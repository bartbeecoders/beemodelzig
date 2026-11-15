// BeeScript's paint, UV and sculpt builtins (script.s b_sculpt, b_unwrap,
// b_uvpack, b_seams, b_uvstat, b_imgset, b_uvmap, b_paint, b_layer, b_vpaint,
// b_vcol, b_bake): each checks its arguments in the original's order (the
// first bad one is the error) and calls the subsystem's port (sculpt.zig,
// uv.zig, paint.zig, layers.zig, bake.zig). Sculpt strokes, paint dabs and
// bakes make their own steps in the history as the original's do.
const std = @import("std");
const bs = @import("bscript.zig");
const bsc = @import("bs_scene.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const em = @import("editmesh.zig");
const images = @import("images.zig");
const uv = @import("uv.zig");
const sculpt = @import("sculpt.zig");
const paint = @import("paint.zig");
const layers = @import("layers.zig");
const bake = @import("bake.zig");
const ax = @import("animexpr.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "sculpt", .f = sculptB },
    .{ .name = "unwrap", .f = unwrap },
    .{ .name = "uvpack", .f = uvpack },
    .{ .name = "seams", .f = seams },
    .{ .name = "uvstat", .f = uvstat },
    .{ .name = "imgset", .f = imgset },
    .{ .name = "uvmap", .f = uvmap },
    .{ .name = "paint", .f = paintB },
    .{ .name = "layer", .f = layer },
    .{ .name = "vpaint", .f = vpaint },
    .{ .name = "vcol", .f = vcol },
    .{ .name = "bake", .f = bakeB },
};

const e_uv_kind = "unknown kind: ";
const e_brush = "sculpt brushes: draw, clay strips, crease, inflate, grab, snake hook, smooth, flatten, pinch, layer, mask - not ";
const e_no_image = "no image called ";
const e_param = "parameter: ";

const seam_modes = [_][]const u8{ "mark", "clear", "sharp", "none" };
const uvstat_kinds = [_][]const u8{ "islands", "angle", "area", "flipped", "overlap", "inside" };
const bake_kinds = [_][]const u8{ "normal", "ao", "curvature" };

// ---- argument helpers (script.s; here as the shared files have none) ---------------------

/// uv_kind: the index of the word in names, else "unknown kind: <word>".
fn kindOf(v: V, names: []const []const u8) Err!usize {
    const s = try bs.argStr(v);
    for (names, 0..) |n, k| {
        if (std.mem.eql(u8, n, s)) return k;
    }
    return bs.fail(e_uv_kind, s);
}

/// a_val: a number, or a text that is an expression (units, parameters).
fn argVal(v: V) Err!f64 {
    if (v.t != .str) return bs.argNum(v);
    const r = ax.evaluate(std.mem.span(v.u.s));
    if (!r.ok) return bs.fail(e_param, ax.err orelse "");
    return r.v;
}

/// a_image: an image by its name.
fn argImage(v: V) Err!usize {
    const s = try bs.argStr(v);
    return images.find(s) orelse bs.fail(e_no_image, s);
}

/// a_int
fn argInt(v: V) Err!i32 {
    return bs.ci32(try bs.argNum(v));
}

/// a 0..255 channel: cvttsd2si, then clamped (a negative or NaN: 0).
fn channel(v: V) Err!u32 {
    const k = try argInt(v);
    if (k < 0) return 0;
    return @min(@as(u32, @intCast(k)), 255);
}

fn num(x: anytype) V {
    return bs.num(switch (@typeInfo(@TypeOf(x))) {
        .int, .comptime_int => @floatFromInt(x),
        else => x,
    });
}

fn meshOf(i: usize) *scene.Mesh {
    return &scene.meshes[scene.objects[i].mesh.?].?;
}

// ---- sculpt ------------------------------------------------------------------------------

/// sculpt(object, brush, x1, y1, z1, x2, y2, z2, radius, strength): a stroke from
/// one world point to the other (sculpt mode on the object; negative strength
/// inverts), one undo step.
fn sculptB(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    if (!(sculpt.on and !sculpt.land and scene.findOid(sculpt.oid) == i)) {
        if (!sculpt.enter(i)) return bs.nil;
    }
    const bn = try bs.argStr(a[1]);
    const b = sculpt.brushByName(bn) orelse return bs.fail(e_brush, bn);
    var v: [8]f32 = undefined;
    for (0..8) |k| v[k] = bs.f32of(try argVal(a[2 + k]));
    _ = sculpt.strokeWorld(b, v[0..3].*, v[3..6].*, v[6], v[7]);
    app.dirty = true;
    return bs.nil;
}

// ---- UVs ---------------------------------------------------------------------------------

/// unwrap(object [, "smart"]) -> islands (-1: none, no memory): LSCM along the
/// seams or a smart projection, packed into 0..1
fn unwrap(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    const me = uv.cow(i);
    var smart = false;
    if (a.len >= 2) smart = std.mem.eql(u8, try bs.argStr(a[1]), "smart");
    app.dirty = true;
    const m = me orelse return num(-1);
    const n = uv.unwrap(m, smart) orelse return num(-1);
    return num(n);
}

/// uvpack(object) -> islands (-1: no UVs)
fn uvpack(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    const me = uv.cow(i) orelse return num(-1);
    app.dirty = true;
    const n = uv.pack(me) orelse return num(-1);
    return num(n);
}

/// seams(object, "mark" | "clear" | "sharp" | "none") -> the seam edges now
fn seams(a: []const V) Err!V {
    const k = try kindOf(a[1], &seam_modes);
    const i = try bsc.argMesh(a[0]);
    const me = uv.cow(i) orelse return num(-1);
    const sel: []const bool = if (em.active and em.obj == i and em.sel.len == me.verts.len) em.sel else me.vsel;
    app.dirty = true;
    const n = uv.seams(me, @enumFromInt(k), sel) orelse return num(-1);
    return num(n);
}

/// uvstat(object, "islands" | "angle" | "area" | "flipped" | "overlap" | "inside")
fn uvstat(a: []const V) Err!V {
    const k = try kindOf(a[1], &uvstat_kinds);
    const i = try bsc.argMesh(a[0]);
    return num(@as(f64, uv.stat(meshOf(i), @enumFromInt(k))));
}

/// uvmap(object, su, sv, du, dv): every UV becomes (u su + du, v sv + dv)
fn uvmap(a: []const V) Err!V {
    var t: [4]f32 = undefined;
    for (0..4) |k| t[k] = bs.f32of(try bs.argNum(a[1 + k]));
    const i = try bsc.argMesh(a[0]);
    if (uv.cow(i)) |me| {
        if (me.uv.len > 0) {
            var c = me.uv.len;
            while (c > 0) {
                c -= 1;
                me.uv[c][0] = me.uv[c][0] * t[0] + t[2];
                me.uv[c][1] = me.uv[c][1] * t[1] + t[3];
            }
        }
    }
    app.dirty = true;
    return bs.nil;
}

// ---- images ------------------------------------------------------------------------------

/// imgset(image, x, y, r, g, b [, a]): an 8-bit image's pixel (0..255); the image
/// is then saved inside .bee files
fn imgset(a: []const V) Err!V {
    const im = try argImage(a[0]);
    const x = try argInt(a[1]);
    const y = try argInt(a[2]);
    var c: [4]u8 = .{ 0, 0, 0, 255 };
    var k: usize = 0;
    while (k + 3 < a.len) : (k += 1) c[k] = @intCast(try channel(a[3 + k]));
    const e = &images.list[im];
    if (e.img.hdr or e.b8.len == 0) return bs.nil;
    const ux: u32 = @bitCast(x);
    const uy: u32 = @bitCast(y);
    if (ux >= e.img.w or uy >= e.img.h) return bs.nil;
    e.b8[@as(usize, uy) * e.img.w + ux] = c;
    images.rectChanged(im, ux, uy, ux, uy);
    app.dirty = true;
    return bs.nil;
}

/// layer(image, "count" | "add" | "active" | "opacity" | "blend" | "visible" |
/// "remove" | "merge" [, layer [, value]])
fn layer(a: []const V) Err!V {
    const im = try argImage(a[0]);
    var op = try kindOf(a[1], &layers.op_names);
    var l: i32 = -1;
    var value: f32 = 0;
    if (a.len >= 3) {
        l = try argInt(a[2]);
        if (a.len >= 4) value = bs.f32of(try bs.argNum(a[3]));
    }
    if (op == @intFromEnum(layers.Op.active) and a.len < 3) op = @intFromEnum(layers.Op.get_active);
    const r = layers.op(im, @enumFromInt(op), l, value);
    app.dirty = true;
    return num(r);
}

/// The x y z radius and the colour (paint, vpaint): the colour is the brush's
/// from then on.
fn dabArgs(a: []const V) Err![4]f32 {
    var v: [4]f32 = undefined;
    for (0..4) |k| v[k] = bs.f32of(try bs.argNum(a[1 + k]));
    if (a.len >= 8) {
        var c: u32 = 0xff;
        for (5..8) |k| c = c << 8 | try channel(a[k]);
        paint.col = c;
    }
    return v;
}

/// paint(object, x, y, z, radius [, r, g, b]): a dab of texture paint around that
/// world point -> 1, 0 when the object has no image to paint
fn paintB(a: []const V) Err!V {
    const v = try dabArgs(a);
    const i = try bsc.argMesh(a[0]);
    const ok = paint.dabWorld(i, v[0..3].*, v[3]);
    app.dirty = true;
    return num(@intFromBool(ok));
}

/// vpaint(object, x, y, z, radius [, r, g, b]): vertex paint around that world
/// point (one undo step) -> 1
fn vpaint(a: []const V) Err!V {
    const v = try dabArgs(a);
    const i = try bsc.argMesh(a[0]);
    const ok = paint.dabWorldMesh(i, .vertex, v[0..3].*, v[3]);
    app.dirty = true;
    return num(@intFromBool(ok));
}

/// vcol(object, vertex, channel) -> its vertex colour's red, green, blue or alpha
/// (0..3: 0..255; -1: no colours)
fn vcol(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    const vi: u32 = @bitCast(try argInt(a[1]));
    const ch: u32 = @bitCast(try argInt(a[2]));
    const me = meshOf(i);
    if (me.vcol.len == 0 or vi >= me.verts.len or vi >= me.vcol.len or ch > 3) return num(-1);
    const sh: u5 = switch (ch) {
        0 => 16,
        1 => 8,
        2 => 0,
        else => 24,
    };
    return num((me.vcol[vi] >> sh) & 0xff);
}

/// bake(low, high, "normal" | "ao" | "curvature", image [, distance]) -> the
/// texels baked (-1: no UVs, not an 8-bit image)
fn bakeB(a: []const V) Err!V {
    const low = try bsc.argMesh(a[0]);
    const high = try bsc.argMesh(a[1]);
    const k = try kindOf(a[2], &bake_kinds);
    const im = try argImage(a[3]);
    var dist: f32 = 0;
    if (a.len >= 5) dist = bs.f32of(try bs.argNum(a[4]));
    app.dirty = true;
    const n = bake.bake(low, high, @enumFromInt(k), im, dist, null) orelse return num(-1);
    @import("material.zig").version +%= 1;
    return num(n);
}

test "channels: truncated toward zero, then 0..255 (NaN and the out of range: 0)" {
    try std.testing.expectEqual(@as(u32, 7), try channel(bs.num(7.9)));
    try std.testing.expectEqual(@as(u32, 0), try channel(bs.num(-0.5)));
    try std.testing.expectEqual(@as(u32, 0), try channel(bs.num(-5)));
    try std.testing.expectEqual(@as(u32, 255), try channel(bs.num(300)));
    try std.testing.expectEqual(@as(u32, 0), try channel(bs.num(std.math.nan(f64))));
    try std.testing.expectEqual(@as(u32, 0), try channel(bs.num(1e300)));
}
