//! Canvases: areas the app paints itself, with their own mouse handling.
//! A 3D viewport, a timeline or a node graph each start as a canvas.
//!
//!     const c = ui.beginCanvas("view", .{ .height = .px(300) });
//!     defer ui.endCanvas();
//!     if (c.dragging == .middle) pan = pan.add(c.delta);
//!     c.painter.circle(c.toScreen(.{ .x = 50, .y = 50 }), 20, color);

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const ui_mod = @import("ui.zig");
const paint = @import("paint.zig");
const input = @import("input.zig");
const Ui = ui_mod.Ui;
const Vec2 = draw.Vec2;
const Rect = draw.Rect;

/// Options for `beginCanvas`.
pub const CanvasOptions = struct {
    width: layout.Size = .fill,
    height: layout.Size = .{ .fixed = 200 },
    /// Painted before anything else.
    background: draw.Color = .transparent,
    /// Take the mouse wheel while hovered, so it doesn't scroll the window
    /// around the canvas. The amount shows up in `Canvas.wheel`.
    take_wheel: bool = true,
    /// Join the Tab order, so the canvas can take keys.
    focusable: bool = false,
    /// Pointer shape while hovered or dragged.
    cursor: ?ui_mod.Cursor = null,
    /// Put the canvas here (window units) rather than in the layout: for
    /// an app that places its own views. `width` and `height` are ignored.
    rect: ?Rect = null,
};

/// What `beginCanvas` reports about this frame.
pub const Canvas = struct {
    id: ui_mod.Id,
    /// Where the canvas is, in window units. Paint inside it.
    rect: Rect,
    /// The left button, as for any widget: hovered, pressed, held, clicked;
    /// `focused` if `focusable`.
    interaction: ui_mod.Interaction,
    /// The pointer relative to the canvas's top-left corner.
    mouse: Vec2,
    /// How far the pointer moved since the last frame; on the frame a
    /// button goes down over the canvas, since that press. Add it up while
    /// `dragging` to follow a drag.
    delta: Vec2,
    /// Wheel movement while hovered, in lines; zero unless `take_wheel`.
    wheel: Vec2,
    /// The pointer is over the canvas and nothing in front of it.
    hovered: bool,
    /// A button that went down over the canvas and is still held. The
    /// canvas keeps it while the pointer leaves, until the button goes up.
    dragging: ?input.MouseButton,
    /// The right or middle button went down over the canvas this frame.
    right_pressed: bool,
    middle_pressed: bool,
    /// Double click with the left button this frame.
    double_clicked: bool,
    painter: paint.Painter,

    /// A point given relative to the canvas, in window units.
    pub fn toScreen(c: Canvas, p: Vec2) Vec2 {
        return .{ .x = c.rect.x + p.x, .y = c.rect.y + p.y };
    }

    /// A window point relative to the canvas.
    pub fn toLocal(c: Canvas, p: Vec2) Vec2 {
        return .{ .x = p.x - c.rect.x, .y = p.y - c.rect.y };
    }
};

/// Places a canvas and clips drawing to it until `endCanvas`.
pub fn beginCanvas(ui: *Ui, name: []const u8, options: CanvasOptions) Canvas {
    const rect = options.rect orelse ui.placeSized(options.width, options.height, .{ .x = 200, .y = 200 });
    const widget = ui.id(name);
    var result = ui.interact(widget, rect);
    if (options.focusable) ui.focusable(widget, &result);

    const in = &ui.input;
    const clip = ui.clipRect();
    const over = rect.contains(in.mouse_pos) and clip.contains(in.mouse_pos) and ui.hovered_window == ui.current_window;
    const hovered = over and (ui.active == .none or ui.active == widget) and !ui.dead_press;
    var c: Canvas = .{
        .id = widget,
        .rect = rect,
        .interaction = result,
        .mouse = .{ .x = in.mouse_pos.x - rect.x, .y = in.mouse_pos.y - rect.y },
        .delta = ui.mouse_delta,
        .wheel = .{},
        .hovered = hovered,
        .dragging = null,
        .right_pressed = false,
        .middle_pressed = false,
        .double_clicked = result.pressed and in.press_clicks.get(.left) == 2,
        .painter = ui.painter(),
    };

    // The right and middle buttons: a press over the canvas captures that
    // button until it comes up.
    for ([_]input.MouseButton{ .right, .middle }) |b| {
        if (!in.mouse_pressed.contains(b)) continue;
        const at = in.press_pos.get(b);
        const pressed_here = rect.contains(at) and clip.contains(at) and ui.pressed_window == ui.current_window;
        if (!pressed_here) continue;
        if (b == .right) c.right_pressed = true else c.middle_pressed = true;
        ui.canvas_capture = .{ .id = widget, .button = b };
    }
    if (ui.canvas_capture) |cap| {
        if (cap.id == widget) {
            if (in.mouse_down.contains(cap.button)) {
                c.dragging = cap.button;
                ui.canvas_capture_seen = true;
            } else ui.canvas_capture = null;
        }
    }
    if (result.held) c.dragging = .left;
    // On the frame a drag starts, count only the movement since the press:
    // the pointer may have come from far away just before it.
    const pressed: ?input.MouseButton = if (result.pressed) .left else if (c.middle_pressed) .middle else if (c.right_pressed) .right else null;
    if (pressed) |b| c.delta = in.mouse_pos.sub(in.press_pos.get(b));

    if (hovered and options.take_wheel) {
        c.wheel = in.scroll;
        in.scroll = .{};
    }
    if (options.cursor) |shape| {
        if (hovered or c.dragging != null) ui.cursor = shape;
    }
    if (hovered or c.dragging != null) ui.hot = widget;

    if (options.focusable) ui.drawFocusRing(widget, rect);
    ui.recordWidget(.canvas, widget, name, rect, .{ .hovered = hovered, .focused = result.focused });
    ui.pushClip(rect);
    if (options.background.a != 0) ui.drawRect(.{ .rect = rect, .fill = options.background });
    return c;
}

/// Ends the canvas started by `beginCanvas`.
pub fn endCanvas(ui: *Ui) void {
    ui.popClip();
}
