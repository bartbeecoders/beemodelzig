//! Turns path commands into triangles for renderers.
//!
//! Lines and polygons get a one-pixel fringe that fades from the shape's
//! color to transparent, which is how their edges are anti-aliased. A
//! renderer only has to fill triangles with colors blended across them, so
//! the software and OpenGL renderers share this code and draw the same edges.

const std = @import("std");
const draw = @import("draw.zig");
const Allocator = std.mem.Allocator;
const Vec2 = draw.Vec2;
const Color = draw.Color;

/// A triangle corner in physical pixels, y down.
pub const Vertex = struct {
    x: f32,
    y: f32,
    color: Color,
};

/// Reusable buffers. Keep one per renderer so steady frames don't allocate.
pub const Tessellator = struct {
    allocator: Allocator,
    /// Output: three vertices per triangle.
    triangles: std.ArrayList(Vertex) = .empty,
    points: std.ArrayList(Vec2) = .empty,
    normals: std.ArrayList(Vec2) = .empty,

    /// Creates empty buffers.
    pub fn init(allocator: Allocator) Tessellator {
        return .{ .allocator = allocator };
    }

    /// Frees the buffers.
    pub fn deinit(self: *Tessellator) void {
        self.triangles.deinit(self.allocator);
        self.points.deinit(self.allocator);
        self.normals.deinit(self.allocator);
    }

    /// Replaces `triangles` with the triangles of `cmd` drawn at `scale`
    /// physical pixels per logical unit.
    pub fn path(self: *Tessellator, cmd: draw.PathCommand, scale: f32) Allocator.Error!void {
        self.triangles.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
        var width = cmd.width * scale;
        // Snapped lines get a whole number of pixels; odd widths sit on pixel
        // centers, even ones on pixel edges.
        if (cmd.snap and width > 0) width = @max(1, @round(width));
        const odd = @mod(width, 2) == 1;
        for (cmd.points) |p| {
            var q: Vec2 = .{ .x = p.x * scale, .y = p.y * scale };
            if (cmd.snap) q = if (width > 0 and odd)
                .{ .x = @floor(q.x) + 0.5, .y = @floor(q.y) + 0.5 }
            else
                .{ .x = @round(q.x), .y = @round(q.y) };
            // Repeated points have no direction; drop them.
            if (self.points.items.len > 0 and close(self.points.items[self.points.items.len - 1], q)) continue;
            try self.points.append(self.allocator, q);
        }
        if (cmd.closed or width == 0) {
            while (self.points.items.len > 2 and close(self.points.items[0], self.points.items[self.points.items.len - 1])) {
                _ = self.points.pop();
            }
        }
        if (width == 0) {
            if (self.points.items.len >= 3) try self.fillConvex(cmd.color);
        } else if (self.points.items.len >= 2) {
            try self.stroke(cmd.color, width, cmd.closed and self.points.items.len >= 3);
        }
    }

    fn close(a: Vec2, b: Vec2) bool {
        return @abs(a.x - b.x) < 1e-3 and @abs(a.y - b.y) < 1e-3;
    }

    fn emit(self: *Tessellator, a: Vertex, b: Vertex, c: Vertex) Allocator.Error!void {
        try self.triangles.appendSlice(self.allocator, &.{ a, b, c });
    }

    fn quad(self: *Tessellator, a: Vertex, b: Vertex, c: Vertex, d: Vertex) Allocator.Error!void {
        try self.emit(a, b, c);
        try self.emit(a, c, d);
    }

    /// Unit normal of the segment from `a` to `b`: its direction turned a
    /// quarter to the left (in y-down coordinates).
    fn segmentNormal(a: Vec2, b: Vec2) Vec2 {
        const d = b.sub(a);
        const len = d.length();
        if (len == 0) return .{};
        return .{ .x = d.y / len, .y = -d.x / len };
    }

    /// Fills `normals` with each point's join direction: the average of its
    /// segments' normals, lengthened so that offset edges stay parallel to
    /// the segments (a miter), within limits for sharp turns.
    fn joinNormals(self: *Tessellator, closed: bool) Allocator.Error!void {
        const pts = self.points.items;
        const n = pts.len;
        self.normals.clearRetainingCapacity();
        try self.normals.resize(self.allocator, n);
        for (0..n) |i| {
            const before = if (i > 0) segmentNormal(pts[i - 1], pts[i]) else if (closed) segmentNormal(pts[n - 1], pts[0]) else null;
            const after = if (i + 1 < n) segmentNormal(pts[i], pts[i + 1]) else if (closed) segmentNormal(pts[n - 1], pts[0]) else null;
            const a = before orelse after.?;
            const b = after orelse a;
            var m: Vec2 = .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
            const len2 = m.x * m.x + m.y * m.y;
            // A miter is 1/cos(half the turn) long; past about 4 times the
            // width, a hairpin would spike far out, so cap it.
            if (len2 > 1e-6) m = m.scale(@min(1 / len2, 16));
            self.normals.items[i] = m;
        }
    }

    fn stroke(self: *Tessellator, color: Color, width: f32, closed: bool) Allocator.Error!void {
        try self.joinNormals(closed);
        const pts = self.points.items;
        const normals = self.normals.items;
        const n = pts.len;
        // The solid core is width - 1 wide, plus half a pixel of fade on each
        // side: the coverage adds up to `width`. Thinner lines fade their
        // color instead of getting narrower.
        const inner = @max(0, (width - 1) / 2);
        const outer = inner + 1;
        const core = color.withAlpha(@intFromFloat(@as(f32, @floatFromInt(color.a)) * @min(1, width) + 0.5));
        const clear = color.withAlpha(0);

        const Ring = struct { a: Vertex, b: Vertex, c: Vertex, d: Vertex };
        const ring = struct {
            fn at(p: Vec2, m: Vec2, along: Vec2, in: f32, out: f32, solid: Color, faded: Color) Ring {
                // `along` moves the solid part in and the fade out by half a
                // pixel at an open end, so that the end is anti-aliased too.
                return .{
                    .a = .{ .x = p.x + m.x * out - along.x, .y = p.y + m.y * out - along.y, .color = faded },
                    .b = .{ .x = p.x + m.x * in + along.x, .y = p.y + m.y * in + along.y, .color = solid },
                    .c = .{ .x = p.x - m.x * in + along.x, .y = p.y - m.y * in + along.y, .color = solid },
                    .d = .{ .x = p.x - m.x * out - along.x, .y = p.y - m.y * out - along.y, .color = faded },
                };
            }
        };

        const segments = if (closed) n else n - 1;
        var first: Ring = undefined;
        var previous: Ring = undefined;
        for (0..n) |i| {
            var along: Vec2 = .{};
            if (!closed and i == 0) along = unit(pts[1].sub(pts[0])).scale(0.5);
            if (!closed and i == n - 1) along = unit(pts[n - 2].sub(pts[n - 1])).scale(0.5);
            const r = ring.at(pts[i], normals[i], along, inner, outer, core, clear);
            if (i == 0) first = r else try self.band(previous, r);
            previous = r;
            if (!closed and (i == 0 or i == n - 1)) {
                // The end cap: a fade from the solid end outwards.
                const back = along.scale(-2);
                const b2: Vertex = .{ .x = r.b.x + back.x, .y = r.b.y + back.y, .color = clear };
                const c2: Vertex = .{ .x = r.c.x + back.x, .y = r.c.y + back.y, .color = clear };
                if (inner > 0) try self.quad(r.b, r.c, c2, b2);
                try self.emit(r.a, r.b, b2);
                try self.emit(r.d, r.c, c2);
            }
        }
        if (segments == n) try self.band(previous, first);
    }

    /// The three strips between two consecutive rings: fade, core, fade.
    fn band(self: *Tessellator, p: anytype, q: anytype) Allocator.Error!void {
        try self.quad(p.a, q.a, q.b, p.b);
        if (p.b.x != p.c.x or p.b.y != p.c.y or q.b.x != q.c.x or q.b.y != q.c.y) try self.quad(p.b, q.b, q.c, p.c);
        try self.quad(p.c, q.c, q.d, p.d);
    }

    fn fillConvex(self: *Tessellator, color: Color) Allocator.Error!void {
        const pts = self.points.items;
        const n = pts.len;
        var area: f32 = 0;
        for (0..n) |i| {
            const a = pts[i];
            const b = pts[(i + 1) % n];
            area += a.x * b.y - b.x * a.y;
        }
        if (area == 0) return;
        try self.joinNormals(true);
        // With positive area the left-hand normals point outwards.
        const out: f32 = if (area > 0) 0.5 else -0.5;
        const clear = color.withAlpha(0);
        const normals = self.normals.items;
        const inner = struct {
            fn at(p: Vec2, m: Vec2, k: f32, c: Color) Vertex {
                return .{ .x = p.x + m.x * k, .y = p.y + m.y * k, .color = c };
            }
        }.at;
        const hub = inner(pts[0], normals[0], -out, color);
        for (1..n - 1) |i| {
            try self.emit(hub, inner(pts[i], normals[i], -out, color), inner(pts[i + 1], normals[i + 1], -out, color));
        }
        for (0..n) |i| {
            const j = (i + 1) % n;
            try self.quad(
                inner(pts[i], normals[i], -out, color),
                inner(pts[j], normals[j], -out, color),
                inner(pts[j], normals[j], out, clear),
                inner(pts[i], normals[i], out, clear),
            );
        }
    }
};

fn unit(v: Vec2) Vec2 {
    const len = v.length();
    return if (len == 0) .{} else v.scale(1 / len);
}

const testing = std.testing;

/// Sums the area of the triangles, weighted by their mean alpha: how much
/// color they put down. Every triangle here has straight edges, so this is
/// exact for corners that share an alpha.
fn coverage(triangles: []const Vertex) f32 {
    var sum: f32 = 0;
    var i: usize = 0;
    while (i < triangles.len) : (i += 3) {
        const a = triangles[i];
        const b = triangles[i + 1];
        const c = triangles[i + 2];
        const area = @abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2;
        const alpha = (@as(f32, @floatFromInt(a.color.a)) + @as(f32, @floatFromInt(b.color.a)) + @as(f32, @floatFromInt(c.color.a))) / (3 * 255);
        sum += area * alpha;
    }
    return sum;
}

test "a line puts down its width times its length" {
    var t: Tessellator = .init(testing.allocator);
    defer t.deinit();
    for ([_]f32{ 0.5, 1, 2, 3.5 }) |w| {
        try t.path(.{ .points = &.{ .{ .x = 10, .y = 10 }, .{ .x = 50, .y = 10 } }, .color = .white, .width = w }, 1);
        try testing.expectApproxEqAbs(w * 40, coverage(t.triangles.items), w * 40 * 0.03);
    }
}

test "a filled square covers its area" {
    var t: Tessellator = .init(testing.allocator);
    defer t.deinit();
    const square = [_]Vec2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    try t.path(.{ .points = &square, .color = .white, .width = 0 }, 2);
    // 20 x 20 pixels at scale 2, give or take the fringe's corners.
    try testing.expectApproxEqAbs(400, coverage(t.triangles.items), 2);
    // Either winding gives the same result.
    var reversed = square;
    std.mem.reverse(Vec2, &reversed);
    try t.path(.{ .points = &reversed, .color = .white, .width = 0 }, 2);
    try testing.expectApproxEqAbs(400, coverage(t.triangles.items), 2);
}

test "snapped odd-width lines sit on pixel centers" {
    var t: Tessellator = .init(testing.allocator);
    defer t.deinit();
    try t.path(.{ .points = &.{ .{ .x = 2.3, .y = 4.2 }, .{ .x = 9, .y = 4.2 } }, .color = .white, .width = 1, .snap = true }, 1);
    for (t.triangles.items) |v| {
        if (v.color.a == 255) try testing.expectEqual(@as(f32, 4.5), v.y);
    }
}

test "degenerate paths draw nothing" {
    var t: Tessellator = .init(testing.allocator);
    defer t.deinit();
    try t.path(.{ .points = &.{ .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 3 } }, .color = .white }, 1);
    try testing.expectEqual(@as(usize, 0), t.triangles.items.len);
    try t.path(.{ .points = &.{ .{}, .{ .x = 5 }, .{ .x = 10 } }, .color = .white, .width = 0 }, 1);
    try testing.expectEqual(@as(usize, 0), t.triangles.items.len);
}
