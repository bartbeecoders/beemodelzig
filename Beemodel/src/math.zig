// Small vector / matrix helpers for the software 3D viewport (Y up, right-handed).
const std = @import("std");
pub const V3 = [3]f32;

pub fn add(a: V3, b: V3) V3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
pub fn sub(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
pub fn scale(a: V3, s: f32) V3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
pub fn dot(a: V3, b: V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
pub fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
pub fn len(a: V3) f32 {
    return @sqrt(dot(a, a));
}
pub fn norm(a: V3) V3 {
    const l = len(a);
    return if (l > 1e-9) scale(a, 1.0 / l) else a;
}

pub const deg = 3.14159265358979 / 180.0;

/// Row-major 4x4 matrix; vectors are columns (p' = M * p).
pub const M4 = [16]f32;

pub fn identity() M4 {
    return .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
}

pub fn mul(a: M4, b: M4) M4 {
    var r: M4 = undefined;
    for (0..4) |i| {
        for (0..4) |j| {
            var s: f32 = 0;
            for (0..4) |k| s += a[i * 4 + k] * b[k * 4 + j];
            r[i * 4 + j] = s;
        }
    }
    return r;
}

pub fn xform(m: M4, p: V3) V3 {
    return .{
        m[0] * p[0] + m[1] * p[1] + m[2] * p[2] + m[3],
        m[4] * p[0] + m[5] * p[1] + m[6] * p[2] + m[7],
        m[8] * p[0] + m[9] * p[1] + m[10] * p[2] + m[11],
    };
}

/// Rotate a direction (no translation).
pub fn xdir(m: M4, p: V3) V3 {
    return .{
        m[0] * p[0] + m[1] * p[1] + m[2] * p[2],
        m[4] * p[0] + m[5] * p[1] + m[6] * p[2],
        m[8] * p[0] + m[9] * p[1] + m[10] * p[2],
    };
}

/// Translation * RotZ * RotY * RotX * Scale, rotation in degrees.
pub fn trs(t: V3, r: V3, s: V3) M4 {
    const cx = @cos(r[0] * deg);
    const sx = @sin(r[0] * deg);
    const cy = @cos(r[1] * deg);
    const sy = @sin(r[1] * deg);
    const cz = @cos(r[2] * deg);
    const sz = @sin(r[2] * deg);
    const rx: M4 = .{ 1, 0, 0, 0, 0, cx, -sx, 0, 0, sx, cx, 0, 0, 0, 0, 1 };
    const ry: M4 = .{ cy, 0, sy, 0, 0, 1, 0, 0, -sy, 0, cy, 0, 0, 0, 0, 1 };
    const rz: M4 = .{ cz, -sz, 0, 0, sz, cz, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const sc: M4 = .{ s[0], 0, 0, 0, 0, s[1], 0, 0, 0, 0, s[2], 0, 0, 0, 0, 1 };
    var m = mul(rz, mul(ry, mul(rx, sc)));
    m[3] = t[0];
    m[7] = t[1];
    m[11] = t[2];
    return m;
}

// --- 3x3 rotations (row-major) -------------------------------------------

pub const M3 = [9]f32;

pub fn mul3(a: M3, b: M3) M3 {
    var r: M3 = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            var s: f32 = 0;
            for (0..3) |k| s += a[i * 3 + k] * b[k * 3 + j];
            r[i * 3 + j] = s;
        }
    }
    return r;
}

pub fn apply3(a: M3, p: V3) V3 {
    return .{
        a[0] * p[0] + a[1] * p[1] + a[2] * p[2],
        a[3] * p[0] + a[4] * p[1] + a[5] * p[2],
        a[6] * p[0] + a[7] * p[1] + a[8] * p[2],
    };
}

/// RotZ * RotY * RotX of Euler angles in degrees (the order trs uses).
pub fn eulerMat(r: V3) M3 {
    const cx = @cos(r[0] * deg);
    const sx = @sin(r[0] * deg);
    const cy = @cos(r[1] * deg);
    const sy = @sin(r[1] * deg);
    const cz = @cos(r[2] * deg);
    const sz = @sin(r[2] * deg);
    return .{
        cy * cz, sx * sy * cz - cx * sz, cx * sy * cz + sx * sz,
        cy * sz, sx * sy * sz + cx * cz, cx * sy * sz - sx * cz,
        -sy,     sx * cy,                cx * cy,
    };
}

/// Euler angles in degrees of a rotation matrix (inverse of eulerMat).
pub fn matEuler(a: M3) V3 {
    const sy = std.math.clamp(-a[6], -1.0, 1.0);
    const y = std.math.asin(sy);
    if (@abs(sy) < 0.99999) {
        return .{ std.math.atan2(a[7], a[8]) / deg, y / deg, std.math.atan2(a[3], a[0]) / deg };
    }
    // gimbal lock: put everything in Z
    return .{ 0, y / deg, std.math.atan2(-a[1], a[4]) / deg };
}

/// Rotation by `angle` radians about the unit vector `ax`.
pub fn axisAngle(ax: V3, angle: f32) M3 {
    const c = @cos(angle);
    const s = @sin(angle);
    const t = 1 - c;
    const x = ax[0];
    const y = ax[1];
    const z = ax[2];
    return .{
        t * x * x + c,     t * x * y - s * z, t * x * z + s * y,
        t * x * y + s * z, t * y * y + c,     t * y * z - s * x,
        t * x * z - s * y, t * y * z + s * x, t * z * z + c,
    };
}

pub fn lerp(a: V3, b: V3, t: f32) V3 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

// --- affine 4x4 helpers ----------------------------------------------------

/// The inverse of an affine matrix (rotation, scale, translation).
pub fn inverseAffine(a: M4) M4 {
    const det = a[0] * (a[5] * a[10] - a[6] * a[9]) - a[1] * (a[4] * a[10] - a[6] * a[8]) + a[2] * (a[4] * a[9] - a[5] * a[8]);
    const d = if (@abs(det) < 1e-20) 1e-20 else det;
    const id = 1.0 / d;
    var r: M4 = identity();
    r[0] = (a[5] * a[10] - a[6] * a[9]) * id;
    r[1] = (a[2] * a[9] - a[1] * a[10]) * id;
    r[2] = (a[1] * a[6] - a[2] * a[5]) * id;
    r[4] = (a[6] * a[8] - a[4] * a[10]) * id;
    r[5] = (a[0] * a[10] - a[2] * a[8]) * id;
    r[6] = (a[2] * a[4] - a[0] * a[6]) * id;
    r[8] = (a[4] * a[9] - a[5] * a[8]) * id;
    r[9] = (a[1] * a[8] - a[0] * a[9]) * id;
    r[10] = (a[0] * a[5] - a[1] * a[4]) * id;
    const t: V3 = .{ a[3], a[7], a[11] };
    r[3] = -(r[0] * t[0] + r[1] * t[1] + r[2] * t[2]);
    r[7] = -(r[4] * t[0] + r[5] * t[1] + r[6] * t[2]);
    r[11] = -(r[8] * t[0] + r[9] * t[1] + r[10] * t[2]);
    return r;
}

pub const TRS = struct { loc: V3, rot: V3, scl: V3 };

/// Location, Euler rotation (degrees) and scale of an affine matrix
/// (no shear: a parent's non-uniform scale under a rotation is approximated).
pub fn decompose(a: M4) TRS {
    var s: V3 = .{
        len(.{ a[0], a[4], a[8] }),
        len(.{ a[1], a[5], a[9] }),
        len(.{ a[2], a[6], a[10] }),
    };
    for (&s) |*x| {
        if (x.* < 1e-9) x.* = 1e-9;
    }
    // a mirrored matrix: one negative scale
    const det = a[0] * (a[5] * a[10] - a[6] * a[9]) - a[1] * (a[4] * a[10] - a[6] * a[8]) + a[2] * (a[4] * a[9] - a[5] * a[8]);
    if (det < 0) s[0] = -s[0];
    const R = M3{ a[0] / s[0], a[1] / s[1], a[2] / s[2], a[4] / s[0], a[5] / s[1], a[6] / s[2], a[8] / s[0], a[9] / s[1], a[10] / s[2] };
    return .{ .loc = .{ a[3], a[7], a[11] }, .rot = matEuler(R), .scl = s };
}

/// The rotation part of an affine matrix (columns normalised).
pub fn rotationOf(a: M4) M3 {
    const t = decompose(a);
    return eulerMat(t.rot);
}
