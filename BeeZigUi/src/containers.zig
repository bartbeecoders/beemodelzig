//! Widgets that hold other widgets: scroll areas, selectable rows (for list
//! views), tree nodes, collapsing headers and tables.

const std = @import("std");
const draw = @import("draw.zig");
const icons = @import("icons.zig");
const layout = @import("layout.zig");
const window = @import("window.zig");
const widgets = @import("widgets.zig");
const ui_mod = @import("ui.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;

/// What a scroll area remembers between frames.
pub const ScrollState = struct {
    scroll: f32 = 0,
    /// Height of the content last frame, padding included.
    content_height: f32 = 0,
    /// Sideways, for areas that scroll horizontally too.
    scroll_x: f32 = 0,
    /// Width of the content last frame, padding included.
    content_width: f32 = 0,
};

/// One scroll area being described.
pub const ScrollFrame = struct {
    id: Id,
    /// The visible area, scrollbar excluded.
    view: Rect,
    /// The whole area, for the mouse wheel.
    rect: Rect,
    padding: f32,
    horizontal: bool = false,
};

/// The deepest allowed nesting of scroll areas.
pub const max_scroll_depth = 8;

/// Options for `beginScrollArea`.
pub const ScrollAreaOptions = struct {
    width: layout.Size = .fill,
    height: layout.Size = .px(200),
    /// Space between the edge and the content. Defaults to the style's
    /// `popup_padding`.
    padding: ?f32 = null,
    /// Space between items. Defaults to the style's.
    spacing: ?f32 = null,
    /// Draw a background and border.
    frame: bool = true,
    /// Also scroll sideways when the content is wider: a horizontal
    /// scrollbar, Shift+wheel and sideways wheels.
    horizontal: bool = false,
};

/// Starts a fixed-size area whose content scrolls vertically. Pair with
/// `endScrollArea`. A list view is a scroll area of `selectable` rows.
///
///     ui.beginScrollArea("files", .{ .height = .px(160) });
///     for (files, 0..) |f, i| {
///         ui.pushIdInt(i);
///         defer ui.popId();
///         if (ui.selectable(f.name, i == chosen, .{}).clicked) chosen = i;
///     }
///     ui.endScrollArea();
pub fn beginScrollArea(ui: *Ui, name: []const u8, options: ScrollAreaOptions) void {
    const style = &ui.style;
    const rect = ui.placeSized(options.width, options.height, .{ .x = style.widget_width, .y = 200 });
    if (options.frame) {
        ui.drawRect(.{
            .rect = rect,
            .fill = style.colors.input,
            .border = style.colors.border,
            .border_width = style.border_width,
            .radius = style.rounding,
        });
    }
    ui.recordWidget(.scroll_area, ui.id(name), name, rect, .{ .hovered = rect.contains(ui.input.mouse_pos) and ui.hovered_window == ui.current_window });
    beginScrollRegionEx(ui, ui.id(name), rect, options.padding orelse style.popup_padding, options.spacing, options.horizontal);
}

/// Ends the area from `beginScrollArea`.
pub fn endScrollArea(ui: *Ui) void {
    endScrollRegion(ui);
}

/// The part of a scroll area shared with tables: scrolls content inside an
/// already placed `rect`.
/// A scrolling layout at `rect`, outside the normal flow: the body of a
/// dock area, a panel the app placed itself. End it with `endScrollRegion`.
pub fn beginScrollRegion(ui: *Ui, area: Id, rect: Rect, padding: f32, spacing: ?f32) void {
    beginScrollRegionEx(ui, area, rect, padding, spacing, false);
}

/// `beginScrollRegion` that can also scroll sideways.
pub fn beginScrollRegionEx(ui: *Ui, area: Id, rect: Rect, padding: f32, spacing: ?f32, horizontal: bool) void {
    std.debug.assert(ui.scroll_depth < max_scroll_depth); // scroll areas nested too deep
    std.debug.assert(ui.layout_depth < Ui.max_layout_depth);
    const entry = ui.scroll_states.getOrPut(ui.allocator, area) catch |err| blk: {
        ui.fail(err);
        break :blk null;
    };
    var state: ScrollState = if (entry) |e| (if (e.found_existing) e.value_ptr.* else .{}) else .{};

    ui.pushIdValue(area);
    var body = rect;
    if (horizontal and state.content_width > rect.w) {
        // Room for the horizontal bar at the bottom.
        body.h = @max(0, rect.h - ui.style.scrollbar_width - 4);
        state.scroll_x = std.math.clamp(state.scroll_x, 0, @max(0, state.content_width - body.w));
        hscrollbar(ui, &state.scroll_x, state.content_width, rect, body);
    } else state.scroll_x = 0;
    // Clamped to the height left above the horizontal bar, so the bottom
    // of the content can be reached.
    state.scroll = std.math.clamp(state.scroll, 0, @max(0, state.content_height - body.h));
    const view = window.scrollbar(ui, &state.scroll, state.content_height, body);
    if (entry) |e| e.value_ptr.* = state;

    ui.scroll_stack[ui.scroll_depth] = .{ .id = area, .view = view, .rect = rect, .padding = padding, .horizontal = horizontal };
    ui.scroll_depth += 1;
    ui.pushClip(view.inset(ui.style.border_width));
    const item = ui.style.item_spacing;
    ui.layouts[ui.layout_depth] = .{
        .id = area,
        .layout = .init(.{
            .origin = .{ .x = view.x + padding - state.scroll_x, .y = view.y + padding - state.scroll },
            .spacing = .{ .x = spacing orelse item.x, .y = spacing orelse item.y },
            // Sideways scrolling: as wide as the content wants.
            .cross_extent = if (horizontal) @max(view.w - 2 * padding, state.content_width - 2 * padding) else @max(0, view.w - 2 * padding),
            .previous = ui.measures.get(area) orelse .{},
        }),
    };
    ui.layout_depth += 1;
}

/// A horizontal scrollbar along the bottom of `rect`, for content
/// `content_width` wide shown in `body`.
fn hscrollbar(ui: *Ui, scroll: *f32, content_width: f32, rect: Rect, body: Rect) void {
    const style = &ui.style;
    const max_scroll = @max(0, content_width - body.w);
    if (max_scroll == 0) return;
    const bar_h = style.scrollbar_width;
    const track: Rect = .{ .x = rect.x + 2, .y = rect.bottom() - bar_h - 2, .w = @max(0, body.w - 4 - 16), .h = bar_h };
    const thumb_w = @max(24, track.w * body.w / content_width);
    const travel = @max(1, track.w - thumb_w);
    const thumb: Rect = .{ .x = track.x + travel * (scroll.* / max_scroll), .y = track.y, .w = thumb_w, .h = bar_h };
    const drag = ui.interact(ui.id("#hscroll"), thumb);
    if (drag.held) {
        if (drag.pressed) ui.drag_offset = .{ .x = ui.input.press_pos.get(.left).x - thumb.x };
        const t = (ui.input.mouse_pos.x - ui.drag_offset.x - track.x) / travel;
        scroll.* = std.math.clamp(t, 0, 1) * max_scroll;
    }
    ui.drawRect(.{ .rect = thumb, .fill = if (drag.held or drag.hovered) style.colors.scrollbar_hovered else style.colors.scrollbar, .radius = bar_h / 2 });
}

/// Ends `beginScrollRegion`.
pub fn endScrollRegion(ui: *Ui) void {
    std.debug.assert(ui.scroll_depth > 0); // endScrollArea without beginScrollArea
    ui.scroll_depth -= 1;
    const frame = ui.scroll_stack[ui.scroll_depth];
    std.debug.assert(ui.current().id == frame.id); // a group inside the area was not ended
    const measure = ui.current().layout.finish();
    ui.layout_depth -= 1;
    ui.storeMeasure(frame.id, measure);
    ui.popClip();
    ui.popId();
    // Once ended, the area counts as one item, like a widget.
    ui.last_rect = frame.rect;

    const state = ui.scroll_states.getPtr(frame.id) orelse return;
    state.content_height = measure.content.y + 2 * frame.padding;
    const pos = ui.input.mouse_pos;
    const hovered = frame.rect.contains(pos) and ui.clipRect().contains(pos) and ui.hovered_window == ui.current_window;
    if (frame.horizontal) {
        state.content_width = measure.content.x + 2 * frame.padding;
        // Shift turns the wheel sideways; sideways wheels go sideways.
        const in = &ui.input;
        const max_x = state.content_width - frame.view.w;
        if (hovered and max_x > 0) {
            var dx = in.scroll.x;
            if (in.modifiers.shift and in.scroll.y != 0) {
                dx = in.scroll.y;
                in.scroll.y = 0;
            }
            if (dx != 0) {
                const before = state.scroll_x;
                state.scroll_x = std.math.clamp(state.scroll_x - dx * ui.style.scroll_step, 0, max_x);
                in.scroll.x = 0;
                if (state.scroll_x != before) ui.redraw_requested = true;
            }
        }
    }
    if (hovered) window.takeWheel(ui, &state.scroll, state.content_height - frame.view.h);
}

/// Scrolls the innermost scroll area being described so that `rect` is in
/// view. Returns false if there is no scroll area. Used for keyboard focus.
pub fn scrollIntoView(ui: *Ui, rect: Rect) bool {
    if (ui.scroll_depth == 0) return false;
    const frame = ui.scroll_stack[ui.scroll_depth - 1];
    const state = ui.scroll_states.getPtr(frame.id) orelse return false;
    const view = frame.view;
    if (rect.y < view.y) {
        state.scroll -= view.y - rect.y + frame.padding;
    } else if (rect.bottom() > view.bottom()) {
        state.scroll += rect.bottom() - view.bottom() + frame.padding;
    }
    state.scroll = @max(0, state.scroll);
    ui.redraw_requested = true;
    return true;
}

/// Options for `selectable`.
pub const SelectableOptions = struct {
    width: layout.Size = .fill,
    /// Shown before the text.
    icon: ?icons.Icon = null,
};

/// A row of text that can be selected, as in a list view. Draws as
/// highlighted while `selected`; clicking it, or Enter or Space when it is
/// focused, sets `result.clicked`. The caller decides what selection means.
pub fn selectable(ui: *Ui, name: []const u8, selected: bool, options: SelectableOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    const text = Ui.visibleLabel(name);
    const text_size = ui.textSize(text);
    const pad: Vec2 = .{ .x = style.frame_padding.x / 2, .y = style.frame_padding.y / 2 };
    const icon_w = if (options.icon != null) text_size.y + style.item_spacing.x * 0.5 else 0;
    const rect = ui.placeSized(options.width, .auto, .{ .x = icon_w + text_size.x + 2 * pad.x, .y = text_size.y + 2 * pad.y });
    const widget = ui.id(name);
    var result = ui.interact(widget, rect);
    ui.focusable(widget, &result);
    if (widgets.keyActivated(ui, result)) result.clicked = true;

    const fill = if (selected)
        colors.button_active
    else if (result.hovered or result.held)
        colors.button_hovered
    else
        draw.Color.transparent;
    ui.drawRect(.{ .rect = rect, .fill = fill, .radius = style.rounding });
    if (options.icon) |which| ui.painter().icon(which, .{ .x = rect.x + pad.x, .y = rect.y + pad.y, .w = text_size.y, .h = text_size.y }, colors.text);
    ui.drawText(.{ .x = rect.x + pad.x + icon_w, .y = rect.y + pad.y }, colors.text, text);
    ui.drawFocusRing(widget, rect);
    ui.recordWidget(.selectable, widget, name, rect, .{ .value = if (selected) "true" else "false", .hovered = result.hovered, .focused = result.focused });
    return result;
}

/// Options for `treeNode` and `collapsingHeader`.
pub const TreeOptions = struct {
    /// Open the first time it is shown. Later the user decides.
    default_open: bool = false,
    /// Keep the open state in your own variable instead of in the `Ui`.
    open: ?*bool = null,
};

/// A row with an arrow that opens and closes. When it returns true, describe
/// the children, which are indented, then call `treePop`.
///
///     if (ui.treeNode("Assets", .{})) {
///         defer ui.treePop();
///         ui.label("texture.png", .{});
///     }
///
/// Click it, or press Enter, Space or the arrow keys when it is focused.
pub fn treeNode(ui: *Ui, name: []const u8, options: TreeOptions) bool {
    const widget = ui.id(name);
    if (!disclosure(ui, widget, name, options, false)) return false;
    ui.pushIdValue(widget);
    ui.beginHorizontal(.{ .alignment = .start, .spacing = 0 });
    ui.spacer(.px(ui.style.indent));
    ui.beginVertical(.{ .width = .fill });
    return true;
}

/// Ends the children of the `treeNode` that returned true.
pub fn treePop(ui: *Ui) void {
    ui.endVertical();
    ui.endHorizontal();
    ui.popId();
}

/// A full-width header that shows or hides a section. Returns true while it
/// is open; unlike `treeNode` there is nothing to end.
pub fn collapsingHeader(ui: *Ui, name: []const u8, options: TreeOptions) bool {
    return disclosure(ui, ui.id(name), name, options, true);
}

/// The clickable row shared by tree nodes and headers. Returns whether it is
/// open after this frame's input.
fn disclosure(ui: *Ui, widget: Id, name: []const u8, options: TreeOptions, header: bool) bool {
    const style = &ui.style;
    const colors = &style.colors;
    const text = Ui.visibleLabel(name);
    const text_size = ui.textSize(text);
    const pad_y = if (header) style.frame_padding.y else style.frame_padding.y / 2;
    const arrow_w = text_size.y;
    const rect = ui.placeSized(if (header) .fill else .auto, .auto, .{
        .x = arrow_w + text_size.x + style.frame_padding.x,
        .y = text_size.y + 2 * pad_y,
    });
    var result = ui.interact(widget, rect);
    ui.focusable(widget, &result);

    var open = if (options.open) |o| o.* else ui.open_states.get(widget) orelse options.default_open;
    const keys = ui.input.keys_pressed;
    if (result.clicked or widgets.keyActivated(ui, result)) open = !open;
    if (result.focused and keys.contains(.right)) open = true;
    if (result.focused and keys.contains(.left)) open = false;
    if (options.open) |o| {
        o.* = open;
    } else {
        ui.open_states.put(ui.allocator, widget, open) catch |err| ui.fail(err);
    }

    const hot = result.hovered or result.held;
    const fill = if (header)
        (if (hot) colors.button_hovered else colors.button)
    else if (hot)
        colors.button_hovered
    else
        draw.Color.transparent;
    ui.drawRect(.{
        .rect = rect,
        .fill = fill,
        .border = if (header) colors.border else draw.Color.transparent,
        .border_width = if (header) style.border_width else 0,
        .radius = style.rounding,
    });
    const arrow: icons.Icon = .{ .builtin = if (open) .chevron_down else .chevron_right };
    const text_y = rect.y + pad_y;
    const left = rect.x + (if (header) style.frame_padding.x / 2 else 0);
    const glyph = text_size.y * 0.8;
    ui.painter().icon(arrow, .{ .x = left + (arrow_w - glyph) / 2, .y = text_y + (text_size.y - glyph) / 2, .w = glyph, .h = glyph }, colors.text_muted);
    ui.drawText(.{ .x = left + arrow_w + style.frame_padding.x / 3, .y = text_y }, colors.text, text);
    ui.drawFocusRing(widget, rect);
    ui.recordWidget(if (header) .header else .tree_node, widget, name, rect, .{ .value = if (open) "open" else "closed", .hovered = result.hovered, .focused = result.focused });
    return open;
}

/// How a column's rows are sorted, for the header's arrow.
pub const SortOrder = enum { none, ascending, descending };

/// One column of a table.
pub const TableColumn = struct {
    name: []const u8,
    /// `.px(n)` for fixed, `.fill` (or `.{ .grow = weight }`) to share what is left.
    width: layout.Size = .fill,
    /// Shows an arrow in the header.
    sort: SortOrder = .none,
};

/// Options for `beginTable`.
pub const TableOptions = struct {
    width: layout.Size = .fill,
    height: layout.Size = .px(240),
    /// Shade every other row.
    striped: bool = true,
};

/// What happened in a table's header this frame.
pub const TableResult = struct {
    /// The column whose header was clicked, for sorting.
    header_clicked: ?usize = null,
};

/// The table being described.
pub const TableState = struct {
    widths: [max_table_columns]f32 = undefined,
    offsets: [max_table_columns]f32 = undefined,
    count: usize = 0,
    column: usize = 0,
    row: usize = 0,
    row_open: bool = false,
    striped: bool = true,
    /// Left edge of the rows' content.
    left: f32 = 0,
    /// The whole table, header included.
    rect: Rect = .{},
};

/// The most columns a table can have.
pub const max_table_columns = 16;

/// Starts a table with a fixed header and scrolling rows. Begin each row with
/// `tableRow`, put each cell's widgets after `tableNextColumn` (the first
/// cell needs none), and finish with `endTable`. Tables don't nest.
///
///     const columns = [_]zui.TableColumn{ .{ .name = "Name" }, .{ .name = "Size", .width = .px(80) } };
///     _ = ui.beginTable("files", &columns, .{});
///     for (files) |f| {
///         ui.tableRow();
///         ui.label(f.name, .{});
///         ui.tableNextColumn();
///         ui.labelf("{d} KB", .{f.kb}, .{});
///     }
///     ui.endTable();
pub fn beginTable(ui: *Ui, name: []const u8, columns: []const TableColumn, options: TableOptions) TableResult {
    std.debug.assert(ui.table == null); // tables don't nest
    std.debug.assert(columns.len > 0 and columns.len <= max_table_columns);
    const style = &ui.style;
    const colors = &style.colors;
    const table_id = ui.id(name);
    const rect = ui.placeSized(options.width, options.height, .{ .x = 2 * style.widget_width, .y = 240 });
    ui.drawRect(.{
        .rect = rect,
        .fill = colors.input,
        .border = colors.border,
        .border_width = style.border_width,
        .radius = style.rounding,
    });

    // The header row, outside the scrolling part.
    const line_h = ui.textSize("").y;
    const header_h = line_h + style.frame_padding.y * 2;
    const header: Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @min(header_h, rect.h) };
    const body: Rect = .{ .x = rect.x, .y = header.bottom(), .w = rect.w, .h = @max(0, rect.h - header.h) };

    // The body's scrollbar, if it had one last frame, takes width from the
    // columns. IDs from here on are scoped to the table.
    ui.pushIdValue(table_id);
    const body_id = ui.id("##body");
    var available = rect.w;
    if (ui.scroll_states.get(body_id)) |s| {
        if (s.content_height > body.h) available -= style.scrollbar_width + 4;
    }
    var state: TableState = .{ .count = columns.len, .striped = options.striped, .left = rect.x, .rect = rect };
    var fixed: f32 = 0;
    var weights: f32 = 0;
    for (columns) |c| switch (c.width) {
        .fixed => |px| fixed += px,
        .grow => |g| weights += g,
        .auto => weights += 1,
    };
    const leftover = @max(0, available - fixed);
    var x: f32 = 0;
    for (columns, 0..) |c, i| {
        const w = switch (c.width) {
            .fixed => |px| px,
            .grow => |g| if (weights > 0) leftover * g / weights else 0,
            .auto => if (weights > 0) leftover / weights else 0,
        };
        state.widths[i] = w;
        state.offsets[i] = x;
        x += w;
    }

    var result: TableResult = .{};
    ui.pushClip(header);
    ui.drawRect(.{ .rect = header.inset(style.border_width), .fill = colors.title, .radius = @max(0, style.rounding - 1) });
    for (columns, 0..) |c, i| {
        ui.pushIdInt(i);
        defer ui.popId();
        const cell: Rect = .{ .x = rect.x + state.offsets[i], .y = header.y, .w = state.widths[i], .h = header.h };
        const r = ui.interact(ui.id("##header"), cell);
        ui.recordWidget(.table_header, ui.id("##header"), c.name, cell, .{ .value = @tagName(c.sort), .hovered = r.hovered });
        if (r.clicked) result.header_clicked = i;
        if (r.hovered) ui.drawRect(.{ .rect = cell.inset(2), .fill = colors.button_hovered, .radius = style.rounding });
        ui.pushClip(cell);
        const label_x = cell.x + style.frame_padding.x / 2;
        ui.drawText(.{ .x = label_x, .y = cell.y + style.frame_padding.y }, colors.title_text, c.name);
        if (c.sort != .none) {
            const arrow: icons.Icon = .{ .builtin = if (c.sort == .ascending) .chevron_up else .chevron_down };
            const glyph = line_h * 0.75;
            const arrow_x = label_x + ui.textSize(c.name).x + 4;
            ui.painter().icon(arrow, .{ .x = arrow_x, .y = cell.y + style.frame_padding.y + (line_h - glyph) / 2, .w = glyph, .h = glyph }, colors.text_muted);
        }
        ui.popClip();
        if (i > 0) ui.drawRect(.{ .rect = .{ .x = cell.x, .y = cell.y + 4, .w = style.separator_width, .h = cell.h - 8 }, .fill = colors.separator });
    }
    ui.popClip();
    ui.drawRect(.{ .rect = .{ .x = rect.x, .y = header.bottom() - style.separator_width, .w = rect.w, .h = style.separator_width }, .fill = colors.border });

    ui.table = state;
    beginScrollRegion(ui, body_id, body, 0, 0);
    return result;
}

/// Starts the next row of the table, ending the previous one.
pub fn tableRow(ui: *Ui) void {
    const t = if (ui.table) |*t| t else unreachable; // tableRow outside a table
    if (t.row_open) endRow(ui, t);
    const stripe = t.striped and t.row % 2 == 1;
    ui.pushIdInt(t.row);
    ui.beginHorizontal(.{ .spacing = 0, .alignment = .center, .fill = if (stripe) ui.style.colors.text.withAlpha(10) else .transparent });
    t.row += 1;
    t.row_open = true;
    t.column = 0;
    beginCell(ui, t);
}

/// Moves to the next cell of the current row.
pub fn tableNextColumn(ui: *Ui) void {
    const t = if (ui.table) |*t| t else unreachable; // tableNextColumn outside a table
    std.debug.assert(t.row_open); // call tableRow first
    if (t.column + 1 >= t.count) return; // more cells than columns: stay in the last one
    endCell(ui);
    t.column += 1;
    beginCell(ui, t);
}

/// Ends the table from `beginTable`.
pub fn endTable(ui: *Ui) void {
    const t = if (ui.table) |*t| t else unreachable; // endTable without beginTable
    if (t.row_open) endRow(ui, t);
    const rect = t.rect;
    ui.table = null;
    endScrollRegion(ui);
    ui.popId();
    ui.last_rect = rect;
}

fn beginCell(ui: *Ui, t: *const TableState) void {
    const w = t.widths[t.column];
    const clip = ui.clipRect();
    ui.pushClip(.{ .x = t.left + t.offsets[t.column], .y = clip.y, .w = w, .h = clip.h });
    ui.beginVertical(.{ .width = .px(w), .padding = ui.style.frame_padding.y });
}

fn endCell(ui: *Ui) void {
    ui.endVertical();
    ui.popClip();
}

fn endRow(ui: *Ui, t: *TableState) void {
    endCell(ui);
    // Cells left out of a short row still take their width, keeping the
    // row's background full width.
    ui.endHorizontal();
    ui.popId();
    t.row_open = false;
}
