// Shatter (shatter.s): cutting a closed mesh into convex cells.
//
// A cell is a set of planes (n.x <= d inside). A solid is convex polygons
// (the mesh's triangles to start with) clipped by one plane after another,
// in doubles: each vertex is in, on (within the tolerance) or out; a polygon
// with nothing out is kept, one with nothing in goes, the rest are clipped
// (Sutherland-Hodgman; the point on a cut edge is made once, from the edge's
// ends in order, so both its polygons share it). The hole the plane leaves
// (the kept polygons' edges in the plane with no twin) is chained into loops
// and filled: a convex loop is one polygon; otherwise holes are bridged into
// the smallest outer loop around them, the ring is ear clipped (reflex
// corners in a grid) and the triangles joined into convex polygons again
// (Hertel-Mehlhorn). After the last plane the solid is the mesh inside the
// cell; its parts that do not touch become pieces of their own.
//
// The cells go into a tree (split at their centres' median); each node's
// solid is its parent's cut by the node's box, level by level, so a cell is
// cut from its leaf's small solid. Cells and nodes are cut on every thread
// (jobs.zig), each with an arena of its own; every result is the same
// whatever the threads. Whether a point is inside: a skewed ray's crossings,
// odd; on a mesh of 256 triangles or more only those in the point's square
// of a grid of the triangles seen along the ray.
//
// Every comparison and every sum is in the original's order and with its
// NaN behaviour (comisd / minsd / maxsd), so the pieces are its bit for bit.
const std = @import("std");
const Allocator = std.mem.Allocator;
const pa = std.heap.page_allocator;

pub const V = [3]f64;
pub const Plane = struct { n: V = .{ 0, 0, 0 }, d: f64 = 0, tag: u32 = 0 };
pub const Poly = struct { first: u32, cnt: u32, tag: u32 };
pub const CPL_MAX = 128;

const CL_IN: u8 = 0;
const CL_ON: u8 = 1;
const CL_OUT: u8 = 2;

const BIG: f64 = 1.0e300;
const TINY: f64 = 1.0e-300;
const RAY = V{ 0.5773502691896258, 0.5773674398219341, 0.5773330981405107 };
const RAYU = V{ 0.7071172957739438, -0.7070962664427984, 0.0 };
const RAYV = V{ 0.40823007816688506, 0.40824221909578634, -0.8165087224442901 };

// ---- NaN-faithful helpers ------------------------------------------------------------

/// minsd a, b: a when a < b, else b.
inline fn minsd(a: f64, b: f64) f64 {
    return if (a < b) a else b;
}
inline fn maxsd(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}
/// cvttsd2si to i32: out of range or NaN gives 0x80000000.
pub fn cvtt(x: f64) i32 {
    if (!(x > -2147483649.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}

// ---- the source -------------------------------------------------------------------------

pub var src_p: []V = &.{};
/// triangles (a b c), turned when the mesh was inside out
pub var src_t: [][3]u32 = &.{};
var src_pp: []Poly = &.{};
var src_pl: []u32 = &.{};
pub var src_min: V = .{ 0, 0, 0 };
pub var src_max: V = .{ 0, 0, 0 };
pub var src_vol: f64 = 0;
pub var tol: f64 = 0;
/// the mesh's directed edges with no opposite one (0: closed; -1: no memory)
pub var open_edges: i32 = 0;

fn freeSlice(comptime T: type, s: *[]T) void {
    if (s.len > 0) pa.free(s.*);
    s.* = &.{};
}

/// sh_src_free
pub fn srcFree() void {
    freeSlice(V, &src_p);
    freeSlice([3]u32, &src_t);
    freeSlice(Poly, &src_pp);
    freeSlice(u32, &src_pl);
    gridFree();
}

/// The triangles mesh_finish makes of polygons: fans, but a polygon of 4 to
/// 256 corners has its flat ears (three corners in a line) wait (ear_tris).
pub fn triangulate(a: Allocator, verts: []const [3]f32, poff: []const u32, loops: []const u32) ![][3]u32 {
    var tris: std.ArrayList([3]u32) = .empty;
    var c: [256]u32 = undefined;
    for (0..poff.len -| 1) |p| {
        const idx = loops[poff[p]..poff[p + 1]];
        if (idx.len < 4 or idx.len > 256) {
            var i: usize = 1;
            while (i + 1 < idx.len) : (i += 1) try tris.append(a, .{ idx[0], idx[i], idx[i + 1] });
            continue;
        }
        var n = idx.len;
        @memcpy(c[0..n], idx);
        var tip: usize = 1;
        var flats: usize = 0;
        while (n > 3 and flats < n) {
            if (tip >= n) tip = 0;
            const pv = (tip + n - 1) % n;
            const nx = (tip + 1) % n;
            if (flat3(verts, c[pv], c[tip], c[nx])) {
                tip += 1;
                flats += 1;
                continue;
            }
            try tris.append(a, .{ c[pv], c[tip], c[nx] });
            std.mem.copyForwards(u32, c[tip .. n - 1], c[tip + 1 .. n]);
            n -= 1;
            flats = 0;
        }
        var i: usize = 1;
        while (i + 1 < n) : (i += 1) try tris.append(a, .{ c[0], c[i], c[i + 1] });
    }
    return tris.toOwnedSlice(a);
}

fn flat3(verts: []const [3]f32, ai: u32, bi: u32, ci: u32) bool {
    const a = verts[ai];
    const b = verts[bi];
    const cc = verts[ci];
    const u = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const w = [3]f32{ cc[0] - a[0], cc[1] - a[1], cc[2] - a[2] };
    var x = u[1] * w[2] - u[2] * w[1];
    x *= x;
    var y = u[2] * w[0] - u[0] * w[2];
    y *= y;
    var z = u[0] * w[1] - u[1] * w[0];
    z *= z;
    const l = x + y + z;
    const uu = u[0] * u[0] + u[1] * u[1] + u[2] * u[2];
    const ww = w[0] * w[0] + w[1] * w[1] + w[2] * w[2];
    const r = uu * ww * 1.0e-10;
    return !(l > r);
}

/// sh_src_set: the mesh (float vertices, its triangles) in doubles, its
/// bounds, volume, the tolerance; open_edges. False: no memory.
pub fn srcSet(verts: []const [3]f32, tris: []const [3]u32) bool {
    srcFree();
    src_p = pa.alloc(V, verts.len) catch return failSrc();
    src_t = pa.alloc([3]u32, tris.len) catch return failSrc();
    var mn = V{ BIG, BIG, BIG };
    var mx = V{ -BIG, -BIG, -BIG };
    for (verts, 0..) |v, i| {
        const d = V{ v[0], v[1], v[2] };
        src_p[i] = d;
        for (0..3) |k| {
            mn[k] = minsd(mn[k], d[k]);
            mx[k] = maxsd(mx[k], d[k]);
        }
    }
    src_min = mn;
    src_max = mx;
    var s = maxsd(mx[0] - mn[0], mx[1] - mn[1]);
    s = maxsd(s, mx[2] - mn[2]);
    tol = maxsd(s * 1.0e-9, TINY);
    @memcpy(src_t, tris);
    src_pp = pa.alloc(Poly, tris.len) catch return failSrc();
    src_pl = pa.alloc(u32, tris.len * 3) catch return failSrc();
    for (src_pp, 0..) |*p, i| p.* = .{ .first = @intCast(i * 3), .cnt = 3, .tag = 0 };
    var vol = triVolume(src_p, src_t);
    if (!(vol >= 0)) {
        vol = 0 - vol;
        for (src_t) |*t| std.mem.swap(u32, &t[1], &t[2]);
    }
    src_vol = vol;
    for (src_t, 0..) |t, i| @memcpy(src_pl[i * 3 ..][0..3], &t);
    open_edges = trisOpen(src_t);
    return true;
}

fn failSrc() bool {
    srcFree();
    return false;
}

/// tri_volume: signed tetrahedra from the first triangle's first vertex.
fn triVolume(p: []const V, t: []const [3]u32) f64 {
    if (t.len == 0) return 0;
    const o = p[t[0][0]];
    var s: f64 = 0;
    for (t) |tr| s = s + tet6(p[tr[0]], p[tr[1]], p[tr[2]], o);
    return s * 0.16666666666666666;
}

/// tet6: six times the tetrahedron's signed volume, a . (b x c) from o.
fn tet6(pa_: V, pb: V, pc: V, o: V) f64 {
    const x1 = pa_[0] - o[0];
    const x2 = pa_[1] - o[1];
    const x3 = pa_[2] - o[2];
    const x4 = pb[0] - o[0];
    const x5 = pb[1] - o[1];
    const x6 = pb[2] - o[2];
    const x7 = pc[0] - o[0];
    const x8 = pc[1] - o[1];
    const x9 = pc[2] - o[2];
    var r = (x5 * x9 - x6 * x8) * x1;
    r = r + (x6 * x7 - x4 * x9) * x2;
    r = r + (x4 * x8 - x5 * x7) * x3;
    return r;
}

/// tris_open: directed edges (each once) with no opposite one.
fn trisOpen(t: []const [3]u32) i32 {
    var set = std.AutoHashMap(u64, void).init(@import("alloc.zig").A);
    defer set.deinit();
    for (t) |tr| {
        for (0..3) |k| set.put(key(tr[k], tr[(k + 1) % 3]), {}) catch return -1;
    }
    var n: i32 = 0;
    var it = set.keyIterator();
    while (it.next()) |kp| {
        const k = kp.*;
        if (!set.contains((k << 32) | (k >> 32))) n += 1;
    }
    return n;
}

fn key(a: u32, b: u32) u64 {
    return (@as(u64, a) << 32) | b;
}

/// polys_open: a piece's polygons (counts) and loops: directed edges with no
/// opposite one.
pub fn polysOpen(cnts: []const u32, loops: []const u32) i32 {
    var set = std.AutoHashMap(u64, void).init(@import("alloc.zig").A);
    defer set.deinit();
    var f: usize = 0;
    for (cnts) |c| {
        for (0..c) |k| set.put(key(loops[f + k], loops[f + (k + 1) % c]), {}) catch return -1;
        f += c;
    }
    var n: i32 = 0;
    var it = set.keyIterator();
    while (it.next()) |kp| {
        const k = kp.*;
        if (!set.contains((k << 32) | (k >> 32))) n += 1;
    }
    return n;
}

// ---- distance and inside -----------------------------------------------------------------

inline fn dot3d(a: V, b: V) f64 {
    return (a[0] * b[0] + a[1] * b[1]) + a[2] * b[2];
}

/// sh_dist2: the squared distance from p to the source's surface.
pub fn dist2(p: V) f64 {
    var best = BIG;
    for (src_t) |t| best = minsd(best, ptTri2(p, src_p[t[0]], src_p[t[1]], src_p[t[2]]));
    return best;
}

/// pt_tri2: the squared distance from p to the triangle (Ericson).
fn ptTri2(p: V, a: V, b: V, c: V) f64 {
    const ab = V{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const ac = V{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    const ap = V{ p[0] - a[0], p[1] - a[1], p[2] - a[2] };
    const d1 = dot3d(ab, ap);
    const d2 = dot3d(ac, ap);
    var q: V = undefined;
    blk: {
        if (!(d1 > 0) and !(d2 > 0)) {
            q = a;
            break :blk;
        }
        const bp = V{ p[0] - b[0], p[1] - b[1], p[2] - b[2] };
        const d3 = dot3d(ab, bp);
        const d4 = dot3d(ac, bp);
        if (d3 >= 0 and !(d4 > d3)) {
            q = b;
            break :blk;
        }
        const vc = d1 * d4 - d3 * d2;
        var v: f64 = undefined;
        var w: f64 = undefined;
        if (!(vc > 0) and d1 >= 0 and !(d3 > 0)) {
            v = d1 / (d1 - d3);
            w = 0;
        } else {
            const cp = V{ p[0] - c[0], p[1] - c[1], p[2] - c[2] };
            const d5 = dot3d(ab, cp);
            const d6 = dot3d(ac, cp);
            if (d6 >= 0 and !(d5 > d6)) {
                q = c;
                break :blk;
            }
            const vb = d5 * d2 - d1 * d6;
            if (!(vb > 0) and d2 >= 0 and !(d6 > 0)) {
                w = d2 / (d2 - d6);
                v = 0;
            } else {
                const va = d3 * d6 - d5 * d4;
                const e1 = d4 - d3;
                const e2 = d5 - d6;
                if (!(va > 0) and e1 >= 0 and e2 >= 0) {
                    w = e1 / (e2 + e1);
                    v = 1.0 - w;
                } else {
                    const den = maxsd((va + vb) + vc, TINY);
                    v = vb / den;
                    w = vc / den;
                }
            }
        }
        for (0..3) |k| q[k] = (ab[k] * v + ac[k] * w) + a[k];
    }
    const x = q[0] - p[0];
    const y = q[1] - p[1];
    const z = q[2] - p[2];
    return (x * x + y * y) + z * z;
}

// the inside test's grid
var sg_uv: [][2]f64 = &.{};
var sg_start: []u32 = &.{};
var sg_idx: []u32 = &.{};
var sg_g: u32 = 0;
var sg_u0: f64 = 0;
var sg_v0: f64 = 0;
var sg_iu: f64 = 0;
var sg_iv: f64 = 0;

fn gridFree() void {
    freeSlice([2]f64, &sg_uv);
    freeSlice(u32, &sg_start);
    freeSlice(u32, &sg_idx);
}

fn rayUv(p: V) [2]f64 {
    const u = p[0] * RAYU[0] + p[1] * RAYU[1];
    const v = (p[0] * RAYV[0] + p[1] * RAYV[1]) + p[2] * RAYV[2];
    return .{ u, v };
}

/// sh_inside_prep: the grid sh_inside looks through (once a source; before
/// the threads use it). Small meshes: none.
pub fn insidePrep() void {
    if (sg_start.len != 0) return;
    if (src_t.len < 256) return;
    sg_uv = pa.alloc([2]f64, src_p.len) catch return;
    var ua = BIG;
    var va_ = BIG;
    var ub = -BIG;
    var vb_ = -BIG;
    for (src_p, 0..) |p, i| {
        const uv = rayUv(p);
        sg_uv[i] = uv;
        ua = minsd(ua, uv[0]);
        ub = maxsd(ub, uv[0]);
        va_ = minsd(va_, uv[1]);
        vb_ = maxsd(vb_, uv[1]);
    }
    var eps = maxsd(ub - ua, vb_ - va_);
    eps = maxsd(eps * 1.0e-7, TINY);
    ua -= eps;
    va_ -= eps;
    ub += eps;
    vb_ += eps;
    sg_u0 = ua;
    sg_v0 = va_;
    var g: i32 = cvtt(@sqrt(@as(f64, @floatFromInt(src_t.len))) * 0.7);
    if (g > 1024) g = 1024; // (unsigned compares in the original: the count is small)
    if (g < 4) g = 4;
    sg_g = @intCast(g);
    const gf: f64 = @floatFromInt(sg_g);
    sg_iu = gf / (ub - ua);
    sg_iv = gf / (vb_ - va_);
    sg_start = pa.alloc(u32, sg_g * sg_g + 2) catch return gridFail();
    @memset(sg_start, 0);
    gridPass(false, eps);
    const nc = sg_g * sg_g;
    for (0..nc) |c| sg_start[c + 1] += sg_start[c];
    sg_start[nc + 1] = sg_start[nc];
    sg_idx = pa.alloc(u32, sg_start[nc] + 1) catch return gridFail();
    gridPass(true, eps);
}

fn gridFail() void {
    freeSlice(u32, &sg_start);
}

/// sg_pass: each triangle into the squares its bounds cover (count, then fill
/// from the ends down).
fn gridPass(fill: bool, eps: f64) void {
    const gm: i32 = @as(i32, @intCast(sg_g)) - 1;
    for (src_t, 0..) |t, ti| {
        var a0 = sg_uv[t[0]][0];
        var a1 = a0;
        var b0 = sg_uv[t[0]][1];
        var b1 = b0;
        for (1..3) |k| {
            const uv = sg_uv[t[k]];
            a0 = minsd(a0, uv[0]);
            a1 = maxsd(a1, uv[0]);
            b0 = minsd(b0, uv[1]);
            b1 = maxsd(b1, uv[1]);
        }
        a0 = (a0 - eps - sg_u0) * sg_iu;
        a1 = (a1 + eps - sg_u0) * sg_iu;
        b0 = (b0 - eps - sg_v0) * sg_iv;
        b1 = (b1 + eps - sg_v0) * sg_iv;
        a0 = maxsd(a0, 0);
        b0 = maxsd(b0, 0);
        var ia = cvtt(a0);
        var ib = cvtt(a1);
        var ja = cvtt(b0);
        var jb = cvtt(b1);
        if (ia > gm) ia = gm;
        if (ib > gm) ib = gm;
        if (ja > gm) ja = gm;
        if (jb > gm) jb = gm;
        if (ib < 0) ib = 0;
        if (jb < 0) jb = 0;
        var j = ja;
        while (j <= jb) : (j += 1) {
            var i = ia;
            while (i <= ib) : (i += 1) {
                const c: usize = @intCast(j * @as(i32, @intCast(sg_g)) + i);
                if (!fill) {
                    sg_start[c + 1] += 1;
                } else {
                    sg_start[c + 1] -= 1;
                    sg_idx[sg_start[c + 1]] = @intCast(ti);
                }
            }
        }
    }
}

/// sh_inside: p inside the source (a ray's crossings, odd).
pub fn inside(p: V) bool {
    var hits: u32 = 0;
    if (sg_start.len != 0) {
        const uv = rayUv(p);
        const cu = (uv[0] - sg_u0) * sg_iu;
        const cv = (uv[1] - sg_v0) * sg_iv;
        if (!(cu >= 0) or !(cv >= 0)) return false;
        const iu: u32 = @bitCast(cvtt(cu));
        const iv: u32 = @bitCast(cvtt(cv));
        if (iu >= sg_g or iv >= sg_g) return false;
        const c = iv *% sg_g +% iu;
        for (sg_idx[sg_start[c + 1]..sg_start[c + 2]]) |ti| hits += crosses(p, src_t[ti]);
    } else {
        for (src_t) |t| hits += crosses(p, t);
    }
    return hits & 1 != 0;
}

/// Moller-Trumbore along RAY: 1 when it crosses the triangle ahead.
fn crosses(o: V, t: [3]u32) u32 {
    const a = src_p[t[0]];
    const b = src_p[t[1]];
    const c = src_p[t[2]];
    const e1 = V{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const e2 = V{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    const px = RAY[1] * e2[2] - RAY[2] * e2[1];
    const py = RAY[2] * e2[0] - RAY[0] * e2[2];
    const pz = RAY[0] * e2[1] - RAY[1] * e2[0];
    const det = (e1[0] * px + e1[1] * py) + e1[2] * pz;
    if (!(@abs(det) > TINY)) return 0;
    const tx = o[0] - a[0];
    const ty = o[1] - a[1];
    const tz = o[2] - a[2];
    const u = ((tx * px + ty * py) + tz * pz) / det;
    if (!(u >= 0) or u > 1) return 0;
    const qx = ty * e1[2] - tz * e1[1];
    const qy = tz * e1[0] - tx * e1[2];
    const qz = tx * e1[1] - ty * e1[0];
    const v = ((RAY[0] * qx + RAY[1] * qy) + RAY[2] * qz) / det;
    if (!(v >= 0)) return 0;
    if (v + u > 1) return 0;
    const tt = ((e2[0] * qx + e2[1] * qy) + e2[2] * qz) / det;
    if (!(tt > 0)) return 0;
    return 1;
}

// ---- a cut ------------------------------------------------------------------------------

const Cut = struct {
    a: Allocator, // its arena (reset each item)
    r: Allocator, // the thread's results (kept until the next cut)
    v: []V,
    p: []Poly,
    l: []u32,
    fail: bool = false,

    fn alloc(c: *Cut, comptime T: type, n: usize) ?[]T {
        return c.a.alloc(T, n) catch {
            c.fail = true;
            return null;
        };
    }
};

/// clip_plane's frame
const CF = struct {
    pl: *const Plane,
    s: []f64,
    cl: []u8,
    rm: []u32,
    vo: []V,
    onp: []u8,
    po: []Poly,
    lo: []u32,
    ek: std.AutoHashMap(u64, u32),
    nvo: u32 = 0,
    npo: u32 = 0,
    nlo: u32 = 0,
    capp: u32 = 0,
    capl: u32 = 0,
    vin: []V,
    pin: []Poly,
    lin: []u32,

    fn put(f: *CF, v: u32) void {
        if (f.nlo >= f.capl) return;
        f.lo[f.nlo] = v;
        f.nlo += 1;
    }
    fn mask(f: *CF, p: Poly) u32 {
        var m: u32 = 0;
        for (f.lin[p.first..][0..p.cnt]) |v| m |= @as(u32, 1) << @intCast(f.cl[v]);
        return m;
    }
    fn vert(f: *CF, old: u32) u32 {
        if (f.rm[old] != 0xffffffff) return f.rm[old];
        const n = f.nvo;
        f.rm[old] = n;
        f.nvo += 1;
        f.vo[n] = f.vin[old];
        f.onp[n] = @intFromBool(f.cl[old] == CL_ON);
        return n;
    }
    fn cut(f: *CF, c: *Cut, ia: u32, ja: u32) u32 {
        const lo_ = @min(ia, ja);
        const hi = @max(ia, ja);
        const g = f.ek.getOrPut(key(lo_, hi)) catch {
            c.fail = true;
            return 0;
        };
        if (g.found_existing) return g.value_ptr.*;
        const n = f.nvo;
        f.nvo += 1;
        g.value_ptr.* = n;
        f.onp[n] = 1;
        const sl = f.s[lo_];
        const t = sl / (sl - f.s[hi]);
        const a = f.vin[lo_];
        const b = f.vin[hi];
        for (0..3) |k| f.vo[n][k] = (b[k] - a[k]) * t + a[k];
        return n;
    }
};

fn hpow(n: u32) u32 {
    var c: u32 = 16;
    const t = n *% 2;
    while (c < t) c *%= 2;
    return c;
}

/// clip_plane: the cut's solid on the plane's inner side, closed again.
fn clipPlane(c: *Cut, pl: *const Plane) void {
    const nvin: u32 = @intCast(c.v.len);
    if (c.p.len == 0) return;
    const s = c.alloc(f64, nvin) orelse return;
    const cl = c.alloc(u8, nvin) orelse return;
    var nin: u32 = 0;
    var nout: u32 = 0;
    const ntol = 0 - tol;
    for (c.v, 0..) |v, i| {
        const d = ((v[0] * pl.n[0] + v[1] * pl.n[1]) + v[2] * pl.n[2]) - pl.d;
        s[i] = d;
        if (d > tol) {
            cl[i] = CL_OUT;
            nout += 1;
        } else if (!(d >= ntol)) {
            cl[i] = CL_IN;
            nin += 1;
        } else cl[i] = CL_ON;
    }
    if (nout == 0) return;
    if (nin == 0) {
        c.v = c.v[0..0];
        c.p = c.p[0..0];
        c.l = c.l[0..0];
        return;
    }
    var f = CF{ .pl = pl, .s = s, .cl = cl, .rm = &.{}, .vo = &.{}, .onp = &.{}, .po = &.{}, .lo = &.{}, .ek = std.AutoHashMap(u64, u32).init(c.a), .vin = c.v, .pin = c.p, .lin = c.l };
    var nstr: u32 = 0;
    var nkeep: u32 = 0;
    var lsum: u32 = 0;
    var bsum: u32 = 0;
    for (c.p) |p| {
        const m = f.mask(p);
        if (m & 4 == 0) {
            nkeep += 1;
            lsum += p.cnt;
            if (m & 2 != 0) bsum += p.cnt;
        } else if (m & 1 != 0) {
            nstr += 1;
            lsum += p.cnt + 2;
            bsum += p.cnt + 2;
        }
    }
    f.rm = c.alloc(u32, nvin) orelse return;
    @memset(f.rm, 0xffffffff);
    const nvo_cap = nstr * 2 + nvin + 8;
    f.vo = c.alloc(V, nvo_cap) orelse return;
    f.onp = c.alloc(u8, nvo_cap) orelse return;
    f.capp = bsum * 3 + 16 + nkeep + nstr;
    f.po = c.alloc(Poly, f.capp) orelse return;
    f.capl = bsum * 9 + lsum + 64;
    f.lo = c.alloc(u32, f.capl) orelse return;
    f.ek.ensureTotalCapacity(nstr * 2 + 16) catch {
        c.fail = true;
        return;
    };
    for (c.p) |p| {
        const m = f.mask(p);
        const start = f.nlo;
        if (m & 4 == 0) {
            for (f.lin[p.first..][0..p.cnt]) |v| f.put(f.vert(v));
        } else if (m & 1 != 0) {
            for (0..p.cnt) |k| {
                const i = f.lin[p.first + k];
                const j = f.lin[p.first + (k + 1) % p.cnt];
                const ci = cl[i];
                const cj = cl[j];
                if (ci != CL_OUT) f.put(f.vert(i));
                if (ci + cj == CL_OUT and ci != CL_ON) f.put(f.cut(c, i, j));
            }
        } else continue;
        const cnt = f.nlo - start;
        if (cnt < 3) {
            f.nlo = start;
            continue;
        }
        if (f.npo >= f.capp) continue;
        f.po[f.npo] = .{ .first = start, .cnt = cnt, .tag = p.tag };
        f.npo += 1;
    }
    if (c.fail) return;
    c.v = f.vo[0..f.nvo];
    capBuild(c, &f);
    c.p = f.po[0..f.npo];
    c.l = f.lo[0..f.nlo];
}

// ---- the cap ----------------------------------------------------------------------------

const CB = struct {
    be: [][2]u32,
    nb: u32 = 0,
    enx: []i32 = &.{},
    used: []u8 = &.{},
    rid: []u32 = &.{},
    rx: []f64 = &.{},
    ry: []f64 = &.{},
    nxt: []u32 = &.{},
    prv: []u32 = &.{},
    nr: u32 = 0,
    nl: u32 = 0,
    lst: []u32 = &.{},
    lcn: []u32 = &.{},
    lar: []f64 = &.{},
    lout: []i32 = &.{},
    lmx: []u32 = &.{},
    u: V = .{ 0, 0, 0 },
    w: V = .{ 0, 0, 0 },
    mark: []u32 = &.{},
    nref: u32 = 0,
    gh: ?[]i32 = null,
    gn: []i32 = &.{},
    gs: i32 = 0,
    gx: f64 = 0,
    gy: f64 = 0,
    gix: f64 = 0,
    giy: f64 = 0,
    nbr: u32 = 0,
    t0: u32 = 0,
    l0: u32 = 0,
    cf: *CF,
    cx: *Cut,
};

/// cap_build: the edges of the new polygons that lie in the plane and have no
/// twin, chained into loops and filled.
fn capBuild(c: *Cut, f: *CF) void {
    var n: u32 = 0;
    for (f.po[0..f.npo]) |p| {
        const l = f.lo[p.first..][0..p.cnt];
        var prev = f.onp[l[p.cnt - 1]];
        for (l) |v| {
            const o = f.onp[v];
            n += prev & o;
            prev = o;
        }
    }
    if (n == 0) return;
    var set = std.AutoHashMap(u64, void).init(c.a);
    set.ensureTotalCapacity(n) catch {
        c.fail = true;
        return;
    };
    const be = c.alloc([2]u32, n) orelse return;
    var k: usize = 0;
    for (f.po[0..f.npo]) |p| {
        for (0..p.cnt) |q| {
            const u = f.lo[p.first + q];
            const v = f.lo[p.first + (q + 1) % p.cnt];
            if (f.onp[u] == 0 or f.onp[v] == 0) continue;
            be[k] = .{ u, v };
            k += 1;
            set.putAssumeCapacity(key(u, v), {});
        }
    }
    var nb: u32 = 0;
    for (0..n) |i| {
        const e = be[i];
        if (set.contains(key(e[1], e[0]))) continue;
        be[nb] = .{ e[1], e[0] };
        nb += 1;
    }
    var cb = CB{ .be = be, .nb = nb, .cf = f, .cx = c };
    if (nb < 3) return;
    if (!cbLoops(&cb)) return;
    cbFill(&cb);
}

fn cbLoops(cb: *CB) bool {
    const c = cb.cx;
    var head = std.AutoHashMap(u32, i32).init(c.a);
    head.ensureTotalCapacity(cb.nb) catch return false;
    cb.enx = c.alloc(i32, cb.nb) orelse return false;
    cb.used = c.alloc(u8, cb.nb) orelse return false;
    @memset(cb.used, 0);
    const rcap = cb.nb * 3 + 16;
    cb.rid = c.alloc(u32, rcap) orelse return false;
    cb.rx = c.alloc(f64, rcap) orelse return false;
    cb.ry = c.alloc(f64, rcap) orelse return false;
    cb.nxt = c.alloc(u32, rcap) orelse return false;
    cb.prv = c.alloc(u32, rcap) orelse return false;
    cb.mark = c.alloc(u32, rcap) orelse return false;
    const lcap = cb.nb / 3 + 2;
    cb.lst = c.alloc(u32, lcap) orelse return false;
    cb.lcn = c.alloc(u32, lcap) orelse return false;
    cb.lar = c.alloc(f64, lcap) orelse return false;
    cb.lout = c.alloc(i32, lcap) orelse return false;
    cb.lmx = c.alloc(u32, lcap) orelse return false;
    for (0..cb.nb) |i| {
        const g = head.getOrPutAssumeCapacity(cb.be[i][0]);
        cb.enx[i] = if (g.found_existing) g.value_ptr.* else -1;
        g.value_ptr.* = @intCast(i);
    }
    cbAxes(cb);
    cb.nr = 0;
    cb.nl = 0;
    for (0..cb.nb) |e0| {
        if (cb.used[e0] != 0) continue;
        if (cb.nl >= lcap) break;
        const first = cb.nr;
        cb.lst[cb.nl] = first;
        const start = cb.be[e0][0];
        var e: usize = e0;
        while (true) {
            cb.used[e] = 1;
            cb.rid[cb.nr] = cb.be[e][0];
            cb.nr += 1;
            const to = cb.be[e][1];
            if (to == start) break;
            var x = head.get(to) orelse break;
            while (x != -1 and cb.used[@intCast(x)] != 0) x = cb.enx[@intCast(x)];
            if (x == -1) break;
            e = @intCast(x);
        }
        const cnt = cb.nr - first;
        if (cnt < 3) {
            cb.nr = first;
            continue;
        }
        cb.lcn[cb.nl] = cnt;
        cb.nl += 1;
        const last = first + cnt - 1;
        var r = first;
        while (r <= last) : (r += 1) {
            const nx = if (r == last) first else r + 1;
            cb.nxt[r] = nx;
            cb.prv[nx] = r;
        }
        r = first;
        while (r <= last) : (r += 1) {
            const p = cb.cf.vo[cb.rid[r]];
            cb.rx[r] = (p[0] * cb.u[0] + p[1] * cb.u[1]) + p[2] * cb.u[2];
            cb.ry[r] = (p[0] * cb.w[0] + p[1] * cb.w[1]) + p[2] * cb.w[2];
            cb.mark[r] = 0;
        }
    }
    for (0..cb.nl) |l| {
        const a = cbArea(cb, l);
        cb.lar[l] = a.area;
        cb.lmx[l] = a.mx;
        cb.lout[l] = -1;
    }
    return true;
}

/// cb_axes: u, w in the plane with u x w = n.
fn cbAxes(cb: *CB) void {
    const n = cb.cf.pl.n;
    var a = V{ 1, 0, 0 };
    if (@abs(n[0]) >= 0.6) a = .{ 0, 1, 0 };
    const d = n[0] * a[0] + n[1] * a[1];
    var u = V{ a[0] - n[0] * d, a[1] - n[1] * d, a[2] - n[2] * d };
    const len = @sqrt((u[0] * u[0] + u[1] * u[1]) + u[2] * u[2]);
    const inv = 1.0 / len;
    u = .{ u[0] * inv, u[1] * inv, u[2] * inv };
    cb.u = u;
    cb.w = .{ n[1] * u[2] - n[2] * u[1], n[2] * u[0] - n[0] * u[2], n[0] * u[1] - n[1] * u[0] };
}

fn cbArea(cb: *CB, l: usize) struct { area: f64, mx: u32 } {
    const first = cb.lst[l];
    var s: f64 = 0;
    var mx = first;
    var xm = cb.rx[first];
    var i = first;
    while (true) {
        const j = cb.nxt[i];
        s = s + (cb.rx[i] * cb.ry[j] - cb.rx[j] * cb.ry[i]);
        if (cb.rx[i] > xm) {
            xm = cb.rx[i];
            mx = i;
        }
        i = j;
        if (i == first) break;
    }
    return .{ .area = s * 0.5, .mx = mx };
}

fn cbFill(cb: *CB) void {
    for (0..cb.nl) |l| {
        if (!(cb.lar[l] >= 0)) cb.lout[l] = cbOuterOf(cb, l);
    }
    for (0..cb.nl) |l| {
        if (!(cb.lar[l] >= 0)) {
            if (cb.lout[l] != -1) continue;
            cb.nbr = 1;
        } else {
            cb.nbr = 0;
            while (cbNextHole(cb, @intCast(l))) |h| {
                cb.lout[h] = -2;
                cbBridge(cb, @intCast(l), h);
                cb.nbr += 1;
            }
        }
        cbClip(cb, cb.lst[l]);
    }
}

fn cbOuterOf(cb: *CB, hole: usize) i32 {
    const m = cb.lmx[hole];
    const x = cb.rx[m];
    const y = cb.ry[m];
    var best: i32 = -1;
    var largest: i32 = -1;
    var best_a = BIG;
    var large_a: f64 = 0;
    for (0..cb.nl) |k| {
        const a = cb.lar[k];
        if (!(a >= 0)) continue;
        if (a > large_a) {
            large_a = a;
            largest = @intCast(k);
        }
        if (a >= best_a) continue;
        if (!cbPip(cb, k, x, y)) continue;
        best_a = a;
        best = @intCast(k);
    }
    return if (best != -1) best else largest;
}

fn cbPip(cb: *CB, l: usize, x: f64, y: f64) bool {
    const first = cb.lst[l];
    var in = false;
    var i = first;
    while (true) {
        const j = cb.nxt[i];
        const yi = cb.ry[i];
        const yj = cb.ry[j];
        if ((yi > y) != (yj > y)) {
            const xi = ((y - yi) * (cb.rx[j] - cb.rx[i])) / (yj - yi) + cb.rx[i];
            if (xi > x) in = !in;
        }
        i = j;
        if (i == first) break;
    }
    return in;
}

fn cbNextHole(cb: *CB, outer: i32) ?u32 {
    var best: ?u32 = null;
    var bx = 0 - BIG;
    for (0..cb.nl) |k| {
        if (cb.lout[k] != outer) continue;
        const x = cb.rx[cb.lmx[k]];
        if (x > bx) {
            bx = x;
            best = @intCast(k);
        }
    }
    return best;
}

fn cbBridge(cb: *CB, outer: u32, hole: u32) void {
    const m = cb.lmx[hole];
    const mx = cb.rx[m];
    const my = cb.ry[m];
    const b0 = cb.lst[outer];
    var e = b0;
    while (true) {
        cb.mark[e] = 0;
        e = cb.nxt[e];
        if (e == b0) break;
    }
    var p_any: i64 = -1;
    while (true) {
        var near: i64 = -1;
        var bd = BIG;
        e = b0;
        while (true) {
            if (cb.mark[e] == 0) {
                const dx = cb.rx[e] - mx;
                const dy = cb.ry[e] - my;
                const d = dx * dx + dy * dy;
                if (d < bd) {
                    bd = d;
                    near = e;
                }
            }
            e = cb.nxt[e];
            if (e == b0) break;
        }
        if (near == -1) break;
        const nu: u32 = @intCast(near);
        if (p_any == -1) p_any = near;
        cb.mark[nu] = 1;
        if (cbSees(cb, nu, m, outer, hole)) {
            p_any = near;
            break;
        }
    }
    if (p_any == -1) return;
    const a: u32 = @intCast(p_any);
    const a2 = cb.nr;
    const b2 = cb.nr + 1;
    cb.nr += 2;
    cbDup(cb, a, a2);
    cbDup(cb, m, b2);
    const an = cb.nxt[a];
    const bp = cb.prv[m];
    cb.nxt[a] = m;
    cb.prv[m] = a;
    cb.nxt[a2] = an;
    cb.prv[an] = a2;
    cb.nxt[b2] = a2;
    cb.prv[a2] = b2;
    cb.nxt[bp] = b2;
    cb.prv[b2] = bp;
}

fn cbDup(cb: *CB, e: u32, n: u32) void {
    cb.rid[n] = cb.rid[e];
    cb.rx[n] = cb.rx[e];
    cb.ry[n] = cb.ry[e];
    cb.mark[n] = 1;
}

fn cbSees(cb: *CB, p: u32, m: u32, outer: u32, hole: u32) bool {
    if (cbRingHits(cb, cb.lst[outer], p, m)) return false;
    for (0..cb.nl) |k| {
        if (k == hole or cb.lout[k] == @as(i32, @intCast(outer))) {
            if (cbRingHits(cb, cb.lst[k], p, m)) return false;
        }
    }
    return true;
}

inline fn same(cb: *CB, a: u32, b: u32) bool {
    return cb.rx[a] == cb.rx[b] and cb.ry[a] == cb.ry[b];
}

fn cbRingHits(cb: *CB, start: u32, p: u32, m: u32) bool {
    var a = start;
    while (true) {
        const b = cb.nxt[a];
        if (!(same(cb, a, p) or same(cb, a, m) or same(cb, b, p) or same(cb, b, m))) {
            const o1 = orient2(cb.rx[p], cb.ry[p], cb.rx[m], cb.ry[m], cb.rx[a], cb.ry[a]);
            const o2 = orient2(cb.rx[p], cb.ry[p], cb.rx[m], cb.ry[m], cb.rx[b], cb.ry[b]);
            if (!(o1 * o2 >= 0)) {
                const o3 = orient2(cb.rx[a], cb.ry[a], cb.rx[b], cb.ry[b], cb.rx[p], cb.ry[p]);
                const o4 = orient2(cb.rx[a], cb.ry[a], cb.rx[b], cb.ry[b], cb.rx[m], cb.ry[m]);
                if (!(o3 * o4 >= 0)) return true;
            }
        }
        a = b;
        if (a == start) break;
    }
    return false;
}

/// (b - a) x (c - a)
inline fn orient2(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64) f64 {
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
}

/// orient2f: the corner straight (its sine under 1e-6)?
fn straight(ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64, o: f64) bool {
    var p = (bx - ax) * (bx - ax);
    p = p + (by - ay) * (by - ay);
    var q = (cx - bx) * (cx - bx);
    q = q + (cy - by) * (cy - by);
    const r = p * q * 1.0e-12;
    return !(o * o > r);
}

fn cbClip(cb: *CB, start0: u32) void {
    var b = start0;
    var cnt: u32 = 0;
    cb.nref = 0;
    var e = start0;
    while (true) {
        cnt += 1;
        const r = cbReflex(cb, e);
        cb.mark[e] = r;
        cb.nref += r;
        e = cb.nxt[e];
        if (e == start0) break;
    }
    if (cb.nref == 0 and cb.nbr == 0) {
        cbEmitRing(cb, start0);
        return;
    }
    cb.t0 = cb.cf.npo;
    cb.l0 = cb.cf.nlo;
    cbGrid(cb, start0);
    var tried: u32 = 0;
    while (cnt > 3) {
        if (!cbIsEar(cb, b)) {
            tried += 1;
            if (tried <= cnt) {
                b = cb.nxt[b];
                continue;
            }
        }
        cbEmit(cb, b);
        const a = cb.prv[b];
        const c = cb.nxt[b];
        cb.nxt[a] = c;
        cb.prv[c] = a;
        cb.nref -= cb.mark[b];
        cb.mark[b] = 0;
        b = c;
        cbReflag(cb, a);
        cbReflag(cb, b);
        cnt -= 1;
        tried = 0;
    }
    if (cnt == 3) cbEmit(cb, b);
    cbMerge(cb);
}

fn cbReflex(cb: *CB, e: u32) u32 {
    const a = cb.prv[e];
    const c = cb.nxt[e];
    const o = orient2(cb.rx[a], cb.ry[a], cb.rx[e], cb.ry[e], cb.rx[c], cb.ry[c]);
    if (o >= 0) return 0;
    var d = (cb.rx[c] - cb.rx[a]) * (cb.rx[c] - cb.rx[a]);
    d = d + (cb.ry[c] - cb.ry[a]) * (cb.ry[c] - cb.ry[a]);
    var k = tol * 100.0;
    k = k * k;
    d = d * k;
    return @intFromBool(o * o > d);
}

fn cbReflag(cb: *CB, e: u32) void {
    const r = cbReflex(cb, e);
    const dlt = r -% cb.mark[e];
    cb.nref +%= dlt;
    cb.mark[e] +%= dlt;
}

fn cbGrid(cb: *CB, start: u32) void {
    cb.gh = null;
    if (cb.nref == 0) return;
    const c = cb.cx;
    var x0 = cb.rx[start];
    var y0 = cb.ry[start];
    var x1 = x0;
    var y1 = y0;
    var e = start;
    while (true) {
        x0 = minsd(x0, cb.rx[e]);
        x1 = maxsd(x1, cb.rx[e]);
        y0 = minsd(y0, cb.ry[e]);
        y1 = maxsd(y1, cb.ry[e]);
        e = cb.nxt[e];
        if (e == start) break;
    }
    cb.gx = x0;
    cb.gy = y0;
    var gs = cvtt(@sqrt(@as(f64, @floatFromInt(cb.nref)))) +% 1;
    if (@as(u32, @bitCast(gs)) > 1024) gs = 1024;
    cb.gs = gs;
    const gf: f64 = @floatFromInt(gs);
    const sx = maxsd(x1 - x0, TINY);
    const sy = maxsd(y1 - y0, TINY);
    const f = gf * 0.999999;
    cb.gix = f / sx;
    cb.giy = f / sy;
    const nc: usize = @intCast(gs * gs);
    const heads = c.alloc(i32, nc) orelse return;
    @memset(heads, -1);
    cb.gn = c.alloc(i32, cb.nr) orelse return;
    cb.gh = heads;
    e = start;
    while (true) {
        if (cb.mark[e] != 0) {
            const cell = cbCell(cb, cb.rx[e], cb.ry[e]);
            cb.gn[e] = heads[cell];
            heads[cell] = @intCast(e);
        }
        e = cb.nxt[e];
        if (e == start) break;
    }
}

fn cbCxy(cb: *CB, x: f64, y: f64) [2]i32 {
    var col = cvtt((x - cb.gx) * cb.gix);
    var row = cvtt((y - cb.gy) * cb.giy);
    const m = cb.gs - 1;
    if (col < 0) col = 0;
    if (col > m) col = m;
    if (row < 0) row = 0;
    if (row > m) row = m;
    return .{ col, row };
}

fn cbCell(cb: *CB, x: f64, y: f64) usize {
    const r = cbCxy(cb, x, y);
    return @intCast(r[1] * cb.gs + r[0]);
}

fn cbIsEar(cb: *CB, b: u32) bool {
    const a = cb.prv[b];
    const c = cb.nxt[b];
    const rx = cb.rx;
    const ry = cb.ry;
    const o = orient2(rx[a], ry[a], rx[b], ry[b], rx[c], ry[c]);
    if (straight(rx[a], ry[a], rx[b], ry[b], rx[c], ry[c], o)) return false;
    if (!(o > 0)) return false;
    if (cb.nref == 0) return true;
    const heads = cb.gh orelse return true;
    const lo = cbCxy(cb, minsd(minsd(rx[a], rx[b]), rx[c]), minsd(minsd(ry[a], ry[b]), ry[c]));
    const hi = cbCxy(cb, maxsd(maxsd(rx[a], rx[b]), rx[c]), maxsd(maxsd(ry[a], ry[b]), ry[c]));
    var row = lo[1];
    while (row <= hi[1]) : (row += 1) {
        var col = lo[0];
        while (col <= hi[0]) : (col += 1) {
            var x = heads[@intCast(row * cb.gs + col)];
            while (x != -1) : (x = cb.gn[@intCast(x)]) {
                const e: u32 = @intCast(x);
                if (cb.mark[e] == 0 or e == a or e == b or e == c) continue;
                if (same(cb, e, a) or same(cb, e, b) or same(cb, e, c)) continue;
                if (!(orient2(rx[a], ry[a], rx[b], ry[b], rx[e], ry[e]) >= 0)) continue;
                if (!(orient2(rx[b], ry[b], rx[c], ry[c], rx[e], ry[e]) >= 0)) continue;
                if (orient2(rx[c], ry[c], rx[a], ry[a], rx[e], ry[e]) >= 0) return false;
            }
        }
    }
    return true;
}

fn cbEmit(cb: *CB, e: u32) void {
    const f = cb.cf;
    const ia = cb.rid[cb.prv[e]];
    const ib = cb.rid[e];
    const ic = cb.rid[cb.nxt[e]];
    if (ia == ib or ib == ic or ia == ic) return;
    if (f.npo >= f.capp) return;
    if (f.nlo + 3 > f.capl) return;
    f.po[f.npo] = .{ .first = f.nlo, .cnt = 3, .tag = f.pl.tag };
    f.npo += 1;
    f.lo[f.nlo] = ia;
    f.lo[f.nlo + 1] = ib;
    f.lo[f.nlo + 2] = ic;
    f.nlo += 3;
}

fn cbEmitRing(cb: *CB, start: u32) void {
    const f = cb.cf;
    if (f.npo >= f.capp) return;
    const first = f.nlo;
    var last: u32 = 0xffffffff;
    var e = start;
    while (true) {
        const id = cb.rid[e];
        if (id != last) {
            if (f.nlo >= f.capl) return;
            f.lo[f.nlo] = id;
            f.nlo += 1;
            last = id;
        }
        e = cb.nxt[e];
        if (e == start) break;
    }
    if (f.nlo -% 1 > first and f.lo[f.nlo - 1] == f.lo[first]) f.nlo -= 1;
    const cnt = f.nlo - first;
    if (cnt < 3) {
        f.nlo = first;
        return;
    }
    f.po[f.npo] = .{ .first = first, .cnt = cnt, .tag = f.pl.tag };
    f.npo += 1;
}

// ---- Hertel-Mehlhorn --------------------------------------------------------------------

const MG = struct {
    sv: []u32,
    sn: []u32,
    ts: []i32,
    edges: std.AutoHashMap(u64, u32),
    ns: u32 = 0,
    p: u32 = 0,
    cb: *CB,
};

fn cbMerge(cb: *CB) void {
    const f = cb.cf;
    const c = cb.cx;
    const nt = f.npo - cb.t0;
    if (nt < 2) return;
    const nslot = nt * 4 + 8;
    var g = MG{
        .sv = c.alloc(u32, nslot) orelse return,
        .sn = c.alloc(u32, nslot) orelse return,
        .ts = c.alloc(i32, nt) orelse return,
        .edges = std.AutoHashMap(u64, u32).init(c.a),
        .cb = cb,
    };
    g.edges.ensureTotalCapacity(nt * 3) catch {
        c.fail = true;
        return;
    };
    for (0..nt) |t| {
        const p = f.po[cb.t0 + t];
        const s0 = g.ns;
        g.ts[t] = @intCast(s0);
        for (0..3) |k| {
            g.sv[s0 + k] = f.lo[p.first + k];
            g.sn[s0 + k] = s0 + @as(u32, @intCast((k + 1) % 3));
        }
        g.ns += 3;
        for (0..3) |k| {
            const s = s0 + @as(u32, @intCast(k));
            const r = g.edges.getOrPutAssumeCapacity(key(g.sv[s], g.sv[g.sn[s]]));
            if (!r.found_existing) r.value_ptr.* = @intCast(t); // (the first one found)
        }
    }
    f.npo = cb.t0;
    f.nlo = cb.l0;
    for (0..nt) |t| {
        if (g.ts[t] == -1) continue;
        g.p = @intCast(g.ts[t]);
        g.ts[t] = -1;
        while (true) {
            var grown = false;
            var x = g.p;
            while (true) {
                const y = g.sn[x];
                if (mgTry(&g, x, y)) grown = true;
                x = g.sn[x];
                if (x == g.p) break;
            }
            if (!grown) break;
        }
        mgEmit(&g);
    }
}

fn mgTry(g: *MG, x: u32, y: u32) bool {
    const t = g.edges.get(key(g.sv[y], g.sv[x])) orelse return false;
    if (g.ts[t] == -1) return false;
    var cs: u32 = @intCast(g.ts[t]);
    const vx = g.sv[x];
    const vy = g.sv[y];
    var w: ?u32 = null;
    for (0..3) |_| {
        const v = g.sv[cs];
        if (v != vx and v != vy) {
            w = v;
            break;
        }
        cs = g.sn[cs];
    }
    const wv = w orelse return false;
    if (!mgConvex(g, x, wv, y)) return false;
    g.ts[t] = -1;
    const s = g.ns;
    g.ns += 1;
    g.sv[s] = wv;
    g.sn[s] = y;
    g.sn[x] = s;
    return true;
}

fn mgConvex(g: *MG, x: u32, w: u32, y: u32) bool {
    var p = x;
    while (g.sn[p] != x) p = g.sn[p];
    if (!mgTurn(g, g.sv[p], g.sv[x], w)) return false;
    if (!mgTurn(g, g.sv[x], w, g.sv[y])) return false;
    if (!mgTurn(g, w, g.sv[y], g.sv[g.sn[y]])) return false;
    return true;
}

fn mgXy(g: *MG, v: u32) [2]f64 {
    const p = g.cb.cf.vo[v];
    const u = g.cb.u;
    const w = g.cb.w;
    return .{ (p[0] * u[0] + p[1] * u[1]) + p[2] * u[2], (p[0] * w[0] + p[1] * w[1]) + p[2] * w[2] };
}

fn mgTurn(g: *MG, a: u32, b: u32, c: u32) bool {
    const pa_ = mgXy(g, a);
    const pb = mgXy(g, b);
    const pc = mgXy(g, c);
    const o = orient2(pa_[0], pa_[1], pb[0], pb[1], pc[0], pc[1]);
    if (o >= 0) return true;
    var d = (pc[0] - pa_[0]) * (pc[0] - pa_[0]);
    d = d + (pc[1] - pa_[1]) * (pc[1] - pa_[1]);
    var k = tol * 100.0;
    k = k * k;
    d = d * k;
    return !(o * o > d);
}

fn mgEmit(g: *MG) void {
    const f = g.cb.cf;
    if (f.npo >= f.capp) return;
    const first = f.nlo;
    var c = g.p;
    while (true) {
        if (f.nlo >= f.capl) return;
        f.lo[f.nlo] = g.sv[c];
        f.nlo += 1;
        c = g.sn[c];
        if (c == g.p) break;
    }
    f.po[f.npo] = .{ .first = first, .cnt = f.nlo - first, .tag = f.pl.tag };
    f.npo += 1;
}

// ---- cells, the tree, pieces ------------------------------------------------------------

/// What the patterns give: per cell its planes (CPL_MAX at most) and bounds.
pub var cpl: []Plane = &.{};
pub var cpn: []u32 = &.{};
pub var cbb: [][6]f64 = &.{};
pub var ncell: u32 = 0;
/// 0: planes per cell given (bricks), 1: Voronoi cells of the seeds
pub var mode: u32 = 0;
pub var seeds: []V = &.{};

/// sh_cells_alloc: room for n cells' planes and bounds (zeroed).
pub fn cellsAlloc(n: u32) bool {
    cellsFree();
    cpl = pa.alloc(Plane, @as(usize, n) * CPL_MAX) catch return failCells();
    cpn = pa.alloc(u32, n) catch return failCells();
    cbb = pa.alloc([6]f64, n) catch return failCells();
    @memset(cpn, 0);
    @memset(cbb, @splat(0));
    ncell = n;
    return true;
}
fn failCells() bool {
    cellsFree();
    return false;
}
pub fn cellsFree() void {
    freeSlice(Plane, &cpl);
    freeSlice(u32, &cpn);
    freeSlice([6]f64, &cbb);
    ncell = 0;
}

/// A piece: volume, centre (local, doubles), vertices from the centre,
/// polygons (corners, tag: 0 the surface, else the plane that made them).
pub const Piece = struct {
    vol: f64,
    c: V,
    verts: [][3]f32,
    cnt: []u32,
    tag: []u32,
    loops: []u32,
};

/// Per cell its pieces (in the results' arena), after cutAll.
pub var res: [][]Piece = &.{};
var res_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(pa);
/// The phases' ns: 1 cells, 2 tree, 3 levels, 4 cells from leaves.
pub var cnt_ns: [8]u64 = @splat(0);
var tlap: u64 = 0;

fn lap(slot: usize) void {
    const t: u64 = @intCast(nowNs());
    if (slot != 0) cnt_ns[slot] = t -% tlap;
    tlap = t;
}

pub fn nowNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000000000 + ts.nsec;
}

pub fn resFree() void {
    res = &.{};
    _ = res_arena.reset(.free_all);
}

const Node = struct {
    first: u32,
    cnt: u32,
    par: i32,
    lev: u32,
    leaf: bool = false,
    v: []V = &.{},
    p: []Poly = &.{},
    l: []u32 = &.{},
    min: V = .{ 0, 0, 0 },
    max: V = .{ 0, 0, 0 },
};

var nodes: std.ArrayList(Node) = .empty;
var order: []u32 = &.{};
var leaf_of: []u32 = &.{};
var levels: u32 = 0;
var level_now: u32 = 0;

/// Each thread's scratch arena and its results' (kept until the next cut).
const MAXT = 65;
var scratch: [MAXT]std.heap.ArenaAllocator = undefined;
var results: [MAXT]std.heap.ArenaAllocator = undefined;
var arenas_made = false;

fn arenasInit() void {
    if (arenas_made) return;
    for (0..MAXT) |k| {
        scratch[k] = std.heap.ArenaAllocator.init(pa);
        results[k] = std.heap.ArenaAllocator.init(pa);
    }
    arenas_made = true;
}

fn cutFor(t: usize) Cut {
    const k = @min(t, MAXT - 1);
    _ = scratch[k].reset(.retain_capacity);
    return .{ .a = scratch[k].allocator(), .r = results[k].allocator(), .v = &.{}, .p = &.{}, .l = &.{} };
}

const jobs = @import("jobs.zig");

fn parFor(n: usize, comptime f: fn (usize, usize) void) void {
    const C = struct {
        fn run(_: *anyopaque, lo: usize, hi: usize, t: usize) void {
            for (lo..hi) |i| f(i, t);
        }
    };
    var dummy: u8 = 0;
    jobs.parallelFor(n, 1, &dummy, C.run);
}

/// sh_cut_all: every cell cut, res filled (n cells). False: no memory.
pub fn cutAll(n: u32) bool {
    lap(0);
    resFree();
    treeFree();
    arenasInit();
    for (0..MAXT) |k| _ = results[k].reset(.free_all);
    res = res_arena.allocator().alloc([]Piece, n) catch return false;
    @memset(res, &.{});
    if (mode == 1) {
        if (!cellsAlloc(n)) return false;
        parFor(n, planesJob);
    }
    lap(1);
    if (!treeBuild()) {
        treeFree();
        return false;
    }
    lap(2);
    var l: u32 = 1;
    while (l < levels) : (l += 1) {
        level_now = l;
        parFor(nodes.items.len, nodeJob);
        // the parents' solids go (not leaves')
        for (nodes.items) |*nd| {
            if (nd.lev == l - 1 and !nd.leaf) {
                nd.v = &.{};
                nd.p = &.{};
            }
        }
    }
    lap(3);
    parFor(n, cellJob);
    lap(4);
    treeFree();
    return true;
}

fn treeFree() void {
    nodes.clearAndFree(pa);
    freeSlice(u32, &order);
    freeSlice(u32, &leaf_of);
}

fn planesJob(i: usize, t: usize) void {
    var c = cutFor(t);
    cpn[i] = 0;
    const r = vorPlanes(&c, @intCast(i)) orelse return;
    const k: u32 = @min(@as(u32, @intCast(r.len)), CPL_MAX);
    cpn[i] = k;
    const dst = cpl[i * CPL_MAX ..][0..k];
    @memcpy(dst, r[0..k]);
    for (dst) |*p| {
        var a: u32 = @intCast(i);
        var b: u32 = p.tag -% 1;
        if (a > b) std.mem.swap(u32, &a, &b);
        p.tag = (a << 12) | b | (1 << 30);
    }
    cbb[i] = cxBounds(&c);
}

fn cxBounds(c: *Cut) [6]f64 {
    var b = [6]f64{ BIG, BIG, BIG, -BIG, -BIG, -BIG };
    for (c.v) |v| {
        for (0..3) |k| {
            b[k] = minsd(b[k], v[k]);
            b[3 + k] = maxsd(b[3 + k], v[k]);
        }
    }
    return b;
}

/// sort_u64: Shell sort, ascending (unique keys here: any sort gives the same).
pub fn sortU64(k: []u64) void {
    std.mem.sort(u64, k, {}, std.sort.asc(u64));
}

fn f32bits(x: f64) u64 {
    const f: f32 = @floatCast(x);
    return @as(u32, @bitCast(f));
}

/// vor_planes: the box round the mesh cut by the bisectors with the other
/// seeds, nearest first, until none can reach it (twice the cell's radius);
/// the planes that left a face.
fn vorPlanes(c: *Cut, i: u32) ?[]Plane {
    const ns = seeds.len;
    const keys = c.alloc(u64, ns) orelse return null;
    const si = seeds[i];
    for (seeds, 0..) |s, j| {
        var d = (s[0] - si[0]) * (s[0] - si[0]);
        d = d + (s[1] - si[1]) * (s[1] - si[1]);
        d = d + (s[2] - si[2]) * (s[2] - si[2]);
        keys[j] = (f32bits(d) << 32) | j;
    }
    sortU64(keys);
    if (!boxCell(c)) return null;
    var r2 = cellRadius(c, si);
    for (keys) |kk| {
        const j: u32 = @truncate(kk);
        if (j == i) continue;
        const dd: f64 = @as(f32, @bitCast(@as(u32, @intCast(kk >> 32))));
        if (dd > r2 * 4.0) break;
        const pl = bisector(i, j);
        clipPlane(c, &pl);
        if (c.fail) return null;
        r2 = cellRadius(c, si);
    }
    const out = c.alloc(Plane, c.p.len) orelse return null;
    var n: usize = 0;
    for (keys) |kk| {
        const j: u32 = @truncate(kk);
        if (j == i) continue;
        const dd: f64 = @as(f32, @bitCast(@as(u32, @intCast(kk >> 32))));
        if (dd > r2 * 4.0) break;
        for (c.p) |p| {
            if (p.tag == j + 1) {
                out[n] = bisector(i, j);
                n += 1;
                break;
            }
        }
    }
    return out[0..n];
}

fn bisector(i: u32, j: u32) Plane {
    const a = seeds[i];
    const b = seeds[j];
    var n = V{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    var l = n[0] * n[0];
    l = l + n[1] * n[1];
    l = l + n[2] * n[2];
    l = maxsd(@sqrt(l), TINY);
    const inv = 1.0 / l;
    n = .{ n[0] * inv, n[1] * inv, n[2] * inv };
    var d = (b[0] + a[0]) * n[0];
    d = d + (b[1] + a[1]) * n[1];
    d = d + (b[2] + a[2]) * n[2];
    return .{ .n = n, .d = d * 0.5, .tag = j + 1 };
}

const box_quads = [24]u32{ 0, 2, 3, 1, 4, 5, 7, 6, 0, 1, 5, 4, 2, 6, 7, 3, 0, 4, 6, 2, 1, 3, 7, 5 };

/// box_cell: the box round the mesh, 1% larger.
fn boxCell(c: *Cut) bool {
    const v = c.alloc(V, 8) orelse return false;
    const p = c.alloc(Poly, 6) orelse return false;
    const l = c.alloc(u32, 24) orelse return false;
    for (0..8) |k| {
        for (0..3) |a| {
            const pad = ((src_max[a] - src_min[a]) * 0.01 + tol) + tol;
            v[k][a] = if ((k >> @intCast(a)) & 1 != 0) src_max[a] + pad else src_min[a] - pad;
        }
    }
    for (0..6) |k| p[k] = .{ .first = @intCast(k * 4), .cnt = 4, .tag = 0 };
    @memcpy(l, &box_quads);
    c.v = v;
    c.p = p;
    c.l = l;
    return true;
}

fn cellRadius(c: *Cut, s: V) f64 {
    var r: f64 = 0;
    for (c.v) |v| {
        var d = (v[0] - s[0]) * (v[0] - s[0]);
        d = d + (v[1] - s[1]) * (v[1] - s[1]);
        d = d + (v[2] - s[2]) * (v[2] - s[2]);
        r = maxsd(r, d);
    }
    return r;
}

var sort_keys: []u64 = &.{};

fn treeBuild() bool {
    treeFree();
    const n = ncell;
    if (n == 0) return false;
    if (sort_keys.len < n) {
        if (sort_keys.len > 0) pa.free(sort_keys);
        sort_keys = pa.alloc(u64, n) catch {
            sort_keys = &.{};
            return false;
        };
    }
    order = pa.alloc(u32, n) catch return false;
    leaf_of = pa.alloc(u32, n) catch return false;
    @memset(leaf_of, 0);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    nodes.ensureTotalCapacity(pa, 2 * n + 2) catch return false;
    levels = 1;
    nodes.appendAssumeCapacity(.{ .first = 0, .cnt = n, .par = -1, .lev = 0, .v = src_p, .p = src_pp, .l = src_pl });
    tnBox(0);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(pa);
    stack.append(pa, 0) catch return false;
    while (stack.pop()) |ni| {
        const nd = nodes.items[ni];
        if (nd.cnt <= 1) {
            nodes.items[ni].leaf = true;
            leaf_of[order[nd.first]] = ni;
            continue;
        }
        tnSort(ni);
        const half = nd.cnt >> 1;
        for (0..2) |side| {
            const k: u32 = @intCast(nodes.items.len);
            nodes.appendAssumeCapacity(.{
                .first = if (side == 0) nd.first else nd.first + half,
                .cnt = if (side == 0) half else nd.cnt - half,
                .par = @intCast(ni),
                .lev = nd.lev + 1,
            });
            if (nd.lev + 2 > levels) levels = nd.lev + 2;
            tnBox(k);
            stack.append(pa, k) catch return false;
        }
    }
    return true;
}

fn tnBox(ni: u32) void {
    const nd = &nodes.items[ni];
    var b = [6]f64{ BIG, BIG, BIG, -BIG, -BIG, -BIG };
    for (order[nd.first..][0..nd.cnt]) |ci| {
        for (0..3) |k| {
            b[k] = minsd(b[k], cbb[ci][k]);
            b[3 + k] = maxsd(b[3 + k], cbb[ci][3 + k]);
        }
    }
    const hair = tol * 10000.0;
    for (0..3) |k| {
        nd.min[k] = b[k] - hair;
        nd.max[k] = b[3 + k] + hair;
    }
}

fn tnSort(ni: u32) void {
    const nd = nodes.items[ni];
    const cells = order[nd.first..][0..nd.cnt];
    var axis: usize = 0;
    var best: f64 = 0;
    for (0..3) |a| {
        var lo = BIG;
        var hi = 0 - BIG;
        for (cells) |ci| {
            const m = cbb[ci][a] + cbb[ci][a + 3];
            lo = minsd(lo, m);
            hi = maxsd(hi, m);
        }
        const s = hi - lo;
        if (s > best) {
            best = s;
            axis = a;
        }
    }
    const keys = sort_keys[0..cells.len];
    for (cells, 0..) |ci, k| {
        const m: f32 = @floatCast(cbb[ci][axis] + cbb[ci][axis + 3]);
        var b: u32 = @bitCast(m);
        const s: u32 = @bitCast(@as(i32, @bitCast(b)) >> 31);
        b ^= s | 0x80000000;
        keys[k] = (@as(u64, b) << 32) | ci;
    }
    sortU64(keys);
    for (cells, 0..) |*ci, k| ci.* = @truncate(keys[k]);
}

fn nodeJob(i: usize, t: usize) void {
    const nd = &nodes.items[i];
    if (nd.lev != level_now) return;
    var c = cutFor(t);
    const par = nodes.items[@intCast(nd.par)];
    c.v = par.v;
    c.p = par.p;
    c.l = par.l;
    for (0..6) |k| {
        if (c.p.len == 0) break;
        const a = k >> 1;
        const near = (par.max[a] - par.min[a]) * 0.02;
        var pl = Plane{};
        if (k & 1 == 0) {
            const v = nd.max[a] + near;
            if (v >= par.max[a]) continue;
            pl.n[a] = 1;
            pl.d = v - near;
        } else {
            const v = nd.min[a] - near;
            if (!(v > par.min[a])) continue;
            pl.n[a] = 0 - @as(f64, 1);
            pl.d = 0 - (v + near);
        }
        clipPlane(&c, &pl);
        if (c.fail) {
            nd.v = &.{};
            nd.p = &.{};
            nd.l = &.{};
            return;
        }
    }
    // its own copy
    nd.v = c.r.dupe(V, c.v) catch &.{};
    nd.p = c.r.dupe(Poly, c.p) catch &.{};
    nd.l = c.r.dupe(u32, c.l) catch &.{};
}

fn cellJob(i: usize, t: usize) void {
    const np = cpn[i];
    if (np == 0) return;
    var c = cutFor(t);
    const nd = nodes.items[leaf_of[i]];
    c.v = nd.v;
    c.p = nd.p;
    c.l = nd.l;
    for (cpl[i * CPL_MAX ..][0..np]) |*pl| {
        if (c.p.len == 0) break;
        if (c.fail) return;
        clipPlane(&c, pl);
    }
    if (c.fail or c.p.len == 0) return;
    putPieces(&c, i);
}

fn ufRoot(p: []u32, x0: u32) u32 {
    var x = x0;
    while (p[x] != x) {
        const g = p[p[x]];
        p[x] = g;
        x = g;
    }
    return x;
}

fn ufJoin(p: []u32, a: u32, b: u32) void {
    const ra = ufRoot(p, a);
    const rb = ufRoot(p, b);
    if (ra == rb) return;
    if (rb < ra) p[ra] = rb else p[rb] = ra;
}

/// put_pieces: the cut's parts that touch (shared vertices) as pieces; those
/// under 1e-12 of the volume go.
fn putPieces(c: *Cut, cell: usize) void {
    const nv = c.v.len;
    const par = c.alloc(u32, nv) orelse return;
    for (par, 0..) |*x, i| x.* = @intCast(i);
    for (c.p) |p| {
        const f0 = c.l[p.first];
        for (1..p.cnt) |k| ufJoin(par, f0, c.l[p.first + k]);
    }
    const part = c.alloc(u32, nv) orelse return;
    @memset(part, 0xffffffff);
    var nparts: u32 = 0;
    for (c.p) |p| {
        const r = ufRoot(par, c.l[p.first]);
        if (part[r] == 0xffffffff) {
            part[r] = nparts;
            nparts += 1;
        }
    }
    const starts = c.alloc(u32, nparts + 2) orelse return;
    @memset(starts, 0);
    for (c.p) |p| starts[part[ufRoot(par, c.l[p.first])] + 1] += 1;
    for (0..nparts) |k| starts[k + 1] += starts[k];
    const sorted = c.alloc(u32, c.p.len) orelse return;
    const fill = c.alloc(u32, nparts + 2) orelse return;
    @memcpy(fill, starts);
    for (c.p, 0..) |p, pi| {
        const k = part[ufRoot(par, c.l[p.first])];
        sorted[fill[k]] = @intCast(pi);
        fill[k] += 1;
    }
    const local = c.alloc(u32, nv) orelse return;
    @memset(local, 0xffffffff);
    var out: std.ArrayList(Piece) = .empty;
    const vlim = @abs(src_vol) * 1.0e-12;
    for (0..nparts) |k| {
        const idx = sorted[starts[k]..starts[k + 1]];
        const vc = polyVc(c, idx);
        if (!(vc[0] > vlim)) continue;
        const cen = V{ vc[1], vc[2], vc[3] };
        var verts: std.ArrayList([3]f32) = .empty;
        var cnt = c.r.alloc(u32, idx.len) catch return;
        var tag = c.r.alloc(u32, idx.len) catch return;
        var nl: usize = 0;
        for (idx) |pi| nl += c.p[pi].cnt;
        var loops = c.r.alloc(u32, nl) catch return;
        for (idx) |pi| {
            const p = c.p[pi];
            for (c.l[p.first..][0..p.cnt]) |v| {
                if (local[v] != 0xffffffff) continue;
                local[v] = @intCast(verts.items.len);
                const q = c.v[v];
                verts.append(c.r, .{ @floatCast(q[0] - cen[0]), @floatCast(q[1] - cen[1]), @floatCast(q[2] - cen[2]) }) catch return;
            }
        }
        var w: usize = 0;
        for (idx, 0..) |pi, k2| {
            const p = c.p[pi];
            cnt[k2] = p.cnt;
            tag[k2] = p.tag;
            for (c.l[p.first..][0..p.cnt]) |v| {
                loops[w] = local[v];
                w += 1;
            }
        }
        out.append(c.r, .{ .vol = vc[0], .c = cen, .verts = verts.items, .cnt = cnt, .tag = tag, .loops = loops }) catch return;
    }
    res[cell] = out.items;
}

/// poly_vc: volume and centre (fans from each polygon's first corner,
/// tetrahedra from the first vertex).
fn polyVc(c: *Cut, idx: []const u32) [4]f64 {
    if (idx.len == 0) return .{ 0, 0, 0, 0 };
    const o = c.v[c.l[c.p[idx[0]].first]];
    var s: f64 = 0;
    var acc = V{ 0, 0, 0 };
    for (idx) |pi| {
        const p = c.p[pi];
        const a = c.l[p.first];
        const last = p.first + p.cnt - 1;
        var r = p.first + 1;
        while (r < last) : (r += 1) {
            const b = c.l[r];
            const cc = c.l[r + 1];
            const v6 = tet6(c.v[a], c.v[b], c.v[cc], o);
            s = s + v6;
            for (0..3) |k| {
                var x: f64 = 0;
                x = x + c.v[a][k];
                x = x - o[k];
                x = x + c.v[b][k];
                x = x - o[k];
                x = x + c.v[cc][k];
                x = x - o[k];
                acc[k] = x * v6 + acc[k];
            }
        }
    }
    const vol = s * 0.16666666666666666;
    if (@abs(s) > TINY) {
        const d = s * 4.0;
        return .{ vol, acc[0] / d + o[0], acc[1] / d + o[1], acc[2] / d + o[2] };
    }
    return .{ vol, o[0], o[1], o[2] };
}

test "a cube cut in two by a plane: two closed halves" {
    const verts = [_][3]f32{ .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ -1, 1, -1 }, .{ 1, 1, -1 }, .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ -1, 1, 1 }, .{ 1, 1, 1 } };
    const poff = [_]u32{ 0, 4, 8, 12, 16, 20, 24 };
    const loops = box_quads;
    const tris = try triangulate(std.testing.allocator, &verts, &poff, &loops);
    defer std.testing.allocator.free(tris);
    try std.testing.expect(srcSet(&verts, tris));
    defer srcFree();
    try std.testing.expectEqual(@as(i32, 0), open_edges);
    try std.testing.expectApproxEqAbs(@as(f64, 8), src_vol, 1e-12);
    mode = 0;
    try std.testing.expect(cellsAlloc(2));
    defer cellsFree();
    cpl[0] = .{ .n = .{ 1, 0, 0 }, .d = 0.25, .tag = 7 };
    cpn[0] = 1;
    cbb[0] = .{ -1, -1, -1, 0.25, 1, 1 };
    cpl[CPL_MAX] = .{ .n = .{ -1, 0, 0 }, .d = -0.25, .tag = 7 };
    cpn[1] = 1;
    cbb[1] = .{ 0.25, -1, -1, 1, 1, 1 };
    try std.testing.expect(cutAll(2));
    defer resFree();
    try std.testing.expectEqual(@as(usize, 1), res[0].len);
    try std.testing.expectEqual(@as(usize, 1), res[1].len);
    try std.testing.expectApproxEqAbs(@as(f64, 5), res[0][0].vol, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3), res[1][0].vol, 1e-9);
    try std.testing.expectEqual(@as(i32, 0), polysOpen(res[0][0].cnt, res[0][0].loops));
    try std.testing.expect(inside(.{ 0.1, 0.2, 0.3 }));
    try std.testing.expect(!inside(.{ 2, 0, 0 }));
    try std.testing.expectApproxEqAbs(@as(f64, 1), dist2(.{ 2, 0, 0 }), 1e-12);
}
