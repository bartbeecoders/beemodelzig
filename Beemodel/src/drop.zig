// Files dropped on the window (drop.s, clipboard.s): a file manager offers
// text/uri-list through wl_data_device; each file:// line is opened by its kind:
// .obj .stl imported, images as references, a .bee opened when the scene has no
// unsaved changes. clipboard.zig passes the device's drag events here.
const std = @import("std");
const linux = std.os.linux;
const wl = @import("wayland.zig");
const app = @import("app.zig");
const files = @import("files.zig");
const ops = @import("ops.zig");

const MIME = "text/uri-list";
const OFFER_ACCEPT = 0;
const OFFER_RECEIVE = 1;
const OFFER_DESTROY = 2;
const OFFER_FINISH = 3;
const OFFER_ACTIONS = 4;
const CAP = 1 << 16;

var offer_uri = false; // the newest offer has text/uri-list
var dnd: u32 = 0; // the offer being dragged over us
var dnd_ok = false;
var pending: [CAP]u8 = undefined;
var pending_len: usize = 0;

/// data_offer(id): its types follow.
pub fn newOffer() void {
    offer_uri = false;
}

/// offer(type)
pub fn offered(m: []const u8) void {
    if (std.mem.eql(u8, m, MIME)) offer_uri = true;
}

/// enter(serial, surface, x, y, offer): files dragged over us: take them.
pub fn enter(w: *wl.Window, r: *wl.Window.Rd, newest: u32) void {
    const serial = r.u();
    _ = r.u();
    at = .{ r.fixed(), r.fixed() };
    dnd = r.u();
    dnd_ok = false;
    if (dnd == 0 or dnd != newest or !offer_uri) return;
    dnd_ok = true;
    w.req(dnd, OFFER_ACCEPT, .{ serial, wl.Window.Str{ .s = MIME } });
    w.req(dnd, OFFER_ACTIONS, .{ @as(u32, 1), @as(u32, 1) }); // copy, copy
    w.flush() catch {};
}

/// motion(time, x, y): where the files would land.
pub fn motion(r: *wl.Window.Rd) void {
    _ = r.u();
    at = .{ r.fixed(), r.fixed() };
}

/// leave: the offer goes (unless it is also the selection).
pub fn leave(w: *wl.Window, selection: u32) void {
    if (dnd != 0 and dnd != selection) w.req(dnd, OFFER_DESTROY, .{});
    dnd = 0;
    dnd_ok = false;
}

/// drop: the list, through a pipe; the files open from the main loop.
pub fn dropped(w: *wl.Window, selection: u32) void {
    if (!dnd_ok) return;
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) == .SUCCESS) {
        w.req(dnd, OFFER_RECEIVE, .{ wl.Window.Str{ .s = MIME }, wl.Window.Fd{ .fd = fds[1] } });
        w.flush() catch {};
        _ = linux.close(fds[1]);
        pending_len = readAll(fds[0]);
        _ = linux.close(fds[0]);
    }
    w.req(dnd, OFFER_FINISH, .{});
    leave(w, selection);
    const sc = @import("scale.zig");
    deliver(pending[0..pending_len], .{ sc.ptr(at[0]), sc.ptr(at[1]) });
}

/// Where the files dragged over the window are (surface coordinates).
var at: [2]f32 = .{ 0, 0 };

/// Where the last drop landed, if a zone of Zui's took it: the 3D
/// viewport (area) under it, at (x, y) units.
pub const Target = struct { area: i16, x: i32, y: i32 };
var target: ?Target = null;
var waiting = false;

/// A text/uri-list dropped at `pos` (units): its files go to Zui's input,
/// for the zone under the pointer (`fileDrop`) in the next frame; after
/// that frame (`flush`) they open by their kind, where that zone said.
pub fn deliver(list: []const u8, pos: [2]f32) void {
    if (list.len == 0) return;
    if (list.ptr != &pending) {
        pending_len = @min(list.len, pending.len);
        @memcpy(pending[0..pending_len], list[0..pending_len]);
    }
    target = null;
    waiting = true;
    var it = std.mem.splitScalar(u8, pending[0..pending_len], '\n');
    var pb: [1000]u8 = undefined;
    while (it.next()) |l| if (pathOf(l, &pb)) |p| @import("zuihost.zig").fileDrop(p, pos);
    app.dirty = true;
}

/// A zone took the drop (the viewport, at the area and place given).
pub fn take(t: Target) void {
    if (waiting) target = t;
}

/// After the frame that saw the drop: the files open (a job: one may take a while).
pub fn flush() void {
    if (!waiting) return;
    waiting = false;
    @import("zuihost.zig").clearDrops();
    @import("jobui.zig").later(job, "Opening the dropped files", "", 0, 0);
}

/// (a second at most: a sender that says nothing does not stop the window)
fn readAll(fd: i32) usize {
    var n: usize = 0;
    while (n < pending.len) {
        var p = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const pr = linux.poll(&p, 1, 1000);
        if (linux.errno(pr) == .INTR) continue;
        if (linux.errno(pr) != .SUCCESS or pr == 0) break;
        const rc = linux.read(fd, pending[n..].ptr, pending.len - n);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS or rc == 0) break;
        n += rc;
    }
    return n;
}

fn job(_: []const u8, _: usize, _: usize) void {
    // (dropped on a 3D viewport: an image lands on what is under the
    // pointer, through the 3D cursor, as an asset dragged there)
    if (target) |t| if (app.areaValid(t.area) and app.N(t.area).editor == .viewport) {
        const vp = @import("viewport.zig");
        const body = @import("editors.zig").bodyRect(app.N(t.area).rect);
        @import("scene.zig").cursor = vp.surfacePoint(@import("ui.zig").cv, &app.N(t.area).view, body, t.x, t.y) orelse @import("scene.zig").cursor;
    };
    target = null;
    openList(pending[0..pending_len]);
}

// --- the list -----------------------------------------------------------------

fn hexval(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

/// One line's path, %XX decoded, into out. Null: a comment, not a file:// URI,
/// or no path.
pub fn pathOf(line0: []const u8, out: []u8) ?[]const u8 {
    const line = std.mem.trim(u8, line0, "\r\n ");
    if (line.len == 0 or line[0] == '#' or !std.mem.startsWith(u8, line, "file://")) return null;
    const rest = line[7..]; // past "file://", its host
    const sl = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const p = rest[sl..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < p.len and n < out.len) : (n += 1) {
        if (p[i] == '%' and i + 2 < p.len) {
            if (hexval(p[i + 1])) |h| {
                if (hexval(p[i + 2])) |l| {
                    out[n] = h << 4 | l;
                    i += 3;
                    continue;
                }
            }
        }
        out[n] = p[i];
        i += 1;
    }
    if (i < p.len) return null; // (too long for a path)
    return if (std.mem.indexOfScalar(u8, out[0..n], 0) != null) null else out[0..n];
}

pub const Kind = enum { obj, stl, bee, image, step, usd, gltf, unported, unknown };

pub fn kindOf(path: []const u8) Kind {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return .unknown;
    const e = base[dot..];
    const is = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.ascii.eqlIgnoreCase(a, b);
        }
    }.f;
    if (is(e, ".obj")) return .obj;
    if (is(e, ".stl")) return .stl;
    if (is(e, ".bee")) return .bee;
    if (is(e, ".png") or is(e, ".jpg") or is(e, ".jpeg")) return .image;
    if (is(e, ".step") or is(e, ".stp")) return .step;
    if (is(e, ".usd") or is(e, ".usda") or is(e, ".usdc")) return .usd;
    if (is(e, ".glb") or is(e, ".gltf")) return .gltf;
    if (is(e, ".blend")) return .unported;
    return .unknown;
}

/// As drop_one: by its kind.
pub fn openOne(path: []const u8) void {
    switch (kindOf(path)) {
        .obj, .stl => files.importPath(path),
        .bee => {
            if (files.changed()) return app.toast(.warn, "Save the scene first, or use File > Open: a .bee file replaces it", .{});
            files.openFrom(path);
        },
        .image => {
            ops.arg = path;
            defer ops.arg = "";
            ops.runId("object.add_reference");
        },
        .step => {
            ops.arg = path;
            defer ops.arg = "";
            ops.runId("file.import_step");
        },
        .usd => {
            ops.arg = path;
            defer ops.arg = "";
            ops.runId("file.import_usd");
        },
        .gltf => {
            ops.arg = path;
            defer ops.arg = "";
            ops.runId("file.import_gltf");
        },
        .unported => app.toast(.warn, "{s}: {s}", .{ path, ops.not_ported }),
        .unknown => app.toast(.warn, "Cannot open a dropped file of that kind: {s}", .{path}),
    }
    app.dirty = true;
}

/// Every file:// line of a text/uri-list.
pub fn openList(list: []const u8) void {
    var it = std.mem.splitScalar(u8, list, '\n');
    var pb: [1000]u8 = undefined;
    while (it.next()) |l| {
        if (pathOf(l, &pb)) |p| openOne(p);
        app.afterInput();
    }
}

const testing = std.testing;

test "a line of a uri list" {
    var b: [200]u8 = undefined;
    try testing.expectEqualStrings("/home/a/b c.png", pathOf("file:///home/a/b%20c.png\r", &b).?);
    try testing.expectEqualStrings("/x/y.obj", pathOf("file://host.local/x/y.obj", &b).?);
    try testing.expectEqualStrings("/caf\xc3\xa9.stl", pathOf("file:///caf%C3%A9.stl", &b).?);
    try testing.expectEqualStrings("/100%.bee", pathOf("file:///100%.bee", &b).?);
    try testing.expectEqualStrings("/a%zz.bee", pathOf("file:///a%zz.bee", &b).?);
    try testing.expectEqual(null, pathOf("# a comment", &b));
    try testing.expectEqual(null, pathOf("http://example.com/x.png", &b));
    try testing.expectEqual(null, pathOf("file://nopath", &b));
    try testing.expectEqual(null, pathOf("", &b));
    // a NUL in it, a path longer than there is room for
    try testing.expectEqual(null, pathOf("file:///a%00b.bee", &b));
    var long: [300]u8 = @splat('a');
    @memcpy(long[0..8], "file:///");
    try testing.expectEqual(null, pathOf(&long, &b));
}

test "kinds by extension, in any case" {
    try testing.expectEqual(Kind.obj, kindOf("/a/b.OBJ"));
    try testing.expectEqual(Kind.stl, kindOf("/a/b.stl"));
    try testing.expectEqual(Kind.bee, kindOf("/a/b.c.bee"));
    try testing.expectEqual(Kind.image, kindOf("/a/b.JPeG"));
    try testing.expectEqual(Kind.unported, kindOf("/a/b.blend"));
    try testing.expectEqual(Kind.usd, kindOf("/a/b.USDA"));
    try testing.expectEqual(Kind.usd, kindOf("/a/b.usdc"));
    try testing.expectEqual(Kind.usd, kindOf("/a/b.usd"));
    try testing.expectEqual(Kind.gltf, kindOf("/a/b.GLB"));
    try testing.expectEqual(Kind.gltf, kindOf("/a/b.gltf"));
    try testing.expectEqual(Kind.unknown, kindOf("/a.bee/readme"));
    try testing.expectEqual(Kind.unknown, kindOf("/a/b.txt"));
}
