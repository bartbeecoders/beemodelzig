// OpenEXR writing (port of exr.s): scanline, half-float B, G, R, ZIP or none.
//
// ZIP blocks hold 16 lines: the bytes are split into even and odd halves,
// delta-coded (the EXR predictor) and deflated inside a zlib stream; a block
// that would not shrink is stored raw, as the format allows. Uncompressed
// files hold one line per block. There is no reader: the original has none.
const std = @import("std");
const flate = std.compress.flate;

const ZIP_LINES = 16;

pub const Error = error{ BadSize, OutOfMemory };

const head1 = "\x76\x2f\x31\x01\x02\x00\x00\x00" ++
    "channels\x00chlist\x00" ++ le32(55) ++
    chan('B') ++ chan('G') ++ chan('R') ++ "\x00" ++
    "compression\x00compression\x00" ++ le32(1);
const head2 = "lineOrder\x00lineOrder\x00" ++ le32(1) ++ "\x00" ++
    "pixelAspectRatio\x00float\x00" ++ le32(4) ++ le32(0x3f800000) ++
    "screenWindowCenter\x00v2f\x00" ++ le32(8) ++ le32(0) ++ le32(0) ++
    "screenWindowWidth\x00float\x00" ++ le32(4) ++ le32(0x3f800000);

fn le32(comptime v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

/// One channel-list entry: half, not linear, sampling 1 x 1.
fn chan(comptime name: u8) [18]u8 {
    return [2]u8{ name, 0 } ++ le32(1) ++ [4]u8{ 0, 0, 0, 0 } ++ le32(1) ++ le32(1);
}

/// The IEEE half nearest `f` (ties to even, overflow to infinity).
pub fn half(f: f32) u16 {
    const b: u32 = @bitCast(f);
    const sign: u32 = (b >> 16) & 0x8000;
    const m = b & 0x7fffffff;
    if (m > 0x7f800000) return 0x7e00;
    if (m >= 0x477ff000) return @intCast(0x7c00 | sign);
    if (m < 0x38800000) {
        const v: f32 = @as(f32, @bitCast(m)) * 16777216.0; // subnormal: 2^-24 units
        const fl = @floor(v);
        var i: u32 = @intFromFloat(fl);
        const d = v - fl;
        if (d > 0.5 or (d == 0.5 and i & 1 == 1)) i += 1;
        return @intCast(i | sign);
    }
    const r = m + ((m >> 13) & 1) + 0xfff - 0x38000000;
    return @intCast((r >> 13) | sign);
}

const Blocks = struct {
    raw: []u8,
    tmp: []u8,
    window: []u8,
    z: *flate.Compress,
    aw: std.Io.Writer.Allocating,

    /// The bytes as stored: `raw[0..n]` or the deflated form of them.
    fn zip(s: *Blocks, n: usize) Error![]const u8 {
        const half_len = (n + 1) / 2;
        const raw = s.raw[0..n];
        const split = s.tmp[0..n];
        for (raw, 0..) |c, i| {
            if (i & 1 == 0) split[i / 2] = c else split[half_len + i / 2] = c;
        }
        var prev = split[0];
        for (split[1..]) |*c| {
            const v = c.*;
            c.* = v -% prev +% 128;
            prev = v;
        }
        s.aw.clearRetainingCapacity();
        s.aw.ensureUnusedCapacity(64) catch return error.OutOfMemory;
        // (the only failure of a writer into memory is running out of it)
        s.z.* = flate.Compress.init(&s.aw.writer, s.window, .zlib, .level_4) catch return error.OutOfMemory;
        s.z.writer.writeAll(split) catch return error.OutOfMemory;
        s.z.finish() catch return error.OutOfMemory;
        const out = s.aw.written();
        return if (out.len < n) out else raw;
    }
};

/// A ZIP-compressed EXR file of linear RGB pixels, as exr_write_image writes.
pub fn encode(a: std.mem.Allocator, w: u32, h: u32, rgb: []const [3]f32) Error![]u8 {
    return encodeFloats(a, @ptrCast(rgb), w, h, 3, true);
}

/// exr_write: `px` holds w * h pixels of `stride` floats, r g b first.
pub fn encodeFloats(a: std.mem.Allocator, px: []const f32, w: u32, h: u32, stride: u32, zip: bool) Error![]u8 {
    const i32max: u32 = std.math.maxInt(i32);
    if (w == 0 or h == 0 or w > i32max or h > i32max or stride < 3) return error.BadSize;
    const pixels = std.math.mul(usize, w, h) catch return error.BadSize;
    const floats = std.math.mul(usize, pixels, stride) catch return error.BadSize;
    if (px.len != floats) return error.BadSize;
    const lines: u32 = if (zip) ZIP_LINES else 1;
    const blocks = (h - 1) / lines + 1;
    // (the size field of a block is 32 bits)
    const line_bytes = std.math.mul(usize, w, 6) catch return error.BadSize;
    const blk_bytes = std.math.mul(usize, line_bytes, @min(lines, h)) catch return error.BadSize;
    if (blk_bytes > i32max) return error.BadSize;

    const raw = try a.alloc(u8, blk_bytes * 2);
    defer a.free(raw);
    var s: Blocks = .{
        .raw = raw[0..blk_bytes],
        .tmp = raw[blk_bytes..],
        .window = &.{},
        .z = undefined,
        .aw = .init(a),
    };
    defer s.aw.deinit();
    if (zip) {
        s.window = try a.alloc(u8, flate.max_window_len);
        s.z = a.create(flate.Compress) catch |e| {
            a.free(s.window);
            return e;
        };
    }
    defer if (zip) {
        a.destroy(s.z);
        a.free(s.window);
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, head1);
    try out.append(a, if (zip) 3 else 0);
    try out.appendSlice(a, "dataWindow\x00box2i\x00" ++ le32(16));
    try putBox(&out, a, w, h);
    try out.appendSlice(a, "displayWindow\x00box2i\x00" ++ le32(16));
    try putBox(&out, a, w, h);
    try out.appendSlice(a, head2);
    try out.append(a, 0);

    const table = out.items.len;
    try out.appendNTimes(a, 0, @as(usize, blocks) * 8);

    for (0..blocks) |b| {
        const first = b * lines;
        const n = @min(lines, h - first);
        const off: u64 = out.items.len;
        std.mem.writeInt(u64, out.items[table + b * 8 ..][0..8], off, .little);
        var o: usize = 0;
        for (0..n) |l| {
            const row = px[(first + l) * w * stride ..][0 .. @as(usize, w) * stride];
            for ([3]usize{ 2, 1, 0 }) |c| {
                for (0..w) |x| {
                    std.mem.writeInt(u16, s.raw[o..][0..2], half(row[x * stride + c]), .little);
                    o += 2;
                }
            }
        }
        const data = if (zip) try s.zip(o) else s.raw[0..o];
        try put32(&out, a, @intCast(first));
        try put32(&out, a, @intCast(data.len));
        try out.appendSlice(a, data);
    }
    return out.toOwnedSlice(a);
}

fn put32(out: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(a, &b);
}

fn putBox(out: *std.ArrayList(u8), a: std.mem.Allocator, w: u32, h: u32) !void {
    try put32(out, a, 0);
    try put32(out, a, 0);
    try put32(out, a, w - 1);
    try put32(out, a, h - 1);
}

// ---- tests (run from image.zig: `zig test src/image.zig`) ---------------------

const t = std.testing;

test "half: exact encodings, rounding and limits" {
    const cases = [_]struct { f: f32, h: u16 }{
        .{ .f = 0, .h = 0 },
        .{ .f = -0.0, .h = 0x8000 },
        .{ .f = 1, .h = 0x3c00 },
        .{ .f = -2, .h = 0xc000 },
        .{ .f = 0.5, .h = 0x3800 },
        .{ .f = 65504, .h = 0x7bff }, // largest
        .{ .f = 65519.99, .h = 0x7bff }, // still rounds down
        .{ .f = 65520, .h = 0x7c00 }, // overflow
        .{ .f = 1e30, .h = 0x7c00 },
        .{ .f = -1e30, .h = 0xfc00 },
        .{ .f = std.math.inf(f32), .h = 0x7c00 },
        .{ .f = 0x1p-14, .h = 0x0400 }, // smallest normal
        .{ .f = 0x1p-24, .h = 0x0001 }, // smallest subnormal
        .{ .f = 0x1p-25, .h = 0x0000 }, // tie to even: 0
        .{ .f = 0x3p-25, .h = 0x0002 }, // tie to even: 2
        .{ .f = 1.0 + 0x1p-11, .h = 0x3c00 }, // tie to even: down
        .{ .f = 1.0 + 0x3p-11, .h = 0x3c02 }, // tie to even: up
    };
    for (cases) |c| try t.expectEqual(c.h, half(c.f));
    try t.expectEqual(@as(u16, 0x7e00), half(std.math.nan(f32)));
    // against the compiler's own f16, over the whole range of normals
    var b: u32 = 0x33000000;
    while (b < 0x47800000) : (b += 4099) {
        const f: f32 = @bitCast(b);
        const want: f16 = @floatCast(f);
        try t.expectEqual(@as(u16, @bitCast(want)), half(f));
    }
}

test "the header, byte by byte" {
    const a = t.allocator;
    const f = try encode(a, 2, 3, &@as([6][3]f32, @splat(.{ 1, 0.5, 0.25 })));
    defer a.free(f);
    const want = "\x76\x2f\x31\x01\x02\x00\x00\x00" ++
        "channels\x00chlist\x00\x37\x00\x00\x00" ++
        "B\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00" ++
        "G\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00" ++
        "R\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00" ++
        "compression\x00compression\x00\x01\x00\x00\x00\x03" ++
        "dataWindow\x00box2i\x00\x10\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00" ++
        "displayWindow\x00box2i\x00\x10\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00" ++
        "lineOrder\x00lineOrder\x00\x01\x00\x00\x00\x00" ++
        "pixelAspectRatio\x00float\x00\x04\x00\x00\x00\x00\x00\x80\x3f" ++
        "screenWindowCenter\x00v2f\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "screenWindowWidth\x00float\x00\x04\x00\x00\x00\x00\x00\x80\x3f\x00";
    try t.expectEqualSlices(u8, want, f[0..want.len]);
    const off = std.mem.readInt(u64, f[want.len..][0..8], .little);
    try t.expectEqual(want.len + 8, off);
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, f[off..][0..4], .little)); // first line
    const size = std.mem.readInt(u32, f[off + 4 ..][0..4], .little);
    try t.expectEqual(f.len, off + 8 + size);
}

test "bad arguments" {
    const a = t.allocator;
    const px: [12]f32 = @splat(0);
    try t.expectError(error.BadSize, encode(a, 0, 1, &.{}));
    try t.expectError(error.BadSize, encode(a, 1, 0, &.{}));
    try t.expectError(error.BadSize, encode(a, 2, 2, &.{.{ 0, 0, 0 }}));
    try t.expectError(error.BadSize, encodeFloats(a, &px, 2, 2, 2, true));
    try t.expectError(error.BadSize, encodeFloats(a, &px, 0xffffffff, 0xffffffff, 3, true));
    try t.expectError(error.BadSize, encodeFloats(a, &px, 0x80000000, 1, 3, false));
}

const img = @import("image.zig");

fn roundTrip(a: std.mem.Allocator, name: []const u8, px: []const f32, w: u32, h: u32, stride: u32, zip: bool) !void {
    errdefer std.debug.print("in {s}\n", .{name});
    const f = try encodeFloats(a, px, w, h, stride, zip);
    defer a.free(f);
    try img.testkit.write(a, name, f);
    const p = try img.testkit.path(a, name);
    defer a.free(p);
    const info = try img.testkit.tool(a, &.{ "magick", "identify", "-format", "%w %h %C", p });
    defer a.free(info);
    const want = try std.fmt.allocPrint(a, "{d} {d} {s}", .{ w, h, if (zip) "Zip" else "None" });
    defer a.free(want);
    try t.expectEqualStrings(want, std.mem.trim(u8, info, " \n"));
    const ref = try img.testkit.refFloats(a, name, &.{}, "RGB:-");
    defer a.free(ref);
    try t.expectEqual(@as(usize, w) * h * 3, ref.len);
    for (0..@as(usize, w) * h) |i| for (0..3) |c| {
        const v = px[i * stride + c];
        // half a half-float step (2^-11 relative, 2^-25 absolute), and magick's float rounding
        const tol = @abs(v) * (0x1p-11 + 1e-6) + 0x1p-25 + 1e-9;
        try t.expectApproxEqAbs(v, ref[i * 3 + c], tol);
    };
}

test "magick reads what is written, ZIP and uncompressed (half-float rounding as the tolerance)" {
    const a = t.allocator;
    try img.testkit.ensureBase(a);
    const w = 37;
    const h = 49; // (two whole ZIP blocks, one short)
    var px: [w * h * 3]f32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        px[(y * w + x) * 3] = fx / w;
        px[(y * w + x) * 3 + 1] = (fy + 0.5) * 7.3 - 20; // (negative, beyond 1)
        px[(y * w + x) * 3 + 2] = 0.001 * @sin(fx * 0.7) * @cos(fy * 0.3);
    };
    try roundTrip(a, "zip.exr", &px, w, h, 3, true);
    try roundTrip(a, "none.exr", &px, w, h, 3, false);
    // block-size edges (magick cannot read 1-wide or 1-high EXR, not even its own)
    try roundTrip(a, "zip16.exr", px[0 .. 32 * 3], 2, 16, 3, true);
    try roundTrip(a, "zip17.exr", px[0 .. 34 * 3], 2, 17, 3, true);
    try roundTrip(a, "zip2.exr", px[0 .. 10 * 3], 5, 2, 3, true);

    // floats per pixel beyond three: the fourth is skipped
    var four: [6 * 8 * 4]f32 = undefined;
    for (&four, 0..) |*v, i| v.* = if (i % 4 == 3) 1e9 else @as(f32, @floatFromInt(i)) * 0.125;
    try roundTrip(a, "four.exr", &four, 6, 8, 4, true);
}

test "a block that does not shrink is stored raw, and is still read" {
    const a = t.allocator;
    try img.testkit.ensureBase(a);
    const w = 64;
    const h = 16;
    var px: [w * h * 3]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(0xe7e);
    for (&px) |*v| { // uniform halves: nothing for deflate to find
        var b = prng.random().int(u16);
        if (b & 0x7c00 == 0x7c00) b ^= 0x0400; // (no infinities or NaNs)
        v.* = @as(f16, @bitCast(b));
    }
    const f = try encodeFloats(a, &px, w, h, 3, true);
    defer a.free(f);
    try t.expect(f.len > w * h * 6 + 16);
    const off = std.mem.readInt(u64, f[f.len - w * h * 6 - 16 ..][0..8], .little);
    try t.expectEqual(f.len - w * h * 6 - 8, off);
    try t.expectEqual(@as(u32, w * h * 6), std.mem.readInt(u32, f[off + 4 ..][0..4], .little));
    // stored as it is: B of the first pixel first
    try t.expectEqual(half(px[2]), std.mem.readInt(u16, f[off + 8 ..][0..2], .little));
    try roundTrip(a, "noise.exr", &px, w, h, 3, true);
}

test "a flat image does shrink" {
    const a = t.allocator;
    const px: [64 * 64][3]f32 = @splat(.{ 0.25, 0.5, 0.75 });
    const f = try encode(a, 64, 64, &px);
    defer a.free(f);
    try t.expect(f.len < 1500);
}

fn encodeAndFree(a: std.mem.Allocator, px: []const [3]f32) !void {
    a.free(try encode(a, 3, 20, px));
}

test "out of memory at every allocation: an error, no leak" {
    const px: [60][3]f32 = @splat(.{ 0.25, 0.5, 0.75 });
    try t.checkAllAllocationFailures(t.allocator, encodeAndFree, .{&px});
}

test "the assembly original writes the same pixels and header" {
    const a = t.allocator;
    const bin = t.environ.getPosix("BEE_ORIGINAL") orelse return error.SkipZigTest;
    try img.testkit.ensureBase(a);
    try img.testkit.make(a, "base.png", &.{ "-alpha", "off", "-colorspace", "RGB", "-evaluate", "multiply", "9.5" }, "", "ex.hdr");
    try img.testkit.make(a, "base.png", &.{ "-alpha", "off" }, "PNG24:", "ex.png");
    for ([_][]const u8{ "ex.hdr", "ex.png" }) |name| {
        errdefer std.debug.print("in {s}\n", .{name});
        const src = try img.testkit.read(a, name);
        defer a.free(src);
        var im = try img.decode(a, src);
        defer im.deinit(a);
        const mine = try encodeFloats(a, @ptrCast(im.px), im.w, im.h, 4, true);
        defer a.free(mine);
        try img.testkit.write(a, "mine.exr", mine);
        const ps = try img.testkit.path(a, name);
        defer a.free(ps);
        const po = try img.testkit.path(a, "orig.exr");
        defer a.free(po);
        const code = try std.fmt.allocPrint(a, "n = image(\"{s}\"); op(\"image.save\", n + \" {s}\")", .{ ps, po });
        defer a.free(code);
        a.free(try img.testkit.tool(a, &.{ "env", "XDG_CACHE_HOME=", bin, "--eval", code }));
        const orig = try img.testkit.read(a, "orig.exr");
        defer a.free(orig);
        // the header and the first block's place, byte by byte (the deflate streams differ)
        const hl = std.mem.indexOf(u8, mine, "screenWindowWidth").? + 17 + 7 + 8 + 1 + 8;
        try t.expectEqualSlices(u8, orig[0..hl], mine[0..hl]);
        const x = try img.testkit.refFloats(a, "orig.exr", &.{}, "RGB:-");
        defer a.free(x);
        const y = try img.testkit.refFloats(a, "mine.exr", &.{}, "RGB:-");
        defer a.free(y);
        try t.expectEqualSlices(f32, x, y);
    }
}
