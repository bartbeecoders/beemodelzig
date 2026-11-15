//! The geometry of the mesh modifiers, ported from the original's mods.s,
//! mods2.s and meshops2.s (build_bevel): mirror, array, solidify, bevel,
//! decimate, remesh. Pure: each takes a PMesh, leaves it alone and allocates
//! its result with `a`. Float operations keep the assembly's order, so results
//! match the original to the bit. What the original returns as "0, unchanged" is
//! a clone here. Subdivision: subsurf.zig.
//!
//! One deliberate difference: the original sizes its output for 4 loops per input
//! loop, too few for solidify's rims on mostly open meshes and for bevel's
//! patches around some non-manifold vertices, and mesh_finish's edge list then
//! overwrites the last polygons. Here those polygons come out whole.
const std = @import("std");
const m = @import("math.zig");
const pmesh = @import("pmesh.zig");
const PMesh = pmesh.PMesh;
const V3 = m.V3;
const Allocator = std.mem.Allocator;

pub const Error = error{ TooBig, BadMesh, OutOfMemory };

/// Output limits: past these a modifier gives error.TooBig (the original would
/// overflow its 32-bit sizes or run out of address space).
pub const max_verts: usize = 1 << 27;
pub const max_loops: usize = 1 << 28;

// ---- the arithmetic of the assembly ------------------------------------------

/// minss / maxss: the second operand when either is NaN.
pub fn fmin(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
pub fn fmax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
/// mod_param_set's clamp (NaN becomes lo).
pub fn clampF(v: f32, lo: f32, hi: f32) f32 {
    return fmin(fmax(v, lo), hi);
}
/// cvttss2si: what does not fit (and NaN) is the "indefinite" integer.
fn cvtt(x: f32) i32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}
fn fi(x: anytype) f32 {
    return @floatFromInt(x);
}
/// normalize in meshops.s: unchanged when about zero.
fn normalize(v: V3) V3 {
    const l2 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
    if (!(l2 > 1.0e-12)) return v;
    const inv = 1.0 / @sqrt(l2);
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}
fn vlen(v: V3) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

// ---- the input, checked ------------------------------------------------------

/// A PMesh whose indices are known good; `loops` ends at the last polygon.
pub const Mesh = struct {
    verts: []const V3,
    poff: []const u32,
    loops: []const u32,
    f: u32,
    l: u32,

    pub fn v(s: Mesh) u32 {
        return @intCast(s.verts.len);
    }
    fn poly(s: Mesh, i: usize) []const u32 {
        return s.loops[s.poff[i]..s.poff[i + 1]];
    }
};

/// Refuses what would index out of bounds (error.BadMesh); anything else is
/// geometry, however odd. Sizes past the limits are error.TooBig.
pub fn view(in: PMesh) Error!Mesh {
    if (in.verts.len > max_verts) return error.TooBig;
    const f = in.faces();
    if (f == 0) return .{ .verts = in.verts, .poff = &.{}, .loops = &.{}, .f = 0, .l = 0 };
    if (in.poff[0] != 0) return error.BadMesh;
    var prev: u32 = 0;
    for (in.poff[1..]) |o| {
        if (o < prev) return error.BadMesh;
        prev = o;
    }
    if (prev > in.loops.len) return error.BadMesh;
    if (prev > max_loops) return error.TooBig;
    const loops = in.loops[0..prev];
    const nv: u32 = @intCast(in.verts.len);
    for (loops) |x| if (x >= nv) return error.BadMesh;
    return .{ .verts = in.verts, .poff = in.poff, .loops = loops, .f = @intCast(f), .l = prev };
}

/// mesh_bbox: over all vertices, used or not.
fn bbox(verts: []const V3) [2]V3 {
    var lo: V3 = .{ 1.0e30, 1.0e30, 1.0e30 };
    var hi: V3 = .{ -1.0e30, -1.0e30, -1.0e30 };
    for (verts) |p| {
        for (0..3) |c| {
            lo[c] = fmin(lo[c], p[c]);
            hi[c] = fmax(hi[c], p[c]);
        }
    }
    return .{ lo, hi };
}

/// poly_normal: Newell, area weighted.
fn newell(verts: []const V3, idx: []const u32) V3 {
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

// ---- edge hash (eh_new, eh_slot, ef_find) ---------------------------------------

const Hash = struct {
    mask: u64,
    keys: []u64, // key + 1, 0: empty
    vals: []u32,

    fn init(t: Allocator, expected: usize) !Hash {
        var n: usize = 16;
        while (n < expected * 2) n *= 2;
        const keys = try t.alloc(u64, n);
        @memset(keys, 0);
        return .{ .mask = n - 1, .keys = keys, .vals = try t.alloc(u32, n) };
    }
    fn clear(h: Hash) void {
        @memset(h.keys, 0);
    }
    fn home(h: Hash, k: u64) usize {
        return @intCast(((k *% 0x2545f491) >> 13) & h.mask);
    }
    /// The value's place; a new key gets `fresh` and existed = false.
    fn slot(h: Hash, key: u64, fresh: u32) struct { val: *u32, existed: bool } {
        const k = key + 1;
        var i = h.home(k);
        while (true) {
            const c = h.keys[i];
            if (c == 0) {
                h.keys[i] = k;
                h.vals[i] = fresh;
                return .{ .val = &h.vals[i], .existed = false };
            }
            if (c == k) return .{ .val = &h.vals[i], .existed = true };
            i = (i + 1) & @as(usize, @intCast(h.mask));
        }
    }
    fn get(h: Hash, key: u64) ?u32 {
        const k = key + 1;
        var i = h.home(k);
        while (true) {
            const c = h.keys[i];
            if (c == 0) return null;
            if (c == k) return h.vals[i];
            i = (i + 1) & @as(usize, @intCast(h.mask));
        }
    }
};

fn dkey(a: u32, b: u32) u64 {
    return (@as(u64, a) << 32) | b;
}
fn ukey(a: u32, b: u32) u64 {
    return if (a <= b) dkey(a, b) else dkey(b, a);
}

/// edge_faces: undirected edges numbered as first met, which is also the order
/// of mesh_finish's edge list.
const EdgeTab = struct {
    hash: Hash,
    lo: []u32,
    hi: []u32,
    f1: []i32,
    f2: []i32,
    cnt: []u32,
    n: u32,

    fn build(t: Allocator, s: Mesh) !EdgeTab {
        const hash = try Hash.init(t, s.l);
        const e = EdgeTab{
            .hash = hash,
            .lo = try t.alloc(u32, s.l),
            .hi = try t.alloc(u32, s.l),
            .f1 = try t.alloc(i32, s.l),
            .f2 = try t.alloc(i32, s.l),
            .cnt = try t.alloc(u32, s.l),
            .n = 0,
        };
        @memset(e.f1, -1);
        @memset(e.f2, -1);
        @memset(e.cnt, 0);
        var n: u32 = 0;
        for (0..s.f) |p| {
            const idx = s.poly(p);
            for (idx, 0..) |a, i| {
                const b = idx[if (i + 1 < idx.len) i + 1 else 0];
                const r = hash.slot(ukey(a, b), n);
                const c = r.val.*;
                if (!r.existed) {
                    e.lo[c] = @min(a, b);
                    e.hi[c] = @max(a, b);
                    n += 1;
                }
                e.cnt[c] += 1;
                if (e.f1[c] == -1) {
                    e.f1[c] = @intCast(p);
                } else if (e.f2[c] == -1) {
                    e.f2[c] = @intCast(p);
                }
            }
        }
        var res = e;
        res.n = n;
        return res;
    }
    fn find(e: *const EdgeTab, a: u32, b: u32) ?u32 {
        return e.hash.get(ukey(a, b));
    }
};

// ---- triangles (mesh_finish, ear_tris) ------------------------------------------

/// flat3: three vertices (nearly) in a line.
fn flat3(verts: []const V3, ai: u32, bi: u32, ci: u32) bool {
    const a = verts[ai];
    const u = m.sub(verts[bi], a);
    const w = m.sub(verts[ci], a);
    var x = u[1] * w[2] - u[2] * w[1];
    x *= x;
    var y = u[2] * w[0] - u[0] * w[2];
    y *= y;
    var z = u[0] * w[1] - u[1] * w[0];
    z *= z;
    const l = x + y + z;
    const uu = u[0] * u[0] + u[1] * u[1] + u[2] * u[2];
    const ww = w[0] * w[0] + w[1] * w[1] + w[2] * w[2];
    const r = uu * ww * 1.0e-10;
    return !(l > r);
}

/// The fan of each polygon, except that a flat ear (three corners in a line)
/// waits until it is not flat. 3 indices per triangle.
fn triangulate(t: Allocator, s: Mesh) ![]u32 {
    var tris: std.ArrayList(u32) = .empty;
    try tris.ensureTotalCapacity(t, @as(usize, s.l) * 3);
    var c: [256]u32 = undefined;
    for (0..s.f) |p| {
        const idx = s.poly(p);
        if (idx.len < 4 or idx.len > 256) {
            var i: usize = 1;
            while (i + 1 < idx.len) : (i += 1) tris.appendSliceAssumeCapacity(&.{ idx[0], idx[i], idx[i + 1] });
            continue;
        }
        var n = idx.len;
        @memcpy(c[0..n], idx);
        var tip: usize = 1;
        var flats: usize = 0;
        while (n > 3 and flats < n) {
            if (tip >= n) tip = 0;
            const pv = (tip + n - 1) % n;
            const nx = (tip + 1) % n;
            if (flat3(s.verts, c[pv], c[tip], c[nx])) {
                tip += 1;
                flats += 1;
                continue;
            }
            tris.appendSliceAssumeCapacity(&.{ c[pv], c[tip], c[nx] });
            std.mem.copyForwards(u32, c[tip .. n - 1], c[tip + 1 .. n]);
            n -= 1;
            flats = 0;
        }
        var i: usize = 1;
        while (i + 1 < n) : (i += 1) tris.appendSliceAssumeCapacity(&.{ c[0], c[i], c[i + 1] });
    }
    return tris.items;
}

// ---- the result under construction -----------------------------------------------

const Out = struct {
    a: Allocator,
    verts: std.ArrayList(V3) = .empty,
    poff: std.ArrayList(u32) = .empty,
    loops: std.ArrayList(u32) = .empty,

    fn init(a: Allocator) !Out {
        var o = Out{ .a = a };
        try o.poff.append(a, 0);
        return o;
    }
    fn deinit(o: *Out) void {
        o.verts.deinit(o.a);
        o.poff.deinit(o.a);
        o.loops.deinit(o.a);
    }
    fn addVert(o: *Out, p: V3) !u32 {
        if (o.verts.items.len >= max_verts) return error.TooBig;
        try o.verts.append(o.a, p);
        return @intCast(o.verts.items.len - 1);
    }
    fn addPoly(o: *Out, idx: []const u32) !void {
        if (o.loops.items.len + idx.len > max_loops) return error.TooBig;
        try o.loops.appendSlice(o.a, idx);
        try o.poff.append(o.a, @intCast(o.loops.items.len));
    }
    /// Hands the arrays over; o is empty afterwards.
    fn take(o: *Out) !PMesh {
        const v = try o.verts.toOwnedSlice(o.a);
        errdefer o.a.free(v);
        const p = try o.poff.toOwnedSlice(o.a);
        errdefer o.a.free(p);
        return .{ .verts = v, .poff = p, .loops = try o.loops.toOwnedSlice(o.a) };
    }
};

fn newMesh(a: Allocator, nv: usize, nf: usize, nl: usize) !PMesh {
    if (nv > max_verts or nl > max_loops) return error.TooBig;
    const v = try a.alloc(V3, nv);
    errdefer a.free(v);
    const p = try a.alloc(u32, nf + 1);
    errdefer a.free(p);
    p[0] = 0;
    return .{ .verts = v, .poff = p, .loops = try a.alloc(u32, nl) };
}

/// mesh_compact: without the vertices no polygon uses, in the same order.
fn compact(a: Allocator, t: Allocator, verts: []const V3, poff: []const u32, loops: []const u32) !PMesh {
    const remap = try t.alloc(u32, verts.len);
    @memset(remap, std.math.maxInt(u32));
    for (loops) |x| remap[x] = 0;
    var n: u32 = 0;
    for (remap) |*r| {
        if (r.* == 0) {
            r.* = n;
            n += 1;
        }
    }
    const r = try newMesh(a, n, poff.len - 1, loops.len);
    for (verts, remap) |p, i| {
        if (i != std.math.maxInt(u32)) r.verts[i] = p;
    }
    @memcpy(r.poff, poff);
    for (loops, r.loops) |x, *y| y.* = remap[x];
    return r;
}

// ---- Mirror ------------------------------------------------------------------

/// Vertices within `merge` of the plane are shared (and snapped to it); the rest
/// get mirrored copies, appended in order. Originals, then mirrored and reversed.
pub fn mirror(a: Allocator, in: PMesh, axis: u32, merge: f32) Error!PMesh {
    const s = try view(in);
    const ax: usize = @min(axis, 2);
    const mg = clampF(merge, 0, 10);
    const nv0 = s.verts.len;
    var extra: usize = 0;
    for (s.verts) |p| {
        if (@abs(p[ax]) > mg) extra += 1;
    }
    const r = try newMesh(a, nv0 + extra, @as(usize, s.f) * 2, @as(usize, s.l) * 2);
    errdefer r.deinit(a);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const map = try arena.allocator().alloc(u32, nv0);
    var nv: u32 = @intCast(nv0);
    for (s.verts, 0..) |p, i| {
        r.verts[i] = p;
        if (@abs(p[ax]) > mg) {
            var q = p;
            q[ax] = -q[ax];
            r.verts[nv] = q;
            map[i] = nv;
            nv += 1;
        } else {
            map[i] = @intCast(i);
            r.verts[i][ax] = 0;
        }
    }
    @memcpy(r.loops[0..s.l], s.loops);
    if (s.f > 0) {
        @memcpy(r.poff[0 .. s.f + 1], s.poff[0 .. s.f + 1]);
        var o: u32 = s.l;
        for (0..s.f) |p| {
            const idx = s.poly(p);
            var i = idx.len;
            while (i > 0) {
                i -= 1;
                r.loops[o] = map[idx[i]];
                o += 1;
            }
            r.poff[s.f + p + 1] = o;
        }
    }
    return r;
}

// ---- Array -------------------------------------------------------------------

/// count copies, each step = (x, y, z) * the bounding box size.
pub fn array(a: Allocator, in: PMesh, count: u32, x: f32, y: f32, z: f32) Error!PMesh {
    const s = try view(in);
    const n: usize = std.math.clamp(count, 1, 1000);
    const rel = V3{ clampF(x, -100, 100), clampF(y, -100, 100), clampF(z, -100, 100) };
    const box = bbox(s.verts);
    var step: V3 = undefined;
    for (0..3) |c| step[c] = (box[1][c] - box[0][c]) * rel[c];
    const r = try newMesh(a, s.verts.len * n, s.f * n, s.l * n);
    errdefer r.deinit(a);
    var vo: usize = 0;
    var po: usize = 1;
    var lo: usize = 0;
    for (0..n) |k| {
        const fk = fi(k);
        for (s.verts) |p| {
            for (0..3) |c| r.verts[vo][c] = step[c] * fk + p[c];
            vo += 1;
        }
        const base: u32 = @intCast(k * s.verts.len);
        const l0: u32 = @intCast(lo);
        if (s.f > 0) {
            for (s.poff[1 .. s.f + 1]) |o| {
                r.poff[po] = l0 + o;
                po += 1;
            }
        }
        for (s.loops) |i| {
            r.loops[lo] = i + base;
            lo += 1;
        }
    }
    return r;
}

// ---- Solidify ----------------------------------------------------------------

/// An inner shell along the area-weighted vertex normals (reversed), and rims
/// on the edges of one face: a -> b gives b a a' b'.
pub fn solidify(a: Allocator, in: PMesh, thickness: f32) Error!PMesh {
    const s = try view(in);
    const th = clampF(thickness, -100, 100);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    const vn = try t.alloc(V3, s.verts.len);
    @memset(vn, .{ 0, 0, 0 });
    for (0..s.f) |p| {
        const idx = s.poly(p);
        const n = newell(s.verts, idx);
        for (idx) |i| vn[i] = m.add(vn[i], n);
    }
    const tab = try EdgeTab.build(t, s);
    var rims: usize = 0;
    for (0..s.f) |p| {
        const idx = s.poly(p);
        for (idx, 0..) |x, i| {
            const y = idx[if (i + 1 < idx.len) i + 1 else 0];
            if (tab.cnt[tab.find(x, y).?] == 1) rims += 1;
        }
    }
    const nv0 = s.verts.len;
    const r = try newMesh(a, nv0 * 2, @as(usize, s.f) * 2 + rims, @as(usize, s.l) * 2 + rims * 4);
    errdefer r.deinit(a);
    for (s.verts, 0..) |p, i| {
        r.verts[i] = p;
        const n = normalize(vn[i]);
        for (0..3) |c| r.verts[nv0 + i][c] = p[c] - n[c] * th;
    }
    var po: usize = 0;
    var lo: u32 = 0;
    for (0..s.f) |p| {
        const idx = s.poly(p);
        @memcpy(r.loops[lo..][0..idx.len], idx);
        lo += @intCast(idx.len);
        po += 1;
        r.poff[po] = lo;
    }
    const off: u32 = @intCast(nv0);
    for (0..s.f) |p| {
        const idx = s.poly(p);
        var i = idx.len;
        while (i > 0) {
            i -= 1;
            r.loops[lo] = idx[i] + off;
            lo += 1;
        }
        po += 1;
        r.poff[po] = lo;
    }
    for (0..s.f) |p| {
        const idx = s.poly(p);
        for (idx, 0..) |x, i| {
            const y = idx[if (i + 1 < idx.len) i + 1 else 0];
            if (tab.cnt[tab.find(x, y).?] != 1) continue;
            r.loops[lo] = y;
            r.loops[lo + 1] = x;
            r.loops[lo + 2] = x + off;
            r.loops[lo + 3] = y + off;
            lo += 4;
            po += 1;
            r.poff[po] = lo;
        }
    }
    return r;
}

// ---- Bevel (mod_bevel -> build_bevel in meshops2.s) --------------------------------

const Bev = struct {
    s: Mesh,
    tab: *const EdgeTab,
    bev: []u8, // per edge: beveled
    cpt: []i32, // per loop: the corner's own point, or -1
    along: Hash, // (v, other) -> point slid from v towards other
    arc: []u32, // per edge: 2 ends x (segments - 1) arc points
    arch: ?Hash = null, // an arc's two ends -> who made it
    done: []u8, // per vertex: a face closed its round (no patch)
    cface: []u32, // per loop: its polygon
    vfirst: []u32, // per vertex: its first loop
    vedge_off: []u32 = &.{}, // per vertex: the edges at it, in order
    vedge: []u32 = &.{},
    w: f32,
    seg: u32,
    o: *Out,
    scr: *std.ArrayList(u32),
    t: Allocator,

    fn isBev(b: *const Bev, x: u32, y: u32) bool {
        const e = b.tab.find(x, y) orelse return false;
        return b.bev[e] != 0;
    }
    /// corner_of: where polygon p has vertex v.
    fn cornerOf(b: *const Bev, p: u32, v: u32) u32 {
        var c = b.s.poff[p];
        const end = b.s.poff[p + 1];
        while (c < end) : (c += 1) {
            if (b.s.loops[c] == v) return c;
        }
        return end -| 1;
    }
    /// bv_cpt of the corner; the vertex itself where a polygon that visits v
    /// twice left its first corner without a point (the original reads -1 there).
    fn cptAt(b: *const Bev, p: u32, v: u32) u32 {
        const c = b.cpt[b.cornerOf(p, v)];
        return if (c < 0) v else @intCast(c);
    }
    fn prevV(b: *const Bev, l: u32) u32 {
        const p = b.cface[l];
        const first = b.s.poff[p];
        return b.s.loops[if (l > first) l - 1 else b.s.poff[p + 1] - 1];
    }
    fn nextV(b: *const Bev, l: u32) u32 {
        const p = b.cface[l];
        return b.s.loops[if (l + 1 < b.s.poff[p + 1]) l + 1 else b.s.poff[p]];
    }
    fn alongOrV(b: *const Bev, v: u32, other: u32) u32 {
        return b.along.get(dkey(v, other)) orelse v;
    }
    fn f1(b: *const Bev, e: u32) u32 {
        return @intCast(b.tab.f1[e]);
    }
    fn f2(b: *const Bev, e: u32) u32 {
        return @intCast(b.tab.f2[e]);
    }
    fn arcBase(b: *const Bev, e: u32, end: u32) usize {
        const n: usize = b.seg - 1;
        return (@as(usize, e) * 2 + end) * n;
    }

    /// Pass 1: the corner of loop l, next to a beveled edge, gets its point.
    fn cornerPoint(b: *Bev, l: u32, ui: u32, vi: u32, wi: u32, bp: bool, bn: bool) !void {
        const v = b.s.verts[vi];
        var dp = m.sub(b.s.verts[ui], v);
        var dn = m.sub(b.s.verts[wi], v);
        const lp = vlen(dp);
        const ln = vlen(dn);
        dp = normalize(dp);
        dn = normalize(dn);
        var x = dp[1] * dn[2] - dp[2] * dn[1];
        x *= x;
        var y = dp[2] * dn[0] - dp[0] * dn[2];
        y *= y;
        var z = dp[0] * dn[1] - dp[1] * dn[0];
        z *= z;
        const sn = fmax(@sqrt(x + y + z), 0.05);
        var k = b.w / sn; // width / sin
        var id: u32 = undefined;
        if (bp and bn) { // both: no further than 45% of the shorter edge
            k = fmin(fmin(lp, ln) * 0.45, k);
            var q: V3 = undefined;
            for (0..3) |c| q[c] = (dp[c] + dn[c]) * k + v[c];
            id = try b.o.addVert(q);
        } else { // one: slide along the other edge, shared per (v, other)
            const dir = if (bn) dp else dn;
            const other = if (bn) ui else wi;
            k = fmin((if (bn) lp else ln) * 0.45, k);
            const r = b.along.slot(dkey(vi, other), std.math.maxInt(u32));
            if (r.val.* == std.math.maxInt(u32)) {
                var q: V3 = undefined;
                for (0..3) |c| q[c] = dir[c] * k + v[c];
                id = try b.o.addVert(q);
                r.val.* = id;
            } else id = r.val.*;
        }
        b.cpt[l] = @intCast(id);
    }

    /// arc_share: an earlier edge end made the arc between these two points?
    /// Then its points are used and v needs no patch; else this one registers.
    fn arcShare(b: *Bev, e: u32, end: u32, v: u32, p1: u32, p2: u32) bool {
        const n: usize = b.seg - 1;
        const r = b.arch.?.slot(ukey(p1, p2), 0);
        const dir: u32 = if (p1 > p2) 1 else 0;
        const ours: u32 = e * 2 + end;
        if (!r.existed) {
            r.val.* = ours * 2 + dir;
            return false;
        }
        const val = r.val.*;
        const theirs = @as(usize, val >> 1) * n;
        for (0..n) |k| {
            const i = if ((val & 1) == dir) k else n - 1 - k;
            b.arc[ours * n + k] = b.arc[theirs + i];
        }
        b.done[v] = 1;
        return true;
    }

    /// arc_fill: when a beveled edge ends at v with its strip running from p to
    /// q (or back), its arc points go in between.
    fn arcFill(b: *Bev, v: u32, p: u32, q: u32) !void {
        if (b.seg <= 1 or p == q or p == v or q == v) return;
        for (b.vedge[b.vedge_off[v]..b.vedge_off[v + 1]]) |e| {
            if (b.bev[e] == 0) continue;
            const c1 = b.cptAt(b.f1(e), v);
            const c2 = b.cptAt(b.f2(e), v);
            const fwd = c1 == p and c2 == q;
            if (!fwd and !(c1 == q and c2 == p)) continue;
            b.done[v] = 1;
            const base = b.arcBase(e, if (b.tab.lo[e] == v) 0 else 1);
            const n: usize = b.seg - 1;
            for (0..n) |k| try b.scr.append(b.t, b.arc[base + (if (fwd) k else n - 1 - k)]);
            return;
        }
    }

    /// corner_rep: loop l's own point, or for an untouched corner the points
    /// slid along its two edges (else the vertex), with an ending arc between.
    fn cornerRep(b: *Bev, l: u32, ui: u32, vi: u32, wi: u32) !void {
        const c = b.cpt[l];
        if (c >= 0) return b.scr.append(b.t, @intCast(c));
        const p = b.alongOrV(vi, ui);
        try b.scr.append(b.t, p);
        const q = b.alongOrV(vi, wi);
        try b.arcFill(vi, p, q);
        try b.scr.append(b.t, q);
    }

    /// dedupe_scr: no repeated neighbours (cyclic).
    fn dedupe(b: *Bev) void {
        const s = b.scr.items;
        if (s.len == 0) return;
        var w: usize = 1;
        for (s[1..]) |x| {
            if (x != s[w - 1]) {
                s[w] = x;
                w += 1;
            }
        }
        while (w > 1 and s[w - 1] == s[0]) w -= 1;
        b.scr.items.len = w;
    }

    /// strip_pt: row 0 is F1's corner point, row s F2's, between them the arc.
    fn stripPt(b: *const Bev, e: u32, end: u32, v: u32, row: u32) u32 {
        if (row == 0) return b.cptAt(b.f1(e), v);
        if (row >= b.seg) return b.cptAt(b.f2(e), v);
        return b.arc[b.arcBase(e, end) + row - 1];
    }

    /// other_face: across edge (x, y) from polygon p, or none.
    fn otherFace(b: *const Bev, x: u32, y: u32, p: u32) ?u32 {
        const e = b.tab.find(x, y) orelse return null;
        if (b.tab.cnt[e] != 2) return null;
        return if (b.f1(e) != p) b.f1(e) else b.f2(e);
    }

    fn appendArc(b: *Bev, v: u32, w: u32, from: u32) !void {
        if (b.seg <= 1) return;
        const e = b.tab.find(v, w) orelse return;
        const base = b.arcBase(e, if (v < w) 0 else 1);
        const n: usize = b.seg - 1;
        const up = b.f1(e) == from;
        for (0..n) |k| try b.scr.append(b.t, b.arc[base + (if (up) k else n - 1 - k)]);
    }

    /// corner_patch: walk the faces around v, collecting their points and the
    /// arcs between; three or more distinct points close the hole.
    fn cornerPatch(b: *Bev, v: u32) !void {
        const start = b.cface[b.vfirst[v]];
        var cur = start;
        var guard: u32 = 0;
        while (true) { // rewind to the start of an open fan
            guard += 1;
            if (guard > 256) break;
            const u = b.prevV(b.cornerOf(cur, v));
            const o = b.otherFace(v, u, cur) orelse break;
            if (o == start) {
                cur = start;
                break;
            }
            cur = o;
        }
        const first = cur;
        b.scr.clearRetainingCapacity();
        guard = 0;
        while (true) {
            guard += 1;
            if (guard > 256) break;
            const l = b.cornerOf(cur, v);
            const c = b.cpt[l];
            if (c >= 0) {
                try b.scr.append(b.t, @intCast(c));
            } else {
                try b.scr.append(b.t, b.alongOrV(v, b.prevV(l)));
                try b.scr.append(b.t, b.alongOrV(v, b.nextV(l)));
            }
            const w = b.nextV(l);
            if (b.isBev(v, w)) try b.appendArc(v, w, cur);
            const o = b.otherFace(v, w, cur) orelse break;
            if (o == first) break;
            cur = o;
        }
        b.dedupe();
        if (b.scr.items.len < 3) return;
        const n0 = newell(b.s.verts, b.s.poly(first)); // like the first face around v
        const n1 = newell(b.o.verts.items, b.scr.items);
        const d = n1[0] * n0[0] + n1[1] * n0[1] + n1[2] * n0[2];
        if (!(d >= 0)) std.mem.reverse(u32, b.scr.items);
        try b.o.addPoly(b.scr.items);
    }
};

/// Bevels the edges of two faces whose normals differ by more than the angle:
/// corners move inwards, strips (rounded by a quadratic arc of `segments` rows)
/// fill the edges, patches the vertices.
pub fn bevel(a: Allocator, in: PMesh, width: f32, segments: u32, angle_deg: f32) Error!PMesh {
    const w = clampF(width, 0, 100);
    const seg: u32 = std.math.clamp(segments, 1, 32);
    const angle: f32 = clampF(angle_deg, 0, 180) * 0.017453292;
    const cosa: f32 = @floatCast(@cos(@as(f64, angle))); // (fsincos)
    return bevelPred(a, in, w, seg, cosa, null, null);
}

/// What a caller's edge test sees (feature.zig's fillet selector): the
/// positions and their bounds.
pub const PredMesh = struct { verts: []const V3, bmin: V3, bmax: V3 };
pub const Pred = *const fn (u32, u32, *const PredMesh) bool;

/// build_bevel as it is: edges sharper than cos^-1(cosa) (bv_angle, bv_cos)
/// that the caller's test takes too (bv_pred), any width, segments >= 1.
pub fn bevelPred(a: Allocator, in: PMesh, w: f32, segments: u32, cosa: f32, pred: ?Pred, pm: ?*const PredMesh) Error!PMesh {
    const s = try view(in);
    const seg: u32 = @max(segments, 1);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();

    const tab = try EdgeTab.build(t, s);
    const bevf = try t.alloc(u8, tab.n);
    @memset(bevf, 0);
    for (0..tab.n) |e| {
        if (tab.cnt[e] != 2) continue;
        const n1 = normalize(newell(s.verts, s.poly(@intCast(tab.f1[e]))));
        const n2 = normalize(newell(s.verts, s.poly(@intCast(tab.f2[e]))));
        const d = n1[0] * n2[0] + n1[1] * n2[1] + n1[2] * n2[2];
        if (!(d >= cosa)) {
            if (pred) |f| {
                if (!f(tab.lo[e], tab.hi[e], pm.?)) continue;
            }
            bevf[e] = 1;
        }
    }
    const arc_len = @as(usize, seg - 1) * 2 * tab.n;
    if (arc_len > max_loops) return error.TooBig;

    var o = try Out.init(a);
    defer o.deinit();
    try o.verts.appendSlice(a, s.verts);
    var scr: std.ArrayList(u32) = .empty;

    const cpt = try t.alloc(i32, s.l);
    @memset(cpt, -1);
    const arc = try t.alloc(u32, arc_len);
    @memset(arc, 0);
    const done = try t.alloc(u8, s.verts.len);
    @memset(done, 0);
    const cface = try t.alloc(u32, s.l);
    const vfirst = try t.alloc(u32, s.verts.len);
    @memset(vfirst, std.math.maxInt(u32));
    var bb = Bev{
        .s = s,
        .tab = &tab,
        .bev = bevf,
        .cpt = cpt,
        .along = try Hash.init(t, @as(usize, s.l) * 2),
        .arc = arc,
        .done = done,
        .cface = cface,
        .vfirst = vfirst,
        .w = w,
        .seg = seg,
        .o = &o,
        .scr = &scr,
        .t = t,
    };
    for (0..s.f) |p| {
        var l = s.poff[p];
        while (l < s.poff[p + 1]) : (l += 1) {
            cface[l] = @intCast(p);
            const x = s.loops[l];
            if (vfirst[x] == std.math.maxInt(u32)) vfirst[x] = l;
        }
    }

    // pass 1: each corner touching a beveled edge gets its point
    for (0..s.f) |p| {
        var l = s.poff[p];
        while (l < s.poff[p + 1]) : (l += 1) {
            const u = bb.prevV(l);
            const v = s.loops[l];
            const n = bb.nextV(l);
            const bp = bb.isBev(u, v);
            const bn = bb.isBev(v, n);
            if (bp or bn) try bb.cornerPoint(l, u, v, n, bp, bn);
        }
    }

    // arc points per beveled edge end
    if (seg > 1) {
        bb.arch = try Hash.init(t, @as(usize, tab.n) * 2);
        const off = try t.alloc(u32, s.verts.len + 1);
        @memset(off, 0);
        for (0..tab.n) |e| {
            off[tab.lo[e] + 1] += 1;
            if (tab.hi[e] != tab.lo[e]) off[tab.hi[e] + 1] += 1;
        }
        for (1..off.len) |i| off[i] += off[i - 1];
        const vedge = try t.alloc(u32, off[s.verts.len]);
        const pos = try t.dupe(u32, off[0..s.verts.len]);
        for (0..tab.n) |e| {
            vedge[pos[tab.lo[e]]] = @intCast(e);
            pos[tab.lo[e]] += 1;
            if (tab.hi[e] != tab.lo[e]) {
                vedge[pos[tab.hi[e]]] = @intCast(e);
                pos[tab.hi[e]] += 1;
            }
        }
        bb.vedge_off = off;
        bb.vedge = vedge;
        const ft = fi(seg);
        for (0..tab.n) |ei| {
            if (bevf[ei] == 0) continue;
            const e: u32 = @intCast(ei);
            for ([2]u32{ tab.lo[e], tab.hi[e] }, 0..) |v, endi| {
                const end: u32 = @intCast(endi);
                const c1 = bb.cptAt(bb.f1(e), v);
                const c2 = bb.cptAt(bb.f2(e), v);
                if (bb.arcShare(e, end, v, c1, c2)) continue;
                var j: u32 = 1;
                while (j < seg) : (j += 1) {
                    const tt = fi(j) / ft;
                    const mt = 1.0 - tt;
                    const p1 = o.verts.items[c1];
                    const p2 = o.verts.items[c2];
                    const c = s.verts[v];
                    var q: V3 = undefined;
                    for (0..3) |i| {
                        const x = p1[i] * mt * mt;
                        var y = c[i] * mt * tt;
                        y += y;
                        q[i] = x + y + p2[i] * tt * tt;
                    }
                    arc[bb.arcBase(e, end) + j - 1] = try o.addVert(q);
                }
            }
        }
    }

    // faces: corners replaced by their points
    for (0..s.f) |p| {
        scr.clearRetainingCapacity();
        var l = s.poff[p];
        while (l < s.poff[p + 1]) : (l += 1) try bb.cornerRep(l, bb.prevV(l), s.loops[l], bb.nextV(l));
        bb.dedupe();
        if (scr.items.len >= 3) try o.addPoly(scr.items);
    }

    // strips across each beveled edge
    for (0..tab.n) |ei| {
        if (bevf[ei] == 0) continue;
        const e: u32 = @intCast(ei);
        const lo = tab.lo[e];
        const hi = tab.hi[e];
        // F1 walks end 0 -> end 1: the strip walks back
        const reverse = bb.nextV(bb.cornerOf(bb.f1(e), lo)) == hi;
        var j: u32 = 0;
        while (j < seg) : (j += 1) {
            var q = [4]u32{ bb.stripPt(e, 0, lo, j), bb.stripPt(e, 1, hi, j), bb.stripPt(e, 1, hi, j + 1), bb.stripPt(e, 0, lo, j + 1) };
            if (reverse) std.mem.swap(u32, &q[1], &q[3]);
            try o.addPoly(&q);
        }
    }

    // corner patches where the points around a vertex leave a hole
    const has = try t.alloc(u8, s.verts.len);
    @memset(has, 0);
    for (0..tab.n) |e| {
        if (bevf[e] == 0) continue;
        has[tab.lo[e]] = 1;
        has[tab.hi[e]] = 1;
    }
    for (0..s.verts.len) |v| {
        if (has[v] != 0 and done[v] == 0) try bb.cornerPatch(@intCast(v));
    }
    return compact(a, t, o.verts.items, o.poff.items, o.loops.items);
}

// ---- Decimate ----------------------------------------------------------------

fn cellKey(p: V3, inv: f32) u64 {
    var k: u64 = 0;
    for (0..3) |c| {
        const i: u32 = @bitCast(cvtt(@floor(p[c] * inv)));
        k = (k << 21) | (i & 0x1fffff);
    }
    return k;
}

/// Vertex clustering on a grid whose cell size is tuned to the ratio (ten
/// tries): one vertex per occupied cell, at the mean of its vertices.
pub fn decimate(a: Allocator, in: PMesh, ratio: f32) Error!PMesh {
    const s = try view(in);
    const r0 = clampF(ratio, 0.01, 1);
    if (!(r0 < 1) or s.verts.len == 0) return in.clone(a);
    const target = fmax(r0 * fi(s.verts.len), 4);
    const box = bbox(s.verts);
    var d2: f32 = 0;
    for (0..3) |c| {
        const e = box[1][c] - box[0][c];
        d2 += e * e;
    }
    var h = fmax(@sqrt(d2) / @sqrt(target), 1.0e-6);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    const tab = try Hash.init(t, s.verts.len);
    var iter: u32 = 0;
    while (true) {
        tab.clear();
        const inv = 1.0 / h;
        var cells: u32 = 0;
        for (s.verts) |p| {
            if (!tab.slot(cellKey(p, inv), 0).existed) cells += 1;
        }
        const q = fi(cells) / target;
        if (!(@abs(q - 1.0) >= 0.03)) break; // close enough
        iter += 1;
        if (iter >= 10) break;
        h = @sqrt(q) * h; // surface: count ~ 1 / h^2
    }
    tab.clear();
    const inv = 1.0 / h;
    const rep = try t.alloc(u32, s.verts.len);
    const sums = try t.alloc(V3, s.verts.len);
    const cnt = try t.alloc(u32, s.verts.len);
    @memset(sums, .{ 0, 0, 0 });
    @memset(cnt, 0);
    for (s.verts, 0..) |p, i| {
        const r = tab.slot(cellKey(p, inv), @intCast(i)).val.*; // the first in the cell
        rep[i] = r;
        sums[r] = m.add(sums[r], p);
        cnt[r] += 1;
    }
    for (sums, cnt) |*p, c| {
        if (c == 0) continue;
        const n = fi(c);
        p.* = .{ p[0] / n, p[1] / n, p[2] / n };
    }
    const poff = try t.alloc(u32, s.f + 1);
    const loops = try t.alloc(u32, s.l);
    poff[0] = 0;
    var nf: usize = 0;
    var nl: u32 = 0;
    for (0..s.f) |p| {
        const st = nl;
        for (s.poly(p)) |x| {
            const r = rep[x];
            if (nl > st and loops[nl - 1] == r) continue;
            loops[nl] = r;
            nl += 1;
        }
        if (nl - st >= 2 and loops[nl - 1] == loops[st]) nl -= 1;
        if (nl - st < 3) {
            nl = st;
            continue;
        }
        nf += 1;
        poff[nf] = nl;
    }
    return compact(a, t, sums, poff[0 .. nf + 1], loops[0..nl]);
}

// ---- Remesh ------------------------------------------------------------------

const RM_MAX: u64 = 8000000; // most sample points

const Grid = struct {
    n: [3]u32,
    inside: []const u8,
    cell: []const i32,

    fn sample(g: Grid, c: [3]i32) u8 {
        if (c[0] < 0 or c[1] < 0 or c[2] < 0) return 0;
        const i: u32 = @intCast(c[0]);
        const j: u32 = @intCast(c[1]);
        const k: u32 = @intCast(c[2]);
        if (i >= g.n[0] or j >= g.n[1] or k >= g.n[2]) return 0;
        return g.inside[(@as(usize, k) * g.n[1] + j) * g.n[0] + i];
    }
    fn cellVert(g: Grid, c: [3]i32) i32 {
        if (c[0] < 0 or c[1] < 0 or c[2] < 0) return -1;
        const i: u32 = @intCast(c[0]);
        const j: u32 = @intCast(c[1]);
        const k: u32 = @intCast(c[2]);
        const cx = g.n[0] - 1;
        const cy = g.n[1] - 1;
        if (i >= cx or j >= cy or k >= g.n[2] - 1) return -1;
        return g.cell[(@as(usize, k) * cy + j) * cx + i];
    }
};

/// mod_remesh: inside / outside on a voxel grid (ray parity along x), then
/// surface nets: one vertex per cell the surface crosses, a quad per crossing
/// sample edge, two smoothing rounds. Too fine a voxel is coarsened by 1.2 until
/// the grid holds at most 8 million samples, as in the original.
pub fn remesh(a: Allocator, in: PMesh, voxel: f32) Error!PMesh {
    const s = try view(in);
    var v = fmax(clampF(voxel, 0.01, 100), 1.0e-6);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    const tris = try triangulate(t, s);
    if (tris.len == 0) return in.clone(a);
    const box = bbox(s.verts);
    for (0..3) |c| {
        // (the original would coarsen for ever)
        if (!std.math.isFinite(box[0][c]) or !std.math.isFinite(box[1][c])) return in.clone(a);
    }

    // samples: the box padded by 1.5 voxels
    var mn: V3 = undefined;
    var n: [3]u32 = undefined;
    var samples: u64 = undefined;
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (tries > 2000) return in.clone(a); // (a box too large for f32 arithmetic)
        const pad = v * 1.5;
        samples = 1;
        var fits = true;
        for (0..3) |c| {
            mn[c] = box[0][c] - pad;
            const i = cvtt((box[1][c] + pad - mn[c]) / v);
            if (i < 0 or i >= 8000000) {
                fits = false;
                n[c] = 0;
                continue;
            }
            n[c] = @as(u32, @intCast(i)) + 2;
            samples *|= n[c];
        }
        if (fits and samples <= RM_MAX) break;
        v *= 1.2;
    }
    const nx: usize = n[0];
    const ny: usize = n[1];
    const nz: usize = n[2];
    const lines = ny * nz;

    // pass 0 counts, pass 1 stores the crossings of every line
    const ends = try t.alloc(u32, lines);
    @memset(ends, 0);
    var xs: []f32 = &.{};
    for (0..2) |pass| {
        var ti: usize = 0;
        while (ti < tris.len) : (ti += 3) {
            const p0 = s.verts[tris[ti]];
            const p1 = s.verts[tris[ti + 1]];
            const p2 = s.verts[tris[ti + 2]];
            const d = (p1[1] - p0[1]) * (p2[2] - p0[2]) - (p2[1] - p0[1]) * (p1[2] - p0[2]);
            if (!(@abs(d) > 1.0e-12)) continue;
            // the lines j, k inside the triangle's YZ box
            var j0 = cvtt(@ceil((fmin(fmin(p0[1], p1[1]), p2[1]) - mn[1]) / v));
            var j1 = cvtt(@floor((fmax(fmax(p0[1], p1[1]), p2[1]) - mn[1]) / v));
            var k0 = cvtt(@ceil((fmin(fmin(p0[2], p1[2]), p2[2]) - mn[2]) / v));
            var k1 = cvtt(@floor((fmax(fmax(p0[2], p1[2]), p2[2]) - mn[2]) / v));
            j0 = @max(j0, 0);
            k0 = @max(k0, 0);
            j1 = @min(j1, @as(i32, @intCast(ny)) - 1);
            k1 = @min(k1, @as(i32, @intCast(nz)) - 1);
            var k = k0;
            while (k <= k1) : (k += 1) {
                var j = j0;
                while (j <= j1) : (j += 1) {
                    // the line point, jittered against exact edge hits
                    const y = (fi(j) + 0.000618034) * v + mn[1];
                    const z = (fi(k) + 0.000414214) * v + mn[2];
                    const dy = y - p0[1];
                    const dz = z - p0[2];
                    const u = (dy * (p2[2] - p0[2]) - (p2[1] - p0[1]) * dz) / d;
                    const w = ((p1[1] - p0[1]) * dz - (p1[2] - p0[2]) * dy) / d;
                    if (!(u >= 0) or !(w >= 0) or u + w > 1.0) continue;
                    const line = @as(usize, @intCast(k)) * ny + @as(usize, @intCast(j));
                    if (pass == 0) {
                        ends[line] += 1;
                    } else {
                        xs[ends[line]] = (p1[0] - p0[0]) * u + (p2[0] - p0[0]) * w + p0[0];
                        ends[line] += 1;
                    }
                }
            }
        }
        if (pass == 0) { // counts -> offsets
            var total: u64 = 0;
            for (ends) |*e| {
                const c = e.*;
                if (total > max_loops) return error.TooBig;
                e.* = @intCast(total);
                total += c;
            }
            if (total > max_loops) return error.TooBig;
            xs = try t.alloc(f32, @intCast(total));
        }
    }

    // sort each line's crossings; a sample is inside after an odd number of them
    const inside = try t.alloc(u8, @intCast(samples));
    for (0..lines) |line| {
        const b: usize = if (line > 0) ends[line - 1] else 0;
        const e: usize = ends[line];
        var c = b + 1;
        while (c < e) : (c += 1) {
            const x = xs[c];
            var i = c;
            while (i > b and !(x >= xs[i - 1])) : (i -= 1) xs[i] = xs[i - 1];
            xs[i] = x;
        }
        var next = b;
        var ins: u8 = 0;
        for (0..nx) |i| {
            const x = fi(i) * v + mn[0];
            while (next < e and x >= xs[next]) {
                ins ^= 1;
                next += 1;
            }
            inside[line * nx + i] = ins;
        }
    }

    // a vertex per mixed cell
    const cx = nx - 1;
    const cy = ny - 1;
    const cz = nz - 1;
    const cell = try t.alloc(i32, cx * cy * cz);
    var o = try Out.init(a);
    defer o.deinit();
    var ci: usize = 0;
    for (0..cz) |k| {
        for (0..cy) |j| {
            for (0..cx) |i| {
                var any: u8 = 0;
                var all: u8 = 1;
                for (0..8) |b| {
                    const sm = inside[((k + (b >> 2)) * ny + j + ((b >> 1) & 1)) * nx + i + (b & 1)];
                    any |= sm;
                    all &= sm;
                }
                if (any != all) {
                    const id = try o.addVert(.{
                        (fi(i) + 0.5) * v + mn[0],
                        (fi(j) + 0.5) * v + mn[1],
                        (fi(k) + 0.5) * v + mn[2],
                    });
                    cell[ci] = @intCast(id);
                } else cell[ci] = -1;
                ci += 1;
            }
        }
    }
    if (o.verts.items.len == 0) return in.clone(a);

    // a quad per sample edge with a sign change: the 4 cells around it, in the
    // plane of the other two axes (cyclic), wound so the normal leaves the inside
    const g = Grid{ .n = n, .inside = inside, .cell = cell };
    const da = [4]i32{ -1, 0, 0, -1 };
    const db = [4]i32{ -1, -1, 0, 0 };
    for (0..nz) |k| {
        for (0..ny) |j| {
            for (0..nx) |i| {
                const c0 = [3]i32{ @intCast(i), @intCast(j), @intCast(k) };
                const s0 = inside[(k * ny + j) * nx + i];
                axes: for (0..3) |ax| {
                    var c1 = c0;
                    c1[ax] += 1;
                    if (g.sample(c1) == s0) continue;
                    const ea = (ax + 1) % 3;
                    const eb = (ea + 1) % 3;
                    var q: [4]u32 = undefined;
                    for (0..4) |r| {
                        var c = c0;
                        c[ea] += da[r];
                        c[eb] += db[r];
                        const id = g.cellVert(c);
                        if (id < 0) continue :axes;
                        q[r] = @intCast(id);
                    }
                    if (s0 == 0) std.mem.reverse(u32, &q);
                    try o.addPoly(&q);
                }
            }
        }
    }
    try smooth2(t, &o);
    return o.take();
}

/// Two rounds of p = (p + mean(neighbours)) / 2: relaxes the staircase.
fn smooth2(t: Allocator, o: *Out) !void {
    const pos = o.verts.items;
    const s = Mesh{ .verts = pos, .poff = o.poff.items, .loops = o.loops.items, .f = @intCast(o.poff.items.len - 1), .l = @intCast(o.loops.items.len) };
    const tab = try EdgeTab.build(t, s);
    const sums = try t.alloc(V3, pos.len);
    const cnt = try t.alloc(u32, pos.len);
    for (0..2) |_| {
        @memset(sums, .{ 0, 0, 0 });
        @memset(cnt, 0);
        for (0..tab.n) |e| {
            const x = tab.lo[e];
            const y = tab.hi[e];
            for (0..3) |c| {
                sums[x][c] += pos[y][c];
                sums[y][c] += pos[x][c];
            }
            cnt[x] += 1;
            cnt[y] += 1;
        }
        for (pos, sums, cnt) |*p, q, c| {
            if (c == 0) continue;
            const n = fi(c);
            for (0..3) |i| p[i] = (q[i] / n + p[i]) * 0.5;
        }
    }
}

// ---- tests -----------------------------------------------------------------------

/// Geometry checks for the tests here and in subsurf.zig.
pub const check = struct {
    /// Every directed edge once, and its opposite once: closed and consistently wound.
    pub fn closed(p: PMesh) !bool {
        var map = std.AutoHashMap(u64, u32).init(std.testing.allocator);
        defer map.deinit();
        for (0..p.faces()) |f| {
            const idx = p.poly(f);
            for (idx, 0..) |x, i| {
                const r = try map.getOrPut(dkey(x, idx[if (i + 1 < idx.len) i + 1 else 0]));
                r.value_ptr.* = if (r.found_existing) r.value_ptr.* + 1 else 1;
            }
        }
        var it = map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != 1) return false;
            const rev = (e.key_ptr.* << 32) | (e.key_ptr.* >> 32);
            if ((map.get(rev) orelse 0) != 1) return false;
        }
        return true;
    }
    /// Every directed edge as often as its opposite (a pinched edge may have four faces).
    pub fn watertight(p: PMesh) !bool {
        var map = std.AutoHashMap(u64, i32).init(std.testing.allocator);
        defer map.deinit();
        for (0..p.faces()) |f| {
            const idx = p.poly(f);
            for (idx, 0..) |x, i| {
                const y = idx[if (i + 1 < idx.len) i + 1 else 0];
                const r = try map.getOrPutValue(ukey(x, y), 0);
                r.value_ptr.* += if (x < y) 1 else -1;
            }
        }
        var it = map.valueIterator();
        while (it.next()) |v| if (v.* != 0) return false;
        return true;
    }
    /// Signed volume (positive: faces outward).
    pub fn volume(p: PMesh) f64 {
        var s: f64 = 0;
        for (0..p.faces()) |f| {
            const idx = p.poly(f);
            var i: usize = 1;
            while (i + 1 < idx.len) : (i += 1) {
                const a = p.verts[idx[0]];
                const b = p.verts[idx[i]];
                const c = p.verts[idx[i + 1]];
                const x: f64 = @as(f64, b[1]) * c[2] - @as(f64, b[2]) * c[1];
                const y: f64 = @as(f64, b[2]) * c[0] - @as(f64, b[0]) * c[2];
                const z: f64 = @as(f64, b[0]) * c[1] - @as(f64, b[1]) * c[0];
                s += (a[0] * x + a[1] * y + a[2] * z) / 6.0;
            }
        }
        return s;
    }
    pub fn box(p: PMesh) [2]V3 {
        return bbox(p.verts);
    }
    /// Faces of a mesh around the origin all look away from it.
    pub fn outward(p: PMesh) bool {
        for (0..p.faces()) |f| {
            const idx = p.poly(f);
            var c: V3 = .{ 0, 0, 0 };
            for (idx) |i| c = m.add(c, p.verts[i]);
            if (m.dot(newell(p.verts, idx), c) <= 0) return false;
        }
        return true;
    }
    /// Euler characteristic.
    pub fn euler(p: PMesh) !i64 {
        var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
        defer seen.deinit();
        for (0..p.faces()) |f| {
            const idx = p.poly(f);
            for (idx, 0..) |x, i| try seen.put(ukey(x, idx[if (i + 1 < idx.len) i + 1 else 0]), {});
        }
        return @as(i64, @intCast(p.verts.len)) - @as(i64, @intCast(seen.count())) + @as(i64, @intCast(p.faces()));
    }
    pub fn dup(a: Allocator, v: []const V3, o: []const u32, l: []const u32) !PMesh {
        return (PMesh{ .verts = @constCast(v), .poff = @constCast(o), .loops = @constCast(l) }).clone(a);
    }
    pub fn tri(a: Allocator) !PMesh {
        return dup(a, &.{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1.5 } }, &.{ 0, 3 }, &.{ 0, 1, 2 });
    }
    /// One open quad in the XZ plane, facing +Y.
    pub fn plane(a: Allocator) !PMesh {
        return dup(a, &.{ .{ -1, 0, -1 }, .{ -1, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 0, -1 } }, &.{ 0, 4 }, &.{ 0, 1, 2, 3 });
    }
    pub fn empty(a: Allocator) !PMesh {
        return dup(a, &.{}, &.{0}, &.{});
    }
    /// Three triangles on one edge.
    pub fn nonManifold(a: Allocator) !PMesh {
        return dup(a, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0.5 }, .{ 0, -1, 0.5 }, .{ 0, 0.2, -1 } }, &.{ 0, 3, 6, 9 }, &.{ 0, 1, 2, 1, 0, 3, 0, 1, 4 });
    }
    /// Polygons of 0, 1, 2 corners, one that visits a vertex twice, a loose vertex.
    pub fn odd(a: Allocator) !PMesh {
        return dup(a, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 1 }, .{ 2, 2, 2 }, .{ 9, 9, 9 } }, &.{ 0, 0, 1, 3, 8, 12 }, &.{ 0, 1, 2, 0, 1, 2, 0, 3, 3, 2, 1, 0 });
    }
    /// A closed torus of nu x nv quads around Y.
    pub fn torus(a: Allocator, nu: u32, nv: u32) !PMesh {
        const v = try a.alloc(V3, nu * nv);
        errdefer a.free(v);
        const o = try a.alloc(u32, nu * nv + 1);
        errdefer a.free(o);
        const l = try a.alloc(u32, nu * nv * 4);
        for (0..nu) |i| {
            for (0..nv) |j| {
                const u = fi(i) / fi(nu) * 6.2831855;
                const w = fi(j) / fi(nv) * 6.2831855;
                const r = 2.0 + @cos(w);
                v[i * nv + j] = .{ r * @cos(u), @sin(w), r * @sin(u) };
                const q = (i * nv + j) * 4;
                const ip = (i + 1) % nu;
                const jp = (j + 1) % nv;
                o[i * nv + j] = @intCast(q);
                l[q] = @intCast(i * nv + j);
                l[q + 1] = @intCast(i * nv + jp);
                l[q + 2] = @intCast(ip * nv + jp);
                l[q + 3] = @intCast(ip * nv + j);
            }
        }
        o[nu * nv] = nu * nv * 4;
        return .{ .verts = v, .poff = o, .loops = l };
    }
};

const T = std.testing;
const allocT = std.testing.allocator;
const eqI = T.expectEqual;

fn near(want: f64, got: f64, tol: f64) !void {
    try T.expectApproxEqAbs(want, got, tol);
}
/// Half a cube: x in 0..1, open on the x = 0 side.
fn halfCube(a: Allocator) !PMesh {
    return check.dup(a, &.{
        .{ 0, -1, -1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ 0, 1, -1 },
        .{ 0, -1, 1 },  .{ 1, -1, 1 },  .{ 1, 1, 1 },  .{ 0, 1, 1 },
    }, &.{ 0, 4, 8, 12, 16, 20 }, &.{ 0, 3, 2, 1, 4, 5, 6, 7, 0, 1, 5, 4, 1, 2, 6, 5, 2, 3, 7, 6 });
}

test "triangles: a flat ear waits, so none has no area" {
    const p = try check.dup(allocT, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 1, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } }, &.{ 0, 6 }, &.{ 0, 1, 2, 3, 4, 5 });
    defer p.deinit(allocT);
    var arena = std.heap.ArenaAllocator.init(allocT);
    defer arena.deinit();
    const tris = try triangulate(arena.allocator(), try view(p));
    try eqI(@as(usize, 12), tris.len);
    var i: usize = 0;
    var area: f32 = 0;
    while (i < 12) : (i += 3) {
        const n = m.cross(m.sub(p.verts[tris[i + 1]], p.verts[tris[i]]), m.sub(p.verts[tris[i + 2]], p.verts[tris[i]]));
        try T.expect(n[2] > 0.5);
        area += n[2] / 2;
    }
    try near(2, area, 1e-6);
}

test "mirror: half a cube welds shut along the plane" {
    const h = try halfCube(allocT);
    defer h.deinit(allocT);
    try T.expect(!try check.closed(h));
    const r = try mirror(allocT, h, 0, 0.001);
    defer r.deinit(allocT);
    try eqI(@as(usize, 12), r.verts.len); // 4 shared + 4 + 4
    try eqI(@as(usize, 10), r.faces());
    try T.expect(try check.closed(r));
    try near(8, check.volume(r), 1e-5);
    try T.expect(check.outward(r));
    const b = check.box(r);
    try eqI(@as(f32, -1), b[0][0]);
    try eqI(@as(f32, 1), b[1][0]);
    // every vertex has its mirror image
    for (r.verts) |p| {
        var found = false;
        for (r.verts) |q| {
            if (q[0] == -p[0] and q[1] == p[1] and q[2] == p[2]) found = true;
        }
        try T.expect(found);
    }
}

test "mirror: merge distance snaps to the plane, the axis clamps" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const r = try mirror(allocT, c, 7, 0.001); // axis 7 -> 2
    defer r.deinit(allocT);
    try eqI(@as(usize, 16), r.verts.len);
    try eqI(@as(usize, 12), r.faces());
    try near(16, check.volume(r), 1e-5); // both copies face out
    const r2 = try mirror(allocT, c, 1, 1000); // merge 1000 -> 10: all on the plane
    defer r2.deinit(allocT);
    try eqI(@as(usize, 8), r2.verts.len);
    for (r2.verts) |p| try eqI(@as(f32, 0), p[1]);
    try eqI(@as(f32, -1), c.verts[0][1]); // the input stays
}

test "array: offsets are relative to the size" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const r = try array(allocT, c, 3, 1, 0, 0);
    defer r.deinit(allocT);
    try eqI(@as(usize, 24), r.verts.len);
    try eqI(@as(usize, 18), r.faces());
    try T.expect(try check.closed(r));
    try near(24, check.volume(r), 1e-5);
    const b = check.box(r);
    try eqI(@as(f32, 5), b[1][0]); // 1 + 2 steps of 2
    try eqI(@as(f32, -1), b[0][0]);
    const r2 = try array(allocT, c, 2, 0.5, -1.5, 0.25);
    defer r2.deinit(allocT);
    try eqI(V3{ 0, -4, -0.5 }, r2.verts[8 + 0]); // (-1,-1,-1) + (1,-3,.5)
    const r3 = try array(allocT, c, 0, 1, 0, 0); // count 0 -> 1
    defer r3.deinit(allocT);
    try eqI(@as(usize, 8), r3.verts.len);
    const r4 = try array(allocT, c, 5000, 1, 0, 0); // -> 1000
    defer r4.deinit(allocT);
    try eqI(@as(usize, 8000), r4.verts.len);
    try eqI(@as(usize, 6000), r4.faces());
    try T.expect(r4.poff[6000] == 24000);
}

test "array: too much output is an error, not an out-of-memory machine" {
    const t = try check.torus(allocT, 300, 300); // 360k loops x 1000
    defer t.deinit(allocT);
    try T.expectError(error.TooBig, array(allocT, t, 1000, 1, 0, 0));
}

test "solidify: a closed mesh gets an inner shell" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const r = try solidify(allocT, c, 0.1);
    defer r.deinit(allocT);
    try eqI(@as(usize, 16), r.verts.len);
    try eqI(@as(usize, 12), r.faces());
    // the corners move along the diagonal
    const s: f64 = 1.0 - 0.1 / @sqrt(3.0);
    try near(s, @abs(r.verts[8][0]), 1e-6);
    try near(8.0 - 8.0 * s * s * s, check.volume(r), 1e-4);
    const hollow = try solidify(allocT, c, -0.1); // outwards: the shell inverts
    defer hollow.deinit(allocT);
    try T.expect(check.volume(hollow) < 0);
}

test "solidify: rims close open edges" {
    const p = try check.plane(allocT);
    defer p.deinit(allocT);
    const r = try solidify(allocT, p, 0.25);
    defer r.deinit(allocT);
    try eqI(@as(usize, 8), r.verts.len);
    try eqI(@as(usize, 6), r.faces());
    try T.expect(try check.closed(r));
    try near(1.0, check.volume(r), 1e-5); // 4 * 0.25
    const t = try check.tri(allocT);
    defer t.deinit(allocT);
    const r2 = try solidify(allocT, t, 0.5);
    defer r2.deinit(allocT);
    try eqI(@as(usize, 5), r2.faces());
    try T.expect(try check.closed(r2));
    const n = try check.nonManifold(allocT);
    defer n.deinit(allocT);
    const r3 = try solidify(allocT, n, 0.1);
    defer r3.deinit(allocT);
    try eqI(@as(usize, 6 + 6), r3.faces()); // 6 open edges; the shared one has no rim
}

test "bevel: the cube, as the binary gives it" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const Case = struct { w: f32, s: u32, v: usize, f: usize, l: usize, vol: f64 };
    for ([_]Case{
        .{ .w = 0.1, .s = 1, .v = 24, .f = 26, .l = 96, .vol = 7.885333 },
        .{ .w = 0.1, .s = 3, .v = 72, .f = 50, .l = 240, .vol = 7.952713 },
        .{ .w = 0.3, .s = 2, .v = 48, .f = 38, .l = 168, .vol = 7.523000 },
    }) |e| {
        const r = try bevel(allocT, c, e.w, e.s, 30);
        defer r.deinit(allocT);
        try eqI(e.v, r.verts.len);
        try eqI(e.f, r.faces());
        try eqI(e.l, r.loops.len);
        try T.expect(try check.closed(r));
        try T.expect(check.outward(r));
        try near(e.vol, check.volume(r), 1e-4);
        try eqI(@as(i64, 2), try check.euler(r));
        const b = check.box(r);
        try eqI(@as(f32, 1), b[1][1]);
    }
}

test "bevel: the angle picks the edges" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const r = try bevel(allocT, c, 0.1, 2, 89);
    defer r.deinit(allocT);
    try eqI(@as(usize, 48), r.verts.len);
    // at 90 the cube's edges are no sharper than the angle: nothing to do
    const none = try bevel(allocT, c, 0.1, 2, 90);
    defer none.deinit(allocT);
    try eqI(@as(usize, 8), none.verts.len);
    try eqI(@as(usize, 6), none.faces());
    try T.expectEqualSlices(u32, c.loops, none.loops);
    const p = try check.plane(allocT);
    defer p.deinit(allocT);
    const flat = try bevel(allocT, p, 0.2, 3, 30); // boundary edges never bevel
    defer flat.deinit(allocT);
    try eqI(@as(usize, 4), flat.verts.len);
    try eqI(@as(usize, 1), flat.faces());
}

test "bevel: the width is held to 45% of the shorter edge" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const r = try bevel(allocT, c, 100, 1, 30);
    defer r.deinit(allocT);
    try eqI(@as(usize, 24), r.verts.len);
    try near(2.168, check.volume(r), 1e-3); // as the binary gives it
    for (r.verts) |p| {
        var inner: u32 = 0;
        for (p) |x| {
            if (@abs(x) < 1) {
                try near(0.1, @abs(x), 1e-5); // 1 - 0.45 * 2
                inner += 1;
            }
        }
        try eqI(@as(u32, 2), inner);
    }
}

test "decimate: clusters by the grid" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const same = try decimate(allocT, c, 0.5); // target 4; each corner stays alone
    defer same.deinit(allocT);
    try eqI(@as(usize, 8), same.verts.len);
    try eqI(@as(usize, 6), same.faces());
    try near(8, check.volume(same), 1e-5);
    const one = try decimate(allocT, c, 1);
    defer one.deinit(allocT);
    try T.expectEqualSlices(V3, c.verts, one.verts);

    const t = try check.torus(allocT, 48, 24);
    defer t.deinit(allocT);
    const r = try decimate(allocT, t, 0.25);
    defer r.deinit(allocT);
    try eqI(@as(usize, 280), r.verts.len); // as the binary gives it
    try eqI(@as(usize, 392), r.faces());
    try near(36.373733, check.volume(r), 0.01);
    // means of the input stay inside its box, and every polygon has three corners
    const b0 = check.box(t);
    const b1 = check.box(r);
    for (0..3) |i| {
        try T.expect(b1[0][i] >= b0[0][i] and b1[1][i] <= b0[1][i]);
        try T.expect(b1[1][i] - b1[0][i] > (b0[1][i] - b0[0][i]) * 0.8);
    }
    for (0..r.faces()) |f| {
        const idx = r.poly(f);
        try T.expect(idx.len >= 3);
        for (idx, 0..) |x, i| try T.expect(x != idx[(i + 1) % idx.len]);
    }
    // no vertex left unused
    var used = try allocT.alloc(bool, r.verts.len);
    defer allocT.free(used);
    @memset(used, false);
    for (r.loops) |x| used[x] = true;
    for (used) |u| try T.expect(u);
}

test "remesh: voxel quads on the cube, as the binary gives them" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const Case = struct { v: f32, nv: usize, nf: usize, vol: f64 };
    for ([_]Case{
        .{ .v = 0.25, .nv = 386, .nf = 384, .vol = 7.654637 },
        .{ .v = 0.5, .nv = 98, .nf = 96, .vol = 6.737099 },
    }) |e| {
        const r = try remesh(allocT, c, e.v);
        defer r.deinit(allocT);
        try eqI(e.nv, r.verts.len);
        try eqI(e.nf, r.faces());
        try eqI(e.nf * 4, r.loops.len);
        try T.expect(try check.closed(r));
        try T.expect(check.outward(r));
        try near(e.vol, check.volume(r), 1e-3);
        try eqI(@as(i64, 2), try check.euler(r));
    }
}

test "remesh: nothing inside gives the input back" {
    const t = try check.tri(allocT);
    defer t.deinit(allocT);
    const r = try remesh(allocT, t, 0.25); // flat in YZ: no crossings
    defer r.deinit(allocT);
    try T.expectEqualSlices(V3, t.verts, r.verts);
    try T.expectEqualSlices(u32, t.loops, r.loops);
}

test "remesh: a torus keeps its hole and its size" {
    const t = try check.torus(allocT, 48, 24);
    defer t.deinit(allocT);
    const r = try remesh(allocT, t, 0.2);
    defer r.deinit(allocT);
    try eqI(@as(usize, 3738), r.verts.len); // as the binary gives it
    try eqI(@as(usize, 3792), r.faces());
    try near(35.180373, check.volume(r), 0.01);
    // surface nets can pinch (an edge of four faces, as in the original), but
    // every edge is walked as often one way as the other: no holes
    try T.expect(try check.watertight(r));
}

test "remesh: a voxel too fine coarsens to the sample limit" {
    // 200 units long and flat: 0.01 voxels would need 2e12 samples
    const v = [_]V3{ .{ -100, -1, -1 }, .{ 100, -1, -1 }, .{ 100, 1, -1 }, .{ -100, 1, -1 }, .{ -100, -1, 1 }, .{ 100, -1, 1 }, .{ 100, 1, 1 }, .{ -100, 1, 1 } };
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    const p = PMesh{ .verts = @constCast(&v), .poff = c.poff, .loops = c.loops };
    const r = try remesh(allocT, p, 0.01);
    defer r.deinit(allocT);
    try T.expect(try check.closed(r));
    try T.expect(r.verts.len > 1000 and r.verts.len < 1000000);
    try near(800, check.volume(r), 40);
}

test "degenerate inputs give sensible meshes, whatever the modifier" {
    const makers = [_]*const fn (Allocator) anyerror!PMesh{ check.empty, check.tri, check.plane, check.nonManifold, check.odd };
    for (makers) |mk| {
        const p = try mk(allocT);
        defer p.deinit(allocT);
        const snapshot = try p.clone(allocT);
        defer snapshot.deinit(allocT);
        const rs = [_]PMesh{
            try mirror(allocT, p, 0, 0.5),
            try array(allocT, p, 3, 1, 1, 0),
            try solidify(allocT, p, 0.1),
            try bevel(allocT, p, 0.1, 3, 30),
            try bevel(allocT, p, 0.1, 1, 0),
            try decimate(allocT, p, 0.3),
            try remesh(allocT, p, 0.3),
        };
        defer for (rs) |r| r.deinit(allocT);
        for (rs) |r| { // well formed
            try T.expect(r.poff.len >= 1);
            try eqI(@as(u32, 0), r.poff[0]);
            try eqI(r.loops.len, @as(usize, r.poff[r.faces()]));
            for (r.loops) |x| try T.expect(x < r.verts.len);
        }
        try T.expectEqualSlices(V3, snapshot.verts, p.verts); // input untouched
        try T.expectEqualSlices(u32, snapshot.loops, p.loops);
        try T.expectEqualSlices(u32, snapshot.poff, p.poff);
    }
}

test "no polygons, and poff missing altogether" {
    const p = PMesh{ .verts = &.{}, .poff = &.{}, .loops = &.{} };
    const r = try mirror(allocT, p, 0, 0);
    defer r.deinit(allocT);
    try eqI(@as(usize, 0), r.faces());
    const d = try decimate(allocT, p, 0.5);
    defer d.deinit(allocT);
    try eqI(@as(usize, 0), d.verts.len);
    const e = try remesh(allocT, p, 0.5);
    defer e.deinit(allocT);
    try eqI(@as(usize, 0), e.verts.len);
}

test "bad indices are refused, NaN and huge coordinates survive" {
    const v = [_]V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    var o = [_]u32{ 0, 3 };
    var l = [_]u32{ 0, 1, 7 };
    const bad = PMesh{ .verts = @constCast(&v), .poff = &o, .loops = &l };
    try T.expectError(error.BadMesh, mirror(allocT, bad, 0, 0));
    try T.expectError(error.BadMesh, bevel(allocT, bad, 0.1, 1, 30));
    var o2 = [_]u32{ 0, 5 };
    l[2] = 2;
    const bad2 = PMesh{ .verts = @constCast(&v), .poff = &o2, .loops = &l };
    try T.expectError(error.BadMesh, remesh(allocT, bad2, 1));

    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    for ([_]f32{ nan, inf, -inf, 3.0e38 }) |x| {
        c.verts[2] = .{ x, 0, 1 };
        c.verts[6] = .{ 0, x, 1 };
        const rs = [_]PMesh{
            try mirror(allocT, c, 0, nan),
            try array(allocT, c, 3, nan, 1, 0),
            try solidify(allocT, c, nan),
            try bevel(allocT, c, 0.1, 2, nan),
            try decimate(allocT, c, 0.5),
            try decimate(allocT, c, nan),
            try remesh(allocT, c, 0.5),
            try remesh(allocT, c, nan),
        };
        for (rs) |r| r.deinit(allocT);
    }
}

fn runAll(a: Allocator, p: PMesh) !void {
    (try mirror(a, p, 0, 0.1)).deinit(a);
    (try array(a, p, 3, 1, 0, 0)).deinit(a);
    (try solidify(a, p, 0.1)).deinit(a);
    (try bevel(a, p, 0.1, 3, 30)).deinit(a);
    (try decimate(a, p, 0.5)).deinit(a);
    (try remesh(a, p, 0.5)).deinit(a);
}

test "running out of memory leaks nothing" {
    const c = try pmesh.testCube(allocT);
    defer c.deinit(allocT);
    try T.checkAllAllocationFailures(allocT, runAll, .{c});
}
