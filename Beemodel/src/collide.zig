// Convex collision (collide.s): support functions, GJK, EPA.
//
// A part (of a rigid body, rbcore.Part) is a convex core plus a radius: a box
// core (half extents; a sphere is a box of size 0, a capsule a box of half
// height along Y) or a hull (its points). A proxy places a part in the world:
// the body's rotation rows, the part's centre.
//
// collide(A, B) runs GJK on the cores' Minkowski difference A - B. When they
// are apart it gives the closest points (the distance less the radii is the
// separation); when the cores overlap, EPA expands the simplex to the face of
// A - B nearest the origin (the depth and normal). The result: the separation
// (negative when they overlap), a point on each surface and the normal from A
// to B. Re-entrant: all its memory is on the stack, so workers collide pairs
// in parallel.
//
// Every number goes through the original's single-precision operations in
// its order (DOT3 = dpps 0x71; comparisons keep comiss's NaN outcomes).
const std = @import("std");
const rc = @import("rbcore.zig");

const V4 = rc.V4;
const Part = rc.Part;
const Proxy = rc.Proxy;
const Hit = rc.Hit;
const dot3 = rc.dot3;
const cross = rc.cross;
const splat = rc.splat;
const andXyz = rc.andXyz;

const axes = [6]V4{
    .{ 1, 0, 0, 0 },  .{ 0, 1, 0, 0 },  .{ 0, 0, 1, 0 },
    .{ -1, 0, 0, 0 }, .{ 0, -1, 0, 0 }, .{ 0, 0, -1, 0 },
};
const ONE: f32 = 1.0;
const TINY: f32 = 1.0e-12;
const EPS: f32 = 1.0e-6;
const EPA_TOL: f32 = 1.0e-4;
const DUP: f32 = 1.0e-10;
const SMALL: f32 = 1.0e-8;
const BIG: f32 = 3.0e38;
const zero4: V4 = @splat(0);

/// xorps cx_sign: x y z negated.
const neg3 = rc.neg3;
/// andps cx_absm: every lane's sign cleared.
fn absS(x: f32) f32 {
    return @bitCast(@as(u32, @bitCast(x)) & 0x7fffffff);
}

// ---- supports ------------------------------------------------------------------------

/// part_support: the core's farthest point along d (part-local).
pub fn partSupport(p: *const Part, d: V4) V4 {
    if (p.typ != 1) {
        // a box: the half extents, signed (andps cx_sign, orps half)
        const s: @Vector(4, u32) = @bitCast(d);
        const hb: @Vector(4, u32) = @bitCast(p.half);
        return @bitCast((s & @Vector(4, u32){ 0x80000000, 0x80000000, 0x80000000, 0 }) | hb);
    }
    const vs = p.verts.?;
    var best = vs[0];
    var bd = dot3(best, d);
    var k: u32 = 1;
    while (k < p.nv) : (k += 1) {
        const x = dot3(vs[k], d);
        if (x > bd) {
            bd = x;
            best = vs[k];
        }
    }
    return best;
}

/// proxy_support: the world point farthest along d (world).
pub fn proxySupport(px: *const Proxy, d: V4) V4 {
    const local = andXyz(rc.mtv3(&px.r, d));
    const s = partSupport(px.part.?, local);
    return rc.mv3(&px.r, s) + px.c;
}

/// px_place: the proxy of a part of a body (its rotation rows, its position).
pub fn pxPlace(px: *Proxy, rows: *const [3]V4, pos: V4, part: *const Part) void {
    px.r = rows.*;
    px.part = part;
    px.c = andXyz(rc.mv3(rows, part.off) + pos);
}

// ---- the simplex -----------------------------------------------------------------------

/// tri_closest's / seg_closest's out (TC_*).
pub const Closest = struct {
    v: V4 = zero4,
    u: [3]f32 = .{ 0, 0, 0 },
    mask: u32 = 0,
};

const Simplex = struct {
    n: u32 = 0,
    pa: *const Proxy,
    pb: *const Proxy,
    w: [4]V4 = @splat(zero4), // A - B
    a: [4]V4 = @splat(zero4), // A's point
    b: [4]V4 = @splat(zero4), // B's point
    l: [4]f32 = @splat(0), // barycentric weights
    v: V4 = zero4, // the closest point to the origin
    t: Closest = .{},
    t2: Closest = .{},
    best_d: f32 = 0, // (GJ_T2+60)
    best_f: i32 = 0, // (GJ_T2+56)
};

/// gj_support: A's point along d, B's along -d, their difference, into the slot.
fn gjSupport(s: *Simplex, slot: u32, d: V4) V4 {
    const pa = proxySupport(s.pa, d);
    s.a[slot] = pa;
    const pb = proxySupport(s.pb, neg3(d));
    s.b[slot] = pb;
    const w = pa - pb;
    s.w[slot] = w;
    return w;
}

/// seg_closest: the segment's closest point to the origin, its weights, mask.
pub fn segClosest(a: V4, b: V4, out: *Closest) void {
    const ab = b - a;
    const d = dot3(a, ab);
    const l2 = dot3(ab, ab);
    var t = 0.0 - d;
    if (!(t > 0)) {
        out.v = a;
        out.u[0] = ONE;
        out.mask = 1;
        return;
    }
    if (t >= l2) {
        out.v = b;
        out.u[1] = ONE;
        out.mask = 2;
        return;
    }
    t = t / l2;
    out.v = splat(t) * ab + a;
    out.u[0] = ONE - t;
    out.u[1] = t;
    out.mask = 3;
}

/// tri_closest: Ericson's regions: the closest point of the triangle to the
/// origin, its weights, the vertices that make it.
pub fn triClosest(a: V4, b: V4, c: V4, out: *Closest) void {
    const ab = b - a;
    const ac = c - a;
    var ap = zero4 - a;
    const d1 = dot3(ab, ap);
    const d2 = dot3(ac, ap);
    if (!(d1 > 0) and !(d2 > 0)) {
        out.v = a;
        out.u = .{ ONE, 0, 0 };
        out.mask = 1;
        return;
    }
    ap = zero4 - b;
    const d3 = dot3(ab, ap);
    const d4 = dot3(ac, ap);
    if (d3 >= 0 and !(d4 > d3)) {
        out.v = b;
        out.u = .{ 0, ONE, 0 };
        out.mask = 2;
        return;
    }
    const vc = d1 * d4 - d3 * d2;
    if (!(vc > 0) and d1 >= 0 and !(d3 > 0)) {
        const v = d1 / (d1 - d3);
        out.v = splat(v) * ab + a;
        out.u = .{ ONE - v, v, 0 };
        out.mask = 3;
        return;
    }
    ap = zero4 - c;
    const d5 = dot3(ab, ap);
    const d6 = dot3(ac, ap);
    if (d6 >= 0 and !(d5 > d6)) {
        out.v = c;
        out.u = .{ 0, 0, ONE };
        out.mask = 4;
        return;
    }
    const vb = d5 * d2 - d1 * d6;
    if (!(vb > 0) and d2 >= 0 and !(d6 > 0)) {
        const w = d2 / (d2 - d6);
        out.v = splat(w) * ac + a;
        out.u = .{ ONE - w, 0, w };
        out.mask = 5;
        return;
    }
    const va = d3 * d6 - d5 * d4;
    if (!(va > 0)) {
        const e3 = d4 - d3;
        if (e3 >= 0) {
            const e4 = d5 - d6;
            if (e4 >= 0) {
                const w = e3 / (e4 + e3);
                out.v = (c - b) * splat(w) + b;
                out.u = .{ 0, ONE - w, w };
                out.mask = 6;
                return;
            }
        }
    }
    var den = (va + vb) + vc;
    if (!(den > TINY)) den = TINY;
    const inv = ONE / den;
    const v = vb * inv;
    const w = vc * inv;
    out.u = .{ (ONE - v) - w, v, w };
    out.v = (splat(v) * ab + splat(w) * ac) + a;
    out.mask = 7;
}

/// sx_apply: keep the vertices the mask names (slots: a | b << 8 | c << 16),
/// with their weights; V = out's point.
fn sxApply(s: *Simplex, out: *const Closest, slots: u32) void {
    var w: [3]V4 = undefined;
    var a: [3]V4 = undefined;
    var b: [3]V4 = undefined;
    var l: [3]f32 = undefined;
    var kept: u32 = 0;
    for (0..3) |i| {
        if (out.mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const sl = (slots >> @intCast(i * 8)) & 0xff;
        w[kept] = s.w[sl];
        a[kept] = s.a[sl];
        b[kept] = s.b[sl];
        l[kept] = out.u[i];
        kept += 1;
    }
    s.n = kept;
    for (0..kept) |i| {
        s.w[i] = w[i];
        s.a[i] = a[i];
        s.b[i] = b[i];
        s.l[i] = l[i];
    }
    s.v = andXyz(out.v);
}

const tet_faces = [4]u32{ 0x03020100, 0x02030100, 0x01030200, 0x00030201 };

/// sx_solve: true when the simplex holds the origin; else it is cut to the
/// vertices of its closest feature, V that point.
fn sxSolve(s: *Simplex) bool {
    switch (s.n) {
        1 => {
            s.v = s.w[0];
            s.l[0] = ONE;
            return false;
        },
        2 => {
            segClosest(s.w[0], s.w[1], &s.t);
            sxApply(s, &s.t, 0x0100);
            return false;
        },
        3 => {
            triClosest(s.w[0], s.w[1], s.w[2], &s.t);
            sxApply(s, &s.t, 0x020100);
            return false;
        },
        else => {},
    }
    // a tetrahedron: each face with the origin outside it, the nearest
    s.best_d = std.math.floatMax(f32);
    s.best_f = -1;
    for (tet_faces, 0..) |f, fi| {
        const a = s.w[f & 0xff];
        const ab = s.w[(f >> 8) & 0xff] - a;
        const ac = s.w[(f >> 16) & 0xff] - a;
        const n = cross(ab, ac);
        var x4 = dot3(s.w[(f >> 24) & 0xff] - a, n);
        const x5 = dot3(zero4 - a, n);
        x4 *= x5;
        if (x4 > 0) continue; // the origin and d apart (or flat)
        if (x5 == 0) continue; // (on its plane: inside as far as it goes)
        triClosest(a, s.w[(f >> 8) & 0xff], s.w[(f >> 16) & 0xff], &s.t);
        const d = dot3(s.t.v, s.t.v);
        if (d >= s.best_d) continue;
        s.best_d = d;
        s.best_f = @intCast(fi);
        s.t2 = s.t;
    }
    if (s.best_f < 0) return true;
    sxApply(s, &s.t2, tet_faces[@intCast(s.best_f)] & 0xffffff);
    return false;
}

/// gjk: true when the cores overlap; else V the closest point of A - B to the
/// origin, the simplex its feature.
fn gjk(s: *Simplex) bool {
    var d = s.pa.c - s.pb.c;
    if (!(dot3(d, d) > SMALL)) d = axes[0];
    const w0 = gjSupport(s, 0, d);
    s.n = 1;
    s.v = w0;
    s.l[0] = ONE;
    var it: u32 = 64;
    while (true) {
        const vv = dot3(s.v, s.v);
        if (!(vv > TINY)) return true;
        const w = gjSupport(s, s.n, neg3(s.v));
        const vw = dot3(s.v, w);
        if (!(vv - vw > vv * EPS)) return false;
        for (0..s.n) |k| {
            const e = s.w[k] - w;
            if (!(dot3(e, e) > DUP)) return false;
        }
        s.n += 1;
        if (sxSolve(s)) return true;
        it -= 1;
        if (it == 0) return false;
    }
}

/// gj_witness: sum of weights x points.
fn gjWitness(s: *const Simplex, pa: *V4, pb: *V4) void {
    var x = zero4;
    var y = zero4;
    for (0..s.n) |k| {
        const l = splat(s.l[k]);
        x += s.a[k] * l;
        y += s.b[k] * l;
    }
    pa.* = andXyz(x);
    pb.* = andXyz(y);
}

// ---- EPA -------------------------------------------------------------------------------

const EP_MAXV = 64;
const EP_MAXF = 128;

const Face = struct {
    i: [3]u32,
    dead: u32,
    n: V4, // normal xyz, distance in w
};

const Poly = struct {
    vw: [EP_MAXV]V4 = undefined,
    va: [EP_MAXV]V4 = undefined,
    vb: [EP_MAXV]V4 = undefined,
    f: [EP_MAXF]Face = undefined,
    e: [EP_MAXF][2]u32 = undefined,
    nv: u32 = 0,
    nf: u32 = 0,
    ne: u32 = 0,
};

/// ep_face: a face, its outward normal and distance (no room: nothing).
fn epFace(p: *Poly, i: u32, j: u32, k: u32) void {
    if (p.nf >= EP_MAXF) return;
    const f = &p.f[p.nf];
    p.nf += 1;
    f.i = .{ i, j, k };
    f.dead = 0;
    const a = p.vw[i];
    var n = cross(p.vw[j] - a, p.vw[k] - a);
    const l = rc.maxss(@sqrt(dot3(n, n)), TINY);
    n = andXyz(n / splat(l));
    const d = dot3(n, a);
    f.n = .{ n[0], n[1], n[2], d };
}

/// ep_edge: the horizon: an edge, or its reverse gone when it is there.
fn epEdge(p: *Poly, i: u32, j: u32) void {
    var c: u32 = 0;
    while (c < p.ne) : (c += 1) {
        if (p.e[c][0] == j and p.e[c][1] == i) {
            p.ne -= 1;
            p.e[c] = p.e[p.ne];
            return;
        }
    }
    if (c >= EP_MAXF) return;
    p.e[c] = .{ i, j };
    p.ne += 1;
}

/// ep_nearest: the live face nearest the origin, or null.
fn epNearest(p: *const Poly) ?u32 {
    var best: ?u32 = null;
    var bd: f32 = BIG;
    for (0..p.nf) |c| {
        const d = p.f[c].n[3];
        if (d >= bd) continue;
        bd = d;
        best = @intCast(c);
    }
    return best;
}

/// ep_support: the new point (w) along d, stored with a and b.
fn epSupport(p: *Poly, s: *const Simplex, slot: u32, d: V4) V4 {
    const pa = proxySupport(s.pa, d);
    p.va[slot] = pa;
    const pb = proxySupport(s.pb, neg3(d));
    p.vb[slot] = pb;
    const w = pa - pb;
    p.vw[slot] = w;
    return w;
}

/// ep_grow: true when the simplex is (made) a tetrahedron with volume.
fn epGrow(s: *Simplex) bool {
    if (s.n == 1) { // a point: any other point
        var k: u32 = 0;
        while (true) {
            if (k >= 6) return false;
            const w = gjSupport(s, 1, axes[k]);
            const e = w - s.w[0];
            k += 1;
            if (dot3(e, e) > SMALL) break;
        }
        s.n = 2;
    }
    if (s.n == 2) { // a segment: square to it
        const seg = s.w[1] - s.w[0];
        var k: u32 = 0;
        while (true) {
            if (k >= 6) return false;
            const c = cross(seg, axes[k]);
            k += 1;
            if (!(dot3(c, c) > SMALL)) continue;
            const w = gjSupport(s, 2, c);
            const c2 = cross(w - s.w[0], seg);
            if (!(dot3(c2, c2) > SMALL)) continue;
            break;
        }
        s.n = 3;
    }
    if (s.n == 3) { // a triangle: along its normal
        var n = cross(s.w[1] - s.w[0], s.w[2] - s.w[0]);
        var tries: u32 = 2;
        while (true) {
            const w = gjSupport(s, 3, n);
            if (absS(dot3(w - s.w[0], n)) > SMALL) break;
            n = neg3(n);
            tries -= 1;
            if (tries == 0) return false;
        }
        s.n = 4;
    }
    const n = cross(s.w[1] - s.w[0], s.w[2] - s.w[0]);
    return absS(dot3(n, s.w[3] - s.w[0])) > TINY;
}

/// epa: true when found: out's normal (A to B), depth (sep, positive), witness points.
fn epa(s: *Simplex, out: *Hit) bool {
    var p: Poly = .{};
    if (!epGrow(s)) return false;
    p.nv = 4;
    p.nf = 0;
    for (0..4) |c| {
        p.vw[c] = s.w[c];
        p.va[c] = s.a[c];
        p.vb[c] = s.b[c];
    }
    // faces, wound outward (away from the fourth vertex)
    for (tet_faces) |f| {
        const i = f & 0xff;
        const j = (f >> 8) & 0xff;
        const k = (f >> 16) & 0xff;
        const o = f >> 24;
        epFace(&p, i, j, k);
        const fl = &p.f[p.nf - 1];
        if (dot3(p.vw[o] - p.vw[i], fl.n) > 0) {
            p.nf -= 1;
            epFace(&p, i, k, j);
        }
    }
    var it: u32 = 48;
    var fi: u32 = undefined;
    while (true) {
        fi = epNearest(&p) orelse return false;
        const fn_ = p.f[fi].n;
        const dir = andXyz(fn_);
        if (p.nv >= EP_MAXV) break;
        const w = epSupport(&p, s, p.nv, dir);
        const gain = dot3(w, dir) - fn_[3];
        if (!(gain > EPA_TOL)) break;
        it -= 1;
        if (it == 0) break;
        const nw = p.nv;
        p.nv += 1;
        p.ne = 0;
        for (0..p.nf) |c| {
            const f = &p.f[c];
            if (f.dead != 0) continue;
            if (!(dot3(p.vw[nw] - p.vw[f.i[0]], f.n) > 0)) continue;
            f.dead = 1;
            epEdge(&p, f.i[0], f.i[1]);
            epEdge(&p, f.i[1], f.i[2]);
            epEdge(&p, f.i[2], f.i[0]);
        }
        var k: u32 = 0;
        for (0..p.nf) |c| {
            if (p.f[c].dead != 0) continue;
            p.f[k] = p.f[c];
            k += 1;
        }
        p.nf = k;
        for (0..p.ne) |c| epFace(&p, p.e[c][0], p.e[c][1], nw);
    }
    // the face's point: its weights
    const f = p.f[fi];
    const depth = f.n[3];
    const n = andXyz(f.n);
    out.n = n;
    out.sep = depth;
    const pp = andXyz(splat(depth) * n);
    const a = p.vw[f.i[0]];
    const b = p.vw[f.i[1]];
    const c = p.vw[f.i[2]];
    var u = dot3(cross(b - pp, c - pp), n);
    var v = dot3(cross(c - pp, a - pp), n);
    var w = dot3(cross(a - pp, b - pp), n);
    var sum = (u + v) + w;
    if (!(absS(sum) > TINY)) { // (degenerate: the first vertex)
        sum = ONE;
        u = sum;
        v = 0;
        w = 0;
    }
    const inv = ONE / sum;
    u *= inv;
    v *= inv;
    w *= inv;
    out.pa = andXyz((p.va[f.i[0]] * splat(u) + p.va[f.i[1]] * splat(v)) + p.va[f.i[2]] * splat(w));
    out.pb = andXyz((p.vb[f.i[0]] * splat(u) + p.vb[f.i[1]] * splat(v)) + p.vb[f.i[2]] * splat(w));
    return true;
}

// ---- exact pairs -----------------------------------------------------------------------

/// cx_sphere: a box core of no size, a radius.
fn cxSphere(p: *const Part) bool {
    if (p.typ != 0) return false;
    if (p.rad == 0 or std.math.isNan(p.rad)) return false;
    const hv = andXyz(p.half);
    inline for (0..4) |k| {
        if (hv[k] != 0) return false;
    }
    return true;
}
/// cx_box: a box core, no radius (ucomiss: NaN counts as none).
fn cxBox(p: *const Part) bool {
    if (p.typ != 0) return false;
    return p.rad == 0 or std.math.isNan(p.rad);
}

/// cx_quick: two spheres, or a sphere and a box (no radius): exact.
fn cxQuick(pa: *const Proxy, pb: *const Proxy, out: *Hit) bool {
    const sa = cxSphere(pa.part.?);
    const sb = cxSphere(pb.part.?);
    if (sa and sb) {
        const d = andXyz(pb.c - pa.c);
        var l = @sqrt(dot3(d, d));
        var n = axes[1]; // (one inside the other: up)
        if (l > EPS) n = d / splat(l);
        out.n = n;
        const ra = pa.part.?.rad;
        const rb = pb.part.?.rad;
        l -= ra;
        l -= rb;
        out.sep = l;
        out.pa = andXyz(splat(ra) * n + pa.c);
        out.pb = andXyz(pb.c - splat(rb) * n);
        return true;
    }
    if (sa) {
        if (!cxBox(pb.part.?)) return false;
        boxSphere(pb, pa, true, out);
        return true;
    }
    if (!sb) return false;
    if (!cxBox(pa.part.?)) return false;
    boxSphere(pa, pb, false, out);
    return true;
}

/// .Lcq_bs: bx the box, sp the sphere; turned: the box was B.
fn boxSphere(bx: *const Proxy, sp: *const Proxy, turned: bool, out: *Hit) void {
    const p = andXyz(rc.mtv3(&bx.r, sp.c - bx.c)); // the sphere's centre in the box's axes
    const hh = andXyz(bx.part.?.half);
    var q = rc.minps(rc.maxps(neg3(hh), p), hh);
    var n = p - q;
    var dist: f32 = undefined;
    const l2 = dot3(n, n);
    if (l2 > SMALL) { // outside: n = (p - q) / |p - q|
        const l = @sqrt(l2);
        n = n / splat(l);
        dist = l;
    } else { // inside: the nearest face
        const e = hh - rc.abs4(p);
        var ax: u32 = 0;
        var best = e[0];
        if (!(e[1] >= best)) {
            best = e[1];
            ax = 1;
        }
        if (!(e[2] >= best)) {
            best = e[2];
            ax = 2;
        }
        n = axes[ax];
        const pa_: [4]f32 = p;
        const ha: [4]f32 = hh;
        if (!(pa_[ax] >= 0)) n = neg3(n);
        const na: [4]f32 = n;
        var qa: [4]f32 = p;
        qa[ax] = ha[ax] * na[ax];
        q = qa;
        dist = -best;
    }
    const nw = andXyz(rc.mv3(&bx.r, n));
    const qw = andXyz(rc.mv3(&bx.r, q) + bx.c);
    const r = sp.part.?.rad;
    out.sep = dist - r;
    const sw = andXyz(sp.c - splat(r) * nw);
    if (!turned) {
        out.pa = qw;
        out.pb = sw;
        out.n = nw;
    } else {
        out.pa = sw;
        out.pb = qw;
        out.n = neg3(nw);
    }
}

// ---- collide ---------------------------------------------------------------------------

/// collide: the separation (negative: overlapping), a point on each surface,
/// the normal from A to B.
pub fn collide(pa: *const Proxy, pb: *const Proxy, out: *Hit) void {
    if (cxQuick(pa, pb, out)) return;
    var s: Simplex = .{ .pa = pa, .pb = pb };
    var overlap = gjk(&s);
    if (!overlap) {
        gjWitness(&s, &out.pa, &out.pb);
        var n = out.pb - out.pa;
        const l = @sqrt(dot3(n, n));
        if (l > SMALL) {
            out.sep = l;
            n = andXyz(n / splat(l));
            out.n = n;
        } else overlap = true; // (touching: as overlapping)
    }
    if (overlap) {
        if (!epa(&s, out)) { // (degenerate: centre to centre, 0)
            var d = pb.c - pa.c;
            const l = rc.maxss(@sqrt(dot3(d, d)), TINY);
            d = andXyz(d / splat(l));
            out.n = d;
            gjWitness(&s, &out.pa, &out.pb);
            out.sep = 0;
        }
        out.sep = 0.0 - out.sep;
    }
    const ra = pa.part.?.rad;
    const rb = pb.part.?.rad;
    var sep = out.sep;
    sep -= ra;
    sep -= rb;
    out.sep = sep;
    out.pa = splat(ra) * out.n + out.pa;
    out.pb = out.pb - splat(rb) * out.n;
}

// ---- tests -----------------------------------------------------------------------------

fn place(px: *Proxy, part: *const Part, pos: V4) void {
    pxPlace(px, &rc.ident, pos, part);
}

test "two spheres" {
    const a = Part{ .rad = 0.5 };
    const b = Part{ .rad = 0.25 };
    var pa: Proxy = .{};
    var pb: Proxy = .{};
    place(&pa, &a, .{ 0, 0, 0, 0 });
    place(&pb, &b, .{ 2, 0, 0, 0 });
    var h: Hit = .{};
    collide(&pa, &pb, &h);
    try std.testing.expectEqual(@as(f32, 1.25), h.sep);
    try std.testing.expectEqual(@as(f32, 1), h.n[0]);
    try std.testing.expectEqual(@as(f32, 0.5), h.pa[0]);
    try std.testing.expectEqual(@as(f32, 1.75), h.pb[0]);
}

test "box and sphere, outside and inside" {
    const bx = Part{ .half = .{ 1, 1, 1, 0 } };
    const sp = Part{ .rad = 0.5 };
    var pa: Proxy = .{};
    var pb: Proxy = .{};
    place(&pa, &bx, .{ 0, 0, 0, 0 });
    place(&pb, &sp, .{ 0, 3, 0, 0 });
    var h: Hit = .{};
    collide(&pa, &pb, &h);
    try std.testing.expectEqual(@as(f32, 1.5), h.sep);
    try std.testing.expectEqual(@as(f32, 1), h.n[1]);
    // the sphere first: turned
    collide(&pb, &pa, &h);
    try std.testing.expectEqual(@as(f32, 1.5), h.sep);
    try std.testing.expectEqual(@as(f32, -1), h.n[1]);
    place(&pb, &sp, .{ 0.8, 0.1, 0, 0 }); // inside: nearest face +x
    collide(&pa, &pb, &h);
    try std.testing.expectApproxEqAbs(@as(f32, -0.7), h.sep, 1e-6);
    try std.testing.expectEqual(@as(f32, 1), h.n[0]);
}

test "boxes apart and overlapping (GJK, EPA)" {
    const bx = Part{ .half = .{ 1, 1, 1, 0 } };
    var pa: Proxy = .{};
    var pb: Proxy = .{};
    place(&pa, &bx, .{ 0, 0, 0, 0 });
    place(&pb, &bx, .{ 3, 0.5, 0.25, 0 });
    var h: Hit = .{};
    collide(&pa, &pb, &h);
    try std.testing.expectApproxEqAbs(@as(f32, 1), h.sep, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), h.n[0], 1e-5);
    place(&pb, &bx, .{ 1.75, 0.1, 0.2, 0 });
    collide(&pa, &pb, &h);
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), h.sep, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), h.n[0], 1e-4);
}

test "capsule and hull" {
    // a capsule: a box core of half height along Y, a radius
    const cap = Part{ .half = .{ 0, 1, 0, 0 }, .rad = 0.5 };
    var pts = [_]V4{
        .{ -1, -1, -1, 0 }, .{ 1, -1, -1, 0 }, .{ -1, 1, -1, 0 }, .{ 1, 1, -1, 0 },
        .{ -1, -1, 1, 0 },  .{ 1, -1, 1, 0 },  .{ -1, 1, 1, 0 },  .{ 1, 1, 1, 0 },
    };
    const hull = Part{ .typ = 1, .nv = 8, .verts = &pts };
    var pa: Proxy = .{};
    var pb: Proxy = .{};
    place(&pa, &cap, .{ 0, 0, 0, 0 });
    place(&pb, &hull, .{ 0, 4, 0, 0 });
    var h: Hit = .{};
    collide(&pa, &pb, &h);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), h.sep, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), h.n[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), h.pa[1], 1e-5);
    place(&pb, &hull, .{ 1.25, 0, 0, 0 }); // cores apart, surfaces 0.25 into each other
    collide(&pa, &pb, &h);
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), h.sep, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), h.n[0], 1e-5);
    place(&pb, &hull, .{ 0.75, 0, 0, 0 }); // cores overlap by 0.25 (EPA)
    collide(&pa, &pb, &h);
    try std.testing.expectApproxEqAbs(@as(f32, -0.75), h.sep, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), h.n[0], 1e-4);
}

test "tri_closest regions" {
    var o: Closest = .{};
    // the face: the origin above the triangle's inside
    triClosest(.{ -1, -1, 1, 0 }, .{ 1, -1, 1, 0 }, .{ 0, 1, 1, 0 }, &o);
    try std.testing.expectEqual(@as(u32, 7), o.mask);
    try std.testing.expectApproxEqAbs(@as(f32, 0), o.v[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), o.v[1], 1e-6);
    try std.testing.expectEqual(@as(f32, 1), o.v[2]);
    // vertex a
    triClosest(.{ 1, 1, 0, 0 }, .{ 2, 1, 0, 0 }, .{ 1, 2, 0, 0 }, &o);
    try std.testing.expectEqual(@as(u32, 1), o.mask);
    // edge ab
    triClosest(.{ -1, 1, 0, 0 }, .{ 1, 1, 0, 0 }, .{ 0, 2, 0, 0 }, &o);
    try std.testing.expectEqual(@as(u32, 3), o.mask);
    try std.testing.expectEqual(@as(f32, 1), o.v[1]);
    try std.testing.expectEqual(@as(f32, 0.5), o.u[1]);
    // edge bc
    triClosest(.{ 3, 0, 0, 0 }, .{ 1, -1, 0, 0 }, .{ 1, 1, 0, 0 }, &o);
    try std.testing.expectEqual(@as(u32, 6), o.mask);
    try std.testing.expectEqual(@as(f32, 1), o.v[0]);
}
