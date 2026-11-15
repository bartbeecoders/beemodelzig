// Material Preview (preview.s): the viewport shaded with each object's
// principled material under a studio environment.
//
// The rasterizer keeps, per pixel, the object id and an interpolated normal
// (smooth across corners closer than 30 degrees: a cube stays sharp, a
// sphere turns round). This pass shades every such pixel: the principled
// BSDF lit by a sky / ground environment (split-sum approximation) and three
// softbox lights fixed in the world, emission added, then ACES tone mapping
// and the sRGB curve (a square root, as the original).
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const gfx = @import("gfx.zig");
const world = @import("env.zig");
const probe = @import("probe.zig");
const surface = @import("surface.zig");
const gops = @import("graphops.zig");
const A = std.heap.page_allocator;

// --- corner normals ------------------------------------------------------------------

pub const Kept = struct { serial: u32 = 0, shape: u32 = 0, n: [][3]m.V3 = &.{} };
var kept: [scene.max_meshes]Kept = @splat(.{});

const cos30: f32 = 0.8660254;

/// Per triangle corner: the area-weighted normals of the triangles at that
/// vertex within 30 degrees of this one (object space, not unit). Kept per
/// mesh slot until the mesh there changes (its serial) or moves (its shape).
pub fn cornerNormals(mi: usize, me: *const scene.Mesh) ?[][3]m.V3 {
    return cornerNormalsIn(&kept[mi], me);
}

pub fn freeKept(k: *Kept) void {
    if (k.n.len > 0) A.free(k.n);
    k.* = .{};
}

/// The same, kept by the caller (an evaluated mesh has no slot).
pub fn cornerNormalsIn(k: *Kept, me: *const scene.Mesh) ?[][3]m.V3 {
    if (k.serial == me.serial and k.shape == me.shape and k.n.len == me.tris.len) return k.n;
    if (k.n.len > 0) A.free(k.n);
    k.* = .{};
    const nt = me.tris.len;
    const nv = me.verts.len;
    const out = A.alloc([3]m.V3, nt) catch return null;
    const fn_ = A.alloc(m.V3, nt) catch {
        A.free(out);
        return null;
    };
    defer A.free(fn_);
    const unit = A.alloc(m.V3, nt) catch {
        A.free(out);
        return null;
    };
    defer A.free(unit);
    // vertex -> triangles (CSR)
    const start = A.alloc(u32, nv + 1) catch {
        A.free(out);
        return null;
    };
    defer A.free(start);
    @memset(start, 0);
    for (me.tris) |t| {
        for (t) |v| start[v + 1] += 1;
    }
    for (1..nv + 1) |i| start[i] += start[i - 1];
    const list = A.alloc(u32, nt * 3) catch {
        A.free(out);
        return null;
    };
    defer A.free(list);
    const fill = A.alloc(u32, nv) catch {
        A.free(out);
        return null;
    };
    defer A.free(fill);
    @memcpy(fill, start[0..nv]);
    for (me.tris, 0..) |t, ti| {
        const a = me.verts[t[0]];
        fn_[ti] = m.cross(m.sub(me.verts[t[1]], a), m.sub(me.verts[t[2]], a));
        const l = m.len(fn_[ti]);
        unit[ti] = if (l > 1e-30) m.scale(fn_[ti], 1 / l) else .{ 0, 0, 0 };
        for (t) |v| {
            list[fill[v]] = @intCast(ti);
            fill[v] += 1;
        }
    }
    for (me.tris, 0..) |t, ti| {
        for (t, 0..) |v, c| {
            var s: m.V3 = .{ 0, 0, 0 };
            for (list[start[v]..start[v + 1]]) |o| {
                if (o == ti or m.dot(unit[o], unit[ti]) >= cos30) s = m.add(s, fn_[o]);
            }
            out[ti][c] = if (m.len(s) > 0) s else fn_[ti];
        }
    }
    k.* = .{ .serial = me.serial, .shape = me.shape, .n = out };
    return out;
}

// --- the original's per-pixel geometry (preview.s: cn_build, pv_kmat, job_xform,
// ray_bary, pixel_normal, cam_to_world), operation for operation ----------------------

/// Off: the rasterizer's normals and world-space rays (the tests compare).
pub var exact_off = false;
/// by the mesh's address (an evaluated mesh has no slot), checked by its serial and shape
var kept_x: std.AutoHashMapUnmanaged(usize, Kept) = .empty;

fn dot3o(a: m.V3, b: m.V3) f32 {
    return (a[0] * b[0] + a[1] * b[1]) + a[2] * b[2];
}

/// cn_build in the mesh's own space: per corner the faces at its vertex within
/// 30 degrees (dpps of the unit normals), their unit normals times their size
/// summed in triangle order, made unit (none: the face's own).
pub fn cornerNormalsX(me: *const scene.Mesh) ?[][3]m.V3 {
    if (kept_x.count() > 4096) {
        var it = kept_x.valueIterator();
        while (it.next()) |x| freeKept(x);
        kept_x.clearRetainingCapacity();
    }
    const gp = kept_x.getOrPut(A, @intFromPtr(me)) catch return null;
    if (!gp.found_existing) gp.value_ptr.* = .{};
    const k = gp.value_ptr;
    if (k.serial == me.serial and k.shape == me.shape and k.n.len == me.tris.len) return k.n;
    if (k.n.len > 0) A.free(k.n);
    k.* = .{};
    const nt = me.tris.len;
    const nv = me.verts.len;
    const out = A.alloc([3]m.V3, nt) catch return null;
    const face = A.alloc([4]f32, nt) catch {
        A.free(out);
        return null;
    };
    defer A.free(face);
    const start = A.alloc(u32, nv + 1) catch {
        A.free(out);
        return null;
    };
    defer A.free(start);
    const list = A.alloc(u32, nt * 3) catch {
        A.free(out);
        return null;
    };
    defer A.free(list);
    @memset(start, 0);
    for (me.tris, 0..) |t, ti| {
        const p0 = me.verts[t[0]];
        const e1 = m.sub(me.verts[t[1]], p0);
        const e2 = m.sub(me.verts[t[2]], p0);
        var c: m.V3 = .{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        const l = @sqrt(dot3o(c, c));
        if (l > 0) {
            const r = 1 / l;
            c = .{ c[0] * r, c[1] * r, c[2] * r };
        }
        face[ti] = .{ c[0], c[1], c[2], l };
        for (t) |v| start[v + 1] += 1;
    }
    for (1..nv + 1) |i| start[i] += start[i - 1];
    for (me.tris, 0..) |t, ti| {
        for (t) |v| {
            list[start[v]] = @intCast(ti);
            start[v] += 1;
        }
    }
    var i = nv;
    while (i > 0) : (i -= 1) start[i] = start[i - 1];
    start[0] = 0;
    for (me.tris, 0..) |t, ti| {
        const f = face[ti];
        const fu: m.V3 = .{ f[0], f[1], f[2] };
        for (t, 0..) |v, c| {
            var sum: m.V3 = .{ 0, 0, 0 };
            for (list[start[v]..start[v + 1]]) |o| {
                const g = face[o];
                const d = (g[0] * f[0] + g[1] * f[1]) + g[2] * f[2];
                if (!(d >= cos30)) continue;
                sum = .{ sum[0] + g[0] * g[3], sum[1] + g[1] * g[3], sum[2] + g[2] * g[3] };
            }
            const d2 = dot3o(sum, sum);
            if (d2 > 1.0e-20) {
                const l = @sqrt(d2);
                out[ti][c] = .{ sum[0] / l, sum[1] / l, sum[2] / l };
            } else out[ti][c] = fu;
        }
    }
    k.* = .{ .serial = me.serial, .shape = me.shape, .n = out };
    return out;
}

/// An object's camera matrix (job_verts' C: the view's basis times the model
/// matrix, the eye taken off) and its cofactor K (pv_kmat: what normals become).
pub const CamObj = struct {
    c: [3][4]f32,
    k: [3]m.V3,
    me: *const scene.Mesh,
    cn: [][3]m.V3,
    /// this frame's camera-space vertices and corner normals (job_verts, job_xform)
    cv: []m.V3 = &.{},
    cnc: [][3]m.V3 = &.{},
    st: []u8 = &.{},
};

/// Room for this frame's camera-space vertices and corner normals; each is
/// made when a pixel first needs it (job_verts / job_xform do all of them).
fn camFill(o: *CamObj) bool {
    o.cv = A.alloc(m.V3, o.me.verts.len) catch return false;
    o.cnc = A.alloc([3]m.V3, o.cn.len) catch {
        A.free(o.cv);
        o.cv = &.{};
        return false;
    };
    o.st = A.alloc(u8, o.me.verts.len + o.cn.len) catch {
        A.free(o.cv);
        A.free(o.cnc);
        o.cv = &.{};
        o.cnc = &.{};
        return false;
    };
    @memset(o.st, 0);
    return true;
}

/// Made once by whichever thread gets there first (0 none, 1 being made, 2
/// made); another meanwhile makes its own copy (the same bits).
fn lazyVert(o: *const CamObj, i: u32) m.V3 {
    const st = &o.st[i];
    if (@atomicLoad(u8, st, .acquire) == 2) return o.cv[i];
    const v = camVert(o, o.me.verts[i]);
    if (@cmpxchgStrong(u8, st, 0, 1, .acquire, .monotonic) == null) {
        o.cv[i] = v;
        @atomicStore(u8, st, 2, .release);
    }
    return v;
}

fn lazyCorners(o: *const CamObj, ti: u32) [3]m.V3 {
    const st = &o.st[o.me.verts.len + ti];
    if (@atomicLoad(u8, st, .acquire) == 2) return o.cnc[ti];
    const n = o.cn[ti];
    const c: [3]m.V3 = .{ camNormal(o, n[0]), camNormal(o, n[1]), camNormal(o, n[2]) };
    if (@cmpxchgStrong(u8, st, 0, 1, .acquire, .monotonic) == null) {
        o.cnc[ti] = c;
        @atomicStore(u8, st, 2, .release);
    }
    return c;
}

fn camFree(o: *CamObj) void {
    if (o.cv.len > 0) A.free(o.cv);
    if (o.cnc.len > 0) A.free(o.cnc);
    if (o.st.len > 0) A.free(o.st);
    o.st = &.{};
    o.cv = &.{};
    o.cnc = &.{};
}


pub fn camObj(mtx: m.M4, me: *const scene.Mesh, cn: [][3]m.V3, right: m.V3, up: m.V3, fwd: m.V3, eye: m.V3) CamObj {
    var o: CamObj = .{ .c = undefined, .k = undefined, .me = me, .cn = cn };
    const basis = [3]m.V3{ right, up, fwd };
    for (basis, 0..) |b, r| {
        for (0..3) |c| o.c[r][c] = (b[0] * mtx[c] + b[1] * mtx[4 + c]) + b[2] * mtx[8 + c];
        o.c[r][3] = ((mtx[3] - eye[0]) * b[0] + (mtx[7] - eye[1]) * b[1]) + (mtx[11] - eye[2]) * b[2];
    }
    const col = [3]m.V3{ .{ o.c[0][0], o.c[1][0], o.c[2][0] }, .{ o.c[0][1], o.c[1][1], o.c[2][1] }, .{ o.c[0][2], o.c[1][2], o.c[2][2] } };
    const cross = struct {
        fn f(a: m.V3, b: m.V3) m.V3 {
            return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
        }
    }.f;
    o.k = .{ cross(col[1], col[2]), cross(col[2], col[0]), cross(col[0], col[1]) };
    return o;
}

fn camVert(o: *const CamObj, p: m.V3) m.V3 {
    var r: m.V3 = undefined;
    for (0..3) |i| r[i] = ((o.c[i][0] * p[0] + o.c[i][1] * p[1]) + o.c[i][2] * p[2]) + o.c[i][3];
    return r;
}

/// job_xform: a kept corner normal into camera space, unit.
fn camNormal(o: *const CamObj, n: m.V3) m.V3 {
    var r: m.V3 = undefined;
    for (0..3) |i| r[i] = (n[0] * o.k[0][i] + n[1] * o.k[1][i]) + n[2] * o.k[2][i];
    const l = @sqrt(@max(dot3o(r, r), 1.0e-20));
    return .{ r[0] / l, r[1] / l, r[2] / l };
}

/// unit3: by the reciprocal of the length (0: as it is).
fn unit3(v: m.V3) m.V3 {
    const l = @sqrt(dot3o(v, v));
    if (!(l > 0)) return v;
    const k = 1 / l;
    return .{ v[0] * k, v[1] * k, v[2] * k };
}

pub const Px = struct {
    u: f32,
    v: f32,
    n: m.V3, // world, towards the eye
    view: m.V3, // world
    p: m.V3, // the world point
    e1: m.V3, // the triangle's edges, world
    e2: m.V3,
};

/// job_shade for pixel ray d = (dx, dy, 1): ray_bary in camera space, the
/// corner normals between, both turned to world space. Null: the ray runs along.
pub fn pixelX(o: *const CamObj, ti: u32, dx: f32, dy: f32, right: m.V3, up: m.V3, fwd: m.V3, eye: m.V3, full: bool) ?Px {
    const me = o.me;
    if (ti >= me.tris.len or ti >= o.cnc.len) return null;
    const t = me.tris[ti];
    const p0 = lazyVert(o, t[0]);
    const p1 = lazyVert(o, t[1]);
    const p2 = lazyVert(o, t[2]);
    const e1: m.V3 = .{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
    const e2: m.V3 = .{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };
    const d: m.V3 = .{ dx, dy, 1 };
    const pc: m.V3 = .{ d[1] * e2[2] - d[2] * e2[1], d[2] * e2[0] - d[0] * e2[2], d[0] * e2[1] - d[1] * e2[0] };
    const det = dot3o(e1, pc);
    if (!(@abs(det) > 0)) return null;
    const inv = 1 / det;
    const s: m.V3 = .{ -p0[0], -p0[1], -p0[2] };
    const u = ((pc[0] * s[0] + pc[1] * s[1]) + pc[2] * s[2]) * inv;
    const q: m.V3 = .{ s[1] * e1[2] - s[2] * e1[1], s[2] * e1[0] - s[0] * e1[2], s[0] * e1[1] - s[1] * e1[0] };
    const v = ((d[0] * q[0] + d[1] * q[1]) + d[2] * q[2]) * inv;
    const tt = ((q[0] * e2[0] + q[1] * e2[1]) + q[2] * e2[2]) * inv;
    // pixel_normal
    const uc = @min(@max(u, 0), 1);
    const vc = @min(@max(v, 0), 1);
    const w0 = @max((1 - uc) - vc, 0);
    const cnc = lazyCorners(o, ti);
    const n0 = cnc[0];
    const n1 = cnc[1];
    const n2 = cnc[2];
    var n: m.V3 = undefined;
    for (0..3) |i| n[i] = (n0[i] * w0 + n1[i] * uc) + n2[i] * vc;
    n = unit3(n);
    const view = unit3(.{ -d[0], -d[1], -d[2] });
    if (!(dot3o(n, view) >= 0)) n = .{ -n[0], -n[1], -n[2] };
    const toW = struct {
        fn f(a: m.V3, r: m.V3, uu: m.V3, fw: m.V3) m.V3 {
            var w: m.V3 = undefined;
            for (0..3) |i| w[i] = (r[i] * a[0] + uu[i] * a[1]) + fw[i] * a[2];
            return w;
        }
    }.f;
    const nw = toW(n, right, up, fwd);
    const vw = toW(view, right, up, fwd);
    if (!full) return .{ .u = u, .v = v, .n = nw, .view = vw, .p = eye, .e1 = e1, .e2 = e2 }; // (a plain pixel: no point, no edges)
    var p = toW(.{ d[0] * tt, d[1] * tt, d[2] * tt }, right, up, fwd);
    for (0..3) |i| p[i] = eye[i] + p[i];
    return .{ .u = u, .v = v, .n = nw, .view = vw, .p = p, .e1 = toW(e1, right, up, fwd), .e2 = toW(e2, right, up, fwd) };
}

/// The normal matrix of a world matrix: the cofactor of its 3x3 (columns
/// b x c, c x a, a x b), what the edges' cross products become.
pub fn normalMatrix(mtx: m.M4) [3]m.V3 {
    const a: m.V3 = .{ mtx[0], mtx[4], mtx[8] };
    const b: m.V3 = .{ mtx[1], mtx[5], mtx[9] };
    const c: m.V3 = .{ mtx[2], mtx[6], mtx[10] };
    return .{ m.cross(b, c), m.cross(c, a), m.cross(a, b) };
}

pub fn xformN(k: [3]m.V3, n: m.V3) m.V3 {
    return m.add(m.add(m.scale(k[0], n[0]), m.scale(k[1], n[1])), m.scale(k[2], n[2]));
}

// --- the shading -------------------------------------------------------------------

const env_zenith: m.V3 = .{ 0.34, 0.46, 0.74 };
const env_horizon: m.V3 = .{ 0.72, 0.74, 0.78 };
const env_ground: m.V3 = .{ 0.20, 0.19, 0.17 };
const env_sky_irr: m.V3 = .{ 0.46, 0.50, 0.60 };
const env_gnd_irr: m.V3 = .{ 0.20, 0.19, 0.17 };
const Light = struct { d: m.V3, c: m.V3 };
const lights = [_]Light{
    .{ .d = .{ 0.5246, 0.7343, 0.4302 }, .c = .{ 1.7, 1.65, 1.55 } },
    .{ .d = .{ -0.6230, 0.3560, -0.6963 }, .c = .{ 0.6, 0.7, 0.95 } },
    .{ .d = .{ -0.6670, 0.2665, 0.6960 }, .c = .{ 0.3, 0.3, 0.32 } },
};
const soft: f32 = 0.04; // the softbox's size (widens the lobe)
const amin: f32 = 0.003;
const inv_pi: f32 = 1.0 / std.math.pi;

/// A material's values as the shading needs them (per object, once a frame).
pub const Shader = struct {
    base: m.V3,
    f0: m.V3,
    diff: m.V3,
    emit: m.V3,
    metal: f32,
    rough: f32,
    trans: f32,
    coat: f32,
    coat_rough: f32,
    ao: f32, // a graph's occlusion of the ambient light; else 1
    spec0: f32 = 0,

    /// Vertex colours: the base times c, what follows from it.
    pub fn tint(s: *Shader, c: m.V3) void {
        for (0..3) |k| {
            s.base[k] *= c[k];
            s.f0[k] = s.base[k] * s.metal + s.spec0 * (1 - s.metal);
            s.diff[k] = s.base[k] * (1 - s.metal) * (1 - s.trans);
        }
    }

    pub fn of(ma: *const material.Material) Shader {
        const metal = ma.metallic;
        const spec0 = blk: {
            const r = (ma.ior - 1) / (ma.ior + 1);
            break :blk 2 * ma.specular * r * r;
        };
        var s: Shader = undefined;
        s.base = ma.base;
        s.spec0 = spec0;
        s.metal = metal;
        s.rough = ma.roughness;
        s.trans = ma.transmission;
        s.coat = ma.coat;
        s.coat_rough = ma.coat_rough;
        s.ao = 1;
        for (0..3) |c| {
            s.f0[c] = ma.base[c] * metal + spec0 * (1 - metal);
            s.diff[c] = ma.base[c] * (1 - metal) * (1 - ma.transmission);
            s.emit[c] = ma.emission[c] * ma.strength;
        }
        return s;
    }
};

pub const default_material = material.Material{};

fn envIrr(d: m.V3) m.V3 {
    const t = 0.5 + 0.5 * d[1];
    return m.add(env_gnd_irr, m.scale(m.sub(env_sky_irr, env_gnd_irr), t));
}

fn envSky(d: m.V3) m.V3 {
    if (d[1] <= 0) return env_ground;
    const t = @sqrt(d[1]);
    return m.add(env_horizon, m.scale(m.sub(env_zenith, env_horizon), t));
}

/// Karis' analytic fit of the pre-integrated environment BRDF: (A, B).
fn splitSum(rough: f32, nv: f32) [2]f32 {
    const c0 = [4]f32{ -1, -0.0275, -0.572, 0.022 };
    const c1 = [4]f32{ 1, 0.0425, 1.04, -0.04 };
    var r: [4]f32 = undefined;
    for (0..4) |i| r[i] = rough * c0[i] + c1[i];
    const a004 = @min(r[0] * r[0], @exp2(-9.28 * nv)) * r[0] + r[1];
    return .{ -1.04 * a004 + r[2], 1.04 * a004 + r[3] };
}

/// diffuse / pi + GGX specular, times n.l and the light's colour, added to out.
fn lightGGX(out: *m.V3, n: m.V3, v: m.V3, nv: f32, l: Light, rough: f32, f0: m.V3, diff: m.V3, k_spec: f32) void {
    const alpha = @max(rough * rough + soft, amin);
    const nl = m.dot(l.d, n);
    if (nl <= 0) return;
    const h = m.norm(m.add(l.d, v));
    const nh = @max(m.dot(h, n), 0);
    const vh = @max(m.dot(h, v), 0);
    const a2 = alpha * alpha;
    const q = nh * nh * (a2 - 1) + 1;
    const d = a2 / (q * q) * inv_pi;
    const kk = alpha * 0.5;
    const g = (nl * (1 - kk) + kk) * (nv * (1 - kk) + kk) * 4;
    const dg = d / g;
    const w0 = 1 - vh;
    const w = w0 * w0 * w0 * w0 * w0;
    for (0..3) |c| {
        const f = f0[c] + (1 - f0[c]) * w;
        out[c] += (f * dg * k_spec + diff[c] * inv_pi) * nl * l.c[c];
    }
}

/// The pixel for unit normal n and unit view vector v (toward the eye).
pub fn shade(s: *const Shader, n: m.V3, v: m.V3) u32 {
    return shadeAt(s, n, v, null);
}

/// The same at world point q: the light probes around it (probe.zig) take the
/// environment's place, and an irradiance volume the softboxes' too.
pub fn shadeAt(s: *const Shader, n: m.V3, v: m.V3, q: ?m.V3) u32 {
    const nv = @max(m.dot(n, v), 1e-4);
    const r = m.sub(m.scale(n, 2 * nv), v);
    const hdri0 = world.on();
    const pb_n = if (q) |p| probe.irr(p, n) else null;
    const pb_s = if (q) |p| probe.spec(p, m.norm(r)) else null;
    const pb_r = if (q) |p| probe.irr(p, r) else null;
    const irr_n = pb_n orelse if (hdri0) world.irrPv(n) else envIrr(n);
    const sky_r = pb_s orelse if (hdri0) world.specPv(r) else envSky(r);
    const irr_r = pb_r orelse if (hdri0) world.irrPv(r) else envIrr(r);
    const hdri = hdri0 or pb_n != null;
    const ab = splitSum(s.rough * s.rough, nv);
    var out: m.V3 = undefined;
    const blur = s.rough * s.rough;
    for (0..3) |c| {
        const env = sky_r[c] + (irr_r[c] - sky_r[c]) * blur;
        out[c] = ((s.f0[c] * ab[0] + ab[1]) * env + s.diff[c] * irr_n[c]) * s.ao;
    }
    // transmission: the environment behind, tinted (approx.)
    if (s.trans > 0) {
        const behind = if (hdri0) world.specPv(m.scale(v, -1)) else envSky(m.scale(v, -1));
        const k = @max(1 - ab[0] - ab[1], 0) * s.trans * (1 - s.metal);
        for (0..3) |c| out[c] += behind[c] * s.base[c] * k;
    }
    if (!hdri) for (lights) |l| lightGGX(&out, n, v, nv, l, s.rough, s.f0, s.diff, 1);
    // clear coat: a second, clear layer on top
    if (s.coat > 0) {
        const cab = splitSum(s.coat_rough * s.coat_rough, nv);
        const w = (0.04 * cab[0] + cab[1]) * s.coat;
        for (0..3) |c| out[c] += sky_r[c] * w;
        if (!hdri) lightGGX(&out, n, v, nv, lights[0], s.coat_rough, .{ 0.04, 0.04, 0.04 }, .{ 0, 0, 0 }, s.coat);
    }
    var px: u32 = 0;
    for (0..3) |c| {
        const x = @max(out[c] + s.emit[c], 0);
        const t = std.math.clamp(x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14), 0, 1);
        px = (px << 8) | @as(u32, @intFromFloat(@sqrt(t) * 255 + 0.5));
    }
    return px;
}

// --- the pass over the viewport ---------------------------------------------------------

/// Per pixel normals (world, not unit) written by gfx.Canvas.triangleN.
pub var nbuf: [][3]f32 = &.{};
/// Per pixel the source triangle (shader graphs).
var tbuf: []u32 = &.{};

pub fn ensure(n: usize) bool {
    if (nbuf.len >= n and tbuf.len >= n) return true;
    if (nbuf.len > 0) A.free(nbuf);
    if (tbuf.len > 0) A.free(tbuf);
    gfx.tri_buf = null;
    tbuf = &.{};
    nbuf = A.alloc([3]f32, n) catch {
        nbuf = &.{};
        return false;
    };
    tbuf = A.alloc(u32, n) catch {
        A.free(nbuf);
        nbuf = &.{};
        tbuf = &.{};
        return false;
    };
    gfx.tri_buf = tbuf.ptr;
    return true;
}

const Pass = struct {
    cv: *gfx.Canvas,
    ids: [*]u16,
    sh: []Shader,
    rr: gfx.Rect,
    right: m.V3,
    up: m.V3,
    fwd: m.V3,
    f: f32,
    cx: f32,
    cy: f32,
    eye: m.V3,
    /// per object: its graph, if it has one
    gr: []?surface.PvObj,
    /// per object: what shows, when it has vertex colours, and where
    vm: []?*const scene.Mesh,
    mt: []m.M4,
    /// per object: its camera matrix and corner normals (the original's geometry)
    xs: []?CamObj,
};

fn rows(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const p: *const Pass = @ptrCast(@alignCast(ctx));
    const cv = p.cv;
    for (lo..hi) |yi| {
        const y = p.rr.y + @as(i32, @intCast(yi));
        const dy = (p.cy - (@as(f32, @floatFromInt(y)) + 0.5)) / p.f;
        const row = m.add(m.scale(p.up, dy), p.fwd);
        var o: usize = @intCast(y * cv.w + p.rr.x);
        var x = p.rr.x;
        while (x < p.rr.right()) : ({
            x += 1;
            o += 1;
        }) {
            const id = p.ids[o];
            if (id == 0 or id > p.sh.len) continue;
            const nn = nbuf[o];
            const l2 = nn[0] * nn[0] + nn[1] * nn[1] + nn[2] * nn[2];
            if (!(l2 > 1e-30) or !std.math.isFinite(l2)) continue; // not shaded (a selected face)
            const dx = ((@as(f32, @floatFromInt(x)) + 0.5) - p.cx) / p.f;
            if (p.xs[id - 1]) |*xo| {
                // the original's geometry: the ray in camera space against the
                // source triangle, its corner normals between
                if (pixelX(xo, tbuf[o], dx, dy, p.right, p.up, p.fwd, p.eye, p.gr[id - 1] != null or probe.cur != null)) |px| {
                    var n2 = px.n;
                    const q2: ?m.V3 = if (probe.cur != null) px.p else null;
                    if (p.gr[id - 1]) |*g| {
                        var cp: material.Material = undefined;
                        const ao = surface.previewGraph(g, tbuf[o], px.u, px.v, px.e1, px.e2, px.p, &n2, px.view, &cp);
                        var s = Shader.of(&cp);
                        s.ao = ao;
                        cv.px[o] = shadeAt(&s, n2, px.view, q2);
                        continue;
                    }
                    if (p.vm[id - 1]) |me| {
                        if (@import("vcol.zig").lin(me, tbuf[o], px.u, px.v)) |c| {
                            var s = p.sh[id - 1];
                            s.tint(c);
                            cv.px[o] = shadeAt(&s, n2, px.view, q2);
                            continue;
                        }
                    }
                    cv.px[o] = shadeAt(&p.sh[id - 1], n2, px.view, q2);
                }
                continue;
            }
            const ray = m.add(row, m.scale(p.right, dx));
            const v = m.norm(m.scale(ray, -1));
            var n = m.scale(nn, 1 / @sqrt(l2));
            if (m.dot(n, v) < 0) n = m.scale(n, -1); // the back side
            // the world point: the depth buffer holds 1 / depth along fwd
            const q: ?m.V3 = if (probe.cur != null and cv.zbuf != null) m.add(p.eye, m.scale(ray, 1 / cv.zbuf.?[o])) else null;
            if (p.gr[id - 1]) |*g| {
                const wp = if (cv.zbuf) |z| m.add(p.eye, m.scale(ray, 1 / z[o])) else p.eye;
                var cp: material.Material = undefined;
                const ao = surface.previewPixel(g, tbuf[o], p.eye, ray, wp, &n, v, &cp);
                var s = Shader.of(&cp);
                s.ao = ao;
                cv.px[o] = shadeAt(&s, n, v, q);
                continue;
            }
            if (p.vm[id - 1]) |me| {
                // vertex colours tint the base
                if (surface.previewVcol(me, p.mt[id - 1], tbuf[o], p.eye, ray)) |c| {
                    var s = p.sh[id - 1];
                    s.tint(c);
                    cv.px[o] = shadeAt(&s, n, v, q);
                    continue;
                }
            }
            cv.px[o] = shadeAt(&p.sh[id - 1], n, v, q);
        }
    }
}

/// Shade the pixels of r that hold a mesh (rows on every core); the camera
/// as the rasterizer projects: pixel rays right * dx + up * dy + fwd.
pub fn pass(cv: *gfx.Canvas, r: gfx.Rect, right: m.V3, up: m.V3, fwd: m.V3, f: f32, cx: f32, cy: f32, eye: m.V3) void {
    const ids = cv.ids orelse return;
    if (nbuf.len < @as(usize, @intCast(cv.w * cv.h))) return;
    const sh = A.alloc(Shader, scene.count) catch return;
    defer A.free(sh);
    for (scene.objects[0..scene.count], sh) |*o, *s| s.* = Shader.of(material.of(o) orelse &default_material);
    const rr = r.intersect(cv.clip);
    if (rr.w <= 0 or rr.h <= 0) return;
    const gr = A.alloc(?surface.PvObj, scene.count) catch return;
    defer A.free(gr);
    const vm = A.alloc(?*const scene.Mesh, scene.count) catch return;
    defer A.free(vm);
    const mt = A.alloc(m.M4, scene.count) catch return;
    defer A.free(mt);
    for (vm, mt, 0..) |*q, *t, oi| {
        q.* = null;
        const me = @import("mods.zig").of(oi) orelse continue;
        if (me.vcol.len == 0) continue;
        q.* = me;
        t.* = scene.world(oi);
    }
    gops.syncCheck();
    @import("shgraph.zig").scene_time = gops.sceneTime();
    for (gr, 0..) |*g, oi| {
        g.* = null;
        const ma = material.of(&scene.objects[oi]) orelse continue;
        if (ma.nodes() == 0) continue;
        const me = @import("mods.zig").of(oi) orelse continue;
        g.* = .{ .ma = ma, .me = me, .mtx = scene.world(oi) };
    }
    const xs = A.alloc(?CamObj, scene.count) catch return;
    defer A.free(xs);
    const editing = @import("editmesh.zig");
    for (xs, 0..) |*x, oi| {
        x.* = null;
        if (exact_off or (editing.active and editing.obj == oi)) continue; // (the edit mesh: as drawn)
        const me = @import("mods.zig").of(oi) orelse continue;
        const cn = cornerNormalsX(me) orelse continue;
        x.* = camObj(scene.world(oi), me, cn, right, up, fwd, eye);
    }
    for (xs) |*x| {
        if (x.*) |*o| {
            if (!camFill(o)) x.* = null;
        }
    }
    defer for (xs) |*x| {
        if (x.*) |*o| camFree(o);
    };
    var p = Pass{ .cv = cv, .ids = ids, .sh = sh, .rr = rr, .right = right, .up = up, .fwd = fwd, .f = f, .cx = cx, .cy = cy, .eye = eye, .gr = gr, .vm = vm, .mt = mt, .xs = xs };
    @import("jobs.zig").parallelFor(@intCast(rr.h), 8, &p, rows);
}

test "shade: grey under the studio light" {
    const s = Shader.of(&default_material);
    const px = shade(&s, .{ 0, 1, 0 }, .{ 0, 0.6, 0.8 });
    try std.testing.expect(px & 0xff > 100);
    try std.testing.expect(px != 0xffffff);
}

// --- a material alone on a shape (preview.s preview_material) ------------------------

const Ball = struct {
    ma: ?*const material.Material,
    out: []u32,
    size: u32,
    shape: u32,
    cy: f32,
    sy: f32,
    cp: f32,
    sp: f32,

    /// Ry(-yaw) Rx(-pitch) v
    fn toObj(b: *const Ball, v: m.V3) m.V3 {
        const x = v[0];
        const y1 = v[1] * b.cp + v[2] * b.sp;
        const z1 = v[2] * b.cp - v[1] * b.sp;
        return .{ x * b.cy - z1 * b.sy, y1, z1 * b.cy + x * b.sy };
    }
    /// Rx(pitch) Ry(yaw) v
    fn toCam(b: *const Ball, v: m.V3) m.V3 {
        const x1 = v[0] * b.cy + v[2] * b.sy;
        const z1 = v[2] * b.cy - v[0] * b.sy;
        const y2 = v[1] * b.cp - z1 * b.sp;
        const z2 = v[1] * b.sp + z1 * b.cp;
        return .{ x1, y2, z2 };
    }
};

fn pmDot(a: m.V3, b: m.V3) f32 {
    var s = a[0] * b[0];
    s += a[1] * b[1];
    s += a[2] * b[2];
    return s;
}

fn pmBg(x: u32, y: u32) u32 {
    return if (((x >> 3) ^ (y >> 3)) & 1 != 0) 0x33363c else 0x2a2c31;
}

fn cvtRound(x: f32) i32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    if (@abs(x - @trunc(x)) == 0.5) return @intFromFloat(2 * @round(x / 2));
    return @intFromFloat(@round(x));
}

/// pm_blend: over * a + under * (255 - a), per channel >> 8.
fn pmBlend(over: u32, under: u32, op0: f32) u32 {
    var op = if (op0 > 0) op0 else 0;
    op = if (op < 1) op else 1;
    const a: u32 = @bitCast(cvtRound(op * 255.0));
    const ia = 255 -% a;
    var r: u32 = 0;
    var sh: u5 = 16;
    while (true) {
        const c = (((over >> sh) & 255) *% a +% ((under >> sh) & 255) *% ia) >> 8;
        r |= c << sh;
        if (sh == 0) break;
        sh -= 8;
    }
    return r;
}

fn ballRows(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const b: *const Ball = @ptrCast(@alignCast(ctx));
    const sg = @import("shgraph.zig");
    const eye: m.V3 = .{ 0, 0, 3.4 };
    const oo = b.toObj(eye);
    const sizef: f32 = @floatFromInt(b.size);
    const hstep: f32 = 0.002;
    var row = lo;
    while (row < hi) : (row += 1) {
        var x: u32 = 0;
        while (x < b.size) : (x += 1) {
            var dx = (@as(f32, @floatFromInt(x)) + 0.5) / sizef;
            dx = dx + dx - 1.0;
            var dy = (@as(f32, @floatFromInt(row)) + 0.5) / sizef;
            dy = dy + dy;
            dy = 1.0 - dy;
            var d: m.V3 = .{ dx, dy, -2.6 };
            const il = 1.0 / @sqrt(pmDot(d, d));
            for (0..3) |c| d[c] *= il;
            const do_ = b.toObj(d);
            var po: m.V3 = undefined;
            var no: m.V3 = undefined;
            var tu: m.V3 = undefined;
            var tv: m.V3 = undefined;
            var u: f32 = 0;
            var vv: f32 = 0;
            const px = blk: {
                switch (b.shape) {
                    1 => {
                        // slabs: [-c, c]^3
                        const cs: f32 = 0.75;
                        var tn: f32 = 0;
                        var tf: f32 = 1.0e8;
                        var ax: i32 = -1;
                        for (0..3) |c| {
                            const dc = do_[c];
                            if (@abs(dc) < 1.0e-4) {
                                if (@abs(oo[c]) > cs) break :blk pmBg(x, @intCast(row));
                                continue;
                            }
                            var t1 = (-cs - oo[c]) / dc;
                            var t2 = (cs - oo[c]) / dc;
                            const t3 = t1;
                            t1 = if (t1 < t2) t1 else t2;
                            t2 = if (t2 > t3) t2 else t3;
                            if (t1 > tn) {
                                tn = t1;
                                ax = @intCast(c);
                            }
                            tf = if (tf < t2) tf else t2;
                        }
                        if (tn > tf or ax < 0) break :blk pmBg(x, @intCast(row));
                        for (0..3) |c| po[c] = do_[c] * tn + oo[c];
                        const a: usize = @intCast(ax);
                        no = .{ 0, 0, 0 };
                        no[a] = if (po[a] >= 0) 1 else -1;
                        const faxes = [6]u8{ 2, 1, 0, 2, 0, 1 };
                        const ua = faxes[a * 2];
                        const va = faxes[a * 2 + 1];
                        u = po[ua] / cs * 0.5 + 0.5;
                        vv = po[va] / cs * 0.5 + 0.5;
                        tu = .{ 0, 0, 0 };
                        tv = .{ 0, 0, 0 };
                        tu[ua] = cs + cs;
                        tv[va] = cs + cs;
                    },
                    2 => {
                        // y = 0, |x| |z| <= p
                        const pp: f32 = 1.1;
                        if (@abs(do_[1]) < 1.0e-4) break :blk pmBg(x, @intCast(row));
                        const t = -oo[1] / do_[1];
                        if (!(t > 0)) break :blk pmBg(x, @intCast(row));
                        for (0..3) |c| po[c] = do_[c] * t + oo[c];
                        if (@abs(po[0]) > pp or @abs(po[2]) > pp) break :blk pmBg(x, @intCast(row));
                        no = .{ 0, if (0 > do_[1]) 1 else -1, 0 };
                        u = po[0] / pp * 0.5 + 0.5;
                        vv = 0.5 - po[2] / pp * 0.5;
                        tu = .{ pp + pp, 0, 0 };
                        tv = .{ 0, 0, -(pp + pp) };
                    },
                    else => {
                        // sphere: |o + t d| = 1
                        const bb = pmDot(oo, do_);
                        const cc = pmDot(oo, oo) - 1.0;
                        var disc = bb * bb;
                        disc -= cc;
                        if (disc < 0) break :blk pmBg(x, @intCast(row));
                        const t = -bb - @sqrt(disc);
                        for (0..3) |c| po[c] = do_[c] * t + oo[c];
                        no = po;
                        const at: f32 = @floatCast(std.math.atan2(@as(f64, po[0]), @as(f64, po[2])));
                        u = at * 0.15915494 + 0.5;
                        vv = (po[1] + 1.0) * 0.5;
                        tu = .{ po[2] * 6.2831853, 0, -(po[0] * 6.2831853) };
                        tv = .{ 0, 2, 0 };
                    },
                }
                // the values, the normal and the view (camera space)
                const ma = b.ma orelse &default_material;
                var n = b.toCam(no);
                const v: m.V3 = .{ -d[0], -d[1], -d[2] };
                var copy: material.Material = undefined;
                var src: *const material.Material = ma;
                var ao: f32 = 1;
                if (ma.nodes() != 0) {
                    var sc = sg.SC{};
                    sc.p0o = po;
                    for (0..3) |c| {
                        sc.e1o[c] = tu[c] * hstep;
                        sc.e2o[c] = tv[c] * hstep;
                    }
                    sc.pu = b.toCam(sc.e1o);
                    sc.pv = b.toCam(sc.e2o);
                    sc.n = n;
                    sc.wp = b.toCam(po);
                    sc.wv = v;
                    sc.vc = .{ 1, 1, 1 };
                    const uvs = [6]f32{ u, vv, u + hstep, vv, u, vv + hstep };
                    sc.uvp = &uvs;
                    sg.copyValues(&copy, ma);
                    _ = sg.shade(ma, material.list[0..material.count], &sc, &copy, false);
                    src = &copy;
                    if (sc.flags & (1 << sg.PIN_AO) != 0) ao = sg.rtAo(&copy);
                    if (sc.flags & (1 << sg.PIN_NORMAL) != 0) n = sc.n;
                    // masked: below the clip, the background
                    if (cvtRound(ma.blend) == 1) {
                        var a = copy.alpha;
                        if (sc.flags & (1 << sg.PIN_MASK) != 0) a = sg.rtMask(&copy);
                        const clip: f32 = if (ma.clip > 0) ma.clip else 0.33333334;
                        if (a < clip) break :blk pmBg(x, @intCast(row));
                    }
                }
                var s = Shader.of(src);
                s.ao = ao;
                var c = shadeAt(&s, n, v, null);
                if (b.ma != null and cvtRound(ma.blend) == 2) {
                    const op = if (ma.nodes() != 0) copy.alpha else ma.alpha;
                    c = pmBlend(c, pmBg(x, @intCast(row)), op);
                }
                break :blk c;
            };
            b.out[row * b.size + x] = px;
        }
    }
}

/// preview_material: the material (null: the default) on a shape alone (0 sphere,
/// 1 cube, 2 plane, turned by yaw and pitch) under the studio environment, as the
/// viewport preview shades it (its graph, masks and opacity too). The node
/// editor's preview pane.
pub fn materialBall(ma: ?*const material.Material, out: []u32, size: u32, shape: u32, yaw: f32, pitch: f32) void {
    _ = world.prep();
    var b = Ball{
        .ma = ma,
        .out = out,
        .size = size,
        .shape = shape,
        .cy = @floatCast(@cos(@as(f64, yaw))),
        .sy = @floatCast(@sin(@as(f64, yaw))),
        .cp = @floatCast(@cos(@as(f64, pitch))),
        .sp = @floatCast(@sin(@as(f64, pitch))),
    };
    @import("jobs.zig").parallelFor(size, 8, &b, ballRows);
}
