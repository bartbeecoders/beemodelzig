//! The mesh work of the feature tree (feature.s and its helpers): a finished
//! mesh as the original keeps one (positions, polygons, the bounds over every
//! position, used or not), and the passes features run on bodies, each ported
//! step for step so the results are the original's to the bit:
//!   flatMerge   mesh_flat_merge (meshops.s): neighbouring faces in one plane
//!               become one polygon again
//!   dropFlats   mesh_drop_flats (meshops.s): flat triangles go into the
//!               polygon across their long edge
//!   clean       mesh_clean (repair.s): welded, degenerate and duplicate faces
//!               gone, holes filled, consistently oriented, facing out
//!   manifold    mesh_manifold (bool.s)
//!   compact     mesh_compact (meshops.s)
//!   append      mesh_append (sdf.s)
//! Every function leaves its input alone and allocates the result with `a`.
const std = @import("std");
const m = @import("math.zig");
const pmesh = @import("pmesh.zig");

pub const V3 = m.V3;
pub const PMesh = pmesh.PMesh;
const Allocator = std.mem.Allocator;

/// The scratch polygon's size (SCR_MAX in meshops.s).
const SCR_MAX = 65536;

/// A finished mesh: its arrays and the bounds of all its positions.
pub const M = struct {
    verts: []V3,
    poff: []u32,
    loops: []u32,
    bmin: V3,
    bmax: V3,

    pub fn faces(x: *const M) usize {
        return if (x.poff.len == 0) 0 else x.poff.len - 1;
    }
    pub fn poly(x: *const M, i: usize) []const u32 {
        return x.loops[x.poff[i]..x.poff[i + 1]];
    }
    pub fn deinit(x: *const M, a: Allocator) void {
        a.free(x.verts);
        a.free(x.poff);
        a.free(x.loops);
    }
    pub fn clone(x: *const M, a: Allocator) !M {
        const v = try a.dupe(V3, x.verts);
        errdefer a.free(v);
        const o = try a.dupe(u32, x.poff);
        errdefer a.free(o);
        return .{ .verts = v, .poff = o, .loops = try a.dupe(u32, x.loops), .bmin = x.bmin, .bmax = x.bmax };
    }
    pub fn asP(x: *const M) PMesh {
        return .{ .verts = x.verts, .poff = x.poff, .loops = x.loops };
    }
};

/// minss / maxss: the second operand when either is NaN.
fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

/// mesh_bbox: over all positions (none: 1e30 .. -1e30).
pub fn bbox(verts: []const V3) [2]V3 {
    var lo: V3 = .{ 1.0e30, 1.0e30, 1.0e30 };
    var hi: V3 = .{ -1.0e30, -1.0e30, -1.0e30 };
    for (verts) |p| {
        for (0..3) |c| {
            lo[c] = minss(lo[c], p[c]);
            hi[c] = maxss(hi[c], p[c]);
        }
    }
    return .{ lo, hi };
}

/// A finished mesh of these arrays (taken over, not copied).
pub fn finish(verts: []V3, poff: []u32, loops: []u32) M {
    const b = bbox(verts);
    return .{ .verts = verts, .poff = poff, .loops = loops, .bmin = b[0], .bmax = b[1] };
}

/// From a PMesh (taken over).
pub fn fromP(p: PMesh) M {
    return finish(p.verts, p.poff, p.loops);
}

/// A mesh under construction (mesh_new, mesh_add_vert, mesh_add_poly).
pub const Builder = struct {
    a: Allocator,
    verts: std.ArrayList(V3) = .empty,
    poff: std.ArrayList(u32) = .empty,
    loops: std.ArrayList(u32) = .empty,

    pub fn init(a: Allocator) !Builder {
        var b = Builder{ .a = a };
        try b.poff.append(a, 0);
        return b;
    }
    pub fn deinit(b: *Builder) void {
        b.verts.deinit(b.a);
        b.poff.deinit(b.a);
        b.loops.deinit(b.a);
    }
    pub fn vert(b: *Builder, p: V3) !u32 {
        try b.verts.append(b.a, p);
        return @intCast(b.verts.items.len - 1);
    }
    pub fn poly(b: *Builder, idx: []const u32) !void {
        try b.loops.appendSlice(b.a, idx);
        try b.poff.append(b.a, @intCast(b.loops.items.len));
    }
    pub fn npolys(b: *const Builder) usize {
        return b.poff.items.len - 1;
    }
    /// mesh_finish: the arrays handed over as a finished mesh.
    pub fn done(b: *Builder) !M {
        const v = try b.verts.toOwnedSlice(b.a);
        errdefer b.a.free(v);
        const o = try b.poff.toOwnedSlice(b.a);
        errdefer b.a.free(o);
        const l = try b.loops.toOwnedSlice(b.a);
        return finish(v, o, l);
    }
};

// ---- the edge hash (eh_new / eh_slot / eh_get) -----------------------------------

pub const Hash = struct {
    mask: u64,
    keys: []u64, // key + 1; 0: empty
    vals: []u32,

    /// eh_new(expected): a power of two >= 2 expected (16 at least).
    pub fn init(t: Allocator, expected: usize) !Hash {
        var n: usize = 16;
        while (n < expected *% 2 and n < (1 << 40)) n *= 2;
        const keys = try t.alloc(u64, n);
        @memset(keys, 0);
        const vals = try t.alloc(u32, n);
        @memset(vals, 0);
        return .{ .mask = n - 1, .keys = keys, .vals = vals };
    }
    fn home(h: *const Hash, k: u64) usize {
        return @intCast(((k *% 0x2545f491) >> 13) & h.mask);
    }
    /// eh_slot: the value's place (a new key gets -1) and whether it existed.
    pub fn slot(h: *Hash, key: u64) struct { val: *u32, existed: bool } {
        const k = key +% 1;
        var i = h.home(k);
        while (true) {
            const c = h.keys[i];
            if (c == 0) {
                h.keys[i] = k;
                h.vals[i] = 0xffffffff;
                return .{ .val = &h.vals[i], .existed = false };
            }
            if (c == k) return .{ .val = &h.vals[i], .existed = true };
            i = (i + 1) & @as(usize, @intCast(h.mask));
        }
    }
    /// eh_get / an_get with the key: the value, or -1 as i32.
    pub fn get(h: *const Hash, key: u64) i32 {
        const k = key +% 1;
        var i = h.home(k);
        while (true) {
            const c = h.keys[i];
            if (c == 0) return -1;
            if (c == k) return @bitCast(h.vals[i]);
            i = (i + 1) & @as(usize, @intCast(h.mask));
        }
    }
};

pub fn dkey(a: u32, b: u32) u64 {
    return (@as(u64, a) << 32) | b;
}
pub fn ukey(a: u32, b: u32) u64 {
    return if (a <= b) dkey(a, b) else dkey(b, a);
}

/// edge_faces: undirected edges numbered as first met; the first two polygons
/// and how many use each.
pub const EdgeFaces = struct {
    tab: Hash,
    f1: []i32,
    f2: []i32,
    cnt: []u32,
    n: u32,

    pub fn build(t: Allocator, x: *const M) !EdgeFaces {
        const nl = x.loops.len;
        var e = EdgeFaces{ .tab = try Hash.init(t, nl), .f1 = try t.alloc(i32, nl), .f2 = try t.alloc(i32, nl), .cnt = try t.alloc(u32, nl), .n = 0 };
        @memset(e.f1, -1);
        @memset(e.f2, -1);
        @memset(e.cnt, 0);
        for (0..x.faces()) |p| {
            const idx = x.poly(p);
            for (idx, 0..) |a, i| {
                const b = idx[if (i + 1 < idx.len) i + 1 else 0];
                const r = e.tab.slot(ukey(a, b));
                if (!r.existed) {
                    r.val.* = e.n;
                    e.n += 1;
                }
                const c = r.val.*;
                e.cnt[c] += 1;
                if (e.f1[c] == -1) {
                    e.f1[c] = @intCast(p);
                } else if (e.f2[c] == -1) {
                    e.f2[c] = @intCast(p);
                }
            }
        }
        return e;
    }
    /// ef_find: the slot of edge (a, b), or -1.
    pub fn find(e: *const EdgeFaces, a: u32, b: u32) i32 {
        return e.tab.get(ukey(a, b));
    }
};

/// poly_normal: Newell, area weighted.
pub fn newell(verts: []const V3, idx: []const u32) V3 {
    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;
    for (idx, 0..) |vi, i| {
        const c = verts[vi];
        const n = verts[idx[if (i + 1 < idx.len) i + 1 else 0]];
        x += (c[1] - n[1]) * (c[2] + n[2]);
        y += (c[2] - n[2]) * (c[0] + n[0]);
        z += (c[0] - n[0]) * (c[1] + n[1]);
    }
    return .{ x, y, z };
}

/// normalize (meshops.s): unchanged when about zero.
pub fn normalize(v: V3) V3 {
    var l2 = v[0] * v[0];
    l2 += v[1] * v[1];
    l2 += v[2] * v[2];
    if (!(l2 > 1.0e-12)) return v;
    const inv = 1.0 / @sqrt(l2);
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

// ---- mesh_manifold / mesh_compact / mesh_append -----------------------------------

/// mesh_manifold: every edge used once in each direction.
pub fn manifold(a: Allocator, x: *const M) !bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var h = try Hash.init(arena.allocator(), x.loops.len);
    for (0..2) |pass| {
        for (0..x.faces()) |p| {
            const l = x.poly(p);
            for (l, 0..) |u, i| {
                const v = l[if (i + 1 < l.len) i + 1 else 0];
                if (pass == 0) {
                    const s = h.slot(dkey(u, v));
                    s.val.* = 0;
                    if (s.existed) return false;
                } else if (h.get(dkey(v, u)) < 0) return false;
            }
        }
    }
    return true;
}

/// mesh_compact: without the positions no polygon uses, in the same order.
pub fn compact(a: Allocator, x: *const M) !M {
    const remap = try a.alloc(u32, x.verts.len);
    defer a.free(remap);
    @memset(remap, std.math.maxInt(u32));
    for (x.loops) |l| remap[l] = 0;
    var n: u32 = 0;
    for (remap) |*r| {
        if (r.* == 0) {
            r.* = n;
            n += 1;
        }
    }
    const v = try a.alloc(V3, n);
    errdefer a.free(v);
    for (x.verts, remap) |p, i| {
        if (i != std.math.maxInt(u32)) v[i] = p;
    }
    const o = try a.dupe(u32, x.poff);
    errdefer a.free(o);
    const l = try a.alloc(u32, x.loops.len);
    for (x.loops, l) |s, *d| d.* = remap[s];
    return finish(v, o, l);
}

/// mesh_append: one mesh holding both (b's vertices after a's).
pub fn append(a: Allocator, x: *const M, y: *const M) !M {
    const nv: u32 = @intCast(x.verts.len);
    const v = try a.alloc(V3, x.verts.len + y.verts.len);
    errdefer a.free(v);
    @memcpy(v[0..x.verts.len], x.verts);
    @memcpy(v[x.verts.len..], y.verts);
    const o = try a.alloc(u32, x.faces() + y.faces() + 1);
    errdefer a.free(o);
    const l = try a.alloc(u32, x.loops.len + y.loops.len);
    @memcpy(o[0..x.poff.len], x.poff);
    for (1..y.poff.len) |k| o[x.faces() + k] = y.poff[k] + @as(u32, @intCast(x.loops.len));
    @memcpy(l[0..x.loops.len], x.loops);
    for (y.loops, 0..) |s, k| l[x.loops.len + k] = s + nv;
    return finish(v, o, l);
}

// ---- mesh_flat_merge -----------------------------------------------------------------

const FLATDOT: f32 = 0.99999;

/// uf_find with path halving.
fn ufFind(par: []u32, x0: u32) u32 {
    var x = x0;
    while (true) {
        const p = par[x];
        if (p == x) return x;
        const g = par[p];
        par[x] = g;
        x = g;
    }
}

/// group_outline: the boundary of the group with root `root` as one loop in
/// scr (its length), or 0 when it is not one simple loop.
fn groupOutline(x: *const M, ef: *const EdgeFaces, roots: []const u32, merged: []const u8, next: []i32, scr: []u32, root: u32) u32 {
    var nb: u32 = 0;
    var start: i32 = -1;
    var pinch = false;
    for (0..x.faces()) |p| {
        if (roots[p] != root) continue;
        const l = x.poly(p);
        for (l, 0..) |a, i| {
            const b = l[if (i + 1 < l.len) i + 1 else 0];
            const e = ef.find(a, b);
            if (e >= 0 and merged[@intCast(e)] != 0) {
                const f1: u32 = @bitCast(ef.f1[@intCast(e)]);
                const f2: u32 = @bitCast(ef.f2[@intCast(e)]);
                if (roots[f1] == root and roots[f2] == root) continue;
            }
            if (next[a] != -1) pinch = true;
            next[a] = @intCast(b);
            start = @intCast(a);
            nb += 1;
        }
    }
    var res: u32 = 0;
    walk: {
        if (pinch or start < 0 or nb > SCR_MAX) break :walk;
        var c: u32 = 0;
        var d: i32 = start;
        while (true) {
            scr[c] = @intCast(d);
            c += 1;
            if (c > nb) break :walk;
            d = next[@intCast(d)];
            if (d < 0) break :walk;
            if (d == start) break;
        }
        if (c != nb or c < 3) break :walk;
        res = c;
    }
    // next[] back to -1 for the next group
    for (0..x.faces()) |p| {
        if (roots[p] != root) continue;
        for (x.poly(p)) |a| next[a] = -1;
    }
    return res;
}

/// mesh_flat_merge: neighbouring faces in one plane merged into one polygon;
/// null when no group merges.
pub fn flatMerge(a: Allocator, x: *const M) !?M {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    const np = x.faces();
    const ef = try EdgeFaces.build(t, x);
    const par = try t.alloc(u32, np);
    for (par, 0..) |*p, i| p.* = @intCast(i);
    const merged = try t.alloc(u8, ef.n + 1);
    @memset(merged, 0);
    const nrm = try t.alloc(V3, np);
    for (0..np) |p| nrm[p] = normalize(newell(x.verts, x.poly(p)));
    for (0..ef.n) |e| {
        if (ef.cnt[e] != 2) continue;
        const p1 = nrm[@intCast(ef.f1[e])];
        const p2 = nrm[@intCast(ef.f2[e])];
        var d = p1[0] * p2[0];
        d += p1[1] * p2[1];
        d += p1[2] * p2[2];
        if (d >= FLATDOT) merged[e] = 1; // (comiss; jb: NaN does not)
    }
    for (0..ef.n) |e| {
        if (merged[e] == 0) continue;
        const r1 = ufFind(par, @bitCast(ef.f1[e]));
        const r2 = ufFind(par, @bitCast(ef.f2[e]));
        if (r1 == r2) continue;
        par[r2] = r1;
    }
    const size = try t.alloc(u32, np);
    @memset(size, 0);
    for (0..np) |p| {
        const r = ufFind(par, @intCast(p));
        par[p] = r;
        size[r] += 1;
    }
    const next = try t.alloc(i32, x.verts.len);
    @memset(next, -1);
    const scr = try t.alloc(u32, SCR_MAX + 1);
    for (0..np) |p| {
        if (par[p] != p or size[p] <= 1) continue;
        if (groupOutline(x, &ef, par, merged, next, scr, @intCast(p)) == 0) size[p] = 1;
    }
    var b = try Builder.init(a);
    defer b.deinit();
    try b.verts.appendSlice(a, x.verts);
    var groups: u32 = 0;
    for (0..np) |p| {
        const r = par[p];
        if (size[r] <= 1) {
            try b.poly(x.poly(p));
            continue;
        }
        if (r != p) continue;
        const n = groupOutline(x, &ef, par, merged, next, scr, r);
        if (n == 0) continue;
        try b.poly(scr[0..n]);
        groups += 1;
    }
    if (groups == 0) return null;
    return try b.done();
}

// ---- mesh_drop_flats -------------------------------------------------------------------

const FLAT2: f32 = 1.0e-12;

/// tri_flat: the slot of the corner lying between the other two, or -1.
fn triFlat(verts: []const V3, c: [3]u32) i32 {
    const p0 = verts[c[0]];
    const p1 = verts[c[1]];
    const p2 = verts[c[2]];
    const e1 = [3]f32{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
    var e2 = [3]f32{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };
    var x6 = e1[1] * e2[2] - e1[2] * e2[1];
    x6 *= x6;
    var x7 = e1[2] * e2[0] - e1[0] * e2[2];
    x7 *= x7;
    x6 += x7;
    x7 = e1[0] * e2[1] - e1[1] * e2[0];
    x7 *= x7;
    x6 += x7;
    var ab = e1[0] * e1[0];
    ab += e1[1] * e1[1];
    ab += e1[2] * e1[2];
    var ac = e2[0] * e2[0];
    ac += e2[1] * e2[1];
    ac += e2[2] * e2[2];
    for (0..3) |k| {
        e2[k] -= e1[k];
        e2[k] *= e2[k];
    }
    var bc = e2[0] + e2[1];
    bc += e2[2];
    var lg = maxss(ab, ac);
    lg = maxss(lg, bc);
    const lim = lg * lg * FLAT2;
    if (x6 > lim) return -1; // (ja: NaN counts as flat)
    if (!(lg > 0)) return -1;
    if (bc >= lg) return 0;
    if (ac >= lg) return 1;
    return 2;
}

/// mesh_drop_flats: without flat triangles (each goes into the polygon across
/// its long edge, which gets the middle corner); null when there are none.
pub fn dropFlats(a: Allocator, x0: *const M) !?M {
    var res: ?M = null;
    errdefer if (res) |r| r.deinit(a);
    var x = x0.*;
    var pass: u32 = 0;
    while (pass < 8) : (pass += 1) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const t = arena.allocator();
        const np = x.faces();
        var dir = try Hash.init(t, x.loops.len);
        for (0..np) |p| {
            const l = x.poly(p);
            for (l, 0..) |u, i| {
                const v = l[if (i + 1 < l.len) i + 1 else 0];
                dir.slot(dkey(u, v)).val.* = @intCast(p);
            }
        }
        const dead = try t.alloc(u8, np + 8);
        @memset(dead, 0);
        var ins = try Hash.init(t, x.loops.len);
        var taken: u32 = 0;
        for (0..np) |p| {
            const l = x.poly(p);
            if (l.len != 3) continue;
            const c = [3]u32{ l[0], l[1], l[2] };
            const s = triFlat(x.verts, c);
            if (s < 0) continue;
            const k: usize = @intCast(s);
            const mid = c[k];
            const n = c[(k + 1) % 3];
            const q = c[(k + 2) % 3];
            const nb = dir.get(dkey(q, n));
            if (nb < 0) continue;
            if (dead[@intCast(nb)] != 0) continue;
            const r = ins.slot(dkey(q, n));
            if (r.existed) continue;
            r.val.* = mid + 1;
            dead[p] = 1;
            dead[@intCast(nb)] = 2;
            taken += 1;
        }
        if (taken == 0) break;
        var b = try Builder.init(a);
        defer b.deinit();
        try b.verts.appendSlice(a, x.verts);
        const scr = try t.alloc(u32, SCR_MAX);
        for (0..np) |p| {
            if (dead[p] == 1) continue;
            const l = x.poly(p);
            var w: usize = 0;
            var i: usize = 0;
            while (i < l.len) {
                scr[w] = l[i];
                w += 1;
                const v = l[if (i + 1 < l.len) i + 1 else 0];
                const g = ins.get(dkey(l[i], v));
                if (g > 0) {
                    scr[w] = @intCast(g - 1);
                    w += 1;
                }
                i += 1;
                if (w >= SCR_MAX - 4) break;
            }
            try b.poly(scr[0..w]);
        }
        const nm = try b.done();
        if (res) |r| r.deinit(a);
        res = nm;
        x = nm;
    }
    return res;
}

// ---- mesh_clean (repair.s) -------------------------------------------------------------

const CleanCtx = struct {
    t: Allocator,
    x: *const M,
    rep: []u32,
    poff: []u32,
    loops: []u32,
    np: u32 = 0,
    nl: u32 = 0,
    capp: u32,
    capl: u32,
    dead: []u8,
    flip: []u8,

    fn eachEdge(c: *CleanCtx, p: u32, ctx: anytype, comptime f: fn (@TypeOf(ctx), u32, u32) void) void {
        if (c.dead[p] != 0) return;
        const s = c.poff[p];
        const e = c.poff[p + 1];
        var i = s;
        while (i < e) : (i += 1) f(ctx, c.loops[i], c.loops[if (i + 1 < e) i + 1 else s]);
    }
};

fn cellKey(x: i32, y: i32, z: i32) u64 {
    var k: u64 = @as(u32, @bitCast(z)) & 0x1fffff;
    k <<= 21;
    k |= @as(u32, @bitCast(y)) & 0x1fffff;
    k <<= 21;
    k |= @as(u32, @bitCast(x)) & 0x1fffff;
    return k;
}

/// roundss floor then cvtss2si.
fn floorInt(v: f32) i32 {
    const f = @floor(v);
    if (!(f >= -2147483648.0 and f < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(f);
}

fn rpMerge(c: *CleanCtx, dist: f32) !void {
    const x = c.x;
    const nv = x.verts.len;
    c.rep = try c.t.alloc(u32, nv + 2);
    const nxt = try c.t.alloc(i32, nv + 2);
    @memset(nxt, 0);
    var cells = try Hash.init(c.t, nv + 8);
    if (!(dist > 0)) {
        for (0..nv) |i| c.rep[i] = @intCast(i);
        return;
    }
    const inv = 1.0 / dist;
    const d2 = dist * dist;
    for (0..nv) |vi| {
        c.rep[vi] = @intCast(vi);
        const p = x.verts[vi];
        var cell: [3]i32 = undefined;
        for (0..3) |k| cell[k] = floorInt(p[k] * inv);
        var merged = false;
        nb: for (0..27) |kk| {
            const k: u32 = @intCast(kk);
            const dx: i32 = @as(i32, @intCast(k % 3)) - 1;
            const dy: i32 = @as(i32, @intCast((k / 3) % 3)) - 1;
            const dz: i32 = @as(i32, @intCast(k / 9)) - 1;
            var cand = cells.get(cellKey(cell[0] +% dx, cell[1] +% dy, cell[2] +% dz));
            while (cand >= 0) {
                const q = x.verts[@intCast(cand)];
                var d = (q[0] - p[0]) * (q[0] - p[0]);
                d += (q[1] - p[1]) * (q[1] - p[1]);
                d += (q[2] - p[2]) * (q[2] - p[2]);
                if (!(d > d2)) {
                    c.rep[vi] = c.rep[@intCast(cand)];
                    merged = true;
                    break :nb;
                }
                cand = nxt[@intCast(cand)];
            }
        }
        if (merged) continue;
        const r = cells.slot(cellKey(cell[0], cell[1], cell[2]));
        nxt[vi] = @bitCast(r.val.*);
        r.val.* = @intCast(vi);
    }
}

fn areaOk(c: *const CleanCtx, s: u32, e: u32) bool {
    const v = c.x.verts;
    var x0: f32 = 0;
    var x1: f32 = 0;
    var x2: f32 = 0;
    var i = s;
    while (i < e) : (i += 1) {
        const p = v[c.loops[i]];
        const q = v[c.loops[if (i + 1 < e) i + 1 else s]];
        x0 += (p[1] - q[1]) * (p[2] + q[2]);
        x1 += (p[2] - q[2]) * (p[0] + q[0]);
        x2 += (p[0] - q[0]) * (p[1] + q[1]);
    }
    var n2 = x0 * x0;
    n2 += x1 * x1;
    n2 += x2 * x2;
    const bx = c.x.bmax[0] - c.x.bmin[0];
    const by = c.x.bmax[1] - c.x.bmin[1];
    const bz = c.x.bmax[2] - c.x.bmin[2];
    var s2 = bx * bx;
    s2 += by * by;
    s2 += bz * bz;
    s2 *= s2;
    s2 *= 1.0e-20;
    return n2 > s2;
}

fn cyc(c: *const CleanCtx, p: u32, rev: bool) u64 {
    const s = c.poff[p];
    const n = c.poff[p + 1] - s;
    const l = c.loops[s .. s + n];
    var lo: u32 = 0;
    for (0..n) |i| {
        if (l[i] < l[lo]) lo = @intCast(i);
    }
    var h: u64 = 0xcbf29ce484222325 ^ @as(u64, n);
    for (0..n) |dd| {
        const d: u32 = @intCast(dd);
        var k: u32 = if (!rev) lo + d else lo -% d +% n;
        if (k >= n) k -%= n;
        h ^= l[k];
        h *%= 0x100000001b3;
    }
    return h >> 1;
}

fn rpPolys(c: *CleanCtx, nedges: u32) !bool {
    const x = c.x;
    c.capp = @as(u32, @intCast(x.faces())) * 2 + 16 + nedges;
    c.capl = @as(u32, @intCast(x.loops.len)) * 2 + 64;
    c.poff = try c.t.alloc(u32, c.capp + 2);
    @memset(c.poff, 0);
    c.loops = try c.t.alloc(u32, c.capl);
    c.dead = try c.t.alloc(u8, c.capp);
    @memset(c.dead, 0);
    c.flip = try c.t.alloc(u8, c.capp);
    @memset(c.flip, 0);
    for (0..x.faces()) |p| {
        const st = c.nl;
        c.poff[c.np] = st;
        for (x.poly(p)) |vi| {
            const r = c.rep[vi];
            if (c.nl != st and c.loops[c.nl - 1] == r) continue;
            c.loops[c.nl] = r;
            c.nl += 1;
        }
        if (c.nl - st >= 2 and c.loops[c.nl - 1] == c.loops[st]) c.nl -= 1;
        if (c.nl - st < 3 or !areaOk(c, st, c.nl)) {
            c.nl = st;
            continue;
        }
        c.np += 1;
        c.poff[c.np] = c.nl;
    }
    var tab = try Hash.init(c.t, c.np + 8);
    for (0..c.np) |pp| {
        const p: u32 = @intCast(pp);
        const h = cyc(c, p, false);
        const same = tab.get(h);
        if (same >= 0 and c.dead[@intCast(same)] == 0) {
            c.dead[p] = 1;
            continue;
        }
        const opp = tab.get(cyc(c, p, true));
        if (opp >= 0 and c.dead[@intCast(opp)] == 0) {
            c.dead[@intCast(opp)] = 1;
            c.dead[p] = 1;
            continue;
        }
        tab.slot(h).val.* = p;
    }
    return true;
}

const FillCtx = struct {
    c: *CleanCtx,
    tab: *Hash,
    btab: *Hash,
    ba: []u32,
    bb: []u32,
    bnext: []i32,
    bused: []u8,
    nb: u32 = 0,

    fn add(f: *FillCtx, a: u32, b: u32) void {
        const r = f.tab.slot(ukey(a, b));
        if (!r.existed) r.val.* = 0;
        r.val.* +%= 1;
    }
    fn bound(f: *FillCtx, a: u32, b: u32) void {
        if (f.tab.get(ukey(a, b)) != 1) return;
        if (f.nb >= f.c.nl) return;
        const i = f.nb;
        f.ba[i] = a;
        f.bb[i] = b;
        f.nb += 1;
        const r = f.btab.slot(b);
        f.bnext[i] = @bitCast(r.val.*);
        r.val.* = i;
    }
    fn take(f: *FillCtx, v: u32) i32 {
        var e = f.btab.get(v);
        while (e >= 0) {
            const k: usize = @intCast(e);
            if (f.bused[k] == 0) {
                f.bused[k] = 1;
                return @intCast(f.ba[k]);
            }
            e = f.bnext[k];
        }
        return -1;
    }
    fn push(f: *FillCtx, v: u32) bool {
        const c = f.c;
        if (c.nl >= c.capl) return false;
        c.loops[c.nl] = v;
        c.nl += 1;
        return true;
    }
};

fn rpFill(c: *CleanCtx) !bool {
    var tab = try Hash.init(c.t, c.nl + 8);
    var btab = try Hash.init(c.t, c.nl + 8);
    var f = FillCtx{
        .c = c,
        .tab = &tab,
        .btab = &btab,
        .ba = try c.t.alloc(u32, c.nl + 2),
        .bb = try c.t.alloc(u32, c.nl + 2),
        .bnext = try c.t.alloc(i32, c.nl + 2),
        .bused = try c.t.alloc(u8, c.nl + 8),
    };
    @memset(f.bused, 0);
    for (0..c.np) |p| c.eachEdge(@intCast(p), &f, FillCtx.add);
    for (0..c.np) |p| c.eachEdge(@intCast(p), &f, FillCtx.bound);
    var i: u32 = 0;
    while (i < f.nb) : (i += 1) {
        if (f.bused[i] != 0) continue;
        f.bused[i] = 1;
        const base = c.nl;
        const start = f.bb[i];
        if (!f.push(start)) return false;
        var cur = f.ba[i];
        var ok = false;
        while (true) {
            if (cur == start) {
                ok = true;
                break;
            }
            if (!f.push(cur)) return false;
            if (c.nl - base > 100000) break;
            const nx = f.take(cur);
            if (nx < 0) break;
            cur = @intCast(nx);
        }
        if (ok and c.nl - base >= 3 and c.np < c.capp) {
            c.np += 1;
            c.poff[c.np] = c.nl;
            continue;
        }
        c.nl = base;
    }
    return true;
}

const OrientCtx = struct {
    c: *CleanCtx,
    tab: *Hash,
    slots: [][4]i32,
    ns: u32 = 0,
    face: u32 = 0,
    comp: []i32,
    stack: []u32,
    depth: u32 = 0,

    fn add(o: *OrientCtx, a: u32, b: u32) void {
        const r = o.tab.slot(ukey(a, b));
        if (!r.existed) {
            r.val.* = o.ns;
            o.ns += 1;
        }
        const s = &o.slots[r.val.*];
        if (s[0] == -1) {
            s[0] = @intCast(o.face);
            s[1] = @bitCast(a);
        } else if (s[2] == -1) {
            s[2] = @intCast(o.face);
            s[3] = @bitCast(a);
        }
    }
    fn visit(o: *OrientCtx, a: u32, b: u32) void {
        const e = o.tab.get(ukey(a, b));
        if (e < 0) return;
        const s = &o.slots[@intCast(e)];
        var f = s[0];
        var st = s[1];
        if (f == @as(i32, @intCast(o.face))) {
            f = s[2];
            st = s[3];
        }
        if (f < 0) return;
        const nb: usize = @intCast(f);
        if (o.comp[nb] != -1) return;
        o.comp[nb] = o.comp[o.face];
        var fl: u8 = o.c.flip[o.face];
        if (@as(u32, @bitCast(st)) == a) fl ^= 1;
        o.c.flip[nb] = fl;
        o.stack[o.depth] = @intCast(nb);
        o.depth += 1;
    }
};

fn rpVolume(c: *const CleanCtx, p: u32) f64 {
    const v = c.x.verts;
    const s = c.poff[p];
    const e = c.poff[p + 1];
    const a = v[c.loops[s]];
    var vol: f64 = 0;
    var d = s + 1;
    while (d + 1 < e) : (d += 1) {
        const p1 = v[c.loops[d]];
        const p2 = v[c.loops[d + 1]];
        const f = struct {
            fn f(x: f32) f64 {
                return @floatCast(x);
            }
        }.f;
        var x1 = f(p1[1]) * f(p2[2]);
        x1 -= f(p1[2]) * f(p2[1]);
        x1 *= f(a[0]);
        var x4 = f(p1[2]) * f(p2[0]);
        x4 -= f(p1[0]) * f(p2[2]);
        x4 *= f(a[1]);
        x1 += x4;
        x4 = f(p1[0]) * f(p2[1]);
        x4 -= f(p1[1]) * f(p2[0]);
        x4 *= f(a[2]);
        x1 += x4;
        vol += x1;
    }
    if (c.flip[p] != 0) vol = 0.0 - vol;
    return vol;
}

fn rpOrient(c: *CleanCtx) !bool {
    var tab = try Hash.init(c.t, c.nl + 8);
    const slots = try c.t.alloc([4]i32, c.nl + 1);
    @memset(slots, .{ -1, -1, -1, -1 });
    const comp = try c.t.alloc(i32, c.np + 2);
    @memset(comp, -1);
    var o = OrientCtx{ .c = c, .tab = &tab, .slots = slots, .comp = comp, .stack = try c.t.alloc(u32, c.np + 2) };
    for (0..c.np) |p| {
        o.face = @intCast(p);
        c.eachEdge(@intCast(p), &o, OrientCtx.add);
    }
    var nc: i32 = 0;
    for (0..c.np) |seed| {
        if (c.dead[seed] != 0 or comp[seed] != -1) continue;
        comp[seed] = nc;
        nc += 1;
        o.stack[0] = @intCast(seed);
        var depth: u32 = 1;
        while (depth > 0) {
            depth -= 1;
            const f = o.stack[depth];
            o.face = f;
            o.depth = depth;
            c.eachEdge(f, &o, OrientCtx.visit);
            depth = o.depth;
        }
    }
    const vol = try c.t.alloc(f64, @as(usize, @intCast(nc)) + 2);
    @memset(vol, 0);
    for (0..c.np) |p| {
        if (c.dead[p] != 0) continue;
        const k: usize = @intCast(comp[p]);
        vol[k] = rpVolume(c, @intCast(p)) + vol[k];
    }
    for (0..c.np) |p| {
        if (c.dead[p] != 0) continue;
        if (!(vol[@intCast(comp[p])] >= 0)) c.flip[p] ^= 1;
    }
    return true;
}

/// mesh_clean: a repaired copy (positions within 1e-4 of the size welded,
/// degenerate and duplicate faces gone, holes filled, oriented outwards,
/// compacted), or null.
pub fn clean(a: Allocator, x: *const M) !?M {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    var sz = x.bmax[0] - x.bmin[0];
    sz = maxss(sz, x.bmax[1] - x.bmin[1]);
    sz = maxss(sz, x.bmax[2] - x.bmin[2]);
    const dist = sz * 1.0e-4;
    var c = CleanCtx{ .t = t, .x = x, .rep = &.{}, .poff = &.{}, .loops = &.{}, .capp = 0, .capl = 0, .dead = &.{}, .flip = &.{} };
    try rpMerge(&c, dist);
    const ef = try EdgeFaces.build(t, x); // (ME_NEDGES: the mesh's unique edges)
    if (!try rpPolys(&c, ef.n)) return null;
    if (!try rpFill(&c)) return null;
    if (!try rpOrient(&c)) return null;
    // rp_build: every position, the live polygons (flipped ones reversed)
    var b = try Builder.init(t);
    try b.verts.appendSlice(t, x.verts);
    for (0..c.np) |p| {
        if (c.dead[p] != 0) continue;
        const l = c.loops[c.poff[p]..c.poff[p + 1]];
        if (l.len > SCR_MAX) continue;
        if (c.flip[p] == 0) {
            try b.poly(l);
        } else {
            const r = try t.dupe(u32, l);
            std.mem.reverse(u32, r);
            try b.poly(r);
        }
    }
    const built = try b.done();
    return try compact(a, &built);
}

/// mesh_merge_dist (repair.s): vertices within `dist` welded into the first
/// one within it, corners that repeat and faces without area dropped,
/// duplicates dropped, unused vertices gone; null when it fails (geometry
/// nodes' Merge by Distance). The arrays are borrowed.
pub fn mergeDist(a: Allocator, verts: []const V3, poff: []const u32, loops: []const u32, dist: f32) !?M {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    const b = bbox(verts);
    const x = M{ .verts = @constCast(verts), .poff = @constCast(poff), .loops = @constCast(loops), .bmin = b[0], .bmax = b[1] };
    var c = CleanCtx{ .t = t, .x = &x, .rep = &.{}, .poff = &.{}, .loops = &.{}, .capp = 0, .capl = 0, .dead = &.{}, .flip = &.{} };
    try rpMerge(&c, dist);
    const ef = try EdgeFaces.build(t, &x); // (ME_NEDGES: the mesh's unique edges)
    if (!try rpPolys(&c, ef.n)) return null;
    // rp_build: every position, the live polygons (flipped ones reversed)
    var bl = try Builder.init(t);
    try bl.verts.appendSlice(t, verts);
    for (0..c.np) |p| {
        if (c.dead[p] != 0) continue;
        const l = c.loops[c.poff[p]..c.poff[p + 1]];
        if (l.len > SCR_MAX) continue;
        if (c.flip[p] == 0) {
            try bl.poly(l);
        } else {
            const r = try t.dupe(u32, l);
            std.mem.reverse(u32, r);
            try bl.poly(r);
        }
    }
    const built = try bl.done();
    return try compact(a, &built);
}

// ---- tests ------------------------------------------------------------------------------

fn testCube(a: Allocator) !M {
    return fromP(try pmesh.testCube(a));
}

test "manifold, compact, append" {
    const a = std.testing.allocator;
    const c = try testCube(a);
    defer c.deinit(a);
    try std.testing.expect(try manifold(a, &c));
    const two = try append(a, &c, &c);
    defer two.deinit(a);
    try std.testing.expectEqual(@as(usize, 16), two.verts.len);
    try std.testing.expectEqual(@as(usize, 12), two.faces());
    try std.testing.expect(try manifold(a, &two));
    // an open cube is not manifold
    var o = c;
    o.poff = c.poff[0..6];
    o.loops = c.loops[0..20];
    try std.testing.expect(!try manifold(a, &o));
    const k = try compact(a, &o);
    defer k.deinit(a);
    try std.testing.expectEqual(@as(usize, 8), k.verts.len);
}

test "flat merge: a cube cut into triangles is six quads again" {
    const a = std.testing.allocator;
    const c = try testCube(a);
    defer c.deinit(a);
    var b = try Builder.init(a);
    defer b.deinit();
    try b.verts.appendSlice(a, c.verts);
    for (0..c.faces()) |p| {
        const l = c.poly(p);
        try b.poly(&.{ l[0], l[1], l[2] });
        try b.poly(&.{ l[0], l[2], l[3] });
    }
    const tri = try b.done();
    defer tri.deinit(a);
    const r = (try flatMerge(a, &tri)).?;
    defer r.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), r.faces());
    try std.testing.expect(try manifold(a, &r));
    try std.testing.expect(try flatMerge(a, &r) == null);
}

test "clean: a welded, reoriented cube" {
    const a = std.testing.allocator;
    var c = try testCube(a);
    defer c.deinit(a);
    // one face inside out, a duplicate vertex
    std.mem.reverse(u32, c.loops[0..4]);
    const r = (try clean(a, &c)).?;
    defer r.deinit(a);
    try std.testing.expect(try manifold(a, &r));
    try std.testing.expectEqual(@as(usize, 6), r.faces());
    try std.testing.expect(try dropFlats(a, &r) == null);
}
