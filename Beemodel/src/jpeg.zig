// Baseline JPEG decoding (port of jpeg.s).
//
// SOF0 / SOF1 (8-bit, Huffman), one or three components with any sampling
// factors, interleaved or one scan per component, restart intervals. Codes go
// through a 9-bit lookup with the standard maxcode walk for longer ones; the
// IDCT is a separable float matrix product; chroma is upsampled bilinearly at
// sample centres (libjpeg's "fancy" triangle filter), then YCbCr -> RGB.
// Progressive and arithmetic-coded files are refused.
//
// Stricter than the original, which pads running-out data with zero bits and
// leaves unscanned components black: entropy data that ends early, a component
// no scan covers and tables a scan needs but nobody defined are errors here.
const std = @import("std");

pub const MAX_SIDE = 16384;

pub const Error = error{
    /// damaged or unsupported JPEG
    Damaged,
    /// progressive, lossless or arithmetic-coded
    Progressive,
    /// not one or three components
    Components,
    TooLarge,
    OutOfMemory,
};

/// The decoded image: w * h * 3 bytes, R G B, sRGB.
pub const Pixels = struct {
    w: u32,
    h: u32,
    rgb: []u8,

    pub fn deinit(self: *Pixels, a: std.mem.Allocator) void {
        a.free(self.rgb);
        self.* = undefined;
    }
};

const MAXC = 3;
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

const Huff = struct {
    fast: [512]u16, // len << 8 | symbol, 0: a longer code
    maxc: [18]i32, // max code per length (-1: none)
    vptr: [17]i32,
    minc: [17]i32,
    vals: [256]u8,
    ok: bool,
};

const Comp = struct {
    id: u8 = 0,
    h: u32 = 0,
    v: u32 = 0,
    tq: u32 = 0,
    td: u32 = 0,
    ta: u32 = 0,
    pred: i32 = 0,
    bw: u32 = 0, // blocks across (padded to MCUs)
    bh: u32 = 0,
    cw: u32 = 0, // samples across, rounded up (non-interleaved)
    ch: u32 = 0,
    plane: []u8 = &.{},
    scanned: bool = false,
};

const V8 = @Vector(8, f32);

const D = struct {
    a: std.mem.Allocator,
    f: []const u8,
    t: [8][8]f32, // IDCT basis T[u][x] = C(u) cos((2x+1)u pi/16) / 2
    q: [4][64]f32, // zigzag order
    q_ok: [4]bool = @splat(false),
    dc: [4]Huff,
    ac: [4]Huff,
    comp: [MAXC]Comp = @splat(.{}),
    p: usize = 0, // entropy data cursor
    bits: u64 = 0, // MSB-aligned
    cnt: u32 = 0,
    pad: u32 = 0, // how many of the last `cnt` bits are made up (past the data)
    marker: u8 = 0, // a marker met inside the data
    w: u32 = 0,
    h: u32 = 0,
    nc: u32 = 0,
    hmax: u32 = 1,
    vmax: u32 = 1,
    mcux: u32 = 0,
    mcuy: u32 = 0,
    ri: u32 = 0,
    sof: bool = false,
    ns: u32 = 0,
    scomp: [MAXC]u32 = @splat(0),

    fn fill(d: *D) void {
        while (d.cnt <= 56) {
            var b: u64 = 0;
            if (d.marker == 0 and d.p < d.f.len) {
                const c = d.f[d.p];
                if (c == 0xff and d.p + 1 < d.f.len) {
                    const n = d.f[d.p + 1];
                    if (n == 0) { // FF 00: a data FF
                        b = 0xff;
                        d.p += 2;
                    } else { // a marker: stop here (on the FF)
                        d.marker = n;
                        d.pad += 8;
                    }
                } else {
                    b = c;
                    d.p += 1;
                }
            } else d.pad += 8;
            d.bits |= b << @intCast(56 - d.cnt);
            d.cnt += 8;
        }
    }

    fn getbits(d: *D, n: u32) i32 {
        if (d.cnt < n) d.fill();
        const r = d.bits >> @intCast(64 - n);
        d.bits <<= @intCast(n);
        d.cnt -= n;
        return @intCast(r);
    }

    fn huff(d: *D, t: *const Huff) Error!u8 {
        if (d.cnt < 16) d.fill();
        const e = t.fast[@intCast(d.bits >> 55)];
        if (e != 0) {
            const l: u32 = e >> 8;
            d.bits <<= @intCast(l);
            d.cnt -= l;
            return @truncate(e);
        }
        var l: u32 = 10;
        while (l <= 16) : (l += 1) {
            const code: i32 = @intCast(d.bits >> @intCast(64 - l));
            if (code <= t.maxc[l]) {
                d.bits <<= @intCast(l);
                d.cnt -= l;
                const i = code - t.minc[l] + t.vptr[l];
                if (i < 0 or i > 255) return error.Damaged;
                return t.vals[@intCast(i)];
            }
        }
        return error.Damaged;
    }

    /// One 8 x 8 block of samples into the component's plane.
    fn block(d: *D, c: *Comp, bx: u32, by: u32) Error!void {
        var blk: [64]f32 = @splat(0);
        const q = &d.q[c.tq];
        const s = try d.huff(&d.dc[c.td]);
        if (s > 16) return error.Damaged;
        const diff: i32 = if (s == 0) 0 else extend(d.getbits(s), s);
        c.pred +%= diff;
        blk[0] = @as(f32, @floatFromInt(c.pred)) * q[0];
        const ac = &d.ac[c.ta];
        var k: u32 = 1;
        while (k < 64) {
            const rs = try d.huff(ac);
            const ss: u32 = rs & 15;
            const r: u32 = rs >> 4;
            if (ss == 0) {
                if (r != 15) break; // end of block
                k += 16;
                continue;
            }
            k += r;
            if (k > 63) return error.Damaged;
            const v = extend(d.getbits(ss), ss);
            blk[zigzag[k]] = @as(f32, @floatFromInt(v)) * q[k];
            k += 1;
        }
        // the data ended inside this block
        if (d.cnt < d.pad) return error.Damaged;
        const stride = @as(usize, c.bw) * 8;
        d.idct(&blk, c.plane[(@as(usize, by) * stride + bx) * 8 ..], stride);
    }

    /// blk -> 8 x 8 samples (+128, clamped).
    fn idct(d: *const D, blk: *const [64]f32, dst: []u8, stride: usize) void {
        var tmp: [8]V8 = undefined;
        for (0..8) |r| {
            var v: V8 = @splat(0);
            for (0..8) |u| {
                const c = blk[r * 8 + u];
                if (c != 0) v += @as(V8, d.t[u]) * @as(V8, @splat(c));
            }
            tmp[r] = v;
        }
        for (0..8) |y| {
            var v: V8 = @splat(0);
            for (0..8) |u| v += tmp[u] * @as(V8, @splat(d.t[u][y]));
            const s: [8]f32 = v + @as(V8, @splat(128.5));
            const row = dst[y * stride ..][0..8];
            for (row, s) |*o, e| o.* = @intFromFloat(@min(@max(e, 0), 255));
        }
    }

    /// After RSTn: byte align, skip the marker, reset the predictions.
    fn restart(d: *D) Error!void {
        d.bits = 0;
        d.cnt = 0;
        d.pad = 0;
        if (isRst(d.marker)) {
            d.p += 2; // (it sits on the FF)
        } else { // not yet seen: look for it
            var q = d.p;
            while (true) : (q += 1) {
                if (q + 1 >= d.f.len) return error.Damaged;
                if (d.f[q] == 0xff and isRst(d.f[q + 1])) break;
            }
            d.p = q + 2;
        }
        d.marker = 0;
        for (&d.comp) |*c| c.pred = 0;
    }

    fn scan(d: *D) Error!void {
        d.bits = 0;
        d.cnt = 0;
        d.pad = 0;
        d.marker = 0;
        for (&d.comp) |*c| c.pred = 0;
        var units: u32 = 0;
        if (d.ns == 1) { // one component: its own block grid
            const c = &d.comp[d.scomp[0]];
            const bw = (c.cw + 7) / 8;
            const bh = (c.ch + 7) / 8;
            for (0..bh) |by| for (0..bw) |bx| {
                try d.restartCheck(&units);
                try d.block(c, @intCast(bx), @intCast(by));
            };
        } else {
            for (0..d.mcuy) |my| for (0..d.mcux) |mx| {
                try d.restartCheck(&units);
                for (d.scomp[0..d.ns]) |ci| {
                    const c = &d.comp[ci];
                    for (0..c.v) |v| for (0..c.h) |h| {
                        try d.block(c, @intCast(mx * c.h + h), @intCast(my * c.v + v));
                    };
                }
            };
        }
    }

    fn restartCheck(d: *D, units: *u32) Error!void {
        if (d.ri == 0) return;
        if (units.* >= d.ri) {
            try d.restart();
            units.* = 0;
        }
        units.* += 1;
    }

    fn dqt(d: *D, seg: []const u8) Error!void {
        var i: usize = 0;
        while (i < seg.len) {
            const pq = seg[i] >> 4;
            const t = seg[i] & 3;
            i += 1;
            const n: usize = if (pq == 0) 64 else 128;
            if (seg.len - i < n) return error.Damaged;
            for (0..64) |k| {
                const v: u32 = if (pq == 0) seg[i + k] else @as(u32, seg[i + 2 * k]) << 8 | seg[i + 2 * k + 1];
                d.q[t][k] = @floatFromInt(v);
            }
            d.q_ok[t] = true;
            i += n;
        }
    }

    fn dht(d: *D, seg: []const u8) Error!void {
        var i: usize = 0;
        while (seg.len - i >= 17) {
            const t: *Huff = if (seg[i] & 0xf0 == 0) &d.dc[seg[i] & 3] else &d.ac[seg[i] & 3];
            i = try buildHuff(t, seg, i + 1);
        }
    }

    fn startOfFrame(d: *D, s: []const u8, rest: usize) Error!void {
        if (d.sof) return error.Damaged;
        if (s.len < 6 or s[0] != 8) return error.Damaged;
        const h = be16(s[1..]);
        const w = be16(s[3..]);
        const nc = s[5];
        if (nc != 1 and nc != 3) return error.Components;
        if (w == 0 or h == 0) return error.Damaged; // (DNL heights: unsupported)
        if (w > MAX_SIDE or h > MAX_SIDE) return error.TooLarge;
        if (s.len < 6 + @as(usize, nc) * 3) return error.Damaged;
        d.w = w;
        d.h = h;
        d.nc = nc;
        for (0..nc) |i| {
            const c = &d.comp[i];
            const e = s[6 + i * 3 ..];
            c.id = e[0];
            c.h = e[1] >> 4;
            c.v = e[1] & 15;
            if (c.h == 0 or c.v == 0 or c.h > 4 or c.v > 4) return error.Damaged;
            c.tq = e[2] & 3;
            d.hmax = @max(d.hmax, c.h);
            d.vmax = @max(d.vmax, c.v);
        }
        d.mcux = (w + d.hmax * 8 - 1) / (d.hmax * 8);
        d.mcuy = (h + d.vmax * 8 - 1) / (d.vmax * 8);
        // A block takes at least two bits, so the data left bounds the image:
        // a tiny file cannot ask for gigabytes.
        var blocks: u64 = 0;
        for (d.comp[0..nc]) |*c| {
            c.bw = d.mcux * c.h;
            c.bh = d.mcuy * c.v;
            c.cw = (w * c.h + d.hmax - 1) / d.hmax;
            c.ch = (h * c.v + d.vmax - 1) / d.vmax;
            blocks += @as(u64, (c.cw + 7) / 8) * ((c.ch + 7) / 8);
        }
        if (blocks / 4 > rest) return error.Damaged;
        for (d.comp[0..nc]) |*c| {
            const bytes = @as(usize, c.bw) * c.bh * 64;
            c.plane = try d.a.alloc(u8, bytes);
            @memset(c.plane, 0);
        }
        d.sof = true;
    }

    fn startOfScan(d: *D, s: []const u8) Error!void {
        if (!d.sof or s.len == 0) return error.Damaged;
        const ns = s[0];
        if (ns == 0 or ns > d.nc or s.len < 1 + @as(usize, ns) * 2) return error.Damaged;
        d.ns = ns;
        for (0..ns) |i| {
            const id = s[1 + i * 2];
            const tabs = s[2 + i * 2];
            const ci = for (d.comp[0..d.nc], 0..) |c, k| {
                if (c.id == id) break k;
            } else return error.Damaged;
            for (d.scomp[0..i]) |o| if (o == ci) return error.Damaged;
            d.scomp[i] = @intCast(ci);
            const c = &d.comp[ci];
            c.td = (tabs >> 4) & 3;
            c.ta = tabs & 3;
            if (!d.dc[c.td].ok or !d.ac[c.ta].ok or !d.q_ok[c.tq]) return error.Damaged;
            c.scanned = true;
        }
        try d.scan();
    }

    /// The sample of a component at an image pixel's centre.
    fn sample(d: *const D, c: *const Comp, x: u32, y: u32) f32 {
        const stride = @as(usize, c.bw) * 8;
        if (c.h == d.hmax and c.v == d.vmax) return @floatFromInt(c.plane[y * stride + x]);
        const fx = @max(0, (@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(c.h)) /
            @as(f32, @floatFromInt(d.hmax)) - 0.5);
        const fy = @max(0, (@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(c.v)) /
            @as(f32, @floatFromInt(d.vmax)) - 0.5);
        const ix: u32 = @intFromFloat(fx);
        const iy: u32 = @intFromFloat(fy);
        const tx = fx - @as(f32, @floatFromInt(ix));
        const ty = fy - @as(f32, @floatFromInt(iy));
        const x0 = @min(ix, c.cw - 1);
        const y0 = @min(iy, c.ch - 1);
        const x1 = @min(x0 + 1, c.cw - 1);
        const y1 = @min(y0 + 1, c.ch - 1);
        const r0 = c.plane[y0 * stride ..];
        const r1 = c.plane[y1 * stride ..];
        const a0: f32 = @floatFromInt(r0[x0]);
        const b0: f32 = @floatFromInt(r0[x1]);
        const a1: f32 = @floatFromInt(r1[x0]);
        const b1: f32 = @floatFromInt(r1[x1]);
        const top = a0 + (b0 - a0) * tx;
        const bot = a1 + (b1 - a1) * tx;
        return top + (bot - top) * ty;
    }

    fn toRgb(d: *const D) Error!Pixels {
        const n = @as(usize, d.w) * d.h * 3;
        const rgb = try d.a.alloc(u8, n);
        var o: usize = 0;
        for (0..d.h) |yy| for (0..d.w) |xx| {
            const x: u32 = @intCast(xx);
            const y: u32 = @intCast(yy);
            const l = d.sample(&d.comp[0], x, y);
            if (d.nc == 1) {
                const g = clamp8(l);
                rgb[o..][0..3].* = .{ g, g, g };
            } else {
                const cb = d.sample(&d.comp[1], x, y) - 128;
                const cr = d.sample(&d.comp[2], x, y) - 128;
                rgb[o] = clamp8(cr * 1.402 + l);
                rgb[o + 1] = clamp8(cb * -0.344136 + cr * -0.714136 + l);
                rgb[o + 2] = clamp8(cb * 1.772 + l);
            }
            o += 3;
        };
        return .{ .w = d.w, .h = d.h, .rgb = rgb };
    }
};

fn isRst(m: u8) bool {
    return m >= 0xd0 and m <= 0xd7;
}

fn be16(b: []const u8) u32 {
    return @as(u32, b[0]) << 8 | b[1];
}

fn clamp8(v: f32) u8 {
    return @intFromFloat(@min(@max(v, 0), 255) + 0.5);
}

fn extend(v: i32, s: u32) i32 {
    const top = @as(i32, 1) << @intCast(s - 1);
    if (v >= top) return v;
    return v + (@as(i32, -1) << @intCast(s)) + 1;
}

/// The table from the counts at seg[i..]; returns the offset after its symbols.
fn buildHuff(t: *Huff, seg: []const u8, i: usize) Error!usize {
    const counts = seg[i..][0..16];
    var total: usize = 0;
    for (counts) |c| total += c;
    if (total > 256 or seg.len - i - 16 < total) return error.Damaged;
    t.fast = @splat(0);
    @memcpy(t.vals[0..total], seg[i + 16 ..][0..total]);
    var code: u32 = 0;
    var si: u32 = 0;
    for (1..17) |l| {
        var n: u32 = counts[l - 1];
        t.vptr[l] = @intCast(si);
        t.minc[l] = @intCast(code);
        t.maxc[l] = -1;
        if (n != 0) {
            if (code + n > @as(u32, 1) << @intCast(l)) return error.Damaged; // over-subscribed
            while (n != 0) : (n -= 1) {
                if (l <= 9) {
                    const sh: u5 = @intCast(9 - l);
                    const first = code << sh;
                    const e: u16 = @intCast(l << 8 | t.vals[si]);
                    @memset(t.fast[first..][0 .. @as(usize, 1) << sh], e);
                }
                code += 1;
                si += 1;
            }
            t.maxc[l] = @intCast(code - 1);
        }
        code *= 2;
    }
    t.ok = true;
    return i + 16 + total;
}

/// Decode a JPEG file (it starts FF D8).
pub fn decode(a: std.mem.Allocator, f: []const u8) Error!Pixels {
    if (f.len < 4 or f[0] != 0xff or f[1] != 0xd8) return error.Damaged;
    const d = try a.create(D);
    defer a.destroy(d);
    d.* = .{ .a = a, .f = f, .t = undefined, .q = undefined, .dc = undefined, .ac = undefined };
    for (&d.dc) |*t| t.ok = false;
    for (&d.ac) |*t| t.ok = false;
    for (0..8) |u| for (0..8) |x| {
        var v = std.math.cos(@as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16);
        if (u == 0) v /= std.math.sqrt(2.0);
        d.t[u][x] = @floatCast(v / 2);
    };
    defer for (d.comp) |c| a.free(c.plane);

    var p: usize = 2;
    seg: while (f.len - p >= 4) {
        if (f[p] != 0xff or f[p + 1] == 0xff) { // (fill bytes)
            p += 1;
            continue;
        }
        const m = f[p + 1];
        if (m == 0xd9) break; // EOI
        if (isRst(m) or m == 0x01) { // stray RSTn / TEM: no length
            p += 2;
            continue;
        }
        const len = be16(f[p + 2 ..]);
        if (len < 2 or len > f.len - p - 2) return error.Damaged;
        const next = p + 2 + len;
        const s = f[p + 4 .. next];
        switch (m) {
            0xdb => try d.dqt(s),
            0xc4 => try d.dht(s),
            0xc0, 0xc1 => try d.startOfFrame(s, f.len - next),
            0xc2, 0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => return error.Progressive,
            0xdd => {
                if (s.len < 2) return error.Damaged;
                d.ri = be16(s);
            },
            0xda => {
                d.p = next;
                try d.startOfScan(s);
                // continue after the data: the next marker that isn't RSTn / FF00
                p = d.p;
                while (true) : (p += 1) {
                    if (f.len - p < 2) break :seg;
                    if (f[p] == 0xff and f[p + 1] != 0 and !isRst(f[p + 1])) break;
                }
                continue;
            },
            else => {},
        }
        p = next;
    }
    if (!d.sof) return error.Damaged;
    for (d.comp[0..d.nc]) |c| if (!c.scanned) return error.Damaged;
    return d.toRgb();
}
