// BeeScript's signed-distance shapes (script.s b_ssphere .. b_sclear; sdf.zig):
// numbers are node ids. Shapes are centred at the origin (sbox's sizes are
// full sizes, scyl runs along Y, storus turns about Y, sgrid takes the struts'
// diameter); sunion / ssub / sisect join two with an optional smoothing radius,
// sshell makes a wall centred on the surface, smove / srot place one (radians,
// Euler XYZ as objects), sdist asks the distance at a point, smesh makes a
// closed mesh object of one, sclear forgets them all. Values may be expression
// texts with units.
const std = @import("std");
const bs = @import("bscript.zig");
const bc = @import("bs_cad.zig");
const scene = @import("scene.zig");
const sdf = @import("sdf.zig");
const A = @import("alloc.zig").A;

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "ssphere", .f = ssphere },
    .{ .name = "sbox", .f = sbox },
    .{ .name = "scyl", .f = scyl },
    .{ .name = "storus", .f = storus },
    .{ .name = "sgyroid", .f = sgyroid },
    .{ .name = "sgrid", .f = sgrid },
    .{ .name = "sunion", .f = sunion },
    .{ .name = "ssub", .f = ssub },
    .{ .name = "sisect", .f = sisect },
    .{ .name = "sshell", .f = sshell },
    .{ .name = "smove", .f = smove },
    .{ .name = "srot", .f = srot },
    .{ .name = "sdist", .f = sdist },
    .{ .name = "smesh", .f = smesh },
    .{ .name = "sclear", .f = sclear },
};

const e_sdf = "shape: ";
const e_sdf_id = "no such shape";

/// sd_args: values first .. first + n as floats into p.
fn args(a: []const V, first: usize, n: usize, p: *[6]f32) Err!void {
    for (0..n) |k| p[k] = bs.f32of(try bc.aVal(a[first + k]));
}

/// sd_id: a valid node id.
fn id(v: V) Err!u32 {
    const x = try bc.aInt(v);
    if (x <= 0 or @as(u32, @intCast(x)) >= sdf.count()) return bs.fail(e_sdf_id, "");
    return @intCast(x);
}

/// sd_ret: the id as a number, or why there is none.
fn ret(k: u32) Err!V {
    if (k == 0) return bs.fail(e_sdf, sdf.err);
    return bs.num(@floatFromInt(k));
}

fn make(t: u32, a: u32, b: u32, p: *const [6]f32) Err!V {
    return ret(sdf.new(t, a, b, p, null, null));
}

fn leaf(a: []const V, t: u32, n: usize) Err!V {
    var p: [6]f32 = @splat(0);
    try args(a, 0, n, &p);
    if (t == sdf.S_BOX) {
        for (0..3) |c| p[c] = p[c] * 0.5;
    }
    if (t == sdf.S_GRID) p[1] = p[1] * 0.5; // a diameter -> radius
    return make(t, 0, 0, &p);
}

/// ssphere(r)
fn ssphere(a: []const V) Err!V {
    return leaf(a, sdf.S_SPHERE, 1);
}
/// sbox(x, y, z [, rounding]): full sizes
fn sbox(a: []const V) Err!V {
    return leaf(a, sdf.S_BOX, a.len);
}
/// scyl(r, height): along Y
fn scyl(a: []const V) Err!V {
    return leaf(a, sdf.S_CYL, 2);
}
/// storus(R, r): about Y
fn storus(a: []const V) Err!V {
    return leaf(a, sdf.S_TORUS, 2);
}
/// sgyroid(cell, wall)
fn sgyroid(a: []const V) Err!V {
    return leaf(a, sdf.S_GYROID, 2);
}
/// sgrid(cell, strut diameter)
fn sgrid(a: []const V) Err!V {
    return leaf(a, sdf.S_GRID, 2);
}

/// sunion / ssub / sisect(a, b [, smoothing radius])
fn boolOp(a: []const V, t: u32) Err!V {
    var p: [6]f32 = @splat(0);
    const x = try id(a[0]);
    const y = try id(a[1]);
    if (a.len >= 3) try args(a, 2, 1, &p);
    return make(t, x, y, &p);
}
fn sunion(a: []const V) Err!V {
    return boolOp(a, sdf.S_UNION);
}
fn ssub(a: []const V) Err!V {
    return boolOp(a, sdf.S_UNION + 1);
}
fn sisect(a: []const V) Err!V {
    return boolOp(a, sdf.S_UNION + 2);
}

/// sshell(a, thickness): a wall centred on the surface
fn sshell(a: []const V) Err!V {
    var p: [6]f32 = @splat(0);
    const x = try id(a[0]);
    try args(a, 1, 1, &p);
    return make(sdf.S_SHELL, x, 0, &p);
}

/// smove(a, x, y, z) / srot(a, rx, ry, rz)
fn xform(a: []const V, rotate: bool) Err!V {
    var p: [6]f32 = @splat(0);
    const x = try id(a[0]);
    try args(a, 1, 3, &p);
    return ret(sdf.moved(x, .{ p[0], p[1], p[2] }, rotate));
}
fn smove(a: []const V) Err!V {
    return xform(a, false);
}
fn srot(a: []const V) Err!V {
    return xform(a, true);
}

/// sdist(a, x, y, z) -> the signed distance there
fn sdist(a: []const V) Err!V {
    var p: [6]f32 = @splat(0);
    const x = try id(a[0]);
    try args(a, 1, 3, &p);
    return bs.num(sdf.eval(x, p[0], p[1], p[2]));
}

/// smesh(name, a [, cells along the largest side, default 64, 512 at most])
/// -> the new mesh object's name
fn smesh(a: []const V) Err!V {
    const nm = try bs.argStr(a[0]);
    const x = try id(a[1]);
    var cells: i32 = 64;
    if (a.len >= 3) {
        cells = try bc.aInt(a[2]);
        if (@as(u32, @bitCast(cells)) > 512) cells = 512; // (unsigned: negative too)
    }
    var out = sdf.mesh(x, cells) orelse return bs.fail(e_sdf, sdf.err);
    defer out.deinit();
    const nq = out.loops.items.len / 3;
    const poff = A.alloc(u32, nq + 1) catch return bs.fail(bc.e_ft_full, "");
    defer A.free(poff);
    for (poff, 0..) |*q, k| q.* = @intCast(k * 3);
    const mi = scene.addMesh(out.verts.items, poff, out.loops.items) orelse return bs.fail(bc.e_ft_full, "");
    const i = bc.objNew(.mesh, nm, mi, bc.mesh_colour) orelse {
        scene.freeMeshSlot(mi);
        return bs.fail(bc.e_ft_full, "");
    };
    return bs.text(scene.objects[i].name());
}

/// sclear(): forget every shape node
fn sclear(_: []const V) Err!V {
    sdf.clear();
    return bs.nil;
}

test "shape ids: 1 .. count - 1" {
    const T = std.testing;
    sdf.clear();
    const p: [6]f32 = .{ 1, 0, 0, 0, 0, 0 };
    const s = sdf.new(sdf.S_SPHERE, 0, 0, &p, null, null);
    try T.expectEqual(@as(u32, 1), try id(bs.num(1)));
    try T.expectEqual(s, try id(bs.num(1.9)));
    try T.expectError(error.Script, id(bs.num(0)));
    try T.expectError(error.Script, id(bs.num(2)));
    try T.expectError(error.Script, id(bs.num(std.math.nan(f64))));
    sdf.clear();
}
