// Other file formats, as the original's formats.s:
//   OBJ  import (one object, n-gons, v/vt/vn and negative indices, its MTL) /
//        export (every mesh object, world coordinates: objmtl.zig)
//   STL  import (binary or ASCII, vertices welded) / export (binary)
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const bee = @import("bee.zig");
const objmtl = @import("objmtl.zig");

const A = std.heap.page_allocator;

pub const Error = error{ CannotOpen, Empty, Damaged, TooMany, CannotWrite, NothingToExport };

fn baseName(path: []const u8) []const u8 {
    const b = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
    return if (std.mem.lastIndexOfScalar(u8, b, '.')) |d| (if (d > 0) b[0..d] else b) else b;
}

/// Add an object for mesh mi, named after the file, at the 3D cursor... no:
/// imported geometry stays where the file put it (as the original).
fn addImported(name: []const u8, mi: u16) !usize {
    if (scene.count >= scene.max_objects) return Error.TooMany;
    var o = scene.Object{ .kind = .mesh, .mesh = mi };
    o.setName(if (name.len > 0) name else "Import");
    // a unique name (Name.001 ...)
    var buf: [40]u8 = undefined;
    var k: u32 = 1;
    while (scene.find(o.name()) != null) : (k += 1) {
        const nm = std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ name[0..@min(name.len, 27)], k }) catch break;
        o.setName(nm);
    }
    scene.objects[scene.count] = o;
    scene.stamp(scene.count);
    scene.count += 1;
    scene.selectOnly(scene.count - 1);
    return scene.count - 1;
}

// --- OBJ ---------------------------------------------------------------------------

pub fn importObj(path: []const u8) !usize {
    const d = @import("ttf.zig").mapFile(path) orelse return Error.CannotOpen;
    defer _ = std.os.linux.munmap(d.ptr, d.len);
    var verts: std.ArrayList(m.V3) = .empty;
    defer verts.deinit(A);
    var poff: std.ArrayList(u32) = .empty;
    defer poff.deinit(A);
    var loops: std.ArrayList(u32) = .empty;
    defer loops.deinit(A);
    try poff.append(A, 0);
    var lines = std.mem.splitScalar(u8, d, '\n');
    // (the first of each, as the original)
    var mtllib: []const u8 = "";
    var usemtl: []const u8 = "";
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 2) continue;
        if (mtllib.len == 0 and std.mem.startsWith(u8, line, "mtllib ")) mtllib = std.mem.trim(u8, line[7..], " \t");
        if (usemtl.len == 0 and std.mem.startsWith(u8, line, "usemtl ")) usemtl = std.mem.trim(u8, line[7..], " \t");
        if (line[0] == 'v' and (line[1] == ' ' or line[1] == '\t')) {
            var it = std.mem.tokenizeAny(u8, line[2..], " \t");
            var v: m.V3 = .{ 0, 0, 0 };
            for (&v) |*c| {
                const t = it.next() orelse break;
                c.* = std.fmt.parseFloat(f32, t) catch 0;
                if (!std.math.isFinite(c.*)) c.* = 0;
            }
            try verts.append(A, v);
        } else if (line[0] == 'f' and (line[1] == ' ' or line[1] == '\t')) {
            var it = std.mem.tokenizeAny(u8, line[2..], " \t");
            const start = loops.items.len;
            while (it.next()) |t| {
                // v, v/vt, v//vn, v/vt/vn; negative: from the end
                const vs = if (std.mem.indexOfScalar(u8, t, '/')) |s| t[0..s] else t;
                const iv = std.fmt.parseInt(i64, vs, 10) catch continue;
                const n: i64 = @intCast(verts.items.len);
                const idx: i64 = if (iv < 0) n + iv else iv - 1;
                if (idx < 0 or idx >= n) continue;
                try loops.append(A, @intCast(idx));
            }
            if (loops.items.len - start >= 3) {
                try poff.append(A, @intCast(loops.items.len));
            } else loops.shrinkRetainingCapacity(start);
        }
    }
    if (verts.items.len == 0 or poff.items.len < 2) return Error.Empty;
    const mi = scene.addMesh(verts.items, poff.items, loops.items) orelse return Error.Damaged;
    const oi = try addImported(baseName(path), mi);
    objmtl.importMaterials(path, mtllib, usemtl, oi);
    return oi;
}

fn putf(out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    var b: [256]u8 = undefined;
    try out.appendSlice(A, std.fmt.bufPrint(&b, fmt, args) catch return);
}

/// (objmtl.zig: the file, its MTL, the export options)
pub fn exportObj(path: []const u8) !usize {
    return objmtl.exportObj(path);
}

// --- STL ---------------------------------------------------------------------------

/// Binary or ASCII; equal vertices are welded into one.
pub fn importStl(path: []const u8) !usize {
    const d = @import("ttf.zig").mapFile(path) orelse return Error.CannotOpen;
    defer _ = std.os.linux.munmap(d.ptr, d.len);
    var tris: std.ArrayList(m.V3) = .empty; // 3 per triangle
    defer tris.deinit(A);
    const binary = d.len >= 84 and 84 + @as(u64, std.mem.readInt(u32, d[80..84], .little)) * 50 == d.len;
    if (binary) {
        const n = std.mem.readInt(u32, d[80..84], .little);
        for (0..n) |t| {
            const o = 84 + t * 50 + 12;
            for (0..3) |k| {
                var v: m.V3 = undefined;
                for (0..3) |c| v[c] = @bitCast(std.mem.readInt(u32, d[o + k * 12 + c * 4 ..][0..4], .little));
                for (&v) |*x| {
                    if (!std.math.isFinite(x.*)) x.* = 0;
                }
                try tris.append(A, v);
            }
        }
    } else {
        var lines = std.mem.splitScalar(u8, d, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "vertex")) continue;
            var it = std.mem.tokenizeAny(u8, line[6..], " \t");
            var v: m.V3 = .{ 0, 0, 0 };
            for (&v) |*c| {
                c.* = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
                if (!std.math.isFinite(c.*)) c.* = 0;
            }
            try tris.append(A, v);
        }
        tris.shrinkRetainingCapacity(tris.items.len / 3 * 3);
    }
    if (tris.items.len < 3) return Error.Empty;
    // weld: sort the corners by position, give equal ones one index
    const nc = tris.items.len;
    const order = try A.alloc(u32, nc);
    defer A.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.sort.pdq(u32, order, tris.items, struct {
        fn lt(t: []m.V3, a: u32, b: u32) bool {
            const p = t[a];
            const q = t[b];
            if (p[0] != q[0]) return p[0] < q[0];
            if (p[1] != q[1]) return p[1] < q[1];
            return p[2] < q[2];
        }
    }.lt);
    const idx = try A.alloc(u32, nc);
    defer A.free(idx);
    var verts: std.ArrayList(m.V3) = .empty;
    defer verts.deinit(A);
    for (order, 0..) |c, k| {
        if (k == 0 or !std.mem.eql(f32, &tris.items[c], &tris.items[order[k - 1]])) try verts.append(A, tris.items[c]);
        idx[c] = @intCast(verts.items.len - 1);
    }
    const nt = nc / 3;
    const poff = try A.alloc(u32, nt + 1);
    defer A.free(poff);
    for (poff, 0..) |*p, i| p.* = @intCast(i * 3);
    const mi = scene.addMesh(verts.items, poff, idx) orelse return Error.Damaged;
    return addImported(baseName(path), mi);
}

/// Every visible mesh object as binary STL triangles, in world coordinates.
pub fn exportStl(path: []const u8) !usize {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(A);
    var hdr: [84]u8 = @splat(0);
    @memcpy(hdr[0..21], "BeeModel (Zig) STL   ");
    try out.appendSlice(A, &hdr);
    var nt: u32 = 0;
    var n: usize = 0;
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (!objmtl.wants(o)) continue;
        const me = @import("mods.zig").of(i) orelse continue;
        const w = scene.world(i);
        for (me.tris) |t| {
            const a = objmtl.exported(m.xform(w, me.verts[t[0]]));
            const b = objmtl.exported(m.xform(w, me.verts[t[1]]));
            const c = objmtl.exported(m.xform(w, me.verts[t[2]]));
            const nrm = m.norm(m.cross(m.sub(b, a), m.sub(c, a)));
            var rec: [50]u8 = @splat(0);
            const vals = [_]m.V3{ nrm, a, b, c };
            for (vals, 0..) |v, k| {
                for (0..3) |q| std.mem.writeInt(u32, rec[(k * 3 + q) * 4 ..][0..4], @bitCast(if (std.math.isFinite(v[q])) v[q] else 0), .little);
            }
            try out.appendSlice(A, &rec);
            nt += 1;
        }
        n += 1;
    }
    if (n == 0) return Error.NothingToExport;
    std.mem.writeInt(u32, out.items[80..84], nt, .little);
    try bee.writeAtomic(path, out.items);
    return n;
}
