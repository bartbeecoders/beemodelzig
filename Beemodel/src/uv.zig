// UV maps (uv.s): seams, unwrapping, packing, measures. A mesh may carry UVs
// (Mesh.uv: u, v per loop) and seams (Mesh.seam: per loop, the edge from it to the
// next loop of its polygon). The topology, the smart projection, the islands by
// equal UVs and the packing are smartuv.zig's; here are the islands along seams,
// LSCM (Levy et al. 2002) and everything that works on a mesh of the scene.
//
// Islands are polygons joined across edges that are not seams; UV vertices are
// loops at one vertex joined across such edges, so a seam splits a vertex even
// inside one island (a cylinder cut once). Unwrap: per island, each triangle in
// its own plane gives two rows of the conformal energy |sum W_j (u_j + i v_j)|^2 /
// 2A; two vertices are pinned (the extremes of a planar projection, which is also
// the start) and the normal equations are solved by conjugate gradients with a
// Jacobi preconditioner, matrix-free, in doubles. The order of every sum is the
// original's: the same input gives the same bits.
//
// Scene meshes are never changed in place: a step of the history may hold them
// (undo.zig), so each operator works on a copy the object then points at.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const smartuv = @import("smartuv.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const em = @import("editmesh.zig");
const A = std.heap.page_allocator;
const AS = @import("alloc.zig").A;

const NONE = smartuv.NONE;
const Mesh = scene.Mesh;
const Topo = smartuv.Topo;

const tiny_d: f64 = 1.0e-300;
const tol2: f64 = 1.0e-14; // residual^2, relative
const tiny_f: f32 = 1.0e-20;
const cos30: f32 = 0.8660254;
const OV_N = 256;

// --- islands along seams ---------------------------------------------------------

/// ut_seam: the loop's edge is a seam (either side). A loop without a twin never
/// gets here.
fn isSeam(me: *const Mesh, l: usize, tw: usize) bool {
    if (me.seam.len != me.loops.len) return false;
    return me.seam[l] != 0 or me.seam[tw] != 0;
}

/// ut_islands(0): polygon islands and each loop's UV vertex (a root loop).
fn islandsBySeams(t: *Topo, luv: []u32) bool {
    const me = t.me;
    for (0..t.np()) |i| t.puf[i] = @intCast(i);
    for (luv, 0..) |*x, i| x.* = @intCast(i);
    for (0..t.nl()) |l| {
        const tw = t.twin[l];
        if (tw == NONE or isSeam(me, l, tw)) continue;
        smartuv.join(t.puf, t.lpoly[l], t.lpoly[tw]);
        smartuv.join(luv, @intCast(l), t.next[tw]); // l with next(t), next(l) with t
        smartuv.join(luv, t.next[l], tw);
    }
    for (0..t.nl()) |l| luv[l] = smartuv.find(luv, @intCast(l));
    return smartuv.number(t);
}

// --- LSCM ------------------------------------------------------------------------

/// A triangle in its own plane: three local vertices, W / sqrt(2A) per corner.
const LT = extern struct { id: [3]u32, pad: u32 = 0, w: [6]f64 };

const Ls = struct {
    me: *const Mesh,
    t: *const Topo,
    uv: [][2]f32,
    luv: []const u32,
    /// per loop: stamp, local id
    lst: []u32,
    lid: []u32,
    /// per polygon: its first triangle (+1 at the end)
    ptoff: []u32,
    serial: u32 = 0,
    // per island, grown as needed
    tri: []LT = &.{},
    nt: usize = 0,
    nv: usize = 0,
    x: []f64 = &.{},
    r: []f64 = &.{},
    p: []f64 = &.{},
    q: []f64 = &.{},
    z: []f64 = &.{},
    d: []f64 = &.{},
    pin: []u8 = &.{},
    pos: []u32 = &.{},

    fn deinit(s: *Ls) void {
        A.free(s.tri);
        A.free(s.x);
        A.free(s.pin);
        A.free(s.pos);
    }

    fn room(s: *Ls, nt: usize, nv: usize) bool {
        if (nt > s.tri.len) {
            A.free(s.tri);
            s.tri = &.{};
            s.tri = A.alloc(LT, nt + nt / 2) catch return false;
        }
        if (nv * 12 > s.x.len) {
            A.free(s.x);
            A.free(s.pin);
            A.free(s.pos);
            s.x = &.{};
            s.pin = &.{};
            s.pos = &.{};
            const cap = nv + nv / 2;
            const all = A.alloc(f64, cap * 12) catch return false;
            s.x = all;
            s.pin = A.alloc(u8, cap) catch return false;
            s.pos = A.alloc(u32, cap) catch return false;
        }
        const n = nv * 2;
        s.r = s.x[n..][0..n];
        s.p = s.x[2 * n..][0..n];
        s.q = s.x[3 * n..][0..n];
        s.z = s.x[4 * n..][0..n];
        s.d = s.x[5 * n..][0..n];
        @memset(s.x[0 .. 6 * n], 0);
        @memset(s.pin[0..nv], 0);
        return true;
    }

    fn vpos(s: *const Ls, v: usize) m.V3 {
        return s.me.verts[s.me.loops[s.pos[v]]];
    }

    /// The first loop of polygon p at vertex v.
    fn corner(s: *const Ls, p: usize, v: u32) usize {
        const me = s.me;
        var l: usize = me.poff[p];
        while (l < me.poff[p + 1]) : (l += 1) {
            if (me.loops[l] == v) return l;
        }
        return me.poff[p];
    }

    /// ls_project: x: every local vertex on the island's plane; the two extremes
    /// along u are pinned.
    fn project(s: *Ls, ax: [2]m.V3) void {
        var lo: usize = 0;
        var hi: usize = 0;
        for (0..s.nv) |v| {
            const q = s.vpos(v);
            const u = q[0] * ax[0][0] + q[1] * ax[0][1] + q[2] * ax[0][2];
            const w = q[0] * ax[1][0] + q[1] * ax[1][1] + q[2] * ax[1][2];
            s.x[v * 2] = u;
            s.x[v * 2 + 1] = w;
            const x: f64 = u;
            if (!(x >= s.x[lo * 2])) lo = v;
            if (x > s.x[hi * 2]) hi = v;
        }
        s.pin[lo] = 1;
        s.pin[hi] = 1;
    }

    /// ls_triangles: W0 = z2 - z1, W1 = z0 - z2, W2 = z1 - z0, over sqrt(2A);
    /// degenerate triangles make no rows.
    fn triangles(s: *Ls, polys: []const u32) void {
        const me = s.me;
        var out: usize = 0;
        for (polys) |p| {
            var ti = s.ptoff[p];
            while (ti < s.ptoff[p + 1]) : (ti += 1) {
                var id: [3]u32 = undefined;
                var c: [3]m.V3 = undefined;
                for (0..3) |k| {
                    const l = s.corner(p, me.tris[ti][k]);
                    id[k] = s.lid[s.luv[l]];
                    c[k] = s.vpos(id[k]);
                }
                const e1 = [3]f64{ c[1][0] - c[0][0], c[1][1] - c[0][1], c[1][2] - c[0][2] };
                const e2 = [3]f64{ c[2][0] - c[0][0], c[2][1] - c[0][1], c[2][2] - c[0][2] };
                const x1 = @sqrt(e1[0] * e1[0] + e1[1] * e1[1] + e1[2] * e1[2]);
                const div = @max(x1, tiny_d);
                const x2 = (e1[0] * e2[0] + e1[1] * e2[1] + e1[2] * e2[2]) / div;
                const c0 = e1[1] * e2[2] - e1[2] * e2[1];
                const c1 = e1[2] * e2[0] - e1[0] * e2[2];
                const c2 = e1[0] * e2[1] - e1[1] * e2[0];
                const two_a = @sqrt(c0 * c0 + c1 * c1 + c2 * c2);
                const y2 = two_a / div;
                if (!(two_a > tiny_d)) continue;
                const k = 1 / @sqrt(two_a);
                s.tri[out] = .{ .id = id, .w = .{ (x2 - x1) * k, y2 * k, (0 - x2) * k, (0 - y2) * k, x1 * k, 0 } };
                out += 1;
            }
        }
        s.nt = out;
    }

    /// out = A^T A in (two doubles a vertex); pinned outputs are 0.
    fn apply(s: *Ls, in: []const f64, out: []f64, pins: bool) void {
        @memset(out[0 .. s.nv * 2], 0);
        for (s.tri[0..s.nt]) |*t| {
            var re: f64 = 0;
            var im: f64 = 0;
            for (0..3) |c| {
                const a = t.id[c];
                if (!pins and s.pin[a] != 0) continue;
                const u = in[a * 2];
                const v = in[a * 2 + 1];
                const wr = t.w[c * 2];
                const wi = t.w[c * 2 + 1];
                re = (re + wr * u) - wi * v;
                im = (im + wi * u) + wr * v;
            }
            for (0..3) |c| {
                const a = t.id[c];
                if (s.pin[a] != 0) continue;
                const wr = t.w[c * 2];
                const wi = t.w[c * 2 + 1];
                out[a * 2] += wr * re + wi * im;
                out[a * 2 + 1] += wr * im - wi * re;
            }
        }
    }

    /// (from the last entry down, as the original adds them)
    fn dot(s: *const Ls, a: []const f64, b: []const f64) f64 {
        var r: f64 = 0;
        var i = s.nv * 2;
        while (i > 0) {
            i -= 1;
            r += a[i] * b[i];
        }
        return r;
    }

    fn precond(s: *Ls) void {
        for (s.z[0 .. s.nv * 2], s.r[0 .. s.nv * 2], s.d[0 .. s.nv * 2]) |*z, r, d| z.* = r * d;
    }

    /// Conjugate gradients on A^T A x = -A^T A x_pinned (Jacobi).
    fn solve(s: *Ls) void {
        const n2 = s.nv * 2;
        for (s.tri[0..s.nt]) |*t| {
            for (0..3) |c| {
                const a = t.id[c];
                const v = t.w[c * 2] * t.w[c * 2] + t.w[c * 2 + 1] * t.w[c * 2 + 1] + s.d[a * 2];
                s.d[a * 2] = v;
                s.d[a * 2 + 1] = v;
            }
        }
        for (0..s.nv) |v| {
            const y: f64 = if (s.pin[v] != 0) 0 else 1 / @max(s.d[v * 2], tiny_d);
            s.d[v * 2] = y;
            s.d[v * 2 + 1] = y;
        }
        s.apply(s.x, s.r, true);
        for (s.r[0..n2]) |*y| y.* = 0 - y.*;
        s.precond();
        @memcpy(s.p[0..n2], s.z[0..n2]);
        var rz = s.dot(s.r, s.z);
        const stop = s.dot(s.r, s.r) * tol2;
        var left: i64 = @as(i64, @intCast(s.nv)) * 4 + 200; // at most 4 n + 200 iterations
        while (true) {
            left -= 1;
            if (left < 0) return;
            s.apply(s.p, s.q, false);
            const pq = s.dot(s.p, s.q);
            if (!(pq > tiny_d)) return;
            const alpha = rz / pq;
            for (0..n2) |i| {
                s.x[i] += s.p[i] * alpha; // (pinned p: 0)
                s.r[i] -= s.q[i] * alpha;
            }
            if (!(s.dot(s.r, s.r) > stop)) return;
            s.precond();
            const rz2 = s.dot(s.r, s.z);
            const beta = rz2 / rz;
            rz = rz2;
            for (0..n2) |i| s.p[i] = s.p[i] * beta + s.z[i];
        }
    }

    /// One island's loops get their UVs. False: no memory.
    fn island(s: *Ls, polys: []const u32) bool {
        const me = s.me;
        const t = s.t;
        s.serial += 1;
        var nt: usize = 0;
        var nv: u32 = 0;
        for (polys) |p| {
            nt += s.ptoff[p + 1] - s.ptoff[p];
            for (me.poff[p]..me.poff[p + 1]) |l| {
                const r = s.luv[l];
                if (s.lst[r] == s.serial) continue;
                s.lst[r] = s.serial;
                s.lid[r] = nv;
                nv += 1;
            }
        }
        s.nt = nt;
        s.nv = nv;
        if (!s.room(nt, nv)) return false;
        for (polys) |p| {
            for (me.poff[p]..me.poff[p + 1]) |l| s.pos[s.lid[s.luv[l]]] = @intCast(l);
        }
        // the island's plane: its area-weighted normal
        var n: m.V3 = .{ 0, 0, 0 };
        for (polys) |p| {
            for (0..3) |c| n[c] += t.pnrm[p][c] * t.parea[p];
        }
        s.project(smartuv.axes(n));
        s.triangles(polys);
        if (nv >= 3) s.solve();
        for (polys) |p| {
            for (me.poff[p]..me.poff[p + 1]) |l| {
                const v = s.lid[s.luv[l]];
                s.uv[l] = .{ @floatCast(s.x[v * 2]), @floatCast(s.x[v * 2 + 1]) };
            }
        }
        return true;
    }
};

fn triOffsets(me: *const Mesh, ptoff: []u32) void {
    @memset(ptoff, 0);
    for (me.tri_poly) |p| ptoff[p + 1] += 1;
    var a: u32 = 0;
    for (ptoff[1..]) |*x| {
        a += x.*;
        x.* = a;
    }
}

fn lscm(t: *Topo, me: *const Mesh) bool {
    const nl = t.nl();
    const ints = A.alloc(u32, nl * 3 + t.np() + 1) catch return false;
    defer A.free(ints);
    const luv = ints[0..nl];
    const lst = ints[nl..][0..nl];
    const lid = ints[2 * nl..][0..nl];
    const ptoff = ints[3 * nl..];
    @memset(lst, 0);
    triOffsets(me, ptoff);
    if (!islandsBySeams(t, luv)) return false;
    var s = Ls{ .me = me, .t = t, .uv = t.uv, .luv = luv, .lst = lst, .lid = lid, .ptoff = ptoff };
    defer s.deinit();
    for (0..t.nisl) |i| {
        if (!s.island(t.ipoly[t.ioff[i]..t.ioff[i + 1]])) return false;
    }
    return true;
}

// --- on a mesh -------------------------------------------------------------------

fn uvAlloc(me: *Mesh) bool {
    if (me.uv.len == me.loops.len and me.uv.len > 0) return true;
    if (me.uv.len > 0) AS.free(me.uv);
    me.uv = &.{};
    const u = AS.alloc([2]f32, me.loops.len) catch return false;
    @memset(u, .{ 0, 0 });
    me.uv = u;
    return true;
}

/// uv_unwrap: the islands, packed; null: no memory (or nothing to unwrap).
pub fn unwrap(me: *Mesh, smart: bool) ?u32 {
    if (me.loops.len == 0 or !uvAlloc(me)) return null;
    var w = smartuv.Work.init(me, me.uv) orelse return null;
    defer w.deinit();
    if (smart) {
        w.smart();
    } else if (!lscm(&w.t, me)) return null;
    if (!smartuv.islandsByUv(&w.t) or !smartuv.pack(&w.t)) return null;
    return w.t.nisl;
}

/// uv_pack: the islands; null: no UVs (or no memory).
pub fn pack(me: *Mesh) ?u32 {
    if (me.uv.len == 0 or me.uv.len != me.loops.len) return null;
    var w = smartuv.Work.init(me, me.uv) orelse return null;
    defer w.deinit();
    if (!smartuv.islandsByUv(&w.t) or !smartuv.pack(&w.t)) return null;
    return w.t.nisl;
}

pub const SeamMode = enum { mark, clear, sharp, none };

/// uv_seams: the seam edges now; null: no memory. `sel`: selected vertices.
pub fn seams(me: *Mesh, mode: SeamMode, sel: []const bool) ?u32 {
    if (me.seam.len != me.loops.len) {
        if (me.seam.len > 0) AS.free(me.seam);
        me.seam = &.{};
        const s = AS.alloc(u8, me.loops.len) catch return null;
        @memset(s, 0);
        me.seam = s;
    }
    if (mode == .none) {
        @memset(me.seam, 0);
    } else if (me.loops.len > 0) {
        var w = smartuv.Work.init(me, &.{}) orelse return null;
        defer w.deinit();
        const t = &w.t;
        for (0..t.nl()) |l| {
            if (mode == .sharp) {
                const tw = t.twin[l];
                if (tw == NONE) continue;
                const a = t.pnrm[t.lpoly[l]];
                const b = t.pnrm[t.lpoly[tw]];
                if (!(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] >= cos30)) me.seam[l] = 1;
            } else {
                const v0 = me.loops[l];
                const v1 = me.loops[t.next[l]];
                if (v0 >= sel.len or v1 >= sel.len or !sel[v0] or !sel[v1]) continue;
                me.seam[l] = @intFromBool(mode == .mark);
            }
        }
    }
    var n: u32 = 0; // (each edge has two sides)
    for (me.seam) |c| n +%= c;
    return (n +% 1) >> 1;
}

// --- measures --------------------------------------------------------------------

pub const Stat = enum(u32) { islands, angle, area, flipped, overlap, inside };

fn triPos(me: *const Mesh, ti: usize) [3]m.V3 {
    const t = me.tris[ti];
    return .{ me.verts[t[0]], me.verts[t[1]], me.verts[t[2]] };
}

/// tri_area3
pub fn area3(p: *const [3]m.V3) f32 {
    const e1 = m.sub(p[1], p[0]);
    const e2 = m.sub(p[2], p[0]);
    const a = e1[1] * e2[2] - e1[2] * e2[1];
    const b = e1[2] * e2[0] - e1[0] * e2[2];
    const c = e1[0] * e2[1] - e1[1] * e2[0];
    return @sqrt(a * a + b * b + c * c) * 0.5;
}

/// tri_area2: signed, counter-clockwise +.
pub fn area2(u: *const [6]f32) f32 {
    return ((u[2] - u[0]) * (u[5] - u[1]) - (u[4] - u[0]) * (u[3] - u[1])) * 0.5;
}

fn acosOf(ab0: f32, aa: f32, bb: f32) f32 {
    const l = @max(@sqrt(aa * bb), tiny_f);
    const c: f64 = @min(@max(ab0 / l, -1.0), 1.0);
    return @floatCast(std.math.atan2(@sqrt(1 - c * c), c));
}

/// angle3: corner k's angle.
pub fn angle3(k: usize, p: *const [3]m.V3) f32 {
    const a = p[k];
    const b = p[(k + 1) % 3];
    const c = p[(k + 2) % 3];
    var ab: f32 = 0;
    var aa: f32 = 0;
    var bb: f32 = 0;
    for (0..3) |i| {
        const x = b[i] - a[i];
        const y = c[i] - a[i];
        ab += x * y;
        aa += x * x;
        bb += y * y;
    }
    return acosOf(ab, aa, bb);
}

/// angle2: corner k's angle.
pub fn angle2(k: usize, u: *const [6]f32) f32 {
    const a = k * 2;
    const b = (k + 1) % 3 * 2;
    const c = (k + 2) % 3 * 2;
    var ab: f32 = 0;
    var aa: f32 = 0;
    var bb: f32 = 0;
    for (0..2) |i| {
        const x = u[b + i] - u[a + i];
        const y = u[c + i] - u[a + i];
        ab += x * y;
        aa += x * x;
        bb += y * y;
    }
    return acosOf(ab, aa, bb);
}

fn truncI(x: f32) i32 {
    if (!(x > -2.0e9 and x < 2.0e9)) return std.math.minInt(i32); // (cvttss2si's answer)
    return @intFromFloat(x);
}

/// cover_tri: +1 on the cells whose centres lie strictly inside (either winding).
fn coverTri(grid: []u16, uv0: *const [6]f32) void {
    var g: [6]f32 = undefined;
    for (uv0, &g) |a, *b| b.* = a * OV_N;
    const ar = area2(&g);
    if (!(@abs(ar) > tiny_f)) return;
    const x0 = @max(truncI(@min(@min(g[0], g[2]), g[4])), 0);
    const x1 = @min(truncI(@max(@max(g[0], g[2]), g[4])), OV_N - 1);
    const y0 = @max(truncI(@min(@min(g[1], g[3]), g[5])), 0);
    const y1 = @min(truncI(@max(@max(g[1], g[3]), g[5])), OV_N - 1);
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        cell: while (x <= x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            for (0..3) |k| {
                const a = k * 2;
                const b = (k + 1) % 3 * 2;
                const e = ((g[b] - g[a]) * (py - g[a + 1]) - (g[b + 1] - g[a + 1]) * (px - g[a])) * ar;
                if (!(e > 0)) continue :cell; // (outside, or on an edge)
            }
            grid[@intCast(y * OV_N + x)] +%= 1;
        }
    }
}

/// uv_stat; -1: no UVs.
pub fn stat(me: *const Mesh, what: Stat) f32 {
    if (me.uv.len == 0 or me.uv.len != me.loops.len) return -1;
    const bake = @import("bake.zig");
    switch (what) {
        .inside => {
            for (me.uv) |u| {
                for (u) |c| {
                    if (!(c >= 0 and c <= 1)) return 0;
                }
            }
            return 1;
        },
        .islands => return @floatFromInt(islandCount(me) orelse return -1),
        else => {},
    }
    var sum: f32 = 0;
    var corners: u32 = 0;
    switch (what) {
        .angle => for (0..me.tris.len) |ti| {
            const p = triPos(me, ti);
            const u = bake.triUvs(me, ti).?;
            for (0..3) |k| {
                sum += @abs(angle2(k, &u) - angle3(k, &p));
                corners += 1;
            }
        },
        .area => {
            var t3: f32 = 0;
            var t2: f32 = 0;
            for (0..me.tris.len) |ti| {
                const p = triPos(me, ti);
                const u = bake.triUvs(me, ti).?;
                t2 += @abs(area2(&u));
                t3 += area3(&p);
            }
            const d2 = @max(t2, tiny_f);
            const d3 = @max(t3, tiny_f);
            for (0..me.tris.len) |ti| {
                const p = triPos(me, ti);
                const u = bake.triUvs(me, ti).?;
                sum += @abs(@abs(area2(&u)) / d2 - area3(&p) / d3);
            }
            return sum;
        },
        .flipped => for (0..me.tris.len) |ti| {
            const u = bake.triUvs(me, ti).?;
            if (!(area2(&u) >= 0)) sum += 1;
        },
        else => {
            const grid = A.alloc(u16, OV_N * OV_N) catch return -1;
            defer A.free(grid);
            @memset(grid, 0);
            for (0..me.tris.len) |ti| {
                const u = bake.triUvs(me, ti).?;
                coverTri(grid, &u);
            }
            var once: u32 = 0;
            var twice: u32 = 0;
            for (grid) |c| {
                if (c != 0) once += 1;
                if (c > 1) twice += 1;
            }
            return @as(f32, @floatFromInt(twice)) / @max(@as(f32, @floatFromInt(once)), 1);
        },
    }
    if (what == .angle) return sum / @max(@as(f32, @floatFromInt(corners)), 1) * 57.29578;
    return sum;
}

/// Islands as the UVs join; null: no memory.
pub fn islandCount(me: *const Mesh) ?u32 {
    if (me.loops.len == 0) return 0;
    var w = smartuv.Work.init(me, me.uv) orelse return null;
    defer w.deinit();
    if (!smartuv.islandsByUv(&w.t)) return null;
    return w.t.nisl;
}

/// uv_select_island: polygon p's UV island's loops get 1.
pub fn selectIsland(me: *const Mesh, p: usize, flags: []u8) void {
    var w = smartuv.Work.init(me, me.uv) orelse return;
    defer w.deinit();
    if (!smartuv.islandsByUv(&w.t)) return;
    const t = &w.t;
    const i = t.pisl[p];
    for (t.ipoly[t.ioff[i]..t.ioff[i + 1]]) |q| @memset(flags[me.poff[q]..me.poff[q + 1]], 1);
}

// --- operators -------------------------------------------------------------------

/// The object the UV work is on: the edit object, else the active mesh.
pub fn target() ?usize {
    if (em.active) {
        if (em.mesh() == null) return null;
        return em.obj;
    }
    const a = scene.active orelse return null;
    const o = &scene.objects[a];
    return if (o.mesh != null and o.kind.isMesh()) a else null;
}

/// uv_cow: object oi's mesh, a copy of its own, so that what any step of the
/// history holds stays as it is (the original counts a snapshot as a user, so an
/// operator never finds its mesh unshared).
pub fn cow(oi: usize) ?*Mesh {
    const o = &scene.objects[oi];
    const mi = o.mesh orelse return null;
    const c = scene.cloneMesh(mi) orelse return null;
    const vs = scene.meshes[mi].?.vsel;
    if (vs.len > 0) scene.setMeshSel(c, vs);
    o.mesh = c;
    em.version +%= 1;
    return &scene.meshes[c].?;
}

fn none() void {
    app.log("  uv: select a mesh", .{});
}

fn report(n: ?u32) void {
    if (n) |k| app.log("  uv: islands {d}", .{k}) else app.log("  uv: out of memory", .{});
    app.dirty = true;
}

fn doUnwrap(smart: bool) void {
    const oi = target() orelse return none();
    const me = cow(oi) orelse return none();
    undo.label(if (smart) "Smart UV Project" else "Unwrap");
    report(unwrap(me, smart));
}

fn unwrapJob(_: []const u8, _: usize, _: usize) void {
    doUnwrap(false);
}
fn packJob(_: []const u8, _: usize, _: usize) void {
    const oi = target() orelse return none();
    const me = cow(oi) orelse return none();
    undo.label("Pack Islands");
    report(pack(me));
}

pub fn opUnwrap() void {
    @import("jobui.zig").later(unwrapJob, "Unwrapping", "", 0, 0);
}
pub fn opSmart() void {
    doUnwrap(true);
}
pub fn opPack() void {
    @import("jobui.zig").later(packJob, "Packing UV islands", "", 0, 0);
}

fn doSeams(mode: SeamMode) void {
    const oi = target() orelse return none();
    const me = cow(oi) orelse return none();
    const sel: []const bool = if (em.active) em.sel else me.vsel;
    const n = seams(me, mode, sel) orelse return app.log("  uv: out of memory", .{});
    app.log("  uv: seams {d}", .{n});
    app.dirty = true;
}
pub fn opMark() void {
    doSeams(.mark);
}
pub fn opClear() void {
    doSeams(.clear);
}
pub fn opSharp() void {
    doSeams(.sharp);
}

/// OPF_EDIT: what asks first (menus, keys, buttons); scripts get the operator's
/// own message, as run_op does not ask.
pub fn pollEdit() ?[]const u8 {
    if (ops.scripted or em.active) return null;
    return "works in edit mode - select a mesh and press Tab";
}

const testing = std.testing;

fn testGrid(nx: u32, ny: u32) !Mesh {
    var v: std.ArrayList(m.V3) = .empty;
    defer v.deinit(A);
    var po: std.ArrayList(u32) = .empty;
    defer po.deinit(A);
    var lo: std.ArrayList(u32) = .empty;
    defer lo.deinit(A);
    for (0..ny + 1) |j| {
        for (0..nx + 1) |i| try v.append(A, .{ @floatFromInt(i), @floatFromInt(j), 0 });
    }
    try po.append(A, 0);
    for (0..ny) |j| {
        for (0..nx) |i| {
            const a: u32 = @intCast(j * (nx + 1) + i);
            try lo.appendSlice(A, &.{ a, a + 1, a + nx + 2, a + nx + 1 });
            try po.append(A, @intCast(lo.items.len));
        }
    }
    return scene.buildMesh(v.items, po.items, lo.items) orelse error.NoMesh;
}

test "a flat grid unwraps without distortion" {
    var me = try testGrid(6, 4);
    defer scene.freeMesh(&me);
    try testing.expectEqual(@as(?u32, 1), unwrap(&me, false));
    try testing.expect(stat(&me, .inside) == 1);
    try testing.expectApproxEqAbs(@as(f32, 0), stat(&me, .angle), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0), stat(&me, .area), 1e-4);
    try testing.expectEqual(@as(f32, 1), stat(&me, .islands));
}

test "seams make islands: a loop's twin side counts, and seams count once" {
    var me = try testGrid(2, 1);
    defer scene.freeMesh(&me);
    me.verts[2][2] = 1; // (folded: on one plane their UVs would meet again)
    me.verts[5][2] = 1;
    // the edge between the two quads
    const sel = [_]bool{ false, true, false, false, true, false };
    try testing.expectEqual(@as(?u32, 1), seams(&me, .mark, &sel));
    try testing.expectEqual(@as(?u32, 2), unwrap(&me, false));
    try testing.expectEqual(@as(?u32, 0), seams(&me, .clear, &sel));
    try testing.expectEqual(@as(?u32, 1), unwrap(&me, false));
}

test "no seam on what is not selected; none clears all" {
    var me = try testGrid(2, 2);
    defer scene.freeMesh(&me);
    const sel: [9]bool = @splat(false);
    try testing.expectEqual(@as(?u32, 0), seams(&me, .mark, &sel));
    const all: [9]bool = @splat(true);
    try testing.expectEqual(@as(?u32, 8), seams(&me, .mark, &all)); // (loops / 2: the rim counts half)
    try testing.expectEqual(@as(?u32, 0), seams(&me, .none, &all));
}

test "degenerate: all at one point stays finite" {
    const v = [_]m.V3{ .{ 1, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 1 } };
    const po = [_]u32{ 0, 4 };
    const lo = [_]u32{ 0, 1, 2, 3 };
    var me = scene.buildMesh(&v, &po, &lo).?;
    defer scene.freeMesh(&me);
    try testing.expect(unwrap(&me, false) != null);
    for (me.uv) |u| {
        try testing.expect(std.math.isFinite(u[0]) and std.math.isFinite(u[1]));
    }
    try testing.expect(pack(&me) != null);
    try testing.expect(unwrap(&me, true) != null);
}
