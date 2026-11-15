//! Number fields, the building block of property editors: drag to scrub,
//! click to type a value or an expression, arrow keys and Ctrl+wheel to
//! step. Plus angle fields (degrees shown, radians kept) and vector rows.
//!
//!     _ = ui.numberField("Size", &size, .{ .min = 0, .suffix = " m" });
//!     _ = ui.angleField("Rotation", &angle_radians, .{});
//!     _ = ui.vectorField("Location", &location, .{});
//!
//! Dragging: Shift moves ten times finer, Ctrl snaps to whole steps.
//! Typing: Enter keeps the value, Escape puts the old one back, a click
//! elsewhere or Tab keeps it. Expressions such as `2*pi` or `25mm` work
//! (see `zui.expr`).

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const ui_mod = @import("ui.zig");
const expr = @import("expr.zig");
const text_input = @import("text_input.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;
const Color = draw.Color;

/// Where a number field shows its label.
pub const LabelPlace = enum {
    /// Inside the field on the left, dimmed, with the value on the right:
    /// compact, as in BeeModel's and Blender's property panels.
    inside,
    /// To the right of the field, like other widgets.
    outside,
    /// Not at all; the value is centered.
    none,
};

/// Options for `numberField`, `angleField` and the parts of `vectorField`.
pub const NumberOptions = struct {
    width: layout.Size = .auto,
    /// Limits, in stored units. Dragging and typing stay inside them.
    min: ?f64 = null,
    max: ?f64 = null,
    /// What an arrow key, Ctrl+wheel notch, or Ctrl-snapped drag moves, in
    /// shown units. Defaults to 1 for integers, a hundredth of the range,
    /// or 0.1.
    step: ?f64 = null,
    /// How much a drag of one unit (about a pixel) changes the shown value.
    /// Defaults to a tenth of `step`, or a quarter for integers.
    drag_step: ?f64 = null,
    /// Digits after the decimal point, at most. Trailing zeros are dropped.
    decimals: u8 = 3,
    /// Shown after the value, such as " m" or "%".
    suffix: []const u8 = "",
    /// The shown value is the stored one times this. Angles use 180/pi.
    display_scale: f64 = 1,
    /// Fill the field up to the value, between `min` and `max`.
    slider: bool = false,
    label: LabelPlace = .inside,
    /// A thin bar of this color at the left edge (vector axes).
    accent: ?Color = null,
    /// Turns typed text into a number; the default knows arithmetic,
    /// functions and constants but no units.
    evaluator: ?*const expr.Evaluator = null,
};

/// The number field being dragged or typed into. One at a time, so `Ui`
/// keeps a single one.
pub const State = struct {
    id: Id = .none,
    /// Typing a value rather than showing it.
    editing: bool = false,
    /// Dragging past the threshold.
    dragging: bool = false,
    /// The shown value when the drag started.
    start: f64 = 0,
    /// Drag distance turned into value, so Shift can change mid-drag.
    offset: f64 = 0,
    last_x: f32 = 0,
    buffer: [64]u8 = undefined,
    len: usize = 0,
    /// The text typing started with: committed unchanged, it keeps the
    /// value as it was (the text has only so many digits).
    initial: [64]u8 = undefined,
    initial_len: usize = 0,
};

const default_evaluator: expr.Evaluator = .{};
const degree_evaluator: expr.Evaluator = .{ .units = &expr.degrees };

/// How far the pointer must move before a press becomes a drag.
const drag_threshold = 3;

/// A field editing an integer or float through `value`. See the module
/// documentation for how it is used. `result.started`, `committed` and
/// `cancelled` bracket each drag, typed value or step, for undo.
pub fn numberField(ui: *Ui, name: []const u8, value: anytype, options: NumberOptions) Interaction {
    const style = &ui.style;
    const text = Ui.visibleLabel(name);
    const outside = options.label == .outside and text.len > 0;
    const text_w = if (outside) ui.textSize(text).x else 0;
    const gap: f32 = if (outside) style.item_spacing.x else 0;
    const height = ui.textSize("").y + style.frame_padding.y * 2;
    const rect = ui.placeSized(options.width, .auto, .{ .x = style.widget_width + gap + text_w, .y = height });
    const field: Rect = .{ .x = rect.x, .y = rect.y, .w = @max(0, rect.w - gap - text_w), .h = height };
    var result = numberAt(ui, name, name, value, field, options);
    if (outside) ui.drawText(.{ .x = field.right() + gap, .y = rect.y + style.frame_padding.y }, style.colors.text, text);
    result.rect = rect;
    return result;
}

/// A number field for an angle kept in radians, shown and typed in
/// degrees. Typed values may say `rad` or `turn`.
pub fn angleField(ui: *Ui, name: []const u8, radians: anytype, options: NumberOptions) Interaction {
    var o = options;
    o.display_scale = 180.0 / std.math.pi;
    if (o.suffix.len == 0) o.suffix = "\u{00B0}";
    if (o.step == null) o.step = 1;
    if (o.evaluator == null) o.evaluator = &degree_evaluator;
    return numberField(ui, name, radians, o);
}

/// Options for `vectorField`.
pub const VectorOptions = struct {
    width: layout.Size = .auto,
    /// Labels of the components, in order.
    components: []const []const u8 = &.{ "X", "Y", "Z", "W" },
    /// Mark X, Y and Z with the style's axis colors.
    axis_colors: bool = true,
    /// Applied to every component.
    number: NumberOptions = .{},
};

/// A row of number fields for a vector, such as a location: `values` is a
/// pointer to an array of numbers. The label goes to the right.
pub fn vectorField(ui: *Ui, name: []const u8, values: anytype, options: VectorOptions) Interaction {
    const info = @typeInfo(@TypeOf(values.*));
    comptime if (info != .array) @compileError("vectorField needs a pointer to an array of numbers");
    const n = info.array.len;
    const style = &ui.style;
    const text = Ui.visibleLabel(name);
    const text_w = if (text.len > 0) ui.textSize(text).x else 0;
    const gap: f32 = if (text.len > 0) style.item_spacing.x else 0;
    const height = ui.textSize("").y + style.frame_padding.y * 2;
    const natural = @max(style.widget_width, @as(f32, @floatFromInt(n)) * 70);
    const rect = ui.placeSized(options.width, .auto, .{ .x = natural + gap + text_w, .y = height });
    const row_w = @max(0, rect.w - gap - text_w);
    const spacing: f32 = 2;
    const part_w = (row_w - spacing * @as(f32, @floatFromInt(n - 1))) / @as(f32, @floatFromInt(n));

    var result: Interaction = .{ .rect = rect };
    ui.pushId(name);
    const axis = [_]Color{ style.colors.axis_x, style.colors.axis_y, style.colors.axis_z };
    for (0..n) |i| {
        var o = options.number;
        o.label = .inside;
        if (options.axis_colors and i < axis.len) o.accent = axis[i];
        const label_text = if (i < options.components.len) options.components[i] else "?";
        const part: Rect = .{ .x = rect.x + @as(f32, @floatFromInt(i)) * (part_w + spacing), .y = rect.y, .w = part_w, .h = height };
        // Recorded as "Location X", so scripts can tell the rows apart.
        const record_name = std.fmt.allocPrint(ui.frameAllocator(), "{s} {s}", .{ text, label_text }) catch label_text;
        const r = numberAt(ui, label_text, record_name, &values[i], part, o);
        result.hovered = result.hovered or r.hovered;
        result.held = result.held or r.held;
        result.focused = result.focused or r.focused;
        result.changed = result.changed or r.changed;
        result.started = result.started or r.started;
        result.committed = result.committed or r.committed;
        result.cancelled = result.cancelled or r.cancelled;
        result.context_clicked = result.context_clicked or r.context_clicked;
        result.disabled = r.disabled;
    }
    ui.popId();
    if (text.len > 0) ui.drawText(.{ .x = rect.x + row_w + gap, .y = rect.y + style.frame_padding.y }, style.colors.text, text);
    return result;
}

fn toF64(v: anytype) f64 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int, .comptime_int => @floatFromInt(v),
        .float, .comptime_float => @floatCast(v),
        else => @compileError("number fields edit integers and floats"),
    };
}

/// Stores the shown value `shown` into `value`, clamped and, for integers,
/// rounded. Returns whether it changed.
fn store(comptime T: type, value: *T, shown: f64, options: NumberOptions) bool {
    var v = shown / options.display_scale;
    if (options.min) |m| v = @max(v, m);
    if (options.max) |m| v = @min(v, m);
    const new: T = switch (@typeInfo(T)) {
        .int => blk: {
            if (std.math.isNan(v)) return false;
            const r = @round(v);
            // maxInt of a 64-bit type rounds up to 2^63 as a float, which
            // doesn't fit back: compare instead of clamping to it.
            const lo: f64 = @floatFromInt(std.math.minInt(T));
            const hi: f64 = @floatFromInt(std.math.maxInt(T));
            if (r >= hi) break :blk std.math.maxInt(T);
            if (r <= lo) break :blk std.math.minInt(T);
            break :blk @intFromFloat(r);
        },
        else => @floatCast(v),
    };
    if (new == value.*) return false;
    value.* = new;
    return true;
}

/// The shown value as text: up to `decimals` digits, trailing zeros
/// dropped, without the suffix.
pub fn formatValue(buffer: []u8, shown: f64, decimals: u8, integer: bool) []const u8 {
    if (integer) return std.fmt.bufPrint(buffer, "{d}", .{@round(shown)}) catch "?";
    if (!std.math.isFinite(shown) or @abs(shown) >= 1e15) return std.fmt.bufPrint(buffer, "{e:.3}", .{shown}) catch "?";
    const s = std.fmt.bufPrint(buffer, "{d:.[1]}", .{ shown, @min(decimals, 9) }) catch return "?";
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var n = s.len;
    while (s[n - 1] == '0') n -= 1;
    if (s[n - 1] == '.') n -= 1;
    if (n == 2 and s[0] == '-' and s[1] == '0') return "0";
    return s[0..n];
}

/// The number field drawn and handled in `field`, with no placement.
fn numberAt(ui: *Ui, name: []const u8, record_name: []const u8, value: anytype, field: Rect, options: NumberOptions) Interaction {
    const T = @TypeOf(value.*);
    const integer = @typeInfo(T) == .int;
    const style = &ui.style;
    const colors = &style.colors;
    const widget = ui.id(name);
    const ns = &ui.number_state;
    const mine = ns.id == widget;
    const was_active = ui.active == widget;
    const was_focused = ui.focused == widget;

    var result = ui.interact(widget, field);
    ui.focusable(widget, &result);
    const input = &ui.input;

    const scale = options.display_scale;
    const range: ?f64 = if (options.min != null and options.max != null) (options.max.? - options.min.?) * scale else null;
    const step = options.step orelse if (integer) 1 else if (range) |r| r / 100 else 0.1;
    const drag_step = options.drag_step orelse if (integer) @max(step, 1) / 4 else step / 10;
    var shown = toF64(value.*) * scale;

    // Typing into the field.
    if (mine and ns.editing) {
        if (ui.focused != widget) {
            // Focus moved away: keep what was typed.
            ns.editing = false;
            commitText(T, ui, value, options, &result);
        } else {
            var edit = result;
            text_input.editField(ui, widget, field, &ns.buffer, &ns.len, &edit, was_focused, "");
            result.focused = edit.focused;
            if (edit.submitted) {
                ns.editing = false;
                commitText(T, ui, value, options, &result);
                result.submitted = true;
            } else if (edit.cancelled or ui.focused != widget) {
                ns.editing = false;
                result.cancelled = true;
            }
            if (ns.editing) {
                recordNumber(ui, widget, record_name, field, value, options, result);
                return result;
            }
            shown = toF64(value.*) * scale;
        }
    } else if (!result.disabled) {
        // Dragging, clicking, keys and the wheel.
        if (result.pressed) {
            ns.* = .{ .id = widget, .start = shown, .last_x = input.press_pos.get(.left).x };
        }
        if (result.held and ns.id == widget) {
            ui.cursor = .resize_ew;
            const mx = input.mouse_pos.x;
            if (!ns.dragging and @abs(mx - input.press_pos.get(.left).x) > drag_threshold) {
                ns.dragging = true;
                result.started = true;
            }
            if (ns.dragging) {
                const fine: f64 = if (input.modifiers.shift) 0.1 else 1;
                ns.offset += @as(f64, mx - ns.last_x) * drag_step * fine;
                ns.last_x = mx;
                var v = ns.start + ns.offset;
                if (input.modifiers.ctrl) v = @round(v / step) * step;
                if (store(T, value, v, options)) result.changed = true;
                if (input.keys_pressed.contains(.escape)) {
                    input.keys_pressed.remove(.escape); // (the drag's: a dialog around it stays)
                    _ = store(T, value, ns.start, options);
                    result.changed = true;
                    result.cancelled = true;
                    result.held = false;
                    ns.dragging = false;
                    ui.active = .none;
                }
            }
        }
        // Released this frame, after a press this frame or earlier: a click
        // inside one frame (a fast click, a test driver) counts too.
        if ((was_active or result.pressed) and !result.held and ns.id == widget and !result.cancelled) {
            if (ns.dragging) {
                ns.dragging = false;
                if (toF64(value.*) * scale != ns.start) result.committed = true else result.cancelled = true;
            } else if (result.clicked) {
                beginTyping(ui, widget, shown, options, integer);
                result.started = true;
            }
        }
        if (result.hovered) ui.cursor = .resize_ew;

        if (result.focused and !result.held) {
            var steps: f64 = 0;
            for (input.keyEvents()) |event| {
                const k: f64 = if (event.modifiers.shift) 10 else 1;
                switch (event.key) {
                    .left, .down => steps -= k,
                    .right, .up => steps += k,
                    .enter => {
                        beginTyping(ui, widget, shown, options, integer);
                        result.started = true;
                    },
                    else => {},
                }
            }
            if (steps != 0 and store(T, value, shown + steps * step, options)) {
                result.started = true;
                result.changed = true;
                result.committed = true;
            }
        }
        if (result.hovered and input.modifiers.ctrl and input.scroll.y != 0) {
            const fine: f64 = if (input.modifiers.shift) 0.1 else 1;
            const notches: f64 = @floatCast(input.scroll.y);
            input.scroll.y = 0;
            if (store(T, value, @round((shown + notches * step * fine) / (step * fine)) * step * fine, options)) {
                result.started = true;
                result.changed = true;
                result.committed = true;
            }
        }
        shown = toF64(value.*) * scale;
    }

    drawNumber(ui, widget, name, field, shown, integer, options, result);
    recordNumber(ui, widget, record_name, field, value, options, result);
    _ = colors;
    return result;
}

fn beginTyping(ui: *Ui, widget: Id, shown: f64, options: NumberOptions, integer: bool) void {
    const ns = &ui.number_state;
    ns.id = widget;
    ns.editing = true;
    ns.dragging = false;
    // Every digit there is, not just the shown ones, so Enter keeps it exact.
    const text = formatValue(&ns.buffer, shown, if (integer) 0 else @max(options.decimals, 6), integer);
    ns.len = text.len;
    @memcpy(ns.initial[0..text.len], text);
    ns.initial_len = text.len;
    ui.setFocus(widget);
    // A fresh editing session: everything selected, ready to retype.
    ui.text_edit.id = .none;
    ui.requestRedraw();
}

fn commitText(comptime T: type, ui: *Ui, value: *T, options: NumberOptions, result: *Interaction) void {
    const ns = &ui.number_state;
    const ev = options.evaluator orelse &default_evaluator;
    // Nothing typed: the value stays exactly as it was, not as its text.
    if (std.mem.eql(u8, ns.buffer[0..ns.len], ns.initial[0..ns.initial_len])) {
        result.cancelled = true;
        return;
    }
    const typed = std.mem.trim(u8, ns.buffer[0..ns.len], " ");
    // The suffix may be typed back in, as it is shown ("2 m").
    const suffix = std.mem.trim(u8, options.suffix, " ");
    const without = if (suffix.len > 0 and std.mem.endsWith(u8, typed, suffix))
        std.mem.trim(u8, typed[0 .. typed.len - suffix.len], " ")
    else
        typed;
    if (ev.eval(typed) orelse ev.eval(without)) |shown| {
        if (store(T, value, shown, options)) {
            result.changed = true;
            result.committed = true;
            return;
        }
    }
    // Unchanged, or not a number: the edit ends without a step.
    result.cancelled = true;
}

fn drawNumber(ui: *Ui, widget: Id, name: []const u8, field: Rect, shown: f64, integer: bool, options: NumberOptions, result: Interaction) void {
    const style = &ui.style;
    const colors = &style.colors;
    ui.drawRect(.{
        .rect = field,
        .fill = if (result.held) colors.button_active else if (result.hovered) colors.button_hovered else colors.input,
        .border = colors.border,
        .border_width = style.border_width,
        .radius = style.rounding,
    });
    if (options.slider) if (options.min) |lo| if (options.max) |hi| if (hi > lo) {
        const t = std.math.clamp((shown / options.display_scale - lo) / (hi - lo), 0, 1);
        const w: f32 = @floatCast(t * @as(f64, field.w - 2));
        if (w > 0) ui.drawRect(.{ .rect = .{ .x = field.x + 1, .y = field.y + 1, .w = w, .h = field.h - 2 }, .fill = colors.slider_fill, .radius = @max(0, style.rounding - 1) });
    };
    if (options.accent) |c| {
        ui.drawRect(.{ .rect = .{ .x = field.x + 1, .y = field.y + 3, .w = 2, .h = field.h - 6 }, .fill = c, .radius = 1 });
    }

    var number_buffer: [64]u8 = undefined;
    var buffer: [96]u8 = undefined;
    const number = formatValue(&number_buffer, shown, options.decimals, integer);
    const with_suffix = std.fmt.bufPrint(&buffer, "{s}{s}", .{ number, options.suffix }) catch number;
    const pad = style.frame_padding.x * 0.6;
    const y = field.y + style.frame_padding.y;
    ui.pushClip(field.inset(1));
    const value_w = ui.textSize(with_suffix).x;
    const label_text = Ui.visibleLabel(name);
    if (options.label == .inside and label_text.len > 0) {
        ui.pushClip(.{ .x = field.x, .y = field.y, .w = @max(0, field.w - value_w - pad * 2), .h = field.h });
        ui.drawText(.{ .x = field.x + pad, .y = y }, colors.text_muted, label_text);
        ui.popClip();
        ui.drawText(.{ .x = field.right() - pad - value_w, .y = y }, colors.text, with_suffix);
    } else {
        ui.drawText(.{ .x = field.x + (field.w - value_w) / 2, .y = y }, colors.text, with_suffix);
    }
    ui.popClip();
    ui.drawFocusRing(widget, field);
}

fn recordNumber(ui: *Ui, widget: Id, name: []const u8, field: Rect, value: anytype, options: NumberOptions, result: Interaction) void {
    const integer = @typeInfo(@TypeOf(value.*)) == .int;
    var buffer: [64]u8 = undefined;
    const shown = formatValue(&buffer, toF64(value.*) * options.display_scale, options.decimals, integer);
    ui.recordWidgetf(.number, widget, name, field, .{ .hovered = result.hovered, .focused = result.focused }, "{s}{s}", .{ shown, options.suffix });
}

test "formatValue drops trailing zeros" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1.5", formatValue(&b, 1.5, 3, false));
    try std.testing.expectEqualStrings("2", formatValue(&b, 2.0004, 3, false));
    try std.testing.expectEqualStrings("0", formatValue(&b, -0.0001, 3, false));
    try std.testing.expectEqualStrings("-3", formatValue(&b, -3.2, 3, true));
}
