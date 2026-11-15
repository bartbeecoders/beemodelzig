// Immediate-mode UI core. The whole UI is one function (app.frame) that runs
// in two passes: a hit pass on every input event (canvas disabled, widgets
// react to presses/drags) and a draw pass per displayed frame.
const std = @import("std");
const gfx = @import("gfx.zig");
const theme = @import("theme.zig");
const wl = @import("wayland.zig");
const wg = @import("wg.zig");
const clipboard = @import("clipboard.zig");

const Rect = gfx.Rect;

pub const L_BASE: u8 = 0;
pub const L_FLOAT: u8 = 1; // + float index
pub const L_POPUP: u8 = 100;
pub const L_DIALOG: u8 = 200;

pub const LMB: u8 = 1;
pub const MMB: u8 = 2;
pub const RMB: u8 = 4;

pub var cv: *gfx.Canvas = undefined;
pub var th: *const theme.Theme = &theme.cur;
/// Milliseconds now (set by the app before each pass).
pub var now_ms: i64 = 0;

pub var mx: i32 = -1000;
pub var my: i32 = -1000;
pub var dx: i32 = 0;
pub var dy: i32 = 0;
pub var down: u8 = 0;
pub var pressed: u8 = 0;
pub var released: u8 = 0;
pub var dbl: bool = false;
pub var wheel: f32 = 0;
pub var mods: u32 = 0;
pub var hit: bool = false;

pub var layer: u8 = L_BASE;
pub var hot_layer: u8 = L_BASE;
pub var active: u32 = 0;
pub var active_layer: u8 = L_BASE;
pub var press_x: i32 = 0;
pub var press_y: i32 = 0;
/// The pointer moved far enough since the press to count as a drag.
pub var moved: bool = false;
pub var cursor: wl.Cursor = .default;

// Text editing (one field at a time)
pub var edit_id: u32 = 0;
pub var edit_buf: [512]u8 = undefined;
pub var edit_len: usize = 0;
pub var edit_caret: usize = 0;
pub var edit_anchor: usize = 0; // the other end of the selection
pub var edit_submit: bool = false;

pub fn id(comptime src: std.builtin.SourceLocation, salt: usize) u32 {
    const base: u32 = comptime (src.line *% 2654435761) ^ (src.column *% 40503);
    var h = base ^ @as(u32, @truncate(salt *% 0x9e3779b1));
    if (h == 0) h = 1;
    return h;
}

pub fn shift() bool {
    return mods & wl.MOD_SHIFT != 0;
}
pub fn ctrl() bool {
    return mods & wl.MOD_CTRL != 0;
}

pub fn inside(r: Rect) bool {
    if (mask) |k| {
        if (!k.contains(mx, my)) return false;
    }
    return layer == hot_layer and r.contains(mx, my);
}

/// While set: nothing outside it takes the pointer (a list scrolled under its header).
pub var mask: ?Rect = null;

pub fn hover(wid: u32, r: Rect) bool {
    return inside(r) and (active == 0 or active == wid);
}

/// Pointer pressed on r with one of the `btn` buttons: becomes the active widget.
pub fn press(wid: u32, r: Rect, btn: u8) bool {
    if (btn & LMB != 0) wg.add(wid, r);
    return pressDrag(wid, r, btn);
}

/// press() for what the keyboard's focus should skip (handles, drags).
pub fn pressDrag(wid: u32, r: Rect, btn: u8) bool {
    if (hit and wg.activate_id == wid) {
        wg.activate_id = 0;
        return true;
    }
    if (!hit or pressed & btn == 0 or !inside(r) or active != 0) return false;
    active = wid;
    active_layer = layer;
    press_x = mx;
    press_y = my;
    moved = false;
    return true;
}

/// The active widget's button came up this event.
pub fn releasedOn(wid: u32) bool {
    return hit and released != 0 and active == wid;
}

pub fn isActive(wid: u32) bool {
    return active == wid;
}

// --- widgets ------------------------------------------------------------

// --- tooltips -----------------------------------------------------------
//
// A hovered widget offers its tooltip; once the pointer has rested on the
// same widget for tip_delay ms, the app draws it above everything.

pub var tip_delay: i64 = 600;
pub var tip_id: u32 = 0; // the widget whose tip is pending / shown
pub var tip_since: i64 = 0;
pub var tip_rect: Rect = .{};
/// Show the tip to the right of its widget (menu rows) instead of below it.
pub var tip_beside: bool = false;
pub var tip_title: [64]u8 = undefined;
pub var tip_title_len: usize = 0;
pub var tip_body: [256]u8 = undefined;
pub var tip_body_len: usize = 0;
pub var tip_warn: [96]u8 = undefined;
pub var tip_warn_len: usize = 0;
var tip_seen: u32 = 0; // offered during this pass

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// Offer a tooltip for a hovered widget: a title, what it does, and (greyed
/// widgets) why it cannot be used now.
pub fn tip(wid: u32, r: Rect, title: []const u8, body: []const u8, warn: ?[]const u8) void {
    tip_seen = wid;
    if (tip_id == wid) return;
    tip_id = wid;
    tip_since = now_ms;
    tip_rect = r;
    tip_beside = beside_next;
    tip_title_len = copyInto(&tip_title, title);
    tip_body_len = copyInto(&tip_body, body);
    tip_warn_len = if (warn) |w| copyInto(&tip_warn, w) else 0;
}

var beside_next: bool = false;

/// Like tip(), shown beside the widget (rows of a menu or list).
pub fn tipBeside(wid: u32, r: Rect, title: []const u8, body: []const u8, warn: ?[]const u8) void {
    beside_next = true;
    tip(wid, r, title, body, warn);
    beside_next = false;
}

/// Called before each pass.
pub fn tipBegin() void {
    tip_seen = 0;
}

/// Called after each pass: a tip nobody offered this time goes away.
pub fn tipEnd() void {
    if (tip_seen == 0 or down != 0) tip_id = 0;
}

pub fn tipVisible() bool {
    return tip_id != 0 and down == 0 and now_ms - tip_since >= tip_delay;
}

// --- widget record (ui_tree, for tests and agents) -----------------------

pub const Rec = struct { kind: []const u8, label: [48]u8, len: u8, r: Rect, enabled: bool };
pub var rec: [1024]Rec = undefined;
pub var rec_n: usize = 0;

pub fn record(kind: []const u8, label: []const u8, r: Rect, enabled: bool) void {
    if (!cv.enabled or rec_n >= rec.len) return;
    var e = Rec{ .kind = kind, .label = undefined, .len = 0, .r = r.intersect(cv.clip), .enabled = enabled };
    e.len = @intCast(copyInto(&e.label, label));
    if (e.r.w <= 0 or e.r.h <= 0) return;
    rec[rec_n] = e;
    rec_n += 1;
}

pub const BtnOpts = struct {
    selected: bool = false,
    enabled: bool = true,
    center: bool = true,
    flat: bool = false,
    radius: i32 = 4,
    key: []const u8 = "",
    tip: []const u8 = "",
    why: ?[]const u8 = null,
    /// on as the original's toggles and tabs: dark accent fill, gold text
    soft: bool = false,
};

pub fn button(wid: u32, r: Rect, label: []const u8, o: BtnOpts) bool {
    record("button", label, r, o.enabled);
    if (inside(r) and (active == 0 or active == wid) and (o.tip.len > 0 or o.why != null)) tip(wid, r, label, o.tip, if (o.enabled) null else o.why);
    const hv = o.enabled and hover(wid, r);
    const bg = if (o.selected) (if (o.soft) th.accent_dark else th.accent) else if (hv) th.btn_hover else if (o.flat) 0xffffffff else th.btn;
    if (bg != 0xffffffff) cv.fillRound(r, o.radius, bg);
    const fg = if (!o.enabled) th.text_off else if (o.selected) (if (o.soft) th.accent_fg else th.accent_text) else th.text;
    if (o.center) cv.textCentered(r, label, fg) else cv.textIn(r, 8, label, fg);
    if (o.key.len > 0 and gfx.textWidth(label) + gfx.textWidth(o.key) + 28 <= r.w) cv.textRight(r, 8, o.key, if (o.selected and !o.soft) th.accent_text else th.text_dim);
    return o.enabled and press(wid, r, LMB);
}

pub fn checkbox(wid: u32, r: Rect, label: []const u8, v: *bool) bool {
    record("checkbox", label, r, true);
    const box = Rect{ .x = r.x, .y = r.y + @divTrunc(r.h - 14, 2), .w = 14, .h = 14 };
    const hv = hover(wid, r);
    cv.fillRound(box, 3, if (v.*) th.accent else if (hv) th.btn_hover else th.field);
    if (v.*) {
        cv.thickLine(box.x + 3, box.y + 7, box.x + 6, box.y + 10, th.accent_text);
        cv.thickLine(box.x + 6, box.y + 10, box.x + 10, box.y + 3, th.accent_text);
    }
    cv.textIn(.{ .x = r.x + 20, .y = r.y, .w = r.w - 20, .h = r.h }, 0, label, th.text);
    if (press(wid, r, LMB)) {
        v.* = !v.*;
        return true;
    }
    return false;
}

fn beginEdit(wid: u32, text: []const u8) void {
    editSet(wid, text, true);
}

/// Start editing field `wid` with `text`, all of it selected or the caret at the end.
pub fn editSet(wid: u32, text: []const u8, select_all: bool) void {
    edit_id = wid;
    const n = @min(text.len, edit_buf.len);
    @memcpy(edit_buf[0..n], text[0..n]);
    edit_len = n;
    edit_caret = n;
    edit_anchor = if (select_all) 0 else n;
    edit_submit = false;
}

fn selLo() usize {
    return @min(edit_anchor, edit_caret);
}
fn selHi() usize {
    return @max(edit_anchor, edit_caret);
}

fn drawEdit(r: Rect, align_center: bool) void {
    cv.fillRound(r, 3, th.field);
    cv.rectLine(r, th.focus);
    const s = edit_buf[0..edit_len];
    const tw = gfx.textWidth(s);
    var x0 = if (align_center and tw < r.w - 12) r.x + @divTrunc(r.w - tw, 2) else r.x + 6;
    // keep the caret in view
    const cx = gfx.textWidth(s[0..edit_caret]);
    if (x0 + cx > r.right() - 6) x0 = r.right() - 6 - cx;
    const ty = r.y + @divTrunc(r.h - gfx.glyph_h, 2);
    const old = cv.setClip(r.inset(2).intersect(cv.clip));
    defer cv.clip = old;
    if (selHi() > selLo()) {
        const sx = x0 + gfx.textWidth(s[0..selLo()]);
        cv.fill(.{ .x = sx, .y = ty, .w = gfx.textWidth(s[selLo()..selHi()]), .h = gfx.glyph_h }, th.selection);
    }
    _ = cv.text(x0, ty, s, th.text);
    cv.fill(.{ .x = x0 + cx, .y = ty, .w = 1, .h = gfx.glyph_h }, th.focus);
}

/// wg_commit: what a number field takes from the text typed in it. The
/// original's expr_eval (cad.eval: the parameters, lengths in scene units,
/// angles in radians); null (logged "not a value: ...") when it fails. A
/// degree field (WGF_DEG) holds degrees here: a plain number is degrees, one
/// with a letter (a unit: "1.2rad", "90deg", "pi/2") is radians (has_letter).
pub fn fieldValue(text: []const u8, deg: bool) ?f32 {
    const x = @import("cad.zig").eval(text) orelse {
        @import("app.zig").log("not a value: {s}", .{text});
        return null;
    };
    const d = if (deg and hasLetter(text)) x * (180.0 / std.math.pi) else x;
    return @floatCast(d);
}

/// has_letter: a letter (a unit) anywhere in the text.
pub fn hasLetter(text: []const u8) bool {
    for (text) |c| {
        if ((c | 0x20) -% 'a' < 26) return true;
    }
    return false;
}

/// The next numField is a degree field (WGF_DEG): see fieldValue.
pub var deg_field: bool = false;

/// numField for a value in degrees (the original's WGF_DEG fields).
pub fn numFieldDeg(wid: u32, r: Rect, v: *f32, step: f32, suffix: []const u8) bool {
    deg_field = true;
    defer deg_field = false;
    return numField(wid, r, v, step, suffix);
}

/// Numeric field: drag sideways to change (Shift finer, Ctrl in whole
/// steps), Ctrl+wheel steps it, click to type a value or an expression.
pub fn numField(wid: u32, r: Rect, v: *f32, step: f32, suffix: []const u8) bool {
    var rb: [32]u8 = undefined;
    record("number", fmtNum(&rb, v.*, suffix), r, true);
    wg.number(wid, r, v.*, step, -std.math.inf(f32), std.math.inf(f32), false, "");
    if (edit_id == wid) {
        drawEdit(r, true);
        if (hit and edit_submit) {
            edit_submit = false;
            edit_id = 0;
            if (fieldValue(edit_buf[0..edit_len], deg_field)) |val| {
                v.* = val;
                return true;
            } else return false;
        }
        if (hit and pressed != 0 and !inside(r)) edit_id = 0;
        return false;
    }
    const hv = hover(wid, r);
    cv.fillRound(r, 3, if (active == wid) th.btn_hover else if (hv) th.field_hover else th.field);
    var buf: [32]u8 = undefined;
    var s = fmtNum(&buf, v.*, suffix);
    if (gfx.textWidth(s) > r.w - 6) s = fmtNum(&buf, v.*, ""); // no room for the unit
    const old = cv.setClip(r.intersect(cv.clip));
    if (gfx.textWidth(s) > r.w - 4) {
        _ = cv.textFit(r.x + 2, r.y + @divTrunc(r.h - gfx.glyph_h, 2), r.w - 4, s, th.text);
    } else cv.textCentered(r, s, th.text);
    cv.clip = old;
    if (hv) cursor = .ew_resize;
    if (press(wid, r, LMB)) drag_acc = v.*;
    var changed = false;
    if (hit and active == wid) {
        if (moved and dx != 0) {
            const fine: f32 = if (shift()) 0.1 else 1.0;
            drag_acc += @as(f32, @floatFromInt(dx)) * step * fine;
            // Ctrl: whole steps of ten times the drag step (1 for degrees)
            const snap = if (step >= 1) 5.0 else step * 10;
            const nv = if (ctrl()) @round(drag_acc / snap) * snap else drag_acc;
            if (nv != v.*) {
                v.* = nv;
                changed = true;
            }
        }
        if (released & LMB != 0 and !moved) beginEdit(wid, fmtNum(&buf, v.*, ""));
    }
    if (hit and wheel != 0 and ctrl() and inside(r) and active == 0) {
        v.* += (if (wheel < 0) step * 10 else -step * 10) * (if (shift()) @as(f32, 0.1) else 1);
        changed = true;
    }
    return changed;
}

/// A number with up to `dec` decimals, trailing zeros dropped (the original's value_text).
pub fn fmtDec(buf: []u8, v: f32, dec: u8) []const u8 {
    if (!std.math.isFinite(v) or @abs(v) >= 1e12) return fmtNum(buf, v, "");
    const s = switch (dec) {
        0 => std.fmt.bufPrint(buf, "{d:.0}", .{v}),
        1 => std.fmt.bufPrint(buf, "{d:.1}", .{v}),
        2 => std.fmt.bufPrint(buf, "{d:.2}", .{v}),
        // (the cloth compliances' fields: 5 and 6 decimals, simui.s)
        5 => std.fmt.bufPrint(buf, "{d:.5}", .{v}),
        6 => std.fmt.bufPrint(buf, "{d:.6}", .{v}),
        else => std.fmt.bufPrint(buf, "{d:.3}", .{v}),
    } catch return "?";
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var n = s.len;
    while (s[n - 1] == '0') n -= 1;
    if (s[n - 1] == '.') n -= 1;
    if (n == 2 and s[0] == '-' and s[1] == '0') return "0";
    return s[0..n];
}

/// The original's labelled number field (widgets.s): the label dim on the
/// left, the value on the right; a slider fills the part up to its value.
/// Drag sideways to change (Shift finer, Ctrl in steps), click to type a
/// value or an expression. Clamped to lo .. hi.
pub fn valueField(wid: u32, r: Rect, v: *f32, label: []const u8, o: struct { step: f32, lo: f32, hi: f32, dec: u8 = 3, slider: bool = false, tip: []const u8 = "", compact: bool = false, deg: bool = false, center: bool = false, fit: bool = true, suffix: []const u8 = "" }) bool {
    var vb: [32]u8 = undefined;
    const vn = fmtDec(&vb, v.*, o.dec);
    // (a unit after the value: WGF_DEG's degree sign; not in the text to edit)
    var sb: [40]u8 = undefined;
    const vs = if (o.suffix.len > 0) (std.fmt.bufPrint(&sb, "{s}{s}", .{ vn, o.suffix }) catch vn) else vn;
    record(if (o.slider) "slider" else "number", label, r, true);
    wg.number(wid, r, v.*, o.step, o.lo, o.hi, o.dec == 0, label);
    if (inside(r) and o.tip.len > 0 and (active == 0 or active == wid) and edit_id != wid) tip(wid, r, label, o.tip, null);
    if (edit_id == wid) {
        drawEdit(r, true);
        if (hit and edit_submit) {
            edit_submit = false;
            edit_id = 0;
            if (fieldValue(edit_buf[0..edit_len], o.deg)) |val| {
                if (!std.math.isFinite(val)) return false;
                v.* = std.math.clamp(val, o.lo, o.hi);
                return true;
            } else return false;
        }
        if (hit and pressed != 0 and !inside(r)) edit_id = 0;
        return false;
    }
    const hv = hover(wid, r);
    cv.fillRound(r, 4, if (active == wid) th.btn_hover else if (hv) th.field_hover else th.field);
    if (o.slider and o.hi > o.lo) {
        const f = std.math.clamp((v.* - o.lo) / (o.hi - o.lo), 0, 1);
        const fw: i32 = @intFromFloat(f * @as(f32, @floatFromInt(r.w)));
        if (fw > 0) cv.fillRound(.{ .x = r.x, .y = r.y, .w = fw, .h = r.h }, 4, th.accent_dark);
    }
    const ty = r.y + @divTrunc(r.h - gfx.glyph_h, 2);
    const vw = gfx.textWidth(vs);
    // (fit: cut short of the value; else whole and unclipped, the value over
    // it - widgets.s draws a field's label so)
    if (!o.compact and !o.fit) _ = cv.text(r.x + 7, ty, label, th.text_dim);
    const old = cv.setClip(r.intersect(cv.clip));
    if (!o.compact and o.fit) _ = cv.textFit(r.x + 7, ty, r.w - vw - 18, label, th.text_dim);
    // (widgets.s: the value right-aligned after a label, centred without one)
    _ = cv.text(if (o.center) r.x + (r.w - vw >> 1) else r.right() - 7 - vw, ty, vs, th.text);
    cv.clip = old;
    if (hv) cursor = .ew_resize;
    if (press(wid, r, LMB)) drag_acc = v.*;
    var changed = false;
    if (hit and active == wid) {
        if (moved and dx != 0) {
            const fine: f32 = if (shift()) 0.1 else 1.0;
            drag_acc = std.math.clamp(drag_acc + @as(f32, @floatFromInt(dx)) * o.step * fine, o.lo, o.hi);
            const snap = if (o.step >= 1) o.step else o.step * 10;
            const nv = std.math.clamp(if (ctrl()) @round(drag_acc / snap) * snap else drag_acc, o.lo, o.hi);
            if (nv != v.*) {
                v.* = nv;
                changed = true;
            }
        }
        if (released & LMB != 0 and !moved) beginEdit(wid, vn);
    }
    if (hit and wheel != 0 and ctrl() and inside(r) and active == 0) {
        v.* = std.math.clamp(v.* + (if (wheel < 0) o.step * 10 else -o.step * 10) * (if (shift()) @as(f32, 0.1) else 1), o.lo, o.hi);
        changed = true;
    }
    return changed;
}

/// Text field: click to edit, Enter commits. Returns the new text on commit.
pub fn textField(wid: u32, r: Rect, text: []const u8, placeholder: []const u8) ?[]const u8 {
    record("text", if (text.len > 0) text else placeholder, r, true);
    wg.text(wid, r, text);
    if (edit_id == wid) {
        drawEdit(r, false);
        if (hit and edit_submit) {
            edit_submit = false;
            edit_id = 0;
            return edit_buf[0..edit_len];
        }
        if (hit and pressed != 0 and !inside(r)) edit_id = 0;
        return null;
    }
    const hv = hover(wid, r);
    cv.fillRound(r, 3, if (hv) th.field_hover else th.field);
    if (text.len > 0) cv.textIn(r, 6, text, th.text) else cv.textIn(r, 6, placeholder, th.text_off);
    if (hv) cursor = .text;
    if (press(wid, r, LMB)) beginEdit(wid, text);
    return null;
}

var drag_acc: f32 = 0;

pub fn fmtNum(buf: []u8, v: f32, suffix: []const u8) []const u8 {
    if (std.math.isNan(v) or std.math.isInf(v) or @abs(v) >= 1e12) return std.fmt.bufPrint(buf, "{e:.3}{s}", .{ v, suffix }) catch "?";
    const r = @round(v * 1000.0) / 1000.0;
    const s = if (r == @round(r))
        std.fmt.bufPrint(buf, "{d}{s}", .{ @as(i64, @intFromFloat(r)), suffix }) catch "?"
    else
        std.fmt.bufPrint(buf, "{d:.2}{s}", .{ r, suffix }) catch "?";
    return s;
}

// --- keyboard -----------------------------------------------------------

/// Characters for evdev key codes on a US layout (no XKB parsing yet).
const lower = "\x00\x001234567890-=\x00\x00qwertyuiop[]\x00\x00asdfghjkl;'`\x00\\zxcvbnm,./";
const upper = "\x00\x00!@#$%^&*()_+\x00\x00QWERTYUIOP{}\x00\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?";

pub fn keyChar(code: u32, shifted: bool) u8 {
    if (code == 57) return ' ';
    if (code >= lower.len) return 0;
    return if (shifted) upper[code] else lower[code];
}

pub const KEY = struct {
    pub const ESC = 1;
    pub const MINUS = 12;
    pub const BACKSPACE = 14;
    pub const TAB = 15;
    pub const Q = 16;
    pub const W = 17;
    pub const E = 18;
    pub const R = 19;
    pub const T = 20;
    pub const Y = 21;
    pub const I = 23;
    pub const O = 24;
    pub const ENTER = 28;
    pub const LEFTCTRL = 29;
    pub const A = 30;
    pub const S = 31;
    pub const D = 32;
    pub const F = 33;
    pub const G = 34;
    pub const H = 35;
    pub const LEFTSHIFT = 42;
    pub const Z = 44;
    pub const X = 45;
    pub const N = 49;
    pub const DOT = 52;
    pub const RIGHTSHIFT = 54;
    pub const LEFTALT = 56;
    pub const SPACE = 57;
    pub const F1 = 59;
    pub const F2 = 60;
    pub const F3 = 61;
    pub const F6 = 64;
    pub const F10 = 68;
    pub const KP7 = 71;
    pub const KP8 = 72;
    pub const KP9 = 73;
    pub const KPMINUS = 74;
    pub const KP4 = 75;
    pub const KP5 = 76;
    pub const KP6 = 77;
    pub const KP1 = 79;
    pub const KP2 = 80;
    pub const KP3 = 81;
    pub const KP0 = 82;
    pub const KPDOT = 83;
    pub const KPENTER = 96;
    pub const RIGHTCTRL = 97;
    pub const RIGHTALT = 100;
    pub const HOME = 102;
    pub const UP = 103;
    pub const PAGEUP = 104;
    pub const LEFT = 105;
    pub const RIGHT = 106;
    pub const END = 107;
    pub const DOWN = 108;
    pub const PAGEDOWN = 109;
    pub const DELETE = 111;
};

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

fn wordLeft(from: usize) usize {
    var i = from;
    while (i > 0 and !isWord(edit_buf[i - 1])) i -= 1;
    while (i > 0 and isWord(edit_buf[i - 1])) i -= 1;
    return i;
}

fn wordRight(from: usize) usize {
    var i = from;
    while (i < edit_len and !isWord(edit_buf[i])) i += 1;
    while (i < edit_len and isWord(edit_buf[i])) i += 1;
    return i;
}

fn deleteRange(lo: usize, hi: usize) void {
    if (hi <= lo) return;
    std.mem.copyForwards(u8, edit_buf[lo .. edit_len - (hi - lo)], edit_buf[hi..edit_len]);
    edit_len -= hi - lo;
    edit_caret = lo;
    edit_anchor = lo;
}

fn insertText(t: []const u8) void {
    deleteRange(selLo(), selHi());
    const n = @min(t.len, edit_buf.len - edit_len);
    if (n == 0) return;
    std.mem.copyBackwards(u8, edit_buf[edit_caret + n .. edit_len + n], edit_buf[edit_caret..edit_len]);
    @memcpy(edit_buf[edit_caret .. edit_caret + n], t[0..n]);
    edit_len += n;
    edit_caret += n;
    edit_anchor = edit_caret;
}

fn moveCaret(to: usize) void {
    edit_caret = to;
    if (!shift()) edit_anchor = to;
}

/// Feed a key press to the field being edited. Returns true if it was consumed.
pub fn editKey(code: u32) bool {
    if (edit_id == 0) return false;
    const has_sel = selHi() > selLo();
    switch (code) {
        KEY.ESC => edit_id = 0,
        KEY.ENTER, KEY.KPENTER => edit_submit = true,
        KEY.LEFT => moveCaret(if (ctrl()) wordLeft(edit_caret) else if (has_sel and !shift()) selLo() else edit_caret -| 1),
        KEY.RIGHT => moveCaret(if (ctrl()) wordRight(edit_caret) else if (has_sel and !shift()) selHi() else @min(edit_len, edit_caret + 1)),
        KEY.HOME => moveCaret(0),
        KEY.END => moveCaret(edit_len),
        KEY.BACKSPACE => {
            if (has_sel) deleteRange(selLo(), selHi()) else if (ctrl()) deleteRange(wordLeft(edit_caret), edit_caret) else if (edit_caret > 0) deleteRange(edit_caret - 1, edit_caret);
        },
        KEY.DELETE => {
            if (has_sel) deleteRange(selLo(), selHi()) else if (ctrl()) deleteRange(edit_caret, wordRight(edit_caret)) else if (edit_caret < edit_len) deleteRange(edit_caret, edit_caret + 1);
        },
        else => {
            if (ctrl()) {
                switch (code) {
                    KEY.A => {
                        edit_anchor = 0;
                        edit_caret = edit_len;
                    },
                    46, 45 => { // C, X (no selection: everything is copied)
                        clipboard.copy(if (has_sel) edit_buf[selLo()..selHi()] else edit_buf[0..edit_len]);
                        if (code == 45) deleteRange(selLo(), selHi());
                    },
                    47 => { // V: one line, breaks and tabs become spaces
                        var pb: [512]u8 = undefined;
                        const got = clipboard.paste(&pb);
                        for (pb[0..got]) |*c| {
                            if (c.* < 0x20) c.* = ' ';
                        }
                        if (got > 0) insertText(pb[0..got]);
                    },
                    else => {},
                }
                return true;
            }
            // the layout's character (AltGr levels, caps lock, dead keys)
            const cp = @import("keyboard.zig").char(code, mods);
            if (cp < 0x20 or cp == 0x7f) return true;
            var ub: [4]u8 = undefined;
            insertText(@import("keyboard.zig").utf8(cp, &ub));
        },
    }
    return true;
}
