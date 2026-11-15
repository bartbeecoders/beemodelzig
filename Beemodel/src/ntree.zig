// Node trees (ntree.s): the scene's node graphs - geometry node trees and,
// marked by TR_KIND, logic graphs (logic.zig).
//
// The trees live in one reference-counted block (like the force fields'):
// undo steps keep a reference to the block they saw, any change copies it
// first. A record is 4 KiB, byte for byte the original's (the NTRE chunk):
// name at 0, the kind at 124, the node count at 128, up to 48 nodes from 160,
// 72 bytes each: type, three inputs (a link - the feeding node + 1 with the
// output it takes in bits 16..23 - and a constant x y z), four values and the
// place in the node editor (two i16). A logic graph keeps 30 names of 16 bytes
// after the nodes; the node editor's flags (one byte a node) are at 3968, in
// the same bytes as names 23 to 30 (the original's layout, kept).
//
// Node numbers never change but on a delete (the later ones move one down, the
// links follow): evaluation pulls from the output, links that would loop are
// refused (nt_reaches).
const std = @import("std");
const app = @import("app.zig");
const A = @import("alloc.zig").A;

pub const TR_SZ = 4096;
pub const TR_MAX = 64;
pub const TR_KIND = 124;
pub const GR_N = 128;
pub const GR_NODES = 160;
pub const NODE_SZ = 72;
pub const ND_TYPE = 0;
pub const ND_IN = 4;
pub const ND_P = 52;
pub const ND_POS = 68;
pub const NT_MAXN = 48;
pub const NE_NFLAGS = 3968;

pub const Rec = [TR_SZ]u8;

pub const Block = struct {
    refs: u32 = 1,
    n: u32 = 0,
    r: []Rec = &.{},
};

/// The current block (null: no trees).
pub var cur: ?*Block = null;
/// Bumped by every change (nt_ver: modifier caches, the views).
pub var ver: u32 = 0;

fn unref(b: ?*Block) void {
    const x = b orelse return;
    x.refs -= 1;
    if (x.refs != 0) return;
    if (x.r.len > 0) A.free(x.r);
    A.destroy(x);
}

/// The undo steps: a snapshot holds a reference to the block it saw.
pub fn keep(slot: *?*Block) void {
    if (cur) |b| b.refs += 1;
    unref(slot.*);
    slot.* = cur;
}
pub fn restore(b: ?*Block) void {
    if (b) |x| x.refs += 1;
    if (b != cur) ver +%= 1;
    unref(cur);
    cur = b;
}
/// The trees the snapshot holds are the scene's (the same records).
pub fn same(b: ?*Block) bool {
    if (b == cur) return true;
    const x = b orelse return cur.?.n == 0;
    const y = cur orelse return x.n == 0;
    if (x.n != y.n) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(x.r[0..x.n]), std.mem.sliceAsBytes(y.r[0..y.n]));
}

// --- the fields of a record -------------------------------------------------------------

pub fn rd32(r: *const Rec, o: usize) u32 {
    return std.mem.readInt(u32, r[o..][0..4], .little);
}
pub fn wr32(r: *Rec, o: usize, v: u32) void {
    std.mem.writeInt(u32, r[o..][0..4], v, .little);
}
pub fn rdf(r: *const Rec, o: usize) f32 {
    return @bitCast(rd32(r, o));
}
pub fn wrf(r: *Rec, o: usize, v: f32) void {
    wr32(r, o, @bitCast(v));
}
/// The node count as the record has it.
pub fn nodes(r: *const Rec) u32 {
    return rd32(r, GR_N);
}
/// Node k's offset (1..48).
pub fn nodeAt(k: u32) usize {
    return GR_NODES + @as(usize, k - 1) * NODE_SZ;
}
/// The tree's name (up to its NUL).
pub fn name(r: *const Rec) []const u8 {
    return std.mem.sliceTo(r[0..32], 0);
}

// --- the block ----------------------------------------------------------------------------

/// nt_count
pub fn count() u32 {
    return if (cur) |b| b.n else 0;
}

/// nt_get: the record (read only), or null.
pub fn get(i: u32) ?*const Rec {
    const b = cur orelse return null;
    if (i >= b.n) return null;
    return &b.r[i];
}

/// nt_alloc: an empty block with room for cap records.
fn alloc(cap: u32) ?*Block {
    const b = A.create(Block) catch return null;
    const r = A.alloc(Rec, cap) catch {
        A.destroy(b);
        return null;
    };
    b.* = .{ .refs = 1, .n = 0, .r = r };
    return b;
}

/// nt_cow: cur, owned and with room for `room` more.
fn cow(room: u32) ?*Block {
    const old = cur;
    var n: u32 = 0;
    if (old) |b| {
        n = b.n;
        if (b.refs == 1 and n + room <= b.r.len) return b;
    }
    const nb = alloc(n + room + 2) orelse return null;
    if (old) |b| {
        nb.n = b.n;
        @memcpy(nb.r[0..b.n], b.r[0..b.n]);
    }
    cur = nb;
    unref(old);
    return nb;
}

/// nt_own: the record, writable (null if none); the change counts (nt_ver, a redraw).
pub fn own(i: u32) ?*Rec {
    if (i >= count()) return null;
    const b = cow(0) orelse return null;
    ver +%= 1;
    app.dirty = true;
    return &b.r[i];
}

/// nt_find: the tree with exactly this name.
pub fn find(nm: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < count()) : (i += 1) {
        if (std.mem.eql(u8, name(get(i).?), nm)) return i;
    }
    return null;
}

/// nt_new: a new empty tree with a unique name ("Geometry", or the name given cut to
/// 26 characters; .001 ... added); null when the scene holds 64.
pub fn new(nm0: ?[]const u8) ?u32 {
    if (count() >= TR_MAX) {
        app.log("  the scene holds 64 node trees", .{});
        return null;
    }
    const b = cow(1) orelse {
        app.log("  the scene holds 64 node trees", .{});
        return null;
    };
    const k = b.n;
    b.r[k] = @splat(0);
    b.n += 1;
    ver +%= 1;
    var base: []const u8 = if (nm0) |s| (if (s.len > 0) s else "Geometry") else "Geometry";
    if (std.mem.indexOfScalar(u8, base, 0)) |z| base = base[0..z];
    base = base[0..@min(base.len, 26)];
    var suffix: u32 = 0;
    while (true) : (suffix += 1) {
        const r = &b.r[k];
        @memset(r[0..32], 0);
        @memcpy(r[0..base.len], base);
        if (suffix != 0) {
            r[base.len] = '.';
            r[base.len + 1] = @truncate('0' + suffix / 100);
            r[base.len + 2] = @truncate('0' + (suffix % 100) / 10);
            r[base.len + 3] = @truncate('0' + suffix % 10);
        }
        var taken = false;
        for (b.r[0..b.n], 0..) |*o, j| {
            if (j != k and std.mem.eql(u8, name(o), name(r))) taken = true;
        }
        if (!taken) return k;
    }
}

/// nt_reset: no trees (a new scene).
pub fn reset() void {
    const old = cur;
    cur = null;
    ver +%= 1;
    unref(old);
}

// --- nodes ----------------------------------------------------------------------------------

/// nt_add: a node of this type with its defaults (4 values, then the 3 inputs'
/// x y z): its number (1..48), or null.
pub fn add(t: u32, typ: u32, d: *const [13]f32) ?u32 {
    const r = own(t) orelse return null;
    const n = nodes(r);
    if (n >= NT_MAXN) return null;
    const o = GR_NODES + @as(usize, n) * NODE_SZ;
    @memset(r[o..][0..NODE_SZ], 0);
    wr32(r, o + ND_TYPE, typ);
    for (0..4) |k| wrf(r, o + ND_P + k * 4, d[k]);
    for (0..3) |i| {
        for (0..3) |c| wrf(r, o + ND_IN + i * 16 + 4 + c * 4, d[4 + i * 3 + c]);
    }
    wr32(r, GR_N, n + 1);
    return n + 1;
}

/// nt_reaches: does `target` feed `node` (through any inputs)?
fn reaches(r: *const Rec, node: u32, target: u32) bool {
    var seen: [64]bool = @splat(false);
    var stack: [NT_MAXN]u32 = undefined;
    stack[0] = node;
    var sp: usize = 1;
    const n = nodes(r);
    while (sp > 0) {
        sp -= 1;
        const k = stack[sp];
        if (k == target) return true;
        if (k > n) continue;
        if (seen[k]) continue;
        seen[k] = true;
        if (k == 0) continue; // (not reached: links of 0 are never pushed)
        const o = nodeAt(k) + ND_IN;
        for (0..3) |i| {
            const w: u32 = rd32(r, o + i * 16) & 0xffff;
            if (w == 0 or sp >= NT_MAXN) continue;
            stack[sp] = w;
            sp += 1;
        }
    }
    return false;
}

/// nt_link: `from`'s output feeds input 1..3 of `to`: the node fed, or 0 (no
/// such nodes, or a loop - nothing changed but the copy).
pub fn link(t: u32, from: i32, to: i32, input: i32, output: i32) u32 {
    const r = own(t) orelse return 0;
    const n: i32 = @intCast(@min(nodes(r), 0x7fffffff));
    if (from <= 0 or to <= 0 or from == to) return 0;
    if (from > n or to > n) return 0;
    if (input < 1 or input > 3) return 0;
    if (output < 0 or output > 255) return 0;
    const f: u32 = @intCast(from);
    const tt: u32 = @intCast(to);
    if (reaches(r, f, tt)) return 0;
    wr32(r, nodeAt(tt) + ND_IN + @as(usize, @intCast(input - 1)) * 16, (@as(u32, @intCast(output)) << 16) | f);
    return tt;
}

/// nt_set: slot 1..3 an input's constant (unlinked: x, or x y z with three), 4..7 a value.
pub fn set(t: u32, node: i32, slot: i32, v: []const f32) bool {
    const r = own(t) orelse return false;
    if (node <= 0 or node > @as(i64, nodes(r))) return false;
    const o = nodeAt(@intCast(node));
    if (slot >= 1 and slot <= 3) {
        const p = o + ND_IN + @as(usize, @intCast(slot - 1)) * 16;
        wr32(r, p, 0);
        for (0..3) |c| wrf(r, p + 4 + c * 4, v[0]);
        if (v.len >= 3) {
            wrf(r, p + 8, v[1]);
            wrf(r, p + 12, v[2]);
        }
        return true;
    }
    if (slot >= 4 and slot <= 7) {
        wrf(r, o + ND_P + @as(usize, @intCast(slot - 4)) * 4, v[0]);
        return true;
    }
    return false;
}

/// nt_delete: the node goes, links to it unplugged, the later ones one down.
pub fn delete(t: u32, node: i32) bool {
    const r = own(t) orelse return false;
    const n = nodes(r);
    if (node <= 0 or node > @as(i64, n)) return false;
    const k: u32 = @intCast(node);
    const at = nodeAt(k);
    std.mem.copyForwards(u8, r[at .. at + (n - k) * NODE_SZ], r[at + NODE_SZ .. at + NODE_SZ + (n - k) * NODE_SZ]);
    const fl = NE_NFLAGS + k - 1;
    std.mem.copyForwards(u8, r[fl .. fl + (n - k)], r[fl + 1 .. fl + 1 + (n - k)]);
    r[NE_NFLAGS + n - 1] = 0;
    wr32(r, GR_N, n - 1);
    @memset(r[GR_NODES + (n - 1) * NODE_SZ ..][0..NODE_SZ], 0);
    var j: u32 = 0;
    while (j < n - 1) : (j += 1) {
        const o = GR_NODES + j * NODE_SZ + ND_IN;
        for (0..3) |i| {
            const p = o + i * 16;
            const w = std.mem.readInt(u16, r[p..][0..2], .little);
            if (w < k) continue;
            if (w == k) wr32(r, p, 0) else std.mem.writeInt(u16, r[p..][0..2], w - 1, .little);
        }
    }
    return true;
}

/// nt_place: where the node editor shows it (0, 0 is kept as 0, 1).
pub fn place(t: u32, node: i32, x: i32, y0: i32) bool {
    const r = own(t) orelse return false;
    var y = y0;
    if (@as(u16, @truncate(@as(u32, @bitCast(x)))) == 0 and @as(u16, @truncate(@as(u32, @bitCast(y)))) == 0) y = 1;
    if (node <= 0 or node > @as(i64, nodes(r))) return false;
    const o = nodeAt(@intCast(node)) + ND_POS;
    std.mem.writeInt(u16, r[o..][0..2], @truncate(@as(u32, @bitCast(x))), .little);
    std.mem.writeInt(u16, r[o + 2 ..][0..2], @truncate(@as(u32, @bitCast(y))), .little);
    return true;
}

/// nt_info: what 0 the node count, 1 its type, 2 the node feeding input k (1..3),
/// 3 the output that link takes, 4 x, 5 y; -1 none. (6: value k, see value())
pub fn info(t: u32, node: i32, what: u32, k: i32) i32 {
    const r = get(t) orelse return -1;
    const n = nodes(r);
    if (what == 0) return @bitCast(n);
    if (node <= 0 or node > @as(i64, n)) return -1;
    const o = nodeAt(@intCast(node));
    if (what == 1) return @bitCast(rd32(r, o + ND_TYPE));
    if (what == 2 or what == 3) {
        if (k < 1 or k > 3) return -1;
        const w = rd32(r, o + ND_IN + @as(usize, @intCast(k - 1)) * 16);
        return if (what == 2) @intCast(w & 0xffff) else @intCast((w >> 16) & 0xff);
    }
    if (what == 4) return std.mem.readInt(i16, r[o + ND_POS ..][0..2], .little);
    if (what == 5) return std.mem.readInt(i16, r[o + ND_POS + 2 ..][0..2], .little);
    return -1;
}

/// nt_info 6: value k (1..4).
pub fn value(t: u32, node: i32, k: i32) ?f32 {
    const r = get(t) orelse return null;
    if (node <= 0 or node > @as(i64, nodes(r))) return null;
    if (k < 1 or k > 4) return null;
    return rdf(r, nodeAt(@intCast(node)) + ND_P + @as(usize, @intCast(k - 1)) * 4);
}

/// nt_clear: no nodes (the names after them go too).
pub fn clear(t: u32) bool {
    const r = own(t) orelse return false;
    @memset(r[GR_N..], 0);
    return true;
}

// --- files: NTRE (the count, then each 4 KiB record) ----------------------------------------

pub fn write(out: anytype) void {
    const n = count();
    out.u32_(n);
    var i: u32 = 0;
    while (i < n) : (i += 1) out.bytes(get(i).?);
}

/// nt_read: the trees (a count past 64 is 64; fewer bytes than it says: none;
/// a node count past 48: no nodes).
pub fn read(c: []const u8) void {
    reset();
    defer ver +%= 1;
    if (c.len < 4) return;
    const k: u32 = @min(std.mem.readInt(u32, c[0..4], .little), TR_MAX);
    if (@as(usize, k) * TR_SZ + 4 > c.len) return;
    const b = alloc(k + 2) orelse return;
    b.n = k;
    @memcpy(std.mem.sliceAsBytes(b.r[0..k]), c[4..][0 .. @as(usize, k) * TR_SZ]);
    for (b.r[0..k]) |*r| {
        r[31] = 0;
        if (nodes(r) > NT_MAXN) wr32(r, GR_N, 0);
    }
    cur = b;
}

// --- the operators: tree.new, tree.link, tree.node_set, tree.node_delete, tree.node_move -----

/// im_next_word: words split at spaces only, each at most 255 bytes.
pub const Words = struct {
    s: []const u8,
    i: usize = 0,
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn next(w: *Words) []const u8 {
        w.len = 0;
        while (w.i < w.s.len and w.s[w.i] == ' ') w.i += 1;
        while (w.i < w.s.len and w.s[w.i] != ' ' and w.s[w.i] != 0) : (w.i += 1) {
            if (w.len < 255) {
                w.buf[w.len] = w.s[w.i];
                w.len += 1;
            }
        }
        return w.buf[0..w.len];
    }
    /// The rest after the words taken.
    pub fn rest(w: *const Words) []const u8 {
        return w.s[w.i..];
    }
    /// gn_arg_num: the next word as a number (parse_float: its leading number).
    pub fn num(w: *Words) ?f32 {
        const s = w.next();
        if (s.len == 0) return null;
        return parseFloat(s, null);
    }
};

/// parse_float: "-1.5e3" style; null when no digits. `end`: where it stopped.
pub fn parseFloat(s: []const u8, end: ?*usize) ?f32 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == 9)) i += 1;
    var v: f64 = 0;
    var neg = false;
    var digits: u32 = 0;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    } else if (i < s.len and s[i] == '+') i += 1;
    while (i < s.len and s[i] -% '0' <= 9) : (i += 1) {
        v = v * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
        digits += 1;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        var u: f64 = 1;
        while (i < s.len and s[i] -% '0' <= 9) : (i += 1) {
            u /= 10.0;
            v += @as(f64, @floatFromInt(s[i] - '0')) * u;
            digits += 1;
        }
    }
    if (i < s.len and s[i] | 0x20 == 'e') {
        i += 1;
        var eneg = false;
        if (i < s.len and s[i] == '-') {
            eneg = true;
            i += 1;
        } else if (i < s.len and s[i] == '+') i += 1;
        var e: u32 = 0;
        while (i < s.len and s[i] -% '0' <= 9) : (i += 1) e = e *% 10 +% (s[i] - '0');
        if (e > 38) e = 38;
        while (e > 0) : (e -= 1) v = if (eneg) v / 10.0 else v * 10.0;
    }
    if (neg) v = 0.0 - v;
    if (end) |e| e.* = i;
    return if (digits > 0) @floatCast(v) else null;
}

/// cvttss2si: out of range or NaN gives the minimum.
pub fn cvtt(x: f32) i32 {
    if (x >= -2147483648.0 and x < 2147483648.0) return @intFromFloat(x);
    return std.math.minInt(i32);
}

/// gn_arg_tree: the tree named by the next word (said when there is none).
pub fn argTree(w: *Words) ?u32 {
    const s = w.next();
    if (s.len > 0) {
        if (find(s)) |t| return t;
    }
    app.log("  no node tree named: {s}", .{s});
    return null;
}

/// The tree the op was given, the scene's trees as they were when it failed
/// (undo_drop_last: a failed operator leaves no step).
var before: ?*Block = null;
pub fn begin() void {
    before = null;
    keep(&before);
}
pub fn fail() void {
    restore(before);
    unref(before);
    before = null;
}
pub fn done() void {
    unref(before);
    before = null;
}

const ops = @import("ops.zig");

pub fn sayNode(k: u32) void {
    app.log("  node {d}", .{k});
}

/// tree.new [name]
fn opNew() void {
    var w = Words{ .s = ops.arg };
    const s = w.next();
    const t = new(if (s.len > 0) s else null) orelse return;
    app.log("  node tree: {s}", .{name(get(t).?)});
}

/// tree.link <tree> <from[:output]> <to> <input>
fn opLink() void {
    begin();
    var w = Words{ .s = ops.arg };
    const t = argTree(&w) orelse return fail();
    const need = "  tree.link <tree> <from[:output]> <to> <input 1-3> (no loops)";
    const fw = w.next();
    if (fw.len == 0) return needed(need);
    var e: usize = 0;
    const from = parseFloat(fw, &e) orelse return needed(need);
    var out: f32 = 0;
    if (e < fw.len and fw[e] == ':') out = parseFloat(fw[e + 1 ..], null) orelse 0;
    const to = w.num() orelse return needed(need);
    const input = w.num() orelse return needed(need);
    const k = link(t, cvtt(from), cvtt(to), cvtt(input), cvtt(out));
    if (k == 0) return needed(need);
    done();
    sayNode(k);
}

pub fn needed(s: []const u8) void {
    app.log("{s}", .{s});
    fail();
}

/// tree.node_set <tree> <node> <slot> <x> [y z]
fn opSet() void {
    begin();
    var w = Words{ .s = ops.arg };
    const t = argTree(&w) orelse return fail();
    const need = "  tree.node_set <tree> <node> <slot> <x> [y z]";
    const node = w.num() orelse return needed(need);
    const slot = w.num() orelse return needed(need);
    var v: [3]f32 = undefined;
    var n: usize = 0;
    while (n < 3) : (n += 1) v[n] = w.num() orelse break;
    if (n == 0) return needed(need);
    if (!set(t, cvtt(node), cvtt(slot), v[0..n])) return needed(need);
    done();
}

/// tree.node_delete <tree> <node>
fn opDelete() void {
    begin();
    var w = Words{ .s = ops.arg };
    const t = argTree(&w) orelse return fail();
    const need = "  tree.node_delete <tree> <node>";
    const node = w.num() orelse return needed(need);
    if (!delete(t, cvtt(node))) return needed(need);
    done();
}

/// tree.node_move <tree> <node> <x> <y>
fn opMove() void {
    begin();
    var w = Words{ .s = ops.arg };
    const t = argTree(&w) orelse return fail();
    const need = "  tree.node_move <tree> <node> <x> <y>";
    const node = w.num() orelse return needed(need);
    const x = w.num() orelse return needed(need);
    const y = w.num() orelse return needed(need);
    if (!place(t, cvtt(node), cvtt(x), cvtt(y))) return needed(need);
    done();
}

const Impl = ops.Impl;
pub const list = .{
    .{ "tree.new", Impl{ .run = opNew } },
    .{ "tree.link", Impl{ .run = opLink } },
    .{ "tree.node_set", Impl{ .run = opSet } },
    .{ "tree.node_delete", Impl{ .run = opDelete } },
    .{ "tree.node_move", Impl{ .run = opMove } },
};

// --- tests ------------------------------------------------------------------------------------

test "trees: names, nodes, links, loops, delete, the chunk" {
    reset();
    defer reset();
    const t0 = new(null).?;
    const t1 = new(null).?;
    try std.testing.expectEqualStrings("Geometry", name(get(t0).?));
    try std.testing.expectEqualStrings("Geometry.001", name(get(t1).?));
    try std.testing.expectEqual(@as(?u32, 1), find("Geometry.001"));
    const d: [13]f32 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
    try std.testing.expectEqual(@as(?u32, 1), add(t0, 3, &d));
    try std.testing.expectEqual(@as(?u32, 2), add(t0, 4, &d));
    try std.testing.expectEqual(@as(?u32, 3), add(t0, 5, &d));
    try std.testing.expectEqual(@as(i32, 3), info(t0, 0, 0, 0));
    try std.testing.expectEqual(@as(f32, 3), value(t0, 2, 3).?);
    try std.testing.expectEqual(@as(u32, 2), link(t0, 1, 2, 1, 0));
    try std.testing.expectEqual(@as(u32, 3), link(t0, 2, 3, 2, 1));
    // 3 -> 1 would loop: refused
    try std.testing.expectEqual(@as(u32, 0), link(t0, 3, 1, 1, 0));
    try std.testing.expectEqual(@as(u32, 0), link(t0, 1, 1, 1, 0));
    try std.testing.expectEqual(@as(i32, 2), info(t0, 3, 2, 2));
    try std.testing.expectEqual(@as(i32, 1), info(t0, 3, 3, 2));
    // a held snapshot keeps its records
    var snap: ?*Block = null;
    keep(&snap);
    try std.testing.expect(set(t0, 2, 1, &.{ 7, 8, 9 }));
    try std.testing.expect(snap != cur);
    try std.testing.expect(!same(snap));
    try std.testing.expectEqual(@as(i32, 2), info(t0, 3, 2, 2));
    try std.testing.expect(delete(t0, 2));
    try std.testing.expectEqual(@as(i32, 2), info(t0, 0, 0, 0));
    try std.testing.expectEqual(@as(i32, 0), info(t0, 2, 2, 2)); // (its feeder went)
    try std.testing.expectEqual(@as(i32, 5), info(t0, 2, 1, 0)); // (3 is 2 now)
    try std.testing.expect(place(t0, 1, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), info(t0, 1, 5, 0));
    // the chunk both ways
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const W = struct {
        l: *std.ArrayList(u8),
        fn u32_(s: @This(), v: u32) void {
            var b4: [4]u8 = undefined;
            std.mem.writeInt(u32, &b4, v, .little);
            s.l.appendSlice(std.testing.allocator, &b4) catch {};
        }
        fn bytes(s: @This(), x: []const u8) void {
            s.l.appendSlice(std.testing.allocator, x) catch {};
        }
    };
    write(W{ .l = &buf });
    try std.testing.expectEqual(@as(usize, 4 + 2 * TR_SZ), buf.items.len);
    const was = cur.?.r[0];
    read(buf.items);
    try std.testing.expectEqual(@as(u32, 2), count());
    try std.testing.expect(std.mem.eql(u8, &was, &cur.?.r[0]));
    // damaged: short, or a node count past 48
    read(buf.items[0..100]);
    try std.testing.expectEqual(@as(u32, 0), count());
    std.mem.writeInt(u32, buf.items[4 + GR_N ..][0..4], 9999, .little);
    read(buf.items);
    try std.testing.expectEqual(@as(i32, 0), info(0, 0, 0, 0));
    restore(snap);
    unref(snap);
    try std.testing.expectEqual(@as(i32, 3), info(t0, 0, 0, 0));
}

test "trees: 64 at most, names cut to 26" {
    reset();
    defer reset();
    var i: u32 = 0;
    while (i < TR_MAX) : (i += 1) _ = new("abcdefghijklmnopqrstuvwxyz0123").?;
    try std.testing.expectEqual(@as(?u32, null), new(null));
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz.063", name(get(63).?));
}
