// "Hive", the path tracer's scene (hive.s): the scene snapshot as a triangle
// soup in world space (v0, e1, e2 per triangle, corner normals smoothed
// across corners closer than 30 degrees, a material) and a binned-SAH BVH.
// trace() finds the nearest hit, occluded() any hit before a distance.
// The snapshot is taken on the main thread; the queries run on every core
// and only read it.
const std = @import("std");
const mods = @import("mods.zig");
const m = @import("math.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const preview = @import("preview.zig");
const bake = @import("bake.zig");
const gops = @import("graphops.zig");
const jobs = @import("jobs.zig");
const A = std.heap.page_allocator;

pub const Tri = extern struct {
    v0: m.V3,
    e1: m.V3,
    e2: m.V3,
};

pub const Node = extern struct {
    lo: m.V3,
    /// a leaf: its first triangle; else its first child (the second follows it)
    index: u32,
    hi: m.V3,
    /// triangles in a leaf (0: an inner node)
    count: u32,
};

pub var tris: []Tri = &.{};
/// corner normals (unit, world), 3 per triangle
pub var norms: [][3]m.V3 = &.{};
/// material + 1 per triangle (0: the default)
pub var mats: []u16 = &.{};
/// the scene's materials when it was taken
pub var mat_list: []material.Material = &.{};
/// object-space v0, e1, e2 per triangle (shader graphs)
pub var obj_tris: []Tri = &.{};
/// UVs per triangle (u0 NaN: none, box projection)
pub var tuv: [][6]f32 = &.{};
/// vertex colours per triangle's corners (0: none)
pub var tvc: [][3]u32 = &.{};
/// some material is masked, translucent or one-sided: rays walk through (pt.zig)
pub var cut = false;
/// set: only this object (baking)
pub var only: ?usize = null;
pub var nodes: []Node = &.{};
var n_nodes: usize = 0;

pub fn free() void {
    if (tris.len > 0) A.free(tris);
    if (norms.len > 0) A.free(norms);
    if (mats.len > 0) A.free(mats);
    if (mat_list.len > 0) A.free(mat_list);
    if (nodes.len > 0) A.free(nodes);
    if (obj_tris.len > 0) A.free(obj_tris);
    if (tuv.len > 0) A.free(tuv);
    if (tvc.len > 0) A.free(tvc);
    tvc = &.{};
    tris = &.{};
    norms = &.{};
    mats = &.{};
    mat_list = &.{};
    obj_tris = &.{};
    tuv = &.{};
    cut = false;
    nodes = &.{};
    n_nodes = 0;
}

pub fn materialOf(t: usize) *const material.Material {
    const k = mats[t];
    return if (k == 0 or k > mat_list.len) &preview.default_material else &mat_list[k - 1];
}

fn takes(o: *const scene.Object, oi: usize) bool {
    if (only) |k| {
        if (k != oi) return false;
    }
    return o.visible and o.render and o.kind != .light and o.kind != .camera and o.kind != .armature and o.kind != .sketch and o.kind != .field;
}

/// Take the scene: every visible, rendered mesh. False: out of memory.
pub fn build() bool {
    free();
    gops.syncCheck(); // (material instances up to date)
    var total: usize = 0;
    var ibud: usize = inst_budget;
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!takes(o, oi)) continue;
        const me = mods.of(oi) orelse continue;
        total += me.tris.len;
        total += instTris(oi, &ibud, null); // (hv_inst_count)
    }
    mat_list = A.alloc(material.Material, material.count) catch return false;
    @memcpy(mat_list, material.list[0..material.count]);
    for (mat_list) |*ma| {
        if (ma.blend + ma.one_sided > 0) cut = true;
    }
    if (total == 0) return true;
    tris = A.alloc(Tri, total) catch return fail();
    norms = A.alloc([3]m.V3, total) catch return fail();
    mats = A.alloc(u16, total) catch return fail();
    obj_tris = A.alloc(Tri, total) catch return fail();
    tuv = A.alloc([6]f32, total) catch return fail();
    tvc = A.alloc([3]u32, total) catch return fail();
    var k: usize = 0;
    var ibud2: usize = inst_budget;
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!takes(o, oi)) continue;
        const me = mods.of(oi) orelse continue;
        const cn = mods.normals(oi, me) orelse return fail();
        const mtx = scene.world(oi);
        const nm = preview.normalMatrix(mtx);
        const mi: u16 = if (material.of(o) != null) o.mat else 0;
        for (me.tris, 0..) |t, ti| {
            const a = m.xform(mtx, me.verts[t[0]]);
            const b = m.xform(mtx, me.verts[t[1]]);
            const c = m.xform(mtx, me.verts[t[2]]);
            tris[k] = .{ .v0 = a, .e1 = m.sub(b, a), .e2 = m.sub(c, a) };
            const p0 = me.verts[t[0]];
            obj_tris[k] = .{ .v0 = p0, .e1 = m.sub(me.verts[t[1]], p0), .e2 = m.sub(me.verts[t[2]], p0) };
            tuv[k] = bake.triUvs(me, ti) orelse .{ std.math.nan(f32), 0, 0, 0, 0, 0 };
            tvc[k] = if (me.vcol.len == me.verts.len and me.vcol.len != 0) .{ me.vcol[t[0]], me.vcol[t[1]], me.vcol[t[2]] } else .{ 0, 0, 0 };
            for (0..3) |q| {
                const n = preview.xformN(nm, cn[ti][q]);
                const l = m.len(n);
                norms[k][q] = if (l > 1e-30 and std.math.isFinite(l)) m.scale(n, 1 / l) else .{ 0, 1, 0 };
            }
            mats[k] = mi;
            k += 1;
        }
        // then its instances (hv_inst_emit)
        k += instTris(oi, &ibud2, .{ .k = k, .mtx = mtx, .mi = mi });
    }
    return buildBvh();
}

/// Instance triangles the path tracer takes (HV_IBUDGET), whole instances
/// while it lasts.
const inst_budget: usize = 4000000;

const Emit = struct { k: usize, mtx: m.M4, mi: u16 };

/// The triangles object oi's instances add while the budget lasts (spent);
/// with `emit`, written from triangle emit.k on: the prototype's triangles
/// placed by world x instance, its corner normals (within 30 degrees) turned
/// with them.
fn instTris(oi: usize, bud: *usize, emit: ?Emit) usize {
    const inst = @import("inst.zig");
    const b = mods.instancesOf(oi) orelse return 0;
    var pm: [inst.MAXP]?scene.Mesh = @splat(null);
    var pk: [inst.MAXP]preview.Kept = @splat(.{});
    defer for (&pm, &pk) |*x, *y| {
        if (x.*) |*me| scene.freeMesh(me);
        preview.freeKept(y);
    };
    var n: usize = 0;
    for (0..b.n) |i| {
        const g = b.proto[b.pids[i] & 7] orelse break;
        var t: usize = 0;
        for (0..g.faces()) |f| {
            const c = g.poff[f + 1] - g.poff[f];
            if (c >= 3) t += c - 2;
        }
        if (t > bud.*) break;
        bud.* -= t;
        if (emit) |e| {
            const pid = b.pids[i] & 7;
            if (pm[pid] == null) pm[pid] = scene.buildMesh(g.verts, g.poff, g.loops);
            const cn_ = if (pm[pid]) |*me| preview.cornerNormalsIn(&pk[pid], me) else null;
            const cn = cn_ orelse { // (out of memory: nothing there, as counted)
                for (0..t) |q| {
                    const kk = e.k + n + q;
                    tris[kk] = .{ .v0 = .{ 0, 0, 0 }, .e1 = .{ 0, 0, 0 }, .e2 = .{ 0, 0, 0 } };
                    obj_tris[kk] = tris[kk];
                    tuv[kk] = .{ std.math.nan(f32), 0, 0, 0, 0, 0 };
                    tvc[kk] = .{ 0, 0, 0 };
                    norms[kk] = .{ .{ 0, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 0 } };
                    mats[kk] = e.mi;
                }
                n += t;
                continue;
            };
            const me = &pm[pid].?;
            const im = b.mats[i];
            const w = e.mtx;
            const wm = inst.mul(&.{ w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11] }, &im);
            const m4: m.M4 = .{ wm[0], wm[1], wm[2], wm[3], wm[4], wm[5], wm[6], wm[7], wm[8], wm[9], wm[10], wm[11], 0, 0, 0, 1 };
            const nm = preview.normalMatrix(m4);
            for (me.tris, 0..) |tr, ti| {
                const kk = e.k + n + ti;
                const pa = @import("geonodes.zig").xf(&wm, me.verts[tr[0]]);
                const pb = @import("geonodes.zig").xf(&wm, me.verts[tr[1]]);
                const pc = @import("geonodes.zig").xf(&wm, me.verts[tr[2]]);
                tris[kk] = .{ .v0 = pa, .e1 = m.sub(pb, pa), .e2 = m.sub(pc, pa) };
                obj_tris[kk] = tris[kk];
                tuv[kk] = .{ std.math.nan(f32), 0, 0, 0, 0, 0 };
                tvc[kk] = .{ 0, 0, 0 };
                for (0..3) |q| {
                    const nn = preview.xformN(nm, cn[ti][q]);
                    const l = m.len(nn);
                    norms[kk][q] = if (l > 1e-30 and std.math.isFinite(l)) m.scale(nn, 1 / l) else .{ 0, 1, 0 };
                }
                mats[kk] = e.mi;
            }
        }
        n += t;
    }
    return n;
}

fn fail() bool {
    free();
    return false;
}

// --- the BVH (binned SAH, 12 bins) ------------------------------------------------------

const BINS = 12;
const LEAF_MAX = 4;

const Box = struct {
    lo: m.V3 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) },
    hi: m.V3 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) },
    fn grow(b: *Box, p: m.V3) void {
        for (0..3) |i| {
            b.lo[i] = @min(b.lo[i], p[i]);
            b.hi[i] = @max(b.hi[i], p[i]);
        }
    }
    fn merge(b: *Box, o: Box) void {
        for (0..3) |i| {
            b.lo[i] = @min(b.lo[i], o.lo[i]);
            b.hi[i] = @max(b.hi[i], o.hi[i]);
        }
    }
    fn area(b: Box) f32 {
        const d = m.sub(b.hi, b.lo);
        if (!(d[0] >= 0)) return 0;
        return d[0] * d[1] + d[1] * d[2] + d[2] * d[0];
    }
};

var tbox: []Box = &.{};
var cent: []m.V3 = &.{};
var order: []u32 = &.{};

const Task = struct { node: u32, first: u32, count: u32 };
/// A node of this many triangles or more: its boxes and bins on every thread.
const PAR_NODE = 1 << 15;
/// A subtree of this many or fewer: built whole by one thread.
const SUB_MAX = 1 << 15;

const Bins = struct {
    bb: Box = .{},
    cb: Box = .{},
    box: [3][BINS]Box = @splat(@splat(.{})),
    cnt: [3][BINS]u32 = @splat(@splat(0)),
};

inline fn binOf(ti: u32, ax: usize, lo: f32, k: f32) usize {
    return @min(BINS - 1, @as(usize, @intFromFloat(@max(0, (cent[ti][ax] - lo) * k))));
}

fn growBounds(ids: []const u32, bn: *Bins) void {
    for (ids) |ti| {
        bn.bb.merge(tbox[ti]);
        bn.cb.grow(cent[ti]);
    }
}

/// The triangles into each axis's bins (an axis the centroids do not span: none).
fn fillBins(ids: []const u32, cb: *const Box, bn: *Bins) void {
    for (0..3) |ax| {
        const ext = cb.hi[ax] - cb.lo[ax];
        if (!(ext > 1e-12)) continue;
        const k = @as(f32, BINS) / ext;
        for (ids) |ti| {
            const bi = binOf(ti, ax, cb.lo[ax], k);
            bn.box[ax][bi].merge(tbox[ti]);
            bn.cnt[ax][bi] += 1;
        }
    }
}

/// A big node's passes on every thread: each thread's own sums, merged after
/// (boxes and counts: the same whatever the order).
const Par = struct {
    ids: []const u32,
    cb: Box = .{},
    per: []Bins,
    fn boundsJob(ctx: *anyopaque, lo: usize, hi: usize, th: usize) void {
        const j: *const Par = @ptrCast(@alignCast(ctx));
        growBounds(j.ids[lo..hi], &j.per[th]);
    }
    fn binsJob(ctx: *anyopaque, lo: usize, hi: usize, th: usize) void {
        const j: *const Par = @ptrCast(@alignCast(ctx));
        fillBins(j.ids[lo..hi], &j.cb, &j.per[th]);
    }
};
var par_bins: []Bins = &.{};

/// One node: its box, then a leaf or its split, the children at nodes l and
/// l + 1. The left child's triangles (0: a leaf).
fn splitNode(tk: Task, l: u32) u32 {
    const ids = order[tk.first..][0..tk.count];
    var bn = Bins{};
    const par = tk.count >= PAR_NODE and par_bins.len > 1;
    if (par) {
        var j = Par{ .ids = ids, .per = par_bins };
        for (par_bins) |*p| p.* = .{};
        jobs.parallelFor(ids.len, 8192, &j, Par.boundsJob);
        for (par_bins) |*p| {
            bn.bb.merge(p.bb);
            bn.cb.merge(p.cb);
        }
    } else growBounds(ids, &bn);
    const cb = bn.cb;
    const nd = &nodes[tk.node];
    nd.lo = bn.bb.lo;
    nd.hi = bn.bb.hi;
    if (tk.count <= LEAF_MAX) {
        nd.index = tk.first;
        nd.count = tk.count;
        return 0;
    }
    if (par) {
        var j = Par{ .ids = ids, .cb = cb, .per = par_bins };
        for (par_bins) |*p| p.* = .{};
        jobs.parallelFor(ids.len, 8192, &j, Par.binsJob);
        for (par_bins) |*p| {
            for (0..3) |ax| {
                for (0..BINS) |i| {
                    bn.box[ax][i].merge(p.box[ax][i]);
                    bn.cnt[ax][i] += p.cnt[ax][i];
                }
            }
        }
    } else fillBins(ids, &cb, &bn);
    // the best split: binned SAH on the longest centroid axis... on all three
    var best_cost = std.math.inf(f32);
    var best_axis: usize = 0;
    var best_bin: usize = 0;
    for (0..3) |ax| {
        const ext = cb.hi[ax] - cb.lo[ax];
        if (!(ext > 1e-12)) continue;
        const bins = &bn.box[ax];
        const cnt = &bn.cnt[ax];
        var la: [BINS - 1]f32 = undefined;
        var lc: [BINS - 1]u32 = undefined;
        var acc = Box{};
        var c: u32 = 0;
        for (0..BINS - 1) |i| {
            acc.merge(bins[i]);
            c += cnt[i];
            la[i] = acc.area();
            lc[i] = c;
        }
        acc = .{};
        c = 0;
        var i: usize = BINS - 1;
        while (i > 0) : (i -= 1) {
            acc.merge(bins[i]);
            c += cnt[i];
            const cost = la[i - 1] * @as(f32, @floatFromInt(lc[i - 1])) + acc.area() * @as(f32, @floatFromInt(c));
            if (lc[i - 1] > 0 and c > 0 and cost < best_cost) {
                best_cost = cost;
                best_axis = ax;
                best_bin = i;
            }
        }
    }
    var mid: u32 = 0;
    if (best_cost < std.math.inf(f32)) {
        const ax = best_axis;
        const k = @as(f32, BINS) / (cb.hi[ax] - cb.lo[ax]);
        var lo: u32 = tk.first;
        var hi: u32 = tk.first + tk.count;
        while (lo < hi) {
            const ti = order[lo];
            if (binOf(ti, ax, cb.lo[ax], k) < best_bin) lo += 1 else {
                hi -= 1;
                std.mem.swap(u32, &order[lo], &order[hi]);
            }
        }
        mid = lo - tk.first;
    }
    if (mid == 0 or mid == tk.count) {
        // all centroids together: a leaf if small, else halves
        if (tk.count <= 16) {
            nd.index = tk.first;
            nd.count = tk.count;
            return 0;
        }
        mid = tk.count / 2;
    }
    nd.index = l; // the first child; the second follows it
    nd.count = 0;
    return mid;
}

/// A small subtree, whole, in its own run of nodes (2 count - 2 at most).
const Sub = struct { task: Task, base: u32 };

fn subJob(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const subs: *const []const Sub = @ptrCast(@alignCast(ctx));
    for (subs.*[lo..hi]) |sb| {
        var next = sb.base;
        // (the larger half waits, the smaller goes first: the stack stays short)
        var stack: [64]Task = undefined;
        var sp: usize = 1;
        stack[0] = sb.task;
        while (sp > 0) {
            sp -= 1;
            const tk = stack[sp];
            const mid = splitNode(tk, next);
            if (mid == 0) continue;
            const a = Task{ .node = next, .first = tk.first, .count = mid };
            const b = Task{ .node = next + 1, .first = tk.first + mid, .count = tk.count - mid };
            next += 2;
            stack[sp] = if (a.count >= b.count) a else b;
            stack[sp + 1] = if (a.count >= b.count) b else a;
            sp += 2;
        }
    }
}

fn boxJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |i| {
        const t = tris[i];
        var b = Box{};
        b.grow(t.v0);
        b.grow(m.add(t.v0, t.e1));
        b.grow(m.add(t.v0, t.e2));
        tbox[i] = b;
        cent[i] = m.scale(m.add(b.lo, b.hi), 0.5);
        order[i] = @intCast(i);
    }
}

/// Everything per triangle, in leaf order.
const Sorted = struct {
    tris: []Tri = &.{},
    norms: [][3]m.V3 = &.{},
    mats: []u16 = &.{},
    obj_tris: []Tri = &.{},
    tuv: [][6]f32 = &.{},
    tvc: [][3]u32 = &.{},
    fn alloc(n: usize) ?Sorted {
        var s = Sorted{};
        s.tris = A.alloc(Tri, n) catch return s.drop();
        s.norms = A.alloc([3]m.V3, n) catch return s.drop();
        s.mats = A.alloc(u16, n) catch return s.drop();
        s.obj_tris = A.alloc(Tri, n) catch return s.drop();
        s.tuv = A.alloc([6]f32, n) catch return s.drop();
        s.tvc = A.alloc([3]u32, n) catch return s.drop();
        return s;
    }
    fn drop(s: *Sorted) ?Sorted {
        if (s.tris.len > 0) A.free(s.tris);
        if (s.norms.len > 0) A.free(s.norms);
        if (s.mats.len > 0) A.free(s.mats);
        if (s.obj_tris.len > 0) A.free(s.obj_tris);
        if (s.tuv.len > 0) A.free(s.tuv);
        if (s.tvc.len > 0) A.free(s.tvc);
        return null;
    }
    fn job(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
        const s: *const Sorted = @ptrCast(@alignCast(ctx));
        for (order[lo..hi], lo..) |o, i| {
            s.tris[i] = tris[o];
            s.norms[i] = norms[o];
            s.mats[i] = mats[o];
            s.obj_tris[i] = obj_tris[o];
            s.tuv[i] = tuv[o];
            s.tvc[i] = tvc[o];
        }
    }
};

/// The tree, on every thread: the big nodes one after the other, their passes
/// shared out; the subtrees under them one thread each. The tree and the
/// triangles' order are the same however many threads there are.
fn buildBvh() bool {
    const n = tris.len;
    tbox = A.alloc(Box, n) catch return fail();
    defer A.free(tbox);
    cent = A.alloc(m.V3, n) catch return fail();
    defer A.free(cent);
    order = A.alloc(u32, n) catch return fail();
    defer A.free(order);
    par_bins = A.alloc(Bins, jobs.count()) catch &.{};
    defer {
        if (par_bins.len > 0) A.free(par_bins);
        par_bins = &.{};
    }
    var dummy: u8 = 0;
    jobs.parallelFor(n, 16384, &dummy, boxJob);
    nodes = A.alloc(Node, 2 * n) catch return fail();
    n_nodes = 1;
    var stack: std.ArrayList(Task) = .empty;
    defer stack.deinit(A);
    var subs: std.ArrayList(Sub) = .empty;
    defer subs.deinit(A);
    stack.append(A, .{ .node = 0, .first = 0, .count = @intCast(n) }) catch return fail();
    while (stack.pop()) |tk| {
        if (tk.count <= SUB_MAX) {
            subs.append(A, .{ .task = tk, .base = 0 }) catch return fail();
            continue;
        }
        const l: u32 = @intCast(n_nodes);
        const mid = splitNode(tk, l);
        if (mid == 0) continue;
        n_nodes += 2;
        stack.append(A, .{ .node = l, .first = tk.first, .count = mid }) catch return fail();
        stack.append(A, .{ .node = l + 1, .first = tk.first + mid, .count = tk.count - mid }) catch return fail();
    }
    for (subs.items) |*sb| {
        sb.base = @intCast(n_nodes);
        n_nodes += 2 * @as(usize, sb.task.count) - 2;
    }
    var sub_list: []const Sub = subs.items;
    jobs.parallelFor(sub_list.len, 1, @ptrCast(&sub_list), subJob);
    // triangles in leaf order
    var s = Sorted.alloc(n) orelse return fail();
    jobs.parallelFor(n, 16384, &s, Sorted.job);
    A.free(tris);
    A.free(norms);
    A.free(mats);
    A.free(obj_tris);
    A.free(tuv);
    A.free(tvc);
    tris = s.tris;
    norms = s.norms;
    mats = s.mats;
    obj_tris = s.obj_tris;
    tuv = s.tuv;
    tvc = s.tvc;
    return true;
}

// --- queries --------------------------------------------------------------------------

pub const Hit = struct { t: f32, tri: u32, u: f32, v: f32 };

inline fn boxHit(nd: *const Node, o: m.V3, inv: m.V3, tmax: f32) f32 {
    var t0: f32 = 0;
    var t1: f32 = tmax;
    inline for (0..3) |i| {
        const a = (nd.lo[i] - o[i]) * inv[i];
        const b = (nd.hi[i] - o[i]) * inv[i];
        t0 = @max(t0, @min(a, b));
        t1 = @min(t1, @max(a, b));
    }
    return if (t0 <= t1) t0 else std.math.inf(f32);
}

inline fn triHit(t: *const Tri, o: m.V3, d: m.V3, tmax: f32, u: *f32, v: *f32) f32 {
    const p = m.cross(d, t.e2);
    const det = m.dot(t.e1, p);
    if (!(@abs(det) > 1e-12)) return -1;
    const inv = 1 / det;
    const s = m.sub(o, t.v0);
    const uu = m.dot(s, p) * inv;
    if (uu < 0 or uu > 1) return -1;
    const q = m.cross(s, t.e1);
    const vv = m.dot(d, q) * inv;
    if (vv < 0 or uu + vv > 1) return -1;
    const tt = m.dot(t.e2, q) * inv;
    if (!(tt > 1e-4 and tt < tmax)) return -1; // (as the original: a surface does not hide a point on it)
    u.* = uu;
    v.* = vv;
    return tt;
}

/// The nearest hit along o + t d (0 < t < tmax), or null.
pub fn trace(o: m.V3, d: m.V3, tmax: f32) ?Hit {
    if (tris.len == 0) return null;
    const inf = std.math.inf(f32);
    const inv: m.V3 = .{ 1 / d[0], 1 / d[1], 1 / d[2] };
    var best = Hit{ .t = tmax, .tri = 0, .u = 0, .v = 0 };
    var found = false;
    var stack: [64]u32 = undefined;
    var sp: usize = 1;
    stack[0] = 0;
    while (sp > 0) {
        sp -= 1;
        const nd = &nodes[stack[sp]];
        if (boxHit(nd, o, inv, best.t) == inf) continue;
        if (nd.count > 0) {
            for (nd.index..nd.index + nd.count) |ti| {
                var u: f32 = 0;
                var v: f32 = 0;
                const t = triHit(&tris[ti], o, d, best.t, &u, &v);
                if (t > 0) {
                    best = .{ .t = t, .tri = @intCast(ti), .u = u, .v = v };
                    found = true;
                }
            }
            continue;
        }
        if (sp + 2 > stack.len) continue;
        const a = nd.index;
        const ta = boxHit(&nodes[a], o, inv, best.t);
        const tb = boxHit(&nodes[a + 1], o, inv, best.t);
        // the nearer is popped first
        if (ta <= tb) {
            if (tb != inf) {
                stack[sp] = a + 1;
                sp += 1;
            }
            if (ta != inf) {
                stack[sp] = a;
                sp += 1;
            }
        } else {
            if (ta != inf) {
                stack[sp] = a;
                sp += 1;
            }
            stack[sp] = a + 1;
            sp += 1;
        }
    }
    return if (found) best else null;
}

/// Whether anything lies along o + t d for 0 < t < tmax.
pub fn occluded(o: m.V3, d: m.V3, tmax: f32) bool {
    if (tris.len == 0) return false;
    const inv: m.V3 = .{ 1 / d[0], 1 / d[1], 1 / d[2] };
    var stack: [64]u32 = undefined;
    var sp: usize = 1;
    stack[0] = 0;
    while (sp > 0) {
        sp -= 1;
        const nd = &nodes[stack[sp]];
        if (boxHit(nd, o, inv, tmax) == std.math.inf(f32)) continue;
        if (nd.count > 0) {
            for (nd.index..nd.index + nd.count) |ti| {
                var u: f32 = 0;
                var v: f32 = 0;
                if (triHit(&tris[ti], o, d, tmax, &u, &v) > 0) return true;
            }
        } else if (sp + 2 <= stack.len) {
            stack[sp] = nd.index;
            stack[sp + 1] = nd.index + 1;
            sp += 2;
        }
    }
    return false;
}

test "a cube's BVH: rays hit what brute force hits" {
    scene.init();
    scene.count = 0;
    _ = scene.add(.cube);
    _ = scene.add(.sphere);
    scene.objects[1].loc = .{ 2.5, 0.3, 0 };
    try std.testing.expect(build());
    defer free();
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();
    var hits: usize = 0;
    for (0..2000) |_| {
        const o: m.V3 = .{ r.float(f32) * 10 - 5, r.float(f32) * 10 - 5, 6 };
        const d = m.norm(.{ r.float(f32) - 0.5, r.float(f32) - 0.5, -1 });
        var bt: f32 = 1e30;
        for (tris) |*t| {
            var u: f32 = 0;
            var v: f32 = 0;
            const tt = triHit(t, o, d, bt, &u, &v);
            if (tt > 0) bt = tt;
        }
        const h = trace(o, d, 1e30);
        if (bt < 1e30) {
            hits += 1;
            try std.testing.expect(h != null);
            try std.testing.expectApproxEqAbs(bt, h.?.t, 1e-4);
            try std.testing.expect(occluded(o, d, 1e30));
        } else {
            try std.testing.expect(h == null);
            try std.testing.expect(!occluded(o, d, 1e30));
        }
    }
    try std.testing.expect(hits > 50);
}
