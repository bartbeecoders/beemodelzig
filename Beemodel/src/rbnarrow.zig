// Rigid bodies (rbody.s): the narrow phase and continuous collision.
//
// Each manifold (a pair of parts whose bounds met this step) with something
// awake in it is brought up to date (mfUpdate): its points refreshed (gone
// when apart or slid), then new ones: a plane's own (clip.zig polyPlane), the
// faces of two polytopes clipped (polyClip), else collide's point (collide.zig)
// and, for polytopes touching at an edge or vertex, more found by tilting the
// smaller part a little four ways. At most four points are kept (the deepest,
// then the most area). A contact on a mesh's inner edges takes the face's
// normal (triFix).
//
// ccdPass: a fast moving body against the static parts it has manifolds with:
// conservative advancement from where the step began to the first time of
// impact; it is put there, a little short, its velocity kept.
//
// The manifolds' hash (mfHash, hfSlot, hfDelete: linear probing, kept as
// manifolds are made and go) and compact are here too.
//
// The original's single-precision operations in its order throughout.
const std = @import("std");
const rc = @import("rbcore.zig");
const cx = @import("collide.zig");
const clip = @import("clip.zig");
const sincos = @import("animexpr.zig").sincos32;

const V4 = rc.V4;
const Body = rc.Body;
const Part = rc.Part;
const Proxy = rc.Proxy;
const Hit = rc.Hit;
const Manifold = rc.Manifold;
const Contact = rc.Contact;
const dot3 = rc.dot3;
const cross = rc.cross;
const splat = rc.splat;
const andXyz = rc.andXyz;

const MARGIN: f32 = 0.02; // contacts begin this far apart
const KEEP: f32 = 0.04; // points kept this far apart,
const DRIFT2: f32 = 0.0004; //  sliding less than 2 cm
const SAME2: f32 = 0.0004; // a new point this near an old one
const CCD_TOL: f32 = 0.005;
const CCD_BACK: f32 = 0.02;
const TILT: f32 = 0.02; // radians
const C0577: f32 = 0.57735;
const TINY: f32 = 1.0e-9;

/// AWAKE: a moving body, not asleep.
pub inline fn awake(b: *const Body) bool {
    return b.typ == 1 and b.asleep == 0;
}

// ---- times (rb_lap) ---------------------------------------------------------------------

/// rb_lap: the time since t added to part's total (rb_tns); t = now.
pub fn lap(part: usize, t: *u64) void {
    const now = rc.nowNs();
    rc.tns[part] +%= now -% t.*;
    t.* = now;
}

// ---- the manifolds' hash ---------------------------------------------------------------

/// mf_hash: the slot to start at for parts a, b.
pub fn mfHash(a: u32, b: u32) u32 {
    var x: u64 = (@as(u64, a) << 32) | b;
    x *%= 0x9E3779B97F4A7C15;
    x ^= x >> 29;
    return @as(u32, @truncate(x)) & rc.hmask;
}

/// hf_slot: manifold m's slot in the hash (it is there).
pub fn hfSlot(m: u32) u32 {
    const k = &rc.mx[m];
    var s = mfHash(k.pa, k.pb);
    while (rc.hs[s] != m + 1) s = (s + 1) & rc.hmask;
    return s;
}

/// hf_delete: that slot emptied, the entries after it shifted back (linear
/// probing: no gaps between an entry and its home).
pub fn hfDelete(slot: u32) void {
    var i = slot; // the hole
    rc.hs[i] = 0;
    var j = i;
    while (true) {
        j = (j + 1) & rc.hmask;
        const e = rc.hs[j];
        if (e == 0) return;
        const k = &rc.mx[e - 1];
        const home = mfHash(k.pa, k.pb);
        // it may move to i when its home is not cyclically in (i, j]
        const dj = (j -% home) & rc.hmask;
        const di = (j -% i) & rc.hmask;
        if (dj < di) continue;
        rc.hs[i] = e;
        rc.hs[j] = 0;
        i = j;
    }
}

/// compact: manifolds not seen this step go (the last into each one's place).
pub fn compact() void {
    var b: u32 = 0;
    while (b < rc.nmf) {
        if (rc.mx[b].keep == rc.stepno) {
            b += 1;
            continue;
        }
        hfDelete(hfSlot(b)); // not seen: out of the hash
        rc.nmf -= 1;
        const last = rc.nmf;
        if (b == last) continue;
        rc.hs[hfSlot(last)] = b + 1; // (its hash entry: the new index)
        rc.mx[b] = rc.mx[last];
        rc.mf[b] = rc.mf[last];
        // (that one checked next)
    }
}

// ---- bounds and reach (the broad phase's helpers) -------------------------------------

/// pp_reach: a mesh's triangle (its part) comes within reach (squared) of a centre.
pub fn ppReach(tri: u32, centre: V4, reach2: f32) bool {
    const p = &rc.pt[tri];
    const c = rc.tvw[p.tw * 3 ..][0..3];
    var q: [3]V4 = undefined;
    for (0..3) |k| q[k] = andXyz(c[k] - centre);
    var o: cx.Closest = .{};
    cx.triClosest(q[0], q[1], q[2], &o);
    return !(dot3(o.v, o.v) > reach2);
}

/// part_bounds: a part's bounds in the world (with the margin and its step's move).
pub fn partBounds(b: *const Body, part: u32, out: *[2]V4) void {
    const p = &rc.pt[part];
    if (p.typ == 2) { // a plane: without end
        out[0] = rc.nbig4;
        out[1] = rc.big4;
        return;
    }
    var c = rc.mv3(&b.r, p.off);
    c += b.pos;
    const e = andXyz(splat(p.rad)) + p.half;
    var ext: V4 = .{ dot3(rc.abs3(b.r[0]), e), dot3(rc.abs3(b.r[1]), e), dot3(rc.abs3(b.r[2]), e), 0 };
    ext += rc.marg4;
    ext += andXyz(rc.abs3(b.v) * splat(rc.dt));
    out[0] = c - ext;
    out[1] = c + ext;
}

// ---- the narrow phase -----------------------------------------------------------------

/// narrow_job: manifolds [lo, hi) with something awake in them brought up to
/// date (jobs.parallelFor's signature).
pub fn narrowJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    var i = lo;
    while (i < hi) : (i += 1) {
        const m = &rc.mf[i];
        if (!awake(&rc.bd[m.a]) and !awake(&rc.bd[m.b])) continue;
        mfUpdate(m);
        rc.mx[i].n = m.n; // (its count in the keys)
    }
}

/// mf_update: its points refreshed (gone when apart or slid), a new one from
/// collide, more by tilting (polytopes), at most four kept.
pub fn mfUpdate(m: *Manifold) void {
    const A = &rc.bd[m.a];
    const B = &rc.bd[m.b];
    // the margin: 2 cm, and as far as they can close in a step
    var mg = @sqrt(dot3(A.v, A.v));
    mg += @sqrt(dot3(B.v, B.v));
    mg *= rc.dt;
    mg += MARGIN;
    const keep = rc.maxss(mg + MARGIN, KEEP);
    // refresh
    var k: u32 = 0;
    while (k < m.n) {
        const p = &m.pts[k];
        const ra = rc.mv3(&A.r, p.la);
        p.ra = ra;
        const wa = ra + A.pos;
        p.wa = wa;
        const rb = rc.mv3(&B.r, p.lb);
        p.rb = rb;
        var d = (rb + B.pos) - wa;
        const sep = dot3(d, m.nrm);
        p.sep = sep;
        var gone = sep > keep;
        if (!gone) { // sliding: d - n sep
            d -= splat(sep) * m.nrm;
            gone = dot3(d, d) > DRIFT2;
        }
        if (gone) {
            cpRemove(m, k);
            continue;
        }
        k += 1;
    }
    // a new point
    var pxa: Proxy = .{};
    var pxb: Proxy = .{};
    cx.pxPlace(&pxa, &A.r, A.pos, &rc.pt[m.pa]);
    cx.pxPlace(&pxb, &B.r, B.pos, &rc.pt[m.pb]);
    var cl: [4]Hit = @splat(.{});
    var scratch: [4]Contact = @splat(.{});
    const pla = pxa.part.?.typ == 2;
    if (pla or pxb.part.?.typ == 2) { // a plane: its own contacts
        const n = if (pla)
            clip.polyPlane(&pxa, &pxb, true, mg, &cl, m)
        else
            clip.polyPlane(&pxb, &pxa, false, mg, &cl, m);
        if (n == 0) {
            m.n = 0; // (apart)
            return;
        }
        m.nrm = cl[0].n;
        mfReplace(m, A, B, cl[0..n], &scratch);
        mfTangents(m);
        return;
    }
    var res: Hit = .{};
    cx.collide(&pxa, &pxb, &res);
    if (res.sep > mg) {
        m.n = 0; // apart
        return;
    }
    // a mesh's triangle: its inactive edges (tri_fix)
    var tri: ?*const Proxy = null;
    var tri_a = false;
    if (pxa.part.?.flg & 1 != 0) {
        tri = &pxa;
        tri_a = true;
    } else if (pxb.part.?.flg & 1 != 0) tri = &pxb;
    if (tri) |t| {
        clip.triFix(t, &res, tri_a);
        if (res.sep > mg) { // (the gap along the face: maybe apart)
            m.n = 0;
            return;
        }
    }
    m.nrm = res.n;
    // polytopes: their faces clipped - the whole contact at once
    const nc = clip.polyClip(&pxa, &pxb, res.n, mg, &cl);
    if (nc != 0) {
        mfReplace(m, A, B, cl[0..nc], &scratch);
        mfTangents(m);
        return;
    }
    cpAdd(m, A, B, &res);
    // other polytopes (edges, vertices): tilt the smaller a little four ways
    if (m.n >= 4 or !noRad(pxa.part.?.rad) or !noRad(pxb.part.?.rad)) {
        mfTangents(m);
        return;
    }
    mfTangents(m);
    const piv = res.pa; // the pivot: the contact
    const ha = pxa.part.?.half;
    const hb = pxb.part.?.half;
    const who: u32 = if (dot3(ha, ha) > dot3(hb, hb)) 1 else 0;
    for (0..4) |r| {
        const axis = if (r & 2 != 0) m.t2 else m.t1;
        const ang: f32 = if (r & 1 != 0) -TILT else TILT;
        var q: [3]V4 = undefined;
        rotAxis4(&q, axis, ang);
        const src: *const Proxy = if (who == 0) &pxa else &pxb;
        var pt: Proxy = .{};
        rowsMul(&pt.r, &q, &src.r); // the one tilted: rows Q R, centre P + Q (C - P)
        pt.c = andXyz(rc.mv3(&q, src.c - piv) + piv);
        pt.part = src.part;
        if (who == 0) cx.collide(&pt, &pxb, &res) else cx.collide(&pxa, &pt, &res);
        if (res.sep > mg) continue;
        // the tilted one's point: from the other's along n, turned back
        const sn = splat(res.sep) * res.n;
        const pp = if (who == 0) res.pb - sn else res.pa + sn;
        const back = andXyz(rc.mtv3(&q, pp - piv) + piv);
        if (who == 0) res.pa = back else res.pb = back;
        res.sep = dot3(res.pb - res.pa, m.nrm); // its separation along the normal
        if (res.sep > mg) continue;
        cpAdd(m, A, B, &res);
    }
    mfTangents(m);
}

/// ucomiss 0, r; jne: a radius (ordered, not 0) stops the tilting.
inline fn noRad(r: f32) bool {
    return r == 0 or std.math.isNan(r);
}

/// mf_tangents: t1, t2 square to the normal.
pub fn mfTangents(m: *Manifold) void {
    const n = m.nrm;
    var t: V4 = undefined;
    if (!(@abs(n[0]) >= C0577)) {
        t = .{ 0, n[2], -n[1], 0 }; // (0, z, -y)
    } else {
        t = .{ n[1], -n[0], 0, 0 }; // (y, -x, 0)
    }
    const l = rc.maxss(@sqrt(dot3(t, t)), TINY);
    t = andXyz(t / splat(l));
    m.t1 = t;
    m.t2 = andXyz(cross(n, t));
}

/// rot_axis4: rows of the turn by ang about a unit axis.
pub fn rotAxis4(o: *[3]V4, k: V4, ang: f32) void {
    const sc = sincos(ang);
    const s = sc[0];
    const c = sc[1];
    const omc = 1.0 - c;
    const ka: [4]f32 = k;
    for (0..3) |i| {
        o[i] = andXyz(splat(ka[i] * omc) * k + rc.ident[i] * splat(c));
    }
    const xs = k[0] * s;
    const ys = k[1] * s;
    const zs = k[2] * s;
    o[0][1] = o[0][1] - zs;
    o[0][2] = o[0][2] + ys;
    o[1][0] = o[1][0] + zs;
    o[1][2] = o[1][2] - xs;
    o[2][0] = o[2][0] - ys;
    o[2][1] = o[2][1] + xs;
}

/// rows_mul: out = Q R.
pub fn rowsMul(o: *[3]V4, q: *const [3]V4, r: *const [3]V4) void {
    for (0..3) |i| o[i] = andXyz(rc.mtv3(r, q[i]));
}

/// cp_remove: the last into its place.
pub fn cpRemove(m: *Manifold, k: u32) void {
    m.n -= 1;
    if (k != m.n) m.pts[k] = m.pts[m.n];
}

/// cp_add: a contact point replacing one near it (its impulses kept), added,
/// or four kept (cp_reduce).
pub fn cpAdd(m: *Manifold, A: *const Body, B: *const Body, res: *const Hit) void {
    var k: u32 = 0;
    while (k < m.n) : (k += 1) {
        const e = m.pts[k].wa - res.pa;
        if (!(dot3(e, e) > SAME2)) break;
    }
    if (k >= m.n) {
        if (k >= 4) { // full: one goes
            const r = cpReduce(m, res);
            if (r < 0) return;
            k = @intCast(r);
        } else {
            m.n += 1;
            m.pts[k].jn = 0;
            m.pts[k].jt1 = 0;
            m.pts[k].jt2 = 0;
        }
    }
    cpGeom(&m.pts[k], A, B, res);
}

/// cp_geom: a point's anchors, where it is, its gap.
pub fn cpGeom(p: *Contact, A: *const Body, B: *const Body, res: *const Hit) void {
    p.wa = res.pa;
    const ra = res.pa - A.pos;
    p.ra = ra;
    p.la = andXyz(rc.mtv3(&A.r, ra));
    const rb = res.pb - B.pos;
    p.rb = rb;
    p.lb = andXyz(rc.mtv3(&B.r, rb));
    p.sep = res.sep;
}

/// mf_replace: these points instead; each takes the impulses of an old one
/// where it was.
pub fn mfReplace(m: *Manifold, A: *const Body, B: *const Body, res: []const Hit, scratch: *[4]Contact) void {
    for (res, 0..) |*r, i| {
        const p = &scratch[i];
        p.jn = 0;
        p.jt1 = 0;
        p.jt2 = 0;
        for (m.pts[0..m.n]) |*o| { // an old one near it
            const e = o.wa - r.pa;
            if (dot3(e, e) > SAME2) continue;
            p.jn = o.jn;
            p.jt1 = o.jt1;
            p.jt2 = o.jt2;
            break;
        }
        cpGeom(p, A, B, r);
    }
    m.n = @intCast(res.len);
    @memcpy(m.pts[0..res.len], scratch[0..res.len]);
}

const red_tab = [4][3]u8{ .{ 1, 3, 2 }, .{ 0, 3, 2 }, .{ 0, 3, 1 }, .{ 0, 2, 1 } };

/// cp_reduce (a manifold of 4): the point the new one replaces (the deepest
/// stays; the most area left), or -1: the new one is not wanted.
pub fn cpReduce(m: *const Manifold, res: *const Hit) i32 {
    var deep: i32 = -1;
    var best = res.sep;
    for (0..4) |d| {
        const s = m.pts[d].sep;
        if (!(s >= best)) {
            best = s;
            deep = @intCast(d);
        }
    }
    // areas without each: |(p4 - pa) x (pb - pc)|^2
    const p4 = res.pa;
    var area: f32 = 0;
    var r: i32 = -1;
    for (0..4) |d| {
        if (@as(i32, @intCast(d)) == deep) continue;
        const t = red_tab[d];
        const x0 = andXyz(p4 - m.pts[t[0]].wa);
        const x1 = andXyz(m.pts[t[1]].wa - m.pts[t[2]].wa);
        const c = cross(x0, x1);
        const a = dot3(c, c);
        if (a > area) {
            area = a;
            r = @intCast(d);
        }
    }
    return r;
}

// ---- continuous collision --------------------------------------------------------------

/// ccd_mark: each moving body's place at the step's start.
pub fn ccdMark() void {
    for (rc.bd[0..rc.nb]) |*b| {
        if (b.typ != 1) continue;
        b.pp = b.pos;
        b.pq = b.q;
    }
}

/// The pose at t of the step (cc_pose_here / cc_place): position lerped,
/// orientation nlerped.
fn lerpPose(b: *const Body, t: f32, pos: *V4, q: *V4) void {
    const tv = splat(t);
    pos.* = andXyz((b.pos - b.pp) * tv + b.pp);
    const q0 = b.pq;
    var q1 = b.q;
    if (!(rc.dot4(q0, q1) >= 0)) q1 = rc.neg4(q1);
    var x = (q1 - q0) * tv + q0;
    x = x / splat(@sqrt(rc.dot4(x, x)));
    q.* = x;
}

/// ccd_pass: continuous collision for fast bodies: a moving body that went
/// more than half its size this step, against each static part it has a
/// manifold with: put a little short of the first time of impact.
pub fn ccdPass() void {
    var i: u32 = 0;
    while (i < rc.nmf) : (i += 1) {
        const k = &rc.mx[i];
        var mov = &rc.bd[k.a];
        var sta = &rc.bd[k.b];
        var pm = k.pa;
        var ps = k.pb;
        if (mov.typ == 1) {
            if (sta.typ != 2) continue;
        } else {
            if (sta.typ != 1 or mov.typ != 2) continue;
            std.mem.swap(*Body, &mov, &sta);
            std.mem.swap(u32, &pm, &ps);
        }
        if (mov.asleep != 0) continue;
        // fast: moved more than half its smallest half (+ radius)
        const p = &rc.pt[pm];
        var lim = rc.minss(p.half[0], p.half[1]);
        lim = rc.minss(lim, p.half[2]);
        lim += p.rad;
        lim *= 0.5;
        const mv = mov.pos - mov.pp;
        if (!(dot3(mv, mv) > lim * lim)) continue;
        const toi = ccToi(mov, sta, pm, ps);
        if (toi >= 1.0) continue;
        ccPlace(mov, toi);
    }
}

/// cc_toi: the first time (0..1 of the step) the moving part comes within
/// 5 mm of the static one (>= 1: not this step, or touching from the start).
fn ccToi(mov: *const Body, sta: *const Body, pm: u32, ps: u32) f32 {
    var t: f32 = 0;
    var it: u32 = 24;
    var pxa: Proxy = .{};
    var pxb: Proxy = .{};
    var res: Hit = .{};
    while (true) {
        var pos: V4 = undefined;
        var q: V4 = undefined;
        lerpPose(mov, t, &pos, &q);
        var rows: [3]V4 = undefined;
        rc.qRows(q, &rows);
        cx.pxPlace(&pxa, &rows, pos, &rc.pt[pm]);
        cx.pxPlace(&pxb, &sta.r, sta.pos, &rc.pt[ps]);
        cx.collide(&pxa, &pxb, &res);
        const gap = res.sep;
        if (!(gap > CCD_TOL)) {
            if (it == 24) return 2.0; // touching where it began: its contact's
            return t;
        }
        // the most it closes over the step: its move along n + its turn x reach
        var close = @abs(dot3(mov.pos - mov.pp, res.n));
        var ang = @sqrt(dot3(mov.w, mov.w));
        ang *= rc.dt;
        const part = &rc.pt[pm];
        var reach = @sqrt(dot3(part.half, part.half));
        reach += part.rad;
        reach += @sqrt(dot3(part.off, part.off));
        ang *= reach;
        close += ang;
        if (!(close > TINY)) return 2.0; // not closing: no impact
        t = gap / close + t;
        if (t >= 1.0) return 2.0;
        it -= 1;
        if (it == 0) return t;
    }
}

/// cc_place: the body at its pose a little before the impact (its velocity kept).
fn ccPlace(b: *Body, toi: f32) void {
    const t = rc.maxss(toi - CCD_BACK, 0);
    var pos: V4 = undefined;
    var q: V4 = undefined;
    lerpPose(b, t, &pos, &q);
    b.pos = pos;
    b.q = q;
    rc.bodyUpdate(b);
}

test {
    std.testing.refAllDecls(@This());
}

test "the manifolds' hash: put, find, delete" {
    var hs: [16]u32 = @splat(0);
    var mx: [4]rc.Mx = @splat(.{});
    rc.hs = &hs;
    rc.mx = &mx;
    rc.hmask = 15;
    for (0..4) |m| {
        mx[m] = .{ .pa = @intCast(m), .pb = @intCast(m + 7) };
        var s = mfHash(mx[m].pa, mx[m].pb);
        while (hs[s] != 0) s = (s + 1) & 15;
        hs[s] = @intCast(m + 1);
    }
    for (0..4) |m| try std.testing.expectEqual(@as(u32, @intCast(m + 1)), hs[hfSlot(@intCast(m))]);
    hfDelete(hfSlot(1));
    for ([_]u32{ 0, 2, 3 }) |m| try std.testing.expectEqual(m + 1, hs[hfSlot(m)]);
    rc.hs = &.{};
    rc.mx = &.{};
}

test "mf_tangents: square to the normal" {
    var m: Manifold = .{ .nrm = .{ 0, 1, 0, 0 } };
    mfTangents(&m);
    try std.testing.expectEqual(@as(f32, 0), dot3(m.t1, m.nrm));
    try std.testing.expectEqual(@as(f32, 0), dot3(m.t2, m.nrm));
    try std.testing.expectEqual(@as(f32, 0), dot3(m.t1, m.t2));
}

test "mf_update: a box resting on a box has four points; ccd leaves a slow one" {
    var bodies: [2]Body = @splat(.{});
    var parts: [2]Part = .{ .{ .half = .{ 0.5, 0.5, 0.5, 0 } }, .{ .half = .{ 2, 0.5, 2, 0 } } };
    bodies[0] = .{ .pos = .{ 0, 0.99, 0, 0 }, .q = rc.qid, .typ = 1, .p0 = 0, .np = 1 };
    bodies[1] = .{ .pos = .{ 0, 0, 0, 0 }, .q = rc.qid, .typ = 2, .p0 = 1, .np = 1 };
    rc.bd = &bodies;
    rc.pt = &parts;
    rc.nb = 2;
    rc.dt = 1.0 / 120.0;
    for (&bodies) |*b| rc.bodyUpdate(b);
    var m: Manifold = .{ .a = 0, .b = 1, .pa = 0, .pb = 1 };
    mfUpdate(&m);
    try std.testing.expectEqual(@as(u32, 4), m.n);
    for (m.pts[0..4]) |p| try std.testing.expectApproxEqAbs(@as(f32, -0.01), p.sep, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1), m.nrm[1], 1e-6);
    // the same again: refreshed, kept
    mfUpdate(&m);
    try std.testing.expectEqual(@as(u32, 4), m.n);
    var mx: [1]rc.Mx = .{.{ .a = 0, .b = 1, .pa = 0, .pb = 1 }};
    rc.mx = &mx;
    rc.nmf = 1;
    ccdMark();
    ccdPass();
    try std.testing.expectEqual(@as(f32, 0.99), bodies[0].pos[1]);
    rc.bd = &.{};
    rc.pt = &.{};
    rc.mx = &.{};
    rc.nb = 0;
    rc.nmf = 0;
}
