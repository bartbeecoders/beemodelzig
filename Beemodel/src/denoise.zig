// Hive's denoiser (denoise.s): an edge-avoiding a-trous wavelet filter
// guided by the first-hit passes, after Dammertz et al. 2010 and SVGF
// (Schied et al. 2017):
//
//   1. the radiance is divided by the albedo (textures and colours stay
//      sharp: only the lighting is filtered);
//   2. a per-pixel variance comes from the luminance moments of the samples
//      (blurred 3 x 3 once);
//   3. five passes of a 5 x 5 B3-spline kernel with holes (steps 1, 2, 4, 8,
//      16) weigh every tap by normals (dot^64), depth (relative to the
//      distance) and luminance (relative to the remaining noise), and carry
//      the variance down as sum(w^2 var) / sum(w)^2;
//   4. multiplied by the albedo again.
//
// The noise sets the strength: a converged render passes nearly untouched.
// Pixels where the camera sees the sky are left alone. Rows go in parallel.
const std = @import("std");
const pt = @import("pt.zig");
const jobs = @import("jobs.zig");
const A = std.heap.page_allocator;

const PASSES = 5;
const lumw = [3]f32{ 0.2126, 0.7152, 0.0722 };
const h5 = [5]f32{ 0.0625, 0.25, 0.375, 0.25, 0.0625 };
const h3 = [3]f32{ 0.25, 0.5, 0.25 };
const sig_l: f32 = 4.0; // luminance: 4 sigma
const sig_z: f32 = 0.02; // depth: 2% of the distance a pixel
const eps: f32 = 1e-4;
const dmin: f32 = 0.1;

var buf_a: [][4]f32 = &.{}; // a pass's source: illumination rgb + variance
var buf_b: [][4]f32 = &.{}; // its destination
var guide: [][4]f32 = &.{}; // normal xyz, depth (0: the sky)
var step: u32 = 1;
/// The denoised beauty (linear rgb + variance), w * h; valid when `on`.
pub var out: [][4]f32 = &.{};
pub var on = false;

pub fn free() void {
    if (buf_a.len > 0) A.free(buf_a);
    if (buf_b.len > 0) A.free(buf_b);
    if (guide.len > 0) A.free(guide);
    buf_a = &.{};
    buf_b = &.{};
    guide = &.{};
    out = &.{};
    on = false;
}

/// The buffers held aside (the live view has its own).
pub const State = struct {
    buf_a: [][4]f32 = &.{},
    buf_b: [][4]f32 = &.{},
    guide: [][4]f32 = &.{},
    out: [][4]f32 = &.{},
    on: bool = false,
};

pub fn swapState(s: *State) void {
    const t = s.*;
    s.* = .{ .buf_a = buf_a, .buf_b = buf_b, .guide = guide, .out = out, .on = on };
    buf_a = t.buf_a;
    buf_b = t.buf_b;
    guide = t.guide;
    out = t.out;
    on = t.on;
}

fn lum(c: [4]f32) f32 {
    return c[0] * lumw[0] + c[1] * lumw[1] + c[2] * lumw[2];
}

fn rowInv(y: usize) f32 {
    const s = pt.row_spp[y];
    return if (s > 0) 1 / @as(f32, @floatFromInt(s)) else 0;
}

fn albedo(i: usize, k: f32) [3]f32 {
    return .{ @max(pt.alb[i][0] * k, dmin), @max(pt.alb[i][1] * k, dmin), @max(pt.alb[i][2] * k, dmin) };
}

// ---- 1. demodulate: A = (radiance / albedo, variance), G = (normal, depth) ----
fn prep(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const w = pt.fw;
    for (lo..hi) |y| {
        const k = rowInv(y);
        for (0..w) |x| {
            const i = y * w + x;
            const c = [3]f32{ pt.accum[i][0] * k, pt.accum[i][1] * k, pt.accum[i][2] * k };
            const n = pt.nrm[i];
            const z = pt.dep[i] * k;
            const nn = n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
            var al: [3]f32 = .{ 1, 1, 1 };
            if (nn > 1e-12 and z > 0) {
                const l = @sqrt(nn);
                guide[i] = .{ n[0] / l, n[1] / l, n[2] / l, z };
                al = albedo(i, k);
            } else guide[i] = .{ 0, 0, 0, 0 };
            // the variance of the mean luminance: (m2 / n - mean^2) / n, per albedo^2
            const ml = c[0] * lumw[0] + c[1] * lumw[1] + c[2] * lumw[2];
            const v = @max(pt.m2[i] * k - ml * ml, 0) * k;
            const la = al[0] * lumw[0] + al[1] * lumw[1] + al[2] * lumw[2];
            buf_a[i] = .{ c[0] / al[0], c[1] / al[1], c[2] / al[2], v / (la * la) };
        }
    }
}

// ---- 2. B = A with the variance blurred 3 x 3 (surface pixels only) ----
fn varBlur(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const w = pt.fw;
    const h = pt.fh;
    for (lo..hi) |y| {
        for (0..w) |x| {
            const i = y * w + x;
            var c = buf_a[i];
            var sv: f32 = 0;
            var sw: f32 = 0;
            for (0..3) |dj| {
                const qy = @as(i64, @intCast(y)) + @as(i64, @intCast(dj)) - 1;
                if (qy < 0 or qy >= h) continue;
                for (0..3) |di| {
                    const qx = @as(i64, @intCast(x)) + @as(i64, @intCast(di)) - 1;
                    if (qx < 0 or qx >= w) continue;
                    const q: usize = @intCast(qy * w + qx);
                    if (!(guide[q][3] > 0)) continue; // sky taps don't count
                    const wt = h3[dj] * h3[di];
                    sv += buf_a[q][3] * wt;
                    sw += wt;
                }
            }
            if (sw > 0) c[3] = sv / sw;
            buf_b[i] = c;
        }
    }
}

// ---- 3. one a-trous pass A -> B at `step` ----
fn iter(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const w = pt.fw;
    const h = pt.fh;
    const st: i64 = step;
    for (lo..hi) |y| {
        for (0..w) |x| {
            const i = y * w + x;
            const g = guide[i];
            const zp = g[3];
            const a = buf_a[i];
            if (!(zp > 0)) {
                buf_b[i] = a; // the sky: as it is
                continue;
            }
            const lp = lum(a);
            const inv_sl = 1 / (sig_l * @sqrt(@max(a[3], 0)) + eps);
            var sum: [3]f32 = .{ 0, 0, 0 };
            var svar: f32 = 0;
            var sw: f32 = 0;
            var j: i64 = -2;
            while (j <= 2) : (j += 1) {
                const qy = @as(i64, @intCast(y)) + j * st;
                if (qy < 0 or qy >= h) continue;
                var ii: i64 = -2;
                while (ii <= 2) : (ii += 1) {
                    const qx = @as(i64, @intCast(x)) + ii * st;
                    if (qx < 0 or qx >= w) continue;
                    const q: usize = @intCast(qy * w + qx);
                    const gq = guide[q];
                    if (!(gq[3] > 0)) continue;
                    // normals: max(0, n_p . n_q)^64
                    var d = g[0] * gq[0] + g[1] * gq[1] + g[2] * gq[2];
                    if (!(d > 0)) continue;
                    inline for (0..6) |_| d *= d;
                    var wt = d * h5[@intCast(j + 2)] * h5[@intCast(ii + 2)];
                    // depth: |dz| / (sigma_z z_p dist); luminance: |l_p - l_q| / sigma
                    const dist: f32 = @floatFromInt(@max(@abs(ii), @abs(j)) * step);
                    const ez = @abs(zp - gq[3]) / (dist * zp * sig_z + eps);
                    const aq = buf_a[q];
                    const el = @abs(lum(aq) - lp) * inv_sl;
                    wt *= @exp(-@min(ez + el, 30));
                    sw += wt;
                    svar += wt * wt * aq[3];
                    sum[0] += aq[0] * wt;
                    sum[1] += aq[1] * wt;
                    sum[2] += aq[2] * wt;
                }
            }
            const inv = 1 / sw;
            buf_b[i] = .{ sum[0] * inv, sum[1] * inv, sum[2] * inv, svar * inv * inv };
        }
    }
}

// ---- 4. remodulate: A.rgb *= albedo (surface pixels) ----
fn final(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const w = pt.fw;
    for (lo..hi) |y| {
        const k = rowInv(y);
        for (0..w) |x| {
            const i = y * w + x;
            if (!(guide[i][3] > 0)) continue;
            const al = albedo(i, k);
            for (0..3) |c| buf_a[i][c] *= al[c];
        }
    }
}

fn swap() void {
    const t = buf_a;
    buf_a = buf_b;
    buf_b = t;
}

/// Denoise the render's beauty into `out`. False: no memory (nothing changed).
pub fn run() bool {
    const n = @as(usize, pt.fw) * pt.fh;
    if (n == 0) return false;
    if (buf_a.len != n) {
        free();
        buf_a = A.alloc([4]f32, n) catch return false;
        buf_b = A.alloc([4]f32, n) catch {
            free();
            return false;
        };
        guide = A.alloc([4]f32, n) catch {
            free();
            return false;
        };
    }
    var dummy: u8 = 0;
    jobs.parallelFor(pt.fh, 4, &dummy, prep);
    jobs.parallelFor(pt.fh, 4, &dummy, varBlur);
    swap();
    for (0..PASSES) |k| {
        step = @as(u32, 1) << @intCast(k);
        jobs.parallelFor(pt.fh, 4, &dummy, iter);
        swap();
    }
    jobs.parallelFor(pt.fh, 4, &dummy, final);
    out = buf_a;
    on = true;
    return true;
}
