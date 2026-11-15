//! Exact mesh booleans: a port of the original's bool.s, stage for stage.
//!
//!  1. Both meshes are snapped to a dyadic integer grid (2^18 cells over the
//!     size: noise such as cos 90deg != 0 or angles typed to six decimals goes
//!     away, coincidences become exact). orient3d is exact in 128-bit
//!     integers. B is perturbed symbolically along its vertex normals (out for
//!     union and difference, in for intersection) plus a pseudo-random
//!     per-vertex part: every decision is generic and made the same way
//!     everywhere, so a flush cut goes through, touching solids fuse and
//!     A - A is empty.
//!  2. Candidate triangle pairs come from a uniform grid. Each crossing pair
//!     gives a segment between two points; a point is (edge of one mesh, face
//!     of the other), so neighbouring triangles share it. Points at the same
//!     place are welded to one id, mesh vertices included.
//!  3. Every cut triangle is re-triangulated in 2D: the points of its edges in
//!     order, the others inserted, the segments recovered by edge flips. A
//!     point inside symbolically but on the boundary in fact makes a flat
//!     triangle, so no neighbour sees a T-junction.
//!  4. Regions bounded by the cuts are classified by exact ray parity from a
//!     point exactly on the region. The operation picks them. Untouched
//!     polygons keep their shape; coincident opposite faces cancel. A result
//!     that is not closed is retried with B turned a hair.
//!
//! Deviations from bool.s, all where it fails or is wrong by its own comments:
//! the hash that finds opposite polygons covers the whole cycle (see cycHash);
//! a triangle whose first triangulation fails gets a second order (see
//! cdtTriangle); non-finite or out-of-range input is refused up front; the
//! tables grow instead of failing at a capacity (one triangle's 4096 points
//! stay the limit: that part is quadratic). B has no matrix: the inputs share
//! one space already.
//!
//! The grid is 2^18 cells over the size of both meshes together, so what is
//! smaller than that disappears: a unit cube next to one 1e30 away is gone
//! (the original's answer too), and every vertex moves up to half a cell.
//!
//! Pure: the inputs are read only, the result comes from `a`, scratch memory
//! lives in arenas over `a` and nothing is global, so calls may run side by
//! side (given an `a` that allows it). No threads: the original has none here.
const std = @import("std");
const m = @import("math.zig");
const pmesh = @import("pmesh.zig");

pub const PMesh = pmesh.PMesh;
const Allocator = std.mem.Allocator;

pub const Op = enum(u32) { union_ = 0, difference = 1, intersect = 2 };

/// BooleanFailed: an empty or malformed input, or nothing usable after the
/// retries (the original's "the meshes must be closed and not
/// self-intersecting"). The caller keeps its meshes.
pub const Error = error{BooleanFailed} || Allocator.Error;

const V3i = [3]i64;
const V3d = [3]f64;

const CDT_MAXP = 4096;
const CDT_MAXT = CDT_MAXP * 2 + 8;

/// Internal: a degenerate configuration, try again with B turned a hair.
const Degenerate = error{Degenerate};
const StageError = Degenerate || Allocator.Error;

// ---- float -> integer as the hardware does it ------------------------------
// bool.s uses cvtsd2si / cvttsd2si: NaN and anything outside i64 become the
// "integer indefinite" -2^63 and the integer code wraps from there. @intFromFloat
// would be undefined, so these keep the hardware's answer.

const indefinite: i64 = std.math.minInt(i64);

/// cvtsd2si: round to nearest, ties to even.
fn cvt(x: f64) i64 {
    if (!(x > -0x1p63 and x < 0x1p63)) return indefinite;
    var r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5 and @rem(r, 2.0) != 0.0) r -= std.math.sign(x);
    return @intFromFloat(r);
}

/// cvttsd2si: truncate.
fn cvtt(x: f64) i64 {
    if (!(x > -0x1p63 and x < 0x1p63)) return indefinite;
    return @intFromFloat(@trunc(x));
}

fn min2(a: f64, b: f64) f64 { // minsd a, b
    return if (a < b) a else b;
}
fn max2(a: f64, b: f64) f64 { // maxsd a, b
    return if (a > b) a else b;
}

fn subD(a: V3d, b: V3d) V3d {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn dotD(a: V3d, b: V3d) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn crossD(a: V3d, b: V3d) V3d {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn ukey(a: u32, b: u32) u64 {
    return if (a <= b) dkey(a, b) else dkey(b, a);
}
fn dkey(a: u32, b: u32) u64 {
    return @as(u64, a) << 32 | b;
}

/// u64 -> u32 hash table with linear probing; grows, unlike the original's
/// tables, whose capacities are fixed in advance.
const Eh = struct {
    a: Allocator,
    keys: []u64, // key + 1, 0 = empty
    vals: []u32,
    used: usize = 0,

    fn init(a: Allocator, n: usize) Allocator.Error!Eh {
        var size: usize = 16;
        while (size < n * 2) size *= 2;
        const keys = try a.alloc(u64, size);
        @memset(keys, 0);
        return .{ .a = a, .keys = keys, .vals = try a.alloc(u32, size) };
    }
    fn home(key1: u64, mask: usize) usize {
        return @intCast(((key1 *% 0x9E3779B97F4A7C15) >> 32) & mask);
    }
    fn grow(e: *Eh) Allocator.Error!void {
        const ok = e.keys;
        const ov = e.vals;
        const keys = try e.a.alloc(u64, ok.len * 2);
        @memset(keys, 0);
        const vals = try e.a.alloc(u32, ok.len * 2);
        const mask = keys.len - 1;
        for (ok, ov) |k, v| {
            if (k == 0) continue;
            var i = home(k, mask);
            while (keys[i] != 0) i = (i + 1) & mask;
            keys[i] = k;
            vals[i] = v;
        }
        e.a.free(ok);
        e.a.free(ov);
        e.keys = keys;
        e.vals = vals;
    }
    const Slot = struct { val: *u32, found: bool };
    /// The value's slot; a new key gets 0xffffffff.
    fn slot(e: *Eh, key: u64) Allocator.Error!Slot {
        if (e.used * 2 >= e.keys.len) try e.grow();
        const k = key + 1;
        const mask = e.keys.len - 1;
        var i = home(k, mask);
        while (e.keys[i] != 0) : (i = (i + 1) & mask) {
            if (e.keys[i] == k) return .{ .val = &e.vals[i], .found = true };
        }
        e.keys[i] = k;
        e.vals[i] = 0xffffffff;
        e.used += 1;
        return .{ .val = &e.vals[i], .found = false };
    }
    fn get(e: *const Eh, key: u64) ?u32 {
        const k = key + 1;
        const mask = e.keys.len - 1;
        var i = home(k, mask);
        while (e.keys[i] != 0) : (i = (i + 1) & mask) {
            if (e.keys[i] == k) return e.vals[i];
        }
        return null;
    }
};

/// Every edge used once in each direction: closed, consistently oriented.
fn manifold(a: Allocator, poff: []const u32, loops: []const u32) Allocator.Error!bool {
    var e = try Eh.init(a, loops.len);
    defer {
        a.free(e.keys);
        a.free(e.vals);
    }
    const np = if (poff.len == 0) 0 else poff.len - 1;
    for (0..2) |pass| {
        for (0..np) |p| {
            const l = loops[poff[p]..poff[p + 1]];
            for (l, 0..) |u, i| {
                const v = l[if (i + 1 < l.len) i + 1 else 0];
                if (pass == 0) {
                    const s = try e.slot(dkey(u, v));
                    s.val.* = 0;
                    if (s.found) return false;
                } else if (e.get(dkey(v, u)) == null) return false;
            }
        }
    }
    return true;
}

// ---- input triangles (mesh_finish, ear_tris) --------------------------------

/// The triangles of a mesh, as the original's mesh_finish makes them: fans,
/// where a flat ear (three corners in a line) waits until it is not flat.
const Tris = struct {
    tri: [][3]u32,
    tpoly: []u32,
    first: []u32, // polygon -> its first triangle (npolys + 1 entries)
    bmin: [3]f32,
    bmax: [3]f32,
};

fn flat3(pos: []const m.V3, ia: u32, ib: u32, ic: u32) bool {
    const a = pos[ia];
    const b = pos[ib];
    const c = pos[ic];
    const u = m.sub(b, a);
    const w = m.sub(c, a);
    const x = u[1] * w[2] - u[2] * w[1];
    const y = u[2] * w[0] - u[0] * w[2];
    const z = u[0] * w[1] - u[1] * w[0];
    const lhs = x * x + y * y + z * z;
    const uu = u[0] * u[0] + u[1] * u[1] + u[2] * u[2];
    const ww = w[0] * w[0] + w[1] * w[1] + w[2] * w[2];
    return lhs <= uu * ww * 1.0e-10;
}

fn triangulate(a: Allocator, p: PMesh) Allocator.Error!Tris {
    var bmin = [3]f32{ 1.0e30, 1.0e30, 1.0e30 };
    var bmax = [3]f32{ -1.0e30, -1.0e30, -1.0e30 };
    for (p.verts) |v| for (0..3) |k| {
        bmin[k] = @min(bmin[k], v[k]);
        bmax[k] = @max(bmax[k], v[k]);
    };
    const np = p.faces();
    var total: usize = 0;
    for (0..np) |i| {
        const n = p.poff[i + 1] - p.poff[i];
        if (n >= 3) total += n - 2;
    }
    const tri = try a.alloc([3]u32, total);
    const tpoly = try a.alloc(u32, total);
    const first = try a.alloc(u32, np + 1);
    var nt: u32 = 0;
    var c: [256]u32 = undefined;
    for (0..np) |i| {
        first[i] = nt;
        const l = p.poly(i);
        if (l.len >= 4 and l.len <= 256) {
            var n: usize = l.len;
            @memcpy(c[0..n], l);
            var tip: usize = 1;
            var flats: usize = 0;
            while (n > 3 and flats < n) {
                if (tip >= n) tip = 0;
                const prev = (tip + n - 1) % n;
                const next = (tip + 1) % n;
                if (flat3(p.verts, c[prev], c[tip], c[next])) {
                    tip += 1;
                    flats += 1;
                    continue;
                }
                tri[nt] = .{ c[prev], c[tip], c[next] };
                tpoly[nt] = @intCast(i);
                nt += 1;
                std.mem.copyForwards(u32, c[tip .. n - 1], c[tip + 1 .. n]);
                n -= 1;
                flats = 0;
            }
            var k: usize = 1;
            while (k + 1 < n) : (k += 1) {
                tri[nt] = .{ c[0], c[k], c[k + 1] };
                tpoly[nt] = @intCast(i);
                nt += 1;
            }
        } else if (l.len >= 3) {
            var k: usize = 1;
            while (k + 1 < l.len) : (k += 1) {
                tri[nt] = .{ l[0], l[k], l[k + 1] };
                tpoly[nt] = @intCast(i);
                nt += 1;
            }
        }
    }
    first[np] = nt;
    return .{ .tri = tri, .tpoly = tpoly, .first = first, .bmin = bmin, .bmax = bmax };
}

// ---- exact predicates --------------------------------------------------------

fn cross2(x1: i64, y1: i64, x2: i64, y2: i64) i128 {
    return @as(i128, x1) * y2 -% @as(i128, y1) * x2;
}

/// x . (y x z), wrapping at 128 bits as the original ("assumed to fit": rows
/// are at most 2^41 in the ray tests, which leaves room).
fn det3(x: *const V3i, y: *const V3i, z: *const V3i) i128 {
    const a = cross2(y[1], y[2], z[1], z[2]) *% x[0];
    const b = cross2(y[2], y[0], z[2], z[0]) *% x[1];
    const c = cross2(y[0], y[1], z[0], z[1]) *% x[2];
    return a +% b +% c;
}

fn sgn(x: i128) i32 {
    return if (x < 0) -1 else if (x > 0) 1 else 0;
}

/// A point with its perturbation: p + e (n + d w), 1 >> d >> e.
const Pv = struct { p: *const V3i, n: *const V3i, w: *const V3i };

const ord_k = [10]u8{ 0, 1, 1, 2, 2, 2, 3, 3, 3, 3 };
const ord_m = [10]u8{ 0, 0, 1, 0, 1, 2, 0, 1, 2, 3 };

/// The sign of det(r + e (A + d B)), a polynomial in e and d: its first
/// non-zero coefficient in the order 1, e, ed, e^2, e^2 d, e^2 d^2, e^3, ...
/// With `out`, all ten coefficients are computed into it.
fn orientGen(pt: *const [4]Pv, out: ?*[10]i128) i32 {
    const d = pt[3];
    if (out == null) {
        var q: [3]V3i = undefined;
        for (0..3) |j| for (0..3) |i| {
            q[j][i] = pt[j].p[i] -% d.p[i];
        };
        const s = sgn(det3(&q[0], &q[1], &q[2]));
        if (s != 0) return s;
    }
    var rows: [3][3]V3i = undefined; // [row][r, A, B]
    var nz: [3]u32 = undefined;
    for (0..3) |j| {
        var bits: u32 = 0;
        for (0..3) |i| {
            rows[j][0][i] = pt[j].p[i] -% d.p[i];
            rows[j][1][i] = pt[j].n[i] -% d.n[i];
            rows[j][2][i] = pt[j].w[i] -% d.w[i];
            if (rows[j][1][i] != 0) bits |= 1;
            if (rows[j][2][i] != 0) bits |= 2;
        }
        nz[j] = bits;
    }
    var sign: i32 = 0;
    for (0..10) |o| {
        var sum: i128 = 0;
        for (0..27) |as| {
            const dg = [3]usize{ as % 3, (as / 3) % 3, (as / 9) % 3 };
            var k: u32 = 0;
            var mm: u32 = 0;
            var ok = true;
            for (dg, 0..) |g, j| {
                if (g != 0) k += 1;
                if (g == 2) mm += 1;
                if (g != 0 and nz[j] & (@as(u32, 1) << @intCast(g - 1)) == 0) ok = false;
            }
            if (!ok or k != ord_k[o] or mm != ord_m[o]) continue;
            sum +%= det3(&rows[0][dg[0]], &rows[1][dg[1]], &rows[2][dg[2]]);
        }
        if (out) |c| c[o] = sum;
        const s = sgn(sum);
        if (s != 0 and sign == 0) {
            sign = s;
            if (out == null) break;
        }
    }
    return sign;
}

/// A 128-bit value as a double, the way the original rounds it.
fn cDouble(x: i128) f64 {
    const hi: i64 = @truncate(x >> 64);
    const lo: u64 = @truncate(@as(u128, @bitCast(x)));
    const h = @as(f64, @floatFromInt(hi)) * 0x1p64;
    const half: i64 = @intCast(lo >> 1);
    const bit: i64 = @intCast(lo & 1);
    return h + (@as(f64, @floatFromInt(half)) * 2.0 + @as(f64, @floatFromInt(bit)));
}

// ---- the 2D triangulation of one triangle's scratch --------------------------

const Cdt = struct {
    n: u32 = 0,
    nt: u32 = 0,
    id: []u32,
    xy: [][2]f64,
    t: [][3]u32,
    ax: [2]u8 = .{ 0, 1 },
    flip: bool = false,
    area0: f64 = 0,
    depth: u32 = 0,
    es_t: []f64,
    es_id: []u32,
};

const Fragment = struct { v: [3]u32, src: u32 };

const RayGrid = struct {
    built: bool = false,
    n: i32 = 0,
    min: V3d = .{ 0, 0, 0 },
    inv: f64 = 0,
    off: []u32 = &.{},
    tri: []u32 = &.{},
};

const ray_dirs = [5]V3i{
    .{ 397268980492, 548411791148, 738007750828 },
    .{ -632880339924, 367344988844, 453830842372 },
    .{ 284920197524, -675288079484, 519101206532 },
    .{ 481353801116, 560948493844, -349641027932 },
    .{ -532028582132, -388902471676, 604131778652 },
};

/// One attempt (the original's module state).
const Ctx = struct {
    a: Allocator, // the attempt's arena
    out: Allocator, // the result's
    x: PMesh,
    y: PMesh,
    tx: *const Tris,
    ty: *const Tris,
    op: Op,
    jit: u32,
    /// bool.s as it is (runExact): its corner-cycle hash, a triangle whose
    /// triangulation fails gives the attempt up, a region on a source
    /// triangle of no area tested from where 0 / 0 puts it
    exact: bool = false,
    fail: bool = false,

    nva: u32 = 0,
    nvb: u32 = 0,
    nta: u32 = 0,
    ntb: u32 = 0,
    nv: u32 = 0,
    nt: u32 = 0,
    vd: []V3d = &.{},
    vi: []V3i = &.{},
    vw: []V3i = &.{},
    vn: []V3i = &.{},
    tri: [][3]u32 = &.{},
    tpoly: []u32 = &.{},
    ctr: V3d = .{ 0, 0, 0 },
    scl: f64 = 1,
    cell: f64 = 1,

    // edges
    n_edge: u32 = 0,
    te: [][3]u32 = &.{},
    ev: [][2]u32 = &.{},

    // intersections
    eh_p: Eh = undefined,
    p_pos: std.ArrayList(V3d) = .empty,
    inc: std.ArrayList([2]u32) = .empty, // (edge, point)
    seg: std.ArrayList([3]u32) = .empty, // triangle, p, q

    // pair grid
    g_n: u32 = 0,
    g_min: V3d = .{ 0, 0, 0 },
    g_inv: f64 = 0,
    g_off: []u32 = &.{},
    g_tri: []u32 = &.{},
    stamp: []u32 = &.{},

    // welding
    canon: []u32 = &.{}, // nv + np entries
    w_q: []V3i = &.{},
    w_tab: []u32 = &.{},

    // per triangle / per edge lists
    ts_off: []u32 = &.{},
    ts_seg: []u32 = &.{},
    ep_off: []u32 = &.{},
    ep_pts: []u32 = &.{},
    eh_c: Eh = undefined,

    cdt: Cdt = undefined,
    fr: std.ArrayList(Fragment) = .empty,

    // classification
    reg: []i32 = &.{},
    reg_in: []u8 = &.{},
    nreg: u32 = 0,
    rgs: [2]RayGrid = .{ .{}, .{} }, // [0]: B's triangles, [1]: A's
    rg_stamp: []u32 = &.{},
    rg_serial: u32 = 0,
    ray_p: V3i = .{ 0, 0, 0 },
    ray_q: V3i = .{ 0, 0, 0 },
    ray_n: V3i = .{ 0, 0, 0 },
    ray_w: V3i = .{ 0, 0, 0 },

    fn zeroed(c: *Ctx, comptime T: type, n: usize) Allocator.Error![]T {
        const s = try c.a.alloc(T, n);
        @memset(std.mem.sliceAsBytes(s), 0);
        return s;
    }

    fn vpos(c: *const Ctx, id: u32) V3d {
        return if (id < c.nv) c.vd[id] else c.p_pos.items[id - c.nv];
    }

    fn pv(c: *const Ctx, id: u32) Pv {
        return .{ .p = &c.vi[id], .n = &c.vn[id], .w = &c.vw[id] };
    }

    // ---- inputs: vertices, snapping, triangles ----------------------------

    fn loadInputs(c: *Ctx) StageError!void {
        c.nva = @intCast(c.x.verts.len);
        c.nvb = @intCast(c.y.verts.len);
        c.nv = c.nva + c.nvb;
        c.nta = @intCast(c.tx.tri.len);
        c.ntb = @intCast(c.ty.tri.len);
        c.nt = c.nta + c.ntb;
        c.vd = try c.a.alloc(V3d, c.nv);
        c.vi = try c.a.alloc(V3i, c.nv);
        c.vw = try c.zeroed(V3i, c.nv);
        // W: pseudo-random, odd, non-zero, < 2^20
        const K: u64 = 0x9E3779B97F4A7C15;
        for (c.nva..c.nv) |i| {
            var h: u64 = (@as(u64, i - c.nva) + 1) *% K;
            h ^= h >> 29;
            h *%= K;
            for (0..3) |k| {
                const q: i64 = @intCast(h & 0xFFFFF);
                c.vw[i][k] = (q - 0x7FFFF) | 1;
                h >>= 21;
            }
        }
        for (c.x.verts, 0..) |v, i| c.vd[i] = .{ v[0], v[1], v[2] };
        for (c.y.verts, c.nva..) |v, i| c.vd[i] = .{ v[0], v[1], v[2] };
        if (c.jit != 0) c.jitterB();

        // the snapping frame: centre of the box, grid below it
        var lo = c.vd[0];
        var hi = c.vd[0];
        for (c.vd) |p| for (0..3) |k| {
            lo[k] = min2(lo[k], p[k]);
            hi[k] = max2(hi[k], p[k]);
        };
        var ctr: V3d = undefined;
        var h: f64 = 0;
        for (0..3) |k| {
            ctr[k] = (lo[k] + hi[k]) * 0.5;
            h = max2(h, hi[k] - ctr[k]);
        }
        h = max2(h, 1.0e-9);
        // cell = 2^(floor(log2 h) - 17): float noise below it disappears and
        // dyadic coordinates stay exact; |coordinate| < 2^18 + 1
        const e: u64 = (@as(u64, @bitCast(h)) >> 52) & 0x7ff;
        const cell: f64 = @bitCast((e -% 17) << 52);
        const scl = 1.0 / cell;
        for (0..3) |k| ctr[k] = @as(f64, @floatFromInt(cvt(ctr[k] * scl))) * cell;
        for (c.vd, c.vi) |*p, *q| for (0..3) |k| {
            const r = cvt((p[k] - ctr[k]) * scl);
            q[k] = r;
            p[k] = @as(f64, @floatFromInt(r)) * cell + ctr[k]; // the snapped one
        };
        c.ctr = ctr;
        c.scl = scl;
        c.cell = cell;

        c.tri = try c.a.alloc([3]u32, c.nt);
        c.tpoly = try c.a.alloc(u32, c.nt);
        @memcpy(c.tri[0..c.nta], c.tx.tri);
        @memcpy(c.tpoly[0..c.nta], c.tx.tpoly);
        for (c.ty.tri, c.ty.tpoly, c.nta..) |t, q, i| {
            c.tri[i] = .{ t[0] + c.nva, t[1] + c.nva, t[2] + c.nva };
            c.tpoly[i] = q;
        }
    }

    /// Turn B's vertices by jit * 1e-5 rad about a generic axis through a
    /// generic point of A's box: breaks the coincidences (parallel coplanar
    /// edges, ...) that a translation alone cannot.
    fn jitterB(c: *Ctx) void {
        var o: V3d = undefined;
        for (0..3) |k| o[k] = @as(f64, c.tx.bmin[k]) * 0.6180339887 + @as(f64, c.tx.bmax[k]) * 0.3819660113;
        const th = @as(f64, @floatFromInt(c.jit)) * 1.0e-5;
        const k = V3d{ 0.4558423058 * th, 0.5698028822 * th, 0.6837634587 * th };
        for (c.vd[c.nva..]) |*p| {
            const r = subD(p.*, o);
            const t = crossD(k, r);
            p.* = .{ p[0] + t[0], p[1] + t[1], p[2] + t[2] };
        }
    }

    /// vn = B's vertex normals (sums of unit triangle normals) as integers of
    /// length 2^20: out for union and difference, in for intersection.
    fn bNormals(c: *Ctx) StageError!void {
        c.vn = try c.zeroed(V3i, c.nv);
        const sum = try c.zeroed(V3d, c.nv);
        for (c.tri[c.nta..]) |t| {
            const a = c.vd[t[0]];
            const n = crossD(subD(c.vd[t[1]], a), subD(c.vd[t[2]], a));
            const l = @sqrt(dotD(n, n));
            if (l == 0) continue;
            const f = 1.0 / l;
            for (t) |v| for (0..3) |k| {
                sum[v][k] += n[k] * f;
            };
        }
        const s: f64 = if (c.op == .intersect) -1048576.0 else 1048576.0;
        for (c.nva..c.nv) |i| {
            const l = @sqrt(dotD(sum[i], sum[i]));
            if (l == 0) continue; // no normal: W alone
            const f = s / l;
            for (0..3) |k| c.vn[i][k] = cvt(sum[i][k] * f);
        }
    }

    /// orient3d with the perturbation; 0 (degenerate even perturbed) flags the
    /// attempt as failed.
    fn orientSos(c: *Ctx, a: u32, b: u32, d: u32, e: u32) i32 {
        const pt = [4]Pv{ c.pv(a), c.pv(b), c.pv(d), c.pv(e) };
        const s = orientGen(&pt, null);
        if (s == 0) c.fail = true;
        return s;
    }

    /// Where the edge lo -> hi crosses the triangle's plane in the limit of
    /// the perturbation: t = D(lo) / (D(lo) - D(hi)) at the first order where
    /// they are not both 0.
    fn pointT(c: *const Ctx, t: *const [3]u32, lo: u32, hi: u32) f64 {
        var pt = [4]Pv{ c.pv(t[0]), c.pv(t[1]), c.pv(t[2]), c.pv(lo) };
        var dl: [10]i128 = undefined;
        var dh: [10]i128 = undefined;
        _ = orientGen(&pt, &dl);
        pt[3] = c.pv(hi);
        _ = orientGen(&pt, &dh);
        for (0..10) |k| {
            if (dl[k] == 0 and dh[k] == 0) continue;
            const h = cDouble(dh[k]);
            const l = cDouble(dl[k]);
            const q = l - h;
            if (q == 0) return 0.5;
            return l / q;
        }
        return 0.5;
    }

    // ---- edges ---------------------------------------------------------------

    fn buildEdges(c: *Ctx) StageError!void {
        var eh = try Eh.init(c.a, @as(usize, c.nt) * 3);
        c.te = try c.a.alloc([3]u32, c.nt);
        c.ev = try c.a.alloc([2]u32, @as(usize, c.nt) * 3);
        var n: u32 = 0;
        for (c.tri, 0..) |t, i| {
            for (0..3) |k| {
                const u = t[k];
                const v = t[(k + 1) % 3];
                const s = try eh.slot(ukey(u, v));
                if (!s.found) {
                    s.val.* = n;
                    c.ev[n] = .{ @min(u, v), @max(u, v) };
                    n += 1;
                }
                c.te[i][k] = s.val.*;
            }
        }
        c.n_edge = n;
    }

    // ---- intersections -------------------------------------------------------

    fn triBox(c: *const Ctx, t: u32) [2]V3d {
        const tv = c.tri[t];
        const a = c.vd[tv[0]];
        const b = c.vd[tv[1]];
        const d = c.vd[tv[2]];
        var r: [2]V3d = undefined;
        for (0..3) |k| {
            r[0][k] = min2(min2(a[k], b[k]), d[k]);
            r[1][k] = max2(max2(a[k], b[k]), d[k]);
        }
        return r;
    }

    fn clampG(c: *const Ctx, x: i64) u32 {
        if (x < 0) return 0;
        const top: i64 = c.g_n - 1;
        return @intCast(@min(x, top));
    }

    /// The grid cells a triangle's padded box covers.
    fn triCells(c: *const Ctx, t: u32) [6]u32 {
        const b = c.triBox(t);
        var r: [6]u32 = undefined;
        for (0..3) |k| {
            r[k] = c.clampG(cvtt((b[0][k] - c.g_min[k]) * c.g_inv - 0.001));
            r[k + 3] = c.clampG(cvtt((b[1][k] - c.g_min[k]) * c.g_inv + 0.001));
        }
        return r;
    }

    /// B's triangles bucketed into g_n^3 cells.
    fn buildGrid(c: *Ctx) StageError!void {
        const q = @sqrt(@sqrt(@as(f64, @floatFromInt(c.ntb)))) * 2.0;
        const g: u32 = @intCast(std.math.clamp(cvtt(q), 1, 96));
        c.g_n = g;
        var lo = V3d{ 1.0e300, 1.0e300, 1.0e300 };
        var hi = V3d{ -1.0e300, -1.0e300, -1.0e300 };
        for (c.vd[c.nva..]) |p| for (0..3) |k| {
            lo[k] = min2(lo[k], p[k]);
            hi[k] = max2(hi[k], p[k]);
        };
        c.g_min = lo;
        const size = max2(max2(max2(hi[0] - lo[0], hi[1] - lo[1]), hi[2] - lo[2]) * 1.001, 1.0e-9);
        c.g_inv = @as(f64, @floatFromInt(g)) / size;
        const cells: usize = @as(usize, g) * g * g;
        const off = try c.zeroed(u32, cells + 1);
        c.g_off = off;
        var pass: u32 = 0;
        while (pass < 2) : (pass += 1) {
            for (c.nta..c.nt) |ti| {
                const t: u32 = @intCast(ti);
                const r = c.triCells(t);
                var z = r[2];
                while (z <= r[5]) : (z += 1) {
                    var y = r[1];
                    while (y <= r[4]) : (y += 1) {
                        var x = r[0];
                        while (x <= r[3]) : (x += 1) {
                            const ci = ((z * g + y) * g + x);
                            if (pass == 0) {
                                off[ci + 1] += 1;
                            } else {
                                c.g_tri[off[ci]] = t - c.nta;
                                off[ci] += 1;
                            }
                        }
                    }
                }
            }
            if (pass == 0) {
                var sum: u32 = 0;
                for (off[1..]) |*v| {
                    sum += v.*;
                    v.* = sum;
                }
                c.g_tri = try c.a.alloc(u32, sum);
            } else {
                std.mem.copyBackwards(u32, off[1 .. cells + 1], off[0..cells]);
                off[0] = 0;
            }
        }
    }

    fn findIntersections(c: *Ctx) StageError!void {
        try c.buildGrid();
        c.eh_p = try Eh.init(c.a, @as(usize, c.nt) * 2);
        c.stamp = try c.zeroed(u32, c.ntb);
        const g = c.g_n;
        for (0..c.nta) |ti| {
            const ta: u32 = @intCast(ti);
            const r = c.triCells(ta);
            var z = r[2];
            while (z <= r[5]) : (z += 1) {
                var y = r[1];
                while (y <= r[4]) : (y += 1) {
                    var x = r[0];
                    while (x <= r[3]) : (x += 1) {
                        const ci = (z * g + y) * g + x;
                        for (c.g_tri[c.g_off[ci]..c.g_off[ci + 1]]) |tb| {
                            if (c.stamp[tb] == ta + 1) continue;
                            c.stamp[tb] = ta + 1;
                            try c.triTri(ta, tb + c.nta);
                        }
                    }
                }
            }
        }
        if (c.fail) return error.Degenerate;
    }

    /// Unless the snapped boxes are strictly apart (then no perturbation can
    /// join them).
    fn boxOverlap(c: *const Ctx, a: *const [3]u32, b: *const [3]u32) bool {
        for (0..3) |k| {
            const a0 = c.vi[a[0]][k];
            const a1 = c.vi[a[1]][k];
            const a2 = c.vi[a[2]][k];
            const b0 = c.vi[b[0]][k];
            const b1 = c.vi[b[1]][k];
            const b2 = c.vi[b[2]][k];
            if (@min(b0, b1, b2) > @max(a0, a1, a2)) return false;
            if (@min(a0, a1, a2) > @max(b0, b1, b2)) return false;
        }
        return true;
    }

    /// Records the segment and its points when they intersect.
    fn triTri(c: *Ctx, ta: u32, tb: u32) StageError!void {
        const a = c.tri[ta];
        const b = c.tri[tb];
        if (!c.boxOverlap(&a, &b)) return;
        var sa: [3]i32 = undefined;
        var sb: [3]i32 = undefined;
        for (0..3) |k| {
            sa[k] = c.orientSos(b[0], b[1], b[2], a[k]);
            sb[k] = c.orientSos(a[0], a[1], a[2], b[k]);
        }
        if (sa[0] == sa[1] and sa[0] == sa[2]) return;
        if (sb[0] == sb[1] and sb[0] == sb[2]) return;
        var n: u32 = 0;
        var ends: [2]u32 = undefined;
        for (0..3) |i| {
            const k = (i + 1) % 3;
            if (sa[i] == sa[k]) continue;
            if (!c.segThrough(&b, a[i], a[k])) continue;
            const p = try c.makePoint(ta, i, tb, &b);
            if (n >= 2) return c.degenerate();
            ends[n] = p;
            n += 1;
        }
        for (0..3) |i| {
            const k = (i + 1) % 3;
            if (sb[i] == sb[k]) continue;
            if (!c.segThrough(&a, b[i], b[k])) continue;
            const p = try c.makePoint(tb, i, ta, &a);
            if (n >= 2) return c.degenerate();
            ends[n] = p;
            n += 1;
        }
        if (n == 0) return;
        if (n != 2) return c.degenerate();
        try c.seg.append(c.a, .{ ta, ends[0], ends[1] });
        try c.seg.append(c.a, .{ tb, ends[0], ends[1] });
    }

    fn degenerate(c: *Ctx) Degenerate {
        c.fail = true;
        return error.Degenerate;
    }

    /// Segment pq (crossing the triangle's plane) passes through the triangle:
    /// the three orientations agree.
    fn segThrough(c: *Ctx, t: *const [3]u32, p: u32, q: u32) bool {
        const s = c.orientSos(p, q, t[0], t[1]);
        if (c.orientSos(p, q, t[1], t[2]) != s) return false;
        return c.orientSos(p, q, t[2], t[0]) == s and s != 0;
    }

    /// The intersection point of (edge of `owner`, face `face`), once per pair.
    fn makePoint(c: *Ctx, owner: u32, corner: usize, face: u32, ft: *const [3]u32) StageError!u32 {
        const edge = c.te[owner][corner];
        const s = try c.eh_p.slot(@as(u64, edge) << 32 | face);
        if (s.found) return s.val.* + c.nv;
        const id: u32 = @intCast(c.p_pos.items.len);
        s.val.* = id;
        try c.inc.append(c.a, .{ edge, id });
        const lo = c.ev[edge][0];
        const hi = c.ev[edge][1];
        const t = c.pointT(ft, lo, hi);
        const pl = c.vd[lo];
        const ph = c.vd[hi];
        try c.p_pos.append(c.a, .{
            (ph[0] - pl[0]) * t + pl[0],
            (ph[1] - pl[1]) * t + pl[1],
            (ph[2] - pl[2]) * t + pl[2],
        });
        return id + c.nv;
    }

    // ---- welding -------------------------------------------------------------

    /// The weld key: a lattice 16 times finer than the grid; a position within
    /// 1/16 cell of a grid point (where every vertex is) takes that grid point.
    fn wq(c: *const Ctx, p: V3d) V3i {
        var g: V3d = undefined;
        var off = false;
        for (0..3) |k| {
            g[k] = (p[k] - c.ctr[k]) * c.scl;
            if (@abs(@as(f64, @floatFromInt(cvt(g[k]))) - g[k]) >= 0.0625) off = true;
        }
        var r: V3i = undefined;
        for (0..3) |k| r[k] = if (off) cvt(g[k] * 16.0) else cvt(g[k]) *% 16;
        return r;
    }

    fn weldPoints(c: *Ctx) StageError!void {
        const total: usize = @as(usize, c.nv) + c.p_pos.items.len;
        var size: usize = 16;
        while (size < total * 2) size *= 2;
        c.w_tab = try c.zeroed(u32, size);
        c.w_q = try c.a.alloc(V3i, total);
        c.canon = try c.a.alloc(u32, total);
        const mask = size - 1;
        for (0..total) |ii| {
            const i: u32 = @intCast(ii);
            const q = c.wq(c.vpos(i));
            c.w_q[i] = q;
            var h: u64 = @as(u64, @bitCast(q[0] *% 0x5bd1e995)) ^
                @as(u64, @bitCast(q[1] *% 0x27d4eb2f)) ^
                @as(u64, @bitCast(q[2] *% 0x165667b1));
            h ^= h >> 29;
            var s: usize = @intCast(h & mask);
            while (true) : (s = (s + 1) & mask) {
                const e = c.w_tab[s];
                if (e == 0) {
                    c.w_tab[s] = i + 1;
                    c.canon[i] = i;
                    break;
                }
                if (std.mem.eql(i64, &c.w_q[e - 1], &q)) {
                    c.canon[i] = e - 1;
                    break;
                }
            }
        }
        for (c.seg.items) |*s| {
            s[1] = c.canon[s[1]];
            s[2] = c.canon[s[2]];
        }
    }

    // ---- splitting -----------------------------------------------------------

    fn splitTriangles(c: *Ctx) StageError!void {
        // segments per triangle
        const nseg = c.seg.items.len;
        c.ts_off = try c.zeroed(u32, @as(usize, c.nt) + 1);
        for (c.seg.items) |s| c.ts_off[s[0] + 1] += 1;
        for (0..c.nt) |i| c.ts_off[i + 1] += c.ts_off[i];
        c.ts_seg = try c.a.alloc(u32, nseg);
        {
            const cur = try c.a.dupe(u32, c.ts_off);
            for (c.seg.items, 0..) |s, i| {
                c.ts_seg[cur[s[0]]] = @intCast(i);
                cur[s[0]] += 1;
            }
        }
        try c.shareEdgePoints();
        // points per edge
        c.ep_off = try c.zeroed(u32, @as(usize, c.n_edge) + 1);
        for (c.inc.items) |e| c.ep_off[e[0] + 1] += 1;
        for (0..c.n_edge) |i| c.ep_off[i + 1] += c.ep_off[i];
        c.ep_pts = try c.a.alloc(u32, c.inc.items.len);
        {
            const cur = try c.a.dupe(u32, c.ep_off);
            for (c.inc.items) |e| {
                c.ep_pts[cur[e[0]]] = e[1];
                cur[e[0]] += 1;
            }
        }
        // constrained edges (for the classification)
        c.eh_c = try Eh.init(c.a, nseg + 8);
        for (c.seg.items) |s| {
            const e = try c.eh_c.slot(ukey(s[1], s[2]));
            e.val.* = 1;
        }
        c.cdt = .{
            .id = try c.a.alloc(u32, CDT_MAXP),
            .xy = try c.a.alloc([2]f64, CDT_MAXP),
            .t = try c.a.alloc([3]u32, CDT_MAXT),
            .es_t = try c.a.alloc(f64, CDT_MAXP),
            .es_id = try c.a.alloc(u32, CDT_MAXP),
        };
        // fragments
        for (0..c.nt) |ti| {
            const t: u32 = @intCast(ti);
            if (c.ts_off[ti] == c.ts_off[ti + 1]) {
                const v = c.tri[ti];
                try c.addFrag(c.canon[v[0]], c.canon[v[1]], c.canon[v[2]], t);
            } else {
                try c.cdtTriangle(t);
            }
        }
    }

    /// A segment end on a triangle's edge that the triangle across uses as
    /// well: the curve crosses that edge there, so the point joins the edge's
    /// list and both sides split it. (Used by one side only, it is inside that
    /// triangle symbolically and becomes a flat triangle there.)
    fn shareEdgePoints(c: *Ctx) StageError!void {
        const e2t = try c.a.alloc([2]i32, @as(usize, c.n_edge) + 1);
        @memset(e2t, .{ -1, -1 });
        for (c.te, 0..) |e3, t| for (e3) |e| {
            if (e2t[e][0] == -1) e2t[e][0] = @intCast(t) else e2t[e][1] = @intCast(t);
        };
        for (0..c.nt) |ti| {
            for (c.ts_seg[c.ts_off[ti]..c.ts_off[ti + 1]]) |si| {
                for ([2]usize{ 1, 2 }) |end| {
                    const p = c.seg.items[si][end];
                    if (p < c.nv) continue;
                    for (0..3) |k| {
                        const u = c.tri[ti][k];
                        const v = c.tri[ti][(k + 1) % 3];
                        if (c.canon[u] == p or c.canon[v] == p) break; // welded to a corner
                        if (!c.onEdge(u, v, p)) continue;
                        const e = c.te[ti][k];
                        var o = e2t[e][0];
                        if (o == @as(i32, @intCast(ti))) o = e2t[e][1];
                        if (o < 0) continue;
                        const ou: usize = @intCast(o);
                        for (c.ts_seg[c.ts_off[ou]..c.ts_off[ou + 1]]) |sj| {
                            const q = c.seg.items[sj];
                            if (q[1] == p or q[2] == p) {
                                try c.inc.append(c.a, .{ e, p - c.nv });
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    /// P on segment u-v, within the weld tolerance, strictly between the ends.
    fn onEdge(c: *const Ctx, u: u32, v: u32, p: u32) bool {
        const pu = c.vpos(u);
        const d = subD(c.vpos(v), pu);
        const w = subD(c.vpos(p), pu);
        const dd = dotD(d, d);
        const dw = dotD(d, w);
        if (!(dw > 0) or !(dw < dd)) return false;
        const x = crossD(w, d);
        const tol = c.cell * 0.125;
        return dotD(x, x) <= tol * tol * dd;
    }

    fn addFrag(c: *Ctx, a: u32, b: u32, d: u32, src: u32) StageError!void {
        if (a == b or b == d or d == a) return; // collapsed by the welding
        try c.fr.append(c.a, .{ .v = .{ a, b, d }, .src = src });
    }

    // ---- 2D constrained triangulation of one triangle ------------------------

    fn cdtAddPt(c: *Ctx, g: u32) ?u32 {
        const t = &c.cdt;
        for (t.id[0..t.n], 0..) |id, i| {
            if (id == g) return @intCast(i);
        }
        if (t.n >= CDT_MAXP) return null;
        const i = t.n;
        t.id[i] = g;
        t.n += 1;
        const p = c.vpos(g);
        t.xy[i] = .{ p[t.ax[0]], p[t.ax[1]] };
        return i;
    }

    fn o2(c: *const Ctx, i: u32, j: u32, k: u32) f64 {
        const xy = c.cdt.xy;
        const r = (xy[j][0] - xy[i][0]) * (xy[k][1] - xy[i][1]) - (xy[j][1] - xy[i][1]) * (xy[k][0] - xy[i][0]);
        return if (c.cdt.flip) -r else r;
    }

    fn cdtFail(c: *Ctx) Degenerate {
        return c.degenerate();
    }

    /// Deviation: where the first order fails, bool.s gives the whole boolean
    /// up. Runs of nearly collinear points (a triangle crossed along a line
    /// by a fan) can fold a triangle in floating point depending on the order
    /// they go in, so the other order is tried first.
    fn cdtTriangle(c: *Ctx, t: u32) StageError!void {
        c.cdtBuild(t, false) catch |e| switch (e) {
            error.Degenerate => if (c.exact) return e else try c.cdtBuild(t, true),
            else => return e,
        };
        const cd = &c.cdt;
        for (cd.t[0..cd.nt]) |l| try c.addFrag(cd.id[l[0]], cd.id[l[1]], cd.id[l[2]], t);
    }

    fn cdtBuild(c: *Ctx, t: u32, reversed: bool) StageError!void {
        const cd = &c.cdt;
        cd.n = 0;
        cd.nt = 0;
        const tv = c.tri[t];
        // the projection: drop the dominant axis of the normal
        const a = c.vpos(tv[0]);
        const n = crossD(subD(c.vpos(tv[1]), a), subD(c.vpos(tv[2]), a));
        var ax: usize = 0;
        var best = @abs(n[0]);
        if (@abs(n[1]) > best) {
            ax = 1;
            best = @abs(n[1]);
        }
        if (@abs(n[2]) > best) ax = 2;
        const axes = [3][2]u8{ .{ 1, 2 }, .{ 2, 0 }, .{ 0, 1 } }; // cyclic: CCW keeps its sign
        cd.ax = axes[ax];
        cd.flip = n[ax] < 0;
        // corners, canonical: one may share its place with the other mesh
        for (tv) |v| _ = c.cdtAddPt(c.canon[v]) orelse return c.cdtFail();
        if (cd.n < 3) return; // collapsed: nothing to cut
        cd.t[0] = .{ 0, 1, 2 };
        cd.nt = 1;
        cd.area0 = @abs(c.o2(0, 1, 2));
        // the points on the three edges, then the segments' other points
        for (0..3) |k| try c.cdtEdgePts(t, k);
        const segs = c.ts_seg[c.ts_off[t]..c.ts_off[t + 1]];
        for (0..segs.len) |i| {
            const s = c.seg.items[segs[if (reversed) segs.len - 1 - i else i]];
            try c.cdtInsert(s[1]);
            try c.cdtInsert(s[2]);
        }
        // the segments as edges
        for (segs) |si| {
            const s = c.seg.items[si];
            try c.cdtForce(s[1], s[2]);
        }
    }

    /// The points on edge k -> k+1, in order along it, each splitting the last
    /// piece: they are on that edge by construction, whatever the doubles say.
    fn cdtEdgePts(c: *Ctx, t: u32, k: usize) StageError!void {
        const cd = &c.cdt;
        const v_local: u32 = @intCast((k + 1) % 3);
        const pu = c.vpos(c.tri[t][k]);
        const d = subD(c.vpos(c.tri[t][v_local]), pu);
        const edge = c.te[t][k];
        var cnt: usize = 0;
        for (c.ep_pts[c.ep_off[edge]..c.ep_off[edge + 1]]) |pt| {
            if (cnt >= CDT_MAXP) return c.cdtFail();
            const g = c.canon[c.nv + pt];
            cd.es_id[cnt] = g;
            cd.es_t[cnt] = dotD(subD(c.vpos(g), pu), d);
            cnt += 1;
            var j = cnt - 1; // insertion sort by t
            while (j != 0 and cd.es_t[j - 1] > cd.es_t[j]) : (j -= 1) {
                std.mem.swap(f64, &cd.es_t[j - 1], &cd.es_t[j]);
                std.mem.swap(u32, &cd.es_id[j - 1], &cd.es_id[j]);
            }
        }
        var prev: u32 = @intCast(k);
        for (cd.es_id[0..cnt]) |g| {
            const n0 = cd.n;
            const p = c.cdtAddPt(g) orelse return c.cdtFail();
            if (p < n0) continue; // known (a corner, or twice)
            const e = c.cdtFindEdge(prev, v_local) orelse return c.cdtFail();
            cd.t[e.t] = .{ prev, p, e.third }; // (prev, P, w), (P, v, w)
            try c.cdtNew(p, v_local, e.third);
            prev = p;
        }
    }

    fn cdtNew(c: *Ctx, a: u32, b: u32, d: u32) Degenerate!void {
        const cd = &c.cdt;
        if (cd.nt >= CDT_MAXT) return c.cdtFail();
        cd.t[cd.nt] = .{ a, b, d };
        cd.nt += 1;
    }

    const EdgeHit = struct { t: u32, third: u32 };

    /// The triangle with the directed edge u -> v and its third vertex.
    fn cdtFindEdge(c: *const Ctx, u: u32, v: u32) ?EdgeHit {
        for (c.cdt.t[0..c.cdt.nt], 0..) |t, i| {
            for (0..3) |k| {
                const n = (k + 1) % 3;
                if (t[k] == u and t[n] == v) return .{ .t = @intCast(i), .third = t[(n + 1) % 3] };
            }
        }
        return null;
    }

    /// p on a-b: |o2| within `thr` (from the triangle's area) or within 1e-7 of
    /// the edge's length: computed edge points carry rounding a few orders
    /// above that, and a point taken off its line by it would leave a sliver
    /// no flip can repair.
    fn nearEdge(c: *const Ctx, a: u32, b: u32, p: u32, thr: f64) bool {
        const q = @abs(c.o2(a, b, p));
        const xy = c.cdt.xy;
        const dx = xy[b][0] - xy[a][0];
        const dy = xy[b][1] - xy[a][1];
        return q <= max2((dx * dx + dy * dy) * 1.0e-7, thr);
    }

    /// Split the triangle (or edge) holding a point.
    fn cdtInsert(c: *Ctx, g: u32) StageError!void {
        const cd = &c.cdt;
        const n0 = cd.n;
        const p = c.cdtAddPt(g) orelse return c.cdtFail();
        if (p < n0) return;
        // the most interior triangle wins; a flat one only when nothing else
        // holds the point
        var bt: i32 = -1;
        var bv: f64 = -1.0e300;
        for (cd.t[0..cd.nt], 0..) |t, i| {
            var v = c.o2(t[0], t[1], p);
            v = min2(c.o2(t[1], t[2], p), v);
            v = min2(c.o2(t[2], t[0], p), v);
            if (!(@abs(c.o2(t[0], t[1], t[2])) > cd.area0 * 1.0e-13)) v -= 1.0e200;
            if (v > bv) {
                bv = v;
                bt = @intCast(i);
            }
        }
        if (bt < 0) return c.cdtFail();
        const ti: u32 = @intCast(bt);
        const a = cd.t[ti][0];
        const b = cd.t[ti][1];
        const d = cd.t[ti][2];
        const rel = @abs(c.o2(a, b, d)) * 1.0e-9;
        var u: u32 = undefined;
        var v: u32 = undefined;
        var w: u32 = undefined;
        var on_edge = true;
        if (c.nearEdge(a, b, p, rel)) {
            u = a;
            v = b;
            w = d;
        } else if (c.nearEdge(b, d, p, rel)) {
            u = b;
            v = d;
            w = a;
        } else if (c.nearEdge(d, a, p, rel)) {
            u = d;
            v = a;
            w = b;
        } else on_edge = false;
        // a point that only looks to be on the triangle's own boundary is
        // inside it symbolically: a flat triangle, not a split the neighbour
        // cannot see
        if (on_edge and c.cdtFindEdge(v, u) == null) on_edge = false;
        if (!on_edge) {
            cd.t[ti] = .{ a, b, p };
            try c.cdtNew(b, d, p);
            try c.cdtNew(d, a, p);
            return;
        }
        cd.t[ti] = .{ u, p, w };
        try c.cdtNew(p, v, w);
        const e = c.cdtFindEdge(v, u) orelse return;
        cd.t[e.t] = .{ v, p, e.third };
        try c.cdtNew(p, u, e.third);
    }

    fn cdtLocal(c: *const Ctx, g: u32) ?u32 {
        for (c.cdt.id[0..c.cdt.n], 0..) |id, i| {
            if (id == g) return @intCast(i);
        }
        return null;
    }

    /// Make edge p-q exist by flipping the edges that cross it (Sloan).
    fn cdtForce(c: *Ctx, gp: u32, gq: u32) StageError!void {
        if (gp == gq) return; // welded to one point
        const cd = &c.cdt;
        const p = c.cdtLocal(gp) orelse return c.cdtFail();
        const q = c.cdtLocal(gq) orelse return c.cdtFail();
        var guard: u32 = 0;
        var start: u32 = 0; // round robin: an edge just made is not undone
        outer: while (true) {
            guard += 1;
            if (guard > 20000) return c.cdtFail();
            if (c.cdtFindEdge(p, q) != null or c.cdtFindEdge(q, p) != null) return;
            // an edge (a, b) crossing p-q in a convex quad: flip it, first
            // looking for flips whose new edge no longer crosses p-q
            for (0..2) |pass| {
                var si: u32 = 0;
                while (si < cd.nt) : (si += 1) {
                    const ti = (si + start) % cd.nt;
                    for (0..3) |k| {
                        const t = cd.t[ti];
                        const a = t[k];
                        const b = t[(k + 1) % 3];
                        const d = t[(k + 2) % 3];
                        if (a == p or a == q or b == p or b == q) continue;
                        if (!(c.o2(p, q, a) * c.o2(p, q, b) < 0)) continue;
                        if (!(c.o2(a, b, p) * c.o2(a, b, q) < 0)) continue;
                        const e = c.cdtFindEdge(b, a) orelse continue;
                        if (!(c.o2(d, e.third, a) * c.o2(d, e.third, b) < 0)) continue;
                        if (pass == 0 and d != p and d != q and e.third != p and e.third != q) {
                            if (c.o2(p, q, d) * c.o2(p, q, e.third) < 0 and
                                c.o2(d, e.third, p) * c.o2(d, e.third, q) < 0) continue; // it would still cross: later
                        }
                        start = ti + 1;
                        cd.t[ti] = .{ a, e.third, d };
                        cd.t[e.t] = .{ e.third, b, d };
                        continue :outer;
                    }
                }
            }
            break;
        }
        // nothing crosses p-q strictly: it runs through a vertex v (a point
        // that is on it in fact): recover p-v and v-q
        if (cd.depth >= 64) return c.cdtFail();
        const xy = cd.xy;
        const dx = xy[q][0] - xy[p][0];
        const dy = xy[q][1] - xy[p][1];
        const l2 = dx * dx + dy * dy;
        if (!(l2 > 0)) return c.cdtFail();
        var bv: i32 = -1;
        var bt: f64 = 2.0;
        for (0..cd.n) |vi| {
            if (vi == p or vi == q) continue;
            const wx = xy[vi][0] - xy[p][0];
            const wy = xy[vi][1] - xy[p][1];
            const t = (wx * dx + wy * dy) / l2;
            if (!(t > 1.0e-9)) continue;
            if (!(t < 1.0 - 1.0e-9)) continue;
            const cr = wx * dy - wy * dx;
            if (cr * cr > l2 * l2 * 1.0e-18) continue;
            if (t >= bt) continue;
            bt = t;
            bv = @intCast(vi);
        }
        if (bv < 0) return c.cdtFail();
        const gv = cd.id[@intCast(bv)];
        cd.depth += 1;
        defer cd.depth -= 1;
        try c.cdtForce(gp, gv);
        try c.cdtForce(gv, gq);
    }

    // ---- classification ------------------------------------------------------

    fn classify(c: *Ctx) StageError!void {
        const fr = c.fr.items;
        c.reg = try c.a.alloc(i32, fr.len + 1);
        @memset(c.reg, -1);
        var eh = try Eh.init(c.a, fr.len * 3);
        const pair = try c.a.alloc([2]i32, fr.len * 3 + 2);
        @memset(pair, .{ -1, -1 });
        var used: u32 = 0;
        const bbit: u64 = 1 << 63; // A and B apart
        for (fr, 0..) |f, i| {
            const isb = f.src >= c.nta;
            for (0..3) |k| {
                var key = ukey(f.v[k], f.v[(k + 1) % 3]);
                if (isb) key |= bbit;
                const s = try eh.slot(key);
                if (!s.found) {
                    s.val.* = used;
                    used += 1;
                }
                const q = &pair[s.val.*];
                if (q[0] == -1) q[0] = @intCast(i) else q[1] = @intCast(i);
            }
        }
        // the flood: regions, never across a constrained edge
        const stack = try c.a.alloc(u32, fr.len + 1);
        var nreg: u32 = 0;
        for (0..fr.len) |seed| {
            if (c.reg[seed] != -1) continue;
            const rid: i32 = @intCast(nreg);
            c.reg[seed] = rid;
            nreg += 1;
            stack[0] = @intCast(seed);
            var sp: usize = 1;
            while (sp != 0) {
                sp -= 1;
                const fi = stack[sp];
                const f = fr[fi];
                for (0..3) |k| {
                    const key = ukey(f.v[k], f.v[(k + 1) % 3]);
                    if (c.eh_c.get(key) != null) continue;
                    const s = eh.get(if (f.src >= c.nta) key | bbit else key) orelse continue;
                    var o = pair[s][0];
                    if (o == @as(i32, @intCast(fi))) o = pair[s][1];
                    if (o < 0) continue;
                    const ou: usize = @intCast(o);
                    if (c.reg[ou] != -1) continue;
                    c.reg[ou] = rid;
                    stack[sp] = @intCast(o);
                    sp += 1;
                }
            }
        }
        c.nreg = nreg;
        // one test per region: its largest fragment against the other mesh
        c.reg_in = try c.zeroed(u8, nreg + 8);
        const best = try c.a.alloc(i32, nreg);
        const area = try c.zeroed(f32, nreg);
        @memset(best, -1);
        for (fr, 0..) |f, i| {
            const q = c.fragArea(f);
            const r: usize = @intCast(c.reg[i]);
            if (best[r] == -1 or q > area[r]) {
                area[r] = q;
                best[r] = @intCast(i);
            }
        }
        for (0..nreg) |r| {
            const inside = try c.fragInside(fr[@intCast(best[r])]);
            c.reg_in[r] = inside orelse return c.degenerate();
        }
    }

    fn fragArea(c: *const Ctx, f: Fragment) f32 {
        const a = c.vpos(f.v[0]);
        const n = crossD(subD(c.vpos(f.v[1]), a), subD(c.vpos(f.v[2]), a));
        return @floatCast(@sqrt(dotD(n, n)));
    }

    /// 1 if its centroid is inside the other mesh (exact ray parity; another
    /// direction on a tie), null when every direction ties.
    fn fragInside(c: *Ctx, f: Fragment) Allocator.Error!?u8 {
        const side: usize = if (f.src >= c.nta) 1 else 0;
        const t = c.tri[f.src];
        // the sample: the centroid, rounded to barycentric weights k / 2^16 on
        // the source triangle, so it lies exactly on that triangle and moves
        // with it when B is perturbed; ray tests run on coordinates x 2^16
        var o = V3d{ 0, 0, 0 };
        for (f.v) |v| {
            const p = c.vpos(v);
            o[0] += p[0];
            o[1] += p[1];
            o[2] += p[2];
        }
        for (&o) |*q| q.* *= 0.3333333333333333;
        const a = c.vpos(t[0]);
        const e1 = subD(c.vpos(t[1]), a);
        const e2 = subD(c.vpos(t[2]), a);
        const d = subD(o, a);
        const n = crossD(e1, e2);
        const nn = dotD(n, n);
        var kb: i64 = 21845;
        var kd: i64 = 21845;
        // (a source triangle of no area: its centre; bool.s divides by the 0
        // and the weights come out as the integer indefinite)
        if (nn > 0 or c.exact) {
            kb = cvt(dotD(crossD(d, e2), n) / nn * 65536.0);
            kd = cvt(dotD(crossD(e1, d), n) / nn * 65536.0);
        }
        const k = [3]i64{ 65536 -% kb -% kd, kb, kd };
        for (0..3) |i| {
            var sp: i64 = 0;
            var sn: i64 = 0;
            var sw: i64 = 0;
            for (0..3) |j| {
                sp +%= c.vi[t[j]][i] *% k[j];
                sn +%= c.vn[t[j]][i] *% k[j];
                sw +%= c.vw[t[j]][i] *% k[j];
            }
            c.ray_p[i] = sp;
            c.ray_n[i] = sn;
            c.ray_w[i] = sw;
        }
        for (ray_dirs) |dir| {
            for (0..3) |i| c.ray_q[i] = c.ray_p[i] +% (dir[i] *% 2);
            const hits = try c.rayCount(side);
            if (hits) |h| return @intCast(h & 1);
        }
        return null;
    }

    fn rgBuild(c: *Ctx, side: usize) Allocator.Error!void {
        const rg = &c.rgs[side];
        const lo: u32 = if (side == 1) 0 else c.nta;
        const hi: u32 = if (side == 1) c.nta else c.nt;
        const count = hi - lo;
        var g: u32 = 1; // the cube root of the count, 1 .. 128
        while (g * g * g < count and g < 128) g += 1;
        rg.n = @intCast(g);
        var bmin = V3d{ 1.0e300, 1.0e300, 1.0e300 };
        var bmax = V3d{ -1.0e300, -1.0e300, -1.0e300 };
        for (c.tri[lo..hi]) |t| for (t) |v| for (0..3) |k| {
            const q: f64 = @floatFromInt(c.vi[v][k]);
            bmin[k] = min2(bmin[k], q);
            bmax[k] = max2(bmax[k], q);
        };
        rg.min = bmin;
        const size = max2(max2(bmax[0] - bmin[0], bmax[1] - bmin[1]), bmax[2] - bmin[2]) * 1.001 + 1.0;
        rg.inv = @as(f64, @floatFromInt(g)) / size;
        const cells: usize = @as(usize, g) * g * g;
        const off = try c.zeroed(u32, cells + 1);
        rg.off = off;
        const top: i64 = rg.n - 1;
        var pass: u32 = 0;
        while (pass < 2) : (pass += 1) {
            for (c.tri[lo..hi], lo..) |t, ti| {
                var box: [6]u32 = undefined;
                for (0..3) |k| {
                    var mn: f64 = 1.0e300;
                    var mx: f64 = -1.0e300;
                    for (t) |v| {
                        const q: f64 = @floatFromInt(c.vi[v][k]);
                        mn = min2(mn, q);
                        mx = max2(mx, q);
                    }
                    box[k] = @intCast(std.math.clamp(cvtt((mn - bmin[k]) * rg.inv - 0.01), 0, top));
                    box[k + 3] = @intCast(std.math.clamp(cvtt((mx - bmin[k]) * rg.inv + 0.01), 0, top));
                }
                var z = box[2];
                while (z <= box[5]) : (z += 1) {
                    var y = box[1];
                    while (y <= box[4]) : (y += 1) {
                        var x = box[0];
                        while (x <= box[3]) : (x += 1) {
                            const ci = (z * g + y) * g + x;
                            if (pass == 0) {
                                off[ci + 1] += 1;
                            } else {
                                rg.tri[off[ci]] = @intCast(ti);
                                off[ci] += 1;
                            }
                        }
                    }
                }
            }
            if (pass == 0) {
                var sum: u32 = 0;
                for (off[1..]) |*v| {
                    sum += v.*;
                    v.* = sum;
                }
                rg.tri = try c.a.alloc(u32, sum);
            } else {
                std.mem.copyBackwards(u32, off[1 .. cells + 1], off[0..cells]);
                off[0] = 0;
            }
        }
        rg.built = true;
    }

    /// Crossings of ray_p -> ray_q with the triangles of `side`, walking the
    /// grid; null when one is a tie.
    fn rayCount(c: *Ctx, side: usize) Allocator.Error!?u32 {
        const rg = &c.rgs[side];
        if (!rg.built) try c.rgBuild(side);
        if (c.rg_stamp.len == 0) c.rg_stamp = try c.zeroed(u32, c.nt);
        c.rg_serial += 1;
        const nf: f64 = @floatFromInt(rg.n);
        const n2m16 = 1.52587890625e-05;
        var o: V3d = undefined;
        var d: V3d = undefined;
        for (0..3) |k| {
            const po = (@as(f64, @floatFromInt(c.ray_p[k])) * n2m16 - rg.min[k]) * rg.inv;
            const qo = (@as(f64, @floatFromInt(c.ray_q[k])) * n2m16 - rg.min[k]) * rg.inv;
            o[k] = po;
            d[k] = qo - po;
        }
        var t0: f64 = 0;
        var t1: f64 = 1;
        for (0..3) |k| {
            if (@abs(d[k]) > 1.0e-30) {
                const a = (0.0 - o[k]) / d[k];
                const b = (nf - o[k]) / d[k];
                t0 = max2(t0, min2(a, b));
                t1 = min2(t1, max2(a, b));
            } else if (o[k] < 0 or o[k] > nf) {
                return 0;
            }
        }
        if (t0 > t1) return 0;
        var cell: [3]i32 = undefined;
        var step: [3]i32 = undefined;
        var tmax: V3d = undefined;
        var tdelta: V3d = undefined;
        for (0..3) |k| {
            const q = cvtt(d[k] * t0 + o[k]);
            const at: i32 = @intCast(std.math.clamp(q, 0, rg.n - 1));
            cell[k] = at;
            if (@abs(d[k]) > 1.0e-30) {
                const s: i32 = if (d[k] > 0) 1 else -1;
                step[k] = s;
                var b: f64 = @floatFromInt(at);
                if (s == 1) b += 1.0;
                tmax[k] = (b - o[k]) / d[k];
                tdelta[k] = 1.0 / @abs(d[k]);
            } else {
                step[k] = 0;
                tmax[k] = 1.0e300;
                tdelta[k] = 1.0e300;
            }
        }
        var hits: u32 = 0;
        const un: u32 = @intCast(rg.n);
        while (true) {
            const ci = ((@as(u32, @intCast(cell[2])) * un + @as(u32, @intCast(cell[1]))) * un + @as(u32, @intCast(cell[0])));
            for (rg.tri[rg.off[ci]..rg.off[ci + 1]]) |t| {
                if (c.rg_stamp[t] == c.rg_serial) continue;
                c.rg_stamp[t] = c.rg_serial;
                const r = c.rayTri(t);
                if (r < 0) return null;
                hits += @intCast(r);
            }
            var ax: usize = 0;
            var tm = tmax[0];
            for (1..3) |k| {
                if (tmax[k] < tm) {
                    tm = tmax[k];
                    ax = k;
                }
            }
            if (tm > t1) break;
            if (step[ax] == 0) break;
            const nc = cell[ax] + step[ax];
            if (nc < 0 or nc >= rg.n) break;
            cell[ax] = nc;
            tmax[ax] += tdelta[ax];
        }
        return hits;
    }

    /// A vertex times 2^16 (the scale of the ray tests).
    fn scaled(c: *const Ctx, v: u32, out: *[3]V3i) Pv {
        for (0..3) |k| {
            out[0][k] = c.vi[v][k] << 16;
            out[1][k] = c.vn[v][k] << 16;
            out[2][k] = c.vw[v][k] << 16;
        }
        return .{ .p = &out[0], .n = &out[1], .w = &out[2] };
    }

    /// 1 if the segment ray_p -> ray_q crosses the triangle, 0 if not, -1 on
    /// an exact tie.
    fn rayTri(c: *const Ctx, t: u32) i32 {
        const tv = c.tri[t];
        var sv: [3][3]V3i = undefined;
        const a = c.scaled(tv[0], &sv[0]);
        const b = c.scaled(tv[1], &sv[1]);
        const d = c.scaled(tv[2], &sv[2]);
        const sp = orientGen(&.{ a, b, d, .{ .p = &c.ray_p, .n = &c.ray_n, .w = &c.ray_w } }, null);
        const sq = orientGen(&.{ a, b, d, .{ .p = &c.ray_q, .n = &c.ray_n, .w = &c.ray_w } }, null);
        if (sp == 0 and sq == 0) return 0; // on its plane: a flat triangle, nothing to cross
        if (sp == 0 or sq == 0) return -1;
        if (sp == sq) return 0;
        const rp = Pv{ .p = &c.ray_p, .n = &c.ray_n, .w = &c.ray_w };
        const rq = Pv{ .p = &c.ray_q, .n = &c.ray_n, .w = &c.ray_w };
        const e0 = orientGen(&.{ rp, rq, a, b }, null);
        if (e0 == 0) return -1;
        const e1 = orientGen(&.{ rp, rq, b, d }, null);
        if (e1 == 0) return -1;
        if (e1 != e0) return 0;
        const e2 = orientGen(&.{ rp, rq, d, a }, null);
        if (e2 == 0) return -1;
        if (e2 != e0) return 0;
        return 1;
    }

    // ---- assembly -------------------------------------------------------------

    /// 1 keep, 2 keep flipped, 0 drop.
    fn keepFrag(c: *const Ctx, i: usize) u8 {
        const isb = c.fr.items[i].src >= c.nta;
        const inside = c.reg_in[@intCast(c.reg[i])];
        return switch (c.op) {
            .union_ => inside ^ 1, // outside parts of both
            .intersect => inside, // inside parts of both
            .difference => if (!isb) inside ^ 1 else if (inside != 0) 2 else 0, // B's flipped
        };
    }

    fn assemble(c: *Ctx) StageError!PMesh {
        const fr = c.fr.items;
        // which source triangles survived whole
        const whole = try c.zeroed(u8, c.nt);
        for (fr, 0..) |f, i| {
            if (c.ts_off[f.src] == c.ts_off[f.src + 1]) whole[f.src] = c.keepFrag(i);
        }
        const polya: u32 = @intCast(c.x.faces());
        const emitted = try c.zeroed(u8, @as(usize, polya) + c.y.faces() + 1);
        var poff: std.ArrayList(u32) = .empty;
        var loops: std.ArrayList(u32) = .empty;
        try poff.ensureTotalCapacity(c.a, fr.len + polya + c.y.faces() + 2);
        try loops.ensureTotalCapacity(c.a, fr.len * 3 + c.x.loops.len + c.y.loops.len + 16);
        try poff.append(c.a, 0);
        // polygons whose every triangle survived whole, the same way, come
        // back as the original polygon
        for (0..2) |mi| {
            const src = if (mi == 0) c.x else c.y;
            const tr = if (mi == 0) c.tx else c.ty;
            const voff: u32 = if (mi == 0) 0 else c.nva;
            const toff: u32 = if (mi == 0) 0 else c.nta;
            const poffs: u32 = if (mi == 0) 0 else polya;
            for (0..src.faces()) |p| {
                const f0 = tr.first[p] + toff;
                const f1 = tr.first[p + 1] + toff;
                if (f0 == f1) continue;
                const w = whole[f0];
                if (w == 0) continue;
                var same = true;
                for (whole[f0..f1]) |q| {
                    if (q != w) same = false;
                }
                if (!same) continue;
                emitted[p + poffs] = 1;
                const l = src.poly(p);
                const start = loops.items.len;
                for (l) |v| try loops.append(c.a, c.canon[v + voff]);
                if (w == 2) std.mem.reverse(u32, loops.items[start..]);
                try poff.append(c.a, @intCast(loops.items.len));
            }
        }
        // the remaining kept fragments as triangles
        for (fr, 0..) |f, i| {
            const isb = f.src >= c.nta;
            const gp = c.tpoly[f.src] + (if (isb) polya else 0);
            if (emitted[gp] != 0) continue;
            const k = c.keepFrag(i);
            if (k == 0) continue;
            if (k == 2) {
                try loops.appendSlice(c.a, &.{ f.v[2], f.v[1], f.v[0] });
            } else {
                try loops.appendSlice(c.a, &f.v);
            }
            try poff.append(c.a, @intCast(loops.items.len));
        }
        try c.cancelSheets(&poff, &loops);
        return c.compact(poff.items, loops.items);
    }

    /// A polygon and another one with the same corners in the opposite order
    /// enclose nothing (A - A, faces pressed together): both go.
    fn cancelSheets(c: *Ctx, poff: *std.ArrayList(u32), loops: *std.ArrayList(u32)) StageError!void {
        const np = poff.items.len - 1;
        var eh = try Eh.init(c.a, np);
        const dead = try c.zeroed(u8, np + 1);
        for (0..np) |p| {
            const l = loops.items[poff.items[p]..poff.items[p + 1]];
            const back = cycHash(l, true, c.exact);
            if (eh.get(back)) |q| {
                if (dead[q] == 0 and cycReverse(l, loops.items[poff.items[q]..poff.items[q + 1]])) {
                    dead[p] = 1;
                    dead[q] = 1;
                    continue;
                }
            }
            const s = try eh.slot(cycHash(l, false, c.exact));
            s.val.* = @intCast(p);
        }
        var wp: usize = 0;
        var wl: u32 = 0;
        for (0..np) |p| {
            if (dead[p] != 0) continue;
            const s = poff.items[p];
            const e = poff.items[p + 1];
            poff.items[wp] = wl;
            std.mem.copyForwards(u32, loops.items[wl..], loops.items[s..e]);
            wl += e - s;
            wp += 1;
        }
        poff.items[wp] = wl;
        poff.items.len = wp + 1;
        loops.items.len = wl;
    }

    /// The vertices used, as the result.
    fn compact(c: *Ctx, poff: []const u32, loops: []const u32) StageError!PMesh {
        const total: usize = @as(usize, c.nv) + c.p_pos.items.len;
        const map = try c.a.alloc(u32, total);
        @memset(map, 0xffffffff);
        for (loops) |v| map[v] = 0;
        var n: u32 = 0;
        for (map) |*q| {
            if (q.* == 0) {
                q.* = n;
                n += 1;
            }
        }
        const verts = try c.out.alloc(m.V3, n);
        errdefer c.out.free(verts);
        for (map, 0..) |q, i| {
            if (q == 0xffffffff) continue;
            const p = c.vpos(@intCast(i));
            verts[q] = .{ @floatCast(p[0]), @floatCast(p[1]), @floatCast(p[2]) };
        }
        const op = try c.out.dupe(u32, poff);
        errdefer c.out.free(op);
        const ol = try c.out.alloc(u32, loops.len);
        for (loops, ol) |v, *o| o.* = map[v];
        return .{ .verts = verts, .poff = op, .loops = ol };
    }

    fn attempt(c: *Ctx) StageError!PMesh {
        try c.loadInputs();
        try c.bNormals();
        try c.buildEdges();
        try c.findIntersections();
        try c.weldPoints();
        try c.splitTriangles();
        try c.classify();
        return c.assemble();
    }
};

/// The corner cycle, from its smallest corner, forwards or backwards.
///
/// Deviation: bool.s clobbers its running hash here, so that only the last
/// corner counts and opposite polygons match by luck; this one hashes the
/// whole cycle, so coincident opposite faces always cancel as its comment says.
fn cycHash(l: []const u32, reversed: bool, exact: bool) u64 {
    var c: usize = 0;
    for (l, 0..) |v, i| {
        if (v < l[c]) c = i;
    }
    const n = l.len;
    var h: u64 = 0xcbf29ce484222325 ^ @as(u64, n);
    for (0..n) |k| {
        const i = if (reversed) (c + n - k) % n else (c + k) % n;
        // (bool.s: the index, before the wrap, overwrites the running hash)
        if (exact) h = @as(u32, @truncate(if (reversed) c + n - k else c + k));
        h = (h ^ l[i]) *% 0x100000001b3;
    }
    return h >> 1;
}

/// q is p backwards.
fn cycReverse(p: []const u32, q: []const u32) bool {
    if (p.len != q.len) return false;
    const j = std.mem.indexOfScalar(u32, q, p[0]) orelse return false;
    for (p, 0..) |v, k| {
        if (q[(j + q.len - k) % q.len] != v) return false;
    }
    return true;
}

fn wellFormed(p: PMesh) bool {
    if (p.poff.len == 0) return p.loops.len == 0;
    if (p.poff[0] != 0 or p.poff[p.poff.len - 1] != p.loops.len) return false;
    for (p.poff[0 .. p.poff.len - 1], p.poff[1..]) |a, b| {
        if (a > b) return false;
    }
    for (p.loops) |v| {
        if (v >= p.verts.len) return false;
    }
    for (p.verts) |v| for (v) |q| {
        if (!std.math.isFinite(q)) return false;
    };
    return true;
}

/// Combine two meshes, already in one coordinate space. The result is closed
/// when both inputs are, unless the solids only touch along a line (open by
/// nature). Open inputs give the original's best effort: no retries, no
/// promises. The inputs are not touched; the result belongs to the caller.
pub fn run(a: Allocator, x: PMesh, y: PMesh, op: Op) !PMesh {
    return runWith(a, x, y, op, false);
}

/// mesh_boolean exactly as bool.s gives it, its faults included (the feature
/// tree's booleans: their meshes are the original's byte for byte): the
/// corner-cycle hash that finds coincident opposite faces counts only the
/// last corner, so some such pairs stay; a cut triangle whose triangulation
/// fails gives the attempt up instead of trying the other order; a region
/// whose source triangle has no area is tested from the point its 0 / 0
/// weights give, not from the triangle's centre.
pub fn runExact(a: Allocator, x: PMesh, y: PMesh, op: Op) !PMesh {
    return runWith(a, x, y, op, true);
}

fn runWith(a: Allocator, x: PMesh, y: PMesh, op: Op, exact: bool) !PMesh {
    if (!wellFormed(x) or !wellFormed(y)) return error.BooleanFailed;
    var keep = std.heap.ArenaAllocator.init(a);
    defer keep.deinit();
    var work = std.heap.ArenaAllocator.init(a);
    defer work.deinit();
    const tx = try triangulate(keep.allocator(), x);
    const ty = try triangulate(keep.allocator(), y);
    if (tx.tri.len == 0 or ty.tri.len == 0) return error.BooleanFailed;
    const closed = try manifold(keep.allocator(), x.poff, x.loops) and
        try manifold(keep.allocator(), y.poff, y.loops);

    var best: ?PMesh = null; // a result that is not closed, in case nothing better comes
    errdefer if (best) |b| b.deinit(a);
    var jit: u32 = 0;
    while (true) : (jit += 1) {
        _ = work.reset(.retain_capacity);
        var c = Ctx{ .a = work.allocator(), .out = a, .x = x, .y = y, .tx = &tx, .ty = &ty, .op = op, .jit = jit, .exact = exact };
        const r: ?PMesh = c.attempt() catch |e| switch (e) {
            error.Degenerate => null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (r) |res| {
            if (!closed) return res;
            const good = manifold(work.allocator(), res.poff, res.loops) catch |e| {
                res.deinit(a);
                return e;
            };
            if (best) |b| b.deinit(a);
            best = null;
            if (good) return res;
            best = res; // solids touching along a line, ...: try turned a hair
        }
        if (jit >= 2) break;
    }
    return best orelse error.BooleanFailed;
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;
const gpa = testing.allocator;

const Mat = struct { r: [9]f64 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 }, t: V3d = .{ 0, 0, 0 } };

fn rotXYZ(ax: f64, ay: f64, az: f64) [9]f64 {
    const cx = @cos(ax);
    const sx = @sin(ax);
    const cy = @cos(ay);
    const sy = @sin(ay);
    const cz = @cos(az);
    const sz = @sin(az);
    return .{
        cy * cz,                 -cy * sz,                sy,
        sx * sy * cz + cx * sz,  -sx * sy * sz + cx * cz, -sx * cy,
        -cx * sy * cz + sx * sz, cx * sy * sz + sx * cz,  cx * cy,
    };
}

fn moved(p: PMesh, x: Mat) !PMesh {
    const q = try p.clone(gpa);
    for (q.verts) |*v| {
        const a: V3d = .{ v[0], v[1], v[2] };
        for (0..3) |k| {
            const w = x.r[k * 3] * a[0] + x.r[k * 3 + 1] * a[1] + x.r[k * 3 + 2] * a[2] + x.t[k];
            v[k] = @floatCast(w);
        }
    }
    return q;
}

fn takes(p: PMesh, x: Mat) !PMesh {
    defer p.deinit(gpa);
    return moved(p, x);
}

const Builder = struct {
    verts: std.ArrayList(m.V3) = .empty,
    loops: std.ArrayList(u32) = .empty,
    poff: std.ArrayList(u32) = .empty,

    fn vert(b: *Builder, x: f64, y: f64, z: f64) !void {
        try b.verts.append(gpa, .{ @floatCast(x), @floatCast(y), @floatCast(z) });
    }
    fn poly(b: *Builder, l: []const u32) !void {
        if (b.poff.items.len == 0) try b.poff.append(gpa, 0);
        try b.loops.appendSlice(gpa, l);
        try b.poff.append(gpa, @intCast(b.loops.items.len));
    }
    fn done(b: *Builder) !PMesh {
        return .{
            .verts = try b.verts.toOwnedSlice(gpa),
            .poff = try b.poff.toOwnedSlice(gpa),
            .loops = try b.loops.toOwnedSlice(gpa),
        };
    }
};

/// The original's UV sphere, Y up: 512 faces at 16 x 32, triangles at the poles.
fn sphere(rings: u32, segs: u32, r: f64) !PMesh {
    var b = Builder{};
    try b.vert(0, r, 0);
    for (1..rings) |i| for (0..segs) |j| {
        const th = std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(rings));
        const ph = 2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(segs));
        try b.vert(r * @sin(th) * @cos(ph), r * @cos(th), r * @sin(th) * @sin(ph));
    };
    try b.vert(0, -r, 0);
    const south = 1 + (rings - 1) * segs;
    const at = struct {
        fn f(i: u32, j: u32, s: u32) u32 {
            return 1 + i * s + (j % s);
        }
    }.f;
    for (0..segs) |ju| {
        const j: u32 = @intCast(ju);
        try b.poly(&.{ 0, at(0, j + 1, segs), at(0, j, segs) });
        for (0..rings - 2) |iu| {
            const i: u32 = @intCast(iu);
            try b.poly(&.{ at(i, j, segs), at(i, j + 1, segs), at(i + 1, j + 1, segs), at(i + 1, j, segs) });
        }
        try b.poly(&.{ south, at(rings - 2, j, segs), at(rings - 2, j + 1, segs) });
    }
    return b.done();
}

fn cylinder(segs: u32) !PMesh {
    var b = Builder{};
    for (0..segs) |j| {
        const ph = 2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(segs));
        try b.vert(@cos(ph), -1, @sin(ph));
        try b.vert(@cos(ph), 1, @sin(ph));
    }
    var lo: std.ArrayList(u32) = .empty;
    defer lo.deinit(gpa);
    var hi: std.ArrayList(u32) = .empty;
    defer hi.deinit(gpa);
    for (0..segs) |ju| {
        const j: u32 = @intCast(ju);
        const k = (j + 1) % segs;
        try b.poly(&.{ 2 * j, 2 * j + 1, 2 * k + 1, 2 * k });
        try lo.append(gpa, 2 * j);
        try hi.append(gpa, 2 * (segs - 1 - j) + 1);
    }
    try b.poly(lo.items);
    try b.poly(hi.items);
    return b.done();
}

fn cone(segs: u32) !PMesh {
    var b = Builder{};
    for (0..segs) |j| {
        const ph = 2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(segs));
        try b.vert(@cos(ph), -1, @sin(ph));
    }
    try b.vert(0, 1, 0);
    var lo: std.ArrayList(u32) = .empty;
    defer lo.deinit(gpa);
    for (0..segs) |ju| {
        const j: u32 = @intCast(ju);
        try b.poly(&.{ j, segs, (j + 1) % segs });
        try lo.append(gpa, j);
    }
    try b.poly(lo.items);
    return b.done();
}

fn torus(nu: u32, nv: u32, big: f64, small: f64) !PMesh {
    var b = Builder{};
    for (0..nu) |i| for (0..nv) |j| {
        const u = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(nu));
        const v = 2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(nv));
        const r = big + small * @cos(v);
        try b.vert(r * @cos(u), small * @sin(v), r * @sin(u));
    };
    for (0..nu) |iu| for (0..nv) |ju| {
        const i: u32 = @intCast(iu);
        const j: u32 = @intCast(ju);
        const ip = (i + 1) % nu;
        const jp = (j + 1) % nv;
        try b.poly(&.{ i * nv + j, i * nv + jp, ip * nv + jp, ip * nv + j });
    };
    return b.done();
}

fn mkBox(lo: V3d, hi: V3d) !PMesh {
    const c = try pmesh.testCube(gpa);
    for (c.verts) |*v| for (0..3) |k| {
        v[k] = @floatCast(if (v[k] < 0) lo[k] else hi[k]);
    };
    return c;
}

const Prim = enum { cube, sphere, cylinder, cone, torus };

fn prim(t: Prim) !PMesh {
    return switch (t) {
        .cube => pmesh.testCube(gpa),
        .sphere => sphere(16, 32, 1),
        .cylinder => cylinder(32),
        .cone => cone(32),
        .torus => torus(24, 24, 1, 0.25),
    };
}

/// Signed volume, |result| of a closed mesh; polygons as fans.
fn volume(p: PMesh) f64 {
    var s: f64 = 0;
    for (0..p.faces()) |i| {
        const l = p.poly(i);
        var k: usize = 1;
        while (k + 1 < l.len) : (k += 1) {
            const a = p.verts[l[0]];
            const b = p.verts[l[k]];
            const c = p.verts[l[k + 1]];
            const da = V3d{ a[0], a[1], a[2] };
            s += dotD(da, crossD(.{ b[0], b[1], b[2] }, .{ c[0], c[1], c[2] }));
        }
    }
    return s / 6.0;
}

/// Every edge in exactly two faces, once each way. An empty mesh is closed.
fn isClosed(p: PMesh) !bool {
    return manifold(gpa, p.poff, p.loops);
}

fn expectClosed(p: PMesh) !void {
    try testing.expect(try isClosed(p));
}

fn near(a: f64, b: f64, tol: f64) !void {
    if (@abs(a - b) > tol) {
        std.debug.print("expected {d}, got {d} (tol {d})\n", .{ b, a, tol });
        return error.TestExpectedApproxEq;
    }
}

const Vols = struct { u: f64, i: f64, d: f64, closed: bool };

fn three(a: PMesh, b: PMesh) !Vols {
    const u = try run(gpa, a, b, .union_);
    defer u.deinit(gpa);
    const i = try run(gpa, a, b, .intersect);
    defer i.deinit(gpa);
    const d = try run(gpa, a, b, .difference);
    defer d.deinit(gpa);
    return .{
        .u = volume(u),
        .i = volume(i),
        .d = volume(d),
        .closed = try isClosed(u) and try isClosed(i) and try isClosed(d),
    };
}

fn expectIdentities(a: PMesh, b: PMesh, tol: f64) !Vols {
    const v = try three(a, b);
    const va = volume(a);
    const vb = volume(b);
    try near(v.u + v.i, va + vb, tol);
    try near(v.d, va - v.i, tol);
    return v;
}

test "two overlapping boxes: exact volumes" {
    const a = try mkBox(.{ -1, -1, -1 }, .{ 1, 1, 1 });
    defer a.deinit(gpa);
    const b = try mkBox(.{ 0.5, 0.25, 0.125 }, .{ 2.5, 2.25, 2.125 });
    defer b.deinit(gpa);
    const v = try expectIdentities(a, b, 1e-3);
    try testing.expect(v.closed);
    const shared = 0.5 * 0.75 * 0.875;
    try near(v.i, shared, 1e-3);
    try near(v.d, 8 - shared, 1e-3);
    try near(v.u, 16 - shared, 1e-3);
}

test "disjoint, and one inside the other" {
    const a = try mkBox(.{ -1, -1, -1 }, .{ 1, 1, 1 });
    defer a.deinit(gpa);
    const far = try mkBox(.{ 3, 3, 3 }, .{ 4, 4, 4 });
    defer far.deinit(gpa);
    const v = try expectIdentities(a, far, 1e-3);
    try testing.expect(v.closed);
    try near(v.u, 9, 1e-3);
    try near(v.i, 0, 1e-9);
    try near(v.d, 8, 1e-3);
    const inner = try mkBox(.{ -0.5, -0.5, -0.5 }, .{ 0.5, 0.5, 0.5 });
    defer inner.deinit(gpa);
    const w = try expectIdentities(a, inner, 1e-3);
    try testing.expect(w.closed);
    try near(w.u, 8, 1e-3);
    try near(w.i, 1, 1e-3);
    try near(w.d, 7, 1e-3);
}

test "a flush cut goes through" {
    // the cutter's ends lie exactly in the block's top and bottom faces
    const a = try mkBox(.{ -1, -1, -1 }, .{ 1, 1, 1 });
    defer a.deinit(gpa);
    const b = try mkBox(.{ -0.5, -0.5, -1 }, .{ 0.5, 0.5, 1 });
    defer b.deinit(gpa);
    const r = try run(gpa, a, b, .difference);
    defer r.deinit(gpa);
    try expectClosed(r);
    try near(volume(r), 6, 1e-3);
    // no cap left in the hole: no polygon has its centre inside it at z = +-1
    for (0..r.faces()) |i| {
        var c = V3d{ 0, 0, 0 };
        const l = r.poly(i);
        for (l) |v| for (0..3) |k| {
            c[k] += r.verts[v][k];
        };
        for (&c) |*q| q.* /= @floatFromInt(l.len);
        try testing.expect(!(@abs(c[0]) < 0.49 and @abs(c[1]) < 0.49));
    }
    // a pocket with one flush face: the block's top opens, the floor stays
    const p = try mkBox(.{ -0.5, -0.5, 0 }, .{ 0.5, 0.5, 1 });
    defer p.deinit(gpa);
    const s = try run(gpa, a, p, .difference);
    defer s.deinit(gpa);
    try expectClosed(s);
    try near(volume(s), 7, 1e-3);
}

test "touching solids fuse" {
    const a = try mkBox(.{ -1, -1, -1 }, .{ 1, 1, 1 });
    defer a.deinit(gpa);
    const b = try mkBox(.{ 1, -1, -1 }, .{ 3, 1, 1 });
    defer b.deinit(gpa);
    const r = try run(gpa, a, b, .union_);
    defer r.deinit(gpa);
    try expectClosed(r);
    try near(volume(r), 16, 1e-3);
    // no wall left between them
    for (0..r.faces()) |i| {
        var c = V3d{ 0, 0, 0 };
        const l = r.poly(i);
        for (l) |v| for (0..3) |k| {
            c[k] += r.verts[v][k];
        };
        for (&c) |*q| q.* /= @floatFromInt(l.len);
        try testing.expect(!(@abs(c[0] - 1) < 1e-4 and @abs(c[1]) < 0.99 and @abs(c[2]) < 0.99));
    }
    const x = try run(gpa, a, b, .intersect);
    defer x.deinit(gpa);
    try near(volume(x), 0, 1e-4);
    try testing.expectEqual(@as(usize, 0), x.faces());
    const d = try run(gpa, a, b, .difference);
    defer d.deinit(gpa);
    try expectClosed(d);
    try near(volume(d), 8, 1e-3);
}

test "identical meshes: A - A is empty, A + A and A n A are A" {
    for ([_]Prim{ .cube, .sphere, .cylinder, .cone, .torus }) |t| {
        const a = try prim(t);
        defer a.deinit(gpa);
        const d = try run(gpa, a, a, .difference);
        defer d.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), d.faces());
        try testing.expectEqual(@as(usize, 0), d.verts.len);
        const u = try run(gpa, a, a, .union_);
        defer u.deinit(gpa);
        try expectClosed(u);
        try near(volume(u), volume(a), 1e-3);
        const i = try run(gpa, a, a, .intersect);
        defer i.deinit(gpa);
        try expectClosed(i);
        try near(volume(i), volume(a), 1e-3);
    }
}

test "inputs are not touched" {
    const a = try prim(.sphere);
    defer a.deinit(gpa);
    const b = try takes(try prim(.sphere), .{ .t = .{ 0.5, 0.25, 0.1 } });
    defer b.deinit(gpa);
    const a0 = try a.clone(gpa);
    defer a0.deinit(gpa);
    const b0 = try b.clone(gpa);
    defer b0.deinit(gpa);
    const r = try run(gpa, a, b, .difference);
    defer r.deinit(gpa);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a0.verts), std.mem.sliceAsBytes(a.verts));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(b0.verts), std.mem.sliceAsBytes(b.verts));
    try testing.expectEqualSlices(u32, a0.loops, a.loops);
    try testing.expectEqualSlices(u32, b0.poff, b.poff);
}

test "a quarter turn typed as 1.570796" {
    for ([_]Prim{ .cube, .sphere, .cylinder, .cone, .torus }) |t| {
        for ([_][3]f64{ .{ 1.570796, 0, 0 }, .{ 0, 1.570796, 0 }, .{ 0, 0, 1.570796 }, .{ 1.570796, 1.570796, 0 } }) |e| {
            const a = try prim(t);
            defer a.deinit(gpa);
            const b = try takes(try prim(t), .{ .r = rotXYZ(e[0], e[1], e[2]) });
            defer b.deinit(gpa);
            const tol = 2e-3 * (volume(a) + volume(b)) + 1e-4;
            const v = try expectIdentities(a, b, tol);
            if (t == .cube) {
                try testing.expect(v.closed);
                try near(v.u, 8, 1e-3);
                try near(v.i, 8, 1e-3);
                try near(v.d, 0, 1e-3);
            }
        }
    }
}

test "open, empty and malformed inputs" {
    const cube = try pmesh.testCube(gpa);
    defer cube.deinit(gpa);
    // a plane through the cube: the original's best effort, open, no crash
    var b = Builder{};
    try b.vert(-2, 0, -2);
    try b.vert(2, 0, -2);
    try b.vert(2, 0, 2);
    try b.vert(-2, 0, 2);
    try b.poly(&.{ 0, 1, 2, 3 });
    const plane = try b.done();
    defer plane.deinit(gpa);
    for ([_]Op{ .union_, .difference, .intersect }) |op| {
        const r = try run(gpa, cube, plane, op);
        defer r.deinit(gpa);
        for (r.loops) |v| try testing.expect(v < r.verts.len);
        const q = try run(gpa, plane, cube, op);
        defer q.deinit(gpa);
        for (q.loops) |v| try testing.expect(v < q.verts.len);
    }
    // no triangles at all
    const empty = PMesh{ .verts = &.{}, .poff = &.{}, .loops = &.{} };
    try testing.expectError(error.BooleanFailed, run(gpa, cube, empty, .union_));
    try testing.expectError(error.BooleanFailed, run(gpa, empty, cube, .difference));
    try testing.expectError(error.BooleanFailed, run(gpa, empty, empty, .intersect));
    var o0 = [_]u32{0};
    const none = PMesh{ .verts = &.{}, .poff = &o0, .loops = &.{} };
    try testing.expectError(error.BooleanFailed, run(gpa, cube, none, .union_));
    // an index out of range, a NaN
    const bad = try cube.clone(gpa);
    defer bad.deinit(gpa);
    bad.loops[3] = 99;
    try testing.expectError(error.BooleanFailed, run(gpa, cube, bad, .union_));
    bad.loops[3] = 1;
    bad.verts[2][1] = std.math.nan(f32);
    try testing.expectError(error.BooleanFailed, run(gpa, cube, bad, .union_));
    bad.verts[2][1] = std.math.inf(f32);
    try testing.expectError(error.BooleanFailed, run(gpa, cube, bad, .union_));
}

test "snapping: extreme coordinates neither crash nor hang" {
    // everything on one far point: the box has no size, the grid under it is
    // fine enough to overflow i64 at the centre
    var c = try pmesh.testCube(gpa);
    defer c.deinit(gpa);
    for (c.verts) |*v| v.* = .{ 1.0e30, -1.0e30, 3.0e7 };
    for ([_]Op{ .union_, .difference, .intersect }) |op| {
        if (run(gpa, c, c, op)) |r| {
            defer r.deinit(gpa);
            for (r.loops) |v| try testing.expect(v < r.verts.len);
        } else |e| try testing.expectEqual(error.BooleanFailed, e);
    }
    // the largest finite coordinates, and sizes far apart
    const huge = try takes(try prim(.cube), .{ .r = .{ 3e38, 0, 0, 0, 3e38, 0, 0, 0, 3e38 } });
    defer huge.deinit(gpa);
    const unit = try prim(.cube);
    defer unit.deinit(gpa);
    for ([_]Op{ .union_, .difference, .intersect }) |op| {
        const r = try run(gpa, huge, unit, op);
        defer r.deinit(gpa);
        for (r.verts) |v| for (v) |q| try testing.expect(std.math.isFinite(q));
    }
}

test "out of memory at every allocation: an error, no leak" {
    const a = try mkBox(.{ -1, -1, -1 }, .{ 1, 1, 1 });
    defer a.deinit(gpa);
    const b = try mkBox(.{ 0.5, 0.25, 0.125 }, .{ 2.5, 2.25, 2.125 });
    defer b.deinit(gpa);
    const f = struct {
        fn go(al: Allocator, p: PMesh, q: PMesh) !void {
            const r = try run(al, p, q, .difference);
            r.deinit(al);
        }
    }.go;
    try testing.checkAllAllocationFailures(gpa, f, .{ a, b });
}

test "a triangle crossed along a line by a fan needs the other order" {
    // fails in the original: a cube's face cut along one line by all the
    // triangles of a cone's base, nearly collinear points in floating point
    const cone_v = [_]m.V3{
        .{ -0.610750, 1.275110, -0.032832 }, .{ -0.773704, 1.180593, -0.087069 },
        .{ -0.927374, 1.061691, -0.113095 }, .{ -1.065853, 0.922973, -0.109907 },
        .{ -1.183820, 0.769769, -0.077629 }, .{ -1.276742, 0.607967, -0.017500 },
        .{ -1.341047, 0.443786, 0.068168 },  .{ -1.374264, 0.283536, 0.176083 },
        .{ -1.375118, 0.133373, 0.302098 },  .{ -1.343574, -0.000931, 0.441370 },
        .{ -1.280846, -0.114216, 0.588549 }, .{ -1.189344, -0.202126, 0.737975 },
        .{ -1.072583, -0.261285, 0.883910 }, .{ -0.935052, -0.289418, 1.020743 },
        .{ -0.782035, -0.285446, 1.143216 }, .{ -0.619414, -0.249518, 1.246622 },
        .{ -0.453437, -0.183019, 1.326989 }, .{ -0.290483, -0.088502, 1.381226 },
        .{ -0.136813, 0.030400, 1.407252 },  .{ 0.001666, 0.169119, 1.404064 },
        .{ 0.119633, 0.322323, 1.371786 },   .{ 0.212555, 0.484124, 1.311657 },
        .{ 0.276860, 0.648305, 1.225989 },   .{ 0.310077, 0.808556, 1.118074 },
        .{ 0.310931, 0.958718, 0.992059 },   .{ 0.279387, 1.093022, 0.852787 },
        .{ 0.216658, 1.206307, 0.705608 },   .{ 0.125156, 1.294217, 0.556182 },
        .{ 0.008396, 1.353376, 0.410248 },   .{ -0.129135, 1.381510, 0.273415 },
        .{ -0.282152, 1.377537, 0.150941 },  .{ -0.444773, 1.341610, 0.047535 },
        .{ 0.532094, -0.546046, -0.647079 },
    };
    const cube_v = [_]m.V3{
        .{ -0.054714, -0.161727, -0.206900 }, .{ -0.055753, -0.769796, 1.698422 },
        .{ -2.055752, -0.771427, 1.696810 },  .{ -2.054712, -0.163357, -0.208511 },
        .{ -0.056757, 1.743594, 0.401168 },   .{ -0.057796, 1.135525, 2.306490 },
        .{ -2.057795, 1.133894, 2.304878 },   .{ -2.056756, 1.741964, 0.399557 },
    };
    var b = Builder{};
    for (cone_v) |v| try b.vert(v[0], v[1], v[2]);
    var base: [32]u32 = undefined;
    for (0..32) |ju| {
        const j: u32 = @intCast(ju);
        try b.poly(&.{ j, 32, (j + 1) % 32 });
        base[j] = j;
    }
    try b.poly(&base);
    const a = try b.done();
    defer a.deinit(gpa);
    var q = Builder{};
    for (cube_v) |v| try q.vert(v[0], v[1], v[2]);
    for ([_][4]u32{ .{ 0, 1, 2, 3 }, .{ 7, 6, 5, 4 }, .{ 0, 4, 5, 1 }, .{ 1, 5, 6, 2 }, .{ 2, 6, 7, 3 }, .{ 3, 7, 4, 0 } }) |f| try q.poly(&f);
    const c = try q.done();
    defer c.deinit(gpa);
    const v = try expectIdentities(a, c, 1e-3);
    try testing.expect(v.closed);
    try near(v.i, 1.056651, 1e-3);
}

test "chains: results feed the next boolean" {
    var r = try mkBox(.{ -1, -1, -1 }, .{ 1, 1, 1 });
    defer r.deinit(gpa);
    var rng = std.Random.DefaultPrng.init(7);
    const rnd = rng.random();
    var expect: f64 = volume(r);
    for (0..24) |_| {
        const p = [6]f64{
            (rnd.float(f64) - 0.5) * 2, (rnd.float(f64) - 0.5) * 2, (rnd.float(f64) - 0.5) * 2,
            rnd.float(f64) * 3,         rnd.float(f64) * 3,         rnd.float(f64) * 3,
        };
        const s = try takes(try sphere(8, 16, 0.3), .{ .r = rotXYZ(p[3], p[4], p[5]), .t = .{ p[0], p[1], p[2] } });
        defer s.deinit(gpa);
        const shared = try run(gpa, r, s, .intersect);
        defer shared.deinit(gpa);
        expect -= volume(shared);
        const n = try run(gpa, r, s, .difference);
        r.deinit(gpa);
        r = n;
        try expectClosed(r);
    }
    try near(volume(r), expect, 2e-2);
}

test "goldens from the original binary: boxes touching on a face, edge, corner" {
    // faces, vertices of union, difference (Edit > Boolean on the same OBJ
    // files in build/beemodel); intersections are empty. Solids touching
    // along a line need the retry with B turned a hair to come out closed.
    const G = struct { d: V3d, uf: usize, uv: usize, df: usize, dv: usize };
    for ([_]G{
        .{ .d = .{ 2, 2, 0 }, .uf = 17, .uv = 15, .df = 10, .dv = 8 },
        .{ .d = .{ 2, 2, 2 }, .uf = 18, .uv = 15, .df = 9, .dv = 8 },
        .{ .d = .{ 2, 0.5, 0.25 }, .uf = 32, .uv = 21, .df = 21, .dv = 14 },
        .{ .d = .{ 2, 2, 0.5 }, .uf = 12, .uv = 16, .df = 11, .dv = 9 },
    }) |g| {
        const a = try mkBox(.{ -1, -1, -1 }, .{ 1, 1, 1 });
        defer a.deinit(gpa);
        const b = try takes(try mkBox(.{ -1, -1, -1 }, .{ 1, 1, 1 }), .{ .t = g.d });
        defer b.deinit(gpa);
        const u = try run(gpa, a, b, .union_);
        defer u.deinit(gpa);
        const d = try run(gpa, a, b, .difference);
        defer d.deinit(gpa);
        const i = try run(gpa, a, b, .intersect);
        defer i.deinit(gpa);
        try expectClosed(u);
        try expectClosed(d);
        try near(volume(u), 16, 1e-3);
        try near(volume(d), 8, 1e-3);
        try testing.expectEqual(@as(usize, 0), i.faces());
        try testing.expectEqual(g.uf, u.faces());
        try testing.expectEqual(g.uv, u.verts.len);
        try testing.expectEqual(g.df, d.faces());
        try testing.expectEqual(g.dv, d.verts.len);
    }
}

test "untouched polygons keep their shape" {
    const a = try mkBox(.{ -1, -1, -1 }, .{ 1, 1, 1 });
    defer a.deinit(gpa);
    const b = try mkBox(.{ 3, 3, 3 }, .{ 4, 4, 4 });
    defer b.deinit(gpa);
    const u = try run(gpa, a, b, .union_);
    defer u.deinit(gpa);
    try testing.expectEqual(@as(usize, 12), u.faces());
    try testing.expectEqual(@as(usize, 48), u.loops.len);
}

// The stress corpus (tests/bool_stress.py), in process: a quarter of the cases
// general position, the others built for exact coincidences. The tolerance and
// the allowance for solids touching along a line (open by nature) are the
// corpus's.
const StressCase = struct { ta: Prim, tb: Prim, pa: [6]f64, pb: [6]f64, general: bool };

fn genCase(r: std.Random, i: u32) StressCase {
    const types = [_]Prim{ .cube, .sphere, .cylinder, .cone, .torus };
    var c = StressCase{
        .ta = types[r.uintLessThan(u32, 5)],
        .tb = types[r.uintLessThan(u32, 5)],
        .pa = .{ 0, 0, 0, 0, 0, 0 },
        .pb = .{ 0, 0, 0, 0, 0, 0 },
        .general = false,
    };
    if (i % 4 == 0) { // coincidences: grid offsets, quarter turns
        const off = [_]f64{ 0, 0.5, 1, 0.25, 2 };
        for (0..3) |k| c.pb[k] = off[r.uintLessThan(u32, 5)];
        const turns = [_]f64{ 1.570796, 1.5707963267948966 };
        const q = turns[r.uintLessThan(u32, 2)];
        for (3..6) |k| c.pb[k] = q * @as(f64, @floatFromInt(r.uintLessThan(u32, 3)));
    } else if (i % 8 == 1) { // identical operands
        c.tb = c.ta;
    } else {
        c.general = true;
        for (3..6) |k| c.pa[k] = (r.float(f64) - 0.5) * 6;
        for (0..3) |k| c.pb[k] = (r.float(f64) - 0.5) * 2.4;
        for (3..6) |k| c.pb[k] = (r.float(f64) - 0.5) * 6;
    }
    return c;
}

fn place(t: Prim, p: [6]f64) !PMesh {
    return takes(try prim(t), .{ .r = rotXYZ(p[3], p[4], p[5]), .t = .{ p[0], p[1], p[2] } });
}

fn stress(n: u32, seed: u64, max_open_pct: f64) !void {
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    var touching: u32 = 0;
    for (0..n) |iu| {
        const i: u32 = @intCast(iu);
        const k = genCase(r, i);
        const a = try place(k.ta, k.pa);
        defer a.deinit(gpa);
        const b = try place(k.tb, k.pb);
        defer b.deinit(gpa);
        const va = volume(a);
        const vb = volume(b);
        const tol = 2e-3 * (@abs(va) + @abs(vb)) + 1e-4;
        const v = try three(a, b);
        const ok = @abs(v.u + v.i - va - vb) < tol and @abs(v.d - (va - v.i)) < tol and
            v.i > -tol and v.u + tol >= @max(va, vb);
        if (!ok) {
            std.debug.print("case {d} {s}/{s} {any} {any}: va {d} vb {d} u {d} i {d} d {d}\n", .{ i, @tagName(k.ta), @tagName(k.tb), k.pa, k.pb, va, vb, v.u, v.i, v.d });
            return error.VolumeIdentity;
        }
        if (!v.closed) {
            if (k.general) {
                std.debug.print("open in general position: case {d} {s}/{s}\n", .{ i, @tagName(k.ta), @tagName(k.tb) });
                return error.OpenResult;
            }
            touching += 1;
        }
    }
    const pct = 100.0 * @as(f64, @floatFromInt(touching)) / @as(f64, @floatFromInt(n));
    if (pct > max_open_pct) {
        std.debug.print("{d} of {d} coincident cases open\n", .{ touching, n });
        return error.TooManyOpen;
    }
}

test "stress corpus, fixed seed" {
    try stress(300, 1, 2.0);
}

test "stress: rotated, translated cubes and spheres, fixed seed" {
    var rng = std.Random.DefaultPrng.init(0xBEE);
    const r = rng.random();
    for (0..200) |_| {
        const ka: Prim = if (r.boolean()) .cube else .sphere;
        const kb: Prim = if (r.boolean()) .cube else .sphere;
        var pa: [6]f64 = undefined;
        var pb: [6]f64 = undefined;
        for (0..3) |k| {
            pa[k] = 0;
            pb[k] = (r.float(f64) - 0.5) * 3.2;
            pa[k + 3] = (r.float(f64) - 0.5) * 6.3;
            pb[k + 3] = (r.float(f64) - 0.5) * 6.3;
        }
        const a = try place(ka, pa);
        defer a.deinit(gpa);
        const b = try place(kb, pb);
        defer b.deinit(gpa);
        const tol = 2e-3 * (volume(a) + volume(b)) + 1e-4;
        const v = try expectIdentities(a, b, tol);
        try testing.expect(v.closed);
        try testing.expect(v.i > -tol and v.i < @min(volume(a), volume(b)) + tol);
    }
}
