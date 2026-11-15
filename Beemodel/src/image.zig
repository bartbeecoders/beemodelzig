// Image decoding (port of imgread.s, with jpeg.s in jpeg.zig): PNG, JPEG,
// Radiance HDR, to linear RGBA floats.
//
// The original keeps 8-bit sources as sRGB bytes and decodes them when
// sampled, alpha as a plain fraction, never premultiplied; here that happens
// once, at load, with the same curve. 16-bit PNG samples keep their top byte.
// `decodeData` skips the curve, for images that are not colours (the sampler's
// "data" flag in texture.s).
const std = @import("std");
const flate = std.compress.flate;
const jpeg = @import("jpeg.zig");

pub const MAX_SIDE = 16384;

pub const Error = error{
    /// not PNG, JPEG or Radiance HDR
    UnknownFormat,
    /// damaged or unsupported file
    Damaged,
    /// sides beyond 16384, or zero
    TooLarge,
    /// PNG colour type or bit depth
    UnsupportedPng,
    /// progressive, lossless or arithmetic-coded JPEG
    UnsupportedJpeg,
    /// JPEG that is not one or three components
    UnsupportedJpegComponents,
    OutOfMemory,
};

pub const Image = struct {
    w: u32,
    h: u32,
    /// w * h pixels, top row first: linear RGB, straight alpha
    px: [][4]f32,
    /// from an HDR source (values beyond 1, alpha 1), not 8-bit sRGB
    hdr: bool,

    pub fn deinit(self: *Image, a: std.mem.Allocator) void {
        a.free(self.px);
        self.* = undefined;
    }
};

const Lut = [256]f32;

/// Linear value of an sRGB-encoded fraction.
pub fn srgbToLinear(c: f32) f32 {
    if (c <= 0.04045) return c * 0.0773993808;
    return @floatCast(std.math.pow(f64, c * 0.9478672986 + 0.0521327014, 2.4));
}

fn curveLut() Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*e, i| e.* = srgbToLinear(@as(f32, @floatFromInt(i)) / 255.0);
    return lut;
}

fn plainLut() Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*e, i| e.* = @as(f32, @floatFromInt(i)) / 255.0;
    return lut;
}

/// Decode an image file: colours go through the sRGB curve.
pub fn decode(a: std.mem.Allocator, bytes: []const u8) Error!Image {
    const lut = curveLut();
    return decodeWith(a, bytes, &lut);
}

/// Decode an image of data, not colours: 8-bit samples become plain fractions.
pub fn decodeData(a: std.mem.Allocator, bytes: []const u8) Error!Image {
    const lut = plainLut();
    return decodeWith(a, bytes, &lut);
}

fn decodeWith(a: std.mem.Allocator, f: []const u8, lut: *const Lut) Error!Image {
    if (f.len < 8) return error.UnknownFormat;
    if (std.mem.eql(u8, f[0..8], "\x89PNG\r\n\x1a\n")) return decodePng(a, f, lut);
    if (f[0] == 0xff and f[1] == 0xd8) return decodeJpeg(a, f, lut);
    if (f[0] == '#' and f[1] == '?') return decodeHdr(a, f);
    return error.UnknownFormat;
}

fn decodeJpeg(a: std.mem.Allocator, f: []const u8, lut: *const Lut) Error!Image {
    var j = jpeg.decode(a, f) catch |e| return switch (e) {
        error.Damaged => error.Damaged,
        error.Progressive => error.UnsupportedJpeg,
        error.Components => error.UnsupportedJpegComponents,
        error.TooLarge => error.TooLarge,
        error.OutOfMemory => error.OutOfMemory,
    };
    defer j.deinit(a);
    const px = try a.alloc([4]f32, @as(usize, j.w) * j.h);
    for (px, 0..) |*p, i| {
        const s = j.rgb[i * 3 ..][0..3];
        p.* = .{ lut[s[0]], lut[s[1]], lut[s[2]], 1 };
    }
    return .{ .w = j.w, .h = j.h, .px = px, .hdr = false };
}

fn checkSize(w: u32, h: u32) Error!void {
    if (w -% 1 >= MAX_SIDE or h -% 1 >= MAX_SIDE) return error.TooLarge;
}

// ---- PNG: every colour type and bit depth, Adam7, tRNS ---------------------

// x0, y0, dx, dy per pass
const adam7 = [7][4]u8{
    .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 },
    .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 },
};
const plain_pass = [1][4]u8{.{ 0, 0, 1, 1 }};

const Png = struct {
    w: u32 = 0,
    h: u32 = 0,
    depth: u32 = 0,
    ctype: u32 = 0,
    chan: u32 = 0,
    key: ?[3]u16 = null, // tRNS colour key (raw sample values)
    npal: u32 = 0,
    pal: [256][4]u8 = undefined, // r g b a

    fn rowBytes(s: *const Png, pixels: u32) usize {
        return (@as(usize, pixels) * s.chan * s.depth + 7) / 8;
    }

    /// The raw sample (full depth).
    fn sample(s: *const Png, row: []const u8, i: usize) u32 {
        switch (s.depth) {
            8 => return row[i],
            16 => return @as(u32, row[i * 2]) << 8 | row[i * 2 + 1],
            else => {
                const pos = i * s.depth;
                const sh: u5 = @intCast(8 - s.depth - (pos & 7));
                return (@as(u32, row[pos >> 3]) >> sh) & ((@as(u32, 1) << @intCast(s.depth)) - 1);
            },
        }
    }

    /// A sample as 8 bits.
    fn to8(s: *const Png, v: u32) u8 {
        return @intCast(switch (s.depth) {
            1 => v * 255,
            2 => v * 85,
            4 => v * 17,
            8 => v,
            else => v >> 8,
        });
    }

    /// One unfiltered row of a pass into the image.
    fn putRow(s: *const Png, row: []const u8, pass: [4]u8, ry: u32, n: u32, px: [][4]f32, lut: *const Lut) void {
        const y = @as(usize, pass[1]) + @as(usize, ry) * pass[3];
        const out = px[y * s.w ..][0..s.w];
        for (0..n) |i| {
            const si = i * s.chan;
            var c: [4]u8 = undefined;
            switch (s.ctype) {
                3 => {
                    const v = s.sample(row, si);
                    c = if (v < s.npal) s.pal[v] else .{ 0, 0, 0, 255 };
                },
                2, 6 => {
                    var keyed = s.key != null;
                    for (0..3) |k| {
                        const v = s.sample(row, si + k);
                        if (keyed and s.key.?[k] != v) keyed = false;
                        c[k] = s.to8(v);
                    }
                    c[3] = if (s.ctype == 6) s.to8(s.sample(row, si + 3)) else if (keyed) 0 else 255;
                },
                else => {
                    const v = s.sample(row, si);
                    const g = s.to8(v);
                    c = .{ g, g, g, 255 };
                    if (s.ctype == 4) {
                        c[3] = s.to8(s.sample(row, si + 1));
                    } else if (s.key) |k| {
                        if (k[0] == v) c[3] = 0;
                    }
                },
            }
            out[pass[0] + i * pass[2]] = .{
                lut[c[0]],                             lut[c[1]], lut[c[2]],
                @as(f32, @floatFromInt(c[3])) / 255.0,
            };
        }
    }
};

fn passDims(p: [4]u8, w: u32, h: u32) [2]u32 {
    if (w <= p[0] or h <= p[1]) return .{ 0, 0 };
    return .{ (w - p[0] + p[2] - 1) / p[2], (h - p[1] + p[3] - 1) / p[3] };
}

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

fn paeth(a: u32, b: u32, c: u32) u32 {
    const p: i32 = @intCast(a + b);
    const q = p - @as(i32, @intCast(c));
    const pa = @abs(q - @as(i32, @intCast(a)));
    const pb = @abs(q - @as(i32, @intCast(b)));
    const pc = @abs(q - @as(i32, @intCast(c)));
    if (pa <= pb and pa <= pc) return a;
    return if (pb <= pc) b else c;
}

fn unfilter(row: []u8, prev: ?[]const u8, bpp: usize, filter: u8) void {
    if (filter == 0) return;
    for (row, 0..) |*e, i| {
        const left: u32 = if (i >= bpp) row[i - bpp] else 0;
        const up: u32 = if (prev) |p| p[i] else 0;
        const ul: u32 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
        const v = switch (filter) {
            1 => left,
            2 => up,
            3 => (left + up) >> 1,
            else => paeth(left, up, ul),
        };
        e.* +%= @truncate(v);
    }
}

fn inflate(a: std.mem.Allocator, z: []const u8, raw: []u8) Error!void {
    const window = try a.alloc(u8, flate.max_window_len);
    defer a.free(window);
    const dec = try a.create(flate.Decompress);
    defer a.destroy(dec);
    var in = std.Io.Reader.fixed(z);
    dec.* = flate.Decompress.init(&in, .zlib, window);
    dec.reader.readSliceAll(raw) catch return error.Damaged;
    // exactly that much: more data is as wrong as less
    if (dec.reader.takeByte()) |_| return error.Damaged else |e| switch (e) {
        error.EndOfStream => {},
        error.ReadFailed => return error.Damaged,
    }
}

fn decodePng(a: std.mem.Allocator, f: []const u8, lut: *const Lut) Error!Image {
    var s: Png = .{};
    var inter: u32 = 0;
    var seen_ihdr = false;
    var idat: usize = 0;
    // pass 1: header, palette, transparency, IDAT size
    var pos: usize = 8;
    while (f.len - pos >= 12) {
        const n: usize = be32(f[pos..]);
        const tag = f[pos + 4 ..][0..4];
        if (n > f.len - pos - 12) return error.Damaged;
        const d = f[pos + 8 ..][0..n];
        pos += n + 12;
        if (std.mem.eql(u8, tag, "IHDR")) {
            if (n < 13) return error.Damaged;
            s.w = be32(d);
            s.h = be32(d[4..]);
            s.depth = d[8];
            s.ctype = d[9];
            inter = d[12];
            seen_ihdr = true;
        } else if (std.mem.eql(u8, tag, "PLTE")) {
            s.npal = @intCast(@min(n / 3, 256));
            for (s.pal[0..s.npal], 0..) |*e, i| e.* = .{ d[i * 3], d[i * 3 + 1], d[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, tag, "tRNS")) {
            if (!seen_ihdr) continue;
            if (s.ctype == 3) {
                for (d[0..@min(n, s.npal)], 0..) |v, i| s.pal[i][3] = v;
            } else if (n >= 2) {
                var key: [3]u16 = @splat(0);
                key[0] = std.mem.readInt(u16, d[0..2], .big);
                if (s.ctype == 2 or s.ctype == 6) {
                    if (n < 6) continue;
                    key[1] = std.mem.readInt(u16, d[2..4], .big);
                    key[2] = std.mem.readInt(u16, d[4..6], .big);
                }
                s.key = key;
            }
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            idat += n;
        } else if (std.mem.eql(u8, tag, "IEND")) break;
    }
    if (!seen_ihdr) return error.Damaged;
    // the format
    const depth_ok = switch (s.ctype) {
        0 => s.depth == 1 or s.depth == 2 or s.depth == 4 or s.depth == 8 or s.depth == 16,
        2, 4, 6 => s.depth == 8 or s.depth == 16,
        3 => s.depth == 1 or s.depth == 2 or s.depth == 4 or s.depth == 8,
        else => false,
    };
    if (!depth_ok) return error.UnsupportedPng;
    s.chan = switch (s.ctype) {
        2 => 3,
        4 => 2,
        6 => 4,
        else => 1,
    };
    const bpp = (s.chan * s.depth + 7) / 8;
    if (inter > 1 or idat == 0) return error.Damaged;
    try checkSize(s.w, s.h);
    const passes: []const [4]u8 = if (inter != 0) &adam7 else &plain_pass;

    // the raw (filtered) size over the passes
    var raw_size: usize = 0;
    for (passes) |p| {
        const dim = passDims(p, s.w, s.h);
        if (dim[0] == 0 or dim[1] == 0) continue;
        raw_size += (s.rowBytes(dim[0]) + 1) * dim[1];
    }
    // Deflate does not expand a byte more than 1032 times, so a header cannot
    // ask for more memory than its data could fill.
    if (raw_size / 1040 > idat + 16) return error.Damaged;

    const z = try a.alloc(u8, idat);
    defer a.free(z);
    var o: usize = 0;
    pos = 8;
    while (f.len - pos >= 12) {
        const n: usize = be32(f[pos..]);
        const tag = f[pos + 4 ..][0..4];
        if (std.mem.eql(u8, tag, "IDAT")) {
            @memcpy(z[o..][0..n], f[pos + 8 ..][0..n]);
            o += n;
        } else if (std.mem.eql(u8, tag, "IEND")) break;
        pos += n + 12;
    }
    const raw = try a.alloc(u8, raw_size);
    defer a.free(raw);
    try inflate(a, z, raw);

    // every filter known, before the (bigger) image is allocated
    var cur: usize = 0;
    for (passes) |p| {
        const dim = passDims(p, s.w, s.h);
        if (dim[0] == 0 or dim[1] == 0) continue;
        const rb = s.rowBytes(dim[0]);
        for (0..dim[1]) |_| {
            if (raw[cur] > 4) return error.Damaged;
            cur += rb + 1;
        }
    }

    const px = try a.alloc([4]f32, @as(usize, s.w) * s.h);
    cur = 0;
    for (passes) |p| {
        const dim = passDims(p, s.w, s.h);
        if (dim[0] == 0 or dim[1] == 0) continue;
        const rb = s.rowBytes(dim[0]);
        var prev: ?[]const u8 = null;
        for (0..dim[1]) |ry| {
            const row = raw[cur + 1 ..][0..rb];
            unfilter(row, prev, bpp, raw[cur]);
            s.putRow(row, p, @intCast(ry), dim[0], px, lut);
            prev = row;
            cur += rb + 1;
        }
    }
    return .{ .w = s.w, .h = s.h, .px = px, .hdr = false };
}

// ---- Radiance HDR: new-style RLE scanlines or flat pixels ------------------

/// The line at `pos` with its newline, or null when none ends it.
fn hdrLine(f: []const u8, pos: usize) ?[]const u8 {
    const i = std.mem.indexOfScalarPos(u8, f, pos, '\n') orelse return null;
    return f[pos .. i + 1];
}

fn hdrNum(f: []const u8, pos: *usize) u32 {
    var p = pos.*;
    while (p < f.len and f[p] == ' ') p += 1;
    var v: u32 = 0;
    while (p < f.len and f[p] >= '0' and f[p] <= '9') {
        v = v * 10 + (f[p] - '0');
        if (v > 1 << 20) break;
        p += 1;
    }
    pos.* = p;
    return v;
}

/// One RLE-coded line (channels stored planar) into `line` (RGBE per pixel).
fn hdrRle(f: []const u8, pos: *usize, line: []u8, w: u32) Error!void {
    var p = pos.*;
    for (0..4) |ch| {
        var x: usize = 0;
        while (x < w) {
            if (p >= f.len) return error.Damaged;
            const c: usize = f[p];
            p += 1;
            if (c > 128) { // a run
                const n = c - 128;
                if (x + n > w or p >= f.len) return error.Damaged;
                const v = f[p];
                p += 1;
                for (0..n) |_| {
                    line[x * 4 + ch] = v;
                    x += 1;
                }
            } else { // literals
                if (c == 0 or x + c > w or f.len - p < c) return error.Damaged;
                for (f[p..][0..c]) |v| {
                    line[x * 4 + ch] = v;
                    x += 1;
                }
                p += c;
            }
        }
    }
    pos.* = p;
}

fn decodeHdr(a: std.mem.Allocator, f: []const u8) Error!Image {
    var pos: usize = 0;
    while (true) { // header lines up to an empty one
        const l = hdrLine(f, pos) orelse return error.Damaged;
        pos += l.len;
        if (l.len == 1) break;
        if (std.mem.startsWith(u8, l, "FORM")) {
            if (l.len < 11 or !std.mem.eql(u8, l[7..11], "32-b")) return error.Damaged;
        }
    }
    const res = hdrLine(f, pos) orelse return error.Damaged; // "-Y h +X w"
    const data = pos + res.len;
    const bottom_up = if (std.mem.startsWith(u8, res, "-Y"))
        false
    else if (std.mem.startsWith(u8, res, "+Y"))
        true
    else
        return error.Damaged;
    var q: usize = pos + 2;
    const h = hdrNum(f, &q);
    if (q >= f.len or f[q] != ' ') return error.Damaged;
    q += 1;
    if (!std.mem.startsWith(u8, f[q..], "+X")) return error.Damaged;
    q += 2;
    const w = hdrNum(f, &q);
    try checkSize(w, h);

    // The shortest line that can be: the data left bounds the image.
    const rle = w >= 8 and w <= 0x7fff;
    const min_line: usize = if (rle) 4 + 8 * ((@as(usize, w) + 126) / 127) else @as(usize, w) * 4;
    if (@as(usize, h) * min_line > f.len - data) return error.Damaged;

    const line = try a.alloc(u8, @as(usize, w) * 4);
    defer a.free(line);
    const px = try a.alloc([4]f32, @as(usize, w) * h);
    errdefer a.free(px);
    var p = data;
    for (0..h) |row| {
        const left = f.len - p;
        var flat = true;
        if (rle) {
            if (left < 4) return error.Damaged;
            if (f[p] == 2 and f[p + 1] == 2) {
                if ((@as(u32, f[p + 2]) << 8 | f[p + 3]) != w) return error.Damaged;
                p += 4;
                try hdrRle(f, &p, line, w);
                flat = false;
            }
        }
        if (flat) {
            if (left < line.len) return error.Damaged;
            @memcpy(line, f[p..][0..line.len]);
            p += line.len;
        }
        const y = if (bottom_up) h - 1 - row else row;
        const out = px[y * w ..][0..w];
        for (out, 0..) |*o, x| {
            const e: u32 = line[x * 4 + 3]; // 2^(e - 136) as float bits
            const m: f32 = if (e > 9) @bitCast((e - 9) << 23) else 0;
            o.* = .{
                @as(f32, @floatFromInt(line[x * 4])) * m,
                @as(f32, @floatFromInt(line[x * 4 + 1])) * m,
                @as(f32, @floatFromInt(line[x * 4 + 2])) * m,
                1,
            };
        }
    }
    return .{ .w = w, .h = h, .px = px, .hdr = true };
}

// ---- tests ---------------------------------------------------------------
//
// `zig test src/image.zig` runs these and those of jpeg.zig and exr.zig.
// Reference pixels come from ImageMagick and jpegtran; fixtures are written to
// $BEE_IMG_FIXTURES (default /tmp/beemodel-img-fixtures), and $BEE_FUZZ_ROUNDS
// scales the fuzzing (default 1). Without magick those tests are skipped.
// $BEE_ORIGINAL names a build of the assembly original to compare with.

test {
    _ = jpeg;
    _ = @import("exr.zig");
}

const t = std.testing;

pub const testkit = struct {
    var dir_ready = false;

    pub fn fixtureDir() []const u8 {
        return t.environ.getPosix("BEE_IMG_FIXTURES") orelse "/tmp/beemodel-img-fixtures";
    }

    pub fn path(a: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/{s}", .{ fixtureDir(), name });
    }

    /// The tool's standard output; a missing tool skips the test.
    pub fn tool(a: std.mem.Allocator, argv: []const []const u8) ![]u8 {
        const r = std.process.run(a, t.io, .{ .argv = argv }) catch |e| switch (e) {
            error.FileNotFound => return error.SkipZigTest,
            else => return e,
        };
        defer a.free(r.stderr);
        if (!r.term.success()) {
            std.debug.print("{s} failed: {s}\n", .{ argv[0], r.stderr });
            a.free(r.stdout);
            return error.ToolFailed;
        }
        return r.stdout;
    }

    pub fn read(a: std.mem.Allocator, name: []const u8) ![]u8 {
        const p = try path(a, name);
        defer a.free(p);
        return std.Io.Dir.cwd().readFileAlloc(t.io, p, a, .limited(64 << 20));
    }

    pub fn write(a: std.mem.Allocator, name: []const u8, data: []const u8) !void {
        const p = try path(a, name);
        defer a.free(p);
        try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p, .data = data });
    }

    /// magick <in> <args...> <prefix:out>
    pub fn make(a: std.mem.Allocator, in: []const u8, args: []const []const u8, prefix: []const u8, out: []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        const pin = try path(a, in);
        defer a.free(pin);
        const pout = try path(a, out);
        defer a.free(pout);
        const po = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, pout });
        defer a.free(po);
        try argv.appendSlice(a, &.{ "magick", pin });
        try argv.appendSlice(a, args);
        try argv.append(a, po);
        a.free(try tool(a, argv.items));
    }

    /// The source of the magick fixtures: smooth noise with an alpha ramp.
    pub fn ensureBase(a: std.mem.Allocator) !void {
        if (dir_ready) return;
        std.Io.Dir.cwd().createDirPath(t.io, fixtureDir()) catch {};
        const p = try path(a, "base.png");
        defer a.free(p);
        a.free(try tool(a, &.{
            "magick",                        "-seed", "7",      "-size", "67x53",    "plasma:fractal", "(",          "-size",  "67x53",
            "gradient:gray(10%)-gray(100%)", ")",     "-alpha", "off",   "-compose", "CopyOpacity",    "-composite", "-depth", "16",
            p,
        }));
        dir_ready = true;
    }

    /// Native floats of an image, as magick decodes it.
    pub fn refFloats(a: std.mem.Allocator, name: []const u8, pre: []const []const u8, map: []const u8) ![]f32 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        const p = try path(a, name);
        defer a.free(p);
        try argv.appendSlice(a, &.{ "magick", p });
        try argv.appendSlice(a, pre);
        try argv.appendSlice(a, &.{ "-define", "quantum:format=floating-point", "-depth", "32", map });
        const b = try tool(a, argv.items);
        defer a.free(b);
        const out = try a.alloc(f32, b.len / 4);
        @memcpy(std.mem.sliceAsBytes(out), b[0 .. out.len * 4]);
        return out;
    }

    /// An allocator that refuses, and remembers, going past a limit.
    pub const CapAlloc = struct {
        child: std.mem.Allocator,
        cap: usize,
        live: usize = 0,
        peak: usize = 0,
        refused: bool = false,

        pub fn allocator(s: *CapAlloc) std.mem.Allocator {
            return .{ .ptr = s, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn grow(s: *CapAlloc, n: usize) bool {
            if (s.live + n > s.cap) {
                s.refused = true;
                return false;
            }
            s.live += n;
            s.peak = @max(s.peak, s.live);
            return true;
        }
        fn alloc(p: *anyopaque, n: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
            const s: *CapAlloc = @ptrCast(@alignCast(p));
            if (!s.grow(n)) return null;
            return s.child.rawAlloc(n, al, ra) orelse {
                s.live -= n;
                return null;
            };
        }
        fn resize(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
            const s: *CapAlloc = @ptrCast(@alignCast(p));
            if (n > m.len and !s.grow(n - m.len)) return false;
            if (s.child.rawResize(m, al, n, ra)) {
                if (n < m.len) s.live -= m.len - n;
                return true;
            }
            if (n > m.len) s.live -= n - m.len;
            return false;
        }
        fn remap(p: *anyopaque, m: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
            const s: *CapAlloc = @ptrCast(@alignCast(p));
            if (n > m.len and !s.grow(n - m.len)) return null;
            if (s.child.rawRemap(m, al, n, ra)) |r| {
                if (n < m.len) s.live -= m.len - n;
                return r;
            }
            if (n > m.len) s.live -= n - m.len;
            return null;
        }
        fn free(p: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
            const s: *CapAlloc = @ptrCast(@alignCast(p));
            s.live -= m.len;
            s.child.rawFree(m, al, ra);
        }
    };
};

fn byte(v: f32) u32 {
    return @intFromFloat(@round(v * 255));
}

/// Our data decode against magick's 16-bit RGBA; returns the largest channel
/// difference in 8-bit steps and adds the absolute differences to `sum`.
fn compare8(im: *const Image, ref: []const u8, sum: *u64) !u32 {
    try t.expectEqual(@as(usize, im.w) * im.h * 8, ref.len);
    var worst: u32 = 0;
    for (im.px, 0..) |p, i| for (0..4) |c| {
        const r: u32 = std.mem.readInt(u16, ref[(i * 4 + c) * 2 ..][0..2], .little) >> 8;
        const d = @max(r, byte(p[c])) - @min(r, byte(p[c]));
        worst = @max(worst, d);
        sum.* += d;
    };
    return worst;
}

fn refRgba16(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const p = try testkit.path(a, name);
    defer a.free(p);
    return testkit.tool(a, &.{ "magick", p, "-depth", "16", "RGBA:-" });
}

const PngCase = struct {
    name: []const u8,
    prefix: []const u8 = "",
    args: []const []const u8,
    ctype: u8,
    depth: u8,
    inter: u8 = 0,
    trns: bool = false,
};

const opaque_args: []const []const u8 = &.{ "-alpha", "off" };
const gray_args: []const []const u8 = &.{ "-alpha", "off", "-colorspace", "Gray" };

fn pngCases() []const PngCase {
    const binary = [_][]const u8{ "-channel", "A", "-threshold", "50%", "+channel" };
    return &[_]PngCase{
        .{ .name = "rgb8.png", .prefix = "PNG24:", .args = opaque_args, .ctype = 2, .depth = 8 },
        .{ .name = "rgba8.png", .prefix = "PNG32:", .args = &.{}, .ctype = 6, .depth = 8 },
        .{ .name = "rgb16.png", .prefix = "PNG48:", .args = opaque_args, .ctype = 2, .depth = 16 },
        .{ .name = "rgba16.png", .prefix = "PNG64:", .args = &.{}, .ctype = 6, .depth = 16 },
        .{ .name = "pal8.png", .prefix = "PNG8:", .args = opaque_args ++ &[_][]const u8{ "-colors", "200" }, .ctype = 3, .depth = 8 },
        .{ .name = "pal4.png", .args = opaque_args ++ &[_][]const u8{ "-colors", "12", "-define", "png:color-type=3", "-define", "png:bit-depth=4" }, .ctype = 3, .depth = 4 },
        .{ .name = "pal2.png", .args = opaque_args ++ &[_][]const u8{ "-colors", "4", "-define", "png:color-type=3", "-define", "png:bit-depth=2" }, .ctype = 3, .depth = 2 },
        .{ .name = "pal1.png", .args = opaque_args ++ &[_][]const u8{ "-colors", "2", "-define", "png:color-type=3", "-define", "png:bit-depth=1" }, .ctype = 3, .depth = 1 },
        .{ .name = "paltrns.png", .prefix = "PNG8:", .args = &binary ++ &[_][]const u8{ "-colors", "40" }, .ctype = 3, .depth = 8, .trns = true },
        .{ .name = "gray8.png", .args = gray_args ++ &[_][]const u8{ "-depth", "8", "-define", "png:color-type=0" }, .ctype = 0, .depth = 8 },
        .{ .name = "gray16.png", .args = gray_args ++ &[_][]const u8{ "-depth", "16", "-define", "png:color-type=0" }, .ctype = 0, .depth = 16 },
        .{ .name = "gray4.png", .args = gray_args ++ &[_][]const u8{ "-depth", "4", "-define", "png:color-type=0", "-define", "png:bit-depth=4" }, .ctype = 0, .depth = 4 },
        .{ .name = "gray2.png", .args = gray_args ++ &[_][]const u8{ "-depth", "2", "-define", "png:color-type=0", "-define", "png:bit-depth=2" }, .ctype = 0, .depth = 2 },
        .{ .name = "gray1.png", .args = gray_args ++ &[_][]const u8{ "-threshold", "50%", "-depth", "1", "-define", "png:color-type=0", "-define", "png:bit-depth=1" }, .ctype = 0, .depth = 1 },
        .{ .name = "graya8.png", .args = &.{ "-colorspace", "Gray", "-depth", "8", "-define", "png:color-type=4" }, .ctype = 4, .depth = 8 },
        .{ .name = "graya16.png", .args = &.{ "-colorspace", "Gray", "-depth", "16", "-define", "png:color-type=4" }, .ctype = 4, .depth = 16 },
        .{ .name = "keyrgb.png", .args = &binary ++ &[_][]const u8{ "-depth", "8", "-background", "#10203a", "-define", "png:color-type=2" }, .ctype = 2, .depth = 8, .trns = true },
        .{ .name = "keygray.png", .args = &.{ "-colorspace", "Gray", "-channel", "A", "-threshold", "50%", "+channel", "-depth", "8", "-define", "png:color-type=0" }, .ctype = 0, .depth = 8, .trns = true },
        .{ .name = "irgb8.png", .prefix = "PNG24:", .args = opaque_args ++ &[_][]const u8{ "-interlace", "PNG" }, .ctype = 2, .depth = 8, .inter = 1 },
        .{ .name = "irgba8.png", .prefix = "PNG32:", .args = &.{ "-interlace", "PNG" }, .ctype = 6, .depth = 8, .inter = 1 },
        .{ .name = "irgba16.png", .prefix = "PNG64:", .args = &.{ "-interlace", "PNG" }, .ctype = 6, .depth = 16, .inter = 1 },
        .{ .name = "ipal8.png", .prefix = "PNG8:", .args = opaque_args ++ &[_][]const u8{ "-colors", "60", "-interlace", "PNG" }, .ctype = 3, .depth = 8, .inter = 1 },
        .{ .name = "ipal2.png", .args = opaque_args ++ &[_][]const u8{ "-colors", "4", "-interlace", "PNG", "-define", "png:color-type=3", "-define", "png:bit-depth=2" }, .ctype = 3, .depth = 2, .inter = 1 },
        .{ .name = "igray8.png", .args = gray_args ++ &[_][]const u8{ "-depth", "8", "-interlace", "PNG", "-define", "png:color-type=0" }, .ctype = 0, .depth = 8, .inter = 1 },
        .{ .name = "igray1.png", .args = gray_args ++ &[_][]const u8{ "-threshold", "50%", "-depth", "1", "-interlace", "PNG", "-define", "png:color-type=0", "-define", "png:bit-depth=1" }, .ctype = 0, .depth = 1, .inter = 1 },
        // sizes with empty Adam7 passes
        .{ .name = "i1x1.png", .prefix = "PNG32:", .args = &.{ "-resize", "1x1!", "-interlace", "PNG" }, .ctype = 6, .depth = 8, .inter = 1 },
        .{ .name = "i3x2.png", .prefix = "PNG32:", .args = &.{ "-resize", "3x2!", "-interlace", "PNG" }, .ctype = 6, .depth = 8, .inter = 1 },
        .{ .name = "i5x9.png", .prefix = "PNG24:", .args = opaque_args ++ &[_][]const u8{ "-resize", "5x9!", "-interlace", "PNG" }, .ctype = 2, .depth = 8, .inter = 1 },
    };
}

fn makePngs(a: std.mem.Allocator) !void {
    try testkit.ensureBase(a);
    for (pngCases()) |c| try testkit.make(a, "base.png", c.args, c.prefix, c.name);
}

test "PNG: every colour type and depth, equal to magick's 8 bits (tolerance 0)" {
    const a = t.allocator;
    try makePngs(a);
    for (pngCases()) |c| {
        errdefer std.debug.print("in {s}\n", .{c.name});
        const f = try testkit.read(a, c.name);
        defer a.free(f);
        // the fixture is what it claims to be
        try t.expectEqual(c.depth, f[24]);
        try t.expectEqual(c.ctype, f[25]);
        try t.expectEqual(c.inter, f[28]);
        try t.expectEqual(c.trns, std.mem.indexOf(u8, f, "tRNS") != null);
        const ref = try refRgba16(a, c.name);
        defer a.free(ref);
        var im = try decodeData(a, f);
        defer im.deinit(a);
        var sum: u64 = 0;
        try t.expectEqual(@as(u32, 0), try compare8(&im, ref, &sum));
        try t.expect(!im.hdr);
    }
}

test "PNG, JPEG: colours are linear, alpha is not (magick's sRGB to linear, tolerance 1/4096)" {
    const a = t.allocator;
    try makePngs(a);
    try makeJpegs(a);
    for ([_][]const u8{ "rgb8.png", "rgba8.png", "pal8.png", "irgba8.png", "j444.jpg" }) |name| {
        errdefer std.debug.print("in {s}\n", .{name});
        const f = try testkit.read(a, name);
        defer a.free(f);
        var im = try decode(a, f);
        defer im.deinit(a);
        var data = try decodeData(a, f);
        defer data.deinit(a);
        const ref = try testkit.refFloats(a, name, &.{ "-colorspace", "RGB" }, "RGBA:-");
        defer a.free(ref);
        try t.expectEqual(im.px.len * 4, ref.len);
        for (im.px, data.px, 0..) |p, q, i| {
            // (JPEG: magick's own bytes differ a little, so its curve is applied to ours)
            const exp: [4]f32 = if (name[0] == 'j')
                .{ srgbToLinear(q[0]), srgbToLinear(q[1]), srgbToLinear(q[2]), 1 }
            else
                ref[i * 4 ..][0..4].*;
            for (0..4) |c| try t.expectApproxEqAbs(exp[c], p[c], 1.0 / 4096.0);
        }
    }
    // the curve itself, whichever bytes
    try t.expectApproxEqAbs(@as(f32, 0.2158605), srgbToLinear(128.0 / 255.0), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.0003035), srgbToLinear(1.0 / 255.0), 1e-6);
    try t.expectEqual(@as(f32, 1), srgbToLinear(1));
}

// A zlib stream of stored blocks.
fn stored(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "\x78\x01");
    var i: usize = 0;
    while (true) {
        const n = @min(raw.len - i, 65535);
        const last = i + n == raw.len;
        const l: u16 = @intCast(n);
        try out.append(a, if (last) 1 else 0);
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, l)));
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~l)));
        try out.appendSlice(a, raw[i..][0..n]);
        i += n;
        if (last) break;
    }
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Adler32.hash(raw))));
    return out.toOwnedSlice(a);
}

fn pngChunk(out: *std.ArrayList(u8), a: std.mem.Allocator, tag: *const [4]u8, d: []const u8) !void {
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(d.len))));
    try out.appendSlice(a, tag);
    try out.appendSlice(a, d);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(d);
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, crc.final())));
}

const PngOpts = struct { depth: u8 = 8, ctype: u8, inter: u8 = 0, plte: []const u8 = "", trns: []const u8 = "" };

fn mkPng(a: std.mem.Allocator, w: u32, h: u32, o: PngOpts, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var ih: [13]u8 = undefined;
    std.mem.writeInt(u32, ih[0..4], w, .big);
    std.mem.writeInt(u32, ih[4..8], h, .big);
    ih[8] = o.depth;
    ih[9] = o.ctype;
    ih[10] = 0;
    ih[11] = 0;
    ih[12] = o.inter;
    try pngChunk(&out, a, "IHDR", &ih);
    if (o.plte.len != 0) try pngChunk(&out, a, "PLTE", o.plte);
    if (o.trns.len != 0) try pngChunk(&out, a, "tRNS", o.trns);
    const z = try stored(a, raw);
    defer a.free(z);
    // (split: IDAT chunks join)
    try pngChunk(&out, a, "IDAT", z[0 .. z.len / 2]);
    try pngChunk(&out, a, "IDAT", z[z.len / 2 ..]);
    try pngChunk(&out, a, "IEND", "");
    return out.toOwnedSlice(a);
}

fn filterRow(out: []u8, cur: []const u8, prev: []const u8, bpp: usize, ft: u8) void {
    for (cur, 0..) |c, i| {
        const l: u32 = if (i >= bpp) cur[i - bpp] else 0;
        const u: u32 = prev[i];
        const ul: u32 = if (i >= bpp) prev[i - bpp] else 0;
        const pred: u32 = switch (ft) {
            0 => 0,
            1 => l,
            2 => u,
            3 => (l + u) / 2,
            else => paeth(l, u, ul),
        };
        out[i] = c -% @as(u8, @truncate(pred));
    }
}

test "PNG: all five filters, on rows that need their neighbours" {
    const a = t.allocator;
    const w = 7;
    const h = 11;
    var img: [h][w * 4]u8 = undefined;
    var state: u32 = 12345;
    for (&img) |*r| for (r) |*b| {
        state = state *% 1103515245 +% 12345;
        b.* = @truncate(state >> 16);
    };
    var raw: [h * (w * 4 + 1)]u8 = undefined;
    const zero: [w * 4]u8 = @splat(0);
    for (0..h) |y| {
        const ft: u8 = @intCast(y % 5);
        raw[y * (w * 4 + 1)] = ft;
        filterRow(raw[y * (w * 4 + 1) + 1 ..][0 .. w * 4], &img[y], if (y == 0) &zero else &img[y - 1], 4, ft);
    }
    const f = try mkPng(a, w, h, .{ .ctype = 6 }, &raw);
    defer a.free(f);
    var im = try decodeData(a, f);
    defer im.deinit(a);
    for (im.px, 0..) |p, i| for (0..4) |c| {
        try t.expectEqual(@as(u32, img[i / w][i % w * 4 + c]), byte(p[c]));
    };
}

test "PNG: palette indices past the end are opaque black, short tRNS leaves the rest opaque" {
    const a = t.allocator;
    const raw = [_]u8{ 0, 0, 1, 2, 9 };
    const f = try mkPng(a, 4, 1, .{ .ctype = 3, .plte = "\x10\x20\x30\x40\x50\x60\x70\x80\x90", .trns = "\x7f" }, &raw);
    defer a.free(f);
    var im = try decodeData(a, f);
    defer im.deinit(a);
    try t.expectEqual(@as(u32, 0x10), byte(im.px[0][0]));
    try t.expectEqual(@as(u32, 0x7f), byte(im.px[0][3]));
    try t.expectEqual(@as(u32, 0x50), byte(im.px[1][1]));
    try t.expectEqual(@as(f32, 1), im.px[1][3]);
    try t.expectEqual([4]f32{ 0, 0, 0, 1 }, im.px[3]);
}

test "PNG: bad headers, filters and data sizes are errors" {
    const a = t.allocator;
    const raw = [_]u8{ 0, 1, 2, 3, 0, 4, 5, 6 };
    const cases = [_]struct { w: u32, h: u32, o: PngOpts, raw: []const u8, e: Error }{
        .{ .w = 1, .h = 2, .o = .{ .ctype = 5 }, .raw = &raw, .e = error.UnsupportedPng },
        .{ .w = 1, .h = 2, .o = .{ .ctype = 2, .depth = 4 }, .raw = &raw, .e = error.UnsupportedPng },
        .{ .w = 1, .h = 2, .o = .{ .ctype = 3, .depth = 16 }, .raw = &raw, .e = error.UnsupportedPng },
        .{ .w = 1, .h = 2, .o = .{ .ctype = 0, .depth = 3 }, .raw = &raw, .e = error.UnsupportedPng },
        .{ .w = 1, .h = 2, .o = .{ .ctype = 2, .inter = 2 }, .raw = &raw, .e = error.Damaged },
        .{ .w = 0, .h = 2, .o = .{ .ctype = 2 }, .raw = &raw, .e = error.TooLarge },
        .{ .w = 1, .h = 0, .o = .{ .ctype = 2 }, .raw = &raw, .e = error.TooLarge },
        .{ .w = 16385, .h = 1, .o = .{ .ctype = 2 }, .raw = &raw, .e = error.TooLarge },
        .{ .w = 1, .h = 16385, .o = .{ .ctype = 2 }, .raw = &raw, .e = error.TooLarge },
        .{ .w = 0xffffffff, .h = 0xffffffff, .o = .{ .ctype = 6, .depth = 16 }, .raw = &raw, .e = error.TooLarge },
        .{ .w = 1, .h = 2, .o = .{ .ctype = 2 }, .raw = raw[0..7], .e = error.Damaged }, // short
        .{ .w = 1, .h = 2, .o = .{ .ctype = 2 }, .raw = &(raw ++ [_]u8{0}), .e = error.Damaged }, // long
        .{ .w = 1, .h = 2, .o = .{ .ctype = 2 }, .raw = &[_]u8{ 5, 1, 2, 3, 0, 4, 5, 6 }, .e = error.Damaged }, // filter 5
    };
    for (cases) |c| {
        const f = try mkPng(a, c.w, c.h, c.o, c.raw);
        defer a.free(f);
        try t.expectError(c.e, decode(a, f));
    }
}

test "huge dimensions in a tiny file: an error, with no big allocation" {
    const a = t.allocator;
    var cap: testkit.CapAlloc = .{ .child = a, .cap = 1 << 20 };
    const ca = cap.allocator();
    // PNG, at the size limit
    {
        const f = try mkPng(a, 16384, 16384, .{ .ctype = 6, .depth = 16 }, "\x00\x01\x02");
        defer a.free(f);
        try t.expectError(error.Damaged, decode(ca, f));
    }
    // HDR, at the size limit and beyond
    try t.expectError(error.Damaged, decode(ca, "#?RGBE\nFORMAT=32-bit_rle_rgbe\n\n-Y 16384 +X 16384\n\x02\x02"));
    try t.expectError(error.TooLarge, decode(ca, "#?RGBE\n\n-Y 16385 +X 1\nabcd"));
    try t.expectError(error.TooLarge, decode(ca, "#?RGBE\n\n-Y 1 +X 16385\nabcd"));
    try t.expectError(error.TooLarge, decode(ca, "#?RGBE\n\n-Y 0 +X 5\nabcd"));
    try t.expectError(error.Damaged, decode(ca, "#?RGBE\n\n-Y 99999999999999 +X 5\nabcd"));
    // JPEG: SOF0 of 16384 x 16384, 65535 x 65535, 4 x 4 sampled
    for ([_][2]u8{ .{ 0x40, 0x00 }, .{ 0xff, 0xff } }) |s| {
        const f = "\xff\xd8\xff\xc0\x00\x11\x08" ++ s ++ s ++ "\x03\x01\x44\x00\x02\x44\x00\x03\x44\x00\xff\xda\x00\x02";
        const e: Error = if (s[0] == 0x40) error.Damaged else error.TooLarge;
        try t.expectError(e, decode(ca, f));
    }
    try t.expect(!cap.refused);
    try t.expect(cap.peak < 1 << 20);
}

test "unknown and tiny files" {
    const a = t.allocator;
    try t.expectError(error.UnknownFormat, decode(a, ""));
    try t.expectError(error.UnknownFormat, decode(a, "\xff\xd8\xff"));
    try t.expectError(error.UnknownFormat, decode(a, "not an image at all"));
    try t.expectError(error.Damaged, decode(a, "\x89PNG\r\n\x1a\n"));
    try t.expectError(error.Damaged, decode(a, "\xff\xd8\xff\xd9\x00\x00\x00\x00"));
    try t.expectError(error.Damaged, decode(a, "#?RADIANCE"));
}

// ---- JPEG fixtures

const JpegCase = struct {
    name: []const u8,
    args: []const []const u8,
    comps: u8 = 3,
    /// sampling byte of the first component (the others are 0x11)
    y: u8,
    /// the largest and the mean difference from libjpeg-turbo allowed, in 8-bit steps
    tol: u32,
    mean: f64 = 0.4,
    /// the same for Rec. 601 luma (clipped channels make it more than rounding)
    luma: f32 = 2,
};

const jpeg_cases = [_]JpegCase{
    .{ .name = "j444.jpg", .args = opaque_args ++ &[_][]const u8{ "-quality", "92", "-sampling-factor", "4:4:4" }, .y = 0x11, .tol = 3, .mean = 0.06 },
    .{ .name = "j420.jpg", .args = opaque_args ++ &[_][]const u8{ "-quality", "92", "-sampling-factor", "4:2:0" }, .y = 0x22, .tol = 3 },
    .{ .name = "j422.jpg", .args = opaque_args ++ &[_][]const u8{ "-quality", "92", "-sampling-factor", "4:2:2" }, .y = 0x21, .tol = 3 },
    .{ .name = "j440.jpg", .args = opaque_args ++ &[_][]const u8{ "-quality", "92", "-sampling-factor", "4:4:0" }, .y = 0x12, .tol = 3 },
    // libjpeg replicates chroma at 4:1:1 (fancy upsampling stops at 2:1), the
    // original interpolates it at every ratio: luma stays closer
    .{ .name = "j411.jpg", .args = opaque_args ++ &[_][]const u8{ "-quality", "92", "-sampling-factor", "4:1:1" }, .y = 0x41, .tol = 27, .mean = 3.2, .luma = 6 },
    .{ .name = "j420q40.jpg", .args = opaque_args ++ &[_][]const u8{ "-quality", "40", "-sampling-factor", "4:2:0" }, .y = 0x22, .tol = 3 },
    .{ .name = "jgray.jpg", .args = gray_args ++ &[_][]const u8{ "-quality", "85" }, .comps = 1, .y = 0x11, .tol = 1, .mean = 0.03 },
};

fn sofOf(f: []const u8) ?usize {
    var i: usize = 2;
    while (i + 4 <= f.len and f[i] == 0xff) {
        if (f[i + 1] == 0xc0 or f[i + 1] == 0xc1 or f[i + 1] == 0xc2 or f[i + 1] == 0xc9 or f[i + 1] == 0xca) return i;
        i += 2 + std.mem.readInt(u16, f[i + 2 ..][0..2], .big);
    }
    return null;
}

/// Lossless jpegtran of `in`, to compare exactly with its plain decoding.
fn jpegtran(a: std.mem.Allocator, args: []const []const u8, in: []const u8, out: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    const pi = try testkit.path(a, in);
    defer a.free(pi);
    const po = try testkit.path(a, out);
    defer a.free(po);
    try argv.append(a, "jpegtran");
    try argv.appendSlice(a, args);
    try argv.appendSlice(a, &.{ "-outfile", po, pi });
    a.free(try testkit.tool(a, argv.items));
}

fn makeJpegs(a: std.mem.Allocator) !void {
    try testkit.ensureBase(a);
    for (jpeg_cases) |c| try testkit.make(a, "base.png", c.args, "", c.name);
    try testkit.write(a, "seq3.scans", "0: 0 63 0 0;\n1: 0 63 0 0;\n2: 0 63 0 0;\n");
    const sc = try testkit.path(a, "seq3.scans");
    defer a.free(sc);
    try jpegtran(a, &.{ "-restart", "3B" }, "j444.jpg", "jr444.jpg");
    try jpegtran(a, &.{ "-restart", "1" }, "j420.jpg", "jr420.jpg");
    try jpegtran(a, &.{ "-scans", sc }, "j420.jpg", "jnon.jpg");
    try jpegtran(a, &.{ "-scans", sc, "-restart", "2B" }, "j422.jpg", "jnonr.jpg");
    try testkit.make(a, "base.png", opaque_args ++ &[_][]const u8{ "-interlace", "JPEG" }, "", "jprog.jpg");
    try jpegtran(a, &.{"-arithmetic"}, "j444.jpg", "jarith.jpg");
    try testkit.make(a, "base.png", opaque_args ++ &[_][]const u8{ "-colorspace", "CMYK" }, "", "jcmyk.jpg");
}

test "JPEG: equal to libjpeg-turbo within the stated tolerance" {
    const a = t.allocator;
    try makeJpegs(a);
    for (jpeg_cases) |c| {
        errdefer std.debug.print("in {s}\n", .{c.name});
        const f = try testkit.read(a, c.name);
        defer a.free(f);
        const s = sofOf(f) orelse return error.TestUnexpectedResult;
        try t.expectEqual(@as(u8, 0xc0), f[s + 1]);
        try t.expectEqual(c.comps, f[s + 9]);
        try t.expectEqual(c.y, f[s + 11]);
        const ref = try refRgba16(a, c.name);
        defer a.free(ref);
        var im = try decodeData(a, f);
        defer im.deinit(a);
        var sum: u64 = 0;
        const worst = try compare8(&im, ref, &sum);
        const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(im.px.len * 3));
        if (t.environ.getPosix("BEE_IMG_VERBOSE") != null)
            std.debug.print("{s}: max {d}, mean {d:.3}\n", .{ c.name, worst, mean });
        try t.expect(worst <= c.tol);
        try t.expect(mean <= c.mean);
        // chroma filters aside, luma agrees at every ratio
        var luma: f32 = 0;
        for (im.px, 0..) |p, i| {
            var d: [3]f32 = undefined;
            for (0..3) |k| d[k] = @as(f32, @floatFromInt(std.mem.readInt(u16, ref[(i * 4 + k) * 2 ..][0..2], .little) >> 8)) - @as(f32, @floatFromInt(byte(p[k])));
            luma = @max(luma, @abs(0.299 * d[0] + 0.587 * d[1] + 0.114 * d[2]));
        }
        if (t.environ.getPosix("BEE_IMG_VERBOSE") != null) std.debug.print("  luma max {d:.2}\n", .{luma});
        try t.expect(luma <= c.luma);
    }
}

test "JPEG: restart markers and one scan per component change nothing (tolerance 0)" {
    const a = t.allocator;
    try makeJpegs(a);
    const pairs = [_][2][]const u8{
        .{ "jr444.jpg", "j444.jpg" }, .{ "jr420.jpg", "j420.jpg" },
        .{ "jnon.jpg", "j420.jpg" },  .{ "jnonr.jpg", "j422.jpg" },
    };
    for (pairs, 0..) |p, i| {
        errdefer std.debug.print("in {s}\n", .{p[0]});
        const f = try testkit.read(a, p[0]);
        defer a.free(f);
        const g = try testkit.read(a, p[1]);
        defer a.free(g);
        try t.expectEqual(@as(u8, 0xc0), f[sofOf(f).? + 1]);
        // the fixture has what it claims: DRI, RSTn, or several scans
        if (i != 2) {
            try t.expect(std.mem.indexOf(u8, f, "\xff\xdd") != null);
            try t.expect(std.mem.indexOf(u8, f, "\xff\xd0") != null);
        }
        if (i >= 2) try t.expectEqual(@as(usize, 3), std.mem.count(u8, f, "\xff\xda"));
        var x = try decodeData(a, f);
        defer x.deinit(a);
        var y = try decodeData(a, g);
        defer y.deinit(a);
        try t.expectEqualSlices([4]f32, y.px, x.px);
    }
}

test "JPEG: what the original refuses is refused" {
    const a = t.allocator;
    try makeJpegs(a);
    const f = try testkit.read(a, "jprog.jpg");
    defer a.free(f);
    try t.expectEqual(@as(u8, 0xc2), f[sofOf(f).? + 1]);
    try t.expectError(error.UnsupportedJpeg, decode(a, f));
    const g = try testkit.read(a, "jarith.jpg");
    defer a.free(g);
    try t.expectEqual(@as(u8, 0xc9), g[sofOf(g).? + 1]);
    try t.expectError(error.UnsupportedJpeg, decode(a, g));
    const h = try testkit.read(a, "jcmyk.jpg");
    defer a.free(h);
    try t.expectEqual(@as(u8, 4), h[sofOf(h).? + 9]);
    try t.expectError(error.UnsupportedJpegComponents, decode(a, h));
}

// ---- HDR

fn makeHdrs(a: std.mem.Allocator) !void {
    try testkit.ensureBase(a);
    const up = opaque_args ++ &[_][]const u8{ "-colorspace", "RGB", "-evaluate", "multiply", "9.5" };
    try testkit.make(a, "base.png", up, "", "rle.hdr");
    try testkit.make(a, "base.png", up ++ &[_][]const u8{ "-resize", "5x6!" }, "", "flat.hdr");
    try testkit.make(a, "base.png", up ++ &[_][]const u8{ "-resize", "8x3!" }, "", "rle8.hdr");
}

test "HDR: equal to magick's floats (relative tolerance 1e-5)" {
    const a = t.allocator;
    try makeHdrs(a);
    for ([_][]const u8{ "rle.hdr", "flat.hdr", "rle8.hdr" }) |name| {
        errdefer std.debug.print("in {s}\n", .{name});
        const f = try testkit.read(a, name);
        defer a.free(f);
        var im = try decode(a, f);
        defer im.deinit(a);
        try t.expect(im.hdr);
        const ref = try testkit.refFloats(a, name, &.{}, "RGB:-");
        defer a.free(ref);
        try t.expectEqual(im.px.len * 3, ref.len);
        var top: f32 = 0;
        for (im.px, 0..) |p, i| {
            for (0..3) |c| {
                const e = ref[i * 3 + c];
                try t.expectApproxEqAbs(e, p[c], @abs(e) * 1e-5 + 1e-30);
                top = @max(top, p[c]);
            }
            try t.expectEqual(@as(f32, 1), p[3]);
        }
        try t.expect(top > 2); // (values beyond 1 survived)
    }
}

test "HDR: flat, RLE, flipped, and small exponents, from bytes" {
    const a = t.allocator;
    // +Y: the first line stored is the bottom row
    const f = "#?RADIANCE\n# c\nFORMAT=32-bit_rle_rgbe\n\n+Y 2 +X 2\n" ++
        "\x80\x40\x20\x81" ++ "\x80\x00\x00\x09" ++ // bottom
        "\xff\x00\x00\x8a" ++ "\x01\x02\x03\x0a"; // top
    var im = try decode(a, f);
    defer im.deinit(a);
    try t.expectEqual([4]f32{ 1020, 0, 0, 1 }, im.px[0]); // 255 * 2^(138 - 136)
    try t.expectEqual([4]f32{ 1, 0.5, 0.25, 1 }, im.px[2]);
    try t.expectEqual([4]f32{ 0, 0, 0, 1 }, im.px[3]); // (e <= 9: zero)
    try t.expect(im.px[1][0] > 0 and im.px[1][0] < 1e-30);

    // new RLE, 8 wide: runs and literals, per channel
    const g = "#?RGBE\n\n-Y 1 +X 8\n\x02\x02\x00\x08" ++
        "\x88\x80" ++ // r: run of 8
        "\x02\x40\x41\x86\x20" ++ // g: 2 literals, run of 6
        "\x08\x01\x02\x03\x04\x05\x06\x07\x08" ++ // b: 8 literals
        "\x88\x81"; // e
    var jm = try decode(a, g);
    defer jm.deinit(a);
    try t.expectEqual([4]f32{ 1, 0.5, 1.0 / 128.0, 1 }, jm.px[0]);
    try t.expectEqual([4]f32{ 1, 65.0 / 128.0, 2.0 / 128.0, 1 }, jm.px[1]);
    try t.expectEqual([4]f32{ 1, 0.25, 8.0 / 128.0, 1 }, jm.px[7]);

    const bad = [_][]const u8{
        "#?RGBE\nFORMAT=16-bit_rle_rgbe\n\n-Y 1 +X 1\nabcd", // the format
        "#?RGBE\nFORMAT=2\n\n-Y 1 +X 1\nabcd", // (shorter than the check)
        "#?RGBE\n\n+X 1 -Y 1\nabcd", // orientation
        "#?RGBE\n\n-Y 1 -X 1\nabcd",
        "#?RGBE\n\n-Y 1 +X 1\nabc", // short
        "#?RGBE\n\n-Y 1 +X 8\n\x02\x02\x00\x09aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", // RLE of another width
        "#?RGBE\n\n-Y 1 +X 8\n\x02\x02\x00\x08\x89\x80aaaaaaaaaaaaaaaaaaaaaaaaaaaa", // a run too long
        "#?RGBE\n\n-Y 1 +X 8\n\x02\x02\x00\x08\x00\x80aaaaaaaaaaaaaaaaaaaaaaaaaaaa", // zero literals
        "#?RGBE\n\n-Y 1 +X 8\n\x02\x02\x00\x08\x88", // ends in a run
    };
    for (bad) |b| try t.expectError(error.Damaged, decode(a, b));
}

// ---- limits

test "the largest sides decode, one more does not" {
    const a = t.allocator;
    try testkit.ensureBase(a);
    const cases = [_]struct { ok: []const u8, bad: []const u8, out: []const u8, over: []const u8 }{
        .{ .ok = "16384x2!", .bad = "16385x2!", .out = "max.png", .over = "over.png" },
        .{ .ok = "2x16384!", .bad = "2x16385!", .out = "maxh.png", .over = "overh.png" },
        .{ .ok = "16384x2!", .bad = "16385x2!", .out = "max.jpg", .over = "over.jpg" },
        .{ .ok = "2x16384!", .bad = "2x16385!", .out = "maxh.jpg", .over = "overh.jpg" },
        .{ .ok = "16384x2!", .bad = "16385x2!", .out = "max.hdr", .over = "over.hdr" },
        .{ .ok = "2x16384!", .bad = "2x16385!", .out = "maxh.hdr", .over = "overh.hdr" },
    };
    for (cases) |c| {
        errdefer std.debug.print("in {s}\n", .{c.out});
        try testkit.make(a, "base.png", &.{ "-alpha", "off", "-sample", c.ok }, "", c.out);
        try testkit.make(a, "base.png", &.{ "-alpha", "off", "-sample", c.bad }, "", c.over);
        const f = try testkit.read(a, c.out);
        defer a.free(f);
        const g = try testkit.read(a, c.over);
        defer a.free(g);
        var im = try decode(a, f);
        defer im.deinit(a);
        try t.expectEqual(@as(usize, 16384 * 2), im.px.len);
        try t.expectError(error.TooLarge, decode(a, g));
    }
}

// ---- against the original

/// Every pixel as the assembly build decodes it, through its BeeScript:
/// 0..255 for 8-bit images, linear for HDR. Null: no build to ask.
fn original(a: std.mem.Allocator, name: []const u8, w: u32, h: u32) !?[]f64 {
    const bin = t.environ.getPosix("BEE_ORIGINAL") orelse return null;
    const p = try testkit.path(a, name);
    defer a.free(p);
    const px = try a.alloc(f64, @as(usize, w) * h * 4);
    errdefer a.free(px);
    // (its output stops at 64 KiB: a few rows at a time)
    var o: usize = 0;
    var y: u32 = 0;
    while (y < h) : (y += 16) {
        const code = try std.fmt.allocPrint(a,
            \\n = image("{s}")
            \\for y in {d}..{d} {{ for x in 0..{d} {{ print(imgpixel(n, x, y, 0), imgpixel(n, x, y, 1), imgpixel(n, x, y, 2), imgpixel(n, x, y, 3)) }} }}
        , .{ p, y, @min(y + 16, h), w });
        defer a.free(code);
        const out = try testkit.tool(a, &.{ "env", "XDG_CACHE_HOME=", bin, "--eval", code });
        defer a.free(out);
        var it = std.mem.tokenizeAny(u8, out, " \n");
        while (it.next()) |v| : (o += 1) px[o] = try std.fmt.parseFloat(f64, v);
    }
    try t.expectEqual(px.len, o);
    return px;
}

test "the assembly original decodes the same pixels" {
    const a = t.allocator;
    if (t.environ.getPosix("BEE_ORIGINAL") == null) return error.SkipZigTest;
    try makePngs(a);
    try makeJpegs(a);
    try makeHdrs(a);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    for (pngCases()) |c| try names.append(a, c.name);
    for (jpeg_cases) |c| try names.append(a, c.name);
    try names.appendSlice(a, &.{ "jr444.jpg", "jr420.jpg", "jnon.jpg", "jnonr.jpg", "rle.hdr", "flat.hdr", "rle8.hdr" });
    var worst8: f64 = 0;
    var off8: usize = 0;
    var total8: usize = 0;
    var worst_hdr: f64 = 0;
    for (names.items) |name| {
        errdefer std.debug.print("in {s}\n", .{name});
        const f = try testkit.read(a, name);
        defer a.free(f);
        var im = try decodeData(a, f);
        defer im.deinit(a);
        const ref = (try original(a, name, im.w, im.h)).?;
        defer a.free(ref);
        for (im.px, 0..) |p, i| for (0..4) |c| {
            const r = ref[i * 4 + c];
            if (im.hdr) {
                if (c < 3) worst_hdr = @max(worst_hdr, @abs(r - p[c])); // (it prints 6 decimals)
            } else {
                const d = @abs(r - @as(f64, @floatFromInt(byte(p[c]))));
                total8 += 1;
                if (d != 0) off8 += 1;
                worst8 = @max(worst8, d);
            }
        };
    }
    if (t.environ.getPosix("BEE_IMG_VERBOSE") != null)
        std.debug.print("{d} images: 8-bit {d} of {d} samples differ, by at most {d}; HDR by {e}\n", .{ names.items.len, off8, total8, worst8, worst_hdr });
    try t.expect(worst8 == 0);
    try t.expect(worst_hdr <= 1.01e-6);
}

// ---- damage

fn fuzzRounds() usize {
    const s = t.environ.getPosix("BEE_FUZZ_ROUNDS") orelse return 1;
    return std.fmt.parseInt(usize, s, 10) catch 1;
}

/// Decoding must end in an image or an error, inside the memory limit, with
/// sane pixels. Returns whether it decoded.
fn tryDecode(a: std.mem.Allocator, f: []const u8) !bool {
    var cap: testkit.CapAlloc = .{ .child = a, .cap = 64 << 20 };
    var im = decode(cap.allocator(), f) catch |e| {
        try t.expect(!cap.refused);
        try t.expect(e != error.OutOfMemory);
        return false;
    };
    defer im.deinit(cap.allocator());
    try t.expect(!cap.refused);
    try t.expectEqual(@as(usize, im.w) * im.h, im.px.len);
    for (im.px) |p| for (p) |v| {
        try t.expect(std.math.isFinite(v));
        try t.expect(v >= 0);
        if (!im.hdr) try t.expect(v <= 1);
    };
    return true;
}

const Fuzzed = struct { rounds: usize = 0, decoded: usize = 0 };

fn fuzzFile(a: std.mem.Allocator, f: []const u8, rng: std.Random, n: usize, st: *Fuzzed) !void {
    const m = try a.alloc(u8, f.len);
    defer a.free(m);
    for (0..n) |_| {
        @memcpy(m, f);
        const flips = 1 + rng.uintLessThan(usize, 8);
        // the headers are where the structure is: a third of the damage goes there
        const head = @min(f.len, 700);
        for (0..flips) |_| {
            const at = if (rng.uintLessThan(u32, 3) == 0) rng.uintLessThan(usize, head) else rng.uintLessThan(usize, f.len);
            switch (rng.uintLessThan(u32, 3)) {
                0 => m[at] ^= @as(u8, 1) << rng.int(u3),
                1 => m[at] = rng.int(u8),
                else => m[at] = if (rng.boolean()) 0xff else 0,
            }
        }
        st.rounds += 1;
        if (try tryDecode(a, m)) st.decoded += 1;
    }
}

const fuzz_files = [_][]const u8{
    "rgb8.png", "rgba16.png", "irgba16.png", "pal8.png",  "paltrns.png", "gray1.png", "igray1.png",
    "j444.jpg", "j420.jpg",   "j411.jpg",    "jgray.jpg", "jr420.jpg",   "jnon.jpg",  "jnonr.jpg",
    "rle.hdr",  "flat.hdr",   "rle8.hdr",
};

test "truncation: every cut of real files is an error unless the pixels were complete" {
    const a = t.allocator;
    try makePngs(a);
    try makeJpegs(a);
    try makeHdrs(a);
    var cuts: usize = 0;
    for (fuzz_files) |name| {
        errdefer std.debug.print("in {s}\n", .{name});
        const f = try testkit.read(a, name);
        defer a.free(f);
        // the first byte that may go without losing pixels
        const need: usize = switch (name[name.len - 1]) {
            'g' => if (name[name.len - 2] == 'n') blk: {
                // .png: the end of the last IDAT chunk
                const last = std.mem.lastIndexOf(u8, f, "IDAT").?;
                break :blk last + 8 + std.mem.readInt(u32, f[last - 4 ..][0..4], .big);
            } else f.len - 2, // .jpg: all but EOI
            else => f.len, // .hdr
        };
        for (0..f.len) |n| {
            if (f.len > 2000 and n > 256 and n < need - 64 and n % 7 != 0) continue;
            cuts += 1;
            const ok = try tryDecode(a, f[0..n]);
            if (n < need) {
                if (ok) std.debug.print("cut at {d} of {d} decoded\n", .{ n, f.len });
                try t.expect(!ok);
            }
        }
        try t.expect(try tryDecode(a, f));
    }
    if (t.environ.getPosix("BEE_IMG_VERBOSE") != null) std.debug.print("truncations: {d}\n", .{cuts});
}

test "fuzz: random damage over a fixed seed" {
    const a = t.allocator;
    try makePngs(a);
    try makeJpegs(a);
    try makeHdrs(a);
    var prng = std.Random.DefaultPrng.init(0xbee_0001);
    const rng = prng.random();
    var total: Fuzzed = .{};
    for (fuzz_files) |name| {
        errdefer std.debug.print("in {s}\n", .{name});
        const f = try testkit.read(a, name);
        defer a.free(f);
        try fuzzFile(a, f, rng, 1500 * fuzzRounds(), &total);
    }
    // PNG is mostly stopped by inflate: stored blocks let damage reach the
    // filters and the row code too
    const raw = try a.alloc(u8, (67 * 8 + 1) * 53);
    defer a.free(raw);
    for (raw, 0..) |*b, i| b.* = @truncate((i *% 2654435761) >> 13);
    for (0..53) |y| raw[y * (67 * 8 + 1)] = @intCast(y % 5);
    const f = try mkPng(a, 67, 53, .{ .ctype = 6, .depth = 16 }, raw);
    defer a.free(f);
    try fuzzFile(a, f, rng, 1500 * fuzzRounds(), &total);
    if (t.environ.getPosix("BEE_IMG_VERBOSE") != null)
        std.debug.print("fuzz: {d} files, {d} of them decoded\n", .{ total.rounds, total.decoded });
    // (a real share gets through; damage that is always caught tests less)
    try t.expect(total.decoded * 20 > total.rounds);
    try t.expect(total.decoded < total.rounds);
}

fn decodeAndFree(a: std.mem.Allocator, f: []const u8) !void {
    var im = try decode(a, f);
    im.deinit(a);
}

test "out of memory at every allocation: an error, no leak" {
    const a = t.allocator;
    try makePngs(a);
    try makeJpegs(a);
    try makeHdrs(a);
    for ([_][]const u8{ "irgba16.png", "paltrns.png", "j420.jpg", "rle.hdr" }) |name| {
        const f = try testkit.read(a, name);
        defer a.free(f);
        try t.checkAllAllocationFailures(a, decodeAndFree, .{f});
    }
}
