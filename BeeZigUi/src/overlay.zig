//! Things drawn above everything else: popups and tooltips.
//!
//! Popups are windows without a title bar, kept in front of ordinary windows,
//! so they get the same hit testing: a click on a popup never reaches what is
//! underneath. Open popups form a stack, so a popup can open another.

const std = @import("std");
const draw = @import("draw.zig");
const window = @import("window.zig");
const record = @import("record.zig");
const ui_mod = @import("ui.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;

/// The deepest allowed nesting of popups.
pub const max_popups = 8;

/// One open popup.
pub const PopupEntry = struct {
    id: Id,
    /// What it opens next to. A zero-size rect is a point, such as the mouse.
    anchor: Rect,
    opened_frame: u64,
    /// Opens to the right of the anchor, tops aligned (submenus).
    beside: bool = false,
    /// Described this frame. Popups that stop being described close.
    seen: bool = false,
};

/// Options for `Ui.beginPopup`.
pub const PopupOptions = struct {
    /// The popup is at least this wide, and `.fill` widgets fill it.
    min_width: f32 = 0,
};

/// Gap between an anchor rect and the popup below or above it.
const anchor_gap = 4;

/// Closes popups on a click elsewhere or on Escape. Called by `Ui.beginFrame`
/// after windows have worked out what was pressed.
pub fn beginFrame(ui: *Ui) void {
    for (ui.popups[0..ui.popup_count]) |*p| p.seen = false;
    ui.popup_nesting = 0;
    ui.overlay.clear();

    if (ui.input.mouse_pressed.contains(.left) and ui.active == .none) {
        // Keep the popup that was clicked and those below it.
        var keep: usize = 0;
        if (ui.pressed_window) |w| {
            if (w.popup) {
                for (ui.popups[0..ui.popup_count], 0..) |p, i| {
                    if (p.id == w.id) keep = i + 1;
                }
            }
        }
        ui.popup_count = @min(ui.popup_count, keep);
    }
    // Escape closes the top popup, unless it is undoing a text edit.
    if (ui.input.keys_pressed.contains(.escape) and ui.popup_count > 0 and
        (ui.focused == .none or ui.focused != ui.text_edit.id))
    {
        ui.popup_count -= 1;
        // The popup's: a dialog it is in stays open.
        ui.input.keys_pressed.remove(.escape);
    }
}

/// Closes popups that were not described this frame. Called by `Ui.endFrame`.
pub fn endFrame(ui: *Ui) void {
    std.debug.assert(ui.popup_nesting == 0); // a beginPopup without an endPopup
    // A disabled widget with no tooltip of its own still says why.
    if (ui.disabled_hover) |d| if (!ui.tooltip_shown and !ui.input.mouse_down.contains(.left)) {
        const delay = ui.style.tooltip_delay;
        if (ui.hover_id != d.widget) {
            ui.requestRedrawIn(delay);
        } else if (ui.hover_time < delay) {
            ui.requestRedrawIn(delay - ui.hover_time);
        } else showTip(ui, .{ .warning = d.reason }, d.rect);
    };
    for (ui.popups[0..ui.popup_count], 0..) |p, i| {
        if (!p.seen and p.opened_frame != ui.frame_index) {
            ui.popup_count = i;
            break;
        }
    }
}

/// Opens the popup `name` at the mouse. Describe it with `beginPopup`, using
/// the same name and ID scope. Opening a popup closes any other popup at the
/// same level.
pub fn openPopup(ui: *Ui, name: []const u8) void {
    const m = ui.input.mouse_pos;
    openPopupAt(ui, name, .{ .x = m.x, .y = m.y });
}

/// Opens the popup `name` below `anchor`, or above it if there is no room
/// below. Pass a widget's `result.rect` to attach the popup to that widget.
pub fn openPopupAt(ui: *Ui, name: []const u8, anchor: Rect) void {
    const level = ui.popup_nesting;
    if (level >= max_popups) return;
    ui.popups[level] = .{ .id = ui.id(name), .anchor = anchor, .opened_frame = ui.frame_index };
    ui.popup_count = level + 1;
    ui.redraw_requested = true;
}

/// True if the popup `name` is open.
/// Opens the popup `name` to the right of `anchor`, tops lined up, or to
/// its left if there is no room: how submenus open.
pub fn openPopupBeside(ui: *Ui, name: []const u8, anchor: Rect) void {
    openPopupAt(ui, name, anchor);
    const level = ui.popup_nesting;
    if (level < max_popups) ui.popups[level].beside = true;
}

/// True if the popup `name` is open.
pub fn isPopupOpen(ui: *const Ui, name: []const u8) bool {
    const popup_id = ui.id(name);
    for (ui.popups[0..ui.popup_count]) |p| {
        if (p.id == popup_id) return true;
    }
    return false;
}

/// Closes the popup being described, and any it opened. Outside any popup,
/// closes all of them.
pub fn closePopup(ui: *Ui) void {
    ui.popup_count = @min(ui.popup_count, ui.popup_nesting -| 1);
}

/// Closes every popup, for example after a choice in a nested menu.
pub fn closeAllPopups(ui: *Ui) void {
    ui.popup_count = 0;
}

/// Starts describing the popup `name` if it is open. When this returns true,
/// describe the contents and call `endPopup`.
///
///     if (ui.button("Menu", .{}).clicked) ui.openPopupAt("menu", ui.lastRect());
///     if (ui.beginPopup("menu", .{})) {
///         defer ui.endPopup();
///         if (ui.button("Quit", .{}).clicked) ui.closePopup();
///     }
pub fn beginPopup(ui: *Ui, name: []const u8, options: PopupOptions) bool {
    const level = ui.popup_nesting;
    const popup_id = ui.id(name);
    if (level >= ui.popup_count or ui.popups[level].id != popup_id) return false;
    std.debug.assert(ui.layout_depth < Ui.max_layout_depth);
    const entry = &ui.popups[level];
    entry.seen = true;

    const w = window.getOrCreate(ui, popup_id, .{}) catch |err| {
        ui.fail(err);
        return false;
    };
    w.popup = true;
    w.collapsed = false;
    window.raise(ui, w);
    w.last_frame = ui.frame_index;
    w.described_frame = ui.frame_index;
    // In the OS window of whatever opened it, and kept inside that.
    w.viewport = if (ui.current_window) |opener| opener.viewport else .none;
    const saved_size: Vec2 = .{ .x = ui.width, .y = ui.height };
    if (w.viewport != .none) if (ui.windows.get(w.viewport)) |vp| {
        ui.width = vp.rect.w;
        ui.height = vp.rect.h;
    };
    defer {
        ui.width = saved_size.x;
        ui.height = saved_size.y;
    }

    // Size to last frame's content. Until that is known, describe the
    // contents but don't show them.
    const style = &ui.style;
    const p = style.popup_padding;
    const measure = ui.measures.get(popup_id);
    w.hidden = measure == null;
    // What the content needs, not what its fill rows were stretched to, so
    // it can get smaller again.
    const content = if (measure) |m| m.natural(.vertical, 0) else Vec2{};
    const size: Vec2 = .{
        .x = @min(@max(options.min_width, content.x + 2 * p), ui.width),
        .y = @min(content.y + 2 * p, ui.height),
    };
    w.rect = if (entry.beside) placeBeside(ui, entry.anchor, size) else place(ui, entry.anchor, size);
    // Taller than the window: the content scrolls.
    const overflow = @max(0, (if (measure) |m| m.content.y else 0) + 2 * p - w.rect.h);
    w.scroll = std.math.clamp(w.scroll, 0, overflow);

    w.saved_list = ui.list;
    w.saved_window = ui.current_window;
    w.saved_clip_depth = ui.clip_depth;
    w.grip = null;
    w.list.clear();
    ui.list = &w.list;
    ui.current_window = w;
    w.saved_record_parent = record.enterContainer(ui, .popup, popup_id, name, w.rect, .{});
    ui.pushIdValue(popup_id);
    ui.pushClipAbsolute(.{ .w = ui.width, .h = ui.height });

    ui.drawShadow(w.rect, style.window_rounding, style.colors.popup);
    ui.drawRect(.{
        .rect = w.rect,
        .fill = style.colors.popup,
        .border = style.colors.border,
        .border_width = style.border_width,
        .radius = style.window_rounding,
    });
    ui.pushClip(w.rect);
    ui.layouts[ui.layout_depth] = .{
        .id = popup_id,
        .layout = .init(.{
            .origin = .{ .x = w.rect.x + p, .y = w.rect.y + p - w.scroll },
            .spacing = style.item_spacing,
            .cross_extent = @max(0, w.rect.w - 2 * p),
            .previous = measure orelse .{},
        }),
    };
    ui.layout_depth += 1;
    ui.popup_nesting += 1;
    return true;
}

/// Ends the popup started by the matching successful `beginPopup`.
pub fn endPopup(ui: *Ui) void {
    const w = ui.current_window orelse unreachable; // endPopup without beginPopup
    std.debug.assert(w.popup and ui.current().id == w.id); // a group inside the popup was not ended
    const measure = ui.current().layout.finish();
    ui.layout_depth -= 1;
    ui.storeMeasure(w.id, measure);
    if (ui.hovered_window == w) window.takeWheel(ui, &w.scroll, measure.content.y + 2 * ui.style.popup_padding - w.rect.h);
    window.restore(ui, w);
    ui.popup_nesting -= 1;
}

/// Where a submenu of `size` goes beside `anchor`, kept on screen.
fn placeBeside(ui: *const Ui, anchor: Rect, size: Vec2) Rect {
    var x = anchor.right() + 2;
    if (x + size.x > ui.width) x = anchor.x - 2 - size.x;
    var y = anchor.y - ui.style.popup_padding;
    if (y + size.y > ui.height) y = ui.height - size.y;
    return .{ .x = @max(0, x), .y = @max(0, y), .w = size.x, .h = size.y };
}

/// Where a popup of `size` goes for `anchor`, kept on screen.
fn place(ui: *const Ui, anchor: Rect, size: Vec2) Rect {
    const point = anchor.w == 0 and anchor.h == 0;
    var x = anchor.x;
    var y = if (point) anchor.y else anchor.bottom() + anchor_gap;
    if (y + size.y > ui.height) {
        // No room below: go above the anchor if that fits better.
        const above = if (point) anchor.y - size.y else anchor.y - anchor_gap - size.y;
        y = if (above >= 0) above else ui.height - size.y;
    }
    if (x + size.x > ui.width) x = ui.width - size.x;
    return .{ .x = @max(0, x), .y = @max(0, y), .w = size.x, .h = size.y };
}

/// Shows `text` as a tooltip once the mouse has rested on `item` for the
/// style's `tooltip_delay`. Call it right after the widget.
///
///     ui.tooltip(ui.button("Save", .{}), "Write the file to disk");
pub fn tooltip(ui: *Ui, item: Interaction, text: []const u8) void {
    if (item.disabled) return tooltipRich(ui, item, .{ .body = text, .placement = .pointer });
    record.attachTooltip(ui, item.rect, text);
    if (!item.hovered or ui.input.mouse_down.contains(.left)) return;
    const delay = ui.style.tooltip_delay;
    if (ui.hot != ui.hover_id) return ui.requestRedrawIn(delay);
    if (ui.hover_time < delay) return ui.requestRedrawIn(delay - ui.hover_time);
    showTooltip(ui, text);
}

/// Like `tooltip`, with formatted text.
pub fn tooltipf(ui: *Ui, item: Interaction, comptime fmt: []const u8, args: anytype) void {
    if (!item.hovered and !ui.recording) return;
    const text = std.fmt.allocPrint(ui.frameAllocator(), fmt, args) catch |err| return ui.fail(err);
    tooltip(ui, item, text);
}

/// Shows `text` next to the mouse right away, above everything. Lines are
/// split at `\n`.
pub fn showTooltip(ui: *Ui, text: []const u8) void {
    ui.tooltip_shown = true;
    const style = &ui.style;
    const line = ui.font.lineMetrics(style.font_size);
    const p = style.popup_padding;

    var width: f32 = 0;
    var lines: f32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        width = @max(width, ui.textSize(l).x);
        lines += 1;
    }
    const size: Vec2 = .{ .x = width + 2 * p, .y = (lines - 1) * line.height + line.ascent + line.descent + 2 * p };

    // Below and right of the pointer, moved to stay on screen.
    const margin = 4;
    const m = ui.input.mouse_pos;
    var x = m.x + 14;
    var y = m.y + 20;
    if (x + size.x > ui.width - margin) x = ui.width - margin - size.x;
    if (y + size.y > ui.height - margin) y = m.y - 8 - size.y;
    const rect: Rect = .{ .x = @max(margin, x), .y = @max(margin, y), .w = size.x, .h = size.y };
    record.recordOverlay(ui, .tooltip, ui.id("#tooltip"), text, rect);

    const list = &ui.overlay;
    list.setClip(null) catch |err| return ui.fail(err);
    if (style.colors.shadow.a != 0) {
        const off = style.shadow_offset;
        list.addShadow(.{
            .rect = .{ .x = rect.x + off.x, .y = rect.y + off.y, .w = rect.w, .h = rect.h },
            .radius = style.rounding,
            .blur = style.shadow_blur / 2,
            .color = style.colors.shadow,
        }) catch |err| return ui.fail(err);
    }
    list.addRect(.{
        .rect = rect,
        .fill = style.colors.popup,
        .border = style.colors.border,
        .border_width = style.border_width,
        .radius = style.rounding,
    }) catch |err| return ui.fail(err);
    var pen_y = rect.y + p + line.ascent;
    it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| : (pen_y += line.height) {
        list.addText(.{ .font = ui.font, .pos = .{ .x = rect.x + p, .y = pen_y }, .size = style.font_size, .color = style.colors.text, .text = l }) catch |err| return ui.fail(err);
    }
}

/// Where a rich tooltip goes.
pub const TipPlacement = enum {
    /// Below the widget, left edges lined up: buttons and fields.
    below,
    /// To the right of the widget, tops lined up: menu items and list rows.
    beside,
    /// Near the pointer, like `tooltip`.
    pointer,
};

/// A tooltip with parts, as BeeModel shows them: what it is, its shortcut,
/// what it does, and why it can't be used now. Long text wraps.
pub const Tip = struct {
    /// The name, in the main text color.
    title: []const u8 = "",
    /// Shown at the right of the title, muted, such as "Ctrl+S".
    shortcut: []const u8 = "",
    /// What it does. `\n` starts a new paragraph.
    body: []const u8 = "",
    /// A problem or the reason it is disabled, in the warning color.
    warning: []const u8 = "",
    placement: TipPlacement = .below,
    /// Lines wrap to fit this width.
    max_width: f32 = 320,
};

/// Shows `tip` once the mouse has rested on `item` for the style's
/// `tooltip_delay`. For a disabled item, the reason is added as the warning.
///
///     ui.tooltipRich(ui.button("Save", .{}), .{ .title = "Save", .shortcut = "Ctrl+S", .body = "Writes the scene to its file." });
pub fn tooltipRich(ui: *Ui, item: Interaction, tip: Tip) void {
    var t = tip;
    if (item.disabled and t.warning.len == 0) {
        if (ui.disabled_hover) |d| {
            if (d.rect.x == item.rect.x and d.rect.y == item.rect.y) t.warning = d.reason;
        }
    }
    record.attachTooltip(ui, item.rect, if (t.body.len > 0) t.body else t.title);
    if (!item.hovered or ui.input.mouse_down.contains(.left)) return;
    const delay = ui.style.tooltip_delay;
    if (ui.hot != ui.hover_id) return ui.requestRedrawIn(delay);
    if (ui.hover_time < delay) return ui.requestRedrawIn(delay - ui.hover_time);
    // Beside an item of a popup (a menu's entry): beside the popup, so the
    // tip does not cover its edge.
    var anchor = item.rect;
    if (t.placement == .beside) if (ui.current_window) |w| if (w.popup) {
        anchor.x = w.rect.x;
        anchor.w = w.rect.w;
    };
    showTip(ui, t, anchor);
}

/// Splits `text` into lines no wider than `width`, breaking between words
/// (and inside a word only if it alone is too wide). Calls `line` for each.
pub fn wrapText(ui: *const Ui, text: []const u8, width: f32, context: anytype, comptime line: fn (@TypeOf(context), []const u8) void) void {
    const font = ui.font;
    const size = ui.style.font_size;
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |para| {
        var rest = para;
        if (rest.len == 0) line(context, "");
        while (rest.len > 0) {
            // One pass along the line, adding advances and kerning as
            // textWidth does: the longest prefix that fits, and the last
            // space in it (a space that doesn't fit is still a fine place
            // to break).
            var it: @import("font.zig").Utf8Iterator = .{ .bytes = rest };
            var w: f32 = 0;
            var previous: ?u21 = null;
            var fit: usize = 0;
            var last_space: ?usize = null;
            const all = while (true) {
                const start = it.index;
                const cp = it.next() orelse break true;
                var step = font.advance(cp, size);
                if (previous) |p| step += font.kerning(p, cp, size);
                if (w + step > width) {
                    if (cp == ' ') last_space = start;
                    break false;
                }
                w += step;
                previous = cp;
                if (cp == ' ') last_space = start;
                fit = it.index;
            };
            if (all) {
                line(context, rest);
                break;
            }
            // Nothing fits: at least one whole character, so the line moves on.
            const first = @min(rest.len, std.unicode.utf8ByteSequenceLength(rest[0]) catch 1);
            const cut = if (last_space) |sp| (if (sp > 0) sp else @max(fit, first)) else @max(fit, first);
            line(context, std.mem.trimEnd(u8, rest[0..cut], " "));
            rest = std.mem.trimStart(u8, rest[cut..], " ");
        }
    }
}

/// Draws `tip` now, next to `anchor`, above everything.
pub fn showTip(ui: *Ui, tip: Tip, anchor: Rect) void {
    ui.tooltip_shown = true;
    ui.shown_tip = tip;
    const style = &ui.style;
    const p = style.popup_padding;
    const line = ui.font.lineMetrics(style.font_size);
    const line_h = line.height;
    const icon_w = line.ascent + line.descent;
    const inner_max = @max(80, tip.max_width - 2 * p);

    // Measure: the widest line decides the width.
    const Measure = struct {
        ui: *const Ui,
        width: f32 = 0,
        lines: f32 = 0,
        indent: f32 = 0,
        fn add(m: *@This(), s: []const u8) void {
            m.width = @max(m.width, m.ui.textSize(s).x + m.indent);
            m.lines += 1;
        }
    };
    var m: Measure = .{ .ui = ui };
    const title_row = tip.title.len > 0 or tip.shortcut.len > 0;
    if (title_row) {
        const gap: f32 = if (tip.title.len > 0 and tip.shortcut.len > 0) 24 else 0;
        m.width = ui.textSize(tip.title).x + gap + ui.textSize(tip.shortcut).x;
        m.lines = 1;
    }
    if (tip.body.len > 0) wrapText(ui, tip.body, inner_max, &m, Measure.add);
    if (tip.warning.len > 0) {
        m.indent = icon_w + 4;
        wrapText(ui, tip.warning, inner_max - m.indent, &m, Measure.add);
    }
    if (m.lines == 0) return;
    const sections: f32 = @floatFromInt(@as(u32, @intFromBool(title_row)) + @intFromBool(tip.body.len > 0) + @intFromBool(tip.warning.len > 0));
    const section_gap = p / 2;
    const size: Vec2 = .{
        .x = @min(m.width, tip.max_width) + 2 * p,
        .y = (m.lines - 1) * line_h + line.ascent + line.descent + 2 * p + (sections - 1) * section_gap,
    };

    const margin = 4;
    var x: f32 = 0;
    var y: f32 = 0;
    switch (tip.placement) {
        .below => {
            x = anchor.x;
            y = anchor.bottom() + 4;
            if (y + size.y > ui.height - margin) y = anchor.y - 4 - size.y;
        },
        .beside => {
            x = anchor.right() + 4;
            y = anchor.y;
            if (x + size.x > ui.width - margin) x = anchor.x - 4 - size.x;
        },
        .pointer => {
            const mp = ui.input.mouse_pos;
            x = mp.x + 14;
            y = mp.y + 20;
            if (y + size.y > ui.height - margin) y = mp.y - 8 - size.y;
        },
    }
    x = std.math.clamp(x, margin, @max(margin, ui.width - margin - size.x));
    y = std.math.clamp(y, margin, @max(margin, ui.height - margin - size.y));
    const rect: Rect = .{ .x = x, .y = y, .w = size.x, .h = size.y };
    record.recordOverlay(ui, .tooltip, ui.id("#tooltip"), if (tip.title.len > 0) tip.title else if (tip.body.len > 0) tip.body else tip.warning, rect);

    const list = &ui.overlay;
    list.setClip(null) catch |err| return ui.fail(err);
    if (style.colors.shadow.a != 0) {
        const off = style.shadow_offset;
        list.addShadow(.{
            .rect = .{ .x = rect.x + off.x, .y = rect.y + off.y, .w = rect.w, .h = rect.h },
            .radius = style.rounding,
            .blur = style.shadow_blur / 2,
            .color = style.colors.shadow,
            .covered = if (style.colors.popup.a == 255) rect.inset(style.rounding) else null,
        }) catch |err| return ui.fail(err);
    }
    list.addRect(.{ .rect = rect, .fill = style.colors.popup, .border = style.colors.border, .border_width = style.border_width, .radius = style.rounding }) catch |err| return ui.fail(err);

    const Pen = struct {
        ui: *Ui,
        x: f32,
        y: f32,
        line_h: f32,
        color: draw.Color,
        fn add(pen: *@This(), s: []const u8) void {
            const style_size = pen.ui.style.font_size;
            pen.ui.overlay.addText(.{ .font = pen.ui.font, .pos = .{ .x = pen.x, .y = pen.y }, .size = style_size, .color = pen.color, .text = s }) catch |err| pen.ui.fail(err);
            pen.y += pen.line_h;
        }
    };
    var pen: Pen = .{ .ui = ui, .x = rect.x + p, .y = rect.y + p + line.ascent, .line_h = line_h, .color = style.colors.text };
    if (title_row) {
        if (tip.title.len > 0) pen.add(tip.title) else pen.y += line_h;
        if (tip.shortcut.len > 0) {
            const sx = rect.right() - p - ui.textSize(tip.shortcut).x;
            list.addText(.{ .font = ui.font, .pos = .{ .x = sx, .y = pen.y - line_h }, .size = style.font_size, .color = style.colors.text_muted, .text = tip.shortcut }) catch |err| return ui.fail(err);
        }
        pen.y += section_gap;
    }
    if (tip.body.len > 0) {
        pen.color = if (title_row) style.colors.text_muted else style.colors.text;
        wrapText(ui, tip.body, inner_max, &pen, Pen.add);
        pen.y += section_gap;
    }
    if (tip.warning.len > 0) {
        const icon_rect: Rect = .{ .x = rect.x + p, .y = pen.y - line.ascent, .w = icon_w, .h = icon_w };
        @import("icons.zig").draw(list, .{ .builtin = .warning }, icon_rect, style.colors.warning) catch |err| return ui.fail(err);
        pen.x += icon_w + 4;
        pen.color = style.colors.warning;
        wrapText(ui, tip.warning, inner_max - icon_w - 4, &pen, Pen.add);
    }
}

test "wrapText breaks between words and inside long words" {
    var font: @import("font.zig").Font = try .initDefault(std.testing.allocator);
    defer font.deinit();
    var ui: Ui = .init(std.testing.allocator, .{ .font = &font });
    defer ui.deinit();
    const Lines = struct {
        buffer: [16][]const u8 = undefined,
        n: usize = 0,
        fn add(l: *@This(), s: []const u8) void {
            l.buffer[l.n] = s;
            l.n += 1;
        }
    };
    var lines: Lines = .{};
    const word_w = ui.textSize("several words").x;
    wrapText(&ui, "several words that will wrap", word_w + 2, &lines, Lines.add);
    try std.testing.expectEqualStrings("several words", lines.buffer[0]);
    for (lines.buffer[0..lines.n]) |l| try std.testing.expect(ui.textSize(l).x <= word_w + 2);
    lines = .{};
    wrapText(&ui, "Supercalifragilistic", ui.textSize("Super").x, &lines, Lines.add);
    try std.testing.expect(lines.n >= 3);
}

// Docs/improvements.html P9: one pass per line, the same lines as before.
fn wrapReference(ui: *const Ui, text: []const u8, width: f32, out: *std.ArrayList([]const u8)) !void {
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |para| {
        var rest = para;
        if (rest.len == 0) try out.append(std.testing.allocator, "");
        while (rest.len > 0) {
            if (ui.textSize(rest).x <= width) {
                try out.append(std.testing.allocator, rest);
                break;
            }
            var fit: usize = 0;
            var last_space: ?usize = null;
            var i: usize = 0;
            while (i < rest.len) {
                var next = i + 1;
                while (next < rest.len and rest[next] & 0xC0 == 0x80) next += 1;
                if (ui.textSize(rest[0..next]).x > width) {
                    if (rest[i] == ' ') last_space = i;
                    break;
                }
                if (rest[i] == ' ') last_space = i;
                fit = next;
                i = next;
            }
            const first = @min(rest.len, std.unicode.utf8ByteSequenceLength(rest[0]) catch 1);
            const cut = if (last_space) |sp| (if (sp > 0) sp else @max(fit, first)) else @max(fit, first);
            try out.append(std.testing.allocator, std.mem.trimEnd(u8, rest[0..cut], " "));
            rest = std.mem.trimStart(u8, rest[cut..], " ");
        }
    }
}

test "P9: wrapping in one pass gives the same lines as measuring every prefix" {
    var font: @import("font.zig").Font = try .initDefault(std.testing.allocator);
    defer font.deinit();
    var ui: Ui = .init(std.testing.allocator, .{ .font = &font });
    defer ui.deinit();
    const texts = [_][]const u8{
        "The quick brown fox jumps over the lazy dog. AVATAR WAVE Tyrol.",
        "Supercalifragilisticexpialidocious and a few short words after it\nsecond paragraph\n\nafter an empty one",
        "Événements à l'été: ça déménage, naïve façade, Œuvre complète — Ægir ⌘ ☃ 日本語のテキスト",
        "",
        "   leading spaces and  double  spaces   ",
    };
    const Collect = struct {
        list: *std.ArrayList([]const u8),
        fn add(c: @This(), l: []const u8) void {
            c.list.append(std.testing.allocator, l) catch unreachable;
        }
    };
    for (texts) |t| {
        for ([_]f32{ 4, 30, 80, 150, 400 }) |w| {
            var a: std.ArrayList([]const u8) = .empty;
            defer a.deinit(std.testing.allocator);
            var b: std.ArrayList([]const u8) = .empty;
            defer b.deinit(std.testing.allocator);
            wrapText(&ui, t, w, Collect{ .list = &a }, Collect.add);
            try wrapReference(&ui, t, w, &b);
            try std.testing.expectEqual(b.items.len, a.items.len);
            for (a.items, b.items) |x, y| try std.testing.expectEqualStrings(y, x);
            // Every line is whole UTF-8.
            for (a.items) |x| try std.testing.expect(std.unicode.utf8ValidateSlice(x));
        }
    }
}
