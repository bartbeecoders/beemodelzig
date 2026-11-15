// Assets (asset.s): node trees and materials kept between scenes.
//
// tree.save_asset writes a geometry node tree - with every group it runs,
// nested - to ~/BeeModel/assets/<name>.beea; material.save_asset writes a
// material (its shader graph too; image nodes come back empty, images stay
// with their scenes). asset.load appends one to the scene (new names when
// taken; a tree's groups renumbered to the trees added), asset.list says what
// there is. The content library (library.zig) keeps the same records as its
// tree and material blobs.
//
// A file: "BEEA", version, kind (1 trees, 2 a material), count, then the
// records, byte for byte the scene's: 4 KiB trees (the first the one saved; a
// group's tree number is its place in the file + 1), or the 4 KiB material
// (version 2; version 1's 1 KiB records of v0.12 are read too).
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const ops = @import("ops.zig");
const nt = @import("ntree.zig");
const material = @import("material.zig");
const library = @import("library.zig");

pub const MAGIC: u32 = 0x41454542; // "BEEA"
const TR_SZ = nt.TR_SZ;
const T_GROUP = 26;
const T_IMAGE = 1;
const MAXT = 16;
const MAXF = 64;
const MA_V1SZ = 1024;

// --- the folder -------------------------------------------------------------------------

var dir_buf: [600]u8 = undefined;
var path_buf: [700]u8 = undefined;

/// ~/BeeModel/assets (made).
fn folder() []const u8 {
    const d = std.fmt.bufPrint(&dir_buf, "{s}/BeeModel/assets", .{library.home()}) catch return "";
    _ = @import("spawn.zig").ensureDir(d);
    return d;
}

/// "<folder>/<name>.beea" (the name: 60 bytes at most, no slashes).
fn file(name: []const u8) []const u8 {
    const d = folder();
    var n: usize = 0;
    @memcpy(path_buf[0..d.len], d);
    n = d.len;
    path_buf[n] = '/';
    n += 1;
    for (name[0..@min(name.len, 60)]) |c| {
        path_buf[n] = if (c == '/') '_' else c;
        n += 1;
    }
    @memcpy(path_buf[n..][0..5], ".beea");
    return path_buf[0 .. n + 5];
}

// --- blobs ---------------------------------------------------------------------------------

var buf: [16 + MAXT * TR_SZ]u8 align(16) = undefined;
var list: [MAXT]i32 = undefined;
var n_list: u32 = 0;

fn wr32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}
fn rd32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}

/// as_add_tree: its place in the list (added once), -1 when full.
fn addTree(t: i32) i32 {
    for (list[0..n_list], 0..) |x, k| {
        if (x == t) return @intCast(k);
    }
    if (n_list >= MAXT) return -1;
    list[n_list] = t;
    n_list += 1;
    return @intCast(n_list - 1);
}

/// cvttss2si: truncated toward zero, INT_MIN when it does not fit.
fn cvtt(f: f32) i32 {
    if (!(f > -2147483904.0 and f < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(f);
}

/// as_tree_blob: the tree and every group it runs (nested), group numbers made
/// places in the file + 1.
pub fn treeBlob(t: u32) []const u8 {
    n_list = 0;
    _ = addTree(@intCast(t));
    const ntrees: i32 = @intCast(nt.count());
    var k: u32 = 0;
    while (k < n_list) : (k += 1) {
        const r = nt.get(@intCast(list[k])) orelse continue;
        var i: u32 = 0;
        while (i < nt.nodes(r)) : (i += 1) {
            const at = nt.GR_NODES + i * nt.NODE_SZ;
            if (nt.rd32(r, at) != T_GROUP) continue;
            const g = cvtt(nt.rdf(r, at + nt.ND_P)) -% 1;
            if (g < 0 or g >= ntrees) continue;
            _ = addTree(g);
        }
    }
    wr32(&buf, 0, MAGIC);
    wr32(&buf, 4, 1);
    wr32(&buf, 8, 1);
    wr32(&buf, 12, n_list);
    // (a group node naming no tree, or one past the scene's: the original adds
    // it to the list here and copies a record that is not there - a crash;
    // here it becomes 0, no group)
    k = 0;
    while (k < n_list) : (k += 1) {
        const dst = buf[16 + k * TR_SZ ..][0..TR_SZ];
        dst.* = nt.get(@intCast(list[k])).?.*;
        var i: u32 = 0;
        while (i < @min(rd32(dst, nt.GR_N), nt.NT_MAXN)) : (i += 1) {
            const at = nt.GR_NODES + i * nt.NODE_SZ;
            if (rd32(dst, at) != T_GROUP) continue;
            const g = cvtt(@bitCast(rd32(dst, at + nt.ND_P))) -% 1;
            const p: i32 = if (g < 0 or g >= ntrees) -1 else addTree(g);
            wr32(dst, at + nt.ND_P, @bitCast(@as(f32, @floatFromInt(p + 1))));
        }
    }
    return buf[0 .. 16 + n_list * TR_SZ];
}

/// as_mat_blob: the record (its shader graph too; image nodes left empty).
pub fn matBlob(mi: usize) []const u8 {
    wr32(&buf, 0, MAGIC);
    wr32(&buf, 4, 2); // (version 2: 4 KiB material records)
    wr32(&buf, 8, 2);
    wr32(&buf, 12, 1);
    const rec = buf[16..][0..material.REC];
    rec.* = std.mem.asBytes(&material.list[mi]).*;
    var i: u32 = 0;
    while (i < rd32(rec, 128) and i < 48) : (i += 1) {
        const at = 160 + i * 72;
        if (rd32(rec, at) == T_IMAGE) wr32(rec, at + 52, 0);
    }
    return buf[0 .. 16 + material.REC];
}

pub const Loaded = struct { kind: u32, idx: u32 };

/// as_blob_load: what came in (1 node trees, 2 a material, 0 none: not one)
/// and the tree (the first) or the material.
pub fn blobLoad(d: []const u8) Loaded {
    defer app.dirty = true;
    if (d.len < 16 or rd32(d, 0) != MAGIC) return .{ .kind = 0, .idx = 0 };
    const cnt = rd32(d, 12);
    if (rd32(d, 8) == 2) {
        const size: usize = switch (rd32(d, 4)) {
            1 => MA_V1SZ - 32,
            2 => material.REC - 32,
            else => return .{ .kind = 0, .idx = 0 },
        };
        if (d.len < size + 16 + 32) return .{ .kind = 0, .idx = 0 };
        const nm = std.mem.sliceTo(d[16..][0..32], 0);
        const mi = material.new(nm[0..@min(nm.len, 26)]) orelse return .{ .kind = 0, .idx = 0 };
        const rec = std.mem.asBytes(&material.list[mi]);
        @memcpy(rec[32..][0..size], d[16 + 32 ..][0..size]);
        if (size == MA_V1SZ - 32) material.graphUpgrade(&material.list[mi].graph);
        _ = material.graphCheck(&material.list[mi].graph);
        material.version +%= 1;
        return .{ .kind = 2, .idx = @intCast(mi) };
    }
    if (rd32(d, 4) != 1 or rd32(d, 8) != 1) return .{ .kind = 0, .idx = 0 };
    if (cnt == 0 or cnt > MAXT or 16 + @as(usize, cnt) * TR_SZ > d.len) return .{ .kind = 0, .idx = 0 };
    var map: [MAXT]u32 = undefined;
    for (0..cnt) |k| {
        const src = d[16 + k * TR_SZ ..][0..TR_SZ];
        const nm = std.mem.sliceTo(src[0..32], 0);
        const t = nt.new(nm) orelse return .{ .kind = 0, .idx = 0 };
        map[k] = t;
        const r = nt.own(t).?;
        @memcpy(r[32..], src[32..]); // (its new name kept)
        if (nt.nodes(r) > nt.NT_MAXN) nt.wr32(r, nt.GR_N, 0);
    }
    for (0..cnt) |k| {
        const r = nt.own(map[k]).?;
        var i: u32 = 0;
        while (i < nt.nodes(r)) : (i += 1) {
            const at = nt.GR_NODES + i * nt.NODE_SZ;
            if (nt.rd32(r, at) != T_GROUP) continue;
            const g = cvtt(nt.rdf(r, at + nt.ND_P)) -% 1;
            const v: u32 = if (g >= 0 and g < cnt) map[@intCast(g)] + 1 else 0;
            nt.wrf(r, at + nt.ND_P, @floatFromInt(v));
        }
    }
    return .{ .kind = 1, .idx = map[0] };
}

// --- the operators ------------------------------------------------------------------------

fn firstWord(w: *nt.Words) ?[]const u8 {
    const s = w.next();
    return if (s.len == 0) null else s;
}

/// tree.save_asset <tree>
fn opSaveTree() void {
    var w = nt.Words{ .s = ops.arg };
    const word = firstWord(&w) orelse return app.log("  tree.save_asset <tree>", .{});
    const t = nt.find(word) orelse return app.log("  no node tree named: {s}", .{word});
    const b = treeBlob(t);
    const p = file(nt.name(nt.get(t).?));
    if (!library.mayWrite(p)) return app.log("  could not write the asset", .{});
    @import("bee.zig").writeAtomic(p, b) catch return app.log("  could not write the asset", .{});
    app.log("  asset saved: {s}", .{p});
}

/// material.save_asset <material>
fn opSaveMat() void {
    var w = nt.Words{ .s = ops.arg };
    const word = firstWord(&w) orelse return app.log("  material.save_asset <material>", .{});
    const mi = material.find(word) orelse return app.log("  no material named: {s}", .{word});
    const b = matBlob(mi);
    const p = file(material.list[mi].nameOf());
    if (!library.mayWrite(p)) return app.log("  could not write the asset", .{});
    @import("bee.zig").writeAtomic(p, b) catch return app.log("  could not write the asset", .{});
    app.log("  asset saved: {s}", .{p});
}

/// asset.load <name>
fn opLoad() void {
    var w = nt.Words{ .s = ops.arg };
    const word = firstWord(&w) orelse return app.log("  asset.load <name>", .{});
    const p = file(word);
    const d = @import("ttf.zig").mapFile(p) orelse return app.log("  no such asset (or not one): {s}", .{word});
    defer _ = linux.munmap(d.ptr, d.len);
    const got = blobLoad(d);
    switch (got.kind) {
        1 => app.log("  asset added: {s}", .{nt.name(nt.get(got.idx).?)}),
        2 => app.log("  asset added: {s}", .{material.list[got.idx].nameOf()}),
        else => app.log("  no such asset (or not one): {s}", .{word}),
    }
}

/// The folder's assets (names without ".beea"), sorted by name: ab_rescan.
pub fn scan(out: *[MAXF][64]u8, lens: *[MAXF]u8) usize {
    var n: usize = 0;
    const d = folder();
    var zb: [601]u8 = undefined;
    @memcpy(zb[0..d.len], d);
    zb[d.len] = 0;
    const fd0 = linux.open(@ptrCast(&zb), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(fd0) != .SUCCESS) return 0;
    const fd: i32 = @intCast(fd0);
    defer _ = linux.close(fd);
    var dents: [16384]u8 align(8) = undefined;
    while (true) {
        const r = linux.getdents64(fd, &dents, dents.len);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        var o: usize = 0;
        while (o < r) {
            const reclen = std.mem.readInt(u16, dents[o + 16 ..][0..2], .little);
            const nm = std.mem.sliceTo(dents[o + 19 .. o + reclen], 0);
            o += reclen;
            if (nm.len < 6 or nm.len > 60 or !std.mem.endsWith(u8, nm, ".beea")) continue;
            if (n >= MAXF) continue;
            const b = nm[0 .. nm.len - 5];
            @memcpy(out[n][0..b.len], b);
            lens[n] = @intCast(b.len);
            n += 1;
        }
    }
    // insertion sort by bytes (a few dozen at most)
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, out[j - 1][0..lens[j - 1]], out[j][0..lens[j]]) == .gt) : (j -= 1) {
            std.mem.swap([64]u8, &out[j - 1], &out[j]);
            std.mem.swap(u8, &lens[j - 1], &lens[j]);
        }
    }
    return n;
}

/// asset.list
fn opList() void {
    var names: [MAXF][64]u8 = undefined;
    var lens: [MAXF]u8 = undefined;
    const n = scan(&names, &lens);
    for (0..n) |k| app.log("  asset: {s}", .{names[k][0..lens[k]]});
}

const Impl = ops.Impl;
pub const list_ops = .{
    .{ "tree.save_asset", Impl{ .run = opSaveTree } },
    .{ "material.save_asset", Impl{ .run = opSaveMat } },
    .{ "asset.load", Impl{ .run = opLoad } },
    .{ "asset.list", Impl{ .run = opList } },
};

// --- tests ------------------------------------------------------------------------------------

test "assets: a tree with its groups, renumbered both ways; a material's images emptied" {
    nt.reset();
    defer nt.reset();
    material.reset();
    const a = nt.new("Main").?;
    const g1 = nt.new("G1").?;
    const g2 = nt.new("G2").?;
    _ = g1;
    const d: [13]f32 = @splat(0);
    // Main runs G2 (tree 3), G2 runs G1 (tree 2), and one group node names no tree
    const n1 = nt.add(a, T_GROUP, &d).?;
    _ = nt.set(a, @intCast(n1), 4, &.{3});
    const n2 = nt.add(g2, T_GROUP, &d).?;
    _ = nt.set(g2, @intCast(n2), 4, &.{2});
    _ = nt.add(a, T_GROUP, &d).?;
    const b = treeBlob(a);
    try std.testing.expectEqual(@as(usize, 16 + 3 * TR_SZ), b.len);
    try std.testing.expectEqual(@as(u32, 3), rd32(b, 12));
    // in the file: Main 1, G2 2, G1 3
    try std.testing.expectEqualStrings("G2", std.mem.sliceTo(b[16 + TR_SZ ..][0..32], 0));
    try std.testing.expectEqual(@as(f32, 2), @as(f32, @bitCast(rd32(b, 16 + nt.GR_NODES + nt.ND_P))));
    try std.testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(rd32(b, 16 + nt.GR_NODES + nt.NODE_SZ + nt.ND_P))));
    try std.testing.expectEqual(@as(f32, 3), @as(f32, @bitCast(rd32(b, 16 + TR_SZ + nt.GR_NODES + nt.ND_P))));
    var copy: [16 + 3 * TR_SZ]u8 = undefined;
    @memcpy(&copy, b);
    const got = blobLoad(&copy);
    try std.testing.expectEqual(@as(u32, 1), got.kind);
    try std.testing.expectEqual(@as(u32, 3), got.idx);
    try std.testing.expectEqualStrings("Main.001", nt.name(nt.get(3).?));
    // Main.001's group: G2.001 (tree 5) -> 6; G2.001's: G1.001 (tree 6) -> 7
    try std.testing.expectEqual(@as(f32, 5), nt.rdf(nt.get(3).?, nt.GR_NODES + nt.ND_P));
    try std.testing.expectEqual(@as(f32, 6), nt.rdf(nt.get(4).?, nt.GR_NODES + nt.ND_P));
    // damaged: short, a count past 16, a wrong kind
    try std.testing.expectEqual(@as(u32, 0), blobLoad(copy[0 .. 16 + TR_SZ]).kind);
    wr32(&copy, 12, 17);
    try std.testing.expectEqual(@as(u32, 0), blobLoad(&copy).kind);
    // a material
    const mi = material.new("Gold").?;
    material.list[mi].graph[0] = 1; // one node, an image node with an image
    wr32(&material.list[mi].graph, 32, T_IMAGE);
    wr32(&material.list[mi].graph, 32 + 52, 7);
    const mb = matBlob(mi);
    try std.testing.expectEqual(@as(usize, 16 + 4096), mb.len);
    try std.testing.expectEqual(@as(u32, 0), rd32(mb, 16 + 160 + 52));
    var mc: [16 + 4096]u8 = undefined;
    @memcpy(&mc, mb);
    const gm = blobLoad(&mc);
    try std.testing.expectEqual(@as(u32, 2), gm.kind);
    try std.testing.expectEqualStrings("Gold.001", material.list[gm.idx].nameOf());
    try std.testing.expectEqual(@as(u32, T_IMAGE), rd32(&material.list[gm.idx].graph, 32));
}
