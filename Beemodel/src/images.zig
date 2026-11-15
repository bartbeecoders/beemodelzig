// The scene's images (image.s): loaded from files, named after them, kept until
// the scene is cleared. Not part of undo. Materials and the world refer to them
// by index; .bee keeps the paths (IMGS) and loads them again, in order.
const std = @import("std");
const image = @import("image.zig");
const texture = @import("texture.zig");
const A = std.heap.page_allocator;

pub const MAX = 2048;
pub const Entry = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    path: []u8 = &.{},
    img: image.Image,
    version: u32 = 0,
    /// 8-bit sources as they are (R G B A, top row first): what the sampler reads
    /// (texture.zig); img.px holds their linear colours. Empty for HDR.
    b8: [][4]u8 = &.{},
    /// saved inside the .bee file (IMGD): made here or baked, not a file's
    inside: bool = false,
    /// the file it came from inside a .bee, saved as it was unless baked over
    src: []u8 = &.{},
    /// its paint layers (layers.zig): b8 is then their composite
    layers: ?*@import("layers.zig").Block = null,
};

pub var list: [MAX]Entry = undefined;
pub var count: usize = 0;
var versions: u32 = 0;

pub fn nameOf(i: usize) []const u8 {
    return list[i].name[0..list[i].name_len];
}

pub fn find(nm: []const u8) ?usize {
    for (0..count) |i| {
        if (std.mem.eql(u8, nameOf(i), nm)) return i;
    }
    return null;
}

fn setName(e: *Entry, nm: []const u8) void {
    const n = @min(nm.len, e.name.len);
    @memcpy(e.name[0..n], nm[0..n]);
    e.name_len = @intCast(n);
}

fn readFile(path: []const u8) ?[]u8 {
    const raw = @import("ttf.zig").mapFile(path) orelse return null;
    defer _ = std.os.linux.munmap(raw.ptr, raw.len);
    return A.dupe(u8, raw) catch null;
}

pub const LoadError = error{ CannotRead, BadImage, TooMany };

/// Load a file, or find it loaded: its index.
pub fn load(path: []const u8) LoadError!usize {
    for (0..count) |i| {
        if (std.mem.eql(u8, list[i].path, path)) return i;
    }
    if (count >= MAX) return error.TooMany;
    const bytes = readFile(path) orelse return error.CannotRead;
    defer A.free(bytes);
    const img = image.decodeData(A, bytes) catch return error.BadImage;
    // named after the file, without its extension (world.hdri sky, for sky.hdr)
    return add(std.fs.path.stem(path), path, img);
}

/// image_load, as the original's: always a new image (the same file twice is
/// two), named after the file's base name up to its first '.' (26 bytes at
/// most; "image" when none), made unique with ".001", ".002" ...
pub fn loadNew(path: []const u8) LoadError!usize {
    if (count >= MAX) return error.TooMany;
    const bytes = readFile(path) orelse return error.CannotRead;
    defer A.free(bytes);
    const img = image.decodeData(A, bytes) catch return error.BadImage;
    var nb: [40]u8 = undefined;
    const base = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0..];
    var n: usize = 0;
    while (n < base.len and base[n] != 0 and base[n] != '.' and n < 26) : (n += 1) nb[n] = base[n];
    if (n == 0) {
        @memcpy(nb[0..5], "image");
        n = 5;
    }
    var k: u32 = 0;
    var len = n;
    while (find(nb[0..len]) != null) {
        k += 1;
        nb[n] = '.';
        nb[n + 1] = @truncate('0' + k / 100); // (the original's al: past 999 not a digit)
        nb[n + 2] = @intCast('0' + k % 100 / 10);
        nb[n + 3] = @intCast('0' + k % 10);
        len = n + 4;
    }
    return add(nb[0..len], path, img);
}

/// image_adopt: an image made in memory (R G B A bytes, top row first: a
/// USD import's metallic-roughness map), named as image_load names a file
/// (its base name up to its first '.', unique), saved inside .bee files.
pub fn adopt(nm: []const u8, w: u32, h: u32, rgba: []const [4]u8) LoadError!usize {
    if (count >= MAX) return error.TooMany;
    if (w == 0 or h == 0 or rgba.len != @as(usize, w) * h) return error.BadImage;
    const px = A.alloc([4]f32, rgba.len) catch return error.TooMany;
    for (px, rgba) |*p, b| p.* = .{ @as(f32, @floatFromInt(b[0])) / 255.0, @as(f32, @floatFromInt(b[1])) / 255.0, @as(f32, @floatFromInt(b[2])) / 255.0, @as(f32, @floatFromInt(b[3])) / 255.0 };
    var nb: [40]u8 = undefined;
    const i = try add(uniqueBase(nm, &nb), "", .{ .w = w, .h = h, .px = px, .hdr = false });
    list[i].inside = true;
    return i;
}

/// image_adopt_src: a decoded image (a glTF's) named as image_load names a
/// file (unique), saved inside .bee files; `src`: the bytes it was decoded
/// from, kept to be saved as they are while it is not painted.
pub fn adoptDecoded(nm: []const u8, img: image.Image, src: ?[]const u8) LoadError!usize {
    if (count >= MAX) {
        var im = img;
        im.deinit(A);
        return error.TooMany;
    }
    var nb: [40]u8 = undefined;
    const i = try add(uniqueBase(nm, &nb), "", img);
    list[i].inside = true;
    if (src) |s| list[i].src = A.dupe(u8, s) catch &.{};
    return i;
}

/// image_load's name for a path: its base name up to its first '.' (26
/// bytes at most; "image" when none), made unique with ".001", ".002" ...
fn uniqueBase(path: []const u8, nb: *[40]u8) []const u8 {
    const base = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0..];
    var n: usize = 0;
    while (n < base.len and base[n] != 0 and base[n] != '.' and n < 26) : (n += 1) nb[n] = base[n];
    if (n == 0) {
        @memcpy(nb[0..5], "image");
        n = 5;
    }
    var k: u32 = 0;
    var len = n;
    while (find(nb[0..len]) != null) {
        k += 1;
        nb[n] = '.';
        nb[n + 1] = @truncate('0' + k / 100); // (the original's al: past 999 not a digit)
        nb[n + 2] = @intCast('0' + k % 100 / 10);
        nb[n + 3] = @intCast('0' + k % 10);
        len = n + 4;
    }
    return nb[0..len];
}

/// A decoded image (decodeData: 8-bit samples as fractions) as the scene keeps
/// it: its bytes for the sampler, img.px turned into linear colours.
fn keepBytes(e: *Entry) void {
    if (e.img.hdr) return;
    const b = A.alloc([4]u8, e.img.px.len) catch {
        e.b8 = &.{};
        return;
    };
    for (e.img.px, b) |*p, *o| {
        for (0..4) |c| o[c] = @intFromFloat(std.math.clamp(p[c], 0, 1) * 255 + 0.5);
        p.* = .{ texture.lut[o[0]], texture.lut[o[1]], texture.lut[o[2]], p[3] };
    }
    e.b8 = b;
}

fn add(nm: []const u8, path: []const u8, img: image.Image) LoadError!usize {
    const e = &list[count];
    e.* = .{ .img = img };
    setName(e, nm);
    e.path = A.dupe(u8, path) catch return error.TooMany;
    keepBytes(e);
    versions +%= 1;
    e.version = versions;
    count += 1;
    return count - 1;
}

/// After its bytes changed (a bake): the colours from them; it is saved inside
/// the file from now on.
pub fn bytesChanged(i: usize) void {
    const e = &list[i];
    for (e.img.px, e.b8) |*p, b| p.* = linear(b);
    touched(i);
}

/// The colours of a texel's bytes (keepBytes' after a decode).
pub inline fn linear(b: [4]u8) [4]f32 {
    return .{ texture.lut[b[0]], texture.lut[b[1]], texture.lut[b[2]], @as(f32, @floatFromInt(b[3])) / 255.0 };
}

/// Its pixels are not what any file holds any more (IM_DIRTY = 1), and whatever
/// keys on the image draws it again.
pub fn touched(i: usize) void {
    const e = &list[i];
    e.inside = true;
    if (e.src.len > 0) A.free(e.src);
    e.src = &.{};
    versions +%= 1;
    e.version = versions;
}

/// bytesChanged for a box of it (inclusive).
pub fn rectChanged(i: usize, x0: usize, y0: usize, x1: usize, y1: usize) void {
    const e = &list[i];
    const w: usize = e.img.w;
    for (y0..y1 + 1) |y| {
        for (x0..x1 + 1) |x| e.img.px[y * w + x] = linear(e.b8[y * w + x]);
    }
    touched(i);
}

/// A new image of one colour: its index.
pub fn new(nm: []const u8, w: u32, h: u32, c: [4]f32) LoadError!usize {
    if (count >= MAX or w == 0 or h == 0 or w > image.MAX_SIDE or h > image.MAX_SIDE) return error.BadImage;
    const px = A.alloc([4]f32, @as(usize, w) * h) catch return error.TooMany;
    // (the bytes it would be stored as, then as a decoded file)
    var g = c;
    for (g[0..3]) |*x| {
        const v = std.math.clamp(x.*, 0, 1);
        x.* = if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
    }
    @memset(px, g);
    const i = try add(nm, "", .{ .w = w, .h = h, .px = px, .hdr = false });
    list[i].inside = true;
    return i;
}

pub fn clear() void {
    @import("pthist.zig").clear();
    for (list[0..count]) |*e| {
        @import("layers.zig").free(e);
        e.img.deinit(A);
        if (e.path.len > 0) A.free(e.path);
        if (e.b8.len > 0) A.free(e.b8);
        if (e.src.len > 0) A.free(e.src);
    }
    count = 0;
}

fn embedded(e: *const Entry) bool {
    return e.b8.len > 0 and (e.inside or e.path.len == 0);
}

/// IMGS: count, then per image a length and its path (kept inside: 1, then its name).
pub fn writeChunk(out: anytype) void {
    out.u32_(@intCast(count));
    for (list[0..count]) |*e| {
        if (embedded(e)) {
            out.u32_(@as(u32, e.name_len) + 1);
            out.bytes(&[1]u8{1});
            out.bytes(e.name[0..e.name_len]);
            continue;
        }
        out.u32_(@intCast(e.path.len));
        out.bytes(e.path);
    }
}

/// IMGD: per embedded image its index, bytes and PNG file.
pub fn writeData(out: anytype) void {
    for (list[0..count], 0..) |*e, i| {
        if (!embedded(e)) continue;
        const png = @import("png.zig");
        const made = if (e.src.len > 0) null else (png.encodeRgba(A, e.img.w, e.img.h, e.b8) catch continue);
        defer if (made) |f| A.free(f);
        const f: []const u8 = made orelse e.src;
        out.u32_(@intCast(i));
        out.u32_(@intCast(f.len));
        out.bytes(f);
    }
}

/// Embedded images into their stand-ins (after readChunk). False: damaged.
pub fn readData(d: []const u8) bool {
    var o: usize = 0;
    var ok = true;
    while (d.len - o >= 8) {
        const ix = std.mem.readInt(u32, d[o..][0..4], .little);
        const n = std.mem.readInt(u32, d[o + 4 ..][0..4], .little);
        o += 8;
        if (n > d.len - o) return false;
        const f = d[o..][0..n];
        o += n;
        if (ix >= count) continue;
        const img = image.decodeData(A, f) catch {
            ok = false;
            continue;
        };
        const e = &list[ix];
        @import("layers.zig").free(e); // (they were this image's)
        e.img.deinit(A);
        if (e.b8.len > 0) A.free(e.b8);
        e.img = img;
        e.b8 = &.{};
        keepBytes(e);
        e.inside = true;
        if (e.src.len > 0) A.free(e.src);
        e.src = A.dupe(u8, f) catch &.{};
        versions +%= 1;
        e.version = versions;
    }
    return ok and o == d.len;
}

/// Load them again. A file gone leaves a grey stand-in: indices stay. False: damaged.
pub fn readChunk(d: []const u8) bool {
    if (d.len < 4) return false;
    const n = std.mem.readInt(u32, d[0..4], .little);
    var o: usize = 4;
    for (0..n) |_| {
        if (o + 4 > d.len) return false;
        const l = std.mem.readInt(u32, d[o..][0..4], .little);
        o += 4;
        if (l > d.len - o or count >= MAX) return false;
        const p = d[o..][0..l];
        o += l;
        if (l > 0 and p[0] == 1) {
            // embedded: a named stand-in (IMGD fills it)
            _ = new(p[1..], 1, 1, .{ 0.2158605, 0.2158605, 0.2158605, 1 }) catch return false;
            continue;
        }
        _ = load(p) catch {
            const i = new(std.fs.path.stem(p), 1, 1, .{ 0.2158605, 0.2158605, 0.2158605, 1 }) catch return false;
            // (the file may come back: the path stays)
            list[i].inside = false;
            A.free(list[i].path);
            list[i].path = A.dupe(u8, p) catch &.{};
        };
    }
    return true;
}
