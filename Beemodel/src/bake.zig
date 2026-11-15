// Baking maps (bake.s). bake(low, high, kind, image) fills an image through the
// low mesh's UVs. Hive's BVH is built over the high mesh alone; every texel
// inside a UV triangle of the low mesh gets its world point and smoothed normal,
// and a ray from a little outside along the normal, back through the surface,
// finds the high mesh (within the cage distance: 5% of the low mesh's size
// unless given). From the hit:
//    normal     the high normal in the low triangle's tangent frame (from its
//               UVs), 0.5 + n / 2 (no hit: flat, 0.5 0.5 1)
//    ao         ambient occlusion: 48 cosine-weighted rays from the hit within
//               the cage distance x 4; the unblocked share
//    curvature  how the high surface's smooth normals turn around the hit
//               (8 probes at 1% of the size): 0.5 flat, lighter convex, darker
//               concave; probes falling off an edge count as convex
// Material kinds need no high mesh: the graph is evaluated at every texel into
// base colour (sRGB, alpha), occlusion roughness metallic, tangent-space normal
// and emission (sRGB). Texels no triangle covers are filled from their
// neighbours (8 passes), so island borders do not show seams. Rows run in
// parallel; the workers allocate nothing.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const mods = @import("mods.zig");
const hive = @import("hive.zig");
const preview = @import("preview.zig");
const material = @import("material.zig");
const images = @import("images.zig");
const jobs = @import("jobs.zig");
const sg = @import("shgraph.zig");
const gops = @import("graphops.zig");
const pthist = @import("pthist.zig");
const A = std.heap.page_allocator;

pub const Kind = enum(u32) { normal, ao, curvature, base, orm, nrm, emit };
const AO_N = 48;
const CV_N = 8;
const dirs = [8][2]f32{ .{ 1, 0 }, .{ 0.7071068, 0.7071068 }, .{ 0, 1 }, .{ -0.7071068, 0.7071068 }, .{ -1, 0 }, .{ -0.7071068, -0.7071068 }, .{ 0, -1 }, .{ 0.7071068, -0.7071068 } };

const Job = struct {
    me: *const scene.Mesh,
    wpos: []const m.V3,
    wnrm: []const [3]m.V3,
    kind: Kind,
    dist: f32,
    diag: f32,
    w: u32,
    h: u32,
    /// 0xAARRGGBB, top row first
    pix: []u32,
    mask: []u8,
    rec: ?*const material.Material,
    count: std.atomic.Value(u32) = .init(0),
};

fn unit(v: m.V3) m.V3 {
    const l = @max(@sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]), 1.0e-12);
    const k = 1 / l;
    return .{ v[0] * k, v[1] * k, v[2] * k };
}
fn dot(a: m.V3, b: m.V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
/// The vector made orthogonal to unit n, unit.
fn orth(v: m.V3, n: m.V3) m.V3 {
    const d = dot(v, n);
    return unit(.{ v[0] - n[0] * d, v[1] - n[1] * d, v[2] - n[2] * d });
}
fn byte(x0: f32) u32 {
    const x = @min(@max(if (x0 == x0) x0 else 0, 0), 1);
    return @intFromFloat(x * 255 + 0.5);
}
fn linToSrgb(x: f32) f32 {
    if (!(x > 0.0031308)) return x * 12.92;
    return @as(f32, @floatCast(std.math.pow(f64, x, 1.0 / 2.4))) * 1.055 - 0.055;
}

/// An orthonormal frame about unit n.
fn basis(n: m.V3) [2]m.V3 {
    var t: m.V3 = undefined;
    if (@abs(n[0]) >= 0.5) {
        t = .{ -n[2], 0, n[0] };
    } else t = .{ 0, n[2], -n[1] };
    t = unit(t);
    return .{ t, .{ n[1] * t[2] - n[2] * t[1], n[2] * t[0] - n[0] * t[2], n[0] * t[1] - n[1] * t[0] } };
}

/// Two numbers in [0, 1) from a texel and a ray (a hash: repeatable).
pub fn rand2(x: u32, y: u32, i: u32) [2]f32 {
    var a = (x *% 0x27d4eb2d) ^ (y *% 0x165667b1) ^ (i *% 0x9e3779b9);
    a ^= a >> 15;
    a *%= 0x2c1b3c6d;
    a ^= a >> 12;
    a *%= 0x297a2d39;
    const b = (a >> 15) ^ a;
    const c = b *% 0x85ebca6b;
    const d = (c >> 13) ^ c;
    return .{ @as(f32, @floatFromInt(b >> 8)) * 5.9604645e-8, @as(f32, @floatFromInt(d >> 8)) * 5.9604645e-8 };
}

/// The high triangle's corner normals at (u, v), unit.
fn highNormal(h: hive.Hit) m.V3 {
    const n = hive.norms[h.tri];
    const w = 1 - h.u - h.v;
    var r: m.V3 = undefined;
    for (0..3) |c| r[c] = n[0][c] * w + n[1][c] * h.u + n[2][c] * h.v;
    return unit(r);
}

/// What bk_job knows of a low triangle.
const Tri = struct {
    p: [3]m.V3,
    n: [3]m.V3,
    t: m.V3,
    b: m.V3,
    uv: [6]f32,
    bary: [3]f32 = undefined,
    ti: usize,
};

fn oTexel(j: *const Job, x: u32, y: u32, tr: *const Tri) void {
    var p: m.V3 = undefined;
    var n0: m.V3 = undefined;
    for (0..3) |c| {
        var a: f32 = 0;
        var b: f32 = 0;
        for (0..3) |k| {
            a += tr.p[k][c] * tr.bary[k];
            b += tr.n[k][c] * tr.bary[k];
        }
        p[c] = a;
        n0[c] = b;
    }
    const n = unit(n0);
    const v: u32 = switch (j.kind) {
        .base, .orm, .nrm, .emit => matTexel(j, tr, p, n),
        else => rayTexel(j, x, y, tr, p, n),
    };
    const i = @as(usize, y) * j.w + x;
    j.pix[i] = v;
    j.mask[i] = 1;
    _ = @constCast(&j.count).fetchAdd(1, .monotonic);
}

fn rayTexel(j: *const Job, x: u32, y: u32, tr: *const Tri, p: m.V3, n: m.V3) u32 {
    var o: m.V3 = undefined;
    var d: m.V3 = undefined;
    for (0..3) |c| {
        o[c] = n[c] * j.dist + p[c];
        d[c] = -n[c];
    }
    const hit = hive.trace(o, d, j.dist + j.dist);
    switch (j.kind) {
        .normal => {
            const h = hit orelse return 0xff8080ff; // (no hit: flat)
            const hn = highNormal(h);
            const t = orth(tr.t, n);
            const b = orth(tr.b, n);
            var v: u32 = 0xff;
            for ([3]m.V3{ t, b, n }) |a| v = (v << 8) | byte(dot(hn, a) * 0.5 + 0.5);
            return v;
        },
        .ao => {
            const h = hit orelse return 0xffffffff;
            const hn = highNormal(h);
            var q: m.V3 = undefined;
            for (0..3) |c| q[c] = d[c] * h.t + o[c];
            const f = basis(hn);
            var free: u32 = 0;
            var i: u32 = 0;
            while (i < AO_N) : (i += 1) {
                const rr = rand2(x, y, i);
                const r = @sqrt(rr[0]); // cosine: r = sqrt(u1), phi = 2pi u2
                const ph = rr[1] * 6.2831853;
                const sy = @as(f32, @floatCast(@sin(@as(f64, ph)))) * r;
                const cx = @as(f32, @floatCast(@cos(@as(f64, ph)))) * r;
                const z = @sqrt(@max(1 - r * r, 1.0e-12));
                var rd: m.V3 = undefined;
                var ro: m.V3 = undefined;
                for (0..3) |c| {
                    rd[c] = f[0][c] * cx + f[1][c] * sy + hn[c] * z;
                    ro[c] = hn[c] * 1.0e-3 * j.dist + q[c]; // from a hair above the hit
                }
                if (!hive.occluded(ro, rd, j.dist * 4)) free += 1;
            }
            return grey(@as(f32, @floatFromInt(free)) / AO_N);
        },
        else => {
            const h = hit orelse return 0xff808080;
            const hn = highNormal(h);
            var q: m.V3 = undefined;
            for (0..3) |c| q[c] = d[c] * h.t + o[c];
            const f = basis(hn);
            const r = j.diag * 0.01;
            var sum: f32 = 0;
            for (dirs) |dd| {
                var so: m.V3 = undefined;
                var sd: m.V3 = undefined;
                for (0..3) |c| {
                    so[c] = (f[0][c] * dd[0] + f[1][c] * dd[1] + hn[c]) * r + q[c];
                    sd[c] = -hn[c];
                }
                var v: f32 = 1; // (missed: fell off, convex)
                if (hive.trace(so, sd, r * 3)) |h2| {
                    const n2 = highNormal(h2);
                    v = 0;
                    for (0..3) |c| v += (n2[c] - hn[c]) * (f[0][c] * dd[0] + f[1][c] * dd[1]);
                }
                sum += v;
            }
            return grey(sum * 0.5 + 0.5);
        },
    }
}

fn grey(v: f32) u32 {
    return byte(v) * 0x010101 | 0xff000000;
}

/// The material's texel for the kind.
fn matTexel(j: *const Job, tr: *const Tri, p: m.V3, n: m.V3) u32 {
    const rec = j.rec.?;
    const me = j.me;
    const t3 = me.tris[tr.ti];
    const p0 = me.verts[t3[0]];
    var sc = sg.SC{
        .p0o = p0,
        .e1o = m.sub(me.verts[t3[1]], p0),
        .e2o = m.sub(me.verts[t3[2]], p0),
        .u = tr.bary[1],
        .v = tr.bary[2],
        .pu = m.sub(tr.p[1], tr.p[0]),
        .pv = m.sub(tr.p[2], tr.p[0]),
        .n = n,
        .wv = n,
        .wp = p,
        .uvp = &tr.uv,
    };
    var cp: material.Material = undefined;
    sg.copyValues(&cp, rec);
    _ = sg.shade(rec, material.list[0..material.count], &sc, &cp, false);
    const fl = sc.flags;
    switch (j.kind) {
        .orm => {
            const o: f32 = if (fl & (1 << sg.PIN_AO) != 0) sg.rtAo(&cp) else 1;
            return 0xff000000 | byte(o) << 16 | byte(cp.roughness) << 8 | byte(cp.metallic);
        },
        .nrm => {
            if (fl & (1 << sg.PIN_NORMAL) == 0) return 0xff8080ff; // (no normal of its own: flat)
            const b = unit(sc.n);
            var v: u32 = 0xff;
            for ([3]m.V3{ orth(tr.t, n), orth(tr.b, n), n }) |a| v = (v << 8) | byte(dot(b, a) * 0.5 + 0.5);
            return v;
        },
        .emit => {
            var v: u32 = 0xff;
            for (cp.emission) |e| v = (v << 8) | byte(linToSrgb(clamp01(e * cp.strength)));
            return v;
        },
        else => {
            var v = byte(if (fl & (1 << sg.PIN_MASK) != 0) sg.rtMask(&cp) else cp.alpha);
            for (cp.base) |e| v = (v << 8) | byte(linToSrgb(clamp01(e)));
            return v;
        },
    }
}

fn clamp01(x: f32) f32 {
    return if (x < 1) (if (x > 0) x else 0) else 1;
}

/// cvttss2si for a value that came from a mesh: out of range gives a bound the
/// clipping below throws away.
fn trunc(x: f32) i32 {
    if (!(x > -2.0e9 and x < 2.0e9)) return if (x > 0) std.math.maxInt(i32) else std.math.minInt(i32);
    return @intFromFloat(x);
}

fn jobRun(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *const Job = @ptrCast(@alignCast(ctx));
    for (lo..hi) |item| tri(j, item >> 4, item & 15);
}

/// A low triangle's texels in one band of rows.
fn tri(j: *const Job, ti: usize, band: usize) void {
    const me = j.me;
    const uv = triUvs(me, ti) orelse return;
    const t3 = me.tris[ti];
    var tr = Tri{ .p = undefined, .n = j.wnrm[ti], .t = undefined, .b = undefined, .uv = uv, .ti = ti };
    for (0..3) |k| tr.p[k] = j.wpos[t3[k]];
    // the tangent frame from the UVs
    const du1 = uv[2] - uv[0];
    const dv1 = uv[3] - uv[1];
    const du2 = uv[4] - uv[0];
    const dv2 = uv[5] - uv[1];
    const det = du1 * dv2 - du2 * dv1;
    if (!(@abs(det) > 1.0e-12)) return;
    const inv = 1 / det;
    const e1 = m.sub(tr.p[1], tr.p[0]);
    const e2 = m.sub(tr.p[2], tr.p[0]);
    for (0..3) |c| {
        tr.t[c] = (e1[c] * dv2 - e2[c] * dv1) * inv;
        tr.b[c] = (e2[c] * du1 - e1[c] * du2) * inv;
    }
    // texels: the box of the UV triangle (x = u w, y = (1 - v) h)
    const wf: f32 = @floatFromInt(j.w);
    const hf: f32 = @floatFromInt(j.h);
    var s: [3][2]f32 = undefined;
    for (0..3) |k| s[k] = .{ uv[k * 2] * wf, (1 - uv[k * 2 + 1]) * hf };
    const area = (s[1][0] - s[0][0]) * (s[2][1] - s[0][1]) - (s[2][0] - s[0][0]) * (s[1][1] - s[0][1]);
    if (!(@abs(area) > 1.0e-12)) return;
    var x0 = @max(trunc(@min(s[0][0], @min(s[1][0], s[2][0]))), 0);
    const x1 = @min(trunc(@max(s[0][0], @max(s[1][0], s[2][0]))), @as(i32, @intCast(j.w)) - 1);
    var y0 = @max(trunc(@min(s[0][1], @min(s[1][1], s[2][1]))), 0);
    var y1 = @min(trunc(@max(s[0][1], @max(s[1][1], s[2][1]))), @as(i32, @intCast(j.h)) - 1);
    const h: usize = j.h;
    y0 = @max(y0, @as(i32, @intCast(band * h >> 4)));
    y1 = @min(y1, @as(i32, @intCast((band + 1) * h >> 4)) - 1);
    x0 = @max(x0, 0);
    var y = y0;
    while (y <= y1) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x = x0;
        pix: while (x <= x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            for (0..3) |k| {
                const a = (k + 1) % 3;
                const b = (a + 1) % 3;
                const w = ((s[b][0] - s[a][0]) * (py - s[a][1]) - (s[b][1] - s[a][1]) * (px - s[a][0])) / area;
                tr.bary[k] = w;
                if (!(w >= -1.0e-4)) continue :pix;
            }
            oTexel(j, @intCast(x), @intCast(y), &tr);
        }
    }
}

/// Texels no triangle covers take their covered neighbours' average, 8 rings out.
fn dilate(j: *Job) void {
    const w: usize = j.w;
    const h: usize = j.h;
    for (0..8) |_| {
        for (0..h) |y| {
            for (0..w) |x| {
                const i = y * w + x;
                if (j.mask[i] != 0) continue;
                var n: u32 = 0;
                var sum = [3]u32{ 0, 0, 0 };
                const near = [4][2]isize{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
                for (near) |d| {
                    const nx = @as(isize, @intCast(x)) + d[0];
                    const ny = @as(isize, @intCast(y)) + d[1];
                    if (nx < 0 or ny < 0 or nx >= w or ny >= h) continue;
                    const q = @as(usize, @intCast(ny)) * w + @as(usize, @intCast(nx));
                    if (j.mask[q] != 1) continue; // (covered before this pass)
                    const p = j.pix[q];
                    sum[0] += (p >> 16) & 255;
                    sum[1] += (p >> 8) & 255;
                    sum[2] += p & 255;
                    n += 1;
                }
                if (n == 0) continue;
                j.pix[i] = 0xff000000 | (sum[0] / n) << 16 | (sum[1] / n) << 8 | (sum[2] / n);
                j.mask[i] = 2;
            }
        }
        for (j.mask) |*c| {
            if (c.* == 2) c.* = 1;
        }
    }
}

/// tri_uvs: a triangle's corners' UVs: u0 v0 u1 v1 u2 v2; null without UVs.
pub fn triUvs(me: *const scene.Mesh, ti: usize) ?[6]f32 {
    if (me.uv.len == 0 or me.uv.len != me.loops.len) return null;
    const p = me.tri_poly[ti];
    const s = me.poff[p];
    const e = me.poff[p + 1];
    var out: [6]f32 = undefined;
    for (me.tris[ti], 0..) |v, k| {
        var l = s;
        while (l < e and me.loops[l] != v) l += 1;
        if (l >= e) l = s;
        out[k * 2] = me.uv[l][0];
        out[k * 2 + 1] = me.uv[l][1];
    }
    return out;
}

/// The texels baked; null: the low mesh has no UVs, the image is not 8-bit, or
/// no memory. Into image `im`; `rec`: the material (material kinds).
pub fn bake(low: usize, high: usize, kind: Kind, im: usize, dist0: f32, rec: ?*const material.Material) ?u32 {
    const me = mods.of(low) orelse return null;
    if (me.uv.len == 0 or me.tris.len == 0 or im >= images.count) return null;
    const e = &images.list[im];
    if (e.b8.len == 0) return null;
    const mtx = scene.world(low);
    const wpos = A.alloc(m.V3, me.verts.len) catch return null;
    defer A.free(wpos);
    var lo: m.V3 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    var hi: m.V3 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (me.verts, wpos) |v, *p| {
        p.* = m.xform(mtx, v);
        for (0..3) |c| {
            lo[c] = @min(lo[c], p[c]);
            hi[c] = @max(hi[c], p[c]);
        }
    }
    // the corner normals of the triangles in the world: what is within 30 degrees
    // of what goes by the object's scale too
    var world_me = me.*;
    world_me.verts = wpos;
    var kept: preview.Kept = .{};
    defer preview.freeKept(&kept);
    const cn = preview.cornerNormalsIn(&kept, &world_me) orelse return null;
    const wnrm = A.alloc([3]m.V3, me.tris.len) catch return null;
    defer A.free(wnrm);
    for (cn, wnrm) |c, *o| {
        for (0..3) |k| o[k] = unit(c[k]);
    }
    const d = m.sub(hi, lo);
    const diag = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    const dist = if (dist0 > 0) dist0 else diag * 0.05;
    const n = @as(usize, e.img.w) * e.img.h;
    const pix = A.alloc(u32, n) catch return null;
    defer A.free(pix);
    const layers = @import("layers.zig");
    const buf = if (quiet) e.b8 else layers.target(e); // (where: the image, its active layer)
    for (buf, pix) |b, *p| p.* = @as(u32, b[3]) << 24 | @as(u32, b[0]) << 16 | @as(u32, b[1]) << 8 | b[2];
    const mask = A.alloc(u8, n) catch return null;
    defer A.free(mask);
    @memset(mask, 0);
    const uses_hive = @backingInt(kind) < @backingInt(Kind.base);
    if (uses_hive) {
        const rn = @import("render.zig");
        if (rn.active) rn.stopNow();
        hive.only = high;
        const ok = hive.build();
        hive.only = null;
        if (!ok) return null;
    }
    defer if (uses_hive) {
        hive.free();
        @import("pt.zig").scene_gen +%= 1; // (the scene's BVH again next time)
    };
    if (uses_hive and hive.tris.len == 0) return 0;
    const before = if (quiet) null else pthist.snap(im); // (one texture paint undo step)
    var j = Job{ .me = me, .wpos = wpos, .wnrm = wnrm, .kind = kind, .dist = dist, .diag = diag, .w = e.img.w, .h = e.img.h, .pix = pix, .mask = mask, .rec = rec };
    jobs.parallelFor(me.tris.len * 16, 4, &j, jobRun);
    dilate(&j);
    for (pix, buf) |p, *b| b.* = .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p), @truncate(p >> 24) };
    if (quiet) return j.count.load(.monotonic);
    if (e.layers != null) layers.rect(e, 0, 0, e.img.w - 1, e.img.h - 1); // (done: composite)
    images.bytesChanged(im);
    if (before) |b| pthist.commit(im, b);
    return j.count.load(.monotonic);
}

/// bk_quiet: straight into the image's bytes (no layers, no undo, nothing
/// else told: the glTF export's bakes into an image of its own).
pub var quiet = false;

/// `bake_material`: kind 0 base 1 orm 2 normal 3 emissive.
pub fn bakeMaterial(ob: usize, kind: u32, im: usize) ?u32 {
    gops.syncCheck();
    const ma = material.of(&scene.objects[ob]) orelse return null;
    return bake(ob, ob, @fromBackingInt(@intCast(kind + 3)), im, 0, ma);
}

const t_ = std.testing;

test "the hash behind AO's rays is the original's" {
    // (bk_rand2 worked out by hand)
    const r = rand2(3, 5, 7);
    try t_.expectEqual(@as(f32, 10210726) * 5.9604645e-8, r[0]);
    try t_.expectEqual(@as(f32, 4491589) * 5.9604645e-8, r[1]);
    const q = rand2(100, 200, 47);
    try t_.expectEqual(@as(f32, 1434086) * 5.9604645e-8, q[0]);
}
