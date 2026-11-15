// An animated PNG, written as the frames come (video.s vd_apng): each frame's
// PNG (png.zig) taken apart into chunks. The file gets the first frame's IHDR,
// acTL, then per frame an fcTL and its image data: IDAT chunks for the first,
// fdAT chunks after. At the end acTL is written again with the frames that are
// there, so a stopped render plays what it has.
const std = @import("std");
const linux = std.os.linux;
const A = std.heap.page_allocator;

const SIG = [8]u8{ 0x89, 'P', 'N', 'G', 13, 10, 26, 10 };
const IEND = [12]u8{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82 };
// (8 signature + 25 IHDR + 8 chunk head)
const ACTL_DATA = 41;
const ACTL_CRC = 49;

pub const Writer = struct {
    fd: i32 = -1,
    /// frames written
    n: u32 = 0,
    total: u32 = 0,
    /// a frame lasts 100 / den s
    den: u16 = 1,
    seq: u32 = 0,
    bad: bool = false,
    scr: []u8 = &.{},

    /// Over path. fps: the animation's. False: it cannot be written.
    pub fn open(w: *Writer, path: [*:0]const u8, total: u32, fps: f32) bool {
        const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(rc) != .SUCCESS) return false;
        w.* = .{ .fd = @intCast(rc), .total = total, .den = denominator(fps) };
        return true;
    }

    fn put(w: *Writer, d: []const u8) void {
        var o: usize = 0;
        while (o < d.len and !w.bad) {
            const r = linux.write(w.fd, d[o..].ptr, d.len - o);
            const e = linux.errno(r);
            if (e == .INTR) continue;
            if (e != .SUCCESS or r == 0) {
                w.bad = true;
                return;
            }
            o += r;
        }
    }

    fn chunk(w: *Writer, tag: *const [4]u8, data: []const u8) void {
        var h: [8]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], @intCast(data.len), .big);
        h[4..8].* = tag.*;
        w.put(&h);
        w.put(data);
        var c = std.hash.Crc32.init();
        c.update(tag);
        c.update(data);
        var e: [4]u8 = undefined;
        std.mem.writeInt(u32, &e, c.final(), .big);
        w.put(&e);
    }

    fn fctl(w: *Writer, width: u32, height: u32) void {
        var d: [26]u8 = @splat(0);
        std.mem.writeInt(u32, d[0..4], w.seq, .big);
        w.seq += 1;
        std.mem.writeInt(u32, d[4..8], width, .big);
        std.mem.writeInt(u32, d[8..12], height, .big);
        // at 0, 0; 100 / den s; dispose none, blend source
        std.mem.writeInt(u16, d[20..22], 100, .big);
        std.mem.writeInt(u16, d[22..24], w.den, .big);
        w.chunk("fcTL", &d);
    }

    /// One frame: a whole PNG file. True when it went in.
    pub fn frame(w: *Writer, png: []const u8, width: u32, height: u32) bool {
        if (png.len < 8 or !std.mem.eql(u8, png[0..8], &SIG)) {
            w.bad = true;
            return false;
        }
        var o: usize = 8;
        var ctl = false;
        while (o + 12 <= png.len) {
            const len = std.mem.readInt(u32, png[o..][0..4], .big);
            const tag = png[o + 4 ..][0..4];
            if (len > png.len - o - 12) break;
            if (std.mem.eql(u8, tag, "IEND")) break;
            if (std.mem.eql(u8, tag, "IHDR")) {
                if (w.n == 0) {
                    w.put(&SIG);
                    w.put(png[o .. o + 12 + len]);
                    var ac: [8]u8 = @splat(0);
                    std.mem.writeInt(u32, ac[0..4], w.total, .big);
                    w.chunk("acTL", &ac); // (plays for ever)
                }
            } else if (std.mem.eql(u8, tag, "IDAT")) {
                if (!ctl) {
                    ctl = true;
                    w.fctl(width, height);
                }
                if (w.n == 0) {
                    w.put(png[o .. o + 12 + len]);
                } else {
                    if (w.scr.len < len + 4) {
                        if (w.scr.len > 0) A.free(w.scr);
                        w.scr = A.alloc(u8, (len + 4) * 2) catch {
                            w.scr = &.{};
                            w.bad = true;
                            return false;
                        };
                    }
                    std.mem.writeInt(u32, w.scr[0..4], w.seq, .big);
                    w.seq += 1;
                    @memcpy(w.scr[4..][0..len], png[o + 8 ..][0..len]);
                    w.chunk("fdAT", w.scr[0 .. len + 4]);
                }
            }
            o += 12 + @as(usize, len);
        }
        w.n += 1;
        return !w.bad;
    }

    /// The end, how many frames. True when the file is made.
    pub fn close(w: *Writer) bool {
        defer {
            _ = linux.close(w.fd);
            w.fd = -1;
            if (w.scr.len > 0) A.free(w.scr);
            w.scr = &.{};
        }
        if (w.n == 0) return false;
        w.put(&IEND);
        var d: [12]u8 = undefined;
        d[0..4].* = "acTL".*;
        std.mem.writeInt(u32, d[4..8], w.n, .big);
        @memset(d[8..12], 0);
        var e: [4]u8 = undefined;
        std.mem.writeInt(u32, &e, std.hash.Crc32.hash(&d), .big);
        if (linux.errno(linux.pwrite(w.fd, d[4..8], 4, ACTL_DATA)) != .SUCCESS) w.bad = true;
        if (linux.errno(linux.pwrite(w.fd, &e, 4, ACTL_CRC)) != .SUCCESS) w.bad = true;
        return !w.bad;
    }
};

/// fps -> the denominator of 100 / den s, in 1 .. 65535.
pub fn denominator(fps: f32) u16 {
    const v = fps * 100 + 0.5;
    if (!std.math.isFinite(v) or v < 1) return 1;
    return if (v >= 65535) 65535 else @intFromFloat(v);
}

test "the delay" {
    try std.testing.expectEqual(@as(u16, 2400), denominator(24));
    try std.testing.expectEqual(@as(u16, 1), denominator(0));
    try std.testing.expectEqual(@as(u16, 65535), denominator(1e9));
    try std.testing.expectEqual(@as(u16, 1), denominator(std.math.nan(f32)));
}

fn readAll(a: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.CannotRead;
    defer _ = linux.close(@intCast(fd));
    var out: std.ArrayList(u8) = .empty;
    var b: [65536]u8 = undefined;
    while (true) {
        const r = linux.read(@intCast(fd), &b, b.len);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        try out.appendSlice(a, b[0..r]);
    }
    return out.items;
}

test "chunks: order, sequence numbers, CRCs, acTL rewritten for a stopped render" {
    const png = @import("png.zig");
    const a = std.heap.page_allocator;
    const path = "/tmp/beemodel-apng-test.apng";
    defer _ = linux.unlink(path);
    var w = Writer{};
    try std.testing.expect(w.open(path, 10, 24));
    var px: [12]u32 = undefined;
    for (0..3) |f| {
        for (&px, 0..) |*p, i| p.* = @intCast((f * 0x204060 + i * 0x010203) & 0xffffff);
        const data = try png.encode(a, 4, 3, &px);
        defer a.free(data);
        try std.testing.expect(w.frame(data, 4, 3));
    }
    try std.testing.expect(w.close());
    const d = try readAll(a, path);
    try std.testing.expectEqualSlices(u8, &SIG, d[0..8]);
    var o: usize = 8;
    var seq: u32 = 0;
    var tags: std.ArrayList(u8) = .empty;
    while (o < d.len) {
        const len = std.mem.readInt(u32, d[o..][0..4], .big);
        const tag = d[o + 4 ..][0..4];
        const crc = std.mem.readInt(u32, d[o + 8 + len ..][0..4], .big);
        try std.testing.expectEqual(std.hash.Crc32.hash(d[o + 4 .. o + 8 + len]), crc);
        try tags.append(a, tag[0]);
        if (std.mem.eql(u8, tag, "acTL")) {
            try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, d[o + 8 ..][0..4], .big));
            try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, d[o + 12 ..][0..4], .big));
        }
        if (std.mem.eql(u8, tag, "fcTL") or std.mem.eql(u8, tag, "fdAT")) {
            try std.testing.expectEqual(seq, std.mem.readInt(u32, d[o + 8 ..][0..4], .big));
            seq += 1;
        }
        o += 12 + len;
    }
    try std.testing.expectEqualStrings("IafIffffI", tags.items);
    try std.testing.expectEqual(@as(u32, 5), seq);
}
