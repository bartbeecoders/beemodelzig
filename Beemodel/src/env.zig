// The world: an HDRI environment (env.s), an equirectangular image from the
// scene's images. When there is one it replaces the studio sky and sun:
//   Hive     radiance lookups (bilinear), importance sampling through a 2D CDF
//            over luminance x sin(theta) (marginal rows, conditional columns),
//            with the pdf for MIS;
//   preview  irradiance from 9 spherical-harmonic coefficients (Ramamoorthi and
//            Hanrahan), reflections from a 128 x 64 blurred copy.
// Directions: y up; u = 0.5 + (atan2(x, -z) - rotation) / 2 pi, v = theta / pi
// (row 0 looks straight up).
const std = @import("std");
const m = @import("math.zig");
const images = @import("images.zig");
const image = @import("image.zig");
const A = std.heap.page_allocator;

const pi: f32 = std.math.pi;
const SMALL_W = 128;
const SMALL_H = 64;

pub var idx: u32 = 0; // image + 1, 0: the studio sky
pub var strength: f32 = 1;
pub var rotation: f32 = 0; // radians

var ready = false;
var at_version: u32 = 0;
var w: u32 = 0;
var h: u32 = 0;
var cond: []f32 = &.{}; // (w + 1) x h: columns' CDF per row
var marg: []f32 = &.{}; // h + 1: rows' CDF
var total: f32 = 0;
var small: [][3]f32 = &.{};
var sh: [9][3]f32 = undefined;

pub fn reset() void {
    idx = 0;
    strength = 1;
    rotation = 0;
    ready = false;
    at_version = 0;
}

fn tex() ?*const image.Image {
    if (idx == 0 or idx > images.count) return null;
    return &images.list[idx - 1].img;
}

/// The tables as they stand, for the GPU (gpupt.zig). After prep().
pub const Tables = struct { w: u32, h: u32, total: f32, strength: f32, rotation: f32, version: u32, px: []const [4]f32, cond: []const f32, marg: []const f32 };
pub fn tables() ?Tables {
    const t = tex() orelse return null;
    if (!ready) return null;
    return .{ .w = w, .h = h, .total = total, .strength = strength, .rotation = rotation, .version = at_version, .px = t.px, .cond = cond, .marg = marg };
}

/// Material Preview's tables, for the GPU's viewport (gview.zig). After prep().
pub const PvTables = struct { sh: *const [9][3]f32, small: []const [3]f32, strength: f32, rotation: f32, version: u32 };
pub fn previewTables() PvTables {
    return .{ .sh = &sh, .small = small, .strength = strength, .rotation = rotation, .version = at_version };
}

pub fn on() bool {
    return ready and tex() != null;
}

fn lumOf(c: [4]f32) f32 {
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

fn basis(d: m.V3) [9]f32 {
    const x = d[0];
    const y = d[1];
    const z = d[2];
    return .{ 0.282095, 0.488603 * y, 0.488603 * z, 0.488603 * x, 1.092548 * x * y, 1.092548 * y * z, 0.315392 * (3 * z * z - 1), 1.092548 * x * z, 0.546274 * (x * x - y * y) };
}

fn fromUV(u: f32, v: f32) m.V3 {
    const th = v * pi;
    const ph = (u - 0.5) * 2 * pi + rotation;
    const st = @sin(th);
    return .{ st * @sin(ph), @cos(th), -st * @cos(ph) };
}

/// The tables, when the image changed. Call before tracing or drawing a frame.
/// False: no HDRI (the studio sky). Not during a parallel run.
pub fn prep() bool {
    const t = tex() orelse {
        ready = false;
        return false;
    };
    const ver = images.list[idx - 1].version;
    if (ready and at_version == ver and w == t.w and h == t.h) return true;
    ready = false;
    w = t.w;
    h = t.h;
    if (cond.len > 0) A.free(cond);
    if (marg.len > 0) A.free(marg);
    cond = &.{};
    marg = &.{};
    const nc = (@as(usize, w) + 1) * h;
    cond = A.alloc(f32, nc) catch return false;
    marg = A.alloc(f32, @as(usize, h) + 1) catch {
        A.free(cond);
        cond = &.{};
        return false;
    };
    if (small.len == 0) small = A.alloc([3]f32, SMALL_W * SMALL_H) catch return false;
    marg[0] = 0;
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    for (0..h) |y| {
        const st = @sin((@as(f32, @floatFromInt(y)) + 0.5) / fh * pi);
        const row = cond[y * (@as(usize, w) + 1)..][0 .. @as(usize, w) + 1];
        row[0] = 0;
        var sum: f32 = 0;
        for (0..w) |x| {
            sum += @max(lumOf(t.px[y * w + x]), 0) * st;
            row[x + 1] = sum;
        }
        marg[y + 1] = marg[y] + sum;
    }
    total = marg[h];
    // the blurred copy, and the harmonics from it
    for (&sh) |*c| c.* = .{ 0, 0, 0 };
    for (0..SMALL_H) |sy| {
        for (0..SMALL_W) |sx| {
            const y0 = sy * h / SMALL_H;
            const y1 = @max((sy + 1) * h / SMALL_H, y0 + 1);
            const x0 = sx * w / SMALL_W;
            const x1 = @max((sx + 1) * w / SMALL_W, x0 + 1);
            var c: [3]f32 = .{ 0, 0, 0 };
            for (y0..y1) |y| {
                for (x0..x1) |x| {
                    const p = t.px[y * w + x];
                    for (0..3) |k| c[k] += p[k];
                }
            }
            const n: f32 = @floatFromInt((y1 - y0) * (x1 - x0));
            for (&c) |*v| v.* /= n;
            small[sy * SMALL_W + sx] = c;
            const u = (@as(f32, @floatFromInt(sx)) + 0.5) / SMALL_W;
            const v = (@as(f32, @floatFromInt(sy)) + 0.5) / SMALL_H;
            const dw = 2 * pi / SMALL_W * (pi / SMALL_H) * @sin(v * pi);
            const save = rotation;
            rotation = 0;
            const b = basis(fromUV(u, v));
            rotation = save;
            for (0..9) |q| {
                for (0..3) |k| sh[q][k] += c[k] * b[q] * dw;
            }
        }
    }
    _ = fw;
    at_version = ver;
    ready = true;
    return true;
}

fn toUV(d: m.V3) [2]f32 {
    var u = 0.5 + (std.math.atan2(d[0], -d[2]) - rotation) / (2 * pi);
    u -= @floor(u);
    return .{ u, std.math.acos(std.math.clamp(d[1], -1, 1)) / pi };
}

fn lookup(px: []const [4]f32, tw: u32, th: u32, u: f32, v: f32) m.V3 {
    const fx = u * @as(f32, @floatFromInt(tw)) - 0.5;
    const fy = std.math.clamp(v * @as(f32, @floatFromInt(th)) - 0.5, 0, @as(f32, @floatFromInt(th - 1)));
    const ix: i64 = @intFromFloat(@floor(fx));
    const iy: u32 = @intFromFloat(@floor(fy));
    const ax = fx - @floor(fx);
    const ay = fy - @floor(fy);
    const iw: i64 = tw;
    const x0: usize = @intCast(@mod(ix, iw));
    const x1: usize = @intCast(@mod(ix + 1, iw));
    const y1 = @min(iy + 1, th - 1);
    const a = px[iy * tw + x0];
    const b = px[iy * tw + x1];
    const c = px[y1 * tw + x0];
    const e = px[y1 * tw + x1];
    var o: m.V3 = undefined;
    for (0..3) |k| {
        const t0 = a[k] + (b[k] - a[k]) * ax;
        const t1 = c[k] + (e[k] - c[k]) * ax;
        o[k] = t0 + (t1 - t0) * ay;
    }
    return o;
}

/// Radiance from direction d.
pub fn rad(d: m.V3) m.V3 {
    const t = tex().?;
    const uv = toUV(d);
    return m.scale(lookup(t.px, t.w, t.h, uv[0], uv[1]), strength);
}

/// A direction by the light: u1 .. u2 pick a texel, u3 .. u4 a spot in it. pdf in solid angle.
pub const Sample = struct { wi: m.V3, pdf: f32 };

fn lowerBound(c: []const f32, x: f32) usize {
    var lo: usize = 0;
    var hi: usize = c.len - 1;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (c[mid] <= x) lo = mid else hi = mid;
    }
    return lo;
}

pub fn sample(a1: f32, a2: f32, a3: f32, a4: f32) ?Sample {
    if (total <= 0) return null;
    const y = lowerBound(marg, a1 * total);
    const row = cond[y * (@as(usize, w) + 1)..][0 .. @as(usize, w) + 1];
    const x = lowerBound(row, a2 * row[w]);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const uu = (@as(f32, @floatFromInt(x)) + a3) / fw;
    const vv = (@as(f32, @floatFromInt(y)) + a4) / fh;
    const wi = fromUV(uu, vv);
    const p = pdf(wi);
    return if (p > 0) .{ .wi = wi, .pdf = p } else null;
}

pub fn pdf(d: m.V3) f32 {
    if (total <= 0) return 0;
    const uv = toUV(d);
    const x = @min(@as(usize, @intFromFloat(uv[0] * @as(f32, @floatFromInt(w)))), w - 1);
    const y = @min(@as(usize, @intFromFloat(uv[1] * @as(f32, @floatFromInt(h)))), h - 1);
    const row = cond[y * (@as(usize, w) + 1)..][0 .. @as(usize, w) + 1];
    const f = row[x + 1] - row[x]; // lum x sin at the row's centre
    const st = @sin((@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(h)) * pi);
    if (st <= 1e-6) return 0;
    return f / total * @as(f32, @floatFromInt(w)) * @as(f32, @floatFromInt(h)) / (2 * pi * pi * st);
}

/// Preview: the irradiance / pi facing unit n.
pub fn irrPv(n0: m.V3) m.V3 {
    const n = turn(n0);
    const b = basis(n);
    const a = [9]f32{ pi, 2.0943951, 2.0943951, 2.0943951, 0.785398, 0.785398, 0.785398, 0.785398, 0.785398 };
    var o: m.V3 = .{ 0, 0, 0 };
    for (0..9) |q| {
        for (0..3) |k| o[k] += sh[q][k] * a[q] * b[q];
    }
    return .{ @max(o[0], 0) * strength / pi, @max(o[1], 0) * strength / pi, @max(o[2], 0) * strength / pi };
}

/// The harmonics hold the image unturned.
fn turn(d: m.V3) m.V3 {
    const c = @cos(-rotation);
    const s = @sin(-rotation);
    return .{ d[0] * c + d[2] * s, d[1], -d[0] * s + d[2] * c };
}

/// Preview: the blurred world along r.
pub fn specPv(r: m.V3) m.V3 {
    const uv = toUV(r);
    return m.scale(lookupSmall(uv[0], uv[1]), strength);
}

fn lookupSmall(u: f32, v: f32) m.V3 {
    const x: usize = @min(@as(usize, @intFromFloat(u * SMALL_W)), SMALL_W - 1);
    const y: usize = @min(@as(usize, @intFromFloat(v * SMALL_H)), SMALL_H - 1);
    return small[y * SMALL_W + x];
}

test "the sampler's pdf integrates to one and finds the bright spot" {
    const a = A;
    const W = 64;
    const H = 32;
    const px = try a.alloc([4]f32, W * H);
    @memset(px, .{ 0.005, 0.005, 0.005, 1 });
    for (10..14) |y| {
        for (20..26) |x| px[y * W + x] = .{ 50, 40, 30, 1 };
    }
    images.list[0] = .{ .img = .{ .w = W, .h = H, .px = px, .hdr = true } };
    images.count = 1;
    defer images.count = 0;
    reset();
    idx = 1;
    rotation = 0.7;
    try std.testing.expect(prep());
    // integral of pdf over the sphere, by rows and columns
    var sum: f64 = 0;
    const N = 512;
    for (0..N) |j| {
        const v = (@as(f32, @floatFromInt(j)) + 0.5) / N;
        for (0..N * 2) |i| {
            const u = (@as(f32, @floatFromInt(i)) + 0.5) / (N * 2);
            sum += pdf(fromUV(u, v)) * @sin(v * pi) * (2 * pi / (N * 2)) * (pi / N);
        }
    }
    try std.testing.expectApproxEqAbs(@as(f64, 1), sum, 0.01);
    // samples land where the light is, and read it back
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var bright: u32 = 0;
    for (0..2000) |_| {
        const s = sample(rnd.float(f32), rnd.float(f32), rnd.float(f32), rnd.float(f32)).?;
        try std.testing.expect(s.pdf > 0);
        try std.testing.expectApproxEqAbs(@as(f32, 1), m.len(s.wi), 1e-3);
        if (rad(s.wi)[0] > 10) bright += 1;
    }
    try std.testing.expect(bright > 1800);
    // a direction turns back to the same place
    const uv = toUV(fromUV(0.31, 0.62));
    try std.testing.expectApproxEqAbs(@as(f32, 0.31), uv[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.62), uv[1], 1e-4);
}
