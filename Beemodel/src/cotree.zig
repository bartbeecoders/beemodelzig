// Co-editing node graphs (cotree.s, with cosync.zig).
//
// Every node tree (geometry, logic) is an element of a set keyed by its name;
// its nodes are a sequence (RGA) of node elements with stable ids: added after
// the node before them when made (newer first at one place), removed by a later
// delete time. A node's content - type, values, input constants, place, and its
// links as the ids of the nodes they come from - is one register (last writer
// wins); the tree's kind and its names table (logic graphs) another.
//
// The scene's trees are compared with what was last built: nodes matched in
// order by their content without links (a node missing in the middle: deleted;
// extra at the end: added; else changed), then each node's content with its
// links as ids. Remote changes mark the tree; it is built again (alive nodes in
// sequence order, links mapped back to node numbers) after a tick's operations.
//
// Messages (after cosync's header): 48 TREE (name, its add time, kind), 49 TAIL
// (name, time, kind, the 480-byte names table), 50 NADD (tree, id, time,
// after), 51 NDEL (tree, id, time), 52 NSET (tree, id, time, the node's 72
// bytes with links cleared, 3 link ids, 3 outputs).
const std = @import("std");
const co = @import("cosync.zig");
const nt = @import("ntree.zig");
const app = @import("app.zig");

const GR_N = nt.GR_N;
const GR_NODES = nt.GR_NODES;
const NODE_SZ = nt.NODE_SZ;
const ND_IN = nt.ND_IN;
const NT_MAXN = nt.NT_MAXN;
const TR_KIND = nt.TR_KIND;
const TR_SZ = nt.TR_SZ;
const TAIL_AT = GR_NODES + NT_MAXN * NODE_SZ;
const TAIL_SZ = TR_SZ - TAIL_AT;
const CT_MAX = 64;
const CN_MAX = 4096;
const CONTENT = NODE_SZ + 24 + 3; // a node's register: 72 bytes, 3 ids, 3 outputs
// the original's tree element: its first 736 bytes go into an undo record
const CT_KIND = 40;
const CT_TAIL = 256;
const U_TAIL_BYTES = CT_TAIL + TAIL_SZ;

pub const M_TREE: u8 = 48;
pub const M_TAIL: u8 = 49;
pub const M_NADD: u8 = 50;
pub const M_NDEL: u8 = 51;
pub const M_NSET: u8 = 52;
const U_NADD: u32 = 20;
const U_NDEL: u32 = 21;
const U_NSET: u32 = 22;
const U_TAIL: u32 = 23;

const Tree = struct {
    name: [32]u8 = @splat(0),
    add: u64 = 0,
    kind: u32 = 0,
    tail_ts: u64 = 0,
    dirty: bool = false,
    nsl: u32 = 0, // slots as last built
    slot: [NT_MAXN]u32 = @splat(0), // node element per slot
    tail: [TAIL_SZ]u8 = @splat(0), // the names table
    copy: [TR_SZ]u8 = @splat(0), // the record as last built
};
const Node = struct {
    tree: u32 = 0,
    id: u64 = 0,
    after: u64 = 0,
    add: u64 = 0,
    del: u64 = 0,
    ts: u64 = 0,
    data: [CONTENT]u8 = @splat(0),
    fn alive(n: *const Node) bool {
        return n.add > n.del;
    }
};

var tab: [CT_MAX]Tree = undefined;
var nct: usize = 0;
var cn: [CN_MAX]Node = undefined;
var ncn: usize = 0;
var rec: [TR_SZ]u8 = undefined; // a record being built
var ord: [NT_MAXN]u32 = undefined;
var nord: usize = 0;
var map: [NT_MAXN]u32 = @splat(0); // new slot -> node element (capture)
var tmp: [CONTENT]u8 = undefined;

fn rd32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .little);
}
fn rd64(d: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, d[o..][0..8], .little);
}
fn wr32(d: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, d[o..][0..4], v, .little);
}
fn cstr(b: []const u8) []const u8 {
    return std.mem.sliceTo(b, 0);
}

/// ct_reset: no trees in the document.
pub fn reset() void {
    nct = 0;
    ncn = 0;
}

fn find(name: []const u8) ?*Tree {
    const n = cstr(name);
    for (tab[0..nct]) |*t| if (std.mem.eql(u8, cstr(&t.name), n)) return t;
    return null;
}
fn make(name: []const u8) ?*Tree {
    if (nct >= CT_MAX) return null;
    tab[nct] = .{};
    const n = @min(name.len, 31);
    @memcpy(tab[nct].name[0..n], name[0..n]);
    nct += 1;
    return &tab[nct - 1];
}
fn index(t: *const Tree) u32 {
    return @intCast((@intFromPtr(t) - @intFromPtr(&tab[0])) / @sizeOf(Tree));
}
fn cnFind(id: u64) ?*Node {
    for (cn[0..ncn]) |*n| if (n.id == id) return n;
    return null;
}
fn cnMake(id: u64, tree: u32) ?*Node {
    if (ncn >= CN_MAX) return null;
    cn[ncn] = .{ .id = id, .tree = tree };
    ncn += 1;
    return &cn[ncn - 1];
}
fn cnIndex(n: *const Node) u32 {
    return @intCast((@intFromPtr(n) - @intFromPtr(&cn[0])) / @sizeOf(Node));
}

/// ct_order: a tree's alive nodes in sequence order (into ord, nord).
fn order(tree: u32) void {
    nord = 0;
    visit(tree, 0, 0);
}
/// cn_visit: children newest first, each then its own (a loop is not followed).
fn visit(tree: u32, parent: u64, depth: u32) void {
    if (depth > CN_MAX) return;
    var last: u64 = std.math.maxInt(u64);
    while (true) {
        var best: u64 = 0;
        var bi: ?usize = null;
        for (cn[0..ncn], 0..) |*n, i| {
            if (n.tree != tree or n.after != parent) continue;
            if (n.id >= last or n.id <= best) continue;
            best = n.id;
            bi = i;
        }
        const i = bi orelse return;
        last = best;
        if (cn[i].alive() and nord < NT_MAXN) {
            ord[nord] = @intCast(i);
            nord += 1;
        }
        if (best == parent) continue; // (a node after itself)
        visit(tree, best, depth + 1);
    }
}

/// node_eq_nl: alike but for the three link dwords.
fn eqNoLinks(a: []const u8, b: []const u8) bool {
    var k: usize = 0;
    while (k < NODE_SZ) : (k += 4) {
        if (k == ND_IN or k == ND_IN + 16 or k == ND_IN + 32) continue;
        if (rd32(a, k) != rd32(b, k)) return false;
    }
    return true;
}

// ---- capture -----------------------------------------------------------------------------
/// ct_capture: every scene tree against its element (made when new).
pub fn capture() void {
    var ti: u32 = 0;
    while (ti < nt.count()) : (ti += 1) {
        const r = nt.get(ti) orelse continue;
        var t: *Tree = undefined;
        if (find(r[0..32])) |x| {
            t = x;
            if (std.mem.eql(u8, &t.copy, r)) continue; // the same as built? nothing
        } else {
            // new: TREE (name, add time, kind)
            t = make(r[0..32]) orelse continue;
            t.add = co.ts();
            t.kind = rd32(r, TR_KIND);
            co.moB(M_TREE);
            co.moBytes(&t.name);
            co.moU64(t.add);
            co.moU32(t.kind);
            co.moSend();
        }
        // the names table and kind
        if (!std.mem.eql(u8, r[TAIL_AT..], &t.tail) or rd32(r, TR_KIND) != t.kind) opTail(t, r);
        // nodes: matched in order by content without links
        const tidx = index(t);
        const old = t.nsl;
        const new = @min(rd32(r, GR_N), NT_MAXN);
        var i: u32 = 0;
        var j: u32 = 0;
        while (true) {
            if (j >= new) {
                // (old ones left: deleted)
                while (i < old) : (i += 1) opNdel(&cn[t.slot[i]]);
                break;
            }
            if (i >= old) {
                // (new ones left: added at the end)
                while (j < new) : (j += 1) {
                    const after: u64 = if (j > 0) cn[map[j - 1]].id else 0;
                    if (opNadd(after, tidx)) |n| map[j] = cnIndex(n);
                }
                break;
            }
            const a = t.copy[GR_NODES + i * NODE_SZ ..][0..NODE_SZ];
            const b = r[GR_NODES + j * NODE_SZ ..][0..NODE_SZ];
            if (!eqNoLinks(a, b) and old - i > new - j) {
                // more old left than new: deleted
                opNdel(&cn[t.slot[i]]);
                i += 1;
                continue;
            }
            // the same node (changed or not)
            map[j] = t.slot[i];
            i += 1;
            j += 1;
        }
        // each new slot's content as ids
        var k: u32 = 0;
        while (k < new) : (k += 1) setIf(&cn[map[k]], r[GR_NODES + k * NODE_SZ ..][0..NODE_SZ]);
        t.nsl = new;
        @memcpy(t.slot[0..new], map[0..new]);
        @memcpy(&t.copy, r);
    }
}

/// node_ids: a scene node as the register holds it (into tmp).
fn nodeIds(nd: []const u8) void {
    @memcpy(tmp[0..NODE_SZ], nd);
    for (0..3) |k| {
        const l = rd32(nd, ND_IN + k * 16);
        wr32(&tmp, ND_IN + k * 16, 0);
        std.mem.writeInt(u64, tmp[NODE_SZ + k * 8 ..][0..8], 0, .little);
        tmp[NODE_SZ + 24 + k] = 0;
        const from = l & 0xffff; // node + 1
        if (from == 0 or from - 1 >= NT_MAXN) continue;
        tmp[NODE_SZ + 24 + k] = @truncate(l >> 16);
        std.mem.writeInt(u64, tmp[NODE_SZ + k * 8 ..][0..8], cn[map[from - 1]].id, .little);
    }
}

/// node_set_if: NSET when its content (links as ids) differs.
fn setIf(n: *Node, nd: []const u8) void {
    nodeIds(nd);
    if (!std.mem.eql(u8, &n.data, &tmp)) opNset(n);
}

/// The first 736 bytes of the original's tree element (an undo record).
fn tailRecord(t: *const Tree) [U_TAIL_BYTES]u8 {
    var b: [U_TAIL_BYTES]u8 = @splat(0);
    @memcpy(b[0..32], &t.name);
    std.mem.writeInt(u64, b[32..40], t.add, .little);
    wr32(&b, CT_KIND, t.kind);
    std.mem.writeInt(u64, b[48..56], t.tail_ts, .little);
    @memcpy(b[CT_TAIL..], &t.tail);
    return b;
}

/// op_tail: TAIL: kind, names table (from a scene record).
fn opTail(t: *Tree, r: []const u8) void {
    const old = tailRecord(t);
    co.ulPut(U_TAIL, &old); // undo: the old
    t.kind = rd32(r, TR_KIND);
    @memcpy(&t.tail, r[TAIL_AT..][0..TAIL_SZ]);
    t.tail_ts = co.ts();
    msgTail(t);
    co.moSend();
}
fn msgTail(t: *const Tree) void {
    co.moB(M_TAIL);
    co.moBytes(&t.name);
    co.moU64(t.tail_ts);
    co.moU32(t.kind);
    co.moBytes(&t.tail);
}

/// op_nadd: a new node element: NADD.
fn opNadd(after: u64, tree: u32) ?*Node {
    const n = cnMake(co.ts(), tree) orelse return null;
    n.after = after;
    n.add = n.id;
    msgNadd(n);
    co.moSend();
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, n.id, .little);
    co.ulPut(U_NDEL, &b); // undo: delete it
    return n;
}
fn msgNadd(n: *const Node) void {
    co.moB(M_NADD);
    co.moBytes(&tab[n.tree].name);
    co.moU64(n.id);
    co.moU64(n.add);
    co.moU64(n.after);
}

/// op_ndel: NDEL.
fn opNdel(n: *Node) void {
    n.del = co.ts();
    msgNdel(n);
    co.moSend();
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, n.id, .little);
    co.ulPut(U_NADD, &b); // undo: add it again
}
fn msgNdel(n: *const Node) void {
    co.moB(M_NDEL);
    co.moBytes(&tab[n.tree].name);
    co.moU64(n.id);
    co.moU64(n.del);
}

/// op_nset: its content becomes tmp: NSET (the old one recorded).
fn opNset(n: *Node) void {
    var u: [8 + CONTENT]u8 = undefined;
    std.mem.writeInt(u64, u[0..8], n.id, .little);
    @memcpy(u[8..], &n.data);
    co.ulPut(U_NSET, &u);
    n.data = tmp;
    n.ts = co.ts();
    msgNset(n);
    co.moSend();
}
fn msgNset(n: *const Node) void {
    co.moB(M_NSET);
    co.moBytes(&tab[n.tree].name);
    co.moU64(n.id);
    co.moU64(n.ts);
    co.moBytes(&n.data);
}

// ---- remote operations -------------------------------------------------------------------------
/// The bytes each tree message's payload needs (0: not a tree message).
pub fn needBytes(t: u8, _: []const u8) ?usize {
    return switch (t) {
        M_TREE => 44,
        M_TAIL => 44 + TAIL_SZ,
        M_NADD => 56,
        M_NDEL => 48,
        M_NSET => 48 + CONTENT,
        else => 0,
    };
}

/// ct_apply: a tree message.
pub fn apply(t: u8, p: []const u8) void {
    if (t < M_TREE or t > M_NSET) return;
    const tr = find(p[0..32]) orelse make(p[0..32]) orelse return; // the tree (made when new)
    tr.dirty = true;
    const ti = index(tr);
    switch (t) {
        M_TREE => {
            const at = rd64(p, 32);
            co.seenTs(at);
            if (at <= tr.add) return;
            tr.add = at;
            if (tr.tail_ts == 0) tr.kind = rd32(p, 40);
        },
        M_TAIL => {
            const at = rd64(p, 32);
            co.seenTs(at);
            if (at <= tr.tail_ts) return;
            tr.tail_ts = at;
            tr.kind = rd32(p, 40);
            @memcpy(&tr.tail, p[44..][0..TAIL_SZ]);
        },
        else => {
            // a node: id at 32, time at 40
            const at = rd64(p, 40);
            co.seenTs(at);
            const id = rd64(p, 32);
            const n = cnFind(id) orelse cnMake(id, ti) orelse return;
            switch (t) {
                M_NADD => {
                    if (at <= n.add) return;
                    n.add = at;
                    n.after = rd64(p, 48);
                },
                M_NDEL => {
                    if (at <= n.del) return;
                    n.del = at;
                },
                else => {
                    if (at <= n.ts) return;
                    n.ts = at;
                    @memcpy(&n.data, p[48..][0..CONTENT]);
                },
            }
        },
    }
}

/// ct_build_dirty: trees changed by others, built again into the scene.
pub fn buildDirty() void {
    for (tab[0..nct], 0..) |*t, i| {
        if (!t.dirty) continue;
        t.dirty = false;
        build(@intCast(i));
    }
}

/// ct_build: a tree's record from the document into the scene.
fn build(ti: u32) void {
    const t = &tab[ti];
    order(ti);
    @memset(&rec, 0);
    @memcpy(rec[0..31], t.name[0..31]);
    wr32(&rec, TR_KIND, t.kind);
    @memcpy(rec[TAIL_AT..], &t.tail);
    wr32(&rec, GR_N, @intCast(nord));
    for (0..nord) |k| {
        t.slot[k] = ord[k];
        const n = &cn[ord[k]];
        const at = GR_NODES + k * NODE_SZ;
        @memcpy(rec[at..][0..NODE_SZ], n.data[0..NODE_SZ]);
        for (0..3) |l| {
            const id = rd64(&n.data, NODE_SZ + l * 8);
            if (id == 0) continue;
            for (0..nord) |s| {
                if (cn[ord[s]].id != id) continue;
                wr32(&rec, at + ND_IN + l * 16, @as(u32, @intCast(s + 1)) | (@as(u32, n.data[NODE_SZ + 24 + l]) << 16));
                break;
            }
        }
    }
    t.nsl = @intCast(nord);
    // into the scene: its tree (made)
    const si = nt.find(cstr(rec[0..32])) orelse nt.new(cstr(rec[0..32])) orelse return;
    const dst = nt.own(si) orelse return;
    @memcpy(dst, &rec);
    t.copy = rec;
    app.dirty = true;
}

// ---- state, hash, undo -------------------------------------------------------------------------
/// ct_send_state: every tree and node, to a connection.
pub fn sendState(c: *co.Conn) void {
    for (tab[0..nct]) |*t| {
        co.moB(M_TREE);
        co.moBytes(&t.name);
        co.moU64(t.add);
        co.moU32(t.kind);
        co.stPut(c);
        if (t.tail_ts != 0) {
            msgTail(t);
            co.stPut(c);
        }
    }
    for (cn[0..ncn]) |*n| {
        msgNadd(n);
        co.stPut(c);
        if (n.del != 0) {
            msgNdel(n);
            co.stPut(c);
        }
        if (n.ts != 0) {
            msgNset(n);
            co.stPut(c);
        }
    }
}

/// ct_hash: the trees by name, each its kind, names table and alive nodes in
/// order (id, content).
pub fn hash(f: *co.Hasher) void {
    var ix: [CT_MAX]u32 = undefined;
    for (0..nct) |i| ix[i] = @intCast(i);
    std.sort.pdq(u32, ix[0..nct], {}, struct {
        fn lt(_: void, a: u32, b: u32) bool {
            return co.strLess(cstr(&tab[a].name), cstr(&tab[b].name));
        }
    }.lt);
    for (ix[0..nct]) |i| {
        const t = &tab[i];
        f.mix(&t.name);
        f.mix(std.mem.asBytes(&t.kind));
        f.mix(&t.tail);
        order(i);
        for (ord[0..nord]) |k| {
            f.mix(std.mem.asBytes(&cn[k].id));
            f.mix(&cn[k].data);
        }
    }
}

/// ct_undo: a tree record's inverse as new operations (the tree built again).
pub fn undo(t: u32, d: []const u8) void {
    if (t < U_NADD or t > U_TAIL) return;
    if (t == U_TAIL) {
        if (d.len < U_TAIL_BYTES) return;
        const tr = find(d[0..32]) orelse return;
        @memset(&rec, 0);
        wr32(&rec, TR_KIND, rd32(d, CT_KIND));
        @memcpy(rec[TAIL_AT..], d[CT_TAIL..][0..TAIL_SZ]);
        opTail(tr, &rec);
        return build(index(tr));
    }
    if (d.len < 8) return;
    const n = cnFind(rd64(d, 0)) orelse return;
    switch (t) {
        U_NADD => {
            n.add = co.ts();
            msgNadd(n);
            co.moSend();
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, n.id, .little);
            co.ulPut(U_NDEL, &b);
        },
        U_NDEL => opNdel(n),
        else => {
            if (d.len < 8 + CONTENT) return;
            @memcpy(&tmp, d[8..][0..CONTENT]);
            opNset(n);
        },
    }
    build(n.tree);
}

test "a node's content but its links; tree messages' sizes" {
    var a: [NODE_SZ]u8 = @splat(0);
    var b: [NODE_SZ]u8 = @splat(0);
    a[ND_IN] = 3; // a link
    try std.testing.expect(eqNoLinks(&a, &b));
    a[0] = 1; // the type
    try std.testing.expect(!eqNoLinks(&a, &b));
    try std.testing.expectEqual(@as(?usize, 44 + 480), needBytes(M_TAIL, &.{}));
    try std.testing.expectEqual(@as(?usize, 48 + 99), needBytes(M_NSET, &.{}));
    try std.testing.expectEqual(@as(usize, 480), TAIL_SZ);
}

test "the node order: newest first under each, a node after itself not followed" {
    reset();
    _ = cnMake(10, 0).?;
    cn[0].add = 1;
    _ = cnMake(20, 0).?;
    cn[1].add = 1;
    cn[1].after = 10;
    _ = cnMake(30, 0).?;
    cn[2].add = 1;
    _ = cnMake(40, 0).?;
    cn[3].add = 1;
    cn[3].after = 40;
    order(0);
    try std.testing.expectEqual(@as(usize, 3), nord);
    try std.testing.expectEqual(@as(u64, 30), cn[ord[0]].id);
    try std.testing.expectEqual(@as(u64, 10), cn[ord[1]].id);
    try std.testing.expectEqual(@as(u64, 20), cn[ord[2]].id);
    reset();
}
