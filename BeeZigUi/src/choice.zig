//! Picking one of several things: drop-down lists, segmented buttons, and
//! icon toggles such as BeeModel's eye, lock and camera.
//!
//!     const kinds = [_]zui.Choice{ .{ .label = "Point" }, .{ .label = "Sun" }, .{ .label = "Spot" } };
//!     _ = ui.dropdown("Light", &kind_index, &kinds, .{});
//!     _ = ui.dropdownEnum("Shading", &shading, .{}); // the items from an enum
//!     _ = ui.segmented("Mode", &mode, &modes, .{});
//!     _ = ui.iconToggle("Visible", &visible, .{ .on = eye, .off = eye_off });
//!
//! A pick reports `started`, `changed` and `committed` together: one undo
//! step. Focused, the arrow keys step through the items.

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const icons = @import("icons.zig");
const ui_mod = @import("ui.zig");
const widgets = @import("widgets.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;

/// One item of a drop-down list or segmented control.
pub const Choice = struct {
    label: []const u8,
    icon: ?icons.Icon = null,
    /// Why it can't be picked now; null if it can. It shows faded, and its
    /// tooltip says why.
    disabled: ?[]const u8 = null,
    /// Shown when the pointer rests on it.
    tooltip: []const u8 = "",
};

/// The open drop-down list's keyboard highlight.
pub const State = struct {
    list: Id = .none,
    highlight: usize = 0,
};

/// Options for `dropdown` and `dropdownEnum`.
pub const DropdownOptions = struct {
    width: layout.Size = .auto,
};

/// A button showing the chosen item; a click opens the list to pick
/// another. `selected` indexes `items`.
pub fn dropdown(ui: *Ui, name: []const u8, selected: *usize, items: []const Choice, options: DropdownOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    const text = Ui.visibleLabel(name);
    const text_w = if (text.len > 0) ui.textSize(text).x else 0;
    const gap: f32 = if (text.len > 0) style.item_spacing.x else 0;
    const line_h = ui.textSize("").y;
    const height = line_h + style.frame_padding.y * 2;
    const rect = ui.placeSized(options.width, .auto, .{ .x = style.widget_width + gap + text_w, .y = height });
    const field: Rect = .{ .x = rect.x, .y = rect.y, .w = @max(0, rect.w - gap - text_w), .h = height };
    const widget = ui.id(name);
    var result = ui.interact(widget, field);
    ui.focusable(widget, &result);
    if (items.len == 0) return result;
    selected.* = @min(selected.*, items.len - 1);

    ui.pushIdValue(widget);
    // Named after the list, so scripts and agents can say "Light > choice:Spot".
    const popup_name = std.fmt.allocPrint(ui.frameAllocator(), "{s}##list", .{if (text.len > 0) text else name}) catch "##list";
    const open = ui.isPopupOpen(popup_name);
    const keys = ui.input.keys_pressed;
    if (!result.disabled and (result.clicked or (result.focused and !open and (keys.contains(.enter) or keys.contains(.space))))) {
        ui.openPopupAt(popup_name, field);
        ui.choice_state = .{ .list = widget, .highlight = selected.* };
    }
    // Focused and closed, arrows step through the enabled items.
    if (result.focused and !open) {
        for (ui.input.keyEvents()) |event| {
            const dir: isize = switch (event.key) {
                .up, .left => -1,
                .down, .right => 1,
                else => 0,
            };
            if (dir == 0) continue;
            if (nextEnabled(items, selected.*, dir)) |i| {
                selected.* = i;
                result.changed = true;
                result.started = true;
                result.committed = true;
            }
        }
    }
    if (ui.beginPopup(popup_name, .{ .min_width = field.w })) {
        defer ui.endPopup();
        if (list(ui, widget, selected, items)) {
            result.changed = true;
            result.started = true;
            result.committed = true;
        }
    }
    ui.popId();

    // The field: the chosen item, and a chevron.
    ui.drawRect(.{
        .rect = field,
        .fill = if (result.held) colors.button_active else if (result.hovered) colors.button_hovered else colors.button,
        .border = colors.border,
        .border_width = style.border_width,
        .radius = style.rounding,
    });
    const chosen = items[selected.*];
    const pad = style.frame_padding.x * 0.75;
    var x = field.x + pad;
    const y = field.y + style.frame_padding.y;
    const chevron = line_h * 0.7;
    ui.pushClip(.{ .x = field.x, .y = field.y, .w = @max(0, field.w - chevron - pad), .h = field.h });
    if (chosen.icon) |ic| {
        ui.painter().icon(ic, .{ .x = x, .y = y, .w = line_h, .h = line_h }, colors.text);
        x += line_h + 6;
    }
    ui.drawText(.{ .x = x, .y = y }, colors.text, chosen.label);
    ui.popClip();
    ui.painter().icon(.{ .builtin = .chevron_down }, .{ .x = field.right() - pad - chevron, .y = field.y + (field.h - chevron) / 2, .w = chevron, .h = chevron }, colors.text_muted);
    if (text.len > 0) ui.drawText(.{ .x = field.right() + gap, .y = y }, colors.text, text);
    ui.drawFocusRing(widget, field);
    ui.recordWidget(.dropdown, widget, name, field, .{ .value = chosen.label, .hovered = result.hovered, .focused = result.focused });
    result.rect = rect;
    return result;
}

/// The next item from `from` in direction `dir` that can be picked.
fn nextEnabled(items: []const Choice, from: usize, dir: isize) ?usize {
    var i: isize = @intCast(from);
    while (true) {
        i += dir;
        if (i < 0 or i >= items.len) return null;
        if (items[@intCast(i)].disabled == null) return @intCast(i);
    }
}

/// The open list. Returns true when an item was picked.
fn list(ui: *Ui, widget: Id, selected: *usize, items: []const Choice) bool {
    const style = &ui.style;
    const colors = &style.colors;
    const cs = &ui.choice_state;
    if (cs.list != widget) cs.* = .{ .list = widget, .highlight = selected.* };
    var picked: ?usize = null;
    for (ui.input.keyEvents()) |event| switch (event.key) {
        .up => cs.highlight = nextEnabled(items, cs.highlight, -1) orelse cs.highlight,
        .down => cs.highlight = nextEnabled(items, cs.highlight, 1) orelse cs.highlight,
        .enter, .space => if (cs.highlight < items.len and items[cs.highlight].disabled == null) {
            picked = cs.highlight;
        },
        else => {},
    };

    const line_h = ui.textSize("").y;
    const pad_y = style.frame_padding.y * 0.6;
    const has_icons = for (items) |it| {
        if (it.icon != null) break true;
    } else false;
    const check_w = line_h;
    const icon_w: f32 = if (has_icons) line_h + 6 else 0;
    for (items, 0..) |item, i| {
        ui.pushIdInt(i);
        defer ui.popId();
        ui.pushDisabled(item.disabled);
        defer ui.popDisabled();
        const natural = check_w + icon_w + ui.textSize(item.label).x + style.frame_padding.x;
        const row = ui.placeSized(.fill, .auto, .{ .x = natural, .y = line_h + 2 * pad_y });
        const r = ui.interact(ui.id("##item"), row);
        if (r.hovered and ui.mouse_delta.length() > 0) cs.highlight = i;
        if (r.clicked) picked = i;
        if (r.hovered or cs.highlight == i) {
            ui.drawRect(.{ .rect = row, .fill = colors.button_hovered, .radius = style.rounding });
        }
        if (i == selected.*) {
            ui.painter().icon(.{ .builtin = .check }, .{ .x = row.x + 2, .y = row.y + pad_y, .w = line_h, .h = line_h }, colors.accent);
        }
        var x = row.x + check_w;
        if (item.icon) |ic| ui.painter().icon(ic, .{ .x = x, .y = row.y + pad_y, .w = line_h, .h = line_h }, colors.text);
        x += icon_w;
        ui.drawText(.{ .x = x, .y = row.y + pad_y }, colors.text, item.label);
        if (item.tooltip.len > 0) ui.tooltipRich(r, .{ .body = item.tooltip, .placement = .beside });
        ui.recordWidget(.choice, ui.id("##item"), item.label, row, .{ .value = if (i == selected.*) "true" else "false", .hovered = r.hovered });
    }
    if (picked) |i| {
        ui.closePopup();
        if (i != selected.*) {
            selected.* = i;
            return true;
        }
    }
    return false;
}

/// Labels for an enum's fields: underscores become spaces and the first
/// letter is a capital, so `area_light` reads "Area light".
pub fn enumChoices(comptime E: type) [std.meta.fieldNames(E).len]Choice {
    const names = comptime std.meta.fieldNames(E);
    var out: [names.len]Choice = undefined;
    inline for (names, 0..) |name, i| {
        const pretty = comptime blk: {
            var b: [name.len]u8 = name[0..name.len].*;
            for (&b) |*c| {
                if (c.* == '_') c.* = ' ';
            }
            if (b.len > 0) b[0] = std.ascii.toUpper(b[0]);
            const final = b;
            break :blk final;
        };
        out[i] = .{ .label = &pretty };
    }
    return out;
}

/// A drop-down list over the values of an enum, labelled by `enumChoices`.
pub fn dropdownEnum(ui: *Ui, name: []const u8, value: anytype, options: DropdownOptions) Interaction {
    const E = @TypeOf(value.*);
    const all = comptime std.enums.values(E);
    const items = comptime enumChoices(E);
    var index: usize = for (all, 0..) |v, i| {
        if (v == value.*) break i;
    } else 0;
    const result = dropdown(ui, name, &index, &items, options);
    if (result.changed) value.* = all[index];
    return result;
}

/// Options for `segmented`.
pub const SegmentedOptions = struct {
    /// `.fill` shares the width out equally.
    width: layout.Size = .auto,
    /// Show only the icons; the labels become their tooltips.
    icons_only: bool = false,
};

/// Joined buttons of which one is chosen: shading modes, alignment, tabs
/// for a small panel. `selected` indexes `items`.
pub fn segmented(ui: *Ui, name: []const u8, selected: *usize, items: []const Choice, options: SegmentedOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    const text = Ui.visibleLabel(name);
    const text_w = if (text.len > 0) ui.textSize(text).x else 0;
    const gap: f32 = if (text.len > 0) style.item_spacing.x else 0;
    const line_h = ui.textSize("").y;
    const height = line_h + style.frame_padding.y * 2;
    if (items.len == 0) return .{};
    selected.* = @min(selected.*, items.len - 1);

    var widths: [32]f32 = undefined;
    const n = @min(items.len, widths.len);
    var natural: f32 = 0;
    for (items[0..n], 0..) |item, i| {
        const show_text = !(options.icons_only and item.icon != null);
        var w: f32 = 2 * style.frame_padding.x * (if (show_text) @as(f32, 1) else 0.5);
        if (item.icon != null) w += line_h;
        if (item.icon != null and show_text) w += 6;
        if (show_text) w += ui.textSize(item.label).x;
        widths[i] = w;
        natural += w;
    }
    const rect = ui.placeSized(options.width, .auto, .{ .x = natural + gap + text_w, .y = height });
    const row_w = @max(0, rect.w - gap - text_w);
    const k = if (natural > 0) row_w / natural else 1;

    var result: Interaction = .{ .rect = rect };
    const group = ui.id(name);
    ui.pushIdValue(group);
    defer ui.popId();
    ui.drawRect(.{ .rect = .{ .x = rect.x, .y = rect.y, .w = row_w, .h = height }, .fill = colors.button, .border = colors.border, .border_width = style.border_width, .radius = style.rounding });
    var x = rect.x;
    for (items[0..n], 0..) |item, i| {
        ui.pushIdInt(i);
        defer ui.popId();
        ui.pushDisabled(item.disabled);
        defer ui.popDisabled();
        const w = widths[i] * k;
        const seg: Rect = .{ .x = x, .y = rect.y, .w = w, .h = height };
        x += w;
        const seg_id = ui.id("##segment");
        var r = ui.interact(seg_id, seg);
        // One Tab stop: the chosen segment.
        if (i == selected.*) ui.focusable(seg_id, &r);
        result.hovered = result.hovered or r.hovered;
        result.context_clicked = result.context_clicked or r.context_clicked;
        if (r.focused) result.focused = true;
        var pick = r.clicked and i != selected.*;
        if (r.focused) {
            for (ui.input.keyEvents()) |event| {
                const dir: isize = switch (event.key) {
                    .left, .up => -1,
                    .right, .down => 1,
                    else => 0,
                };
                if (dir == 0) continue;
                if (nextEnabled(items[0..n], selected.*, dir)) |next| {
                    selected.* = next;
                    pick = false;
                    result.changed = true;
                    result.started = true;
                    result.committed = true;
                }
            }
        }
        if (pick) {
            selected.* = i;
            result.changed = true;
            result.started = true;
            result.committed = true;
        }
        const on = i == selected.*;
        if (on or r.hovered) ui.drawRect(.{ .rect = seg.inset(2), .fill = if (on) colors.button_active else colors.button_hovered, .radius = @max(0, style.rounding - 1) });
        const show_text = !(options.icons_only and item.icon != null);
        const content_w = (if (item.icon != null) line_h else 0) + (if (item.icon != null and show_text) @as(f32, 6) else 0) + (if (show_text) ui.textSize(item.label).x else 0);
        var cx = seg.x + (seg.w - content_w) / 2;
        const cy = seg.y + style.frame_padding.y;
        if (item.icon) |ic| {
            ui.painter().icon(ic, .{ .x = cx, .y = cy, .w = line_h, .h = line_h }, colors.text);
            cx += line_h + 6;
        }
        if (show_text) ui.drawText(.{ .x = cx, .y = cy }, colors.text, item.label);
        if (item.tooltip.len > 0 or !show_text) {
            ui.tooltipRich(r, .{ .title = if (!show_text) item.label else "", .body = item.tooltip });
        }
        ui.drawFocusRing(seg_id, seg);
        ui.recordWidget(.segment, seg_id, item.label, seg, .{ .value = if (on) "true" else "false", .hovered = r.hovered, .focused = r.focused });
    }
    // Keep focus on the chosen segment after the arrows moved it.
    if (result.focused and result.changed) {
        ui.pushIdInt(selected.*);
        ui.setFocus(ui.id("##segment"));
        ui.popId();
    }
    if (text.len > 0) ui.drawText(.{ .x = rect.x + row_w + gap, .y = rect.y + style.frame_padding.y }, colors.text, text);
    return result;
}

/// Options for `iconToggle`.
pub const IconToggleOptions = struct {
    /// Shown while the value is true.
    on: icons.Icon,
    /// Shown while it is false; defaults to `on`, dimmed.
    off: ?icons.Icon = null,
    /// Width and height; defaults to a button's height.
    size: ?f32 = null,
};

/// A small square button showing one icon while `value` is true and
/// another while it is false: an eye, a lock, a camera. The name is its ID
/// and tooltip-free label; add a tooltip with `ui.tooltip`.
pub fn iconToggle(ui: *Ui, name: []const u8, value: *bool, options: IconToggleOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    const line_h = ui.textSize("").y;
    const size = options.size orelse line_h + style.frame_padding.y * 2;
    const rect = ui.place(.{ .x = size, .y = size });
    const widget = ui.id(name);
    var result = ui.interact(widget, rect);
    ui.focusable(widget, &result);
    if (!result.disabled and (result.clicked or widgets.keyActivated(ui, result))) {
        value.* = !value.*;
        result.changed = true;
        result.started = true;
        result.committed = true;
    }
    if (result.hovered or result.held) ui.drawRect(.{ .rect = rect, .fill = if (result.held) colors.button_active else colors.button_hovered, .radius = style.rounding });
    const icon_size = @min(line_h, size - 4);
    const which = if (value.*) options.on else options.off orelse options.on;
    const tint = if (value.*) colors.text else colors.text_muted;
    ui.painter().icon(which, .{ .x = rect.x + (size - icon_size) / 2, .y = rect.y + (size - icon_size) / 2, .w = icon_size, .h = icon_size }, tint);
    ui.drawFocusRing(widget, rect);
    ui.recordWidget(.toggle, widget, name, rect, .{ .value = if (value.*) "true" else "false", .hovered = result.hovered, .focused = result.focused });
    return result;
}

test "enum choices read like words" {
    const Shading = enum { wireframe, solid, material_preview };
    const items = enumChoices(Shading);
    try std.testing.expectEqualStrings("Material preview", items[2].label);
    try std.testing.expectEqualStrings("Wireframe", items[0].label);
}
