// Measuring (measure.s): mass properties and the measure tool.
//
// massProps integrates over an object's triangles in world space (its
// transform included): surface area, the volume as a sum of signed tetrahedra
// from the origin, and the centre of mass as their volume-weighted centroids.
// Mass = volume x the material's density (g/cm^3; no material: 1). Results are
// in scene units (cad.zig): lengths, units^2, units^3, grams.
//
// The measure tool (view.measure, Shift+M) takes clicks in the viewport,
// snapped to the nearest mesh vertex on screen or else the surface / ground
// under the pointer: two points give a distance, a third the angle at the
// middle one. Esc or a right click ends it.
const std = @import("std");
const app = @import("app.zig");
const scene = @import("scene.zig");
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const vp = @import("viewport.zig");
const cad = @import("cad.zig");
const material = @import("material.zig");

pub const Props = struct {
    area: f64 = 0,
    vol: f64 = 0,
    cen: [3]f64 = .{ 0, 0, 0 },
    mass: f64 = 0,
};

/// obj_matrix: the object's matrix as the original computes it (fsincos of the
/// angles in radians, f32 products in its order); a child's from its world
/// transform as the port keeps it.
pub fn objMatrix(i: usize) m.M4 {
    const o = &scene.objects[i];
    if (o.parent != null) return scene.world(i);
    const ax = @import("animexpr.zig");
    const x = ax.sincos32(o.rot[0] * m.deg);
    const y = ax.sincos32(o.rot[1] * m.deg);
    const z = ax.sincos32(o.rot[2] * m.deg);
    const sx = x[0];
    const cx = x[1];
    const sy = y[0];
    const cy = y[1];
    const sz = z[0];
    const cz = z[1];
    var r: m.M4 = .{
        cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx, o.loc[0],
        sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx, o.loc[1],
        0 - sy,  cy * sx,                cy * cx,                o.loc[2],
        0,       0,                      0,                      1,
    };
    for (0..3) |row| {
        for (0..3) |c| r[row * 4 + c] = o.scl[c] * r[row * 4 + c];
    }
    return r;
}

/// mass_props: object i's, null when it is no mesh.
pub fn massProps(i: usize) ?Props {
    const o = &scene.objects[i];
    if (!o.kind.isMesh()) return null;
    const me = scene.meshOfObj(i) orelse return null;
    const w = objMatrix(i);
    var area: f64 = 0;
    var v6: f64 = 0;
    var cs: [3]f64 = .{ 0, 0, 0 };
    for (me.tris) |t| {
        var p: [3][3]f64 = undefined;
        for (0..3) |k| {
            const q = m.xform(w, me.verts[t[k]]);
            p[k] = .{ q[0], q[1], q[2] };
        }
        const e1 = [3]f64{ p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2] };
        const e2 = [3]f64{ p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2] };
        const n = [3]f64{
            e1[1] * e2[2] - e1[2] * e2[1],
            e1[2] * e2[0] - e1[0] * e2[2],
            e1[0] * e2[1] - e1[1] * e2[0],
        };
        area = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]) * 0.5 + area;
        const six = n[0] * p[0][0] + n[1] * p[0][1] + n[2] * p[0][2]; // a . (b x c)
        v6 = v6 + six;
        for (0..3) |c| cs[c] = (p[0][c] + p[1][c] + p[2][c]) * six + cs[c];
    }
    var r = Props{ .area = area, .vol = v6 * 0.16666666666666666 };
    if (@abs(v6) > 1.0e-30) {
        const d = (v6 + v6) + (v6 + v6);
        for (0..3) |c| r.cen[c] = cs[c] / d;
    }
    var dens: f32 = 1;
    if (material.of(o)) |ma| {
        if (ma.density > 0) dens = ma.density;
    }
    const u = cad.unitMm() / 10.0; // mass = |V| (mm/unit / 10)^3 cm^3 x density
    r.mass = @abs(r.vol) * (u * u * u) * @as(f64, dens);
    return r;
}

/// fmt_unit: " mm" (the scene unit's name, or " units").
fn unitW() []const u8 {
    return cad.unitName() orelse "units";
}

fn val3(w: *std.Io.Writer, v: f64) void {
    var b: [32]u8 = undefined;
    w.writeAll(cad.fmtVal3(&b, @floatCast(v))) catch {};
}

/// fmt_props: "  Name: volume 1 m^3, area 6 m^2, mass 1000 kg, centre 0, 1, 0 m".
pub fn fmtProps(buf: []u8, name: []const u8, p: *const Props) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("  {s}: volume ", .{name}) catch {};
    val3(&w, p.vol);
    w.print(" {s}^3, area ", .{unitW()}) catch {};
    val3(&w, p.area);
    w.print(" {s}^2, mass ", .{unitW()}) catch {};
    const kg = p.mass >= 1000.0;
    val3(&w, if (kg) p.mass / 1000.0 else p.mass);
    w.writeAll(if (kg) " kg" else " g") catch {};
    w.writeAll(", centre ") catch {};
    for (0..3) |c| {
        if (c > 0) w.writeAll(", ") catch {};
        val3(&w, p.cen[c]);
    }
    w.print(" {s}", .{unitW()}) catch {};
    return w.buffered();
}

/// object.measure: each selected mesh (or the active one) to the console.
pub fn opObjMeasure() void {
    var n: usize = 0;
    var b: [256]u8 = undefined;
    for (0..scene.count) |i| {
        if (!scene.objects[i].selected) continue;
        const p = massProps(i) orelse continue;
        app.log("{s}", .{fmtProps(&b, scene.objects[i].name(), &p)});
        n += 1;
    }
    if (n > 0) return;
    if (scene.active) |a| {
        if (massProps(a)) |p| return app.log("{s}", .{fmtProps(&b, scene.objects[a].name(), &p)});
    }
    app.log("  object.measure: select a mesh", .{});
}

// ---- the CAD tab's Mass Properties button (cadui.s mass_now) -------------------------

/// The last mass properties shown, and whose (by identity).
pub var mass_text: [128]u8 = undefined;
pub var mass_len: usize = 0;
pub var mass_oid: u32 = 0;

pub fn massNow() void {
    const a = scene.active orelse return;
    const p = massProps(a) orelse return;
    var b: [256]u8 = undefined;
    const s = fmtProps(&b, scene.objects[a].name(), &p);
    const n = @min(s.len, 127); // (127 bytes, as the original's buffer)
    @memcpy(mass_text[0..n], s[0..n]);
    mass_len = n;
    mass_oid = scene.objects[a].oid;
    app.dirty = true;
}

// ---- the measure tool -------------------------------------------------------------------

pub var on = false;
pub var npts: usize = 0;
pub var pts: [3]m.V3 = undefined;

pub fn opViewMeasure() void {
    on = true;
    npts = 0;
    app.dirty = true;
}

pub fn isOn() bool {
    return on;
}

/// etool_cancel.
pub fn cancel() void {
    on = false;
    npts = 0;
    app.dirty = true;
}

/// The nearest vertex on screen within 14 px, else the surface / ground point.
fn pick(cv: *gfx.Canvas, v: *const vp.View, r: gfx.Rect, x: i32, y: i32) m.V3 {
    const c = vp.Cam.init(v, r);
    const px = @as(f32, @floatFromInt(cv.toPx(x)));
    const py = @as(f32, @floatFromInt(cv.toPx(y)));
    const sc: f32 = @as(f32, @floatFromInt(cv.toPx(1000))) / 1000.0;
    var best: f32 = 196.0; // 14 px
    var hit: ?m.V3 = null;
    for (0..scene.count) |i| {
        const o = &scene.objects[i];
        if (!o.kind.isMesh()) continue;
        const me = scene.meshOfObj(i) orelse continue;
        const w = objMatrix(i);
        for (me.verts) |p0| {
            const p = m.xform(w, p0);
            const vv = c.toView(p);
            if (!(vv[2] > 0)) continue;
            const s = c.screen(vv);
            const dx = s[0] * sc - px;
            const dy = s[1] * sc - py;
            const d = dx * dx + dy * dy;
            if (d < best) {
                best = d;
                hit = p;
            }
        }
    }
    if (hit) |h| return h;
    return vp.surfacePoint(cv, v, r, x, y) orelse scene.cursor;
}

/// measure_press: a click, the next point (a fourth starts again).
pub fn press(cv: *gfx.Canvas, v: *const vp.View, r: gfx.Rect, x: i32, y: i32) void {
    const p = pick(cv, v, r, x, y);
    if (npts >= 3) npts = 0;
    pts[npts] = p;
    npts += 1;
    if (npts >= 2) {
        var b: [160]u8 = undefined;
        app.log("{s}", .{result(&b)});
    }
    app.dirty = true;
}

fn vec(a: usize, b: usize) [3]f64 {
    return .{
        @as(f64, pts[b][0]) - @as(f64, pts[a][0]),
        @as(f64, pts[b][1]) - @as(f64, pts[a][1]),
        @as(f64, pts[b][2]) - @as(f64, pts[a][2]),
    };
}

/// vangle: atan2(|u x v|, u . v), exact near 0 and 180.
pub fn vangle(u: [3]f64, v: [3]f64) f64 {
    const x = u[1] * v[2] - u[2] * v[1];
    const y = u[2] * v[0] - u[0] * v[2];
    const z = u[0] * v[1] - u[1] * v[0];
    const cr = @sqrt(x * x + y * y + z * z);
    const d = u[0] * v[0] + u[1] * v[1] + u[2] * v[2];
    return @import("animexpr.zig").atan2x87(cr, d);
}

/// ms_result: "  distance 12.5 mm (dx, dy, dz)" or "  angle 90 deg".
pub fn result(buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("  ") catch {};
    if (npts == 3) {
        w.writeAll("angle ") catch {};
        val3(&w, vangle(vec(1, 0), vec(1, 2)) * 57.29577951308232);
        w.writeAll(" deg") catch {};
    } else {
        const d = vec(0, 1);
        w.writeAll("distance ") catch {};
        val3(&w, @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]));
        w.print(" {s} (", .{unitW()}) catch {};
        for (0..3) |c| {
            if (c > 0) w.writeAll(", ") catch {};
            val3(&w, d[c]);
        }
        w.writeAll(")") catch {};
    }
    return w.buffered();
}

pub const Value = union(enum) { none, dist: f64, angle: f64 };

/// measure_value: the distance (two points) or the angle at the middle one (radians).
pub fn value() Value {
    if (npts < 2) return .none;
    if (npts == 2) {
        const d = vec(0, 1);
        return .{ .dist = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) };
    }
    return .{ .angle = vangle(vec(1, 0), vec(1, 2)) };
}

/// measure_draw: the points joined, a cross on each, the result in the hint line.
/// The tool's line in the view's corner (the viewport's text, Zui's): what
/// to do, or what was measured.
pub fn hint(b: *[160]u8) []const u8 {
    return if (npts >= 2) result(b)[2..] else "Measure: click points (snaps to vertices), Esc ends";
}

/// The points and the lines between them, over the view.
pub fn draw(cv: *gfx.Canvas, v: *const vp.View, r: gfx.Rect) void {
    const c = vp.Cam.init(v, r);
    const col: u32 = 0x40d0ff;
    for (0..npts) |k| {
        const p = pts[k];
        const e = c.eye;
        const dx = p[0] - e[0];
        const dy = p[1] - e[1];
        const dz = p[2] - e[2];
        const s = @sqrt(dx * dx + dy * dy + dz * dz) * 0.01; // 1% of the eye distance
        for (0..3) |ax| {
            var a = p;
            var bb = p;
            a[ax] -= s;
            bb[ax] += s;
            vp.line3(cv, &c, a, bb, col);
        }
        if (k > 0) vp.line3(cv, &c, pts[k - 1], p, col);
    }
}

test "a cube's mass properties" {
    // (the unit cube's sums, in the order the original adds them)
    const u = [3]f64{ 1, 0, 0 };
    const v = [3]f64{ 0, 1, 0 };
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi / 2.0), vangle(u, v), 1e-15);
}
