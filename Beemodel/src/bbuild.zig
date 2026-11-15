//! bbuild.s: B-rep bodies from sketches, extrusions and revolutions.
//!
//! bpPlace sets up the map from a sketch's plane coordinates (u, v, and w
//! along its normal) to the world, in doubles. bpBuild finds the closed
//! loops of a sketch exactly - lines and arcs chained end to end, whole
//! circles - nests them (even-odd: material, holes, material ...) and turns
//! material loops counter-clockwise, holes clockwise; arcs longer than half
//! a turn are split so no face spans more than pi of a periodic surface.
//!
//! bpPrism extrudes every region between two heights: a plane or a
//! cylinder per loop element, the profile as caps. bpRevolve turns the
//! loops about the sketch's u or v axis: lines make cylinders, planes or
//! cones, arcs spheres or tori, in patches of at most half a turn, with
//! poles where the profile touches the axis and caps for part turns. The
//! faces are oriented by asking whether a point just off them lies inside
//! the solid, which the profile answers exactly (arcs included). In the
//! original's order of operations, bit for bit.
const std = @import("std");
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const sk = @import("sketch.zig");
const V3 = nb.V3;
const jb = nb.jb;
const ja = nb.ja;
const jae = nb.jae;
const jbe = nb.jbe;
const maxsd = nb.maxsd;
const fabs = nb.fabs;
const fneg = nb.fneg;
const fl = nb.fl;

pub const E_LINE: u32 = 1;
pub const E_CIRCLE: u32 = 2;
pub const E_ARC: u32 = 3;
const F_CONSTR: u32 = 4;

/// A profile element: a line or an arc from a to b.
pub const El = extern struct {
    typ: u32,
    _p0: u32 = 0,
    a: [2]f64,
    b: [2]f64,
    c: [2]f64 = .{ 0, 0 }, // arc: centre, radius,
    r: f64 = 0,
    t0: f64 = 0, //  start angle, signed sweep
    sw: f64 = 0,
    na: u32 = 0, // end clusters (chaining)
    nb_: u32 = 0,
    _p1: [2]u32 = .{ 0, 0 },
};
comptime {
    std.debug.assert(@sizeOf(El) == 96 and @offsetOf(El, "na") == 80);
}
const MAXEL = 512;
const MAXLP = 128;
const MAXN = 1024;

const bb_weld: f64 = 1.0e-7;
const bb_tiny: f64 = 1.0e-12;
const bb_eps: f64 = 1.0e-7; // fc_orient's step (of the scale)
const bb_axis: f64 = 1.0e-9; // on the revolve axis (of the scale)
const bb_full: f64 = 6.2831853;
const bb_pi = nb.nk_pi;
const bb_2pi = nb.nk_2pi;
// sketch planes: Lo (offset direction), Lu, Lv, Lw
const pl_dirs = [3][4]V3{
    .{ .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } }, // XY
    .{ .{ 0, 1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 1, 0 } }, // XZ
    .{ .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 1, 0 }, .{ 1, 0, 0 } }, // YZ
};

// the plane map: O + u U + v V + w W
pub var bm_o: V3 = .{ 0, 0, 0 };
pub var bm_u: V3 = .{ 0, 0, 0 };
pub var bm_v: V3 = .{ 0, 0, 0 };
pub var bm_w: V3 = .{ 0, 0, 0 };
var bm_inv: [3]V3 = undefined; // rows of [U V W]^-1
/// The profile's size (tolerances).
pub var bp_scale: f64 = 0;
// raw elements, then chained into loops
var bp_raw: [MAXEL]El = undefined;
var bp_nraw: u32 = 0;
var bp_used: [MAXEL]u8 = undefined;
pub var bp_el: [MAXEL]El = undefined;
pub var bp_nel: u32 = 0;
pub var bp_nl: u32 = 0;
pub var bp_lf: [MAXLP]u32 = undefined;
pub var bp_ln: [MAXLP]u32 = undefined;
pub var bp_dep: [MAXLP]u32 = undefined;
pub var bp_par: [MAXLP]i32 = undefined;
var bp_ar: [MAXLP]f64 = undefined;
var bp_nx: [MAXN][2]f64 = undefined;
var bp_nn: u32 = 0;
// building
var bq_w0: f64 = 0;
var bq_w1: f64 = 0;
var bq_vb: [MAXEL]u32 = undefined; // per element of the loop being built
var bq_vt: [MAXEL]u32 = undefined;
var bq_ve: [MAXEL]u32 = undefined;
var bq_be: [MAXEL]u32 = undefined;
var bq_te: [MAXEL]u32 = undefined;
// revolve
var br_ax: u32 = 0; // 0 about u, 1 about v
var br_side: i32 = 1; // +1 / -1: the profile's side
var br_np: u32 = 0; // patches
var br_full: bool = false;
var br_ang: f64 = 0;
var br_phi: [4]f64 = undefined; // patch boundaries
var br_ao: V3 = undefined; // the axis: origin, Ax, Ay, Az (world)
var br_axw: V3 = undefined;
var br_ayw: V3 = undefined;
var br_azw: V3 = undefined;
var br_pv: [3][MAXEL]u32 = undefined; // vertex per point per boundary (0..2)
var br_pe: [3][MAXEL]u32 = undefined; // profile edge per element per boundary
var br_ce: [2][MAXEL]u32 = undefined; // circle edge per point per patch
var br_onax: [MAXEL]bool = undefined; // point on the axis
var ws_hint: f64 = 0;

// ---- the plane map ---------------------------------------------------------------------
/// bm_pt: a point
pub fn bmPt(u: f64, v: f64, w: f64) V3 {
    return nb.lin3(&bm_o, &bm_u, u, &bm_v, v, &bm_w, w);
}
/// bm_dir: a direction
pub fn bmDir(u: f64, v: f64, w: f64) V3 {
    return nb.lin3(null, &bm_u, u, &bm_v, v, &bm_w, w);
}

/// fmat(float[12] rows, in, point): row . in (+ the row's translation)
fn fmat(m: *const [12]f32, in: V3, point: bool) V3 {
    var o: V3 = undefined;
    for (0..3) |r| {
        var x: f64 = @as(f64, m[r * 4]) * in[0];
        x += @as(f64, m[r * 4 + 1]) * in[1];
        x += @as(f64, m[r * 4 + 2]) * in[2];
        if (point) x += @as(f64, m[r * 4 + 3]);
        o[r] = x;
    }
    return o;
}

/// bp_place(sketch, its object's matrix (3 x 4 rows), extra transform or null)
pub fn bpPlace(s: *const sk.Block, m: *const [12]f32, extra: ?*const [12]f32) void {
    const pl = if (s.plane <= 2) s.plane else 0;
    const d = &pl_dirs[pl];
    const lo = nb.v3scale(d[0], s.offset);
    bm_o = fmat(m, lo, true);
    bm_u = fmat(m, d[1], false);
    bm_v = fmat(m, d[2], false);
    bm_w = fmat(m, d[3], false);
    if (extra) |x| {
        bm_o = fmat(x, bm_o, true);
        bm_u = fmat(x, bm_u, false);
        bm_v = fmat(x, bm_v, false);
        bm_w = fmat(x, bm_w, false);
    }
    bmInvert();
}

/// bm_set: a plane map given directly (O U V W)
pub fn bmSet(f: *const [4]V3) void {
    bm_o = f[0];
    bm_u = f[1];
    bm_v = f[2];
    bm_w = f[3];
    bmInvert();
}

fn bmInvert() void {
    bm_inv[0] = nb.v3cross(bm_v, bm_w);
    bm_inv[1] = nb.v3cross(bm_w, bm_u);
    bm_inv[2] = nb.v3cross(bm_u, bm_v);
    const k = 1.0 / nb.v3dot(bm_u, bm_inv[0]);
    for (0..3) |i| {
        for (0..3) |j| bm_inv[i][j] = bm_inv[i][j] * k;
    }
}

fn bmLocal(p: V3) V3 {
    const d = nb.v3sub(p, bm_o);
    return .{ nb.v3dot(d, bm_inv[0]), nb.v3dot(d, bm_inv[1]), nb.v3dot(d, bm_inv[2]) };
}

// ---- profiles ----------------------------------------------------------------------------
/// bp_count -> loops
pub fn bpCount() u32 {
    return bp_nl;
}

fn elRev(e: *El) void {
    const a = e.a;
    e.a = e.b;
    e.b = a;
    const n = e.na;
    e.na = e.nb_;
    e.nb_ = n;
    e.t0 = e.t0 + e.sw;
    e.sw = fneg(e.sw);
}

fn elAt(e: *const El, s: f64) [2]f64 {
    if (e.typ != E_ARC) {
        var x = e.b[0] - e.a[0];
        x = x * s;
        x = x + e.a[0];
        var y = e.b[1] - e.a[1];
        y = y * s;
        y = y + e.a[1];
        return .{ x, y };
    }
    var t = s * e.sw;
    t = t + e.t0;
    const sc = nb.dsincos(t);
    return .{ sc[1] * e.r + e.c[0], sc[0] * e.r + e.c[1] };
}

fn arcEnds(e: *El) void {
    e.a = elAt(e, 0);
    e.b = elAt(e, 1.0);
}

fn rawNew() ?*El {
    if (bp_nraw >= MAXEL) return null;
    const e = &bp_raw[bp_nraw];
    bp_nraw += 1;
    e.* = std.mem.zeroes(El);
    return e;
}

/// node: a point's cluster (welded)
fn node(p: [2]f64) u32 {
    const tol = bp_scale * bb_weld;
    var i: u32 = 0;
    while (i < bp_nn) : (i += 1) {
        const d = maxsd(fabs(p[0] - bp_nx[i][0]), fabs(p[1] - bp_nx[i][1]));
        if (jbe(d, tol)) return i;
    }
    if (i >= MAXN) return 0;
    bp_nx[i] = p;
    bp_nn += 1;
    return i;
}

fn skp(s: *const sk.Block, i: i32) [2]f64 {
    const p = &s.pts[@as(u32, @bitCast(i)) & 0xff];
    return .{ p.x, p.y };
}

/// bp_build(sketch) -> loops (the profile filled)
pub fn bpBuild(s: *const sk.Block) u32 {
    bp_nraw = 0;
    bp_nel = 0;
    bp_nl = 0;
    bp_nn = 0;
    // the scale: the largest coordinate
    var sc = bb_tiny;
    const npt = @min(s.npt, sk.MAX_PT);
    const nent = @min(s.nent, sk.MAX_ENT);
    for (0..npt) |i| {
        sc = maxsd(sc, fabs(s.pts[i].x));
        sc = maxsd(sc, fabs(s.pts[i].y));
    }
    for (0..nent) |i| sc = maxsd(sc, fabs(s.ents[i].r));
    bp_scale = sc;
    // the elements
    for (0..nent) |i| {
        const en = &s.ents[i];
        if (en.flags & F_CONSTR != 0) continue;
        switch (en.typ) {
            E_LINE => {
                const e = rawNew() orelse continue;
                e.typ = E_LINE;
                e.a = skp(s, en.p[0]);
                e.b = skp(s, en.p[1]);
                e.na = node(e.a);
                e.nb_ = node(e.b);
            },
            E_ARC => {
                const e = rawNew() orelse continue;
                e.typ = E_ARC;
                e.c = skp(s, en.p[0]);
                e.r = en.r;
                var q = skp(s, en.p[1]);
                e.t0 = nb.datan2(q[1] - e.c[1], q[0] - e.c[0]);
                q = skp(s, en.p[2]);
                var sw = nb.datan2(q[1] - e.c[1], q[0] - e.c[0]);
                sw = sw - e.t0; // counter-clockwise sweep, 0 .. 2 pi
                if (!ja(sw, 0)) sw = sw + bb_2pi;
                e.sw = sw;
                arcEnds(e);
                e.na = node(e.a);
                e.nb_ = node(e.b);
            },
            E_CIRCLE => addCircle(skp(s, en.p[0]), en.r),
            else => {},
        }
    }
    // chain
    @memset(&bp_used, 0);
    var st: u32 = 0;
    while (st < bp_nraw) : (st += 1) {
        if (bp_used[st] != 0) continue;
        if (bp_nl >= MAXLP) break;
        const first = bp_nel;
        var cur = st;
        const home = bp_raw[st].na; // where the loop must come back to
        const closed = walk: while (true) {
            bp_used[cur] = 1;
            if (bp_nel >= MAXEL) break :walk false;
            bp_el[bp_nel] = bp_raw[cur];
            bp_nel += 1;
            const end = bp_el[bp_nel - 1].nb_;
            if (end == home) break :walk true;
            var k: u32 = 0;
            while (k < bp_nraw) : (k += 1) {
                if (bp_used[k] != 0) continue;
                const r = &bp_raw[k];
                if (r.na == end) break;
                if (r.nb_ == end) {
                    elRev(r); // (reversed in place)
                    break;
                }
            }
            if (k >= bp_nraw) break :walk false;
            cur = k;
        };
        if (!closed) {
            bp_nel = first; // not closed: forgotten
            continue;
        }
        bp_lf[bp_nl] = first;
        bp_ln[bp_nl] = bp_nel - first;
        bp_nl += 1;
    }
    splitArcs();
    nest();
    return bp_nl;
}

/// add_circle(centre, radius): a loop of two half arcs
fn addCircle(c: [2]f64, r: f64) void {
    if (bp_nl >= MAXLP) return;
    if (bp_nel + 2 > MAXEL) return;
    const first = bp_nel;
    for (0..2) |k| {
        const e = &bp_el[bp_nel];
        e.* = std.mem.zeroes(El);
        e.typ = E_ARC;
        e.c = c;
        e.r = r;
        e.t0 = fl(k) * bb_pi;
        e.sw = bb_pi;
        arcEnds(e);
        bp_nel += 1;
    }
    bp_lf[bp_nl] = first;
    bp_ln[bp_nl] = 2;
    bp_nl += 1;
}

/// split_arcs: arcs of more than half a turn become two
fn splitArcs() void {
    var i: i32 = @as(i32, @intCast(bp_nel)) - 1;
    while (i >= 0) : (i -= 1) {
        const k: u32 = @intCast(i);
        const e = &bp_el[k];
        if (e.typ != E_ARC) continue;
        if (jbe(fabs(e.sw), bb_pi)) continue;
        if (bp_nel >= MAXEL) continue;
        // move everything after it up one
        var j = bp_nel;
        while (j > k + 1) : (j -= 1) bp_el[j] = bp_el[j - 1];
        bp_nel += 1;
        bp_el[k + 1] = bp_el[k]; // the copy: the second half
        const h = bp_el[k].sw * 0.5;
        bp_el[k].sw = h;
        bp_el[k + 1].sw = h;
        bp_el[k + 1].t0 = h + bp_el[k].t0;
        arcEnds(&bp_el[k]);
        arcEnds(&bp_el[k + 1]);
        // loops after it move up one; its own grows
        var l: u32 = 0;
        while (l < bp_nl) : (l += 1) {
            const f: i32 = @intCast(bp_lf[l]);
            if (f > i) {
                bp_lf[l] += 1;
            } else if (f + @as(i32, @intCast(bp_ln[l])) > i) bp_ln[l] += 1;
        }
    }
}

/// loop_area: its signed area (arcs exactly)
fn loopArea(l: u32) f64 {
    var s: f64 = 0;
    var i = bp_lf[l];
    const end = i + bp_ln[l];
    while (i < end) : (i += 1) {
        const e = &bp_el[i];
        var x = e.a[0] * e.b[1];
        x = x - e.b[0] * e.a[1];
        if (e.typ == E_ARC) {
            // arc: cx (by - ay) - cy (bx - ax) + r^2 sweep instead
            x = (e.b[1] - e.a[1]) * e.c[0];
            x = x - (e.b[0] - e.a[0]) * e.c[1];
            var y = e.r * e.r;
            y = y * e.sw;
            x = x + y;
        }
        s += x;
    }
    return s * 0.5;
}

/// crossings: how often a ray from (u, v) towards +u crosses the loop
fn crossings(l: u32, u: f64, v: f64) u32 {
    var n: u32 = 0;
    var i = bp_lf[l];
    const end = i + bp_ln[l];
    while (i < end) : (i += 1) {
        const e = &bp_el[i];
        if (e.typ != E_ARC) {
            if ((e.a[1] > v) == (e.b[1] > v)) continue;
            var x = v - e.a[1];
            x = x * (e.b[0] - e.a[0]);
            x = x / (e.b[1] - e.a[1]);
            x = x + e.a[0];
            if (jbe(x, u)) continue;
            n += 1;
            continue;
        }
        const dy = v - e.c[1];
        var d = e.r * e.r;
        d = d - dy * dy;
        if (jbe(d, 0)) continue;
        d = @sqrt(d);
        for (0..2) |k| {
            const dx = if (k == 0) d else fneg(d);
            if (jbe(dx + e.c[0], u)) continue;
            // on the arc? its angle within the sweep
            var a = nb.datan2(dy, dx);
            a = a - e.t0;
            var sw = e.sw;
            if (!jae(sw, 0)) {
                a = fneg(a);
                sw = fneg(sw);
            }
            while (!jae(a, 0)) {
                if (a != a) break;
                a = a + bb_2pi;
            }
            while (!jb(a, bb_2pi)) a = a - bb_2pi;
            if (jae(a, sw)) continue;
            n += 1;
        }
    }
    return n;
}

/// prof_in: inside the profile (even-odd)
fn profIn(u: f64, v: f64) bool {
    var n: u32 = 0;
    var l: u32 = 0;
    while (l < bp_nl) : (l += 1) n +%= crossings(l, u, v);
    return n & 1 != 0;
}

/// nest: depth and parent of every loop; material loops counter-clockwise,
/// holes clockwise
fn nest() void {
    var l: u32 = 0;
    while (l < bp_nl) : (l += 1) {
        const p = elAt(&bp_el[bp_lf[l]], 0.5);
        var dep: u32 = 0;
        var par: i32 = -1;
        var best: f64 = 0;
        var k: u32 = 0;
        while (k < bp_nl) : (k += 1) {
            if (k == l) continue;
            if (crossings(k, p[0], p[1]) & 1 == 0) continue;
            dep += 1;
            const a = fabs(loopArea(k));
            if (par != -1 and jae(a, best)) continue;
            best = a;
            par = @intCast(k);
        }
        bp_dep[l] = dep;
        bp_par[l] = par;
        const a = loopArea(l);
        bp_ar[l] = a;
        const pos: u32 = @intFromBool(a > 0);
        const want: u32 = (dep & 1) ^ 1;
        if (pos != want) loopFlipEl(l);
    }
}

/// loop_flip_el: its elements in the opposite order, each reversed
fn loopFlipEl(l: u32) void {
    var a = bp_lf[l];
    var b: i64 = @as(i64, a) + bp_ln[l] - 1;
    bp_ar[l] = fneg(bp_ar[l]);
    while (@as(i64, a) <= b) {
        const ub: u32 = @intCast(b);
        const t = bp_el[a];
        bp_el[a] = bp_el[ub];
        bp_el[ub] = t;
        elRev(&bp_el[a]);
        if (a != ub) elRev(&bp_el[ub]);
        a += 1;
        b -= 1;
    }
}

/// bp_points(sketch, radius) -> loops: a circle at every point no entity
/// uses (hole centres)
pub fn bpPoints(s: *const sk.Block, r: f64) u32 {
    bp_nel = 0;
    bp_nl = 0;
    bp_scale = r;
    const npt = @min(s.npt, sk.MAX_PT);
    const nent = @min(s.nent, sk.MAX_ENT);
    var i: u32 = 0;
    while (i < npt) : (i += 1) {
        const pi: i32 = @intCast(i);
        var used = false;
        for (0..nent) |k| {
            const e = &s.ents[k];
            if (e.p[0] == pi or e.p[1] == pi or e.p[2] == pi) {
                used = true;
                break;
            }
        }
        if (used) continue;
        const p = skp(s, pi);
        var x = maxsd(fabs(p[0]), bp_scale);
        x = maxsd(x, fabs(p[1]));
        bp_scale = x;
        addCircle(p, r);
    }
    nest();
    return bp_nl;
}

/// bp_offset(distance): every loop moved towards its material side (shells);
/// false when a loop cannot be offset
pub fn bpOffset(d: f64) bool {
    var i: u32 = 0;
    while (i < bp_nel) : (i += 1) {
        const e = &bp_el[i];
        if (e.typ == E_ARC) {
            // counter-clockwise: towards the centre (r - d); clockwise: r + d
            const r = if (jb(e.sw, 0)) e.r + d else e.r - d;
            if (jbe(r, bb_tiny)) return false;
            e.r = r;
            arcEnds(e);
            continue;
        }
        var dx = e.b[0] - e.a[0];
        var dy = e.b[1] - e.a[1];
        const len = @sqrt(dx * dx + dy * dy);
        const k = d / len;
        dx = dx * k;
        dy = dy * k;
        e.a[0] = e.a[0] - dy;
        e.b[0] = e.b[0] - dy;
        e.a[1] = e.a[1] + dx;
        e.b[1] = e.b[1] + dx;
    }
    // corners that opened: lines meeting at their lines' intersection
    var l: u32 = 0;
    while (l < bp_nl) : (l += 1) {
        const f = bp_lf[l];
        const n = bp_ln[l];
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const p = &bp_el[f + k];
            const q = &bp_el[f + (k + 1) % n];
            var g = fabs(p.b[0] - q.a[0]);
            g = g + fabs(p.b[1] - q.a[1]);
            if (jbe(g, bp_scale * bb_weld)) continue;
            if (p.typ != E_LINE or q.typ != E_LINE) return false;
            var d1x = p.b[0] - p.a[0];
            var d1y = p.b[1] - p.a[1];
            const d2x = q.b[0] - q.a[0];
            const d2y = q.b[1] - q.a[1];
            var cr = d1x * d2y;
            cr = cr - d1y * d2x;
            if (jbe(fabs(cr), bb_tiny)) return false;
            var t = (q.a[0] - p.a[0]) * d2y;
            t = t - (q.a[1] - p.a[1]) * d2x;
            t = t / cr;
            d1x = d1x * t + p.a[0];
            d1y = d1y * t + p.a[1];
            p.b = .{ d1x, d1y };
            q.a = .{ d1x, d1y };
        }
    }
    return true;
}

/// bp_custom(elements, scale): the profile is that one closed loop (turned
/// counter-clockwise)
pub fn bpCustom(els: []const El, scale: f64) void {
    bp_scale = scale;
    const n = @min(els.len, MAXEL);
    @memcpy(bp_el[0..n], els[0..n]);
    bp_nel = @intCast(n);
    bp_nl = 1;
    bp_lf[0] = 0;
    bp_ln[0] = @intCast(n);
    nest();
}

// ---- building ------------------------------------------------------------------------------
/// bd_finish(first face, faces, classifier): pcurves, sense and loop turns, boxes
pub fn bdFinish(first: u32, n: u32, cl: br.Classifier) void {
    var f = first;
    while (f < first + n) : (f += 1) {
        br.fcPcurves(f);
        br.fcOrient(f, cl, bp_scale * bb_eps);
        br.fcBox(f);
    }
}

fn vertAt(u: f64, v: f64, w: f64) u32 {
    return br.newVx(bmPt(u, v, w));
}

/// plane_xy: unit U, and V made perpendicular to it
fn planeXy() [2]V3 {
    var x = nb.v3scale(bm_u, 1.0);
    _ = nb.v3norm(&x);
    var y = nb.v3scale(bm_v, 1.0);
    nb.v3axpy(&y, x, fneg(nb.v3dot(y, x)));
    _ = nb.v3norm(&y);
    return .{ x, y };
}

/// el_edge(element, w, v0, v1): an edge, the element at height w
fn elEdge(e: *const El, w: f64, v0: u32, v1: u32) u32 {
    if (e.typ != E_ARC) {
        const a = bmPt(e.a[0], e.a[1], w);
        const b = bmPt(e.b[0], e.b[1], w);
        const l = br.mkLine(a, b);
        return br.newEd(l.i, v0, v1, 0, l.len);
    }
    // a circle: centre, U, V (unit)
    const xy = planeXy();
    const fr: [3]V3 = .{ bmPt(e.c[0], e.c[1], w), xy[0], xy[1] };
    var r = bm_u[0] * bm_u[0];
    r += bm_u[1] * bm_u[1];
    r += bm_u[2] * bm_u[2];
    r = @sqrt(r) * e.r;
    const c = br.mkConic(nb.CT_CIRCLE, &fr, r, r);
    return br.newEd(c, v0, v1, e.t0, e.t0 + e.sw);
}

fn prismIn(p: *const V3) bool {
    const l = bmLocal(p.*);
    if (jbe(l[2], bq_w0)) return false;
    if (jae(l[2], bq_w1)) return false;
    return profIn(l[0], l[1]);
}

/// bp_prism(w0, w1) -> a body: the profile from w0 to w1 (NONE on failure)
pub fn bpPrism(w0: f64, w1: f64) u32 {
    bq_w0 = w0;
    bq_w1 = w1;
    if (bp_nl == 0) return br.NONE;
    br.bbBegin();
    var l: u32 = 0;
    while (l < bp_nl) : (l += 1) {
        const f = bp_lf[l];
        const n = bp_ln[l];
        // vertices and vertical edges
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const e = &bp_el[f + i];
            bq_vb[i] = vertAt(e.a[0], e.a[1], bq_w0);
            bq_vt[i] = vertAt(e.a[0], e.a[1], bq_w1);
            const a = bmPt(e.a[0], e.a[1], bq_w0);
            const b = bmPt(e.a[0], e.a[1], bq_w1);
            const ln = br.mkLine(a, b);
            bq_ve[i] = br.newEd(ln.i, bq_vb[i], bq_vt[i], 0, ln.len);
        }
        // bottom and top edges
        i = 0;
        while (i < n) : (i += 1) {
            const nx = (i + 1) % n;
            const e = &bp_el[f + i];
            bq_be[i] = elEdge(e, bq_w0, bq_vb[i], bq_vb[nx]);
            bq_te[i] = elEdge(e, bq_w1, bq_vt[i], bq_vt[nx]);
        }
        // a wall per element
        i = 0;
        while (i < n) : (i += 1) {
            const s = wallSurface(&bp_el[f + i]);
            _ = br.fbFace(s, ws_hint, 0);
            _ = br.fbLoop();
            _ = br.fbCe(bq_be[i], 0);
            _ = br.fbCe(bq_ve[(i + 1) % n], 0);
            _ = br.fbCe(bq_te[i], 1);
            _ = br.fbCe(bq_ve[i], 1);
        }
        // this loop's bottom / top edges for the caps
        i = 0;
        while (i < n) : (i += 1) {
            bp_el[f + i].na = bq_be[i];
            bp_el[f + i].nb_ = bq_te[i];
        }
    }
    // caps: bottom (0) and top (1), each material loop with its holes
    for (0..2) |side| {
        var r: u32 = 0;
        while (r < bp_nl) : (r += 1) {
            if (bp_dep[r] & 1 != 0) continue;
            const o = bmPt(0, 0, if (side == 0) bq_w0 else bq_w1);
            const xy = planeXy();
            const fr: [3]V3 = .{ o, xy[0], xy[1] };
            const s = br.mkSurf(nb.ST_PLANE, &fr, 0, 0);
            _ = br.fbFace(s, 0, 0);
            capLoop(r, side);
            var h: u32 = 0;
            while (h < bp_nl) : (h += 1) {
                if (bp_par[h] == @as(i32, @intCast(r))) capLoop(h, side);
            }
        }
    }
    const b = br.bbEnd();
    if (b == br.NONE) return b;
    bdFinish(br.bd(b).first, br.bd(b).nf, &prismIn);
    return b;
}

/// cap_loop(profile loop, 0 bottom / 1 top): a loop of the face being built
/// from the loop's bottom or top edges (kept in na / nb)
fn capLoop(l: u32, side: usize) void {
    _ = br.fbLoop();
    var i = bp_lf[l];
    const end = i + bp_ln[l];
    while (i < end) : (i += 1) {
        _ = br.fbCe(if (side == 0) bp_el[i].na else bp_el[i].nb_, 0);
    }
}

/// wall_surface: a plane through the line along the normal, or the cylinder
/// of the arc (from w0)
fn wallSurface(e: *const El) u32 {
    if (e.typ != E_ARC) {
        const o = bmPt(e.a[0], e.a[1], bq_w0);
        const b = bmPt(e.b[0], e.b[1], bq_w0);
        var x = nb.v3sub(b, o);
        _ = nb.v3norm(&x);
        var y = nb.v3scale(bm_w, 1.0);
        nb.v3axpy(&y, x, fneg(nb.v3dot(y, x)));
        _ = nb.v3norm(&y);
        const fr: [3]V3 = .{ o, x, y };
        const s = br.mkSurf(nb.ST_PLANE, &fr, 0, 0);
        ws_hint = 0;
        return s;
    }
    const o = bmPt(e.c[0], e.c[1], bq_w0);
    const xy = planeXy();
    const fr: [3]V3 = .{ o, xy[0], xy[1] };
    const s = br.mkSurf(nb.ST_CYL, &fr, nb.v3len(bm_u) * e.r, 0);
    ws_hint = e.sw * 0.5 + e.t0;
    return s;
}

// ---- revolutions ---------------------------------------------------------------------------
/// rz: an element point -> z along the axis, rho
fn rz(p: [2]f64) [2]f64 {
    var z = p[0];
    var rho = p[1];
    if (br_ax != 0) {
        z = p[1];
        rho = p[0];
    }
    return .{ z, rho * fl(br_side) };
}

/// rot_pt(z, rho, phi): the point turned by phi
fn rotPt(z: f64, rho: f64, phi: f64) V3 {
    const sc = nb.dsincos(phi);
    return nb.lin3(&br_ao, &br_axw, sc[1] * rho, &br_ayw, sc[0] * rho, &br_azw, z);
}

/// rot_dir(0 the sketch's u / 1 its v, phi): the direction turned by phi
fn rotDir(which: u32, phi: f64) V3 {
    var z: f64 = 0;
    var rho: f64 = 0;
    if (which ^ br_ax == 0) z = 1.0 else rho = fl(br_side);
    const sc = nb.dsincos(phi);
    return nb.lin3(null, &br_axw, sc[1] * rho, &br_ayw, sc[0] * rho, &br_azw, z);
}

fn revolveIn(p: *const V3) bool {
    const d = nb.v3sub(p.*, br_ao);
    const z = nb.v3dot(d, br_azw);
    const x = nb.v3dot(d, br_axw);
    const y = nb.v3dot(d, br_ayw);
    if (!br_full) {
        var phi = nb.datan2(y, x);
        if (!jae(phi, 0)) phi = phi + bb_2pi;
        if (jbe(phi, 0)) return false;
        if (jae(phi, br_ang)) return false;
    }
    var rho = @sqrt(x * x + y * y);
    rho = rho * fl(br_side);
    if (br_ax != 0) return profIn(rho, z);
    return profIn(z, rho);
}

fn onaxis(rho: f64) bool {
    return !(fabs(rho) > bp_scale * bb_axis);
}

/// bp_revolve(axis 0 u / 1 v, angle) -> a body: the profile turned about
/// the axis (NONE on failure)
pub fn bpRevolve(ax: u32, angle: f64) u32 {
    br_ax = ax;
    if (bp_nl == 0) return br.NONE;
    // the side: the sign of the first point off the axis
    br_side = 1;
    var i: u32 = 0;
    while (i < bp_nel) : (i += 1) {
        const t = if (br_ax == 0) bp_el[i].a[1] else bp_el[i].a[0];
        if (onaxis(t)) continue;
        if (!jb(0, t)) br_side = -1;
        break;
    }
    // the axis frame in the sketch, then the world
    br_full = false;
    br_ang = fabs(angle);
    if (!jb(br_ang, bb_full)) {
        br_full = true;
        br_ang = bb_2pi;
    }
    br_ao = bmPt(0, 0, 0);
    const sd = fl(br_side);
    if (br_ax == 0) {
        br_azw = bmDir(1.0, 0, 0);
        br_axw = bmDir(0, sd, 0);
        br_ayw = bmDir(0, 0, sd);
    } else {
        br_azw = bmDir(0, 1.0, 0);
        br_axw = bmDir(sd, 0, 0);
        br_ayw = bmDir(0, 0, fneg(sd));
    }
    _ = nb.v3norm(&br_azw);
    _ = nb.v3norm(&br_axw);
    _ = nb.v3norm(&br_ayw);
    if (!jbe(0, angle)) { // a negative angle turns the other way
        br_ayw = nb.v3scale(br_ayw, -1.0);
        br_azw = nb.v3scale(br_azw, -1.0);
    }
    // patches: a full turn two halves; else 1 (<= pi) or 2
    var np: u32 = 2;
    if (!br_full) {
        np = 1;
        if (!jbe(br_ang, bb_pi)) np = 2;
    }
    br_np = np;
    const step = br_ang / fl(np);
    br_phi[0] = 0;
    br_phi[1] = step;
    br_phi[2] = step + step;
    br.bbBegin();
    var l: u32 = 0;
    while (l < bp_nl) : (l += 1) {
        const f = bp_lf[l];
        const n = bp_ln[l];
        rvVertices(f, n);
        rvEdges(f, n);
        rvFaces(f, n);
    }
    if (!br_full) {
        for (0..2) |side| {
            var r: u32 = 0;
            while (r < bp_nl) : (r += 1) {
                if (bp_dep[r] & 1 != 0) continue;
                const t: f64 = if (side == 0) 0 else br_ang;
                const fr: [3]V3 = .{ br_ao, rotDir(0, t), rotDir(1, t) };
                const s = br.mkSurf(nb.ST_PLANE, &fr, 0, 0);
                _ = br.fbFace(s, 0, 0);
                capLoop(r, side); // (na / nb: the edges at 0, end)
                var h: u32 = 0;
                while (h < bp_nl) : (h += 1) {
                    if (bp_par[h] == @as(i32, @intCast(r))) capLoop(h, side);
                }
            }
        }
    }
    const b = br.bbEnd();
    if (b == br.NONE) return b;
    bdFinish(br.bd(b).first, br.bd(b).nf, &revolveIn);
    return b;
}

/// rv_vertices: the vertices at every boundary (one for points on the axis);
/// boundary np of a full turn is boundary 0
fn rvVertices(f: u32, n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const q = rz(bp_el[f + i].a);
        br_onax[i] = onaxis(q[1]);
        var k: u32 = 0;
        while (k <= br_np) : (k += 1) {
            var v: u32 = undefined;
            if (k == br_np and br_full) {
                v = br_pv[0][i];
            } else if (k != 0 and br_onax[i]) {
                v = br_pv[0][i];
            } else v = br.newVx(rotPt(q[0], q[1], br_phi[k]));
            br_pv[k][i] = v;
        }
    }
}

fn pvAt(i: u32, k: u32, n: u32) u32 {
    return br_pv[k][if (i >= n) i - n else i];
}

/// rv_edges: the profile edges at each boundary and the circles each point
/// draws in each patch
fn rvEdges(f: u32, n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const e = &bp_el[f + i];
        var on = onaxis(rz(e.a)[1]) and onaxis(rz(e.b)[1]);
        if (e.typ == E_ARC) on = false; // (an arc is never on it)
        var k: u32 = 0;
        while (k <= br_np) : (k += 1) {
            var ed: u32 = undefined;
            if (k == br_np and br_full) {
                ed = br_pe[0][i];
            } else if (on and k != 0) {
                ed = br_pe[0][i];
            } else {
                const phi = br_phi[k];
                var c: u32 = undefined;
                var t0: f64 = undefined;
                var t1: f64 = undefined;
                if (e.typ != E_ARC) {
                    const a = rz(e.a);
                    const b = rz(e.b);
                    const ln = br.mkLine(rotPt(a[0], a[1], phi), rotPt(b[0], b[1], phi));
                    c = ln.i;
                    t0 = 0;
                    t1 = ln.len;
                } else {
                    const cc = rz(e.c);
                    const fr: [3]V3 = .{ rotPt(cc[0], cc[1], phi), rotDir(0, phi), rotDir(1, phi) };
                    c = br.mkConic(nb.CT_CIRCLE, &fr, e.r, e.r);
                    t0 = e.t0;
                    t1 = e.t0 + e.sw;
                }
                ed = br.newEd(c, pvAt(i, k, n), pvAt(i + 1, k, n), t0, t1);
            }
            br_pe[k][i] = ed;
            // caps: the edges at 0 and at the end
            if (k == 0) e.na = ed;
            if (k == br_np) e.nb_ = ed;
        }
    }
    i = 0;
    while (i < n) : (i += 1) {
        const q = rz(bp_el[f + i].a);
        var k: u32 = 0;
        while (k < br_np) : (k += 1) {
            var ed: u32 = undefined;
            if (br_onax[i]) {
                // a pole: a degenerate edge
                const v = pvAt(i, k, n);
                ed = br.newEd(0, v, v, 0, 0);
                if (ed != br.NONE) br.ed(ed).flags |= br.EF_DEGEN;
            } else {
                const fr: [3]V3 = .{ nb.lin3(&br_ao, &br_azw, q[0], null, 0, null, 0), br_axw, br_ayw };
                const c = br.mkConic(nb.CT_CIRCLE, &fr, q[1], q[1]);
                ed = br.newEd(c, pvAt(i, k, n), pvAt(i, k + 1, n), br_phi[k], br_phi[k + 1]);
            }
            br_ce[k][i] = ed;
        }
    }
}

/// rv_faces: a face per element (off the axis) per patch
fn rvFaces(f: u32, n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const e = &bp_el[f + i];
        const a = rz(e.a);
        const b = rz(e.b);
        const on = onaxis(a[1]) and onaxis(b[1]);
        if (e.typ != E_ARC and on) continue; // a line on the axis: no face
        var k: u32 = 0;
        while (k < br_np) : (k += 1) {
            var hint: [2]f64 = .{ (br_phi[k] + br_phi[k + 1]) * 0.5, 0 };
            const s = rvSurface(e, a, b, &hint);
            _ = br.fbFace(s, hint[0], hint[1]);
            _ = br.fbLoop();
            _ = br.fbCe(br_pe[k][i], 0); // PE(i, k) forwards
            _ = br.fbCe(br_ce[k][if (i + 1 < n) i + 1 else 0], 0); // CE(i+1, k) forwards
            _ = br.fbCe(br_pe[k + 1][i], 1); // PE(i, k+1) backwards
            _ = br.fbCe(br_ce[k][i], 1); // CE(i, k) backwards
        }
    }
}

fn axisFrame() [3]V3 {
    return .{ br_ao, br_axw, br_ayw };
}

/// rv_surface: the surface the element sweeps; may change the hints
fn rvSurface(e: *const El, a: [2]f64, b: [2]f64, hint: *[2]f64) u32 {
    if (e.typ == E_ARC) {
        const c = rz(e.c);
        var fr = axisFrame();
        nb.v3axpy(&fr[0], br_azw, c[0]);
        if (onaxis(c[1])) return br.mkSurf(nb.ST_SPHERE, &fr, e.r, 0);
        // a torus; the v hint: the arc's middle seen from its centre
        const m = rz(elAt(e, 0.5));
        hint[1] = nb.datan2(m[0] - c[0], m[1] - c[1]);
        return br.mkSurf(nb.ST_TORUS, &fr, c[1], e.r);
    }
    if (onaxis(a[1] - b[1])) { // ra - rb tiny: a cylinder
        const fr = axisFrame();
        return br.mkSurf(nb.ST_CYL, &fr, a[1], 0);
    }
    if (onaxis(a[0] - b[0])) { // za - zb tiny: a plane across the axis
        var fr = axisFrame();
        nb.v3axpy(&fr[0], br_azw, a[0]);
        return br.mkSurf(nb.ST_PLANE, &fr, 0, 0);
    }
    // a cone: from the narrow end s to the wide end l, Z towards l
    var zs = a[0];
    var rs = a[1];
    var zl = b[0];
    var rl = b[1];
    if (!jae(rl, rs)) {
        zs = b[0];
        rs = b[1];
        zl = a[0];
        rl = a[1];
    }
    const dz = zl - zs;
    const dr = rl - rs;
    var fr = axisFrame();
    nb.v3axpy(&fr[0], br_azw, zs);
    if (!jbe(0, dz)) { // dz < 0: Y = -Ay (Z = X x Y = -Az), u = -phi
        fr[2] = nb.v3scale(fr[2], -1.0);
        hint[0] = fneg(hint[0]);
    }
    const ang = nb.datan2(dr, fabs(dz));
    return br.mkSurf(nb.ST_CONE, &fr, rs, ang);
}

test "bbuild compiles" {
    std.testing.refAllDecls(@This());
}
