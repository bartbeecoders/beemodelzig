// World partition (world.s): a scene split into grid cells that stream in and
// out by distance from the camera.
//
// world.partition <size> splits a saved scene into square cells on the ground
// (x, z). Plain mesh objects (no modifiers, multires, curve, text, armature,
// weights or shape keys) belong to the cell under their location; everything
// else stays loaded. Each cell is its own file beside the scene,
// <name>.cells/<x>_<z>.cell: "BEEC", version 1, x, z, then its meshes (MESH,
// MUVS, MVCL, VGEO, LAND chunks, as in .bee files) and its objects (CELO:
// count, 120-byte records: name, transform, colour, type, flags, mesh, uid,
// material name). The scene's own file keeps the rest and the cell index
// (WRLP: cell size, radius, budget, then the cells with a file).
//
// tick (every pass of the window's loop; world.update in scripts):
//   1. an object standing in a cell that is not loaded pulls the cell in;
//   2. cells within the loading radius of the camera come in, nearest first,
//      two a pass, while the memory budget allows;
//   3. loaded cells past 1.25 x the radius go out, and while the cells in
//      memory pass the budget, the farthest go out. A cell going out is written
//      first when it changed: a fingerprint of its objects taken when it came in
//      or was written tells.
// Streaming starts the undo history afresh (steps from before would bring back
// what is now on disk). Unloaded cells show as boxes in the viewport, and a
// minimap shows them all with the camera and its radius.
//
// The cell table is the original's: open addressing on (x, z) with its hash, so
// the index and the minimap walk the cells in the same order. A cell's memory
// is the original's mesh mapping (mesh_new's bytes for the mesh's counts), so the
// budget unloads the same cells. The fingerprint is the port's own (the
// original's hashes its mesh pointers): its value in WRLP differs, nothing reads
// it back.
const std = @import("std");
const linux = std.os.linux;
const m = @import("math.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const bee = @import("bee.zig");
const material = @import("material.zig");
const gfx = @import("gfx.zig");
const nt = @import("ntree.zig");

pub const CAP = 16384;
const LOADS = 2; // cells loaded a pass (the window)
const CELL_MAGIC: u32 = 0x43454542; // "BEEC"
const CELL_VER: u32 = 1;
const CO_SZ = 120;
const REC = 8 + 68; // a WRLP record: x, z, then the record from WC_NOBJ on
fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}
const T_MESH = tag("MESH");
const T_MUVS = tag("MUVS");
const T_MVCL = tag("MVCL");
const T_VGEO = tag("VGEO");
const T_CELO = tag("CELO");
const T_LAND = tag("LAND");
const BIG: f32 = 1.0e30;
const LIM: f32 = 1.0e8;

pub const Cell = struct {
    ix: i32 = 0,
    iz: i32 = 0,
    used: bool = false,
    disk: bool = false, // its file exists
    loaded: bool = false, // its objects are in the scene
    nobj: u32 = 0,
    fp: u64 = 0, // its objects' fingerprint (in, written)
    bytes: u64 = 0, // its meshes' memory
    bmin: [3]f32 = .{ BIG, BIG, BIG },
    bmax: [3]f32 = .{ -BIG, -BIG, -BIG },
    nfp: u64 = 0, // (fps: its objects' fingerprint now and how many)
    nnow: u32 = 0,
};

pub var budget: u64 = 0x20000000; // 512 MiB of cells' meshes
pub var size: f32 = 64.0;
pub var radius: f32 = 160.0;
pub var minimap: bool = true;
pub var on: bool = false;
/// Autosave: what is loaded, as a plain scene (no WRLP, nothing left out).
pub var plain: bool = false;
/// Cells in reach waiting to come in (the window looks again soon).
pub var pending: u32 = 0;
var saving = false;
var tab: [CAP]Cell = @splat(.{});
var ncell: u32 = 0;
var loaded_bytes: u64 = 0;
var eye: m.V3 = .{ 0, 0, 0 };
var nload: u32 = 0;
var nunload: u32 = 0;
var nwrite: u32 = 0;
var nmoved: u32 = 0;
var dir_buf: [512]u8 = undefined;
var dir_len: usize = 0; // <scene>.cells (0: none, an unsaved world)
var lpath_buf: [512]u8 = undefined;
var lpath_len: usize = 0; // the file being opened
/// Moves whenever what the viewport shows of the cells changes.
pub var version: u32 = 0;
/// A cell's object found the scene full (it stays in its file).
var full = false;

fn dir() []const u8 {
    return dir_buf[0..dir_len];
}

// --- cells ---------------------------------------------------------------------------------------

/// wp_reset: no partition (a new scene, another file). The size, radius,
/// budget and the counts stay, as the original's.
pub fn reset() void {
    on = false;
    pending = 0;
    loaded_bytes = 0;
    dir_len = 0;
    if (ncell != 0) {
        tab = @splat(.{});
        ncell = 0;
    }
    version +%= 1;
}

/// wp_note_path: the file bee.load opens.
pub fn notePath(p: []const u8) void {
    lpath_len = @min(p.len, 511);
    @memcpy(lpath_buf[0..lpath_len], p[0..lpath_len]);
}

fn hashOf(x: i32, z: i32) u32 {
    var h: u32 = @as(u32, @bitCast(x)) *% 0x9e3779b1;
    h ^= @as(u32, @bitCast(z)) *% 0x85ebca6b;
    h ^= h >> 15;
    return h & (CAP - 1);
}

/// cell_find: the cell's record, made when `make` (null: none, or the table
/// is three quarters full).
fn find(x: i32, z: i32, make: bool) ?*Cell {
    var h = hashOf(x, z);
    while (true) {
        const c = &tab[h];
        if (!c.used) {
            if (!make or ncell >= CAP * 3 / 4) return null;
            c.* = .{ .ix = x, .iz = z, .used = true };
            ncell += 1;
            return c;
        }
        if (c.ix == x and c.iz == z) return c;
        h = (h + 1) & (CAP - 1);
    }
}

/// minss / maxss: the second operand when either is NaN.
fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

/// cell_xz: the cell under (x, z).
fn cellXZ(x: f32, z: f32) [2]i32 {
    var a = minss(x / size, LIM);
    var b = minss(z / size, LIM);
    a = maxss(a, -LIM);
    b = maxss(b, -LIM);
    return .{ nt.cvtt(@floor(a)), nt.cvtt(@floor(b)) };
}

fn objCell(i: usize) [2]i32 {
    const p = scene.worldPlace(i);
    return cellXZ(p[0], p[2]);
}

/// obj_part: object i belongs to a cell (a plain mesh object).
pub fn isPart(i: usize) bool {
    if (!on) return false;
    const o = &scene.objects[i];
    if (!o.kind.isMesh() or o.mods.n != 0 or o.mres != null or o.sk != null) return false;
    const mi = o.mesh orelse return false;
    const me = scene.meshes[mi] orelse return false;
    return me.curve == null and me.text == null and me.arm == null and me.wgt.len == 0 and me.sk == null;
}

fn inCell(i: usize, c: *const Cell) bool {
    if (!isPart(i)) return false;
    const xz = objCell(i);
    return xz[0] == c.ix and xz[1] == c.iz;
}

fn mix(h: u64, v: u64) u64 {
    var x = (h ^ v) *% 0x9e3779b97f4a7c15;
    x ^= x >> 29;
    return x;
}

/// obj_fp: its id, name, transform, flags (not the selection), material, mesh
/// and what the mesh is now.
fn objFp(i: usize) u64 {
    const o = &scene.objects[i];
    var h: u64 = o.uid;
    for (0..4) |k| h = mix(h, std.mem.readInt(u64, o.name_buf[k * 8 ..][0..8], .little));
    for (scene.worldPlace(i)) |f| h = mix(h, @as(u32, @bitCast(f)));
    h = mix(h, bee.objFlags(o) & ~@as(u32, 1));
    h = mix(h, o.mat);
    const mi = o.mesh.?;
    h = mix(h, mi);
    if (scene.meshes[mi]) |*me| {
        h = mix(h, me.serial);
        h = mix(h, me.shape);
        h = mix(h, me.paints);
        h = mix(h, me.uv.len ^ (me.seam.len << 32) ^ (me.vcol.len << 16));
    }
    return h;
}

/// cell_scan: its objects' fingerprint (a sum: their order does not matter) and count.
fn scan(c: *const Cell) struct { fp: u64, n: u32 } {
    var s: u64 = 0;
    var n: u32 = 0;
    for (0..scene.count) |i| {
        if (!inCell(i, c)) continue;
        s +%= objFp(i);
        n += 1;
    }
    return .{ .fp = s, .n = n };
}

/// cell_dirty: it must be written (changed since it came in or was written,
/// or never written and not empty).
fn dirty(c: *const Cell) bool {
    const s = scan(c);
    return if (c.disk) s.fp != c.fp else s.n != 0;
}

/// wp_fps: every cell's objects' fingerprint and count now, in one pass.
fn fps() void {
    for (&tab) |*c| {
        c.nfp = 0;
        c.nnow = 0;
    }
    for (0..scene.count) |i| {
        if (!isPart(i)) continue;
        const xz = objCell(i);
        const c = find(xz[0], xz[1], false) orelse continue;
        c.nfp +%= objFp(i);
        c.nnow += 1;
    }
}

fn fpDirty(c: *const Cell) bool {
    return if (c.disk) c.nfp != c.fp else c.nnow != 0;
}

fn cellPath(c: *const Cell, buf: []u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{d}_{d}.cell", .{ dir(), c.ix, c.iz }, 0) catch null;
}

/// The original's mesh mapping for a mesh of these counts (mesh_new: the
/// header, then positions, offsets, loops, edges, triangles and selection).
pub fn meshBytes(me: *const scene.Mesh) u64 {
    const nv: u64 = me.verts.len;
    const np: u64 = me.poff.len -| 1;
    const nl: u64 = me.loops.len;
    return (240 + 13 * nv + 4 * (np + 1) + 28 * nl + 4095) & ~@as(u64, 4095);
}

/// sincos as the x87's fsincos of a float, rounded to floats.
fn sinCos(a: f32) [2]f32 {
    const x: f64 = a;
    return .{ @floatCast(@sin(x)), @floatCast(@cos(x)) };
}

/// obj_matrix: rows of (rotation x scale, translation), from the place the
/// original keeps (location, radians, scale).
fn origMatrix(p: [9]f32) [3][4]f32 {
    const x = sinCos(p[3]);
    const y = sinCos(p[4]);
    const z = sinCos(p[5]);
    const sx = x[0];
    const cx = x[1];
    const sy = y[0];
    const cy = y[1];
    const sz = z[0];
    const cz = z[1];
    var r: [3][4]f32 = undefined;
    r[0][0] = cz * cy;
    r[0][1] = cz * sy * sx - sz * cx;
    r[0][2] = cz * sy * cx + sz * sx;
    r[1][0] = sz * cy;
    r[1][1] = sz * sy * sx + cz * cx;
    r[1][2] = sz * sy * cx - cz * sx;
    r[2][0] = 0 - sy;
    r[2][1] = cy * sx;
    r[2][2] = cy * cx;
    for (0..3) |k| {
        r[k][0] = p[6] * r[k][0];
        r[k][1] = p[7] * r[k][1];
        r[k][2] = p[8] * r[k][2];
        r[k][3] = p[k];
    }
    return r;
}

/// obj_bounds: its mesh's box moved by its matrix (the eight corners), into
/// the cell's bounds.
fn objBounds(i: usize, c: *Cell) void {
    const me = scene.meshOfObj(i) orelse return;
    const mt = origMatrix(scene.worldPlace(i));
    for (0..8) |bits| {
        for (0..3) |r| {
            var v = mt[r][3];
            for (0..3) |a| {
                const b = if (bits >> @intCast(a) & 1 != 0) me.hi[a] else me.lo[a];
                v += b * mt[r][a];
            }
            c.bmin[r] = minss(c.bmin[r], v);
            c.bmax[r] = maxss(c.bmax[r], v);
        }
    }
}

/// Bytes to a file: a temporary file beside it, renamed over it (the
/// original's file_write_atomic: no sync, cells are written while flying).
fn writeFile(p: [:0]const u8, data: []const u8) bool {
    var tb: [640]u8 = undefined;
    const t = std.fmt.bufPrintSentinel(&tb, "{s}.{d}-wp.tmp", .{ p, linux.getpid() }, 0) catch return false;
    const rc = linux.open(t, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    var off: usize = 0;
    var ok = true;
    while (off < data.len) {
        const w = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(w) == .INTR) continue;
        if (linux.errno(w) != .SUCCESS or w == 0) {
            ok = false;
            break;
        }
        off += w;
    }
    _ = linux.close(fd);
    if (!ok or linux.errno(linux.rename(t, p)) != .SUCCESS) {
        _ = linux.unlink(t);
        return false;
    }
    return true;
}

fn ensureDir(p: []const u8) void {
    if (!@import("files.zig").mayWrite(p)) return;
    _ = @import("spawn.zig").ensureDir(p);
}

/// The meshes of a cell being written, in the order its objects first use them.
var mesh_tab: std.ArrayList(u16) = .empty;
/// Each of the cell's objects' place in it. A primitive's mesh is the
/// object's own in the original (the port shares one): a chunk each.
var obj_mesh: std.ArrayList(u32) = .empty;
const A = @import("alloc.zig").A;

fn meshIndex(mi: u16) u32 {
    for (mesh_tab.items, 0..) |x, k| {
        if (x == mi and !scene.isPrim(mi)) return @intCast(k);
    }
    if (mesh_tab.items.len >= scene.max_meshes) return 0xffffffff;
    mesh_tab.append(A, mi) catch return 0xffffffff;
    return @intCast(mesh_tab.items.len - 1);
}

fn resetBounds(c: *Cell) void {
    c.bmin = .{ BIG, BIG, BIG };
    c.bmax = .{ -BIG, -BIG, -BIG };
}

/// The cell's file as the original writes it (its objects, in the scene's order).
fn encodeCell(c: *Cell, nobj: u32) ?[]u8 {
    var b = bee.Buf{};
    bee.encode_failed = false;
    b.u32_(CELL_MAGIC);
    b.u32_(CELL_VER);
    b.u32_(@bitCast(c.ix));
    b.u32_(@bitCast(c.iz));
    for (mesh_tab.items) |mi| {
        const me = &scene.meshes[mi].?;
        const st = b.begin(T_MESH);
        b.u32_(@intCast(me.verts.len));
        b.u32_(@intCast(me.poff.len - 1));
        b.u32_(@intCast(me.loops.len));
        b.bytes(std.mem.sliceAsBytes(me.verts));
        b.bytes(std.mem.sliceAsBytes(me.poff));
        b.bytes(std.mem.sliceAsBytes(me.loops));
        b.end(st);
    }
    var st = b.begin(T_MUVS);
    for (mesh_tab.items, 0..) |mi, k| bee.writeUvs(&b, @intCast(k), &scene.meshes[mi].?);
    b.end(st);
    st = b.begin(T_MVCL);
    for (mesh_tab.items, 0..) |mi, k| {
        const me = &scene.meshes[mi].?;
        if (me.vcol.len == 0 or me.vcol.len != me.verts.len) continue;
        b.u32_(@intCast(k));
        b.u32_(@intCast(me.vcol.len));
        b.bytes(std.mem.sliceAsBytes(me.vcol));
    }
    b.end(st);
    {
        const ix = A.alloc(u32, scene.max_meshes) catch {
            b.data.deinit(b.a);
            return null;
        };
        defer A.free(ix);
        @memset(ix, 0xffffffff);
        for (mesh_tab.items, 0..) |mi, k| ix[mi] = @intCast(k);
        @import("vgeo.zig").writeChunks(&b, ix);
        st = b.begin(T_LAND);
        @import("landscape.zig").writeChunk(&b, ix);
        b.end(st);
    }
    st = b.begin(T_CELO);
    b.u32_(nobj);
    var nth: u32 = 0; // (the objects in the order they were given their meshes)
    for (0..scene.count) |i| {
        if (!inCell(i, c)) continue;
        defer nth += 1;
        const o = &scene.objects[i];
        b.bytes(&o.name_buf);
        const wp = scene.worldPlace(i);
        for (wp) |f| b.u32_(@bitCast(f));
        b.u32_(o.color & 0xffffff);
        b.u32_(0); // (OT_MESH)
        b.u32_(bee.objFlags(o));
        b.u32_(obj_mesh.items[nth]);
        b.u32_(o.uid);
        var mn: [32]u8 = @splat(0);
        if (material.of(o)) |ma| @memcpy(mn[0..31], ma.name[0..31]);
        b.bytes(&mn);
    }
    b.end(st);
    if (bee.encode_failed) {
        b.data.deinit(b.a);
        return null;
    }
    return b.data.toOwnedSlice(b.a) catch null;
}

/// cell_write: its file holds its objects in the scene now (written, or
/// removed when it has none). False: it could not be written.
fn write(c: *Cell) bool {
    var pb: [600]u8 = undefined;
    const p = cellPath(c, &pb) orelse return false;
    resetBounds(c);
    mesh_tab.clearRetainingCapacity();
    obj_mesh.clearRetainingCapacity();
    defer mesh_tab.clearRetainingCapacity();
    defer obj_mesh.clearRetainingCapacity();
    var nobj: u32 = 0;
    for (0..scene.count) |i| {
        if (!inCell(i, c)) continue;
        nobj += 1;
        obj_mesh.append(A, meshIndex(scene.objects[i].mesh.?)) catch return false;
        objBounds(i, c);
    }
    if (nobj == 0) { // none: no file
        _ = linux.unlink(p);
        c.disk = false;
        c.nobj = 0;
        c.fp = 0;
        c.bytes = 0;
        version +%= 1;
        return true;
    }
    const data = encodeCell(c, nobj);
    ensureDir(dir());
    const ok = if (data) |d| @import("files.zig").mayWrite(p) and writeFile(p, d) else false;
    if (data) |d| std.heap.page_allocator.free(d);
    if (!ok) {
        app.log("World partition: a cell could not be written (kept loaded)", .{});
        return false;
    }
    var by: u64 = 0;
    for (mesh_tab.items) |mi| by += meshBytes(&scene.meshes[mi].?);
    c.bytes = by;
    c.disk = true;
    c.nobj = nobj;
    c.fp = scan(c).fp;
    nwrite += 1;
    version +%= 1;
    return true;
}

/// cell_unload: written when changed, its objects out of the scene. False:
/// the write failed, it stays.
fn unload(c: *Cell) bool {
    if (dirty(c) and !write(c)) return false;
    var i = scene.count;
    while (i > 0) {
        i -= 1;
        if (inCell(i, c)) scene.remove(i);
    }
    c.loaded = false;
    loaded_bytes -|= c.bytes;
    nunload += 1;
    version +%= 1;
    return true;
}

/// name_taken + unique_name: "Base" (26 bytes at most), "Base.001" ... ".999".
fn uniqueName(o: *scene.Object, base0: []const u8) void {
    const base = base0[0..@min(base0.len, 26)];
    var k: u32 = 0;
    var buf: [32]u8 = undefined;
    while (true) {
        const nm = if (k == 0) base else std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ base, k }) catch base;
        var taken = false;
        for (scene.objects[0..scene.count]) |*x| {
            if (std.mem.eql(u8, x.name(), nm)) taken = true;
        }
        o.name_buf = @splat(0);
        @memcpy(o.name_buf[0..nm.len], nm);
        o.name_len = @intCast(nm.len);
        if (!taken) return;
        k += 1;
        if (k > 999) return;
    }
}

fn rd32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .little);
}

/// mesh_from's checks: the counts in its limits, the chunk holds them, the
/// offsets rise from 0 to at most the loops, every loop a vertex.
fn meshOk(c: []const u8) bool {
    if (c.len < 12) return false;
    const nv = rd32(c, 0);
    const np = rd32(c, 4);
    const nl = rd32(c, 8);
    if (nv > 0x1000000 or np > 0x1000000 or nl > 0x4000000) return false;
    const need = 12 + @as(u64, nv) * 12 + (@as(u64, np) + 1) * 4 + @as(u64, nl) * 4;
    if (need > c.len) return false;
    const po = 12 + @as(usize, nv) * 12;
    var prev: u32 = 0;
    for (0..np + 1) |k| {
        const x = rd32(c, po + k * 4);
        if (x < prev or x > nl) return false;
        prev = x;
    }
    if (np != 0 and rd32(c, po) != 0) return false;
    const lo = po + (@as(usize, np) + 1) * 4;
    for (0..nl) |k| {
        if (rd32(c, lo + k * 4) >= nv) return false;
    }
    return true;
}

/// mesh_from (after meshOk): the mesh from the chunk as it lies in the file
/// (no copies on the way). The loops past the last polygon's (mesh_from keeps
/// them, unused) are left out.
fn readMesh(c: []const u8) ?u16 {
    const nv = rd32(c, 0);
    const np = rd32(c, 4);
    if (nv == 0 and np == 0) return scene.addEmptyMesh();
    if (@intFromPtr(c.ptr) & 3 != 0) return bee.readMesh(c);
    const vb = c[12..][0 .. @as(usize, nv) * 12];
    const pb = c[12 + vb.len ..][0 .. (@as(usize, np) + 1) * 4];
    const verts: []const m.V3 = @as([*]const m.V3, @ptrCast(@alignCast(vb.ptr)))[0..nv];
    const poff: []const u32 = @as([*]const u32, @ptrCast(@alignCast(pb.ptr)))[0 .. np + 1];
    const lb = c[12 + vb.len + pb.len ..];
    const loops: []const u32 = @as([*]const u32, @ptrCast(@alignCast(lb.ptr)))[0..poff[np]];
    return scene.addMesh(verts, poff, loops);
}

/// cell_load: its file's objects into the scene (an object whose id is there
/// already stays as it is); the cell is loaded.
fn load(c: *Cell) void {
    var extra = scan(c).n; // objects the scene has there already (crossed in, or kept)
    c.loaded = true;
    version +%= 1;
    defer {
        const s = scan(c);
        c.fp = if (extra != 0) s.fp ^ 1 else s.fp; // (its file no longer says it all: written when it goes)
        c.nobj = s.n;
        app.dirty = true;
    }
    if (!c.disk) return;
    var pb: [600]u8 = undefined;
    const p = cellPath(c, &pb) orelse return;
    const d = @import("ttf.zig").mapFile(p) orelse {
        c.disk = false;
        return;
    };
    defer _ = linux.munmap(@constCast(d.ptr), d.len);
    defer nload += 1;
    if (d.len < 16 or rd32(d, 0) != CELL_MAGIC or rd32(d, 4) != CELL_VER) return;
    var tabm: std.ArrayList(?u16) = .empty;
    defer tabm.deinit(A);
    var muvs: ?[]const u8 = null;
    var mvcl: ?[]const u8 = null;
    var celo: ?[]const u8 = null;
    var land: ?[]const u8 = null;
    var o: usize = 16;
    while (d.len - o >= 8) {
        const t = rd32(d, o);
        const sz = rd32(d, o + 4);
        if (sz > d.len - o - 8) break;
        const ch = d[o + 8 .. o + 8 + sz];
        o += 8 + sz;
        if (t == T_MESH) {
            if (tabm.items.len >= scene.max_objects) continue;
            if (!meshOk(ch)) break; // (a damaged file: what came so far)
            const mi = readMesh(ch) orelse break;
            tabm.append(A, mi) catch {
                scene.freeMeshSlot(mi);
                break;
            };
        } else if (t == T_MUVS) {
            muvs = ch;
        } else if (t == T_MVCL) {
            mvcl = ch;
        } else if (t == T_CELO) {
            celo = ch;
        } else if (t == T_LAND) {
            land = ch;
        } else if (t == T_VGEO) {
            const vg = @import("vgeo.zig");
            if (vg.readChunk(ch, tabm.items.len, d, p)) {
                const ix = rd32(ch, 0);
                if (ix < tabm.items.len) {
                    if (tabm.items[ix]) |mi| scene.meshes[mi].?.vg_had = true;
                }
            }
        }
    }
    if (muvs) |ch| _ = bee.readUvs(ch, tabm.items);
    if (mvcl) |ch| @import("vcol.zig").readChunk(ch, tabm.items);
    if (land) |ch| @import("landscape.zig").readChunk(ch, tabm.items);
    const used = A.alloc(bool, tabm.items.len) catch {
        for (tabm.items) |x| if (x) |mi| scene.freeMeshSlot(mi);
        return;
    };
    defer A.free(used);
    @memset(used, false);
    if (celo) |ch| if (ch.len >= 4) {
        var n = rd32(ch, 0);
        var r: usize = 4;
        while (n > 0 and ch.len - r >= CO_SZ) : ({
            r += CO_SZ;
            n -= 1;
        }) {
            const rec = ch[r..][0..CO_SZ];
            const uid = rd32(rec, 84);
            if (scene.findUid(uid) != null) { // (the scene's copy wins: changed)
                extra += 1;
                continue;
            }
            const mx = rd32(rec, 80);
            if (mx >= tabm.items.len or rd32(rec, 72) != 0) continue;
            const mi = tabm.items[mx] orelse continue;
            if (scene.count >= scene.max_objects) {
                full = true; // (the scene is full: this one stays in its file)
                continue;
            }
            var ob = scene.Object{ .kind = .mesh, .mesh = mi };
            const nm = std.mem.sliceTo(rec[0..31], 0);
            uniqueName(&ob, nm);
            var f: [9]f32 = undefined;
            for (0..9) |k| f[k] = @bitCast(rd32(rec, 32 + k * 4));
            for (0..3) |k| {
                ob.loc[k] = if (std.math.isFinite(f[k])) f[k] else 0;
                ob.scl[k] = if (std.math.isFinite(f[6 + k])) f[6 + k] else 1;
                if (!std.math.isFinite(f[3 + k])) f[3 + k] = 0;
            }
            ob.setRadians(.{ f[3], f[4], f[5] });
            ob.color = rd32(rec, 68) & 0xffffff;
            bee.applyFlags(&ob, rd32(rec, 76), 0);
            const idx = scene.count;
            scene.objects[idx] = ob;
            scene.stamp(idx); // (obj_new: an id of its own first)
            scene.count += 1;
            scene.objects[idx].uid = uid;
            if (uid >= scene.uid_next) scene.uid_next = uid +% 1;
            used[mx] = true;
            const mn = std.mem.sliceTo(rec[88..119], 0);
            if (mn.len > 0) {
                if (material.find(mn)) |k| scene.objects[idx].mat = @intCast(k + 1);
            }
            relink(idx);
        }
    };
    var by: u64 = 0;
    for (tabm.items, 0..) |x, k| {
        const mi = x orelse continue;
        by += meshBytes(&scene.meshes[mi].?);
        if (!used[k]) scene.freeMeshSlot(mi); // (drop_table_refs: the objects hold them)
    }
    c.bytes = by;
    loaded_bytes += by;
}

/// Children left behind when their parent's cell went (their OB_PARENT is its
/// uid, the original's): they follow it again.
fn relink(idx: usize) void {
    const uid = scene.objects[idx].uid;
    for (scene.objects[0..scene.count], 0..) |*x, k| {
        if (x.parent == null and x.parent_gone == uid and k != idx) _ = scene.setParent(k, idx);
    }
}

/// cell_dist: from the camera (x, z) to the cell's square.
fn dist(c: *const Cell) f32 {
    var x0 = @as(f32, @floatFromInt(c.ix)) * size;
    var x1 = x0 + size;
    x0 = minss(maxss(x0, eye[0]), x1);
    const dx = x0 - eye[0];
    var z0 = @as(f32, @floatFromInt(c.iz)) * size;
    x1 = z0 + size;
    z0 = minss(maxss(z0, eye[2]), x1);
    const dz = z0 - eye[2];
    return @sqrt(dx * dx + dz * dz);
}

/// eye_now: the viewport camera's eye (target - forward x distance).
fn eyeNow() void {
    const vp = @import("viewport.zig");
    const k = app.viewportArea();
    const v: vp.View = if (k >= 0) app.N(k).view else .{};
    const rad = v.radians();
    const yaw = sinCos(rad[0]);
    const pitch = sinCos(rad[1]);
    eye[0] = pitch[1] * yaw[0] * v.dist + v.target[0];
    eye[1] = pitch[0] * v.dist + v.target[1];
    eye[2] = pitch[1] * yaw[1] * v.dist + v.target[2];
}

/// wp_members: every partitioned object's cell gets a record, and a cell that
/// is not loaded but has one of the scene's objects standing in it comes in
/// (the object crossed a border). True: a cell with a file came in.
fn members() bool {
    var changed = false;
    var i: usize = 0;
    while (i < scene.count) : (i += 1) {
        if (!isPart(i)) continue;
        const xz = objCell(i);
        const c = find(xz[0], xz[1], true) orelse continue;
        if (c.loaded) continue;
        if (c.disk) {
            nmoved += 1;
            changed = true;
        }
        load(c);
    }
    return changed;
}

/// Streaming may not run now (transforming, editing, sculpting; a save).
fn held() bool {
    return saving or @import("xform.zig").active or @import("editmesh.zig").active or @import("sculpt.zig").on;
}

/// wp_tick: cells in reach come in, cells out of reach (or past the budget)
/// go out. all: everything now (world.update), else a pass of the window's
/// loop (two cells at most). True: something came in or went.
pub fn tick(all: bool) bool {
    if (!on or held()) return false;
    eyeNow();
    var changed = members();
    // out of reach (first): written when changed, out
    if (dir_len > 0) {
        const far = radius * 1.25;
        for (&tab) |*c| {
            if (!c.used or !c.loaded) continue;
            if (dist(c) > far) changed = unload(c) or changed;
        }
    }
    // in reach: nearest first, while the budget allows
    var n: u32 = 0;
    var waiting: u32 = 0;
    while (true) {
        var best: ?*Cell = null;
        var bd: f32 = BIG;
        waiting = 0;
        for (&tab) |*c| {
            if (!c.used or !c.disk or c.loaded) continue;
            const d = dist(c);
            if (d > radius) continue;
            if (loaded_bytes +% c.bytes > budget and loaded_bytes != 0) continue; // (fits, or nothing is in)
            waiting += 1;
            if (d >= bd) continue;
            bd = d;
            best = c;
        }
        const c = best orelse break;
        if (!all and n >= LOADS) break;
        load(c);
        changed = true;
        n += 1;
    }
    pending = waiting; // (waiting: the rate holds them back)
    // past the budget: the farthest out
    if (dir_len > 0) {
        while (loaded_bytes > budget) {
            var far: ?*Cell = null;
            var fd: f32 = 0;
            for (&tab) |*c| {
                if (!c.used or !c.loaded or c.bytes == 0) continue;
                const d = dist(c);
                if (!(d > 0)) continue; // (not the camera's own cell)
                if (!(d > fd)) continue;
                fd = d;
                far = c;
            }
            const c = far orelse break;
            if (!unload(c)) break;
            changed = true;
        }
    }
    if (changed) {
        restartHistory();
        app.dirty = true;
    }
    return changed;
}

/// undo_clear: steps from before would bring back what is now on disk.
fn restartHistory() void {
    const files = @import("files.zig");
    const was = files.changed();
    @import("undo.zig").restart();
    files.historyRestarted(was);
}

/// The window's loop: a pass. Milliseconds until it should look again (cells
/// waiting), or null.
pub fn frame() ?i32 {
    _ = tick(false);
    return if (on and pending > 0) 16 else null;
}

// --- saving and opening -------------------------------------------------------------------------

/// set_dir: <path without .bee>.cells
fn cellsDir(p: []const u8, buf: []u8) []const u8 {
    const q = p[0..@min(p.len, 500)];
    const base = if (std.mem.endsWith(u8, q, ".bee")) q[0 .. q.len - 4] else q;
    return std.fmt.bufPrint(buf, "{s}.cells", .{base}) catch "";
}

fn setDir(d: []const u8) void {
    dir_len = @min(d.len, dir_buf.len - 1);
    @memcpy(dir_buf[0..dir_len], d[0..dir_len]);
}

var kept: std.ArrayList(scene.Object) = .empty;
var kept_active: ?usize = null;
var kept_cam: ?usize = null;
var prepared = false;
var compacted = false;

/// wp_save_begin (bee.save): a partitioned world's cells move along when the
/// scene goes elsewhere, changed loaded cells are written, and (compact, after
/// the thumbnail) the partitioned objects are kept out of the scene's own file.
pub fn saveBegin(path: []const u8) void {
    if (!on or plain) return;
    var nb: [600]u8 = undefined;
    const nd = cellsDir(path, &nb);
    if (!std.mem.eql(u8, nd, dir())) {
        ensureDir(nd);
        if (dir_len > 0) {
            // cells on disk, not loaded: copied
            for (&tab) |*c| {
                if (!c.used or !c.disk or c.loaded) continue;
                var pb: [600]u8 = undefined;
                const p = cellPath(c, &pb) orelse continue;
                const d = @import("ttf.zig").mapFile(p) orelse continue;
                defer _ = linux.munmap(@constCast(d.ptr), d.len);
                var qb: [600]u8 = undefined;
                const q = std.fmt.bufPrintSentinel(&qb, "{s}/{d}_{d}.cell", .{ nd, c.ix, c.iz }, 0) catch continue;
                if (@import("files.zig").mayWrite(q)) _ = writeFile(q, d);
            }
        }
        setDir(nd);
        for (&tab) |*c| {
            if (c.used and c.loaded) c.disk = false; // (loaded cells: written below)
        }
    }
    _ = members();
    for (&tab) |*c| {
        if (!c.used or !c.loaded) continue;
        if (dirty(c)) _ = write(c);
    }
    prepared = true;
    saving = true;
}

/// The scene's own objects alone (bee.encode, after the thumbnail): the
/// partitioned ones are left out until saveEnd. A child whose parent is left
/// out keeps its world place and the parent's uid.
pub fn compact() void {
    if (!prepared) return;
    prepared = false;
    kept.clearRetainingCapacity();
    kept.appendSlice(A, scene.objects[0..scene.count]) catch return;
    kept_active = scene.active;
    kept_cam = scene.render_camera;
    const n = scene.count;
    const newix = A.alloc(?u16, n) catch return;
    defer A.free(newix);
    const places = A.alloc([9]f32, n) catch return;
    defer A.free(places);
    var k: usize = 0;
    for (0..n) |i| {
        places[i] = scene.worldPlace(i);
        newix[i] = if (isPart(i)) null else blk: {
            k += 1;
            break :blk @intCast(k - 1);
        };
    }
    var j: usize = 0;
    for (0..n) |i| {
        const ni = newix[i] orelse continue;
        var o = kept.items[i];
        if (o.parent) |p| {
            if (newix[p]) |np| {
                o.parent = np;
            } else {
                o.parent = null;
                o.parent_gone = kept.items[p].uid;
                o.loc = .{ places[i][0], places[i][1], places[i][2] };
                o.setRadians(.{ places[i][3], places[i][4], places[i][5] });
                o.scl = .{ places[i][6], places[i][7], places[i][8] };
                o.wp_ok = false;
            }
        }
        scene.objects[ni] = o;
        j += 1;
    }
    scene.count = j;
    compacted = true;
    scene.active = if (kept_active) |a| (if (a < n) (if (newix[a]) |x| @as(usize, x) else null) else null) else null;
    scene.render_camera = if (kept_cam) |a| (if (a < n) (if (newix[a]) |x| @as(usize, x) else null) else null) else null;
}

/// wp_save_end: the scene as it was.
pub fn saveEnd() void {
    prepared = false;
    saving = false;
    if (!compacted) return;
    compacted = false;
    @memcpy(scene.objects[0..kept.items.len], kept.items);
    scene.count = kept.items.len;
    scene.active = kept_active;
    scene.render_camera = kept_cam;
    kept.clearRetainingCapacity();
}

/// WRLP is written (bee.encode).
pub fn wanted() bool {
    return on and !plain;
}

/// wp_chunk_write: cell size, radius, budget, then the cells with a file (x, z,
/// objects, fingerprint, bytes, bounds, the fingerprint now and how many, padding).
pub fn chunkWrite(b: *bee.Buf) void {
    b.u32_(@bitCast(size));
    b.u32_(@bitCast(radius));
    b.u32_(@truncate(budget));
    b.u32_(@truncate(budget >> 32));
    var n: u32 = 0;
    for (&tab) |*c| {
        if (c.used and c.disk) n += 1;
    }
    b.u32_(n);
    for (&tab) |*c| {
        if (!c.used or !c.disk) continue;
        var r: [REC]u8 = @splat(0);
        std.mem.writeInt(i32, r[0..4], c.ix, .little);
        std.mem.writeInt(i32, r[4..8], c.iz, .little);
        std.mem.writeInt(u32, r[8..12], c.nobj, .little);
        std.mem.writeInt(u64, r[12..20], c.fp, .little);
        std.mem.writeInt(u64, r[20..28], c.bytes, .little);
        for (0..3) |k| {
            std.mem.writeInt(u32, r[28 + k * 4 ..][0..4], @bitCast(c.bmin[k]), .little);
            std.mem.writeInt(u32, r[40 + k * 4 ..][0..4], @bitCast(c.bmax[k]), .little);
        }
        std.mem.writeInt(u64, r[52..60], c.nfp, .little);
        std.mem.writeInt(u32, r[60..64], c.nnow, .little);
        b.bytes(&r);
    }
}

/// wp_chunk_read (bee.load, after the scene): a partitioned world, its cells on
/// disk beside the file, nothing loaded.
pub fn chunkRead(d: []const u8) void {
    if (d.len < 20) return;
    reset();
    size = @bitCast(rd32(d, 0));
    radius = @bitCast(rd32(d, 4));
    budget = std.mem.readInt(u64, d[8..16], .little);
    const n: u64 = rd32(d, 16);
    if (20 + n * REC > d.len) return;
    var nb: [600]u8 = undefined;
    setDir(cellsDir(lpath_buf[0..lpath_len], &nb));
    on = true;
    for (0..n) |k| {
        const r = d[20 + k * REC ..][0..REC];
        const c = find(@bitCast(rd32(r, 0)), @bitCast(rd32(r, 4)), true) orelse continue;
        c.nobj = rd32(r, 8);
        c.fp = std.mem.readInt(u64, r[12..20], .little);
        c.bytes = std.mem.readInt(u64, r[20..28], .little);
        for (0..3) |a| {
            c.bmin[a] = @bitCast(rd32(r, 28 + a * 4));
            c.bmax[a] = @bitCast(rd32(r, 40 + a * 4));
        }
        c.nfp = std.mem.readInt(u64, r[52..60], .little);
        c.nnow = rd32(r, 60);
        c.disk = true;
        c.loaded = false;
    }
    scanDir(); // (the files are the truth: cells written since the scene was saved)
    pending = 1;
    app.dirty = true;
}

/// get_int: a signed integer (wrapping, as the original's), and where it ends; null: no digits.
fn getInt(s: []const u8, at: *usize) ?i32 {
    var i = at.*;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    if (i >= s.len or s[i] -% '0' > 9) return null;
    var v: i32 = 0;
    while (i < s.len and s[i] -% '0' <= 9) : (i += 1) v = v *% 10 +% @as(i32, s[i] - '0');
    at.* = i;
    return if (neg) 0 -% v else v;
}

/// wp_scan_dir: the cells folder's <x>_<z>.cell files: a cell with a file is
/// on disk (known from the index or not), one without is not.
fn scanDir() void {
    for (&tab) |*c| c.disk = false;
    var pb: [520]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pb, "{s}", .{dir()}, 0) catch return;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const de: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            const nm = std.mem.span(@as([*:0]const u8, @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")])));
            off += de.reclen;
            var at: usize = 0;
            const x = getInt(nm, &at) orelse continue;
            if (at >= nm.len or nm[at] != '_') continue;
            at += 1;
            const z = getInt(nm, &at) orelse continue;
            if (!std.mem.eql(u8, nm[at..], ".cell")) continue;
            const c = find(x, z, true) orelse continue;
            c.disk = true;
            c.loaded = false;
        }
    }
}

// --- drawing: boxes for the cells not loaded, the minimap --------------------------------------------

const box_edges = [12][2]u8{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 }, .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 }, .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 } };

/// What the viewport shows of the cells (its cache key).
pub fn stateWord() u64 {
    if (!on) return 0;
    return @as(u64, version) | @as(u64, @intFromBool(minimap)) << 32 | @as(u64, @as(u32, @bitCast(eye[0]))) << 33 ^ @as(u64, @as(u32, @bitCast(eye[2])));
}

/// wp_draw (after the objects): the cells not loaded as boxes, the minimap in
/// the corner of r (pixels).
pub fn draw(cv: *gfx.Canvas, c: anytype, r: gfx.Rect, line: anytype) void {
    if (!on) return;
    for (&tab) |*cl| {
        if (!cl.used or !cl.disk or cl.loaded) continue;
        if (cl.bmin[0] > cl.bmax[0]) continue;
        for (box_edges) |e| {
            var a: m.V3 = undefined;
            var b: m.V3 = undefined;
            for (0..3) |k| {
                a[k] = if (e[0] >> @intCast(k) & 1 != 0) cl.bmax[k] else cl.bmin[k];
                b[k] = if (e[1] >> @intCast(k) & 1 != 0) cl.bmax[k] else cl.bmin[k];
            }
            line(cv, c, a, b, 0x555b66);
        }
    }
    if (!minimap) return;
    fps();
    // the cells' extent in a 168 px square, bottom right
    var x0: i32 = std.math.maxInt(i32);
    var z0: i32 = std.math.maxInt(i32);
    var x1: i32 = std.math.minInt(i32);
    var z1: i32 = std.math.minInt(i32);
    for (&tab) |*cl| {
        if (!cl.used or (!cl.disk and !cl.loaded)) continue;
        x0 = @min(x0, cl.ix);
        x1 = @max(x1, cl.ix);
        z0 = @min(z0, cl.iz);
        z1 = @max(z1, cl.iz);
    }
    if (x1 < x0) return; // no cells
    var side = x1 -% x0 +% 1;
    const sz = z1 -% z0 +% 1;
    if (side < sz) side = sz; // cells along the longer side
    var px: i32 = @bitCast(@as(u32, 160) / @as(u32, @bitCast(side)));
    if (px < 1) px = 1;
    if (px > 16) px = 16;
    const cx = r.x +% r.w -% 180;
    const cy = r.y +% r.h -% 180;
    cv.fill(.{ .x = cx - 4, .y = cy - 4, .w = 172, .h = 172 }, 0x1d2027);
    for (&tab) |*cl| {
        if (!cl.used) continue;
        var col: u32 = 0x4c525c; // on disk
        if (cl.loaded) {
            const ch = fpDirty(cl);
            col = if (ch) 0xe5a33b else 0x3e9b52; // changed, loaded
            if (!cl.disk and !ch) continue; // (empty and new: nothing to show)
        } else if (!cl.disk) continue;
        const w: i32 = if (px >= 3) px - 1 else px; // (a gap between cells)
        cv.fill(.{ .x = (cl.ix -% x0) *% px +% cx, .y = (cl.iz -% z0) *% px +% cy, .w = w, .h = w }, col);
    }
    // the camera and its radius
    const fpx: f32 = @floatFromInt(px);
    const ex = nt.cvtt((eye[0] / size - @as(f32, @floatFromInt(x0))) * fpx) +% cx;
    const ey = nt.cvtt((eye[2] / size - @as(f32, @floatFromInt(z0))) * fpx) +% cy;
    const rp = radius / size * fpx;
    const pt = struct {
        fn f(k: u32, rr: f32, ox: i32, oy: i32) [2]i32 {
            const sc = sinCos(@as(f32, @floatFromInt(k)) * 0.19634954); // 2 pi / 32
            return .{ nt.cvtt(sc[1] * rr) +% ox, nt.cvtt(sc[0] * rr) +% oy };
        }
    }.f;
    for (0..32) |k| {
        const a = pt(@intCast(k), rp, ex, ey);
        const b = pt(@intCast(k + 1), rp, ex, ey);
        cv.line(a[0], a[1], b[0], b[1], 0xd0d4dc);
    }
    cv.fill(.{ .x = ex -% 2, .y = ey -% 2, .w = 5, .h = 5 }, 0xffffff);
}

// --- operators, statistics ----------------------------------------------------------------------

/// wp_arg: the operator's number at this word (words split on spaces), or null.
fn argNum(arg: []const u8, which: usize) ?f32 {
    var it = std.mem.tokenizeScalar(u8, arg, ' ');
    var k: usize = 0;
    while (it.next()) |w| : (k += 1) {
        if (k == which) return nt.parseFloat(w, null);
    }
    return null;
}

/// world.partition <size> [radius] | off
pub fn opPartition(arg: []const u8) void {
    defer app.dirty = true;
    var it = std.mem.tokenizeScalar(u8, arg, ' ');
    const w = it.next() orelse return app.log("world.partition <cell size in m> [loading radius] | off", .{});
    if (w[0] == 'o') {
        if (!on) return;
        if (!allIn()) return;
        dropFiles();
        reset();
        app.log("World partition off: every cell loaded", .{});
        return;
    }
    const s = argNum(arg, 0) orelse return app.log("world.partition <cell size in m> [loading radius] | off", .{});
    if (!(s > 0)) return app.log("world.partition <cell size in m> [loading radius] | off", .{});
    const p = @import("files.zig").path() orelse return app.log("World partition: save the scene first (its cells are kept beside it)", .{});
    if (on) { // already split: everything in, files dropped, split again
        if (!allIn()) return;
        dropFiles();
    }
    reset();
    size = s;
    radius = s * 2.5;
    if (argNum(arg, 1)) |rr| radius = rr;
    var nb: [600]u8 = undefined;
    setDir(cellsDir(p, &nb));
    on = true;
    _ = members(); // (every object's cell, loaded)
    app.log("World partition: cells of {d} m, {d} cells", .{ nt.cvtt(size), ncell });
}

/// wp_all_in: every cell on disk loaded (the partition ends or changes).
/// False: the scene is full, objects are still in their files (the original
/// goes on and drops those files: the objects are lost); the partition stays.
fn allIn() bool {
    full = false;
    for (&tab) |*c| {
        if (c.used and c.disk and !c.loaded) load(c);
    }
    restartHistory();
    if (full) app.log("World partition: the scene is full ({d} objects): the cells not loaded stay in their files", .{scene.max_objects});
    return !full;
}

/// wp_drop_files: the cells' files removed (their objects are all loaded).
fn dropFiles() void {
    for (&tab) |*c| {
        if (!c.used or !c.disk) continue;
        var pb: [600]u8 = undefined;
        if (cellPath(c, &pb)) |p| _ = linux.unlink(p);
        c.disk = false;
    }
}

pub fn opRadius(arg: []const u8) void {
    const v = argNum(arg, 0) orelse return;
    radius = maxss(v, 1);
    pending = 1;
    version +%= 1;
    app.dirty = true;
}

pub fn opBudget(arg: []const u8) void {
    const v = maxss(argNum(arg, 0) orelse return, 1);
    // cvttss2si rax: out of range gives the minimum
    const q: i64 = if (v < 9.2233720e18) @intFromFloat(v) else std.math.minInt(i64);
    budget = @as(u64, @bitCast(q)) << 20;
    pending = 1;
    app.dirty = true;
}

pub fn opUpdate() void {
    _ = tick(true);
}

pub fn opMinimap() void {
    minimap = !minimap;
    version +%= 1;
    app.dirty = true;
}

/// wp_stat(k): 0 on, 1 cells, 2 loaded cells, 3 MB of loaded cells' meshes, 4
/// the budget (MB), 5 cells written, 6 cells loaded, 7 cells unloaded (all
/// three since the start), 8 loaded cells changed, 9 partitioned objects in
/// the scene, 10 cell size, 11 loading radius, 12 cells pulled in by objects
/// crossing into them, 13 cells waiting.
pub fn stat(k: i32) f32 {
    const mb: f32 = 9.5367432e-7;
    switch (k) {
        0 => return @floatFromInt(@intFromBool(on)),
        3 => return @as(f32, @floatFromInt(@as(i64, @bitCast(loaded_bytes)))) * mb,
        4 => return @as(f32, @floatFromInt(@as(i64, @bitCast(budget)))) * mb,
        5 => return @floatFromInt(nwrite),
        6 => return @floatFromInt(nload),
        7 => return @floatFromInt(nunload),
        12 => return @floatFromInt(nmoved),
        13 => return @floatFromInt(pending),
        10 => return size,
        11 => return radius,
        9 => {
            var n: u32 = 0;
            for (0..scene.count) |i| n += @intFromBool(isPart(i));
            return @floatFromInt(n);
        },
        else => {},
    }
    fps();
    var n: u32 = 0;
    for (&tab) |*c| {
        if (!c.used) continue;
        if (k == 1) {
            if (c.disk or c.loaded) n += 1;
        } else if (c.loaded) {
            if (k == 2 or (k == 8 and fpDirty(c))) n += 1;
        }
    }
    return @floatFromInt(n);
}

// --- the Render tab's panel (rnui.s) -----------------------------------------------------------------

var ui_size: f32 = 64;
var ui_radius: f32 = 160;
var ui_budget: f32 = 512;

fn runOp(id: []const u8, arg: []const u8) void {
    const ops = @import("ops.zig");
    const oi = ops.byId(id) orelse return;
    const old = ops.arg;
    const was = ops.scripted;
    ops.arg = arg;
    ops.scripted = true;
    ops.run(oi);
    ops.arg = old;
    ops.scripted = was;
}

/// world.partition <size> <radius> | off, from the panel's values (wp_cb)
fn partitionFromPanel(want_on: bool) void {
    var b: [64]u8 = undefined;
    const a = if (want_on) std.fmt.bufPrint(&b, "{d} {d}", .{ size, radius }) catch "" else "off";
    runOp("world.partition", a);
}

/// Below y; returns where it ends.
pub fn panel(salt: usize, bd: gfx.Rect, y0: i32) i32 {
    const ui = @import("ui.zig");
    var y = y0 + 8;
    const old = gfx.useFace(.head);
    _ = ui.cv.text(bd.x, y + 2, "World Partition", ui.th.accent_fg);
    _ = gfx.useFace(old);
    ui.record("heading", "World Partition", .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, true);
    y += 26;
    var want = on;
    if (ui.checkbox(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, "Partition the world", &want)) partitionFromPanel(want);
    y += 26;
    ui_size = size;
    if (ui.valueField(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, &ui_size, "Cell size (m)", .{ .step = 0.5, .lo = 1, .hi = 100000, .dec = 1 })) {
        size = std.math.clamp(ui_size, 1, 100000);
        partitionFromPanel(on);
    }
    y += 26;
    ui_radius = radius;
    if (ui.valueField(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, &ui_radius, "Loading radius (m)", .{ .step = 0.5, .lo = 1, .hi = 1000000, .dec = 1 })) {
        radius = std.math.clamp(ui_radius, 1, 1000000);
        partitionFromPanel(on);
    }
    y += 26;
    ui_budget = @floatFromInt(budget >> 20);
    if (ui.valueField(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, &ui_budget, "Memory (MB)", .{ .step = 1, .lo = 16, .hi = 1048576, .dec = 0 })) {
        var b: [24]u8 = undefined;
        runOp("world.budget", std.fmt.bufPrint(&b, "{d}", .{@as(u32, @intFromFloat(std.math.clamp(@round(ui_budget), 16, 1048576)))}) catch "");
    }
    y += 26;
    const half = @divTrunc(bd.w - 4, 2);
    var mm = minimap;
    if (ui.checkbox(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = half, .h = 22 }, "Minimap", &mm)) {
        if (mm != minimap) runOp("world.minimap", "");
    }
    if (ui.button(ui.id(@src(), salt), .{ .x = bd.x + bd.w - half, .y = y, .w = half, .h = 22 }, "Update Now", .{ .tip = "Load and unload the world's cells for the camera now (scripts; the window does it every frame)" })) {
        ui.active = 0;
        runOp("world.update", "");
    }
    return y + 26;
}

test "the cell table is the original's" {
    try std.testing.expectEqual(@as(u32, 0), hashOf(0, 0));
    // x * 0x9e3779b1 ^ z * 0x85ebca6b, ^ >> 15, & 16383
    var h: u32 = @as(u32, 6) *% 0x9e3779b1 ^ @as(u32, @bitCast(@as(i32, -11))) *% 0x85ebca6b;
    h ^= h >> 15;
    try std.testing.expectEqual(h & (CAP - 1), hashOf(6, -11));
    reset();
    const a = find(3, -4, true).?;
    try std.testing.expect(find(3, -4, false) == a);
    try std.testing.expect(find(4, -4, false) == null);
    reset();
}

test "cells under a point: floor, clamped" {
    size = 50;
    try std.testing.expectEqual([2]i32{ 0, -1 }, cellXZ(25, -0.5));
    try std.testing.expectEqual([2]i32{ -1, 0 }, cellXZ(-50, 49.9));
    const big = cellXZ(1e30, std.math.nan(f32));
    try std.testing.expectEqual(@as(i32, 100000000), big[0]);
    try std.testing.expectEqual(@as(i32, 100000000), big[1]);
    size = 64;
}

test "get_int and the cells folder's names" {
    var at: usize = 0;
    try std.testing.expectEqual(@as(?i32, -12), getInt("-12_3.cell", &at));
    try std.testing.expectEqual(@as(usize, 3), at);
    at = 0;
    try std.testing.expectEqual(@as(?i32, null), getInt("-_3.cell", &at));
}

test "a mesh's mapping is the original's mesh_new" {
    var v: [8]m.V3 = @splat(.{ 0, 0, 0 });
    var po = [_]u32{ 0, 4, 8, 12, 16, 20, 24 };
    var lo: [24]u32 = @splat(0);
    const me = scene.Mesh{ .verts = &v, .poff = &po, .loops = &lo, .tris = &.{}, .tri_poly = &.{}, .edges = 0 };
    try std.testing.expectEqual(@as(u64, 4096), meshBytes(&me));
}

test "cell distance: to the square, clamped" {
    size = 50;
    eye = .{ 25, 0, 25 };
    const c = Cell{ .ix = 0, .iz = 0, .used = true };
    try std.testing.expectEqual(@as(f32, 0), dist(&c));
    const d = Cell{ .ix = 2, .iz = 0, .used = true };
    try std.testing.expectEqual(@as(f32, 75), dist(&d));
    size = 64;
    eye = .{ 0, 0, 0 };
}
