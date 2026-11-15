// The 3D viewport drawn by the GPU (gview.s): Solid and Material Preview in one
// render pass and one indirect call (view.vert, view.frag; slot 3). Each mesh's
// triangles stay on the GPU in object space and go up again only when a mesh
// changes; a frame sends the camera, a record per object and the materials. Colour
// comes back into the canvas where an object is, 1/z and the ids into its depth and
// id buffers, so wires, the outline and clicks work on top as before.
//
// The CPU's viewport stays the reference and the fallback: it draws without a
// helper, with BEEMODEL_GPU_VIEW=off, in edit mode, with cluster DAGs, with light
// probes in Material Preview, a shader graph the GPU lacks, over 4M triangles, and
// any frame the helper is busy or late for (a frame never waits long). Headless runs
// use it only with BEEMODEL_GPU_VIEW=on, so scenario images stay the CPU's.
const std = @import("std");
const linux = std.os.linux;
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const gpu = @import("gpu.zig");
const gp = @import("gpupt.zig");
const ipc = @import("gpu/ipc.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const mods = @import("mods.zig");
const preview = @import("preview.zig");
const texture = @import("texture.zig");
const spawn = @import("spawn.zig");
const jobs = @import("jobs.zig");
const vp = @import("viewport.zig");
const env = @import("env.zig");
const Rect = gfx.Rect;
const A = std.heap.page_allocator;

const MAX_TRIS = 4_000_000;
const WAIT_MS = 50;
const DRW = 32; // words a draw
const INW = 16; // words an instance
const PARAM_WORDS = 64 + 256;
const ENV_WORDS = 32 + 128 * 64 * 3;

/// viewport frames the GPU drew, the last one's time (us), KiB of meshes sent
pub var nframes: u32 = 0;
pub var last_us: i64 = 0;
pub var mesh_kib: u64 = 0;
pub var last_on = false;

const Mode = enum { unread, auto, on, off };
var mode: Mode = .unread;

var off: [ipc.GV_NB]u64 = @splat(0);
var cap: [ipc.GV_NB]u64 = @splat(0);
var tris_up: u64 = 0;
var key_up: u64 = 0;
var img_key: u64 = 0;
var env_key: u64 = 0;
var ok = false; // the device holds the meshes as the slot does
var gen: u32 = 0;

fn nowUs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

fn wanted() bool {
    if (mode == .unread) {
        mode = .auto;
        if (spawn.getenv("BEEMODEL_GPU_VIEW")) |v| {
            if (std.mem.eql(u8, v, "off")) mode = .off;
            if (std.mem.eql(u8, v, "on")) mode = .on;
        }
    }
    const headless = @import("files.zig").headless;
    if (mode == .off or gpu.device == .cpu) return false;
    if (@import("paint.zig").meshModes()) return false; // (painting: the weights' heat)
    if (headless and mode != .on) return false;
    if (!gpu.ready(if (headless) 15000 else 0)) return false;
    return gpu.hasGfx();
}

/// The objects as the CPU's loop takes them.
fn takes(o: *const scene.Object) bool {
    if (!o.visible or o.kind == .light or o.kind == .camera or o.kind == .armature or o.kind == .sketch or o.kind == .field) return false;
    if (@import("sculpt.zig").on and o.oid == @import("sculpt.zig").oid) return false; // (it draws itself)
    return o.ref == 0 and !o.isGround();
}

fn align256(x: u64) u64 {
    return (x + ipc.GPU_ALIGN - 1) & ~@as(u64, ipc.GPU_ALIGN - 1);
}

const Merge = struct { cv: *gfx.Canvas, r: Rect, c: [*]align(1) const u32, z: [*]align(1) const f32, id: [*]align(1) const u32 };

fn mergeRows(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *const Merge = @ptrCast(@alignCast(ctx));
    const cv = j.cv;
    const zb = cv.zbuf.?;
    const ids = cv.ids.?;
    const w: usize = @intCast(j.r.w);
    for (lo..hi) |y| {
        var o: usize = @intCast((@as(i32, @intCast(y)) + j.r.y) * cv.w + j.r.x);
        const s = y * w;
        for (0..w) |x| {
            const iz = j.z[s + x];
            if (iz > zb[o]) { // (what the CPU drew first, the grid, may be nearer)
                zb[o] = iz;
                ids[o] = @truncate(j.id[s + x]);
                cv.px[o] = j.c[s + x] & 0xffffff;
            }
            o += 1;
        }
    }
}

/// The meshes of the frame on the GPU. False: the CPU draws them.
pub fn draw(cv: *gfx.Canvas, r: Rect, c: *const vp.Cam, v: *const vp.View, mat_prev: bool) bool {
    last_on = false;
    if (v.wire or !wanted()) return false;
    const t0 = nowUs();
    if (@import("editmesh.zig").active) return false;
    if (mat_prev and @import("probe.zig").cur != null) return false;
    if (cv.zbuf == null or cv.ids == null or r.w <= 0 or r.h <= 0) return false;
    // (a viewport hanging off the canvas: the CPU clips it)
    if (r.x < 0 or r.y < 0 or r.right() > cv.w or r.bottom() > cv.h) return false;
    // (a late frame's reply: nothing goes to a slot in flight)
    if (gpu.busy() and !gpu.runWait(0)) return false;
    if (!gpu.isUp()) return false;
    if (gen != gpu.lost) {
        gen = gpu.lost;
        ok = false;
    }
    const vg = @import("vgeo.zig");
    const dags = vg.dagCount() != 0 and @import("vgdraw.zig").view_mode != 2;
    var ntri: u64 = 0;
    var ndraw: u32 = 0;
    var hs = std.hash.Wyhash.init(0x67766965);
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!takes(o)) continue;
        const me = mods.of(oi) orelse continue;
        if (dags and vg.of(me) != null) return false;
        if (mat_prev) {
            if (material.of(o)) |ma| {
                if (!gp.graphOk(ma)) return false;
            }
        }
        const k = [_]u64{ oi, @intFromPtr(me), me.serial, me.shape, me.tris.len, me.paints, me.vcol.len };
        hs.update(std.mem.asBytes(&k));
        ntri += me.tris.len;
        ndraw += 1;
    }
    if (ntri > MAX_TRIS) return false;
    const key = hs.final();
    const w: u64 = @intCast(r.w);
    const h: u64 = @intCast(r.h);
    const px = w * h * 4;

    var sz: [ipc.GV_NB]u64 = @splat(16);
    sz[ipc.GV_PAR] = PARAM_WORDS * 4;
    sz[ipc.GV_DRAW] = @max(@as(u64, ndraw) * DRW * 4, 16);
    sz[ipc.GV_IND] = @max(@as(u64, ndraw) * 16, 16);
    sz[ipc.GV_INST] = @max(@as(u64, ndraw) * INW * 4, 16);
    sz[ipc.GV_POS] = @max(ntri * 36, 16);
    sz[ipc.GV_NRM] = @max(ntri * 36, 16);
    sz[ipc.GV_UV] = @max(ntri * 24, 16);
    sz[ipc.GV_VC] = @max(ntri * 12, 16);
    sz[ipc.GV_MAT] = (@as(u64, material.count) + 1) * material.REC;
    sz[ipc.GV_IMG] = gp.imgBytes();
    sz[ipc.GV_ENV] = ENV_WORDS * 4;
    sz[ipc.GV_COL] = px;
    sz[ipc.GV_INVZ] = px;
    sz[ipc.GV_ID] = px;
    var fits = ok;
    for (sz, 0..) |s, i| {
        if (s > cap[i]) fits = false;
    }
    var total: u64 = ipc.GPU_DATA0;
    if (!fits) {
        for (sz, 0..) |s, i| {
            cap[i] = @max(s + s / 8, cap[i]);
            off[i] = total;
            total = align256(total + cap[i]);
        }
        ok = false;
    } else total = off[ipc.GV_NB - 1] + cap[ipc.GV_NB - 1];
    var fresh = false;
    const base = gpu.slot(ipc.GV_SLOT, total, &fresh) orelse return false;
    if (fresh) ok = false;
    const tab: *[ipc.GPU_MAXBIND]ipc.Binding = @ptrCast(@alignCast(base));
    for (0..ipc.GV_NB) |i| tab[i] = .{ .off = off[i], .bytes = sz[i], .flags = 0 };

    // the meshes: only when one changed
    const upload = !ok or key != key_up;
    if (upload) {
        const pos: [*]align(1) f32 = @ptrCast(base + off[ipc.GV_POS]);
        const nrm: [*]align(1) f32 = @ptrCast(base + off[ipc.GV_NRM]);
        const uvs: [*]align(1) f32 = @ptrCast(base + off[ipc.GV_UV]);
        const vcs: [*]align(1) u32 = @ptrCast(base + off[ipc.GV_VC]);
        var t: usize = 0;
        for (scene.objects[0..scene.count], 0..) |*o, oi| {
            if (!takes(o)) continue;
            const me = mods.of(oi) orelse continue;
            const cn = mods.normals(oi, me) orelse {
                ok = false;
                return false;
            };
            for (me.tris, 0..) |tr, ti| {
                for (0..3) |q| {
                    pos[t * 9 + q * 3..][0..3].* = me.verts[tr[q]];
                    nrm[t * 9 + q * 3..][0..3].* = cn[ti][q];
                }
                const uv = @import("bake.zig").triUvs(me, ti) orelse [6]f32{ std.math.nan(f32), 0, 0, 0, 0, 0 };
                uvs[t * 6..][0..6].* = uv;
                // vertex colours (none: 0)
                const vc = @import("vcol.zig").has(me);
                for (0..3) |q| vcs[t * 3 + q] = if (vc) me.vcol[tr[q]] else 0;
                t += 1;
            }
        }
        for ([_]usize{ ipc.GV_POS, ipc.GV_NRM, ipc.GV_UV, ipc.GV_VC }) |b| tab[b].flags = ipc.GBF_IN;
        key_up = key;
        mesh_kib += (sz[ipc.GV_POS] + sz[ipc.GV_NRM] + sz[ipc.GV_UV] + sz[ipc.GV_VC]) / 1024;
    }

    // the draws
    const dr: [*]align(1) u32 = @ptrCast(base + off[ipc.GV_DRAW]);
    const df: [*]align(1) f32 = @ptrCast(dr);
    const ind: [*]align(1) u32 = @ptrCast(base + off[ipc.GV_IND]);
    const ins: [*]align(1) u32 = @ptrCast(base + off[ipc.GV_INST]);
    const inf: [*]align(1) f32 = @ptrCast(ins);
    var d: usize = 0;
    var t0i: u32 = 0;
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!takes(o)) continue;
        const me = mods.of(oi) orelse continue;
        const mtx = scene.world(oi);
        const nm = preview.normalMatrix(mtx);
        const q = d * DRW;
        @memcpy(df[q..][0..12], mtx[0..12]);
        df[q + 12 ..][0..3].* = nm[0];
        df[q + 15 ..][0..3].* = nm[1];
        df[q + 18 ..][0..3].* = nm[2];
        dr[q + 21] = if (material.of(o) != null) o.mat else 0;
        dr[q + 22] = material.displayColor(o);
        dr[q + 23] = @intCast(oi + 1);
        dr[q + 24] = @intFromBool(me.closed and vp.boxInFront(c, mtx, me.lo, me.hi)); // (eye inside, near plane through: every face)
        dr[q + 25] = 0;
        dr[q + 26] = 0;
        df[q + 27] = 0.28;
        df[q + 28] = 0.72;
        const n: u32 = @intCast(me.tris.len);
        ind[d * 4] = n * 3;
        ind[d * 4 + 1] = 1;
        ind[d * 4 + 2] = t0i * 3;
        ind[d * 4 + 3] = @intCast(d);
        const e = d * INW;
        inf[e..][0..12].* = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
        ins[e + 12] = @intCast(d);
        ins[e + 13] = 0;
        ins[e + 14] = 0;
        ins[e + 15] = 0;
        t0i += n;
        d += 1;
    }
    for ([_]usize{ ipc.GV_PAR, ipc.GV_DRAW, ipc.GV_IND, ipc.GV_INST }) |b| tab[b].flags = ipc.GBF_IN;

    // the materials: whole, when they changed
    {
        const nb = sz[ipc.GV_MAT];
        const dst = base[off[ipc.GV_MAT]..][0..nb];
        const src = std.mem.sliceAsBytes(material.list[0..material.count]);
        if (!ok or !std.mem.eql(u8, dst[material.REC..], src)) {
            @memset(dst[0..material.REC], 0);
            @memcpy(dst[material.REC..], src);
            tab[ipc.GV_MAT].flags = ipc.GBF_IN;
        }
    }
    {
        const kk = gp.imgKey();
        if (!ok or kk != img_key) {
            img_key = kk;
            gp.imgInto(base + off[ipc.GV_IMG]);
            tab[ipc.GV_IMG].flags = ipc.GBF_IN;
        }
    }
    const hdri = mat_prev and env.on();
    if (hdri) {
        const t = env.previewTables();
        var ek = std.hash.Wyhash.init(0x656e);
        ek.update(std.mem.asBytes(&t.rotation));
        ek.update(std.mem.asBytes(&t.strength));
        ek.update(std.mem.asBytes(&t.version));
        const k2 = ek.final();
        if (!ok or k2 != env_key) {
            env_key = k2;
            const ev: [*]align(1) f32 = @ptrCast(base + off[ipc.GV_ENV]);
            for (t.sh, 0..) |c3, i| ev[i * 3..][0..3].* = c3;
            ev[27] = @cos(-t.rotation);
            ev[28] = @sin(-t.rotation);
            ev[29] = t.strength;
            ev[30] = t.rotation;
            ev[31] = 0;
            for (t.small, 0..) |c3, i| ev[32 + i * 3..][0..3].* = c3;
            tab[ipc.GV_ENV].flags = ipc.GBF_IN;
        }
    }

    // the constants
    const p: [*]align(1) u32 = @ptrCast(base + off[ipc.GV_PAR]);
    const pf: [*]align(1) f32 = @ptrCast(p);
    @memset(p[0..PARAM_WORDS], 0);
    p[0] = @intCast(w);
    p[1] = @intCast(h);
    p[2] = if (mat_prev) 2 else 0;
    p[3] = @intFromBool(hdri);
    pf[4..7].* = c.eye;
    pf[7..10].* = c.right;
    pf[10..13].* = c.up;
    pf[13..16].* = c.fwd;
    pf[16] = c.f;
    pf[17] = c.cx - @as(f32, @floatFromInt(r.x));
    pf[18] = c.cy - @as(f32, @floatFromInt(r.y));
    pf[19] = vp.near;
    pf[64..][0..256].* = texture.lut;

    if (!gpu.runSendN(ipc.GV_SLOT, ipc.GV_NB, @intCast(w), @intCast(h), ipc.K_VIEW + 1, ndraw)) {
        ok = false;
        return false;
    }
    ok = true;
    const wait: i32 = if (@import("files.zig").headless) 60000 else WAIT_MS;
    if (!gpu.runWait(wait) or !gpu.isUp()) return false; // (late: the CPU's frame; the reply goes unread till the next)
    var job = Merge{ .cv = cv, .r = r, .c = @ptrCast(base + off[ipc.GV_COL]), .z = @ptrCast(base + off[ipc.GV_INVZ]), .id = @ptrCast(base + off[ipc.GV_ID]) };
    jobs.parallelFor(@intCast(h), 16, &job, mergeRows);
    nframes += 1;
    tris_up = ntri;
    last_us = nowUs() - t0;
    last_on = true;
    return true;
}
