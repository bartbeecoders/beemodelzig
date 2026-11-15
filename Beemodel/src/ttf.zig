// TrueType fonts without FreeType, like the original's ttf.s: table parsing
// (cmap 4 / 12, loca, glyf, hmtx), simple and composite glyph outlines, an
// anti-aliased signed-area rasterizer (the font-rs approach: every edge adds
// signed coverage to an accumulation buffer, a running sum turns it into
// exact area coverage; quadratic curves are flattened to lines) and a glyph
// cache. Fonts are read from the system at start-up, nothing is embedded.
const std = @import("std");
const linux = std.os.linux;

pub const Font = struct {
    data: []const u8 = &.{},
    units: f32 = 1000,
    ascent: f32 = 0, // font units
    descent: f32 = 0, // font units, negative
    loca_long: bool = false,
    num_glyphs: u16 = 0,
    num_hmetrics: u16 = 0,
    cmap: usize = 0, // the chosen subtable (format 4 or 12)
    cmap_fmt: u16 = 0,
    loca: usize = 0,
    glyf: usize = 0,
    hmtx: usize = 0,

    fn u16At(f: *const Font, o: usize) u16 {
        if (o + 2 > f.data.len) return 0;
        return std.mem.readInt(u16, f.data[o..][0..2], .big);
    }
    fn i16At(f: *const Font, o: usize) i16 {
        return @bitCast(f.u16At(o));
    }
    fn u32At(f: *const Font, o: usize) u32 {
        if (o + 4 > f.data.len) return 0;
        return std.mem.readInt(u32, f.data[o..][0..4], .big);
    }

    fn table(f: *const Font, tag: *const [4]u8) ?usize {
        const n = f.u16At(4);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = 12 + i * 16;
            if (rec + 16 > f.data.len) return null;
            if (std.mem.eql(u8, f.data[rec..][0..4], tag)) {
                const off = f.u32At(rec + 8);
                return if (off < f.data.len) off else null;
            }
        }
        return null;
    }

    pub fn parse(data: []const u8) ?Font {
        var f = Font{ .data = data };
        if (data.len < 12) return null;
        const head = f.table("head") orelse return null;
        const hhea = f.table("hhea") orelse return null;
        const maxp = f.table("maxp") orelse return null;
        const cmap = f.table("cmap") orelse return null;
        f.loca = f.table("loca") orelse return null;
        f.glyf = f.table("glyf") orelse return null;
        f.hmtx = f.table("hmtx") orelse return null;
        f.units = @floatFromInt(@max(16, f.u16At(head + 18)));
        f.loca_long = f.i16At(head + 50) != 0;
        f.ascent = @floatFromInt(f.i16At(hhea + 4));
        f.descent = @floatFromInt(f.i16At(hhea + 6));
        f.num_hmetrics = f.u16At(hhea + 34);
        f.num_glyphs = f.u16At(maxp + 4);
        // prefer a Unicode full-repertoire table (format 12), else BMP (4)
        const n = f.u16At(cmap + 2);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = cmap + 4 + i * 8;
            const pid = f.u16At(rec);
            const eid = f.u16At(rec + 2);
            const sub = cmap + f.u32At(rec + 4);
            const fmt = f.u16At(sub);
            const unicode = pid == 0 or (pid == 3 and (eid == 1 or eid == 10));
            if (!unicode) continue;
            if (fmt == 12 or (fmt == 4 and f.cmap_fmt != 12)) {
                f.cmap = sub;
                f.cmap_fmt = fmt;
            }
        }
        if (f.cmap_fmt == 0) return null;
        return f;
    }

    pub fn glyphIndex(f: *const Font, cp: u32) u16 {
        if (f.cmap_fmt == 12) {
            const groups = f.u32At(f.cmap + 12);
            var lo: u32 = 0;
            var hi: u32 = groups;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const g = f.cmap + 16 + mid * 12;
                const start = f.u32At(g);
                const end = f.u32At(g + 4);
                if (cp < start) {
                    hi = mid;
                } else if (cp > end) {
                    lo = mid + 1;
                } else return @truncate(f.u32At(g + 8) + (cp - start));
            }
            return 0;
        }
        if (cp > 0xffff) return 0;
        const segx2 = f.u16At(f.cmap + 6);
        const ends = f.cmap + 14;
        const starts = ends + segx2 + 2;
        const deltas = starts + segx2;
        const ranges = deltas + segx2;
        var s: usize = 0;
        while (s < segx2) : (s += 2) {
            if (f.u16At(ends + s) < cp) continue;
            const start = f.u16At(starts + s);
            if (cp < start) return 0;
            const delta = f.u16At(deltas + s);
            const ro = f.u16At(ranges + s);
            if (ro == 0) return @truncate((cp +% delta) & 0xffff);
            const gi = f.u16At(ranges + s + ro + (cp - start) * 2);
            return if (gi == 0) 0 else @truncate((gi +% delta) & 0xffff);
        }
        return 0;
    }

    pub fn advance(f: *const Font, g: u16) f32 {
        const i = @min(g, f.num_hmetrics -| 1);
        return @floatFromInt(f.u16At(f.hmtx + @as(usize, i) * 4));
    }

    fn glyphRange(f: *const Font, g: u16) ?[2]usize {
        if (g >= f.num_glyphs) return null;
        const a: usize = if (f.loca_long) f.u32At(f.loca + @as(usize, g) * 4) else @as(usize, f.u16At(f.loca + @as(usize, g) * 2)) * 2;
        const b: usize = if (f.loca_long) f.u32At(f.loca + @as(usize, g) * 4 + 4) else @as(usize, f.u16At(f.loca + @as(usize, g) * 2 + 2)) * 2;
        if (b <= a) return null; // empty glyph (space)
        return .{ f.glyf + a, f.glyf + b };
    }

    /// Calls sink.line(x0, y0, x1, y1) for the flattened outline of glyph g,
    /// in font units transformed by m (a b c d e f: x' = a x + c y + e).
    pub fn outline(f: *const Font, g: u16, m: [6]f32, sink: anytype, depth: u8) void {
        const r = f.glyphRange(g) orelse return;
        const o = r[0];
        const ncont = f.i16At(o);
        if (ncont < 0) {
            if (depth > 4) return;
            f.composite(o + 10, r[1], m, sink, depth);
            return;
        }
        const nc: usize = @intCast(ncont);
        if (nc == 0) return;
        const ends_o = o + 10;
        const npts: usize = @as(usize, f.u16At(ends_o + (nc - 1) * 2)) + 1;
        if (npts > 2048) return;
        const ins_len = f.u16At(ends_o + nc * 2);
        var p = ends_o + nc * 2 + 2 + ins_len;
        var flags: [2048]u8 = undefined;
        var xs: [2048]f32 = undefined;
        var ys: [2048]f32 = undefined;
        var i: usize = 0;
        while (i < npts) {
            if (p >= f.data.len) return;
            const fl = f.data[p];
            p += 1;
            var rep: usize = 1;
            if (fl & 8 != 0) {
                if (p >= f.data.len) return;
                rep += f.data[p];
                p += 1;
            }
            while (rep > 0 and i < npts) : (rep -= 1) {
                flags[i] = fl;
                i += 1;
            }
        }
        var v: i32 = 0;
        for (0..npts) |k| {
            const fl = flags[k];
            if (fl & 2 != 0) {
                if (p >= f.data.len) return;
                const d: i32 = f.data[p];
                p += 1;
                v += if (fl & 16 != 0) d else -d;
            } else if (fl & 16 == 0) {
                v += f.i16At(p);
                p += 2;
            }
            xs[k] = @floatFromInt(v);
        }
        v = 0;
        for (0..npts) |k| {
            const fl = flags[k];
            if (fl & 4 != 0) {
                if (p >= f.data.len) return;
                const d: i32 = f.data[p];
                p += 1;
                v += if (fl & 32 != 0) d else -d;
            } else if (fl & 32 == 0) {
                v += f.i16At(p);
                p += 2;
            }
            ys[k] = @floatFromInt(v);
        }
        // contours: on-curve points and quadratic control points (two
        // off-curve points in a row imply an on-curve one between them)
        var start: usize = 0;
        for (0..nc) |c| {
            const end: usize = f.u16At(ends_o + c * 2);
            if (end < start or end >= npts) return;
            const n = end - start + 1;
            // find a starting on-curve point (or make one)
            var sx: f32 = undefined;
            var sy: f32 = undefined;
            var first: usize = 0;
            if (flags[start] & 1 != 0) {
                sx = xs[start];
                sy = ys[start];
                first = 1;
            } else if (flags[end] & 1 != 0) {
                sx = xs[end];
                sy = ys[end];
                first = 0;
            } else {
                sx = (xs[start] + xs[end]) / 2;
                sy = (ys[start] + ys[end]) / 2;
                first = 0;
            }
            var px = sx;
            var py = sy;
            var cx: f32 = 0;
            var cy: f32 = 0;
            var has_ctrl = false;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const idx = start + (first + k) % n;
                const x = xs[idx];
                const y = ys[idx];
                if (flags[idx] & 1 != 0) {
                    if (has_ctrl) quad(sink, m, px, py, cx, cy, x, y) else lineT(sink, m, px, py, x, y);
                    px = x;
                    py = y;
                    has_ctrl = false;
                } else {
                    if (has_ctrl) {
                        const mx = (cx + x) / 2;
                        const my = (cy + y) / 2;
                        quad(sink, m, px, py, cx, cy, mx, my);
                        px = mx;
                        py = my;
                    }
                    cx = x;
                    cy = y;
                    has_ctrl = true;
                }
            }
            if (has_ctrl) quad(sink, m, px, py, cx, cy, sx, sy) else lineT(sink, m, px, py, sx, sy);
            start = end + 1;
        }
    }

    fn composite(f: *const Font, o0: usize, end: usize, m: [6]f32, sink: anytype, depth: u8) void {
        var o = o0;
        while (o + 4 <= end) {
            const fl = f.u16At(o);
            const g = f.u16At(o + 2);
            o += 4;
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (fl & 1 != 0) {
                if (fl & 2 != 0) {
                    dx = @floatFromInt(f.i16At(o));
                    dy = @floatFromInt(f.i16At(o + 2));
                }
                o += 4;
            } else {
                if (fl & 2 != 0) {
                    dx = @floatFromInt(@as(i8, @bitCast(f.data[o])));
                    dy = @floatFromInt(@as(i8, @bitCast(f.data[o + 1])));
                }
                o += 2;
            }
            var a: f32 = 1;
            var b: f32 = 0;
            var c: f32 = 0;
            var d: f32 = 1;
            const f2 = struct {
                fn v(ff: *const Font, at: usize) f32 {
                    return @as(f32, @floatFromInt(ff.i16At(at))) / 16384.0;
                }
            }.v;
            if (fl & 8 != 0) {
                a = f2(f, o);
                d = a;
                o += 2;
            } else if (fl & 0x40 != 0) {
                a = f2(f, o);
                d = f2(f, o + 2);
                o += 4;
            } else if (fl & 0x80 != 0) {
                a = f2(f, o);
                b = f2(f, o + 2);
                c = f2(f, o + 4);
                d = f2(f, o + 6);
                o += 8;
            }
            // child transform then ours
            const cm = [6]f32{
                m[0] * a + m[2] * b, m[1] * a + m[3] * b,
                m[0] * c + m[2] * d, m[1] * c + m[3] * d,
                m[0] * dx + m[2] * dy + m[4], m[1] * dx + m[3] * dy + m[5],
            };
            f.outline(g, cm, sink, depth + 1);
            if (fl & 0x20 == 0) break; // MORE_COMPONENTS
        }
    }
};

fn lineT(sink: anytype, m: [6]f32, x0: f32, y0: f32, x1: f32, y1: f32) void {
    sink.line(m[0] * x0 + m[2] * y0 + m[4], m[1] * x0 + m[3] * y0 + m[5], m[0] * x1 + m[2] * y1 + m[4], m[1] * x1 + m[3] * y1 + m[5]);
}

fn quad(sink: anytype, m: [6]f32, x0: f32, y0: f32, cx: f32, cy: f32, x1: f32, y1: f32) void {
    // flatten: enough segments for about a quarter-pixel error
    const ax = m[0] * x0 + m[2] * y0 + m[4];
    const ay = m[1] * x0 + m[3] * y0 + m[5];
    const bx = m[0] * cx + m[2] * cy + m[4];
    const by = m[1] * cx + m[3] * cy + m[5];
    const ex = m[0] * x1 + m[2] * y1 + m[4];
    const ey = m[1] * x1 + m[3] * y1 + m[5];
    const ddx = ax - 2 * bx + ex;
    const ddy = ay - 2 * by + ey;
    const dd = @sqrt(ddx * ddx + ddy * ddy);
    const n: usize = @intFromFloat(@min(16.0, @max(1.0, @ceil(@sqrt(dd * 2)))));
    var px = ax;
    var py = ay;
    for (1..n + 1) |k| {
        const t: f32 = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        const u = 1 - t;
        const qx = u * u * ax + 2 * u * t * bx + t * t * ex;
        const qy = u * u * ay + 2 * u * t * by + t * t * ey;
        sink.line(px, py, qx, qy);
        px = qx;
        py = qy;
    }
}

/// The accumulation rasterizer: lines add signed area to `acc` (w x h
/// pixels, y down); coverage() sums each row into 0..255 alpha.
pub const Raster = struct {
    acc: []f32,
    w: usize,
    h: usize,

    pub fn line(r: *Raster, x0: f32, y0: f32, x1: f32, y1: f32) void {
        if (y0 == y1) return;
        var dir: f32 = 1;
        var ax = x0;
        var ay = y0;
        var bx = x1;
        var by = y1;
        if (ay > by) {
            dir = -1;
            std.mem.swap(f32, &ax, &bx);
            std.mem.swap(f32, &ay, &by);
        }
        const fh: f32 = @floatFromInt(r.h);
        const fw: f32 = @floatFromInt(r.w);
        const dxdy = (bx - ax) / (by - ay);
        var x = ax;
        if (ay < 0) x -= ay * dxdy;
        const y_start: usize = @intFromFloat(@max(0, ay));
        const y_end: usize = @intFromFloat(@min(fh, @ceil(by)));
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const fy: f32 = @floatFromInt(y);
            const dy = @min(fy + 1, by) - @max(fy, ay);
            const xnext = x + dxdy * dy;
            const d = dy * dir;
            const lo = @min(x, xnext);
            const hi = @max(x, xnext);
            const row = y * r.w;
            if (lo >= fw) {
                // past the right edge: nothing to add inside
            } else {
                const x0i: usize = @intFromFloat(@max(0, @floor(lo)));
                const x0f = lo - @as(f32, @floatFromInt(x0i));
                const x1c = @ceil(hi);
                const x1i: usize = @intFromFloat(@max(0, x1c));
                if (x1i <= x0i + 1) {
                    const xmf = 0.5 * (x + xnext) - @as(f32, @floatFromInt(x0i));
                    if (x0i < r.w) r.acc[row + x0i] += d - d * xmf;
                    if (x0i + 1 < r.w) r.acc[row + x0i + 1] += d * xmf;
                } else {
                    const s = 1.0 / (hi - lo);
                    const x0f2 = 1 - x0f;
                    const a0 = 0.5 * s * x0f2 * x0f2;
                    const x1f = hi - x1c + 1;
                    const am = 0.5 * s * x1f * x1f;
                    if (x0i < r.w) r.acc[row + x0i] += d * a0;
                    if (x1i == x0i + 2) {
                        if (x0i + 1 < r.w) r.acc[row + x0i + 1] += d * (1.0 - a0 - am);
                    } else {
                        const a1 = s * (1.5 - x0f);
                        if (x0i + 1 < r.w) r.acc[row + x0i + 1] += d * (a1 - a0);
                        var xi = x0i + 2;
                        while (xi < x1i - 1) : (xi += 1) {
                            if (xi < r.w) r.acc[row + xi] += d * s;
                        }
                        const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                        if (x1i - 1 < r.w) r.acc[row + x1i - 1] += d * (1.0 - a2 - am);
                    }
                    if (x1i < r.w) r.acc[row + x1i] += d * am;
                }
            }
            x = xnext;
        }
    }
};

// --- loading -----------------------------------------------------------------

/// Read a whole file (mapped read-only). Null when it is not there.
pub fn mapFile(path: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const p: [*:0]const u8 = @ptrCast(&buf);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size) != .SUCCESS or size == 0 or size > 4 << 30) return null;
    const mp = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(mp) != .SUCCESS) return null;
    const ptr: [*]const u8 = @ptrFromInt(mp);
    return ptr[0..size];
}
