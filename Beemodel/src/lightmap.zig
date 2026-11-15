// The lightmap baker (lightmap.s): the light falling on every surface, in one
// atlas, for game engines.
//
// lightmap.bake gives every visible mesh object a second UV set of its own (a
// smart projection of its evaluated mesh: smartuv.zig, so the object's own UVs
// stay as they are), then places the objects in one square atlas: a square each,
// its side by the square root of the object's surface area in the world (the
// same texel density everywhere), on shelves, two texels apart. Every atlas texel
// a triangle covers gets its point and smoothed normal in the world, and the path
// tracer gathers the irradiance there: cosine-weighted rays from just above the
// surface, the average radiance = irradiance / pi. Then a denoise (three a-trous
// passes, 5 x 5, holes 1 2 4, weighted by the normals, within one object and
// nearby in the world) and a dilation (8 passes: empty texels take their filled
// neighbours' average, so filtering finds no black borders).
//
// An object's region is its rectangle (x0, y0, width, height, as fractions, rows
// down); its second UVs (u, v up) map into it as x0 + w u, y0 + h (1 - v).
//
// lightmap.save writes the atlas as OpenEXR (linear, half floats) or PNG (sRGB,
// clamped at 1). It is saved in the .bee file (LMAP) but is not part of undo: it
// is baked data, like a render.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const mods = @import("mods.zig");
const app = @import("app.zig");
const pt = @import("pt.zig");
const hive = @import("hive.zig");
const jobs = @import("jobs.zig");
const jobui = @import("jobui.zig");
const probe = @import("probe.zig");
const smartuv = @import("smartuv.zig");
const A = std.heap.page_allocator;

pub const MAX = 128;
const PAD = 2; // texels around each region
const SZ_MAX = 4096;

pub const Entry = struct {
    /// who it is (0: none now: the object is gone, its bytes stay)
    oid: u32 = 0,
    nloops: u32 = 0,
    ntris: u32 = 0,
    uv: [][2]f32 = &.{},
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    tex: f32 = 0, // the world size of a texel (baking)
    area: f32 = 0,
};

pub var w: u32 = 0;
pub var h: u32 = 0;
pub var n: usize = 0;
pub var tab: [MAX]Entry = @splat(.{});
/// The atlas: rgb a texel (empty: none).
pub var rgb: [][3]f32 = &.{};
/// The last bake: ms, texels covered, rays a texel.
pub var ms: i64 = 0;
pub var covered: usize = 0;
pub var spp: u32 = 0;
var seed: u32 = 0;

// baking only
var pos: []m.V3 = &.{};
var nrm: []m.V3 = &.{};
var obj: []u16 = &.{};
var tmp: [][3]f32 = &.{};
var todo: []u32 = &.{};

fn freeOf(comptime T: type, s: *[]T) void {
    if (s.len > 0) A.free(s.*);
    s.* = &.{};
}

fn freeBake() void {
    freeOf(m.V3, &pos);
    freeOf(m.V3, &nrm);
    freeOf(u16, &obj);
    freeOf([3]f32, &tmp);
    freeOf(u32, &todo);
}

/// No lightmap.
pub fn reset() void {
    freeBake();
    freeOf([3]f32, &rgb);
    for (tab[0..n]) |*e| {
        freeOf([2]f32, &e.uv);
        e.* = .{};
    }
    n = 0;
    w = 0;
    h = 0;
    covered = 0;
}

pub fn pollBaked() ?[]const u8 {
    return if (rgb.len == 0) "Nothing baked (lightmap.bake)" else null;
}

/// The object's entry, if it has one.
pub fn find(oid: u32) ?*const Entry {
    if (rgb.len == 0 or oid == 0) return null;
    for (tab[0..n]) |*e| {
        if (e.oid == oid) return e;
    }
    return null;
}

// --- the file ------------------------------------------------------------------------

/// LMAP: w, h, n; per entry uid, loops, triangles, rect; the UV sets; the atlas.
pub fn write(out: *std.ArrayList(u8), a: std.mem.Allocator) void {
    const put = struct {
        fn f(o: *std.ArrayList(u8), al: std.mem.Allocator, v: u32) void {
            var x: [4]u8 = undefined;
            std.mem.writeInt(u32, &x, v, .little);
            o.appendSlice(al, &x) catch {
                @import("bee.zig").encode_failed = true;
            };
        }
    }.f;
    if (rgb.len == 0) return put(out, a, 0);
    put(out, a, w);
    put(out, a, h);
    put(out, a, @intCast(n));
    for (tab[0..n]) |*e| {
        // the file's uids (bee.zig)
        var uid: u32 = 0;
        for (scene.objects[0..scene.count]) |*o| {
            if (o.oid == e.oid) uid = o.uid;
        }
        put(out, a, uid);
        put(out, a, e.nloops);
        put(out, a, e.ntris);
        out.appendSlice(a, std.mem.asBytes(&e.rect)) catch {
            @import("bee.zig").encode_failed = true;
        };
    }
    for (tab[0..n]) |*e| out.appendSlice(a, std.mem.sliceAsBytes(e.uv)) catch {
        @import("bee.zig").encode_failed = true;
    };
    out.appendSlice(a, std.mem.sliceAsBytes(rgb)) catch {
        @import("bee.zig").encode_failed = true;
    };
}

fn rd(c: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, c[o..][0..4], .little);
}

/// `look.get(uid)` gives the object now. False when the chunk is damaged: no
/// lightmap then.
pub fn read(c: []const u8, look: anytype) bool {
    reset();
    if (c.len < 12) return c.len == 0 or (c.len >= 4 and rd(c, 0) == 0);
    const cw = rd(c, 0);
    const ch = rd(c, 4);
    const cn = rd(c, 8);
    if (cw == 0) return true;
    if (cw > SZ_MAX or ch == 0 or ch > SZ_MAX or cn > MAX) return false;
    var at: usize = 12 + @as(usize, cn) * 28;
    if (at > c.len) return false;
    // what it says must fit before anything is taken
    var need: u64 = at + @as(u64, cw) * ch * 12;
    for (0..cn) |i| need += @as(u64, rd(c, 12 + i * 28 + 4)) * 8;
    if (need > c.len) return false;
    rgb = A.alloc([3]f32, @as(usize, cw) * ch) catch return false;
    w = cw;
    h = ch;
    for (0..cn) |i| {
        const r = c[12 + i * 28..][0..28];
        const e = &tab[i];
        e.* = .{ .nloops = rd(r, 4), .ntris = rd(r, 8) };
        if (look.get(rd(r, 0))) |ours| e.oid = scene.objects[ours].oid;
        @memcpy(std.mem.asBytes(&e.rect), r[12..28]);
        n = i + 1;
        e.uv = A.alloc([2]f32, e.nloops) catch {
            reset();
            return false;
        };
        @memcpy(std.mem.sliceAsBytes(e.uv), c[at..][0 .. @as(usize, e.nloops) * 8]);
        at += @as(usize, e.nloops) * 8;
    }
    @memcpy(std.mem.sliceAsBytes(rgb), c[at..][0 .. rgb.len * 12]);
    return true;
}

// --- operators -----------------------------------------------------------------------

/// lightmap.bake [size] [rays]
pub fn opBake(arg: []const u8) void {
    var it = std.mem.tokenizeAny(u8, arg, " \t\"");
    var v = [2]f32{ 512, 64 };
    for (&v) |*x| {
        const word = it.next() orelse break;
        const f = std.fmt.parseFloat(f32, word) catch break;
        if (std.math.isFinite(f)) x.* = f else break;
    }
    const size: usize = @intFromFloat(std.math.clamp(v[0], 64, SZ_MAX));
    const rays: usize = @intFromFloat(std.math.clamp(v[1], 1, SZ_MAX));
    jobui.later(bakeJob, "Baking the lightmap", "", size, rays);
}

/// lightmap.save <file.exr | file.png>
pub fn opSave(arg: []const u8) void {
    const p = std.mem.trim(u8, arg, " \t\"");
    if (p.len > 0) return saveTo(p);
    @import("filebrowser.zig").show(.save, "Save Lightmap", ".exr", "lightmap.exr", saveTo);
}

/// The atlas as 0xRRGGBB pixels, sRGB, clamped (the caller frees).
pub fn pixels() ?[]u32 {
    const px = A.alloc(u32, rgb.len) catch return null;
    for (rgb, px) |c, *o| {
        var v: u32 = 0;
        for (c) |x0| {
            const x = if (std.math.isFinite(x0)) std.math.clamp(x0, 0, 1) else 0;
            const s = if (x <= 0.0031308) x * 12.92 else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
            v = v << 8 | @as(u32, @intFromFloat(std.math.clamp(s, 0, 1) * 255 + 0.5));
        }
        o.* = v;
    }
    return px;
}

fn saveTo(path0: []const u8) void {
    if (rgb.len == 0) return app.log("  lightmap: nothing baked (lightmap.bake)", .{});
    const files = @import("files.zig");
    const bee = @import("bee.zig");
    var pb: [1024]u8 = undefined;
    const path = files.expandHome(&pb, path0) orelse return app.log("  lightmap.save: could not write {s}", .{path0});
    if (!files.mayWrite(path)) return app.log("  lightmap: not written (tests write under /tmp only): {s}", .{path});
    const data: ?[]u8 = blk: {
        if (std.mem.endsWith(u8, path, ".exr")) break :blk @import("exr.zig").encode(A, w, h, rgb) catch null;
        const px = pixels() orelse break :blk null;
        defer A.free(px);
        break :blk @import("png.zig").encode(A, w, h, px) catch null;
    };
    const d = data orelse return app.log("  lightmap.save: could not write {s}", .{path});
    defer A.free(d);
    bee.writeAtomic(path, d) catch return app.log("  lightmap.save: could not write {s}", .{path});
    app.log("  lightmap saved: {s}", .{path});
    app.toast(.ok, "Lightmap saved: {s}", .{std.fs.path.basename(path)});
}

fn wallMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn bakeJob(_: []const u8, size: usize, rays: usize) void {
    const t0 = wallMs();
    reset();
    if (!bake(@intCast(size), @intCast(rays))) {
        reset();
        return;
    }
    freeBake();
    ms = @max(wallMs() - t0, 1);
    app.log("  lightmap baked: {d} objects, {d} ms", .{ n, ms });
    app.dirty = true;
}

fn bake(size: u32, rays: u32) bool {
    w = size;
    h = size;
    spp = rays;
    seed +%= 1;
    if (!gather()) return say("  lightmap: out of memory");
    if (n == 0) return say("  lightmap: no mesh objects to bake");
    packRects();
    const cells = @as(usize, w) * h;
    rgb = A.alloc([3]f32, cells) catch return say("  lightmap: out of memory");
    pos = A.alloc(m.V3, cells) catch return say("  lightmap: out of memory");
    nrm = A.alloc(m.V3, cells) catch return say("  lightmap: out of memory");
    obj = A.alloc(u16, cells) catch return say("  lightmap: out of memory");
    tmp = A.alloc([3]f32, cells) catch return say("  lightmap: out of memory");
    @memset(rgb, .{ 0, 0, 0 });
    @memset(obj, 0);
    for (0..n) |k| {
        if (!raster(k)) return say("  lightmap: out of memory");
    }
    if (!probe.prep()) return say("  lightmap: out of memory");
    if (hive.tris.len == 0) return say("  lightmap: no mesh objects to bake");
    // the covered texels, a list for the workers
    var cnt: usize = 0;
    for (obj) |x| cnt += @intFromBool(x != 0);
    todo = A.alloc(u32, cnt) catch return say("  lightmap: out of memory");
    cnt = 0;
    for (obj, 0..) |x, i| {
        if (x == 0) continue;
        todo[cnt] = @intCast(i);
        cnt += 1;
    }
    covered = cnt;
    // the status bar: 85% the light, then the denoising
    probe.batched(cnt, 16, @ptrFromInt(1), lightJob, 0, 0.85);
    var hole: u32 = 1;
    var k: f32 = 0;
    while (hole <= 4) : (hole <<= 1) {
        var job = Atrous{ .step = @intCast(hole) };
        probe.batched(h, 8, &job, atrousJob, 0.85 + k * 0.04, 0.04);
        std.mem.swap([][3]f32, &rgb, &tmp);
        k += 1;
    }
    for (0..8) |_| dilate();
    jobui.set(1);
    return true;
}

fn say(s: []const u8) bool {
    app.log("{s}", .{s});
    return false;
}

/// Every visible mesh object with triangles gets an entry: its second UVs, its
/// area. False without memory.
fn gather() bool {
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (n >= MAX) break;
        if (!o.kind.isMesh() or !o.visible) continue;
        const me = mods.of(oi) orelse continue;
        if (me.tris.len == 0) continue;
        const uv = A.alloc([2]f32, me.loops.len) catch return false;
        if (!smartuv.unwrap(me, uv)) {
            A.free(uv);
            return false;
        }
        tab[n] = .{ .oid = o.oid, .nloops = @intCast(me.loops.len), .ntris = @intCast(me.tris.len), .uv = uv, .area = @max(area(oi, me), 1e-12) };
        n += 1;
    }
    return true;
}

/// The triangles' area in the world.
fn area(oi: usize, me: *const scene.Mesh) f32 {
    const mtx = scene.world(oi);
    var s: f32 = 0;
    for (me.tris) |t| {
        const a = m.xform(mtx, me.verts[t[0]]);
        const b = m.xform(mtx, me.verts[t[1]]);
        const c = m.xform(mtx, me.verts[t[2]]);
        s += m.len(m.cross(m.sub(b, a), m.sub(c, a))) * 0.5;
    }
    return s;
}

/// Every entry's region: squares by sqrt(area) on shelves, scaled into the unit
/// square, PAD texels in from each side.
fn packRects() void {
    var ord: [MAX]u32 = undefined;
    var sum: f32 = 0;
    var largest: f32 = 0;
    for (tab[0..n], 0..) |*e, i| {
        sum += e.area;
        e.tex = @sqrt(e.area);
        largest = @max(largest, e.tex);
        ord[i] = @intCast(i);
    }
    const shelf = @max(@sqrt(sum) * 1.15, largest);
    // largest first (stable)
    std.sort.insertion(u32, ord[0..n], {}, struct {
        fn f(_: void, a: u32, b: u32) bool {
            return tab[a].tex > tab[b].tex;
        }
    }.f);
    var x: f32 = 0;
    var y: f32 = 0;
    var sh: f32 = 0;
    for (ord[0..n]) |i| {
        const e = &tab[i];
        const s = e.tex;
        if (x + s > shelf) {
            x = 0;
            y += sh;
            sh = 0;
        }
        e.rect = .{ x, y, s, s };
        x += s;
        sh = @max(sh, s);
    }
    const k = 1 / @max(y + sh, shelf);
    const fw: f32 = @floatFromInt(w);
    const px = 1 / fw; // a texel
    const pad = PAD * px;
    for (tab[0..n]) |*e| {
        for (&e.rect) |*c| c.* *= k;
        if (e.rect[2] > pad * 2 + px + pad) { // (big enough to pad)
            e.rect[0] += pad;
            e.rect[1] += pad;
            e.rect[2] -= pad * 2;
            e.rect[3] = e.rect[2];
        }
        e.tex = @sqrt(e.area) / @max(e.rect[2] * fw, 1);
    }
}

/// The loop of a triangle's corner: its vertex in its polygon.
fn triLoop(me: *const scene.Mesh, t: usize, corner: usize) usize {
    const v = me.tris[t][corner];
    const p = me.tri_poly[t];
    const a = me.poff[p];
    for (a..me.poff[p + 1]) |l| {
        if (me.loops[l] == v) return l;
    }
    return a;
}

/// Its triangles into the atlas: every texel centre inside one gets the point
/// and the smooth normal there (world). False without memory.
fn raster(k: usize) bool {
    const e = &tab[k];
    var oi: usize = scene.count;
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.oid == e.oid) oi = i;
    }
    if (oi == scene.count) return true;
    const me = mods.of(oi) orelse return true;
    const mtx = scene.world(oi);
    // smooth normals a vertex (world)
    const vn = A.alloc(m.V3, me.verts.len) catch return false;
    defer A.free(vn);
    @memset(vn, .{ 0, 0, 0 });
    for (me.tris) |t| {
        const a = m.xform(mtx, me.verts[t[0]]);
        const fnr = m.cross(m.sub(m.xform(mtx, me.verts[t[1]]), a), m.sub(m.xform(mtx, me.verts[t[2]]), a));
        for (t) |v| vn[v] = m.add(vn[v], fnr);
    }
    const unit = struct {
        fn f(v: m.V3) m.V3 {
            return m.scale(v, 1 / @max(m.len(v), 1e-12));
        }
    }.f;
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    for (me.tris, 0..) |t, ti| {
        var p: [3]m.V3 = undefined;
        var nr: [3]m.V3 = undefined;
        var x: [3]f32 = undefined;
        var y: [3]f32 = undefined;
        for (0..3) |c| {
            p[c] = m.xform(mtx, me.verts[t[c]]);
            nr[c] = unit(vn[t[c]]);
            const uv = e.uv[triLoop(me, ti, c)];
            x[c] = (uv[0] * e.rect[2] + e.rect[0]) * fw;
            y[c] = ((1 - uv[1]) * e.rect[3] + e.rect[1]) * fh;
        }
        const area2 = (x[1] - x[0]) * (y[2] - y[0]) - (x[2] - x[0]) * (y[1] - y[0]);
        if (!(@abs(area2) > 1e-12)) continue;
        const x0: i32 = @intFromFloat(@max(@floor(@min(x[0], @min(x[1], x[2]))), 0));
        const y0: i32 = @intFromFloat(@max(@floor(@min(y[0], @min(y[1], y[2]))), 0));
        const x1: i32 = @intFromFloat(@min(@trunc(@max(x[0], @max(x[1], x[2]))), fw - 1));
        const y1: i32 = @intFromFloat(@min(@trunc(@max(y[0], @max(y[1], y[2]))), fh - 1));
        var yi = y0;
        while (yi <= y1) : (yi += 1) {
            var xi = x0;
            while (xi <= x1) : (xi += 1) {
                const px = @as(f32, @floatFromInt(xi)) + 0.5;
                const py = @as(f32, @floatFromInt(yi)) + 0.5;
                const b0 = ((x[2] - x[1]) * (py - y[1]) - (y[2] - y[1]) * (px - x[1])) / area2;
                const b1 = ((x[0] - x[2]) * (py - y[2]) - (y[0] - y[2]) * (px - x[2])) / area2;
                const b2 = 1 - b0 - b1;
                if (b0 < -1e-4 or b1 < -1e-4 or b2 < -1e-4) continue;
                const at = @as(usize, @intCast(yi)) * w + @as(usize, @intCast(xi));
                obj[at] = @intCast(k + 1);
                pos[at] = m.add(m.add(m.scale(p[0], b0), m.scale(p[1], b1)), m.scale(p[2], b2));
                nrm[at] = unit(m.add(m.add(m.scale(nr[0], b0), m.scale(nr[1], b1)), m.scale(nr[2], b2)));
            }
        }
    }
    return true;
}

/// Every covered texel: cosine-weighted rays about its normal, the average radiance.
fn lightJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (todo[lo..hi]) |at| {
        var r = pt.Rng.init(at, @as(u64, seed) << 32 | 0x11);
        const nr = nrm[at];
        const a: m.V3 = if (@abs(nr[0]) >= 0.5) .{ 0, 1, 0 } else .{ 1, 0, 0 };
        const t = m.scale(m.cross(a, nr), 1 / @max(m.len(m.cross(a, nr)), 1e-12));
        const b = m.cross(nr, t);
        // the origin: above by a tenth of a texel (at least 1 mm)
        const o = m.add(pos[at], m.scale(nr, @max(tab[obj[at] - 1].tex * 0.1, 0.001)));
        var sum: m.V3 = .{ 0, 0, 0 };
        for (0..spp) |_| {
            const rr = @sqrt(r.f());
            const ph = 2 * std.math.pi * r.f();
            const x = rr * @cos(ph);
            const y = rr * @sin(ph);
            const z = @sqrt(@max(1 - rr * rr, 0));
            const d = m.add(m.add(m.scale(t, x), m.scale(b, y)), m.scale(nr, z));
            var aux = pt.Aux{};
            const L = pt.traceRay(o, d, &aux, &r);
            if (std.math.isFinite(L[0] + L[1] + L[2])) sum = m.add(sum, L);
        }
        const k = 1 / @as(f32, @floatFromInt(spp));
        rgb[at] = .{ sum[0] * k, sum[1] * k, sum[2] * k };
    }
}

const Atrous = struct { step: i32 };

const h5 = [5]f32{ 0.0625, 0.25, 0.375, 0.25, 0.0625 };

/// One a-trous pass from rgb into tmp: 5 x 5 B3 taps of the same object, facing
/// alike (n.n'^16), within 3 x hole texels in the world, of a like luminance.
fn atrousJob(c: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const job: *const Atrous = @ptrCast(@alignCast(c));
    const st = job.step;
    const iw: i32 = @intCast(w);
    const ih: i32 = @intCast(h);
    for (lo..hi) |yu| {
        const y: i32 = @intCast(yu);
        var x: i32 = 0;
        while (x < iw) : (x += 1) {
            const at: usize = @intCast(y * iw + x);
            const id = obj[at];
            if (id == 0) {
                tmp[at] = rgb[at];
                continue;
            }
            const n0 = nrm[at];
            const p0 = pos[at];
            const l0 = rgb[at][0] + rgb[at][1] + rgb[at][2];
            const reach = tab[id - 1].tex * @as(f32, @floatFromInt(st)) * 3;
            const r2 = reach * reach;
            var sum: m.V3 = .{ 0, 0, 0 };
            var ws: f32 = 0;
            var dy: i32 = -2;
            while (dy <= 2) : (dy += 1) {
                const ty = y + dy * st;
                if (ty < 0 or ty >= ih) continue;
                var dx: i32 = -2;
                while (dx <= 2) : (dx += 1) {
                    const tx = x + dx * st;
                    if (tx < 0 or tx >= iw) continue;
                    const q: usize = @intCast(ty * iw + tx);
                    if (obj[q] != id) continue;
                    const dp = m.sub(pos[q], p0);
                    if (m.dot(dp, dp) > r2) continue;
                    var wt = @max(m.dot(nrm[q], n0), 0);
                    wt *= wt;
                    wt *= wt;
                    wt *= wt;
                    wt *= wt;
                    wt *= h5[@intCast(dx + 2)] * h5[@intCast(dy + 2)];
                    // the luminance: gradients stay
                    const v = rgb[q];
                    const l = v[0] + v[1] + v[2];
                    wt *= @max(1 - @abs(l0 - l) / (@max(l0, l) * 0.25 + 0.01), 0);
                    sum = m.add(sum, m.scale(v, wt));
                    ws += wt;
                }
            }
            const k = 1 / @max(ws, 1e-12);
            tmp[at] = .{ sum[0] * k, sum[1] * k, sum[2] * k };
        }
    }
}

fn dilateRows(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const iw: i32 = @intCast(w);
    const ih: i32 = @intCast(h);
    for (lo..hi) |yu| {
        const y: i32 = @intCast(yu);
        var x: i32 = 0;
        while (x < iw) : (x += 1) {
            const at: usize = @intCast(y * iw + x);
            tmp[at][0] = 0;
            if (obj[at] != 0) continue;
            var sum: m.V3 = .{ 0, 0, 0 };
            var cnt: f32 = 0;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                const ty = y + dy;
                if (ty < 0 or ty >= ih) continue;
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const tx = x + dx;
                    if (tx < 0 or tx >= iw) continue;
                    const q: usize = @intCast(ty * iw + tx);
                    if (obj[q] == 0) continue;
                    sum = m.add(sum, rgb[q]);
                    cnt += 1;
                }
            }
            if (cnt == 0) continue;
            rgb[at] = .{ sum[0] / cnt, sum[1] / cnt, sum[2] / cnt };
            tmp[at][0] = 1; // (filled after this pass)
        }
    }
}

/// One pass: every empty texel next to filled ones takes their average and
/// counts as filled.
fn dilate() void {
    jobs.parallelFor(h, 8, @ptrFromInt(1), dilateRows);
    for (tmp, obj) |t, *o| {
        if (t[0] != 0 and o.* == 0) o.* = 0xffff;
    }
}

// --- tests -----------------------------------------------------------------------------

const testing = std.testing;

const NoLook = struct {
    fn get(_: NoLook, _: u32) ?u16 {
        return null;
    }
};

test "packing: one size a texel, inside the square, apart" {
    reset();
    defer reset();
    w = 512;
    h = 512;
    n = 3;
    tab[0] = .{ .area = 16 };
    tab[1] = .{ .area = 1 };
    tab[2] = .{ .area = 4 };
    packRects();
    for (tab[0..3]) |*e| {
        try testing.expect(e.rect[0] >= 0 and e.rect[1] >= 0);
        try testing.expect(e.rect[0] + e.rect[2] <= 1 and e.rect[1] + e.rect[3] <= 1);
        try testing.expectApproxEqAbs(tab[0].tex, e.tex, 0.05 * tab[0].tex); // (the padding takes more of the small)
    }
    for (0..3) |a| {
        for (a + 1..3) |b| {
            const x = tab[a].rect;
            const y = tab[b].rect;
            const px = 1.0 / 512.0;
            try testing.expect(x[0] + x[2] + px <= y[0] or y[0] + y[2] + px <= x[0] or x[1] + x[3] + px <= y[1] or y[1] + y[3] + px <= x[1]);
        }
    }
    n = 0;
}

test "LMAP: the bytes go round; damage gives none" {
    scene.init();
    defer scene.reset();
    reset();
    defer reset();
    const a = A;
    // two entries, 2 x 3
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    const put = struct {
        fn f(o: *std.ArrayList(u8), v: u32) void {
            var x: [4]u8 = undefined;
            std.mem.writeInt(u32, &x, v, .little);
            o.appendSlice(A, &x) catch {};
        }
    }.f;
    put(&src, 2);
    put(&src, 3);
    put(&src, 2);
    for (0..2) |i| {
        put(&src, @intCast(i + 1));
        put(&src, 4); // loops
        put(&src, 2);
        for (0..4) |c| put(&src, @bitCast(@as(f32, @floatFromInt(i * 4 + c)) * 0.125));
    }
    for (0..16 + 2 * 3 * 3) |i| put(&src, @bitCast(@as(f32, @floatFromInt(i))));
    const Look = struct {
        fn get(_: @This(), u: u32) ?u16 {
            return if (u >= 1 and u <= 2) @intCast(u - 1) else null;
        }
    };
    try testing.expect(read(src.items, Look{}));
    try testing.expectEqual(@as(usize, 2), n);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    write(&out, a);
    try testing.expectEqualSlices(u8, src.items, out.items);
    // short by a byte; a huge atlas; more entries than there are; loops past the end
    try testing.expect(!read(src.items[0 .. src.items.len - 1], Look{}));
    try testing.expectEqual(@as(usize, 0), rgb.len);
    var bad = try a.dupe(u8, src.items);
    defer a.free(bad);
    std.mem.writeInt(u32, bad[0..4], 5000, .little);
    try testing.expect(!read(bad, Look{}));
    std.mem.writeInt(u32, bad[0..4], 2, .little);
    std.mem.writeInt(u32, bad[8..12], 129, .little);
    try testing.expect(!read(bad, Look{}));
    std.mem.writeInt(u32, bad[8..12], 2, .little);
    std.mem.writeInt(u32, bad[12 + 4 ..][0..4], 0x40000000, .little);
    try testing.expect(!read(bad, Look{}));
    std.mem.writeInt(u32, bad[12 + 4 ..][0..4], 0xffffffff, .little);
    try testing.expect(!read(bad, Look{}));
    // an object not there: the entry stays, nobody's
    try testing.expect(read(src.items, NoLook{}));
    try testing.expectEqual(@as(u32, 0), tab[0].oid);
    try testing.expect(find(0) == null);
    // none written: none read
    reset();
    var none: std.ArrayList(u8) = .empty;
    defer none.deinit(a);
    write(&none, a);
    try testing.expectEqual(@as(usize, 4), none.items.len);
    try testing.expect(read(none.items, NoLook{}));
}

test "dilation fills what touches a filled texel, passes grow it" {
    reset();
    defer reset();
    w = 8;
    h = 8;
    rgb = try A.alloc([3]f32, 64);
    tmp = try A.alloc([3]f32, 64);
    obj = try A.alloc(u16, 64);
    @memset(rgb, .{ 0, 0, 0 });
    @memset(obj, 0);
    rgb[27] = .{ 2, 2, 2 };
    obj[27] = 1;
    dilate();
    try testing.expectEqual(@as(f32, 2), rgb[26][0]);
    try testing.expectEqual(@as(f32, 2), rgb[36][0]);
    try testing.expectEqual(@as(f32, 0), rgb[25][0]);
    dilate();
    try testing.expect(rgb[25][0] > 1.5);
}

test "a bake: an open sky lights a plane's up face; the shade of a box on it is dark" {
    scene.init();
    defer scene.reset();
    reset();
    defer reset();
    scene.count = 0;
    const g = scene.add(.plane).?;
    scene.objects[g].scl = .{ 10, 1, 10 };
    const c = scene.add(.cube).?;
    scene.objects[c].loc = .{ 0, 0.6, 0 };
    scene.objects[c].scl = .{ 2, 0.2, 2 };
    pt.bounces = 2;
    defer pt.bounces = 12;
    bakeJob("", 128, 64);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(covered > 1000);
    for (rgb) |x| {
        for (x) |v| try testing.expect(std.math.isFinite(v));
    }
    // the plane's middle lies under the box, its corners in the open
    const e = find(scene.objects[g].oid).?;
    var mid: [2]f32 = .{ 0, 0 };
    for (e.uv) |uv| mid = .{ mid[0] + uv[0], mid[1] + uv[1] };
    const k = 1 / @as(f32, @floatFromInt(e.uv.len));
    const at = struct {
        fn f(en: *const Entry, uv: [2]f32) [3]f32 {
            const x: usize = @intFromFloat(std.math.clamp((en.rect[0] + en.rect[2] * uv[0]) * @as(f32, @floatFromInt(w)), 0, @as(f32, @floatFromInt(w - 1))));
            const y: usize = @intFromFloat(std.math.clamp((en.rect[1] + en.rect[3] * (1 - uv[1])) * @as(f32, @floatFromInt(h)), 0, @as(f32, @floatFromInt(h - 1))));
            return rgb[y * w + x];
        }
    }.f;
    const shade = at(e, .{ mid[0] * k, mid[1] * k });
    var open: [3]f32 = .{ 0, 0, 0 };
    for (e.uv) |uv| {
        // a little in from the corner
        const q = at(e, .{ uv[0] * 0.9 + mid[0] * k * 0.1, uv[1] * 0.9 + mid[1] * k * 0.1 });
        if (q[2] > open[2]) open = q;
    }
    try testing.expect(open[2] > 0.2);
    try testing.expect(shade[2] < open[2] * 0.5);
    // saved both ways
    try testing.expect(pixels() != null);
}
