//! Minimal PNG encoder for screenshots and visual tests. Uses uncompressed
//! DEFLATE blocks, which keeps it small and fast at the cost of file size.

const std = @import("std");

/// Writes `pixels` (`0xAARRGGBB`, row 0 at the top) as an 8-bit RGB PNG.
pub fn write(writer: *std.Io.Writer, pixels: []const u32, width: u32, height: u32) std.Io.Writer.Error!void {
    std.debug.assert(pixels.len == @as(usize, width) * height);
    try writer.writeAll("\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // RGB
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(writer, "IHDR", &ihdr);

    const row_bytes = @as(usize, width) * 3 + 1;
    const raw_len = row_bytes * height;
    const block_count = @max(1, std.math.divCeil(usize, raw_len, max_block) catch unreachable);
    const idat_len: u32 = @intCast(2 + block_count * 5 + raw_len + 4);

    var crc: std.hash.Crc32 = .init();
    try beginChunk(writer, "IDAT", idat_len, &crc);
    var body: Body = .{ .writer = writer, .crc = &crc, .remaining = raw_len };
    try body.bytes(&.{ 0x78, 0x01 }); // zlib header, no compression

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        try body.deflated(&.{0}); // PNG filter: none
        const row = pixels[@as(usize, y) * width..][0..width];
        for (row) |p| {
            try body.deflated(&.{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) });
        }
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, body.adler, .big);
    try body.bytes(&adler);
    try endChunk(writer, &crc);

    try chunk(writer, "IEND", "");
}

const max_block = 65535;

/// Streams raw bytes through stored DEFLATE blocks.
const Body = struct {
    writer: *std.Io.Writer,
    crc: *std.hash.Crc32,
    remaining: usize,
    block_left: usize = 0,
    adler: u32 = 1,

    fn bytes(b: *Body, data: []const u8) !void {
        try b.writer.writeAll(data);
        b.crc.update(data);
    }

    fn deflated(b: *Body, data: []const u8) !void {
        // A stored block at a time: whole runs written and checksummed at
        // once, not byte by byte.
        var rest = data;
        while (rest.len > 0) {
            if (b.block_left == 0) {
                const len: u16 = @intCast(@min(b.remaining, max_block));
                const final: u8 = if (b.remaining <= max_block) 1 else 0;
                var header: [5]u8 = undefined;
                header[0] = final;
                std.mem.writeInt(u16, header[1..3], len, .little);
                std.mem.writeInt(u16, header[3..5], ~len, .little);
                try b.bytes(&header);
                b.block_left = len;
            }
            const n = @min(rest.len, b.block_left);
            try b.bytes(rest[0..n]);
            var a: std.hash.Adler32 = .{ .adler = b.adler };
            a.update(rest[0..n]);
            b.adler = a.adler;
            b.block_left -= @intCast(n);
            b.remaining -= n;
            rest = rest[n..];
        }
    }
};

fn beginChunk(writer: *std.Io.Writer, name: *const [4]u8, len: u32, crc: *std.hash.Crc32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, len, .big);
    try writer.writeAll(&buf);
    try writer.writeAll(name);
    crc.update(name);
}

fn endChunk(writer: *std.Io.Writer, crc: *std.hash.Crc32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, crc.final(), .big);
    try writer.writeAll(&buf);
}

fn chunk(writer: *std.Io.Writer, name: *const [4]u8, data: []const u8) !void {
    var crc: std.hash.Crc32 = .init();
    try beginChunk(writer, name, @intCast(data.len), &crc);
    try writer.writeAll(data);
    crc.update(data);
    try endChunk(writer, &crc);
}
