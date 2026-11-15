// Image to 3D, the Hi3D addon (hi3d.s): a mesh made from a photo.
//
// AI > Model from Image... (object.from_image <image> [512 | 1024 | 1536]) and
// Object > Refine from Image... (object.refine_from_image <image> [...]) hand
// the work to the addon's helper, bee-hi3d: TripoSR makes a rough shape from
// the image, Hi3D v1.0 carves the image's detail into it. Refine sends the
// active mesh as the rough shape instead (an OBJ in the cache, in the object's
// own space), so a block-out modelled here gets the detail.
//
// The helper is ~/.local/share/beemodel/hi3d/bee-hi3d or $BEEMODEL_HI3D. It runs
// while you go on working: one at a time, its output read without waiting from
// the main loop (pollfds / tick), all of it kept in <cache>/beemodel/hi3d/hi3d.log.
// Lines for BeeModel start with "@bee ": "progress <0..1> <text>" (the status
// bar chip), "done <obj> <faces>" and "error <text>". The chip stops it when
// clicked (object.from_image_stop): TERM, then KILL six turns of the loop later.
//
// When it is done, object.from_image_place (one undo step) imports the OBJ as
// an object named after the file: at the 3D cursor (a new model), or with the
// refined object's location, rotation and scale (that one hidden).
// Powered by Hi3D 1.0 (http://hi3d.ai/).
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const undo = @import("undo.zig");
const spawn = @import("spawn.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const m = @import("math.zig");

const Mode = enum(u8) { none, new, refine };

/// hz_pid: the helper (0: none).
pub var pid: i32 = 0;
var fd: i32 = -1; // its stdout + stderr
var log_fd: i32 = -1; // hi3d.log
var kill_at: u32 = 0;
var mode: Mode = .none;
var src_uid: u32 = 0; // refine: the object refined (its uid)
var stopped = false;
var frac: f32 = 0;
// (what the place operator does: the mode and object of the helper that ended)
var pmode: Mode = .none;
var psrc_uid: u32 = 0;
var xf: [3]m.V3 = undefined; // refine: the rough one's location, rotation, scale

var exe_buf: [512]u8 = undefined;
var exe_len: usize = 0;
var img_buf: [512]u8 = undefined;
var dir_buf: [512]u8 = undefined;
var dir_len: usize = 0;
var out_buf: [512]u8 = undefined;
var coarse_buf: [512]u8 = undefined;
/// hz_result: the OBJ the helper made ("" none)
var result: [512]u8 = undefined;
var result_len: usize = 0;
/// hz_text: what it is doing (60 bytes at most)
var text_buf: [64]u8 = undefined;
var text_len: usize = 0;
/// hz_err: what went wrong (250 bytes at most)
var err_buf: [256]u8 = undefined;
var err_len: usize = 0;
var line: [1024]u8 = undefined;
var llen: usize = 0;
/// When the chip was first drawn at work (st_seen), 0: not yet.
var seen_ms: i64 = 0;

const RES = [_][]const u8{ "512", "1024", "1536" };

pub fn running() bool {
    return pid != 0;
}

fn pollMesh() ?[]const u8 {
    return if (activeMesh() == null) "Needs an active mesh object" else null;
}

fn activeMesh() ?usize {
    const a = scene.active orelse return null;
    return if (scene.objects[a].kind.isMesh()) a else null; // (OT_MESH: every mesh, a primitive too)
}

pub const list = [_]struct { []const u8, ops.Impl }{
    .{ "object.from_image", ops.Impl{ .run = opNew } },
    .{ "object.refine_from_image", ops.Impl{ .run = opRefine, .poll = pollMesh } },
    .{ "object.from_image_stop", ops.Impl{ .run = opStop } },
    .{ "object.from_image_place", ops.Impl{ .run = opPlace } },
};

fn opNew() void {
    start(.new);
}
fn opRefine() void {
    start(.refine);
}

fn browsed(p: []const u8) void {
    runWith(if (browse_mode == .refine) "object.refine_from_image" else "object.from_image", p);
}
var browse_mode: Mode = .new;

fn runWith(id: []const u8, arg: []const u8) void {
    const i = ops.byId(id) orelse return;
    const was = ops.arg;
    ops.arg = arg;
    defer ops.arg = was;
    ops.run(i);
}

/// hz_start: the operator's argument (the image, then the detail); the
/// helper started on it.
fn start(md: Mode) void {
    const usage = if (md == .refine) "  object.refine_from_image <image file> [512 | 1024 | 1536] (the active mesh)" else "  object.from_image <image file> [512 | 1024 | 1536]";
    if (ops.arg.len == 0) {
        // from the UI with no values: its form (a file to pick)
        if (!ops.scripted) {
            browse_mode = md;
            @import("filebrowser.zig").show(.open, if (md == .refine) "Refine from Image (Hi3D)" else "Model from Image (Hi3D)", ".png .jpg .jpeg .hdr", "", browsed);
            return;
        }
        return app.log("{s}", .{usage});
    }
    if (pid != 0) return app.log("  Image to 3D: one is being made (its chip in the status bar stops it)", .{});
    // the image (path_expand: leading spaces off, ~ for $HOME; 500 bytes), then its last word: a detail?
    var a = std.mem.trimStart(u8, ops.arg, " ");
    var eb: [600]u8 = undefined;
    if (a.len > 0 and a[0] == '~' and (a.len == 1 or a[1] == '/')) {
        if (spawn.getenv("HOME")) |h| a = std.fmt.bufPrint(&eb, "{s}{s}", .{ h, a[1..] }) catch a;
    }
    var img = a[0..@min(a.len, 500)];
    img = std.mem.trimEnd(u8, img, " ");
    var res: []const u8 = "512";
    if (std.mem.lastIndexOfScalar(u8, img, ' ')) |sp| {
        const w = img[sp + 1 ..];
        for (RES) |r| {
            if (std.mem.eql(u8, w, r)) {
                res = r;
                img = std.mem.trimEnd(u8, img[0..sp], " ");
            }
        }
    }
    if (std.mem.indexOfScalar(u8, img, 0)) |z| img = img[0..z];
    @memcpy(img_buf[0..img.len], img);
    img_buf[img.len] = 0;
    const imgz = img_buf[0..img.len :0];
    if (linux.errno(linux.access(imgz, linux.R_OK)) != .SUCCESS) return app.log("  Image to 3D: cannot read the image {s}", .{img});
    if (md == .refine and activeMesh() == null) return app.log("Needs an active mesh object", .{});
    if (!find()) return app.log("  Image to 3D is an addon: install it with addons/hi3d/install.sh (docs/HI3D.md)", .{});
    // <cache>/beemodel/hi3d ($XDG_CACHE_HOME, else ~/.cache: cache_dir)
    const cache = spawn.getenv("XDG_CACHE_HOME") orelse "";
    const d = (if (cache.len > 0) std.fmt.bufPrint(&dir_buf, "{s}/beemodel/hi3d", .{cache}) else std.fmt.bufPrint(&dir_buf, "{s}/.cache/beemodel/hi3d", .{spawn.getenv("HOME") orelse ""})) catch return;
    dir_len = d.len;
    _ = spawn.ensureDir(d);
    var nb: [32]u8 = undefined;
    const out = std.fmt.bufPrintSentinel(&out_buf, "{s}/{s}.obj", .{ d, importName(&nb, img) }, 0) catch return;
    src_uid = 0;
    var coarse: [:0]const u8 = "";
    if (md == .refine) {
        // the active mesh, alone selected, as an OBJ in its own space: its
        // transform kept for the refined one, the mesh written without it
        coarse = std.fmt.bufPrintSentinel(&coarse_buf, "{s}/coarse.obj", .{d}, 0) catch return;
        const s = activeMesh().?;
        scene.selectOnly(s);
        const o = &scene.objects[s];
        src_uid = o.uid;
        xf = .{ o.loc, o.rot, o.scl };
        o.loc = .{ 0, 0, 0 };
        o.rot = .{ 0, 0, 0 };
        o.scl = .{ 1, 1, 1 };
        const om = @import("objmtl.zig");
        const was = om.opts;
        om.opts = .{ .sel_only = true };
        _ = linux.unlink(coarse);
        _ = om.exportObj(coarse) catch 0;
        om.opts = was;
        o.loc = xf[0];
        o.rot = xf[1];
        o.scl = xf[2];
        if (linux.errno(linux.access(coarse, linux.R_OK)) != .SUCCESS) return app.log("  Image to 3D: could not write the rough mesh", .{});
    }
    // bee-hi3d run --image I --out O --resolution R [--coarse C]
    var rz: [8]u8 = undefined;
    const resz = std.fmt.bufPrintSentinel(&rz, "{s}", .{res}, 0) catch return;
    const exez = exe_buf[0..exe_len :0];
    var argv = [_:null]?[*:0]const u8{ exez, "run", "--image", imgz, "--out", out, "--resolution", resz, null, null, null };
    if (md == .refine) {
        argv[8] = "--coarse";
        argv[9] = coarse;
    }
    if (!startHelper(&argv)) return app.log("  Image to 3D: could not start {s}", .{exez});
    mode = md;
    stopped = false;
    frac = 0;
    result_len = 0;
    err_len = 0;
    llen = 0;
    setText("Starting");
    seen_ms = 0;
    app.log("  {s} (Powered by Hi3D 1.0, http://hi3d.ai/), detail {s}", .{ if (md == .refine) "Refine from Image" else "Image to 3D", res });
    app.dirty = true;
}

/// import_name: the file's base name (26 bytes at most), less what follows
/// its last '.' (not a leading one); "Imported" when nothing is left.
fn importName(b: *[32]u8, path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
    var n: usize = @min(base.len, 26);
    @memcpy(b[0..n], base[0..n]);
    if (std.mem.lastIndexOfScalar(u8, b[0..n], '.')) |dot| {
        if (dot > 0) n = dot;
    }
    return if (n == 0) "Imported" else b[0..n];
}

/// hz_find: the helper's path ($BEEMODEL_HI3D, else
/// ~/.local/share/beemodel/hi3d/bee-hi3d) when it is a program.
fn find() bool {
    var b: [512]u8 = undefined;
    const env = spawn.getenv("BEEMODEL_HI3D") orelse "";
    const want = if (env.len > 0) env else std.fmt.bufPrint(&b, "{s}/.local/share/beemodel/hi3d/bee-hi3d", .{spawn.getenv("HOME") orelse return false}) catch return false;
    var wb: [512]u8 = undefined;
    const p = spawn.which(&wb, want) orelse return false;
    if (p.len >= exe_buf.len) return false;
    @memcpy(exe_buf[0..p.len], p);
    exe_buf[p.len] = 0;
    exe_len = p.len;
    return true;
}

/// hz_spawn: stdin nothing, stdout and stderr into a pipe read without
/// waiting; the log opened.
fn startHelper(argv: [*:null]const ?[*:0]const u8) bool {
    var p: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&p, .{ .CLOEXEC = true })) != .SUCCESS) return false;
    const child = spawn.spawn(exe_buf[0..exe_len :0], argv, spawn.NULL, p[1], p[1]) orelse {
        _ = linux.close(p[0]);
        _ = linux.close(p[1]);
        return false;
    };
    pid = child;
    _ = linux.close(p[1]);
    const fl = linux.fcntl(p[0], linux.F.GETFL, 0);
    _ = linux.fcntl(p[0], linux.F.SETFL, fl | 0o4000); // O_NONBLOCK
    fd = p[0];
    kill_at = 0;
    var lb: [560]u8 = undefined;
    const lp = std.fmt.bufPrintSentinel(&lb, "{s}/hi3d.log", .{dir_buf[0..dir_len]}, 0) catch return true;
    const rc = linux.open(lp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    log_fd = if (linux.errno(rc) == .SUCCESS) @intCast(rc) else -1;
    return true;
}

/// object.from_image_stop: ask the helper to end (TERM; KILL later).
fn opStop() void {
    if (pid == 0) return;
    stopped = true;
    _ = linux.kill(pid, .TERM);
    kill_at = 6;
}

/// hz_kill: end it now (BeeModel is quitting).
pub fn kill() void {
    if (pid != 0) _ = linux.kill(pid, .KILL);
}

/// hz_pollfds: the helper's pipe.
pub fn pollfds(p: []linux.pollfd) usize {
    if (fd < 0 or p.len == 0) return 0;
    p[0] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
    return 1;
}

/// hz_tick: what the helper wrote (into the log, its lines read); its end.
/// ms until it should be looked at again (its chip's time), null: idle.
pub fn tick() ?i32 {
    if (pid == 0) return null;
    if (kill_at > 0) {
        kill_at -= 1;
        if (kill_at == 0) _ = linux.kill(pid, .KILL); // a stop not taken
    }
    drain();
    var st: i32 = 0;
    const r = linux.wait4(pid, &st, 1, null); // WNOHANG
    if (linux.errno(r) != .SUCCESS or r == 0) {
        if (linux.errno(r) == .CHILD) return ended(0x100); // (not ours any more: gone)
        return 1000;
    }
    return ended(@bitCast(st));
}

fn ended(st: u32) ?i32 {
    drain(); // (what it wrote before it ended)
    if (fd >= 0) _ = linux.close(fd);
    fd = -1;
    if (log_fd >= 0) _ = linux.close(log_fd);
    log_fd = -1;
    pid = 0;
    kill_at = 0;
    app.dirty = true;
    pmode = mode;
    psrc_uid = src_uid;
    mode = .none;
    if (stopped) {
        app.log("  Image to 3D: stopped", .{});
        return null;
    }
    if (st & 0x7f == 0 and st & 0xff00 == 0 and result_len > 0) {
        // exit 0 with a mesh: in it comes (one undo step)
        undo.sync();
        runPlace(result[0..result_len]);
        undo.sync();
        return null;
    }
    app.log("  Image to 3D: all the helper said is in ~/.cache/beemodel/hi3d/hi3d.log", .{});
    // (the error last: the toast shows it)
    app.log("  Image to 3D failed: {s}", .{if (err_len > 0) err_buf[0..err_len] else "the helper ended without a mesh"});
    return null;
}

fn runPlace(path: []const u8) void {
    const i = ops.byId("object.from_image_place") orelse return;
    const was = ops.arg;
    const was_s = ops.scripted;
    ops.arg = path;
    ops.scripted = true;
    defer {
        ops.arg = was;
        ops.scripted = was_s;
    }
    ops.run(i);
}

/// hz_drain: what there is, read: into the log, each line looked at.
fn drain() void {
    var buf: [16384]u8 = undefined;
    while (fd >= 0) {
        const r = linux.read(fd, &buf, buf.len);
        const e = linux.errno(r);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return; // (nothing now)
        if (r == 0) { // (the end)
            _ = linux.close(fd);
            fd = -1;
            return;
        }
        if (log_fd >= 0) _ = linux.write(log_fd, &buf, r);
        for (buf[0..r]) |c| {
            if (c == '\n') {
                lineIn(line[0..llen]);
                llen = 0;
            } else if (llen < 1023) {
                line[llen] = c;
                llen += 1;
            }
        }
    }
}

/// hz_cpy: at most n bytes (up to a 0 byte).
fn cpy(dst: []u8, s: []const u8, n: usize) usize {
    const z = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
    const k = @min(z, n);
    @memcpy(dst[0..k], s[0..k]);
    return k;
}

fn setText(s: []const u8) void {
    text_len = cpy(&text_buf, s, 60);
}

/// hz_line_in: one line it wrote: "@bee progress | done | error".
pub fn lineIn(l0: []const u8) void {
    // (a 0 byte ends the line, as the C string the original holds)
    const l = l0[0 .. std.mem.indexOfScalar(u8, l0, 0) orelse l0.len];
    if (!std.mem.startsWith(u8, l, "@bee ")) return;
    const t = l[5..];
    if (std.mem.startsWith(u8, t, "progress ")) {
        const p = parseFloat(t[9..]);
        if (p.ok) frac = p.v;
        var i = 9 + p.end;
        while (i < t.len and t[i] == ' ') i += 1;
        setText(t[i..]);
        app.dirty = true;
    } else if (std.mem.startsWith(u8, t, "done ")) {
        // done <path> <faces>: the path
        result_len = cpy(&result, t[5..], 500);
        if (std.mem.lastIndexOfScalar(u8, result[0..result_len], ' ')) |sp| result_len = sp;
    } else if (std.mem.startsWith(u8, t, "error ")) {
        err_len = cpy(&err_buf, t[6..], 250);
    }
}

const Parsed = struct { v: f32, ok: bool, end: usize };

/// parse_float: "-1.5e3" style; where it stopped, and whether there were digits.
fn parseFloat(s: []const u8) Parsed {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == 9)) i += 1;
    var v: f64 = 0;
    var neg = false;
    var digits: u32 = 0;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    } else if (i < s.len and s[i] == '+') i += 1;
    while (i < s.len and s[i] -% '0' <= 9) : (i += 1) {
        v = v * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
        digits += 1;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        var u: f64 = 1;
        while (i < s.len and s[i] -% '0' <= 9) : (i += 1) {
            u /= 10.0;
            v += @as(f64, @floatFromInt(s[i] - '0')) * u;
            digits += 1;
        }
    }
    if (i < s.len and s[i] | 0x20 == 'e') {
        i += 1;
        var eneg = false;
        if (i < s.len and s[i] == '-') {
            eneg = true;
            i += 1;
        } else if (i < s.len and s[i] == '+') i += 1;
        var e: u32 = 0;
        while (i < s.len and s[i] -% '0' <= 9) : (i += 1) e = e *% 10 +% (s[i] - '0');
        if (e > 38) e = 38;
        while (e > 0) : (e -= 1) v = if (eneg) v / 10.0 else v * 10.0;
    }
    if (neg) v = 0.0 - v;
    return .{ .v = @floatCast(v), .ok = digits > 0, .end = i };
}

/// object.from_image_place <obj>: the helper's mesh in, placed (one undo step).
fn opPlace() void {
    const p = ops.arg;
    if (p.len == 0) return;
    const fm = @import("formats.zig");
    var zb: [600]u8 = undefined;
    const path = zb[0..@min(p.len, 599)];
    @memcpy(path, p[0..path.len]);
    const oi = fm.importObj(path) catch {
        app.log("  Image to 3D: could not read the mesh it made: {s}", .{p});
        return;
    };
    const o = &scene.objects[oi];
    if (pmode == .refine) {
        // refined: the rough one's transform (its mesh is in that one's
        // space); the rough one hidden
        o.loc = xf[0];
        o.rot = xf[1];
        o.scl = xf[2];
        for (scene.objects[0..scene.count]) |*q| {
            if (psrc_uid != 0 and q.uid == psrc_uid) {
                q.visible = false;
                q.selected = false;
            }
        }
    } else o.loc = scene.cursor; // a new model: on the 3D cursor
    app.log("  Image to 3D made {s}", .{o.name()});
}

// ---- the status bar chip ----------------------------------------------------------------

/// hz_chip and its time: "Image to 3D: <what it is doing> 42%, 12 s (click: stop)".
pub fn chipText(b: []u8, ms: i64) []const u8 {
    const f = frac * 100;
    const pct: i32 = if (f >= -2147483648.0 and f < 2147483648.0) @intFromFloat(f) else std.math.minInt(i32);
    var w = std.Io.Writer.fixed(b);
    w.print("Image to 3D: {s} {d}%", .{ text_buf[0..text_len], pct }) catch {};
    if (ms >= 1000) {
        const s: u64 = @intCast(@divTrunc(ms, 1000));
        if (s >= 60) {
            w.print(", {d} min {s}{d} s", .{ s / 60, if (s % 60 < 10) "0" else "", s % 60 }) catch {};
        } else w.print(", {d} s", .{s}) catch {};
    }
    w.writeAll(" (click: stop)") catch {};
    return w.buffered();
}

/// The chip, its right edge at `right` (status.s chip): the next chip's edge.
/// A click stops the helper.
pub fn chip(b: []u8) ?app.Chip {
    if (pid == 0) {
        seen_ms = 0;
        return null;
    }
    if (seen_ms == 0) seen_ms = app.now_ms;
    const s = chipText(b, app.now_ms - seen_ms);
    return .{ .text = s, .label = s, .title = "Image to 3D", .tip = "A model being made from an image (the Hi3D addon). Click to stop it", .action = stopChip };
}

fn stopChip() void {
    ops.runId("object.from_image_stop");
}
test "the helper's lines" {
    lineIn("@bee progress 0.42 Carving the detail");
    try std.testing.expectEqual(@as(f32, 0.42), frac);
    try std.testing.expectEqualStrings("Carving the detail", text_buf[0..text_len]);
    lineIn("@bee progress x");
    try std.testing.expectEqualStrings("x", text_buf[0..text_len]);
    lineIn("@bee done /tmp/a b/x.obj 1234");
    try std.testing.expectEqualStrings("/tmp/a b/x.obj", result[0..result_len]);
    lineIn("@bee error out of memory");
    try std.testing.expectEqualStrings("out of memory", err_buf[0..err_len]);
    lineIn("noise @bee done y");
    try std.testing.expectEqualStrings("/tmp/a b/x.obj", result[0..result_len]);
    var b: [160]u8 = undefined;
    frac = 0.5;
    setText("Rough shape");
    try std.testing.expectEqualStrings("Image to 3D: Rough shape 50% (click: stop)", chipText(&b, 300));
    try std.testing.expectEqualStrings("Image to 3D: Rough shape 50%, 1 min 05 s (click: stop)", chipText(&b, 65_000));
    var nb: [32]u8 = undefined;
    try std.testing.expectEqualStrings("chair", importName(&nb, "/x/chair.png"));
    try std.testing.expectEqualStrings(".png", importName(&nb, "/x/.png"));
}
