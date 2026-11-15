//! bbool.s: B-rep booleans (union, difference).
//!
//!  1. Both solids are tessellated (for inside / outside), every pair of
//!     faces whose boxes meet is intersected (bssi.zig); faces on the same
//!     plane are paired instead.
//!  2. Each section curve is cut where it crosses either face's boundary:
//!     the crossing is found exactly on the boundary edge (a root of the
//!     distance to the other surface along it) and becomes a vertex that
//!     splits that edge, shared by everything that finds the same point. The
//!     pieces inside both faces become new edges (lines and circles stay
//!     exact, traced curves become polylines on both surfaces).
//!  3. Every face cut by a section, or whose edges were split, is divided:
//!     its boundary pieces (one way round), the section edges in it and a
//!     paired face's edges inside it (both ways) are walked in its (u, v),
//!     turning the sharpest way at each vertex, into cycles; outer cycles
//!     with the holes inside them are its regions.
//!  4. A point inside each region says where it lies: inside or outside the
//!     other solid, or on its paired face facing the same or the other way.
//!     Union keeps A outside B, B outside A and A on B facing the same way;
//!     difference keeps A outside B, A on B facing the other way and B inside
//!     A turned inside out. The kept regions are the result's faces.
//!
//! In the original's order of operations, bit for bit. bk_err says why the
//! last boolean failed (1 .. 9 as the original).
const std = @import("std");
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const bt = @import("btess.zig");
const ss = @import("bssi.zig");
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
const NONE = br.NONE;

pub const OP_UNION: u32 = 0;
pub const OP_DIFF: u32 = 1;
const C_OUT: u32 = 0;
const C_IN: u32 = 1;
const C_SAME: u32 = 2;
const C_OPP: u32 = 3;
const MAXLF = 4096;
const MAXBS = 131072;
const MAXSPL = 65536;
const MAXNV = 65536;
const MAXSPC = 65536;
const MAXCR = 16384;
const MAXEPL = 262144;
const MAXHE = 16384;
const MAXHP = 1048576;
const MAXCY = 4096;
const MAXCL = 32768;

const bo_2pi = nb.nk_2pi;
const bo_pi = nb.nk_pi;
const bo_rweld: f64 = 1.0e-8;
const bo_ron: f64 = 1.0e-7;
const bo_rsec: f64 = 1.0e-7;
const bo_rtess: f64 = 2.0e-4;
const bo_angeps: f64 = 1.0e-10;
const bo_tiny: f64 = 1.0e-14;
const bo_big: f64 = 1.0e300;
const bo_left: f64 = 1.0e-3;

const Bs = struct { u0: f64, v0: f64, u1: f64, v1: f64, t0: f64, t1: f64, e: u32 };
const He = struct { e: u32, rev: u32, v0: u32, v1: u32, used: u32, p: u32, n: u32, ang: f64, rang: f64 };

var bo_a: u32 = 0;
var bo_b: u32 = 0;
var bo_op: u32 = 0;
var bo_fail: bool = false;
/// Why the last boolean failed.
pub var bk_err: u32 = 0;
var bo_size: f64 = 0;
var bo_weld: f64 = 0;
var bo_on: f64 = 0;
// local faces: A's then B's
var lf_n: u32 = 0;
var lf_na: u32 = 0;
var lf_face: [MAXLF]u32 = undefined;
var lf_coin: [MAXLF]u32 = undefined;
var lf_touch: [MAXLF]bool = undefined;
var lf_bs0: [MAXLF]u32 = undefined;
var lf_bsn: [MAXLF]u32 = undefined;
var lf_box: [MAXLF][6]f64 = undefined;
var lf_su: [MAXLF]f64 = undefined;
var lf_sv: [MAXLF]f64 = undefined;
var bs_rec: [MAXBS]Bs = undefined;
var bs_n: u32 = 0;
// splits of edges (heads in aux), new vertices
var spl_t: [MAXSPL]f64 = undefined;
var spl_v: [MAXSPL]u32 = undefined;
var spl_next: [MAXSPL]u32 = undefined;
var spl_n: u32 = 0;
var nv_v: [MAXNV]u32 = undefined;
var nv_n: u32 = 0;
// edges of one solid lying in a face of the other
var ins_e: [4096]u32 = undefined;
var ins_f: [4096]u32 = undefined;
var ins_n: u32 = 0;
// the solids' own vertices
var ov_v: [65536]u32 = undefined;
var ov_n: u32 = 0;
var ov_mark: [*]u8 = undefined;
// section pieces: edge, local face a, local face b
var spc_e: [MAXSPC]u32 = undefined;
var spc_a: [MAXSPC]u32 = undefined;
var spc_b: [MAXSPC]u32 = undefined;
var spc_n: u32 = 0;
// one section's crossings
var cr_pos: [MAXCR]f64 = undefined;
var cr_v: [MAXCR]u32 = undefined;
var cr_n: u32 = 0;
// edge pieces (by edge index)
var ep_first: [*]u32 = undefined;
var ep_cnt: [*]u32 = undefined;
var ep_cap: u32 = 0;
var ep_list: [MAXEPL]u32 = undefined;
var ep_n: u32 = 0;
// a face's arrangement
var he_rec: [MAXHE]He = undefined;
var he_n: u32 = 0;
var hp_pts: [MAXHP][2]f64 = undefined;
var hp_n: u32 = 0;
var cy_first: [MAXCY]u32 = undefined;
var cy_cnt: [MAXCY]u32 = undefined;
var cy_par: [MAXCY]u32 = undefined;
var cy_area: [MAXCY]f64 = undefined;
var cy_list: [MAXCL]u32 = undefined;
var cy_n: u32 = 0;
var cy_ln: u32 = 0;
var af_lf: u32 = 0; // the face being divided
var af_f: u32 = 0;
var af_surf: *nb.Surface = undefined;
var af_su: f64 = 0;
var af_sv: f64 = 0; // (negative for sense 1)
var af_hu: f64 = 0; // inversion hints
var af_hv: f64 = 0;
var er_miss: bool = false;
var sn_p: V3 = undefined;
var sn_vx: u32 = 0;

/// bk_keep (bdebug.s): BEEMODEL_BREP_KEEP set keeps a boolean's result even
/// when it is not a valid solid.
pub fn keep() bool {
    return @import("spawn.zig").getenv("BEEMODEL_BREP_KEEP") != null;
}

// ---- the operation ---------------------------------------------------------------------------
/// bk_bool(A, B, OP_UNION / OP_DIFF) -> the result body, or NONE
pub fn bool_(a: u32, b: u32, op: u32) u32 {
    bo_a = a;
    bo_b = b;
    bo_op = op;
    bo_fail = false;
    bk_err = 0;
    // sizes and tolerances
    const ra = bt.bdSize(a);
    const size = maxsd(bt.bdSize(b), ra);
    bo_size = size;
    bo_weld = size * bo_rweld;
    bo_on = size * bo_ron;
    ss.ss_tol = size * bo_rsec;
    bt.bt_tol = size * bo_rtess;
    bt.bdTess(a);
    bt.bdTess(b);
    ss.reset();
    spl_n = 0;
    nv_n = 0;
    spc_n = 0;
    ins_n = 0;
    ov_n = 0;
    ep_n = 0;
    bs_n = 0;
    boFaces();
    if (bo_fail) return fail(1);
    // pairs: paired planes or sections
    var i: u32 = 0;
    while (i < lf_na) : (i += 1) {
        var j: u32 = lf_na;
        while (j < lf_n) : (j += 1) {
            if (!boxesMeet(i, j)) continue;
            const sa = lfSurf(i);
            const sb = lfSurf(j);
            if (ss.coincide(sa, sb)) {
                if (sa.typ != nb.ST_PLANE) return fail(2); // only planes can be paired
                if (lf_coin[i] != NONE) return fail(3); // (one partner each)
                if (lf_coin[j] != NONE) return fail(4);
                lf_coin[i] = j;
                lf_coin[j] = i;
                lf_touch[i] = true;
                lf_touch[j] = true;
                continue;
            }
            ss.ssi(lf_face[i], lf_face[j]);
        }
    }
    var k: u32 = 0;
    while (k < ss.ss_n) : (k += 1) boSection(k);
    if (bo_fail) return fail(5);
    snapVertices(); // new vertices on existing edges
    boPieces();
    if (bo_fail) return fail(6);
    br.bbBegin();
    i = 0;
    while (i < lf_n) : (i += 1) boFace(i);
    const r = br.bbEnd();
    if (bo_fail) return fail(7);
    if (r == NONE or br.bd(r).nf == 0) return fail(8);
    var f = br.bd(r).first;
    const f1 = f + br.bd(r).nf;
    while (f < f1) : (f += 1) {
        br.fcPcurves(f);
        br.fcBox(f);
    }
    const bad = br.bdCheck(r);
    if (!keep() and bad != 0) return fail(9);
    return r;
}
fn fail(e: u32) u32 {
    bk_err = e;
    return NONE;
}

/// boxes_meet: their boxes overlap
fn boxesMeet(a: u32, b: u32) bool {
    const p = &lf_box[a];
    const q = &lf_box[b];
    for (0..3) |c| {
        if (jb(p[3 + c] + bo_on, q[c])) return false;
        if (jb(q[3 + c] + bo_on, p[c])) return false;
    }
    return true;
}

// ---- faces, their boundaries ----------------------------------------------------------------
/// bo_faces: the local faces: boxes, metric, boundary segments, marks
fn boFaces() void {
    lf_n = 0;
    full: for (0..2) |side| {
        const body = br.bd(if (side == 0) bo_a else bo_b);
        var f = body.first;
        const f1 = f + body.nf;
        while (f < f1) : (f += 1) {
            if (lf_n >= MAXLF) {
                bo_fail = true;
                break :full;
            }
            const l = lf_n;
            lf_face[l] = f;
            lf_coin[l] = NONE;
            lf_touch[l] = false;
            br.fc(f).mark = l; // face -> local index
            lf_box[l] = ss.fcBbox(f);
            boBsegs(l);
            lf_n += 1;
        }
        if (side == 0) lf_na = lf_n;
    }
    edgesReset();
    ownVertices();
}

fn eachCoedge(fi: u32, comptime cb: fn (c: u32) void) void {
    const f = br.fc(fi);
    var l = f.loop;
    const l1 = l + f.nloop;
    while (l < l1) : (l += 1) {
        var c = br.lp(l).first;
        const cend = c + br.lp(l).n;
        while (c < cend) : (c += 1) cb(c);
    }
}

/// own_vertices: every vertex of both solids, once
fn ownVertices() void {
    const n = (br.bk_vx.used >> 5) + 16;
    ov_mark = @ptrCast(nb.data(n) orelse return);
    @memset(ov_mark[0..n], 0);
    var i: u32 = 0;
    while (i < lf_n) : (i += 1) eachCoedge(lf_face[i], ovTake);
}
fn ovTake(c: u32) void {
    const e = br.ed(br.ce(c).edge);
    ovOne(e.v0);
    ovOne(e.v1);
}
fn ovOne(v: u32) void {
    if (ov_mark[v] != 0) return;
    ov_mark[v] = 1;
    if (ov_n >= 65536) return;
    ov_v[ov_n] = v;
    ov_n += 1;
}

/// edges_reset: every edge of both solids: no splits, no pieces yet
fn edgesReset() void {
    ep_cap = @as(u32, @truncate(br.bk_ed.used >> 6)) +% 65536;
    ep_first = @ptrCast(@alignCast(nb.data(@as(usize, ep_cap) * 4) orelse return));
    @memset(ep_first[0..ep_cap], NONE);
    ep_cnt = @ptrCast(@alignCast(nb.data(@as(usize, ep_cap) * 4) orelse return));
    @memset(ep_cnt[0..ep_cap], 0);
    var i: u32 = 0;
    while (i < lf_n) : (i += 1) eachCoedge(lf_face[i], edAuxClear);
}
fn edAuxClear(c: u32) void {
    br.ed(br.ce(c).edge).aux = NONE;
}

/// to_uv(surface, point, guess) -> its (u, v)
fn toUv(s: *const nb.Surface, p: V3, gu: f64, gv: f64) [2]f64 {
    if (s.typ == nb.ST_NURBS) return br.sfProject(s, p, gu, gv);
    const r = br.sfInvert(s, p, gu, gv);
    if (r.pole) return .{ gu, gv }; // (a pole: the guess)
    return .{ r.u, r.v };
}

/// bo_bsegs(local face): its boundary as (u, v) segments with each
/// segment's edge and edge parameters
fn boBsegs(l: u32) void {
    lf_bs0[l] = bs_n;
    const f = br.fc(lf_face[l]);
    const s = br.sf(f.surf);
    // metric scales at the box's middle
    const ev = nb.srfEval(s, (f.u0 + f.u1) * 0.5, (f.v0 + f.v1) * 0.5);
    lf_su[l] = maxsd(nb.v3len(ev[1]), bo_tiny);
    lf_sv[l] = maxsd(nb.v3len(ev[2]), bo_tiny);
    var lp = f.loop;
    const l1 = lp + f.nloop;
    while (lp < l1) : (lp += 1) {
        var c = br.lp(lp).first;
        const cend = c + br.lp(lp).n;
        while (c < cend) : (c += 1) {
            const r = br.ce(c);
            const e = br.ed(r.edge);
            var prev: [2]f64 = undefined;
            var prt: f64 = undefined;
            if (e.flags & br.EF_DEGEN != 0) {
                // a pole: its pcurve (no edge to cut)
                var k: u32 = 0;
                while (k <= 8) : (k += 1) {
                    const t = fl(k) / 8.0;
                    const uv = br.ceUv(c, t);
                    if (k != 0) bsAdd(prev, prt, .{ uv[0], uv[1] }, t, NONE);
                    prev = .{ uv[0], uv[1] };
                    prt = t;
                }
                continue;
            }
            var ts = e.t0;
            var te = e.t1;
            if (r.rev != 0) {
                ts = e.t1;
                te = e.t0;
            }
            const kn = e.npoly;
            var k: u32 = 0;
            while (k < kn) : (k += 1) {
                const idx = if (r.rev != 0) kn - 1 - k else k;
                const q = e.poly.? + idx * 4;
                const t = q[3];
                var sx = t - ts;
                sx = sx / (te - ts);
                const g = br.ceUv(c, sx);
                const uv = toUv(s, .{ q[0], q[1], q[2] }, g[0], g[1]);
                if (k != 0) bsAdd(prev, prt, uv, t, r.edge);
                prev = uv;
                prt = t;
            }
        }
    }
    lf_bsn[l] = bs_n - lf_bs0[l];
}
fn bsAdd(p: [2]f64, pt: f64, q: [2]f64, t: f64, e: u32) void {
    if (bs_n >= MAXBS) return;
    bs_rec[bs_n] = .{ .u0 = p[0], .v0 = p[1], .u1 = q[0], .v1 = q[1], .t0 = pt, .t1 = t, .e = e };
    bs_n += 1;
}

/// uv_inside(local face, u, v): inside its boundary
fn uvInside(l: u32, u: f64, v: f64) bool {
    var in = false;
    var i = lf_bs0[l];
    const end = i + lf_bsn[l];
    while (i < end) : (i += 1) {
        const s = &bs_rec[i];
        if ((s.v0 > v) == (s.v1 > v)) continue;
        var x = v - s.v0;
        x = x * (s.u1 - s.u0);
        x = x / (s.v1 - s.v0);
        x = x + s.u0;
        if (jae(u, x)) continue;
        in = !in;
    }
    return in;
}

/// bdist(local face, u, v) -> the distance (in the face's metric) to its
/// boundary, and the edge of the nearest piece
fn bdist(l: u32, u_in: f64, v_in: f64) struct { d: f64, e: u32 } {
    const su = lf_su[l];
    const sv = lf_sv[l];
    const u = u_in * su;
    const v = v_in * sv;
    var best = bo_big;
    var e: u32 = NONE;
    var i = lf_bs0[l];
    const end = i + lf_bsn[l];
    while (i < end) : (i += 1) {
        const s = &bs_rec[i];
        const ax = s.u0 * su;
        const ay = s.v0 * sv;
        var dx = s.u1 * su - ax;
        var dy = s.v1 * sv - ay;
        var wx = u - ax;
        var wy = v - ay;
        var t = wx * dx;
        t += wy * dy;
        var dd = dx * dx;
        dd += dy * dy;
        var tt: f64 = 0;
        if (!jbe(dd, bo_tiny)) {
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
        if (jae(wx, best)) continue;
        best = wx;
        e = s.e;
    }
    return .{ .d = @sqrt(best), .e = e };
}

// ---- sections --------------------------------------------------------------------------------
fn lfSurf(l: u32) *nb.Surface {
    return br.sf(br.fc(lf_face[l]).surf);
}
fn boxMid(l: u32) [2]f64 {
    const f = br.fc(lf_face[l]);
    return .{ (f.u0 + f.u1) * 0.5, (f.v0 + f.v1) * 0.5 };
}

const SE = struct {
    rec: *ss.Sec,
    pts: [*]ss.Pt,
    n: u32,
    la: u32,
    lb: u32,
    sa: *nb.Surface,
    sb: *nb.Surface,
    k: u32 = 0,
    side: u32 = 0,
    t0: f64 = 0, // the piece
    t1: f64 = 0,
};

fn spAt(se: *const SE, i: u32) *ss.Pt {
    return &se.pts[i % se.n];
}

/// bo_section(section): its crossings with both faces' boundaries, the
/// pieces inside both made edges
fn boSection(si: u32) void {
    const rec = &ss.ss_rec[si];
    var se: SE = .{
        .rec = rec,
        .pts = ss.ss_pts + rec.first,
        .n = rec.n,
        .la = br.fc(rec.fa).mark,
        .lb = br.fc(rec.fb).mark,
        .sa = undefined,
        .sb = undefined,
    };
    se.sa = lfSurf(se.la);
    se.sb = lfSurf(se.lb);
    cr_n = 0;
    // segments k -> k+1 (closed: n - 1 -> 0 too) against both boundaries
    var kn = se.n -% 1;
    if (rec.closed != 0) kn +%= 1;
    se.k = 0;
    while (se.k < kn) : (se.k += 1) {
        se.side = 0;
        while (se.side < 2) : (se.side += 1) seCrossings(&se);
    }
    crSort();
    if (cr_n == 0) {
        // no crossings: a closed loop inside both maybe, cut in two halves
        if (rec.closed == 0) return;
        if (se.n < 4) return;
        cr_v[0] = newVertex(spAt(&se, 0).p);
        cr_pos[0] = 0;
        const h = se.n >> 1;
        cr_v[1] = newVertex(spAt(&se, h).p);
        cr_pos[1] = fl(h);
        cr_n = 2;
    }
    var c: u32 = 0;
    while (true) : (c += 1) {
        var np = cr_n;
        if (rec.closed == 0) np -%= 1; // (open: n - 1 pieces)
        if (c >= np) return;
        const d = (c + 1) % cr_n; // the next crossing
        const p0 = cr_pos[c];
        var p1 = cr_pos[d];
        if (!ja(p1, p0)) p1 = p1 + fl(se.n); // (wraps round a closed loop)
        se.t0 = p0;
        se.t1 = p1;
        const len = p1 - p0;
        if (jbe(len, bo_angeps)) continue; // (no length)
        if (cr_v[c] == cr_v[d] and jb(len, 1.0)) continue; // the same vertex, close: nothing
        const m = sePointAt(&se, (p0 + p1) * 0.5);
        // on a face's boundary: that face's edge goes into the other face (when
        // inside it); off both: a section piece when inside both
        const da = bdist(se.la, m.ua[0], m.ua[1]);
        const db = bdist(se.lb, m.ub[0], m.ub[1]);
        if (jae(bo_on, da.d)) {
            if (jae(bo_on, db.d)) continue; // (on both: nothing)
            if (!uvInside(se.lb, m.ub[0], m.ub[1])) continue;
            insAlong(&se, 0);
            continue;
        }
        if (jae(bo_on, db.d)) {
            // on b's boundary, off a's: b's edges along it into a, when it is inside a
            if (!uvInside(se.la, m.ua[0], m.ua[1])) continue;
            insAlong(&se, 1);
            continue;
        }
        if (!uvInside(se.la, m.ua[0], m.ua[1])) continue;
        if (!uvInside(se.lb, m.ub[0], m.ub[1])) continue;
        const e = seEdge(&se, cr_v[c], cr_v[d], p0, p1);
        if (e == NONE) continue;
        if (spc_n >= MAXSPC) continue;
        spc_e[spc_n] = e;
        spc_a[spc_n] = se.la;
        lf_touch[se.la] = true;
        spc_b[spc_n] = se.lb;
        lf_touch[se.lb] = true;
        spc_n += 1;
    }
}

/// ins_along(0: a's edges into b / 1: b's into a): every boundary edge the
/// piece runs along (nearest to 17 points of it) into the other face
fn insAlong(se: *const SE, which: u32) void {
    var k: u32 = 0;
    while (k <= 16) : (k += 1) {
        var x = fl(k) / 16.0;
        x = x * (se.t1 - se.t0);
        x = x + se.t0;
        const m = sePointAt(se, x);
        const d = if (which != 0) bdist(se.lb, m.ub[0], m.ub[1]) else bdist(se.la, m.ua[0], m.ua[1]);
        if (ja(d.d, bo_on)) continue;
        insAdd(d.e, if (which != 0) se.la else se.lb);
    }
}

/// ins_add(edge (NONE: none), local face): the edge into that face (once)
fn insAdd(e: u32, l: u32) void {
    if (e == NONE) return;
    var i: u32 = 0;
    while (i < ins_n) : (i += 1) {
        if (ins_e[i] == e and ins_f[i] == l) return;
    }
    if (i >= 4096) return;
    ins_e[i] = e;
    ins_f[i] = l;
    ins_n += 1;
    lf_touch[l] = true;
}

/// se_point_at(position k + f): the section interpolated there
fn sePointAt(se: *const SE, pos: f64) ss.Pt {
    const k = nb.cvtt(pos);
    const f = pos - fl(k);
    const g = 1.0 - f;
    const a = spAt(se, @bitCast(k));
    const b = spAt(se, @bitCast(k +% 1));
    var o: ss.Pt = undefined;
    for (0..3) |c| {
        var x = a.p[c] * g;
        x = x + b.p[c] * f;
        o.p[c] = x;
    }
    var h = boxMid(se.la);
    o.ua = toUv(se.sa, o.p, h[0], h[1]);
    h = boxMid(se.lb);
    o.ub = toUv(se.sb, o.p, h[0], h[1]);
    return o;
}

/// se_crossings(segment k, side): its crossings with that face's boundary:
/// exact vertices on the boundary edges
fn seCrossings(se: *const SE) void {
    const a = spAt(se, se.k);
    const b = spAt(se, se.k + 1);
    const l = if (se.side == 0) se.la else se.lb;
    const sso = if (se.side == 0) se.sb else se.sa;
    const ssf = if (se.side == 0) se.sa else se.sb;
    const p = if (se.side == 0) a.ua else a.ub;
    const q = if (se.side == 0) b.ua else b.ub;
    var i = lf_bs0[l];
    const end = i + lf_bsn[l];
    while (i < end) : (i += 1) {
        const s = &bs_rec[i];
        if (s.e == NONE) continue; // (a pole's: nothing to cut)
        // a jump of a turn on a periodic surface is no crossing
        if (ssf.typ != nb.ST_PLANE and ssf.typ != nb.ST_NURBS) {
            if (ja(fabs(q[0] - p[0]), bo_pi)) return;
            if (ja(fabs(q[1] - p[1]), bo_pi)) return;
        }
        // p + lam (q - p) = a + mu (b - a)
        const dx = q[0] - p[0];
        const dy = q[1] - p[1];
        const ex = s.u1 - s.u0;
        const ey = s.v1 - s.v0;
        var den = dx * ey;
        den = den - dy * ex;
        if (jbe(fabs(den), bo_tiny)) continue;
        const wx = s.u0 - p[0];
        const wy = s.v0 - p[1];
        var lam = wx * ey;
        lam = lam - wy * ex;
        lam = lam / den;
        var mu = wx * dy;
        mu = mu - wy * dx;
        mu = mu / den;
        if (jb(lam, 0)) continue;
        if (jae(lam, 1.0)) continue;
        if (jb(mu, 0)) continue;
        if (ja(mu, 1.0)) continue;
        // the exact point on the edge: a root of the distance to the other
        // surface in the segment's t range
        const r = edgeRoot(s.e, s.t0, s.t1, sso, mu);
        if (er_miss) continue;
        // in (or on) the other face? else no piece can end here: no split
        const ol = if (se.side == 0) se.lb else se.la;
        const h = boxMid(ol);
        const uv = toUv(sso, r.p, h[0], h[1]);
        if (!uvInside(ol, uv[0], uv[1])) {
            const d = bdist(ol, uv[0], uv[1]);
            if (ja(d.d, bo_on + bo_on)) continue;
        }
        const v = splitVertex(s.e, r.p, r.t);
        if (cr_n >= MAXCR) continue;
        cr_v[cr_n] = v;
        cr_pos[cr_n] = fl(se.k) + lam;
        cr_n += 1;
    }
}

/// cr_sort: the crossings by position, repeats of one vertex at one place dropped
fn crSort() void {
    var c: u32 = 1;
    while (c < cr_n) : (c += 1) {
        const x = cr_pos[c];
        const v = cr_v[c];
        var d = c;
        while (d != 0 and !jae(x, cr_pos[d - 1])) : (d -= 1) {
            cr_pos[d] = cr_pos[d - 1];
            cr_v[d] = cr_v[d - 1];
        }
        cr_pos[d] = x;
        cr_v[d] = v;
    }
    var w: u32 = 0;
    c = 0;
    while (c < cr_n) : (c += 1) {
        if (w != 0 and cr_v[c] == cr_v[w - 1] and jb(cr_pos[c] - cr_pos[w - 1], 1.0)) continue;
        cr_pos[w] = cr_pos[c];
        cr_v[w] = cr_v[c];
        w += 1;
    }
    cr_n = w;
}

const Root = struct { t: f64, p: V3 };

/// edge_root(edge, t0, t1, surface, guess in 0..1): t where the edge's curve
/// meets the surface, and the point: a bracketed root of the signed distance
/// (Illinois); er_miss when there is no sign change
fn edgeRoot(ei: u32, t0: f64, t1: f64, s: *const nb.Surface, g: f64) Root {
    var a = t0;
    var b = t1;
    var t = (b - a) * g;
    t = t + a;
    const c = br.cv(br.ed(ei).curve);
    er_miss = false;
    var h: [2]f64 = .{ 0, 0 };
    _ = erF(c, s, t, &h); // hint from the guess point
    var fa = erF(c, s, a, &h);
    var fb = erF(c, s, b, &h);
    if (ja(fb * fa, 0)) {
        // no sign change: at most a touch: no crossing here
        er_miss = true;
        t = a;
    } else {
        var side: i32 = 0;
        var it: u32 = 0;
        while (it < 100) : (it += 1) {
            const df = fb - fa;
            if (jbe(fabs(df), bo_tiny)) break;
            var x = b - a;
            x = x * fa;
            x = x / df;
            t = a - x;
            const ft = erF(c, s, t, &h);
            if (jbe(fabs(ft), bo_size * bo_tiny)) break;
            if (!jbe(ft * fa, 0)) {
                a = t; // f same sign as fa
                fa = ft;
                if (side == -1) fb = fb * 0.5; // (Illinois: halve the stuck end)
                side = -1;
            } else {
                b = t;
                fb = ft;
                if (side == 1) fa = fa * 0.5;
                side = 1;
            }
            if (jbe(fabs(b - a), bo_tiny)) break;
        }
    }
    return .{ .t = t, .p = nb.crvEval(c, t)[0] };
}
fn erF(c: *const nb.Curve, s: *const nb.Surface, t: f64, h: *[2]f64) f64 {
    const p = nb.crvEval(c, t)[0];
    const d = ss.sfDist(s, p, h[0], h[1]);
    h.* = d.uv;
    return d.d;
}

/// new_vertex: a vertex there: one of the solids' or this boolean's within
/// the weld distance, or a new one
fn newVertex(p: V3) u32 {
    var i: u32 = 0;
    while (i < ov_n) : (i += 1) {
        if (!ja(nb.v3dist(br.vx(ov_v[i]).p, p), bo_weld)) return ov_v[i];
    }
    i = 0;
    while (i < nv_n) : (i += 1) {
        if (!ja(nb.v3dist(br.vx(nv_v[i]).p, p), bo_weld)) return nv_v[i];
    }
    const v = br.newVx(p);
    if (nv_n < MAXNV) {
        nv_v[nv_n] = v;
        nv_n += 1;
    }
    return v;
}

/// split_vertex(edge, point, t): the vertex there: the edge's own end, a
/// split it already has, or a new split
fn splitVertex(ei: u32, p: V3, t: f64) u32 {
    const e = br.ed(ei);
    if (!ja(nb.v3dist(br.vx(e.v0).p, p), bo_weld)) return e.v0;
    if (!ja(nb.v3dist(br.vx(e.v1).p, p), bo_weld)) return e.v1;
    var s = e.aux;
    while (s != NONE) : (s = spl_next[s]) {
        if (!ja(nb.v3dist(br.vx(spl_v[s]).p, p), bo_weld)) return spl_v[s];
    }
    const v = newVertex(p);
    if (spl_n >= MAXSPL) {
        bo_fail = true;
        return v;
    }
    spl_v[spl_n] = v;
    spl_t[spl_n] = t;
    spl_next[spl_n] = br.ed(ei).aux;
    br.ed(ei).aux = spl_n;
    spl_n += 1;
    return v;
}

/// se_edge(start vertex, end vertex, their positions along the section): a
/// new edge: the exact curve's arc between them, or a polyline through the
/// section's points
fn seEdge(se: *const SE, v0: u32, v1: u32, p0: f64, p1: f64) u32 {
    const cvi = se.rec.curve;
    if (cvi != NONE) {
        const c = br.cv(cvi);
        const t0 = cvParam(c, v0);
        var t1 = cvParam(c, v1);
        if (c.typ == nb.CT_CIRCLE and !ja(t1, t0)) t1 = t1 + bo_2pi; // forwards
        return br.newEd(cvi, v0, v1, t0, t1);
    }
    // points: the start vertex, section points strictly between, the end
    const k0 = nb.cvtt(p0) +% 1;
    var k1 = nb.cvtt(p1);
    if (je(fl(k1), p1)) k1 -%= 1; // (exactly on a point: not inner)
    var cnt = k1 -% k0 +% 1;
    if (cnt < 0) cnt = 0;
    const n: u32 = @intCast(cnt + 2);
    const c = br.nbNewExt(1, n) orelse return NONE;
    const cp = c.cp.?;
    putPt(cp, br.vx(v0).p);
    var i: u32 = 0;
    while (i < n - 2) : (i += 1) putPt(cp + (i + 1) * 4, spAt(se, @as(u32, @bitCast(k0)) +% i).p);
    putPt(cp + (n - 1) * 4, br.vx(v1).p);
    // knots: chord lengths
    const kn = c.kn.?;
    kn[0] = 0;
    kn[1] = 0;
    i = 0;
    while (i + 1 < n) : (i += 1) {
        const a: V3 = .{ cp[i * 4], cp[i * 4 + 1], cp[i * 4 + 2] };
        const b: V3 = .{ cp[i * 4 + 4], cp[i * 4 + 5], cp[i * 4 + 6] };
        kn[i + 2] = nb.v3dist(a, b) + kn[i + 1];
    }
    kn[n + 1] = kn[n];
    return br.newEd(nb.cvIndex(c), v0, v1, 0, kn[n]);
}
fn putPt(d: [*]f64, p: V3) void {
    d[0] = p[0];
    d[1] = p[1];
    d[2] = p[2];
    d[3] = 1.0;
}
/// cv_param(line or circle, vertex): its parameter
fn cvParam(c: *const nb.Curve, v: u32) f64 {
    const d = nb.v3sub(br.vx(v).p, c.o);
    const x = nb.v3dot(d, c.x);
    if (c.typ == nb.CT_LINE) return x;
    return nb.datan2(nb.v3dot(d, c.y), x);
}

/// snap_vertices: every vertex this boolean made that lies on an edge of
/// either solid (inside it, not at its ends) splits that edge
fn snapVertices() void {
    var i: u32 = 0;
    while (i < nv_n + ov_n) : (i += 1) {
        sn_vx = if (i < nv_n) nv_v[i] else ov_v[i - nv_n];
        sn_p = br.vx(sn_vx).p;
        var l: u32 = 0;
        while (l < lf_n) : (l += 1) eachCoedge(lf_face[l], snapOne);
    }
}
fn snapOne(c: u32) void {
    const ei = br.ce(c).edge;
    const e = br.ed(ei);
    if (e.flags & br.EF_DEGEN != 0) return;
    if (sn_vx == e.v0 or sn_vx == e.v1) return; // (its own end)
    if (e.poly == null) return;
    const r = edNearestT(ei);
    if (ja(r[1], bo_on)) return;
    const lo = minsd(e.t0, e.t1);
    const hi = maxsd(e.t0, e.t1);
    if (jbe(r[0], lo)) return;
    if (jae(r[0], hi)) return;
    _ = splitVertex(ei, sn_p, r[0]);
}

/// ed_nearest_t(edge; sn_p) -> the parameter of its curve nearest sn_p, the
/// distance (the polyline's nearest piece, then Newton on the curve)
fn edNearestT(ei: u32) [2]f64 {
    const e = br.ed(ei);
    const c = br.cv(e.curve);
    var best = bo_big;
    var t = e.t0;
    const poly = e.poly.?;
    var i: u32 = 0;
    while (i + 1 < e.npoly) : (i += 1) {
        const a = poly + i * 4;
        const r = segNear(.{ a[0], a[1], a[2] }, .{ a[4], a[5], a[6] });
        if (jae(r[1], best)) continue;
        best = r[1];
        var x = a[7] - a[3];
        x = x * r[0];
        t = x + a[3];
    }
    var k: u32 = 0;
    while (k < 8) : (k += 1) {
        const ev = nb.crvEval(c, t);
        const w = nb.v3sub(ev[0], sn_p);
        const g = nb.v3dot(w, ev[1]);
        const dd = nb.v3dot(ev[1], ev[1]);
        if (jbe(dd, bo_tiny)) break;
        t = t - g / dd;
    }
    return .{ t, nb.v3dist(nb.crvEval(c, t)[0], sn_p) };
}
/// seg_near(a, b; sn_p) -> the fraction along a -> b of the point nearest
/// sn_p, the distance to it
fn segNear(a: V3, b: V3) [2]f64 {
    var dd: f64 = 0;
    var wd: f64 = 0;
    for (0..3) |c| {
        const d = b[c] - a[c];
        var w = sn_p[c] - a[c];
        w = w * d;
        wd += w;
        dd += d * d;
    }
    var f: f64 = 0;
    if (!jbe(dd, bo_tiny)) {
        f = wd / dd;
        f = maxsd(f, 0);
        f = minsd(f, 1.0);
    }
    var s: f64 = 0;
    for (0..3) |c| {
        var x = b[c] - a[c];
        x = x * f;
        x = x + a[c];
        x = x - sn_p[c];
        s += x * x;
    }
    return .{ f, @sqrt(s) };
}

// ---- edge pieces -----------------------------------------------------------------------------
/// bo_pieces: every edge of both solids cut at its splits (sorted along it)
fn boPieces() void {
    var l: u32 = 0;
    while (l < lf_n) : (l += 1) eachCoedge(lf_face[l], edgeCut);
}

var ec_ts: [1024]f64 = undefined;
var ec_tv: [1024]u32 = undefined;
fn edgeCut(c: u32) void {
    const ei = br.ce(c).edge;
    if (ei >= ep_cap) {
        bo_fail = true;
        return;
    }
    if (ep_first[ei] != NONE) return; // (done already)
    ep_first[ei] = ep_n;
    // its splits, sorted along the edge (t0 -> t1)
    var n: u32 = 0;
    var s = br.ed(ei).aux;
    while (s != NONE and n < 1024) : (s = spl_next[s]) {
        ec_ts[n] = spl_t[s];
        ec_tv[n] = spl_v[s];
        n += 1;
    }
    if (n == 0) {
        // no splits: the edge itself
        ep_list[ep_n] = ei;
        ep_n += 1;
        ep_cnt[ei] = 1;
        return;
    }
    const e = br.ed(ei);
    const dir = e.t1 - e.t0;
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        const x = ec_ts[i];
        const v = ec_tv[i];
        var d = i;
        while (d != 0 and !jae((x - ec_ts[d - 1]) * dir, 0)) : (d -= 1) {
            ec_ts[d] = ec_ts[d - 1];
            ec_tv[d] = ec_tv[d - 1];
        }
        ec_ts[d] = x;
        ec_tv[d] = v;
    }
    // pieces: v0 (t0) -> split 1 -> ... -> v1 (t1)
    var pv = e.v0;
    var pt = e.t0;
    var k: u32 = 0;
    while (k <= n) : (k += 1) {
        var v: u32 = undefined;
        var t: f64 = undefined;
        if (k == n) {
            v = br.ed(ei).v1; // the last piece ends at v1
            t = br.ed(ei).t1;
        } else {
            v = ec_tv[k];
            t = ec_ts[k];
        }
        if (v == pv) continue; // (no length: skipped)
        const ne = br.newEd(br.ed(ei).curve, pv, v, pt, t);
        if (ep_n >= MAXEPL) {
            bo_fail = true;
            return;
        }
        ep_list[ep_n] = ne;
        ep_n += 1;
        ep_cnt[ei] += 1;
        pv = v;
        pt = t;
    }
}

// ---- dividing a face -------------------------------------------------------------------------
/// he_add(edge, rev): a half-edge of the face being divided: its points in
/// the face's scaled, oriented (u, v)
fn heAdd(ei: u32, rev: u32) void {
    var i: u32 = 0;
    while (i < he_n) : (i += 1) {
        if (he_rec[i].e == ei and he_rec[i].rev == rev) return; // (already there)
    }
    if (he_n >= MAXHE) {
        bo_fail = true;
        return;
    }
    const h = &he_rec[he_n];
    h.e = ei;
    h.rev = rev;
    h.used = 0;
    h.p = hp_n;
    bt.edTess(ei);
    const e = br.ed(ei);
    h.v0 = if (rev != 0) e.v1 else e.v0;
    h.v1 = if (rev != 0) e.v0 else e.v1;
    const kn = e.npoly;
    var hu = af_hu;
    var hv = af_hv;
    var k: u32 = 0;
    while (k < kn) : (k += 1) {
        const idx = if (rev != 0) kn - 1 - k else k;
        const q = e.poly.? + idx * 4;
        const uv = toUv(af_surf, .{ q[0], q[1], q[2] }, hu, hv);
        hu = uv[0];
        hv = uv[1];
        if (hp_n >= MAXHP) {
            bo_fail = true;
            return;
        }
        hp_pts[hp_n] = .{ uv[0] * af_su, uv[1] * af_sv };
        hp_n += 1;
    }
    h.n = hp_n - h.p;
    heAngles(h);
    he_n += 1;
}

/// he_angles: its first direction and its last reversed
fn heAngles(h: *He) void {
    h.ang = 0;
    h.rang = 0;
    if (h.n < 2) return;
    const p = hp_pts[h.p..];
    h.ang = nb.datan2(p[1][1] - p[0][1], p[1][0] - p[0][0]);
    const l = h.n - 1;
    h.rang = nb.datan2(p[l - 1][1] - p[l][1], p[l - 1][0] - p[l][0]);
}

/// he_left: a point a little to the left of the middle of its first segment
fn heLeft(h: *const He) [2]f64 {
    const p = hp_pts[h.p..];
    var dx = p[1][0] - p[0][0];
    var dy = p[1][1] - p[0][1];
    var x = (p[0][0] + p[1][0]) * 0.5;
    var y = (p[0][1] + p[1][1]) * 0.5;
    dx = dx * bo_left;
    dy = dy * bo_left;
    x = x - dy;
    y = y + dx;
    return .{ x, y };
}

/// bo_face(local face): divided (when touched) and classified; what is kept
/// becomes faces of the result
fn boFace(l: u32) void {
    af_lf = l;
    af_f = lf_face[l];
    const f = br.fc(af_f);
    af_surf = br.sf(f.surf);
    af_su = lf_su[l];
    af_sv = if (f.sense != 0) fneg(lf_sv[l]) else lf_sv[l];
    af_hu = (f.u0 + f.u1) * 0.5;
    af_hv = (f.v0 + f.v1) * 0.5;
    // touched: a section in it, a split edge, or a paired face
    var touched = lf_touch[l];
    if (!touched) {
        cut_any = false;
        eachCoedge(af_f, cutCheck);
        touched = cut_any;
    }
    if (!touched) {
        // untouched: one point decides for the whole face
        br.fcSample(af_f, 24);
        const p = br.fsDeepPoint() orelse return;
        const k = keepRule(classify(p[0], p[1]));
        if (!k[0]) return;
        emitCopy(af_f, k[1]);
        return;
    }
    he_n = 0;
    hp_n = 0;
    eachCoedge(af_f, heBoundary); // the boundary pieces
    var s: u32 = 0;
    while (s < spc_n) : (s += 1) { // the sections in it
        if (spc_a[s] != l and spc_b[s] != l) continue;
        heAdd(spc_e[s], 0);
        heAdd(spc_e[s], 1);
    }
    if (lf_coin[l] != NONE) eachCoedge(lf_face[lf_coin[l]], heInsertedCe); // a paired face's edges inside it
    var i: u32 = 0;
    while (i < ins_n) : (i += 1) { // edges of the other solid along it
        if (ins_f[i] == l) heInserted(ins_e[i]);
    }
    if (bo_fail) return;
    walkCycles();
    nestCycles();
    var c: u32 = 0;
    while (c < cy_n) : (c += 1) { // each outer cycle: a region
        if (jbe(cy_area[c], bo_tiny)) continue;
        regionPoints(c);
        var p = br.fsDeepPoint() orelse continue;
        p[0] = p[0] / af_su; // back to the face's (u, v)
        p[1] = p[1] / af_sv;
        const k = keepRule(classify(p[0], p[1]));
        if (!k[0]) continue;
        emitRegion(c, k[1]);
    }
}

var cut_any = false;
fn cutCheck(c: u32) void {
    const e = br.ce(c).edge;
    if (e >= ep_cap) return;
    if (ep_cnt[e] > 1) cut_any = true;
}

/// he_boundary: its edge's pieces walked its way (a pole: its pcurve)
fn heBoundary(c: u32) void {
    const r = br.ce(c);
    const ei = r.edge;
    const rev = r.rev;
    if (br.ed(ei).flags & br.EF_DEGEN != 0) {
        hePole(c, ei, rev);
        return;
    }
    if (ei >= ep_cap) return;
    const first = ep_first[ei];
    const n = ep_cnt[ei];
    if (rev == 0) {
        var k: u32 = 0;
        while (k < n) : (k += 1) heAdd(ep_list[first + k], 0);
    } else {
        var k = n;
        while (k > 0) {
            k -= 1;
            heAdd(ep_list[first + k], 1);
        }
    }
}

/// he_pole(coedge, edge, rev): a half-edge at a pole: its pcurve's points
fn hePole(c: u32, ei: u32, rev: u32) void {
    if (he_n >= MAXHE) return;
    const h = &he_rec[he_n];
    h.e = ei;
    h.rev = rev;
    h.used = 0;
    h.v0 = br.ed(ei).v0;
    h.v1 = h.v0;
    h.p = hp_n;
    var k: u32 = 0;
    while (k <= 8) : (k += 1) {
        const uv = br.ceUv(c, fl(k) / 8.0);
        if (hp_n >= MAXHP) return;
        hp_pts[hp_n] = .{ uv[0] * af_su, uv[1] * af_sv };
        hp_n += 1;
    }
    h.n = hp_n - h.p;
    heAngles(h);
    he_n += 1;
}

fn heInsertedCe(c: u32) void {
    heInserted(br.ce(c).edge);
}
/// he_inserted(edge of the paired face / of the other solid): its pieces
/// that lie inside the face being divided (off its boundary): both ways
fn heInserted(ei: u32) void {
    if (ei >= ep_cap) return;
    const first = ep_first[ei];
    const n = ep_cnt[ei];
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const pe = ep_list[first + k];
        const m = br.edMid(pe);
        const uv = toUv(af_surf, m, af_hu, af_hv);
        if (!uvInside(af_lf, uv[0], uv[1])) continue;
        if (jbe(bdist(af_lf, uv[0], uv[1]).d, bo_on)) continue;
        heAdd(pe, 0);
        heAdd(pe, 1);
    }
}

/// walk_cycles: every half-edge into one cycle: at each vertex the next is
/// the one turning most sharply (the first clockwise from the way back)
fn walkCycles() void {
    cy_n = 0;
    cy_ln = 0;
    var s: u32 = 0;
    while (s < he_n) : (s += 1) {
        if (he_rec[s].used != 0) continue;
        if (cy_n >= MAXCY) return;
        cy_first[cy_n] = cy_ln;
        var cur = s;
        var len: u32 = 0;
        var best_i: u32 = NONE;
        while (true) {
            const h = &he_rec[cur];
            h.used = 1;
            if (cy_ln >= MAXCL) return;
            cy_list[cy_ln] = cur;
            cy_ln += 1;
            len += 1;
            const last = hp_pts[h.p + h.n - 1]; // where it ends
            const back = h.rang;
            const v = h.v1;
            best_i = NONE;
            var best = bo_big;
            var c: u32 = 0;
            while (c < he_n) : (c += 1) {
                const g = &he_rec[c];
                if (g.v0 != v) continue;
                if (g.used != 0 and c != s) continue; // used: only the cycle's start
                const fp = hp_pts[g.p];
                var d = fabs(fp[0] - last[0]);
                d = d + fabs(fp[1] - last[1]);
                if (ja(d, bo_size * bo_rsec)) continue; // it starts where we are
                var a = back - g.ang; // (back - its angle) mod 2 pi, in (0, 2 pi]
                while (!ja(a, bo_angeps)) {
                    if (a != a) break;
                    a = a + bo_2pi;
                }
                while (!jbe(a, bo_2pi)) a = a - bo_2pi;
                if (jae(a, best)) continue;
                best = a;
                best_i = c;
            }
            if (best_i == NONE or best_i == s) break; // (a dead end / round to the start)
            if (he_rec[best_i].used != 0) break;
            if (len > 4096) break;
            cur = best_i;
        }
        cy_cnt[cy_n] = len;
        var a = cyAreaOf(cy_n);
        if (best_i != s) a = 0; // (not closed: no area, ignored)
        cy_area[cy_n] = a;
        cy_n += 1;
    }
}

fn cyAreaOf(c: u32) f64 {
    var s: f64 = 0;
    var i = cy_first[c];
    const end = i + cy_cnt[c];
    while (i < end) : (i += 1) {
        const h = &he_rec[cy_list[i]];
        var k = h.p;
        var n = h.n -% 1;
        while (n != 0) : (n -= 1) {
            const p = hp_pts[k];
            const q = hp_pts[k + 1];
            var x = p[0] * q[1];
            x = x - q[0] * p[1];
            s += x;
            k += 1;
        }
    }
    return s * 0.5;
}

fn cyInside(c: u32, u: f64, v: f64) bool {
    var in = false;
    var i = cy_first[c];
    const end = i + cy_cnt[c];
    while (i < end) : (i += 1) {
        const h = &he_rec[cy_list[i]];
        var k = h.p;
        var n = h.n -% 1;
        while (n != 0) : (n -= 1) {
            const p = hp_pts[k];
            const q = hp_pts[k + 1];
            k += 1;
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

/// nest_cycles: each hole (negative cycle) in the smallest outer cycle around it
fn nestCycles() void {
    var c: u32 = 0;
    while (c < cy_n) : (c += 1) {
        cy_par[c] = NONE;
        if (jae(cy_area[c], fneg(bo_tiny))) continue;
        // a hole: a point just left of its first segment
        const p = heLeft(&he_rec[cy_list[cy_first[c]]]);
        var best = bo_big;
        var o: u32 = 0;
        while (o < cy_n) : (o += 1) {
            if (jbe(cy_area[o], bo_tiny)) continue;
            if (jae(cy_area[o], best)) continue;
            if (!cyInside(o, p[0], p[1])) continue;
            best = cy_area[o];
            cy_par[c] = o;
        }
    }
}

/// region_points(outer cycle): fs_* hold the region's cycles' points
fn regionPoints(c: u32) void {
    br.fs_nl = 0;
    br.fs_np = 0;
    fsCycle(c);
    var h: u32 = 0;
    while (h < cy_n) : (h += 1) {
        if (cy_par[h] == c) fsCycle(h);
    }
}
fn fsCycle(c: u32) void {
    if (br.fs_nl >= 256) return;
    br.fs_ls[br.fs_nl] = br.fs_np;
    var i = cy_first[c];
    const end = i + cy_cnt[c];
    while (i < end) : (i += 1) {
        const h = &he_rec[cy_list[i]];
        var k = h.p;
        var n = h.n -% 1;
        while (n != 0) : (n -= 1) {
            if (br.fs_np >= 16384) break;
            br.fs_pts[br.fs_np] = hp_pts[k];
            br.fs_np += 1;
            k += 1;
        }
    }
    br.fs_ln[br.fs_nl] = br.fs_np - br.fs_ls[br.fs_nl];
    br.fs_nl += 1;
}

/// classify((u, v) on the face being divided) -> C_OUT, C_IN, C_SAME or
/// C_OPP against the other solid
fn classify(u: f64, v: f64) u32 {
    var pn = br.sfNormal(af_surf, u, v); // P, N (Su x Sv)
    if (br.fc(af_f).sense != 0) pn[1] = nb.v3scale(pn[1], -1.0);
    const o = lf_coin[af_lf];
    if (o != NONE) { // on the paired face?
        const s = lfSurf(o);
        const r = br.sfInvert(s, pn[0], 0, 0);
        if (uvInside(o, r.u, r.v)) {
            var d = nb.v3dot(s.z, pn[1]); // the same way out?
            if (br.fc(lf_face[o]).sense != 0) d = fneg(d);
            return if (ja(d, 0)) C_SAME else C_OPP;
        }
    }
    const other = if (af_lf < lf_na) bo_b else bo_a;
    return if (bt.bdInside(other, pn[0])) C_IN else C_OUT;
}

/// keep_rule(class) -> kept, turned inside out
fn keepRule(cls: u32) [2]bool {
    if (af_lf < lf_na) {
        // A: outside, or on B the same way (union) or the other way (difference)
        if (cls == C_OUT) return .{ true, false };
        const want = if (bo_op == OP_UNION) C_SAME else C_OPP;
        return .{ cls == want, false };
    }
    if (bo_op == OP_UNION) return .{ cls == C_OUT, false }; // union: B outside A
    return .{ cls == C_IN, cls == C_IN }; // difference: B inside A, turned
}

/// emit_copy(face, turned): the face as it is in the result
fn emitCopy(fi: u32, turn: bool) void {
    const src = br.fc(fi).*;
    const nf = br.fbFace(src.surf, af_hu, af_hv);
    if (nf == NONE) return;
    const t: u32 = @intFromBool(turn);
    const f = br.fc(nf);
    f.sense = src.sense ^ t;
    copyBox(f, &src);
    var l = src.loop;
    while (l < src.loop + src.nloop) : (l += 1) {
        _ = br.fbLoop();
        const first = br.lp(l).first;
        const n = br.lp(l).n;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const idx = if (turn) n - 1 - k else k; // turned: walked backwards
            const o = br.ce(first + idx).*;
            const nc = br.fbCe(o.edge, o.rev ^ t);
            if (nc == NONE) continue;
            const c = br.ce(nc);
            c.pc = o.pc; // the same pcurve
            c.p0 = if (turn) o.p1 else o.p0;
            c.p1 = if (turn) o.p0 else o.p1;
        }
    }
}
fn copyBox(to: *br.Face, from: *const br.Face) void {
    to.u0 = from.u0;
    to.u1 = from.u1;
    to.v0 = from.v0;
    to.v1 = from.v1;
    to.src = af_f;
}

/// emit_region(outer cycle, turned): a face of the result: the cycle and its holes
fn emitRegion(c: u32, turn: bool) void {
    const src = br.fc(af_f).*;
    const nf = br.fbFace(src.surf, af_hu, af_hv);
    if (nf == NONE) return;
    const f = br.fc(nf);
    f.sense = src.sense ^ @as(u32, @intFromBool(turn));
    copyBox(f, &src);
    emitCycle(c, turn);
    var h: u32 = 0;
    while (h < cy_n) : (h += 1) {
        if (cy_par[h] == c) emitCycle(h, turn);
    }
}
fn emitCycle(c: u32, turn: bool) void {
    const first = cy_first[c];
    const n = cy_cnt[c];
    _ = br.fbLoop();
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const idx = if (turn) n - 1 - k else k;
        const h = &he_rec[cy_list[first + idx]];
        _ = br.fbCe(h.e, h.rev ^ @as(u32, @intFromBool(turn)));
    }
}

fn testBox(x0: f64, y0: f64, w: f64, w0: f64, w1: f64) u32 {
    const bb = @import("bbuild.zig");
    const fr = [4]V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    bb.bmSet(&fr);
    const c = [4][2]f64{ .{ x0, y0 }, .{ x0 + w, y0 }, .{ x0 + w, y0 + w }, .{ x0, y0 + w } };
    var els: [4]bb.El = undefined;
    for (0..4) |k| els[k] = .{ .typ = bb.E_LINE, .a = c[k], .b = c[(k + 1) % 4] };
    bb.bpCustom(&els, 4);
    return bb.bpPrism(w0, w1);
}

test "two overlapping boxes: union and difference, valid, exact volumes" {
    br.reset();
    ss.reset();
    var a = testBox(0, 0, 2, 0, 1);
    var b = testBox(1, 1, 2, 0.5, 1.5);
    const u = bool_(a, b, OP_UNION);
    try std.testing.expect(u != NONE);
    try std.testing.expectApproxEqRel(@as(f64, 7.5), br.bdVolume(u), 1e-12);
    try std.testing.expectEqual(@as(u32, 0), br.bdCheck(u));
    a = testBox(0, 0, 2, 0, 1);
    b = testBox(1, 1, 2, 0.5, 1.5);
    const d = bool_(a, b, OP_DIFF);
    try std.testing.expect(d != NONE);
    try std.testing.expectApproxEqRel(@as(f64, 3.5), br.bdVolume(d), 1e-12);
    try std.testing.expectEqual(@as(u32, 0), br.bdCheck(d));
    bt.bt_tol = 0;
    bt.bdTess(d);
    try std.testing.expect(br.bd(d).tri != null);
}

test "bbool compiles" {
    std.testing.refAllDecls(@This());
}
