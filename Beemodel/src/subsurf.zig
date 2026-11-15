//! Catmull-Clark subdivision, ported from the original's subsurf.s.
//!
//! Corner-based topology: a corner c is a (face, vertex) pair; twin[c] is the
//! corner of the neighbouring face that runs the same edge backwards (-1 on a
//! boundary), eid[c] its edge. Level 0 comes from the input (one hash build);
//! every further level is derived arithmetically - new corner 4c + k of old
//! corner c - so nothing after the first level hashes, and every pass runs in
//! parallel over faces, corners or vertices.
//!
//! A Plan holds the topology of all levels and the output's polygons, and the
//! positions of the levels between. After vertices move, eval() (or evalInto(),
//! which reuses a buffer the way the original writes into its cached mesh) only
//! recomputes positions. A Plan is not safe to evaluate from two threads at
//! once, and jobs.parallelFor has one caller at a time.
const std = @import("std");
const m = @import("math.zig");
const jobs = @import("jobs.zig");
const pmesh = @import("pmesh.zig");
const kern = @import("modkern.zig");
const PMesh = pmesh.PMesh;
const V3 = m.V3;
const Allocator = std.mem.Allocator;

pub const Error = kern.Error;
pub const max_levels: u32 = 6;
const GRAIN = 4096;

const Level = struct {
    v: u32 = 0,
    e: u32 = 0,
    f: u32 = 0,
    l: u32 = 0,
    loops: []u32 = &.{},
    poff: []u32 = &.{}, // (level 0; after it faces are quads)
    cface: []u32 = &.{}, // (level 0)
    twin: []i32 = &.{},
    eid: []u32 = &.{},
    vc: []i32 = &.{}, // per vertex: one of its corners, -1 unused
};

pub const Plan = struct {
    levels: u32,
    /// the input's vertex count: what eval takes
    nverts: u32,
    lv: [max_levels]Level = @splat(.{}),
    /// positions of levels 1 .. levels - 1
    pos: [max_levels][]V3 = @splat(&.{}),
    /// level 0's polygons (a copy of the input's) or, with levels, the output's
    poff: []u32 = &.{},
    loops: []u32 = &.{},
    /// the output's vertex count
    out_verts: u32,
};

// ---- corner navigation -----------------------------------------------------------

inline fn next(lv: *const Level, comptime quad: bool, c: u32) u32 {
    if (quad) return (c & ~@as(u32, 3)) | ((c + 1) & 3);
    const f = lv.cface[c];
    return if (c + 1 < lv.poff[f + 1]) c + 1 else lv.poff[f];
}
inline fn prev(lv: *const Level, comptime quad: bool, c: u32) u32 {
    if (quad) return (c & ~@as(u32, 3)) | ((c + 3) & 3);
    const f = lv.cface[c];
    return if (c > lv.poff[f]) c - 1 else lv.poff[f + 1] - 1;
}
inline fn face(lv: *const Level, comptime quad: bool, c: u32) u32 {
    return if (quad) c >> 2 else lv.cface[c];
}
/// owner in subsurf.s: c stands for its edge.
inline fn owner(lv: *const Level, c: u32) bool {
    const t = lv.twin[c];
    return t < 0 or c < @as(u32, @intCast(t));
}

// ---- jobs ------------------------------------------------------------------------

const Job = struct {
    lv: *const Level,
    nx: *Level = undefined,
    pin: []const V3 = &.{},
    pout: []V3 = &.{},
    out_loops: []u32 = &.{},
    out_poff: []u32 = &.{},
    dst_u32: []u32 = &.{},
    src_u32: []const u32 = &.{},
};

fn run(n: usize, grain: usize, j: *Job, f: jobs.Fn) void {
    jobs.parallelFor(n, grain, j, f);
}
fn jobOf(ctx: *anyopaque) *Job {
    return @ptrCast(@alignCast(ctx));
}
fn quadFn(comptime F: fn (*Job, usize, usize, comptime bool) void, comptime quad: bool) jobs.Fn {
    return struct {
        fn call(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
            F(jobOf(ctx), lo, hi, quad);
        }
    }.call;
}

/// corners of level k -> k + 1
fn topoJob(j: *Job, lo: usize, hi: usize, comptime quad: bool) void {
    const lv = j.lv;
    const nx = j.nx;
    const twin = lv.twin;
    for (lo..hi) |ci| {
        const c: u32 = @intCast(ci);
        const p = prev(lv, quad, c);
        const f = face(lv, quad, c);
        const v = lv.loops[c];
        const e = lv.eid[c];
        const ep = lv.eid[p];
        const q = c * 4;
        nx.loops[q] = v;
        nx.loops[q + 1] = lv.v + e;
        nx.loops[q + 2] = lv.v + lv.e + f;
        nx.loops[q + 3] = lv.v + ep;
        const own = owner(lv, c);
        const e2 = lv.e * 2;
        nx.eid[q] = e * 2 + @intFromBool(!own);
        nx.eid[q + 1] = e2 + c;
        nx.eid[q + 2] = e2 + p;
        nx.eid[q + 3] = ep * 2 + @intFromBool(owner(lv, p));
        const t = twin[c];
        nx.twin[q] = if (t < 0) t else @intCast(next(lv, quad, @intCast(t)) * 4 + 3);
        nx.twin[q + 1] = @intCast(next(lv, quad, c) * 4 + 2);
        nx.twin[q + 2] = @intCast(p * 4 + 1);
        const t2 = twin[p];
        nx.twin[q + 3] = if (t2 < 0) t2 else t2 << 2;
        if (own) nx.vc[lv.v + e] = @intCast(c * 4 + 1);
        const first = if (quad) c & ~@as(u32, 3) else lv.poff[f];
        if (first == c) nx.vc[lv.v + lv.e + f] = @intCast(c * 4 + 2);
    }
}

/// old vertices keep their corner (times 4)
fn vcJob(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j = jobOf(ctx);
    for (lo..hi) |v| {
        const c = j.lv.vc[v];
        j.nx.vc[v] = if (c < 0) c else c << 2;
    }
}

/// last level's corners -> output quads
fn outJob(j: *Job, lo: usize, hi: usize, comptime quad: bool) void {
    const lv = j.lv;
    for (lo..hi) |ci| {
        const c: u32 = @intCast(ci);
        const p = prev(lv, quad, c);
        const f = face(lv, quad, c);
        const q = c * 4;
        j.out_loops[q] = lv.loops[c];
        j.out_loops[q + 1] = lv.v + lv.eid[c];
        j.out_loops[q + 2] = lv.v + lv.e + f;
        j.out_loops[q + 3] = lv.v + lv.eid[p];
        j.out_poff[c] = q;
    }
}

/// face points at V + E + f
fn fpJob(j: *Job, lo: usize, hi: usize, comptime quad: bool) void {
    const lv = j.lv;
    const pin = j.pin;
    const base = lv.v + lv.e;
    for (lo..hi) |fi| {
        const first: usize = if (quad) fi * 4 else lv.poff[fi];
        const n: usize = if (quad) 4 else lv.poff[fi + 1] - first;
        var x: f32 = 0;
        var y: f32 = 0;
        var z: f32 = 0;
        for (lv.loops[first..][0..n]) |vi| {
            const s = pin[vi];
            x += s[0];
            y += s[1];
            z += s[2];
        }
        const d: f32 = @floatFromInt(n);
        j.pout[base + fi] = .{ x / d, y / d, z / d };
    }
}

/// edge points at V + e (owner corners): (a + b + F1 + F2) / 4, or the midpoint
/// on boundaries
fn epJob(j: *Job, lo: usize, hi: usize, comptime quad: bool) void {
    const lv = j.lv;
    const pin = j.pin;
    const pout = j.pout;
    const fb = lv.v + lv.e;
    for (lo..hi) |ci| {
        const c: u32 = @intCast(ci);
        const t = lv.twin[c];
        if (t >= 0 and c > @as(u32, @intCast(t))) continue;
        const a = pin[lv.loops[c]];
        const b = pin[lv.loops[next(lv, quad, c)]];
        var s: V3 = undefined;
        if (t >= 0) {
            const f1 = pout[fb + face(lv, quad, c)];
            const f2 = pout[fb + face(lv, quad, @intCast(t))];
            for (0..3) |i| s[i] = (a[i] + b[i] + f1[i] + f2[i]) * 0.25;
        } else {
            for (0..3) |i| s[i] = (a[i] + b[i]) * 0.5;
        }
        pout[lv.v + lv.eid[c]] = s;
    }
}

/// vertex points: walk the corners around v (twin of prev). Interior
/// (Q + 2R + (n - 3) S) / n, boundary (6 S + a + b) / 8; what cannot be walked
/// (non-manifold, valence 256 and up) stays where it is.
fn vpJob(j: *Job, lo: usize, hi: usize, comptime quad: bool) void {
    const lv = j.lv;
    const pin = j.pin;
    const pout = j.pout;
    const fb = lv.v + lv.e;
    for (lo..hi) |v| vert: {
        const s = pin[v];
        pout[v] = s; // (the copy case; overwritten below)
        const c0i = lv.vc[v];
        if (c0i < 0) continue;
        const c0: u32 = @intCast(c0i);
        // find a boundary corner going the other way: c -> next(twin(c))
        var c = c0;
        var steps: u32 = 0;
        const boundary = blk: while (true) {
            const t = lv.twin[c];
            if (t < 0) break :blk true;
            c = next(lv, quad, @intCast(t));
            if (c == c0) break :blk false;
            steps += 1;
            if (steps >= 256) break :vert;
        };
        if (boundary) {
            const a = pin[lv.loops[next(lv, quad, c)]];
            steps = 0;
            var p: u32 = undefined;
            while (true) {
                p = prev(lv, quad, c);
                const t = lv.twin[p];
                if (t < 0) break;
                c = @intCast(t);
                steps += 1;
                if (steps >= 256) break :vert;
            }
            const b = pin[lv.loops[p]];
            for (0..3) |i| pout[v][i] = (s[i] * 6.0 + b[i] + a[i]) * 0.125;
            continue;
        }
        var q: V3 = .{ 0, 0, 0 };
        var r: V3 = .{ 0, 0, 0 };
        var n: u32 = 0;
        c = c0;
        while (true) {
            const f = pout[fb + face(lv, quad, c)];
            const far = pin[lv.loops[next(lv, quad, c)]];
            for (0..3) |i| {
                q[i] += f[i];
                r[i] += far[i];
            }
            n += 1;
            if (n >= 256) break :vert;
            const t = lv.twin[prev(lv, quad, c)];
            if (t < 0) break :vert;
            c = @intCast(t);
            if (c == c0) break;
        }
        const fnv: f32 = @floatFromInt(n);
        const n3 = fnv - 3.0;
        var o: V3 = undefined;
        for (0..3) |i| {
            const qm = q[i] / fnv;
            const r2 = (s[i] * fnv + r[i]) / fnv;
            o[i] = (qm + r2 + s[i] * n3) / fnv;
        }
        pout[v] = o;
    }
}

fn copyJob(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j = jobOf(ctx);
    @memcpy(j.dst_u32[lo..hi], j.src_u32[lo..hi]);
}

fn topoPass(comptime F: fn (*Job, usize, usize, comptime bool) void, j: *Job, n: usize, quad: bool) void {
    run(n, GRAIN, j, if (quad) quadFn(F, true) else quadFn(F, false));
}

// ---- level 0 ---------------------------------------------------------------------

/// cface, twin (through a hash of directed edges; of several the last wins),
/// edge ids (owners numbered first), one corner per vertex.
fn level0(a: Allocator, lv: *Level, s: kern.Mesh) !void {
    const n = s.l;
    lv.cface = try a.alloc(u32, n);
    lv.twin = try a.alloc(i32, n);
    lv.eid = try a.alloc(u32, n);
    lv.vc = try a.alloc(i32, lv.v);
    for (0..s.f) |f| {
        @memset(lv.cface[s.poff[f]..s.poff[f + 1]], @intCast(f));
    }
    var map: DirMap = try .init(a, n);
    defer map.deinit(a);
    for (0..n) |ci| {
        const c: u32 = @intCast(ci);
        map.put((@as(u64, lv.loops[c]) << 32) | lv.loops[next(lv, false, c)], c);
    }
    for (0..n) |ci| {
        const c: u32 = @intCast(ci);
        lv.twin[c] = map.get((@as(u64, lv.loops[next(lv, false, c)]) << 32) | lv.loops[c]);
    }
    var e: u32 = 0;
    @memset(lv.eid, 0);
    for (0..n) |c| {
        const t = lv.twin[c];
        if (t < 0 or c <= @as(usize, @intCast(t))) {
            lv.eid[c] = e;
            e += 1;
        }
    }
    lv.e = e;
    for (0..n) |c| {
        const t = lv.twin[c];
        if (t >= 0 and c > @as(usize, @intCast(t))) lv.eid[c] = lv.eid[@intCast(t)];
    }
    @memset(lv.vc, -1);
    for (lv.loops, 0..) |v, c| lv.vc[v] = @intCast(c);
}

const DirMap = struct {
    mask: usize,
    keys: []u64,
    vals: []u32,

    fn init(a: Allocator, expected: usize) !DirMap {
        var n: usize = 16;
        while (n < expected * 2) n *= 2;
        const keys = try a.alloc(u64, n);
        errdefer a.free(keys);
        @memset(keys, 0);
        return .{ .mask = n - 1, .keys = keys, .vals = try a.alloc(u32, n) };
    }
    fn deinit(d: DirMap, a: Allocator) void {
        a.free(d.keys);
        a.free(d.vals);
    }
    fn home(d: DirMap, k: u64) usize {
        return @as(usize, @truncate((k *% 0x2545f491) >> 13)) & d.mask;
    }
    fn put(d: DirMap, key: u64, val: u32) void {
        const k = key + 1;
        var i = d.home(k);
        while (d.keys[i] != 0 and d.keys[i] != k) i = (i + 1) & d.mask;
        d.keys[i] = k;
        d.vals[i] = val;
    }
    fn get(d: DirMap, key: u64) i32 {
        const k = key + 1;
        var i = d.home(k);
        while (d.keys[i] != 0) : (i = (i + 1) & d.mask) {
            if (d.keys[i] == k) return @intCast(d.vals[i]);
        }
        return -1;
    }
};

// ---- the plan --------------------------------------------------------------------

/// Sizes of every level up front: error.TooBig before anything is allocated.
fn sizes(v0: usize, e0_max: usize, f0: usize, l0: usize, levels: u32) Error!void {
    var v: usize = v0;
    var e: usize = e0_max;
    var f: usize = f0;
    var l: usize = l0;
    for (0..levels) |_| {
        const v2 = v + e + f;
        const e2 = e * 2 + l;
        f = l;
        if (l > kern.max_loops / 4) return error.TooBig;
        l *= 4;
        v = v2;
        e = e2;
        if (v > kern.max_verts or l > kern.max_loops) return error.TooBig;
    }
}

/// Topology for `levels` (clamped to 0..6) over `in`; the copy is the Plan's, so
/// `in` may go away. Free with freePlan.
pub fn plan(a: Allocator, in: PMesh, levels: u32) Error!*Plan {
    const s = try kern.view(in);
    const lvls = @min(levels, max_levels);
    const p = try a.create(Plan);
    p.* = .{ .levels = lvls, .nverts = s.v(), .out_verts = s.v() };
    errdefer freePlan(a, p);
    p.poff = try a.alloc(u32, if (s.f == 0) 1 else s.f + 1);
    p.poff[0] = 0;
    if (s.f > 0) @memcpy(p.poff, s.poff[0 .. s.f + 1]);
    p.loops = try a.dupe(u32, s.loops);
    if (lvls == 0) return p;
    // (edges: at most the corners; the real count may be lower)
    try sizes(s.verts.len, s.l, s.f, s.l, lvls);

    const l0 = &p.lv[0];
    l0.* = .{ .v = s.v(), .f = s.f, .l = s.l, .loops = p.loops, .poff = p.poff };
    try level0(a, l0, s);
    var k: u32 = 0;
    while (k + 1 < lvls) : (k += 1) {
        const lv = &p.lv[k];
        const nx = &p.lv[k + 1];
        nx.v = lv.v + lv.e + lv.f;
        nx.e = lv.e * 2 + lv.l;
        nx.f = lv.l;
        nx.l = lv.l * 4;
        nx.loops = try a.alloc(u32, nx.l);
        nx.twin = try a.alloc(i32, nx.l);
        nx.eid = try a.alloc(u32, nx.l);
        nx.vc = try a.alloc(i32, nx.v);
        @memset(nx.vc, 0);
        p.pos[k + 1] = try a.alloc(V3, nx.v);
        var j = Job{ .lv = lv, .nx = nx };
        topoPass(topoJob, &j, lv.l, k > 0);
        run(lv.v, GRAIN, &j, vcJob);
    }
    // the output: last level's corners become quads
    const last = &p.lv[lvls - 1];
    p.out_verts = last.v + last.e + last.f;
    const op = try a.alloc(u32, @as(usize, last.l) + 1);
    errdefer a.free(op);
    const ol = try a.alloc(u32, @as(usize, last.l) * 4);
    var j = Job{ .lv = last, .out_loops = ol, .out_poff = op };
    topoPass(outJob, &j, last.l, lvls > 1);
    op[last.l] = last.l * 4;
    p.poff = op; // (level 0 keeps the input's)
    p.loops = ol;
    return p;
}

pub fn freePlan(a: Allocator, p: *Plan) void {
    for (&p.lv, 0..) |*lv, k| {
        if (k == 0) {
            if (lv.loops.ptr != p.loops.ptr) a.free(lv.loops);
            if (lv.poff.ptr != p.poff.ptr) a.free(lv.poff);
            a.free(lv.cface);
        } else {
            a.free(lv.loops);
        }
        a.free(lv.twin);
        a.free(lv.eid);
        a.free(lv.vc);
        a.free(p.pos[k]);
    }
    a.free(p.poff);
    a.free(p.loops);
    a.destroy(p);
}

// ---- positions (every evaluation) --------------------------------------------------

/// The output's positions into `out` (p.out_verts of them): the fast path, no
/// allocation. `verts` are the input's vertices, moved or not.
pub fn evalInto(p: *Plan, verts: []const V3, out: []V3) Error!void {
    if (verts.len != p.nverts or out.len != p.out_verts) return error.BadMesh;
    if (p.levels == 0) return @memcpy(out, verts);
    var pin = verts;
    for (0..p.levels) |k| {
        const lv = &p.lv[k];
        const pout = if (k + 1 < p.levels) p.pos[k + 1] else out;
        var j = Job{ .lv = lv, .pin = pin, .pout = pout };
        const quad = k > 0;
        topoPass(fpJob, &j, lv.f, quad);
        topoPass(epJob, &j, lv.l, quad);
        topoPass(vpJob, &j, lv.v, quad);
        pin = pout;
    }
}

/// Multires over a plan (subsurf_mr, subsurf_fit): each level j displaced as it is
/// made, P_j = S(P_j-1) + D_j. The displacements are one level after the other from
/// level 1; a level they do not cover whole gets none.
pub const Mr = struct {
    disp: []const V3 = &.{},
    /// fit: the finest level's positions: each level takes the targets' first vertices
    /// and `out` what that takes over S(level j-1); the finest is the targets exactly.
    fit: ?[]const V3 = null,
    fit_out: []V3 = &.{},
    /// after: the last level's displacements' offset, and the end of them.
    off: u32 = 0,
    total: u32 = 0,
};

/// evalInto, displaced.
pub fn evalMr(p: *Plan, verts: []const V3, out: []V3, mr: *Mr) Error!void {
    if (verts.len != p.nverts or out.len != p.out_verts) return error.BadMesh;
    if (p.levels == 0) return @memcpy(out, verts);
    var pin = verts;
    var done: u32 = 0;
    for (0..p.levels) |k| {
        const lv = &p.lv[k];
        const pout = if (k + 1 < p.levels) p.pos[k + 1] else out;
        var j = Job{ .lv = lv, .pin = pin, .pout = pout };
        const quad = k > 0;
        topoPass(fpJob, &j, lv.f, quad);
        topoPass(epJob, &j, lv.l, quad);
        topoPass(vpJob, &j, lv.v, quad);
        const n = lv.v + lv.e + lv.f;
        mr.off = done;
        done += n;
        mr.total = done;
        if (mr.fit) |t| {
            const d = mr.fit_out[mr.off..][0..n];
            for (pout[0..n], d, t[0..n]) |*q, *e, g| {
                for (0..3) |c| e[c] = g[c] - q[c];
                q.* = g;
            }
        } else if (@as(usize, done) <= mr.disp.len) {
            const d = mr.disp[mr.off..][0..n];
            for (pout[0..n], d) |*q, e| {
                for (0..3) |c| q[c] = q[c] + e[c];
            }
        }
        pin = pout;
    }
}

fn dupeParallel(a: Allocator, s: []const u32) ![]u32 {
    const d = try a.alloc(u32, s.len);
    var j = Job{ .lv = undefined, .dst_u32 = d, .src_u32 = s };
    run(s.len, 1 << 18, &j, copyJob);
    return d;
}

/// The subdivided mesh for these input positions, allocated with `a`.
pub fn eval(p: *Plan, a: Allocator, verts: []const V3) Error!PMesh {
    const v = try a.alloc(V3, p.out_verts);
    errdefer a.free(v);
    try evalInto(p, verts, v);
    const o = try dupeParallel(a, p.poff);
    errdefer a.free(o);
    return .{ .verts = v, .poff = o, .loops = try dupeParallel(a, p.loops) };
}

/// plan + eval + free. Level 0 is the input.
pub fn subdivide(a: Allocator, in: PMesh, levels: u32) Error!PMesh {
    if (levels == 0) {
        _ = try kern.view(in);
        return in.clone(a);
    }
    const p = try plan(a, in, levels);
    defer freePlan(a, p);
    return eval(p, a, in.verts);
}

// ---- tests -----------------------------------------------------------------------

const T = std.testing;
const allocT = std.testing.allocator;
const check = kern.check;
const eqI = T.expectEqual;

fn near(want: f64, got: f64, tol: f64) !void {
    try T.expectApproxEqAbs(want, got, tol);
}
fn hasPoint(r: PMesh, q: V3) bool {
    for (r.verts) |p| {
        if (@abs(p[0] - q[0]) < 1e-5 and @abs(p[1] - q[1]) < 1e-5 and @abs(p[2] - q[2]) < 1e-5) return true;
    }
    return false;
}

test "cube, level 1: the Catmull-Clark rules" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const r = try subdivide(allocT, c, 1);
    defer r.deinit(allocT);
    try eqI(@as(usize, 26), r.verts.len); // V + E + F
    try eqI(@as(usize, 24), r.faces());
    try eqI(@as(usize, 96), r.loops.len);
    try T.expect(try check.closed(r));
    try T.expect(check.outward(r));
    try eqI(@as(i64, 2), try check.euler(r));
    const s = 5.0 / 9.0; // corner: (1/3 + 2 * 2/3 + 0) / 3
    try T.expect(hasPoint(r, .{ s, s, s }));
    try T.expect(hasPoint(r, .{ -s, s, -s }));
    try T.expect(hasPoint(r, .{ 0.75, 0.75, 0 })); // edge: (2 + 0 + 1) / 4
    try T.expect(hasPoint(r, .{ 1, 0, 0 })); // face
    // a corner stays first in its quad, face points third
    for (0..24) |f| try T.expect(r.poly(f)[2] >= 8 + 12);
}

test "cube, levels up to 6, as the binary gives them" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const two = try subdivide(allocT, c, 2);
    defer two.deinit(allocT);
    try eqI(@as(usize, 98), two.verts.len);
    try eqI(@as(usize, 96), two.faces());
    try near(0.8784722, check.box(two)[1][1], 1e-6);
    try near(2.800938 * 2.0, check.volume(two) * 2.0, 2e-4); // (and it faces outward)
    var last = check.volume(c);
    for (1..7) |l| {
        const r = try subdivide(allocT, c, @intCast(l));
        defer r.deinit(allocT);
        const n = @as(usize, 6) << @intCast(2 * l);
        try eqI(n, r.faces());
        try eqI(n + 2, r.verts.len);
        try T.expect(try check.closed(r));
        const v = check.volume(r);
        try T.expect(v < last and v > 2);
        last = v;
        // symmetric: x -> -x maps the vertices onto themselves
        const b = check.box(r);
        try eqI(b[1][0], -b[0][0]);
    }
    const nine = try subdivide(allocT, c, 9); // clamps to 6
    defer nine.deinit(allocT);
    try eqI(@as(usize, 6 << 12), nine.faces());
}

test "level 0 is the input" {
    const t = try check.tri(allocT);
    defer t.deinit(allocT);
    const r = try subdivide(allocT, t, 0);
    defer r.deinit(allocT);
    try T.expectEqualSlices(V3, t.verts, r.verts);
    try T.expectEqualSlices(u32, t.loops, r.loops);
    const p = try plan(allocT, t, 0);
    defer freePlan(allocT, p);
    const r2 = try eval(p, allocT, t.verts);
    defer r2.deinit(allocT);
    try T.expectEqualSlices(u32, t.poff, r2.poff);
}

test "open meshes: boundaries follow the curve rule" {
    const q = try check.plane(allocT);
    defer q.deinit(allocT);
    const r = try subdivide(allocT, q, 1);
    defer r.deinit(allocT);
    try eqI(@as(usize, 9), r.verts.len);
    try eqI(@as(usize, 4), r.faces());
    try T.expect(hasPoint(r, .{ -0.75, 0, -0.75 })); // (6 S + a + b) / 8
    try T.expect(hasPoint(r, .{ 1, 0, 0 })); // midpoint
    try T.expect(hasPoint(r, .{ 0, 0, 0 })); // face point
    const t = try check.tri(allocT);
    defer t.deinit(allocT);
    const r2 = try subdivide(allocT, t, 1);
    defer r2.deinit(allocT);
    try eqI(@as(usize, 7), r2.verts.len);
    try eqI(@as(usize, 3), r2.faces());
    for (r2.verts) |p| try eqI(@as(f32, 0), p[1]);
    try T.expect(hasPoint(r2, .{ 0, 0, 0.5 })); // face point
    const r3 = try subdivide(allocT, t, 3); // n-gons only at the first level
    defer r3.deinit(allocT);
    try eqI(@as(usize, 48), r3.faces());
}

test "valence: 255 moves, from 256 on a vertex stays" {
    for ([_]u32{ 255, 256, 300 }) |n| {
        // a cone of n triangles around its tip
        const v = try allocT.alloc(V3, n + 1);
        defer allocT.free(v);
        const o = try allocT.alloc(u32, n + 1);
        defer allocT.free(o);
        const l = try allocT.alloc(u32, n * 3);
        defer allocT.free(l);
        v[n] = .{ 0, 2, 0 };
        for (0..n) |i| {
            const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * 6.2831855;
            v[i] = .{ @cos(u), 0, @sin(u) };
            o[i] = @intCast(i * 3);
            l[i * 3] = n;
            l[i * 3 + 1] = @intCast((i + 1) % n);
            l[i * 3 + 2] = @intCast(i);
        }
        o[n] = n * 3;
        const c = PMesh{ .verts = v, .poff = o, .loops = l };
        const r = try subdivide(allocT, c, 1);
        defer r.deinit(allocT);
        try eqI(@as(usize, n * 3), r.faces());
        try eqI(@as(usize, n + 1 + 2 * n + n), r.verts.len);
        const tip = r.verts[n][1];
        if (n >= 256) try eqI(@as(f32, 2), tip) else try T.expect(tip < 1.99);
    }
}

test "a plan re-evaluates to what a new one gives" {
    const t = try check.torus(allocT, 24, 12);
    defer t.deinit(allocT);
    const p = try plan(allocT, t, 3);
    defer freePlan(allocT, p);
    const r0 = try eval(p, allocT, t.verts);
    defer r0.deinit(allocT);
    try T.expect(try check.closed(r0));
    try eqI(@as(i64, 0), try check.euler(r0));
    t.verts[5] = m.add(t.verts[5], .{ 0.3, 0.2, -0.1 });
    t.verts[100] = m.scale(t.verts[100], 1.2);
    const r1 = try eval(p, allocT, t.verts);
    defer r1.deinit(allocT);
    const fresh = try subdivide(allocT, t, 3);
    defer fresh.deinit(allocT);
    try T.expectEqualSlices(V3, fresh.verts, r1.verts);
    try T.expectEqualSlices(u32, fresh.loops, r1.loops);
    try T.expectEqualSlices(u32, fresh.poff, r1.poff);
    try T.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(r0.verts), std.mem.sliceAsBytes(r1.verts)));
    const buf = try allocT.alloc(V3, p.out_verts);
    defer allocT.free(buf);
    try evalInto(p, t.verts, buf);
    try T.expectEqualSlices(V3, fresh.verts, buf);
    try T.expectError(error.BadMesh, eval(p, allocT, t.verts[1..]));
}

test "the plan does not lean on its input" {
    const c = try pmesh.testCube(allocT);
    const p = try plan(allocT, c, 2);
    defer freePlan(allocT, p);
    const v = try allocT.dupe(V3, c.verts);
    defer allocT.free(v);
    c.deinit(allocT);
    const r = try eval(p, allocT, v);
    defer r.deinit(allocT);
    try T.expect(try check.closed(r));
}

test "threads give what one thread gives" {
    const t = try check.torus(allocT, 64, 64); // past the job grain
    defer t.deinit(allocT);
    const one = try subdivide(allocT, t, 3); // (workers not started yet)
    defer one.deinit(allocT);
    if (jobs.count() != 1) return error.SkipZigTest;
    jobs.init();
    const r = try subdivide(allocT, t, 3);
    defer r.deinit(allocT);
    try T.expectEqualSlices(V3, one.verts, r.verts);
    try T.expectEqualSlices(u32, one.loops, r.loops);
}

test "degenerate inputs" {
    const makers = [_]*const fn (Allocator) anyerror!PMesh{ check.empty, check.tri, check.plane, check.nonManifold, check.odd };
    for (makers) |mk| {
        const p = try mk(allocT);
        defer p.deinit(allocT);
        for (0..5) |l| {
            const r = try subdivide(allocT, p, @intCast(l));
            defer r.deinit(allocT);
            for (r.loops) |x| try T.expect(x < r.verts.len);
            try eqI(r.loops.len, @as(usize, r.poff[r.faces()]));
        }
    }
    const none = PMesh{ .verts = &.{}, .poff = &.{}, .loops = &.{} };
    const r = try subdivide(allocT, none, 2);
    defer r.deinit(allocT);
    try eqI(@as(usize, 0), r.verts.len);
    // vertices without polygons pass through
    const v = [_]V3{.{ 1, 2, 3 }};
    const r2 = try subdivide(allocT, .{ .verts = @constCast(&v), .poff = &.{}, .loops = &.{} }, 2);
    defer r2.deinit(allocT);
    try eqI(V3{ 1, 2, 3 }, r2.verts[0]);
}

test "non-manifold edges subdivide, bad indices are refused" {
    const n = try check.nonManifold(allocT);
    defer n.deinit(allocT);
    const r = try subdivide(allocT, n, 2);
    defer r.deinit(allocT);
    try eqI(@as(usize, 36), r.faces());
    var o = [_]u32{ 0, 3 };
    var l = [_]u32{ 0, 1, 9 };
    const v = [_]V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    try T.expectError(error.BadMesh, subdivide(allocT, .{ .verts = @constCast(&v), .poff = &o, .loops = &l }, 1));
}

test "blow-ups are refused before allocating" {
    const t = try check.torus(allocT, 200, 100); // 80k loops: level 6 passes 2^28
    defer t.deinit(allocT);
    try T.expectError(error.TooBig, subdivide(allocT, t, 6));
    var fail = std.testing.FailingAllocator.init(allocT, .{ .fail_index = 3 }); // input copies + plan only
    try T.expectError(error.TooBig, plan(fail.allocator(), t, 6));
}

fn planAndEval(a: Allocator, in: PMesh) !void {
    const p = try plan(a, in, 2);
    defer freePlan(a, p);
    (try eval(p, a, in.verts)).deinit(a);
}

test "running out of memory leaks nothing" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    try T.checkAllAllocationFailures(allocT, planAndEval, .{c});
}
