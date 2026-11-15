// What the path tracer asks of a hit's material (hive_pt.s): its graph at the
// point, and how much of the surface stops a ray: rays go on through the parts
// of masked, translucent and one-sided materials that let them, by chance, as
// much as they do. Runs on the tracer's workers: no allocation.
const std = @import("std");
const m = @import("math.zig");
const hive = @import("hive.zig");
const material = @import("material.zig");
const sg = @import("shgraph.zig");
const vcol = @import("vcol.zig");
const Material = material.Material;

fn context(sc: *sg.SC, ti: u32, u: f32, v: f32) void {
    const t = &hive.tris[ti];
    const ob = &hive.obj_tris[ti];
    sc.p0o = ob.v0;
    sc.e1o = ob.e1;
    sc.e2o = ob.e2;
    sc.u = u;
    sc.v = v;
    sc.pu = t.e1;
    sc.pv = t.e2;
    const uv = &hive.tuv[ti];
    sc.uvp = if (std.math.isNan(uv[0])) null else uv;
    // the vertex colour (none: white)
    if (hasVcol(ti)) sc.vc = vcol.lin3(&hive.tvc[ti], u, v);
}

inline fn hasVcol(ti: u32) bool {
    return hive.tvc[ti][0] != 0;
}

/// The material's graph at a hit: the results in `out` (returned), the normal bent.
/// Vertex colours tint the base, unless the graph read them.
pub fn hitGraph(ma: *const Material, h: hive.Hit, p: m.V3, ns: *m.V3, wo: m.V3, out: *Material) *const Material {
    var sc = sg.SC{};
    context(&sc, h.tri, h.u, h.v);
    sc.n = ns.*;
    sc.wp = p;
    // (the original's hit_graph copies the 12 bytes after the hit point, PF_NG,
    // the geometric normal, as "towards the eye": Camera Vector and Fresnel see
    // the normal there. A bug, not copied; to match it: sc.wv = the geometric normal.)
    sc.wv = wo;
    sg.copyValues(out, ma);
    _ = sg.shade(ma, hive.mat_list, &sc, out, false);
    if (sc.flags & (1 << sg.PIN_NORMAL) != 0) ns.* = sc.n;
    if (sc.flags & sg.SCF_VCOL == 0 and hasVcol(h.tri)) {
        for (0..3) |k| out.base[k] *= sc.vc[k];
    }
    return out;
}

/// A material with no graph on a triangle with vertex colours: its copy, tinted.
pub fn hitTint(ma: *const Material, h: hive.Hit, out: *Material) *const Material {
    if (!hasVcol(h.tri)) return ma;
    out.* = ma.*;
    const c = vcol.lin3(&hive.tvc[h.tri], h.u, h.v);
    for (0..3) |k| out.base[k] *= c[k];
    return out;
}

/// How much of the surface there stops a ray: 1 opaque, 0 a hole (a one-sided
/// material from behind, a masked one below its clip value), else a translucent
/// material's opacity.
pub fn cover(h: hive.Hit, d: m.V3) f32 {
    const ma = hive.materialOf(h.tri);
    const t = &hive.tris[h.tri];
    if (ma.one_sided >= 0.5 and m.dot(m.cross(t.e1, t.e2), d) > 0) return 0;
    const blend: i32 = if (ma.blend >= 1.5) 2 else if (ma.blend >= 0.5) 1 else 0;
    if (blend <= 0) return 1;
    var a = ma.alpha;
    if (ma.nodes() != 0) {
        var sc = sg.SC{};
        context(&sc, h.tri, h.u, h.v);
        sc.n = .{ 0, 0, 1 };
        sc.wp = m.add(t.v0, m.add(m.scale(t.e1, h.u), m.scale(t.e2, h.v)));
        sc.wv = m.scale(d, -1);
        var cp: Material = undefined;
        sg.copyValues(&cp, ma);
        _ = sg.shade(ma, hive.mat_list, &sc, &cp, true);
        a = cp.alpha;
        if (blend == 1 and sc.flags & (1 << sg.PIN_MASK) != 0) a = sg.rtMask(&cp);
    }
    if (blend == 1) {
        const clip: f32 = if (ma.clip > 0) ma.clip else 0.33333334;
        return if (a >= clip) 1 else 0;
    }
    return if (a < 1) (if (a > 0) a else 0) else 1;
}

/// hive.trace, but rays go on through what lets them; t stays measured from
/// the ray's origin. r: anything with f() -> 0..1.
pub fn walk(o0: m.V3, d: m.V3, tmax0: f32, r: anytype) ?hive.Hit {
    if (!hive.cut) return hive.trace(o0, d, tmax0);
    var o = o0;
    var tmax = tmax0;
    var gone: f32 = 0;
    var layers: u32 = 32;
    while (true) {
        var h = hive.trace(o, d, tmax) orelse return null;
        layers -= 1;
        var stop = layers == 0;
        if (!stop) {
            const c = cover(h, d);
            stop = c >= 0.99999994 or (c > 0 and r.f() < c);
        }
        if (stop) {
            h.t += gone;
            return h;
        }
        const step = h.t + h.t * 1.0e-5 + 1.0e-4; // on, from a little past it
        o = m.add(o, m.scale(d, step));
        gone += step;
        tmax -= step;
        if (!(tmax > 0)) return null;
    }
}

// --- Material Preview (preview.s pv_graph) ---------------------------------------------

/// An object whose material has a graph, as the preview's rows need it.
pub const PvObj = struct { ma: *const Material, me: *const @import("scene.zig").Mesh, mtx: m.M4 };

/// The vertex colour under a preview pixel; null: none there.
pub fn previewVcol(me: *const @import("scene.zig").Mesh, mtx: m.M4, ti: u32, eye: m.V3, ray: m.V3) ?m.V3 {
    if (!vcol.has(me) or ti >= me.tris.len) return null;
    const t3 = me.tris[ti];
    const a = m.xform(mtx, me.verts[t3[0]]);
    const e1 = m.sub(m.xform(mtx, me.verts[t3[1]]), a);
    const e2 = m.sub(m.xform(mtx, me.verts[t3[2]]), a);
    const b = rayBary(a, e1, e2, eye, ray) orelse return null;
    return vcol.lin(me, ti, b[0], b[1]);
}

/// The ray's point on triangle ti: (u, v), null when it runs along it.
fn rayBary(a: m.V3, e1: m.V3, e2: m.V3, o: m.V3, d: m.V3) ?[2]f32 {
    const p = m.cross(d, e2);
    const det = m.dot(e1, p);
    if (!(@abs(det) > 1e-20)) return null;
    const k = 1 / det;
    const s = m.sub(o, a);
    const q = m.cross(s, e1);
    return .{ m.dot(s, p) * k, m.dot(d, q) * k };
}

/// The material's graph at a pixel: the results in `out`, the normal bent, the
/// occlusion returned. n: world, towards the eye; ray: from the eye to wp.
pub fn previewPixel(g: *const PvObj, ti: u32, eye: m.V3, ray: m.V3, wp: m.V3, n: *m.V3, v: m.V3, out: *Material) f32 {
    sg.copyValues(out, g.ma);
    const me = g.me;
    if (ti >= me.tris.len) return 1;
    const t3 = me.tris[ti];
    const a = m.xform(g.mtx, me.verts[t3[0]]);
    const e1 = m.sub(m.xform(g.mtx, me.verts[t3[1]]), a);
    const e2 = m.sub(m.xform(g.mtx, me.verts[t3[2]]), a);
    const b = rayBary(a, e1, e2, eye, ray) orelse return 1;
    return previewGraph(g, ti, b[0], b[1], e1, e2, wp, n, v, out);
}

/// preview.s pv_graph: the graph at the point (u, v) of triangle ti; pu, pv its
/// edges in world space, wp the point, n the normal (bent, when the graph
/// drives it), wv towards the eye. The results in `out`, the occlusion returned.
pub fn previewGraph(g: *const PvObj, ti: u32, u: f32, v: f32, pu: m.V3, pv: m.V3, wp: m.V3, n: *m.V3, wv: m.V3, out: *Material) f32 {
    sg.copyValues(out, g.ma);
    const me = g.me;
    if (ti >= me.tris.len) return 1;
    const t3 = me.tris[ti];
    const p0 = me.verts[t3[0]];
    var sc = sg.SC{
        .p0o = p0,
        .e1o = m.sub(me.verts[t3[1]], p0),
        .e2o = m.sub(me.verts[t3[2]], p0),
        .u = u,
        .v = v,
        .pu = pu,
        .pv = pv,
        .n = n.*,
        .wp = wp,
        .wv = wv,
    };
    const uv = @import("bake.zig").triUvs(me, ti);
    if (uv) |*x| sc.uvp = x;
    const vc = vcol.lin(me, ti, u, v);
    if (vc) |c| sc.vc = c;
    _ = sg.shade(g.ma, material.list[0..material.count], &sc, out, false);
    if (sc.flags & (1 << sg.PIN_NORMAL) != 0) n.* = sc.n;
    if (sc.flags & sg.SCF_VCOL == 0) {
        if (vc) |c| {
            for (0..3) |k| out.base[k] *= c[k];
        }
    }
    return if (sc.flags & (1 << sg.PIN_AO) != 0) sg.rtAo(out) else 1;
}

test "the point on a triangle from a ray" {
    const a: m.V3 = .{ 1, 0, 0 };
    const e1: m.V3 = .{ 2, 0, 0 };
    const e2: m.V3 = .{ 0, 2, 0 };
    const b = rayBary(a, e1, e2, .{ 1.5, 0.5, 4 }, .{ 0, 0, -1 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), b[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), b[1], 1e-6);
    // along the triangle: none
    try std.testing.expect(rayBary(a, e1, e2, .{ 0, 0, 0 }, .{ 1, 0, 0 }) == null);
}
