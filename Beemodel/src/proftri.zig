//! prof.s's loops in a plane and their triangulation: the one copy, used by
//! the B-rep tessellation (btess.s calls pf_merge and pf_earclip) and by the
//! feature tree's sketch profiles (prof.zig fills this state): the loops
//! (pf_pt, pf_ls / pf_ln, their nesting in pf_par / pf_dep), a material loop
//! with its holes bridged into one polygon (merge), and ear clipping (earclip). The rest of prof.s (sketch profiles, prisms,
//! revolutions as meshes) is prof.zig, on top of this state. In the
//! original's order of operations, bit for bit.
const std = @import("std");
const nb = @import("nurbs.zig");
const jb = nb.jb;
const jbe = nb.jbe;
const jae = nb.jae;
const ja = nb.ja;
const maxsd = nb.maxsd;
const fabs = nb.fabs;

pub const MAXP = 8192; // loop points
pub const MAXL = 128; // loops
pub const MAXTRI = 16384;
const pd_eps: f64 = 1.0e-12;
const pd_big: f64 = 1.0e300;

pub var pf_nl: u32 = 0; // loops
pub var pf_np: u32 = 0; // points in them
pub var pf_ls: [MAXL]u32 = undefined; // first point
pub var pf_ln: [MAXL]u32 = undefined; // how many
pub var pf_par: [MAXL]i32 = undefined; // the material loop a hole is in (-1)
pub var pf_dep: [MAXL]u32 = undefined;
pub var pf_pt: [MAXP][2]f64 = undefined; // u, v
pub var pf_area: [MAXL]f64 = undefined;
pub var pf_scale: f64 = 0;
var used: [MAXL]u8 = undefined; // (el_used in prof.s: holes bridged)
pub var tr_v: [MAXP + 2 * MAXL]u32 = undefined; // the merged polygon (point indices)
pub var tr_n: u32 = 0;
pub var pf_tri: [MAXTRI][3]u32 = undefined; // triangles (point indices)
pub var pf_ntri: u32 = 0;

inline fn lp(i: u32) [2]f64 {
    return pf_pt[i];
}

/// area(loop) -> signed area (shoelace)
pub fn area(l: u32) f64 {
    const s = pf_ls[l];
    const n = pf_ln[l];
    var a: f64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const p = lp(s + i);
        const q = lp(s + (i + 1) % n);
        var x = q[1] * p[0];
        x = x - q[0] * p[1];
        a += x;
    }
    return a * 0.5;
}

/// inside(loop, point): even-odd crossings
pub fn inside(l: u32, u: f64, v: f64) bool {
    const s = pf_ls[l];
    const n = pf_ln[l];
    var c = false;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const a = lp(s + i);
        const b = lp(s + (i + 1) % n);
        if ((a[1] > v) == (b[1] > v)) continue;
        var x = v - a[1];
        x = x * (b[0] - a[0]);
        x = x / (b[1] - a[1]);
        x = x + a[0];
        if (jbe(x, u)) continue;
        c = !c;
    }
    return c;
}

/// reverse(loop): in place
pub fn reverse(l: u32) void {
    var a = pf_ls[l];
    var b = a +% pf_ln[l] -% 1;
    while (a < b) {
        const t = pf_pt[a];
        pf_pt[a] = pf_pt[b];
        pf_pt[b] = t;
        a += 1;
        b -= 1;
    }
}

/// pf_nest: depth by containment, parent = the smallest container; material
/// loops counter-clockwise, holes clockwise
pub fn nest() void {
    var i: u32 = 0;
    while (i < pf_nl) : (i += 1) pf_area[i] = area(i);
    i = 0;
    while (i < pf_nl) : (i += 1) {
        // (a loop left empty by a full point table: (0, 0), not past the table)
        const p = if (pf_ln[i] > 0) lp(pf_ls[i]) else [2]f64{ 0, 0 };
        var dep: u32 = 0;
        var par: i32 = -1;
        var best = pd_big;
        var j: u32 = 0;
        while (j < pf_nl) : (j += 1) {
            if (j == i) continue;
            if (!inside(j, p[0], p[1])) continue;
            dep += 1;
            const a = fabs(pf_area[j]);
            if (jae(a, best)) continue;
            best = a;
            par = @intCast(j);
        }
        pf_dep[i] = dep;
        pf_par[i] = par;
    }
    i = 0;
    while (i < pf_nl) : (i += 1) {
        const a = pf_area[i];
        if (pf_dep[i] & 1 == 0) {
            if (!jae(a, 0)) reverse(i); // material: counter-clockwise
        } else {
            if (!jbe(a, 0)) reverse(i); // hole: clockwise
        }
        if (pf_dep[i] & 1 == 0) pf_par[i] = -1; // holes: their parent is material
    }
}

/// prof_count -> material loops (regions)
pub fn count() u32 {
    var n: u32 = 0;
    for (0..pf_nl) |i| {
        if (pf_dep[i] & 1 == 0) n += 1;
    }
    return n;
}

inline fn tvp(i: u32) [2]f64 {
    return lp(tr_v[i]);
}

/// cross3: (b - a) x (c - a)
inline fn cross3(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    var x = b[0] - a[0];
    x = x * (c[1] - a[1]);
    var y = b[1] - a[1];
    y = y * (c[0] - a[0]);
    return x - y;
}

/// pf_merge(material loop) -> tr_v / tr_n: the loop with its holes bridged in
pub fn merge(l: u32) void {
    const s = pf_ls[l];
    const n = pf_ln[l];
    var i: u32 = 0;
    while (i < n) : (i += 1) tr_v[i] = s + i;
    tr_n = n;
    @memset(&used, 0);
    while (true) {
        // the unbridged hole of this loop with the largest u
        var hole: i32 = -1;
        var best: f64 = 0 - pd_big;
        var m: u32 = 0;
        var k: u32 = 0;
        while (k < pf_nl) : (k += 1) {
            if (pf_par[k] != @as(i32, @intCast(l))) continue;
            if (used[k] != 0) continue;
            const r = maxu(k);
            if (jbe(r.u, best)) continue;
            best = r.u;
            hole = @intCast(k);
            m = r.p;
        }
        if (hole < 0) return;
        const h: u32 = @intCast(hole);
        used[h] = 1;
        const M = lp(m);
        // the nearest crossing of the ray +u from M with the polygon so far
        var edge: i32 = -1;
        var eu = pd_big;
        var bsave: [2]f64 = undefined;
        var e: u32 = 0;
        while (e < tr_n) : (e += 1) {
            const a = tvp(e);
            const b = tvp((e + 1) % tr_n);
            var st = a[1] - M[1];
            st = st * (b[1] - M[1]);
            if (ja(st, 0)) continue; // straddles v of M?
            if (jbe(fabs(b[1] - a[1]), pd_eps)) continue; // (a horizontal edge)
            var x = M[1] - a[1];
            x = x * (b[0] - a[0]);
            x = x / (b[1] - a[1]);
            x = x + a[0];
            if (jb(x, M[0])) continue; // to the right of M
            if (jae(x, eu)) continue;
            eu = x;
            edge = @intCast(e);
            bsave = b;
        }
        if (edge < 0) continue; // (no crossing: skip this hole)
        // P: the end of that edge with the larger u
        const ue: u32 = @intCast(edge);
        var pslot = ue;
        const a = tvp(ue);
        if (!jae(a[0], bsave[0])) pslot = (ue + 1) % tr_n;
        splice(h, pslot, m);
    }
}

const MaxU = struct { u: f64, p: u32 };
/// maxu(loop) -> its largest u, and that point
fn maxu(l: u32) MaxU {
    const s = pf_ls[l];
    const n = pf_ln[l];
    var best: f64 = 0 - pd_big;
    var p = s;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const q = lp(s + i);
        if (jbe(q[0], best)) continue;
        best = q[0];
        p = s + i;
    }
    return .{ .u = best, .p = p };
}

/// splice(hole loop, slot of P in tr_v, M): insert the hole
fn splice(h: u32, ps: u32, m: u32) void {
    const hn = pf_ln[h];
    if (hn + 2 + tr_n > MAXP + 2 * MAXL) return;
    // shift the tail right
    var c: i32 = @as(i32, @intCast(tr_n)) - 1;
    while (c > @as(i32, @intCast(ps))) : (c -= 1) {
        const uc: u32 = @intCast(c);
        tr_v[uc + hn + 2] = tr_v[uc];
    }
    // after P: the hole from M, then M, P
    const first = pf_ls[h];
    const off = m -% first;
    var i: u32 = 0;
    while (i < hn) : (i += 1) tr_v[ps + i + 1] = first + (off +% i) % hn;
    tr_v[ps + hn + 1] = m;
    tr_v[ps + hn + 2] = tr_v[ps];
    tr_n += hn + 2;
}

/// pf_earclip -> pf_tri / pf_ntri from tr_v (counter-clockwise, may touch
/// itself at the bridges)
pub fn earclip() void {
    pf_ntri = 0;
    var n = tr_n; // vertices left
    var fails: u32 = 0; // failures in a row
    var i: u32 = 0;
    while (n >= 3) {
        var prev = (i + n - 1) % n;
        i = i % n;
        var next = (i + 1) % n;
        if (fails > n) {
            // stuck (degenerate): clip anyway
            fails = 0;
            prev = (i + n - 1) % n;
            i = i % n;
            next = (i + 1) % n;
            emit(prev, &i, next, &n);
            continue;
        }
        const A = tvp(prev);
        const B = tvp(i);
        const C = tvp(next);
        // convex: (cur - prev) x (next - prev) > 0
        var lim = pf_scale * pf_scale;
        lim = lim * pd_eps;
        var ear = ja(cross3(A, B, C), lim);
        if (ear) {
            // no other vertex inside (vertices at a corner's position don't count)
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                if (k == prev or k == i or k == next) continue;
                const v = tr_v[k];
                if (v == tr_v[prev] or v == tr_v[i] or v == tr_v[next]) continue;
                const P = tvp(k);
                if (jb(cross3(A, B, P), 0)) continue;
                if (jb(cross3(B, C, P), 0)) continue;
                if (jb(cross3(C, A, P), 0)) continue;
                ear = false; // a vertex inside: not an ear
                break;
            }
        }
        if (ear) {
            emit(prev, &i, next, &n);
            fails = 0;
        } else {
            fails += 1;
            i += 1;
        }
    }
}

/// emit: a triangle, then cur leaves the polygon
fn emit(prev: u32, cur: *u32, next: u32, n: *u32) void {
    if (pf_ntri < MAXTRI) {
        pf_tri[pf_ntri] = .{ tr_v[prev], tr_v[cur.*], tr_v[next] };
        pf_ntri += 1;
    }
    var k = cur.*;
    while (k + 1 < n.*) : (k += 1) tr_v[k] = tr_v[k + 1];
    n.* -= 1;
    if (cur.* >= n.*) cur.* = 0;
}

test "a square with a square hole: bridged, clipped, the area kept" {
    const T = std.testing;
    const outer = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    const hole = [_][2]f64{ .{ 1, 1 }, .{ 1, 3 }, .{ 3, 3 }, .{ 3, 1 } }; // clockwise
    for (outer, 0..) |p, i| pf_pt[i] = p;
    for (hole, 0..) |p, i| pf_pt[4 + i] = p;
    pf_nl = 2;
    pf_np = 8;
    pf_ls[0] = 0;
    pf_ln[0] = 4;
    pf_ls[1] = 4;
    pf_ln[1] = 4;
    nest();
    try T.expectEqual(@as(i32, -1), pf_par[0]);
    try T.expectEqual(@as(i32, 0), pf_par[1]);
    try T.expectEqual(@as(u32, 1), count());
    pf_scale = 4;
    merge(0);
    try T.expectEqual(@as(u32, 10), tr_n);
    earclip();
    try T.expectEqual(@as(u32, 8), pf_ntri);
    var a: f64 = 0;
    for (pf_tri[0..pf_ntri]) |t| a += cross3(pf_pt[t[0]], pf_pt[t[1]], pf_pt[t[2]]) * 0.5;
    try T.expectEqual(@as(f64, 12), a);
}
