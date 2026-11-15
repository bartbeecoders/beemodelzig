// PNG writing (8-bit RGB, the Sub filter, zlib through std's deflate).
const std = @import("std");
const flate = std.compress.flate;

fn chunk(out: *std.ArrayList(u8), a: std.mem.Allocator, tag: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(a, &len);
    try out.appendSlice(a, tag);
    try out.appendSlice(a, data);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try out.appendSlice(a, &c);
}

/// The image (R G B A bytes, w * h) as a PNG file with alpha.
pub fn encodeRgba(a: std.mem.Allocator, w: u32, h: u32, px: []const [4]u8) ![]u8 {
    const stride = @as(usize, w) * 4 + 1;
    const raw = try a.alloc(u8, stride * h);
    defer a.free(raw);
    for (0..h) |y| {
        const row = raw[y * stride ..][0..stride];
        row[0] = 1;
        var prev = [4]u8{ 0, 0, 0, 0 };
        for (0..w) |x| {
            const p = px[y * w + x];
            for (0..4) |c| row[1 + x * 4 + c] = p[c] -% prev[c];
            prev = p;
        }
    }
    return wrap(a, w, h, 6, raw);
}

/// The image (0xRRGGBB pixels, w * h) as a PNG file.
pub fn encode(a: std.mem.Allocator, w: u32, h: u32, px: []const u32) ![]u8 {
    // the scanlines: filter 1 (Sub) then RGB differences
    const stride = @as(usize, w) * 3 + 1;
    const raw = try a.alloc(u8, stride * h);
    defer a.free(raw);
    for (0..h) |y| {
        const row = raw[y * stride ..][0..stride];
        row[0] = 1;
        var prev = [3]u8{ 0, 0, 0 };
        for (0..w) |x| {
            const p = px[y * w + x];
            const rgb = [3]u8{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) };
            for (0..3) |c| row[1 + x * 3 + c] = rgb[c] -% prev[c];
            prev = rgb;
        }
    }
    return wrap(a, w, h, 2, raw);
}

/// Filtered scanlines as a file (colour type 2 RGB, 6 RGBA).
fn wrap(a: std.mem.Allocator, w: u32, h: u32, colour: u8, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try aw.ensureUnusedCapacity(64);
    const win = try a.alloc(u8, flate.max_window_len);
    defer a.free(win);
    var z = try flate.Compress.init(&aw.writer, win, .zlib, .level_4);
    try z.writer.writeAll(raw);
    try z.finish();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = colour;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(&out, a, "IHDR", &ihdr);
    try chunk(&out, a, "IDAT", aw.written());
    try chunk(&out, a, "IEND", "");
    return out.toOwnedSlice(a);
}

test "a PNG decodes back (std's inflate)" {
    const a = std.testing.allocator;
    var px: [12 * 7]u32 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast((i * 2654435761) & 0xffffff);
    const f = try encode(a, 12, 7, &px);
    defer a.free(f);
    try std.testing.expectEqualSlices(u8, "\x89PNG", f[0..4]);
    // IDAT: inflate and undo the filter
    const idat_len = std.mem.readInt(u32, f[33..37], .big);
    const idat = f[41..][0..idat_len];
    var in: std.Io.Reader = .fixed(idat);
    var buf: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .zlib, &buf);
    var raw: [7 * (12 * 3 + 1)]u8 = undefined;
    try d.reader.readSliceAll(&raw);
    for (0..7) |y| {
        var prev = [3]u8{ 0, 0, 0 };
        for (0..12) |x| {
            var rgb: [3]u8 = undefined;
            for (0..3) |c| rgb[c] = raw[y * 37 + 1 + x * 3 + c] +% prev[c];
            prev = rgb;
            const p = px[y * 12 + x];
            try std.testing.expectEqual(@as(u8, @truncate(p >> 16)), rgb[0]);
            try std.testing.expectEqual(@as(u8, @truncate(p)), rgb[2]);
        }
    }
}
