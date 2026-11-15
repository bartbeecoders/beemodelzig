// More modelling tools, as the original's meshops2.s / repair.s: merge
// collapse and by distance, bridge edge loops, separate by loose parts,
// repair, and loop cut (Ctrl+R: hover an edge, the wheel sets the cuts, a
// click cuts the ring of quads across it).
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const em = @import("editmesh.zig");
const mo = @import("meshops.zig");
const gfx = @import("gfx.zig");
const vp = @import("viewport.zig");

const A = @import("alloc.zig").A;
const Work = mo.Work;

fn begin() !Work {
    const me = em.mesh() orelse return error.NotEditing;
    return Work.from(me, em.sel);
}

fn key(a: u32, b: u32) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

// --- merging ------------------------------------------------------------------

/// Union-find over vertices.
const Sets = struct {
    p: []u32,
    fn init(n: usize) !Sets {
        const p = try A.alloc(u32, n);
        for (p, 0..) |*x, i| x.* = @intCast(i);
        return .{ .p = p };
    }
    fn find(s: *Sets, x0: u32) u32 {
        var x = x0;
        while (s.p[x] != x) {
            s.p[x] = s.p[s.p[x]];
            x = s.p[x];
        }
        return x;
    }
    fn join(s: *Sets, a: u32, b: u32) void {
        const ra = s.find(a);
        const rb = s.find(b);
        if (ra != rb) s.p[@max(ra, rb)] = @min(ra, rb);
    }
};

/// Merge the vertices of each set into its root at the set's centre.
/// `average`: merged vertices go to their centre; else they go onto the set's
/// first vertex (by distance: the target, which stays where it is).
fn mergeSets(w: *Work, sets: *Sets, only: []const bool, label: []const u8, average: bool) !?usize {
    const n = w.verts.items.len;
    var sum = try A.alloc(m.V3, n);
    defer A.free(sum);
    var cnt = try A.alloc(u32, n);
    defer A.free(cnt);
    @memset(sum, .{ 0, 0, 0 });
    @memset(cnt, 0);
    for (0..n) |i| {
        if (!only[i]) continue;
        const r = sets.find(@intCast(i));
        sum[r] = m.add(sum[r], w.verts.items[i]);
        cnt[r] += 1;
    }
    var merged: usize = 0;
    for (0..n) |i| {
        if (only[i] and cnt[i] > 1) {
            if (average) w.verts.items[i] = m.scale(sum[i], 1 / @as(f32, @floatFromInt(cnt[i])));
            merged += cnt[i] - 1;
        }
    }
    if (merged == 0) return 0;
    for (w.polys.items) |*l| {
        for (l.items) |*v| v.* = sets.find(v.*);
    }
    cleanPolys(w);
    const drop = try A.alloc(bool, n);
    defer A.free(drop);
    // every vertex no polygon uses goes, merged or not (mesh_compact)
    @memset(drop, true);
    try dropUnused(w, drop);
    if (w.commit(label) != null) return null;
    return merged;
}

fn cleanPolys(w: *Work) void {
    // repeated corners in a row and polygons with fewer than three go
    w.clean();
}

fn dropUnused(w: *Work, only: []const bool) !void {
    const used = try A.alloc(bool, w.verts.items.len);
    defer A.free(used);
    @memset(used, false);
    for (w.polys.items) |l| {
        for (l.items) |v| used[v] = true;
    }
    const remap = try A.alloc(u32, w.verts.items.len);
    defer A.free(remap);
    var n: u32 = 0;
    for (0..w.verts.items.len) |i| {
        if (used[i] or i >= only.len or !only[i]) {
            w.verts.items[n] = w.verts.items[i];
            w.sel.items[n] = w.sel.items[i];
            remap[i] = n;
            n += 1;
        }
    }
    w.verts.shrinkRetainingCapacity(n);
    w.sel.shrinkRetainingCapacity(n);
    for (w.polys.items) |*l| {
        for (l.items) |*v| v.* = remap[v.*];
    }
}

/// Each connected group of selected vertices at its own centre.
pub fn mergeCollapse() !?usize {
    var w = try begin();
    defer w.deinit();
    var sets = try Sets.init(w.verts.items.len);
    defer A.free(sets.p);
    for (w.polys.items) |l| {
        for (l.items, 0..) |a, k| {
            const b = l.items[(k + 1) % l.items.len];
            if (w.sel.items[a] and w.sel.items[b]) sets.join(a, b);
        }
    }
    return mergeSets(&w, &sets, w.sel.items, "Merge Collapse", true);
}

/// Selected vertices closer than `dist` become one (a grid of cells finds them).
pub fn mergeDistance(dist: f32) !?usize {
    var w = try begin();
    defer w.deinit();
    // nothing selected: every vertex takes part
    const all = try A.alloc(bool, w.sel.items.len);
    defer A.free(all);
    @memset(all, true);
    const any = std.mem.indexOfScalar(bool, w.sel.items, true) != null;
    return mergeClose(&w, if (any) w.sel.items else all, dist, "Merge by Distance");
}

fn mergeClose(w: *Work, only: []const bool, dist: f32, label: []const u8) !?usize {
    const n = w.verts.items.len;
    var sets = try Sets.init(n);
    defer A.free(sets.p);
    const cell = @max(dist, 1e-7);
    var grid = std.AutoHashMap([3]i64, std.ArrayList(u32)).init(A);
    defer {
        var it = grid.valueIterator();
        while (it.next()) |l| l.deinit(A);
        grid.deinit();
    }
    for (0..n) |i| {
        if (!only[i]) continue;
        const p = w.verts.items[i];
        const c = [3]i64{ @intFromFloat(@floor(p[0] / cell)), @intFromFloat(@floor(p[1] / cell)), @intFromFloat(@floor(p[2] / cell)) };
        // the 27 cells round it, x then y then z, each cell's newest first: the
        // first target within reach takes it (targets only, so merges do not
        // chain; which one decides the topology: meshops.s .Lmd_dx)
        var target: ?u32 = null;
        scan: for ([3]i64{ -1, 0, 1 }) |dx| {
            for ([3]i64{ -1, 0, 1 }) |dy| {
                for ([3]i64{ -1, 0, 1 }) |dz| {
                    const l = grid.get(.{ c[0] + dx, c[1] + dy, c[2] + dz }) orelse continue;
                    var q = l.items.len;
                    while (q > 0) {
                        q -= 1;
                        const j = l.items[q];
                        const e = m.sub(w.verts.items[j], p);
                        if (m.dot(e, e) <= dist * dist) {
                            target = j;
                            break :scan;
                        }
                    }
                }
            }
        }
        if (target) |j| {
            sets.join(@intCast(i), j);
            continue;
        }
        const g = try grid.getOrPut(c);
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(A, @intCast(i));
    }
    return mergeSets(w, &sets, only, label, false);
}

// --- bridge ----------------------------------------------------------------------

/// Join two selected boundary loops with a band of quads.
pub fn bridge() !?[]const u8 {
    var w = try begin();
    defer w.deinit();
    // boundary edges (one polygon) between selected vertices, as their polygon runs them
    var counts = std.AutoHashMap(u64, u32).init(A);
    defer counts.deinit();
    for (w.polys.items) |l| {
        for (l.items, 0..) |a, k| {
            const g = try counts.getOrPut(key(a, l.items[(k + 1) % l.items.len]));
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }
    var next = std.AutoHashMap(u32, u32).init(A);
    defer next.deinit();
    for (w.polys.items) |l| {
        for (l.items, 0..) |a, k| {
            const b = l.items[(k + 1) % l.items.len];
            if (w.sel.items[a] and w.sel.items[b] and counts.get(key(a, b)).? == 1) try next.put(a, b);
        }
    }
    // the loops
    var loops: [2]std.ArrayList(u32) = .{ .empty, .empty };
    defer for (&loops) |*l| l.deinit(A);
    var nl: usize = 0;
    var done = std.AutoHashMap(u32, void).init(A);
    defer done.deinit();
    var it = next.keyIterator();
    while (it.next()) |s| {
        if (done.contains(s.*)) continue;
        if (nl == 2) return "Select exactly two boundary loops";
        var at = s.*;
        var guard: usize = 0;
        while (guard <= next.count()) : (guard += 1) {
            try done.put(at, {});
            try loops[nl].append(A, at);
            at = next.get(at) orelse return "The selected boundary does not close into loops";
            if (at == s.*) break;
        }
        nl += 1;
    }
    if (nl != 2) return "Select two boundary loops (the edges round two holes)";
    const a = loops[0].items;
    const b = loops[1].items;
    if (a.len != b.len) return "The two loops need as many vertices each";
    const n = a.len;
    // line them up: both directions, every start; the shortest band wins
    // (facing holes run opposite ways; two copies of one outline the same way)
    var best: usize = 0;
    var bd: f32 = std.math.inf(f32);
    var best_rev = true;
    for ([2]bool{ true, false }) |rev| {
        std.mem.reverse(u32, loops[1].items); // (first pass: reversed, second: as it was)
        for (0..n) |s| {
            var d: f32 = 0;
            for (0..n) |k| d += m.len(m.sub(w.verts.items[a[k]], w.verts.items[b[(k + s) % n]]));
            if (d < bd - 1e-6) {
                bd = d;
                best = s;
                best_rev = rev;
            }
        }
    }
    if (best_rev) std.mem.reverse(u32, loops[1].items);
    for (0..n) |k| {
        const k1 = (k + 1) % n;
        // a's boundary runs a[k] -> a[k+1]: the bridge runs it back
        try w.polys.append(A, blk: {
            var q: std.ArrayList(u32) = .empty;
            try q.appendSlice(A, &.{ a[k1], a[k], b[(k + best) % n], b[(k1 + best) % n] });
            break :blk q;
        });
    }
    if (w.commit("Bridge Edge Loops")) |why| return why;
    // same-way loops: one side has to turn round for a consistent outside
    if (!best_rev) {
        _ = try mo.recalcNormals();
        @import("undo.zig").label("Bridge Edge Loops");
    }
    return null;
}

// --- separate, repair -------------------------------------------------------------

/// The parts of a mesh that share no vertex: a part number per polygon.
fn parts(me: *const scene.Mesh, out: []u32) !usize {
    var sets = try Sets.init(me.verts.len);
    defer A.free(sets.p);
    for (0..me.poff.len - 1) |p| {
        const l = me.loops[me.poff[p]..me.poff[p + 1]];
        for (l[1..]) |v| sets.join(l[0], v);
    }
    var ids = std.AutoHashMap(u32, u32).init(A);
    defer ids.deinit();
    for (0..me.poff.len - 1) |p| {
        const r = sets.find(me.loops[me.poff[p]]);
        const g = try ids.getOrPut(r);
        if (!g.found_existing) g.value_ptr.* = @intCast(ids.count() - 1);
        out[p] = g.value_ptr.*;
    }
    return ids.count();
}

/// Each selected mesh object split into one object per loose part.
pub fn separateLoose() !usize {
    var made: usize = 0;
    const n0 = scene.count;
    for (0..n0) |i| {
        if (!scene.objects[i].selected) continue;
        const me = scene.meshOfObj(i) orelse continue;
        const np = me.poff.len - 1;
        const part = try A.alloc(u32, np);
        defer A.free(part);
        const npart = try parts(me, part);
        if (npart < 2) continue;
        // build each part's mesh
        var meshes = try A.alloc(?u16, npart);
        defer A.free(meshes);
        const remap = try A.alloc(u32, me.verts.len);
        defer A.free(remap);
        for (0..npart) |q| {
            @memset(remap, std.math.maxInt(u32));
            var vs: std.ArrayList(m.V3) = .empty;
            defer vs.deinit(A);
            var po: std.ArrayList(u32) = .empty;
            defer po.deinit(A);
            var lo: std.ArrayList(u32) = .empty;
            defer lo.deinit(A);
            try po.append(A, 0);
            for (0..np) |p| {
                if (part[p] != q) continue;
                for (me.loops[me.poff[p]..me.poff[p + 1]]) |v| {
                    if (remap[v] == std.math.maxInt(u32)) {
                        remap[v] = @intCast(vs.items.len);
                        try vs.append(A, me.verts[v]);
                    }
                    try lo.append(A, remap[v]);
                }
                try po.append(A, @intCast(lo.items.len));
            }
            meshes[q] = scene.addMesh(vs.items, po.items, lo.items);
        }
        // the object keeps the first part; copies take the rest
        scene.objects[i].mesh = meshes[0];
        for (1..npart) |q| {
            if (scene.count >= scene.max_objects) break;
            var o = scene.objects[i];
            o.mesh = meshes[q];
            var nb: [40]u8 = undefined;
            o.setName(std.fmt.bufPrint(&nb, "{s}.{d:0>3}", .{ scene.objects[i].name()[0..@min(scene.objects[i].name().len, 27)], q }) catch "Part");
            scene.objects[scene.count] = o;
            scene.stamp(scene.count);
            scene.count += 1;
            made += 1;
        }
    }
    return made;
}

pub const RepairReport = struct { merged: usize = 0, degenerate: usize = 0, duplicates: usize = 0, holes: usize = 0, loose: usize = 0 };

/// Merge by distance, remove faces without area and duplicate faces, fill
/// holes, make the normals consistent and outward, drop loose vertices.
pub fn repair(dist: f32) !RepairReport {
    var rep = RepairReport{};
    var w = try begin();
    defer w.deinit();
    const all = try A.alloc(bool, w.verts.items.len);
    defer A.free(all);
    @memset(all, true);
    // 1. merge by distance (into this work copy, not committed yet)
    {
        var sets = try Sets.init(w.verts.items.len);
        defer A.free(sets.p);
        // a sort along x finds the close ones without a grid
        const order = try A.alloc(u32, w.verts.items.len);
        defer A.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.sort.pdq(u32, order, w.verts.items, struct {
            fn lt(v: []m.V3, a: u32, b: u32) bool {
                return v[a][0] < v[b][0];
            }
        }.lt);
        for (order, 0..) |a, k| {
            var j = k + 1;
            while (j < order.len and w.verts.items[order[j]][0] - w.verts.items[a][0] <= dist) : (j += 1) {
                if (m.len(m.sub(w.verts.items[order[j]], w.verts.items[a])) <= dist) {
                    sets.join(a, order[j]);
                    rep.merged += 1;
                }
            }
        }
        for (w.polys.items) |*l| {
            for (l.items) |*v| v.* = sets.find(v.*);
        }
    }
    // 2. degenerate (fewer than three different corners, no area) and duplicate faces
    const before = w.polys.items.len;
    cleanPolys(&w);
    {
        const drop = try A.alloc(bool, w.polys.items.len);
        defer A.free(drop);
        for (drop, 0..) |*d, k| d.* = area(&w, k) < 1e-12;
        w.dropPolys(drop);
    }
    var k: usize = 0;
    rep.degenerate = before - w.polys.items.len;
    {
        var seen = std.AutoHashMap(u64, void).init(A);
        defer seen.deinit();
        const drop = try A.alloc(bool, w.polys.items.len);
        defer A.free(drop);
        k = 0;
        while (k < w.polys.items.len) : (k += 1) {
            // the same corners in any order and direction: a sorted hash
            const l = w.polys.items[k].items;
            const s = try A.dupe(u32, l);
            defer A.free(s);
            std.sort.pdq(u32, s, {}, std.sort.asc(u32));
            const h = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(s));
            drop[k] = (try seen.getOrPut(h)).found_existing;
            if (drop[k]) rep.duplicates += 1;
        }
        w.dropPolys(drop);
    }
    // 3. holes: every boundary loop gets a face
    {
        var counts = std.AutoHashMap(u64, u32).init(A);
        defer counts.deinit();
        for (w.polys.items) |l| {
            for (l.items, 0..) |a, j| {
                const g = try counts.getOrPut(key(a, l.items[(j + 1) % l.items.len]));
                if (!g.found_existing) g.value_ptr.* = 0;
                g.value_ptr.* += 1;
            }
        }
        var next = std.AutoHashMap(u32, u32).init(A);
        defer next.deinit();
        var clash = false;
        for (w.polys.items) |l| {
            for (l.items, 0..) |a, j| {
                const b = l.items[(j + 1) % l.items.len];
                if (counts.get(key(a, b)).? == 1) {
                    if (next.contains(b)) clash = true;
                    try next.put(b, a); // the hole runs the other way
                }
            }
        }
        if (!clash) {
            var used = std.AutoHashMap(u32, void).init(A);
            defer used.deinit();
            var it = next.keyIterator();
            while (it.next()) |s| {
                if (used.contains(s.*)) continue;
                var loop: std.ArrayList(u32) = .empty;
                defer loop.deinit(A);
                var at = s.*;
                var guard: usize = 0;
                var closed = false;
                while (guard <= next.count()) : (guard += 1) {
                    try used.put(at, {});
                    try loop.append(A, at);
                    at = next.get(at) orelse break;
                    if (at == s.*) {
                        closed = true;
                        break;
                    }
                }
                if (closed and loop.items.len >= 3) {
                    var q: std.ArrayList(u32) = .empty;
                    try q.appendSlice(A, loop.items);
                    try w.polys.append(A, q);
                    rep.holes += 1;
                }
            }
        }
    }
    // 4. vertices no face uses (merged and loose) go
    const n_before = w.verts.items.len;
    try dropUnused(&w, all);
    rep.loose = n_before - w.verts.items.len;
    for (w.sel.items) |*s| s.* = true;
    if (w.commit("Repair Mesh")) |_| return error.Failed;
    // 5. normals: consistent and outward (selection: all)
    _ = try mo.recalcNormals();
    return rep;
}

fn area(w: *const Work, p: usize) f32 {
    const l = w.polys.items[p].items;
    var n: m.V3 = .{ 0, 0, 0 };
    const a = w.verts.items[l[0]];
    for (1..l.len - 1) |k| n = m.add(n, m.cross(m.sub(w.verts.items[l[k]], a), m.sub(w.verts.items[l[k + 1]], a)));
    return m.len(n);
}

// --- loop cut ----------------------------------------------------------------------

/// The ring across edge (a, b): ring edges as ordered pairs (sides kept
/// consistent), the quads between them, whether it closes.
const Ring = struct {
    edges: std.ArrayList([2]u32) = .empty,
    closed: bool = false,
    fn deinit(r: *Ring) void {
        r.edges.deinit(A);
    }
};

fn quadOpposite(l: []const u32, a: u32, b: u32) ?[2]u32 {
    // in quad l containing edge a-b (either way): the opposite edge, keeping
    // a's side with a's neighbour (so the cut points line up)
    if (l.len != 4) return null;
    for (0..4) |k| {
        const x = l[k];
        const y = l[(k + 1) % 4];
        if (x == a and y == b) return .{ l[(k + 3) % 4], l[(k + 2) % 4] };
        if (x == b and y == a) return .{ l[(k + 2) % 4], l[(k + 3) % 4] };
    }
    return null;
}

fn findRing(me: *const scene.Mesh, a: u32, b: u32) !Ring {
    var r = Ring{};
    try r.edges.append(A, .{ a, b });
    // the polygons on each edge
    var faces_of = std.AutoHashMap(u64, [2]u32).init(A);
    defer faces_of.deinit();
    for (0..me.poff.len - 1) |p| {
        const l = me.loops[me.poff[p]..me.poff[p + 1]];
        for (l, 0..) |x, k| {
            const g = try faces_of.getOrPut(key(x, l[(k + 1) % l.len]));
            if (!g.found_existing) g.value_ptr.* = .{ @intCast(p), std.math.maxInt(u32) } else g.value_ptr.*[1] = @intCast(p);
        }
    }
    // walk both ways from the first edge
    for (0..2) |dir| {
        var cur: [2]u32 = .{ a, b };
        var from_face: u32 = std.math.maxInt(u32);
        var guard: usize = 0;
        while (guard < me.poff.len) : (guard += 1) {
            const fs = faces_of.get(key(cur[0], cur[1])) orelse break;
            const f = if (from_face == std.math.maxInt(u32)) fs[dir] else (if (fs[0] == from_face) fs[1] else fs[0]);
            if (f == std.math.maxInt(u32)) break;
            const l = me.loops[me.poff[f]..me.poff[f + 1]];
            const opp = quadOpposite(l, cur[0], cur[1]) orelse break;
            if (key(opp[0], opp[1]) == key(a, b)) {
                r.closed = true;
                break;
            }
            if (dir == 0) try r.edges.append(A, opp) else try r.edges.insert(A, 0, opp);
            cur = opp;
            from_face = f;
        }
        if (r.closed) break;
    }
    return r;
}

/// Loop cut with `cuts` loops across the ring through edge (a, b).
pub fn loopCut(a: u32, b: u32, cuts: u32) !?[]const u8 {
    const me = em.mesh() orelse return "Not in edit mode";
    if (a >= me.verts.len or b >= me.verts.len) return "No such vertex";
    if (cuts == 0) return "No cuts";
    // (a, b) must be an edge between quads
    var is_edge = false;
    for (me.edge_list) |e| {
        if ((e[0] == a and e[1] == b) or (e[0] == b and e[1] == a)) is_edge = true;
    }
    if (!is_edge) return "Those two vertices are not an edge";
    var ring = try findRing(me, a, b);
    defer ring.deinit();
    if (ring.edges.items.len < 2) return "No quads across that edge";
    var w = try Work.from(me, em.sel);
    defer w.deinit();
    const ne = ring.edges.items.len;
    // the cut points on each ring edge, from its first to its second vertex
    var pts = try A.alloc(u32, ne * cuts);
    defer A.free(pts);
    var on_edge = std.AutoHashMap(u64, usize).init(A); // edge -> ring index
    defer on_edge.deinit();
    for (w.sel.items) |*s| s.* = false;
    for (ring.edges.items, 0..) |e, k| {
        try on_edge.put(key(e[0], e[1]), k);
        for (0..cuts) |j| {
            const t = @as(f32, @floatFromInt(j + 1)) / @as(f32, @floatFromInt(cuts + 1));
            pts[k * cuts + j] = try w.addVert(m.lerp(w.verts.items[e[0]], w.verts.items[e[1]], t), true);
        }
    }
    // every polygon: quads between two ring edges split into strips; any
    // other polygon on a ring edge gets the cut points on that edge
    var out: std.ArrayList(std.ArrayList(u32)) = .empty;
    for (w.polys.items) |*lp| {
        const l = lp.items;
        // which of its edges are ring edges
        var rk: [2]usize = undefined;
        var rpos: [2]usize = undefined;
        var nr: usize = 0;
        for (l, 0..) |x, k| {
            if (on_edge.get(key(x, l[(k + 1) % l.len]))) |ri| {
                if (nr < 2) {
                    rk[nr] = ri;
                    rpos[nr] = k;
                }
                nr += 1;
            }
        }
        if (l.len == 4 and nr == 2 and (rpos[1] + 4 - rpos[0]) % 4 == 2) {
            // a quad of the ring: corners p0 p1 (edge one), p2 p3 (edge two)
            const k0 = rpos[0];
            const p0 = l[k0];
            const p1 = l[(k0 + 1) % 4];
            const p2 = l[(k0 + 2) % 4];
            const p3 = l[(k0 + 3) % 4];
            const e0 = ring.edges.items[rk[0]];
            const e1 = ring.edges.items[rk[1]];
            // the cut point j along p0->p1 and along p3->p2 (same side as p0)
            const ptOn = struct {
                fn f(e: [2]u32, from: u32, j: usize, n: u32, base: usize, ps: []const u32) u32 {
                    // point j counted from `from`
                    return if (e[0] == from) ps[base + j] else ps[base + (n - 1 - j)];
                }
            }.f;
            var prev_a = p0;
            var prev_b = p3;
            for (0..cuts) |j| {
                const ca = ptOn(e0, p0, j, cuts, rk[0] * cuts, pts);
                const cb = ptOn(e1, p3, j, cuts, rk[1] * cuts, pts);
                var q: std.ArrayList(u32) = .empty;
                try q.appendSlice(A, &.{ prev_a, ca, cb, prev_b });
                try out.append(A, q);
                prev_a = ca;
                prev_b = cb;
            }
            var q: std.ArrayList(u32) = .empty;
            try q.appendSlice(A, &.{ prev_a, p1, p2, prev_b });
            try out.append(A, q);
            lp.deinit(A);
        } else if (nr > 0) {
            // a neighbour (or a ring end): the points go into its edges
            var q: std.ArrayList(u32) = .empty;
            for (l, 0..) |x, k| {
                try q.append(A, x);
                const y = l[(k + 1) % l.len];
                if (on_edge.get(key(x, y))) |ri| {
                    const e = ring.edges.items[ri];
                    for (0..cuts) |j| try q.append(A, if (e[0] == x) pts[ri * cuts + j] else pts[ri * cuts + (cuts - 1 - j)]);
                }
            }
            try out.append(A, q);
            lp.deinit(A);
        } else try out.append(A, lp.*);
    }
    w.polys.deinit(A);
    w.polys = out;
    if (w.commit("Loop Cut")) |why| return why;
    return null;
}

/// The loop cut tool: the edge under the pointer and the number of cuts.
pub var lc_active = false;
pub var lc_cuts: u32 = 1;
pub var lc_edge: ?[2]u32 = null;

pub fn lcStart() void {
    lc_active = true;
    lc_cuts = 1;
    lc_edge = null;
}

pub fn lcHover(cv: *gfx.Canvas, v: *const vp.View, r: gfx.Rect, mx: i32, my: i32) void {
    const saved = em.sel_mode;
    em.sel_mode = .edge;
    const h = em.pick(cv, v, r, mx, my);
    em.sel_mode = saved;
    lc_edge = if (h) |x| x.edge else null;
}

/// The ring's cut lines in world space (the preview), into out (pairs).
/// The last ring found (the preview asks every frame): mesh serial and edge.
var ring_cache: ?Ring = null;
var ring_key: [3]u32 = .{ 0, 0, 0 };

pub fn lcPreview(out: *std.ArrayList([2]m.V3)) void {
    const me = em.mesh() orelse return;
    const e = lc_edge orelse return;
    const k3 = [3]u32{ me.serial, e[0], e[1] };
    if (ring_cache == null or !std.mem.eql(u32, &k3, &ring_key)) {
        if (ring_cache) |*rc| rc.deinit();
        ring_cache = findRing(me, e[0], e[1]) catch null;
        ring_key = k3;
    }
    const ring = &(ring_cache orelse return);
    const w = scene.world(em.obj);
    const n = ring.edges.items.len;
    for (0..lc_cuts) |j| {
        const t = @as(f32, @floatFromInt(j + 1)) / @as(f32, @floatFromInt(lc_cuts + 1));
        var k: usize = 0;
        while (k + 1 < n or (ring.closed and k < n)) : (k += 1) {
            const e0 = ring.edges.items[k];
            const e1 = ring.edges.items[(k + 1) % n];
            const p0 = m.xform(w, m.lerp(me.verts[e0[0]], me.verts[e0[1]], t));
            const p1 = m.xform(w, m.lerp(me.verts[e1[0]], me.verts[e1[1]], t));
            out.append(A, .{ p0, p1 }) catch return;
        }
    }
}

// --- bisect ------------------------------------------------------------------------

/// Cut the mesh with a plane (world point and normal): edges crossing it get a
/// vertex, faces crossing it split in two; the new vertices are selected.
pub fn bisect(point_w: m.V3, normal_w: m.V3) !?[]const u8 {
    const me = em.mesh() orelse return "Not in edit mode";
    var w = try Work.from(me, em.sel);
    defer w.deinit();
    // the plane in the object's own space
    const wm = scene.world(em.obj);
    const inv = m.inverseAffine(wm);
    const p0 = m.xform(inv, point_w);
    // normals go through the inverse transpose
    const nT: m.V3 = .{
        inv[0] * normal_w[0] + inv[4] * normal_w[1] + inv[8] * normal_w[2],
        inv[1] * normal_w[0] + inv[5] * normal_w[1] + inv[9] * normal_w[2],
        inv[2] * normal_w[0] + inv[6] * normal_w[1] + inv[10] * normal_w[2],
    };
    if (m.len(nT) < 1e-12) return "No plane";
    const n = m.norm(nT);
    const eps: f32 = 1e-6;
    const side = try A.alloc(f32, w.verts.items.len);
    defer A.free(side);
    for (w.verts.items, 0..) |p, i| {
        side[i] = m.dot(m.sub(p, p0), n);
        if (@abs(side[i]) < eps) side[i] = 0;
    }
    for (w.sel.items) |*s| s.* = false;
    var cut = std.AutoHashMap(u64, u32).init(A);
    defer cut.deinit();
    var out: std.ArrayList(std.ArrayList(u32)) = .empty;
    var any = false;
    for (w.polys.items) |*lp| {
        const l = lp.items;
        // the polygon with the crossing points in place
        var ring: std.ArrayList(u32) = .empty;
        defer ring.deinit(A);
        for (l, 0..) |a, k| {
            const b = l[(k + 1) % l.len];
            try ring.append(A, a);
            if (side[a] * side[b] < 0) {
                const g = try cut.getOrPut(key(a, b));
                if (!g.found_existing) {
                    const t = side[a] / (side[a] - side[b]);
                    g.value_ptr.* = try w.addVert(m.lerp(w.verts.items[a], w.verts.items[b], t), true);
                    any = true;
                }
                try ring.append(A, g.value_ptr.*);
            }
        }
        // corners on the plane (old or new)
        var on: [2]usize = undefined;
        var non: usize = 0;
        for (ring.items, 0..) |v, k| {
            const s = if (v < side.len) side[v] else 0;
            if (s == 0) {
                if (non < 2) on[non] = k;
                non += 1;
                w.sel.items[v] = true;
            }
        }
        if (non == 2 and on[1] - on[0] >= 2 and on[1] - on[0] <= ring.items.len - 2) {
            any = true; // (also through two old corners: a diagonal cut)
            var q1: std.ArrayList(u32) = .empty;
            try q1.appendSlice(A, ring.items[on[0] .. on[1] + 1]);
            var q2: std.ArrayList(u32) = .empty;
            try q2.appendSlice(A, ring.items[on[1]..]);
            try q2.appendSlice(A, ring.items[0 .. on[0] + 1]);
            try out.append(A, q1);
            try out.append(A, q2);
            lp.deinit(A);
        } else {
            var q: std.ArrayList(u32) = .empty;
            try q.appendSlice(A, ring.items);
            try out.append(A, q);
            lp.deinit(A);
        }
    }
    w.polys.deinit(A);
    w.polys = out;
    if (!any) {
        return "The plane does not cut the mesh (it goes through the 3D cursor; move the cursor)";
    }
    if (w.commit("Bisect")) |why| return why;
    return null;
}

// --- spin -----------------------------------------------------------------------------

/// Sweep the selected edges around the 3D cursor: `steps` copies over
/// `degrees` about the world axis `axis` (0 x, 1 y, 2 z), quads between.
pub fn spin(steps: u32, degrees_in: f32, axis: u2) !?[]const u8 {
    // a turn or more: one closed turn (as the original)
    const degrees = std.math.clamp(degrees_in, -360, 360);
    const me = em.mesh() orelse return "Not in edit mode";
    var w = try Work.from(me, em.sel);
    defer w.deinit();
    // the selected edges
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(A);
    for (me.edge_list) |e| {
        if (em.edgeSelected(e)) try edges.append(A, e);
    }
    if (edges.items.len == 0) return "Select the edges of a profile first";
    const wm = scene.world(em.obj);
    const inv = m.inverseAffine(wm);
    const ax: m.V3 = switch (axis) {
        0 => .{ 1, 0, 0 },
        1 => .{ 0, 1, 0 },
        else => .{ 0, 0, 1 },
    };
    const full = @abs(degrees) > 360 - 1e-3;
    const nsteps = @max(1, steps);
    const rings: u32 = if (full) nsteps else nsteps + 1;
    const nv0 = w.verts.items.len;
    // per profile vertex, its copy at each step (step 0 is itself)
    var copies = std.AutoHashMap(u64, u32).init(A);
    defer copies.deinit();
    const c = scene.cursor;
    for (w.sel.items) |*s| s.* = false;
    for (0..nv0) |v| {
        if (!em.sel[v]) continue;
        const pw = m.xform(wm, w.verts.items[v]);
        const d = m.sub(pw, c);
        // on the axis: one vertex for every step
        const radial = m.sub(d, m.scale(ax, m.dot(d, ax)));
        const on_axis = m.len(radial) < 1e-6;
        for (0..rings) |k| {
            if (k == 0 or on_axis) {
                try copies.put((@as(u64, v) << 32) | k, @intCast(v));
                continue;
            }
            const ang = degrees * m.deg * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(nsteps));
            const R = m.axisAngle(ax, ang);
            const p = m.add(c, m.apply3(R, d));
            try copies.put((@as(u64, v) << 32) | k, try w.addVert(m.xform(inv, p), k == rings - 1));
        }
    }
    const last: u32 = if (full) nsteps else nsteps;
    for (edges.items) |e| {
        var k: u32 = 0;
        while (k < last) : (k += 1) {
            const k1: u32 = if (full and k + 1 == nsteps) 0 else k + 1;
            const a0 = copies.get((@as(u64, e[0]) << 32) | k).?;
            const b0 = copies.get((@as(u64, e[1]) << 32) | k).?;
            const a1 = copies.get((@as(u64, e[0]) << 32) | k1).?;
            const b1 = copies.get((@as(u64, e[1]) << 32) | k1).?;
            try w.addPoly(&.{ a0, b0, b1, a1 });
        }
    }
    cleanPolys(&w);
    if (w.commit("Spin")) |why| return why;
    // the faces' outside: as the rest of the mesh
    _ = try mo.recalcNormals();
    return null;
}

// --- bevel ---------------------------------------------------------------------------

/// Bevel the selected edges: at each end the faces' corners slide `width`
/// along their other edges, a strip of `segments` rows (a curve through the
/// old corner) replaces the edge, and the corners where strips meet get a cap.
pub fn bevel(width: f32, segments: u32) !?[]const u8 {
    const me = em.mesh() orelse return "Not in edit mode";
    const segs: u32 = std.math.clamp(segments, 1, 32);
    // the beveled edges: selected, between two faces
    var faces_of = std.AutoHashMap(u64, [2]u32).init(A);
    defer faces_of.deinit();
    const np = me.poff.len - 1;
    var count = std.AutoHashMap(u64, u8).init(A);
    defer count.deinit();
    for (0..np) |p| {
        const l = me.loops[me.poff[p]..me.poff[p + 1]];
        for (l, 0..) |a, k| {
            const b = l[(k + 1) % l.len];
            // only edges that can bevel (both ends selected) are counted
            if (!em.sel[a] or !em.sel[b]) continue;
            const kk = key(a, b);
            const g = try count.getOrPut(kk);
            if (!g.found_existing) g.value_ptr.* = 0;
            if (g.value_ptr.* < 2) {
                const f = try faces_of.getOrPut(kk);
                if (!f.found_existing) f.value_ptr.* = .{ @intCast(p), 0 } else f.value_ptr.*[1] = @intCast(p);
            }
            g.value_ptr.* +|= 1;
        }
    }
    var bev = std.AutoHashMap(u64, void).init(A);
    defer bev.deinit();
    for (me.edge_list) |e| {
        if (!em.edgeSelected(e)) continue;
        if ((count.get(key(e[0], e[1])) orelse 0) != 2) continue;
        try bev.put(key(e[0], e[1]), {});
    }
    if (bev.count() == 0) return "Select edges between two faces first";
    if (!(width > 0)) return null; // nothing yet (the tool starts at 0)

    var w = try Work.from(me, em.sel);
    defer w.deinit();
    for (w.sel.items) |*s| s.* = false;
    const isBev = struct {
        fn f(bv: *const std.AutoHashMap(u64, void), a: u32, b: u32) bool {
            return bv.contains(key(a, b));
        }
    }.f;
    // the vertices at beveled edges, and their neighbours (edges)
    var touched = try A.alloc(bool, me.verts.len);
    defer A.free(touched);
    @memset(touched, false);
    var it0 = bev.keyIterator();
    while (it0.next()) |k| {
        touched[@intCast(k.* >> 32)] = true;
        touched[@intCast(k.* & 0xffffffff)] = true;
    }
    var nbrs = std.AutoHashMap(u32, std.ArrayList(u32)).init(A);
    defer {
        var ni = nbrs.valueIterator();
        while (ni.next()) |l| l.deinit(A);
        nbrs.deinit();
    }
    // a vertex's edges are limited by the shortest: never slide past the middle
    var lim = try A.alloc(f32, me.verts.len);
    defer A.free(lim);
    @memset(lim, width);
    for (me.edge_list) |e| {
        if (!touched[e[0]] and !touched[e[1]]) continue;
        // 45% of the shortest edge (meshops.s m2_clamp): corners never meet
        const half = m.len(m.sub(me.verts[e[0]], me.verts[e[1]])) * 0.45;
        lim[e[0]] = @min(lim[e[0]], half);
        lim[e[1]] = @min(lim[e[1]], half);
        for ([2]u32{ e[0], e[1] }, 0..) |v, k| {
            if (!touched[v]) continue;
            const g = try nbrs.getOrPut(v);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(A, e[1 - k]);
        }
    }
    // new corner points: slides (v towards x) and face corners (face p at v)
    var slide = std.AutoHashMap(u64, u32).init(A);
    defer slide.deinit();
    var corner = std.AutoHashMap(u64, u32).init(A);
    defer corner.deinit();
    var origin: std.ArrayList(u32) = .empty; // new vertex -> the vertex it came from
    defer origin.deinit(A);
    const nv0: u32 = @intCast(me.verts.len);
    const S = struct {
        fn get(ww: *Work, map: *std.AutoHashMap(u64, u32), org: *std.ArrayList(u32), k: u64, p: m.V3, from: u32) !u32 {
            const g = try map.getOrPut(k);
            if (!g.found_existing) {
                g.value_ptr.* = try ww.addVert(p, true);
                try org.append(A, from);
            }
            return g.value_ptr.*;
        }
    };
    // per face, the corner point(s) at v
    const PtAt = struct { a: u32, b: u32, two: bool };
    var at = std.AutoHashMap(u64, PtAt).init(A); // (face, v) -> its point(s)
    defer at.deinit();
    var out: std.ArrayList(std.ArrayList(u32)) = .empty;
    errdefer {
        for (out.items) |*l| l.deinit(A);
        out.deinit(A);
    }
    const ptouch = try A.alloc(bool, np);
    defer A.free(ptouch);
    for (0..np) |p| {
        const l = me.loops[me.poff[p]..me.poff[p + 1]];
        ptouch[p] = false;
        for (l) |v| {
            if (touched[v]) ptouch[p] = true;
        }
        if (!ptouch[p]) {
            // far from the bevel: the polygon as it is
            try out.append(A, w.polys.items[p]);
            w.polys.items[p] = .empty;
            continue;
        }
        var q: std.ArrayList(u32) = .empty;
        for (l, 0..) |v, k| {
            if (!touched[v]) {
                try q.append(A, v);
                continue;
            }
            const u = l[(k + l.len - 1) % l.len];
            const x = l[(k + 1) % l.len];
            const pv = me.verts[v];
            const d = lim[v];
            const tu = m.norm(m.sub(me.verts[u], pv));
            const tx = m.norm(m.sub(me.verts[x], pv));
            const bu = isBev(&bev, u, v);
            const bx = isBev(&bev, v, x);
            const fk = (@as(u64, p) << 32) | v;
            if (bu and bx) {
                // both edges go: a point inside the face's corner
                const c = try S.get(&w, &corner, &origin, fk, m.add(pv, m.add(m.scale(tu, d), m.scale(tx, d))), v);
                try q.append(A, c);
                try at.put(fk, .{ .a = c, .b = c, .two = false });
            } else if (bu) {
                const c = try S.get(&w, &slide, &origin, (@as(u64, v) << 32) | x, m.add(pv, m.scale(tx, d)), v);
                try q.append(A, c);
                try at.put(fk, .{ .a = c, .b = c, .two = false });
            } else if (bx) {
                const c = try S.get(&w, &slide, &origin, (@as(u64, v) << 32) | u, m.add(pv, m.scale(tu, d)), v);
                try q.append(A, c);
                try at.put(fk, .{ .a = c, .b = c, .two = false });
            } else {
                // a face beside the beveled edges: fixed below, once every slide is known
                try q.append(A, v);
            }
        }
        try out.append(A, q);
    }
    // second pass: corners of faces beside the bevel take the slides on their edges
    for (0..np) |p| {
        if (!ptouch[p]) continue;
        const l = me.loops[me.poff[p]..me.poff[p + 1]];
        var q: std.ArrayList(u32) = .empty;
        var changed = false;
        for (out.items[p].items, 0..) |cur, k| {
            _ = k;
            if (cur >= nv0 or !touched[cur]) {
                try q.append(A, cur);
                continue;
            }
            const v = cur;
            // where v sits in the original polygon
            var j: usize = 0;
            while (j < l.len and l[j] != v) j += 1;
            const u = l[(j + l.len - 1) % l.len];
            const x = l[(j + 1) % l.len];
            const su = slide.get((@as(u64, v) << 32) | u);
            const sx = slide.get((@as(u64, v) << 32) | x);
            if (su == null and sx == null) {
                try q.append(A, v);
                continue;
            }
            changed = true;
            if (su) |a| try q.append(A, a);
            if (su != null and sx != null) {
                // v stays between them when it has edges that do not bevel
                var keeps = false;
                if (nbrs.get(v)) |nl| for (nl.items) |oo| {
                    if (!isBev(&bev, v, oo) and slide.get((@as(u64, v) << 32) | oo) == null) keeps = true;
                };
                if (keeps) try q.append(A, v);
            }
            if (sx) |b| try q.append(A, b);
            try at.put((@as(u64, p) << 32) | v, .{ .a = su orelse v, .b = sx orelse v, .two = true });
        }
        if (changed) {
            out.items[p].deinit(A);
            out.items[p] = q;
        } else q.deinit(A);
    }
    // the strips: between the two faces' points at each end, `segs` rows
    var it = bev.iterator();
    while (it.next()) |kv| {
        const a: u32 = @intCast(kv.key_ptr.* >> 32);
        const b: u32 = @intCast(kv.key_ptr.* & 0xffffffff);
        const fp = faces_of.get(kv.key_ptr.*).?;
        var rows: [2][33]u32 = undefined;
        for ([2]u32{ a, b }, 0..) |v, end| {
            const p1 = (at.get((@as(u64, fp[0]) << 32) | v) orelse return "it failed").a;
            const p2 = (at.get((@as(u64, fp[1]) << 32) | v) orelse return "it failed").a;
            rows[end][0] = p1;
            rows[end][segs] = p2;
            var s: u32 = 1;
            while (s < segs) : (s += 1) {
                const t = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segs));
                const P1 = w.verts.items[p1];
                const P2 = w.verts.items[p2];
                const C = me.verts[v];
                // a quadratic curve through the old corner's side (rounded)
                const pt = m.add(m.add(m.scale(P1, (1 - t) * (1 - t)), m.scale(C, 2 * t * (1 - t))), m.scale(P2, t * t));
                // each strip's own arc points (never shared)
                rows[end][s] = try w.addVert(pt, true);
                try origin.append(A, v);
            }
        }
        // wound against the first face's a -> b (its new edge runs the same way)
        const l1 = me.loops[me.poff[fp[0]]..me.poff[fp[0] + 1]];
        var fwd = false;
        for (l1, 0..) |x, k| {
            if (x == a and l1[(k + 1) % l1.len] == b) fwd = true;
        }
        var s: u32 = 0;
        while (s < segs) : (s += 1) {
            if (fwd)
                try w.addPoly(&.{ rows[1][s], rows[0][s], rows[0][s + 1], rows[1][s + 1] })
            else
                try w.addPoly(&.{ rows[0][s], rows[1][s], rows[1][s + 1], rows[0][s + 1] });
        }
    }
    // the faces with their new corners (instead of the old ones)
    for (w.polys.items[0..np]) |*l| l.deinit(A);
    const strips = w.polys.items[np..];
    var all: std.ArrayList(std.ArrayList(u32)) = .empty;
    try all.appendSlice(A, out.items);
    try all.appendSlice(A, strips);
    out.deinit(A);
    out = .empty;
    w.polys.deinit(A);
    w.polys = all;
    w.clean();
    // corners where strips meet: their open rings (new points of one vertex) get a cap
    try capHoles(&w, nv0, origin.items);
    // the old corners the bevel replaced (other loose vertices stay)
    try dropUnused(&w, touched);
    if (w.commit("Bevel")) |why| return why;
    return null;
}

/// Fill boundary rings made only of new vertices that came from one vertex.
fn capHoles(w: *Work, nv0: u32, origin: []const u32) !void {
    var next = std.AutoHashMap(u32, u32).init(A);
    defer next.deinit();
    var uses = std.AutoHashMap(u64, i32).init(A);
    defer uses.deinit();
    const hasNew = struct {
        fn f(l: []const u32, n0: u32) bool {
            for (l) |v| {
                if (v >= n0) return true;
            }
            return false;
        }
    }.f;
    for (w.polys.items) |*lp| {
        const l = lp.items;
        if (!hasNew(l, nv0)) continue;
        for (l, 0..) |a, k| {
            const b = l[(k + 1) % l.len];
            const g = try uses.getOrPut(key(a, b));
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }
    for (w.polys.items) |*lp| {
        const l = lp.items;
        if (!hasNew(l, nv0)) continue;
        for (l, 0..) |a, k| {
            const b = l[(k + 1) % l.len];
            if (uses.get(key(a, b)).? != 1) continue;
            if (a < nv0 or b < nv0) continue;
            if (origin[a - nv0] != origin[b - nv0]) continue;
            // boundary edge a -> b: the cap runs b -> a
            try next.put(b, a);
        }
    }
    var done = std.AutoHashMap(u32, void).init(A);
    defer done.deinit();
    var kit = next.iterator();
    while (kit.next()) |kv| {
        const s0 = kv.key_ptr.*;
        if (done.contains(s0)) continue;
        var ring: std.ArrayList(u32) = .empty;
        defer ring.deinit(A);
        var cur = s0;
        var ok = false;
        while (ring.items.len <= next.count()) {
            if (done.contains(cur)) break;
            try done.put(cur, {});
            try ring.append(A, cur);
            cur = next.get(cur) orelse break;
            if (cur == s0) {
                ok = true;
                break;
            }
        }
        if (ok and ring.items.len >= 3) try w.addPoly(ring.items);
    }
}

// --- knife ---------------------------------------------------------------------------

/// The knife tool: clicked points (screen), Enter cuts, Esc stops.
pub var kn_active = false;
pub var kn_pts: [64][2]f32 = undefined;
pub var kn_n: usize = 0;

pub fn knStart() void {
    kn_active = true;
    kn_n = 0;
}

pub fn knAdd(x: i32, y: i32) void {
    if (kn_n >= kn_pts.len) return;
    const p: [2]f32 = .{ @floatFromInt(x), @floatFromInt(y) };
    // the same point twice: ignored
    if (kn_n > 0 and @abs(kn_pts[kn_n - 1][0] - p[0]) + @abs(kn_pts[kn_n - 1][1] - p[1]) < 2) return;
    kn_pts[kn_n] = p;
    kn_n += 1;
}

/// Cut along the polyline `pts` (screen points of camera `c`): every segment is
/// a plane through the eye and both points; edges crossing it between the two
/// points get a vertex, and the faces facing the camera split along them.
pub fn knifeCut(c: *const vp.Cam, pts: []const [2]f32) !?[]const u8 {
    const me0 = em.mesh() orelse return "Not in edit mode";
    if (pts.len < 2) return "Click at least two points, then Enter";
    _ = me0;
    var any = false;
    for (0..pts.len - 1) |s| {
        if (try knifeSegment(c, pts[s], pts[s + 1])) any = true;
    }
    if (!any) return "The cut crosses no edge";
    return null;
}

fn rayDir(c: *const vp.Cam, p: [2]f32) m.V3 {
    const px = (p[0] - c.cx) / c.f;
    const py = -(p[1] - c.cy) / c.f;
    return m.add(c.fwd, m.add(m.scale(c.right, px), m.scale(c.up, py)));
}

fn knifeSegment(c: *const vp.Cam, p0: [2]f32, p1: [2]f32) !bool {
    const me = em.mesh() orelse return false;
    var w = try Work.from(me, em.sel);
    defer w.deinit();
    const wm = scene.world(em.obj);
    const nv0 = w.verts.items.len;
    // the plane in world space, the vertices' sides of it
    const n = m.cross(rayDir(c, p0), rayDir(c, p1));
    if (m.len(n) < 1e-12) return false;
    const nn = m.norm(n);
    const wv = try A.alloc(m.V3, nv0);
    defer A.free(wv);
    const side = try A.alloc(f32, nv0);
    defer A.free(side);
    for (w.verts.items, 0..) |p, i| {
        wv[i] = m.xform(wm, p);
        side[i] = m.dot(m.sub(wv[i], c.eye), nn);
    }
    // where a world point falls along the segment (0..1), from the screen
    const seg = [2]f32{ p1[0] - p0[0], p1[1] - p0[1] };
    const l2 = seg[0] * seg[0] + seg[1] * seg[1];
    if (l2 < 1) return false;
    for (w.sel.items) |*sx| sx.* = false;
    // vertices on the cut (within a hair, between the two points): used as they are
    const on = try A.alloc(bool, nv0);
    defer A.free(on);
    for (0..nv0) |i| {
        on[i] = false;
        const eps = 1e-5 * @max(1.0, m.len(m.sub(wv[i], c.eye)));
        if (@abs(side[i]) > eps) continue;
        const v = c.toView(wv[i]);
        if (v[2] < 1e-4) continue;
        const s = c.screen(v);
        const u = ((s[0] - p0[0]) * seg[0] + (s[1] - p0[1]) * seg[1]) / l2;
        on[i] = u >= -1e-4 and u <= 1 + 1e-4;
    }
    var cut = std.AutoHashMap(u64, u32).init(A);
    defer cut.deinit();
    var any = false;
    // faces facing the camera (the ones the knife sees)
    const np = w.polys.items.len;
    const front = try A.alloc(bool, np);
    defer A.free(front);
    for (0..np) |p| {
        const l = w.polys.items[p].items;
        var nrm: m.V3 = .{ 0, 0, 0 };
        for (l, 0..) |a, k| {
            const b = l[(k + 1) % l.len];
            nrm = m.add(nrm, m.cross(wv[a], wv[b]));
        }
        front[p] = l.len >= 3 and m.dot(nrm, m.sub(wv[l[0]], c.eye)) < 0;
    }
    // the crossings: on edges of front faces, inside the segment
    for (0..np) |p| {
        if (!front[p]) continue;
        const l = w.polys.items[p].items;
        for (l, 0..) |a, k| {
            const b = l[(k + 1) % l.len];
            if (on[a] or on[b] or !(side[a] * side[b] < 0)) continue;
            const kk = key(a, b);
            if (cut.contains(kk)) continue;
            const t = side[a] / (side[a] - side[b]);
            const q = m.lerp(wv[a], wv[b], t);
            const v = c.toView(q);
            if (v[2] < 1e-4) continue;
            const s = c.screen(v);
            const u = ((s[0] - p0[0]) * seg[0] + (s[1] - p0[1]) * seg[1]) / l2;
            if (u < -1e-4 or u > 1 + 1e-4) continue;
            try cut.put(kk, try w.addVert(m.lerp(w.verts.items[a], w.verts.items[b], t), true));
            any = true;
        }
    }
    // every polygon takes the new points on its edges; front faces with two split
    var split_any = false;
    var out: std.ArrayList(std.ArrayList(u32)) = .empty;
    for (w.polys.items, 0..) |*lp, p| {
        const l = lp.items;
        var ring: std.ArrayList(u32) = .empty;
        defer ring.deinit(A);
        var at: [2]usize = undefined;
        var nat: usize = 0;
        for (l, 0..) |a, k| {
            const b = l[(k + 1) % l.len];
            if (on[a]) {
                // an old corner on the cut: the split may run through it
                if (nat < 2) at[nat] = ring.items.len;
                nat += 1;
                w.sel.items[a] = true;
            }
            try ring.append(A, a);
            if (cut.get(key(a, b))) |nvx| {
                if (nat < 2) at[nat] = ring.items.len;
                nat += 1;
                try ring.append(A, nvx);
            }
        }
        if (front[p] and nat == 2 and at[1] - at[0] >= 2 and ring.items.len - (at[1] - at[0]) >= 2) {
            split_any = true;
            var q1: std.ArrayList(u32) = .empty;
            try q1.appendSlice(A, ring.items[at[0] .. at[1] + 1]);
            var q2: std.ArrayList(u32) = .empty;
            try q2.appendSlice(A, ring.items[at[1]..]);
            try q2.appendSlice(A, ring.items[0 .. at[0] + 1]);
            try out.append(A, q1);
            try out.append(A, q2);
        } else {
            var q: std.ArrayList(u32) = .empty;
            try q.appendSlice(A, ring.items);
            try out.append(A, q);
        }
        lp.deinit(A);
    }
    w.polys.deinit(A);
    w.polys = out;
    if (!any and !split_any) return false;
    return w.commit("Knife") == null;
}
