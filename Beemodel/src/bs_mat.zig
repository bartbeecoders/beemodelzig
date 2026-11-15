// BeeScript's material builtins (script.s b_material, b_matset, b_matget,
// b_assign, b_matof, b_instance, b_matparam): materials by name (exactly, as
// mat_find), their parameters (the original's mat_params, by exact name),
// what a mesh wears, material instances and their parameter nodes. What they
// change is part of the run's one undo step (bscript.zig).
const std = @import("std");
const bs = @import("bscript.zig");
const bsc = @import("bs_scene.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const gops = @import("graphops.zig");
const sg = @import("shgraph.zig");
const app = @import("app.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "material", .f = materialFn },
    .{ .name = "matset", .f = matset },
    .{ .name = "matget", .f = matget },
    .{ .name = "assign", .f = assign },
    .{ .name = "matof", .f = matof },
    .{ .name = "instance", .f = instance },
    .{ .name = "matparam", .f = matparam },
};

pub const e_no_mat = "no material named ";
const e_mat_param = "material parameters: base metallic roughness specular ior transmission emission strength clearcoat coat_roughness alpha density, not ";
const e_mat_full = "the scene holds 1024 materials";
pub const e_node_bad = "no such node, input, output or socket (or the link would loop)";

/// a_mat: the material of exactly this name.
pub fn argMat(v: V) Err!usize {
    const nm = try bs.argStr(v);
    return material.find(nm) orelse bs.fail(e_no_mat, nm);
}

/// a_mparam: mat_param_index (exactly: str_eq, unlike the port's form fields).
fn argParam(v: V) Err!usize {
    const nm = try bs.argStr(v);
    for (material.params, 0..) |p, k| {
        if (std.mem.eql(u8, p.name, nm)) return k;
    }
    return bs.fail(e_mat_param, nm);
}

/// a_int: cvttsd2si into 32 bits.
pub fn argInt(v: V) Err!i32 {
    return bs.ci32(try bs.argNum(v));
}

fn retMat(i: usize) Err!V {
    return bs.text(material.list[i].nameOf());
}

/// mat_new from a script: the console says so when the scene is full.
fn newMat(name: []const u8) ?usize {
    return material.new(name) orelse {
        app.log("  the scene holds 1024 materials", .{});
        return null;
    };
}

/// material(name) -> name: the material with that name, made when missing
fn materialFn(a: []const V) Err!V {
    const nm = try bs.argStr(a[0]);
    const i = material.find(nm) orelse (newMat(nm) orelse return bs.fail(e_mat_full, ""));
    app.dirty = true;
    return retMat(i);
}

/// mat_set: clamped by maxss / minss (NaN: the low end; the range's ends
/// for the infinities), a component past the parameter's: nothing.
fn matSet(i: usize, p: usize, comp: u32, x: f32) void {
    if (i >= material.count or p >= material.params.len) return;
    const pr = material.params[p];
    if (comp >= pr.comps) return;
    var v = if (x > pr.lo) x else pr.lo; // maxss
    v = if (v < pr.hi) v else pr.hi; // minss
    material.ptr(&material.list[i], p, comp).* = v;
    material.version +%= 1;
    app.dirty = true;
}

/// matset(material, parameter, value [, value, value]): colours take three
fn matset(a: []const V) Err!V {
    const mi = try argMat(a[0]);
    const p = try argParam(a[1]);
    var c: u32 = 0;
    while (c + 2 < a.len) : (c += 1) {
        const x = bs.f32of(try bs.argNum(a[c + 2]));
        matSet(mi, p, c, x);
    }
    return bs.nil;
}

/// matget(material, parameter [, component]) -> number (0: no such component)
fn matget(a: []const V) Err!V {
    gops.syncCheck(); // (instances up to date)
    var comp: i32 = 0;
    if (a.len >= 3) comp = try argInt(a[2]);
    const mi = try argMat(a[0]);
    const p = try argParam(a[1]);
    const c: u32 = @bitCast(comp);
    if (c >= material.params[p].comps) return bs.num(0);
    return bs.num(material.ptr(&material.list[mi], p, c).*);
}

/// assign(object, material): "" or anything not a text: no material
fn assign(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    var m: u16 = 0;
    if (a[1].t == .str and a[1].u.s[0] != 0) m = @intCast(try argMat(a[1]) + 1);
    scene.objects[i].mat = m;
    app.dirty = true;
    return bs.nil;
}

/// matof(object) -> its material's name, or nil
fn matof(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    const m = scene.objects[i].mat;
    if (m == 0 or m - 1 >= material.count) return bs.nil;
    return retMat(m - 1);
}

/// instance(parent [, name]) -> the new instance's name ("<parent>_Inst"
/// without one); no object gets it
fn instance(a: []const V) Err!V {
    const p = try argMat(a[0]);
    var b: [48]u8 = undefined;
    var nm: []const u8 = undefined;
    if (a.len >= 2) {
        nm = try bs.argStr(a[1]);
    } else {
        const pn = material.list[p].nameOf();
        @memcpy(b[0..pn.len], pn);
        @memcpy(b[pn.len..][0..5], "_Inst");
        nm = b[0 .. pn.len + 5];
    }
    const i = gops.instanceNew(p, nm) orelse {
        app.log("  the scene holds 1024 materials", .{});
        return bs.fail(e_mat_full, "");
    };
    app.dirty = true;
    return retMat(i);
}

/// matparam(material, name [, x, y, z, w]): a parameter node's first value,
/// or its values set (an instance's: overridden)
fn matparam(a: []const V) Err!V {
    gops.syncCheck();
    const mi = try argMat(a[0]);
    const nm = try bs.argStr(a[1]);
    const node = gops.paramNode(&material.list[mi], nm);
    if (node == 0) return bs.fail(e_node_bad, "");
    if (a.len < 3) return bs.num(sg.nodesOf(&material.list[mi])[node - 1].p[0]);
    var v: [4]f32 = undefined;
    var c: usize = 0;
    // (each value written as it is read: a bad one leaves those before it,
    // not overridden yet)
    while (c + 2 < a.len) : (c += 1) {
        v[c] = bs.f32of(try bs.argNum(a[c + 2]));
        sg.nodesMut(&material.list[mi])[node - 1].p[c] = v[c];
        material.version +%= 1;
        app.dirty = true;
    }
    gops.setParam(mi, node, v[0..c]);
    return bs.nil;
}

test "matset clamps as maxss / minss: NaN the low end, infinities the ends" {
    material.reset();
    const i = material.new("T").?;
    const p = for (material.params, 0..) |x, k| {
        if (std.mem.eql(u8, x.name, "ior")) break k;
    } else unreachable;
    matSet(i, p, 0, std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 1), material.ptr(&material.list[i], p, 0).*);
    matSet(i, p, 0, std.math.inf(f32));
    try std.testing.expectEqual(@as(f32, 3), material.ptr(&material.list[i], p, 0).*);
    matSet(i, p, 0, -std.math.inf(f32));
    try std.testing.expectEqual(@as(f32, 1), material.ptr(&material.list[i], p, 0).*);
    matSet(i, p, 1, 2); // (one component: nothing)
    try std.testing.expectEqual(@as(f32, 1), material.ptr(&material.list[i], p, 0).*);
    material.reset();
}
