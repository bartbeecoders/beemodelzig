//! PNG files as the original's png.s writes them (png_encode, png_encode_rgba),
//! byte for byte: each row filtered Sub, or Up when its sum of absolute
//! residuals (as signed bytes) is strictly smaller, then zlib with the original's own deflate (fab.zig: one block of fixed
//! Huffman codes, greedy LZ77) and its Adler-32. The glTF export embeds its
//! textures and the lightmap this way, so its files are the original's.
//! (png.zig, std's deflate, writes other bytes for the same pixels.)
const std = @import("std");
const fab = @import("fab.zig");

/// pixels: 0xAARRGGBB (rgba) or 0x..RRGGBB, w * h, top row first.
pub fn encode(a: std.mem.Allocator, w: u32, h: u32, px: []const u32, rgba: bool) ![]u8 {
    const bpp: usize = if (rgba) 4 else 3;
    const row_bytes = @as(usize, w) * bpp;
    const stride = row_bytes + 1;
    const raw = try a.alloc(u8, stride * h);
    defer a.free(raw);
    const rows = try a.alloc(u8, row_bytes * 2); // the row before, this one
    defer a.free(rows);
    for (0..h) |y| {
        const cur = rows[(y & 1) * row_bytes ..][0..row_bytes];
        const prev = rows[((y + 1) & 1) * row_bytes ..][0..row_bytes];
        for (0..w) |x| {
            const p = px[y * w + x];
            cur[x * bpp] = @truncate(p >> 16);
            cur[x * bpp + 1] = @truncate(p >> 8);
            cur[x * bpp + 2] = @truncate(p);
            if (rgba) cur[x * bpp + 3] = @truncate(p >> 24);
        }
        var sub: u32 = 0;
        var up: u32 = 0;
        for (0..row_bytes) |i| {
            const c = cur[i];
            const l: u8 = if (i >= bpp) cur[i - bpp] else 0;
            sub += @abs(@as(i8, @bitCast(c -% l)));
            const u: u8 = if (y > 0) prev[i] else 0;
            up += @abs(@as(i8, @bitCast(c -% u)));
        }
        const f: u8 = if (up < sub) 2 else 1;
        const out = raw[y * stride ..][0..stride];
        out[0] = f;
        for (0..row_bytes) |i| {
            var c = cur[i];
            if (f == 1) {
                if (i >= bpp) c -%= cur[i - bpp];
            } else if (y > 0) c -%= prev[i];
            out[i + 1] = c;
        }
    }
    var o: std.ArrayList(u8) = .empty;
    errdefer o.deinit(a);
    try o.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8;
    ihdr[9] = if (rgba) 6 else 2;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(a, &o, "IHDR", &ihdr);
    // IDAT: the zlib stream
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(std.heap.page_allocator);
    try z.appendSlice(std.heap.page_allocator, &.{ 0x78, 0x9c });
    try fab.deflate(&z, raw);
    var ad: [4]u8 = undefined;
    std.mem.writeInt(u32, &ad, adler32(raw), .big);
    try z.appendSlice(std.heap.page_allocator, &ad);
    try chunk(a, &o, "IDAT", z.items);
    try chunk(a, &o, "IEND", "");
    return o.toOwnedSlice(a);
}

fn adler32(d: []const u8) u32 {
    var s1: u32 = 1;
    var s2: u32 = 0;
    var i: usize = 0;
    while (i < d.len) {
        const n = @min(d.len - i, 5552);
        for (d[i .. i + n]) |b| {
            s1 += b;
            s2 += s1;
        }
        s1 %= 65521;
        s2 %= 65521;
        i += n;
    }
    return s2 << 16 | s1;
}

fn chunk(a: std.mem.Allocator, o: *std.ArrayList(u8), tag: *const [4]u8, data: []const u8) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(data.len), .big);
    try o.appendSlice(a, &b);
    const start = o.items.len;
    try o.appendSlice(a, tag);
    try o.appendSlice(a, data);
    std.mem.writeInt(u32, &b, fab.crc32(o.items[start..]), .big);
    try o.appendSlice(a, &b);
}

test "a PNG that std's inflate reads back, filters chosen per row" {
    const a = std.testing.allocator;
    var px: [9 * 5]u32 = undefined;
    for (&px, 0..) |*p, i| p.* = if (i / 9 == 2) 0x80102030 else @intCast((i * 2654435761) & 0xffffffff);
    for ([_]bool{ false, true }) |rgba| {
        const f = try encode(a, 9, 5, &px, rgba);
        defer a.free(f);
        try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", f[0..8]);
        try std.testing.expectEqual(@as(u8, if (rgba) 6 else 2), f[25]);
        const n = std.mem.readInt(u32, f[33..37], .big);
        var in: std.Io.Reader = .fixed(f[41..][0..n]);
        var win: [std.compress.flate.max_window_len]u8 = undefined;
        var d: std.compress.flate.Decompress = .init(&in, .zlib, &win);
        const bpp: usize = if (rgba) 4 else 3;
        var raw: [5 * (9 * 4 + 1)]u8 = undefined;
        const st = 9 * bpp + 1;
        try d.reader.readSliceAll(raw[0 .. 5 * st]);
        var prev: [36]u8 = @splat(0);
        for (0..5) |y| {
            var cur: [36]u8 = undefined;
            const r = raw[y * st ..][0..st];
            for (0..9 * bpp) |i| {
                const l: u8 = if (i >= bpp) cur[i - bpp] else 0;
                cur[i] = r[i + 1] +% (if (r[0] == 1) l else prev[i]);
            }
            for (0..9) |x| {
                const p = px[y * 9 + x];
                try std.testing.expectEqual(@as(u8, @truncate(p >> 16)), cur[x * bpp]);
                try std.testing.expectEqual(@as(u8, @truncate(p)), cur[x * bpp + 2]);
                if (rgba) try std.testing.expectEqual(@as(u8, @truncate(p >> 24)), cur[x * bpp + 3]);
            }
            prev = cur;
        }
        // the flat row: Sub (zeros after its first pixel)
        try std.testing.expectEqual(@as(u8, 1), raw[2 * st]);
    }
    try std.testing.expectEqual(@as(u32, 0x11E60398), adler32("Wikipedia"));
}
