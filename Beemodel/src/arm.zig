// Armatures and skinning (arm.s). An armature object shows a display mesh, each
// bone an octahedron from head to tail, posed; the mesh carries the bones: up to
// 128, each a name, a parent, a rest head / tail / roll and a pose (location,
// Euler rotation, scale, in the bone's own axes: Y along it).
//
// Rest frame: Y = tail - head, X and Z square to it (rolled). A bone's pose
// matrix M = M(parent) R(parent)^-1 R P (P from its location, rotation and
// scale; parents come first), its skin matrix M R^-1.
//
// An Armature modifier deforms a mesh by its skin weights (four bones and
// weights a vertex): a linear blend of the skin matrices, or dual quaternions,
// on every core. Automatic weights: heat diffusion over the mesh, each bone's
// heat equation with the nearest bone as the source; the four largest kept.
//
// The arithmetic is the original's, step by step and in single precision, so
// matrices, skinned vertices and weights come out the same to the last bits
// (x87 sin / cos / atan through f64 rounded to f32).
//
// The block sits on its display mesh with the record's layout of the file, and
// is copied with the mesh. An undo step holds the mesh it saw: an edit copies
// the mesh first (own), an evaluation too when another step holds it (chan), once.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const undo = @import("undo.zig");
const app = @import("app.zig");
const jobs = @import("jobs.zig");
const rig = @import("rig.zig");
const A = @import("alloc.zig").A;
const Mesh = scene.Mesh;

pub const MAXB = 128;
pub const BONE_SZ = 128;
pub const SZ = 64 + MAXB * BONE_SZ;
const BYTES: u64 = (SZ + 4095) & ~@as(u64, 4095);

pub const SEL_HEAD = 1;
pub const SEL_TAIL = 2;
pub const SEL_BONE = 4;

pub const Bone = extern struct {
    name: [24]u8,
    parent: i32, // -1: a root
    head: [3]f32,
    tail: [3]f32,
    roll: f32,
    sel: u8, // 1 head, 2 tail, 4 the bone
    conn: u8, // its head is its parent's tail
    pad0: [2]u8 = .{ 0, 0 },
    loc: [3]f32,
    rot: [3]f32, // Euler XYZ, radians
    scale: [3]f32,
    pad1: [32]u8 = @splat(0),

    pub fn nameOf(b: *const Bone) []const u8 {
        return std.mem.sliceTo(&b.name, 0);
    }
};

/// As in the file from `n` on.
pub const Block = extern struct {
    refs: u32 = 1,
    n: u32 = 0,
    act: u32 = 0,
    pad0: u32 = 0,
    bytes: u64 = BYTES,
    pad1: [40]u8 = @splat(0),
    bones: [MAXB]Bone = undefined,
};

/// Four bones (0xff: none) and their weights.
pub const Wgt = extern struct { bone: [4]u8 align(4), w: [4]f32 };

comptime {
    std.debug.assert(@sizeOf(Bone) == BONE_SZ and @sizeOf(Block) == SZ and @sizeOf(Wgt) == 20);
    std.debug.assert(@offsetOf(Bone, "sel") == 56 and @offsetOf(Bone, "loc") == 60 and @offsetOf(Block, "bones") == 64);
}

/// 3x4 row-major, translation in the 4th column.
pub const M = [12]f32;
const ident: M = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
const TINY: f32 = 1.0e-8;
const EPS: f32 = 1.0e-6;

// pose matrices (armature space), rest matrices, IK's poses used where set
pub var am_m: [MAXB]M = undefined;
pub var am_r: [MAXB]M = undefined;
pub var am_ov: [MAXB]M = undefined;
pub var am_ovf: [MAXB]bool = @splat(false);
var am_k: [MAXB]M = undefined;
var sk_dq: [MAXB][8]f32 = undefined;

/// maxss, minss as the instruction: the second operand when unordered.
pub fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
pub fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

/// fsincos through fstp single.
pub fn sincos(x: f32) [2]f32 {
    const d: f64 = x;
    return .{ @floatCast(@sin(d)), @floatCast(@cos(d)) };
}
/// fpatan through fstp single.
pub fn atan2(y: f32, x: f32) f32 {
    return @floatCast(std.math.atan2(@as(f64, y), @as(f64, x)));
}

// --- 3x4 matrices ------------------------------------------------------------------------

pub fn mMul(a: *const M, b: *const M) M {
    var o: M = undefined;
    for (0..3) |r| {
        for (0..4) |c| {
            var v = a[r * 4] * b[c] + a[r * 4 + 1] * b[4 + c] + a[r * 4 + 2] * b[8 + c];
            if (c == 3) v += a[r * 4 + 3];
            o[r * 4 + c] = v;
        }
    }
    return o;
}

/// The inverse of an affine 3x4; singular: identity.
pub fn mInv(a: *const M) M {
    const c00 = a[5] * a[10] - a[6] * a[9];
    const c01 = a[6] * a[8] - a[4] * a[10];
    const c02 = a[4] * a[9] - a[5] * a[8];
    const det = a[0] * c00 + a[1] * c01 + a[2] * c02;
    if (!(@abs(det) > TINY)) return ident;
    const s = 1.0 / det;
    var o: M = undefined;
    o[0] = c00 * s;
    o[1] = (a[2] * a[9] - a[1] * a[10]) * s;
    o[2] = (a[1] * a[6] - a[2] * a[5]) * s;
    o[4] = c01 * s;
    o[5] = (a[0] * a[10] - a[2] * a[8]) * s;
    o[6] = (a[2] * a[4] - a[0] * a[6]) * s;
    o[8] = c02 * s;
    o[9] = (a[1] * a[8] - a[0] * a[9]) * s;
    o[10] = (a[0] * a[5] - a[1] * a[4]) * s;
    for (0..3) |r| {
        const t = o[r * 4] * a[3] + o[r * 4 + 1] * a[7] + o[r * 4 + 2] * a[11];
        o[r * 4 + 3] = 0.0 - t;
    }
    return o;
}

/// obj_matrix: T Rz Ry Rx S (angles in radians).
pub fn trs(loc: *const [3]f32, rot: *const [3]f32, scl: *const [3]f32) M {
    const x = sincos(rot[0]);
    const y = sincos(rot[1]);
    const z = sincos(rot[2]);
    const sx = x[0];
    const cx = x[1];
    const sy = y[0];
    const cy = y[1];
    const sz = z[0];
    const cz = z[1];
    var o: M = undefined;
    o[0] = cz * cy;
    o[1] = cz * sy * sx - sz * cx;
    o[2] = cz * sy * cx + sz * sx;
    o[4] = sz * cy;
    o[5] = sz * sy * sx + cz * cx;
    o[6] = sz * sy * cx - cz * sx;
    o[8] = 0.0 - sy;
    o[9] = cy * sx;
    o[10] = cy * cx;
    for (0..3) |r| {
        o[r * 4] = scl[0] * o[r * 4];
        o[r * 4 + 1] = scl[1] * o[r * 4 + 1];
        o[r * 4 + 2] = scl[2] * o[r * 4 + 2];
        o[r * 4 + 3] = loc[r];
    }
    return o;
}

pub fn xformPoint(a: *const M, p: [3]f32) [3]f32 {
    var o: [3]f32 = undefined;
    for (0..3) |r| o[r] = a[r * 4] * p[0] + a[r * 4 + 1] * p[1] + a[r * 4 + 2] * p[2] + a[r * 4 + 3];
    return o;
}

/// location, scale (column lengths), Euler XYZ of R = Rz Ry Rx.
pub const Pose = struct { loc: [3]f32, rot: [3]f32, scale: [3]f32 };
pub fn poseFromMat(a: *const M) Pose {
    var p: Pose = undefined;
    p.loc = .{ a[3], a[7], a[11] };
    var r: [9]f32 = undefined;
    for (0..3) |c| {
        const l = maxss(@sqrt(a[c] * a[c] + a[4 + c] * a[4 + c] + a[8 + c] * a[8 + c]), TINY);
        p.scale[c] = l;
        r[c] = a[c] / l;
        r[3 + c] = a[4 + c] / l;
        r[6 + c] = a[8 + c] / l;
    }
    p.rot[1] = atan2(0.0 - r[6], @sqrt(r[0] * r[0] + r[3] * r[3]));
    p.rot[0] = atan2(r[7], r[8]);
    p.rot[2] = atan2(r[3], r[0]);
    return p;
}

/// The object's matrix (what obj_matrix gives: the original's object holds its
/// world transform).
pub fn objMat(i: usize) M {
    const o = &scene.objects[i];
    if (o.parent == null) {
        const r: [3]f32 = .{ o.rot[0] * m.deg, o.rot[1] * m.deg, o.rot[2] * m.deg };
        return trs(&o.loc, &r, &o.scl);
    }
    const w = scene.world(i);
    return w[0..12].*;
}

// --- the block ---------------------------------------------------------------------------

/// Its bones, an armature's.
pub fn of(i: usize) ?*Block {
    if (i >= scene.count) return null;
    const o = &scene.objects[i];
    if (o.kind != .armature) return null;
    const mi = o.mesh orelse return null;
    if (scene.meshes[mi]) |*me| return me.arm;
    return null;
}

pub fn findBone(b: *const Block, nm: []const u8) ?u32 {
    for (b.bones[0..b.n], 0..) |*x, k| {
        if (std.mem.eql(u8, x.nameOf(), nm)) return @intCast(k);
    }
    return null;
}

fn sharedLive(i: usize, mi: u16) bool {
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (k != i and o.mesh == mi) return true;
    }
    return false;
}

/// A mesh of the object's own, copied when `held` or another object has it.
fn ownMesh(i: usize, held: bool) ?u16 {
    const o = &scene.objects[i];
    const mi = o.mesh orelse return null;
    if (!held and !sharedLive(i, mi)) return mi;
    const c = scene.cloneMesh(mi) orelse return null;
    o.mesh = c;
    return c;
}

/// arm_edit: its bones, ready to change (copied with the mesh when an undo
/// step or another object holds them).
pub fn own(i: usize) ?*Block {
    const o = &scene.objects[i];
    if (of(i) == null) return null;
    const c = ownMesh(i, undo.holdsMesh(o.mesh.?)) orelse return null;
    return scene.meshes[c].?.arm;
}

/// arm_mesh_own: the mesh object's mesh, unshared.
pub fn meshOwn(i: usize) ?*Mesh {
    const mi = scene.objects[i].mesh orelse return null;
    var held = undo.holdsMesh(mi);
    for (scene.prim) |p| {
        if (p == mi) held = true;
    }
    const c = ownMesh(i, held) orelse return null;
    return &scene.meshes[c].?;
}

pub fn newBlock() ?*Block {
    const b = A.create(Block) catch return null;
    b.* = .{};
    // (the bones not in use are written to files with the rest: zeros, as arm_new's)
    @memset(std.mem.asBytes(&b.bones), 0);
    return b;
}

pub fn addBone(b: *Block, name: ?[]const u8, parent: i32, head: [3]f32, tail: [3]f32) ?u32 {
    if (b.n >= MAXB or parent >= @as(i32, @intCast(b.n))) return null;
    const x = &b.bones[b.n];
    x.* = std.mem.zeroes(Bone);
    x.parent = parent;
    x.head = head;
    x.tail = tail;
    x.scale = .{ 1, 1, 1 };
    if (name) |s| {
        @memcpy(x.name[0..@min(s.len, 23)], s[0..@min(s.len, 23)]);
    } else if (b.n == 0) {
        @memcpy(x.name[0..4], "Bone");
    } else {
        _ = std.fmt.bufPrint(&x.name, "Bone.{d}", .{b.n}) catch {};
    }
    b.act = b.n;
    b.n += 1;
    return b.n - 1;
}

// --- pose --------------------------------------------------------------------------------

fn norm3(v: *[3]f32) void {
    const l = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (l > TINY) {
        v[0] /= l;
        v[1] /= l;
        v[2] /= l;
    }
}

/// Its rest frame: Y head -> tail, X and Z rolled.
fn restMat(b: *const Bone) M {
    var y: [3]f32 = .{ b.tail[0] - b.head[0], b.tail[1] - b.head[1], b.tail[2] - b.head[2] };
    norm3(&y);
    // X = Y x (0 0 1), or Y x (1 0 0) along Z
    var x: [3]f32 = if (@abs(y[2]) >= 0.99) .{ 0, y[2], 0.0 - y[1] } else .{ y[1], 0.0 - y[0], 0 };
    norm3(&x);
    const z: [3]f32 = .{ x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0] };
    const sc = sincos(b.roll);
    var o: M = undefined;
    for (0..3) |c| {
        o[c * 4] = x[c] * sc[1] + z[c] * sc[0];
        o[c * 4 + 1] = y[c];
        o[c * 4 + 2] = z[c] * sc[1] - x[c] * sc[0];
        o[c * 4 + 3] = b.head[c];
    }
    return o;
}

fn posePass(b: *const Block) void {
    for (b.bones[0..b.n], 0..) |*x, i| {
        am_r[i] = restMat(x);
        const p: M = if (am_ovf[i]) am_ov[i] else trs(&x.loc, &x.rot, &x.scale);
        const rp = mMul(&am_r[i], &p);
        if (x.parent >= 0 and x.parent < i) {
            const k: usize = @intCast(x.parent);
            const t = mInv(&am_r[k]);
            const t2 = mMul(&am_m[k], &t);
            am_m[i] = mMul(&t2, &rp);
        } else am_m[i] = rp;
    }
}

/// am_r and am_m for every bone; with an owner, its IK chains solved and the
/// bones posed again with those poses.
pub fn poseMats(b: *const Block, owner: ?usize) void {
    am_ovf = @splat(false);
    posePass(b);
    if (owner) |i| {
        if (rig.ik(b, i)) posePass(b);
    }
}

fn boneLen(x: *const Bone) f32 {
    const d: [3]f32 = .{ x.tail[0] - x.head[0], x.tail[1] - x.head[1], x.tail[2] - x.head[2] };
    return @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
}

/// Where the bone's tail is, posed (am_m set), armature space.
pub fn tailOf(b: *const Block, k: usize) [3]f32 {
    return xformPoint(&am_m[k], .{ 0, boneLen(&b.bones[k]), 0 });
}

const oct_pts = [6][3]f32{ .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 0.1, 0.1, 0 }, .{ 0, 0.1, 0.1 }, .{ -0.1, 0.1, 0 }, .{ 0, 0.1, -0.1 } };
const oct_faces = [8][3]u32{ .{ 0, 3, 2 }, .{ 0, 4, 3 }, .{ 0, 5, 4 }, .{ 0, 2, 5 }, .{ 1, 2, 3 }, .{ 1, 3, 4 }, .{ 1, 4, 5 }, .{ 1, 5, 2 } };

fn fillVerts(b: *const Block, out: []m.V3) void {
    for (b.bones[0..b.n], 0..) |*x, i| {
        const l = boneLen(x);
        for (oct_pts, 0..) |p, k| out[i * 6 + k] = xformPoint(&am_m[i], .{ p[0] * l, p[1] * l, p[2] * l });
    }
}

/// A new display mesh for these bones, carrying a copy of them. Null: no room.
pub fn makeMesh(b: *const Block, owner: ?usize) ?u16 {
    poseMats(b, owner);
    const n: usize = b.n;
    if (n == 0) return null;
    const v = A.alloc(m.V3, n * 6) catch return null;
    defer A.free(v);
    const po = A.alloc(u32, n * 8 + 1) catch return null;
    defer A.free(po);
    const lo = A.alloc(u32, n * 24) catch return null;
    defer A.free(lo);
    fillVerts(b, v);
    for (0..n) |i| {
        for (oct_faces, 0..) |f, k| {
            for (0..3) |c| lo[(i * 8 + k) * 3 + c] = f[c] + @as(u32, @intCast(i * 6));
        }
    }
    for (po, 0..) |*p, k| p.* = @intCast(k * 3);
    const mi = scene.addMesh(v, po, lo) orelse return null;
    const c = A.create(Block) catch {
        scene.freeMeshSlot(mi);
        return null;
    };
    c.* = b.*;
    scene.meshes[mi].?.arm = c;
    return mi;
}

/// arm_rebuild: its display mesh made again from its bones (in place when the
/// bones are as many).
pub fn rebuild(i: usize) void {
    const o = &scene.objects[i];
    o.arm_dirty = false;
    const b = of(i) orelse return;
    const mi = o.mesh.?;
    const me = &scene.meshes[mi].?;
    if (b.n > 0 and me.verts.len == @as(usize, b.n) * 6 and me.loops.len == @as(usize, b.n) * 24 and me.poff.len == @as(usize, b.n) * 8 + 1) {
        poseMats(b, i);
        fillVerts(b, me.verts);
        scene.refreshMesh(mi);
    } else {
        o.mesh = makeMesh(b, i) orelse mi;
    }
    app.dirty = true;
}

var any_dirty = false;

pub fn markDirty(i: usize) void {
    scene.objects[i].arm_dirty = true;
    any_dirty = true;
}

/// Every armature posed again.
pub fn allDirty() void {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.kind == .armature) markDirty(i);
    }
}

/// arm_refresh: armatures whose pose changed show it.
pub fn refresh() void {
    if (!any_dirty) return;
    any_dirty = false;
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (!o.arm_dirty) continue;
        undo.evalWrite();
        const was = o.mesh;
        rebuild(i);
        if (o.mesh != was) undo.absorb(i); // (an evaluation: no edit)
    }
}

/// A new armature (one bone, up 1): its object.
pub fn create(name: ?[]const u8) ?usize {
    const b = newBlock() orelse return null;
    defer A.destroy(b);
    _ = addBone(b, null, -1, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    const mi = makeMesh(b, null) orelse return null;
    const i = scene.add(.armature) orelse return null;
    const o = &scene.objects[i];
    o.mesh = mi;
    if (name) |s| o.setName(s);
    return i;
}

var hint: usize = 0;

fn byOid(oid: u32) ?usize {
    if (hint < scene.count and scene.objects[hint].oid == oid) return hint;
    hint = scene.findOid(oid) orelse return null;
    return hint;
}

/// anim.bone_chan: bone:Rig:Bone:rz. A set is no edit, but a step keeps the
/// bones it saw (arm_edit copies on ME_REFS, which counts snapshots), and marks
/// the armature to show anew.
fn chan(oid: u32, bone: u32, prop: u32, v: f32, set: bool) ?f32 {
    const i = byOid(oid) orelse return null;
    if (prop >= 9) return null;
    var b = of(i) orelse return null;
    if (bone >= b.n) return null;
    const f = &(@as(*[9]f32, @ptrCast(&b.bones[bone].loc))[prop]);
    if (!set) return f.*;
    if (f.* == v) return v;
    const mi = scene.objects[i].mesh.?;
    if (undo.evalHolds(mi) or sharedLive(i, mi)) {
        const c = ownMesh(i, true) orelse return null;
        undo.absorb(i);
        b = scene.meshes[c].?.arm orelse return null;
    }
    @as(*[9]f32, @ptrCast(&b.bones[bone].loc))[prop] = v;
    markDirty(i);
    return v;
}

fn path(obj: []const u8, bone: []const u8) ?[2]u32 {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (!std.mem.eql(u8, o.name(), obj)) continue;
        const b = of(i) orelse return null;
        return .{ o.oid, findBone(b, bone) orelse return null };
    }
    return null;
}

/// Where the bone's tail is, posed (IK too), in the world.
pub fn boneTail(i: usize, bone: u32) ?m.V3 {
    const b = of(i) orelse return null;
    if (bone >= b.n) return null;
    poseMats(b, i);
    const t = tailOf(b, bone);
    const a = objMat(i);
    return xformPoint(&a, t);
}

fn tailHook(oid: u32, bone: u32) ?m.V3 {
    return boneTail(byOid(oid) orelse return null, bone);
}

/// Wire the animation's hooks (once, at start).
pub fn init() void {
    const anim = @import("anim.zig");
    const armedit = @import("armedit.zig");
    anim.bone_chan = chan;
    anim.bone_path = path;
    anim.after_drivers = rig.eval;
    anim.before_write = rig.beforeWrite;
    anim.on_reset = rig.reset;
    const motion = @import("motion.zig");
    motion.bones_selected = armedit.selectedBones;
    motion.bone_tail = tailHook;
}

// --- skinning ----------------------------------------------------------------------------

/// mat_dq: its rotation (columns made unit) as a quaternion, its translation
/// as the dual part: real xyzw, dual xyzw.
fn matDq(a: *const M) [8]f32 {
    var r: [9]f32 = undefined;
    for (0..3) |c| {
        const l = maxss(@sqrt(a[c] * a[c] + a[4 + c] * a[4 + c] + a[8 + c] * a[8 + c]), TINY);
        r[c] = a[c] / l;
        r[3 + c] = a[4 + c] / l;
        r[6 + c] = a[8 + c] / l;
    }
    var q: [4]f32 = undefined;
    const tr = r[0] + r[4] + r[8];
    if (tr > 0) {
        const s = @sqrt(tr + 1.0) * 2.0;
        q[3] = s * 0.25;
        q[0] = (r[7] - r[5]) / s;
        q[1] = (r[2] - r[6]) / s;
        q[2] = (r[3] - r[1]) / s;
    } else if (r[0] >= r[4] and r[0] >= r[8]) {
        const s = @sqrt(r[0] + 1.0 - r[4] - r[8]) * 2.0;
        q[0] = s * 0.25;
        q[3] = (r[7] - r[5]) / s;
        q[1] = (r[1] + r[3]) / s;
        q[2] = (r[2] + r[6]) / s;
    } else if (r[0] < r[4] and r[4] >= r[8]) {
        const s = @sqrt(1.0 + r[4] - r[0] - r[8]) * 2.0;
        q[1] = s * 0.25;
        q[3] = (r[2] - r[6]) / s;
        q[0] = (r[1] + r[3]) / s;
        q[2] = (r[5] + r[7]) / s;
    } else {
        const s = @sqrt(1.0 + r[8] - r[0] - r[4]) * 2.0;
        q[2] = s * 0.25;
        q[3] = (r[3] - r[1]) / s;
        q[0] = (r[2] + r[6]) / s;
        q[1] = (r[5] + r[7]) / s;
    }
    // dual = 0.5 (0, t) q: (t w + t x q.xyz) / 2, w: -(t . q.xyz) / 2
    const t: [3]f32 = .{ a[3], a[7], a[11] };
    const cr = cross(t, .{ q[0], q[1], q[2] });
    const dot = (t[0] * q[0] + t[1] * q[1]) + (t[2] * q[2] + 0);
    return .{ q[0], q[1], q[2], q[3], (t[0] * q[3] + cr[0]) * 0.5, (t[1] * q[3] + cr[1]) * 0.5, (t[2] * q[3] + cr[2]) * 0.5, (0.0 - dot) * 0.5 };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// p' = r p r* + t
fn dqApply(r: *const [4]f32, d: *const [4]f32, p: [3]f32) [3]f32 {
    const rv: [3]f32 = .{ r[0], r[1], r[2] };
    const dv: [3]f32 = .{ d[0], d[1], d[2] };
    const w = r[3];
    const c1 = cross(rv, p);
    const v5: [3]f32 = .{ c1[0] + w * p[0], c1[1] + w * p[1], c1[2] + w * p[2] };
    const c2 = cross(rv, v5);
    const c3 = cross(rv, dv);
    var o: [3]f32 = undefined;
    for (0..3) |k| {
        const q = p[k] + (c2[k] + c2[k]);
        const t = (w * dv[k] - d[3] * rv[k]) + c3[k];
        o[k] = q + (t + t);
    }
    return o;
}

fn dot4(a: *const [4]f32, b: *const [4]f32) f32 {
    return (a[0] * b[0] + a[1] * b[1]) + (a[2] * b[2] + a[3] * b[3]);
}

const Skin = struct { wgt: []const Wgt, in: []const m.V3, out: []m.V3, nb: u32, dual: bool };

fn linear(s: *const Skin, lo: usize, hi: usize) void {
    for (lo..hi) |v| {
        const g = &s.wgt[v];
        const p = s.in[v];
        var sum: [3]f32 = .{ 0, 0, 0 };
        var sw: f32 = 0;
        for (0..4) |c| {
            const b = g.bone[c];
            const w = g.w[c];
            if (b >= s.nb or !(w > 0)) continue;
            const q = xformPoint(&am_k[b], p);
            for (0..3) |k| sum[k] = q[k] * w + sum[k];
            sw = w + sw;
        }
        if (!(sw > EPS)) {
            s.out[v] = p;
            continue;
        }
        for (0..3) |k| s.out[v][k] = sum[k] / sw;
    }
}

fn dualq(s: *const Skin, lo: usize, hi: usize) void {
    for (lo..hi) |v| {
        const g = &s.wgt[v];
        const p = s.in[v];
        var re: [4]f32 = .{ 0, 0, 0, 0 };
        var du: [4]f32 = .{ 0, 0, 0, 0 };
        var first = false;
        var q0: [4]f32 = undefined;
        for (0..4) |c| {
            const b = g.bone[c];
            var w = g.w[c];
            if (b >= s.nb or !(w > 0)) continue;
            const q = &sk_dq[b];
            const qr: *const [4]f32 = q[0..4];
            if (!first) {
                first = true;
                q0 = qr.*;
            }
            // the opposite hemisphere: a negative weight
            if (!(dot4(&q0, qr) >= 0)) w = -w;
            for (0..4) |k| {
                re[k] = re[k] + q[k] * w;
                du[k] = du[k] + q[4 + k] * w;
            }
        }
        s.out[v] = p;
        if (!first) continue;
        const l = @sqrt(dot4(&re, &re));
        if (!(l > EPS)) continue;
        for (0..4) |k| {
            re[k] /= l;
            du[k] /= l;
        }
        s.out[v] = dqApply(&re, &du, p);
    }
}

/// The threads that have skinned (a bit each; the tests read it).
pub var skin_threads = std.atomic.Value(u64).init(0);

fn skinJob(ctx: *anyopaque, lo: usize, hi: usize, thread: usize) void {
    const s: *const Skin = @ptrCast(@alignCast(ctx));
    _ = skin_threads.fetchOr(@as(u64, 1) << @intCast(thread & 63), .monotonic);
    if (s.dual) dualq(s, lo, hi) else linear(s, lo, hi);
}

/// S = (A^-1 Mesh)^-1 M R^-1 (A^-1 Mesh) for every bone. False: no armature.
fn skinMats(mesh_obj: usize, arm_obj: usize, dual: bool) ?u32 {
    const b = of(arm_obj) orelse return null;
    poseMats(b, arm_obj);
    const me = objMat(mesh_obj);
    const a = objMat(arm_obj);
    const ai = mInv(&a);
    const t2 = mMul(&ai, &me);
    const n = mInv(&t2);
    for (0..b.n) |i| {
        const ri = mInv(&am_r[i]);
        const mr = mMul(&am_m[i], &ri);
        const t = mMul(&mr, &t2);
        am_k[i] = mMul(&n, &t);
        if (dual) sk_dq[i] = matDq(&am_k[i]);
    }
    return b.n;
}

/// arm_skin: `in` (as many as the mesh's weights) deformed into `out` (may be
/// `in`). False: nothing to do (no armature, no weights).
pub fn skin(mesh_obj: usize, arm_oid: u32, mode: f32, base: *const Mesh, in: []const m.V3, out: []m.V3) bool {
    const ai = scene.findOid(arm_oid) orelse return false;
    if (base.wgt.len != in.len or in.len != out.len or in.len == 0) return false;
    const dual: bool = blk: {
        if (!(@abs(mode) < 1e9)) break :blk false;
        break :blk @as(i32, @intFromFloat(mode)) != 0;
    };
    const nb = skinMats(mesh_obj, ai, dual) orelse return false;
    var s = Skin{ .wgt = base.wgt, .in = in, .out = out, .nb = nb, .dual = dual };
    jobs.parallelFor(in.len, 4096, &s, skinJob);
    return true;
}

// --- weights -----------------------------------------------------------------------------

const HW_ITERS = 400;

fn segDist2(a: *const [3]f32, b: *const [3]f32, p: *const [3]f32) f32 {
    const d: [3]f32 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const e: [3]f32 = .{ p[0] - a[0], p[1] - a[1], p[2] - a[2] };
    var t = d[0] * e[0] + d[1] * e[1] + d[2] * e[2];
    const dd = maxss(d[0] * d[0] + d[1] * d[1] + d[2] * d[2], TINY);
    t /= dd;
    t = minss(maxss(t, 0), 1);
    const q: [3]f32 = .{ e[0] - d[0] * t, e[1] - d[1] * t, e[2] - d[2] * t };
    return q[0] * q[0] + q[1] * q[1] + q[2] * q[2];
}

const Heat = struct { w: []f32, h: []const f32, near: []const u8, off: []const u32, nb: []const u32, nv: usize };

fn heatJob(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *const Heat = @ptrCast(@alignCast(ctx));
    for (lo..hi) |bone| {
        const w = j.w[bone * j.nv..][0..j.nv];
        for (0..HW_ITERS) |_| {
            for (0..j.nv) |v| {
                var s: f32 = 0;
                const a = j.off[v];
                const e = j.off[v + 1];
                for (j.nb[a..e]) |n| s = s + w[n];
                const h = j.h[v];
                const deg: f32 = @floatFromInt(e - a);
                var den = deg + h;
                if (j.near[v] == bone) s += h;
                den = maxss(den, EPS);
                w[v] = s / den;
            }
        }
    }
}

/// The mesh's edges in the original's order: each new consecutive loop pair, by
/// polygon (lo, hi).
fn edgesFirstSeen(me: *const Mesh) ?[][2]u32 {
    const out = A.alloc([2]u32, me.edge_list.len) catch return null;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(A);
    seen.ensureTotalCapacity(A, @intCast(me.edge_list.len + 1)) catch {
        A.free(out);
        return null;
    };
    var n: usize = 0;
    for (0..me.poff.len - 1) |p| {
        const s0 = me.poff[p];
        const e0 = me.poff[p + 1];
        var k = s0;
        while (k < e0) : (k += 1) {
            var a = me.loops[k];
            var b = me.loops[if (k + 1 < e0) k + 1 else s0];
            if (a > b) std.mem.swap(u32, &a, &b);
            const key = (@as(u64, a) << 32) | b;
            if (seen.contains(key)) continue;
            seen.putAssumeCapacity(key, {});
            if (n < out.len) out[n] = .{ a, b };
            n += 1;
        }
    }
    return out[0..@min(n, out.len)];
}

/// arm_auto_weights: the mesh's (unshared) weights by bone heat. False: no.
pub fn autoWeights(mesh_obj: usize, arm_obj: usize) bool {
    const b = of(arm_obj) orelse return false;
    if (b.n == 0) return false;
    const me = meshOwn(mesh_obj) orelse return false;
    const nv = me.verts.len;
    if (nv == 0) return false;
    const nb: usize = b.n;
    // bone segments in the mesh's space: Mesh^-1 Arm
    const mo = objMat(mesh_obj);
    const inv = mInv(&mo);
    const ao = objMat(arm_obj);
    const q = mMul(&inv, &ao);
    var seg: [MAXB][2][3]f32 = undefined;
    for (b.bones[0..nb], 0..) |*x, i| seg[i] = .{ xformPoint(&q, x.head), xformPoint(&q, x.tail) };

    const edges = edgesFirstSeen(me) orelse return false;
    defer A.free(edges.ptr[0..me.edge_list.len]);
    // the average edge: the heat's scale
    var sum: f32 = 0;
    for (edges) |e| {
        const p = me.verts[e[0]];
        const r = me.verts[e[1]];
        const d: [3]f32 = .{ p[0] - r[0], p[1] - r[1], p[2] - r[2] };
        sum = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) + sum;
    }
    const ne: f32 = @floatFromInt(@max(edges.len, 1));
    var edge2 = maxss(sum / ne, EPS);
    edge2 *= edge2;

    const h = A.alloc(f32, nv) catch return false;
    defer A.free(h);
    const near = A.alloc(u8, nv) catch return false;
    defer A.free(near);
    const w = A.alloc(f32, nv * nb) catch return false;
    defer A.free(w);
    @memset(w, 0);
    for (me.verts, 0..) |*p, v| {
        var best: f32 = 1.0e30;
        var who: usize = 0;
        for (0..nb) |k| {
            const d = segDist2(&seg[k][0], &seg[k][1], p);
            if (!(d >= best)) {
                best = d;
                who = k;
            }
        }
        near[v] = @intCast(who);
        h[v] = minss(edge2 / maxss(best, EPS), 1000.0); // (edge / d)^2, at most 1000
        w[who * nv + v] = 1;
    }
    // neighbours, then diffuse
    const off = A.alloc(u32, nv + 1) catch return false;
    defer A.free(off);
    const adj = A.alloc(u32, edges.len * 2) catch return false;
    defer A.free(adj);
    @memset(off, 0);
    for (edges) |e| {
        off[e[0] + 1] += 1;
        off[e[1] + 1] += 1;
    }
    for (0..nv) |v| off[v + 1] += off[v];
    const cur = A.alloc(u32, nv) catch return false;
    defer A.free(cur);
    @memcpy(cur, off[0..nv]);
    for (edges) |e| {
        adj[cur[e[0]]] = e[1];
        cur[e[0]] += 1;
        adj[cur[e[1]]] = e[0];
        cur[e[1]] += 1;
    }
    var heat = Heat{ .w = w, .h = h, .near = near, .off = off, .nb = adj, .nv = nv };
    jobs.parallelFor(nb, 1, &heat, heatJob);

    if (me.wgt.len != nv) {
        if (me.wgt.len > 0) A.free(me.wgt);
        me.wgt = A.alloc(Wgt, nv) catch {
            me.wgt = &.{};
            return false;
        };
    }
    // the four heaviest bones a vertex, normalized
    for (me.wgt, 0..) |*g, v| {
        g.* = .{ .bone = .{ 0xff, 0xff, 0xff, 0xff }, .w = .{ 0, 0, 0, 0 } };
        for (0..nb) |k| {
            const x = w[k * nv + v];
            if (!(x > 0.01)) continue;
            var lite: usize = 0;
            var lw = g.w[0];
            for (1..4) |c| {
                if (lw > g.w[c]) {
                    lw = g.w[c];
                    lite = c;
                }
            }
            if (!(x > lw)) continue;
            g.bone[lite] = @intCast(k);
            g.w[lite] = x;
        }
        const s = (((0 + g.w[0]) + g.w[1]) + g.w[2]) + g.w[3];
        if (s > EPS) {
            for (&g.w) |*x| x.* /= s;
        } else {
            g.bone[0] = near[v];
            g.w[0] = 1;
        }
    }
    scene.bumpShape(scene.objects[mesh_obj].mesh.?);
    return true;
}

/// (An edit made a new mesh.) The weights stay while the vertices are as many;
/// a new topology has none, as in the original.
pub fn keepWeights(me: *Mesh, from: *const Mesh) void {
    if (me.wgt.len > 0 or from.wgt.len != me.verts.len or from.wgt.len == 0) return;
    me.wgt = A.dupe(Wgt, from.wgt) catch return;
}

// --- files -------------------------------------------------------------------------------

/// ARMT: per mesh with bones its index, the block from its bone count on.
pub fn writeArmt(out: anytype, mesh_ix: []const u32) void {
    for (mesh_ix, 0..) |ix, mi| {
        if (ix == 0xffffffff) continue;
        const b = scene.meshes[mi].?.arm orelse continue;
        out.u32_(ix);
        out.bytes(std.mem.asBytes(b)[4..]);
    }
}

fn saneF(p: []f32, bad: f32) void {
    for (p) |*x| {
        if (!std.math.isFinite(x.*) or @abs(x.*) > 1e7) x.* = bad;
    }
}

/// False: damaged (what fits came in). Whatever a file says: bones as many as
/// fit, parents before their children, numbers that can be worked with.
pub fn readArmt(c: []const u8, map: []const ?u16) bool {
    var o: usize = 0;
    var ok = true;
    while (c.len - o >= SZ) : (o += SZ) {
        const ix = std.mem.readInt(u32, c[o..][0..4], .little);
        const mi = if (ix < map.len) (map[ix] orelse continue) else {
            ok = false;
            continue;
        };
        const n = std.mem.readInt(u32, c[o + 4..][0..4], .little);
        if (n > MAXB) {
            ok = false;
            continue;
        }
        const b = newBlock() orelse return false;
        @memcpy(std.mem.asBytes(b)[4..], c[o + 4..][0 .. SZ - 4]);
        b.refs = 1;
        b.bytes = BYTES;
        if (b.act >= MAXB) b.act = 0;
        for (b.bones[0..n], 0..) |*x, k| {
            if (x.parent >= @as(i32, @intCast(k))) x.parent = -1;
            x.name[23] = 0;
            saneF(&x.head, 0);
            saneF(&x.tail, 0);
            saneF(@as(*[1]f32, @ptrCast(&x.roll)), 0);
            saneF(&x.loc, 0);
            saneF(&x.rot, 0);
            saneF(&x.scale, 1);
        }
        const me = &scene.meshes[mi].?;
        if (me.arm) |old| A.destroy(old);
        me.arm = b;
    }
    return ok and o == c.len;
}

/// MWGT: per mesh with weights its index, vertices, the records.
pub fn writeMwgt(out: anytype, mesh_ix: []const u32) void {
    for (mesh_ix, 0..) |ix, mi| {
        if (ix == 0xffffffff) continue;
        const me = &scene.meshes[mi].?;
        if (me.wgt.len != me.verts.len or me.wgt.len == 0) continue;
        out.u32_(ix);
        out.u32_(@intCast(me.wgt.len));
        out.bytes(std.mem.sliceAsBytes(me.wgt));
    }
}

pub fn readMwgt(c: []const u8, map: []const ?u16) bool {
    var o: usize = 0;
    while (c.len - o >= 8) {
        const ix = std.mem.readInt(u32, c[o..][0..4], .little);
        const nv = std.mem.readInt(u32, c[o + 4..][0..4], .little);
        if (nv > 0x8000000) return false;
        const size = @as(usize, nv) * 20 + 8;
        if (size > c.len - o) return false;
        defer o += size;
        const mi = (if (ix < map.len) map[ix] else null) orelse continue;
        const me = &scene.meshes[mi].?;
        if (nv != me.verts.len or nv == 0) continue;
        const w = A.alloc(Wgt, nv) catch return false;
        @memcpy(std.mem.sliceAsBytes(w), c[o + 8..][0 .. @as(usize, nv) * 20]);
        for (w) |*g| {
            for (&g.w) |*x| {
                if (!std.math.isFinite(x.*)) x.* = 0;
            }
        }
        if (me.wgt.len > 0) A.free(me.wgt);
        me.wgt = w;
    }
    return o == c.len;
}

test "records and matrices" {
    try std.testing.expectEqual(@as(usize, 16448), @sizeOf(Block));
    const r: [3]f32 = .{ 0.3, -1.2, 0.7 };
    const a = trs(&.{ 1, 2, 3 }, &r, &.{ 2, 0.5, 1.5 });
    const i = mInv(&a);
    const u = mMul(&a, &i);
    for (u, ident) |x, y| try std.testing.expect(@abs(x - y) < 1e-5);
    const p = poseFromMat(&a);
    for (p.rot, r) |x, y| try std.testing.expect(@abs(x - y) < 1e-5);
    // singular: the identity, as the original
    const z = std.mem.zeroes(M);
    try std.testing.expectEqual(ident, mInv(&z));
}

test "a dual quaternion of a rigid matrix moves points as it does" {
    const r: [3]f32 = .{ 0.4, 0.2, -0.9 };
    const a = trs(&.{ 1, -2, 0.5 }, &r, &.{ 1, 1, 1 });
    const q = matDq(&a);
    const p: [3]f32 = .{ 0.3, 0.7, -0.2 };
    const x = dqApply(q[0..4], q[4..8], p);
    const y = xformPoint(&a, p);
    for (x, y) |s, t| try std.testing.expect(@abs(s - t) < 1e-5);
}
