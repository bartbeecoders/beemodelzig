// Vertex colours (vcol.s). A mesh may carry a colour per vertex (Mesh.vcol,
// 0xAARRGGBB, sRGB). They tint its material: the solid viewport multiplies each
// triangle's flat colour by its corners' average; Material Preview and the path
// tracer multiply the base colour by the colour interpolated across the triangle,
// in linear light. A shader graph that reads them (SCF_VCOL) is not tinted again.
// The arrays live on the mesh and are copied with it; a new topology has none.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const texture = @import("texture.zig");
const A = @import("alloc.zig").A;
const Mesh = scene.Mesh;

/// Are these the colours of this mesh (a damaged or stale array never is)?
pub inline fn has(me: *const Mesh) bool {
    return me.vcol.len != 0 and me.vcol.len == me.verts.len;
}

/// vcol_avg: 0x..RRGGBB times the triangle's corners' average, per channel:
/// c x (a + b + c) / 765, as integers (unchanged without colours).
pub fn avg(me: *const Mesh, ti: usize, col: u32) u32 {
    if (!has(me)) return col;
    const t = me.tris[ti];
    const c0 = me.vcol[t[0]];
    const c1 = me.vcol[t[1]];
    const c2 = me.vcol[t[2]];
    var out: u32 = 0;
    var sh: u5 = 16;
    while (true) {
        const s = (c0 >> sh & 255) + (c1 >> sh & 255) + (c2 >> sh & 255);
        out |= ((col >> sh & 255) * s / 765) << sh;
        if (sh == 0) break;
        sh -= 8;
    }
    return out;
}

/// vcol_lin3: three corners' colours in linear light at (u, v): corners 1 - u - v,
/// u, v. The bytes through the sRGB table (what srgb_to_lin gives for byte / 255).
pub fn lin3(c: *const [3]u32, u: f32, v: f32) m.V3 {
    const w = [3]f32{ 1 - u - v, u, v };
    var out: m.V3 = undefined;
    for (0..3) |k| {
        const sh: u5 = @intCast(16 - k * 8);
        var s: f32 = 0;
        for (0..3) |q| s = texture.lut[c[q] >> sh & 255] * w[q] + s;
        out[k] = s;
    }
    return out;
}

/// vcol_lin: the colour at (u, v) on a triangle; null: the mesh has none.
pub fn lin(me: *const Mesh, ti: usize, u: f32, v: f32) ?m.V3 {
    if (!has(me)) return null;
    const t = me.tris[ti];
    const c = [3]u32{ me.vcol[t[0]], me.vcol[t[1]], me.vcol[t[2]] };
    return lin3(&c, u, v);
}

/// mesh_vcol_alloc: its colours, made white when it has none; false: no memory.
pub fn alloc(me: *Mesh) bool {
    if (me.vcol.len == me.verts.len and me.vcol.len != 0) return true;
    if (me.vcol.len != 0) A.free(me.vcol);
    me.vcol = A.alloc(u32, me.verts.len) catch {
        me.vcol = &.{};
        return false;
    };
    @memset(me.vcol, 0xffffffff);
    return true;
}

/// (An edit made a new mesh.) The colours stay while its polygons do; a new
/// topology has none, as in the original.
pub fn keep(me: *Mesh, from: *const Mesh) void {
    if (me.vcol.len > 0 or from.vcol.len != me.verts.len or from.vcol.len == 0) return;
    if (!std.mem.eql(u32, me.loops, from.loops) or !std.mem.eql(u32, me.poff, from.poff)) return;
    me.vcol = A.dupe(u32, from.vcol) catch &.{};
}

/// MVCL: per mesh with colours its place among the MESH chunks, its vertices, the
/// colours.
pub fn writeChunk(out: anytype, mesh_ix: []const u32) void {
    for (mesh_ix, 0..) |ix, mi| {
        if (ix == 0xffffffff) continue;
        const me = &(scene.meshes[mi] orelse continue);
        if (me.vcol.len == 0 or me.vcol.len != me.verts.len) continue;
        out.u32_(ix);
        out.u32_(@intCast(me.vcol.len));
        out.bytes(std.mem.sliceAsBytes(me.vcol));
    }
}

/// mvcl_read: what does not fit is left out, a record that runs past the end
/// ends it.
pub fn readChunk(c: []const u8, map: []const ?u16) void {
    var o: usize = 0;
    while (c.len - o >= 8) {
        const ix = std.mem.readInt(u32, c[o..][0..4], .little);
        const n = std.mem.readInt(u32, c[o + 4 ..][0..4], .little);
        if (n >= 0x10000000 or n * 4 + 8 > c.len - o) return;
        const b = c[o + 8..][0 .. n * 4];
        o += 8 + n * 4;
        if (ix >= map.len) continue;
        const mi = map[ix] orelse continue;
        const me = &(scene.meshes[mi] orelse continue);
        if (n != me.verts.len or n == 0) continue;
        if (!alloc(me)) continue;
        @memcpy(std.mem.sliceAsBytes(me.vcol), b);
    }
}

const t_ = std.testing;

test "a tint: integers, as the original's division" {
    var v = [_]m.V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    var c = [_]u32{ 0xffff0000, 0xff00ff00, 0xff0000ff };
    var tr = [_][3]u32{.{ 0, 1, 2 }};
    var me = std.mem.zeroInit(Mesh, .{ .verts = v[0..], .tris = tr[0..], .vcol = c[0..] });
    try t_.expectEqual(@as(u32, 0x555555), avg(&me, 0, 0xffffff));
    try t_.expectEqual(@as(u32, 0x2a0000), avg(&me, 0, 0x808080) & 0xff0000);
    c = .{ 0xffffffff, 0xffffffff, 0xffffffff };
    try t_.expectEqual(@as(u32, 0x804020), avg(&me, 0, 0x804020));
    me.vcol = &.{};
    try t_.expectEqual(@as(u32, 0x123456), avg(&me, 0, 0x123456));
    try t_.expect(lin(&me, 0, 0, 0) == null);
}

test "interpolated in linear light" {
    const c = [3]u32{ 0xffffffff, 0xff000000, 0xff000000 };
    const p = lin3(&c, 0.5, 0.25);
    try t_.expectApproxEqAbs(@as(f32, 0.25), p[0], 1e-6);
    const q = lin3(&c, 0, 0);
    try t_.expectEqual(@as(f32, texture.lut[255]), q[1]);
    const g = [3]u32{ 0xff808080, 0xff808080, 0xff808080 };
    try t_.expectApproxEqAbs(texture.lut[128], lin3(&g, 0.2, 0.3)[2], 1e-6);
}

test "the file's records" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], 0, .little);
    std.mem.writeInt(u32, buf[4..8], 0x10000000, .little);
    readChunk(buf[0..16], &[_]?u16{null}); // (too many: ends here, reads nothing)
    std.mem.writeInt(u32, buf[4..8], 100, .little);
    readChunk(buf[0..16], &[_]?u16{null}); // (past the end)
    std.mem.writeInt(u32, buf[0..4], 7, .little);
    std.mem.writeInt(u32, buf[4..8], 1, .little);
    readChunk(buf[0..12], &[_]?u16{null}); // (no such mesh)
}
