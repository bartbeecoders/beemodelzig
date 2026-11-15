//! Colours: a swatch that opens a picker (`colorEdit`), and the picker
//! itself to put anywhere (`colorPicker`).
//!
//! The picker has a saturation and value square, a hue strip, an alpha
//! strip, the old colour beside the new one (click the old one to go
//! back), a hex field, R G B or H S V fields, the app's swatches, recent
//! colours and an eyedropper that takes a colour from anywhere in the
//! window. Right-click a swatch to copy or paste its hex code, or reset it.
//!
//!     var recent: zui.RecentColors = .{};
//!     _ = ui.colorEdit("Base Color", &material.color, .{
//!         .recent = &recent,
//!         .swatches = &palette,
//!         .default = .hex(0xCCCCCC),
//!     });
//!
//! The eyedropper needs the backend to read a pixel back: after rendering,
//! if `ui.sample_request` is set, pass the pixel there to
//! `ui.input.onColorSample` (the demo harness does this).

const std = @import("std");
const draw = @import("draw.zig");
const ui_mod = @import("ui.zig");
const color = @import("color.zig");
const record = @import("record.zig");
const choice = @import("choice.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Color = draw.Color;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;
const Hsv = color.Hsv;

/// Recently chosen colours, newest first. The app owns it (and may save
/// it); pickers add to it whenever an edit is committed.
pub const RecentColors = struct {
    items: [max]Color = undefined,
    len: usize = 0,

    /// How many it keeps.
    pub const max = 10;

    /// Puts `c` first, removing an earlier copy, dropping the oldest.
    pub fn add(self: *RecentColors, c: Color) void {
        var i: usize = 0;
        while (i < self.len and !self.items[i].eql(c)) i += 1;
        if (i == self.len) {
            if (self.len < max) self.len += 1;
            i = self.len - 1;
        }
        while (i > 0) : (i -= 1) self.items[i] = self.items[i - 1];
        self.items[0] = c;
    }

    /// The colours, newest first.
    pub fn slice(self: *const RecentColors) []const Color {
        return self.items[0..self.len];
    }
};

/// Options for `colorPicker` and `colorEdit`.
pub const PickerOptions = struct {
    /// Offer an alpha strip and field, and show the hex code with alpha.
    alpha: bool = true,
    /// The app's colours to choose from, such as a palette.
    swatches: []const Color = &.{},
    /// Recent colours: shown, and added to on each commit.
    recent: ?*RecentColors = null,
    /// What Reset in a swatch's menu goes back to; no Reset if null.
    default: ?Color = null,
    /// Offer the eyedropper. It needs a backend that reads pixels back.
    eyedropper: bool = true,
    /// `colorEdit` only: the label, then the swatch filling the rest of
    /// the width; no hex code. For narrow places such as nodes.
    compact: bool = false,
};

/// `colorEdit` takes the picker's options.
pub const ColorEditOptions = PickerOptions;

/// A picker's working state: the hue survives greys and black, and the
/// old colour is what the picker started from.
const PickerSlot = struct {
    widget: Id = .none,
    hsv: Hsv = .{},
    /// The colour `hsv` was last synced with; a different colour means it
    /// was changed elsewhere.
    synced: Color = .{},
    old: Color = .{},
    /// 0: R G B fields, 1: H S V.
    mode: usize = 0,
    used: u64 = 0,
};

/// Picker state kept in the `Ui`.
pub const State = struct {
    slots: [4]PickerSlot = @splat(.{}),
    /// The eyedropper is taking a colour for this picker.
    picking: Id = .none,
    picking_seen: bool = false,
    /// The colour before the eyedropper started, for Escape.
    before_pick: Color = .{},
    /// This frame's left press was taken by the eyedropper.
    pick_click: bool = false,
    pick_cancel: bool = false,
    /// The next picker described starts over (a popup just opened).
    fresh: bool = false,
    /// The hex field's text while it is edited. One at a time.
    hex: HexState = .{},
};

/// The hex field's text while it is edited.
pub const HexState = struct {
    buffer: [9]u8 = undefined,
    len: usize = 0,
};

/// Called by `Ui.beginFrame`: while the eyedropper is out, the left press
/// and Escape are its own and reach no widget.
pub fn beginFrame(ui: *Ui) void {
    const st = &ui.picker_state;
    st.pick_click = false;
    st.pick_cancel = false;
    st.picking_seen = false;
    if (st.picking == .none) return;
    const in = &ui.input;
    if (in.mouse_pressed.contains(.left)) {
        in.mouse_pressed.remove(.left);
        st.pick_click = true;
    }
    if (in.keys_pressed.contains(.escape)) {
        in.keys_pressed.remove(.escape);
        st.pick_cancel = true;
    }
}

/// Called by `Ui.endFrame`: an eyedropper whose picker is gone stops.
pub fn endFrame(ui: *Ui) void {
    const st = &ui.picker_state;
    if (!st.picking_seen) st.picking = .none;
    if (st.picking == .none) ui.sample_request = null;
}

fn slotFor(ui: *Ui, widget: Id, c: Color, fresh: bool) *PickerSlot {
    const st = &ui.picker_state;
    var slot: *PickerSlot = &st.slots[0];
    var found = false;
    for (&st.slots) |*s| {
        if (s.widget == widget) {
            slot = s;
            found = true;
            break;
        }
        if (s.used < slot.used) slot = s;
    }
    if (!found or fresh) {
        const mode = if (found) slot.mode else 0;
        slot.* = .{ .widget = widget, .hsv = color.toHsv(c), .synced = c, .old = c, .mode = mode };
    } else if (!slot.synced.eql(c)) {
        sync(slot, c);
    }
    slot.used = ui.frame_index;
    return slot;
}

/// Takes HSV from `c`, keeping the hue where it is undefined (greys) and
/// the saturation at black.
fn sync(slot: *PickerSlot, c: Color) void {
    var hsv = color.toHsv(c);
    if (hsv.v == 0) {
        hsv.h = slot.hsv.h;
        hsv.s = slot.hsv.s;
    } else if (hsv.s == 0) {
        hsv.h = slot.hsv.h;
    }
    slot.hsv = hsv;
    slot.synced = c;
}

fn setHsv(slot: *PickerSlot, c: *Color, hsv: Hsv) void {
    slot.hsv = hsv;
    c.* = color.fromHsv(hsv, c.a);
    slot.synced = c.*;
}

/// A swatch and hex code for `color`, with the label to the right. Click
/// the swatch, or press Enter or Space on it, for the picker in a popup;
/// right-click it to copy, paste or reset.
pub fn colorEdit(ui: *Ui, name: []const u8, c: *Color, options: ColorEditOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    const label_text = Ui.visibleLabel(name);
    const line_h = ui.textSize(label_text).y;
    const height = line_h + 2 * style.frame_padding.y;
    const swatch_w = height * 1.6;
    const gap = style.item_spacing.x;

    var hex_buffer: [9]u8 = undefined;
    const hex = formatHex(&hex_buffer, c.*, options.alpha);
    const hex_w = ui.textSize("#DDDDDDDD").x * (if (options.alpha) @as(f32, 1) else 0.8);
    const label_w = ui.textSize(label_text).x;
    const rect = if (options.compact)
        ui.placeSized(.fill, .auto, .{ .x = label_w + gap + swatch_w, .y = height })
    else
        ui.place(.{ .x = swatch_w + gap + hex_w + (if (label_text.len > 0) gap + label_w else 0), .y = height });
    const swatch: Rect = if (options.compact)
        .{ .x = rect.x + label_w + gap, .y = rect.y, .w = @max(swatch_w / 2, rect.w - label_w - gap), .h = height }
    else
        .{ .x = rect.x, .y = rect.y, .w = swatch_w, .h = height };

    const widget = ui.id(name);
    var result = ui.interact(widget, swatch);
    ui.focusable(widget, &result);
    result.rect = rect;
    const keys = ui.input.keys_pressed;
    const by_key = result.focused and (keys.contains(.enter) or keys.contains(.space));

    drawSwatch(ui, swatch, c.*);
    if (result.hovered or result.held) {
        ui.drawRect(.{ .rect = swatch, .border = colors.accent, .border_width = style.border_width, .radius = swatchRadius(ui, c.*) });
    }
    ui.drawFocusRing(widget, swatch);
    ui.recordWidget(.color_edit, widget, name, swatch, .{ .value = hex, .hovered = result.hovered, .focused = result.focused });
    if (options.compact) {
        ui.drawText(.{ .x = rect.x, .y = rect.y + style.frame_padding.y }, colors.text, label_text);
    } else {
        ui.drawText(.{ .x = swatch.right() + gap, .y = rect.y + style.frame_padding.y }, colors.text_muted, hex);
    }
    if (label_text.len > 0 and !options.compact) {
        ui.drawText(.{ .x = swatch.right() + gap + hex_w + gap, .y = rect.y + style.frame_padding.y }, colors.text, label_text);
    }

    ui.pushIdValue(widget);
    defer ui.popId();
    merge(&result, swatchMenu(ui, result, c, options));
    if (result.pressed or by_key) {
        ui.openPopupAt("##picker", swatch);
        // The picker starts over: the old colour is this one.
        ui.picker_state.fresh = true;
    }
    if (ui.beginPopup("##picker", .{ .min_width = 260 })) {
        defer ui.endPopup();
        merge(&result, colorPicker(ui, "##colors", c, options));
    }
    return result;
}

/// Right-click menu of a swatch: copy and paste the hex code, reset.
fn swatchMenu(ui: *Ui, item: Interaction, c: *Color, options: PickerOptions) Interaction {
    var edit: Interaction = .{};
    if (!ui.beginContextMenu(item, "##swatch menu")) return edit;
    defer ui.endMenu();
    var buffer: [9]u8 = undefined;
    if (ui.menuItem("Copy Hex", .{})) ui.setClipboard(formatHex(&buffer, c.*, options.alpha and c.a != 255));
    const pasted = parseHex(ui.getClipboard());
    if (ui.menuItem("Paste Hex", .{ .disabled = if (pasted == null) "The clipboard holds no colour" else null })) {
        if (pasted) |p| {
            c.* = if (options.alpha) p else p.withAlpha(c.a);
            edit = .{ .changed = true, .started = true, .committed = true };
        }
    }
    if (ui.menuItem("Reset", .{ .disabled = if (options.default == null) "There is no default colour" else null })) {
        if (options.default) |d| {
            c.* = d;
            edit = .{ .changed = true, .started = true, .committed = true };
        }
    }
    return edit;
}

/// The picker, placed in the layout: in a popup (as `colorEdit` does), a
/// panel or a dialog. Returns the edit flags; one drag, typed value,
/// swatch click or eyedropper pick is one commit.
pub fn colorPicker(ui: *Ui, name: []const u8, c: *Color, options: PickerOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    const widget = ui.id(name);
    const slot = slotFor(ui, widget, c.*, ui.picker_state.fresh);
    ui.picker_state.fresh = false;
    var edit: Interaction = .{ .id = widget };
    ui.pushIdValue(widget);
    defer ui.popId();
    ui.beginVertical(.{ .width = .fill, .id = "##picker" });
    defer ui.endVertical();

    // The square and the strips.
    const strip_w: f32 = 18;
    const gap = style.item_spacing.x;
    const square_h: f32 = 150;
    const area = ui.placeSized(.fill, .{ .fixed = square_h }, .{ .x = 240, .y = square_h });
    const strips: f32 = if (options.alpha) 2 else 1;
    const square: Rect = .{ .x = area.x, .y = area.y, .w = @max(40, area.w - strips * (strip_w + gap)), .h = area.h };
    const hue_rect: Rect = .{ .x = square.right() + gap, .y = area.y, .w = strip_w, .h = area.h };
    const alpha_rect: Rect = .{ .x = hue_rect.right() + gap, .y = area.y, .w = strip_w, .h = area.h };

    merge(&edit, squareArea(ui, slot, c, square));
    merge(&edit, hueStrip(ui, slot, c, hue_rect));
    if (options.alpha) merge(&edit, alphaStrip(ui, c, alpha_rect));

    // Old and new, the eyedropper and the hex code.
    ui.beginHorizontal(.{});
    const height = ui.textSize("").y + 2 * style.frame_padding.y;
    const pair = ui.place(.{ .x = 72, .y = height });
    const old_rect: Rect = .{ .x = pair.x, .y = pair.y, .w = pair.w / 2, .h = pair.h };
    const new_rect: Rect = .{ .x = pair.x + pair.w / 2, .y = pair.y, .w = pair.w / 2, .h = pair.h };
    drawSwatch(ui, old_rect, slot.old);
    drawSwatch(ui, new_rect, c.*);
    const old_id = ui.id("Old");
    const old = ui.interact(old_id, old_rect);
    var hex_old: [9]u8 = undefined;
    ui.recordWidget(.swatch, old_id, "Old", old_rect, .{ .value = formatHex(&hex_old, slot.old, options.alpha), .hovered = old.hovered });
    ui.tooltip(old, "The colour before: click to go back to it");
    if (old.clicked and !c.eql(slot.old)) {
        c.* = slot.old;
        edit.changed = true;
        edit.started = true;
        edit.committed = true;
    }
    const new_id = ui.id("New");
    var hex_new: [9]u8 = undefined;
    var new_item = ui.interact(new_id, new_rect);
    new_item.rect = new_rect;
    ui.recordWidget(.swatch, new_id, "New", new_rect, .{ .value = formatHex(&hex_new, c.*, options.alpha), .hovered = new_item.hovered });
    merge(&edit, swatchMenu(ui, new_item, c, options));

    if (options.eyedropper) {
        const picking = ui.picker_state.picking == widget;
        const b = ui.button("##eyedropper", .{ .icon = .{ .builtin = .eyedropper } });
        if (picking) ui.drawRect(.{ .rect = b.rect, .border = colors.accent, .border_width = 2, .radius = style.rounding });
        ui.tooltip(b, "Take a colour from anywhere in the window (Esc cancels)");
        if (b.clicked and !picking) {
            ui.picker_state.picking = widget;
            ui.picker_state.before_pick = c.*;
            ui.input.sampled = null;
        }
    }
    merge(&edit, hexField(ui, slot, c, options));
    ui.endHorizontal();

    // R G B or H S V fields.
    _ = ui.segmented("##mode", &slot.mode, &.{ .{ .label = "RGB" }, .{ .label = "HSV" } }, .{ .width = .fill });
    ui.beginHorizontal(.{ .spacing = 4 });
    if (slot.mode == 0) {
        inline for (.{ .{ "R", "r" }, .{ "G", "g" }, .{ "B", "b" } }) |n| {
            var v: f64 = @floatFromInt(@field(c, n[1]));
            const f = ui.numberField(n[0], &v, .{ .width = .fill, .min = 0, .max = 255, .step = 1, .decimals = 0, .slider = true });
            if (f.changed) @field(c, n[1]) = @intFromFloat(@round(std.math.clamp(v, 0, 255)));
            merge(&edit, f);
        }
    } else {
        var h: f64 = slot.hsv.h;
        var s: f64 = slot.hsv.s * 100;
        var v: f64 = slot.hsv.v * 100;
        const fh = ui.numberField("H", &h, .{ .width = .fill, .min = 0, .max = 360, .step = 1, .decimals = 1, .suffix = "\u{00B0}", .slider = true });
        const fs = ui.numberField("S", &s, .{ .width = .fill, .min = 0, .max = 100, .step = 1, .decimals = 1, .suffix = "%", .slider = true });
        const fv = ui.numberField("V", &v, .{ .width = .fill, .min = 0, .max = 100, .step = 1, .decimals = 1, .suffix = "%", .slider = true });
        if (fh.changed or fs.changed or fv.changed) {
            setHsv(slot, c, .{ .h = @floatCast(h), .s = @floatCast(s / 100), .v = @floatCast(v / 100) });
        }
        merge(&edit, fh);
        merge(&edit, fs);
        merge(&edit, fv);
    }
    if (options.alpha) {
        var a: f64 = @floatFromInt(c.a);
        const f = ui.numberField("A", &a, .{ .width = .fill, .min = 0, .max = 255, .step = 1, .decimals = 0, .slider = true });
        if (f.changed) c.a = @intFromFloat(@round(std.math.clamp(a, 0, 255)));
        merge(&edit, f);
    }
    ui.endHorizontal();

    merge(&edit, swatchRow(ui, "Swatches", options.swatches, c, options));
    if (options.recent) |recent| merge(&edit, swatchRow(ui, "Recent", recent.slice(), c, options));

    merge(&edit, eyedropper(ui, widget, c));
    if (!c.eql(slot.synced)) sync(slot, c.*);
    if (edit.committed) if (options.recent) |recent| recent.add(c.*);
    return edit;
}

/// Turns pointer travel over `rect` into a 0..1 fraction on each axis.
fn fractions(ui: *const Ui, rect: Rect) Vec2 {
    const m = ui.input.mouse_pos;
    return .{
        .x = std.math.clamp((m.x - rect.x) / @max(1, rect.w), 0, 1),
        .y = std.math.clamp((m.y - rect.y) / @max(1, rect.h), 0, 1),
    };
}

/// A drag area: press starts, moving changes, release commits, Escape
/// puts the colour back.
fn dragArea(ui: *Ui, name: []const u8, rect: Rect, c: *Color, slot: ?*PickerSlot) struct { item: Interaction, active: bool } {
    const widget = ui.id(name);
    const was_held = ui.active == widget;
    var item = ui.interact(widget, rect);
    item.rect = rect;
    const backup = std.mem.bytesAsValue(Color, ui.drag_backup[0..@sizeOf(Color)]);
    if (item.pressed) {
        backup.* = c.*;
        item.started = true;
    }
    if (item.held and ui.input.keys_pressed.contains(.escape)) {
        ui.input.keys_pressed.remove(.escape);
        c.* = backup.*;
        if (slot) |s| sync(s, c.*);
        ui.active = .none;
        item.held = false;
        item.cancelled = true;
        item.changed = true;
    }
    if (was_held and !item.held and !item.cancelled) {
        if (!c.eql(backup.*)) item.committed = true else item.cancelled = true;
    }
    if (item.held) ui.cursor = .crosshair;
    return .{ .item = item, .active = item.held };
}

fn squareArea(ui: *Ui, slot: *PickerSlot, c: *Color, rect: Rect) Interaction {
    const d = dragArea(ui, "Saturation and value", rect, c, slot);
    var item = d.item;
    if (d.active) {
        const f = fractions(ui, rect);
        const before = c.*;
        setHsv(slot, c, .{ .h = slot.hsv.h, .s = f.x, .v = 1 - f.y });
        if (!c.eql(before)) item.changed = true;
    }
    // White to the pure hue across, then black coming up from below.
    const p = ui.painter();
    const hue = color.fromHsv(.{ .h = slot.hsv.h, .s = 1, .v = 1 }, 255);
    p.gradient(rect, Color.white, hue, Color.white, hue);
    p.gradient(rect, Color.black.withAlpha(0), Color.black.withAlpha(0), Color.black, Color.black);
    ui.drawRect(.{ .rect = rect, .border = ui.style.colors.border, .border_width = 1 });
    const at: Vec2 = .{ .x = rect.x + slot.hsv.s * rect.w, .y = rect.y + (1 - slot.hsv.v) * rect.h };
    ui.pushClip(rect);
    p.circleOutline(at, 6, Color.black.withAlpha(160), 3);
    p.circleOutline(at, 6, Color.white, 1.5);
    ui.popClip();
    var buffer: [32]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, "{d:.0}% {d:.0}%", .{ slot.hsv.s * 100, slot.hsv.v * 100 }) catch "";
    ui.recordWidget(.color_area, item.id, "Saturation and value", rect, .{ .value = value, .hovered = item.hovered });
    return item;
}

const hue_stops = [_]Color{ Color.hex(0xFF0000), Color.hex(0xFFFF00), Color.hex(0x00FF00), Color.hex(0x00FFFF), Color.hex(0x0000FF), Color.hex(0xFF00FF), Color.hex(0xFF0000) };

fn hueStrip(ui: *Ui, slot: *PickerSlot, c: *Color, rect: Rect) Interaction {
    const d = dragArea(ui, "Hue", rect, c, slot);
    var item = d.item;
    if (d.active) {
        const before = c.*;
        setHsv(slot, c, .{ .h = fractions(ui, rect).y * 360, .s = slot.hsv.s, .v = slot.hsv.v });
        // A grey has no hue to show; the marker moves anyway.
        if (!c.eql(before)) item.changed = true;
    }
    const p = ui.painter();
    const seg = rect.h / 6;
    for (0..6) |i| {
        const y = rect.y + seg * @as(f32, @floatFromInt(i));
        p.gradient(.{ .x = rect.x, .y = y, .w = rect.w, .h = seg }, hue_stops[i], hue_stops[i], hue_stops[i + 1], hue_stops[i + 1]);
    }
    ui.drawRect(.{ .rect = rect, .border = ui.style.colors.border, .border_width = 1 });
    marker(ui, rect, slot.hsv.h / 360);
    var buffer: [16]u8 = undefined;
    ui.recordWidget(.color_area, item.id, "Hue", rect, .{ .value = std.fmt.bufPrint(&buffer, "{d:.0}", .{slot.hsv.h}) catch "", .hovered = item.hovered });
    return item;
}

fn alphaStrip(ui: *Ui, c: *Color, rect: Rect) Interaction {
    const d = dragArea(ui, "Alpha", rect, c, null);
    var item = d.item;
    if (d.active) {
        const a: u8 = @intFromFloat(@round((1 - fractions(ui, rect).y) * 255));
        if (a != c.a) {
            c.a = a;
            item.changed = true;
        }
    }
    drawChecker(ui, rect);
    ui.painter().gradient(rect, c.withAlpha(255), c.withAlpha(255), c.withAlpha(0), c.withAlpha(0));
    ui.drawRect(.{ .rect = rect, .border = ui.style.colors.border, .border_width = 1 });
    marker(ui, rect, 1 - @as(f32, @floatFromInt(c.a)) / 255);
    var buffer: [8]u8 = undefined;
    ui.recordWidget(.color_area, item.id, "Alpha", rect, .{ .value = std.fmt.bufPrint(&buffer, "{d}", .{c.a}) catch "", .hovered = item.hovered });
    return item;
}

/// A bar across a strip at `t` (0 top, 1 bottom).
fn marker(ui: *Ui, rect: Rect, t: f32) void {
    const y = rect.y + std.math.clamp(t, 0, 1) * rect.h;
    const bar: Rect = .{ .x = rect.x - 2, .y = y - 3, .w = rect.w + 4, .h = 6 };
    ui.drawRect(.{ .rect = bar, .border = Color.black.withAlpha(170), .border_width = 3, .radius = 2 });
    ui.drawRect(.{ .rect = bar, .border = Color.white, .border_width = 1.5, .radius = 2 });
}

fn hexField(ui: *Ui, slot: *PickerSlot, c: *Color, options: PickerOptions) Interaction {
    var edit: Interaction = .{};
    // It shows the colour until it is being edited, then applies whatever
    // parses.
    const field = ui.id("Hex");
    const state = &ui.picker_state.hex;
    if (ui.focused != field) state.len = formatHex(&state.buffer, c.*, options.alpha and c.a != 255).len;
    const hex = ui.textInput("Hex", &state.buffer, &state.len, .{ .width = .fill });
    if (hex.changed) {
        if (parseHex(state.buffer[0..state.len])) |parsed| {
            c.* = if (options.alpha) parsed else parsed.withAlpha(c.a);
            sync(slot, c.*);
            edit.changed = true;
        }
    }
    edit.started = hex.started;
    edit.committed = hex.committed;
    edit.cancelled = hex.cancelled;
    return edit;
}

fn swatchRow(ui: *Ui, title: []const u8, swatches: []const Color, c: *Color, options: PickerOptions) Interaction {
    var edit: Interaction = .{};
    if (swatches.len == 0) return edit;
    const style = &ui.style;
    ui.label(title, .{ .color = style.colors.text_muted });
    const size: f32 = 20;
    const gap: f32 = 4;
    const area = ui.placeSized(.fill, .auto, .{ .x = 200, .y = size });
    const per_row: usize = @max(1, @as(usize, @intFromFloat(@floor((area.w + gap) / (size + gap)))));
    const rows = (swatches.len + per_row - 1) / per_row;
    // Claim the height the rows need (the first row came with `area`).
    if (rows > 1) _ = ui.placeSized(.fill, .{ .fixed = @as(f32, @floatFromInt(rows - 1)) * (size + gap) - style.item_spacing.y }, .{});
    ui.pushId(title);
    defer ui.popId();
    for (swatches, 0..) |s, i| {
        const r: Rect = .{
            .x = area.x + @as(f32, @floatFromInt(i % per_row)) * (size + gap),
            .y = area.y + @as(f32, @floatFromInt(i / per_row)) * (size + gap),
            .w = size,
            .h = size,
        };
        ui.pushIdInt(i);
        const widget = ui.id("swatch");
        ui.popId();
        var item = ui.interact(widget, r);
        item.rect = r;
        drawSwatch(ui, r, s);
        if (s.eql(c.*)) ui.drawRect(.{ .rect = r.inset(-2), .border = style.colors.accent, .border_width = 2, .radius = style.rounding + 1 });
        if (item.hovered) ui.drawRect(.{ .rect = r, .border = style.colors.text, .border_width = 1, .radius = swatchRadius(ui, s) });
        var buffer: [9]u8 = undefined;
        const hex = formatHex(&buffer, s, s.a != 255);
        ui.recordWidget(.swatch, widget, hex, r, .{ .value = title, .hovered = item.hovered });
        ui.tooltip(item, hex);
        if (item.clicked and !c.eql(s)) {
            c.* = if (options.alpha) s else s.withAlpha(c.a);
            edit = .{ .changed = true, .started = true, .committed = true };
        }
        if (item.context_clicked) {
            ui.setClipboard(hex);
            _ = ui.toast("Copied", .info, .{});
        }
    }
    return edit;
}

/// The eyedropper while it is out: the colour under the pointer shows
/// live; a click keeps it, Escape puts the old one back.
fn eyedropper(ui: *Ui, widget: Id, c: *Color) Interaction {
    const st = &ui.picker_state;
    var edit: Interaction = .{};
    if (st.picking != widget) return edit;
    st.picking_seen = true;
    if (st.pick_cancel) {
        if (!c.eql(st.before_pick)) {
            c.* = st.before_pick;
            edit.changed = true;
        }
        edit.cancelled = true;
        st.picking = .none;
        ui.sample_request = null;
        return edit;
    }
    const m = ui.input.mouse_pos;
    ui.sample_request = m;
    ui.cursor = .crosshair;
    if (ui.input.sampled) |s| {
        if (!s.eql(c.*)) {
            c.* = s;
            edit.changed = true;
        }
    }
    if (st.pick_click) {
        st.picking = .none;
        ui.sample_request = null;
        edit.started = true;
        if (!c.eql(st.before_pick)) edit.committed = true else edit.cancelled = true;
        return edit;
    }
    // A chip at the pointer with the colour and its code.
    var buffer: [9]u8 = undefined;
    const hex = formatHex(&buffer, c.*, false);
    const style = &ui.style;
    const line = ui.font.lineMetrics(style.font_size);
    const w = ui.textSize(hex).x + 40;
    const chip: Rect = .{ .x = m.x + 18, .y = m.y + 18, .w = w, .h = line.height + 10 };
    const list = &ui.overlay;
    list.setClip(null) catch {};
    list.addRect(.{ .rect = chip, .fill = style.colors.popup, .border = style.colors.border, .border_width = 1, .radius = style.rounding }) catch {};
    list.addRect(.{ .rect = .{ .x = chip.x + 5, .y = chip.y + 5, .w = 20, .h = chip.h - 10 }, .fill = c.withAlpha(255), .border = style.colors.border, .border_width = 1, .radius = 3 }) catch {};
    list.addText(.{ .font = ui.font, .pos = .{ .x = chip.x + 32, .y = chip.y + 5 + line.ascent }, .size = style.font_size, .color = style.colors.text, .text = hex }) catch {};
    record.recordOverlay(ui, .drag, .none, "Eyedropper", chip);
    return edit;
}

/// Adds `from`'s edit flags to `into`.
fn merge(into: *Interaction, from: Interaction) void {
    into.changed = into.changed or from.changed;
    into.started = into.started or from.started;
    into.committed = into.committed or from.committed;
    into.cancelled = into.cancelled or from.cancelled;
}

fn swatchRadius(ui: *const Ui, c: Color) f32 {
    // A checkerboard can't follow rounded corners, so translucent swatches
    // stay square.
    return if (c.a == 255) ui.style.rounding else 0;
}

fn drawChecker(ui: *Ui, rect: Rect) void {
    const cell = 6;
    ui.drawRect(.{ .rect = rect, .fill = Color.hex(0xFFFFFF) });
    var y: f32 = 0;
    var row: u32 = 0;
    while (y < rect.h) : ({
        y += cell;
        row += 1;
    }) {
        var x: f32 = if (row % 2 == 0) 0 else cell;
        while (x < rect.w) : (x += 2 * cell) {
            ui.drawRect(.{
                .rect = .{ .x = rect.x + x, .y = rect.y + y, .w = @min(cell, rect.w - x), .h = @min(cell, rect.h - y) },
                .fill = Color.hex(0xC8C8C8),
            });
        }
    }
}

/// Fills `rect` with `color`, over a checkerboard where it is translucent.
pub fn drawSwatch(ui: *Ui, rect: Rect, c: Color) void {
    if (c.a < 255) drawChecker(ui, rect);
    ui.drawRect(.{
        .rect = rect,
        .fill = c,
        .border = ui.style.colors.border,
        .border_width = ui.style.border_width,
        .radius = swatchRadius(ui, c),
    });
}

/// Writes `#RRGGBB`, or `#RRGGBBAA` with alpha, into `buffer`.
pub fn formatHex(buffer: *[9]u8, c: Color, alpha: bool) []const u8 {
    const digits = "0123456789ABCDEF";
    const bytes = [4]u8{ c.r, c.g, c.b, c.a };
    const n: usize = if (alpha) 4 else 3;
    buffer[0] = '#';
    for (bytes[0..n], 0..) |b, i| {
        buffer[1 + 2 * i] = digits[b >> 4];
        buffer[2 + 2 * i] = digits[b & 0xF];
    }
    return buffer[0 .. 1 + 2 * n];
}

/// Parses `RRGGBB` or `RRGGBBAA`, with or without a leading `#`, any case.
pub fn parseHex(text: []const u8) ?Color {
    const digits = std.mem.trim(u8, std.mem.trimStart(u8, std.mem.trim(u8, text, " \t\r\n"), "#"), " ");
    if (digits.len != 6 and digits.len != 8) return null;
    var bytes: [4]u8 = .{ 0, 0, 0, 255 };
    for (0..digits.len / 2) |i| {
        bytes[i] = std.fmt.parseInt(u8, digits[2 * i ..][0..2], 16) catch return null;
    }
    return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = bytes[3] };
}

const testing = std.testing;

test "hex round trip" {
    var buffer: [9]u8 = undefined;
    const c: Color = .{ .r = 0x12, .g = 0xAB, .b = 0xFF, .a = 0x80 };
    try testing.expectEqualStrings("#12ABFF80", formatHex(&buffer, c, true));
    try testing.expectEqualStrings("#12ABFF", formatHex(&buffer, c, false));
    try testing.expectEqual(c, parseHex("#12abff80").?);
    try testing.expectEqual(Color.hex(0x12ABFF), parseHex(" 12ABFF ").?);
    try testing.expectEqual(@as(?Color, null), parseHex("#12AB"));
    try testing.expectEqual(@as(?Color, null), parseHex("#12ABZZ"));
}

test "recent colours: newest first, no repeats, oldest dropped" {
    var r: RecentColors = .{};
    for (0..12) |i| r.add(Color.hex(@intCast(i)));
    try testing.expectEqual(@as(usize, RecentColors.max), r.len);
    try testing.expectEqual(Color.hex(11), r.slice()[0]);
    r.add(Color.hex(5));
    try testing.expectEqual(Color.hex(5), r.slice()[0]);
    try testing.expectEqual(Color.hex(11), r.slice()[1]);
    try testing.expectEqual(@as(usize, RecentColors.max), r.len);
}
