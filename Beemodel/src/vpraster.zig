// Plain meshes on every core. The objects a frame shows go in batches: their
// vertices are transformed and their triangles lit, culled and clipped in
// parallel, unit by unit, then the rows of the viewport are rasterized band by
// band. A band walks the units in scene order, so the depth test sees the
// triangles in the same order as drawing them one by one: the image is the
// same, pixel for pixel, as the serial path in viewport.zig.
const std = @import("std");
const gfx = @import("gfx.zig");
const m = @import("math.zig");
const scene = @import("scene.zig");
const em = @import("editmesh.zig");
const jobs = @import("jobs.zig");
const preview = @import("preview.zig");
const vp = @import("viewport.zig");

const Rect = gfx.Rect;
const A = std.heap.page_allocator;

/// Off: every frame the serial way (tests compare the two).
pub var enabled: bool = true;
/// A frame with fewer triangles is not worth the threads.
pub var min_tris: usize = 16384;

const UNIT = 2048; // triangles a unit
const MAX_UNITS = 256; // units a batch
const VERTS_UNIT = 16384;

const Tri = struct {
    p: [3][3]f32,
    col: u32,
    ti: u32,
    id: u16,
    y0: i32,
    y1: i32,
};

const Obj = struct {
    mesh: *const scene.Mesh,
    verts: usize, // first in the batch's arrays
    mtx: m.M4,
    col: u32,
    editing: bool,
    cn: ?[][3]m.V3,
    nmat: [3]m.V3,
    id: u16,
    oi: usize,
    tint: bool,
    cull: bool, // closed and wholly in front of the near plane: back faces skipped
};
const Unit = struct { obj: u32, lo: u32, hi: u32, n: u32 = 0, y0: i32 = 0, y1: i32 = 0 };
const VUnit = struct { obj: u32, lo: u32, hi: u32 };

var objs: [MAX_UNITS]Obj = undefined;
var nobj: usize = 0;
var units: [MAX_UNITS]Unit = undefined;
var nunit: usize = 0;
var vunits: []VUnit = &.{};
var nvunit: usize = 0;
var wv: []m.V3 = &.{};
var vv: []m.V3 = &.{};
var nvert: usize = 0;
var out: []Tri = &.{}; // MAX_UNITS x (2 x UNIT)
var out_n: [][3]m.V3 = &.{}; // their corner normals (Material Preview)
var cv: *gfx.Canvas = undefined;
var cam: *const vp.Cam = undefined;
var mat_prev = false;

pub fn wanted(total_tris: usize) bool {
    return enabled and total_tris >= min_tris and jobs.count() > 1 and gfx.sink == null and space();
}

fn space() bool {
    if (out.len > 0) return true;
    // (only the pages written to are ever real)
    out = A.alloc(Tri, MAX_UNITS * 2 * UNIT) catch return false;
    out_n = A.alloc([3]m.V3, MAX_UNITS * 2 * UNIT) catch {
        A.free(out);
        out = &.{};
        return false;
    };
    vunits = A.alloc(VUnit, 4096) catch {
        A.free(out);
        A.free(out_n);
        out = &.{};
        return false;
    };
    return true;
}

fn vertSpace(n: usize) bool {
    if (wv.len >= n) return true;
    if (wv.len > 0) {
        A.free(wv);
        A.free(vv);
        wv = &.{};
        vv = &.{};
    }
    const cap = @max(n, 1 << 20);
    wv = A.alloc(m.V3, cap) catch return false;
    vv = A.alloc(m.V3, cap) catch {
        A.free(wv);
        wv = &.{};
        return false;
    };
    return true;
}

pub fn begin(c: *gfx.Canvas, k: *const vp.Cam, material: bool) void {
    cv = c;
    cam = k;
    mat_prev = material;
    nobj = 0;
    nunit = 0;
    nvunit = 0;
    nvert = 0;
}

/// A mesh of the frame. False: no memory for it (the caller draws it).
pub fn add(mesh: *const scene.Mesh, mtx: m.M4, col: u32, id: u16, cn: ?[][3]m.V3, editing: bool) bool {
    const nt = mesh.tris.len;
    const nv = mesh.verts.len;
    const need_units = (nt + UNIT - 1) / UNIT;
    const need_v = (nv + VERTS_UNIT - 1) / VERTS_UNIT;
    if (nobj >= objs.len or nunit + need_units > units.len or nvunit + need_v > vunits.len) flush();
    if (need_units > units.len or need_v > vunits.len) return addHuge(mesh, mtx, col, id, cn, editing);
    if (!vertSpace(nvert + nv)) {
        flush();
        if (!vertSpace(nv)) return false;
    }
    addRange(mesh, mtx, col, id, cn, editing, 0, nt);
    return true;
}

fn addRange(mesh: *const scene.Mesh, mtx: m.M4, col: u32, id: u16, cn: ?[][3]m.V3, editing: bool, t0: usize, t1: usize) void {
    const nv = mesh.verts.len;
    objs[nobj] = .{ .mesh = mesh, .verts = nvert, .mtx = mtx, .col = col, .editing = editing, .cn = cn, .nmat = preview.normalMatrix(mtx), .id = id, .oi = id - 1, .tint = vp.tinted(id - 1, mesh), .cull = mesh.closed and vp.boxInFront(cam, mtx, mesh.lo, mesh.hi) };
    var lo: usize = 0;
    while (lo < nv) : (lo += VERTS_UNIT) {
        vunits[nvunit] = .{ .obj = @intCast(nobj), .lo = @intCast(lo), .hi = @intCast(@min(nv, lo + VERTS_UNIT)) };
        nvunit += 1;
    }
    var t = t0;
    while (t < t1) : (t += UNIT) {
        units[nunit] = .{ .obj = @intCast(nobj), .lo = @intCast(t), .hi = @intCast(@min(t1, t + UNIT)) };
        nunit += 1;
    }
    nvert += nv;
    nobj += 1;
}

/// A mesh bigger than a batch: batch after batch of its triangles.
fn addHuge(mesh: *const scene.Mesh, mtx: m.M4, col: u32, id: u16, cn: ?[][3]m.V3, editing: bool) bool {
    if (!vertSpace(mesh.verts.len) or (mesh.verts.len + VERTS_UNIT - 1) / VERTS_UNIT > vunits.len) return false;
    var t: usize = 0;
    while (t < mesh.tris.len) : (t += MAX_UNITS * UNIT) {
        addRange(mesh, mtx, col, id, cn, editing, t, @min(mesh.tris.len, t + MAX_UNITS * UNIT));
        flush();
    }
    return true;
}

pub fn finish() void {
    flush();
}

fn vertsJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (vunits[lo..hi]) |u| {
        const o = &objs[u.obj];
        const src = o.mesh.verts;
        for (u.lo..u.hi) |i| {
            const w = m.xform(o.mtx, src[i]);
            wv[o.verts + i] = w;
            vv[o.verts + i] = cam.toView(w);
        }
    }
}

fn clipEmit(t: [3]m.V3, tn: [3]m.V3, col: u32, ti: u32, id: u16, slots: []Tri, ns: [][3]m.V3, n: *u32) void {
    const c = cam;
    const near = vp.near;
    var poly: [4]m.V3 = undefined;
    var pn: [4]m.V3 = undefined;
    var k: usize = 0;
    for (0..3) |e| {
        const a = t[e];
        const b = t[(e + 1) % 3];
        const ain = a[2] >= near;
        const bin = b[2] >= near;
        if (ain) {
            poly[k] = a;
            pn[k] = tn[e];
            k += 1;
        }
        if (ain != bin) {
            const na = tn[e];
            const nb = tn[(e + 1) % 3];
            const q = if (ain) vp.cutNear(a, b) else vp.cutNear(b, a);
            poly[k] = q.p;
            pn[k] = if (ain) m.add(na, m.scale(m.sub(nb, na), q.s)) else m.add(nb, m.scale(m.sub(na, nb), q.s));
            k += 1;
        }
    }
    if (k < 3) return;
    var sp: [4][3]f32 = undefined;
    for (poly[0..k], 0..) |p, j| sp[j] = vp.scr(c, p);
    const one = struct {
        fn f(a: [3]f32, b: [3]f32, d: [3]f32, na: m.V3, nb: m.V3, nd: m.V3, cl: u32, tid: u32, i_d: u16, sl: []Tri, sn: [][3]m.V3, nn: *u32) void {
            const lo = @min(a[1], @min(b[1], d[1]));
            const hi = @max(a[1], @max(b[1], d[1]));
            // (the rows it covers, held to an int's range: corners are not clamped)
            sl[nn.*] = .{ .p = .{ a, b, d }, .col = cl, .ti = tid, .id = i_d, .y0 = @intFromFloat(@floor(std.math.clamp(lo, -1e9, 1e9))), .y1 = @intFromFloat(@ceil(std.math.clamp(hi, -1e9, 1e9))) };
            if (mat_prev) sn[nn.*] = .{ na, nb, nd };
            nn.* += 1;
        }
    }.f;
    one(sp[0], sp[1], sp[2], pn[0], pn[1], pn[2], col, ti, id, slots, ns, n);
    if (k == 4) one(sp[0], sp[2], sp[3], pn[0], pn[2], pn[3], col, ti, id, slots, ns, n);
}

fn trisJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const c = cam;
    const z: m.V3 = .{ 0, 0, 0 };
    for (lo..hi) |ui| {
        const u = &units[ui];
        const o = &objs[u.obj];
        const me = o.mesh;
        const slots = out[ui * 2 * UNIT..][0 .. 2 * UNIT];
        const ns = out_n[ui * 2 * UNIT..][0 .. 2 * UNIT];
        const w = wv[o.verts..];
        const v = vv[o.verts..];
        var n: u32 = 0;
        for (u.lo..u.hi) |ti| {
            const t = me.tris[ti];
            const a = w[t[0]];
            const fn_ = m.norm(m.cross(m.sub(w[t[1]], a), m.sub(w[t[2]], a)));
            var nn = fn_;
            if (m.dot(fn_, m.sub(a, c.eye)) >= 0) {
                if (o.cull) continue;
                nn = m.scale(fn_, -1);
            }
            const lit = 0.28 + 0.72 * @abs(m.dot(nn, c.fwd));
            var base = o.col;
            const fsel = o.editing and me.serial < 0x80000000 and em.faceSelected(me, me.tri_poly[ti]);
            if (fsel) base = vp.FACE_SEL else if (o.tint) base = vp.paintTint(o.oi, me, ti, base);
            var tn: [3]m.V3 = .{ z, z, z };
            if (o.cn) |corner| {
                if (!fsel) tn = .{ preview.xformN(o.nmat, corner[ti][0]), preview.xformN(o.nmat, corner[ti][1]), preview.xformN(o.nmat, corner[ti][2]) };
            }
            clipEmit(.{ v[t[0]], v[t[1]], v[t[2]] }, tn, gfx.shade(base, lit), @intCast(ti), o.id, slots, ns, &n);
        }
        u.n = n;
        // what the unit covers: a band skips it whole
        var ylo: i32 = std.math.maxInt(i32);
        var yhi: i32 = std.math.minInt(i32);
        for (slots[0..n]) |*q| {
            ylo = @min(ylo, q.y0);
            yhi = @max(yhi, q.y1);
        }
        u.y0 = ylo;
        u.y1 = yhi;
    }
}

const Band = struct { y0: i32, h: i32, n: i32 };

fn bandsJob(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const b: *const Band = @ptrCast(@alignCast(ctx));
    const nb = if (mat_prev) preview.nbuf.ptr else undefined;
    for (lo..hi) |k| {
        const ki: i32 = @intCast(k);
        const y0 = b.y0 + @divTrunc(b.h * ki, b.n);
        const y1 = b.y0 + @divTrunc(b.h * (ki + 1), b.n);
        var bc = cv.*;
        bc.clip = .{ .x = cv.clip.x, .y = y0, .w = cv.clip.w, .h = y1 - y0 };
        for (units[0..nunit], 0..) |*u, ui| {
            if (u.n == 0 or u.y1 < y0 or u.y0 >= y1) continue;
            const ts = out[ui * 2 * UNIT..][0..u.n];
            for (ts, 0..) |*t, ti| {
                if (t.y1 < y0 or t.y0 >= y1) continue;
                if (mat_prev) {
                    bc.tri = t.ti;
                    bc.triangleN(t.p[0], t.p[1], t.p[2], out_n[ui * 2 * UNIT + ti], t.col, t.id, nb);
                } else bc.triangle(t.p[0], t.p[1], t.p[2], t.col, t.id);
            }
        }
    }
}

var dummy: u8 = 0;

fn flush() void {
    if (nunit == 0) {
        nobj = 0;
        nvert = 0;
        nvunit = 0;
        return;
    }
    jobs.parallelFor(nvunit, 1, &dummy, vertsJob);
    jobs.parallelFor(nunit, 1, &dummy, trisJob);
    var b = Band{ .y0 = cv.clip.y, .h = cv.clip.h, .n = @intCast(@min(@as(usize, @intCast(@max(1, cv.clip.h))), jobs.count() * 3)) };
    jobs.parallelFor(@intCast(b.n), 1, &b, bandsJob);
    nobj = 0;
    nunit = 0;
    nvunit = 0;
    nvert = 0;
}
