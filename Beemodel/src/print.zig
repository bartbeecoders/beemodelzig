// Printability (print.s, printui.s): wall thickness and the print check.
//
// thFaces measures every face's wall: a ray from its centre straight in
// (against its normal, world space) to the nearest other face. The rays walk a
// uniform grid of the mesh's triangles (3D DDA; Moller-Trumbore per triangle),
// and the result is cached until the mesh or its transform changes. The
// analysis overlay (analysis.zig, View > Show Thin Walls) colours faces under
// the minimum red and under twice it yellow; mesh.print_check reports
// closedness, the thinnest wall, overhangs and the size for the selected
// meshes, and Properties > Object shows the last check's findings with Show
// buttons (mesh.print_show). All in f32 as the original, step for step.
const std = @import("std");
const app = @import("app.zig");
const scene = @import("scene.zig");
const m = @import("math.zig");
const cad = @import("cad.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const analysis = @import("analysis.zig");

const A = std.heap.page_allocator;
const BIG: f32 = 1.0e30;
const EPS: f32 = 1.0e-4;
const TINY: f32 = 1.0e-20;

/// The minimum wall (mm; 0: 1 mm).
pub var th_min: f32 = 0;
/// The last thinnest wall (world units).
pub var th_world_min: f32 = 0;

fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
fn cvtt(x: f32) i32 {
    return if (x >= -2147483648.0 and x < 2147483648.0) @intFromFloat(x) else std.math.minInt(i32);
}

// ---- the triangle grid ------------------------------------------------------------------

const Grid = struct {
    me: *const scene.Mesh,
    wv: []m.V3,
    n: i32 = 1,
    min: m.V3 = .{ 0, 0, 0 },
    inv: f32 = 0,
    diag: f32 = 0,
    off: []u32 = &.{},
    tri: []u32 = &.{},
    stamp: []u32 = &.{},
    serial: u32 = 0,

    fn deinit(g: *Grid) void {
        if (g.off.len > 0) A.free(g.off);
        if (g.tri.len > 0) A.free(g.tri);
        if (g.stamp.len > 0) A.free(g.stamp);
    }

    fn clamp(g: *const Grid, v: i32) i32 {
        if (v < 0) return 0;
        return if (v > g.n - 1) g.n - 1 else v;
    }

    /// tri_cells: the triangle's cell range (padded a little).
    fn cells(g: *const Grid, t: usize) [2][3]i32 {
        var lo: m.V3 = .{ BIG, BIG, BIG };
        var hi: m.V3 = .{ -BIG, -BIG, -BIG };
        for (0..3) |k| {
            const p = g.wv[g.me.tris[t][k]];
            for (0..3) |c| {
                lo[c] = minss(lo[c], p[c]);
                hi[c] = maxss(hi[c], p[c]);
            }
        }
        var r: [2][3]i32 = undefined;
        for (0..3) |c| {
            r[0][c] = g.clamp(cvtt((lo[c] - g.min[c]) * g.inv - 0.01));
            r[1][c] = g.clamp(cvtt((hi[c] - g.min[c]) * g.inv + 0.01));
        }
        return r;
    }

    /// tg_build.
    fn build(g: *Grid) !void {
        const nt = g.me.tris.len;
        var c: i32 = 1;
        while (@as(u64, @intCast(c * c * c)) < nt and c < 96) c += 1;
        g.n = c;
        var lo: m.V3 = .{ BIG, BIG, BIG };
        var hi: m.V3 = .{ -BIG, -BIG, -BIG };
        for (g.wv) |p| {
            for (0..3) |k| {
                lo[k] = minss(lo[k], p[k]);
                hi[k] = maxss(hi[k], p[k]);
            }
        }
        g.min = lo;
        var d = maxss(maxss(hi[0] - lo[0], hi[1] - lo[1]), hi[2] - lo[2]);
        g.diag = d;
        d = maxss(d * 1.001, TINY);
        g.inv = @as(f32, @floatFromInt(c)) / d;
        const cells_n: usize = @intCast(c * c * c);
        g.off = try A.alloc(u32, cells_n + 1);
        @memset(g.off, 0);
        g.stamp = try A.alloc(u32, @max(nt, 1));
        @memset(g.stamp, 0);
        g.serial = 0;
        const un: usize = @intCast(c);
        for (0..2) |pass| {
            for (0..nt) |t| {
                const r = g.cells(t);
                var z = r[0][2];
                while (z <= r[1][2]) : (z += 1) {
                    var y = r[0][1];
                    while (y <= r[1][1]) : (y += 1) {
                        var x = r[0][0];
                        while (x <= r[1][0]) : (x += 1) {
                            const cell = (@as(usize, @intCast(z)) * un + @as(usize, @intCast(y))) * un + @as(usize, @intCast(x));
                            if (pass == 0) {
                                g.off[cell + 1] += 1;
                            } else {
                                g.tri[g.off[cell]] = @intCast(t);
                                g.off[cell] += 1;
                            }
                        }
                    }
                }
            }
            if (pass == 0) {
                var sum: u32 = 0;
                for (g.off[1..]) |*o| {
                    sum += o.*;
                    o.* = sum;
                }
                g.tri = try A.alloc(u32, @max(sum, 1));
            }
        }
        // (the fill moved each start to the next one's: back by one)
        var k = cells_n;
        while (k > 0) : (k -= 1) g.off[k] = g.off[k - 1];
        g.off[0] = 0;
    }

    /// ray_tri_f: Moller-Trumbore, both sides; t or -1.
    fn rayTri(g: *const Grid, t: usize, o: m.V3, dir: m.V3) f32 {
        const a = g.wv[g.me.tris[t][0]];
        const b = g.wv[g.me.tris[t][1]];
        const cc = g.wv[g.me.tris[t][2]];
        var e1: m.V3 = undefined;
        var e2: m.V3 = undefined;
        var s: m.V3 = undefined;
        for (0..3) |k| {
            e1[k] = b[k] - a[k];
            e2[k] = cc[k] - a[k];
            s[k] = o[k] - a[k];
        }
        const p = crossf(dir, e2);
        const det = dotf(e1, p);
        if (!(@abs(det) > TINY)) return -1;
        const u = dotf(s, p) / det;
        if (!(u >= 0) or u > 1) return -1;
        const q = crossf(s, e1);
        const v = dotf(dir, q) / det;
        if (!(v >= 0)) return -1;
        if (v + u > 1) return -1;
        return dotf(e2, q) / det;
    }

    /// tg_ray: the distance to the nearest triangle hit (1e30: none).
    fn ray(g: *Grid, o: m.V3, dir: m.V3, skip: u32) f32 {
        var best: f32 = BIG;
        g.serial +%= 1;
        const nf: f32 = @floatFromInt(g.n);
        var t0: f32 = 0;
        var t1: f32 = BIG;
        var og: m.V3 = undefined;
        var dg: m.V3 = undefined;
        for (0..3) |c| {
            og[c] = (o[c] - g.min[c]) * g.inv;
            dg[c] = dir[c] * g.inv;
            const ad = @abs(dg[c]);
            if (!(ad > TINY)) {
                // parallel: inside the slab or no hit
                if (og[c] < 0 or std.math.isNan(og[c])) return best;
                if (og[c] > nf) return best;
            } else {
                var a = (0 - og[c]) / dg[c];
                const b = (nf - og[c]) / dg[c];
                const lo = minss(a, b);
                a = maxss(a, b);
                t0 = maxss(t0, lo);
                t1 = minss(t1, a);
            }
        }
        if (t0 > t1) return best;
        var cell: [3]i32 = undefined;
        var step: [3]i32 = undefined;
        var tmax: [3]f32 = undefined;
        var tdel: [3]f32 = undefined;
        for (0..3) |c| {
            cell[c] = g.clamp(cvtt(dg[c] * t0 + og[c]));
            const ad = @abs(dg[c]);
            if (!(ad > TINY)) {
                step[c] = 0;
                tmax[c] = BIG;
                tdel[c] = BIG;
            } else {
                step[c] = if (dg[c] > 0) 1 else -1;
                var x: f32 = @floatFromInt(cell[c]);
                if (step[c] == 1) x += 1;
                tmax[c] = (x - og[c]) / dg[c];
                tdel[c] = 1 / ad;
            }
        }
        const un: usize = @intCast(g.n);
        while (true) {
            const ci = (@as(usize, @intCast(cell[2])) * un + @as(usize, @intCast(cell[1]))) * un + @as(usize, @intCast(cell[0]));
            var k = g.off[ci];
            while (k < g.off[ci + 1]) : (k += 1) {
                const t = g.tri[k];
                if (g.stamp[t] == g.serial) continue;
                g.stamp[t] = g.serial;
                if (g.me.tri_poly[t] == skip) continue;
                const h = g.rayTri(t, o, dir);
                if (h > 0) best = minss(h, best);
            }
            // the next cell (or done when the best hit comes before its boundary)
            var ax: usize = 0;
            var tm = tmax[0];
            for (1..3) |c| {
                if (!(tmax[c] >= tm)) {
                    tm = tmax[c];
                    ax = c;
                }
            }
            if (tm > best or tm > t1) break;
            if (step[ax] == 0) break;
            const nx = step[ax] + cell[ax];
            if (nx < 0 or nx >= g.n) break;
            cell[ax] = nx;
            tmax[ax] = tmax[ax] + tdel[ax];
        }
        return best;
    }
};

fn crossf(a: m.V3, b: m.V3) m.V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn dotf(a: m.V3, b: m.V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// poly_world: polygon p's centre and unit normal (world); |Newell| (2 x area)
/// in `len`; false when it has no area (the centre is set all the same).
fn polyWorld(me: *const scene.Mesh, wv: []const m.V3, p: usize, centre: *m.V3, nrm: *m.V3, len: *f32) bool {
    const l = me.loops[me.poff[p]..me.poff[p + 1]];
    var n: m.V3 = .{ 0, 0, 0 };
    var c: m.V3 = .{ 0, 0, 0 };
    for (l, 0..) |a, k| {
        const i = wv[a];
        const j = wv[l[if (k + 1 < l.len) k + 1 else 0]];
        c[0] += i[0];
        c[1] += i[1];
        c[2] += i[2];
        n[0] += (i[1] - j[1]) * (i[2] + j[2]);
        n[1] += (i[2] - j[2]) * (i[0] + j[0]);
        n[2] += (i[0] - j[0]) * (i[1] + j[1]);
    }
    const cnt: f32 = @floatFromInt(l.len);
    centre.* = .{ c[0] / cnt, c[1] / cnt, c[2] / cnt };
    const s = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    len.* = s;
    if (!(s > TINY)) return false;
    nrm.* = .{ n[0] / s, n[1] / s, n[2] / s };
    return true;
}

fn worldVerts(i: usize, me: *const scene.Mesh) ![]m.V3 {
    const w = @import("measure.zig").objMatrix(i);
    const wv = try A.alloc(m.V3, me.verts.len);
    for (me.verts, wv) |p, *q| q.* = m.xform(w, p);
    return wv;
}

// ---- the thickness, cached --------------------------------------------------------------

var c_th: []f32 = &.{};
var c_serial: u32 = 0;
var c_shape: u32 = 0;
var c_np: usize = 0;
var c_mtx: m.M4 = undefined;
var c_valid = false;

/// th_faces: object i's wall thickness per polygon (world units, 1e30 when the
/// ray leaves), cached; null when it has no mesh or no memory.
pub fn thFaces(i: usize) ?[]const f32 {
    const me = scene.meshOfObj(i) orelse return null;
    const w = @import("measure.zig").objMatrix(i);
    const np = me.poff.len - 1;
    if (c_valid and c_serial == me.serial and c_shape == me.shape and c_np == np and std.mem.eql(f32, &c_mtx, &w)) return c_th;
    c_valid = false;
    if (c_th.len > 0) A.free(c_th);
    c_th = &.{};
    const th = A.alloc(f32, np) catch return null;
    measure(i, me, th) catch {
        A.free(th);
        return null;
    };
    c_th = th;
    c_serial = me.serial;
    c_shape = me.shape;
    c_np = np;
    c_mtx = w;
    c_valid = true;
    return c_th;
}

fn measure(i: usize, me: *const scene.Mesh, th: []f32) !void {
    const wv = try worldVerts(i, me);
    defer A.free(wv);
    var g = Grid{ .me = me, .wv = wv };
    defer g.deinit();
    try g.build();
    for (0..th.len) |p| {
        var c: m.V3 = undefined;
        var n: m.V3 = undefined;
        var len: f32 = undefined;
        if (!polyWorld(me, wv, p, &c, &n, &len)) {
            th[p] = BIG;
            continue;
        }
        // origin: a hair inside, the direction in
        const hair = EPS * g.diag;
        var o: m.V3 = undefined;
        var d: m.V3 = undefined;
        for (0..3) |k| {
            o[k] = c[k] - n[k] * hair;
            d[k] = 0 - n[k];
        }
        var t = g.ray(o, d, @intCast(p));
        if (t < BIG) t += EPS * g.diag; // (plus the hair it started inside)
        th[p] = t;
    }
}

/// th_minw: the minimum wall in world units.
pub fn minWorld() f32 {
    const mm: f32 = if (th_min > 0) th_min else 1.0;
    const u: f32 = @floatCast(cad.unitMm());
    return mm / u;
}

// ---- view.show_thickness [mm] ---------------------------------------------------------------

/// parse_float: "-1.5e3" style, at most 32 characters; null when no digits.
pub fn parseFloat(text: []const u8) ?f32 {
    const s = text[0..@min(text.len, 32)];
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == 9)) i += 1;
    var v: f64 = 0;
    var neg = false;
    var digits: u32 = 0;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    } else if (i < s.len and s[i] == '+') i += 1;
    while (i < s.len and s[i] -% '0' <= 9) : (i += 1) {
        v = v * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
        digits += 1;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        var u: f64 = 1;
        while (i < s.len and s[i] -% '0' <= 9) : (i += 1) {
            u /= 10.0;
            v += @as(f64, @floatFromInt(s[i] - '0')) * u;
            digits += 1;
        }
    }
    if (i < s.len and s[i] | 0x20 == 'e') {
        i += 1;
        var eneg = false;
        if (i < s.len and s[i] == '-') {
            eneg = true;
            i += 1;
        } else if (i < s.len and s[i] == '+') i += 1;
        var e: u32 = 0;
        while (i < s.len and s[i] -% '0' <= 9) : (i += 1) e = e *% 10 +% (s[i] - '0');
        if (e > 38) e = 38;
        while (e > 0) : (e -= 1) v = if (eneg) v / 10.0 else v * 10.0;
    }
    if (neg) v = 0.0 - v;
    return if (digits > 0) @floatCast(v) else null;
}

pub fn opShowThin() void {
    const ops = @import("ops.zig");
    if (ops.arg.len > 0) {
        if (parseFloat(ops.arg)) |x| {
            th_min = x;
            analysis.flags |= analysis.THIN;
            analysis.prepare();
            app.dirty = true;
            return;
        }
    }
    analysis.toggle(analysis.THIN);
}

pub fn isThin() bool {
    return analysis.flags & analysis.THIN != 0;
}

// ---- mesh.print_check [minimum mm] ------------------------------------------------------------

/// What the last check found (the panel's: pc_store).
pub const Found = struct {
    valid: bool = false,
    oid: u32 = 0,
    serial: u32 = 0,
    shape: u32 = 0,
    loc: m.V3 = .{ 0, 0, 0 },
    rot: m.V3 = .{ 0, 0, 0 },
    scl: m.V3 = .{ 0, 0, 0 },
    nb: u32 = 0,
    nm: u32 = 0,
    nthin: u32 = 0,
    thin: f32 = -1, // mm (< 0: none)
    min: f32 = 0, // mm
    over: f32 = 0, // % of the area
    size: [3]f32 = .{ 0, 0, 0 }, // mm, Z up
};
pub var found = Found{};

pub fn opPrintCheck() void {
    const ops = @import("ops.zig");
    // (from the UI, the console or MCP: Properties shows the findings on its
    // Object tab, and the check runs as a job with its chip, as the original's
    // JOB_NOW; quiet only from a script, op_quiet)
    if (!ops.quiet) {
        for (&app.nodes) |*nd| {
            if (nd.used and nd.leaf and nd.editor == .properties) nd.tab = 0;
        }
        return @import("jobui.zig").later(checkJob, "Checking for printing", ops.arg, 0, 0);
    }
    check(ops.arg);
}

fn checkJob(arg: []const u8, _: usize, _: usize) void {
    check(arg);
}

fn check(arg: []const u8) void {
    if (arg.len > 0) {
        if (parseFloat(arg)) |x| th_min = x;
    }
    var n: usize = 0;
    for (0..scene.count) |i| {
        const o = &scene.objects[i];
        if (!o.kind.isMesh() or o.mesh == null or !o.selected) continue;
        report(i);
        n += 1;
    }
    if (n > 0) return;
    if (scene.active) |a| {
        if (scene.objects[a].kind.isMesh() and scene.objects[a].mesh != null) return report(a);
    }
    app.log("  print check: select a mesh", .{});
}

fn val3(w: *std.Io.Writer, v: f32) void {
    var b: [32]u8 = undefined;
    w.writeAll(cad.fmtVal3(&b, v)) catch {};
}

/// pc_report: two console lines, and the panel's findings.
fn report(i: usize) void {
    const o = &scene.objects[i];
    const me = scene.meshOfObj(i) orelse return;
    var f = Found{ .valid = true, .oid = o.oid, .serial = me.serial, .shape = me.shape, .loc = o.loc, .rot = o.rot, .scl = o.scl };
    const an = analysis.of(i);
    const nb: u32 = if (an) |r| r.counts.boundary else 0;
    const nm: u32 = if (an) |r| r.counts.nonmanifold else 0;
    f.nb = nb;
    f.nm = nm;
    var b1: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&b1);
    w.print("  {s}", .{o.name()}) catch {};
    if (nb == 0 and nm == 0) {
        w.writeAll(": closed") catch {};
    } else w.print(": NOT closed ({d} boundary, {d} non-manifold edges)", .{ nb, nm }) catch {};
    const u: f32 = @floatCast(cad.unitMm());
    if (thFaces(i)) |th| {
        const minw = minWorld();
        var thinnest: f32 = BIG;
        var under: u32 = 0;
        for (th) |t| {
            thinnest = minss(thinnest, t);
            if (!(t >= minw)) under += 1;
        }
        th_world_min = thinnest;
        f.nthin = under;
        f.min = u * minw;
        w.writeAll(", thinnest wall ") catch {};
        if (thinnest >= BIG) {
            w.writeAll(" -") catch {};
            f.thin = -1;
        } else {
            f.thin = u * thinnest;
            val3(&w, f.thin);
            w.print(" mm ({d} faces under ", .{under}) catch {};
            val3(&w, u * minw);
            w.writeAll(" mm)") catch {};
        }
    }
    app.log("{s}", .{w.buffered()});
    // (a second line: the original's is short)
    var b2: [256]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&b2);
    w2.writeAll("  overhangs ") catch {};
    const wv = worldVerts(i, me) catch return;
    defer A.free(wv);
    f.over = overShare(me, wv, if (an) |r| r.fcls else &.{}) * 100.0;
    val3(&w2, f.over);
    w2.writeAll("% of the area, size ") catch {};
    const box = wbox(wv);
    for ([_]usize{ 0, 2, 1 }, 0..) |c, k| {
        if (k > 0) w2.writeAll(" x ") catch {};
        f.size[k] = u * (box[1][c] - box[0][c]);
        val3(&w2, f.size[k]);
    }
    w2.writeAll(" mm") catch {};
    app.log("{s}", .{w2.buffered()});
    found = f;
}

/// wbox: the world box (min, max).
fn wbox(wv: []const m.V3) [2]m.V3 {
    var lo: m.V3 = .{ BIG, BIG, BIG };
    var hi: m.V3 = .{ -BIG, -BIG, -BIG };
    for (wv) |p| {
        for (0..3) |k| {
            lo[k] = minss(lo[k], p[k]);
            hi[k] = maxss(hi[k], p[k]);
        }
    }
    return .{ lo, hi };
}

/// over_share: the overhanging faces' share of the area (faces on the bed, at
/// the lowest height, do not count).
fn overShare(me: *const scene.Mesh, wv: []const m.V3, fcls: []const u8) f32 {
    var all: f32 = 0;
    var over: f32 = 0;
    const box = wbox(wv);
    const bed = (box[1][1] - box[0][1]) * EPS + box[0][1];
    for (0..me.poff.len - 1) |p| {
        var c: m.V3 = undefined;
        var n: m.V3 = undefined;
        var len: f32 = undefined;
        _ = polyWorld(me, wv, p, &c, &n, &len);
        const area = len * 0.5;
        all += area;
        if (p < fcls.len and fcls[p] & 2 != 0 and c[1] > bed) over += area;
    }
    return over / maxss(all, TINY);
}

// ---- the panel (printui.s) ---------------------------------------------------------------

/// mesh.print_show edges|thin|overhangs: the checked mesh in edit mode, those
/// selected, framed.
pub fn opShow() void {
    const ops = @import("ops.zig");
    const em = @import("editmesh.zig");
    var it = std.mem.tokenizeAny(u8, ops.arg, " \t\"");
    const word = it.next() orelse "";
    const kind: u2 = if (std.mem.eql(u8, word, "edges")) 0 else if (std.mem.eql(u8, word, "thin")) 1 else 2;
    if (!found.valid) return;
    const i = scene.findOid(found.oid) orelse return;
    if (em.active and em.obj != i) ops.runId("mode.object");
    if (!em.active) {
        for (scene.objects[0..scene.count]) |*o| o.selected = false;
        scene.objects[i].selected = true;
        scene.active = i;
        ops.runId("mode.edit");
        if (!em.active) return;
    }
    const me = scene.meshOfObj(i) orelse return;
    if (em.sel.len != me.verts.len) return;
    @memset(em.sel, false);
    const an = analysis.of(i);
    switch (kind) {
        0 => if (an) |r| {
            for (r.bound.items) |e| {
                em.sel[e[0]] = true;
                em.sel[e[1]] = true;
            }
            for (r.nonman.items) |e| {
                em.sel[e[0]] = true;
                em.sel[e[1]] = true;
            }
        },
        1 => if (thFaces(i)) |th| {
            const minw = minWorld();
            for (th, 0..) |t, p| {
                if (!(t >= minw)) selectFace(me, p);
            }
        },
        else => if (an) |r| {
            for (r.fcls, 0..) |c, p| {
                if (c & 2 != 0) selectFace(me, p);
            }
        },
    }
    em.version +%= 1;
    app.dirty = true;
    ops.runId("view.frame_selected");
}

fn selectFace(me: *const scene.Mesh, p: usize) void {
    const em = @import("editmesh.zig");
    for (me.loops[me.poff[p]..me.poff[p + 1]]) |v| em.sel[v] = true;
}

fn hint(bd: gfx.Rect, y: *i32, s: []const u8) void {
    _ = ui.cv.textFit(bd.x, y.* + 2, bd.w, s, ui.th.text_dim);
    ui.record("info", s, .{ .x = bd.x, .y = y.*, .w = bd.w, .h = 18 }, true);
    y.* += 22;
}

/// pk_row: a title, a Show button on the right (`what`: mesh.print_show's word).
fn row(salt: usize, bd: gfx.Rect, y: *i32, title: []const u8, what: ?[]const u8, name: []const u8, tip: []const u8) void {
    const sf = gfx.useFace(.small);
    const tw = if (what != null) bd.w - 60 else bd.w;
    _ = ui.cv.textFit(bd.x, y.* + 3, tw, title, ui.th.text);
    _ = gfx.useFace(sf);
    ui.record("info", title, .{ .x = bd.x, .y = y.*, .w = tw, .h = 18 }, true);
    if (what) |wd| {
        const r = gfx.Rect{ .x = bd.right() - 56, .y = y.*, .w = 56, .h = 20 };
        if (ui.button(ui.id(@src(), salt * 8 + wd.len), r, "Show", .{ .tip = tip })) {
            ui.active = 0;
            @import("animops.zig").runText("mesh.print_show", wd);
        }
        _ = name;
    }
    y.* += 20;
}

/// print_props: object i's findings, when it was the one checked; y below them.
pub fn props(salt: usize, i: usize, bd: gfx.Rect, y0: i32) i32 {
    var y = y0;
    if (!found.valid or scene.objects[i].oid != found.oid) return y;
    const o = &scene.objects[i];
    const editors = @import("editors.zig");
    if (!editors.section(ui.id(@src(), salt), bd.x, &y, bd.w, "Print Check", 29)) return y;
    const me = scene.meshOfObj(i);
    const same = me != null and me.?.serial == found.serial and me.?.shape == found.shape and
        std.mem.eql(f32, &o.loc, &found.loc) and std.mem.eql(f32, &o.rot, &found.rot) and std.mem.eql(f32, &o.scl, &found.scl);
    var b: [160]u8 = undefined;
    if (!same) {
        hint(bd, &y, "The mesh changed since: check it again.");
    } else {
        if (found.nb == 0 and found.nm == 0) {
            row(salt, bd, &y, "Closed", null, "", "");
        } else {
            row(salt, bd, &y, "Not closed", "edges", "print.show_edges", "Select the open and non-manifold edges in edit mode, and frame them");
            hint(bd, &y, std.fmt.bufPrint(&b, "{d} open, {d} non-manifold edges", .{ found.nb, found.nm }) catch "");
        }
        var vb: [32]u8 = undefined;
        if (found.thin < 0) {
            row(salt, bd, &y, "Walls: none measured", null, "", "");
        } else {
            var tb: [64]u8 = undefined;
            const t = std.fmt.bufPrint(&tb, "Thinnest wall {s} mm", .{cad.fmtVal3(&vb, found.thin)}) catch "";
            row(salt, bd, &y, t, if (found.nthin > 0) "thin" else null, "print.show_thin", "Select the faces thinner than the minimum in edit mode, and frame them");
            hint(bd, &y, std.fmt.bufPrint(&b, "{d} faces under {s} mm", .{ found.nthin, cad.fmtVal3(&vb, found.min) }) catch "");
        }
        var ob: [64]u8 = undefined;
        const ot = std.fmt.bufPrint(&ob, "Overhangs {s}%", .{cad.fmtVal3(&vb, found.over)}) catch "";
        row(salt, bd, &y, ot, if (0 < found.over) "overhangs" else null, "print.show_overhangs", "Select the overhanging faces in edit mode, and frame them");
        row(salt, bd, &y, "Size", null, "", "");
        var w = std.Io.Writer.fixed(&b);
        for (found.size, 0..) |s, k| {
            if (k > 0) w.writeAll(" x ") catch {};
            w.writeAll(cad.fmtVal3(&vb, s)) catch {};
        }
        w.writeAll(" mm") catch {};
        hint(bd, &y, w.buffered());
    }
    y += 4;
    editors.opButtonL(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, "mesh.print_check", "Check Again");
    return y + 30;
}

test "parse_float as the original" {
    try std.testing.expectEqual(@as(f32, 2), parseFloat("2mm").?);
    try std.testing.expectEqual(@as(f32, -1500), parseFloat(" -1.5e3").?);
    try std.testing.expect(parseFloat("mm") == null);
}
