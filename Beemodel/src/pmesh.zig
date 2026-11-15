//! A polygon mesh as plain arrays: what the modifier kernels, subdivision and
//! booleans take and give. Polygon p is loops[poff[p]..poff[p + 1]] (vertex
//! indices, counter-clockwise from outside). No caches, no slot in the scene;
//! scene.zig turns one into a scene.Mesh.
const std = @import("std");
const m = @import("math.zig");

pub const PMesh = struct {
    verts: []m.V3,
    /// polygons + 1 entries, poff[0] == 0
    poff: []u32,
    loops: []u32,

    pub fn faces(p: PMesh) usize {
        return if (p.poff.len == 0) 0 else p.poff.len - 1;
    }
    pub fn poly(p: PMesh, i: usize) []const u32 {
        return p.loops[p.poff[i]..p.poff[i + 1]];
    }
    pub fn clone(p: PMesh, a: std.mem.Allocator) !PMesh {
        const v = try a.dupe(m.V3, p.verts);
        errdefer a.free(v);
        const o = try a.dupe(u32, p.poff);
        errdefer a.free(o);
        return .{ .verts = v, .poff = o, .loops = try a.dupe(u32, p.loops) };
    }
    pub fn deinit(p: PMesh, a: std.mem.Allocator) void {
        a.free(p.verts);
        a.free(p.poff);
        a.free(p.loops);
    }
};

/// The unit cube, faces outward (for tests).
pub fn testCube(a: std.mem.Allocator) !PMesh {
    const v = [_]m.V3{ .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 }, .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } };
    const l = [_]u32{ 0, 3, 2, 1, 4, 5, 6, 7, 0, 1, 5, 4, 1, 2, 6, 5, 2, 3, 7, 6, 3, 0, 4, 7 };
    const o = [_]u32{ 0, 4, 8, 12, 16, 20, 24 };
    const p = PMesh{ .verts = @constCast(&v), .poff = @constCast(&o), .loops = @constCast(&l) };
    return p.clone(a);
}
