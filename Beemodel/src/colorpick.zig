// The colour picker: a click on a colour field opens it under the field, a
// Zui popup with Zui's picker (a saturation x value square and a hue strip,
// the old and new colour side by side, the hex code, R G B or H S V, the
// eyedropper: a click anywhere in the window takes the colour there), the
// last colours used (kept in the preferences) and the scene's own colours.
// A click outside or Esc closes it. A host client (zuihost.zig), modal: the
// rest of the window waits while it is open.
const std = @import("std");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const scene = @import("scene.zig");
const prefs = @import("prefs.zig");
const undo = @import("undo.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");

const Rect = gfx.Rect;

pub var open: bool = false;
/// The eyedropper waits for a click.
pub var picking: bool = false;
var target: *u32 = undefined;
var on_change: ?*const fn () void = null;
var title: []const u8 = "";
var old: u32 = 0;
var anchor_r: Rect = .{};
var opening = false;
const POPUP = "##colour picker";

/// Open the picker for colour `t`, under `anchor`.
pub fn openFor(t: *u32, anchor: Rect, name: []const u8, cb: ?*const fn () void) void {
    target = t;
    on_change = cb;
    title = name;
    old = t.*;
    anchor_r = anchor;
    open = true;
    picking = false;
    opening = true;
    app.dirty = true;
}

pub fn close() void {
    if (open and target.* != old) prefs.pushRecent(target.*);
    open = false;
    picking = false;
    const z = host.get();
    if (z.isPopupOpen(POPUP)) z.closeAllPopups();
    z.picker_state.picking = .none;
    app.dirty = true;
}

pub fn hsvToRgb(hh: f32, ss: f32, vv: f32) u32 {
    const c = vv * ss;
    const x = c * (1 - @abs(@mod(hh / 60, 2) - 1));
    const m = vv - c;
    const seg: u32 = @intFromFloat(@mod(@floor(hh / 60), 6));
    const rgb: [3]f32 = switch (seg) {
        0 => .{ c, x, 0 },
        1 => .{ x, c, 0 },
        2 => .{ 0, c, x },
        3 => .{ 0, x, c },
        4 => .{ x, 0, c },
        else => .{ c, 0, x },
    };
    var out: u32 = 0;
    for (rgb) |ch| out = (out << 8) | @as(u32, @intFromFloat(std.math.clamp((ch + m) * 255 + 0.5, 0, 255)));
    return out;
}

fn setColor(c: u32) void {
    if (target.* == c) return;
    target.* = c;
    undo.label(title);
    if (on_change) |f| f();
    app.dirty = true;
}

fn toZ(c: u32) zui.Color {
    return host.col(c);
}

fn fromZ(c: zui.Color) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

/// The picker, as a host client: modal (the window waits), the popup under
/// the field, closed by a click outside or Esc (Zui's).
pub const client: host.Client = .{
    .visible = shown,
    .describe = describe,
    .modal = true,
};

fn shown() bool {
    return open;
}

fn describe(z: *zui.Ui) void {
    if (opening) {
        opening = false;
        z.openPopupAt(POPUP, host.zr(anchor_r));
        z.picker_state.fresh = true; // (the old colour is this one)
    }
    z.pushMetric(.popup_padding, 10);
    defer z.popStyle();
    if (!z.beginPopup(POPUP, .{ .min_width = 300 })) {
        close();
        return;
    }
    defer z.endPopup();
    // the last colours used (the preferences'), the scene's own
    var recent: zui.RecentColors = .{};
    var k: usize = prefs.recent.len;
    while (k > 0) {
        k -= 1;
        if (prefs.recent[k] != 0) recent.add(toZ(prefs.recent[k] - 1));
    }
    var sc: [10]zui.Color = undefined;
    var n: usize = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (n >= sc.len) break;
        const c = toZ(o.color);
        const dup = for (sc[0..n]) |x| {
            if (x.eql(c)) break true;
        } else false;
        if (!dup) {
            sc[n] = c;
            n += 1;
        }
    }
    var c = toZ(target.*);
    const e = z.colorPicker("##colours", &c, .{ .alpha = false, .recent = &recent, .swatches = sc[0..n] });
    picking = z.picker_state.picking != .none;
    if (e.changed) setColor(fromZ(c));
}

/// Parse "#rrggbb" / "rrggbb" (spaces allowed).
pub fn parseHex(t: []const u8) ?u32 {
    const x = std.mem.trim(u8, t, " #");
    if (x.len != 6) return null;
    return std.fmt.parseInt(u32, x, 16) catch null;
}

/// A colour field: a swatch that opens the picker. Returns true on a change
/// (the picker changes it later; callers need not act).
pub fn field(wid: u32, r: Rect, c: *u32, name: []const u8, cb: ?*const fn () void) void {
    const th = ui.th;
    const cv = ui.cv;
    var hb: [8]u8 = undefined;
    ui.record("colour", name, r, true);
    @import("wg.zig").color(wid, r, c, cb);
    cv.fillRound(r, 4, c.*);
    cv.rectLine(r, if (open and target == c) th.accent else th.drop_border);
    if (ui.inside(r)) ui.tip(wid, r, name, std.fmt.bufPrint(&hb, "#{x:0>6}", .{c.*}) catch "", null);
    if (ui.press(wid, r, ui.LMB)) {
        ui.active = 0;
        openFor(c, r, name, cb);
    }
}
