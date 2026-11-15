// The workspaces on disk, as the original's workspace.s: WSPC in a .bee, and
// the same bytes in ~/.config/beemodel-zig/workspaces (the last ones used, for
// a new scene; their cameras are not remembered).
//   WSPC  u32 count, u32 current, then a record of 1856 bytes each:
//     name[24], root, active area, viewport area, maximized (-1), Properties tab,
//     zeros up to 64;
//     32 nodes of 32 bytes: kind (1 leaf, 2 a | b, 3 a / b), editor, parent,
//       flags (1: a floating panel), ratio 16.16, a, b, z, 0, x, y, w, h, 0;
//     32 cameras of 24 bytes: yaw, pitch (radians), distance, target.
// The port's areas are a pool shared by the workspaces, so the file's numbers
// are made on writing and forgotten on reading. Everything read is checked
// first: a damaged chunk changes nothing.
const std = @import("std");
const app = @import("app.zig");
const m = @import("math.zig");
const vp = @import("viewport.zig");

const MAX_NODES = 32;
const N_SZ = 32;
const CAM_SZ = 24;
const REC = 64 + MAX_NODES * N_SZ + MAX_NODES * CAM_SZ;
const NONE: u8 = 0xff;
const K_LEAF = 1;
const K_HSPLIT = 2;
const K_VSPLIT = 3;
const NF_FLOAT = 1;
pub const WS_MAX = 12;

// the original's ED_ numbers (const.inc) and the port's editor of each, by name
// (an editor the port gets later is simply found here)
const ED_VIEWPORT = 0;
const ED_PROPS = 3;
const ed_tags = [_][]const u8{ "viewport", "tools", "outliner", "properties", "console", "activity", "render", "uved", "nodes", "assets", "timeline", "dopesheet", "graph", "versions", "prefs", "help", "ai" };
const ed_names = [_][]const u8{ "3D Viewport", "Tools", "Outliner", "Properties", "Console", "Activity", "Render", "UV Editor", "Node Editor", "Asset Browser", "Timeline", "Dope Sheet", "Graph Editor", "Versions", "Preferences", "Help", "AI Assistant" };

pub fn otherLabel(ed: u8) []const u8 {
    return if (ed < ed_names.len) ed_names[ed] else "Unknown Editor";
}

fn toFile(n: *const app.Node) u8 {
    if (n.editor == .other) return n.raw_ed;
    const t = @tagName(n.editor);
    for (ed_tags, 0..) |x, k| {
        if (std.mem.eql(u8, x, t)) return @intCast(k);
    }
    return 0;
}

fn fromFile(ed: u8) app.Editor {
    if (ed >= ed_tags.len) return .other;
    return std.meta.stringToEnum(app.Editor, ed_tags[ed]) orelse .other;
}

fn wr32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}
fn wrf(b: []u8, o: usize, v: f32) void {
    wr32(b, o, @bitCast(v));
}
fn rd32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
fn rdf(b: []const u8, o: usize) f32 {
    return @bitCast(rd32(b, o));
}

// --- writing ---------------------------------------------------------------------

const home_cam = [6]f32{ 0.7853982, 0.5, 18.0, 0.0, 0.0, 0.0 };

fn nodeCount(i: i16) usize {
    const n = app.N(i);
    return if (n.leaf) 1 else 1 + nodeCount(n.a) + nodeCount(n.b);
}

fn firstLeaf(i: i16) i16 {
    const n = app.N(i);
    return if (n.leaf) i else firstLeaf(n.a);
}

const Out = struct {
    rec: []u8,
    n: u32 = 0,
    map: []i16, // the port's area -> the file's number
    first_vp: i32 = -1,
    tab: ?u8 = null, // the first Properties area's tab
};

fn nodeAt(o: *Out, k: u32) []u8 {
    return o.rec[64 + k * N_SZ..][0..N_SZ];
}

fn leafTo(o: *Out, k: u32, i: i16, parent: u8) void {
    const n = app.N(i);
    const b = nodeAt(o, k);
    b[0] = K_LEAF;
    b[1] = toFile(n);
    b[2] = parent;
    wr32(b, 12, @bitCast(n.rect.x));
    wr32(b, 16, @bitCast(n.rect.y));
    wr32(b, 20, @bitCast(n.rect.w));
    wr32(b, 24, @bitCast(n.rect.h));
    o.map[@intCast(i)] = @intCast(k);
    if (n.editor == .viewport and o.first_vp < 0) o.first_vp = @intCast(k);
    if (n.editor == .properties and o.tab == null) o.tab = n.tab;
    const c = o.rec[64 + MAX_NODES * N_SZ + k * CAM_SZ..][0..CAM_SZ];
    if (n.editor == .viewport) {
        wrf(c, 0, n.view.yaw * m.deg);
        wrf(c, 4, n.view.pitch * m.deg);
        wrf(c, 8, n.view.dist);
        for (n.view.target, 0..) |x, j| wrf(c, 12 + j * 4, x);
    }
}

/// Node i and what is below it, in `room` nodes at most. A tree too big for the
/// file's 32 loses its branches to their first leaf (the port's pool is larger).
fn place(o: *Out, i: i16, parent: u8, room: u32) u8 {
    const k = o.n;
    o.n += 1;
    const n = app.N(i);
    if (n.leaf or room < 3) {
        leafTo(o, k, if (n.leaf) i else firstLeaf(i), parent);
        return @intCast(k);
    }
    const b = nodeAt(o, k);
    b[0] = if (n.vertical) K_HSPLIT else K_VSPLIT;
    b[2] = parent;
    wr32(b, 4, @intFromFloat(std.math.clamp(@round(n.ratio * 65536), 1, 65535)));
    wr32(b, 12, @bitCast(n.rect.x));
    wr32(b, 16, @bitCast(n.rect.y));
    wr32(b, 20, @bitCast(n.rect.w));
    wr32(b, 24, @bitCast(n.rect.h));
    const avail = room - 1;
    const ca: u32 = @intCast(nodeCount(n.a));
    const cb: u32 = @intCast(nodeCount(n.b));
    const ra = if (ca + cb <= avail) ca else std.math.clamp(avail - @min(cb, avail / 2), 1, ca);
    const rb = if (ca + cb <= avail) cb else avail - ra;
    const a = place(o, n.a, @intCast(k), ra);
    const c = place(o, n.b, @intCast(k), rb);
    b[8] = a;
    b[9] = c;
    return @intCast(k);
}

fn writeRecord(w: *const app.Workspace, is_cur: bool, rec: []u8, map: []i16) void {
    @memset(rec, 0);
    @memset(map, -1);
    const nm = w.name();
    @memcpy(rec[0..@min(nm.len, 23)], nm[0..@min(nm.len, 23)]);
    const cams = rec[64 + MAX_NODES * N_SZ..];
    for (0..MAX_NODES) |k| {
        for (home_cam, 0..) |x, j| wrf(cams, k * CAM_SZ + j * 4, x);
    }
    var o = Out{ .rec = rec, .map = map };
    const room: u32 = MAX_NODES - @as(u32, @intCast(w.nfloats));
    const root = place(&o, w.root, NONE, room);
    wr32(rec, 24, root);
    // floating panels: leaves outside the tree, z their place in the stack
    for (w.floats[0..w.nfloats], 0..) |f, z| {
        if (o.n >= MAX_NODES) break;
        const k = o.n;
        o.n += 1;
        leafTo(&o, k, f.node, NONE);
        const b = nodeAt(&o, k);
        b[3] = NF_FLOAT;
        b[10] = @intCast(z);
        wr32(b, 12, @bitCast(f.rect.x));
        wr32(b, 16, @bitCast(f.rect.y));
        wr32(b, 20, @bitCast(f.rect.w));
        wr32(b, 24, @bitCast(f.rect.h));
    }
    const vp_k: u32 = if (o.first_vp >= 0) @intCast(o.first_vp) else 0;
    var act: i32 = o.first_vp;
    if (is_cur) {
        const a = app.activeArea();
        if (a >= 0 and map[@intCast(a)] >= 0) act = map[@intCast(a)];
    }
    if (act < 0) act = @intCast(firstLeafNumber(rec));
    wr32(rec, 28, @bitCast(act));
    wr32(rec, 32, vp_k);
    const maxed: i32 = if (w.maximized >= 0) map[@intCast(w.maximized)] else -1;
    wr32(rec, 36, @bitCast(maxed));
    wr32(rec, 40, o.tab orelse 0);
}

fn firstLeafNumber(rec: []const u8) u32 {
    for (0..MAX_NODES) |k| {
        if (rec[64 + k * N_SZ] == K_LEAF) return @intCast(k);
    }
    return 0;
}

/// The count, the current one, the records.
pub fn writeChunk(b: anytype) void {
    var rec: [REC]u8 = undefined;
    var map: [app.nodes.len]i16 = undefined;
    const n: u32 = @intCast(@min(app.n_ws, WS_MAX));
    b.u32_(n);
    b.u32_(@intCast(app.cur_ws));
    for (app.workspaces[0..n], 0..) |*w, i| {
        writeRecord(w, i == app.cur_ws, &rec, &map);
        b.bytes(&rec);
    }
}

// --- reading ---------------------------------------------------------------------

/// A record's tree: every node once, every kind known.
fn validTree(nodes: []const u8, i: u32, seen: *[MAX_NODES]bool) bool {
    if (i >= MAX_NODES or seen[i]) return false;
    seen[i] = true;
    const b = nodes[i * N_SZ..][0..N_SZ];
    return switch (b[0]) {
        K_LEAF => true,
        K_HSPLIT, K_VSPLIT => validTree(nodes, b[8], seen) and validTree(nodes, b[9], seen),
        else => false,
    };
}

fn validRecord(r: []const u8) bool {
    const root = rd32(r, 24);
    var seen: [MAX_NODES]bool = @splat(false);
    return validTree(r[64..][0 .. MAX_NODES * N_SZ], root, &seen);
}

/// The original writes a count of 0 without a window (--eval): no workspaces.
pub fn empty(c: []const u8) bool {
    return c.len >= 4 and rd32(c, 0) == 0;
}

/// True when the chunk can be used: nothing has changed if not.
pub fn valid(c: []const u8) bool {
    if (c.len < 8) return false;
    const n = rd32(c, 0);
    if (n == 0 or n > WS_MAX or 8 + @as(usize, n) * REC > c.len) return false;
    for (0..n) |k| {
        if (!validRecord(c[8 + k * REC..][0..REC])) return false;
    }
    return true;
}

fn finite(x: f32, d: f32) f32 {
    return if (std.math.isFinite(x)) x else d;
}

fn camTo(v: *vp.View, c: []const u8) void {
    const yaw = finite(rdf(c, 0) / m.deg, 45);
    v.yaw = @mod(yaw, 360);
    v.pitch = std.math.clamp(finite(rdf(c, 4) / m.deg, 28.64789), -89.9, 89.9);
    v.dist = std.math.clamp(finite(rdf(c, 8), 18), 0.5, 500);
    for (&v.target, 0..) |*x, j| x.* = finite(rdf(c, 12 + j * 4), 0);
}

fn build(r: []const u8, k: u32, parent: i16, back: *[MAX_NODES]i16, tab: u8) i16 {
    const b = r[64 + k * N_SZ..][0..N_SZ];
    const i = app.alloc();
    if (i < 0) return i;
    back[k] = i;
    const n = app.N(i);
    n.parent = parent;
    if (b[0] == K_LEAF) {
        leafFrom(r, k, i, tab);
        return i;
    }
    n.leaf = false;
    n.vertical = b[0] == K_HSPLIT;
    const raw = rd32(b, 4);
    n.ratio = if (raw == 0 or raw >= 65536) 0.5 else @as(f32, @floatFromInt(raw)) / 65536.0;
    const a = build(r, b[8], i, back, tab);
    const c = build(r, b[9], i, back, tab);
    n.a = a;
    n.b = c;
    return i;
}

fn leafFrom(r: []const u8, k: u32, i: i16, tab: u8) void {
    const b = r[64 + k * N_SZ..][0..N_SZ];
    const n = app.N(i);
    n.editor = fromFile(b[1]);
    n.raw_ed = b[1];
    n.tab = tab;
    if (n.editor == .viewport) camTo(&n.view, r[64 + MAX_NODES * N_SZ + k * CAM_SZ..][0..CAM_SZ]);
}

fn numbered(v: u32, back: *const [MAX_NODES]i16) i16 {
    return if (v < MAX_NODES) back[v] else -1;
}

/// Replace the workspaces with those of a chunk that passed valid().
/// `home_cams`: the last session's layouts for a new scene: its cameras were
/// aimed at the last one (workspace.s, wsp_home_cams).
pub fn read(c: []const u8, home_cams: bool) void {
    for (app.workspaces[0..app.n_ws]) |*w| {
        app.freeTree(w.root);
        for (w.floats[0..w.nfloats]) |f| app.freeTree(f.node);
    }
    const n = rd32(c, 0);
    app.n_ws = n;
    var cur = rd32(c, 4);
    if (cur >= n) cur = 0;
    app.cur_ws = cur;
    var active: i16 = -1;
    for (0..n) |k| {
        const r = c[8 + k * REC..][0..REC];
        const w = &app.workspaces[k];
        w.* = .{};
        w.setName(std.mem.sliceTo(r[0..24], 0));
        if (w.name_len == 0) w.setName("Workspace");
        var back: [MAX_NODES]i16 = @splat(-1);
        const tab: u8 = @intCast(@min(rd32(r, 40), 255));
        w.root = build(r, rd32(r, 24), -1, &back, tab);
        // panels, in their stack's order
        var z: u32 = 0;
        while (z < 256 and w.nfloats < w.floats.len) : (z += 1) {
            for (0..MAX_NODES) |q| {
                const b = r[64 + q * N_SZ..][0..N_SZ];
                if (b[0] != K_LEAF or b[3] & NF_FLOAT == 0 or b[10] != z or back[q] >= 0 or w.nfloats >= w.floats.len) continue;
                const i = app.alloc();
                if (i < 0) continue;
                back[q] = i;
                leafFrom(r, @intCast(q), i, tab);
                const rw: i32 = @bitCast(rd32(b, 20));
                const rh: i32 = @bitCast(rd32(b, 24));
                w.floats[w.nfloats] = .{ .node = i, .rect = .{
                    .x = std.math.clamp(@as(i32, @bitCast(rd32(b, 12))), -30000, 30000),
                    .y = std.math.clamp(@as(i32, @bitCast(rd32(b, 16))), -30000, 30000),
                    .w = std.math.clamp(rw, 220, 4000),
                    .h = std.math.clamp(rh, 140, 4000),
                } };
                w.nfloats += 1;
            }
        }
        const mx = numbered(rd32(r, 36), &back);
        w.maximized = if (mx >= 0 and app.N(mx).leaf) mx else -1;
        if (k == cur) active = numbered(rd32(r, 28), &back);
    }
    if (home_cams) {
        for (&app.nodes) |*nd| {
            if (!nd.used or !nd.leaf or nd.editor != .viewport) continue;
            nd.view.yaw = home_cam[0] / m.deg;
            nd.view.pitch = home_cam[1] / m.deg;
            nd.view.dist = home_cam[2];
            nd.view.target = .{ 0, 0, 0 };
        }
    }
    app.workspacesReplaced(active);
}

// --- commands ---------------------------------------------------------------------

/// workspace.set <number from 1 | name>
pub fn opSet(arg: []const u8) void {
    if (arg.len == 1 and arg[0] >= '1' and arg[0] <= '9') return app.switchWorkspace(arg[0] - '1');
    for (app.workspaces[0..app.n_ws], 0..) |*w, i| {
        if (std.mem.eql(u8, w.name(), arg)) return app.switchWorkspace(i);
    }
    app.log("  workspace.set <number from 1 | name>", .{});
}

/// workspace.rename <name>
pub fn opRename(arg: []const u8) void {
    if (arg.len == 0) return app.workspaceRename();
    app.ws().setName(arg[0..@min(arg.len, 23)]);
    persist();
}

// --- remembered ------------------------------------------------------------------

var path_buf: [300]u8 = undefined;
var path_len: usize = 0;

/// Start: the last session's workspaces (`dir`: the preferences' folder).
pub fn initRemembered(home: []const u8) void {
    const s = std.fmt.bufPrint(&path_buf, "{s}/.config/beemodel-zig/workspaces", .{home}) catch return;
    path_len = s.len;
    const d = @import("ttf.zig").mapFile(s) orelse return;
    defer _ = std.os.linux.munmap(d.ptr, d.len);
    if (valid(d)) read(d, true);
}

/// The same bytes as WSPC; after a switch, as the original.
pub fn persist() void {
    if (path_len == 0) return;
    // (the folders may not be there yet)
    var db: [300]u8 = undefined;
    const p = path_buf[0..path_len];
    var at = p.len;
    for ([_]u8{ 0, 1, 2 }) |_| at = std.mem.lastIndexOfScalar(u8, p[0..at], '/') orelse 0;
    while (at < p.len) {
        const end = std.mem.indexOfScalarPos(u8, p, at + 1, '/') orelse break;
        @memcpy(db[0..end], p[0..end]);
        db[end] = 0;
        _ = std.os.linux.mkdir(@ptrCast(&db), 0o755);
        at = end;
    }
    var b = Bytes{};
    defer b.data.deinit(std.heap.page_allocator);
    writeChunk(&b);
    if (!b.failed) @import("bee.zig").writeAtomic(path_buf[0..path_len], b.data.items) catch {};
}

const Bytes = struct {
    data: std.ArrayList(u8) = .empty,
    failed: bool = false,
    fn u32_(b: *Bytes, v: u32) void {
        var x: [4]u8 = undefined;
        std.mem.writeInt(u32, &x, v, .little);
        b.bytes(&x);
    }
    fn bytes(b: *Bytes, s: []const u8) void {
        b.data.appendSlice(std.heap.page_allocator, s) catch {
            b.failed = true;
        };
    }
};

test "the record's size is the original's" {
    try std.testing.expectEqual(1856, REC);
}

test "a damaged tree is refused" {
    var c: [8 + REC]u8 = @splat(0);
    wr32(&c, 0, 1);
    try std.testing.expect(!valid(&c)); // (kind 0)
    const n = c[8 + 64..];
    n[0] = K_HSPLIT;
    n[8] = 0; // a loop
    n[9] = 1;
    n[N_SZ] = K_LEAF;
    try std.testing.expect(!valid(&c));
    n[8] = 2;
    n[2 * N_SZ] = K_LEAF;
    try std.testing.expect(valid(&c));
    n[9] = 40; // out of the table
    try std.testing.expect(!valid(&c));
    n[9] = 1;
    wr32(&c, 0, 13);
    try std.testing.expect(!valid(&c));
    wr32(&c, 0, 2); // (cut short)
    try std.testing.expect(!valid(&c));
    wr32(&c, 0, 1);
    try std.testing.expect(!valid(c[0 .. c.len - 1]));
}

test "editors keep their numbers" {
    for ([_]u8{ 0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 13, 14, 15 }) |e| {
        var n = app.Node{ .editor = fromFile(e) };
        try std.testing.expectEqual(e, toFile(&n));
    }
    // (every number of the original's editors has one now: a number past them is "other")
    var n = app.Node{ .editor = fromFile(17), .raw_ed = 17 };
    try std.testing.expectEqual(app.Editor.other, n.editor);
    try std.testing.expectEqual(@as(u8, 17), toFile(&n));
    try std.testing.expectEqual(app.Editor.activity, fromFile(5));
    try std.testing.expectEqualStrings("Node Editor", otherLabel(8));
    try std.testing.expectEqualStrings("Unknown Editor", otherLabel(200));
}
