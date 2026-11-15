//! Landscapes in and out (landio.s): heightmaps, meshes, tiles.
//!
//! landscape.import reads a PNG (grey, grey + alpha, RGB or RGBA; 8 or 16 bits:
//! the first channel, 0..1) or an OpenEXR file (scanlines; no, ZIPS or ZIP
//! compression; half, float or uint; its Y channel, else R, else the first)
//! into a new landscape of 2^k + 1 samples a side (the image resampled unless
//! it is that size) with one Heightmap layer: base + value x height metres
//! (EXR: the values as metres x height, default 1). landscape.export writes the
//! heights as a 16-bit grey PNG (the range lowest..highest) or a float EXR (the
//! heights in metres, the original's header byte for byte), or the splat map
//! as RGBA PNGs (paint layers 1-4, and 5-8 in <name>_2.png). landscape.to_mesh
//! makes it a plain mesh (the display grid, or every sample). landscape.tiles
//! splits it into k x k landscapes (the heights baked into each tile's
//! Heightmap layer, the paint copied).
//!
//! The decoders are the original's (li_png, li_exr), with std's inflate in
//! place of inflate.s; the PNGs written are the original's samples, deflated by
//! std (other bytes, the same pixels).
const std = @import("std");
const linux = std.os.linux;
const scene = @import("scene.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const la = @import("landscape.zig");
const procgen = @import("procgen.zig");
const files = @import("files.zig");

const flate = std.compress.flate;
const Impl = ops.Impl;
const Block = la.Block;
const cvtt = procgen.cvtt;
const maxss = procgen.maxss;
const A = std.heap.page_allocator;

const MAX_SIDE = 16384;

/// A decoded image: its first channel (or the EXR channel), f32 w x h.
pub const Img = struct {
    w: u32,
    h: u32,
    px: []f32,
    pub fn deinit(im: *Img) void {
        A.free(im.px);
    }
};

fn newImg(w: u32, h: u32) ?Img {
    const px = A.alloc(f32, @as(usize, w) * h) catch return null;
    @memset(px, 0);
    return .{ .w = w, .h = h, .px = px };
}

fn be32(d: []const u8) u32 {
    return std.mem.readInt(u32, d[0..4], .big);
}
fn le32(d: []const u8) u32 {
    return std.mem.readInt(u32, d[0..4], .little);
}

/// zlib_inflate: exactly `out.len` bytes from a zlib stream (the header's
/// checks as inflate.s's; no Adler-32 check, as there). False otherwise.
fn zinflate(src: []const u8, out: []u8) bool {
    if (src.len < 2) return false;
    const cmf: u32 = src[0];
    const flg: u32 = src[1];
    if (cmf & 15 != 8 or flg & 0x20 != 0 or ((cmf << 8) | flg) % 31 != 0) return false;
    var in: std.Io.Reader = .fixed(src[2..]);
    const win = A.alloc(u8, flate.max_window_len) catch return false;
    defer A.free(win);
    var d: flate.Decompress = .init(&in, .raw, win);
    d.reader.readSliceAll(out) catch return false;
    var one: [1]u8 = undefined;
    const more = d.reader.readSliceShort(&one) catch return false;
    return more == 0;
}

// ---- PNG -------------------------------------------------------------------------------

/// li_png: the first channel of an 8- or 16-bit PNG (not interlaced), x 1/255
/// or x 1/65535 (as the original's constants). Null: not one it reads.
pub fn decodePng(d: []const u8) ?Img {
    if (d.len < 33) return null;
    if (!std.mem.eql(u8, d[0..8], "\x89PNG\r\n\x1a\n")) return null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(A);
    var w: u32 = 0;
    var h: u32 = 0;
    var depth: u32 = 0;
    var colour: u32 = 0;
    var o: usize = 8;
    while (o + 12 <= d.len) {
        const len: usize = be32(d[o..]);
        if (o + 12 + len > d.len) break;
        const tag = le32(d[o + 4 ..]);
        if (tag == 0x52444849) { // IHDR
            if (o + 21 > d.len) return null;
            w = be32(d[o + 8 ..]);
            h = be32(d[o + 12 ..]);
            depth = d[o + 16];
            colour = d[o + 17];
            if (d[o + 20] != 0) return null; // (interlaced: no)
        } else if (tag == 0x54414449) { // IDAT
            idat.appendSlice(A, d[o + 8 .. o + 8 + len]) catch return null;
        } else if (tag == 0x444e4549) break; // IEND
        o += 12 + len;
    }
    if (w == 0 or w > MAX_SIDE or h == 0 or h > MAX_SIDE) return null;
    if (depth != 8 and depth != 16) return null;
    const ch: u32 = switch (colour) {
        0 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => return null,
    };
    const bpp: usize = depth / 8 * ch;
    const stride: usize = bpp * w;
    const rows = A.alloc(u8, (stride + 1) * h) catch return null;
    defer A.free(rows);
    if (!zinflate(idat.items, rows)) return null;
    var im = newImg(w, h) orelse return null;
    var prev: ?[]u8 = null;
    for (0..h) |y| {
        const f = rows[y * (stride + 1)];
        const r = rows[y * (stride + 1) + 1 ..][0..stride];
        for (0..stride) |c| {
            const a: u32 = if (c >= bpp) r[c - bpp] else 0;
            const b: u32 = if (prev) |p| p[c] else 0;
            const cc: u32 = if (prev != null and c >= bpp) prev.?[c - bpp] else 0;
            var v: u32 = r[c];
            switch (f) {
                1 => v += a,
                2 => v += b,
                3 => v += (a + b) >> 1,
                4 => {
                    const p: i32 = @as(i32, @intCast(a + b)) - @as(i32, @intCast(cc));
                    const pa = @abs(p - @as(i32, @intCast(a)));
                    const pb = @abs(p - @as(i32, @intCast(b)));
                    const pc = @abs(p - @as(i32, @intCast(cc)));
                    v += if (pa <= pb and pa <= pc) a else if (pb <= pc) b else cc;
                },
                else => {},
            }
            r[c] = @truncate(v);
        }
        for (0..w) |x| {
            const k = x * bpp;
            im.px[y * w + x] = if (depth == 16)
                @as(f32, @floatFromInt((@as(u32, r[k]) << 8) | r[k + 1])) * 1.5259022e-5
            else
                @as(f32, @floatFromInt(r[k])) * 0.003921569;
        }
        prev = r;
    }
    return im;
}

// ---- OpenEXR ---------------------------------------------------------------------------

/// li_h2f: a half as a float.
pub fn h2f(x: u16) f32 {
    const sign: u32 = @as(u32, x & 0x8000) << 16;
    const e: u32 = (x >> 10) & 31;
    const mt: u32 = x & 0x3ff;
    if (e == 0) {
        if (mt == 0) return @bitCast(sign);
        const v: f32 = @as(f32, @floatFromInt(mt)) * @as(f32, @bitCast(@as(u32, 0x33800000)));
        return @bitCast(@as(u32, @bitCast(v)) | sign);
    }
    if (e == 31) return @bitCast(sign | 0x7f800000 | (mt << 13));
    return @bitCast(((e + 112) << 23) | (mt << 13) | sign);
}

/// li_exr: Y (a one-letter name), else R, else the first channel, of a
/// scanline file (no, ZIPS or ZIP compression). Null: not one it reads.
/// (Unlike the original, blocks whose lines lie outside the data window are
/// left out, and a block's bytes must lie inside the file.)
pub fn decodeExr(d: []const u8) ?Img {
    if (d.len < 16) return null;
    if (le32(d) != 0x01312f76) return null;
    if (le32(d[4..]) & 0x1e00 != 0) return null;
    var nch: u32 = 0;
    var chosen: i32 = -1;
    var types: [8]u32 = undefined;
    var sizes: [8]u32 = undefined;
    var comp: u32 = 0;
    var dw = [4]i32{ 0, 0, 0, 0 };
    var o: usize = 8;
    while (true) {
        if (o >= d.len) return null;
        if (d[o] == 0) break;
        const name0 = o;
        while (true) : (o += 1) {
            if (o >= d.len) return null;
            if (d[o] == 0) break;
        }
        const name = d[name0..o];
        o += 1;
        while (true) : (o += 1) {
            if (o >= d.len) return null;
            if (d[o] == 0) break;
        }
        o += 1;
        if (o + 4 > d.len) return null;
        const size: usize = le32(d[o..]);
        o += 4;
        if (o + size > d.len) return null;
        const v = d[o .. o + size];
        if (std.mem.eql(u8, name, "channels")) {
            var p: usize = 0;
            while (p < v.len and v[p] != 0) {
                const n0 = p;
                while (true) : (p += 1) {
                    if (p >= v.len) return null;
                    if (v[p] == 0) break;
                }
                p += 1;
                if (nch >= 8) return null;
                if (o + p + 4 > d.len) return null;
                const t = le32(d[o + p ..]);
                if (t > 2) return null;
                types[nch] = t;
                sizes[nch] = if (t == 1) 2 else 4;
                if (p - n0 == 2) {
                    if (v[n0] == 'Y') {
                        chosen = @intCast(nch);
                    } else if (v[n0] == 'R' and chosen == -1) {
                        chosen = @as(i32, @intCast(nch)) | 0x100; // (R: until a Y comes)
                    }
                }
                nch += 1;
                p += 16;
            }
        } else if (std.mem.eql(u8, name, "compression")) {
            if (size > 0) comp = v[0];
        } else if (std.mem.eql(u8, name, "dataWindow")) {
            if (o + 16 > d.len) return null;
            for (0..4) |k| dw[k] = @bitCast(le32(d[o + k * 4 ..]));
        }
        o += size;
    }
    o += 1; // the offset table follows
    if (nch == 0) return null;
    const ci: u32 = if (chosen == -1) 0 else @as(u32, @bitCast(chosen)) & 0xff;
    if (ci >= nch) return null;
    var choff: u32 = 0;
    for (0..ci) |k| choff += sizes[k];
    const ctype = types[ci];
    var pix: u32 = 0;
    for (0..nch) |k| pix += sizes[k];
    const w = dw[2] -% dw[0] +% 1;
    const h = dw[3] -% dw[1] +% 1;
    if (w <= 0 or w > MAX_SIDE or h <= 0 or h > MAX_SIDE) return null;
    const uw: u32 = @intCast(w);
    const uh: u32 = @intCast(h);
    const bpl: usize = @as(usize, pix) * uw;
    var lpb: u32 = 1;
    if (comp == 3) {
        lpb = 16;
    } else if (comp > 2 or comp == 1) return null;
    var im = newImg(uw, uh) orelse return null;
    errdefer im.deinit();
    const tmp = A.alloc(u8, bpl * lpb) catch return null;
    defer A.free(tmp);
    const tmp2 = A.alloc(u8, bpl * lpb) catch return null;
    defer A.free(tmp2);
    const nb = (uh + lpb - 1) / lpb;
    for (0..nb) |bi| {
        const te = o + bi * 8;
        if (te + 8 > d.len) return null;
        const off = std.mem.readInt(u64, d[te..][0..8], .little);
        if (off > d.len or off + 8 > d.len) return null;
        const bo: usize = @intCast(off);
        const first: i32 = @as(i32, @bitCast(le32(d[bo..]))) -% dw[1];
        const bsize: usize = le32(d[bo + 4 ..]);
        if (bo + 8 + bsize > d.len) return null;
        var lines: u32 = uh -% @as(u32, @bitCast(first));
        if (lines > lpb) lines = lpb;
        const raw: usize = lines * bpl;
        var src: []const u8 = undefined;
        if (comp != 0 and bsize != raw) {
            if (!zinflate(d[bo + 8 .. bo + 8 + bsize], tmp[0..raw])) return null;
            // the predictor: t[i] += t[i-1] - 128, then the halves interleaved
            var k: usize = 1;
            while (k < raw) : (k += 1) tmp[k] = @truncate(@as(u32, tmp[k - 1]) + tmp[k] -% 128);
            const half = (raw + 1) / 2;
            for (0..raw) |q| tmp2[q] = tmp[if (q & 1 == 0) q / 2 else half + q / 2];
            src = tmp2[0..raw];
        } else {
            if (bo + 8 + raw > d.len) return null;
            src = d[bo + 8 .. bo + 8 + raw];
        }
        for (0..lines) |li| {
            const row = @as(i64, first) + @as(i64, @intCast(li));
            if (row < 0 or row >= uh) continue;
            const line = src[li * bpl + @as(usize, choff) * uw ..];
            const dst = im.px[@as(usize, @intCast(row)) * uw ..][0..uw];
            for (0..uw) |x| {
                dst[x] = switch (ctype) {
                    1 => h2f(std.mem.readInt(u16, line[x * 2 ..][0..2], .little)),
                    2 => @bitCast(le32(line[x * 4 ..])),
                    else => @floatFromInt(le32(line[x * 4 ..])),
                };
            }
        }
    }
    return im;
}

// ---- writing ---------------------------------------------------------------------------

fn pngChunk(out: *std.ArrayList(u8), tag: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(A, &len);
    try out.appendSlice(A, tag);
    try out.appendSlice(A, data);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try out.appendSlice(A, &c);
}

/// png_raw: filtered rows (a filter byte first in each) as a PNG file.
pub fn pngRaw(w: u32, h: u32, depth: u8, colour: u8, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(A);
    defer aw.deinit();
    try aw.ensureUnusedCapacity(64); // (the zlib header goes in before any write)
    const win = try A.alloc(u8, flate.max_window_len);
    defer A.free(win);
    var z = try flate.Compress.init(&aw.writer, win, .zlib, .level_4);
    try z.writer.writeAll(raw);
    try z.finish();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(A);
    try out.appendSlice(A, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = depth;
    ihdr[9] = colour;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try pngChunk(&out, "IHDR", &ihdr);
    try pngChunk(&out, "IDAT", aw.written());
    try pngChunk(&out, "IEND", "");
    return out.toOwnedSlice(A);
}

/// The EXR header the original writes (a float Y channel, no compression),
/// up to the dataWindow's box, then up to the displayWindow's, then the rest.
const exr_h1 = "\x76\x2f\x31\x01\x02\x00\x00\x00" ++
    "channels\x00chlist\x00" ++ "\x13\x00\x00\x00" ++ "Y\x00" ++ "\x02\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "\x01\x00\x00\x00\x01\x00\x00\x00" ++ "\x00" ++
    "compression\x00compression\x00" ++ "\x01\x00\x00\x00" ++ "\x00" ++
    "dataWindow\x00box2i\x00" ++ "\x10\x00\x00\x00";
const exr_h2 = "displayWindow\x00box2i\x00" ++ "\x10\x00\x00\x00";
const exr_h3 = "lineOrder\x00lineOrder\x00" ++ "\x01\x00\x00\x00" ++ "\x00" ++
    "pixelAspectRatio\x00float\x00" ++ "\x04\x00\x00\x00" ++ "\x00\x00\x80\x3f" ++
    "screenWindowCenter\x00v2f\x00" ++ "\x08\x00\x00\x00" ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
    "screenWindowWidth\x00float\x00" ++ "\x04\x00\x00\x00" ++ "\x00\x00\x80\x3f" ++ "\x00";

fn put32(out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(A, &b);
}

/// The heights (N x N) as the original's float EXR, byte for byte.
pub fn exrBytes(n: u32, hs: []const f32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(A);
    const box = [4]u32{ 0, 0, n - 1, n - 1 };
    try out.appendSlice(A, exr_h1);
    for (box) |x| try put32(&out, x);
    try out.appendSlice(A, exr_h2);
    for (box) |x| try put32(&out, x);
    try out.appendSlice(A, exr_h3);
    const first: u64 = out.items.len + @as(u64, n) * 8;
    for (0..n) |r| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, first + r * (@as(u64, n) * 4 + 8), .little);
        try out.appendSlice(A, &b);
    }
    for (0..n) |r| {
        try put32(&out, @intCast(r));
        try put32(&out, n * 4);
        try out.appendSlice(A, std.mem.sliceAsBytes(hs[r * n ..][0..n]));
    }
    return out.toOwnedSlice(A);
}

/// The heights as 16-bit grey rows (filter 0): lowest..highest -> 0..65535.
pub fn heightRows(b: *Block) ![]u8 {
    const n = b.n;
    const stride: usize = @as(usize, n) * 2 + 1;
    const raw = try A.alloc(u8, stride * n);
    const lo = b.hmin;
    const rg = maxss(b.hmax - lo, 1.0e-12);
    const h = la.heights(b);
    for (0..n) |r| {
        const row = raw[r * stride ..][0..stride];
        row[0] = 0;
        for (0..n) |c| {
            var v = cvtt((h[r * n + c] - lo) / rg * 65535.0 + 0.5);
            if (v < 0) v = 0;
            if (v > 65535) v = 65535;
            row[c * 2 + 1] = @truncate(@as(u32, @intCast(v)) >> 8);
            row[c * 2 + 2] = @truncate(@as(u32, @intCast(v)));
        }
    }
    return raw;
}

/// The splat weights of layers 4 half .. 4 half + 3 as RGBA rows (filter 0).
pub fn splatRows(b: *Block, half: u32) ![]u8 {
    const n = b.n;
    const stride: usize = @as(usize, n) * 4 + 1;
    const raw = try A.alloc(u8, stride * n);
    const sp = la.splat(b);
    for (0..n) |r| {
        raw[r * stride] = 0;
        for (0..n) |c| @memcpy(raw[r * stride + 1 + c * 4 ..][0..4], sp[r * n + c][half * 4 ..][0..4]);
    }
    return raw;
}

// ---- operators -------------------------------------------------------------------------

const s_bad = "  landscape: not understood: ";
const s_read = "  landscape.import: cannot read (a PNG or an OpenEXR heightmap): ";
const s_wfail = "  landscape.export: could not write ";

fn bad() void {
    app.log("{s}{s}", .{ s_bad, ops.arg });
}

/// li_resample: bilinear, w x h into n x n (stretched to the square).
pub fn resampleImg(im: *const Img, out: []f32, n: u32) void {
    const w = im.w;
    const h = im.h;
    const nm1: f32 = @floatFromInt(n - 1);
    const xl: i32 = @max(@as(i32, @intCast(w)) - 2, 0);
    const zl: i32 = @max(@as(i32, @intCast(h)) - 2, 0);
    const cs: usize = if (w > 1) 1 else 0;
    const rs: usize = if (h > 1) w else 0;
    for (0..n) |j| {
        for (0..n) |i| {
            var x = @as(f32, @floatFromInt(i)) * @as(f32, @floatFromInt(w - 1)) / nm1;
            var z = @as(f32, @floatFromInt(j)) * @as(f32, @floatFromInt(h - 1)) / nm1;
            const ix = @min(cvtt(x), xl);
            const iz = @min(cvtt(z), zl);
            x = x - @as(f32, @floatFromInt(ix));
            z = z - @as(f32, @floatFromInt(iz));
            const k: usize = @intCast(iz * @as(i32, @intCast(w)) + ix);
            var h0 = im.px[k];
            const h1 = im.px[k + cs];
            var h2 = im.px[k + rs];
            const h3 = im.px[k + rs + cs];
            h0 = (h1 - h0) * x + h0;
            h2 = (h3 - h2) * x + h2;
            out[j * n + i] = (h2 - h0) * z + h0;
        }
    }
}

/// The samples a side for an image: 2^k + 1 >= its longer side (4097 at most).
pub fn sideFor(w: u32, h: u32) u32 {
    const s = @max(w, h);
    var c: u32 = 65;
    while (c < s and c < 4097) c = c * 2 - 1;
    return c;
}

fn readFile(path: []const u8) ?[]u8 {
    var eb: [600]u8 = undefined;
    const p = files.expandHome(&eb, path) orelse return null;
    const m = @import("ttf.zig").mapFile(p) orelse return null;
    defer _ = linux.munmap(@constCast(m.ptr), m.len);
    return A.dupe(u8, m) catch null;
}

/// do_la_import: landscape.import <file> [size s] [height h] [base b].
fn opImport() void {
    var it = la.Words{ .s = ops.arg };
    const path = it.next() orelse return bad();
    if (path.len > 511) return bad();
    var args = [3]f32{ 0, 0, 0 }; // size (0: a metre a sample), height (0: the default), base
    while (it.next()) |w| {
        const k: usize = if (std.mem.eql(u8, w, "size")) 0 else if (std.mem.eql(u8, w, "height")) 1 else if (std.mem.eql(u8, w, "base")) 2 else return bad();
        args[k] = it.num() orelse return bad();
    }
    const data = readFile(path) orelse return app.log("{s}{s}", .{ s_read, path });
    defer A.free(data);
    var is_png = true;
    var im = decodePng(data) orelse blk: {
        is_png = false;
        break :blk decodeExr(data) orelse return app.log("{s}{s}", .{ s_read, path });
    };
    defer im.deinit();
    const n = sideFor(im.w, im.h);
    const b = la.make(null, n, la.WANT_EXTRA) orelse return la.outOfMemory();
    b.size = if (args[0] > 0) args[0] else @floatFromInt(n - 1);
    b.nl = 1;
    const l = &b.lay[0];
    l.typ = 6;
    l.flg = 0;
    l.str = 1.0;
    l.data = la.extra;
    const height: f32 = if (args[1] > 0) args[1] else if (is_png) 100 else 1;
    const dst = la.arrF(b, l.data);
    if (im.w == n and im.h == n) {
        @memcpy(dst, im.px);
    } else resampleImg(&im, dst, n);
    var k = dst.len;
    while (k > 0) {
        k -= 1;
        dst[k] = dst[k] * height + args[2];
    }
    la.eval(b, 0);
    const mi = la.display(b, null);
    la.unref(b);
    const m_ = mi orelse return la.outOfMemory();
    const i = la.newObject(m_, "Landscape") orelse return;
    scene.selectOnly(i);
    app.log("  imported a heightmap: {d} x {d}", .{ n, n });
    app.dirty = true;
}

fn endsWith(p: []const u8, e: []const u8) bool {
    return p.len >= e.len and std.mem.eql(u8, p[p.len - e.len ..], e);
}

/// li_write: the bytes to the file (atomically); false: not written.
fn writeOut(path: []const u8, data: []const u8) bool {
    var eb: [600]u8 = undefined;
    const p = files.expandHome(&eb, path) orelse return false;
    if (!files.mayWrite(p)) return false;
    @import("atomicfile.zig").write(p, data) catch return false;
    return true;
}

/// do_la_export: <file.png> | <file.exr> | <file.png> splat.
fn opExport() void {
    const a = la.active() orelse return;
    const b = a.b;
    var it = la.Words{ .s = ops.arg };
    const p0 = it.next() orelse return bad();
    if (p0.len > 511) return bad();
    var pb: [520]u8 = undefined;
    @memcpy(pb[0..p0.len], p0);
    var path: []const u8 = pb[0..p0.len];
    var do_splat = false;
    if (it.next()) |w| {
        if (!std.mem.eql(u8, w, "splat")) return bad();
        do_splat = true;
    }
    if (do_splat) {
        if (b.splat == 0) return bad();
        var half: u32 = 0;
        while (true) {
            const raw = splatRows(b, half) catch return la.outOfMemory();
            defer A.free(raw);
            const f = pngRaw(b.n, b.n, 8, 6, raw) catch return la.outOfMemory();
            defer A.free(f);
            if (!writeOut(path, f)) return app.log("{s}{s}", .{ s_wfail, path });
            if (half != 0 or b.np <= 4 or path.len < 4) break;
            // <file>.png -> <file>_2.png
            const L = path.len;
            @memcpy(pb[L - 4 .. L + 2], "_2.png");
            path = pb[0 .. L + 2];
            half = 1;
        }
    } else if (endsWith(path, ".exr")) {
        const f = exrBytes(b.n, la.heights(b)) catch return la.outOfMemory();
        defer A.free(f);
        if (!writeOut(path, f)) return app.log("{s}{s}", .{ s_wfail, path });
    } else if (endsWith(path, ".png")) {
        const raw = heightRows(b) catch return la.outOfMemory();
        defer A.free(raw);
        const f = pngRaw(b.n, b.n, 16, 0, raw) catch return la.outOfMemory();
        defer A.free(f);
        if (!writeOut(path, f)) return app.log("{s}{s}", .{ s_wfail, path });
    } else return bad();
    app.log("  exported {s}", .{path});
}

/// do_la_tomesh: landscape.to_mesh [full]: a plain mesh.
fn opToMesh() void {
    const a = la.active() orelse return;
    const b = a.b;
    var it = la.Words{ .s = ops.arg };
    const full = if (it.next()) |w| std.mem.eql(u8, w, "full") else false;
    var mi: u16 = undefined;
    if (full) {
        if (b.n > 2049) return app.log("  landscape.to_mesh full: 2049 samples a side at most", .{});
        var g = procgen.grid(A, b.n - 1) catch return;
        defer g.deinit(A);
        const n = b.n;
        const cell = b.size / @as(f32, @floatFromInt(n - 1));
        const half = b.size * 0.5;
        const h = la.heights(b);
        for (0..n) |r| {
            for (0..n) |c| g.verts[r * n + c] = .{ @as(f32, @floatFromInt(c)) * cell - half, h[r * n + c], @as(f32, @floatFromInt(r)) * cell - half };
        }
        mi = scene.addMesh(g.verts, g.poff, g.loops) orelse return;
        const me = &scene.meshes[mi].?;
        la.bounds(me);
        la.vcolOf(b, me);
    } else {
        // the display grid as it is (a copy is a plain mesh)
        mi = scene.cloneMesh(scene.objects[a.i].mesh orelse return) orelse return;
    }
    scene.objects[a.i].mesh = mi;
    app.dirty = true;
}

/// do_la_tiles: landscape.tiles <k>: k x k landscapes in its place.
fn opTiles() void {
    const a = la.active() orelse return;
    const src = a.b;
    const msg = "  landscape.tiles <k>: k divides the samples a side less 1 (tiles of 65 samples at least)";
    var it = la.Words{ .s = ops.arg };
    const kf = it.num() orelse return app.log("{s}", .{msg});
    const k = cvtt(kf);
    if (k < 2) return app.log("{s}", .{msg});
    const uk: u32 = @intCast(k);
    if ((src.n - 1) % uk != 0 or (src.n - 1) / uk < 64) return app.log("{s}", .{msg});
    const ts = (src.n - 1) / uk + 1;
    const tsize = src.size / @as(f32, @floatFromInt(uk));
    const lobj = scene.objects[a.i];
    const sp_src = la.splat(src);
    const hs = la.heights(src);
    var bz: u32 = 0;
    while (bz < uk) : (bz += 1) {
        var ax: u32 = 0;
        while (ax < uk) : (ax += 1) {
            const want: u32 = la.WANT_EXTRA | (if (src.splat != 0) la.WANT_SPLAT else 0);
            const b = la.make(null, ts, want) orelse return la.outOfMemory();
            b.paint = src.paint;
            b.np = src.np;
            b.disp = src.disp;
            b.size = tsize;
            b.nl = 1;
            const l = &b.lay[0];
            l.typ = 6;
            l.flg = 0;
            l.str = 1.0;
            l.data = la.extra;
            const dst = la.arrF(b, l.data);
            const dsp = la.splat(b);
            for (0..ts) |r| {
                for (0..ts) |c| {
                    const s = (bz * (ts - 1) + r) * src.n + ax * (ts - 1) + c;
                    dst[r * ts + c] = hs[s];
                    if (src.splat != 0) dsp[r * ts + c] = sp_src[s];
                }
            }
            la.eval(b, 0);
            const mi = la.display(b, null);
            la.unref(b);
            const m_ = mi orelse return la.outOfMemory();
            const t = la.newObject(m_, "Landscape") orelse return la.outOfMemory();
            const o = &scene.objects[t];
            // its place: the landscape's + the tile's centre (scaled)
            o.loc = lobj.loc;
            o.rot = lobj.rot;
            o.rad = lobj.rad;
            o.rad_deg = lobj.rad_deg;
            o.scl = lobj.scl;
            const hsz = src.size * 0.5;
            o.loc[0] = ((@as(f32, @floatFromInt(ax)) + 0.5) * tsize - hsz) * lobj.scl[0] + o.loc[0];
            o.loc[2] = ((@as(f32, @floatFromInt(bz)) + 0.5) * tsize - hsz) * lobj.scl[2] + o.loc[2];
        }
    }
    // the landscape goes
    scene.remove(a.i);
    app.log("  landscape split into tiles: {d}", .{uk * uk});
    app.dirty = true;
}

pub const list = .{
    .{ "landscape.import", Impl{ .run = opImport } },
    .{ "landscape.export", Impl{ .run = opExport } },
    .{ "landscape.to_mesh", Impl{ .run = opToMesh } },
    .{ "landscape.tiles", Impl{ .run = opTiles } },
};

// ---- tests ----------------------------------------------------------------------------

test "h2f: normals, subnormals, zero, inf" {
    try std.testing.expectEqual(@as(f32, 1.0), h2f(0x3c00));
    try std.testing.expectEqual(@as(f32, -2.0), h2f(0xc000));
    try std.testing.expectEqual(@as(f32, 5.9604645e-8), h2f(0x0001));
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(h2f(0x8000))));
    try std.testing.expect(std.math.isInf(h2f(0x7c00)));
}

test "a 16-bit PNG round-trips through pngRaw and decodePng" {
    var raw: [3 * (2 * 2 + 1)]u8 = undefined;
    const vals = [_]u16{ 0, 65535, 1234, 40000, 7, 32768 };
    for (0..3) |r| {
        raw[r * 5] = 0;
        for (0..2) |c| {
            const v = vals[r * 2 + c];
            raw[r * 5 + 1 + c * 2] = @truncate(v >> 8);
            raw[r * 5 + 2 + c * 2] = @truncate(v);
        }
    }
    const f = try pngRaw(2, 3, 16, 0, &raw);
    defer A.free(f);
    var im = decodePng(f).?;
    defer im.deinit();
    for (vals, 0..) |v, i| try std.testing.expectEqual(@as(f32, @floatFromInt(v)) * 1.5259022e-5, im.px[i]);
    // damaged: truncated, a bad magic
    try std.testing.expect(decodePng(f[0 .. f.len - 20]) == null);
    try std.testing.expect(decodePng(f[1..]) == null);
}

test "the EXR written reads back as the same floats" {
    const hs = [_]f32{ 1.5, -2, 3.25, 1e6, 0, 7, 8, 9, 10 };
    const f = try exrBytes(3, &hs);
    defer A.free(f);
    var im = decodeExr(f).?;
    defer im.deinit();
    try std.testing.expectEqual(@as(u32, 3), im.w);
    try std.testing.expectEqualSlices(f32, &hs, im.px);
    try std.testing.expect(decodeExr(f[0 .. f.len - 5]) == null);
}

test "sideFor and the resample's corners" {
    try std.testing.expectEqual(@as(u32, 65), sideFor(10, 3));
    try std.testing.expectEqual(@as(u32, 257), sideFor(200, 129));
    try std.testing.expectEqual(@as(u32, 4097), sideFor(9000, 1));
    var px = [_]f32{ 0, 1, 2, 3 };
    const im = Img{ .w = 2, .h = 2, .px = &px };
    var out: [9]f32 = undefined;
    resampleImg(&im, &out, 3);
    try std.testing.expectEqual(@as(f32, 0), out[0]);
    try std.testing.expectEqual(@as(f32, 3), out[8]);
    try std.testing.expectEqual(@as(f32, 1.5), out[4]);
}
