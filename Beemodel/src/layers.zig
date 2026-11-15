// Paint layers (layers.s). An 8-bit image can carry a stack of layers (up to 16):
// the base (the pixels it had) and layers above with alpha, an opacity, a blend mode
// (normal, multiply, add) and a visibility. The image's own bytes (Entry.b8) are
// then the composite, which is what the shaders sample and the files save; painting
// writes into the active layer and composites the texels it touched. Merge
// flattens the stack into the image. Layers are saved inside .bee files (ILAY: per
// layer its settings and an RGBA PNG).
const std = @import("std");
const images = @import("images.zig");
const pthist = @import("pthist.zig");
const texture = @import("texture.zig");
const material = @import("material.zig");
const app = @import("app.zig");
const png = @import("png.zig");
const image = @import("image.zig");
const A = std.heap.page_allocator;

pub const MAX = 16;
const inv255: f32 = 0.003921569;

pub const Layer = struct {
    /// R G B A, top row first
    px: [][4]u8 = &.{},
    opac: f32 = 1,
    blend: u32 = 0,
    vis: u32 = 1,
};
pub const Block = struct {
    count: u32 = 0,
    active: u32 = 0,
    l: [MAX]Layer = @splat(.{}),
};

/// lay_op's operations.
pub const Op = enum(u32) { count, add, active, opacity, blend, visible, remove, merge, get_active };
pub const op_names = [_][]const u8{ "count", "add", "active", "opacity", "blend", "visible", "remove", "merge" };

fn entry(im: usize) *images.Entry {
    return &images.list[im];
}

fn zeroed(e: *const images.Entry) ?[][4]u8 {
    const p = A.alloc([4]u8, e.b8.len) catch return null;
    @memset(p, .{ 0, 0, 0, 0 });
    return p;
}

/// lay_add: the new layer's number (active; -1: none). The first one also makes the
/// base from the image's pixels.
fn add(im: usize) i32 {
    const e = entry(im);
    if (e.b8.len == 0) return -1;
    if (e.layers == null) {
        const b = A.create(Block) catch return -1;
        b.* = .{};
        b.l[0].px = A.dupe([4]u8, e.b8) catch {
            A.destroy(b);
            return -1;
        };
        b.count = 1;
        e.layers = b;
    }
    const b = e.layers.?;
    if (b.count >= MAX) return -1;
    const n = b.count;
    const p = zeroed(e) orelse return -1;
    b.l[n] = .{ .px = p };
    b.count += 1;
    b.active = n;
    return @intCast(n);
}

/// lay_free: its layers go (the composite stays).
pub fn free(e: *images.Entry) void {
    const b = e.layers orelse return;
    for (b.l[0..b.count]) |*l| {
        if (l.px.len > 0) A.free(l.px);
    }
    A.destroy(b);
    e.layers = null;
}

/// lay_target: the pixels painting writes: the active layer's, else the image's own.
pub fn target(e: *const images.Entry) [][4]u8 {
    const b = e.layers orelse return e.b8;
    return b.l[b.active].px;
}

/// The layer painted, -1: the image itself.
pub fn activeOf(e: *const images.Entry) i32 {
    const b = e.layers orelse return -1;
    return @intCast(b.active);
}

/// The same buffer again (an undo step's): k from activeOf.
pub fn buffer(e: *const images.Entry, k: i32) ?[][4]u8 {
    if (k < 0) return e.b8;
    const b = e.layers orelse return null;
    if (k >= b.count) return null;
    return b.l[@intCast(k)].px;
}

/// lay_texel: the composite at texel i, into the image's bytes.
pub fn texel(e: *images.Entry, b: *const Block, i: usize) void {
    var o0: f32 = 0;
    var o1: f32 = 0;
    var o2: f32 = 0;
    for (b.l[0..b.count], 0..) |*l, k| {
        if (l.vis == 0) continue;
        const c = l.px[i];
        var a = @as(f32, @floatFromInt(c[3])) * inv255;
        a = a * l.opac;
        if (k == 0) a = l.opac; // (the base: opaque)
        const r = @as(f32, @floatFromInt(c[0])) * inv255;
        const g = @as(f32, @floatFromInt(c[1])) * inv255;
        const bl = @as(f32, @floatFromInt(c[2])) * inv255;
        switch (l.blend) {
            1 => { // multiply: out + (out c - out) a
                o0 += (r * o0 - o0) * a;
                o1 += (g * o1 - o1) * a;
                o2 += (bl * o2 - o2) * a;
            },
            2 => { // add: out + c a (to 1)
                o0 += r * a;
                o0 = if (o0 < 1) o0 else 1;
                o1 += g * a;
                o1 = if (o1 < 1) o1 else 1;
                o2 += bl * a;
                o2 = if (o2 < 1) o2 else 1;
            },
            else => { // normal: out + (c - out) a
                o0 += (r - o0) * a;
                o1 += (g - o1) * a;
                o2 += (bl - o2) * a;
            },
        }
    }
    const s = @import("stroke.zig").trunc32;
    const px = [4]u8{ @truncate(@as(u32, @bitCast(s(o0 * 255.0 + 0.5)))), @truncate(@as(u32, @bitCast(s(o1 * 255.0 + 0.5)))), @truncate(@as(u32, @bitCast(s(o2 * 255.0 + 0.5)))), 255 };
    e.b8[i] = px;
    e.img.px[i] = .{ texture.lut[px[0]], texture.lut[px[1]], texture.lut[px[2]], 1 };
}

/// lay_rect: the composite of that box (inclusive).
pub fn rect(e: *images.Entry, x0: usize, y0: usize, x1: usize, y1: usize) void {
    const b = e.layers orelse return;
    const w: usize = e.img.w;
    for (y0..y1 + 1) |y| {
        for (x0..x1 + 1) |x| texel(e, b, y * w + x);
    }
}

fn all(e: *images.Entry) void {
    if (e.layers != null and e.img.w > 0 and e.img.h > 0) rect(e, 0, 0, e.img.w - 1, e.img.h - 1);
}

fn changed(im: usize) void {
    images.bytesChanged(im);
    material.version +%= 1;
    app.dirty = true;
}

/// lay_op: the result (-1: no such layer).
pub fn op(im: usize, which: Op, layer: i32, value: f32) i32 {
    if (im >= images.count) return -1;
    const e = entry(im);
    switch (which) {
        .add => {
            @import("paint.zig").finishStroke(); // (it writes into what goes)
            pthist.clear(); // (strokes point at layers)
            const r = add(im);
            changed(im);
            return r;
        },
        .count => return if (e.layers) |b| @intCast(b.count) else 1,
        .get_active => return if (e.layers) |b| @intCast(b.active) else 0,
        .merge => {
            @import("paint.zig").finishStroke();
            pthist.clear();
            free(e); // (the composite is the image)
            changed(im);
            return 0;
        },
        else => {},
    }
    const b = e.layers orelse return -1;
    if (layer < 0 or layer >= b.count) return -1;
    const k: usize = @intCast(layer);
    const l = &b.l[k];
    switch (which) {
        .active => {
            b.active = @intCast(k);
            return layer;
        },
        .opacity => {
            const s = @import("stroke.zig");
            l.opac = s.minss(s.maxss(value, 0), 1);
        },
        .blend => {
            const v = @import("stroke.zig").trunc32(value);
            if (v < 0 or v > 2) return -1;
            l.blend = @intCast(v);
        },
        .visible => l.vis = @intFromBool(@import("stroke.zig").trunc32(value) != 0),
        .remove => { // (not the base)
            if (k == 0) return -1;
            @import("paint.zig").finishStroke();
            pthist.clear();
            A.free(l.px);
            std.mem.copyForwards(Layer, b.l[k .. b.count - 1], b.l[k + 1 .. b.count]);
            b.count -= 1;
            b.l[b.count] = .{};
            if (b.active > b.count - 1) b.active = b.count - 1;
        },
        else => return -1,
    }
    all(e);
    changed(im);
    return 0;
}

/// ILAY: per image with layers its index, count, active, then per layer opacity,
/// blend, visible, bytes, an RGBA PNG.
pub fn writeChunk(out: anytype) void {
    for (images.list[0..images.count], 0..) |*e, i| {
        const b = e.layers orelse continue;
        var f: [MAX][]u8 = undefined;
        var n: usize = 0;
        defer for (f[0..n]) |x| A.free(x);
        while (n < b.count) : (n += 1) f[n] = png.encodeRgba(A, e.img.w, e.img.h, b.l[n].px) catch break;
        if (n != b.count) continue; // (no memory: as if it had none)
        out.u32_(@intCast(i));
        out.u32_(b.count);
        out.u32_(b.active);
        for (b.l[0..b.count], f[0..n]) |*l, x| {
            out.u32_(@bitCast(l.opac));
            out.u32_(l.blend);
            out.u32_(l.vis);
            out.u32_(@intCast(x.len));
            out.bytes(x);
        }
    }
}

fn rd(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .little);
}

/// ilay_read: the layers back on their images (sizes must match), composited. Damage
/// ends the reading; a layer that does not decode stays empty (the base: as saved).
pub fn readChunk(d: []const u8) void {
    var o: usize = 0;
    while (d.len - o >= 12) {
        const ix = rd(d, o);
        const count = rd(d, o + 4);
        const active = rd(d, o + 8);
        o += 12;
        if (ix >= images.count) return;
        const e = entry(ix);
        if (e.b8.len == 0) return;
        free(e);
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            if (d.len - o < 16) return done(e, active);
            const n = rd(d, o + 12);
            if (n > d.len - o - 16) return done(e, active);
            const r = add(ix);
            if (r < 0) return done(e, active);
            // (the first add makes the base and layer 1: layer 1's pixels stay for
            // the next one, as they are empty)
            if (k == 0) {
                const b = e.layers.?;
                A.free(b.l[1].px);
                b.l[1] = .{};
                b.count = 1;
            }
            const l = &e.layers.?.l[k];
            l.opac = @bitCast(rd(d, o));
            l.blend = rd(d, o + 4);
            l.vis = rd(d, o + 8);
            decodeInto(e, l, d[o + 16..][0..n]);
            o += 16 + n;
        }
        finish(e, active);
    }
}

fn done(e: *images.Entry, active: u32) void {
    // (a chunk cut short: what came, composited, not the original's half-made stack)
    finish(e, active);
}

fn finish(e: *images.Entry, active: u32) void {
    const b = e.layers orelse return;
    b.active = if (active < b.count) active else 0;
    all(e);
}

fn decodeInto(e: *images.Entry, l: *Layer, f: []const u8) void {
    var img = image.decodeData(A, f) catch return;
    defer img.deinit(A);
    if (img.w != e.img.w or img.h != e.img.h or img.hdr or img.px.len != l.px.len) return;
    for (img.px, l.px) |*p, *o| {
        for (0..4) |c| o[c] = @intFromFloat(std.math.clamp(p[c], 0, 1) * 255 + 0.5);
    }
}

const t_ = std.testing;

test "the composite's arithmetic" {
    var b8 = [_][4]u8{.{ 200, 100, 50, 255 }};
    var fl = [_][4]f32{.{ 0, 0, 0, 0 }};
    var e: images.Entry = .{ .img = .{ .w = 1, .h = 1, .px = fl[0..], .hdr = false }, .b8 = b8[0..] };
    var base = [_][4]u8{.{ 200, 100, 50, 255 }};
    var top = [_][4]u8{.{ 0, 0, 0, 0 }};
    var b = Block{ .count = 2, .active = 1 };
    b.l[0] = .{ .px = base[0..] };
    b.l[1] = .{ .px = top[0..] };
    texel(&e, &b, 0);
    try t_.expectEqual([4]u8{ 200, 100, 50, 255 }, e.b8[0]); // (transparent: the base)
    top[0] = .{ 255, 0, 0, 255 };
    b.l[1].opac = 0.5;
    texel(&e, &b, 0);
    try t_.expectEqual(@as(u8, 228), e.b8[0][0]);
    try t_.expectEqual(@as(u8, 50), e.b8[0][1]);
    b.l[1].blend = 1;
    b.l[1].opac = 1;
    texel(&e, &b, 0);
    try t_.expectEqual([4]u8{ 200, 0, 0, 255 }, e.b8[0]);
    b.l[1].blend = 2;
    texel(&e, &b, 0);
    try t_.expectEqual(@as(u8, 255), e.b8[0][0]);
    b.l[0].vis = 0;
    b.l[1].vis = 0;
    texel(&e, &b, 0);
    try t_.expectEqual([4]u8{ 0, 0, 0, 255 }, e.b8[0]);
}

test "a blend outside the three is normal" {
    var fl = [_][4]f32{.{ 0, 0, 0, 0 }};
    var b8 = [_][4]u8{.{ 0, 0, 0, 255 }};
    var e: images.Entry = .{ .img = .{ .w = 1, .h = 1, .px = fl[0..], .hdr = false }, .b8 = b8[0..] };
    var base = [_][4]u8{.{ 10, 20, 30, 255 }};
    var b = Block{ .count = 1 };
    b.l[0] = .{ .px = base[0..], .blend = 77 };
    texel(&e, &b, 0);
    try t_.expectEqual([4]u8{ 10, 20, 30, 255 }, e.b8[0]);
}
