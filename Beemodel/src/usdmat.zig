//! OpenUSD materials (usdmat.s): a bound Material prim's UsdPreviewSurface
//! into a BeeModel material, made once an import.
//!
//! The Material's outputs:surface leads to its UsdPreviewSurface shader. Each
//! input is a value, or a connection to another shader's output:
//!   diffuseColor   value -> base colour; a UsdUVTexture -> the base map
//!   metallic,      values; both from one texture's b and g outputs (an ORM /
//!   roughness       glTF metallic-roughness map) -> that map; each from a
//!                   texture of its own (one channel; Blender's exports, Poly
//!                   Haven's), or one of them a value -> a metallic-roughness
//!                   map made of them (B, G)
//!   normal         a UsdUVTexture -> the normal map (its scale)
//!   emissiveColor  value -> emission; a texture -> the emission map
//!   opacity        below 1 (glass): transmission 1 - opacity; ior
//!   opacityThreshold above 0: the base map's alpha as a mask
//! A texture's st through a UsdTransform2d gives the maps' tiling and offset.
//! Texture files are resolved beside the layer that names them; images are
//! loaded once an import. graphops.gltf (matlib.s ml_gltf) makes the graph.
//! Textures bigger than file.usd_texture_size (1024 by default) are box-
//! filtered down by a power of two once, kept beside the original as
//! <name>.<size>.png and loaded from there. A texture that cannot be read, or
//! an OpenEXR one (no reader here), is taken from the same name as .png or
//! .jpg when that is there.
const std = @import("std");
const ul = @import("usdlayer.zig");
const usd = @import("usd.zig");
const app = @import("app.zig");
const material = @import("material.zig");
const images = @import("images.zig");
const image = @import("image.zig");
const gops = @import("graphops.zig");
const Value = ul.Value;
const Layer = ul.Layer;

const A = std.heap.page_allocator;

const MP_BASE = 0; // (material.zig's parameters)
const MP_METAL = 1;
const MP_ROUGH = 2;
const MP_IOR = 4;
const MP_TRANS = 5;
const MP_EMIT = 6;
const MP_ESTR = 7;
const MAXMAT = 256;
const MAXIMG = 256;

/// textures at most this a side (0: any)
pub var texcap: u32 = 1024;

const Made = struct { lay: *Layer, path: [*:0]const u8, index: usize };
var made: [MAXMAT]Made = undefined; // materials made: where defined, index
var nm: u32 = 0;
const Img = struct { path: [*:0]const u8, idx: u32 }; // images loaded: file, index + 1
var imgs: [MAXIMG]Img = undefined;
var ni: u32 = 0;
var gt: gops.Gt = .{};
var mat: usize = 0;
var tile = false; // the tiling is set (the first map's)
var cpath: [1100]u8 = undefined; // the capped copy's path
var apath: [1100]u8 = undefined; // a texture's stand-in (.png / .jpg)

/// usdmat_reset: a new import: no materials or images made yet
pub fn reset() void {
    nm = 0;
    ni = 0;
}

/// mat_set: clamped to the parameter's range (a NaN: its least, as maxss /
/// minss leave it)
fn set(p: usize, comp: usize, v: f32) void {
    const ma = material.get(mat) orelse return;
    const pr = material.params[p];
    var x = if (v > pr.lo) v else pr.lo;
    x = if (x < pr.hi) x else pr.hi;
    material.ptr(ma, p, comp).* = x;
    material.version +%= 1;
}

/// usdmat_get: a Material prim's BeeModel material (made the first time for
/// its definition: instances share it), null when it is not a material it can
/// read
pub fn get(path: [*:0]const u8) ?usize {
    const mp = prim(path) orelse return null;
    const src = usd.source(mp) orelse return null; // made already? (by its definition)
    for (made[0..nm]) |*r| {
        if (r.lay == src.lay and ul.eq(r.path, src.path)) return r.index;
    }
    const surf = conn(mp, "outputs:surface") orelse return null; // its surface: the shader connected
    if (!isId(surf.prim, "UsdPreviewSurface")) return null;
    const s = surf.prim;
    mat = material.new(nameOf(usd.primPath(mp))) orelse {
        app.log("  the scene holds 1024 materials", .{});
        return null;
    };
    gt = .{}; // no maps; factors 1; tiling 1
    tile = false;
    _ = colour(s, "inputs:diffuseColor", &gt.base, MP_BASE); // base colour
    scalar(s, "inputs:metallic", MP_METAL); // metallic, roughness: values, or one texture's b and g
    scalar(s, "inputs:roughness", MP_ROUGH);
    mrOne(s);
    mrTwo(s);
    if (conn(s, "inputs:normal")) |c| { // normal
        const t = texture(c.prim);
        if (t != 0) gt.nrm = t;
    }
    if (colour(s, "inputs:emissiveColor", &gt.emi, MP_EMIT)) set(MP_ESTR, 0, 1); // (a colour or a map: full strength)
    if (value(s, "inputs:opacity")) |v| { // opacity: glass as transmission
        if (v.t == ul.UT_DBL) {
            const f: f32 = @floatCast(v.dbl());
            if (!(f >= 1)) set(MP_TRANS, 0, 1 - f);
        }
    }
    if (value(s, "inputs:ior")) |v| {
        if (v.t == ul.UT_DBL) set(MP_IOR, 0, @floatCast(v.dbl()));
    }
    if (value(s, "inputs:opacityThreshold")) |v| { // a threshold: the alpha a mask
        if (v.t == ul.UT_DBL and !(0 >= v.dbl())) gt.alpha = 1;
    }
    if (gt.base | gt.mr | gt.nrm | gt.emi != 0) gops.gltf(mat, &gt); // any map: a graph
    if (nm < MAXMAT) { // remembered
        made[nm] = .{ .lay = src.lay, .path = src.path, .index = mat };
        nm += 1;
    }
    return mat;
}

/// um_name: its last element
fn nameOf(p: [*:0]const u8) []const u8 {
    const s = ul.cstr(p);
    return s[if (std.mem.lastIndexOfScalar(u8, s, '/')) |k| k + 1 else 0..];
}

/// um_prim: the composed prim of a stage path (of a prim, or of a property:
/// its prim's part), null
fn prim(p: [*:0]const u8) ?u32 {
    var b: [4097]u8 = undefined;
    var i: usize = 0;
    var keep: usize = 0; // up to a '.' after the last '/'
    while (p[i] != 0) : (i += 1) {
        const c = p[i];
        if (c == '/') keep = 0;
        if (c == '.' and keep == 0) keep = i;
        if (i >= 4000) return null;
        b[i] = c;
    }
    const n = if (keep != 0) keep else i;
    b[n] = 0;
    const k = ul.find(usd.st.?, @ptrCast(&b)) orelse return null;
    return if (usd.done(k)) k else null;
}

const Conn = struct { prim: u32, out: [*:0]const u8 };

/// um_conn: the prim an input's / output's connection leads to, and the
/// output's name ("outputs:rgb" ...: after the '.')
fn conn(pi: u32, input: [*:0]const u8) ?Conn {
    const g = usd.aget(pi, input, "connectionPaths") orelse return null;
    if (g.v.t != ul.UT_SLIST or g.v.n == 0) return null;
    const t = g.v.texts();
    if (t.len == 0) return null;
    const first = t[0] orelse return null;
    const mp = usd.map(g.n, first); // into the stage's names
    const k = prim(mp) orelse return null;
    var out = mp; // the output: after the last '.'
    var i: usize = 0;
    while (mp[i] != 0) {
        const c = mp[i];
        i += 1;
        if (c == '.') out = mp + i;
    }
    return .{ .prim = k, .out = out };
}

fn value(pi: u32, input: [*:0]const u8) ?*Value {
    return usd.agetv(pi, input);
}

/// um_isid: its info:id is that
fn isId(pi: u32, id: []const u8) bool {
    const v = value(pi, "info:id") orelse return false;
    return v.t == ul.UT_STR and std.mem.eql(u8, ul.cstr(v.str()), id);
}

/// um_colour: set: a UsdUVTexture connected (its image into the slot), or a
/// colour value (the parameter)
fn colour(s: u32, input: [*:0]const u8, slot: *u32, p: usize) bool {
    if (conn(s, input)) |c| {
        const t = texture(c.prim);
        if (t == 0) return false;
        slot.* = t;
        return true;
    }
    const v = value(s, input) orelse return false;
    if (v.t != ul.UT_VEC or v.n < 3) return false;
    const d = v.vec();
    for (0..3) |k| set(p, k, @floatCast(d[k]));
    return true;
}

/// um_scalar: a float value set
fn scalar(s: u32, input: [*:0]const u8, p: usize) void {
    const v = value(s, input) orelse return;
    if (v.t == ul.UT_DBL) set(p, 0, @floatCast(v.dbl()));
}

/// um_mr: metallic from a texture's b and roughness from the same texture's
/// g (glTF's metallic-roughness, SimReady's ORM): that map
fn mrOne(s: u32) void {
    const a = conn(s, "inputs:metallic") orelse return;
    if (!ul.eq(a.out, "outputs:b")) return;
    const b = conn(s, "inputs:roughness") orelse return;
    if (b.prim != a.prim or !ul.eq(b.out, "outputs:g")) return;
    const t = texture(a.prim);
    if (t != 0) gt.mr = t;
}

const Chan = struct { img: u32, shift: u5 };

/// um_chan: the image + 1 of the UsdUVTexture connected (0: none), the
/// channel's shift (r 16, g 8, b 0)
fn chan(s: u32, input: [*:0]const u8) Chan {
    const c = conn(s, input) orelse return .{ .img = 0, .shift = 0 };
    const sh: u5 = if (ul.eq(c.out, "outputs:g")) 8 else if (ul.eq(c.out, "outputs:b")) 0 else 16;
    return .{ .img = texture(c.prim), .shift = sh };
}

/// um_cbyte: its float value as a byte (x 255), else the default
fn cbyte(s: u32, input: [*:0]const u8, def: u32) u32 {
    const v = value(s, input) orelse return def;
    if (v.t != ul.UT_DBL) return def;
    const f: f32 = @as(f32, @floatCast(v.dbl())) * 255.0 + 0.5;
    const x = @import("ntree.zig").cvtt(f);
    if (x < 0) return 0;
    if (x > 255) return 255;
    return @intCast(x);
}

/// um_img8: an image (+ 1) when it is 8-bit
fn img8(ip1: u32) ?*images.Entry {
    if (ip1 == 0) return null;
    if (ip1 - 1 >= images.count) return null;
    const e = &images.list[ip1 - 1];
    if (e.img.hdr or e.b8.len == 0) return null;
    return e;
}

/// um_sample: the image's byte at (x, y) of the map made (ow x oh), nearest
fn sample(e: *const images.Entry, x: u32, y: u32, ow: u32, oh: u32, shift: u5) u32 {
    const sx: u32 = @intCast(@as(u64, x) * e.img.w / ow);
    const sy: u32 = @intCast(@as(u64, y) * e.img.h / oh);
    const p = e.b8[@as(usize, sy) * e.img.w + sx];
    const argb: u32 = @as(u32, p[3]) << 24 | @as(u32, p[0]) << 16 | @as(u32, p[1]) << 8 | p[2];
    return (argb >> shift) & 255;
}

/// um_mr2: no metallic-roughness map yet: metallic and roughness each from a
/// texture of its own (the channel connected: r, g or b) or a value (defaults
/// 0 and 0.5), at least one a texture: a map made of them (B metallic, G
/// roughness; the size of the roughness texture, else the metallic one),
/// adopted as an image of the scene
fn mrTwo(s: u32) void {
    if (gt.mr != 0) return;
    const m = chan(s, "inputs:metallic");
    const r = chan(s, "inputs:roughness");
    if (m.img | r.img == 0) return;
    const mv = cbyte(s, "inputs:metallic", 0); // the values (no texture)
    const rv = cbyte(s, "inputs:roughness", 128);
    const mi = img8(m.img);
    const ri = img8(r.img);
    const base = ri orelse mi orelse return;
    const ow = base.img.w;
    const oh = base.img.h;
    const px = A.alloc([4]u8, @as(usize, ow) * oh) catch return;
    defer A.free(px);
    for (0..oh) |y| {
        for (0..ow) |x| {
            const mb = if (mi) |e| sample(e, @intCast(x), @intCast(y), ow, oh, m.shift) else mv;
            const rb = if (ri) |e| sample(e, @intCast(x), @intCast(y), ow, oh, r.shift) else rv;
            px[y * ow + x] = .{ 0, @intCast(rb), @intCast(mb), 255 };
        }
    }
    const from = (if (r.img != 0) r.img else m.img) - 1; // named <texture>_mr
    var nb: [40]u8 = undefined;
    const tn = images.nameOf(from);
    const k = @min(tn.len, 27);
    @memcpy(nb[0..k], tn[0..k]);
    @memcpy(nb[k..][0..3], "_mr");
    const idx = images.adopt(nb[0 .. k + 3], ow, oh, px) catch return;
    gt.mr = @intCast(idx + 1);
}

/// um_alt: the file to load: it, or when it cannot be read or is an OpenEXR
/// (no reader here) the same name as .png, else .jpg, when that is there
fn alt(p: []const u8) []const u8 {
    if (!std.mem.endsWith(u8, p, ".exr") and readable(p)) return p;
    if (p.len > 1080) return p;
    @memcpy(apath[0..p.len], p);
    var dot: ?usize = null; // <stem>
    for (p, 0..) |c, i| {
        if (c == '/') dot = null;
        if (c == '.') dot = i;
    }
    const d = dot orelse return p;
    for ([_][]const u8{ ".png", ".jpg" }) |x| {
        @memcpy(apath[d..][0..4], x);
        if (readable(apath[0 .. d + 4])) return apath[0 .. d + 4];
    }
    return p;
}

fn readable(p: []const u8) bool {
    const d = ul.mapFile(p) orelse return false;
    ul.unmapFile(d);
    return true;
}

/// um_texture: a UsdUVTexture prim's image + 1 (0: none): inputs:file
/// resolved beside the layer that names it, loaded once; its st's
/// UsdTransform2d sets the tiling (the first map's)
fn texture(t: u32) u32 {
    if (!isId(t, "UsdUVTexture")) return 0;
    const g = usd.aget(t, "inputs:file", "default") orelse return 0;
    if (g.v.t != ul.UT_STR or g.v.str()[0] == 0) return 0;
    const rp = usd.resolve(g.v.str(), g.n.lay.file);
    const p = capped(alt(rp)); // (an EXR, or missing: a .png / .jpg of it; its size capped: the small copy)
    var idx: u32 = 0;
    for (imgs[0..ni]) |*x| {
        if (std.mem.eql(u8, ul.cstr(x.path), p)) {
            idx = x.idx;
            break;
        }
    } else {
        const i = load(p) orelse return 0;
        idx = @intCast(i + 1);
        if (ni < MAXIMG) { // (the path kept: the buffers are reused)
            imgs[ni] = .{ .path = usd.st.?.ar.dup(p) orelse "", .idx = idx };
            ni += 1;
        }
    }
    if (!tile) tiling(t); // the tiling: its st's transform
    return idx;
}

/// image_load: a new image of the file (its name unique), and the console's
/// line about it; null when it cannot be read
pub fn load(p: []const u8) ?usize {
    if (images.count >= images.MAX) {
        app.log("  image: too many images", .{});
        return null;
    }
    const i = images.loadNew(p) catch |e| {
        const why = switch (e) {
            error.CannotRead => "cannot read the file",
            else => if (knownFormat(p)) "damaged or unsupported file" else "unknown image format",
        };
        app.log("  image: {s}: {s}", .{ p, why });
        return null;
    };
    const im = &images.list[i].img;
    app.log("  image: {s} {d} x {d}{s}", .{ images.nameOf(i), im.w, im.h, if (im.hdr) " (HDR)" else "" });
    return i;
}

fn knownFormat(p: []const u8) bool {
    const d = ul.mapFile(p) orelse return false;
    defer ul.unmapFile(d);
    if (d.len < 8) return false;
    return std.mem.eql(u8, d[0..8], "\x89PNG\r\n\x1a\n") or (d[0] == 0xff and d[1] == 0xd8) or (d[0] == '#' and d[1] == '?');
}

/// um_capped: the file to load: it, or its copy <stem>.<cap>.png when it is
/// bigger than texcap a side (made the first time: an f x f box filter, f the
/// power of two that fits it)
fn capped(p: []const u8) []const u8 {
    const cap = texcap;
    if (cap == 0) return p;
    if (p.len > 1000) return p;
    var dot: ?usize = null; // the copy's name: up to the extension (its '.': after the last '/')
    for (p, 0..) |c, i| {
        if (c == '/') dot = null;
        if (c == '.') dot = i;
    }
    const stem = dot orelse p.len;
    @memcpy(cpath[0..stem], p[0..stem]);
    const cp = std.fmt.bufPrint(cpath[stem..], ".{d}.png", .{cap}) catch return p;
    const copy = cpath[0 .. stem + cp.len];
    if (readable(copy)) return copy; // made already?
    if (!@import("files.zig").mayWrite(copy)) return p; // (headless: files under /tmp only)
    const d = ul.mapFile(p) orelse return p; // the original: decoded
    var img = image.decodeData(A, d) catch {
        ul.unmapFile(d);
        return p;
    };
    ul.unmapFile(d);
    defer img.deinit(A);
    if (img.hdr) return p; // (8-bit ones only)
    if (img.w <= cap and img.h <= cap) return p; // small enough: as it is
    var f: u32 = 1;
    while (img.w / f > cap or img.h / f > cap) f *%= 2;
    const nw = img.w / f;
    const nh = img.h / f;
    if (nw == 0 or nh == 0) return p;
    const out = A.alloc([4]u8, @as(usize, nw) * nh) catch return p;
    defer A.free(out);
    shrink(out, &img, f, nw, nh);
    const data = @import("png.zig").encodeRgba(A, nw, nh, out) catch return p;
    defer A.free(data);
    @import("atomicfile.zig").write(copy, data) catch return p;
    return copy;
}

fn byteOf(x: f32) u32 {
    return @intFromFloat(std.math.clamp(x, 0, 1) * 255 + 0.5);
}

/// um_shrink: each out pixel the average of its f x f source pixels, per
/// channel (sums divided, truncated)
fn shrink(out: [][4]u8, img: *const image.Image, f: u32, nw: u32, nh: u32) void {
    const ff = f * f;
    for (0..nh) |oy| {
        for (0..nw) |ox| {
            var s: [4]u32 = .{ 0, 0, 0, 0 };
            for (0..f) |dy| {
                const row = (oy * f + dy) * img.w + ox * f;
                for (0..f) |dx| {
                    const q = img.px[row + dx];
                    for (0..4) |c| s[c] += byteOf(q[c]);
                }
            }
            for (0..4) |c| out[oy * nw + ox][c] = @intCast(s[c] / ff);
        }
    }
}

/// um_tiling: its st from a UsdTransform2d: the maps' tiling (scale) and
/// offset (translation)
fn tiling(t: u32) void {
    const c = conn(t, "inputs:st") orelse return;
    if (!isId(c.prim, "UsdTransform2d")) return;
    tile = true;
    if (value(c.prim, "inputs:scale")) |v| {
        if (v.t == ul.UT_VEC and v.n >= 2) {
            const d = v.vec();
            gt.tile = .{ @floatCast(d[0]), @floatCast(d[1]) };
        }
    }
    if (value(c.prim, "inputs:translation")) |v| {
        if (v.t == ul.UT_VEC and v.n >= 2) {
            const d = v.vec();
            gt.off = .{ @floatCast(d[0]), @floatCast(d[1]) };
        }
    }
}
