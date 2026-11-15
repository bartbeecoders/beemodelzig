// Panels in windows of their own (dock.s pw_*, wayland.s): a floating panel
// can live in an xdg_toplevel of its own, for another monitor. It stays in its
// workspace's list of panels; the main window just does not draw it. Each
// window has its surface, buffers, depth and id buffers; the UI runs for it
// with app.frameWindow. Input says which window it is in through the pointer's
// enter event. Closing the window, or the dock button, docks the area back;
// switching workspaces brings the windows in as floating panels.
const std = @import("std");
const linux = std.os.linux;
const wl = @import("wayland.zig");
const gfx = @import("gfx.zig");
const app = @import("app.zig");
const scale = @import("scale.zig");
const wlext = @import("wlext.zig");

pub const MAX = 4;

const Slot = struct {
    node: i16 = -1,
    surface: u32 = 0,
    xdg: u32 = 0,
    top: u32 = 0,
    viewport: u32 = 0,
    frame_cb: u32 = 0,
    frame_pending: bool = false,
    configured: bool = false,
    w: i32 = 400,
    h: i32 = 300,
    pend_w: i32 = 0,
    pend_h: i32 = 0,
    mem_fd: i32 = -1,
    mem: [*]u8 = undefined,
    cap: usize = 0, // bytes a buffer
    pool: u32 = 0,
    buf: [2]u32 = .{ 0, 0 },
    cur_buf: usize = 0,
    zb: []f32 = &.{},
    ids: []u16 = &.{},
    canvas: gfx.Canvas = .{ .px = undefined, .w = 0, .h = 0, .clip = .{} },
};

var slots: [MAX]Slot = @splat(.{});
/// The window input is in (-1: the main one).
pub var cur: i32 = -1;
/// A window could not take a frame: when its callback comes, draw again.
var waiting = false;

fn win() ?*wl.Window {
    return app.win;
}

pub fn supported() bool {
    return app.win != null;
}

/// The window an area is in, -1: none.
pub fn slotOf(node: i16) i32 {
    for (&slots, 0..) |*s, i| {
        if (s.node == node) return @intCast(i);
    }
    return -1;
}

pub fn count() usize {
    var n: usize = 0;
    for (&slots) |*s| {
        if (s.node >= 0) n += 1;
    }
    return n;
}

/// Open a window for a floating panel: false when there is no room.
pub fn open(node: i16, w_: i32, h_: i32, title: []const u8) bool {
    const w = win() orelse return false;
    for (&slots) |*s| {
        if (s.node >= 0) continue;
        s.* = .{ .node = node, .w = w_, .h = h_ };
        s.surface = w.newId();
        w.req(w.compositor, 0, .{s.surface});
        s.viewport = wlext.viewportFor(w, s.surface);
        s.xdg = w.newId();
        w.req(w.wm_base, 2, .{ s.xdg, s.surface });
        s.top = w.newId();
        w.req(s.xdg, 1, .{s.top});
        var tb: [64]u8 = undefined;
        w.req(s.top, 2, .{wl.Window.Str{ .s = std.fmt.bufPrint(&tb, "BeeModel - {s}", .{title}) catch "BeeModel" }});
        w.req(s.top, 3, .{wl.Window.Str{ .s = "beemodel-zig" }});
        w.req(s.top, 8, .{ @as(u32, 220), @as(u32, 140) }); // set_min_size
        w.req(s.surface, 6, .{}); // commit: it asks for a configure
        w.flush() catch {};
        return true;
    }
    return false;
}

fn destroy(s: *Slot) void {
    const w = win() orelse return;
    const a = std.heap.page_allocator;
    for (s.buf) |b| {
        if (b != 0) w.req(b, 0, .{});
    }
    if (s.pool != 0) w.req(s.pool, 1, .{});
    w.req(s.top, 0, .{});
    w.req(s.xdg, 0, .{});
    w.req(s.surface, 0, .{});
    if (s.cap > 0) {
        _ = linux.munmap(s.mem, s.cap * 2);
        _ = linux.close(s.mem_fd);
    }
    if (s.zb.len > 0) {
        a.free(s.zb);
        a.free(s.ids);
    }
    s.* = .{};
}

/// The area's window goes; the area stays what it was (a floating panel).
pub fn closeNode(node: i16) void {
    const i = slotOf(node);
    if (i < 0) return;
    destroy(&slots[@intCast(i)]);
    if (cur == i) cur = -1;
}

pub fn closeAll() void {
    for (&slots) |*s| {
        if (s.node >= 0) destroy(s);
    }
    cur = -1;
}

fn ensure(s: *Slot, w: *wl.Window, need: usize) bool {
    if (need <= s.cap) return true;
    if (s.pool == 0) {
        const f = linux.memfd_create("beemodel-zig-panel", linux.MFD.CLOEXEC);
        if (linux.errno(f) != .SUCCESS) return false;
        s.mem_fd = @intCast(f);
    } else _ = linux.munmap(s.mem, s.cap * 2);
    s.cap = 0;
    if (linux.errno(linux.ftruncate(s.mem_fd, @intCast(need * 2))) != .SUCCESS) return false;
    const p = linux.mmap(null, need * 2, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, s.mem_fd, 0);
    if (linux.errno(p) != .SUCCESS) return false;
    s.mem = @ptrFromInt(p);
    s.cap = need;
    if (s.pool == 0) {
        s.pool = w.newId();
        w.req(w.shm, 0, .{ s.pool, wl.Window.Fd{ .fd = s.mem_fd }, @as(u32, @intCast(need * 2)) });
    } else w.req(s.pool, 2, .{@as(u32, @intCast(need * 2))});
    return true;
}

fn setCanvas(s: *Slot, px: [*]u32) bool {
    const pw = scale.px(s.w);
    const ph = scale.px(s.h);
    const n: usize = @intCast(pw * ph);
    if (s.zb.len < n) {
        const a = std.heap.page_allocator;
        if (s.zb.len > 0) {
            a.free(s.zb);
            a.free(s.ids);
            s.zb = &.{};
            s.ids = &.{};
        }
        s.zb = a.alloc(f32, n) catch return false;
        s.ids = a.alloc(u16, n) catch {
            a.free(s.zb);
            s.zb = &.{};
            return false;
        };
        @memset(s.ids, 0);
    }
    s.canvas = .{ .px = px, .w = pw, .h = ph, .clip = .{ .w = scale.units(pw), .h = scale.units(ph) }, .zbuf = s.zb.ptr, .ids = s.ids.ptr, .s = scale.q16(), .uw = scale.units(pw), .uh = scale.units(ph) };
    return true;
}

/// Draw every window that can take a frame (the main window just drew).
pub fn drawAll() void {
    const w = win() orelse return;
    for (&slots, 0..) |*s, i| {
        if (s.node < 0 or !s.configured) continue;
        if (s.frame_pending) {
            waiting = true;
            continue;
        }
        var b: usize = 0;
        while (b < 2 and s.buf[b] != 0) b += 1;
        if (b == 2) {
            waiting = true;
            continue;
        }
        const pw = scale.px(s.w);
        const ph = scale.px(s.h);
        if (!ensure(s, w, @intCast(pw * ph * 4))) continue;
        const px: [*]u32 = @ptrCast(@alignCast(s.mem + b * s.cap));
        if (!setCanvas(s, px)) continue;
        s.cur_buf = b;
        app.frameWindow(&s.canvas, s.node, @intCast(i));
        const id = w.newId();
        s.buf[b] = id;
        w.req(s.pool, 0, .{ id, @as(u32, @intCast(b * s.cap)), pw, ph, pw * 4, @as(u32, 1) });
        w.req(s.surface, 1, .{ id, @as(u32, 0), @as(u32, 0) });
        if (s.viewport != 0) w.req(s.viewport, 2, .{ s.w, s.h });
        w.req(s.surface, 2, .{ @as(i32, 0), @as(i32, 0), s.w, s.h });
        s.frame_cb = w.newId();
        w.req(s.surface, 3, .{s.frame_cb});
        w.req(s.surface, 6, .{});
        s.frame_pending = true;
    }
}

/// The canvas of the window input is in.
pub fn curCanvas() ?*gfx.Canvas {
    if (cur < 0) return null;
    const s = &slots[@intCast(cur)];
    if (s.node < 0 or s.zb.len == 0) return null;
    return &s.canvas;
}

pub fn curNode() i16 {
    return if (cur < 0) -1 else slots[@intCast(cur)].node;
}

/// The user moves / resizes the window (a press on its header or edge).
pub fn moveWindow(node: i16) bool {
    const i = slotOf(node);
    if (i < 0) return false;
    const w = win() orelse return false;
    w.req(slots[@intCast(i)].top, 5, .{ w.seat, w.last_serial });
    return true;
}

pub fn resizeWindow(node: i16, edges: u32) void {
    const i = slotOf(node);
    if (i < 0) return;
    const w = win() orelse return;
    w.req(slots[@intCast(i)].top, 6, .{ w.seat, w.last_serial, edges });
}

pub fn event(w: *wl.Window, obj: u32, op: u16, r: *wl.Window.Rd) bool {
    // the pointer's enter: which window it is in now
    if (obj == w.pointer and op == 0) {
        var c = r.*;
        _ = c.u();
        const sf = c.u();
        cur = -1;
        for (&slots, 0..) |*s, i| {
            if (s.node >= 0 and s.surface == sf) cur = @intCast(i);
        }
        return false;
    }
    for (&slots) |*s| {
        if (s.node < 0) continue;
        if (obj == s.xdg) {
            if (op == 0) {
                w.req(s.xdg, 4, .{r.u()}); // ack_configure
                if (s.pend_w > 0 and s.pend_h > 0) {
                    s.w = s.pend_w;
                    s.h = s.pend_h;
                }
                s.configured = true;
                app.dirty = true;
            }
            return true;
        }
        if (obj == s.top) {
            if (op == 0) {
                s.pend_w = r.i();
                s.pend_h = r.i();
            } else if (op == 1) {
                app.windowClosed(s.node);
            }
            return true;
        }
        if (obj == s.frame_cb and s.frame_cb != 0) {
            s.frame_pending = false;
            s.frame_cb = 0;
            if (waiting) {
                waiting = false;
                app.dirty = true;
            }
            return true;
        }
        if (obj == s.buf[0] or obj == s.buf[1]) {
            const b: usize = if (obj == s.buf[0]) 0 else 1;
            if (op == 0) {
                w.req(obj, 0, .{});
                s.buf[b] = 0;
            }
            return true;
        }
    }
    return false;
}
