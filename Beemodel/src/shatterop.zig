// Shatter: the operator (shatterop.s). object.shatter breaks the active mesh
// object into pieces: its evaluated mesh (closed: repaired first when it is
// not, refused when that does not close it) is cut into cells (shatter.zig)
// and every piece becomes a mesh object of its own, its origin at its centre
// of volume, placed where it was, a child of the original. The original is
// hidden, not deleted; one undo step brings it back. The patterns:
//   - shards: Voronoi cells from seeds inside the mesh: uniform, around an
//     impact point (closer likelier) or near the surface;
//   - bricks: a running bond in the object's axes (rows along Y), cut by the
//     joints' planes, a mortar gap, joints jittered;
//   - balls: no cutting - spheres on a face-centred cubic lattice, inside and
//     clear of the surface, sharing one sphere mesh.
// An inner colour goes to the cut faces as vertex colours (their vertices
// apart from the surface's). The pieces become rigid bodies (records in the
// animation block, as the original writes them: rbody.zig simulates them)
// unless "nobodies". stat(k) is the original's shinfo(k).
const std = @import("std");
const scene = @import("scene.zig");
const sh = @import("shatter.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const anim = @import("anim.zig");
const rc = @import("rbcore.zig");
const m = @import("math.zig");
const A = @import("alloc.zig").A;
const pa = std.heap.page_allocator;

const V = sh.V;
const MAXSEEDS = 4096;
const SB_MAX = 16384;
const BL_MAX = 131072;
const NSTAT = 24;
const TINY: f64 = 1.0e-300;

/// The last shatter (shinfo): 0 pieces, 1 cells, 2 the pieces' volume, 3 the
/// original's, 4 the smallest piece's, 5 open edges in the pieces, 6 ms, 7
/// glue joints, 8 open edges of the mesh, 9 |pieces' volume - its| / its, 10
/// the smallest piece / the mean one, 11-13 ms seeding, cutting, making; 14-17
/// the cut's phases; balls: 18 the radius, 19 the least gap over a radius, 20
/// the most one reaches past the surface; 21 the bodies' mass, 22 bodies.
pub var stat: [NSTAT]f64 = @splat(0);

// ---- the options (so_*) --------------------------------------------------------------

const Opt = struct {
    pat: u32 = 0, // 0 shards, 1 bricks, 2 balls
    atmode: u32 = 0, // 0 uniform, 1 round a point, 2 near the surface
    count: i32 = 50,
    seed: i32 = 1,
    counted: bool = false,
    spread: f32 = 0.5,
    spreadset: bool = false,
    hassize: bool = false,
    counts: [3]i32 = .{ 8, 4, 1 },
    hascounts: bool = false,
    offset: f32 = 0.5,
    offrand: bool = false,
    gap: f32 = 0,
    jitter: f32 = 0,
    radius: f32 = 0,
    inner: bool = false,
    innerc: u32 = 0,
    density: f32 = 0,
    nobodies: bool = false,
    gluef: f32 = 0,
    gluepaint: bool = false,
    impact: f32 = 0,
    impactset: bool = false,
    preset: u32 = 0,
    again: bool = false,
};
var o: Opt = .{};
/// so_atw, so_size, so_tmp3: kept from one shatter to the next (so_defaults
/// leaves them), a short list of numbers keeps the rest.
var atw: [3]f32 = .{ 0, 0, 0 };
var size: [3]f32 = .{ 0, 0, 0 };
var tmp3: [3]f32 = .{ 0, 0, 0 };

const presets = [_][]const u8{ "none", "brickwall", "glass", "stone", "gravel" };
const Preset = struct { pat: u32, count: i32, glue: f32, impact: f32, dens: f32, gap: f32, spread: f32, spreadset: u32, cx: i32, cy: i32, inner: u32 };
const pdata = [4]Preset{
    .{ .pat = 1, .count = 50, .glue = 40000, .impact = 0, .dens = 1900, .gap = 0.005, .spread = 0.5, .spreadset = 0, .cx = 10, .cy = 5, .inner = 0xff9a8f84 },
    .{ .pat = 0, .count = 60, .glue = 15000, .impact = 10, .dens = 2500, .gap = 0, .spread = 0.5, .spreadset = 0, .cx = 8, .cy = 4, .inner = 0xffd8f0f0 },
    .{ .pat = 0, .count = 25, .glue = 150000, .impact = 0, .dens = 2600, .gap = 0, .spread = 0.5, .spreadset = 0, .cx = 8, .cy = 4, .inner = 0xff8c8c88 },
    .{ .pat = 2, .count = 300, .glue = 0, .impact = 0, .dens = 1800, .gap = 0, .spread = 0.5, .spreadset = 1, .cx = 8, .cy = 4, .inner = 0 },
};
const kws = [_][]const u8{ "shards", "bricks", "balls", "count", "seed", "at", "cursor", "surface", "spread", "size", "counts", "offset", "gap", "jitter", "radius", "inner", "density", "nobodies", "glue", "paint", "impact", "preset", "again" };

/// im_next_word: words split at spaces only, each at most 255 bytes.
const Words = struct {
    s: []const u8,
    i: usize = 0,
    fn next(w: *Words) ?[]const u8 {
        while (w.i < w.s.len and w.s[w.i] == ' ') w.i += 1;
        const st = w.i;
        while (w.i < w.s.len and w.s[w.i] != ' ' and w.s[w.i] != 0) w.i += 1;
        if (w.i == st) {
            w.i = w.s.len;
            return null;
        }
        return w.s[st..@min(w.i, st + 255)];
    }
    fn num(w: *Words) ?f32 {
        const x = w.next() orelse {
            last = "";
            return null;
        };
        last = x;
        return @import("print.zig").parseFloat(x);
    }
    /// pa_vec: up to three numbers into out, the first that is none ends it
    /// (that word gone); never refused (the original's add rsp clears ZF).
    fn vec(w: *Words, out: *[3]f32) bool {
        for (out) |*x| x.* = w.num() orelse return true;
        return true;
    }
};
var last: []const u8 = "";

/// cvttss2si
fn cvtts(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}
/// cvtss2si (round to nearest even)
fn cvtss(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return std.math.minInt(i32);
    var r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5 and @mod(r, 2) != 0) r -= std.math.sign(x);
    return @intFromFloat(r);
}

/// so_parse: the words into o; false at one it does not understand (last).
fn parse(arg: []const u8) bool {
    var w = Words{ .s = arg };
    while (w.next()) |x| {
        last = x;
        const k = for (kws, 0..) |kw, i| {
            if (std.mem.eql(u8, kw, x)) break i;
        } else return false;
        switch (k) {
            0, 1, 2 => o.pat = @intCast(k),
            3 => {
                o.counted = true;
                const v = w.num() orelse return false;
                var n = cvtts(v);
                if (n < 1) return false;
                if (n > MAXSEEDS) n = MAXSEEDS;
                o.count = n;
            },
            4 => o.seed = cvtts(w.num() orelse return false),
            5 => {
                if (!w.vec(&atw)) return false;
                o.atmode = 1;
            },
            6 => {
                atw = scene.cursor;
                o.atmode = 1;
            },
            7 => o.atmode = 2,
            8 => {
                o.spread = w.num() orelse return false;
                o.spreadset = true;
            },
            9 => {
                if (!w.vec(&size)) return false;
                o.hassize = true;
            },
            10 => {
                _ = w.vec(&tmp3);
                for (0..3) |c| o.counts[c] = std.math.clamp(cvtts(tmp3[c]), 1, 4096);
                o.hascounts = true;
            },
            11 => {
                const y = w.next() orelse {
                    last = "";
                    return false;
                };
                last = y;
                if (std.mem.eql(u8, y, "random")) {
                    o.offrand = true;
                } else {
                    o.offset = @import("print.zig").parseFloat(y) orelse return false;
                    o.offrand = false;
                }
            },
            12 => o.gap = w.num() orelse return false,
            13 => o.jitter = w.num() orelse return false,
            14 => o.radius = w.num() orelse return false,
            15 => {
                _ = w.vec(&tmp3);
                var c: u32 = 0xff;
                for (tmp3) |x0| {
                    var x1 = if (x0 > 0) x0 else 0;
                    x1 = if (x1 < 1) x1 else 1;
                    c = (c << 8) | @as(u32, @bitCast(cvtss(x1 * 255.0)));
                }
                o.innerc = c;
                o.inner = true;
            },
            16 => o.density = w.num() orelse return false,
            17 => o.nobodies = true,
            18 => o.gluef = w.num() orelse return false,
            19 => o.gluepaint = true,
            20 => {
                o.impact = w.num() orelse return false;
                o.impactset = true;
            },
            21 => {
                const y = w.next() orelse {
                    last = "";
                    return false;
                };
                last = y;
                const pi = for (presets, 0..) |p, i| {
                    if (std.mem.eql(u8, p, y)) break i;
                } else return false;
                o.preset = @intCast(pi);
                if (pi == 0) continue;
                const d = pdata[pi - 1];
                o.pat = d.pat;
                o.count = d.count;
                o.counted = d.pat != 1;
                o.gluef = d.glue;
                o.impact = d.impact;
                o.impactset = d.impact != 0;
                o.density = d.dens;
                o.gap = d.gap;
                o.spread = d.spread;
                o.spreadset = d.spreadset != 0;
                o.counts[0] = d.cx;
                o.counts[1] = d.cy;
                if (d.inner != 0) {
                    o.innerc = d.inner;
                    o.inner = true;
                }
            },
            22 => o.again = true,
            else => unreachable,
        }
    }
    return true;
}

// ---- random numbers, time ---------------------------------------------------------

var rng: u64 = 0;

/// so_rand: xorshift64*, a double in [0, 1).
fn rand() f64 {
    var x = rng;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rng = x;
    const r = (x *% 0x2545F4914F6CDD1D) >> 11;
    return @as(f64, @floatFromInt(r)) * 1.1102230246251565e-16;
}

fn seedRng(s: i32) void {
    const v: u64 = @as(u32, @bitCast(s));
    rng = ((v *% 0x9E3779B97F4A7C15) +% 1) ^ 0x5851F42D4C957F2D;
}

var t0: i64 = 0;
var tlap: i64 = 0;
fn lap(k: usize) void {
    const t = sh.nowNs();
    const from = if (tlap != 0) tlap else t0;
    tlap = t;
    stat[k] = @as(f64, @floatFromInt(t - from)) / 1000000.0;
}

// ---- the object, its frame ----------------------------------------------------------

var obj: usize = 0;
var mat: [12]f32 = undefined;
var imat: [12]f64 = undefined;
var at: V = .{ 0, 0, 0 };
var meanscale: f32 = 1;

fn diag() f64 {
    var s: f64 = 0;
    for (0..3) |k| {
        const d = sh.src_max[k] - sh.src_min[k];
        s = s + d * d;
    }
    return @sqrt(s);
}

/// so_inverse: imat = mat's inverse (adjugate / determinant; t' = -inv t).
fn inverse() void {
    var a: [9]f64 = undefined;
    for (0..9) |k| a[k] = mat[(k / 3) * 4 + k % 3];
    var r: [12]f64 = undefined;
    r[0] = a[4] * a[8] - a[5] * a[7];
    r[1] = a[2] * a[7] - a[1] * a[8];
    r[2] = a[1] * a[5] - a[2] * a[4];
    r[4] = a[5] * a[6] - a[3] * a[8];
    r[5] = a[0] * a[8] - a[2] * a[6];
    r[6] = a[2] * a[3] - a[0] * a[5];
    r[8] = a[3] * a[7] - a[4] * a[6];
    r[9] = a[1] * a[6] - a[0] * a[7];
    r[10] = a[0] * a[4] - a[1] * a[3];
    var det = a[0] * r[0];
    det = det + a[1] * r[4];
    det = det + a[2] * r[8];
    if (!(@abs(det) > TINY)) det = 1;
    const inv = 1.0 / det;
    for (0..3) |row| {
        for (0..3) |c| r[row * 4 + c] = r[row * 4 + c] * inv;
    }
    for (0..3) |row| {
        var t: f64 = 0;
        for (0..3) |c| t = t - r[row * 4 + c] * @as(f64, mat[c * 4 + 3]);
        r[row * 4 + 3] = t;
    }
    imat = r;
}

fn toLocal(w: [3]f32) V {
    var out: V = undefined;
    for (0..3) |row| {
        var x = imat[row * 4 + 3];
        for (0..3) |c| x = x + @as(f64, w[c]) * imat[row * 4 + c];
        out[row] = x;
    }
    return out;
}

/// so_source: the object's evaluated mesh is the cut's source (repaired when
/// it is not closed); false: refused (said why).
fn source(i: usize) bool {
    const me = @import("mods.zig").of(i) orelse {
        app.log("  shatter: make a mesh object active", .{});
        return false;
    };
    if (!setSource(me.verts, me.poff, me.loops)) return noMem();
    stat[8] = @floatFromInt(sh.open_edges);
    if (sh.open_edges == 0) return true;
    // not closed: repaired
    const fm = @import("fmesh.zig");
    const bb = fm.bbox(me.verts);
    const x = fm.M{ .verts = me.verts, .poff = me.poff, .loops = me.loops, .bmin = bb[0], .bmax = bb[1] };
    if (fm.clean(A, &x) catch null) |cm| {
        defer cm.deinit(A);
        if (!setSource(cm.verts, cm.poff, cm.loops)) return noMem();
        if (sh.open_edges == 0) return true;
    }
    app.log("  shatter: the mesh is not closed even after repair (mesh.repair; open edges: {d})", .{sh.open_edges});
    sh.srcFree();
    return false;
}

fn setSource(verts: []const m.V3, poff: []const u32, loops: []const u32) bool {
    const tris = sh.triangulate(pa, verts, poff, loops) catch return false;
    defer pa.free(tris);
    return sh.srcSet(verts, tris);
}

fn noMem() bool {
    app.log("  shatter: out of memory", .{});
    return false;
}

// ---- shards ---------------------------------------------------------------------------

var cdf: []f64 = &.{};

fn cdfMake() bool {
    if (cdf.len > 0) pa.free(cdf);
    cdf = pa.alloc(f64, sh.src_t.len) catch {
        cdf = &.{};
        return false;
    };
    var s: f64 = 0;
    for (sh.src_t, 0..) |t, i| {
        const a = sh.src_p[t[0]];
        const b = sh.src_p[t[1]];
        const c = sh.src_p[t[2]];
        const e1 = V{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const e2 = V{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        var x = e1[1] * e2[2] - e1[2] * e2[1];
        x = x * x;
        var y = e1[2] * e2[0] - e1[0] * e2[2];
        y = y * y;
        x = x + y;
        var z = e1[0] * e2[1] - e1[1] * e2[0];
        z = z * z;
        x = x + z;
        s = s + @sqrt(x);
        cdf[i] = s;
    }
    return true;
}

/// so_cand_pt: a point to try as a seed.
fn candPt() V {
    var p: V = undefined;
    switch (o.atmode) {
        1 => {
            var d: V = undefined;
            var len: f64 = 0;
            while (true) {
                for (&d) |*x| x.* = rand() * 2.0 - 1.0;
                const l2 = (d[0] * d[0] + d[1] * d[1]) + d[2] * d[2];
                if (l2 > 1) continue;
                if (!(l2 >= 1.0e-6)) continue;
                len = @sqrt(l2);
                break;
            }
            const u = rand();
            var f = diag() * (u * u);
            f = f * @as(f64, o.spread);
            f = f / len;
            for (0..3) |k| p[k] = d[k] * f + at[k];
        },
        2 => {
            const nt = sh.src_t.len;
            const u = rand() * cdf[nt - 1];
            var lo: usize = 0;
            var hi: usize = nt;
            while (lo < hi) {
                const mid = (lo + hi) >> 1;
                if (!(u >= cdf[mid])) hi = mid else lo = mid + 1;
            }
            if (lo >= nt) lo = nt - 1;
            var r1 = rand();
            var r2 = rand();
            if (r1 + r2 > 1) {
                r1 = 1.0 - r1;
                r2 = 1.0 - r2;
            }
            const t = sh.src_t[lo];
            const a = sh.src_p[t[0]];
            const b = sh.src_p[t[1]];
            const c = sh.src_p[t[2]];
            for (0..3) |k| p[k] = ((b[k] - a[k]) * r1 + (c[k] - a[k]) * r2) + a[k];
            const e1 = V{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
            const e2 = V{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
            const n = V{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
            var l = (n[0] * n[0] + n[1] * n[1]) + n[2] * n[2];
            l = @sqrt(l);
            if (!(l > TINY)) l = TINY;
            const s = diag() * 0.01 / l;
            for (0..3) |k| p[k] = p[k] - n[k] * s;
        },
        else => {
            for (0..3) |k| p[k] = rand() * (sh.src_max[k] - sh.src_min[k]) + sh.src_min[k];
        },
    }
    return p;
}

var cand: []V = &.{};
var cin: []u8 = &.{};

fn insideJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |i| cin[i] = @intFromBool(sh.inside(cand[i]));
}

/// so_seeds: n points inside the source, tried in batches (in order).
fn makeSeeds(n: u32) u32 {
    if (sh.seeds.len > 0) pa.free(sh.seeds);
    sh.seeds = pa.alloc(V, n) catch {
        sh.seeds = &.{};
        return 0;
    };
    var made: u32 = 0;
    var tries: i64 = @as(i64, n) * 200 + 1000;
    cand = pa.alloc(V, SB_MAX) catch return 0;
    defer pa.free(cand);
    cin = pa.alloc(u8, SB_MAX) catch return 0;
    defer pa.free(cin);
    while (made < n and tries > 0) {
        const batch: u32 = @min((n - made) * 2 + 32, SB_MAX);
        tries -= batch;
        for (cand[0..batch]) |*p| p.* = candPt();
        sh.insidePrep();
        var dummy: u8 = 0;
        @import("jobs.zig").parallelFor(batch, 8, &dummy, insideJob);
        for (0..batch) |k| {
            if (made >= n) break;
            if (cin[k] == 0) continue;
            sh.seeds[made] = cand[k];
            made += 1;
        }
    }
    sh.seeds = sh.seeds[0..made];
    return made;
}

// ---- bricks --------------------------------------------------------------------------

/// so_bricks: the cells of a running bond (0: none).
fn bricks() u32 {
    if (o.counted and !o.hascounts and !o.hassize) {
        o.counts[0] = o.count;
        var r = o.count >> 1;
        if (r < 1) r = 1;
        o.counts[1] = r;
        o.counts[2] = 1;
    }
    const ob = &scene.objects[obj];
    var sizes: V = undefined;
    var n: [3]i32 = undefined;
    var gap: V = undefined;
    for (0..3) |c| {
        const span = sh.src_max[c] - sh.src_min[c];
        var k = o.counts[c];
        const sc = maxsd(@abs(@as(f64, ob.scl[c])), TINY);
        if (o.hassize and !o.hascounts) {
            const sz = maxsd(@as(f64, size[c]) / sc, TINY);
            k = sh.cvtt(span / sz + 0.5);
            if (k < 1) k = 1;
            if (k > 4096) k = 4096;
        }
        n[c] = k;
        sizes[c] = span / @as(f64, @floatFromInt(k));
        gap[c] = (@as(f64, o.gap) / sc) * 0.5;
    }
    const ncells: i64 = @as(i64, n[0] + 1) * n[1] * n[2];
    if (ncells > MAXSEEDS) return 0;
    if (!sh.cellsAlloc(@intCast(ncells))) return 0;
    var joints: [4096]f64 = undefined;
    var cell: u32 = 0;
    var row: i32 = 0;
    while (row < n[1]) : (row += 1) {
        var off = @as(f64, o.offset) * @as(f64, @floatFromInt(row));
        if (o.offrand) off = rand();
        off = (off - @floor(off)) * sizes[0];
        var x = sh.src_min[0];
        joints[0] = x;
        var nj: usize = 1;
        const e = sizes[0] * 0.01;
        if (off > e and !(off >= sizes[0] - e)) {
            x = x + off;
            joints[nj] = x;
            nj += 1;
        }
        const lim = sh.src_max[0] - e;
        while (true) {
            x = x + sizes[0];
            if (x >= lim) break;
            joints[nj] = x;
            nj += 1;
            if (nj >= 4094) break;
        }
        joints[nj] = sh.src_max[0];
        nj += 1;
        if (@as(f64, o.jitter) > 0) {
            var j: usize = 1;
            while (j + 1 < nj) : (j += 1) {
                var d = rand() - 0.5;
                d = d * @as(f64, o.jitter);
                d = d * sizes[0];
                d = d * 0.5;
                joints[j] = d + joints[j];
            }
        }
        var layer: i32 = 0;
        while (layer < n[2]) : (layer += 1) {
            var b: usize = 0;
            while (b + 1 < nj) : (b += 1) {
                brickCell(cell, &joints, b, row, layer, sizes, gap);
                cell += 1;
            }
        }
    }
    return cell;
}

fn brickCell(cell: u32, joints: []const f64, b: usize, row: i32, layer: i32, sizes: V, gap: V) void {
    var lo: V = undefined;
    var hi: V = undefined;
    lo[0] = joints[b];
    hi[0] = joints[b + 1];
    lo[1] = @as(f64, @floatFromInt(row)) * sizes[1] + sh.src_min[1];
    hi[1] = lo[1] + sizes[1];
    lo[2] = @as(f64, @floatFromInt(layer)) * sizes[2] + sh.src_min[2];
    hi[2] = lo[2] + sizes[2];
    sh.cbb[cell] = .{ lo[0], lo[1], lo[2], hi[0], hi[1], hi[2] };
    const pl = sh.cpl[cell * sh.CPL_MAX ..];
    var np: u32 = 0;
    for (0..6) |side| {
        const a = side >> 1;
        const e = sizes[a] * 0.01;
        const bmin = sh.src_min[a] + e;
        const bmax = sh.src_max[a] - e;
        var p = sh.Plane{};
        if (side & 1 == 0) {
            if (hi[a] >= bmax) continue;
            p.d = hi[a] - gap[a];
            p.n[a] = 1;
        } else {
            if (!(lo[a] > bmin)) continue;
            const v = lo[a] + gap[a];
            p.n[a] = 0 - @as(f64, 1);
            p.d = 0 - v;
        }
        const up: u32 = @intFromBool(side & 1 == 0);
        p.tag = switch (a) {
            0 => ((@as(u32, @intCast(b)) + up) | (@as(u32, @bitCast(row)) << 12)) | (1 << 24),
            1 => (@as(u32, @bitCast(row)) + up) | (2 << 24),
            else => (@as(u32, @bitCast(layer)) + up) | (3 << 24),
        };
        pl[np] = p;
        np += 1;
    }
    sh.cpn[cell] = np;
}

inline fn maxsd(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}
inline fn minsd(a: f64, b: f64) f64 {
    return if (a < b) a else b;
}

// ---- balls ------------------------------------------------------------------------------

// fld1; fld qword [rdi]; fyl2x; fdiv qword [rdi+8]; fld st0; frndint; fsub st1, st0;
// fxch st1; f2xm1; fld1; faddp st1, st0; fscale; fstp st1; fstp qword [rdi]
export const bee_x87_cbrt: [32]u8 linksection(".text") = .{
    0xd9, 0xe8, 0xdd, 0x07, 0xd9, 0xf1, 0xdc, 0x77, 0x08, 0xd9, 0xc0, 0xd9, 0xfc, 0xdc, 0xe9, 0xd9,
    0xc9, 0xd9, 0xf0, 0xd9, 0xe8, 0xde, 0xc1, 0xd9, 0xfd, 0xdd, 0xd9, 0xdd, 0x1f, 0xc3, 0x90, 0x90,
};

fn run87(code: []const u8, mm: *[2]f64) void {
    const f: *const fn (*[2]f64) callconv(.c) void = @ptrCast(code.ptr);
    f(mm);
}

/// so_cbrt: 2^(log2 x / 3) on the x87, as the original (x > 0; else x).
fn cbrt(x: f64) f64 {
    if (!(x > 0)) return x;
    var mm: [2]f64 = .{ x, 3.0 };
    run87(&bee_x87_cbrt, &mm);
    return mm[0];
}

var bpts: []V = &.{};
var bkeep: []u8 = &.{};
var brad_job: f64 = 0;

fn ballJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |i| {
        if (!sh.inside(bpts[i])) {
            bkeep[i] = 0;
            continue;
        }
        const d = sh.dist2(bpts[i]);
        var r = brad_job * 0.8;
        r = r * r;
        bkeep[i] = @intFromBool(d >= r);
    }
}

/// bl_lattice: the face-centred cubic lattice's points in the bounds less r
/// (BL_MAX: too many).
fn lattice(r: f64) usize {
    const a = r * 2.8284271247461903;
    var n: [3]i32 = undefined;
    for (0..3) |c| {
        var s = sh.src_max[c] - sh.src_min[c];
        s = s - r;
        s = s - r;
        s = maxsd(s, 0);
        var k = sh.cvtt(s / a) +% 1;
        if (@as(u32, @bitCast(k)) > 4096) k = 4096;
        n[c] = k;
    }
    const xy = @mulWithOverflow(n[0], n[1]);
    if (xy[1] != 0 or @as(u32, @bitCast(xy[0])) >= BL_MAX) return BL_MAX;
    const xyz = @mulWithOverflow(xy[0], n[2]);
    if (xyz[1] != 0 or @as(u32, @bitCast(xyz[0])) >= BL_MAX / 4) return BL_MAX;
    const fcc = [4]V{ .{ 0, 0, 0 }, .{ 0.5, 0.5, 0 }, .{ 0.5, 0, 0.5 }, .{ 0, 0.5, 0.5 } };
    var k: usize = 0;
    var z: i32 = 0;
    while (z < n[2]) : (z += 1) {
        var y: i32 = 0;
        while (y < n[1]) : (y += 1) {
            var x: i32 = 0;
            while (x < n[0]) : (x += 1) {
                for (fcc) |f| {
                    const ii = [3]i32{ x, y, z };
                    for (0..3) |c| bpts[k][c] = ((@as(f64, @floatFromInt(ii[c])) + f[c]) * a + r) + sh.src_min[c];
                    k += 1;
                }
            }
        }
    }
    brad_job = r;
    return k;
}

var brad: []f64 = &.{};

/// so_balls: balls made.
fn balls() u32 {
    const ob = &scene.objects[obj];
    var ms: f32 = (ob.scl[0] + ob.scl[1]) + ob.scl[2];
    ms = @abs(ms) * 0.33333334;
    meanscale = ms;
    const msd = maxsd(@as(f64, ms), TINY);
    var r: f64 = undefined;
    if (@as(f64, o.radius) > 0) {
        r = @as(f64, o.radius) / msd;
    } else {
        var v = @abs(sh.src_vol) * 0.55;
        v = v / (@as(f64, @floatFromInt(o.count)) * 4.18879020478639);
        r = cbrt(v);
    }
    bpts = pa.alloc(V, BL_MAX) catch return 0;
    defer pa.free(bpts);
    bkeep = pa.alloc(u8, BL_MAX) catch return 0;
    defer pa.free(bkeep);
    var kept: usize = 0;
    var tries: u32 = 0;
    while (true) {
        tries += 1;
        if (tries > 24) break;
        const np = lattice(r);
        if (np >= BL_MAX) {
            r = r * 1.2;
            continue;
        }
        if (np == 0) {
            r = r * 0.5;
            continue;
        }
        sh.insidePrep();
        var dummy: u8 = 0;
        @import("jobs.zig").parallelFor(np, 16, &dummy, ballJob);
        kept = 0;
        for (0..np) |k| {
            if (bkeep[k] == 0) continue;
            bpts[kept] = bpts[k];
            kept += 1;
        }
        if (@as(f64, o.radius) > 0 and !o.counted) {
            o.count = @intCast(@min(kept, MAXSEEDS));
            break;
        }
        if (kept >= @as(usize, @intCast(o.count))) break;
        if (kept == 0) {
            r = r * 0.5;
            continue;
        }
        const q = @as(f64, @floatFromInt(kept)) / @as(f64, @floatFromInt(o.count));
        r = (cbrt(q) * 0.97) * r;
    }
    var n = kept;
    const cnt: usize = @intCast(o.count);
    if (n > cnt) {
        for (0..cnt) |i| {
            const j: usize = @intCast(sh.cvtt(rand() * @as(f64, @floatFromInt(n - i))) + @as(i32, @intCast(i)));
            std.mem.swap(V, &bpts[i], &bpts[j]);
        }
        n = cnt;
    }
    if (n == 0) return 0;
    const sphere = scene.cloneMesh(scene.prim[1]) orelse return 0;
    if (brad.len > 0) pa.free(brad);
    brad = pa.alloc(f64, n) catch return 0;
    const spread: f64 = if (o.spreadset) o.spread else 0;
    var made: u32 = 0;
    for (0..n) |i| {
        const k = newObject(sphere, nextName()) orelse break;
        const b = &scene.objects[k];
        b.color = scene.objects[obj].color;
        b.mat = scene.objects[obj].mat;
        b.selected = true;
        if (first == null) first = k;
        b.loc = place(bpts[i]);
        var s = 1.0 - rand() * spread;
        s = s * r;
        s = s * msd;
        const sf: f32 = @floatCast(s);
        b.scl = .{ sf, sf, sf };
        const br = @as(f64, sf) / msd;
        brad[i] = br;
        var vol = br * br;
        vol = vol * br;
        vol = vol * 4.18879020478639;
        record(k, vol);
        if (nearColour(bpts[i])) |c| b.color = c;
        made += 1;
    }
    stat[18] = r * msd;
    ballStats(made);
    return made;
}

fn ballStats(n: usize) void {
    var gap: f64 = 1.0e300;
    var past: f64 = -1.0e300;
    for (0..n) |i| {
        for (i + 1..n) |j| {
            const p = bpts[i];
            const q = bpts[j];
            var d = (q[0] - p[0]) * (q[0] - p[0]);
            d = d + (q[1] - p[1]) * (q[1] - p[1]);
            d = d + (q[2] - p[2]) * (q[2] - p[2]);
            var g = @sqrt(d) - brad[i];
            g = g - brad[j];
            g = g / brad[i];
            gap = minsd(gap, g);
        }
        const d = @sqrt(sh.dist2(bpts[i]));
        past = maxsd(past, (brad[i] - d) / brad[i]);
    }
    stat[19] = gap;
    stat[20] = past;
}

/// so_near_colour: the colour of the original mesh's vertex nearest p.
fn nearColour(p: V) ?u32 {
    const mi = scene.objects[obj].mesh orelse return null;
    const me = scene.meshes[mi] orelse return null;
    if (me.vcol.len == 0 or sh.src_p.len != me.verts.len or me.vcol.len != me.verts.len) return null;
    var best: f64 = 1.0e300;
    var k: usize = 0;
    for (sh.src_p, 0..) |q, i| {
        var d = (q[0] - p[0]) * (q[0] - p[0]);
        d = d + (q[1] - p[1]) * (q[1] - p[1]);
        d = d + (q[2] - p[2]) * (q[2] - p[2]);
        if (d < best) {
            best = d;
            k = i;
        }
    }
    return me.vcol[k];
}

// ---- the pieces as objects -------------------------------------------------------------

var nbase: [32]u8 = undefined;
var nbase_len: usize = 0;
var ctr: u32 = 0;
var name_buf: [48]u8 = undefined;
var first: ?usize = null;
var pieces: std.ArrayList(usize) = .empty;
var pvol: std.ArrayList(f64) = .empty;

fn baseName(suffix: []const u8) void {
    const nm = scene.objects[obj].name();
    const k = @min(nm.len, 18);
    @memcpy(nbase[0..k], nm[0..k]);
    @memcpy(nbase[k..][0..suffix.len], suffix);
    nbase_len = k + suffix.len;
    ctr = 0;
}

fn nextName() []const u8 {
    ctr += 1;
    return std.fmt.bufPrint(&name_buf, "{s}{d}", .{ nbase[0..nbase_len], ctr }) catch nbase[0..nbase_len];
}

/// unique_name: the base (26 bytes at most), then base.001 ...
fn uniqueName(base0: []const u8, buf: *[32]u8) []const u8 {
    const base = base0[0..@min(base0.len, 26)];
    var k: u32 = 0;
    while (k < 1000) : (k += 1) {
        const nm = if (k == 0) base else std.fmt.bufPrint(buf, "{s}.{d:0>3}", .{ base, k }) catch base;
        if (scene.find(nm) == null) return nm;
    }
    return base;
}

/// obj_new(OT_MESH, name, mesh): a mesh object at the end, its colour the
/// type's (the caller sets the rest).
fn newObject(mi: u16, name: []const u8) ?usize {
    if (scene.count >= scene.max_objects) return null;
    var buf: [32]u8 = undefined;
    var nb: [32]u8 = undefined;
    const nm0 = std.fmt.bufPrint(&nb, "{s}", .{name[0..@min(name.len, 31)]}) catch name;
    const nm = uniqueName(nm0, &buf);
    var ob = scene.Object{ .kind = .mesh, .mesh = mi, .color = 0xb4b8c0 };
    ob.setName(nm);
    const k = scene.count;
    scene.objects[k] = ob;
    scene.stamp(k);
    scene.count += 1;
    return k;
}

/// loc = M c (floats, the original's order)
fn place(c: V) m.V3 {
    const x: f32 = @floatCast(c[0]);
    const y: f32 = @floatCast(c[1]);
    const z: f32 = @floatCast(c[2]);
    var out: m.V3 = undefined;
    for (0..3) |row| out[row] = ((mat[row * 4] * x + mat[row * 4 + 1] * y) + mat[row * 4 + 2] * z) + mat[row * 4 + 3];
    return out;
}

fn record(k: usize, vol: f64) void {
    pieces.append(pa, k) catch return;
    pvol.append(pa, vol) catch {
        _ = pieces.pop();
    };
}

/// so_make: a piece's object (its mesh from its centre; placed at the centre,
/// turned and scaled like the original).
fn make(p: *const sh.Piece) ?usize {
    const nv = p.verts.len;
    // an inner colour: the cut faces' vertices twice
    var imap: []u32 = &.{};
    var irev: std.ArrayList(u32) = .empty;
    defer if (imap.len > 0) A.free(imap);
    defer irev.deinit(pa);
    if (o.inner) {
        imap = A.alloc(u32, nv) catch &.{};
        if (imap.len == nv) {
            @memset(imap, 0xffffffff);
            var f: usize = 0;
            for (p.cnt, p.tag) |c, t| {
                if (t != 0) {
                    for (p.loops[f..][0..c]) |v| {
                        if (imap[v] != 0xffffffff) continue;
                        imap[v] = @intCast(irev.items.len);
                        irev.append(pa, v) catch {};
                    }
                }
                f += c;
            }
        }
    }
    const ni = irev.items.len;
    const verts = A.alloc(m.V3, nv + ni) catch return null;
    defer A.free(verts);
    @memcpy(verts[0..nv], p.verts);
    for (irev.items, 0..) |v, k| verts[nv + k] = p.verts[v];
    const poff = A.alloc(u32, p.cnt.len + 1) catch return null;
    defer A.free(poff);
    const loops = A.dupe(u32, p.loops) catch return null;
    defer A.free(loops);
    poff[0] = 0;
    var f: u32 = 0;
    for (p.cnt, p.tag, 0..) |c, t, k| {
        if (ni > 0 and t != 0 and c <= 256) {
            for (loops[f..][0..c]) |*v| v.* = imap[v.*] + @as(u32, @intCast(nv));
        }
        f += c;
        poff[k + 1] = f;
    }
    const mi = scene.addMesh(verts, poff, loops) orelse return null;
    if (ni > 0) {
        const me = &scene.meshes[mi].?;
        if (@import("vcol.zig").alloc(me)) {
            for (nv..nv + ni) |k| me.vcol[k] = o.innerc | 0xff000000;
        }
    }
    const k = newObject(mi, nextName()) orelse return null;
    record(k, p.vol);
    const src = &scene.objects[obj];
    const b = &scene.objects[k];
    b.color = src.color;
    b.mat = src.mat;
    b.rot = src.rot;
    b.rad = src.rad;
    b.rad_deg = src.rad_deg;
    b.scl = src.scl;
    b.selected = true;
    b.loc = place(p.c);
    return k;
}

/// so_build: every cell's pieces into objects; the stats.
fn build() u32 {
    var made: u32 = 0;
    first = null;
    var np: usize = 0;
    for (sh.res) |cell| {
        for (cell) |*p| np += p.cnt.len;
    }
    grp.clearRetainingCapacity();
    grp_cap = np;
    stat[2] = 0;
    stat[5] = 0;
    stat[3] = sh.src_vol;
    stat[4] = sh.src_vol;
    for (sh.res) |cell| {
        for (cell) |*p| {
            stat[2] = stat[2] + p.vol;
            stat[4] = minsd(p.vol, stat[4]);
            stat[5] = @as(f64, @floatFromInt(sh.polysOpen(p.cnt, p.loops))) + stat[5];
            const k = make(p) orelse continue;
            groups(p, pieces.items.len - 1);
            made += 1;
            if (first == null) first = k;
        }
    }
    stat[0] = @floatFromInt(made);
    const v = maxsd(stat[3], TINY);
    stat[9] = @abs(stat[2] - stat[3]) / v;
    stat[10] = (stat[4] * stat[1]) / v;
    return made;
}

// ---- rigid bodies (records in the animation block, as the original writes them) -------

fn growRb(b: *anim.Block, n: usize) ?[]u8 {
    const need = (n + 1) * rc.RB_SZ;
    if (b.rb.len < need) {
        const nb = A.realloc(b.rb, need) catch return null;
        b.rb = nb;
    }
    return b.rb[n * rc.RB_SZ ..][0..rc.RB_SZ];
}

/// so_bodies: every piece a child of the original (folded), then an active
/// body (a hull; a ball a sphere) unless nobodies.
fn bodies() u32 {
    const src = &scene.objects[obj];
    src.folded = true;
    for (pieces.items) |k| {
        // (its world place kept as the original holds it: OB_LOC, OB_ROT, OB_SCALE)
        const wp = scene.worldPlace(k);
        if (scene.setParent(k, obj)) scene.keepWorldPlace(k, wp);
    }
    if (o.nobodies) return 0;
    const b = anim.own(0) orelse {
        app.log("  shatter: no room for more rigid bodies (4096) - the rest are not bodies", .{});
        return 0;
    };
    var fric: u32 = @bitCast(@as(f32, 0.5));
    var rest: u32 = 0;
    var damp: u32 = 0;
    var flags: u32 = 0;
    var vel: [12]u8 = @splat(0);
    const nrb: usize = @min(b.h.nrb, b.rb.len / rc.RB_SZ);
    for (0..nrb) |k| {
        const r = b.rb[k * rc.RB_SZ ..][0..rc.RB_SZ];
        if (rc.rdU(r, rc.RB_UID) != src.oid) continue;
        fric = rc.rdU(r, rc.RB_FRIC);
        rest = rc.rdU(r, rc.RB_REST);
        damp = rc.rdU(r, rc.RB_DAMP);
        flags = rc.rdU(r, rc.RB_FLAGS) & ~@as(u32, 3);
        @memcpy(&vel, r[rc.RB_VEL..][0..12]);
        break;
    }
    var dens: f32 = o.density;
    if (!(dens > 0)) {
        dens = 1000;
        if (@import("material.zig").of(src)) |ma| {
            if (ma.density > 0) dens = ma.density * 1000.0;
        }
    }
    const densd: f64 = dens;
    var dets: f64 = src.scl[0];
    dets = dets * @as(f64, src.scl[1]);
    dets = dets * @as(f64, src.scl[2]);
    dets = @abs(dets);
    var total: f64 = 0;
    var made: u32 = 0;
    for (pieces.items, pvol.items) |k, v| {
        const n: usize = @min(b.h.nrb, b.rb.len / rc.RB_SZ);
        if (n >= rc.RB_MAX) {
            app.log("  shatter: no room for more rigid bodies (4096) - the rest are not bodies", .{});
            break;
        }
        const r = growRb(b, n) orelse break;
        b.h.nrb = @intCast(n + 1);
        @memset(r, 0);
        rc.wrU(r, rc.RB_UID, scene.objects[k].oid);
        rc.wrU(r, rc.RB_TYPE, 1);
        rc.wrU(r, rc.RB_SHAPE, if (o.pat == 2) 1 else 3);
        var mass = @abs(v);
        if (o.pat == 2) {
            const s: f64 = meanscale;
            mass = mass * s;
            mass = mass * s;
            mass = mass * s;
        } else mass = mass * dets;
        mass = mass * densd;
        total = total + mass;
        rc.wrF(r, rc.RB_MASS, @floatCast(mass));
        rc.wrU(r, rc.RB_FRIC, fric);
        rc.wrU(r, rc.RB_REST, rest);
        rc.wrU(r, rc.RB_DAMP, damp);
        rc.wrU(r, rc.RB_FLAGS, flags);
        @memcpy(r[rc.RB_VEL..][0..12], &vel);
        if (o.impactset) {
            // waiting for the original to break: hidden
            rc.wrU(r, rc.RB_FLAGS, flags | 8);
            scene.objects[k].visible = false;
            scene.objects[k].selected = false;
        }
        made += 1;
    }
    if (o.impactset) impactMarks(b, fric, rest, densd, dets);
    stat[22] = @floatFromInt(made);
    stat[21] = total;
    return made;
}

fn growJt(b: *anim.Block, n: usize) ?[]u8 {
    const need = (n + 1) * rc.JT_SZ;
    if (b.jt.len < need) {
        const nb = A.realloc(b.jt, need) catch return null;
        b.jt = nb;
    }
    return b.jt[n * rc.JT_SZ ..][0..rc.JT_SZ];
}

/// so_impact_marks: the original an active body (as it is; else a hull of
/// its volume x the density) that breaks on impact, and the marker joint.
fn impactMarks(b: *anim.Block, fric: u32, rest: u32, dens: f64, dets: f64) void {
    const src = &scene.objects[obj];
    const n: usize = @min(b.h.nrb, b.rb.len / rc.RB_SZ);
    var e: ?[]u8 = null;
    for (0..n) |k| {
        const r = b.rb[k * rc.RB_SZ ..][0..rc.RB_SZ];
        if (rc.rdU(r, rc.RB_UID) == src.oid) {
            e = r;
            break;
        }
    }
    if (e == null) {
        if (n >= rc.RB_MAX) return;
        const r = growRb(b, n) orelse return;
        b.h.nrb = @intCast(n + 1);
        @memset(r, 0);
        rc.wrU(r, rc.RB_UID, src.oid);
        rc.wrU(r, rc.RB_TYPE, 1);
        rc.wrU(r, rc.RB_SHAPE, 3);
        var mass = @abs(sh.src_vol) * dets;
        mass = mass * dens;
        rc.wrF(r, rc.RB_MASS, @floatCast(mass));
        rc.wrU(r, rc.RB_FRIC, fric);
        rc.wrU(r, rc.RB_REST, rest);
        e = r;
    }
    const r = e.?;
    rc.wrU(r, rc.RB_FLAGS, rc.rdU(r, rc.RB_FLAGS) | 4);
    const nj: usize = @min(b.h.njt, b.jt.len / rc.JT_SZ);
    if (nj >= rc.JT_MAX) return;
    const j = growJt(b, nj) orelse return;
    b.h.njt = @intCast(nj + 1);
    @memset(j, 0);
    rc.wrU(j, rc.JT_TYPE, 5);
    rc.wrU(j, rc.JT_A, src.oid);
    rc.wrF(j, rc.JT_BRK, o.impact);
}

// ---- glue ------------------------------------------------------------------------------

/// A piece's cut faces of one tag: its piece (index in pieces), area, area x
/// centre, area x normal, bounds (local).
const Group = struct { piece: u32, tag: u32, area: f64 = 0, c: V = .{ 0, 0, 0 }, n: V = .{ 0, 0, 0 }, min: V, max: V };
var grp: std.ArrayList(Group) = .empty;
var grp_cap: usize = 0;

/// so_groups: a piece's cut faces' groups by tag.
fn groups(p: *const sh.Piece, pidx: usize) void {
    const g0 = grp.items.len;
    var f: usize = 0;
    for (p.cnt, p.tag) |cnt, tag| {
        defer f += cnt;
        if (tag == 0) continue;
        var gi: ?usize = null;
        for (grp.items[g0..], g0..) |*g, k| {
            if (g.tag == tag) {
                gi = k;
                break;
            }
        }
        if (gi == null) {
            if (grp.items.len >= grp_cap) continue;
            grp.append(pa, .{ .piece = @intCast(pidx), .tag = tag, .min = .{ 1.0e300, 1.0e300, 1.0e300 }, .max = .{ -1.0e300, -1.0e300, -1.0e300 } }) catch continue;
            gi = grp.items.len - 1;
        }
        const g = &grp.items[gi.?];
        const l = p.loops[f..][0..cnt];
        const p0 = gpVert(p, l[0]);
        var k: usize = 1;
        while (k + 1 < cnt) : (k += 1) {
            const v1 = gpVert(p, l[k]);
            const v2 = gpVert(p, l[k + 1]);
            const a = V{ v1[0] - p0[0], v1[1] - p0[1], v1[2] - p0[2] };
            const b = V{ v2[0] - p0[0], v2[1] - p0[1], v2[2] - p0[2] };
            const n = V{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
            for (0..3) |c| g.n[c] = g.n[c] + n[c];
            var ar = n[0] * n[0] + n[1] * n[1];
            ar = ar + n[2] * n[2];
            ar = @sqrt(ar) * 0.5;
            g.area = g.area + ar;
            for (0..3) |c| {
                var x = b[c] + a[c];
                x = x * 0.3333333333333333;
                x = x + p0[c];
                x = x * ar;
                g.c[c] = x + g.c[c];
            }
        }
        for (l) |v| {
            const q = gpVert(p, v);
            for (0..3) |c| {
                g.min[c] = minsd(g.min[c], q[c]);
                g.max[c] = maxsd(g.max[c], q[c]);
            }
        }
    }
}

fn gpVert(p: *const sh.Piece, v: u32) V {
    const q = p.verts[v];
    return .{ @as(f64, q[0]) + p.c[0], @as(f64, q[1]) + p.c[1], @as(f64, q[2]) + p.c[2] };
}

/// so_gap_tol: how far apart two faces of a joint can be.
fn gapTol() f64 {
    var h = diag() * 1.0e-6;
    const ob = &scene.objects[obj];
    for (0..3) |c| {
        const sc = maxsd(@abs(@as(f64, ob.scl[c])), TINY);
        var t = @as(f64, o.gap) / sc;
        t = t + h;
        h = maxsd(h, t);
    }
    return h + 1.0e-6;
}

/// so_glue: pieces that share a face tied by a fixed joint breaking at the
/// glue's strength x the face's area.
fn glue() u32 {
    if (!(o.gluef > 0) or o.nobodies or grp.items.len < 2) return 0;
    const n = grp.items.len;
    const keys = pa.alloc(u64, n) catch return 0;
    defer pa.free(keys);
    for (grp.items, 0..) |*g, k| {
        keys[k] = (@as(u64, g.tag) << 32) | k;
        const ar = maxsd(g.area, TINY);
        for (0..3) |c| g.c[c] = g.c[c] / ar;
    }
    sh.sortU64(keys);
    const b = anim.own(0) orelse return 0;
    const gtol = gapTol();
    var made: u32 = 0;
    var i: usize = 0;
    while (i < n) {
        const tag = keys[i] >> 32;
        var e = i + 1;
        while (e < n and keys[e] >> 32 == tag) e += 1;
        for (i..e) |x| {
            for (x + 1..e) |y| {
                const g1 = &grp.items[@as(u32, @truncate(keys[x]))];
                const g2 = &grp.items[@as(u32, @truncate(keys[y]))];
                if (meet(g1, g2, gtol)) |mt| {
                    if (joint(b, g1.piece, g2.piece, mt)) made += 1;
                }
            }
        }
        i = e;
    }
    return made;
}

const Meet = struct { area: f64, piv: V };

fn meet(g1: *const Group, g2: *const Group, gtol: f64) ?Meet {
    if (g1.piece == g2.piece) return null;
    var d = g1.n[0] * g2.n[0] + g1.n[1] * g2.n[1];
    d = d + g1.n[2] * g2.n[2];
    if (d >= 0) return null;
    var w: V = undefined;
    var mt: Meet = undefined;
    for (0..3) |c| {
        const hi = minsd(g1.max[c], g2.max[c]);
        const lo = maxsd(g1.min[c], g2.min[c]);
        mt.piv[c] = (hi + lo) * 0.5;
        const x = hi - lo;
        if (!(x >= 0 - gtol)) return null;
        w[c] = maxsd(x, 0);
    }
    var a = w[0] * w[1];
    a = maxsd(a, w[0] * w[2]);
    a = maxsd(a, w[1] * w[2]);
    a = minsd(a, minsd(g1.area, g2.area));
    if (!(a > TINY)) return null;
    mt.area = a;
    return mt;
}

fn joint(b: *anim.Block, pa_: u32, pb: u32, mt: Meet) bool {
    const nj: usize = @min(b.h.njt, b.jt.len / rc.JT_SZ);
    if (nj >= rc.JT_MAX) return false;
    const r = growJt(b, nj) orelse return false;
    b.h.njt = @intCast(nj + 1);
    @memset(r, 0);
    rc.wrU(r, rc.JT_TYPE, 1);
    rc.wrU(r, rc.JT_A, scene.objects[pieces.items[pa_]].oid);
    rc.wrU(r, rc.JT_B, scene.objects[pieces.items[pb]].oid);
    rc.wrF(r, rc.JT_AXIS + 4, 1.0);
    for (0..3) |row| {
        var x = mat[row * 4 + 3];
        for (0..3) |c| x = x + @as(f32, @floatCast(mt.piv[c])) * mat[row * 4 + c];
        rc.wrF(r, rc.JT_PIV + row * 4, x);
    }
    const ob = &scene.objects[obj];
    var dets: f64 = ob.scl[0];
    dets = dets * @as(f64, ob.scl[1]);
    dets = dets * @as(f64, ob.scl[2]);
    var brk = cbrt(@abs(dets));
    brk = brk * brk;
    brk = brk * mt.area;
    brk = brk * @as(f64, o.gluef);
    if (o.atmode == 1) {
        var dd: f64 = 0;
        for (0..3) |c| {
            const x = mt.piv[c] - at[c];
            dd = dd + x * x;
        }
        dd = @sqrt(dd);
        const s = maxsd(diag() * @as(f64, o.spread), TINY);
        var f = dd / s;
        f = maxsd(f, 0.2);
        f = minsd(f, 1.0);
        brk = f * brk;
    }
    if (o.gluepaint) {
        if (nearColour(mt.piv)) |col| {
            const sum = (col & 0xff) + ((col >> 8) & 0xff) + ((col >> 16) & 0xff);
            brk = @as(f64, @floatFromInt(sum)) / 765.0 * brk;
        }
    }
    var bf: f32 = @floatCast(brk);
    bf = if (bf > 1.0e-3) bf else 1.0e-3;
    rc.wrF(r, rc.JT_BRK, bf);
    return true;
}

/// so_unshatter: from a piece, its original; the pieces made before go (their
/// bodies, their joints), the original shown and active.
fn unshatter(start: usize) usize {
    var i = start;
    if (scene.objects[i].parent) |p| i = p;
    const orig_oid = scene.objects[i].oid;
    if (anim.own(0)) |b| {
        var k: usize = @min(b.h.nrb, b.rb.len / rc.RB_SZ);
        while (k > 0) {
            k -= 1;
            const r = b.rb[k * rc.RB_SZ ..][0..rc.RB_SZ];
            if (!isPiece(rc.rdU(r, rc.RB_UID), orig_oid)) continue;
            const n = @min(b.h.nrb, b.rb.len / rc.RB_SZ) - 1;
            b.h.nrb = @intCast(n);
            std.mem.copyForwards(u8, r, b.rb[n * rc.RB_SZ ..][0..rc.RB_SZ]);
        }
        var j: usize = @min(b.h.njt, b.jt.len / rc.JT_SZ);
        while (j > 0) {
            j -= 1;
            const r = b.jt[j * rc.JT_SZ ..][0..rc.JT_SZ];
            const marker = rc.rdU(r, rc.JT_TYPE) == 5 and rc.rdU(r, rc.JT_A) == orig_oid;
            if (!marker and !isPiece(rc.rdU(r, rc.JT_A), orig_oid) and !isPiece(rc.rdU(r, rc.JT_B), orig_oid)) continue;
            const n = @min(b.h.njt, b.jt.len / rc.JT_SZ) - 1;
            b.h.njt = @intCast(n);
            std.mem.copyForwards(u8, r, b.jt[n * rc.JT_SZ ..][0..rc.JT_SZ]);
        }
    }
    var k = scene.count;
    while (k > 0) {
        k -= 1;
        const p = scene.objects[k].parent orelse continue;
        if (scene.objects[p].oid == orig_oid) scene.remove(k);
    }
    const oi = scene.findOid(orig_oid).?;
    scene.objects[oi].visible = true;
    scene.objects[oi].selected = true;
    scene.active = oi;
    return oi;
}

fn isPiece(oid: u32, orig_oid: u32) bool {
    const i = scene.findOid(oid) orelse return false;
    const p = scene.objects[i].parent orelse return false;
    return scene.objects[p].oid == orig_oid;
}

// ---- object.shatter ----------------------------------------------------------------------

/// do_shatter
pub fn opShatter() void {
    t0 = sh.nowNs();
    tlap = 0;
    sh.cnt_ns = @splat(0);
    stat = @splat(0);
    o = .{};
    pieces.clearRetainingCapacity();
    pvol.clearRetainingCapacity();
    if (!parse(ops.arg)) {
        // (the original's console cuts this line at 95 characters, so the word
        // it did not understand never shows: here it comes first, on its own)
        app.log("  object.shatter: not understood: {s}", .{last});
        app.log("  object.shatter <shards|bricks|balls> [count n] [seed s] [at x y z | cursor | surface] [spread f] [size x y z | counts a b c] [offset f|random] [gap g] [jitter f] ...", .{});
        return;
    }
    @import("shatterui.zig").sync(o.pat, o.preset, o.count, o.gluef, o.impact); // (sp_sync)
    const a = scene.active orelse return noneMsg();
    if (a >= scene.count or !scene.objects[a].kind.isMesh() or scene.objects[a].mesh == null) return noneMsg();
    obj = a;
    if (o.again) obj = unshatter(obj);
    if (!source(obj)) return;
    defer sh.srcFree();
    mat = @import("fields.zig").objMatrix(obj);
    inverse();
    if (o.atmode == 1) at = toLocal(atw);
    seedRng(o.seed);
    var made: u32 = 0;
    switch (o.pat) {
        1, 0 => {
            var n: u32 = 0;
            if (o.pat == 0) {
                if (o.atmode == 2 and !cdfMake()) return mem();
                n = makeSeeds(@intCast(o.count));
                lap(11);
                if (n == 0) return noSeed();
                stat[1] = @floatFromInt(n);
                sh.mode = 1;
                baseName("_shard_");
            } else {
                n = bricks();
                if (n == 0) return mem();
                sh.ncell = n;
                stat[1] = @floatFromInt(n);
                sh.mode = 0;
                baseName("_brick_");
            }
            const ok = sh.cutAll(n);
            lap(12);
            if (!ok) return mem();
            const src = &scene.objects[obj];
            if (!o.impactset) {
                src.visible = false;
                src.selected = false;
            }
            made = build();
            _ = bodies();
            stat[7] = @floatFromInt(glue());
            lap(13);
        },
        else => {
            baseName("_ball_");
            first = null;
            made = balls();
            stat[0] = @floatFromInt(made);
            stat[1] = @floatFromInt(made);
            if (made == 0) return noSeed();
            const src = &scene.objects[obj];
            src.visible = false;
            src.selected = false;
            _ = bodies();
            lap(13);
        },
    }
    for (1..5) |k| stat[13 + k] = @as(f64, @floatFromInt(sh.cnt_ns[k])) / 1000000.0;
    sh.resFree();
    if (first) |f| {
        if (!o.impactset) scene.active = f;
    }
    stat[6] = @as(f64, @floatFromInt(sh.nowNs() - t0)) / 1000000.0;
    app.log("  shattered into {d} pieces ({d} ms)", .{ made, @as(i64, @intFromFloat(stat[6])) });
    app.dirty = true;
    undo.label("Shatter");
}

fn noneMsg() void {
    app.log("  shatter: make a mesh object active", .{});
}
fn noSeed() void {
    app.log("  shatter: no room inside the mesh for the cells", .{});
}
fn mem() void {
    app.log("  shatter: out of memory", .{});
}

// ---- mesh.separate_loose ------------------------------------------------------------------

/// do_sep_loose: each selected mesh object split into one object a loose part
/// (polygons that share no vertex), named Name_part_1 ..., where it was; the
/// original goes.
pub fn opSepLoose() void {
    var made: usize = 0;
    var n = scene.count;
    var i: usize = 0;
    while (i < n) {
        const ob = &scene.objects[i];
        if (ob.selected and ob.kind.isMesh() and ob.mesh != null) {
            const k = sepSplit(i);
            if (k > 0) {
                made += k;
                scene.remove(i);
                n -= 1;
                continue;
            }
        }
        i += 1;
    }
    if (made == 0) {
        app.log("  separate: select mesh objects with loose parts", .{});
        return;
    }
    app.log("  separated into loose parts: {d}", .{made});
    app.dirty = true;
    undo.label("Separate By Loose Parts");
}

fn ufRoot(p: []u32, x0: u32) u32 {
    var x = x0;
    while (p[x] != x) {
        const g = p[p[x]];
        p[x] = g;
        x = g;
    }
    return x;
}

/// sl_split: objects made of i's base mesh's parts (0: one part, nothing done).
fn sepSplit(i: usize) usize {
    const me = &(scene.meshes[scene.objects[i].mesh.?] orelse return 0);
    const nv = me.verts.len;
    if (nv == 0) return 0;
    const par = A.alloc(u32, nv) catch return 0;
    defer A.free(par);
    const part = A.alloc(u32, nv) catch return 0;
    defer A.free(part);
    for (par, 0..) |*x, k| x.* = @intCast(k);
    @memset(part, 0xffffffff);
    const np = me.poff.len - 1;
    for (0..np) |p| {
        const l = me.loops[me.poff[p]..me.poff[p + 1]];
        if (l.len == 0) continue;
        for (l[1..]) |v| {
            const ra = ufRoot(par, l[0]);
            const rb = ufRoot(par, v);
            if (ra == rb) continue;
            if (rb < ra) par[ra] = rb else par[rb] = ra;
        }
    }
    var nparts: u32 = 0;
    for (0..np) |p| {
        const r = ufRoot(par, me.loops[me.poff[p]]);
        if (part[r] == 0xffffffff) {
            part[r] = nparts;
            nparts += 1;
        }
    }
    if (nparts < 2) return 0;
    obj = i;
    baseName("_part_");
    var made: usize = 0;
    for (0..nparts) |k| {
        if (sepPart(i, @intCast(k), par, part)) made += 1;
    }
    return made;
}

/// sl_part: an object of that part's polygons (vertex colours and UVs kept).
fn sepPart(i: usize, k: u32, par: []u32, part: []u32) bool {
    const me = &(scene.meshes[scene.objects[i].mesh.?] orelse return false);
    const map = A.alloc(u32, me.verts.len) catch return false;
    defer A.free(map);
    @memset(map, 0xffffffff);
    var verts: std.ArrayList(m.V3) = .empty;
    defer verts.deinit(A);
    var cols: std.ArrayList(u32) = .empty;
    defer cols.deinit(A);
    var poff: std.ArrayList(u32) = .empty;
    defer poff.deinit(A);
    var loops: std.ArrayList(u32) = .empty;
    defer loops.deinit(A);
    var uv: std.ArrayList([2]f32) = .empty;
    defer uv.deinit(A);
    const has_uv = me.uv.len == me.loops.len and me.uv.len > 0;
    const has_col = me.vcol.len == me.verts.len and me.vcol.len > 0;
    poff.append(A, 0) catch return false;
    for (0..me.poff.len - 1) |p| {
        const l = me.loops[me.poff[p]..me.poff[p + 1]];
        if (l.len == 0 or part[ufRoot(par, l[0])] != k) continue;
        const take = @min(l.len, 256);
        for (l[0..take]) |v| {
            if (map[v] == 0xffffffff) {
                map[v] = @intCast(verts.items.len);
                verts.append(A, me.verts[v]) catch return false;
                if (has_col) cols.append(A, me.vcol[v]) catch return false;
            }
            loops.append(A, map[v]) catch return false;
        }
        if (has_uv) uv.appendSlice(A, me.uv[me.poff[p]..][0..take]) catch return false;
        poff.append(A, @intCast(loops.items.len)) catch return false;
    }
    const mi = scene.addMesh(verts.items, poff.items, loops.items) orelse return false;
    const nm = &scene.meshes[mi].?;
    if (has_uv) nm.uv = A.dupe([2]f32, uv.items) catch &.{};
    if (has_col) nm.vcol = A.dupe(u32, cols.items) catch &.{};
    const ko = newObject(mi, nextName()) orelse return false;
    const src = &scene.objects[i];
    const b = &scene.objects[ko];
    if (src.parent == null) {
        b.loc = src.loc;
        b.rot = src.rot;
        b.rad = src.rad;
        b.rad_deg = src.rad_deg;
        b.scl = src.scl;
    } else {
        const wp = scene.worldPlace(i); // (its world place, as the original holds it)
        b.loc = wp[0..3].*;
        b.setRadians(wp[3..6].*);
        b.scl = wp[6..9].*;
    }
    b.color = src.color;
    b.mat = src.mat;
    b.selected = true;
    return true;
}

const Impl = ops.Impl;
pub const list = .{
    .{ "object.shatter", Impl{ .run = opShatter } },
};

test "so_rand as the original's xorshift64*" {
    seedRng(1);
    const a = rand();
    try std.testing.expect(a >= 0 and a < 1);
    seedRng(1);
    try std.testing.expectEqual(a, rand());
}

test "the presets' words" {
    o = .{};
    try std.testing.expect(parse("preset brickwall count 9"));
    try std.testing.expectEqual(@as(u32, 1), o.pat);
    try std.testing.expectEqual(@as(i32, 9), o.count);
    try std.testing.expect(o.inner);
    o = .{};
    try std.testing.expect(!parse("bricks bogus"));
    try std.testing.expectEqualStrings("bogus", last);
}
