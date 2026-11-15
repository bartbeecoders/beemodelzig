// Multiresolution (multires.s): sculpted detail kept as displacements over the
// subdivision levels of a base cage. A multires modifier (levels L, level k) shows
// level k of the stack's input subdivided (Catmull-Clark), each level j displaced
// after it is made: P_0 = base, P_j = S(P_j-1) + D_j.
//
// The displacements live on the object (Object.mres): a block shared with the undo
// steps as a mesh is (a mesh slot with positions and nothing else, never changed once
// made): D_1, D_2, ... one level after the other, with the base's vertex, polygon and
// loop counts (a base with other counts: no displacements).
//
// Sculpting at level k >= 1 works on a copy of P_k; a stroke adds its moves to D_k, in
// a new block, and the object takes it: the finer levels follow (S is linear; their
// own D_j stay on top), the coarser keep theirs. At level 0 the base itself is
// sculpted. Propagate down refits the coarser levels to the finest: every vertex keeps
// its number through the levels, so P_j takes the finest level's positions of its
// vertices and D_j becomes what makes that so. Applying the modifier keeps the level
// shown.
const std = @import("std");
const m = @import("math.zig");
const app = @import("app.zig");
const sc = @import("sculpt.zig");
const scene = @import("scene.zig");
const mods = @import("mods.zig");
const undo = @import("undo.zig");
const subsurf = @import("subsurf.zig");
const dyntopo = @import("dyntopo.zig");
const stroke = @import("stroke.zig");
const PMesh = @import("pmesh.zig").PMesh;
const A = @import("alloc.zig").A;

const V3 = m.V3;
const Mesh = scene.Mesh;
const Mod = scene.Mod;

// the modifier --------------------------------------------------------------------

/// mr_find: the object's first enabled modifier, when that is a multires one.
pub fn find(o: *const scene.Object) ?*const Mod {
    for (o.mods.m[0..o.mods.n]) |*d| {
        if (d.flags & 1 == 0) continue;
        return if (d.kind == mods.MULTIRES) d else null;
    }
    return null;
}

pub const Levels = struct { all: u32, k: u32 };

/// mr_levels: levels 1..6, the level shown 0..levels (cvttss2si: as stored).
pub fn levels(d: *const Mod) Levels {
    const l = @max(@min(stroke.trunc32(mods.getF(d, 0)), 6), 1);
    const k = @min(@max(stroke.trunc32(mods.getF(d, 1)), 0), l);
    return .{ .all = @intCast(l), .k = @intCast(k) };
}

/// The block's identity (what is shown hangs on it; slots are used again).
pub fn stamp(o: *const scene.Object) [2]u32 {
    const mi = o.mres orelse return .{ 0, 0 };
    return .{ @as(u32, mi) + 1, if (scene.meshes[mi]) |*b| b.serial else 0 };
}

fn counts(p: PMesh) [3]u32 {
    return .{ @intCast(p.verts.len), @intCast(p.poff.len -| 1), @intCast(p.loops.len) };
}

fn asP(me: *const Mesh) PMesh {
    return .{ .verts = me.verts, .poff = me.poff, .loops = me.loops };
}

/// mr_disp: its displacements when they were made on this topology.
fn disp(o: *const scene.Object, c: [3]u32) ?*const Mesh {
    const mi = o.mres orelse return null;
    const b = if (scene.meshes[mi]) |*x| x else return null;
    return if (std.mem.eql(u32, &b.db, &c)) b else null;
}

/// mr_prune: displacements made for another base go.
pub fn prune(oi: usize) void {
    const o = &scene.objects[oi];
    if (o.mres == null) return;
    const base = scene.meshOfObj(oi) orelse return;
    if (disp(o, counts(asP(base))) == null) o.mres = null;
}

/// mod_multires: the level this plan makes of `input`, displaced.
pub fn eval(oi: usize, input: PMesh, p: *subsurf.Plan) subsurf.Error!PMesh {
    const o = &scene.objects[oi];
    var mr = subsurf.Mr{};
    if (disp(o, counts(input))) |b| mr.disp = b.verts;
    const v = try A.alloc(V3, p.out_verts);
    errdefer A.free(v);
    try subsurf.evalMr(p, input.verts, v, &mr);
    const po = try A.dupe(u32, p.poff);
    errdefer A.free(po);
    return .{ .verts = v, .poff = po, .loops = try A.dupe(u32, p.loops) };
}

/// Positions only: what `o` shows when just the displacements moved.
pub fn evalInto(oi: usize, input: PMesh, p: *subsurf.Plan, out: []V3) subsurf.Error!void {
    var mr = subsurf.Mr{};
    if (disp(&scene.objects[oi], counts(input))) |b| mr.disp = b.verts;
    try subsurf.evalMr(p, input.verts, out, &mr);
}

// sculpting -----------------------------------------------------------------------

/// The sculpted copy of level k (positions and triangles: all a sculpt reads), and what
/// it was made from.
var copy: Mesh = undefined;
var have = false;
var kobj: u32 = 0;
var kbase: u32 = 0;
var kver: u32 = 0;
var klev: u32 = 0;
var kd: [2]u32 = .{ 0, 0 };
var mr_off: u32 = 0; // level k's displacements: where, how many, the end of them
var mr_n: u32 = 0;
var mr_end: u32 = 0;
var serials: u32 = 0;

fn dropCopy() void {
    if (!have) return;
    have = false;
    A.free(copy.verts);
    A.free(copy.tris);
}

/// mr_drop, leaving the mode.
pub fn drop() void {
    dropCopy();
}

fn makeCopy(i: usize, o: *const scene.Object, base: *const Mesh, k: u32) ?*Mesh {
    const p = mods.planOf(i, k) orelse return null; // (the plan what it shows uses)
    const v = A.alloc(V3, p.out_verts) catch return null;
    var mr = subsurf.Mr{};
    if (disp(o, counts(asP(base)))) |b| mr.disp = b.verts;
    subsurf.evalMr(p, base.verts, v, &mr) catch {
        A.free(v);
        return null;
    };
    // quads: two triangles each, as the fan
    const nq = p.loops.len / 4;
    const t = A.alloc([3]u32, nq * 2) catch {
        A.free(v);
        return null;
    };
    for (0..nq) |q| {
        const l = p.loops[q * 4 ..][0..4];
        t[q * 2] = .{ l[0], l[1], l[2] };
        t[q * 2 + 1] = .{ l[0], l[2], l[3] };
    }
    serials +%= 1;
    copy = .{ .verts = v, .poff = &.{}, .loops = &.{}, .tris = t, .tri_poly = &.{}, .edges = 0, .serial = serials | 0xc0000000 };
    have = true;
    kobj = o.oid;
    kbase = base.serial;
    kver = base.shape;
    klev = k;
    kd = stamp(o);
    mr_off = mr.off;
    mr_end = mr.total;
    mr_n = mr.total - mr.off;
    return &copy;
}

/// mr_target: what object i sculpts when not its mesh: with a multires modifier first
/// at level k >= 1 (and no dyntopo), a copy of level k (kept while object, base,
/// displacements and level stay).
pub fn target(i: usize) ?*Mesh {
    if (dyntopo.on) return null;
    const o = &scene.objects[i];
    const d = find(o) orelse return null;
    const k = levels(d).k;
    if (k == 0) return null;
    const base = scene.meshOfObj(i) orelse return null;
    if (have and kobj == o.oid and kbase == base.serial and kver == base.shape and klev == k and std.mem.eql(u32, &kd, &stamp(o))) return &copy;
    dropCopy();
    return makeCopy(i, o, base, k);
}

/// mr_owns: sculpt mode works on the copy.
pub fn owns() bool {
    return have and sc.mesh == @as(?*Mesh, &copy);
}

/// The level sculpted (the settings line).
pub fn level() u32 {
    return klev;
}

/// mr_stroke_end: a stroke on the copy: its moves (old positions in the stroke's
/// deltas, new ones in the copy) added to level k's displacements, in a new block the
/// object takes.
pub fn strokeEnd() void {
    const oi = scene.findOid(kobj) orelse return;
    const o = &scene.objects[oi];
    const base = scene.meshOfObj(oi) orelse return;
    const c = counts(asP(base));
    const old = disp(o, c);
    var n: usize = mr_end; // the block: at least up to level k
    if (old) |b| n = @max(n, b.verts.len);
    const mi = scene.addDisp(n, c) orelse return downMem();
    const nb = &scene.meshes[mi].?;
    if (old) |b| @memcpy(nb.verts[0..b.verts.len], b.verts); // the old ones (the rest: zero)
    const lev = nb.verts[mr_off..]; // + the moves, at level k
    const cnt = @min(sc.d_n.load(.monotonic), @as(u32, @intCast(sc.d_idx.len)));
    const p = sc.pos;
    for (sc.d_idx[0..cnt], sc.d_old[0..cnt]) |v, q| {
        if (v >= mr_n) continue;
        for (0..3) |w| lev[v][w] = p[v][w] - q[w] + lev[v][w];
    }
    o.mres = mi;
    kd = stamp(o); // (the copy is that, as sculpted)
}

// the operators -------------------------------------------------------------------

fn activeMesh() ?usize {
    const a = scene.active orelse return null;
    const o = &scene.objects[a];
    return if (o.mesh != null and o.kind.isMesh()) a else null;
}

/// Multires' Subdivide: one level more, shown.
pub fn subdivide(oi: usize, k: usize) void {
    const x = mods.getF(&scene.objects[oi].mods.m[k], 0) + 1; // levels + 1, and the level shown
    _ = mods.set(oi, k, "levels", x);
    _ = mods.set(oi, k, "level", x);
    undo.label("Modifiers");
    app.dirty = true;
}

fn need() void {
    app.toast(.warn, "multires: select a mesh with a multires modifier", .{});
}

fn downMem() void {
    app.toast(.warn, "multires: out of memory", .{});
}

/// multires.propagate_down: the coarser levels take the shape of the finest.
fn downJob(_: []const u8, _: usize, _: usize) void {
    const oi = activeMesh() orelse return need();
    const o = &scene.objects[oi];
    const d = find(o) orelse return need();
    const lv = levels(d).all;
    const base = scene.meshOfObj(oi) orelse return need();
    const pb = asP(base);
    const p = subsurf.plan(A, pb, lv) catch return downMem();
    defer subsurf.freePlan(A, p);
    // the finest level as it is
    var mr = subsurf.Mr{};
    const c = counts(pb);
    if (disp(o, c)) |b| mr.disp = b.verts;
    const fine = A.alloc(V3, p.out_verts) catch return downMem();
    defer A.free(fine);
    subsurf.evalMr(p, base.verts, fine, &mr) catch return downMem();
    // a new block for all levels: fit, level by level
    const mi = scene.addDisp(mr.total, c) orelse return downMem();
    const nb = &scene.meshes[mi].?;
    const out = A.alloc(V3, p.out_verts) catch return downMem();
    defer A.free(out);
    var fit = subsurf.Mr{ .fit = fine, .fit_out = nb.verts };
    subsurf.evalMr(p, base.verts, out, &fit) catch return downMem();
    undo.label("Propagate Down");
    o.mres = mi;
    app.toast(.ok, "multires: coarser levels follow the finest", .{});
}

pub fn opDown() void {
    @import("jobui.zig").later(downJob, "Propagating the levels", "", 0, 0);
}

// the file: MRES - per object with displacements: index, count, the base's vertices,
// polygons, loops, then the floats -------------------------------------------------

pub fn writeChunk(b: anytype) void {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        const mi = o.mres orelse continue;
        const me = &(scene.meshes[mi] orelse continue);
        b.u32_(@intCast(i));
        b.u32_(@intCast(me.verts.len));
        for (me.db) |x| b.u32_(x);
        b.bytes(std.mem.sliceAsBytes(me.verts));
    }
}

/// `ours`: the file's object -> ours.
pub fn readChunk(d: []const u8, ours: []const ?u16) void {
    var o: usize = 0;
    while (d.len - o >= 20) {
        const c = std.mem.readInt(u32, d[o + 4 ..][0..4], .little); // count
        if (c >= 0x8000000) return;
        const size = @as(usize, c) * 12 + 20;
        if (size > d.len - o) return;
        const idx = std.mem.readInt(u32, d[o..][0..4], .little);
        if (idx < ours.len) {
            if (ours[idx]) |i| {
                var db: [3]u32 = undefined;
                for (&db, 0..) |*x, k| x.* = std.mem.readInt(u32, d[o + 8 + k * 4 ..][0..4], .little);
                const mi = scene.addDisp(c, db) orelse return;
                @memcpy(std.mem.sliceAsBytes(scene.meshes[mi].?.verts), d[o + 20 ..][0 .. @as(usize, c) * 12]);
                scene.objects[i].mres = mi;
            }
        }
        o += size;
    }
}

test "the levels as stored: clamped, truncated, a NaN is the least" {
    var d = Mod{ .kind = mods.MULTIRES, .flags = 1 };
    mods.setF(&d, 0, 2);
    mods.setF(&d, 1, 6);
    try std.testing.expectEqual(Levels{ .all = 2, .k = 2 }, levels(&d));
    mods.setF(&d, 0, 9.5);
    mods.setF(&d, 1, 3.9);
    try std.testing.expectEqual(Levels{ .all = 6, .k = 3 }, levels(&d));
    mods.setF(&d, 0, std.math.nan(f32));
    mods.setF(&d, 1, std.math.nan(f32));
    try std.testing.expectEqual(Levels{ .all = 1, .k = 0 }, levels(&d));
    mods.setF(&d, 0, -3);
    mods.setF(&d, 1, -3);
    try std.testing.expectEqual(Levels{ .all = 1, .k = 0 }, levels(&d));
}
