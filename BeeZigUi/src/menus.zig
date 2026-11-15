//! Menus: a menu bar, menus and submenus, context menus, a command palette
//! (BeeModel's F3) and a field for editing a shortcut.
//!
//!     ui.beginMenuBar();
//!     if (ui.beginMenu("File")) {
//!         defer ui.endMenu();
//!         if (ui.menuItem("Save", .{ .shortcut = "Ctrl+S" })) save();
//!         if (ui.beginSubmenu("Open Recent", .{})) {
//!             defer ui.endMenu();
//!             for (recent) |path| if (ui.menuItem(path, .{})) open(path);
//!         }
//!         ui.menuSeparator();
//!         if (ui.menuItem("Quit", .{ .disabled = if (busy) "A render is running" else null })) quit();
//!     }
//!     ui.endMenuBar();
//!
//! The mouse: click a title, then hover across the bar and into submenus.
//! The keyboard: F10 or Alt+letter opens a menu, Up / Down move, Right opens
//! a submenu or the next menu, Left goes back, Enter picks, Escape closes one
//! level.

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const icons = @import("icons.zig");
const input_mod = @import("input.zig");
const ui_mod = @import("ui.zig");
const overlay = @import("overlay.zig");
const text_input = @import("text_input.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;

const max_levels = overlay.max_popups;
const max_bar = 24;

/// Options for `menuItem`.
pub const ItemOptions = struct {
    /// Shown at the right, such as "Ctrl+S". `zui.Shortcut.format` makes one.
    shortcut: []const u8 = "",
    icon: ?icons.Icon = null,
    /// Non-null shows a check mark column; true shows the mark.
    checked: ?bool = null,
    /// Why it can't be used now; null if it can. Shown faded; the tooltip
    /// says why, and a click reports it through `Ui.disabledClick`.
    disabled: ?[]const u8 = null,
    /// What it does, shown beside the item when the pointer rests on it.
    tooltip: []const u8 = "",
};

/// Options for `beginSubmenu`.
pub const SubmenuOptions = struct {
    icon: ?icons.Icon = null,
    disabled: ?[]const u8 = null,
};

/// Menu navigation state kept in the `Ui`.
pub const State = struct {
    /// The keyboard is driving: show the highlight even without a hover.
    keyboard: bool = false,
    highlight: [max_levels]?u32 = @splat(null),
    /// Items described per level, this frame and the last.
    count: [max_levels]u32 = @splat(0),
    count_last: [max_levels]u32 = @splat(0),
    /// Whether any item of a level has a check or an icon, this frame and
    /// the last, so columns are kept only when used.
    checks: [max_levels]bool = @splat(false),
    checks_last: [max_levels]bool = @splat(false),
    icons: [max_levels]bool = @splat(false),
    icons_last: [max_levels]bool = @splat(false),
    /// Enter, or Right, was pressed for the highlighted item of a level.
    activate: [max_levels]bool = @splat(false),
    open_sub: [max_levels]bool = @splat(false),
    /// Menu bar: titles described this frame and last, and their letters.
    bar_count: u32 = 0,
    bar_count_last: u32 = 0,
    bar_letters: [max_bar]u8 = @splat(0),
    /// A bar menu to open this frame (keys, or hover while one is open).
    bar_request: ?u32 = null,
    /// One asked for while describing menus, for the next frame.
    bar_request_next: ?u32 = null,
    /// The open bar menu's index.
    bar_open: ?u32 = null,
    bar_seen_open: bool = false,
    in_bar: bool = false,
    /// The command palette.
    palette: Palette = .{},
    /// The shortcut field waiting for a key.
    capturing: Id = .none,
    /// The menu was opened by a press the app took (a title of a bar it
    /// draws, the right-click that opened a context menu): the release of
    /// that button over an item picks it, once the pointer has moved
    /// `held_slop` from `held_from`.
    held: bool = false,
    held_from: Vec2 = .{},
    /// This frame's keys were taken by a menu: a submenu they opened in the
    /// same frame doesn't take them again (Enter on its row would pick its
    /// first item).
    keys_taken: bool = false,
};

/// How far the pointer must move from where a held menu opened before its
/// release picks: a right-click's own release picks nothing.
pub const held_slop = 4;

/// Called by `Ui.beginFrame`.
pub fn beginFrame(ui: *Ui) void {
    const m = &ui.menu_state;
    m.count_last = m.count;
    m.count = @splat(0);
    m.checks_last = m.checks;
    m.checks = @splat(false);
    m.icons_last = m.icons;
    m.icons = @splat(false);
    m.activate = @splat(false);
    m.open_sub = @splat(false);
    m.keys_taken = false;
    m.bar_count_last = m.bar_count;
    m.bar_count = 0;
    if (ui.mouse_delta.length() > 0) m.keyboard = false;
    // Levels that closed forget their highlight.
    for (ui.popup_count..max_levels) |i| m.highlight[i] = null;
}

/// Called by `Ui.endFrame`.
pub fn endFrame(ui: *Ui) void {
    const m = &ui.menu_state;
    // A held menu is held until any button is let go, or it closes.
    if (ui.input.mouse_released.count() > 0 or ui.popup_count == 0) m.held = false;
    if (!m.bar_seen_open) m.bar_open = null;
    m.bar_seen_open = false;
}

/// Handles the keys for the menu at `level` if it is the innermost open one.
fn menuKeys(ui: *Ui, level: usize) void {
    const m = &ui.menu_state;
    if (level + 1 != ui.popup_count or m.keys_taken) return;
    m.keys_taken = true;
    const count = m.count_last[level];
    for (ui.input.keyEvents()) |event| {
        switch (event.key) {
            .down, .up => {
                m.keyboard = true;
                if (count == 0) continue;
                const h = m.highlight[level];
                m.highlight[level] = if (event.key == .down)
                    (if (h) |i| (i + 1) % count else 0)
                else
                    (if (h) |i| (i + count - 1) % count else count - 1);
            },
            .home => m.highlight[level] = 0,
            .end => m.highlight[level] = if (count > 0) count - 1 else null,
            .enter, .space => {
                m.keyboard = true;
                m.activate[level] = true;
            },
            .right => {
                m.keyboard = true;
                m.open_sub[level] = true;
            },
            .left => {
                m.keyboard = true;
                if (level > 0) {
                    ui.popup_count = level;
                } else if (m.bar_open) |b| {
                    if (m.bar_count_last > 0) m.bar_request_next = (b + m.bar_count_last - 1) % m.bar_count_last;
                }
            },
            else => {},
        }
    }
}

/// Starts a popup used as a menu: same as `beginPopup`, plus the keyboard.
/// Use it for a context menu opened with `openPopup` or `openPopupAt`.
pub fn beginPopupMenu(ui: *Ui, name: []const u8) bool {
    return beginPopupMenuSized(ui, name, 180);
}

/// `beginPopupMenu` at least `min_width` wide.
pub fn beginPopupMenuSized(ui: *Ui, name: []const u8, min_width: f32) bool {
    const level = ui.popup_nesting;
    if (!ui.beginPopup(name, .{ .min_width = min_width })) return false;
    menuKeys(ui, level);
    // A right or middle press in a menu holds it as well: that button's
    // release over an item picks it (a left click does anyway).
    if (ui.hovered_window == ui.current_window and
        (ui.input.mouse_pressed.contains(.right) or ui.input.mouse_pressed.contains(.middle)))
    {
        ui.menu_state.held = true;
        ui.menu_state.held_from = .{ .x = -1e9, .y = -1e9 };
    }
    return true;
}

/// The menu just opened (with `openPopupAt`) is held by a button the app
/// took the press of, at `from`: a title of a bar the app draws itself, or
/// the right-click that opened a context menu. Letting go of it over an
/// item picks the item, once the pointer has moved a few units, so press,
/// drag and release works and a right-click's own release picks nothing.
pub fn holdMenu(ui: *Ui, from: Vec2) void {
    ui.menu_state.held = true;
    ui.menu_state.held_from = from;
}

/// The popup menu about to be described is menu `index` of a bar of `count`
/// the app draws itself (not `beginMenuBar`): Left / Right walk the bar.
/// Call each frame before its `beginPopupMenu`; `takeBarRequest` says which
/// menu the keys asked for.
pub fn externalBar(ui: *Ui, index: u32, count: u32) void {
    const m = &ui.menu_state;
    m.bar_open = index;
    m.bar_count_last = count;
    m.bar_seen_open = true;
}

/// The bar menu Left / Right asked to open (see `externalBar`), once.
pub fn takeBarRequest(ui: *Ui) ?u32 {
    const m = &ui.menu_state;
    defer m.bar_request_next = null;
    return m.bar_request_next;
}

/// Highlights the first item of the menu at `level`, as when a menu is
/// opened from the keyboard.
pub fn highlightFirst(ui: *Ui, level: usize) void {
    if (level >= max_levels) return;
    ui.menu_state.highlight[level] = 0;
    ui.menu_state.keyboard = true;
}

/// Ends a menu, submenu or popup menu.
pub fn endMenu(ui: *Ui) void {
    const level = ui.popup_nesting - 1;
    const m = &ui.menu_state;
    // Right on an item without a submenu, in a bar menu: the next menu.
    if (level == 0 and m.open_sub[0] and m.bar_open != null and m.bar_count_last > 0) {
        m.bar_request_next = (m.bar_open.? + 1) % m.bar_count_last;
    }
    ui.endPopup();
}

/// Opens a context menu for `item` when it is right-clicked, and starts it
/// while it is open. End it with `endMenu`.
///
///     const row = ui.selectable("Cube", selected, .{});
///     if (ui.beginContextMenu(row, "Cube menu")) {
///         defer ui.endMenu();
///         if (ui.menuItem("Delete", .{ .shortcut = "X" })) delete();
///     }
pub fn beginContextMenu(ui: *Ui, item: Interaction, name: []const u8) bool {
    if (item.context_clicked) {
        const at = ui.input.press_pos.get(.right);
        ui.openPopupAt(name, .{ .x = at.x, .y = at.y });
        ui.menu_state.highlight[ui.popup_nesting] = null;
    }
    return beginPopupMenu(ui, name);
}

/// A thin line between groups of items.
pub fn menuSeparator(ui: *Ui) void {
    const r = ui.placeSized(.fill, .{ .fixed = 1 }, .{});
    ui.drawRect(.{ .rect = r, .fill = ui.style.colors.separator });
}

/// The shared row of `menuItem` and `beginSubmenu`.
const Row = struct {
    result: Interaction,
    rect: Rect,
    highlighted: bool,
    index: u32,
    level: usize,
    /// A held menu's button let go over it.
    released: bool = false,
};

fn row(ui: *Ui, name: []const u8, icon: ?icons.Icon, checked: ?bool, right_text: []const u8, submenu: bool) Row {
    const style = &ui.style;
    const colors = &style.colors;
    const m = &ui.menu_state;
    const level = ui.popup_nesting -| 1;
    const index = m.count[level];
    m.count[level] += 1;

    const text = Ui.visibleLabel(name);
    const line_h = ui.textSize("").y;
    const pad_y = style.frame_padding.y * 0.6;
    const pad_x = style.frame_padding.x * 0.6;
    if (checked != null) m.checks[level] = true;
    if (icon != null) m.icons[level] = true;
    const check_w: f32 = if (m.checks_last[level] or checked != null) line_h + 4 else 0;
    const icon_w: f32 = if (m.icons_last[level] or icon != null) line_h + 6 else 0;
    const right_w = if (submenu) line_h else if (right_text.len > 0) ui.textSize(right_text).x else 0;
    const natural = pad_x + check_w + icon_w + ui.textSize(text).x + 32 + right_w + pad_x;
    const rect = ui.placeSized(.fill, .auto, .{ .x = natural, .y = line_h + 2 * pad_y });
    const widget = ui.id(name);
    const r = ui.interact(widget, rect);

    // The pointer takes over from the keyboard as soon as it moves.
    if (r.hovered and !m.keyboard and m.highlight[level] != index) {
        m.highlight[level] = index;
        // Hovering an item closes a submenu opened from another one.
        if (!submenu) ui.popup_count = @min(ui.popup_count, level + 1);
    }
    const highlighted = m.highlight[level] == index;
    if (highlighted) ui.drawRect(.{ .rect = rect, .fill = colors.button_hovered, .radius = style.rounding });
    if (checked orelse false) {
        ui.painter().icon(.{ .builtin = .check }, .{ .x = rect.x + pad_x, .y = rect.y + pad_y, .w = line_h, .h = line_h }, colors.accent);
    }
    if (icon) |ic| ui.painter().icon(ic, .{ .x = rect.x + pad_x + check_w, .y = rect.y + pad_y, .w = line_h, .h = line_h }, colors.text);
    ui.drawText(.{ .x = rect.x + pad_x + check_w + icon_w, .y = rect.y + pad_y }, colors.text, text);
    if (submenu) {
        const s = line_h * 0.7;
        ui.painter().icon(.{ .builtin = .chevron_right }, .{ .x = rect.right() - pad_x - s, .y = rect.y + (rect.h - s) / 2, .w = s, .h = s }, colors.text_muted);
    } else if (right_text.len > 0) {
        ui.drawText(.{ .x = rect.right() - pad_x - right_w, .y = rect.y + pad_y }, colors.text_muted, right_text);
    }
    // A held menu's release over the row picks it, as a click would.
    const from = m.held_from;
    const moved = @abs(ui.input.mouse_pos.x - from.x) + @abs(ui.input.mouse_pos.y - from.y) >= held_slop;
    const released = m.held and moved and ui.input.mouse_released.count() > 0 and
        rect.contains(ui.input.mouse_pos) and ui.clipRect().contains(ui.input.mouse_pos) and ui.hovered_window == ui.current_window;
    return .{ .result = r, .rect = rect, .highlighted = highlighted, .index = index, .level = level, .released = released };
}

/// An item of the menu being described. Returns true when it is picked, and
/// then closes the menus.
pub fn menuItem(ui: *Ui, name: []const u8, options: ItemOptions) bool {
    ui.pushDisabled(options.disabled);
    defer ui.popDisabled();
    const r = row(ui, name, options.icon, options.checked, options.shortcut, false);
    const m = &ui.menu_state;
    if (options.tooltip.len > 0 or r.result.disabled) {
        ui.tooltipRich(r.result, .{ .body = options.tooltip, .placement = .beside });
    }
    ui.recordWidget(.menu_item, ui.id(name), name, r.rect, .{
        .value = if (options.checked) |c| (if (c) "true" else "false") else null,
        .hovered = r.result.hovered,
        .focused = r.highlighted,
    });
    const by_key = r.highlighted and m.activate[r.level];
    if (r.result.disabled) {
        if (by_key or r.released) ui.disabled_click_next = ui.disabledReason();
        return false;
    }
    if (r.result.clicked or by_key or r.released) {
        ui.closeAllPopups();
        m.bar_open = null;
        return true;
    }
    return false;
}

/// An item that opens a submenu beside it, by hovering, clicking or Right.
/// When it returns true, describe the submenu's items and call `endMenu`.
pub fn beginSubmenu(ui: *Ui, name: []const u8, options: SubmenuOptions) bool {
    ui.pushDisabled(options.disabled);
    const r = row(ui, name, options.icon, null, "", true);
    ui.popDisabled();
    const m = &ui.menu_state;
    const widget = ui.id(name);
    ui.recordWidget(.menu, widget, name, r.rect, .{ .hovered = r.result.hovered, .focused = r.highlighted });
    if (r.result.disabled) return false;
    const popup_name = std.fmt.allocPrint(ui.frameAllocator(), "{s}##submenu", .{Ui.visibleLabel(name)}) catch return false;
    const open = ui.isPopupOpen(popup_name);
    const by_key = r.highlighted and (m.activate[r.level] or m.open_sub[r.level]);
    // Hovering opens it when the pointer moves onto it, so Escape can
    // close it while the pointer rests there.
    const hover_open = r.result.hovered and r.highlighted and ui.mouse_delta.length() > 0;
    if (!open and (hover_open or r.result.clicked or by_key or r.released)) {
        overlay.openPopupBeside(ui, popup_name, r.rect);
        m.highlight[r.level + 1] = if (by_key) 0 else null;
        if (by_key) m.keyboard = true;
    }
    // Right was used here to open the submenu, not to move along the bar.
    if (by_key) m.open_sub[r.level] = false;
    return beginPopupMenu(ui, popup_name);
}

/// Starts a menu bar across the current layout. Describe menus with
/// `beginMenu`, then call `endMenuBar`.
pub fn beginMenuBar(ui: *Ui) void {
    const style = &ui.style;
    const m = &ui.menu_state;
    m.bar_request = m.bar_request_next;
    m.bar_request_next = null;
    // F10 opens the first menu; Alt+letter the menu starting with it.
    if (!ui.wantsKeyboard()) {
        for (ui.input.keyEvents()) |event| {
            if (event.key == .f10 and !event.modifiers.ctrl) {
                m.bar_request = if (m.bar_open != null) null else 0;
                if (m.bar_open != null) ui.closeAllPopups();
            } else if (event.modifiers.alt and !event.modifiers.ctrl) {
                const name = @tagName(event.key);
                if (name.len != 1) continue;
                for (m.bar_letters[0..m.bar_count_last], 0..) |letter, i| {
                    if (letter == std.ascii.toUpper(name[0])) m.bar_request = @intCast(i);
                }
            }
        }
    }
    ui.beginHorizontal(.{ .spacing = 0, .fill = style.colors.title, .padding = 2 });
    m.in_bar = true;
}

/// Ends the menu bar.
pub fn endMenuBar(ui: *Ui) void {
    const m = &ui.menu_state;
    ui.spacer(.fill);
    ui.endHorizontal();
    m.in_bar = false;
    m.bar_request = null;
}

/// A menu: a title in the menu bar, or (inside another menu) a submenu.
/// When it returns true, describe the items and call `endMenu`.
pub fn beginMenu(ui: *Ui, name: []const u8) bool {
    const m = &ui.menu_state;
    if (!m.in_bar or ui.popup_nesting > 0) return beginSubmenu(ui, name, .{});
    const style = &ui.style;
    const colors = &style.colors;
    const index = m.bar_count;
    m.bar_count += 1;
    const text = Ui.visibleLabel(name);
    if (index < max_bar and text.len > 0) m.bar_letters[index] = std.ascii.toUpper(text[0]);

    const size = ui.textSize(text);
    const rect = ui.place(.{ .x = size.x + style.frame_padding.x * 1.5, .y = size.y + style.frame_padding.y * 1.2 });
    const widget = ui.id(name);
    const r = ui.interact(widget, rect);
    const popup_name = std.fmt.allocPrint(ui.frameAllocator(), "{s}##menu", .{text}) catch return false;
    const open = ui.isPopupOpen(popup_name);

    var want_open = false;
    if (r.pressed) {
        if (open) {
            ui.closeAllPopups();
            m.bar_open = null;
        } else want_open = true;
    }
    // While a bar menu is open, hovering another title switches to it.
    if (r.hovered and m.bar_open != null and m.bar_open != index and !open) want_open = true;
    if (m.bar_request == index) {
        want_open = !open;
        m.keyboard = true;
    }
    if (want_open) {
        ui.openPopupAt(popup_name, rect);
        m.highlight[0] = if (m.bar_request == index) 0 else null;
        m.bar_open = index;
    }
    const is_open = open or want_open;
    if (is_open) m.bar_seen_open = true;
    if (is_open or r.hovered) ui.drawRect(.{ .rect = rect, .fill = if (is_open) colors.button_active else colors.button_hovered, .radius = style.rounding });
    ui.drawText(.{ .x = rect.x + (rect.w - size.x) / 2, .y = rect.y + (rect.h - size.y) / 2 }, colors.title_text, text);
    ui.recordWidget(.menu, widget, name, rect, .{ .hovered = r.hovered, .value = if (is_open) "open" else "closed" });
    if (!is_open) return false;
    // The bar's row is not where the popup's content goes.
    return beginPopupMenu(ui, popup_name);
}

// ---- command palette -----------------------------------------------------

/// A command the palette can run.
pub const Command = struct {
    label: []const u8,
    shortcut: []const u8 = "",
    /// Shown muted before the label, such as "Mesh".
    category: []const u8 = "",
    disabled: ?[]const u8 = null,
    tooltip: []const u8 = "",
    /// Shown muted after the label, such as an identifier ("mesh.bevel").
    detail: []const u8 = "",
};

/// Options for `commandPalette`.
pub const PaletteOptions = struct {
    width: f32 = 560,
    /// Rows shown before the list scrolls.
    rows: u32 = 12,
    hint: []const u8 = "Search commands",
    /// The app's own ranking instead of `fuzzyScore` on the labels: how
    /// well command `index` matches `query` (higher is better), or null to
    /// leave it out. Ties keep the order given.
    score: ?*const fn (query: []const u8, index: usize) ?f32 = null,
};

/// The palette's query and highlight.
pub const Palette = struct {
    query: [128]u8 = undefined,
    len: usize = 0,
    highlight: usize = 0,
    was_open: bool = false,
    last_len: usize = 0,
    /// Put the focus in the search field (inside the popup's ID scope).
    focus_query: bool = false,
};

/// How well `query` matches `text`: null if its letters don't all appear in
/// order. Higher is better: letters at word starts and runs of letters
/// count most, an early first match a little. Case doesn't matter. `marks`,
/// if given, receives the matched byte positions.
pub fn fuzzyScore(query: []const u8, text: []const u8, marks: ?*std.bit_set.IntegerBitSet(256)) ?f32 {
    if (query.len == 0) return 0;
    var score: f32 = 0;
    var qi: usize = 0;
    var last: ?usize = null;
    var first: ?usize = null;
    for (text, 0..) |c, i| {
        if (qi == query.len) break;
        if (query[qi] == ' ') {
            qi += 1;
            if (qi == query.len) break;
        }
        if (std.ascii.toLower(c) != std.ascii.toLower(query[qi])) continue;
        score += 1;
        const word_start = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]) or (std.ascii.isUpper(c) and std.ascii.isLower(text[i - 1]));
        if (word_start) score += 3;
        if (last) |l| {
            if (l + 1 == i) score += 5 else score -= @min(2, @as(f32, @floatFromInt(i - l - 1)) * 0.05);
        }
        if (first == null) first = i;
        if (marks) |mk| if (i < 256) mk.set(i);
        last = i;
        qi += 1;
    }
    if (qi < query.len) return null;
    score -= @as(f32, @floatFromInt(first orelse 0)) * 0.02;
    // A shorter text with the same match is a little more likely the one.
    score -= @as(f32, @floatFromInt(text.len)) * 0.002;
    return score;
}

/// A search box over `commands`, centered near the top of the window,
/// while `open.*` is true: type to filter (fuzzy), Up / Down to choose,
/// Enter or a click to run, Escape or a click outside to close. Returns the
/// index of the command picked this frame, and closes.
pub fn commandPalette(ui: *Ui, name: []const u8, open: *bool, commands: []const Command, options: PaletteOptions) ?usize {
    const st = &ui.menu_state.palette;
    ui.pushId(name);
    defer ui.popId();
    const popup = "##palette";
    if (open.* and !ui.isPopupOpen(popup)) {
        if (st.was_open) {
            // Closed by Escape or a click outside.
            open.* = false;
            st.was_open = false;
            return null;
        }
        const w = @min(options.width, ui.width - 16);
        ui.openPopupAt(popup, .{ .x = (ui.width - w) / 2, .y = ui.height * 0.1 });
        st.len = 0;
        st.highlight = 0;
        st.was_open = true;
        st.focus_query = true;
    }
    if (!open.*) {
        if (st.was_open) ui.closeAllPopups();
        st.was_open = false;
        return null;
    }
    if (!ui.beginPopup(popup, .{ .min_width = @min(options.width, ui.width - 16) })) return null;
    defer ui.endPopup();
    if (st.focus_query) {
        st.focus_query = false;
        ui.setFocus(ui.id("##query"));
        ui.focus_visible = false;
    }

    // Rank: best score first, then the order given.
    const Ranked = struct { index: u32, score: f32 };
    const query = st.query[0..st.len];
    var ranked: std.ArrayList(Ranked) = .empty;
    for (commands, 0..) |c, i| {
        const in_label = if (options.score) |f| f(query, i) else fuzzyScore(query, c.label, null);
        const s = in_label orelse continue;
        ranked.append(ui.frameAllocator(), .{ .index = @intCast(i), .score = s }) catch |err| {
            ui.fail(err);
            return null;
        };
    }
    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn less(_: void, a: Ranked, b: Ranked) bool {
            return if (a.score != b.score) a.score > b.score else a.index < b.index;
        }
    }.less);
    if (st.len != st.last_len) st.highlight = 0;
    st.last_len = st.len;

    var picked: ?usize = null;
    const n = ranked.items.len;
    for (ui.input.keyEvents()) |event| switch (event.key) {
        .down => if (n > 0) {
            st.highlight = (st.highlight + 1) % n;
        },
        .up => if (n > 0) {
            st.highlight = (st.highlight + n - 1) % n;
        },
        .page_down => st.highlight = @min(st.highlight + options.rows, n -| 1),
        .page_up => st.highlight -|= options.rows,
        else => {},
    };
    st.highlight = @min(st.highlight, n -| 1);

    // Escape closes the palette at once, before its field would take it to
    // undo the typing.
    const escape = ui.input.keys_pressed.contains(.escape);
    const query_result = ui.textInput("##query", &st.query, &st.len, .{ .width = .fill, .hint = options.hint });
    if (query_result.submitted and n > 0) {
        const c = commands[ranked.items[st.highlight].index];
        if (c.disabled) |why| {
            ui.disabled_click_next = why;
            st.focus_query = true;
        } else picked = ranked.items[st.highlight].index;
    }
    if (escape) {
        ui.input.keys_pressed.remove(.escape);
        open.* = false;
    }

    const style = &ui.style;
    const colors = &style.colors;
    const line_h = ui.textSize("").y;
    const pad_y = style.frame_padding.y * 0.6;
    const row_h = line_h + 2 * pad_y;
    const list_h = row_h * @as(f32, @floatFromInt(@max(1, @min(n, options.rows))));
    // Only the rows in view are described (a catalog has hundreds); the
    // arrows scroll the highlight into view here, since a row out of view
    // isn't there to do it.
    const results_id = ui.id("##results");
    var first: usize = 0;
    if (ui.scroll_states.getPtr(results_id)) |sc| {
        if (ui.input.keyEvents().len > 0) {
            const top = @as(f32, @floatFromInt(st.highlight)) * row_h;
            if (top < sc.scroll) sc.scroll = top;
            if (top + row_h > sc.scroll + list_h) sc.scroll = top + row_h - list_h;
        }
        sc.scroll = std.math.clamp(sc.scroll, 0, @max(0, @as(f32, @floatFromInt(n)) * row_h + 4 - list_h - 4));
        first = @min(n, @as(usize, @intFromFloat(@max(0, @floor((sc.scroll - 2) / row_h)))));
    }
    const shown_rows = @min(n - first, options.rows + 2);
    ui.beginScrollArea("##results", .{ .height = .{ .fixed = list_h + 4 }, .width = .fill, .frame = false, .padding = 2, .spacing = 0 });
    if (first > 0) ui.spacer(.{ .fixed = @as(f32, @floatFromInt(first)) * row_h });
    for (ranked.items[first..][0..shown_rows], first..) |rk, i| {
        const c = commands[rk.index];
        ui.pushIdInt(rk.index);
        defer ui.popId();
        ui.pushDisabled(c.disabled);
        defer ui.popDisabled();
        const rect = ui.placeSized(.fill, .{ .fixed = row_h }, .{});
        var r = ui.interact(ui.id("##command"), rect);
        if (r.hovered and ui.mouse_delta.length() > 0) st.highlight = i;
        const lit = st.highlight == i;
        if (lit) ui.drawRect(.{ .rect = rect, .fill = colors.button_hovered, .radius = style.rounding });
        var x = rect.x + style.frame_padding.x * 0.5;
        const y = rect.y + pad_y;
        if (c.category.len > 0) {
            ui.drawText(.{ .x = x, .y = y }, colors.text_muted, c.category);
            x += ui.textSize(c.category).x;
            ui.drawText(.{ .x = x, .y = y }, colors.text_muted, ": ");
            x += ui.textSize(": ").x;
        }
        // (the matched letters marked by the fuzzy match; an app's own
        // ranking may have matched elsewhere)
        if (options.score == null) drawMarked(ui, .{ .x = x, .y = y }, c.label, query) else ui.drawText(.{ .x = x, .y = y }, colors.text, c.label);
        if (c.detail.len > 0) ui.drawText(.{ .x = x + ui.textSize(c.label).x + 12, .y = y }, colors.text_muted, c.detail);
        if (c.shortcut.len > 0) {
            const sw = ui.textSize(c.shortcut).x;
            ui.drawText(.{ .x = rect.right() - style.frame_padding.x * 0.5 - sw, .y = y }, colors.text_muted, c.shortcut);
        }
        if (c.tooltip.len > 0 or r.disabled) ui.tooltipRich(r, .{ .body = c.tooltip, .placement = .beside });
        ui.recordWidget(.command, ui.id("##command"), c.label, rect, .{ .hovered = r.hovered, .focused = lit });
        if (r.clicked) picked = rk.index;
        r.rect = rect;
    }
    const after = n - first - shown_rows;
    if (after > 0) ui.spacer(.{ .fixed = @as(f32, @floatFromInt(after)) * row_h });
    if (n == 0) ui.label("No command matches.", .{ .color = colors.text_muted });
    ui.endScrollArea();

    if (picked != null or !open.*) {
        open.* = false;
        st.was_open = false;
        ui.closeAllPopups();
    }
    return picked;
}

/// Draws `text` with the letters `query` matched in the accent color.
fn drawMarked(ui: *Ui, pos: Vec2, text: []const u8, query: []const u8) void {
    var marks: std.bit_set.IntegerBitSet(256) = .empty;
    _ = fuzzyScore(query, text, &marks);
    if (marks.count() == 0) return ui.drawText(pos, ui.style.colors.text, text);
    var x = pos.x;
    var i: usize = 0;
    while (i < text.len) {
        const on = i < 256 and marks.isSet(i);
        var j = i + 1;
        while (j < text.len and (j < 256 and marks.isSet(j)) == on) j += 1;
        const part = text[i..j];
        ui.drawText(.{ .x = x, .y = pos.y }, if (on) ui.style.colors.accent else ui.style.colors.text, part);
        x += ui.textSize(part).x;
        i = j;
    }
}

// ---- shortcut field --------------------------------------------------------

/// Options for `shortcutField`.
pub const ShortcutOptions = struct {
    width: layout.Size = .auto,
    /// Shown when there is no shortcut.
    none: []const u8 = "None",
};

/// A field showing a shortcut. Click it (or Enter) and press the new keys;
/// Escape keeps the old one, Backspace or Delete clears it. The new one
/// arrives with `changed` and `committed`.
pub fn shortcutField(ui: *Ui, name: []const u8, shortcut: *?input_mod.Shortcut, options: ShortcutOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    const text = Ui.visibleLabel(name);
    const text_w = if (text.len > 0) ui.textSize(text).x else 0;
    const gap: f32 = if (text.len > 0) style.item_spacing.x else 0;
    const line_h = ui.textSize("").y;
    const height = line_h + style.frame_padding.y * 2;
    const rect = ui.placeSized(options.width, .auto, .{ .x = 160 + gap + text_w, .y = height });
    const field: Rect = .{ .x = rect.x, .y = rect.y, .w = @max(0, rect.w - gap - text_w), .h = height };
    const widget = ui.id(name);
    var result = ui.interact(widget, field);
    ui.focusable(widget, &result);
    const m = &ui.menu_state;
    var capturing = m.capturing == widget;
    if (capturing and !result.focused) {
        // Focus went elsewhere: stop waiting, keep the old one.
        m.capturing = .none;
        capturing = false;
        result.cancelled = true;
    }
    if (capturing) {
        for (ui.input.keyEvents()) |event| {
            switch (event.key) {
                .escape => {
                    result.cancelled = true;
                    ui.input.keys_pressed.remove(.escape);
                },
                .backspace, .delete => if (!event.modifiers.ctrl and !event.modifiers.alt) {
                    if (shortcut.* != null) {
                        shortcut.* = null;
                        result.changed = true;
                        result.committed = true;
                    } else result.cancelled = true;
                } else {
                    shortcut.* = .{ .key = event.key, .modifiers = event.modifiers };
                    result.changed = true;
                    result.committed = true;
                },
                else => {
                    shortcut.* = .{ .key = event.key, .modifiers = event.modifiers };
                    result.changed = true;
                    result.committed = true;
                },
            }
            m.capturing = .none;
            capturing = false;
            break;
        }
    } else if (!result.disabled and (result.clicked or (result.focused and ui.input.keys_pressed.contains(.enter)))) {
        m.capturing = widget;
        capturing = true;
        result.started = true;
    }

    ui.drawRect(.{
        .rect = field,
        .fill = if (capturing) colors.input else if (result.hovered) colors.button_hovered else colors.button,
        .border = if (capturing) colors.accent else colors.border,
        .border_width = style.border_width,
        .radius = style.rounding,
    });
    var buffer: [48]u8 = undefined;
    const shown = if (capturing) "Press a key..." else if (shortcut.*) |s| s.format(&buffer) else options.none;
    const shown_w = ui.textSize(shown).x;
    ui.drawText(.{ .x = field.x + (field.w - shown_w) / 2, .y = field.y + style.frame_padding.y }, if (capturing or shortcut.* == null) colors.text_muted else colors.text, shown);
    if (text.len > 0) ui.drawText(.{ .x = field.right() + gap, .y = rect.y + style.frame_padding.y }, colors.text, text);
    ui.drawFocusRing(widget, field);
    ui.recordWidget(.shortcut, widget, name, field, .{ .value = shown, .hovered = result.hovered, .focused = result.focused });
    result.rect = rect;
    return result;
}

test "fuzzy matching prefers word starts and runs" {
    try std.testing.expect(fuzzyScore("sav", "Save As...", null) != null);
    try std.testing.expect(fuzzyScore("xyz", "Save", null) == null);
    const word = fuzzyScore("ls", "Loop Cut and Slide", null).?;
    const middle = fuzzyScore("ls", "Fills", null).?;
    try std.testing.expect(word > middle);
    const run = fuzzyScore("save", "Save", null).?;
    const spread = fuzzyScore("save", "Select All Vertices Evenly", null).?;
    try std.testing.expect(run > spread);
    var marks: std.bit_set.IntegerBitSet(256) = .empty;
    _ = fuzzyScore("sa", "Save", &marks);
    try std.testing.expect(marks.isSet(0) and marks.isSet(1) and !marks.isSet(2));
}
