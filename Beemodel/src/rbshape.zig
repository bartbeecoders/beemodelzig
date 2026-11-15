// Rigid bodies (rbody.s): bodies and their parts. make_body / make_body_ex
// (a body from an object's evaluated mesh: box, sphere, capsule, the hull of
// its points, a compound of convex parts, a mesh collider of triangles, a
// plane), mass and inertia (mass_props: a closed mesh's volume and moments in
// doubles), hulls (hull_part, extremes along 64 fixed directions), compounds
// (decompose: triangles split along the longest side while a part is
// hollower than its hull), a mesh collider's active edges (tri_edges) and its
// triangles' tree (bvh_build), and the joints' runtime records (make_joints,
// with the uid -> body and joint-pair hashes).
//
// Every number goes through the original's single-precision (and, for the
// mass, double) operations in its order. A landscape is a heightfield
// (rbland.zig). Instances (inst.s, geometry nodes) are not in the port yet:
// marked HOOK.
const std = @import("std");
const rc = @import("rbcore.zig");
const hfl = @import("rbland.zig");

const V4 = rc.V4;
const Body = rc.Body;
const Part = rc.Part;
const BvNode = rc.BvNode;
const splat = rc.splat;
const andXyz = rc.andXyz;
const dot3 = rc.dot3;
const cross = rc.cross;
const minps = rc.minps;
const maxps = rc.maxps;
const minss = rc.minss;
const maxss = rc.maxss;

const UH_N = 16384;
const JH_N = 32768;

const rx_thin: f32 = 0.05;
const rx_thick: f32 = 0.25;
const rx_third: f32 = 0.33333334;
const rx_fifth2: f32 = 0.4;
const rx_near2: f32 = 0.0004;
const rx_tiny: f32 = 1.0e-9;
const rx_tiny2: f32 = 1e-12;
const rx_cos5: f32 = 0.9962;
const rx_conc: f32 = 0.05;
const rx_1e4: V4 = .{ 10000, 10000, 10000, 0 };
const GOLD: u64 = 0x9E3779B97F4A7C15;

/// rb_dirs: 64 directions (a spiral over the sphere).
const rb_dirs = [64]V4{
    .{ 0.176085, 0.984375, 0.000000, 0 },   .{ -0.223111, 0.953125, 0.204388, 0 },
    .{ 0.033876, 0.921875, -0.386004, 0 },  .{ 0.276681, 0.890625, 0.360881, 0 },
    .{ -0.503529, 0.859375, -0.089067, 0 }, .{ 0.472962, 0.828125, -0.300859, 0 },
    .{ -0.156838, 0.796875, 0.583431, 0 },  .{ -0.296496, 0.765625, -0.570884, 0 },
    .{ 0.637559, 0.734375, 0.232835, 0 },   .{ -0.657271, 0.703125, 0.271312, 0 },
    .{ 0.313928, 0.671875, -0.670845, 0 },  .{ 0.229806, 0.640625, 0.732659, 0 },
    .{ -0.686011, 0.609375, -0.397557, 0 }, .{ 0.796917, 0.578125, -0.175200, 0 },
    .{ -0.481507, 0.546875, 0.684894, 0 },  .{ -0.110110, 0.515625, -0.849710, 0 },
    .{ 0.668961, 0.484375, 0.563801, 0 },   .{ -0.890686, 0.453125, 0.036833, 0 },
    .{ 0.642663, 0.421875, -0.639536, 0 },  .{ -0.042522, 0.390625, 0.919567, 0 },
    .{ -0.597905, 0.359375, -0.716491, 0 }, .{ 0.936198, 0.328125, 0.125964, 0 },
    .{ -0.783851, 0.296875, 0.545383, 0 },  .{ 0.211597, 0.265625, -0.940569, 0 },
    .{ 0.483333, 0.234375, 0.843480, 0 },   .{ -0.932832, 0.203125, -0.297599, 0 },
    .{ 0.894282, 0.171875, -0.413181, 0 },  .{ -0.382225, 0.140625, 0.913307, 0 },
    .{ -0.336422, 0.109375, -0.935338, 0 }, .{ 0.882484, 0.078125, 0.463809, 0 },
    .{ -0.965907, 0.046875, 0.254610, 0 },  .{ 0.540772, 0.015625, -0.841024, 0 },
    .{ 0.169355, -0.015625, 0.985431, 0 },  .{ -0.789754, -0.046875, -0.611630, 0 },
    .{ 0.993540, -0.078125, -0.082313, 0 }, .{ -0.675005, -0.109375, 0.729661, 0 },
    .{ 0.004830, -0.140625, -0.990051, 0 }, .{ 0.661887, -0.171875, 0.729633, 0 },
    .{ -0.974974, -0.203125, -0.090360, 0 }, .{ 0.774372, -0.234375, -0.587721, 0 },
    .{ -0.172554, -0.265625, 0.948509, 0 }, .{ -0.508594, -0.296875, -0.808206, 0 },
    .{ 0.911040, -0.328125, 0.249678, 0 },  .{ -0.830249, -0.359375, 0.426070, 0 },
    .{ 0.319999, -0.390625, -0.863141, 0 }, .{ 0.341847, -0.421875, 0.839739, 0 },
    .{ -0.805561, -0.453125, -0.381771, 0 }, .{ 0.836028, -0.484375, -0.257756, 0 },
    .{ -0.433224, -0.515625, 0.739221, 0 }, .{ -0.175775, -0.546875, -0.818554, 0 },
    .{ 0.665199, -0.578125, 0.472526, 0 },  .{ -0.786795, -0.609375, 0.098057, 0 },
    .{ 0.497699, -0.640625, -0.584718, 0 }, .{ 0.026992, -0.671875, 0.740173, 0 },
    .{ -0.499107, -0.703125, -0.506465, 0 }, .{ 0.677858, -0.734375, 0.034659, 0 },
    .{ -0.495910, -0.765625, 0.409746, 0 }, .{ 0.083481, -0.796875, -0.598349, 0 },
    .{ 0.317896, -0.828125, 0.461683, 0 },  .{ -0.498324, -0.859375, -0.114663, 0 },
    .{ 0.395651, -0.890625, -0.224160, 0 }, .{ -0.119570, -0.921875, 0.368578, 0 },
    .{ -0.125566, -0.953125, -0.275292, 0 }, .{ 0.162100, -0.984375, 0.068771, 0 },
};

inline fn lane(v: V4, i: usize) f32 {
    const a: [4]f32 = v;
    return a[i];
}
inline fn setLane(v: *V4, i: usize, x: f32) void {
    var a: [4]f32 = v.*;
    a[i] = x;
    v.* = a;
}

/// A mesh as make_body reads it (ME_POS, ME_TRIS, ME_BMIN / ME_BMAX).
pub const MeshView = struct {
    verts: []const [3]f32,
    tris: []const [3]u32,
    lo: [3]f32,
    hi: [3]f32,
};

// ---- bodies ----------------------------------------------------------------------------

/// make_body: a body of the object's evaluated mesh at its place (its own
/// loc / rot / scale: the original reads OB_LOC, OB_ROT, OB_SCALE as they
/// are, parent or not).
pub fn makeBody(idx: u32, rec: []u8, oi: usize) void {
    const scene = @import("scene.zig");
    const o = &scene.objects[oi];
    const me = @import("mods.zig").of(oi) orelse return;
    // (a child: its world place, as the original holds it)
    const wp = scene.worldPlace(oi);
    var rows: [3]V4 = undefined;
    rotRows(wp[3..6].*, &rows);
    const loc = andXyz(.{ wp[0], wp[1], wp[2], 0 });
    const scl = andXyz(.{ wp[6], wp[7], wp[8], 0 });
    const mv = MeshView{ .verts = me.verts, .tris = me.tris, .lo = me.lo, .hi = me.hi };
    makeBodyEx(idx, rec, o.oid, &mv, &rows, loc, scl);
}

/// obj_matrix at loc 0, scale 1: the rotation rows Rz Ry Rx (x87 fsincos, as
/// the original), w 0.
pub fn rotRows(rot: [3]f32, o: *[3]V4) void {
    const sincos = @import("animexpr.zig").sincos32;
    const x = sincos(rot[0]);
    const y = sincos(rot[1]);
    const z = sincos(rot[2]);
    const sx = x[0];
    const cx = x[1];
    const sy = y[0];
    const cy = y[1];
    const sz = z[0];
    const cz = z[1];
    o[0] = .{ cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx, 0 };
    o[1] = .{ sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx, 0 };
    o[2] = .{ 0.0 - sy, cy * sx, cy * cx, 0 };
    // (scale 1: 1 x m, the same bits)
    for (0..3) |r| {
        o[r] = .{ 1.0 * lane(o[r], 0), 1.0 * lane(o[r], 1), 1.0 * lane(o[r], 2), 0 };
    }
}

// mass_props' results (rb_mp_*)
var mp_c: V4 = @splat(0);
var mp_m: V4 = @splat(0);
var mp_v: f32 = 0;
var mp_ok: bool = false;

/// make_body_ex: a body of that mesh, so placed (rotation rows, loc) and scaled.
pub fn makeBodyEx(idx: u32, rec: []const u8, oid: u32, me: *const MeshView, rows: *const [3]V4, loc: V4, scl: V4) void {
    const b = &rc.bd[idx];
    b.obj = oid;
    const typ = rc.rdU(rec, rc.RB_TYPE);
    b.typ = typ;
    b.p0 = rc.npt;
    const flags = rc.rdU(rec, rc.RB_FLAGS);
    const sh: u5 = @intCast((flags >> rc.RBF_GRP) & 15);
    b.grp = (flags & 0xffff0000) | (@as(u32, 1) << sh);
    b.am = if (flags & rc.RBF_ATTR != 0) rc.rdF(rec, rc.RB_MASS) else 0;
    if (typ == 1) b.v = rc.rdV3(rec, rc.RB_VEL);
    b.scl = scl;
    var q = rc.rowsQ(rows);
    const l = @sqrt(rc.dot4(q, q));
    q = q / splat(l);
    b.q = q;
    rc.qRows(b.q, &b.r);
    // the mesh's bounds, scaled: centre, half
    const S = andXyz(scl);
    const b0 = andXyz(.{ me.lo[0], me.lo[1], me.lo[2], 0 }) * S;
    const b1 = andXyz(.{ me.hi[0], me.hi[1], me.hi[2], 0 }) * S;
    const lo = minps(b0, b1);
    const hi = maxps(b1, b0);
    var centre = (lo + hi) * rc.half4;
    var half = (hi - lo) * rc.half4;
    const shape = rc.rdU(rec, rc.RB_SHAPE);
    const pstart = rc.npt;
    var kind: enum { shape, hull, comp, mesh, plane, land } = .shape;
    var eshape = shape;
    if (shape >= 5) {
        if (typ != 2) { // moving: a mesh as a compound, a plane as a box
            if (shape == 5) kind = .comp else eshape = 0;
        } else if (shape == 5) {
            kind = .mesh;
            // a landscape: a heightfield (while there is room for one)
            if (@import("scene.zig").findOid(oid)) |oi| {
                if (@import("landscape.zig").ofIndex(oi) != null and hfl.nhf < hfl.HF_MAX) kind = .land;
            }
        } else kind = .plane;
    }
    if (kind == .shape and eshape >= 3) kind = .hull;
    switch (kind) {
        .shape => {
            const p = newPart(idx);
            if (shape == 6 or shape == 0) {
                if (typ == 2) { // a thin passive box: deep below (Y only)
                    const hy = lane(half, 1);
                    if (!(hy >= rx_thin)) {
                        setLane(&half, 1, rx_thick);
                        const d = rx_thick - hy;
                        setLane(&centre, 1, lane(centre, 1) - d);
                    }
                }
                p.half = half;
            } else {
                const hx = lane(half, 0);
                const hy = lane(half, 1);
                var r = maxss(lane(half, 2), hx);
                if (shape == 1) {
                    r = maxss(r, hy);
                    p.rad = r;
                } else { // capsule: along Y
                    p.rad = r;
                    setLane(&p.half, 1, maxss(hy - r, 0));
                }
            }
        },
        .hull => {
            const pts = meshPoints(me, centre, S);
            if (shape == 3) {
                hullPart(idx, pts, @splat(0));
                if (massProps(me, pts)) {
                    const c = mp_c;
                    const p = &rc.pt[rc.npt - 1];
                    p.off = p.off - c;
                    centre = c + centre;
                }
            } else {
                decompose(idx, me, meshPointsBase());
            }
        },
        .comp => {
            _ = meshPoints(me, centre, S);
            decompose(idx, me, meshPointsBase());
        },
        .mesh => { // a mesh collider: a part a triangle
            const nt: u32 = @intCast(me.tris.len);
            const at = nt * 3 + 64;
            const pts = meshPointsIn(me, centre, S, rc.nvx + at);
            for (me.tris) |t| {
                const c: [3]V4 = .{ pts[t[0]], pts[t[1]], pts[t[2]] };
                const n = cross(c[1] - c[0], c[2] - c[0]);
                if (!(dot3(n, n) > rx_tiny2)) continue;
                hullPart(idx, &c, @splat(0));
                rc.pt[rc.npt - 1].flg = 1 | 14; // (every edge active, for now)
            }
        },
        .land => { // one part: its bounds (pairs only; the triangles come per step)
            const scene = @import("scene.zig");
            hfl.new(idx, @import("landscape.zig").ofIndex(scene.findOid(oid).?).?, centre);
            hfl.boundsPart(newPart(idx), half);
        },
        .plane => { // its object's XZ, up its Y, through its origin, without end
            const p = newPart(idx);
            p.typ = 2;
            p.half = .{ 0, 1, 0, lane(p.half, 3) };
            p.off = rc.neg3(centre);
        },
    }
    // .Lmb_mass
    b.np = rc.npt - pstart;
    b.com = centre;
    b.pos = rc.mv3(&b.r, centre) + loc;
    b.fric = rc.rdF(rec, rc.RB_FRIC);
    b.rest = rc.rdF(rec, rc.RB_REST);
    b.damp = rc.rdF(rec, rc.RB_DAMP);
    if (typ == 1) {
        var mass = rc.rdF(rec, rc.RB_MASS);
        if (!(mass > 0)) mass = 1.0;
        b.im = 1.0 / mass;
        var I: V4 = undefined;
        if (shape == 3 and mp_ok) {
            mp_ok = false;
            const m1 = mp_m;
            const a = @shuffle(f32, m1, undefined, [4]i32{ 1, 2, 0, 3 });
            const c = @shuffle(f32, m1, undefined, [4]i32{ 2, 0, 1, 3 });
            I = (a + c) * splat(mass / mp_v);
        } else {
            const h2 = half * half;
            if (shape == 1) {
                var r = rc.pt[b.p0].rad;
                r = r * r;
                r = r * mass;
                r = r * rx_fifth2;
                I = splat(r);
            } else {
                const a = @shuffle(f32, h2, undefined, [4]i32{ 1, 2, 0, 3 });
                const c = @shuffle(f32, h2, undefined, [4]i32{ 2, 0, 1, 3 });
                I = (a + c) * splat(mass * rx_third);
            }
        }
        b.iil = andXyz(rc.one4 / maxps(I, rc.tiny4));
    }
    rc.bodyUpdate(b);
    if (hfl.isHf(b)) {
        hfl.reserve(b); // a heightfield: its slots
    } else if (shape == 5 and typ == 2) {
        triEdges(b);
        bvhBuild(idx);
    }
}

/// new_part: a zeroed part of the body being made, counted.
fn newPart(body: u32) *Part {
    const p = &rc.pt[rc.npt];
    rc.npt += 1;
    p.* = .{};
    p.body = body;
    return p;
}

/// Where mesh_points puts them: after the hulls so far, leaving room for this body's.
fn meshPointsBase() u32 {
    return rc.nvx + rc.PT_MAXB * rc.HULL_MAX;
}

/// mesh_points: the mesh's points (scaled, from the centre) in scratch.
fn meshPoints(me: *const MeshView, centre: V4, S: V4) []V4 {
    return meshPointsIn(me, centre, S, meshPointsBase());
}

/// mesh_points_in: into vx from `at`.
fn meshPointsIn(me: *const MeshView, centre: V4, S: V4, at: u32) []V4 {
    const out = rc.vx[at..][0..me.verts.len];
    for (me.verts, 0..) |p, k| {
        const v: V4 = .{ p[0], p[1], p[2], 0 };
        out[k] = andXyz(v * S - centre);
    }
    return out;
}

/// hull_part: a hull part of at most HULL_MAX of the points (few: all but
/// those within 2% of the size of one kept; many: the farthest along 64
/// directions), from their bounds' centre, offset by `off`.
pub fn hullPart(body: u32, pts: []const V4, off: V4) void {
    const p = newPart(body);
    p.typ = 1;
    const base = rc.nvx;
    const out = rc.vx[base..];
    p.verts = out.ptr;
    var kept: u32 = 0;
    if (pts.len <= rc.HULL_MAX) {
        var lo = rc.big4;
        var hi = rc.nbig4;
        for (pts) |q| {
            lo = minps(lo, q);
            hi = maxps(hi, q);
        }
        const d = andXyz(hi - lo);
        const thr = dot3(d, d) * rx_near2;
        for (pts) |q| {
            var near = false;
            for (out[0..kept]) |k| {
                const e = k - q;
                if (!(dot3(e, e) >= thr)) {
                    near = true;
                    break;
                }
            }
            if (near) continue;
            out[kept] = q;
            kept += 1;
        }
    } else {
        kept = extremes(pts, out);
    }
    p.nv = kept;
    rc.nvx += kept;
    var lo = rc.big4;
    var hi = rc.nbig4;
    for (out[0..kept]) |q| {
        lo = minps(lo, q);
        hi = maxps(hi, q);
    }
    const c = andXyz((lo + hi) * rc.half4);
    p.half = andXyz((hi - lo) * rc.half4);
    for (out[0..kept]) |*q| q.* = q.* - c;
    p.off = c + off;
}

/// extremes: the points farthest along 64 directions (each once), into out.
pub fn extremes(pts: []const V4, out: []V4) u32 {
    var n: u32 = 0;
    for (rb_dirs) |dir| {
        var best: f32 = -1e30;
        var bi: usize = 0;
        for (pts, 0..) |q, i| {
            const d = dot3(q, dir);
            if (d > best) {
                best = d;
                bi = i;
            }
        }
        const q = pts[bi];
        var seen = false;
        for (out[0..n]) |k| {
            const ne = k != q; // (cmpneqps: NaN differs)
            if (!(ne[0] or ne[1] or ne[2])) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        out[n] = q;
        n += 1;
    }
    return n;
}

/// mass_props: a closed mesh's volume, centre of volume, second moments about
/// it (tetrahedra from the origin, in doubles) into mp_*; false: no volume.
fn massProps(me: *const MeshView, pts: []const V4) bool {
    var v6: f64 = 0;
    var s1: [3]f64 = .{ 0, 0, 0 };
    var s2: [3]f64 = .{ 0, 0, 0 };
    if (me.tris.len == 0) {
        mp_ok = false;
        return false;
    }
    for (me.tris) |t| {
        var p: [3][3]f64 = undefined;
        for (0..3) |c| {
            const q = pts[t[c]];
            p[c] = .{ lane(q, 0), lane(q, 1), lane(q, 2) };
        }
        var d = p[1][1] * p[2][2];
        d -= p[1][2] * p[2][1];
        d *= p[0][0];
        var e = p[1][2] * p[2][0];
        e -= p[1][0] * p[2][2];
        e *= p[0][1];
        d += e;
        e = p[1][0] * p[2][1];
        e -= p[1][1] * p[2][0];
        e *= p[0][2];
        d += e;
        v6 += d;
        for (0..3) |k| {
            var s = p[0][k];
            s += p[1][k];
            s += p[2][k];
            var q2 = p[0][k] * p[0][k];
            q2 += p[1][k] * p[1][k];
            q2 += p[2][k] * p[2][k];
            q2 += s * s;
            s1[k] += s * d;
            s2[k] += q2 * d;
        }
    }
    const v = v6 / 6.0;
    if (!(@abs(v) > 1.0e-12)) {
        mp_ok = false;
        return false;
    }
    mp_v = @floatCast(v);
    const k24 = 24.0 * v;
    var c: [3]f64 = undefined;
    var mm: [3]f64 = undefined;
    for (0..3) |k| c[k] = s1[k] / k24;
    for (0..3) |k| mm[k] = s2[k] / 120.0;
    for (0..3) |k| {
        var t = c[k] * c[k];
        t *= v;
        mm[k] -= t;
    }
    mp_c = .{ @floatCast(c[0]), @floatCast(c[1]), @floatCast(c[2]), 0 };
    mp_m = .{ @floatCast(mm[0]), @floatCast(mm[1]), @floatCast(mm[2]), 0 };
    mp_ok = true;
    return true;
}

// ---- compounds (decompose) ----------------------------------------------------------------

const Dc = struct {
    me: *const MeshView,
    pts: []V4, // the mesh's points (from the body's centre)
    gath: []V4, // gathered points
    mark: []u32, // a stamp a vertex
    stamp: u32,
    body: u32,
};
var dc: Dc = undefined;

/// decompose: convex parts of the mesh whose points are at vx[pts_at..].
fn decompose(body: u32, me: *const MeshView, pts_at: u32) void {
    const nv: u32 = @intCast(me.verts.len);
    const A = std.heap.page_allocator;
    const mark = A.alloc(u32, nv) catch return;
    defer A.free(mark);
    const list = A.alloc(u32, me.tris.len) catch return;
    defer A.free(list);
    @memset(mark, 0);
    for (list, 0..) |*x, k| x.* = @intCast(k);
    const gat = pts_at + nv + 4; // (after the points, 64 bytes on)
    dc = .{
        .me = me,
        .pts = rc.vx[pts_at..][0..nv],
        .gath = rc.vx[gat..][0..nv],
        .mark = mark,
        .stamp = 0,
        .body = body,
    };
    dcNode(list, 0);
}

fn dcTri(t: u32) [3]V4 {
    const tr = dc.me.tris[t];
    return .{ dc.pts[tr[0]], dc.pts[tr[1]], dc.pts[tr[2]] };
}

/// dc_node: a part of these triangles, or two halves of them.
fn dcNode(list: []u32, depth: u32) void {
    const n = list.len;
    if (n == 0) return;
    dc.stamp +%= 1;
    const st = dc.stamp;
    var ng: usize = 0;
    for (list) |t| {
        for (dc.me.tris[t]) |vi| {
            if (dc.mark[vi] == st) continue;
            dc.mark[vi] = st;
            dc.gath[ng] = dc.pts[vi];
            ng += 1;
        }
    }
    leaf: {
        if (depth >= 4 or n < 12) break :leaf;
        if (rc.npt - rc.bd[dc.body].p0 + 2 > rc.PT_MAXB) break :leaf;
        var hp: [rc.HULL_MAX]V4 = undefined;
        const nh = extremes(dc.gath[0..ng], &hp);
        var lo = rc.big4;
        var hi = rc.nbig4;
        for (hp[0..nh]) |q| {
            lo = minps(lo, q);
            hi = maxps(hi, q);
        }
        const diag = andXyz(hi - lo);
        const thr = @sqrt(dot3(diag, diag)) * rx_conc;
        var worst: f32 = 0;
        for (list) |t| {
            const c = dcTri(t);
            var nn = cross(c[1] - c[0], c[2] - c[0]);
            const l = @sqrt(dot3(nn, nn));
            if (!(l > rx_tiny)) continue;
            nn = andXyz(nn / splat(l));
            const g = andXyz(((c[0] + c[1]) + c[2]) * splat(rx_third));
            const gn = dot3(g, nn);
            var mx: f32 = -1e30;
            var mn: f32 = 1e30;
            for (hp[0..nh]) |q| {
                const d = dot3(q, nn);
                mx = maxss(mx, d);
                mn = minss(mn, d);
            }
            var a = mx - gn;
            const bq = gn - mn;
            a = minss(a, bq);
            worst = maxss(a, worst);
        }
        if (!(worst > thr)) break :leaf;
        // split along the longest side at its middle (by triangle centres)
        var ax: usize = 0;
        var v = lane(diag, 0);
        if (lane(diag, 1) > v) {
            ax = 1;
            v = lane(diag, 1);
        }
        if (lane(diag, 2) > v) ax = 2;
        const mid = (lane(lo, ax) + lane(hi, ax)) * 0.5;
        var i: i64 = 0;
        var j: i64 = @as(i64, @intCast(n)) - 1;
        while (i <= j) {
            const c = dcTri(list[@intCast(i)]);
            var x = lane(c[0], ax) + lane(c[1], ax);
            x += lane(c[2], ax);
            x *= rx_third;
            if (x >= mid) {
                std.mem.swap(u32, &list[@intCast(i)], &list[@intCast(j)]);
                j -= 1;
            } else i += 1;
        }
        const k: usize = @intCast(i);
        if (k == 0 or k >= n) break :leaf;
        dcNode(list[0..k], depth + 1);
        dcNode(list[k..], depth + 1);
        return;
    }
    hullPart(dc.body, dc.gath[0..ng], @splat(0));
}

// ---- a mesh collider: active edges, the triangles' tree -------------------------------------

/// cvtps2dq: round to nearest even; out of range or NaN: 0x80000000.
fn cvtps2dq(x: f32) i32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    var r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) r = 2.0 * @round(x * 0.5);
    return @intFromFloat(r);
}

fn tePoint(b: *const Body, part: u32, corner: u32) V4 {
    const p = &rc.pt[b.p0 + part];
    return andXyz(p.verts.?[corner] + p.off);
}

/// te_key: the edge's ends' places (to 0.1 mm, either way round) hashed; never 0.
fn teKey(b: *const Body, part: u32, edge: u32) u64 {
    const pa = tePoint(b, part, edge) * rx_1e4;
    const pb = tePoint(b, part, if (edge + 1 < 3) edge + 1 else 0) * rx_1e4;
    const a: [3]i32 = .{ cvtps2dq(lane(pa, 0)), cvtps2dq(lane(pa, 1)), cvtps2dq(lane(pa, 2)) };
    const c: [3]i32 = .{ cvtps2dq(lane(pb, 0)), cvtps2dq(lane(pb, 1)), cvtps2dq(lane(pb, 2)) };
    var rax: u64 = @as(u64, @as(u32, @bitCast(a[0]))) | (@as(u64, @as(u32, @bitCast(a[1]))) << 32);
    var rcx: u64 = @as(u64, @as(u32, @bitCast(c[0]))) | (@as(u64, @as(u32, @bitCast(c[1]))) << 32);
    var rdx: u64 = @as(u32, @bitCast(a[2]));
    var r8: u64 = @as(u32, @bitCast(c[2]));
    const swap = if (a[0] != c[0]) a[0] > c[0] else if (a[1] != c[1]) a[1] > c[1] else a[2] > c[2];
    if (swap) {
        std.mem.swap(u64, &rax, &rcx);
        std.mem.swap(u64, &rdx, &r8);
    }
    var hh = rax *% GOLD;
    hh ^= rdx;
    hh *%= GOLD;
    hh ^= rcx;
    hh *%= GOLD;
    hh ^= r8;
    hh *%= GOLD;
    return hh | 1;
}

/// te_normal: the part's face's normal (unit).
fn teNormal(b: *const Body, part: u32) V4 {
    const v = rc.pt[b.p0 + part].verts.?;
    const e1 = andXyz(v[1] - v[0]);
    const e2 = andXyz(v[2] - v[0]);
    const n = cross(e1, e2);
    const l = @sqrt(maxss(dot3(n, n), rx_tiny2));
    return n / splat(l);
}

const TeEntry = struct { key: u64, part: u32, edge: u32 };

/// tri_edges: an edge shared with a neighbour in the same plane (within 5
/// degrees) is not active (contacts there take the face's normal).
pub fn triEdges(b: *Body) void {
    var x: u32 = (b.np *% 6) | 63;
    const bits: u5 = @intCast(32 - @clz(x));
    x = (@as(u32, 1) << bits);
    const mask = x - 1;
    const A = std.heap.page_allocator;
    const tab = A.alloc(TeEntry, x) catch return;
    defer A.free(tab);
    @memset(tab, .{ .key = 0, .part = 0, .edge = 0 });
    var p: u32 = 0;
    while (p < b.np) : (p += 1) {
        var e: u32 = 0;
        while (e < 3) : (e += 1) {
            const key = teKey(b, p, e);
            var s: u32 = @as(u32, @truncate(key >> 20)) & mask;
            while (true) {
                if (tab[s].key == 0) {
                    tab[s] = .{ .key = key, .part = p, .edge = e };
                    break;
                }
                if (tab[s].key == key) {
                    const n1 = teNormal(b, p);
                    const n2 = teNormal(b, tab[s].part);
                    const d = @abs(dot3(n2, n1));
                    if (d >= rx_cos5) {
                        const o = tab[s];
                        rc.pt[b.p0 + o.part].flg &= ~(@as(u32, 2) << @intCast(o.edge));
                        rc.pt[b.p0 + p].flg &= ~(@as(u32, 2) << @intCast(e));
                    }
                    break;
                }
                s = (s + 1) & mask;
            }
        }
    }
}

inline fn nodeLo(n: *const BvNode) V4 {
    return .{ n.min[0], n.min[1], n.min[2], @bitCast(n.left) };
}
inline fn nodeHi(n: *const BvNode) V4 {
    return .{ n.max[0], n.max[1], n.max[2], @bitCast(n.right) };
}
inline fn setNode(n: *BvNode, lo: V4, hi: V4) void {
    n.* = .{ .min = .{ lane(lo, 0), lane(lo, 1), lane(lo, 2) }, .left = @bitCast(lane(lo, 3)), .max = .{ lane(hi, 0), lane(hi, 1), lane(hi, 2) }, .right = @bitCast(lane(hi, 3)) };
}

/// part_bounds: a part's bounds (world, with the margin and a step's travel).
pub fn partBounds(b: *const Body, part: u32, out: *BvNode) void {
    const p = &rc.pt[part];
    if (p.typ == 2) {
        setNode(out, rc.nbig4, rc.big4);
        return;
    }
    const c = rc.mv3(&b.r, p.off) + b.pos;
    const e = andXyz(splat(p.rad)) + p.half;
    var ext: V4 = .{ dot3(rc.abs3(b.r[0]), e), dot3(rc.abs3(b.r[1]), e), dot3(rc.abs3(b.r[2]), e), 0 };
    ext += rc.marg4;
    ext += andXyz(rc.abs3(b.v) * splat(rc.dt));
    setNode(out, c - ext, c + ext);
}

/// bvh_build: a tree of the body's parts (a mesh's triangles).
pub fn bvhBuild(idx: u32) void {
    const b = &rc.bd[idx];
    const start = rc.nbvi;
    var k: u32 = 0;
    while (k < b.np) : (k += 1) {
        const part = b.p0 + k;
        rc.bvi[start + k] = part;
        partBounds(b, part, &rc.bvb[start + k]);
        twMake(b, part, start + k);
    }
    rc.nbvi += b.np;
    b.bvh = bvhNode(start, b.np) + 1;
}

/// tw_make: the triangle's corners in the world into tvw (the body is static).
fn twMake(b: *const Body, part: u32, slot: u32) void {
    const p = &rc.pt[part];
    p.tw = slot;
    for (0..3) |c| {
        const q = andXyz(p.verts.?[c] + p.off);
        rc.tvw[slot * 3 + c] = andXyz(rc.mv3(&b.r, q) + b.pos);
    }
}

/// bvh_node: a node for those triangles (four or fewer: a leaf).
fn bvhNode(first: u32, count: u32) u32 {
    const node = rc.nbvh;
    rc.nbvh += 1;
    var lo = rc.big4;
    var hi = rc.nbig4;
    var clo = rc.big4;
    var chi = rc.nbig4;
    var c: u32 = 0;
    while (c < count) : (c += 1) {
        const e = &rc.bvb[first + c];
        const a = nodeLo(e);
        const z = nodeHi(e);
        lo = minps(lo, a);
        hi = maxps(hi, z);
        const s = a + z;
        clo = minps(clo, s);
        chi = maxps(chi, s);
    }
    setNode(&rc.bvh[node], lo, hi);
    if (count <= 4) {
        rc.bvh[node].left = first | 0x80000000;
        rc.bvh[node].right = count;
        return node;
    }
    const ext = chi - clo;
    var ax: usize = 0;
    var v = lane(ext, 0);
    if (lane(ext, 1) > v) {
        v = lane(ext, 1);
        ax = 1;
    }
    if (lane(ext, 2) > v) ax = 2;
    var mid = lane(clo, ax) + lane(chi, ax);
    mid *= 0.5;
    var i = first;
    var d = first + count;
    while (i < d) {
        const e = &rc.bvb[i];
        const s = e.min[ax] + e.max[ax];
        if (s >= mid) {
            d -= 1;
            std.mem.swap(BvNode, &rc.bvb[i], &rc.bvb[d]);
            std.mem.swap(u32, &rc.bvi[i], &rc.bvi[d]);
        } else i += 1;
    }
    var below = i - first;
    if (below == 0 or below >= count) below = count >> 1;
    const l = bvhNode(first, below);
    rc.bvh[node].left = l;
    const r = bvhNode(first + below, count - below);
    rc.bvh[node].right = r;
    return node;
}

// ---- joints -------------------------------------------------------------------------------

/// make_joints: the joints' runtime records.
pub fn makeJoints() void {
    uhBuild();
    const blk = @import("anim.zig").cur orelse return;
    const njt = @min(blk.h.njt, @as(u32, @intCast(blk.jt.len / rc.JT_SZ)));
    var k: u32 = 0;
    while (k < njt) : (k += 1) {
        const r = blk.jt[k * rc.JT_SZ ..][0..rc.JT_SZ];
        if (rc.rdU(r, rc.JT_TYPE) == 5) {
            @import("rbimp.zig").register(r); // shatter on impact: a group, no rows
            continue;
        }
        const ia = bodyOfUid(rc.rdU(r, rc.JT_A)) orelse continue;
        var ibb: u32 = rc.nb - 1; // B: the world, or a body
        const ub = rc.rdU(r, rc.JT_B);
        if (ub != 0) ibb = bodyOfUid(ub) orelse continue;
        if (ibb == ia) continue;
        const j = &rc.jr[rc.njr];
        rc.njr += 1;
        j.* = .{};
        j.a = ia;
        j.b = ibb;
        j.typ = rc.rdU(r, rc.JT_TYPE);
        j.brk = rc.rdF(r, rc.JT_BRK);
        j.lo = rc.rdF(r, rc.JT_LO);
        j.hi = rc.rdF(r, rc.JT_HI);
        j.ms = rc.rdF(r, rc.JT_MSPD);
        j.mf = rc.rdF(r, rc.JT_MFOR);
        j.fl = rc.rdU(r, rc.JT_FLG) & 3;
        j.imp = .{ 0, 0, 0 };
        j.wl = @splat(0);
        j.wa = @splat(0);
        jhPut(ia, ibb, rc.njr - 1);
        const A = &rc.bd[ia];
        const B = &rc.bd[ibb];
        A.joint = 1;
        B.joint = 1;
        if (A.typ == 3 or B.typ == 3) j.fl |= 12; // (a dormant piece's: asleep)
        const piv = rc.rdV3(r, rc.JT_PIV);
        j.la = andXyz(rc.mtv3(&A.r, piv - A.pos));
        j.lb = andXyz(rc.mtv3(&B.r, piv - B.pos));
        var ax = rc.rdV3(r, rc.JT_AXIS);
        var d = dot3(ax, ax);
        if (!(d > rx_tiny)) {
            ax = rc.ident[1];
            d = 1.0;
        }
        ax = andXyz(ax / splat(@sqrt(d)));
        j.axa = andXyz(rc.mtv3(&A.r, ax));
        j.axb = andXyz(rc.mtv3(&B.r, ax));
        j.q0 = rc.qMul(rc.qConj(B.q), A.q);
    }
}

fn uhSlot(key: u32) u32 {
    return ((key *% 0x9E3779B1) >> 18) & (UH_N - 1);
}

/// body_of_uid: the body of the object (its oid in the port), or null.
pub fn bodyOfUid(oid: u32) ?u32 {
    const key = oid +% 1;
    var s = uhSlot(key);
    while (true) {
        const e = rc.uh[s];
        const k: u32 = @truncate(e);
        if (k == 0) return null;
        if (k == key) return @truncate(e >> 32);
        s = (s + 1) & (UH_N - 1);
    }
}

/// uh_build: each body's object -> the body (objects, not instances: the first body of an object).
pub fn uhBuild() void {
    var i: u32 = 0;
    while (i + 1 < rc.nb) : (i += 1) {
        const b = &rc.bd[i];
        if (b.inst != 0 or b.obj == 0) continue;
        const key = b.obj +% 1;
        var s = uhSlot(key);
        while (true) {
            const k: u32 = @truncate(rc.uh[s]);
            if (k == 0) {
                rc.uh[s] = @as(u64, key) | (@as(u64, i) << 32);
                break;
            }
            if (k == key) break;
            s = (s + 1) & (UH_N - 1);
        }
    }
}

/// jh_key: (lower << 32 | higher) + 1.
pub fn jhKey(a: u32, b: u32) u64 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    return ((@as(u64, lo) << 32) | hi) +% 1;
}
fn jhSlot(key: u64) u32 {
    return @as(u32, @truncate((key *% 0xFFFFFFFF9E3779B1) >> 17)) & (JH_N - 1);
}
/// jh_find: the joint the pair was put with, or null.
pub fn jhFind(key: u64) ?u32 {
    var s = jhSlot(key);
    while (true) {
        const k = rc.jh[s];
        if (k == 0) return null;
        if (k == key) return rc.jhv[s];
        s = (s + 1) & (JH_N - 1);
    }
}
/// jh_put: the pair into jh (the first joint of a pair kept).
pub fn jhPut(a: u32, b: u32, joint: u32) void {
    const key = jhKey(a, b);
    var s = jhSlot(key);
    while (true) {
        const k = rc.jh[s];
        if (k == 0) {
            rc.jh[s] = key;
            rc.jhv[s] = joint;
            return;
        }
        if (k == key) return;
        s = (s + 1) & (JH_N - 1);
    }
}
/// jointed: the two bodies share a joint that is not broken.
pub fn jointed(a: u32, b: u32) bool {
    const j = jhFind(jhKey(a, b)) orelse return false;
    return rc.jr[j].fl & 4 == 0;
}

// ---- tests ------------------------------------------------------------------------------------

const TestWorld = struct {
    bd: [4]Body = @splat(.{}),
    pt: [64]Part = @splat(.{}),
    vx: [8192]V4 = @splat(@splat(0)),
    bvh: [256]BvNode = @splat(.{}),
    bvi: [256]u32 = @splat(0),
    bvb: [256]BvNode = @splat(.{}),
    tvw: [768]V4 = @splat(@splat(0)),

    fn use(w: *TestWorld) void {
        rc.bd = &w.bd;
        rc.pt = &w.pt;
        rc.vx = &w.vx;
        rc.bvh = &w.bvh;
        rc.bvi = &w.bvi;
        rc.bvb = &w.bvb;
        rc.tvw = &w.tvw;
        rc.npt = 0;
        rc.nvx = 0;
        rc.nbvh = 0;
        rc.nbvi = 0;
        rc.nb = 4;
        rc.dt = 1.0 / 120.0;
    }
};

const cube_v = [_][3]f32{ .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 }, .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } };
const cube_t = [_][3]u32{
    .{ 0, 2, 1 }, .{ 0, 3, 2 }, .{ 4, 5, 6 }, .{ 4, 6, 7 }, .{ 0, 1, 5 }, .{ 0, 5, 4 },
    .{ 2, 3, 7 }, .{ 2, 7, 6 }, .{ 1, 2, 6 }, .{ 1, 6, 5 }, .{ 0, 4, 7 }, .{ 0, 7, 3 },
};

fn testRec(typ: u32, shape: u32, mass: f32) [rc.RB_SZ]u8 {
    var r: [rc.RB_SZ]u8 = @splat(0);
    rc.wrU(&r, rc.RB_TYPE, typ);
    rc.wrU(&r, rc.RB_SHAPE, shape);
    rc.wrF(&r, rc.RB_MASS, mass);
    return r;
}

test "hull of a cube keeps its 8 corners; mass_props of a 2 m cube" {
    const w = try std.testing.allocator.create(TestWorld);
    defer std.testing.allocator.destroy(w);
    w.* = .{};
    w.use();
    const mv = MeshView{ .verts = &cube_v, .tris = &cube_t, .lo = .{ -1, -1, -1 }, .hi = .{ 1, 1, 1 } };
    const rec = testRec(1, 3, 8);
    makeBodyEx(0, &rec, 1, &mv, &rc.ident, @splat(0), rc.one4);
    const b = &rc.bd[0];
    try std.testing.expectEqual(@as(u32, 1), b.np);
    try std.testing.expectEqual(@as(u32, 8), rc.pt[0].nv);
    try std.testing.expectApproxEqAbs(@as(f32, 8), mp_v, 1e-5);
    // a 2 m cube of 8 kg: I = m (h^2 + h^2) / 3 = 8 x 2 / 3; inverse 3/16
    try std.testing.expectApproxEqAbs(@as(f32, 3.0 / 16.0), b.iil[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), b.im, 1e-7);
}

test "a box: inertia of its bounds; a sphere: 2/5 m r^2" {
    const w = try std.testing.allocator.create(TestWorld);
    defer std.testing.allocator.destroy(w);
    w.* = .{};
    w.use();
    const mv = MeshView{ .verts = &cube_v, .tris = &cube_t, .lo = .{ -1, -1, -1 }, .hi = .{ 1, 1, 1 } };
    var rec = testRec(1, 0, 6);
    makeBodyEx(0, &rec, 1, &mv, &rc.ident, @splat(0), rc.one4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), rc.bd[0].iil[1], 1e-6); // 1 / (6 x 2 / 3)
    rec = testRec(1, 1, 5);
    makeBodyEx(1, &rec, 2, &mv, &rc.ident, @splat(0), rc.one4);
    try std.testing.expectEqual(@as(f32, 1), rc.pt[rc.bd[1].p0].rad);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rc.bd[1].iil[2], 1e-6); // 1 / (0.4 x 5)
    // a thin passive floor goes deep below its top
    const flat = MeshView{ .verts = &cube_v, .tris = &cube_t, .lo = .{ -5, 0, -5 }, .hi = .{ 5, 0.02, 5 } };
    rec = testRec(2, 0, 1);
    makeBodyEx(2, &rec, 3, &flat, &rc.ident, @splat(0), rc.one4);
    try std.testing.expectEqual(@as(f32, 0.25), rc.pt[rc.bd[2].p0].half[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.02 - 0.25), rc.bd[2].pos[1], 1e-6);
}

test "decompose: an L shape gives more than one part" {
    const w = try std.testing.allocator.create(TestWorld);
    defer std.testing.allocator.destroy(w);
    w.* = .{};
    w.use();
    // an L: a grid of unit cubes' boundary, 4 long along X, 4 up along Y at x 0
    var verts: std.ArrayList([3]f32) = .empty;
    defer verts.deinit(std.testing.allocator);
    var tris: std.ArrayList([3]u32) = .empty;
    defer tris.deinit(std.testing.allocator);
    const cells = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 3, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 } };
    for (cells) |c| {
        const base: u32 = @intCast(verts.items.len);
        for (cube_v) |v| try verts.append(std.testing.allocator, .{ c[0] + (v[0] + 1) * 0.5, c[1] + (v[1] + 1) * 0.5, (v[2] + 1) * 0.5 });
        for (cube_t) |t| try tris.append(std.testing.allocator, .{ t[0] + base, t[1] + base, t[2] + base });
    }
    const mv = MeshView{ .verts = verts.items, .tris = tris.items, .lo = .{ 0, 0, 0 }, .hi = .{ 4, 4, 1 } };
    const rec = testRec(1, 4, 1);
    makeBodyEx(0, &rec, 1, &mv, &rc.ident, @splat(0), rc.one4);
    try std.testing.expect(rc.bd[0].np > 1);
    try std.testing.expect(rc.bd[0].np <= rc.PT_MAXB);
}

test "a mesh collider: flat neighbours' shared edges go inactive; its tree" {
    const w = try std.testing.allocator.create(TestWorld);
    defer std.testing.allocator.destroy(w);
    w.* = .{};
    w.use();
    const mv = MeshView{ .verts = &cube_v, .tris = &cube_t, .lo = .{ -1, -1, -1 }, .hi = .{ 1, 1, 1 } };
    const rec = testRec(2, 5, 1);
    makeBodyEx(0, &rec, 1, &mv, &rc.ident, @splat(0), rc.one4);
    const b = &rc.bd[0];
    try std.testing.expectEqual(@as(u32, 12), b.np);
    // each face's diagonal is shared by two coplanar triangles: one edge of each off
    for (0..12) |k| {
        const f = rc.pt[b.p0 + k].flg;
        try std.testing.expectEqual(@as(u32, 1), f & 1);
        try std.testing.expectEqual(@as(u32, 2), @popCount(f & 14));
    }
    try std.testing.expect(b.bvh != 0);
    try std.testing.expectEqual(@as(u32, 12), rc.nbvi);
}

test "joint pairs and uid hashes" {
    var jh: [JH_N]u64 = @splat(0);
    var jhv: [JH_N]u32 = @splat(0);
    var jr: [2]rc.Joint = @splat(.{});
    rc.jh = &jh;
    rc.jhv = &jhv;
    rc.jr = &jr;
    jhPut(3, 1, 0);
    jhPut(1, 3, 1);
    try std.testing.expectEqual(@as(?u32, 0), jhFind(jhKey(1, 3)));
    try std.testing.expect(jointed(3, 1));
    jr[0].fl = 4;
    try std.testing.expect(!jointed(1, 3));
    try std.testing.expectEqual(@as(?u32, null), jhFind(jhKey(2, 3)));
    try std.testing.expectEqual(@as(i32, 2), cvtps2dq(2.5));
    try std.testing.expectEqual(@as(i32, -4), cvtps2dq(-3.5));
    try std.testing.expectEqual(std.math.minInt(i32), cvtps2dq(std.math.nan(f32)));
}

test {
    std.testing.refAllDecls(@This());
}
