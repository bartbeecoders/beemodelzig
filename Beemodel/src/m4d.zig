//! 4x4 matrices of doubles (row-major, column vectors) as blend.s keeps them
//! for its imports (.blend, USD): products, one-axis turns, Euler angles in
//! Blender's six orders, quaternions, and taking a matrix apart into place,
//! turn and scale (bl_place). Bit for bit with the original: the same
//! operations in the same order, the x87's sine, cosine and arctangent.
const std = @import("std");
const nb = @import("nurbs.zig");

pub const M = [16]f64;

pub const ident: M = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
const tiny: f64 = 1.0e-12;
const eps: f64 = 1.0e-4;

/// m4_mul: a b (each sum from +0.0, as the original adds)
pub fn mul(a: M, b: M) M {
    var o: M = undefined;
    for (0..16) |i| {
        const r = i >> 2;
        const c = i & 3;
        var s: f64 = 0.0;
        for (0..4) |k| s += a[r * 4 + k] * b[k * 4 + c];
        o[i] = s;
    }
    return o;
}

/// m4_axisrot: one rotation about axis 0..2 (radians)
pub fn axisRot(axis: u32, angle: f64) M {
    var o = ident;
    const sc = nb.dsincos(angle);
    const a: usize = (axis + 1) % 3;
    const b: usize = (a + 1) % 3;
    o[a * 5] = sc[1];
    o[b * 5] = sc[1];
    o[a * 4 + b] = -sc[0];
    o[b * 4 + a] = sc[0];
    return o;
}

const eul_order = [6][3]u8{ .{ 0, 1, 2 }, .{ 0, 2, 1 }, .{ 1, 0, 2 }, .{ 1, 2, 0 }, .{ 2, 0, 1 }, .{ 2, 1, 0 } };

/// m4_euler: float angles, Blender's rotation mode 1..6 (XYZ XZY YXZ YZX ZXY
/// ZYX - the first axis turns first: R = R3 R2 R1)
pub fn euler(ang: [3]f32, mode: u32) M {
    const o = eul_order[mode - 1];
    const r1 = axisRot(o[0], ang[o[0]]);
    const r2 = axisRot(o[1], ang[o[1]]);
    const r21 = mul(r2, r1);
    const r3 = axisRot(o[2], ang[o[2]]);
    return mul(r3, r21);
}

/// m4_quat: float w x y z, normalized (identity when ~0)
pub fn quat(q: [4]f32) M {
    var w: f64 = q[0];
    var x: f64 = q[1];
    var y: f64 = q[2];
    var z: f64 = q[3];
    var n = w * w;
    n += x * x;
    n += y * y;
    n += z * z;
    if (!(n > tiny)) return ident;
    n = @sqrt(n);
    w /= n;
    x /= n;
    y /= n;
    z /= n;
    var o = ident;
    o[0] = 1.0 - (y * y + z * z) * 2.0;
    o[5] = 1.0 - (x * x + z * z) * 2.0;
    o[10] = 1.0 - (x * x + y * y) * 2.0;
    const xy = x * y;
    const wz = w * z;
    o[1] = (xy - wz) * 2.0;
    o[4] = (xy + wz) * 2.0;
    const xz = x * z;
    const wy = w * y;
    o[2] = (xz + wy) * 2.0;
    o[8] = (xz - wy) * 2.0;
    const yz = y * z;
    const wx = w * x;
    o[6] = (yz - wx) * 2.0;
    o[9] = (yz + wx) * 2.0;
    return o;
}

pub const Split = struct { r: [9]f64, s: [3]f64, ortho: bool };

/// m4_split: R (rows) and the scales; ortho when the axes are orthogonal (no
/// shear). A mirror flips the first scale.
pub fn split(m: M) Split {
    var o: Split = undefined;
    for (0..3) |c| {
        var l = m[c] * m[c];
        l += m[c + 4] * m[c + 4];
        l += m[c + 8] * m[c + 8];
        o.s[c] = @sqrt(l);
    }
    var d = (m[5] * m[10] - m[6] * m[9]) * m[0];
    d -= (m[4] * m[10] - m[6] * m[8]) * m[1];
    d += (m[4] * m[9] - m[5] * m[8]) * m[2];
    if (!(d >= 0)) o.s[0] = -o.s[0];
    for (0..3) |c| {
        var s = o.s[c];
        if (!(@abs(s) > tiny)) s = 1.0;
        for (0..3) |r| o.r[r * 3 + c] = m[r * 4 + c] / s;
    }
    o.ortho = true;
    const pairs = [3][2]usize{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 2 } };
    for (pairs) |p| {
        var dot: f64 = 0.0;
        for (0..3) |r| dot += o.r[r * 3 + p[0]] * o.r[r * 3 + p[1]];
        if (@abs(dot) > eps) o.ortho = false;
    }
    return o;
}

/// r3_euler: X Y Z (radians, floats) with R = Rz Ry Rx
pub fn r3Euler(r: [9]f64) [3]f32 {
    const ny = -r[6];
    const c = @sqrt(maxsd(1.0 - ny * ny, 0.0));
    const y = nb.datan2(ny, c);
    const x = nb.datan2(r[7], r[8]);
    const z = nb.datan2(r[3], r[0]);
    return .{ @floatCast(x), @floatCast(y), @floatCast(z) };
}

/// maxsd a, b: a when a > b, else b (NaN: b)
fn maxsd(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}

pub const Place = struct { loc: [3]f32, rot: [3]f32, scl: [3]f32 };

/// bl_place: a matrix (our axes) as place, Euler XYZ (radians) and scale
pub fn place(m: M) Place {
    const sp = split(m);
    return .{
        .loc = .{ @floatCast(m[3]), @floatCast(m[7]), @floatCast(m[11]) },
        .rot = r3Euler(sp.r),
        .scl = .{ @floatCast(sp.s[0]), @floatCast(sp.s[1]), @floatCast(sp.s[2]) },
    };
}

test "m4d: products, turns, quaternions, taking apart" {
    const t = std.testing;
    const r = axisRot(2, std.math.pi / 2.0); // Z: x -> y
    try t.expectApproxEqAbs(@as(f64, 1), r[4], 1e-15);
    try t.expectApproxEqAbs(@as(f64, -1), r[1], 1e-15);
    const p = mul(r, ident);
    try t.expectEqualSlices(f64, &r, &p);
    const q = quat(.{ 0.70710677, 0, 0, 0.70710677 });
    try t.expectApproxEqAbs(@as(f64, 1), q[4], 1e-7);
    var m = mul(r, ident);
    m[0] *= 2;
    m[4] *= 2;
    m[8] *= 2;
    m[3] = 5;
    const pl = place(m);
    try t.expectApproxEqAbs(@as(f32, 2), pl.scl[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), pl.rot[2], 1e-6);
    try t.expectEqual(@as(f32, 5), pl.loc[0]);
    var sh = ident;
    sh[1] = 0.5; // a shear
    try t.expect(!split(sh).ortho);
    try t.expect(split(m).ortho);
    const e = euler(.{ 0.3, 0.2, 0.1 }, 1);
    const back = r3Euler(split(e).r);
    try t.expectApproxEqAbs(@as(f32, 0.3), back[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.1), back[2], 1e-6);
}
