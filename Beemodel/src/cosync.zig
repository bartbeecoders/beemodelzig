// Live co-editing (cosync.s): peers edit one scene; a CRDT merges them.
//
// co.host [port] starts a session with the scene; co.join host:port joins one
// (the scene there replaces ours). Peers connect to any peer of the session -
// there is no server: every operation is relayed to the other connections,
// each kept once (by its origin peer and number).
//
// The document (a CRDT) mirrors the scene:
//   objects    an element each, a unique id (a timestamp of its making); alive
//              while its add time is later than its delete time (last writer
//              wins), in a sequence (RGA: each placed after the element before
//              it when made; newer first at one place)
//   properties name, material (by name), transform, hidden, colour: a
//              register each, last writer wins
//   meshes     a generation register (the topology) and, within a generation,
//              a register per vertex (its position)
//   materials  a register each, by name: their 15 values
// Timestamps are Lamport clocks with the peer's id below (a total order), so
// every peer settles every register the same way whatever order operations
// came in: all converge to the same document (cohash).
//
// Local edits become operations by comparing the scene with the document
// after every turn of the event loop; remote operations update the document
// and then the scene. Undo in a session is per author (the user's, the MCP
// agent's with co.agent on). Presence: each peer's name, colour, camera, 3D
// cursor and selection go to the others, who draw them; co.follow keeps your
// view on another's.
//
// The wire is the live link's: u32 length, u8 type, then here u16 origin peer,
// u32 its number, the payload. Every message and its byte layout is the
// original's (the documents of an original peer and a port peer converge).
//
// Deliberate differences (the original's memory errors on damaged input): a
// message too short for its type, a GEN whose counts do not fit its bytes, a
// VERTS range past the store (its 32-bit sum wraps there) and an RGA loop are
// passed over instead of read past the buffer; messages that came whole before
// a peer's end are applied before it goes.
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const ops = @import("ops.zig");
const m = @import("math.zig");
const ct = @import("cotree.zig");
const A = @import("alloc.zig").A;

// ---- limits, messages, records (cosync.s) ---------------------------------------
pub const CC_MAX = 8;
pub const BUF_CAP: usize = 64 * 1024 * 1024;
pub const CE_MAX = 4096;
pub const CM_MAX = 256;
const SEEN_N = 65536;
pub const PR_MAX = 16;
const UL_CAP: usize = 64 * 1024 * 1024;

pub const M_HELLO: u8 = 40;
pub const M_ADD: u8 = 41;
pub const M_DEL: u8 = 42;
pub const M_REG: u8 = 43;
pub const M_GEN: u8 = 44;
pub const M_VERTS: u8 = 45;
pub const M_MAT: u8 = 46;
pub const M_PRES: u8 = 47;
pub const M_AUTH: u8 = 53;

const K_NAME = 1;
const K_MAT = 2;
const K_XF = 3;
const K_FLAGS = 4;
const K_COLOR = 5;

pub const U_GROUP: u32 = 0;
const U_REG: u32 = 1;
const U_ADD: u32 = 2;
const U_DEL: u32 = 3;
const U_GEN: u32 = 4;
const U_VERTS: u32 = 5;
const U_MAT: u32 = 6;

const OT_MESH: u32 = 0;
const OT_LIGHT: u32 = 1;
const OT_CAMERA: u32 = 2;
const OBF_HIDDEN: u32 = 0x200;

const peer_cols = [8]u32{ 0x4fa3ff, 0xff7a45, 0x52d07a, 0xd977ff, 0xffd14a, 0x4ad8d8, 0xff5c8a, 0xa0a0ff };
const kdf_k0: u64 = std.mem.readInt(u64, "BeeModel", .little);
const kdf_k1: u64 = std.mem.readInt(u64, "co.key!!", .little);
const b32 = "abcdefghijkmnpqrstuvwxyz23456789";

const s_bad = "  co-editing: co.host [port] | lan [port]; co.join host:port";

// ---- the state ---------------------------------------------------------------------
pub var on: bool = false; // co_on: in a session
var lfd: i32 = -1; // the listener
pub var peer: u32 = 0; // our peer id (the user's; | 0x8000 the agent's)
var agentmode: bool = false;
/// A tool ran since the last capture (mcp.zig's tools/call sets it).
pub var mcp_touch: bool = false;
var seq: u32 = 0;
/// The peer followed (0: none).
pub var follow: u32 = 0;
var inited = false;
var presms: u32 = 0;
var preshash: u32 = 0;
var needorder = false;
var nag_new: u32 = 0;
var nagsel: u32 = 0;
var agstamp: u32 = 0;
var agsent: u32 = 0;
var agsel_new: [16]u64 = @splat(0);
var agsel: [16]u64 = @splat(0);
var clock: u64 = 0;
var key0: u64 = 0;
var key1: u64 = 0;
var keyset = false;
var mode: u32 = 0; // recording into: 0 undo, 1 redo
pub var author: u32 = 0; // 0 user, 1 agent
pub var n_ops: u64 = 0; // operations made
var n_applied: u64 = 0;

pub const Conn = struct {
    fd: i32 = -1,
    state: u8 = 0, // 0 free, 1 waiting (keyed: their AUTH), 2 in
    out: std.ArrayList(u8) = .empty,
    head: usize = 0,
    in: std.ArrayList(u8) = .empty,
    keyed: bool = false,
    nour: u64 = 0,
    nth: u64 = 0,
    k0: u64 = 0,
    k1: u64 = 0,
    sctr: u64 = 0,
    rctr: u64 = 0,
};
pub var cc: [CC_MAX]Conn = @splat(.{});

/// A mesh store: the original's layout (generation, counts, then positions,
/// their times, the polygon starts, loops, UVs), so its bytes hash and travel
/// as the original's.
const MS_HDR = 32;
fn msBytes(nv: u32, np: u32, nl: u32, uv: u32) u32 {
    var b: u32 = nv *% 20 +% np *% 4 +% 4 +% MS_HDR +% nl *% 4;
    if (uv != 0) b +%= nl *% 8;
    return b;
}
const Store = struct {
    d: []u8,
    fn gen(s: Store) u64 {
        return rd64(s.d, 0);
    }
    fn nv(s: Store) u32 {
        return rd32(s.d, 8);
    }
    fn np(s: Store) u32 {
        return rd32(s.d, 12);
    }
    fn nl(s: Store) u32 {
        return rd32(s.d, 16);
    }
    fn hasUv(s: Store) u32 {
        return rd32(s.d, 20);
    }
    fn posAt(_: Store) usize {
        return MS_HDR;
    }
    fn vtsAt(s: Store) usize {
        return MS_HDR + @as(usize, s.nv()) * 12;
    }
    fn poffAt(s: Store) usize {
        return MS_HDR + @as(usize, s.nv()) * 20;
    }
    fn loopsAt(s: Store) usize {
        return s.poffAt() + @as(usize, s.np()) * 4 + 4;
    }
    fn uvAt(s: Store) usize {
        return s.loopsAt() + @as(usize, s.nl()) * 4;
    }
    fn vts(s: Store, i: usize) u64 {
        return rd64(s.d, s.vtsAt() + i * 8);
    }
    fn setVts(s: Store, i: usize, t: u64) void {
        wr64(s.d, s.vtsAt() + i * 8, t);
    }
};
var stores: std.ArrayList([]u8) = .empty;

fn storeNew(bytes: u32) ?Store {
    if (bytes < MS_HDR) return null;
    stores.ensureUnusedCapacity(A, 1) catch return null;
    const d = A.alloc(u8, bytes) catch return null;
    @memset(d, 0);
    stores.appendAssumeCapacity(d);
    wr32(d, 24, bytes);
    return .{ .d = d };
}

pub const Elem = struct {
    id: u64 = 0,
    uid: u32 = 0, // its object here (0: none)
    typ: u32 = 0,
    add: u64 = 0,
    del: u64 = 0,
    after: u64 = 0,
    name_ts: u64 = 0,
    name: [32]u8 = @splat(0),
    mat_ts: u64 = 0,
    mat: [32]u8 = @splat(0),
    xf_ts: u64 = 0,
    xf: [36]u8 = @splat(0),
    fl_ts: u64 = 0,
    flags: [4]u8 = @splat(0),
    col_ts: u64 = 0,
    color: [4]u8 = @splat(0),
    gen_ts: u64 = 0,
    gen: u64 = 0,
    ms: ?Store = null, // its mesh store
    // the scene's mesh as last compared (slot, serial, shape)
    mslot: i32 = -1,
    mserial: u32 = 0,
    mshape: u32 = 0,

    fn alive(e: *const Elem) bool {
        return e.add > e.del;
    }
};
pub var ce: [CE_MAX]Elem = undefined;
pub var nce: usize = 0;

const Cm = struct {
    name: [32]u8 = @splat(0),
    ts: u64 = 0,
    val: [60]u8 = @splat(0),
    // the original's 104-byte record: name, time, values, 4 bytes of padding
    fn bytes(c: *const Cm) [104]u8 {
        var b: [104]u8 = @splat(0);
        @memcpy(b[0..32], &c.name);
        wr64(&b, 32, c.ts);
        @memcpy(b[40..100], &c.val);
        return b;
    }
};
var cm: [CM_MAX]Cm = undefined;
var ncm: usize = 0;

pub const Pres = struct {
    peer: u32 = 0,
    color: u32 = 0,
    name: [16]u8 = @splat(0),
    cam: [6]f32 = @splat(0), // yaw pitch dist tx ty tz (radians)
    cur: [3]f32 = @splat(0),
    nsel: u32 = 0,
    sel: [16]u64 = @splat(0),
};
pub var pr: [PR_MAX]Pres = @splat(.{});
pub var npr: usize = 0;

var seen: [SEEN_N]u64 = @splat(0);
var op: std.ArrayList(u8) = .empty; // a message being built
var op_bad = false;
var ul: [4]std.ArrayList(u8) = .{ .empty, .empty, .empty, .empty }; // undo / redo logs: user, agent
var order: [CE_MAX]u32 = undefined;

// ---- bytes ----------------------------------------------------------------------------
fn rd32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .little);
}
fn rd64(d: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, d[o..][0..8], .little);
}
fn rd16(d: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, d[o..][0..2], .little);
}
fn wr32(d: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, d[o..][0..4], v, .little);
}
fn wr64(d: []u8, o: usize, v: u64) void {
    std.mem.writeInt(u64, d[o..][0..8], v, .little);
}
fn cstr(b: []const u8) []const u8 {
    return std.mem.sliceTo(b, 0);
}

// ---- setup, clocks ------------------------------------------------------------------
fn init() void {
    if (inited) return;
    inited = true;
    const pid: u32 = @bitCast(@as(i32, @truncate(linux.getpid())));
    peer = ((pid *% 0x9E3779B1) >> 17) & 0x7fff | 1;
}

/// co_ts: a new timestamp, (clock + 1) << 16 | the author's peer.
pub fn ts() u64 {
    clock +%= 1;
    var p: u64 = peer;
    if (author != 0) p |= 0x8000;
    return (clock << 16) | p;
}

/// co_seen_ts: the clock past a timestamp seen.
pub fn seenTs(t: u64) void {
    const c = t >> 16;
    if (c > clock) clock = c;
}

// ---- messages out -------------------------------------------------------------------
/// mo_b: a new message: length, type, origin, number.
pub fn moB(t: u8) void {
    op.clearRetainingCapacity();
    op_bad = false;
    op.appendNTimes(A, 0, 11) catch {
        op_bad = true;
        return;
    };
    op.items[4] = t;
    var o: u32 = peer;
    if (author != 0) o |= 0x8000;
    std.mem.writeInt(u16, op.items[5..7], @truncate(o), .little);
    seq +%= 1;
    wr32(op.items, 7, seq);
}
pub fn moU32(v: u32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    moBytes(&b);
}
pub fn moU64(v: u64) void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    moBytes(&b);
}
pub fn moBytes(b: []const u8) void {
    if (op_bad) return;
    op.appendSlice(A, b) catch {
        op_bad = true;
    };
}
fn moLen() void {
    if (op.items.len >= 4) wr32(op.items, 0, @truncate(op.items.len - 4));
}
/// mo_send: the length in; to every connection; ours seen.
pub fn moSend() void {
    if (op_bad or op.items.len < 11) return;
    moLen();
    _ = seenAdd(rd16(op.items, 5), rd32(op.items, 7));
    n_ops +%= 1;
    toAll(op.items, null);
}

/// to_all: a message to every connection that is in (but one).
fn toAll(msg: []const u8, skip: ?usize) void {
    for (&cc, 0..) |*c, k| {
        if (skip != null and skip.? == k) continue;
        if (c.state != 2) continue;
        ccAppend(c, msg);
    }
}

/// seen_add: true when (origin, number) is new (kept).
fn seenAdd(origin: u32, num: u32) bool {
    const key: u64 = ((@as(u64, origin) << 32) | num) +% 1; // (0 means empty)
    var i: usize = @intCast(((key *% 0x9E3779B97F4A7C15) >> 40) & (SEEN_N - 1));
    var probe: u32 = 64; // a short probe; then overwritten
    while (true) {
        const v = seen[i];
        if (v == 0) break;
        if (v == key) return false;
        i = (i + 1) & (SEEN_N - 1);
        probe -= 1;
        if (probe == 0) break;
    }
    seen[i] = key;
    return true;
}

// ---- the document ---------------------------------------------------------------------
fn ceFind(id: u64) ?*Elem {
    for (ce[0..nce]) |*e| if (e.id == id) return e;
    return null;
}
/// ce_by_uid: the alive element its object is.
fn ceByUid(uid: u32) ?*Elem {
    for (ce[0..nce]) |*e| {
        if (e.uid == uid and e.del < e.add) return e;
    }
    return null;
}
fn ceNew(id: u64) ?*Elem {
    if (nce >= CE_MAX) return null;
    ce[nce] = .{ .id = id };
    nce += 1;
    return &ce[nce - 1];
}

/// The original's object type, or null for what co-editing leaves out.
fn otOf(k: scene.Kind) ?u32 {
    return switch (k) {
        .mesh, .cube, .sphere, .cylinder, .plane => OT_MESH,
        .light => OT_LIGHT,
        .camera => OT_CAMERA,
        else => null,
    };
}

/// ms_from_mesh: a store of a mesh (every vertex at that time).
fn msFromMesh(me: *const scene.Mesh, gen: u64, t: u64) ?Store {
    const nv: u32 = @intCast(me.verts.len);
    const np: u32 = me.faces();
    const nl: u32 = @intCast(me.loops.len);
    const uv: u32 = @intFromBool(me.uv.len > 0 and me.uv.len == me.loops.len);
    const s = storeNew(msBytes(nv, np, nl, uv)) orelse return null;
    wr64(s.d, 0, gen);
    wr32(s.d, 8, nv);
    wr32(s.d, 12, np);
    wr32(s.d, 16, nl);
    wr32(s.d, 20, uv);
    @memcpy(s.d[s.posAt()..][0 .. nv * 12], std.mem.sliceAsBytes(me.verts));
    for (0..nv) |i| s.setVts(i, t);
    @memcpy(s.d[s.poffAt()..][0 .. (np + 1) * 4], std.mem.sliceAsBytes(me.poff[0 .. np + 1]));
    @memcpy(s.d[s.loopsAt()..][0 .. nl * 4], std.mem.sliceAsBytes(me.loops));
    if (uv != 0) @memcpy(s.d[s.uvAt()..][0 .. nl * 8], std.mem.sliceAsBytes(me.uv));
    return s;
}

/// ms_mesh: a mesh slot built from a store (null: none).
fn msMesh(s: Store) ?u16 {
    const nv = s.nv();
    const pos: []align(1) const [3]f32 = std.mem.bytesAsSlice([3]f32, s.d[s.posAt()..][0 .. @as(usize, nv) * 12]);
    // (mesh_add_poly: a polygon of no loops is left out)
    var poff: std.ArrayList(u32) = .empty;
    defer poff.deinit(A);
    var loops: std.ArrayList(u32) = .empty;
    defer loops.deinit(A);
    var luv: std.ArrayList([2]f32) = .empty;
    defer luv.deinit(A);
    poff.append(A, 0) catch return null;
    const nl = s.nl();
    for (0..s.np()) |p| {
        const a = rd32(s.d, s.poffAt() + p * 4);
        const b = rd32(s.d, s.poffAt() + p * 4 + 4);
        if (b <= a or b > nl) continue;
        for (a..b) |l| {
            const v = rd32(s.d, s.loopsAt() + l * 4);
            if (v >= nv) return null; // (damaged: no mesh)
            loops.append(A, v) catch return null;
            if (s.hasUv() != 0) luv.append(A, .{ @bitCast(rd32(s.d, s.uvAt() + l * 8)), @bitCast(rd32(s.d, s.uvAt() + l * 8 + 4)) }) catch return null;
        }
        poff.append(A, @intCast(loops.items.len)) catch return null;
    }
    const vv = A.alloc(m.V3, nv) catch return null;
    defer A.free(vv);
    for (pos, 0..) |p, i| vv[i] = p;
    const mi = (if (nv == 0) scene.addEmptyMesh() else scene.addMesh(vv, poff.items, loops.items)) orelse return null;
    if (s.hasUv() != 0 and luv.items.len == loops.items.len and luv.items.len > 0) {
        const me = &scene.meshes[mi].?;
        me.uv = A.dupe([2]f32, luv.items) catch &.{};
    }
    return mi;
}

/// ms_same_topo: counts, starts, loops, UVs.
fn sameTopo(s: Store, me: *const scene.Mesh) bool {
    if (me.verts.len != s.nv() or me.faces() != s.np() or me.loops.len != s.nl()) return false;
    const uv: u32 = @intFromBool(me.uv.len > 0 and me.uv.len == me.loops.len);
    if (uv != s.hasUv()) return false;
    if (!std.mem.eql(u8, s.d[s.poffAt()..][0 .. (s.np() + 1) * 4], std.mem.sliceAsBytes(me.poff[0 .. s.np() + 1]))) return false;
    if (!std.mem.eql(u8, s.d[s.loopsAt()..][0 .. s.nl() * 4], std.mem.sliceAsBytes(me.loops))) return false;
    if (uv != 0 and !std.mem.eql(u8, s.d[s.uvAt()..][0 .. s.nl() * 8], std.mem.sliceAsBytes(me.uv))) return false;
    return true;
}

// ---- operations made here: applied to the document, sent, the inverse recorded ----------
/// ul_put: a record into the author's log (undo or redo as `mode` says).
pub fn ulPut(typ: u32, data: []const u8) void {
    const k = author * 2 + mode;
    const l = &ul[k];
    if (l.items.len + data.len + 8 >= UL_CAP) return;
    var h: [8]u8 = undefined;
    std.mem.writeInt(u32, h[0..4], typ, .little);
    std.mem.writeInt(u32, h[4..8], @intCast(data.len), .little);
    l.ensureUnusedCapacity(A, data.len + 8) catch return;
    l.appendSliceAssumeCapacity(&h);
    l.appendSliceAssumeCapacity(data);
}
fn ulGroup() void {
    ulPut(U_GROUP, &.{});
}

/// op_add: its add time anew: ADD (id, time, after, type).
fn opAdd(e: *Elem) void {
    e.add = ts();
    moB(M_ADD);
    moU64(e.id);
    moU64(e.add);
    moU64(e.after);
    moU32(e.typ);
    moSend();
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, e.id, .little);
    ulPut(U_DEL, &b); // (undo: delete it)
}

/// op_del: DELETE (id, time).
fn opDel(e: *Elem) void {
    e.del = ts();
    moB(M_DEL);
    moU64(e.id);
    moU64(e.del);
    moSend();
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, e.id, .little);
    ulPut(U_ADD, &b); // (undo: add it again)
}

const Slot = struct { t: *u64, v: []u8 };
/// reg_slot: a register's time and value (any other key: the colour's).
fn regSlot(e: *Elem, key: u32) Slot {
    return switch (key) {
        K_NAME => .{ .t = &e.name_ts, .v = &e.name },
        K_MAT => .{ .t = &e.mat_ts, .v = &e.mat },
        K_XF => .{ .t = &e.xf_ts, .v = &e.xf },
        K_FLAGS => .{ .t = &e.fl_ts, .v = &e.flags },
        else => .{ .t = &e.col_ts, .v = &e.color },
    };
}

/// op_reg: REG (id, time, key, 36 bytes); the old value recorded for undo.
fn opReg(e: *Elem, key: u32, val: []const u8) void {
    var rec: [48]u8 = @splat(0);
    wr64(&rec, 0, e.id);
    wr32(&rec, 8, key);
    const s = regSlot(e, key);
    @memcpy(rec[12..][0..s.v.len], s.v);
    @memcpy(s.v, val[0..s.v.len]);
    s.t.* = ts();
    moB(M_REG);
    moU64(e.id);
    moU64(s.t.*);
    moU32(key);
    var v36: [36]u8 = @splat(0);
    @memcpy(v36[0..s.v.len], s.v);
    moBytes(&v36);
    moSend();
    ulPut(U_REG, &rec);
}

/// op_gen: GEN (id, time, generation, counts, arrays); the old store kept for
/// undo.
fn opGen(e: *Elem, s: Store) void {
    const t = ts();
    e.gen_ts = t;
    e.gen = t;
    wr64(s.d, 0, t);
    for (0..s.nv()) |i| s.setVts(i, t);
    const old = e.ms;
    e.ms = s;
    msgGen(e);
    moSend();
    var rec: [16]u8 = @splat(0);
    wr64(&rec, 0, e.id);
    wr64(&rec, 8, storeRef(old));
    ulPut(U_GEN, &rec);
}

/// A store's reference in an undo record: its index in `stores` + 1 (0: none).
fn storeRef(s: ?Store) u64 {
    const x = s orelse return 0;
    var k = stores.items.len;
    while (k > 0) {
        k -= 1;
        if (stores.items[k].ptr == x.d.ptr) return k + 1;
    }
    return 0;
}
fn storeOf(r: u64) ?Store {
    if (r == 0 or r > stores.items.len) return null;
    return .{ .d = stores.items[@intCast(r - 1)] };
}

/// msg_gen: GEN from its store (built, not sent).
fn msgGen(e: *const Elem) void {
    const s = e.ms.?;
    moB(M_GEN);
    moU64(e.id);
    moU64(e.gen_ts);
    moU64(s.gen());
    moU32(s.nv());
    moU32(s.np());
    moU32(s.nl());
    moU32(s.hasUv());
    moBytes(s.d[s.posAt()..][0 .. @as(usize, s.nv()) * 12]); // positions (not their times)
    moBytes(s.d[s.poffAt()..]); // the rest
}

/// op_verts: the vertices that moved: VERTS (id, generation, time, ranges;
/// per range first, count, positions); the old positions recorded.
fn opVerts(e: *Elem, pos: []const m.V3) void {
    const s = e.ms orelse return;
    const t = ts();
    moB(M_VERTS);
    moU64(e.id);
    moU64(s.gen());
    moU64(t);
    const at_count = op.items.len;
    moU32(0);
    var ranges: u32 = 0;
    const nv: usize = s.nv();
    var i: usize = 0;
    while (i < nv) {
        if (vSame(e, s, pos, i)) {
            i += 1;
            continue;
        }
        const first = i; // a run of moved vertices
        i += 1;
        while (i < nv and !vSame(e, s, pos, i)) i += 1;
        moU32(@intCast(first));
        moU32(@intCast(i - first));
        for (first..i) |k| moBytes(std.mem.asBytes(&vAt(pos, k)));
        for (first..i) |k| { // the store takes them (times too)
            @memcpy(s.d[s.posAt() + k * 12 ..][0..12], std.mem.asBytes(&vAt(pos, k)));
            s.setVts(k, t);
        }
        ranges += 1;
    }
    if (!op_bad and op.items.len >= at_count + 4) wr32(op.items, at_count, ranges);
    if (ranges != 0) moSend();
}
fn vAt(pos: []const m.V3, k: usize) m.V3 {
    return if (k < pos.len) pos[k] else .{ 0, 0, 0 };
}
/// (.Lov_same) the scene's vertex is the store's? The old position is recorded
/// (U_VERTS) when it is not.
fn vSame(e: *Elem, s: Store, pos: []const m.V3, i: usize) bool {
    const p = std.mem.asBytes(&vAt(pos, i));
    const q = s.d[s.posAt() + i * 12 ..][0..12];
    if (std.mem.eql(u8, p, q)) return true;
    var rec: [24]u8 = undefined;
    wr64(&rec, 0, e.id);
    wr32(&rec, 8, @intCast(i));
    @memcpy(rec[12..24], q);
    ulPut(U_VERTS, &rec);
    return false;
}

/// op_mat: MAT (name, time, values) for a material record (name, values).
fn opMat(name: []const u8, val: []const u8) void {
    const c = cmFind(name) orelse cmNew(name) orelse return;
    const rec = c.bytes();
    ulPut(U_MAT, &rec); // undo: the old values
    @memcpy(&c.val, val[0..60]);
    c.ts = ts();
    msgMat(c);
    moSend();
}
fn msgMat(c: *const Cm) void {
    moB(M_MAT);
    moBytes(&c.name);
    moU64(c.ts);
    moBytes(&c.val);
}
fn cmFind(name: []const u8) ?*Cm {
    const n = cstr(name);
    for (cm[0..ncm]) |*c| if (std.mem.eql(u8, cstr(&c.name), n)) return c;
    return null;
}
fn cmNew(name: []const u8) ?*Cm {
    if (ncm >= CM_MAX) return null;
    cm[ncm] = .{};
    const n = @min(name.len, 31);
    @memcpy(cm[ncm].name[0..n], name[0..n]);
    ncm += 1;
    return &cm[ncm - 1];
}

// ---- capture: the scene's changes become operations ---------------------------------
/// The 31 bytes of an object's name the document takes (OB_NAME's).
fn objName31(o: *const scene.Object) []const u8 {
    return cstr(o.name_buf[0..31]);
}
/// The material name an object points at (31 bytes at most), or "".
fn objMatName(o: *const scene.Object) []const u8 {
    if (o.mat == 0) return "";
    const ma = material.get(o.mat - 1) orelse return "";
    return cstr(ma.name[0..31]);
}
fn objXf(o: *const scene.Object) [36]u8 {
    var b: [36]u8 = undefined;
    const r = o.radians();
    const v = [9]f32{ o.loc[0], o.loc[1], o.loc[2], r[0], r[1], r[2], o.scl[0], o.scl[1], o.scl[2] };
    @memcpy(&b, std.mem.asBytes(&v));
    return b;
}
fn meshKey(o: *const scene.Object) struct { slot: i32, serial: u32, shape: u32 } {
    const mi = o.mesh orelse return .{ .slot = -1, .serial = 0, .shape = 0 };
    const me = scene.meshes[mi] orelse return .{ .slot = -1, .serial = 0, .shape = 0 };
    return .{ .slot = mi, .serial = me.serial, .shape = me.shape };
}
fn keepKey(e: *Elem, o: *const scene.Object) void {
    const k = meshKey(o);
    e.mslot = k.slot;
    e.mserial = k.serial;
    e.mshape = k.shape;
}

/// co_capture: compare the scene with the document.
pub fn capture() void {
    const ops0 = n_ops;
    var touched = n_ops;
    nag_new = 0;
    var prev: u64 = 0; // the previous object's element id
    var oi: usize = 0;
    while (oi < scene.count) : (oi += 1) {
        const o = &scene.objects[oi];
        const typ = otOf(o.kind) orelse continue;
        var e: *Elem = undefined;
        if (ceByUid(o.uid)) |x| {
            e = x;
            capRegs(e, o);
            if (typ == OT_MESH) capMesh(e, o);
        } else {
            // new: an element, its registers, its mesh
            e = ceNew(ts()) orelse continue;
            e.uid = o.uid;
            e.typ = typ;
            e.after = prev;
            opAdd(e);
            capRegs(e, o);
            if (typ == OT_MESH) {
                if (o.mesh) |mi| {
                    if (scene.meshes[mi]) |*me| {
                        keepKey(e, o);
                        if (msFromMesh(me, 0, 0)) |s| opGen(e, s);
                    }
                }
            }
        }
        prev = e.id;
        if (n_ops != touched) { // touched by this capture: kept (the agent's selection)
            touched = n_ops;
            if (author == 1 and nag_new < 16) {
                agsel_new[nag_new] = prev;
                nag_new += 1;
            }
        }
    }
    // alive elements whose object went
    for (ce[0..nce]) |*e| {
        if (!e.alive() or e.uid == 0) continue;
        if (scene.findUid(e.uid) == null) opDel(e);
    }
    // materials: new or changed values
    var k: usize = 0;
    while (k < material.count) : (k += 1) {
        const ma = &material.list[k];
        const rb = std.mem.asBytes(ma);
        if (cmFind(rb[0..32])) |c| {
            if (std.mem.eql(u8, &c.val, rb[32..92])) continue;
        }
        opMat(rb[0..32], rb[32..92]);
    }
    ct.capture(); // node graphs
    if (n_ops == ops0) return;
    ulGroup(); // anything: the group ends
    if (nag_new != 0) { // the agent's: its selection now
        nagsel = nag_new;
        @memcpy(agsel[0..nag_new], agsel_new[0..nag_new]);
        agstamp +%= 1;
    }
}

/// .Lcc_regs: the registers that differ: an operation each.
fn capRegs(e: *Elem, o: *const scene.Object) void {
    var v: [36]u8 = @splat(0);
    const nm = objName31(o);
    if (!std.mem.eql(u8, nm, cstr(&e.name))) {
        @memcpy(v[0..31], o.name_buf[0..31]);
        opReg(e, K_NAME, &v);
    }
    v = @splat(0);
    const mn = objMatName(o);
    @memcpy(v[0..mn.len], mn);
    if (o.mat != 0) {
        if (material.get(o.mat - 1)) |ma| @memcpy(v[0..31], ma.name[0..31]);
    }
    if (!std.mem.eql(u8, mn, cstr(&e.mat))) opReg(e, K_MAT, &v);
    const xf = objXf(o);
    if (!std.mem.eql(u8, &xf, &e.xf)) opReg(e, K_XF, &xf);
    const hid: u32 = if (o.visible) 0 else OBF_HIDDEN;
    if (hid != rd32(&e.flags, 0)) {
        v = @splat(0);
        wr32(&v, 0, hid);
        opReg(e, K_FLAGS, &v);
    }
    if (o.color != rd32(&e.color, 0)) {
        v = @splat(0);
        wr32(&v, 0, o.color);
        opReg(e, K_COLOR, &v);
    }
}

/// The mesh: changed since it was last compared? Vertices moved, or a new topology.
fn capMesh(e: *Elem, o: *const scene.Object) void {
    const mi = o.mesh orelse return;
    const me = &(scene.meshes[mi] orelse return);
    const k = meshKey(o);
    if (k.slot == e.mslot and k.serial == e.mserial and k.shape == e.mshape) return;
    keepKey(e, o);
    if (e.ms) |s| {
        if (sameTopo(s, me)) return opVerts(e, me.verts);
    }
    const s = msFromMesh(me, 0, 0) orelse return;
    opGen(e, s);
}

// ---- remote operations: into the document, then the scene ----------------------------
/// The bytes a payload of each type needs (after the 11-byte header).
fn needBytes(t: u8, p: []const u8) ?usize {
    return switch (t) {
        M_ADD => 28,
        M_DEL => 16,
        M_REG => 56,
        M_GEN => blk: {
            if (p.len < 40) break :blk null;
            const nv: u64 = rd32(p, 24);
            const np: u64 = rd32(p, 28);
            const nl: u64 = rd32(p, 32);
            const uv: u64 = rd32(p, 36);
            const need = 40 + nv * 12 + (np + 1) * 4 + nl * 4 + (if (uv != 0) nl * 8 else 0);
            // (ms_bytes is 32-bit: a store that size could not be made)
            if (nv * 20 + np * 4 + 4 + MS_HDR + nl * 4 + (if (uv != 0) nl * 8 else 0) > 0xffffffff) break :blk null;
            break :blk @intCast(@min(need, std.math.maxInt(usize)));
        },
        M_VERTS => 28,
        M_MAT => 100,
        M_PRES => 60,
        else => ct.needBytes(t, p),
    };
}

/// Whether the scene was its undo step's before this tick's first remote
/// operation (then what they do goes into that step).
var clean_known = false;
var was_clean = false;

/// co_apply: one operation (the whole message).
fn apply(msg: []const u8) void {
    if (!clean_known) {
        clean_known = true;
        was_clean = @import("undo.zig").isClean();
    }
    n_applied +%= 1;
    const t = msg[4];
    const p = msg[11..];
    if (needBytes(t, p)) |need| {
        if (p.len < need) return; // (damaged: passed over)
    } else if (t >= 41 and t <= 52) return;
    switch (t) {
        M_ADD => {
            seenTs(rd64(p, 8));
            const id = rd64(p, 0);
            const e = ceFind(id) orelse blk: {
                const x = ceNew(id) orelse return;
                x.after = rd64(p, 16);
                x.typ = rd32(p, 24);
                break :blk x;
            };
            const at = rd64(p, 8);
            if (at <= e.add) return;
            e.add = at;
            matElem(e); // alive now: made here
            needorder = true;
        },
        M_DEL => {
            seenTs(rd64(p, 8));
            const id = rd64(p, 0);
            const e = ceFind(id) orelse ceNew(id) orelse return; // (before its ADD came: a tombstone)
            const at = rd64(p, 8);
            if (at <= e.del) return;
            e.del = at;
            matElem(e);
        },
        M_REG => {
            seenTs(rd64(p, 8));
            const id = rd64(p, 0);
            const e = ceFind(id) orelse ceNew(id) orelse return;
            const s = regSlot(e, rd32(p, 16));
            const at = rd64(p, 8);
            if (at <= s.t.*) return;
            s.t.* = at;
            @memcpy(s.v, p[20..][0..s.v.len]);
            matElem(e);
        },
        M_GEN => {
            seenTs(rd64(p, 8));
            const id = rd64(p, 0);
            const e = ceFind(id) orelse ceNew(id) orelse return;
            const at = rd64(p, 8);
            if (at <= e.gen_ts) return;
            e.gen_ts = at;
            e.gen = rd64(p, 16);
            const nv = rd32(p, 24);
            const np = rd32(p, 28);
            const nl = rd32(p, 32);
            const uv = rd32(p, 36);
            const s = storeNew(msBytes(nv, np, nl, uv)) orelse return;
            wr64(s.d, 0, rd64(p, 16));
            wr32(s.d, 8, nv);
            wr32(s.d, 12, np);
            wr32(s.d, 16, nl);
            wr32(s.d, 20, uv);
            @memcpy(s.d[s.posAt()..][0 .. @as(usize, nv) * 12], p[40..][0 .. @as(usize, nv) * 12]);
            for (0..nv) |i| s.setVts(i, at); // every vertex at the GEN's time
            const rest = s.d.len - s.poffAt();
            @memcpy(s.d[s.poffAt()..], p[40 + @as(usize, nv) * 12 ..][0..rest]);
            e.ms = s; // (the old one kept: undo may need it)
            matMesh(e);
        },
        M_VERTS => {
            seenTs(rd64(p, 16));
            const e = ceFind(rd64(p, 0)) orelse return;
            const s = e.ms orelse return;
            if (rd64(p, 8) != s.gen()) return; // (another generation: nothing)
            const at = rd64(p, 16);
            var n = rd32(p, 24);
            var o: usize = 28;
            while (n > 0) : (n -= 1) {
                if (o + 8 > p.len) break;
                const first: u64 = rd32(p, o);
                const count: u64 = rd32(p, o + 4);
                o += 8;
                if (first + count > s.nv()) break;
                if (o + count * 12 > p.len) break;
                var v = first;
                while (v < first + count) : (v += 1) {
                    const vi: usize = @intCast(v);
                    if (at > s.vts(vi)) { // newer than this vertex's?
                        s.setVts(vi, at);
                        @memcpy(s.d[s.posAt() + vi * 12 ..][0..12], p[o..][0..12]);
                    }
                    o += 12;
                }
            }
            matMesh(e);
        },
        M_MAT => {
            seenTs(rd64(p, 32));
            const c = cmFind(p[0..32]) orelse cmNew(cstr(p[0..32])) orelse return;
            const at = rd64(p, 32);
            if (at <= c.ts) return;
            c.ts = at;
            @memcpy(&c.val, p[40..100]);
            matMat(c);
        },
        M_PRES => presTake(p),
        else => ct.apply(t, p),
    }
}

// ---- materializing: the document into the scene -----------------------------------------
fn removeUid(uid: u32) void {
    const i = scene.findUid(uid) orelse return;
    removeAt(i);
}

/// An object removed by the document: the modes that hold an index follow.
fn removeAt(i: usize) void {
    const em = @import("editmesh.zig");
    const sc = @import("sculpt.zig");
    if (em.active and em.obj == i) em.exit();
    if (sc.on and sc.obj == i) sc.exit();
    scene.remove(i);
    if (em.active and em.obj > i) em.obj -= 1;
    if (sc.on and sc.obj > i) sc.obj -= 1;
    app.dirty = true;
}

/// mat_elem: its object as the document says (made, changed, removed).
fn matElem(e: *Elem) void {
    if (!e.alive()) {
        if (e.uid != 0) removeUid(e.uid);
        return;
    }
    var idx: ?usize = if (e.uid != 0) scene.findUid(e.uid) else null;
    if (idx == null) {
        // (not before its name, a mesh's topology: else ours would differ)
        if (e.name_ts == 0) return;
        if (e.typ == OT_MESH and e.ms == null) return;
        const kind: scene.Kind = switch (e.typ) {
            OT_LIGHT => .light,
            OT_CAMERA => .camera,
            OT_MESH => .mesh,
            else => return, // (a type co-editing does not carry: nothing made)
        };
        var mi: ?u16 = null;
        if (kind == .mesh) mi = msMesh(e.ms.?) orelse scene.addEmptyMesh() orelse return;
        if (scene.count >= scene.max_objects) return;
        var o = scene.Object{ .kind = kind, .mesh = mi };
        o.color = switch (kind) {
            .light => 0xe5c07b,
            .camera => 0x61afef,
            else => 0xb4b8c0,
        };
        o.setName(uniqueName(if (e.name[0] != 0) cstr(&e.name) else "user"));
        scene.objects[scene.count] = o;
        scene.stamp(scene.count);
        scene.count += 1;
        const i = scene.count - 1;
        e.uid = scene.objects[i].uid;
        keepKey(e, &scene.objects[i]);
        idx = i;
    }
    const o = &scene.objects[idx.?];
    // the registers into it (a name only when it differs: unique names)
    if (e.name[0] != 0 and !std.mem.eql(u8, o.name(), cstr(&e.name))) o.setName(cstr(e.name[0..31]));
    if (e.xf_ts != 0) {
        const f: [9]f32 = @bitCast(e.xf);
        o.loc = .{ f[0], f[1], f[2] };
        o.setRadians(.{ f[3], f[4], f[5] });
        o.scl = .{ f[6], f[7], f[8] };
    }
    o.visible = rd32(&e.flags, 0) & OBF_HIDDEN == 0;
    if (e.col_ts != 0) o.color = rd32(&e.color, 0);
    o.mat = if (matEnsure(&e.mat)) |k| @intCast(k + 1) else 0; // material by name (made if needed)
    app.dirty = true;
}

/// obj_new's unique_name: the name, or with .001, .002 ... until no object has it.
fn uniqueName(want: []const u8) []const u8 {
    const S = struct {
        var buf: [32]u8 = undefined;
    };
    if (!taken(want)) return want;
    const n = @min(want.len, 26);
    var k: u32 = 1;
    while (k <= 999) : (k += 1) {
        const s = std.fmt.bufPrint(&S.buf, "{s}.{d:0>3}", .{ want[0..n], k }) catch return want;
        if (!taken(s)) return s;
    }
    return want;
}
fn taken(s: []const u8) bool {
    for (scene.objects[0..scene.count]) |*o| if (std.mem.eql(u8, o.name(), s)) return true;
    return false;
}

/// mat_ensure: the material's index (made when missing; null: "").
fn matEnsure(name: []const u8) ?usize {
    const n = cstr(name);
    if (n.len == 0) return null;
    if (material.find(n)) |k| return k;
    return material.new(n);
}

/// mat_mesh: its object's mesh built again from the store.
fn matMesh(e: *Elem) void {
    if (!e.alive()) return;
    const i = (if (e.uid != 0) scene.findUid(e.uid) else null) orelse return matElem(e);
    const o = &scene.objects[i];
    if (otOf(o.kind) != OT_MESH) return;
    const s = e.ms orelse return;
    const mi = msMesh(s) orelse return;
    o.mesh = mi;
    keepKey(e, o);
    @import("editmesh.zig").version +%= 1;
    app.dirty = true;
}

/// mat_mat: the scene's material of that name takes its values (made).
fn matMat(c: *const Cm) void {
    const k = matEnsure(&c.name) orelse return;
    const ma = &material.list[k];
    const b = std.mem.asBytes(ma);
    @memcpy(b[0..31], c.name[0..31]);
    b[31] = 0;
    @memcpy(b[32..92], &c.val);
    material.version +%= 1;
    app.dirty = true;
}

/// co_order_build: the alive elements in the sequence's order (RGA: under each
/// element its later insertions first).
fn orderBuild() usize {
    var n: usize = 0;
    // children of each element, newest first (a sort by after, then id down)
    var idx: [CE_MAX]u32 = undefined;
    for (0..nce) |i| idx[i] = @intCast(i);
    const Ctx = struct {
        fn lt(_: void, a: u32, b: u32) bool {
            const x = &ce[a];
            const y = &ce[b];
            if (x.after != y.after) return x.after < y.after;
            return x.id > y.id;
        }
    };
    std.sort.pdq(u32, idx[0..nce], {}, Ctx.lt);
    // a depth-first walk from the head (after = 0); ids 0 and all-ones are never
    // taken, as the original's walk does not take them
    var visited: [CE_MAX]bool = undefined;
    @memset(visited[0..nce], false);
    var stack: [CE_MAX + 1]struct { id: u64, at: usize } = undefined;
    var sp: usize = 1;
    stack[0] = .{ .id = 0, .at = firstChild(idx[0..nce], 0) };
    while (sp > 0) {
        const top = &stack[sp - 1];
        if (top.at >= nce or ce[idx[top.at]].after != top.id) {
            sp -= 1;
            continue;
        }
        const k = idx[top.at];
        top.at += 1;
        const e = &ce[k];
        if (e.id == 0 or e.id == std.math.maxInt(u64) or visited[k]) continue;
        visited[k] = true;
        if (e.alive()) {
            order[n] = k;
            n += 1;
        }
        if (sp <= CE_MAX) {
            stack[sp] = .{ .id = e.id, .at = firstChild(idx[0..nce], e.id) };
            sp += 1;
        }
    }
    return n;
}
fn firstChild(idx: []const u32, id: u64) usize {
    var lo: usize = 0;
    var hi: usize = idx.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (ce[idx[mid]].after < id) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// co_reorder: the object list in the sequence's order (others after).
fn reorder() void {
    const n = orderBuild();
    var place: usize = 0;
    for (order[0..n]) |k| {
        const uid = ce[k].uid;
        if (uid == 0) continue;
        const at = scene.findUid(uid) orelse continue;
        if (at < place) continue;
        if (at != place) moveObject(at, place);
        place += 1;
    }
    app.dirty = true;
}

/// Object `from` to index `to` (< from), the ones between one down; whatever
/// holds an index follows.
fn moveObject(from: usize, to: usize) void {
    const map = struct {
        fn f(i: usize, a: usize, b: usize) usize {
            if (i == a) return b;
            if (i >= b and i < a) return i + 1;
            return i;
        }
    }.f;
    const keep = scene.objects[from];
    var i = from;
    while (i > to) : (i -= 1) scene.objects[i] = scene.objects[i - 1];
    scene.objects[to] = keep;
    for (scene.objects[0..scene.count]) |*o| {
        if (o.parent) |p| o.parent = @intCast(map(p, from, to));
    }
    if (scene.active) |a| scene.active = map(a, from, to);
    if (scene.render_camera) |c| scene.render_camera = map(c, from, to);
    const em = @import("editmesh.zig");
    const sc = @import("sculpt.zig");
    if (em.active) em.obj = map(em.obj, from, to);
    if (sc.on) sc.obj = map(sc.obj, from, to);
}

// ---- the document's hash ------------------------------------------------------------------
const Fnv = struct {
    h: u64 = 0xcbf29ce484222325,
    pub fn mix(f: *Fnv, b: []const u8) void {
        for (b) |c| {
            f.h ^= c;
            f.h *%= 0x100000001b3;
        }
    }
};

/// co_hash_doc: the alive objects in sequence order (id, type, registers, the
/// mesh: generation, counts, positions, the rest), the materials by name, the
/// node graphs.
pub fn hashDoc() u64 {
    var f = Fnv{};
    const n = orderBuild();
    for (order[0..n]) |k| {
        const e = &ce[k];
        f.mix(std.mem.asBytes(&e.id));
        f.mix(std.mem.asBytes(&e.typ));
        f.mix(&e.name);
        f.mix(&e.mat);
        f.mix(&e.xf);
        f.mix(&e.flags);
        f.mix(&e.color);
        if (e.ms) |s| {
            f.mix(s.d[0..24]);
            f.mix(s.d[s.posAt()..][0 .. @as(usize, s.nv()) * 12]);
            f.mix(s.d[s.poffAt()..]);
        }
    }
    // materials: by name, smallest first (name, time, the first 56 bytes of values)
    var mi: [CM_MAX]u32 = undefined;
    for (0..ncm) |i| mi[i] = @intCast(i);
    std.sort.pdq(u32, mi[0..ncm], {}, struct {
        fn lt(_: void, a: u32, b: u32) bool {
            return strLess(cstr(&cm[a].name), cstr(&cm[b].name));
        }
    }.lt);
    for (mi[0..ncm]) |k| {
        const b = cm[k].bytes();
        f.mix(b[0..96]);
    }
    ct.hash(&f);
    return f.h;
}
pub fn strLess(a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
pub const Hasher = Fnv;

// ---- the session: hosting, joining, the network ----------------------------------------
pub const list = [_]struct { []const u8, ops.Impl }{
    .{ "co.host", ops.Impl{ .run = opHost } },
    .{ "co.join", ops.Impl{ .run = opJoin } },
    .{ "co.leave", ops.Impl{ .run = opLeave } },
    .{ "co.follow", ops.Impl{ .run = opFollow } },
    .{ "co.key", ops.Impl{ .run = opKey } },
    .{ "co.agent", ops.Impl{ .run = opAgent } },
};

const SockAddr = extern struct { family: u16, port: u16, addr: u32, zero: [8]u8 = @splat(0) };

/// co.host [port] | lan [port]
fn opHost() void {
    init();
    if (!on) reset();
    if (lfd >= 0) {
        _ = linux.close(lfd);
        lfd = -1;
    }
    var addr: u32 = 0x0100007f; // 127.0.0.1 (network order)
    var port: i32 = 7462;
    var w = @import("ntree.zig").Words{ .s = ops.arg };
    var word = w.next();
    if (word.len > 0) {
        var ok = true;
        if (std.mem.eql(u8, word, "lan")) {
            addr = 0;
            word = w.next();
            if (word.len == 0) ok = false;
        }
        if (ok) {
            const f = @import("ntree.zig").parseFloat(word, null) orelse return app.log(s_bad, .{});
            port = @import("ntree.zig").cvtt(f);
        }
    }
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return app.log(s_bad, .{});
    const fd: i32 = @intCast(rc);
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    const p16: u16 = @truncate(@as(u32, @bitCast(port)));
    const sa = SockAddr{ .family = linux.AF.INET, .port = @byteSwap(p16), .addr = addr };
    if (linux.errno(linux.bind(fd, @ptrCast(&sa), 16)) != .SUCCESS or linux.errno(linux.listen(fd, CC_MAX)) != .SUCCESS) {
        _ = linux.close(fd);
        return app.log(s_bad, .{});
    }
    lfd = fd;
    if (!on) {
        on = true;
        capture(); // the scene: the document's start
        // (the scene as it was is not an edit of the user's: Ctrl+Z in the
        // session does not take it all away, as the original's would)
        ul[0].clearRetainingCapacity();
    }
    app.log("  co-editing: hosting on {d}", .{port});
}

/// co.key <pass phrase> | new | off
fn opKey() void {
    var a = ops.arg;
    while (a.len > 0 and a[0] == ' ') a = a[1..];
    if (a.len > 0 and a[0] != 0) {
        a = cstr(a);
        var shown = false;
        var nb: [24]u8 = undefined;
        if (std.mem.eql(u8, a, "off")) {
            keyset = false;
            return showKey();
        } else if (std.mem.eql(u8, a, "new")) {
            // 20 random letters, a dash after every fifth
            var r: [20]u8 = undefined;
            _ = linux.getrandom(&r, 20, 0);
            var n: usize = 0;
            for (r, 0..) |c, k| {
                nb[n] = b32[c & 31];
                n += 1;
                if (k + 1 < 20 and (k + 1) % 5 == 0) {
                    nb[n] = '-';
                    n += 1;
                }
            }
            a = nb[0..n];
            app.log("  co-editing: session key: {s}", .{a});
            shown = true;
        } else if (a.len < 8) {
            return app.log("  co-editing: a session key has 8 characters at least (co.key new makes one)", .{});
        }
        key0 = siphash(a, kdf_k0, kdf_k1, 0);
        key1 = siphash(a, kdf_k0, kdf_k1, 1);
        keyset = true;
        if (shown) return;
    }
    showKey();
}
fn showKey() void {
    if (keyset) app.log("  co-editing: session key set (for sessions hosted or joined from now on)", .{}) else app.log("  co-editing: no session key: anyone who can reach the port can join", .{});
}

/// co_reset: no session: connections closed, the document empty.
fn reset() void {
    for (&cc) |*c| {
        if (c.state != 0) ccDrop(c);
    }
    if (lfd >= 0) {
        _ = linux.close(lfd);
        lfd = -1;
    }
    for (stores.items) |d| A.free(d); // stores let go
    stores.clearRetainingCapacity();
    nce = 0;
    ncm = 0;
    ct.reset();
    npr = 0;
    on = false;
    follow = 0;
    for (&ul) |*l| l.clearRetainingCapacity();
    @memset(&seen, 0);
}

fn ccDrop(c: *Conn) void {
    if (c.fd >= 0) _ = linux.close(c.fd);
    c.fd = -1;
    c.state = 0;
    c.head = 0;
    c.out.clearRetainingCapacity();
    c.in.clearRetainingCapacity();
    if (c.out.capacity > 1 << 20) c.out.clearAndFree(A);
    if (c.in.capacity > 1 << 20) c.in.clearAndFree(A);
}

/// co.join host:port
fn opJoin() void {
    init();
    reset();
    const arg = ops.arg;
    if (arg.len == 0) return app.log("  co-editing: could not join {s}", .{s_bad});
    const hp = parseHp(arg) orelse return app.log("  co-editing: could not join {s}", .{arg});
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return app.log("  co-editing: could not join {s}", .{arg});
    const fd: i32 = @intCast(rc);
    const sa = SockAddr{ .family = linux.AF.INET, .port = @byteSwap(@as(u16, @truncate(hp.port))), .addr = hp.addr };
    if (linux.errno(linux.connect(fd, @ptrCast(&sa), 16)) != .SUCCESS) {
        _ = linux.close(fd);
        return app.log("  co-editing: could not join {s}", .{arg});
    }
    const c = ccSetup(fd) orelse {
        _ = linux.close(fd);
        return app.log("  co-editing: could not join {s}", .{arg});
    };
    sceneClear(); // their scene replaces ours
    on = true;
    ccHello(c);
    app.log("  co-editing: joined {s}", .{arg});
}

/// scene_clear: every object, material, node tree ... gone (the cursor stays).
fn sceneClear() void {
    const cur = scene.cursor;
    scene.reset();
    scene.count = 0;
    scene.active = null;
    scene.render_camera = null;
    scene.uid_next = 1;
    scene.cursor = cur;
    app.dirty = true;
}

/// co_parse_hp: "a.b.c.d:port" or "localhost:port".
fn parseHp(s: []const u8) ?struct { addr: u32, port: u32 } {
    var i: usize = 0;
    var addr: u32 = 0;
    if (s.len >= 4 and std.mem.eql(u8, s[0..4], "loca")) {
        addr = 0x0100007f;
        i = 9;
    } else {
        var part: u5 = 0;
        while (true) {
            var v: u32 = 0;
            var nd: u32 = 0;
            while (i < s.len and s[i] -% '0' <= 9) : (i += 1) {
                v = v *% 10 +% (s[i] - '0');
                nd += 1;
            }
            if (nd == 0) return null;
            addr |= v << (part * 8);
            part += 1;
            if (part >= 4) break;
            if (i >= s.len or s[i] != '.') return null;
            i += 1;
        }
    }
    if (i >= s.len or s[i] != ':') return null;
    i += 1;
    var port: u32 = 0;
    var nd: u32 = 0;
    while (i < s.len and s[i] -% '0' <= 9) : (i += 1) {
        port = port *% 10 +% (s[i] - '0');
        nd += 1;
    }
    if (nd == 0) return null;
    return .{ .addr = addr, .port = port };
}

/// cc_setup: a connection for a socket (no delay, non-blocking).
fn ccSetup(fd: i32) ?*Conn {
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), 4);
    _ = linux.fcntl(fd, linux.F.SETFL, 0x800);
    for (&cc) |*c| {
        if (c.state != 0) continue;
        c.fd = fd;
        c.state = 1;
        c.keyed = false;
        c.sctr = 0;
        c.rctr = 0;
        c.head = 0;
        c.out.clearRetainingCapacity();
        c.in.clearRetainingCapacity();
        return c;
    }
    return null;
}

/// cc_hello: our HELLO first in its output, then (it is in) all we have.
fn ccHello(c: *Conn) void {
    moB(M_HELLO);
    moBytes("BEEL");
    moU32(1 | (2 << 16)); // version 1, role 2 (a co-editor)
    if (keyset) {
        // keyed: a nonce; the document only once their AUTH checks out
        var nb: [8]u8 = undefined;
        _ = linux.getrandom(&nb, 8, 0);
        c.nour = std.mem.readInt(u64, &nb, .little);
        moU64(c.nour);
    }
    moLen();
    if (!op_bad) ccAppend(c, op.items);
    if (keyset) return;
    c.state = 2;
    author = 0;
    sendState(c);
}

/// cc_append: into a connection's output; on a keyed one with its tag after it
/// (the length counting it).
fn ccAppend(c: *Conn, msg: []const u8) void {
    if (c.out.items.len + msg.len + 8 > BUF_CAP) return;
    c.out.ensureUnusedCapacity(A, msg.len + 8) catch return;
    const at = c.out.items.len;
    c.out.appendSliceAssumeCapacity(msg);
    if (!c.keyed) return;
    const cp = c.out.items[at..];
    wr32(cp, 0, rd32(cp, 0) +% 8);
    const tag = siphash(cp[4..], c.k0, c.k1, prefix(c, false));
    var tb: [8]u8 = undefined;
    std.mem.writeInt(u64, &tb, tag, .little);
    c.out.appendSliceAssumeCapacity(&tb);
    c.sctr +%= 1;
}

/// cc_prefix: a tag's first word: the counter, and which way (bit 63: from the
/// side whose nonce is lower).
fn prefix(c: *const Conn, receiving: bool) u64 {
    var a = c.nour;
    var b = c.nth;
    var r = c.sctr;
    if (receiving) {
        r = c.rctr;
        std.mem.swap(u64, &a, &b);
    }
    if (a < b) r |= 1 << 63;
    return r;
}

/// cc_derive: a connection's key: SipHash of both nonces (the lower first)
/// under the session key.
fn derive(c: *Conn) void {
    var lo = c.nour;
    var hi = c.nth;
    if (lo > hi) std.mem.swap(u64, &lo, &hi);
    var b: [16]u8 = undefined;
    wr64(&b, 0, lo);
    wr64(&b, 8, hi);
    c.k0 = siphash(&b, key0, key1, 1);
    c.k1 = siphash(&b, key0, key1, 2);
    c.keyed = true;
}

/// siphash: SipHash-2-4 of a word (8 bytes, little-endian) and then the data.
pub fn siphash(data: []const u8, k0: u64, k1: u64, word: u64) u64 {
    var v0: u64 = 0x736f6d6570736575 ^ k0;
    var v1: u64 = 0x646f72616e646f6d ^ k1;
    var v2: u64 = 0x6c7967656e657261 ^ k0;
    var v3: u64 = 0x7465646279746573 ^ k1;
    const R = struct {
        fn round(a: *u64, b: *u64, c: *u64, d: *u64) void {
            a.* +%= b.*;
            b.* = std.math.rotl(u64, b.*, 13);
            b.* ^= a.*;
            a.* = std.math.rotl(u64, a.*, 32);
            c.* +%= d.*;
            d.* = std.math.rotl(u64, d.*, 16);
            d.* ^= c.*;
            a.* +%= d.*;
            d.* = std.math.rotl(u64, d.*, 21);
            d.* ^= a.*;
            c.* +%= b.*;
            b.* = std.math.rotl(u64, b.*, 17);
            b.* ^= c.*;
            c.* = std.math.rotl(u64, c.*, 32);
        }
        fn mixw(x: u64, a: *u64, b: *u64, c: *u64, d: *u64) void {
            d.* ^= x;
            round(a, b, c, d);
            round(a, b, c, d);
            a.* ^= x;
        }
    };
    R.mixw(word, &v0, &v1, &v2, &v3);
    var d = data;
    while (d.len >= 8) : (d = d[8..]) R.mixw(std.mem.readInt(u64, d[0..8], .little), &v0, &v1, &v2, &v3);
    var last: u64 = 0;
    var k = d.len;
    while (k > 0) {
        k -= 1;
        last = (last << 8) | d[k];
    }
    last |= @as(u64, @truncate(data.len + 8)) << 56;
    R.mixw(last, &v0, &v1, &v2, &v3);
    v2 ^= 0xff;
    for (0..4) |_| R.round(&v0, &v1, &v2, &v3);
    return v0 ^ v1 ^ v2 ^ v3;
}

/// The 36 value bytes send_state puts after a register's key: the original
/// sends 36 bytes from the register's place in its element record (the bytes
/// after a shorter value are the record's next fields; its mesh store's address
/// is not ours to give: zero).
fn regWire(e: *const Elem, key: u32) [36]u8 {
    var b: [36]u8 = @splat(0);
    switch (key) {
        K_NAME => {
            @memcpy(b[0..32], &e.name);
            wr32(&b, 32, @truncate(e.mat_ts));
        },
        K_MAT => {
            @memcpy(b[0..32], &e.mat);
            wr32(&b, 32, @truncate(e.xf_ts));
        },
        K_XF => @memcpy(&b, &e.xf),
        K_FLAGS => {
            @memcpy(b[0..4], &e.flags);
            wr64(&b, 8, e.col_ts);
            @memcpy(b[16..20], &e.color);
            wr64(&b, 24, e.gen_ts);
            wr32(&b, 32, @truncate(e.gen));
        },
        else => {
            @memcpy(b[0..4], &e.color);
            wr64(&b, 8, e.gen_ts);
            wr64(&b, 16, e.gen);
        },
    }
    return b;
}

/// send_state: every element and material, as operations with their own times
/// (idempotent wherever they land).
fn sendState(c: *Conn) void {
    for (ce[0..nce]) |*e| {
        moB(M_ADD);
        moU64(e.id);
        moU64(e.add);
        moU64(e.after);
        moU32(e.typ);
        stPut(c);
        if (e.del != 0) {
            moB(M_DEL);
            moU64(e.id);
            moU64(e.del);
            stPut(c);
        }
        var key: u32 = K_NAME;
        while (key <= K_COLOR) : (key += 1) {
            const s = regSlot(e, key);
            if (s.t.* == 0) continue;
            moB(M_REG);
            moU64(e.id);
            moU64(s.t.*);
            moU32(key);
            const v = regWire(e, key);
            moBytes(&v);
            stPut(c);
        }
        if (e.ms) |s| {
            msgGen(e);
            stPut(c);
            // vertices newer than their generation: a VERTS each
            for (0..s.nv()) |i| {
                const t = s.vts(i);
                if (t <= e.gen_ts) continue;
                moB(M_VERTS);
                moU64(e.id);
                moU64(s.gen());
                moU64(t);
                moU32(1);
                moU32(@intCast(i));
                moU32(1);
                moBytes(s.d[s.posAt() + i * 12 ..][0..12]);
                stPut(c);
            }
        }
    }
    for (cm[0..ncm]) |*x| {
        msgMat(x);
        stPut(c);
    }
    ct.sendState(c);
}
/// st_put: the message (length in) to a connection's output.
pub fn stPut(c: *Conn) void {
    if (op_bad) return;
    moLen();
    ccAppend(c, op.items);
}

/// co.leave
fn opLeave() void {
    init();
    reset();
    app.log("  co-editing: left the session", .{});
}

/// co.agent on|off
fn opAgent() void {
    agentmode = true;
    var w = @import("ntree.zig").Words{ .s = ops.arg };
    if (std.mem.eql(u8, w.next(), "off")) {
        agentmode = false;
        return;
    }
    app.log("  co-editing: what tools do is the agent's", .{});
}

/// co.follow <peer name | number> | off
fn opFollow() void {
    follow = 0;
    var w = @import("ntree.zig").Words{ .s = ops.arg };
    const word = w.next();
    if (ops.arg.len == 0 or std.mem.eql(u8, word, "off")) return;
    var k: ?usize = null;
    for (pr[0..npr], 0..) |*p, i| {
        if (std.mem.eql(u8, cstr(&p.name), word)) {
            k = i;
            break;
        }
    }
    if (k == null) {
        if (@import("ntree.zig").parseFloat(word, null)) |f| {
            const n = @import("ntree.zig").cvtt(f) -% 1;
            if (n >= 0 and n < npr) k = @intCast(n);
        }
    }
    const i = k orelse return app.log("  co-editing: no such peer: {s}", .{word});
    follow = pr[i].peer;
    app.log("  co-editing: following {s}", .{word});
}

// ---- the tick -------------------------------------------------------------------------------
/// co_tick: (main loop) connections in, operations applied and relayed, the
/// scene's changes out (the user's or the agent's), presence, output.
pub fn tick() void {
    if (!on) return;
    const undo = @import("undo.zig");
    const applied0 = n_applied;
    clean_known = false;
    accept();
    read();
    ct.buildDirty(); // (node graphs changed by others)
    if (needorder) {
        needorder = false;
        reorder();
    }
    // (what others did is no undo step of ours: the step the scene is at takes it)
    if (n_applied != applied0 and was_clean) undo.replaceCurrent();
    author = if (agentmode and mcp_touch) 1 else 0;
    mcp_touch = false;
    mode = 0;
    capture();
    author = 0;
    presTick();
    flush();
}

fn accept() void {
    if (lfd < 0) return;
    while (true) {
        const rc = linux.accept4(lfd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return;
        const fd: i32 = @intCast(rc);
        const c = ccSetup(fd) orelse {
            _ = linux.close(fd);
            continue;
        };
        ccHello(c); // ours to them now: HELLO, the state
        app.log("  co-editing: a peer joined", .{});
    }
}

/// co_read: every connection: what came; whole messages applied, relayed.
fn read() void {
    for (&cc, 0..) |*c, k| {
        if (c.state == 0) continue;
        var ended = false;
        while (true) {
            const room = BUF_CAP - c.in.items.len;
            if (room == 0) break;
            const want = @min(BUF_CAP, @max(c.in.items.len + 65536, c.in.capacity));
            c.in.ensureTotalCapacity(A, want) catch break;
            const spare = c.in.allocatedSlice()[c.in.items.len..];
            const n = @min(spare.len, room);
            const rc = linux.read(c.fd, spare.ptr, n);
            const e = linux.errno(rc);
            if (e == .AGAIN or e == .INTR) break;
            if (e != .SUCCESS or rc == 0) {
                ended = true;
                break;
            }
            c.in.items.len += rc;
        }
        if (!messages(c, k)) continue; // (refused)
        if (ended) {
            ccDrop(c);
            app.log("  co-editing: a peer left", .{});
        }
    }
}

/// The whole messages in a connection's input; false when it was refused.
fn messages(c: *Conn, k: usize) bool {
    var off: usize = 0;
    while (true) {
        const buf = c.in.items;
        if (buf.len - off < 4) break;
        const sent: usize = rd32(buf, off);
        if (buf.len - off < sent + 4) break;
        var n = sent;
        const msg = buf[off .. off + sent + 4];
        defer off += sent + 4;
        if (c.keyed) {
            // keyed: its tag checked, then taken off
            if (n < 15) return refuse(c);
            const tag = siphash(msg[4 .. n - 4], c.k0, c.k1, prefix(c, true));
            if (tag != rd64(msg, n - 4)) return refuse(c);
            c.rctr +%= 1;
            n -= 8;
            wr32(msg, 0, @intCast(n));
        }
        if (n < 7) continue; // (too short: skipped)
        const t = msg[4];
        if (t == M_HELLO) {
            // keyed: their nonce, our AUTH back
            if (!keyset) continue;
            if (c.keyed) return refuse(c);
            if (n < 23) return refuse(c); // (no nonce: they have no key)
            c.nth = rd64(msg, 19);
            derive(c);
            moB(M_AUTH);
            moLen();
            if (!op_bad) ccAppend(c, op.items);
            continue;
        }
        if (t == M_AUTH) {
            // keyed, and it checked out: in
            if (!c.keyed or c.state != 1) continue;
            c.state = 2;
            author = 0;
            sendState(c);
            preshash ^= 1; // (presence sent before it got nowhere: again, the agent's too)
            if (agstamp != 0) agsent -%= 1;
            continue;
        }
        if (n < 10) continue;
        if (keyset and c.state != 2) return refuse(c); // keyed: nothing before the AUTH
        const whole = msg[0 .. n + 4];
        if (!seenAdd(rd16(whole, 5), rd32(whole, 7))) continue; // once each: applied, relayed
        apply(whole);
        toAll(whole, k);
    }
    // the rest to the front
    const rest = c.in.items.len - off;
    std.mem.copyForwards(u8, c.in.items[0..rest], c.in.items[off..]);
    c.in.items.len = rest;
    return true;
}

fn refuse(c: *Conn) bool {
    ccDrop(c);
    app.log("  co-editing: refused a peer (no session key, or another one)", .{});
    return false;
}

/// co_flush: each connection's output, as its socket takes it.
fn flush() void {
    for (&cc) |*c| {
        if (c.state == 0) continue;
        while (c.head < c.out.items.len) {
            const d = c.out.items[c.head..];
            const rc = linux.sendto(c.fd, d.ptr, d.len, linux.MSG.NOSIGNAL, null, 0);
            const e = linux.errno(rc);
            if (e == .AGAIN or e == .INTR) break;
            if (e != .SUCCESS or rc == 0) {
                ccDrop(c);
                break;
            }
            c.head += rc;
        }
        if (c.state != 0 and c.head >= c.out.items.len) {
            c.head = 0;
            c.out.clearRetainingCapacity();
            if (c.out.capacity > 1 << 22) c.out.clearAndFree(A);
        }
    }
}

/// co_pollfds: the listener and the connections (entries written).
pub fn pollfds(p: []linux.pollfd) usize {
    if (!on) return 0;
    var n: usize = 0;
    if (lfd >= 0 and n < p.len) {
        p[n] = .{ .fd = lfd, .events = linux.POLL.IN, .revents = 0 };
        n += 1;
    }
    for (&cc) |*c| {
        if (c.state == 0 or n >= p.len) continue;
        var ev: i16 = linux.POLL.IN;
        if (c.out.items.len != c.head) ev |= linux.POLL.OUT;
        p[n] = .{ .fd = c.fd, .events = ev, .revents = 0 };
        n += 1;
    }
    return n;
}
pub const MAX_FDS = 1 + CC_MAX;

// ---- undo per author --------------------------------------------------------------------
/// co_undo_hook / co_redo_hook: true when a session took Ctrl+Z (or redo): the
/// author's last group undone (the agent's when a tool asks, co.agent on).
pub fn undoHook(redo: bool) bool {
    if (!on) return false;
    undoGo(redo);
    // (in a session what undo did is no step of the scene's history either)
    @import("undo.zig").replaceCurrent();
    app.dirty = true;
    return true;
}

/// co_undo_go: the author's last group from that log, its records applied
/// backwards as new operations; their inverses go to the other log.
fn undoGo(redo: bool) void {
    author = if (agentmode and mcp_touch) 1 else 0;
    mcp_touch = false;
    capture(); // (pending edits first: theirs)
    const r: u32 = @intFromBool(redo);
    const li = author * 2 + r;
    defer author = 0;
    const end = ul[li].items.len;
    if (end == 0) return;
    const last = end - 8; // (the last group mark)
    // the offset just past the mark before it (or the start)
    var start: usize = 0;
    var o: usize = 0;
    {
        const l = ul[li].items;
        while (o < last) {
            const t = rd32(l, o);
            const len = rd32(l, o + 4);
            const nx = o + len + 8;
            if (t == U_GROUP) start = nx;
            o = nx;
        }
    }
    // the records [start, last), backwards; the log ends at start now
    var recs: std.ArrayList(u8) = .empty;
    defer recs.deinit(A);
    recs.appendSlice(A, ul[li].items[start..last]) catch return;
    ul[li].items.len = start;
    mode = if (redo) 0 else 1;
    defer mode = 0;
    var offs: std.ArrayList(usize) = .empty;
    defer offs.deinit(A);
    o = 0;
    while (o + 8 <= recs.items.len) {
        offs.append(A, o) catch return;
        o += rd32(recs.items, o + 4) + 8;
    }
    var k = offs.items.len;
    while (k > 0) {
        k -= 1;
        const at = offs.items[k];
        const len = rd32(recs.items, at + 4);
        if (at + 8 + len > recs.items.len) continue;
        ulApply(rd32(recs.items, at), recs.items[at + 8 ..][0..len]);
    }
    ulGroup();
    mode = 0;
    reorder();
}

/// ul_apply: a record's inverse as new operations (into `mode`'s log).
fn ulApply(t: u32, d: []const u8) void {
    if (t >= 20) return ct.undo(t, d); // node graphs'
    switch (t) {
        U_REG => {
            if (d.len < 48) return;
            const e = ceFind(rd64(d, 0)) orelse return;
            opReg(e, rd32(d, 8), d[12..48]);
            matElem(e);
        },
        U_ADD => { // add again
            if (d.len < 8) return;
            const e = ceFind(rd64(d, 0)) orelse return;
            opAdd(e);
            matElem(e);
        },
        U_DEL => {
            if (d.len < 8) return;
            const e = ceFind(rd64(d, 0)) orelse return;
            opDel(e);
            matElem(e);
        },
        U_GEN => { // the old store again (a copy: a new generation)
            if (d.len < 16) return;
            const e = ceFind(rd64(d, 0)) orelse return;
            const old = storeOf(rd64(d, 8)) orelse return;
            const s = storeNew(@intCast(old.d.len)) orelse return;
            @memcpy(s.d, old.d);
            opGen(e, s);
            matMesh(e);
        },
        U_VERTS => { // one vertex back
            if (d.len < 24) return;
            const e = ceFind(rd64(d, 0)) orelse return;
            const i = scene.findUid(e.uid) orelse return;
            const mi = scene.objects[i].mesh orelse return;
            const me = &(scene.meshes[mi] orelse return);
            const pos = A.dupe(m.V3, me.verts) catch return;
            defer A.free(pos);
            const v = rd32(d, 8);
            if (v < pos.len) pos[v] = @bitCast(d[12..24].*);
            opVerts(e, pos);
            matMesh(e);
        },
        U_MAT => {
            if (d.len < 100) return;
            _ = cmFind(d[0..32]) orelse return;
            opMat(d[0..32], d[40..100]);
            if (cmFind(d[0..32])) |c| matMat(c);
        },
        else => {},
    }
}

// ---- presence ---------------------------------------------------------------------------------
fn theView() ?*@import("viewport.zig").View {
    const k = app.viewportArea();
    if (k < 0) return null;
    return &app.N(k).view;
}
fn camBytes() [24]u8 {
    const v = theView() orelse &@import("viewport.zig").View{};
    const c = [6]f32{ v.yaw * m.deg, v.pitch * m.deg, v.dist, v.target[0], v.target[1], v.target[2] };
    return @bitCast(c);
}

/// pres_tick: ours to the others when it changed (at most every 50 ms; the
/// agent's too: the objects its last edits touched).
fn presTick() void {
    if (agentmode and agstamp != agsent) {
        agsent = agstamp;
        presAgent();
    }
    const h = presStamp();
    if (h == preshash) return;
    const now: u32 = @truncate(@as(u64, @bitCast(app.now_ms)));
    if (now -% presms < 50) return;
    presms = now;
    preshash = h;
    author = 0;
    moB(M_PRES);
    moU32(peer);
    var nm: [16]u8 = @splat(0); // "user-" + the peer's number (its low byte, hex)
    @memcpy(nm[0..5], "user-");
    const hx = "0123456789ABCDEF";
    nm[5] = hx[(peer >> 4) & 15];
    nm[6] = hx[peer & 15];
    moBytes(&nm);
    const cb = camBytes();
    moBytes(&cb);
    moBytes(std.mem.asBytes(&scene.cursor));
    presSel();
    moSend();
}

/// pres_agent: the agent's presence: its name, no camera, its selection.
fn presAgent() void {
    author = 1;
    moB(M_PRES);
    moU32(peer | 0x8000);
    // (the original sends its name's buffer again as "no camera" and "no
    // cursor": "agent" and zeros - a distance of 0, which receivers read so)
    var z: [24]u8 = @splat(0);
    @memcpy(z[0..5], "agent");
    moBytes(z[0..16]);
    moBytes(&z);
    moBytes(z[0..12]);
    moU32(nagsel);
    for (agsel[0..nagsel]) |id| moU64(id);
    moSend();
    author = 0;
}

/// pres_stamp: a hash of camera, cursor, selection.
fn presStamp() u32 {
    var f = Fnv{};
    const cb = camBytes();
    f.mix(&cb);
    f.mix(std.mem.asBytes(&scene.cursor));
    for (scene.objects[0..scene.count]) |*o| {
        if (!o.selected) continue;
        f.h ^= o.uid;
        f.h *%= 0x9E3779B97F4A7C15;
    }
    return @truncate(f.h);
}

/// pres_sel: the selected objects' element ids (16 at most).
fn presSel() void {
    const at = op.items.len;
    moU32(0);
    var n: u32 = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (n >= 16) break;
        if (!o.selected) continue;
        const e = ceByUid(o.uid) orelse continue;
        moU64(e.id);
        n += 1;
    }
    if (!op_bad and op.items.len >= at + 4) wr32(op.items, at, n);
}

/// pres_take: a peer's presence kept (followed: our camera).
fn presTake(p: []const u8) void {
    const id = rd32(p, 0);
    var k: usize = 0;
    while (k < npr and pr[k].peer != id) k += 1;
    if (k == npr) {
        if (npr >= PR_MAX) return;
        npr += 1;
        pr[k] = .{ .peer = id, .color = peer_cols[k & 7] };
    }
    const x = &pr[k];
    @memcpy(&x.name, p[4..20]);
    x.name[15] = 0;
    x.cam = @bitCast(p[20..44].*);
    x.cur = @bitCast(p[44..56].*);
    var n = rd32(p, 56);
    if (n > 16) n = 16;
    if (60 + n * 8 > p.len) n = @intCast((p.len - 60) / 8);
    x.nsel = n;
    for (0..n) |i| x.sel[i] = rd64(p, 60 + i * 8);
    if (x.peer == follow and follow != 0) { // followed: our view on theirs
        if (theView()) |v| {
            v.cam_view = false;
            v.gliding = false;
            v.yaw = x.cam[0] / m.deg;
            v.pitch = x.cam[1] / m.deg;
            v.dist = x.cam[2];
            v.target = .{ x.cam[3], x.cam[4], x.cam[5] };
        }
    }
    app.dirty = true;
}

/// co_draw: (viewport) every peer: its selection outlined, its camera, its
/// cursor, in its colour.
pub fn draw(cv: anytype, c: anytype, line: anytype) void {
    if (!on) return;
    for (pr[0..npr]) |*p| {
        for (p.sel[0..p.nsel]) |id| {
            const e = ceFind(id) orelse continue;
            if (e.uid == 0) continue;
            const i = scene.findUid(e.uid) orelse continue;
            const o = &scene.objects[i];
            if (otOf(o.kind) != OT_MESH) continue;
            const mi = o.mesh orelse continue;
            const me = &(scene.meshes[mi] orelse continue);
            wire(cv, c, line, me, o, p.color);
        }
        if (@as(u32, @bitCast(p.cam[2])) == 0) continue; // (the agent: no view, no cursor)
        cross(cv, c, line, p.cur, p.color);
        // its camera: a line from the eye to the target, a cross at the eye
        const cy = @cos(p.cam[0]);
        const sy = @sin(p.cam[0]);
        const cp = @cos(p.cam[1]);
        const sp = @sin(p.cam[1]);
        const eye = m.V3{ cp * sy * p.cam[2] + p.cam[3], sp * p.cam[2] + p.cam[4], cp * cy * p.cam[2] + p.cam[5] };
        line(cv, c, eye, .{ p.cam[3], p.cam[4], p.cam[5] }, p.color);
        cross(cv, c, line, eye, p.color);
    }
}

/// What co_draw shows, as a word for the viewport's cache key: the peers'
/// colours, selections, cameras and cursors (0: no session).
pub fn stateWord() u64 {
    if (!on) return 0;
    var f = Fnv{};
    f.mix(std.mem.asBytes(&npr));
    for (pr[0..npr]) |*p| f.mix(std.mem.asBytes(p));
    return f.h;
}

/// co_wire: a mesh's edges (5000 at most) with an object's own transform.
fn wire(cv: anytype, c: anytype, line: anytype, me: *const scene.Mesh, o: *const scene.Object, col: u32) void {
    const mt = m.trs(o.loc, o.rot, o.scl);
    var n: u32 = 0;
    const np = me.faces();
    for (0..np) |p| {
        const a = me.poff[p];
        const b = me.poff[p + 1];
        var l = a;
        while (l < b) : (l += 1) {
            if (n >= 5000) return;
            const v0 = me.loops[l];
            const v1 = me.loops[if (l + 1 < b) l + 1 else a];
            line(cv, c, m.xform(mt, me.verts[v0]), m.xform(mt, me.verts[v1]), col);
            n += 1;
        }
    }
}

/// co_cross: three short lines through a point.
fn cross(cv: anytype, c: anytype, line: anytype, q: m.V3, col: u32) void {
    for (0..3) |k| {
        var a = q;
        var b = q;
        a[k] -= 0.25;
        b[k] += 0.25;
        line(cv, c, a, b, col);
    }
}

/// fill_circle (shapes.s rrect): the 2r square around (cx, cy), its corner
/// pixels covered by the quarter circles as the original's (fillRound's
/// coverage is a little other).
pub fn fillCircle(cv: anytype, cx: i32, cy: i32, r: i32, col: u32) void {
    if (cv.s != @import("gfx.zig").ONE) return cv.fillRound(.{ .x = cx - r, .y = cy - r, .w = 2 * r, .h = 2 * r }, r, col);
    const x0 = cx - r;
    const y0 = cy - r;
    const x1 = cx + r;
    const y1 = cy + r;
    var y = y0;
    while (y < y1) : (y += 1) {
        const dy = @max((y0 + r) - y, y - (y1 - r) + 1);
        var x = x0;
        while (x < x1) : (x += 1) {
            var a: i32 = 256;
            if (dy > 0) {
                const dx = @max((x0 + r) - x, x - (x1 - r) + 1);
                if (dx > 0) {
                    const fx = @as(f32, @floatFromInt(dx)) - 0.5;
                    const fy = @as(f32, @floatFromInt(dy)) - 0.5;
                    const d = @sqrt(fx * fx + fy * fy);
                    const cov = std.math.clamp(@as(f32, @floatFromInt(r)) - d + 0.5, 0, 1);
                    a = @intFromFloat(cov * 256);
                }
            }
            if (a >= 256) cv.pixel(x, y, col) else if (a > 0) cv.blend(.{ .x = x, .y = y, .w = 1, .h = 1 }, col, @intCast(a));
        }
    }
}

// ---- what others read -------------------------------------------------------------------------
/// co_stat(k): 0 in a session, 1 connections, 2 objects in the document (alive),
/// 3 peers seen, 4 operations made, 5 applied, 6 our peer id, 7 following, 8 the
/// agent's undo log's bytes, 9 the user's.
pub fn stat(k: i32) f32 {
    return switch (k) {
        0 => @floatFromInt(@intFromBool(on)),
        1 => blk: {
            var n: i32 = 0;
            for (&cc) |*c| n += @intFromBool(c.state == 2);
            break :blk @floatFromInt(n);
        },
        2 => blk: {
            var n: i32 = 0;
            for (ce[0..nce]) |*e| n += @intFromBool(e.add > e.del);
            break :blk @floatFromInt(n);
        },
        3 => @floatFromInt(npr),
        4 => @floatFromInt(@as(i64, @bitCast(n_ops))),
        5 => @floatFromInt(@as(i64, @bitCast(n_applied))),
        6 => @floatFromInt(@as(i32, @bitCast(peer))),
        7 => @floatFromInt(@intFromBool(follow != 0)),
        8 => @floatFromInt(@as(i64, @intCast(ul[2].items.len))),
        9 => @floatFromInt(@as(i64, @intCast(ul[0].items.len))),
        else => 0,
    };
}

/// The status bar's chip (status.s: "Co-editing" while in a session), its right
/// edge at `right`; the next chip's right edge.
pub fn statusChip() ?app.Chip {
    if (!on) return null;
    return .{ .text = "Co-editing", .label = "Co-editing", .title = "Co-editing", .tip = "This scene is edited with others: see the Versions editor" };
}
// ---- tests ---------------------------------------------------------------------------------------
test "siphash is SipHash-2-4 of the word and then the data" {
    const key = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const k0 = std.mem.readInt(u64, key[0..8], .little);
    const k1 = std.mem.readInt(u64, key[8..16], .little);
    var msg: [40]u8 = undefined;
    for (&msg, 0..) |*b, i| b.* = @intCast(i * 7 % 251);
    for (0..33) |n| {
        var full: [48]u8 = undefined;
        std.mem.writeInt(u64, full[0..8], 0x8000000000000005, .little);
        @memcpy(full[8 .. 8 + n], msg[0..n]);
        var want: [8]u8 = undefined;
        std.crypto.auth.siphash.SipHash64(2, 4).create(&want, full[0 .. 8 + n], &key);
        try std.testing.expectEqual(std.mem.readInt(u64, &want, .little), siphash(msg[0..n], k0, k1, 0x8000000000000005));
    }
}

test "the seen table keeps an (origin, number) once" {
    @memset(&seen, 0);
    try std.testing.expect(seenAdd(0x1234, 7));
    try std.testing.expect(!seenAdd(0x1234, 7));
    try std.testing.expect(seenAdd(0x1234, 8));
    try std.testing.expect(seenAdd(0x9234, 7));
    @memset(&seen, 0);
}

test "a store's size and places are the original's" {
    try std.testing.expectEqual(@as(u32, 8 * 20 + 6 * 4 + 4 + 32 + 24 * 4), msBytes(8, 6, 24, 0));
    try std.testing.expectEqual(@as(u32, 8 * 20 + 6 * 4 + 4 + 32 + 24 * 12), msBytes(8, 6, 24, 1));
}

test "host:port parses as co_parse_hp" {
    const a = parseHp("127.0.0.1:7462").?;
    try std.testing.expectEqual(@as(u32, 0x0100007f), a.addr);
    try std.testing.expectEqual(@as(u32, 7462), a.port);
    try std.testing.expectEqual(@as(u32, 0x0100007f), parseHp("localhost:9").?.addr);
    try std.testing.expect(parseHp("127.0.0:7462") == null);
    try std.testing.expect(parseHp("127.0.0.1") == null);
    try std.testing.expect(parseHp("127.0.0.1:") == null);
    try std.testing.expect(parseHp("") == null);
    try std.testing.expect(parseHp("lo") == null);
}

test "the RGA order: later insertions first under each element" {
    nce = 0;
    // a (id 10) at the head, b (20) after a, c (30) at the head, d (25) after a
    _ = ceNew(10).?;
    ce[0].add = 1;
    _ = ceNew(20).?;
    ce[1].add = 1;
    ce[1].after = 10;
    _ = ceNew(30).?;
    ce[2].add = 1;
    _ = ceNew(25).?;
    ce[3].add = 1;
    ce[3].after = 10;
    // a loop (40 after 41, 41 after 40) is never reached; a self loop neither
    _ = ceNew(40).?;
    ce[4].add = 1;
    ce[4].after = 41;
    _ = ceNew(41).?;
    ce[5].add = 1;
    ce[5].after = 40;
    _ = ceNew(50).?;
    ce[6].add = 1;
    ce[6].after = 50;
    const n = orderBuild();
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u64, 30), ce[order[0]].id);
    try std.testing.expectEqual(@as(u64, 10), ce[order[1]].id);
    try std.testing.expectEqual(@as(u64, 25), ce[order[2]].id);
    try std.testing.expectEqual(@as(u64, 20), ce[order[3]].id);
    nce = 0;
}
