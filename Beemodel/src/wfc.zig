// Wave function collapse (procgen.s wfc_run and its wf_* helpers): tile objects
// arranged on an nx x nz grid, layers high, so that neighbours fit. A tile
// spans -0.5..0.5 on each axis; each of its sides is known by the vertices on
// it (their two other coordinates quantized to 1/64, hashed, summed). A tile
// turned a quarter about Y is another option unless its sides are the same
// as a turn already there. Two options fit side by side when one's side d
// hashes as the other's side d ^ 1. Solving: the cell with the fewest options
// (ties at random) takes one at random, the neighbours narrow until nothing
// changes; a contradiction tries the next seed (20 tries). The answer is one
// mesh: every cell's tile, turned, at its cell (cells centred on the origin
// in X and Z, layers upwards). Integer arithmetic as the original's: the
// grid's sizes are 32-bit, divided unsigned; floats in its order.
const std = @import("std");
const scene = @import("scene.zig");
const A = @import("alloc.zig").A;

pub const MAXT = 16;
pub const MAXO = 64;
pub const MAXC = 32768;
const TRIES = 20;

const Side = struct { c: u2, v: f32, a: u2, b: u2 };
/// per side: the coordinate tested, its value, the key's two coordinates
const sides = [6]Side{
    .{ .c = 0, .v = 0.5, .a = 1, .b = 2 },  .{ .c = 0, .v = -0.5, .a = 1, .b = 2 },
    .{ .c = 1, .v = 0.5, .a = 0, .b = 2 },  .{ .c = 1, .v = -0.5, .a = 0, .b = 2 },
    .{ .c = 2, .v = 0.5, .a = 0, .b = 1 },  .{ .c = 2, .v = -0.5, .a = 0, .b = 1 },
};

const St = struct {
    tiles: []const usize,
    nx: u32,
    nz: u32,
    ny: u32,
    nc: u32 = 0,
    no: u32 = 0,
    rng: u32 = 0,
    otile: [MAXO]u8 = undefined,
    orot: [MAXO]u8 = undefined,
    sig: [MAXO][6]u64 = undefined,
    comp: [MAXO][6]u64 = undefined,
    mat: [MAXT][12]f32 = undefined,
    cell: []u64 = &.{},
    stack: []u32 = &.{},
    sp: usize = 0,
};

/// cvtss2si: to the nearest (ties to even); NaN or out of range: 0x80000000.
fn cvt(x: f32) u32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return 0x80000000;
    const r = @round(x);
    const t: f32 = if (@abs(x - @trunc(x)) == 0.5) 2.0 * @round(x / 2.0) else r;
    return @bitCast(@as(i32, @intFromFloat(t)));
}

/// wf_key: a hash of the point quantized to 1/64 (splitmix64).
fn key(a: f32, b: f32) u64 {
    var x: u64 = (@as(u64, cvt(a * 64.0)) << 32) | cvt(b * 64.0);
    x +%= 0x9E3779B97F4A7C15;
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    return x ^ (x >> 31);
}

/// wf_near: within 1/1000 (NaN counts: comiss unordered sets CF).
fn near(v: f32, t: f32) bool {
    return !(@abs(v - t) >= 0.001);
}

/// wf_rot: (x, z) turned about Y a quarter at a time: (z, -x).
fn rot(p: [3]f32, turns: u32) [3]f32 {
    var x = p[0];
    var z = p[2];
    var k = turns;
    while (k > 0) : (k -= 1) {
        const t = x;
        x = z;
        z = 0.0 - t;
    }
    return .{ x, p[1], z };
}

/// wf_tv_of: a vertex through the tile's matrix (turn and scale, no place).
fn tv(s: *const St, p: [3]f32, tile: usize) [3]f32 {
    const m = &s.mat[tile];
    var o: [3]f32 = undefined;
    for (0..3) |r| {
        var x = m[r * 4] * p[0];
        x += m[r * 4 + 1] * p[1];
        x += m[r * 4 + 2] * p[2];
        x += m[r * 4 + 3];
        o[r] = x;
    }
    return o;
}

/// obj_matrix: T Rz Ry Rx S, row-major, from the object's own place and its
/// rotation in radians as the original keeps them (fsincos, f32 products in
/// its order); a child's from its world transform as the port keeps it.
pub fn objMatrix(i: usize) [16]f32 {
    const o = &scene.objects[i];
    if (o.parent != null) return scene.world(i);
    const ax = @import("animexpr.zig");
    const rad = o.radians();
    const x = ax.sincos32(rad[0]);
    const y = ax.sincos32(rad[1]);
    const z = ax.sincos32(rad[2]);
    const sx = x[0];
    const cx = x[1];
    const sy = y[0];
    const cy = y[1];
    const sz = z[0];
    const cz = z[1];
    var r: [16]f32 = .{
        cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx, o.loc[0],
        sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx, o.loc[1],
        0 - sy,  cy * sx,                cy * cx,                o.loc[2],
        0,       0,                      0,                      1,
    };
    for (0..3) |row| {
        for (0..3) |c| r[row * 4 + c] = o.scl[c] * r[row * 4 + c];
    }
    return r;
}

/// A tile's mesh: its vertices and polygons (loops[poff[p] .. poff[p + 1]]).
const TMesh = struct { verts: []const [3]f32, poff: []const u32, loops: []const u32 };

// The original's lights, cameras and force fields carry a mesh of their own
// (mesh.s prim_light, prim_camera: what they show as); the port draws them
// otherwise. Armatures (their bones' octahedra) and sketches (their display
// mesh) have theirs in both.
const light_v = [6][3]f32{ .{ 0, 0.25, 0 }, .{ 0.25, 0, 0 }, .{ 0, 0, 0.25 }, .{ -0.25, 0, 0 }, .{ 0, 0, -0.25 }, .{ 0, -0.25, 0 } };
const light_l = [24]u32{ 0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 1, 5, 2, 1, 5, 3, 2, 5, 4, 3, 5, 1, 4 };
const light_o = [9]u32{ 0, 3, 6, 9, 12, 15, 18, 21, 24 };
const cam_v = [8][3]f32{ .{ 0, 0, 0 }, .{ -0.5, -0.35, -1 }, .{ 0.5, -0.35, -1 }, .{ 0.5, 0.35, -1 }, .{ -0.5, 0.35, -1 }, .{ -0.3, 0.45, -1 }, .{ 0.3, 0.45, -1 }, .{ 0, 0.7, -1 } };
const cam_l = [19]u32{ 0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 1, 1, 4, 3, 2, 5, 6, 7 };
const cam_o = [7]u32{ 0, 3, 6, 9, 12, 16, 19 };

/// The tile object's own mesh (OB_MESH, not evaluated), or null.
fn meshOf(oi: usize) ?TMesh {
    const o = &scene.objects[oi];
    switch (o.kind) {
        .light => return .{ .verts = &light_v, .poff = &light_o, .loops = &light_l },
        .camera => return .{ .verts = &cam_v, .poff = &cam_o, .loops = &cam_l },
        .field => return .{ .verts = &light_v, .poff = &light_o, .loops = &light_l }, // (fl_add_named: prim_light)
        .armature => if (o.arm_dirty) @import("arm.zig").rebuild(oi), // (its bones' display mesh, as shown)
        else => {},
    }
    const mi = o.mesh orelse return null;
    const me = if (scene.meshes[mi]) |*x| x else return null;
    return .{ .verts = me.verts, .poff = me.poff, .loops = me.loops };
}

fn sigs(s: *St, me: TMesh, turns: u32, tile: usize, out: *[6]u64) void {
    out.* = @splat(0);
    for (me.verts) |v| {
        const p = rot(tv(s, v, tile), turns);
        for (sides, 0..) |sd, d| {
            if (near(p[sd.c], sd.v)) out[d] +%= key(p[sd.a], p[sd.b]);
        }
    }
}

/// wf_options: tiles x distinct turns; who fits beside whom.
fn options(s: *St) u32 {
    s.no = 0;
    tiles: for (s.tiles, 0..) |oi, t| {
        var mt = objMatrix(oi);
        mt[3] = 0;
        mt[7] = 0;
        mt[11] = 0;
        s.mat[t] = mt[0..12].*;
        const me = meshOf(oi) orelse continue;
        var r: u32 = 0;
        while (r < 4) : (r += 1) {
            if (s.no >= MAXO) break :tiles;
            sigs(s, me, r, t, &s.sig[s.no]);
            var dup = false;
            for (0..s.no) |k| {
                if (s.otile[k] == t and std.mem.eql(u64, &s.sig[k], &s.sig[s.no])) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            s.otile[s.no] = @intCast(t);
            s.orot[s.no] = @intCast(r);
            s.no += 1;
        }
    }
    for (0..s.no) |o| {
        for (0..6) |d| {
            var mask: u64 = 0;
            for (0..s.no) |o2| {
                if (s.sig[o2][d ^ 1] == s.sig[o][d]) mask |= @as(u64, 1) << @intCast(o2);
            }
            s.comp[o][d] = mask;
        }
    }
    return s.no;
}

/// wf_neighbour: the cell beside it, or null.
fn neighbour(s: *const St, cell: u32, side: usize) ?u32 {
    var x = cell % s.nx;
    const t = cell / s.nx;
    var z = t % s.nz;
    var y = t / s.nz;
    switch (side) {
        0 => x +%= 1,
        1 => x -%= 1,
        2 => y +%= 1,
        3 => y -%= 1,
        4 => z +%= 1,
        else => z -%= 1,
    }
    if (x >= s.nx or z >= s.nz or y >= s.ny) return null;
    const n = (y *% s.nz +% z) *% s.nx +% x;
    // (sizes whose product is positive though some are negative - huge as
    // unsigned - give cells past the grid: the original reads and writes
    // past its cell array there; here there is no neighbour)
    if (n >= s.nc) return null;
    return n;
}

/// pg_rand: xorshift32.
fn rand(s: *St) u32 {
    var x = s.rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    s.rng = x;
    return x;
}

/// wf_propagate: false on a contradiction.
fn propagate(s: *St) bool {
    while (s.sp > 0) {
        s.sp -= 1;
        const c = s.stack[s.sp];
        var opts = s.cell[c];
        for (0..6) |d| {
            var allowed: u64 = 0;
            var m = opts;
            while (m != 0) {
                const b: u6 = @intCast(@ctz(m));
                m &= m - 1;
                allowed |= s.comp[b][d];
            }
            const n = neighbour(s, c, d) orelse continue;
            const cur = s.cell[n];
            const nw = cur & allowed;
            if (nw == cur) continue;
            if (nw == 0) return false;
            s.cell[n] = nw;
            if (s.sp < s.stack.len) {
                s.stack[s.sp] = n;
                s.sp += 1;
            }
            if (n == c) opts = s.cell[c]; // (never: a cell is not its own neighbour)
        }
    }
    return true;
}

/// wf_solve: true when every cell has one option left.
fn solve(s: *St) bool {
    const all: u64 = if (s.no >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(s.no)) - 1;
    @memset(s.cell, all);
    while (true) {
        var best: u64 = ~@as(u64, 0);
        var bc: ?u32 = null;
        for (s.cell, 0..) |m, c| {
            const pc: u64 = @popCount(m);
            if (pc <= 1) continue;
            const v = (pc << 32) | rand(s);
            if (v < best) {
                best = v;
                bc = @intCast(c);
            }
        }
        const c = bc orelse return true;
        var m = s.cell[c];
        const cnt: u32 = @popCount(m);
        var r = rand(s) % cnt;
        var bit: u6 = @intCast(@ctz(m));
        while (r != 0) : (r -= 1) {
            m &= m - 1;
            bit = @intCast(@ctz(m));
        }
        s.cell[c] = @as(u64, 1) << bit;
        s.stack[0] = c;
        s.sp = 1;
        if (!propagate(s)) return false;
    }
}

const CellMesh = struct { me: TMesh, turns: u32, tile: usize };

fn cellMesh(s: *const St, c: usize) ?CellMesh {
    const m = s.cell[c];
    if (m == 0) return null;
    const o = @ctz(m);
    const t = s.otile[o];
    const me = meshOf(s.tiles[t]) orelse return null;
    return .{ .me = me, .turns = s.orot[o], .tile = t };
}

fn cvtsi(x: u32) f32 {
    return @floatFromInt(@as(i32, @bitCast(x)));
}

/// wf_mesh: the tiles in their cells, one mesh slot (none: null).
fn mesh(s: *const St) ?u16 {
    var nv: u64 = 0;
    var nl: usize = 0;
    var np: usize = 0;
    for (0..s.nc) |c| {
        const cm = cellMesh(s, c) orelse continue;
        nv += cm.me.verts.len;
        nl += cm.me.loops.len;
        np += cm.me.poff.len -| 1;
    }
    if (nv > 50000000) return null;
    const verts = A.alloc([3]f32, @intCast(nv)) catch return null;
    defer A.free(verts);
    const poff = A.alloc(u32, np + 1) catch return null;
    defer A.free(poff);
    const loops = A.alloc(u32, nl) catch return null;
    defer A.free(loops);
    var vi: usize = 0;
    var pi: usize = 0;
    var li: usize = 0;
    poff[0] = 0;
    for (0..s.nc) |c| {
        const cm = cellMesh(s, c) orelse continue;
        const cu: u32 = @intCast(c);
        const x = cvtsi(cu % s.nx) - (cvtsi(s.nx) - 1.0) * 0.5;
        const t = cu / s.nx;
        const z = cvtsi(t % s.nz) - (cvtsi(s.nz) - 1.0) * 0.5;
        const y = cvtsi(t / s.nz);
        const base: u32 = @intCast(vi);
        for (cm.me.verts) |v| {
            const p = rot(tv(s, v, cm.tile), cm.turns);
            verts[vi] = .{ p[0] + x, p[1] + y, p[2] + z };
            vi += 1;
        }
        const me = cm.me;
        var p: usize = 0;
        while (p + 1 < me.poff.len) : (p += 1) {
            const a = me.poff[p];
            const n = me.poff[p + 1] -% a;
            if (n > 4096) continue;
            for (me.loops[a .. a + n]) |l| {
                loops[li] = l +% base;
                li += 1;
            }
            pi += 1;
            poff[pi] = @intCast(li);
        }
    }
    if (vi == 0) return scene.addEmptyMesh();
    return scene.addMesh(verts[0..vi], poff[0 .. pi + 1], loops[0..li]);
}

/// wfc_run: the grid solved (up to 20 seeds) and made one mesh slot; null
/// when it cannot be solved (no options, a grid of no cells or more than
/// 32768, no seed solves it).
pub fn run(tiles: []const usize, nx: i32, nz: i32, ny: i32, seed: i32) ?u16 {
    var s = A.create(St) catch return null;
    defer A.destroy(s);
    s.* = .{ .tiles = tiles[0..@min(tiles.len, MAXT)], .nx = @bitCast(nx), .nz = @bitCast(nz), .ny = @bitCast(ny) };
    if (options(s) == 0) return null;
    const p1 = @mulWithOverflow(nx, nz);
    if (p1[1] != 0) return null;
    const p2 = @mulWithOverflow(p1[0], ny);
    if (p2[1] != 0) return null;
    if (p2[0] <= 0 or p2[0] > MAXC) return null;
    s.nc = @intCast(p2[0]);
    s.cell = A.alloc(u64, s.nc) catch return null;
    defer A.free(s.cell);
    s.stack = A.alloc(u32, @as(usize, s.nc) * 64 + 16) catch return null;
    defer A.free(s.stack);
    var t: u32 = 0;
    while (t < TRIES) : (t += 1) {
        s.rng = ((@as(u32, @bitCast(seed)) +% t) *% 0x9E3779B1) | 1;
        if (solve(s)) return mesh(s);
    }
    return null;
}

test "wfc: keys, turns, nearness" {
    try std.testing.expectEqual(@as(u32, 0x80000000), cvt(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 2), cvt(2.5));
    try std.testing.expectEqual(@as(u32, 4), cvt(3.5));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -2))), cvt(-2.5));
    try std.testing.expect(near(std.math.nan(f32), 0.5));
    try std.testing.expect(near(0.5004, 0.5));
    try std.testing.expect(!near(0.502, 0.5));
    const r = rot(.{ 1, 2, 3 }, 1);
    try std.testing.expectEqual([3]f32{ 3, 2, -1 }, r);
    try std.testing.expectEqual(rot(.{ 1, 2, 3 }, 4), [3]f32{ 1, 2, 3 });
    try std.testing.expect(key(0.5, 0.25) != key(0.25, 0.5));
}

test "wfc: neighbours on a 3 x 2 x 2 grid" {
    var s = St{ .tiles = &.{}, .nx = 3, .nz = 2, .ny = 2, .nc = 12 };
    try std.testing.expectEqual(@as(?u32, 1), neighbour(&s, 0, 0));
    try std.testing.expectEqual(@as(?u32, null), neighbour(&s, 0, 1));
    try std.testing.expectEqual(@as(?u32, 6), neighbour(&s, 0, 2));
    try std.testing.expectEqual(@as(?u32, 3), neighbour(&s, 0, 4));
    try std.testing.expectEqual(@as(?u32, null), neighbour(&s, 11, 0));
    s.rng = 1;
    try std.testing.expectEqual(@as(u32, 270369), rand(&s));
}
