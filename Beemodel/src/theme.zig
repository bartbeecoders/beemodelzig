// The active UI theme: one of the nine generated themes (themes.zig), with an
// optional accent colour of your own on top.
const std = @import("std");
const themes = @import("themes.zig");

pub const Theme = themes.Theme;
pub const all = themes.all;
pub const dark = &themes.dark;

/// The theme the UI draws with (a copy, so the accent can be changed).
pub var cur: Theme = themes.dark;

pub fn init() void {
    set(&themes.dark);
}
/// The theme `cur` was made from.
pub var base: *const Theme = &themes.dark;
/// The accent chosen in the preferences, or null for the theme's own.
pub var accent: ?u32 = null;

pub fn set(t: *const Theme) void {
    base = t;
    apply();
}

/// Colour-blind-safe axes: orange, sky blue and purple (Okabe-Ito).
pub var colorblind: bool = false;

pub fn setColorblind(on: bool) void {
    colorblind = on;
    apply();
}

pub fn setAccent(c: ?u32) void {
    accent = c;
    apply();
}

fn apply() void {
    cur = base.*;
    if (accent) |a| {
        cur.accent = a;
        cur.split_hot = a;
        cur.accent_text = readableOn(a);
        cur.accent_dark = mixRaw(a, cur.pane_bg, 150);
        cur.selection = mixRaw(a, cur.field, 170);
    }
    if (colorblind) {
        cur.axis_x = 0xe69f00;
        cur.axis_y = 0x56b4e9;
        cur.axis_z = 0xcc79a7;
    }
    const dark_ui = luminance(cur.pane_bg) < 0.2;
    // the accent as text: at least 4.5:1 on panels and the title bar
    cur.accent_fg = towards(cur.accent, cur.text, cur.pane_bg, 4.5);
    cur.accent_fg = towards(cur.accent_fg, cur.text, cur.title_bg, 4.5);
    // greyed text: at least 3:1 on menus and on a hovered row
    cur.text_off = towards(cur.text_off, cur.text, cur.drop_bg, 3.0);
    cur.text_off = towards(cur.text_off, cur.text, cur.hover, 3.0);
    // fields, check boxes: visible on the panels (light themes have white on white)
    if (contrast(cur.field, cur.pane_bg) < 1.12) {
        cur.field = mixRaw(cur.pane_bg, 0x000000, 22);
        cur.field_hover = mixRaw(cur.pane_bg, 0x000000, 34);
    }
    if (contrast(cur.input_bg, cur.pane_bg) < 1.12) cur.input_bg = cur.field;
    // the ground grid must not fade into the bottom of the viewport
    cur.grid = towards(cur.grid, cur.text, cur.canvas_bot, 1.5);
    cur.grid_major = towards(cur.grid_major, cur.text, cur.canvas_bot, 2.0);
    // objects in wireframe, the camera and lights: visible on the viewport
    cur.obj_wire = if (dark_ui) 0x9aa1ad else 0x3a3f48;
    cur.obj_wire = towards(cur.obj_wire, cur.text, cur.canvas_bot, 3.0);
    cur.cam_col = towards(if (dark_ui) 0x6aa8e8 else 0x2a6fb8, cur.text, cur.canvas_top, 3.0);
    cur.lamp_col = towards(if (dark_ui) 0xf0d890 else 0x9a6a00, cur.text, cur.canvas_top, 3.0);
}

/// Move colour c towards `to` until it has contrast `want` against bg.
fn towards(c: u32, to: u32, bg: u32, want: f32) u32 {
    var x = c;
    var t: u32 = 0;
    while (contrast(x, bg) < want and t < 256) {
        t += 16;
        x = mixRaw(c, to, @min(t, 256));
    }
    if (contrast(x, bg) < want) {
        // the text colour itself is not enough: go to black or white
        x = readableOn(bg);
    }
    return x;
}

pub fn byId(id: []const u8) ?*const Theme {
    for (all) |t| {
        if (std.ascii.eqlIgnoreCase(t.id, id) or std.ascii.eqlIgnoreCase(t.name, id)) return t;
    }
    return null;
}

// --- colour helpers -----------------------------------------------------

fn mixRaw(a: u32, b: u32, t: u32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const x = (a >> sh) & 255;
        const y = (b >> sh) & 255;
        out |= ((x * (256 - t) + y * t) >> 8) << sh;
    }
    return out;
}

fn channel(v: u32) f32 {
    const c: f32 = @as(f32, @floatFromInt(v)) / 255.0;
    return if (c <= 0.03928) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

pub fn luminance(c: u32) f32 {
    return 0.2126 * channel((c >> 16) & 255) + 0.7152 * channel((c >> 8) & 255) + 0.0722 * channel(c & 255);
}

pub fn contrast(a: u32, b: u32) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// Near-black or white, whichever reads better on `bg`.
pub fn readableOn(bg: u32) u32 {
    return if (contrast(bg, 0x1b1d23) >= contrast(bg, 0xffffff)) 0x1b1d23 else 0xffffff;
}
