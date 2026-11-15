//! Drawing shapes, images and icons from UI code.
//!
//! `ui.painter()` returns a `Painter` that records into whatever the UI is
//! drawing into at that moment (the current window, popup or canvas), clipped
//! like the widgets around it. Coordinates are logical units in window space,
//! the same as `Interaction.rect`. Like widgets, it never returns errors: the
//! first allocation failure comes out of `ui.endFrame()`.

const std = @import("std");
const draw = @import("draw.zig");
const icons = @import("icons.zig");
const Ui = @import("ui.zig").Ui;
const Vec2 = draw.Vec2;
const Rect = draw.Rect;
const Color = draw.Color;

/// Options for `Painter.image`.
pub const ImageOptions = struct {
    /// The part of the image to draw, in 0..1 of its size.
    uv: Rect = .{ .w = 1, .h = 1 },
    /// Multiplies the pixels; for alpha images it is the color drawn.
    tint: Color = .white,
    filter: draw.Filter = .linear,
};

/// Records drawing into the UI's current draw list.
pub const Painter = struct {
    ui: *Ui,

    fn list(self: Painter) *draw.DrawList {
        return self.ui.list;
    }

    fn record(self: Painter, result: std.mem.Allocator.Error!void) void {
        result catch |err| self.ui.fail(err);
    }

    /// True if `bounds` (in logical units) can't be seen: outside the clip.
    pub fn culled(self: Painter, bounds: Rect) bool {
        return bounds.intersect(self.ui.clipRect()).isEmpty();
    }

    /// A rectangle with optional border and rounded corners.
    pub fn rect(self: Painter, cmd: draw.RectCommand) void {
        self.ui.drawRect(cmd);
    }

    /// Text at the current font and size; `pos` is the top-left of the line.
    pub fn text(self: Painter, pos: Vec2, color: Color, s: []const u8) void {
        self.ui.drawText(pos, color, s);
    }

    /// A straight line. Horizontal and vertical lines stay sharp.
    pub fn line(self: Painter, a: Vec2, b: Vec2, color: Color, width: f32) void {
        if (self.culled(boxOf(&.{ a, b }, width))) return;
        self.record(self.list().addLine(a, b, color, width));
    }

    /// A straight line in dashes.
    pub fn dashedLine(self: Painter, a: Vec2, b: Vec2, color: Color, width: f32, dash: f32, gap: f32) void {
        if (self.culled(boxOf(&.{ a, b }, width))) return;
        self.record(self.list().addDashedLine(a, b, color, width, dash, gap));
    }

    /// A line through `points`; `closed` joins the end to the start.
    pub fn polyline(self: Painter, points: []const Vec2, color: Color, width: f32, closed: bool) void {
        if (self.culled(boxOf(points, width))) return;
        self.record(self.list().addPath(.{ .points = points, .color = color, .width = width, .closed = closed }));
    }

    /// A filled convex polygon (any winding). Concave shapes need a mesh.
    pub fn polygon(self: Painter, points: []const Vec2, color: Color) void {
        if (self.culled(boxOf(points, 1))) return;
        self.record(self.list().addPath(.{ .points = points, .color = color, .width = 0, .closed = true }));
    }

    /// A filled circle.
    pub fn circle(self: Painter, center: Vec2, radius: f32, color: Color) void {
        if (self.culled(.{ .x = center.x - radius, .y = center.y - radius, .w = 2 * radius, .h = 2 * radius })) return;
        self.record(self.list().addCircle(center, radius, color, 0));
    }

    /// The outline of a circle.
    pub fn circleOutline(self: Painter, center: Vec2, radius: f32, color: Color, width: f32) void {
        const r = radius + width;
        if (self.culled(.{ .x = center.x - r, .y = center.y - r, .w = 2 * r, .h = 2 * r })) return;
        self.record(self.list().addCircle(center, radius, color, width));
    }

    /// An arc from angle `from` to `to`, in radians clockwise from +x.
    pub fn arc(self: Painter, center: Vec2, radius: f32, from: f32, to: f32, color: Color, width: f32) void {
        self.record(self.list().addArc(center, radius, from, to, color, width));
    }

    /// A filled pie slice of at most half a turn.
    pub fn pie(self: Painter, center: Vec2, radius: f32, from: f32, to: f32, color: Color) void {
        self.record(self.list().addPie(center, radius, from, to, color));
    }

    /// A filled band of a ring between radii `inner` and `outer`: the wedge
    /// of a pie menu.
    pub fn ringSegment(self: Painter, center: Vec2, inner: f32, outer: f32, from: f32, to: f32, color: Color) void {
        self.record(self.list().addRingSegment(center, inner, outer, from, to, color));
    }

    /// A cubic Bézier curve from `p0` to `p3`, pulled towards `p1` and `p2`.
    pub fn bezier(self: Painter, p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, color: Color, width: f32) void {
        // The curve stays inside its control points' box.
        if (self.culled(boxOf(&.{ p0, p1, p2, p3 }, width))) return;
        self.record(self.list().addBezier(p0, p1, p2, p3, color, width));
    }

    /// A rectangle with a color per corner.
    pub fn gradient(self: Painter, r: Rect, top_left: Color, top_right: Color, bottom_left: Color, bottom_right: Color) void {
        if (self.culled(r)) return;
        self.record(self.list().addGradient(r, top_left, top_right, bottom_left, bottom_right));
    }

    /// Triangles with a color per vertex.
    pub fn mesh(self: Painter, vertices: []const draw.MeshVertex, indices: []const u32) void {
        if (vertices.len > 0) {
            var lo = vertices[0].pos;
            var hi = lo;
            for (vertices[1..]) |v| {
                lo = .{ .x = @min(lo.x, v.pos.x), .y = @min(lo.y, v.pos.y) };
                hi = .{ .x = @max(hi.x, v.pos.x), .y = @max(hi.y, v.pos.y) };
            }
            if (self.culled(.{ .x = lo.x, .y = lo.y, .w = hi.x - lo.x, .h = hi.y - lo.y })) return;
        }
        self.record(self.list().addMesh(.{ .vertices = vertices, .indices = indices }));
    }

    /// An image stretched over `r`. The image must stay valid until the
    /// frame is rendered.
    pub fn image(self: Painter, img: *const draw.Image, r: Rect, options: ImageOptions) void {
        if (self.culled(r)) return;
        self.record(self.list().addImage(.{ .image = img, .rect = r, .uv = options.uv, .tint = options.tint, .filter = options.filter }));
    }

    /// An icon fitted into `r`, in `color`.
    pub fn icon(self: Painter, which: icons.Icon, r: Rect, color: Color) void {
        if (self.culled(r)) return;
        self.record(icons.draw(self.list(), which, r, color));
    }
};

/// The box around `points`, grown by `width` (and a pixel of anti-aliasing),
/// for skipping shapes that can't be seen. NaN coordinates give an empty
/// box; the renderer drops them anyway.
fn boxOf(points: []const Vec2, width: f32) Rect {
    if (points.len == 0) return .{};
    var lo = points[0];
    var hi = lo;
    for (points[1..]) |p| {
        lo = .{ .x = @min(lo.x, p.x), .y = @min(lo.y, p.y) };
        hi = .{ .x = @max(hi.x, p.x), .y = @max(hi.y, p.y) };
    }
    const g = @abs(width) + 1;
    return .{ .x = lo.x - g, .y = lo.y - g, .w = hi.x - lo.x + 2 * g, .h = hi.y - lo.y + 2 * g };
}
