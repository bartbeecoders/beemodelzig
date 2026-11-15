// BeeScript's animation and rigging builtins (script.s b_key, b_unkey, b_keyed,
// b_armature, b_evpos, b_bones, b_shapes, b_bonepos, b_wpaint, b_weight): keys
// on any animatable path, armatures, posed bones, skin weights (painted and
// read), shape keys, and a mesh as its modifiers show it.
const std = @import("std");
const bs = @import("bscript.zig");
const bsc = @import("bs_scene.zig");
const scene = @import("scene.zig");
const anim = @import("anim.zig");
const arm = @import("arm.zig");
const app = @import("app.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "key", .f = key },
    .{ .name = "unkey", .f = unkey },
    .{ .name = "keyed", .f = keyed },
    .{ .name = "armature", .f = armature },
    .{ .name = "evpos", .f = evpos },
    .{ .name = "bones", .f = bones },
    .{ .name = "shapes", .f = shapes },
    .{ .name = "bonepos", .f = bonepos },
    .{ .name = "wpaint", .f = wpaint },
    .{ .name = "weight", .f = weight },
};

const e_key_path = "key: no such property (paths: \"Cube:x\" .. sz, \"material:M:roughness\", \"modifier:Cube:0:levels\", \"node:Tree:3:5\"): ";
const e_key_interp = "key: interpolation is \"constant\", \"linear\" or \"bezier\"";

// ---- keys ---------------------------------------------------------------------------------

/// key(path, frame [, value [, interpolation]]) -> the curve's key count (no
/// value, or NaN: the property's value now)
fn key(a: []const V) Err!V {
    const path = try bs.argStr(a[0]);
    const f = bs.f32of(try bs.argNum(a[1]));
    var v: f32 = std.math.nan(f32);
    var int: u8 = 2;
    if (a.len >= 3) {
        v = bs.f32of(try bs.argNum(a[2]));
        if (a.len >= 4) {
            const s = try bs.argStr(a[3]);
            int = if (std.mem.eql(u8, s, "constant")) 0 else if (std.mem.eql(u8, s, "linear")) 1 else if (std.mem.eql(u8, s, "bezier")) 2 else return bs.fail(e_key_interp, "");
        }
    }
    const n = anim.pathKey(path, f, if (std.math.isNan(v)) null else v, int) orelse return bs.fail(e_key_path, path);
    app.dirty = true;
    return bs.num(@floatFromInt(n));
}

/// unkey(path, frame) -> 1 when a key went
fn unkey(a: []const V) Err!V {
    const path = try bs.argStr(a[0]);
    const f = bs.f32of(try bs.argNum(a[1]));
    const ch = anim.parsePath(path) orelse return bs.num(0);
    const gone = anim.unkey(ch, 0, f);
    if (gone) app.dirty = true;
    return bs.num(if (gone) 1 else 0);
}

/// keyed(path, frame) -> its curve's value at that frame; nil: no curve
fn keyed(a: []const V) Err!V {
    const path = try bs.argStr(a[0]);
    const f = bs.f32of(try bs.argNum(a[1]));
    const v = anim.pathEval(path, f) orelse return bs.nil;
    return bs.num(v);
}

// ---- armatures ----------------------------------------------------------------------------

/// armature([name]) -> the name of a new armature (one bone, up 1, at the
/// origin), selected and active; nil when none could be made
fn armature(a: []const V) Err!V {
    var nm: ?[]const u8 = null;
    if (a.len >= 1) nm = try bs.argStr(a[0]);
    const i = arm.create(null) orelse return bs.nil;
    newName(i, nm orelse "Armature");
    scene.selectOnly(i);
    app.dirty = true;
    return bsc.retName(i);
}

/// obj_new's unique_name: the name, or "Name.001" ... (its base cut to 26 bytes)
/// when another object has it. Unlike obj_rename the new object is not among
/// the objects yet, so even "" is a name it can have.
fn newName(i: usize, want: []const u8) void {
    var buf: [32]u8 = undefined;
    const b = want[0..@min(want.len, 26)];
    var k: u32 = 0;
    var cand: []const u8 = b;
    while (true) {
        @memcpy(buf[0..b.len], b);
        var n = b.len;
        if (k > 0) {
            buf[n] = '.';
            buf[n + 1] = @intCast('0' + k / 100);
            buf[n + 2] = @intCast('0' + k % 100 / 10);
            buf[n + 3] = @intCast('0' + k % 10);
            n += 4;
        }
        cand = buf[0..n];
        const taken = for (scene.objects[0..scene.count], 0..) |*o, j| {
            if (j != i and std.mem.eql(u8, o.name(), cand)) break true;
        } else false;
        if (!taken) break;
        k += 1;
        if (k > 999) break;
    }
    const o = &scene.objects[i];
    o.name_buf = @splat(0);
    @memcpy(o.name_buf[0..cand.len], cand);
    o.name_len = @intCast(cand.len);
}

/// bones(name) -> an armature's bone count (-1: not an armature)
fn bones(a: []const V) Err!V {
    const i = try bsc.argObj(a[0]);
    const b = arm.of(i) orelse return bs.num(-1);
    return bs.num(@floatFromInt(b.n));
}

/// shapes(name) -> a mesh's shape keys, the Basis too (0: none)
fn shapes(a: []const V) Err!V {
    const i = try bsc.argObj(a[0]);
    return bs.num(@floatFromInt(@import("shape.zig").count(i)));
}

/// The first character of a text argument as an axis (0..2), else null.
fn axisOf(v: V) Err!?usize {
    const s = try bs.argStr(v);
    const c: u32 = @as(u32, s.ptr[0]) -% 'x';
    return if (c <= 2) c else null;
}

/// bonepos(armature, bone, axis) -> where a bone's tail is posed (IK too), in
/// the world; nil: no such bone
fn bonepos(a: []const V) Err!V {
    const i = try bsc.argObj(a[0]);
    const b = arm.of(i) orelse return bs.nil;
    const bn = arm.findBone(b, try bs.argStr(a[1])) orelse return bs.nil;
    const ax = (try axisOf(a[2])) orelse return bs.nil;
    const t = arm.boneTail(i, bn) orelse return bs.nil;
    return bs.num(t[ax]);
}

/// evpos(name, i, axis): vertex i of the mesh as shown (after the modifiers)
fn evpos(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    const me = @import("mods.zig").of(i) orelse &scene.meshes[scene.objects[i].mesh.?].?;
    const k: u32 = @bitCast(bs.ci32(try bs.argNum(a[1])));
    if (k >= me.verts.len) return bs.nil;
    const ax = (try axisOf(a[2])) orelse return bs.nil;
    return bs.num(me.verts[k][ax]);
}

/// weight(name, i, bone): vertex i's skin weight for a bone (by number)
fn weight(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    const me = &scene.meshes[scene.objects[i].mesh.?].?;
    const k: u32 = @bitCast(bs.ci32(try bs.argNum(a[1])));
    const bone = bs.ci32(try bs.argNum(a[2]));
    if (me.wgt.len == 0 or k >= me.verts.len or k >= me.wgt.len) return bs.num(0);
    const w = &me.wgt[k];
    for (0..4) |s| {
        if (@as(i32, w.bone[s]) == bone) return bs.num(w.w[s]);
    }
    return bs.num(0);
}

/// wpaint(object, x, y, z, radius, bone, weight): skin weight for a bone
/// painted round a world point (one undo step) -> 1; 0: no armature, no such bone
fn wpaint(a: []const V) Err!V {
    var v: [5]f32 = undefined; // x y z radius weight
    for (0..5) |k| v[k] = bs.f32of(try bs.argNum(a[if (k < 4) k + 1 else 6]));
    const bone: u32 = @bitCast(bs.ci32(try bs.argNum(a[5])));
    const i = try bsc.argObj(a[0]);
    const wp = @import("wpaint.zig");
    const b = wp.blockOf(i) orelse return bs.num(0);
    if (bone >= b.n) return bs.num(0);
    b.act = @intCast(bone);
    const was = wp.value;
    defer wp.value = was;
    wp.value = v[4];
    const ok = @import("paint.zig").dabWorldMesh(i, .weight, .{ v[0], v[1], v[2] }, v[3]);
    app.dirty = true;
    return bs.num(if (ok) 1 else 0);
}
