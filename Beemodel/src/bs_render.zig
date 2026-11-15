// BeeScript's render and image builtins (script.s b_vgeo, b_vgstat, b_probe ..
// b_lmsample, b_gpu, b_render, b_rframes, b_image, b_imgsize, b_imgpixel): the
// cluster DAGs, the light probes and the lightmap asked, the GPU helper's
// counters, the path tracer into PNG files, images loaded and read. Arguments
// are read in the original's order (its errors come in that order).
const std = @import("std");
const bs = @import("bscript.zig");
const bsc = @import("bs_scene.zig");
const scene = @import("scene.zig");
const m = @import("math.zig");
const images = @import("images.zig");
const vgeo = @import("vgeo.zig");
const probe = @import("probe.zig");
const lightmap = @import("lightmap.zig");
const pt = @import("pt.zig");
const gpu = @import("gpu.zig");
const gpupt = @import("gpupt.zig");
const files = @import("files.zig");
const app = @import("app.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "vgeo", .f = vgeoB },
    .{ .name = "vgstat", .f = vgstat },
    .{ .name = "probe", .f = probeB },
    .{ .name = "probeinfo", .f = probeinfo },
    .{ .name = "probesample", .f = probesample },
    .{ .name = "lightmap", .f = lightmapB },
    .{ .name = "lmsample", .f = lmsample },
    .{ .name = "gpu", .f = gpuB },
    .{ .name = "render", .f = renderB },
    .{ .name = "render_frames", .f = renderFrames },
    .{ .name = "image", .f = imageB },
    .{ .name = "imgsize", .f = imgsize },
    .{ .name = "imgpixel", .f = imgpixel },
};

const e_op_perm = "permission denied (the user has not given agents file access): ";
const e_image = "image: could not load ";
const e_no_image = "no image called ";
const e_render = "render: could not render or write ";

/// cvttsd2si of an argument (a_num then the truncation).
fn int(v: V) Err!i32 {
    return bs.ci32(try bs.argNum(v));
}

fn f32n(x: f32) V {
    return bs.num(x);
}

/// Agents need file access (the files tier) for what reads or writes files.
fn mayFiles(what: []const u8) Err!void {
    if (bs.byAgent() and @import("agent.zig").tier < 2) return bs.fail(e_op_perm, what);
}

// ---- cluster DAGs -----------------------------------------------------------------------

/// vgeo(name, k): the object's cluster LOD DAG (vg_info); 0 for anything but a
/// mesh object, and for k a DAG does not answer.
fn vgeoB(a: []const V) Err!V {
    const i = try bsc.argObj(a[0]);
    const o = &scene.objects[i];
    const base: ?*const scene.Mesh = if (o.kind.isMesh()) scene.meshOfObj(i) else null;
    const k = try int(a[1]);
    const me = base orelse return bs.num(0);
    const shown = @import("mods.zig").of(i);
    if (k == 0) return bs.num(@floatFromInt(vgeo.stateOf(me, shown)));
    const d = vgeo.of(me) orelse (if (shown) |e| vgeo.of(e) else null) orelse return bs.num(0);
    const ku: u32 = @bitCast(k);
    if (ku == 12) return bs.num(if (vgeo.check(d)) 1 else 0);
    if (ku >= 400) return bs.num(@floatFromInt(levelCount(d, ku)));
    if (ku >= 100) { // 100 + L, 200 + L, 300 + L: level L's triangles, clusters, largest error
        const h = d.hdr();
        const L = ku % 100;
        if (L >= h.nlv) return bs.num(0);
        const lv = &h.lv[L];
        return switch (ku / 100) {
            1 => bs.num(@floatFromInt(lv.tris)),
            2 => bs.num(@floatFromInt(lv.n)),
            else => f32n(lv.err),
        };
    }
    return f32n(vgeo.info(d, ku));
}

/// 500 + L: groups of level L; 400 + L: level L's clusters under 32 triangles.
fn levelCount(d: *const vgeo.Dag, k: u32) u32 {
    var n: u32 = 0;
    if (k >= 500) {
        for (d.groups()) |*g| n += @intFromBool(g.level == k - 500);
    } else {
        for (d.clusters()) |*c| n += @intFromBool(c.level == k - 400 and c.nt < 32);
    }
    return n;
}

/// vgstat(k): the last frame's drawing through cluster DAGs
fn vgstat(a: []const V) Err!V {
    return f32n(@import("vgdraw.zig").stat(@bitCast(try int(a[0]))));
}

// ---- light probes ------------------------------------------------------------------------

/// probe(k): 0 probes, 1 baked, 2 irradiance volumes, 3 reflection probes, 4 the
/// last bake (ms), 5 its paths, 6 grid points in all (pb_stat)
fn probeB(a: []const V) Err!V {
    const k = try int(a[0]);
    var n: i32 = 0;
    switch (k) {
        4 => n = @truncate(probe.last_ms),
        5 => n = @truncate(@as(i64, @bitCast(probe.last_paths))),
        else => {
            const b = probe.cur orelse return bs.num(0);
            for (b.p[0..b.n]) |*p| {
                switch (k) {
                    0 => n += 1,
                    1 => n += @intFromBool(p.spp != 0),
                    2 => n += @intFromBool(p.kind == probe.IRRADIANCE),
                    3 => n += @intFromBool(p.kind == probe.REFLECTION),
                    6 => if (p.kind == probe.IRRADIANCE) {
                        n +%= @bitCast(p.res[0] *% p.res[1] *% p.res[2]);
                    },
                    else => {},
                }
            }
        },
    }
    return f32n(@floatFromInt(n));
}

/// probeinfo(n, what): probe n (from 1): 0 kind, 1 samples baked, 2-4 centre,
/// 5-7 half size, 8-10 grid points; nil when there is no such probe
fn probeinfo(a: []const V) Err!V {
    const n = (try int(a[0])) -% 1;
    const w = try int(a[1]);
    if (n < 0) return bs.nil;
    const b = probe.cur orelse return bs.nil;
    if (@as(u32, @intCast(n)) >= b.n) return bs.nil;
    const p = &b.p[@intCast(n)];
    const x: f32 = switch (w) {
        0 => @floatFromInt(p.kind),
        1 => @floatFromInt(p.spp),
        2...4 => p.cen[@intCast(w - 2)],
        5...7 => p.half[@intCast(w - 5)],
        8...10 => @floatFromInt(p.res[@intCast(w - 8)]),
        else => 0,
    };
    return f32n(x);
}

/// probesample(what, x, y, z, dx, dy, dz, c [, rays]): colour channel c of 0 the
/// probes' irradiance / pi for that normal, 1 a reflection probe's radiance
/// along that direction, 2 the irradiance / pi traced now (the reference);
/// nil when no probe covers the point
fn probesample(a: []const V) Err!V {
    const what = try int(a[0]);
    var q: [6]f32 = undefined;
    for (0..6) |k| q[k] = bs.f32of(try bs.argNum(a[1 + k]));
    const c = try int(a[7]);
    var rays: i32 = 1024;
    if (a.len >= 9) rays = try int(a[8]);
    const p: m.V3 = .{ q[0], q[1], q[2] };
    // the direction, unit (its length at least 1e-12: sqrtps, maxps)
    var d: m.V3 = .{ q[3], q[4], q[5] };
    const l = @max(@sqrt((d[0] * d[0] + d[1] * d[1]) + d[2] * d[2]), 1.0e-12);
    d = .{ d[0] / l, d[1] / l, d[2] / l };
    const rgb: m.V3 = switch (what) {
        1 => probe.spec(p, d),
        2 => traced(p, d, rays),
        else => probe.irr(p, d),
    } orelse return bs.nil;
    if (c < 0 or c >= 3) return bs.nil;
    return f32n(rgb[@intCast(c)]);
}

/// The irradiance / pi at p about unit normal n: cosine-weighted rays from 1 mm
/// above it through the path tracer's scene (made first), averaged.
fn traced(p: m.V3, n: m.V3, rays_: i32) ?m.V3 {
    if (!probe.prep()) return null;
    const o = m.add(p, m.scale(n, 0.001));
    const ax: m.V3 = if (@abs(n[0]) >= 0.5) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    var t = m.cross(ax, n);
    const tl = @sqrt((t[0] * t[0] + t[1] * t[1]) + t[2] * t[2]);
    t = .{ t[0] / tl, t[1] / tl, t[2] / tl };
    const b = m.cross(n, t);
    var r = pt.Rng.init(0x2545F4914F6CDD1D, 0x9B5);
    var sum: m.V3 = .{ 0, 0, 0 };
    const rays: u32 = @bitCast(rays_); // (the original's unsigned count)
    var k: u32 = 0;
    while (k < rays) : (k += 1) {
        const rr = @sqrt(r.f());
        const ph = r.f() * 6.2831855;
        const x = rr * @cos(ph);
        const y = rr * @sin(ph);
        const z = @sqrt(@max(1 - rr * rr, 0));
        const dir: m.V3 = .{ t[0] * x + b[0] * y + n[0] * z, t[1] * x + b[1] * y + n[1] * z, t[2] * x + b[2] * y + n[2] * z };
        var aux = pt.Aux{};
        const L = pt.traceRay(o, dir, &aux, &r);
        if (L[0] == L[0] and L[1] == L[1] and L[2] == L[2]) sum = m.add(sum, L);
    }
    const nr = @max(@as(f32, @floatFromInt(rays)), 1);
    return .{ sum[0] / nr, sum[1] / nr, sum[2] / nr };
}

// ---- the lightmap --------------------------------------------------------------------------

/// lightmap(k): 0 objects, 1 width, 2 texels baked, 3 the bake (ms), 4 rays a
/// texel; 0 when nothing is baked (lm_stat)
fn lightmapB(a: []const V) Err!V {
    const k = try int(a[0]);
    if (lightmap.rgb.len == 0) return bs.num(0);
    const n: i32 = switch (k) {
        0 => @intCast(lightmap.n),
        1 => @bitCast(lightmap.w),
        2 => @truncate(@as(i64, @intCast(lightmap.covered))),
        3 => @truncate(lightmap.ms),
        4 => @bitCast(lightmap.spp),
        else => 0,
    };
    return f32n(@floatFromInt(n));
}

/// (a0 b0 + a1 b1) + (a2 b2 + a3 b3): dpps' sum
fn dp4(r: []const f32, p: m.V3) f32 {
    return (r[0] * p[0] + r[1] * p[1]) + (r[2] * p[2] + r[3]);
}
fn dp3(a: m.V3, b: m.V3) f32 {
    return (a[0] * b[0] + a[1] * b[1]) + a[2] * b[2];
}

/// lmsample(object, x, y, z, c): the lightmap's channel c where the object's
/// surface is nearest the point (a triangle within 5 cm, the point projected
/// onto it); nil if none (lm_sample)
fn lmsample(a: []const V) Err!V {
    var q: m.V3 = undefined;
    for (0..3) |k| q[k] = bs.f32of(try bs.argNum(a[1 + k]));
    const c = try int(a[4]);
    const oi = try bsc.argObj(a[0]);
    const rgb = lmAt(oi, q) orelse return bs.nil;
    if (c < 0 or c >= 3) return bs.nil;
    return f32n(rgb[@intCast(c)]);
}

fn lmAt(oi: usize, q: m.V3) ?m.V3 {
    const o = &scene.objects[oi];
    const e = lightmap.find(o.oid) orelse return null;
    const me = @import("mods.zig").of(oi) orelse return null;
    if (me.loops.len != e.nloops) return null;
    const mtx = scene.world(oi);
    for (me.tris, 0..) |tr, t| {
        var v: [3]m.V3 = undefined;
        for (0..3) |k| v[k] = .{ dp4(mtx[0..4], me.verts[tr[k]]), dp4(mtx[4..8], me.verts[tr[k]]), dp4(mtx[8..12], me.verts[tr[k]]) };
        var n = m.cross(m.sub(v[1], v[0]), m.sub(v[2], v[0]));
        const nl = @sqrt(dp3(n, n));
        if (!(nl > 1.0e-12)) continue;
        n = .{ n[0] / nl, n[1] / nl, n[2] / nl };
        const dist = dp3(m.sub(q, v[0]), n);
        if (!(@abs(dist) <= 0.05)) continue;
        const pq = m.sub(q, m.scale(n, dist));
        const b0 = dp3(m.cross(m.sub(v[1], pq), m.sub(v[2], pq)), n);
        const b1 = dp3(m.cross(m.sub(v[2], pq), m.sub(v[0], pq)), n);
        const whole = dp3(m.cross(m.sub(v[1], v[0]), m.sub(v[2], v[0])), n);
        const w0 = b0 / whole;
        const w1 = b1 / whole;
        const w2 = (1 - w0) - w1;
        if (!(w0 >= -1.0e-4) or !(w1 >= -1.0e-4) or !(w2 >= -1.0e-4)) continue;
        const w = [3]f32{ w0, w1, w2 };
        var uv: [2]f32 = .{ 0, 0 };
        for (0..3) |k| {
            const l = triLoop(me, t, k);
            const s = e.uv[l];
            uv = .{ s[0] * w[k] + uv[0], s[1] * w[k] + uv[1] };
        }
        return bilinear(e, uv);
    }
    return null;
}

/// The loop of a triangle's corner: its vertex in its polygon (lm_tri_loop).
fn triLoop(me: *const scene.Mesh, t: usize, corner: usize) usize {
    const v = me.tris[t][corner];
    const p = me.tri_poly[t];
    const a = me.poff[p];
    for (a..me.poff[p + 1]) |l| {
        if (me.loops[l] == v) return l;
    }
    return a;
}

fn bilinear(e: *const lightmap.Entry, uv: [2]f32) m.V3 {
    const W = lightmap.w;
    const H = lightmap.h;
    var x = (uv[0] * e.rect[2] + e.rect[0]) * @as(f32, @floatFromInt(@as(i32, @bitCast(W)))) - 0.5;
    var y = ((1 - uv[1]) * e.rect[3] + e.rect[1]) * @as(f32, @floatFromInt(@as(i32, @bitCast(H)))) - 0.5;
    x = @max(x, 0); // (maxss: NaN gives 0)
    y = @max(y, 0);
    if (x != x) x = 0;
    if (y != y) y = 0;
    const xf = @floor(x);
    const yf = @floor(y);
    var x0 = bs.ci32(xf);
    var y0 = bs.ci32(yf);
    const fx = x - xf;
    const fy = y - yf;
    const wm: i32 = @as(i32, @bitCast(W)) - 1;
    const hm: i32 = @as(i32, @bitCast(H)) - 1;
    if (x0 > wm) x0 = wm;
    if (y0 > hm) y0 = hm;
    const x1 = @min(x0 + 1, wm);
    const y1 = @min(y0 + 1, hm);
    const px = struct {
        fn f(xx: i32, yy: i32) m.V3 {
            const i: usize = @intCast(@as(i64, yy) * @as(i64, @bitCast(@as(u64, lightmap.w))) + xx);
            return lightmap.rgb[i];
        }
    }.f;
    const a0 = px(x0, y0);
    const a1 = px(x1, y0);
    const c0 = px(x0, y1);
    const c1 = px(x1, y1);
    var out: m.V3 = undefined;
    for (0..3) |k| {
        const top = a0[k] + (a1[k] - a0[k]) * fx;
        const bot = c0[k] + (c1[k] - c0[k]) * fx;
        out[k] = top + (bot - top) * fy;
    }
    return out;
}

// ---- the GPU helper --------------------------------------------------------------------------

/// gpu(k): 0 running (starts it), 1 device type, 2 path tracer runs, 3 raster
/// batches, 4 samples traced, 5 GPU-side ms, 6 this render on the GPU; 7.. the
/// live viewport's and the GPU viewport's (those the port keeps; others 0)
fn gpuB(a: []const V) Err!V {
    const k = try int(a[0]);
    const lg = @import("livegpu.zig");
    const gv = @import("gview.zig");
    const n: i64 = switch (k) {
        0 => @intFromBool(gpu.ready(15000)),
        1 => gpu.typeOf(),
        2 => gpupt.n_runs,
        3 => @import("gpuraster.zig").nbatch,
        4 => gpupt.n_spp,
        5 => @as(i64, @bitCast(gpu.total_ms)),
        6 => @intFromBool(gpupt.on or gpupt.why == .gpu),
        7 => lg.nray,
        8 => @import("live.zig").samples(),
        9 => lg.nput,
        11 => @divTrunc(lg.ray_us, 1000),
        14 => @divTrunc(lg.dn_us, 1000),
        21 => @as(i64, @bitCast(gpupt.last_kib)),
        23 => @intFromBool(gpupt.last_rtx),
        24 => @intFromBool(gpu.hasRtx()),
        27 => gv.nframes,
        28 => @divTrunc(gv.last_us, 1000),
        29 => @as(i64, @bitCast(gv.mesh_kib)),
        31 => @intFromBool(gpu.hostMem()),
        else => 0,
    };
    const v: i32 = @truncate(n); // (eax)
    return bs.num(@floatFromInt(v));
}

// ---- the path tracer into files ---------------------------------------------------------

fn wallMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// A film the path tracer can hold: the original's 32-bit sizes (w h 28 bytes).
fn filmOk(w: i32, h: i32) bool {
    if (w <= 0 or h <= 0) return false;
    return @as(i64, w) * h * 28 < 1 << 31;
}

/// render(path [, width, height, samples, denoise]) -> milliseconds: the path
/// tracer into a PNG (the camera object, or the viewport)
fn renderB(a: []const V) Err!V {
    var w: i32 = 640;
    var h: i32 = 360;
    var spp: i32 = 64;
    var dn: i32 = 0;
    if (a.len >= 2) w = try int(a[1]);
    if (a.len >= 3) h = try int(a[2]);
    if (a.len >= 4) spp = try int(a[3]);
    if (a.len >= 5) dn = try int(a[4]);
    const path0 = try bs.argStr(a[0]);
    try mayFiles("render");
    var pb: [1024]u8 = undefined;
    const path = files.expandHome(&pb, path0) orelse return bs.fail(e_render, path0);
    // (a width or height below 1, or a sample count past 2^31, made the original
    // crash or trace for ever: they fail here)
    if (!filmOk(w, h) or spp < 0 or path.len == 0) return bs.fail(e_render, path0);
    if (spp == 0) return zeroSamples(path, path0, @intCast(w), @intCast(h));
    const vi = app.viewportArea();
    const view: @import("viewport.zig").View = if (vi >= 0) app.N(vi).view else .{};
    const t0 = wallMs();
    if (!@import("render.zig").renderFile(path, @intCast(w), @intCast(h), @intCast(spp), dn != 0, &view)) return bs.fail(e_render, path0);
    return bs.num(@floatFromInt(@as(i32, @truncate(wallMs() - t0))));
}

/// No samples: the original's film as it starts, black (its Render area's
/// samples gone all the same).
fn zeroSamples(path: []const u8, path0: []const u8, w: u32, h: u32) Err!V {
    const A = std.heap.page_allocator;
    const t0 = wallMs();
    @import("render.zig").abandon();
    if (!files.mayWrite(path)) return bs.fail(e_render, path0);
    const px = A.alloc(u32, @as(usize, w) * h) catch return bs.fail(e_render, path0);
    defer A.free(px);
    @memset(px, 0);
    const data = @import("png.zig").encode(A, w, h, px) catch return bs.fail(e_render, path0);
    defer A.free(data);
    @import("bee.zig").writeAtomic(path, data) catch return bs.fail(e_render, path0);
    return bs.num(@floatFromInt(@as(i32, @truncate(wallMs() - t0))));
}

/// render_frames(folder [, first, last, width, height, samples, denoise]) ->
/// milliseconds: every frame of the range into folder/NNNN.png; defaults the
/// animation's range and the render settings
fn renderFrames(a: []const V) Err!V {
    const render = @import("render.zig");
    const fr = @import("frange.zig").r;
    // first, last, width, height, samples, denoise
    var v = [6]i32{ fr.start, fr.end, @bitCast(render.width), @bitCast(render.height), @bitCast(render.samples), @intFromBool(render.denoise) };
    var k: usize = 1;
    while (k < a.len) : (k += 1) {
        var x = try int(a[k]);
        if (k > 2 and k != 6 and x < 1) x = 1; // (first, last as given; the rest at least 1)
        v[k - 1] = x;
    }
    const folder0 = try bs.argStr(a[0]);
    try mayFiles("render_frames");
    var pb: [1024]u8 = undefined;
    const folder = files.expandHome(&pb, folder0) orelse return bs.fail(e_render, folder0);
    const ms = @import("video.zig").renderFrames(folder, @bitCast(v[2]), @bitCast(v[3]), @bitCast(v[4]), v[5] != 0, v[0], v[1]) orelse return bs.fail(e_render, folder0);
    return bs.num(@floatFromInt(@as(i32, @truncate(ms))));
}

// ---- images ----------------------------------------------------------------------------------

/// image(path) -> the new image's name: loads PNG, JPEG or Radiance HDR
fn imageB(a: []const V) Err!V {
    const p0 = try bs.argStr(a[0]);
    try mayFiles("image");
    var pb: [1024]u8 = undefined;
    const path = files.expandHome(&pb, p0) orelse return bs.fail(e_image, p0);
    const i = images.loadNew(path) catch return bs.fail(e_image, p0);
    app.log("image: {s} {d} x {d}{s}", .{ images.nameOf(i), images.list[i].img.w, images.list[i].img.h, if (images.list[i].img.hdr) " (HDR)" else "" });
    app.dirty = true;
    return bs.text(images.nameOf(i));
}

/// a_image
fn argImage(v: V) Err!usize {
    const nm = try bs.argStr(v);
    return images.find(nm) orelse bs.fail(e_no_image, nm);
}

/// imgsize(image, axis) -> width (0) or height (anything else)
fn imgsize(a: []const V) Err!V {
    const i = try argImage(a[0]);
    const ax = try int(a[1]);
    const img = &images.list[i].img;
    const n: u32 = if (ax == 0) img.w else img.h;
    return bs.num(@floatFromInt(n));
}

/// imgpixel(image, x, y, channel) -> 0..255 (8-bit) or linear (HDR, alpha 1);
/// -1 outside
fn imgpixel(a: []const V) Err!V {
    const i = try argImage(a[0]);
    const x: u32 = @bitCast(try int(a[1]));
    const y: u32 = @bitCast(try int(a[2]));
    const c: u32 = @bitCast(try int(a[3]));
    const e = &images.list[i];
    if (x >= e.img.w or y >= e.img.h or c >= 4) return bs.num(-1);
    const at = @as(usize, y) * e.img.w + x;
    if (e.img.hdr) {
        if (c == 3) return bs.num(1);
        return f32n(e.img.px[at][c]);
    }
    if (e.b8.len <= at) return bs.num(-1);
    return bs.num(@floatFromInt(e.b8[at][c]));
}

test "a film the path tracer can hold" {
    try std.testing.expect(filmOk(1, 1));
    try std.testing.expect(filmOk(8192, 8192));
    try std.testing.expect(!filmOk(0, 10));
    try std.testing.expect(!filmOk(-5, 10));
    try std.testing.expect(!filmOk(100000, 100000));
    try std.testing.expect(!filmOk(std.math.minInt(i32), 1));
}

test "dpps' order of sums" {
    // (a0 b0 + a1 b1) + (a2 b2 + a3): 1e8 + 1 - 1e8 is not 1 that way
    try std.testing.expectEqual(@as(f32, 0), dp4(&.{ 1, 1, 1, 0 }, .{ 1.0e8, 1, -1.0e8 }));
    try std.testing.expectEqual(@as(f32, 3), dp3(.{ 1, 1, 1 }, .{ 1, 1, 1 }));
}
