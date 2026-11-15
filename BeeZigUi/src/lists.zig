//! Long lists and trees, as in BeeModel's outliner, and tile grids, as in its
//! asset browser. Only the rows in view are described, so thousands of rows
//! cost no more than a screenful.
//!
//!     var list = ui.beginList("outliner", selected, &state, .{});
//!     for (list.first..list.end) |i| {
//!         ui.beginRow(&list, i, .{ .label = names[i], .depth = depth[i], .fold = open[i], .renamable = true });
//!         _ = ui.iconToggle("##eye", &visible[i], .{ .on = eye, .off = eye_off });
//!         const row = ui.endRow(&list);
//!         if (row.fold_clicked) open[i] = !open[i].?;
//!         if (row.renamed) |name| rename(i, name);
//!     }
//!     const done = ui.endList(&list);
//!
//! `selected` is one bool per row, which the list keeps up to date: a click
//! selects one row, Ctrl+click adds or removes one, Shift+click selects the
//! range from the last click. With the list focused, Up / Down move (Shift
//! extends), Home / End, Page Up / Down, Ctrl+A selects all, F2 renames,
//! Enter activates, Delete asks to delete.

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const icons = @import("icons.zig");
const ui_mod = @import("ui.zig");
const containers = @import("containers.zig");
const text_input = @import("text_input.zig");
const input_mod = @import("input.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;

/// Selection anchor, keyboard cursor and inline rename of a list or tile
/// grid. The app keeps one per list.
pub const ListState = struct {
    /// Where the last plain or Ctrl click was: the start of a Shift range.
    anchor: ?usize = null,
    /// The row the keyboard is on.
    cursor: ?usize = null,
    /// The row being renamed.
    rename: ?usize = null,
    rename_started: bool = false,
    buffer: [128]u8 = undefined,
    len: usize = 0,
    /// Scroll so the cursor shows, next frame.
    reveal: bool = false,

    /// Applies a click on `index` with `modifiers` to `selected`.
    pub fn click(self: *ListState, selected: []bool, index: usize, modifiers: input_mod.Modifiers) void {
        if (index >= selected.len) return;
        if (modifiers.shift) {
            // (an anchor past the end is from before the list got shorter)
            const from = if (self.anchor) |a| (if (a < selected.len) a else index) else index;
            if (!modifiers.ctrl) @memset(selected, false);
            const lo = @min(from, index);
            const hi = @max(from, index);
            @memset(selected[lo .. hi + 1], true);
        } else if (modifiers.ctrl) {
            selected[index] = !selected[index];
            self.anchor = index;
        } else {
            @memset(selected, false);
            selected[index] = true;
            self.anchor = index;
        }
        self.cursor = index;
    }

    /// Keeps the cursor, anchor and rename inside a list of `count` rows,
    /// for when the app removed rows since last frame.
    pub fn fit(self: *ListState, count: usize) void {
        if (self.cursor) |c| if (c >= count) {
            self.cursor = if (count > 0) count - 1 else null;
        };
        if (self.anchor) |a| if (a >= count) {
            self.anchor = null;
        };
        if (self.rename) |r| if (r >= count) {
            self.rename = null;
        };
    }

    /// Starts renaming row `index` from `text`.
    pub fn startRename(self: *ListState, index: usize) void {
        self.rename = index;
        self.rename_started = false;
    }
};

/// Options for `beginList`.
pub const ListOptions = struct {
    width: layout.Size = .fill,
    height: layout.Size = .fill,
    frame: bool = true,
};

/// A list being described, from `beginList`: describe rows `first..end`.
pub const List = struct {
    id: Id,
    first: usize,
    end: usize,
    count: usize,
    row_h: f32,
    selected: []bool,
    state: *ListState,
    focused: bool,
    /// Results the keyboard produced this frame.
    activated: ?usize = null,
    delete: bool = false,
    changed: bool = false,
    /// The row being described.
    row: usize = 0,
    row_rect: Rect = .{},
    row_label: []const u8 = "",
    row_renamable: bool = false,
    row_fold_clicked: bool = false,
    row_renamed: ?[]const u8 = null,
    row_tooltip: []const u8 = "",
    row_fold_rect: Rect = .{},
    row_icon_clicked: bool = false,
    row_icon_rect: Rect = .{},
};

/// What happened to a row, from `endRow`.
pub const RowResult = struct {
    /// The row's own interaction: `clicked`, `held`, `context_clicked`;
    /// pass it to `dragSource` to drag rows.
    interaction: Interaction,
    rect: Rect,
    /// Double-clicked (or Enter on the cursor row): open it.
    activated: bool = false,
    /// The fold arrow was clicked: open or close it.
    fold_clicked: bool = false,
    /// A rename ended with this new name, valid this frame.
    renamed: ?[]const u8 = null,
    /// Where its fold arrow is (empty without one), to name it in a test
    /// record of the app's.
    fold_rect: Rect = .{},
    /// Its icon was clicked (`RowOptions.icon_button`).
    icon_clicked: bool = false,
    /// Where its icon is (empty without one).
    icon_rect: Rect = .{},
};

/// What the list as a whole did, from `endList`.
pub const ListResult = struct {
    /// The selection changed.
    changed: bool = false,
    /// Delete was pressed with the list focused.
    delete: bool = false,
    /// A row was activated (Enter, or a double click).
    activated: ?usize = null,
    /// A click on empty space below the rows (it also cleared the
    /// selection); a drop target for "no parent".
    empty_clicked: bool = false,
    /// The empty space below the rows.
    empty: Rect = .{},
};

fn rowHeight(ui: *const Ui) f32 {
    return ui.textSize("").y + ui.style.frame_padding.y;
}

/// Starts a list of `selected.len` rows in a scrolling area. Describe the
/// rows from `first` to `end` with `beginRow` / `endRow`, then `endList`.
pub fn beginList(ui: *Ui, name: []const u8, selected: []bool, state: *ListState, options: ListOptions) List {
    const style = &ui.style;
    const rect = ui.placeSized(options.width, options.height, .{ .x = style.widget_width, .y = 200 });
    const widget = ui.id(name);
    var focus = ui.interact(ui.id("##listfocus"), .{});
    // The list takes focus as one stop; rows don't each join the Tab order.
    focus.rect = rect;
    ui.focusable(widget, &focus);
    const focused = ui.focused == widget;
    if (options.frame) ui.drawRect(.{ .rect = rect, .fill = style.colors.input, .border = style.colors.border, .border_width = style.border_width, .radius = style.rounding });

    const count = selected.len;
    const row_h = rowHeight(ui);
    var list: List = .{ .id = widget, .first = 0, .end = 0, .count = count, .row_h = row_h, .selected = selected, .state = state, .focused = focused };
    state.fit(count);
    if (focused) keys(ui, &list);

    containers.beginScrollRegion(ui, widget, rect, 2, 0);
    const frame = ui.scroll_stack[ui.scroll_depth - 1];
    const scroll_state = ui.scroll_states.getPtr(widget);
    var scroll = if (scroll_state) |s| s.scroll else 0;
    // Bring the keyboard's row into view.
    if (state.reveal) {
        state.reveal = false;
        if (state.cursor) |c| if (scroll_state) |s| {
            const top = @as(f32, @floatFromInt(c)) * row_h;
            if (top < s.scroll) s.scroll = top;
            if (top + row_h > s.scroll + frame.view.h - 4) s.scroll = top + row_h - frame.view.h + 4;
            scroll = s.scroll;
            ui.requestRedraw();
        };
    }
    const first: usize = @intFromFloat(@max(0, @floor(scroll / row_h)));
    const visible: usize = @intFromFloat(@ceil(frame.view.h / row_h) + 1);
    list.first = @min(first, count);
    list.end = @min(count, list.first + visible);
    // Space for the rows above the view, so the scroll range is right.
    if (list.first > 0) _ = ui.placeSized(.fill, .{ .fixed = @as(f32, @floatFromInt(list.first)) * row_h }, .{});
    return list;
}

/// The keyboard, with the list focused.
fn keys(ui: *Ui, list: *List) void {
    const st = list.state;
    const count = list.count;
    if (count == 0 or st.rename != null) return;
    for (ui.input.keyEvents()) |event| {
        const m = event.modifiers;
        var to: ?usize = null;
        const at = st.cursor orelse 0;
        const page: usize = 10;
        switch (event.key) {
            .down => to = if (st.cursor == null) 0 else @min(count - 1, at + 1),
            .up => to = at -| 1,
            .home => to = 0,
            .end => to = count - 1,
            .page_down => to = @min(count - 1, at + page),
            .page_up => to = at -| page,
            .a => if (m.ctrl) {
                @memset(list.selected, true);
                list.changed = true;
            },
            .space => if (st.cursor) |c| {
                st.click(list.selected, c, .{ .ctrl = true });
                list.changed = true;
            },
            .f2 => if (st.cursor) |c| st.startRename(c),
            .enter => list.activated = st.cursor,
            .delete => list.delete = true,
            else => {},
        }
        if (to) |t| {
            st.cursor = t;
            if (m.ctrl) {
                // Ctrl moves the cursor only; Space then toggles.
            } else {
                st.click(list.selected, t, .{ .shift = m.shift });
                list.changed = true;
            }
            st.reveal = true;
        }
    }
}

/// Options for `beginRow`.
pub const RowOptions = struct {
    label: []const u8,
    icon: ?icons.Icon = null,
    /// How far in, for trees: children are one deeper than their parent.
    depth: u32 = 0,
    /// A fold arrow: null for none, else open (true) or closed.
    fold: ?bool = null,
    /// Shown in the accent color: BeeModel's active object, in gold.
    active: bool = false,
    /// Double-click or F2 renames it in place.
    renamable: bool = false,
    tooltip: []const u8 = "",
    /// A small square of this color before the icon (BeeModel: an
    /// object's color).
    swatch: ?draw.Color = null,
    /// The label's color instead of the theme's (a hidden object, dimmed).
    /// `active` wins.
    text_color: ?draw.Color = null,
    /// The icon's color instead of the text color (a folder's color).
    icon_color: ?draw.Color = null,
    /// The icon is a button of its own (a folder's color: a click takes the
    /// next): `RowResult.icon_clicked`, not a click on the row.
    icon_button: bool = false,
};

/// Starts row `index`: draws its selection, indent, fold arrow, icon and
/// label, and leaves a row open for widgets at its right (toggles), which
/// a `ui.spacer(.fill)` is not needed for. End it with `endRow`.
pub fn beginRow(ui: *Ui, list: *List, index: usize, options: RowOptions) void {
    const style = &ui.style;
    const colors = &style.colors;
    const st = list.state;
    list.row = index;
    list.row_label = options.label;
    list.row_renamable = options.renamable;
    list.row_fold_clicked = false;
    list.row_renamed = null;
    list.row_tooltip = options.tooltip;
    list.row_fold_rect = .{};
    list.row_icon_clicked = false;
    list.row_icon_rect = .{};
    const rect = ui.placeSized(.fill, .{ .fixed = list.row_h }, .{});
    list.row_rect = rect;
    ui.pushIdInt(index);

    const selected = index < list.selected.len and list.selected[index];
    if (selected) ui.drawRect(.{ .rect = rect, .fill = colors.button_active.withAlpha(150), .radius = style.rounding });
    if (list.focused and ui.focus_visible and st.cursor == index) ui.drawRect(.{ .rect = rect, .border = colors.focus_ring, .border_width = 1, .radius = style.rounding });

    const line_h = ui.textSize("").y;
    var x = rect.x + 4 + @as(f32, @floatFromInt(options.depth)) * style.indent;
    const y = rect.y + (rect.h - line_h) / 2;
    if (options.fold) |open| {
        const s = line_h * 0.75;
        const arrow: Rect = .{ .x = x, .y = rect.y + (rect.h - s) / 2, .w = s, .h = s };
        const r = ui.interact(ui.id("##fold"), arrow.inset(-3));
        if (r.clicked) list.row_fold_clicked = true;
        list.row_fold_rect = arrow.inset(-3);
        if (ui.recording) {
            const name = std.fmt.allocPrint(ui.frameAllocator(), "{s} fold", .{options.label}) catch "fold";
            ui.recordWidget(.custom, r.id, name, arrow.inset(-3), .{ .value = if (open) "open" else "closed", .hovered = r.hovered });
        }
        ui.painter().icon(.{ .builtin = if (open) .chevron_down else .chevron_right }, arrow, if (r.hovered) colors.text else colors.text_muted);
    }
    x += line_h * 0.75 + 4;
    if (options.swatch) |c| {
        const s = @round(line_h * 0.4);
        ui.drawRect(.{ .rect = .{ .x = x, .y = rect.y + (rect.h - s) / 2, .w = s, .h = s }, .fill = c });
        x += s + 3;
    }
    if (options.icon) |ic| {
        const ir: Rect = .{ .x = x, .y = y, .w = line_h, .h = line_h };
        list.row_icon_rect = ir;
        var hot = false;
        if (options.icon_button) {
            const r = ui.interact(ui.id("##icon"), ir);
            if (r.clicked) list.row_icon_clicked = true;
            hot = r.hovered;
        }
        if (hot) ui.drawRect(.{ .rect = ir.inset(-1), .fill = colors.button_hovered, .radius = style.rounding });
        ui.painter().icon(ic, ir, options.icon_color orelse colors.text);
        x += line_h + 6;
    }

    ui.beginRegion(ui.id("##row"), .{ .x = x, .y = rect.y, .w = @max(0, rect.right() - x), .h = rect.h }, .horizontal, 0, .center);
    if (st.rename == index) {
        // Typing the new name in place of the label.
        const field = ui.placeSized(.fill, .{ .fixed = rect.h - 2 }, .{});
        const fid = ui.id("##rename");
        var r = ui.interact(fid, field);
        if (!st.rename_started) {
            st.rename_started = true;
            const n = @import("font.zig").fitUtf8(options.label, st.buffer.len);
            @memcpy(st.buffer[0..n], options.label[0..n]);
            st.len = n;
            ui.setFocus(fid);
            ui.text_edit.id = .none;
        }
        const was_focused = ui.focused == fid;
        // Keeps its focus from frame to frame, like any field.
        ui.focusable(fid, &r);
        text_input.editField(ui, fid, field, &st.buffer, &st.len, &r, was_focused, "");
        if (r.cancelled) {
            st.rename = null;
            ui.setFocus(list.id);
        } else if (r.submitted or ui.focused != fid) {
            st.rename = null;
            const text = std.mem.trim(u8, st.buffer[0..st.len], " ");
            if (text.len > 0 and !std.mem.eql(u8, text, options.label)) {
                list.row_renamed = ui.frameAllocator().dupe(u8, text) catch text;
            }
            if (r.submitted) ui.setFocus(list.id);
        }
    } else {
        const label_rect = ui.placeSized(.fill, .{ .fixed = rect.h }, .{});
        ui.pushClip(label_rect);
        ui.drawText(.{ .x = label_rect.x, .y = y }, if (options.active) colors.accent else options.text_color orelse colors.text, options.label);
        ui.popClip();
    }
}

/// Ends the row: its own click (described after its toggles, so they win),
/// selection, rename on double-click, and what happened.
pub fn endRow(ui: *Ui, list: *List) RowResult {
    ui.endRegion();
    const st = list.state;
    const index = list.row;
    const rect = list.row_rect;
    const r = ui.interact(ui.id("##rowclick"), rect);
    var result: RowResult = .{ .interaction = r, .rect = rect, .fold_clicked = list.row_fold_clicked, .renamed = list.row_renamed, .fold_rect = list.row_fold_rect, .icon_clicked = list.row_icon_clicked, .icon_rect = list.row_icon_rect };
    if (r.pressed) {
        const m = ui.input.modifiers;
        const clicks = ui.input.press_clicks.get(.left);
        // Pressing a selected row keeps the selection, so it can be dragged.
        const keep = index < list.selected.len and list.selected[index] and !m.ctrl and !m.shift;
        if (!keep) {
            st.click(list.selected, index, m);
            list.changed = true;
        } else st.cursor = index;
        ui.setFocus(list.id);
        if (clicks == 2) {
            if (list.row_renamable) st.startRename(index) else result.activated = true;
        }
    }
    // A click (not a drag) on a row of several selected ones selects it alone.
    if (r.clicked and !ui.input.modifiers.ctrl and !ui.input.modifiers.shift and ui.drag_state.phase != .active) {
        var many = false;
        var n: usize = 0;
        for (list.selected) |sel| {
            if (sel) n += 1;
        }
        many = n > 1;
        if (many and st.rename == null) {
            st.click(list.selected, index, .{});
            list.changed = true;
        }
    }
    if (list.activated == index) result.activated = true;
    if (list.row_tooltip.len > 0) ui.tooltipRich(r, .{ .body = list.row_tooltip, .placement = .beside });
    ui.recordWidget(.row, r.id, list.row_label, rect, .{ .value = if (index < list.selected.len and list.selected[index]) "true" else "false", .hovered = r.hovered, .focused = list.focused and st.cursor == index });
    ui.popId();
    return result;
}

/// Ends the list.
pub fn endList(ui: *Ui, list: *List) ListResult {
    // Space for the rows below the view.
    const below = list.count - list.end;
    if (below > 0) _ = ui.placeSized(.fill, .{ .fixed = @as(f32, @floatFromInt(below)) * list.row_h }, .{});
    // The empty space under the last row, as a target ("no parent").
    const frame = ui.scroll_stack[ui.scroll_depth - 1];
    const content_bottom = frame.view.y + 2 + @as(f32, @floatFromInt(list.count)) * list.row_h - (if (ui.scroll_states.get(list.id)) |s| s.scroll else 0);
    var result: ListResult = .{ .changed = list.changed, .delete = list.delete, .activated = list.activated };
    if (content_bottom < frame.view.bottom()) {
        result.empty = .{ .x = frame.view.x, .y = content_bottom, .w = frame.view.w, .h = frame.view.bottom() - content_bottom };
        const r = ui.interact(ui.id("##empty"), result.empty);
        if (r.pressed) {
            @memset(list.selected, false);
            result.changed = true;
            ui.setFocus(list.id);
        }
        result.empty_clicked = r.clicked;
    }
    containers.endScrollRegion(ui);
    ui.drawFocusRing(list.id, frame.rect);
    ui.recordWidget(.list, list.id, "list", frame.rect, .{ .focused = list.focused });
    return result;
}

// ---- tile grids --------------------------------------------------------------

/// Options for `beginTiles`.
pub const TileOptions = struct {
    width: layout.Size = .fill,
    height: layout.Size = .fill,
    tile_width: f32 = 120,
    tile_height: f32 = 120,
};

/// A tile grid being described, from `beginTiles`.
pub const Tiles = struct {
    list: List,
    columns: usize,
    tile_w: f32,
    tile_h: f32,
    origin: Vec2,
};

/// Options for `tile`.
pub const TileItem = struct {
    label: []const u8,
    image: ?*const draw.Image = null,
    icon: ?icons.Icon = null,
    tooltip: []const u8 = "",
};

/// Starts a grid of `selected.len` tiles that scrolls. Describe the tiles
/// from `tiles.list.first` to `tiles.list.end` with `tile`, then
/// `endTiles`. Selection and keys work as in a list, with Left and Right
/// too.
pub fn beginTiles(ui: *Ui, name: []const u8, selected: []bool, state: *ListState, options: TileOptions) Tiles {
    const style = &ui.style;
    const rect = ui.placeSized(options.width, options.height, .{ .x = 400, .y = 300 });
    const widget = ui.id(name);
    var focus = ui.interact(ui.id("##tilefocus"), .{});
    focus.rect = rect;
    ui.focusable(widget, &focus);
    const focused = ui.focused == widget;
    ui.drawRect(.{ .rect = rect, .fill = style.colors.input, .border = style.colors.border, .border_width = style.border_width, .radius = style.rounding });
    const count = selected.len;
    const columns: usize = @max(1, @as(usize, @intFromFloat(@floor((rect.w - 16) / options.tile_width))));
    var list: List = .{ .id = widget, .first = 0, .end = 0, .count = count, .row_h = options.tile_height, .selected = selected, .state = state, .focused = focused };
    state.fit(count);
    if (focused and count > 0) {
        for (ui.input.keyEvents()) |event| {
            const at = state.cursor orelse 0;
            const to: ?usize = switch (event.key) {
                .right => @min(count - 1, at + 1),
                .left => at -| 1,
                .down => @min(count - 1, at + columns),
                .up => at -| columns,
                .home => 0,
                .end => count - 1,
                else => null,
            };
            if (to) |t| {
                state.click(selected, t, .{ .shift = event.modifiers.shift });
                list.changed = true;
                state.reveal = true;
            }
            if (event.key == .enter) list.activated = state.cursor;
            if (event.key == .delete) list.delete = true;
            if (event.key == .a and event.modifiers.ctrl) {
                @memset(selected, true);
                list.changed = true;
            }
        }
    }
    containers.beginScrollRegion(ui, widget, rect, 6, 0);
    const frame = ui.scroll_stack[ui.scroll_depth - 1];
    const scroll_state = ui.scroll_states.getPtr(widget);
    var scroll = if (scroll_state) |s| s.scroll else 0;
    if (state.reveal) {
        state.reveal = false;
        if (state.cursor) |c| if (scroll_state) |s| {
            const top = @as(f32, @floatFromInt(c / columns)) * options.tile_height;
            if (top < s.scroll) s.scroll = top;
            if (top + options.tile_height > s.scroll + frame.view.h - 12) s.scroll = top + options.tile_height - frame.view.h + 12;
            scroll = s.scroll;
            ui.requestRedraw();
        };
    }
    const rows = (count + columns - 1) / columns;
    const first_row: usize = @intFromFloat(@max(0, @floor(scroll / options.tile_height)));
    const visible_rows: usize = @intFromFloat(@ceil(frame.view.h / options.tile_height) + 1);
    list.first = @min(count, first_row * columns);
    list.end = @min(count, (first_row + visible_rows) * columns);
    // The whole grid's height, so the scroll range is right.
    const origin: Vec2 = .{ .x = frame.view.x + 6, .y = frame.view.y + 6 - scroll };
    _ = ui.placeSized(.fill, .{ .fixed = @as(f32, @floatFromInt(rows)) * options.tile_height }, .{});
    return .{ .list = list, .columns = columns, .tile_w = options.tile_width, .tile_h = options.tile_height, .origin = origin };
}

/// Tile `index` of the grid: a picture and a label below it.
pub fn tile(ui: *Ui, tiles: *Tiles, index: usize, item: TileItem) RowResult {
    const style = &ui.style;
    const colors = &style.colors;
    const list = &tiles.list;
    const st = list.state;
    const col = index % tiles.columns;
    const row = index / tiles.columns;
    const rect: Rect = .{
        .x = tiles.origin.x + @as(f32, @floatFromInt(col)) * tiles.tile_w,
        .y = tiles.origin.y + @as(f32, @floatFromInt(row)) * tiles.tile_h,
        .w = tiles.tile_w - 6,
        .h = tiles.tile_h - 6,
    };
    ui.pushIdInt(index);
    defer ui.popId();
    const r = ui.interact(ui.id("##tile"), rect);
    var result: RowResult = .{ .interaction = r, .rect = rect };
    const selected = index < list.selected.len and list.selected[index];
    if (r.pressed) {
        const m = ui.input.modifiers;
        if (!(selected and !m.ctrl and !m.shift)) {
            st.click(list.selected, index, m);
            list.changed = true;
        } else st.cursor = index;
        ui.setFocus(list.id);
        if (ui.input.press_clicks.get(.left) == 2) result.activated = true;
    }
    if (list.activated == index) result.activated = true;
    const line_h = ui.textSize("").y;
    ui.drawRect(.{ .rect = rect, .fill = if (selected) colors.button_active.withAlpha(150) else if (r.hovered) colors.button_hovered else colors.button, .border = if (list.focused and ui.focus_visible and st.cursor == index) colors.focus_ring else colors.border, .border_width = 1, .radius = style.rounding });
    const pic: Rect = .{ .x = rect.x + 6, .y = rect.y + 6, .w = rect.w - 12, .h = rect.h - line_h - 16 };
    if (item.image) |img| {
        ui.painter().image(img, pic, .{});
    } else if (item.icon) |ic| {
        const s = @min(pic.w, pic.h) * 0.5;
        ui.painter().icon(ic, .{ .x = pic.x + (pic.w - s) / 2, .y = pic.y + (pic.h - s) / 2, .w = s, .h = s }, colors.text_muted);
    }
    ui.pushClip(rect.inset(4));
    const tw = ui.textSize(item.label).x;
    ui.drawText(.{ .x = rect.x + @max(6, (rect.w - tw) / 2), .y = rect.bottom() - line_h - 6 }, colors.text, item.label);
    ui.popClip();
    if (item.tooltip.len > 0) ui.tooltipRich(r, .{ .title = item.label, .body = item.tooltip });
    ui.recordWidget(.tile, r.id, item.label, rect, .{ .value = if (selected) "true" else "false", .hovered = r.hovered, .focused = list.focused and st.cursor == index });
    return result;
}

/// Ends the tile grid.
pub fn endTiles(ui: *Ui, tiles: *Tiles) ListResult {
    const list = &tiles.list;
    const frame = ui.scroll_stack[ui.scroll_depth - 1];
    containers.endScrollRegion(ui);
    ui.drawFocusRing(list.id, frame.rect);
    ui.recordWidget(.list, list.id, "tiles", frame.rect, .{ .focused = list.focused });
    return .{ .changed = list.changed, .delete = list.delete, .activated = list.activated };
}

test "click, ctrl+click and shift+click select like a file manager" {
    var selected = [_]bool{ false, false, false, false, false };
    var st: ListState = .{};
    st.click(&selected, 1, .{});
    try std.testing.expectEqualSlices(bool, &.{ false, true, false, false, false }, &selected);
    st.click(&selected, 3, .{ .ctrl = true });
    try std.testing.expectEqualSlices(bool, &.{ false, true, false, true, false }, &selected);
    st.click(&selected, 4, .{ .shift = true });
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, true, true }, &selected);
    st.click(&selected, 0, .{ .shift = true, .ctrl = true });
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, true, true }, &selected);
}
