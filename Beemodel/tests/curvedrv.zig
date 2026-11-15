// tests/curves.py's driver: runs curve.zig's chain functions (the geometry nodes'
// curve nodes) on cases from a file: op (u32), 4 values (f32), a node record's
// inputs (3 x xyz), mesh A, has-B, mesh B. Writes the result meshes (nv, verts,
// polygon offsets, loops; or nv = 0xffffffff: null; points: nv, verts, normals).
const std = @import("std");
const cv = @import("curve");

fn rd(comptime T: type, d: []const u8, o: *usize) T {
    const v = std.mem.readInt(u32, d[o.*..][0..4], .little);
    o.* += 4;
    return @bitCast(v);
}

fn rdMesh(a: std.mem.Allocator, d: []const u8, o: *usize) !cv.PMesh {
    const nv = rd(u32, d, o);
    const v = try a.alloc([3]f32, nv);
    for (v) |*x| x.* = .{ rd(f32, d, o), rd(f32, d, o), rd(f32, d, o) };
    const np = rd(u32, d, o);
    const off = try a.alloc(u32, np + 1);
    for (off) |*x| x.* = rd(u32, d, o);
    const nl = rd(u32, d, o);
    const l = try a.alloc(u32, nl);
    for (l) |*x| x.* = rd(u32, d, o);
    return .{ .verts = v, .poff = off, .loops = l };
}

fn put(out: *std.ArrayList(u8), a: std.mem.Allocator, x: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, x, .little);
    try out.appendSlice(a, &b);
}

pub fn main(init: std.process.Init) !void {
    const a = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;
    const d = try std.Io.Dir.cwd().readFileAlloc(io, args[1], a, .unlimited);
    var out: std.ArrayList(u8) = .empty;
    var o: usize = 0;
    while (o < d.len) {
        const op = rd(u32, d, &o);
        var node: [72]u8 = @splat(0);
        for (0..4) |k| std.mem.writeInt(u32, node[52 + k * 4 ..][0..4], rd(u32, d, &o), .little);
        for (0..3) |k| for (0..3) |c| std.mem.writeInt(u32, node[4 + k * 16 + 4 + c * 4 ..][0..4], rd(u32, d, &o), .little);
        const ma = try rdMesh(a, d, &o);
        const hb = rd(u32, d, &o);
        const mb: ?cv.PMesh = if (hb != 0) try rdMesh(a, d, &o) else null;
        if (op == 6) {
            const p = cv.cnPoints(a, ma, &node);
            if (p) |pp| {
                try put(&out, a, @intCast(pp.verts.len));
                for (pp.verts) |v| for (v) |c| try put(&out, a, @bitCast(c));
                for (pp.nrm) |v| for (v) |c| try put(&out, a, @bitCast(c));
            } else try put(&out, a, 0xffffffff);
            continue;
        }
        const r: ?cv.PMesh = switch (op) {
            0 => cv.cnLine(a, &node),
            1 => cv.cnCircle(a, &node),
            2 => cv.cnToMesh(a, ma, mb, &node),
            3 => cv.cnResample(a, ma, &node),
            4 => cv.cnTrim(a, ma, &node),
            5 => cv.cnFillet(a, ma, &node),
            else => null,
        };
        if (r) |m| {
            try put(&out, a, @intCast(m.verts.len));
            for (m.verts) |v| for (v) |c| try put(&out, a, @bitCast(c));
            try put(&out, a, @intCast(m.faces()));
            for (m.poff) |x| try put(&out, a, x);
            try put(&out, a, @intCast(m.loops.len));
            for (m.loops) |x| try put(&out, a, x);
        } else try put(&out, a, 0xffffffff);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.items });
}
