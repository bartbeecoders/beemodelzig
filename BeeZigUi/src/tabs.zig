//! Tab bars: a row of tabs for workspaces (with + to add, double-click to
//! rename, a cross to close), or a column of icon tabs like BeeModel's
//! Properties editor.
//!
//!     const r = ui.tabBar("workspaces", &current, &tabs, .{ .addable = true, .renamable = true, .closable = true });
//!     if (r.add) addWorkspace();
//!     if (r.close) |i| removeWorkspace(i);
//!     if (r.rename) |rn| renameWorkspace(rn.index, rn.text);
//!
//! Focused, Left and Right (Up and Down for a column) move between tabs.

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const icons = @import("icons.zig");
const ui_mod = @import("ui.zig");
const text_input = @import("text_input.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Rect = draw.Rect;

/// One tab.
pub const Tab = struct {
    label: []const u8,
    icon: ?icons.Icon = null,
    tooltip: []const u8 = "",
    disabled: ?[]const u8 = null,
};

/// The next tab from `from` in direction `dir` that isn't disabled.
fn nextEnabled(tabs: []const Tab, from: usize, dir: isize) ?usize {
    var i: isize = @intCast(from);
    while (true) {
        i += dir;
        if (i < 0 or i >= tabs.len) return null;
        if (tabs[@intCast(i)].disabled == null) return @intCast(i);
    }
}

/// Options for `tabBar`.
pub const TabBarOptions = struct {
    /// A column of icon tabs, the labels in their tooltips.
    vertical: bool = false,
    /// A + button after the tabs.
    addable: bool = false,
    /// A cross on the chosen and the hovered tab.
    closable: bool = false,
    /// Double-click a tab to rename it.
    renamable: bool = false,
};

/// What happened to a tab bar this frame.
pub const TabBarResult = struct {
    /// `selected` changed.
    changed: bool = false,
    /// The + button was clicked.
    add: bool = false,
    /// This tab's cross was clicked.
    close: ?usize = null,
    /// A tab was renamed; the text is valid until the next frame.
    rename: ?struct { index: usize, text: []const u8 } = null,
};

/// The tab being renamed.
pub const State = struct {
    bar: Id = .none,
    index: usize = 0,
    buffer: [64]u8 = undefined,
    len: usize = 0,
    started: bool = false,
};

/// A row (or column) of tabs; `selected` indexes `tabs`.
pub fn tabBar(ui: *Ui, name: []const u8, selected: *usize, tabs: []const Tab, options: TabBarOptions) TabBarResult {
    if (options.vertical) return column(ui, name, selected, tabs);
    const style = &ui.style;
    const colors = &style.colors;
    var result: TabBarResult = .{};
    if (tabs.len > 0) selected.* = @min(selected.*, tabs.len - 1);
    const bar = ui.id(name);
    ui.pushIdValue(bar);
    defer ui.popId();
    const line_h = ui.textSize("").y;
    const pad_x = style.frame_padding.x;
    const height = line_h + style.frame_padding.y * 2;
    const close_w: f32 = if (options.closable) line_h else 0;
    const rs = &ui.tab_state;

    ui.beginHorizontal(.{ .spacing = 2 });
    for (tabs, 0..) |tab, i| {
        ui.pushIdInt(i);
        defer ui.popId();
        const renaming = rs.bar == bar and rs.index == i;
        const icon_w: f32 = if (tab.icon != null) line_h + 6 else 0;
        const text_w = if (renaming) @max(ui.textSize(rs.buffer[0..rs.len]).x + 20, 80) else ui.textSize(tab.label).x;
        const rect = ui.place(.{ .x = pad_x * 2 + icon_w + text_w + close_w, .y = height });
        const tab_id = ui.id("##tab");
        ui.pushDisabled(tab.disabled);
        var r = ui.interact(tab_id, rect);
        if (i == selected.*) ui.focusable(tab_id, &r);
        ui.popDisabled();
        const on = i == selected.*;
        const close_rect: Rect = .{ .x = rect.right() - pad_x * 0.5 - close_w, .y = rect.y + (rect.h - close_w) / 2, .w = close_w, .h = close_w };

        if (renaming) {
            // Typing the new name in place of the label.
            const field: Rect = .{ .x = rect.x + 2, .y = rect.y + 1, .w = rect.w - 4, .h = rect.h - 2 };
            if (!rs.started) {
                rs.started = true;
                ui.setFocus(tab_id);
                ui.text_edit.id = .none;
            }
            var edit = r;
            text_input.editField(ui, tab_id, field, &rs.buffer, &rs.len, &edit, ui.focused == tab_id, "");
            if (edit.cancelled) {
                rs.bar = .none;
            } else if (edit.submitted or ui.focused != tab_id) {
                rs.bar = .none;
                const text = std.mem.trim(u8, rs.buffer[0..rs.len], " ");
                if (text.len > 0 and !std.mem.eql(u8, text, tab.label)) {
                    const copy = ui.frameAllocator().dupe(u8, text) catch text;
                    result.rename = .{ .index = i, .text = copy };
                }
            }
            continue;
        }

        const over_close = options.closable and close_rect.contains(ui.input.mouse_pos) and (on or r.hovered);
        if (r.clicked and !over_close and !on) {
            selected.* = i;
            result.changed = true;
        }
        if (r.clicked and over_close) result.close = i;
        if (r.pressed and options.renamable and ui.input.press_clicks.get(.left) == 2) {
            rs.* = .{ .bar = bar, .index = i };
            const n = @import("font.zig").fitUtf8(tab.label, rs.buffer.len);
            @memcpy(rs.buffer[0..n], tab.label[0..n]);
            rs.len = n;
            ui.requestRedraw();
        }
        if (r.focused) {
            for (ui.input.keyEvents()) |event| switch (event.key) {
                .left => if (nextEnabled(tabs, selected.*, -1)) |k| {
                    selected.* = k;
                    result.changed = true;
                },
                .right => if (nextEnabled(tabs, selected.*, 1)) |k| {
                    selected.* = k;
                    result.changed = true;
                },
                .f2 => if (options.renamable) {
                    rs.* = .{ .bar = bar, .index = i };
                    const n = @import("font.zig").fitUtf8(tab.label, rs.buffer.len);
                    @memcpy(rs.buffer[0..n], tab.label[0..n]);
                    rs.len = n;
                },
                else => {},
            };
        }

        const fill = if (on) colors.window else if (r.hovered) colors.button_hovered else colors.title;
        ui.drawRect(.{ .rect = rect, .fill = fill, .radius = style.rounding });
        if (on) ui.drawRect(.{ .rect = .{ .x = rect.x + 3, .y = rect.bottom() - 2, .w = rect.w - 6, .h = 2 }, .fill = colors.accent });
        var x = rect.x + pad_x;
        const y = rect.y + style.frame_padding.y;
        if (tab.icon) |ic| {
            ui.painter().icon(ic, .{ .x = x, .y = y, .w = line_h, .h = line_h }, colors.text);
            x += line_h + 6;
        }
        ui.drawText(.{ .x = x, .y = y }, if (on) colors.text else colors.text_muted, tab.label);
        if (options.closable and (on or r.hovered)) {
            ui.painter().icon(.{ .builtin = .close }, close_rect.inset(2), if (over_close) colors.text else colors.text_muted);
        }
        if (tab.tooltip.len > 0 or r.disabled) ui.tooltipRich(r, .{ .title = tab.label, .body = tab.tooltip });
        ui.drawFocusRing(tab_id, rect);
        ui.recordWidget(.tab, tab_id, tab.label, rect, .{ .value = if (on) "true" else "false", .hovered = r.hovered, .focused = r.focused });
    }
    if (options.addable) {
        var b: @import("widgets.zig").ButtonOptions = .{ .icon = .{ .builtin = .plus }, .height = .{ .fixed = height } };
        b.width = .{ .fixed = height };
        const add = ui.button("##add", b);
        ui.tooltipRich(add, .{ .title = "New" });
        if (add.clicked) result.add = true;
    }
    ui.endHorizontal();
    // Focus follows the arrow keys.
    if (result.changed) {
        ui.pushIdInt(selected.*);
        if (ui.focused != .none) ui.setFocus(ui.id("##tab"));
        ui.popId();
    }
    return result;
}

/// A column of square icon tabs, the chosen one marked by a bar.
fn column(ui: *Ui, name: []const u8, selected: *usize, tabs: []const Tab) TabBarResult {
    const style = &ui.style;
    const colors = &style.colors;
    var result: TabBarResult = .{};
    if (tabs.len > 0) selected.* = @min(selected.*, tabs.len - 1);
    const bar = ui.id(name);
    ui.pushIdValue(bar);
    defer ui.popId();
    const line_h = ui.textSize("").y;
    const size = line_h + style.frame_padding.y * 2 + 4;
    ui.beginVertical(.{ .spacing = 2 });
    for (tabs, 0..) |tab, i| {
        ui.pushIdInt(i);
        defer ui.popId();
        const rect = ui.place(.{ .x = size, .y = size });
        const tab_id = ui.id("##tab");
        ui.pushDisabled(tab.disabled);
        var r = ui.interact(tab_id, rect);
        if (i == selected.*) ui.focusable(tab_id, &r);
        ui.popDisabled();
        const on = i == selected.*;
        if (r.clicked and !on) {
            selected.* = i;
            result.changed = true;
        }
        if (r.focused) for (ui.input.keyEvents()) |event| switch (event.key) {
            .up => if (nextEnabled(tabs, selected.*, -1)) |k| {
                selected.* = k;
                result.changed = true;
            },
            .down => if (nextEnabled(tabs, selected.*, 1)) |k| {
                selected.* = k;
                result.changed = true;
            },
            else => {},
        };
        if (on or r.hovered) ui.drawRect(.{ .rect = rect, .fill = if (on) colors.button_active else colors.button_hovered, .radius = style.rounding });
        if (on) ui.drawRect(.{ .rect = .{ .x = rect.x, .y = rect.y + 4, .w = 3, .h = rect.h - 8 }, .fill = colors.accent, .radius = 1 });
        const s = line_h;
        if (tab.icon) |ic| {
            ui.painter().icon(ic, .{ .x = rect.x + (size - s) / 2, .y = rect.y + (size - s) / 2, .w = s, .h = s }, if (on) colors.text else colors.text_muted);
        } else {
            const initial = tab.label[0..@min(1, tab.label.len)];
            const w = ui.textSize(initial).x;
            ui.drawText(.{ .x = rect.x + (size - w) / 2, .y = rect.y + (size - line_h) / 2 }, colors.text, initial);
        }
        ui.tooltipRich(r, .{ .title = tab.label, .body = tab.tooltip, .placement = .beside });
        ui.drawFocusRing(tab_id, rect);
        ui.recordWidget(.tab, tab_id, tab.label, rect, .{ .value = if (on) "true" else "false", .hovered = r.hovered, .focused = r.focused });
    }
    ui.endVertical();
    if (result.changed) {
        ui.pushIdInt(selected.*);
        if (ui.focused != .none) ui.setFocus(ui.id("##tab"));
        ui.popId();
    }
    return result;
}
