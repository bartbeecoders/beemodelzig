//! 2D views: the building block of a timeline, a dope sheet, a graph
//! editor, a UV editor and an image viewer.
//!
//! The app keeps a `View2D` (where it looks and how close) and describes
//! the view each frame. The view pans with the middle button, Ctrl+wheel
//! (sideways) and Shift+wheel (up and down), zooms about the pointer with
//! the wheel, and fits its content with Home. Handles placed inside are
//! dragged in world units; a drag on empty space draws a selection box.
//!
//!     var view: zui.View2D = .{};
//!     const v = ui.beginView2D("graph", &view, .{ .rulers = .{ .x = .frames, .y = .values }, .y_up = true });
//!     ui.playhead(v, &frame, .{});
//!     for (keys) |*k| {
//!         const h = ui.viewHandle(v, k.id, &k.pos, .{ .selected = k.selected, .snap = .{ .x = 1, .y = 0 } });
//!         if (h.interaction.pressed) select(k, ui.input.modifiers.shift);
//!     }
//!     if (ui.endView2D().box) |box| selectInside(box.rect, box.mode);

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const ui_mod = @import("ui.zig");
const input = @import("input.zig");
const paint = @import("paint.zig");
const record = @import("record.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;
const Color = draw.Color;

/// Where a 2D view looks. The app owns it, one per view (per editor area).
pub const View2D = struct {
    /// The world point at the plot's top-left corner (bottom-left with
    /// `y_up`).
    origin: Vec2 = .{},
    /// Screen units per world unit, per axis.
    zoom: Vec2 = .{ .x = 1, .y = 1 },
    /// Fit the content on the first frame shown, and again when the view's
    /// size changes, until the user pans or zooms.
    follow_fit: bool = true,
    /// The plot size last fitted to.
    fitted_size: Vec2 = .{},
    /// Panning with the middle button.
    panning: bool = false,
    /// A selection box being drawn, from this world point.
    box_start: ?Vec2 = null,
    box_mode: BoxMode = .set,
    /// Moving the visible rect in the minimap.
    minimap_drag: bool = false,
};

/// Which axes the wheel zooms.
pub const ZoomAxes = enum { both, x, y };

/// What a ruler labels.
pub const RulerKind = enum {
    /// Whole numbers: frames of a timeline.
    frames,
    /// Numbers with as many decimals as the zoom needs.
    values,
};

/// Options for `beginView2D`.
pub const ViewOptions = struct {
    width: layout.Size = .fill,
    height: layout.Size = .fill,
    /// Zoom limits, screen units per world unit.
    min_zoom: Vec2 = .{ .x = 0.01, .y = 0.01 },
    max_zoom: Vec2 = .{ .x = 1000, .y = 1000 },
    zoom_axes: ZoomAxes = .both,
    /// Keep the same zoom on both axes (images, UV maps).
    keep_aspect: bool = false,
    /// World y grows upwards (curves). Otherwise downwards (images).
    y_up: bool = false,
    /// What Home and the first frame fit, in world units.
    content: ?Rect = null,
    /// The view can't wander away from this world rect.
    limits: ?Rect = null,
    rulers: struct { x: ?RulerKind = null, y: ?RulerKind = null } = .{},
    grid: bool = true,
    background: ?Color = null,
};

/// How a selection box combines with the selection.
pub const BoxMode = enum {
    /// Select what is inside, nothing else.
    set,
    /// Shift: add what is inside.
    add,
    /// Ctrl: deselect what is inside.
    remove,
};

/// A 2D view being described, from `beginView2D`.
pub const ViewFrame = struct {
    id: Id,
    view: *View2D,
    /// The plot: the view without its rulers.
    rect: Rect,
    /// The horizontal ruler along the top, if any.
    ruler_x: ?Rect,
    /// The vertical ruler along the left, if any.
    ruler_y: ?Rect,
    y_up: bool,
    /// The pointer is over the plot.
    hovered: bool,
    /// The pointer in world units.
    mouse: Vec2,
    painter: paint.Painter,

    /// A world point on screen.
    pub fn toScreen(f: ViewFrame, w: Vec2) Vec2 {
        const v = f.view;
        return .{
            .x = f.rect.x + (w.x - v.origin.x) * v.zoom.x,
            .y = if (f.y_up) f.rect.bottom() - (w.y - v.origin.y) * v.zoom.y else f.rect.y + (w.y - v.origin.y) * v.zoom.y,
        };
    }

    /// A screen point in world units.
    pub fn toWorld(f: ViewFrame, s: Vec2) Vec2 {
        const v = f.view;
        return .{
            .x = v.origin.x + (s.x - f.rect.x) / v.zoom.x,
            .y = if (f.y_up) v.origin.y + (f.rect.bottom() - s.y) / v.zoom.y else v.origin.y + (s.y - f.rect.y) / v.zoom.y,
        };
    }

    /// A world rect on screen.
    pub fn rectToScreen(f: ViewFrame, w: Rect) Rect {
        const a = f.toScreen(.{ .x = w.x, .y = w.y });
        const b = f.toScreen(.{ .x = w.right(), .y = w.bottom() });
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .w = @abs(b.x - a.x), .h = @abs(b.y - a.y) };
    }

    /// The world rect in view.
    pub fn visible(f: ViewFrame) Rect {
        const a = f.toWorld(.{ .x = f.rect.x, .y = f.rect.y });
        const b = f.toWorld(.{ .x = f.rect.right(), .y = f.rect.bottom() });
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .w = @abs(b.x - a.x), .h = @abs(b.y - a.y) };
    }
};

/// A finished selection box, from `endView2D`.
pub const BoxSelection = struct {
    /// In world units.
    rect: Rect,
    mode: BoxMode,
};

/// What `endView2D` reports.
pub const ViewResult = struct {
    /// A selection box was let go this frame.
    box: ?BoxSelection = null,
    /// Empty space was clicked (no drag): clear the selection unless
    /// Shift is held. In world units.
    clicked: ?Vec2 = null,
    /// The view moved or zoomed this frame.
    moved: bool = false,
};

/// The view being described; views don't nest.
pub const State = struct {
    frame: ?ViewFrame = null,
    options: ViewOptions = .{},
    moved: bool = false,
};

const ruler_size = 22;
/// Grid lines are at least this far apart on screen.
const min_spacing = 64;

/// Places a 2D view and handles panning and zooming. Draw with
/// `ViewFrame.painter` and `toScreen`; pair with `endView2D`.
pub fn beginView2D(ui: *Ui, name: []const u8, view: *View2D, options: ViewOptions) ViewFrame {
    std.debug.assert(ui.view_state.frame == null); // views don't nest
    const outer = ui.placeSized(options.width, options.height, .{ .x = 400, .y = 300 });
    const widget = ui.id(name);
    var plot = outer;
    var ruler_x: ?Rect = null;
    var ruler_y: ?Rect = null;
    const left: f32 = if (options.rulers.y != null) 48 else 0;
    if (options.rulers.x != null) {
        ruler_x = .{ .x = outer.x + left, .y = outer.y, .w = @max(0, outer.w - left), .h = ruler_size };
        plot.y += ruler_size;
        plot.h = @max(0, plot.h - ruler_size);
    }
    if (options.rulers.y != null) {
        ruler_y = .{ .x = outer.x, .y = plot.y, .w = left, .h = plot.h };
        plot.x += left;
        plot.w = @max(0, plot.w - left);
    }

    var f: ViewFrame = .{
        .id = widget,
        .view = view,
        .rect = plot,
        .ruler_x = ruler_x,
        .ruler_y = ruler_y,
        .y_up = options.y_up,
        .hovered = false,
        .mouse = .{},
        .painter = ui.painter(),
    };
    const in = &ui.input;
    const clip = ui.clipRect();
    const over = outer.contains(in.mouse_pos) and clip.contains(in.mouse_pos) and ui.hovered_window == ui.current_window;
    const free = ui.active == .none and !ui.dead_press;
    f.hovered = over and free and plot.contains(in.mouse_pos);
    const before = view.*;

    if (view.follow_fit and plot.w > 0 and plot.h > 0 and (plot.w != view.fitted_size.x or plot.h != view.fitted_size.y)) {
        view.fitted_size = .{ .x = plot.w, .y = plot.h };
        if (options.content) |content| fit(&f, content, options);
    }
    // The middle button pans, from a press over the view until it is let
    // go; the wheel zooms or, with Ctrl or Shift, pans.
    if (in.mouse_pressed.contains(.middle) and over and ui.pressed_window == ui.current_window) view.panning = true;
    if (!in.mouse_down.contains(.middle)) view.panning = false;
    if (view.panning) {
        view.follow_fit = false;
        view.origin.x -= ui.mouse_delta.x / view.zoom.x;
        view.origin.y += (if (options.y_up) ui.mouse_delta.y else -ui.mouse_delta.y) / view.zoom.y;
        ui.cursor = .move;
        ui.hot = widget;
    }
    if (over and free and (in.scroll.x != 0 or in.scroll.y != 0)) {
        const wheel = in.scroll;
        in.scroll = .{};
        view.follow_fit = false;
        const step = ui.style.scroll_step;
        if (in.modifiers.ctrl) {
            view.origin.x -= wheel.y * step / view.zoom.x;
        } else if (in.modifiers.shift) {
            // Up the wheel, up the view.
            const dy = wheel.y * step / view.zoom.y;
            if (options.y_up) view.origin.y += dy else view.origin.y -= dy;
        } else {
            if (wheel.x != 0) view.origin.x -= wheel.x * step / view.zoom.x;
            if (wheel.y != 0) zoomAbout(&f, in.mouse_pos, std.math.pow(f32, 1.2, wheel.y), options);
        }
    }
    if (over and free and in.keys_pressed.contains(.home) and !ui.wantsKeyboard()) {
        if (options.content) |content| fit(&f, content, options);
        view.follow_fit = true;
        view.fitted_size = .{ .x = plot.w, .y = plot.h };
    }
    clampView(&f, options);
    ui.view_state = .{ .frame = null, .options = options, .moved = !std.meta.eql(before.origin, view.origin) or !std.meta.eql(before.zoom, view.zoom) };
    f.mouse = f.toWorld(in.mouse_pos);
    if (ui.view_state.moved) ui.requestRedraw();

    ui.pushClip(outer);
    const colors = &ui.style.colors;
    ui.drawRect(.{ .rect = plot, .fill = options.background orelse colors.input });
    if (options.grid) drawGrid(ui, f, options);
    if (ruler_x) |r| drawRuler(ui, f, r, .x, options.rulers.x.?);
    if (ruler_y) |r| drawRuler(ui, f, r, .y, options.rulers.y.?);
    var zoom_text: [48]u8 = undefined;
    ui.recordWidget(.view, widget, name, plot, .{ .hovered = f.hovered, .value = std.fmt.bufPrint(&zoom_text, "{d:.2} x {d:.2}", .{ view.zoom.x, view.zoom.y }) catch null });
    ui.pushClip(plot);
    ui.pushIdValue(widget);
    ui.view_state.frame = f;
    return f;
}

/// Ends the view: the background takes presses no handle took, for box
/// selection and clicks on empty space.
pub fn endView2D(ui: *Ui) ViewResult {
    const f = ui.view_state.frame orelse unreachable; // an end without a begin
    ui.view_state.frame = null;
    const view = f.view;
    var result: ViewResult = .{ .moved = ui.view_state.moved };
    const bg = ui.id("##background");
    const item = ui.interact(bg, f.rect);
    const in = &ui.input;
    if (item.pressed) {
        view.box_start = f.toWorld(in.press_pos.get(.left));
        view.box_mode = if (in.modifiers.shift) .add else if (in.modifiers.ctrl) .remove else .set;
    }
    if (view.box_start) |start| {
        const now = f.toWorld(in.mouse_pos);
        const box: Rect = .{ .x = @min(start.x, now.x), .y = @min(start.y, now.y), .w = @abs(now.x - start.x), .h = @abs(now.y - start.y) };
        const screen = f.rectToScreen(box);
        const dragged = screen.w > 3 or screen.h > 3;
        if (item.held or item.pressed) {
            if (dragged) {
                const colors = &ui.style.colors;
                const tint = if (view.box_mode == .remove) colors.warning else colors.accent;
                ui.drawRect(.{ .rect = screen, .fill = tint.withAlpha(40), .border = tint, .border_width = 1 });
            }
            if (in.keys_pressed.contains(.escape)) {
                in.keys_pressed.remove(.escape);
                view.box_start = null;
                ui.active = .none;
            }
        } else {
            if (dragged) result.box = .{ .rect = box, .mode = view.box_mode } else if (item.clicked) result.clicked = now;
            view.box_start = null;
        }
    }
    ui.popId();
    ui.popClip();
    ui.popClip();
    return result;
}

fn zoomAbout(f: *ViewFrame, at: Vec2, factor: f32, options: ViewOptions) void {
    const view = f.view;
    const keep = f.toWorld(at);
    var z = view.zoom;
    switch (options.zoom_axes) {
        .both => z = z.scale(factor),
        .x => z.x *= factor,
        .y => z.y *= factor,
    }
    view.zoom = clampZoom(z, options);
    // Keep the world point under the pointer where it was.
    view.origin.x = keep.x - (at.x - f.rect.x) / view.zoom.x;
    view.origin.y = if (f.y_up) keep.y - (f.rect.bottom() - at.y) / view.zoom.y else keep.y - (at.y - f.rect.y) / view.zoom.y;
}

fn clampZoom(z: Vec2, options: ViewOptions) Vec2 {
    var out: Vec2 = .{
        .x = std.math.clamp(z.x, options.min_zoom.x, options.max_zoom.x),
        .y = std.math.clamp(z.y, options.min_zoom.y, options.max_zoom.y),
    };
    if (options.keep_aspect) {
        const k = @min(out.x, out.y);
        out = .{ .x = k, .y = k };
    }
    return out;
}

/// Zooms and pans so `content` fills the plot, with a margin.
pub fn fit(f: *ViewFrame, content: Rect, options: ViewOptions) void {
    const view = f.view;
    const margin: f32 = 24;
    const w = @max(1, f.rect.w - 2 * margin);
    const h = @max(1, f.rect.h - 2 * margin);
    var z: Vec2 = .{ .x = w / @max(1e-6, content.w), .y = h / @max(1e-6, content.h) };
    if (options.keep_aspect) z = .{ .x = @min(z.x, z.y), .y = @min(z.x, z.y) };
    switch (options.zoom_axes) {
        .x => z.y = view.zoom.y,
        .y => z.x = view.zoom.x,
        .both => {},
    }
    view.zoom = clampZoom(z, options);
    const center: Vec2 = .{ .x = content.x + content.w / 2, .y = content.y + content.h / 2 };
    view.origin.x = center.x - f.rect.w / 2 / view.zoom.x;
    if (options.zoom_axes != .x) view.origin.y = center.y - f.rect.h / 2 / view.zoom.y;
}

fn clampView(f: *ViewFrame, options: ViewOptions) void {
    const lim = options.limits orelse return;
    const view = f.view;
    const span: Vec2 = .{ .x = f.rect.w / view.zoom.x, .y = f.rect.h / view.zoom.y };
    // At least a tenth of the view shows something inside the limits.
    const mx = @min(span.x, lim.w) * 0.1;
    const my = @min(span.y, lim.h) * 0.1;
    view.origin.x = std.math.clamp(view.origin.x, lim.x - span.x + mx, @max(lim.x - span.x + mx, lim.right() - mx));
    view.origin.y = std.math.clamp(view.origin.y, lim.y - span.y + my, @max(lim.y - span.y + my, lim.bottom() - my));
}

/// A step of 1, 2 or 5 times a power of ten, at least `min`.
pub fn niceStep(min: f32, whole: bool) f32 {
    if (!(min > 0)) return 1;
    const p = std.math.pow(f32, 10, @floor(std.math.log10(min)));
    var step = p * 10;
    for ([_]f32{ 1, 2, 5, 10 }) |m| if (p * m >= min) {
        step = p * m;
        break;
    };
    return if (whole) @max(1, @round(step)) else step;
}

fn drawGrid(ui: *Ui, f: ViewFrame, options: ViewOptions) void {
    const colors = &ui.style.colors;
    const p = f.painter;
    const vis = f.visible();
    const major = colors.separator;
    const minor = colors.separator.withAlpha(colors.separator.a / 3);
    for ([_]bool{ true, false }) |vertical_lines| {
        const zoom = if (vertical_lines) f.view.zoom.x else f.view.zoom.y;
        const whole = if (vertical_lines) options.rulers.x == .frames else options.rulers.y == .frames;
        const step = niceStep(min_spacing / zoom, whole);
        const sub = step / 5;
        const lo = if (vertical_lines) vis.x else vis.y;
        const hi = if (vertical_lines) vis.right() else vis.bottom();
        const fine = sub * zoom >= 12 and (!whole or sub >= 1);
        const unit = if (fine) sub else step;
        var v = @floor(lo / unit) * unit;
        var guard: u32 = 0;
        while (v <= hi and guard < 2000) : ({
            v += unit;
            guard += 1;
        }) {
            const is_major = @abs(@mod(v + step / 2, step) - step / 2) < unit * 0.01;
            const col = if (@abs(v) < unit * 0.01) colors.border else if (is_major) major else minor;
            if (vertical_lines) {
                const x = @round(f.toScreen(.{ .x = v, .y = 0 }).x);
                p.line(.{ .x = x, .y = f.rect.y }, .{ .x = x, .y = f.rect.bottom() }, col, 1);
            } else {
                const y = @round(f.toScreen(.{ .x = 0, .y = v }).y);
                p.line(.{ .x = f.rect.x, .y = y }, .{ .x = f.rect.right(), .y = y }, col, 1);
            }
        }
    }
}

/// Formats a ruler or playhead value: whole frames, or as many decimals
/// as `step` needs.
pub fn formatValue(buffer: []u8, v: f32, step: f32, kind: RulerKind) []const u8 {
    if (kind == .frames) return std.fmt.bufPrint(buffer, "{d}", .{@as(i64, @intFromFloat(@round(v)))}) catch "";
    const decimals: usize = if (step >= 1) 0 else @intFromFloat(@min(6, @ceil(-std.math.log10(step) - 1e-4)));
    const clean = if (@abs(v) < step * 1e-3) 0 else v;
    return switch (decimals) {
        0 => std.fmt.bufPrint(buffer, "{d:.0}", .{clean}),
        1 => std.fmt.bufPrint(buffer, "{d:.1}", .{clean}),
        2 => std.fmt.bufPrint(buffer, "{d:.2}", .{clean}),
        3 => std.fmt.bufPrint(buffer, "{d:.3}", .{clean}),
        else => std.fmt.bufPrint(buffer, "{d:.4}", .{clean}),
    } catch "";
}

fn drawRuler(ui: *Ui, f: ViewFrame, r: Rect, axis: enum { x, y }, kind: RulerKind) void {
    const colors = &ui.style.colors;
    ui.drawRect(.{ .rect = r, .fill = colors.title });
    const p = f.painter;
    const vis = f.visible();
    const zoom = if (axis == .x) f.view.zoom.x else f.view.zoom.y;
    const step = niceStep(min_spacing / zoom, kind == .frames);
    const lo = if (axis == .x) vis.x else vis.y;
    const hi = if (axis == .x) vis.right() else vis.bottom();
    var v = @floor(lo / step) * step;
    var buffer: [32]u8 = undefined;
    const small = ui.style.font_size * 0.85;
    ui.pushMetric(.font_size, small);
    defer ui.popStyle();
    var guard: u32 = 0;
    ui.pushClip(r);
    defer ui.popClip();
    while (v <= hi + step and guard < 500) : ({
        v += step;
        guard += 1;
    }) {
        const text = formatValue(&buffer, v, step, kind);
        if (axis == .x) {
            const x = @round(f.toScreen(.{ .x = v, .y = 0 }).x);
            p.line(.{ .x = x, .y = r.bottom() - 6 }, .{ .x = x, .y = r.bottom() }, colors.text_muted, 1);
            ui.drawText(.{ .x = x + 3, .y = r.y + 3 }, colors.text_muted, text);
        } else {
            const y = @round(f.toScreen(.{ .x = 0, .y = v }).y);
            p.line(.{ .x = r.right() - 6, .y = y }, .{ .x = r.right(), .y = y }, colors.text_muted, 1);
            const tw = ui.textSize(text).x;
            ui.drawText(.{ .x = r.right() - 8 - tw, .y = y - ui.textSize(text).y / 2 }, colors.text_muted, text);
        }
    }
}

/// Options for `playhead`.
pub const PlayheadOptions = struct {
    /// Snap to whole frames while scrubbing.
    whole: bool = true,
    color: ?Color = null,
};

/// The current frame as a line across the plot with its number on the
/// ruler. Press or drag on the top ruler to scrub. Needs a top ruler.
pub fn playhead(ui: *Ui, f: ViewFrame, frame: *f32, options: PlayheadOptions) Interaction {
    const ruler = f.ruler_x orelse return .{};
    // The ruler is outside the plot's clip: draw with the view's own.
    ui.popClip();
    defer ui.pushClip(f.rect);
    const widget = ui.id("##playhead");
    const was_held = ui.active == widget;
    var item = ui.interact(widget, ruler);
    item.rect = ruler;
    const before = frame.*;
    if (item.pressed) {
        @memcpy(ui.drag_backup[0..4], std.mem.asBytes(frame));
        item.started = true;
    }
    if (item.held and ui.input.keys_pressed.contains(.escape)) {
        ui.input.keys_pressed.remove(.escape);
        @memcpy(std.mem.asBytes(frame), ui.drag_backup[0..4]);
        ui.active = .none;
        item.held = false;
        item.cancelled = true;
    } else if (item.held) {
        var x = f.toWorld(ui.input.mouse_pos).x;
        if (options.whole) x = @round(x);
        frame.* = x;
        ui.cursor = .resize_ew;
    }
    if (frame.* != before) item.changed = true;
    if ((was_held or item.pressed) and !item.held and !item.cancelled) {
        const start = std.mem.bytesAsValue(f32, ui.drag_backup[0..4]).*;
        if (frame.* != start) item.committed = true else item.cancelled = true;
    }

    const colors = &ui.style.colors;
    const tint = options.color orelse colors.accent;
    const x = @round(f.toScreen(.{ .x = frame.*, .y = 0 }).x);
    if (x >= f.rect.x - 1 and x <= f.rect.right() + 1) {
        ui.pushClip(f.rect);
        f.painter.line(.{ .x = x, .y = f.rect.y }, .{ .x = x, .y = f.rect.bottom() }, tint, 2);
        ui.popClip();
        var buffer: [24]u8 = undefined;
        const text = formatValue(&buffer, frame.*, 1, if (options.whole) .frames else .values);
        const tw = ui.textSize(text).x;
        ui.pushClip(ruler);
        const head: Rect = .{ .x = x - tw / 2 - 6, .y = ruler.y + 1, .w = tw + 12, .h = ruler.h - 2 };
        ui.drawRect(.{ .rect = head, .fill = tint, .radius = 4 });
        ui.drawText(.{ .x = head.x + 6, .y = head.y + (head.h - ui.textSize(text).y) / 2 }, @import("color.zig").textOn(tint), text);
        ui.popClip();
    }
    var buffer: [24]u8 = undefined;
    ui.recordWidget(.playhead, widget, "playhead", ruler, .{ .value = formatValue(&buffer, frame.*, 1, if (options.whole) .frames else .values), .hovered = item.hovered });
    return item;
}

/// Dims the plot outside `start` to `end` (a scene's frame range) and
/// draws the edges. Drag an edge on the ruler to move it.
pub fn frameRange(ui: *Ui, f: ViewFrame, start: *f32, end: *f32) Interaction {
    const colors = &ui.style.colors;
    const a = f.toScreen(.{ .x = start.*, .y = 0 }).x;
    const b = f.toScreen(.{ .x = end.*, .y = 0 }).x;
    const shade = colors.background.withAlpha(120);
    if (a > f.rect.x) ui.drawRect(.{ .rect = .{ .x = f.rect.x, .y = f.rect.y, .w = a - f.rect.x, .h = f.rect.h }, .fill = shade });
    if (b < f.rect.right()) ui.drawRect(.{ .rect = .{ .x = b, .y = f.rect.y, .w = f.rect.right() - b, .h = f.rect.h }, .fill = shade });
    var result: Interaction = .{};
    const ruler = f.ruler_x orelse return result;
    ui.popClip();
    defer ui.pushClip(f.rect);
    ui.pushClip(ruler.inset(-1));
    defer ui.popClip();
    for ([_]*f32{ start, end }, [_][]const u8{ "range start", "range end" }, 0..) |value, label, i| {
        const x = f.toScreen(.{ .x = value.*, .y = 0 }).x;
        const grip: Rect = .{ .x = x - 5, .y = ruler.bottom() - 9, .w = 10, .h = 9 };
        const widget = ui.id(label);
        const was_held = ui.active == widget;
        var item = ui.interact(widget, grip);
        if (item.pressed) {
            item.started = true;
            @memcpy(ui.drag_backup[0..4], std.mem.asBytes(value));
        }
        // Escape puts it back, as for every value dragged.
        if (item.held and ui.input.keys_pressed.contains(.escape)) {
            ui.input.keys_pressed.remove(.escape);
            value.* = std.mem.bytesAsValue(f32, ui.drag_backup[0..4]).*;
            ui.active = .none;
            item.held = false;
            item.changed = true;
            item.cancelled = true;
        }
        if (item.held) {
            var v = @round(f.toWorld(ui.input.mouse_pos).x);
            if (i == 0) v = @min(v, end.* - 1) else v = @max(v, start.* + 1);
            if (v != value.*) {
                value.* = v;
                item.changed = true;
            }
            ui.cursor = .resize_ew;
        }
        // One step only when it moved: a plain click is no edit.
        if ((was_held or item.pressed) and !item.held and !item.cancelled) {
            const before = std.mem.bytesAsValue(f32, ui.drag_backup[0..4]).*;
            if (value.* != before) item.committed = true else item.cancelled = true;
        }
        const col = if (item.hovered or item.held) colors.accent else colors.text_muted;
        f.painter.polygon(&.{ .{ .x = x, .y = ruler.bottom() }, .{ .x = x - 5, .y = ruler.bottom() - 8 }, .{ .x = x + 5, .y = ruler.bottom() - 8 } }, col);
        var buffer: [16]u8 = undefined;
        ui.recordWidget(.handle, widget, label, grip, .{ .value = formatValue(&buffer, value.*, 1, .frames), .hovered = item.hovered });
        result.changed = result.changed or item.changed;
        result.started = result.started or item.started;
        result.committed = result.committed or item.committed;
        result.cancelled = result.cancelled or item.cancelled;
    }
    return result;
}

/// The shape of a handle.
pub const HandleShape = enum { circle, diamond, square };

/// Options for `viewHandle`.
pub const HandleOptions = struct {
    /// Recorded for scripts and agents.
    label: []const u8 = "",
    shape: HandleShape = .circle,
    /// Radius on screen; the same at every zoom.
    size: f32 = 5,
    color: ?Color = null,
    selected: bool = false,
    /// Snap to multiples of this, per axis (0: free). Ctrl turns snapping
    /// off while dragging (or on, if it is null).
    snap: ?Vec2 = null,
    /// Move along this axis only.
    lock_x: bool = false,
    lock_y: bool = false,
};

/// What `viewHandle` reports.
pub const HandleResult = struct {
    interaction: Interaction,
    /// How far the handle moved this frame, in world units: move the
    /// other selected handles by as much. Escape reports the way back.
    delta: Vec2 = .{},
};

/// A draggable point at `pos` (world units): a key, a curve handle, a UV
/// vertex. Easy to grab: the hit area is a few units wider than the dot,
/// at every zoom.
pub fn viewHandle(ui: *Ui, f: ViewFrame, id: u64, pos: *Vec2, options: HandleOptions) HandleResult {
    const s = f.toScreen(pos.*);
    const grab = options.size + 5;
    const hit: Rect = .{ .x = s.x - grab, .y = s.y - grab, .w = 2 * grab, .h = 2 * grab };
    ui.pushIdInt(id);
    const widget = ui.id("##handle");
    ui.popId();
    const was_held = ui.active == widget;
    var item = ui.interact(widget, hit);
    item.rect = hit;
    var result: HandleResult = .{ .interaction = item };
    const backup = std.mem.bytesAsValue(Vec2, ui.drag_backup[0..@sizeOf(Vec2)]);
    const grab_offset = std.mem.bytesAsValue(Vec2, ui.drag_backup[@sizeOf(Vec2) .. 2 * @sizeOf(Vec2)]);
    if (item.pressed) {
        backup.* = pos.*;
        grab_offset.* = pos.sub(f.toWorld(ui.input.press_pos.get(.left)));
        result.interaction.started = true;
    }
    if (item.held) {
        const old = pos.*;
        if (ui.input.keys_pressed.contains(.escape)) {
            ui.input.keys_pressed.remove(.escape);
            pos.* = backup.*;
            ui.active = .none;
            result.interaction.held = false;
            result.interaction.cancelled = true;
        } else {
            var target = f.toWorld(ui.input.mouse_pos).add(grab_offset.*);
            if (options.lock_x) target.x = backup.x;
            if (options.lock_y) target.y = backup.y;
            const snapping = (options.snap != null) != ui.input.modifiers.ctrl;
            if (snapping) {
                const step = options.snap orelse Vec2{ .x = niceStep(8 / f.view.zoom.x, false), .y = niceStep(8 / f.view.zoom.y, false) };
                if (step.x > 0) target.x = @round(target.x / step.x) * step.x;
                if (step.y > 0) target.y = @round(target.y / step.y) * step.y;
            }
            pos.* = target;
            ui.cursor = .move;
        }
        result.delta = pos.sub(old);
        if (result.delta.x != 0 or result.delta.y != 0) result.interaction.changed = true;
    }
    // Let go: one edit if it moved.
    if ((was_held or item.pressed) and !result.interaction.held and !result.interaction.cancelled) {
        if (pos.x != backup.x or pos.y != backup.y) result.interaction.committed = true else result.interaction.cancelled = true;
    }

    const colors = &ui.style.colors;
    const base = options.color orelse colors.text;
    const fill = if (options.selected) colors.accent else base;
    const r = options.size + (if (item.hovered or item.held) @as(f32, 1.5) else 0);
    const p = f.painter;
    const dark = Color.black.withAlpha(150);
    switch (options.shape) {
        .circle => {
            p.circle(s, r + 1.5, dark);
            p.circle(s, r, fill);
        },
        .diamond => {
            const pts = [_]Vec2{ .{ .x = s.x, .y = s.y - r - 1.5 }, .{ .x = s.x + r + 1.5, .y = s.y }, .{ .x = s.x, .y = s.y + r + 1.5 }, .{ .x = s.x - r - 1.5, .y = s.y } };
            p.polygon(&pts, dark);
            const inner = [_]Vec2{ .{ .x = s.x, .y = s.y - r }, .{ .x = s.x + r, .y = s.y }, .{ .x = s.x, .y = s.y + r }, .{ .x = s.x - r, .y = s.y } };
            p.polygon(&inner, fill);
        },
        .square => {
            ui.drawRect(.{ .rect = .{ .x = s.x - r - 1.5, .y = s.y - r - 1.5, .w = 2 * r + 3, .h = 2 * r + 3 }, .fill = dark });
            ui.drawRect(.{ .rect = .{ .x = s.x - r, .y = s.y - r, .w = 2 * r, .h = 2 * r }, .fill = fill });
        },
    }
    var buffer: [48]u8 = undefined;
    const label = if (options.label.len > 0) options.label else "handle";
    ui.recordWidget(.handle, widget, label, hit, .{ .value = std.fmt.bufPrint(&buffer, "{d:.3} {d:.3}", .{ pos.x, pos.y }) catch null, .hovered = item.hovered });
    return result;
}

/// A minimap being described, from `beginMinimap`.
pub const Minimap = struct {
    /// Where the map is on screen.
    rect: Rect,
    content: Rect,
    scale: f32,
    painter: paint.Painter,

    /// A world point on the map.
    pub fn toMap(m: Minimap, w: Vec2) Vec2 {
        return .{ .x = m.rect.x + (w.x - m.content.x) * m.scale, .y = m.rect.y + (w.y - m.content.y) * m.scale };
    }

    /// A world rect on the map.
    pub fn rectToMap(m: Minimap, w: Rect) Rect {
        const a = m.toMap(.{ .x = w.x, .y = w.y });
        return .{ .x = a.x, .y = a.y, .w = w.w * m.scale, .h = w.h * m.scale };
    }
};

/// A small map of `content` (world units) in the plot's bottom-right
/// corner, showing what is in view. Paint the content with `toMap`, then
/// call `endMinimap`, which draws the view's rect: drag on the map to
/// move the view. For views with y growing down.
pub fn beginMinimap(ui: *Ui, f: ViewFrame, content: Rect) Minimap {
    const max: Vec2 = .{ .x = 180, .y = 120 };
    const scale = @min(max.x / @max(1e-6, content.w), max.y / @max(1e-6, content.h));
    const size: Vec2 = .{ .x = content.w * scale, .y = content.h * scale };
    const rect: Rect = .{ .x = f.rect.right() - size.x - 12, .y = f.rect.bottom() - size.y - 12, .w = size.x, .h = size.y };
    const colors = &ui.style.colors;
    ui.drawShadow(rect.inset(-4), 4, colors.popup);
    ui.drawRect(.{ .rect = rect.inset(-4), .fill = colors.popup.withAlpha(235), .border = colors.border, .border_width = 1, .radius = 4 });
    ui.pushClip(rect.inset(-2));
    return .{ .rect = rect, .content = content, .scale = scale, .painter = ui.painter() };
}

/// Ends the minimap: draws the view's rect and moves the view when the
/// map is pressed or dragged.
pub fn endMinimap(ui: *Ui, f: ViewFrame, m: Minimap) void {
    ui.popClip();
    const view = f.view;
    const widget = ui.id("##minimap");
    const item = ui.interact(widget, m.rect.inset(-4));
    if (item.held) {
        // Centre the view on the world point under the pointer.
        const p = ui.input.mouse_pos;
        const w: Vec2 = .{ .x = m.content.x + (p.x - m.rect.x) / m.scale, .y = m.content.y + (p.y - m.rect.y) / m.scale };
        view.origin = .{ .x = w.x - f.rect.w / 2 / view.zoom.x, .y = w.y - f.rect.h / 2 / view.zoom.y };
        view.follow_fit = false;
        ui.cursor = .move;
        ui.requestRedraw();
    }
    const vis = m.rectToMap(f.visible()).intersect(m.rect.inset(-2));
    ui.drawRect(.{ .rect = vis, .fill = ui.style.colors.accent.withAlpha(30), .border = ui.style.colors.accent, .border_width = 1.5 });
    ui.recordWidget(.minimap, widget, "minimap", m.rect, .{ .hovered = item.hovered });
}

/// Options for `imageView`.
pub const ImageViewOptions = struct {
    width: layout.Size = .fill,
    height: layout.Size = .fill,
    /// The most an image pixel can be magnified.
    max_zoom: f32 = 32,
    /// Show the minimap while zoomed in.
    minimap: bool = true,
    background: ?Color = null,
};

/// An image to zoom (up to 32 times, about the pointer) and pan; Home
/// fits it. Pixels stay sharp when magnified. Returns the view, still
/// open for overlays drawn on the image (UVs, a crop), and needing
/// `endView2D`.
pub fn imageView(ui: *Ui, name: []const u8, img: *const draw.Image, view: *View2D, options: ImageViewOptions) ViewFrame {
    const content: Rect = .{ .w = @floatFromInt(img.width), .h = @floatFromInt(img.height) };
    const f = beginView2D(ui, name, view, .{
        .width = options.width,
        .height = options.height,
        .min_zoom = .{ .x = 0.02, .y = 0.02 },
        .max_zoom = .{ .x = options.max_zoom, .y = options.max_zoom },
        .keep_aspect = true,
        .content = content,
        .limits = content,
        .grid = false,
        .background = options.background,
    });
    const screen = f.rectToScreen(content);
    checker(ui, screen.intersect(f.rect));
    f.painter.image(img, screen, .{ .filter = if (view.zoom.x >= 2) .nearest else .linear });
    ui.drawRect(.{ .rect = screen, .border = ui.style.colors.border, .border_width = 1 });
    if (options.minimap and (view.zoom.x * content.w > f.rect.w * 1.05 or view.zoom.y * content.h > f.rect.h * 1.05)) {
        const m = beginMinimap(ui, f, content);
        m.painter.image(img, m.rect, .{ .filter = .linear });
        endMinimap(ui, f, m);
    }
    return f;
}

fn checker(ui: *Ui, r: Rect) void {
    if (r.isEmpty()) return;
    ui.drawRect(.{ .rect = r, .fill = Color.hex(0x9A9A9A) });
    const cell: f32 = 10;
    var y = @floor(r.y / cell) * cell;
    while (y < r.bottom()) : (y += cell) {
        var x = @floor(r.x / cell) * cell + (if (@mod(y / cell, 2) == 0) cell else 0);
        while (x < r.right()) : (x += 2 * cell) {
            const c: Rect = .{ .x = x, .y = y, .w = cell, .h = cell };
            ui.drawRect(.{ .rect = c.intersect(r), .fill = Color.hex(0x7A7A7A) });
        }
    }
}

const testing = std.testing;

test "nice steps" {
    try testing.expectEqual(@as(f32, 1), niceStep(0.7, false));
    try testing.expectEqual(@as(f32, 2), niceStep(1.5, false));
    try testing.expectEqual(@as(f32, 5), niceStep(3, false));
    try testing.expectEqual(@as(f32, 10), niceStep(6, false));
    try testing.expectApproxEqAbs(@as(f32, 0.05), niceStep(0.031, false), 1e-6);
    try testing.expectEqual(@as(f32, 1), niceStep(0.2, true));
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("0.25", formatValue(&buffer, 0.25, 0.05, .values));
    try testing.expectEqualStrings("120", formatValue(&buffer, 120, 10, .values));
    try testing.expectEqualStrings("0.0", formatValue(&buffer, 1e-7, 0.5, .values));
    try testing.expectEqualStrings("24", formatValue(&buffer, 24.4, 1, .frames));
}
