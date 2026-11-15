// The modifier stack (mods.s): non-destructive operations per object. A stack
// is up to 8 records of 48 bytes in the object, as in the file. of() gives what
// is drawn, rendered and exported: the base mesh run through the enabled
// modifiers, cached by object until the mesh, the stack or what the stack reads
// changes. A modifier that fails passes its input on and shows so in its panel.
//
// A Geometry Nodes modifier runs its node tree (geonodes.zig) on the mesh below
// it; what it makes may carry instances and point normals (inst.zig), which the
// entry keeps beside its mesh: a later modifier that makes a new mesh drops them
// (as the original's mesh_new), an Armature keeps them (mesh_copy). A Logic
// modifier names a logic graph (logic.zig) and makes no geometry.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const preview = @import("preview.zig");
const kern = @import("modkern.zig");
const subsurf = @import("subsurf.zig");
const boolean = @import("boolean.zig");
const multires = @import("multires.zig");
const PMesh = @import("pmesh.zig").PMesh;
const shape = @import("shape.zig");
const arm = @import("arm.zig");
const gn = @import("geonodes.zig");
const inst = @import("inst.zig");
const nt = @import("ntree.zig");
const A = @import("alloc.zig").A;
const Mesh = scene.Mesh;
const Mod = scene.Mod;

pub const MIRROR = 1;
pub const ARRAY = 2;
pub const SOLIDIFY = 3;
pub const SUBSURF = 4;
pub const BEVEL = 5;
pub const DECIMATE = 6;
pub const REMESH = 7;
pub const BOOLEAN = 8;
pub const MULTIRES = 9;
pub const GEONODES = 10;
pub const ARMATURE = 11;
pub const LOGIC = 12;
pub const COUNT = 13;

pub const Param = struct {
    name: []const u8,
    int: bool = false,
    object: bool = false,
    step: f32 = 1,
    lo: f32 = 0,
    hi: f32 = 0,
    def: f32 = 0,
};

const none = [_]Param{};
const p_mirror = [_]Param{ .{ .name = "axis", .int = true, .lo = 0, .hi = 2 }, .{ .name = "merge", .step = 0.001, .lo = 0, .hi = 10, .def = 0.001 } };
const p_array = [_]Param{
    .{ .name = "count", .int = true, .lo = 1, .hi = 1000, .def = 2 }, .{ .name = "x", .step = 0.01, .lo = -100, .hi = 100, .def = 1 },
    .{ .name = "y", .step = 0.01, .lo = -100, .hi = 100 },            .{ .name = "z", .step = 0.01, .lo = -100, .hi = 100 },
};
const p_solidify = [_]Param{.{ .name = "thickness", .step = 0.005, .lo = -100, .hi = 100, .def = 0.1 }};
const p_subsurf = [_]Param{.{ .name = "levels", .int = true, .lo = 0, .hi = 6, .def = 2 }};
const p_bevel = [_]Param{ .{ .name = "width", .step = 0.005, .lo = 0, .hi = 100, .def = 0.1 }, .{ .name = "segments", .int = true, .lo = 1, .hi = 32, .def = 1 }, .{ .name = "angle", .lo = 0, .hi = 180, .def = 30 } };
const p_decimate = [_]Param{.{ .name = "ratio", .step = 0.01, .lo = 0.01, .hi = 1, .def = 0.5 }};
const p_remesh = [_]Param{.{ .name = "voxel", .step = 0.01, .lo = 0.01, .hi = 100, .def = 0.1 }};
const p_boolean = [_]Param{ .{ .name = "object", .object = true }, .{ .name = "operation", .int = true, .lo = 0, .hi = 2, .def = 1 } };
const p_multires = [_]Param{ .{ .name = "levels", .int = true, .lo = 1, .hi = 6, .def = 2 }, .{ .name = "level", .int = true, .lo = 0, .hi = 6, .def = 6 } };
/// a Geometry Nodes modifier's tree: its place + 1 (0: none; mp_geonodes)
const p_geonodes = [_]Param{.{ .name = "tree", .int = true, .lo = 0, .hi = 64 }};
/// a Logic modifier's graph: its place + 1 (0: none; mp_logic)
const p_logic = [_]Param{.{ .name = "tree", .int = true, .lo = 0, .hi = 64 }};
const p_armature = [_]Param{ .{ .name = "object", .object = true }, .{ .name = "mode", .int = true, .lo = 0, .hi = 1 } };

pub const names = [COUNT][]const u8{ "?", "Mirror", "Array", "Solidify", "Subsurf", "Bevel", "Decimate", "Remesh", "Boolean", "Multires", "Geo Nodes", "Armature", "Logic" };
const keys = [COUNT][]const u8{ "", "mirror", "array", "solidify", "subsurf", "bevel", "decimate", "remesh", "boolean", "multires", "geometry", "armature", "logic" };
pub const op_names = [3][]const u8{ "Union", "Difference", "Intersect" };
pub const arm_modes = [2][]const u8{ "Linear blend", "Dual quaternion" };

pub fn params(t: u32) []const Param {
    return switch (t) {
        MIRROR => &p_mirror,
        ARRAY => &p_array,
        SOLIDIFY => &p_solidify,
        SUBSURF => &p_subsurf,
        BEVEL => &p_bevel,
        DECIMATE => &p_decimate,
        REMESH => &p_remesh,
        BOOLEAN => &p_boolean,
        MULTIRES => &p_multires,
        ARMATURE => &p_armature,
        GEONODES => &p_geonodes,
        LOGIC => &p_logic,
        else => &none,
    };
}

pub fn ported(t: u32) bool {
    return (t >= MIRROR and t <= MULTIRES) or t == GEONODES or t == ARMATURE or t == LOGIC;
}

pub fn getF(d: *const Mod, k: usize) f32 {
    return @bitCast(d.p[k]);
}
pub fn setF(d: *Mod, k: usize, v: f32) void {
    d.p[k] = @bitCast(v);
}
fn clamped(t: u32, d: *const Mod, k: usize) f32 {
    const p = params(t)[k];
    const v = getF(d, k);
    if (!std.math.isFinite(v)) return p.def;
    return std.math.clamp(if (p.int) @round(v) else v, p.lo, p.hi);
}
fn int(t: u32, d: *const Mod, k: usize) u32 {
    return @intFromFloat(@max(clamped(t, d, k), 0));
}

/// The object an entry reads (a boolean's), by index.
pub fn target(d: *const Mod) ?usize {
    if ((d.kind != BOOLEAN and d.kind != ARMATURE) or d.p[0] == 0) return null;
    return scene.findOid(d.p[0]);
}

fn on(o: *const scene.Object) bool {
    for (o.mods.m[0..o.mods.n]) |*d| {
        if (d.flags & 1 != 0 and ported(d.kind) and d.kind != LOGIC) return true; // (mods_on: a logic graph makes no geometry)
    }
    return false;
}

// --- the cache -------------------------------------------------------------------------

const Entry = struct {
    serial: u32 = 0,
    shape: u32 = 0,
    key: u64 = 0,
    valid: bool = false,
    visiting: bool = false,
    bad: u8 = 0, // the modifiers that failed
    mix_only: bool = false, // shape keys and no modifiers: rewritten in place
    deform_only: bool = false, // Armature modifiers alone: the same polygons
    colours_at: u32 = 0, // the base's vertex colours it carries (Mesh.paints)
    mesh: ?Mesh = null, // null: the base mesh shows (every modifier failed)
    kept: preview.Kept = .{},
    plan: ?*subsurf.Plan = null,
    plan_serial: u32 = 0,
    plan_levels: u32 = 0,
    /// what the stack's geometry nodes left on the mesh: instances, point normals
    extra: Extra = .{},
};

/// The parts of the original's mesh the port's mesh has not: instances (a
/// reference) and point normals (owned).
pub const Extra = struct {
    inst: ?*inst.Block = null,
    pnrm: []m.V3 = &.{},
    /// its triangles as the original has them (a node that copies a mesh keeps
    /// the source's, made where its corners were: mesh_copy); empty: made anew
    tris: [][3]u32 = &.{},
    pub fn clear(x: *Extra) void {
        inst.unref(x.inst);
        x.inst = null;
        if (x.pnrm.len > 0) A.free(x.pnrm);
        x.pnrm = &.{};
        if (x.tris.len > 0) A.free(x.tris);
        x.tris = &.{};
    }
};

var cache: std.AutoHashMapUnmanaged(u32, *Entry) = .empty;
var serials: u32 = 0x80000000;

fn drop(e: *Entry) void {
    if (e.mesh) |*me| scene.freeMesh(me);
    e.mesh = null;
    preview.freeKept(&e.kept);
    if (e.plan) |p| subsurf.freePlan(A, p);
    e.plan = null;
    e.extra.clear();
}

fn prune() void {
    if (cache.count() < 2 * scene.count + 32) return;
    var it = cache.iterator();
    var dead: [64]u32 = undefined;
    var n: usize = 0;
    while (it.next()) |kv| {
        if (n == dead.len) break;
        const i = scene.findOid(kv.key_ptr.*);
        if (i == null or !on(&scene.objects[i.?])) {
            dead[n] = kv.key_ptr.*;
            n += 1;
        }
    }
    for (dead[0..n]) |oid| {
        const e = cache.get(oid).?;
        drop(e);
        A.destroy(e);
        _ = cache.remove(oid);
    }
}

/// Does what `from` shows depend on `to`? Two booleans reading each other:
/// each reads the other's base mesh, whichever is evaluated first.
fn reaches(from: usize, to: usize, depth: u32) bool {
    if (depth > 16) return true;
    const o = &scene.objects[from];
    for (o.mods.m[0..o.mods.n]) |*d| {
        if (d.flags & 1 == 0) continue;
        if (d.kind == ARMATURE) continue; // (bones read no mesh)
        const ti = target(d) orelse continue;
        if (ti == to or reaches(ti, to, depth + 1)) return true;
    }
    return false;
}

fn shown(oi: usize, ti: usize) ?*const Mesh {
    return if (reaches(ti, oi, 0)) scene.meshOfObj(ti) else of(ti);
}

/// How `other` sits in the frame of object oi.
fn relative(oi: usize, other: usize) m.M4 {
    return m.mul(m.inverseAffine(scene.world(oi)), scene.world(other));
}

/// Everything the result depends on but the base mesh.
fn stackKey(oi: usize) u64 {
    const o = &scene.objects[oi];
    var h = std.hash.Wyhash.init(0x6d6f6473);
    if (scene.meshOfObj(oi)) |me| shape.hashValues(&h, me);
    h.update(std.mem.sliceAsBytes(o.mods.m[0..o.mods.n]));
    h.update(std.mem.asBytes(&multires.stamp(o))); // (its displacements)
    for (o.mods.m[0..o.mods.n]) |*d| {
        if (d.kind == GEONODES) { // (geometry nodes: the trees' version)
            h.update(std.mem.asBytes(&nt.ver));
            break;
        }
    }
    for (o.mods.m[0..o.mods.n]) |*d| {
        const ti = target(d) orelse continue;
        if (ti == oi) continue;
        if (shown(oi, ti)) |me| {
            h.update(std.mem.asBytes(&me.serial));
            h.update(std.mem.asBytes(&me.shape));
        }
        const r = relative(oi, ti);
        h.update(std.mem.asBytes(&r));
    }
    return h.final();
}

fn asP(me: *const Mesh) PMesh {
    return .{ .verts = me.verts, .poff = me.poff, .loops = me.loops };
}

fn booleanStep(oi: usize, d: *const Mod, input: PMesh) !?PMesh {
    const ti = target(d) orelse return null; // none picked: as it is
    if (ti == oi) return null;
    const op: boolean.Op = @enumFromInt(int(BOOLEAN, d, 1));
    return try booleanWith(oi, ti, input, op);
}

pub const BakeResult = enum { ok, failed, emptied };

/// Edit > Boolean: the active object's shape, combined with the other's, becomes its mesh.
pub fn bakeBoolean(oi: usize, other: usize, op: boolean.Op) BakeResult {
    const me = of(oi) orelse return .failed;
    const r = (booleanWith(oi, other, asP(me), op) catch return .failed) orelse return .failed;
    defer r.deinit(A);
    if (r.verts.len == 0) return .emptied;
    scene.objects[oi].mesh = scene.addMesh(r.verts, r.poff, r.loops) orelse return .failed;
    scene.objects[oi].mods = .{};
    return .ok;
}

fn booleanWith(oi: usize, ti: usize, input: PMesh, op: boolean.Op) !?PMesh {
    const om = shown(oi, ti) orelse return null;
    var y = try asP(om).clone(A);
    defer y.deinit(A);
    const r = relative(oi, ti);
    for (y.verts) |*v| v.* = m.xform(r, v.*);
    // a mirrored object: its faces turn inside out
    const ax: m.V3 = .{ r[0], r[4], r[8] };
    const ay: m.V3 = .{ r[1], r[5], r[9] };
    const az: m.V3 = .{ r[2], r[6], r[10] };
    if (m.dot(ax, m.cross(ay, az)) < 0) {
        for (0..y.faces()) |f| std.mem.reverse(u32, y.loops[y.poff[f]..y.poff[f + 1]]);
    }
    return try boolean.run(A, input, y, op);
}

/// Do the enabled modifiers only move vertices?
fn deformOnly(o: *const scene.Object) bool {
    var any = false;
    for (o.mods.m[0..o.mods.n]) |*d| {
        if (d.flags & 1 == 0 or !ported(d.kind) or d.kind == LOGIC) continue;
        if (d.kind != ARMATURE) return false;
        any = true;
    }
    return any;
}

/// The entry's plan for these levels of this base.
fn planIn(e: *Entry, input: PMesh, serial: u32, k: u32) !*subsurf.Plan {
    if (e.plan == null or e.plan_serial != serial or e.plan_levels != k) {
        if (e.plan) |p| subsurf.freePlan(A, p);
        e.plan = null;
        e.plan = try subsurf.plan(A, input, k);
        e.plan_serial = serial;
        e.plan_levels = k;
    }
    return e.plan.?;
}

/// Object oi's plan for k levels of its base (multires shares it with what it shows):
/// the caller's until the next evaluation.
pub fn planOf(oi: usize, k: u32) ?*subsurf.Plan {
    const base = scene.meshOfObj(oi) orelse return null;
    const e = entryOf(oi) orelse return null;
    return planIn(e, asP(base), base.serial, k) catch null;
}

/// The level, when a multires modifier is all the stack does (0: not so).
fn multiresOnly(o: *const scene.Object) u32 {
    var k: u32 = 0;
    for (o.mods.m[0..o.mods.n]) |*d| {
        if (d.flags & 1 == 0 or !ported(d.kind)) continue;
        if (d.kind != MULTIRES or k != 0) return 0;
        k = multires.levels(d).k;
        if (k == 0) return 0;
    }
    return k;
}

fn step(oi: usize, d: *const Mod, input: PMesh, e: ?*Entry, base: ?*const Mesh) !?PMesh {
    return switch (d.kind) {
        MIRROR => try kern.mirror(A, input, int(MIRROR, d, 0), clamped(MIRROR, d, 1)),
        ARRAY => try kern.array(A, input, int(ARRAY, d, 0), clamped(ARRAY, d, 1), clamped(ARRAY, d, 2), clamped(ARRAY, d, 3)),
        SOLIDIFY => try kern.solidify(A, input, clamped(SOLIDIFY, d, 0)),
        SUBSURF => blk: {
            const lv = int(SUBSURF, d, 0);
            if (lv == 0) break :blk null;
            // straight on the base mesh: keep the plan, vertices moving is the common edit
            if (e != null and base != null) {
                const en = e.?;
                if (en.plan == null or en.plan_serial != base.?.serial or en.plan_levels != lv) {
                    if (en.plan) |p| subsurf.freePlan(A, p);
                    en.plan = null;
                    en.plan = try subsurf.plan(A, input, lv);
                    en.plan_serial = base.?.serial;
                    en.plan_levels = lv;
                }
                break :blk try subsurf.eval(en.plan.?, A, input.verts);
            }
            break :blk try subsurf.subdivide(A, input, lv);
        },
        BEVEL => try kern.bevel(A, input, clamped(BEVEL, d, 0), int(BEVEL, d, 1), clamped(BEVEL, d, 2)),
        DECIMATE => try kern.decimate(A, input, clamped(DECIMATE, d, 0)),
        REMESH => try kern.remesh(A, input, clamped(REMESH, d, 0)),
        BOOLEAN => try booleanStep(oi, d, input),
        MULTIRES => blk: {
            const k = multires.levels(d).k;
            if (k == 0) break :blk null; // (level 0: the mesh as it is)
            if (e != null and base != null) break :blk try multires.eval(oi, input, try planIn(e.?, input, base.?.serial, k));
            const p = try subsurf.plan(A, input, k);
            defer subsurf.freePlan(A, p);
            break :blk try multires.eval(oi, input, p);
        },
        else => null,
    };
}

/// A Geometry Nodes modifier (mod_geonodes): its tree's result on the mesh so
/// far, or null (no tree, a logic graph, nothing made, or the mesh itself);
/// `ex` follows what it made.
fn geoStep(d: *const Mod, input: PMesh, ex: *Extra) !?PMesh {
    const t1 = nt.cvtt(getF(d, 0));
    if (t1 <= 0 or t1 > nt.TR_MAX) return null;
    if (@import("logic.zig").isLogic(@intCast(t1 - 1))) return null; // (a logic graph: no geometry)
    const g = gn.geoCopyP(input) orelse return error.OutOfMemory;
    defer gn.unref(g);
    g.inst = ex.inst;
    inst.ref(g.inst);
    if (ex.pnrm.len == input.verts.len and ex.pnrm.len > 0) g.pnrm = try A.dupe(m.V3, ex.pnrm);
    const r = gn.eval(g, @intCast(t1)) orelse return null;
    defer gn.unref(r);
    const out = try r.view().clone(A);
    errdefer out.deinit(A);
    const pn: []m.V3 = if (r.pnrm.len > 0) try A.dupe(m.V3, r.pnrm) else &.{};
    const tr = gn.trisOf(r);
    const tc: [][3]u32 = if (tr.len > 0) (A.dupe([3]u32, tr) catch &.{}) else &.{};
    ex.clear();
    ex.pnrm = pn;
    ex.tris = tc;
    ex.inst = r.inst;
    inst.ref(ex.inst);
    return out;
}

/// Run entries 0..end on the base mesh. Null: the base mesh as it is.
/// `ex`: what geometry nodes left on the result (instances, point normals).
fn run(oi: usize, end: usize, e: ?*Entry, bad: *u8, ex: *Extra) ?PMesh {
    const o = &scene.objects[oi];
    const base = scene.meshOfObj(oi) orelse return null;
    var cur: PMesh = asP(base);
    var owned = false;
    // (what came out of another modifier has no weights: the Armature passes it on)
    var skinnable = true;
    bad.* = 0;
    // shape keys first (the modifiers work on the mixed vertices)
    const mixed: ?[]m.V3 = if (shape.active(base)) (A.dupe(m.V3, base.verts) catch null) else null;
    defer if (mixed) |x| A.free(x);
    if (mixed) |x| {
        shape.mix(base, x);
        cur.verts = x;
    }
    for (o.mods.m[0..end], 0..) |*d, k| {
        if (d.flags & 1 == 0 or !ported(d.kind) or d.kind == LOGIC) continue;
        if (d.kind == ARMATURE) {
            if (!skinnable or base.wgt.len != cur.verts.len) continue;
            if (!owned) {
                const c = cur.clone(A) catch {
                    bad.* |= @as(u8, 1) << @intCast(k);
                    continue;
                };
                cur = c;
                owned = true;
            }
            _ = arm.skin(oi, d.p[0], getF(d, 1), base, cur.verts, cur.verts);
            continue;
        }
        if (d.kind == GEONODES) {
            const r = geoStep(d, cur, ex) catch {
                bad.* |= @as(u8, 1) << @intCast(k);
                continue;
            };
            if (r) |nx| {
                if (owned) cur.deinit(A);
                cur = nx;
                owned = true;
                skinnable = false;
            }
            continue;
        }
        const r = step(oi, d, cur, e, if (skinnable) base else null) catch {
            bad.* |= @as(u8, 1) << @intCast(k);
            continue;
        };
        if (r) |nx| {
            if (owned) cur.deinit(A);
            cur = nx;
            owned = true;
            skinnable = false;
            ex.clear(); // (a new mesh: no instances, no point normals)
        }
    }
    if (!owned and mixed != null) return cur.clone(A) catch null;
    return if (owned) cur else null;
}

fn entryOf(oi: usize) ?*Entry {
    const oid = scene.objects[oi].oid;
    if (cache.get(oid)) |e| return e;
    prune();
    const e = A.create(Entry) catch return null;
    e.* = .{};
    cache.put(A, oid, e) catch {
        A.destroy(e);
        return null;
    };
    return e;
}

/// What object oi shows: its evaluated mesh, else the base; null: it has none.
pub fn of(oi: usize) ?*const Mesh {
    const o = &scene.objects[oi];
    if (o.kind.isMesh()) if (@import("cloth.zig").meshOf(oi)) |cm| return cm; // (simulated cloth: its mesh)
    if (o.kind.isMesh()) if (@import("partsurf.zig").shown(oi)) |sm| return sm; // (a liquid's surface: particles)
    const base = scene.meshOfObj(oi) orelse return null;
    const sk_on = shape.active(base);
    if (!o.kind.isMesh() or (!on(o) and !sk_on)) return base;
    const e = entryOf(oi) orelse return base;
    if (e.visiting) return base; // (two booleans reading each other)
    e.visiting = true;
    defer e.visiting = false;
    const key = stackKey(oi);
    if (e.valid and e.serial == base.serial and e.shape == base.shape and e.key == key) {
        if (e.mesh) |*me| {
            colours(me, base, e);
            return me;
        }
        return base;
    }
    // bones alone, as before: the same polygons, only the vertices move
    if (e.valid and e.serial == base.serial and e.deform_only and deformOnly(o)) {
        if (e.mesh) |*me| {
            if (me.verts.len == base.verts.len and base.wgt.len == base.verts.len) {
                @memcpy(me.verts, base.verts);
                if (sk_on) shape.mix(base, me.verts);
                for (o.mods.m[0..o.mods.n]) |*d| {
                    if (d.flags & 1 != 0 and d.kind == ARMATURE) _ = arm.skin(oi, d.p[0], getF(d, 1), base, me.verts, me.verts);
                }
                refreshBounds(me);
                preview.freeKept(&e.kept);
                e.shape = base.shape;
                e.key = key;
                serials +%= 1;
                me.shape = serials;
                colours(me, base, e);
                return me;
            }
        }
    }
    // shape keys alone, as before: the same polygons, only the vertices move
    if (e.valid and e.serial == base.serial and e.mix_only and sk_on and !on(o)) {
        if (e.mesh) |*me| {
            if (me.verts.len == base.verts.len) {
                @memcpy(me.verts, base.verts);
                shape.mix(base, me.verts);
                refreshBounds(me);
                preview.freeKept(&e.kept);
                e.shape = base.shape;
                e.key = key;
                serials +%= 1;
                me.shape = serials;
                return me;
            }
        }
    }
    // multires alone, the same level: the same polygons, only the vertices move
    if (e.valid and e.serial == base.serial and !sk_on and e.plan != null and e.plan_serial == base.serial) {
        if (e.mesh) |*me| {
            const k = multiresOnly(o);
            if (k != 0 and k == e.plan_levels and me.verts.len == e.plan.?.out_verts) {
                multires.evalInto(oi, asP(base), e.plan.?, me.verts) catch return base;
                refreshBounds(me);
                preview.freeKept(&e.kept);
                e.shape = base.shape;
                e.key = key;
                serials +%= 1;
                me.shape = serials;
                colours(me, base, e);
                return me;
            }
        }
    }
    if (e.mesh) |*me| scene.freeMesh(me);
    e.mesh = null;
    preview.freeKept(&e.kept);
    e.serial = base.serial;
    e.shape = base.shape;
    e.key = key;
    e.valid = true;
    e.extra.clear();
    const r = run(oi, o.mods.n, e, &e.bad, &e.extra) orelse return base;
    defer r.deinit(A);
    const po: []const u32 = if (r.poff.len == 0) &[_]u32{0} else r.poff;
    var me = scene.buildMesh(r.verts, po, r.loops) orelse return base;
    // (geometry nodes' triangles: as the original made them)
    if (e.extra.tris.len == me.tris.len and e.extra.tris.len > 0) @memcpy(me.tris, e.extra.tris);
    serials +%= 1;
    me.serial = serials | 0x80000000;
    e.deform_only = deformOnly(o);
    me.uv = if (((sk_on and !on(o)) or e.deform_only) and base.uv.len > 0) (A.dupe([2]f32, base.uv) catch &.{}) else &.{};
    e.mix_only = sk_on and !on(o);
    e.mesh = me;
    e.colours_at = base.paints -% 1;
    colours(&e.mesh.?, base, e);
    return &e.mesh.?;
}

/// A shape-key mix or an Armature copies the mesh, its colours with it (mesh_copy);
/// other modifiers make a new mesh, without.
fn keepsMesh(e: *const Entry) bool {
    return e.deform_only or e.mix_only;
}

/// What shows follows the base's vertex colours (they change in place).
fn colours(me: *Mesh, base: *const Mesh, e: *Entry) void {
    if (e.colours_at == base.paints) return;
    e.colours_at = base.paints;
    me.paints = base.paints;
    const want = keepsMesh(e) and base.vcol.len == me.verts.len;
    if (!want) {
        if (me.vcol.len > 0) A.free(me.vcol);
        me.vcol = &.{};
        return;
    }
    if (me.vcol.len != base.vcol.len) {
        if (me.vcol.len > 0) A.free(me.vcol);
        me.vcol = A.dupe(u32, base.vcol) catch &.{};
    } else @memcpy(me.vcol, base.vcol);
}

/// The weights of what object oi shows: its own, or the base's through a copy of it.
pub fn weightsOf(oi: usize, me: *const Mesh) []const arm.Wgt {
    const base = scene.meshOfObj(oi) orelse return &.{};
    if (me == base) return base.wgt;
    const e = cache.get(scene.objects[oi].oid) orelse return &.{};
    return if (keepsMesh(e)) base.wgt else &.{};
}

fn refreshBounds(me: *Mesh) void {
    me.lo = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    me.hi = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (me.verts) |p| {
        for (0..3) |k| {
            me.lo[k] = @min(me.lo[k], p[k]);
            me.hi[k] = @max(me.hi[k], p[k]);
        }
    }
}

/// The instances on what object oi shows (inst_count of obj_eval), or null.
pub fn instancesOf(oi: usize) ?*inst.Block {
    const o = &scene.objects[oi];
    if (@import("rbody.zig").movingInstances(o.oid)) |b| return b; // (moving: rigid bodies)
    if (!o.kind.isMesh() or !on(o)) return null;
    const me = of(oi) orelse return null;
    const e = cache.get(o.oid) orelse return null;
    if (e.mesh) |*x| {
        if (x == me) return e.extra.inst;
    }
    return null;
}

/// The point normals of what object oi shows (ME_PNRM), or empty.
pub fn pointNormalsOf(oi: usize) []const m.V3 {
    const o = &scene.objects[oi];
    if (!o.kind.isMesh() or !on(o)) return &.{};
    const me = of(oi) orelse return &.{};
    const e = cache.get(o.oid) orelse return &.{};
    if (e.mesh) |*x| {
        if (x == me and e.extra.pnrm.len == me.verts.len) return e.extra.pnrm;
    }
    return &.{};
}

/// The modifiers of object oi that failed (a bit each).
pub fn failed(oi: usize) u8 {
    const o = &scene.objects[oi];
    if (!on(o)) return 0;
    _ = of(oi);
    return if (cache.get(o.oid)) |e| e.bad else 0;
}

/// Smooth corner normals of what object oi shows.
pub fn normals(oi: usize, me: *const Mesh) ?[][3]m.V3 {
    const o = &scene.objects[oi];
    if (@import("cloth.zig").normals(me)) |cn| return cn; // (a simulated cloth's own)
    if (cache.get(o.oid)) |e| {
        if (e.mesh) |*x| {
            if (x == me) return preview.cornerNormalsIn(&e.kept, me);
        }
    }
    return preview.cornerNormals(o.mesh.?, me);
}

// --- changing a stack ------------------------------------------------------------------

pub fn typeByName(s: []const u8) ?u32 {
    for (keys, 0..) |k, t| {
        if (t > 0 and std.ascii.eqlIgnoreCase(k, s)) return @intCast(t);
    }
    return null;
}

fn otherSelected(oi: usize) u32 {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (i != oi and o.selected and o.mesh != null and o.kind.isMesh()) return o.oid;
    }
    return 0;
}

/// Its index, or null: the stack is full.
pub fn add(oi: usize, t: u32) ?usize {
    const o = &scene.objects[oi];
    if (o.mods.n >= scene.MOD_MAX) return null;
    var d = Mod{ .kind = t, .flags = 1 };
    for (params(t), 0..) |p, k| setF(&d, k, p.def);
    if (t == BOOLEAN) d.p[0] = otherSelected(oi);
    o.mods.m[o.mods.n] = d;
    o.mods.n += 1;
    return o.mods.n - 1;
}

pub fn remove(oi: usize, k: usize) bool {
    const o = &scene.objects[oi];
    if (k >= o.mods.n) return false;
    std.mem.copyForwards(Mod, o.mods.m[k .. o.mods.n - 1], o.mods.m[k + 1 .. o.mods.n]);
    o.mods.n -= 1;
    o.mods.m[o.mods.n] = .{};
    return true;
}

pub fn move(oi: usize, k: usize, dir: i32) bool {
    const o = &scene.objects[oi];
    const to = @as(i32, @intCast(k)) + dir;
    if (k >= o.mods.n or to < 0 or to >= o.mods.n) return false;
    std.mem.swap(Mod, &o.mods.m[k], &o.mods.m[@intCast(to)]);
    return true;
}

pub const ApplyResult = enum { ok, failed, none, emptied };

/// Entries 0..k become part of the mesh and leave the stack.
pub fn apply(oi: usize, k: usize) ApplyResult {
    const o = &scene.objects[oi];
    if (k >= o.mods.n) return .none;
    var bad: u8 = 0;
    var ex: Extra = .{};
    defer ex.clear(); // (instances do not become part of the mesh: the port's meshes carry none)
    const r = run(oi, k + 1, null, &bad, &ex);
    defer if (r) |x| x.deinit(A);
    if (bad != 0) return .failed;
    if (r) |x| {
        if (x.verts.len == 0) return .emptied;
        const was = o.mesh;
        o.mesh = scene.addMesh(x.verts, x.poff, x.loops) orelse return .failed;
        // (a copy of the mesh, as mesh_copy: the skin comes along)
        if (was) |w| {
            if (scene.meshes[w]) |*om| {
                if (om.wgt.len == x.verts.len) arm.keepWeights(&scene.meshes[o.mesh.?].?, om);
                var copies = true;
                for (o.mods.m[0 .. k + 1]) |*d| copies = copies and d.kind == ARMATURE;
                if (copies) {
                    @import("vcol.zig").keep(&scene.meshes[o.mesh.?].?, om);
                    // (the same polygons: UVs, seams and shape keys too)
                    scene.keepUvs(o.mesh.?, om);
                }
            }
        }
    }
    var left = k + 1;
    while (left > 0) : (left -= 1) _ = remove(oi, 0);
    multires.prune(oi); // (multires detail that no longer fits)
    return .ok;
}

/// roundss to nearest: a half goes to the even neighbour.
fn roundEven(x: f32) f32 {
    const r = @round(x);
    if (@abs(x - @trunc(x)) != 0.5) return r;
    return 2 * @round(x / 2);
}

/// A value by name; false: no such value.
pub fn set(oi: usize, k: usize, name: []const u8, v: f32) bool {
    const o = &scene.objects[oi];
    if (k >= o.mods.n or !std.math.isFinite(v)) return false;
    const d = &o.mods.m[k];
    for (params(d.kind), 0..) |p, q| {
        if (!std.ascii.eqlIgnoreCase(p.name, name)) continue;
        if (p.object) return false;
        const c = std.math.clamp(v, p.lo, p.hi);
        setF(d, q, if (p.int) roundEven(c) else c);
        return true;
    }
    return false;
}

// --- the file: per object u32 count + count x 48 bytes -------------------------------------

pub fn writeChunk(out: anytype) void {
    out.u32_(@intCast(scene.count));
    for (scene.objects[0..scene.count]) |*o| {
        out.u32_(o.mods.n);
        for (o.mods.m[0..o.mods.n]) |d| {
            var c = d;
            // an object: 1 + its place in the scene (0: none)
            if (c.kind == BOOLEAN) c.p[0] = if (target(&d)) |i| @intCast(i + 1) else 0;
            // an armature: the original's pool handle (it keeps the session's)
            if (c.kind == ARMATURE) c.p[0] = if (target(&d)) |i| armHandle(i) else 0;
            out.bytes(std.mem.asBytes(&c));
        }
    }
}

/// The handle the original finds object i by, opening this file in a session
/// that deleted nothing: a place in its pool, of the first generation (loading
/// fills the pool from the start and keeps generations).
fn armHandle(i: usize) u32 {
    return 1 << 24 | @as(u32, @intCast(i));
}

/// The object a saved handle means: the one at that place when it is an
/// armature, else the file's first armature (a handle of another session).
fn armFromHandle(h: u32, file_index: []const u32) u32 {
    if (h == 0) return 0;
    const at = h & 0xffffff;
    var first: u32 = 0;
    for (file_index, 0..) |g, j| {
        if (j >= scene.count or scene.objects[j].kind != .armature) continue;
        if (g == at) return scene.objects[j].oid;
        if (first == 0) first = scene.objects[j].oid;
    }
    return first;
}

/// `file_index[i]`: object i's place in the file. False: damaged (what was read stays).
pub fn readChunk(d: []const u8, file_index: []const u32) bool {
    if (d.len < 4) return false;
    const n = std.mem.readInt(u32, d[0..4], .little);
    const off = A.alloc(u32, n) catch return false;
    defer A.free(off);
    @memset(off, 0xffffffff);
    var o: usize = 4;
    var ok = true;
    for (0..n) |k| {
        if (o + 4 > d.len) {
            ok = false;
            break;
        }
        const c = std.mem.readInt(u32, d[o..][0..4], .little);
        if (c > scene.MOD_MAX or o + 4 + c * @sizeOf(Mod) > d.len) {
            ok = false;
            break;
        }
        off[k] = @intCast(o);
        o += 4 + c * @sizeOf(Mod);
    }
    for (file_index, 0..) |f, i| {
        if (f >= n or off[f] == 0xffffffff or i >= scene.count) continue;
        const at = off[f];
        const c = std.mem.readInt(u32, d[at..][0..4], .little);
        const ob = &scene.objects[i];
        ob.mods.n = @intCast(c);
        for (0..c) |q| {
            const e = &ob.mods.m[q];
            e.* = std.mem.bytesToValue(Mod, d[at + 4 + q * @sizeOf(Mod)..][0..@sizeOf(Mod)]);
            if (e.kind == 0 or e.kind >= COUNT) e.* = .{ .kind = MIRROR, .flags = 0 }; // (unknown: a disabled mirror)
            if (e.kind == BOOLEAN) {
                // the place in the file -> the object there
                var oid: u32 = 0;
                if (e.p[0] > 0) {
                    for (file_index, 0..) |g, j| {
                        if (g == e.p[0] - 1 and j < scene.count) oid = scene.objects[j].oid;
                    }
                }
                e.p[0] = oid;
            }
            if (e.kind == ARMATURE) e.p[0] = armFromHandle(e.p[0], file_index);
        }
    }
    return ok;
}

test "stack edits and file records" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Mod));
}
