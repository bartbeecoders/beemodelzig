//! btess.s: watertight triangles for display and tests. Every edge is
//! sampled once (adaptively: chord height and angle), so the two faces of an
//! edge share its points and the result has no cracks. Each face is
//! triangulated in its (u, v), scaled by the surface's metric there: its
//! loops (holes bridged into the outer one) are ear-clipped (proftri.zig),
//! then made Delaunay by edge flips that never cross a boundary; doubly
//! curved faces (spheres, tori, NURBS) and cylinders and cones get points
//! inside at the sampling step, each inserted with flips. bdInside answers
//! whether a point lies inside a tessellated body (ray parity, three
//! directions voting). The same triangles as the original, vertex for vertex.
const std = @import("std");
const linux = std.os.linux;
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const pt = @import("proftri.zig");
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

/// A body's triangles (BD_TRI).
pub const Tess = extern struct {
    nv: u32,
    nt: u32,
    pv: [*]f64, // 3 doubles per vertex
    pt: [*]u32, // 3 u32 per triangle
    _pad: u64,
};

const MAXEP = 4096; // points of an edge
const MAXCP = 32768; // a face's points
const MAXCT = 65536; // a face's triangles
const PF_MAXP = 8192;
const PF_MAXL = 128;

const bt_step: f64 = 0.2617993877991494; // 15 degrees
const bt_fine: f64 = 0.17453292519943295; // 10 degrees
const bt_tiny: f64 = 1.0e-12;
const bt_big: f64 = 1.0e300;
const bt_rel: f64 = 2.0e-4; // chord height (of the size)
const bt_keep: f64 = 0.45; // inner points this far in
const bt_200: f64 = 0.005;
const bt_dirs = [3]V3{ .{ 0.5773, 0.5774, 0.5776 }, .{ -0.6247, 0.4342, 0.6489 }, .{ 0.2117, -0.8731, 0.4392 } };

/// The chord height (set from the body's size when 0).
pub var bt_tol: f64 = 0;

// the body's vertices (3 doubles) and triangles (3 u32): 1 GB reserved each
var bt_va: [*]f64 = undefined;
var bt_ta: [*]u32 = undefined;
var bt_nv: u32 = 0;
var bt_nt: u32 = 0;
var bt_ready = false;
var bt_vmap: [*]u32 = undefined; // B-rep vertex -> tessellation vertex
const BT_CAP = 0x40000000;
const BT_LIM = 0x3ff00000;

// edge sampling
var es_t: [MAXEP]f64 = undefined;
var es_p: [MAXEP]V3 = undefined;
var es_n: u32 = 0;
// a face
var ft_surf: *nb.Surface = undefined;
var ft_sense: u32 = 0;
var ft_curved: bool = false;
var ft_su: f64 = 0; // metric scales (u, v)
var ft_sv: f64 = 0;
var ft_uv: [MAXCP][2]f64 = undefined; // true (u, v) per point
var ft_mv: [MAXCP]u32 = undefined; // tessellation vertex per point
var ft_nxt: [MAXCP]u32 = undefined; // the next boundary point (-1 inner)
var ct_p: [MAXCP][2]f64 = undefined; // scaled (u, v)
var ct_np: u32 = 0;
var ct_v: [MAXCT][3]u32 = undefined;
var ct_n: [MAXCT][3]u32 = undefined;
var ct_nt: u32 = 0;
var ct_stk: [MAXCT][2]u32 = undefined; // (triangle, edge) to check
var ct_ns: u32 = 0;
var ct_last: u32 = 0;
var ct_hash: [*][2]u64 = undefined; // adjacency table (key; value, pad)
var ct_hcap: u32 = 0;

fn reserve(bytes: usize) ?usize {
    const rc = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return rc;
}

fn btInit() void {
    if (bt_ready) return;
    bt_va = @ptrFromInt(reserve(BT_CAP) orelse return);
    bt_ta = @ptrFromInt(reserve(BT_CAP) orelse return);
    bt_ready = true;
}

/// tv_add: a new tessellation vertex (0 when full, as the original)
fn tvAdd(p: V3) u32 {
    const i = bt_nv;
    if (@as(u64, i) * 24 >= BT_LIM) return 0;
    bt_va[i * 3] = p[0];
    bt_va[i * 3 + 1] = p[1];
    bt_va[i * 3 + 2] = p[2];
    bt_nv += 1;
    return i;
}

/// tt_add: a triangle
fn ttAdd(a: u32, b: u32, c: u32) void {
    const i = bt_nt;
    if (@as(u64, i) * 12 >= BT_LIM) return;
    bt_ta[i * 3] = a;
    bt_ta[i * 3 + 1] = b;
    bt_ta[i * 3 + 2] = c;
    bt_nt += 1;
}

/// vmap: a B-rep vertex's tessellation vertex (made once)
fn vmap(v: u32) u32 {
    if (bt_vmap[v] != NONE) return bt_vmap[v];
    const i = tvAdd(br.vx(v).p);
    bt_vmap[v] = i;
    return i;
}

// ---- edges ---------------------------------------------------------------------------------
fn esPush(c: *const nb.Curve, t: f64) void {
    if (es_n >= MAXEP) return;
    es_t[es_n] = t;
    es_p[es_n] = nb.crvEval(c, t)[0];
    es_n += 1;
}

/// ed_tess(edge): its polyline (poly: x y z t per point), made once
pub fn edTess(ei: u32) void {
    const e = br.ed(ei);
    if (e.poly != null) return;
    es_n = 0;
    if (e.flags & br.EF_DEGEN != 0) {
        es_p[0] = br.vx(e.v0).p;
        es_t[0] = 0;
        es_n = 1;
    } else {
        const c = br.cv(e.curve);
        if (c.typ == nb.CT_NURBS and c.deg == 1) {
            // a polyline: its own points between t0 and t1 (knots 1 .. N), in order
            esPush(c, e.t0);
            var i: i32 = 1;
            var step: i32 = 1;
            if (!jae(e.t1, e.t0)) {
                i = @intCast(c.n);
                step = -1;
            }
            const n: i32 = @intCast(c.n);
            while (i >= 1 and i <= n) : (i += step) {
                const x = c.kn.?[@intCast(i)];
                const lo = minsd(e.t0, e.t1);
                const hi = maxsd(e.t0, e.t1);
                if (jbe(x, lo)) continue;
                if (jae(x, hi)) continue;
                esPush(c, x);
            }
            esPush(c, e.t1);
        } else {
            // first pieces: lines 1; conics every 15 degrees; other NURBS 4 per knot span
            var n: u32 = 1;
            if (c.typ == nb.CT_NURBS) {
                const k: i32 = (@as(i32, @bitCast(c.n)) -% @as(i32, @bitCast(c.deg))) << 2;
                n = if (k >= 1) @intCast(k) else 1;
            } else if (c.typ != nb.CT_LINE) {
                n = @bitCast(nb.cvtt(fabs(e.t1 - e.t0) / bt_step) +% 1);
            }
            if (n > MAXEP / 4) n = MAXEP / 4;
            var i: u32 = 0;
            while (i <= n) : (i += 1) {
                var t = fl(i) / fl(n);
                t = t * (e.t1 - e.t0);
                t = t + e.t0;
                esPush(c, t);
            }
            // refine: a piece whose middle is off its chord by more than the
            // tolerance is split
            var k: u32 = 0;
            while (k < es_n -% 1 and es_n < MAXEP - 1 and c.typ != nb.CT_LINE) {
                const t = (es_t[k] + es_t[k + 1]) * 0.5;
                const m = nb.crvEval(c, t)[0];
                var d: f64 = 0;
                for (0..3) |q| {
                    var x = (es_p[k][q] + es_p[k + 1][q]) * 0.5;
                    x = x - m[q];
                    d += x * x;
                }
                d = @sqrt(d);
                if (jbe(d, bt_tol)) {
                    k += 1;
                    continue;
                }
                // insert after k: move the rest up one
                var j = es_n;
                while (j > k + 1) : (j -= 1) {
                    es_t[j] = es_t[j - 1];
                    es_p[j] = es_p[j - 1];
                }
                es_t[k + 1] = t;
                es_p[k + 1] = m;
                es_n += 1;
            }
        }
    }
    // the ends are the vertices exactly
    es_p[0] = br.vx(e.v0).p;
    es_p[es_n - 1] = br.vx(e.v1).p;
    const poly = nb.doubles(@as(usize, es_n) * 4) orelse return;
    e.poly = poly;
    e.npoly = es_n;
    for (0..es_n) |i| {
        poly[i * 4] = es_p[i][0];
        poly[i * 4 + 1] = es_p[i][1];
        poly[i * 4 + 2] = es_p[i][2];
        poly[i * 4 + 3] = es_t[i];
    }
}

// ---- the triangulation of one face (in scaled (u, v)) --------------------------------
inline fn orient(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    var x = b[0] - a[0];
    x = x * (c[1] - a[1]);
    var y = b[1] - a[1];
    y = y * (c[0] - a[0]);
    return x - y;
}
inline fn next3(i: u32) u32 {
    return if (i + 1 < 3) i + 1 else 0;
}
fn tnRepoint(t: u32, from: u32, to: u32) void {
    if (@as(i32, @bitCast(t)) < 0) return;
    const n = &ct_n[t];
    if (n[0] == from) {
        n[0] = to;
    } else if (n[1] == from) {
        n[1] = to;
    } else if (n[2] == from) n[2] = to;
}
/// con_edge: a-b is a boundary edge
inline fn conEdge(a: u32, b: u32) bool {
    return ft_nxt[a] == b or ft_nxt[b] == a;
}

/// ct_adjacency: neighbours from matching edges (an open-addressing table)
fn ctAdjacency() void {
    const want = ct_nt * 3 * 4;
    var cap: u32 = 64;
    while (cap < want) cap <<= 1;
    ct_hcap = cap;
    const mem = nb.data(@as(usize, cap) * 16) orelse return;
    ct_hash = @ptrCast(mem);
    @memset(@as([*]u64, @ptrCast(mem))[0 .. @as(usize, cap) * 2], 0xffffffffffffffff);
    var t: u32 = 0;
    while (t < ct_nt) : (t += 1) {
        for (0..3) |e| {
            ct_n[t][e] = NONE;
            const key = edgeKey(t, @intCast(e));
            const s = hSlot(key);
            s[0] = key;
            s[1] = (s[1] & 0xffffffff00000000) | (t * 3 + @as(u32, @intCast(e)));
        }
    }
    t = 0;
    while (t < ct_nt) : (t += 1) {
        for (0..3) |e| {
            const k = std.math.rotl(u64, edgeKey(t, @intCast(e)), 32);
            const s = hSlot(k);
            if (s[0] != k) continue;
            ct_n[t][e] = @as(u32, @truncate(s[1])) / 3;
        }
    }
}
fn edgeKey(t: u32, e: u32) u64 {
    return (@as(u64, ct_v[t][e]) << 32) | ct_v[t][next3(e)];
}
fn hSlot(key: u64) *[2]u64 {
    var i: u32 = @truncate((key *% 0x9e3779b97f4a7c15) >> 32);
    const m = ct_hcap - 1;
    i &= m;
    while (true) {
        const s = &ct_hash[i];
        if (s[0] == 0xffffffffffffffff or s[0] == key) return s;
        i = (i + 1) & m;
    }
}

/// ct_flip(triangle, edge): the edge flipped (to be Delaunay); the outer
/// edges go on the stack
fn ctFlip(t: u32, i: u32) bool {
    const n = ct_n[t][i];
    if (@as(i32, @bitCast(n)) < 0) return false;
    const a = ct_v[t][i];
    const ia = next3(i);
    const b = ct_v[t][ia];
    const ib = next3(ia);
    const c = ct_v[t][ib];
    if (conEdge(a, b)) return false; // a boundary edge stays
    const A1 = ct_n[t][ia];
    const A2 = ct_n[t][ib];
    var j: u32 = 0;
    while (j < 3) : (j += 1) {
        if (ct_v[n][j] == b) break;
    }
    if (j >= 3) return false;
    const ja1 = next3(j);
    if (ct_v[n][ja1] != a) return false;
    const jb2 = next3(ja1);
    const d = ct_v[n][jb2];
    const B1 = ct_n[n][ja1];
    const B2 = ct_n[n][jb2];
    // convex: (c, a, d) and (d, b, c) both counter-clockwise
    if (jbe(orient(ct_p[c], ct_p[a], ct_p[d]), bt_tiny)) return false;
    if (jbe(orient(ct_p[d], ct_p[b], ct_p[c]), bt_tiny)) return false;
    // d inside the circle through a, b, c?
    if (jbe(incircle(ct_p[a], ct_p[b], ct_p[c], ct_p[d]), 0)) return false;
    ct_v[t] = .{ c, a, d };
    ct_n[t] = .{ A2, B1, n };
    ct_v[n] = .{ d, b, c };
    ct_n[n] = .{ B2, A1, t };
    tnRepoint(A1, t, n); // A1 now borders n, B1 borders t
    tnRepoint(B1, n, t);
    ctPush(t, 1); // check t's (a, d) and n's (d, b)
    ctPush(n, 0);
    ctPush(t, 0); // (and their other outer edges)
    ctPush(n, 1);
    return true;
}

/// incircle: > 0 when d is inside the circle of the counter-clockwise a, b, c
fn incircle(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) f64 {
    const ax = a[0] - d[0];
    const ay = a[1] - d[1];
    const bx = b[0] - d[0];
    const by = b[1] - d[1];
    const cx = c[0] - d[0];
    const cy = c[1] - d[1];
    var r = bx * cy - cx * by;
    r = r * (ax * ax + ay * ay);
    var s = cx * ay - ax * cy;
    s = s * (bx * bx + by * by);
    r = r + s;
    var q = ax * by - bx * ay;
    q = q * (cx * cx + cy * cy);
    return r + q;
}

fn ctPush(t: u32, e: u32) void {
    if (ct_ns >= MAXCT) return;
    ct_stk[ct_ns] = .{ t, e };
    ct_ns += 1;
}

/// ct_legalize: flip until the stack is empty (bounded)
fn ctLegalize() void {
    var k: u32 = 0;
    while (ct_ns != 0) {
        k += 1;
        if (k > 4 * MAXCT) {
            ct_ns = 0;
            return;
        }
        ct_ns -= 1;
        const s = ct_stk[ct_ns];
        _ = ctFlip(s[0], s[1]);
    }
}

/// ct_delaunay: every edge checked (and flipped while that helps)
fn ctDelaunay() void {
    ct_ns = 0;
    var t: u32 = 0;
    while (t < ct_nt) : (t += 1) {
        ctPush(t, 0);
        ctPush(t, 1);
        ctPush(t, 2);
    }
    ctLegalize();
}

/// ct_locate: the triangle holding a point, or -1 (a walk, then every triangle)
fn ctLocate(p: [2]f64) u32 {
    var t = ct_last;
    if (t >= ct_nt) t = 0;
    var steps: u32 = 0;
    walk: while (true) {
        steps += 1;
        if (steps > 4096) break :walk;
        const v = ct_v[t];
        var e: u32 = undefined;
        if (!jae(orient(ct_p[v[0]], ct_p[v[1]], p), 0)) {
            e = 0;
        } else if (!jae(orient(ct_p[v[1]], ct_p[v[2]], p), 0)) {
            e = 1;
        } else if (!jae(orient(ct_p[v[2]], ct_p[v[0]], p), 0)) {
            e = 2;
        } else {
            ct_last = t;
            return t;
        }
        const n = ct_n[t][e];
        if (@as(i32, @bitCast(n)) < 0) break :walk;
        t = n;
    }
    t = 0;
    while (t < ct_nt) : (t += 1) {
        const v = ct_v[t];
        if (jb(orient(ct_p[v[0]], ct_p[v[1]], p), 0)) continue;
        if (jb(orient(ct_p[v[1]], ct_p[v[2]], p), 0)) continue;
        if (!jae(orient(ct_p[v[2]], ct_p[v[0]], p), 0)) continue;
        ct_last = t;
        return t;
    }
    return NONE;
}

/// ct_insert(point): split the triangle holding it in three, then flips
fn ctInsert(p: u32) void {
    const t = ctLocate(ct_p[p]);
    if (@as(i32, @bitCast(t)) < 0) return;
    if (ct_nt + 2 > MAXCT) return;
    const t1 = ct_nt;
    const t2 = t1 + 1;
    ct_nt += 2;
    const a = ct_v[t][0];
    const b = ct_v[t][1];
    const c = ct_v[t][2];
    const nbc = ct_n[t][1];
    const nca = ct_n[t][2];
    ct_v[t][2] = p;
    ct_n[t][1] = t1;
    ct_n[t][2] = t2;
    ct_v[t1] = .{ b, c, p };
    ct_n[t1] = .{ nbc, t2, t };
    ct_v[t2] = .{ c, a, p };
    ct_n[t2] = .{ nca, t, t1 };
    tnRepoint(nbc, t, t1); // the old neighbours point at t1, t2
    tnRepoint(nca, t, t2);
    ct_ns = 0;
    ctPush(t, 0);
    ctPush(t1, 0);
    ctPush(t2, 0);
    ctLegalize();
}

// ---- faces ---------------------------------------------------------------------------------
/// fp_add(u, v (true), tessellation vertex) -> a face point (scaled into ct_p), or -1 when full
fn fpAdd(u: f64, v: f64, mv: u32) u32 {
    const i = ct_np;
    if (i >= MAXCP) return NONE;
    ft_uv[i] = .{ u, v };
    ct_p[i] = .{ u * ft_su, v * ft_sv };
    ft_mv[i] = mv;
    ft_nxt[i] = NONE;
    ct_np += 1;
    return i;
}

/// fc_tess(face): its triangles into the body's
fn fcTess(fi: u32) void {
    const f = br.fc(fi);
    ft_sense = f.sense;
    ft_surf = br.sf(f.surf);
    ft_curved = ft_surf.typ != nb.ST_PLANE;
    // metric scales at the box's middle: |Su|, |Sv| (v negated for sense 1)
    const ev = nb.srfEval(ft_surf, (f.u0 + f.u1) * 0.5, (f.v0 + f.v1) * 0.5);
    ft_su = maxsd(nb.v3len(ev[1]), bt_tiny);
    var sv = maxsd(nb.v3len(ev[2]), bt_tiny);
    if (ft_sense != 0) sv = fneg(sv);
    ft_sv = sv;
    // the loops' points
    ct_np = 0;
    pt.pf_nl = 0;
    var l = f.loop;
    const l1 = l + f.nloop;
    while (l < l1) : (l += 1) {
        if (pt.pf_nl >= PF_MAXL) break;
        const ls = ct_np;
        var c = br.lp(l).first;
        const cend = c + br.lp(l).n;
        while (c < cend) : (c += 1) {
            const r = br.ce(c);
            const rev = r.rev;
            const e = br.ed(r.edge);
            if (e.flags & br.EF_DEGEN != 0) {
                // a pole: its pcurve sampled, every point the pole
                const mv = vmap(e.v0);
                var k: u32 = 0;
                while (k < 8) : (k += 1) {
                    const uv = br.ceUv(c, fl(k) / 8.0);
                    _ = fpAdd(uv[0], uv[1], mv);
                }
                continue;
            }
            var ts = e.t0;
            var te = e.t1;
            if (rev != 0) {
                ts = e.t1;
                te = e.t0;
            }
            const kn = e.npoly -% 1; // points 0 .. n - 2 in walking order
            var k: u32 = 0;
            while (k < kn) : (k += 1) {
                const np = if (rev != 0) e.npoly - 1 - k else k;
                // its tessellation vertex: the edge's ends are vertices
                var mv: u32 = undefined;
                if (np == 0) {
                    mv = vmap(e.v0);
                } else if (np == e.npoly - 1) {
                    mv = vmap(e.v1);
                } else mv = edgeInner(e, np);
                // (u, v): the pcurve's guess, refined on the surface
                const q = e.poly.? + np * 4;
                const P: V3 = .{ q[0], q[1], q[2] };
                var s = q[3] - ts;
                s = s / (te - ts);
                const g = br.ceUv(c, s);
                var u = g[0];
                var v = g[1];
                if (ft_surf.typ == nb.ST_NURBS) {
                    const r2 = br.sfProject(ft_surf, P, u, v);
                    u = r2[0];
                    v = r2[1];
                } else if (ft_surf.typ == nb.ST_PLANE) {
                    const r2 = br.sfInvert(ft_surf, P, u, v);
                    u = r2.u;
                    v = r2.v;
                } else {
                    const r2 = br.sfInvert(ft_surf, P, u, v);
                    if (!r2.pole) {
                        u = r2.u;
                        v = r2.v;
                    }
                }
                _ = fpAdd(u, v, mv);
            }
        }
        // the loop for proftri: its points, next links
        const nl = pt.pf_nl;
        pt.pf_ls[nl] = ls;
        const n = ct_np - ls;
        pt.pf_ln[nl] = n;
        pt.pf_par[nl] = -1;
        pt.pf_dep[nl] = 0;
        if (nl != 0) {
            pt.pf_par[nl] = 0;
            pt.pf_dep[nl] = 1;
        }
        var i: u32 = 0;
        while (i < n) : (i += 1) ft_nxt[ls + i] = ls + (if (i + 1 < n) i + 1 else 0);
        pt.pf_nl += 1;
    }
    if (ct_np < 3 or ct_np > PF_MAXP) return;
    // proftri's points: the scaled (u, v); its scale for tolerances
    pt.pf_np = ct_np;
    @memcpy(pt.pf_pt[0..ct_np], ct_p[0..ct_np]);
    var sc: f64 = 0;
    var i: u32 = ct_np * 2;
    while (i > 0) {
        i -= 1;
        sc = maxsd(sc, fabs(ct_p[i >> 1][i & 1]));
    }
    pt.pf_scale = maxsd(sc, bt_tiny);
    pt.merge(0);
    pt.earclip();
    var nt = pt.pf_ntri;
    if (nt > MAXCT / 2) nt = MAXCT / 2;
    ct_nt = nt;
    @memcpy(ct_v[0..nt], pt.pf_tri[0..nt]);
    ct_last = 0;
    ctAdjacency();
    ctDelaunay();
    if (ft_curved) innerPoints(f);
    var t: u32 = 0;
    while (t < ct_nt) : (t += 1) {
        const a = ft_mv[ct_v[t][0]];
        const b = ft_mv[ct_v[t][1]];
        const c = ft_mv[ct_v[t][2]];
        if (a == b or b == c or a == c) continue; // (collapsed at a pole: dropped)
        ttAdd(a, b, c);
    }
}

/// edge_inner(point index (1 .. n-2)): its tessellation vertex (the edge's
/// inner points are made together)
fn edgeInner(e: *br.Edge, np: u32) u32 {
    if (e.aux == NONE) {
        e.aux = bt_nv;
        var k: u32 = 1;
        while (k < e.npoly -% 1) : (k += 1) {
            const q = e.poly.? + k * 4;
            _ = tvAdd(.{ q[0], q[1], q[2] });
        }
    }
    return e.aux +% np -% 1;
}

/// inner_points: a grid inside a curved face at the sampling step, points
/// well inside its loops inserted
fn innerPoints(f: *const br.Face) void {
    // steps: 10 degrees on angles; NURBS: the box in 16
    var du = bt_fine;
    var dv = du;
    const typ = ft_surf.typ;
    if (typ == nb.ST_CYL or typ == nb.ST_CONE) {
        // cylinders, cones: v (a length) at the step the angle makes on the surface
        dv = du * ft_su;
        dv = dv / fabs(ft_sv);
    } else if (typ == nb.ST_NURBS) {
        du = (f.u1 - f.u0) / 16.0;
        dv = (f.v1 - f.v0) / 16.0;
    }
    // at most 200 steps each way
    du = maxsd(du, (f.u1 - f.u0) * bt_200);
    dv = maxsd(dv, (f.v1 - f.v0) * bt_200);
    du = maxsd(du, bt_tiny);
    dv = maxsd(dv, bt_tiny);
    // keep away from the boundary: 0.45 step in the scaled metric
    var keep = minsd(fabs(du * ft_su), fabs(dv * ft_sv));
    keep = keep * bt_keep;
    keep = keep * keep;
    const nbp = ct_np; // boundary points: 0 .. nbp - 1
    var u = f.u0 + du;
    while (true) : (u = u + du) {
        if (jae(u, f.u1) or u != u or f.u1 != f.u1) return;
        var v = f.v0 + dv;
        while (true) : (v = v + dv) {
            if (v != v or f.v1 != f.v1) return;
            if (jae(v, f.v1)) break;
            const su = u * ft_su;
            const sv = v * ft_sv;
            if (!inLoops(su, sv)) continue;
            var far = true;
            var k: u32 = 0;
            while (k < nbp) : (k += 1) {
                var x = ct_p[k][0] - su;
                x = x * x;
                var y = ct_p[k][1] - sv;
                y = y * y;
                if (jb(x + y, keep)) {
                    far = false;
                    break;
                }
            }
            if (!far) continue;
            const P = nb.srfEval(ft_surf, u, v)[0];
            const mv = tvAdd(P);
            const p = fpAdd(u, v, mv);
            if (p == NONE) return;
            ctInsert(p);
        }
    }
}

/// in_loops(u, v scaled; proftri's loops): inside (even-odd)
fn inLoops(u: f64, v: f64) bool {
    var in = false;
    var l: u32 = 0;
    while (l < pt.pf_nl) : (l += 1) {
        const s = pt.pf_ls[l];
        const n = pt.pf_ln[l];
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const a = pt.pf_pt[s + i];
            const b = pt.pf_pt[s + (if (i + 1 < n) i + 1 else 0)];
            if ((a[1] > v) == (b[1] > v)) continue;
            var x = v - a[1];
            x = x * (b[0] - a[0]);
            x = x / (b[1] - a[1]);
            x = x + a[0];
            if (jae(u, x)) continue;
            in = !in;
        }
    }
    return in;
}

// ---- bodies --------------------------------------------------------------------------------
/// bd_tess(body): its triangles (tri), at chord height bt_tol (set from its
/// size when 0)
pub fn bdTess(b: u32) void {
    btInit();
    if (!bt_ready) return;
    bt_nv = 0;
    bt_nt = 0;
    // vertex map: -1 for every vertex
    const vm = nb.data((br.bk_vx.used >> 3) + 16) orelse return;
    bt_vmap = @ptrCast(vm);
    @memset(bt_vmap[0 .. (br.bk_vx.used >> 5) + 1], NONE);
    // the tolerance from the vertices' extent when not set
    if (bt_tol == 0 or bt_tol != bt_tol) {
        bt_tol = maxsd(bdSize(b) * bt_rel, bt_tiny);
    }
    // edges: sampled, inner points unmade
    const body = br.bd(b);
    var f = body.first;
    const f1 = f + body.nf;
    while (f < f1) : (f += 1) {
        var l = br.fc(f).loop;
        const l1 = l + br.fc(f).nloop;
        while (l < l1) : (l += 1) {
            var c = br.lp(l).first;
            const cend = c + br.lp(l).n;
            while (c < cend) : (c += 1) {
                const e = br.ce(c).edge;
                edTess(e);
                br.ed(e).aux = NONE;
            }
        }
    }
    f = body.first;
    while (f < f1) : (f += 1) fcTess(f);
    // kept: a copy of exactly that size
    const ts: *Tess = @ptrCast(nb.data(@sizeOf(Tess)) orelse return);
    ts.nv = bt_nv;
    ts.nt = bt_nt;
    const pv = nb.doubles(@as(usize, bt_nv) * 3 + 2) orelse return;
    @memcpy(pv[0 .. @as(usize, bt_nv) * 3], bt_va[0 .. @as(usize, bt_nv) * 3]);
    ts.pv = pv;
    const pm: [*]u32 = @ptrCast(nb.data(@as(usize, bt_nt) * 12 + 16) orelse return);
    @memcpy(pm[0 .. @as(usize, bt_nt) * 3], bt_ta[0 .. @as(usize, bt_nt) * 3]);
    ts.pt = pm;
    br.bd(b).tri = ts;
}

/// bd_size / bd_reach(body): the diagonal of its vertices' box
pub fn bdSize(b: u32) f64 {
    var lo: V3 = .{ bt_big, bt_big, bt_big };
    var hi: V3 = .{ fneg(bt_big), fneg(bt_big), fneg(bt_big) };
    const body = br.bd(b);
    var f = body.first;
    const f1 = f + body.nf;
    while (f < f1) : (f += 1) {
        var l = br.fc(f).loop;
        const l1 = l + br.fc(f).nloop;
        while (l < l1) : (l += 1) {
            var c = br.lp(l).first;
            const cend = c + br.lp(l).n;
            while (c < cend) : (c += 1) {
                const p = br.vx(br.ed(br.ce(c).edge).v0).p;
                for (0..3) |q| {
                    lo[q] = minsd(lo[q], p[q]);
                    hi[q] = maxsd(hi[q], p[q]);
                }
            }
        }
    }
    var d: f64 = 0;
    for (0..3) |q| {
        const x = hi[q] - lo[q];
        d += x * x;
    }
    return @sqrt(d);
}

/// The body's triangles (tessellated if not yet), or null.
pub fn bdTri(b: u32) ?*Tess {
    if (br.bd(b).tri == null) bdTess(b);
    return @ptrCast(@alignCast(br.bd(b).tri));
}

/// bd_inside(body, point): inside its tessellation: rays in three
/// directions, the majority of their crossing parities
pub fn bdInside(b: u32, p: V3) bool {
    const t: *Tess = @ptrCast(@alignCast(br.bd(b).tri orelse return false));
    var votes: u32 = 0;
    for (bt_dirs) |d| votes += rayParity(t, p, d);
    return votes >= 2;
}

/// ray_parity: crossings & 1 (Moller-Trumbore)
fn rayParity(ts: *const Tess, o: V3, d: V3) u32 {
    var cross: u32 = 0;
    var i: u32 = 0;
    while (i < ts.nt) : (i += 1) {
        const v0 = vtx(ts, ts.pt[i * 3]);
        const v1 = vtx(ts, ts.pt[i * 3 + 1]);
        const v2 = vtx(ts, ts.pt[i * 3 + 2]);
        const e1 = nb.v3sub(v1, v0);
        const e2 = nb.v3sub(v2, v0);
        const p = nb.v3cross(d, e2);
        const det = nb.v3dot(e1, p);
        if (jbe(fabs(det), bt_tiny)) continue;
        const inv = 1.0 / det;
        const s = nb.v3sub(o, v0);
        const u = nb.v3dot(s, p) * inv;
        if (jb(u, 0)) continue;
        if (ja(u, 1.0)) continue;
        const q = nb.v3cross(s, e1);
        var v = nb.v3dot(d, q) * inv;
        if (jb(v, 0)) continue;
        v = v + u;
        if (ja(v, 1.0)) continue;
        const t = nb.v3dot(e2, q) * inv;
        if (jbe(t, 0)) continue;
        cross += 1;
    }
    return cross & 1;
}
inline fn vtx(ts: *const Tess, i: u32) V3 {
    return .{ ts.pv[i * 3], ts.pv[i * 3 + 1], ts.pv[i * 3 + 2] };
}

test "btess compiles" {
    std.testing.refAllDecls(@This());
}
