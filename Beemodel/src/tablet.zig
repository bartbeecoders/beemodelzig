// Pen tablets (zwp_tablet_v2, as wayland.s): tools come and go on the tablet seat;
// a tool's events are collected until its frame, then given to the UI as pointer
// motion and the left button (stylus buttons: middle and right), with the pressure
// and the eraser end for the brushes (stroke.zig). Without a tablet nothing changes.
const std = @import("std");
const wl = @import("wayland.zig");

const MAX_TOOLS = 8;
const TOOL_ERASER = 0x141;
const BTN_STYLUS = 0x14b;
const BTN_STYLUS2 = 0x14c;
const CURSOR_MGR_GET_TABLET_TOOL = 2;
const CURSOR_SET_SHAPE = 1;

var mgr: u32 = 0;
var seat: u32 = 0;
const Tool = struct { id: u32 = 0, kind: u32 = 0x140, cdev: u32 = 0 };
var tools: [MAX_TOOLS]Tool = @splat(.{});

// what a frame collected: 1 moved, 2 down, 4 up
var ev: u32 = 0;
var x: f32 = 0;
var y: f32 = 0;
var pressure: f32 = 1;
var eraser = false;

pub fn global(w: *wl.Window, name: u32, iface: []const u8) bool {
    if (!std.mem.eql(u8, iface, "zwp_tablet_manager_v2") or mgr != 0) return false;
    mgr = w.bind(name, iface, 1);
    return true;
}

/// Once there are a seat and a tablet manager: the tablet seat.
pub fn ready(w: *wl.Window) void {
    if (mgr == 0 or w.seat == 0 or seat != 0) return;
    seat = w.newId();
    w.req(mgr, 0, .{ seat, w.seat });
}

pub fn event(w: *wl.Window, obj: u32, op: u16, r: *wl.Window.Rd) bool {
    if (obj == seat and seat != 0) {
        if (op == 1) { // tool_added(id)
            const id = r.u();
            for (&tools) |*t| {
                if (t.id != 0) continue;
                t.* = .{ .id = id };
                if (w.cursor_mgr != 0) {
                    t.cdev = w.newId();
                    w.req(w.cursor_mgr, CURSOR_MGR_GET_TABLET_TOOL, .{ t.cdev, id });
                }
                break;
            }
        }
        return true;
    }
    for (&tools) |*t| {
        if (t.id != 0 and t.id == obj) {
            toolEvent(w, t, op, r);
            return true;
        }
    }
    return false;
}

fn toolEvent(w: *wl.Window, t: *Tool, op: u16, r: *wl.Window.Rd) void {
    switch (op) {
        0 => t.kind = r.u(), // type
        5 => t.* = .{}, // removed
        6 => { // proximity_in(serial, tablet, surface): the same cursor as the mouse's
            const serial = r.u();
            eraser = t.kind == TOOL_ERASER;
            w.push(.{ .pen = .{ .pressure = pressure, .eraser = eraser } });
            w.push(.pen_end);
            if (t.cdev != 0) w.req(t.cdev, CURSOR_SET_SHAPE, .{ serial, @intFromEnum(w.cursor) });
        },
        7 => eraser = false, // proximity_out
        8 => {
            w.last_serial = r.u();
            ev |= 2;
        },
        9 => ev |= 4,
        10 => { // motion(x, y) (fixed 24.8)
            x = @floor(r.fixed());
            y = @floor(r.fixed());
            ev |= 1;
        },
        11 => pressure = @as(f32, @floatFromInt(r.u())) / 65535.0,
        17 => { // button(serial, button, state)
            w.last_serial = r.u();
            const b = r.u();
            const st = r.u();
            const to: u32 = if (b == BTN_STYLUS) wl.BTN_MIDDLE else if (b == BTN_STYLUS2) wl.BTN_RIGHT else return;
            w.push(.{ .button = .{ .button = to, .pressed = st == 1 } });
        },
        18 => { // frame(time): what was collected
            const e = ev;
            ev = 0;
            if (e == 0) return;
            w.push(.{ .pen = .{ .pressure = pressure, .eraser = eraser } });
            if (e & 1 != 0) w.push(.{ .motion = .{ .x = x, .y = y } });
            if (e & 2 != 0) w.push(.{ .button = .{ .button = wl.BTN_LEFT, .pressed = true } });
            if (e & 4 != 0) w.push(.{ .button = .{ .button = wl.BTN_LEFT, .pressed = false } });
            w.push(.pen_end);
        },
        else => {},
    }
}
