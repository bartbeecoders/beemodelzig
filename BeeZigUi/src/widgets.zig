//! The built-in widgets. They are written against the same public `Ui` methods
//! that custom widgets use, and are exposed as methods of `Ui`.

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const ui_mod = @import("ui.zig");
const Ui = ui_mod.Ui;
const Interaction = ui_mod.Interaction;
const Color = draw.Color;
const color_mod = @import("color.zig");
const icons = @import("icons.zig");

/// Options for `label`.
pub const LabelOptions = struct {
    /// Overrides the theme's text color.
    color: ?Color = null,
    /// The width it takes: its text's by default; fixed, or `.fill`, for a
    /// column of captions or a name in a narrow panel.
    width: layout.Size = .auto,
    /// Where the text sits in that width.
    alignment: layout.Align = .start,
    /// Text wider than the label is cut, ending in "…" (whole characters).
    /// The record keeps the whole text.
    ellipsis: bool = true,
};

/// Shows a line of text.
pub fn label(ui: *Ui, text: []const u8, options: LabelOptions) void {
    const natural = ui.textSize(text);
    const rect = ui.placeSized(options.width, .auto, natural);
    ui.recordWidget(.label, .none, text, rect, .{});
    var shown = text;
    var buffer: [512]u8 = undefined;
    if (options.ellipsis and natural.x > rect.w + 0.5) shown = fitEllipsis(ui, text, rect.w, &buffer);
    const w = ui.textSize(shown).x;
    const x = switch (options.alignment) {
        .start => rect.x,
        .center => rect.x + (rect.w - w) / 2,
        .end => rect.right() - w,
    };
    ui.drawText(.{ .x = x, .y = rect.y }, options.color orelse ui.style.colors.text, shown);
}

/// The longest start of `text` that, with "…" after it, fits in `width`.
fn fitEllipsis(ui: *const Ui, text: []const u8, width: f32, buffer: []u8) []const u8 {
    const dots = "\u{2026}";
    const room = width - ui.textSize(dots).x;
    if (room <= 0) return "";
    var it: @import("font.zig").Utf8Iterator = .{ .bytes = text };
    var end: usize = 0;
    while (it.next()) |_| {
        if (ui.textSize(text[0..it.index]).x > room) break;
        end = it.index;
    }
    const n = @min(end, buffer.len - dots.len);
    const cut = @import("font.zig").fitUtf8(text, n);
    @memcpy(buffer[0..cut], text[0..cut]);
    @memcpy(buffer[cut..][0..dots.len], dots);
    return buffer[0 .. cut + dots.len];
}

/// Shows a line of formatted text. Formats into the frame arena.
pub fn labelf(ui: *Ui, comptime fmt: []const u8, args: anytype, options: LabelOptions) void {
    const text = std.fmt.allocPrint(ui.frameAllocator(), fmt, args) catch |err| {
        ui.fail(err);
        return;
    };
    label(ui, text, options);
}

/// Options for `button`.
pub const ButtonOptions = struct {
    width: layout.Size = .auto,
    height: layout.Size = .auto,
    /// Shown before the text, or alone for a name like `"##close"`.
    icon: ?icons.Icon = null,
    /// Where the text sits: in the middle, or from the left edge (rows of
    /// a list, categories).
    alignment: layout.Align = .center,
    /// How it looks: see `ButtonVariant`.
    variant: ButtonVariant = .normal,
};

/// Kinds of push button.
pub const ButtonVariant = enum {
    /// The theme's button.
    normal,
    /// The main action (OK, Save): the accent fill, text that reads on it.
    primary,
    /// On, like a chosen tab or a toggle that is set: the accent fill.
    selected,
    /// No fill until hovered: buttons in a toolbar or a list of categories.
    flat,
};

/// Options for `icon`.
pub const IconOptions = struct {
    /// Width and height. Defaults to the text line height.
    size: ?f32 = null,
    /// Defaults to the theme's text color.
    color: ?Color = null,
};

/// Shows an icon in the layout, sized like a line of text by default.
pub fn icon(ui: *Ui, which: icons.Icon, options: IconOptions) void {
    const size = options.size orelse ui.textSize("").y;
    const rect = ui.place(.{ .x = size, .y = size });
    ui.recordWidget(.icon, .none, switch (which) {
        .builtin => |b| @tagName(b),
        .bitmap => "bitmap",
    }, rect, .{});
    ui.painter().icon(which, rect, options.color orelse ui.style.colors.text);
}

/// True if the focused widget was activated from the keyboard this frame.
pub fn keyActivated(ui: *const Ui, result: Interaction) bool {
    const keys = ui.input.keys_pressed;
    return result.focused and (keys.contains(.enter) or keys.contains(.space));
}

/// Shows a push button. `name` is also its ID; add `##suffix` to tell apart
/// buttons with the same text. Enter or Space clicks it when focused.
pub fn button(ui: *Ui, name: []const u8, options: ButtonOptions) Interaction {
    const style = &ui.style;
    const text = Ui.visibleLabel(name);
    const text_size = ui.textSize(text);
    const icon_size = if (options.icon != null) text_size.y else 0;
    const icon_gap = if (options.icon != null and text.len > 0) style.item_spacing.x * 0.75 else 0;
    // An icon-only button is square.
    const pad_x = if (text.len == 0 and options.icon != null) style.frame_padding.y else style.frame_padding.x;
    const content_w = icon_size + icon_gap + text_size.x;
    const rect = ui.placeSized(options.width, options.height, .{
        .x = content_w + pad_x * 2,
        .y = text_size.y + style.frame_padding.y * 2,
    });
    const widget = ui.id(name);
    var result = ui.interact(widget, rect);
    ui.focusable(widget, &result);
    if (keyActivated(ui, result)) result.clicked = true;

    const colors = &style.colors;
    const lit = result.hovered or result.held;
    const fill = switch (options.variant) {
        .normal => if (result.held and result.hovered) colors.button_active else if (lit) colors.button_hovered else colors.button,
        .primary, .selected => colors.button_active,
        .flat => if (result.held and result.hovered) colors.button_active else if (lit) colors.button_hovered else Color.transparent,
    };
    ui.drawRect(.{
        .rect = rect,
        .fill = fill,
        .border = if (options.variant == .flat) Color.transparent else colors.border,
        .border_width = style.border_width,
        .radius = style.rounding,
    });
    // Text that reads on the accent; faded like the fill when disabled.
    const ink = switch (options.variant) {
        .primary, .selected => color_mod.textOn(fill.withAlpha(255)).withAlpha(colors.text.a),
        else => colors.text,
    };
    const left = switch (options.alignment) {
        .center => rect.x + (rect.w - content_w) / 2,
        .start => rect.x + pad_x,
        .end => rect.right() - pad_x - content_w,
    };
    if (options.icon) |which| {
        ui.painter().icon(which, .{ .x = left, .y = rect.y + (rect.h - icon_size) / 2, .w = icon_size, .h = icon_size }, ink);
    }
    ui.drawText(.{
        .x = left + icon_size + icon_gap,
        .y = rect.y + (rect.h - text_size.y) / 2,
    }, ink, text);
    ui.drawFocusRing(widget, rect);
    // An icon-only button is known by its ID ("##split" is "split"), or
    // else by its icon's name.
    const record_label = if (text.len == 0 and options.icon != null and name.len <= 2) switch (options.icon.?) {
        .builtin => |b| @tagName(b),
        .bitmap => name,
    } else name;
    ui.recordWidget(.button, widget, record_label, rect, .{ .hovered = result.hovered, .focused = result.focused });
    return result;
}

/// Draws a thin line across the current layout: horizontal in a column,
/// vertical in a row.
pub fn separator(ui: *Ui) void {
    const thickness = ui.style.separator_width;
    const rect = switch (ui.currentAxis()) {
        .vertical => ui.placeSized(.fill, .px(thickness), .{}),
        .horizontal => ui.placeSized(.px(thickness), .fill, .{}),
    };
    ui.drawRect(.{ .rect = rect, .fill = ui.style.colors.separator });
}

/// Adds empty space along the layout's axis. `.fill` pushes what follows to
/// the far end.
pub fn spacer(ui: *Ui, size: layout.Size) void {
    _ = switch (ui.currentAxis()) {
        .vertical => ui.placeSized(.auto, size, .{}),
        .horizontal => ui.placeSized(size, .auto, .{}),
    };
}

/// Options for `checkbox`.
pub const CheckboxOptions = struct {};

/// A box that toggles `value`. Clicking the label toggles it too, and so
/// do Enter and Space when it is focused.
/// `result.changed` is true on the frame it flips.
pub fn checkbox(ui: *Ui, name: []const u8, value: *bool, options: CheckboxOptions) Interaction {
    _ = options;
    const style = &ui.style;
    const colors = &style.colors;
    const text = Ui.visibleLabel(name);
    const text_size = ui.textSize(text);
    const box_size = text_size.y + 2 * style.checkbox_padding;
    const gap = style.item_spacing.x;
    const height = @max(box_size, text_size.y);
    const rect = ui.place(.{ .x = box_size + gap + text_size.x, .y = height });

    const widget = ui.id(name);
    var result = ui.interact(widget, rect);
    ui.focusable(widget, &result);
    if (result.clicked or keyActivated(ui, result)) {
        value.* = !value.*;
        result.changed = true;
        result.started = true;
        result.committed = true;
    }

    const box: draw.Rect = .{ .x = rect.x, .y = rect.y + (height - box_size) / 2, .w = box_size, .h = box_size };
    const fill = if (value.*)
        colors.button_active
    else if (result.hovered or result.held)
        colors.button_hovered
    else
        colors.button;
    ui.drawRect(.{
        .rect = box,
        .fill = fill,
        .border = if (value.*) colors.button_active else colors.border,
        .border_width = style.border_width,
        .radius = style.rounding * 0.8,
    });
    if (value.*) {
        const s = box_size;
        const stroke = @max(1.5, s * 0.12);
        const a: draw.Vec2 = .{ .x = box.x + s * 0.25, .y = box.y + s * 0.52 };
        const b: draw.Vec2 = .{ .x = box.x + s * 0.43, .y = box.y + s * 0.70 };
        const c: draw.Vec2 = .{ .x = box.x + s * 0.76, .y = box.y + s * 0.32 };
        ui.painter().polyline(&.{ a, b, c }, colors.check_mark, stroke, false);
    }
    ui.drawText(.{ .x = box.right() + gap, .y = rect.y + (height - text_size.y) / 2 }, colors.text, text);
    ui.drawFocusRing(widget, rect);
    ui.recordWidget(.checkbox, widget, name, rect, .{ .value = if (value.*) "true" else "false", .hovered = result.hovered, .focused = result.focused });
    return result;
}

/// Options for `slider`.
pub const SliderOptions = struct {
    /// Width of the whole widget, label included. Defaults to a 200-unit track.
    width: layout.Size = .auto,
    /// Digits after the decimal point when showing a float.
    decimals: u8 = 2,
    /// Snap floats to multiples of this, counted from `min`.
    step: ?f64 = null,
};

/// A horizontal slider editing an integer or float through `value`, kept
/// within `min` and `max`. Keeps tracking while the mouse is held, even
/// outside the widget; Escape during a drag puts the old value back. When
/// focused, arrow keys step the value (Shift for ten steps), Page Up and
/// Page Down move ten steps, Home and End go to the ends.
/// `result.changed` is true when the value changed.
pub fn slider(
    ui: *Ui,
    name: []const u8,
    value: anytype,
    min: @TypeOf(value.*),
    max: @TypeOf(value.*),
    options: SliderOptions,
) Interaction {
    const T = @TypeOf(value.*);
    comptime switch (@typeInfo(T)) {
        .int, .float => {},
        else => @compileError("slider needs a pointer to an integer or float, got " ++ @typeName(T)),
    };

    const style = &ui.style;
    const colors = &style.colors;
    const text = Ui.visibleLabel(name);
    const text_size = ui.textSize(text);
    const gap = if (text.len > 0) style.item_spacing.x else 0;
    const height = text_size.y + style.frame_padding.y * 2;
    const rect = ui.placeSized(options.width, .auto, .{ .x = style.widget_width + gap + text_size.x, .y = height });
    const track: draw.Rect = .{ .x = rect.x, .y = rect.y, .w = @max(0, rect.w - gap - text_size.x), .h = height };

    const widget = ui.id(name);
    const was_held = ui.active == widget;
    var result = ui.interact(widget, track);
    ui.focusable(widget, &result);
    result.rect = rect;
    const thumb_w = style.slider_thumb_width;
    const travel = @max(1, track.w - thumb_w);
    const before = value.*;

    if (@sizeOf(T) <= ui.drag_backup.len) {
        if (result.pressed) @memcpy(ui.drag_backup[0..@sizeOf(T)], std.mem.asBytes(value));
        if (result.held and ui.input.keys_pressed.contains(.escape)) {
            ui.input.keys_pressed.remove(.escape); // (the drag's: a dialog around it stays)
            @memcpy(std.mem.asBytes(value), ui.drag_backup[0..@sizeOf(T)]);
            ui.active = .none;
            result.held = false;
            result.cancelled = true;
        }
    }
    if (result.pressed) result.started = true;
    if (result.focused and !result.held) {
        value.* = keyboardStep(T, ui, value.*, min, max, options.step);
        if (value.* != before) {
            // A key edits in one step.
            result.started = true;
            result.committed = true;
        }
    }
    if (value.* != before) result.changed = true;

    if (result.held) {
        const t = std.math.clamp((ui.input.mouse_pos.x - track.x - thumb_w / 2) / travel, 0, 1);
        const new_value = fromFraction(T, t, min, max, options.step);
        if (new_value != value.*) {
            value.* = new_value;
            result.changed = true;
        }
    }

    // The drag ended: one step, if it changed anything.
    if (was_held and !result.held and !result.cancelled) {
        const moved = @sizeOf(T) > ui.drag_backup.len or !std.mem.eql(u8, ui.drag_backup[0..@sizeOf(T)], std.mem.asBytes(value));
        if (moved) result.committed = true else if (!result.pressed) result.cancelled = true;
    }

    const t = toFraction(T, value.*, min, max);
    ui.drawRect(.{
        .rect = track,
        .fill = if (result.hovered or result.held) colors.button_hovered else colors.button,
        .border = colors.border,
        .border_width = style.border_width,
        .radius = style.rounding,
    });
    // A filled bar up to the value, and a slim thumb that the value text can
    // be read over.
    const thumb: draw.Rect = .{ .x = track.x + travel * t, .y = track.y + 3, .w = thumb_w, .h = track.h - 6 };
    if (thumb.x > track.x + 1) {
        ui.drawRect(.{
            .rect = .{ .x = track.x + 1, .y = track.y + 1, .w = thumb.x + thumb_w / 2 - track.x - 1, .h = track.h - 2 },
            .fill = colors.slider_fill,
            .radius = @max(0, style.rounding - 1),
        });
    }
    ui.drawRect(.{ .rect = thumb, .fill = if (result.held) colors.slider_thumb_active else colors.slider_thumb, .radius = thumb_w / 2 });

    var buffer: [64]u8 = undefined;
    const shown = switch (@typeInfo(T)) {
        .int => std.fmt.bufPrint(&buffer, "{d}", .{value.*}),
        else => std.fmt.bufPrint(&buffer, "{d:.[1]}", .{ value.*, options.decimals }),
    } catch "?";
    const shown_size = ui.textSize(shown);
    ui.drawText(.{ .x = track.x + (track.w - shown_size.x) / 2, .y = track.y + style.frame_padding.y }, colors.text, shown);
    if (text.len > 0) {
        ui.drawText(.{ .x = track.right() + gap, .y = rect.y + style.frame_padding.y }, colors.text, text);
    }
    ui.drawFocusRing(widget, track);
    // The track, so scripts can drag along it.
    ui.recordWidget(.slider, widget, name, track, .{ .value = shown, .hovered = result.hovered, .focused = result.focused });
    return result;
}

/// Applies this frame's arrow, page and Home/End keys to a slider value.
fn keyboardStep(comptime T: type, ui: *const Ui, value: T, min: T, max: T, step: ?f64) T {
    if (!(max > min)) return value;
    var steps: i64 = 0;
    var result = value;
    for (ui.input.keyEvents()) |event| {
        const one: i64 = if (event.modifiers.shift) 10 else 1;
        switch (event.key) {
            .left, .down => steps -= one,
            .right, .up => steps += one,
            .page_down => steps -= 10,
            .page_up => steps += 10,
            .home => {
                result = min;
                steps = 0;
            },
            .end => {
                result = max;
                steps = 0;
            },
            else => {},
        }
    }
    if (steps == 0) return result;
    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.bits > 64) return result; // i128 arithmetic below can't hold it
            const unit: i128 = if (step) |s| @max(1, @as(i128, @intFromFloat(@round(s)))) else 1;
            const next = std.math.clamp(@as(i128, result) + steps * unit, @as(i128, min), @as(i128, max));
            return @intCast(next);
        },
        else => {
            const lo = asFloat(T, min);
            const hi = asFloat(T, max);
            const unit = step orelse (hi - lo) / 100;
            var x = asFloat(T, result) + @as(f64, @floatFromInt(steps)) * unit;
            if (step) |s| {
                if (s > 0) x = lo + @round((x - lo) / s) * s;
            }
            return @floatCast(std.math.clamp(x, lo, hi));
        },
    }
}

fn asFloat(comptime T: type, v: T) f64 {
    return switch (@typeInfo(T)) {
        .int => @floatFromInt(v),
        else => @floatCast(v),
    };
}

/// Where `v` sits between `min` and `max`, from 0 to 1.
fn toFraction(comptime T: type, v: T, min: T, max: T) f32 {
    const lo = asFloat(T, min);
    const hi = asFloat(T, max);
    const x = asFloat(T, v);
    if (!(hi > lo) or !std.math.isFinite(x)) return 0;
    return @floatCast(std.math.clamp((x - lo) / (hi - lo), 0, 1));
}

/// The value at fraction `t` between `min` and `max`. Never leaves the range,
/// including for integer types near their limits.
fn fromFraction(comptime T: type, t: f32, min: T, max: T, step: ?f64) T {
    if (!(max > min)) return min;
    if (t <= 0) return min;
    if (t >= 1) return max;
    const lo = asFloat(T, min);
    const hi = asFloat(T, max);
    var x = lo + (hi - lo) * t;
    switch (@typeInfo(T)) {
        .int => {
            x = @round(x);
            if (x <= lo) return min;
            if (x >= hi) return max;
            return @intFromFloat(x);
        },
        else => {
            if (step) |s| {
                if (s > 0) x = lo + @round((x - lo) / s) * s;
            }
            return @floatCast(std.math.clamp(x, lo, hi));
        },
    }
}

test "slider mapping stays in range at integer limits" {
    const testing = std.testing;
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), fromFraction(i64, 1, std.math.minInt(i64), std.math.maxInt(i64), null));
    const mid = fromFraction(i64, 0.999999, std.math.minInt(i64), std.math.maxInt(i64), null);
    try testing.expect(mid <= std.math.maxInt(i64));
    try testing.expectEqual(@as(u8, 255), fromFraction(u8, 1, 0, 255, null));
    try testing.expectEqual(@as(u8, 128), fromFraction(u8, 0.5, 0, 255, null));
    try testing.expectEqual(@as(i32, 5), fromFraction(i32, 0.3, 5, 5, null));
    try testing.expectEqual(@as(f32, 0.5), fromFraction(f32, 0.52, 0, 1, 0.25));
    try testing.expectEqual(@as(f32, 0), toFraction(f32, std.math.nan(f32), 0, 1));
}
