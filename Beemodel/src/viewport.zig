// The 3D viewport: orbit camera, grid, flat-shaded meshes with a depth
// buffer, selection outline, camera/light gizmos and the navigation gizmo.
const std = @import("std");
const gfx = @import("gfx.zig");
const m = @import("math.zig");
const scene = @import("scene.zig");
const theme = @import("theme.zig");
const em = @import("editmesh.zig");
const material = @import("material.zig");
const preview = @import("preview.zig");
const mods = @import("mods.zig");
const refimg = @import("refimg.zig");
const vgd = @import("vgdraw.zig");

/// The original's edit-mode colours: wires, the selection, selected faces.
const EDIT_WIRE: u32 = 0x0b0c0e;
const EDIT_SEL: u32 = 0xffa233;
const SEAM: u32 = 0xe8483c;
pub const FACE_SEL: u32 = 0xe0a060;

const Rect = gfx.Rect;

pub const View = struct {
    // the original's default view: yaw 45, pitch 0.5 rad, distance 18
    yaw: f32 = 45,
    pitch: f32 = 28.64789, // (0.5 rad, as the original keeps it: 28.64789 * deg is 0.5 exactly)
    dist: f32 = 18,
    target: m.V3 = .{ 0, 0, 0 },
    wire: bool = false,
    /// Material Preview (when not wireframe): each object's material under a studio light.
    material: bool = false,
    /// Rendered: the live path tracer over Material Preview (`material` is on too).
    rendered: bool = false,
    /// Orthographic: a very long lens from far away, as in the original.
    ortho: bool = false,
    /// Orthographic because an axis view was asked for (Numpad 1 / 3 / 7, the
    /// gizmo's balls): orbiting away goes back to perspective.
    auto_ortho: bool = false,
    /// Looking through the scene's camera.
    cam_view: bool = false,
    /// The view before Camera View (Numpad 0 again goes back to it).
    before_cam: Pose = .{},
    // overlays
    show_text: bool = true,
    show_stats: bool = false,
    show_gizmo: bool = true,
    // a glide to another view (views glide to where they go)
    glide_t0: i64 = 0,
    glide_from: Pose = .{},
    glide_to: Pose = .{},
    gliding: bool = false,
    /// The radians the yaw and pitch came as (a script's view(), a file's VIEW:
    /// the original keeps radians, and degrees do not always give them back),
    /// valid while yaw and pitch are still `rad_at`.
    rad: [2]f32 = .{ 0.7853982, 0.5 },
    rad_at: [2]f32 = .{ 45, 28.64789 },

    /// Yaw and pitch in radians, as the original holds them (cam_yaw, cam_pitch).
    pub fn radians(v: *const View) [2]f32 {
        return .{
            if (v.yaw == v.rad_at[0]) v.rad[0] else v.yaw * m.deg,
            if (v.pitch == v.rad_at[1]) v.rad[1] else v.pitch * m.deg,
        };
    }
    pub fn setRadians(v: *View, yaw: f32, pitch: f32) void {
        v.rad = .{ yaw, pitch };
        v.rad_at = .{ v.yaw, v.pitch };
    }

    pub fn pose(v: *const View) Pose {
        return .{ .yaw = v.yaw, .pitch = v.pitch, .dist = v.dist, .target = v.target };
    }
    pub fn setPose(v: *View, p: Pose) void {
        v.yaw = p.yaw;
        v.pitch = p.pitch;
        v.dist = p.dist;
        v.target = p.target;
    }
};

pub const Pose = struct { yaw: f32 = 45, pitch: f32 = 28.64789, dist: f32 = 18, target: m.V3 = .{ 0, 0, 0 } };

/// Field of view (vertical, degrees) and how far "orthographic" moves back.
pub var fov: f32 = 50;
const ORTHO_K: f32 = 80;

/// The scene's camera (the first one), if any.
pub fn sceneCamera() ?usize {
    if (scene.render_camera) |c| {
        if (c < scene.count and scene.objects[c].kind == .camera) return c;
    }
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.kind == .camera) return i;
    }
    return null;
}

pub const Cam = struct {
    eye: m.V3,
    right: m.V3,
    up: m.V3,
    fwd: m.V3,
    f: f32,
    cx: f32,
    cy: f32,

    pub fn init(v: *const View, r: Rect) Cam {
        const fh: f32 = @floatFromInt(r.h);
        const cx = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) * 0.5;
        const cy = @as(f32, @floatFromInt(r.y)) + fh * 0.5;
        // (the original's default is the rounded 0.5 / tan(fov / 2): vp_focal_k)
        const f0 = if (fov == 50) fh * 1.07 else (fh * 0.5) / @tan(fov * 0.5 * m.deg);
        if (v.cam_view and @import("play.zig").on == 0) { // (play mode: the player's eyes)
            if (sceneCamera()) |ci| {
                const o = &scene.objects[ci];
                const wt = scene.worldTRS(ci);
                const R = m.eulerMat(wt.rot);
                const fr = camFrame(r);
                // the camera's lens on a 36 mm wide sensor across the frame
                const ff = @as(f32, @floatFromInt(fr.w)) * o.lens / 36.0;
                return .{
                    .eye = wt.loc,
                    .right = m.norm(.{ R[0], R[3], R[6] }),
                    .up = m.norm(.{ R[1], R[4], R[7] }),
                    .fwd = m.norm(.{ -R[2], -R[5], -R[8] }),
                    .f = ff,
                    .cx = cx,
                    .cy = cy,
                };
            }
        }
        const cp = @cos(v.pitch * m.deg);
        const off: m.V3 = .{ cp * @sin(v.yaw * m.deg), @sin(v.pitch * m.deg), cp * @cos(v.yaw * m.deg) };
        const k: f32 = if (v.ortho) ORTHO_K else 1;
        const eye = m.add(v.target, m.scale(off, v.dist * k));
        const fwd = m.scale(off, -1);
        var right = m.cross(fwd, .{ 0, 1, 0 });
        if (m.len(right) < 1e-4) right = .{ @cos(v.yaw * m.deg), 0, -@sin(v.yaw * m.deg) };
        right = m.norm(right);
        const up = m.cross(right, fwd);
        // play mode: turned into the player's frame (walking round a planet; pl_basis)
        const pl = @import("play.zig");
        if (pl.basis(right)) |br| {
            const bf = pl.basis(fwd).?;
            return .{ .eye = m.sub(v.target, m.scale(bf, v.dist * k)), .right = br, .up = pl.basis(up).?, .fwd = bf, .f = f0 * k, .cx = cx, .cy = cy };
        }
        return .{ .eye = eye, .right = right, .up = up, .fwd = fwd, .f = f0 * k, .cx = cx, .cy = cy };
    }

    /// World -> view space (x right, y up, z forward/depth).
    pub fn toView(c: *const Cam, p: m.V3) m.V3 {
        const d = m.sub(p, c.eye);
        return .{ m.dot(d, c.right), m.dot(d, c.up), m.dot(d, c.fwd) };
    }

    pub fn screen(c: *const Cam, v: m.V3) [3]f32 {
        return .{ c.cx + v[0] / v[2] * c.f, c.cy - v[1] / v[2] * c.f, v[2] };
    }

    /// A point's pixel (icons, dots, picking): a point far off the view is
    /// held at +-30000 on each axis (still off it). Not for the ends of a
    /// line or an edge: that bends them (projectF, segment).
    pub fn project(c: *const Cam, p: m.V3) ?[2]i32 {
        const v = c.toView(p);
        if (v[2] < near) return null;
        const s = c.screen(v);
        return .{ @intFromFloat(std.math.clamp(s[0], -30000, 30000)), @intFromFloat(std.math.clamp(s[1], -30000, 30000)) };
    }

    /// A point's screen spot, unclamped (directions between points stay true).
    pub fn projectF(c: *const Cam, p: m.V3) ?[2]f32 {
        const v = c.toView(p);
        if (v[2] < near) return null;
        const s = c.screen(v);
        return .{ s[0], s[1] };
    }

    /// World-space size of one pixel at the depth of p.
    pub fn pixelSize(c: *const Cam, p: m.V3) f32 {
        return @max(near, c.toView(p)[2]) / c.f;
    }
};

/// The clip start (Preferences > Viewport).
pub var near: f32 = 0.05;
// scratch space for a mesh's transformed vertices (grows with the largest mesh)
var wv_buf: []m.V3 = &.{};
var vv_buf: []m.V3 = &.{};

fn scratch(n: usize) bool {
    if (wv_buf.len >= n) return true;
    const a = std.heap.page_allocator;
    if (wv_buf.len > 0) {
        a.free(wv_buf);
        a.free(vv_buf);
    }
    const cap = @max(n, 4096);
    wv_buf = a.alloc(m.V3, cap) catch {
        wv_buf = &.{};
        return false;
    };
    vv_buf = a.alloc(m.V3, cap) catch {
        a.free(wv_buf);
        wv_buf = &.{};
        return false;
    };
    return true;
}

/// Whether an object's bounds (object space, through mtx) are wholly in front
/// of the near plane. Only then may a closed mesh's back faces be skipped: the
/// original draws every face (raster.s), and with the eye inside the mesh or
/// the near plane through it, the back faces are what shows.
pub fn boxInFront(c: *const Cam, mtx: m.M4, lo: m.V3, hi: m.V3) bool {
    for (0..8) |k| {
        const p: m.V3 = .{ if (k & 1 != 0) hi[0] else lo[0], if (k & 2 != 0) hi[1] else lo[1], if (k & 4 != 0) hi[2] else lo[2] };
        if (!(c.toView(m.xform(mtx, p))[2] >= near)) return false;
    }
    return true;
}

/// Whether an object's bounds (object space, through mtx) can be in view:
/// not all behind the eye, not all off one side of the viewport.
fn boxVisible(c: *const Cam, r: Rect, mtx: m.M4, lo: m.V3, hi: m.V3) bool {
    var behind: usize = 0;
    var left: usize = 0;
    var right: usize = 0;
    var above: usize = 0;
    var below: usize = 0;
    const x0: f32 = @floatFromInt(r.x);
    const x1: f32 = @floatFromInt(r.right());
    const y0: f32 = @floatFromInt(r.y);
    const y1: f32 = @floatFromInt(r.bottom());
    for (0..8) |k| {
        const p: m.V3 = .{ if (k & 1 != 0) hi[0] else lo[0], if (k & 2 != 0) hi[1] else lo[1], if (k & 4 != 0) hi[2] else lo[2] };
        const v = c.toView(m.xform(mtx, p));
        if (v[2] < near) {
            behind += 1;
            continue;
        }
        const s = c.screen(v);
        if (s[0] < x0) left += 1;
        if (s[0] > x1) right += 1;
        if (s[1] < y0) above += 1;
        if (s[1] > y1) below += 1;
    }
    if (behind == 8) return false;
    if (behind > 0) return true; // crosses the eye's plane: keep it
    return !(left == 8 or right == 8 or above == 8 or below == 8);
}

/// A view-space point in front of the near plane on screen: x, y and 1 / depth,
/// as the original's emit_vert: not clamped, so a corner far off the view (an
/// edge cut by the near plane) keeps its place and the edges their directions;
/// the rasterizer takes its bounds within the clip in floats.
pub inline fn scr(c: *const Cam, p: m.V3) [3]f32 {
    const s = c.screen(p);
    return .{ s[0], s[1], 1.0 / p[2] };
}

/// Where the edge from a (in front of the near plane) to b (behind it) meets
/// the plane, as the parameter s along a -> b and the point (z exactly the
/// plane, as the original's clip_edge). Measured from the end in front: from a
/// far end behind the eye (an edge thousands of units long) the difference
/// would cancel to a depth of 0, a corner at infinity.
pub fn cutNear(a: m.V3, b: m.V3) struct { s: f32, p: m.V3 } {
    const s = (near - a[2]) / (b[2] - a[2]);
    var p = m.add(a, m.scale(m.sub(b, a), s));
    p[2] = near;
    return .{ .s = s, .p = p };
}

/// The original's line3d: the part of a -> b (screen floats) inside the clip
/// rect, Liang-Barsky (left, right, top, bottom; the last column and row
/// inclusive), as the parameters (t0, t1) of its ends; null: none of it.
pub fn clipSeg(cl: Rect, ax: f32, ay: f32, bx: f32, by: f32) ?[2]f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const ps = [4]f32{ -dx, dx, -dy, dy };
    const qs = [4]f32{
        ax - @as(f32, @floatFromInt(cl.x)),
        @as(f32, @floatFromInt(cl.right() - 1)) - ax,
        ay - @as(f32, @floatFromInt(cl.y)),
        @as(f32, @floatFromInt(cl.bottom() - 1)) - ay,
    };
    var t0: f32 = 0;
    var t1: f32 = 1;
    for (ps, qs) |p, q| {
        if (p == 0) {
            if (q < 0) return null; // parallel, outside
            continue;
        }
        const r = q / p;
        if (p < 0) t0 = @max(t0, r) else t1 = @min(t1, r);
        if (!(t0 <= t1)) return null;
    }
    return .{ t0, t1 };
}

/// cvtss2si: the nearest integer, ties to even.
fn rne(x: f32) i32 {
    var r = @round(x);
    if (@abs(r - x) == 0.5 and @mod(r, 2.0) != 0) r -= std.math.sign(x);
    return @intFromFloat(r);
}

/// A line between two screen points (x, y, 1 / depth), any distance off the
/// view: cut to the clip rect first (clipSeg), so its direction stays; the
/// ends rounded as the original's. depth: tested against the depth buffer.
pub fn segment(cv: *gfx.Canvas, a: [3]f32, b: [3]f32, col: u32, depth: bool) void {
    if (!(@abs(a[0]) < 1e30 and @abs(a[1]) < 1e30 and @abs(b[0]) < 1e30 and @abs(b[1]) < 1e30)) return;
    const t = clipSeg(cv.clip, a[0], a[1], b[0], b[1]) orelse return;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const x0 = a[0] + t[0] * dx;
    const y0 = a[1] + t[0] * dy;
    const x1 = a[0] + t[1] * dx;
    const y1 = a[1] + t[1] * dy;
    if (depth and cv.zbuf != null) {
        const dz = b[2] - a[2];
        cv.lineDepth(x0, y0, a[2] + t[0] * dz, x1, y1, a[2] + t[1] * dz, col);
    } else cv.line(rne(x0), rne(y0), rne(x1), rne(y1), col);
}

/// A view-space triangle, clipped against the near plane (0, 1 or 2
/// triangles), then rasterized with inverse depth.
pub fn clipTri(cv: *gfx.Canvas, c: *const Cam, t: [3]m.V3, col: u32, id: u16) void {
    var poly: [4]m.V3 = undefined;
    var n: usize = 0;
    for (0..3) |k| {
        const a = t[k];
        const b = t[(k + 1) % 3];
        const ain = a[2] >= near;
        const bin = b[2] >= near;
        if (ain) {
            poly[n] = a;
            n += 1;
        }
        if (ain != bin) {
            poly[n] = if (ain) cutNear(a, b).p else cutNear(b, a).p;
            n += 1;
        }
    }
    if (n < 3) return;
    var sp: [4][3]f32 = undefined;
    for (poly[0..n], 0..) |p, k| sp[k] = scr(c, p);
    cv.triangle(sp[0], sp[1], sp[2], col, id);
    if (n == 4) cv.triangle(sp[0], sp[2], sp[3], col, id);
}

/// clipTri with world normals at the corners (Material Preview): the near
/// plane's cut corners get theirs interpolated.
pub fn clipTriN(cv: *gfx.Canvas, c: *const Cam, t: [3]m.V3, tn: [3]m.V3, col: u32, id: u16) void {
    var poly: [4]m.V3 = undefined;
    var pn: [4]m.V3 = undefined;
    var n: usize = 0;
    for (0..3) |k| {
        const a = t[k];
        const b = t[(k + 1) % 3];
        const ain = a[2] >= near;
        const bin = b[2] >= near;
        if (ain) {
            poly[n] = a;
            pn[n] = tn[k];
            n += 1;
        }
        if (ain != bin) {
            const na = tn[k];
            const nb = tn[(k + 1) % 3];
            const q = if (ain) cutNear(a, b) else cutNear(b, a);
            poly[n] = q.p;
            pn[n] = if (ain) m.add(na, m.scale(m.sub(nb, na), q.s)) else m.add(nb, m.scale(m.sub(na, nb), q.s));
            n += 1;
        }
    }
    if (n < 3) return;
    var sp: [4][3]f32 = undefined;
    for (poly[0..n], 0..) |p, k| sp[k] = scr(c, p);
    const nb = preview.nbuf.ptr;
    cv.triangleN(sp[0], sp[1], sp[2], .{ pn[0], pn[1], pn[2] }, col, id, nb);
    if (n == 4) cv.triangleN(sp[0], sp[2], sp[3], .{ pn[0], pn[2], pn[3] }, col, id, nb);
}

/// A line between two view-space points, clipped at the near plane.
pub fn viewLine(cv: *gfx.Canvas, c: *const Cam, a0: m.V3, b0: m.V3, col: u32) void {
    var a = a0;
    var b = b0;
    if (a[2] < near and b[2] < near) return;
    if (a[2] < near) a = cutNear(b, a).p else if (b[2] < near) b = cutNear(a, b).p;
    segment(cv, scr(c, a), scr(c, b), col, false);
}

pub fn line3(cv: *gfx.Canvas, c: *const Cam, a: m.V3, b: m.V3, col: u32) void {
    var va = c.toView(a);
    var vb = c.toView(b);
    if (va[2] < near and vb[2] < near) return;
    if (va[2] < near) va = cutNear(vb, va).p else if (vb[2] < near) vb = cutNear(va, vb).p;
    segment(cv, scr(c, va), scr(c, vb), col, false);
}

/// Render aspect (Render Settings: 1920 x 1080 until they are ported).
pub var render_w: f32 = 1920;
pub var render_h: f32 = 1080;

/// The camera's frame inside viewport r (camera view).
pub fn camFrame(r: Rect) Rect {
    const aspect = render_w / render_h;
    var fh: f32 = @as(f32, @floatFromInt(r.h)) * 0.86;
    var fw = fh * aspect;
    const maxw: f32 = @as(f32, @floatFromInt(r.w)) * 0.92;
    if (fw > maxw) {
        fw = maxw;
        fh = fw / aspect;
    }
    const w: i32 = @intFromFloat(fw);
    const h: i32 = @intFromFloat(fh);
    return .{ .x = r.x + @divTrunc(r.w - w, 2), .y = r.y + @divTrunc(r.h - h, 2), .w = w, .h = h };
}

/// Leave camera view where the camera stands (orbit, pan or zoom from there).
pub fn leaveCamView(v: *View) void {
    if (!v.cam_view) return;
    v.cam_view = false;
    const ci = sceneCamera() orelse return;
    const wt = scene.worldTRS(ci);
    const R = m.eulerMat(wt.rot);
    const fwd = m.norm(.{ -R[2], -R[5], -R[8] });
    const off = m.scale(fwd, -1);
    v.pitch = std.math.clamp(std.math.asin(std.math.clamp(off[1], -1.0, 1.0)) / m.deg, -89.9, 89.9);
    v.yaw = std.math.atan2(off[0], off[2]) / m.deg;
    v.dist = 10;
    v.ortho = false;
    v.target = m.add(wt.loc, m.scale(fwd, v.dist));
}

// --- the image cache ---------------------------------------------------------
//
// Moving the mouse over the window redraws it, but the 3D view only changes
// when the scene, the view or the theme do: a viewport keeps its last image
// (pixels, depth and object ids) with a hash of everything it shows, and
// copies it back when nothing changed.

const Cached = struct {
    key: u64 = 0,
    /// the key of the last frame: saved once two frames in a row agree
    /// (while orbiting nothing is saved)
    last: u64 = 0,
    r: Rect = .{},
    canvas_w: i32 = 0,
    px: []u32 = &.{},
    zb: []f32 = &.{},
    ids: []u16 = &.{},
};
var caches: [8]Cached = @splat(.{});
var cache_next: usize = 0;
pub var cache_hits: usize = 0;
/// Off: always render (benchmarks measure the rasterizer, not the copy).
pub var cache_enabled = true;

fn stateKey(r: Rect, v: *const View, th: *const theme.Theme, cw: i32) u64 {
    var h = std.hash.Wyhash.init(0x6265656d);
    h.update(std.mem.asBytes(&r));
    h.update(std.mem.asBytes(&cw));
    h.update(std.mem.asBytes(&v.yaw));
    h.update(std.mem.asBytes(&v.pitch));
    h.update(std.mem.asBytes(&v.dist));
    h.update(std.mem.asBytes(&v.target));
    const flags = [_]bool{ v.wire, v.material, v.rendered, v.ortho, v.cam_view, v.show_gizmo, scene.show_grid };
    h.update(std.mem.asBytes(&flags));
    h.update(std.mem.asBytes(&fov));
    h.update(std.mem.asBytes(&near));
    h.update(std.mem.asBytes(&render_w));
    h.update(std.mem.asBytes(&render_h));
    h.update(std.mem.asBytes(th));
    h.update(std.mem.asBytes(&scene.cursor));
    {
        // the world lights Material Preview
        const env = @import("env.zig");
        const images = @import("images.zig");
        const world = [4]u32{ env.idx, @bitCast(env.strength), @bitCast(env.rotation), if (env.idx > 0 and env.idx <= images.count) images.list[env.idx - 1].version else 0 };
        h.update(std.mem.asBytes(&world));
    }
    h.update(std.mem.asBytes(&scene.count));
    h.update(std.mem.asBytes(&scene.active));
    h.update(std.mem.asBytes(&scene.render_camera));
    const es = [_]u32{ @intFromBool(em.active), @intCast(em.obj), em.version, @intFromEnum(em.sel_mode), material.version };
    h.update(std.mem.asBytes(&es));
    h.update(std.mem.asBytes(&@import("probe.zig").version));
    h.update(std.mem.asBytes(&@import("fields.zig").stateWord()));
    h.update(std.mem.asBytes(&@import("play.zig").stateWord()));
    h.update(std.mem.asBytes(&@import("cosync.zig").stateWord())); // (the other peers drawn)
    h.update(std.mem.asBytes(&@import("cloth.zig").stateWord())); // (a simulated cloth moved)
    h.update(std.mem.asBytes(&@import("particles.zig").stateWord())); // (the particles moved)
    h.update(std.mem.asBytes(&@import("inst.zig").ver)); // (instances moved: rigid bodies)
    h.update(std.mem.asBytes(&vgd.stateWord()));
    h.update(std.mem.asBytes(&@import("world.zig").stateWord())); // (cells in and out, the minimap)
    h.update(std.mem.asBytes(&@import("vc.zig").stateWord())); // (versions: the diff, the merge panel)
    { // an AI proposal's banner: its state and title (copilot.zig)
        const cp = @import("copilot.zig");
        h.update(std.mem.asBytes(&cp.state));
        h.update(cp.title());
    }
    {
        const mo = @import("motion.zig");
        const w = mo.stateWord();
        h.update(std.mem.asBytes(&w));
        if (mo.n_paths > 0) h.update(std.mem.asBytes(&@import("anim.zig").frame));
    }
    h.update(std.mem.asBytes(&@import("analysis.zig").stateWord()));
    // the CAD document (its units, its parameters: Show Thin Walls' minimum in
    // scene units; an edit, an undo or a load bumps it)
    h.update(std.mem.asBytes(&@import("cad.zig").version));
    h.update(std.mem.asBytes(&@import("sculpt.zig").stateWord()));
    h.update(std.mem.asBytes(&@import("paint.zig").stateWord()));
    h.update(std.mem.asBytes(&@import("wpaint.zig").bone));
    h.update(std.mem.asBytes(&@import("curve.zig").stateWord())); // (curve edit mode: its points)
    for (scene.objects[0..scene.count]) |*o| {
        h.update(&o.name_buf);
        h.update(std.mem.asBytes(&o.kind));
        h.update(std.mem.asBytes(&o.loc));
        h.update(std.mem.asBytes(&o.rot));
        h.update(std.mem.asBytes(&o.scl));
        h.update(std.mem.asBytes(&o.color));
        h.update(std.mem.asBytes(&o.mat));
        h.update(std.mem.asBytes(&o.parent));
        h.update(std.mem.asBytes(&o.mesh));
        // (the same slot, other UVs: the UV editor's transforms)
        if (o.mesh) |mi| {
            if (scene.meshes[mi]) |*me| {
                h.update(std.mem.asBytes(&me.serial));
                // (vertices changed in place, as an undone stroke's: refreshMesh stamps them)
                h.update(std.mem.asBytes(&me.shape));
            }
        }
        if (o.mods.n > 0 or (o.mesh != null and scene.meshes[o.mesh.?] != null and scene.meshes[o.mesh.?].?.sk != null)) {
            // (what it shows: evaluated when something changed)
            const i_: usize = (@intFromPtr(o) - @intFromPtr(&scene.objects[0])) / @sizeOf(scene.Object);
            if (mods.of(i_)) |me| {
                h.update(std.mem.asBytes(&me.serial));
                h.update(std.mem.asBytes(&me.shape));
            }
        }
        const lf = [_]f32{ o.size, o.cone, o.lens, @floatFromInt(@intFromEnum(o.light_type)) };
        h.update(std.mem.asBytes(&lf));
        const of = [_]bool{ o.visible, o.selected };
        h.update(std.mem.asBytes(&of));
        h.update(std.mem.asBytes(&o.ref));
    }
    return h.final();
}

fn cacheFor(r: Rect) *Cached {
    for (&caches) |*c| {
        if (c.r.x == r.x and c.r.y == r.y and c.r.w == r.w and c.r.h == r.h) return c;
    }
    const c = &caches[cache_next % caches.len];
    cache_next += 1;
    if (c.px.len > 0) {
        // another area had it: let its memory go
        const a = std.heap.page_allocator;
        a.free(c.px);
        a.free(c.zb);
        a.free(c.ids);
        c.px = &.{};
        c.zb = &.{};
        c.ids = &.{};
    }
    c.key = 0;
    c.last = 0;
    return c;
}

fn copyRect(cv: *gfx.Canvas, r: Rect, c: *Cached, save: bool) bool {
    const n: usize = @intCast(r.w * r.h);
    if (save and c.px.len < n) {
        const a = std.heap.page_allocator;
        if (c.px.len > 0) {
            a.free(c.px);
            a.free(c.zb);
            a.free(c.ids);
        }
        c.px = a.alloc(u32, n) catch return false;
        c.zb = a.alloc(f32, n) catch return false;
        c.ids = a.alloc(u16, n) catch return false;
    }
    const zb = cv.zbuf orelse return false;
    const ids = cv.ids orelse return false;
    const w: usize = @intCast(r.w);
    var y: usize = 0;
    while (y < r.h) : (y += 1) {
        const o: usize = @intCast((r.y + @as(i32, @intCast(y))) * cv.w + r.x);
        const so = y * w;
        if (save) {
            @memcpy(c.px[so .. so + w], cv.px[o .. o + w]);
            @memcpy(c.zb[so .. so + w], zb[o .. o + w]);
            @memcpy(c.ids[so .. so + w], ids[o .. o + w]);
        } else {
            @memcpy(cv.px[o .. o + w], c.px[so .. so + w]);
            @memcpy(zb[o .. o + w], c.zb[so .. so + w]);
            @memcpy(ids[o .. o + w], c.ids[so .. so + w]);
        }
    }
    return true;
}

/// The canvas and rectangle in the UI's units, for what keeps its size on
/// screen over the 3D view (the gizmo, the axes).
var ui_cv: *gfx.Canvas = undefined;
var ui_r: Rect = .{};

/// A viewport has been drawn (the original's camera globals - fwd, used by
/// object.add_reference - are set only then: zero before, as in --eval).
pub var drawn = false;

pub fn render(cv0: *gfx.Canvas, r00: Rect, v: *const View, th: *const theme.Theme) void {
    drawn = true;
    if (!cv0.enabled) return;
    ui_cv = cv0;
    ui_r = r00;
    // the 3D view is drawn in the buffer's pixels, whatever the UI's scale
    var pc = cv0.pixels();
    const cv = &pc;
    const r0 = cv0.pxRect(r00);
    // only what is on the canvas (a panel can hang off the window)
    const r = r0.intersect(cv.clip).intersect(cv.full());
    if (r.w <= 0 or r.h <= 0) return;
    const key = stateKey(r0, v, th, cv.w) ^ @as(u64, @bitCast(@as(i64, r.x) << 40 | @as(i64, r.y) << 20 | r.w));
    // Rendered: the base is what gets cached (the refining image and the
    // overlays over it are drawn every frame)
    const live_view = v.rendered and !v.wire;
    const c = cacheFor(r);
    if (cache_enabled and c.key == key and c.canvas_w == cv.w and c.px.len >= @as(usize, @intCast(r.w * r.h))) {
        if (copyRect(cv, r, c, false)) {
            cache_hits += 1;
            if (live_view) liveOver(cv, r0, r, v, th);
            return;
        }
    }
    if (live_view) renderBase(cv, r0, v, th) else renderNow(cv, r0, v, th);
    if (cache_enabled and c.last == key) {
        if (copyRect(cv, r, c, true)) {
            c.key = key;
            c.r = r;
            c.canvas_w = cv.w;
        }
    }
    c.last = key;
    c.r = r;
    if (live_view) liveOver(cv, r0, r, v, th);
}

/// The area being drawn (set by the editor: the live view has one owner).
pub var draw_area: i16 = -1;

fn liveOver(cv: *gfx.Canvas, r0: Rect, r: Rect, v: *const View, th: *const theme.Theme) void {
    const c = Cam.init(v, r0);
    @import("live.zig").shade(cv, r0, r, &c, draw_area);
    {
        const old = cv.setClip(r0);
        defer cv.clip = old;
        refimg.draw(cv, &c, v.ortho, false, th.selected);
    }
    renderOver(cv, r0, v, th);
}

fn renderNow(cv: *gfx.Canvas, r: Rect, v: *const View, th: *const theme.Theme) void {
    renderBase(cv, r, v, th);
    renderOver(cv, r, v, th);
}

const SkyFill = struct { cv: *gfx.Canvas, r: Rect, c: *const Cam };

fn skyRows(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *const SkyFill = @ptrCast(@alignCast(ctx));
    const r = j.r;
    const c = j.c;
    for (lo..hi) |k| {
        const y = r.y + @as(i32, @intCast(k));
        const row = j.cv.px[@intCast(y * j.cv.w + r.x)..][0..@intCast(r.w)];
        const vy = c.cy - (@as(f32, @floatFromInt(y)) + 0.5);
        const b = m.add(m.scale(c.fwd, c.f), m.scale(c.up, vy));
        for (row, 0..) |*p, x| {
            const vx = @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(x)) + 0.5 - c.cx;
            p.* = @import("pt.zig").skyPixel(m.norm(m.add(b, m.scale(c.right, vx))));
        }
    }
}

/// Rendered: the sky the samples will show, so that the view does not flash
/// between the theme's backdrop and the render's while it moves.
fn skyFill(cv: *gfx.Canvas, r0: Rect, c: *const Cam) void {
    const r = r0.intersect(cv.clip);
    if (r.w <= 0 or r.h <= 0) return;
    var j = SkyFill{ .cv = cv, .r = r, .c = c };
    @import("jobs.zig").parallelFor(@intCast(r.h), 8, &j, skyRows);
}

/// Is a triangle's flat colour not its object's? (vertex colours, the weights' heat)
pub inline fn tinted(oi: usize, me: *const scene.Mesh) bool {
    return me.vcol.len != 0 or @import("paint.zig").heatOf(oi);
}

/// Weight paint: the weights' heat on the painted object; else vertex colours tint it.
pub fn paintTint(oi: usize, me: *const scene.Mesh, ti: usize, base: u32) u32 {
    if (@import("paint.zig").heatOf(oi)) return @import("wpaint.zig").tint(mods.weightsOf(oi, me), me, ti);
    return @import("vcol.zig").avg(me, ti, base);
}

/// The grid and the meshes (with depth and object ids).
fn renderBase(cv: *gfx.Canvas, r: Rect, v: *const View, th: *const theme.Theme) void {
    const old = cv.setClip(r);
    defer cv.clip = old;
    const c = Cam.init(v, r);
    const live_view = v.rendered and !v.wire;
    if (live_view) skyFill(cv, r, &c) else cv.gradientV(r, th.canvas_top, th.canvas_bot);
    cv.clearDepth(r);

    // The Ground's fading grid; the floor grid gives way to it
    const ground = !live_view and @import("prims.zig").drawGrid(cv, &c, v, th);
    // Grid on the XZ plane (renders have none)
    // (as the original's viewport_draw: the lines, then the axes on top of
    // them, Y too: 3 units up; the Ground's grid keeps the axes)
    if (scene.show_grid and !live_view) {
        if (!ground) {
            var i: i32 = -10;
            while (i <= 10) : (i += 1) {
                if (i == 0) continue;
                const f: f32 = @floatFromInt(i);
                const col = if (@mod(i, 5) == 0) th.grid_major else th.grid;
                line3(cv, &c, .{ f, 0, -10 }, .{ f, 0, 10 }, col);
                line3(cv, &c, .{ -10, 0, f }, .{ 10, 0, f }, col);
            }
        }
        line3(cv, &c, .{ -10, 0, 0 }, .{ 10, 0, 0 }, th.axis_x);
        line3(cv, &c, .{ 0, 0, -10 }, .{ 0, 0, 10 }, th.axis_z);
        line3(cv, &c, .{ 0, 0, 0 }, .{ 0, 3, 0 }, th.axis_y);
    }

    // Meshes
    const mat_prev = !v.wire and v.material and preview.ensure(@intCast(cv.w * cv.h));
    if (mat_prev or live_view) _ = @import("env.zig").prep();
    // (reference images: under the wires; else after the meshes, by the ids)
    if (v.wire) refimg.draw(cv, &c, v.ortho, true, th.selected);
    const sculpt = @import("sculpt.zig");
    // the GPU's viewport, when it can (gview.zig)
    if (@import("gview.zig").draw(cv, r, &c, v, mat_prev)) {
        @import("sculptdraw.zig").draw(cv, r, &c); // (the sculpt mesh: its own path)
        if (!v.wire) @import("inst.zig").draw(cv, r, &c, near); // (instances: inst_draw)
        @import("partdraw.zig").draw(cv, r, &c, near); // (particles: pt_draw)
        if (!live_view) refimg.draw(cv, &c, v.ortho, false, th.selected);
        return;
    }
    // (objects with a cluster DAG: a cut of it, drawn after the others)
    vgd.begin(cv, r, &c, th, v.wire, mat_prev);
    const gr = @import("gpuraster.zig");
    const rs_all = !v.wire and !mat_prev and gr.wantedAll();
    if (rs_all) {
        gr.setCanvas(cv);
        _ = gr.begin();
    }
    // big frames: on every core (vpraster.zig), the same image
    const vr = @import("vpraster.zig");
    var all_tris: usize = 0;
    if (!v.wire and !rs_all) {
        for (scene.objects[0..scene.count], 0..) |*o, oi| {
            if (o.visible and o.mesh != null and o.ref == 0 and !sculpt.drawnApart(oi)) all_tris += if (mods.of(oi)) |me| me.tris.len else 0;
        }
    }
    const threaded = !v.wire and !rs_all and vr.wanted(all_tris);
    if (threaded) vr.begin(cv, &c, mat_prev);
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.visible or o.kind == .light or o.kind == .camera or o.kind == .armature or o.kind == .sketch) continue;
        if (o.ref != 0 and !v.wire) continue;
        if (o.isGround()) continue;
        if (vgd.owns(oi)) continue;
        if (!v.wire and sculpt.drawnApart(oi)) continue; // (the sculpt object draws itself)
        const mesh = mods.of(oi) orelse continue;
        const mtx = scene.world(oi);
        if (!boxVisible(&c, r, mtx, mesh.lo, mesh.hi)) continue; // outside the view
        if (threaded and vr.add(mesh, mtx, material.displayColor(o), @intCast(oi + 1), if (mat_prev) mods.normals(oi, mesh) else null, em.active and em.obj == oi)) continue;
        if (!scratch(mesh.verts.len)) continue;
        const wv = wv_buf[0..mesh.verts.len];
        const vv = vv_buf[0..mesh.verts.len];
        for (mesh.verts, 0..) |p, i| {
            wv[i] = m.xform(mtx, p);
            vv[i] = c.toView(wv[i]);
        }
        const act = scene.active != null and scene.active.? == oi;
        const wire_col = if (act) th.active else if (o.selected) th.selected else th.obj_wire;
        if (v.wire) {
            // every edge once (the edited mesh: drawEdit draws them)
            if (em.active and em.obj == oi) continue;
            for (mesh.edge_list) |e| viewLine(cv, &c, vv[e[0]], vv[e[1]], wire_col);
            continue;
        }
        const editing = em.active and em.obj == oi;
        const obj_col = material.displayColor(o);
        const cn: ?[][3]m.V3 = if (mat_prev) mods.normals(oi, mesh) else null;
        const nmat = preview.normalMatrix(mtx);
        const tint = tinted(oi, mesh);
        const cull = mesh.closed and boxInFront(&c, mtx, mesh.lo, mesh.hi);
        for (mesh.tris, 0..) |t, ti| {
            const a = wv[t[0]];
            const n = m.norm(m.cross(m.sub(wv[t[1]], a), m.sub(wv[t[2]], a)));
            var nn = n;
            if (m.dot(n, m.sub(a, c.eye)) >= 0) {
                // a back face: a closed mesh hides it; an open one shows its other side
                if (cull) continue;
                nn = m.scale(n, -1);
            }
            // the original's headlight (raster.s): ambient + diffuse * |n . view|
            const lit = 0.28 + 0.72 * @abs(m.dot(nn, c.fwd));
            var base = obj_col;
            const fsel = editing and mesh.serial < 0x80000000 and em.faceSelected(mesh, mesh.tri_poly[ti]);
            if (fsel) base = FACE_SEL else if (tint) base = paintTint(oi, mesh, ti, base);
            if (cn) |corner| {
                // selected faces keep their tint: no normal, the shading leaves them
                const z: m.V3 = .{ 0, 0, 0 };
                const tn: [3]m.V3 = if (fsel) .{ z, z, z } else .{ preview.xformN(nmat, corner[ti][0]), preview.xformN(nmat, corner[ti][1]), preview.xformN(nmat, corner[ti][2]) };
                gfx.cur_tri = @intCast(ti);
                clipTriN(cv, &c, .{ vv[t[0]], vv[t[1]], vv[t[2]] }, tn, gfx.shade(base, lit), @intCast(oi + 1));
            } else clipTri(cv, &c, .{ vv[t[0]], vv[t[1]], vv[t[2]] }, gfx.shade(base, lit), @intCast(oi + 1));
        }
    }

    if (threaded) vr.finish();
    if (rs_all) gr.flush(cv, r.intersect(cv.clip).intersect(cv.full()));
    vgd.finish();

    if (mat_prev) preview.pass(cv, r, c.right, c.up, c.fwd, c.f, c.cx, c.cy, c.eye);
    if (!v.wire) @import("sculptdraw.zig").draw(cv, r, &c); // the sculpt mesh: its own path
    if (!v.wire) @import("inst.zig").draw(cv, r, &c, near); // instances: splats and triangles (inst_draw)
    if (!v.wire) @import("partdraw.zig").draw(cv, r, &c, near); // particles (pt_draw; not in wireframe)
    if (!v.wire and !live_view) refimg.draw(cv, &c, v.ortho, false, th.selected);
}

/// What goes over the meshes: outlines, the edited mesh, cameras, lights, the gizmo.
fn renderOver(cv: *gfx.Canvas, r: Rect, v: *const View, th: *const theme.Theme) void {
    const old = cv.setClip(r);
    defer cv.clip = old;
    const c = Cam.init(v, r);

    // Outlines of the selected meshes (from the id buffer): orange, the active one gold
    if (!v.wire and scene.nSelected() > 0) outlines(cv, cv.clip, th);
    // Edit mode: the edited mesh's edges and vertices over everything
    if (em.active) drawEdit(cv, &c, v, th);
    if (em.active) drawSeams(cv, &c);
    // View > Analysis: the mesh checks
    @import("analysis.zig").draw(cv, &c, v);
    // onion skins, motion paths
    @import("motion.zig").draw(cv, &c);

    // World partition: the cells not loaded as boxes, the minimap (wp_draw)
    @import("world.zig").draw(cv, &c, r, line3);
    // Light probes: their boxes
    if (@import("play.zig").on == 0) @import("probe.zig").draw(cv, &c, line3); // (not while playing)

    // Armatures: their bones as wires
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.visible or o.kind != .armature) continue;
        const me = scene.meshOfObj(oi) orelse continue;
        const act = scene.active != null and scene.active.? == oi;
        const col: u32 = if (act) th.active else if (o.selected) th.selected else o.color;
        const mtx = scene.world(oi);
        for (me.edge_list) |e| line3(cv, &c, m.xform(mtx, me.verts[e[0]]), m.xform(mtx, me.verts[e[1]]), col);
    }
    @import("armedit.zig").overlay(cv, &c);
    @import("curveui.zig").overlay(cv, &c); // (curve edit mode: points, handles)

    // Sketches: their entities (selected ones coloured by their constraint
    // status, the others in their colour), unselected first (skx_draw)
    for (0..2) |pass| {
        for (scene.objects[0..scene.count], 0..) |*o, oi| {
            if (!o.visible or o.kind != .sketch or o.selected != (pass == 1)) continue;
            const L = struct {
                cv: *gfx.Canvas,
                c: *const Cam,
                fn f(l: @This(), a: m.V3, b: m.V3, col: u32) void {
                    line3(l.cv, l.c, a, b, col);
                }
            };
            @import("skobj.zig").draw(oi, if (o.selected) 0 else o.color, L{ .cv = cv, .c = &c }, L.f);
        }
    }

    // Cameras and lights
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.visible or (o.kind != .light and o.kind != .camera and o.kind != .field)) continue;
        const act = scene.active != null and scene.active.? == oi;
        const sel = o.selected;
        const col: u32 = if (act) th.active else if (sel) th.selected else th.cam_col;
        const mtx = scene.world(oi);
        if (o.kind == .camera) {
            if (v.cam_view and @import("play.zig").on == 0 and sceneCamera() == oi) continue; // looking through it
            const s: f32 = 0.6;
            const tip = m.xform(mtx, .{ 0, 0, 0 });
            const cs = [4]m.V3{
                m.xform(mtx, .{ -s, -s * 0.6, -s * 1.6 }), m.xform(mtx, .{ s, -s * 0.6, -s * 1.6 }),
                m.xform(mtx, .{ s, s * 0.6, -s * 1.6 }),   m.xform(mtx, .{ -s, s * 0.6, -s * 1.6 }),
            };
            for (0..4) |i| {
                line3(cv, &c, tip, cs[i], col);
                line3(cv, &c, cs[i], cs[(i + 1) % 4], col);
            }
            line3(cv, &c, m.xform(mtx, .{ -s * 0.4, s * 0.7, -s * 1.6 }), m.xform(mtx, .{ 0, s * 1.1, -s * 1.6 }), col);
            line3(cv, &c, m.xform(mtx, .{ s * 0.4, s * 0.7, -s * 1.6 }), m.xform(mtx, .{ 0, s * 1.1, -s * 1.6 }), col);
        } else {
            // the original's light (mesh.s prim_light): an octahedron 0.25 to a
            // corner, its wire in the object's colour (selected or active: theirs),
            // the same for every type of light (draw_objects)
            const lc: u32 = if (act) th.active else if (sel) th.selected else o.color;
            const L = 0.25;
            const ov = [6]m.V3{ .{ 0, L, 0 }, .{ L, 0, 0 }, .{ 0, 0, L }, .{ -L, 0, 0 }, .{ 0, 0, -L }, .{ 0, -L, 0 } };
            var wv: [6]m.V3 = undefined;
            for (ov, 0..) |q, k| wv[k] = m.xform(mtx, q);
            const edges = [12][2]u8{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 }, .{ 2, 3 }, .{ 3, 0 }, .{ 3, 4 }, .{ 4, 0 }, .{ 4, 1 }, .{ 5, 2 }, .{ 1, 5 }, .{ 3, 5 }, .{ 4, 5 } };
            for (edges) |e| line3(cv, &c, wv[e[0]], wv[e[1]], lc);
        }
    }

    // Force fields: their gizmos, the overlay (fields.zig fl_draw)
    @import("fields.zig").draw(cv, &c, line3, th);
    // co-editing: the other peers (cosync.zig co_draw)
    @import("cosync.zig").draw(cv, &c, line3);
    // Versions: the diff's ghosts (vc_draw; its list and the merge panel
    // after the gizmo: over it, as the original's)
    @import("vc.zig").draw(cv, &c);
    // play mode: the keys, or the question (play.zig play_hud)
    @import("play.zig").hud(cv, r.x, r.x + r.w, r.y + r.h, th);

    // Origins of the selection
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.selected or !o.visible or @import("sculpt.zig").drawnApart(oi) or @import("paint.zig").on) continue;
        if (c.project(scene.worldLoc(oi))) |p| {
            const act = scene.active != null and scene.active.? == oi;
            cv.fillCircle(p[0], p[1], 3, if (act) th.active else th.selected);
            cv.circle(p[0], p[1], 3, 0x101114);
        }
    }

    // The 3D cursor: a red and white ring with a cross
    if (c.project(scene.cursor)) |p| {
        var k: usize = 0;
        while (k < 16) : (k += 1) {
            const a0 = @as(f32, @floatFromInt(k)) * std.math.pi / 8.0;
            const a1 = a0 + std.math.pi / 8.0;
            cv.line(p[0] + @as(i32, @intFromFloat(@cos(a0) * 9)), p[1] + @as(i32, @intFromFloat(@sin(a0) * 9)), p[0] + @as(i32, @intFromFloat(@cos(a1) * 9)), p[1] + @as(i32, @intFromFloat(@sin(a1) * 9)), if (k % 2 == 0) 0xe5484d else 0xffffff);
        }
        cv.line(p[0] - 14, p[1], p[0] - 5, p[1], 0x101114);
        cv.line(p[0] + 5, p[1], p[0] + 14, p[1], 0x101114);
        cv.line(p[0], p[1] - 14, p[0], p[1] - 5, 0x101114);
        cv.line(p[0], p[1] + 5, p[0], p[1] + 14, 0x101114);
    }

    // (an AI proposal's banner is a Zui part over the view: copilot.banner)
    if (v.cam_view and @import("play.zig").on == 0 and sceneCamera() != null) {
        // the render's frame, the rest dimmed
        const fr = camFrame(r);
        cv.blend(.{ .x = r.x, .y = r.y, .w = r.w, .h = fr.y - r.y }, 0x000000, 170);
        cv.blend(.{ .x = r.x, .y = fr.bottom(), .w = r.w, .h = r.bottom() - fr.bottom() }, 0x000000, 170);
        cv.blend(.{ .x = r.x, .y = fr.y, .w = fr.x - r.x, .h = fr.h }, 0x000000, 170);
        cv.blend(.{ .x = fr.right(), .y = fr.y, .w = r.right() - fr.right(), .h = fr.h }, 0x000000, 170);
        cv.rectLine(fr, th.text_dim);
    }
    const uc = ui_cv.clip;
    defer ui_cv.clip = uc;
    _ = ui_cv.setClip(ui_r.intersect(uc));
    if (v.show_gizmo) drawGizmo(ui_cv, ui_r, &c, th);
    drawAxesCorner(ui_cv, ui_r, &c, th);
}

/// One pass over the id buffer: pixels of a selected mesh next to another
/// id get the outline colour (gold for the active object, else orange).
fn outlines(cv: *gfx.Canvas, r: Rect, th: *const theme.Theme) void {
    const ids = cv.ids orelse return;
    const w = cv.w;
    // the outline colour per object id (0: none)
    const S = struct {
        var col_of: [scene.max_objects + 1]u32 = @splat(0);
    };
    const col_of = &S.col_of;
    @memset(col_of[0 .. scene.count + 1], 0);
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.selected or o.mesh == null) continue;
        col_of[oi + 1] = if (scene.active != null and scene.active.? == oi) th.active else th.selected;
    }
    var y = r.y;
    while (y < r.bottom()) : (y += 1) {
        var x = r.x;
        while (x < r.right()) : (x += 1) {
            const o: usize = @intCast(y * w + x);
            const id = ids[o];
            if (id > scene.count) continue;
            const col = col_of[id];
            if (col == 0) continue;
            var edge = false;
            for ([_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 }, .{ 2, 0 }, .{ -2, 0 }, .{ 0, 2 }, .{ 0, -2 } }) |d| {
                const nx = x + d[0];
                const ny = y + d[1];
                // (the viewport's border is not the object's edge)
                if (r.contains(nx, ny) and ids[@intCast(ny * w + nx)] != id) {
                    edge = true;
                    break;
                }
            }
            if (edge) cv.px[o] = col;
        }
    }
}

/// The point under pixel (x, y): on the surface drawn there (from the depth
/// buffer of the last frame), else on the ground.
pub fn surfacePoint(cv: *gfx.Canvas, v: *const View, r: Rect, x: i32, y: i32) ?m.V3 {
    if (cv.zbuf) |zb| {
        const po: usize = @intCast(@max(0, cv.toPx(y) * cv.w + cv.toPx(x)));
        if (r.contains(x, y) and cv.ids.?[po] != 0) {
            const iz = zb[po];
            if (iz > 0) {
                const c = Cam.init(v, r);
                const z = 1.0 / iz;
                const px = (@as(f32, @floatFromInt(x)) + 0.5 - c.cx) / c.f;
                const py = -(@as(f32, @floatFromInt(y)) + 0.5 - c.cy) / c.f;
                return m.add(c.eye, m.add(m.scale(c.fwd, z), m.add(m.scale(c.right, px * z), m.scale(c.up, py * z))));
            }
        }
    }
    return groundPoint(v, r, x, y);
}

/// seams_draw: the edit object's UV seams, red, over its wires.
fn drawSeams(cv: *gfx.Canvas, c: *const Cam) void {
    const me = em.mesh() orelse return;
    if (me.seam.len != me.loops.len or !scene.objects[em.obj].visible) return;
    const w = scene.world(em.obj);
    for (0..me.poff.len - 1) |p| {
        const s = me.poff[p];
        const e = me.poff[p + 1];
        var l = s;
        while (l < e) : (l += 1) {
            if (me.seam[l] == 0) continue;
            const n = if (l + 1 < e) l + 1 else s;
            line3(cv, c, m.xform(w, me.verts[me.loops[l]]), m.xform(w, me.verts[me.loops[n]]), SEAM);
        }
    }
}

fn drawEdit(cv: *gfx.Canvas, c: *const Cam, v: *const View, th: *const theme.Theme) void {
    const me = em.mesh() orelse return;
    if (!scene.objects[em.obj].visible) return;
    if (!scratch(me.verts.len)) return;
    const w = scene.world(em.obj);
    const vv = vv_buf[0..me.verts.len];
    // every vertex projected once: x, y, 1/z (z <= 0: behind the near plane)
    const sp = wv_buf[0..me.verts.len];
    for (me.verts, 0..) |p, i| {
        vv[i] = c.toView(m.xform(w, p));
        if (vv[i][2] < near) {
            sp[i] = .{ 0, 0, 0 };
        } else {
            const q = c.screen(vv[i]);
            sp[i] = .{ q[0], q[1], 1 / vv[i][2] };
        }
    }
    const wire_col: u32 = if (v.wire) th.obj_wire else EDIT_WIRE;
    const cl = cv.clip;
    const x0: f32 = @floatFromInt(cl.x);
    const y0: f32 = @floatFromInt(cl.y);
    const x1: f32 = @floatFromInt(cl.right());
    const y1: f32 = @floatFromInt(cl.y + cl.h);
    // unselected edges first, the selected ones on top (drawn in a second pass)
    var n_sel: usize = 0;
    for (0..2) |pass| {
        if (pass == 1 and n_sel == 0) break;
        for (me.edge_list) |e| {
            const on = em.edgeSelected(e);
            if (pass == 0 and on) {
                n_sel += 1;
                continue;
            }
            if (pass == 1 and !on) continue;
            const col = if (on) EDIT_SEL else wire_col;
            var pa = sp[e[0]];
            var pb = sp[e[1]];
            if (pa[2] == 0 or pb[2] == 0) {
                // one end (or both) behind the near plane: clip in view space
                var a = vv[e[0]];
                var b = vv[e[1]];
                if (a[2] < near and b[2] < near) continue;
                if (a[2] < near) a = cutNear(b, a).p else b = cutNear(a, b).p;
                const qa = c.screen(a);
                const qb = c.screen(b);
                pa = .{ qa[0], qa[1], 1 / a[2] };
                pb = .{ qb[0], qb[1], 1 / b[2] };
            }
            // off the view on one side: nothing to draw
            if ((pa[0] < x0 and pb[0] < x0) or (pa[0] >= x1 and pb[0] >= x1) or
                (pa[1] < y0 and pb[1] < y0) or (pa[1] >= y1 and pb[1] >= y1)) continue;
            segment(cv, pa, pb, col, !v.wire);
        }
    }
    const zb = cv.zbuf;
    // a dot as the original draws it: 4 px, 6 px when selected
    const dot = struct {
        fn f(cv2: *gfx.Canvas, zb2: ?[*]f32, wire: bool, x: f32, y: f32, iz: f32, on: bool, col: u32) void {
            if (@abs(x) > 30000 or @abs(y) > 30000) return;
            const xi: i32 = @intFromFloat(x);
            const yi: i32 = @intFromFloat(y);
            if (!cv2.clip.contains(xi, yi)) return;
            if (!wire) {
                if (zb2) |z| {
                    if (iz * 1.01 + 1e-4 < z[@intCast(yi * cv2.w + xi)]) return; // hidden
                }
            }
            if (on) cv2.fill(.{ .x = xi - 3, .y = yi - 3, .w = 6, .h = 6 }, EDIT_SEL) else cv2.fill(.{ .x = xi - 2, .y = yi - 2, .w = 4, .h = 4 }, col);
        }
    }.f;
    switch (em.sel_mode) {
        .vertex => for (sp, 0..) |p, i| {
            if (p[2] == 0) continue;
            dot(cv, zb, v.wire, p[0], p[1], p[2], i < em.sel.len and em.sel[i], wire_col);
        },
        .face => for (0..me.poff.len - 1) |f| {
            // the polygon's centre
            const lo = me.loops[me.poff[f]..me.poff[f + 1]];
            if (lo.len == 0) continue;
            var ctr: m.V3 = .{ 0, 0, 0 };
            for (lo) |x| ctr = m.add(ctr, vv[x]);
            ctr = m.scale(ctr, 1 / @as(f32, @floatFromInt(lo.len)));
            if (ctr[2] < near) continue;
            const q = c.screen(ctr);
            dot(cv, zb, v.wire, q[0], q[1], 1 / ctr[2], em.faceSelected(me, f), wire_col);
        },
        .edge => {},
    }
}

/// Where the ray through pixel (x, y) meets the ground (y = 0), if it does.
pub fn groundPoint(v: *const View, r: Rect, x: i32, y: i32) ?m.V3 {
    const c = Cam.init(v, r);
    const px = (@as(f32, @floatFromInt(x)) - c.cx) / c.f;
    const py = -(@as(f32, @floatFromInt(y)) - c.cy) / c.f;
    const dir = m.norm(m.add(c.fwd, m.add(m.scale(c.right, px), m.scale(c.up, py))));
    if (@abs(dir[1]) < 1e-5) return null;
    const t = -c.eye[1] / dir[1];
    if (t <= 0) return null;
    return m.add(c.eye, m.scale(dir, t));
}

// --- navigation gizmo -----------------------------------------------------

pub const gizmo_r = 38;

pub fn gizmoCenter(r: Rect) [2]i32 {
    return .{ r.right() - gizmo_r - 14, r.y + gizmo_r + 12 };
}

const Axis = struct { dir: m.V3, col: u2, label: []const u8, yaw: f32, pitch: f32 };

fn axisCol(th: *const theme.Theme, k: u2) u32 {
    return switch (k) {
        0 => th.axis_x,
        1 => th.axis_y,
        else => th.axis_z,
    };
}
const axes = [6]Axis{
    .{ .dir = .{ 1, 0, 0 }, .col = 0, .label = "X", .yaw = 90, .pitch = 0 },
    .{ .dir = .{ 0, 1, 0 }, .col = 1, .label = "Y", .yaw = 0, .pitch = 89.9 },
    .{ .dir = .{ 0, 0, 1 }, .col = 2, .label = "Z", .yaw = 0, .pitch = 0 },
    .{ .dir = .{ -1, 0, 0 }, .col = 0, .label = "", .yaw = -90, .pitch = 0 },
    .{ .dir = .{ 0, -1, 0 }, .col = 1, .label = "", .yaw = 0, .pitch = -89.9 },
    .{ .dir = .{ 0, 0, -1 }, .col = 2, .label = "", .yaw = 180, .pitch = 0 },
};

fn gizmoPoints(c: *const Cam, r: Rect) [6][3]i32 {
    const ctr = gizmoCenter(r);
    var pts: [6][3]i32 = undefined;
    for (axes, 0..) |a, i| {
        const x = m.dot(a.dir, c.right);
        const y = m.dot(a.dir, c.up);
        const z = m.dot(a.dir, c.fwd);
        pts[i] = .{ ctr[0] + @as(i32, @intFromFloat(x * (gizmo_r - 10))), ctr[1] - @as(i32, @intFromFloat(y * (gizmo_r - 10))), @intFromFloat(z * 100) };
    }
    return pts;
}

fn drawGizmo(cv: *gfx.Canvas, r: Rect, c: *const Cam, th: *const theme.Theme) void {
    const ctr = gizmoCenter(r);
    cv.fillCircle(ctr[0], ctr[1], gizmo_r, gfx.mix(th.canvas_top, 0x000000, 70));
    const pts = gizmoPoints(c, r);
    // draw far axes first
    var order = [6]usize{ 0, 1, 2, 3, 4, 5 };
    std.mem.sort(usize, &order, pts, struct {
        fn lt(p: [6][3]i32, a: usize, b: usize) bool {
            return p[a][2] > p[b][2];
        }
    }.lt);
    for (order) |i| {
        const p = pts[i];
        const a = axes[i];
        const col = axisCol(th, a.col);
        if (a.label.len > 0) {
            cv.thickLine(ctr[0], ctr[1], p[0], p[1], col);
            cv.fillCircle(p[0], p[1], 9, col);
            _ = cv.text(p[0] - 3, p[1] - 8, a.label, 0x101114);
        } else {
            // the negative axes: hollow rings
            cv.fillCircle(p[0], p[1], 7, gfx.mix(th.canvas_top, 0x000000, 70));
            cv.circle(p[0], p[1], 7, col);
            cv.circle(p[0], p[1], 6, col);
        }
    }
}

/// If (x, y) is on one of the gizmo's axis balls, the view it snaps to.
pub fn gizmoPick(v: *const View, r: Rect, x: i32, y: i32) ?[2]f32 {
    const c = Cam.init(v, r);
    const pts = gizmoPoints(&c, r);
    var best: ?usize = null;
    var bz: i32 = std.math.maxInt(i32);
    for (pts, 0..) |p, i| {
        const ddx = x - p[0];
        const ddy = y - p[1];
        if (ddx * ddx + ddy * ddy <= 100 and p[2] < bz) {
            best = i;
            bz = p[2];
        }
    }
    const b = best orelse return null;
    return .{ axes[b].yaw, axes[b].pitch };
}

pub fn inGizmo(r: Rect, x: i32, y: i32) bool {
    const ctr = gizmoCenter(r);
    const ddx = x - ctr[0];
    const ddy = y - ctr[1];
    return ddx * ddx + ddy * ddy <= gizmo_r * gizmo_r;
}

fn drawAxesCorner(cv: *gfx.Canvas, r: Rect, c: *const Cam, th: *const theme.Theme) void {
    // (the original's orientation gizmo: 50 in from the corner, 34 long, each
    // axis two lines a pixel apart, its letter by the tip; viewport.s)
    const ox = r.x + 50;
    const oy = r.bottom() - 50;
    for (axes[0..3]) |a| {
        const x = m.dot(a.dir, c.right);
        const y = m.dot(a.dir, c.up);
        const ex = ox + @as(i32, @intFromFloat(@round(x * 34)));
        const ey = oy - @as(i32, @intFromFloat(@round(y * 34)));
        const col = axisCol(th, a.col);
        cv.line(ox, oy, ex, ey, col);
        cv.line(ox + 1, oy, ex + 1, ey, col);
        _ = cv.text(ex - 3, ey - 7, a.label, col);
    }
}

// --- picking --------------------------------------------------------------

/// The object under (x, y): meshes from the id buffer, else the nearest
/// camera/light origin within a few pixels.
pub fn pick(cv: *gfx.Canvas, v: *const View, r: Rect, x: i32, y: i32) ?usize {
    if (cv.ids) |ids| {
        if (r.contains(x, y) and cv.toPx(x) < cv.w and cv.toPx(y) < cv.h) {
            const id = ids[@intCast(cv.toPx(y) * cv.w + cv.toPx(x))];
            if (id > 0 and id <= scene.count) return id - 1;
        }
    }
    const c = Cam.init(v, r);
    var best: ?usize = null;
    var bd: i32 = 16 * 16;
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (!o.visible or (o.kind != .light and o.kind != .camera and o.kind != .armature and o.kind != .field)) continue;
        if (o.kind == .armature) {
            // (not in the ids: its wires' corners, drawn on no mesh)
            const me = scene.meshOfObj(i) orelse continue;
            const mtx = scene.world(i);
            for (me.verts) |q| {
                const p = c.project(m.xform(mtx, q)) orelse continue;
                const d = (p[0] - x) * (p[0] - x) + (p[1] - y) * (p[1] - y);
                if (d < bd) {
                    bd = d;
                    best = i;
                }
            }
            continue;
        }
        const p = c.project(scene.worldLoc(i)) orelse continue;
        const d = (p[0] - x) * (p[0] - x) + (p[1] - y) * (p[1] - y);
        if (d < bd) {
            bd = d;
            best = i;
        }
    }
    // sketches: their lines' screen bounds, a few pixels' slack, the smallest
    // (vp_pick_bounds)
    if (best == null) best = pickSketch(&c, x, y);
    // reference images: their outlines (not in the ids)
    return best orelse refimg.pickBounds(&c, v.ortho, x, y);
}

fn pickSketch(c: *const Cam, x: i32, y: i32) ?usize {
    var best: ?usize = null;
    var area: f32 = 1.0e30;
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (!o.visible or o.locked or o.kind != .sketch) continue;
        const me = scene.meshOfObj(i) orelse continue;
        const mtx = scene.world(i);
        var lo: [2]f32 = .{ 1.0e30, 1.0e30 };
        var hi: [2]f32 = .{ -1.0e30, -1.0e30 };
        var n: usize = 0;
        for (me.verts) |q| {
            const vw = c.toView(m.xform(mtx, q));
            if (vw[2] < near) continue;
            const s = c.screen(vw);
            lo = .{ @min(lo[0], s[0]), @min(lo[1], s[1]) };
            hi = .{ @max(hi[0], s[0]), @max(hi[1], s[1]) };
            n += 1;
        }
        if (n == 0) continue;
        if (fx < lo[0] - 4 or fx > hi[0] + 4 or fy < lo[1] - 4 or fy > hi[1] + 4) continue;
        const a = (hi[0] - lo[0] + 4) * (hi[1] - lo[1] + 4);
        if (a < area) {
            area = a;
            best = i;
        }
    }
    return best;
}

test "clipSeg: a far end keeps the line's direction; outside or parallel misses" {
    const cl = Rect{ .x = 10, .y = 20, .w = 100, .h = 50 }; // x 10..109, y 20..69
    // from inside to far off to the right and down: cut at the right edge, on the line
    const t = clipSeg(cl, 20, 30, 1.0e6, 2.0e5).?;
    try std.testing.expectEqual(@as(f32, 0), t[0]);
    const x1 = 20 + t[1] * (1.0e6 - 20);
    const y1 = 30 + t[1] * (2.0e5 - 30);
    try std.testing.expectApproxEqAbs(@as(f32, 109), x1, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 30 + (109 - 20) * (2.0e5 - 30) / (1.0e6 - 20)), y1, 1e-3);
    // both ends far out on either side: the part across the view
    const u = clipSeg(cl, -1.0e5, 40, 1.0e5, 40).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10), -1.0e5 + u[0] * 2.0e5, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 109), -1.0e5 + u[1] * 2.0e5, 1e-2);
    try std.testing.expect(clipSeg(cl, 0, 0, 5, 100) == null); // left of it
    try std.testing.expect(clipSeg(cl, 0, 10, 200, 10) == null); // parallel, above
    try std.testing.expect(clipSeg(cl, 0, 100, 200, 0) != null); // a diagonal through it
}

test "rne: ties to even (cvtss2si)" {
    try std.testing.expectEqual(@as(i32, 2), rne(2.5));
    try std.testing.expectEqual(@as(i32, 4), rne(3.5));
    try std.testing.expectEqual(@as(i32, -2), rne(-2.5));
    try std.testing.expectEqual(@as(i32, 3), rne(2.6));
    try std.testing.expectEqual(@as(i32, -3), rne(-2.6));
    try std.testing.expectEqual(@as(i32, 7), rne(7.0));
}

test "cutNear: from the end in front, the depth exactly the plane" {
    // a bar's corner in view space and its far corner: 60 and 2 000 000 along it
    const a: m.V3 = .{ -0.3535533, 0.7080798, 17.2103 };
    const far: m.V3 = .{ 1.4142132e+06, -6.7800944e+05, -1.2410720e+06 };
    const q = cutNear(a, far);
    try std.testing.expectEqual(near, q.p[2]);
    // where a 60 long bar along the same line meets the plane
    const b60: m.V3 = .{ 42.072857, -19.632227, -20.022373 };
    const r = cutNear(a, b60);
    try std.testing.expectApproxEqAbs(r.p[0], q.p[0], 0.01);
    try std.testing.expectApproxEqAbs(r.p[1], q.p[1], 0.01);
    try std.testing.expect(q.s > 0 and q.s < 1);
    try std.testing.expectApproxEqAbs(@as(f32, 19.2005), q.p[0], 0.001);
}
