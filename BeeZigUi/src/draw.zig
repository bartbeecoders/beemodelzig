//! Geometry, colors, draw commands and the `Renderer` interface.
//!
//! The UI never touches pixels. It records a `DrawList`, and a backend replays
//! that list through a `Renderer`. All coordinates in a `DrawList` are logical
//! units; backends multiply by `Frame.scale` to reach physical pixels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Font = @import("font.zig").Font;

/// A 2D point or size.
pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    /// Returns the component-wise sum.
    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    /// Returns the component-wise difference.
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    /// Returns the vector multiplied by `k`.
    pub fn scale(a: Vec2, k: f32) Vec2 {
        return .{ .x = a.x * k, .y = a.y * k };
    }

    /// Returns the length.
    pub fn length(a: Vec2) f32 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }

    /// Returns the point `t` of the way from `a` to `b`.
    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }
};

/// An axis-aligned rectangle. `w` and `h` are never negative in practice;
/// `intersect` clamps them to zero.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    /// Right edge.
    pub fn right(r: Rect) f32 {
        return r.x + r.w;
    }

    /// Bottom edge.
    pub fn bottom(r: Rect) f32 {
        return r.y + r.h;
    }

    /// True if `p` lies inside. The top and left edges are inclusive, the
    /// bottom and right edges exclusive, so adjacent rects never both match.
    pub fn contains(r: Rect, p: Vec2) bool {
        return p.x >= r.x and p.y >= r.y and p.x < r.right() and p.y < r.bottom();
    }

    /// Returns the overlap of two rects, with zero size if they are disjoint.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    /// Returns the rect shrunk by `d` on every side (grown if `d` is negative).
    pub fn inset(r: Rect, d: f32) Rect {
        return .{
            .x = r.x + d,
            .y = r.y + d,
            .w = @max(0, r.w - 2 * d),
            .h = @max(0, r.h - 2 * d),
        };
    }

    /// True if the rect has no area.
    pub fn isEmpty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }
};

/// A straight-alpha, sRGB color.
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    /// Draws nothing.
    pub const transparent: Color = .{ .a = 0 };
    /// Opaque white.
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    /// Opaque black.
    pub const black: Color = .{};

    /// Builds a color from `0xRRGGBB`, fully opaque.
    pub fn hex(rgb: u24) Color {
        return .{
            .r = @truncate(rgb >> 16),
            .g = @truncate(rgb >> 8),
            .b = @truncate(rgb),
        };
    }

    /// True if both colors are the same, alpha included.
    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }

    /// Returns the same color with alpha `a`.
    pub fn withAlpha(c: Color, a: u8) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }
};

/// A filled rectangle with optional border and rounded corners.
pub const RectCommand = struct {
    rect: Rect,
    fill: Color = .transparent,
    border: Color = .transparent,
    /// Drawn inside `rect`. Zero disables the border.
    border_width: f32 = 0,
    /// Corner radius. Clamped by backends to half the shorter side.
    radius: f32 = 0,
};

/// A run of UTF-8 text on one line.
pub const TextCommand = struct {
    font: *Font,
    /// Pen start: left end of the baseline.
    pos: Vec2,
    /// Pixel size in logical units.
    size: f32,
    color: Color,
    text: []const u8,
};

/// A soft shadow: a rounded rect whose edge fades out over `blur` units.
/// Draw it before the shape that casts it.
pub const ShadowCommand = struct {
    /// The shape casting the shadow, usually already offset downwards.
    rect: Rect,
    radius: f32 = 0,
    /// How far outside `rect` the shadow fades to nothing.
    blur: f32 = 8,
    color: Color,
    /// An area that is painted opaquely right after the shadow, usually the
    /// shape casting it. Renderers may skip it, which saves filling the
    /// whole area under a window.
    covered: ?Rect = null,
};

/// A line through `points`, or a filled convex polygon when `width` is 0.
/// Edges are anti-aliased.
pub const PathCommand = struct {
    points: []const Vec2,
    color: Color,
    /// Stroke width in logical units; 0 fills the polygon instead.
    width: f32 = 1,
    /// Joins the last point back to the first.
    closed: bool = false,
    /// Moves the points onto the pixel grid, so that a horizontal or vertical
    /// line covers whole pixels instead of two half-lit rows.
    snap: bool = false,
};

/// A corner of a `MeshCommand` triangle.
pub const MeshVertex = struct {
    pos: Vec2,
    color: Color,
};

/// Triangles with a color per corner, blended across each triangle. Edges are
/// not anti-aliased; use it for gradients and custom shapes.
pub const MeshCommand = struct {
    vertices: []const MeshVertex,
    /// Three per triangle, indexing `vertices`.
    indices: []const u32,
    /// Rounds vertex positions to whole pixels, for crisp rectangles.
    snap: bool = false,
};

/// How an image is sampled when drawn larger or smaller than its pixels.
pub const Filter = enum {
    /// The closest pixel: blocky when enlarged, right for pixel art and 1:1.
    nearest,
    /// Blends the four closest pixels: smooth.
    linear,
    /// `nearest` when the image is drawn at a whole multiple of its size
    /// (100 %, 200 %), `linear` otherwise: pixel-art icons stay crisp
    /// wherever they can.
    auto,

    /// The filter to use for `cmd` drawn `pixel_width` physical pixels wide.
    pub fn resolve(cmd: ImageCommand, pixel_width: f32) Filter {
        if (cmd.filter != .auto) return cmd.filter;
        const source = cmd.uv.w * @as(f32, @floatFromInt(cmd.image.width));
        if (source <= 0) return .linear;
        const ratio = pixel_width / source;
        return if (ratio >= 0.999 and @abs(ratio - @round(ratio)) < 0.01) .nearest else .linear;
    }
};

/// Pixels the app owns, drawn with `DrawList.addImage`.
///
/// Renderers read the pixels while rendering, so they must stay valid until
/// then. A GPU renderer keeps a copy; call `touch` after changing the pixels
/// so it uploads them again.
pub const Image = struct {
    /// Unique per image, from `nextId`. Renderers cache by it.
    id: u32,
    width: u32,
    height: u32,
    format: Format,
    /// `width * height` pixels, row 0 at the top.
    pixels: []const u8,
    /// Bumped by `touch`.
    version: u32 = 0,
    /// Every pixel has alpha 255. Lets renderers skip blending.
    is_opaque: bool = false,

    /// Pixel layouts.
    pub const Format = enum {
        /// `u32` per pixel, `0xAARRGGBB` in native byte order, straight
        /// alpha: the software renderer's own layout.
        argb32,
        /// One coverage byte per pixel, drawn in the tint color (icons, masks).
        alpha8,
    };

    var next_id = std.atomic.Value(u32).init(1);

    /// Returns a fresh image id.
    pub fn nextId() u32 {
        return next_id.fetchAdd(1, .monotonic);
    }

    /// Wraps `0xAARRGGBB` pixels. Not copied.
    pub fn initArgb(pixels: []const u32, width: u32, height: u32) Image {
        std.debug.assert(pixels.len >= @as(usize, width) * height);
        return .{ .id = nextId(), .width = width, .height = height, .format = .argb32, .pixels = std.mem.sliceAsBytes(pixels[0 .. @as(usize, width) * height]) };
    }

    /// Wraps one coverage byte per pixel. Not copied.
    pub fn initAlpha(pixels: []const u8, width: u32, height: u32) Image {
        std.debug.assert(pixels.len >= @as(usize, width) * height);
        return .{ .id = nextId(), .width = width, .height = height, .format = .alpha8, .pixels = pixels[0 .. @as(usize, width) * height] };
    }

    /// Marks the pixels as changed.
    pub fn touch(self: *Image) void {
        self.version +%= 1;
    }

    /// Returns pixel `(x, y)` as `0xAARRGGBB`; alpha images give white with
    /// their coverage as alpha.
    pub fn argbAt(self: *const Image, x: u32, y: u32) u32 {
        const i = @as(usize, y) * self.width + x;
        return switch (self.format) {
            .argb32 => std.mem.bytesAsSlice(u32, self.pixels)[i],
            .alpha8 => (@as(u32, self.pixels[i]) << 24) | 0xFFFFFF,
        };
    }
};

/// An image drawn into `rect`.
pub const ImageCommand = struct {
    image: *const Image,
    rect: Rect,
    /// The part of the image to draw, in 0..1 of its width and height.
    uv: Rect = .{ .w = 1, .h = 1 },
    /// Multiplies every pixel. For `alpha8` images it is the color drawn.
    tint: Color = .white,
    filter: Filter = .linear,
};

/// One recorded drawing operation. Text bytes live in `DrawList.text_bytes`,
/// path points in `DrawList.points`, mesh data in `DrawList.mesh_vertices`
/// and `DrawList.indices`.
pub const Command = union(enum) {
    rect: RectCommand,
    text: struct {
        font: *Font,
        pos: Vec2,
        size: f32,
        color: Color,
        start: u32,
        len: u32,
    },
    /// Restricts following commands to this rect. `null` removes the clip.
    clip: ?Rect,
    shadow: ShadowCommand,
    path: struct {
        start: u32,
        len: u32,
        color: Color,
        width: f32,
        closed: bool,
        snap: bool,
    },
    mesh: struct {
        vertex_start: u32,
        vertex_len: u32,
        index_start: u32,
        index_len: u32,
        snap: bool,
    },
    image: ImageCommand,
};

/// Output size of one frame, passed to `Renderer.begin`.
pub const Frame = struct {
    /// Logical width, the coordinate space of the draw list.
    width: f32,
    /// Logical height.
    height: f32,
    /// Physical pixels per logical unit.
    scale: f32 = 1,
};

/// A growable command buffer. Keeps its capacity across `clear`, so a stable UI
/// does not allocate per frame.
pub const DrawList = struct {
    allocator: Allocator,
    commands: std.ArrayList(Command) = .empty,
    text_bytes: std.ArrayList(u8) = .empty,
    points: std.ArrayList(Vec2) = .empty,
    mesh_vertices: std.ArrayList(MeshVertex) = .empty,
    indices: std.ArrayList(u32) = .empty,

    /// Creates an empty list. `allocator` must outlive it.
    pub fn init(allocator: Allocator) DrawList {
        return .{ .allocator = allocator };
    }

    /// Frees all memory.
    pub fn deinit(self: *DrawList) void {
        self.commands.deinit(self.allocator);
        self.text_bytes.deinit(self.allocator);
        self.points.deinit(self.allocator);
        self.mesh_vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }

    /// Removes all commands, keeping capacity.
    pub fn clear(self: *DrawList) void {
        self.commands.clearRetainingCapacity();
        self.text_bytes.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
        self.mesh_vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
    }

    /// Records a rectangle.
    pub fn addRect(self: *DrawList, cmd: RectCommand) Allocator.Error!void {
        try self.commands.append(self.allocator, .{ .rect = cmd });
    }

    /// Records a soft shadow.
    pub fn addShadow(self: *DrawList, cmd: ShadowCommand) Allocator.Error!void {
        try self.commands.append(self.allocator, .{ .shadow = cmd });
    }

    /// Records text. `cmd.text` is copied, so it may be temporary.
    pub fn addText(self: *DrawList, cmd: TextCommand) Allocator.Error!void {
        const start: u32 = @intCast(self.text_bytes.items.len);
        try self.text_bytes.appendSlice(self.allocator, cmd.text);
        errdefer self.text_bytes.shrinkRetainingCapacity(start);
        try self.commands.append(self.allocator, .{ .text = .{
            .font = cmd.font,
            .pos = cmd.pos,
            .size = cmd.size,
            .color = cmd.color,
            .start = start,
            .len = @intCast(cmd.text.len),
        } });
    }

    /// Commands `start` to `end` as a list of their own, sharing this
    /// list's text, points and meshes. For an app that draws part of a frame
    /// early: BeeModel draws a panel's commands when it draws the area under
    /// it, so its own menus can go over them. Read only; valid until this
    /// list changes.
    pub fn view(self: *const DrawList, start: usize, end: usize) DrawList {
        std.debug.assert(start <= end and end <= self.commands.items.len);
        var v = self.*;
        v.commands.items = self.commands.items[start..end];
        v.commands.capacity = end - start;
        return v;
    }

    /// Appends all of `other`'s commands.
    pub fn append(self: *DrawList, other: *const DrawList) Allocator.Error!void {
        const text_base: u32 = @intCast(self.text_bytes.items.len);
        const point_base: u32 = @intCast(self.points.items.len);
        const vertex_base: u32 = @intCast(self.mesh_vertices.items.len);
        const index_base: u32 = @intCast(self.indices.items.len);
        errdefer {
            self.text_bytes.shrinkRetainingCapacity(text_base);
            self.points.shrinkRetainingCapacity(point_base);
            self.mesh_vertices.shrinkRetainingCapacity(vertex_base);
            self.indices.shrinkRetainingCapacity(index_base);
        }
        try self.text_bytes.appendSlice(self.allocator, other.text_bytes.items);
        try self.points.appendSlice(self.allocator, other.points.items);
        try self.mesh_vertices.appendSlice(self.allocator, other.mesh_vertices.items);
        try self.indices.appendSlice(self.allocator, other.indices.items);
        const first = self.commands.items.len;
        try self.commands.appendSlice(self.allocator, other.commands.items);
        for (self.commands.items[first..]) |*cmd| switch (cmd.*) {
            .text => |*t| t.start += text_base,
            .path => |*p| p.start += point_base,
            .mesh => |*m| {
                m.vertex_start += vertex_base;
                m.index_start += index_base;
            },
            else => {},
        };
    }

    /// Records a path. `cmd.points` is copied.
    pub fn addPath(self: *DrawList, cmd: PathCommand) Allocator.Error!void {
        if (cmd.points.len < 2 or cmd.color.a == 0) return;
        const start: u32 = @intCast(self.points.items.len);
        try self.points.appendSlice(self.allocator, cmd.points);
        errdefer self.points.shrinkRetainingCapacity(start);
        try self.commands.append(self.allocator, .{ .path = .{
            .start = start,
            .len = @intCast(cmd.points.len),
            .color = cmd.color,
            .width = cmd.width,
            .closed = cmd.closed,
            .snap = cmd.snap,
        } });
    }

    /// Starts a path whose points are added in place with `pathPoint`, then
    /// recorded by `endPath`. Avoids a temporary buffer for generated shapes.
    pub fn beginPath(self: *DrawList) u32 {
        return @intCast(self.points.items.len);
    }

    /// Adds a point to the path started by `beginPath`.
    pub fn pathPoint(self: *DrawList, p: Vec2) Allocator.Error!void {
        try self.points.append(self.allocator, p);
    }

    /// Records the path started at `start` (from `beginPath`).
    pub fn endPath(self: *DrawList, start: u32, color: Color, width: f32, closed: bool) Allocator.Error!void {
        const len: u32 = @as(u32, @intCast(self.points.items.len)) - start;
        if (len < 2 or color.a == 0) {
            self.points.shrinkRetainingCapacity(start);
            return;
        }
        errdefer self.points.shrinkRetainingCapacity(start);
        try self.commands.append(self.allocator, .{ .path = .{
            .start = start,
            .len = len,
            .color = color,
            .width = width,
            .closed = closed,
            .snap = false,
        } });
    }

    /// Records a straight line. Horizontal and vertical lines are snapped to
    /// the pixel grid so they stay sharp.
    pub fn addLine(self: *DrawList, a: Vec2, b: Vec2, color: Color, width: f32) Allocator.Error!void {
        try self.addPath(.{ .points = &.{ a, b }, .color = color, .width = width, .snap = a.x == b.x or a.y == b.y });
    }

    /// Records a line broken into dashes `dash` long with `gap` between them.
    pub fn addDashedLine(self: *DrawList, a: Vec2, b: Vec2, color: Color, width: f32, dash: f32, gap: f32) Allocator.Error!void {
        const total = b.sub(a).length();
        if (!(total > 0) or !(dash > 0) or !std.math.isFinite(total) or !std.math.isFinite(dash + gap)) return;
        const snap = a.x == b.x or a.y == b.y;
        // Counted in whole dashes (f32 stops adding past 2^24), and at most
        // as many as could ever show.
        const period = dash + @max(0, gap);
        const count: u32 = @intFromFloat(@min(@ceil(total / period), 100_000));
        for (0..count) |k| {
            const at = @as(f32, @floatFromInt(k)) * period;
            const end = @min(total, at + dash);
            try self.addPath(.{ .points = &.{ a.lerp(b, at / total), a.lerp(b, end / total) }, .color = color, .width = width, .snap = snap });
        }
    }

    /// Records a circle: filled when `width` is 0, else its outline.
    pub fn addCircle(self: *DrawList, center: Vec2, radius: f32, color: Color, width: f32) Allocator.Error!void {
        const n = arcSegments(radius, 2 * std.math.pi);
        const start = self.beginPath();
        errdefer self.points.shrinkRetainingCapacity(start);
        for (0..n) |i| {
            const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * 2 * std.math.pi;
            try self.pathPoint(.{ .x = center.x + @cos(a) * radius, .y = center.y + @sin(a) * radius });
        }
        try self.endPath(start, color, width, true);
    }

    /// Records an arc of a circle from angle `from` to `to`, in radians
    /// clockwise from the +x axis (y points down).
    pub fn addArc(self: *DrawList, center: Vec2, radius: f32, from: f32, to: f32, color: Color, width: f32) Allocator.Error!void {
        const start = self.beginPath();
        errdefer self.points.shrinkRetainingCapacity(start);
        try self.arcPoints(center, radius, from, to);
        try self.endPath(start, color, width, false);
    }

    /// Records a filled pie slice from `from` to `to` (radians, at most half
    /// a turn, as the fill is convex).
    pub fn addPie(self: *DrawList, center: Vec2, radius: f32, from: f32, to: f32, color: Color) Allocator.Error!void {
        const start = self.beginPath();
        errdefer self.points.shrinkRetainingCapacity(start);
        try self.pathPoint(center);
        try self.arcPoints(center, radius, from, to);
        try self.endPath(start, color, 0, true);
    }

    /// Records a filled ring segment between radii `inner` and `outer`,
    /// from `from` to `to` (radians): a wedge of a pie menu.
    pub fn addRingSegment(self: *DrawList, center: Vec2, inner: f32, outer: f32, from: f32, to: f32, color: Color) Allocator.Error!void {
        if (outer <= inner) return;
        try self.addArc(center, (inner + outer) / 2, from, to, color, outer - inner);
    }

    fn arcPoints(self: *DrawList, center: Vec2, radius: f32, from: f32, to: f32) Allocator.Error!void {
        const n = arcSegments(radius, @abs(to - from));
        for (0..n + 1) |i| {
            const a = from + (to - from) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            try self.pathPoint(.{ .x = center.x + @cos(a) * radius, .y = center.y + @sin(a) * radius });
        }
    }

    /// Records a cubic Bézier curve from `p0` to `p3` with control points
    /// `p1` and `p2`.
    pub fn addBezier(self: *DrawList, p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, color: Color, width: f32) Allocator.Error!void {
        // Wang's formula: the fewest pieces that keep every chord within
        // `tolerance` of the curve. A long, gentle node wire needs far fewer
        // pieces than its length suggests.
        const tolerance = 0.1; // units: a fifth of a pixel at 2x
        const d1 = p0.sub(p1.scale(2)).add(p2).length();
        const d2 = p1.sub(p2.scale(2)).add(p3).length();
        const pieces = @ceil(@sqrt(0.75 * @max(d1, d2) / tolerance));
        const n: u32 = if (std.math.isFinite(pieces)) @intFromFloat(std.math.clamp(pieces, 2, 200)) else 2;
        const start = self.beginPath();
        errdefer self.points.shrinkRetainingCapacity(start);
        for (0..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const u = 1 - t;
            const w0 = u * u * u;
            const w1 = 3 * u * u * t;
            const w2 = 3 * u * t * t;
            const w3 = t * t * t;
            try self.pathPoint(.{
                .x = w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x,
                .y = w0 * p0.y + w1 * p1.y + w2 * p2.y + w3 * p3.y,
            });
        }
        try self.endPath(start, color, width, false);
    }

    /// Records triangles. Both slices are copied; `indices` index `vertices`.
    pub fn addMesh(self: *DrawList, cmd: MeshCommand) Allocator.Error!void {
        if (cmd.indices.len < 3) return;
        const vertex_start: u32 = @intCast(self.mesh_vertices.items.len);
        const index_start: u32 = @intCast(self.indices.items.len);
        errdefer {
            self.mesh_vertices.shrinkRetainingCapacity(vertex_start);
            self.indices.shrinkRetainingCapacity(index_start);
        }
        try self.mesh_vertices.appendSlice(self.allocator, cmd.vertices);
        try self.indices.appendSlice(self.allocator, cmd.indices);
        try self.commands.append(self.allocator, .{ .mesh = .{
            .vertex_start = vertex_start,
            .vertex_len = @intCast(cmd.vertices.len),
            .index_start = index_start,
            .index_len = @intCast(cmd.indices.len),
            .snap = cmd.snap,
        } });
    }

    /// Records a rectangle whose four corners have their own colors, blended
    /// in between. A horizontal gradient repeats a color down each side.
    pub fn addGradient(self: *DrawList, rect: Rect, top_left: Color, top_right: Color, bottom_left: Color, bottom_right: Color) Allocator.Error!void {
        try self.addMesh(.{
            .vertices = &.{
                .{ .pos = .{ .x = rect.x, .y = rect.y }, .color = top_left },
                .{ .pos = .{ .x = rect.right(), .y = rect.y }, .color = top_right },
                .{ .pos = .{ .x = rect.right(), .y = rect.bottom() }, .color = bottom_right },
                .{ .pos = .{ .x = rect.x, .y = rect.bottom() }, .color = bottom_left },
            },
            .indices = &.{ 0, 1, 2, 0, 2, 3 },
            .snap = true,
        });
    }

    /// Records an image.
    pub fn addImage(self: *DrawList, cmd: ImageCommand) Allocator.Error!void {
        if (cmd.tint.a == 0 or cmd.rect.isEmpty()) return;
        try self.commands.append(self.allocator, .{ .image = cmd });
    }

    /// Records a clip change. `null` removes the clip.
    pub fn setClip(self: *DrawList, clip: ?Rect) Allocator.Error!void {
        try self.commands.append(self.allocator, .{ .clip = clip });
    }
};

/// How many straight pieces approximate an arc of `angle` radians, enough to
/// look round at up to twice the logical size.
fn arcSegments(radius: f32, angle: f32) u32 {
    const len = @abs(radius * angle);
    return @intFromFloat(std.math.clamp(@ceil(len / 2.5), 3, 512));
}

/// What a backend implements to display a `DrawList`.
///
/// This is a type-erased interface, so `Ui` and application code stay
/// independent of any concrete backend.
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// The backend's entry points.
    pub const VTable = struct {
        /// Called once before any drawing.
        begin: *const fn (ptr: *anyopaque, frame: Frame) void,
        /// Draws one rectangle, honoring the current clip.
        drawRect: *const fn (ptr: *anyopaque, cmd: RectCommand) void,
        /// Draws one run of text, honoring the current clip.
        drawText: *const fn (ptr: *anyopaque, cmd: TextCommand) void,
        /// Sets the clip rect in logical units, or removes it.
        setClip: *const fn (ptr: *anyopaque, clip: ?Rect) void,
        /// Called once after all drawing.
        end: *const fn (ptr: *anyopaque) void,
        /// Draws a soft shadow, honoring the current clip. Optional: a
        /// backend without it draws no shadows.
        drawShadow: ?*const fn (ptr: *anyopaque, cmd: ShadowCommand) void = null,
        /// Draws a line or convex polygon. Optional, like the two below: a
        /// backend without it skips those commands.
        drawPath: ?*const fn (ptr: *anyopaque, cmd: PathCommand) void = null,
        /// Draws colored triangles.
        drawMesh: ?*const fn (ptr: *anyopaque, cmd: MeshCommand) void = null,
        /// Draws an image.
        drawImage: ?*const fn (ptr: *anyopaque, cmd: ImageCommand) void = null,
    };

    /// Replays `list` through the backend.
    pub fn render(self: Renderer, list: *const DrawList, frame: Frame) void {
        self.vtable.begin(self.ptr, frame);
        for (list.commands.items) |cmd| switch (cmd) {
            .rect => |r| self.vtable.drawRect(self.ptr, r),
            .text => |t| self.vtable.drawText(self.ptr, .{
                .font = t.font,
                .pos = t.pos,
                .size = t.size,
                .color = t.color,
                .text = list.text_bytes.items[t.start..][0..t.len],
            }),
            .clip => |c| self.vtable.setClip(self.ptr, c),
            .shadow => |s| if (self.vtable.drawShadow) |f| f(self.ptr, s),
            .path => |p| if (self.vtable.drawPath) |f| f(self.ptr, .{
                .points = list.points.items[p.start..][0..p.len],
                .color = p.color,
                .width = p.width,
                .closed = p.closed,
                .snap = p.snap,
            }),
            .mesh => |m| if (self.vtable.drawMesh) |f| f(self.ptr, .{
                .vertices = list.mesh_vertices.items[m.vertex_start..][0..m.vertex_len],
                .indices = list.indices.items[m.index_start..][0..m.index_len],
                .snap = m.snap,
            }),
            .image => |i| if (self.vtable.drawImage) |f| f(self.ptr, i),
        };
        self.vtable.end(self.ptr);
    }
};

test "rect intersect of disjoint rects is empty" {
    const a: Rect = .{ .w = 10, .h = 10 };
    const b: Rect = .{ .x = 20, .y = 20, .w = 5, .h = 5 };
    try std.testing.expect(a.intersect(b).isEmpty());
}

test "append keeps text pointing at the right bytes" {
    var font: Font = try .initDefault(std.testing.allocator);
    defer font.deinit();
    var a: DrawList = .init(std.testing.allocator);
    defer a.deinit();
    var b: DrawList = .init(std.testing.allocator);
    defer b.deinit();
    try a.addText(.{ .font = &font, .pos = .{}, .size = 10, .color = .white, .text = "first" });
    try b.addText(.{ .font = &font, .pos = .{}, .size = 10, .color = .white, .text = "second" });
    try a.append(&b);
    const t = a.commands.items[1].text;
    try std.testing.expectEqualStrings("second", a.text_bytes.items[t.start..][0..t.len]);
}

test "a view holds a range of commands, its text still where it was" {
    var font: Font = try .initDefault(std.testing.allocator);
    defer font.deinit();
    var a: DrawList = .init(std.testing.allocator);
    defer a.deinit();
    try a.addText(.{ .font = &font, .pos = .{}, .size = 10, .color = .white, .text = "first" });
    try a.addRect(.{ .rect = .{ .w = 4, .h = 4 }, .fill = .white });
    try a.addText(.{ .font = &font, .pos = .{}, .size = 10, .color = .white, .text = "third" });
    const v = a.view(1, 3);
    try std.testing.expectEqual(@as(usize, 2), v.commands.items.len);
    try std.testing.expect(v.commands.items[0] == .rect);
    const t = v.commands.items[1].text;
    try std.testing.expectEqualStrings("third", v.text_bytes.items[t.start..][0..t.len]);
    try std.testing.expectEqual(@as(usize, 0), a.view(3, 3).commands.items.len);
}

test "append moves path points and mesh data along" {
    var a: DrawList = .init(std.testing.allocator);
    defer a.deinit();
    var b: DrawList = .init(std.testing.allocator);
    defer b.deinit();
    try a.addLine(.{}, .{ .x = 1 }, .white, 1);
    try b.addLine(.{ .x = 5 }, .{ .x = 9, .y = 3 }, .white, 1);
    try b.addGradient(.{ .w = 4, .h = 4 }, .white, .black, .white, .black);
    try a.append(&b);
    const p = a.commands.items[1].path;
    try std.testing.expectEqual(@as(f32, 5), a.points.items[p.start].x);
    const m = a.commands.items[2].mesh;
    try std.testing.expectEqual(@as(u32, 0), m.vertex_start);
    try std.testing.expectEqual(@as(u32, 4), m.vertex_len);
    try std.testing.expectEqual(@as(u32, 6), m.index_len);
}

test "an abandoned generated path leaves no points behind" {
    var list: DrawList = .init(std.testing.allocator);
    defer list.deinit();
    try list.addCircle(.{}, 10, .transparent, 0);
    try std.testing.expectEqual(@as(usize, 0), list.points.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}

test "rect contains is half-open" {
    const r: Rect = .{ .x = 1, .y = 1, .w = 2, .h = 2 };
    try std.testing.expect(r.contains(.{ .x = 1, .y = 1 }));
    try std.testing.expect(!r.contains(.{ .x = 3, .y = 2 }));
}
