// Rigid bodies (rbody.s): islands and the solver.
//
// Islands: bodies joined by contacts and joints through moving bodies
// (union-find), their bodies, manifolds and joints listed by island, awake
// when any body in it is. Each awake island takes the step in substeps
// (solve_island): forces, the warm start (contacts', then every joint's),
// iterations of joints and contacts (sequential impulses; soft contacts push
// overlaps apart), the bodies moved, a relax pass without the push; then
// restitution, and rest (an island at rest for half a second sleeps).
//
// A big island (128 constraints or more) is solved the same way as stages
// (solve_big): its constraints coloured greedily so that no two of a colour
// share a moving body (64 colours, the rest one serial block), each pass a
// stage per colour. The original runs the stages across its workers; a stage
// holds only independent items, so running them in order here gives the same
// bits. Islands are independent of each other too (island_job runs them in
// parallel): any order of islands gives the same result.
//
// Every number goes through the original's single-precision operations in its
// order (fpatan for the hinge's angle, as the original's x87 does).
const std = @import("std");
const builtin = @import("builtin");
const c = @import("rbcore.zig");

const V4 = c.V4;
const Body = c.Body;
const Manifold = c.Manifold;
const Joint = c.Joint;
const Contact = c.Contact;
const Row = c.Row;
const splat = c.splat;
const dot3 = c.dot3;
const cross = c.cross;
const mv3 = c.mv3;
const andXyz = c.andXyz;
const minss = c.minss;
const maxss = c.maxss;

// ---- constants (rodata) ----------------------------------------------------------------

const rx_tiny: f32 = 1.0e-9;
const rx_slop: f32 = 0.002;
const rx_pushmax: f32 = 1.0;
const rx_beta: f32 = 0.2;
const rx_bounce: f32 = 1.0;
const rx_rest2: f32 = 0.0025;
const rx_sleep: f32 = 0.5;
const rx_adamp: f32 = 0.05;
const rx_quarter: f32 = 0.25;
const rx_half: f32 = 0.5;
const rx_0577: f32 = 0.57735;

pub const ST_MAX = 8192;
const BIG = 128; // constraints that make an island big

// ---- the other files ------------------------------------------------------------------

const fields = @import("fields.zig"); // fl_n, fl_accel (force fields)
const nbody = @import("nbody.zig"); // nb_on (bodies that attract)

// ---- x87 (rb_atan2: fld y, fld x, fpatan, fstp single) ---------------------------------

// fld dword [rdi]; fld dword [rdi+4]; fpatan; fstp dword [rdi]; ret
export const bee_x87_rb_atan2f: [10]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0x47, 0x04, 0xd9, 0xf3, 0xd9, 0x1f, 0xc3 };

/// rb_atan2(y, x): fpatan, stored single.
pub fn rbAtan2(y: f32, x: f32) f32 {
    if (builtin.cpu.arch != .x86_64) return std.math.atan2(y, x);
    return run87f(&bee_x87_rb_atan2f, y, x);
}

fn run87f(code: []const u8, y: f32, x: f32) f32 {
    var a: [2]f32 = .{ y, x };
    const f: *const fn (*[2]f32) callconv(.c) void = @ptrCast(code.ptr);
    f(&a);
    return a[0];
}

// ---- islands ---------------------------------------------------------------------------

/// uf_find: its root (paths halved).
fn ufFind(start: u32) u32 {
    const p = c.par;
    var i = start;
    while (true) {
        const d = p[i];
        if (d == i) return i;
        const e = p[d];
        p[i] = e;
        i = e;
    }
}

/// uf_union: when both move.
fn ufUnion(a: u32, b: u32) void {
    if (c.bd[a].typ != 1) return;
    if (c.bd[b].typ != 1) return;
    const rb = ufFind(b);
    const ra = ufFind(a);
    if (ra == rb) return;
    c.par[ra] = rb;
}

/// isl_of: the island of the one that moves, or -1.
fn islOf(a: u32, b: u32) i32 {
    if (c.bd[a].typ == 1) return @bitCast(c.bd[a].isl);
    if (c.bd[b].typ == 1) return @bitCast(c.bd[b].isl);
    return -1;
}

/// mf_island: its island (-1: no points / none).
fn mfIsland(x: *const c.Mx) i32 {
    if (x.n == 0) return -1;
    return islOf(x.a, x.b);
}

/// isl_zero: nisl + 2 zeros.
fn islZero(s: []u32) void {
    @memset(s[0 .. c.nisl + 2], 0);
}

/// isl_prefix: prefix sums (counts at +1); the cursors (rb_par) too.
fn islPrefix(s: []u32) void {
    var acc: u32 = 0;
    var k: usize = 0;
    while (k <= c.nisl) : (k += 1) {
        acc +%= s[k];
        s[k] = acc;
        c.par[k] = acc;
    }
}

/// islands: bodies joined by contacts and joints (through moving bodies): their lists, and whether each is awake.
pub fn islands() void {
    const n = c.nb;
    for (0..n) |k| c.par[k] = @intCast(k);
    for (0..c.nmf) |k| {
        const x = &c.mx[k];
        if (x.n != 0) ufUnion(x.a, x.b);
    }
    for (0..c.njr) |k| {
        const j = &c.jr[k];
        if (j.fl & 4 == 0) ufUnion(j.a, j.b);
    }
    const ids = c.isj; // (root -> id, for now)
    for (0..n) |k| ids[k] = 0xffffffff;
    var ni: u32 = 0;
    for (0..n) |k| {
        const b = &c.bd[k];
        b.isl = 0xffffffff;
        if (b.typ != 1) continue;
        const r = ufFind(@intCast(k));
        if (ids[r] & 0x80000000 != 0) {
            ids[r] = ni;
            ni += 1;
        }
        b.isl = ids[r];
    }
    c.nisl = ni;
    // bodies by island
    islZero(c.isb);
    for (0..n) |k| {
        const s: i32 = @bitCast(c.bd[k].isl);
        if (s >= 0) c.isb[@as(usize, @intCast(s)) + 1] += 1;
    }
    islPrefix(c.isb);
    for (0..n) |k| {
        const s: i32 = @bitCast(c.bd[k].isl);
        if (s < 0) continue;
        const d = c.par[@intCast(s)];
        c.par[@intCast(s)] += 1;
        c.ib[d] = @intCast(k);
    }
    // manifolds by island
    islZero(c.ism);
    for (0..c.nmf) |k| {
        const s = mfIsland(&c.mx[k]);
        if (s >= 0) c.ism[@as(usize, @intCast(s)) + 1] += 1;
    }
    islPrefix(c.ism);
    for (0..c.nmf) |k| {
        const s = mfIsland(&c.mx[k]);
        if (s < 0) continue;
        const d = c.par[@intCast(s)];
        c.par[@intCast(s)] += 1;
        c.imf[d] = @intCast(k);
    }
    // joints by island
    islZero(c.isj);
    for (0..c.njr) |k| {
        const s = islOf(c.jr[k].a, c.jr[k].b);
        if (s >= 0) c.isj[@as(usize, @intCast(s)) + 1] += 1;
    }
    islPrefix(c.isj);
    for (0..c.njr) |k| {
        const s = islOf(c.jr[k].a, c.jr[k].b);
        if (s < 0) continue;
        const d = c.par[@intCast(s)];
        c.par[@intCast(s)] += 1;
        c.ij[d] = @intCast(k);
    }
    // awake: any body in it; then all of it
    for (0..ni) |k| c.iaw[k] = 0;
    for (0..n) |k| {
        const b = &c.bd[k];
        const s: i32 = @bitCast(b.isl);
        if (s < 0) continue;
        if (b.asleep != 0) continue;
        c.iaw[@intCast(s)] = 1;
    }
    for (0..n) |k| {
        const b = &c.bd[k];
        const s: i32 = @bitCast(b.isl);
        if (s < 0) continue;
        if (c.iaw[@intCast(s)] != 0) b.asleep = 0;
    }
}

// ---- the solver ------------------------------------------------------------------------

/// kmass: 1 / (mA + mB + (rA x d) IA (rA x d) + (rB x d) IB (rB x d)).
fn kmass(d: V4, ra: V4, rb: V4, a: *const Body, b: *const Body) f32 {
    var k = a.im + b.im;
    var x = cross(ra, d);
    k += dot3(mv3(&a.iiw, x), x);
    x = cross(rb, d);
    k += dot3(mv3(&b.iiw, x), x);
    k = maxss(k, rx_tiny);
    return 1.0 / k;
}

/// relvel: (vB + wB x rB) - (vA + wA x rA).
fn relvel(ra: V4, rb: V4, a: *const Body, b: *const Body) V4 {
    const vb = cross(b.w, rb) + b.v;
    const va = cross(a.w, ra) + a.v;
    return vb - va;
}

/// impulse: -P on A, +P on B (the moving ones).
fn impulse(p: V4, ra: V4, rb: V4, a: *Body, b: *Body) void {
    if (a.typ == 1) {
        a.v = a.v - splat(a.im) * p;
        a.w = a.w - mv3(&a.iiw, cross(ra, p));
    }
    if (b.typ == 1) {
        b.v = splat(b.im) * p + b.v;
        b.w = mv3(&b.iiw, cross(rb, p)) + b.w;
    }
}

/// ang_impulse: -on A, +on B (angular only).
fn angImpulse(l: V4, a: *Body, b: *Body) void {
    if (a.typ == 1) a.w = a.w - mv3(&a.iiw, l);
    if (b.typ == 1) b.w = mv3(&b.iiw, l) + b.w;
}

inline fn mfA(m: *const Manifold) *Body {
    return &c.bd[m.a];
}
inline fn mfB(m: *const Manifold) *Body {
    return &c.bd[m.b];
}

/// row_make: the row's cross products and inverse inertias; 1 / k.
fn rowMake(r: *Row, d: V4, p: *const Contact, a: *const Body, b: *const Body) f32 {
    var x = cross(p.ra, d);
    r.ax = x;
    var y = andXyz(mv3(&a.iiw, x));
    r.ia = y;
    var k = dot3(y, x);
    x = cross(p.rb, d);
    r.bx = x;
    y = andXyz(mv3(&b.iiw, x));
    r.ib = y;
    k += dot3(y, x);
    k += a.im;
    k += b.im;
    k = maxss(k, rx_tiny);
    return 1.0 / k;
}

/// row_vel: (vB - vA) . d + wB . (rB x d) - wA . (rA x d).
fn rowVel(r: *const Row, d: V4, a: *const Body, b: *const Body) f32 {
    var s = dot3(b.v - a.v, d);
    s += dot3(b.w, r.bx);
    s -= dot3(a.w, r.ax);
    return s;
}

/// row_push: -the impulse on A, + on B (the moving ones).
fn rowPush(r: *const Row, d: V4, j: f32, a: *Body, b: *Body) void {
    const jj = splat(j);
    if (a.typ == 1) {
        a.v = a.v - (splat(a.im) * d) * jj;
        a.w = a.w - r.ia * jj;
    }
    if (b.typ == 1) {
        b.v = (splat(b.im) * d) * jj + b.v;
        b.w = r.ib * jj + b.w;
    }
}

/// mf_prestep: each point's rows for the step, the gap's base, the speed it meets at.
pub fn mfPrestep(m: *Manifold) void {
    const a = mfA(m);
    const b = mfB(m);
    for (m.pts[0..m.n]) |*p| {
        p.mn = rowMake(&p.rn, m.nrm, p, a, b);
        p.mt1 = rowMake(&p.rt1, m.t1, p, a, b);
        p.mt2 = rowMake(&p.rt2, m.t2, p, a, b);
        const g = (((b.pos + p.rb) - a.pos) - p.ra);
        p.c0 = p.sep - dot3(g, m.nrm);
        p.vn0 = rowVel(&p.rn, m.nrm, a, b);
        p.jmax = 0;
    }
}

/// mf_warm: last time's impulses again (each substep).
pub fn mfWarm(m: *Manifold) void {
    const a = mfA(m);
    const b = mfB(m);
    for (m.pts[0..m.n]) |*p| {
        rowPush(&p.rn, m.nrm, p.jn, a, b);
        rowPush(&p.rt1, m.t1, p.jt1, a, b);
        rowPush(&p.rt2, m.t2, p.jt2, a, b);
    }
}

/// fr_row: one friction direction, within the limit.
fn frRow(t: V4, jt: *f32, mt: f32, r: *const Row, lim: f32, a: *Body, b: *Body) void {
    var x = -rowVel(r, t, a, b);
    x *= mt;
    const old = jt.*;
    x += old;
    x = minss(x, lim);
    x = maxss(x, -lim);
    jt.* = x;
    rowPush(r, t, x - old, a, b);
}

/// mf_solve / mf_relax: friction, then the normal (never pulling).
fn mfSolveIn(m: *Manifold, push: bool) void {
    const a = mfA(m);
    const b = mfB(m);
    m.dir ^= 1;
    var k: u32 = 0;
    while (k < m.n) : (k += 1) {
        const ix = if (m.dir != 0) m.n - k - 1 else k;
        const p = &m.pts[ix];
        if (push) {
            const lim = p.jn * m.fric;
            frRow(m.t1, &p.jt1, p.mt1, &p.rt1, lim, a, b);
            frRow(m.t2, &p.jt2, p.mt2, &p.rt2, lim, a, b);
        }
        var pb = mv3(&b.r, p.lb);
        pb += b.pos;
        var pa = mv3(&a.r, p.la);
        pa += a.pos;
        var s = dot3(pb - pa, m.nrm);
        s += p.c0;
        var ms: f32 = 1.0;
        var is: f32 = 0;
        var bias: f32 = 0;
        if (s > 0) {
            bias = s / c.h;
        } else if (push) {
            var rate = c.brate;
            var msc = c.mscale;
            var isc = c.iscale;
            if (a.typ == 2 or b.typ == 2) {
                rate = c.brate_s;
                msc = c.mscale_s;
                isc = c.iscale_s;
            }
            s += rx_slop;
            s = minss(s, 0);
            s *= rate;
            bias = maxss(-rx_pushmax, s);
            ms = msc;
            is = isc;
        }
        var x = rowVel(&p.rn, m.nrm, a, b);
        x += bias;
        x *= p.mn;
        x *= ms;
        x = -x;
        const old = p.jn;
        x -= old * is;
        x += old;
        x = maxss(x, 0);
        p.jn = x;
        p.jmax = maxss(p.jmax, x);
        rowPush(&p.rn, m.nrm, x - old, a, b);
    }
}
pub fn mfSolve(m: *Manifold) void {
    mfSolveIn(m, true);
}
pub fn mfRelax(m: *Manifold) void {
    mfSolveIn(m, false);
}

/// mf_bounce: after the substeps, points that met faster than 1 m/s and pushed leave at their restitution.
pub fn mfBounce(m: *Manifold) void {
    const a = mfA(m);
    const b = mfB(m);
    if (0 >= m.rest) return; // (comiss 0, rest; jae: none - unordered goes on)
    for (m.pts[0..m.n]) |*p| {
        if (!(-rx_bounce > p.vn0)) continue;
        if (0 >= p.jmax) continue;
        var x = rowVel(&p.rn, m.nrm, a, b);
        x += p.vn0 * m.rest;
        x *= p.mn;
        x = -x;
        const old = p.jn;
        x += old;
        x = maxss(x, 0);
        p.jn = x;
        rowPush(&p.rn, m.nrm, x - old, a, b);
    }
}

/// mf_tangents (on a scratch normal): t1, t2 square to it.
fn tangents(n: V4) [2]V4 {
    var t: V4 = undefined;
    if (@abs(n[0]) >= rx_0577) {
        t = .{ n[1], -n[0], 0, 0 };
    } else {
        t = .{ 0, n[2], -n[1], 0 };
    }
    var l = @sqrt(dot3(t, t));
    l = maxss(l, rx_tiny);
    t = andXyz(t / splat(l));
    return .{ t, andXyz(cross(n, t)) };
}

// ---- joints ----------------------------------------------------------------------------

inline fn jrA(j: *const Joint) *Body {
    return &c.bd[j.a];
}
inline fn jrB(j: *const Joint) *Body {
    return &c.bd[j.b];
}

/// jr_prestep: anchors, errors, axes.
pub fn jrPrestep(j: *Joint) void {
    if (j.fl & 4 != 0) return;
    j.macc = 0;
    const a = jrA(j);
    const b = jrB(j);
    var pa = mv3(&a.r, j.la);
    j.ra = pa;
    pa += a.pos;
    var pb = mv3(&b.r, j.lb);
    j.rb = pb;
    pb += b.pos;
    pb -= pa;
    j.c = pb;
    const aw = mv3(&a.r, j.axa);
    j.aw = aw;
    if (j.typ == 4) {
        j.pos = -dot3(pb, aw);
        const t = tangents(aw);
        j.p = t[0];
        j.q = t[1];
    } else if (j.typ == 2) {
        const ax = mv3(&a.r, j.axa);
        const bx = mv3(&b.r, j.axb);
        j.err = cross(ax, bx);
        const t = tangents(ax);
        j.p = t[0];
        j.q = t[1];
        if (j.fl == 0) return;
    }
    if (j.typ == 3) return;
    var e = c.qMul(b.q, j.q0);
    e = c.qMul(e, c.neg3(a.q));
    if (!(e[3] >= 0)) e = c.neg3(e);
    if (j.typ == 2) {
        const y = -dot3(e, j.aw);
        const x = @abs(e[3]);
        const ang = rbAtan2(y, x);
        j.pos = ang + ang;
        return;
    }
    e = e + e;
    j.err = andXyz(e);
}

/// The solve pass's scales: pull-back factor, mass scale, impulse scale, bias rate.
const Scales = struct { f: f32, ms: f32, is: f32, rate: f32 };

/// jr_solve / jr_relax: the anchors together (three rows), then the rotation.
fn jrSolveIn(j: *Joint, s: Scales) void {
    if (j.fl & 4 != 0) return;
    const a = jrA(j);
    const b = jrB(j);
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        var d = c.ident[r];
        if (j.typ == 4) {
            if (r >= 2) break;
            d = if (r == 0) j.p else j.q;
        }
        const k = kmass(d, j.ra, j.rb, a, b);
        const v = dot3(relvel(j.ra, j.rb, a, b), d);
        var x = dot3(j.c, d);
        x *= s.rate;
        x *= s.f;
        x = -x;
        x -= v;
        x *= k;
        x *= s.ms;
        x -= dot3(j.wl, d) * s.is;
        j.imp[r] = x + j.imp[r];
        const pv = splat(x) * d;
        j.wl = pv + j.wl;
        impulse(pv, j.ra, j.rb, a, b);
        if (jrOverload(j)) return;
    }
    jrExtra(j, a, b, s);
    if (j.typ == 3) return;
    r = 0;
    while (true) : (r += 1) {
        var d: V4 = undefined;
        var x: f32 = undefined;
        if (j.typ == 2) {
            if (r >= 2) return;
            d = if (r == 0) j.p else j.q;
            x = dot3(j.err, d);
        } else {
            if (r >= 3) return;
            d = c.ident[r];
            const e: [4]f32 = j.err;
            x = e[r];
        }
        x *= s.rate;
        x *= s.f;
        const target = -x;
        var k = dot3(mv3(&a.iiw, d), d);
        k += dot3(mv3(&b.iiw, d), d);
        k = maxss(k, rx_tiny);
        const rel = dot3(b.w - a.w, d);
        var y = target - rel;
        y /= k;
        y *= s.ms;
        y -= dot3(j.wa, d) * s.is;
        const l = splat(y) * d;
        j.wa = l + j.wa;
        angImpulse(l, a, b);
    }
}
pub fn jrSolve(j: *Joint) void {
    var s = Scales{ .f = 1.0, .rate = c.jsoft[0], .ms = c.jsoft[1], .is = c.jsoft[2] };
    if (!(0 >= j.brk)) { // breakable (or unordered): rigid, as it was
        s.rate = c.jhard;
        s.ms = 1.0;
        s.is = 0;
    }
    jrSolveIn(j, s);
}
pub fn jrRelax(j: *Joint) void {
    jrSolveIn(j, .{ .f = 0, .ms = 1.0, .is = 0, .rate = 0 });
}

/// jr_warmstart: jr_warm on its bodies (not broken, not breakable).
pub fn jrWarmstart(j: *Joint) void {
    if (j.fl & 4 != 0) return;
    if (!(0 >= j.brk)) return; // (comiss 0, brk; jb: breakable)
    jrWarm(j, jrA(j), jrB(j));
}

/// jr_warm: the impulses its rows took before, given again (less what its rows can't push).
fn jrWarm(j: *Joint, a: *Body, b: *Body) void {
    var l = j.wl;
    if (j.typ == 4 and !jrLocked(j)) {
        const x = dot3(l, j.aw);
        l = l - splat(x) * j.aw;
        j.wl = l;
    }
    if (j.typ == 4) {
        j.imp[0] = dot3(l, j.p) + j.imp[0];
        j.imp[1] = dot3(l, j.q) + j.imp[1];
    } else {
        j.imp[0] = l[0] + j.imp[0];
        j.imp[1] = l[1] + j.imp[1];
        j.imp[2] = l[2] + j.imp[2];
    }
    impulse(l, j.ra, j.rb, a, b);
    if (j.typ == 3) return;
    var w = j.wa;
    if (j.typ == 2 and !jrLocked(j)) {
        const x = dot3(w, j.aw);
        w = w - splat(x) * j.aw;
        j.wa = w;
    }
    angImpulse(w, a, b);
}

/// jr_locked: held (limited, lo = hi).
fn jrLocked(j: *const Joint) bool {
    return j.fl & 1 != 0 and j.lo == j.hi;
}

/// jr_extra: a hinge's or slider's limits (one way) and motor.
fn jrExtra(j: *Joint, a: *Body, b: *Body, s: Scales) void {
    if (j.fl & 3 == 0) return;
    if (j.typ != 2 and j.typ != 4) return;
    if (j.fl & 1 != 0) limits: {
        if (jrLocked(j)) {
            var t = j.lo - j.pos;
            t *= s.rate;
            t *= s.f;
            const sp = jrAxisSpeed(j, a, b);
            var x = t - sp[0];
            x *= sp[1];
            x *= s.ms;
            const acc = if (j.typ == 2) j.wa else j.wl;
            x += dot3(acc, j.aw) * s.is;
            const sum = splat(-x) * j.aw;
            if (j.typ == 2) j.wa = sum + j.wa else j.wl = sum + j.wl;
            jrAxisPush(j, x, a, b);
            break :limits;
        }
        var t = j.lo - j.pos;
        var up = true;
        if (t > 0) {
            t *= rx_beta;
            t /= c.h;
        } else {
            t = j.hi - j.pos;
            if (t >= 0) break :limits;
            t *= rx_beta;
            t /= c.h;
            up = false;
        }
        t *= s.f;
        const sp = jrAxisSpeed(j, a, b);
        const dv = t - sp[0];
        if (up) {
            if (!(dv > 0)) break :limits;
        } else {
            if (dv >= 0) break :limits;
        }
        jrAxisPush(j, dv * sp[1], a, b);
    }
    if (j.fl & 2 != 0) {
        const sp = jrAxisSpeed(j, a, b);
        var x = j.ms - sp[0];
        x *= sp[1];
        const most = j.mf * c.h;
        const old = j.macc;
        x += old;
        x = minss(x, most);
        x = maxss(x, -most);
        j.macc = x;
        jrAxisPush(j, x - old, a, b);
    }
}

/// jr_axis_speed: the joint's speed along its axis (A's, from B), its effective mass.
fn jrAxisSpeed(j: *const Joint, a: *const Body, b: *const Body) [2]f32 {
    if (j.typ == 2) {
        const d = j.aw;
        var k = dot3(mv3(&a.iiw, d), d);
        k += dot3(mv3(&b.iiw, d), d);
        k = maxss(k, rx_tiny);
        const m = 1.0 / k;
        return .{ dot3(a.w - b.w, d), m };
    }
    const m = kmass(j.aw, j.ra, j.rb, a, b);
    const v = -dot3(relvel(j.ra, j.rb, a, b), j.aw);
    return .{ v, m };
}

/// jr_axis_push: +on A, -on B along the axis.
fn jrAxisPush(j: *const Joint, x: f32, a: *Body, b: *Body) void {
    const p = splat(-x) * j.aw;
    if (j.typ == 2) angImpulse(p, a, b) else impulse(p, j.ra, j.rb, a, b);
}

fn load(j: *const Joint) f32 {
    var l = j.imp[0] * j.imp[0];
    l += j.imp[1] * j.imp[1];
    l += j.imp[2] * j.imp[2];
    return @sqrt(l);
}

/// jr_overload: its load this step passed its breaking force (broken now).
fn jrOverload(j: *Joint) bool {
    if (!(j.brk > 0)) return false;
    const lim = j.brk * c.dt;
    if (lim >= load(j)) return false;
    j.fl |= 4;
    _ = @atomicRmw(u32, &c.nbroken, .Add, 1, .monotonic);
    return true;
}

/// jr_breaks: after a step, joints pulled past their breaking force are gone; the loads start again.
pub fn jrBreaks() void {
    for (c.jr[0..c.njr]) |*j| {
        if (j.fl & 4 == 0 and j.brk > 0) {
            const lim = j.brk * c.dt;
            if (!(lim >= load(j))) {
                j.fl |= 4;
                c.nbroken += 1;
            }
        }
        j.imp = .{ 0, 0, 0 };
    }
}

// ---- islands solved --------------------------------------------------------------------

/// island_job: each awake island that is not big (jobs.parallelFor: ctx unused).
pub fn islandJob(ctx: *anyopaque, lo: usize, hi: usize, thread: usize) void {
    _ = ctx;
    _ = thread;
    for (lo..hi) |k| {
        if (c.iaw[k] == 0) continue;
        if (islBig(@intCast(k))) continue;
        solveIsland(@intCast(k));
    }
}

/// The islands' step (rb_step's part): island_job over all, then the big ones one at a time.
pub fn solveAll() void {
    var dummy: u8 = 0;
    if (c.nisl == 0) return;
    islandJob(&dummy, 0, c.nisl, 0);
    for (0..c.nisl) |k| {
        if (c.iaw[k] == 0) continue;
        if (islBig(@intCast(k))) solveBig(@intCast(k));
    }
}

fn eachMf(isl: u32, f: *const fn (*Manifold) void) void {
    for (c.ism[isl]..c.ism[isl + 1]) |k| f(&c.mf[c.imf[k]]);
}
fn eachJr(isl: u32, f: *const fn (*Joint) void) void {
    for (c.isj[isl]..c.isj[isl + 1]) |k| f(&c.jr[c.ij[k]]);
}
fn eachBody(isl: u32, f: *const fn (*Body) void) void {
    for (c.isb[isl]..c.isb[isl + 1]) |k| f(&c.bd[c.ib[k]]);
}

/// solve_island: the step in substeps; then restitution, and rest.
pub fn solveIsland(isl: u32) void {
    eachMf(isl, mfPrestep);
    var sub: u32 = 0;
    while (sub < c.nsub) : (sub += 1) {
        eachBody(isl, bodyForce);
        eachMf(isl, mfWarm);
        eachJr(isl, jrPrestep);
        eachJr(isl, jrWarmstart);
        var it: u32 = 0;
        while (it < c.iter) : (it += 1) {
            eachJr(isl, jrSolve);
            eachMf(isl, mfSolve);
        }
        eachBody(isl, integrate);
        eachJr(isl, jrPrestep);
        eachJr(isl, jrRelax);
        eachMf(isl, mfRelax);
    }
    eachMf(isl, mfBounce);
    islRest(isl);
}

/// isl_rest: each body's time at rest; all long enough at rest: the island sleeps.
pub fn islRest(isl: u32) void {
    var least: f32 = rx_sleep;
    for (c.isb[isl]..c.isb[isl + 1]) |k| {
        const b = &c.bd[c.ib[k]];
        var v = dot3(b.v, b.v);
        var w = dot3(b.w, b.w);
        const e = b.max - b.min;
        var sz = dot3(e, e);
        sz *= rx_quarter;
        sz = minss(sz, 1.0);
        w *= sz;
        v = maxss(v, w);
        var t: f32 = 0;
        if (!(v >= rx_rest2)) t = b.sleep + c.dt;
        b.sleep = t;
        least = minss(t, least);
    }
    if (least < rx_sleep or std.math.isNan(least)) return; // (jb: below or unordered)
    for (c.isb[isl]..c.isb[isl + 1]) |k| {
        const b = &c.bd[c.ib[k]];
        b.asleep = 1;
        b.v = @splat(0);
        b.w = @splat(0);
    }
}

/// body_force: a substep's gravity (and force fields, the bodies' pull) and damping.
pub fn bodyForce(b: *Body) void {
    var g = c.g;
    if (fields.n != 0) { // fields: their pull at its centre of mass, gravity in it
        const r = fields.accel(.{ b.pos[0], b.pos[1], b.pos[2] }, .{ b.v[0], b.v[1], b.v[2] }, b.grp & 0xffff, false);
        g = .{ r[0], r[1], r[2], 0 };
    }
    if (nbody.on) { // the step's pull as one kick in its first substep
        const n: f32 = @floatFromInt(c.nsub);
        g = g + splat(n) * b.nba;
        b.nba = @splat(0);
    }
    g = g * splat(c.h);
    var v = b.v + g;
    var dmp = b.damp * c.h;
    dmp += 1.0;
    v = v / splat(dmp);
    b.v = andXyz(v);
    var ad = rx_adamp * c.h;
    ad += 1.0;
    b.w = andXyz(b.w / splat(ad));
}

/// isl_big: 128 constraints or more.
pub fn islBig(isl: u32) bool {
    var n = c.ism[isl + 1] -% c.ism[isl];
    n +%= c.isj[isl + 1] -% c.isj[isl];
    return n >= BIG;
}

// ---- big islands: stages ----------------------------------------------------------------

const Kind = enum { con, bodies };
const Stage = struct {
    fmf: ?*const fn (*Manifold) void = null,
    fjr: ?*const fn (*Joint) void = null,
    fbd: ?*const fn (*Body) void = null,
    base: []const u32 = &.{},
    gr: u32 = 0,
    kind: Kind = .con,
};
var stages: [ST_MAX]Stage = undefined;

/// st_add: a stage at the end (counted past ST_MAX: then the step is not run that way).
fn stAdd(items: []const u32, gr: u32, s: Stage) void {
    if (items.len == 0) return;
    const k = c.nstg;
    c.nstg += 1;
    if (k >= ST_MAX) return;
    stages[k] = s;
    stages[k].base = items;
    stages[k].gr = gr;
}

/// st_colours: a stage per colour (the last, the serial one, a single block).
fn stColours(fmf: ?*const fn (*Manifold) void, fjr: ?*const fn (*Joint) void) void {
    var col: usize = 0;
    while (col <= 64) : (col += 1) {
        const s0 = c.bcst[col];
        const n = c.bcst[col + 1] - s0;
        if (n == 0) continue;
        stAdd(c.bsrt[s0..][0..n], if (col == 64) n else 16, .{ .fmf = fmf, .fjr = fjr, .kind = .con });
    }
}

/// st_all: one stage of every constraint (passes that write no body).
fn stAll(fmf: ?*const fn (*Manifold) void, fjr: ?*const fn (*Joint) void) void {
    stAdd(c.bsrt[0..c.bcst[65]], 32, .{ .fmf = fmf, .fjr = fjr, .kind = .con });
}

/// st_bodies: a stage of the island's bodies.
fn stBodies(isl: u32, f: *const fn (*Body) void) void {
    const s0 = c.isb[isl];
    stAdd(c.ib[s0..c.isb[isl + 1]], 64, .{ .fbd = f, .kind = .bodies });
}

/// st_block: the stage's fn on one block.
fn stBlock(s: *const Stage, blk: usize) void {
    const first = blk * s.gr;
    const end = @min(first + s.gr, s.base.len);
    for (s.base[first..end]) |it| {
        if (s.kind == .bodies) {
            s.fbd.?(&c.bd[it]);
        } else if (it & 0x80000000 == 0) {
            if (s.fmf) |f| f(&c.mf[it]);
        } else {
            if (s.fjr) |f| f(&c.jr[it & 0x7fffffff]);
        }
    }
}

/// stage_job (one lane): every stage in turn, its blocks in order. A stage's
/// items share no moving body, so this is the result of any number of lanes.
fn stageRun() void {
    for (stages[0..c.nstg]) |*s| {
        const nblk = (s.base.len + s.gr - 1) / s.gr;
        for (0..nblk) |k| stBlock(s, k);
    }
}

/// con_bodies: the moving bodies' colour masks (or null).
fn conBodies(x: u32) [2]?*u64 {
    var a: u32 = undefined;
    var b: u32 = undefined;
    if (x & 0x80000000 == 0) {
        a = c.mf[x].a;
        b = c.mf[x].b;
    } else {
        const j = &c.jr[x & 0x7fffffff];
        a = j.a;
        b = j.b;
    }
    return .{
        if (c.bd[a].typ == 1) &c.bmask[a] else null,
        if (c.bd[b].typ == 1) &c.bmask[b] else null,
    };
}

/// solve_big: solve_island's steps for a big island, as coloured stages.
pub fn solveBig(isl: u32) void {
    const con = c.bcon;
    var n: u32 = 0;
    for (c.ism[isl]..c.ism[isl + 1]) |k| {
        con[n] = c.imf[k];
        n += 1;
    }
    for (c.isj[isl]..c.isj[isl + 1]) |k| {
        con[n] = c.ij[k] | 0x80000000;
        n += 1;
    }
    for (c.isb[isl]..c.isb[isl + 1]) |k| c.bmask[c.ib[k]] = 0;
    @memset(c.bcst[0..68], 0);
    for (0..n) |k| {
        const mb = conBodies(con[k]);
        var used: u64 = 0;
        if (mb[0]) |p| used |= p.*;
        if (mb[1]) |p| used |= p.*;
        const free = ~used;
        const col: u32 = if (free == 0) 64 else @ctz(free);
        c.bcol[k] = col;
        c.bcst[col + 1] += 1;
        if (col < 64) {
            const bit = @as(u64, 1) << @intCast(col);
            if (mb[0]) |p| p.* |= bit;
            if (mb[1]) |p| p.* |= bit;
        }
    }
    var acc: u32 = 0;
    for (0..66) |k| {
        acc += c.bcst[k];
        c.bcst[k] = acc;
    }
    var cur: [66]u32 = undefined;
    @memcpy(&cur, c.bcst[0..66]);
    for (0..n) |k| {
        const col = c.bcol[k];
        c.bsrt[cur[col]] = con[k];
        cur[col] += 1;
    }
    // the step as stages
    c.nstg = 0;
    c.islj = c.isj[isl + 1] - c.isj[isl];
    stAll(mfPrestep, jrPrestep);
    var sub: u32 = 0;
    while (sub < c.nsub) : (sub += 1) {
        stBodies(isl, bodyForce);
        stColours(mfWarm, jrWarmstart);
        if (sub != 0 and c.islj != 0) stAll(null, jrPrestep);
        var it: u32 = 0;
        while (it < c.iter) : (it += 1) stColours(mfSolve, jrSolve);
        stBodies(isl, integrate);
        if (c.islj != 0) stAll(null, jrPrestep);
        stColours(mfRelax, jrRelax);
    }
    stColours(mfBounce, null);
    if (c.nstg > ST_MAX) { // too many stages: one thread
        solveIsland(isl);
        return;
    }
    stageRun();
    islRest(isl);
}

/// integrate: position, orientation (q += h/2 (w, 0) q), the rest.
pub fn integrate(b: *Body) void {
    const hh = splat(c.h);
    b.pos = andXyz(b.v * hh + b.pos);
    var q = c.qMul(andXyz(b.w), b.q);
    q = q * splat(c.h * rx_half);
    q = q + b.q;
    const l = @sqrt(c.dot4(q, q));
    b.q = q / splat(l);
    c.bodyUpdate(b);
}

// ---- tests -----------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

const T = struct {
    var bodies: [4]Body = undefined;
    var parv: [8]u32 = undefined;
    var isbv: [8]u32 = undefined;
    var ismv: [8]u32 = undefined;
    var isjv: [8]u32 = undefined;
    var ibv: [8]u32 = undefined;
    var imfv: [8]u32 = undefined;
    var ijv: [8]u32 = undefined;
    var iawv: [8]u32 = undefined;
    var mxv: [4]c.Mx = undefined;
    fn unit(p: V4) Body {
        var b = Body{};
        b.pos = p;
        b.q = c.qid;
        b.im = 1;
        b.iil = .{ 6, 6, 6, 0 };
        b.typ = 1;
        return b;
    }
    fn setup() void {
        c.bd = &bodies;
        c.par = &parv;
        c.isb = &isbv;
        c.ism = &ismv;
        c.isj = &isjv;
        c.ib = &ibv;
        c.imf = &imfv;
        c.ij = &ijv;
        c.iaw = &iawv;
        c.mx = &mxv;
        c.dt = 1.0 / 120.0;
        for (&bodies) |*b| {
            b.* = unit(.{ 0, 0, 0, 0 });
            c.bodyUpdate(b);
        }
    }
};

test "a contact's normal impulse stops two unit bodies closing" {
    T.setup();
    var a = &T.bodies[0];
    var b = &T.bodies[1];
    a.v = .{ 1, 0, 0, 0 };
    b.v = .{ -1, 0, 0, 0 };
    b.pos = .{ 1, 0, 0, 0 };
    c.bodyUpdate(b);
    c.h = 1.0 / 480.0;
    var m = Manifold{ .a = 0, .b = 1, .n = 1, .nrm = .{ 1, 0, 0, 0 } };
    const t = tangents(m.nrm);
    m.t1 = t[0];
    m.t2 = t[1];
    m.pts[0].ra = .{ 0.5, 0, 0, 0 };
    m.pts[0].rb = .{ -0.5, 0, 0, 0 };
    m.pts[0].la = m.pts[0].ra;
    m.pts[0].lb = m.pts[0].rb;
    m.pts[0].sep = 0;
    mfPrestep(&m);
    // centred along the normal: no turn, k = 2, closing at 2
    try std.testing.expectEqual(@as(f32, 0.5), m.pts[0].mn);
    try std.testing.expectEqual(@as(f32, -2), m.pts[0].vn0);
    mfRelax(&m); // gap 0, no push: the closing speed taken away
    try std.testing.expectEqual(@as(f32, 1), m.pts[0].jn);
    try std.testing.expectEqual(@as(f32, 0), a.v[0]);
    try std.testing.expectEqual(@as(f32, 0), b.v[0]);
    try std.testing.expectEqual(@as(f32, 0), a.w[1]);
}

test "islands of a small graph" {
    T.setup();
    c.nb = 4;
    T.bodies[3].typ = 2; // static: joins nothing
    c.nmf = 2;
    T.mxv[0] = .{ .a = 0, .b = 3, .n = 1 };
    T.mxv[1] = .{ .a = 1, .b = 2, .n = 1 };
    c.njr = 0;
    islands();
    try std.testing.expectEqual(@as(u32, 2), c.nisl);
    try std.testing.expectEqual(@as(u32, 0), T.bodies[0].isl);
    try std.testing.expectEqual(T.bodies[1].isl, T.bodies[2].isl);
    try std.testing.expectEqual(@as(u32, 0xffffffff), T.bodies[3].isl);
    try std.testing.expectEqual(@as(u32, 1), c.ism[1] - c.ism[0]);
    try std.testing.expect(!islBig(0));
}

test "rb_atan2 is fpatan" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.7853982), rbAtan2(1, 1), 1e-7);
}

test "a big island's stages give solve_island's bits when the colours keep its order" {
    T.setup();
    c.nb = 3;
    c.nsub = 4;
    c.iter = 3;
    c.h = 1.0 / 480.0;
    c.g = .{ 0, -9.81, 0, 0 };
    c.brate = 30;
    c.mscale = 0.9;
    c.iscale = 0.1;
    var mfv: [2]Manifold = undefined;
    var bconv: [8]u32 = undefined;
    var bsrtv: [8]u32 = undefined;
    var bcolv: [8]u32 = undefined;
    var bmaskv: [8]u64 = undefined;
    var bcstv: [70]u32 = undefined;
    c.mf = &mfv;
    c.bcon = &bconv;
    c.bsrt = &bsrtv;
    c.bcol = &bcolv;
    c.bmask = &bmaskv;
    c.bcst = &bcstv;
    c.njr = 0;
    c.nmf = 2;
    for (0..2) |k| {
        var m = Manifold{ .a = @intCast(k), .b = @intCast(k + 1), .n = 1, .fric = 0.5, .rest = 0.3, .nrm = .{ 0, 1, 0, 0 } };
        const t = tangents(m.nrm);
        m.t1 = t[0];
        m.t2 = t[1];
        m.pts[0].ra = .{ 0.1, 0.5, 0, 0 };
        m.pts[0].rb = .{ 0.1, -0.5, 0.05, 0 };
        m.pts[0].la = m.pts[0].ra;
        m.pts[0].lb = m.pts[0].rb;
        m.pts[0].sep = -0.01;
        mfv[k] = m;
        T.mxv[k] = .{ .a = m.a, .b = m.b, .n = 1 };
    }
    for (0..3) |k| {
        T.bodies[k].pos = .{ 0, @floatFromInt(k), 0, 0 };
        T.bodies[k].v = .{ 0.3, -2, 0.1, 0 };
        c.bodyUpdate(&T.bodies[k]);
    }
    const b0 = T.bodies;
    const m0 = mfv;
    islands();
    solveIsland(0);
    const want = T.bodies;
    T.bodies = b0;
    mfv = m0;
    islands();
    solveBig(0);
    for (0..3) |k| {
        try std.testing.expectEqual(want[k].v, T.bodies[k].v);
        try std.testing.expectEqual(want[k].w, T.bodies[k].w);
        try std.testing.expectEqual(want[k].q, T.bodies[k].q);
    }
    try std.testing.expect(want[0].v[1] != b0[0].v[1]);
}
