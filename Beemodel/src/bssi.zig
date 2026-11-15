//! bssi.s: surface-surface intersection for the B-rep booleans.
//!
//! ssi(fa, fb) appends the curves where two faces' surfaces meet, as dense
//! polylines whose every point lies on both surfaces (with its (u, v) on
//! each). Planes against planes, cylinders across or along their axis,
//! spheres and cones across theirs are solved in closed form and keep the
//! exact line or circle. Everything else is traced: the signed distance to
//! the second surface sampled on a grid over the first face (the smaller
//! one), its zero contour followed cell by cell (marching squares), every
//! point pulled onto both surfaces by intersecting their tangent planes,
//! and points added where the polyline strays from the true curve. Faces
//! whose surfaces coincide are left to the boolean. In the original's order
//! of operations, bit for bit.
const std = @import("std");
const linux = std.os.linux;
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const V3 = nb.V3;
const jb = nb.jb;
const ja = nb.ja;
const jae = nb.jae;
const jbe = nb.jbe;
const maxsd = nb.maxsd;
const minsd = nb.minsd;
const fabs = nb.fabs;
const fneg = nb.fneg;
const fl = nb.fl;
const NONE = br.NONE;

/// A section curve.
pub const Sec = extern struct {
    fa: u32,
    fb: u32,
    first: u32, // its points in pts
    n: u32,
    closed: u32,
    curve: u32, // an exact curve (NONE: none)
    _pad: [6]u32,
};
/// A point: x y z, ua va, ub vb.
pub const Pt = extern struct {
    p: V3,
    ua: [2]f64,
    ub: [2]f64,
};
comptime {
    std.debug.assert(@sizeOf(Sec) == 48 and @sizeOf(Pt) == 56);
}
pub const MAXSS = 8192;
const GRIDN = 1600; // samples per face grid
const PA_CAP = 0x40000000;

const ss_ext: f64 = 0.02; // the grid reaches past the face
const ss_par: f64 = 1.0e-9; // parallel / perpendicular
const ss_conv: f64 = 1.0e-4; // (of the tolerance) converged
const ss_tiny: f64 = 1.0e-14;
const ss_big: f64 = 1.0e300;
const ss_seg: f64 = 0.04908738521234052; // circles: 128 points a turn

/// The linear tolerance.
pub var ss_tol: f64 = 0;
pub var ss_n: u32 = 0;
pub var ss_rec: [MAXSS]Sec = undefined;
var ss_np: u32 = 0;
var ss_ready = false;
/// The points (PA_CAP bytes reserved).
pub var ss_pts: [*]Pt = undefined;
// the faces being intersected
var sa_f: u32 = 0;
var sb_f: u32 = 0;
var sa_s: *nb.Surface = undefined;
var sb_s: *nb.Surface = undefined;
var sa_box: [4]f64 = undefined;
var sb_box: [4]f64 = undefined;
var ss_swap: bool = false; // the grid is on b: (u, v) swapped
var sp_cont: bool = false;
// the grid
var gr_nu: u32 = 0;
var gr_nv: u32 = 0;
var gr_f: [*]f64 = undefined;
const Cross = extern struct { uv: [2]f64, link: [2]u32, traced: u32, _pad: u32 };
var gr_x: [*]Cross = undefined;
var gr_u0: f64 = 0;
var gr_du: f64 = 0;
var gr_v0: f64 = 0;
var gr_dv: f64 = 0;

fn ssInit() void {
    if (ss_ready) return;
    const rc = linux.mmap(null, PA_CAP, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    ss_pts = @ptrFromInt(rc);
    ss_ready = true;
}

/// ss_reset: no sections
pub fn reset() void {
    ssInit();
    ss_n = 0;
    ss_np = 0;
}

fn spNew() ?u32 {
    if (!ss_ready or ss_np >= PA_CAP / @sizeOf(Pt) - 1) return null;
    ss_np += 1;
    return ss_np - 1;
}

// ---- distances and projections -------------------------------------------------------
/// sf_near: (u, v) of the nearest point
pub fn sfNear(s: *const nb.Surface, p: V3, uh: f64, vh: f64) [2]f64 {
    if (s.typ == nb.ST_NURBS) return br.sfProject(s, p, uh, vh);
    const r = br.sfInvert(s, p, uh, vh);
    return .{ r.u, r.v };
}

/// sf_dist: the signed distance along Su x Sv, and the nearest (u, v)
pub fn sfDist(s: *const nb.Surface, p: V3, uh: f64, vh: f64) struct { d: f64, uv: [2]f64 } {
    const uv = sfNear(s, p, uh, vh);
    const pn = br.sfNormal(s, uv[0], uv[1]);
    return .{ .d = nb.v3dot(nb.v3sub(p, pn[0]), pn[1]), .uv = uv };
}

/// ss_refine(a, b, point): it lies on both (to the tolerance): the tangent
/// planes of the nearest points and the plane across their line through the
/// point, met
pub fn refine(a: *const nb.Surface, b: *const nb.Surface, q: *Pt) bool {
    var it: u32 = 0;
    while (true) {
        q.ua = sfNear(a, q.p, q.ua[0], q.ua[1]);
        const pa = br.sfNormal(a, q.ua[0], q.ua[1]);
        q.ub = sfNear(b, q.p, q.ub[0], q.ub[1]);
        const pb = br.sfNormal(b, q.ub[0], q.ub[1]);
        const d = nb.v3dist(pa[0], pb[0]);
        if (jbe(d, ss_tol * ss_conv)) {
            for (0..3) |k| q.p[k] = (pa[0][k] + pb[0][k]) * 0.5;
            return true;
        }
        it += 1;
        if (it > 24) {
            if (jbe(d, ss_tol)) { // (stalled: close enough is enough)
                for (0..3) |k| q.p[k] = (pa[0][k] + pb[0][k]) * 0.5;
                return true;
            }
            return false;
        }
        const t = nb.v3cross(pa[1], pb[1]);
        if (jbe(nb.v3len(t), ss_par)) return false; // tangent
        const x = nb.v3cross(pb[1], t);
        const det = nb.v3dot(pa[1], x);
        const ha = nb.v3dot(pa[1], pa[0]);
        const hb = nb.v3dot(pb[1], pb[0]);
        const hp = nb.v3dot(t, q.p);
        const w = nb.v3cross(t, pa[1]);
        const p = nb.lin3(null, &x, ha, &w, hb, &t, hp);
        q.p = nb.v3scale(p, 1.0 / det);
    }
}

fn boxAdd(bx: *[6]f64, p: V3) void {
    for (0..3) |k| {
        bx[k] = minsd(bx[k], p[k]);
        bx[3 + k] = maxsd(bx[3 + k], p[k]);
    }
}

/// fc_bbox(face): a box around it: its edges' points and its surface
/// sampled over its (u, v) box (min xyz, max xyz)
pub fn fcBbox(fi: u32) [6]f64 {
    const f = br.fc(fi);
    var bx: [6]f64 = .{ ss_big, ss_big, ss_big, fneg(ss_big), fneg(ss_big), fneg(ss_big) };
    const s = br.sf(f.surf);
    var i: u32 = 0;
    while (i <= 8) : (i += 1) {
        var j: u32 = 0;
        while (j <= 8) : (j += 1) {
            var u = fl(i) / 8.0;
            u = u * (f.u1 - f.u0);
            u = u + f.u0;
            var v = fl(j) / 8.0;
            v = v * (f.v1 - f.v0);
            v = v + f.v0;
            boxAdd(&bx, nb.srfEval(s, u, v)[0]);
        }
    }
    var l = f.loop;
    const l1 = l + f.nloop;
    while (l < l1) : (l += 1) {
        var c = br.lp(l).first;
        const cend = c + br.lp(l).n;
        while (c < cend) : (c += 1) {
            const e = br.ed(br.ce(c).edge);
            const poly = e.poly orelse continue;
            for (0..e.npoly) |k| boxAdd(&bx, .{ poly[k * 4], poly[k * 4 + 1], poly[k * 4 + 2] });
        }
    }
    return bx;
}

/// sf_coincide: the same plane (either way round) or the same cylinder or sphere
pub fn coincide(a: *const nb.Surface, b: *const nb.Surface) bool {
    if (a.typ != b.typ) return false;
    switch (a.typ) {
        nb.ST_PLANE => {
            if (ja(1.0 - fabs(nb.v3dot(a.z, b.z)), ss_par)) return false;
            return !ja(fabs(nb.v3dot(nb.v3sub(b.o, a.o), a.z)), ss_tol);
        },
        nb.ST_CYL => {
            if (ja(1.0 - fabs(nb.v3dot(a.z, b.z)), ss_par)) return false;
            if (ja(fabs(a.r1 - b.r1), ss_tol)) return false;
            var d = nb.v3sub(b.o, a.o);
            nb.v3axpy(&d, a.z, fneg(nb.v3dot(d, a.z)));
            return !ja(nb.v3len(d), ss_tol);
        },
        nb.ST_SPHERE => {
            if (ja(fabs(a.r1 - b.r1), ss_tol)) return false;
            return !ja(nb.v3dist(a.o, b.o), ss_tol);
        },
        else => return false,
    }
}

// ---- sections ------------------------------------------------------------------------------
fn scBegin() ?*Sec {
    if (ss_n >= MAXSS) return null;
    const r = &ss_rec[ss_n];
    r.fa = if (ss_swap) sb_f else sa_f;
    r.fb = if (ss_swap) sa_f else sb_f;
    r.first = ss_np;
    r.n = 0;
    r.closed = 0;
    r.curve = NONE;
    return r;
}
/// sc_end: counted when it has two points or more
fn scEnd(r: *Sec) void {
    r.n = ss_np -% r.first;
    if (r.n >= 2) {
        ss_n += 1;
        return;
    }
    ss_np = r.first;
}

/// sc_point(3D point, (u, v) hint on the grid face): a point on both
/// surfaces, (u, v) on each (in a, b order)
fn scPoint(p: V3, uh: f64, vh: f64) bool {
    const i = spNew() orelse return false;
    const q = &ss_pts[i];
    q.p = p;
    // hints: the grid face's (u, v) for it, the other's box middle
    q.ua = .{ uh, vh };
    q.ub = .{ (sb_box[0] + sb_box[1]) * 0.5, (sb_box[2] + sb_box[3]) * 0.5 };
    if (sp_cont and sb_s.typ == nb.ST_NURBS and ss_np >= 2) {
        // continuing a curve on a NURBS surface: the last point's
        const l = &ss_pts[ss_np - 2];
        q.ub = if (ss_swap) l.ua else l.ub;
    }
    if (!refine(sa_s, sb_s, q)) {
        ss_np -= 1; // (not on both: dropped)
        return false;
    }
    if (ss_swap) { // stored in (face a, face b) order
        const t = q.ua;
        q.ua = q.ub;
        q.ub = t;
    }
    return true;
}

/// ssi(face a, face b): their sections appended
pub fn ssi(fa: u32, fb: u32) void {
    sa_f = fa;
    sb_f = fb;
    ss_swap = false;
    // the grid goes on the smaller face: swap so a is the smaller
    const ba = fcBbox(sa_f);
    const bb = fcBbox(sb_f);
    const ta = nb.v3dist(.{ ba[0], ba[1], ba[2] }, .{ ba[3], ba[4], ba[5] });
    if (!jae(nb.v3dist(.{ bb[0], bb[1], bb[2] }, .{ bb[3], bb[4], bb[5] }), ta)) {
        sa_f = fb;
        sb_f = fa;
        ss_swap = true;
    }
    var f = br.fc(sa_f);
    sa_s = br.sf(f.surf);
    sa_box = .{ f.u0, f.u1, f.v0, f.v1 };
    f = br.fc(sb_f);
    sb_s = br.sf(f.surf);
    sb_box = .{ f.u0, f.u1, f.v0, f.v1 };
    if (coincide(sa_s, sb_s)) return; // (the boolean handles these)
    if (sa_s.typ == nb.ST_PLANE) {
        if (exactPlaneA()) return;
    } else if (sb_s.typ == nb.ST_PLANE) {
        if (exactPlaneB()) return;
    }
    march();
}

fn swapAB() void {
    const s = sa_s;
    sa_s = sb_s;
    sb_s = s;
    const f = sa_f;
    sa_f = sb_f;
    sb_f = f;
    ss_swap = !ss_swap;
    const b = sa_box;
    sa_box = sb_box;
    sb_box = b;
}

/// exact_plane_b: b is a plane: a's role and b's swapped for the exact cases
fn exactPlaneB() bool {
    swapAB();
    if (exactPlaneA()) return true;
    swapAB(); // not exact: swap back for the march
    return false;
}

const Ex = struct {
    n: V3, // a's normal and offset
    h: f64,
    c: [3]V3 = undefined, // circle / line: O, X, Y
    r: f64 = 0,
    p: V3 = undefined,
    d: V3 = undefined,
    t: f64 = 0,
};

/// exact_plane_a: solved: a is a plane; b a plane, or a cylinder, sphere or
/// cone across its axis, or a cylinder along it
fn exactPlaneA() bool {
    const a = sa_s;
    const b = sb_s;
    var x: Ex = .{ .n = nb.v3scale(a.z, 1.0), .h = 0 };
    x.h = nb.v3dot(x.n, a.o);
    switch (b.typ) {
        nb.ST_PLANE => {
            // the line: direction Na x Nb, a point on both
            x.d = nb.v3cross(x.n, b.z);
            if (jbe(nb.v3norm(&x.d), ss_par)) return true; // parallel planes: nothing
            x.t = nb.v3dot(b.z, b.o);
            x.c[0] = nb.v3cross(b.z, x.d);
            x.c[1] = nb.v3cross(x.d, x.n);
            const k = nb.v3dot(x.n, x.c[0]);
            x.p = nb.lin3(null, &x.c[0], x.h, &x.c[1], x.t, null, 0);
            x.p = nb.v3scale(x.p, 1.0 / k);
            exLine(&x);
            return true;
        },
        nb.ST_CYL => {
            x.t = nb.v3dot(x.n, b.z);
            const az = fabs(x.t);
            if (jbe(1.0 - az, ss_par)) {
                exAxisCentre(&x);
                x.r = b.r1;
                exCircle(&x);
                return true;
            }
            if (!jbe(az, ss_par)) return false; // oblique: an ellipse, traced
            // lines along Z at the two places the plane cuts the circle
            x.t = nb.v3dot(x.n, b.o) - x.h;
            var c = b.r1 * b.r1;
            c = c - x.t * x.t;
            if (jbe(c, ss_tol * b.r1)) return true; // (touching: nothing)
            x.r = @sqrt(c);
            x.c[1] = nb.v3cross(x.n, b.z);
            _ = nb.v3norm(&x.c[1]);
            x.d = nb.v3scale(b.z, 1.0);
            for (0..2) |k| {
                const s = if (k == 0) x.r else fneg(x.r);
                x.p = nb.lin3(&b.o, &x.n, fneg(x.t), &x.c[1], s, null, 0);
                exLine(&x);
            }
            return true;
        },
        nb.ST_SPHERE => {
            x.t = nb.v3dot(x.n, b.o) - x.h;
            var r = b.r1 * b.r1;
            r = r - x.t * x.t;
            if (jbe(r, 0)) return true;
            x.r = @sqrt(r);
            x.c[0] = nb.lin3(&b.o, &x.n, fneg(x.t), null, 0, null, 0);
            x.c[1] = nb.v3scale(a.x, 1.0);
            x.c[2] = nb.v3scale(a.y, 1.0);
            exCircle(&x);
            return true;
        },
        nb.ST_CONE => {
            x.t = nb.v3dot(x.n, b.z);
            if (ja(1.0 - fabs(x.t), ss_par)) return false;
            exAxisCentre(&x); // the circle at that height: R + v sin a with v = z / cos a
            var r = nb.v3dot(nb.v3sub(x.c[0], b.o), b.z) / b.ca;
            r = r * b.sa;
            r = r + b.r1;
            if (jbe(r, 0)) return true;
            x.r = r;
            exCircle(&x);
            return true;
        },
        else => return false,
    }
}

/// ex_axis_centre: c[0] = b's axis meets a's plane; c[1], c[2]: b's X, Y
fn exAxisCentre(x: *Ex) void {
    const b = sb_s;
    var k = x.h - nb.v3dot(x.n, b.o);
    k = k / x.t;
    x.c[0] = nb.lin3(&b.o, &b.z, k, null, 0, null, 0);
    x.c[1] = nb.v3scale(b.x, 1.0);
    x.c[2] = nb.v3scale(b.y, 1.0);
}

/// ex_circle: the circle c, r as a closed section, 128 points
fn exCircle(x: *const Ex) void {
    const cv = br.mkConic(nb.CT_CIRCLE, &x.c, x.r, x.r);
    const r = scBegin() orelse return;
    r.curve = cv;
    r.closed = 1;
    sp_cont = true;
    var k: u32 = 0;
    while (k < 128) : (k += 1) {
        const sc = nb.dsincos(fl(k) * ss_seg);
        const p = nb.lin3(&x.c[0], &x.c[1], sc[1] * x.r, &x.c[2], sc[0] * x.r, null, 0);
        const g = gridHint(p);
        _ = scPoint(p, g[0], g[1]);
    }
    sp_cont = false;
    scEnd(r);
}

/// grid_hint: a point's (u, v) on face a (the plane in the exact cases)
fn gridHint(p: V3) [2]f64 {
    return sfNear(sa_s, p, (sa_box[0] + sa_box[1]) * 0.5, (sa_box[2] + sa_box[3]) * 0.5);
}

/// ex_line: the line through p along d, as an open section across both
/// faces' boxes (a little past them)
fn exLine(x: *const Ex) void {
    var bx: [12]f64 = undefined;
    bx[0..6].* = fcBbox(sa_f);
    bx[6..12].* = fcBbox(sb_f);
    var tmin = ss_big;
    var tmax = fneg(ss_big);
    var c: u32 = 0;
    while (c < 16) : (c += 1) {
        var s: f64 = 0;
        for (0..3) |k| {
            const sel = (c >> @intCast(k)) & 1;
            const at = sel * 3 + (c & 8) / 8 * 6 + k;
            var v = bx[at] - x.p[k];
            v = v * x.d[k];
            s += v;
        }
        tmin = minsd(tmin, s);
        tmax = maxsd(tmax, s);
    }
    var ext = (tmax - tmin) * ss_ext;
    ext = ext + ext;
    ext = ext + ext;
    ext = ext + ss_tol;
    tmin = tmin - ext;
    tmax = tmax + ext;
    const e1 = nb.lin3(&x.p, &x.d, 1.0, null, 0, null, 0);
    const ln = br.mkLine(x.p, e1);
    const r = scBegin() orelse return;
    r.curve = ln.i;
    var k: u32 = 0;
    while (k <= 32) : (k += 1) {
        var t = fl(k) / 32.0;
        t = t * (tmax - tmin);
        t = t + tmin;
        const p = nb.lin3(&x.p, &x.d, t, null, 0, null, 0);
        const g = sfNear(sa_s, p, (sa_box[0] + sa_box[1]) * 0.5, (sa_box[2] + sa_box[3]) * 0.5);
        _ = scPoint(p, g[0], g[1]);
    }
    scEnd(r);
}

// ---- tracing (marching squares over face a) ----------------------------------------------
inline fn grVal(i: u32, j: u32) f64 {
    return gr_f[(gr_nu + 1) * j + i];
}
inline fn grUv(i: u32, j: u32) [2]f64 {
    return .{ fl(i) * gr_du + gr_u0, fl(j) * gr_dv + gr_v0 };
}

const MA = struct { e: [4]u32 = undefined, ne: u32 = 0 };

/// march: the zero contour of the distance to b over face a's grid
fn march() void {
    // the grid: the box 2% bigger each way, cells by the metric lengths
    var x = (sa_box[1] - sa_box[0]) * ss_ext;
    gr_u0 = sa_box[0] - x;
    const lu = (sa_box[1] + x) - gr_u0;
    x = (sa_box[3] - sa_box[2]) * ss_ext;
    gr_v0 = sa_box[2] - x;
    const lv = (sa_box[3] + x) - gr_v0;
    const ev = nb.srfEval(sa_s, (sa_box[0] + sa_box[1]) * 0.5, (sa_box[2] + sa_box[3]) * 0.5);
    const mu = nb.v3len(ev[1]) * lu; // metric lengths Lu, Lv
    const mv = maxsd(nb.v3len(ev[2]) * lv, ss_tiny);
    // nu = sqrt(N Lu / Lv), 4 .. 400
    var a = maxsd(mu, ss_tiny) / mv;
    a = a * fl(GRIDN);
    a = @sqrt(a);
    a = minsd(maxsd(a, 4.0), 400.0);
    const nu = nb.cvtt(a);
    gr_nu = @bitCast(nu);
    var b = fl(GRIDN) / fl(nu);
    b = minsd(maxsd(b, 4.0), 400.0);
    gr_nv = @bitCast(nb.cvtt(b));
    if (gr_nu > 400 or gr_nv > 400) return; // (NaN sizes: no grid)
    gr_du = lu / fl(gr_nu);
    gr_dv = lv / fl(gr_nv);
    // values
    const nval = (gr_nu + 1) * (gr_nv + 1);
    gr_f = nb.doubles(nval + 2) orelse return;
    var j: u32 = 0;
    while (j <= gr_nv) : (j += 1) {
        // (b's hint carried along the row)
        var h: [2]f64 = .{ (sb_box[0] + sb_box[1]) * 0.5, (sb_box[2] + sb_box[3]) * 0.5 };
        var i: u32 = 0;
        while (i <= gr_nu) : (i += 1) {
            const uv = grUv(i, j);
            const p = nb.srfEval(sa_s, uv[0], uv[1])[0];
            const d = sfDist(sb_s, p, h[0], h[1]);
            h = d.uv;
            gr_f[(gr_nu + 1) * j + i] = d.d;
        }
    }
    // crossings: one slot per grid edge; horizontal edges first, then vertical
    const slots = nval * 2;
    const m = nb.data(@as(usize, slots) * 32 + 16) orelse return;
    gr_x = @ptrCast(m);
    @memset(@as([*]u64, @ptrCast(m))[0 .. @as(usize, slots) * 4], 0xffffffffffffffff);
    j = 0;
    while (j < gr_nv) : (j += 1) {
        var i: u32 = 0;
        while (i < gr_nu) : (i += 1) {
            var c: MA = .{};
            crossEdge(&c, i, j, i + 1, j); // bottom
            crossEdge(&c, i + 1, j, i + 1, j + 1); // right
            crossEdge(&c, i, j + 1, i + 1, j + 1); // top
            crossEdge(&c, i, j, i, j + 1); // left
            if (c.ne == 2) {
                link(c.e[0], c.e[1]);
            } else if (c.ne == 4) {
                // a saddle: pair by the centre's sign
                var s = grVal(i, j);
                s += grVal(i + 1, j);
                s += grVal(i + 1, j + 1);
                s += grVal(i, j + 1);
                if (!jb(grVal(i, j) * s, 0)) {
                    link(c.e[0], c.e[1]);
                    link(c.e[2], c.e[3]);
                } else {
                    link(c.e[0], c.e[3]);
                    link(c.e[1], c.e[2]);
                }
            }
        }
    }
    // chains: from open ends first, then closed loops
    for (0..2) |pass| {
        var s: u32 = 0;
        while (s < slots) : (s += 1) {
            const r = &gr_x[s];
            if (@as(u64, @bitCast(r.uv[0])) == 0xffffffffffffffff) continue;
            if (r.traced != 0) continue;
            const nl = @as(u32, @intFromBool(r.link[0] != NONE)) + @intFromBool(r.link[1] != NONE);
            if (nl != pass + 1) continue;
            trace(s, @intCast(pass));
        }
    }
}

/// cross_edge: a crossing on that grid edge (made once), its id added to the cell's list
fn crossEdge(c: *MA, ia: u32, ja0: u32, ib: u32, jb1: u32) void {
    const f0 = grVal(ia, ja0);
    const f1 = grVal(ib, jb1);
    if (jae(f1, 0) == jae(f0, 0)) return; // a sign change (zero counts as +)
    var id = (gr_nu + 1) * ja0 + ia;
    if (ja0 != jb1) id += (gr_nu + 1) * (gr_nv + 1); // vertical: after the horizontal ones
    const r = &gr_x[id];
    if (@as(u64, @bitCast(r.uv[0])) == 0xffffffffffffffff) {
        const t = f0 / (f0 - f1);
        const a = grUv(ia, ja0);
        const b = grUv(ib, jb1);
        r.uv = .{ (b[0] - a[0]) * t + a[0], (b[1] - a[1]) * t + a[1] };
        r.link = .{ NONE, NONE };
        r.traced = 0;
    }
    if (c.ne >= 4) return;
    c.e[c.ne] = id;
    c.ne += 1;
}

fn link(a: u32, b: u32) void {
    var r = &gr_x[a];
    if (r.link[0] == NONE) r.link[0] = b else r.link[1] = b;
    r = &gr_x[b];
    if (r.link[0] == NONE) r.link[0] = a else r.link[1] = a;
}

/// trace(start crossing, closed): a section along the links, each point
/// refined onto both surfaces; then points added where needed
fn trace(start: u32, closed: u32) void {
    const r = scBegin() orelse return;
    r.closed = closed;
    var prev: u32 = NONE;
    var cur = start;
    sp_cont = true;
    while (true) {
        const x = &gr_x[cur];
        x.traced = 1;
        const p = nb.srfEval(sa_s, x.uv[0], x.uv[1])[0];
        _ = scPoint(p, x.uv[0], x.uv[1]);
        var nx = x.link[0];
        if (nx == prev) nx = x.link[1];
        if (nx == NONE or nx == start) break;
        if (gr_x[nx].traced != 0) break;
        prev = cur;
        cur = nx;
    }
    sp_cont = false;
    scEnd(r);
    if (r.n < 2) return;
    densify(r);
}

/// densify(the last section): points added between neighbours whose middle
/// (refined) is off their chord by more than the tolerance
fn densify(r: *Sec) void {
    var k: u32 = 0;
    while (true) {
        var pieces = r.n;
        if (r.closed == 0) pieces -%= 1;
        if (k >= pieces) return;
        if (r.n >= 65536) return;
        const ai = r.first + k;
        const bi = if (k + 1 < r.n) ai + 1 else r.first;
        const ni = spNew() orelse return;
        const a = &ss_pts[ai];
        const b = &ss_pts[bi];
        const q = &ss_pts[ni];
        const af: *const [7]f64 = @ptrCast(a);
        const bf: *const [7]f64 = @ptrCast(b);
        const qf: *[7]f64 = @ptrCast(q);
        for (0..7) |c| qf[c] = (af[c] + bf[c]) * 0.5;
        const ok = if (ss_swap) refine(sb_s, sa_s, q) else refine(sa_s, sb_s, q);
        ss_np -= 1; // (the slot was only scratch)
        if (!ok) {
            k += 1;
            continue;
        }
        var d: f64 = 0;
        for (0..3) |c| {
            var x = (af[c] + bf[c]) * 0.5;
            x = x - qf[c];
            d += x * x;
        }
        if (jbe(@sqrt(d), ss_tol)) {
            k += 1;
            continue;
        }
        // insert after k: the records after it move up one
        const keep = q.*;
        var m = ss_np;
        while (m > ai + 1) : (m -= 1) ss_pts[m] = ss_pts[m - 1];
        ss_pts[ai + 1] = keep;
        ss_np += 1;
        r.n += 1;
    }
}

test "bssi compiles" {
    std.testing.refAllDecls(@This());
}
