// Texture, vertex and weight painting (paint.s, vcol.s).
//
// Shift+Tab paints the active mesh's texture: the first image of its material,
// through its UVs. A dab in the viewport is projected: the triangles whose screen
// footprint meets the brush have their texels visited in UV space; each texel's point
// on the surface is projected and painted when it lies inside the brush and in front
// (the viewport's depth buffer, so hidden faces stay clean), with a smooth falloff.
// Texels a little outside a triangle count too, so island borders do not show seams;
// such a texel is painted once by each triangle that reaches it. In the UV editor a
// dab paints the texels around the pointer in UV space. Images are not part of the
// scene's undo: strokes keep their own history (pthist.zig).
//
// Shift+V and Ctrl+W share the brush and the keys: a dab projects the vertices and
// blends those inside the brush and in front towards the colour, or the armature's
// active bone's weight towards a value (wpaint.zig). Each of those strokes is a scene
// undo step.
//
// The arithmetic is the original's, step by step and in single precision, with its
// order of triangles, so texels come out the same to the bit. It only skips what it
// can prove stays clean, and shares the work out by rows of the image: a texel's
// triangles are visited in the same order on one core or many. Nothing here allocates
// per dab: the arrays are made when a stroke starts and stay.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const undo = @import("undo.zig");
const app = @import("app.zig");
const gfx = @import("gfx.zig");
const jobs = @import("jobs.zig");
const arm = @import("arm.zig");
const vp = @import("viewport.zig");
const images = @import("images.zig");
const layers = @import("layers.zig");
const pthist = @import("pthist.zig");
const vcol = @import("vcol.zig");
const wpaint = @import("wpaint.zig");
const material = @import("material.zig");
const sg = @import("shgraph.zig");
const bake = @import("bake.zig");
const stroke = @import("stroke.zig");
const A = std.heap.page_allocator;

const V3 = m.V3;
const Rect = gfx.Rect;
const trunc32 = stroke.trunc32;
const minss = stroke.minss;
const maxss = stroke.maxss;

pub const Kind = enum(u32) { texture = 0, vertex = 1, weight = 2 };

const pf_spacing: f32 = 0.2;
const pf_bleed: f32 = 1.5; // texels past an edge
const pf_depth: f32 = 0.985; // in front: 1/z within 1.5%
const pf_tiny: f32 = 1.0e-12;
const pf_big: f32 = 3.0e38;
pub const rmin: f32 = 2;
pub const rmax: f32 = 500;

pub var on = false;
pub var oid: u32 = 0;
pub var kind: Kind = .texture;
pub var radius: f32 = 30; // pixels
pub var strength: f32 = 0.8;
pub var col: u32 = 0xffd04020; // 0xAARRGGBB
pub var stroking = false;
/// Moves with what a stroke changes (what is drawn from it keys on this).
pub var version: u32 = 0;
/// How long dabs took, and how many (paint.info).
pub var work_ns: i64 = 0;
pub var dabs: u64 = 0;

/// The object painted (its place now).
pub fn objIndex() ?usize {
    if (!on) return null;
    return scene.findOid(oid);
}

/// The painted object, drawn as weights' heat?
pub inline fn heatOf(oi: usize) bool {
    return on and kind == .weight and scene.objects[oi].oid == oid;
}

/// Vertex or weight paint: the mesh itself, not the GPU's copy (gview.zig), not
/// clusters (vgdraw.zig).
pub inline fn meshModes() bool {
    return on and kind != .texture;
}

pub fn stateWord() u64 {
    return @as(u64, oid) << 32 | version;
}

/// paint_target: the 8-bit image of the first image node of its material; its mesh
/// needs UVs.
pub fn target(oi: usize) ?usize {
    const o = &scene.objects[oi];
    if (!o.kind.isMesh()) return null;
    const me = scene.meshOfObj(oi) orelse return null;
    if (me.uv.len == 0 or me.uv.len != me.loops.len or me.tris.len == 0) return null;
    return imageOf(oi);
}

/// The image the UV editor shows under the layout: as paint_target, UVs apart.
pub fn imageOf(oi: usize) ?usize {
    const ma = material.of(&scene.objects[oi]) orelse return null;
    const ns = sg.nodesOf(ma);
    for (ns[0..sg.count(ma)]) |*n| {
        if (n.type != sg.T_IMAGE) continue;
        const f = n.p[0];
        if (!(f >= 1 and f < @as(f32, @floatFromInt(images.count)) + 1)) return null;
        const i: usize = @intFromFloat(f - 1);
        return if (images.list[i].b8.len > 0) i else null;
    }
    return null;
}

/// The image painted (texture paint), the mode left when it is gone.
fn validImage() ?usize {
    const i = objIndex() orelse {
        if (on) leave();
        return null;
    };
    if (kind != .texture) return null;
    return target(i) orelse {
        leave();
        return null;
    };
}

fn validMesh() ?usize {
    const i = objIndex() orelse {
        if (on) leave();
        return null;
    };
    if (!scene.objects[i].kind.isMesh() or scene.objects[i].mesh == null) {
        leave();
        return null;
    }
    return i;
}

/// The image the HUD names.
pub fn image() ?usize {
    if (!on or kind != .texture) return null;
    const i = objIndex() orelse return null;
    return target(i);
}

// the modes --------------------------------------------------------------------------

fn leave() void {
    finishStroke();
    on = false;
    oid = 0;
    kind = .texture;
    version +%= 1;
    freeArrays();
    app.dirty = true;
}

/// Out of the mode, whichever paint it was (a stroke under way ends here, one step).
pub fn exit() void {
    if (on) leave();
}

/// A new scene: nothing here points at it.
pub fn sceneReplaced() void {
    dropStroke();
    if (on) leave();
    freeArrays();
}

fn activeMesh() ?usize {
    const a = scene.active orelse {
        app.toast(.warn, "select a mesh", .{});
        return null;
    };
    if (!scene.objects[a].kind.isMesh() or scene.objects[a].mesh == null) {
        app.toast(.warn, "select a mesh", .{});
        return null;
    }
    return a;
}

/// Other modes end before a paint mode starts (one mode at a time).
fn otherModesOff() void {
    const em = @import("editmesh.zig");
    if (em.active) em.exit();
    @import("sculpt.zig").exit();
    @import("armedit.zig").mode = 0;
}

fn beginMode(i: usize, k: Kind) void {
    otherModesOff();
    on = true;
    oid = scene.objects[i].oid;
    kind = k;
    version +%= 1;
    app.dirty = true;
}

/// object.texture_paint: Shift+Tab toggles.
pub fn opTexture() void {
    if (on) {
        leave();
        app.toast(.ok, "texture paint off", .{});
        return;
    }
    const a = activeMesh() orelse return need();
    if (target(a) == null) return need();
    beginMode(a, .texture);
    app.toast(.ok, "texture paint: {s}", .{scene.objects[a].name()});
}

fn need() void {
    app.toast(.warn, "texture paint: a mesh with UVs and an image in its material (U unwraps, image.new + node)", .{});
    app.dirty = true;
}

/// object.vertex_paint: Shift+V toggles.
pub fn opVertex() void {
    if (on) return leave();
    const a = activeMesh() orelse return;
    beginMode(a, .vertex);
    app.toast(.ok, "vertex paint: {s}", .{scene.objects[a].name()});
}

/// object.weight_paint: Ctrl+W toggles.
pub fn opWeight() void {
    if (on) return leave();
    const a = activeMesh() orelse return;
    beginMode(a, .weight);
    wpaint.bone = wpaint.paintBone(a);
    app.toast(.ok, "weight paint: {s}", .{scene.objects[a].name()});
}

pub fn isTexture() bool {
    return on and kind == .texture;
}
pub fn isVertex() bool {
    return on and kind == .vertex;
}
pub fn isWeight() bool {
    return on and kind == .weight;
}

// the camera of a stroke -----------------------------------------------------------

/// local -> camera (rows: right, up, fwd; translation).
var pt_c: [12]f32 = undefined;
var cam_f: f32 = 1;
var cam_cx: f32 = 0;
var cam_cy: f32 = 0;
var near: f32 = 0.05;
// the viewport's depth (pixels), as the last frame left it
var zb: ?[*]f32 = null;
var zw: usize = 0;
var rs_x0: i32 = 0;
var rs_y0: i32 = 0;
var rs_w: u32 = 0;
var rs_h: u32 = 0;
var ui_s120: f32 = 120;
/// What vc, tbox, vs were made from.
var cache_key: [18]u32 = @splat(0);
var cache_on = false;

fn setCam(oi: usize, c: *const vp.Cam) void {
    const a = arm.objMat(oi);
    const rows = [3]V3{ c.right, c.up, c.fwd };
    for (rows, 0..) |r, i| {
        for (0..3) |j| pt_c[i * 4 + j] = r[0] * a[j] + r[1] * a[4 + j] + r[2] * a[8 + j];
        pt_c[i * 4 + 3] = (a[3] - c.eye[0]) * r[0] + (a[7] - c.eye[1]) * r[1] + (a[11] - c.eye[2]) * r[2];
    }
    cam_f = c.f;
    cam_cx = c.cx;
    cam_cy = c.cy;
    near = vp.near;
}

inline fn toCam(p: V3) V3 {
    var o: V3 = undefined;
    for (0..3) |k| {
        const r = pt_c[k * 4..][0..4];
        o[k] = r[0] * p[0] + r[1] * p[1] + r[2] * p[2] + r[3];
    }
    return o;
}

/// pt_screen: x, y (physical), 1/z.
inline fn toScreen(p: V3) [3]f32 {
    const iz = 1.0 / p[2];
    const k = iz * cam_f;
    return .{ p[0] * k + cam_cx, cam_cy - p[1] * k, iz };
}

fn setView(cv: *const gfx.Canvas, v: *const vp.View, r: Rect, oi: usize) void {
    const pr = cv.pxRect(r);
    const c = vp.Cam.init(v, pr);
    setCam(oi, &c);
    zb = cv.zbuf;
    zw = @intCast(cv.w);
    rs_x0 = pr.x;
    rs_y0 = pr.y;
    rs_w = @intCast(@max(pr.w, 0));
    rs_h = @intCast(@max(pr.h, 0));
    ui_s120 = @floatFromInt(@as(u64, @import("scale.zig").comp_s120) * @import("scale.zig").pref / 100);
}

inline fn inFront(x: f32, y: f32, iz: f32) bool {
    const px: u32 = @bitCast(trunc32(x) -% rs_x0);
    const py: u32 = @bitCast(trunc32(y) -% rs_y0);
    if (px >= rs_w or py >= rs_h) return false;
    const z = zb orelse return false;
    const d = z[@as(usize, py +% @as(u32, @intCast(rs_y0))) * zw + (px +% @as(u32, @intCast(rs_x0)))] * pf_depth;
    return !(d > iz);
}

// the arrays a stroke keeps ----------------------------------------------------------

const BLOCKS = 256;
const BAND = 32; // rows

/// A triangle under the brush, ready for its texels.
const Prep = struct {
    t: [6]f32, // the corners in texels
    area2: f32,
    tol: [3]f32,
    cam: [3]V3,
    x0: i32,
    x1: i32,
    y0: i32,
    y1: i32,
};

var vc: []V3 = &.{}; // vertices in camera space
var vs: [][3]f32 = &.{}; // and on screen: x, y, 1/z (-1: behind the near plane)
var tbox: [][4]f32 = &.{}; // triangles' screen boxes
var prep: []Prep = &.{};
var before: [][4]u8 = &.{}; // the buffer painted, as it was when the stroke began

fn freeArrays() void {
    if (vc.len > 0) A.free(vc);
    if (vs.len > 0) A.free(vs);
    if (tbox.len > 0) A.free(tbox);
    if (prep.len > 0) A.free(prep);
    if (before.len > 0) A.free(before);
    vc = &.{};
    vs = &.{};
    tbox = &.{};
    prep = &.{};
    before = &.{};
    cache_on = false;
    if (vbefore.len > 0) A.free(vbefore);
    if (wbefore.len > 0) A.free(wbefore);
    vbefore = &.{};
    wbefore = &.{};
}

fn sized(comptime T: type, a: *[]T, n: usize) bool {
    if (a.len == n) return true;
    if (a.len > 0) A.free(a.*);
    a.* = A.alloc(T, n) catch {
        a.* = &.{};
        return false;
    };
    cache_on = false;
    return true;
}

fn jobVerts(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const me: *const scene.Mesh = @ptrCast(@alignCast(ctx));
    for (lo..hi) |i| {
        const p = toCam(me.verts[i]);
        vc[i] = p;
        if (p[2] >= near) {
            vs[i] = toScreen(p);
        } else vs[i] = .{ 0, 0, -1 }; // (behind the eye, or a NaN)
    }
}

fn jobBoxes(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const me: *const scene.Mesh = @ptrCast(@alignCast(ctx));
    for (me.tris[lo..hi], lo..) |t, ti| {
        var b = [4]f32{ pf_big, pf_big, -pf_big, -pf_big };
        var ok = true;
        for (t) |v| {
            const s = &vs[v];
            if (s[2] == -1) ok = false;
            b[0] = minss(b[0], s[0]);
            b[2] = maxss(b[2], s[0]);
            b[1] = minss(b[1], s[1]);
            b[3] = maxss(b[3], s[1]);
        }
        // (a corner behind the eye: skipped, whatever the rest says)
        tbox[ti] = if (ok) b else .{ pf_big, pf_big, -pf_big, -pf_big };
    }
}

/// The projections of this mesh from this view: once, while both stay.
fn project(me: *const scene.Mesh) bool {
    var key: [18]u32 = undefined;
    for (pt_c, 0..) |x, k| key[k] = @bitCast(x);
    key[12] = @bitCast(cam_f);
    key[13] = @bitCast(cam_cx);
    key[14] = @bitCast(cam_cy);
    key[15] = me.serial;
    key[16] = me.shape;
    key[17] = @truncate(@intFromPtr(me.verts.ptr) >> 4);
    if (!sized(V3, &vc, me.verts.len) or !sized([3]f32, &vs, me.verts.len)) return false;
    if (kind == .texture and (!sized([4]f32, &tbox, me.tris.len) or !sized(Prep, &prep, me.tris.len))) return false;
    if (cache_on and std.mem.eql(u32, &key, &cache_key)) return true;
    cache_key = key;
    cache_on = true;
    const ctx: *anyopaque = @ptrCast(@constCast(me));
    jobs.parallelFor(me.verts.len, 16384, ctx, jobVerts);
    if (kind == .texture) jobs.parallelFor(me.tris.len, 16384, ctx, jobBoxes);
    return true;
}

// the stroke ---------------------------------------------------------------------------

var st_im: usize = 0;
var st_layer: i32 = -1;
var st_buf: [][4]u8 = &.{};
var st_layers: ?*layers.Block = null;
var st_x0: i32 = 0x7fffffff;
var st_y0: i32 = 0x7fffffff;
var st_x1: i32 = -1;
var st_y1: i32 = -1;
var lx: f32 = 0; // the last dab (physical)
var ly: f32 = 0;
pub var hx: i32 = 0;
pub var hy: i32 = 0;
/// in the UV editor (a dab per motion, no projection)
var uv_stroke = false;

/// stroke_start: a copy of the buffer painted (for the history), no box yet.
fn strokeStart(im: usize) bool {
    const e = &images.list[im];
    const buf = layers.target(e);
    if (!sized([4]u8, &before, buf.len)) return false;
    @memcpy(before, buf);
    st_im = im;
    st_layer = layers.activeOf(e);
    st_buf = buf;
    st_layers = e.layers;
    st_x0 = 0x7fffffff;
    st_y0 = 0x7fffffff;
    st_x1 = -1;
    st_y1 = -1;
    stroking = true;
    return true;
}

/// stroke_finish: the box's pixels before the stroke go into the history.
fn textureEnd() void {
    stroking = false;
    if (st_x1 < 0) return; // (nothing changed)
    if (st_im >= images.count) return;
    pthist.commitBox(st_im, st_layer, before, @intCast(st_x0), @intCast(st_y0), @intCast(st_x1), @intCast(st_y1));
}

/// A stroke by hand that is still going (the mode ends, a key undoes): it ends here,
/// one step, with what it did.
pub fn finishStroke() void {
    if (!stroking) return;
    if (kind == .texture or uv_stroke) textureEnd() else meshEnd();
    uv_stroke = false;
}

/// The scene went with the stroke's mesh or image.
fn dropStroke() void {
    stroking = false;
    uv_stroke = false;
    st_buf = &.{};
}

// a dab in the viewport ------------------------------------------------------------------

const Dab = struct {
    x: f32,
    y: f32,
    r: f32,
    r2: f32,
    str: f32,
    e: *images.Entry,
    w: f32,
    h: f32,
    iw: usize,
    start: [BLOCKS]u32 = undefined,
    cnt: [BLOCKS]u32 = undefined,
    me: *const scene.Mesh,
    // the rows touched
    ymin: i32 = 0x7fffffff,
    ymax: i32 = -1,
};

const Box = struct {
    x0: i32 = 0x7fffffff,
    y0: i32 = 0x7fffffff,
    x1: i32 = -1,
    y1: i32 = -1,
};

/// The stroke's box grows with what workers saw.
var box_lock: std.atomic.Mutex = .unlocked;
fn merge(b: *const Box) void {
    if (b.x1 < 0) return;
    while (!box_lock.tryLock()) std.atomic.spinLoopHint();
    defer box_lock.unlock();
    st_x0 = @min(st_x0, b.x0);
    st_y0 = @min(st_y0, b.y0);
    st_x1 = @max(st_x1, b.x1);
    st_y1 = @max(st_y1, b.y1);
}

/// pt_blend: towards the brush colour in the buffer painted (a layer: its alpha rises
/// too, then the composite there).
inline fn blendTexel(e: *images.Entry, b: *Box, x: i32, y: i32, amount: f32) void {
    if (x < b.x0) b.x0 = x;
    if (x > b.x1) b.x1 = x;
    if (y < b.y0) b.y0 = y;
    if (y > b.y1) b.y1 = y;
    const i = @as(usize, @intCast(y)) * @as(usize, e.img.w) + @as(usize, @intCast(x));
    const p = &st_buf[i];
    var c = p.*;
    const br = [4]u8{ @truncate(col >> 16), @truncate(col >> 8), @truncate(col), @truncate(col >> 24) };
    const lay = st_layers != null;
    if (lay and c[3] == 0) c = br; // (a layer: transparent takes the brush colour outright)
    // 0xAARRGGBB as pt_blend builds it: each channel's whole 32 bits shifted
    // into place and or'd in (out of 0..255, a NaN amount: they spill above)
    var r: u32 = 0;
    for ([3]u5{ 0, 8, 16 }, [3]usize{ 2, 1, 0 }) |sh, k| {
        const a: f32 = @floatFromInt(c[k]);
        const d: f32 = @as(f32, @floatFromInt(br[k])) - a;
        const s = d * amount + a + 0.5;
        r |= @as(u32, @bitCast(trunc32(s))) << sh;
    }
    var al: u32 = 0xff; // (no layers: opaque)
    if (lay) {
        const a: f32 = @floatFromInt(c[3]);
        const s = (255.0 - a) * amount + a + 0.5;
        al = @bitCast(trunc32(s));
    }
    r |= al << 24;
    const o = [4]u8{ @truncate(r >> 16), @truncate(r >> 8), @truncate(r), @truncate(r >> 24) };
    p.* = o;
    if (lay) {
        layers.texel(e, st_layers.?, i);
    } else e.img.px[i] = images.linear(o);
}

/// pt_tri_texels' set-up: the corners in texels, the tolerance of each edge, the box.
fn setup(d: *const Dab, p: *Prep, uv: *const [6]f32) bool {
    for (0..3) |k| {
        p.t[k * 2] = uv[k * 2] * d.w;
        p.t[k * 2 + 1] = (1.0 - uv[k * 2 + 1]) * d.h;
    }
    const t = &p.t;
    const a2 = (t[2] - t[0]) * (t[5] - t[1]) - (t[4] - t[0]) * (t[3] - t[1]);
    p.area2 = a2;
    if (!(@abs(a2) > pf_tiny)) return false;
    const xl = minss(minss(t[0], t[2]), t[4]);
    const xh = maxss(maxss(t[0], t[2]), t[4]);
    const yl = minss(minss(t[1], t[3]), t[5]);
    const yh = maxss(maxss(t[1], t[3]), t[5]);
    p.x0 = trunc32(xl - pf_bleed);
    p.x1 = trunc32(xh + pf_bleed);
    p.y0 = trunc32(yl - pf_bleed);
    p.y1 = trunc32(yh + pf_bleed);
    if (p.x0 < 0) p.x0 = 0;
    const wm: i32 = @intCast(d.e.img.w - 1);
    const hm: i32 = @intCast(d.e.img.h - 1);
    if (p.x1 > wm) p.x1 = wm;
    if (p.y0 < 0) p.y0 = 0;
    if (p.y1 > hm) p.y1 = hm;
    for (0..3) |k| {
        const q = (k + 1) % 3;
        const ex = t[q * 2] - t[k * 2];
        const ey = t[q * 2 + 1] - t[k * 2 + 1];
        p.tol[k] = @sqrt(ex * ex + ey * ey) * pf_bleed / @abs(a2);
    }
    return true;
}

/// Is every texel of this box, a block of a triangle's, sure to stay clean? The
/// surface's point is affine in the texel, so the corners bound what lies between:
/// a block past an edge has every texel past it; a block in front of the eye
/// projects into the corners' hull. Rounding is allowed for on both.
fn blockClean(d: *const Dab, p: *const Prep, x0: i32, y0: i32, x1: i32, y1: i32) bool {
    const fx0 = @as(f32, @floatFromInt(x0)) + 0.5;
    const fx1 = @as(f32, @floatFromInt(x1)) + 0.5;
    const fy0 = @as(f32, @floatFromInt(y0)) + 0.5;
    const fy1 = @as(f32, @floatFromInt(y1)) + 0.5;
    const cx = [4]f32{ fx0, fx1, fx0, fx1 };
    const cy = [4]f32{ fy0, fy0, fy1, fy1 };
    const t = &p.t;
    const slack: f32 = 64.0 / @abs(p.area2);
    var w: [4][3]f32 = undefined;
    for (0..3) |k| {
        const b = (k + 1) % 3;
        const c = (b + 1) % 3;
        var top: f32 = -std.math.inf(f32);
        for (0..4) |q| {
            const v = ((t[c * 2] - t[b * 2]) * (cy[q] - t[b * 2 + 1]) - (t[c * 2 + 1] - t[b * 2 + 1]) * (cx[q] - t[b * 2])) / p.area2;
            w[q][k] = v;
            top = @max(top, v);
        }
        const lim = -p.tol[b] - slack - @abs(top) * 1.0e-5;
        if (top < lim) return true;
    }
    var xl: f32 = std.math.inf(f32);
    var xh: f32 = -std.math.inf(f32);
    var yl: f32 = std.math.inf(f32);
    var yh: f32 = -std.math.inf(f32);
    for (0..4) |q| {
        var c: V3 = .{ 0, 0, 0 };
        for (0..3) |k| {
            for (0..3) |i| c[i] += p.cam[k][i] * w[q][k];
        }
        if (!(c[2] >= near) or !std.math.isFinite(c[0]) or !std.math.isFinite(c[1])) return false;
        const s = toScreen(c);
        xl = @min(xl, s[0]);
        xh = @max(xh, s[0]);
        yl = @min(yl, s[1]);
        yh = @max(yh, s[1]);
    }
    const mx = 1.0 + (@abs(xl) + @abs(xh)) * 1.0e-4;
    const my = 1.0 + (@abs(yl) + @abs(yh)) * 1.0e-4;
    return xh + mx < d.x - d.r or xl - mx > d.x + d.r or yh + my < d.y - d.r or yl - my > d.y + d.r;
}

/// pt_tri_texels' loops: every texel whose centre is in the UV triangle (or within a
/// texel and a half of it): barycentrics -> camera point -> screen; inside the brush
/// and in front: painted.
fn texels(d: *const Dab, p: *const Prep, b: *Box, x0: i32, y0: i32, x1: i32, y1: i32) void {
    if (x1 < x0 or y1 < y0) return;
    if ((x1 - x0 >= 16 or y1 - y0 >= 16) and blockClean(d, p, x0, y0, x1, y1)) return;
    if (x1 - x0 >= 16 or y1 - y0 >= 16) {
        if (x1 - x0 >= y1 - y0) {
            const mid = x0 + @divTrunc(x1 - x0, 2);
            texels(d, p, b, x0, y0, mid, y1);
            texels(d, p, b, mid + 1, y0, x1, y1);
        } else {
            const mid = y0 + @divTrunc(y1 - y0, 2);
            texels(d, p, b, x0, y0, x1, mid);
            texels(d, p, b, x0, mid + 1, x1, y1);
        }
        return;
    }
    const t = &p.t;
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        texel: while (x <= x1) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            var w: [3]f32 = undefined;
            for (0..3) |k| {
                // the edge opposite corner k
                const e = (k + 1) % 3;
                const c = (e + 1) % 3;
                const v = ((t[c * 2] - t[e * 2]) * (fy - t[e * 2 + 1]) - (t[c * 2 + 1] - t[e * 2 + 1]) * (fx - t[e * 2])) / p.area2;
                w[k] = v;
                if (!(v >= 0.0 - p.tol[e])) continue :texel;
            }
            var q: V3 = .{ 0, 0, 0 };
            for (0..3) |k| {
                q[0] += p.cam[k][0] * w[k];
                q[1] += p.cam[k][1] * w[k];
                q[2] += p.cam[k][2] * w[k];
            }
            if (!(q[2] >= near)) continue;
            const s = toScreen(q);
            const ex = s[0] - d.x;
            const ey = s[1] - d.y;
            var dist = ex * ex + ey * ey;
            if (dist >= d.r2) continue;
            dist /= d.r2;
            const f = 1.0 - dist;
            const amount = f * f * d.str;
            if (!inFront(s[0], s[1], s[2])) continue;
            blendTexel(d.e, b, x, y, amount);
        }
    }
}

fn jobSelect(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const d: *Dab = @ptrCast(@alignCast(ctx));
    const nt = d.me.tris.len;
    for (lo..hi) |k| {
        const t0 = nt * k / BLOCKS;
        const t1 = nt * (k + 1) / BLOCKS;
        var n: u32 = 0;
        var ymin: i32 = 0x7fffffff;
        var ymax: i32 = -1;
        for (t0..t1) |ti| {
            const b = &tbox[ti];
            if (!(d.x + d.r >= b[0])) continue;
            if (d.x - d.r > b[2]) continue;
            if (!(d.y + d.r >= b[1])) continue;
            if (d.y - d.r > b[3]) continue;
            const uv = bake.triUvs(d.me, ti) orelse continue;
            const p = &prep[t0 + n];
            if (!setup(d, p, &uv)) continue;
            if (p.x1 < p.x0 or p.y1 < p.y0) continue;
            const c = d.me.tris[ti];
            p.cam = .{ vc[c[0]], vc[c[1]], vc[c[2]] };
            ymin = @min(ymin, p.y0);
            ymax = @max(ymax, p.y1);
            n += 1;
        }
        d.start[k] = @intCast(t0);
        d.cnt[k] = n;
        // (one writer a block; the rows are gathered after)
        blk_ymin[k] = ymin;
        blk_ymax[k] = ymax;
    }
}
var blk_ymin: [BLOCKS]i32 = undefined;
var blk_ymax: [BLOCKS]i32 = undefined;

fn bandRange(d: *const Dab, y0: i32, y1: i32, b: *Box) void {
    for (0..BLOCKS) |k| {
        const c = d.cnt[k];
        if (c == 0 or blk_ymax[k] < y0 or blk_ymin[k] > y1) continue;
        for (prep[d.start[k]..][0..c]) |*p| {
            if (p.y1 < y0 or p.y0 > y1) continue;
            texels(d, p, b, p.x0, @max(p.y0, y0), p.x1, @min(p.y1, y1));
        }
    }
}

fn jobBand(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const d: *Dab = @ptrCast(@alignCast(ctx));
    var b = Box{};
    for (lo..hi) |k| {
        const y0 = d.ymin + @as(i32, @intCast(k)) * BAND;
        bandRange(d, y0, @min(y0 + BAND - 1, d.ymax), &b);
    }
    merge(&b);
}

/// pt_dab: one dab, (x, y) physical.
fn dabTexture(x: f32, y: f32, im: usize, oi: usize) void {
    if (im != st_im) return; // (the material changed under the stroke)
    const me = scene.meshOfObj(oi) orelse return;
    if (!project(me)) return;
    const e = &images.list[im];
    const r = radius * ui_s120 / 120.0;
    var d = Dab{ .x = x, .y = y, .r = r, .r2 = r * r, .str = strength, .e = e, .w = @floatFromInt(e.img.w), .h = @floatFromInt(e.img.h), .iw = e.img.w, .me = me };
    jobs.parallelFor(BLOCKS, if (me.tris.len < 16384) BLOCKS else 8, &d, jobSelect);
    var area: u64 = 0;
    for (0..BLOCKS) |k| {
        d.ymin = @min(d.ymin, blk_ymin[k]);
        d.ymax = @max(d.ymax, blk_ymax[k]);
        if (d.cnt[k] != 0) area += @as(u64, d.cnt[k]) * 64;
    }
    if (d.ymax >= d.ymin) {
        const rows: usize = @intCast(d.ymax - d.ymin + 1);
        if (area + rows * 4 < 60000 or jobs.count() <= 1) {
            var b = Box{};
            bandRange(&d, d.ymin, d.ymax, &b);
            merge(&b);
        } else jobs.parallelFor((rows + BAND - 1) / BAND, 1, &d, jobBand);
    }
    images.touched(im);
}

// a dab on vertices --------------------------------------------------------------------

const VDab = struct { x: f32, y: f32, r2: f32, me: *scene.Mesh };

fn jobVDab(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const d: *VDab = @ptrCast(@alignCast(ctx));
    for (lo..hi) |i| {
        const s = &vs[i];
        if (s[2] == -1) continue;
        const ex = s[0] - d.x;
        const ey = s[1] - d.y;
        var dist = ex * ex + ey * ey;
        if (dist >= d.r2) continue;
        dist /= d.r2;
        const f = 1.0 - dist;
        const amount = f * f * strength;
        if (!inFront(s[0], s[1], s[2])) continue;
        put(d.me, i, amount);
    }
}

inline fn put(me: *scene.Mesh, i: usize, amount: f32) void {
    if (kind == .weight) wpaint.blend(&me.wgt[i], amount) else blendVertex(&me.vcol[i], amount);
}

/// vp_blend: towards the brush colour.
inline fn blendVertex(p: *u32, amount: f32) void {
    const c = p.*;
    var o: u32 = 0xff000000;
    var sh: u5 = 0;
    while (true) {
        const a: f32 = @floatFromInt(c >> sh & 255);
        const b: f32 = @floatFromInt(col >> sh & 255);
        const s = (b - a) * amount + a + 0.5;
        o |= (@as(u32, @bitCast(trunc32(s))) & 255) << sh;
        if (sh == 16) break;
        sh += 8;
    }
    p.* = o;
}

/// vp_dab: the vertices inside the brush and in front.
fn dabMesh(x: f32, y: f32, oi: usize) void {
    const me = meshNow(oi) orelse return;
    if (kind == .weight and me.wgt.len != me.verts.len) return;
    if (kind == .vertex and me.vcol.len != me.verts.len) return;
    if (!project(me)) return;
    const r = radius * ui_s120 / 120.0;
    var d = VDab{ .x = x, .y = y, .r2 = r * r, .me = me };
    jobs.parallelFor(me.verts.len, 16384, &d, jobVDab);
}

fn meshNow(oi: usize) ?*scene.Mesh {
    const mi = scene.objects[oi].mesh orelse return null;
    return if (scene.meshes[mi]) |*me| me else null;
}

// undo of a mesh stroke: what changed, old and new -------------------------------------

var vbefore: []u32 = &.{};
var wbefore: []arm.Wgt = &.{};
var st_mi: u16 = 0;
var st_serial: u32 = 0;
var st_made = false; // the stroke gave the mesh its colours or weights

const Block = struct {
    serial: u32,
    mi: u16,
    weights: bool,
    made: bool,
    n: usize,
    idx: []u32,
    old: []u8, // n records
    new: []u8,
};

/// Another object shows this mesh, or a new one would (the primitives).
fn sharedMesh(i: usize, mi: u16) bool {
    for (scene.prim) |p| {
        if (p == mi) return true;
    }
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (k != i and o.mesh == mi) return true;
    }
    return false;
}

/// vp_stroke_start: the mesh is the object's own (the step before keeps seeing it
/// through the delta), with colours or weights; a copy of them to tell what changed.
fn meshStart(oi: usize) bool {
    undo.sync(); // (the scene as it is now is the step before this one)
    const o = &scene.objects[oi];
    const mi0 = o.mesh orelse return false;
    if (sharedMesh(oi, mi0)) {
        const c = scene.cloneMesh(mi0) orelse return false;
        o.mesh = c;
        undo.absorbMesh(oi);
    }
    const mi = o.mesh.?;
    const me = &(scene.meshes[mi] orelse return false);
    st_made = false;
    if (kind == .weight) {
        const b = wpaint.paintBone(oi);
        if (b < 0) {
            undo.strokeStep("Vertex Paint", null); // (the step comes first, in the original)
            return false;
        }
        wpaint.bone = b;
        if (me.wgt.len != me.verts.len) {
            if (!wpaint.alloc(me)) return false;
            st_made = true;
        }
        if (!sized(arm.Wgt, &wbefore, me.wgt.len)) return false;
        @memcpy(wbefore, me.wgt);
    } else {
        if (me.vcol.len != me.verts.len) {
            if (!vcol.alloc(me)) return false;
            st_made = true;
        }
        if (!sized(u32, &vbefore, me.vcol.len)) return false;
        @memcpy(vbefore, me.vcol);
    }
    st_mi = mi;
    st_serial = me.serial;
    stroking = true;
    return true;
}

fn makeDelta(comptime T: type, me: []const T, was: []const T, mi: u16, serial: u32, made: bool, weights: bool) ?undo.Delta {
    var n: usize = 0;
    for (me, was) |a, b| {
        if (!std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b))) n += 1;
    }
    const bl = A.create(Block) catch return null;
    const idx = A.alloc(u32, n) catch {
        A.destroy(bl);
        return null;
    };
    const rec = @sizeOf(T);
    const old = A.alloc(u8, n * rec) catch {
        A.free(idx);
        A.destroy(bl);
        return null;
    };
    const new = A.alloc(u8, n * rec) catch {
        A.free(idx);
        A.free(old);
        A.destroy(bl);
        return null;
    };
    var k: usize = 0;
    for (me, was, 0..) |a, b, i| {
        if (std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b))) continue;
        idx[k] = @intCast(i);
        @memcpy(old[k * rec..][0..rec], std.mem.asBytes(&b));
        @memcpy(new[k * rec..][0..rec], std.mem.asBytes(&a));
        k += 1;
    }
    bl.* = .{ .serial = serial, .mi = mi, .weights = weights, .made = made, .n = n, .idx = idx, .old = old, .new = new };
    return .{ .ctx = bl, .bytes = @sizeOf(Block) + n * 4 + n * rec * 2, .apply = applyDelta, .free = freeDelta };
}

fn applyDelta(ctx: *anyopaque, back: bool) void {
    const h: *Block = @ptrCast(@alignCast(ctx));
    const me = &(scene.meshes[h.mi] orelse return);
    if (me.serial != h.serial) return;
    if (h.weights) {
        if (h.made and !back and !wpaint.alloc(me)) return;
        applyRecs(arm.Wgt, me.wgt, h, back);
        if (h.made and back) {
            @import("alloc.zig").A.free(me.wgt);
            me.wgt = &.{};
        }
        scene.bumpShape(h.mi); // (the skin follows)
    } else {
        if (h.made and !back and !vcol.alloc(me)) return;
        applyRecs(u32, me.vcol, h, back);
        if (h.made and back) {
            @import("alloc.zig").A.free(me.vcol);
            me.vcol = &.{};
        }
    }
    shown(me);
}

fn applyRecs(comptime T: type, a: []T, h: *const Block, back: bool) void {
    if (a.len == 0) return;
    const rec = @sizeOf(T);
    const src = if (back) h.old else h.new;
    for (h.idx, 0..) |v, k| {
        if (v >= a.len) continue;
        @memcpy(std.mem.asBytes(&a[v]), src[k * rec..][0..rec]);
    }
}

fn freeDelta(ctx: *anyopaque) void {
    const h: *Block = @ptrCast(@alignCast(ctx));
    A.free(h.idx);
    A.free(h.old);
    A.free(h.new);
    A.destroy(h);
}

/// What shows its colours or weights follows.
fn shown(me: *scene.Mesh) void {
    paints +%= 1;
    me.paints = paints;
    version +%= 1;
    material.version +%= 1; // (Rendered restarts, the viewport draws again)
    app.dirty = true;
}
var paints: u32 = 0;

/// The stroke as one scene step.
fn meshEnd() void {
    stroking = false;
    const me = &(scene.meshes[st_mi] orelse {
        undo.strokeStep("Vertex Paint", null);
        return;
    });
    var d: ?undo.Delta = null;
    if (me.serial == st_serial) {
        if (kind == .weight) {
            if (me.wgt.len == wbefore.len) d = makeDelta(arm.Wgt, me.wgt, wbefore, st_mi, st_serial, st_made, true);
            scene.bumpShape(st_mi);
        } else if (me.vcol.len == vbefore.len) d = makeDelta(u32, me.vcol, vbefore, st_mi, st_serial, st_made, false);
    }
    undo.strokeStep("Vertex Paint", d);
    shown(me);
}

// the pointer ---------------------------------------------------------------------------

fn afterDabs() void {
    if (objIndex()) |oi| {
        if (meshNow(oi)) |me| {
            if (kind != .texture) {
                shown(me);
                if (kind == .weight) scene.bumpShape(scene.objects[oi].mesh.?);
                return;
            }
        }
    }
    version +%= 1;
    material.version +%= 1;
    app.dirty = true;
}

fn oneDab(x: f32, y: f32) void {
    const t0 = @import("sculpt.zig").nowNs();
    defer {
        work_ns += @import("sculpt.zig").nowNs() - t0;
        dabs += 1;
    }
    if (kind == .texture) {
        const im = validImage() orelse return;
        const oi = objIndex() orelse return;
        dabTexture(x, y, im, oi);
    } else {
        const oi = validMesh() orelse return;
        dabMesh(x, y, oi);
    }
}

/// paint_press: true when a stroke started (off the mesh too: it is a stroke).
pub fn press(cv: *const gfx.Canvas, v: *const vp.View, r: Rect, x: i32, y: i32) bool {
    if (kind == .texture) {
        const im = validImage() orelse return false;
        if (!strokeStart(im)) return false;
    } else {
        const oi = validMesh() orelse return false;
        if (!meshStart(oi)) return false;
    }
    const oi = objIndex() orelse return false;
    setView(cv, v, r, oi);
    lx = @floatFromInt(cv.toPx(x));
    ly = @floatFromInt(cv.toPx(y));
    hx = x;
    hy = y;
    oneDab(lx, ly);
    afterDabs();
    return true;
}

/// paint_drag: dabs every fifth of the radius.
pub fn drag(cv: *const gfx.Canvas, v: *const vp.View, r: Rect, x: i32, y: i32) void {
    hx = x;
    hy = y;
    if (!stroking or uv_stroke) return;
    const oi = objIndex() orelse return;
    setView(cv, v, r, oi);
    const px: f32 = @floatFromInt(cv.toPx(x));
    const py: f32 = @floatFromInt(cv.toPx(y));
    const dx = px - lx;
    const dy = py - ly;
    const d = @sqrt(dx * dx + dy * dy);
    const every = maxss(radius * ui_s120 / 120.0 * pf_spacing, 1);
    const n = stroke.dabsAlong(d, every);
    if (n == 0) return;
    var k: i32 = 1;
    while (k <= n) : (k += 1) {
        const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        oneDab(dx * t + lx, dy * t + ly);
    }
    lx = px;
    ly = py;
    afterDabs();
}

pub fn release() void {
    finishStroke();
}

// the UV editor ------------------------------------------------------------------------

/// pt_uv_dab: the texels within r (UV).
fn dabUv(u: f32, v: f32, r: f32) void {
    const im = validImage() orelse return;
    if (im != st_im) return;
    const e = &images.list[im];
    const w: f32 = @floatFromInt(e.img.w);
    const h: f32 = @floatFromInt(e.img.h);
    const cx = u * w;
    const cy = (1.0 - v) * h;
    const rx = r * w;
    const ry = r * h;
    var x0 = trunc32(cx - rx);
    var x1 = trunc32(cx + rx);
    var y0 = trunc32(cy - ry);
    var y1 = trunc32(cy + ry);
    if (x0 < 0) x0 = 0;
    if (x1 > @as(i32, @intCast(e.img.w - 1))) x1 = @intCast(e.img.w - 1);
    if (y0 < 0) y0 = 0;
    if (y1 > @as(i32, @intCast(e.img.h - 1))) y1 = @intCast(e.img.h - 1);
    var b = Box{};
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            var a = (@as(f32, @floatFromInt(x)) + 0.5 - cx) / rx;
            a = a * a;
            var c = (@as(f32, @floatFromInt(y)) + 0.5 - cy) / ry;
            c = c * c;
            const dist = a + c;
            if (dist >= 1.0) continue;
            const f = 1.0 - dist;
            blendTexel(e, &b, x, y, f * f * strength);
        }
    }
    merge(&b);
    images.touched(im);
    afterDabs();
}

/// paint_uv_press: a stroke here (texture paint only); false: the click is the editor's.
pub fn uvPress(u: f32, v: f32, r: f32) bool {
    if (!on or kind != .texture) return false;
    const im = validImage() orelse return false;
    if (!strokeStart(im)) return false;
    uv_stroke = true;
    dabUv(u, v, r);
    return true;
}

pub fn uvDrag(u: f32, v: f32, r: f32) void {
    if (stroking and uv_stroke) dabUv(u, v, r);
}

// for scripts, and the console that stands in for them ------------------------------------

/// paint_dab_world: the texels of the mesh's triangles whose surface lies within the
/// radius of the world point (no screen, no depth); one stroke in the history.
pub fn dabWorld(oi: usize, world: V3, radius0: f32) bool {
    const im = target(oi) orelse return false;
    finishStroke();
    const was_kind = kind;
    kind = .texture;
    defer kind = was_kind;
    if (!strokeStart(im)) return false;
    const me = scene.meshOfObj(oi) orelse return false;
    const e = &images.list[im];
    const a = arm.objMat(oi);
    const s = maxss(@sqrt(a[0] * a[0] + a[4] * a[4] + a[8] * a[8]), pf_tiny);
    const r = radius0 / s;
    const mi = arm.mInv(&a);
    const c = arm.xformPoint(&mi, world);
    const d0 = Dab{ .x = 0, .y = 0, .r = 0, .r2 = 0, .str = strength, .e = e, .w = @floatFromInt(e.img.w), .h = @floatFromInt(e.img.h), .iw = e.img.w, .me = me };
    var b = Box{};
    for (0..me.tris.len) |ti| {
        const uv = bake.triUvs(me, ti) orelse continue;
        worldTri(&d0, me, ti, &uv, c, r, &b);
    }
    merge(&b);
    images.touched(im);
    textureEnd();
    afterDabs();
    return true;
}

/// pt_tri_world: a triangle's texels within r of c (local): inside it, no bleed.
fn worldTri(d: *const Dab, me: *const scene.Mesh, ti: usize, uv: *const [6]f32, c: V3, r: f32, b: *Box) void {
    var t: [6]f32 = undefined;
    for (0..3) |k| {
        t[k * 2] = uv[k * 2] * d.w;
        t[k * 2 + 1] = (1.0 - uv[k * 2 + 1]) * d.h;
    }
    const a2 = (t[2] - t[0]) * (t[5] - t[1]) - (t[4] - t[0]) * (t[3] - t[1]);
    if (!(@abs(a2) > pf_tiny)) return;
    var x0 = trunc32(minss(minss(t[0], t[2]), t[4]));
    var x1 = trunc32(maxss(maxss(t[0], t[2]), t[4])) +% 1;
    var y0 = trunc32(minss(minss(t[1], t[3]), t[5]));
    var y1 = trunc32(maxss(maxss(t[1], t[3]), t[5])) +% 1;
    if (x0 < 0) x0 = 0;
    if (x1 > @as(i32, @intCast(d.e.img.w - 1))) x1 = @intCast(d.e.img.w - 1);
    if (y0 < 0) y0 = 0;
    if (y1 > @as(i32, @intCast(d.e.img.h - 1))) y1 = @intCast(d.e.img.h - 1);
    const tr = me.tris[ti];
    const p = [3]V3{ me.verts[tr[0]], me.verts[tr[1]], me.verts[tr[2]] };
    const r2 = r * r;
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        texel: while (x <= x1) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            var w: [3]f32 = undefined;
            for (0..3) |k| {
                const e = (k + 1) % 3;
                const f = (e + 1) % 3;
                const v = ((t[f * 2] - t[e * 2]) * (fy - t[e * 2 + 1]) - (t[f * 2 + 1] - t[e * 2 + 1]) * (fx - t[e * 2])) / a2;
                w[k] = v;
                if (!(v >= 0)) continue :texel;
            }
            var dist: f32 = 0;
            for (0..3) |i| {
                var q: f32 = 0;
                for (0..3) |k| q = w[k] * p[k][i] + q;
                q -= c[i];
                dist += q * q;
            }
            if (dist >= r2) continue;
            dist /= r2;
            const f = 1.0 - dist;
            blendTexel(d.e, b, x, y, f * f * strength);
        }
    }
}

/// vp_dab_world: the vertices within the radius of the world point (no screen), one
/// undo step. Weights: wp_dab_world, for that bone at that value.
pub fn dabWorldMesh(oi: usize, k: Kind, world: V3, radius0: f32) bool {
    finishStroke();
    const was_kind = kind;
    kind = k;
    defer kind = was_kind;
    if (!meshStart(oi)) return false;
    const me = meshNow(oi) orelse return false;
    const a = arm.objMat(oi);
    const r2 = radius0 * radius0;
    for (me.verts, 0..) |v, i| {
        const q = arm.xformPoint(&a, v);
        var dist: f32 = 0;
        for (0..3) |c| {
            const e = q[c] - world[c];
            dist += e * e;
        }
        if (dist >= r2) continue;
        dist /= r2;
        const f = 1.0 - dist;
        put(me, i, f * f * strength);
    }
    meshEnd();
    return true;
}

test "a texel past the triangle by more than the bleed stays clean" {
    var fl = [_][4]f32{.{ 0, 0, 0, 0 }};
    var b8 = [_][4]u8{.{ 0, 0, 0, 255 }};
    var e: images.Entry = .{ .img = .{ .w = 256, .h = 256, .px = fl[0..], .hdr = false }, .b8 = b8[0..] };
    var v = [_]V3{.{ 0, 0, 0 }};
    var tr = [_][3]u32{.{ 0, 0, 0 }};
    const me = std.mem.zeroInit(scene.Mesh, .{ .verts = v[0..], .tris = tr[0..] });
    const d = Dab{ .x = 0, .y = 0, .r = 1, .r2 = 1, .str = 1, .e = &e, .w = 256, .h = 256, .iw = 256, .me = &me };
    var p: Prep = undefined;
    const uv = [6]f32{ 0.5, 0.5, 0.75, 0.5, 0.5, 0.75 };
    try std.testing.expect(setup(&d, &p, &uv));
    p.cam = .{ .{ 0, 0, 5 }, .{ 1, 0, 5 }, .{ 0, 1, 5 } };
    near = 0.05;
    cam_f = 100;
    // (the block left of it, inside the bleed it is not)
    try std.testing.expect(blockClean(&d, &p, 40, 40, 70, 70));
    // a block over it, the brush over it: not clean
    try std.testing.expect(!blockClean(&.{ .x = cam_cx + 10, .y = cam_cy - 10, .r = 50, .r2 = 2500, .str = 1, .e = &e, .w = 256, .h = 256, .iw = 256, .me = &me }, &p, 130, 80, 160, 120));
    // zero area: nothing
    const flat = [6]f32{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5 };
    try std.testing.expect(!setup(&d, &p, &flat));
}

test "the colours blend towards the brush, opaque" {
    col = 0xff102030;
    var c: u32 = 0xffffffff;
    blendVertex(&c, 1);
    try std.testing.expectEqual(@as(u32, 0xff102030), c);
    col = 0xffd04020;
}
