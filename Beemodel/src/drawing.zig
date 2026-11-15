// 2D drawings to PDF (drawing.s): file.export_pdf lays out orthographic views
// of the selected meshes (all meshes when none is selected) in third-angle
// projection - front, top above it, right side to its right, and an optional
// isometric - at a standard scale on a sheet, with overall dimensions and a
// title block. Each view draws the boundary, sharp (> 30 deg) and silhouette
// edges; a depth buffer of the view (the triangles rasterized) splits them
// into visible lines and dashed hidden ones. The PDF is written by hand: five
// objects, Helvetica, an uncompressed content stream, an exact xref table.
// All in f32 step for step as the original, so the bytes are the same.
const std = @import("std");
const app = @import("app.zig");
const scene = @import("scene.zig");
const m = @import("math.zig");
const cad = @import("cad.zig");

const A = std.heap.page_allocator;

const MAXO = 64;
const BIG: f32 = 3.0e38;
const ZR: f32 = 1024.0;
const COS: f32 = 0.8660254;
const PT: f32 = 2.8346457; // points per mm
const TOL: f32 = 2.5;
const TINY: f32 = 1.0e-12;
const SLIVER: f32 = 1.0e-6;
const GAP: f32 = 50.0;
const DIM: f32 = 14.0;
const EXT: f32 = 4.0;
const ARROW: f32 = 3.0;
const TEXTW: f32 = 2.4;
const ISO3: f32 = 0.57735027;
const ISO2: f32 = 0.70710678;
const ISO6: f32 = 0.40824829;

const scales = [_]f32{ 20, 10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 0 };
const fixed_scales = [_]f32{ 0, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01 };
const sheet_wh = [_][2]f32{ .{ 842, 595 }, .{ 1191, 842 }, .{ 1684, 1191 }, .{ 792, 612 } };

// ---- the options (drawing.options; kept for the next drawing) ---------------------------

pub var o_sheet: u32 = 0; // A4 A3 A2 Letter
pub var o_port: u32 = 0; // portrait
pub var o_views: u32 = 7; // 1 front, 2 top, 4 right, 8 iso
pub var o_scale: u32 = 0; // 0: the largest that fits, else fixed_scales
pub var o_title: [64]u8 = @splat(0);
pub var o_author: [64]u8 = @splat(0);

fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
fn cvtt(x: f32) i32 {
    return if (x >= -2147483648.0 and x < 2147483648.0) @intFromFloat(x) else std.math.minInt(i32);
}

// ---- writing ---------------------------------------------------------------------------

const W = struct {
    b: std.ArrayList(u8) = .empty,
    fail: bool = false,

    fn s(w: *W, t: []const u8) void {
        w.b.appendSlice(A, t) catch {
            w.fail = true;
        };
    }
    fn int(w: *W, v: i64) void {
        var buf: [24]u8 = undefined;
        w.s(std.fmt.bufPrint(&buf, "{d}", .{v}) catch "");
    }
    /// wb_float: six decimals, rounded to millionths (to even, as cvtsd2si).
    fn float(w: *W, v: f32) void {
        var x: f64 = v;
        if (!(x >= 0)) {
            w.s("-");
            x = 0.0 - x;
        }
        const y = x * 1000000.0;
        var q: u64 = 0x8000000000000000;
        if (y < 9.2e18) {
            var r = @floor(y);
            const diff = y - r;
            if (diff > 0.5 or (diff == 0.5 and @mod(r, 2) == 1)) r += 1;
            q = @intFromFloat(r);
        }
        var buf: [32]u8 = undefined;
        w.s(std.fmt.bufPrint(&buf, "{d}.{d:0>6}", .{ q / 1000000, q % 1000000 }) catch "");
    }
    /// wf: a number and a space.
    fn wf(w: *W, v: f32) void {
        w.float(v);
        w.s(" ");
    }
    fn line(w: *W, x0: f32, y0: f32, x1: f32, y1: f32) void {
        w.wf(x0);
        w.wf(y0);
        w.s("m ");
        w.wf(x1);
        w.float(y1);
        w.s(" l S\n");
    }
    /// ptext. (A string whose parentheses do not pair, or with a backslash, is
    /// escaped: the original writes it as it is, and such a name broke its file.)
    fn text(w: *W, x: f32, y: f32, size: i64, t: []const u8) void {
        w.s("BT /F1 ");
        w.int(size);
        w.s(" Tf ");
        w.wf(x);
        w.float(y);
        w.s(" Td (");
        var depth: i32 = 0;
        var paired = true;
        for (t) |c| {
            if (c == '(') depth += 1;
            if (c == ')') depth -= 1;
            if (depth < 0 or c == '\\') paired = false;
        }
        if (depth != 0) paired = false;
        for (t) |c| {
            if (!paired and (c == '(' or c == ')' or c == '\\')) w.s("\\");
            w.s(&.{c});
        }
        w.s(") Tj ET\n");
    }
};

// ---- the scene, the views ------------------------------------------------------------------

const Obj = struct { i: usize, me: *const scene.Mesh, wv: []m.V3 };

var objs: [MAXO]Obj = undefined;
var n_obj: usize = 0;
var mm: f32 = 1000;
var bmin: m.V3 = undefined;
var bmax: m.V3 = undefined;
var view: u32 = 0; // 0 front, 1 top, 2 right, 3 isometric
var vmin: [2]f32 = undefined;
var vmax: [2]f32 = undefined;
var ps: f32 = 1;
var zw: i32 = 0;
var zh: i32 = 0;
var zb: []f32 = &.{};
var k_pt: f32 = 1; // points per model mm
var scale: f32 = 1;
var ox: f32 = 0;
var oy: f32 = 0;
var dir: m.V3 = .{ 0, 0, 0 };

fn freeObjs() void {
    for (objs[0..n_obj]) |o| A.free(o.wv);
    n_obj = 0;
}

/// collect: the selected meshes, or all of them.
fn collect() !void {
    freeObjs();
    for (0..2) |pass| {
        for (0..scene.count) |i| {
            if (n_obj >= MAXO) break;
            const o = &scene.objects[i];
            if (!o.kind.isMesh() or o.mesh == null) continue;
            if (pass == 0 and !o.selected) continue;
            const me = @import("mods.zig").of(i) orelse continue;
            if (me.tris.len == 0) continue;
            const w = @import("measure.zig").objMatrix(i);
            const wv = try A.alloc(m.V3, me.verts.len);
            for (me.verts, wv) |p, *q| q.* = m.xform(w, p);
            objs[n_obj] = .{ .i = i, .me = me, .wv = wv };
            n_obj += 1;
        }
        if (n_obj > 0) break;
    }
}

const P3 = struct { x: f32, y: f32, d: f32 };

/// proj: front (x, y, z), top (x, -z, y), right (-z, y, x), mm.
fn proj(p: m.V3) P3 {
    const x = p[0] * mm;
    const y = p[1] * mm;
    const z = p[2] * mm;
    const nz = 0 - z;
    return switch (view) {
        3 => .{ .x = (x - z) * ISO2, .y = (y + y - x - z) * ISO6, .d = (x + y + z) * ISO3 },
        1 => .{ .x = x, .y = nz, .d = y },
        2 => .{ .x = nz, .y = y, .d = x },
        else => .{ .x = x, .y = y, .d = z },
    };
}

fn topx(x: f32, y: f32) [2]f32 {
    return .{ (x - vmin[0]) / ps, (y - vmin[1]) / ps };
}

fn topage(x: f32, y: f32) [2]f32 {
    return .{ (x - vmin[0]) * k_pt + ox, (y - vmin[1]) * k_pt + oy };
}

/// view_bounds: the world box's corners projected.
fn viewBounds() void {
    vmin = .{ BIG, BIG };
    vmax = .{ -BIG, -BIG };
    for (0..8) |bits| {
        var p: m.V3 = undefined;
        for (0..3) |c| p[c] = (if (bits >> @intCast(c) & 1 != 0) bmax[c] else bmin[c]) / mm;
        const q = proj(p);
        vmin[0] = minss(vmin[0], q.x);
        vmin[1] = minss(vmin[1], q.y);
        vmax[0] = maxss(vmax[0], q.x);
        vmax[1] = maxss(vmax[1], q.y);
    }
}

/// zbuf_make: filled with -max float.
fn zbufMake() !void {
    const w = vmax[0] - vmin[0];
    const h = vmax[1] - vmin[1];
    ps = maxss(maxss(w, h), TINY) / ZR;
    zw = cvtt(w / ps) + 3;
    zh = cvtt(h / ps) + 3;
    if (zw <= 0 or zh <= 0 or @as(i64, zw) * zh > 1 << 26) return error.OutOfMemory;
    zb = try A.alloc(f32, @intCast(zw * zh));
    @memset(zb, -std.math.floatMax(f32));
}

fn edgef(p: [2]f32, q: [2]f32, x: f32, y: f32) f32 {
    return (q[0] - p[0]) * (y - p[1]) - (q[1] - p[1]) * (x - p[0]);
}

/// zbuf_fill: every triangle's nearest depth per pixel.
fn zbufFill() void {
    for (objs[0..n_obj]) |o| {
        for (o.me.tris) |t| {
            var c: [3][2]f32 = undefined;
            var d: [3]f32 = undefined;
            for (0..3) |k| {
                const q = proj(o.wv[t[k]]);
                d[k] = q.d;
                c[k] = topx(q.x, q.y);
            }
            const area = (c[1][0] - c[0][0]) * (c[2][1] - c[0][1]) - (c[1][1] - c[0][1]) * (c[2][0] - c[0][0]);
            if (!(@abs(area) > TINY)) continue;
            var x0 = cvtt(minss(minss(c[0][0], c[1][0]), c[2][0]));
            var y0 = cvtt(minss(minss(c[0][1], c[1][1]), c[2][1]));
            var x1 = cvtt(maxss(maxss(c[0][0], c[1][0]), c[2][0])) +% 1;
            var y1 = cvtt(maxss(maxss(c[0][1], c[1][1]), c[2][1])) +% 1;
            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 > zw - 1) x1 = zw - 1;
            if (y1 > zh - 1) y1 = zh - 1;
            var y = y0;
            while (y <= y1) : (y += 1) {
                var x = x0;
                while (x <= x1) : (x += 1) {
                    const px = @as(f32, @floatFromInt(x)) + 0.5;
                    const py = @as(f32, @floatFromInt(y)) + 0.5;
                    const w0 = edgef(c[1], c[2], px, py) / area;
                    const w1 = edgef(c[2], c[0], px, py) / area;
                    const w2 = edgef(c[0], c[1], px, py) / area;
                    if (!(w2 >= 0) or !(w0 >= 0) or !(w1 >= 0)) continue;
                    const depth = w2 * d[2] + w0 * d[0] + w1 * d[1];
                    const at: usize = @intCast(y * zw + x);
                    zb[at] = maxss(depth, zb[at]);
                }
            }
        }
    }
}

/// znear: the nearest depth in the 3x3 pixels there.
fn znear(px: f32, py: f32) f32 {
    const ix = cvtt(px);
    const iy = cvtt(py);
    var best: f32 = -BIG;
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const yy = iy +% dy;
            const xx = ix +% dx;
            if (yy < 0 or yy >= zh or xx < 0 or xx >= zw) continue;
            best = maxss(best, zb[@intCast(yy * zw + xx)]);
        }
    }
    return best;
}

/// wnormal: Newell's normal of the polygon's world corners, unit length (0: a sliver).
fn wnormal(me: *const scene.Mesh, wv: []const m.V3, p: usize) m.V3 {
    const l = me.loops[me.poff[p]..me.poff[p + 1]];
    var n: m.V3 = .{ 0, 0, 0 };
    var per: f32 = 0;
    for (l, 0..) |a, k| {
        const i = wv[a];
        const j = wv[l[if (k + 1 < l.len) k + 1 else 0]];
        n[0] += (i[1] - j[1]) * (i[2] + j[2]);
        n[1] += (i[2] - j[2]) * (i[0] + j[0]);
        n[2] += (i[0] - j[0]) * (i[1] + j[1]);
        const dx = i[0] - j[0];
        const dy = i[1] - j[1];
        const dz = i[2] - j[2];
        per += @sqrt(dx * dx + dy * dy + dz * dz);
    }
    const sl = per * per * SLIVER;
    var len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    if (!(len > sl)) {
        n = .{ 0, 0, 0 };
        len = 1;
    }
    len = maxss(len, TINY);
    return .{ n[0] / len, n[1] / len, n[2] / len };
}

const EdgeRec = struct { a: u32, b: u32, cnt: u32 = 0, f1: i32 = -1, f2: i32 = -1 };

/// The mesh's edges in the original's order (first seen, lo-hi), with the faces
/// on them (mesh_finish, edge_faces).
fn edgesOf(me: *const scene.Mesh) !std.ArrayList(EdgeRec) {
    var list: std.ArrayList(EdgeRec) = .empty;
    errdefer list.deinit(A);
    var map: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer map.deinit(A);
    for (0..me.poff.len - 1) |p| {
        const l = me.loops[me.poff[p]..me.poff[p + 1]];
        for (l, 0..) |a0, k| {
            const b0 = l[if (k + 1 < l.len) k + 1 else 0];
            const a = @min(a0, b0);
            const b = @max(a0, b0);
            const g = try map.getOrPut(A, @as(u64, a) << 32 | b);
            if (!g.found_existing) {
                g.value_ptr.* = @intCast(list.items.len);
                try list.append(A, .{ .a = a, .b = b });
            }
            const e = &list.items[g.value_ptr.*];
            e.cnt += 1;
            if (e.f1 < 0) {
                e.f1 = @intCast(p);
            } else if (e.f2 < 0) e.f2 = @intCast(p);
        }
    }
    return list;
}

fn dot(a: m.V3, b: m.V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// view_edges: boundary, sharp and silhouette edges, visible runs solid, hidden dashed.
fn viewEdges(w: *W) !void {
    dir = .{ 0, 0, 0 };
    switch (view) {
        3 => dir = .{ ISO3, ISO3, ISO3 },
        1 => dir[1] = 1,
        2 => dir[0] = 1,
        else => dir[2] = 1,
    }
    for (objs[0..n_obj]) |o| {
        var el = try edgesOf(o.me);
        defer el.deinit(A);
        const np = o.me.poff.len - 1;
        const nrm = try A.alloc(m.V3, np);
        defer A.free(nrm);
        for (0..np) |p| nrm[p] = wnormal(o.me, o.wv, p);
        for (el.items) |e| {
            if (e.cnt == 2) {
                const n1 = nrm[@intCast(e.f1)];
                const n2 = nrm[@intCast(e.f2)];
                if (!(dot(n1, n1) >= 0.5)) continue; // a sliver beside it: not an edge to draw
                if (!(dot(n2, n2) >= 0.5)) continue;
                if (dot(n1, n2) >= COS) { // not sharp: a silhouette (facing changes)?
                    if (dot(n1, dir) * dot(n2, dir) >= 0) continue;
                }
            }
            const a = proj(o.wv[e.a]);
            const b = proj(o.wv[e.b]);
            edgeRuns(w, a, b);
        }
    }
    w.s("[] 0 d 0 G 0.6 w\n");
}

fn ler(a: P3, b: P3, t: f32) P3 {
    return .{ .x = (b.x - a.x) * t + a.x, .y = (b.y - a.y) * t + a.y, .d = (b.d - a.d) * t + a.d };
}

/// edge_runs: samples along it against the depth buffer; each run of the same
/// visibility becomes one line.
fn edgeRuns(w: *W, a: P3, b: P3) void {
    const ax = (a.x - vmin[0]) / ps;
    const bx = (b.x - vmin[0]) / ps - ax;
    const ay = (a.y - vmin[1]) / ps;
    const by = (b.y - vmin[1]) / ps - ay;
    const n = cvtt(@sqrt(by * by + bx * bx)) +% 2;
    if (n < 2 or n > 1 << 24) return;
    var start: i32 = -1;
    var vis: i32 = -1;
    const nf: f32 = @floatFromInt(n);
    var s: i32 = 0;
    while (s <= n) : (s += 1) {
        const t = @as(f32, @floatFromInt(s)) / nf;
        const q = ler(a, b, t);
        const px = topx(q.x, q.y);
        const zn = znear(px[0], px[1]);
        const v: i32 = @intFromBool(q.d + TOL * ps >= zn);
        if (s != n) {
            if (start < 0) {
                start = s;
                vis = v;
                continue;
            }
            if (v == vis) continue;
        }
        runLine(w, a, b, start, s, vis, nf);
        start = s;
        vis = v;
    }
}

fn runLine(w: *W, a: P3, b: P3, from: i32, to: i32, vis: i32, nf: f32) void {
    w.s(if (vis != 0) "[] 0 d 0 G 0.6 w\n" else "[2 1.5] 0 d 0.55 G 0.35 w\n");
    const p = ler(a, b, @as(f32, @floatFromInt(from)) / nf);
    const q = ler(a, b, @as(f32, @floatFromInt(to)) / nf);
    const p0 = topage(p.x, p.y);
    const p1 = topage(q.x, q.y);
    w.line(p0[0], p0[1], p1[0], p1[1]);
}

/// arrow: a filled triangle, 0 points left, 1 right, 2 down, 3 up.
fn arrow(w: *W, tx: f32, ty: f32, d: u32) void {
    const h = ARROW * 0.5;
    var bx: f32 = 0;
    var by: f32 = 0;
    var sx: f32 = 0;
    var sy: f32 = 0;
    if (d <= 1) {
        sy = h;
        bx = if (d == 0) ARROW else 0 - ARROW;
    } else {
        sx = h;
        by = if (d == 2) ARROW else 0 - ARROW;
    }
    w.wf(tx);
    w.wf(ty);
    w.s("m ");
    w.wf(tx + bx + sx);
    w.wf(ty + by + sy);
    w.s("l ");
    w.wf(tx + bx - sx);
    w.float(ty + by - sy);
    w.s(" l f\n");
}

fn val3(buf: []u8, v: f32) []const u8 {
    return cad.fmtVal3(buf, v);
}

/// view_dims: the overall width below and height to the right, and its name.
fn viewDims(w: *W) void {
    w.s("[] 0 d 0 G 0.3 w\n");
    const p0 = topage(vmin[0], vmin[1]);
    const p1 = topage(vmax[0], vmax[1]);
    const x0 = p0[0];
    const y0 = p0[1];
    const x1 = p1[0];
    const y1 = p1[1];
    var vb: [32]u8 = undefined;
    if (view != 3) {
        const yd = y0 - DIM;
        w.line(x0, y0 - EXT, x0, yd - EXT);
        w.line(x1, y0 - EXT, x1, yd - EXT);
        w.line(x0, yd, x1, yd);
        arrow(w, x0, yd, 0);
        arrow(w, x1, yd, 1);
        const t = val3(&vb, vmax[0] - vmin[0]);
        const cx = (x0 + x1) * 0.5 - @as(f32, @floatFromInt(t.len)) * TEXTW;
        w.text(cx, yd - DIM + EXT, 8, t);
        const xd = x1 + DIM;
        w.line(x1 + EXT, y0, xd + EXT, y0);
        w.line(x1 + EXT, y1, xd + EXT, y1);
        w.line(xd, y0, xd, y1);
        arrow(w, xd, y0, 2);
        arrow(w, xd, y1, 3);
        const t2 = val3(&vb, vmax[1] - vmin[1]);
        w.text(xd + EXT, (y0 + y1) * 0.5, 8, t2);
    }
    const names = [_][]const u8{ "FRONT", "TOP", "RIGHT", "ISOMETRIC" };
    w.text(x0, y1 + EXT + EXT, 7, names[view]);
}

/// today: "YYYY-MM-DD" (UTC).
fn today(buf: []u8) []const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    const days: u64 = @as(u64, @intCast(@max(ts.sec, 0))) / 86400;
    const z = days + 719468;
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    var y = era * 400 + yoe;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const mo = if (mp < 10) mp + 3 else mp - 9;
    if (mo <= 2) y += 1;
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y % 10000, mo, d }) catch "";
}

fn titleBlock(w: *W, pw: f32, ph: f32) void {
    w.s("[] 0 d 0 G 0.3 w\n");
    const bx = pw - 262.0;
    w.wf(bx);
    w.wf(28);
    w.wf(232);
    w.wf(94);
    w.s("re S\n");
    for ([_]f32{ 98, 80, 62, 47 }) |y| w.line(bx, y, bx + 232.0, y);
    w.wf(20);
    w.wf(20);
    w.wf(pw - 40.0);
    w.wf(ph - 40.0);
    w.s("re S\n");
    const tx = bx + 6.0;
    const title = std.mem.sliceTo(&o_title, 0);
    w.text(tx, 104, 12, if (title.len > 0) title else "BeeModel");
    var b: [256]u8 = undefined;
    var bw = std.Io.Writer.fixed(&b);
    bw.writeAll("Part: ") catch {};
    for (objs[0..@min(n_obj, 4)], 0..) |o, k| {
        if (k > 0) bw.writeAll(", ") catch {};
        bw.writeAll(scene.objects[o.i].name()) catch {};
    }
    w.text(tx, 85, 9, bw.buffered());
    var vb: [32]u8 = undefined;
    bw = std.Io.Writer.fixed(&b);
    bw.writeAll("Scale ") catch {};
    if (scale >= 1) {
        bw.print("{s}:1", .{val3(&vb, scale)}) catch {};
    } else bw.print("1:{s}", .{val3(&vb, 1.0 / scale)}) catch {};
    w.text(tx, 67, 9, bw.buffered());
    bw = std.Io.Writer.fixed(&b);
    const author = std.mem.sliceTo(&o_author, 0);
    if (author.len > 0) bw.print("By {s}   ", .{author}) catch {};
    var db: [16]u8 = undefined;
    bw.writeAll(today(&db)) catch {};
    w.text(tx, 51, 8, bw.buffered());
    w.text(tx, 34, 8, "Units: mm    Third-angle projection");
}

pub const Err = error{ NothingToDraw, OutOfMemory };

/// export_pdf: the file's bytes.
pub fn build() Err![]u8 {
    mm = @floatCast(cad.unitMm());
    collect() catch return Err.OutOfMemory;
    defer freeObjs();
    if (n_obj == 0) return Err.NothingToDraw;
    bmin = .{ BIG, BIG, BIG };
    bmax = .{ -BIG, -BIG, -BIG };
    for (objs[0..n_obj]) |o| {
        for (o.wv) |p| {
            for (0..3) |c| {
                const v = p[c] * mm;
                bmin[c] = minss(bmin[c], v);
                bmax[c] = maxss(bmax[c], v);
            }
        }
    }
    const sh = if (o_sheet <= 3) o_sheet else 0;
    var pw = sheet_wh[sh][0];
    var ph = sheet_wh[sh][1];
    if (o_port != 0) std.mem.swap(f32, &pw, &ph);
    const dx = bmax[0] - bmin[0];
    const dy = bmax[1] - bmin[1];
    const dz = bmax[2] - bmin[2];
    var vw = [4]f32{ dx, dx, dz, 0 };
    var vh = [4]f32{ dy, dz, dy, 0 };
    view = 3;
    k_pt = 1;
    viewBounds();
    vw[3] = vmax[0] - vmin[0];
    vh[3] = vmax[1] - vmin[1];
    // the grid: columns A (front, top), B (right, iso); rows 1 (front, right), 2 (top, iso)
    var col = [2]f32{ 0, 0 };
    var row = [2]f32{ 0, 0 };
    var gap = [2]f32{ 0, 0 };
    for (0..4) |v| {
        if (o_views >> @intCast(v) & 1 == 0) continue;
        col[v >> 1] = maxss(col[v >> 1], vw[v]);
        row[v & 1] = maxss(row[v & 1], vh[v]);
    }
    if (col[0] > 0 and col[1] > 0) gap[0] = GAP;
    if (row[0] > 0 and row[1] > 0) gap[1] = GAP;
    // the scale: fixed, or the largest standard one that fits
    if (o_scale != 0 and o_scale <= 8) {
        scale = fixed_scales[o_scale];
    } else {
        var k: usize = 0;
        while (true) : (k += 1) {
            if (scales[k] == 0) {
                k -= 1;
                break;
            }
            const kk = scales[k] * PT;
            if ((col[0] + col[1]) * kk + gap[0] > pw - 102.0) continue;
            if ((row[0] + row[1]) * kk + gap[1] <= ph - 175.0) break;
        }
        scale = scales[k];
    }
    k_pt = scale * PT;
    var w = W{};
    defer w.b.deinit(A);
    for (0..4) |v| {
        if (o_views >> @intCast(v) & 1 == 0) continue;
        view = @intCast(v);
        ox = 50;
        oy = 130;
        if (v & 2 != 0) ox += col[0] * k_pt + gap[0];
        if (v & 1 != 0) oy += row[0] * k_pt + gap[1];
        viewBounds();
        zbufMake() catch return Err.OutOfMemory;
        defer {
            A.free(zb);
            zb = &.{};
        }
        zbufFill();
        viewEdges(&w) catch return Err.OutOfMemory;
        viewDims(&w);
    }
    titleBlock(&w, pw, ph);
    if (w.fail) return Err.OutOfMemory;
    // the PDF around it
    var f = W{};
    errdefer f.b.deinit(A);
    var offs: [6]usize = undefined;
    f.s("%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");
    offs[1] = f.b.items.len;
    f.s("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
    offs[2] = f.b.items.len;
    f.s("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
    offs[3] = f.b.items.len;
    f.s("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ");
    f.int(cvtt(pw));
    f.s(" ");
    f.int(cvtt(ph));
    f.s("] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");
    offs[4] = f.b.items.len;
    f.s("4 0 obj\n<< /Length ");
    f.int(@intCast(w.b.items.len));
    f.s(" >>\nstream\n");
    f.s(w.b.items);
    f.s("\nendstream\nendobj\n");
    offs[5] = f.b.items.len;
    f.s("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");
    const xref = f.b.items.len;
    f.s("xref\n0 6\n0000000000 65535 f \n");
    for (offs[1..6]) |o| {
        var b: [16]u8 = undefined;
        f.s(std.fmt.bufPrint(&b, "{d:0>10}", .{o % 10000000000}) catch "");
        f.s(" 00000 n \n");
    }
    f.s("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n");
    f.int(@intCast(xref));
    f.s("\n%%EOF\n");
    if (f.fail) return Err.OutOfMemory;
    return f.b.toOwnedSlice(A) catch Err.OutOfMemory;
}

fn exportTo(p0: []const u8) void {
    const files = @import("files.zig");
    var eb: [600]u8 = undefined;
    const p = files.expandHome(&eb, p0) orelse p0;
    if (!files.mayWrite(p)) return app.toast(.warn, "Headless: not writing outside /tmp ({s})", .{p});
    const data = build() catch |e| switch (e) {
        Err.NothingToDraw => return app.log("  nothing to draw: no meshes", .{}),
        else => return app.log("  could not write {s}", .{p}),
    };
    defer A.free(data);
    @import("bee.zig").writeAtomic(p, data) catch return app.log("  could not write {s}", .{p});
    app.log("  exported {s}", .{p});
}

fn exportLater(p: []const u8) void {
    @import("jobui.zig").later(exportJob, "Exporting the drawing", p, 0, 0);
}
fn exportJob(p: []const u8, _: usize, _: usize) void {
    exportTo(p);
}

/// file.export_pdf <path>: from the UI with none, the file browser; from the
/// console with none, the command half typed.
pub fn opExportPdf() void {
    const ops = @import("ops.zig");
    const arg = std.mem.trim(u8, ops.arg, " ");
    if (arg.len == 0) {
        if (ops.scripted) return @import("editors.zig").prefillConsole("file.export_pdf ~/BeeModel/drawing.pdf");
        @import("filebrowser.zig").show(.save, "Export Drawing (PDF)", ".pdf", "drawing.pdf", exportLater);
        return;
    }
    exportTo(arg);
}

// ---- drawing.options ------------------------------------------------------------------------

var tok_buf: [64]u8 = undefined;

/// dr_token: the next word or "quoted words"; null at the end.
fn token(s: []const u8, i: *usize) ?[]const u8 {
    while (i.* < s.len and s[i.*] == ' ') i.* += 1;
    if (i.* >= s.len) return null;
    var end: u8 = ' ';
    if (s[i.*] == '"') {
        end = '"';
        i.* += 1;
    }
    var n: usize = 0;
    while (i.* < s.len and s[i.*] != 0) {
        const c = s[i.*];
        i.* += 1;
        if (c == end) break;
        if (n < 63) {
            tok_buf[n] = c;
            n += 1;
        }
    }
    if (n == 0 and end != '"') return null;
    return tok_buf[0..n];
}

fn kw(t: []const u8, words: []const []const u8) ?u32 {
    for (words, 0..) |w, k| {
        if (std.mem.eql(u8, t, w)) return @intCast(k);
    }
    return null;
}

/// drawing.options [a4|a3|a2|letter] [landscape|portrait] [views front top right iso]
/// [scale auto|2:1|1:1|1:2|1:5|1:10|1:20|1:50|1:100] [title "..."] [author "..."]
pub fn opOptions() void {
    const ops = @import("ops.zig");
    const s = ops.arg;
    var i: usize = 0;
    while (token(s, &i)) |t| {
        if (kw(t, &.{ "a4", "a3", "a2", "letter" })) |k| {
            o_sheet = k;
        } else if (std.mem.eql(u8, t, "landscape")) {
            o_port = 0;
        } else if (std.mem.eql(u8, t, "portrait")) {
            o_port = 1;
        } else if (std.mem.eql(u8, t, "views")) {
            var v: u32 = 0;
            while (true) {
                var j = i;
                const t2 = token(s, &j) orelse break;
                const k = kw(t2, &.{ "front", "top", "right", "iso" }) orelse break;
                v |= @as(u32, 1) << @intCast(k);
                i = j;
            }
            if (v != 0) o_views = v;
        } else if (std.mem.eql(u8, t, "scale")) {
            const t2 = token(s, &i) orelse break;
            if (kw(t2, &.{ "auto", "2:1", "1:1", "1:2", "1:5", "1:10", "1:20", "1:50", "1:100" })) |k| o_scale = k;
        } else if (std.mem.eql(u8, t, "title") or std.mem.eql(u8, t, "author")) {
            const dst = if (t[0] == 't') &o_title else &o_author;
            const t2 = token(s, &i) orelse "";
            dst.* = @splat(0);
            @memcpy(dst[0..@min(t2.len, 63)], t2[0..@min(t2.len, 63)]);
        }
    }
}
