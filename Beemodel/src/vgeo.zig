// Virtualized geometry, part 1: the cluster LOD DAG (vgeo.s).
//
// vgeo.build turns a mesh into clusters of up to 128 triangles and 128
// vertices grown over their neighbours (seeded in Morton order), then, level
// by level, groups neighbouring clusters, simplifies each group to half its
// triangles (quadric error, half-edge collapses, the group's border locked)
// and splits it into new clusters, until one cluster is left or a level no
// longer shrinks.
//
// Every cluster keeps its bounds, the error and LOD sphere of the group that
// made it and those of the group it was simplified in: errors only grow up
// the DAG and the spheres nest, so any cut "error <= t < parent error" is
// crack-free. Positions are welded on a 2^20 grid over the mesh's extent; a
// collapse keeps one of its vertices, so every level uses the original
// vertices and borders match exactly.
//
// The DAG is one block, as in the file: a header, the clusters (64 B), groups
// (48 B) and their member lists, then the page-aligned cluster data, per
// cluster its vertices (i32 grid x y z + an octahedral normal) and triangles
// (u8 x 3). A build gives the same bytes as the original's, but for VH_MS and
// the cluster bounds' radii (see fixRadii).
//
// A DAG goes with a mesh by its hash (the original's sc_meshhash, kept in the
// block), so the mesh that matches may be a base mesh, or what an object's
// modifiers evaluate to (mods.of), whichever object shows it. The build runs
// on its own threads (jobs.parallelFor belongs to the UI thread): in the
// window behind a chip in the status bar, headless at once.
const std = @import("std");
const linux = std.os.linux;
const scene = @import("scene.zig");
const m = @import("math.zig");
const A = @import("alloc.zig").A;

pub const MAGIC: u32 = 0x4F454756; // "VGEO"
pub const VERSION: u32 = 2;
pub const VH_SZ = 1024;
pub const VR_CREATOR = 520; // where the runtime part of the header begins: zeros in files
pub const MAXLV = 24;
pub const CL_TRIS = 128;
pub const CL_VERTS = 128;
pub const VP_SHIFT = 16; // streaming pages: 64 KiB of cluster data
pub const VP_BYTES: usize = 1 << VP_SHIFT;
const FIXED_MARK: u32 = 0x31584952; // VH_FIXED: the clusters' radii are true

const BLK = 4096; // level 0 is partitioned in blocks
const NCAND = 1024;
const GMAXN = 32;
const GTRIS = 1024;
const GTSMALL = 256;
const GTMAX = 1536;
const FLT_MAX: u32 = 0x7f7fffff;

pub const Level = extern struct { first: u32, n: u32, tris: u32, err: f32 };

pub const Header = extern struct {
    magic: u32,
    ver: u32,
    refs: u32,
    ncl: u32,
    ngr: u32,
    nlv: u32,
    stri: u32, // source triangles (welded, no degenerate)
    svert: u32, // welded vertices
    bmin: [3]f32, // the grid's origin
    step: f32, // its spacing
    hash: u64 align(4), // the mesh it was built from
    ms: u32, // build time
    ttri: u32, // triangles in all clusters
    nmem: u32,
    roots: u32,
    ocl: u64 align(4), // offsets in the block
    ogr: u64 align(4),
    omem: u64 align(4),
    odata: u64 align(4),
    dbytes: u64 align(4),
    bytes: u64 align(4),
    rerr: f32, // the largest error
    fixed: u32, // (the port: FIXED_MARK; the original leaves it 0 and keeps it)
    lv: [MAXLV]Level,
    phash: u64 align(4), // a proxy mesh standing in for it (vgeo.proxy)
};

pub const Cluster = extern struct {
    c: [4]f32, // bounds: centre, radius
    lod: [4]f32, // LOD sphere (of the group that made it)
    plod: [4]f32, // parent LOD sphere (the group it is in)
    err: f32,
    perr: f32, // FLT_MAX for roots
    data: u32, // data offset / 16
    nv: u8,
    nt: u8,
    level: u8,
    pad: u8,
};

pub const Group = extern struct {
    mem: u32, // first member (index into members)
    nmem: u32,
    par: u32, // first cluster it made
    npar: u32,
    err: f32,
    lod: [4]f32,
    level: u32,
    pad: [2]u32,
};

comptime {
    std.debug.assert(@offsetOf(Header, "hash") == 48);
    std.debug.assert(@offsetOf(Header, "ttri") == 60);
    std.debug.assert(@offsetOf(Header, "ocl") == 72);
    std.debug.assert(@offsetOf(Header, "bytes") == 112);
    std.debug.assert(@offsetOf(Header, "rerr") == 120);
    std.debug.assert(@offsetOf(Header, "lv") == 128);
    std.debug.assert(@offsetOf(Header, "phash") == 512);
    std.debug.assert(@sizeOf(Cluster) == 64);
    std.debug.assert(@offsetOf(Cluster, "err") == 48);
    std.debug.assert(@offsetOf(Cluster, "nv") == 60);
    std.debug.assert(@sizeOf(Group) == 48);
    std.debug.assert(@offsetOf(Group, "lod") == 20);
    std.debug.assert(@offsetOf(Group, "level") == 36);
}

/// A DAG in memory: the block (anonymous, or mapped from a .bee file) and what
/// drawing keeps for it (vgdraw.zig). The block is never written after it is
/// made, but for the radii (a private mapping when it is the file's).
pub const Dag = struct {
    block: []align(4096) u8,
    hash: u64,
    phash: u64 = 0,
    // runtime (vgdraw.zig)
    stream: bool = false, // mapped from a file: pages stream
    ready: bool = false,
    creator: []u32 = &.{}, // per cluster: the group that made it + 1
    roots: []u32 = &.{},
    gcull: []f32 = &.{}, // per group: a sphere holding all it stands for
    state: []u8 = &.{}, // per page: 0 out, 1 asked, 2 in, 3 pinned
    stamp: []u32 = &.{}, // per page: the frame it was last used
    reg: u32 = 0, // slot in the streamed list + 1

    pub fn hdr(d: *const Dag) *const Header {
        return @ptrCast(@alignCast(d.block.ptr));
    }
    pub fn clusters(d: *const Dag) []Cluster {
        const p: [*]Cluster = @ptrCast(@alignCast(d.block.ptr + VH_SZ));
        return p[0..d.hdr().ncl];
    }
    pub fn groups(d: *const Dag) []const Group {
        const p: [*]const Group = @ptrCast(@alignCast(d.block.ptr + d.hdr().ogr));
        return p[0..d.hdr().ngr];
    }
    pub fn members(d: *const Dag) []const u32 {
        const p: [*]const u32 = @ptrCast(@alignCast(d.block.ptr + d.hdr().omem));
        return p[0..d.hdr().nmem];
    }
    pub fn data(d: *const Dag, c: *const Cluster) [*]const u8 {
        return d.block.ptr + d.hdr().odata + @as(u64, c.data) * 16;
    }
};

pub fn clusterBytes(c: *const Cluster) u64 {
    return @as(u64, c.nv) * 16 + ((@as(u64, c.nt) * 3 + 15) & ~@as(u64, 15));
}

// --- small things, as the SSE code does them --------------------------------------------

fn fmax(a: f32, b: f32) f32 {
    return if (a > b) a else b; // maxss a, b
}
fn fmin(a: f32, b: f32) f32 {
    return if (a < b) a else b; // minss a, b
}

/// cvtss2si / cvtps2dq: to the nearest, halves to even; NaN and out of range give
/// the integer indefinite.
fn rint(x: f32) i32 {
    if (!(@abs(x) < 2147483648.0)) return std.math.minInt(i32);
    var r = @floor(x);
    const d = x - r;
    if (d > 0.5 or (d == 0.5 and @mod(r, 2.0) != 0)) r += 1;
    return @intFromFloat(r);
}

pub fn mix(x0: u64) u64 {
    var x = x0;
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

fn scMix(h0: u64, b: []const u8) u64 {
    const K: u64 = 0x9E3779B97F4A7C15;
    var h = h0;
    var i: usize = 0;
    while (i + 8 <= b.len) : (i += 8) {
        h = (h ^ std.mem.readInt(u64, b[i..][0..8], .little)) *% K;
    }
    while (i < b.len) : (i += 1) h = (h ^ b[i]) *% K;
    return h;
}

/// The original's sc_meshhash: its counts, vertices, loops.
pub fn meshHash(me: *const scene.Mesh) u64 {
    const counts = [5]u32{ @intCast(me.verts.len), @intCast(me.poff.len - 1), @intCast(me.loops.len), me.edges, @intCast(me.tris.len) };
    var h: u64 = 0xcbf29ce484222325;
    h = scMix(h, std.mem.sliceAsBytes(&counts));
    h = scMix(h, std.mem.sliceAsBytes(me.verts));
    return scMix(h, std.mem.sliceAsBytes(me.loops));
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// --- the builder's memory --------------------------------------------------------------

const MAP_NORES = linux.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true };

/// Lazy pages, kept in a list (the level's are given back at its end).
const VM_MAX = 256;
var vm_list: [VM_MAX][]align(4096) u8 = undefined;
var vm_n: usize = 0;
var fail = std.atomic.Value(bool).init(false);

fn rawMap(bytes: usize) ?[]align(4096) u8 {
    const n = std.mem.alignForward(usize, @max(bytes, 1), 4096);
    const rc = linux.mmap(null, n, .{ .READ = true, .WRITE = true }, MAP_NORES, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const p: [*]align(4096) u8 = @ptrFromInt(rc);
    return p[0..n];
}

fn vmap(comptime T: type, n: usize) []T {
    const empty: []T = &.{};
    if (fail.load(.monotonic)) return empty;
    if (vm_n >= VM_MAX) {
        fail.store(true, .monotonic);
        return empty;
    }
    const b = rawMap(n * @sizeOf(T) + 64) orelse {
        fail.store(true, .monotonic);
        return empty;
    };
    vm_list[vm_n] = b;
    vm_n += 1;
    const p: [*]T = @ptrCast(@alignCast(b.ptr));
    return p[0..n];
}

fn vfreeTo(k: usize) void {
    while (vm_n > k) {
        vm_n -= 1;
        _ = linux.munmap(vm_list[vm_n].ptr, vm_list[vm_n].len);
    }
}

/// A worker's scratch: made before the workers start, reset per item.
const ARENA_BYTES = 32 << 20;
const Arena = struct {
    mem: []align(4096) u8 = &.{},
    used: usize = 0,

    fn alloc(ar: *Arena, comptime T: type, n: usize) error{Full}![]T {
        const need = n * @sizeOf(T);
        const at = std.mem.alignForward(usize, ar.used, 16);
        if (at + need > ar.mem.len) return error.Full;
        ar.used = at + need;
        const p: [*]T = @ptrCast(@alignCast(ar.mem.ptr + at));
        return p[0..n];
    }
    fn zalloc(ar: *Arena, comptime T: type, n: usize) error{Full}![]T {
        const s = try ar.alloc(T, n);
        @memset(std.mem.sliceAsBytes(s), 0);
        return s;
    }
};

// --- the builder's threads -------------------------------------------------------------

const MAXT = 64;
const PFn = *const fn (lo: usize, hi: usize, ar: *Arena) void;
var pool: [MAXT]std.Thread = undefined;
var arenas: [MAXT]Arena = @splat(.{});
var pool_n: usize = 0; // besides the caller
var pj_fn: PFn = undefined;
var pj_n: usize = 0;
var pj_chunk: usize = 1;
var pj_quit = false;
var pj_nice = false;
var pj_next = std.atomic.Value(usize).init(0);
var pj_gen = std.atomic.Value(u32).init(0);
var pj_busy = std.atomic.Value(u32).init(0);

fn futexWait(ptr: *const std.atomic.Value(u32), expected: u32) void {
    _ = linux.futex_4arg(&ptr.raw, .{ .cmd = .WAIT, .private = true }, expected, null);
}
fn futexWake(ptr: *const std.atomic.Value(u32), n: u32) void {
    _ = linux.futex_3arg(&ptr.raw, .{ .cmd = .WAKE, .private = true }, n);
}

fn takeJobs(ar: *Arena) void {
    while (true) {
        const at = pj_next.fetchAdd(pj_chunk, .acq_rel);
        if (at >= pj_n) return;
        pj_fn(at, @min(at + pj_chunk, pj_n), ar);
    }
}

fn niceThread() void {
    // (the window stays first: a build takes what the frames leave)
    _ = linux.syscall3(.setpriority, 0, 0, 10);
}

fn poolWorker(id: usize) void {
    if (pj_nice) niceThread();
    var seen: u32 = 0;
    while (true) {
        var g = pj_gen.load(.acquire);
        while (g == seen) {
            futexWait(&pj_gen, seen);
            g = pj_gen.load(.acquire);
        }
        seen = g;
        if (pj_quit) return;
        takeJobs(&arenas[id]);
        if (pj_busy.fetchSub(1, .acq_rel) == 1) futexWake(&pj_busy, 1);
    }
}

fn poolStart(background: bool) bool {
    pj_quit = false;
    pj_nice = background;
    const cpus = std.Thread.getCpuCount() catch 1;
    const want = @min(@max(cpus, 1), MAXT);
    var k: usize = 0;
    while (k < want) : (k += 1) {
        if (arenas[k].mem.len == 0) arenas[k].mem = rawMap(ARENA_BYTES) orelse return k > 0;
    }
    pool_n = 0;
    k = 1;
    while (k < want) : (k += 1) {
        pool[pool_n] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, poolWorker, .{k}) catch break;
        pool_n += 1;
    }
    return true;
}

fn poolStop() void {
    pj_quit = true;
    _ = pj_gen.fetchAdd(1, .acq_rel);
    futexWake(&pj_gen, std.math.maxInt(i32));
    for (pool[0..pool_n]) |t| t.join();
    pool_n = 0;
    // (what the arenas touched goes back)
    for (&arenas) |*ar| {
        if (ar.mem.len > 0) _ = linux.munmap(ar.mem.ptr, ar.mem.len);
        ar.* = .{};
    }
}

fn pfor(n: usize, chunk: usize, f: PFn) void {
    if (n == 0) return;
    if (pool_n == 0 or n <= chunk) {
        f(0, n, &arenas[0]);
        return;
    }
    pj_fn = f;
    pj_n = n;
    pj_chunk = @max(chunk, 1);
    pj_next.store(0, .release);
    pj_busy.store(@intCast(pool_n), .release);
    _ = pj_gen.fetchAdd(1, .acq_rel);
    futexWake(&pj_gen, std.math.maxInt(i32));
    takeJobs(&arenas[0]);
    while (true) {
        const b = pj_busy.load(.acquire);
        if (b == 0) break;
        futexWait(&pj_busy, b);
    }
}

// --- the build's state --------------------------------------------------------------------

const CB = extern struct { toff: u32, nt: u32, nv: u32, grp: u32 };

var s_pos: []const [3]f32 = &.{};
var s_tri: []const [3]u32 = &.{};
var s_hash: u64 = 0;
var w_n: u32 = 0;
var w_q: [][3]i32 = &.{};
var w_nrm: [][3]f32 = &.{};
var bmin: [3]f32 = undefined;
var step: f32 = 1;
var bt: [][3]u32 = &.{};
var bt_n: u32 = 0;
var nt0: u32 = 0;
var cr: []Cluster = &.{};
var cb: []CB = &.{};
var nc: u32 = 0;
var gr: []Group = &.{};
var ng: u32 = 0;
var mem: []u32 = &.{};
var nm: u32 = 0;
var csrc: []u32 = &.{};
var nlv: u32 = 0;
var lv: [MAXLV]Level = std.mem.zeroes([MAXLV]Level);
// per level
var lo: u32 = 0;
var hi: u32 = 0;
var glo: u32 = 0;
var ghi: u32 = 0;
var be_mode: u32 = 0;
var ebn: []u32 = &.{};
var eoff: []u32 = &.{};
var eb: []u64 = &.{};
var gin: []u32 = &.{};
var gonc: []u32 = &.{};
var gont: []u32 = &.{};
var goerr: []f32 = &.{};
var ot: [][3]u32 = &.{};
var os: []u32 = &.{};
var blk_nc: []u32 = &.{};
var bnd_first: u32 = 0;
var pk_block: *Header = undefined;
var pk_ptr: [*]u8 = undefined;

// --- weld ---------------------------------------------------------------------------------

fn bdWeld() bool {
    const nv: u32 = @intCast(s_pos.len);
    var bn: [3]f32 = @splat(1.0e30);
    var bx: [3]f32 = @splat(-1.0e30);
    for (s_pos) |p| {
        for (0..3) |k| {
            bn[k] = fmin(bn[k], p[k]);
            bx[k] = fmax(bx[k], p[k]);
        }
    }
    bmin = bn;
    const ext = [3]f32{ bx[0] - bn[0], bx[1] - bn[1], bx[2] - bn[2] };
    var st = fmax(fmax(ext[0], ext[1]), ext[2]) / 1048576.0; // 2^20 steps over the largest side
    if (!(st > 0)) st = 1;
    step = st;
    const inv = 1.0 / st;
    var cap: u64 = 1024; // weld table: >= 2 slots a vertex
    while (cap < @as(u64, nv) * 2) cap += cap;
    const mask = cap - 1;
    const wt = vmap(u32, cap); // id + 1
    const keys = vmap(u64, nv); // of the welded vertices
    const remap = vmap(u32, nv);
    w_q = vmap([3]i32, nv + 8);
    if (fail.load(.monotonic)) return false;
    w_n = 0;
    for (s_pos, 0..) |p, i| {
        var q: [3]i32 = undefined;
        for (0..3) |k| q[k] = @max(rint((p[k] - bn[k]) * inv), 0); // (never below the grid)
        const key: u64 = @as(u64, @intCast(q[0])) | (@as(u64, @intCast(q[1])) << 21) | (@as(u64, @intCast(q[2])) << 42);
        var at = mix(key) & mask;
        const id: u32 = while (true) {
            const t = wt[at];
            if (t == 0) {
                const n = w_n;
                wt[at] = n + 1;
                w_n = n + 1;
                keys[n] = key;
                w_q[n] = q;
                break n;
            }
            if (keys[t - 1] == key) break t - 1;
            at = (at + 1) & mask;
        };
        remap[i] = id;
    }
    // the triangles on welded vertices
    bt = vmap([3]u32, s_tri.len + 8);
    w_nrm = vmap([3]f32, @as(usize, w_n) + 8);
    if (fail.load(.monotonic)) return false;
    var kept: u32 = 0;
    for (s_tri) |t| {
        if (t[0] >= nv or t[1] >= nv or t[2] >= nv) continue; // (out of range: skipped)
        const a = remap[t[0]];
        const b = remap[t[1]];
        const c = remap[t[2]];
        if (a == b or b == c or a == c) continue;
        bt[kept] = .{ a, b, c };
        kept += 1;
    }
    nt0 = kept;
    if (kept == 0) return false;
    // normals: the faces' (area weighted)
    for (bt[0..nt0]) |t| {
        const q0 = w_q[t[0]];
        const q1 = w_q[t[1]];
        const q2 = w_q[t[2]];
        const e1 = [3]f32{ @floatFromInt(q1[0] -% q0[0]), @floatFromInt(q1[1] -% q0[1]), @floatFromInt(q1[2] -% q0[2]) };
        const e2 = [3]f32{ @floatFromInt(q2[0] -% q0[0]), @floatFromInt(q2[1] -% q0[1]), @floatFromInt(q2[2] -% q0[2]) };
        const n = [3]f32{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        for (t) |v| {
            for (0..3) |k| w_nrm[v][k] += n[k];
        }
    }
    return true;
}

fn bdAlloc() bool {
    const worst: usize = @as(usize, nt0) * 21 + 64; // triangles / clusters over all levels
    const nb = vmap([3]u32, worst);
    if (nb.len == 0) return false;
    @memcpy(nb[0..nt0], bt[0..nt0]);
    bt = nb;
    cr = vmap(Cluster, worst);
    cb = vmap(CB, worst);
    gr = vmap(Group, worst);
    mem = vmap(u32, worst);
    csrc = vmap(u32, worst);
    nc = 0;
    ng = 0;
    nm = 0;
    nlv = 0;
    lv = std.mem.zeroes([MAXLV]Level);
    return !fail.load(.monotonic);
}

// --- level 0 ------------------------------------------------------------------------------

fn spread10(x: u32) u32 {
    var a = x & 0x3ff;
    a = (a | (a << 16)) & 0x030000ff;
    a = (a | (a << 8)) & 0x0300f00f;
    a = (a | (a << 4)) & 0x030c30c3;
    a = (a | (a << 2)) & 0x09249249;
    return a;
}

/// Stable, by 10 bits.
fn radix10(src: []const u64, dst: []u64, shift: u6, cnt: *[1024]u32) void {
    @memset(cnt, 0);
    for (src) |k| cnt[@intCast((k >> shift) & 1023)] += 1;
    var sum: u32 = 0;
    for (cnt) |*c| {
        const x = c.*;
        c.* = sum;
        sum += x;
    }
    for (src) |k| {
        const b: usize = @intCast((k >> shift) & 1023);
        dst[cnt[b]] = k;
        cnt[b] += 1;
    }
}

fn newCluster(toff: u32, size: u32) *CB {
    const c = &cb[nc];
    nc += 1;
    c.* = .{ .toff = toff, .nt = size & 0xffff, .nv = size >> 16, .grp = 0 };
    return c;
}

fn jobBlock(lo_: usize, hi_: usize, ar: *Arena) void {
    for (lo_..hi_) |b| {
        ar.used = 0;
        const at = b << 12;
        const n: u32 = @intCast(@min(@as(usize, nt0) - at, BLK));
        const k = partSet(bt[at..][0..n], ar, os[at..]) catch {
            fail.store(true, .monotonic);
            return;
        };
        blk_nc[b] = k;
    }
}

fn bdLevel0() bool {
    const n: usize = nt0;
    const keys = vmap(u64, n);
    const tmp = vmap(u64, n);
    const reord = vmap([3]u32, n);
    if (fail.load(.monotonic)) return false;
    for (bt[0..n], 0..) |t, i| { // key: the Morton code of the centroid
        var s: [3]u32 = undefined;
        for (0..3) |k| {
            const c = w_q[t[0]][k] +% w_q[t[1]][k] +% w_q[t[2]][k];
            s[k] = @as(u32, @bitCast(c)) >> 12; // 3 * 2^20 -> 10 bits
        }
        const code: u32 = (spread10(s[2]) << 2) | (spread10(s[1]) *% 2) | spread10(s[0]);
        keys[i] = (@as(u64, code) << 32) | i;
    }
    var cnt: [1024]u32 = undefined;
    radix10(keys, tmp, 32, &cnt);
    radix10(tmp, keys, 42, &cnt);
    radix10(keys, tmp, 52, &cnt);
    for (tmp, 0..) |k, i| reord[i] = bt[@as(u32, @truncate(k))];
    @memcpy(bt[0..n], reord);
    const nblk: u32 = (nt0 + BLK - 1) >> 12;
    blk_nc = vmap(u32, nblk);
    os = vmap(u32, n);
    if (fail.load(.monotonic)) return false;
    pfor(nblk, 64, jobBlock);
    if (fail.load(.monotonic)) return false;
    var toff: u32 = 0;
    for (0..nblk) |b| { // the clusters, block by block
        var slot = b << 12;
        for (0..blk_nc[b]) |_| {
            const c = newCluster(toff, os[slot]);
            toff += c.nt;
            slot += 1;
        }
    }
    bt_n = toff;
    bounds(0, nc); // their bounds; level 0 error 0
    for (cr[0..nc]) |*c| {
        c.lod = c.c;
        c.plod = c.c;
        c.err = 0;
        c.perr = @bitCast(FLT_MAX);
        c.level = 0;
    }
    lv[0] = .{ .first = 0, .n = nc, .tris = nt0, .err = 0 };
    nlv = 1;
    return true;
}

fn bounds(first: u32, end: u32) void {
    bnd_first = first;
    if (end > first) pfor(end - first, 256, jobBounds);
}

/// The clusters' bounding spheres. As the original (a register slip there adds
/// y squared twice and no z): what the DAG is built from must not change, the
/// radii are put right when the block is packed (fixRadii).
fn jobBounds(lo_: usize, hi_: usize, _: *Arena) void {
    var i = lo_ + bnd_first;
    const end = hi_ + bnd_first;
    while (i < end) : (i += 1) {
        const c = &cb[i];
        const tris = bt[c.toff..][0..c.nt];
        var mn: [3]i32 = @splat(std.math.maxInt(i32));
        var mx: [3]i32 = @splat(std.math.minInt(i32));
        for (tris) |t| {
            for (t) |v| {
                const q = w_q[v];
                for (0..3) |k| {
                    mn[k] = @min(mn[k], q[k]);
                    mx[k] = @max(mx[k], q[k]);
                }
            }
        }
        var ctr: [3]f32 = undefined;
        for (0..3) |k| ctr[k] = @as(f32, @floatFromInt(mn[k] +% mx[k])) * 0.5;
        var d2: f32 = 0;
        for (tris) |t| {
            for (t) |v| {
                const q = w_q[v];
                const x = @as(f32, @floatFromInt(q[0])) - ctr[0];
                const y = @as(f32, @floatFromInt(q[1])) - ctr[1];
                d2 = fmax(d2, x * x + y * y + y * y);
            }
        }
        const r = (@sqrt(d2) + 1) * step; // (a step of slack)
        cr[i].c = .{ ctr[0] * step + bmin[0], ctr[1] * step + bmin[1], ctr[2] * step + bmin[2], r };
    }
}

// --- partitioning -------------------------------------------------------------------------

/// The triangles on local ids 0 .. nv - 1, and local -> welded id.
const Local = struct { lt: []u32, ids: []u32, nv: u32 };

fn localize(tris: []const [3]u32, ar: *Arena) !Local {
    const n3: u32 = @intCast(tris.len * 3);
    var cap: u32 = 64; // table: >= 2 slots an id
    while (cap < n3 * 2) cap += cap;
    const tab = try ar.zalloc(u32, cap); // welded id + 1
    const loc = try ar.alloc(u32, cap); // its local id
    const lt = try ar.alloc(u32, n3 + 4);
    const ids = try ar.alloc(u32, n3 + 4);
    const mask = cap - 1;
    var nv: u32 = 0;
    for (tris, 0..) |t, ti| {
        for (t, 0..) |w, e| {
            const key = w + 1;
            var h = key *% 0x9e3779b1;
            h = (h ^ (h >> 15)) & mask;
            while (true) {
                const x = tab[h];
                if (x == 0) {
                    tab[h] = key;
                    loc[h] = nv;
                    ids[nv] = w;
                    lt[ti * 3 + e] = nv;
                    nv += 1;
                    break;
                }
                if (x == key) {
                    lt[ti * 3 + e] = loc[h];
                    break;
                }
                h = (h + 1) & mask;
            }
        }
    }
    return .{ .lt = lt, .ids = ids, .nv = nv };
}

/// The triangles reordered cluster by cluster in place; sizes[k] = triangles |
/// vertices << 16. Returns the clusters.
fn partSet(tris: [][3]u32, ar: *Arena, sizes: []u32) !u32 {
    const l = try localize(tris, ar);
    const p = try partLocal(l.lt, @intCast(tris.len), l.nv, ar, sizes);
    const out = try ar.alloc([3]u32, tris.len);
    for (p.order[0..tris.len], 0..) |t, i| {
        for (0..3) |e| out[i][e] = l.ids[l.lt[t * 3 + e]];
    }
    @memcpy(tris, out);
    return p.k;
}

const Part = struct { k: u32, order: []u32 };

/// Each cluster grows from the frontier's most cornered triangle, else the
/// first left (the input is in spatial order), over its neighbours, taking the
/// one that adds the fewest vertices, then the fewest triangles left around
/// it (the oldest on a tie), up to 128 triangles / 128 vertices.
fn partLocal(lt: []const u32, n: u32, nv: u32, ar: *Arena, sizes: []u32) !Part {
    const n3 = n * 3;
    const voff = try ar.zalloc(u32, nv + 2);
    const vlist = try ar.alloc(u32, n3 + 4);
    const adj = try ar.alloc(i32, n3 + 4);
    const used = try ar.zalloc(u8, n + 16);
    const vst = try ar.zalloc(u32, nv + 4);
    const cst = try ar.zalloc(u32, n + 4);
    const cand = try ar.alloc(u32, NCAND);
    const order = try ar.alloc(u32, n + 4);
    const cur = try ar.alloc(u32, nv + 4);
    for (lt[0..n3]) |v| voff[v + 1] += 1;
    {
        var sum: u32 = 0;
        for (0..nv) |i| {
            sum += voff[i + 1];
            voff[i + 1] = sum;
            cur[i] = voff[i];
        }
    }
    const live = try ar.alloc(u32, nv + 4);
    for (0..nv) |i| live[i] = voff[i + 1] - voff[i];
    for (lt[0..n3], 0..) |v, i| {
        vlist[cur[v]] = @intCast(i / 3);
        cur[v] += 1;
    }
    // neighbours across each edge
    for (0..n3) |i| {
        const t = i / 3;
        const nxt = if (i + 1 < t * 3 + 3) i + 1 else t * 3;
        const a = lt[i];
        const b = lt[nxt];
        adj[i] = -1;
        for (vlist[voff[a]..voff[a + 1]]) |u| {
            if (u == t) continue;
            const s = lt[u * 3 ..][0..3];
            if (s[0] == b or s[1] == b or s[2] == b) {
                adj[i] = @intCast(u);
                break;
            }
        }
    }
    // connected pieces: a cluster may go on to the next triangle when its piece
    // is used up (islands), not in a pocket
    const comp = try ar.alloc(i32, n + 4);
    @memset(comp[0..n], -1);
    const csize = try ar.zalloc(u32, n + 4);
    const stack = try ar.alloc(u32, n + 4);
    {
        var pieces: u32 = 0;
        for (0..n) |t0| {
            if (comp[t0] >= 0) continue;
            comp[t0] = @intCast(pieces);
            stack[0] = @intCast(t0);
            var sp: u32 = 1;
            while (sp > 0) {
                sp -= 1;
                const t = stack[sp];
                csize[pieces] += 1;
                for (adj[t * 3 ..][0..3]) |e| {
                    if (e >= 0 and comp[@intCast(e)] < 0) {
                        comp[@intCast(e)] = @intCast(pieces);
                        stack[sp] = @intCast(e);
                        sp += 1;
                    }
                }
            }
            pieces += 1;
        }
    }
    var st = PartState{ .lt = lt, .adj = adj, .used = used, .vst = vst, .cst = cst, .cand = cand, .order = order, .live = live, .comp = comp, .csize = csize };
    var seed: u32 = 0;
    var fseed: i32 = -1;
    while (true) {
        var start: u32 = undefined;
        if (fseed >= 0) {
            start = @intCast(fseed);
        } else {
            while (seed < n and used[seed] != 0) seed += 1;
            if (seed >= n) break;
            start = seed;
        }
        st.ntri = 0;
        st.nvert = 0;
        st.ncand = 0;
        st.add(start);
        while (st.ntri < CL_TRIS) {
            const stamp = st.k + 1;
            var best: i32 = -1;
            var score: u32 = 0x7fffffff;
            var w: u32 = 0; // (kept in order)
            for (cand[0..st.ncand]) |t| {
                if (used[t] != 0) continue;
                cand[w] = t;
                w += 1;
                var adds: u32 = 0; // the vertices it adds, and how many
                var around: u32 = 0; // triangles its vertices have left
                for (lt[t * 3 ..][0..3]) |v| {
                    around += live[v];
                    if (vst[v] != stamp) adds += 1;
                }
                if (st.nvert + adds > CL_VERTS) continue;
                const s = (adds << 16) | @min(around, 0xffff);
                if (s < score) {
                    score = s;
                    best = @intCast(t);
                }
            }
            st.ncand = w;
            if (best < 0) {
                const last = order[st.out - 1];
                if (csize[@intCast(comp[last])] != 0) break; // its piece has more: a pocket
                if (st.ntri >= CL_TRIS / 2) break; // nothing next to it, still
                if (st.nvert > CL_VERTS - 3) break; //   small (an island): the next
                var e = seed; //   triangle left, in order
                while (e < n and used[e] != 0) e += 1;
                if (e >= n) break;
                seed = e;
                best = @intCast(e);
            }
            st.add(@intCast(best));
        }
        sizes[st.k] = (st.nvert << 16) | st.ntri;
        st.k += 1;
        // the next seed: the frontier triangle with the fewest triangles left
        // around it (a corner, a pocket)
        fseed = -1;
        var least: u32 = 0x7fffffff;
        for (cand[0..st.ncand]) |t| {
            if (used[t] != 0) continue;
            const c = lt[t * 3 ..][0..3];
            const s = live[c[0]] + live[c[1]] + live[c[2]];
            if (s < least) {
                least = s;
                fseed = @intCast(t);
            }
        }
    }
    return .{ .k = st.k, .order = order };
}

const PartState = struct {
    lt: []const u32,
    adj: []const i32,
    used: []u8,
    vst: []u32,
    cst: []u32,
    cand: []u32,
    order: []u32,
    live: []u32,
    comp: []const i32,
    csize: []u32,
    out: u32 = 0,
    k: u32 = 0,
    ntri: u32 = 0,
    nvert: u32 = 0,
    ncand: u32 = 0,

    fn add(s: *PartState, t: u32) void {
        s.used[t] = 1;
        s.csize[@intCast(s.comp[t])] -= 1;
        s.order[s.out] = t;
        s.out += 1;
        s.ntri += 1;
        const stamp = s.k + 1;
        for (0..3) |e| {
            const v = s.lt[t * 3 + e];
            s.live[v] -= 1;
            if (s.vst[v] != stamp) {
                s.vst[v] = stamp;
                s.nvert += 1;
            }
            const nb = s.adj[t * 3 + e]; // its neighbours become candidates
            if (nb < 0) continue;
            const u: u32 = @intCast(nb);
            if (s.used[u] != 0 or s.cst[u] == stamp or s.ncand >= NCAND) continue;
            s.cst[u] = stamp;
            s.cand[s.ncand] = u;
            s.ncand += 1;
        }
    }
};

// --- levels: group, simplify, split --------------------------------------------------------

const BE_K: u64 = 0x9e3779b97f4a7c15;

fn edgeKey(t: []const u32, i: usize) u64 {
    const tri = i / 3;
    const nxt = if (i + 1 < tri * 3 + 3) i + 1 else tri * 3;
    return (@as(u64, t[i] + 1) << 32) | (t[nxt] + 1);
}
fn twin(k: u64) u64 {
    return (k >> 32) | (k << 32);
}

/// A cluster's boundary edges (directed edges whose twin is not in it):
/// counted (be_mode 0) or written as min << 32 | max (1).
fn jobBedge(lo_: usize, hi_: usize, _: *Arena) void {
    var tab: [1024]u64 = undefined;
    for (lo_..hi_) |ci| {
        @memset(&tab, 0);
        const c = &cb[lo + ci];
        const tris: []const u32 = @as([*]const u32, @ptrCast(&bt[c.toff]))[0 .. c.nt * 3];
        for (0..tris.len) |i| {
            const key = edgeKey(tris, i);
            var h: usize = @intCast((key *% BE_K) >> 54);
            while (tab[h] != 0 and tab[h] != key) h = (h + 1) & 1023;
            tab[h] = key;
        }
        var nb: u32 = 0;
        for (0..tris.len) |i| {
            const key = twin(edgeKey(tris, i));
            var h: usize = @intCast((key *% BE_K) >> 54);
            while (tab[h] != 0 and tab[h] != key) h = (h + 1) & 1023;
            if (tab[h] == key) continue;
            if (be_mode != 0) {
                const a = @as(u32, @truncate(key)) - 1;
                const b = @as(u32, @truncate(key >> 32)) - 1;
                eb[eoff[ci] + nb] = (@as(u64, @min(a, b)) << 32) | @max(a, b);
            }
            nb += 1;
        }
        if (be_mode == 0) ebn[ci] = nb;
    }
}

const GroupBuild = struct {
    off: []const u32,
    nbs: []const u32,
    grp: []u32, // group + 1 per cluster
    gtr: []u32, // triangles per group
    ncand: u32 = 0,
    bg: u32 = 0,
    bn: u32 = 0,
    bmem: [64]u32 = undefined,
    cid: [512]u32 = undefined,
    csc: [512]u32 = undefined,

    fn add(g: *GroupBuild, ci: u32) void {
        g.grp[ci] = g.bg + 1;
        if (g.bn < 64) g.bmem[g.bn] = ci;
        g.bn += 1;
        g.gtr[g.bg] += cb[lo + ci].nt;
        // (who made it: edges to clusters another group made count more, so groups
        // straddle the old borders and those get simplified)
        const src = csrc[lo + ci];
        for (g.nbs[g.off[ci]..g.off[ci + 1]]) |n| {
            if (g.grp[n] != 0) continue;
            const w: u32 = if (csrc[lo + n] == src) 1 else 4;
            var k: u32 = 0;
            while (k < g.ncand and g.cid[k] != n) k += 1;
            if (k < g.ncand) {
                g.csc[k] += w;
            } else if (g.ncand < 512) {
                g.cid[g.ncand] = n;
                g.csc[g.ncand] = w;
                g.ncand += 1;
            }
        }
    }
};

/// Groups of the level's clusters: from the first cluster left, add the neighbour
/// sharing the most edges with the group, up to GMAXN clusters / GTRIS triangles;
/// a group still small joins the neighbouring group it shares the most edges with
/// (up to GTMAX). Then the group records and member lists.
fn bdGroup(off: []const u32, nbs: []const u32, grp: []u32, ncl: u32) void {
    const gtr = vmap(u32, ncl + 2);
    if (fail.load(.monotonic)) return;
    var g = GroupBuild{ .off = off, .nbs = nbs, .grp = grp, .gtr = gtr };
    var gn: u32 = 0;
    for (0..ncl) |c0| {
        if (grp[c0] != 0) continue;
        g.bg = gn;
        gn += 1;
        g.bn = 0;
        gtr[g.bg] = 0;
        g.ncand = 0;
        g.add(@intCast(c0));
        while (g.bn < GMAXN) {
            const have = gtr[g.bg];
            var best: i32 = -1;
            var score: u32 = 0;
            for (0..g.ncand) |k| {
                const c = g.cid[k];
                if (grp[c] != 0) continue;
                if (g.csc[k] <= score) continue;
                if (cb[lo + c].nt + have > GTRIS) continue; // (room for its triangles?)
                score = g.csc[k];
                best = @intCast(c);
            }
            if (best < 0) break;
            g.add(@intCast(best));
        }
        // small: into a neighbouring group
        if (gtr[g.bg] >= GTSMALL) continue;
        var nb: u32 = 0;
        for (g.bmem[0..g.bn]) |mb| {
            for (nbs[off[mb]..off[mb + 1]]) |n| {
                const x = grp[n];
                if (x == 0 or x - 1 == g.bg) continue;
                var k: u32 = 0;
                while (k < nb and g.cid[k] != x - 1) k += 1;
                if (k < nb) {
                    g.csc[k] += 1;
                } else if (nb < 512) {
                    g.cid[nb] = x - 1;
                    g.csc[nb] = 1;
                    nb += 1;
                }
            }
        }
        const have = gtr[g.bg];
        var best: i32 = -1;
        var score: u32 = 0;
        for (0..nb) |k| {
            const o = g.cid[k];
            if (g.csc[k] <= score) continue;
            if (gtr[o] + have > GTMAX) continue;
            score = g.csc[k];
            best = @intCast(o);
        }
        if (best < 0) {
            if (nb != 0 or g.bg == 0) continue; // no group next to it (islands):
            const o = g.bg - 1; //   the one made before, if it has room
            if (gtr[o] + have > GTMAX) continue;
            best = @intCast(o);
        }
        gtr[@intCast(best)] += have; // merged: the group was the last made
        for (g.bmem[0..g.bn]) |mb| grp[mb] = @intCast(best + 1);
        gn -= 1;
    }
    // the records and member lists
    for (gr[ng..][0..gn]) |*r| {
        r.nmem = 0;
        r.npar = 0;
        r.level = nlv - 1;
    }
    for (grp[0..ncl]) |x| gr[ng + x - 1].nmem += 1;
    var first = nm;
    for (gr[ng..][0..gn]) |*r| {
        r.mem = first;
        first += r.nmem;
    }
    nm = first;
    for (0..ncl) |c| { // (npar counts, for now)
        const gi = ng + grp[c] - 1;
        const r = &gr[gi];
        mem[r.mem + r.npar] = lo + @as(u32, @intCast(c));
        r.npar += 1;
        cb[lo + c].grp = gi + 1;
    }
    ng += gn;
}

fn bdLevel() bool {
    const mark = vm_n;
    const ng0 = ng;
    const nm0 = nm;
    const stop = struct {
        fn f(mk: usize, g0: u32, m0: u32) bool {
            ng = g0; // (groups made for nothing: gone)
            nm = m0;
            vfreeTo(mk);
            return false;
        }
    }.f;
    if (nlv >= MAXLV) return stop(mark, ng0, nm0);
    const prev = lv[nlv - 1];
    lo = prev.first;
    const ncl = prev.n;
    hi = lo + ncl;
    if (ncl <= 1) return stop(mark, ng0, nm0);
    // boundary edges of every cluster (counted, then written)
    ebn = vmap(u32, ncl + 2);
    eoff = vmap(u32, ncl + 2);
    if (fail.load(.monotonic)) return stop(mark, ng0, nm0);
    be_mode = 0;
    pfor(ncl, 64, jobBedge);
    var tot: u32 = 0;
    for (0..ncl) |i| {
        eoff[i] = tot;
        tot += ebn[i];
    }
    eoff[ncl] = tot;
    eb = vmap(u64, tot + 8);
    if (fail.load(.monotonic)) return stop(mark, ng0, nm0);
    be_mode = 1;
    pfor(ncl, 64, jobBedge);
    // shared edges -> pairs of neighbouring clusters
    var cap: u32 = 1024;
    while (cap < tot *| 2) cap += cap;
    const keys = vmap(u64, cap);
    const vals = vmap(u32, cap);
    const pairs = vmap([2]u32, tot + 8);
    if (fail.load(.monotonic)) return stop(mark, ng0, nm0);
    const mask = cap - 1;
    var np: u32 = 0;
    for (0..ncl) |c| {
        for (eb[eoff[c]..eoff[c + 1]]) |key| {
            var h: u32 = @as(u32, @truncate((key *% BE_K) >> 32)) & mask;
            while (true) {
                const x = keys[h];
                if (x == 0) {
                    keys[h] = key;
                    vals[h] = @intCast(c);
                    break;
                }
                if (x == key) {
                    if (vals[h] != c) {
                        pairs[np] = .{ vals[h], @intCast(c) };
                        np += 1;
                    }
                    break;
                }
                h = (h + 1) & mask;
            }
        }
    }
    // neighbour lists (a neighbour once per shared edge: the weight)
    const deg = vmap(u32, ncl + 2);
    const nbs = vmap(u32, @as(usize, np) * 2 + 4);
    const grp = vmap(u32, ncl + 2); // (first a cursor, then group + 1)
    if (fail.load(.monotonic)) return stop(mark, ng0, nm0);
    for (pairs[0..np]) |p| {
        deg[p[0] + 1] += 1;
        deg[p[1] + 1] += 1;
    }
    for (0..ncl) |i| {
        grp[i] = deg[i];
        deg[i + 1] += deg[i];
    }
    for (pairs[0..np]) |p| {
        nbs[grp[p[0]]] = p[1];
        grp[p[0]] += 1;
        nbs[grp[p[1]]] = p[0];
        grp[p[1]] += 1;
    }
    @memset(grp[0..ncl], 0);
    glo = ng;
    bdGroup(deg, nbs, grp, ncl);
    ghi = ng;
    if (fail.load(.monotonic)) return stop(mark, ng0, nm0);
    // simplify the groups (in parallel)
    const ngl = ghi - glo;
    gin = vmap(u32, ngl + 2);
    gonc = vmap(u32, ngl + 2);
    gont = vmap(u32, ngl + 2);
    goerr = vmap(f32, ngl + 2);
    if (fail.load(.monotonic)) return stop(mark, ng0, nm0);
    var at: u32 = 0;
    for (0..ngl) |g| {
        gin[g] = at;
        const r = &gr[glo + g];
        for (mem[r.mem..][0..r.nmem]) |c| at += cb[c].nt;
    }
    gin[ngl] = at;
    ot = vmap([3]u32, @as(usize, at) + 8);
    os = vmap(u32, @as(usize, at) + 16);
    if (fail.load(.monotonic)) return stop(mark, ng0, nm0);
    pfor(ngl, 1, jobGroup);
    if (fail.load(.monotonic)) return stop(mark, ng0, nm0);
    // the new clusters, group by group
    const newlo = nc;
    var newt: u32 = 0;
    var maxe: f32 = 0;
    for (0..ngl) |g| {
        maxe = fmax(finishGroup(@intCast(g)), maxe);
        newt += gont[g];
    }
    bounds(newlo, nc);
    lv[nlv] = .{ .first = newlo, .n = nc - newlo, .tris = newt, .err = maxe };
    nlv += 1;
    vfreeTo(mark);
    const nw = lv[nlv - 1];
    if (nw.n <= 1) return false; // one cluster: the root
    // a level that hardly shrinks: done
    if (@as(f32, @floatFromInt(nw.tris)) > @as(f32, @floatFromInt(lv[nlv - 2].tris)) * 0.95) return false;
    return true;
}

fn jobGroup(lo_: usize, hi_: usize, ar: *Arena) void {
    for (lo_..hi_) |g| {
        ar.used = 0;
        grpWork(@intCast(g), ar) catch fail.store(true, .monotonic);
    }
}

fn grpWork(gi: u32, ar: *Arena) !void {
    const r = &gr[glo + gi];
    const n = gin[gi + 1] - gin[gi];
    gonc[gi] = 0;
    gont[gi] = 0;
    goerr[gi] = 0;
    if (n == 0) return;
    const gl = try ar.alloc([3]u32, n);
    var w: u32 = 0;
    for (mem[r.mem..][0..r.nmem]) |c| { // gather
        const b = &cb[c];
        @memcpy(gl[w..][0..b.nt], bt[b.toff..][0..b.nt]);
        w += b.nt;
    }
    const l = try localize(gl, ar);
    const pos = try ar.alloc([3]f64, l.nv + 2); // (doubles, from the first)
    const lock = try ar.zalloc(u8, l.nv + 16);
    const q0 = w_q[l.ids[0]];
    for (0..l.nv) |i| {
        const q = w_q[l.ids[i]];
        for (0..3) |k| pos[i][k] = @floatFromInt(q[k] -% q0[k]);
    }
    try lockBorder(l.lt[0 .. n * 3], lock, ar); // the group's border
    var err: f64 = 0;
    const kept = try simplify(l.lt, n, l.nv, pos, lock, ar, &err);
    // split
    const p = try partLocal(l.lt, kept, l.nv, ar, os[gin[gi]..]);
    // the triangles, cluster by cluster
    const out = ot[gin[gi]..];
    for (p.order[0..kept], 0..) |t, i| {
        for (0..3) |e| out[i][e] = l.ids[l.lt[t * 3 + e]];
    }
    gonc[gi] = p.k;
    gont[gi] = kept;
    goerr[gi] = @as(f32, @floatCast(@sqrt(err))) * step; // grid steps -> world
}

/// Both ends of every directed edge whose twin is not in the group are locked.
fn lockBorder(lt: []const u32, lock: []u8, ar: *Arena) !void {
    const n3: u32 = @intCast(lt.len);
    var cap: u32 = 64;
    while (cap < n3 * 2) cap += cap;
    const tab = try ar.zalloc(u64, cap);
    const mask = cap - 1;
    for (0..n3) |i| {
        const key = edgeKey(lt, i);
        var h: u32 = @as(u32, @truncate((key *% BE_K) >> 32)) & mask;
        while (tab[h] != 0 and tab[h] != key) h = (h + 1) & mask;
        tab[h] = key;
    }
    for (0..n3) |i| {
        const key = twin(edgeKey(lt, i));
        var h: u32 = @as(u32, @truncate((key *% BE_K) >> 32)) & mask;
        while (tab[h] != 0 and tab[h] != key) h = (h + 1) & mask;
        if (tab[h] == key) continue;
        lock[@as(u32, @truncate(key)) - 1] = 1; // no twin: lock both ends
        lock[@as(u32, @truncate(key >> 32)) - 1] = 1;
    }
}

// --- simplification: quadric error, half-edge collapses in passes (each pass takes
// --- the cheapest collapses whose ends nothing else moved this pass)

const Q = [12]f64;

fn qeval(q: *const Q, p: [3]f64) f64 {
    const x = p[0];
    const y = p[1];
    const z = p[2];
    var a = q[0] * x;
    var b = q[1] * y;
    b = b + b;
    a += b;
    b = q[2] * z;
    b = b + b;
    a += b;
    b = q[3];
    b = b + b;
    a += b;
    a *= x;
    b = q[4] * y;
    var c = q[5] * z;
    c = c + c;
    b += c;
    c = q[6];
    c = c + c;
    b += c;
    b *= y;
    a += b;
    b = q[7] * z;
    c = q[8];
    c = c + c;
    b += c;
    b *= z;
    a += b;
    a += q[9];
    return a;
}

fn crossD(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn subD(a: [3]f64, b: [3]f64) [3]f64 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

const Simp = struct {
    lt: []u32,
    pos: []const [3]f64,
    lock: []const u8,
    q: []Q,
    alive: []u8,
    voff: []u32,
    vlist: []u32,
    nu: []u32,
    nvl: []u32,

    fn plane(s: *Simp, t: u32) void {
        const c = s.lt[t * 3 ..][0..3];
        const p0 = s.pos[c[0]];
        const n = crossD(subD(s.pos[c[1]], p0), subD(s.pos[c[2]], p0));
        const l2 = n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
        if (!(l2 > 0)) return; // degenerate: no plane
        const len = @sqrt(l2);
        const a = n[0] / len;
        const b = n[1] / len;
        const cc = n[2] / len;
        const area = len * 0.5; // the plane's weight
        const d = 0.0 - (a * p0[0] + b * p0[1] + cc * p0[2]);
        const pl = Q{ a * a * area, a * b * area, a * cc * area, a * d * area, b * b * area, b * cc * area, b * d * area, cc * cc * area, cc * d * area, d * d * area, area, 0 };
        for (c) |v| {
            for (0..12) |k| s.q[v][k] += pl[k];
        }
    }

    /// The collapse u -> v as a key: cost << 32 | v << 16 | u.
    fn cand(s: *const Simp, u: u32, v: u32) u64 {
        const pv = s.pos[v];
        const area = s.q[u][10] + s.q[v][10];
        var c = qeval(&s.q[v], pv) + qeval(&s.q[u], pv);
        if (area > 0) c /= area; // mean squared distance
        c = if (c > 0) c else 0;
        const cf: f32 = @floatCast(c);
        return (@as(u64, @as(u32, @bitCast(cf))) << 32) | (v << 16) | u;
    }

    fn setAdd(set: []u32, n: *u32, x: u32) bool {
        for (set[0..n.*]) |e| {
            if (e == x) return true;
        }
        if (n.* >= 256) return false;
        set[n.*] = x;
        n.* += 1;
        return true;
    }

    fn triNormal(s: *const Simp, c: []const u32, u: u32, v: u32, moved: bool) [3]f64 {
        var p: [3][3]f64 = undefined;
        for (0..3) |k| {
            const x = if (moved and c[k] == u) v else c[k];
            p[k] = s.pos[x];
        }
        return crossD(subD(p[1], p[0]), subD(p[2], p[0]));
    }

    /// The triangle it becomes is v's already, or has all three corners on the
    /// group's border (it could be one next door): either folds a pillow.
    fn dup(s: *const Simp, c: []const u32, u: u32, v: u32) bool {
        var p: u32 = 0;
        var q: u32 = 0;
        var have = false;
        for (c) |x| {
            if (x == u) continue;
            if (!have) {
                p = x;
                have = true;
            } else q = x;
        }
        if (s.lock[v] != 0 and s.lock[p] != 0 and s.lock[q] != 0) return true;
        for (s.vlist[s.voff[v]..s.voff[v + 1]]) |t| {
            if (s.alive[t] == 0) continue;
            const e = s.lt[t * 3 ..][0..3];
            if ((e[0] == p or e[1] == p or e[2] == p) and (e[0] == q or e[1] == q or e[2] == q)) return true;
        }
        return false;
    }

    /// The collapse keeps the surface a manifold (link condition) and turns no
    /// triangle over.
    fn valid(s: *const Simp, u: u32, v: u32) bool {
        var nnu: u32 = 0;
        var shared: u32 = 0;
        for (s.vlist[s.voff[u]..s.voff[u + 1]]) |t| { // u's neighbours; triangles with v
            if (s.alive[t] == 0) continue;
            for (s.lt[t * 3 ..][0..3]) |x| {
                if (x == v) shared += 1;
                if (x == u) continue;
                if (!setAdd(s.nu, &nnu, x)) return false;
            }
        }
        if (shared == 0) return false;
        var nnv: u32 = 0;
        for (s.vlist[s.voff[v]..s.voff[v + 1]]) |t| { // v's neighbours
            if (s.alive[t] == 0) continue;
            for (s.lt[t * 3 ..][0..3]) |x| {
                if (x == v) continue;
                if (!setAdd(s.nvl, &nnv, x)) return false;
            }
        }
        var common: u32 = 0; // (not u, v)
        for (s.nu[0..nnu]) |x| {
            if (x == v) continue;
            for (s.nvl[0..nnv]) |y| {
                if (y == x) {
                    common += 1;
                    break;
                }
            }
        }
        if (common != shared) return false;
        for (s.vlist[s.voff[u]..s.voff[u + 1]]) |t| { // no triangle of u turns over
            if (s.alive[t] == 0) continue;
            const c = s.lt[t * 3 ..][0..3];
            if (c[0] == v or c[1] == v or c[2] == v) continue;
            if (s.dup(c, u, v)) return false;
            const a = s.triNormal(c, u, v, false);
            const b = s.triNormal(c, u, v, true);
            if (!(b[0] * a[0] + b[1] * a[1] + b[2] * a[2] > 0)) return false;
        }
        return true;
    }
};

/// Returns the triangles kept (packed to the front); err = the largest collapse
/// cost (squared grid steps).
fn simplify(lt: []u32, n: u32, nv: u32, pos: []const [3]f64, lock: []const u8, ar: *Arena, err: *f64) !u32 {
    var nalive = n;
    const target = n >> 1;
    var pass: u32 = 0;
    const q = try ar.zalloc(Q, nv + 1);
    const alive = try ar.alloc(u8, n + 16);
    @memset(alive[0..n], 1);
    const touch = try ar.zalloc(u32, nv + 4);
    const keys = try ar.alloc(u64, @as(usize, n) * 6 + 2);
    const tmp = try ar.alloc(u64, @as(usize, n) * 6 + 2);
    const cnt: *[1024]u32 = @ptrCast(try ar.alloc(u32, 1024));
    const nu = try ar.alloc(u32, 256);
    const nvl = try ar.alloc(u32, 256);
    const voff = try ar.alloc(u32, nv + 4);
    const cur = try ar.alloc(u32, nv + 4);
    const vlist = try ar.alloc(u32, @as(usize, n) * 3 + 4);
    var s = Simp{ .lt = lt, .pos = pos, .lock = lock, .q = q, .alive = alive, .voff = voff, .vlist = vlist, .nu = nu, .nvl = nvl };
    for (0..n) |t| s.plane(@intCast(t)); // the planes' quadrics
    while (nalive > target and pass < 32) {
        pass += 1;
        var any: u32 = 0;
        // vertex -> live triangles
        @memset(voff[0 .. nv + 1], 0);
        for (0..n) |t| {
            if (alive[t] == 0) continue;
            for (lt[t * 3 ..][0..3]) |v| voff[v + 1] += 1;
        }
        var sum: u32 = 0;
        for (0..nv) |i| {
            cur[i] = voff[i];
            sum += voff[i + 1];
            voff[i + 1] = sum;
        }
        for (0..n) |t| {
            if (alive[t] == 0) continue;
            for (lt[t * 3 ..][0..3]) |v| {
                vlist[cur[v]] = @intCast(t);
                cur[v] += 1;
            }
        }
        // candidate collapses, both ways along every live edge
        var nk: usize = 0;
        for (0..n * 3) |i| {
            if (alive[i / 3] == 0) continue;
            const key = edgeKey(lt[0 .. n * 3], i);
            const a: u32 = @as(u32, @truncate(key >> 32)) - 1;
            const b: u32 = @as(u32, @truncate(key)) - 1;
            if (lock[a] == 0) {
                keys[nk] = s.cand(a, b);
                nk += 1;
            }
            if (lock[b] == 0) {
                keys[nk] = s.cand(b, a);
                nk += 1;
            }
        }
        radix10(keys[0..nk], tmp, 32, cnt);
        radix10(tmp[0..nk], keys, 42, cnt);
        radix10(keys[0..nk], tmp, 52, cnt);
        radix10(tmp[0..nk], keys, 62, cnt);
        // cheapest first
        for (keys[0..nk]) |k| {
            if (nalive <= target) break;
            const u: u32 = @as(u16, @truncate(k));
            const v: u32 = @as(u16, @truncate(k >> 16));
            if (touch[u] == pass or touch[v] == pass) continue;
            if (!s.valid(u, v)) continue;
            // collapse u into v
            for (vlist[voff[u]..voff[u + 1]]) |t| {
                if (alive[t] == 0) continue;
                const c = lt[t * 3 ..][0..3];
                if (c[0] == v or c[1] == v or c[2] == v) {
                    alive[t] = 0; // has the edge: gone
                    nalive -= 1;
                    continue;
                }
                for (c) |*x| {
                    if (x.* == u) x.* = v; // keeps: u -> v
                }
            }
            for (0..12) |e| q[v][e] = q[u][e] + q[v][e];
            const cost: f32 = @bitCast(@as(u32, @truncate(k >> 32)));
            const cd: f64 = cost;
            err.* = if (cd > err.*) cd else err.*;
            touch[u] = pass;
            touch[v] = pass;
            any += 1;
        }
        // another pass, unless this one did little (2% of what is left)
        if (any *% 50 < nalive) break;
    }
    var w: u32 = 0; // pack the live triangles
    for (0..n) |t| {
        if (alive[t] == 0) continue;
        lt[w * 3] = lt[t * 3];
        lt[w * 3 + 1] = lt[t * 3 + 1];
        lt[w * 3 + 2] = lt[t * 3 + 2];
        w += 1;
    }
    return w;
}

/// The group's error (its simplification's + its members' largest) and LOD sphere
/// (holding its members'), given to its members as their parents' and to the
/// clusters it made, which are appended (level nlv).
fn finishGroup(gi: u32) f32 {
    const r = &gr[glo + gi];
    const mb = mem[r.mem..][0..r.nmem];
    var maxe: f32 = 0;
    var bn: [3]f32 = @splat(1.0e30);
    var bx: [3]f32 = @splat(-1.0e30);
    for (mb) |c| {
        const k = &cr[c];
        maxe = fmax(maxe, k.err);
        for (0..3) |a| {
            bn[a] = fmin(bn[a], k.lod[a] - k.lod[3]);
            bx[a] = fmax(bx[a], k.lod[a] + k.lod[3]);
        }
    }
    const ctr = [3]f32{ (bn[0] + bx[0]) * 0.5, (bn[1] + bx[1]) * 0.5, (bn[2] + bx[2]) * 0.5 };
    var rad: f32 = 0; // holds every member's sphere
    for (mb) |c| {
        const l = cr[c].lod;
        const d = [3]f32{ l[0] - ctr[0], l[1] - ctr[1], l[2] - ctr[2] };
        rad = fmax(rad, @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) + l[3]);
    }
    rad = rad * 1.00001 + 1.0e-6;
    const sph = [4]f32{ ctr[0], ctr[1], ctr[2], rad };
    const e = goerr[gi] + maxe;
    r.err = e;
    r.lod = sph;
    for (mb) |c| { // the members' parent
        cr[c].perr = e;
        cr[c].plod = sph;
    }
    r.par = nc; // the clusters it made
    r.npar = gonc[gi];
    var slot = gin[gi];
    var tr = slot;
    for (0..gonc[gi]) |_| {
        const c = newCluster(bt_n, os[slot]);
        @memcpy(bt[bt_n..][0..c.nt], ot[tr..][0..c.nt]);
        bt_n += c.nt;
        tr += c.nt;
        const k = &cr[nc - 1];
        k.lod = sph;
        k.plod = sph;
        k.err = e;
        k.perr = @bitCast(FLT_MAX);
        k.level = @intCast(nlv);
        csrc[nc - 1] = glo + gi + 1; // (made by this group)
        slot += 1;
    }
    return e;
}

// --- packing the block ------------------------------------------------------------------------

fn octStore(n: [3]f32, out: *u32) void {
    const sum = @abs(n[1]) + @abs(n[0]) + @abs(n[2]);
    if (!(sum > 0)) {
        out.* = 0x7fff0000; // (no normal: +z)
        return;
    }
    var x = n[0] / sum;
    var y = n[1] / sum;
    const z = n[2] / sum;
    if (!(z >= 0)) { // lower half: folded
        const sx: u32 = @as(u32, @bitCast(x)) & 0x80000000;
        const sy: u32 = @as(u32, @bitCast(y)) & 0x80000000;
        const fx = 1.0 - @abs(y);
        const fy = 1.0 - @abs(x);
        x = @bitCast(@as(u32, @bitCast(fx)) | sx);
        y = @bitCast(@as(u32, @bitCast(fy)) | sy);
    }
    const ix = rint(x * 32767.0);
    const iy = rint(y * 32767.0);
    out.* = (@as(u32, @bitCast(ix)) & 0xffff) | (@as(u32, @bitCast(iy)) << 16);
}

pub fn octLoad(w: u32) [3]f32 {
    const ix: i16 = @bitCast(@as(u16, @truncate(w)));
    const iy: i16 = @bitCast(@as(u16, @truncate(w >> 16)));
    var x = @as(f32, @floatFromInt(ix)) / 32767.0;
    var y = @as(f32, @floatFromInt(iy)) / 32767.0;
    const z = 1.0 - @abs(x) - @abs(y);
    if (z < 0) {
        const ox = x;
        x = std.math.copysign(1.0 - @abs(y), ox);
        y = std.math.copysign(1.0 - @abs(ox), y);
    }
    return .{ x, y, z };
}

/// The clusters' data: vertices (grid x y z, octahedral normal) in first-use
/// order, then the triangles (u8 x 3).
fn jobPack(lo_: usize, hi_: usize, _: *Arena) void {
    const blk: [*]u8 = pk_ptr;
    const clus: [*]Cluster = @ptrCast(@alignCast(blk + VH_SZ));
    const odata = pk_block.odata;
    var tab: [256]u32 = undefined;
    var idx: [256]u8 = undefined;
    for (lo_..hi_) |ci| {
        @memset(&tab, 0);
        const c = &clus[ci];
        const vout: [*]u8 = blk + odata + @as(u64, c.data) * 16;
        const tout: [*]u8 = vout + @as(usize, c.nv) * 16;
        const tris = bt[cb[ci].toff..][0..cb[ci].nt];
        var nv: u32 = 0;
        var e: usize = 0;
        for (tris) |t| {
            for (t) |w| {
                const key = w + 1;
                var h: u32 = (key *% 0x9e3779b1) >> 24;
                while (tab[h] != 0 and tab[h] != key) h = (h + 1) & 255;
                if (tab[h] == 0) {
                    tab[h] = key;
                    idx[h] = @intCast(nv);
                    const vo: *align(1) [4]u32 = @ptrCast(vout + @as(usize, nv) * 16);
                    const q = w_q[w];
                    vo[0] = @bitCast(q[0]);
                    vo[1] = @bitCast(q[1]);
                    vo[2] = @bitCast(q[2]);
                    var wn: u32 = undefined;
                    octStore(w_nrm[w], &wn);
                    vo[3] = wn;
                    nv += 1;
                }
                tout[e] = idx[h];
                e += 1;
            }
        }
    }
}

fn bdPack() ?[]align(4096) u8 {
    var d: u32 = 0;
    var ttri: u32 = 0;
    for (cr[0..nc], cb[0..nc]) |*c, *b| {
        c.data = d;
        c.nv = @intCast(b.nv);
        c.nt = @intCast(b.nt);
        ttri += b.nt;
        d += (b.nv * 16 + ((b.nt * 3 + 15) & ~@as(u32, 15))) >> 4;
    }
    const dbytes: u64 = @as(u64, d) << 4;
    const cl_b: u64 = @as(u64, nc) * 64;
    const gr_b: u64 = @as(u64, ng) * 48;
    const mem_b: u64 = @as(u64, nm) * 4;
    const odata: u64 = (cl_b + gr_b + VH_SZ + 4095 + mem_b) & ~@as(u64, 4095);
    const bytes: u64 = (odata + dbytes + 4095) & ~@as(u64, 4095);
    const rc = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const p: [*]align(4096) u8 = @ptrFromInt(rc);
    const h: *Header = @ptrCast(p);
    h.magic = MAGIC;
    h.ver = VERSION;
    h.refs = 1;
    h.ncl = nc;
    h.ngr = ng;
    h.nlv = nlv;
    h.stri = nt0;
    h.svert = w_n;
    h.bmin = bmin;
    h.step = step;
    h.hash = s_hash;
    h.ttri = ttri;
    h.nmem = nm;
    h.ocl = VH_SZ;
    h.ogr = cl_b + VH_SZ;
    h.omem = cl_b + VH_SZ + gr_b;
    h.odata = odata;
    h.dbytes = dbytes;
    h.bytes = bytes;
    h.lv = lv;
    @memcpy(p[VH_SZ..][0..cl_b], std.mem.sliceAsBytes(cr[0..nc]));
    @memcpy(p[VH_SZ + cl_b..][0..gr_b], std.mem.sliceAsBytes(gr[0..ng]));
    @memcpy(p[VH_SZ + cl_b + gr_b..][0..mem_b], std.mem.sliceAsBytes(mem[0..nm]));
    var roots: u32 = 0; // roots, the largest error
    var rerr: f32 = 0;
    for (cr[0..nc]) |*c| {
        rerr = fmax(rerr, c.err);
        if (@as(u32, @bitCast(c.perr)) == FLT_MAX) roots += 1;
    }
    h.roots = roots;
    h.rerr = rerr;
    pk_block = h;
    pk_ptr = p;
    pfor(nc, 64, jobPack);
    pfor(nc, 256, jobRadii);
    h.fixed = FIXED_MARK;
    return p[0..bytes];
}

fn jobRadii(lo_: usize, hi_: usize, _: *Arena) void {
    const blk: [*]u8 = pk_ptr;
    const clus: [*]Cluster = @ptrCast(@alignCast(blk + VH_SZ));
    const h = pk_block;
    trueRadii(clus, blk + h.odata, h.step, lo_, hi_);
}

/// The clusters' true bounding spheres (the original's radii leave out z, so a long
/// cluster could be culled while in view). The centres stay. All else that is
/// made from them keeps the original's values: the DAG's structure and its
/// cuts do not change.
pub fn trueRadii(clus: [*]Cluster, odata: [*]const u8, st: f32, lo_: usize, hi_: usize) void {
    for (lo_..hi_) |i| {
        const c = &clus[i];
        const d = odata + @as(u64, c.data) * 16;
        var mn: [3]i32 = @splat(std.math.maxInt(i32));
        var mx: [3]i32 = @splat(std.math.minInt(i32));
        for (0..c.nv) |v| {
            const q: *align(1) const [4]i32 = @ptrCast(d + v * 16);
            for (0..3) |k| {
                mn[k] = @min(mn[k], q[k]);
                mx[k] = @max(mx[k], q[k]);
            }
        }
        var ctr: [3]f32 = undefined;
        for (0..3) |k| ctr[k] = @as(f32, @floatFromInt(mn[k] +% mx[k])) * 0.5;
        var d2: f32 = 0;
        for (0..c.nv) |v| {
            const q: *align(1) const [4]i32 = @ptrCast(d + v * 16);
            const x = @as(f32, @floatFromInt(q[0])) - ctr[0];
            const y = @as(f32, @floatFromInt(q[1])) - ctr[1];
            const z = @as(f32, @floatFromInt(q[2])) - ctr[2];
            d2 = fmax(d2, x * x + y * y + z * z);
        }
        c.c[3] = (@sqrt(d2) + 2) * st;
    }
}

/// The DAG of a snapshot; null: no triangles, or no memory. The builder's memory
/// is given back.
fn run(pos: []const [3]f32, tris: []const [3]u32, hash: u64, background: bool) ?[]align(4096) u8 {
    const t0 = nowMs();
    s_pos = pos;
    s_tri = tris;
    s_hash = hash;
    fail.store(false, .monotonic);
    const mark = vm_n;
    defer vfreeTo(mark);
    if (pos.len < 3 or tris.len == 0) return null;
    if (!poolStart(background)) return null;
    defer poolStop();
    if (!bdWeld() or !bdAlloc() or !bdLevel0()) return null;
    while (bdLevel()) {}
    if (fail.load(.monotonic)) return null;
    const b = bdPack() orelse return null;
    const h: *Header = @ptrCast(b.ptr);
    h.ms = @intCast(nowMs() - t0);
    return b;
}

pub fn dagOf(block: []align(4096) u8) !*Dag {
    const h: *const Header = @ptrCast(block.ptr);
    const d = try A.create(Dag);
    d.* = .{ .block = block, .hash = h.hash, .phash = h.phash };
    return d;
}

/// Build now (for tests and scripts).
pub fn buildNow(pos: []const [3]f32, tris: []const [3]u32, hash: u64) ?*Dag {
    const b = run(pos, tris, hash, false) orelse return null;
    return dagOf(b) catch null;
}

pub fn freeDag(d: *Dag) void {
    @import("vgdraw.zig").forget(d);
    _ = linux.munmap(d.block.ptr, d.block.len);
    A.destroy(d);
}

// --- cuts and their checks --------------------------------------------------------------------

fn proj(e: f32, sph: *const [4]f32, cam: ?*const [3]f32) f32 {
    const c = cam orelse return e;
    const d = [3]f32{ sph[0] - c[0], sph[1] - c[1], sph[2] - c[2] };
    const x = @sqrt(d[1] * d[1] + d[0] * d[0] + d[2] * d[2]) - sph[3];
    return e / fmax(x, 1.0e-6);
}

pub const Sel = struct { clusters: u32, tris: u32 };

/// The cut "error <= t < parent error" (projected from the camera when given);
/// out: a byte per cluster.
pub fn select(d: *const Dag, t: f32, cam: ?*const [3]f32, out: []u8) Sel {
    var r = Sel{ .clusters = 0, .tris = 0 };
    for (d.clusters(), 0..) |*c, i| {
        out[i] = 0;
        if (proj(c.err, &c.lod, cam) > t) continue; // too coarse
        if (!(t < proj(c.perr, &c.plod, cam))) continue; // its parents are fine enough
        out[i] = 1;
        r.clusters += 1;
        r.tris += c.nt;
    }
    return r;
}

fn edgeHash(p: [*]const u8) u64 {
    const q: *align(1) const [3]u32 = @ptrCast(p);
    return mix(@as(u64, q[0]) | (@as(u64, q[1]) << 21) | (@as(u64, q[2]) << 42));
}
fn pairSum(a: u64, b: u64) u64 {
    return mix(std.math.rotl(u64, b, 23) ^ a) -% mix(std.math.rotl(u64, a, 23) ^ b);
}

/// The sum over the chosen triangles' directed edges of g(a, b) - g(b, a), vertices
/// by their grid position. A crack-free cut has the same sum as level 0 (0 for a
/// closed mesh).
pub fn edges(d: *const Dag, chosen: []const u8) u64 {
    var sum: u64 = 0;
    for (d.clusters(), 0..) |*c, i| {
        if (chosen[i] == 0) continue;
        const v = d.data(c);
        const t = v + @as(usize, c.nv) * 16;
        for (0..c.nt) |k| {
            if (t[k * 3] >= c.nv or t[k * 3 + 1] >= c.nv or t[k * 3 + 2] >= c.nv) continue; // (a damaged file)
            const a = edgeHash(v + @as(usize, t[k * 3]) * 16);
            const b = edgeHash(v + @as(usize, t[k * 3 + 1]) * 16);
            const e = edgeHash(v + @as(usize, t[k * 3 + 2]) * 16);
            sum +%= pairSum(a, b) +% pairSum(b, e) +% pairSum(e, a);
        }
    }
    return sum;
}

fn levelSel(d: *const Dag, l: u32, out: []u8) void {
    for (d.clusters(), 0..) |*c, i| out[i] = @intFromBool(c.level == l);
}

/// Every cluster within its limits, errors only growing to the parents, LOD
/// spheres inside the parents', and every cut crack-free: each level, 16 error
/// thresholds, 24 cameras around it.
pub fn check(d: *const Dag) bool {
    const h = d.hdr();
    const a = std.heap.page_allocator;
    const sel = a.alloc(u8, h.ncl) catch return false;
    defer a.free(sel);
    for (d.clusters()) |*c| {
        if (c.nt == 0 or c.nt > CL_TRIS or c.nv == 0 or c.nv > CL_VERTS) return false;
        if (c.err > c.perr) return false;
        const x = [3]f32{ c.lod[0] - c.plod[0], c.lod[1] - c.plod[1], c.lod[2] - c.plod[2] };
        const dist = @sqrt(x[1] * x[1] + x[0] * x[0] + x[2] * x[2]) + c.lod[3];
        if (dist > c.plod[3] * 1.00001 + 1.0e-6) return false;
    }
    levelSel(d, 0, sel);
    const d0 = edges(d, sel);
    var l: u32 = 1;
    while (l < h.nlv) : (l += 1) {
        levelSel(d, l, sel);
        if (edges(d, sel) != d0) return false;
    }
    const cutOk = struct {
        fn f(dg: *const Dag, t: f32, cam: ?*const [3]f32, s: []u8, want: u64) bool {
            if (select(dg, t, cam, s).clusters == 0) return false;
            return edges(dg, s) == want;
        }
    }.f;
    for (0..16) |k| { // thresholds 0 .. 1.25 x the largest
        const t = @as(f32, @floatFromInt(k)) * h.rerr * 0.104166667;
        if (!cutOk(d, t, null, sel, d0)) return false;
    }
    const half = h.step * 524288.0; // cameras: around the grid's centre
    const ctr = [3]f32{ h.bmin[0] + half, h.bmin[1] + half, h.bmin[2] + half };
    for (0..24) |k| {
        var r = mix(@as(u64, k) + 0x5eed);
        var cam: [3]f32 = undefined;
        for (0..3) |a_| {
            cam[a_] = @as(f32, @floatFromInt(r & 0xffff)) * 0.000030518 - 1.0;
            r >>= 16;
        }
        const dist = (@as(f32, @floatFromInt(r & 7)) * 0.9 + 0.1) * half; // 0.1 .. 6.4 half-grids
        for (0..3) |a_| cam[a_] = cam[a_] * dist + ctr[a_];
        const t = @as(f32, @floatFromInt(k & 7)) * 0.0024 + 0.0005; // 1/2000 .. 1/60
        if (!cutOk(d, t, &cam, sel, d0)) return false;
    }
    return true;
}

// --- the DAGs of the scene -----------------------------------------------------------------------

var table: std.AutoHashMapUnmanaged(u64, *Dag) = .empty;
/// Moves when what the viewport shows through DAGs may change.
pub var version: u32 = 0;

const HE = struct { serial: u32 = 0, shape: u32 = 0, n: u32 = 0, hash: u64 = 0 };
var hcache: [1 << 14]HE = @splat(.{});

/// The hash of a mesh, kept by its serial and shape: drawing asks every frame.
pub fn hashOf(me: *const scene.Mesh) u64 {
    var at = (me.serial *% 0x9e3779b1 ^ me.shape) & (hcache.len - 1);
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        const e = &hcache[(at + k) & (hcache.len - 1)];
        if (e.n != 0 and e.serial == me.serial and e.shape == me.shape and e.n == me.verts.len) return e.hash;
        if (e.n == 0) {
            at +%= @intCast(k);
            break;
        }
    }
    const h = meshHash(me);
    hcache[at & (hcache.len - 1)] = .{ .serial = me.serial, .shape = me.shape, .n = @intCast(me.verts.len), .hash = h };
    return h;
}

/// The DAG of this mesh as it is now.
pub fn of(me: *const scene.Mesh) ?*Dag {
    if (table.count() == 0 or me.verts.len == 0) return null;
    return table.get(hashOf(me));
}

pub fn dagCount() usize {
    return table.count();
}

fn put(d: *Dag) void {
    table.put(A, d.hash, d) catch return;
    if (d.phash != 0) table.put(A, d.phash, d) catch {};
    version +%= 1;
}

fn removeDag(d: *Dag) void {
    _ = table.remove(d.hash);
    if (d.phash != 0) _ = table.remove(d.phash);
    freeDag(d);
    version +%= 1;
}

/// The DAGs no object's mesh matches go (after a build, a new scene).
pub fn sweep() void {
    if (table.count() == 0) return;
    var live: std.AutoHashMapUnmanaged(*Dag, void) = .empty;
    defer live.deinit(A);
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.kind.isMesh()) continue;
        if (scene.meshOfObj(oi)) |b| {
            if (of(b)) |d| live.put(A, d, {}) catch return;
        }
        if (@import("mods.zig").of(oi)) |e| {
            if (of(e)) |d| live.put(A, d, {}) catch return;
        }
    }
    var dead: std.ArrayListUnmanaged(*Dag) = .empty;
    defer dead.deinit(A);
    var it = table.iterator();
    while (it.next()) |kv| {
        if (live.contains(kv.value_ptr.*)) continue;
        var seen = false;
        for (dead.items) |x| seen = seen or x == kv.value_ptr.*;
        if (!seen) dead.append(A, kv.value_ptr.*) catch return;
    }
    for (dead.items) |d| removeDag(d);
}

// --- the file -----------------------------------------------------------------------------------

/// The VGEO chunks: the mesh's index, padding to a page of the file, the block
/// (the runtime part of the header as zeros). An evaluated mesh's DAG goes with
/// its base mesh; the original keeps it but finds it out of date.
pub fn writeChunks(b: anytype, mesh_ix: []const u32) void {
    if (table.count() == 0) return;
    const mods = @import("mods.zig");
    const One = struct {
        fn f(bb: @TypeOf(b), d: *const Dag, ix: u32, zeros: *const [4096]u8) void {
            if (d.block.len >= 0xffffe000) return; // (a chunk's size is a u32)
            bb.u32_(MAGIC); // (the chunk's tag; its size comes after)
            bb.u32_(0);
            const st = bb.data.items.len;
            bb.u32_(ix);
            const pad: u32 = @intCast((4096 - ((bb.data.items.len + 4) & 4095)) & 4095);
            bb.u32_(pad);
            bb.bytes(zeros[0..pad]);
            var head: [VH_SZ]u8 = undefined;
            @memcpy(&head, d.block[0..VH_SZ]);
            std.mem.writeInt(u32, head[8..12], 1, .little); // refs
            std.mem.writeInt(u64, head[512..520], d.phash, .little);
            @memset(head[VR_CREATOR..], 0);
            bb.bytes(&head);
            bb.bytes(d.block[VH_SZ..]);
            std.mem.writeInt(u32, bb.data.items[st - 4 ..][0..4], @intCast(bb.data.items.len - st), .little);
            @import("vgdraw.zig").drop(d); // (read all through: given back)
        }
    }.f;
    const zeros: [4096]u8 = @splat(0);
    var done: std.AutoHashMapUnmanaged(*const Dag, void) = .empty;
    defer done.deinit(A);
    // evaluated meshes first: when a mesh has both, the base's comes last
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        const mi = o.mesh orelse continue;
        if (!o.kind.isMesh() or mi >= mesh_ix.len or mesh_ix[mi] == 0xffffffff or o.mods.n == 0) continue;
        const e = mods.of(oi) orelse continue;
        const base = scene.meshOfObj(oi) orelse continue;
        if (e == base) continue;
        const d = of(e) orelse continue;
        if (done.contains(d)) continue;
        One(b, d, mesh_ix[mi], &zeros);
        done.put(A, d, {}) catch {};
    }
    for (mesh_ix, 0..) |ix, mi| {
        if (ix == 0xffffffff) continue;
        const me = if (scene.meshes[mi]) |*x| x else continue;
        const d = of(me) orelse continue;
        if (done.contains(d)) continue;
        One(b, d, ix, &zeros);
        done.put(A, d, {}) catch {};
    }
}

fn fin(a: []const f32) bool {
    for (a) |x| {
        if (!(@abs(x) < 3.5e38)) return false;
    }
    return true;
}

/// Everything in the block a reader relies on, but the cluster data itself (its
/// triangles' corners are checked as they are drawn: the pages may stay on disk).
/// A block from a file is not to be trusted.
pub fn validate(b: []const u8) bool {
    if (b.len < VH_SZ or b.len & 4095 != 0) return false;
    if (@intFromPtr(b.ptr) & 63 != 0) return false;
    const h: *const Header = @ptrCast(@alignCast(b.ptr));
    if (h.magic != MAGIC or h.ver != VERSION) return false;
    if (h.bytes != b.len) return false;
    if (h.ncl == 0 or h.nlv == 0 or h.nlv > MAXLV) return false;
    const cl_b: u64 = @as(u64, h.ncl) * 64;
    const gr_b: u64 = @as(u64, h.ngr) * 48;
    const mem_b: u64 = @as(u64, h.nmem) * 4;
    if (h.ocl != VH_SZ or h.ogr != VH_SZ + cl_b or h.omem != h.ogr + gr_b) return false;
    if (h.odata < h.omem + mem_b or h.odata & 4095 != 0) return false;
    if (h.odata > h.bytes or h.dbytes > h.bytes - h.odata) return false;
    if (!(h.step > 0) or !(h.step < 1.0e20)) return false;
    if (!fin(&h.bmin) or !(@abs(h.bmin[0]) < 1.0e30) or !(@abs(h.bmin[1]) < 1.0e30) or !(@abs(h.bmin[2]) < 1.0e30)) return false;
    const clus: [*]const Cluster = @ptrCast(@alignCast(b.ptr + VH_SZ));
    var roots: u32 = 0;
    for (clus[0..h.ncl]) |*c| {
        if (c.nt == 0 or c.nt > CL_TRIS or c.nv == 0 or c.nv > CL_VERTS) return false;
        if (@as(u64, c.data) * 16 + clusterBytes(c) > h.dbytes) return false;
        if (!fin(&c.c) or !fin(&c.lod) or !fin(&c.plod) or !fin(&[2]f32{ c.err, c.perr })) return false;
        if (c.c[3] < 0 or c.lod[3] < 0 or c.plod[3] < 0) return false;
        if (@as(u32, @bitCast(c.perr)) == FLT_MAX) roots += 1;
    }
    if (roots == 0) return false;
    const grs: [*]const Group = @ptrCast(@alignCast(b.ptr + h.ogr));
    for (grs[0..h.ngr]) |*g| {
        if (@as(u64, g.mem) + g.nmem > h.nmem) return false;
        if (@as(u64, g.par) + g.npar > h.ncl) return false;
        if (!fin(&g.lod) or !fin(&[1]f32{g.err})) return false;
    }
    const mb: [*]const u32 = @ptrCast(@alignCast(b.ptr + h.omem));
    for (mb[0..h.nmem]) |x| {
        if (x >= h.ncl) return false;
    }
    return true;
}

fn mapBlock(path: []const u8, off: u64, bytes: u64) ?[]align(4096) u8 {
    var pz: [600]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pz, "{s}", .{path}, 0) catch return null;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const mp = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE }, fd, @intCast(off));
    if (linux.errno(mp) != .SUCCESS) return null;
    const ptr: [*]align(4096) u8 = @ptrFromInt(mp);
    return ptr[0..bytes];
}

/// One VGEO chunk (after the meshes). A block on a page of the file (`file` is its
/// bytes, when the chunk lies in it) stays mapped from it, its cluster data read
/// where the view needs it; else it is copied. False: it was damaged.
pub fn readChunk(c: []const u8, nmesh: usize, file: ?[]const u8, path: []const u8) bool {
    if (c.len < 8) return false;
    const ix = std.mem.readInt(u32, c[0..4], .little);
    const pad = std.mem.readInt(u32, c[4..8], .little);
    if (pad > c.len - 8) return false;
    const rest = c[8 + pad..];
    if (rest.len < VH_SZ) return false;
    const bytes = std.mem.readInt(u64, rest[112..120], .little);
    if (bytes > rest.len or bytes < VH_SZ or bytes & 4095 != 0) return false;
    if (ix >= nmesh) return false; // (no such mesh: dropped)
    var block: ?[]align(4096) u8 = null;
    var stream = false;
    if (file) |f| {
        const off = @intFromPtr(rest.ptr) -% @intFromPtr(f.ptr);
        if (off & 4095 == 0 and off + bytes <= f.len) {
            block = mapBlock(path, off, bytes);
            stream = block != null;
        }
    }
    if (block == null) {
        const n = rawMap(bytes) orelse return false;
        @memcpy(n[0..bytes], rest[0..bytes]);
        block = n[0..bytes];
    }
    const b = block.?;
    const good = validate(b);
    if (!good) {
        _ = linux.munmap(b.ptr, b.len);
        return false;
    }
    const d = dagOf(b) catch {
        _ = linux.munmap(b.ptr, b.len);
        return false;
    };
    d.stream = stream;
    if (table.get(d.hash)) |old| removeDag(old);
    put(d);
    return true;
}

// --- the build as a job ---------------------------------------------------------------------------

var state = std.atomic.Value(u32).init(0); // 0 idle, 1 building, 2 built (to attach)
var thread: ?std.Thread = null;
var out_block: ?[]align(4096) u8 = null;
var t_start: i64 = 0;
var snap_pos: [][3]f32 = &.{};
var snap_tri: [][3]u32 = &.{};
var name_buf: [32]u8 = @splat(0);
var name_len: usize = 0;

fn snapFree() void {
    const p = std.heap.page_allocator;
    if (snap_pos.len > 0) p.free(snap_pos);
    if (snap_tri.len > 0) p.free(snap_tri);
    snap_pos = &.{};
    snap_tri = &.{};
}

fn bgThread(hash: u64) void {
    niceThread();
    out_block = run(snap_pos, snap_tri, hash, true);
    state.store(2, .release);
}

/// The base mesh the build was for (its serial): it then has had a DAG (vg_had).
var build_serial: u32 = 0;

fn markHad(serial: u32) void {
    if (serial == 0) return;
    for (&scene.meshes) |*x| {
        if (x.*) |*me| {
            if (me.serial == serial) me.vg_had = true;
        }
    }
}

/// vg_info(mesh, 0): 0 none, 1 building, 2 ready, 3 out of date (it had one,
/// edited since). `base` is the object's own mesh, `shown` what it shows.
pub fn stateOf(base: *const scene.Mesh, shown: ?*const scene.Mesh) u32 {
    if (state.load(.acquire) != 0 and build_serial == base.serial) return 1;
    if (of(base) != null) return 2;
    if (shown) |e| {
        if (of(e) != null) return 2;
    }
    return if (base.vg_had) 3 else 0;
}

pub fn building() bool {
    return state.load(.acquire) != 0;
}

pub const Chip = struct { label: []const u8, frac: f32, ms: i64 };
pub fn progress() ?Chip {
    if (state.load(.acquire) != 1) return null;
    return .{ .label = "Virtualizing the mesh", .frac = -1, .ms = nowMs() - t_start };
}

/// A build that finished: its DAG goes in (the UI thread). True: something changed.
pub fn tick() bool {
    if (state.load(.acquire) != 2) return false;
    const app = @import("app.zig");
    if (thread) |t| t.join();
    thread = null;
    snapFree();
    const b = out_block;
    out_block = null;
    state.store(0, .release);
    if (b) |blk| {
        if (dagOf(blk)) |d| {
            if (table.get(d.hash)) |old| removeDag(old);
            put(d);
            markHad(build_serial);
            const h = d.hdr();
            app.toast(.ok, "Virtualized: {d} triangles, {d} clusters, {d} levels, {d} roots, {d} ms", .{ h.stri, h.ncl, h.nlv, h.roots, h.ms });
            sweep();
        } else |_| app.toast(.warn, "Virtualize failed (out of memory?)", .{});
    } else app.toast(.warn, "Virtualize failed (out of memory?)", .{});
    app.dirty = true;
    return true;
}

/// Until a background build ends (tests).
pub fn waitBuild() void {
    while (state.load(.acquire) == 1) {
        var ts: linux.timespec = .{ .sec = 0, .nsec = 5_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    _ = tick();
}

// --- operators ------------------------------------------------------------------------------------

fn activeObj() ?usize {
    const a = scene.active orelse return null;
    const o = &scene.objects[a];
    return if (o.mesh != null and o.kind.isMesh()) a else null;
}

/// What the active object shows (its modifiers evaluated).
fn activeMesh() ?*const scene.Mesh {
    const a = activeObj() orelse return null;
    return @import("mods.zig").of(a);
}

pub fn activeDag() ?*Dag {
    return of(activeMesh() orelse return null);
}

pub fn pollMesh() ?[]const u8 {
    return if (activeObj() == null) "Select a mesh object first" else null;
}
pub fn pollDag() ?[]const u8 {
    if (activeObj() == null) return "Select a mesh object first";
    return if (activeDag() == null) "No cluster DAG for this mesh (vgeo.build)" else null;
}

pub fn opBuild(arg: []const u8) void {
    const app = @import("app.zig");
    if (building()) return app.log("A mesh is being virtualized already", .{});
    const me = activeMesh() orelse return app.toast(.warn, "Virtualize: the active object has no triangles", .{});
    if (me.verts.len < 3 or me.tris.len == 0) return app.toast(.warn, "Virtualize: the active object has no triangles", .{});
    const p = std.heap.page_allocator;
    snap_pos = p.dupe([3]f32, me.verts) catch return app.toast(.warn, "Virtualize failed (out of memory?)", .{});
    snap_tri = p.dupe([3]u32, me.tris) catch {
        snapFree();
        return app.toast(.warn, "Virtualize failed (out of memory?)", .{});
    };
    const hash = hashOf(me);
    const o = &scene.objects[activeObj().?];
    build_serial = if (scene.meshOfObj(activeObj().?)) |bm| bm.serial else 0;
    app.log("Virtualizing {s} ({d} triangles)", .{ o.name(), me.tris.len });
    t_start = nowMs();
    const headless = @import("jobui.zig").present_fn == null;
    const asynch = !headless or std.mem.eql(u8, std.mem.trim(u8, arg, " "), "async");
    state.store(1, .release);
    if (asynch) {
        // the window: in the background
        if (std.Thread.spawn(.{ .stack_size = 1 << 20 }, bgThread, .{hash})) |t| {
            thread = t;
            return;
        } else |_| {}
    }
    out_block = run(snap_pos, snap_tri, hash, false); // (scripts, headless: now)
    state.store(2, .release);
    _ = tick();
}

pub fn opClear() void {
    const app = @import("app.zig");
    const d = activeDag() orelse return;
    removeDag(d);
    if (scene.objects[activeObj().?].mesh) |mi| { // (vg_attach(mesh, 0): none, not out of date)
        if (scene.meshes[mi]) |*me| me.vg_had = false;
    }
    app.log("Cluster DAG cleared", .{});
}

const Weld = struct { key: [3]i32, id: u32 };

/// vgeo.extract <level | error>: the cut as a new mesh object. Default: the middle
/// level. (The port has no vertex colours: its clusters are not coloured.)
pub fn opExtract(arg0: []const u8) void {
    const app = @import("app.zig");
    const oi = activeObj() orelse return app.log("No cluster DAG for this mesh (vgeo.build)", .{});
    const d = activeDag() orelse return app.log("No cluster DAG for this mesh (vgeo.build)", .{});
    const h = d.hdr();
    const a = std.heap.page_allocator;
    const sel = a.alloc(u8, h.ncl) catch return;
    defer a.free(sel);
    var level: i32 = @intCast(h.nlv >> 1);
    var thr: f32 = 0;
    const arg = std.mem.trim(u8, arg0, " ");
    if (arg.len > 0) {
        if (std.fmt.parseFloat(f32, arg)) |v| {
            if (std.math.isFinite(v)) {
                if (std.mem.indexOfScalar(u8, arg, '.') != null) { // a '.': an error, else a level
                    thr = v;
                    level = -1;
                } else level = @intFromFloat(std.math.clamp(v, 0, @as(f32, @floatFromInt(h.nlv - 1))));
            }
        } else |_| {}
    }
    if (level >= 0) levelSel(d, @intCast(level), sel) else _ = select(d, thr, null, sel);
    var nv: usize = 0;
    var nt: usize = 0;
    for (d.clusters(), 0..) |*c, i| {
        if (sel[i] == 0) continue;
        nv += c.nv;
        nt += c.nt;
    }
    if (nt == 0) return;
    const verts = a.alloc(m.V3, nv) catch return;
    defer a.free(verts);
    const poff = a.alloc(u32, nt + 1) catch return;
    defer a.free(poff);
    const loops = a.alloc(u32, nt * 3) catch return;
    defer a.free(loops);
    var at: u32 = 0;
    var tn: usize = 0;
    for (d.clusters(), 0..) |*c, i| {
        if (sel[i] == 0) continue;
        const dt = d.data(c);
        for (0..c.nv) |v| verts[at + v] = gridPoint(h, dt + v * 16);
        const tr = dt + @as(usize, c.nv) * 16;
        for (0..c.nt) |t| {
            const x = tr[t * 3 ..][0..3];
            if (x[0] >= c.nv or x[1] >= c.nv or x[2] >= c.nv) continue;
            poff[tn] = @intCast(tn * 3);
            for (0..3) |e| loops[tn * 3 + e] = at + x[e];
            tn += 1;
        }
        at += c.nv;
    }
    poff[tn] = @intCast(tn * 3);
    const mi = scene.addMesh(verts, poff[0 .. tn + 1], loops[0 .. tn * 3]) orelse return;
    const k = scene.add(.mesh) orelse return app.toast(.warn, "The scene is full ({d} objects)", .{scene.max_objects});
    const o = &scene.objects[k];
    o.mesh = mi;
    o.setName("LOD");
    const src = &scene.objects[oi]; // where the source is
    o.loc = src.loc;
    o.rot = src.rot;
    o.scl = src.scl;
    o.parent = src.parent;
    app.log("LOD: {d} triangles", .{tn});
}

pub fn gridPoint(h: *const Header, p: [*]const u8) m.V3 {
    const q: *align(1) const [3]i32 = @ptrCast(p);
    return .{
        @as(f32, @floatFromInt(q[0])) * h.step + h.bmin[0],
        @as(f32, @floatFromInt(q[1])) * h.step + h.bmin[1],
        @as(f32, @floatFromInt(q[2])) * h.step + h.bmin[2],
    };
}

/// The active mesh (and every object showing it) replaced by a mesh of its DAG's
/// roots, vertices welded by grid position; the DAG goes with it.
pub fn opProxy() void {
    const app = @import("app.zig");
    const oi = activeObj() orelse return app.log("No cluster DAG for this mesh (vgeo.build)", .{});
    const d = activeDag() orelse return app.log("No cluster DAG for this mesh (vgeo.build)", .{});
    if (@import("mods.zig").of(oi) != scene.meshOfObj(oi)) return app.toast(.warn, "Proxy Mesh: apply the object's modifiers first", .{});
    const old = scene.objects[oi].mesh.?;
    const h = d.hdr();
    var nv: usize = 0;
    var nt: usize = 0;
    for (d.clusters()) |*c| {
        if (@as(u32, @bitCast(c.perr)) != FLT_MAX) continue;
        nv += c.nv;
        nt += c.nt;
    }
    if (nt == 0) return app.log("No cluster DAG for this mesh (vgeo.build)", .{});
    const a = std.heap.page_allocator;
    var cap: usize = 64; // the weld table: a power of two
    while (cap < nv * 2) cap += cap;
    const tab = a.alloc(Weld, cap) catch return;
    defer a.free(tab);
    @memset(tab, .{ .key = .{ 0, 0, 0 }, .id = 0 });
    const verts = a.alloc(m.V3, nv) catch return;
    defer a.free(verts);
    const poff = a.alloc(u32, nt + 1) catch return;
    defer a.free(poff);
    const loops = a.alloc(u32, nt * 3) catch return;
    defer a.free(loops);
    var n_v: u32 = 0;
    var tn: usize = 0;
    for (d.clusters()) |*c| {
        if (@as(u32, @bitCast(c.perr)) != FLT_MAX) continue;
        const dt = d.data(c);
        var map: [256]u32 = undefined;
        for (0..c.nv) |v| {
            const q: *align(1) const [3]i32 = @ptrCast(dt + v * 16);
            var hh: u32 = @as(u32, @bitCast(q[0])) *% 0x9e3779b1;
            hh = (hh ^ @as(u32, @bitCast(q[1]))) *% 0x85ebca6b;
            hh = (hh ^ @as(u32, @bitCast(q[2]))) *% 0xc2b2ae35;
            hh ^= hh >> 15;
            var at: usize = hh & (cap - 1);
            while (true) {
                const e = &tab[at];
                if (e.id == 0) {
                    e.key = q.*;
                    verts[n_v] = gridPoint(h, dt + v * 16);
                    n_v += 1;
                    e.id = n_v;
                    map[v] = n_v - 1;
                    break;
                }
                if (e.key[0] == q[0] and e.key[1] == q[1] and e.key[2] == q[2]) {
                    map[v] = e.id - 1;
                    break;
                }
                at = (at + 1) & (cap - 1);
            }
        }
        const tr = dt + @as(usize, c.nv) * 16;
        for (0..c.nt) |t| {
            const x = tr[t * 3 ..][0..3];
            if (x[0] >= c.nv or x[1] >= c.nv or x[2] >= c.nv) continue;
            const ia = map[x[0]];
            const ib = map[x[1]];
            const ic = map[x[2]];
            if (ia == ib or ia == ic or ib == ic) continue; // (welded together: dropped)
            poff[tn] = @intCast(tn * 3);
            loops[tn * 3] = ia;
            loops[tn * 3 + 1] = ib;
            loops[tn * 3 + 2] = ic;
            tn += 1;
        }
    }
    poff[tn] = @intCast(tn * 3);
    const mi = scene.addMesh(verts[0..n_v], poff[0 .. tn + 1], loops[0 .. tn * 3]) orelse return;
    const nm_ = &scene.meshes[mi].?;
    nm_.vg_had = true;
    if (d.phash != 0) _ = table.remove(d.phash);
    d.phash = hashOf(nm_); // the DAG goes with it: the proxy's hash also matches
    put(d);
    for (scene.objects[0..scene.count]) |*o| { // every object showing the old mesh
        if (o.mesh == old) o.mesh = mi;
    }
    app.log("Proxy: {d} triangles stand in for {d} triangles", .{ nm_.tris.len, h.stri });
}

/// What vgeo(name, k) answers in the original (a console line).
pub fn info(d: *const Dag, k: u32) f32 {
    const h = d.hdr();
    const f = struct {
        fn i(x: anytype) f32 {
            return @floatFromInt(x);
        }
    }.i;
    switch (k) {
        1 => return f(h.ncl),
        2 => return f(h.nlv),
        3 => return f(h.ngr),
        4 => return f(h.stri),
        5 => return f(h.lv[h.nlv - 1].tris),
        6 => return f(h.ms),
        7 => return f(h.bytes >> 10),
        8 => return h.rerr,
        9 => return f(h.roots),
        10, 11 => {
            var mx: u32 = 0;
            for (d.clusters()) |*c| mx = @max(mx, if (k == 10) c.nt else c.nv);
            return f(mx);
        },
        13 => return f(h.ttri),
        14 => return f(h.lv[0].n),
        else => return 0,
    }
}

// --- tests --------------------------------------------------------------------------------------

const t_alloc = std.testing.allocator;

const TestMesh = struct {
    pos: [][3]f32,
    tris: [][3]u32,
    fn deinit(tm: *TestMesh) void {
        t_alloc.free(tm.pos);
        t_alloc.free(tm.tris);
    }
};

fn torus(nu: u32, nv: u32) !TestMesh {
    const pos = try t_alloc.alloc([3]f32, nu * nv);
    const tris = try t_alloc.alloc([3]u32, nu * nv * 2);
    for (0..nu) |i| {
        for (0..nv) |j| {
            const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(nu)) * std.math.tau;
            const v = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(nv)) * std.math.tau;
            pos[i * nv + j] = .{ (1 + 0.3 * @cos(v)) * @cos(u), 0.3 * @sin(v), (1 + 0.3 * @cos(v)) * @sin(u) };
            const a: u32 = @intCast(i * nv + j);
            const b: u32 = @intCast(((i + 1) % nu) * nv + j);
            const c: u32 = @intCast(((i + 1) % nu) * nv + (j + 1) % nv);
            const d: u32 = @intCast(i * nv + (j + 1) % nv);
            tris[(i * nv + j) * 2] = .{ a, b, c };
            tris[(i * nv + j) * 2 + 1] = .{ a, c, d };
        }
    }
    return .{ .pos = pos, .tris = tris };
}

fn rippled(n: u32) !TestMesh {
    const pos = try t_alloc.alloc([3]f32, (n + 1) * (n + 1));
    const tris = try t_alloc.alloc([3]u32, n * n * 2);
    for (0..n + 1) |i| {
        for (0..n + 1) |j| {
            const x = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) - 0.5;
            const z = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(n)) - 0.5;
            pos[i * (n + 1) + j] = .{ x, 0.05 * @sin(5 * x) * @cos(7 * z), z };
        }
    }
    for (0..n) |i| {
        for (0..n) |j| {
            const a: u32 = @intCast(i * (n + 1) + j);
            const b: u32 = @intCast((i + 1) * (n + 1) + j);
            tris[(i * n + j) * 2] = .{ a, b, b + 1 };
            tris[(i * n + j) * 2 + 1] = .{ a, b + 1, a + 1 };
        }
    }
    return .{ .pos = pos, .tris = tris };
}

fn cubes(k: u32) !TestMesh {
    const n = k * k * k;
    const pos = try t_alloc.alloc([3]f32, n * 8);
    const tris = try t_alloc.alloc([3]u32, n * 12);
    const faces = [6][4]u32{ .{ 0, 1, 2, 3 }, .{ 7, 6, 5, 4 }, .{ 0, 4, 5, 1 }, .{ 1, 5, 6, 2 }, .{ 2, 6, 7, 3 }, .{ 3, 7, 4, 0 } };
    const cv = [8][3]f32{ .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, -1, 1 }, .{ -1, -1, 1 }, .{ -1, 1, -1 }, .{ 1, 1, -1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } };
    for (0..n) |c| {
        const o = [3]f32{ @floatFromInt(c % k), @floatFromInt((c / k) % k), @floatFromInt(c / (k * k)) };
        for (0..8) |v| {
            for (0..3) |a| pos[c * 8 + v][a] = o[a] * 3 + cv[v][a] * 0.5;
        }
        for (faces, 0..) |f, q| {
            const b: u32 = @intCast(c * 8);
            tris[c * 12 + q * 2] = .{ b + f[0], b + f[1], b + f[2] };
            tris[c * 12 + q * 2 + 1] = .{ b + f[0], b + f[2], b + f[3] };
        }
    }
    return .{ .pos = pos, .tris = tris };
}

fn testBuild(tm: *const TestMesh) !*Dag {
    return buildNow(tm.pos, tm.tris, 0x1234) orelse error.BuildFailed;
}
fn freeTest(d: *Dag) void {
    _ = linux.munmap(d.block.ptr, d.block.len);
    A.destroy(d);
}

test "rint rounds as cvtss2si" {
    try std.testing.expectEqual(@as(i32, 2), rint(2.5));
    try std.testing.expectEqual(@as(i32, 4), rint(3.5));
    try std.testing.expectEqual(@as(i32, -2), rint(-2.5));
    try std.testing.expectEqual(@as(i32, 3), rint(2.75));
    try std.testing.expectEqual(std.math.minInt(i32), rint(std.math.nan(f32)));
}

test "octahedral normals come back" {
    const dirs = [_][3]f32{ .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 }, .{ 0.3, -0.5, -0.8 }, .{ -0.6, 0.7, 0.1 } };
    for (dirs) |d| {
        var w: u32 = undefined;
        octStore(d, &w);
        const n = octLoad(w);
        const l = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        const dl = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        const dot = (n[0] * d[0] + n[1] * d[1] + n[2] * d[2]) / (l * dl);
        try std.testing.expect(dot > 0.9999);
    }
}

test "a torus: one root, every cut crack-free" {
    var tm = try torus(256, 128);
    defer tm.deinit();
    const d = try testBuild(&tm);
    defer freeTest(d);
    try std.testing.expect(d.hdr().nlv > 3);
    try std.testing.expectEqual(@as(u32, 1), d.hdr().roots);
    try std.testing.expect(validate(d.block));
    try std.testing.expect(check(d));
}

test "an open grid: every cut crack-free, the top small" {
    var tm = try rippled(256);
    defer tm.deinit();
    const d = try testBuild(&tm);
    defer freeTest(d);
    try std.testing.expect(check(d));
    const h = d.hdr();
    try std.testing.expect(h.lv[h.nlv - 1].tris * 100 <= h.stri);
}

test "islands: 216 cubes share clusters and shrink to little" {
    var tm = try cubes(6);
    defer tm.deinit();
    const d = try testBuild(&tm);
    defer freeTest(d);
    try std.testing.expect(check(d));
    const h = d.hdr();
    try std.testing.expect(h.roots <= 16);
    try std.testing.expect(h.lv[h.nlv - 1].tris <= 216 * 4);
}

test "the crack check can fail: a cut missing a cluster, a moved vertex" {
    var tm = try torus(64, 32);
    defer tm.deinit();
    const d = try testBuild(&tm);
    defer freeTest(d);
    const sel = try t_alloc.alloc(u8, d.hdr().ncl);
    defer t_alloc.free(sel);
    levelSel(d, 0, sel);
    const want = edges(d, sel);
    try std.testing.expectEqual(@as(u64, 0), want); // (closed)
    sel[1] = 0;
    try std.testing.expect(edges(d, sel) != want);
    levelSel(d, 0, sel);
    // a cluster of a level above off its grid positions
    const c = &d.clusters()[d.hdr().lv[1].first];
    for (0..c.nv) |i| {
        const v: *align(1) i32 = @ptrCast(@constCast(d.data(c) + i * 16));
        v.* += 7;
    }
    try std.testing.expect(!check(d));
}

test "radii hold every vertex" {
    var tm = try rippled(64);
    defer tm.deinit();
    for (tm.pos) |*p| { // (long in z: the original's radii leave z out)
        p[2] *= 40;
    }
    const d = try testBuild(&tm);
    defer freeTest(d);
    const h = d.hdr();
    for (d.clusters()) |*c| {
        const dt = d.data(c);
        for (0..c.nv) |v| {
            const p = gridPoint(h, dt + v * 16);
            const x = [3]f32{ p[0] - c.c[0], p[1] - c.c[1], p[2] - c.c[2] };
            try std.testing.expect(@sqrt(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]) <= c.c[3]);
        }
    }
}

test "a damaged block is refused, and none crashes the reader" {
    var tm = try torus(64, 32);
    defer tm.deinit();
    const d = try testBuild(&tm);
    defer freeTest(d);
    const n = d.block.len;
    const copy = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), n);
    defer std.heap.page_allocator.free(copy);
    @memcpy(copy, d.block);
    try std.testing.expect(validate(copy));
    const h: *Header = @ptrCast(copy.ptr);
    const cases = [_]struct { off: usize, val: u32 }{
        .{ .off = 0, .val = 0 }, .{ .off = 4, .val = 3 }, .{ .off = 12, .val = 0xffffffff }, .{ .off = 16, .val = 0xffffffff },
        .{ .off = 20, .val = 99 }, .{ .off = 44, .val = 0x7fc00000 }, .{ .off = 64, .val = 0xffffffff }, .{ .off = 96, .val = 0x7fffffff },
        .{ .off = 104, .val = 0xffffffff }, .{ .off = 112, .val = 12 },
    };
    _ = h;
    for (cases) |cs| {
        const old = std.mem.readInt(u32, copy[cs.off..][0..4], .little);
        std.mem.writeInt(u32, copy[cs.off..][0..4], cs.val, .little);
        try std.testing.expect(!validate(copy));
        std.mem.writeInt(u32, copy[cs.off..][0..4], old, .little);
    }
    // a cluster over the end of the data, a member out of range
    const cl: [*]Cluster = @ptrCast(@alignCast(copy.ptr + VH_SZ));
    cl[3].data = 0xffffffff;
    try std.testing.expect(!validate(copy));
    @memcpy(copy, d.block);
    cl[3].nt = 200;
    try std.testing.expect(!validate(copy));
    @memcpy(copy, d.block);
    cl[0].err = std.math.nan(f32);
    try std.testing.expect(!validate(copy));
    @memcpy(copy, d.block);
    const hd: *const Header = @ptrCast(@alignCast(copy.ptr));
    const mb: [*]u32 = @ptrCast(@alignCast(copy.ptr + hd.omem));
    mb[0] = hd.ncl;
    try std.testing.expect(!validate(copy));
}
