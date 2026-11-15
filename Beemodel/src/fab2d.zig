// DXF and SVG (fab.s, its sketch half): a sketch's lines, circles and arcs in
// its plane, in millimetres; construction geometry goes to its own DXF layer
// (CONSTRUCTION) and is dashed and grey in SVG. The text is the original's,
// byte for byte (numbers through a float, six decimals: wb_float).
const std = @import("std");
const app = @import("app.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const sk = @import("sketch.zig");
const skobj = @import("skobj.zig");
const cad = @import("cad.zig");
const fmtFloat = @import("objmtl.zig").fmtFloat;
const Impl = ops.Impl;

const A = std.heap.page_allocator;

const dxf_head = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1009\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n" ++
    "0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n70\n2\n" ++
    "0\nLAYER\n2\n0\n70\n0\n62\n7\n6\nCONTINUOUS\n" ++
    "0\nLAYER\n2\nCONSTRUCTION\n70\n0\n62\n8\n6\nCONTINUOUS\n" ++
    "0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n";
const dxf_end = "0\nENDSEC\n0\nEOF\n";
const svg_head = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"";

const fd_r2d: f64 = 57.29577951308232;
const fd_pi: f64 = 3.14159265358979323846;
const fd_2pi: f64 = 6.28318530717958647692;
const fd_margin: f64 = 5.0;

/// The sketch to export: the active object's, else the first sketch (fb_sketch).
pub fn which() ?*const sk.Block {
    if (scene.active) |a| {
        if (skobj.of(a)) |b| return b;
    }
    for (0..scene.count) |i| {
        if (skobj.of(i)) |b| return b;
    }
    return null;
}

const Out = struct {
    buf: std.ArrayList(u8) = .empty,
    mm: f64 = 1000,
    fail: bool = false,
    min: [2]f64 = .{ 0, 0 },
    max: [2]f64 = .{ 0, 0 },

    fn str(o: *Out, s: []const u8) void {
        o.buf.appendSlice(A, s) catch {
            o.fail = true;
        };
    }
    /// wb_dbl: a double as text, through a float
    fn dbl(o: *Out, v: f64) void {
        var b: [48]u8 = undefined;
        o.str(fmtFloat(&b, @floatCast(v)));
    }
    fn int(o: *Out, v: i64) void {
        var b: [24]u8 = undefined;
        o.str(std.fmt.bufPrint(&b, "{d}", .{v}) catch "");
    }
    /// wb_code: "code\nvalue\n"
    fn code(o: *Out, c: i64, v: f64) void {
        o.int(c);
        o.str("\n");
        o.dbl(v);
        o.str("\n");
    }
    /// spt: a point's u, v in mm
    fn spt(o: *const Out, b: *const sk.Block, p: i32) [2]f64 {
        const q = sk.pointXY(b, p);
        return .{ q[0] * o.mm, q[1] * o.mm };
    }
    /// arc_angles: start and end angle (radians, counter-clockwise), the radius in mm
    fn arcAngles(o: *const Out, b: *const sk.Block, e: *const sk.Ent) [3]f64 {
        const c = o.spt(b, e.p[0]);
        const s = o.spt(b, e.p[1]);
        const a0 = sk.fpatan(s[1] - c[1], s[0] - c[0]);
        const t = o.spt(b, e.p[2]);
        const a1 = sk.fpatan(t[1] - c[1], t[0] - c[0]);
        return .{ a0, a1, e.r * o.mm };
    }
    fn svgX(o: *Out, u: f64) void {
        o.dbl(u - o.min[0] + fd_margin);
    }
    fn svgY(o: *Out, v: f64) void {
        o.dbl(o.max[1] - v + fd_margin);
    }
    fn svgXY(o: *Out, p: [2]f64) void {
        o.svgX(p[0]);
        o.str(" ");
        o.svgY(p[1]);
    }
};

inline fn minsd(a: f64, b: f64) f64 {
    return if (a < b) a else b;
}
inline fn maxsd(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}

/// The DXF text of a sketch (mm per scene unit: mm).
pub fn dxf(b: *const sk.Block, mm: f64) ?[]u8 {
    var o = Out{ .mm = mm };
    o.str(dxf_head);
    for (b.ents[0..@min(b.nent, sk.MAX_ENT)]) |*e| {
        o.str(switch (e.typ) {
            sk.E_LINE => "0\nLINE\n8\n",
            sk.E_CIRCLE => "0\nCIRCLE\n8\n",
            sk.E_ARC => "0\nARC\n8\n",
            else => continue,
        });
        o.str(if (e.flags & sk.F_CONSTR != 0) "CONSTRUCTION\n" else "0\n"); // the layer
        const p = o.spt(b, e.p[0]); // 10 / 20 / 30: the first point
        o.code(10, p[0]);
        o.code(20, p[1]);
        o.code(30, 0);
        switch (e.typ) {
            sk.E_LINE => {
                const q = o.spt(b, e.p[1]); // 11 / 21 / 31: the end
                o.code(11, q[0]);
                o.code(21, q[1]);
                o.code(31, 0);
            },
            sk.E_CIRCLE => o.code(40, e.r * o.mm), // 40: radius
            else => {
                const a = o.arcAngles(b, e); // 40 radius, 50 / 51 angles (deg)
                o.code(40, a[2]);
                o.code(50, a[0] * fd_r2d);
                o.code(51, a[1] * fd_r2d);
            },
        }
    }
    o.str(dxf_end);
    if (o.fail) {
        o.buf.deinit(A);
        return null;
    }
    return o.buf.toOwnedSlice(A) catch null;
}

/// The SVG text of a sketch: its bounds (points, circles) plus 5 mm margins,
/// y flipped (SVG grows down).
pub fn svg(b: *const sk.Block, mm: f64) ?[]u8 {
    var o = Out{ .mm = mm };
    // sk_bounds: points, then circles and arcs (centre +- r)
    var lo: [2]f64 = .{ 1.0e300, 1.0e300 };
    var hi: [2]f64 = .{ 0 - 1.0e300, 0 - 1.0e300 };
    var k: u32 = 0;
    while (k < b.npt and k < sk.MAX_PT) : (k += 1) {
        const p = o.spt(b, @intCast(k));
        lo[0] = minsd(lo[0], p[0]);
        hi[0] = maxsd(hi[0], p[0]);
        lo[1] = minsd(lo[1], p[1]);
        hi[1] = maxsd(hi[1], p[1]);
    }
    for (b.ents[0..@min(b.nent, sk.MAX_ENT)]) |*e| {
        if (e.typ == sk.E_LINE) continue;
        const c = o.spt(b, e.p[0]);
        const r = e.r * o.mm;
        lo[0] = minsd(lo[0], c[0] - r);
        hi[0] = maxsd(hi[0], c[0] + r);
        lo[1] = minsd(lo[1], c[1] - r);
        hi[1] = maxsd(hi[1], c[1] + r);
    }
    o.min = lo;
    o.max = hi;
    o.str(svg_head);
    const w = hi[0] - lo[0] + fd_margin + fd_margin;
    o.dbl(w);
    o.str("mm\" height=\"");
    const h = hi[1] - lo[1] + fd_margin + fd_margin;
    o.dbl(h);
    o.str("mm\" viewBox=\"0 0 ");
    o.dbl(w);
    o.str(" ");
    o.dbl(h);
    o.str("\">\n<g fill=\"none\" stroke=\"black\" stroke-width=\"0.25\">\n");
    for (b.ents[0..@min(b.nent, sk.MAX_ENT)]) |*e| {
        switch (e.typ) {
            sk.E_LINE => {
                o.str("<line x1=\"");
                const p = o.spt(b, e.p[0]);
                o.svgX(p[0]);
                o.str("\" y1=\"");
                o.svgY(p[1]);
                o.str("\" x2=\"");
                const q = o.spt(b, e.p[1]);
                o.svgX(q[0]);
                o.str("\" y2=\"");
                o.svgY(q[1]);
                o.str("\"");
            },
            sk.E_CIRCLE => {
                o.str("<circle cx=\"");
                const p = o.spt(b, e.p[0]);
                o.svgX(p[0]);
                o.str("\" cy=\"");
                o.svgY(p[1]);
                o.str("\" r=\"");
                o.dbl(e.r * o.mm);
                o.str("\"");
            },
            sk.E_ARC => {
                // M start A r r 0 large 0 end (the flip makes counter-clockwise sweep 0)
                const a = o.arcAngles(b, e);
                var sweep = a[1] - a[0];
                if (!(sweep > 0)) sweep += fd_2pi;
                const large: i64 = if (sweep > fd_pi) 1 else 0;
                o.str("<path d=\"M ");
                o.svgXY(o.spt(b, e.p[1]));
                o.str(" A ");
                o.dbl(a[2]);
                o.str(" ");
                o.dbl(a[2]);
                o.str(" 0 ");
                o.int(large);
                o.str(" 0 ");
                o.svgXY(o.spt(b, e.p[2]));
                o.str("\"");
            },
            else => continue,
        }
        if (e.flags & sk.F_CONSTR != 0) o.str(" stroke-dasharray=\"1 1\" stroke=\"gray\"");
        o.str("/>\n");
    }
    o.str("</g>\n</svg>\n");
    if (o.fail) {
        o.buf.deinit(A);
        return null;
    }
    return o.buf.toOwnedSlice(A) catch null;
}

const Kind = enum { dxf, svg };

fn exportTo(kind: Kind, p0: []const u8) void {
    const b = which() orelse return app.log("  select a sketch to export", .{});
    var eb: [600]u8 = undefined;
    const files = @import("files.zig");
    const p = files.expandHome(&eb, std.mem.trim(u8, p0, " ")) orelse return;
    if (!files.mayWrite(p)) return app.log("  could not write {s}", .{p});
    const data = (if (kind == .dxf) dxf(b, cad.unitMm()) else svg(b, cad.unitMm())) orelse return app.log("  could not write {s}", .{p});
    defer A.free(data);
    @import("atomicfile.zig").write(p, data) catch return app.log("  could not write {s}", .{p});
    app.log("  exported {s}", .{p});
}

fn dxfPath(p: []const u8) void {
    exportTo(.dxf, p);
}
fn svgPath(p: []const u8) void {
    exportTo(.svg, p);
}

fn opDxf() void {
    const arg = std.mem.sliceTo(ops.arg, 0);
    if (arg.len > 0) return exportTo(.dxf, arg);
    // no path: the console (typed) or the file browser (a menu, a key)
    if (ops.scripted) return @import("editors.zig").prefillConsole("file.export_dxf ~/BeeModel/sketch.dxf");
    @import("filebrowser.zig").show(.save, "Export DXF", ".dxf", "sketch.dxf", dxfPath);
}
fn opSvg() void {
    const arg = std.mem.sliceTo(ops.arg, 0);
    if (arg.len > 0) return exportTo(.svg, arg);
    if (ops.scripted) return @import("editors.zig").prefillConsole("file.export_svg ~/BeeModel/sketch.svg");
    @import("filebrowser.zig").show(.save, "Export SVG", ".svg", "sketch.svg", svgPath);
}

pub const list = .{
    .{ "file.export_dxf", Impl{ .run = opDxf } },
    .{ "file.export_svg", Impl{ .run = opSvg } },
};

test "dxf and svg of a rectangle and a circle" {
    const b = sk.new(0).?;
    _ = skobj.rect(b, 0, 0, 4, 2);
    _ = skobj.circleXY(b, 1, 1, 0.5);
    _ = sk.solve(b);
    const d = dxf(b, 1000).?;
    defer A.free(d);
    try std.testing.expect(std.mem.startsWith(u8, d, dxf_head));
    try std.testing.expect(std.mem.endsWith(u8, d, dxf_end));
    try std.testing.expect(std.mem.indexOf(u8, d, "0\nCIRCLE\n8\n0\n10\n1000.000000\n20\n1000.000000\n30\n0.000000\n40\n500.000000\n") != null);
    const s = svg(b, 1000).?;
    defer A.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "width=\"4010.000000mm\" height=\"2010.000000mm\" viewBox=\"0 0 4010.000000 2010.000000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "<circle cx=\"1005.000000\" cy=\"1005.000000\" r=\"500.000000\"/>") != null);
}
