//! Colors and metrics that control how widgets look.
//!
//! Assign `ui.style` to switch themes. For a part of the UI, override single
//! fields with `ui.pushColor` / `ui.pushMetric` (or a whole theme with
//! `ui.pushStyle`) and undo with `ui.popStyle`.

const std = @import("std");
const draw = @import("draw.zig");
const Color = draw.Color;
const Vec2 = draw.Vec2;

/// Every color the widgets use.
pub const Colors = struct {
    /// Behind everything. Backends clear to this.
    background: Color,
    text: Color,
    /// Hints, secondary labels, inactive title bar glyphs.
    text_muted: Color,
    button: Color,
    button_hovered: Color,
    /// Pressed buttons and ticked checkboxes.
    button_active: Color,
    /// Frame outlines.
    border: Color,
    /// Highlights, such as a focused text field's border.
    accent: Color,
    /// Window body.
    window: Color,
    title: Color,
    /// Title bar of the frontmost window.
    title_active: Color,
    title_text: Color,
    scrollbar: Color,
    scrollbar_hovered: Color,
    /// The tick inside a checkbox.
    check_mark: Color,
    /// The part of a slider's track below its value.
    slider_fill: Color,
    slider_thumb: Color,
    /// The thumb while it is dragged.
    slider_thumb_active: Color,
    /// Background of a text field.
    input: Color,
    /// Behind selected text.
    selection: Color,
    caret: Color,
    /// Around the widget with keyboard focus.
    focus_ring: Color,
    separator: Color,
    /// The dots in a window's resize corner.
    resize_grip: Color,
    /// Background of popups and tooltips.
    popup: Color,
    /// Under windows, popups and tooltips. Transparent turns shadows off.
    shadow: Color,
    /// Problems, and why a widget can't be used now: tooltips, toasts.
    warning: Color,
    /// The X axis, for vector fields and gizmos. Y and Z follow.
    axis_x: Color,
    /// The Y axis.
    axis_y: Color,
    /// The Z axis.
    axis_z: Color,
    /// Over the window behind a modal dialog.
    backdrop: Color = Color.black.withAlpha(110),
};

/// A complete theme: every color and size the widgets use.
pub const Style = struct {
    colors: Colors,
    /// Text size in logical units.
    font_size: f32 = 15,
    /// Space between a frame's edge and its contents.
    frame_padding: Vec2 = .{ .x = 12, .y = 6 },
    /// Space between neighbouring items.
    item_spacing: Vec2 = .{ .x = 8, .y = 8 },
    /// Space between the window edge and the first item.
    window_padding: f32 = 16,
    /// Corner radius of frames.
    rounding: f32 = 5,
    /// Border thickness of frames.
    border_width: f32 = 1,
    /// Corner radius of windows.
    window_rounding: f32 = 8,
    /// Width of window scrollbars.
    scrollbar_width: f32 = 10,
    /// Lines scrolled per mouse wheel step, in logical units.
    scroll_step: f32 = 48,
    /// Thickness of separators.
    separator_width: f32 = 1,
    /// Default width of sliders and text fields, without their label.
    widget_width: f32 = 200,
    /// Width of a slider's thumb.
    slider_thumb_width: f32 = 6,
    /// Space between a checkbox's edge and the text height.
    checkbox_padding: f32 = 2,
    /// Width of the text caret.
    caret_width: f32 = 1,
    /// Thickness of the keyboard focus ring.
    focus_ring_width: f32 = 2,
    /// Space between a widget and its focus ring.
    focus_ring_gap: f32 = 3,
    /// Side of the square in a window's corner that resizes it.
    resize_grip_size: f32 = 16,
    /// Seconds the mouse rests on a widget before its tooltip shows.
    tooltip_delay: f32 = 0.5,
    /// How much of their strength disabled widgets keep, in percent: their
    /// text, and their fills and lines. 100 keeps it as it is (an app that
    /// greys only the text sets the fill to 100).
    disabled_text_percent: u8 = 45,
    disabled_fill_percent: u8 = 45,
    /// Space between a popup's or tooltip's edge and its contents.
    popup_padding: f32 = 8,
    /// How far tree node children are indented.
    indent: f32 = 18,
    /// How far window and popup shadows fade out.
    shadow_blur: f32 = 14,
    /// How far shadows sit from what casts them; down looks lit from above.
    shadow_offset: Vec2 = .{ .x = 0, .y = 4 },

    /// The default dark theme.
    pub const dark: Style = .{ .colors = .{
        .background = Color.hex(0x1E2024),
        .text = Color.hex(0xE6E7EA),
        .text_muted = Color.hex(0x9A9EA8),
        .button = Color.hex(0x2F3238),
        .button_hovered = Color.hex(0x3A3E46),
        .button_active = Color.hex(0x2F5FC4),
        .border = Color.hex(0x454952),
        .accent = Color.hex(0x7EA6F5),
        .window = Color.hex(0x25282D),
        .title = Color.hex(0x2B2E34),
        .title_active = Color.hex(0x2D4373),
        .title_text = Color.hex(0xE6E7EA),
        .scrollbar = Color.hex(0x4A4F59),
        .scrollbar_hovered = Color.hex(0x666C78),
        .check_mark = Color.hex(0xFFFFFF),
        .slider_fill = Color.hex(0x2F5FC4).withAlpha(90),
        .slider_thumb = Color.hex(0x2F5FC4),
        .slider_thumb_active = Color.hex(0x7EA6F5),
        .input = Color.hex(0x282B30),
        .selection = Color.hex(0x7EA6F5).withAlpha(90),
        .caret = Color.hex(0xE6E7EA),
        .focus_ring = Color.hex(0x7EA6F5),
        .separator = Color.hex(0x454952),
        .resize_grip = Color.hex(0x9A9EA8),
        .popup = Color.hex(0x2C2F35),
        .shadow = Color.hex(0x000000).withAlpha(110),
        .warning = Color.hex(0xE8B04A),
        .axis_x = Color.hex(0xE5534B),
        .axis_y = Color.hex(0x6CBF43),
        .axis_z = Color.hex(0x4C8DF0),
    } };

    /// The default light theme.
    pub const light: Style = .{ .colors = .{
        .background = Color.hex(0xF4F4F1),
        .text = Color.hex(0x1D1F23),
        .text_muted = Color.hex(0x62666F),
        .button = Color.hex(0xFFFFFF),
        .button_hovered = Color.hex(0xE9EDF7),
        .button_active = Color.hex(0xC9D8F5),
        .border = Color.hex(0xC9CAC5),
        .accent = Color.hex(0x2F5FC4),
        .window = Color.hex(0xFBFBF9),
        .title = Color.hex(0xE6E6E1),
        .title_active = Color.hex(0xC9D8F5),
        .title_text = Color.hex(0x1D1F23),
        .scrollbar = Color.hex(0xC4C5C0),
        .scrollbar_hovered = Color.hex(0xA3A5A0),
        .check_mark = Color.hex(0x1D3F8F),
        .slider_fill = Color.hex(0xC9D8F5).withAlpha(160),
        .slider_thumb = Color.hex(0x2F5FC4),
        .slider_thumb_active = Color.hex(0x1D3F8F),
        .input = Color.hex(0xFFFFFF),
        .selection = Color.hex(0x2F5FC4).withAlpha(70),
        .caret = Color.hex(0x1D1F23),
        .focus_ring = Color.hex(0x2F5FC4),
        .separator = Color.hex(0xC9CAC5),
        .resize_grip = Color.hex(0x62666F),
        .popup = Color.hex(0xFFFFFF),
        .shadow = Color.hex(0x1D1F23).withAlpha(45),
        .warning = Color.hex(0x9A5B00),
        .axis_x = Color.hex(0xC8352E),
        .axis_y = Color.hex(0x3E8A1E),
        .axis_z = Color.hex(0x2563D0),
    } };

    /// The same style at `k` times the size: text, padding, spacing and
    /// corners. Text is rasterized at the new size, so it stays sharp.
    /// For zoomed content such as nodes; for the whole UI see
    /// `Ui.setScale`.
    pub fn scaled(self: Style, k: f32) Style {
        var out = self;
        out.font_size *= k;
        out.frame_padding = self.frame_padding.scale(k);
        out.item_spacing = self.item_spacing.scale(k);
        out.window_padding *= k;
        out.rounding *= k;
        out.window_rounding *= k;
        out.scrollbar_width *= k;
        out.scroll_step *= k;
        out.widget_width *= k;
        out.slider_thumb_width *= k;
        out.checkbox_padding *= k;
        out.focus_ring_gap *= k;
        out.resize_grip_size *= k;
        out.popup_padding *= k;
        out.indent *= k;
        out.shadow_blur *= k;
        out.shadow_offset = self.shadow_offset.scale(k);
        return out;
    }

    /// The same style, faded for widgets that can't be used now. Text and
    /// fills keep their hue at about half strength; the surfaces they sit
    /// on stay as they are.
    pub fn faded(self: Style) Style {
        var out = self;
        const keep = [_][]const u8{ "background", "window", "popup", "title", "title_active", "shadow", "input" };
        const texts = [_][]const u8{ "text", "text_muted", "title_text", "check_mark" };
        inline for (comptime std.meta.fieldNames(Colors)) |name| {
            const skip = comptime for (keep) |k| {
                if (std.mem.eql(u8, k, name)) break true;
            } else false;
            const is_text = comptime for (texts) |k| {
                if (std.mem.eql(u8, k, name)) break true;
            } else false;
            if (!skip) {
                const c = @field(self.colors, name);
                const percent: u32 = if (is_text) self.disabled_text_percent else self.disabled_fill_percent;
                @field(out.colors, name) = c.withAlpha(@intCast(@as(u32, c.a) * @min(percent, 100) / 100));
            }
        }
        return out;
    }
};
