// The UV editor area (uved.s), a Zui part drawn with Zui's painter. Shows the active mesh's UV layout (edit object
// first): the unit square with a grid, every polygon's UV edges, selected islands
// lit. Middle drag pans, the wheel zooms, Home fits. A click selects the island
// under the pointer (Shift adds), A all / none; G, S, R move, scale and rotate the
// selected islands with the pointer (a click or Enter keeps it, right click or Esc
// puts it back; one undo step). D cycles a distortion heat map over the triangles:
// area (blue: UV smaller than its share of the surface, red: larger) and angle
// (green to red). The header gives the islands and the texel density a 1024 px
// map gets per metre.
//
// The view, the selection and the heat map are the editor's, not per area, as in
// the original. The transform works on a copy of the mesh (uv.cow): what a step of
// the history holds stays as it is, and a cancelled transform leaves a step that
// changes nothing, as the original's operator does.
const std = @import("std");
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const scene = @import("scene.zig");
const uv = @import("uv.zig");
const ops = @import("ops.zig");
const cat = @import("catalog.zig");
const menus = @import("menus.zig");
const images = @import("images.zig");
const material = @import("material.zig");
const sg = @import("shgraph.zig");
const bake = @import("bake.zig");
const paint = @import("paint.zig");
const wl = @import("wayland.zig");
const theme = @import("theme.zig");
const A = @import("alloc.zig").A;
const zui = @import("zui");
const host = @import("zuihost.zig");

const Rect = gfx.Rect;
const Mesh = scene.Mesh;

const UV_HDR = 18; // the header line (logical px)
const COL_SEL: u32 = 0xffa233;

const heat_names = [_][]const u8{ "no heat map", "area distortion", "angle distortion" };
const heat_lbl = [_][]const u8{ "No heat map", "Area distortion", "Angle distortion" };

// the view: the UV at the centre, zoom on the fitted size
var cx: f32 = 0.5;
var cy: f32 = 0.5;
var zoomf: f32 = 1;
/// 0 off, 1 area, 2 angle
pub var heat: u32 = 0;
/// transform: 0 none, 1 G, 2 S, 3 R
pub var tm: u32 = 0;
var panning = false;
var painting = false; // a texture paint stroke in UV space
// per loop: selected, for this object and loop count
var sel: []u8 = &.{};
var sel_oid: u32 = 0;
// the last drawn body, the scale, the centre on screen
var rx: i32 = 0;
var ry: i32 = 0;
var rw: i32 = 0;
var rh: i32 = 0;
var ue_s: f32 = 1;
var ox: f32 = 0;
var oy: f32 = 0;
// transform / pan start (pointer), pivot
var px0: i32 = 0;
var py0: i32 = 0;
var pivu: f32 = 0;
var pivv: f32 = 0;
var cx0: f32 = 0;
var cy0: f32 = 0;
var orig: [][2]f32 = &.{};
var tm_mi: u16 = 0;
var tm_oi: usize = 0;
// what the header says, for the mesh it was worked out on
var stat_serial: u32 = 0;
var stat_islands: i32 = 0;

fn view() void {
    const side = @min(rw, rh - UV_HDR);
    ue_s = @max(@as(f32, @floatFromInt(side)) * 0.9 * zoomf, 1);
    ox = @as(f32, @floatFromInt(rw)) * 0.5 + @as(f32, @floatFromInt(rx));
    oy = @as(f32, @floatFromInt(rh - UV_HDR)) * 0.5 + @as(f32, @floatFromInt(ry + UV_HDR));
}

fn toX(u: f32) f32 {
    return (u - cx) * ue_s + ox;
}
fn toY(v: f32) f32 {
    return oy - (v - cy) * ue_s;
}
fn toU(x: i32) f32 {
    return (@as(f32, @floatFromInt(x)) - ox) / ue_s + cx;
}
fn toV(y: i32) f32 {
    return (oy - @as(f32, @floatFromInt(y))) / ue_s + cy;
}

/// cvtss2si: to the nearest, halves to even; whatever a file or a zoom says stays
/// on the int range.
fn nearest(x: f32) i32 {
    if (std.math.isNan(x)) return 0;
    const c = std.math.clamp(x, -1.0e9, 1.0e9);
    var r = @floor(c + 0.5);
    if (r - c == 0.5 and @mod(r, 2) != 0) r -= 1;
    return @intFromFloat(r);
}

/// The target and its mesh with UVs.
fn target() ?struct { oi: usize, me: *const Mesh } {
    const oi = uv.target() orelse return null;
    const me = scene.meshOfObj(oi) orelse return null;
    if (me.uv.len == 0 or me.uv.len != me.loops.len) return null;
    return .{ .oi = oi, .me = me };
}

/// Its loops' selection (made, empty, for another object or loop count).
fn selection(oi: usize, me: *const Mesh) ?[]u8 {
    const oid = scene.objects[oi].oid;
    if (oid == sel_oid and sel.len == me.loops.len + 1) return sel[0..me.loops.len];
    if (sel.len > 0) A.free(sel);
    sel = &.{};
    const s = A.alloc(u8, me.loops.len + 1) catch return null;
    @memset(s, 0);
    sel = s;
    sel_oid = oid;
    return sel[0..me.loops.len];
}

const Colors = struct { square: u32, grid: u32, edge: u32 };
fn colors() Colors {
    const T = struct { id: []const u8, c: Colors };
    const tab = [_]T{
        .{ .id = "light", .c = .{ .square = 0xe4e7eb, .grid = 0xcdd2d9, .edge = 0x464c57 } },
        .{ .id = "contrast", .c = .{ .square = 0x1c1c1c, .grid = 0x5c5c5c, .edge = 0xffffff } },
        .{ .id = "honey", .c = .{ .square = 0x2e271d, .grid = 0x3d3427, .edge = 0xd8c8a8 } },
        .{ .id = "graphite", .c = .{ .square = 0x353535, .grid = 0x444444, .edge = 0xc0c0c0 } },
        .{ .id = "nord", .c = .{ .square = 0x333a47, .grid = 0x3b4252, .edge = 0xd8dee9 } },
        .{ .id = "solarized", .c = .{ .square = 0x073642, .grid = 0x0e4a5a, .edge = 0x93a1a1 } },
        .{ .id = "solarized-light", .c = .{ .square = 0xf2ecd8, .grid = 0xddd6c1, .edge = 0x586e75 } },
        .{ .id = "dracula", .c = .{ .square = 0x2c2e3b, .grid = 0x3a3c4e, .edge = 0xe0e0e8 } },
    };
    for (tab) |t| {
        if (std.mem.eql(u8, t.id, theme.base.id)) return t.c;
    }
    return .{ .square = 0x2c3038, .grid = 0x3a3f48, .edge = 0xb8bcc4 };
}

/// A UV line. Lines wholly off the area go first; one that reaches far past it
/// (a big zoom) is cut to the area, as a line of a million pixels is no use.
var Z: *zui.Ui = undefined;

fn seg(x0: i32, y0: i32, x1: i32, y1: i32, col: u32) void {
    const f = struct {
        fn v(a: i32) f32 {
            return @as(f32, @floatFromInt(a)) + 0.5;
        }
    }.v;
    Z.painter().line(.{ .x = f(x0), .y = f(y0) }, .{ .x = f(x1), .y = f(y1) }, host.col(col), 1);
}

fn line(clip: Rect, a0: f32, b0: f32, a1: f32, b1: f32, col: u32) void {
    const x0 = nearest(toX(a0));
    const y0 = nearest(toY(b0));
    const x1 = nearest(toX(a1));
    const y1 = nearest(toY(b1));
    if ((x0 < clip.x and x1 < clip.x) or (y0 < clip.y and y1 < clip.y)) return;
    if ((x0 >= clip.right() and x1 >= clip.right()) or (y0 >= clip.bottom() and y1 >= clip.bottom())) return;
    const lim = 16384;
    if (@abs(x0) <= lim and @abs(y0) <= lim and @abs(x1) <= lim and @abs(y1) <= lim) return seg(x0, y0, x1, y1, col);
    // Liang-Barsky
    const fx0: f32 = @floatFromInt(x0);
    const fy0: f32 = @floatFromInt(y0);
    const dx: f32 = @as(f32, @floatFromInt(x1)) - fx0;
    const dy: f32 = @as(f32, @floatFromInt(y1)) - fy0;
    var t0: f32 = 0;
    var t1: f32 = 1;
    const ps = [4]f32{ -dx, dx, -dy, dy };
    const qs = [4]f32{ fx0 - @as(f32, @floatFromInt(clip.x)), @as(f32, @floatFromInt(clip.right())) - fx0, fy0 - @as(f32, @floatFromInt(clip.y)), @as(f32, @floatFromInt(clip.bottom())) - fy0 };
    for (ps, qs) |p, q| {
        if (p == 0) {
            if (q < 0) return;
            continue;
        }
        const r = q / p;
        if (p < 0) t0 = @max(t0, r) else t1 = @min(t1, r);
    }
    if (t0 > t1) return;
    seg(nearest(fx0 + dx * t0), nearest(fy0 + dy * t0), nearest(fx0 + dx * t1), nearest(fy0 + dy * t1), col);
}

/// ue_tri: three positions and the UVs.
fn tri(me: *const Mesh, ti: usize, p: *[3]m.V3) [6]f32 {
    const t = me.tris[ti];
    p.* = .{ me.verts[t[0]], me.verts[t[1]], me.verts[t[2]] };
    return bake.triUvs(me, ti).?;
}

/// ue_density: 1024 sqrt(UV area / surface area)
fn density(me: *const Mesh) f32 {
    var a3: f32 = 0;
    var a2: f32 = 0;
    var p: [3]m.V3 = undefined;
    for (0..me.tris.len) |ti| {
        const u = tri(me, ti, &p);
        a3 += uv.area3(&p);
        a2 += @abs(uv.area2(&u));
    }
    return @sqrt(a2 / @max(a3, 1.0e-12)) * 1024;
}

/// t -1 .. 0 .. 1, beyond clamped: blue - green - red
pub fn heatColour(t0: f32) u32 {
    const t = @min(@max(t0, -1.0), 1.0);
    if (t >= 0) {
        const a: u32 = @intFromFloat(t * 210);
        return (a << 16) | ((210 - a) << 8) | 0x202020;
    }
    const a: u32 = @intFromFloat((0 - t) * 210);
    return ((210 - a) << 8) | a | 0x202020;
}

/// A triangle filled, either winding (Zui's painter; it clips).
fn fillTri(q: *const [6]f32, col: u32) void {
    for (q) |v| if (!(v > -1.0e7 and v < 1.0e7)) return;
    Z.painter().polygon(&.{ .{ .x = q[0], .y = q[1] }, .{ .x = q[2], .y = q[3] }, .{ .x = q[4], .y = q[5] } }, host.col(col));
}

/// ue_heat_draw: each triangle filled by its distortion.
fn heatDraw(me: *const Mesh) void {
    var a3: f32 = 0;
    var a2: f32 = 0;
    var p: [3]m.V3 = undefined;
    for (0..me.tris.len) |ti| {
        const u = tri(me, ti, &p);
        a3 += uv.area3(&p);
        a2 += @abs(uv.area2(&u));
    }
    for (0..me.tris.len) |ti| {
        const u = tri(me, ti, &p);
        var t: f32 = undefined;
        if (heat == 2) {
            var w: f32 = 0; // the largest corner error, 30 degrees: full red
            for (0..3) |k| w = @max(@abs(uv.angle2(k, &u) - uv.angle3(k, &p)), w);
            t = w * 57.29578 / 30;
        } else {
            // log2(uv share / surface share), +-1 octave: full colour
            const s3 = @max(uv.area3(&p) / a3, 1.0e-12);
            const s2 = @max(@abs(uv.area2(&u)) / a2, 1.0e-12);
            t = @floatCast(std.math.log2(@as(f64, s2 / s3)));
        }
        const c = heatColour(t);
        var s: [6]f32 = undefined;
        for (0..3) |k| {
            s[k * 2] = toX(u[k * 2]);
            s[k * 2 + 1] = toY(u[k * 2 + 1]);
        }
        fillTri(&s, c);
    }
}

/// paint_target: the 8-bit image of the first image node of its material.
const paintImage = paint.imageOf;

// The paint image as Zui draws it: its 8-bit pixels as ARGB, made again
// when the image changes.
var zpx: []u32 = &.{};
var zimg: zui.Image = undefined;
var z_im: usize = std.math.maxInt(usize);
var z_ver: u32 = 0;

/// ue_image_draw: the image over the unit square (nearest texel).
fn imageDraw(im: usize) void {
    const e = &images.list[im];
    const n = @as(usize, e.img.w) * e.img.h;
    if (n == 0 or e.b8.len < n) return;
    if (z_im != im or z_ver != e.version or zpx.len != n) {
        if (zpx.len != n) {
            if (zpx.len > 0) A.free(zpx);
            zpx = A.alloc(u32, n) catch {
                zpx = &.{};
                return;
            };
        }
        for (zpx, e.b8[0..n]) |*d, b| d.* = 0xff000000 | @as(u32, b[0]) << 16 | @as(u32, b[1]) << 8 | b[2];
        zimg = .initArgb(zpx, e.img.w, e.img.h);
        zimg.is_opaque = true;
        z_im = im;
        z_ver = e.version;
    }
    const x0 = toX(0);
    const y1 = toY(1);
    if (!(@abs(x0) < 1.0e7 and @abs(y1) < 1.0e7 and ue_s < 1.0e7)) return;
    Z.painter().image(&zimg, .{ .x = x0, .y = y1, .w = ue_s, .h = ue_s }, .{ .filter = .nearest });
}

pub fn body(i: i16, r: Rect) void {
    const th = ui.th;
    rx = r.x;
    ry = r.y;
    rw = r.w;
    rh = r.h;
    view();
    Z = host.beginPart("uved", @intCast(i), r) orelse return;
    defer host.endPart(Z);
    Z.drawRect(.{ .rect = host.zr(r), .fill = host.col(th.pane_bg) });
    input(r);
    const clip = r;
    const col = colors();
    const x0 = toX(0);
    const y0 = toY(0);
    const x1 = toX(1);
    const y1 = toY(1);
    if (@abs(x0) < 1.0e7 and @abs(y1) < 1.0e7 and @abs(x1) < 1.0e7 and @abs(y0) < 1.0e7) {
        Z.drawRect(.{ .rect = .{ .x = @round(x0), .y = @round(y1), .w = @round(x1) - @round(x0), .h = @round(y0) - @round(y1) }, .fill = host.col(col.square) });
    }
    for (0..9) |k| {
        const f = @as(f32, @floatFromInt(k)) * 0.125;
        line(clip, f, 0, f, 1, col.grid);
        line(clip, 0, f, 1, f, col.grid);
    }
    if (target()) |t| {
        drawMesh(clip, t.oi, t.me, col.edge);
    } else noUvs(r);
}

fn noUvs(r: Rect) void {
    const s = "UV editor: a mesh with UVs (U unwraps it in edit mode)";
    Z.drawText(.{ .x = @floatFromInt(r.x + 8), .y = @floatFromInt(r.y + 2) }, host.col(ui.th.text), s);
    ui.record("info", s, .{ .x = r.x + 8, .y = r.y + 2, .w = r.w - 16, .h = 16 }, true);
}

fn head(me: *const Mesh, b: []u8) []const u8 {
    if (stat_serial != me.serial) {
        stat_serial = me.serial;
        stat_islands = @intFromFloat(uv.stat(me, .islands));
    }
    const d = @min(density(me), 2.0e9); // (NaN: 0)
    return std.fmt.bufPrint(b, "UV: {d} islands   texel density {d} px/m (1024 px)   D: {s}", .{ stat_islands, if (d == d) @as(i64, @intFromFloat(d)) else 0, heat_names[heat] }) catch "";
}

fn drawMesh(clip: Rect, oi: usize, me: *const Mesh, edge: u32) void {
    if (paintImage(oi)) |im| imageDraw(im);
    const s = selection(oi, me);
    if (heat != 0) heatDraw(me);
    const po = me.poff;
    for (0..po.len - 1) |p| {
        const a = po[p];
        const e = po[p + 1];
        var l = a;
        while (l < e) : (l += 1) {
            const n = if (l + 1 < e) l + 1 else a;
            const c = if (s != null and s.?[l] != 0) COL_SEL else edge;
            line(clip, me.uv[l][0], me.uv[l][1], me.uv[n][0], me.uv[n][1], c);
        }
    }
    var b: [120]u8 = undefined;
    const h = head(me, &b);
    Z.drawText(.{ .x = @floatFromInt(rx + 8), .y = @floatFromInt(ry + 2) }, host.col(ui.th.text), h);
    ui.record("info", h, .{ .x = rx + 8, .y = ry + 2, .w = rw - 16, .h = 16 }, true);
}

// --- the header ------------------------------------------------------------------

const heat_items = [_]zui.Choice{ .{ .label = heat_lbl[0] }, .{ .label = heat_lbl[1] }, .{ .label = heat_lbl[2] } };

/// uv_header_tools: Unwrap, Pack, Select All, the heat map, Fit (a Zui part).
pub fn header(i: i16, r: Rect) void {
    const bkit = @import("bkit.zig");
    const z = host.beginPart("uved.head", @intCast(i), .{ .x = r.x, .y = r.y + 1, .w = r.w, .h = 22 }) orelse return;
    defer host.endPart(z);
    z.beginHorizontal(.{ .spacing = 6 });
    defer z.endHorizontal();
    const items = [_]struct { w: f32, label: []const u8, id: []const u8 }{ .{ .w = 70, .label = "Unwrap", .id = "uv.unwrap" }, .{ .w = 54, .label = "Pack", .id = "uv.pack" }, .{ .w = 84, .label = "Select All", .id = "uv.select_all" } };
    for (items) |it| _ = bkit.opButton(z, it.id, .{ .label = it.label, .width = .px(it.w), .height = .px(22) });
    var h: usize = heat;
    const d = z.dropdown("##heat", &h, &heat_items, .{ .width = .px(140) });
    z.tooltipRich(d, .{ .title = "Heat map", .shortcut = "D", .body = "Colour the islands by how much they are stretched" });
    if (d.changed) {
        heat = @intCast(h);
        app.dirty = true;
    }
    _ = bkit.opButton(z, "uv.view_fit", .{ .label = "Fit", .width = .px(40), .height = .px(22) });
}

// --- input -----------------------------------------------------------------------

var last_mx: i32 = 0;
var last_my: i32 = 0;

/// The pointer over the body: the wheel zooms, a middle drag pans, a press
/// paints (texture paint) or selects the island under it.
fn input(r: Rect) void {
    const it = Z.interact(Z.id("##uv"), host.zr(r));
    const in = &Z.input;
    const pmx: i32 = @intFromFloat(in.mouse_pos.x);
    const pmy: i32 = @intFromFloat(in.mouse_pos.y);
    defer {
        last_mx = pmx;
        last_my = pmy;
    }
    if (it.hovered and in.scroll.y != 0 and tm == 0) {
        zoomf *= if (in.scroll.y > 0) @as(f32, 1.15) else 0.8695652;
        if (!(zoomf > 0) or !std.math.isFinite(zoomf)) zoomf = 1;
        view();
        app.dirty = true;
    }
    if (it.hovered and in.mouse_pressed.contains(.middle)) {
        panning = true;
        px0 = pmx;
        py0 = pmy;
        cx0 = cx;
        cy0 = cy;
    }
    if (it.pressed) {
        const p = in.press_pos.get(.left);
        const x: i32 = @intFromFloat(p.x);
        const y: i32 = @intFromFloat(p.y);
        if (paint.on and paint.uvPress(toU(x), toV(y), paint.radius / ue_s)) {
            painting = true; // (texture paint: a stroke here)
        } else click(x, y);
        app.dirty = true;
    }
    if (painting) {
        if (it.held) {
            if (pmx != last_mx or pmy != last_my) paint.uvDrag(toU(pmx), toV(pmy), paint.radius / ue_s);
        } else {
            painting = false;
            paint.release();
        }
    }
    if (panning) {
        if (in.mouse_down.contains(.middle)) {
            cx = cx0 - @as(f32, @floatFromInt(pmx - px0)) / ue_s;
            cy = cy0 + @as(f32, @floatFromInt(pmy - py0)) / ue_s;
            app.dirty = true;
            view();
        } else panning = false;
    }
}

fn inTri(q: *const [6]f32, u: f32, v: f32) bool {
    var pos = false;
    var neg = false;
    for (0..3) |k| {
        const a = k * 2;
        const b = (k + 1) % 3 * 2;
        const e = (q[b] - q[a]) * (v - q[a + 1]) - (q[b + 1] - q[a + 1]) * (u - q[a]);
        if (!(e < 0)) pos = true else neg = true;
    }
    return !(pos and neg);
}

/// ue_click: the island under the pointer selected (Shift: added to the
/// selection; nothing there and no Shift: none).
fn click(x: i32, y: i32) void {
    const u = toU(x);
    const v = toV(y);
    const t = target() orelse return;
    const s = selection(t.oi, t.me) orelse return;
    if (!ui.shift()) @memset(s, 0);
    const me = t.me;
    for (0..me.tris.len) |ti| {
        const q = bake.triUvs(me, ti).?;
        if (inTri(&q, u, v)) {
            uv.selectIsland(me, me.tri_poly[ti], s);
            break;
        }
    }
    app.dirty = true;
}

pub fn opAll() void {
    const t = target() orelse return;
    const s = selection(t.oi, t.me) orelse return;
    var any: u8 = 0;
    for (s) |c| any |= c;
    @memset(s, @intFromBool(any == 0));
    app.dirty = true;
}

pub fn opHeat() void {
    heat = (heat + 1) % 3;
    app.dirty = true;
}

pub fn opFit() void {
    cx = 0.5;
    cy = 0.5;
    zoomf = 1;
    app.dirty = true;
}

/// do_ue_tm: from the pointer as it is.
fn begin(mode: u32) void {
    const t = target() orelse return;
    const s = selection(t.oi, t.me) orelse return;
    if (std.mem.indexOfNone(u8, s, &.{0}) == null) return; // (nothing to transform)
    const me = uv.cow(t.oi) orelse return;
    if (orig.len > 0) A.free(orig);
    orig = A.dupe([2]f32, me.uv) catch &.{};
    if (orig.len != me.uv.len) {
        orig = &.{};
        return;
    }
    tm_oi = t.oi;
    tm_mi = scene.objects[t.oi].mesh.?;
    // pivot: the selection's box centre
    var lo = [2]f32{ 3.0e38, 3.0e38 };
    var hi = [2]f32{ -3.0e38, -3.0e38 };
    for (me.uv, s) |q, f| {
        if (f == 0) continue;
        for (0..2) |c| {
            lo[c] = @min(lo[c], q[c]);
            hi[c] = @max(hi[c], q[c]);
        }
    }
    pivu = (lo[0] + hi[0]) * 0.5;
    pivv = (lo[1] + hi[1]) * 0.5;
    px0 = ui.mx;
    py0 = ui.my;
    tm = mode;
    app.dirty = true;
}
pub fn opGrab() void {
    begin(1);
}
pub fn opScale() void {
    begin(2);
}
pub fn opRotate() void {
    begin(3);
}

/// The mesh the transform works on, while it is still the object's.
fn tmMesh() ?*Mesh {
    if (tm_oi >= scene.count or scene.objects[tm_oi].mesh != tm_mi) return null;
    const me = if (scene.meshes[tm_mi]) |*x| x else return null;
    if (me.uv.len != orig.len or sel.len != orig.len + 1) return null;
    return me;
}

/// ue_tm_move: the selected loops from their start UVs: moved by the pointer,
/// scaled / turned about the pivot.
pub fn motion(x: i32, y: i32) void {
    if (tm == 0) return;
    const me = tmMesh() orelse {
        tm = 0;
        return;
    };
    view();
    const fi = struct {
        fn f(k: i32) f32 {
            return @floatFromInt(k);
        }
    }.f;
    const pvx = toX(pivu);
    const pvy = toY(pivv);
    // the pointer's start and now, from the pivot (screen, y up)
    const ax = fi(px0) - pvx;
    const ay = pvy - fi(py0);
    const bx = fi(x) - pvx;
    const by = pvy - fi(y);
    var p0: f32 = undefined;
    var p1: f32 = undefined;
    switch (tm) {
        1 => {
            p0 = (bx - ax) / ue_s;
            p1 = (by - ay) / ue_s;
        },
        2 => {
            const la = @max(@sqrt(ax * ax + ay * ay), 1.0);
            p0 = @sqrt(bx * bx + by * by) / la;
            p1 = 0;
        },
        else => {
            const dot = ax * bx + ay * by;
            const crs = ax * by - ay * bx;
            const l = @max(@sqrt(dot * dot + crs * crs), 1.0e-12);
            p0 = dot / l;
            p1 = crs / l;
        },
    }
    for (me.uv, orig, sel[0..orig.len]) |*o, q, f| {
        if (f == 0) continue;
        if (tm == 1) {
            o.* = .{ q[0] + p0, q[1] + p1 };
            continue;
        }
        const u = q[0] - pivu;
        const v = q[1] - pivv;
        if (tm == 2) {
            o.* = .{ u * p0 + pivu, v * p0 + pivv };
        } else o.* = .{ (u * p0 - v * p1) + pivu, (v * p0 + u * p1) + pivv };
    }
    app.dirty = true;
}

/// ue_tm_end. Kept or put back, the step stays (the original's operator pushed
/// it before it started).
pub fn end(back: bool) void {
    if (tm == 0) return;
    tm = 0;
    app.dirty = true;
    const me = tmMesh() orelse return;
    if (back) @memcpy(me.uv, orig) else app.log("  uv: islands transformed", .{});
    // what shows the UVs looks again, back or not: a frame of the drag may have
    // gone into a cache, under this mesh's number
    scene.meshes_made +%= 1;
    me.serial = scene.meshes_made;
}

/// A press while transforming: left keeps, the others put it back.
pub fn press(button: u32) void {
    end(button != wl.BTN_LEFT);
}

/// A transform takes every key: Enter keeps, Esc puts back.
pub fn key(k: u32) void {
    if (k == ui.KEY.ESC) end(true) else if (k == ui.KEY.ENTER) end(false);
    app.dirty = true;
}

pub fn wheelInTransform(v: f32) void {
    zoomf *= if (v < 0) @as(f32, 1.15) else 0.8695652;
    app.dirty = true;
}

/// For the tests: what the view and the selection are.
pub fn dump(w: *std.Io.Writer) void {
    var n: usize = 0;
    for (sel) |c| n += c;
    w.print("uved view {d} {d} {d} heat {d} tm {d} selected {d}\n", .{ cx, cy, zoomf, heat, tm, n }) catch {};
    if (target()) |t| {
        var b: [120]u8 = undefined;
        w.print("line {s}\n", .{head(t.me, &b)}) catch {};
    }
}
