//! CPU rasterizer. Turns draw commands into a 32-bit pixel buffer that can be
//! shown by any window system or written to a file. Pure Zig, no libc.

const std = @import("std");
const zui = @import("zui");
const Allocator = std.mem.Allocator;
const Rect = zui.Rect;
const Color = zui.Color;
const RectCommand = zui.RectCommand;

pub const png = @import("png.zig");

/// An owned framebuffer plus the `zui.Renderer` that draws into it.
///
/// Pixels are `0xFFRRGGBB` in native endianness, row 0 at the top.
pub const SoftwareRenderer = struct {
    allocator: Allocator,
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// Cleared to this at the start of each frame. Opaque colors only.
    clear_color: Color = Color.hex(0x202226),
    /// Clear before drawing. Turn it off to draw Zui over what an app has
    /// already drawn into the buffer (see `useBuffer`).
    clear: bool = true,
    /// The pixels belong to the renderer (false after `useBuffer`).
    owned: bool = true,

    scale: f32 = 1,
    clip: PixelRect = .{},
    tess: zui.tessellate.Tessellator,

    const PixelRect = struct { x0: i32 = 0, y0: i32 = 0, x1: i32 = 0, y1: i32 = 0 };

    /// Creates an empty renderer. Call `resize` before rendering.
    pub fn init(allocator: Allocator) SoftwareRenderer {
        return .{ .allocator = allocator, .tess = .init(allocator) };
    }

    /// Frees the framebuffer.
    pub fn deinit(self: *SoftwareRenderer) void {
        if (self.owned) self.allocator.free(self.pixels);
        self.tess.deinit();
    }

    /// The pixel at (`x`, `y`) in physical pixels, or null outside the
    /// framebuffer. For the eyedropper.
    pub fn pixelAt(self: *const SoftwareRenderer, x: i32, y: i32) ?Color {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return null;
        const p = self.pixels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))];
        return .{ .r = @truncate(p >> 16), .g = @truncate(p >> 8), .b = @truncate(p), .a = 255 };
    }

    /// Sets the framebuffer size in physical pixels. Contents become undefined.
    /// After `useBuffer`, this goes back to a buffer of the renderer's own.
    pub fn resize(self: *SoftwareRenderer, width: u32, height: u32) Allocator.Error!void {
        if (self.owned and width == self.width and height == self.height) return;
        const count = @as(usize, width) * height;
        if (self.owned) {
            self.pixels = try self.allocator.realloc(self.pixels, count);
        } else {
            self.pixels = try self.allocator.alloc(u32, count);
            self.owned = true;
        }
        self.width = width;
        self.height = height;
    }

    /// Draws into `pixels` from now on: `width * height` pixels of
    /// `0xAARRGGBB`, row 0 at the top, owned by the caller. For an app that
    /// owns its window and its framebuffer (a Wayland shm buffer, a game's
    /// screen): set `clear = false` to draw the UI over the app's own
    /// pixels. The target is taken to be opaque: blending works in sRGB
    /// without gamma and leaves every pixel's alpha at 255, which is right for
    /// a window's framebuffer but not for a transparent layer.
    pub fn useBuffer(self: *SoftwareRenderer, pixels: []u32, width: u32, height: u32) void {
        std.debug.assert(pixels.len >= @as(usize, width) * height);
        if (self.owned) self.allocator.free(self.pixels);
        self.pixels = pixels[0 .. @as(usize, width) * height];
        self.width = width;
        self.height = height;
        self.owned = false;
    }

    /// Returns the type-erased interface.
    pub fn renderer(self: *SoftwareRenderer) zui.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: zui.Renderer.VTable = .{
        .begin = begin,
        .drawRect = drawRect,
        .drawText = drawText,
        .setClip = setClip,
        .end = end,
        .drawShadow = drawShadow,
        .drawPath = drawPath,
        .drawMesh = drawMesh,
        .drawImage = drawImage,
    };

    fn drawPath(ptr: *anyopaque, cmd: zui.PathCommand) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        // Out of memory: skip the shape rather than lose the frame.
        self.tess.path(cmd, self.scale) catch return;
        const tris = self.tess.triangles.items;
        var i: usize = 0;
        while (i + 2 < tris.len) : (i += 3) self.fillTriangle(tris[i], tris[i + 1], tris[i + 2]);
    }

    fn drawMesh(ptr: *anyopaque, cmd: zui.MeshCommand) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        var i: usize = 0;
        while (i + 2 < cmd.indices.len) : (i += 3) {
            var corners: [3]zui.tessellate.Vertex = undefined;
            for (&corners, cmd.indices[i..][0..3]) |*c, index| {
                if (index >= cmd.vertices.len) return;
                const v = cmd.vertices[index];
                c.* = meshCorner(v, self.scale, cmd.snap);
            }
            self.fillTriangle(corners[0], corners[1], corners[2]);
        }
    }

    fn drawImage(ptr: *anyopaque, cmd: zui.ImageCommand) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        drawImageInto(self, cmd);
    }

    /// Fills a triangle, blending the corner colors across it. Pixels are
    /// sampled at their centers; a pixel exactly on an edge belongs to the
    /// triangle only if that edge is a top or left edge, so triangles that
    /// share an edge never both draw it, and the fringe of a path shows no
    /// seams.
    fn fillTriangle(self: *SoftwareRenderer, v0: zui.tessellate.Vertex, v1_in: zui.tessellate.Vertex, v2_in: zui.tessellate.Vertex) void {
        if (v0.color.a == 0 and v1_in.color.a == 0 and v2_in.color.a == 0) return;
        // A corner that isn't a number (a 3D point projected from the camera
        // plane) leaves nothing to draw.
        inline for (.{ v0, v1_in, v2_in }) |v| {
            if (!std.math.isFinite(v.x) or !std.math.isFinite(v.y)) return;
        }
        // Fixed point with 8 fraction bits, so that shared edges compute
        // exactly the same values from either side. Corners are kept within
        // 2^22 pixels, so the edge products stay inside i64.
        const fx = struct {
            fn f(v: f32) i64 {
                const lim: f32 = 1 << 22;
                return @intFromFloat(@round(std.math.clamp(v, -lim, lim) * 256));
            }
        }.f;
        var v1 = v1_in;
        var v2 = v2_in;
        const p0 = [2]i64{ fx(v0.x), fx(v0.y) };
        var p1 = [2]i64{ fx(v1.x), fx(v1.y) };
        var p2 = [2]i64{ fx(v2.x), fx(v2.y) };
        var area = edge(p0, p1, p2);
        if (area == 0) return;
        if (area < 0) {
            std.mem.swap(zui.tessellate.Vertex, &v1, &v2);
            std.mem.swap([2]i64, &p1, &p2);
            area = -area;
        }
        const clip = self.clip;
        const min_x = @max(clip.x0, @as(i32, @intCast(@divFloor(@min(p0[0], p1[0], p2[0]), 256))));
        const min_y = @max(clip.y0, @as(i32, @intCast(@divFloor(@min(p0[1], p1[1], p2[1]), 256))));
        const max_x = @min(clip.x1 - 1, @as(i32, @intCast(@divFloor(@max(p0[0], p1[0], p2[0]), 256))));
        const max_y = @min(clip.y1 - 1, @as(i32, @intCast(@divFloor(@max(p0[1], p1[1], p2[1]), 256))));
        if (max_x < min_x or max_y < min_y) return;

        const bias0: i64 = if (topLeft(p1, p2)) 0 else -1;
        const bias1: i64 = if (topLeft(p2, p0)) 0 else -1;
        const bias2: i64 = if (topLeft(p0, p1)) 0 else -1;
        const inv_area = 1 / @as(f32, @floatFromInt(area));
        const same = std.meta.eql(v0.color, v1.color) and std.meta.eql(v0.color, v2.color);
        // Path fringes vary only in alpha.
        const same_rgb = v0.color.withAlpha(0).eql(v1.color.withAlpha(0)) and v0.color.withAlpha(0).eql(v2.color.withAlpha(0));
        const a0: f32 = @floatFromInt(v0.color.a);
        const a1: f32 = @floatFromInt(v1.color.a);
        const a2: f32 = @floatFromInt(v2.color.a);
        const c0 = channels(v0.color);
        const c1 = channels(v1.color);
        const c2 = channels(v2.color);

        // Edge values change by a constant per pixel step, so walk them
        // instead of recomputing three products per pixel.
        const step_x = [3]i64{ -(p2[1] - p1[1]) * 256, -(p0[1] - p2[1]) * 256, -(p1[1] - p0[1]) * 256 };
        var y = min_y;
        while (y < max_y + 1) : (y += 1) {
            const row = self.pixels[@as(usize, @intCast(y)) * self.width..][0..self.width];
            const start = [2]i64{ @as(i64, min_x) * 256 + 128, @as(i64, y) * 256 + 128 };
            var w0 = edge(p1, p2, start);
            var w1 = edge(p2, p0, start);
            const w2 = edge(p0, p1, start);
            // Solve each edge for the pixels of this row that are inside,
            // so thin slanted triangles don't scan their whole bounding box.
            var k_lo: i64 = 0;
            var k_hi: i64 = max_x - min_x;
            for ([3]i64{ w0 + bias0, w1 + bias1, w2 + bias2 }, step_x) |w, st| {
                if (st > 0) {
                    k_lo = @max(k_lo, -@divFloor(w, st));
                } else if (st < 0) {
                    k_hi = @min(k_hi, @divFloor(w, -st));
                } else if (w < 0) k_hi = -1;
            }
            if (k_hi < k_lo) continue;
            w0 += step_x[0] * k_lo;
            w1 += step_x[1] * k_lo;
            const span_end = min_x + @as(i32, @intCast(k_hi));
            const x_start = min_x + @as(i32, @intCast(k_lo));
            // The span solved above is exact: every pixel in it passes all
            // three edge tests, so no per-pixel test is needed.
            const span = row[@intCast(x_start)..@intCast(span_end + 1)];
            if (same) {
                fillSpan(span, v0.color);
                continue;
            }
            const fw0: f32 = @floatFromInt(w0);
            const fw1: f32 = @floatFromInt(w1);
            const db0 = @as(f32, @floatFromInt(step_x[0])) * inv_area;
            const db1 = @as(f32, @floatFromInt(step_x[1])) * inv_area;
            const b0_start = fw0 * inv_area;
            const b1_start = fw1 * inv_area;
            if (same_rgb) {
                // alpha(k) = a0*b0 + a1*b1 + a2*(1-b0-b1), linear in k.
                const al0 = a2 + (a0 - a2) * b0_start + (a1 - a2) * b1_start + 0.5;
                const dal = (a0 - a2) * db0 + (a1 - a2) * db1;
                for (span, 0..) |*p, k| {
                    const a: u8 = @intFromFloat(std.math.clamp(al0 + dal * @as(f32, @floatFromInt(k)), 0, 255));
                    if (a != 0) blendByte(p, v0.color, a);
                }
                continue;
            }
            for (span, 0..) |*p, k| {
                const kf: f32 = @floatFromInt(k);
                const b0 = b0_start + db0 * kf;
                const b1 = b1_start + db1 * kf;
                const b2 = 1 - b0 - b1;
                var c: Color = undefined;
                inline for (.{ "r", "g", "b", "a" }, 0..) |name, ch| {
                    @field(c, name) = @intFromFloat(std.math.clamp(c0[ch] * b0 + c1[ch] * b1 + c2[ch] * b2 + 0.5, 0, 255));
                }
                if (c.a != 0) blendByte(p, c, c.a);
            }
        }
    }

    fn begin(ptr: *anyopaque, frame: zui.Frame) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        self.scale = frame.scale;
        self.clip = self.fullClip();
        if (self.clear) fillOpaque(self.pixels, packOpaque(self.clear_color));
    }

    fn end(_: *anyopaque) void {}

    fn fullClip(self: *const SoftwareRenderer) PixelRect {
        return .{ .x1 = @intCast(self.width), .y1 = @intCast(self.height) };
    }

    /// Converts logical units to whole pixels, intersected with the framebuffer.
    fn toPixels(self: *const SoftwareRenderer, r: Rect) PixelRect {
        const full = self.fullClip();
        return .{
            .x0 = @max(full.x0, roundToInt(r.x * self.scale)),
            .y0 = @max(full.y0, roundToInt(r.y * self.scale)),
            .x1 = @min(full.x1, roundToInt(r.right() * self.scale)),
            .y1 = @min(full.y1, roundToInt(r.bottom() * self.scale)),
        };
    }

    fn setClip(ptr: *anyopaque, clip: ?Rect) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        self.clip = if (clip) |c| self.toPixels(c) else self.fullClip();
    }

    fn drawShadow(ptr: *anyopaque, cmd: zui.ShadowCommand) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        if (cmd.color.a == 0) return;
        if (!finiteRect(cmd.rect) or !std.math.isFinite(cmd.radius) or !std.math.isFinite(cmd.blur)) return;
        const s = self.scale;
        const x0 = cmd.rect.x * s;
        const y0 = cmd.rect.y * s;
        const x1 = cmd.rect.right() * s;
        const y1 = cmd.rect.bottom() * s;
        if (x1 <= x0 or y1 <= y0) return;
        const radius = std.math.clamp(cmd.radius * s, 0, @min(x1 - x0, y1 - y0) / 2);
        const blur = @max(0.5, cmd.blur * s);

        const clip = self.clip;
        const left = @max(clip.x0, roundToInt(x0 - blur));
        const top = @max(clip.y0, roundToInt(y0 - blur));
        const right = @min(clip.x1, roundToInt(x1 + blur));
        const bottom = @min(clip.y1, roundToInt(y1 + blur));
        if (right <= left or bottom <= top) return;

        // Distance to a rounded rect: measure from the inner box whose
        // corners are the centers of the rounded corners.
        const cx = (x0 + x1) / 2;
        const cy = (y0 + y1) / 2;
        const half_w = (x1 - x0) / 2 - radius;
        const half_h = (y1 - y0) / 2 - radius;

        // The covered area in whole pixels, rounded inwards.
        var hole: PixelRect = .{};
        if (cmd.covered) |cov| hole = .{
            .x0 = @intFromFloat(std.math.clamp(@ceil(cov.x * s), -1e9, 1e9)),
            .y0 = @intFromFloat(std.math.clamp(@ceil(cov.y * s), -1e9, 1e9)),
            .x1 = @intFromFloat(std.math.clamp(@floor(cov.right() * s), -1e9, 1e9)),
            .y1 = @intFromFloat(std.math.clamp(@floor(cov.bottom() * s), -1e9, 1e9)),
        };

        // In rows level with the flat sides (dy == 0) coverage depends on
        // the column alone: compute those alphas once.
        const max_side = 256;
        var side_alpha: [max_side]u8 = undefined;
        var side_valid = false;
        var side_lo: i32 = 0;
        var side_hi: i32 = 0;

        var y = top;
        while (y < bottom) : (y += 1) {
            const row = self.pixels[@as(usize, @intCast(y)) * self.width..][0..self.width];
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const dy = @max(0, @abs(py - cy) - half_h);
            if (dy == 0) {
                const fx0 = std.math.clamp(toI(@ceil(cx - half_w - 0.5)), left, right);
                const fx1 = std.math.clamp(toI(@floor(cx + half_w - 0.5)) + 1, fx0, right);
                const nl: usize = @intCast(fx0 - left);
                const nr: usize = @intCast(right - fx1);
                if (nl + nr <= max_side) {
                    if (!side_valid or side_lo != fx0 or side_hi != fx1) {
                        var i: usize = 0;
                        var x = left;
                        while (x < right) : (x += 1) {
                            if (x == fx0) x = fx1;
                            if (x >= right) break;
                            const px = @as(f32, @floatFromInt(x)) + 0.5;
                            const dx = @max(0, @abs(px - cx) - half_w);
                            const cov = shadowCoverage(dx - radius, blur);
                            side_alpha[i] = if (cov > 0) @intFromFloat(@as(f32, @floatFromInt(cmd.color.a)) * cov + 0.5) else 0;
                            i += 1;
                        }
                        side_valid = true;
                        side_lo = fx0;
                        side_hi = fx1;
                    }
                    for (row[@intCast(left)..@intCast(fx0)], side_alpha[0..nl]) |*p, al| blendByte(p, cmd.color, al);
                    for (row[@intCast(fx1)..@intCast(right)], side_alpha[nl..][0..nr]) |*p, al| blendByte(p, cmd.color, al);
                    if (fx1 > fx0) {
                        const in_hole = y >= hole.y0 and y < hole.y1 and hole.x1 > hole.x0;
                        if (in_hole) {
                            const h0 = std.math.clamp(hole.x0, fx0, fx1);
                            const h1 = std.math.clamp(hole.x1, h0, fx1);
                            fillSpan(row[@intCast(fx0)..@intCast(h0)], cmd.color);
                            fillSpan(row[@intCast(h1)..@intCast(fx1)], cmd.color);
                        } else fillSpan(row[@intCast(fx0)..@intCast(fx1)], cmd.color);
                    }
                    continue;
                }
            }
            const in_hole_row = y >= hole.y0 and y < hole.y1 and hole.x1 > hole.x0;
            // Between the corners the distance depends on the row alone, so
            // that stretch gets one coverage value: solid inside the shape,
            // a constant fade above and below it. Only the corners and the
            // side fades need a distance per pixel.
            const flat_x0 = std.math.clamp(toI(@ceil(cx - half_w - 0.5)), left, right);
            const flat_x1 = std.math.clamp(toI(@floor(cx + half_w - 0.5)) + 1, flat_x0, right);
            const flat_cover = shadowCoverage(dy - radius, blur);
            var x = left;
            while (x < right) : (x += 1) {
                if (x == flat_x0 and flat_x1 > flat_x0) {
                    const span = row[@intCast(flat_x0)..@intCast(flat_x1)];
                    if (flat_cover >= 1) {
                        if (in_hole_row) {
                            // Fill only the parts the shape won't cover.
                            const h0 = std.math.clamp(hole.x0, flat_x0, flat_x1);
                            const h1 = std.math.clamp(hole.x1, h0, flat_x1);
                            fillSpan(row[@intCast(flat_x0)..@intCast(h0)], cmd.color);
                            fillSpan(row[@intCast(h1)..@intCast(flat_x1)], cmd.color);
                        } else fillSpan(span, cmd.color);
                    } else if (flat_cover > 0) {
                        const alpha: u8 = @intFromFloat(@as(f32, @floatFromInt(cmd.color.a)) * flat_cover + 0.5);
                        blendSpan(span, cmd.color, alpha);
                    }
                    x = flat_x1 - 1;
                    continue;
                }
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const dx = @max(0, @abs(px - cx) - half_w);
                const coverage = shadowCoverage(@sqrt(dx * dx + dy * dy) - radius, blur);
                if (coverage > 0) blend(&row[@intCast(x)], cmd.color, coverage);
            }
        }
    }

    fn drawText(ptr: *anyopaque, cmd: zui.TextCommand) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        if (cmd.color.a != 0) blitText(self, cmd);
    }

    fn drawRect(ptr: *anyopaque, cmd: RectCommand) void {
        const self: *SoftwareRenderer = @ptrCast(@alignCast(ptr));
        if (cmd.fill.a == 0 and (cmd.border.a == 0 or cmd.border_width <= 0)) return;
        if (!finiteRect(cmd.rect) or !std.math.isFinite(cmd.radius) or !std.math.isFinite(cmd.border_width)) return;

        // Snap the outer edges to pixels so that plain rects stay crisp and
        // neighbouring rects never overlap or leave a gap.
        const x0: f32 = @round(cmd.rect.x * self.scale);
        const y0: f32 = @round(cmd.rect.y * self.scale);
        const x1: f32 = @round(cmd.rect.right() * self.scale);
        const y1: f32 = @round(cmd.rect.bottom() * self.scale);
        if (x1 <= x0 or y1 <= y0) return;

        const radius = std.math.clamp(cmd.radius * self.scale, 0, @min(x1 - x0, y1 - y0) / 2);
        const border = if (cmd.border.a == 0) 0 else @max(0, cmd.border_width * self.scale);

        const shape: Shape = .{
            .x0 = x0,
            .y0 = y0,
            .x1 = x1,
            .y1 = y1,
            .radius = radius,
            .border = border,
            .fill = cmd.fill,
            .edge = cmd.border,
        };

        const clip = self.clip;
        const left = @max(clip.x0, toI(x0));
        const top = @max(clip.y0, toI(y0));
        const right = @min(clip.x1, toI(x1));
        const bottom = @min(clip.y1, toI(y1));
        if (right <= left or bottom <= top) return;

        // Pixels further than `margin` from every edge are plain fill, so only
        // the perimeter pays for the per-pixel distance test.
        const margin: i32 = toI(@ceil(@max(radius, border)));
        const inner_left = toI(x0) + margin;
        const inner_right = toI(x1) - margin;
        const inner_top = toI(y0) + margin;
        const inner_bottom = toI(y1) - margin;

        // Columns strictly between the corners: coverage there depends on
        // the row alone. Rows strictly between the corners: on the column
        // alone, so the side fades are computed once and reused per row.
        const mid_x0 = std.math.clamp(inner_left, left, right);
        const mid_x1 = std.math.clamp(inner_right, mid_x0, right);
        const max_side = 64;
        var side: [2 * max_side][2]u8 = undefined;
        const nl: usize = @intCast(mid_x0 - left);
        const nr: usize = @intCast(right - mid_x1);
        const use_table = nl <= max_side and nr <= max_side and inner_bottom - inner_top > 2;
        if (use_table) {
            const ym = @divFloor(inner_top + inner_bottom, 2);
            for (0..nl) |i| side[i] = shape.alphas(left + @as(i32, @intCast(i)), ym);
            for (0..nr) |i| side[max_side + i] = shape.alphas(mid_x1 + @as(i32, @intCast(i)), ym);
        }

        var y = top;
        while (y < bottom) : (y += 1) {
            const row = self.pixels[@as(usize, @intCast(y)) * self.width..][0..self.width];
            const middle_row = y >= inner_top and y < inner_bottom;
            if (middle_row and use_table) {
                for (row[@intCast(left)..@intCast(mid_x0)], side[0..nl]) |*p, al| shape.apply(p, al);
                if (cmd.fill.a != 0) fillSpan(row[@intCast(mid_x0)..@intCast(mid_x1)], cmd.fill);
                for (row[@intCast(mid_x1)..@intCast(right)], side[max_side..][0..nr]) |*p, al| shape.apply(p, al);
                continue;
            }
            if (middle_row) {
                var x = left;
                while (x < mid_x0) : (x += 1) shape.shade(&row[@intCast(x)], x, y);
                if (cmd.fill.a != 0) fillSpan(row[@intCast(mid_x0)..@intCast(mid_x1)], cmd.fill);
                x = mid_x1;
                while (x < right) : (x += 1) shape.shade(&row[@intCast(x)], x, y);
                continue;
            }
            // A row along the top or bottom edge.
            var x = left;
            while (x < mid_x0) : (x += 1) shape.shade(&row[@intCast(x)], x, y);
            if (mid_x1 > mid_x0) {
                const al = shape.alphas(mid_x0, y);
                const span = row[@intCast(mid_x0)..@intCast(mid_x1)];
                if (al[0] != 0) blendSpanOrFill(span, cmd.fill, al[0]);
                if (al[1] != 0) blendSpanOrFill(span, cmd.border, al[1]);
            }
            x = mid_x1;
            while (x < right) : (x += 1) shape.shade(&row[@intCast(x)], x, y);
        }
    }
};

/// Blits glyphs through `font`. A failed glyph allocation skips that glyph: the
/// vtable has no error channel, and a missing letter beats a lost frame.
fn blitText(self: *SoftwareRenderer, cmd: zui.TextCommand) void {
    const size = cmd.size * self.scale;
    var pen_x = cmd.pos.x * self.scale;
    const baseline: i32 = roundToInt(cmd.pos.y * self.scale);

    var previous: ?u21 = null;
    var it: zui.Utf8Iterator = .{ .bytes = cmd.text };
    while (it.next()) |cp| {
        if (previous) |p| pen_x += cmd.font.kerning(p, cp, size);
        previous = cp;
        defer pen_x += cmd.font.advance(cp, size);

        const steps: f32 = zui.Font.subpixel_steps;
        const quantized = @floor(pen_x * steps + 0.5) / steps;
        const whole = @floor(quantized);
        const subpixel: u8 = @intFromFloat((quantized - whole) * steps);
        const glyph = cmd.font.glyph(cp, size, subpixel) catch continue;
        if (glyph.width == 0) continue;

        const left = roundToInt(whole) + glyph.left;
        const top = baseline + glyph.top;
        const clip = self.clip;
        const x0 = @max(left, clip.x0);
        const y0 = @max(top, clip.y0);
        const x1 = @min(left + @as(i32, @intCast(glyph.width)), clip.x1);
        const y1 = @min(top + @as(i32, @intCast(glyph.height)), clip.y1);
        if (x1 <= x0 or y1 <= y0) continue;

        var y = y0;
        while (y < y1) : (y += 1) {
            const src_row: usize = @intCast(y - top);
            const src = glyph.coverage[src_row * glyph.width..][0..glyph.width];
            const dst = self.pixels[@as(usize, @intCast(y)) * self.width..][0..self.width];
            var x = x0;
            while (x < x1) : (x += 1) {
                const cov = src[@intCast(x - left)];
                if (cov == 0) continue;
                const alpha: u32 = @as(u32, cov) * cmd.color.a;
                blendByte(&dst[@intCast(x)], cmd.color, @intCast((alpha + 127) / 255));
            }
        }
    }
}

/// How much of a shadow shows at distance `d` outside its shape: all of it
/// inside, fading smoothly to nothing at `blur`.
fn shadowCoverage(d: f32, blur: f32) f32 {
    if (d <= 0) return 1;
    if (d >= blur) return 0;
    const t = d / blur;
    return 1 - t * t * (3 - 2 * t);
}

/// Twice the signed area of the triangle `a b p`; positive when `p` is on
/// the inner side of the edge `a`-`b` of a positively wound triangle.
/// Every field of `r` is a number (a NaN or infinite rect draws nothing).
fn finiteRect(r: Rect) bool {
    return std.math.isFinite(r.x) and std.math.isFinite(r.y) and std.math.isFinite(r.w) and std.math.isFinite(r.h);
}

/// A pixel coordinate as an integer: clamped to a billion either way (far
/// past any buffer), NaN as 0, so huge or broken input can't overflow.
fn toI(v: f32) i32 {
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(std.math.clamp(v, -1e9, 1e9));
}

fn edge(a: [2]i64, b: [2]i64, p: [2]i64) i64 {
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
}

/// The top-left rule: of two triangles sharing an edge, the one for which
/// it is a top or left edge owns the pixels exactly on it.
fn topLeft(a: [2]i64, b: [2]i64) bool {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    return dy < 0 or (dy == 0 and dx > 0);
}

/// `@divFloor(w, d)` for `d > 0`, through a precomputed `1 / d` and a fix-up.
fn floorDiv(w: i64, d: i64, inv: f64) i64 {
    var q: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(w)) * inv));
    if (q * d > w) q -= 1 else if ((q + 1) * d <= w) q += 1;
    return q;
}

fn channels(c: Color) [4]f32 {
    return .{ @floatFromInt(c.r), @floatFromInt(c.g), @floatFromInt(c.b), @floatFromInt(c.a) };
}

/// A mesh corner in pixels, optionally on whole pixels.
fn meshCorner(v: zui.MeshVertex, scale: f32, snap: bool) zui.tessellate.Vertex {
    var x = v.pos.x * scale;
    var y = v.pos.y * scale;
    if (snap) {
        x = @round(x);
        y = @round(y);
    }
    return .{ .x = x, .y = y, .color = v.color };
}

/// Draws an image into its rect, edges snapped to pixels like rects. Each
/// destination pixel samples the image at its center.
fn drawImageInto(self: *SoftwareRenderer, cmd: zui.ImageCommand) void {
    const img = cmd.image;
    if (img.width == 0 or img.height == 0) return;
    if (!finiteRect(cmd.rect) or !finiteRect(cmd.uv)) return;
    const s = self.scale;
    const x0 = @round(cmd.rect.x * s);
    const y0 = @round(cmd.rect.y * s);
    const x1 = @round(cmd.rect.right() * s);
    const y1 = @round(cmd.rect.bottom() * s);
    if (x1 <= x0 or y1 <= y0) return;
    const clip = self.clip;
    const left = @max(clip.x0, toI(x0));
    const top = @max(clip.y0, toI(y0));
    const right = @min(clip.x1, toI(x1));
    const bottom = @min(clip.y1, toI(y1));
    if (right <= left or bottom <= top) return;

    const iw: f32 = @floatFromInt(img.width);
    const ih: f32 = @floatFromInt(img.height);
    // Source pixels per destination pixel, and the source position of the
    // first destination pixel's center.
    const du = cmd.uv.w * iw / (x1 - x0);
    const dv = cmd.uv.h * ih / (y1 - y0);
    const u_start = cmd.uv.x * iw + (@as(f32, @floatFromInt(left)) + 0.5 - x0) * du;
    const v_start = cmd.uv.y * ih + (@as(f32, @floatFromInt(top)) + 0.5 - y0) * dv;
    const tint = cmd.tint;
    const plain = tint.r == 255 and tint.g == 255 and tint.b == 255 and tint.a == 255;
    // An opaque image drawn 1:1, untinted, is a plain copy.
    const filter = zui.Filter.resolve(cmd, x1 - x0);
    const copy = plain and img.is_opaque and img.format == .argb32 and filter == .nearest;
    if (copy) {
        // The common case for a viewport image: whole rows at once when it
        // is drawn at its own size, else nearest pixels without blending.
        const src = std.mem.bytesAsSlice(u32, img.pixels);
        var y = top;
        while (y < bottom) : (y += 1) {
            const row = self.pixels[@as(usize, @intCast(y)) * self.width..][0..self.width];
            const v = v_start + @as(f32, @floatFromInt(y - top)) * dv;
            const sy: usize = @intFromFloat(std.math.clamp(@floor(v), 0, ih - 1));
            const src_row = src[sy * img.width ..][0..img.width];
            const sx0 = u_start - 0.5;
            if (du == 1 and sx0 == @floor(sx0) and sx0 >= 0 and sx0 + @as(f32, @floatFromInt(right - left)) <= iw) {
                const first: usize = @intFromFloat(sx0);
                for (row[@intCast(left)..@intCast(right)], src_row[first..][0..@intCast(right - left)]) |*d, p| d.* = p | 0xFF000000;
                continue;
            }
            var x = left;
            while (x < right) : (x += 1) {
                const u = u_start + @as(f32, @floatFromInt(x - left)) * du;
                const sx: usize = @intFromFloat(std.math.clamp(@floor(u), 0, iw - 1));
                row[@intCast(x)] = src_row[sx] | 0xFF000000;
            }
        }
        return;
    }

    // A mask (an icon) drawn at its own size: integer steps, the tint
    // blended by the mask's coverage (the same pixels as the general path).
    const sx0 = u_start - 0.5;
    const sy0 = v_start - 0.5;
    if (img.format == .alpha8 and filter == .nearest and du == 1 and dv == 1 and
        sx0 == @floor(sx0) and sy0 == @floor(sy0) and sx0 >= 0 and sy0 >= 0 and
        sx0 + @as(f32, @floatFromInt(right - left)) <= iw and sy0 + @as(f32, @floatFromInt(bottom - top)) <= ih)
    {
        const fx: usize = @intFromFloat(sx0);
        const fy: usize = @intFromFloat(sy0);
        const n: usize = @intCast(right - left);
        const opaque_tint = packOpaque(tint);
        var y = top;
        while (y < bottom) : (y += 1) {
            const row = self.pixels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(left)) ..][0..n];
            const src = img.pixels[(fy + @as(usize, @intCast(y - top))) * img.width + fx ..][0..n];
            for (row, src) |*d, m| {
                if (m == 0) continue;
                const a = if (tint.a == 255) m else mul255(m, tint.a);
                if (a == 255) d.* = opaque_tint else if (a != 0) blendByte(d, tint, a);
            }
        }
        return;
    }

    const cell = cellOf(img, cmd.uv);
    var y = top;
    while (y < bottom) : (y += 1) {
        const row = self.pixels[@as(usize, @intCast(y)) * self.width..][0..self.width];
        const v = v_start + @as(f32, @floatFromInt(y - top)) * dv;
        var x = left;
        while (x < right) : (x += 1) {
            const u = u_start + @as(f32, @floatFromInt(x - left)) * du;
            const px = if (filter == .nearest) samplePixel(img, u, v) else sampleLinear(img, cell, u, v);
            var c: Color = .{
                .a = @truncate(px >> 24),
                .r = @truncate(px >> 16),
                .g = @truncate(px >> 8),
                .b = @truncate(px),
            };
            if (!plain) c = .{
                .r = mul255(c.r, tint.r),
                .g = mul255(c.g, tint.g),
                .b = mul255(c.b, tint.b),
                .a = mul255(c.a, tint.a),
            };
            if (c.a == 255) {
                row[@intCast(x)] = packOpaque(c);
            } else if (c.a != 0) blendByte(&row[@intCast(x)], c, c.a);
        }
    }
}

fn mul255(a: u8, b: u8) u8 {
    return @intCast((@as(u32, a) * b + 127) / 255);
}

/// The pixel containing source position `(u, v)`, clamped to the edges.
fn samplePixel(img: *const zui.Image, u: f32, v: f32) u32 {
    const x: u32 = @intFromFloat(std.math.clamp(@floor(u), 0, @as(f32, @floatFromInt(img.width - 1))));
    const y: u32 = @intFromFloat(std.math.clamp(@floor(v), 0, @as(f32, @floatFromInt(img.height - 1))));
    return img.argbAt(x, y);
}

/// Bilinear sample at `(u, v)`, blending in premultiplied form so that
/// transparent pixels don't darken their neighbours. Returns straight alpha.
/// The pixels of an image a command may sample: its uv rect, so filtering
/// an icon in an atlas never reaches into the next one.
const Cell = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

fn cellOf(img: *const zui.Image, uv: Rect) Cell {
    const w: f32 = @floatFromInt(img.width);
    const h: f32 = @floatFromInt(img.height);
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(uv.x * w), 0, w - 1));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(uv.y * h), 0, h - 1));
    const x1: u32 = @intFromFloat(std.math.clamp(@ceil((uv.x + uv.w) * w) - 1, @as(f32, @floatFromInt(x0)), w - 1));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil((uv.y + uv.h) * h) - 1, @as(f32, @floatFromInt(y0)), h - 1));
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn sampleLinear(img: *const zui.Image, cell: Cell, u: f32, v: f32) u32 {
    const fx = std.math.clamp(u - 0.5, @as(f32, @floatFromInt(cell.x0)), @as(f32, @floatFromInt(cell.x1)));
    const fy = std.math.clamp(v - 0.5, @as(f32, @floatFromInt(cell.y0)), @as(f32, @floatFromInt(cell.y1)));
    const x0: u32 = @intFromFloat(@floor(fx));
    const y0: u32 = @intFromFloat(@floor(fy));
    const x1 = @min(x0 + 1, cell.x1);
    const y1 = @min(y0 + 1, cell.y1);
    const tx = fx - @floor(fx);
    const ty = fy - @floor(fy);
    const weights = [4]f32{ (1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty };
    const samples = [4]u32{ img.argbAt(x0, y0), img.argbAt(x1, y0), img.argbAt(x0, y1), img.argbAt(x1, y1) };
    var acc = [4]f32{ 0, 0, 0, 0 };
    for (samples, weights) |p, w| {
        const a: f32 = @floatFromInt(p >> 24);
        const k = w * a / 255;
        acc[0] += @as(f32, @floatFromInt((p >> 16) & 0xFF)) * k;
        acc[1] += @as(f32, @floatFromInt((p >> 8) & 0xFF)) * k;
        acc[2] += @as(f32, @floatFromInt(p & 0xFF)) * k;
        acc[3] += a * w;
    }
    if (acc[3] < 0.5) return 0;
    const unpremul = 255 / acc[3];
    const r: u32 = @intFromFloat(std.math.clamp(acc[0] * unpremul + 0.5, 0, 255));
    const g: u32 = @intFromFloat(std.math.clamp(acc[1] * unpremul + 0.5, 0, 255));
    const b: u32 = @intFromFloat(std.math.clamp(acc[2] * unpremul + 0.5, 0, 255));
    const a: u32 = @intFromFloat(std.math.clamp(acc[3] + 0.5, 0, 255));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

/// A pixel-space rounded box, evaluated per pixel at its perimeter.
const Shape = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    radius: f32,
    border: f32,
    fill: Color,
    edge: Color,

    /// Signed distance from `(px, py)` to the box shrunk by `inset`.
    /// Negative inside.
    fn distance(s: Shape, px: f32, py: f32, inset: f32) f32 {
        const half_w = (s.x1 - s.x0) / 2 - inset;
        const half_h = (s.y1 - s.y0) / 2 - inset;
        const r = @max(0, s.radius - inset);
        const qx = @abs(px - (s.x0 + s.x1) / 2) - (half_w - r);
        const qy = @abs(py - (s.y0 + s.y1) / 2) - (half_h - r);
        const ox = @max(qx, 0);
        const oy = @max(qy, 0);
        return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - r;
    }

    /// The fill and border alphas `shade` would blend at pixel (x, y).
    fn alphas(s: Shape, x: i32, y: i32) [2]u8 {
        const px = @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const outer = coverage(s.distance(px, py, 0));
        if (outer <= 0) return .{ 0, 0 };
        const inner = if (s.border > 0) coverage(s.distance(px, py, s.border)) else outer;
        var r: [2]u8 = .{ 0, 0 };
        if (s.fill.a != 0 and inner > 0) r[0] = @intFromFloat(@as(f32, @floatFromInt(s.fill.a)) * inner + 0.5);
        if (s.border > 0 and outer > inner) r[1] = @intFromFloat(@as(f32, @floatFromInt(s.edge.a)) * (outer - inner) + 0.5);
        return r;
    }

    fn apply(s: Shape, dst: *u32, al: [2]u8) void {
        if (al[0] != 0) blendByte(dst, s.fill, al[0]);
        if (al[1] != 0) blendByte(dst, s.edge, al[1]);
    }

    fn shade(s: Shape, dst: *u32, x: i32, y: i32) void {
        const px = @as(f32, @floatFromInt(x)) + 0.5;
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const outer = coverage(s.distance(px, py, 0));
        if (outer <= 0) return;
        const inner = if (s.border > 0) coverage(s.distance(px, py, s.border)) else outer;
        if (s.fill.a != 0 and inner > 0) blend(dst, s.fill, inner);
        if (s.border > 0 and outer > inner) blend(dst, s.edge, outer - inner);
    }

    fn coverage(distance_px: f32) f32 {
        return std.math.clamp(0.5 - distance_px, 0, 1);
    }
};

fn roundToInt(v: f32) i32 {
    return @intFromFloat(std.math.clamp(@round(v), -1e9, 1e9));
}

fn packOpaque(c: Color) u32 {
    return 0xFF000000 | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

fn fillOpaque(span: []u32, v: u32) void {
    const N = 16;
    const vv: @Vector(N, u32) = @splat(v);
    var i: usize = 0;
    while (i + N <= span.len) : (i += N) span[i..][0..N].* = vv;
    while (i < span.len) : (i += 1) span[i] = v;
}

fn fillSpan(span: []u32, c: Color) void {
    if (c.a == 255) {
        fillOpaque(span, packOpaque(c));
    } else {
        blendSpan(span, c, c.a);
    }
}

fn blendSpanOrFill(span: []u32, c: Color, alpha: u8) void {
    if (alpha == 255) @memset(span, packOpaque(c)) else blendSpan(span, c, alpha);
}

/// `blendByte` over a whole span with one alpha, 8 pixels at a time.
fn blendSpan(span: []u32, c: Color, alpha: u8) void {
    if (alpha == 0) return;
    const a: u32 = @as(u32, alpha) + (alpha >> 7);
    const inv = 256 - a;
    const src = packOpaque(c);
    const src_rb = (src & 0xFF00FF) * a;
    const src_g = (src & 0x00FF00) * a;
    const N = 8;
    const V = @Vector(N, u32);
    const vrb: V = @splat(src_rb);
    const vg: V = @splat(src_g);
    const vinv: V = @splat(inv);
    const m_rb: V = @splat(0xFF00FF);
    const m_g: V = @splat(0x00FF00);
    const opaque_bits: V = @splat(0xFF000000);
    var i: usize = 0;
    while (i + N <= span.len) : (i += N) {
        const d: V = span[i..][0..N].*;
        const rb = ((d & m_rb) * vinv + vrb) >> @splat(8);
        const g = ((d & m_g) * vinv + vg) >> @splat(8);
        span[i..][0..N].* = opaque_bits | (rb & m_rb) | (g & m_g);
    }
    while (i < span.len) : (i += 1) {
        const d = span[i];
        const rb = ((d & 0xFF00FF) * inv + src_rb) >> 8;
        const g = ((d & 0x00FF00) * inv + src_g) >> 8;
        span[i] = 0xFF000000 | (rb & 0xFF00FF) | (g & 0x00FF00);
    }
}

fn blend(dst: *u32, c: Color, cov: f32) void {
    blendByte(dst, c, @intFromFloat(@as(f32, @floatFromInt(c.a)) * cov + 0.5));
}

/// Source-over onto an opaque destination. `alpha` is 0..255.
fn blendByte(dst: *u32, c: Color, alpha: u8) void {
    // Map 0..255 to 0..256 so that 255 is exact and the shift below is a
    // true divide.
    const a: u32 = @as(u32, alpha) + (alpha >> 7);
    const inv = 256 - a;
    const src = packOpaque(c);
    const d = dst.*;
    const rb = ((src & 0xFF00FF) * a + (d & 0xFF00FF) * inv) >> 8;
    const g = ((src & 0x00FF00) * a + (d & 0x00FF00) * inv) >> 8;
    dst.* = 0xFF000000 | (rb & 0xFF00FF) | (g & 0x00FF00);
}

const testing = std.testing;

fn testRender(sw: *SoftwareRenderer, list: *const zui.DrawList, w: f32, h: f32) void {
    sw.renderer().render(list, .{ .width = w, .height = h });
}

test "opaque rect fills exactly its pixels" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(10, 10);
    sw.clear_color = Color.black;
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.addRect(.{ .rect = .{ .x = 2, .y = 3, .w = 4, .h = 2 }, .fill = Color.white });
    testRender(&sw, &list, 10, 10);

    var lit: u32 = 0;
    for (sw.pixels) |p| {
        if (p == 0xFFFFFFFF) lit += 1;
    }
    try testing.expectEqual(@as(u32, 8), lit);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), sw.pixels[3 * 10 + 2]);
    try testing.expectEqual(@as(u32, 0xFF000000), sw.pixels[3 * 10 + 6]);
}

test "clip restricts drawing" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(10, 10);
    sw.clear_color = Color.black;
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.setClip(.{ .w = 5, .h = 10 });
    try list.addRect(.{ .rect = .{ .w = 10, .h = 10 }, .fill = Color.white });
    testRender(&sw, &list, 10, 10);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), sw.pixels[4]);
    try testing.expectEqual(@as(u32, 0xFF000000), sw.pixels[5]);
}

test "drawing partly off-screen does not crash" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(8, 8);
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.addRect(.{
        .rect = .{ .x = -20, .y = -20, .w = 100, .h = 100 },
        .fill = Color.white,
        .border = Color.black,
        .border_width = 3,
        .radius = 9,
    });
    testRender(&sw, &list, 8, 8);
}

test "text marks pixels and respects the clip" {
    var font: zui.Font = try .initDefault(testing.allocator);
    defer font.deinit();
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(100, 30);
    sw.clear_color = Color.black;
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.setClip(.{ .w = 100, .h = 15 });
    try list.addText(.{ .font = &font, .pos = .{ .x = 4, .y = 20 }, .size = 20, .color = Color.white, .text = "Hg" });
    testRender(&sw, &list, 100, 30);

    var above: u32 = 0;
    var below: u32 = 0;
    for (sw.pixels, 0..) |p, i| {
        if (p == 0xFF000000) continue;
        if (i / 100 < 15) above += 1 else below += 1;
    }
    try testing.expect(above > 10);
    try testing.expectEqual(@as(u32, 0), below);
}

test "half alpha blends halfway" {
    var dst: u32 = 0xFF000000;
    blendByte(&dst, Color.white, 128);
    try testing.expectEqual(@as(u32, 0xFF808080), dst);
}

test "drawing over an app's own buffer" {
    var sw: SoftwareRenderer = .init(std.testing.allocator);
    defer sw.deinit();
    var app_pixels: [4 * 2]u32 = @splat(0xFF112233);
    sw.useBuffer(&app_pixels, 4, 2);
    sw.clear = false;
    var list: zui.DrawList = .init(std.testing.allocator);
    defer list.deinit();
    try list.addRect(.{ .rect = .{ .x = 2, .y = 0, .w = 2, .h = 2 }, .fill = Color.hex(0xFF0000) });
    sw.renderer().render(&list, .{ .width = 4, .height = 2 });
    // The app's pixels stay where the UI drew nothing.
    try std.testing.expectEqual(@as(u32, 0xFF112233), app_pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), app_pixels[3]);
    // A resize goes back to a buffer of its own.
    try sw.resize(3, 3);
    try std.testing.expect(sw.owned);
}

test "scale doubles pixel size" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(4, 4);
    sw.clear_color = Color.black;
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.addRect(.{ .rect = .{ .w = 1, .h = 1 }, .fill = Color.white });
    sw.renderer().render(&list, .{ .width = 2, .height = 2, .scale = 2 });
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), sw.pixels[5]);
    try testing.expectEqual(@as(u32, 0xFF000000), sw.pixels[6]);
}

test "a shadow is solid inside, fades outside, and is gone past its blur" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(100, 60);
    sw.clear_color = Color.hex(0xFFFFFF);
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.addShadow(.{ .rect = .{ .x = 30, .y = 20, .w = 40, .h = 20 }, .radius = 4, .blur = 10, .color = Color.hex(0x000000) });
    testRender(&sw, &list, 100, 60);
    const at = struct {
        fn f(s: *const SoftwareRenderer, x: usize, y: usize) u8 {
            return @truncate(s.pixels[y * s.width + x]); // blue channel; gray anyway
        }
    }.f;
    try testing.expectEqual(@as(u8, 0), at(&sw, 50, 30)); // inside: full black
    const near = at(&sw, 72, 30);
    const far = at(&sw, 78, 30);
    try testing.expect(near > 0 and near < far); // fades with distance
    try testing.expectEqual(@as(u8, 255), at(&sw, 85, 30)); // past the blur
}

test "a renderer without drawShadow skips shadows" {
    const Counter = struct {
        rects: usize = 0,
        fn begin(_: *anyopaque, _: zui.Frame) void {}
        fn drawRect(p: *anyopaque, _: RectCommand) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.rects += 1;
        }
        fn drawText(_: *anyopaque, _: zui.TextCommand) void {}
        fn setClip(_: *anyopaque, _: ?Rect) void {}
        fn end(_: *anyopaque) void {}
    };
    var counter: Counter = .{};
    const vt: zui.Renderer.VTable = .{ .begin = Counter.begin, .drawRect = Counter.drawRect, .drawText = Counter.drawText, .setClip = Counter.setClip, .end = Counter.end };
    const r: zui.Renderer = .{ .ptr = &counter, .vtable = &vt };
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.addShadow(.{ .rect = .{ .w = 10, .h = 10 }, .color = Color.hex(0) });
    try list.addRect(.{ .rect = .{ .w = 10, .h = 10 }, .fill = Color.hex(0) });
    r.render(&list, .{ .width = 10, .height = 10 });
    try testing.expectEqual(@as(usize, 1), counter.rects);
}

/// Sum of the red channel over all pixels, in pixels' worth of full red.
fn redCoverage(sw: *const SoftwareRenderer) f32 {
    var sum: f32 = 0;
    for (sw.pixels) |p| sum += @as(f32, @floatFromInt((p >> 16) & 0xFF)) / 255;
    return sum;
}

test "a snapped one-unit line lights exactly one row" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(20, 10);
    sw.clear_color = Color.black;
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.addLine(.{ .x = 2, .y = 4.3 }, .{ .x = 18, .y = 4.3 }, Color.white, 1);
    testRender(&sw, &list, 20, 10);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), sw.pixels[4 * 20 + 10]);
    try testing.expectEqual(@as(u32, 0xFF000000), sw.pixels[3 * 20 + 10]);
    try testing.expectEqual(@as(u32, 0xFF000000), sw.pixels[5 * 20 + 10]);
}

test "a filled circle covers its area and has soft edges" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(40, 40);
    sw.clear_color = Color.black;
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.addCircle(.{ .x = 20, .y = 20 }, 12, Color.hex(0xFF0000), 0);
    testRender(&sw, &list, 40, 40);
    try testing.expectApproxEqRel(std.math.pi * 144.0, redCoverage(&sw), 0.02);
    var partial: u32 = 0;
    for (sw.pixels) |p| {
        const r = (p >> 16) & 0xFF;
        if (r > 0 and r < 255) partial += 1;
    }
    try testing.expect(partial > 40);
}

test "triangles sharing an edge leave no seam and no overlap" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(16, 16);
    sw.clear_color = Color.black;
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    // A translucent quad split along a slanted diagonal: overlap would
    // show as brighter pixels, a gap as darker ones.
    const c = Color.hex(0xFF0000).withAlpha(128);
    try list.addMesh(.{
        .vertices = &.{
            .{ .pos = .{ .x = 1.3, .y = 1.1 }, .color = c },
            .{ .pos = .{ .x = 14.6, .y = 2.2 }, .color = c },
            .{ .pos = .{ .x = 13.4, .y = 14.7 }, .color = c },
            .{ .pos = .{ .x = 2.1, .y = 13.5 }, .color = c },
        },
        .indices = &.{ 0, 1, 2, 0, 2, 3 },
    });
    testRender(&sw, &list, 16, 16);
    for (sw.pixels) |p| {
        const r = (p >> 16) & 0xFF;
        try testing.expect(r == 0 or r == 128);
    }
}

test "images: a 1:1 opaque copy, and an alpha mask in the tint" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(8, 8);
    sw.clear_color = Color.black;
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    const src = [_]u32{ 0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC };
    var img: zui.Image = .initArgb(&src, 2, 2);
    img.is_opaque = true;
    try list.addImage(.{ .image = &img, .rect = .{ .x = 1, .y = 1, .w = 2, .h = 2 }, .filter = .nearest });
    const mask = [_]u8{ 255, 0, 0, 255 };
    const alpha: zui.Image = .initAlpha(&mask, 2, 2);
    try list.addImage(.{ .image = &alpha, .rect = .{ .x = 4, .y = 4, .w = 4, .h = 4 }, .tint = Color.hex(0x00FF00), .filter = .auto });
    testRender(&sw, &list, 8, 8);
    try testing.expectEqual(@as(u32, 0xFF112233), sw.pixels[1 * 8 + 1]);
    try testing.expectEqual(@as(u32, 0xFFAABBCC), sw.pixels[2 * 8 + 2]);
    // Twice its size is a whole multiple: `auto` picks nearest, so each
    // mask pixel becomes a crisp 2 x 2 block.
    try testing.expectEqual(@as(u32, 0xFF00FF00), sw.pixels[5 * 8 + 5]);
    try testing.expectEqual(@as(u32, 0xFF000000), sw.pixels[5 * 8 + 6]);
}

test "a mask at its own size, in an atlas cell, tinted and half clear: the general path's pixels" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(8, 4);
    sw.clear_color = Color.hex(0x204060);
    // A 4 x 2 atlas of two 2 x 2 icons; draw the second one at (3, 1).
    const mask = [_]u8{ 255, 255, 10, 200, 255, 255, 0, 128 };
    const atlas: zui.Image = .initAlpha(&mask, 4, 2);
    const tint = Color{ .r = 250, .g = 100, .b = 20, .a = 128 };
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.addImage(.{ .image = &atlas, .rect = .{ .x = 3, .y = 1, .w = 2, .h = 2 }, .uv = .{ .x = 0.5, .y = 0, .w = 0.5, .h = 1 }, .tint = tint, .filter = .auto });
    testRender(&sw, &list, 8, 4);
    for ([_][3]u32{ .{ 3, 1, 10 }, .{ 4, 1, 200 }, .{ 3, 2, 0 }, .{ 4, 2, 128 } }) |t| {
        var want: u32 = packOpaque(Color.hex(0x204060));
        const a = mul255(@intCast(t[2]), tint.a);
        if (a != 0) blendByte(&want, tint, a);
        try testing.expectEqual(want, sw.pixels[t[1] * 8 + t[0]]);
    }
    // (outside it: the background)
    try testing.expectEqual(packOpaque(Color.hex(0x204060)), sw.pixels[1 * 8 + 5]);
}

test "a gradient blends between its corners" {
    var sw: SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    try sw.resize(64, 4);
    sw.clear_color = Color.black;
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.addGradient(.{ .w = 64, .h = 4 }, Color.black, Color.white, Color.black, Color.white);
    testRender(&sw, &list, 64, 4);
    const left = sw.pixels[64 + 0] & 0xFF;
    const middle = sw.pixels[64 + 32] & 0xFF;
    const right = sw.pixels[64 + 63] & 0xFF;
    try testing.expect(left < 8 and right > 247);
    try testing.expect(middle > 120 and middle < 136);
}

// ---- Docs/improvements.html C3, C4: broken or huge geometry draws nothing wrong ----

fn renderOne(comptime add: fn (*zui.DrawList) anyerror!void) !u32 {
    var r: SoftwareRenderer = .init(std.testing.allocator);
    defer r.deinit();
    try r.resize(64, 64);
    var list: zui.DrawList = .init(std.testing.allocator);
    defer list.deinit();
    try add(&list);
    // A sane rect after the broken shape still draws.
    try list.addRect(.{ .rect = .{ .x = 60, .y = 60, .w = 4, .h = 4 }, .fill = zui.Color.white });
    r.renderer().render(&list, .{ .width = 64, .height = 64 });
    return r.pixels[63 * 64 + 63];
}

fn tri(comptime a: [2]f32, comptime b: [2]f32, comptime c: [2]f32) fn (*zui.DrawList) anyerror!void {
    return struct {
        fn f(l: *zui.DrawList) anyerror!void {
            const W = zui.Color.white;
            try l.addMesh(.{ .vertices = &.{ .{ .pos = .{ .x = a[0], .y = a[1] }, .color = W }, .{ .pos = .{ .x = b[0], .y = b[1] }, .color = W }, .{ .pos = .{ .x = c[0], .y = c[1] }, .color = W } }, .indices = &.{ 0, 1, 2 } });
        }
    }.f;
}

test "C3: far-away and NaN triangle corners don't panic" {
    const nan = std.math.nan(f32);
    const white = packOpaque(zui.Color.white);
    try std.testing.expectEqual(white, try renderOne(tri(.{ 0, 0 }, .{ 3e9, 0 }, .{ 0, 30 })));
    try std.testing.expectEqual(white, try renderOne(tri(.{ -2e7, -2e7 }, .{ 2e7, -1e7 }, .{ 10, 3e7 })));
    try std.testing.expectEqual(white, try renderOne(tri(.{ nan, 0 }, .{ 30, 0 }, .{ 0, 30 })));
    try std.testing.expectEqual(white, try renderOne(struct {
        fn f(l: *zui.DrawList) anyerror!void {
            try l.addLine(.{ .x = 10, .y = 10 }, .{ .x = 5e7, .y = 3e7 }, zui.Color.white, 1);
        }
    }.f));
}

test "C4: huge and NaN rects, shadows and images don't panic" {
    const white = packOpaque(zui.Color.white);
    const nan = std.math.nan(f32);
    try std.testing.expectEqual(white, try renderOne(struct {
        fn f(l: *zui.DrawList) anyerror!void {
            try l.addRect(.{ .rect = .{ .x = -1e10, .y = 0, .w = 2e10, .h = 10 }, .fill = zui.Color.white });
            try l.addRect(.{ .rect = .{ .x = nan, .y = 0, .w = 10, .h = 10 }, .fill = zui.Color.white });
            try l.addRect(.{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .fill = zui.Color.white, .border = zui.Color.black, .border_width = 1e10 });
            try l.addShadow(.{ .rect = .{ .x = -1e10, .y = 0, .w = 2e10, .h = 10 }, .color = zui.Color.black });
            try l.addShadow(.{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .color = zui.Color.black, .blur = nan });
        }
    }.f));
    try std.testing.expectEqual(white, try renderOne(struct {
        const S = struct {
            var px = [_]u32{ 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF };
            var img: zui.Image = undefined;
        };
        fn f(l: *zui.DrawList) anyerror!void {
            S.img = .initArgb(&S.px, 2, 2);
            try l.addImage(.{ .image = &S.img, .rect = .{ .x = -1e10, .y = 0, .w = 2e10, .h = 10 } });
            try l.addImage(.{ .image = &S.img, .rect = .{ .x = nan, .y = 0, .w = 10, .h = 10 } });
        }
    }.f));
}

test "L11: filtering an icon at 1.25x never reaches into the next one in the atlas" {
    // Two 4x4 cells side by side: an empty icon, then a solid one.
    var px: [8 * 4]u8 = @splat(0);
    for (0..4) |y| for (4..8) |x| {
        px[y * 8 + x] = 255;
    };
    const img: zui.Image = .initAlpha(&px, 8, 4);
    var r: SoftwareRenderer = .init(std.testing.allocator);
    defer r.deinit();
    try r.resize(16, 16);
    var list: zui.DrawList = .init(std.testing.allocator);
    defer list.deinit();
    try list.addImage(.{ .image = &img, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 5 }, .uv = .{ .x = 0, .y = 0, .w = 0.5, .h = 1 }, .tint = zui.Color.white, .filter = .linear });
    r.renderer().render(&list, .{ .width = 16, .height = 16 });
    const bg = r.pixels[15 * 16 + 15];
    for (0..5) |y| for (0..5) |x| try std.testing.expectEqual(bg, r.pixels[y * 16 + x]);
}
