//! Floating windows: title bar, dragging, collapsing, closing, resizing,
//! scrolling and z-order.
//!
//! Each window records into its own draw list. `Ui.endFrame` composes them
//! back to front, so the window order is independent of call order.

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const ui_mod = @import("ui.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;
const record = @import("record.zig");
const icons = @import("icons.zig");
const decor = @import("decor.zig");

/// What a detached window's title bar or grip asks of its OS window.
pub const ViewportRequest = union(enum) {
    none,
    move,
    resize: decor.Edges,
};

/// What a window remembers between frames.
pub const State = struct {
    id: Id,
    /// Outer rect when expanded.
    rect: Rect,
    collapsed: bool = false,
    /// How far the content is scrolled down.
    scroll: f32 = 0,
    /// Height of the content last frame, padding included.
    content_height: f32 = 0,
    list: draw.DrawList,
    /// The frame this window was last shown in (0 once it closed).
    last_frame: u64 = 0,
    /// The frame it was last described in, closed or not.
    described_frame: u64 = 0,
    /// The open flag the app passed, checked when the window ends.
    open_flag: ?*bool = null,
    title_height: f32 = 0,
    /// A popup: no title bar, always above ordinary windows.
    popup: bool = false,
    /// Not drawn this frame, because its size isn't known yet.
    hidden: bool = false,
    /// A modal dialog: drawn over a dimmed window, and takes the pointer
    /// everywhere.
    dialog: bool = false,
    /// Shown in an OS window of its own (`WindowOptions.detached`).
    detached: bool = false,
    /// The OS window this belongs to: its own ID when detached, the
    /// opener's for a popup, `.none` for the main one.
    viewport: Id = .none,
    /// The detached window's size, as its OS window reports it.
    os_size: Vec2 = .{},
    /// Where it was in the main window before it was detached.
    attached_rect: Rect = .{},
    request: ViewportRequest = .none,
    close_requested: bool = false,
    /// The composed viewport: the window and its popups.
    out: draw.DrawList,
    title: [64]u8 = undefined,
    title_len: usize = 0,

    // Saved by `beginWindow`, restored by `endWindow`.
    saved_list: *draw.DrawList = undefined,
    saved_window: ?*State = null,
    saved_clip_depth: usize = 0,
    saved_record_parent: ?u32 = null,
    saved_scope: Id = .none,
    grip: ?Rect = null,

    /// The rect as it appears: just the title bar when collapsed.
    pub fn visibleRect(self: *const State) Rect {
        var r = self.rect;
        if (self.collapsed) r.h = self.title_height;
        return r;
    }
};

/// Options for `Ui.beginWindow`.
pub const WindowOptions = struct {
    /// Where the window first appears. Later the user decides. Defaults to
    /// a cascade.
    position: ?Vec2 = null,
    /// The first size, in logical units.
    size: Vec2 = .{ .x = 320, .y = 260 },
    /// Smallest size the user can drag it to.
    min_size: Vec2 = .{ .x = 140, .y = 80 },
    /// Shows a close button that sets this to false. While false, the window
    /// is not shown and `beginWindow` returns false.
    open: ?*bool = null,
    movable: bool = true,
    resizable: bool = true,
    collapsible: bool = true,
    /// Show it in an OS window of its own: an area on another monitor.
    /// The backend creates that window from `Ui.viewports`; dragging the
    /// title bar or grip asks the system to move or resize it. Set back to
    /// false to bring it into the main window.
    detached: bool = false,
};

/// Finds the frontmost window under the mouse and raises it on click.
/// Called by `Ui.beginFrame`.
pub fn beginFrame(ui: *Ui) void {
    ui.hovered_window = windowAt(ui, ui.input.mouse_pos);
    ui.pressed_window = null;
    if (ui.input.mouse_pressed.contains(.left) and ui.active == .none) {
        ui.pressed_window = windowAt(ui, ui.input.press_pos.get(.left));
        if (ui.pressed_window) |w| raise(ui, w);
    }
}

/// After a frame: popups closed during it (closePopup, a menu item, a click
/// outside) are not shown any more, so next frame's hit test leaves them out.
/// Called by `Ui.endFrame`.
pub fn forgetClosed(ui: *Ui) void {
    for (ui.window_order.items) |w| {
        if (!w.popup or w.last_frame != ui.frame_index) continue;
        const still = for (ui.popups[0..ui.popup_count]) |p| {
            if (p.id == w.id) break true;
        } else false;
        if (!still) w.last_frame = 0;
    }
}

/// Frees popups and dialogs not described for a while: each is placed
/// afresh when it opens, so nothing is lost, and a context menu per row
/// doesn't leave a window behind per row. Ordinary windows keep their place
/// and size for when they open again, so they stay. Called by `Ui.endFrame`.
pub fn prune(ui: *Ui) void {
    const idle_frames = 300;
    if (ui.frame_index % 64 != 0) return;
    var i: usize = 0;
    while (i < ui.window_order.items.len) {
        const w = ui.window_order.items[i];
        const transient = (w.popup or w.dialog) and !w.detached;
        if (!transient or w.described_frame + idle_frames > ui.frame_index or ui.pressed_window == w or ui.hovered_window == w) {
            i += 1;
            continue;
        }
        _ = ui.window_order.orderedRemove(i);
        _ = ui.windows.remove(w.id);
        _ = ui.measures.remove(w.id);
        w.list.deinit();
        w.out.deinit();
        ui.allocator.destroy(w);
    }
}

/// Whether this frame's left press landed on a window that was shown last
/// frame but not described in this one (closed in between, or no longer
/// described): nothing took it, so it is kept for the next frame.
pub fn pressMissed(ui: *const Ui) bool {
    const w = ui.pressed_window orelse return false;
    return w.described_frame != ui.frame_index;
}

/// Returns the frontmost window shown last frame that contains `pos`.
fn windowAt(ui: *const Ui, pos: Vec2) ?*State {
    var i = ui.window_order.items.len;
    while (i > 0) {
        i -= 1;
        const w = ui.window_order.items[i];
        if (w.last_frame + 1 != ui.frame_index) continue;
        // Only windows in the OS window the pointer is in.
        if (w.viewport != ui.input.viewport) continue;
        if (w.visibleRect().contains(pos)) return w;
        // A modal dialog in front blocks everything behind it.
        if (w.dialog) return w;
    }
    return null;
}

/// Whether `pos` is over a window or popup shown in the last frame (or a
/// modal dialog, which blocks the rest). For a host routing an event that
/// came after the last frame: `Ui.hovered_window` is where the pointer was
/// then.
pub fn shownAt(ui: *const Ui, pos: Vec2) bool {
    var i = ui.window_order.items.len;
    while (i > 0) {
        i -= 1;
        const w = ui.window_order.items[i];
        if (w.last_frame != ui.frame_index or w.hidden) continue;
        if (w.viewport != ui.input.viewport) continue;
        if (w.visibleRect().contains(pos)) return true;
        if (w.dialog) return true;
    }
    return false;
}

/// Moves `w` to the front.
pub fn raise(ui: *Ui, w: *State) void {
    const items = ui.window_order.items;
    const index = std.mem.indexOfScalar(*State, items, w) orelse return;
    std.mem.copyForwards(*State, items[index .. items.len - 1], items[index + 1 ..]);
    items[items.len - 1] = w;
}

/// True if `w` is the frontmost window shown last frame.
fn isFrontmost(ui: *const Ui, w: *const State) bool {
    var i = ui.window_order.items.len;
    while (i > 0) {
        i -= 1;
        const other = ui.window_order.items[i];
        if (other.popup) continue;
        if (other.last_frame + 1 >= ui.frame_index) return other == w;
    }
    return false;
}

/// Returns the state stored for `window_id`, creating it on first use.
pub fn getOrCreate(ui: *Ui, window_id: Id, options: WindowOptions) std.mem.Allocator.Error!*State {
    if (ui.windows.get(window_id)) |w| return w;
    try ui.window_order.ensureUnusedCapacity(ui.allocator, 1);
    try ui.windows.ensureUnusedCapacity(ui.allocator, 1);
    const w = try ui.allocator.create(State);
    const cascade: f32 = @floatFromInt(ui.window_order.items.len % 8);
    w.* = .{
        .id = window_id,
        .rect = .{
            .x = if (options.position) |p| p.x else 40 + cascade * 32,
            .y = if (options.position) |p| p.y else 40 + cascade * 32,
            .w = options.size.x,
            .h = options.size.y,
        },
        .list = .init(ui.allocator),
        .out = .init(ui.allocator),
    };
    ui.windows.putAssumeCapacity(window_id, w);
    // Below the popups and dialogs (which raise themselves when shown), so
    // a window made while a dialog is open can't be hit in front of it.
    const below = for (ui.window_order.items, 0..) |o, i| {
        if (o.popup or o.dialog) break i;
    } else ui.window_order.items.len;
    ui.window_order.insertAssumeCapacity(below, w);
    return w;
}

/// Keeps enough of the title bar on screen to grab it again.
fn clampToViewport(ui: *const Ui, w: *State) void {
    const keep = 48;
    w.rect.x = std.math.clamp(w.rect.x, keep - w.rect.w, @max(0, ui.width - keep));
    w.rect.y = std.math.clamp(w.rect.y, 0, @max(0, ui.height - w.title_height));
}

/// Starts a window. When this returns true, describe the contents and call
/// `endWindow`. When it returns false (collapsed or closed), don't.
///
///     if (ui.beginWindow("Tools", .{})) {
///         defer ui.endWindow();
///         ui.label("Inside", .{});
///     }
///
/// The title is also the ID; use `##` to give two windows the same title.
pub fn beginWindow(ui: *Ui, title: []const u8, options: WindowOptions) bool {
    if (options.open) |open| if (!open.*) return false;
    std.debug.assert(ui.layout_depth < Ui.max_layout_depth);

    const window_id = ui.id(title);
    const w = getOrCreate(ui, window_id, options) catch |err| {
        ui.fail(err);
        return false;
    };
    std.debug.assert(w.last_frame != ui.frame_index); // same window begun twice
    w.last_frame = ui.frame_index;
    w.described_frame = ui.frame_index;
    w.open_flag = options.open;

    const style = &ui.style;
    const colors = &style.colors;
    w.title_height = ui.textSize("").y + 2 * style.frame_padding.y;
    w.request = .none;
    if (options.detached != w.detached) {
        if (options.detached) {
            w.attached_rect = w.rect;
            w.os_size = .{ .x = w.rect.w, .y = w.rect.h };
        } else {
            // Back where it was, at the size it had.
            w.rect = w.attached_rect;
        }
        w.detached = options.detached;
    }
    w.viewport = if (w.detached) w.id else .none;
    if (w.close_requested) {
        w.close_requested = false;
        if (options.open) |open| open.* = false;
    }
    if (options.open) |open| if (!open.*) {
        w.last_frame = 0;
        return false;
    };
    if (w.detached) {
        // The OS window is the window: it fills it, from its corner.
        const n = @import("font.zig").fitUtf8(title, w.title.len);
        @memcpy(w.title[0..n], title[0..n]);
        w.title_len = n;
        w.collapsed = false;
        w.rect = .{ .w = @max(w.os_size.x, options.min_size.x), .h = @max(w.os_size.y, options.min_size.y) };
    }
    w.rect.w = @max(w.rect.w, options.min_size.x);
    w.rect.h = @max(w.rect.h, options.min_size.y, w.title_height);
    if (!w.detached) clampToViewport(ui, w);

    w.saved_list = ui.list;
    w.saved_window = ui.current_window;
    w.saved_clip_depth = ui.clip_depth;
    w.grip = null;
    w.list.clear();
    ui.list = &w.list;
    ui.current_window = w;
    ui.pushIdValue(window_id);
    ui.pushClipAbsolute(if (w.detached) w.rect else Rect{ .w = ui.width, .h = ui.height });
    // A detached window is its own Tab scope: the keyboard stays in the
    // OS window that has it.
    w.saved_scope = if (w.detached) ui.pushFocusScope(w.id) else ui.current_scope;

    const bar: Rect = .{ .x = w.rect.x, .y = w.rect.y, .w = w.rect.w, .h = w.title_height };
    w.saved_record_parent = record.enterContainer(ui, .window, window_id, title, bar, .{
        .value = if (w.collapsed) "collapsed" else "open",
        .hovered = ui.hovered_window == w,
    });
    titleBar(ui, w, title, options);
    if (options.open) |open| {
        if (!open.*) {
            // Closed this frame: draw nothing, and stop blocking the mouse.
            w.last_frame = 0;
            restore(ui, w);
            return false;
        }
    }

    const r = w.visibleRect();
    const radius: f32 = if (w.detached) 0 else style.window_rounding;
    const title_fill = if (w.detached or isFrontmost(ui, w)) colors.title_active else colors.title;
    if (!w.detached) ui.drawShadow(r, radius, colors.window);
    ui.drawRect(.{ .rect = r, .fill = colors.window, .radius = radius });
    ui.drawRect(.{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = w.title_height }, .fill = title_fill, .radius = radius });
    if (!w.collapsed) {
        // Square off the title bar's lower corners.
        ui.drawRect(.{ .rect = .{ .x = r.x, .y = r.y + w.title_height / 2, .w = r.w, .h = w.title_height / 2 }, .fill = title_fill });
    }
    ui.drawRect(.{ .rect = r, .border = colors.border, .border_width = style.border_width, .radius = radius });
    drawTitleBar(ui, w, title, options);

    if (w.collapsed) {
        restore(ui, w);
        return false;
    }

    const body: Rect = .{
        .x = r.x,
        .y = r.y + w.title_height,
        .w = r.w,
        .h = r.h - w.title_height,
    };
    if (options.resizable) {
        w.grip = resizeGrip(ui, w, options);
    }
    const max_scroll = @max(0, w.content_height - body.h);
    w.scroll = std.math.clamp(w.scroll, 0, max_scroll);
    const content = scrollbar(ui, &w.scroll, w.content_height, body);

    ui.pushClip(content);
    const p = style.window_padding;
    ui.layouts[ui.layout_depth] = .{
        .id = window_id,
        .layout = .init(.{
            .origin = .{ .x = content.x + p, .y = content.y + p - w.scroll },
            .spacing = style.item_spacing,
            .main_extent = @max(0, content.h - 2 * p),
            .cross_extent = @max(0, content.w - 2 * p),
            .previous = ui.measures.get(window_id) orelse .{},
        }),
    };
    ui.layout_depth += 1;
    return true;
}

/// Ends the window started by the matching successful `beginWindow`.
pub fn endWindow(ui: *Ui) void {
    const w = ui.current_window orelse unreachable; // endWindow without beginWindow
    std.debug.assert(ui.current().id == w.id); // a group inside the window was not ended
    const measure = ui.current().layout.finish();
    ui.layout_depth -= 1;
    ui.storeMeasure(w.id, measure);
    w.content_height = measure.content.y + 2 * ui.style.window_padding;
    // Closed from inside (a button set its open flag): not there next frame.
    if (w.open_flag) |o| if (!o.*) {
        w.last_frame = 0;
    };
    ui.popClip();
    // The wheel goes to the innermost scrollable area under the mouse. Those
    // inside this window have ended already, so if it is still unclaimed, it
    // is this window's.
    if (ui.hovered_window == w) takeWheel(ui, &w.scroll, w.content_height - w.visibleRect().h + w.title_height);

    if (w.grip) |grip| {
        const color = ui.style.colors.resize_grip;
        for (0..3) |i| {
            const fi: f32 = @floatFromInt(i);
            const dot = 2;
            ui.drawRect(.{
                .rect = .{ .x = grip.right() - 5 - fi * 4, .y = grip.bottom() - 5 - (2 - fi) * 4, .w = dot, .h = dot },
                .fill = color,
            });
            if (i > 0) ui.drawRect(.{
                .rect = .{ .x = grip.right() - 5, .y = grip.bottom() - 5 - fi * 4, .w = dot, .h = dot },
                .fill = color,
            });
        }
    }
    restore(ui, w);
}

/// Undoes what `beginWindow` set up for describing `w`.
pub fn restore(ui: *Ui, w: *State) void {
    if (w.detached) ui.popFocusScope(w.saved_scope);
    record.leaveContainer(ui, w.saved_record_parent);
    ui.popId();
    while (ui.clip_depth > w.saved_clip_depth) ui.popClip();
    ui.list = w.saved_list;
    ui.current_window = w.saved_window;
}

fn buttonRect(w: *const State, slot: f32, from_right: bool) Rect {
    const size = w.title_height;
    const x = if (from_right) w.rect.right() - size * (slot + 1) else w.rect.x + size * slot;
    return .{ .x = x, .y = w.rect.y, .w = size, .h = size };
}

/// Handles title bar input. Buttons are checked before the bar itself, so
/// they win.
fn titleBar(ui: *Ui, w: *State, title: []const u8, options: WindowOptions) void {
    _ = title;
    if (options.open) |open| {
        const close = ui.interact(ui.id("#close"), buttonRect(w, 0, true));
        ui.recordWidget(.window_button, ui.id("#close"), "Close", close.rect, .{ .hovered = close.hovered });
        if (close.clicked) open.* = false;
    }
    if (options.collapsible and !w.detached) {
        const collapse = ui.interact(ui.id("#collapse"), buttonRect(w, 0, false));
        ui.recordWidget(.window_button, ui.id("#collapse"), "Collapse", collapse.rect, .{ .hovered = collapse.hovered, .value = if (w.collapsed) "collapsed" else "open" });
        if (collapse.clicked) w.collapsed = !w.collapsed;
    }
    const bar: Rect = .{ .x = w.rect.x, .y = w.rect.y, .w = w.rect.w, .h = w.title_height };
    const drag = ui.interact(ui.id("#title"), bar);
    if (w.detached) {
        // The system moves an OS window.
        if (drag.pressed) w.request = .move;
        return;
    }
    if (options.movable and drag.held) {
        const mouse = ui.input.mouse_pos;
        if (drag.pressed) {
            const at = ui.input.press_pos.get(.left);
            ui.drag_offset = .{ .x = at.x - w.rect.x, .y = at.y - w.rect.y };
        }
        w.rect.x = mouse.x - ui.drag_offset.x;
        w.rect.y = mouse.y - ui.drag_offset.y;
        clampToViewport(ui, w);
    }
}

fn drawTitleBar(ui: *Ui, w: *State, title: []const u8, options: WindowOptions) void {
    const colors = ui.style.colors;
    const text_h = ui.textSize("").y;
    const text_y = w.rect.y + (w.title_height - text_h) / 2;

    var left = w.rect.x + ui.style.frame_padding.x;
    if (options.collapsible and !w.detached) {
        const button = buttonRect(w, 0, false);
        const hovered = ui.hot == ui.id("#collapse");
        const size = text_h * 0.8;
        const icon: icons.Icon = .{ .builtin = if (w.collapsed) .chevron_right else .chevron_down };
        ui.painter().icon(icon, .{ .x = button.x + (button.w - size) / 2, .y = button.y + (button.h - size) / 2, .w = size, .h = size }, if (hovered) colors.title_text else colors.text_muted);
        left = button.right();
    }
    var right = w.rect.right() - ui.style.frame_padding.x;
    if (options.open != null) {
        const button = buttonRect(w, 0, true);
        const hovered = ui.hot == ui.id("#close");
        if (hovered) ui.drawRect(.{ .rect = button.inset(4), .fill = colors.button_hovered, .radius = ui.style.rounding });
        const size = text_h * 0.75;
        ui.painter().icon(.{ .builtin = .close }, .{ .x = button.x + (button.w - size) / 2, .y = button.y + (button.h - size) / 2, .w = size, .h = size }, if (hovered) colors.title_text else colors.text_muted);
        right = button.x;
    }

    ui.pushClip(.{ .x = left, .y = w.rect.y, .w = @max(0, right - left), .h = w.title_height });
    ui.drawText(.{ .x = left, .y = text_y }, colors.title_text, Ui.visibleLabel(title));
    ui.popClip();
}

fn resizeGrip(ui: *Ui, w: *State, options: WindowOptions) Rect {
    const size = ui.style.resize_grip_size;
    const grip: Rect = .{ .x = w.rect.right() - size, .y = w.rect.bottom() - size, .w = size, .h = size };
    const drag = ui.interact(ui.id("#resize"), grip);
    if (drag.hovered or drag.held) ui.cursor = .resize_nwse;
    if (w.detached) {
        if (drag.pressed) w.request = .{ .resize = .{ .bottom = true, .right = true } };
        return grip;
    }
    if (drag.held) {
        const mouse = ui.input.mouse_pos;
        if (drag.pressed) {
            const at = ui.input.press_pos.get(.left);
            ui.drag_offset = .{ .x = at.x - w.rect.right(), .y = at.y - w.rect.bottom() };
        }
        w.rect.w = @max(options.min_size.x, mouse.x - ui.drag_offset.x - w.rect.x);
        w.rect.h = @max(options.min_size.y, w.title_height, mouse.y - ui.drag_offset.y - w.rect.y);
    }
    return grip;
}

/// Scrolls by this frame's mouse wheel, if no inner area took it and there is
/// anything to scroll. `max_scroll` is how far the content can move.
pub fn takeWheel(ui: *Ui, scroll: *f32, max_scroll: f32) void {
    if (ui.input.scroll.y == 0 or max_scroll <= 0) return;
    const before = scroll.*;
    scroll.* = std.math.clamp(scroll.* - ui.input.scroll.y * ui.style.scroll_step, 0, max_scroll);
    ui.input.scroll.y = 0; // claimed
    if (scroll.* != before) ui.redraw_requested = true;
}

/// Draws a vertical scrollbar in `body` when content of `content_height`
/// doesn't fit, and lets its thumb be dragged. Returns the area left for the
/// content. IDs are relative to the current ID scope.
pub fn scrollbar(ui: *Ui, scroll: *f32, content_height: f32, body: Rect) Rect {
    const style = &ui.style;
    const max_scroll = @max(0, content_height - body.h);
    if (max_scroll == 0) return body;

    const bar_w = style.scrollbar_width;
    const track: Rect = .{ .x = body.right() - bar_w - 2, .y = body.y + 2, .w = bar_w, .h = @max(0, body.h - 4 - 16) };
    const visible = body.h / content_height;
    const thumb_h = @max(24, track.h * visible);
    const travel = @max(1, track.h - thumb_h);
    const thumb: Rect = .{
        .x = track.x,
        .y = track.y + travel * (scroll.* / max_scroll),
        .w = bar_w,
        .h = thumb_h,
    };

    const drag = ui.interact(ui.id("#scroll"), thumb);
    if (drag.held) {
        const mouse = ui.input.mouse_pos;
        if (drag.pressed) ui.drag_offset = .{ .y = ui.input.press_pos.get(.left).y - thumb.y };
        const t = (mouse.y - ui.drag_offset.y - track.y) / travel;
        scroll.* = std.math.clamp(t, 0, 1) * max_scroll;
    }

    const colors = style.colors;
    ui.drawRect(.{
        .rect = thumb,
        .fill = if (drag.held or drag.hovered) colors.scrollbar_hovered else colors.scrollbar,
        .radius = bar_w / 2,
    });
    return .{ .x = body.x, .y = body.y, .w = body.w - bar_w - 4, .h = body.h };
}
