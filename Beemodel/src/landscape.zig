//! Landscapes (landscape.s): heightfields of N x N samples (65 to 4097 a side)
//! over a square of a chosen size, centred on the object, on its XZ plane.
//!
//! A landscape is a mesh object whose mesh carries a landscape block (ME_LAND,
//! scene.Mesh.land): one reference-counted mapping, shared like meshes, so undo
//! steps and copies share it. Every change makes a new block and a new display
//! mesh (a grid of the heights, at most 513 a side: every 2nd, 4th ... sample of
//! a bigger landscape). The block is the original's to the byte (the LAND chunk
//! writes it as it is):
//!
//!   a header (Header: up to 8 layers of 64 bytes, up to 8 paint layers), then
//!   page-aligned arrays at offsets the header keeps (0: none): the heights
//!   (f32 N x N, row-major: row j along Z, sample i along X), the cache (the
//!   heights after the last erosion layer, so changes above it start from
//!   there), each layer's own data (Sculpted: offsets added; Flatten area: its
//!   mask), the splat map (u8 x 8 a sample).
//!
//! The layers, bottom up, a non-destructive stack (each has a strength and can
//! be hidden): Generate (fBm, ridged, billow, Voronoi cells), Erode (droplets,
//! then thermal), Terrace, Sculpted, Flatten, Heightmap (imported, added).
//! Generating runs on every core (rows); erosion on one, its result cached.
const std = @import("std");
const linux = std.os.linux;
const m = @import("math.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const jobs = @import("jobs.zig");
const shgraph = @import("shgraph.zig");
const procgen = @import("procgen.zig");
const ntree = @import("ntree.zig");

const cvtt = procgen.cvtt;
const cvt = procgen.cvt;
const minss = procgen.minss;
const maxss = procgen.maxss;
const Impl = ops.Impl;

const TINY: f32 = 1.0e-6;
pub const LA_MAXL = 8;
pub const LA_MAXP = 8;
pub const LA_DISP = 513;
pub const LB_DATA = 4096;
pub const OBF_WATER: u32 = 0x8000;

/// A layer (LY_, 64 bytes).
pub const Layer = extern struct {
    /// 1 generate 2 erode 3 terrace 4 sculpted 5 flatten 6 heightmap
    typ: u32,
    /// 1: hidden
    flg: u32,
    str: f32,
    p: [10]f32,
    _pad: u32 = 0,
    /// its array's offset (0: none)
    data: u64,
};

/// A paint layer (LP_, 32 bytes): its material (ls_mats), colour 0xRRGGBB,
/// friction, bounce, and its rule: heights (0..1 of the range) and slopes
/// (degrees) it covers.
pub const Paint = extern struct {
    mat: u32,
    col: u32,
    fric: f32,
    bounce: f32,
    hlo: f32,
    hhi: f32,
    slo: f32,
    shi: f32,
};

/// The block's first page (LB_).
pub const Header = extern struct {
    refs: u32,
    n: u32,
    size: f32,
    nl: u32,
    ver: u32,
    disp: u32,
    bytes: u64,
    h: u64,
    c: u64,
    splat: u64,
    cl: i32,
    np: u32,
    hmin: f32,
    hmax: f32,
    ms: u32,
    _pad: [52]u8,
    lay: [LA_MAXL]Layer,
    paint: [LA_MAXP]Paint,
    _rest: [3200]u8,
};

comptime {
    std.debug.assert(@sizeOf(Layer) == 64);
    std.debug.assert(@sizeOf(Paint) == 32);
    std.debug.assert(@offsetOf(Header, "lay") == 128);
    std.debug.assert(@offsetOf(Header, "paint") == 640);
    std.debug.assert(@sizeOf(Header) == LB_DATA);
}

/// A block: the mapping (its header first).
pub const Block = Header;

const page = std.mem.Alignment.fromByteUnits(4096);

fn mapping(b: *Block) []align(4096) u8 {
    const p: [*]align(4096) u8 = @ptrCast(@alignCast(b));
    return p[0..@intCast(b.bytes)];
}

/// The block's f32 array at offset `off` (N x N).
pub fn arrF(b: *Block, off: u64) []f32 {
    const p: [*]u8 = @ptrCast(b);
    const f: [*]f32 = @ptrCast(@alignCast(p + @as(usize, @intCast(off))));
    return f[0 .. @as(usize, b.n) * b.n];
}
pub fn heights(b: *Block) []f32 {
    return arrF(b, b.h);
}
/// The splat map: 8 weights a sample (none: empty).
pub fn splat(b: *Block) [][8]u8 {
    if (b.splat == 0) return &.{};
    const p: [*]u8 = @ptrCast(b);
    const f: [*][8]u8 = @ptrCast(p + @as(usize, @intCast(b.splat)));
    return f[0 .. @as(usize, b.n) * b.n];
}
pub fn layerData(b: *Block, l: *const Layer) ?[]f32 {
    if (l.data == 0) return null;
    return arrF(b, l.data);
}

/// la_ref, la_unref.
pub fn ref(b: ?*Block) void {
    const x = b orelse return;
    _ = @atomicRmw(u32, &x.refs, .Add, 1, .monotonic);
}
pub fn unref(b: ?*Block) void {
    const x = b orelse return;
    if (@atomicRmw(u32, &x.refs, .Sub, 1, .acq_rel) == 1) std.heap.page_allocator.rawFree(mapping(x), page, @returnAddress());
}

/// la_of: an object's landscape block, or null.
pub fn of(o: *const scene.Object) ?*Block {
    if (o.kind != .mesh) return null;
    const mi = o.mesh orelse return null;
    const me = &(scene.meshes[mi] orelse return null);
    return me.land;
}
pub fn ofIndex(i: usize) ?*Block {
    if (i >= scene.count) return null;
    return of(&scene.objects[i]);
}

/// la_arr: bytes of an f32 N x N array (a page multiple).
pub fn arrBytes(n: u32) u64 {
    return (@as(u64, n) * n * 4 + 4095) & ~@as(u64, 4095);
}

fn alloc(bytes: u64) ?*Block {
    const mem = std.heap.page_allocator.rawAlloc(@intCast(bytes), page, @returnAddress()) orelse return null;
    @memset(mem[0..@intCast(bytes)], 0);
    return @ptrCast(@alignCast(mem));
}

/// la_make's "want": the splat map, one more f32 array (its offset in `extra`, zeroed).
pub const WANT_SPLAT: u32 = 1;
pub const WANT_EXTRA: u32 = 2;
/// la_make: the extra array's offset.
pub var extra: u64 = 0;

/// la_make: a new block (references 1) with the source's header, layers and
/// arrays (the same N), repacked; null when out of memory.
pub fn make(src: ?*Block, n: u32, want: u32) ?*Block {
    const arr = arrBytes(n);
    var bytes: u64 = arr * 2 + LB_DATA;
    if (src) |s| {
        for (s.lay[0..@min(s.nl, LA_MAXL)]) |*l| {
            if (l.data != 0) bytes += arr;
        }
    }
    if (want & WANT_SPLAT != 0 or (src != null and src.?.splat != 0)) bytes += arr * 2;
    if (want & WANT_EXTRA != 0) bytes += arr;
    const b = alloc(bytes) orelse return null;
    if (src) |s| @memcpy(std.mem.asBytes(b), std.mem.asBytes(s));
    b.refs = 1;
    b.n = n;
    b.bytes = bytes;
    b.splat = 0;
    var off: u64 = LB_DATA;
    b.h = off;
    off += arr;
    b.c = off;
    off += arr;
    if (src) |s| {
        const p: [*]u8 = @ptrCast(b);
        const q: [*]const u8 = @ptrCast(s);
        @memcpy(p[@intCast(b.h)..][0..@intCast(arr * 2)], q[@intCast(s.h)..][0..@intCast(arr * 2)]);
        for (0..@min(s.nl, LA_MAXL)) |i| {
            const so = s.lay[i].data;
            if (so == 0) continue;
            b.lay[i].data = off;
            @memcpy(p[@intCast(off)..][0..@intCast(arr)], q[@intCast(so)..][0..@intCast(arr)]);
            off += arr;
        }
        if (s.splat != 0) {
            b.splat = off;
            @memcpy(p[@intCast(off)..][0..@intCast(arr * 2)], q[@intCast(s.splat)..][0..@intCast(arr * 2)]);
            off += arr * 2;
        }
    } else b.cl = -1;
    if (want & WANT_SPLAT != 0 and b.splat == 0) {
        b.splat = off;
        off += arr * 2;
    }
    if (want & WANT_EXTRA != 0) {
        extra = off;
        off += arr;
    }
    return b;
}

// ---- evaluation -----------------------------------------------------------------------

fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1000000;
}

/// lv_range: the lowest and highest heights (minss / maxss, from the end).
fn range(h: []const f32) [2]f32 {
    var lo: f32 = 1.0e30;
    var hi: f32 = -1.0e30;
    var k = h.len;
    while (k > 0) {
        k -= 1;
        lo = minss(lo, h[k]);
        hi = maxss(hi, h[k]);
    }
    return .{ lo, hi };
}

/// la_eval: the heights again from layer `first` on (from the cache when it
/// holds a layer below that one).
pub fn eval(b: *Block, first: u32) void {
    const t0 = nowMs();
    const h = heights(b);
    const nl = @min(b.nl, LA_MAXL);
    var k: u32 = 0;
    if (b.cl >= 0 and b.cl < @as(i64, first) and b.cl < @as(i64, b.nl)) {
        @memcpy(h, arrF(b, b.c));
        k = @intCast(b.cl + 1);
    } else {
        @memset(h, 0);
        b.cl = -1;
    }
    while (k < nl) : (k += 1) {
        const l = &b.lay[k];
        if (l.flg & 1 != 0) continue;
        switch (l.typ) {
            1 => generate(b, l),
            2 => {
                erodeLayer(b, l);
                @memcpy(arrF(b, b.c), h);
                b.cl = @intCast(k);
            },
            3 => terrace(b, l),
            4, 6 => sculpted(b, l),
            5 => flatten(b, l),
            else => {},
        }
    }
    const r = range(h);
    b.hmin = r[0];
    b.hmax = r[1];
    b.ver +%= 1;
    b.ms = @truncate(nowMs() - t0);
}

const Gen = struct {
    h: []f32,
    n: u32,
    inv: f32,
    scale: f32,
    ox: f32,
    oz: f32,
    oy: f32,
    amp: f32,
    kind: u32,
    oct: u32,
    seed: i32,
    isl: bool,
    off: f32,
};

fn genRows(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const g: *const Gen = @ptrCast(@alignCast(ctx));
    for (lo..hi) |j| {
        for (0..g.n) |i| {
            const u = @as(f32, @floatFromInt(i)) * g.inv * g.scale + g.ox;
            const w = @as(f32, @floatFromInt(j)) * g.inv * g.scale + g.oz;
            var v: f32 = undefined;
            if (g.kind == 3) {
                // the distance to the nearest of one point in each cell (3 x 3)
                const fx = cvtt(@floor(u));
                const fz = cvtt(@floor(w));
                var best: f32 = 1.0e30;
                var dz: i32 = -1;
                while (dz <= 1) : (dz += 1) {
                    var dx: i32 = -1;
                    while (dx <= 1) : (dx += 1) {
                        const cx = fx +% dx;
                        const cz = fz +% dz;
                        var hh: u32 = @as(u32, @bitCast(cx)) *% 0x8da6b343;
                        hh ^= @as(u32, @bitCast(cz)) *% 0xd8163841;
                        hh ^= @as(u32, @bitCast(g.seed)) *% 0xcb1ab31f;
                        hh ^= hh >> 13;
                        hh *%= 0x5bd1e995;
                        hh ^= hh >> 15;
                        var px = @as(f32, @floatFromInt(hh & 0xffff)) * 1.52587890625e-5;
                        px = px + @as(f32, @floatFromInt(cx));
                        px = px - u;
                        var pz = @as(f32, @floatFromInt(hh >> 16)) * 1.52587890625e-5;
                        pz = pz + @as(f32, @floatFromInt(cz));
                        pz = pz - w;
                        best = minss(best, px * px + pz * pz);
                    }
                }
                v = minss(@sqrt(best), 1);
            } else {
                var amp: f32 = 1;
                var freq: f32 = 1;
                var sum: f32 = 0;
                var tot: f32 = 0;
                for (0..g.oct) |_| {
                    var nz = shgraph.perlin(.{ u * freq, g.oy * freq, w * freq });
                    if (g.kind != 0) {
                        nz = @abs(nz);
                        if (g.kind != 2) {
                            const q = 1.0 - nz;
                            nz = q * q;
                        }
                    }
                    sum = nz * amp + sum;
                    tot = amp + tot;
                    amp = amp * 0.5;
                    freq = freq + freq;
                }
                v = sum / tot;
                if (g.kind == 0) v = v * 0.5 + 0.5;
            }
            if (g.isl) {
                // an island: down towards the edges (1 - r^2, r from the middle)
                const x = @as(f32, @floatFromInt(i)) * g.inv - 0.5;
                const z = @as(f32, @floatFromInt(j)) * g.inv - 0.5;
                var r = x * x + z * z;
                r = r + r;
                r = r + r;
                v = v * maxss(1.0 - r, 0);
            }
            v = v * g.amp + g.off;
            const k = j * g.n + i;
            g.h[k] = v + g.h[k];
        }
    }
}

/// lg_generate: noise rows in parallel.
fn generate(b: *Block, l: *const Layer) void {
    const seed = cvtt(l.p[1]);
    const sf: f32 = @floatFromInt(seed);
    var g = Gen{
        .h = heights(b),
        .n = b.n,
        .inv = 1.0 / @as(f32, @floatFromInt(b.n - 1)),
        .amp = l.str * l.p[3],
        .kind = @as(u32, @bitCast(cvtt(l.p[0]))) & 3,
        .isl = l.p[5] > 0,
        .off = l.p[6] * l.str,
        .oct = @intCast(std.math.clamp(cvtt(l.p[4]), 1, 12)),
        .scale = maxss(l.p[2], TINY),
        .seed = seed,
        .ox = sf * 13.37,
        .oz = sf * 7.77,
        .oy = sf * 3.1 + 0.5,
    };
    jobs.parallelFor(b.n, 4, @ptrCast(&g), genRows);
}

/// tan as fptan of a single, rounded to single.
fn tanf(x: f32) f32 {
    return @floatCast(@tan(@as(f64, x)));
}

/// lg_erode: droplets (er_run) over the heights scaled to 0..1, then thermal
/// erosion; the result mixed in by the strength.
fn erodeLayer(b: *Block, l: *const Layer) void {
    const h = heights(b);
    const r = range(h);
    const lo = r[0];
    const rg = r[1] - lo;
    if (!(rg > TINY)) return;
    const t = std.heap.page_allocator.alloc(f32, h.len) catch return;
    defer std.heap.page_allocator.free(t);
    for (h, t) |x, *o| o.* = (x - lo) / rg;
    var e = procgen.Eroder{ .h = t, .n = b.n, .rng = procgen.Eroder.seedOf(l.p[2]) };
    var d = cvtt(l.p[0]);
    if (!(d > 0)) d = @intCast(@as(u32, @truncate(h.len >> 3)));
    if (d > 16000000) d = 16000000;
    e.run(minss(maxss(l.p[1], 0), 1), @bitCast(d));
    var it = cvtt(l.p[3]);
    if (it > 0) {
        if (it > 1000) it = 1000;
        const inv = 1.0 / @as(f32, @floatFromInt(b.n - 1));
        const talus = b.size * inv * tanf(l.p[4] * 0.017453292) / rg;
        while (it > 0) : (it -= 1) thermal(t, b.n, talus);
    }
    for (h, t) |*x, y| {
        const ev = y * rg + lo;
        x.* = (ev - x.*) * l.str + x.*;
    }
}

/// lg_thermal: one pass: each pair of neighbours (right, below) steeper than
/// the talus shares a quarter of the excess.
fn thermal(t: []f32, n: u32, talus: f32) void {
    for (0..n) |r| {
        for (0..n) |c| {
            const a = r * n + c;
            if (c < n - 1) pair(t, a, a + 1, talus);
            if (r < n - 1) pair(t, a, a + n, talus);
        }
    }
}
fn pair(t: []f32, a: usize, b: usize, talus: f32) void {
    const d = t[a] - t[b];
    var ex = @abs(d) - talus;
    if (!(ex > 0)) return;
    ex = ex * 0.25;
    if (!(d > 0)) ex = 0 - ex;
    t[a] = t[a] - ex;
    t[b] = t[b] + ex;
}

/// lg_terrace: steps over the range; a riser takes the last Smooth of a step.
fn terrace(b: *Block, l: *const Layer) void {
    const h = heights(b);
    const r = range(h);
    const lo = r[0];
    const rg = r[1] - lo;
    if (!(rg > TINY)) return;
    const steps = @floor(maxss(l.p[0], 1));
    const s = minss(maxss(l.p[1], 0), 1);
    for (h) |*x| {
        var t = (x.* - lo) / rg * steps;
        const k = @floor(t);
        t = t - k;
        t = t - (1.0 - s);
        t = maxss(t, 0);
        t = if (s > TINY) t / s else 0;
        const v = (t + k) / steps * rg + lo;
        x.* = (v - x.*) * l.str + x.*;
    }
}

/// lg_sculpted: the offsets added (a heightmap's too).
fn sculpted(b: *Block, l: *const Layer) void {
    const d = layerData(b, l) orelse return;
    for (heights(b), d) |*x, o| x.* = o * l.str + x.*;
}

/// lg_flatten: h + strength mask (level - h).
fn flatten(b: *Block, l: *const Layer) void {
    const d = layerData(b, l) orelse return;
    for (heights(b), d) |*x, w| x.* = (l.p[0] - x.*) * w * l.str + x.*;
}

// ---- the display ----------------------------------------------------------------------

/// The display's samples a side and step (la_display): every s-th sample,
/// s a power of two, at most the display's samples a side.
pub fn dispOf(b: *const Block) [2]u32 {
    var cap: i32 = @bitCast(if (b.disp == 0) LA_DISP else b.disp);
    if (cap < 2) cap = 2;
    var s: u32 = 1;
    while (true) {
        const d = (b.n - 1) / s + 1;
        if (@as(i64, d) <= cap) return .{ d, s };
        s <<= 1;
    }
}

/// la_display: a new mesh slot: a grid of every s-th sample, holding a
/// reference to the block (its colours from the paint). `old`: the mesh it
/// replaces (the same grid: copied, as the original's mesh_copy - its vertex
/// colours too). Null: no room.
pub fn display(b: *Block, old: ?u16) ?u16 {
    const ds = dispOf(b);
    const d = ds[0];
    const s = ds[1];
    var mi: u16 = undefined;
    if (old != null and scene.meshes[old.?] != null and scene.meshes[old.?].?.verts.len == @as(usize, d) * d) {
        mi = scene.cloneMesh(old.?) orelse return null;
    } else {
        var g = procgen.grid(std.heap.page_allocator, d - 1) catch return null;
        defer g.deinit(std.heap.page_allocator);
        mi = scene.addMesh(g.verts, g.poff, g.loops) orelse return null;
    }
    const me = &scene.meshes[mi].?;
    const half = b.size * 0.5;
    const cell = b.size / @as(f32, @floatFromInt(d - 1));
    const h = heights(b);
    var k: usize = 0;
    for (0..d) |r| {
        for (0..d) |c| {
            me.verts[k] = .{
                @as(f32, @floatFromInt(c)) * cell - half,
                h[r * s * b.n + c * s],
                @as(f32, @floatFromInt(r)) * cell - half,
            };
            k += 1;
        }
    }
    bounds(me);
    vcolOf(b, me);
    me.shape +%= 1;
    me.land = b;
    ref(b);
    return mi;
}

/// mesh_bbox on a scene mesh.
pub fn bounds(me: *scene.Mesh) void {
    var lo: m.V3 = .{ 1.0e30, 1.0e30, 1.0e30 };
    var hi: m.V3 = .{ -1.0e30, -1.0e30, -1.0e30 };
    for (me.verts) |p| {
        for (0..3) |c| {
            lo[c] = minss(lo[c], p[c]);
            hi[c] = maxss(hi[c], p[c]);
        }
    }
    me.lo = lo;
    me.hi = hi;
}

/// la_obj_set: object i shows the block (a new display mesh); the caller's
/// reference to the block stays its own.
pub fn objSet(i: usize, b: *Block) void {
    const o = &scene.objects[i];
    const mi = display(b, o.mesh) orelse return;
    o.mesh = mi;
    app.dirty = true;
}

/// ls_colour: 0xFFRRGGBB: the paint layers' colours by their weights, white
/// for the rest.
pub fn colour(b: *Block, sample: usize) u32 {
    const w = splat(b)[sample];
    var out: u32 = 0;
    var sh: i32 = 16;
    while (sh >= 0) : (sh -= 8) {
        var sum: u32 = 0;
        var tot: i32 = 0;
        for (0..@min(b.np, LA_MAXP)) |k| {
            const x: u32 = w[k];
            tot += @intCast(x);
            sum +%= x * ((b.paint[k].col >> @intCast(sh)) & 255);
        }
        var rest: i32 = 255 - tot;
        if (rest < 0) rest = 0;
        var v = (@as(u32, @intCast(rest)) * 255 +% sum) / 255;
        if (v > 255) v = 255;
        out |= v << @intCast(sh);
    }
    return out | 0xff000000;
}

/// mesh_vcol_alloc: the mesh's vertex colours (made white when none).
pub fn vcolAlloc(me: *scene.Mesh) ?[]u32 {
    if (me.vcol.len == me.verts.len and me.vcol.len > 0) return me.vcol;
    if (me.vcol.len > 0) @import("alloc.zig").A.free(me.vcol);
    me.vcol = @import("alloc.zig").A.alloc(u32, me.verts.len) catch {
        me.vcol = &.{};
        return null;
    };
    @memset(me.vcol, 0xffffffff);
    return me.vcol;
}

/// ls_vcol: the display mesh's vertex colours from the splat map (none: left
/// as they are).
pub fn vcolOf(b: *Block, me: *scene.Mesh) void {
    if (b.splat == 0 or b.np == 0) return;
    const vc = vcolAlloc(me) orelse return;
    const d: u32 = @intCast(cvt(@sqrt(@as(f32, @floatFromInt(me.verts.len)))));
    if (d < 2) return;
    const step = (b.n - 1) / (d - 1);
    for (0..d) |r| {
        for (0..d) |c| vc[r * d + c] = colour(b, r * step * b.n + c * step);
    }
    me.paints +%= 1;
}

// ---- heights at a place ---------------------------------------------------------------

/// la_height: the height at (x, z) in its space (bilinear), null outside.
pub fn height(b: *Block, x0: f32, z0: f32) ?f32 {
    const nm1: i32 = @intCast(b.n - 1);
    const per = @as(f32, @floatFromInt(nm1)) / b.size;
    const half = b.size * 0.5;
    const x = (x0 + half) * per;
    const z = (z0 + half) * per;
    if (!(x >= 0) or !(z >= 0)) return null;
    const far: f32 = @floatFromInt(nm1);
    if (x > far or z > far) return null;
    const ix = @min(cvtt(x), nm1 - 1);
    const iz = @min(cvtt(z), nm1 - 1);
    const u = x - @as(f32, @floatFromInt(ix));
    const v = z - @as(f32, @floatFromInt(iz));
    const h = heights(b);
    const k: usize = @intCast(iz * @as(i32, @intCast(b.n)) + ix);
    var h0 = h[k];
    const h1 = h[k + 1];
    var h2 = h[k + b.n];
    const h3 = h[k + b.n + 1];
    h0 = (h1 - h0) * u + h0;
    h2 = (h3 - h2) * u + h2;
    return (h2 - h0) * v + h0;
}

/// la_wheight: the landscape's height at world (x, z), null when not over it
/// (its location and scale; landscapes are not turned).
pub fn wheight(i: usize, x: f32, z: f32) ?f32 {
    const o = &scene.objects[i];
    const b = of(o) orelse return null;
    const h = height(b, (x - o.loc[0]) / o.scl[0], (z - o.loc[2]) / o.scl[2]) orelse return null;
    return h * o.scl[1] + o.loc[1];
}

/// la_info: 0 samples a side, 1 size, 2 layers, 3 lowest, 4 highest, 5
/// display samples a side, 6 the last evaluation (ms), 7 paint layers, 8
/// version; null: not a landscape.
pub fn info(i: usize, k: i32) ?f32 {
    const o = &scene.objects[i];
    const b = of(o) orelse return null;
    return switch (k) {
        0 => @floatFromInt(b.n),
        1 => b.size,
        2 => @floatFromInt(@as(i32, @bitCast(b.nl))),
        3 => b.hmin,
        4 => b.hmax,
        5 => @sqrt(@as(f32, @floatFromInt(scene.meshes[o.mesh.?].?.verts.len))),
        6 => @floatFromInt(@as(i32, @bitCast(b.ms))),
        7 => @floatFromInt(@as(i32, @bitCast(b.np))),
        8 => @floatFromInt(@as(i32, @bitCast(b.ver))),
        else => 0,
    };
}

// ---- the file -------------------------------------------------------------------------

/// la_load: a block made from a saved one (its header checked), or null.
pub fn load(d: []const u8) ?*Block {
    if (d.len < LB_DATA) return null;
    const rd = struct {
        fn u32_(x: []const u8, o: usize) u32 {
            return std.mem.readInt(u32, x[o..][0..4], .little);
        }
        fn u64_(x: []const u8, o: usize) u64 {
            return std.mem.readInt(u64, x[o..][0..8], .little);
        }
    };
    const n = rd.u32_(d, 4);
    if (n < 2 or n > 4097) return null;
    const nl = rd.u32_(d, 12);
    if (nl > LA_MAXL) return null;
    // (the paint layers too: the original reads past its header with more than 8)
    if (rd.u32_(d, 60) > LA_MAXP) return null;
    const bytes = rd.u64_(d, 24);
    if (bytes != d.len) return null;
    const arr = arrBytes(n);
    const ok = struct {
        fn f(off: u64, a: u64, total: u64) bool {
            return off >= LB_DATA and off +% a <= total and off +% a >= off;
        }
    }.f;
    if (!ok(rd.u64_(d, 32), arr, bytes) or !ok(rd.u64_(d, 40), arr, bytes)) return null;
    for (0..nl) |i| {
        const o = rd.u64_(d, 128 + i * 64 + 56);
        if (o != 0 and !ok(o, arr, bytes)) return null;
    }
    const so = rd.u64_(d, 48);
    if (so != 0 and !ok(so +% arr, arr, bytes)) return null;
    const b = alloc(d.len) orelse return null;
    const p: [*]u8 = @ptrCast(b);
    @memcpy(p[0..d.len], d);
    b.refs = 1;
    return b;
}

/// land_write: per mesh (in the MESH chunks' order) showing a landscape: its
/// index, bytes, the block as it is.
pub fn writeChunk(buf: anytype, mesh_ix: []const u32) void {
    var by_ix: [scene.max_meshes]?u16 = @splat(null);
    for (mesh_ix, 0..) |ix, mi| {
        if (ix != 0xffffffff and ix < by_ix.len) by_ix[ix] = @intCast(mi);
    }
    for (by_ix) |x| {
        const mi = x orelse continue;
        const me = &(scene.meshes[mi] orelse continue);
        const b = me.land orelse continue;
        buf.u32_(mesh_ix[mi]);
        buf.u32_(@truncate(b.bytes));
        buf.bytes(mapping(b));
    }
}

/// land_read: landscapes back on the loaded meshes.
pub fn readChunk(c0: []const u8, mesh_map: []const ?u16) void {
    var c = c0;
    while (c.len >= 8) {
        const ix = std.mem.readInt(u32, c[0..4], .little);
        const nb = std.mem.readInt(u32, c[4..8], .little);
        if (nb > c.len - 8) return;
        if (ix < mesh_map.len) {
            if (mesh_map[ix]) |mi| {
                if (load(c[8 .. 8 + nb])) |b| {
                    const me = &scene.meshes[mi].?;
                    unref(me.land);
                    me.land = b;
                }
            }
        }
        c = c[8 + nb ..];
    }
}

// ---- operators ------------------------------------------------------------------------

/// im_next_word: words split at spaces only, each at most 255 bytes.
pub const Words = struct {
    s: []const u8,
    i: usize = 0,
    pub fn next(w: *Words) ?[]const u8 {
        while (w.i < w.s.len and w.s[w.i] == ' ') w.i += 1;
        const st = w.i;
        while (w.i < w.s.len and w.s[w.i] != ' ' and w.s[w.i] != 0) w.i += 1;
        if (w.i == st) {
            w.i = w.s.len;
            return null;
        }
        return w.s[st..@min(w.i, st + 255)];
    }
    /// la_num: the next word as a number (the word is used up either way).
    pub fn num(w: *Words) ?f32 {
        const s = w.next() orelse return null;
        return ntree.parseFloat(s, null);
    }
};

/// la_word: the index of w in the list, or null.
pub fn wordIn(names: []const []const u8, w: []const u8) ?u32 {
    for (names, 0..) |x, i| {
        if (std.mem.eql(u8, x, w)) return @intCast(i);
    }
    return null;
}

const s_nosel = "  landscape: the active object is not a landscape";
const s_bad = "  landscape: not understood: ";
const s_full = "  landscape: 8 layers at most";
const s_mem = "  landscape: out of memory";

pub fn bad() void {
    app.log("{s}{s}", .{ s_bad, ops.arg });
}
pub fn outOfMemory() void {
    app.log("{s}", .{s_mem});
}

/// la_active: the active object if a landscape (and its block); else says so.
pub fn active() ?struct { i: usize, b: *Block } {
    if (scene.active) |i| {
        if (ofIndex(i)) |b| return .{ .i = i, .b = b };
    }
    app.log("{s}", .{s_nosel});
    return null;
}

/// la_res: 2^k + 1 nearest, 65..4097.
pub fn res(x: f32) u32 {
    const a = cvtt(x);
    var c: i32 = 65;
    while (c < 4097) {
        const nx = c * 2 - 1;
        if (a < @divTrunc(c + nx, 2)) break;
        c = nx;
    }
    return @intCast(c);
}

/// A new layer's parameters, by type (strength, then 10).
const defs = [6][11]f32{
    .{ 1.0, 0, 1, 3, 30, 6, 0, 0, 0, 0, 0 },
    .{ 1.0, 0, 0.3, 1, 0, 35, 0, 0, 0, 0, 0 },
    .{ 1.0, 8, 0.2, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

/// la_layer_init: its defaults (type 1..6).
pub fn layerInit(l: *Layer, typ: u32) void {
    l.typ = typ;
    l.flg = 0;
    l.data = 0;
    const d = &defs[typ - 1];
    l.str = d[0];
    @memcpy(&l.p, d[1..11]);
}

/// The presets' layers (la_pdata): type, strength, 10 parameters.
const PL = struct { typ: u32, v: [11]f32 };
pub const preset_layers = [6][]const PL{
    &.{},
    &.{ .{ .typ = 1, .v = .{ 1.0, 0, 1, 3, 30, 6, 0, 0, 0, 0, 0 } }, .{ .typ = 2, .v = .{ 1.0, 0, 0.3, 1, 0, 35, 0, 0, 0, 0, 0 } } },
    &.{ .{ .typ = 1, .v = .{ 1.0, 1, 2, 2.5, 140, 8, 0, 0, 0, 0, 0 } }, .{ .typ = 2, .v = .{ 1.0, 0, 0.45, 2, 6, 40, 0, 0, 0, 0, 0 } } },
    &.{ .{ .typ = 1, .v = .{ 1.0, 0, 4, 2, 60, 5, 0, 0, 0, 0, 0 } }, .{ .typ = 3, .v = .{ 1.0, 6, 0.12, 0, 0, 0, 0, 0, 0, 0, 0 } }, .{ .typ = 2, .v = .{ 1.0, 0, 0.35, 5, 0, 35, 0, 0, 0, 0, 0 } } },
    &.{ .{ .typ = 1, .v = .{ 1.0, 2, 6, 7, 7, 3, 0, 0, 0, 0, 0 } }, .{ .typ = 2, .v = .{ 1.0, 1, 0.1, 7, 25, 30, 0, 0, 0, 0, 0 } } },
    &.{ .{ .typ = 1, .v = .{ 1.0, 0, 9, 2.5, 50, 7, 1, -14, 0, 0, 0 } }, .{ .typ = 2, .v = .{ 1.0, 0, 0.3, 9, 0, 35, 0, 0, 0, 0, 0 } } },
};
pub const preset_names = [_][]const u8{ "flat", "hills", "mountains", "canyon", "dunes", "island" };
pub const type_names = [_][]const u8{ "generate", "erode", "terrace", "sculpted", "flatten", "heightmap" };
pub const noise_names = [_][]const u8{ "fbm", "ridged", "billow", "cells" };
/// Each type's parameter names (by slot).
pub const param_names = [6][]const []const u8{
    &.{ "noise", "seed", "scale", "height", "octaves", "island", "offset" },
    &.{ "droplets", "rate", "seed", "thermal", "talus" },
    &.{ "steps", "smooth" },
    &.{},
    &.{"height"},
    &.{},
};

/// la_preset: its layers.
pub fn preset(b: *Block, k: u32) void {
    const ls = preset_layers[k];
    b.nl = @intCast(ls.len);
    for (ls, 0..) |pl, i| {
        const l = &b.lay[i];
        l.typ = pl.typ;
        l.flg = 0;
        l.data = 0;
        l.str = pl.v[0];
        @memcpy(&l.p, pl.v[1..11]);
    }
}

/// la_disc: a round area added to a flatten layer's mask (1 inside the inner
/// half, smooth to 0 at the edge).
pub fn disc(b: *Block, l: *const Layer, x: f32, z: f32, r0: f32) void {
    const mask = layerData(b, l) orelse return;
    const r = maxss(r0, TINY);
    const n = b.n;
    const cell = b.size / @as(f32, @floatFromInt(n - 1));
    for (0..n) |j| {
        for (0..n) |i| {
            const half = b.size * 0.5;
            const px = @as(f32, @floatFromInt(i)) * cell - half - x;
            const pz = @as(f32, @floatFromInt(j)) * cell - half - z;
            var d = @sqrt(px * px + pz * pz) / r;
            d = d - 0.5;
            d = d + d;
            const w = minss(maxss(1.0 - d, 0), 1);
            const k = j * n + i;
            mask[k] = maxss(w, mask[k]);
        }
    }
}

/// la_params: the layer's keys and values; false at a word it does not take.
pub fn params(b: *Block, l: *Layer, it: *Words) bool {
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "strength")) {
            l.str = it.num() orelse return false;
            continue;
        }
        if (l.typ == 1 and std.mem.eql(u8, w, "noise")) {
            const v = it.next() orelse return false;
            const k = wordIn(&noise_names, v) orelse return false;
            l.p[0] = @floatFromInt(k);
            continue;
        }
        if (l.typ == 5 and std.mem.eql(u8, w, "at")) {
            const x = it.num() orelse return false;
            const z = it.num() orelse return false;
            const r = it.num() orelse return false;
            disc(b, l, x, z, r);
            continue;
        }
        if (l.typ < 1 or l.typ > 6) return false;
        const k = wordIn(param_names[l.typ - 1], w) orelse return false;
        l.p[k] = it.num() orelse return false;
    }
    return true;
}

/// unique_name: the base, then base.001 ...
fn uniqueName(base: []const u8, buf: *[32]u8) []const u8 {
    var k: u32 = 0;
    while (k < 1000) : (k += 1) {
        const nm = if (k == 0) base else std.fmt.bufPrint(buf, "{s}.{d:0>3}", .{ base, k }) catch base;
        if (scene.find(nm) == null) return nm;
    }
    return base;
}

/// obj_new(OT_MESH, name, mesh): a mesh object at the end (at the origin).
pub fn newObject(mi: u16, name: []const u8) ?usize {
    if (scene.count >= scene.max_objects) {
        scene.freeMeshSlot(mi);
        return null;
    }
    var buf: [32]u8 = undefined;
    var ob = scene.Object{ .kind = .mesh, .mesh = mi, .color = 0xb4b8c0 };
    ob.setName(uniqueName(name, &buf));
    const k = scene.count;
    scene.objects[k] = ob;
    scene.stamp(k);
    scene.count += 1;
    return k;
}

/// la_log_ms: "landscape evaluated in N ms" (the active object's).
pub fn logMs() void {
    const i = scene.active orelse return;
    const b = ofIndex(i) orelse return;
    app.log("  landscape evaluated in {d} ms", .{@as(i32, @bitCast(b.ms))});
}


/// la_water_body: a Water plane (half its size `half`) in ripples (a grid of
/// 192 x 192, waves 3 cm high), flagged OBF_WATER; where the landscape `of_`
/// is (else at the origin), the water material, active.
fn waterBody(of_: ?usize, half: f32) void {
    var g = procgen.grid(std.heap.page_allocator, 192) catch return;
    defer g.deinit(std.heap.page_allocator);
    for (g.verts) |*v| {
        const x = v[0];
        const z = v[2];
        const a = x * 101.0 + z * 37.0;
        const c = z * 67.0 - x * 23.0;
        const r: f32 = @floatCast(@sin(@as(f64, a)) * @sin(@as(f64, c)));
        v[1] = r * 0.03;
        v[0] = x * half;
        v[2] = z * half;
    }
    const mi = scene.addMesh(g.verts, g.poff, g.loops) orelse return;
    const k = newObject(mi, "Water") orelse return;
    const o = &scene.objects[k];
    o.gflags |= OBF_WATER;
    if (of_) |l| o.loc = scene.objects[l].loc;
    scene.selectOnly(k);
    // do_preset "water": the active mesh (the plane) a new material of the preset
    if (@import("material.zig").presetIndex("water")) |w| @import("matops.zig").presetActive(w);
}

/// la_water: the landscape's sea: 1.5 times it, at its height.
pub fn water(i: usize) void {
    const b = ofIndex(i) orelse return;
    waterBody(i, b.size * 0.75);
}

/// do_la_add / do_la_addp: landscape.add [preset] [size s] [res n] [seed k].
fn addWith(pre0: u32) void {
    var pre = pre0;
    var size: f32 = 200;
    var n: u32 = 513;
    var seed: i32 = -1;
    var it = Words{ .s = ops.arg };
    while (it.next()) |w| {
        if (wordIn(&preset_names, w)) |k| {
            pre = k;
            continue;
        }
        const key: u8 = if (std.mem.eql(u8, w, "size")) 's' else if (std.mem.eql(u8, w, "res")) 'r' else if (std.mem.eql(u8, w, "seed")) 'k' else return bad();
        const v = it.num() orelse return bad();
        switch (key) {
            's' => size = maxss(v, 1),
            'r' => n = res(v),
            else => seed = cvtt(v),
        }
    }
    const b = make(null, n, 0) orelse return outOfMemory();
    b.size = size;
    preset(b, pre);
    if (seed >= 0) {
        const sf: f32 = @floatFromInt(seed);
        for (b.lay[0..b.nl]) |*l| {
            if (l.typ == 1) l.p[1] = sf;
            if (l.typ == 2) l.p[2] = sf;
        }
    }
    eval(b, 0);
    const mi = display(b, null);
    unref(b); // (the mesh holds it)
    const m_ = mi orelse return outOfMemory();
    const k = newObject(m_, "Landscape") orelse return;
    scene.selectOnly(k);
    scene.objects[k].loc = scene.cursor;
    if (pre == 5) {
        water(k);
        scene.selectOnly(k);
    }
    if (!ops.quiet) {
        app.log("  added {s}", .{scene.objects[k].name()});
        logMs();
    }
    app.dirty = true;
}

fn opAdd() void {
    addWith(1);
}
fn addPreset(comptime k: u32) *const fn () void {
    return &struct {
        fn f() void {
            addWith(k);
        }
    }.f;
}

/// do_la_layer: add <type> [..] | set i [..] | remove i | hide i | show i |
/// up i | down i.
fn opLayer() void {
    const a = active() orelse return;
    const src = a.b;
    var it = Words{ .s = ops.arg };
    const w = it.next() orelse return bad();
    var b: *Block = undefined;
    var first: u32 = 0;
    if (std.mem.eql(u8, w, "add")) {
        const tw = it.next() orelse return bad();
        const typ = (wordIn(&type_names, tw) orelse return bad()) + 1;
        if (src.nl >= LA_MAXL) return app.log("{s}", .{s_full});
        b = make(src, src.n, if (typ >= 4) WANT_EXTRA else 0) orelse return outOfMemory();
        first = b.nl;
        const l = &b.lay[b.nl];
        layerInit(l, typ);
        if (typ >= 4) l.data = extra;
        b.nl += 1;
        if (!params(b, l, &it)) {
            unref(b);
            return bad();
        }
    } else {
        const verbs = [_][]const u8{ "set", "remove", "hide", "show", "up", "down" };
        const verb = wordIn(&verbs, w) orelse return bad();
        const x = it.num() orelse return bad();
        const ix = cvtt(x);
        if (ix < 0 or ix >= @as(i64, src.nl)) return bad();
        first = @intCast(ix);
        b = make(src, src.n, 0) orelse return outOfMemory();
        const l = &b.lay[first];
        switch (verb) {
            1 => {
                // the ones above move down
                var k = first;
                while (k + 1 < b.nl) : (k += 1) b.lay[k] = b.lay[k + 1];
                b.nl -= 1;
            },
            2 => l.flg |= 1,
            3 => l.flg &= ~@as(u32, 1),
            4 => {
                if (first + 1 < b.nl) std.mem.swap(Layer, l, &b.lay[first + 1]);
            },
            5 => {
                if (first > 0) {
                    std.mem.swap(Layer, l, &b.lay[first - 1]);
                    first -= 1; // (evaluated from the lower one)
                }
            },
            else => {
                if (!params(b, l, &it)) {
                    unref(b);
                    return bad();
                }
            },
        }
    }
    eval(b, first);
    objSet(a.i, b);
    unref(b);
    if (!ops.quiet) logMs();
}

/// do_la_set: landscape.set [size s] [res n] [detail d].
fn opSet() void {
    const a = active() orelse return;
    const src = a.b;
    var n = src.n;
    var size = src.size;
    var disp = src.disp;
    var it = Words{ .s = ops.arg };
    while (it.next()) |w| {
        const key: u8 = if (std.mem.eql(u8, w, "size")) 's' else if (std.mem.eql(u8, w, "res")) 'r' else if (std.mem.eql(u8, w, "detail")) 'd' else return bad();
        const v = it.num() orelse return bad();
        switch (key) {
            's' => size = maxss(v, 1),
            'r' => n = res(v),
            else => disp = res(v),
        }
    }
    const b = (if (n != src.n) resize(src, n) else make(src, src.n, 0)) orelse return outOfMemory();
    b.size = size;
    b.disp = disp;
    eval(b, 0);
    objSet(a.i, b);
    unref(b);
}

/// la_resample: bilinear, n x n into m x m.
pub fn resample(src: []const f32, n: u32, dst: []f32, mm: u32) void {
    const per = @as(f32, @floatFromInt(n - 1)) / @as(f32, @floatFromInt(mm - 1));
    const lim: i32 = @as(i32, @intCast(n)) - 2;
    for (0..mm) |j| {
        for (0..mm) |i| {
            var x = @as(f32, @floatFromInt(i)) * per;
            var z = @as(f32, @floatFromInt(j)) * per;
            const ix = @min(cvtt(x), lim);
            const iz = @min(cvtt(z), lim);
            x = x - @as(f32, @floatFromInt(ix));
            z = z - @as(f32, @floatFromInt(iz));
            const k: usize = @intCast(iz * @as(i32, @intCast(n)) + ix);
            var h0 = src[k];
            const h1 = src[k + 1];
            var h2 = src[k + n];
            const h3 = src[k + n + 1];
            h0 = (h1 - h0) * x + h0;
            h2 = (h3 - h2) * x + h2;
            dst[j * mm + i] = (h2 - h0) * z + h0;
        }
    }
}

/// la_resample8: nearest, 8 bytes a sample.
fn resample8(src: []const [8]u8, n: u32, dst: [][8]u8, mm: u32) void {
    const per = @as(f32, @floatFromInt(n - 1)) / @as(f32, @floatFromInt(mm - 1));
    for (0..mm) |j| {
        for (0..mm) |i| {
            const x = cvt(@as(f32, @floatFromInt(i)) * per);
            const z = cvt(@as(f32, @floatFromInt(j)) * per);
            dst[j * mm + i] = src[@intCast(z * @as(i32, @intCast(n)) + x)];
        }
    }
}

/// la_resize: a new block of n samples: the header and layers, each layer's
/// array and the splat map resampled, the heights left to evaluate.
pub fn resize(src: *Block, n: u32) ?*Block {
    const arr = arrBytes(n);
    var bytes: u64 = arr * 2 + LB_DATA;
    for (src.lay[0..@min(src.nl, LA_MAXL)]) |*l| {
        if (l.data != 0) bytes += arr;
    }
    if (src.splat != 0) bytes += arr * 2;
    const b = alloc(bytes) orelse return null;
    @memcpy(std.mem.asBytes(b), std.mem.asBytes(src));
    b.refs = 1;
    b.n = n;
    b.bytes = bytes;
    b.cl = -1;
    b.splat = 0;
    var off: u64 = LB_DATA;
    b.h = off;
    off += arr;
    b.c = off;
    off += arr;
    for (0..@min(src.nl, LA_MAXL)) |i| {
        if (src.lay[i].data == 0) continue;
        b.lay[i].data = off;
        resample(arrF(src, src.lay[i].data), src.n, arrF(b, off), n);
        off += arr;
    }
    if (src.splat != 0) {
        b.splat = off;
        resample8(splat(src), src.n, splat(b), n);
    }
    return b;
}

/// do_la_water: landscape.add_water [size].
fn opWater() void {
    var size: f32 = 200;
    var it = Words{ .s = ops.arg };
    if (it.num()) |v| size = v;
    waterBody(null, size * 0.5);
    app.dirty = true;
}

/// do_la_sea: the active landscape's sea.
fn opSea() void {
    const a = active() orelse return;
    water(a.i);
    app.dirty = true;
}

pub const list = .{
    .{ "landscape.add", Impl{ .run = opAdd } },
    .{ "landscape.add_flat", Impl{ .run = addPreset(0) } },
    .{ "landscape.add_hills", Impl{ .run = addPreset(1) } },
    .{ "landscape.add_mountains", Impl{ .run = addPreset(2) } },
    .{ "landscape.add_canyon", Impl{ .run = addPreset(3) } },
    .{ "landscape.add_dunes", Impl{ .run = addPreset(4) } },
    .{ "landscape.add_island", Impl{ .run = addPreset(5) } },
    .{ "landscape.layer", Impl{ .run = opLayer } },
    .{ "landscape.set", Impl{ .run = opSet } },
    .{ "landscape.add_water", Impl{ .run = opWater } },
    .{ "landscape.sea", Impl{ .run = opSea } },
};

// ---- tests ----------------------------------------------------------------------------

test "header layout as landscape.inc" {
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Header, "cl"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(Header, "ms"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Layer, "data"));
}

test "la_res: 2^k + 1 nearest" {
    try std.testing.expectEqual(@as(u32, 65), res(10));
    try std.testing.expectEqual(@as(u32, 513), res(513));
    try std.testing.expectEqual(@as(u32, 513), res(700));
    try std.testing.expectEqual(@as(u32, 1025), res(800));
    try std.testing.expectEqual(@as(u32, 4097), res(1e9));
}

test "make, eval, load round trip" {
    const b = make(null, 65, 0).?;
    defer unref(b);
    b.size = 100;
    preset(b, 2);
    eval(b, 0);
    try std.testing.expect(b.hmax > b.hmin);
    try std.testing.expectEqual(@as(i32, 1), b.cl);
    const p: [*]u8 = @ptrCast(b);
    const c = load(p[0..@intCast(b.bytes)]).?;
    defer unref(c);
    try std.testing.expectEqualSlices(f32, heights(b), heights(c));
    // from the cache: the same heights
    const h0 = try std.testing.allocator.dupe(f32, heights(b));
    defer std.testing.allocator.free(h0);
    eval(b, 2);
    try std.testing.expectEqualSlices(f32, h0, heights(b));
    // damaged: a short block, offsets outside
    try std.testing.expect(load(p[0..4000]) == null);
    var bad_hdr: [LB_DATA + 16]u8 = undefined;
    @memcpy(bad_hdr[0..LB_DATA], p[0..LB_DATA]);
    std.mem.writeInt(u64, bad_hdr[24..32], bad_hdr.len, .little);
    try std.testing.expect(load(&bad_hdr) == null);
}

test "height: bilinear, outside is null" {
    const b = make(null, 65, 0).?;
    defer unref(b);
    b.size = 64;
    for (heights(b), 0..) |*h, k| h.* = @floatFromInt(k % 65);
    try std.testing.expectEqual(@as(?f32, 32.5), height(b, 0.5, 3));
    try std.testing.expect(height(b, 40, 0) == null);
    try std.testing.expectEqual(@as(?f32, 64), height(b, 32, 32));
}
