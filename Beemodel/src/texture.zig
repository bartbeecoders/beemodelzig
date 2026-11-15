// Texture lookups (texture.s): bilinear, repeating, sampled from what the
// original keeps: 8-bit sources as bytes (colours through the sRGB table, data
// as plain fractions, alpha always a fraction), HDR as linear floats. Box
// projection for meshes without UVs. Nothing here allocates: the tracer's
// workers come through it.
const std = @import("std");
const m = @import("math.zig");
const image = @import("image.zig");
const images = @import("images.zig");

const inv255: f32 = 0.00392156863;

/// The sRGB decoding table (linear value per byte), as tex_init makes it.
pub const lut: [256]f32 = blk: {
    @setEvalBranchQuota(100000);
    var tab: [256]f32 = undefined;
    for (&tab, 0..) |*e, i| e.* = srgbToLinC(@as(f32, @floatFromInt(i)) * inv255);
    break :blk tab;
};

fn srgbToLinC(c: f32) f32 {
    if (c <= 0.04045) return c * 0.0773993808;
    return @floatCast(std.math.pow(f64, c * 0.9478672986 + 0.0521327014, @as(f32, 2.4))); // (texture.s: 2.4 as a float; this gives its x87 bits for every byte)
}

/// The stored 0..1 value of a linear value from an 8-bit image (tx_unlin):
/// normal maps are data, not colour.
pub fn unlin(x0: f32) f32 {
    var lo: u32 = 0;
    var hi: u32 = 255;
    while (hi - lo > 1) {
        const mid = (lo + hi) >> 1;
        if (!(x0 >= lut[mid])) hi = mid else lo = mid;
    }
    const d = lut[hi] - lut[lo];
    var x = x0 - lut[lo];
    x = if (x > 0) x else 0; // (maxss: a NaN goes)
    x /= d;
    x = if (x < 1) x else 1;
    return (x + @as(f32, @floatFromInt(lo))) * inv255;
}

/// floor(x) mod n and the fraction.
fn floorWrap(x0: f32, n: i32, frac: *f32) i32 {
    var x = if (x0 > -1.0e7) x0 else -1.0e7; // (keep it in int range)
    x = if (x < 1.0e7) x else 1.0e7;
    var i: i32 = @intFromFloat(x);
    var f: f32 = @floatFromInt(i);
    if (f > x) {
        i -= 1;
        f = @floatFromInt(i);
    }
    frac.* = x - f;
    return @mod(i, n);
}

fn texel(e: *const images.Entry, x: usize, y: usize, data: bool) [4]f32 {
    const i = y * e.img.w + x;
    if (e.b8.len == 0) {
        const p = e.img.px[i];
        return .{ p[0], p[1], p[2], 1 };
    }
    const b = e.b8[i];
    const a = @as(f32, @floatFromInt(b[3])) * inv255;
    if (data) return .{ @as(f32, @floatFromInt(b[0])) * inv255, @as(f32, @floatFromInt(b[1])) * inv255, @as(f32, @floatFromInt(b[2])) * inv255, a };
    return .{ lut[b[0]], lut[b[1]], lut[b[2]], a };
}

pub const DATA: u32 = 1; // 8-bit texels as fractions, no sRGB curve
pub const CLAMP: u32 = 2; // clamped to the edge, not repeating

/// tex_sample4: bilinear, repeating; v runs up the image.
pub fn sample4(e: *const images.Entry, u: f32, v: f32, mode: u32) [4]f32 {
    const wf: f32 = @floatFromInt(e.img.w);
    const hf: f32 = @floatFromInt(e.img.h);
    var fx0 = u * wf - 0.5;
    var fy0 = (1 - v) * hf - 0.5;
    if (mode & CLAMP != 0) {
        fx0 = if (fx0 > 0) fx0 else 0;
        fy0 = if (fy0 > 0) fy0 else 0;
        fx0 = if (fx0 < wf - 1) fx0 else wf - 1;
        fy0 = if (fy0 < hf - 1) fy0 else hf - 1;
    }
    var fx: f32 = 0;
    var fy: f32 = 0;
    const x0: usize = @intCast(floorWrap(fx0, @intCast(e.img.w), &fx));
    const y0: usize = @intCast(floorWrap(fy0, @intCast(e.img.h), &fy));
    const x1 = if (x0 + 1 < e.img.w) x0 + 1 else 0;
    const y1 = if (y0 + 1 < e.img.h) y0 + 1 else 0;
    const data = mode & DATA != 0;
    const a = texel(e, x0, y0, data);
    const b = texel(e, x1, y0, data);
    const c = texel(e, x0, y1, data);
    const d = texel(e, x1, y1, data);
    var out: [4]f32 = undefined;
    for (0..4) |k| {
        const top = a[k] + (b[k] - a[k]) * fx;
        const bot = c[k] + (d[k] - c[k]) * fx;
        out[k] = top + (bot - top) * fy;
    }
    return out;
}

/// box_uv: each triangle takes the two axes across its face normal's largest
/// component (object space): u0 v0 u1 v1 u2 v2.
pub fn boxUv(p0: m.V3, p1: m.V3, p2: m.V3) [6]f32 {
    const n = m.cross(m.sub(p1, p0), m.sub(p2, p0));
    var axis: usize = 0;
    var best = @abs(n[0]);
    var s = n[0];
    if (@abs(n[1]) > best) {
        axis = 1;
        best = @abs(n[1]);
        s = n[1];
    }
    if (@abs(n[2]) > best) {
        axis = 2;
        s = n[2];
    }
    const flip = !(s >= 0); // flip u when the face looks down its axis
    var out: [6]f32 = undefined;
    for ([3]m.V3{ p0, p1, p2 }, 0..) |p, k| {
        // x: (-z, y) / (z, y)   y: (x, -z) / (x, z)   z: (x, y) / (-x, y)
        const uv: [2]f32 = switch (axis) {
            0 => .{ if (flip) p[2] else -p[2], p[1] },
            1 => .{ p[0], if (flip) p[2] else -p[2] },
            else => .{ if (flip) -p[0] else p[0], p[1] },
        };
        out[k * 2] = uv[0];
        out[k * 2 + 1] = uv[1];
    }
    return out;
}

const t = std.testing;

test "the table is the image decoder's curve; unlin undoes it" {
    for (0..256) |i| {
        try t.expectApproxEqAbs(image.srgbToLinear(@as(f32, @floatFromInt(i)) / 255.0), lut[i], 2e-6);
        try t.expectApproxEqAbs(@as(f32, @floatFromInt(i)) / 255.0, unlin(lut[i]), 1e-5);
    }
}

test "bilinear, repeating, v up; data skips the curve" {
    var e = images.Entry{ .img = .{ .w = 2, .h = 2, .px = &.{}, .hdr = false } };
    var b = [_][4]u8{ .{ 0, 0, 0, 255 }, .{ 255, 0, 0, 255 }, .{ 0, 128, 0, 0 }, .{ 255, 128, 0, 0 } };
    e.b8 = &b;
    // (0.25, 0.75) is the first texel's centre: the top row
    try t.expectEqual(@as(f32, 0), sample4(&e, 0.25, 0.75, 0)[0]);
    try t.expectApproxEqAbs(@as(f32, 1), sample4(&e, 0.75, 0.75, 0)[0], 1e-6);
    // half way between them, and the same a whole repeat on
    const mid = sample4(&e, 0.5, 0.75, 0)[0];
    try t.expectApproxEqAbs(@as(f32, 0.5), mid, 1e-6);
    try t.expectEqual(mid, sample4(&e, 1.5, -2.25, 0)[0]);
    // the bottom row's green: linear, then its byte as data
    try t.expectApproxEqAbs(lut[128], sample4(&e, 0.25, 0.25, 0)[1], 1e-6);
    try t.expectApproxEqAbs(128.0 / 255.0, sample4(&e, 0.25, 0.25, DATA)[1], 1e-6);
    // alpha is a fraction either way
    try t.expectEqual(@as(f32, 0), sample4(&e, 0.25, 0.25, 0)[3]);
    // the seam wraps: u = 0 is half way between the last and first texels
    try t.expectApproxEqAbs(@as(f32, 0.5), sample4(&e, 0, 0.75, 0)[0], 1e-6);
    // clamped it stays on the edge
    try t.expectEqual(@as(f32, 0), sample4(&e, -3, 0.75, CLAMP)[0]);
}

test "box projection: each side of a cube" {
    const uv = boxUv(.{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 0, 1 }); // +x
    try t.expectEqualSlices(f32, &.{ -0.0, 0, -0.0, 1, -1, 0 }, &uv);
    const uz = boxUv(.{ 0, 0, -1 }, .{ 0, 1, -1 }, .{ 1, 0, -1 }); // -z: u flipped
    try t.expectEqualSlices(f32, &.{ -0.0, 0, -0.0, 1, -1, 0 }, &uz);
}
