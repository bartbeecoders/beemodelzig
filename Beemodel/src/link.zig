// The live link (link.s): the scene streamed over a socket.
//
// A session serves (link.serve: TCP on localhost or the LAN, or a UNIX
// socket); peers connect and say HELLO; each gets a snapshot (every material,
// mesh and object), then the changes as they happen. Another BeeModel
// (beemodel --link host:port, link.connect) mirrors the session; a game
// engine plugin reads the same stream (the original's docs/LIVELINK.md: the
// protocol, tools/livelink.py: a reference reader).
//
// The wire: messages of a u32 length (what follows), a u8 type, the payload;
// little-endian. Version 1. Types:
//    1 HELLO        "BEEL", u16 version, u16 role (0 editor, 1 mirror /
//                   reader), u32 peer, name[32]
//    2 SNAP_BEGIN   u32 objects, u32 meshes, u32 materials
//    3 SNAP_END
//    4 TICK         u64 CLOCK_MONOTONIC ns when the changes after it left
//   10 OBJECT       u32 uid, u32 type, u32 flags, u32 colour, i32 material,
//                   u32 mesh (its uid; 0: none), name[32], loc rot scale (9 f32)
//   11 DELETE       u32 uid
//   12 TRANSFORM    u32 uid, loc rot scale (9 f32)
//   13 PROPERTY     u32 uid, u32 key (1 name[32], 2 material i32, 3 flags
//                   u32, 4 colour u32), the value (32 bytes)
//   20 MESH         u32 mesh, u32 vertices, u32 polygons, u32 loops, u32
//                   has UVs; positions, polygon starts (polygons + 1),
//                   loop vertices, UVs (2 f32 a loop)
//   21 MESH_DELTA   u32 mesh, u32 ranges; per range u32 first, u32 count,
//                   the positions
//   30 MATERIAL     u32 index, name[32], 15 f32 (base rgb ... alpha)
//
// The server finds changes by comparing the scene with what it last sent (a
// table by object uid, hashed and probed as the original's, so deletions and
// held-back transforms go out in its order; the evaluated mesh as sent), every
// turn of the main loop. Each peer has its own output buffer, written as the
// socket takes it; a peer more than 256 KiB behind gets no TRANSFORM messages:
// its objects are marked and sent once with their latest place when it catches
// up, everything else waits in order.
//
// Where the original goes wrong this does not (the report lists them): a
// snapshot after a material was removed (the original reads past the list and
// crashes), malformed messages from the server a mirror reads (the original
// reads past them: short payloads, counts that point outside the message,
// meshes whose loops index past their vertices, a zero length, a message
// longer than the input buffer, which stalls it), the mirroring state left
// set after a disconnect (the status chip stayed), the dropping of a peer that
// keeps up but never quite empties its buffer (it is dropped once 64 MiB are
// waiting, as the documentation says), a UNIX path that is not a socket (the
// original deletes whatever file is there before binding).
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const ops = @import("ops.zig");
const m = @import("math.zig");

const PA = std.heap.page_allocator;

pub const MAXC = 8;
const OUT_CAP: usize = 64 << 20; // a peer's output
const IN_CAP: usize = 64 << 20; // the mirror's input
const LAG: usize = 256 * 1024; // behind this: transforms coalesce
const TB_CAP = 8192; // the table (a power of two)
const MATS_MAX = 256;
const DEFAULT_PORT = 7461;

pub const M_HELLO = 1;
pub const M_SNAPB = 2;
pub const M_SNAPE = 3;
pub const M_TICK = 4;
pub const M_OBJECT = 10;
pub const M_DELETE = 11;
pub const M_XF = 12;
pub const M_PROP = 13;
pub const M_MESH = 20;
pub const M_DELTA = 21;
pub const M_MAT = 30;

const OBF_HIDDEN: u32 = 0x200;

const s_bad = "  live link: could not serve (link.serve [port] | lan [port] | unix:<path>)";

// =============================================================================
//  State
// =============================================================================

/// What was sent for an object (TE_*): its values and its evaluated mesh.
const Entry = struct {
    uid: u32 = 0,
    state: u8 = 0, // 0 empty, 1 live, 2 gone
    seen: u32 = 0,
    typ: u32 = 0,
    flags: u32 = 0,
    color: u32 = 0,
    mat: i32 = 0,
    // the evaluated mesh sent: its serial and in-place version (TE_MPTR, TE_MVER)
    mkey_ok: bool = false,
    mserial: u32 = 0,
    mshape: u32 = 0,
    name: [32]u8 = @splat(0),
    xf: [36]u8 = @splat(0),
    // the mesh as sent: counts, a copy (positions, starts, loops, UVs)
    nv: u32 = 0,
    np: u32 = 0,
    nl: u32 = 0,
    uv: u32 = 0,
    mbuf: []u8 = &.{},
};

/// A peer (CL_*).
const Client = struct {
    fd: i32 = -1,
    state: u8 = 0, // 0 free, 1 waiting HELLO, 3 to greet, 2 synced
    out: std.ArrayListUnmanaged(u8) = .empty,
    head: usize = 0,
    inlen: u32 = 0,
    role: u32 = 0,
    in: [64]u8 = @splat(0),
    bits: [TB_CAP / 8]u8 = @splat(0), // transforms held back (a bit an entry)

    fn pending(c: *const Client) usize {
        return c.out.items.len - c.head;
    }
};

/// The mirror's map: a remote uid, its local object, a mesh that came first.
const MapEntry = struct {
    uid: u32 = 0,
    state: u8 = 0,
    oid: u32 = 0, // the local object (its oid; 0: none)
    mesh: ?[]u8 = null, // a MESH payload waiting for its object
};

var tab: [TB_CAP]Entry = @splat(.{});
var cl: [MAXC]Client = @splat(.{});
var mats: [MATS_MAX][92]u8 = undefined; // materials as sent: name, 60 bytes
var nmats: u32 = 0;
var map: [TB_CAP]MapEntry = @splat(.{});

var lfd: i32 = -1; // the listener
pub var serving: bool = false;
var unix_path: [108]u8 = @splat(0);
var unix_len: usize = 0;
var ticked: bool = false;
var seen_mark: u32 = 0;

var op: std.ArrayListUnmanaged(u8) = .empty; // a message being built
var op_failed = false;

var in: std.ArrayListUnmanaged(u8) = .empty; // the mirror's input
var mfd: i32 = -1; // the mirror's connection
pub var mstate: u8 = 0; // 0 none, 1 waiting HELLO, 2 receiving
var target: [121]u8 = @splat(0);
var target_len: usize = 0;
var mirror_changed = false;

// stats (link_stat)
var st_sent: u64 = 0;
var st_msgs: u64 = 0;
var st_recv: u64 = 0;
var st_coal: u64 = 0;
var st_snaps: u32 = 0;

// =============================================================================
//  Messages
// =============================================================================

fn opB(t: u8) void {
    op.clearRetainingCapacity();
    op_failed = false;
    put(&.{ 0, 0, 0, 0, t });
}
fn put(b: []const u8) void {
    op.appendSlice(PA, b) catch {
        op_failed = true;
    };
}
fn putU32(v: u32) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    put(&b);
}
fn putU64(v: u64) void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    put(&b);
}
/// op_e: the length in.
fn opE() void {
    if (op.items.len >= 4) std.mem.writeInt(u32, op.items[0..4], @intCast(op.items.len - 4), .little);
}

/// send_op: a message appended to a peer's output; a transform (xf) to a peer
/// behind is held back (its entry marked); a peer whose output would pass
/// OUT_CAP goes.
fn sendMsg(c: *Client, msg: []const u8, xf: bool, entry: usize) void {
    if (c.state == 0) return; // (dropped on the way)
    if (xf and c.pending() >= LAG) {
        c.bits[entry >> 3] |= @as(u8, 1) << @intCast(entry & 7);
        st_coal += 1;
        return;
    }
    if (c.pending() + msg.len > OUT_CAP) return peerDrop(c);
    if (c.head > 0 and c.head == c.out.items.len) {
        c.out.clearRetainingCapacity();
        c.head = 0;
    }
    c.out.appendSlice(PA, msg) catch return peerDrop(c);
    st_sent += msg.len;
    st_msgs += 1;
}

fn sendOp(c: *Client, xf: bool, entry: usize) void {
    if (op_failed) return;
    sendMsg(c, op.items, xf, entry);
}

/// bcast: the message to every synced peer (a TICK first, once a turn).
fn bcast(xf: bool, entry: usize) void {
    if (!ticked) {
        ticked = true;
        sendTick();
    }
    for (&cl) |*c| {
        if (c.state == 2) sendOp(c, xf, entry);
    }
}

fn sendTick() void {
    var b: [13]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], 9, .little);
    b[4] = M_TICK;
    std.mem.writeInt(u64, b[5..13], nowNs(), .little);
    for (&cl) |*c| {
        if (c.state == 2) sendMsg(c, &b, false, 0);
    }
}

pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
}

// =============================================================================
//  Serving
// =============================================================================

/// The address link.serve's argument names (pure: tested without a socket).
pub const ServeAddr = union(enum) {
    bad,
    tcp: struct { ip: u32, port: i32 }, // ip in network order (0: every interface)
    unix: []const u8,
};

/// im_next_word: words split at spaces only, each at most 255 bytes.
fn nextWord(s: []const u8, i: *usize, out: *[256]u8) []const u8 {
    while (i.* < s.len and s[i.*] == ' ') i.* += 1;
    var n: usize = 0;
    while (i.* < s.len and s[i.*] != ' ' and s[i.*] != 0) : (i.* += 1) {
        if (n < 255) {
            out[n] = s[i.*];
            n += 1;
        }
    }
    return out[0..n];
}

/// cvttss2si: f32 to i32, out of range (or NaN) 0x80000000.
fn truncI32(f: f32) i32 {
    if (!(f > -2147483904.0 and f < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(f);
}

pub fn parseServe(a: []const u8) ServeAddr {
    if (a.len >= 5 and std.mem.eql(u8, a[0..5], "unix:")) {
        // the path: up to a space, 100 bytes at most
        var n: usize = 0;
        while (5 + n < a.len and n < 100 and a[5 + n] != ' ' and a[5 + n] != 0) n += 1;
        return .{ .unix = a[5 .. 5 + n] };
    }
    var ip: u32 = 0x0100007f; // 127.0.0.1
    var i: usize = 0;
    var wb: [256]u8 = undefined;
    var w = nextWord(a, &i, &wb);
    if (w.len == 0) return .{ .tcp = .{ .ip = ip, .port = DEFAULT_PORT } };
    if (std.mem.eql(u8, w, "lan")) {
        ip = 0; // every interface
        w = nextWord(a, &i, &wb);
        if (w.len == 0) return .{ .tcp = .{ .ip = ip, .port = DEFAULT_PORT } };
    }
    const f = @import("mech.zig").parseFloat(w) orelse return .bad;
    return .{ .tcp = .{ .ip = ip, .port = truncI32(f) } };
}

fn sockOpt(fd: i32, level: i32, opt: u32, v: u32) void {
    const b: [4]u8 = @bitCast(v);
    _ = linux.setsockopt(fd, level, opt, &b, 4);
}

fn ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

/// A sockaddr_un for a path (zero-padded; at most 107 bytes kept).
fn unixAddr(p: []const u8) [110]u8 {
    var a: [110]u8 = @splat(0);
    a[0] = linux.AF.UNIX;
    const n = @min(p.len, 107);
    @memcpy(a[2 .. 2 + n], p[0..n]);
    return a;
}

fn isSocket(p: [*:0]const u8) bool {
    var st: linux.Statx = undefined;
    if (!ok(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st))) return false;
    return st.mode & linux.S.IFMT == linux.S.IFSOCK;
}

/// link.serve [port] | lan [port] | unix:path
pub fn serve(a: []const u8) void {
    stopServing();
    const addr = parseServe(a);
    var fd: i32 = -1;
    switch (addr) {
        .bad => return app.log(s_bad, .{}),
        .tcp => |t| {
            const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
            if (!ok(rc)) return app.log(s_bad, .{});
            fd = @intCast(rc);
            sockOpt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
            var sa: [16]u8 align(4) = @splat(0);
            sa[0] = linux.AF.INET;
            const pu: u16 = @truncate(@as(u32, @bitCast(t.port)));
            sa[2] = @intCast(pu >> 8);
            sa[3] = @intCast(pu & 0xff);
            std.mem.writeInt(u32, sa[4..8], t.ip, .little);
            if (!ok(linux.bind(fd, @ptrCast(&sa), 16)) or !ok(linux.listen(fd, MAXC))) {
                _ = linux.close(fd);
                return app.log(s_bad, .{});
            }
            unix_len = 0;
            started(fd);
            app.log("  live link: serving on {d}", .{t.port});
        },
        .unix => |p| {
            var z: [108]u8 = @splat(0);
            @memcpy(z[0..p.len], p);
            const zp: [*:0]const u8 = @ptrCast(&z);
            // a socket left there goes (the original's plat_unlink took any file)
            if (isSocket(zp)) _ = linux.unlink(zp);
            const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
            if (!ok(rc)) return app.log(s_bad, .{});
            fd = @intCast(rc);
            const sa: [110]u8 align(4) = unixAddr(p);
            if (!ok(linux.bind(fd, @ptrCast(&sa), 110)) or !ok(linux.listen(fd, MAXC))) {
                _ = linux.close(fd);
                return app.log(s_bad, .{});
            }
            unix_path = z;
            unix_len = p.len;
            started(fd);
            app.log("  live link: serving on {s}", .{p});
        },
    }
}

fn started(fd: i32) void {
    lfd = fd;
    serving = true;
    tabClear(); // (everything goes out anew)
}

/// link.stop
pub fn stop() void {
    stopServing();
    app.log("  live link: stopped", .{});
}

/// lk_stop_serving: the listener and every peer go.
fn stopServing() void {
    if (!serving) return;
    _ = linux.close(lfd);
    lfd = -1;
    serving = false;
    if (unix_len > 0) {
        const zp: [*:0]const u8 = @ptrCast(&unix_path);
        if (isSocket(zp)) _ = linux.unlink(zp);
        unix_len = 0;
    }
    for (&cl) |*c| {
        if (c.state != 0) peerDrop(c);
    }
}

/// peer_drop: closed, forgotten (its buffer kept for the next).
fn peerDrop(c: *Client) void {
    if (c.fd >= 0) _ = linux.close(c.fd);
    c.state = 0;
    c.fd = -1;
    c.head = 0;
    c.out.clearRetainingCapacity();
    // (a buffer grown large goes back)
    if (c.out.capacity > 4 << 20) c.out.clearAndFree(PA);
}

/// tab_clear: nothing sent yet (copies let go).
fn tabClear() void {
    for (&tab) |*e| {
        if (e.mbuf.len > 0) PA.free(e.mbuf);
        e.* = .{};
    }
    nmats = 0;
}

fn hashOf(uid: u32) usize {
    return ((uid *% 0x9E3779B1) >> 19) & (TB_CAP - 1);
}

/// tab_find: the entry for a uid (made when asked: "gone" until filled), or
/// null when there is none / the table is full.
fn tabFind(uid: u32, make: bool) ?usize {
    var k = hashOf(uid);
    var left: usize = TB_CAP;
    while (left > 0) : (left -= 1) {
        const e = &tab[k];
        if (e.state == 0) {
            if (!make) return null;
            e.uid = uid;
            e.state = 2;
            return k;
        }
        if (e.uid == uid) return k;
        k = (k + 1) & (TB_CAP - 1);
    }
    return null;
}

// =============================================================================
//  Messages from the scene
// =============================================================================

fn mkObject(e: *const Entry) void {
    opB(M_OBJECT);
    putU32(e.uid);
    putU32(e.typ);
    putU32(e.flags);
    putU32(e.color);
    putU32(@bitCast(e.mat));
    putU32(if (e.nv != 0) e.uid else 0); // its mesh: by the object's uid
    put(&e.name);
    put(&e.xf);
    opE();
}

fn mkXf(e: *const Entry) void {
    opB(M_XF);
    putU32(e.uid);
    put(&e.xf);
    opE();
}

fn mkProp(e: *const Entry, key: u32, v: *const [32]u8) void {
    opB(M_PROP);
    putU32(e.uid);
    putU32(key);
    put(v);
    opE();
}

fn mkMesh(e: *const Entry) void {
    opB(M_MESH);
    putU32(e.uid);
    putU32(e.nv);
    putU32(e.np);
    putU32(e.nl);
    putU32(e.uv);
    put(e.mbuf);
    opE();
}

fn copySize(nv: usize, np: usize, nl: usize, uv: bool) usize {
    return nv * 12 + np * 4 + 4 + nl * 4 + (if (uv) nl * 8 else 0);
}

fn hasUv(me: *const scene.Mesh) bool {
    return me.uv.len > 0 and me.uv.len == me.loops.len;
}

/// take_mesh: the entry's copy becomes this mesh.
fn takeMesh(e: *Entry, me: *const scene.Mesh) void {
    if (e.mbuf.len > 0) PA.free(e.mbuf);
    e.mbuf = &.{};
    const uv = hasUv(me);
    const nv = me.verts.len;
    const np = me.poff.len -| 1;
    const nl = me.loops.len;
    const b = PA.alloc(u8, copySize(nv, np, nl, uv)) catch {
        e.nv = 0;
        e.np = 0;
        e.nl = 0;
        e.uv = 0;
        return;
    };
    e.nv = @intCast(nv);
    e.np = @intCast(np);
    e.nl = @intCast(nl);
    e.uv = @intFromBool(uv);
    var o: usize = 0;
    @memcpy(b[o .. o + nv * 12], std.mem.sliceAsBytes(me.verts));
    o += nv * 12;
    if (me.poff.len == np + 1) {
        @memcpy(b[o .. o + np * 4 + 4], std.mem.sliceAsBytes(me.poff));
    } else @memset(b[o .. o + 4], 0);
    o += np * 4 + 4;
    @memcpy(b[o .. o + nl * 4], std.mem.sliceAsBytes(me.loops));
    o += nl * 4;
    if (uv) @memcpy(b[o .. o + nl * 8], std.mem.sliceAsBytes(me.uv));
    e.mbuf = b;
}

/// same_topo: counts, polygons, loops and UVs as sent (only vertices may
/// have moved); a mesh with UVs always goes whole.
fn sameTopo(e: *const Entry, me: *const scene.Mesh) bool {
    if (e.mbuf.len == 0) return false;
    if (me.verts.len != e.nv or (me.poff.len -| 1) != e.np or me.loops.len != e.nl) return false;
    if (@intFromBool(hasUv(me)) != e.uv or e.uv != 0) return false;
    const o = @as(usize, e.nv) * 12;
    const ps = @as(usize, e.np) * 4 + 4;
    if (!std.mem.eql(u8, e.mbuf[o .. o + ps], std.mem.sliceAsBytes(me.poff))) return false;
    return std.mem.eql(u8, e.mbuf[o + ps .. o + ps + @as(usize, e.nl) * 4], std.mem.sliceAsBytes(me.loops));
}

/// mk_delta: MESH_DELTA of the runs of changed vertices (the copy updated);
/// false when nothing moved.
fn mkDelta(e: *Entry, me: *const scene.Mesh) bool {
    opB(M_DELTA);
    putU32(e.uid);
    const at = op.items.len;
    putU32(0);
    const sent: [][3]u32 = @as([*][3]u32, @ptrCast(@alignCast(e.mbuf.ptr)))[0..e.nv];
    const now: []const [3]u32 = @ptrCast(me.verts);
    var ranges: u32 = 0;
    var v: usize = 0;
    const nv: usize = e.nv;
    while (v < nv) {
        if (std.mem.eql(u32, &sent[v], &now[v])) {
            v += 1;
            continue;
        }
        const first = v;
        v += 1;
        while (v < nv and !std.mem.eql(u32, &sent[v], &now[v])) v += 1;
        putU32(@intCast(first));
        putU32(@intCast(v - first));
        put(std.mem.sliceAsBytes(now[first..v]));
        @memcpy(sent[first..v], now[first..v]);
        ranges += 1;
    }
    if (!op_failed) std.mem.writeInt(u32, op.items[at..][0..4], ranges, .little);
    opE();
    return ranges != 0;
}

/// mk_mat: MATERIAL (what was sent kept).
fn mkMat(i: usize) void {
    const ma = &material.list[i];
    const rec: *const [92]u8 = @ptrCast(ma);
    opB(M_MAT);
    putU32(@intCast(i));
    put(rec[0..32]);
    put(rec[32..92]);
    opE();
    mats[i] = rec.*;
}

fn typeCode(k: scene.Kind) u32 {
    return switch (k) {
        .light => 1,
        .camera => 2,
        .sketch => 3,
        .armature => 4,
        .field => 5,
        else => 0,
    };
}

fn objFlags(o: *const scene.Object) u32 {
    return if (o.visible) 0 else OBF_HIDDEN;
}

/// fill_entry: its type, name, flags, colour, material, transform as they are.
fn fillEntry(e: *Entry, i: usize) void {
    const o = &scene.objects[i];
    e.typ = typeCode(o.kind);
    e.flags = objFlags(o);
    e.color = o.color;
    e.mat = @as(i32, o.mat) - 1;
    e.mkey_ok = false;
    e.nv = 0;
    if (e.mbuf.len > 0) PA.free(e.mbuf);
    e.mbuf = &.{};
    e.name = o.name_buf;
    e.xf = @bitCast(scene.worldPlace(i));
}

/// lk_diff: the scene against the table; what changed goes out.
fn diff() void {
    seen_mark +%= 1;
    for (0..scene.count) |i| {
        const o = &scene.objects[i];
        const k = tabFind(o.uid, true) orelse continue;
        const e = &tab[k];
        e.seen = seen_mark;
        const me: ?*const scene.Mesh = if (o.kind.isMesh()) @import("mods.zig").of(i) else null;
        if (e.state == 1 and e.typ != typeCode(o.kind)) e.state = 2; // (the type changed: as new)
        if (e.state != 1) {
            // new: its mesh, then the object
            e.state = 1;
            fillEntry(e, i);
            if (me) |mm| {
                takeMesh(e, mm);
                e.mkey_ok = true;
                e.mserial = mm.serial;
                e.mshape = mm.shape;
                mkMesh(e);
                bcast(false, 0);
            }
            mkObject(e);
            bcast(false, 0);
            continue;
        }
        // the mesh
        if (me) |mm| {
            if (!e.mkey_ok or e.mserial != mm.serial or e.mshape != mm.shape) {
                e.mkey_ok = true;
                e.mserial = mm.serial;
                e.mshape = mm.shape;
                if (sameTopo(e, mm)) {
                    if (mkDelta(e, mm)) bcast(false, 0); // only vertices moved
                } else {
                    takeMesh(e, mm); // anything else: the whole mesh
                    mkMesh(e);
                    bcast(false, 0);
                }
            }
        }
        // the transform
        const xf: [36]u8 = @bitCast(scene.worldPlace(i));
        if (!std.mem.eql(u8, &xf, &e.xf)) {
            e.xf = xf;
            mkXf(e);
            bcast(true, k);
        }
        // the name
        if (!std.mem.eql(u8, &o.name_buf, &e.name)) {
            e.name = o.name_buf;
            mkProp(e, 1, &e.name);
            bcast(false, 0);
        }
        // the material
        const mat = @as(i32, o.mat) - 1;
        if (mat != e.mat) {
            e.mat = mat;
            mkProp(e, 2, &val32(@bitCast(mat)));
            bcast(false, 0);
        }
        // the flags (hidden; not the selection)
        const fl = objFlags(o);
        if (fl != e.flags) {
            e.flags = fl;
            mkProp(e, 3, &val32(fl));
            bcast(false, 0);
        }
        // the colour
        if (o.color != e.color) {
            e.color = o.color;
            mkProp(e, 4, &val32(o.color));
            bcast(false, 0);
        }
    }
    // entries not seen: deleted
    for (&tab) |*e| {
        if (e.state != 1 or e.seen == seen_mark) continue;
        e.state = 2;
        opB(M_DELETE);
        putU32(e.uid);
        opE();
        bcast(false, 0);
    }
    // materials: new or changed
    const n = @min(material.count, MATS_MAX);
    for (0..n) |i| {
        if (i < nmats) {
            const rec: *const [92]u8 = @ptrCast(&material.list[i]);
            if (std.mem.eql(u8, rec, &mats[i])) continue;
        }
        mkMat(i);
        bcast(false, 0);
        if (i + 1 > nmats) nmats = @intCast(i + 1);
    }
}

fn val32(v: u32) [32]u8 {
    var b: [32]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], v, .little);
    return b;
}

// =============================================================================
//  The tick
// =============================================================================

/// link_tick: peers in and out, the scene's changes to the synced ones,
/// output written, the mirror's input applied.
pub fn tick() void {
    if (serving) {
        accept();
        readPeers();
        ticked = false;
        if (anySynced()) diff(); // changes to the synced
        greet(); // new peers: HELLO, the snapshot
        flush();
    }
    if (mfd >= 0) mirror();
}

fn anySynced() bool {
    for (&cl) |*c| {
        if (c.state == 2) return true;
    }
    return false;
}

/// lk_accept: new connections (TCP_NODELAY, a small kernel buffer), waiting
/// for their HELLO.
fn accept() void {
    while (true) {
        const rc = linux.accept4(lfd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        if (!ok(rc)) return;
        const fd: i32 = @intCast(rc);
        sockOpt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1); // (a UNIX socket: no-op)
        sockOpt(fd, linux.SOL.SOCKET, linux.SO.SNDBUF, 256 * 1024); // (the backlog stays ours, to coalesce)
        const c = for (&cl) |*c| {
            if (c.state == 0) break c;
        } else {
            _ = linux.close(fd); // full
            continue;
        };
        c.fd = fd;
        c.state = 1;
        c.head = 0;
        c.out.clearRetainingCapacity();
        c.inlen = 0;
        c.bits = @splat(0);
        app.log("  live link: a peer connected", .{});
    }
}

/// lk_read_peers: a HELLO (then to greet), anything else ignored; a closed
/// connection drops the peer.
fn readPeers() void {
    var buf: [4096]u8 = undefined;
    for (&cl) |*c| {
        if (c.state == 0) continue;
        var budget: usize = 1 << 20; // (a flood waits for the next turn)
        while (budget > 0) {
            const rc = linux.read(c.fd, &buf, buf.len);
            const er = linux.errno(rc);
            if (er == .AGAIN or er == .INTR) break;
            if (er != .SUCCESS or rc == 0) {
                peerDrop(c);
                app.log("  live link: a peer left", .{});
                break;
            }
            budget -|= rc;
            if (c.state != 1) continue;
            const take = @min(rc, 64 - c.inlen);
            @memcpy(c.in[c.inlen .. c.inlen + take], buf[0..take]);
            c.inlen += @intCast(take);
            if (c.inlen < 4 + 1 + 4 + 2 + 2 + 4 + 32) continue;
            if (!helloOk(&c.in)) {
                peerDrop(c);
                app.log("  live link: a peer left", .{});
                break;
            }
            c.role = std.mem.readInt(u16, c.in[11..13], .little);
            c.state = 3; // (to greet)
        }
    }
}

/// hello_ok: a HELLO, "BEEL", version 1.
fn helloOk(b: []const u8) bool {
    if (b.len < 11) return false;
    if (std.mem.readInt(u32, b[0..4], .little) < 1 + 4 + 2 + 2 + 4 + 32) return false;
    if (b[4] != M_HELLO) return false;
    if (!std.mem.eql(u8, b[5..9], "BEEL")) return false;
    return std.mem.readInt(u16, b[9..11], .little) == 1;
}

fn mkHello(role: u16) void {
    opB(M_HELLO);
    put("BEEL");
    putU32(1 | @as(u32, role) << 16); // version 1, the role
    putU32(@bitCast(linux.getpid()));
    var nm: [32]u8 = @splat(0);
    @memcpy(nm[0..8], "BeeModel");
    put(&nm);
    opE();
}

/// lk_greet: peers whose HELLO came: ours, then the snapshot, synced.
fn greet() void {
    for (&cl) |*c| {
        if (c.state != 3) continue;
        if (!anySynced()) {
            ticked = true; // (no TICK: nobody to tell)
            diff(); // (the table brought up to date)
        }
        mkHello(0);
        sendOp(c, false, 0);
        if (c.state != 3) continue;
        // (materials removed since: not sent; the original read past its list)
        nmats = @min(nmats, @as(u32, @intCast(@min(material.count, MATS_MAX))));
        var objs: u32 = 0;
        var meshes: u32 = 0;
        for (&tab) |*e| {
            if (e.state != 1) continue;
            objs += 1;
            if (e.nv != 0) meshes += 1;
        }
        opB(M_SNAPB);
        putU32(objs);
        putU32(meshes);
        putU32(nmats);
        opE();
        sendOp(c, false, 0);
        for (0..nmats) |i| {
            mkMat(i);
            sendOp(c, false, 0);
        }
        // meshes and objects, in list order
        for (scene.objects[0..scene.count]) |*o| {
            const k = tabFind(o.uid, false) orelse continue;
            const e = &tab[k];
            if (e.state != 1) continue;
            if (e.nv != 0) {
                mkMesh(e);
                sendOp(c, false, 0);
            }
            mkObject(e);
            sendOp(c, false, 0);
        }
        opB(M_SNAPE);
        opE();
        sendOp(c, false, 0);
        if (c.state == 0) continue; // (dropped: its output too big)
        c.state = 2;
        st_snaps += 1;
    }
}

/// lk_flush: every peer's output as its socket takes it; a peer caught up
/// gets the transforms it missed (their latest).
fn flush() void {
    for (&cl) |*c| {
        if (c.state != 2) continue;
        write(c);
        if (c.state != 2) continue;
        if (c.pending() >= LAG) continue;
        for (0..TB_CAP) |k| {
            const bit = @as(u8, 1) << @intCast(k & 7);
            if (c.bits[k >> 3] & bit == 0) continue;
            c.bits[k >> 3] &= ~bit;
            if (tab[k].state != 1) continue;
            mkXf(&tab[k]);
            sendOp(c, false, 0);
            if (c.state != 2) break;
        }
        if (c.state == 2) write(c);
    }
}

/// lk_write: what the socket takes.
fn write(c: *Client) void {
    while (c.pending() > 0) {
        const d = c.out.items[c.head..];
        const rc = linux.sendto(c.fd, d.ptr, d.len, linux.MSG.NOSIGNAL, null, 0);
        const er = linux.errno(rc);
        if (er == .AGAIN) break;
        if (er == .INTR) continue;
        if (er != .SUCCESS or rc == 0) return peerDrop(c);
        c.head += rc;
    }
    if (c.pending() == 0) {
        c.out.clearRetainingCapacity(); // all out: from the start again
        c.head = 0;
    } else if (c.head >= 1 << 20 and c.head * 2 >= c.out.items.len) {
        // (the sent part goes: a peer that keeps up but never quite empties
        // its buffer is not dropped for the bytes it took)
        const rest = c.pending();
        std.mem.copyForwards(u8, c.out.items[0..rest], c.out.items[c.head..]);
        c.out.shrinkRetainingCapacity(rest);
        c.head = 0;
    }
}

/// link_pollfds: the listener, the peers (POLLOUT too with output waiting),
/// the mirror's connection.
pub fn pollfds(p: []linux.pollfd) usize {
    var n: usize = 0;
    if (serving) {
        if (n < p.len) {
            p[n] = .{ .fd = lfd, .events = linux.POLL.IN, .revents = 0 };
            n += 1;
        }
        for (&cl) |*c| {
            if (c.state == 0 or n >= p.len) continue;
            p[n] = .{ .fd = c.fd, .events = linux.POLL.IN | @as(i16, if (c.pending() > 0) linux.POLL.OUT else 0), .revents = 0 };
            n += 1;
        }
    }
    if (mfd >= 0 and n < p.len) {
        p[n] = .{ .fd = mfd, .events = linux.POLL.IN, .revents = 0 };
        n += 1;
    }
    return n;
}

pub const MAX_POLLFDS = 1 + MAXC + 1;

// =============================================================================
//  Mirroring
// =============================================================================

pub fn disconnect() void {
    if (mfd < 0) return;
    _ = linux.close(mfd);
    mfd = -1;
    mstate = 0; // (the original kept it: its chip said "mirroring" still)
    in.clearRetainingCapacity();
    if (in.capacity > 4 << 20) in.clearAndFree(PA);
}

/// parse_hostport: "a.b.c.d:port" or "localhost:port" (u32 arithmetic as
/// the original's: a number that wraps is taken as it wraps). The address in
/// network order.
pub fn parseHostPort(s: []const u8) ?struct { ip: u32, port: u16 } {
    var i: usize = 0;
    var ip: u32 = 0;
    const at = struct {
        fn f(t: []const u8, k: usize) u8 {
            return if (k < t.len) t[k] else 0;
        }
    }.f;
    if (s.len >= 9 and std.mem.eql(u8, s[0..9], "localhost")) {
        ip = 0x0100007f;
        i = 9;
    } else {
        var part: u32 = 0;
        while (true) {
            var v: u32 = 0;
            var digits: u32 = 0;
            while (at(s, i) -% '0' <= 9) : (i += 1) {
                v = v *% 10 +% (at(s, i) - '0');
                digits += 1;
            }
            if (digits == 0 or v > 255) return null;
            ip |= v << @intCast(part * 8);
            part += 1;
            if (part >= 4) break;
            if (at(s, i) != '.') return null;
            i += 1;
        }
    }
    if (at(s, i) != ':') return null;
    i += 1;
    var v: u32 = 0;
    var digits: u32 = 0;
    while (at(s, i) -% '0' <= 9) : (i += 1) {
        v = v *% 10 +% (at(s, i) - '0');
        digits += 1;
    }
    if (digits == 0 or v > 65535) return null;
    return .{ .ip = ip, .port = @intCast(v) };
}

/// link_connect_arg: host:port | unix:path. True when connected (our HELLO
/// sent). An empty argument keeps the address asked last (the original's
/// op_arg 0).
pub fn connect(a: ?[]const u8) bool {
    const arg = a orelse return failConnect();
    {
        var n: usize = 0;
        while (n < arg.len and n < 120 and arg[n] != ' ' and arg[n] != 0) n += 1;
        target = @splat(0);
        @memcpy(target[0..n], arg[0..n]);
        target_len = n;
    }
    disconnect();
    const t = target[0..target_len];
    var fd: i32 = -1;
    if (t.len >= 5 and std.mem.eql(u8, t[0..5], "unix:")) {
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (!ok(rc)) return failConnect();
        fd = @intCast(rc);
        const p = t[5..];
        const sa = unixAddr(p[0..@min(p.len, 106)]);
        if (!ok(linux.connect(fd, &sa, 110))) {
            _ = linux.close(fd);
            return failConnect();
        }
    } else {
        const hp = parseHostPort(t) orelse return failConnect();
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (!ok(rc)) return failConnect();
        fd = @intCast(rc);
        var sa: [16]u8 = @splat(0);
        sa[0] = linux.AF.INET;
        sa[2] = @intCast(hp.port >> 8);
        sa[3] = @intCast(hp.port & 0xff);
        std.mem.writeInt(u32, sa[4..8], hp.ip, .little);
        if (!ok(linux.connect(fd, &sa, 16))) {
            _ = linux.close(fd);
            return failConnect();
        }
    }
    sockOpt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);
    _ = linux.fcntl(fd, linux.F.SETFL, 0o4000); // O_NONBLOCK
    mfd = fd;
    mstate = 1;
    in.clearRetainingCapacity();
    mapClear();
    mkHello(1); // ours (a mirror)
    if (!op_failed) _ = linux.sendto(mfd, op.items.ptr, op.items.len, linux.MSG.NOSIGNAL, null, 0);
    app.log("  live link: mirroring {s}", .{t});
    return true;
}

fn failConnect() bool {
    app.log("  live link: could not connect to {s}", .{target[0..target_len]});
    return false;
}

/// map_clear: nothing mirrored yet (meshes waiting let go).
fn mapClear() void {
    for (&map) |*e| {
        if (e.mesh) |b| PA.free(b);
        e.* = .{};
    }
}

fn mapFind(uid: u32, make: bool) ?*MapEntry {
    var k = hashOf(uid);
    var left: usize = TB_CAP;
    while (left > 0) : (left -= 1) {
        const e = &map[k];
        if (e.state == 0) {
            if (!make) return null;
            e.* = .{ .uid = uid, .state = 1 };
            return e;
        }
        if (e.uid == uid) return e;
        k = (k + 1) & (TB_CAP - 1);
    }
    return null;
}

/// map_obj: its local object's index (null: none / gone).
fn mapObj(e: *const MapEntry) ?usize {
    if (e.oid == 0) return null;
    return scene.findOid(e.oid);
}

/// lk_mirror: read what came; apply every whole message.
fn mirror() void {
    while (true) {
        if (in.items.len >= IN_CAP) break;
        in.ensureUnusedCapacity(PA, 64 * 1024) catch break;
        const room = @min(in.capacity - in.items.len, IN_CAP - in.items.len);
        const rc = linux.read(mfd, in.items.ptr + in.items.len, room);
        const er = linux.errno(rc);
        if (er == .AGAIN) break;
        if (er == .INTR) continue;
        if (er != .SUCCESS or rc == 0) {
            disconnect();
            app.log("  live link: the session ended", .{});
            return;
        }
        in.items.len += rc;
    }
    var o: usize = 0;
    mirror_changed = false;
    while (in.items.len - o >= 4) {
        const n = std.mem.readInt(u32, in.items[o..][0..4], .little);
        if (n > IN_CAP - 4) { // (it could never come whole: the original stalled)
            protoBad();
            break;
        }
        if (in.items.len - o < 4 + @as(usize, n)) break;
        apply(in.items[o .. o + 4 + n]);
        if (mfd < 0) break; // (a bad session: closed)
        o += 4 + n;
    }
    if (mfd >= 0 and o > 0) {
        const rest = in.items.len - o;
        std.mem.copyForwards(u8, in.items[0..rest], in.items[o..]);
        in.shrinkRetainingCapacity(rest);
    }
    if (mirror_changed) {
        // (not a step of its own: undo goes back past it, as the original's
        // stack holds only the snapshots its own operators pushed)
        @import("undo.zig").replaceCurrent();
    }
}

fn protoBad() void {
    app.log("  live link: not a BeeModel session (bad HELLO or version)", .{});
    disconnect();
}

fn rd32(p: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, p[o..][0..4], .little);
}
fn rdf(p: []const u8, o: usize) f32 {
    return @bitCast(rd32(p, o));
}

/// apply_msg: one message (its length, type, payload).
fn apply(msg: []const u8) void {
    st_recv += 1;
    app.dirty = true;
    if (msg.len < 5) return; // (a zero length: nothing; the original read past it)
    const t = msg[4];
    const p = msg[5..];
    if (mstate == 1) {
        if (t != M_HELLO or !helloOk(msg)) return protoBad();
        mstate = 2;
        return;
    }
    mirror_changed = true;
    switch (t) {
        M_SNAPB => snapBegin(),
        M_MAT => if (p.len >= 96) applyMat(p),
        M_MESH => applyMesh(p),
        M_OBJECT => if (p.len >= 92) applyObject(p),
        M_XF => if (p.len >= 40) applyXf(p),
        M_PROP => if (p.len >= 40) applyProp(p),
        M_DELETE => if (p.len >= 4) applyDelete(p),
        M_DELTA => if (p.len >= 8) applyDelta(p),
        else => {}, // (TICK, SNAP_END, unknown: nothing)
    }
}

/// A snapshot: the scene starts empty (scene_clear).
fn snapBegin() void {
    mapClear();
    const cur = scene.cursor; // (scene_clear keeps the 3D cursor)
    scene.reset();
    scene.count = 0;
    scene.active = null;
    scene.render_camera = null;
    scene.uid_next = 1;
    scene.cursor = cur;
    @import("images.zig").clear(); // (and the world)
    @import("env.zig").reset();
}

fn applyMat(p: []const u8) void {
    const idx = rd32(p, 0);
    // made up to it
    while (idx >= material.count) {
        if (material.count >= MATS_MAX) return;
        _ = material.new(std.mem.sliceTo(p[4..36], 0)) orelse return;
    }
    // mat_put: 31 bytes of the name, then the values
    const ma = &material.list[idx];
    const rec: *[92]u8 = @ptrCast(ma);
    @memcpy(rec[0..31], p[4..35]);
    rec[31] = 0;
    @memcpy(rec[32..92], p[36..96]);
    material.version +%= 1;
}

/// A MESH payload checked: every count inside the message, every loop a
/// vertex (the original built whatever came).
fn meshOk(p: []const u8) bool {
    if (p.len < 20) return false;
    const nv: u64 = rd32(p, 4);
    const np: u64 = rd32(p, 8);
    const nl: u64 = rd32(p, 12);
    const uv = rd32(p, 16) != 0;
    const need = 20 + nv * 12 + np * 4 + 4 + nl * 4 + (if (uv) nl * 8 else 0);
    if (need > p.len) return false;
    const so: usize = @intCast(20 + nv * 12);
    const lo: usize = @intCast(so + np * 4 + 4);
    var used: u64 = 0;
    for (0..@intCast(np)) |k| {
        const a = rd32(p, so + k * 4);
        const b = rd32(p, so + k * 4 + 4);
        if (b <= a) continue;
        if (b > nl) return false;
        used += b - a;
        for (a..b) |l| {
            if (rd32(p, lo + l * 4) >= nv) return false;
        }
    }
    return used <= nl;
}

/// build_mesh: the mesh a MESH payload holds, in a slot (null: none).
fn buildMesh(p: []const u8) ?u16 {
    if (!meshOk(p)) return null;
    const nv: usize = rd32(p, 4);
    const np: usize = rd32(p, 8);
    const nl: usize = rd32(p, 12);
    const so = 20 + nv * 12;
    const lo = so + np * 4 + 4;
    const A = @import("alloc.zig").A;
    const verts = A.alloc(m.V3, nv) catch return null;
    defer A.free(verts);
    @memcpy(std.mem.sliceAsBytes(verts), p[20..so]);
    // polygons with corners (an empty or backward run is passed over, as mesh_add_poly's caller does)
    const poff = A.alloc(u32, np + 1) catch return null;
    defer A.free(poff);
    const loops = A.alloc(u32, nl) catch return null;
    defer A.free(loops);
    var npo: usize = 0;
    var nlo: usize = 0;
    poff[0] = 0;
    for (0..np) |k| {
        const a = rd32(p, so + k * 4);
        const b = rd32(p, so + k * 4 + 4);
        if (b <= a) continue;
        for (a..b) |l| {
            loops[nlo] = rd32(p, lo + l * 4);
            nlo += 1;
        }
        npo += 1;
        poff[npo] = @intCast(nlo);
    }
    const slot = (if (nv == 0 and npo == 0) scene.addEmptyMesh() else scene.addMesh(verts, poff[0 .. npo + 1], loops[0..nlo])) orelse return null;
    if (rd32(p, 16) != 0 and nlo == nl) {
        const me = &scene.meshes[slot].?;
        if (A.alloc([2]f32, nl)) |uv| {
            @memcpy(std.mem.sliceAsBytes(uv), p[lo + nl * 4 .. lo + nl * 12]);
            me.uv = uv;
        } else |_| {}
    }
    return slot;
}

fn applyMesh(p: []const u8) void {
    if (p.len < 4) return;
    const e = mapFind(rd32(p, 0), true) orelse return;
    if (!meshOk(p)) return;
    if (mapObj(e)) |i| {
        // an object: it takes the mesh
        const o = &scene.objects[i];
        if (!o.kind.isMesh()) return;
        const slot = buildMesh(p) orelse return;
        o.mesh = slot;
        return;
    }
    // else it waits for its object
    const copy = PA.dupe(u8, p) catch return;
    if (e.mesh) |b| PA.free(b);
    e.mesh = copy;
}

/// obj_new's unique_name: "Base", "Base.001" ... (the base 26 bytes at most).
fn uniqueNew(want: []const u8, out: *[32]u8) []const u8 {
    const b = want[0..@min(want.len, 26)];
    var k: u32 = 0;
    var n: usize = 0;
    while (true) : (k += 1) {
        @memcpy(out[0..b.len], b);
        n = b.len;
        if (k > 0) {
            out[n] = '.';
            out[n + 1] = @intCast('0' + k / 100);
            out[n + 2] = @intCast('0' + k % 100 / 10);
            out[n + 3] = @intCast('0' + k % 10);
            n += 4;
        }
        var taken = false;
        for (scene.objects[0..scene.count]) |*o| {
            if (std.mem.eql(u8, o.name(), out[0..n])) {
                taken = true;
                break;
            }
        }
        if (!taken or k >= 999) return out[0..n];
    }
}

/// obj_new: an object of a type, a unique name, a mesh (none: a light's or a
/// camera's); not selected.
fn newObject(kind: scene.Kind, name: []const u8, mesh: ?u16) ?usize {
    if (scene.count >= scene.max_objects) return null;
    var o = scene.Object{ .kind = kind, .mesh = mesh };
    var nb: [32]u8 = undefined;
    o.setName(uniqueNew(name, &nb));
    const i = scene.count;
    scene.objects[i] = o;
    scene.stamp(i);
    scene.count += 1;
    return i;
}

fn applyObject(p: []const u8) void {
    const e = mapFind(rd32(p, 0), true) orelse return;
    const name = std.mem.sliceTo(p[24..56], 0);
    var idx: usize = undefined;
    if (mapObj(e)) |i| {
        idx = i;
        @import("bs_scene.zig").objRename(i, name); // (known: the name may differ)
    } else {
        // new: its type, name, mesh (lights, cameras: their own drawing;
        // other kinds are not mirrored)
        const typ = rd32(p, 4);
        const i = switch (typ) {
            0 => blk: {
                const b = e.mesh orelse return;
                e.mesh = null;
                defer PA.free(b);
                const slot = buildMesh(b) orelse return;
                break :blk newObject(.mesh, name, slot) orelse return;
            },
            1 => newObject(.light, name, null) orelse return,
            2 => newObject(.camera, name, null) orelse return,
            else => return,
        };
        e.oid = scene.objects[i].oid;
        idx = i;
    }
    const o = &scene.objects[idx];
    var xf: [9]f32 = undefined;
    for (0..9) |k| xf[k] = rdf(p, 56 + k * 4);
    setPlace(idx, xf);
    o.visible = rd32(p, 8) & OBF_HIDDEN == 0;
    o.color = rd32(p, 12);
    setMat(o, rd32(p, 16));
}

fn setPlace(i: usize, xf: [9]f32) void {
    const o = &scene.objects[i];
    o.loc = .{ xf[0], xf[1], xf[2] };
    o.setRadians(.{ xf[3], xf[4], xf[5] });
    o.scl = .{ xf[6], xf[7], xf[8] };
}

fn setMat(o: *scene.Object, v: u32) void {
    const w = v +% 1;
    o.mat = if (w <= std.math.maxInt(u16)) @intCast(w) else 0;
}

fn applyXf(p: []const u8) void {
    const e = mapFind(rd32(p, 0), false) orelse return;
    const i = mapObj(e) orelse return;
    var xf: [9]f32 = undefined;
    for (0..9) |k| xf[k] = rdf(p, 4 + k * 4);
    setPlace(i, xf);
}

fn applyProp(p: []const u8) void {
    const e = mapFind(rd32(p, 0), false) orelse return;
    const i = mapObj(e) orelse return;
    const o = &scene.objects[i];
    const v = rd32(p, 8);
    switch (rd32(p, 4)) {
        1 => @import("bs_scene.zig").objRename(i, std.mem.sliceTo(p[8..40], 0)),
        2 => setMat(o, v),
        3 => o.visible = v & OBF_HIDDEN == 0,
        4 => o.color = v,
        else => {},
    }
}

fn applyDelete(p: []const u8) void {
    const e = mapFind(rd32(p, 0), false) orelse return;
    const oid = e.oid;
    e.oid = 0;
    const i = scene.findOid(oid) orelse return;
    scene.remove(i);
}

fn applyDelta(p: []const u8) void {
    const e = mapFind(rd32(p, 0), false) orelse return;
    const i = mapObj(e) orelse return;
    const o = &scene.objects[i];
    const src = o.mesh orelse return;
    if (!o.kind.isMesh()) return;
    // a copy, the runs written in
    const slot = scene.cloneMesh(src) orelse return;
    const me = &scene.meshes[slot].?;
    var ranges = rd32(p, 4);
    var at: usize = 8;
    while (ranges > 0) : (ranges -= 1) {
        if (p.len - at < 8) break;
        const first: u64 = rd32(p, at);
        const count: u64 = rd32(p, at + 4);
        at += 8;
        if (first + count > me.verts.len) break;
        const bytes: usize = @intCast(count * 12);
        if (p.len - at < bytes) break;
        @memcpy(std.mem.sliceAsBytes(me.verts[@intCast(first)..@intCast(first + count)]), p[at .. at + bytes]);
        at += bytes;
    }
    scene.refreshMesh(slot);
    o.mesh = slot;
}

// =============================================================================
//  Stats, operators, the program's end
// =============================================================================

/// link_stat(k): 0 serving, 1 peers synced, 2 bytes sent, 3 messages sent,
/// 4 mirroring, 5 messages received, 6 transforms held back, 7 snapshots sent.
pub fn stat(k: i32) f32 {
    return switch (k) {
        0 => @floatFromInt(@intFromBool(serving)),
        1 => blk: {
            var n: u32 = 0;
            for (&cl) |*c| n += @intFromBool(c.state == 2);
            break :blk @floatFromInt(n);
        },
        2 => @floatFromInt(st_sent),
        3 => @floatFromInt(st_msgs),
        4 => @floatFromInt(@intFromBool(mfd >= 0)),
        5 => @floatFromInt(st_recv),
        6 => @floatFromInt(st_coal),
        7 => @floatFromInt(st_snaps),
        else => 0,
    };
}

/// Mirroring now (the status chip, the Versions editor).
pub fn mirroring() bool {
    return mfd >= 0;
}

/// The program ends: sockets closed, a UNIX socket of ours removed.
pub fn shutdown() void {
    stopServing();
    disconnect();
}

fn opServe() void {
    serve(ops.arg);
}
fn opStop() void {
    stop();
}
fn opConnect() void {
    _ = connect(if (ops.arg.len > 0) ops.arg else null);
}
fn opDisconnect() void {
    disconnect();
}

pub const list = .{
    .{ "link.serve", ops.Impl{ .run = opServe } },
    .{ "link.stop", ops.Impl{ .run = opStop } },
    .{ "link.connect", ops.Impl{ .run = opConnect } },
    .{ "link.disconnect", ops.Impl{ .run = opDisconnect } },
};

// =============================================================================
//  Tests
// =============================================================================

test "link.serve's argument as the original reads it" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 7461), parseServe("").tcp.port);
    try t.expectEqual(@as(u32, 0x0100007f), parseServe("").tcp.ip);
    try t.expectEqual(@as(i32, 9000), parseServe("9000").tcp.port);
    try t.expectEqual(@as(i32, 9000), parseServe("  9000.7 extra").tcp.port);
    try t.expectEqual(@as(u32, 0), parseServe("lan 9000").tcp.ip);
    try t.expectEqual(@as(i32, 9000), parseServe("lan 9000").tcp.port);
    try t.expectEqual(@as(i32, 7461), parseServe("lan").tcp.port);
    try t.expectEqual(@as(i32, -5), parseServe("-5").tcp.port);
    try t.expect(parseServe("abc") == .bad);
    try t.expect(parseServe("lan abc") == .bad);
    try t.expectEqualStrings("/tmp/x.sock", parseServe("unix:/tmp/x.sock more").unix);
    try t.expect(parseServe(" unix:/x") == .bad);
    const long = "unix:" ++ @as([150]u8, @splat('a'));
    try t.expectEqual(@as(usize, 100), parseServe(long).unix.len);
}

test "host:port as the original parses it" {
    const t = std.testing;
    const a = parseHostPort("127.0.0.1:9000").?;
    try t.expectEqual(@as(u32, 0x0100007f), a.ip);
    try t.expectEqual(@as(u16, 9000), a.port);
    try t.expectEqual(@as(u32, 0x0100007f), parseHostPort("localhost:1").?.ip);
    try t.expect(parseHostPort("localhost") == null);
    try t.expect(parseHostPort("localhostx:1") == null);
    try t.expect(parseHostPort("127.0.0:1") == null);
    try t.expect(parseHostPort("256.0.0.1:1") == null);
    try t.expect(parseHostPort("127.0.0.1:") == null);
    try t.expect(parseHostPort("127.0.0.1:65536") == null);
    try t.expect(parseHostPort("127.0.0.1") == null);
    try t.expect(parseHostPort("garbage") == null);
    try t.expect(parseHostPort("") == null);
    // u32 wrapping, as the original's imul: 4294967297 is 1
    try t.expectEqual(@as(u16, 1), parseHostPort("127.0.0.1:4294967297").?.port);
    try t.expectEqual(@as(u16, 80), parseHostPort("127.0.0.1:80junk").?.port);
}

test "the table probes as the original's" {
    const t = std.testing;
    try t.expectEqual(@as(usize, ((@as(u32, 1) *% 0x9E3779B1) >> 19) & 8191), hashOf(1));
    tabClear();
    const a = tabFind(5, true).?;
    try t.expectEqual(hashOf(5), a);
    try t.expectEqual(@as(?usize, null), tabFind(6, false));
    try t.expectEqual(a, tabFind(5, false).?);
    tab[a].state = 1;
    tabClear();
}

test "a HELLO checked: length, type, magic, version" {
    const t = std.testing;
    var b: [49]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], 45, .little);
    b[4] = 1;
    @memcpy(b[5..9], "BEEL");
    b[9] = 1;
    try t.expect(helloOk(&b));
    b[9] = 2;
    try t.expect(!helloOk(&b));
    b[9] = 1;
    std.mem.writeInt(u32, b[0..4], 44, .little);
    try t.expect(!helloOk(&b));
    std.mem.writeInt(u32, b[0..4], 45, .little);
    b[5] = 'X';
    try t.expect(!helloOk(&b));
}

test "a MESH checked before it is built" {
    const t = std.testing;
    // a triangle: 3 vertices, 1 polygon, 3 loops, no UVs
    var p: [20 + 36 + 8 + 12]u8 = @splat(0);
    std.mem.writeInt(u32, p[4..8], 3, .little);
    std.mem.writeInt(u32, p[8..12], 1, .little);
    std.mem.writeInt(u32, p[12..16], 3, .little);
    std.mem.writeInt(u32, p[56..60], 0, .little);
    std.mem.writeInt(u32, p[60..64], 3, .little);
    std.mem.writeInt(u32, p[64..68], 0, .little);
    std.mem.writeInt(u32, p[68..72], 1, .little);
    std.mem.writeInt(u32, p[72..76], 2, .little);
    try t.expect(meshOk(&p));
    try t.expect(!meshOk(p[0 .. p.len - 1])); // short
    std.mem.writeInt(u32, p[72..76], 3, .little); // a loop past the vertices
    try t.expect(!meshOk(&p));
    std.mem.writeInt(u32, p[72..76], 2, .little);
    std.mem.writeInt(u32, p[60..64], 4, .little); // a start past the loops
    try t.expect(!meshOk(&p));
    std.mem.writeInt(u32, p[60..64], 3, .little);
    std.mem.writeInt(u32, p[4..8], 0xffffffff, .little); // counts that overflow
    try t.expect(!meshOk(&p));
}

// =============================================================================
//  The status bar (status.s; the Versions editor's section: versions.zig)
// =============================================================================

const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const Rect = gfx.Rect;

/// The status bar's chip while serving or mirroring (status.s: "Live link:
/// serving" / "Live link: mirroring"), its right edge at `right`: where the
/// next chip's edge goes. A click shows the Versions editor (wd_st_link).
pub fn chip() ?app.Chip {
    const s: []const u8 = if (serving) "Live link: serving" else if (mirroring()) "Live link: mirroring" else return null;
    return .{ .text = s, .label = s, .title = "Live link", .tip = "The live link is on. Click for the Versions editor (serve, connect, stop)", .action = toVersions };
}

fn toVersions() void {
    ops.runId("area.type_versions");
}