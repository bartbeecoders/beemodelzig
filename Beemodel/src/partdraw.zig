// Particles in the viewport (particles.s stage P2, pt_draw).
//
// Points and sprites: every particle projected in parallel (by block) into a
// buffer of 64-bit keys a pixel - the depth (1/z, nearest smallest) over the
// colour - by an atomic minimum, so the picture is the same on any number of
// threads; then the rows composited over the rasterizer's colour and depth.
// A point is a square of its pixels (1..8); a sprite a disc of its size (its
// end size over its life), shaded like a ball; the colour along its ramp.
//
// Objects mode: an instance block of the particles drawn by inst.zig
// (pt_iblock, inst_draw_ib).
const std = @import("std");
const gfx = @import("gfx.zig");
const pt = @import("particles.zig");
const rc = @import("rbcore.zig");
const jobs = @import("jobs.zig");
const A = @import("alloc.zig").A;

const V4 = rc.V4;
const dot3 = rc.dot3;

/// The last draw (ms), the particles it drew.
pub var ms: f32 = 0;
pub var drawn: u32 = 0;

var buf: []u64 = &.{};
var w: u32 = 0;
var h: u32 = 0;
var x0: i32 = 0;
var y0: i32 = 0;
var cx: f32 = 0;
var cy: f32 = 0;
var foc: f32 = 0;
var near: f32 = 0;
var eye: V4 = @splat(0);
var right: V4 = @splat(0);
var up: V4 = @splat(0);
var fwd: V4 = @splat(0);
var list: [pt.NBLK]u32 = undefined;
var nlist: u32 = 0;
var bsys: [pt.NBLK]u32 = undefined;

/// How each system is drawn this time (SR_DMODE ...): -1 not.
const DSys = struct { mode: i32 = -1, c1: u32 = 0, c2: u32 = 0, ramp: u32 = 0, se: f32 = 1, px: i32 = 1 };
var ds: [pt.MAX]DSys = @splat(.{});

pub fn reset() void {
    ms = 0;
    drawn = 0;
}

/// ramp: a colour along the way from c1 to c2 (t 0..1).
pub fn ramp(c1: u32, c2: u32, t: f32) u32 {
    var o: u32 = 0;
    var s: u5 = 16;
    while (true) {
        const a: i32 = @intCast(c1 >> s & 255);
        const b: i32 = @intCast(c2 >> s & 255);
        const d: f32 = @floatFromInt(b - a);
        const r = a +% pt.cvtn(d * t);
        o |= @as(u32, @bitCast(r)) << s;
        if (s == 0) break;
        s -= 8;
    }
    return o;
}

/// shade: a colour times k (0..1), each channel cut down.
fn shade(c: u32, k: f32) u32 {
    var o: u32 = 0;
    var s: u5 = 16;
    while (true) {
        const ch: f32 = @floatFromInt(c >> s & 255);
        o |= @as(u32, @bitCast(pt.cvtt(ch * k))) << s;
        if (s == 0) break;
        s -= 8;
    }
    return o;
}

/// pd_put: the nearest wins.
inline fn put(x: i32, y: i32, key: u64) void {
    const ux: u32 = @bitCast(x);
    const uy: u32 = @bitCast(y);
    if (ux >= w or uy >= h) return;
    const p = &buf[@as(usize, uy) * w + ux];
    var cur = @atomicLoad(u64, p, .monotonic);
    while (key < cur) {
        cur = @cmpxchgWeak(u64, p, cur, key, .monotonic, .monotonic) orelse return;
    }
}

/// pt_draw: the particles into the viewport being drawn (after the meshes:
/// its colour and depth). cam: the viewport's (eye, right, up, fwd, f, cx, cy).
pub fn draw(cv: *gfx.Canvas, r: gfx.Rect, cam: anytype, near_plane: f32) void {
    drawn = 0;
    if (pt.ns == 0 or r.w <= 0 or r.h <= 0) return;
    const zb = cv.zbuf orelse return;
    const t_0 = rc.nowNs();
    w = @intCast(r.w);
    h = @intCast(r.h);
    x0 = r.x;
    y0 = r.y;
    cx = cam.cx - @as(f32, @floatFromInt(r.x));
    cy = cam.cy - @as(f32, @floatFromInt(r.y));
    foc = cam.f;
    near = near_plane;
    eye = .{ cam.eye[0], cam.eye[1], cam.eye[2], 0 };
    right = .{ cam.right[0], cam.right[1], cam.right[2], 0 };
    up = .{ cam.up[0], cam.up[1], cam.up[2], 0 };
    fwd = .{ cam.fwd[0], cam.fwd[1], cam.fwd[2], 0 };
    var any = false;
    nlist = 0;
    for (pt.sr[0..pt.ns], 0..) |*s, si| {
        ds[si] = .{};
        if (s.n == 0) continue;
        const rec = pt.nth(s.uid, s.k) orelse continue;
        ds[si] = .{ .mode = @bitCast(rec.draw), .c1 = rec.color, .c2 = rec.color2, .ramp = rec.ramp, .se = rec.sizeend, .px = pt.cvtt(rc.minss(rc.maxss(rec.px, 1.0), 8.0)) };
        drawn += s.n;
        if (rec.draw == 2) { // objects: instances (pt_iblock, inst_draw_ib)
            @import("inst.zig").drawParticles(cv, r, cam, near_plane, @intCast(si), rec.color);
            continue;
        }
        any = true;
        for (pt.sblk[si][0..s.nb]) |bk| {
            list[nlist] = bk;
            bsys[bk] = @intCast(si);
            nlist += 1;
        }
    }
    if (any) {
        const n = @as(usize, w) * h;
        if (buf.len < n) {
            if (buf.len > 0) A.free(buf);
            buf = &.{};
            buf = A.alloc(u64, n) catch return;
        }
        @memset(buf[0..n], std.math.maxInt(u64));
        var dummy: u8 = 0;
        jobs.parallelFor(nlist, 1, &dummy, splat);
        // over the picture: nearer than what is drawn there
        for (0..h) |yy| {
            const row = buf[yy * w ..][0..w];
            const o = (@as(usize, @intCast(y0)) + yy) * @as(usize, @intCast(cv.w)) + @as(usize, @intCast(x0));
            for (row, 0..) |key, xx| {
                if (key == std.math.maxInt(u64)) continue;
                const iz: f32 = @bitCast(~@as(u32, @truncate(key >> 32)));
                if (!(iz > zb[o + xx])) continue;
                zb[o + xx] = iz;
                cv.px[o + xx] = @truncate(key);
            }
        }
    }
    ms = @as(f32, @floatFromInt(@as(i64, @intCast(rc.nowNs() - t_0)))) * 0.001 * 0.001;
}

/// dj_splat: listed blocks begin..end: each particle as a point (a few
/// pixels) or a sprite (a shaded disc of its size), its colour along its ramp.
fn splat(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |li| {
        const bk = list[li];
        const d = &ds[bsys[bk]];
        const xs = pt.arr(bk, pt.A_X);
        const ys = pt.arr(bk, pt.A_Y);
        const zs = pt.arr(bk, pt.A_Z);
        for (0..pt.bn[bk]) |j| {
            const q = rc.andXyz(V4{ xs[j], ys[j], zs[j], 0 } - eye);
            const z = dot3(q, fwd);
            if (!(z >= near)) continue;
            const iz = 1.0 / z;
            const s = iz * foc;
            const x = dot3(q, right) * s + cx;
            const y = cy - dot3(q, up) * s;
            var t = pt.arr(bk, pt.A_AGE)[j] / pt.arr(bk, pt.A_LIFE)[j];
            t = rc.maxss(t, 0);
            t = rc.minss(t, 1.0);
            var c = d.c1;
            if (d.ramp & 1 != 0) c = ramp(d.c1, d.c2, t);
            c &= 0xffffff;
            const zkey = @as(u64, ~@as(u32, @bitCast(iz))) << 32;
            if (d.mode != 1) {
                // a square of px pixels
                const px = d.px;
                const hx = pt.cvtt(x) -% (px >> 1);
                const hy = pt.cvtt(y) -% (px >> 1);
                var b: i32 = 0;
                while (b < px) : (b += 1) {
                    var a: i32 = 0;
                    while (a < px) : (a += 1) put(hx +% a, hy +% b, zkey | c);
                }
                continue;
            }
            // a disc: its radius in pixels
            var rr = (d.se - 1.0) * t + 1.0;
            rr = rr * pt.arr(bk, pt.A_SIZE)[j];
            rr = rr * 0.5;
            rr = rr * s;
            rr = rc.minss(rr, 48.0);
            if (!(rr > 0.75)) {
                put(pt.cvtt(x), pt.cvtt(y), zkey | c);
                continue;
            }
            const r2 = rr * rr;
            var yy = pt.cvtt(y - rr);
            const y1 = pt.cvtt(y + rr);
            const xa = pt.cvtt(x - rr);
            const xb = pt.cvtt(x + rr);
            while (yy <= y1) : (yy += 1) {
                var xx = xa;
                while (xx <= xb) : (xx += 1) {
                    var dx = @as(f32, @floatFromInt(xx)) + 0.5;
                    dx = dx - x;
                    dx = dx * dx;
                    var dy = @as(f32, @floatFromInt(yy)) + 0.5;
                    dy = dy - y;
                    dy = dy * dy;
                    const d2 = dx + dy;
                    if (d2 > r2) continue;
                    var k = @sqrt(1.0 - d2 / r2);
                    k = k * 0.45 + 0.55;
                    put(xx, yy, zkey | shade(c, k));
                }
            }
        }
    }
}

test "ramp and shade" {
    try std.testing.expectEqual(@as(u32, 0xff0000), ramp(0xff0000, 0x0000ff, 0));
    try std.testing.expectEqual(@as(u32, 0x0000ff), ramp(0xff0000, 0x0000ff, 1));
    try std.testing.expectEqual(@as(u32, 0x7f7f7f), shade(0xffffff, 0.5));
}
