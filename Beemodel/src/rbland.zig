// Rigid bodies on landscapes and in water (rbody.s: hf_reset .. hf_prepare,
// rb_water, rb_volume).
//
// Heightfields: a landscape made a passive mesh body is not cut into
// triangles: each step, the cells under every moving part (its bounds, as the
// pairs see them) become triangle parts on the fly in slots of their own (a
// hash from the triangle to its slot; a slot not needed for a few steps is
// free again), so pairs, manifolds and contacts work as for a mesh's
// triangles and keep their slot while in use. A cell (i, j) is the triangles
// (i, j)(i, j+1)(i+1, j+1) and (i, j)(i+1, j+1)(i+1, j), as the display mesh;
// an edge with a neighbour within 5 degrees is inactive. A triangle's
// friction and bounce are the paint layers' there (by their weights), the
// body's for the rest. At most HF_MAX landscapes are heightfields; more are
// plain mesh colliders.
//
// Water: a mesh object flagged OBF_WATER (landscape.add island, landscape.sea,
// landscape.add_water) is a level over its extent. A moving body reaching below
// it is pushed up by the water it displaces (1000 kg/m3 x g x its volume x the
// share of its height below the level - its bounds), once a step, and slowed
// (its speeds and spin) by that share.
//
// Every number goes through the original's single-precision operations in
// its order (bit for bit).
const std = @import("std");
const rc = @import("rbcore.zig");
const narrow = @import("rbnarrow.zig");
const land = @import("landscape.zig");
const scene = @import("scene.zig");

const V4 = rc.V4;
const Body = rc.Body;
const splat = rc.splat;
const andXyz = rc.andXyz;

pub const HF_SLOTS: u32 = 131072;
pub const HF_MAX: u32 = 4;
const HF_HBITS = 18;
const HF_HN: u32 = 1 << HF_HBITS;

const hf_cos5: f32 = 0.9961947;
const rx_rho: f32 = 1000.0;
const rx_wdrag: f32 = 1.5;
const rx_eight: f32 = 8.0;
const rx_sph: f32 = 4.18879;
const rx_2pi: f32 = 6.2831853;
const rx_hullv: f32 = 0.7;
const rx_tiny2: f32 = 1e-12;
const rx_keep: f32 = 0.04;
const hf_pad: V4 = .{ 0.5, 2.0, 0.5, 0 };
/// A triangle's edge (t, edge 0-1, 1-2, 2-0) -> its neighbour: di, dj, t.
const hf_nb = [2][3][3]i32{
    .{ .{ -1, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 0, 1 } },
    .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 } },
};

/// A heightfield (HF_*).
pub const Hf = struct {
    blk: ?*land.Block = null, // the landscape block (referenced)
    body: u32 = 0,
    n: u32 = 0,
    cell: f32 = 0, // its space
    half: f32 = 0,
    hmax: f32 = 0,
    idx: u32 = 0,
    scl: V4 = @splat(0), // the body's scale, centre of mass
    com: V4 = @splat(0),
    slot0: u32 = 0, // its parts, vertices, corners (world)
    vx0: u32 = 0,
    tw0: u32 = 0,
    nfree: u32 = 0,
};

pub var hf: [HF_MAX]Hf = @splat(.{});
pub var nhf: u32 = 0;
/// (heightfields to make room for: rb_build's count)
pub var xhf: u32 = 0;
// triangles in slots, the step each was last needed, free slots, the hash,
// each slot's friction and bounce (HF_SLOTS a heightfield; the hash 1 << 18)
pub var keyp: []u32 = &.{};
pub var seenp: []u32 = &.{};
pub var freelp: []u32 = &.{};
pub var tabp: []u32 = &.{};
pub var fricp: []f32 = &.{};
pub var restp: []f32 = &.{};

/// hf_reset: the heightfields let go.
pub fn reset() void {
    for (hf[0..nhf]) |*h| {
        const b = h.blk;
        h.blk = null;
        land.unref(b);
    }
    nhf = 0;
}

/// hf_new: the body a heightfield (BD_BVH = -(index + 1)); com: its centre
/// of mass (the mesh's bounds' centre, scaled).
pub fn new(idx: u32, blk: *land.Block, com: V4) void {
    const k = nhf;
    nhf += 1;
    const b = &rc.bd[idx];
    b.bvh = ~k;
    const h = &hf[k];
    h.idx = k;
    h.blk = blk;
    land.ref(blk);
    h.body = idx;
    h.n = blk.n;
    const nm1: i32 = @as(i32, @bitCast(blk.n)) - 1;
    h.cell = blk.size / @as(f32, @floatFromInt(nm1));
    h.half = blk.size * 0.5;
    h.hmax = blk.hmax;
    h.scl = andXyz(b.scl);
    h.com = com;
}

/// The part for its bounds (pairs only; the triangles come per step): type 3,
/// the mesh's half extents padded.
pub fn boundsPart(p: *rc.Part, half: V4) void {
    p.typ = 3;
    p.half = half + hf_pad;
}

/// Is the body a heightfield (BD_BVH < 0)?
pub inline fn isHf(b: *const Body) bool {
    return @as(i32, @bitCast(b.bvh)) < 0;
}
pub inline fn of(b: *const Body) *Hf {
    return &hf[~b.bvh];
}

/// hf_reserve: its slots: parts, vertices, corners.
pub fn reserve(b: *const Body) void {
    const h = of(b);
    h.slot0 = rc.npt;
    rc.npt += HF_SLOTS;
    h.vx0 = rc.nvx;
    rc.nvx += 3 * HF_SLOTS;
    h.tw0 = rc.nbvi;
    rc.nbvi += HF_SLOTS;
    h.nfree = HF_SLOTS;
    const fl = freelp[h.idx * HF_SLOTS ..][0..HF_SLOTS];
    const sn = seenp[h.idx * HF_SLOTS ..][0..HF_SLOTS];
    for (0..HF_SLOTS) |c| {
        fl[c] = HF_SLOTS - 1 - @as(u32, @intCast(c)); // (slot 0 taken first)
        sn[c] = 0;
    }
}

const Arrays = struct { key: []u32, seen: []u32, free: []u32, tab: []u32 };
/// hf_arrays.
fn arrays(h: *const Hf) Arrays {
    const o = h.idx * HF_SLOTS;
    return .{
        .key = keyp[o..][0..HF_SLOTS],
        .seen = seenp[o..][0..HF_SLOTS],
        .free = freelp[o..][0..HF_SLOTS],
        .tab = tabp[h.idx * HF_HN ..][0..HF_HN],
    };
}

/// HF_HASHI: a triangle's first place in the hash.
inline fn hashOf(t: u32) u32 {
    return (t *% 0x9E3779B1) >> (32 - HF_HBITS);
}

/// hf_sweep: slots unneeded for 3 steps freed, the hash made again from the rest.
fn sweep(h: *Hf) void {
    const a = arrays(h);
    @memset(a.tab, 0);
    const now = rc.stepno;
    for (0..HF_SLOTS) |c| {
        const s = a.seen[c];
        if (s == 0) continue;
        if (now -% s > 3) {
            a.seen[c] = 0; // free again
            a.free[h.nfree] = @intCast(c);
            h.nfree += 1;
            continue;
        }
        var e = hashOf(a.key[c]); // in the hash
        while (a.tab[e] != 0) e = (e + 1) & (HF_HN - 1);
        a.tab[e] = @as(u32, @intCast(c)) + 1;
    }
}

/// hfs_get: the triangle's slot (make: made when new, and marked seen), or null.
pub fn get(h: *Hf, tri: u32, make: bool) ?u32 {
    const a = arrays(h);
    var e = hashOf(tri);
    while (true) {
        const c = a.tab[e];
        if (c == 0) break;
        if (a.key[c - 1] == tri) {
            if (make) a.seen[c - 1] = rc.stepno;
            return c - 1;
        }
        e = (e + 1) & (HF_HN - 1);
    }
    if (!make or h.nfree == 0) return null;
    h.nfree -= 1;
    const c = a.free[h.nfree];
    a.tab[e] = c + 1;
    a.key[c] = tri;
    a.seen[c] = rc.stepno;
    makeTri(h, c, tri);
    return c;
}

/// hf_pt: the sample in the body's space: scale (x, h, z) - centre of mass.
fn sample(h: *const Hf, i: i32, j: i32) V4 {
    const hs = land.heights(h.blk.?);
    const k: u32 = @bitCast(j *% @as(i32, @bitCast(h.n)) +% i);
    const y = hs[k];
    const x = @as(f32, @floatFromInt(i)) * h.cell - h.half;
    const z = @as(f32, @floatFromInt(j)) * h.cell - h.half;
    const v: V4 = .{ x, y, z, 0 };
    return andXyz(v * h.scl - h.com);
}

/// hf_corners: a triangle's corners (null: outside the grid).
fn corners(h: *const Hf, i: i32, j: i32, t: i32) ?[3]V4 {
    if (i < 0 or j < 0) return null;
    const last = @as(i32, @bitCast(h.n)) - 2;
    if (i > last or j > last) return null;
    return .{
        sample(h, i, j), // v0 (i, j)
        sample(h, i + t, j + 1), // t0: (i, j+1); t1: (i+1, j+1)
        sample(h, i + 1, j + 1 - t), // t0: (i+1, j+1); t1: (i+1, j)
    };
}

/// hf_tnorm: the triangle's unit normal (null: outside the grid).
fn tnorm(h: *const Hf, i: i32, j: i32, t: i32, c: *[3]V4) ?V4 {
    c.* = corners(h, i, j, t) orelse return null;
    const n = rc.cross(c[1] - c[0], c[2] - c[0]);
    const l = rc.maxss(@sqrt(rc.dot3(n, n)), rx_tiny2);
    return n / splat(l);
}

/// hf_tri: the slot's part: the triangle (body space), its corners in the
/// world, its active edges, its material.
fn makeTri(h: *Hf, slot: u32, tri: u32) void {
    const t: i32 = @intCast(tri & 1);
    const cell = (tri >> 1);
    const i: i32 = @intCast(cell % (h.n - 1));
    const j: i32 = @intCast(cell / (h.n - 1));
    var c: [3]V4 = undefined;
    const n = tnorm(h, i, j, t, &c) orelse @as(V4, @splat(0));
    const p = &rc.pt[h.slot0 + slot];
    p.* = .{};
    p.typ = 1;
    p.nv = 3;
    p.body = h.body;
    p.tw = h.tw0 + slot;
    const vi = h.vx0 + slot * 3; // its vertices: from the bounds' centre
    const vs = rc.vx[vi..][0..3];
    p.verts = vs.ptr;
    const mn = rc.minps(rc.minps(c[0], c[1]), c[2]);
    const mx = rc.maxps(rc.maxps(c[0], c[1]), c[2]);
    const off = andXyz((mn + mx) * rc.half4);
    p.off = off;
    p.half = andXyz((mx - mn) * rc.half4);
    for (0..3) |k| vs[k] = c[k] - off;
    const b = &rc.bd[h.body]; // the corners in the world (static)
    for (0..3) |k| rc.tvw[p.tw * 3 + k] = andXyz(rc.mv3(&b.r, c[k]) + b.pos);
    // its edges: active unless a neighbour lies within 5 degrees
    var flg: u32 = 1;
    for (0..3) |e| {
        const d = hf_nb[@intCast(t)][e];
        const bit = @as(u32, 1) << @intCast(e + 1);
        var sc: [3]V4 = undefined;
        if (tnorm(h, i + d[0], j + d[1], d[2], &sc)) |m| {
            if (rc.dot3(m, n) >= hf_cos5) continue;
        }
        flg |= bit;
    }
    p.flg = flg;
    mat(h, slot, @intCast(i), @intCast(j));
}

/// hf_part_mat: friction and bounce at a heightfield body's triangle part.
pub fn partMat(b: *const Body, part: u32) [2]f32 {
    var f = b.fric;
    var r = b.rest;
    const k = ~b.bvh;
    const d = part -% hf[k].slot0;
    if (d < HF_SLOTS) {
        f = fricp[k * HF_SLOTS + d];
        r = restp[k * HF_SLOTS + d];
    }
    return .{ f, r };
}

/// hf_mat: the slot's friction and bounce: the paint layers' by their weights
/// at (i, j), the body's for the rest.
fn mat(h: *const Hf, slot: u32, i: u32, j: u32) void {
    const b = &rc.bd[h.body];
    var f = b.fric; // (unpainted: the body's)
    var r = b.rest;
    const blk = h.blk.?;
    const sp = land.splat(blk);
    if (sp.len != 0 and blk.np != 0) {
        const w = &sp[j * h.n + i];
        var sf: f32 = 0; // sum w f, sum w b, sum w
        var sb: f32 = 0;
        var sw: i32 = 0;
        var k: u32 = 0;
        while (k < blk.np and k < land.LA_MAXP) : (k += 1) {
            sw += w[k];
            const x: f32 = @floatFromInt(w[k]);
            sf += blk.paint[k].fric * x;
            sb += blk.paint[k].bounce * x;
        }
        var rest = 255 - sw;
        if (rest < 0) rest = 0;
        const x: f32 = @floatFromInt(rest);
        f = f * x + sf;
        r = r * x + sb;
        f = f / 255.0;
        r = r / 255.0;
    }
    fricp[h.idx * HF_SLOTS + slot] = f;
    restp[h.idx * HF_SLOTS + slot] = r;
}

/// hf_box: the part's bounds as the heightfield sees them (part_bounds + the
/// contacts' keep distance).
pub fn box(b: *const Body, part: u32) [2]V4 {
    var o: [2]V4 = undefined;
    narrow.partBounds(b, part, &o);
    const k = andXyz(splat(rx_keep + rx_keep));
    o[0] = o[0] - k;
    o[1] = o[1] + k;
    return o;
}

pub const Cells = struct { i0: i32, i1: i32, j0: i32, j1: i32 };

/// cvttss2si: out of range or NaN gives the minimum.
fn cvtt(x: f32) i32 {
    if (x >= -2147483648.0 and x < 2147483648.0) return @intFromFloat(x);
    return std.math.minInt(i32);
}

/// hf_cells: the cells under the bounds (world min, max); null: none
/// (outside, or above its highest).
pub fn cells(h: *const Hf, bnd: [2]V4) ?Cells {
    const b = &rc.bd[h.body];
    var c = (bnd[0] + bnd[1]) * rc.half4; // centre, half (world)
    const hh = (bnd[1] - bnd[0]) * rc.half4;
    c = c - b.pos;
    // into the body: R^T (c - pos), |R|^T h
    var l = rc.mtv3(&b.r, c);
    const a: [3]V4 = .{ rc.abs3(b.r[0]), rc.abs3(b.r[1]), rc.abs3(b.r[2]) };
    var e = rc.mtv3(&a, hh);
    l += h.com; // its space: / scale (w: 1, not 0)
    const s = rc.setW(andXyz(h.scl), 1.0);
    l = l / s;
    e = rc.abs3(e / s);
    // above its highest: none
    if (l[1] - e[1] > h.hmax) return null;
    const last = @as(i32, @bitCast(h.n)) - 2; // the last cell
    var r: Cells = .{
        .i0 = cvtt(@floor((l[0] - e[0] + h.half) / h.cell)),
        .i1 = cvtt(@floor((l[0] + e[0] + h.half) / h.cell)),
        .j0 = cvtt(@floor((l[2] - e[2] + h.half) / h.cell)),
        .j1 = cvtt(@floor((l[2] + e[2] + h.half) / h.cell)),
    };
    // clamped: none past the edges
    if (r.i0 < 0) r.i0 = 0;
    if (r.j0 < 0) r.j0 = 0;
    if (r.i1 > last) r.i1 = last;
    if (r.j1 > last) r.j1 = last;
    if (r.i0 > r.i1 or r.j0 > r.j1) return null;
    return r;
}

/// A cell's first triangle: (j (N - 1) + i) 2.
pub inline fn triOf(h: *const Hf, i: i32, j: i32) u32 {
    const nm1 = @as(i32, @bitCast(h.n)) - 1;
    return @bitCast((j *% nm1 +% i) << 1);
}

/// hf_prepare: each step, before the pairs: the triangles under every moving
/// part over a heightfield in their slots (made when new).
pub fn prepare() void {
    for (hf[0..nhf]) |*h| {
        sweep(h);
        const hb = &rc.bd[h.body];
        for (rc.bd[0..rc.nb]) |*b| {
            if (b.typ != 1) continue;
            // over it?
            const x = b.min <= hb.max;
            const y = hb.min <= b.max;
            if (!(x[0] and y[0] and x[1] and y[1] and x[2] and y[2])) continue;
            var p = b.p0;
            while (p < b.p0 + b.np) : (p += 1) {
                const c = cells(h, box(b, p)) orelse continue;
                var j = c.j0;
                while (j <= c.j1) : (j += 1) {
                    var i = c.i0;
                    while (i <= c.i1) : (i += 1) {
                        const id = triOf(h, i, j);
                        _ = get(h, id, true);
                        _ = get(h, id +% 1, true);
                    }
                }
            }
        }
    }
}

/// rb_water: water planes: what is in them floats.
pub fn water() void {
    const W = struct { lvl: f32, x0: f32, x1: f32, z0: f32, z1: f32 };
    var ws: [4]W = undefined;
    var nw: u32 = 0;
    var oi: usize = 0;
    while (oi < scene.count and nw < 4) : (oi += 1) {
        const o = &scene.objects[oi];
        if (o.gflags & land.OBF_WATER == 0) continue;
        if (!o.visible) continue;
        const mi = o.mesh orelse continue;
        const me = &(scene.meshes[mi] orelse continue);
        ws[nw] = .{
            .lvl = o.loc[1],
            .x0 = me.lo[0] * o.scl[0] + o.loc[0],
            .x1 = me.hi[0] * o.scl[0] + o.loc[0],
            .z0 = me.lo[2] * o.scl[2] + o.loc[2],
            .z1 = me.hi[2] * o.scl[2] + o.loc[2],
        };
        nw += 1;
    }
    if (nw == 0) return;
    // up: against gravity
    const gl = @sqrt(rc.dot3(rc.g, rc.g));
    if (!(gl > rx_tiny2)) return;
    const up = andXyz(rc.neg4(rc.g / splat(gl)));
    for (rc.bd[0..rc.nb]) |*b| {
        if (b.typ != 1 or b.asleep != 0) continue;
        // the first water it is over
        const w = for (ws[0..nw]) |*w| {
            if (!(b.pos[0] >= w.x0)) continue;
            if (b.pos[0] > w.x1) continue;
            if (!(b.pos[2] >= w.z0)) continue;
            if (b.pos[2] > w.z1) continue;
            break w;
        } else continue;
        // the share below: (level - min) / (max - min)
        var f = w.lvl - b.min[1];
        f = f / rc.maxss(b.max[1] - b.min[1], rx_tiny2);
        if (!(f > 0)) continue;
        f = rc.minss(f, 1.0);
        // dv = rho g V f / m dt, up
        var dv = volume(b) * f;
        dv *= rx_rho;
        dv *= gl;
        dv *= b.im;
        dv *= rc.dt;
        var v = splat(dv) * up + b.v;
        // drag: x (1 - 1.5 f dt)
        var d = f * rx_wdrag;
        d *= rc.dt;
        const k = splat(rc.maxss(1.0 - d, 0));
        v = andXyz(v * k);
        b.v = v;
        b.w = b.w * k;
    }
}

/// rb_volume: a body's volume: its parts' (a box, sphere or capsule as it
/// is; a hull 0.7 of its bounds; heightfield, plane: 0).
pub fn volume(b: *const Body) f32 {
    var v: f32 = 0;
    for (rc.pt[b.p0..][0..b.np]) |*p| {
        var x = p.half[0] * p.half[1]; // 8 hx hy hz
        x *= p.half[2];
        x *= rx_eight;
        const r = p.rad; // r: 4/3 pi r^3 + pi r^2 2 hy
        var y = r * r;
        y *= r;
        y *= rx_sph;
        x += y;
        y = r * r;
        y *= rx_2pi;
        y *= p.half[1];
        x += y;
        if (p.typ == 1) x *= rx_hullv;
        if (p.typ < 2) v += x;
    }
    return v;
}

test "hf hash and triangle ids" {
    try std.testing.expectEqual(@as(u32, 0), hashOf(0));
    try std.testing.expect(hashOf(2) < HF_HN);
    var h: Hf = .{ .n = 65 };
    try std.testing.expectEqual(@as(u32, (3 * 64 + 5) * 2), triOf(&h, 5, 3));
    h.n = 5;
    try std.testing.expect(corners(&h, -1, 0, 0) == null);
    try std.testing.expect(corners(&h, 0, 4, 0) == null);
}

test "rb_volume: a box, a sphere, a capsule, a hull" {
    var parts = [_]rc.Part{
        .{ .typ = 0, .half = .{ 0.5, 1, 2, 0 } },
        .{ .typ = 0, .rad = 1 },
        .{ .typ = 0, .rad = 0.5, .half = .{ 0, 1, 0, 0 } },
        .{ .typ = 1, .half = .{ 1, 1, 1, 0 } },
        .{ .typ = 3, .half = .{ 9, 9, 9, 0 } },
    };
    const save = rc.pt;
    defer rc.pt = save;
    rc.pt = &parts;
    var b: Body = .{ .p0 = 0, .np = 1 };
    try std.testing.expectEqual(@as(f32, 8), volume(&b));
    b.p0 = 1;
    try std.testing.expectApproxEqAbs(@as(f32, 4.18879), volume(&b), 1e-6);
    b.p0 = 3;
    b.np = 2;
    try std.testing.expectApproxEqAbs(@as(f32, 5.6), volume(&b), 1e-6);
}
