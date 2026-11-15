// Autosave, as the original's (undo.s, formats.s): every Preferences > Files
// changes (25; 0: never) the scene is written to the cache folder, file.recover
// opens the last one. It never touches the user's file, and goes further than
// the original in what survives a crash:
//
//   <cache>/autosave-<pid>-<ms>.bee    this session's scene (atomicfile.zig)
//   <cache>/autosave-<pid>-<ms>.info   what it is (its file, when, how big)
//   <cache>/autosave-<pid>-<ms>.lock   held (flock) while the session lives:
//                                      the kernel lets go of it however the
//                                      process ends, so a lock nobody holds
//                                      with a .bee beside it is a crash
//   <cache>/autosave.bee               the last autosave of a session that
//                                      ended well, or was saved (file.recover)
//
// The next start finds a crashed session and offers its scene. A recovered
// scene has no file: Save asks where, so it cannot replace a file that may
// well be newer. Saving, New and Open retire the session's autosave: what is
// in it is older than what the user chose to keep or to leave. Nothing here
// deletes a scene: retired and refused ones go to autosave.bee.
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const bee = @import("bee.zig");
const scene = @import("scene.zig");
const prefs = @import("prefs.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const files = @import("files.zig");
const vp = @import("viewport.zig");
const jobui = @import("jobui.zig");

const Rect = gfx.Rect;
const LOCK_EX_NB: i32 = 2 | 4; // flock: exclusive, no waiting

var dir_buf: [480]u8 = undefined;
var dir_len: usize = 0;
var slot_buf: [64]u8 = undefined;
var slot_len: usize = 0;
var lock_fd: i32 = -1;
/// Sessions with no folder (headless without --autosave-dir) do nothing here.
var armed = false;
/// This session has written an autosave that is still its own.
var have_slot = false;
var changes: u32 = 0;
var warned = false;

// --- paths -------------------------------------------------------------------

fn folder() []const u8 {
    return dir_buf[0..dir_len];
}

fn join(b: []u8, name: []const u8, ext: []const u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(b, "{s}/{s}{s}", .{ folder(), name, ext }, 0) catch null;
}

fn slot() []const u8 {
    return slot_buf[0..slot_len];
}

fn realMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// mkdir -p for the folder (private: scenes are the user's).
fn makeFolder(p: []const u8) bool {
    var b: [480]u8 = undefined;
    if (p.len >= b.len) return false;
    var k: usize = 1;
    while (k <= p.len) : (k += 1) {
        if (k < p.len and p[k] != '/') continue;
        @memcpy(b[0..k], p[0..k]);
        b[k] = 0;
        const r = linux.mkdir(@ptrCast(&b), 0o700);
        const e = linux.errno(r);
        if (e != .SUCCESS and e != .EXIST) return false;
    }
    return true;
}

/// The folder this session uses. `xdg`: $XDG_CACHE_HOME, as the original; the
/// port has its own folder as it has its own preferences, so the assembly
/// app's autosave is never touched.
pub fn folderFor(b: []u8, xdg: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    if (xdg) |x| {
        if (x.len > 0) return std.fmt.bufPrint(b, "{s}/beemodel-zig", .{x}) catch null;
    }
    return std.fmt.bufPrint(b, "{s}/.cache/beemodel-zig", .{home orelse return null}) catch null;
}

/// Start: the folder, this session's lock, the crashed sessions.
pub fn init(dir: []const u8) void {
    if (dir.len == 0 or dir.len >= dir_buf.len or !makeFolder(dir)) {
        // (the user should know there is no safety net)
        app.toast(.warn, "Autosave is off: {s} cannot be used", .{dir});
        return;
    }
    @memcpy(dir_buf[0..dir.len], dir);
    dir_len = dir.len;
    const s = std.fmt.bufPrint(&slot_buf, "autosave-{d}-{d}", .{ linux.getpid(), realMs() }) catch return;
    slot_len = s.len;
    var pb: [560]u8 = undefined;
    const lp = join(&pb, slot(), ".lock") orelse return;
    const rc = linux.open(lp, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return;
    lock_fd = @intCast(rc);
    if (linux.errno(linux.flock(lock_fd, LOCK_EX_NB)) != .SUCCESS) {
        _ = linux.close(lock_fd);
        lock_fd = -1;
        return;
    }
    armed = true;
    scanCrashed();
}

// --- writing -----------------------------------------------------------------

/// A change was recorded (undo.sync).
pub fn note() void {
    if (!armed) return;
    changes += 1;
    if (prefs.autosave <= 0 or changes < @as(u32, @intCast(prefs.autosave))) return;
    if (jobui.queued()) return; // (the next change tries again)
    changes = 0;
    jobui.later(job, "Autosaving", "", 0, 0);
}

fn job(_: []const u8, _: usize, _: usize) void {
    if (files.changed()) _ = now();
}

fn view() ?*const vp.View {
    const v = app.viewportArea();
    return if (v < 0) null else &app.N(v).view;
}

/// The info file: lines of "word value".
fn writeInfo() void {
    var ib: [560]u8 = undefined;
    const ip = join(&ib, slot(), ".info") orelse return;
    var b: [1024]u8 = undefined;
    const t = std.fmt.bufPrint(&b, "doc {s}\ntime {d}\nobjects {d}\nfaces {d}\n", .{ files.path() orelse "", @divTrunc(realMs(), 1000), scene.count, scene.faceCount() }) catch return;
    bee.writeAtomic(ip, t) catch {};
}

/// Write the slot now. The old one stands until the new one is whole.
pub fn now() bool {
    if (!armed) return false;
    var pb: [560]u8 = undefined;
    const p = join(&pb, slot(), ".bee") orelse return false;
    const world = @import("world.zig");
    world.plain = true; // (a partitioned world: what is loaded, as a plain scene)
    defer world.plain = false;
    bee.save(p, view()) catch {
        if (!warned) app.toast(.warn, "Autosave failed: {s} cannot be written", .{p});
        warned = true;
        return false;
    };
    warned = false;
    have_slot = true;
    writeInfo();
    app.log("  autosaved to {s}", .{p});
    return true;
}

/// The scene was saved, or replaced on purpose: this session's autosave is
/// old news, but stays for file.recover. A crash now offers nothing.
pub fn retire() void {
    if (!armed or !have_slot) return;
    have_slot = false;
    changes = 0;
    retireFiles(slot());
}

fn retireFiles(name: []const u8) void {
    var a: [560]u8 = undefined;
    var c: [560]u8 = undefined;
    var d: [560]u8 = undefined;
    const from = join(&a, name, ".bee") orelse return;
    const to = join(&c, "autosave.bee", "") orelse return;
    _ = linux.rename(from, to);
    if (join(&d, name, ".info")) |ip| _ = linux.unlink(ip);
}

/// The main loop ended. Asked to quit: all is decided, the slot is retired.
/// Anything else (the compositor went, a signal): one last autosave of what
/// was not saved, for the next start to offer.
pub fn atExit(asked: bool) void {
    if (!armed) return;
    if (!asked and files.changed()) {
        if (now()) return; // (the lock stays: this reads as a crash)
    }
    if (asked) retire();
    if (have_slot) return;
    var pb: [560]u8 = undefined;
    if (join(&pb, slot(), ".lock")) |lp| _ = linux.unlink(lp);
}

// --- what a crash left -------------------------------------------------------

const Found = struct {
    name: [64]u8 = undefined,
    len: usize = 0,
    fd: i32 = -1, // its lock, held while it is decided
    time: i64 = 0,
    objects: u32 = 0,
    faces: u64 = 0,
    doc: [512]u8 = undefined,
    doc_len: usize = 0,
    pub fn slotName(f: *const Found) []const u8 {
        return f.name[0..f.len];
    }
    pub fn docPath(f: *const Found) []const u8 {
        return f.doc[0..f.doc_len];
    }
};

const MAX_FOUND = 16;
var found: [MAX_FOUND]Found = undefined;
var n_found: usize = 0;
/// The start-up question is showing.
pub var asking = false;

fn readSmall(p: [:0]const u8, b: []u8) []const u8 {
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return "";
    defer _ = linux.close(@intCast(rc));
    const n = linux.read(@intCast(rc), b.ptr, b.len);
    return if (linux.errno(n) == .SUCCESS) b[0..n] else "";
}

/// Lines of "word value", from a file nobody promised anything about.
fn parseInfo(t: []const u8, f: *Found) void {
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const v = line[sp + 1 ..];
        const w = line[0..sp];
        if (std.mem.eql(u8, w, "doc")) {
            f.doc_len = @min(v.len, f.doc.len);
            @memcpy(f.doc[0..f.doc_len], v[0..f.doc_len]);
        } else if (std.mem.eql(u8, w, "time")) {
            f.time = std.fmt.parseInt(i64, v, 10) catch 0;
        } else if (std.mem.eql(u8, w, "objects")) {
            f.objects = std.fmt.parseInt(u32, v, 10) catch 0;
        } else if (std.mem.eql(u8, w, "faces")) {
            f.faces = std.fmt.parseInt(u64, v, 10) catch 0;
        }
    }
}

fn wholeFile(p: []const u8) bool {
    const d = @import("ttf.zig").mapFile(p) orelse return false;
    defer _ = linux.munmap(d.ptr, d.len);
    return bee.wellFormed(d);
}

fn consider(nm: []const u8) void {
    if (std.mem.eql(u8, nm, slot())) return;
    if (nm.len >= 64 or n_found >= MAX_FOUND) return;
    var pb: [560]u8 = undefined;
    const lp = join(&pb, nm, ".lock") orelse return;
    const rc = linux.open(lp, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    // held: that session is alive (a second window)
    if (linux.errno(linux.flock(fd, LOCK_EX_NB)) != .SUCCESS) {
        _ = linux.close(fd);
        return;
    }
    var bb: [560]u8 = undefined;
    const bp = join(&bb, nm, ".bee") orelse return;
    if (!wholeFile(bp)) {
        // no autosave (or one that cannot be used) came with it
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, bp, 0, .{ .SIZE = true }, &st)) == .SUCCESS) {
            app.log("  autosave {s} is damaged: left as it is", .{bp});
        } else {
            var ib: [560]u8 = undefined;
            if (join(&ib, nm, ".info")) |ip| _ = linux.unlink(ip);
            _ = linux.unlink(lp);
        }
        _ = linux.close(fd);
        return;
    }
    const f = &found[n_found];
    f.* = .{ .fd = fd };
    f.len = nm.len;
    @memcpy(f.name[0..nm.len], nm);
    var ib: [560]u8 = undefined;
    var tb: [1024]u8 = undefined;
    if (join(&ib, nm, ".info")) |ip| parseInfo(readSmall(ip, &tb), f);
    n_found += 1;
}

/// What a write cut short left: never read, gone once its session is.
fn sweepTmp() void {
    var pb: [500]u8 = undefined;
    const d = std.fmt.bufPrintSentinel(&pb, "{s}", .{folder()}, 0) catch return;
    const rc = linux.open(d, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const e: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            const nm_ptr: [*:0]const u8 = @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")]);
            const nm = std.mem.span(nm_ptr);
            off += e.reclen;
            if (!std.mem.startsWith(u8, nm, "autosave") or !std.mem.endsWith(u8, nm, ".tmp")) continue;
            // <name>.bee.<pid>-<n>.tmp or .info...: the session's lock says whether it lives
            const stem = nm[0 .. std.mem.indexOfScalar(u8, nm, '.') orelse continue];
            if (std.mem.eql(u8, stem, slot())) continue;
            var lb: [560]u8 = undefined;
            const lp = join(&lb, stem, ".lock") orelse continue;
            const lc = linux.open(lp, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
            if (linux.errno(lc) == .SUCCESS) {
                const held = linux.errno(linux.flock(@intCast(lc), LOCK_EX_NB)) != .SUCCESS;
                _ = linux.close(@intCast(lc));
                if (held) continue;
            }
            var tb: [560]u8 = undefined;
            if (join(&tb, nm, "")) |tp| _ = linux.unlink(tp);
        }
    }
}

/// Calls f for every autosave-*.lock in the folder (by its name, no extension).
fn eachSlot(f: *const fn ([]const u8) void) void {
    var pb: [500]u8 = undefined;
    const d = std.fmt.bufPrintSentinel(&pb, "{s}", .{folder()}, 0) catch return;
    const rc = linux.open(d, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const e: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            const nm_ptr: [*:0]const u8 = @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")]);
            const nm = std.mem.span(nm_ptr);
            off += e.reclen;
            if (std.mem.startsWith(u8, nm, "autosave-") and std.mem.endsWith(u8, nm, ".lock")) f(nm[0 .. nm.len - 5]);
        }
    }
}

fn scanCrashed() void {
    n_found = 0;
    sweepTmp();
    eachSlot(consider);
    // the newest first
    std.mem.sort(Found, found[0..n_found], {}, struct {
        fn f(_: void, a: Found, b: Found) bool {
            return a.time > b.time;
        }
    }.f);
    asking = n_found > 0;
    if (asking) app.dirty = true;
}

/// Let go of the session asked about; the next one (if any) comes up.
fn next() void {
    const f = &found[0];
    _ = linux.close(f.fd);
    var k: usize = 1;
    while (k < n_found) : (k += 1) found[k - 1] = found[k];
    n_found -= 1;
    asking = n_found > 0;
    app.dirty = true;
}

fn removeLock(nm: []const u8) void {
    var pb: [560]u8 = undefined;
    if (join(&pb, nm, ".lock")) |lp| _ = linux.unlink(lp);
}

/// Open the scene the question was about.
fn recoverFound() void {
    const f = &found[0];
    var bb: [560]u8 = undefined;
    const bp = join(&bb, f.slotName(), ".bee") orelse return;
    const nm = if (std.mem.lastIndexOfScalar(u8, f.docPath(), '/')) |s| f.docPath()[s + 1 ..] else f.docPath();
    if (!files.recoverNow(bp, nm, f.docPath())) {
        next();
        return;
    }
    // the scene is this session's now: it is offered again if this one dies too
    var tb: [560]u8 = undefined;
    if (join(&tb, slot(), ".bee")) |to| {
        if (linux.errno(linux.rename(bp, to)) == .SUCCESS) {
            have_slot = true;
            writeInfo();
        }
    }
    var ib: [560]u8 = undefined;
    if (join(&ib, f.slotName(), ".info")) |ip| _ = linux.unlink(ip);
    removeLock(f.slotName());
    next();
}

/// No thanks: it stays reachable with file.recover until a newer one replaces it.
fn discardFound() void {
    const f = &found[0];
    retireFiles(f.slotName());
    removeLock(f.slotName());
    next();
}

pub const Answer = enum { recover, later, discard };

pub fn answer(a: Answer) void {
    if (!asking) return;
    switch (a) {
        .recover => recoverFound(),
        .later => next(), // (its files stay: the next start asks again)
        .discard => discardFound(),
    }
}

var age_buf: [32]u8 = undefined;

/// The prompt, drawn by Zui (dialogs.prompt_client). Enter recovers; Esc
/// leaves it for the next start. Nothing is lost by either.
pub fn describe(z: *@import("zui").Ui) void {
    const dialogs = @import("dialogs.zig");
    const f = &found[0];
    if (!dialogs.beginPrompt(z, "Recover unsaved work?", 440)) return;
    defer z.endDialog();
    var b: [640]u8 = undefined;
    const dp = f.docPath();
    const doc = if (f.doc_len == 0) "an untitled scene" else if (std.mem.lastIndexOfScalar(u8, dp, '/')) |s| dp[s + 1 ..] else dp;
    dialogs.promptLine(z, std.fmt.bufPrint(&b, "The last session on {s} did not end properly.", .{doc}) catch "");
    var b2: [160]u8 = undefined;
    dialogs.promptLine(z, std.fmt.bufPrint(&b2, "Its last autosave, {s} old: {d} objects, {d} faces.", .{ age(&age_buf, f.time), f.objects, f.faces }) catch "");
    if (z.dialogButtons(&.{ "Discard", "Not Now", "Recover" }, .{ .default = 2, .cancel = 1 })) |p| {
        answer(switch (p) {
            0 => .discard,
            1 => .later,
            else => .recover,
        });
    }
}

fn age(b: []u8, t: i64) []const u8 {
    const s = @max(0, @divTrunc(realMs(), 1000) - t);
    if (t == 0) return "of unknown age,";
    if (s < 120) return std.fmt.bufPrint(b, "{d} seconds", .{s}) catch "";
    if (s < 7200) return std.fmt.bufPrint(b, "{d} minutes", .{@divTrunc(s, 60)}) catch "";
    if (s < 172800) return std.fmt.bufPrint(b, "{d} hours", .{@divTrunc(s, 3600)}) catch "";
    return std.fmt.bufPrint(b, "{d} days", .{@divTrunc(s, 86400)}) catch "";
}

// --- file.recover ------------------------------------------------------------

var best_name: [64]u8 = undefined;
var best_len: usize = 0;
var best_time: i64 = -1;
var best_ns: u32 = 0;

fn mtime(p: [:0]const u8) ?struct { i64, u32 } {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, p, 0, .{ .MTIME = true, .SIZE = true }, &st)) != .SUCCESS) return null;
    if (st.size == 0) return null;
    return .{ st.mtime.sec, st.mtime.nsec };
}

fn consideredForRecover(nm: []const u8) void {
    if (nm.len >= 64) return;
    var pb: [560]u8 = undefined;
    const p = join(&pb, nm, ".bee") orelse return;
    const t = mtime(p) orelse return;
    if (!std.mem.eql(u8, nm, slot())) {
        // another window's own autosave is not this session's to take
        var lb: [560]u8 = undefined;
        const lp = join(&lb, nm, ".lock") orelse return;
        const rc = linux.open(lp, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return;
        defer _ = linux.close(@intCast(rc));
        var ok = false;
        for (found[0..n_found]) |*f| ok = ok or std.mem.eql(u8, f.slotName(), nm); // (held by us)
        if (!ok and linux.errno(linux.flock(@intCast(rc), LOCK_EX_NB)) != .SUCCESS) return;
    }
    if (t[0] > best_time or (t[0] == best_time and t[1] > best_ns)) {
        best_time = t[0];
        best_ns = t[1];
        best_len = nm.len;
        @memcpy(best_name[0..nm.len], nm);
    }
}

/// file.recover: the newest autosave this session may take. The "Save
/// changes?" question came first (files.zig).
pub fn recoverLatest() void {
    if (!armed) return app.toast(.warn, "Recover Autosave: there is no autosave folder here", .{});
    best_time = -1;
    best_ns = 0;
    best_len = 0;
    eachSlot(consideredForRecover);
    var pb: [560]u8 = undefined;
    var cb: [560]u8 = undefined;
    if (join(&cb, "autosave.bee", "")) |lp| {
        if (mtime(lp)) |t| {
            if (t[0] > best_time or (t[0] == best_time and t[1] > best_ns)) {
                best_time = t[0];
                best_ns = t[1];
                best_len = 0;
            }
        }
    }
    if (best_time < 0) return app.toast(.warn, "Recover Autosave: there is no autosave yet", .{});
    const p = if (best_len > 0) join(&pb, best_name[0..best_len], ".bee") orelse return else (join(&pb, "autosave.bee", "") orelse return);
    _ = files.recoverNow(p, "", "");
}

// --- tests -------------------------------------------------------------------

test "the info file is read whatever it says" {
    var f = Found{};
    parseInfo("doc /home/a/b.bee\ntime 1700000000\nobjects 12\nfaces 900\n", &f);
    try std.testing.expectEqualStrings("/home/a/b.bee", f.docPath());
    try std.testing.expectEqual(@as(i64, 1700000000), f.time);
    try std.testing.expectEqual(@as(u32, 12), f.objects);
    try std.testing.expectEqual(@as(u64, 900), f.faces);
    var g = Found{};
    parseInfo("doc\ntime nan\nobjects -1\n\xff\xfe faces\nfaces 99999999999999999999999\n", &g);
    try std.testing.expectEqual(@as(usize, 0), g.doc_len);
    try std.testing.expectEqual(@as(i64, 0), g.time);
    var h = Found{};
    var long: [2000]u8 = @splat('a');
    @memcpy(long[0..4], "doc ");
    parseInfo(&long, &h);
    try std.testing.expectEqual(@as(usize, 512), h.doc_len);
}
