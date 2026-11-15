// Software drawing into an XRGB8888 framebuffer: rects, lines, circles, text,
// and a depth-buffered triangle rasterizer for the 3D viewport.
const std = @import("std");
const font = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
pub const Face = tx.Face;
pub const Icon = icons.Icon;

/// The face text is drawn and measured with (the UI's, unless set).
pub var face: Face = .ui;

/// Draw with face f until the returned old face is restored.
pub fn useFace(f: Face) Face {
    const old = face;
    face = f;
    return old;
}

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h;
    }
    pub fn inset(r: Rect, d: i32) Rect {
        return .{ .x = r.x + d, .y = r.y + d, .w = @max(0, r.w - 2 * d), .h = @max(0, r.h - 2 * d) };
    }
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }
    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }
    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }
};

pub const ONE: i32 = 65536;
pub const glyph_w = 8;
pub const glyph_h = 16;

pub fn textWidth(s: []const u8) i32 {
    if (tx.loaded) return tx.width(face, s);
    var n: usize = 0;
    for (s) |ch| {
        if (ch != 0xC2) n += 1;
    }
    return @intCast(n * glyph_w);
}

pub fn mix(a: u32, b: u32, t: u32) u32 {
    // t in 0..256: 0 = a, 256 = b
    const ar = (a >> 16) & 255;
    const ag = (a >> 8) & 255;
    const ab = a & 255;
    const br = (b >> 16) & 255;
    const bg = (b >> 8) & 255;
    const bb = b & 255;
    const r = (ar * (256 - t) + br * t) >> 8;
    const g = (ag * (256 - t) + bg * t) >> 8;
    const bl = (ab * (256 - t) + bb * t) >> 8;
    return (r << 16) | (g << 8) | bl;
}

pub fn shade(c: u32, f: f32) u32 {
    const k = std.math.clamp(f, 0.0, 1.6);
    const r: f32 = @floatFromInt((c >> 16) & 255);
    const g: f32 = @floatFromInt((c >> 8) & 255);
    const b: f32 = @floatFromInt(c & 255);
    const rr: u32 = @intFromFloat(@min(255.0, r * k));
    const gg: u32 = @intFromFloat(@min(255.0, g * k));
    const bb: u32 = @intFromFloat(@min(255.0, b * k));
    return (rr << 16) | (gg << 8) | bb;
}

/// triangleN also writes cur_tri here per pixel (Material Preview: shader
/// graphs find the point on the source triangle).
pub var tri_buf: ?[*]u32 = null;
pub var cur_tri: u32 = 0;
/// Set: triangle() hands its triangles here instead (gpuraster.zig).
pub var sink: ?*const fn ([3]f32, [3]f32, [3]f32, u32, u16) void = null;

pub const Canvas = struct {
    px: [*]u32,
    w: i32,
    h: i32,
    clip: Rect,
    /// Optional per-pixel depth and object id (for the 3D viewport).
    zbuf: ?[*]f32 = null,
    ids: ?[*]u16 = null,
    /// When false every drawing call is a no-op (the UI's hit-testing pass).
    enabled: bool = true,
    /// UI units -> pixels, 16.16 (ONE: they are pixels). w and h are always
    /// the buffer's; clip is in the units the calls take.
    s: i32 = ONE,
    /// The size in UI units.
    uw: i32 = 0,
    uh: i32 = 0,
    /// triangleN's triangle number, on a thread's own copy (else cur_tri).
    tri: ?u32 = null,

    pub fn full(c: *const Canvas) Rect {
        return if (c.s == ONE) .{ .w = c.w, .h = c.h } else .{ .w = c.uw, .h = c.uh };
    }

    /// A UI coordinate in pixels.
    pub fn toPx(c: *const Canvas, v: i32) i32 {
        return @intCast((@as(i64, v) * c.s + 0x8000) >> 16);
    }

    /// A UI rectangle in pixels: shared edges stay shared, nothing vanishes.
    pub fn pxRect(c: *const Canvas, r: Rect) Rect {
        if (c.s == ONE) return r;
        const x0 = c.toPx(r.x);
        const y0 = c.toPx(r.y);
        var w = c.toPx(r.x + r.w) - x0;
        var h = c.toPx(r.y + r.h) - y0;
        if (r.w > 0 and w < 1) w = 1;
        if (r.h > 0 and h < 1) h = 1;
        return .{ .x = x0, .y = y0, .w = w, .h = h };
    }

    /// The same buffer, addressed in pixels (the 3D view, images).
    pub fn pixels(c: *const Canvas) Canvas {
        var p = c.*;
        p.s = ONE;
        p.clip = c.pxRect(c.clip).intersect(.{ .w = c.w, .h = c.h });
        return p;
    }

    pub fn setClip(c: *Canvas, r: Rect) Rect {
        const old = c.clip;
        c.clip = r.intersect(c.full());
        return old;
    }

    pub fn fill(c: *Canvas, r0: Rect, col: u32) void {
        if (!c.enabled) return;
        if (c.s != ONE) {
            var p = c.pixels();
            return p.fill(c.pxRect(r0.intersect(c.clip)), col);
        }
        const r = r0.intersect(c.clip);
        if (r.w <= 0 or r.h <= 0) return;
        var y = r.y;
        while (y < r.y + r.h) : (y += 1) {
            const row = c.px + @as(usize, @intCast(y * c.w + r.x));
            @memset(row[0..@intCast(r.w)], col);
        }
    }

    pub fn blend(c: *Canvas, r0: Rect, col: u32, t: u32) void {
        if (!c.enabled) return;
        if (c.s != ONE) {
            var p = c.pixels();
            return p.blend(c.pxRect(r0.intersect(c.clip)), col, t);
        }
        const r = r0.intersect(c.clip);
        var y = r.y;
        while (y < r.y + r.h) : (y += 1) {
            var x = r.x;
            while (x < r.x + r.w) : (x += 1) {
                const p = &c.px[@intCast(y * c.w + x)];
                p.* = mix(p.*, col, t);
            }
        }
    }

    pub fn pixel(c: *Canvas, x: i32, y: i32, col: u32) void {
        if (c.s != ONE) return c.fill(.{ .x = x, .y = y, .w = 1, .h = 1 }, col);
        if (!c.clip.contains(x, y)) return;
        c.px[@intCast(y * c.w + x)] = col;
    }

    fn pixelBlend(c: *Canvas, x: i32, y: i32, col: u32, t: u32) void {
        if (!c.clip.contains(x, y)) return;
        const p = &c.px[@intCast(y * c.w + x)];
        p.* = mix(p.*, col, t);
    }

    /// Filled rectangle with rounded corners (anti-aliased edge).
    pub fn fillRound(c: *Canvas, r: Rect, rad0: i32, col: u32) void {
        if (!c.enabled) return;
        if (c.s != ONE) {
            var p = c.pixels();
            return p.fillRound(c.pxRect(r), c.toPx(rad0), col);
        }
        const rad = @min(rad0, @divTrunc(@min(r.w, r.h), 2));
        if (rad <= 0) return c.fill(r, col);
        c.fill(.{ .x = r.x, .y = r.y + rad, .w = r.w, .h = r.h - 2 * rad }, col);
        var i: i32 = 0;
        const rf: f32 = @floatFromInt(rad);
        while (i < rad) : (i += 1) {
            // row i from the top edge
            const dy = rf - (@as(f32, @floatFromInt(i)) + 0.5);
            const dx = @sqrt(@max(0.0, rf * rf - dy * dy));
            const inner: i32 = @intFromFloat(@floor(rf - dx));
            const frac = (rf - dx) - @floor(rf - dx);
            const span = Rect{ .x = r.x + inner + 1, .y = 0, .w = r.w - 2 * (inner + 1), .h = 1 };
            const a: u32 = @intFromFloat((1.0 - frac) * 256.0);
            for ([2]i32{ r.y + i, r.y + r.h - 1 - i }) |yy| {
                c.fill(.{ .x = span.x, .y = yy, .w = span.w, .h = 1 }, col);
                c.pixelBlend(r.x + inner, yy, col, a);
                c.pixelBlend(r.x + r.w - 1 - inner, yy, col, a);
            }
        }
    }

    pub fn rectLine(c: *Canvas, r: Rect, col: u32) void {
        c.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, col);
        c.fill(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, col);
        c.fill(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, col);
        c.fill(.{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, col);
    }

    pub fn gradientV(c: *Canvas, r: Rect, top: u32, bot: u32) void {
        if (!c.enabled or r.h <= 0) return;
        if (c.s != ONE) {
            var p = c.pixels();
            return p.gradientV(c.pxRect(r), top, bot);
        }
        // draw.s grad_rows: per channel top + (bot - top) * row / h, truncated
        var y: i32 = 0;
        while (y < r.h) : (y += 1) {
            var col: u32 = 0;
            for ([3]u5{ 16, 8, 0 }) |sh| {
                const a: i32 = @intCast((top >> sh) & 255);
                const b: i32 = @intCast((bot >> sh) & 255);
                const v = a + @divTrunc((b - a) * y, r.h);
                col |= @as(u32, @intCast(v & 255)) << sh;
            }
            c.fill(.{ .x = r.x, .y = r.y + y, .w = r.w, .h = 1 }, col);
        }
    }

    pub fn line(c: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, col: u32) void {
        if (!c.enabled) return;
        if (c.s != ONE) {
            var p = c.pixels();
            return p.line(c.toPx(x0), c.toPx(y0), c.toPx(x1), c.toPx(y1), col);
        }
        // Reject lines far outside to keep the loop bounded.
        const lim = 1 << 15;
        if (@abs(x0) > lim or @abs(y0) > lim or @abs(x1) > lim or @abs(y1) > lim) return;
        var x = x0;
        var y = y0;
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx + dy;
        while (true) {
            c.pixel(x, y, col);
            if (x == x1 and y == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y += sy;
            }
        }
    }

    pub fn thickLine(c: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, col: u32) void {
        c.line(x0, y0, x1, y1, col);
        c.line(x0 + 1, y0, x1 + 1, y1, col);
        c.line(x0, y0 + 1, x1, y1 + 1, col);
    }

    pub fn fillCircle(c: *Canvas, cx: i32, cy: i32, rad: i32, col: u32) void {
        if (!c.enabled) return;
        if (c.s != ONE) {
            var p = c.pixels();
            return p.fillCircle(c.toPx(cx), c.toPx(cy), c.toPx(rad), col);
        }
        const rf: f32 = @floatFromInt(rad);
        var y: i32 = -rad;
        while (y <= rad) : (y += 1) {
            var x: i32 = -rad;
            while (x <= rad) : (x += 1) {
                const d = @sqrt(@as(f32, @floatFromInt(x * x + y * y))) - rf + 0.5;
                if (d <= 0) {
                    c.pixel(cx + x, cy + y, col);
                } else if (d < 1) {
                    c.pixelBlend(cx + x, cy + y, col, @intFromFloat((1 - d) * 256));
                }
            }
        }
    }

    pub fn circle(c: *Canvas, cx: i32, cy: i32, rad: i32, col: u32) void {
        if (!c.enabled) return;
        if (c.s != ONE) {
            var p = c.pixels();
            return p.circle(c.toPx(cx), c.toPx(cy), c.toPx(rad), col);
        }
        const rf: f32 = @floatFromInt(rad);
        var y: i32 = -rad - 1;
        while (y <= rad + 1) : (y += 1) {
            var x: i32 = -rad - 1;
            while (x <= rad + 1) : (x += 1) {
                const d = @abs(@sqrt(@as(f32, @floatFromInt(x * x + y * y))) - rf);
                if (d < 1) c.pixelBlend(cx + x, cy + y, col, @intFromFloat((1 - d) * 256));
            }
        }
    }

    pub fn text(c: *Canvas, x: i32, y: i32, s: []const u8, col: u32) i32 {
        if (!c.enabled) return textWidth(s);
        if (c.s != ONE and tx.loaded) {
            var p = c.pixels();
            const pw = p.ttfText(c.toPx(x), c.toPx(y), s, col);
            return @intCast(@divTrunc((@as(i64, pw) << 16) + c.s - 1, c.s));
        }
        if (tx.loaded) return c.ttfText(x, y, s, col);
        var cx = x;
        for (s) |ch| {
            if (ch == 0xC2) continue; // UTF-8 lead byte of the degree sign
            if (ch == 0xB0) { // degree sign: a small ring
                c.circle(cx + 3, y + 4, 2, col);
                cx += glyph_w;
                continue;
            }
            const g: u8 = if (ch >= 32 and ch <= 126) ch - font.first else '?' - font.first;
            if (cx + glyph_w > c.clip.x and cx < c.clip.right() and y + glyph_h > c.clip.y and y < c.clip.bottom()) {
                for (font.glyphs[g], 0..) |bits, row| {
                    if (bits == 0) continue;
                    var b: u3 = 0;
                    while (true) : (b += 1) {
                        if (bits & (@as(u8, 0x80) >> b) != 0)
                            c.pixel(cx + @as(i32, b), y + @as(i32, @intCast(row)), col);
                        if (b == 7) break;
                    }
                }
            }
            cx += glyph_w;
        }
        return cx - x;
    }

    fn ttfText(c: *Canvas, x: i32, y: i32, s: []const u8, col: u32) i32 {
        const base = y + tx.baseline(face);
        if (y > c.clip.bottom() or y + 96 < c.clip.y) return tx.width(face, s);
        var pen: f32 = @floatFromInt(x);
        // (glyphs placed as the original's: a 16.16 pen, each advance rounded to 1/65536)
        var pen16: i64 = @as(i64, x) << 16;
        var i: usize = 0;
        while (i < s.len) {
            const g = tx.glyph(face, tx.nextCp(s, &i));
            const gx: i32 = @as(i32, @intCast((pen16 + 0x8000) >> 16)) + g.x;
            const gy: i32 = base + g.y;
            pen += g.adv;
            pen16 += @as(i64, @intFromFloat(@round(g.adv * 65536.0)));
            if (g.w == 0 or gx > c.clip.right()) continue;
            const r = (Rect{ .x = gx, .y = gy, .w = g.w, .h = g.h }).intersect(c.clip);
            if (r.w <= 0 or r.h <= 0) continue;
            const px = tx.pixelsOf(g);
            var yy = r.y;
            while (yy < r.bottom()) : (yy += 1) {
                const src = px[@as(usize, @intCast(yy - gy)) * g.w ..];
                const row = c.px + @as(usize, @intCast(yy * c.w));
                var xx = r.x;
                while (xx < r.right()) : (xx += 1) {
                    const a: u32 = src[@intCast(xx - gx)];
                    if (a == 0) continue;
                    const d = &row[@intCast(xx)];
                    d.* = if (a == 255) col else mix(d.*, col, a + (a >> 7));
                }
            }
        }
        return @as(i32, @intFromFloat(@ceil(pen))) - x;
    }

    /// One of the original's 16 x 16 icons in colour col (alpha from the mask).
    pub fn icon(c: *Canvas, x: i32, y: i32, which: Icon, col: u32) void {
        if (!c.enabled) return;
        const m = &icons.masks[@intFromEnum(which)];
        if (c.s != ONE) {
            var p = c.pixels();
            return p.iconScaled(m, c.pxRect(.{ .x = x, .y = y, .w = 16, .h = 16 }), col);
        }
        var yy: i32 = 0;
        while (yy < 16) : (yy += 1) {
            var xx: i32 = 0;
            while (xx < 16) : (xx += 1) {
                const px: i32 = x + xx;
                const py: i32 = y + yy;
                if (!c.clip.contains(px, py)) continue;
                const b = m[@intCast(yy * 8 + @divTrunc(xx, 2))];
                const a4: u32 = if (@mod(xx, 2) == 0) b & 15 else b >> 4;
                if (a4 == 0) continue;
                const d = &c.px[@intCast(py * c.w + px)];
                d.* = if (a4 == 15) col else mix(d.*, col, a4 * 17 + 1);
            }
        }
    }

    /// An icon over r (pixels), as the original: the mask's nearest cell.
    fn iconScaled(c: *Canvas, m: *const [128]u8, r: Rect, col: u32) void {
        const q = r.intersect(c.clip);
        var py = q.y;
        while (py < q.bottom()) : (py += 1) {
            const row = @divTrunc((py - r.y) * 16, r.h);
            var px = q.x;
            while (px < q.right()) : (px += 1) {
                const cl = @divTrunc((px - r.x) * 16, r.w);
                const b = m[@intCast(row * 8 + @divTrunc(cl, 2))];
                const a4: u32 = if (@mod(cl, 2) == 0) b & 15 else b >> 4;
                if (a4 == 0) continue;
                const d = &c.px[@intCast(py * c.w + px)];
                d.* = if (a4 == 15) col else mix(d.*, col, a4 * 17 + 1);
            }
        }
    }

    /// Text cut to maxw pixels, ending in "..." when it does not fit.
    pub fn textFit(c: *Canvas, x: i32, y: i32, maxw: i32, s: []const u8, col: u32) i32 {
        if (textWidth(s) <= maxw) return c.text(x, y, s, col);
        const dots = "...";
        const dw = textWidth(dots);
        if (maxw <= dw) return 0;
        var n = s.len;
        while (n > 0 and textWidth(s[0..n]) + dw > maxw) {
            n -= 1;
            while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1; // whole UTF-8 characters
        }
        const w = c.text(x, y, s[0..n], col);
        return w + c.text(x + w, y, dots, col);
    }

    /// Text vertically centred in r, starting at r.x + pad.
    pub fn textIn(c: *Canvas, r: Rect, pad: i32, s: []const u8, col: u32) void {
        _ = c.text(r.x + pad, r.y + @divTrunc(r.h - glyph_h, 2), s, col);
    }

    pub fn textCentered(c: *Canvas, r: Rect, s: []const u8, col: u32) void {
        _ = c.text(r.x + @divTrunc(r.w - textWidth(s), 2), r.y + @divTrunc(r.h - glyph_h, 2), s, col);
    }

    pub fn textRight(c: *Canvas, r: Rect, pad: i32, s: []const u8, col: u32) void {
        _ = c.text(r.right() - pad - textWidth(s), r.y + @divTrunc(r.h - glyph_h, 2), s, col);
    }

    /// Small filled triangle pointing down (dropdown marker).
    pub fn chevronDown(c: *Canvas, cx: i32, cy: i32, col: u32) void {
        var i: i32 = 0;
        while (i < 4) : (i += 1) c.fill(.{ .x = cx - 3 + i, .y = cy - 1 + i, .w = 7 - 2 * i, .h = 1 }, col);
    }

    pub fn chevronRight(c: *Canvas, cx: i32, cy: i32, col: u32) void {
        var i: i32 = 0;
        while (i < 4) : (i += 1) c.fill(.{ .x = cx - 1 + i, .y = cy - 3 + i, .w = 1, .h = 7 - 2 * i }, col);
    }

    pub fn clearDepth(c: *Canvas, r0: Rect) void {
        const r = r0.intersect(c.full());
        const zb = c.zbuf orelse return;
        const ids = c.ids orelse return;
        var y = r.y;
        while (y < r.y + r.h) : (y += 1) {
            const o: usize = @intCast(y * c.w + r.x);
            @memset(zb[o .. o + @as(usize, @intCast(r.w))], 0); // inverse depth: 0 = infinitely far
            @memset(ids[o .. o + @as(usize, @intCast(r.w))], 0);
        }
    }

    /// Flat-shaded, depth-tested triangle. Points are screen x, y and view depth z.
    /// A line tested against the depth buffer (inverse depths at its ends):
    /// drawn where nothing nearer was rasterized (a little bias in its favour).
    pub fn lineDepth(c: *Canvas, x0f: f32, y0f: f32, iz0: f32, x1f: f32, y1f: f32, iz1: f32, col: u32) void {
        if (!c.enabled) return;
        const zb = c.zbuf orelse return c.line(@intFromFloat(x0f), @intFromFloat(y0f), @intFromFloat(x1f), @intFromFloat(y1f), col);
        const dx = x1f - x0f;
        const dy = y1f - y0f;
        const n: usize = @intFromFloat(@min(20000, @max(@abs(dx), @abs(dy)) + 1));
        var k: usize = 0;
        while (k <= n) : (k += 1) {
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(@max(n, 1)));
            const xi: i32 = @intFromFloat(@round(x0f + dx * t));
            const yi: i32 = @intFromFloat(@round(y0f + dy * t));
            if (!c.clip.contains(xi, yi)) continue;
            const o: usize = @intCast(yi * c.w + xi);
            const iz = iz0 + (iz1 - iz0) * t;
            if (iz * 1.004 + 1e-4 >= zb[o]) c.px[o] = col;
        }
    }

    /// triangle(), also writing each pixel's normal into nb: the corners'
    /// normals interpolated perspective-correct (not unit: the reader
    /// normalizes, so the 1 / depth factor drops out).
    pub fn triangleN(c: *Canvas, p0: [3]f32, p1: [3]f32, p2: [3]f32, n: [3][3]f32, col: u32, id: u16, nb: [*][3]f32) void {
        if (!c.enabled) return;
        const zb = c.zbuf orelse return;
        const ids = c.ids orelse return;
        const minx = @max(@as(f32, @floatFromInt(c.clip.x)), @floor(@min(p0[0], @min(p1[0], p2[0]))));
        const maxx = @min(@as(f32, @floatFromInt(c.clip.right() - 1)), @ceil(@max(p0[0], @max(p1[0], p2[0]))));
        const miny = @max(@as(f32, @floatFromInt(c.clip.y)), @floor(@min(p0[1], @min(p1[1], p2[1]))));
        const maxy = @min(@as(f32, @floatFromInt(c.clip.bottom() - 1)), @ceil(@max(p0[1], @max(p1[1], p2[1]))));
        if (minx > maxx or miny > maxy) return;
        const area = (p1[0] - p0[0]) * (p2[1] - p0[1]) - (p1[1] - p0[1]) * (p2[0] - p0[0]);
        if (@abs(area) < 1e-6) return;
        const inv = 1.0 / area;
        const a0 = (p1[1] - p2[1]) * inv;
        const a1 = (p2[1] - p0[1]) * inv;
        // the normals divided by depth (times inverse depth)
        var q: [3][3]f32 = undefined;
        for (0..3) |k| {
            q[0][k] = n[0][k] * p0[2];
            q[1][k] = n[1][k] * p1[2];
            q[2][k] = n[2][k] * p2[2];
        }
        const y0i: i32 = @intFromFloat(miny);
        const y1: i32 = @intFromFloat(maxy);
        const x0: i32 = @intFromFloat(minx);
        const x1: i32 = @intFromFloat(maxx);
        const fx0 = @as(f32, @floatFromInt(x0)) + 0.5;
        var y = y0i;
        while (y <= y1) : (y += 1) {
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            var w0 = ((p1[0] - fx0) * (p2[1] - fy) - (p1[1] - fy) * (p2[0] - fx0)) * inv;
            var w1 = ((p2[0] - fx0) * (p0[1] - fy) - (p2[1] - fy) * (p0[0] - fx0)) * inv;
            var o: usize = @intCast(y * c.w + x0);
            var x = x0;
            var inside_run = false;
            while (x <= x1) : (x += 1) {
                const w2 = 1.0 - w0 - w1;
                if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                    inside_run = true;
                    const iz = w0 * p0[2] + w1 * p1[2] + w2 * p2[2];
                    if (iz > zb[o]) {
                        zb[o] = iz;
                        ids[o] = id;
                        c.px[o] = col;
                        if (tri_buf) |tb| tb[o] = c.tri orelse cur_tri;
                        nb[o] = .{
                            w0 * q[0][0] + w1 * q[1][0] + w2 * q[2][0],
                            w0 * q[0][1] + w1 * q[1][1] + w2 * q[2][1],
                            w0 * q[0][2] + w1 * q[1][2] + w2 * q[2][2],
                        };
                    }
                } else if (inside_run) break;
                w0 += a0;
                w1 += a1;
                o += 1;
            }
        }
    }

    /// A depth-tested triangle: p = (screen x, screen y, 1 / view depth).
    /// Larger inverse depth is nearer. Edge functions step incrementally.
    pub fn triangle(c: *Canvas, p0: [3]f32, p1: [3]f32, p2: [3]f32, col: u32, id: u16) void {
        if (!c.enabled) return;
        if (sink) |s| return s(p0, p1, p2, col, id);
        const zb = c.zbuf orelse return;
        const ids = c.ids orelse return;
        const minx = @max(@as(f32, @floatFromInt(c.clip.x)), @floor(@min(p0[0], @min(p1[0], p2[0]))));
        const maxx = @min(@as(f32, @floatFromInt(c.clip.right() - 1)), @ceil(@max(p0[0], @max(p1[0], p2[0]))));
        const miny = @max(@as(f32, @floatFromInt(c.clip.y)), @floor(@min(p0[1], @min(p1[1], p2[1]))));
        const maxy = @min(@as(f32, @floatFromInt(c.clip.bottom() - 1)), @ceil(@max(p0[1], @max(p1[1], p2[1]))));
        if (minx > maxx or miny > maxy) return;
        const area = (p1[0] - p0[0]) * (p2[1] - p0[1]) - (p1[1] - p0[1]) * (p2[0] - p0[0]);
        if (@abs(area) < 1e-6) return;
        const inv = 1.0 / area;
        // w0 = ((p1x - x)(p2y - y) - (p1y - y)(p2x - x)) / area, linear in x and y
        const a0 = (p1[1] - p2[1]) * inv;
        const a1 = (p2[1] - p0[1]) * inv;
        const y0i: i32 = @intFromFloat(miny);
        const y1: i32 = @intFromFloat(maxy);
        const x0: i32 = @intFromFloat(minx);
        const x1: i32 = @intFromFloat(maxx);
        const fx0 = @as(f32, @floatFromInt(x0)) + 0.5;
        var y = y0i;
        while (y <= y1) : (y += 1) {
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            var w0 = ((p1[0] - fx0) * (p2[1] - fy) - (p1[1] - fy) * (p2[0] - fx0)) * inv;
            var w1 = ((p2[0] - fx0) * (p0[1] - fy) - (p2[1] - fy) * (p0[0] - fx0)) * inv;
            var o: usize = @intCast(y * c.w + x0);
            var x = x0;
            var inside_run = false;
            while (x <= x1) : (x += 1) {
                const w2 = 1.0 - w0 - w1;
                if (w0 >= 0 and w1 >= 0 and w2 >= 0) {
                    inside_run = true;
                    const iz = w0 * p0[2] + w1 * p1[2] + w2 * p2[2];
                    if (iz > zb[o]) {
                        zb[o] = iz;
                        ids[o] = id;
                        c.px[o] = col;
                    }
                } else if (inside_run) break; // a triangle's row is one span
                w0 += a0;
                w1 += a1;
                o += 1;
            }
        }
    }
};
