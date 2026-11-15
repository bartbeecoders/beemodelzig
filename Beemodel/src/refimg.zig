// Reference images (refimg.s): a photo or drawing to model over.
//
// object.add_reference <file> loads the image and adds a flat object at the 3D
// cursor, square to the view's nearest axis, at the image's aspect ratio. It is
// a 2 x 2 plane flagged REFIMG, left out of renders, with a material of its own
// that carries the image (an image node) and the opacity (its alpha). The
// rasterizer leaves it out; draw paints it in every shading mode, in screen
// space: the quad projected, its pixels mapped back to the image
// (perspective-correct), blended at the opacity, behind the scene (where no
// object is) or in front of it. Object.ref holds the original's flag bits:
//   FRONT  in front of the scene (else behind)
//   ORTHO  only in orthographic views
//   AXIS   only when seen square-on
//   BACK   seen from behind too (else from the front only)
// It is picked by its outline (pickBounds).
const std = @import("std");
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const images = @import("images.zig");
const image = @import("image.zig");
const vp = @import("viewport.zig");
const jobs = @import("jobs.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const Rect = gfx.Rect;
const A = std.heap.page_allocator;

pub const REFIMG: u32 = 0x10000;
pub const FRONT: u32 = 0x20000;
pub const ORTHO: u32 = 0x40000;
pub const AXIS: u32 = 0x80000;
pub const BACK: u32 = 0x100000;
pub const MASK: u32 = REFIMG | FRONT | ORTHO | AXIS | BACK;

// graph.s, in Material.graph (after the 128-byte file part)
const GR_NODES = 32;
const GR_PINS = 3616 - 128;
const NODE_SZ = 72;
const ND_P = 52;
const GR_MAXN = 48;

const CORNERS = [4]m.V3{ .{ -1, 0, -1 }, .{ 1, 0, -1 }, .{ 1, 0, 1 }, .{ -1, 0, 1 } };
const UVS = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
const NEAR: f32 = 0.01;
const SQUARE: f32 = 0.985; // square-on: the normal within about 10 degrees

/// What ref_add_path leaves: the last image's pixels.
pub var last_w: u32 = 0;
pub var last_h: u32 = 0;

fn nameTaken(s: []const u8) bool {
    for (scene.objects[0..scene.count]) |*o| {
        if (std.mem.eql(u8, o.name(), s)) return true;
    }
    return false;
}

fn uniqueName(o: *scene.Object, want: []const u8) void {
    o.setName(want);
    if (!nameTaken(o.name())) return;
    const base = o.name();
    var keep: [32]u8 = undefined;
    const bn = @min(base.len, 27);
    @memcpy(keep[0..bn], base[0..bn]);
    var k: u32 = 1;
    while (k < 10000) : (k += 1) {
        var b: [40]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "{s}.{d:0>3}", .{ keep[0..bn], k }) catch break;
        if (!nameTaken(s)) {
            o.setName(s);
            return;
        }
    }
}

/// The object gets a material of its own: "Reference <image>", an image node
/// into the base colour.
fn makeMaterial(ii: usize, o: *scene.Object) void {
    var b: [100]u8 = undefined;
    const nm = images.nameOf(ii);
    const stem = if (std.mem.lastIndexOfScalar(u8, nm, '.')) |d| nm[0..d] else nm;
    const mi = material.new(std.fmt.bufPrint(&b, "Reference {s}", .{stem[0..@min(stem.len, 80)]}) catch "Reference") orelse return;
    const g = &material.list[mi].graph;
    std.mem.writeInt(u32, g[0..4], 1, .little);
    std.mem.writeInt(u32, g[GR_NODES..][0..4], 1, .little); // an image node
    const p0: f32 = @floatFromInt(ii + 1);
    const p1: f32 = 1;
    std.mem.writeInt(u32, g[GR_NODES + ND_P..][0..4], @bitCast(p0), .little);
    std.mem.writeInt(u32, g[GR_NODES + ND_P + 4..][0..4], @bitCast(p1), .little);
    std.mem.writeInt(u32, g[GR_PINS..][0..4], 1, .little); // it feeds the base colour
    o.mat = @intCast(mi + 1);
    material.version +%= 1;
}

pub const Added = struct { index: usize, aspect: f32 };

/// A reference from an image file, not placed: at the origin, flat, 2 x 2, not
/// selected. Null: the image did not load.
pub fn addPath(path: []const u8, name: ?[]const u8) ?Added {
    if (scene.count >= scene.max_objects) return null;
    const ii = images.load(path) catch return null;
    const img = &images.list[ii].img;
    last_w = img.w;
    last_h = img.h;
    const verts = [4]m.V3{ .{ -1, 0, -1 }, .{ 1, 0, -1 }, .{ -1, 0, 1 }, .{ 1, 0, 1 } };
    const mi = scene.addMesh(&verts, &[2]u32{ 0, 4 }, &[4]u32{ 0, 2, 3, 1 }) orelse return null;
    var o = scene.Object{ .kind = .mesh, .mesh = mi, .color = 0x808080, .render = false, .ref = REFIMG | BACK };
    uniqueName(&o, name orelse "Reference");
    makeMaterial(ii, &o);
    scene.objects[scene.count] = o;
    scene.stamp(scene.count);
    scene.count += 1;
    return .{ .index = scene.count - 1, .aspect = @as(f32, @floatFromInt(img.w)) / @as(f32, @floatFromInt(img.h)) };
}

/// Its plane (normal +Y, the image's top at its -Z) turned to face a view
/// looking along fwd, square to the nearest axis, the image upright.
pub fn faceView(o: *scene.Object, fwd: m.V3) void {
    o.rot = .{ 0, 0, 0 };
    const ax = @abs(fwd[0]);
    const ay = @abs(fwd[1]);
    const az = @abs(fwd[2]);
    if (ay >= ax and ay >= az) {
        if (fwd[1] >= 0) o.rot[0] = 180; // looking up: over
        return;
    }
    o.rot[0] = 90; // a side view: stood up, then turned about y to face it
    if (ax >= az) {
        o.rot[1] = if (fwd[0] < 0) 90 else -90;
    } else if (fwd[2] >= 0) o.rot[1] = 180;
}

fn pathArg(buf: []u8, a: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, a, " \"");
    if (t.len == 0) return null;
    return @import("files.zig").expandHome(buf, t);
}

fn addFile(path: []const u8) void {
    const added = addPath(path, null) orelse return app.log("  reference image: could not load it", .{});
    const o = &scene.objects[added.index];
    o.loc = scene.cursor;
    const vi = app.viewportArea();
    const v: vp.View = if (vi >= 0) app.N(vi).view else .{};
    const s = v.dist * 0.33; // as big as a third of the view
    o.scl = .{ s * added.aspect, 1, s };
    const c = vp.Cam.init(&v, .{ .w = 800, .h = 600 });
    // (the original's fwd is only set when a viewport draws - zero in a run
    // without a window (--eval, --run): it lies flat, turned over)
    faceView(o, if (vp.drawn) c.fwd else .{ 0, 0, 0 });
    scene.selectOnly(added.index);
    undo.label("Reference Image");
    app.dirty = true;
}

/// object.add_reference <image file>
pub fn opAdd() void {
    var pb: [1024]u8 = undefined;
    if (ops.arg.len == 0) {
        @import("filebrowser.zig").show(.open, "Reference Image", ".png .jpg .jpeg .hdr", "", addFile);
        return;
    }
    addFile(pathArg(&pb, ops.arg) orelse return app.log("  reference image: could not load it", .{}));
}

pub const Of = struct { ii: usize, opacity: f32 };

/// Its image (the first image node of its material) and opacity.
pub fn imageOf(o: *const scene.Object) ?Of {
    const ma = material.of(o) orelse return null;
    const g = &ma.graph;
    const n = @min(ma.nodes(), GR_MAXN);
    for (0..n) |k| {
        const at = GR_NODES + k * NODE_SZ;
        if (std.mem.readInt(u32, g[at..][0..4], .little) & 0x7fffffff != 1) continue;
        const p: f32 = @bitCast(std.mem.readInt(u32, g[at + ND_P..][0..4], .little));
        if (!std.math.isFinite(p) or p < 1 or p > 1e6) continue;
        const ii: usize = @intFromFloat(p - 1);
        return if (ii < images.count) .{ .ii = ii, .opacity = ma.alpha } else null;
    }
    return null;
}

// --- drawing -----------------------------------------------------------------------

// the images as the screen shows them, made when first drawn
var tex: [images.MAX][]u32 = @splat(&.{});
var tex_ver: [images.MAX]u32 = @splat(0);

fn toByte(v0: f32) u32 {
    const v = if (std.math.isFinite(v0)) std.math.clamp(v0, 0, 1) else 0;
    const s = if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
    return @intFromFloat(s * 255 + 0.5);
}

/// HDR: roughly sRGB, opaque (rt_texel).
fn hdrByte(v0: f32) u32 {
    const v = if (std.math.isFinite(v0)) std.math.clamp(v0, 0, 1) else 0;
    return @intFromFloat(@sqrt(v) * 255);
}

fn texels(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const t: *const struct { img: *const image.Image, out: []u32 } = @ptrCast(@alignCast(ctx));
    const img = t.img;
    for (lo..hi) |i| {
        const p = img.px[i];
        t.out[i] = if (img.hdr)
            0xff000000 | hdrByte(p[0]) << 16 | hdrByte(p[1]) << 8 | hdrByte(p[2])
        else
            (@as(u32, @intFromFloat(std.math.clamp(p[3], 0, 1) * 255 + 0.5)) << 24) | toByte(p[0]) << 16 | toByte(p[1]) << 8 | toByte(p[2]);
    }
}

fn texOf(ii: usize) ?[]const u32 {
    const e = &images.list[ii];
    if (tex_ver[ii] == e.version and tex[ii].len == e.img.px.len) return tex[ii];
    if (tex[ii].len != e.img.px.len) {
        if (tex[ii].len > 0) A.free(tex[ii]);
        tex[ii] = A.alloc(u32, e.img.px.len) catch {
            tex[ii] = &.{};
            return null;
        };
    }
    var j = .{ .img = &e.img, .out = tex[ii] };
    jobs.parallelFor(e.img.px.len, 4096, &j, texels);
    tex_ver[ii] = e.version;
    return tex[ii];
}

const Tri = struct {
    cv: *gfx.Canvas,
    x0: i32,
    x1: i32,
    y0: i32,
    // the corners: sx sy, 1/z, u/z, v/z
    k: [3][5]f32,
    area: f32,
    tex: []const u32,
    tw: u32,
    th: u32,
    opacity: f32,
    /// skip pixels where an object is
    behind: bool,
    // the diagonal both triangles share: one test says which a pixel is in,
    // so that none on it is blended twice
    q0: [5]f32,
    q2: [5]f32,
    side: f32,
    first: bool,
};

fn edge(a: [5]f32, b: [5]f32, px: f32, py: f32) f32 {
    return (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0]);
}

fn triRows(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const t: *const Tri = @ptrCast(@alignCast(ctx));
    const cv = t.cv;
    const k = &t.k;
    const tw: f32 = @floatFromInt(t.tw);
    const th: f32 = @floatFromInt(t.th);
    const ids = if (t.behind) cv.ids else null;
    for (lo..hi) |row| {
        const y = t.y0 + @as(i32, @intCast(row));
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        const base: usize = @as(usize, @intCast(y)) * @as(usize, @intCast(cv.w));
        var x = t.x0;
        while (x < t.x1) : (x += 1) {
            const px_ = @as(f32, @floatFromInt(x)) + 0.5;
            const w0 = edge(k[1], k[2], px_, py) / t.area;
            const w1 = edge(k[2], k[0], px_, py) / t.area;
            const w2 = edge(k[0], k[1], px_, py) / t.area;
            const onside = edge(t.q0, t.q2, px_, py) * t.side >= 0;
            if (onside != t.first) continue;
            if (w0 < 0 or (w1 < 0 and !t.first) or (w2 < 0 and t.first)) continue;
            const o = base + @as(usize, @intCast(x));
            if (ids) |d| {
                if (d[o] != 0) continue;
            }
            const iz = k[0][2] * w0 + k[1][2] * w1 + k[2][2] * w2;
            const u = (k[0][3] * w0 + k[1][3] * w1 + k[2][3] * w2) / iz;
            const v = (k[0][4] * w0 + k[1][4] * w1 + k[2][4] * w2) / iz;
            const ix: u32 = @intFromFloat(std.math.clamp(u * tw, 0, tw - 1));
            const iy: u32 = @intFromFloat(std.math.clamp(v * th, 0, th - 1));
            const c = t.tex[@as(usize, iy) * t.tw + ix];
            const al = @as(f32, @floatFromInt(c >> 24)) / 255 * t.opacity;
            const d0 = cv.px[o];
            var out: u32 = 0;
            var sh: u5 = 0;
            while (sh <= 16) : (sh += 8) {
                const s: f32 = @floatFromInt((c >> sh) & 255);
                const d: f32 = @floatFromInt((d0 >> sh) & 255);
                out |= @as(u32, @intFromFloat((s - d) * al + d)) << sh;
            }
            cv.px[o] = out;
        }
    }
}

fn fillTri(cv: *gfx.Canvas, tmpl: *const Tri, a: [5]f32, b: [5]f32, cc: [5]f32) void {
    var t = tmpl.*;
    t.k = .{ a, b, cc };
    t.area = edge(a, b, cc[0], cc[1]);
    if (@abs(t.area) < 0.5) return;
    const lo_x = @min(a[0], b[0], cc[0]);
    const hi_x = @max(a[0], b[0], cc[0]);
    const lo_y = @min(a[1], b[1], cc[1]);
    const hi_y = @max(a[1], b[1], cc[1]);
    if (!std.math.isFinite(lo_x + hi_x + lo_y + hi_y)) return;
    const big: f32 = 1e8;
    const x0 = @max(@as(i32, @intFromFloat(std.math.clamp(lo_x, -big, big))), cv.clip.x);
    const x1 = @min(@as(i32, @intFromFloat(std.math.clamp(hi_x, -big, big))) + 1, cv.clip.right());
    const y0 = @max(@as(i32, @intFromFloat(std.math.clamp(lo_y, -big, big))), cv.clip.y);
    const y1 = @min(@as(i32, @intFromFloat(std.math.clamp(hi_y, -big, big))) + 1, cv.clip.bottom());
    if (x0 >= x1 or y0 >= y1) return;
    t.x0 = x0;
    t.x1 = x1;
    t.y0 = y0;
    jobs.parallelFor(@intCast(y1 - y0), 16, &t, triRows);
}

fn one(cv: *gfx.Canvas, c: *const vp.Cam, oi: usize, wire: bool, sel_col: u32) void {
    const o = &scene.objects[oi];
    const of = imageOf(o) orelse return;
    if (!(of.opacity > 0)) return;
    const mtx = scene.world(oi);
    var w: [4]m.V3 = undefined;
    var cs: [4]m.V3 = undefined;
    for (0..4) |k| {
        w[k] = m.xform(mtx, CORNERS[k]);
        cs[k] = c.toView(w[k]);
        if (!(cs[k][2] >= NEAR)) return; // behind the eye: not drawn
    }
    // its normal in camera space: which side faces the eye; square-on?
    const n = m.cross(m.sub(cs[1], cs[0]), m.sub(cs[3], cs[0]));
    if (o.ref & BACK == 0 and m.dot(cs[0], n) >= 0) return;
    if (o.ref & AXIS != 0) {
        const l = m.len(n);
        if (!(l > 0) or @abs(n[2]) / l < SQUARE) return;
    }
    const t = texOf(of.ii) orelse return;
    const img = &images.list[of.ii].img;
    var k: [4][5]f32 = undefined;
    for (0..4) |i| {
        const s = c.screen(cs[i]);
        const iz = 1 / cs[i][2];
        k[i] = .{ s[0], s[1], iz, UVS[i][0] * iz, UVS[i][1] * iz };
    }
    var tmpl = Tri{
        .cv = cv,
        .x0 = 0,
        .x1 = 0,
        .y0 = 0,
        .k = undefined,
        .area = 0,
        .tex = t,
        .tw = img.w,
        .th = img.h,
        .opacity = of.opacity,
        .behind = o.ref & FRONT == 0 and !wire,
        .q0 = k[0],
        .q2 = k[2],
        .side = edge(k[0], k[2], k[1][0], k[1][1]),
        .first = true,
    };
    fillTri(cv, &tmpl, k[0], k[1], k[2]);
    tmpl.first = false;
    fillTri(cv, &tmpl, k[0], k[2], k[3]);
    if (o.selected) {
        for (0..4) |i| vp.line3(cv, c, w[i], w[(i + 1) % 4], sel_col);
    }
}

/// Every reference image, in the viewport being drawn (after its meshes: the
/// id buffer says where objects are).
pub fn draw(cv: *gfx.Canvas, c: *const vp.Cam, ortho: bool, wire: bool, sel_col: u32) void {
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (o.ref & REFIMG == 0 or !o.visible) continue;
        if (o.ref & ORTHO != 0 and !ortho) continue;
        one(cv, c, oi, wire, sel_col);
    }
}

/// The reference whose screen bounds hold the pixel (a few pixels' slack), the
/// smallest of them (vp_pick_bounds): they are not in the id buffer.
pub fn pickBounds(c: *const vp.Cam, ortho: bool, x: i32, y: i32) ?usize {
    const SLACK = 4.0;
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    var best: ?usize = null;
    var best_a: f32 = std.math.inf(f32);
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (o.ref & REFIMG == 0 or !o.visible or o.locked) continue;
        if (o.ref & ORTHO != 0 and !ortho) continue;
        const mtx = scene.world(oi);
        var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
        var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
        var n: usize = 0;
        for (CORNERS) |p| {
            const v = c.toView(m.xform(mtx, p));
            if (!(v[2] >= vp.near)) continue;
            const s = c.screen(v);
            lo = .{ @min(lo[0], s[0]), @min(lo[1], s[1]) };
            hi = .{ @max(hi[0], s[0]), @max(hi[1], s[1]) };
            n += 1;
        }
        if (n == 0) continue;
        if (fx < lo[0] - SLACK or fx > hi[0] + SLACK or fy < lo[1] - SLACK or fy > hi[1] + SLACK) continue;
        const a = (hi[0] - lo[0] + SLACK) * (hi[1] - lo[1] + SLACK);
        if (a < best_a) {
            best_a = a;
            best = oi;
        }
    }
    return best;
}

// --- Properties > Object -------------------------------------------------------------

const ALPHA = 10; // material.params

/// The opacity is its material's alpha (copied first when shared).
pub fn setOpacity(oi: usize, v: f32) void {
    const o = &scene.objects[oi];
    if (o.mat == 0) return;
    var users: u32 = 0;
    for (scene.objects[0..scene.count]) |*q| {
        if (q.mat == o.mat) users += 1;
    }
    if (users > 1) {
        const old: usize = o.mat - 1;
        if (material.new(material.list[old].nameOf())) |i| {
            const nm = material.list[i].name;
            material.list[i] = material.list[old];
            material.list[i].name = nm;
            o.mat = @intCast(i + 1);
        }
    }
    _ = material.set(o.mat - 1, ALPHA, 0, v);
    app.dirty = true;
}

const Opt = struct { cap: []const u8, a: []const u8, b: []const u8, bit: u32, b_set: bool, tip: []const u8 };
const rows = [2]Opt{
    .{ .cap = "Drawn", .a = "Behind the scene", .b = "In front of it", .bit = FRONT, .b_set = true, .tip = "Behind the scene: objects cover it. In front: it covers them (to trace)" },
    .{ .cap = "Seen from", .a = "Both sides", .b = "The front only", .bit = BACK, .b_set = false, .tip = "Seen from behind too, or from its front only" },
};
var list_row: usize = 0;
var list_oi: usize = 0;

fn listLabel(k: usize) []const u8 {
    return if (k == 0) rows[list_row].a else rows[list_row].b;
}
fn listChecked(k: usize) bool {
    if (list_oi >= scene.count) return false;
    const row = rows[list_row];
    return ((scene.objects[list_oi].ref & row.bit != 0) == row.b_set) == (k == 1);
}
fn listPick(k: usize) void {
    if (list_oi >= scene.count) return;
    const row = rows[list_row];
    setBit(&scene.objects[list_oi], row.bit, row.b_set == (k == 1));
}

/// Its settings: y below them.
pub fn props(salt: usize, oi: usize, bd: Rect, y0: i32, label_w: i32) i32 {
    const th = ui.th;
    const cv = ui.cv;
    const o = &scene.objects[oi];
    var y = y0;
    const of = imageOf(o);
    var op: f32 = if (of) |f| f.opacity else 0;
    if (ui.valueField(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, &op, "Opacity", .{ .step = 0.005, .lo = 0, .hi = 1, .dec = 2, .slider = true })) {
        setOpacity(oi, op);
        undo.label("Reference Image");
    }
    y += 26;
    for (rows, 0..) |row, ri| {
        _ = cv.text(bd.x, y + 3, row.cap, th.text_dim);
        const r = Rect{ .x = bd.x + label_w, .y = y, .w = bd.w - label_w, .h = 22 };
        const is_b = (o.ref & row.bit != 0) == row.b_set;
        if (ui.button(ui.id(@src(), salt * 4 + ri), r, if (is_b) row.b else row.a, .{ .tip = row.tip })) {
            ui.active = 0;
            list_row = ri;
            list_oi = oi;
            @import("menus.zig").openList(.{ .n = 2, .label = listLabel, .pick = listPick, .checked = listChecked, .x = r.x, .y = r.bottom() + 2 });
        }
        cv.chevronDown(r.right() - 10, r.y + 11, th.text_dim);
        y += 26;
    }
    var ortho = o.ref & ORTHO != 0;
    if (ui.checkbox(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, "Only in orthographic views", &ortho)) setBit(o, ORTHO, ortho);
    y += 26;
    var axis = o.ref & AXIS != 0;
    if (ui.checkbox(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, "Only when seen square-on", &axis)) setBit(o, AXIS, axis);
    return y + 28;
}

fn setBit(o: *scene.Object, bit: u32, on: bool) void {
    if (on) o.ref |= bit else o.ref &= ~bit;
    undo.label("Reference Image");
    app.dirty = true;
}
