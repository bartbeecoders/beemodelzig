// Particle systems (particles.s, stages P1 .. P6).
//
// A particle system belongs to an emitter object (any object; an object can
// have several). It emits from the faces (by area), the volume (inside the
// closed mesh), the vertices, the object's origin, a lattice filling the mesh
// (fill) or another system's events (births, hits, deaths, a liquid's spray);
// at a rate between two frames, or all at once; each particle with a
// lifetime, a speed along the normal or a direction of its own (object axes),
// in a cone of spread, a size and a colour, each a little random when asked
// (a hash of the system's seed and the particle's id, so the same on any
// number of threads).
//
// The settings are 384-byte records by the emitter's uid in one block,
// reference counted and copied on write like the force fields' (the undo
// steps keep the block they saw), kept in .bee files as a PSYS chunk.
//
// The particles live in pooled blocks of 4096 (structure of arrays: place,
// velocity, age, lifetime, size, colour, id, flags), 1024 blocks, 4 million
// at most. A step (one a frame, from the scene's start): every block in
// parallel moves its particles (gravity, the force fields, drag: x += v dt +
// a dt^2 / 2, then v += a dt) and casts their paths against the colliders
// (the Ground, rigid bodies' and cloth colliders' triangles in a tree: bounce,
// die, stick, split; the hits and deaths kept as events), drops the dead (in
// order); liquids are moved by liquid.zig; empty blocks go back to the pool;
// then each system emits what was born during the step, each new particle
// moved on from the moment it was born; then what events give birth to.
//
// Frames go into the simulation cache (simcache.zig channel 2 particles, 3
// liquids: 20 bytes a particle) and play back from it.
//
// Every number goes through the original's single-precision (and, for the
// emission times, double) operations in its order, so the particles match it
// to the bit on any number of threads.
//
// Not in the port yet (marked HOOK): geometry-node point normals, the GPU liquid (liquid.zig).
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const anim = @import("anim.zig");
const scene = @import("scene.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const fields = @import("fields.zig");
const sc = @import("simcache.zig");
const jobs = @import("jobs.zig");
const rc = @import("rbcore.zig");
const mods = @import("mods.zig");
const liquid = @import("liquid.zig");
const landscape = @import("landscape.zig");
const A = @import("alloc.zig").A;

const V4 = rc.V4;
const dot3 = rc.dot3;
const dot4 = rc.dot4;
const cross = rc.cross;
const minss = rc.minss;
const maxss = rc.maxss;
const minps = rc.minps;
const maxps = rc.maxps;
const andXyz = rc.andXyz;
const splat = rc.splat;

// ---- the settings ---------------------------------------------------------------------------

/// A system's record (PS_*), as in memory and in the file.
pub const Rec = extern struct {
    uid: u32 = 0, // its emitter's uid
    flags: u32 = 0, // 1: off
    from: u32 = 0, // 0 faces, 1 volume, 2 vertices, 3 a point, 4 events, 5 fill
    mode: u32 = 0, // 0 at a rate, 1 all at once
    rate: f32 = 100.0, // 16
    num: u32 = 1000, // a burst's count
    start: f32 = 1.0, // frames
    end: f32 = 1000000.0,
    life: f32 = 3.0, // 32
    lifer: f32 = 0,
    speed: f32 = 2.0,
    speedr: f32 = 0,
    dir: [3]f32 = .{ 0, 1, 0 }, // 48 (object axes)
    vmode: u32 = 0, // 0 along the normal, 1 along dir
    spread: f32 = 0, // 64 degrees
    size: f32 = 0.05,
    sizer: f32 = 0,
    drag: f32 = 0,
    grav: f32 = 1.0, // 80
    color: u32 = 0x9fc8ff,
    seed: u32 = 0,
    group: u32 = 0,
    max: u32 = 0, // 96
    pad0: [3]u32 = .{ 0, 0, 0 },
    name: [16]u8 = .{ 'P', 'a', 'r', 't', 'i', 'c', 'l', 'e', 's', 0, 0, 0, 0, 0, 0, 0 }, // 112
    draw: u32 = 1, // 128: 0 points, 1 sprites, 2 objects
    color2: u32 = 0x9fc8ff,
    ramp: u32 = 0,
    sizeend: f32 = 1.0,
    objs: [8]u32 = @splat(0), // 144
    nobj: u32 = 0, // 176
    alignv: u32 = 0, // 0 at random, 1 along the velocity
    rflags: u32 = 0, // bit 0: left out of renders
    px: f32 = 2.0, // points: pixels across
    coll: u32 = 0, // 192 bit 0: collides
    bounce: f32 = 0.3,
    fric: f32 = 0.1,
    onhit: u32 = 0, // 0 bounces, 1 dies, 2 sticks, 3 splits
    splitn: u32 = 2, // 208
    evkind: u32 = 1, // from events: 0 born, 1 hit, 2 died, 3 spray
    evper: u32 = 3,
    inherit: f32 = 0,
    evname: [16]u8 = @splat(0), // 224
    liq: u32 = 0, // 240 bit 0: a liquid
    visc: f32 = 0.02,
    vort: f32 = 0,
    tens: f32 = 0,
    lsub: u32 = 8, // 256
    liter: u32 = 2,
    domain: [6]f32 = @splat(0),
    domon: u32 = 0, // 288
    dens: f32 = 1000.0,
    surf: u32 = 0,
    sres: f32 = 1.0,
    sprayv: f32 = 2.0, // 304
    sprayn: u32 = 14,
    rest: [72]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(Rec) == 384);
    std.debug.assert(@offsetOf(Rec, "name") == 112 and @offsetOf(Rec, "draw") == 128);
    std.debug.assert(@offsetOf(Rec, "objs") == 144 and @offsetOf(Rec, "coll") == 192);
    std.debug.assert(@offsetOf(Rec, "evname") == 224 and @offsetOf(Rec, "liq") == 240);
    std.debug.assert(@offsetOf(Rec, "domain") == 264 and @offsetOf(Rec, "sprayn") == 308);
}

pub const PS_SZ = 384;
pub const MAX = 64; // systems in a scene

pub const Block = struct {
    refs: u32 = 1,
    n: u32 = 0,
    r: [MAX]Rec = undefined,
};

/// The block now (null: none).
pub var cur: ?*Block = null;

fn unref(b: ?*Block) void {
    const x = b orelse return;
    x.refs -= 1;
    if (x.refs == 0) A.destroy(x);
}

/// ps_reset: no systems (a new scene).
pub fn resetSettings() void {
    unref(cur);
    cur = null;
}

/// The undo steps: a snapshot holds a reference to the block it saw.
pub fn keep(slot: *?*Block) void {
    if (cur) |b| b.refs += 1;
    unref(slot.*);
    slot.* = cur;
}
pub fn restore(b: ?*Block) void {
    if (b) |x| x.refs += 1;
    unref(cur);
    cur = b;
}

/// ps_own: cur, unshared (made when none); null without memory.
fn own() ?*Block {
    if (cur) |b| {
        if (b.refs == 1) return b;
    }
    const nb = A.create(Block) catch return null;
    nb.* = .{};
    if (cur) |b| {
        nb.n = b.n;
        @memcpy(nb.r[0..b.n], b.r[0..b.n]);
    }
    unref(cur);
    cur = nb;
    return nb;
}

/// ps_nth: the k-th system of the object with this uid (read only), or null.
pub fn nth(uid: u32, k0: u32) ?*const Rec {
    const b = cur orelse return null;
    var k = k0;
    for (b.r[0..b.n]) |*r| {
        if (r.uid != uid) continue;
        if (k == 0) return r;
        k -= 1;
    }
    return null;
}

/// ps_count: its object's systems.
pub fn count(uid: u32) u32 {
    const b = cur orelse return 0;
    var n: u32 = 0;
    for (b.r[0..b.n]) |*r| n += @intFromBool(r.uid == uid);
    return n;
}

/// ps_nth_own: that system, writable, or null.
pub fn nthOwn(uid: u32, k: u32) ?*Rec {
    if (nth(uid, k) == null) return null;
    _ = own() orelse return null;
    return @constCast(nth(uid, k));
}

/// ps_new: a new system with the defaults (writable), or null (64 already).
fn new(uid: u32) ?*Rec {
    const b = own() orelse return null;
    if (b.n >= MAX) return null;
    b.r[b.n] = .{ .uid = uid };
    b.n += 1;
    return &b.r[b.n - 1];
}

/// ps_del: true when there was one.
fn del(uid: u32, k: u32) bool {
    const r = nthOwn(uid, k) orelse return false;
    const b = cur.?;
    const i = (@intFromPtr(r) - @intFromPtr(&b.r[0])) / PS_SZ;
    std.mem.copyForwards(Rec, b.r[i .. b.n - 1], b.r[i + 1 .. b.n]);
    b.n -= 1;
    return true;
}

/// ps_copy: a duplicate's systems (object.duplicate).
pub fn copy(uid: u32, new_uid: u32) void {
    if (count(uid) == 0) return;
    var k: u32 = 0;
    while (k < count(uid)) : (k += 1) {
        const r = new(new_uid) orelse return;
        const s = nth(uid, k) orelse return; // (the block may have been copied)
        const keep_uid = r.uid;
        r.* = s.*;
        r.uid = keep_uid;
    }
}

/// ps_write: the PSYS chunk: count, a record's size, the records.
pub fn write(out: anytype) void {
    const n: u32 = if (cur) |b| b.n else 0;
    out.u32_(n);
    out.u32_(PS_SZ);
    if (n > 0) out.bytes(std.mem.sliceAsBytes(cur.?.r[0..n]));
}

/// ps_read: as the original reads it: too short, a record size of 0, or
/// fewer bytes than the count says, and there are no systems (at most 64;
/// each record the defaults, then what the file has of it).
pub fn read(c: []const u8) void {
    resetSettings();
    if (c.len < 8) return;
    const n: u32 = @min(std.mem.readInt(u32, c[0..4], .little), MAX);
    const rs: u32 = std.mem.readInt(u32, c[4..8], .little);
    if (rs == 0) return;
    // (the original's 32-bit product)
    const need: u32 = rs *% n +% 8;
    if (need > c.len) return;
    // (past what the 32-bit product saw the original reads beyond the chunk:
    // here, no systems)
    if (@as(u64, rs) * n + 8 > c.len) return;
    const b = A.create(Block) catch return;
    b.* = .{ .n = n };
    var p: usize = 8;
    for (b.r[0..n]) |*r| {
        r.* = .{};
        const k = @min(rs, PS_SZ);
        @memcpy(std.mem.asBytes(r)[0..k], c[p..][0..k]);
        p += rs;
    }
    cur = b;
}

/// What the cache key and the viewport see of the settings.
pub fn settingsBytes() []const u8 {
    const b = cur orelse return &.{};
    return std.mem.sliceAsBytes(b.r[0..b.n]);
}

// ---- the words ----------------------------------------------------------------------------

/// im_next_word: words split at spaces only, each at most 255 bytes.
const Words = struct {
    s: []const u8,
    i: usize = 0,
    fn next(w: *Words) ?[]const u8 {
        while (w.i < w.s.len and w.s[w.i] == ' ') w.i += 1;
        const st = w.i;
        while (w.i < w.s.len and w.s[w.i] != ' ' and w.s[w.i] != 0) w.i += 1;
        if (w.i == st) {
            w.i = w.s.len;
            return null;
        }
        return w.s[st..@min(w.i, st + 255)];
    }
    fn rest(w: *const Words) []const u8 {
        return w.s[w.i..];
    }
};

const Kind = enum { float, whole, list, on, off, col, rate, burst, normal, dir, name, col2, objs, render, onoff, events, split, visc, domain };
const Word = struct { w: []const u8, off: usize, k: Kind, list: []const []const u8 = &.{} };
const kw_from = [_][]const u8{ "faces", "volume", "verts", "point", "events", "fill" };
const kw_visc = [_][]const u8{ "water", "oil", "honey" };
const viscs = [3]f32{ 0.02, 0.2, 0.6 };
const kw_onhit = [_][]const u8{ "bounce", "die", "stick", "split" };
const kw_ev = [_][]const u8{ "born", "hit", "died", "spray" };
const kw_draw = [_][]const u8{ "points", "sprites", "objects" };
const kw_align = [_][]const u8{ "random", "velocity" };
const kw_onoff = [_][]const u8{ "off", "on" };
const pp_tab = [_]Word{
    .{ .w = "from", .off = 8, .k = .list, .list = &kw_from },
    .{ .w = "rate", .off = 16, .k = .rate },
    .{ .w = "burst", .off = 20, .k = .burst },
    .{ .w = "start", .off = 24, .k = .float },
    .{ .w = "end", .off = 28, .k = .float },
    .{ .w = "life", .off = 32, .k = .float },
    .{ .w = "life_random", .off = 36, .k = .float },
    .{ .w = "speed", .off = 40, .k = .float },
    .{ .w = "speed_random", .off = 44, .k = .float },
    .{ .w = "normal", .off = 60, .k = .normal },
    .{ .w = "direction", .off = 48, .k = .dir },
    .{ .w = "spread", .off = 64, .k = .float },
    .{ .w = "size", .off = 68, .k = .float },
    .{ .w = "size_random", .off = 72, .k = .float },
    .{ .w = "drag", .off = 76, .k = .float },
    .{ .w = "gravity", .off = 80, .k = .float },
    .{ .w = "color", .off = 84, .k = .col },
    .{ .w = "colour", .off = 84, .k = .col },
    .{ .w = "seed", .off = 88, .k = .whole },
    .{ .w = "group", .off = 92, .k = .whole },
    .{ .w = "max", .off = 96, .k = .whole },
    .{ .w = "name", .off = 112, .k = .name },
    .{ .w = "draw", .off = 128, .k = .list, .list = &kw_draw },
    .{ .w = "color_end", .off = 132, .k = .col2 },
    .{ .w = "colour_end", .off = 132, .k = .col2 },
    .{ .w = "size_end", .off = 140, .k = .float },
    .{ .w = "objects", .off = 144, .k = .objs },
    .{ .w = "align", .off = 180, .k = .list, .list = &kw_align },
    .{ .w = "render", .off = 184, .k = .render, .list = &kw_onoff },
    .{ .w = "point_px", .off = 188, .k = .float },
    .{ .w = "collide", .off = 192, .k = .onoff, .list = &kw_onoff },
    .{ .w = "bounce", .off = 196, .k = .float },
    .{ .w = "friction", .off = 200, .k = .float },
    .{ .w = "on_hit", .off = 204, .k = .list, .list = &kw_onhit },
    .{ .w = "split", .off = 208, .k = .split },
    .{ .w = "events", .off = 212, .k = .events, .list = &kw_ev },
    .{ .w = "per", .off = 216, .k = .whole },
    .{ .w = "inherit", .off = 220, .k = .float },
    .{ .w = "liquid", .off = 240, .k = .onoff, .list = &kw_onoff },
    .{ .w = "viscosity", .off = 244, .k = .visc, .list = &kw_visc },
    .{ .w = "vorticity", .off = 248, .k = .float },
    .{ .w = "tension", .off = 252, .k = .float },
    .{ .w = "substeps", .off = 256, .k = .whole },
    .{ .w = "iterations", .off = 260, .k = .whole },
    .{ .w = "domain", .off = 264, .k = .domain },
    .{ .w = "density", .off = 292, .k = .float },
    .{ .w = "surface", .off = 296, .k = .onoff, .list = &kw_onoff },
    .{ .w = "resolution", .off = 300, .k = .float },
    .{ .w = "spray_speed", .off = 304, .k = .float },
    .{ .w = "spray_neighbours", .off = 308, .k = .whole },
    .{ .w = "on", .off = 0, .k = .on },
    .{ .w = "off", .off = 0, .k = .off },
};

fn indexIn(words: []const []const u8, w: []const u8) ?u32 {
    for (words, 0..) |x, i| {
        if (std.mem.eql(u8, x, w)) return @intCast(i);
    }
    return null;
}

/// cvttss2si: out of range or NaN gives 0x80000000.
pub fn cvtt(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}

/// cvtss2si: to the nearest, ties to even (out of range: 0x80000000).
pub fn cvtn(x: f32) i32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    const f = @floor(x);
    const d = x - f;
    var r: i64 = @intFromFloat(f);
    if (d > 0.5 or (d == 0.5 and @mod(r, 2) != 0)) r += 1;
    return @intCast(std.math.clamp(r, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn parseFloat(s: []const u8) ?f32 {
    return @import("print.zig").parseFloat(s);
}

/// pp_hex: RRGGBB (# or 0x before it): its value, or null when no digit came.
fn hex(w0: []const u8) ?u32 {
    var w = w0;
    if (w.len > 0 and w[0] == '#') w = w[1..];
    if (w.len >= 2 and w[0] == '0' and w[1] == 'x') w = w[2..];
    var v: u32 = 0;
    var any = false;
    for (w) |ch| {
        var c: u32 = ch -% '0';
        if (c > 9) {
            c = (ch | 0x20) -% 'a';
            if (c > 5) return null;
            c += 10;
        }
        v = v << 4 | c;
        any = true;
    }
    return if (any) v & 0xffffff else null;
}

/// A name into 16 bytes as the original copies one: up to 15, a 0 after
/// (what was there past it stays).
fn putName(dst: *[16]u8, s: []const u8) void {
    const n = @min(s.len, 15);
    @memcpy(dst[0..n], s[0..n]);
    dst[n] = 0;
}

fn bad(w: []const u8) bool {
    app.log("  particles: not understood: {s}", .{w});
    return false;
}

/// world_box: object i's mesh bounds' corners in the world, their box.
fn worldBox(i: usize) ?[6]f32 {
    const me = mods.of(i) orelse return null;
    const mt = matRows(i);
    var lo: V4 = .{ 1e30, 1e30, 1e30, 0 };
    var hi: V4 = .{ -1e30, -1e30, -1e30, -0.0 };
    for (0..8) |k| {
        var ca: [4]f32 = .{ 0, 0, 0, 0 };
        for (0..3) |a| ca[a] = if (k >> @intCast(a) & 1 != 0) me.hi[a] else me.lo[a];
        const c: V4 = ca;
        const p = mPt(&mt, c);
        lo = minps(lo, p);
        hi = maxps(hi, p);
    }
    return .{ lo[0], lo[1], lo[2], hi[0], hi[1], hi[2] };
}

/// ps_parse: "rate 200 life 2 ..." into a record; false at a word it does
/// not understand (said in the console; what came before it stays).
pub fn parse(r: *Rec, text: []const u8) bool {
    var it = Words{ .s = text };
    const bytes: *[PS_SZ]u8 = @ptrCast(r);
    while (it.next()) |w| {
        const e = for (pp_tab) |e| {
            if (std.mem.eql(u8, e.w, w)) break e;
        } else return bad(w);
        switch (e.k) {
            .on => {
                r.flags &= ~@as(u32, 1);
                continue;
            },
            .off => {
                r.flags |= 1;
                continue;
            },
            .normal => {
                r.vmode = 0;
                continue;
            },
            .dir => {
                for (0..3) |k| {
                    const v = it.next() orelse return bad("");
                    r.dir[k] = parseFloat(v) orelse return bad(v);
                }
                r.vmode = 1;
                continue;
            },
            else => {},
        }
        const val = it.next() orelse return bad("");
        switch (e.k) {
            .list => {
                const k = indexIn(e.list, val) orelse return bad(val);
                std.mem.writeInt(u32, bytes[e.off..][0..4], k, .little);
            },
            .col => r.color = hex(val) orelse return bad(val),
            .col2 => {
                r.color2 = hex(val) orelse return bad(val);
                r.ramp |= 1;
            },
            .render => {
                const k = indexIn(e.list, val) orelse return bad(val);
                r.rflags &= ~@as(u32, 1);
                if (k == 0) r.rflags |= 1;
            },
            .onoff => {
                const k = indexIn(e.list, val) orelse return bad(val);
                const p: *u32 = @ptrCast(@alignCast(&bytes[e.off]));
                p.* = (p.* & ~@as(u32, 1)) | k;
            },
            .visc => {
                if (indexIn(e.list, val)) |k| {
                    r.visc = viscs[k];
                } else r.visc = parseFloat(val) orelse return bad(val);
            },
            .domain => {
                if (std.mem.eql(u8, val, "off")) {
                    r.domon &= ~@as(u32, 1);
                } else if (parseFloat(val)) |x0| {
                    r.domain[0] = x0;
                    for (1..6) |k| {
                        const v = it.next() orelse return bad("");
                        r.domain[k] = parseFloat(v) orelse return bad(v);
                    }
                    r.domon |= 1;
                } else {
                    const i = scene.find(val[0..@min(val.len, 32)]) orelse return bad(val);
                    r.domain = worldBox(i) orelse return bad(val);
                    r.domon |= 1;
                }
            },
            .split => {
                const x = parseFloat(val) orelse return bad(val);
                var k = cvtt(x);
                if (k < 1) k = 1;
                if (k > 64) k = 64;
                r.splitn = @intCast(k);
                r.onhit = 3;
                r.coll |= 1;
            },
            .events => {
                const k = indexIn(e.list, val) orelse return bad(val);
                r.evkind = k;
                r.from = 4;
                const nm = it.next() orelse return bad("");
                putName(&r.evname, nm);
            },
            .objs => {
                r.nobj = 0;
                var parts = std.mem.splitScalar(u8, val, ',');
                while (parts.next()) |p0| {
                    if (p0.len == 0) continue;
                    const p = p0[0..@min(p0.len, 31)];
                    const i = scene.find(p) orelse return bad(val);
                    if (r.nobj >= 8) continue;
                    r.objs[r.nobj] = scene.objects[i].uid;
                    r.nobj += 1;
                }
                if (r.nobj == 0) return bad(val);
                r.draw = 2;
            },
            .name => putName(&r.name, val),
            .float, .whole, .rate, .burst => {
                const x = parseFloat(val) orelse return bad(val);
                if (e.k == .rate) r.mode = 0;
                if (e.k == .burst) r.mode = 1;
                const bits: u32 = if (e.k == .whole or e.k == .burst) @bitCast(cvtt(maxss(x, 0))) else @bitCast(x);
                std.mem.writeInt(u32, bytes[e.off..][0..4], bits, .little);
            },
            .on, .off, .normal, .dir => unreachable,
        }
    }
    return true;
}

// ---- the pool --------------------------------------------------------------------------------

pub const BLK = 4096;
const BLKSH = 12;
pub const NBLK = 1024;
pub const A_X = 0;
pub const A_Y = 1;
pub const A_Z = 2;
pub const A_VX = 3;
pub const A_VY = 4;
pub const A_VZ = 5;
pub const A_AGE = 6;
pub const A_LIFE = 7;
pub const A_SIZE = 8;
pub const A_COL = 9;
pub const A_ID = 10;
pub const A_FLAG = 11;
const NARR = 12;
const BLK_BYTES = NARR * BLK * 4;
const EV_CAP = 2 * BLK * NBLK; // a system's events a step, at most

/// An event (EV_*): its place (w: its kind), velocity (w: the particle's id),
/// the surface's normal.
pub const Ev = struct {
    p: V4 align(16),
    v: V4,
    n: V4,
};

/// A running system (SR_*).
pub const Sys = struct {
    uid: u32 = 0,
    k: u32 = 0, // which of its object's systems
    nb: u32 = 0, // blocks
    n: u32 = 0, // particles alive
    next: u32 = 0, // the next id to be born
    src: u32 = 0, // where from, this step
    mesh: ?*const scene.Mesh = null,
    mat: [3]V4 = @splat(@splat(0)), // its object's matrix this step (rows)
    cdf: []f32 = &.{}, // faces: the areas summed
    cdfn: u32 = 0,
    cdfk: u64 = 0,
    rec: ?*const Rec = null, // its settings this step (null: off)
    en: u32 = 0, // born this step: how many,
    eid: u32 = 0, //  the first one's id,
    elb: i32 = -1, //  the last block before,
    ec: u32 = 0, //  its count,
    er: u32 = 0, //  its room,
    enb: u32 = 0, //  blocks before
    acc: V4 = @splat(0),
    gadj: V4 = @splat(0),
    ts: f64 = 0,
    rate: f64 = 0,
    t1: f64 = 0,
    gbit: u32 = 0,
    damp: f32 = 0,
    seed: u32 = 0,
    tot: f32 = 0,
    si: u32 = 0,
    listen: u32 = 0, // events to keep: 1 hits, 2 deaths
    l0: u32 = 0,
    ln: u32 = 0,
    nh: u32 = 0,
    nd: u32 = 0,
    emode: u32 = 0, // being born from: 0 its source, 1 hits, 2 births, 3 its own hits, 4 deaths
    evp: u32 = 0,
    enext: u32 = 0,
    evh: ?[*]Ev = null,
    evd: ?[*]Ev = null,
    evs: ?*Sys = null,
    eva: ?[*]Ev = null,
    collon: u32 = 0,
    bounce: f32 = 0,
    fric: f32 = 0,
    onhit: u32 = 0,
    hits: u32 = 0,
    rest: f32 = 0,
    liqon: u32 = 0,
    fillp: []u32 = &.{},
    fnx: u32 = 0,
    fny: u32 = 0,
    fo: V4 = @splat(0),
    fd: V4 = @splat(0),
    /// the liquid's surface (partsurf.zig)
    surf: SurfState = .{},
};

/// What a system's surface keeps (partsurf.zig fills it).
pub const SurfState = struct {
    mesh: ?*scene.Mesh = null,
    ms: f32 = 0,
    has: bool = false,
    dirty: bool = false,
    field: []f32 = &.{},
    org: V4 = @splat(0),
    nx: u32 = 0,
    ny: u32 = 0,
    nz: u32 = 0,
};

pub var sr: [MAX]Sys = @splat(.{});
pub var ns: u32 = 0; // running systems
var on: bool = false;
pub var now: u32 = 0; // steps done
var busy: bool = false;
var dt: f32 = 0;
var dtd: f64 = 0;
var t0d: f64 = 0;
var t1d: f64 = 0;
var nfields: u32 = 0;
var msf: f32 = 0; // the last frame's time (ms)
var mss: f32 = 0; //  and step's
var used: u32 = 0; // blocks ever used
var played: bool = false;
pub var start: i32 = 0; // the scene's first frame
var tgt: i32 = 0;
var hash: u64 = 0;
var g: V4 = @splat(0);

var pool: ?[*]u8 = null;
pub var bn: [NBLK]u32 = @splat(0); // each block's count
var bsys: [NBLK]u32 = @splat(0);
var freel: [NBLK]u32 = @splat(0);
var blist: [NBLK]u32 = @splat(0);
pub var sblk: [MAX][NBLK]u32 = undefined; // each system's blocks
var nfree: u32 = 0;
var nlist: u32 = 0;
var ev_bh: [NBLK]u32 = @splat(0);
var ev_bd: [NBLK]u32 = @splat(0);
var stage: ?[*]Ev = null;

fn mmapNr(bytes: usize) ?[*]u8 {
    const r = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    if (linux.errno(r) != .SUCCESS) return null;
    return @ptrFromInt(r);
}
fn munmap(p: anytype, bytes: usize) void {
    _ = linux.munmap(@ptrCast(p), bytes);
}

/// A block's array (floats).
pub inline fn arr(b: u32, a: usize) [*]f32 {
    return @ptrCast(@alignCast(pool.? + @as(usize, b) * BLK_BYTES + a * BLK * 4));
}
pub inline fn arrU(b: u32, a: usize) [*]u32 {
    return @ptrCast(@alignCast(pool.? + @as(usize, b) * BLK_BYTES + a * BLK * 4));
}

/// pool_init: true when the pool is there.
fn poolInit() bool {
    if (pool != null) return true;
    pool = mmapNr(@as(usize, NBLK) * BLK_BYTES) orelse return false;
    freeAll();
    stage = @ptrCast(@alignCast(mmapNr(@as(usize, NBLK) * 2 * BLK * @sizeOf(Ev))));
    return true;
}

fn evReserve() ?[*]Ev {
    return @ptrCast(@alignCast(mmapNr(@as(usize, EV_CAP) * @sizeOf(Ev))));
}

/// free_all_blocks: every block free again (popped 0, 1, 2 ...).
fn freeAll() void {
    nfree = NBLK;
    for (0..NBLK) |c| freel[c] = @intCast(NBLK - 1 - c);
}

fn blkGet() ?u32 {
    if (nfree == 0) return null;
    nfree -= 1;
    const b = freel[nfree];
    bn[b] = 0;
    if (b + 1 > used) used = b + 1;
    return b;
}
fn blkPut(b: u32) void {
    freel[nfree] = b;
    nfree += 1;
}

/// pt_stop: no particles (the pool kept for the next run).
fn stop() void {
    for (sr[0..ns]) |*s| {
        if (s.cdf.len > 0) A.free(s.cdf);
        @import("partsurf.zig").free(s);
        if (s.evh) |p| munmap(p, @as(usize, EV_CAP) * @sizeOf(Ev));
        if (s.evd) |p| munmap(p, @as(usize, EV_CAP) * @sizeOf(Ev));
        if (s.fillp.len > 0) A.free(s.fillp);
    }
    for (&sr) |*s| s.* = .{};
    ns = 0;
    on = false;
    now = 0;
    if (pool != null) freeAll();
}

/// pt_reset: a new scene: no particles, the pool's pages given back.
pub fn reset() void {
    stop();
    hash = 0;
    if (pool) |p| {
        const bytes = @as(usize, used) * BLK_BYTES;
        if (bytes > 0) {
            _ = linux.madvise(p, bytes, linux.MADV.DONTNEED);
            used = 0;
        }
    }
    @import("partdraw.zig").reset();
}

/// pt_build: a running system for each record.
fn build() void {
    stop();
    liquid.resetBodies();
    if (poolInit()) {
        if (cur) |b| {
            for (b.r[0..b.n], 0..) |*r, i| {
                const s = &sr[ns];
                s.si = ns;
                ns += 1;
                s.uid = r.uid;
                var k: u32 = 0;
                for (b.r[0..i]) |*q| k += @intFromBool(q.uid == r.uid);
                s.k = k;
                s.seed = r.seed *% 0xC2B2AE3D +% r.uid *% 0x27d4eb2f;
            }
            on = true;
        }
    }
    played = false;
}

// ---- frames -----------------------------------------------------------------------------------

/// pt_key: the systems' settings, the animation, where the emitters nothing
/// moves are and their meshes, the force fields (what the particles at a
/// frame depend on). (The original mixes in its meshes' addresses: here the
/// mesh slot and the mesh made there.)
fn key() u64 {
    var h: u64 = 0x51ED270B27D4EB2F;
    const b = cur orelse return h;
    h = sc.mix(h, settingsBytes());
    h = fields.animHash(h);
    for (b.r[0..b.n]) |*r| {
        const i = scene.findUid(r.uid) orelse continue;
        const o = &scene.objects[i];
        if (!anim.moves(o.oid)) {
            const rad = o.radians();
            const p = [9]f32{ o.loc[0], o.loc[1], o.loc[2], rad[0], rad[1], rad[2], o.scl[0], o.scl[1], o.scl[2] };
            h = sc.mix(h, std.mem.asBytes(&p));
        }
        const me0: ?*const scene.Mesh = if (o.mesh) |mi| (if (scene.meshes[mi]) |*x| x else null) else null;
        const st = [3]u64{ if (o.mesh) |mi| mi else 0xffff, if (me0) |x| x.serial else 0, if (me0) |x| x.shape else 0 };
        h = sc.mix(h, std.mem.asBytes(&st));
        h = sc.mix(h, std.mem.sliceAsBytes(o.mods.m[0..o.mods.n]));
        h = sc.meshHash(h, scene.meshOfObj(i));
    }
    return fields.mix(h);
}

fn animStart() i32 {
    return if (anim.cur != null) @import("frange.zig").r.start else 0;
}

/// pt_frame: the particles at that frame: none at or before the scene's
/// start; else stepped on from where they are (begun again when going back
/// or something they depend on changed); or played from the cache.
pub fn frame(f: f32) void {
    if (busy) return;
    busy = true;
    defer busy = false;
    const b = cur orelse return gone();
    if (b.n == 0) return gone();
    var fps: f32 = 24.0;
    if (anim.cur != null) {
        const x = @import("frange.zig").r.fps;
        if (x > 0) fps = x;
    }
    dtd = 1.0 / @as(f64, fps);
    dt = @floatCast(dtd);
    var steps = cvtt(@floor(f));
    const st = animStart();
    start = st;
    steps -%= st;
    if (steps <= 0) {
        if (on) {
            stop();
            app.dirty = true;
        }
        return;
    }
    tgt = steps;
    const k = key();
    const kinds = kindsOf();
    const baked2 = sc.check(2, k, st);
    const baked3 = sc.check(3, k, st);
    var r2: ?[]u8 = null;
    var r3: ?[]u8 = null;
    var missing: u32 = 0;
    if (kinds & 1 != 0) {
        r2 = cached(2, baked2);
        if (r2 == null) missing += 1;
    }
    if (kinds & 2 != 0) {
        r3 = cached(3, baked3);
        if (r3 == null) missing += 1;
    }
    var t_0: u64 = undefined;
    if (missing == 0) {
        t_0 = rc.nowNs();
        play(r2, r3, @bitCast(steps), k);
    } else {
        if (!(on and !played and k == hash and @as(u32, @bitCast(steps)) >= now)) {
            build();
            hash = k;
            if (!on) return;
        }
        t_0 = rc.nowNs();
        while (now < @as(u32, @bitCast(steps))) {
            step();
            now += 1;
            record(@as(i32, @bitCast(now)) +% start);
        }
    }
    for (sr[0..ns]) |*s| @import("partsurf.zig").build(s);
    msf = @as(f32, @floatFromInt(@as(i64, @intCast(rc.nowNs() - t_0)))) * 0.001 * 0.001;
    app.dirty = true;
}

fn gone() void {
    sc.clear(2);
    sc.clear(3);
    if (on) {
        reset();
        app.dirty = true;
    }
}

/// pt_step: one step: everything moves, the dead go, the newborn come.
fn step() void {
    const t_0 = rc.nowNs();
    t0d = @as(f64, @floatFromInt(now)) * dtd;
    t1d = t0d + dtd;
    const tf: f32 = @as(f32, @floatFromInt(start +% @as(i32, @bitCast(now)))) * dt;
    g = andXyz(@import("rbody.zig").gravity());
    fields.prep(tf, .{ g[0], g[1], g[2] });
    nfields = fields.n;
    if (anyColl()) colliders() else pc_any = false;
    var nl: u32 = 0;
    for (sr[0..ns], 0..) |*s, i| {
        sysPrep(s);
        s.l0 = nl;
        s.ln = if (s.liqon != 0) 0 else s.nb;
        if (s.ln == 0) continue;
        for (sblk[i][0..s.nb]) |bk| {
            blist[nl] = bk;
            bsys[bk] = @intCast(i);
            nl += 1;
        }
    }
    nlist = nl;
    listen();
    var dummy: u8 = 0;
    jobs.parallelFor(nlist, 1, &dummy, stepJob);
    for (sr[0..ns]) |*s| {
        if (s.liqon != 0) sysLiquid(s);
    }
    for (sr[0..ns]) |*s| {
        gather(s);
        tidy(s);
        emit(s, false);
    }
    for (sr[0..ns]) |*s| emit(s, true);
    mss = @as(f32, @floatFromInt(@as(i64, @intCast(rc.nowNs() - t_0)))) * 0.001 * 0.001;
}

/// any_coll: a running system collides.
fn anyColl() bool {
    for (sr[0..ns]) |*s| {
        const r = nth(s.uid, s.k) orelse continue;
        if (r.coll & 1 != 0) return true;
    }
    return false;
}

/// The object's matrix as rows (obj_matrix: translation in w).
pub fn matRows(i: usize) [3]V4 {
    const mt = fields.objMatrix(i);
    return .{ .{ mt[0], mt[1], mt[2], mt[3] }, .{ mt[4], mt[5], mt[6], mt[7] }, .{ mt[8], mt[9], mt[10], mt[11] } };
}

/// m_pt: M p (w 0).
pub fn mPt(m: *const [3]V4, p: V4) V4 {
    const q: V4 = .{ p[0], p[1], p[2], 1 };
    return .{ dot4(q, m[0]), dot4(q, m[1]), dot4(q, m[2]), 0 };
}
/// m_vec: M v without the move (w 0).
pub fn mVec(m: *const [3]V4, p: V4) V4 {
    const q: V4 = .{ p[0], p[1], p[2], 0 };
    return .{ dot4(q, m[0]), dot4(q, m[1]), dot4(q, m[2]), 0 };
}
/// unit: v / |v| (w 0).
pub fn unit(v0: V4) V4 {
    const v = andXyz(v0);
    var d = dot3(v, v);
    d = maxss(d, 1.0e-12);
    return v / splat(@sqrt(d));
}

/// sys_prep: its settings, its object's place and mesh, its pull and drag
/// this step.
fn sysPrep(s: *Sys) void {
    s.rec = null;
    s.mesh = null;
    const r0 = nth(s.uid, s.k);
    const d = Rec{};
    const r = r0 orelse &d;
    s.acc = splat(r.grav) * g;
    s.gadj = splat(r.grav - 1.0) * g;
    s.damp = 1.0 / (r.drag * dt + 1.0);
    s.gbit = @as(u32, 1) << @intCast(r.group & 15);
    s.collon = r.coll & 1 & @intFromBool(pc_any);
    s.bounce = r.bounce;
    s.fric = r.fric;
    s.onhit = r.onhit;
    s.liqon = r.liq & 1;
    s.rest = dot3(s.acc, s.acc) * dt * dt * 4.0;
    const rec = r0 orelse return;
    if (rec.flags & 1 != 0) return;
    const i = scene.findUid(s.uid) orelse return;
    s.mat = matRows(i);
    var from = rec.from;
    // (a damaged file's source past fill: its origin, where the original
    // would read areas it never made)
    if (from > 5) from = 3;
    if (from == 3 or from == 4) {
        s.src = from;
    } else {
        const me = rawMesh(i);
        if (me != null and me.?.verts.len != 0 and (from == 2 or me.?.tris.len != 0)) {
            s.mesh = me;
            s.src = from;
        } else s.src = 3; // no mesh to emit from: its origin
    }
    s.rec = rec;
    const st: f64 = @floatFromInt(animStart());
    s.ts = (@as(f64, rec.start) - st) * dtd;
    s.rate = rec.rate;
    s.t1 = t1d;
}

/// obj_eval with pt_raw: what the object is (not a liquid's surface).
pub var raw: bool = false;
fn rawMesh(i: usize) ?*const scene.Mesh {
    raw = true;
    defer raw = false;
    return mods.of(i);
}

/// sys_liquid: its particles to liquid.zig, moved, back (older).
fn sysLiquid(s: *Sys) void {
    if (s.n == 0) return;
    if (!liquid.room(s.n)) return;
    lqCopy(s, false);
    const r = nth(s.uid, s.k) orelse return;
    liquid.solve(s.n, r, dt, s.acc, s.gadj, s.gbit);
    spray(s);
    lqCopy(s, true);
}

/// lq_spray: where the surface breaks: fast particles with few neighbours,
/// as events (in its hits' place).
fn spray(s: *Sys) void {
    s.nh = 0;
    s.nd = 0;
    if (s.listen & 1 == 0) return;
    if (s.evh == null) s.evh = evReserve();
    const evh = s.evh orelse return;
    const r = nth(s.uid, s.k) orelse return;
    const v2 = r.sprayv * r.sprayv;
    var nh: u32 = 0;
    for (0..s.n) |i| {
        if (liquid.nn[i] >= r.sprayn) continue;
        const v = liquid.v[i];
        if (!(dot3(v, v) > v2)) continue;
        const e = &evh[nh];
        e.p = liquid.x[i];
        e.p[3] = @bitCast(@as(u32, 3));
        e.v = v;
        e.v[3] = @bitCast(@as(u32, @intCast(i)));
        e.n = unit(liquid.v[i]);
        nh += 1;
    }
    s.nh = nh;
}

/// lq_copy: into liquid.x / v, or back (and a step older).
fn lqCopy(s: *Sys, back: bool) void {
    var q: usize = 0;
    for (sblk[s.si][0..s.nb]) |bk| {
        const c = bn[bk];
        const x = arr(bk, A_X);
        const y = arr(bk, A_Y);
        const z = arr(bk, A_Z);
        const vx = arr(bk, A_VX);
        const vy = arr(bk, A_VY);
        const vz = arr(bk, A_VZ);
        const age = arr(bk, A_AGE);
        for (0..c) |j| {
            if (!back) {
                liquid.x[q] = .{ x[j], y[j], z[j], 0 };
                liquid.v[q] = .{ vx[j], vy[j], vz[j], 0 };
            } else {
                x[j] = liquid.x[q][0];
                y[j] = liquid.x[q][1];
                z[j] = liquid.x[q][2];
                vx[j] = liquid.v[q][0];
                vy[j] = liquid.v[q][1];
                vz[j] = liquid.v[q][2];
                age[j] = age[j] + dt;
            }
            q += 1;
        }
    }
}

/// sys_tidy: its empty blocks back to the pool, its count.
fn tidy(s: *Sys) void {
    const bl = &sblk[s.si];
    var kept: u32 = 0;
    var alive: u32 = 0;
    for (0..s.nb) |k| {
        const b = bl[k];
        if (bn[b] != 0) {
            alive += bn[b];
            bl[kept] = b;
            kept += 1;
        } else blkPut(b);
    }
    s.nb = kept;
    s.n = alive;
}

// ---- being born -----------------------------------------------------------------------------

/// prand: a hash of the id, which number, the system's seed: [0, 1).
pub inline fn prand(id: u32, wh: u32, seed: u32) f32 {
    var a = id *% 0x9E3779B1 +% wh *% 0x85EBCA77 +% seed;
    a ^= a >> 16;
    a *%= 0x7feb352d;
    a ^= a >> 15;
    a *%= 0x846CA68B;
    a ^= a >> 16;
    a >>= 8;
    return @as(f32, @floatFromInt(a)) * 5.9604645e-8;
}

/// sys_emit: the particles born during this step: how many, their places
/// in its blocks, then made in parallel (events: another's, or its own hits
/// when it splits).
fn emit(s: *Sys, events: bool) void {
    if (!events) s.en = 0;
    const r = s.rec orelse return;
    s.emode = 0;
    var nborn: u32 = 0;
    var first: u32 = 0;
    if (events) {
        first = s.enext +% 0x40000000;
        var per: u32 = 0;
        var nev: u32 = 0;
        var eva: ?[*]Ev = null;
        var mode: u32 = 0;
        if (r.from == 4) {
            const o = s.evs orelse return;
            per = r.evper;
            switch (r.evkind) {
                1, 3 => {
                    nev = o.nh;
                    eva = o.evh;
                    mode = 1;
                },
                2 => {
                    nev = o.nd;
                    eva = o.evd;
                    mode = 4;
                },
                else => {
                    nev = o.en;
                    eva = null;
                    mode = 2;
                },
            }
        } else {
            if (r.coll & 1 == 0 or r.onhit != 3) return;
            per = r.splitn;
            nev = s.nh;
            eva = s.evh;
            mode = 3;
        }
        if (@as(i32, @bitCast(per)) < 1) per = 1;
        s.eva = eva;
        s.emode = mode;
        s.evp = per;
        nborn = nev *% per;
        if (nborn == 0) return;
        s.enext +%= nborn;
    } else {
        if (r.from == 4) return;
        if (r.from == 5 or r.mode != 0) {
            // all at once (at the start, or the scene's start if before it)
            if (s.next != 0) return;
            const t = if (s.ts > 0) s.ts else 0.0;
            if (t >= s.t1) return;
            nborn = r.num;
            if (s.src == 5) nborn = fillBuild(s);
            if (nborn == 0) return;
            s.next = nborn;
            first = 0;
        } else {
            // at a rate: ids born before the end (or the emitting's end)
            if (!(s.rate > 0)) return;
            const st: f64 = @floatFromInt(animStart());
            var e = (@as(f64, r.end) - st) * dtd;
            e = if (e < s.t1) e else s.t1;
            e -= s.ts;
            if (!(e > 0)) return;
            var lim: u64 = cvttsd(@ceil(e * s.rate));
            if (lim > 0x7fffffff) lim = 0x7fffffff;
            var lo: u64 = 0;
            const neg = 0.0 - s.ts;
            if (neg > 0) lo = cvttsd(@ceil(neg * s.rate));
            first = s.next;
            if (first < @as(u32, @truncate(lo))) first = @truncate(lo);
            s.next = @truncate(lim);
            const nb: i32 = @as(i32, @bitCast(@as(u32, @truncate(lim)))) -% @as(i32, @bitCast(first));
            if (nb <= 0) return;
            nborn = @bitCast(nb);
        }
    }
    // at most so many at once
    if (r.max != 0) {
        const room: i32 = @as(i32, @bitCast(r.max)) -% @as(i32, @bitCast(s.n));
        if (room <= 0) return;
        if (nborn > @as(u32, @bitCast(room))) nborn = @bitCast(room);
    }
    s.eid = first;
    if (s.src == 0) sysCdf(s);
    // their places: the last block's room, then new blocks
    const bl = &sblk[s.si];
    s.enb = s.nb;
    s.elb = -1;
    var room: u32 = 0;
    var c0: u32 = 0;
    if (s.nb != 0) {
        const lb = bl[s.nb - 1];
        s.elb = @intCast(lb);
        c0 = bn[lb];
        room = BLK - c0;
    }
    s.ec = c0;
    s.er = room;
    const into = @min(nborn, room);
    if (into != 0) bn[@intCast(s.elb)] += into;
    var left = nborn - into;
    var placed = into;
    while (left != 0) {
        const nbk = blkGet() orelse break; // the pool is full: fewer
        bl[s.nb] = nbk;
        s.nb += 1;
        bsys[nbk] = s.si;
        const k = @min(left, BLK);
        bn[nbk] = k;
        placed += k;
        left -= k;
    }
    s.en = placed;
    s.n += placed;
    if (placed == 0) return;
    jobs.parallelFor(placed, 2048, s, emitJob);
}

/// cvttsd2si (64-bit): out of range or NaN gives 0x8000000000000000.
fn cvttsd(x: f64) u64 {
    if (!(x > -9.223372036854775808e18 and x < 9.223372036854775808e18)) return 0x8000000000000000;
    return @bitCast(@as(i64, @intFromFloat(x)));
}

inline fn ld3(v: [3]f32) V4 {
    return .{ v[0], v[1], v[2], 0 };
}

/// sys_cdf: its faces' areas summed (in the world), made again when its mesh
/// or place changed.
fn sysCdf(s: *Sys) void {
    const me = s.mesh.?;
    var kh = (@as(u64, @intFromPtr(me)) ^ me.serial ^ (@as(u64, me.shape) << 32)) *% 0x9E3779B97F4A7C15;
    kh = sc.mix(kh, std.mem.asBytes(&s.mat));
    if (s.cdf.len > 0 and kh == s.cdfk) return;
    s.cdfk = kh;
    const nt = me.tris.len;
    if (nt > s.cdf.len) {
        if (s.cdf.len > 0) A.free(s.cdf);
        s.cdf = &.{};
        s.cdf = A.alloc(f32, nt) catch {
            s.src = 3;
            return;
        };
    }
    s.cdfn = @intCast(nt);
    var sum: f32 = 0;
    for (me.tris, 0..) |t, k| {
        const a = ld3(me.verts[t[0]]);
        const e1 = mVec(&s.mat, ld3(me.verts[t[1]]) - a);
        const e2 = mVec(&s.mat, ld3(me.verts[t[2]]) - a);
        const cr = cross(e1, e2);
        sum += @sqrt(dot3(cr, cr)) * 0.5;
        s.cdf[k] = sum;
    }
    s.tot = sum;
    if (!(sum > 0)) s.src = 3; // nothing to emit from: its origin
}

/// inside: the point (its object's space) is inside the mesh (crossings of a
/// ray along +X, odd).
fn inside(me: *const scene.Mesh, p: V4) bool {
    const px = p[0];
    const py = p[1];
    const pz = p[2];
    var n: u32 = 0;
    var t = me.tris.len;
    while (t > 0) {
        t -= 1;
        const tr = me.tris[me.tris.len - 1 - t];
        const a = me.verts[tr[0]];
        const b = me.verts[tr[1]];
        const c = me.verts[tr[2]];
        const d1 = (b[1] - a[1]) * (pz - a[2]) - (b[2] - a[2]) * (py - a[1]);
        const d2 = (c[1] - b[1]) * (pz - b[2]) - (c[2] - b[2]) * (py - b[1]);
        const d3 = (a[1] - c[1]) * (pz - c[2]) - (a[2] - c[2]) * (py - c[1]);
        const above = @as(u32, @intFromBool(d1 > 0)) + @intFromBool(d2 > 0) + @intFromBool(d3 > 0);
        if (above != 3) {
            if (above != 0) continue;
            // all not above: all below? (or unordered)
            const below = @as(u32, @intFromBool(!(d1 >= 0))) + @intFromBool(!(d2 >= 0)) + @intFromBool(!(d3 >= 0));
            if (below != 3) continue;
        }
        const w = (d1 + d2) + d3;
        var x = d2 * a[0] + d3 * b[0];
        x += d1 * c[0];
        x /= w;
        if (x > px) n += 1;
    }
    return n & 1 != 0;
}

/// fill_build: the points of a lattice (its spacing: the size, in the world)
/// inside its object's mesh.
fn fillBuild(s: *Sys) u32 {
    const me = s.mesh orelse return 0;
    const i = scene.findUid(s.uid) orelse return 0;
    const o = &scene.objects[i];
    const r = s.rec.?;
    var sv: V4 = rc.abs3(.{ o.scl[0], o.scl[1], o.scl[2], 0 });
    sv = maxps(sv, splat(1e-20));
    const size = maxss(r.size, 0.001);
    const fd = andXyz(splat(size) / sv);
    s.fd = fd;
    var lo = ld3(me.lo);
    var ext = ld3(me.hi) - lo;
    const nf = @floor(ext / fd);
    var ni: [4]i32 = undefined;
    const nfa: [4]f32 = nf;
    for (0..4) |k| ni[k] = cvtn(nfa[k]);
    ext = ext - nf * fd;
    ext = ext * splat(0.5);
    lo = lo + ext;
    lo = lo + fd * splat(0.5);
    s.fo = andXyz(lo);
    if (ni[0] <= 0 or ni[1] <= 0 or ni[2] <= 0) return 0;
    s.fnx = @intCast(ni[0]);
    s.fny = @intCast(ni[1]);
    const total: u64 = @as(u64, @intCast(ni[0])) * @as(u64, @intCast(ni[1])) * @as(u64, @intCast(ni[2]));
    if (total > 4194304) return 0;
    if (total > s.fillp.len) {
        if (s.fillp.len > 0) A.free(s.fillp);
        s.fillp = &.{};
        s.fillp = A.alloc(u32, @intCast(total)) catch return 0;
    }
    var k: u32 = 0;
    for (0..@as(usize, @intCast(total))) |idx| {
        const q: u32 = @intCast(idx);
        const x = q % s.fnx;
        const t = q / s.fnx;
        const y = t % s.fny;
        const z = t / s.fny;
        const pf: V4 = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z), 0 };
        const p = pf * s.fd + s.fo;
        if (inside(me, p)) {
            s.fillp[k] = q;
            k += 1;
        }
    }
    return k;
}

const ey: V4 = .{ 0, 1, 0, 0 };
const ex: V4 = .{ 1, 0, 0, 0 };

/// centre: the middle of its bounds.
fn centre(me: *const scene.Mesh) V4 {
    return (ld3(me.lo) + ld3(me.hi)) * splat(0.5);
}

/// place: where a new particle starts, from its source: the point, the normal.
fn place(s: *const Sys, id: u32) [2]V4 {
    const m = &s.mat;
    switch (s.src) {
        1 => {
            // inside: tried at random in its box
            const me = s.mesh.?;
            var p: V4 = undefined;
            var tries: u32 = 0;
            while (true) {
                const rv: V4 = .{ prand(id, tries * 3 + 16, s.seed), prand(id, tries * 3 + 17, s.seed), prand(id, tries * 3 + 18, s.seed), 0 };
                const lo = ld3(me.lo);
                p = lo + (ld3(me.hi) - lo) * rv;
                if (inside(me, p)) break;
                tries += 1;
                if (tries >= 32) break;
            }
            return .{ mPt(m, p), unit(mVec(m, p - centre(me))) };
        },
        2 => {
            // a vertex, outwards (HOOK(geonodes): a point cloud's point normals)
            const me = s.mesh.?;
            const nv: u32 = @intCast(me.verts.len);
            var k: u32 = @bitCast(cvtt(prand(id, 0, s.seed) * @as(f32, @floatFromInt(nv))));
            if (k > nv - 1) k = nv - 1;
            const v = ld3(me.verts[k]);
            return .{ mPt(m, v), unit(mVec(m, v - centre(me))) };
        },
        3 => {
            // its origin, its +Y
            return .{ .{ m[0][3], m[1][3], m[2][3], 0 }, unit(mVec(m, ey)) };
        },
        5 => {
            // a fill: its lattice point (a hair off)
            const q = s.fillp[id];
            const x = q % s.fnx;
            const t = q / s.fnx;
            var pf: [4]f32 = .{ @floatFromInt(x), @floatFromInt(t % s.fny), @floatFromInt(t / s.fny), 0 };
            for (0..3) |c| pf[c] += (prand(id, @intCast(c + 12), s.seed) - 0.5) * 0.02;
            return .{ mPt(m, @as(V4, pf) * s.fd + s.fo), ey };
        },
        else => {
            // faces: one by its area
            const me = s.mesh.?;
            const x = prand(id, 0, s.seed) * s.tot;
            var lo: u32 = 0;
            var hi: u32 = s.cdfn;
            while (lo < hi) {
                const mid = (lo + hi) >> 1;
                if (!(x >= s.cdf[mid])) hi = mid else lo = mid + 1;
            }
            if (lo > s.cdfn - 1) lo = s.cdfn - 1;
            const tr = me.tris[lo];
            const a = ld3(me.verts[tr[0]]);
            const e1 = ld3(me.verts[tr[1]]) - a;
            const e2 = ld3(me.verts[tr[2]]) - a;
            const sq = @sqrt(prand(id, 1, s.seed));
            const b2 = sq * prand(id, 2, s.seed);
            const b1 = sq - b2;
            const p = mPt(m, a + (splat(b1) * e1 + splat(b2) * e2));
            const n = unit(cross(mVec(m, e1), mVec(m, e2)));
            return .{ p, n };
        },
    }
}

/// ev_place: where one born of an event starts: the event's place (a little
/// off the surface for a hit): the point, the normal, the event's velocity.
fn evPlace(s: *const Sys, idx: u32) [3]V4 {
    const e = idx / s.evp;
    if (s.emode == 2) {
        // the other's newborn: where it is
        const o = s.evs.?;
        var bk: u32 = undefined;
        var slot: u32 = undefined;
        if (e < o.er) {
            bk = @bitCast(o.elb);
            slot = e + o.ec;
        } else {
            const q = e - o.er;
            bk = sblk[o.si][(q >> BLKSH) + o.enb];
            slot = q & (BLK - 1);
        }
        const p: V4 = .{ arr(bk, A_X)[slot], arr(bk, A_Y)[slot], arr(bk, A_Z)[slot], 0 };
        const v: V4 = .{ arr(bk, A_VX)[slot], arr(bk, A_VY)[slot], arr(bk, A_VZ)[slot], 0 };
        const d = if (dot3(v, v) > 1.0e-12) v else ey;
        return .{ p, unit(d), v };
    }
    const ev = &s.eva.?[e];
    var n = ev.n;
    const p = andXyz(ev.p) + splat(0.002) * n;
    if (!(dot3(n, n) > 1.0e-12)) n = ey;
    return .{ p, n, andXyz(ev.v) };
}

const deg: f32 = 0.017453293;
const two_pi: f32 = 6.28318531;

fn sincos(x: f32) [2]f32 {
    return @import("animexpr.zig").sincos32(x);
}

/// emit_job: newborn begin..end: where, how fast, how long, moved on from
/// their birth.
fn emitJob(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const s: *Sys = @ptrCast(@alignCast(ctx));
    const r = s.rec.?;
    for (lo..hi) |ii| {
        const idx: u32 = @intCast(ii);
        var bk: u32 = undefined;
        var slot: u32 = undefined;
        if (idx < s.er) {
            bk = @bitCast(s.elb);
            slot = idx + s.ec;
        } else {
            const q = idx - s.er;
            bk = sblk[s.si][(q >> BLKSH) + s.enb];
            slot = q & (BLK - 1);
        }
        const id = s.eid +% idx;
        var p: V4 = undefined;
        var n: V4 = undefined;
        var evv: V4 = @splat(0);
        if (s.emode == 0) {
            const pl = place(s, id);
            p = pl[0];
            n = pl[1];
        } else {
            const pl = evPlace(s, idx);
            p = pl[0];
            n = pl[1];
            evv = pl[2];
        }
        // the way: its normal, or the direction
        var dir = n;
        var along = false;
        if (s.emode == 3) {
            along = true;
        } else if (r.vmode != 0) {
            dir = mVec(&s.mat, ld3(r.dir));
        } else if (s.emode == 2 or s.emode == 4) along = true;
        if (along and dot3(evv, evv) > 1.0e-12) dir = evv;
        dir = unit(dir);
        if (r.spread > 0) {
            // in a cone round it
            var helper = ex;
            if (@abs(dir[0]) > 0.9) helper = ey;
            const u = unit(cross(dir, helper));
            const w = cross(dir, u);
            const r3 = prand(id, 3, s.seed);
            const sc1 = sincos(r.spread * deg);
            const cost = 1.0 - (1.0 - sc1[1]) * r3;
            const sint = @sqrt(maxss(1.0 - cost * cost, 0));
            const sc2 = sincos(prand(id, 4, s.seed) * two_pi);
            var d = splat(sc2[0] * sint) * w;
            d += splat(sc2[1] * sint) * u;
            d += splat(cost) * dir;
            dir = d;
        }
        // its speed
        const r5 = prand(id, 5, s.seed);
        var k = (r5 + r5 - 1.0) * r.speedr + 1.0;
        if (s.emode == 3) {
            k *= @sqrt(dot3(evv, evv));
        } else k *= r.speed;
        var v = andXyz(splat(k) * dir);
        if (s.emode != 0 and s.emode != 3) v = andXyz(v + splat(r.inherit) * evv);
        // born when: moved on since (of an event: at the step's end)
        var tb: f64 = 0;
        var te: f64 = 0;
        if (s.emode == 0) {
            te = s.t1;
            if (r.mode == 0) {
                tb = @as(f64, @floatFromInt(@as(i32, @bitCast(id)))) / s.rate + s.ts;
            } else tb = if (s.ts > 0) s.ts else 0.0;
        }
        var tau64 = te - tb;
        if (!(tau64 > 0)) tau64 = 0;
        const tau: f32 = @floatCast(tau64);
        arr(bk, A_AGE)[slot] = tau;
        var a = s.acc;
        if (nfields != 0) a = accel(p, v, s.gbit) + s.gadj;
        // x = p + v tau + a tau^2 / 2
        const tv = splat(tau);
        const at = a * tv;
        const h = at * tv * splat(0.5);
        const x = (v * tv + h) + p;
        const v1 = v + at;
        arr(bk, A_X)[slot] = x[0];
        arr(bk, A_Y)[slot] = x[1];
        arr(bk, A_Z)[slot] = x[2];
        arr(bk, A_VX)[slot] = v1[0];
        arr(bk, A_VY)[slot] = v1[1];
        arr(bk, A_VZ)[slot] = v1[2];
        // how long, how big
        arr(bk, A_LIFE)[slot] = (1.0 - prand(id, 6, s.seed) * r.lifer) * r.life;
        const r7 = prand(id, 7, s.seed);
        arr(bk, A_SIZE)[slot] = ((r7 + r7 - 1.0) * r.sizer + 1.0) * r.size;
        arrU(bk, A_COL)[slot] = r.color;
        arrU(bk, A_ID)[slot] = id;
        arrU(bk, A_FLAG)[slot] = 0;
    }
}

/// fl_accel (no wind left out), as a 4-lane value (w 0).
fn accel(p: V4, v: V4, gbit: u32) V4 {
    const a = fields.accel(.{ p[0], p[1], p[2] }, .{ v[0], v[1], v[2] }, gbit, false);
    return .{ a[0], a[1], a[2], 0 };
}

// ---- moving -------------------------------------------------------------------------------------

const EV_STAGE = 2 * BLK; // events a listed block

/// step_job: listed blocks begin..end: each particle moved by the pull
/// (gravity, or the fields' at it), slowed by its drag, aged; when its system
/// collides, its path cast against the colliders (bounce, die, stick, split;
/// the hits kept as events); the dead dropped (the rest kept in order, their
/// deaths kept as events).
fn stepJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |li| {
        const bk = blist[li];
        ev_bh[li] = 0;
        ev_bd[li] = 0;
        const s = &sr[bsys[bk]];
        const cnt = bn[bk];
        const x = arr(bk, A_X);
        const y = arr(bk, A_Y);
        const z = arr(bk, A_Z);
        const vx = arr(bk, A_VX);
        const vy = arr(bk, A_VY);
        const vz = arr(bk, A_VZ);
        const age = arr(bk, A_AGE);
        const life = arr(bk, A_LIFE);
        const flag = arrU(bk, A_FLAG);
        // the lanes past the end: never dead
        const c4 = (cnt + 3) & ~@as(u32, 3);
        var k = cnt;
        while (k < c4) : (k += 1) {
            x[k] = 0;
            y[k] = 0;
            z[k] = 0;
            vx[k] = 0;
            vy[k] = 0;
            vz[k] = 0;
            age[k] = 0;
            flag[k] = 0;
            life[k] = 1.0e9;
        }
        const damp = s.damp;
        var dead = false;
        if (nfields == 0 and s.collon == 0) {
            // four at a time (lane by lane, the same numbers)
            const h = dt * dt * 0.5;
            const ah = s.acc * splat(h);
            const ad = s.acc * splat(dt);
            for (0..c4) |j| {
                x[j] = (x[j] + vx[j] * dt) + ah[0];
                vx[j] = (vx[j] + ad[0]) * damp;
                y[j] = (y[j] + vy[j] * dt) + ah[1];
                vy[j] = (vy[j] + ad[1]) * damp;
                z[j] = (z[j] + vz[j] * dt) + ah[2];
                vz[j] = (vz[j] + ad[2]) * damp;
                age[j] = age[j] + dt;
                if (!(age[j] < life[j])) dead = true;
            }
        } else {
            for (0..cnt) |j| {
                age[j] = age[j] + dt;
                if (flag[j] & 1 == 0) {
                    const p: V4 = .{ x[j], y[j], z[j], 0 };
                    var v: V4 = .{ vx[j], vy[j], vz[j], 0 };
                    var a = s.acc;
                    if (nfields != 0) a = accel(p, v, s.gbit) + s.gadj;
                    const dv = splat(dt);
                    const adt = a * dv;
                    var p1 = adt * dv * splat(0.5);
                    p1 += v * dv;
                    p1 += p;
                    v = andXyz((v + adt) * splat(damp));
                    p1 = andXyz(p1);
                    if (s.collon != 0) {
                        if (cast(p, p1)) |hit| {
                            // back off the surface a little
                            p1 = hit.n * V4{ 0.001, 0.001, 0.001, 0 } + hit.p;
                            const vn = dot3(v, hit.n);
                            if (vn < 0) {
                                // bounce, rub
                                var np = splat(vn) * hit.n;
                                var tv = v - np;
                                tv *= splat(1.0 - s.fric);
                                np *= splat(s.bounce);
                                // too slow to leave: it rests there
                                if (!(dot3(np, np) >= s.rest)) np = @splat(0);
                                v = andXyz(tv - np);
                            }
                            if (s.onhit == 2) {
                                flag[j] |= 1; // sticks
                                v = @splat(0);
                            } else if (s.onhit != 0) {
                                age[j] = life[j]; // dies (or splits)
                                dead = true;
                            }
                            // the hit: counted, kept as an event
                            const ci = ev_bh[li];
                            ev_bh[li] += 1;
                            if (s.listen & 1 != 0) {
                                const e = &stage.?[li * EV_STAGE + ci];
                                e.p = hit.p;
                                e.p[3] = @bitCast(@as(u32, 1));
                                e.v = v;
                                e.v[3] = @bitCast(arrU(bk, A_ID)[j]);
                                e.n = hit.n;
                            }
                        }
                    }
                    x[j] = p1[0];
                    y[j] = p1[1];
                    z[j] = p1[2];
                    vx[j] = v[0];
                    vy[j] = v[1];
                    vz[j] = v[2];
                }
                if (age[j] >= life[j]) dead = true;
            }
        }
        if (!dead) continue;
        // the dead out, the rest in order
        var kept: u32 = 0;
        for (0..cnt) |j| {
            if (age[j] >= life[j]) {
                if (s.listen & 2 != 0) {
                    const ci = ev_bd[li];
                    ev_bd[li] += 1;
                    const e = &stage.?[li * EV_STAGE + BLK + ci];
                    e.p = .{ x[j], y[j], z[j], @bitCast(@as(u32, 2)) };
                    e.v = .{ vx[j], vy[j], vz[j], @bitCast(arrU(bk, A_ID)[j]) };
                    e.n = @splat(0);
                }
                continue;
            }
            if (j != kept) {
                for (0..NARR) |a| arrU(bk, a)[kept] = arrU(bk, a)[j];
            }
            kept += 1;
        }
        bn[bk] = kept;
    }
}

/// pt_listen: which systems keep their events this step, and whose events
/// each one born of events uses (by its name).
fn listen() void {
    for (sr[0..ns]) |*s| {
        s.listen = 0;
        s.evs = null;
    }
    for (sr[0..ns]) |*s| {
        const r = s.rec orelse continue;
        if (s.collon != 0 and r.onhit == 3) s.listen |= 1;
        if (r.from != 4) continue;
        for (sr[0..ns]) |*o| {
            const q = nth(o.uid, o.k) orelse continue;
            if (!std.mem.eql(u8, cstr(&q.name), cstr(&r.evname))) continue;
            s.evs = o;
            switch (r.evkind) {
                1, 3 => o.listen |= 1,
                2 => o.listen |= 2,
                else => {},
            }
            break;
        }
    }
}

pub fn cstr(b: []const u8) []const u8 {
    return b[0 .. std.mem.indexOfScalar(u8, b, 0) orelse b.len];
}

/// sys_gather: its blocks' hits and deaths this step, in order.
fn gather(s: *Sys) void {
    if (s.liqon != 0) return; // (a liquid: its spray is kept)
    s.nh = 0;
    s.nd = 0;
    var hsum: u32 = 0;
    for (s.l0..s.l0 + s.ln) |li| hsum +%= ev_bh[li];
    s.hits +%= hsum;
    const st = stage orelse return;
    for (0..2) |kind| {
        if (s.listen & (@as(u32, 1) << @intCast(kind)) == 0) continue;
        const room = if (kind == 0) &s.evh else &s.evd;
        if (room.* == null) room.* = evReserve();
        const dst = room.* orelse continue;
        var n: u32 = 0;
        for (s.l0..s.l0 + s.ln) |li| {
            const c = if (kind == 0) ev_bh[li] else ev_bd[li];
            @memcpy(dst[n..][0..c], st[li * EV_STAGE + kind * BLK ..][0..c]);
            n += c;
        }
        if (kind == 0) s.nh = n else s.nd = n;
    }
}

// ---- the colliders --------------------------------------------------------------------------

/// A collider triangle (CT_*): a, e1, e2, n.
const Tri = struct { a: V4 align(16), e1: V4, e2: V4, n: V4 };
/// A tree node (CN_*): min (w: left / first), max (w: right / count; bit 31 leaf).
const Node = struct { min: V4 align(16), max: V4 };

pub var pc_any: bool = false;
pub var pc_gnd: bool = false;
pub var pc_gy: f32 = 0;
var pc_tri: []Tri = &.{};
var pc_ix: []u32 = &.{};
var pc_cen: []V4 = &.{};
var pc_node: []Node = &.{};
var pc_key: u64 = 0;
pub var pc_ntri: u32 = 0;
var pc_nn: u32 = 0;
var pc_objs: [256]usize = undefined;
var pc_no: u32 = 0;
/// The landscapes (PC_MAXL at most), collided with by their heights: each
/// one's block, location and scale (la_wheight's, read once a step).
const Land = struct { b: *landscape.Block, loc: [3]f32, scl: [3]f32 };
var pc_land: [8]Land = undefined;
pub var pc_nl: u32 = 0;

fn pcAdd(i: usize) void {
    if (pc_no >= 256) return;
    for (pc_objs[0..pc_no]) |x| {
        if (x == i) return;
    }
    pc_objs[pc_no] = i;
    pc_no += 1;
}

/// pc_usable: its triangles can be hit: a visible mesh, not the Ground, not
/// water, not a landscape.
fn pcUsable(i: usize) bool {
    const o = &scene.objects[i];
    if (!o.kind.isMesh() or o.mesh == null) return false;
    if (!o.visible or o.isGround() or o.gflags & landscape.OBF_WATER != 0) return false;
    return landscape.of(o) == null;
}

/// pt_colliders: what particles hit this step (made again when it changed).
fn colliders() void {
    pc_no = 0;
    pc_nl = 0;
    pc_gnd = false;
    if (anim.cur) |b| {
        // rigid bodies, cloth colliders
        var k: usize = 0;
        while (k < b.h.nrb and (k + 1) * rc.RB_SZ <= b.rb.len) : (k += 1) {
            const oid = rc.rdU(b.rb, k * rc.RB_SZ + rc.RB_UID);
            const i = scene.findOid(oid) orelse continue;
            if (pcUsable(i)) pcAdd(i);
        }
        const cl = @import("cloth.zig");
        const ncl = @min(rc.rdU(&b.rest, cl.REST_CW + cl.CW_N), cl.CL_MAX);
        for (0..ncl) |q| {
            const e = b.rest[cl.REST_CL + q * cl.CL_SZ ..][0..cl.CL_SZ];
            if (rc.rdU(e, cl.CL_TYPE) != 3) continue;
            const i = scene.findOid(rc.rdU(e, 0)) orelse continue;
            if (pcUsable(i)) pcAdd(i);
        }
    }
    // landscapes, the ground
    for (scene.objects[0..scene.count]) |*o| {
        if (!o.kind.isMesh() or !o.visible) continue;
        if (o.isGround()) {
            pc_gnd = true;
            pc_gy = o.loc[1];
            continue;
        }
        const lb = landscape.of(o) orelse continue;
        if (pc_nl >= pc_land.len) continue;
        pc_land[pc_nl] = .{ .b = lb, .loc = o.loc, .scl = o.scl };
        pc_nl += 1;
    }
    // what the triangles were made from
    var kh: u64 = 0x2545F4914F6CDD1D;
    var nt: u32 = 0;
    for (pc_objs[0..pc_no]) |i| {
        const o = &scene.objects[i];
        const rad = o.radians();
        const p = [9]f32{ o.loc[0], o.loc[1], o.loc[2], rad[0], rad[1], rad[2], o.scl[0], o.scl[1], o.scl[2] };
        kh = sc.mix(kh, std.mem.asBytes(&p));
        const me = mods.of(i) orelse continue;
        kh ^= @intFromPtr(me);
        kh ^= me.serial ^ (@as(u64, me.shape) << 32);
        kh *%= 0x9E3779B97F4A7C15;
        nt += @intCast(me.tris.len);
    }
    kh ^= pc_no;
    pc_any = false;
    if (!pc_gnd and pc_nl == 0 and nt == 0) return;
    pc_any = true;
    if (nt != 0 and kh == pc_key) return;
    pc_key = kh;
    pc_ntri = nt;
    pc_nn = 0;
    if (nt == 0) return;
    if (nt * 2 > pc_tri.len) {
        pcFree();
        const cap = @as(usize, nt) * 2;
        pc_tri = A.alloc(Tri, cap) catch return pcFail();
        pc_ix = A.alloc(u32, cap) catch return pcFail();
        pc_cen = A.alloc(V4, cap) catch return pcFail();
        pc_node = A.alloc(Node, cap * 2) catch return pcFail();
    }
    // the triangles in the world
    var t: u32 = 0;
    for (pc_objs[0..pc_no]) |i| {
        const m = matRows(i);
        const me = mods.of(i) orelse continue;
        for (me.tris) |tr| {
            const a = mPt(&m, ld3(me.verts[tr[0]]));
            const b1 = mPt(&m, ld3(me.verts[tr[1]]));
            const c1 = mPt(&m, ld3(me.verts[tr[2]]));
            const cen = (a + b1 + c1) * V4{ 0.33333334, 0.33333334, 0.33333334, 0 };
            const e1 = b1 - a;
            const e2 = c1 - a;
            pc_tri[t] = .{ .a = a, .e1 = e1, .e2 = e2, .n = unit(cross(e1, e2)) };
            pc_cen[t] = cen;
            pc_ix[t] = t;
            t += 1;
        }
    }
    _ = pcBuild(0, t);
}

fn pcFree() void {
    if (pc_tri.len > 0) A.free(pc_tri);
    if (pc_ix.len > 0) A.free(pc_ix);
    if (pc_cen.len > 0) A.free(pc_cen);
    if (pc_node.len > 0) A.free(pc_node);
    pc_tri = &.{};
    pc_ix = &.{};
    pc_cen = &.{};
    pc_node = &.{};
}
fn pcFail() void {
    pcFree();
    pc_ntri = 0;
    pc_key = 0;
}

/// pc_build: a node over pc_ix[first..end] (made with its children).
fn pcBuild(first: u32, end: u32) u32 {
    const me = pc_nn;
    pc_nn += 1;
    var bmin: V4 = @splat(1e30);
    var bmax: V4 = @splat(-1e30);
    var cmin = bmin;
    var cmax = bmax;
    for (pc_ix[first..end]) |ti| {
        const tr = &pc_tri[ti];
        const a = tr.a;
        bmin = minps(bmin, a);
        bmax = maxps(bmax, a);
        const b = a + tr.e1;
        bmin = minps(bmin, b);
        bmax = maxps(bmax, b);
        const c = a + tr.e2;
        bmin = minps(bmin, c);
        bmax = maxps(bmax, c);
        cmin = minps(cmin, pc_cen[ti]);
        cmax = maxps(cmax, pc_cen[ti]);
    }
    bmin = andXyz(bmin);
    bmax = andXyz(bmax);
    pc_node[me] = .{ .min = bmin, .max = bmax };
    const n = end - first;
    if (n <= 4) {
        pc_node[me].min[3] = @bitCast(first);
        pc_node[me].max[3] = @bitCast(n | 0x80000000);
        return me;
    }
    // split the longest side at its middle
    const ext = cmax - cmin;
    var axis: usize = 0;
    var l = ext[0];
    if (ext[1] > l) {
        axis = 1;
        l = ext[1];
    }
    if (ext[2] > l) {
        axis = 2;
        l = ext[2];
    }
    const half = l * 0.5 + 1.0e-12;
    const cma: [4]f32 = cmin;
    const mid = cma[axis] + half;
    var i = first;
    var j = end;
    while (i < j) {
        const ti = pc_ix[i];
        const ce: [4]f32 = pc_cen[ti];
        if (ce[axis] >= mid) {
            j -= 1;
            pc_ix[i] = pc_ix[j];
            pc_ix[j] = ti;
        } else i += 1;
    }
    if (i == first or i == end) i = (first + end) >> 1;
    const left = pcBuild(first, i);
    pc_node[me].min[3] = @bitCast(left);
    const right = pcBuild(i, end);
    pc_node[me].max[3] = @bitCast(right);
    return me;
}

pub const Hit = struct { p: V4, n: V4 };

/// pc_cast: the path p0 -> p1 against the ground, the landscapes, the
/// triangles: the first hit (its place, the surface's normal against the
/// motion), or null. Re-entrant.
pub fn cast(p0: V4, p1: V4) ?Hit {
    if (!pc_any) return null;
    const d = andXyz(p1 - p0);
    var t: f32 = 1.0;
    var hit = false;
    var n: V4 = undefined;
    var lhit = false; // a landscape's: its point on the surface
    var lp: V4 = undefined;
    if (pc_gnd) {
        // the ground: y crosses its height
        const f1 = p1[1] - pc_gy;
        if (!(f1 >= 0)) {
            const f0 = p0[1] - pc_gy;
            var tt: f32 = 0;
            if (f0 > 0) tt = f0 / (f0 - f1);
            t = tt;
            hit = true;
            n = ey;
        }
    }
    // landscapes: under their height
    for (pc_land[0..pc_nl]) |*li| {
        const h1 = lwh(li, p1[0], p1[2]) orelse continue;
        const f1 = p1[1] - h1; // under it when < 0
        if (f1 >= 0) continue;
        var tt: f32 = 0; // where f crosses 0
        if (lwh(li, p0[0], p0[2])) |h0| {
            const f0 = p0[1] - h0;
            if (f0 > 0) tt = f0 / (f0 - f1);
        }
        if (tt >= t) continue;
        t = tt;
        hit = true;
        // the point on the surface, its normal there (by differences)
        const x = d[0] * tt + p0[0];
        const z = d[2] * tt + p0[2];
        lp = .{ x, lh(li, x, z), z, 0 };
        lhit = true;
        const dx: f32 = 0.05;
        const hx = lh(li, x + dx, z) - lh(li, x - dx, z);
        const hz = lh(li, x, z + dx) - lh(li, x, z - dx);
        n = unit(.{ -hx, dx + dx, -hz, 0 });
    }
    if (pc_ntri != 0) {
        // 1/d (huge where d is 0)
        var dd: [4]f32 = d;
        for (0..4) |k| {
            if (@abs(dd[k]) < 1.0e-20) dd[k] = @bitCast(@as(u32, @bitCast(dd[k])) | @as(u32, @bitCast(@as(f32, 1.0e-20))));
        }
        const inv = splat(1.0) / @as(V4, dd);
        var stack: [64]u32 = undefined;
        stack[0] = 0;
        var sp: u32 = 1;
        while (sp > 0) {
            sp -= 1;
            const nd = &pc_node[stack[sp]];
            const ta = (nd.min - p0) * inv;
            const tb = (nd.max - p0) * inv;
            const near = minps(ta, tb);
            const far = maxps(tb, ta);
            var tn = maxss(near[0], near[1]);
            tn = maxss(tn, near[2]);
            var tf = minss(far[0], far[1]);
            tf = minss(tf, far[2]);
            tn = maxss(tn, 0);
            tf = minss(tf, t);
            if (tn > tf) continue;
            const w: u32 = @bitCast(nd.max[3]);
            if (w & 0x80000000 == 0) {
                if (sp >= 62) continue;
                stack[sp] = w;
                sp += 1;
                stack[sp] = @bitCast(nd.min[3]);
                sp += 1;
                continue;
            }
            const f0: u32 = @bitCast(nd.min[3]);
            for (f0..f0 + (w & 0x7fffffff)) |q| {
                const tr = &pc_tri[pc_ix[q]];
                // Moller-Trumbore
                const pv = cross(d, tr.e2);
                const det = dot3(tr.e1, pv);
                if (!(@abs(det) > 1.0e-9)) continue;
                const idet = 1.0 / det;
                const sv = andXyz(p0 - tr.a);
                const u = dot3(sv, pv) * idet;
                if (!(u >= 0) or u > 1.0) continue;
                const qv = cross(sv, tr.e1);
                const v = dot3(d, qv) * idet;
                if (!(v >= 0)) continue;
                if (v + u > 1.0) continue;
                const tt = dot3(tr.e2, qv) * idet;
                if (!(tt >= 0)) continue;
                if (!(tt < t)) continue;
                t = tt;
                hit = true;
                lhit = false;
                var nn = tr.n;
                if (dot3(nn, d) > 0) nn = andXyz(rc.neg4(nn));
                n = nn;
            }
        }
    }
    if (!hit) return null;
    if (lhit) return .{ .p = lp, .n = n };
    return .{ .p = andXyz(splat(t) * d + p0), .n = n };
}

/// la_wheight: the landscape's height at world (x, z), null when not over it.
inline fn lwh(l: *const Land, x: f32, z: f32) ?f32 {
    const h = landscape.height(l.b, (x - l.loc[0]) / l.scl[0], (z - l.loc[2]) / l.scl[2]) orelse return null;
    return h * l.scl[1] + l.loc[1];
}
/// The same, 0 where it is not over it (as la_wheight leaves xmm0).
fn lh(l: *const Land, x: f32, z: f32) f32 {
    return lwh(l, x, z) orelse 0;
}

// ---- asking -------------------------------------------------------------------------------------

/// pt_info (BeeScript particles(k, i)): 0 particles alive, 1 systems
/// running, 2 the last frame's time (ms), 3 the last step's, 4 blocks in
/// use, 5 steps done; particle i (in the systems' order): 6..8 its place,
/// 9..11 its velocity, 12 its age, 13 its lifetime, 14 its size, 15 its id,
/// 16 its colour; 17 the last viewport draw (ms), 18 the particles it drew;
/// 19 hits so far; 20 system i's particles born of events so far, 21 its
/// hits so far, 22 its particles; 23.. the liquid solver's; 32 system i's
/// surface: the last meshing (ms), 33 its triangles.
pub fn info(what: i32, i: i32) f32 {
    switch (what) {
        0 => {
            var n: u32 = 0;
            for (sr[0..ns]) |*s| n +%= s.n;
            return @floatFromInt(n);
        },
        1 => return @floatFromInt(ns),
        2 => return msf,
        3 => return mss,
        4 => return if (pool != null) @floatFromInt(NBLK - nfree) else 0,
        5 => return @floatFromInt(now),
        17 => return @import("partdraw.zig").ms,
        18 => return @floatFromInt(@import("partdraw.zig").drawn),
        19 => {
            var n: u32 = 0;
            for (sr[0..ns]) |*s| n +%= s.hits;
            return @floatFromInt(n);
        },
        20 => {
            if (i < 0 or i >= ns) return 0;
            return @floatFromInt(sr[@intCast(i)].enext);
        },
        32, 33 => {
            if (i < 0 or i >= ns) return 0;
            const s = &sr[@intCast(i)];
            if (what == 32) return s.surf.ms;
            const me = @import("partsurf.zig").mesh(s) orelse return 0;
            return @floatFromInt(me.tris.len);
        },
        23...31 => return liquid.info(what - 23),
        21, 22 => {
            if (i < 0 or i >= ns) return 0;
            const s = &sr[@intCast(i)];
            return @floatFromInt(if (what == 21) s.hits else s.n);
        },
        6...16 => {
            if (i < 0) return 0;
            var q: u32 = @bitCast(i);
            for (sr[0..ns], 0..) |*s, si| {
                for (sblk[si][0..s.nb]) |bk| {
                    if (q >= bn[bk]) {
                        q -= bn[bk];
                        continue;
                    }
                    const offs = [11]usize{ A_X, A_Y, A_Z, A_VX, A_VY, A_VZ, A_AGE, A_LIFE, A_SIZE, A_ID, A_COL };
                    const a = offs[@intCast(what - 6)];
                    if (what < 15) return arr(bk, a)[q];
                    return @floatFromInt(@as(i64, arrU(bk, a)[q]));
                }
            }
            return 0;
        },
        else => return 0,
    }
}

/// Something to bake: the systems (simcache's parts_count).
pub fn countAll() u32 {
    return if (cur) |b| b.n else 0;
}

/// What the viewport keys on: moves when the particles do.
pub fn stateWord() u64 {
    var h: u64 = @as(u64, now) << 32 | ns;
    h ^= hash;
    h = sc.mix(h, settingsBytes());
    for (sr[0..ns]) |*s| {
        const x = [2]u32{ s.n, s.nb };
        h = sc.mix(h, std.mem.asBytes(&x));
    }
    return h ^ (@as(u64, @intFromBool(played)) << 63);
}

// ---- the cache (channel 2 particles, 3 liquids) --------------------------------------------------

const CR_HDR = 40;
const CR_P = 20;

/// pt_kinds: bit 0 a system of particles, bit 1 a liquid.
fn kindsOf() u32 {
    const b = cur orelse return 0;
    var k: u32 = 0;
    for (b.r[0..b.n]) |*r| k |= if (r.liq & 1 != 0) 2 else 1;
    return k;
}

/// pt_cached: its record for this frame (baked: past its end, its last), or null.
fn cached(ch: u32, baked: bool) ?[]u8 {
    var f = tgt +% start;
    if (baked) {
        const l = sc.last(ch);
        if (f > l) f = l;
    }
    return sc.get(ch, f);
}

/// cr_size: a record's bytes (kind 1 particles, 2 liquids).
fn crSize(kind: u32) usize {
    var n: usize = 4;
    for (sr[0..ns]) |*s| {
        const k: u32 = if (s.liqon != 0) 2 else 1;
        if (k == kind) n += @as(usize, s.n) * CR_P + CR_HDR;
    }
    return n;
}

fn wrU(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}
fn wrF(b: []u8, o: usize, v: f32) void {
    wrU(b, o, @bitCast(v));
}
fn rdU(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
fn rdF(b: []const u8, o: usize) f32 {
    return @bitCast(rdU(b, o));
}

/// pt_record: the systems as they are, into channels 2 and 3 (when each
/// takes this frame next).
fn record(f: i32) void {
    for (1..3) |kind| {
        const size = crSize(@intCast(kind));
        if (size == 4) continue;
        const rec = sc.add(@intCast(kind + 1), f, size) orelse continue;
        wrU(rec, 0, 0);
        var o: usize = 4;
        for (sr[0..ns]) |*s| {
            const k: u32 = if (s.liqon != 0) 2 else 1;
            if (k != kind) continue;
            wrU(rec, 0, rdU(rec, 0) + 1);
            wrU(rec, o, s.si);
            wrU(rec, o + 4, s.n);
            const bd = bounds(s);
            for (0..6) |q| wrF(rec, o + 8 + q * 4, bd[q]);
            wrF(rec, o + 32, bd[6]);
            wrF(rec, o + 36, bd[7]);
            crWrite(s, rec[o..], rec[o + CR_HDR ..]);
            o += CR_HDR + @as(usize, s.n) * CR_P;
        }
    }
}

/// cr_bounds: min (3), max (3), the largest speed along an axis, the largest size.
fn bounds(s: *const Sys) [8]f32 {
    var lo: V4 = .{ 1e30, 1e30, 1e30, 0 };
    var hi: V4 = .{ -1e30, -1e30, -1e30, -0.0 };
    var vm: f32 = 0;
    var sm: f32 = 0;
    for (sblk[s.si][0..s.nb]) |bk| {
        for (0..bn[bk]) |j| {
            const p: V4 = .{ arr(bk, A_X)[j], arr(bk, A_Y)[j], arr(bk, A_Z)[j], 0 };
            lo = minps(lo, p);
            hi = maxps(hi, p);
            vm = maxss(vm, @abs(arr(bk, A_VX)[j]));
            vm = maxss(vm, @abs(arr(bk, A_VY)[j]));
            vm = maxss(vm, @abs(arr(bk, A_VZ)[j]));
            sm = maxss(sm, arr(bk, A_SIZE)[j]);
        }
    }
    vm = maxss(vm, 1.0e-12);
    sm = maxss(sm, 1.0e-12);
    return .{ lo[0], lo[1], lo[2], hi[0], hi[1], hi[2], vm, sm };
}

/// q16: (v - low) / range into 0..65535.
fn q16(v: f32, low: f32, range0: f32) u16 {
    const range = maxss(range0, 1.0e-12);
    var x = (v - low) / range;
    x = maxss(x, 0);
    x = minss(x, 1.0);
    return @truncate(@as(u32, @bitCast(cvtn(x * 65535.0))));
}

/// cr_write: its particles, 20 bytes each.
fn crWrite(s: *const Sys, h: []const u8, out: []u8) void {
    var rg: [3]f32 = undefined;
    for (0..3) |c| rg[c] = rdF(h, 20 + c * 4) - rdF(h, 8 + c * 4);
    var o: usize = 0;
    for (sblk[s.si][0..s.nb]) |bk| {
        for (0..bn[bk]) |j| {
            for (0..3) |c| std.mem.writeInt(u16, out[o + c * 2 ..][0..2], q16(arr(bk, A_X + c)[j], rdF(h, 8 + c * 4), rg[c]), .little);
            for (0..3) |c| {
                var x = arr(bk, A_VX + c)[j] / rdF(h, 32);
                x = maxss(x, -1.0);
                x = minss(x, 1.0);
                std.mem.writeInt(u16, out[o + 6 + c * 2 ..][0..2], @truncate(@as(u32, @bitCast(cvtn(x * 32767.0)))), .little);
            }
            std.mem.writeInt(u16, out[o + 12 ..][0..2], q16(arr(bk, A_AGE)[j] / arr(bk, A_LIFE)[j], 0, 1.0), .little);
            std.mem.writeInt(u16, out[o + 14 ..][0..2], q16(arr(bk, A_SIZE)[j], 0, rdF(h, 36)), .little);
            wrU(out, o + 16, arrU(bk, A_ID)[j]);
            o += CR_P;
        }
    }
}

/// pt_play: the systems hold those frames' particles (not to be stepped on).
fn play(r2: ?[]u8, r3: ?[]u8, steps: u32, k: u64) void {
    if (!on) {
        build();
    } else {
        for (sr[0..ns]) |*s| {
            s.nb = 0;
            s.n = 0;
        }
        freeAll();
    }
    if (!on) return;
    for ([2]?[]u8{ r2, r3 }) |rr| {
        const rec = rr orelse continue;
        var nsys = rdU(rec, 0);
        var o: usize = 4;
        while (nsys > 0) : (nsys -= 1) {
            if (o + CR_HDR > rec.len) break;
            const idx = rdU(rec, o);
            const n = rdU(rec, o + 4);
            if (o + CR_HDR + @as(usize, n) * CR_P > rec.len) break;
            if (idx < ns) crRead(&sr[idx], rec[o..]);
            o += CR_HDR + @as(usize, n) * CR_P;
        }
    }
    now = steps;
    hash = k;
    played = true;
}

/// cr_read: its particles from its part of a record.
fn crRead(s: *Sys, h: []const u8) void {
    const col: u32 = if (nth(s.uid, s.k)) |r| r.color else 0x9fc8ff;
    var rg: [3]f32 = undefined;
    for (0..3) |c| rg[c] = (rdF(h, 20 + c * 4) - rdF(h, 8 + c * 4)) * 1.5259022e-5;
    var left = rdU(h, 4);
    var src: usize = CR_HDR;
    while (left > 0) {
        const bk = blkGet() orelse break;
        sblk[s.si][s.nb] = bk;
        s.nb += 1;
        bsys[bk] = s.si;
        const c = @min(left, BLK);
        bn[bk] = c;
        s.n += c;
        left -= c;
        for (0..c) |j| {
            const q = h[src..][0..CR_P];
            for (0..3) |a| {
                const u: f32 = @floatFromInt(std.mem.readInt(u16, q[a * 2 ..][0..2], .little));
                arr(bk, A_X + a)[j] = u * rg[a] + rdF(h, 8 + a * 4);
                const iv: f32 = @floatFromInt(std.mem.readInt(i16, q[6 + a * 2 ..][0..2], .little));
                arr(bk, A_VX + a)[j] = iv * 3.0518509e-5 * rdF(h, 32);
            }
            arr(bk, A_AGE)[j] = @as(f32, @floatFromInt(std.mem.readInt(u16, q[12..14], .little))) * 1.5259022e-5;
            arr(bk, A_LIFE)[j] = 1.0;
            arr(bk, A_SIZE)[j] = @as(f32, @floatFromInt(std.mem.readInt(u16, q[14..16], .little))) * 1.5259022e-5 * rdF(h, 36);
            arrU(bk, A_ID)[j] = rdU(q, 16);
            arrU(bk, A_COL)[j] = col;
            arrU(bk, A_FLAG)[j] = 0;
            src += CR_P;
        }
    }
}

// ---- operators ------------------------------------------------------------------------------------

const s_added = "  particles on ";
const s_nosys = "  particles: no such system on ";

const Preset = struct { kw: []const u8, set: []const u8, name: []const u8, prim: u8, h: f32, scl: [3]f32 };
const presets = [6]Preset{
    .{ .kw = "rain", .set = "from faces rate 3000 speed 2 direction 0 -1 0 life 4 size 0.02 draw points point_px 1 color a8c8ff collide on on_hit die name Rain", .name = "Rain Cloud", .prim = 3, .h = 8.0, .scl = .{ 5.0, 1.0, 5.0 } },
    .{ .kw = "snow", .set = "from faces rate 400 speed 0 gravity 0.1 drag 1.5 life 15 size 0.05 color ffffff collide on on_hit stick name Snow", .name = "Snow Cloud", .prim = 3, .h = 8.0, .scl = .{ 5.0, 1.0, 5.0 } },
    .{ .kw = "sparks", .set = "from point rate 300 speed 6 spread 35 direction 0 1 0 life 0.8 life_random 0.5 size 0.03 color ffd060 color_end ff3000 size_end 0.3 drag 0.5 collide on bounce 0.4 name Sparks", .name = "Sparks", .prim = 1, .h = 0.1, .scl = .{ 0.1, 0.1, 0.1 } },
    .{ .kw = "confetti", .set = "from point burst 600 speed 7 spread 40 speed_random 0.4 direction 0 1 0 drag 2 gravity 0.4 life 6 size 0.06 color ff4080 color_end 40c0ff collide on bounce 0.1 friction 0.6 name Confetti", .name = "Confetti", .prim = 1, .h = 0.1, .scl = .{ 0.1, 0.1, 0.1 } },
    .{ .kw = "fountain", .set = "from point rate 600 speed 6 spread 6 direction 0 1 0 life 2.5 size 0.04 color 80c0ff color_end ffffff collide on bounce 0.2 name Fountain", .name = "Fountain", .prim = 2, .h = 0.1, .scl = .{ 0.4, 0.1, 0.4 } },
    .{ .kw = "tank", .set = "from fill size 0.05 life 100000 speed 0 liquid on surface on name Water", .name = "Water", .prim = 0, .h = 0.4, .scl = .{ 0.5, 0.4, 0.5 } },
};
pub const preset_labels = [6][]const u8{ "Rain", "Snow", "Sparks", "Confetti", "Fountain", "Water Tank" };

/// pr_text: a preset's settings when the first word names one, and the rest.
fn presetText(text: []const u8) struct { set: ?[]const u8, rest: []const u8 } {
    var it = Words{ .s = text };
    const w = it.next() orelse return .{ .set = null, .rest = text };
    for (presets) |p| {
        if (std.mem.eql(u8, p.kw, w)) return .{ .set = p.set, .rest = it.rest() };
    }
    return .{ .set = null, .rest = text };
}

/// ps_add: object i's new system (a preset first when the text's first word
/// names one, then the settings): its number (1 ..), or 0.
pub fn add(i: usize, text: []const u8) u32 {
    const uid = scene.objects[i].uid;
    const r = new(uid) orelse {
        app.log("  particles: a scene has at most 64 systems", .{});
        return 0;
    };
    const pt = presetText(text);
    if (pt.set) |s| _ = parse(r, s);
    _ = parse(r, pt.rest);
    water(i, r);
    app.dirty = true;
    return count(uid);
}

/// ps_water: a surface on an object with no material: the water preset's.
fn water(i: usize, r: *const Rec) void {
    if (r.surf & 1 == 0) return;
    if (scene.objects[i].mat != 0) return;
    const keep_a = scene.active;
    scene.active = i;
    defer scene.active = keep_a;
    if (@import("material.zig").presetIndex("water")) |k| @import("matops.zig").presetActive(k);
}

/// which: the system the text names first ("system n": n - 1, else 0), the rest.
fn which(text: []const u8) struct { k: u32, rest: []const u8 } {
    var it = Words{ .s = text };
    const w = it.next() orelse return .{ .k = 0, .rest = text };
    if (!std.mem.eql(u8, w, "system")) return .{ .k = 0, .rest = text };
    const v = it.next() orelse return .{ .k = 0, .rest = it.rest() };
    const x = parseFloat(v) orelse return .{ .k = 0, .rest = it.rest() };
    var k = cvtt(x) -% 1;
    if (k < 0) k = 0;
    return .{ .k = @intCast(k), .rest = it.rest() };
}

fn activeObj() ?usize {
    if (scene.active) |a| {
        if (a < scene.count) return a;
    }
    app.log("  particles: select the object to emit from first", .{});
    return null;
}

/// particles.add [settings]
fn opAdd() void {
    const i = activeObj() orelse return;
    if (add(i, ops.arg) == 0) return;
    if (!ops.quiet) app.log("{s}{s}", .{ s_added, scene.objects[i].name() });
    undo.label("Particle System");
}

/// particles.set [system n] settings
fn opSet() void {
    const i = activeObj() orelse return;
    const w = which(ops.arg);
    const r = nthOwn(scene.objects[i].uid, w.k) orelse return app.log("{s}{s}", .{ s_nosys, scene.objects[i].name() });
    _ = parse(r, w.rest);
    water(i, r);
    app.dirty = true;
    undo.label("Particle Settings");
}

/// particles.remove [system n]
fn opRemove() void {
    const i = activeObj() orelse return;
    const w = which(ops.arg);
    if (del(scene.objects[i].uid, w.k)) {
        app.log("  particles removed from {s}", .{scene.objects[i].name()});
    } else app.log("{s}{s}", .{ s_nosys, scene.objects[i].name() });
    app.dirty = true;
    undo.label("Remove Particle System");
}

/// unique_name: the base, then base.001 ...
fn rename(i: usize, base: []const u8) void {
    var buf: [40]u8 = undefined;
    scene.objects[i].name_len = 0;
    var k: u32 = 0;
    while (k < 1000) : (k += 1) {
        const nm = if (k == 0) base else std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ base, k }) catch base;
        if (scene.find(nm) == null) {
            scene.objects[i].setName(nm);
            return;
        }
    }
    scene.objects[i].setName(base);
}

/// do_ps_preset: an emitter at the 3D cursor with that preset's system (then
/// the operator's settings).
fn preset(comptime k: usize) *const fn () void {
    return &struct {
        fn f() void {
            const p = presets[k];
            switch (p.prim) {
                0 => ops.runId("create.cube"),
                1 => ops.runId("create.sphere"),
                2 => ops.runId("create.cylinder"),
                else => ops.runId("create.plane"),
            }
            const i = scene.active orelse return;
            rename(i, p.name);
            const o = &scene.objects[i];
            o.loc[1] = p.h + o.loc[1];
            o.scl = p.scl;
            const n = add(i, p.set);
            if (n == 0) return;
            const r = nthOwn(o.uid, n - 1) orelse return;
            if (k == 5) {
                // a tank: its box (twice its block, from the floor)
                const sx = o.scl[0] + o.scl[0];
                r.domain[0] = o.loc[0] - sx;
                r.domain[3] = o.loc[0] + sx;
                const y0 = o.loc[1] - o.scl[1];
                r.domain[1] = y0;
                r.domain[4] = y0 + o.scl[1] * 4.0;
                r.domain[2] = o.loc[2] - o.scl[2];
                r.domain[5] = o.loc[2] + o.scl[2];
                r.domon |= 1;
            }
            _ = parse(r, ops.arg);
            undo.label(preset_labels[k]);
        }
    }.f;
}

fn opBake() void {
    ops.arg = "particles liquid";
    ops.runId("sim.bake");
}
fn opFree() void {
    ops.arg = "particles liquid";
    ops.runId("sim.free");
}

const Impl = ops.Impl;
pub const list = .{
    .{ "particles.add", Impl{ .run = opAdd } },
    .{ "particles.set", Impl{ .run = opSet } },
    .{ "particles.remove", Impl{ .run = opRemove } },
    .{ "particles.add_rain", Impl{ .run = preset(0) } },
    .{ "particles.add_snow", Impl{ .run = preset(1) } },
    .{ "particles.add_sparks", Impl{ .run = preset(2) } },
    .{ "particles.add_confetti", Impl{ .run = preset(3) } },
    .{ "particles.add_fountain", Impl{ .run = preset(4) } },
    .{ "particles.add_tank", Impl{ .run = preset(5) } },
    .{ "particles.bake", Impl{ .run = opBake } },
    .{ "particles.free", Impl{ .run = opFree } },
};

// ---- tests' window into it --------------------------------------------------------------------------

/// --dump-particles OUT: every particle (the systems' order) appended as hex
/// bits: x y z vx vy vz age life size id colour, then a line of counts.
pub fn dump(path: []const u8) void {
    var pb: [512]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&pb, "{s}", .{path}, 0) catch return;
    const rcode = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    if (linux.errno(rcode) != .SUCCESS) return;
    const fd: i32 = @intCast(rcode);
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var total: u32 = 0;
    for (sr[0..ns], 0..) |*s, si| {
        for (sblk[si][0..s.nb]) |bk| {
            for (0..bn[bk]) |j| {
                for ([_]usize{ A_X, A_Y, A_Z, A_VX, A_VY, A_VZ, A_AGE, A_LIFE, A_SIZE, A_ID, A_COL }) |a| w.print("{x} ", .{arrU(bk, a)[j]}) catch {};
                w.writeAll("\n") catch {};
                if (w.end > buf.len - 200) {
                    _ = linux.write(fd, &buf, w.end);
                    w.end = 0;
                }
                total += 1;
            }
        }
    }
    w.print("info {d} {d} {d} {d} {d}\n", .{ total, ns, now, info(19, 0), info(4, 0) }) catch {};
    _ = linux.write(fd, &buf, w.end);
}

test "records and the chunk" {
    resetSettings();
    defer resetSettings();
    const r = new(7) orelse return error.NoRoom;
    try std.testing.expect(parse(r, "rate 200 life 2 name Foo color ff0000 direction 0 0 1"));
    try std.testing.expectEqual(@as(f32, 200), r.rate);
    try std.testing.expectEqual(@as(u32, 1), r.vmode);
    try std.testing.expectEqualStrings("Foo", cstr(&r.name));
    try std.testing.expectEqual(@as(u8, 'i'), r.name[4]); // (what was past it stays)
    try std.testing.expect(!parse(r, "bogus 1"));
    try std.testing.expect(parse(r, "burst -5 seed 3.7"));
    try std.testing.expectEqual(@as(u32, 0), r.num);
    try std.testing.expectEqual(@as(u32, 3), r.seed);
    try std.testing.expectEqual(@as(u32, 1), r.mode);
}

test "prand" {
    const a = prand(0, 0, 0);
    try std.testing.expect(a >= 0 and a < 1);
    try std.testing.expectEqual(prand(5, 3, 9), prand(5, 3, 9));
}
