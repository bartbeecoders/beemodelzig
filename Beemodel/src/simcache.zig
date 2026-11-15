// The simulation cache (simcache.s).
//
// Four channels: 0 rigid bodies (each moving body's object place a frame),
// 1 cloth, 2 particles and 3 liquids (their own records). A channel holds
// frames start+1 .. start+n, recorded as the simulation reaches them, and
// played back after: going back on the timeline shows them without
// simulating again.
//
// The cache belongs to a key: the settings, the objects the simulation starts
// from (their places, their meshes), the animation. When the key changes the
// cache goes. A baked channel keeps its frames whatever changes (sim.free lets
// it go), and it is saved in the .bee file (SIMC). All channels share a memory
// budget (sim.cache budget, 1024 MB): a channel that would go over it stops
// recording.
//
// Each channel reserves 4 GiB of address space (pages taken as used, given
// back with MADV_DONTNEED when cleared), as the original.
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const anim = @import("anim.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const scene = @import("scene.zig");

pub const NCH = 4;
const CAP: usize = 0x100000000; // address space a channel
pub const MAXF: u32 = 0x100000; // frames a channel

const Chan = struct {
    key: u64 = 0,
    start: i32 = 0,
    n: u32 = 0,
    baked: u32 = 0,
    full: u32 = 0,
    base: ?[*]u8 = null, // frames (reserved, CAP)
    used: usize = 0,
    idx: ?[*]u64 = null, // each frame's offset
};

pub var budget: u64 = 1024 * 1024 * 1024;
var ch: [NCH]Chan = @splat(.{});

/// The other simulations' resets (cloth, particles: later layers).
pub var cloth_reset: ?*const fn () void = &@import("cloth.zig").reset; // cl_reset
pub var parts_reset: ?*const fn () void = &@import("particles.zig").reset; // pt_reset
/// Something to bake besides rigid bodies: cloth objects (bit 2), particles (bits 4|8).
pub var cloth_count: ?*const fn () u32 = &@import("cloth.zig").count; // AN_CW_ CW_N
pub var parts_count: ?*const fn () u32 = &@import("particles.zig").countAll; // ps_cur PB_N

fn chan(c: u32) *Chan {
    return &ch[c & (NCH - 1)];
}

fn reserve(bytes: usize) ?[*]u8 {
    const rc = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @ptrFromInt(rc);
}

fn dontneed(p: ?[*]u8, bytes: usize) void {
    const a = p orelse return;
    const n = (bytes + 4095) & ~@as(usize, 4095);
    if (n == 0) return;
    _ = linux.madvise(a, n, linux.MADV.DONTNEED);
}

/// sc_mix: the hash through these bytes (8 at a time, then one by one).
pub fn mix(h0: u64, bytes: []const u8) u64 {
    const K: u64 = 0x9E3779B97F4A7C15;
    var h = h0;
    var i: usize = 0;
    while (bytes.len - i >= 8) : (i += 8) {
        h ^= std.mem.readInt(u64, bytes[i..][0..8], .little);
        h *%= K;
    }
    while (i < bytes.len) : (i += 1) {
        h ^= bytes[i];
        h *%= K;
    }
    return h;
}

/// sc_meshhash: its counts (vertices, polygons, loops, edges, triangles),
/// vertices, loops.
pub fn meshHash(h0: u64, me: ?*const scene.Mesh) u64 {
    const x = me orelse return h0;
    var c: [5]u32 = .{ @intCast(x.verts.len), x.faces(), @intCast(x.loops.len), x.edges, @intCast(x.tris.len) };
    var h = mix(h0, std.mem.asBytes(&c));
    h = mix(h, std.mem.sliceAsBytes(x.verts));
    h = mix(h, std.mem.sliceAsBytes(x.loops));
    return h;
}

/// sc_reset: a new scene, nothing cached.
pub fn reset() void {
    for (0..NCH) |k| {
        clear(@intCast(k));
        ch[k].key = 0;
    }
}

/// sc_clear: its frames (and its bake) go.
pub fn clear(c: u32) void {
    const x = chan(c);
    if (x.n == 0 and x.baked == 0 and x.full == 0) return;
    dontneed(x.base, x.used);
    if (x.idx) |p| dontneed(@ptrCast(p), @as(usize, x.n) * 8);
    x.used = 0;
    x.n = 0;
    x.baked = 0;
    x.full = 0;
    app.dirty = true;
}

/// sc_check: true when baked (its frames are what is shown); else a
/// different key or start drops what is cached and takes their place.
pub fn check(c: u32, key: u64, start: i32) bool {
    const x = chan(c);
    if (x.baked != 0) return true;
    if (x.key != key or x.start != start) {
        clear(c);
        x.key = key;
        x.start = start;
    }
    return false;
}

pub fn keyOf(c: u32) u64 {
    return chan(c).key;
}

fn frameAt(x: *Chan, k: u32) []u8 {
    const off = x.idx.?[k];
    return x.base.?[off..][0..fsize(x, k)];
}

/// sc_get: that frame's record, or null.
pub fn get(c: u32, f: i32) ?[]u8 {
    const x = chan(c);
    const k = f -% x.start -% 1;
    if (k < 0) return null;
    if (@as(u32, @intCast(k)) >= x.n) return null;
    return frameAt(x, @intCast(k));
}

/// sc_last: the last frame cached (the start: none).
pub fn last(c: u32) i32 {
    const x = chan(c);
    return x.start +% @as(i32, @bitCast(x.n));
}

pub const Range = struct { start: i32, last: i32, baked: bool };
pub fn range(c: u32) Range {
    const x = chan(c);
    return .{ .start = x.start, .last = x.start +% @as(i32, @bitCast(x.n)), .baked = x.baked != 0 };
}

/// Bytes in use, all channels.
fn total() u64 {
    var t: u64 = 0;
    for (&ch) |*x| t += x.used;
    return t;
}

/// frame_room: room for the next frame (and the channel full when none).
fn frameRoom(x: *Chan, bytes0: usize) ?[]u8 {
    if (x.n >= MAXF) {
        x.full = 1;
        return null;
    }
    const bytes = (bytes0 + 15) & ~@as(usize, 15);
    if (x.base == null) {
        x.base = reserve(CAP);
        if (reserve(MAXF * 8)) |p| x.idx = @ptrCast(@alignCast(p));
    }
    if (x.base == null or x.idx == null) {
        x.full = 1;
        return null;
    }
    if (x.used + bytes > CAP or total() + bytes > budget) {
        x.full = 1;
        return null;
    }
    const at = x.used;
    x.idx.?[x.n] = at;
    x.n += 1;
    x.used += bytes;
    app.dirty = true;
    return x.base.?[at..][0..bytes];
}

/// sc_add: room for that frame's record, or null (not the next frame, baked,
/// or no room).
pub fn add(c: u32, f: i32, bytes: usize) ?[]u8 {
    const x = chan(c);
    if (x.baked != 0 or x.full != 0) return null;
    if (f != x.start +% @as(i32, @bitCast(x.n)) +% 1) return null;
    return frameRoom(x, bytes);
}

/// fsize: a frame's record's size (to the next, or the end).
fn fsize(x: *Chan, k: u32) usize {
    const p = x.idx.?;
    if (k + 1 < x.n) return p[k + 1] - p[k];
    return x.used - p[k];
}

/// sc_info: 0 rigid frames, 1 cloth frames, 2 MB in use, 3 rigid baked, 4
/// cloth baked, 5 full, 6 the budget (MB), 7 particles frames, 8 liquid
/// frames, 9 particles baked, 10 liquid baked.
pub fn info(what: u32) f32 {
    if (what >= 7 and what <= 10) {
        const c = if (what >= 9) what - 7 else what - 5;
        const x = chan(c);
        return @floatFromInt(if (what >= 9) x.baked else x.n);
    }
    if (what <= 1) return @floatFromInt(chan(what).n);
    if (what == 2) return @as(f32, @floatFromInt(@as(i64, @bitCast(total())))) * 9.5367431640625e-7;
    if (what < 5) return @floatFromInt(chan(what - 3).baked);
    if (what == 5) return @floatFromInt(ch[0].full | ch[1].full | ch[2].full | ch[3].full);
    return @floatFromInt(budget >> 20);
}

// ---- the operators ------------------------------------------------------------------

const s_bad = "  not understood: ";

fn words(arg: []const u8) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, arg, ' ');
}

fn say(parts: []const []const u8) void {
    var b: [128]u8 = undefined;
    var n: usize = 0;
    for (parts) |p| {
        for (p) |c| {
            if (n >= 95) break;
            b[n] = c;
            n += 1;
        }
    }
    app.log("{s}", .{b[0..n]});
}

/// which: the channels named (bit 0 rigid, 1 cloth, 2 particles, 3 liquid;
/// all when none), or null (not understood: said).
fn which(arg: []const u8) ?u32 {
    var it = words(arg);
    var m: u32 = 0;
    while (it.next()) |w0| {
        const w = w0[0..@min(w0.len, 255)];
        if (std.mem.eql(u8, w, "rigid")) {
            m |= 1;
        } else if (std.mem.eql(u8, w, "cloth")) {
            m |= 2;
        } else if (std.mem.eql(u8, w, "particles")) {
            m |= 4;
        } else if (std.mem.eql(u8, w, "liquid")) {
            m |= 8;
        } else {
            say(&.{ s_bad, w });
            return null;
        }
    }
    return if (m == 0) 15 else m;
}

/// apply: the scene at that frame (simulations follow).
fn apply(f: i32) void {
    anim.apply(@floatFromInt(f));
}

fn resetSims(m: u32) void {
    if (m & 1 != 0) @import("rbody.zig").reset();
    if (m & 2 != 0) if (cloth_reset) |f| f();
    if (m & 12 != 0) if (parts_reset) |f| f();
}

/// sim.bake [rigid|cloth|particles|liquid]: a job (job_sim_bake).
fn opBake() void {
    @import("jobui.zig").later(bakeJob, "Baking the simulation", ops.arg, 0, 0);
}

fn bakeJob(arg: []const u8, _: usize, _: usize) void {
    const jobui = @import("jobui.zig");
    jobui.begin("Baking the simulation");
    defer jobui.end();
    const m = which(arg) orelse return;
    // particles alone: their frame range (an animation block for it: an_own_g)
    if (anim.cur == null and @import("particles.zig").cur != null) _ = anim.own(0);
    const b0 = anim.cur orelse return say(&.{"  sim.bake: no rigid bodies, cloth or particles to bake"});
    var some: u32 = 0;
    if (m & 1 != 0) some |= b0.h.nrb;
    if (m & 2 != 0) if (cloth_count) |f| {
        some |= f();
    };
    if (m & 12 != 0) if (parts_count) |f| {
        some |= f();
    };
    if (some == 0) return say(&.{"  sim.bake: no rigid bodies, cloth or particles to bake"});
    const keep = anim.frame;
    for (0..NCH) |k| {
        if (m >> @intCast(k) & 1 != 0) clear(@intCast(k));
    }
    const fr = &@import("frange.zig").r;
    apply(fr.start);
    @import("rbody.zig").reset();
    if (cloth_reset) |f| f();
    if (parts_reset) |f| f();
    var f = fr.start;
    const end = fr.end;
    while (true) {
        f +%= 1;
        if (f > end) break;
        apply(f);
        const done: f32 = @floatFromInt(f -% fr.start);
        const all: f32 = @floatFromInt(end -% fr.start);
        jobui.set(done / all);
    }
    for (0..NCH) |k| {
        if (m >> @intCast(k) & 1 == 0) continue;
        if (ch[k].n != 0) ch[k].baked = 1;
    }
    anim.apply(keep);
    status();
}

/// sim.free [rigid|cloth|particles|liquid]
fn opFree() void {
    const m = which(ops.arg) orelse return;
    for (0..NCH) |k| {
        if (m >> @intCast(k) & 1 != 0) {
            clear(@intCast(k));
            resetSims(@as(u32, 1) << @intCast(k));
        }
    }
    say(&.{"  cache freed"});
    anim.apply(anim.frame);
}

/// sim.cache [budget MB]
fn opCache() void {
    var it = words(ops.arg);
    const w = it.next() orelse return status();
    if (!std.mem.eql(u8, w, "budget")) return say(&.{ s_bad, w[0..@min(w.len, 255)] });
    const v = it.next() orelse return say(&.{ s_bad, "" });
    const x = @import("mech.zig").parseFloat(v) orelse return say(&.{ s_bad, v[0..@min(v.len, 255)] });
    // cvttss2si rax: out of range or NaN is the minimum
    var mb: i64 = if (x >= -9.223372036854775808e18 and x < 9.223372036854775808e18) @intFromFloat(x) else std.math.minInt(i64);
    if (mb < 16) mb = 16;
    if (mb > 3000) mb = 3000;
    budget = @as(u64, @intCast(mb)) << 20;
    for (&ch) |*c| c.full = 0;
    status();
}

/// cvtss2si: to the nearest, ties to even.
fn cvtss2si(x: f32) i32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    const f = @floor(x);
    const d = x - f;
    var r: i32 = @intFromFloat(f);
    if (d > 0.5 or (d == 0.5 and @mod(r, 2) != 0)) r += 1;
    return r;
}

/// fmt_fix1: one decimal.
pub fn fix1(buf: []u8, v: f32) []const u8 {
    var k = cvtss2si(v * 10.0);
    var n: usize = 0;
    if (k < 0) {
        buf[0] = '-';
        n = 1;
        k = -%k;
    }
    const u: u32 = @bitCast(k);
    const s = std.fmt.bufPrint(buf[n..], "{d}.{d}", .{ u / 10, u % 10 }) catch return buf[0..n];
    return buf[0 .. n + s.len];
}

/// "  cache: rigid 120 frames (baked), cloth 0 frames, particles 0 frames, liquid 0 frames, 3.2 MB of 1024 MB"
fn status() void {
    var b: [160]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    const names = [_][]const u8{ ", cloth ", ", particles ", ", liquid " };
    w.writeAll("  cache: rigid ") catch {};
    for (0..NCH) |k| {
        w.print("{d} frames", .{ch[k].n}) catch {};
        if (ch[k].baked != 0) {
            w.writeAll(" (baked)") catch {};
        } else if (ch[k].full != 0) w.writeAll(" (full)") catch {};
        if (k < NCH - 1) w.writeAll(names[k]) catch {};
    }
    var fb: [32]u8 = undefined;
    const mb = @as(f32, @floatFromInt(@as(i64, @bitCast(total())))) * 9.5367431640625e-7;
    w.print(", {s} MB of {d} MB", .{ fix1(&fb, mb), budget >> 20 }) catch {};
    say(&.{w.buffered()});
}

// ---- the SIMC chunk: each baked channel: channel, start, key (u64), frames,
// each frame's size, then the frames ---------------------------------------------------

pub fn writeChunk(out: anytype) void {
    for (0..NCH) |k| {
        const x = &ch[k];
        if (x.baked == 0 or x.n == 0) continue;
        out.u32_(@intCast(k));
        out.u32_(@bitCast(x.start));
        out.u32_(@truncate(x.key));
        out.u32_(@truncate(x.key >> 32));
        out.u32_(x.n);
        for (0..x.n) |f| out.u32_(@intCast(fsize(x, @intCast(f))));
        for (0..x.n) |f| out.bytes(frameAt(x, @intCast(f)));
    }
}

fn rd(c: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, c[o..][0..4], .little);
}

/// simc_read (after reset): false when the chunk was damaged (what came
/// before the damage is kept, as the original).
pub fn readChunk(data: []const u8) bool {
    var p: usize = 0;
    var left: u32 = @intCast(@min(data.len, 0xffffffff));
    while (true) {
        if (left < 20) return left == 0;
        const c = rd(data, p);
        if (c >= NCH) return false;
        const nf = rd(data, p + 16);
        if (nf > MAXF) return false;
        const head = nf * 4 + 20;
        if (head > left) return false;
        const x = &ch[c];
        clear(c);
        x.start = @bitCast(rd(data, p + 4));
        x.key = std.mem.readInt(u64, data[p + 8 ..][0..8], .little);
        var sz = p + 20;
        p += head;
        left -= head;
        var k: u32 = 0;
        while (k < nf) : (k += 1) {
            const s = rd(data, sz);
            if (s > left) return false;
            const r = frameRoom(x, s) orelse return false;
            @memcpy(r[0..s], data[p..][0..s]);
            p += s;
            left -= s;
            sz += 4;
        }
        if (x.n != 0) x.baked = 1;
    }
}

pub const list = .{
    .{ "sim.bake", ops.Impl{ .run = opBake } },
    .{ "sim.free", ops.Impl{ .run = opFree } },
    .{ "sim.cache", ops.Impl{ .run = opCache } },
};

test "sc_mix" {
    try std.testing.expectEqual(@as(u64, 0x9E3779B97F4A7C15), mix(1, &.{}) *% 0 +% 0x9E3779B97F4A7C15);
    const h = mix(0, &.{ 1, 0, 0, 0, 0, 0, 0, 0, 2 });
    try std.testing.expectEqual((@as(u64, 1) *% 0x9E3779B97F4A7C15 ^ 2) *% 0x9E3779B97F4A7C15, h);
}

test "frames in and out" {
    reset();
    try std.testing.expect(!check(0, 42, 1));
    const r = add(0, 2, 20) orelse return error.NoRoom;
    try std.testing.expectEqual(@as(usize, 32), r.len);
    try std.testing.expect(add(0, 4, 8) == null);
    _ = add(0, 3, 16) orelse return error.NoRoom;
    try std.testing.expectEqual(@as(i32, 3), last(0));
    try std.testing.expect(get(0, 2) != null and get(0, 1) == null and get(0, 4) == null);
    try std.testing.expect(!check(0, 43, 1));
    try std.testing.expectEqual(@as(i32, 1), last(0));
    reset();
}
