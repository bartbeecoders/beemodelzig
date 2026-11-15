//! The `Ui` context: frame lifecycle, identity, interaction state.

const std = @import("std");
const draw = @import("draw.zig");
const input_mod = @import("input.zig");
const layout = @import("layout.zig");
const widget_fns = @import("widgets.zig");
const text_input = @import("text_input.zig");
const overlay_mod = @import("overlay.zig");
const color_edit = @import("color_edit.zig");
const theme = @import("theme.zig");
const pie_mod = @import("pie.zig");
const decor = @import("decor.zig");
const view2d = @import("view2d.zig");
const containers = @import("containers.zig");
const persist = @import("persist.zig");
const window = @import("window.zig");
const paint = @import("paint.zig");
const icons = @import("icons.zig");
const canvas = @import("canvas.zig");
const record_mod = @import("record.zig");
const values = @import("values.zig");
const choice = @import("choice.zig");
const menus = @import("menus.zig");
const dock_mod = @import("dock.zig");
const tabs_mod = @import("tabs.zig");
const feedback = @import("feedback.zig");
const lists = @import("lists.zig");
const dnd = @import("dnd.zig");
const textview = @import("textview.zig");
const textarea = @import("textarea.zig");
const Font = @import("font.zig").Font;
const style_mod = @import("style.zig");
const Style = style_mod.Style;
const Allocator = std.mem.Allocator;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;

/// Identifies a widget across frames. Derived from its label and the ID stack.
pub const Id = enum(u64) {
    none = 0,
    _,
};

/// What the mouse did to a widget this frame.
pub const Interaction = struct {
    /// The widget's ID, as given to `interact`.
    id: Id = .none,
    /// Where the widget ended up.
    rect: Rect = .{},
    /// The mouse is over the widget, and nothing else owns it.
    hovered: bool = false,
    /// The widget is being pressed. Stays true if the mouse leaves.
    held: bool = false,
    /// The mouse was pressed and released on the widget.
    clicked: bool = false,
    /// The mouse went down on the widget this frame.
    pressed: bool = false,
    /// The widget changed the value it edits.
    changed: bool = false,
    /// The widget has keyboard focus.
    focused: bool = false,
    /// Enter was pressed in a text input.
    submitted: bool = false,
    /// An edit began this frame: a drag started, typing started, a choice
    /// is being made. Take an undo snapshot here.
    started: bool = false,
    /// An edit ended and is kept: the drag was released, Enter was
    /// pressed, a choice was made. One `committed` is one undo step.
    /// A click or key that edits at once sets `started`, `changed` and
    /// `committed` in the same frame.
    committed: bool = false,
    /// An edit that `started` ended without a change to keep: Escape put
    /// the value back, or nothing changed (a press without a drag, typed
    /// text that isn't a number). Drop anything taken at `started`.
    cancelled: bool = false,
    /// The right button was pressed on the widget: show its context menu.
    /// See also `Ui.contextRequest`.
    context_clicked: bool = false,
    /// The widget is disabled (see `Ui.pushDisabled`): it shows as faded
    /// and ignores clicks and keys.
    disabled: bool = false,
};

/// A right-click on a widget, from `Ui.contextRequest`.
pub const ContextRequest = struct {
    widget: Id,
    rect: Rect,
    /// Where the pointer was, for placing the menu.
    pos: Vec2,
};

/// A pending Tab or Shift+Tab.
pub const Nav = enum { none, next, prev };

/// Pointer shapes a widget can ask for through `Ui.cursor`. Backends map
/// them to the system's cursors.
pub const Cursor = enum {
    default,
    /// An I-beam, over editable text.
    text,
    /// A hand, over links and things to click.
    pointer,
    crosshair,
    move,
    /// Left-right arrows: splitters, column edges, number fields to drag.
    resize_ew,
    /// Up-down arrows.
    resize_ns,
    /// Diagonal arrows, top-left to bottom-right: a bottom-right grip.
    resize_nwse,
    /// Diagonal arrows, top-right to bottom-left.
    resize_nesw,
    not_allowed,
    /// An open hand: something that can be dragged.
    grab,
    /// A closed hand: something being dragged.
    grabbing,
};

/// Where copied text goes and pasted text comes from. Backends provide one for
/// the system clipboard; see `Ui.clipboard`.
pub const Clipboard = struct {
    context: *anyopaque,
    /// Returns the clipboard's text, valid until the next call. Empty if the
    /// clipboard holds no text.
    getFn: *const fn (context: *anyopaque) []const u8,
    /// Replaces the clipboard's contents with `text`.
    setFn: *const fn (context: *anyopaque, text: []const u8) void,
};

/// Where a group sits and how it lays out its children. See `Ui.beginGroup`.
pub const GroupOptions = struct {
    /// Identifies the group across frames. Groups are otherwise numbered in
    /// order, which is fine unless groups come and go around it.
    id: ?[]const u8 = null,
    axis: layout.Axis = .vertical,
    /// Defaults to fitting the content.
    width: layout.Size = .auto,
    height: layout.Size = .auto,
    /// Space inside the group's edge.
    padding: f32 = 0,
    /// Space between items. Defaults to the style's.
    spacing: ?f32 = null,
    /// Where items sit across the axis.
    alignment: layout.Align = .start,
    /// Where the run of items sits along the axis. Needs a known size.
    justify: layout.Align = .start,
    /// Background.
    fill: draw.Color = .transparent,
    border: draw.Color = .transparent,
};

/// Options for `Ui.beginHorizontal`, which by default fills the width and
/// centers its items vertically.
pub const RowOptions = struct {
    id: ?[]const u8 = null,
    width: layout.Size = .fill,
    height: layout.Size = .auto,
    padding: f32 = 0,
    spacing: ?f32 = null,
    alignment: layout.Align = .center,
    justify: layout.Align = .start,
    fill: draw.Color = .transparent,
    border: draw.Color = .transparent,
};

/// One level of nested layout.
pub const LayoutFrame = struct {
    layout: layout.Layout,
    id: Id,
    /// Numbers child groups that have no explicit ID.
    children: u32 = 0,
    width: layout.Size = .auto,
    height: layout.Size = .auto,
    padding: f32 = 0,
};

/// The immediate-mode context. Describe the UI between `beginFrame` and
/// `endFrame`, once per frame, calling widget methods such as `button`.
///
/// Widget methods never return errors. The first allocation failure is
/// remembered, the rest of the frame degrades to drawing less, and `endFrame`
/// returns the error.
pub const Ui = struct {
    allocator: Allocator,
    frame_arena: std.heap.ArenaAllocator,
    /// Feed this from your backend between frames.
    input: input_mod.Input = .{},
    /// The current theme. Assign to switch themes, outside any `pushStyle`
    /// scope (its `popStyle` would undo the switch).
    style: Style,
    /// Saved styles, one per push.
    style_stack: [max_style_depth]Style = undefined,
    style_depth: usize = 0,
    /// Pushes past `max_style_depth`, ignored but counted so pops balance.
    style_overflow: usize = 0,
    /// Used for all text.
    font: *Font,
    /// Commands outside any window.
    draw_list: draw.DrawList,
    /// Where draw calls go: `draw_list` or the current window's list.
    list: *draw.DrawList = undefined,
    /// Tooltips, drawn above everything.
    overlay: draw.DrawList,
    /// Everything composed in z-order. What `endFrame` returns.
    output: draw.DrawList,
    /// Open popups, outermost first.
    popups: [overlay_mod.max_popups]overlay_mod.PopupEntry = undefined,
    popup_count: usize = 0,
    /// How many `beginPopup` scopes are being described.
    popup_nesting: usize = 0,
    /// The widget hovered since `hover_time` seconds ago, for tooltips.
    hover_id: Id = .none,
    hover_time: f32 = 0,
    /// The rect most recently placed in a layout.
    last_rect: Rect = .{},
    /// Colour pickers' working state and the eyedropper.
    picker_state: color_edit.State = .{},
    last_keyboard_viewport: Id = .none,
    /// Detached windows of this frame, for `viewports`.
    viewport_list: std.ArrayList(Viewport) = .empty,
    pie_state: pie_mod.State = .{},
    view_state: view2d.State = .{},
    /// Where the eyedropper wants a pixel read back, set during the frame.
    /// After rendering, the backend passes the colour there to
    /// `input.onColorSample`.
    sample_request: ?Vec2 = null,
    /// The UI's own zoom, 0.75 to 2, on top of the display's scale. See
    /// `setScale`.
    ui_scale: f32 = 1,
    /// A `setScale` waiting for the next frame.
    scale_request: ?f32 = null,
    /// Which tree nodes and headers are open.
    open_states: std.AutoHashMapUnmanaged(Id, bool) = .empty,
    /// Scroll position of each scroll area and table.
    scroll_states: std.AutoHashMapUnmanaged(Id, containers.ScrollState) = .empty,
    scroll_stack: [containers.max_scroll_depth]containers.ScrollFrame = undefined,
    scroll_depth: usize = 0,
    /// The table being described, if any.
    table: ?containers.TableState = null,
    clip_stack: [max_layout_depth * 2]Rect = undefined,
    clip_depth: usize = 0,

    windows: std.AutoHashMapUnmanaged(Id, *window.State) = .empty,
    /// Back to front.
    window_order: std.ArrayList(*window.State) = .empty,
    /// The window being described, or null at the top level.
    current_window: ?*window.State = null,
    /// The frontmost window under the mouse, from last frame's positions.
    hovered_window: ?*window.State = null,
    /// The frontmost window under this frame's left press, if any.
    pressed_window: ?*window.State = null,
    /// Mouse offset from what is being dragged.
    drag_offset: Vec2 = .{},
    frame_index: u64 = 0,
    id_stack: std.ArrayList(Id) = .empty,
    /// Fixed size, so nesting can't fail and leave begin and end unbalanced.
    layouts: [max_layout_depth]LayoutFrame = undefined,
    layout_depth: usize = 0,
    /// What each group measured last frame.
    measures: std.AutoHashMapUnmanaged(Id, layout.Measure) = .empty,

    width: f32 = 0,
    height: f32 = 0,
    /// Seconds since the previous frame.
    dt: f32 = 0,

    /// The widget under the mouse this frame.
    hot: Id = .none,
    /// The widget holding the mouse. Persists across frames.
    active: Id = .none,
    /// The widget that held the mouse until a release this frame that came
    /// before a new press (Input.pressed_after_release): it gets its release,
    /// the press goes to whatever is under it.
    releasing: Id = .none,
    active_seen: bool = false,
    /// A press landed on empty space. Until it is released no widget may
    /// react, so dragging across a button doesn't light it up.
    dead_press: bool = false,
    /// A text field took this frame's Enter (to end its typing), so a
    /// dialog's default button doesn't press on it too.
    enter_taken: bool = false,
    /// A group's size changed this frame, so the next lays out differently.
    /// See `layoutSettling`.
    layout_changed: bool = false,
    redraw_requested: bool = false,
    /// Seconds until a frame is wanted even without input, or null. See
    /// `requestRedrawIn`.
    redraw_in: ?f32 = null,
    /// The widget receiving keyboard input. Persists across frames.
    focused: Id = .none,
    focused_seen: bool = false,
    /// Focus was last moved with the keyboard, so the focus ring shows.
    /// The next mouse press hides it again.
    focus_visible: bool = false,
    /// A widget took focus from this frame's mouse press.
    focus_pressed: bool = false,
    /// The focused widget should scroll into view when next described.
    scroll_to_focus: bool = false,
    /// Tab navigation in progress this frame. See `focusable`.
    nav: Nav = .none,
    nav_take_next: bool = false,
    nav_prev: Id = .none,
    nav_first: Id = .none,
    nav_last: Id = .none,
    /// The value a held slider had when pressed, for Escape to restore.
    drag_backup: [16]u8 = undefined,
    /// Editing state of the focused text input.
    text_edit: text_input.State = .{},
    /// The system clipboard. Without one, copy and paste still work, but only
    /// within this `Ui`.
    clipboard: ?Clipboard = null,
    local_clipboard: std.ArrayList(u8) = .empty,
    first_error: ?Allocator.Error = null,
    /// The pointer shape widgets asked for this frame. Reset to `.default`
    /// by `beginFrame`; pass it to the backend after `endFrame`.
    cursor: Cursor = .default,
    /// How far the pointer moved since the previous frame.
    mouse_delta: Vec2 = .{},
    last_mouse: Vec2 = .{},
    /// A canvas that holds the right or middle button since it went down
    /// over it.
    canvas_capture: ?struct { id: Id, button: input_mod.MouseButton } = null,
    canvas_capture_seen: bool = false,
    font_stack: [max_font_depth]*Font = undefined,
    font_depth: usize = 0,
    /// Keep a list of every widget shown, for tests, scripts and agents;
    /// read it with `widgets()` after `endFrame`. Off by default.
    recording: bool = false,
    record: record_mod.Recorder = .{},
    number_state: values.State = .{},
    choice_state: choice.State = .{},
    menu_state: menus.State = .{},
    dock_state: dock_mod.State = .{},
    tab_state: tabs_mod.State = .{},
    feedback_state: feedback.State = .{},
    drag_state: dnd.State = .{},
    textarea_state: textarea.State = .{},
    /// Toasts sit this far above the bottom of the window, clear of a
    /// status bar.
    toast_margin: f32 = 48,
    /// Where toasts sit across the window: in the middle, or 12 units from
    /// the right edge, clear of what is in the middle.
    toast_align: enum { center, right } = .center,
    /// Seconds of gliding progress bars, for their position.
    glide_time: f32 = 0,
    /// The frame `glide_time` last moved in: once a frame, however many
    /// bars glide.
    glide_frame: u64 = 0,
    disabled_stack: [max_disabled_depth]?[]const u8 = undefined,
    disabled_depth: usize = 0,
    /// Whether each `pushDisabled` level pushed a faded style to pop.
    disabled_styled: [max_disabled_depth]bool = undefined,
    /// A disabled widget was clicked this frame; why it is disabled.
    disabled_click_next: ?[]const u8 = null,
    disabled_click_buffer: [160]u8 = undefined,
    disabled_click_len: ?usize = null,
    /// The disabled widget under the pointer, for its tooltip.
    disabled_hover: ?struct { widget: Id, rect: Rect, reason: []const u8 } = null,
    context_next: ?ContextRequest = null,
    context_last: ?ContextRequest = null,
    /// A tooltip was shown this frame, so the disabled reason needn't be.
    tooltip_shown: bool = false,
    /// The rich tooltip shown this frame, if any (its text is valid until
    /// the next `beginFrame`): for a help panel that shows the same.
    shown_tip: ?overlay_mod.Tip = null,
    /// Tab and Shift+Tab move only among widgets in this focus scope
    /// (`.none`: everywhere). Dock areas and dialogs set it.
    nav_scope: Id = .none,
    /// The focus scope being described (`pushFocusScope`).
    current_scope: Id = .none,
    /// The scope Tab is kept to from the next frame on: set during the frame
    /// by the dock's active area, overridden by a dialog.
    nav_scope_next: Id = .none,
    /// A widget that handles Tab itself (completion in a console): while it
    /// has focus, Tab doesn't move the focus. Set it every frame.
    tab_owner: Id = .none,
    tab_owner_last: Id = .none,

    /// The deepest allowed nesting of groups and windows.
    pub const max_layout_depth = 64;
    /// The deepest allowed nesting of style overrides.
    pub const max_style_depth = 32;
    /// How deep `pushFont` can nest.
    pub const max_font_depth = 8;
    /// How deep `pushDisabled` can nest.
    pub const max_disabled_depth = 16;

    /// Settings for `init`.
    pub const Options = struct {
        /// Borrowed; must outlive the `Ui`.
        font: *Font,
        style: Style = .dark,
    };

    /// Per-frame values for `beginFrame`.
    pub const FrameInfo = struct {
        /// Logical size of the drawing area.
        width: f32,
        height: f32,
        /// Seconds since the previous frame.
        dt: f32 = 1.0 / 60.0,
    };

    /// Creates a context. All memory comes from `allocator`.
    pub fn init(allocator: Allocator, options: Options) Ui {
        return .{
            .allocator = allocator,
            .frame_arena = .init(allocator),
            .style = options.style,
            .font = options.font,
            .draw_list = .init(allocator),
            .overlay = .init(allocator),
            .output = .init(allocator),
        };
    }

    /// Frees all memory.
    pub fn deinit(self: *Ui) void {
        self.draw_list.deinit();
        self.overlay.deinit();
        self.output.deinit();
        for (self.window_order.items) |w| {
            w.list.deinit();
            w.out.deinit();
            self.allocator.destroy(w);
        }
        self.viewport_list.deinit(self.allocator);
        self.window_order.deinit(self.allocator);
        self.windows.deinit(self.allocator);
        self.id_stack.deinit(self.allocator);
        self.measures.deinit(self.allocator);
        self.text_edit.deinit(self.allocator);
        self.textarea_state.deinit(self.allocator);
        self.open_states.deinit(self.allocator);
        self.scroll_states.deinit(self.allocator);
        self.local_clipboard.deinit(self.allocator);
        self.record.deinit(self.allocator);
        self.frame_arena.deinit();
    }

    /// The smallest and largest `ui_scale`.
    pub const min_scale = 0.75;
    pub const max_scale = 2.0;

    /// Zooms the whole UI, 0.75 to 2 (75 to 200 %), independent of the
    /// display's own scale, from the next frame on. Text is rasterized at the new size, not
    /// stretched. Pass the window's size to `beginFrame` as before; the UI
    /// then has that size divided by the scale, and `renderFrame` tells the
    /// renderer how to draw it.
    pub fn setScale(self: *Ui, scale: f32) void {
        self.scale_request = std.math.clamp(scale, min_scale, max_scale);
        self.requestRedraw();
    }

    fn applyScale(self: *Ui, s: f32) void {
        // The pointer is kept in UI units: move it to the new ones.
        const k = self.ui_scale / s;
        self.input.mouse_pos = self.input.mouse_pos.scale(k);
        for (std.enums.values(input_mod.MouseButton)) |b| {
            self.input.press_pos.set(b, self.input.press_pos.get(b).scale(k));
        }
        self.last_mouse = self.last_mouse.scale(k);
        self.ui_scale = s;
        self.input.unit_scale = s;
    }

    /// How many commands the root of this frame has described so far: mark
    /// where a part starts, describe it, then draw `rootView(mark, now)`
    /// right away. See `DrawList.view`. The whole frame's list from
    /// `endFrame` still starts with every root command, in the same places,
    /// so draw only the rest of it then.
    pub fn rootCommandCount(self: *const Ui) usize {
        return self.draw_list.commands.items.len;
    }

    /// Root commands `start` to `end` of the frame being described, as a
    /// list to render now. See `rootCommandCount`.
    pub fn rootView(self: *const Ui, start: usize, end: usize) draw.DrawList {
        return self.draw_list.view(start, end);
    }

    /// What to pass to `Renderer.render` for the frame just ended, given
    /// the display's pixels per window unit.
    pub fn renderFrame(self: *const Ui, display_scale: f32) draw.Frame {
        return .{ .width = self.width, .height = self.height, .scale = display_scale * self.ui_scale };
    }

    /// Starts the root layout `top` units lower, below a title bar drawn
    /// across the top (`clientFrame`). Call before placing anything.
    pub fn moveRootBelow(self: *Ui, top: f32) void {
        std.debug.assert(self.layout_depth == 1 and !self.layouts[0].layout.placed_any);
        const padding = self.style.window_padding;
        var options = self.layouts[0].layout.options;
        options.origin.y = top + padding;
        options.main_extent = @max(0, self.height - top - 2 * padding);
        self.layouts[0].layout = .init(options);
    }

    /// A window shown in an OS window of its own, from `viewports`.
    pub const Viewport = struct {
        /// The window's ID; give it back to `setViewportSize`,
        /// `closeViewport` and `input.viewport`.
        id: Id,
        title: []const u8,
        /// Its size in UI units: make the OS window this size, or report
        /// the OS window's size with `setViewportSize`.
        size: Vec2,
        /// What to draw in it, in its own coordinates (0, 0 at its top
        /// left): the window, its popups, and tooltips while the pointer is
        /// in it.
        list: *const draw.DrawList,
        /// The user asked to move or resize it through its title bar or
        /// grip: pass it on to the system.
        request: window.ViewportRequest,
    };

    /// Windows shown in OS windows of their own this frame (see
    /// `WindowOptions.detached`). Valid until the next `beginFrame`. Create
    /// an OS window for each new ID, destroy those that are gone, and
    /// render each list in its window.
    pub fn viewports(self: *const Ui) []const Viewport {
        return self.viewport_list.items;
    }

    /// The OS window of viewport `id` now has `size` (UI units).
    pub fn setViewportSize(self: *Ui, viewport: Id, size: Vec2) void {
        if (self.windows.get(viewport)) |w| {
            if (w.os_size.x != size.x or w.os_size.y != size.y) self.requestRedraw();
            w.os_size = size;
        }
    }

    /// The system closed viewport `id`'s OS window: the window closes if it
    /// can (it has `open`), or comes back into the main window.
    pub fn closeViewport(self: *Ui, viewport: Id) void {
        if (self.windows.get(viewport)) |w| w.close_requested = true;
        self.requestRedraw();
    }

    /// Starts a frame. Input must already be in `self.input`.
    pub fn beginFrame(self: *Ui, info: FrameInfo) void {
        _ = self.frame_arena.reset(.retain_capacity);
        self.frame_index += 1;
        self.draw_list.clear();
        self.list = &self.draw_list;
        self.current_window = null;
        if (self.scale_request) |s| self.applyScale(s);
        self.scale_request = null;
        const width = info.width / self.ui_scale;
        const height = info.height / self.ui_scale;
        self.clip_stack[0] = .{ .w = width, .h = height };
        self.clip_depth = 1;
        self.id_stack.clearRetainingCapacity();
        self.width = width;
        self.height = height;
        self.input.unit_scale = self.ui_scale;
        self.dt = info.dt;
        // Tooltips wait for the mouse to rest on one widget, button up.
        if (self.hot != .none and self.hot == self.hover_id and !self.input.mouse_down.contains(.left)) {
            self.hover_time += info.dt;
        } else {
            self.hover_id = self.hot;
            self.hover_time = 0;
        }
        self.hot = .none;
        self.active_seen = false;
        self.redraw_requested = false;
        self.redraw_in = null;
        self.focused_seen = false;
        self.focus_pressed = false;
        self.enter_taken = false;
        self.layout_changed = false;
        self.first_error = null;
        self.cursor = .default;
        self.mouse_delta = self.input.mouse_pos.sub(self.last_mouse);
        self.last_mouse = self.input.mouse_pos;
        self.canvas_capture_seen = false;
        record_mod.beginFrame(self);
        self.disabled_depth = 0;
        self.disabled_click_next = null;
        self.disabled_hover = null;
        self.context_next = null;
        self.tooltip_shown = false;
        self.shown_tip = null;
        self.nav_scope = self.nav_scope_next;
        self.nav_scope_next = .none;
        // The keyboard moved to another OS window: focus doesn't stay
        // behind in the one it left, and Tab keeps to the new one.
        if (self.input.keyboard_viewport != self.last_keyboard_viewport) {
            self.last_keyboard_viewport = self.input.keyboard_viewport;
            self.focused = .none;
        }
        if (self.input.keyboard_viewport != .none) self.nav_scope = self.input.keyboard_viewport;
        menus.beginFrame(self);
        feedback.beginFrame(self);
        dnd.beginFrame(self);
        color_edit.beginFrame(self);
        pie_mod.beginFrame(self);
        self.beginNavigation();

        // Release, then press, in this frame: the held widget lets go first,
        // so the press can start a new hold.
        self.releasing = .none;
        if (self.input.pressed_after_release.contains(.left) and self.active != .none) {
            self.releasing = self.active;
            self.active = .none;
        }
        window.beginFrame(self);
        overlay_mod.beginFrame(self);

        const padding = self.style.window_padding;
        const root_id: Id = @enumFromInt(0x5A5A5A5A);
        self.layouts[0] = .{
            .id = root_id,
            .layout = .init(.{
                .origin = .{ .x = padding, .y = padding },
                .spacing = self.style.item_spacing,
                .main_extent = @max(0, height - 2 * padding),
                .cross_extent = @max(0, width - 2 * padding),
                .previous = self.measures.get(root_id) orelse .{},
            }),
        };
        self.layout_depth = 1;
    }

    /// Ends the frame and returns what to draw, valid until the next
    /// `beginFrame`. Pass it to `Renderer.render`.
    pub fn endFrame(self: *Ui) Allocator.Error!*const draw.DrawList {
        std.debug.assert(self.layout_depth == 1); // a begin without an end
        std.debug.assert(self.scroll_depth == 0 and self.table == null); // a scroll area or table was not ended
        self.scroll_depth = 0;
        self.table = null;
        std.debug.assert(self.style_depth == 0 and self.style_overflow == 0); // a pushStyle without a popStyle
        if (self.style_depth > 0) self.style = self.style_stack[0];
        self.style_depth = 0;
        std.debug.assert(self.font_depth == 0); // a pushFont without a popFont
        if (self.font_depth > 0) self.font = self.font_stack[0];
        self.font_depth = 0;
        // A canvas that holds a button but wasn't described this frame is gone.
        if (!self.canvas_capture_seen) self.canvas_capture = null;
        std.debug.assert(self.disabled_depth == 0); // a pushDisabled without a popDisabled
        self.disabled_depth = 0;
        self.context_last = self.context_next;
        self.disabled_click_len = null;
        if (self.disabled_click_next) |why| {
            const n = @import("font.zig").fitUtf8(why, self.disabled_click_buffer.len);
            @memcpy(self.disabled_click_buffer[0..n], why[0..n]);
            self.disabled_click_len = n;
        }
        self.style_overflow = 0;
        self.storeMeasure(self.layouts[0].id, self.layouts[0].layout.finish());

        // A held widget that stopped being described can never see the release.
        if (!self.active_seen) self.active = .none;
        // Likewise, focus can't stay on a widget that is gone, and a click
        // anywhere but a focusable widget takes it away.
        if (!self.focused_seen) self.focused = .none;
        if (self.input.mouse_pressed.contains(.left) and !self.focus_pressed) self.focused = .none;
        self.finishNavigation();

        // A press on a window that is gone went to nothing: it is replayed
        // next frame instead of becoming a dead press.
        const replay_press = window.pressMissed(self);
        const left_down = self.input.mouse_down.contains(.left);
        if (self.input.mouse_pressed.contains(.left) and self.active == .none and left_down and !replay_press) {
            self.dead_press = true;
        }
        if (!left_down) self.dead_press = false;

        overlay_mod.endFrame(self);
        menus.endFrame(self);
        feedback.endFrame(self);
        dnd.endFrame(self);
        color_edit.endFrame(self);
        pie_mod.endFrame(self);
        record_mod.endFrame(self);
        window.forgetClosed(self);
        window.prune(self);
        const replay_release = replay_press and self.input.mouse_released.contains(.left);
        self.input.clearEdges();
        if (replay_press) {
            self.input.mouse_pressed.insert(.left);
            if (replay_release) self.input.mouse_released.insert(.left);
            self.requestRedraw();
        }
        self.compose() catch |err| self.fail(err);
        if (self.first_error) |err| return err;
        return &self.output;
    }

    fn compose(self: *Ui) Allocator.Error!void {
        self.output.clear();
        try self.output.append(&self.draw_list);
        // Windows, the dimmed backdrop and dialogs, then popups above
        // them, then tooltips above all. Windows in OS windows of their
        // own go to their viewport's list instead.
        var dimmed = false;
        for ([_]u2{ 0, 1, 2 }) |pass| {
            for (self.window_order.items) |w| {
                if (w.last_frame != self.frame_index or w.hidden) continue;
                if (w.viewport != .none) continue;
                const layer: u2 = if (w.popup) 2 else if (w.dialog) 1 else 0;
                if (layer != pass) continue;
                try self.output.setClip(null);
                if (w.dialog and !dimmed) {
                    dimmed = true;
                    try self.output.addRect(.{ .rect = .{ .w = self.width, .h = self.height }, .fill = self.style.colors.backdrop });
                }
                try self.output.append(&w.list);
            }
        }
        try self.output.setClip(null);
        if (self.input.viewport == .none) try self.output.append(&self.overlay);

        self.viewport_list.clearRetainingCapacity();
        for (self.window_order.items) |d| {
            if (!d.detached or d.last_frame != self.frame_index) continue;
            d.out.clear();
            try d.out.append(&d.list);
            for (self.window_order.items) |w| {
                if (w == d or w.viewport != d.id or w.last_frame != self.frame_index or w.hidden) continue;
                try d.out.setClip(null);
                try d.out.append(&w.list);
            }
            try d.out.setClip(null);
            if (self.input.viewport == d.id) try d.out.append(&self.overlay);
            try self.viewport_list.append(self.allocator, .{
                .id = d.id,
                .title = d.title[0..d.title_len],
                .size = d.os_size,
                .list = &d.out,
                .request = d.request,
            });
        }
    }

    /// Asks for another frame even if no input arrives, for animation.
    pub fn requestRedraw(self: *Ui) void {
        self.redraw_requested = true;
    }

    /// Replaces the whole style until the matching `popStyle`. Use it to
    /// show part of the UI in another theme.
    pub fn pushStyle(self: *Ui, style: Style) void {
        if (self.saveStyle()) self.style = style;
    }

    /// Overrides one color until the matching `popStyle`.
    ///
    ///     ui.pushColor(.button, zui.Color.hex(0xB03A3A));
    ///     defer ui.popStyle();
    pub fn pushColor(self: *Ui, comptime field: std.meta.FieldEnum(style_mod.Colors), color: draw.Color) void {
        if (self.saveStyle()) @field(self.style.colors, @tagName(field)) = color;
    }

    /// Overrides one size until the matching `popStyle`. The value has the
    /// field's type: `ui.pushMetric(.rounding, 0)`,
    /// `ui.pushMetric(.frame_padding, .{ .x = 4, .y = 2 })`.
    pub fn pushMetric(
        self: *Ui,
        comptime field: std.meta.FieldEnum(Style),
        value: @FieldType(Style, @tagName(field)),
    ) void {
        if (field == .colors) @compileError("use pushColor for one color, or pushStyle for a theme");
        if (self.saveStyle()) @field(self.style, @tagName(field)) = value;
    }

    /// Undoes the most recent `pushStyle`, `pushColor` or `pushMetric`.
    pub fn popStyle(self: *Ui) void {
        self.popStyles(1);
    }

    /// Undoes the last `count` style pushes.
    pub fn popStyles(self: *Ui, count: usize) void {
        for (0..count) |_| {
            if (self.style_overflow > 0) {
                self.style_overflow -= 1;
                continue;
            }
            std.debug.assert(self.style_depth > 0); // more pops than pushes
            if (self.style_depth == 0) return;
            self.style_depth -= 1;
            self.style = self.style_stack[self.style_depth];
        }
    }

    /// Saves the style for a push. Returns false, changing nothing, if the
    /// stack is full.
    fn saveStyle(self: *Ui) bool {
        if (self.style_depth == max_style_depth) {
            std.debug.assert(false); // nested deeper than max_style_depth
            self.style_overflow += 1;
            return false;
        }
        self.style_stack[self.style_depth] = self.style;
        self.style_depth += 1;
        return true;
    }

    /// Asks for a frame within `seconds` even if no input arrives, for timed
    /// changes such as a blinking caret. The earliest request of a frame wins.
    /// Backends read the result from `redraw_in`.
    pub fn requestRedrawIn(self: *Ui, seconds: f32) void {
        const s = @max(0, seconds);
        self.redraw_in = if (self.redraw_in) |current_s| @min(current_s, s) else s;
    }

    /// Gives keyboard focus to `widget`, or takes it away with `.none`.
    pub fn setFocus(self: *Ui, widget: Id) void {
        self.focused = widget;
        if (widget != .none) {
            self.focused_seen = true;
            // Chosen during a press: the press doesn't take it away again.
            self.focus_pressed = true;
        }
    }

    /// True after a frame whose layout is still settling: a group, window or
    /// dialog changed size, so the next frame places things differently (a
    /// dialog shows on its second frame). Unlike `redraw_requested`, this
    /// isn't set for animation (a caret, a gliding bar): a test driver or an
    /// app that draws on demand runs frames while it is true, then looks up
    /// widgets where they really are.
    pub fn layoutSettling(self: *const Ui) bool {
        return self.layout_changed;
    }

    /// True if the pointer is Zui's, as of the last frame: over one of its
    /// windows, popups or dialogs still shown (a modal dialog: anywhere), over
    /// a widget, or holding something that started on Zui (a drag, a
    /// canvas's button). An app that draws its own things around Zui's
    /// keeps pointer events for Zui while this is true.
    pub fn wantsPointer(self: *const Ui) bool {
        if (self.active != .none or self.canvas_capture != null) return true;
        if (self.feedback_state.shown) return true;
        if (self.hot != .none) return true;
        if (self.hovered_window) |w| return w.last_frame == self.frame_index;
        return false;
    }

    /// Takes the wheel's movement over `rect` this frame, if the pointer is
    /// there (and nothing in front of it): for a custom view that scrolls or
    /// zooms. Nothing else scrolls with it.
    pub fn takeScroll(self: *Ui, rect: Rect) ?Vec2 {
        const in = &self.input;
        if (in.scroll.x == 0 and in.scroll.y == 0) return null;
        const pos = in.mouse_pos;
        if (!rect.contains(pos) or !self.clipRect().contains(pos) or self.hovered_window != self.current_window) return null;
        const s = in.scroll;
        in.scroll = .{};
        return s;
    }

    /// Lays the next widgets out in `rect`, top to bottom, wherever the app
    /// wants them (a panel inside its own layout, a field over its canvas).
    /// `name` keeps it apart from others. End with `endAt`.
    pub fn beginAt(self: *Ui, name: []const u8, rect: Rect) void {
        const region = self.id(name);
        self.pushIdValue(region);
        self.beginRegion(region, rect, .vertical, 0, .start);
    }

    /// Ends what `beginAt` began.
    pub fn endAt(self: *Ui) void {
        self.endRegion();
        self.popId();
    }

    /// True when a widget is taking keyboard input, so the app should leave
    /// keys alone: a text field is being edited, or focus was moved with Tab.
    pub fn wantsKeyboard(self: *const Ui) bool {
        // A modal dialog owns the keys.
        if (self.feedback_state.shown) return true;
        // A number field being typed into takes its keys too.
        if (self.focused == .none) return false;
        if (self.number_state.editing and self.focused == self.number_state.id) return true;
        return self.focused == self.text_edit.id or self.focused == self.textarea_state.id or self.focus_visible;
    }

    /// True if `widget` has focus and responds to keys.
    pub fn isFocused(self: *const Ui, widget: Id) bool {
        return self.focused == widget;
    }

    fn beginNavigation(self: *Ui) void {
        self.tab_owner_last = self.tab_owner;
        self.tab_owner = .none;
        self.nav = .none;
        self.nav_take_next = false;
        self.nav_prev = .none;
        self.nav_first = .none;
        self.nav_last = .none;
        if (self.input.mouse_pressed.contains(.left)) self.focus_visible = false;
        for (self.input.keyEvents()) |event| {
            if (event.key != .tab or event.modifiers.ctrl or event.modifiers.alt) continue;
            if (self.focused != .none and self.focused == self.tab_owner_last) break;
            self.nav = if (event.modifiers.shift) .prev else .next;
            self.focus_visible = true;
            break;
        }
        // Escape lets go of a focused button or slider. A text field handles
        // Escape itself, to undo its edit.
        if (self.input.keys_pressed.contains(.escape) and self.focused != self.text_edit.id) {
            self.focused = .none;
        }
    }

    /// Resolves a Tab that wrapped around: past the last widget to the
    /// first, or before the first to the last.
    fn finishNavigation(self: *Ui) void {
        const target = switch (self.nav) {
            .none => return,
            .next => self.nav_first,
            .prev => self.nav_last,
        };
        if (target != .none) self.moveFocus(target);
        self.nav = .none;
    }

    fn moveFocus(self: *Ui, widget: Id) void {
        self.focused = widget;
        self.focused_seen = true;
        self.scroll_to_focus = true;
        self.redraw_requested = true;
    }

    /// Makes a widget take part in keyboard focus: clicking it focuses it,
    /// Tab and Shift+Tab reach it in the order widgets are described, and a
    /// widget that gains focus from the keyboard scrolls into view. Call it
    /// right after `interact`; it sets `result.focused`.
    pub fn focusable(self: *Ui, widget: Id, result: *Interaction) void {
        // Disabled widgets are left out of the Tab order.
        if (result.disabled) return;
        // Outside the scope Tab is kept to, a widget can be clicked into
        // focus but Tab doesn't stop there.
        const in_scope = self.nav_scope == .none or self.current_scope == self.nav_scope;
        if (in_scope) self.navigate(widget);
        self.focusRest(widget, result);
    }

    fn navigate(self: *Ui, widget: Id) void {
        switch (self.nav) {
            .none => {},
            .next => if (self.nav_take_next or self.focused == .none) {
                self.moveFocus(widget);
                self.nav = .none;
            } else if (self.focused == widget) {
                self.nav_take_next = true;
            },
            .prev => if (self.focused == widget and self.nav_prev != .none) {
                self.moveFocus(self.nav_prev);
                self.nav = .none;
            } else {
                self.nav_prev = widget;
            },
        }
        if (self.nav_first == .none) self.nav_first = widget;
        self.nav_last = widget;
    }

    fn focusRest(self: *Ui, widget: Id, result: *Interaction) void {
        if (result.pressed) {
            self.focused = widget;
            self.focus_pressed = true;
        } else if (self.focused == widget and self.input.mouse_pressed.contains(.left)) {
            // A press anywhere else ends focus now, not at the end of the
            // frame, so this widget already draws as unfocused.
            self.focused = .none;
        }
        if (self.focused != widget) return;
        self.focused_seen = true;
        result.focused = true;

        if (self.scroll_to_focus) {
            self.scroll_to_focus = false;
            // The innermost scrolling container moves; a scroll area inside
            // a window scrolls itself, not the window.
            if (self.current_window) |w| window.raise(self, w);
            if (containers.scrollIntoView(self, result.rect)) return;
            if (self.current_window) |w| {
                const view = self.clipRect();
                const margin = self.style.item_spacing.y;
                if (result.rect.y < view.y) {
                    w.scroll -= view.y - result.rect.y + margin;
                } else if (result.rect.bottom() > view.bottom()) {
                    w.scroll += result.rect.bottom() - view.bottom() + margin;
                }
                self.redraw_requested = true;
            }
        }
    }

    /// Marks the widgets described until `popFocusScope` as belonging to
    /// `scope`. Returns the scope to restore.
    pub fn pushFocusScope(self: *Ui, scope: Id) Id {
        const saved = self.current_scope;
        self.current_scope = scope;
        return saved;
    }

    /// Ends `pushFocusScope`.
    pub fn popFocusScope(self: *Ui, saved: Id) void {
        self.current_scope = saved;
    }

    /// Fills `rect` above everything, windows and popups included: drop
    /// targets, drag feedback. Cleared every frame.
    pub fn overlayRect(self: *Ui, rect: Rect, color: draw.Color) void {
        self.overlay.setClip(null) catch |err| return self.fail(err);
        self.overlay.addRect(.{ .rect = rect, .fill = color, .radius = self.style.rounding }) catch |err| self.fail(err);
    }

    /// Outlines `rect` above everything.
    pub fn overlayBorder(self: *Ui, rect: Rect, color: draw.Color) void {
        self.overlay.setClip(null) catch |err| return self.fail(err);
        self.overlay.addRect(.{ .rect = rect, .border = color, .border_width = 2, .radius = self.style.rounding }) catch |err| self.fail(err);
    }

    /// Starts a layout at `rect`, outside the normal flow, laying out along
    /// `axis` and clipped to `rect`. End it with `endRegion`.
    pub fn beginRegion(self: *Ui, region: Id, rect: Rect, axis: layout.Axis, padding: f32, alignment: layout.Align) void {
        std.debug.assert(self.layout_depth < max_layout_depth);
        self.pushClip(rect);
        const inner = rect.inset(padding);
        const horizontal = axis == .horizontal;
        self.layouts[self.layout_depth] = .{
            .id = region,
            .layout = .init(.{
                .origin = .{ .x = inner.x, .y = inner.y },
                .axis = axis,
                .spacing = self.style.item_spacing,
                .alignment = alignment,
                .main_extent = if (horizontal) inner.w else inner.h,
                .cross_extent = if (horizontal) inner.h else inner.w,
                .previous = self.measures.get(region) orelse .{},
            }),
        };
        self.layout_depth += 1;
    }

    /// The size of what a region (or group) with this ID held last frame,
    /// or null if it wasn't shown. Size a box to its content a frame late.
    pub fn regionSize(self: *const Ui, region: Id) ?Vec2 {
        const m = self.measures.get(region) orelse return null;
        return m.content;
    }

    /// Ends `beginRegion`.
    pub fn endRegion(self: *Ui) void {
        const frame = self.current();
        const measure = frame.layout.finish();
        self.storeMeasure(frame.id, measure);
        self.layout_depth -= 1;
        self.popClip();
    }

    /// Draws the keyboard focus ring around `rect` if `widget` has focus
    /// and focus was moved with the keyboard.
    pub fn drawFocusRing(self: *Ui, widget: Id, rect: Rect) void {
        if (self.focused != widget or !self.focus_visible) return;
        const gap = self.style.focus_ring_gap;
        self.drawRect(.{
            .rect = .{ .x = rect.x - gap, .y = rect.y - gap, .w = rect.w + 2 * gap, .h = rect.h + 2 * gap },
            .border = self.style.colors.focus_ring,
            .border_width = self.style.focus_ring_width,
            .radius = self.style.rounding + gap,
        });
    }

    /// Returns the clipboard's text, valid until the next clipboard call.
    pub fn getClipboard(self: *Ui) []const u8 {
        if (self.clipboard) |cb| return cb.getFn(cb.context);
        return self.local_clipboard.items;
    }

    /// Copies `text` to the clipboard.
    pub fn setClipboard(self: *Ui, text: []const u8) void {
        if (self.clipboard) |cb| return cb.setFn(cb.context, text);
        self.local_clipboard.clearRetainingCapacity();
        self.local_clipboard.appendSlice(self.allocator, text) catch |err| self.fail(err);
    }

    /// Returns a frame-lifetime allocator for temporary data.
    pub fn frameAllocator(self: *Ui) Allocator {
        return self.frame_arena.allocator();
    }

    /// Remembers an allocation failure for `endFrame` to return.
    pub fn fail(self: *Ui, err: Allocator.Error) void {
        if (self.first_error == null) self.first_error = err;
    }

    /// Derives an ID from `name` and the ID stack. Everything after `##` counts
    /// toward the ID but is not displayed.
    pub fn id(self: *const Ui, name: []const u8) Id {
        const seed: u64 = if (self.id_stack.getLastOrNull()) |top| @intFromEnum(top) else 0x9E3779B97F4A7C15;
        const hash = std.hash.Wyhash.hash(seed, name);
        return if (hash == 0) @enumFromInt(1) else @enumFromInt(hash);
    }

    /// Scopes IDs below this point under `name`. Use in loops, where several
    /// widgets share a label. Pair with `popId`.
    pub fn pushId(self: *Ui, name: []const u8) void {
        self.pushIdValue(self.id(name));
    }

    /// Pushes an already computed ID.
    pub fn pushIdValue(self: *Ui, value: Id) void {
        self.id_stack.append(self.allocator, value) catch |err| self.fail(err);
    }

    /// Like `pushId`, keyed by a number such as a loop index.
    pub fn pushIdInt(self: *Ui, value: u64) void {
        self.pushId(std.mem.asBytes(&value));
    }

    /// Removes the scope added by the matching `pushId`.
    pub fn popId(self: *Ui) void {
        _ = self.id_stack.pop();
    }

    /// Returns the part of a label that is shown, before any `##`.
    pub fn visibleLabel(label_text: []const u8) []const u8 {
        const end = std.mem.indexOf(u8, label_text, "##") orelse return label_text;
        return label_text[0..end];
    }

    /// Runs the shared mouse logic for a widget occupying `rect`. Custom widgets
    /// call this to behave exactly like the built-in ones.
    pub fn interact(self: *Ui, widget: Id, rect: Rect) Interaction {
        const mouse = &self.input;
        // Only the frontmost window under the mouse, and only what is not
        // clipped away, can be hovered.
        const clip = self.clipRect();
        const pos = mouse.mouse_pos;
        const inside = rect.contains(pos) and clip.contains(pos) and
            self.hovered_window == self.current_window;
        const free = self.active == .none or self.active == widget;
        var result: Interaction = .{
            .id = widget,
            .rect = rect,
            .hovered = inside and free and !self.dead_press,
        };
        if (result.hovered) self.hot = widget;

        if (self.disabledReason()) |why| {
            // Hovering still works, for the tooltip that says why; presses
            // only report the reason.
            result.disabled = true;
            if (result.hovered) self.disabled_hover = .{ .widget = widget, .rect = rect, .reason = why };
            if (mouse.mouse_pressed.contains(.left) and self.active == .none) {
                const at = mouse.press_pos.get(.left);
                if (rect.contains(at) and clip.contains(at) and self.pressed_window == self.current_window) self.disabled_click_next = why;
            }
            if (self.active == widget) self.active = .none;
            return result;
        }

        if (mouse.mouse_pressed.contains(.right)) {
            const at = mouse.press_pos.get(.right);
            if (rect.contains(at) and clip.contains(at) and self.hovered_window == self.current_window) {
                result.context_clicked = true;
                self.context_next = .{ .widget = widget, .rect = rect, .pos = at };
            }
        }

        // Let go by a release that came before this frame's press: its click.
        const release_first = mouse.pressed_after_release.contains(.left);
        if (self.releasing == widget) {
            const at = mouse.release_pos.get(.left);
            result.clicked = rect.contains(at) and clip.contains(at);
            self.releasing = .none;
        }

        // Presses are tested where they happened, not where the mouse is now.
        if (mouse.mouse_pressed.contains(.left) and self.active == .none) {
            const at = mouse.press_pos.get(.left);
            if (rect.contains(at) and clip.contains(at) and self.pressed_window == self.current_window) {
                self.active = widget;
                result.pressed = true;
            }
        }
        if (self.active == widget) {
            self.active_seen = true;
            result.held = true;
            // A release before this frame's press ended the previous hold, not
            // this one; but if the button is up again, the last release did.
            if (mouse.mouse_released.contains(.left) and (!release_first or !mouse.mouse_down.contains(.left))) {
                const at = mouse.release_pos.get(.left);
                result.clicked = rect.contains(at) and clip.contains(at);
                result.held = false;
                self.active = .none;
                self.active_seen = true;
            } else if (!mouse.mouse_down.contains(.left)) {
                // The release was never reported, for example because the
                // window lost focus. Let go rather than stay stuck.
                result.held = false;
                self.active = .none;
            }
        }
        return result;
    }

    /// Returns the innermost layout being filled: a group, window or the root.
    pub fn current(self: *Ui) *LayoutFrame {
        return &self.layouts[self.layout_depth - 1];
    }

    /// Records a group's measure, and asks for another frame if it changed,
    /// since this frame was laid out with the old one.
    pub fn storeMeasure(self: *Ui, group: Id, measure: layout.Measure) void {
        const entry = self.measures.getOrPut(self.allocator, group) catch |err| {
            self.fail(err);
            return;
        };
        if (!entry.found_existing or entry.value_ptr.differs(measure)) {
            self.redraw_requested = true;
            self.layout_changed = true;
        }
        entry.value_ptr.* = measure;
    }

    /// Reserves space in the current layout. Custom widgets combine this with
    /// `interact` and the `draw*` methods.
    pub fn place(self: *Ui, size: Vec2) Rect {
        return self.placeSized(.auto, .auto, size);
    }

    /// Like `place`, with sizing. `natural` is what `.auto` means.
    pub fn placeSized(self: *Ui, width: layout.Size, height: layout.Size, natural: Vec2) Rect {
        self.last_rect = self.current().layout.place(width, height, natural);
        return self.last_rect;
    }

    /// Returns where the most recent widget was placed, for example to
    /// open a popup below it with `openPopupAt`.
    pub fn lastRect(self: *const Ui) Rect {
        return self.last_rect;
    }

    /// Puts the next widget to the right of the previous one, centered on it
    /// if it is shorter. To center a short item that comes first, use a
    /// horizontal group.
    pub fn sameLine(self: *Ui) void {
        self.current().layout.sameLine();
    }

    /// Starts a nested group. Pair with `endGroup`.
    pub fn beginGroup(self: *Ui, options: GroupOptions) void {
        std.debug.assert(self.layout_depth < max_layout_depth);
        const parent = self.current();
        parent.children += 1;
        const group: Id = if (options.id) |name|
            self.id(name)
        else
            @enumFromInt(std.hash.Wyhash.hash(@intFromEnum(parent.id), std.mem.asBytes(&parent.children)));

        const previous = self.measures.get(group) orelse layout.Measure{};
        const p = options.padding;
        // What the content needs, not counting space its `grow` items
        // stretched into: otherwise a filling row could grow but never
        // shrink, pushing what follows a spacer out of view.
        const natural = previous.natural(options.axis, p);

        // A trial run on a copy: `endGroup` does the real one, with the size
        // this frame's content turned out to have.
        var trial = parent.layout;
        const slot = trial.place(options.width, options.height, natural);

        if (options.fill.a != 0 or options.border.a != 0) {
            self.drawRect(.{
                .rect = slot,
                .fill = options.fill,
                .border = options.border,
                .border_width = self.style.border_width,
                .radius = self.style.rounding,
            });
        }

        const horizontal = options.axis == .horizontal;
        const known_w: ?f32 = if (options.width == .auto) null else @max(0, slot.w - 2 * p);
        const known_h: ?f32 = if (options.height == .auto) null else @max(0, slot.h - 2 * p);
        const spacing = options.spacing;
        const item = self.style.item_spacing;
        self.layouts[self.layout_depth] = .{
            .id = group,
            .width = options.width,
            .height = options.height,
            .padding = p,
            .layout = .init(.{
                .origin = .{ .x = slot.x + p, .y = slot.y + p },
                .axis = options.axis,
                .spacing = .{ .x = spacing orelse item.x, .y = spacing orelse item.y },
                .alignment = options.alignment,
                .justify = options.justify,
                .main_extent = if (horizontal) known_w else known_h,
                .cross_extent = if (horizontal) known_h else known_w,
                .previous = previous,
            }),
        };
        self.layout_depth += 1;
    }

    /// Ends the group from `beginGroup`, `beginHorizontal` or `beginVertical`.
    pub fn endGroup(self: *Ui) void {
        std.debug.assert(self.layout_depth > 1); // an end without a begin
        const group = self.current().*;
        self.layout_depth -= 1;
        const measure = group.layout.finish();
        self.storeMeasure(group.id, measure);
        _ = self.current().layout.place(group.width, group.height, measure.natural(group.layout.options.axis, group.padding));
    }

    /// Starts a row. Pair with `endHorizontal`.
    pub fn beginHorizontal(self: *Ui, options: RowOptions) void {
        self.beginGroup(.{
            .id = options.id,
            .axis = .horizontal,
            .width = options.width,
            .height = options.height,
            .padding = options.padding,
            .spacing = options.spacing,
            .alignment = options.alignment,
            .justify = options.justify,
            .fill = options.fill,
            .border = options.border,
        });
    }

    /// Ends a row.
    pub fn endHorizontal(self: *Ui) void {
        self.endGroup();
    }

    /// Starts a column. Pair with `endVertical`.
    pub fn beginVertical(self: *Ui, options: GroupOptions) void {
        var o = options;
        o.axis = .vertical;
        self.beginGroup(o);
    }

    /// Ends a column.
    pub fn endVertical(self: *Ui) void {
        self.endGroup();
    }

    /// Returns the axis that the current layout flows along.
    pub fn currentAxis(self: *Ui) layout.Axis {
        return self.current().layout.options.axis;
    }

    /// Returns the current clip rect.
    pub fn clipRect(self: *const Ui) Rect {
        return self.clip_stack[self.clip_depth - 1];
    }

    /// Restricts drawing and hovering to `rect`, within the current clip.
    /// Pair with `popClip`.
    pub fn pushClip(self: *Ui, rect: Rect) void {
        self.pushClipAbsolute(rect.intersect(self.clipRect()));
    }

    /// Like `pushClip`, but ignores the current clip.
    pub fn pushClipAbsolute(self: *Ui, rect: Rect) void {
        std.debug.assert(self.clip_depth < self.clip_stack.len);
        self.clip_stack[self.clip_depth] = rect;
        self.clip_depth += 1;
        self.list.setClip(rect) catch |err| self.fail(err);
    }

    /// Undoes the matching `pushClip`.
    pub fn popClip(self: *Ui) void {
        std.debug.assert(self.clip_depth > 1);
        self.clip_depth -= 1;
        const restored: ?Rect = if (self.clip_depth == 1) null else self.clipRect();
        self.list.setClip(restored) catch |err| self.fail(err);
    }

    /// Records a rectangle. Skipped if it is entirely clipped away, which
    /// keeps long scrolled lists cheap.
    pub fn drawRect(self: *Ui, cmd: draw.RectCommand) void {
        if (cmd.rect.intersect(self.clipRect()).isEmpty()) return;
        self.list.addRect(cmd) catch |err| self.fail(err);
    }

    /// Records the theme's shadow under a shape at `rect` with corner
    /// `radius`, which will be filled with `fill`. Draw it before the shape.
    pub fn drawShadow(self: *Ui, rect: Rect, radius: f32, fill: draw.Color) void {
        const style = &self.style;
        if (style.colors.shadow.a == 0 or style.shadow_blur <= 0) return;
        const off = style.shadow_offset;
        const shadow: Rect = .{ .x = rect.x + off.x, .y = rect.y + off.y, .w = rect.w, .h = rect.h };
        const reach = shadow.inset(-style.shadow_blur);
        if (reach.intersect(self.clipRect()).isEmpty()) return;
        // An opaque shape hides the shadow under it, apart from its corners.
        const covered: ?Rect = if (fill.a == 255) rect.inset(radius) else null;
        self.list.addShadow(.{ .rect = shadow, .radius = radius, .blur = style.shadow_blur, .color = style.colors.shadow, .covered = covered }) catch |err| self.fail(err);
    }

    /// Records text at the current font size, with `pos` the top-left of the
    /// line box.
    pub fn drawText(self: *Ui, pos: Vec2, color: draw.Color, text: []const u8) void {
        const size = self.style.font_size;
        const line = self.font.lineMetrics(size);
        const box: Rect = .{ .x = pos.x, .y = pos.y, .w = self.clipRect().w + 1, .h = line.ascent + line.descent };
        if (box.y >= self.clipRect().bottom() or box.bottom() <= self.clipRect().y) return;
        self.list.addText(.{
            .font = self.font,
            .pos = .{ .x = pos.x, .y = pos.y + line.ascent },
            .size = size,
            .color = color,
            .text = text,
        }) catch |err| self.fail(err);
    }

    /// Returns a painter for drawing shapes, images and icons into the
    /// current window, popup or canvas.
    pub fn painter(self: *Ui) paint.Painter {
        return .{ .ui = self };
    }

    /// Disables the widgets described until the matching `popDisabled`:
    /// they show faded, ignore clicks and keys, leave the Tab order, and
    /// their tooltip says `reason`. A null reason disables nothing, so a
    /// condition reads naturally:
    ///
    ///     ui.pushDisabled(if (selection.len == 0) "Select an object first" else null);
    ///     defer ui.popDisabled();
    pub fn pushDisabled(self: *Ui, reason: ?[]const u8) void {
        if (self.disabled_depth == max_disabled_depth) {
            std.debug.assert(false); // pushDisabled nested too deep
            return;
        }
        const fade = reason != null and self.disabledReason() == null;
        self.disabled_styled[self.disabled_depth] = fade;
        if (fade) self.pushStyle(self.style.faded());
        self.disabled_stack[self.disabled_depth] = reason;
        self.disabled_depth += 1;
    }

    /// Ends the `pushDisabled` level.
    pub fn popDisabled(self: *Ui) void {
        std.debug.assert(self.disabled_depth > 0); // popDisabled without pushDisabled
        if (self.disabled_depth == 0) return;
        self.disabled_depth -= 1;
        if (self.disabled_styled[self.disabled_depth]) self.popStyle();
    }

    /// Why widgets described now are disabled, or null if they aren't.
    pub fn disabledReason(self: *const Ui) ?[]const u8 {
        var i = self.disabled_depth;
        while (i > 0) {
            i -= 1;
            if (self.disabled_stack[i]) |why| return why;
        }
        return null;
    }

    /// If a disabled widget was clicked last frame, why it is disabled.
    /// BeeModel shows this in its status bar.
    pub fn disabledClick(self: *const Ui) ?[]const u8 {
        const n = self.disabled_click_len orelse return null;
        return self.disabled_click_buffer[0..n];
    }

    /// A widget that was right-clicked last frame, for a context menu that
    /// covers many widgets at once (Reset to Default, Copy Value, ...).
    /// Widgets also report it in `Interaction.context_clicked`.
    pub fn contextRequest(self: *const Ui) ?ContextRequest {
        return self.context_last;
    }

    /// Adds a widget to the record (see `recording`), and makes it the
    /// hovered widget when `details.hovered`. Built-in widgets call this;
    /// custom ones should too, with kind `.custom` or the closest built-in.
    pub fn recordWidget(self: *Ui, kind: record_mod.Kind, widget: Id, label_text: []const u8, rect: Rect, details: record_mod.Details) void {
        record_mod.recordWidget(self, kind, widget, label_text, rect, details);
    }

    /// Like `recordWidget`, with the value formatted from `fmt` and `args`
    /// only when recording.
    pub fn recordWidgetf(self: *Ui, kind: record_mod.Kind, widget: Id, label_text: []const u8, rect: Rect, details: record_mod.Details, comptime fmt: []const u8, args: anytype) void {
        record_mod.recordWidgetf(self, kind, widget, label_text, rect, details, fmt, args);
    }

    /// The widgets the last frame showed, front-most last within each
    /// window. Empty unless `recording` was on. Valid until `beginFrame`.
    pub fn widgets(self: *const Ui) []const record_mod.Widget {
        return self.record.list.items;
    }

    /// Finds a widget of the last frame by `label`, `kind:label` or
    /// `Window > kind:label`. Needs `recording`.
    pub fn findWidget(self: *const Ui, target: []const u8) ?record_mod.Widget {
        return record_mod.find(self.record.list.items, target);
    }

    /// The widget under the pointer last frame, recording or not. Apps use
    /// it to act on whatever is hovered, such as copying a field's value.
    pub fn hoveredWidget(self: *const Ui) ?record_mod.Hovered {
        return self.record.hovered;
    }

    /// Writes the last frame's widgets as JSON or text.
    pub fn writeWidgets(self: *const Ui, writer: *std.Io.Writer, format: record_mod.Format) std.Io.Writer.Error!void {
        try record_mod.write(self.record.list.items, writer, format);
    }

    /// Draws text in `font` until the matching `popFont`, for example a
    /// monospace face for code. Measuring follows the same font.
    pub fn pushFont(self: *Ui, font: *Font) void {
        if (self.font_depth == max_font_depth) {
            std.debug.assert(false); // pushFont nested too deep
            return;
        }
        self.font_stack[self.font_depth] = self.font;
        self.font_depth += 1;
        self.font = font;
    }

    /// Goes back to the font before the last `pushFont`.
    pub fn popFont(self: *Ui) void {
        std.debug.assert(self.font_depth > 0); // popFont without pushFont
        if (self.font_depth == 0) return;
        self.font_depth -= 1;
        self.font = self.font_stack[self.font_depth];
    }

    /// Returns the width and line height of `text` at the current font size.
    pub fn textSize(self: *const Ui, text: []const u8) Vec2 {
        const size = self.style.font_size;
        const line = self.font.lineMetrics(size);
        return .{ .x = self.font.textWidth(text, size), .y = line.ascent + line.descent };
    }

    pub const label = widget_fns.label;
    pub const icon = widget_fns.icon;
    pub const numberField = values.numberField;
    pub const angleField = values.angleField;
    pub const vectorField = values.vectorField;
    pub const dropdown = choice.dropdown;
    pub const dropdownEnum = choice.dropdownEnum;
    pub const segmented = choice.segmented;
    pub const iconToggle = choice.iconToggle;
    pub const beginMenuBar = menus.beginMenuBar;
    pub const endMenuBar = menus.endMenuBar;
    pub const beginMenu = menus.beginMenu;
    pub const beginSubmenu = menus.beginSubmenu;
    pub const endMenu = menus.endMenu;
    pub const menuItem = menus.menuItem;
    pub const menuSeparator = menus.menuSeparator;
    pub const beginPopupMenu = menus.beginPopupMenu;
    pub const beginPopupMenuSized = menus.beginPopupMenuSized;
    pub const holdMenu = menus.holdMenu;
    pub const externalBar = menus.externalBar;
    pub const takeBarRequest = menus.takeBarRequest;
    pub const highlightFirst = menus.highlightFirst;
    pub const windowShownAt = window.shownAt;
    pub const beginContextMenu = menus.beginContextMenu;
    pub const commandPalette = menus.commandPalette;
    pub const shortcutField = menus.shortcutField;
    pub const openPopupBeside = overlay_mod.openPopupBeside;
    pub const beginDockSpace = dock_mod.beginDockSpace;
    pub const endDockSpace = dock_mod.endDockSpace;
    pub const beginArea = dock_mod.beginArea;
    pub const areaBody = dock_mod.areaBody;
    pub const endArea = dock_mod.endArea;
    pub const tabBar = tabs_mod.tabBar;
    pub const beginDialog = feedback.beginDialog;
    pub const endDialog = feedback.endDialog;
    pub const dialogButtons = feedback.dialogButtons;
    pub const dialogOpen = feedback.dialogOpen;
    pub const beginStatusBar = feedback.beginStatusBar;
    pub const endStatusBar = feedback.endStatusBar;
    pub const keyHint = feedback.keyHint;
    pub const toast = feedback.toast;
    pub const clickedToast = feedback.clickedToast;
    pub const progressBar = feedback.progressBar;
    pub const jobChip = feedback.jobChip;
    pub const card = feedback.card;
    pub const beginList = lists.beginList;
    pub const endList = lists.endList;
    pub const beginRow = lists.beginRow;
    pub const endRow = lists.endRow;
    pub const beginTiles = lists.beginTiles;
    pub const tile = lists.tile;
    pub const endTiles = lists.endTiles;
    pub const dragSource = dnd.dragSource;
    pub const dropZone = dnd.dropZone;
    pub const dropHint = dnd.dropHint;
    pub const refuseDrop = dnd.refuseDrop;
    pub const dragging = dnd.dragging;
    pub const fileDrop = dnd.fileDrop;
    pub const wrappedText = textview.wrappedText;
    pub const richText = textview.richText;
    pub const textView = textview.textView;
    pub const consoleInput = textview.consoleInput;
    pub const textArea = textarea.textArea;
    pub const textAreaHeight = textarea.textAreaHeight;
    pub const beginCanvas = canvas.beginCanvas;
    pub const endCanvas = canvas.endCanvas;
    pub const labelf = widget_fns.labelf;
    pub const button = widget_fns.button;
    pub const separator = widget_fns.separator;
    pub const checkbox = widget_fns.checkbox;
    pub const slider = widget_fns.slider;
    pub const beginWindow = window.beginWindow;
    pub const endWindow = window.endWindow;
    pub const spacer = widget_fns.spacer;
    pub const textInput = text_input.textInput;
    pub const saveState = persist.saveState;
    pub const restoreState = persist.restoreState;
    pub const beginScrollArea = containers.beginScrollArea;
    pub const endScrollArea = containers.endScrollArea;
    pub const selectable = containers.selectable;
    pub const treeNode = containers.treeNode;
    pub const treePop = containers.treePop;
    pub const collapsingHeader = containers.collapsingHeader;
    pub const beginTable = containers.beginTable;
    pub const tableRow = containers.tableRow;
    pub const tableNextColumn = containers.tableNextColumn;
    pub const endTable = containers.endTable;
    pub const colorEdit = color_edit.colorEdit;
    pub const colorPicker = color_edit.colorPicker;
    pub const themePreview = theme.themePreview;
    pub const openPie = pie_mod.openPie;
    pub const pie = pie_mod.pie;
    pub const openWheel = pie_mod.openWheel;
    pub const openPieAt = pie_mod.openPieAt;
    pub const openWheelAt = pie_mod.openWheelAt;
    pub const wheel = pie_mod.wheel;
    pub const radialOpen = pie_mod.radialOpen;
    pub const clientFrame = decor.clientFrame;
    pub const beginView2D = view2d.beginView2D;
    pub const endView2D = view2d.endView2D;
    pub const playhead = view2d.playhead;
    pub const frameRange = view2d.frameRange;
    pub const viewHandle = view2d.viewHandle;
    pub const beginMinimap = view2d.beginMinimap;
    pub const endMinimap = view2d.endMinimap;
    pub const imageView = view2d.imageView;
    pub const openPopup = overlay_mod.openPopup;
    pub const openPopupAt = overlay_mod.openPopupAt;
    pub const isPopupOpen = overlay_mod.isPopupOpen;
    pub const closePopup = overlay_mod.closePopup;
    pub const closeAllPopups = overlay_mod.closeAllPopups;
    pub const beginPopup = overlay_mod.beginPopup;
    pub const endPopup = overlay_mod.endPopup;
    pub const tooltip = overlay_mod.tooltip;
    pub const tooltipRich = overlay_mod.tooltipRich;
    pub const tooltipf = overlay_mod.tooltipf;
    pub const showTooltip = overlay_mod.showTooltip;
};
