//! Themes built from a few base colours, the presets, a contrast check and
//! a preview strip for theme lists.
//!
//!     ui.style = zui.theme.build(.{
//!         .background = .hex(0x1B1D22),
//!         .text = .hex(0xE8E8EA),
//!         .accent = .hex(0xE0873A),
//!     });
//!
//! Every derived colour is checked as it is made: text keeps 4.5:1 against
//! each surface it sits on, and text on the accent is black or white,
//! whichever reads better. `contrastProblems` checks any style, built or
//! hand-made.

const std = @import("std");
const draw = @import("draw.zig");
const style_mod = @import("style.zig");
const color = @import("color.zig");
const ui_mod = @import("ui.zig");
const Ui = ui_mod.Ui;
const Interaction = ui_mod.Interaction;
const Style = style_mod.Style;
const Colors = style_mod.Colors;
const Color = draw.Color;
const Rect = draw.Rect;

/// What a theme is built from.
pub const Base = struct {
    /// The emptiest surface, behind everything. Its lightness decides
    /// whether the theme is dark or light.
    background: Color,
    /// Body text.
    text: Color,
    /// Highlights, the focus ring, pressed and chosen things.
    accent: Color,
    /// Problems and warnings; a dark or light default if null.
    warning: ?Color = null,
    /// Use axis colours told apart by people with red-green colour
    /// blindness (Okabe and Ito's palette) rather than red, green, blue.
    colorblind_axes: bool = false,
};

/// Body text's minimum contrast against what it sits on.
pub const text_contrast: f32 = 4.5;
/// Outlines, the focus ring and other non-text marks.
pub const mark_contrast: f32 = 3;

/// A complete style from `base`. The metrics are the defaults.
pub fn build(base: Base) Style {
    const bg = base.background.withAlpha(255);
    // Dark means light text reads better on the background.
    const dark = color.contrast(Color.white, bg) > color.contrast(Color.black, bg);
    // Text moves towards `bright` for contrast; surfaces towards `deep`.
    const bright = if (dark) Color.white else Color.black;
    const deep = if (dark) Color.black else Color.white;
    const text = color.ensureContrast(base.text.withAlpha(255), bg, bright, text_contrast);
    const step = struct {
        fn f(b: Color, t: Color, amount: f32) Color {
            return color.mix(b, t, amount);
        }
    }.f;

    var c: Colors = undefined;
    c.background = bg;
    c.window = step(bg, text, 0.035);
    c.input = step(bg, text, if (dark) 0.05 else 0.0);
    c.title = step(bg, text, 0.07);
    c.popup = step(bg, text, 0.075);
    c.button = step(bg, text, if (dark) 0.10 else 0.06);
    c.button_hovered = step(bg, text, if (dark) 0.16 else 0.11);
    c.border = step(bg, text, if (dark) 0.22 else 0.20);
    c.separator = c.border;
    c.scrollbar = step(bg, text, 0.24);
    c.scrollbar_hovered = step(bg, text, 0.38);

    // Every surface text sits on keeps its contrast: a surface too close
    // to the text moves away from it.
    const surfaces = [_]*Color{ &c.window, &c.input, &c.title, &c.popup, &c.button, &c.button_hovered };
    for (surfaces) |s| s.* = color.ensureContrast(s.*, text, deep, text_contrast);
    c.text = text;
    c.text_muted = step(c.text, bg, 0.38);
    c.text_muted = color.ensureContrast(c.text_muted, bg, c.text, text_contrast);
    for (surfaces) |s| c.text_muted = color.ensureContrast(c.text_muted, s.*, c.text, text_contrast);
    c.title_text = c.text;
    c.caret = c.text;
    c.resize_grip = c.text_muted;

    c.accent = base.accent.withAlpha(255);
    for ([_]Color{ c.window, c.popup, c.background }) |s| {
        c.accent = color.ensureContrast(c.accent, s, bright, mark_contrast);
    }
    c.focus_ring = c.accent;
    // Pressed and chosen things are tinted with the accent, as dark as
    // body text still needs; the tick on them is black or white.
    c.button_active = color.ensureContrast(step(c.button, c.accent, if (dark) 0.55 else 0.35), c.text, bg, text_contrast);
    c.check_mark = color.textOn(c.button_active);
    c.title_active = color.ensureContrast(step(c.title, c.accent, 0.35), c.title_text, bg, text_contrast);
    c.slider_fill = c.accent.withAlpha(if (dark) 80 else 110);
    c.slider_thumb = c.accent;
    c.slider_thumb_active = step(c.accent, c.text, 0.35);
    c.selection = c.accent.withAlpha(if (dark) 90 else 70);
    c.shadow = if (dark) Color.black.withAlpha(110) else Color.hex(0x1D1F23).withAlpha(45);

    c.warning = base.warning orelse (if (dark) Color.hex(0xE8B04A) else Color.hex(0x9A5B00));
    for ([_]Color{ c.popup, c.window, c.background }) |s| {
        c.warning = color.ensureContrast(c.warning, s, bright, text_contrast);
    }

    if (base.colorblind_axes) {
        // Vermillion, bluish green and blue: apart for every common kind
        // of colour blindness, and in greyscale.
        c.axis_x = if (dark) Color.hex(0xE8743B) else Color.hex(0xC24E00);
        c.axis_y = if (dark) Color.hex(0x2BBF94) else Color.hex(0x00866A);
        c.axis_z = if (dark) Color.hex(0x4BA3E3) else Color.hex(0x0067A6);
    } else {
        c.axis_x = if (dark) Color.hex(0xE5534B) else Color.hex(0xC8352E);
        c.axis_y = if (dark) Color.hex(0x6CBF43) else Color.hex(0x3E8A1E);
        c.axis_z = if (dark) Color.hex(0x4C8DF0) else Color.hex(0x2563D0);
    }
    return .{ .colors = c };
}

/// A named theme.
pub const Preset = struct {
    name: []const u8,
    /// Built from this, unless `style` is given.
    base: Base = .{ .background = .black, .text = .white, .accent = .white },
    /// A hand-made style.
    fixed: ?Style = null,

    /// The preset's style.
    pub fn style(p: Preset) Style {
        return p.fixed orelse build(p.base);
    }
};

/// Nine themes: Zui's own dark and light, and seven built from bases.
pub const presets = [_]Preset{
    .{ .name = "Zui Dark", .fixed = Style.dark },
    .{ .name = "Zui Light", .fixed = Style.light },
    .{ .name = "Graphite", .base = .{ .background = Color.hex(0x1C1C1C), .text = Color.hex(0xDDDDDD), .accent = Color.hex(0xE0873A) } },
    .{ .name = "Midnight", .base = .{ .background = Color.hex(0x10141F), .text = Color.hex(0xD8DEEA), .accent = Color.hex(0x8E7CF0) } },
    .{ .name = "Forest", .base = .{ .background = Color.hex(0x161D19), .text = Color.hex(0xDCE5DD), .accent = Color.hex(0x5DBB7A) } },
    .{ .name = "Paper", .base = .{ .background = Color.hex(0xF7F5F0), .text = Color.hex(0x24221E), .accent = Color.hex(0xB5462F) } },
    .{ .name = "Sand", .base = .{ .background = Color.hex(0xEAE2D2), .text = Color.hex(0x2B261D), .accent = Color.hex(0x2F7D86) } },
    .{ .name = "High Contrast", .base = .{ .background = Color.hex(0x000000), .text = Color.hex(0xFFFFFF), .accent = Color.hex(0xFFD400), .warning = Color.hex(0xFF9E3D) } },
    .{ .name = "Colour-blind Safe", .base = .{ .background = Color.hex(0x1E2026), .text = Color.hex(0xE6E7EA), .accent = Color.hex(0x4BA3E3), .colorblind_axes = true } },
};

/// The preset called `name`, if there is one.
pub fn preset(name: []const u8) ?Style {
    for (presets) |p| if (std.mem.eql(u8, p.name, name)) return p.style();
    return null;
}

/// A text or mark colour that doesn't stand out enough from what it sits
/// on, from `contrastProblems`.
pub const Problem = struct {
    foreground: []const u8,
    background: []const u8,
    ratio: f32,
    min: f32,
};

const Pair = struct { []const u8, []const u8, f32 };

/// Every foreground and background the widgets combine.
const pairs = [_]Pair{
    .{ "text", "background", text_contrast },
    .{ "text", "window", text_contrast },
    .{ "text", "popup", text_contrast },
    .{ "text", "title", text_contrast },
    .{ "text", "input", text_contrast },
    .{ "text", "button", text_contrast },
    .{ "text", "button_hovered", text_contrast },
    .{ "text", "button_active", text_contrast },
    .{ "text_muted", "window", text_contrast },
    .{ "text_muted", "popup", text_contrast },
    .{ "text_muted", "button", text_contrast },
    .{ "text_muted", "background", text_contrast },
    .{ "title_text", "title", text_contrast },
    .{ "title_text", "title_active", text_contrast },
    .{ "check_mark", "button_active", text_contrast },
    .{ "warning", "window", text_contrast },
    .{ "warning", "popup", text_contrast },
    .{ "accent", "window", mark_contrast },
    .{ "accent", "popup", mark_contrast },
    .{ "focus_ring", "window", mark_contrast },
    .{ "focus_ring", "background", mark_contrast },
};

fn field(colors: *const Colors, name: []const u8) Color {
    inline for (comptime std.meta.fieldNames(Colors)) |n| {
        if (std.mem.eql(u8, n, name)) return @field(colors, n);
    }
    unreachable;
}

/// Checks each text colour against each surface it is drawn on (4.5:1)
/// and marks such as the focus ring (3:1). Fills `out` and returns the
/// problems found; empty means the style passes.
pub fn contrastProblems(style: Style, out: []Problem) []Problem {
    var n: usize = 0;
    for (pairs) |p| {
        const fg_name, const bg_name, const min = p;
        // Translucent colours are judged as they show over the window.
        const bg = color.over(field(&style.colors, bg_name), style.colors.window);
        const fg = color.over(field(&style.colors, fg_name), bg);
        const ratio = color.contrast(fg, bg);
        if (ratio + 0.005 < min and n < out.len) {
            out[n] = .{ .foreground = fg_name, .background = bg_name, .ratio = ratio, .min = min };
            n += 1;
        }
    }
    return out[0..n];
}

/// Options for `themePreview`.
pub const PreviewOptions = struct {
    /// Shown as chosen.
    selected: bool = false,
    width: @import("layout.zig").Size = .fill,
};

/// A row for a theme list: a miniature window in `style`'s colours and
/// the theme's name. Click to choose it.
pub fn themePreview(ui: *Ui, name: []const u8, style: *const Style, options: PreviewOptions) Interaction {
    const own = &ui.style;
    const label = Ui.visibleLabel(name);
    const line_h = ui.textSize("").y;
    const height = @max(44, line_h + 2 * own.frame_padding.y);
    const rect = ui.placeSized(options.width, .{ .fixed = height }, .{ .x = 280, .y = height });
    const widget = ui.id(name);
    var result = ui.interact(widget, rect);
    ui.focusable(widget, &result);
    const keys = ui.input.keys_pressed;
    if (result.focused and (keys.contains(.enter) or keys.contains(.space))) result.clicked = true;

    const fill = if (options.selected) own.colors.button_active else if (result.hovered) own.colors.button_hovered else Color.transparent;
    ui.drawRect(.{ .rect = rect, .fill = fill, .radius = own.rounding });

    // The miniature: the background, a window with its title bar, a line
    // of text, a button and a pressed (accent) button.
    const c = &style.colors;
    const mini: Rect = .{ .x = rect.x + 6, .y = rect.y + 5, .w = 112, .h = rect.h - 10 };
    ui.drawRect(.{ .rect = mini, .fill = c.background, .border = own.colors.border, .border_width = 1, .radius = 4 });
    const win: Rect = .{ .x = mini.x + 8, .y = mini.y + 5, .w = mini.w - 16, .h = mini.h - 10 };
    ui.drawRect(.{ .rect = win, .fill = c.window, .border = c.border, .border_width = 1, .radius = 3 });
    ui.drawRect(.{ .rect = .{ .x = win.x, .y = win.y, .w = win.w, .h = 7 }, .fill = c.title_active, .radius = 3 });
    ui.drawRect(.{ .rect = .{ .x = win.x + 6, .y = win.y + 11, .w = 30, .h = 3 }, .fill = c.text, .radius = 1 });
    ui.drawRect(.{ .rect = .{ .x = win.x + 40, .y = win.y + 11, .w = 22, .h = 3 }, .fill = c.text_muted, .radius = 1 });
    const by = win.bottom() - 9;
    ui.drawRect(.{ .rect = .{ .x = win.x + 6, .y = by, .w = 26, .h = 6 }, .fill = c.button, .border = c.border, .border_width = 1, .radius = 2 });
    ui.drawRect(.{ .rect = .{ .x = win.x + 36, .y = by, .w = 26, .h = 6 }, .fill = c.button_active, .radius = 2 });
    ui.drawRect(.{ .rect = .{ .x = win.right() - 14, .y = by - 1, .w = 8, .h = 8 }, .fill = c.accent, .radius = 4 });

    const text_color = if (options.selected) color.textOn(own.colors.button_active) else own.colors.text;
    ui.drawText(.{ .x = mini.right() + own.item_spacing.x + 4, .y = rect.y + (rect.h - line_h) / 2 }, text_color, label);
    ui.drawFocusRing(widget, rect);
    ui.recordWidget(.theme, widget, name, rect, .{ .value = if (options.selected) "true" else "false", .hovered = result.hovered, .focused = result.focused });
    return result;
}

const testing = std.testing;

test "every preset passes the contrast check" {
    var buffer: [pairs.len]Problem = undefined;
    for (presets) |p| {
        const problems = contrastProblems(p.style(), &buffer);
        for (problems) |q| std.debug.print("{s}: {s} on {s} is {d:.2}:1, needs {d}\n", .{ p.name, q.foreground, q.background, q.ratio, q.min });
        try testing.expectEqual(@as(usize, 0), problems.len);
    }
}

test "built themes keep contrast even from poor bases" {
    var buffer: [pairs.len]Problem = undefined;
    // Grey text on grey, and a pale accent on white.
    const bases = [_]Base{
        .{ .background = Color.hex(0x404040), .text = Color.hex(0x707070), .accent = Color.hex(0x505090) },
        .{ .background = Color.hex(0xFFFFFF), .text = Color.hex(0xAAAAAA), .accent = Color.hex(0xFFEE88) },
        .{ .background = Color.hex(0x808080), .text = Color.hex(0x909090), .accent = Color.hex(0x808080) },
    };
    for (bases) |b| {
        const problems = contrastProblems(build(b), &buffer);
        for (problems) |q| std.debug.print("{s} on {s} is {d:.2}:1, needs {d}\n", .{ q.foreground, q.background, q.ratio, q.min });
        try testing.expectEqual(@as(usize, 0), problems.len);
    }
    // A bad hand-made style is caught.
    var bad = Style.dark;
    bad.colors.text_muted = Color.hex(0x3A3D44);
    const problems = contrastProblems(bad, &buffer);
    try testing.expect(problems.len >= 3);
    try testing.expectEqualStrings("text_muted", problems[0].foreground);
}

test "text on the accent is black or white" {
    const light_accent = build(.{ .background = Color.hex(0x111111), .text = Color.hex(0xEEEEEE), .accent = Color.hex(0xFFD400) });
    try testing.expect(light_accent.colors.check_mark.eql(Color.black) or light_accent.colors.check_mark.eql(Color.white));
    try testing.expect(color.contrast(light_accent.colors.check_mark, light_accent.colors.button_active) >= 4.5);
}
