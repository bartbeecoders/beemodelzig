// The path tracer on the GPU (gpu.s's gp_* and gpu_pt_*): the scene as Hive has it
// (hive.zig, pt.zig's lights) laid out as pt.comp's bindings in a slot, and the
// F12 render's passes run there. The sums come back into pt.zig's film after each
// batch, so everything after (the passes, the denoiser, saving, and the CPU going
// on where it was when the helper dies) is what it always was: the GPU draws the
// same streams as the CPU.
//
// The scene stays on the GPU between renders: a binding gets an eighth more room
// than it needs, so the next scene keeps the layout while it fits; the slot's
// memory then still holds the last scene, the device its copy, and only the 4 KiB
// blocks that differ go up (as gpu.s's put_delta). The live view (livegpu.zig) has
// a slot of its own.
const std = @import("std");
const m = @import("math.zig");
const ipc = @import("gpu/ipc.zig");
const gpu = @import("gpu.zig");
const hive = @import("hive.zig");
const pt = @import("pt.zig");
const env = @import("env.zig");
const images = @import("images.zig");
const material = @import("material.zig");
const texture = @import("texture.zig");
const jobs = @import("jobs.zig");
const app = @import("app.zig");
const A = std.heap.page_allocator;

const MAX_LIGHTS = 64;
const NIMG = 1024; // images the GPU sees (graph.glsl's table)
const BLK = 4096; // compared in blocks
const GAP = 65536; // ranges this close joined
const PARAM_WORDS = ipc.P_HEAD + MAX_LIGHTS * 16 + 256;
const LIVE_AUX = 80; // the live slot's aux: the sums and the denoiser's buffers

/// Where the last render ran, and why (gpu(18)).
pub const Why = enum(u8) {
    none,
    gpu,
    device_cpu,
    no_helper,
    node,
    lights,
    big,
    no_memory,
    busy,
    failed,
    pub fn text(w: Why) []const u8 {
        return switch (w) {
            .none, .gpu => "",
            .device_cpu => "Device is CPU",
            .no_helper => "no helper or device",
            .node => "a material node the GPU lacks",
            .lights => "more than 64 lights",
            .big => "too many triangles",
            .no_memory => "no memory for the GPU",
            .busy => "the GPU has not finished its last batch",
            .failed => "the helper failed",
        };
    }
};
pub var why: Why = .none;
pub var last_rtx = false;
pub var last_kib: u64 = 0;

/// A slot's scene.
pub const Up = struct {
    off: [ipc.PT_NTAB]u64 = @splat(0),
    cap: [ipc.PT_NTAB]u64 = @splat(0),
    bytes: [ipc.PT_NTAB]u64 = @splat(0),
    w: u32 = 0,
    h: u32 = 0,
    kern: u32 = 0, // kernel + 1
    nbind: u32 = 0,
    first: bool = true, // the next run sends the scene
    ok: bool = false, // the device holds the slot's bindings as its memory does
    img_key: u64 = 0,
    env_key: u64 = 0,
    sent_kib: u64 = 0,
};
pub var ups: [3]Up = @splat(.{});

fn alignUp(x: u64, a: u64) u64 {
    return (x + a - 1) & ~(a - 1);
}

// --- what the kernels can run -------------------------------------------------------------------

const TYPES: u64 = 1 << 1 | 1 << 2 | 1 << 3 | 1 << 4 | 1 << 5 | 1 << 6 | 1 << 7 | 1 << 8 | 1 << 9 | 1 << 10 | 1 << 11 | 1 << 12 | 1 << 14 | 1 << 16 | 1 << 17 | 1 << 19 | 1 << 20 | 1 << 21 | 1 << 25 | 1 << 26 | 1 << 27 | 1 << 33 | 1 << 36 | 1 << 37 | 1 << 38 | 1 << 39;

/// pt.comp evaluates its graph: none, or only the node types it knows, 8-bit images.
pub fn graphOk(ma: *const material.Material) bool {
    const r: [*]const u8 = @ptrCast(ma);
    const n = ma.nodes();
    if (n == 0) return true;
    if (n > 48) return false;
    for (0..n) |j| {
        const nd = r[160 + j * 72..];
        const ty = std.mem.readInt(u32, nd[0..4], .little);
        if (ty > 63 or (TYPES >> @intCast(ty)) & 1 == 0) return false;
        if (ty == 1 or ty == 39) {
            const v: f32 = @bitCast(std.mem.readInt(u32, nd[52..56], .little));
            if (!(v >= 1) or v > 100000) continue;
            const im: usize = @as(usize, @intFromFloat(v)) - 1;
            if (im >= images.count) continue;
            if (im >= NIMG or images.list[im].b8.len == 0) return false;
        }
    }
    return true;
}

/// The materials the scene's triangles use.
fn usedMaterials(used: *[material.MAX + 1]bool) void {
    used.* = @splat(false);
    for (hive.mats) |k| used[@min(k, material.MAX)] = true;
}

fn hasGraphs(used: *const [material.MAX + 1]bool) bool {
    for (hive.mat_list, 0..) |*ma, i| {
        if (used[i + 1] and ma.nodes() != 0) return true;
    }
    return false;
}

fn allGraphsOk(used: *const [material.MAX + 1]bool) bool {
    for (hive.mat_list, 0..) |*ma, i| {
        if (used[i + 1] and !graphOk(ma)) return false;
    }
    return true;
}

fn useRtx() bool {
    return gpu.hasRtx() and gpu.device != .gpu and hive.tris.len > 0 and hive.tris.len < 1 << 27;
}

/// The kernel + 1: 1 pt, 3 ptg; RTX: 4 ptr, 5 ptgr.
fn kernelFor(graphs: bool) u32 {
    if (useRtx()) return if (graphs) 5 else 4;
    return if (graphs) 3 else 1;
}

// --- the BVH, four wide -----------------------------------------------------------------------

const inf = std.math.inf(f32);
const N4 = extern struct {
    b: [24]f32 = @splat(0),
    child: [4]u32 = @splat(0xffffffff),
    pad: [4]u32 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(N4) == 128);
}

fn setBox(n: *N4, c: usize, lo: m.V3, hi: m.V3) void {
    for (0..3) |ax| {
        n.b[ax * 8 + c] = lo[ax];
        n.b[ax * 8 + 4 + c] = hi[ax];
    }
}

fn leafRef(first: u32, count: u32) u32 {
    return 0x80000000 | count << 27 | first;
}

fn area(n: *const hive.Node) f32 {
    const d = m.sub(n.hi, n.lo);
    return d[0] * d[1] + d[1] * d[2] + d[2] * d[0];
}

/// Hive's binary tree collapsed: each node takes in its children's children
/// while it has room, the largest first. Null: out of memory.
fn collapse() ?[]N4 {
    const nt = hive.tris.len;
    if (nt == 0) return &.{};
    const out = A.alloc(N4, nt * 2 + 2) catch return null;
    var n: u32 = 1;
    const T = struct { h: u32, k: u32 };
    var stack: std.ArrayList(T) = .empty;
    defer stack.deinit(A);
    stack.append(A, .{ .h = 0, .k = 0 }) catch return null;
    while (stack.pop()) |t| {
        const nd4 = &out[t.k];
        nd4.* = .{};
        const root = &hive.nodes[t.h];
        // a big leaf (only when it could not be split): up to four parts of 15
        if (root.count > 15) {
            var first = root.index;
            var left = root.count;
            var c: usize = 0;
            while (left > 0 and c < 4) : (c += 1) {
                const k = @min(left, 15);
                setBox(nd4, c, root.lo, root.hi);
                nd4.child[c] = leafRef(first, k);
                first += k;
                left -= k;
            }
            continue;
        }
        var e: [4]u32 = undefined;
        var ne: usize = 0;
        if (root.count > 0) {
            e[0] = t.h;
            ne = 1;
        } else {
            e[0] = root.index;
            e[1] = root.index + 1;
            ne = 2;
        }
        while (ne < 4) {
            var best: ?usize = null;
            var ba: f32 = -1;
            for (e[0..ne], 0..) |h, i| {
                const x = &hive.nodes[h];
                if (x.count == 0 and area(x) > ba) {
                    ba = area(x);
                    best = i;
                }
            }
            const b = best orelse break;
            const l = hive.nodes[e[b]].index;
            e[b] = l;
            e[ne] = l + 1;
            ne += 1;
        }
        for (e[0..ne], 0..) |h, c| {
            const x = &hive.nodes[h];
            setBox(nd4, c, x.lo, x.hi);
            if (x.count > 0 and x.count <= 15) {
                nd4.child[c] = leafRef(x.index, x.count);
            } else {
                nd4.child[c] = n;
                stack.append(A, .{ .h = h, .k = n }) catch return null;
                n += 1;
            }
        }
    }
    return out[0..n];
}

// --- into a slot ----------------------------------------------------------------------------------

/// Blocks lo .. hi of a binding into the slot; with marks, only those that
/// differ, each marked.
const CopyJob = struct {
    dst: []u8,
    src: []const u8,
    marks: []u8,
    fn run(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
        const j: *const CopyJob = @ptrCast(@alignCast(ctx));
        if (j.marks.len == 0) {
            const a = lo * BLK;
            const e = @min(hi * BLK, j.src.len);
            @memcpy(j.dst[a..e], j.src[a..e]);
            return;
        }
        for (lo..hi) |bi| {
            const o = bi * BLK;
            const n = @min(BLK, j.src.len - o);
            const same = std.mem.eql(u8, j.dst[o..][0..n], j.src[o..][0..n]);
            j.marks[bi] = @intFromBool(!same);
            if (!same) @memcpy(j.dst[o..][0..n], j.src[o..][0..n]);
        }
    }
};

const Put = struct {
    u: *Up,
    base: [*]u8,
    tab: *[ipc.GPU_MAXBIND]ipc.Binding,
    delta: bool,
    nr: u32 = 0,
    sent: u64 = 0,

    /// Binding b's bytes: when the device holds the layout, only what differs goes.
    /// The copy (and the look for what differs) runs on every thread: a scene
    /// of a million triangles is some 200 MB.
    fn put(p: *Put, b: usize, src: []const u8) void {
        const t = &p.tab[b];
        const off = p.u.off[b];
        const dst = p.base[off..][0..src.len];
        t.flags = ipc.GBF_IN;
        t.r0 = 0;
        t.rn = 0;
        const nblk = (src.len + BLK - 1) / BLK;
        // (no memory for the marks: all of it goes)
        const marks: []u8 = if (p.delta) A.alloc(u8, nblk) catch &.{} else &.{};
        defer if (marks.len > 0) A.free(marks);
        var job = CopyJob{ .dst = dst, .src = src, .marks = marks };
        jobs.parallelFor(nblk, 64, &job, CopyJob.run);
        if (!p.delta or (nblk > 0 and marks.len == 0)) {
            p.sent += src.len;
            return;
        }
        const first = p.nr;
        var start: ?u64 = null;
        var last: u64 = 0;
        var whole = false;
        for (marks, 0..) |mk, bi| {
            if (mk == 0) continue;
            const o: u64 = bi * BLK;
            const n = @min(BLK, src.len - o);
            if (start != null and o - last <= GAP) {
                last = o + n;
                continue;
            }
            if (start) |s| {
                if (!p.range(off + s, last - s)) whole = true;
            }
            start = o;
            last = o + n;
        }
        if (start) |s| {
            if (!p.range(off + s, last - s)) whole = true;
        }
        if (whole) {
            // (too many ranges: all of it)
            p.nr = first;
            p.sent += src.len;
            return;
        }
        t.flags = ipc.GBF_IN | ipc.GBF_DELTA;
        t.r0 = first;
        t.rn = p.nr - first;
    }

    fn range(p: *Put, off: u64, n: u64) bool {
        if (p.nr >= ipc.GPU_MAXRANGE) return false;
        const r: [*]align(1) [2]u64 = @ptrCast(p.base + ipc.GPU_RANGES);
        r[p.nr] = .{ off, n };
        p.nr += 1;
        p.sent += n;
        return true;
    }
};

pub fn imgKey() u64 {
    var hs = std.hash.Wyhash.init(0x696d67);
    for (images.list[0..@min(images.count, NIMG)]) |*e| {
        hs.update(std.mem.asBytes(&e.version));
        hs.update(std.mem.asBytes(&e.img.w));
        hs.update(std.mem.asBytes(&e.img.h));
    }
    return hs.final() | 1;
}

pub fn imgBytes() u64 {
    var n: u64 = NIMG * 16;
    for (images.list[0..@min(images.count, NIMG)]) |*e| {
        if (e.b8.len > 0) n += @as(u64, e.img.w) * e.img.h * 4;
    }
    return n;
}

/// Binding 15: NIMG x (texel offset, w, h, format), then 0xAARRGGBB texels.
fn imgPut(p: *Put) void {
    const u = p.u;
    const b = ipc.B_IMG;
    const key = imgKey();
    p.tab[b].flags = 0;
    if (p.delta and u.img_key == key) return;
    u.img_key = key;
    imgInto(p.base + u.off[b]);
    p.tab[b].flags = ipc.GBF_IN;
    p.sent += u.bytes[b];
}

/// The images there, as graph.glsl reads them.
pub fn imgInto(mem: [*]u8) void {
    const dst: [*]align(1) u32 = @ptrCast(mem);
    var at: u32 = NIMG * 4;
    @memset(dst[0 .. NIMG * 4], 0);
    for (images.list[0..@min(images.count, NIMG)], 0..) |*e, i| {
        if (e.b8.len == 0) continue;
        dst[i * 4] = at - NIMG * 4;
        dst[i * 4 + 1] = e.img.w;
        dst[i * 4 + 2] = e.img.h;
        for (e.b8, 0..) |t, k| dst[at + k] = @as(u32, t[3]) << 24 | @as(u32, t[0]) << 16 | @as(u32, t[1]) << 8 | t[2];
        at += @intCast(e.b8.len);
    }
}

/// Bindings 17, 18: the HDRI's texels (rgb floats), its tables behind a header.
fn envPut(p: *Put) void {
    const u = p.u;
    p.tab[ipc.B_ENVIMG].flags = 0;
    p.tab[ipc.B_ENVCDF].flags = 0;
    if (!pt.use_env) return;
    const t = env.tables() orelse return;
    var hs = std.hash.Wyhash.init(0x656e76);
    hs.update(std.mem.asBytes(&t.version));
    hs.update(std.mem.asBytes(&t.w));
    hs.update(std.mem.asBytes(&t.h));
    hs.update(std.mem.asBytes(&t.strength));
    hs.update(std.mem.asBytes(&t.rotation));
    const key = hs.final() | 1;
    if (p.delta and u.env_key == key) return;
    u.env_key = key;
    const dst: [*]align(1) f32 = @ptrCast(p.base + u.off[ipc.B_ENVIMG]);
    for (t.px, 0..) |c, i| {
        dst[i * 3] = c[0];
        dst[i * 3 + 1] = c[1];
        dst[i * 3 + 2] = c[2];
    }
    const cdf: [*]align(1) f32 = @ptrCast(p.base + u.off[ipc.B_ENVCDF]);
    const w32: [*]align(1) u32 = @ptrCast(cdf);
    w32[0] = t.w;
    w32[1] = t.h;
    cdf[2] = t.total;
    cdf[3] = t.rotation;
    cdf[4] = t.strength;
    @memcpy(cdf[8..][0..t.cond.len], t.cond);
    @memcpy(cdf[8 + t.cond.len..][0..t.marg.len], t.marg);
    p.tab[ipc.B_ENVIMG].flags = ipc.GBF_IN;
    p.tab[ipc.B_ENVCDF].flags = ipc.GBF_IN;
    p.sent += u.bytes[ipc.B_ENVIMG] + u.bytes[ipc.B_ENVCDF];
}

fn isFixed(i: usize) bool {
    return i == ipc.B_PARAMS or i == ipc.B_ACCUM or i == ipc.B_AUX or i == ipc.B_M2;
}

/// The scene as Hive has it now goes to the slot (at the next run). `plain`:
/// materials whose graphs pt.comp lacks are sent with their values alone (the
/// live view; renders stay on the CPU instead). False: the helper or memory failed.
pub fn put(si: usize, w: u32, h: u32, plain: bool) bool {
    if (!gpu.isUp() or gpu.busy()) return false;
    const u = &ups[si];
    var used: [material.MAX + 1]bool = undefined;
    usedMaterials(&used);
    const n4 = collapse() orelse return false;
    defer if (n4.len > 0) A.free(n4.ptr[0 .. hive.tris.len * 2 + 2]);
    const graphs = hasGraphs(&used);
    const kern = kernelFor(graphs);
    const rtx = kern >= 4;
    const nt: u64 = hive.tris.len;
    const px = @as(u64, w) * h;
    var sz: [ipc.PT_NTAB]u64 = @splat(16);
    sz[ipc.B_PARAMS] = PARAM_WORDS * 4;
    sz[ipc.B_TV] = nt * 36;
    sz[ipc.B_TN] = nt * 36;
    sz[ipc.B_TM] = nt * 4;
    sz[ipc.B_TC] = nt * 12;
    sz[ipc.B_MA] = (@as(u64, hive.mat_list.len) + 1) * material.REC;
    sz[ipc.B_ND] = @as(u64, n4.len) * 128;
    sz[ipc.B_LCDF] = @as(u64, pt.lcdf.len) * 4;
    sz[ipc.B_LTRI] = @as(u64, pt.ltri.len) * 4;
    sz[ipc.B_LSEL] = nt * 4;
    sz[ipc.B_ACCUM] = px * 12;
    sz[ipc.B_AUX] = px * (if (si == ipc.SLOT_LIVE) @as(u64, LIVE_AUX) else 28);
    sz[ipc.B_M2] = px * 4;
    sz[ipc.B_TO] = nt * 36;
    sz[ipc.B_TUV] = nt * 24;
    if (graphs) sz[ipc.B_IMG] = imgBytes();
    if (pt.use_env) {
        if (env.tables()) |t| {
            sz[ipc.B_ENVIMG] = @as(u64, t.w) * t.h * 12;
            sz[ipc.B_ENVCDF] = (8 + t.cond.len + t.marg.len) * 4;
        }
    }
    if (rtx) sz[ipc.B_VP] = nt * 36;
    for (&sz) |*s| s.* = @max(s.*, 16);

    // where: as last time when it fits
    var fits = u.ok and u.w == w and u.h == h;
    for (sz, 0..) |s, i| {
        if (s > u.cap[i]) fits = false;
    }
    var total: u64 = ipc.GPU_DATA0;
    if (!fits) {
        for (sz, 0..) |s, i| {
            const cap = if (isFixed(i)) s else s + s / 8;
            u.off[i] = total;
            u.cap[i] = cap;
            total = alignUp(total + cap, ipc.GPU_ALIGN);
        }
    } else total = u.off[ipc.PT_NTAB - 1] + u.cap[ipc.PT_NTAB - 1];
    var fresh = false;
    const base = gpu.slot(si, total, &fresh) orelse return false;
    if (fresh or !fits) {
        u.ok = false;
        u.img_key = 0;
        u.env_key = 0;
    }
    u.w = w;
    u.h = h;
    u.bytes = sz;
    u.kern = kern;
    u.nbind = if (rtx) ipc.PT_NTAB else ipc.PT_NBIND;
    const tab: *[ipc.GPU_MAXBIND]ipc.Binding = @ptrCast(@alignCast(base));
    for (0..ipc.PT_NTAB) |i| tab[i] = .{ .off = u.off[i], .bytes = sz[i], .flags = 0 };
    var p = Put{ .u = u, .base = base, .tab = tab, .delta = u.ok };

    p.put(ipc.B_TV, std.mem.sliceAsBytes(hive.tris));
    p.put(ipc.B_TN, std.mem.sliceAsBytes(hive.norms));
    p.put(ipc.B_TO, std.mem.sliceAsBytes(hive.obj_tris));
    p.put(ipc.B_TUV, std.mem.sliceAsBytes(hive.tuv));
    p.put(ipc.B_TC, std.mem.sliceAsBytes(hive.tvc));
    p.put(ipc.B_ND, std.mem.sliceAsBytes(n4));
    p.put(ipc.B_LCDF, std.mem.sliceAsBytes(pt.lcdf));
    p.put(ipc.B_LTRI, std.mem.sliceAsBytes(pt.ltri));
    p.put(ipc.B_LSEL, std.mem.sliceAsBytes(pt.lsel));
    {
        const tm = A.alloc(u32, nt) catch return false;
        defer A.free(tm);
        for (hive.mats, tm) |a, *b| b.* = a;
        p.put(ipc.B_TM, std.mem.sliceAsBytes(tm));
    }
    {
        // the records, whole: record 0 stays zeros (a triangle's material + 1)
        const mt = A.alloc(u8, sz[ipc.B_MA]) catch return false;
        defer A.free(mt);
        @memset(mt[0..material.REC], 0);
        @memcpy(mt[material.REC..], std.mem.sliceAsBytes(hive.mat_list));
        if (plain) {
            const recs: [*]material.Material = @ptrCast(@alignCast(mt.ptr + material.REC));
            for (recs[0..hive.mat_list.len]) |*ma| {
                if (!graphOk(ma)) @memset(ma.graph[0..4], 0);
            }
        }
        p.put(ipc.B_MA, mt);
    }
    if (graphs) imgPut(&p);
    envPut(&p);

    // the constants
    const w0: [*]align(1) u32 = @ptrCast(base + u.off[ipc.B_PARAMS]);
    const f0: [*]align(1) f32 = @ptrCast(w0);
    @memset(w0[0..PARAM_WORDS], 0);
    w0[0] = w;
    w0[1] = h;
    w0[5] = pt.nslots;
    w0[6] = @intCast(pt.lights.len);
    w0[7] = @intCast(pt.lcdf.len);
    w0[8] = @intCast(nt);
    w0[11] = @intFromBool(hive.cut);
    w0[ipc.P_CAM + 15] = pt.bounces;
    for (pt.lights, 0..) |*l, i| {
        const o = ipc.P_HEAD + i * 16;
        f0[o..][0..3].* = l.pos;
        f0[o + 3 ..][0..3].* = l.I;
        f0[o + 6] = @floatFromInt(@intFromEnum(l.kind));
        f0[o + 7] = l.size;
        f0[o + 8 ..][0..3].* = l.dir;
        f0[o + 11] = l.cos_out;
        f0[o + 12 ..][0..3].* = l.u;
        f0[o + 15] = l.cos_in;
    }
    f0[ipc.P_HEAD + MAX_LIGHTS * 16..][0..256].* = texture.lut;
    u.sent_kib = p.sent / 1024;
    u.first = true;
    return true;
}

/// The scene can go: lights fit, triangles fit a leaf reference.
fn sceneFits() Why {
    if (pt.lights.len > MAX_LIGHTS) return .lights;
    if (hive.tris.len >= 1 << 27) return .big;
    return .gpu;
}

/// The live view can take this scene (its graphs may go plain).
pub fn liveFits() bool {
    return sceneFits() == .gpu;
}

/// The camera, the pass's samples, flags (cam[14]): the next run's constants.
fn constants(si: usize, base: [*]u8, flags: u32, first: u32, count: u32, c: *const pt.Camera) void {
    const u = &ups[si];
    const w0: [*]align(1) u32 = @ptrCast(base + u.off[ipc.B_PARAMS]);
    const f0: [*]align(1) f32 = @ptrCast(w0);
    w0[2] = first;
    w0[3] = count;
    w0[4] = @truncate(pt.seed);
    w0[10] = @truncate(pt.seed >> 32);
    f0[ipc.P_CAM..][0..3].* = c.o;
    f0[ipc.P_CAM + 3 ..][0..3].* = c.right;
    f0[ipc.P_CAM + 6 ..][0..3].* = c.up;
    f0[ipc.P_CAM + 9 ..][0..3].* = c.fwd;
    f0[ipc.P_CAM + 12] = c.tan_h;
    w0[ipc.P_CAM + 14] = flags | (if (pt.use_env) @as(u32, 32) else 0);
}

/// A run of the slot's kernel: only sent (the reply: gpu.pump). `outs`: bits of
/// bindings to read back.
pub fn run(si: usize, flags: u32, first: u32, count: u32, c: *const pt.Camera, outs: u32) bool {
    const u = &ups[si];
    const base = gpu.slots[si].base orelse return false;
    if (gpu.busy()) return false;
    const tab: *[ipc.GPU_MAXBIND]ipc.Binding = @ptrCast(@alignCast(base));
    constants(si, base, flags, first, count, c);
    if (!u.first) {
        for (tab[0..ipc.PT_NTAB]) |*t| t.flags = 0;
    }
    tab[ipc.B_PARAMS].flags = ipc.GBF_IN;
    tab[ipc.B_PARAMS].r0 = 0;
    tab[ipc.B_PARAMS].rn = 0;
    tab[ipc.B_ACCUM].flags = if ((outs >> ipc.B_ACCUM) & 1 != 0) ipc.GBF_OUT else 0;
    tab[ipc.B_AUX].flags = if ((outs >> ipc.B_AUX) & 1 != 0) ipc.GBF_OUT else 0;
    tab[ipc.B_M2].flags = if ((outs >> ipc.B_M2) & 1 != 0) ipc.GBF_OUT else 0;
    if (!gpu.runSend(si, u.nbind, (u.w + 7) / 8, (u.h + 7) / 8, u.kern)) return false;
    u.first = false;
    u.ok = true; // (a failure ends the helper, and with it all of this)
    return true;
}

/// The live slot's pixels, as the last run left them.
pub fn pixels(si: usize) ?[]const u32 {
    const u = &ups[si];
    const base = gpu.slots[si].base orelse return null;
    const p: [*]const u32 = @ptrCast(@alignCast(base + u.off[ipc.B_M2]));
    return p[0 .. @as(usize, u.w) * u.h];
}

/// The helper is gone: nothing of the slots is left.
pub fn forget() void {
    ups = @splat(.{});
}

// --- F12 ----------------------------------------------------------------------------------------

/// This render's passes run on the GPU.
pub var on = false;
var done: u32 = 0;
var flying: u32 = 0; // samples in flight
var batch: u32 = 1;
var sent_at: i64 = 0;
var gen: u32 = 0;
/// A batch this long (ms): the Render area keeps moving.
pub var batch_ms: i64 = 100;

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// "GPU (RTX)", "GPU" or "CPU": where this or the last render ran.
pub fn whereShort() []const u8 {
    if (on or why == .gpu) return if (last_rtx) "GPU (RTX)" else "GPU";
    return "CPU";
}

/// The render just set up on the CPU's film: its passes go to the GPU if they can.
/// `wait_ms`: for a helper still starting.
pub fn begin(wait_ms: i32) bool {
    on = false;
    last_rtx = false;
    last_kib = 0;
    if (gpu.device == .cpu) {
        why = .device_cpu;
        return false;
    }
    if (!gpu.ready(wait_ms)) {
        why = .no_helper;
        return false;
    }
    var used: [material.MAX + 1]bool = undefined;
    usedMaterials(&used);
    if (!allGraphsOk(&used)) {
        why = .node;
        return false;
    }
    const fits = sceneFits();
    if (fits != .gpu) {
        why = fits;
        return false;
    }
    // a batch of a render stopped before this one: its reply first
    if (!gpu.runWait(@min(wait_ms, 3000)) or !gpu.isUp()) {
        why = if (gpu.isUp()) .busy else .failed;
        return false;
    }
    if (!put(ipc.SLOT_PT, pt.fw, pt.fh, false)) {
        why = if (gpu.isUp()) .no_memory else .failed;
        return false;
    }
    last_rtx = ups[ipc.SLOT_PT].kern >= 4;
    last_kib = ups[ipc.SLOT_PT].sent_kib;
    on = true;
    why = .gpu;
    done = 0;
    flying = 0;
    batch = 1;
    gen = gpu.lost;
    return true;
}

const Copy = struct { aux: [*]const f32 };

fn copyRows(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const job: *const Copy = @ptrCast(@alignCast(ctx));
    for (lo * pt.fw..hi * pt.fw) |i| {
        const a = job.aux[i * 7..][0..7];
        pt.alb[i] = a[0..3].*;
        pt.nrm[i] = a[3..6].*;
        pt.dep[i] = a[6];
    }
}

/// A finished batch: the sums into the film, every row counts it.
fn take(s: u32) void {
    const u = &ups[ipc.SLOT_PT];
    const base = gpu.slots[ipc.SLOT_PT].base.?;
    const ac: [*]align(1) const [3]f32 = @ptrCast(base + u.off[ipc.B_ACCUM]);
    @memcpy(pt.accum, ac[0..pt.accum.len]);
    const m2: [*]align(1) const f32 = @ptrCast(base + u.off[ipc.B_M2]);
    @memcpy(pt.m2, m2[0..pt.m2.len]);
    var job = Copy{ .aux = @ptrCast(@alignCast(base + u.off[ipc.B_AUX])) };
    jobs.parallelFor(pt.fh, 16, &job, copyRows);
    done += s;
    @memset(pt.row_spp, done);
    n_runs +%= 1;
    n_spp +%= s;
}

/// Path tracer runs and the samples they traced, since the start (gpu(2), gpu(4):
/// gpu.s g_npt, g_spp).
pub var n_runs: u32 = 0;
pub var n_spp: u32 = 0;

fn failed() void {
    on = false;
    why = .failed;
    forget();
    app.log("  render: the GPU failed: {d} samples kept, the rest on the CPU", .{done});
}

/// Work for about `budget` ms. True while samples remain. `on` goes off when the
/// CPU has to take over (the film is whole up to the last batch).
pub fn tick(budget: i32) bool {
    const t0 = nowMs();
    while (true) {
        if (!on) return true;
        if (gpu.lost != gen or !gpu.isUp()) {
            failed();
            return true;
        }
        if (flying > 0) {
            const left: i64 = @as(i64, budget) - (nowMs() - t0);
            if (!gpu.runWait(@intCast(@max(left, 0)))) return true;
            if (gpu.lost != gen or !gpu.isUp()) continue;
            const took = nowMs() - sent_at;
            const s = flying;
            flying = 0;
            take(s);
            if (done >= pt.target) {
                on = false;
                return false;
            }
            if (took * 2 < batch_ms) batch = @min(batch * 2, 256) else if (took > batch_ms * 2 and batch > 1) batch /= 2;
        }
        const n = @min(batch, pt.target - done);
        sent_at = nowMs();
        if (!run(ipc.SLOT_PT, 0, done, n, &pt.cam, 1 << ipc.B_ACCUM | 1 << ipc.B_AUX | 1 << ipc.B_M2)) {
            // (a run of the live view in flight: its turn ends soon)
            if (gpu.isUp() and !gpu.runWait(budget)) return true;
            continue;
        }
        flying = n;
        if (nowMs() - t0 >= budget) return true;
    }
}

/// A turn of the render, wherever it runs. True while samples remain.
pub fn turn(budget: i32, now: *const fn () i64) bool {
    var more = true;
    if (on) more = tick(budget);
    // (the helper lost in that turn: on from where the film is, the same streams)
    if (!on and more) more = pt.tick(budget, now);
    return more;
}

/// Esc: the samples so far stay; the batch out is dropped.
pub fn stop() void {
    on = false;
    flying = 0;
}
