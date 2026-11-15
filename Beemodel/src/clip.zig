// Contact points between two polytopes, by clipping faces (clip.s).
//
// GJK / EPA give one point and the normal. Two boxes resting face on face
// touch along a whole face, and a stack only stands when its contact points
// are that face's corners. polyClip takes each body's feature along the
// normal (its points within a small tolerance of its support plane: a face,
// an edge or a vertex). When one of them is a face it is the reference: its
// outline (a convex polygon, in order) clips the other feature
// (Sutherland-Hodgman, against the planes through its edges); what is left,
// at or below the reference face (within the contact margin), are the
// contact points, reduced to four (the deepest, the one farthest from it,
// then the most area on each side). The normal is the reference face's.
// Boxes give their eight corners, hulls their points; rounded parts (a
// radius) are not polytopes and keep GJK's point. Re-entrant: everything is
// on the stack.
//
// The original's single-precision operations in its order throughout.
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
const neg3 = rc.neg3;

const MAXV = 64; // points a feature
const MAXP = 160; // points while clipping

const corner = [8]V4{
    .{ -1, -1, -1, 0 }, .{ 1, -1, -1, 0 }, .{ -1, 1, -1, 0 }, .{ 1, 1, -1, 0 },
    .{ -1, -1, 1, 0 },  .{ 1, -1, 1, 0 },  .{ -1, 1, 1, 0 },  .{ 1, 1, 1, 0 },
};
const ex: V4 = .{ 1, 0, 0, 0 };
const ey: V4 = .{ 0, 1, 0, 0 };
const TOLK: f32 = 0.04; // a feature: within 4% of the size
const TOLMIN: f32 = 0.0005;
const TOLMAX: f32 = 0.02; // (2 cm at most)
const BIG: f32 = 1e30;
const WFLOOR: f32 = 0.25;
const NEAR2: f32 = 0.0001;
const EPS: f32 = 1e-9;
const HALF: f32 = 0.577;
const EDGE: f32 = 0.001;
const FLAT: f32 = 0.9998;

const Frame = struct {
    va: [MAXV]V4 = undefined,
    vb: [MAXV]V4 = undefined,
    fa: [MAXV]V4 = undefined,
    fb: [MAXV]V4 = undefined,
    p0: [MAXP]V4 = undefined,
    p1: [MAXP]V4 = undefined,
    tmp: [MAXV]V4 = undefined,
    n: V4 = @splat(0),
    t1: V4 = @splat(0),
    t2: V4 = @splat(0),
    na: u32 = 0,
    nb: u32 = 0,
    np: u32 = 0,
    flip: u32 = 0,
    d: f32 = 0,
    ta: f32 = 0,
    tb: f32 = 0,
    mg: f32 = 0,
    k: [4]u32 = .{ 0, 0, 0, 0 },
    cen: V4 = @splat(0),
    old: ?*const rc.Manifold = null,
    w: [MAXP]f32 = undefined,
};

/// cl_world: C + R p.
fn world(px: *const Proxy, p: V4) V4 {
    return andXyz(rc.mv3(&px.r, p) + px.c);
}

/// cl_gather: its points (world) and how far the farthest is from its
/// centre; 0 points: a rounded part.
fn gather(px: *const Proxy, out: *[MAXV]V4, ext: *f32) u32 {
    const p = px.part.?;
    ext.* = 0;
    if (p.rad != 0 and !std.math.isNan(p.rad)) return 0; // (ucomiss: NaN passes as no radius)
    var n: u32 = 0;
    if (p.typ == 0) {
        while (n < 8) : (n += 1) out[n] = world(px, corner[n] * p.half);
    } else {
        if (p.nv > MAXV) return 0;
        while (n < p.nv) : (n += 1) out[n] = world(px, andXyz(p.verts.?[n]));
    }
    var m: f32 = 0;
    for (out[0..n]) |q| {
        const e = q - px.c;
        m = rc.maxss(m, dot3(e, e));
    }
    ext.* = @sqrt(m);
    return n;
}

/// cl_feature: the points within the tolerance of the farthest along d.
fn feature(pts: []const V4, d: V4, tol: f32, out: []V4) u32 {
    var top: f32 = -BIG;
    for (pts) |q| top = rc.maxss(top, dot3(q, d));
    const cut = top - tol;
    var n: u32 = 0;
    for (pts) |q| {
        if (!(dot3(q, d) >= cut)) continue;
        out[n] = q;
        n += 1;
    }
    return n;
}

/// cl_basis: t1, t2 square to n, t1 x t2 = n.
fn basis(f: *Frame) void {
    const n = f.n;
    const ax = @abs(andXyz(n)[0]);
    const a = if (!(ax >= HALF)) ex else ey;
    var t1 = cross(a, n);
    t1 = t1 / splat(@sqrt(dot3(t1, t1)));
    f.t1 = t1;
    f.t2 = cross(n, t1);
}

/// cl_order: the points of their outline, in turn (gift wrapping from the
/// point least along t1, each next one with all the others on its right).
fn order(f: *Frame, pts: []V4) u32 {
    const n: u32 = @intCast(pts.len);
    var start: u32 = 0;
    var c: u32 = 1;
    while (c < n) : (c += 1) {
        if (!(dot3(pts[c], f.t1) >= dot3(pts[start], f.t1))) start = c;
    }
    var cnt: u32 = 0;
    var p = start;
    while (cnt < n) {
        f.tmp[cnt] = pts[p];
        cnt += 1;
        var q: u32 = p + 1;
        if (q >= n) q = 0;
        var r: u32 = 0;
        while (r < n) : (r += 1) {
            if (r == p) continue;
            const pp = pts[p];
            const qp = pts[q] - pp;
            const rp = pts[r] - pp;
            const s = dot3(cross(qp, rp), f.n);
            if (!(s >= 0)) continue; // r on the right: q stays
            if (!(s > 0)) { // in line: the farther
                if (!(dot3(rp, rp) > dot3(qp, qp))) continue;
            }
            q = r;
        }
        p = q;
        if (p == start) break;
    }
    @memcpy(pts[0..cnt], f.tmp[0..cnt]);
    return cnt;
}

/// cl_cross: where prev -> cur crosses the plane.
inline fn crossAt(cur: V4, dc: f32, prev: V4, dp: f32) V4 {
    const t = dp / (dp - dc);
    return (cur - prev) * splat(t) + prev;
}

/// cl_plane: the points kept by a plane (a point on it, its inward normal):
/// a polygon of 3 or more (Sutherland-Hodgman), a segment, a point.
fn plane(in: []const V4, out: []V4, p0: V4, m: V4) u32 {
    const n: u32 = @intCast(in.len);
    var k: u32 = 0;
    if (n < 3) {
        for (0..n) |c| {
            var p = in[c];
            const d = dot3(p - p0, m);
            if (!(d >= 0)) {
                if (n != 2) continue;
                const o = in[c ^ 1];
                const d2 = dot3(o - p0, m);
                if (!(d2 >= 0)) continue; // both out
                const t = d / (d - d2);
                p = p + (o - p) * splat(t);
            }
            out[k] = p;
            k += 1;
        }
        return k;
    }
    var prev: u32 = n - 1;
    var c: u32 = 0;
    while (c < n) : (c += 1) {
        if (k >= MAXP - 2) break;
        const cur = in[c];
        const pv = in[prev];
        const dc = dot3(cur - p0, m);
        const dp = dot3(pv - p0, m);
        if (!(dc >= 0)) {
            if (dp >= 0) { // cur out: prev in - the crossing
                out[k] = crossAt(cur, dc, pv, dp);
                k += 1;
            }
        } else {
            if (!(dp >= 0)) { // cur in: prev out - the crossing
                out[k] = crossAt(cur, dc, pv, dp);
                k += 1;
            }
            out[k] = cur;
            k += 1;
        }
        prev = c;
    }
    return k;
}

/// cl_pick: all when 4 or fewer, else the deepest, the farthest from it,
/// and the most area on each side of those two.
fn pick(f: *Frame, pts: []const V4) u32 {
    const n: u32 = f.np;
    if (n <= 4) {
        for (0..n) |c| f.k[c] = @intCast(c);
        return n;
    }
    var k0: u32 = 0;
    var c: u32 = 1;
    while (c < n) : (c += 1) {
        if (!(pts[c][3] >= pts[k0][3])) k0 = c;
    }
    f.k[0] = k0;
    const p0 = andXyz(pts[k0]);
    var best: f32 = 0;
    var k1 = k0;
    for (0..n) |i| {
        const e = andXyz(pts[i]) - p0;
        const d = dot3(e, e);
        if (d > best) {
            best = d;
            k1 = @intCast(i);
        }
    }
    f.k[1] = k1;
    const e1 = andXyz(pts[k1]) - p0;
    var hi: f32 = -BIG;
    var lo: f32 = BIG;
    var k2 = k0;
    var k3 = k0;
    for (0..n) |i| {
        const e = andXyz(pts[i]) - p0;
        const a = dot3(cross(e1, e), f.n);
        if (a > hi) {
            hi = a;
            k2 = @intCast(i);
        }
        if (!(a >= lo)) {
            lo = a;
            k3 = @intCast(i);
        }
    }
    f.k[2] = k2;
    f.k[3] = k3;
    return if (k2 == k3) 3 else 4;
}

/// cl_across: a vector's length squared across the normal.
fn across(f: *const Frame, v: V4) f32 {
    const d = dot3(v, f.n);
    const x = v - splat(d) * f.n;
    return dot3(x, x);
}

/// cl_far: the point farthest from p across the normal, times its weight.
fn far(f: *const Frame, pts: []const V4, p: V4) u32 {
    var best: f32 = 0;
    var k: u32 = 0;
    for (0..f.np) |c| {
        var x = across(f, andXyz(pts[c]) - p);
        x *= f.w[c];
        if (x > best) {
            best = x;
            k = @intCast(c);
        }
    }
    return k;
}

/// cl_pick_w: all when 4 or fewer, else four that hold the body up,
/// whichever way it leans (weighed by depth, twice where the manifold
/// already has a point).
fn pickW(f: *Frame, pts: []const V4) u32 {
    if (f.np <= 4) return pick(f, pts);
    var wt = f.mg * WFLOOR;
    wt += f.mg;
    for (0..f.np) |c| {
        var x = wt - pts[c][3];
        x = rc.maxss(x, EPS);
        if (f.old) |m| {
            for (m.pts[0..m.n]) |*cp| {
                const v = andXyz(pts[c] - cp.wa);
                if (across(f, v) > NEAR2) continue;
                x *= 2.0;
                break;
            }
        }
        f.w[c] = x;
    }
    const k0 = far(f, pts, andXyz(f.cen));
    f.k[0] = k0;
    const p0 = andXyz(pts[k0]);
    const k1 = far(f, pts, p0);
    f.k[1] = k1;
    const e1 = andXyz(pts[k1]) - p0;
    var hi: f32 = -BIG;
    var lo: f32 = BIG;
    var k2 = k0;
    var k3 = k0;
    for (0..f.np) |c| {
        const e = andXyz(pts[c]) - p0;
        var a = dot3(cross(e1, e), f.n);
        a *= f.w[c];
        if (a > hi) {
            hi = a;
            k2 = @intCast(c);
        }
        if (!(a >= lo)) {
            lo = a;
            k3 = @intCast(c);
        }
    }
    f.k[2] = k2;
    f.k[3] = k3;
    return if (k2 == k3) 3 else 4;
}

fn clampTol(e: f32) f32 {
    var t = e * TOLK;
    t = rc.maxss(t, TOLMIN);
    return rc.minss(t, TOLMAX);
}

/// poly_clip: the contact points (into out, 4 at most) of two polytopes
/// along n (unit, A to B) within the margin; 0: no face (use GJK's).
pub fn polyClip(pxa: *const Proxy, pxb: *const Proxy, n0: V4, mg: f32, out: *[4]Hit) u32 {
    var f: Frame = .{};
    f.n = andXyz(n0);
    f.mg = mg;
    var ext: f32 = 0;
    f.na = gather(pxa, &f.va, &ext);
    if (f.na == 0) return 0;
    f.ta = clampTol(ext);
    f.nb = gather(pxb, &f.vb, &ext);
    if (f.nb == 0) return 0;
    f.tb = clampTol(ext);
    const nfa = feature(f.va[0..f.na], f.n, f.ta, &f.fa);
    const nfb = feature(f.vb[0..f.nb], neg3(f.n), f.tb, &f.fb);
    // the reference: A's face if it is one, else B's
    f.flip = 0;
    var ref: []V4 = &f.fa;
    var nref = nfa;
    var inc: []V4 = &f.fb;
    var ninc = nfb;
    if (nfa < 3) {
        if (nfb < 3) return 0;
        f.flip = 1;
        ref = &f.fb;
        nref = nfb;
        inc = &f.fa;
        ninc = nfa;
    }
    // the other side: its points within the margin of its support plane
    if (f.flip == 0) {
        const t = rc.maxss(f.mg, f.tb);
        ninc = feature(f.vb[0..f.nb], neg3(f.n), t, &f.fb);
    } else {
        const t = rc.maxss(f.mg, f.ta);
        ninc = feature(f.va[0..f.na], f.n, t, &f.fa);
    }
    basis(&f);
    nref = order(&f, ref[0..nref]);
    if (nref < 3) return 0;
    // the reference face's own normal (Newell), turned like n; its plane
    var nw: V4 = @splat(0);
    for (0..nref) |c| {
        const d = if (c + 1 < nref) c + 1 else 0;
        nw += cross(ref[c], ref[d]);
    }
    const l2 = dot3(nw, nw);
    if (!(l2 > EPS)) return 0;
    nw = nw / splat(@sqrt(l2));
    if (!(dot3(nw, f.n) >= 0)) nw = neg3(nw);
    f.n = nw;
    f.d = dot3(ref[0], nw);
    // the incident feature, in order when it is a face
    if (ninc >= 3) ninc = order(&f, inc[0..ninc]);
    @memcpy(f.p0[0..ninc], inc[0..ninc]);
    f.np = ninc;
    var pin: []V4 = &f.p0;
    // clip by each edge's plane
    for (0..nref) |i| {
        if (f.np == 0) return 0;
        const e0 = ref[i];
        const j = if (i + 1 < nref) i + 1 else 0;
        const e1 = ref[j] - e0;
        var m = cross(f.n, e1);
        var cen: V4 = @splat(0);
        for (0..nref) |c| cen += ref[c];
        const nf: f32 = @floatFromInt(nref);
        cen = cen / splat(nf);
        if (!(dot3(cen - e0, m) >= 0)) m = neg3(m);
        const dst: []V4 = if (pin.ptr == @as([*]V4, &f.p0)) &f.p1 else &f.p0;
        f.np = plane(pin[0..f.np], dst, e0, m);
        pin = dst;
    }
    // the points left: their gaps to the reference plane; near enough kept
    var kept: u32 = 0;
    for (0..f.np) |c| {
        const p = pin[c];
        var g = dot3(p, f.n) - f.d;
        if (f.flip != 0) g = -g;
        if (g > f.mg) continue;
        pin[kept] = rc.setW(andXyz(p), g);
        kept += 1;
    }
    if (kept == 0) return 0;
    f.np = kept;
    const k = pick(&f, pin[0..f.np]);
    for (0..k) |r| {
        const q = pin[f.k[r]];
        const g = q[3];
        const o = &out[r];
        o.sep = g;
        const p = andXyz(q);
        const gn = splat(g) * f.n;
        if (f.flip == 0) {
            o.pb = p;
            o.pa = p - gn;
        } else {
            o.pa = p;
            o.pb = p + gn;
        }
        o.n = f.n;
    }
    return k;
}

/// poly_plane: the contact points of a plane (its proxy: `half` holds its
/// normal) and another part (a polytope's points, or a rounded part's core
/// corners less its radius) at most the margin above the plane; four kept
/// (round the other's centre, the points `old` has kept first). plane_is_a:
/// the plane is A.
pub fn polyPlane(pl: *const Proxy, other: *const Proxy, plane_is_a: bool, mg: f32, out: *[4]Hit, old: ?*const rc.Manifold) u32 {
    var f: Frame = .{};
    f.mg = mg;
    f.flip = @intFromBool(plane_is_a);
    f.old = old;
    f.cen = other.c;
    const hn = andXyz(pl.part.?.half);
    f.n = andXyz(rc.mv3(&pl.r, hn));
    f.d = dot3(pl.c, f.n);
    var ext: f32 = 0;
    var n = gather(other, &f.va, &ext);
    var rad: f32 = 0;
    if (n == 0) { // rounded: its core's distinct corners
        const p = other.part.?;
        if (p.typ != 0) return 0;
        var k: u32 = 0;
        for (corner) |cn| {
            const q = world(other, cn * p.half);
            var dup = false;
            for (f.va[0..k]) |v| {
                const e = v - q;
                if (!(dot3(e, e) >= TOLMIN)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            f.va[k] = q;
            k += 1;
        }
        n = k;
        rad = p.rad;
    }
    f.na = n;
    f.ta = rad;
    var kept: u32 = 0;
    for (f.va[0..n]) |q| {
        var g = dot3(q, f.n) - f.d;
        g -= f.ta;
        if (g > f.mg) continue;
        f.p0[kept] = rc.setW(andXyz(q), g);
        kept += 1;
    }
    if (kept == 0) return 0;
    f.np = kept;
    const pts = f.p0[0..kept];
    const k = pickW(&f, pts);
    for (0..k) |r| {
        const q = pts[f.k[r]];
        const g = q[3];
        const o = &out[r];
        o.sep = g;
        const p = andXyz(q) - splat(f.ta) * f.n; // on the other: p - r n
        const s = p - splat(g) * f.n; // on the plane: that - gap n
        if (f.flip != 0) {
            o.pa = s;
            o.pb = p;
            o.n = f.n;
        } else {
            o.pa = p;
            o.pb = s;
            o.n = neg3(f.n);
        }
    }
    return k;
}

/// tri_fix: a contact on edges of a mesh that are not active (a flat or
/// concave neighbour there): the normal becomes the face's, the gap measured
/// along it. tri_is_a: the triangle is A.
pub fn triFix(tri: *const Proxy, res: *Hit, tri_is_a: bool) void {
    const part = tri.part.?;
    var c: [3]V4 = undefined;
    for (0..3) |k| c[k] = world(tri, andXyz(part.verts.?[k]));
    var nf = cross(c[1] - c[0], c[2] - c[0]);
    const l2 = dot3(nf, nf);
    if (!(l2 > EPS)) return;
    nf = nf / splat(@sqrt(l2));
    var n = res.n; // n from the triangle to the other
    if (!tri_is_a) n = neg3(n);
    var dn = dot3(nf, n);
    if (!(dn >= 0)) {
        nf = neg3(nf);
        dn = -dn;
    }
    if (dn >= FLAT) return; // already the face's
    const p = (if (tri_is_a) res.pa else res.pb) - c[0];
    const e1 = c[1] - c[0];
    const e2 = c[2] - c[0];
    const d00 = dot3(e1, e1);
    const d01 = dot3(e1, e2);
    const d11 = dot3(e2, e2);
    const d20 = dot3(p, e1);
    const d21 = dot3(p, e2);
    const den = d00 * d11 - d01 * d01;
    if (!(den > EPS)) return;
    const v = (d11 * d20 - d01 * d21) / den;
    const w = (d00 * d21 - d01 * d20) / den;
    const u = (1.0 - v) - w;
    var on: u32 = 0;
    if (!(w > EDGE)) on |= 2; // edge 0-1
    if (!(u > EDGE)) on |= 4; // edge 1-2
    if (!(v > EDGE)) on |= 8; // edge 2-0
    if (on == 0) return; // (inside: a face contact - as is)
    if (part.flg & on != 0) return; // one of its edges active: as is
    var nn = nf;
    if (!tri_is_a) nn = neg3(nn); // (B: from the other to the triangle)
    res.n = nn;
    res.sep = dot3(res.pb - res.pa, nn);
}

test "two boxes face on face: four corners" {
    const bx = Part{ .half = .{ 1, 1, 1, 0 } };
    const small = Part{ .half = .{ 0.5, 0.5, 0.5, 0 } };
    var pa: Proxy = .{};
    var pb: Proxy = .{};
    @import("collide.zig").pxPlace(&pa, &rc.ident, .{ 0, 0, 0, 0 }, &bx);
    @import("collide.zig").pxPlace(&pb, &rc.ident, .{ 0.2, 1.49, 0.1, 0 }, &small);
    var out: [4]Hit = undefined;
    const n = polyClip(&pa, &pb, .{ 0, 1, 0, 0 }, 0.02, &out);
    try std.testing.expectEqual(@as(u32, 4), n);
    for (out[0..n]) |h| {
        try std.testing.expectApproxEqAbs(@as(f32, -0.01), h.sep, 1e-5);
        try std.testing.expectEqual(@as(f32, 1), h.n[1]);
    }
}

test "a box on a plane" {
    const pl = Part{ .typ = 2, .half = .{ 0, 1, 0, 0 } };
    const bx = Part{ .half = .{ 0.5, 0.5, 0.5, 0 } };
    var pa: Proxy = .{};
    var pb: Proxy = .{};
    @import("collide.zig").pxPlace(&pa, &rc.ident, .{ 0, 0, 0, 0 }, &pl);
    @import("collide.zig").pxPlace(&pb, &rc.ident, .{ 0, 0.49, 0, 0 }, &bx);
    var out: [4]Hit = undefined;
    const n = polyPlane(&pa, &pb, true, 0.02, &out, null);
    try std.testing.expectEqual(@as(u32, 4), n);
    try std.testing.expectApproxEqAbs(@as(f32, -0.01), out[0].sep, 1e-6);
    try std.testing.expectEqual(@as(f32, 1), out[0].n[1]);
}
