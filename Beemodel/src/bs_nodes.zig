// BeeScript's node builtins: a material's shader graph (script.s b_node,
// b_link, b_nodeset, b_socket, b_nodeinfo, b_nodeval) through graphops.zig,
// and geometry node trees (b_gtree, b_gnode, b_glink, b_gset, b_ginfo)
// through ntree.zig. Node numbers are 1-based as in the node editor; what
// they change is part of the run's one undo step (bscript.zig).
const std = @import("std");
const bs = @import("bscript.zig");
const bm = @import("bs_mat.zig");
const material = @import("material.zig");
const images = @import("images.zig");
const gops = @import("graphops.zig");
const sg = @import("shgraph.zig");
const nt = @import("ntree.zig");
const gn = @import("geonodes.zig");
const app = @import("app.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "node", .f = node },
    .{ .name = "link", .f = link },
    .{ .name = "nodeset", .f = nodeset },
    .{ .name = "nodeinfo", .f = nodeinfo },
    .{ .name = "nodeval", .f = nodeval },
    .{ .name = "socket", .f = socket },
    .{ .name = "gtree", .f = gtree },
    .{ .name = "gnode", .f = gnode },
    .{ .name = "glink", .f = glink },
    .{ .name = "gset", .f = gset },
    .{ .name = "ginfo", .f = ginfo },
};

const e_node_type = "unknown node type (image noise checker gradient mix ramp math bump normalmap): ";
const e_node_full = "a material holds 12 nodes";
const e_no_image = "no image called ";
const e_tree_bad = "no such node tree, node or input";
const e_gtype = "unknown geometry node type: ";
const e_uv_kind = "unknown kind: ";

const ni_whats = [_][]const u8{ "count", "type", "link", "socket", "x", "y", "value", "linkout", "socketout" };
const gi_whats = [_][]const u8{ "count", "type", "link", "output", "x", "y", "value" };

/// uv_kind: the index of the name in the table, exactly.
fn kindOf(v: V, names: []const []const u8) Err!u32 {
    const s = try bs.argStr(v);
    for (names, 0..) |n, k| {
        if (std.mem.eql(u8, n, s)) return @intCast(k);
    }
    return bs.fail(e_uv_kind, s);
}

fn argImage(v: V) Err!usize {
    const nm = try bs.argStr(v);
    return images.find(nm) orelse bs.fail(e_no_image, nm);
}

fn u(x: i32) u32 {
    return @bitCast(x);
}

// ---- a material's graph ---------------------------------------------------------------

fn isParam(t: u32) bool {
    return t >= 37 and t <= 39;
}

/// node(material, type [, values...]) -> the node's number; an image node
/// (a texture parameter) takes an image name first, a Material Function its
/// function, a parameter its name before that
fn node(a0: []const V) Err!V {
    var a = a0;
    const mi = try bm.argMat(a[0]);
    const tn = try bs.argStr(a[1]);
    const t = gops.typeIndex(tn) orelse return bs.fail(e_node_type, tn);
    const n = gops.add(mi, t) orelse return bs.fail(e_node_full, "");
    app.dirty = true;
    var slot: u32 = 4;
    var k: usize = 2;
    if (isParam(t) and a.len >= 3 and a[2].t == .str) {
        gops.setParamName(&sg.nodesMut(&material.list[mi])[n - 1], std.mem.span(a[2].u.s));
        a = a[1..]; // (the rest as if one argument less)
    }
    if (t == 1 or t == 39 or t == 42) {
        if (a.len >= 3) {
            const x = if (t == 42) try bm.argMat(a[2]) else try argImage(a[2]);
            _ = gops.setSlot(mi, n, 4, &.{@floatFromInt(@as(i32, @intCast(x)) + 1)});
            slot = 5;
            k = 3;
        }
    }
    while (k < a.len) : (k += 1) {
        const x = bs.f32of(try bs.argNum(a[k]));
        _ = gops.setSlot(mi, n, slot, &.{x});
        slot += 1;
    }
    return bs.num(@floatFromInt(n));
}

/// link(material, from, to, input 1..3 [, from's output 0..]) -> to's number
/// (linking backwards renumbers)
fn link(a: []const V) Err!V {
    var out: i32 = 0;
    if (a.len >= 5) {
        out = try bm.argInt(a[4]);
        if (out < 0) return bs.fail(bm.e_node_bad, "");
    }
    const mi = try bm.argMat(a[0]);
    const from = try bm.argInt(a[1]);
    const to = try bm.argInt(a[2]);
    const input = try bm.argInt(a[3]);
    app.dirty = true;
    const r = gops.link(mi, u(from), u(to), u(input), u(out)) orelse return bs.fail(bm.e_node_bad, "");
    return bs.num(@floatFromInt(r));
}

/// nodeset(material, node, slot 1..7, x [, y, z])
fn nodeset(a: []const V) Err!V {
    const mi = try bm.argMat(a[0]);
    const n = try bm.argInt(a[1]);
    const slot = try bm.argInt(a[2]);
    var v: [3]f32 = undefined;
    var c: usize = 0;
    while (c + 3 < a.len) : (c += 1) v[c] = bs.f32of(try bs.argNum(a[c + 3]));
    app.dirty = true;
    if (!gops.setSlot(mi, u(n), u(slot), v[0..c])) return bs.fail(bm.e_node_bad, "");
    return bs.nil;
}

/// socket(material, base|metallic|.., node or nil [, output 0..])
fn socket(a: []const V) Err!V {
    var out: i32 = 0;
    if (a.len >= 4) {
        out = try bm.argInt(a[3]);
        if (out < 0) return bs.fail(bm.e_node_bad, "");
    }
    const mi = try bm.argMat(a[0]);
    const sn = try bs.argStr(a[1]);
    var pin: ?usize = null;
    for (gops.socket_names, 0..) |x, k| {
        if (std.mem.eql(u8, x, sn)) {
            pin = k;
            break;
        }
    }
    const p = pin orelse return bs.fail(bm.e_node_bad, "");
    var n: i32 = 0; // nil: unplugged
    if (a[2].t != .nil) n = try bm.argInt(a[2]);
    app.dirty = true;
    if (!gops.socket(mi, p, u(n), u(out))) return bs.fail(bm.e_node_bad, "");
    return bs.nil;
}

/// graph_info: what 0 the node count, 1 the node's type, 2 the node feeding
/// its input k, 3 the node driving pin k, 4 x, 5 y (node 0: the output), 6
/// the output feeding input k, 7 the output driving pin k; -1 none.
fn graphInfo(mi: usize, nd: i32, what: u32, k: i32) i32 {
    const ma = material.get(mi) orelse return -1;
    const n = sg.count(ma);
    if (what == 0) return @bitCast(ma.nodes());
    if (what == 3 or what == 7) {
        if (u(k) >= sg.NPINS) return -1;
        const p = sg.pinsOf(ma)[@intCast(k)];
        return @bitCast(if (what == 7) p >> 16 else p & 0xffff);
    }
    var pos: [2]i16 = undefined;
    if (nd == 0) {
        pos = outPos(ma);
    } else {
        if (nd < 0 or u(nd) > n) return -1;
        const x = &sg.nodesOf(ma)[@intCast(nd - 1)];
        if (what == 1) return @bitCast(x.type);
        if (what == 2 or what == 6) {
            if (u(k -% 1) >= 3) return -1;
            const l = x.in[@intCast(k - 1)].link;
            return @bitCast(if (what == 6) l >> 16 else l & 0xffff);
        }
        pos = x.pos;
    }
    if (what == 4) return pos[0];
    if (what == 5) return pos[1];
    return -1;
}

/// GR_OUTPOS: where the node editor shows the Material Output.
fn outPos(ma: *const material.Material) [2]i16 {
    const o = 152 - material.FILE_PART; // (GR_OUTPOS in the graph block)
    return .{ std.mem.readInt(i16, ma.graph[o..][0..2], .little), std.mem.readInt(i16, ma.graph[o + 2 ..][0..2], .little) };
}

/// nodeinfo(material, node, "count" | "type" | "link" | "socket" | "x" | "y"
/// | "value" | "linkout" | "socketout" [, k])
fn nodeinfo(a: []const V) Err!V {
    gops.syncCheck(); // (instances up to date)
    const mi = try bm.argMat(a[0]);
    const nd = try bm.argInt(a[1]);
    var what = try kindOf(a[2], &ni_whats);
    var k: i32 = 0;
    if (a.len >= 4) k = try bm.argInt(a[3]);
    if (what == 6) {
        // graph_value: value k (1..4), 0 if none
        const ma = material.get(mi) orelse return bs.num(0);
        if (nd <= 0 or u(nd) > sg.count(ma) or u(k -% 1) >= 4) return bs.num(0);
        return bs.num(sg.nodesOf(ma)[@intCast(nd - 1)].p[@intCast(k - 1)]);
    }
    if (what >= 7) what -= 1; // (linkout, socketout: graph_info's 6, 7)
    return bs.num(@floatFromInt(graphInfo(mi, nd, what, k)));
}

/// nodeval(material, node, k, x, y, z [, u, v]): node's output k / 4,
/// channel k % 4, evaluated at that point
fn nodeval(a: []const V) Err!V {
    var f: [5]f32 = @splat(0);
    const mi = try bm.argMat(a[0]);
    const nd = try bm.argInt(a[1]);
    const k = try bm.argInt(a[2]);
    var c: usize = 0;
    while (c + 3 < a.len and c < 5) : (c += 1) f[c] = bs.f32of(try bs.argNum(a[c + 3]));
    gops.syncCheck(); // (material instances up to date)
    sg.scene_time = gops.sceneTime();
    const ma = material.get(mi) orelse return bs.fail(bm.e_node_bad, "");
    if (nd <= 0) return bs.fail(bm.e_node_bad, "");
    const x = sg.probe(ma, material.list[0..material.count], u(nd), u(k), f[0..3].*, f[3..5].*) orelse return bs.fail(bm.e_node_bad, "");
    return bs.num(x);
}

// ---- geometry node trees -------------------------------------------------------------

/// gtree(name) -> the node tree's number (made when there is none)
fn gtree(a: []const V) Err!V {
    const nm = try bs.argStr(a[0]);
    const t = nt.find(nm) orelse (nt.new(nm) orelse return bs.fail(e_tree_bad, ""));
    app.dirty = true;
    return bs.num(@floatFromInt(t + 1));
}

/// a_tree: a tree by its number (1..)
fn argTree(v: V) Err!u32 {
    const t = (try bm.argInt(v)) -% 1;
    if (t < 0 or u(t) >= nt.count()) return bs.fail(e_tree_bad, "");
    return u(t);
}

/// gnode(tree, type [, values...]) -> the new node's number
fn gnode(a: []const V) Err!V {
    const t = try argTree(a[0]);
    const tn = try bs.argStr(a[1]);
    const ty = gn.typeIndex(tn) orelse return bs.fail(e_gtype, tn);
    const n = nt.add(t, ty, &gn.defaults[ty - 1]) orelse return bs.fail(e_tree_bad, "");
    var k: usize = 2;
    while (k < a.len) : (k += 1) {
        const x = bs.f32of(try bs.argNum(a[k]));
        _ = nt.set(t, @intCast(n), @intCast(k + 2), &.{x});
    }
    return bs.num(@floatFromInt(n));
}

/// glink(tree, from, to, input [, output]) -> to's number (a loop is an error)
fn glink(a: []const V) Err!V {
    const t = try argTree(a[0]);
    const from = try bm.argInt(a[1]);
    const to = try bm.argInt(a[2]);
    const input = try bm.argInt(a[3]);
    var out: i32 = 0;
    if (a.len >= 5) out = try bm.argInt(a[4]);
    const r = nt.link(t, from, to, input, out);
    if (r == 0) return bs.fail(e_tree_bad, "");
    return bs.num(@floatFromInt(r));
}

/// gset(tree, node, slot, x [, y, z]): an input's constant (1-3) or a value (4-7)
fn gset(a: []const V) Err!V {
    const t = try argTree(a[0]);
    const n = try bm.argInt(a[1]);
    const slot = try bm.argInt(a[2]);
    var v: [3]f32 = undefined;
    var c: usize = 0;
    while (c + 3 < a.len) : (c += 1) v[c] = bs.f32of(try bs.argNum(a[c + 3]));
    if (!nt.set(t, n, slot, v[0..c])) return bs.fail(e_tree_bad, "");
    return bs.nil;
}

/// ginfo(tree, node, "count" | "type" | "link" | "output" | "x" | "y" |
/// "value" [, k]): as nodeinfo, for a node tree
fn ginfo(a: []const V) Err!V {
    const t = try argTree(a[0]);
    const n = try bm.argInt(a[1]);
    const what = try kindOf(a[2], &gi_whats);
    var k: i32 = 0;
    if (a.len >= 4) k = try bm.argInt(a[3]);
    if (what == 6) return bs.num(nt.value(t, n, k) orelse 0);
    return bs.num(@floatFromInt(nt.info(t, n, what, k)));
}

test "graph_info: counts, links, pins, the output's place, -1 for none" {
    material.reset();
    const mi = material.new("T").?;
    const a = gops.add(mi, 2).?; // noise
    const b = gops.add(mi, 5).?; // mix
    _ = gops.link(mi, a, b, 2, 1).?;
    _ = gops.socket(mi, 3, b, 2);
    _ = gops.place(mi, 0, 120, -40);
    try std.testing.expectEqual(@as(i32, 2), graphInfo(mi, 0, 0, 0));
    try std.testing.expectEqual(@as(i32, 5), graphInfo(mi, 2, 1, 0));
    try std.testing.expectEqual(@as(i32, 1), graphInfo(mi, 2, 2, 2));
    try std.testing.expectEqual(@as(i32, 1), graphInfo(mi, 2, 6, 2));
    try std.testing.expectEqual(@as(i32, 2), graphInfo(mi, 0, 3, 3));
    try std.testing.expectEqual(@as(i32, 2), graphInfo(mi, 0, 7, 3));
    try std.testing.expectEqual(@as(i32, 120), graphInfo(mi, 0, 4, 0));
    try std.testing.expectEqual(@as(i32, -40), graphInfo(mi, 0, 5, 0));
    try std.testing.expectEqual(@as(i32, -1), graphInfo(mi, 3, 1, 0));
    try std.testing.expectEqual(@as(i32, -1), graphInfo(mi, 2, 2, 4));
    try std.testing.expectEqual(@as(i32, -1), graphInfo(mi, 0, 3, 13));
    try std.testing.expectEqual(@as(i32, -1), graphInfo(mi, 0, 1, 0));
    material.reset();
}
