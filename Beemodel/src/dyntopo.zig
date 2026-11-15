// Dynamic topology for sculpt mode (dyntopo.s). With it on, sculpt mode works on its
// own copy of the triangles (pos, tris, with room to grow). After each dab, every
// quarter radius of the way, remesh() changes the triangles inside the brush: edges
// longer than the detail size are split at their middle, those shorter than 0.4 of
// it collapse to their middle when that keeps the surface a manifold (the ends share
// exactly two neighbours, no triangle flips, no vertex is left with fewer than three
// edges). The leaves around are gathered with an edge hash (a vertex ring index for
// collapses); only those leaves get new triangle and vertex lists, boxes, and their
// splats drawn again.
//
// The detail is in pixels: brush radius / sculpt.radius x detail. At the end of the
// stroke the copy becomes the object's mesh: triangles, in leaf order, and nothing
// else of the old mesh (no UVs, seams, shape keys, weights: as the original's
// mesh_new). The step before keeps the old mesh, so undo needs nothing here.
//
// Everything runs on the calling thread and in the original's order, so that the same
// stroke gives the same triangles in the same order. Each array below has the
// original's name without its rm_ prefix; the frame arena's scratch stays between
// dabs, so a dab maps nothing once the arrays have their size.
const std = @import("std");
const linux = std.os.linux;
const m = @import("math.zig");
const sc = @import("sculpt.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const stroke = @import("stroke.zig");
const A = @import("alloc.zig").A;

const V3 = m.V3;
const minss = stroke.minss;
const maxss = stroke.maxss;

const DEAD: u32 = 0xffffffff; // a triangle's first corner: removed
const NONE: u32 = 0xffffffff;
const hashk: u64 = 0x9E3779B97F4A7C15;
const quarter: f32 = 0.25;
const half: f32 = 0.5;
const d04: f32 = 0.4;
const cos2: f32 = 0.25; // (cos 60 deg)^2: no flip
const d049: f32 = 0.49; // 0.7^2
const q2_min: f32 = 0.0009; // (0.03)^2: triangle shape
const tiny: f32 = 1.0e-30;
const finer: f32 = 0.8;
const coarser: f32 = 1.25;
const dmin: f32 = 2.0;
const dmax: f32 = 64.0;

/// The original counts in 32 bits; a mesh's loops must fit them too.
const max_tris: u64 = 0x50000000;
const max_verts: u64 = 0x50000000;

pub var on: bool = false; // sc_dyn
pub var detail: f32 = 10; // dyn_detail, pixels

var dw_pos: []V3 = &.{}; // the working copy
var dw_tris: [][3]u32 = &.{}; //  (DEAD first corner: gone)
var vown: []u32 = &.{}; // per vertex: the leaf owning it
var vst: []u32 = &.{}; // stamps, local ids
var vloc: []u32 = &.{};
var mcarry: []u8 = &.{}; // the mask across a rebuild
var mcarry_n: u32 = 0;
var tri_used: u32 = 0; // triangle-id pool in use
var dy_serial: u32 = 0;
var last: [8]struct { p: V3 = .{ 0, 0, 0 }, have: bool = false } = @splat(.{});

// one remesh
var r2: f32 = 0;
var dmax2: f32 = 0;
var dmin2: f32 = 0;
var mid: V3 = .{ 0, 0, 0 };
var nL: u32 = 0;
var nT: u32 = 0;
var Tcap: u32 = 0;
var hmask: u32 = 0;
var nvl: u32 = 0;
var cs: u32 = 0;
var changed: bool = false;

const Edge = extern struct { key: u64, h0: i32, h1: i32 };
const H_BAD: i32 = -2;

var L: []u32 = &.{}; // the leaves touched
var lidx: []u32 = &.{}; // per leaf: its place in L, or NONE
var T: []u32 = &.{}; // their triangles (local k -> id),
var TL: []u32 = &.{}; //  each one's leaf,
var TM: []u8 = &.{}; //  changed in this pass
var H: []Edge = &.{}; // edge hash
var roff: []u32 = &.{}; // vertex rings (local vertex -> k)
var rt: []u32 = &.{};
var vlock: []u8 = &.{};
var nb: []u32 = &.{};
var fcnt: []u32 = &.{}; // rm_finish: live triangles per touched leaf
var fbuf: []u32 = &.{}; //  a vertex list on its way

// memory --------------------------------------------------------------------------

/// At least n of them, contents not kept (scratch: it stays between dabs).
fn scratch(comptime Ty: type, s: *[]Ty, n: usize) bool {
    if (s.len >= n) return true;
    const c = @max(n, s.len * 2);
    const b = sc.smap(Ty, c) orelse return false;
    sc.sfree(s);
    s.* = b;
    return true;
}

/// sgrow: at least n of them, moved when it must be, contents kept, the rest zero.
fn grow(comptime Ty: type, s: *[]Ty, n: usize) bool {
    if (n <= s.len) return true;
    if (s.len == 0) {
        s.* = sc.smap(Ty, n) orelse return false;
        return true;
    }
    const old = std.mem.alignForward(usize, s.len * @sizeOf(Ty), 4096);
    const new = std.mem.alignForward(usize, n * @sizeOf(Ty), 4096);
    var p: [*]Ty = s.ptr;
    if (new > old) {
        const rc = linux.mremap(@ptrCast(s.ptr), old, new, .{ .MAYMOVE = true }, null);
        if (linux.errno(rc) != .SUCCESS) return false;
        p = @ptrFromInt(rc);
    }
    s.* = p[0..n];
    return true;
}

/// A list's pool: room for that many, doubling (ids count in 32 bits).
fn pool(s: *[]u32, n: u64) bool {
    if (n >= 0xf0000000) return false;
    return n <= s.len or grow(u32, s, @min(@max(2 * s.len, n), 0xf0000000));
}

fn noMem() void {
    app.toast(.warn, "dyntopo: out of memory", .{});
}

/// dyn_alloc: sculpt_build, with pos, tris, nv, nt the mesh's: the room the per-vertex
/// arrays get; dyntopo copies the positions and triangles (twice the room, and more).
pub fn alloc() bool {
    sc.capv = sc.nv;
    sc.capt = sc.nt;
    if (!on) return true;
    const cv = 2 * @as(u64, sc.nv) + 65536;
    const ct = 2 * @as(u64, sc.nt) + 131072;
    if (cv > max_verts or ct > max_tris) return false;
    sc.capv = @intCast(cv);
    sc.capt = @intCast(ct);
    dw_pos = sc.smap(V3, sc.capv) orelse return false;
    @memcpy(dw_pos[0..sc.nv], sc.pos[0..sc.nv]);
    sc.pos = dw_pos.ptr;
    dw_tris = sc.smap([3]u32, sc.capt) orelse return false;
    @memcpy(dw_tris[0..sc.nt], sc.tris[0..sc.nt]);
    sc.tris = dw_tris.ptr;
    vown = sc.smap(u32, sc.capv) orelse return false;
    vst = sc.smap(u32, sc.capv) orelse return false;
    vloc = sc.smap(u32, sc.capv) orelse return false;
    dy_serial = 0;
    return true;
}

/// dyn_free.
pub fn free() void {
    sc.sfree(&dw_pos);
    sc.sfree(&dw_tris);
    sc.sfree(&vown);
    sc.sfree(&vst);
    sc.sfree(&vloc);
    sc.sfree(&L);
    sc.sfree(&lidx);
    sc.sfree(&T);
    sc.sfree(&TL);
    sc.sfree(&TM);
    sc.sfree(&H);
    sc.sfree(&roff);
    sc.sfree(&rt);
    sc.sfree(&vlock);
    sc.sfree(&nb);
    sc.sfree(&fcnt);
    sc.sfree(&fbuf);
}

/// dyn_reserve: room in the working copy (and every per-vertex array) for that many.
fn reserve(v: u64, t: u64) bool {
    if (v > sc.capv) {
        const c = @max(2 * @as(u64, sc.capv), v);
        if (c > max_verts) return false;
        if (!grow(V3, &dw_pos, c)) return false;
        sc.pos = dw_pos.ptr; // (it moved)
        if (!grow(V3, &sc.vn, c) or !grow(u8, &sc.mask, c) or !grow(u32, &sc.stamp, c) or !grow(u8, &sc.rec, c)) return false;
        if (sc.acc.len > 0 and !grow([4]f32, &sc.acc, c)) return false; // (not made yet: left so)
        if (!grow(u32, &vown, c) or !grow(u32, &vst, c) or !grow(u32, &vloc, c)) return false;
        sc.capv = @intCast(c);
    }
    if (t > sc.capt) {
        const c = @max(2 * @as(u64, sc.capt), t);
        if (c > max_tris) return false;
        if (!grow([3]u32, &dw_tris, c)) return false;
        sc.tris = dw_tris.ptr;
        sc.capt = @intCast(c);
    }
    return true;
}

/// dyn_tail: sculpt_build, the leaves made: each list's room is its length; dyntopo:
/// each vertex's owner; a mask carried over a rebuild comes back.
pub fn tail() void {
    for (sc.nodes[0..sc.nnodes]) |*n| {
        n.tcap = n.tn;
        n.vcap = n.vn;
    }
    tri_used = sc.nt;
    if (on) {
        @memset(vown[0..sc.nv], NONE);
        for (sc.nodes[0..sc.nnodes], 0..) |*n, l| {
            for (sc.vl[n.voff .. n.voff + n.vown]) |v| vown[v] = @intCast(l);
        }
    }
    if (mcarry.len == 0) return;
    if (mcarry_n == sc.nv) {
        @memcpy(sc.mask[0..sc.nv], mcarry[0..sc.nv]);
        for (sc.mask[0..sc.nv]) |x| {
            if (x != 0) {
                sc.masked = true;
                break;
            }
        }
    }
    sc.sfree(&mcarry);
}

/// carry_mask: the mask, kept for the next build (when anything is masked). map:
/// vertex -> new index for the vertices stamped live; null: the same.
fn carryMask(n: u32, map: ?[]const u32) void {
    if (!sc.masked) return;
    sc.sfree(&mcarry);
    mcarry = sc.smap(u8, n) orelse return;
    mcarry_n = n;
    if (map) |t| {
        for (0..sc.nv) |v| {
            if (vst[v] == dy_serial) mcarry[t[v]] = sc.mask[v];
        }
    } else @memcpy(mcarry[0..n], sc.mask[0..n]);
}

// the operators --------------------------------------------------------------------

pub fn isOn() bool {
    return on;
}

/// sculpt.dyntopo: on / off, the leaves built again.
pub fn opToggle() void {
    defer app.dirty = true;
    if (!sc.on or sc.land or sc.stroking) return;
    if (sc.ext.owns.?()) return app.toast(.warn, "dyntopo: not on a multires level (level 0 sculpts the base)", .{});
    on = !on;
    carryMask(sc.nv, null); // (the mask stays)
    if (!sc.rebuild()) return sc.exit();
    if (on) app.toast(.ok, "dyntopo on, detail {d} px", .{stroke.trunc32(detail)}) else app.toast(.ok, "dyntopo off", .{});
}

/// sculpt.detail_finer, sculpt.detail_coarser.
pub fn setDetail(k: f32) void {
    detail = minss(maxss(detail * k, dmin), dmax);
    app.dirty = true;
}
pub fn opFiner() void {
    setDetail(finer);
}
pub fn opCoarser() void {
    setDetail(coarser);
}

// strokes --------------------------------------------------------------------------

/// dyn_reset, as a stroke begins (every mirror's).
pub fn reset() void {
    for (&last) |*l| l.have = false;
}

/// dyn_after_dab(radius (local), 0 or the mirror's mask): remesh around dab_p once the
/// brush is a quarter radius on (the sphere reaching back to the last one).
pub fn afterDab(r: f32, mirror: u32) void {
    if (!on or sc.brush_now == sc.GRAB or sc.brush_now == sc.MASK) return;
    const l = &last[mirror & 7]; // (each mirror its own)
    var rr = r;
    if (l.have) {
        var d: f32 = 0;
        for (0..3) |c| {
            const x = sc.dab_p[c] - l.p[c];
            d += x * x;
        }
        d = @sqrt(d);
        if (!(d >= r * quarter)) return;
        rr = r + d;
    }
    remesh(rr, r * detail / sc.radius); // the detail: radius / pixels x px
    l.p = sc.dab_p;
    l.have = true;
}

/// sc_dyn.
pub fn dyn() bool {
    return on;
}

/// dyn_commit: the end of a stroke: the working copy's live triangles become the
/// object's mesh (vertices in leaf order), the mask is carried, the leaves are built
/// again.
pub fn commit() void {
    dy_serial +%= 1; // number the live vertices
    const s = dy_serial;
    var nv2: u32 = 0;
    var nt2: u32 = 0;
    const tris = sc.tris;
    const nodes = sc.nodes[0..sc.nnodes];
    for (nodes) |*n| {
        nt2 += n.tn;
        for (sc.tri[n.toff .. n.toff + n.tn]) |t| {
            for (tris[t]) |v| {
                if (vst[v] == s) continue;
                vst[v] = s;
                vloc[v] = nv2;
                nv2 += 1;
            }
        }
    }
    if (nt2 == 0) return noMem(); // (nothing to make a mesh of: it stays)
    const verts = A.alloc(V3, nv2) catch return noMem();
    defer A.free(verts);
    const poff = A.alloc(u32, @as(usize, nt2) + 1) catch return noMem();
    defer A.free(poff);
    const loops = A.alloc(u32, @as(usize, nt2) * 3) catch return noMem();
    defer A.free(loops);
    for (0..sc.nv) |v| {
        if (vst[v] == s) verts[vloc[v]] = sc.pos[v];
    }
    for (poff, 0..) |*o, k| o.* = @intCast(k * 3);
    var q: usize = 0;
    for (nodes) |*n| {
        for (sc.tri[n.toff .. n.toff + n.tn]) |t| {
            for (tris[t]) |v| {
                loops[q] = vloc[v];
                q += 1;
            }
        }
    }
    const mi = scene.addMesh(verts, poff, loops) orelse return noMem();
    carryMask(nv2, vloc); // (keep the mask for the new build)
    const i = scene.findOid(sc.oid) orelse return;
    scene.objects[i].mesh = mi;
    if (!sc.rebuild()) sc.exit();
}

/// The console's sculpt.check, for the tests (a stroke under way too): the leaves'
/// lists and boxes as they should be. What is wrong, or "ok".
pub fn check() void {
    if (!sc.on or sc.land) return app.log("  sculpt.check: off", .{});
    var tris_seen: u64 = 0;
    for (sc.nodes[0..sc.nnodes], 0..) |*n, l| {
        if (n.tn > n.tcap or n.vn > n.vcap or n.vown > n.vn) return app.log("  sculpt.check: leaf {d}: room", .{l});
        tris_seen += n.tn;
        for (sc.tri[n.toff .. n.toff + n.tn]) |t| {
            if (t >= sc.nt or sc.tris[t][0] == DEAD) return app.log("  sculpt.check: leaf {d}: a dead triangle", .{l});
            for (sc.tris[t]) |v| {
                if (v >= sc.nv) return app.log("  sculpt.check: leaf {d}: vertex {d} of {d}", .{ l, v, sc.nv });
            }
        }
        var a: V3 = @splat(3.0e38);
        var b: V3 = @splat(-3.0e38);
        for (sc.vl[n.voff .. n.voff + n.vn], 0..) |v, k| {
            if (on and k < n.vown and vown[v] != l) return app.log("  sculpt.check: leaf {d}: vertex {d} is {d}'s", .{ l, v, vown[v] });
            for (0..3) |c| {
                a[c] = minss(a[c], sc.pos[v][c]);
                b[c] = maxss(b[c], sc.pos[v][c]);
            }
        }
        if (!std.meta.eql(a, n.min) or !std.meta.eql(b, n.max)) return app.log("  sculpt.check: leaf {d}: a stale box", .{l});
    }
    app.log("  sculpt.check ok: {d} triangles in the leaves of {d}", .{ tris_seen, sc.nt });
}

// remeshing ------------------------------------------------------------------------

inline fn tv(k: u32) *[3]u32 {
    return &sc.tris[T[k]];
}

inline fn nextc(c: u32) u32 {
    return if (c + 1 < 3) c + 1 else 0;
}

inline fn len2(a: u32, b: u32) f32 {
    const p = sc.pos[a];
    const q = sc.pos[b];
    const x = q[0] - p[0];
    const y = q[1] - p[1];
    const z = q[2] - p[2];
    return x * x + y * y + z * z;
}

/// Their middle (mid) is in the sphere.
inline fn midin(a: u32, b: u32) bool {
    const p = sc.pos[a];
    const q = sc.pos[b];
    var s: f32 = 0;
    for (0..3) |c| {
        const x = (q[c] + p[c]) * half;
        mid[c] = x;
        const y = x - sc.dab_p[c];
        s += y * y;
    }
    return !(s >= r2);
}

inline fn edgeKey(a0: u32, b0: u32) u64 {
    const a = @min(a0, b0);
    const b = @max(a0, b0);
    return (@as(u64, a) << 32 | b) +% 1;
}

inline fn firstSlot(key: u64) u32 {
    return @as(u32, @truncate((key *% hashk) >> 32)) & hmask;
}

/// A third half makes the edge unusable.
inline fn insert(a: u32, b: u32, half_id: i32) void {
    const key = edgeKey(a, b);
    var c = firstSlot(key);
    while (true) {
        const e = &H[c];
        if (e.key == 0) {
            e.* = .{ .key = key, .h0 = half_id, .h1 = -1 };
            return;
        }
        if (e.key == key) {
            if (e.h1 == -1 and e.h0 != H_BAD) {
                e.h1 = half_id;
            } else {
                e.h0 = H_BAD;
                e.h1 = H_BAD;
            }
            return;
        }
        c = (c + 1) & hmask;
    }
}

inline fn find(a: u32, b: u32) ?*const Edge {
    const key = edgeKey(a, b);
    var c = firstSlot(key);
    while (true) {
        const e = &H[c];
        if (e.key == 0) return null;
        if (e.key == key) return e;
        c = (c + 1) & hmask;
    }
}

/// The other half of the edge from that corner (local x 3 + corner), -1 when it has
/// none (or more than one).
inline fn other(k: u32, corner: u32) i32 {
    const self: i32 = @intCast(k * 3 + corner);
    const t = tv(k);
    const e = find(t[corner], t[nextc(corner)]) orelse return -1;
    if (e.h0 < 0 or e.h1 < 0) return -1;
    return if (e.h0 != self) e.h0 else e.h1;
}

/// rm_hash: the edge hash of the live triangles.
fn hashEdges() bool {
    var size: u32 = 64;
    const want = nT << 2;
    while (size < want) size += size;
    if (!scratch(Edge, &H, size)) return false;
    hmask = size - 1;
    @memset(std.mem.sliceAsBytes(H[0..size]), 0);
    var k: u32 = 0;
    while (k < nT) : (k += 1) {
        const t = tv(k);
        if (t[0] == DEAD) continue;
        var c: u32 = 0;
        while (c < 3) : (c += 1) insert(t[c], t[nextc(c)], @intCast(k * 3 + c));
    }
    return true;
}

fn clearMod() void {
    @memset(TM[0..nT], 0);
}

/// The corner its longest edge starts at, that edge's square.
fn longest(k: u32) struct { c: u32, l: f32 } {
    const t = tv(k);
    var best: f32 = 0;
    var e: u32 = 0;
    var c: u32 = 0;
    while (c < 3) : (c += 1) {
        const l = len2(t[c], t[nextc(c)]);
        if (l > best) {
            best = l;
            e = c;
        }
    }
    return .{ .c = e, .l = best };
}

/// Edges split: in each triangle not yet changed in this pass, its longest edge over
/// the detail (middle in the sphere).
fn splitPass() u32 {
    var done: u32 = 0;
    if (!hashEdges()) return 0;
    clearMod();
    const n0 = nT;
    var k: u32 = 0;
    while (k < n0) : (k += 1) {
        if (TM[k] != 0) continue;
        const t = tv(k);
        if (t[0] == DEAD) continue;
        const lg = longest(k); // its longest edge: over the detail,
        if (!(lg.l > dmax2)) continue;
        if (!midin(t[lg.c], t[nextc(lg.c)])) continue; //  its middle in the sphere
        const h = other(k, lg.c);
        if (h < 0) continue;
        const k2: u32 = @as(u32, @intCast(h)) / 3; // the other triangle, its corner
        const e2: u32 = @as(u32, @intCast(h)) % 3;
        if (k2 == k or TM[k2] != 0) continue;
        if (longest(k2).l * d049 > lg.l) continue; // (and not the short side of the other: no slivers)
        if (nT + 2 > Tcap) break;
        if (sc.nv >= sc.capv) break; // (room was reserved for this many)
        if (sc.nt + 2 > sc.capt) break;
        split(k, lg.c, k2, e2);
        done += 1;
    }
    return done;
}

/// The edge from corner e of k (= corner e2 of k2, the other way) is halved: a new
/// vertex m in the middle, (a b x) -> (a m x) + (m b x), (p q y) -> (p m y) + (m q y).
fn split(k: u32, e: u32, k2: u32, e2: u32) void {
    const t = tv(k);
    const t2 = tv(k2);
    const a = t[e];
    const cb = nextc(e);
    const b = t[cb];
    const x = t[nextc(cb)];
    const mv = sc.nv;
    sc.nv += 1;
    const pa = sc.pos[a];
    const pb = sc.pos[b];
    for (0..3) |c| sc.pos[mv][c] = (pa[c] + pb[c]) * half;
    vmerge(a, b, mv); // its normal, mask, no owner yet
    vown[mv] = NONE;
    t[cb] = mv; // k: (a m x)
    var id = sc.nt; // + (m b x)
    sc.nt += 1;
    sc.tris[id] = .{ mv, b, x };
    append(id, k);
    const cq = nextc(e2);
    const q = t2[cq];
    const y = t2[nextc(cq)];
    t2[cq] = mv; // (p m y)
    id = sc.nt; // + (m q y)
    sc.nt += 1;
    sc.tris[id] = .{ mv, q, y };
    append(id, k2);
    TM[k] = 1;
    TM[k2] = 1;
    changed = true;
}

/// A new local triangle in k's leaf, changed in this pass.
inline fn append(id: u32, k: u32) void {
    T[nT] = id;
    TL[nT] = TL[k];
    TM[nT] = 1;
    nT += 1;
}

/// normal: the two normalized; mask: the larger.
fn vmerge(a: u32, b: u32, into: u32) void {
    const p = sc.vn[a];
    const q = sc.vn[b];
    var x = p[0] + q[0];
    var y = p[1] + q[1];
    var z = p[2] + q[2];
    const s = x * x + y * y + z * z;
    if (s > tiny) {
        const k = 1.0 / @sqrt(s);
        x *= k;
        y *= k;
        z *= k;
    } else {
        x = p[0];
        y = p[1];
        z = p[2];
    }
    sc.vn[into] = .{ x, y, z };
    sc.mask[into] = @max(sc.mask[a], sc.mask[b]);
}

/// Local vertex ids (vloc, stamped) and each one's live triangles (roff, rt), locks
/// and link marks cleared.
fn rings() bool {
    dy_serial +%= 1;
    const s = dy_serial;
    var n: u32 = 0;
    var k: u32 = 0;
    while (k < nT) : (k += 1) {
        const t = tv(k);
        if (t[0] == DEAD) continue;
        for (t) |v| {
            if (vst[v] == s) continue;
            vst[v] = s;
            vloc[v] = n;
            n += 1;
        }
    }
    nvl = n;
    if (!scratch(u32, &roff, @as(usize, n) + 2)) return false;
    if (!scratch(u32, &rt, @as(usize, nT) * 3 + 4)) return false;
    if (!scratch(u8, &vlock, n)) return false;
    if (!scratch(u32, &nb, n)) return false;
    @memset(roff[0 .. n + 2], 0);
    @memset(vlock[0..n], 0);
    @memset(nb[0..n], 0);
    cs = 1;
    k = 0; // counts at +2 ...
    while (k < nT) : (k += 1) {
        const t = tv(k);
        if (t[0] == DEAD) continue;
        for (t) |v| roff[vloc[v] + 2] += 1;
    }
    var sum: u32 = 0; // ... prefix: roff[j + 1] = start of j (a cursor), roff[j] its start
    for (0..n) |c| {
        sum += roff[c + 2];
        roff[c + 2] = sum;
    }
    k = 0; // fill through the cursors at +1
    while (k < nT) : (k += 1) {
        const t = tv(k);
        if (t[0] == DEAD) continue;
        for (t) |v| {
            const j = vloc[v];
            rt[roff[j + 1]] = k;
            roff[j + 1] += 1;
        }
    }
    return true; // (now roff[j] .. roff[j + 1]: j's)
}

/// Edges collapsed (under 0.4 detail, middle in the sphere, one around a vertex a pass).
fn collapsePass() u32 {
    var done: u32 = 0;
    if (!hashEdges()) return 0;
    if (!rings()) return 0;
    clearMod();
    var k: u32 = 0;
    while (k < nT) : (k += 1) {
        if (TM[k] != 0) continue;
        const t = tv(k);
        if (t[0] == DEAD) continue;
        var e: u32 = 0;
        while (e < 3) : (e += 1) {
            const a = t[e];
            const b = t[nextc(e)];
            if (len2(a, b) >= dmin2) continue;
            if (!midin(a, b)) continue;
            if (other(k, e) < 0) continue;
            if (collapse(a, b)) {
                done += 1;
                break;
            }
        }
    }
    return done;
}

inline fn ring(v: u32) []const u32 {
    const j = vloc[v];
    return rt[roff[j]..roff[j + 1]];
}

/// (p1 - p0) x (p2 - p0)
inline fn triNormal(p: *const [3]V3) V3 {
    const e1x = p[1][0] - p[0][0];
    const e1y = p[1][1] - p[0][1];
    const e1z = p[1][2] - p[0][2];
    const e2x = p[2][0] - p[0][0];
    const e2y = p[2][1] - p[0][1];
    const e2z = p[2][2] - p[0][2];
    return .{ e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x };
}

/// (|normal| / sum of squared edges)^2 (0.083 equilateral, 0 flat).
inline fn triQual2(p: *const [3]V3) f32 {
    const n = triNormal(p);
    const a = n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
    var b: f32 = 0;
    for (0..3) |c| {
        const j = if (c + 1 < 3) c + 1 else 0;
        for (0..3) |w| {
            const x = p[c][w] - p[j][w];
            b += x * x;
        }
    }
    b = maxss(b * b, tiny);
    return a / b;
}

/// a, b with mid their middle -> collapsed: b moves to the middle, a's triangles take
/// b, the two on the edge go.
fn collapse(a: u32, b: u32) bool {
    const la = vloc[a];
    const lb = vloc[b];
    if (vlock[la] != 0 or vlock[lb] != 0) return false; // not locked this pass
    // each ring: unchanged this pass; every edge at the vertex with two triangles (no
    // border, nothing odd)
    const ends = [2]u32{ a, b };
    var valence: [2]u32 = undefined;
    for (ends, 0..) |v, side| {
        const r = ring(v);
        valence[side] = @intCast(r.len);
        for (r) |tk| {
            if (TM[tk] != 0) return false;
            const q = tv(tk);
            var c: u32 = 0; // its corner at the vertex
            while (c < 3 and q[c] != v) c += 1;
            if (c == 3) return false;
            if (other(tk, c) < 0) return false; // the edge out of it ...
            if (other(tk, if (c + 2 < 3) c + 2 else c + 2 - 3) < 0) return false; // ... and the one into it
        }
    }
    if (valence[0] + valence[1] < 7) return false; // merged valence va + vb - 4 >= 3
    // link: exactly two shared neighbours, each keeping three edges or more
    cs += 2;
    const s = cs;
    for (ring(a)) |tk| {
        for (tv(tk)) |d| {
            if (d != a) nb[vloc[d]] = s;
        }
    }
    var shared: u32 = 0;
    for (ring(b)) |tk| {
        for (tv(tk)) |d| {
            if (d == a or d == b) continue;
            const ld = vloc[d];
            if (nb[ld] != s) continue;
            nb[ld] = s + 1;
            shared += 1;
            if (roff[ld + 1] - roff[ld] < 4) return false;
        }
    }
    if (shared != 2) return false;
    // no triangle turns over: each one keeping a side, a or b at the middle
    for (ends) |v| {
        for (ring(v)) |tk| {
            const q = tv(tk);
            var both: u32 = 0; // with both: it goes
            for (q) |d| {
                if (d == a or d == b) both += 1;
            }
            if (both >= 2) continue;
            var p: [3]V3 = .{ sc.pos[q[0]], sc.pos[q[1]], sc.pos[q[2]] };
            const q0 = triQual2(&p); // (its shape, before)
            const n0 = triNormal(&p);
            for (0..3) |c| {
                if (q[c] == a or q[c] == b) p[c] = mid;
            }
            const q1 = triQual2(&p); // no sliver: the shape stays over 0.03 (or no worse)
            if (!(q1 >= q2_min) and !(q1 >= q0)) return false;
            const n1 = triNormal(&p);
            const dot = n1[0] * n0[0] + n1[1] * n0[1] + n1[2] * n0[2];
            if (!(dot > 0)) return false;
            const l1 = n1[0] * n1[0] + n1[1] * n1[1] + n1[2] * n1[2];
            const l0 = n0[0] * n0[0] + n0[1] * n0[1] + n0[2] * n0[2];
            if (!(dot * dot > l1 * l0 * cos2)) return false;
        }
    }
    // collapse: b to the middle (normal, mask merged), a's triangles to b
    sc.pos[b] = mid;
    vmerge(a, b, b);
    for (ring(a)) |tk| {
        const q = tv(tk);
        if (q[0] == b or q[1] == b or q[2] == b) {
            q[0] = DEAD;
        } else {
            for (q) |*d| {
                if (d.* == a) d.* = b;
            }
        }
    }
    for (ends) |v| { // both rings: changed; both: locked
        for (ring(v)) |tk| TM[tk] = 1;
    }
    vlock[la] = 1;
    vlock[lb] = 1;
    changed = true;
    return true;
}

/// dyn_remesh(radius, detail; both local, around dab_p): split and collapse inside
/// that sphere, the leaves around brought up to date.
pub fn remesh(r: f32, det: f32) void {
    r2 = r * r;
    dmax2 = det * det;
    const dm = det * d04;
    dmin2 = dm * dm;
    changed = false;
    // the leaves within r + 2 edges
    const nl = sc.reach(2, r + (sc.maxedge + sc.maxedge));
    if (nl == 0) return;
    nL = nl;
    if (!scratch(u32, &L, nl)) return noMem();
    const list = sc.hits[2 * @as(usize, sc.nnodes) ..];
    @memcpy(L[0..nl], list[0..nl]);
    if (!scratch(u32, &lidx, sc.nnodes)) return noMem(); // leaf -> its place (NONE: not here)
    @memset(lidx[0..sc.nnodes], NONE);
    var total: u64 = 0; // their triangles
    for (L[0..nl], 0..) |l, k| {
        lidx[l] = @intCast(k);
        total += sc.nodes[l].tn;
    }
    // room: each split one vertex, two triangles
    if (!reserve(sc.nv + total * 4 + 64, sc.nt + total * 8 + 64)) return noMem();
    const cap = total * 8 + 64;
    if (cap > max_tris) return noMem();
    Tcap = @intCast(cap);
    if (!scratch(u32, &T, cap) or !scratch(u32, &TL, cap) or !scratch(u8, &TM, cap)) return noMem();
    // the lists' pools, for the most this can leave: nothing fails once triangles moved
    if (!pool(&sc.tri, tri_used + 2 * cap + 64 * @as(u64, nl))) return noMem();
    if (!pool(&sc.vl, sc.nvl + 6 * cap + 64 * @as(u64, nl))) return noMem();
    if (!scratch(u32, &fcnt, nl) or !scratch(u32, &fbuf, 3 * cap + 16)) return noMem();
    var q: u32 = 0; // fill: id, leaf
    for (L[0..nl]) |l| {
        const n = &sc.nodes[l];
        for (sc.tri[n.toff .. n.toff + n.tn]) |t| {
            T[q] = t;
            TL[q] = l;
            q += 1;
        }
    }
    nT = q;
    var passes: u32 = 4; // splits: up to four passes
    while (passes > 0 and splitPass() != 0) passes -= 1;
    _ = collapsePass();
    if (changed) finish();
}

/// The touched leaves: their live triangles (moved to the end of the pool when they
/// outgrow their room), owners for vertices that lost theirs, vertex lists (own
/// first), boxes; splats drawn again; the longest edge.
fn finish() void {
    const live = fcnt[0..nL]; // live triangles per leaf
    @memset(live, 0);
    var k: u32 = 0;
    while (k < nT) : (k += 1) {
        if (tv(k)[0] != DEAD) live[lidx[TL[k]]] += 1;
    }
    for (L[0..nL], live) |l, c| {
        const n = &sc.nodes[l];
        n.tn = 0;
        if (c > n.tcap) { // outgrown: to the end, twice the room
            const room = c + c + 64;
            n.toff = tri_used;
            n.tcap = room;
            tri_used += room;
        }
    }
    k = 0; // refill
    while (k < nT) : (k += 1) {
        if (tv(k)[0] == DEAD) continue;
        const n = &sc.nodes[TL[k]];
        sc.tri[n.toff + n.tn] = T[k];
        n.tn += 1;
    }
    dy_serial +%= 1; // owners: a touched leaf's go
    var s = dy_serial;
    k = 0;
    while (k < nT) : (k += 1) {
        const t = tv(k);
        if (t[0] == DEAD) continue;
        for (t) |v| {
            if (vst[v] == s) continue;
            vst[v] = s;
            const o = vown[v];
            if (o >= sc.nnodes) continue; // (none yet)
            if (lidx[o] == NONE) continue;
            vown[v] = NONE;
        }
    }
    for (L[0..nL]) |l| { // ... to the first touched leaf with it
        const n = &sc.nodes[l];
        for (sc.tri[n.toff .. n.toff + n.tn]) |t| {
            for (sc.tris[t]) |v| {
                if (vown[v] == NONE) vown[v] = l;
            }
        }
    }
    for (L[0..nL]) |l| { // vertex lists: through a buffer
        const n = &sc.nodes[l];
        dy_serial +%= 1;
        s = dy_serial;
        var c: u32 = 0;
        var sub: u32 = 0; // own, then the rest
        while (sub < 2) : (sub += 1) {
            for (sc.tri[n.toff .. n.toff + n.tn]) |t| {
                for (sc.tris[t]) |v| {
                    if (vst[v] == s) continue;
                    if (sub == 0 and vown[v] != l) continue;
                    vst[v] = s;
                    fbuf[c] = v;
                    c += 1;
                }
            }
            if (sub == 0) n.vown = c;
        }
        if (c > n.vcap) { // its room (else at the end)
            const room = c + c + 64;
            n.voff = sc.nvl;
            n.vcap = room;
            sc.nvl += room;
        }
        n.vn = c;
        @memcpy(sc.vl[n.voff..][0..c], fbuf[0..c]);
        sc.lchg[l] = 1;
        sc.nodeBox(l);
    }
    var e: f32 = 0; // the longest edge, at least
    k = 0;
    while (k < nT) : (k += 1) {
        const t = tv(k);
        if (t[0] == DEAD) continue;
        var c: u32 = 0;
        while (c < 3) : (c += 1) e = maxss(e, len2(t[c], t[nextc(c)]));
    }
    sc.maxedge = maxss(@sqrt(e), sc.maxedge);
}

test "the edge hash: a third half spoils an edge, order does not matter" {
    const buf = try A.alloc(Edge, 64);
    defer A.free(buf);
    @memset(std.mem.sliceAsBytes(buf), 0);
    const keep = H;
    defer H = keep;
    H = buf;
    hmask = 63;
    insert(3, 9, 12);
    insert(9, 3, 40);
    const e = find(9, 3).?;
    try std.testing.expectEqual(@as(i32, 12), e.h0);
    try std.testing.expectEqual(@as(i32, 40), e.h1);
    insert(3, 9, 50);
    try std.testing.expectEqual(H_BAD, find(3, 9).?.h0);
    insert(3, 9, 51);
    try std.testing.expectEqual(H_BAD, find(3, 9).?.h1);
    try std.testing.expect(find(1, 2) == null);
}

test "a triangle's shape: equilateral, flat" {
    const s3: f32 = 0.8660254;
    const eq = [3]V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0.5, s3, 0 } };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0833), triQual2(&eq), 0.001);
    const flat = [3]V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 2, 0, 0 } };
    try std.testing.expectEqual(@as(f32, 0), triQual2(&flat));
}
