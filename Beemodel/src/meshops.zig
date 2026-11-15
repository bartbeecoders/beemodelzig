// Mesh tools for edit mode, as the original's Mesh menu: extrude (E),
// extrude individual faces (Alt+E), inset (I), merge at centre (M), fill /
// make face (F), duplicate (Shift+D), flip and recalculate normals (Shift+N),
// subdivide, dissolve (Ctrl+X). Each builds a new mesh (one undo step).
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const em = @import("editmesh.zig");

const A = @import("alloc.zig").A;

/// An editable copy: vertices, polygons as lists, the vertex selection.
pub const Work = struct {
    verts: std.ArrayList(m.V3) = .empty,
    sel: std.ArrayList(bool) = .empty,
    polys: std.ArrayList(std.ArrayList(u32)) = .empty,

    pub fn from(me: *const scene.Mesh, sel: []const bool) !Work {
        var w = Work{};
        try w.verts.appendSlice(A, me.verts);
        try w.sel.appendSlice(A, sel[0..@min(sel.len, me.verts.len)]);
        while (w.sel.items.len < w.verts.items.len) try w.sel.append(A, false);
        for (0..me.poff.len - 1) |p| {
            var l: std.ArrayList(u32) = .empty;
            try l.appendSlice(A, me.loops[me.poff[p]..me.poff[p + 1]]);
            try w.polys.append(A, l);
        }
        return w;
    }

    pub fn deinit(w: *Work) void {
        for (w.polys.items) |*p| p.deinit(A);
        w.polys.deinit(A);
        w.verts.deinit(A);
        w.sel.deinit(A);
    }

    pub fn addVert(w: *Work, p: m.V3, s: bool) !u32 {
        try w.verts.append(A, p);
        try w.sel.append(A, s);
        return @intCast(w.verts.items.len - 1);
    }

    pub fn addPoly(w: *Work, vs: []const u32) !void {
        var l: std.ArrayList(u32) = .empty;
        try l.appendSlice(A, vs);
        try w.polys.append(A, l);
    }

    fn faceSel(w: *const Work, p: usize) bool {
        const l = w.polys.items[p].items;
        if (l.len == 0) return false;
        for (l) |v| {
            if (!w.sel.items[v]) return false;
        }
        return true;
    }

    fn normal(w: *const Work, p: usize) m.V3 {
        // Newell's method: right for any planar-ish polygon
        const l = w.polys.items[p].items;
        var n: m.V3 = .{ 0, 0, 0 };
        for (l, 0..) |a, k| {
            const pa = w.verts.items[a];
            const pb = w.verts.items[l[(k + 1) % l.len]];
            n[0] += (pa[1] - pb[1]) * (pa[2] + pb[2]);
            n[1] += (pa[2] - pb[2]) * (pa[0] + pb[0]);
            n[2] += (pa[0] - pb[0]) * (pa[1] + pb[1]);
        }
        const ln = m.len(n);
        return if (ln < 1e-12) .{ 0, 0, 0 } else m.scale(n, 1 / ln);
    }

    fn center(w: *const Work, p: usize) m.V3 {
        const l = w.polys.items[p].items;
        var c: m.V3 = .{ 0, 0, 0 };
        for (l) |v| c = m.add(c, w.verts.items[v]);
        return m.scale(c, 1 / @as(f32, @floatFromInt(@max(1, l.len))));
    }

    /// Drop polygons with fewer than three corners (and repeated corners in a row).
    pub fn clean(w: *Work) void {
        var out: usize = 0;
        for (w.polys.items) |*lp| {
            var l = lp.*;
            // repeated corners in a row (also last == first) go, in one pass
            var n: usize = 0;
            for (l.items) |v| {
                if (n == 0 or l.items[n - 1] != v) {
                    l.items[n] = v;
                    n += 1;
                }
            }
            while (n > 1 and l.items[n - 1] == l.items[0]) n -= 1;
            l.items.len = n;
            if (n < 3) {
                l.deinit(A);
            } else {
                w.polys.items[out] = l;
                out += 1;
            }
        }
        w.polys.items.len = out;
    }

    /// Drop the polygons `drop` marks (one pass).
    pub fn dropPolys(w: *Work, drop: []const bool) void {
        var out: usize = 0;
        for (w.polys.items, 0..) |*lp, k| {
            if (k < drop.len and drop[k]) {
                lp.deinit(A);
            } else {
                w.polys.items[out] = lp.*;
                out += 1;
            }
        }
        w.polys.items.len = out;
    }

    /// Drop vertices no polygon uses (only those `only` marks).
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
            const keep = used[i] or i >= only.len or !only[i];
            if (keep) {
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

    /// Make it the edited object's mesh (one undo step).
    pub fn commit(w: *Work, label: []const u8) ?[]const u8 {
        var poff: std.ArrayList(u32) = .empty;
        defer poff.deinit(A);
        var loops: std.ArrayList(u32) = .empty;
        defer loops.deinit(A);
        poff.append(A, 0) catch return "Out of memory";
        for (w.polys.items) |l| {
            loops.appendSlice(A, l.items) catch return "Out of memory";
            poff.append(A, @intCast(loops.items.len)) catch return "Out of memory";
        }
        if (w.verts.items.len == 0) return "That would leave nothing";
        if (!em.commit(w.verts.items, poff.items, loops.items, w.sel.items, label)) return "The mesh could not be made";
        return null;
    }
};

fn begin() !Work {
    const me = em.mesh() orelse return error.NotEditing;
    return Work.from(me, em.sel);
}

fn edgeKey(a: u32, b: u32) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

/// How many selected faces use each edge (for region boundaries).
fn regionEdgeCounts(w: *const Work, is_sel: []const bool) !std.AutoHashMap(u64, u32) {
    var map = std.AutoHashMap(u64, u32).init(A);
    for (w.polys.items, 0..) |l, p| {
        if (!is_sel[p]) continue;
        for (l.items, 0..) |a, k| {
            const b = l.items[(k + 1) % l.items.len];
            const g = try map.getOrPut(edgeKey(a, b));
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }
    return map;
}

// --- extrude ------------------------------------------------------------------

/// Extrude the selected faces as one region (or, with no face, the selected
/// edges into new faces). Returns the direction to move it along.
pub fn extrude() !?m.V3 {
    var w = try begin();
    defer w.deinit();
    const np = w.polys.items.len;
    const fsel = try A.alloc(bool, np);
    defer A.free(fsel);
    var nf: usize = 0;
    for (0..np) |p| {
        fsel[p] = w.faceSel(p);
        if (fsel[p]) nf += 1;
    }
    const nv = w.verts.items.len;
    const dup = try A.alloc(u32, nv);
    defer A.free(dup);
    @memset(dup, std.math.maxInt(u32));
    var dir: m.V3 = .{ 0, 0, 0 };
    if (nf > 0) {
        var counts = try regionEdgeCounts(&w, fsel);
        defer counts.deinit();
        // the region's vertices get copies
        for (0..np) |p| {
            if (!fsel[p]) continue;
            dir = m.add(dir, w.normal(p));
            for (w.polys.items[p].items) |v| {
                if (dup[v] == std.math.maxInt(u32)) dup[v] = try w.addVert(w.verts.items[v], true);
            }
        }
        // a side quad on every boundary edge of the region
        for (0..np) |p| {
            if (!fsel[p]) continue;
            const l = w.polys.items[p].items;
            for (l, 0..) |a, k| {
                const b = l[(k + 1) % l.len];
                if (counts.get(edgeKey(a, b)).? == 1) try w.addPoly(&.{ a, b, dup[b], dup[a] });
            }
        }
        // the region moves to the copies
        for (0..np) |p| {
            if (!fsel[p]) continue;
            for (w.polys.items[p].items) |*v| v.* = dup[v.*];
        }
    } else {
        // edges: each selected edge (not inside a face) gets a face up to its copy
        var any = false;
        var seen = std.AutoHashMap(u64, void).init(A);
        defer seen.deinit();
        for (0..np) |p| {
            const l = w.polys.items[p].items;
            for (l, 0..) |a, k| {
                const b = l[(k + 1) % l.len];
                if (!(w.sel.items[a] and w.sel.items[b])) continue;
                if ((try seen.getOrPut(edgeKey(a, b))).found_existing) continue;
                if (dup[a] == std.math.maxInt(u32)) dup[a] = try w.addVert(w.verts.items[a], true);
                if (dup[b] == std.math.maxInt(u32)) dup[b] = try w.addVert(w.verts.items[b], true);
                // the new face continues the old one's winding
                try w.addPoly(&.{ b, a, dup[a], dup[b] });
                dir = m.add(dir, w.normal(p));
                any = true;
            }
        }
        if (!any) return null;
    }
    // the old selection goes; the copies are selected
    for (0..nv) |i| w.sel.items[i] = false;
    // vertices only the region used are left over
    const old_region = try A.alloc(bool, w.verts.items.len);
    defer A.free(old_region);
    @memset(old_region, false);
    for (0..nv) |i| old_region[i] = dup[i] != std.math.maxInt(u32);
    try w.dropUnused(old_region);
    if (w.commit("Extrude")) |_| return null;
    const l = m.len(dir);
    return if (l < 1e-9) m.V3{ 0, 1, 0 } else m.scale(dir, 1 / l);
}

/// Each selected face extruded on its own (a ring of quads each); the faces
/// then move along their own normals by `dist`.
pub fn extrudeIndividual(dist: f32) !bool {
    var w = try begin();
    defer w.deinit();
    const np = w.polys.items.len;
    var any = false;
    for (0..np) |p| {
        if (!w.faceSel(p)) continue;
        any = true;
        const n = w.normal(p);
        const l = try A.dupe(u32, w.polys.items[p].items);
        defer A.free(l);
        var top = try A.alloc(u32, l.len);
        defer A.free(top);
        for (l, 0..) |v, k| top[k] = try w.addVert(m.add(w.verts.items[v], m.scale(n, dist)), true);
        for (l, 0..) |a, k| {
            const kn = (k + 1) % l.len;
            try w.addPoly(&.{ a, l[kn], top[kn], top[k] });
        }
        @memcpy(w.polys.items[p].items, top);
    }
    if (!any) return false;
    // only the moved faces' vertices (the new ones, at the end) stay selected
    const first_new = em.mesh().?.verts.len;
    for (w.sel.items, 0..) |*s, i| s.* = i >= first_new;
    return w.commit("Extrude Individual Faces") == null;
}

// --- inset ----------------------------------------------------------------------

/// Inset every selected face by `t`: a smaller face inside, a ring of quads round it.
pub fn inset(t: f32) !bool {
    var w = try begin();
    defer w.deinit();
    const np = w.polys.items.len;
    var any = false;
    const first_new = w.verts.items.len;
    for (0..np) |p| {
        if (!w.faceSel(p)) continue;
        any = true;
        const n = w.normal(p);
        const l = try A.dupe(u32, w.polys.items[p].items);
        defer A.free(l);
        var inner = try A.alloc(u32, l.len);
        defer A.free(inner);
        for (l, 0..) |v, k| {
            // along the corner's bisector, t from both edges
            const pv = w.verts.items[v];
            const pp = w.verts.items[l[(k + l.len - 1) % l.len]];
            const pn = w.verts.items[l[(k + 1) % l.len]];
            const e1 = m.norm(m.sub(pp, pv));
            const e2 = m.norm(m.sub(pn, pv));
            var bis = m.add(e1, e2);
            if (m.len(bis) < 1e-6) bis = m.cross(n, e2); // a straight corner
            bis = m.norm(bis);
            // keep it on the inside: left of the edge to the next corner
            // (a reflex corner's bisector points out)
            if (m.dot(bis, m.cross(n, e2)) < 0) bis = m.scale(bis, -1);
            const half = std.math.acos(std.math.clamp(m.dot(e1, e2), -1.0, 1.0)) * 0.5;
            const d = t / @max(0.05, @sin(half));
            inner[k] = try w.addVert(m.add(pv, m.scale(bis, d)), true);
        }
        for (l, 0..) |a, k| {
            const kn = (k + 1) % l.len;
            try w.addPoly(&.{ a, l[kn], inner[kn], inner[k] });
        }
        @memcpy(w.polys.items[p].items, inner);
    }
    if (!any) return false;
    for (0..first_new) |i| w.sel.items[i] = false;
    return w.commit("Inset Faces") == null;
}

// --- merge, fill, duplicate --------------------------------------------------

/// Every selected vertex into one at their centre.
pub fn mergeCenter() !bool {
    var w = try begin();
    defer w.deinit();
    var c: m.V3 = .{ 0, 0, 0 };
    var n: f32 = 0;
    var first: ?u32 = null;
    for (w.sel.items, 0..) |s, i| {
        if (!s) continue;
        c = m.add(c, w.verts.items[i]);
        n += 1;
        if (first == null) first = @intCast(i);
    }
    if (n < 2) return false;
    const keep = first.?;
    w.verts.items[keep] = m.scale(c, 1 / n);
    for (w.polys.items) |*l| {
        for (l.items) |*v| {
            if (w.sel.items[v.*]) v.* = keep;
        }
    }
    w.clean();
    const drop = try A.alloc(bool, w.verts.items.len);
    defer A.free(drop);
    for (drop, 0..) |*d, i| d.* = w.sel.items[i] and i != keep;
    try w.dropUnused(drop);
    return w.commit("Merge at Center") == null;
}

/// A face from the selected vertices: the hole they border, or (no hole) in
/// order round their centre.
/// Where the view looks from (world), for faces made from loose vertices:
/// they face it, as the original's fill_order.
pub var view_eye: ?m.V3 = null;

pub fn fill() !?[]const u8 {
    var w = try begin();
    defer w.deinit();
    var vs: std.ArrayList(u32) = .empty;
    defer vs.deinit(A);
    for (w.sel.items, 0..) |s, i| {
        if (s) try vs.append(A, @intCast(i));
    }
    if (vs.items.len < 3) return "Select three vertices or more";
    // boundary edges (used by one face) between selected vertices, in their face's direction
    var counts = std.AutoHashMap(u64, u32).init(A);
    defer counts.deinit();
    for (w.polys.items) |l| {
        for (l.items, 0..) |a, k| {
            const g = try counts.getOrPut(edgeKey(a, l.items[(k + 1) % l.items.len]));
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }
    var next = std.AutoHashMap(u32, u32).init(A); // reversed boundary: b -> a
    defer next.deinit();
    for (w.polys.items) |l| {
        for (l.items, 0..) |a, k| {
            const b = l.items[(k + 1) % l.items.len];
            if (w.sel.items[a] and w.sel.items[b] and counts.get(edgeKey(a, b)).? == 1) try next.put(b, a);
        }
    }
    var loop: std.ArrayList(u32) = .empty;
    defer loop.deinit(A);
    if (next.count() == vs.items.len) {
        // walk the hole
        var at = vs.items[0];
        if (!next.contains(at)) {
            var it = next.keyIterator();
            at = it.next().?.*;
        }
        const first = at;
        while (loop.items.len <= vs.items.len) {
            try loop.append(A, at);
            at = next.get(at) orelse break;
            if (at == first) break;
        }
    }
    if (loop.items.len != vs.items.len) {
        // no clean hole: round the centre, in their best plane
        loop.clearRetainingCapacity();
        var c: m.V3 = .{ 0, 0, 0 };
        for (vs.items) |v| c = m.add(c, w.verts.items[v]);
        c = m.scale(c, 1 / @as(f32, @floatFromInt(vs.items.len)));
        var n: m.V3 = .{ 0, 0, 0 };
        for (vs.items, 0..) |v, k| {
            const a = m.sub(w.verts.items[v], c);
            const b = m.sub(w.verts.items[vs.items[(k + 1) % vs.items.len]], c);
            n = m.add(n, m.cross(a, b));
        }
        if (m.len(n) < 1e-9) n = .{ 0, 1, 0 };
        n = m.norm(n);
        var u = m.cross(n, .{ 1, 0, 0 });
        if (m.len(u) < 0.1) u = m.cross(n, .{ 0, 0, 1 });
        u = m.norm(u);
        const vv = m.cross(n, u);
        const Ang = struct { v: u32, a: f32 };
        var arr = try A.alloc(Ang, vs.items.len);
        defer A.free(arr);
        for (vs.items, 0..) |v, k| {
            const d = m.sub(w.verts.items[v], c);
            arr[k] = .{ .v = v, .a = std.math.atan2(m.dot(d, vv), m.dot(d, u)) };
        }
        std.sort.pdq(Ang, arr, {}, struct {
            fn lt(_: void, a: Ang, b: Ang) bool {
                return a.a < b.a;
            }
        }.lt);
        for (arr) |x| try loop.append(A, x.v);
        // the loop turns about n: make it face the view
        if (view_eye) |e| {
            const el = m.xform(m.inverseAffine(scene.world(em.obj)), e);
            if (m.dot(n, m.sub(el, c)) < 0) std.mem.reverse(u32, loop.items);
        }
    }
    try w.addPoly(loop.items);
    if (w.commit("Fill")) |why| return why;
    return null;
}

/// Copies of the selected faces (and their vertices), selected.
pub fn duplicate() !bool {
    var w = try begin();
    defer w.deinit();
    const np = w.polys.items.len;
    const nv = w.verts.items.len;
    const dup = try A.alloc(u32, nv);
    defer A.free(dup);
    @memset(dup, std.math.maxInt(u32));
    var any = false;
    for (0..np) |p| {
        if (!w.faceSel(p)) continue;
        any = true;
        var nl: std.ArrayList(u32) = .empty;
        for (w.polys.items[p].items) |v| {
            if (dup[v] == std.math.maxInt(u32)) dup[v] = try w.addVert(w.verts.items[v], true);
            try nl.append(A, dup[v]);
        }
        try w.polys.append(A, nl);
    }
    if (!any) return false;
    for (0..nv) |i| w.sel.items[i] = false;
    return w.commit("Duplicate") == null;
}

// --- normals ---------------------------------------------------------------------

pub fn flipNormals() !bool {
    var w = try begin();
    defer w.deinit();
    var any = false;
    for (0..w.polys.items.len) |p| {
        if (!w.faceSel(p)) continue;
        std.mem.reverse(u32, w.polys.items[p].items);
        any = true;
    }
    if (!any) return false;
    return w.commit("Flip Normals") == null;
}

/// Consistent winding across each connected part, pointing outside
/// (the part's signed volume positive).
pub fn recalcNormals() !bool {
    var w = try begin();
    defer w.deinit();
    const np = w.polys.items.len;
    if (np == 0) return false;
    var only_sel = false;
    for (0..np) |p| {
        if (w.faceSel(p)) only_sel = true;
    }
    // edges -> the polygons on them
    var owners = std.AutoHashMap(u64, [2]u32).init(A);
    defer owners.deinit();
    for (w.polys.items, 0..) |l, p| {
        for (l.items, 0..) |a, k| {
            const g = try owners.getOrPut(edgeKey(a, l.items[(k + 1) % l.items.len]));
            if (!g.found_existing) g.value_ptr.* = .{ @intCast(p), std.math.maxInt(u32) } else g.value_ptr.*[1] = @intCast(p);
        }
    }
    const done = try A.alloc(bool, np);
    defer A.free(done);
    @memset(done, false);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(A);
    var part: std.ArrayList(u32) = .empty;
    defer part.deinit(A);
    // the selected faces get the winding their whole part agrees on (an open
    // patch alone has no inside); the others keep theirs
    var keep: std.ArrayList([]u32) = .empty;
    defer {
        for (keep.items) |k| A.free(k);
        keep.deinit(A);
    }
    if (only_sel) {
        for (0..np) |p| {
            try keep.append(A, if (w.faceSel(p)) &.{} else try A.dupe(u32, w.polys.items[p].items));
        }
    }
    for (0..np) |seed| {
        if (done[seed]) continue;
        part.clearRetainingCapacity();
        queue.clearRetainingCapacity();
        try queue.append(A, @intCast(seed));
        done[seed] = true;
        while (queue.items.len > 0) {
            const p = queue.pop().?;
            try part.append(A, p);
            const l = w.polys.items[p].items;
            for (l, 0..) |a, k| {
                const b = l[(k + 1) % l.len];
                const o = owners.get(edgeKey(a, b)).?;
                const q = if (o[0] == p) o[1] else o[0];
                if (q == std.math.maxInt(u32) or done[q]) continue;
                // a neighbour must run the shared edge the other way (b -> a)
                const ql = w.polys.items[q].items;
                var same = false;
                for (ql, 0..) |x, j| {
                    if (x == a and ql[(j + 1) % ql.len] == b) same = true;
                }
                if (same) std.mem.reverse(u32, w.polys.items[q].items);
                done[q] = true;
                try queue.append(A, q);
            }
        }
        // outside: the part's signed volume (about its centre) is positive
        var c: m.V3 = .{ 0, 0, 0 };
        var nc: f32 = 0;
        for (part.items) |p| {
            for (w.polys.items[p].items) |v| {
                c = m.add(c, w.verts.items[v]);
                nc += 1;
            }
        }
        c = m.scale(c, 1 / @max(1, nc));
        var vol: f32 = 0;
        for (part.items) |p| {
            const l = w.polys.items[p].items;
            for (1..l.len - 1) |k| {
                const a = m.sub(w.verts.items[l[0]], c);
                const b = m.sub(w.verts.items[l[k]], c);
                const cc = m.sub(w.verts.items[l[k + 1]], c);
                vol += m.dot(a, m.cross(b, cc));
            }
        }
        if (vol < 0) {
            for (part.items) |p| std.mem.reverse(u32, w.polys.items[p].items);
        }
    }
    if (only_sel) {
        for (keep.items, 0..) |k, p| {
            if (k.len > 0) @memcpy(w.polys.items[p].items, k);
        }
    }
    return w.commit("Recalculate Normals") == null;
}

// --- subdivide ------------------------------------------------------------------

/// Split the selected faces: quads into four, triangles into four, n-gons
/// round a centre. Faces beside them get the new edge points (no gaps).
pub fn subdivide() !bool {
    var w = try begin();
    defer w.deinit();
    const np = w.polys.items.len;
    const fsel = try A.alloc(bool, np);
    defer A.free(fsel);
    var any = false;
    for (0..np) |p| {
        fsel[p] = w.faceSel(p);
        if (fsel[p]) any = true;
    }
    if (!any) return false;
    // a midpoint per edge of a selected face
    var mid = std.AutoHashMap(u64, u32).init(A);
    defer mid.deinit();
    for (0..np) |p| {
        if (!fsel[p]) continue;
        const l = w.polys.items[p].items;
        for (l, 0..) |a, k| {
            const b = l[(k + 1) % l.len];
            const g = try mid.getOrPut(edgeKey(a, b));
            if (!g.found_existing) g.value_ptr.* = try w.addVert(m.scale(m.add(w.verts.items[a], w.verts.items[b]), 0.5), true);
        }
    }
    var out: std.ArrayList(std.ArrayList(u32)) = .empty;
    for (0..np) |p| {
        const l = w.polys.items[p].items;
        if (fsel[p]) {
            if (l.len == 3) {
                const ab = mid.get(edgeKey(l[0], l[1])).?;
                const bc = mid.get(edgeKey(l[1], l[2])).?;
                const ca = mid.get(edgeKey(l[2], l[0])).?;
                inline for (.{ [3]u32{ l[0], ab, ca }, [3]u32{ ab, l[1], bc }, [3]u32{ ca, bc, l[2] }, [3]u32{ ab, bc, ca } }) |t| {
                    var nl: std.ArrayList(u32) = .empty;
                    try nl.appendSlice(A, &t);
                    try out.append(A, nl);
                }
            } else {
                const cen = try w.addVert(w.center(p), true);
                for (l, 0..) |v, k| {
                    const prev = l[(k + l.len - 1) % l.len];
                    const next = l[(k + 1) % l.len];
                    var nl: std.ArrayList(u32) = .empty;
                    try nl.appendSlice(A, &.{ v, mid.get(edgeKey(v, next)).?, cen, mid.get(edgeKey(prev, v)).? });
                    try out.append(A, nl);
                }
            }
            w.polys.items[p].deinit(A);
        } else {
            // a neighbour: its split edges get the midpoint
            var nl: std.ArrayList(u32) = .empty;
            for (l, 0..) |a, k| {
                try nl.append(A, a);
                if (mid.get(edgeKey(a, l[(k + 1) % l.len]))) |mi| try nl.append(A, mi);
            }
            w.polys.items[p].deinit(A);
            try out.append(A, nl);
        }
    }
    w.polys.deinit(A);
    w.polys = out;
    return w.commit("Subdivide") == null;
}

// --- dissolve ------------------------------------------------------------------

/// Merge each connected group of selected faces into one n-gon (its outline).
/// In vertex mode the faces round each selected vertex merge, the vertex goes.
pub fn dissolve() !?[]const u8 {
    var w = try begin();
    defer w.deinit();
    const np = w.polys.items.len;
    const group = try A.alloc(bool, np);
    defer A.free(group);
    switch (em.sel_mode) {
        .face, .edge => for (0..np) |p| {
            group[p] = w.faceSel(p);
        },
        .vertex => for (0..np) |p| {
            group[p] = false;
            for (w.polys.items[p].items) |v| {
                if (w.sel.items[v]) group[p] = true;
            }
        },
    }
    if (em.sel_mode == .edge) {
        // the two faces of each selected edge
        @memset(group, false);
        for (0..np) |p| {
            const l = w.polys.items[p].items;
            for (l, 0..) |a, k| {
                if (w.sel.items[a] and w.sel.items[l[(k + 1) % l.len]]) group[p] = true;
            }
        }
    }
    var counts = try regionEdgeCounts(&w, group);
    defer counts.deinit();
    // outline: directed boundary edges a -> b of the group
    var next = std.AutoHashMap(u32, u32).init(A);
    defer next.deinit();
    var n_bound: usize = 0;
    for (0..np) |p| {
        if (!group[p]) continue;
        const l = w.polys.items[p].items;
        for (l, 0..) |a, k| {
            const b = l[(k + 1) % l.len];
            if (counts.get(edgeKey(a, b)).? == 1) {
                if (next.contains(a)) return "The faces to dissolve touch at a corner";
                try next.put(a, b);
                n_bound += 1;
            }
        }
    }
    if (n_bound < 3) return "Nothing to dissolve";
    // remove the group, add one face per outline loop
    w.dropPolys(group[0..np]);
    var used = std.AutoHashMap(u32, void).init(A);
    defer used.deinit();
    var it = next.iterator();
    while (it.next()) |e| {
        const s0 = e.key_ptr.*;
        if (used.contains(s0)) continue;
        var loop: std.ArrayList(u32) = .empty;
        defer loop.deinit(A);
        var at = s0;
        var guard: usize = 0;
        while (guard <= n_bound) : (guard += 1) {
            try used.put(at, {});
            // vertex mode: the dissolved vertices leave the outline
            if (!(em.sel_mode == .vertex and w.sel.items[at])) try loop.append(A, at);
            at = next.get(at) orelse break;
            if (at == s0) break;
        }
        if (loop.items.len >= 3) try w.addPoly(loop.items);
    }
    if (em.sel_mode == .vertex) {
        const drop = try A.alloc(bool, w.verts.items.len);
        defer A.free(drop);
        @memcpy(drop, w.sel.items);
        try w.dropUnused(drop);
    }
    if (w.commit("Dissolve")) |why| return why;
    return null;
}

// --- tools that take a value from the mouse (inset, extrude individual) -------

pub const Tool = enum { inset, extrude_individual, bevel };

/// Bevel: rows of the strip (the wheel changes it).
pub var bevel_segments: u32 = 1;

pub var modal: ?Tool = null;
var base_mesh: ?u16 = null;
var base_sel: []bool = &.{};
var start_x: i32 = 0;
var value: f32 = 0;
var px_size: f32 = 0.01;
var typed: [24]u8 = undefined;
var typed_len: usize = 0;

pub fn start(t: Tool, mx: i32, pixel: f32) bool {
    if (!em.active or !em.anySelected()) return false;
    base_mesh = scene.objects[em.obj].mesh;
    base_sel = A.dupe(bool, em.sel) catch return false;
    modal = t;
    start_x = mx;
    px_size = @max(1e-5, pixel);
    typed_len = 0;
    value = 0;
    apply();
    return true;
}

fn run(t: Tool, v: f32) void {
    switch (t) {
        .inset => _ = inset(v) catch false,
        .extrude_individual => _ = extrudeIndividual(v) catch false,
        .bevel => _ = @import("meshops2.zig").bevel(v, bevel_segments) catch null,
    }
}

/// The mesh the last motion made (freed by the next: one per tool, not per motion).
var made: ?u16 = null;

fn dropMade() void {
    if (made) |mi| {
        if (mi != base_mesh and scene.objects[em.obj].mesh != mi) scene.freeMeshSlot(mi);
    }
    made = null;
}

fn apply() void {
    const t = modal orelse return;
    // from the mesh as it was, each time
    scene.objects[em.obj].mesh = base_mesh;
    dropMade();
    em.validate();
    @memcpy(em.sel[0..@min(em.sel.len, base_sel.len)], base_sel[0..@min(em.sel.len, base_sel.len)]);
    run(t, value);
    if (scene.objects[em.obj].mesh != base_mesh) made = scene.objects[em.obj].mesh;
}

pub fn motion(mx: i32) void {
    if (modal == null or typed_len > 0) return;
    value = @as(f32, @floatFromInt(mx - start_x)) * px_size;
    if (modal.? == .inset or modal.? == .bevel) value = @max(0, value);
    apply();
}

/// The wheel while a tool runs: bevel segments. True when it was used.
pub fn wheel(d: f32) bool {
    if (modal != .bevel) return false;
    const n: i32 = @as(i32, @intCast(bevel_segments)) + (if (d > 0) @as(i32, -1) else 1);
    bevel_segments = @intCast(std.math.clamp(n, 1, 32));
    apply();
    return true;
}

pub fn toolLabel() []const u8 {
    return switch (modal orelse return "") {
        .inset => "Inset",
        .extrude_individual => "Extrude",
        .bevel => "Bevel",
    };
}

pub fn describe(buf: []u8) []const u8 {
    const t = modal orelse return "";
    const what = switch (t) {
        .inset => "Inset thickness",
        .extrude_individual => "Extrude distance",
        .bevel => "Bevel width",
    };
    if (t == .bevel) {
        // as the original's line: "Bevel  0.3   segments 3"
        if (typed_len > 0) return std.fmt.bufPrint(buf, "Bevel  {s}|   segments {d}", .{ typed[0..typed_len], bevel_segments }) catch "";
        return std.fmt.bufPrint(buf, "Bevel  {d:.2}   segments {d}", .{ value, bevel_segments }) catch "";
    }
    if (typed_len > 0) return std.fmt.bufPrint(buf, "{s}: {s}|", .{ what, typed[0..typed_len] }) catch "";
    return std.fmt.bufPrint(buf, "{s}: {d:.3}", .{ what, value }) catch "";
}

/// A key while the tool runs: digits type the value; true when it was used.
pub fn key(cp: u32, code: u32) bool {
    if (modal == null) return false;
    if (code == 14) {
        typed_len -|= 1;
    } else if ((cp >= '0' and cp <= '9') or cp == '.' or cp == '-') {
        if (typed_len < typed.len) {
            typed[typed_len] = @intCast(cp);
            typed_len += 1;
        }
    } else return false;
    if (typed_len > 0) {
        value = std.fmt.parseFloat(f32, typed[0..typed_len]) catch value;
    }
    apply();
    return true;
}

pub fn confirm() void {
    const t = modal orelse return;
    // the redo panel: its values, from the mesh it began with
    {
        const redo = @import("redo.zig");
        const here = scene.objects[em.obj].mesh;
        scene.objects[em.obj].mesh = base_mesh;
        redo.before();
        scene.objects[em.obj].mesh = here;
        redo.takeSelection(base_sel);
        switch (t) {
            .inset => redo.set(.inset, &.{value}),
            .extrude_individual => redo.set(.extrude_individual, &.{value}),
            .bevel => redo.set(.bevel, &.{ value, @floatFromInt(bevel_segments) }),
        }
    }
    made = null;
    modal = null;
    if (base_sel.len > 0) A.free(base_sel);
    base_sel = &.{};
}

pub fn cancel() void {
    if (modal == null) return;
    scene.objects[em.obj].mesh = base_mesh;
    dropMade();
    em.validate();
    @memcpy(em.sel[0..@min(em.sel.len, base_sel.len)], base_sel[0..@min(em.sel.len, base_sel.len)]);
    em.version +%= 1;
    modal = null;
    if (base_sel.len > 0) A.free(base_sel);
    base_sel = &.{};
}
