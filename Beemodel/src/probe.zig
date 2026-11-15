// Light probes (probe.s): irradiance volumes and reflection probes, baked by
// the path tracer, used by the material preview.
//
// The probes live in one reference-counted block: undo steps keep the block
// they saw, a change copies it first; it is saved as the PRBE chunk, each probe
// the original's 81920-byte record. A probe has a box (centre, half size):
//
//   irradiance  a grid of points over the box (up to 8 x 8 x 8): each holds the
//               light arriving there as L2 spherical harmonics, 9 coefficients
//               a colour channel, already convolved with the cosine lobe and
//               divided by pi: evaluated at a normal they give the irradiance
//               / pi the preview multiplies by the diffuse colour.
//   reflection  a cube map (6 x 32 x 32 texels of radiance) seen from the box's
//               centre, looked up box-projected: the reflected ray meets the
//               box, the cube is read towards that point.
//
// Baking runs on the UI thread as a job, in batches on every core, so the
// window stays alive. The preview asks irr / spec for a point, from any thread:
// the smallest baked probe of that kind around it.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const pt = @import("pt.zig");
const hive = @import("hive.zig");
const jobs = @import("jobs.zig");
const jobui = @import("jobui.zig");
const A = std.heap.page_allocator;

pub const MAX = 16;
pub const RMAX = 8; // grid points a side
pub const CUBE = 32; // texels a cube face side
const SZ = 81920;
const PT = 27; // floats a grid point: 9 coefficients x rgb

pub const IRRADIANCE: u32 = 1;
pub const REFLECTION: u32 = 2;

/// As in the file: the bytes between the fields stay as they came.
pub const Probe = extern struct {
    kind: u32,
    spp: u32, // the samples it was baked with (0: not baked)
    res: [3]u32, // grid points x, y, z
    pad0: [3]u32,
    cen: [4]f32,
    half: [4]f32,
    pad1: [48]u32,
    data: [(SZ - 256) / 4]f32,
};

comptime {
    std.debug.assert(@sizeOf(Probe) == SZ);
    std.debug.assert(@offsetOf(Probe, "data") == 256);
    std.debug.assert(PT * RMAX * RMAX * RMAX <= (SZ - 256) / 4);
    std.debug.assert(6 * CUBE * CUBE * 3 <= (SZ - 256) / 4);
}

pub const Block = struct {
    refs: u32 = 1,
    n: u32 = 0,
    p: [MAX]Probe = undefined,
};

/// The probes now (null: none).
pub var cur: ?*Block = null;
/// Moves when they change (the viewport's cached image keys on it).
pub var version: u32 = 0;

pub fn unref(b: ?*Block) void {
    const x = b orelse return;
    x.refs -= 1;
    if (x.refs == 0) A.destroy(x);
}

pub fn reset() void {
    unref(cur);
    cur = null;
    version +%= 1;
}

pub fn count() usize {
    return if (cur) |b| b.n else 0;
}

/// The undo steps: a snapshot holds a reference to the block it saw.
pub fn keep(slot: *?*Block) void {
    if (cur) |b| b.refs += 1;
    unref(slot.*);
    slot.* = cur;
}
pub fn restore(b: ?*Block) void {
    if (b) |x| x.refs += 1;
    if (b != cur) version +%= 1;
    unref(cur);
    cur = b;
}

/// cur, unshared (made if none); null without memory.
fn own() ?*Block {
    version +%= 1;
    if (cur) |b| {
        if (b.refs == 1) return b;
    }
    const nb = A.create(Block) catch return null;
    nb.refs = 1;
    nb.n = 0;
    if (cur) |b| {
        nb.n = b.n;
        @memcpy(nb.p[0..b.n], b.p[0..b.n]);
    }
    unref(cur);
    cur = nb;
    return nb;
}

// --- the file ------------------------------------------------------------------------

/// PRBE: the count, then each probe.
pub fn write(out: *std.ArrayList(u8), a: std.mem.Allocator) void {
    const n: u32 = @intCast(count());
    var x: [4]u8 = undefined;
    std.mem.writeInt(u32, &x, n, .little);
    out.appendSlice(a, &x) catch {
        @import("bee.zig").encode_failed = true;
    };
    if (cur) |b| out.appendSlice(a, std.mem.sliceAsBytes(b.p[0..n])) catch {
        @import("bee.zig").encode_failed = true;
    };
}

/// A probe out of a file made safe: nothing here may trip the lookups.
fn sane(p: *Probe) void {
    if (p.kind != IRRADIANCE and p.kind != REFLECTION) {
        p.kind = IRRADIANCE;
        p.spp = 0;
    }
    for (0..3) |i| {
        if (p.res[i] < 1 or p.res[i] > RMAX) {
            p.res[i] = 1;
            p.spp = 0;
        }
        if (!std.math.isFinite(p.cen[i])) {
            p.cen[i] = 0;
            p.spp = 0;
        }
        if (!std.math.isFinite(p.half[i]) or !(p.half[i] > 0)) {
            p.half[i] = 1;
            p.spp = 0;
        }
    }
}

/// False when the chunk is damaged: no probes then.
pub fn read(c: []const u8) bool {
    reset();
    if (c.len < 4) return c.len == 0;
    const n: usize = @min(std.mem.readInt(u32, c[0..4], .little), MAX);
    if (n == 0) return true;
    if (4 + n * SZ > c.len) return false;
    const b = own() orelse return false;
    b.n = @intCast(n);
    @memcpy(std.mem.sliceAsBytes(b.p[0..n]), c[4..][0 .. n * SZ]);
    for (b.p[0..n]) |*p| sane(p);
    return true;
}

// --- operators -----------------------------------------------------------------------

fn number(it: anytype) ?f32 {
    const w = it.next() orelse return null;
    const v = std.fmt.parseFloat(f32, w) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

/// probe.add irradiance|reflection [x y z] [hx hy hz] [nx ny nz]
pub fn add(arg: []const u8) void {
    var it = std.mem.tokenizeAny(u8, arg, " \t\"");
    const word = it.next() orelse "";
    const kind: u32 = if (std.mem.eql(u8, word, "irradiance")) IRRADIANCE else if (std.mem.eql(u8, word, "reflection")) REFLECTION else return app.log("  probe.add irradiance|reflection [x y z] [half size x y z] [grid points x y z (1-8)]", .{});
    // defaults: at the 3D cursor, 1 up, a 10 x 4 x 10 box, 4 x 3 x 4 points
    const cu = scene.cursor;
    var v = [9]f32{ cu[0], cu[1] + 1, cu[2], 5, 2, 5, 4, 3, 4 };
    for (&v) |*x| x.* = number(&it) orelse break;
    if (count() >= MAX) return app.log("  probes: the scene holds 16", .{});
    const b = own() orelse return;
    const p = &b.p[b.n];
    @memset(std.mem.asBytes(p), 0);
    p.kind = kind;
    for (0..3) |i| {
        p.cen[i] = v[i];
        p.half[i] = @max(@abs(v[3 + i]), 0.01);
        const t = @trunc(std.math.clamp(v[6 + i], 1, RMAX));
        p.res[i] = if (kind == REFLECTION) 1 else @intFromFloat(t);
    }
    b.n += 1;
    app.log("  probe {d} {s}", .{ b.n, word });
}

/// probe.remove <number from 1>
pub fn remove(arg: []const u8) void {
    var it = std.mem.tokenizeAny(u8, arg, " \t\"");
    const v = number(&it) orelse return app.log("  no such probe", .{});
    const n = count();
    if (!(v >= 1) or v >= @as(f32, @floatFromInt(n + 1))) return app.log("  no such probe", .{});
    const k: usize = @as(usize, @intFromFloat(v)) - 1;
    const b = own() orelse return;
    std.mem.copyForwards(Probe, b.p[k .. n - 1], b.p[k + 1 .. n]);
    b.n -= 1;
}

pub fn clear() void {
    reset();
}

pub fn pollAny() ?[]const u8 {
    return if (count() == 0) "No light probes yet (probe.add)" else null;
}

/// The last bake: ms, paths, for the Render tab.
pub var last_ms: i64 = 0;
pub var last_paths: u64 = 0;

/// probe.bake [rays a point]
pub fn opBake(arg: []const u8) void {
    var rays: f32 = 256;
    var it = std.mem.tokenizeAny(u8, arg, " \t\"");
    if (number(&it)) |v| rays = std.math.clamp(v, 4, 65536);
    if (count() == 0) return;
    jobui.later(bakeJob, "Baking light probes", "", @intFromFloat(rays), 0);
}

fn wallMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Hive up for trace_ray (any render stops); false: out of memory.
pub fn prep() bool {
    const render = @import("render.zig");
    if (render.active) render.stopNow();
    return pt.buildScene();
}

const Batch = struct { base: usize, ctx: *anyopaque, f: jobs.Fn };

fn batchRun(c: *anyopaque, lo: usize, hi: usize, th: usize) void {
    const b: *const Batch = @ptrCast(@alignCast(c));
    b.f(b.ctx, b.base + lo, b.base + hi, th);
}

/// parallelFor in batches of about a tenth of a second, a job frame after each:
/// the window stays alive through bakes of any length. The bar goes over
/// from .. from + span.
pub fn batched(n: usize, chunk: usize, ctx: *anyopaque, f: jobs.Fn, from: f32, span: f32) void {
    var done: usize = 0;
    var step: usize = jobs.count() * chunk;
    while (done < n) {
        const k = @min(step, n - done);
        var b = Batch{ .base = done, .ctx = ctx, .f = f };
        const t0 = wallMs();
        jobs.parallelFor(k, chunk, &b, batchRun);
        done += k;
        jobui.set(from + span * @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(n)));
        const took = wallMs() - t0;
        if (took < 50) step *= 2 else if (took > 200 and step > jobs.count() * chunk) step /= 2;
    }
}

var seed: u32 = 0;

fn bakeJob(_: []const u8, rays: usize, _: usize) void {
    if (count() == 0) return;
    if (!prep()) return app.log("  probes: out of memory", .{});
    if (hive.tris.len == 0) return app.log("  probes: nothing to bake against (no mesh)", .{});
    const t0 = wallMs();
    const b = own() orelse return;
    seed +%= 1;
    var paths: u64 = 0;
    const span = 1 / @as(f32, @floatFromInt(b.n));
    for (b.p[0..b.n], 0..) |*p, i| {
        const from = @as(f32, @floatFromInt(i)) * span;
        var job = Job{ .p = p, .rays = @intCast(rays) };
        if (p.kind == IRRADIANCE) {
            const np = p.res[0] * p.res[1] * p.res[2];
            paths += @as(u64, np) * rays;
            batched(np, 1, &job, irrJob, from, span);
            p.spp = @intCast(rays);
        } else {
            p.spp = @max(@as(u32, @intCast(rays)) >> 3, 4);
            job.rays = p.spp;
            paths += @as(u64, p.spp) * 6 * CUBE * CUBE;
            batched(6 * CUBE, 1, &job, cubeJob, from, span);
        }
    }
    last_ms = @max(wallMs() - t0, 1);
    last_paths = paths;
    version +%= 1;
    app.log("  probes baked: {d}, {d} ms", .{ b.n, last_ms });
    app.dirty = true;
}

// --- baking ------------------------------------------------------------------------

const Job = struct { p: *Probe, rays: u32 };

/// A grid point: min + 2 h i / (n - 1) along each axis (one point: the centre).
fn point(p: *const Probe, ix: [3]u32) m.V3 {
    var o: m.V3 = undefined;
    for (0..3) |a| {
        o[a] = p.cen[a];
        if (p.res[a] > 1) {
            const t = @as(f32, @floatFromInt(ix[a])) / @as(f32, @floatFromInt(p.res[a] - 1));
            o[a] += (t + t - 1) * p.half[a];
        }
    }
    return o;
}

/// The real L2 basis at a unit direction.
pub fn sh9(d: m.V3) [9]f32 {
    const x = d[0];
    const y = d[1];
    const z = d[2];
    const y1: f32 = 0.488603;
    const y2a: f32 = 1.092548;
    return .{
        0.282095,
        y1 * y,
        y1 * z,
        y1 * x,
        y2a * x * y,
        y2a * y * z,
        0.315392 * (3 * z * z - 1),
        y2a * x * z,
        0.546274 * (x * x - y * y),
    };
}

/// Each point: rays over the sphere in strata, their radiance into SH, convolved.
fn irrJob(c: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const job: *const Job = @ptrCast(@alignCast(c));
    const p = job.p;
    for (lo..hi) |pi_| {
        const u: u32 = @intCast(pi_);
        const nx = p.res[0];
        const ny = p.res[1];
        const o = point(p, .{ u % nx, (u / nx) % ny, u / nx / ny });
        var r = pt.Rng.init(u +% (@as(u64, seed) << 32), 0x1BE);
        var sum: [PT]f32 = @splat(0);
        const s: u32 = @max(@as(u32, @intFromFloat(@sqrt(@as(f32, @floatFromInt(job.rays))))), 1);
        const sf: f32 = @floatFromInt(s);
        const total = s * s;
        for (0..total) |k| {
            const row: f32 = @floatFromInt(@as(u32, @intCast(k)) / s);
            const col: f32 = @floatFromInt(@as(u32, @intCast(k)) % s);
            const z = 1 - 2 * (r.f() + row) / sf;
            const ph = 2 * std.math.pi * (r.f() + col) / sf;
            const rr = @sqrt(@max(1 - z * z, 0));
            const d: m.V3 = .{ rr * @cos(ph), rr * @sin(ph), z };
            var aux = pt.Aux{};
            const L = pt.traceRay(o, d, &aux, &r);
            if (!std.math.isFinite(L[0] + L[1] + L[2])) continue;
            const y = sh9(d);
            for (0..9) |l| {
                for (0..3) |ch| sum[l * 3 + ch] += y[l] * L[ch];
            }
        }
        const k4 = 4 * std.math.pi / @as(f32, @floatFromInt(total));
        for (0..9) |l| {
            // the cosine lobe's bands over pi: 1, 2/3, 1/4
            const a: f32 = if (l < 1) 1 else if (l < 4) 0.6666667 else 0.25;
            for (0..3) |ch| p.data[u * PT + l * 3 + ch] = sum[l * 3 + ch] * a * k4;
        }
    }
}

/// +X (1, -v, -u), -X (-1, -v, u), +Y (u, 1, v), -Y (u, -1, -v), +Z (u, -v, 1), -Z (-u, -v, -1)
pub fn cubeDir(face: u32, u: f32, v: f32) m.V3 {
    return switch (face) {
        0 => .{ 1, -v, -u },
        1 => .{ -1, -v, u },
        2 => .{ u, 1, v },
        3 => .{ u, -1, -v },
        4 => .{ u, -v, 1 },
        else => .{ -u, -v, -1 },
    };
}

/// Rows of the six faces: each texel's radiance, jittered inside it.
fn cubeJob(c: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const job: *const Job = @ptrCast(@alignCast(c));
    const p = job.p;
    const o: m.V3 = .{ p.cen[0], p.cen[1], p.cen[2] };
    for (lo..hi) |rowi| {
        const fr: u32 = @intCast(rowi); // face x 32 + row
        const face = fr / CUBE;
        const row: f32 = @floatFromInt(fr % CUBE);
        var r = pt.Rng.init(fr +% (@as(u64, seed) << 32), 0xC0BE);
        for (0..CUBE) |x| {
            var sum: m.V3 = .{ 0, 0, 0 };
            const col: f32 = @floatFromInt(x);
            for (0..job.rays) |_| {
                const u = 2 * (r.f() + col) / CUBE - 1;
                const v = 2 * (r.f() + row) / CUBE - 1;
                const d = m.norm(cubeDir(face, u, v));
                var aux = pt.Aux{};
                const L = pt.traceRay(o, d, &aux, &r);
                if (std.math.isFinite(L[0] + L[1] + L[2])) sum = m.add(sum, L);
            }
            const k = 1 / @as(f32, @floatFromInt(job.rays));
            const at = (fr * CUBE + x) * 3;
            for (0..3) |ch| p.data[at + ch] = sum[ch] * k;
        }
    }
}

// --- lookups (the preview; any thread) -----------------------------------------------

/// The smallest baked probe of that kind whose box holds the point (an
/// irradiance volume's box + half a grid step: the surfaces at its edges).
fn find(q: m.V3, kind: u32) ?*const Probe {
    const b = cur orelse return null;
    var best: ?*const Probe = null;
    var vol: f32 = 1e30;
    for (b.p[0..b.n]) |*p| {
        if (p.kind != kind or p.spp == 0) continue;
        var inside = true;
        for (0..3) |a| {
            var h = p.half[a];
            if (kind == IRRADIANCE) h += h / @max(@as(f32, @floatFromInt(p.res[a])) - 1, 1);
            if (!(@abs(q[a] - p.cen[a]) <= h)) inside = false;
        }
        if (!inside) continue;
        const v = p.half[0] * p.half[1] * p.half[2];
        if (v < vol) {
            vol = v;
            best = p;
        }
    }
    return best;
}

/// The irradiance / pi the probes give at q for unit normal n, null when no
/// irradiance volume holds q: trilinear between the grid points.
pub fn irr(q: m.V3, n: m.V3) ?m.V3 {
    const p = find(q, IRRADIANCE) orelse return null;
    var base: [3]u32 = .{ 0, 0, 0 };
    var t: [3]f32 = .{ 0, 0, 0 };
    for (0..3) |a| {
        const r = p.res[a];
        if (r <= 1) continue;
        const top: f32 = @floatFromInt(r - 1);
        const f = @min(@max((q[a] - p.cen[a] + p.half[a]) / p.half[a] * 0.5 * top, 0), top);
        const fl = @floor(f);
        base[a] = @min(@as(u32, @intFromFloat(fl)), r - 2);
        t[a] = f - @as(f32, @floatFromInt(base[a]));
    }
    const y = sh9(n);
    var sum: m.V3 = .{ 0, 0, 0 };
    for (0..8) |corner| {
        var w: f32 = 1;
        var ix: u32 = 0;
        var stride: u32 = 1;
        for (0..3) |a| {
            var i = base[a];
            if (corner >> @intCast(a) & 1 != 0) {
                if (p.res[a] <= 1) {
                    w = 0;
                } else {
                    i += 1;
                    w *= t[a];
                }
            } else w *= 1 - t[a];
            ix += i * stride;
            stride *= p.res[a];
        }
        if (!(w > 0)) continue;
        var e: m.V3 = .{ 0, 0, 0 };
        for (0..9) |l| {
            for (0..3) |ch| e[ch] += p.data[ix * PT + l * 3 + ch] * y[l];
        }
        for (0..3) |ch| sum[ch] += e[ch] * w;
    }
    for (&sum) |*x| x.* = @max(x.*, 0);
    return sum;
}

fn texel(p: *const Probe, face: u32, x: u32, y: u32) m.V3 {
    const at = ((face << 10) + (y << 5) + x) * 3;
    return .{ p.data[at], p.data[at + 1], p.data[at + 2] };
}

/// The radiance a reflection probe gives along unit d at q, box-projected;
/// null when no reflection probe's box holds q.
pub fn spec(q: m.V3, d: m.V3) ?m.V3 {
    const p = find(q, REFLECTION) orelse return null;
    var tm: f32 = 1e30; // the nearest exit along each axis
    for (0..3) |a| {
        if (@abs(d[a]) < 1e-6) continue;
        const face = if (d[a] > 0) p.cen[a] + p.half[a] else p.cen[a] - p.half[a];
        tm = @min(tm, (face - q[a]) / d[a]);
    }
    tm = @max(tm, 0);
    // from the centre to the hit
    const v: [3]f32 = .{ q[0] + d[0] * tm - p.cen[0], q[1] + d[1] * tm - p.cen[1], q[2] + d[2] * tm - p.cen[2] };
    const ax = @abs(v[0]);
    const ay = @abs(v[1]);
    const az = @abs(v[2]);
    var face: u32 = undefined;
    var ma: f32 = undefined;
    var u: f32 = undefined;
    var w: f32 = undefined;
    if (ax >= ay and ax >= az) {
        ma = ax;
        face = if (v[0] > 0) 0 else 1;
        u = if (v[0] > 0) -v[2] else v[2];
        w = -v[1];
    } else if (ay >= az) {
        ma = ay;
        face = if (v[1] > 0) 2 else 3;
        u = v[0];
        w = if (v[1] > 0) v[2] else -v[2];
    } else {
        ma = az;
        face = if (v[2] > 0) 4 else 5;
        u = if (v[2] > 0) v[0] else -v[0];
        w = -v[1];
    }
    ma = @max(ma, 1e-6);
    const top: f32 = CUBE - 1;
    const fx = @min(@max((u / ma + 1) * 0.5 * CUBE - 0.5, 0), top);
    const fy = @min(@max((w / ma + 1) * 0.5 * CUBE - 0.5, 0), top);
    const xf = @floor(fx);
    const yf = @floor(fy);
    const x0: u32 = @intFromFloat(xf);
    const y0: u32 = @intFromFloat(yf);
    const x1 = @min(x0 + 1, CUBE - 1);
    const y1 = @min(y0 + 1, CUBE - 1);
    const tx = fx - xf;
    const ty = fy - yf;
    const a = texel(p, face, x0, y0);
    const b = texel(p, face, x1, y0);
    const c = texel(p, face, x0, y1);
    const e = texel(p, face, x1, y1);
    var out: m.V3 = undefined;
    for (0..3) |ch| {
        const top_ = a[ch] + (b[ch] - a[ch]) * tx;
        const bot = c[ch] + (e[ch] - c[ch]) * tx;
        out[ch] = top_ + (bot - top_) * ty;
    }
    return out;
}

// --- the viewport --------------------------------------------------------------------

/// Every probe's box as lines: irradiance volumes yellow with a cross at each
/// grid point, reflection probes cyan.
pub fn draw(cv: anytype, c: anytype, line: anytype) void {
    const b = cur orelse return;
    for (b.p[0..b.n]) |*p| {
        const col: u32 = if (p.kind == IRRADIANCE) 0xd8c040 else 0x40c8d8;
        const corner = struct {
            fn at(pr: *const Probe, bits: u32) m.V3 {
                var o: m.V3 = undefined;
                for (0..3) |a| o[a] = pr.cen[a] + (if (bits >> @intCast(a) & 1 != 0) pr.half[a] else -pr.half[a]);
                return o;
            }
        }.at;
        for (0..8) |bits| {
            const k: u32 = @intCast(bits);
            for (0..3) |a| {
                const bit = @as(u32, 1) << @intCast(a);
                if (k & bit == 0) line(cv, c, corner(p, k), corner(p, k | bit), col);
            }
        }
        if (p.kind != IRRADIANCE) continue;
        const np = p.res[0] * p.res[1] * p.res[2];
        for (0..np) |ui| {
            const u: u32 = @intCast(ui);
            const q = point(p, .{ u % p.res[0], (u / p.res[0]) % p.res[1], u / p.res[0] / p.res[1] });
            for (0..3) |a| {
                var s = q;
                var e = q;
                s[a] -= 0.08;
                e[a] += 0.08;
                line(cv, c, s, e, col);
            }
        }
    }
}

// --- tests -----------------------------------------------------------------------------

const testing = std.testing;

fn irradianceProbe(b: *Block) *Probe {
    const p = &b.p[0];
    @memset(std.mem.asBytes(p), 0);
    p.kind = IRRADIANCE;
    p.spp = 1;
    p.res = .{ 2, 1, 1 };
    p.cen = .{ 0, 0, 0, 0 };
    p.half = .{ 1, 1, 1, 0 };
    return p;
}

test "a probe is 81920 bytes, its fields where the file has them" {
    try testing.expectEqual(@as(usize, 32), @offsetOf(Probe, "cen"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(Probe, "half"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Probe, "res"));
}

test "cube faces and their lookups are inverses" {
    const b = try A.create(Block);
    b.* = .{ .n = 1 };
    defer {
        cur = null;
        A.destroy(b);
    }
    const p = &b.p[0];
    @memset(std.mem.asBytes(p), 0);
    p.kind = REFLECTION;
    p.spp = 4;
    p.res = .{ 1, 1, 1 };
    p.half = .{ 2, 2, 2, 0 };
    cur = b;
    // each texel holds the number of its place: a direction through a texel's
    // centre reads that texel back
    for (0..6) |f| {
        for (0..CUBE) |y| {
            for (0..CUBE) |x| {
                const at = ((f << 10) + (y << 5) + x) * 3;
                p.data[at] = @floatFromInt(f);
                p.data[at + 1] = @floatFromInt(y);
                p.data[at + 2] = @floatFromInt(x);
            }
        }
    }
    for (0..6) |f| {
        for ([_]u32{ 0, 7, 20, 31 }) |y| {
            for ([_]u32{ 3, 16, 31 }) |x| {
                const u = 2 * (@as(f32, @floatFromInt(x)) + 0.5) / CUBE - 1;
                const v = 2 * (@as(f32, @floatFromInt(y)) + 0.5) / CUBE - 1;
                const d = m.norm(cubeDir(@intCast(f), u, v));
                const got = spec(.{ 0, 0, 0 }, d).?;
                try testing.expectApproxEqAbs(@as(f32, @floatFromInt(f)), got[0], 1e-4);
                try testing.expectApproxEqAbs(@as(f32, @floatFromInt(y)), got[1], 1e-2);
                try testing.expectApproxEqAbs(@as(f32, @floatFromInt(x)), got[2], 1e-2);
            }
        }
    }
    // box projection: off centre the ray still reads where it meets the box
    p.data[0] = 0;
    const off = spec(.{ 1.5, 0, 0 }, .{ 0, 0, 1 }).?; // hits (1.5, 0, 2): +Z, right of centre
    try testing.expectApproxEqAbs(@as(f32, 4), off[0], 1e-4);
    try testing.expect(off[2] > 22 and off[2] < 28);
}

test "a uniform sky: irradiance / pi comes back, whatever the normal" {
    const b = try A.create(Block);
    b.* = .{ .n = 1 };
    defer {
        cur = null;
        A.destroy(b);
    }
    const p = irradianceProbe(b);
    cur = b;
    // L = 1 everywhere: L00 = sqrt(4 pi) x 0.282095 = 1, the rest 0
    for (0..2) |i| {
        for (0..3) |c| p.data[i * PT + c] = 3.5449077;
    }
    const e = irr(.{ 0.3, 0, 0 }, m.norm(.{ 1, 2, 3 })).?;
    try testing.expectApproxEqAbs(@as(f32, 1), e[0], 1e-4);
    try testing.expect(irr(.{ 9, 0, 0 }, .{ 0, 1, 0 }) == null);
}

test "trilinear along a grid, half a step past the box still lit" {
    const b = try A.create(Block);
    b.* = .{ .n = 1 };
    defer {
        cur = null;
        A.destroy(b);
    }
    const p = irradianceProbe(b);
    cur = b;
    p.data[0] = 3.5449077 * 2;
    p.data[PT] = 3.5449077 * 4;
    const n: m.V3 = .{ 0, 1, 0 };
    try testing.expectApproxEqAbs(@as(f32, 2), irr(.{ -1, 0, 0 }, n).?[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 3), irr(.{ 0, 0, 0 }, n).?[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 4), irr(.{ 1, 0, 0 }, n).?[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 4), irr(.{ 1.9, 0, 0 }, n).?[0], 1e-4); // (a step past the box)
    try testing.expect(irr(.{ 2.1, 0, 0 }, n) == null);
}

test "the smallest box wins; an unbaked one is not asked" {
    const b = try A.create(Block);
    b.* = .{ .n = 2 };
    defer {
        cur = null;
        A.destroy(b);
    }
    const big = irradianceProbe(b);
    big.res = .{ 1, 1, 1 };
    big.half = .{ 8, 8, 8, 0 };
    big.data[0] = 3.5449077;
    const small = &b.p[1];
    small.* = big.*;
    small.half = .{ 1, 1, 1, 0 };
    small.data[0] = 3.5449077 * 2;
    cur = b;
    try testing.expectApproxEqAbs(@as(f32, 2), irr(.{ 0, 0, 0 }, .{ 0, 1, 0 }).?[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), irr(.{ 3, 0, 0 }, .{ 0, 1, 0 }).?[0], 1e-4);
    small.spp = 0;
    try testing.expectApproxEqAbs(@as(f32, 1), irr(.{ 0, 0, 0 }, .{ 0, 1, 0 }).?[0], 1e-4);
}

test "add, clamps, remove, undo's references" {
    reset();
    defer reset();
    add("irradiance 0 1 0 9 1 9 7 3 70");
    add("reflection 5 1.5 0 2.5 -1.5 0 9 9 9");
    add("nonsense");
    try testing.expectEqual(@as(usize, 2), count());
    const b0 = cur.?;
    try testing.expectEqual([3]u32{ 7, 3, 8 }, b0.p[0].res);
    try testing.expectEqual([3]u32{ 1, 1, 1 }, b0.p[1].res);
    try testing.expectEqual(@as(f32, 1.5), b0.p[1].half[1]);
    try testing.expectEqual(@as(f32, 0.01), b0.p[1].half[2]);
    // a snapshot keeps the block; a change copies it
    var snap: ?*Block = null;
    keep(&snap);
    remove("1");
    try testing.expect(cur != snap);
    try testing.expectEqual(@as(u32, 2), snap.?.n);
    try testing.expectEqual(@as(usize, 1), count());
    try testing.expectEqual(REFLECTION, cur.?.p[0].kind);
    restore(snap);
    try testing.expectEqual(@as(usize, 2), count());
    remove("3");
    remove("0");
    remove("-1");
    try testing.expectEqual(@as(usize, 2), count());
    unref(snap);
    for (0..20) |_| add("reflection");
    try testing.expectEqual(@as(usize, MAX), count());
}

test "PRBE: the bytes go round; damage does not reach the lookups" {
    reset();
    defer reset();
    add("irradiance 1 2 3 4 5 6 2 2 2");
    add("reflection");
    cur.?.p[0].spp = 9;
    cur.?.p[0].pad1[7] = 0xdeadbeef;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(A);
    write(&out, A);
    try testing.expectEqual(@as(usize, 4 + 2 * SZ), out.items.len);
    try testing.expect(read(out.items));
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(A);
    write(&again, A);
    try testing.expectEqualSlices(u8, out.items, again.items);
    // cut short: no probes
    try testing.expect(!read(out.items[0 .. out.items.len - 1]));
    try testing.expectEqual(@as(usize, 0), count());
    // a mad count is clamped, then needs its bytes
    std.mem.writeInt(u32, out.items[0..4], 0xffffffff, .little);
    try testing.expect(!read(out.items));
    // mad records: lookups stay in bounds
    std.mem.writeInt(u32, out.items[0..4], 2, .little);
    const bad = [_]u32{ 0x7fc00000, 0x7f800000, 0, 0xffffffff };
    for (bad) |x| {
        for (out.items[4..260]) |*c| c.* = 0;
        std.mem.writeInt(u32, out.items[4 + 8 ..][0..4], x, .little); // res x
        std.mem.writeInt(u32, out.items[4 + 32 ..][0..4], x, .little); // centre x
        std.mem.writeInt(u32, out.items[4 + 48 ..][0..4], x, .little); // half x
        std.mem.writeInt(u32, out.items[4 + 4 ..][0..4], 5, .little); // "baked"
        try testing.expect(read(out.items));
        _ = irr(.{ 0, 0, 0 }, .{ 0, 1, 0 });
        _ = spec(.{ 0, 0, 0 }, .{ 0, 1, 0 });
    }
}

test "the preview: a dark volume replaces the environment and the softboxes" {
    const preview = @import("preview.zig");
    const b = try A.create(Block);
    b.* = .{ .n = 1 };
    defer {
        cur = null;
        A.destroy(b);
    }
    const p = irradianceProbe(b);
    p.res = .{ 1, 1, 1 };
    cur = b;
    const s = preview.Shader.of(&preview.default_material);
    const n: m.V3 = .{ 0, 1, 0 };
    const v: m.V3 = .{ 0, 0.6, 0.8 };
    const lit = preview.shadeAt(&s, n, v, .{ 50, 0, 0 });
    try testing.expectEqual(preview.shade(&s, n, v), lit); // outside it: as ever
    const dark = preview.shadeAt(&s, n, v, .{ 0, 0, 0 });
    try testing.expect((dark & 0xff) * 2 < (lit & 0xff));
}

test "a bake against the studio sky matches the sky's own irradiance" {
    scene.init();
    defer scene.reset();
    reset();
    defer reset();
    // far above the default scene's cube: the upper hemisphere is all sky
    add("irradiance 0 30 0 1 1 1 1 1 1");
    add("reflection 0 30 0 1 1 1");
    pt.bounces = 4;
    bakeJob("", 4096, 0);
    pt.bounces = 12;
    try testing.expectEqual(@as(u32, 4096), cur.?.p[0].spp);
    try testing.expectEqual(@as(u32, 512), cur.?.p[1].spp);
    // an up-facing point: the sky, as traced directly
    const e = irr(.{ 0, 30, 0 }, .{ 0, 1, 0 }).?;
    var ref: m.V3 = .{ 0, 0, 0 };
    var r = pt.Rng.init(5, 6);
    const n = 200000;
    for (0..n) |_| {
        const u = r.f();
        const ph = 2 * std.math.pi * r.f();
        const rr = @sqrt(u);
        const d: m.V3 = .{ rr * @cos(ph), @sqrt(1 - u), rr * @sin(ph) };
        var aux = pt.Aux{};
        const L = pt.traceRay(.{ 0, 30, 0 }, d, &aux, &r);
        if (L[0] < 100) ref = m.add(ref, L); // (the bake's few rays miss the sun's small disc)
    }
    for (0..3) |c| {
        const want = ref[c] / n;
        try testing.expect(@abs(e[c] - want) < 0.05 * want);
    }
    const sky = spec(.{ 0, 30, 0 }, .{ 0, 1, 0 }).?; // straight up: the zenith's blue
    try testing.expect(sky[2] > sky[0]);
}
