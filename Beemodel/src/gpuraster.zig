// The viewport rasterizer's last stage on the GPU (raster.s + gpu_rs_tiles): the
// frame's triangles are set up and binned into 16 x 16 tiles here, and raster.comp
// fills depth, ids and colour exactly as gfx.Canvas.triangle would. By default only
// frames with objects drawn through cluster DAGs use it (Solid: Material Preview's
// per-pixel normals stay on the CPU); BEEMODEL_GPU_RASTER=all sends every frame's
// meshes too, off none. Whatever the GPU cannot take in time is drawn by the CPU
// from the same records, so a frame never waits long and never misses a triangle.
const std = @import("std");
const gfx = @import("gfx.zig");
const gpu = @import("gpu.zig");
const ipc = @import("gpu/ipc.zig");
const spawn = @import("spawn.zig");
const jobs = @import("jobs.zig");
const Rect = gfx.Rect;
const A = std.heap.page_allocator;

const REC = 12; // words a triangle: x y 1/z x3, colour, id, -
const WAIT_MS = 100;

const Mode = enum { unread, auto, all, off };
var mode: Mode = .unread;
var recs: []f32 = &.{};
var n_rec: usize = 0;
var toff: []u32 = &.{};
var ents: []u32 = &.{};
var slot_ok = false;

/// frames the GPU rasterized; batches the CPU had to take
pub var nbatch: u32 = 0;
pub var nfall: u32 = 0;

fn readMode() void {
    if (mode != .unread) return;
    mode = .auto;
    if (spawn.getenv("BEEMODEL_GPU_RASTER")) |v| {
        if (std.mem.eql(u8, v, "all")) mode = .all;
        if (std.mem.eql(u8, v, "off")) mode = .off;
    }
}

/// A DAG batch goes to the GPU: the helper is up (BEEMODEL_GPU_RASTER=all waits
/// for it; else a frame never does).
pub fn wanted() bool {
    readMode();
    if (mode == .off or gpu.device == .cpu) return false;
    if (mode == .all) return gpu.ready(if (@import("files.zig").headless) 15000 else 0);
    return gpu.isUp();
}

/// Every mesh of the frame too.
pub fn wantedAll() bool {
    readMode();
    return mode == .all and wanted();
}

pub fn begin() bool {
    n_rec = 0;
    gfx.sink = add;
    return true;
}

fn add(p0: [3]f32, p1: [3]f32, p2: [3]f32, col: u32, id: u16) void {
    if ((n_rec + 1) * REC > recs.len) {
        const nn = @max(recs.len * 2, 1 << 16);
        const b = A.alloc(f32, nn) catch return drawNow(p0, p1, p2, col, id);
        @memcpy(b[0 .. n_rec * REC], recs[0 .. n_rec * REC]);
        if (recs.len > 0) A.free(recs);
        recs = b;
    }
    const o = recs[n_rec * REC..][0..REC];
    o[0..3].* = p0;
    o[3..6].* = p1;
    o[6..9].* = p2;
    o[9] = @bitCast(col);
    o[10] = @bitCast(@as(u32, id));
    o[11] = 0;
    n_rec += 1;
}

var cur_cv: ?*gfx.Canvas = null;

fn drawNow(p0: [3]f32, p1: [3]f32, p2: [3]f32, col: u32, id: u16) void {
    // (no memory for records: this one the CPU's, now)
    const s = gfx.sink;
    gfx.sink = null;
    if (cur_cv) |cv| cv.triangle(p0, p1, p2, col, id);
    gfx.sink = s;
}

pub fn setCanvas(cv: *gfx.Canvas) void {
    cur_cv = cv;
}

/// The CPU draws the records (the GPU could not).
fn fallback(cv: *gfx.Canvas, r: Rect) void {
    nfall += 1;
    const old = cv.setClip(r);
    defer cv.clip = old;
    for (0..n_rec) |i| {
        const o = recs[i * REC..][0..REC];
        cv.triangle(o[0..3].*, o[3..6].*, o[6..9].*, @bitCast(o[9]), @intCast(@as(u32, @bitCast(o[10]))));
    }
}

fn bin(ntx: usize, nty: usize, r: Rect) bool {
    const nt = ntx * nty;
    if (toff.len < nt + 2) {
        if (toff.len > 0) A.free(toff);
        toff = A.alloc(u32, nt + 2) catch {
            toff = &.{};
            return false;
        };
    }
    const off = toff[0 .. nt + 2];
    @memset(off, 0);
    const Span = struct {
        fn of(o: []const f32, rr: Rect, n_x: usize, n_y: usize) ?[4]usize {
            const a = @min(o[0], @min(o[3], o[6]));
            const b = @max(o[0], @max(o[3], o[6]));
            const c = @min(o[1], @min(o[4], o[7]));
            const d = @max(o[1], @max(o[4], o[7]));
            if (!(b >= @as(f32, @floatFromInt(rr.x)) and a < @as(f32, @floatFromInt(rr.right())) and d >= @as(f32, @floatFromInt(rr.y)) and c < @as(f32, @floatFromInt(rr.bottom())))) return null;
            const x0: i32 = @max(@as(i32, @intFromFloat(@floor(@max(a, -40000)))) - rr.x, 0);
            const x1: i32 = @min(@as(i32, @intFromFloat(@ceil(@min(b, 40000)))) - rr.x, rr.w - 1);
            const y0: i32 = @max(@as(i32, @intFromFloat(@floor(@max(c, -40000)))) - rr.y, 0);
            const y1: i32 = @min(@as(i32, @intFromFloat(@ceil(@min(d, 40000)))) - rr.y, rr.h - 1);
            if (x0 > x1 or y0 > y1) return null;
            return .{ @min(@as(usize, @intCast(x0)) / 16, n_x - 1), @min(@as(usize, @intCast(x1)) / 16, n_x - 1), @min(@as(usize, @intCast(y0)) / 16, n_y - 1), @min(@as(usize, @intCast(y1)) / 16, n_y - 1) };
        }
    };
    var total: usize = 0;
    for (0..n_rec) |i| {
        const s = Span.of(recs[i * REC..][0..REC], r, ntx, nty) orelse continue;
        for (s[2]..s[3] + 1) |y| {
            for (s[0]..s[1] + 1) |x| {
                off[y * ntx + x + 2] += 1;
                total += 1;
            }
        }
    }
    if (ents.len < total) {
        if (ents.len > 0) A.free(ents);
        ents = A.alloc(u32, @max(total + total / 4, 4096)) catch {
            ents = &.{};
            return false;
        };
    }
    for (2..nt + 2) |k| off[k] += off[k - 1];
    for (0..n_rec) |i| {
        const s = Span.of(recs[i * REC..][0..REC], r, ntx, nty) orelse continue;
        for (s[2]..s[3] + 1) |y| {
            for (s[0]..s[1] + 1) |x| {
                const q = y * ntx + x + 1;
                ents[off[q]] = @intCast(i);
                off[q] += 1;
            }
        }
    }
    return true;
}

const Rows = struct { cv: *gfx.Canvas, r: Rect, d: [*]align(1) f32, i: [*]align(1) u32, c: [*]align(1) u32, back: bool };

fn rowJob(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *const Rows = @ptrCast(@alignCast(ctx));
    const w: usize = @intCast(j.r.w);
    const cv = j.cv;
    const zb = cv.zbuf.?;
    const ids = cv.ids.?;
    for (lo..hi) |y| {
        const o: usize = @intCast((@as(i32, @intCast(y)) + j.r.y) * cv.w + j.r.x);
        const s = y * w;
        if (j.back) {
            @memcpy(zb[o..][0..w], j.d[s..][0..w]);
            @memcpy(cv.px[o..][0..w], j.c[s..][0..w]);
            for (0..w) |k| ids[o + k] = @truncate(j.i[s + k]);
        } else {
            @memcpy(j.d[s..][0..w], zb[o..][0..w]);
            @memcpy(j.c[s..][0..w], cv.px[o..][0..w]);
            for (0..w) |k| j.i[s + k] = ids[o + k];
        }
    }
}

/// The records go through the tile stage onto the canvas (rect r, already inside it).
pub fn flush(cv: *gfx.Canvas, r: Rect) void {
    gfx.sink = null;
    if (n_rec == 0 or r.w <= 0 or r.h <= 0) return;
    if (!send(cv, r)) fallback(cv, r);
    n_rec = 0;
}

fn send(cv: *gfx.Canvas, r: Rect) bool {
    if (cv.zbuf == null or cv.ids == null) return false;
    gpu.pump(0);
    if (!gpu.isUp() or gpu.busy()) return false;
    const w: usize = @intCast(r.w);
    const h: usize = @intCast(r.h);
    const ntx = (w + 15) / 16;
    const nty = (h + 15) / 16;
    if (n_rec * REC * 4 > 1 << 31) return false;
    if (!bin(ntx, nty, r)) return false;
    const nt = ntx * nty;
    const nent: usize = toff[nt];
    const px = w * h * 4;
    const sz = [ipc.RS_NB]u64{ 32, n_rec * REC * 4, (nt + 1) * 4, @max(nent, 1) * 4, px, px, px, px };
    var off: [ipc.RS_NB]u64 = undefined;
    var tot: u64 = ipc.GPU_DATA0;
    for (sz, 0..) |s, i| {
        off[i] = tot;
        tot = (tot + s + ipc.GPU_ALIGN - 1) & ~@as(u64, ipc.GPU_ALIGN - 1);
    }
    var fresh = false;
    const base = gpu.slot(ipc.RS_SLOT, tot, &fresh) orelse return false;
    const tab: *[ipc.GPU_MAXBIND]ipc.Binding = @ptrCast(@alignCast(base));
    for (0..ipc.RS_NB) |i| tab[i] = .{ .off = off[i], .bytes = sz[i], .flags = ipc.GBF_IN };
    tab[ipc.RS_VIS].flags = 0;
    tab[ipc.RS_DEPTH].flags = ipc.GBF_IN | ipc.GBF_OUT;
    tab[ipc.RS_IDS].flags = ipc.GBF_IN | ipc.GBF_OUT;
    tab[ipc.RS_COL].flags = ipc.GBF_IN | ipc.GBF_OUT;
    const p: [*]align(1) u32 = @ptrCast(base + off[0]);
    p[0] = @intCast(w);
    p[1] = @intCast(h);
    p[2] = @intCast(ntx);
    p[3] = 0;
    p[4] = @bitCast(r.x);
    p[5] = @bitCast(r.y);
    p[6] = 0;
    p[7] = 0;
    @memcpy((base + off[1])[0 .. n_rec * REC * 4], std.mem.sliceAsBytes(recs[0 .. n_rec * REC]));
    @memcpy((base + off[2])[0 .. (nt + 1) * 4], std.mem.sliceAsBytes(toff[0 .. nt + 1]));
    @memcpy((base + off[3])[0 .. nent * 4], std.mem.sliceAsBytes(ents[0..nent]));
    var job = Rows{ .cv = cv, .r = r, .d = @ptrCast(base + off[ipc.RS_DEPTH]), .i = @ptrCast(base + off[ipc.RS_IDS]), .c = @ptrCast(base + off[ipc.RS_COL]), .back = false };
    jobs.parallelFor(h, 16, &job, rowJob);
    if (!gpu.runSendN(ipc.RS_SLOT, ipc.RS_NB, @intCast(ntx), @intCast(nty), ipc.K_RASTER + 1, 0)) return false;
    // (headless, a first frame may still build the kernel)
    const wait: i32 = if (@import("files.zig").headless) 20000 else WAIT_MS;
    if (!gpu.runWait(wait) or !gpu.isUp()) return false;
    job.back = true;
    jobs.parallelFor(h, 16, &job, rowJob);
    nbatch += 1;
    return true;
}
