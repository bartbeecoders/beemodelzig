// Fabrication formats (fab.s): 3MF for printing. (DXF and SVG of sketches live
// with the sketches: fab2d.zig.)
//
// 3MF is a zip holding [Content_Types].xml, _rels/.rels and 3D/3dmodel.model:
// every mesh object in world space after its modifiers, in millimetres, turned
// from our Y-up into the printers' Z-up (x, -z, y: a rotation, so faces keep
// facing out). The model is deflated with the original's own deflate (png.s:
// one block of fixed Huffman codes, greedy LZ77 through a hash of the next
// three bytes), so the file is the original's byte for byte.
const std = @import("std");
const app = @import("app.zig");
const scene = @import("scene.zig");
const m = @import("math.zig");
const cad = @import("cad.zig");

const A = std.heap.page_allocator;

// ---- CRC-32 and deflate, as png.s --------------------------------------------------------

const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ 0xedb88320 else c >> 1;
        t[i] = c;
    }
    break :blk t;
};

pub fn crc32(d: []const u8) u32 {
    var c: u32 = 0xffffffff;
    for (d) |b| c = (c >> 8) ^ crc_table[(c ^ b) & 255];
    return ~c;
}

fn rev(v0: u32, bits: u5) u32 {
    var v = v0;
    var r: u32 = 0;
    for (0..bits) |_| {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}

const Fixed = struct { code: [288]u16, len: [288]u8, len_sym: [259]u16 };
const fixed: Fixed = blk: {
    @setEvalBranchQuota(100000);
    var f: Fixed = undefined;
    for (0..288) |s| {
        const c: u32, const l: u5 = if (s < 144) .{ s + 0x30, 8 } else if (s < 256) .{ s - 144 + 0x190, 9 } else if (s < 280) .{ s - 256, 7 } else .{ s - 280 + 0xc0, 8 };
        f.code[s] = @intCast(rev(c, l));
        f.len[s] = l;
    }
    var b: usize = 0;
    for (3..259) |len| {
        while (b < 28 and len >= len_base[b + 1]) b += 1;
        f.len_sym[len] = @intCast(b + 257);
    }
    break :blk f;
};

const len_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [_]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

const HASH = 32768;
const WINDOW = 32768;

const Bits = struct {
    out: *std.ArrayList(u8),
    buf: u64 = 0,
    cnt: u6 = 0,

    fn put(b: *Bits, v: u32, n: u6) !void {
        b.buf |= @as(u64, v) << b.cnt;
        b.cnt += n;
        while (b.cnt >= 8) {
            try b.out.append(A, @truncate(b.buf));
            b.buf >>= 8;
            b.cnt -= 8;
        }
    }
    fn lit(b: *Bits, s: usize) !void {
        try b.put(fixed.code[s], @intCast(fixed.len[s]));
    }
    fn match(b: *Bits, len: usize, dist: u32) !void {
        const s = fixed.len_sym[len];
        try b.lit(s);
        const k = s - 257;
        if (len_extra[k] != 0) try b.put(@intCast(len - len_base[k]), @intCast(len_extra[k]));
        var d: usize = 29;
        while (dist < dist_base[d]) d -= 1;
        try b.put(rev(@intCast(d), 5), 5);
        if (dist_extra[d] != 0) try b.put(dist - dist_base[d], @intCast(dist_extra[d]));
    }
};

fn hash3(d: []const u8, p: usize) usize {
    return ((@as(usize, d[p]) << 10) ^ (@as(usize, d[p + 1]) << 5) ^ d[p + 2]) & (HASH - 1);
}

/// deflate_buf: raw deflate, one block of fixed codes.
pub fn deflate(out: *std.ArrayList(u8), d: []const u8) !void {
    const head = try A.alloc(u32, HASH); // position + 1 of the last occurrence
    defer A.free(head);
    @memset(head, 0);
    var b = Bits{ .out = out };
    try b.put(3, 3); // BFINAL = 1, BTYPE = 01
    var p: usize = 0;
    while (d.len - p >= 3) {
        const h = hash3(d, p);
        const cand = head[h];
        head[h] = @intCast(p + 1);
        if (cand != 0) {
            const c = cand - 1;
            const dist: u32 = @intCast(p - c);
            if (dist <= WINDOW and dist != 0) {
                const limit = @min(d.len - p, 258);
                var n: usize = 0;
                while (n < limit and d[c + n] == d[p + n]) n += 1;
                if (n >= 3) {
                    try b.match(n, dist);
                    // the positions inside the match too
                    var k: usize = 1;
                    while (k < n and p + k + 2 < d.len) : (k += 1) head[hash3(d, p + k)] = @intCast(p + k + 1);
                    p += n;
                    continue;
                }
            }
        }
        try b.lit(d[p]);
        p += 1;
    }
    while (p < d.len) : (p += 1) try b.lit(d[p]);
    try b.lit(256); // end of block
    if (b.cnt != 0) try b.put(0, (8 - b.cnt) & 7);
}

// ---- the zip --------------------------------------------------------------------------------

const ct_name = "[Content_Types].xml";
const ct = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
    "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" ++
    "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" ++
    "<Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>" ++
    "</Types>\n";
const rels_name = "_rels/.rels";
const rels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
    "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
    "<Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" " ++
    "Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>" ++
    "</Relationships>\n";
const model_name = "3D/3dmodel.model";

fn u16le(out: *std.ArrayList(u8), v: u32) !void {
    try out.appendSlice(A, &.{ @truncate(v), @truncate(v >> 8) });
}
fn u32le(out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(A, &b);
}

const Entry = struct { name: []const u8, method: u32, crc: u32, csize: u32, size: u32, off: u32 = 0 };

/// zip_local / zip_central: version 20, no flags, 1980-01-01 00:00.
fn header(out: *std.ArrayList(u8), e: Entry, central: bool) !void {
    try u32le(out, if (central) 0x02014b50 else 0x04034b50);
    if (central) try u16le(out, 20); // made by
    try u16le(out, 20); // needed
    try u16le(out, 0);
    try u16le(out, e.method);
    try u16le(out, 0); // time
    try u16le(out, 0x21); // date
    try u32le(out, e.crc);
    try u32le(out, e.csize);
    try u32le(out, e.size);
    try u16le(out, @intCast(e.name.len));
    try u16le(out, 0); // extra
    if (central) {
        try u16le(out, 0); // comment, disk, internal
        try u16le(out, 0);
        try u16le(out, 0);
        try u32le(out, 0); // external attributes
        try u32le(out, e.off);
    }
    try out.appendSlice(A, e.name);
}

// ---- the model -----------------------------------------------------------------------------

/// wb_float: six decimals, rounded to millionths (to even, as cvtsd2si).
fn putFloat(out: *std.ArrayList(u8), v: f32) !void {
    var x: f64 = v;
    if (!(x >= 0)) {
        try out.append(A, '-');
        x = 0.0 - x;
    }
    const y = x * 1000000.0;
    // cvtsd2si: out of range or NaN is the minimum (taken unsigned here)
    var q: u64 = 0x8000000000000000;
    if (y < 9.2e18) {
        var r = @floor(y);
        const diff = y - r;
        if (diff > 0.5 or (diff == 0.5 and @mod(r, 2) == 1)) r += 1;
        q = @intFromFloat(r);
    }
    var b: [32]u8 = undefined;
    try out.appendSlice(A, std.fmt.bufPrint(&b, "{d}.{d:0>6}", .{ q / 1000000, q % 1000000 }) catch "0.000000");
}

fn putEsc(out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(A, "&amp;"),
            '<' => try out.appendSlice(A, "&lt;"),
            '>' => try out.appendSlice(A, "&gt;"),
            '"' => try out.appendSlice(A, "&quot;"),
            else => try out.append(A, c),
        }
    }
}

fn wants(o: *const scene.Object) bool {
    return @import("objmtl.zig").wants(o);
}

pub const Err = error{ NothingToExport, OutOfMemory, CannotWrite };

/// export_3mf: the file's bytes (the caller writes them).
pub fn build3mf() Err![]u8 {
    const mm: f32 = @floatCast(cad.unitMm());
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(A);
    try model.appendSlice(A, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<model unit=\"millimeter\" xml:lang=\"en-US\" " ++
        "xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n" ++
        "<metadata name=\"Application\">BeeModel</metadata>\n" ++
        "<resources>\n");
    var nobj: u32 = 0;
    var b: [32]u8 = undefined;
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (!wants(o)) continue;
        const me = @import("mods.zig").of(i) orelse continue;
        if (me.tris.len == 0) continue;
        const w = @import("measure.zig").objMatrix(i);
        nobj += 1;
        try model.appendSlice(A, "<object id=\"");
        try model.appendSlice(A, std.fmt.bufPrint(&b, "{d}", .{nobj}) catch "");
        try model.appendSlice(A, "\" type=\"model\" name=\"");
        try putEsc(&model, o.name());
        try model.appendSlice(A, "\">\n<mesh>\n<vertices>\n");
        for (me.verts) |p0| {
            const p = m.xform(w, p0); // vertices: (x, -z, y) mm
            try model.appendSlice(A, "<vertex x=\"");
            try putFloat(&model, p[0] * mm);
            try model.appendSlice(A, "\" y=\"");
            try putFloat(&model, (0 - p[2]) * mm);
            try model.appendSlice(A, "\" z=\"");
            try putFloat(&model, p[1] * mm);
            try model.appendSlice(A, "\"/>\n");
        }
        try model.appendSlice(A, "</vertices>\n<triangles>\n");
        for (me.tris) |t| {
            try model.appendSlice(A, std.fmt.bufPrint(&b, "<triangle v1=\"{d}", .{t[0]}) catch "");
            try model.appendSlice(A, std.fmt.bufPrint(&b, "\" v2=\"{d}", .{t[1]}) catch "");
            try model.appendSlice(A, std.fmt.bufPrint(&b, "\" v3=\"{d}", .{t[2]}) catch "");
            try model.appendSlice(A, "\"/>\n");
        }
        try model.appendSlice(A, "</triangles>\n</mesh>\n</object>\n");
    }
    if (nobj == 0) return Err.NothingToExport;
    try model.appendSlice(A, "</resources>\n<build>\n");
    for (1..nobj + 1) |k| {
        try model.appendSlice(A, std.fmt.bufPrint(&b, "<item objectid=\"{d}", .{k}) catch "");
        try model.appendSlice(A, "\"/>\n");
    }
    try model.appendSlice(A, "</build>\n</model>\n");
    var comp: std.ArrayList(u8) = .empty;
    defer comp.deinit(A);
    try deflate(&comp, model.items);
    var z: std.ArrayList(u8) = .empty;
    errdefer z.deinit(A);
    var es = [3]Entry{
        .{ .name = ct_name, .method = 0, .crc = crc32(ct), .csize = ct.len, .size = ct.len },
        .{ .name = rels_name, .method = 0, .crc = crc32(rels), .csize = rels.len, .size = rels.len },
        .{ .name = model_name, .method = 8, .crc = crc32(model.items), .csize = @intCast(comp.items.len), .size = @intCast(model.items.len) },
    };
    const datas = [3][]const u8{ ct, rels, comp.items };
    for (&es, datas) |*e, d| {
        e.off = @intCast(z.items.len);
        try header(&z, e.*, false);
        try z.appendSlice(A, d);
    }
    const cd: u32 = @intCast(z.items.len);
    for (es) |e| try header(&z, e, true);
    const cd_size: u32 = @intCast(z.items.len - cd);
    try u32le(&z, 0x06054b50); // end of central directory
    try u32le(&z, 0);
    try u32le(&z, 0x00030003);
    try u32le(&z, cd_size);
    try u32le(&z, cd);
    try u16le(&z, 0);
    return z.toOwnedSlice(A);
}

fn exportTo(p0: []const u8) void {
    const files = @import("files.zig");
    var eb: [600]u8 = undefined;
    const p = files.expandHome(&eb, p0) orelse p0;
    defer @import("objmtl.zig").defaults();
    if (!files.mayWrite(p)) return app.toast(.warn, "Headless: not writing outside /tmp ({s})", .{p});
    const data = build3mf() catch |e| switch (e) {
        Err.NothingToExport => return app.log("  nothing to export: {s}", .{p}),
        else => return app.log("  could not write {s}", .{p}),
    };
    defer A.free(data);
    @import("bee.zig").writeAtomic(p, data) catch return app.log("  could not write {s}", .{p});
    app.log("  exported {s}", .{p});
}

fn exportLater(p: []const u8) void {
    @import("jobui.zig").later(exportJob, "Exporting 3MF", p, 0, 0);
}
fn exportJob(p: []const u8, _: usize, _: usize) void {
    exportTo(p);
}

/// file.export_3mf <path>: from the UI with none, the file browser (its
/// "Selected objects only"); from the console with none, the command half typed.
pub fn opExport3mf() void {
    const ops = @import("ops.zig");
    const arg = std.mem.trim(u8, ops.arg, " ");
    if (arg.len == 0) {
        if (ops.scripted) return @import("editors.zig").prefillConsole("file.export_3mf ~/BeeModel/part.3mf");
        const fb = @import("filebrowser.zig");
        fb.show(.save, "Export 3MF", ".3mf", "part.3mf", exportLater);
        fb.export_options = true;
        fb.export_axis = false;
        return;
    }
    exportTo(arg);
}

test "deflate: a stream any inflater reads back" {
    const T = std.testing;
    var src: [5000]u8 = undefined;
    for (&src, 0..) |*c, i| c.* = @intCast((i * 7 + i / 50) % 23 + 'a');
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(A);
    try deflate(&out, &src);
    try T.expect(out.items.len < src.len / 2);
    var r = std.Io.Reader.fixed(out.items);
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var dz = std.compress.flate.Decompress.init(&r, .raw, &buf);
    var back: [6000]u8 = undefined;
    const n = try dz.reader.readSliceShort(&back);
    try T.expectEqualSlices(u8, &src, back[0..n]);
    try T.expectEqual(@as(u32, 0xcbf43926), crc32("123456789"));
}
