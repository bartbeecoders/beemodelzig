//! brep.s: the B-rep topology. A body is a run of faces; a face is part of
//! one surface (nurbs.zig), inside its loops; a loop is a run of coedges; a
//! coedge walks an edge one way and carries the edge's curve in the face's
//! (u, v) (its pcurve); an edge is part of a 3D curve between two vertices.
//! Records live in arenas and name each other by index; a rebuild starts
//! them all again.
//!
//! Orientation: a face's outside is Su x Sv, or its opposite when its sense
//! is 1. Seen from outside, a face's first (outer) loop turns counter-
//! clockwise and its holes clockwise; every edge of a closed body is walked
//! once each way.
//!
//! Builders give the surfaces, edges and loops; fcPcurves makes the pcurves
//! (exact for lines and conics on planes and for straight (u, v) images, an
//! adaptive polyline otherwise), fcOrient turns the loops and sets the sense
//! by asking which side of the face is inside the solid. bdVolume and bdArea
//! integrate over the faces with Green's theorem in (u, v): Gauss-Legendre
//! along each pcurve and across u.
const std = @import("std");
const nb = @import("nurbs.zig");
const V3 = nb.V3;
const jb = nb.jb;
const ja = nb.ja;
const jae = nb.jae;
const jbe = nb.jbe;
const je = nb.je;
const maxsd = nb.maxsd;
const minsd = nb.minsd;
const fabs = nb.fabs;
const fneg = nb.fneg;
const fl = nb.fl;

pub const NONE: u32 = 0xffffffff;

pub const Vertex = extern struct {
    p: V3,
    tol: f64,
};
pub const EF_DEGEN = 1; // collapsed to a point (a sphere's pole)
pub const EF_SEAM = 2;
pub const Edge = extern struct {
    curve: u32,
    v0: u32,
    v1: u32,
    flags: u32,
    t0: f64,
    t1: f64,
    tol: f64,
    poly: ?[*]f64, // tessellation: (x, y, z, t) per point
    npoly: u32,
    mark: u32,
    aux: u32,
    _pad: u32,
};
pub const Coedge = extern struct {
    edge: u32,
    rev: u32, // 1: walked vb -> va
    pc: u32, // its curve in the face's (u, v)
    loop: u32,
    p0: f64, // the (u, v) curve's parameter at the coedge's start and end
    p1: f64,
    aux: u32,
    _pad: [3]u32,
};
pub const Loop = extern struct {
    first: u32,
    n: u32,
    face: u32,
    flags: u32,
};
pub const Face = extern struct {
    surf: u32,
    sense: u32, // 1: the outside is -(Su x Sv)
    loop: u32, // loops first .. first + n - 1 (the first is the outer one)
    nloop: u32,
    color: u32,
    flags: u32,
    u0: f64, // its (u, v) box
    u1: f64,
    v0: f64,
    v1: f64,
    src: u32, // the face it came from (booleans)
    mark: u32,
};
pub const Body = extern struct {
    first: u32,
    nf: u32,
    flags: u32,
    _pad: u32,
    tri: ?*anyopaque, // tessellation (btess.zig)
    tol: f64, // linear tolerance
    min: [3]f32,
    max: [3]f32,
    _pad2: [2]u32,
};
comptime {
    std.debug.assert(@sizeOf(Vertex) == 32);
    std.debug.assert(@sizeOf(Edge) == 64 and @offsetOf(Edge, "poly") == 40 and @offsetOf(Edge, "aux") == 56);
    std.debug.assert(@sizeOf(Coedge) == 48 and @offsetOf(Coedge, "aux") == 32);
    std.debug.assert(@sizeOf(Loop) == 16);
    std.debug.assert(@sizeOf(Face) == 64 and @offsetOf(Face, "src") == 56);
    std.debug.assert(@sizeOf(Body) == 64 and @offsetOf(Body, "min") == 32 and @offsetOf(Body, "max") == 44);
}

pub var bk_vx: nb.Arena = .{ .cap = 0x10000000 };
pub var bk_ed: nb.Arena = .{ .cap = 0x10000000 };
pub var bk_ce: nb.Arena = .{ .cap = 0x10000000 };
pub var bk_lp: nb.Arena = .{ .cap = 0x10000000 };
pub var bk_fc: nb.Arena = .{ .cap = 0x10000000 };
pub var bk_bd: nb.Arena = .{ .cap = 0x10000000 };
var ready = false;
var fb_f: u32 = 0; // the face being built
var fb_l: u32 = 0; // its loop being built
var bb_first: u32 = 0;

// bd_stats / bd_check
pub var bs_v: u32 = 0;
pub var bs_e: u32 = 0;
pub var bs_f: u32 = 0;
pub var bs_l: u32 = 0;
pub var bs_bad: u32 = 0;

const br_pi: f64 = 3.14159265358979323846;
const br_2pi: f64 = 6.28318530717958647692;
const br_lin: f64 = 1.0e-10; // (relative) a pcurve is straight
const br_pctol: f64 = 1.0e-8; // (relative) polyline pcurves
const br_pole: f64 = 1.0e-11; // (relative) on a surface's pole
const br_nwt: f64 = 1.0e-15;
const br_on9: f64 = 1.0e-9;
const br_in: f64 = 1.0e-4;
const br_big: f64 = 1.0e300;
const br_third: f64 = 0.33333333333333333333;
// Gauss-Legendre, 8 points on [-1, 1]
pub const gl_x = [8]f64{ -0.9602898564975363, -0.7966664774136267, -0.5255324099163290, -0.1834346424956498, 0.1834346424956498, 0.5255324099163290, 0.7966664774136267, 0.9602898564975363 };
pub const gl_w = [8]f64{ 0.1012285362903763, 0.2223810344533745, 0.3137066458778873, 0.3626837833783620, 0.3626837833783620, 0.3137066458778873, 0.2223810344533745, 0.1012285362903763 };

// ---- storage ---------------------------------------------------------------------------
/// br_init: the arenas exist (nothing reset).
pub fn init() void {
    if (!ready) reset();
}

/// br_reset: the kernel starts empty (nurbs.zig's arenas too).
pub fn reset() void {
    nb.reset();
    if (!ready) {
        _ = bk_vx.init();
        _ = bk_ed.init();
        _ = bk_ce.init();
        _ = bk_lp.init();
        _ = bk_fc.init();
        _ = bk_bd.init();
        ready = true;
    }
    bk_vx.reset();
    bk_ed.reset();
    bk_ce.reset();
    bk_lp.reset();
    bk_fc.reset();
    bk_bd.reset();
}

pub inline fn vx(i: u32) *Vertex {
    return bk_vx.rec(Vertex, i);
}
pub inline fn ed(i: u32) *Edge {
    return bk_ed.rec(Edge, i);
}
pub inline fn ce(i: u32) *Coedge {
    return bk_ce.rec(Coedge, i);
}
pub inline fn lp(i: u32) *Loop {
    return bk_lp.rec(Loop, i);
}
pub inline fn fc(i: u32) *Face {
    return bk_fc.rec(Face, i);
}
pub inline fn bd(i: u32) *Body {
    return bk_bd.rec(Body, i);
}
pub inline fn cv(i: u32) *nb.Curve {
    return nb.cv(i);
}
pub inline fn sf(i: u32) *nb.Surface {
    return nb.sf(i);
}

/// nw: a cleared record and its index (null and NONE when the arena is full)
fn nw(comptime T: type, a: *nb.Arena) struct { p: ?*T, i: u32 } {
    const m = a.alloc(@sizeOf(T)) orelse return .{ .p = null, .i = NONE };
    const r: *T = @ptrCast(m);
    r.* = std.mem.zeroes(T);
    return .{ .p = r, .i = @intCast((@intFromPtr(m) - @intFromPtr(a.base)) / @sizeOf(T)) };
}
/// next_ix: the index the arena's next record gets
pub fn nextIx(comptime T: type, a: *nb.Arena) u32 {
    return @intCast(std.mem.alignForward(usize, a.used, 16) / @sizeOf(T));
}
pub fn nVx() u32 {
    return nextIx(Vertex, &bk_vx);
}
pub fn nEd() u32 {
    return nextIx(Edge, &bk_ed);
}
pub fn nCe() u32 {
    return nextIx(Coedge, &bk_ce);
}
pub fn nLp() u32 {
    return nextIx(Loop, &bk_lp);
}
pub fn nFc() u32 {
    return nextIx(Face, &bk_fc);
}
pub fn nBd() u32 {
    return nextIx(Body, &bk_bd);
}

/// n_vx: a new vertex there
pub fn newVx(p: V3) u32 {
    const r = nw(Vertex, &bk_vx);
    if (r.p) |v| v.p = p;
    return r.i;
}

/// n_ed: a new edge
pub fn newEd(curve: u32, va: u32, vb: u32, t0: f64, t1: f64) u32 {
    const r = nw(Edge, &bk_ed);
    if (r.p) |e| {
        e.curve = curve;
        e.v0 = va;
        e.v1 = vb;
        e.t0 = t0;
        e.t1 = t1;
        e.aux = NONE;
    }
    return r.i;
}

/// fb_face(surface, u hint, v hint (the middle of its range on periodic
/// surfaces)) -> a new face, the one being built
pub fn fbFace(surf: u32, uh: f64, vh: f64) u32 {
    const r = nw(Face, &bk_fc);
    if (r.p) |f| {
        f.surf = surf;
        f.u0 = uh;
        f.u1 = uh;
        f.v0 = vh;
        f.v1 = vh;
        f.src = NONE;
        fb_f = r.i;
        f.loop = nextIx(Loop, &bk_lp);
    }
    return r.i;
}

/// fb_loop: a new loop of the face being built
pub fn fbLoop() u32 {
    const r = nw(Loop, &bk_lp);
    if (r.p) |l| {
        fb_l = r.i;
        l.face = fb_f;
        l.first = nextIx(Coedge, &bk_ce);
        fc(fb_f).nloop += 1;
    }
    return r.i;
}

/// fb_ce(edge, 1: walked vb -> va) -> a new coedge of the loop
pub fn fbCe(edge: u32, rev: u32) u32 {
    const r = nw(Coedge, &bk_ce);
    if (r.p) |c| {
        c.edge = edge;
        c.rev = rev;
        c.pc = NONE;
        c.loop = fb_l;
        lp(fb_l).n += 1;
    }
    return r.i;
}

/// bb_begin: a body starts with the next face
pub fn bbBegin() void {
    bb_first = nextIx(Face, &bk_fc);
}
/// bb_end -> the body
pub fn bbEnd() u32 {
    const end = nextIx(Face, &bk_fc);
    const r = nw(Body, &bk_bd);
    if (r.p) |b| {
        b.first = bb_first;
        b.nf = end -% bb_first;
    }
    return r.i;
}

// ---- curves and surfaces -----------------------------------------------------------------
/// mk_line(a, b) -> a line from a (t = 0) towards b, and the length (b's parameter)
pub fn mkLine(a: V3, b: V3) struct { i: u32, len: f64 } {
    const c = nb.kcNew().?;
    c.typ = nb.CT_LINE;
    c.dim = 3;
    c.o = a;
    c.x = nb.v3sub(b, a);
    const l = nb.v3norm(&c.x);
    return .{ .i = nb.cvIndex(c), .len = l };
}

/// mk_conic(CT_CIRCLE / CT_ELLIPSE, O X Y, R1, R2) -> the curve
pub fn mkConic(typ: u32, fr: *const [3]V3, r1: f64, r2: f64) u32 {
    const c = nb.kcNew().?;
    c.typ = typ;
    c.dim = 3;
    c.o = fr[0];
    c.x = fr[1];
    c.y = fr[2];
    c.r1 = r1;
    c.r2 = r2;
    return nb.cvIndex(c);
}

/// mk_surf(type, O X Y, R1, R2) -> an analytic surface (Z = X x Y; a cone's
/// R2 is its half angle)
pub fn mkSurf(typ: u32, fr: *const [3]V3, r1: f64, r2: f64) u32 {
    const s = nb.ksNew().?;
    s.typ = typ;
    s.o = fr[0];
    s.x = fr[1];
    s.y = fr[2];
    s.z = nb.v3cross(s.x, s.y);
    s.r1 = r1;
    s.r2 = r2;
    const sc = nb.dsincos(r2);
    s.sa = sc[0];
    s.ca = sc[1];
    return nb.sfIndex(s);
}

/// wrap: the angle within pi of the centre
pub fn wrap(a_in: f64, centre: f64) f64 {
    var a = a_in;
    var d = a - centre;
    while (ja(d, br_pi)) {
        a -= br_2pi;
        d -= br_2pi;
    }
    const lo = fneg(br_pi);
    while (jb(d, lo)) {
        // (NaN: the original loops for ever; stop)
        if (d != d) break;
        a += br_2pi;
        d += br_2pi;
    }
    return a;
}

/// sf_normal: the point and the unit Su x Sv
pub fn sfNormal(s: *const nb.Surface, u: f64, v: f64) [2]V3 {
    const e = nb.srfEval(s, u, v);
    var n = nb.v3cross(e[1], e[2]);
    _ = nb.v3norm(&n);
    return .{ e[0], n };
}

pub const Inv = struct { u: f64, v: f64, pole: bool };

/// sf_invert(surface, point, u hint, v hint) -> (u, v) of the point on the
/// surface nearest it; pole when at a pole (u has no meaning there: the hint
/// is given back)
pub fn sfInvert(s: *const nb.Surface, p: V3, uh: f64, vh: f64) Inv {
    if (s.typ == nb.ST_NURBS) {
        const r = sfProject(s, p, uh, vh);
        const q = nb.srfEval(s, r[0], r[1])[0];
        const tol = nb.v3len(p) * br_on9 + br_nwt;
        if (!ja(nb.v3dist(q, p), tol)) return .{ .u = r[0], .v = r[1], .pole = false };
        const seed = nurbsSeed(s, p);
        const r2 = sfProject(s, p, seed[0], seed[1]);
        return .{ .u = r2[0], .v = r2[1], .pole = false };
    }
    const d = nb.v3sub(p, s.o);
    const x = nb.v3dot(d, s.x);
    const y = nb.v3dot(d, s.y);
    const z = nb.v3dot(d, s.z);
    if (s.typ == nb.ST_PLANE) return .{ .u = x, .v = y, .pole = false };
    const u = wrap(nb.datan2(y, x), uh);
    const rho = @sqrt(x * x + y * y);
    var v: f64 = undefined;
    switch (s.typ) {
        nb.ST_CYL => v = z,
        nb.ST_CONE => {
            const a = (rho - s.r1) * s.sa;
            v = z * s.ca + a;
        },
        nb.ST_SPHERE => v = nb.datan2(z, rho),
        else => v = wrap(nb.datan2(z, rho - s.r1), vh),
    }
    if (s.typ == nb.ST_CYL) return .{ .u = u, .v = v, .pole = false };
    // pole: rho tiny
    var t = fabs(s.r1) + s.r2;
    t += fabs(z);
    t *= br_pole;
    if (!jbe(t, rho)) return .{ .u = uh, .v = v, .pole = true };
    return .{ .u = u, .v = v, .pole = false };
}

// nurbs_seed: the nearest of 17 x 17 samples over the knot ranges
var seed_keep: [2]f64 = .{ 0, 0 };
fn nurbsSeed(s: *const nb.Surface, p: V3) [2]f64 {
    var best = br_big;
    var r = seed_keep; // (the original leaves its stack there when none is nearer)
    var i: u32 = 0;
    while (i <= 16) : (i += 1) {
        var j: u32 = 0;
        while (j <= 16) : (j += 1) {
            const u = knotAt(i, s.ku.?, s.du, s.nu);
            const v = knotAt(j, s.kv.?, s.dv, s.nv);
            const d = nb.v3dist(nb.srfEval(s, u, v)[0], p);
            if (jae(d, best)) continue;
            best = d;
            r = .{ u, v };
        }
    }
    seed_keep = r;
    return r;
}
fn knotAt(i: u32, k: [*]const f64, deg: u32, n: u32) f64 {
    const a = k[deg];
    var d = k[n] - a;
    d = d * fl(i);
    d = d / 16.0;
    return a + d;
}

/// sf_project(surface, point, u, v start) -> the nearest (u, v) by
/// Gauss-Newton (NURBS: kept in the knot ranges)
pub fn sfProject(s: *const nb.Surface, p: V3, ua: f64, va: f64) [2]f64 {
    var u = ua;
    var v = va;
    var it: u32 = 0;
    while (it < 40) : (it += 1) {
        const e = nb.srfEval(s, u, v);
        const r = nb.v3sub(p, e[0]);
        const a = nb.v3dot(e[1], e[1]);
        const b = nb.v3dot(e[1], e[2]);
        const c = nb.v3dot(e[2], e[2]);
        const ee = nb.v3dot(e[1], r);
        const ff = nb.v3dot(e[2], r);
        const det = a * c - b * b;
        if (jbe(fabs(det), br_nwt)) break;
        const du = (c * ee - b * ff) / det;
        const dv = (a * ff - b * ee) / det;
        var nu = u + du;
        var nv = v + dv;
        if (s.typ == nb.ST_NURBS) {
            nu = minsd(maxsd(nu, s.ku.?[s.du]), s.ku.?[s.nu]);
            nv = minsd(maxsd(nv, s.kv.?[s.dv]), s.kv.?[s.nv]);
        }
        u = nu;
        v = nv;
        if (jbe(fabs(du) + fabs(dv), br_nwt)) break;
    }
    return .{ u, v };
}

// ---- pcurves ---------------------------------------------------------------------------
/// ed_mid: an edge's middle point
pub fn edMid(e: u32) V3 {
    const r = ed(e);
    const t = (r.t0 + r.t1) * 0.5;
    return nb.crvEval(cv(r.curve), t)[0];
}

/// ce_edge_dir -> t at the coedge's start and its end
pub fn ceEdgeDir(c: u32) [2]f64 {
    const r = ce(c);
    const e = ed(r.edge);
    if (r.rev != 0) return .{ e.t1, e.t0 };
    return .{ e.t0, e.t1 };
}

/// ce_uv(coedge, s in 0 .. 1 along it) -> (u, v) and (du, dv) / d(pcurve
/// parameter) of its pcurve
pub fn ceUv(c: u32, s: f64) [4]f64 {
    const r = ce(c);
    var p = r.p1 - r.p0;
    p = p * s;
    p = p + r.p0;
    if (r.pc == NONE) return .{ 0, 0, 0, 0 }; // (the original reads past its arena)
    const e = nb.crvEval(cv(r.pc), p);
    return .{ e[0][0], e[0][1], e[1][0], e[1][1] };
}

const MAXPC = 8192;
var pc_t: [MAXPC]f64 = undefined;
var pc_uv: [MAXPC][2]f64 = undefined;
var pc_pole: [MAXPC]u8 = undefined;
var pc_n: u32 = 0;
/// pcMake: start near pcHint (continuing round a seam)
pub var pc_hint_ok: bool = false;
pub var pc_hint: [2]f64 = .{ 0, 0 };

const PM = struct {
    s: *const nb.Surface,
    e: *Edge,
    c: *Coedge,
    ts: f64,
    te: f64,
    uh: f64,
    vh: f64,
};

/// pc_make(coedge, face): the coedge's pcurve on the face's surface
/// (degenerate edges are left to fcPcurves)
pub fn pcMake(ci: u32, fi: u32) void {
    const c = ce(ci);
    const e = ed(c.edge);
    if (e.flags & EF_DEGEN != 0) return;
    const f = fc(fi);
    var m: PM = .{
        .s = sf(f.surf),
        .e = e,
        .c = c,
        .ts = 0,
        .te = 0,
        .uh = (f.u0 + f.u1) * 0.5,
        .vh = (f.v0 + f.v1) * 0.5,
    };
    if (pc_hint_ok) {
        m.uh = pc_hint[0];
        m.vh = pc_hint[1];
    }
    const t = ceEdgeDir(ci);
    m.ts = t[0];
    m.te = t[1];
    var pcv: *nb.Curve = undefined;
    if (m.s.typ == nb.ST_PLANE) {
        // the curve's affine image in the plane's coordinates, the same parameter
        const src = cv(e.curve);
        pcv = nb.kcNew().?;
        pcv.* = src.*;
        pcv.dim = 2;
        pcv.o = planeMap(m.s, pcv.o, true);
        pcv.x = planeMap(m.s, pcv.x, false);
        pcv.y = planeMap(m.s, pcv.y, false);
        if (src.typ == nb.CT_NURBS) {
            const cp = nb.doubles(@as(usize, src.n) * 4).?;
            pcv.cp = cp;
            var k: u32 = 0;
            while (k < src.n) : (k += 1) {
                const q = src.cp.? + k * 4;
                const w = q[3];
                const a = planeMap(m.s, .{ q[0] / w, q[1] / w, q[2] / w }, true);
                cp[k * 4] = a[0] * w;
                cp[k * 4 + 1] = a[1] * w;
                cp[k * 4 + 2] = 0;
                cp[k * 4 + 3] = w;
            }
        }
        c.p0 = m.ts;
        c.p1 = m.te;
    } else {
        // a polyline edge: its own points (its pcurve follows it point for point)
        pc_n = 0;
        const ec = cv(e.curve);
        var line = false;
        var poly_only = false;
        if (ec.typ == nb.CT_NURBS and ec.deg == 1) {
            pcKnots(&m, ec);
            pcFixpoles();
            if (pcStraight()) line = true else poly_only = true;
        } else {
            // nine samples: a straight line in (u, v)?
            var k: u32 = 0;
            while (k <= 8) : (k += 1) {
                var t0 = fl(k) / 8.0;
                t0 = t0 * (m.te - m.ts);
                t0 = t0 + m.ts;
                pcPush(&m, t0);
            }
            pcFixpoles();
            line = pcStraight();
        }
        if (line) {
            // a line from the first (u, v) to the last
            pcv = nb.kcNew().?;
            pcv.typ = nb.CT_LINE;
            pcv.dim = 2;
            const a = pc_uv[0];
            const b = pc_uv[pc_n - 1];
            pcv.o[0] = a[0];
            pcv.o[1] = a[1];
            pcv.x[0] = b[0] - a[0];
            pcv.x[1] = b[1] - a[1];
            const l = nb.v3norm(&pcv.x);
            c.p0 = 0;
            c.p1 = l;
        } else {
            if (!poly_only) pcRefine(&m);
            pcv = pcPolyline() orelse return;
            c.p0 = m.ts;
            c.p1 = m.te;
        }
    }
    c.pc = nb.cvIndex(pcv);
}

/// plane_map: a vector's (or a point's) plane coordinates (u, v, 0)
fn planeMap(s: *const nb.Surface, a: V3, point: bool) V3 {
    var d = a;
    if (point) d = nb.v3sub(d, s.o);
    return .{ nb.v3dot(d, s.x), nb.v3dot(d, s.y), 0 };
}

/// pc_push: the edge point at t, inverted, appended
fn pcPush(m: *const PM, t: f64) void {
    if (pc_n >= MAXPC) return;
    pc_t[pc_n] = t;
    const p = nb.crvEval(cv(m.e.curve), t);
    var uh = m.uh;
    var vh = m.vh;
    if (pc_n != 0) {
        uh = pc_uv[pc_n - 1][0];
        vh = pc_uv[pc_n - 1][1];
    }
    const r = sfInvert(m.s, p[0], uh, vh);
    pc_pole[pc_n] = @intFromBool(r.pole);
    pc_uv[pc_n] = .{ r.u, r.v };
    pc_n += 1;
}

/// pc_knots: samples at a polyline edge's own points between its t at the
/// start and the end, in walking order
fn pcKnots(m: *const PM, c: *const nb.Curve) void {
    pcPush(m, m.ts);
    var i: i32 = 1;
    var step: i32 = 1;
    if (!jae(m.te, m.ts)) {
        i = @intCast(c.n);
        step = -1;
    }
    const n: i32 = @intCast(c.n);
    while (i >= 1 and i <= n) : (i += step) {
        const x = c.kn.?[@intCast(i)];
        const lo = minsd(m.ts, m.te);
        const hi = maxsd(m.ts, m.te);
        if (jbe(x, lo)) continue;
        if (jae(x, hi)) continue;
        if (pc_n >= MAXPC - 1) break;
        pcPush(m, x);
    }
    pcPush(m, m.te);
}

/// pc_fixpoles: samples at a pole take u from their neighbour
fn pcFixpoles() void {
    var i: u32 = 0;
    while (i < pc_n) : (i += 1) {
        if (pc_pole[i] == 0) continue;
        var j: u32 = i + 1;
        if (j >= pc_n) {
            if (i == 0) continue;
            j = i - 1;
        }
        pc_uv[i][0] = pc_uv[j][0];
    }
}

/// pc_straight: the samples lie on the line from the first to the last (in
/// (u, v), relative to the chord)
fn pcStraight() bool {
    const a = pc_uv[0];
    const b = pc_uv[pc_n -% 1];
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const d = @sqrt(dx * dx + dy * dy);
    if (je(d, 0)) return false;
    const tol = d * br_lin + br_nwt;
    var i: u32 = 1;
    while (i < pc_n) : (i += 1) {
        var x = pc_uv[i][0] - a[0];
        var y = pc_uv[i][1] - a[1];
        x = x * dy;
        y = y * dx;
        x = x - y;
        x = x / d;
        if (ja(fabs(x), tol)) return false;
    }
    return true;
}

/// pc_refine: samples added until every piece's middle lies on its chord
/// (in (u, v), relative to the face's extent)
fn pcRefine(m: *const PM) void {
    var ua = pc_uv[0][0];
    var ub = ua;
    var va = pc_uv[0][1];
    var vb = va;
    var i: u32 = 0;
    while (i < pc_n) : (i += 1) {
        ua = minsd(ua, pc_uv[i][0]);
        ub = maxsd(ub, pc_uv[i][0]);
        va = minsd(va, pc_uv[i][1]);
        vb = maxsd(vb, pc_uv[i][1]);
    }
    var tol = ub - ua;
    tol = tol + (vb - va);
    tol = tol * br_pctol + br_nwt;
    var passes: u32 = 0;
    out: while (true) {
        var ins: u32 = 0;
        var k: u32 = 0;
        while (k < pc_n -% 1) {
            if (pc_n >= MAXPC - 1) break :out;
            const t = (pc_t[k] + pc_t[k + 1]) * 0.5;
            pcPushTmp(m, t, k);
            const tmp = pc_uv[pc_n];
            var x = (pc_uv[k][0] + pc_uv[k + 1][0]) * 0.5;
            var y = (pc_uv[k][1] + pc_uv[k + 1][1]) * 0.5;
            x -= tmp[0];
            y -= tmp[1];
            if (jbe(fabs(x) + fabs(y), tol)) {
                k += 1;
                continue;
            }
            // insert it after sample k (move the rest up one)
            const pole = pc_pole[pc_n];
            var c = pc_n;
            while (c > k + 1) : (c -= 1) {
                pc_t[c] = pc_t[c - 1];
                pc_uv[c] = pc_uv[c - 1];
                pc_pole[c] = pc_pole[c - 1];
            }
            pc_t[k + 1] = t;
            pc_uv[k + 1] = tmp;
            pc_pole[k + 1] = pole;
            pc_n += 1;
            ins += 1;
            k += 2; // (both halves wait for the next pass)
        }
        if (ins == 0) break;
        passes += 1;
        if (passes >= 16) break;
    }
    pcFixpoles();
}
/// pc_push_tmp: like pcPush into slot pc_n without counting it (hinted by sample k)
fn pcPushTmp(m: *const PM, t: f64, k: u32) void {
    pc_t[pc_n] = t;
    const p = nb.crvEval(cv(m.e.curve), t);
    const r = sfInvert(m.s, p[0], pc_uv[k][0], pc_uv[k][1]);
    pc_pole[pc_n] = @intFromBool(r.pole);
    pc_uv[pc_n] = .{ r.u, r.v };
}

/// pc_polyline: the samples as a degree 1 NURBS in (u, v) over t (ordered by
/// increasing t), or null
fn pcPolyline() ?*nb.Curve {
    const c = nbNewExt(1, pc_n) orelse return null;
    c.dim = 2;
    const n = pc_n;
    const back = ja(pc_t[0], pc_t[n -% 1]);
    const kn = c.kn.?;
    const cp = c.cp.?;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const at = if (back) n - 1 - i else i;
        kn[i + 1] = pc_t[at];
        cp[i * 4] = pc_uv[at][0];
        cp[i * 4 + 1] = pc_uv[at][1];
        cp[i * 4 + 2] = 0;
        cp[i * 4 + 3] = 1;
    }
    kn[0] = kn[1];
    kn[n + 1] = kn[n];
    return c;
}

/// nb_new_ext: nurbs.zig's nbNew, re-done here
pub fn nbNewExt(deg: u32, n: u32) ?*nb.Curve {
    const c = nb.kcNew() orelse return null;
    c.typ = nb.CT_NURBS;
    c.dim = 3;
    c.deg = deg;
    c.n = n;
    c.kn = nb.doubles(deg + n + 1);
    c.cp = nb.doubles(@as(usize, n) * 4);
    if (c.kn == null or c.cp == null) return null;
    return c;
}

// ---- faces -----------------------------------------------------------------------------
/// fc_pcurves(face): pcurves for every coedge; a degenerate one (at a pole)
/// runs straight from where the coedge before it ends to where the one after
/// it starts
pub fn fcPcurves(fi: u32) void {
    const f = fc(fi);
    const l0 = f.loop;
    const l1 = f.loop + f.nloop;
    var l = l0;
    while (l < l1) : (l += 1) {
        const first = lp(l).first;
        const end = first + lp(l).n;
        var c = first;
        while (c < end) : (c += 1) {
            if (ce(c).pc != NONE) continue; // (kept when it has one)
            pc_hint_ok = false;
            if (c != first and ce(c - 1).pc != NONE) {
                const q = ceUv(c - 1, 1.0);
                pc_hint = .{ q[0], q[1] };
                pc_hint_ok = true;
            }
            pcMake(c, fi);
            pc_hint_ok = false;
        }
    }
    l = l0;
    while (l < l1) : (l += 1) {
        const first = lp(l).first;
        const n = lp(l).n;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const c = first + k;
            if (ce(c).pc != NONE) continue;
            if (ed(ce(c).edge).flags & EF_DEGEN == 0) continue;
            const a = ceUv(first + (k + n - 1) % n, 1.0);
            const b = ceUv(first + (k + 1) % n, 0.0);
            const pcv = nb.kcNew().?;
            pcv.typ = nb.CT_LINE;
            pcv.dim = 2;
            pcv.o[0] = a[0];
            pcv.o[1] = a[1];
            pcv.x[0] = b[0] - a[0];
            pcv.x[1] = b[1] - a[1];
            const len = nb.v3norm(&pcv.x);
            const r = ce(c);
            r.pc = nb.cvIndex(pcv);
            r.p0 = 0;
            r.p1 = len;
        }
    }
}

const FS_MAX = 16384;
const FS_MAXL = 256;
/// fcSample: every loop of a face as (u, v) points
pub var fs_pts: [FS_MAX][2]f64 = undefined;
pub var fs_ls: [FS_MAXL]u32 = undefined;
pub var fs_ln: [FS_MAXL]u32 = undefined;
pub var fs_nl: u32 = 0;
pub var fs_np: u32 = 0;

/// fc_sample(face, points per curved coedge): every loop as a closed (u, v)
/// polygon: fs_pts, loop k from fs_ls[k], fs_ln[k] points
pub fn fcSample(fi: u32, per: u32) void {
    const f = fc(fi);
    fs_nl = 0;
    fs_np = 0;
    var l = f.loop;
    const l1 = f.loop + f.nloop;
    while (l < l1) : (l += 1) {
        if (fs_nl >= FS_MAXL) return;
        fs_ls[fs_nl] = fs_np;
        var c = lp(l).first;
        const end = c + lp(l).n;
        while (c < end) : (c += 1) {
            // points: a straight pcurve 1, else n
            var n: u32 = 1;
            const pc = ce(c).pc;
            if (pc == NONE) continue;
            const p = cv(pc);
            if (p.typ != nb.CT_LINE) {
                n = per;
                if (p.typ == nb.CT_NURBS and p.deg == 1) {
                    const k: i32 = @as(i32, @bitCast(p.n)) - 1;
                    n = if (k >= 1) @intCast(k) else 1;
                }
            }
            var j: u32 = 0;
            while (j < n) : (j += 1) {
                if (fs_np >= FS_MAX) break;
                const q = ceUv(c, fl(j) / fl(n));
                fs_pts[fs_np] = .{ q[0], q[1] };
                fs_np += 1;
            }
        }
        fs_ln[fs_nl] = fs_np - fs_ls[fs_nl];
        fs_nl += 1;
    }
}

/// fs_area(loop of the samples) -> its signed area
pub fn fsArea(k: u32) f64 {
    const s = fs_ls[k];
    const n = fs_ln[k];
    var a: f64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const p = fs_pts[s + i];
        const q = fs_pts[s + (if (i + 1 < n) i + 1 else 0)];
        const x = p[0] * q[1] - q[0] * p[1];
        a += x;
    }
    return a * 0.5;
}

/// fc_inside(u, v): inside the sampled loops (even-odd)
pub fn fcInside(u: f64, v: f64) bool {
    var in = false;
    var l: u32 = 0;
    while (l < fs_nl) : (l += 1) {
        const s = fs_ls[l];
        const n = fs_ln[l];
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const p = fs_pts[s + i];
            const q = fs_pts[s + (if (i + 1 < n) i + 1 else 0)];
            if ((p[1] > v) == (q[1] > v)) continue;
            var x = v - p[1];
            x = x * (q[0] - p[0]);
            x = x / (q[1] - p[1]);
            x = x + p[0];
            if (jae(u, x)) continue;
            in = !in;
        }
    }
    return in;
}

pub const Classifier = *const fn (p: *const V3) bool;

/// fc_orient(face, classifier (point -> inside the solid), step off the
/// face): its sense, then its loops turned so the outer one comes first and
/// goes the right way round
pub fn fcOrient(fi: u32, cl: Classifier, eps: f64) void {
    const f = fc(fi);
    fcSample(fi, 24);
    const ip = fsInnerPoint() orelse return;
    var pn = sfNormal(sf(f.surf), ip[0], ip[1]);
    nb.v3axpy(&pn[0], pn[1], eps);
    f.sense = @intFromBool(cl(&pn[0]));
    // the outer loop: the largest area
    var best: f64 = 0;
    var out: u32 = 0;
    var k: u32 = 0;
    while (k < fs_nl) : (k += 1) {
        const a = fabs(fsArea(k));
        if (jbe(a, best)) continue;
        best = a;
        out = k;
    }
    // each loop: counter-clockwise (outer, sense 0) or clockwise
    k = 0;
    while (k < fs_nl) : (k += 1) {
        const a = fsArea(k);
        const want: u32 = @as(u32, @intFromBool(k == out)) ^ f.sense;
        const pos: u32 = @intFromBool(a > 0);
        if (want != pos) lpFlip(f.loop + k);
    }
    // the outer loop first
    if (out != 0) {
        const a = lp(f.loop);
        const b = lp(f.loop + out);
        const t = a.*;
        a.* = b.*;
        b.* = t;
    }
}

/// fs_inner_point -> a point inside the sampled loops (null: none found):
/// beside the middle of an edge of the polygon, a little in
pub fn fsInnerPoint() ?[2]f64 {
    if (fs_np == 0) return null;
    var ua = fs_pts[0][0];
    var ub = ua;
    var va = fs_pts[0][1];
    var vb = va;
    var i: u32 = 0;
    while (i < fs_np) : (i += 1) {
        ua = minsd(ua, fs_pts[i][0]);
        ub = maxsd(ub, fs_pts[i][0]);
        va = minsd(va, fs_pts[i][1]);
        vb = maxsd(vb, fs_pts[i][1]);
    }
    var step = maxsd(ub - ua, vb - va) * br_in;
    var tries: i32 = 1;
    while (true) {
        var k: u32 = 0;
        while (k < fs_np) : (k += 1) {
            const nx = fsNext(k);
            const a = fs_pts[k];
            const b = fs_pts[nx];
            var dx = b[0] - a[0];
            var dy = b[1] - a[1];
            const d = @sqrt(dx * dx + dy * dy);
            if (je(d, 0)) continue;
            const s = step / d;
            dy = dy * s;
            dx = dx * s;
            const mx = (b[0] + a[0]) * 0.5;
            const my = (b[1] + a[1]) * 0.5;
            var p = [2]f64{ mx - dy, my + dx };
            if (fcInside(p[0], p[1])) return p;
            p = .{ mx + dy, my - dx };
            if (fcInside(p[0], p[1])) return p;
        }
        tries -= 1;
        if (tries < 0) return null;
        step = step * br_in;
        step = step * br_in;
        step = step * br_2pi;
    }
}

/// fs_deep_point -> a point well inside the sampled loops (the farthest from
/// them of a 24 x 24 grid over their box); falls back to fsInnerPoint for
/// regions too thin for the grid
pub fn fsDeepPoint() ?[2]f64 {
    if (fs_np == 0) return fsInnerPoint();
    var ua = fs_pts[0][0];
    var ub = ua;
    var va = fs_pts[0][1];
    var vb = va;
    var i: u32 = 0;
    while (i < fs_np) : (i += 1) {
        ua = minsd(ua, fs_pts[i][0]);
        ub = maxsd(ub, fs_pts[i][0]);
        va = minsd(va, fs_pts[i][1]);
        vb = maxsd(vb, fs_pts[i][1]);
    }
    var best: f64 = 0;
    var found = false;
    var q: [2]f64 = undefined;
    i = 0;
    while (i < 24) : (i += 1) {
        var j: u32 = 0;
        while (j < 24) : (j += 1) {
            var x = (fl(i) + 0.5) / 24.0;
            x = x * (ub - ua);
            x = x + ua;
            var y = (fl(j) + 0.5) / 24.0;
            y = y * (vb - va);
            y = y + va;
            if (!fcInside(x, y)) continue;
            const d = fsSegDist(x, y);
            if (jbe(d, best)) continue;
            best = d;
            q = .{ x, y };
            found = true;
        }
    }
    if (found) return q;
    return fsInnerPoint();
}

/// fs_seg_dist: a point's distance to the sampled loops
fn fsSegDist(x: f64, y: f64) f64 {
    var best = br_big;
    var k: u32 = 0;
    while (k < fs_np) : (k += 1) {
        const nx = fsNext(k);
        const a = fs_pts[k];
        const b = fs_pts[nx];
        var dx = b[0] - a[0];
        var dy = b[1] - a[1];
        var wx = x - a[0];
        var wy = y - a[1];
        var t = wx * dx;
        t += wy * dy;
        var dd = dx * dx;
        dd += dy * dy;
        var tt: f64 = 0;
        if (!jbe(dd, br_nwt)) {
            t = t / dd;
            t = maxsd(t, 0);
            t = minsd(t, 1.0);
            tt = t;
        }
        dx *= tt;
        dy *= tt;
        wx -= dx;
        wy -= dy;
        wx *= wx;
        wy *= wy;
        wx += wy;
        best = minsd(best, wx);
    }
    return @sqrt(best);
}

/// fs_next: the point after it in its loop
pub fn fsNext(p: u32) u32 {
    var l: u32 = 0;
    while (l < fs_nl) : (l += 1) {
        const s = fs_ls[l];
        const end = fs_ln[l] + s;
        if (p >= end) continue;
        const q = p + 1;
        return if (q < end) q else s;
    }
    return p;
}

/// lp_rev: a loop's coedges in the opposite order
pub fn lpRev(l: u32) void {
    if (lp(l).n == 0) return; // (the original swaps from first - 1)
    var a = lp(l).first;
    var b = a + lp(l).n - 1;
    while (a < b) {
        const t = ce(a).*;
        ce(a).* = ce(b).*;
        ce(b).* = t;
        a += 1;
        b -= 1;
    }
}

/// lp_flip: lpRev, and every coedge turned round
pub fn lpFlip(l: u32) void {
    lpRev(l);
    var c = lp(l).first;
    const end = c + lp(l).n;
    while (c < end) : (c += 1) {
        const r = ce(c);
        r.rev ^= 1;
        const t = r.p0;
        r.p0 = r.p1;
        r.p1 = t;
    }
}

// ---- bodies ------------------------------------------------------------------------------
/// bd_flip: inside out: every sense flipped, every loop reversed
pub fn bdFlip(b: u32) void {
    var f = bd(b).first;
    const end = f + bd(b).nf;
    while (f < end) : (f += 1) {
        fc(f).sense ^= 1;
        var l = fc(f).loop;
        const l1 = l + fc(f).nloop;
        while (l < l1) : (l += 1) lpFlip(l);
    }
}

/// fc_box: a face's (u, v) box from its loops' samples
pub fn fcBox(fi: u32) void {
    fcSample(fi, 32);
    if (fs_np == 0) return;
    var ua = fs_pts[0][0];
    var ub = ua;
    var va = fs_pts[0][1];
    var vb = va;
    var i = fs_np;
    while (i > 0) {
        i -= 1;
        ua = minsd(ua, fs_pts[i][0]);
        ub = maxsd(ub, fs_pts[i][0]);
        va = minsd(va, fs_pts[i][1]);
        vb = maxsd(vb, fs_pts[i][1]);
    }
    const f = fc(fi);
    f.u0 = ua;
    f.u1 = ub;
    f.v0 = va;
    f.v1 = vb;
}

/// bd_integrate(body or face, 0 volume / 1 area / 2 one face's volume / 3 its area)
fn integrate(which: u32, kind_in: u32) f64 {
    var kind = kind_in;
    var f0: u32 = undefined;
    var f1: u32 = undefined;
    if (kind >= 2) {
        kind -= 2;
        f0 = which;
        f1 = which + 1;
    } else {
        f0 = bd(which).first;
        f1 = f0 + bd(which).nf;
    }
    var sum: f64 = 0;
    var fi = f0;
    while (fi < f1) : (fi += 1) {
        const f = fc(fi);
        const uref = (f.u0 + f.u1) * 0.5;
        const s = sf(f.surf);
        // area: a flipped face's loops turn the other way
        const m: f64 = if (kind != 0 and f.sense != 0) -1.0 else 1.0;
        var l = f.loop;
        const l1 = l + f.nloop;
        while (l < l1) : (l += 1) {
            var c = lp(l).first;
            const c1 = c + lp(l).n;
            while (c < c1) : (c += 1) {
                const r = ce(c);
                if (r.pc == NONE) continue;
                const pc = cv(r.pc);
                // intervals over s in 0 .. 1: a polyline per piece, a conic 8,
                // a line 1 (4 on a curved surface)
                var ni: u32 = 1;
                if (pc.typ == nb.CT_LINE) {
                    if (s.typ != nb.ST_PLANE) ni = 4;
                } else {
                    ni = 8;
                    if (pc.typ == nb.CT_NURBS) {
                        ni = (pc.n -% pc.deg) *% 2;
                        if (pc.deg != 1) ni <<= 2;
                    }
                }
                var k: u32 = 0;
                while (k < ni) : (k += 1) {
                    const ab = biBounds(k, ni, pc, r);
                    var j: u32 = 0;
                    while (j < 8) : (j += 1) {
                        const w = (ab[1] - ab[0]) * 0.5;
                        var sx = w * gl_x[j];
                        sx = sx + (ab[0] + ab[1]) * 0.5;
                        const uv = ceUv(c, sx);
                        // G = integral of f(w, v) dw from uref to u (4 pieces x 8 points)
                        var g: f64 = 0;
                        var p: u32 = 0;
                        while (p < 4) : (p += 1) {
                            const q = (uv[0] - uref) * 0.25;
                            var n: u32 = 0;
                            while (n < 8) : (n += 1) {
                                var x = (gl_x[n] + 1.0) * 0.5;
                                x = x + fl(p);
                                x = x * q;
                                x = x + uref;
                                const e = nb.srfEval(s, x, uv[1]);
                                const cr = nb.v3cross(e[1], e[2]);
                                var v = if (kind == 0) nb.v3dot(cr, e[0]) else nb.v3len(cr);
                                v = v * gl_w[n];
                                v = v * q;
                                v = v * 0.5;
                                g = v + g;
                            }
                        }
                        // sum += w_j G dv/dp dp/ds (b - a)/2; dp/ds = P1 - P0
                        var t = g * gl_w[j];
                        t = t * uv[3];
                        t = t * (r.p1 - r.p0);
                        t = t * w;
                        t = t * m;
                        sum = t + sum;
                    }
                }
            }
        }
    }
    if (kind == 0) sum = sum * br_third;
    return sum;
}

/// bi_bounds: [a, b] in s: k/n .. (k+1)/n, or for a polyline pcurve the k-th
/// of its pieces (split in two) mapped to s
fn biBounds(k: u32, n: u32, pc: *const nb.Curve, r: *const Coedge) [2]f64 {
    if (pc.typ == nb.CT_NURBS and pc.deg == 1) {
        const c = k >> 1;
        const kn = pc.kn.?;
        var a = kn[c + 1];
        var b = kn[c + 2];
        if (k & 1 != 0) {
            a = (a + b) * 0.5;
        } else {
            b = (b + a) * 0.5;
        }
        const d = r.p1 - r.p0;
        a = (a - r.p0) / d;
        b = (b - r.p0) / d;
        if (!jbe(a, b)) return .{ b, a };
        return .{ a, b };
    }
    return .{ fl(k) / fl(n), fl(k + 1) / fl(n) };
}

pub fn bdVolume(b: u32) f64 {
    return integrate(b, 0);
}
pub fn bdArea(b: u32) f64 {
    return integrate(b, 1);
}
/// a face's share of the volume
pub fn fcVolume(f: u32) f64 {
    return integrate(f, 2);
}
pub fn fcArea(f: u32) f64 {
    return integrate(f, 3);
}

/// bd_stats: bs_v, bs_e (edges used), bs_f, bs_l
pub fn bdStats(b: u32) void {
    bs_v = 0;
    bs_e = 0;
    bs_l = 0;
    bs_bad = 0;
    bdWalk(b, 0);
    bdWalk(b, 1);
    bs_f = bd(b).nf;
}

const VMARK: u32 = 0x7ff00001;

/// bd_walk(body, pass): every coedge: pass 0 clears its edge's and vertices'
/// marks, pass 1 counts uses (mark: +1 forwards, +0x10000 backwards) and new
/// vertices and edges; pass 2 checks the counts
fn bdWalk(b: u32, pass: u32) void {
    var f = bd(b).first;
    const f1 = f + bd(b).nf;
    while (f < f1) : (f += 1) {
        var l = fc(f).loop;
        const l1 = l + fc(f).nloop;
        while (l < l1) : (l += 1) {
            if (pass == 1) bs_l += 1;
            const first = lp(l).first;
            const end = first + lp(l).n;
            var c = first;
            while (c < end) : (c += 1) {
                const rev = ce(c).rev;
                const e = ed(ce(c).edge);
                if (e.flags & EF_DEGEN != 0) continue;
                if (pass == 0) {
                    e.mark = 0;
                    vx(e.v0).tol = 0;
                    vx(e.v1).tol = 0;
                } else if (pass == 1) {
                    if (e.mark == 0) bs_e += 1;
                    e.mark +%= if (rev != 0) 0x10000 else 1;
                    vmark(e.v0);
                    vmark(e.v1);
                    // the loop is closed: this coedge's end is the next one's start
                    const nx = if (c + 1 < end) c + 1 else first;
                    if (ceEnds(c)[1] != ceEnds(nx)[0]) bs_bad += 1;
                } else {
                    if (e.mark == 0x10001) continue;
                    bs_bad += 1;
                    e.mark = 0x10001; // (counted once)
                }
            }
        }
    }
}
fn vmark(v: u32) void {
    const p: *[2]u32 = @ptrCast(&vx(v).tol);
    if (p[1] == VMARK) return;
    p[1] = VMARK;
    bs_v += 1;
}
/// ce_ends -> the vertex a coedge starts at, and where it ends
pub fn ceEnds(c: u32) [2]u32 {
    const e = ed(ce(c).edge);
    if (ce(c).rev != 0) return .{ e.v1, e.v0 };
    return .{ e.v0, e.v1 };
}

/// bd_check -> problems: loops that do not close, edges not used exactly
/// once each way (bdStats' counts are set too)
pub fn bdCheck(b: u32) u32 {
    bdStats(b);
    bdWalk(b, 2);
    return bs_bad;
}

test "brep compiles" {
    std.testing.refAllDecls(@This());
}
