// Edit mode, as in the original: Tab switches the active mesh between object
// mode and edit mode. 1 / 2 / 3 pick vertices, edges or faces; a click
// selects (Shift extends), A all / none, Ctrl+I inverts, B then a drag
// box-selects (Ctrl subtracts), Alt+click an edge loop, Ctrl+L linked parts.
// G / R / S move the selection; X deletes by select mode.
//
// Meshes are never changed in place: every edit builds a new mesh and the
// object points at it, so undo (whole-scene snapshots of the objects) keeps
// working and a primitive shared by many objects is never touched. The
// selection is per vertex (an edge is selected when both its vertices are,
// a face when all of them are).
const std = @import("std");
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const scene = @import("scene.zig");
const vp = @import("viewport.zig");
const ui = @import("ui.zig");
const undo = @import("undo.zig");

const Rect = gfx.Rect;
const A = @import("alloc.zig").A;

pub const SelMode = enum { vertex, edge, face };

pub var active: bool = false;
/// The object being edited.
pub var obj: usize = 0;
pub var sel_mode: SelMode = .vertex;
/// Per vertex of the object's current mesh.
pub var sel: []bool = &.{};
/// Bumped on every change of the mesh or the selection (the viewport's image cache).
pub var version: u32 = 0;
/// B was pressed: the next drag box-selects.
pub var box_armed: bool = false;

pub fn mesh() ?*const scene.Mesh {
    if (!active or obj >= scene.count) return null;
    return scene.meshOfObj(obj);
}

fn fitSel(n: usize) void {
    if (sel.len == n) return;
    const old = sel;
    sel = A.alloc(bool, n) catch &.{};
    @memset(sel, false);
    const k = @min(old.len, sel.len);
    @memcpy(sel[0..k], old[0..k]);
    if (old.len > 0) A.free(old);
}

/// Enter edit mode on the active object (it must have a mesh).
pub fn enter() ?[]const u8 {
    const a = scene.active orelse return "Select a mesh object first";
    if (scene.objects[a].mesh == null or !scene.objects[a].kind.isMesh()) return "The active object has no mesh";
    active = true;
    obj = a;
    oid = scene.objects[a].oid;
    const me = scene.meshOfObj(a).?;
    if (sel.len > 0) A.free(sel);
    sel = &.{};
    fitSel(me.verts.len);
    // the selection the mesh had when edit mode was left (a new one: all)
    if (me.vsel.len == me.verts.len) @memcpy(sel, me.vsel) else @memset(sel, true);
    version +%= 1;
    return null;
}

/// Keep the selection with the mesh (for the next Tab).
pub fn storeSel() void {
    if (obj >= scene.count or scene.objects[obj].oid != oid) return;
    const mi = scene.objects[obj].mesh orelse return;
    scene.setMeshSel(mi, sel);
}

pub fn exit() void {
    if (active) storeSel();
    active = false;
    box_armed = false;
    version +%= 1;
}

/// Called every frame: undo or a deleted object can change the mesh under us.
/// The edited object's identity: undo or a delete may move it to another index.
var oid: u32 = 0;

pub fn validate() void {
    if (!active) return;
    if (obj >= scene.count or scene.objects[obj].oid != oid) {
        if (scene.findOid(oid)) |i| {
            obj = i;
            version +%= 1;
        } else {
            exit();
            return;
        }
    }
    if (scene.objects[obj].mesh == null) {
        exit();
        return;
    }
    const me = scene.meshOfObj(obj) orelse return exit();
    if (sel.len != me.verts.len) {
        fitSel(me.verts.len);
        version +%= 1;
    }
}

// --- what is selected ---------------------------------------------------------

pub fn edgeSelected(e: [2]u32) bool {
    return e[0] < sel.len and e[1] < sel.len and sel[e[0]] and sel[e[1]];
}

pub fn faceSelected(me: *const scene.Mesh, p: usize) bool {
    const lo = me.loops[me.poff[p]..me.poff[p + 1]];
    if (lo.len == 0) return false;
    for (lo) |v| {
        if (v >= sel.len or !sel[v]) return false;
    }
    return true;
}

pub fn count() usize {
    var n: usize = 0;
    for (sel) |s| {
        if (s) n += 1;
    }
    return n;
}

pub fn anySelected() bool {
    for (sel) |s| {
        if (s) return true;
    }
    return false;
}

pub fn selectAll() void {
    @memset(sel, !anySelected());
    version +%= 1;
}

pub fn invert() void {
    for (sel) |*s| s.* = !s.*;
    version +%= 1;
}

/// Grow the selection over every part it touches.
pub fn selectLinked() void {
    const me = mesh() orelse return;
    var changed = true;
    while (changed) {
        changed = false;
        for (0..me.poff.len - 1) |p| {
            const lo = me.loops[me.poff[p]..me.poff[p + 1]];
            var any = false;
            var all = true;
            for (lo) |v| {
                if (sel[v]) any = true else all = false;
            }
            if (any and !all) {
                for (lo) |v| sel[v] = true;
                changed = true;
            }
        }
    }
    version +%= 1;
}

// --- picking ------------------------------------------------------------------

const Proj = struct { x: f32, y: f32, iz: f32, ok: bool };

fn project(c: *const vp.Cam, w: m.M4, p: m.V3) Proj {
    const v = c.toView(m.xform(w, p));
    if (v[2] < vp.near) return .{ .x = 0, .y = 0, .iz = 0, .ok = false };
    const s = c.screen(v);
    return .{ .x = s[0], .y = s[1], .iz = 1 / v[2], .ok = true };
}

/// Whether a point at this depth is in front of what the last frame drew there.
fn visible(cv: *gfx.Canvas, x: f32, y: f32, iz: f32, wire: bool) bool {
    if (wire) return true;
    const zb = cv.zbuf orelse return true;
    const xi: i32 = cv.toPx(@intFromFloat(x));
    const yi: i32 = cv.toPx(@intFromFloat(y));
    if (xi < 0 or yi < 0 or xi >= cv.w or yi >= cv.h) return false;
    // check a small neighbourhood: a vertex sits on the edge of its faces
    var best: f32 = 0;
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const px = std.math.clamp(xi + dx, 0, cv.w - 1);
            const py = std.math.clamp(yi + dy, 0, cv.h - 1);
            best = @max(best, zb[@intCast(py * cv.w + px)]);
        }
    }
    return iz * 1.01 >= best or best == 0;
}

pub const Hit = union(enum) { vertex: u32, edge: [2]u32, face: usize };

/// The element under (mx, my) for the select mode.
pub fn pick(cv: *gfx.Canvas, v: *const vp.View, r: Rect, mx: i32, my: i32) ?Hit {
    const me = mesh() orelse return null;
    const c = vp.Cam.init(v, r);
    const w = scene.world(obj);
    const fx: f32 = @floatFromInt(mx);
    const fy: f32 = @floatFromInt(my);
    switch (sel_mode) {
        .vertex => {
            var best: ?u32 = null;
            var bd: f32 = 14 * 14;
            for (me.verts, 0..) |p, i| {
                const s = project(&c, w, p);
                if (!s.ok) continue;
                const d = (s.x - fx) * (s.x - fx) + (s.y - fy) * (s.y - fy);
                if (d < bd and visible(cv, s.x, s.y, s.iz, v.wire)) {
                    bd = d;
                    best = @intCast(i);
                }
            }
            return if (best) |b| .{ .vertex = b } else null;
        },
        .edge => {
            var best: ?[2]u32 = null;
            var bd: f32 = 10 * 10;
            // every vertex once, then the edges
            const pr = A.alloc(Proj, me.verts.len) catch return null;
            defer A.free(pr);
            for (me.verts, 0..) |p, i| pr[i] = project(&c, w, p);
            for (me.edge_list) |e| {
                const a = pr[e[0]];
                const b = pr[e[1]];
                if (!a.ok or !b.ok) continue;
                // both ends far on one side of the pointer: not this one
                if ((a.x < fx - 10 and b.x < fx - 10) or (a.x > fx + 10 and b.x > fx + 10) or
                    (a.y < fy - 10 and b.y < fy - 10) or (a.y > fy + 10 and b.y > fy + 10)) continue;
                const ex = b.x - a.x;
                const ey = b.y - a.y;
                const l2 = ex * ex + ey * ey;
                const t = if (l2 < 1e-6) 0 else std.math.clamp(((fx - a.x) * ex + (fy - a.y) * ey) / l2, 0, 1);
                const px = a.x + ex * t;
                const py = a.y + ey * t;
                const d = (px - fx) * (px - fx) + (py - fy) * (py - fy);
                if (d < bd and visible(cv, px, py, a.iz + (b.iz - a.iz) * t, v.wire)) {
                    bd = d;
                    best = e;
                }
            }
            return if (best) |b| .{ .edge = b } else null;
        },
        .face => {
            // a ray through the pixel: the nearest triangle it hits
            const dir_w = m.norm(m.add(c.fwd, m.add(m.scale(c.right, (fx + 0.5 - c.cx) / c.f), m.scale(c.up, -(fy + 0.5 - c.cy) / c.f))));
            // the ray in the mesh's own space (distances along it keep their order)
            const inv = m.inverseAffine(w);
            const orig = m.xform(inv, c.eye);
            const dir = m.sub(m.xform(inv, m.add(c.eye, dir_w)), orig);
            if (!rayBox(orig, dir, me.lo, me.hi)) return null;
            var best: ?usize = null;
            var bt: f32 = std.math.inf(f32);
            for (me.tris, 0..) |t, ti| {
                const a = me.verts[t[0]];
                const b = me.verts[t[1]];
                const cc = me.verts[t[2]];
                if (rayTri(orig, dir, a, b, cc)) |d| {
                    if (d < bt) {
                        bt = d;
                        best = me.tri_poly[ti];
                    }
                }
            }
            return if (best) |b| .{ .face = b } else null;
        },
    }
}

/// Does the ray meet the box (slabs, a little margin)?
fn rayBox(o: m.V3, d: m.V3, lo: m.V3, hi: m.V3) bool {
    var t0: f32 = -std.math.inf(f32);
    var t1: f32 = std.math.inf(f32);
    for (0..3) |k| {
        const pad = (hi[k] - lo[k]) * 1e-3 + 1e-5;
        if (@abs(d[k]) < 1e-12) {
            if (o[k] < lo[k] - pad or o[k] > hi[k] + pad) return false;
            continue;
        }
        var a = (lo[k] - pad - o[k]) / d[k];
        var b = (hi[k] + pad - o[k]) / d[k];
        if (a > b) std.mem.swap(f32, &a, &b);
        t0 = @max(t0, a);
        t1 = @min(t1, b);
    }
    return t1 >= @max(t0, 0);
}

/// Möller-Trumbore: the distance along the ray, both sides.
fn rayTri(o: m.V3, d: m.V3, a: m.V3, b: m.V3, c: m.V3) ?f32 {
    const e1 = m.sub(b, a);
    const e2 = m.sub(c, a);
    const p = m.cross(d, e2);
    const det = m.dot(e1, p);
    if (@abs(det) < 1e-12) return null;
    const inv = 1 / det;
    const t0 = m.sub(o, a);
    const u = m.dot(t0, p) * inv;
    if (u < 0 or u > 1) return null;
    const q = m.cross(t0, e1);
    const v = m.dot(d, q) * inv;
    if (v < 0 or u + v > 1) return null;
    const t = m.dot(e2, q) * inv;
    return if (t > 1e-6) t else null;
}

/// A click: select what is under the pointer (Shift: toggle it, keep the rest).
pub fn click(cv: *gfx.Canvas, v: *const vp.View, r: Rect, mx: i32, my: i32, extend: bool) void {
    const me = mesh() orelse return;
    const h = pick(cv, v, r, mx, my);
    if (!extend) @memset(sel, false);
    if (h) |hit| {
        switch (hit) {
            .vertex => |i| sel[i] = if (extend) !sel[i] else true,
            .edge => |e| {
                const on = if (extend) !edgeSelected(e) else true;
                sel[e[0]] = on;
                sel[e[1]] = on;
            },
            .face => |p| {
                const on = if (extend) !faceSelected(me, p) else true;
                for (me.loops[me.poff[p]..me.poff[p + 1]]) |vi| sel[vi] = on;
            },
        }
    }
    version +%= 1;
}

/// Alt+click: the edge loop through the edge under the pointer (edges in
/// line through four-edged vertices, as far as they go).
pub fn clickLoop(cv: *gfx.Canvas, v: *const vp.View, r: Rect, mx: i32, my: i32, extend: bool) void {
    const me = mesh() orelse return;
    const saved = sel_mode;
    sel_mode = .edge;
    const h = pick(cv, v, r, mx, my);
    sel_mode = saved;
    const hit = h orelse return;
    const e0 = hit.edge;
    if (!extend) @memset(sel, false);
    sel[e0[0]] = true;
    sel[e0[1]] = true;
    const adj = adjOf(me) orelse return;
    walkLoop(me, adj, e0[0], e0[1]);
    walkLoop(me, adj, e0[1], e0[0]);
    version +%= 1;
}

/// Vertex -> edges and vertex -> polygons (compressed rows), for walking loops.
const Adj = struct {
    eoff: []u32,
    eadj: []u32, // the other vertex of each edge
    foff: []u32,
    fadj: []u32, // polygons
    fn init(me: *const scene.Mesh) !Adj {
        const nv = me.verts.len;
        const eoff = try A.alloc(u32, nv + 1);
        errdefer A.free(eoff);
        @memset(eoff, 0);
        for (me.edge_list) |e| {
            eoff[e[0] + 1] += 1;
            eoff[e[1] + 1] += 1;
        }
        for (1..nv + 1) |i| eoff[i] += eoff[i - 1];
        const eadj = try A.alloc(u32, eoff[nv]);
        errdefer A.free(eadj);
        const fill = try A.alloc(u32, nv);
        defer A.free(fill);
        @memcpy(fill, eoff[0..nv]);
        for (me.edge_list) |e| {
            eadj[fill[e[0]]] = e[1];
            fill[e[0]] += 1;
            eadj[fill[e[1]]] = e[0];
            fill[e[1]] += 1;
        }
        const foff = try A.alloc(u32, nv + 1);
        errdefer A.free(foff);
        @memset(foff, 0);
        for (me.loops) |x| foff[x + 1] += 1;
        for (1..nv + 1) |i| foff[i] += foff[i - 1];
        const fadj = try A.alloc(u32, foff[nv]);
        @memcpy(fill, foff[0..nv]);
        for (0..me.poff.len - 1) |p| {
            for (me.loops[me.poff[p]..me.poff[p + 1]]) |x| {
                fadj[fill[x]] = @intCast(p);
                fill[x] += 1;
            }
        }
        return .{ .eoff = eoff, .eadj = eadj, .foff = foff, .fadj = fadj };
    }
    fn deinit(a: *Adj) void {
        A.free(a.eoff);
        A.free(a.eadj);
        A.free(a.foff);
        A.free(a.fadj);
    }
};

/// The adjacency of the last mesh asked about (kept until the topology changes).
var adj_cache: ?Adj = null;
var adj_key: u32 = 0;

fn adjOf(me: *const scene.Mesh) ?*const Adj {
    const k = me.serial;
    if (adj_cache != null and k == adj_key) return &adj_cache.?;
    if (adj_cache) |*a| a.deinit();
    adj_cache = Adj.init(me) catch null;
    adj_key = k;
    return if (adj_cache) |*a| a else null;
}

/// Are edges from-at and at-x side by side in a polygon (from, at, x or
/// x, at, from in a row)? The original's `beside`.
fn beside(me: *const scene.Mesh, adj: *const Adj, from: u32, at: u32, x: u32) bool {
    for (adj.fadj[adj.foff[at]..adj.foff[at + 1]]) |p| {
        const lo = me.loops[me.poff[p]..me.poff[p + 1]];
        for (lo, 0..) |v, k| {
            if (v != at) continue;
            const pv = lo[(k + lo.len - 1) % lo.len];
            const nx = lo[(k + 1) % lo.len];
            if ((pv == from and nx == x) or (pv == x and nx == from)) return true;
        }
    }
    return false;
}

fn walkLoop(me: *const scene.Mesh, adj: *const Adj, from0: u32, at0: u32) void {
    var from = from0;
    var at = at0;
    var steps: usize = 0;
    while (steps < me.verts.len) : (steps += 1) {
        // the edges at `at`: a loop goes on through four-edged vertices only
        const nb = adj.eadj[adj.eoff[at]..adj.eoff[at + 1]];
        if (nb.len != 4) return;
        // the one edge not beside this one (two: no clear way on, stop)
        var next: ?u32 = null;
        var n_next: usize = 0;
        for (nb) |x| {
            if (x == from) continue;
            if (!beside(me, adj, from, at, x)) {
                next = x;
                n_next += 1;
            }
        }
        if (n_next != 1) return;
        const nx = next orelse return;
        if (sel[nx] and nx == from0) return; // round
        sel[nx] = true;
        from = at;
        at = nx;
        if (at == at0) return;
    }
}

/// Box select: every vertex (edge, face) inside the rectangle; Ctrl subtracts.
pub fn boxSelect(cv: *gfx.Canvas, v: *const vp.View, r: Rect, box: Rect, subtract: bool) void {
    const me = mesh() orelse return;
    const c = vp.Cam.init(v, r);
    const w = scene.world(obj);
    var inside = A.alloc(bool, me.verts.len) catch return;
    defer A.free(inside);
    for (me.verts, 0..) |p, i| {
        const s = project(&c, w, p);
        inside[i] = s.ok and box.contains(@intFromFloat(s.x), @intFromFloat(s.y)) and visible(cv, s.x, s.y, s.iz, v.wire);
    }
    switch (sel_mode) {
        .vertex => for (inside, 0..) |in, i| {
            if (in) sel[i] = !subtract;
        },
        .edge => for (me.edge_list) |e| {
            if (inside[e[0]] and inside[e[1]]) {
                sel[e[0]] = !subtract;
                sel[e[1]] = !subtract;
            }
        },
        .face => for (0..me.poff.len - 1) |p| {
            const lo = me.loops[me.poff[p]..me.poff[p + 1]];
            var all = lo.len > 0;
            for (lo) |x| {
                if (!inside[x]) all = false;
            }
            if (all) {
                for (lo) |x| sel[x] = !subtract;
            }
        },
    }
    version +%= 1;
}

// --- editing --------------------------------------------------------------------

/// Replace the edited object's mesh with a new one (an undo step).
pub fn commit(verts: []const m.V3, poff: []const u32, loops: []const u32, new_sel: ?[]const bool, label: []const u8) bool {
    const mi = scene.addMesh(verts, poff, loops) orelse return false;
    if (scene.objects[obj].mesh) |old| {
        if (scene.meshes[old]) |*om| scene.keepUvs(mi, om);
    }
    scene.objects[obj].mesh = mi;
    fitSel(verts.len);
    if (new_sel) |ns| {
        @memcpy(sel[0..@min(ns.len, sel.len)], ns[0..@min(ns.len, sel.len)]);
    }
    undo.label(label);
    version +%= 1;
    return true;
}

/// Delete by select mode: vertices (and their faces), the faces of the
/// selected edges, or the selected faces (and vertices left with none).
pub fn delete() ?[]const u8 {
    const me = mesh() orelse return "Not in edit mode";
    if (!anySelected()) return "Nothing is selected";
    const np = me.poff.len - 1;
    const keep_poly = A.alloc(bool, np) catch return "Out of memory";
    defer A.free(keep_poly);
    for (0..np) |p| {
        const lo = me.loops[me.poff[p]..me.poff[p + 1]];
        keep_poly[p] = switch (sel_mode) {
            .vertex => blk: {
                for (lo) |x| {
                    if (sel[x]) break :blk false;
                }
                break :blk true;
            },
            .edge => blk: {
                for (lo, 0..) |x, k| {
                    const y = lo[(k + 1) % lo.len];
                    if (sel[x] and sel[y]) break :blk false;
                }
                break :blk true;
            },
            .face => !faceSelected(me, p),
        };
    }
    // vertices: the deleted ones go; with faces, the ones left with no face too
    const keep_v = A.alloc(bool, me.verts.len) catch return "Out of memory";
    defer A.free(keep_v);
    switch (sel_mode) {
        .vertex => for (keep_v, 0..) |*k, i| {
            k.* = !sel[i];
        },
        else => {
            @memset(keep_v, false);
            for (0..np) |p| {
                if (!keep_poly[p]) continue;
                for (me.loops[me.poff[p]..me.poff[p + 1]]) |x| keep_v[x] = true;
            }
            for (keep_v, 0..) |*k, i| {
                if (!sel[i]) k.* = true; // unselected loose vertices stay
            }
        },
    }
    return rebuild(me, keep_v, keep_poly, "Delete");
}

/// A mesh of the kept vertices and polygons (renumbered).
fn rebuild(me: *const scene.Mesh, keep_v: []const bool, keep_poly: []const bool, label: []const u8) ?[]const u8 {
    const remap = A.alloc(u32, me.verts.len) catch return "Out of memory";
    defer A.free(remap);
    var verts: std.ArrayList(m.V3) = .empty;
    defer verts.deinit(A);
    var ns: std.ArrayList(bool) = .empty;
    defer ns.deinit(A);
    for (me.verts, 0..) |p, i| {
        if (keep_v[i]) {
            remap[i] = @intCast(verts.items.len);
            verts.append(A, p) catch return "Out of memory";
            ns.append(A, sel[i]) catch return "Out of memory";
        } else remap[i] = std.math.maxInt(u32);
    }
    var poff: std.ArrayList(u32) = .empty;
    defer poff.deinit(A);
    var loops: std.ArrayList(u32) = .empty;
    defer loops.deinit(A);
    poff.append(A, 0) catch return "Out of memory";
    for (0..me.poff.len - 1) |p| {
        if (!keep_poly[p]) continue;
        const start = loops.items.len;
        var ok = true;
        for (me.loops[me.poff[p]..me.poff[p + 1]]) |x| {
            if (remap[x] == std.math.maxInt(u32)) ok = false;
            loops.append(A, remap[x]) catch return "Out of memory";
        }
        if (!ok) {
            loops.shrinkRetainingCapacity(start);
            continue;
        }
        poff.append(A, @intCast(loops.items.len)) catch return "Out of memory";
    }
    if (verts.items.len == 0) return "That would leave nothing (delete the object instead)";
    if (!commit(verts.items, poff.items, loops.items, ns.items, label)) return "The mesh could not be made";
    return null;
}

// --- moving vertices (G / R / S): a working copy ------------------------------

var work: ?u16 = null;
var before: ?u16 = null;

/// Start moving vertices: the object gets a copy of its mesh to change.
pub fn beginMove() bool {
    if (mesh() == null) return false;
    if (!anySelected()) return false;
    moving.clearRetainingCapacity();
    for (sel, 0..) |on, i| {
        if (on) moving.append(A, @intCast(i)) catch return false;
    }
    // same topology: copy the arrays, change only the vertices
    const mi = scene.cloneMesh(scene.objects[obj].mesh.?) orelse return false;
    before = scene.objects[obj].mesh;
    work = mi;
    scene.objects[obj].mesh = mi;
    return true;
}

var moving: std.ArrayList(u32) = .empty;

/// The vertices being moved (selected when the move began).
pub fn movingVerts() []const u32 {
    return moving.items;
}

/// After the working copy changed: new bounds, a new image.
pub fn moved() void {
    if (work) |mi| scene.refreshMesh(mi);
    version +%= 1;
}

/// The working copy's vertices (changed in place while moving).
pub fn workVerts() []m.V3 {
    const mi = work orelse return &.{};
    return scene.meshes[mi].?.verts;
}

pub fn originalVerts() []const m.V3 {
    const mi = before orelse return &.{};
    return (scene.meshes[mi] orelse return &.{}).verts;
}

pub fn endMove(ok: bool, label: []const u8) void {
    const mi = work orelse return;
    if (ok) {
        scene.refreshMesh(mi);
        undo.label(label);
    } else if (before) |b| {
        scene.objects[obj].mesh = b;
        scene.freeMeshSlot(mi);
    }
    work = null;
    before = null;
    version +%= 1;
}
