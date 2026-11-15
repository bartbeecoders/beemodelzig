// What the window takes from the compositor beyond the core: each is optional,
// and without it the app runs as before. wayland.zig hands every global it does
// not know and every event here first.
const std = @import("std");
const wl = @import("wayland.zig");
const clipboard = @import("clipboard.zig");
const panelwin = @import("panelwin.zig");
const tablet = @import("tablet.zig");
pub const scale = @import("scale.zig");

const FSCALE_GET = 1;
const VIEWPORTER_GET = 1;
const VIEWPORT_DEST = 2;

// play mode's locked pointer (wnd_lock_pointer): the pointer kept in the
// window, its cursor hidden, its relative motion turning the view
var constraints: u32 = 0; // zwp_pointer_constraints_v1
var relmgr: u32 = 0; // zwp_relative_pointer_manager_v1
var locked: u32 = 0; // (play mode: the locked pointer, its relative motion)
var relptr: u32 = 0;
var lock_win: ?*wl.Window = null;

var fscale_mgr: u32 = 0;
var viewporter: u32 = 0;
var fscale: u32 = 0;
var viewport: u32 = 0;

pub fn global(w: *wl.Window, name: u32, iface: []const u8, ver: u32) void {
    if (clipboard.global(w, name, iface, ver)) return;
    if (tablet.global(w, name, iface)) return;
    if (std.mem.eql(u8, iface, "zwp_pointer_constraints_v1") and constraints == 0) {
        constraints = w.bind(name, iface, 1);
        lock_win = w;
        @import("play.zig").lock_fn = &lockPointer;
        @import("play.zig").unlock_fn = &unlockPointer;
    } else if (std.mem.eql(u8, iface, "zwp_relative_pointer_manager_v1") and relmgr == 0) {
        relmgr = w.bind(name, iface, 1);
    } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1") and fscale_mgr == 0) {
        fscale_mgr = w.bind(name, iface, 1);
    } else if (std.mem.eql(u8, iface, "wp_viewporter") and viewporter == 0) {
        viewporter = w.bind(name, iface, 1);
    }
}

/// The globals are known and the main surface exists.
pub fn ready(w: *wl.Window) void {
    clipboard.init(w);
    tablet.ready(w);
    // (the buffer's size is ours only with both)
    if (fscale_mgr == 0 or viewporter == 0) return;
    fscale = w.newId();
    w.req(fscale_mgr, FSCALE_GET, .{ fscale, w.surface });
    viewport = w.newId();
    w.req(viewporter, VIEWPORTER_GET, .{ viewport, w.surface });
}

/// Map the buffer onto the logical size.
pub fn beforeCommit(w: *wl.Window) void {
    if (viewport != 0) w.req(viewport, VIEWPORT_DEST, .{ w.width, w.height });
}

/// A viewport for another surface (the panels' windows), 0: none.
pub fn viewportFor(w: *wl.Window, surface: u32) u32 {
    if (viewporter == 0 or fscale == 0) return 0;
    const v = w.newId();
    w.req(viewporter, VIEWPORTER_GET, .{ v, surface });
    return v;
}

/// wnd_lock_pointer: true when the pointer is locked in the window, its cursor
/// hidden and its relative motion coming (the compositor has both).
fn lockPointer() bool {
    const w = lock_win orelse return false;
    if (constraints == 0 or relmgr == 0 or w.pointer == 0) return false;
    if (locked != 0) return true;
    locked = w.newId(); // lock_pointer(id, surface, pointer, region none, persistent)
    w.req(constraints, 1, .{ locked, w.surface, w.pointer, @as(u32, 0), @as(u32, 2) });
    relptr = w.newId(); // get_relative_pointer(id, pointer)
    w.req(relmgr, 1, .{ relptr, w.pointer });
    w.req(w.pointer, 0, .{ w.enter_serial, @as(u32, 0), @as(i32, 0), @as(i32, 0) }); // no cursor
    return true;
}

/// wnd_unlock_pointer: the pointer free again, its cursor back.
fn unlockPointer() void {
    const w = lock_win orelse return;
    if (locked == 0) return;
    w.req(locked, 0, .{});
    w.req(relptr, 0, .{});
    locked = 0;
    relptr = 0;
    if (w.cursor_dev != 0) w.req(w.cursor_dev, 1, .{ w.enter_serial, @intFromEnum(w.cursor) });
}

pub fn event(w: *wl.Window, obj: u32, op: u16, r: *wl.Window.Rd) bool {
    if (obj == 0) return false;
    if (obj == relptr) {
        // relative_motion(utime hi, lo, dx, dy, dx unaccelerated, dy unaccelerated)
        if (op == 0) {
            _ = r.u();
            _ = r.u();
            _ = r.i();
            _ = r.i();
            const ux: f32 = @floatFromInt(r.i());
            const uy: f32 = @floatFromInt(r.i());
            @import("play.zig").look(ux * (1.0 / 256.0), uy * (1.0 / 256.0));
        }
        return true;
    }
    if (obj == locked) return true; // (locked, unlocked)
    if (obj == fscale) {
        if (op == 0) {
            const s = r.u();
            if (s != 0 and s != scale.comp_s120) {
                scale.comp_s120 = s;
                w.push(.resize);
            }
        }
        return true;
    }
    if (tablet.event(w, obj, op, r)) return true;
    if (panelwin.event(w, obj, op, r)) return true;
    return clipboard.event(w, obj, op, r);
}
