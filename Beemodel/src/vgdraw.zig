// Virtualized geometry, part 2: drawing cluster LOD DAGs (vgdraw.s).
//
// Every frame, each mesh object with a DAG (vgeo.zig) is drawn through a cut of
// it instead of its triangles:
//
// 1. cut      : from the roots down, a cluster's group is refined while its error,
//               projected from the camera, is over px_err pixels (the LOD spheres
//               nest and errors grow up the DAG, so a group not refined has no
//               refined descendant). A group is expanded once (a bit per group),
//               and only when it is in the frustum and its members' pages are in
//               memory; otherwise the clusters it made stand in (always crack-free:
//               they are what the members were simplified into). One object a job.
// 2. culling  : a cluster to draw is tested against the frustum, then against the
//               depth pyramid of the last frame, seen from that frame's camera.
//               Occluded ones wait.
// 3. drawing  : the chosen clusters are transformed in parallel (per cluster),
//               then rasterized in bands of rows: each band is one job, and owns
//               its rows of the colour, depth and id buffers. After those, the depth
//               pyramid is built from this frame's depth and the clusters that
//               waited are tested again: the ones now visible are drawn too (no
//               holes when the view moves).
// 4. streaming: a DAG read from a .bee file stays mapped from it. Its cluster data
//               is in 64 KiB pages: a page is asked for when a group needs it
//               (madvise WILLNEED), counted in once mincore finds it in memory,
//               stamped with the frame whenever it is used, and given back
//               (MADV_DONTNEED), least recently used first, when the pages in memory
//               and on their way would pass the budget. The roots' pages stay.
//
// The workers allocate nothing: the UI thread sizes every buffer first.
const std = @import("std");
const linux = std.os.linux;
const gfx = @import("gfx.zig");
const m = @import("math.zig");
const scene = @import("scene.zig");
const vg = @import("vgeo.zig");
const jobs = @import("jobs.zig");
const theme = @import("theme.zig");
const vp = @import("viewport.zig");
const Dag = vg.Dag;
const Rect = gfx.Rect;
const Cam = vp.Cam;

/// The error allowed, in pixels.
pub var px_err: f32 = 1.0;
/// Memory for cluster pages.
pub var budget: u64 = 0x80000000;
/// 0 shaded, 1 clusters coloured, 2 off (the meshes themselves).
pub var view_mode: u32 = 0;
var check_cut = false;

const M34 = [3][4]f32;

const Inst = struct {
    oi: u32,
    dag: *Dag,
    v: M34, // camera <- model
    p: M34, // the depth pyramid's camera <- model
    s: f32, // the model's largest scale
    ks: f32, // focal / pixels x scale
    col: u32,
    wire: u32,
    closed: bool,
    nmat: [3]m.V3,
    l1: [*]u32 = undefined, // clusters drawn
    l2: [*]u32 = undefined, // clusters that waited (occluded)
    n1: u32 = 0,
    n2: u32 = 0,
    fru: u32 = 0,
    occ: u32 = 0,
    fall: u32 = 0,
};

/// A vertex this frame: view space, then screen x, y, 1 / z.
const Vx = extern struct { v: m.V3, s: [3]f32 };
const Ent = struct { inst: u32, cl: u32, vb: u32, tb: u32, y0: i32, y1: i32 };
const DRAWN: u32 = 0x80000000;
const BAND = 16;

var insts: [scene.max_objects]Inst = undefined;
var n_inst: u32 = 0;
var owned: [scene.max_objects]bool = @splat(false);
var any_owned = false;
var frame: u32 = 0;
var planes: [4]m.V3 = undefined;
var cam: *const Cam = undefined;
var rect: Rect = .{};
var canvas: *gfx.Canvas = undefined;
var hz_use: ?*Hz = null; // this frame's occluders
var n_wire = false;
var n_prev = false;
var t0_us: i64 = 0;

// memory (sized by the UI thread, used by the workers)
fn Grow(comptime T: type) type {
    return struct {
        s: []T = &.{},
        fn need(g: *@This(), n: usize) bool {
            if (g.s.len >= n) return true;
            const want = @max(n + n / 2, 4096);
            const a = std.heap.page_allocator;
            if (g.s.len > 0) a.free(g.s);
            g.s = a.alloc(T, want) catch {
                g.s = &.{};
                return false;
            };
            return true;
        }
    };
}
var lists: Grow(u32) = .{};
var scratch: [64]Grow(u64) = @splat(.{});
var ents: Grow(Ent) = .{};
var vxs: Grow(Vx) = .{};
var nrm: Grow(m.V3) = .{};
var tcol: Grow(u32) = .{};
var bin_off: Grow(u32) = .{};
var bin_ent: Grow(u32) = .{};
var n_ent: u32 = 0;
var n_band: u32 = 0;

// statistics (vgstat)
var vs_inst: u32 = 0;
var vs_cl: u32 = 0;
var vs_tri: u32 = 0;
var vs_fru: u32 = 0;
var vs_occ: u32 = 0;
var vs_cl2: u32 = 0;
var vs_fall: u32 = 0;
var vs_us: u32 = 0;
var vs_crack: i32 = 0; // (vgdraw.s: 0 until a check ran)
var vs_src: u64 = 0;
var vs_reqs: u64 = 0;
var vs_evict: u64 = 0;

fn nowUs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

/// What the viewport's image also hangs on.
pub fn stateWord() [4]u32 {
    return .{ @bitCast(px_err), view_mode, vg.version, pages_in };
}

// --- the frame --------------------------------------------------------------------------------

fn plane(x: f32, y: f32, z: f32) m.V3 {
    const l = @sqrt(x * x + y * y + z * z);
    return .{ x / l, y / l, z / l };
}

fn cols(mtx: m.M4, basis: *const [3]m.V3, eye: m.V3, out: *M34) void {
    for (0..3) |r| {
        const b = basis[r];
        for (0..3) |k| out[r][k] = b[0] * mtx[k] + b[1] * mtx[4 + k] + b[2] * mtx[8 + k];
        const t: m.V3 = .{ mtx[3] - eye[0], mtx[7] - eye[1], mtx[11] - eye[2] };
        out[r][3] = b[0] * t[0] + b[1] * t[1] + b[2] * t[2];
    }
}

/// The objects drawn through their DAGs this frame: cuts and culling. They are
/// drawn by finish(), after the other meshes.
pub fn begin(cv: *gfx.Canvas, r: Rect, c: *const Cam, th: *const theme.Theme, wire: bool, mat_prev: bool) void {
    n_inst = 0;
    if (any_owned) @memset(owned[0..], false);
    any_owned = false;
    vs_inst = 0;
    vs_cl = 0;
    vs_tri = 0;
    vs_fru = 0;
    vs_occ = 0;
    vs_cl2 = 0;
    vs_fall = 0;
    vs_src = 0;
    if (view_mode == 2 or vg.dagCount() == 0 or scene.count == 0) return;
    const em = @import("editmesh.zig");
    const mods = @import("mods.zig");
    const material = @import("material.zig");
    const preview = @import("preview.zig");
    t0_us = nowUs();
    frame +%= 1;
    canvas = cv;
    cam = c;
    rect = r;
    n_wire = wire;
    n_prev = mat_prev and !wire;
    setup(r, c);
    hz_use = if (wire) null else hzFor(r);
    const basis = [3]m.V3{ c.right, c.up, c.fwd };
    var total: usize = 0;
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.visible or !o.kind.isMesh()) continue;
        if (o.ref != 0 and !wire) continue;
        if (em.active and em.obj == oi) continue; // (the edited object: as it is)
        if (@import("sculpt.zig").drawnApart(oi)) continue; // (the sculpted one too)
        if (scene.meshOfObj(oi) == null) continue;
        const me = mods.of(oi) orelse continue;
        if (@import("paint.zig").meshModes() or me.vcol.len != 0) continue; // (paint modes, vertex colours: the mesh)
        const d = vg.of(me) orelse continue;
        if (n_prev) {
            // (a shader graph reads the mesh's own triangles, pixel by pixel)
            if (material.of(o)) |ma| {
                if (ma.nodes() != 0) continue;
            }
        }
        if (!prep(d)) continue;
        const mtx = scene.world(oi);
        const act = scene.active != null and scene.active.? == oi;
        var ins = Inst{
            .oi = @intCast(oi),
            .dag = d,
            .v = undefined,
            .p = undefined,
            .s = 1,
            .ks = 1,
            .col = material.displayColor(o),
            .wire = if (act) th.active else if (o.selected) th.selected else th.obj_wire,
            .closed = me.closed and vp.boxInFront(c, mtx, me.lo, me.hi), // (else every face, as the original)
            .nmat = preview.normalMatrix(mtx),
        };
        cols(mtx, &basis, c.eye, &ins.v);
        if (hz_use) |hz| {
            const hb = [3]m.V3{ hz.cam.right, hz.cam.up, hz.cam.fwd };
            cols(mtx, &hb, hz.cam.eye, &ins.p);
        }
        // the column norms
        var mx: f32 = 0;
        for (0..3) |k| {
            mx = @max(mx, mtx[k] * mtx[k] + mtx[4 + k] * mtx[4 + k] + mtx[8 + k] * mtx[8 + k]);
        }
        ins.s = @sqrt(mx);
        ins.ks = ins.s * (c.f / @max(px_err, 1.0e-4));
        insts[n_inst] = ins;
        n_inst += 1;
        owned[oi] = true;
        any_owned = true;
        total += d.hdr().ncl;
        vs_src += d.hdr().stri;
    }
    vs_inst = n_inst;
    if (n_inst == 0) return;
    tickIn(); // pages that came in
    if (!sizeCut(total)) {
        n_inst = 0;
        @memset(owned[0..], false);
        any_owned = false;
        return;
    }
    n_req.store(0, .monotonic);
    jobs.parallelFor(n_inst, 1, &insts, jobCut);
    tickOut(); // pages asked for, the budget kept
    for (insts[0..n_inst]) |*i| {
        vs_fru += i.fru;
        vs_occ += i.occ;
        vs_fall += i.fall;
    }
    vs_us = @intCast(nowUs() - t0_us);
}

pub fn owns(oi: usize) bool {
    return owned[oi];
}

/// The clusters: the first batch, the depth pyramid, the ones that waited.
pub fn finish() void {
    if (n_inst == 0) return;
    drawBatch(0);
    if (!n_wire) hzBuild();
    crackCheck();
    var waiting: u32 = 0;
    for (insts[0..n_inst]) |*i| waiting += i.n2;
    if (waiting != 0) {
        jobs.parallelFor(n_inst, 1, &insts, jobOcc2);
        drawBatch(1);
    }
    for (insts[0..n_inst]) |*i| {
        vs_cl += i.n1 + i.n2;
        vs_cl2 += i.n2;
    }
}

fn sizeCut(total: usize) bool {
    if (!lists.need(total * 2 + 16)) return false;
    var at: usize = 0;
    var need: usize = 0;
    for (insts[0..n_inst]) |*i| {
        const h = i.dag.hdr();
        i.l1 = lists.s.ptr + at;
        i.l2 = lists.s.ptr + at + h.ncl;
        at += @as(usize, h.ncl) * 2;
        // a bit per group, the stack
        need = @max(need, (h.ngr / 64 + 1) + (i.dag.roots.len + h.nmem + 8) / 2 + 1);
    }
    for (0..jobs.count()) |t| {
        if (!scratch[@min(t, 63)].need(need)) return false;
    }
    return true;
}

fn setup(r: Rect, c: *const Cam) void {
    const f = c.f;
    const cx = c.cx - @as(f32, @floatFromInt(r.x));
    const cy = c.cy - @as(f32, @floatFromInt(r.y));
    const w: f32 = @floatFromInt(r.w);
    const h: f32 = @floatFromInt(r.h);
    const al = -cx / f;
    const ar = (w - cx) / f;
    const ab = (cy - h) / f;
    const at = cy / f;
    planes = .{ plane(1, 0, -al), plane(-1, 0, ar), plane(0, 1, -ab), plane(0, -1, at) };
}

fn sphere(s: *const [4]f32, a: *const M34, scale: f32) [4]f32 {
    return .{
        a[0][0] * s[0] + a[0][1] * s[1] + a[0][2] * s[2] + a[0][3],
        a[1][0] * s[0] + a[1][1] * s[1] + a[1][2] * s[2] + a[1][3],
        a[2][0] * s[0] + a[2][1] * s[1] + a[2][2] * s[2] + a[2][3],
        s[3] * scale,
    };
}

fn outside(s: [4]f32) bool {
    const r = s[3];
    if (s[2] + r < vp.near) return true;
    for (planes) |p| {
        if (p[0] * s[0] + p[1] * s[1] + p[2] * s[2] < -r) return true;
    }
    return false;
}

// --- the cut (one object a job) ---------------------------------------------------------------------

fn jobCut(_: *anyopaque, lo: usize, hi: usize, thread: usize) void {
    for (lo..hi) |i| cutOne(&insts[i], thread);
}

fn cutOne(ins: *Inst, thread: usize) void {
    const d = ins.dag;
    const h = d.hdr();
    const cl = d.clusters();
    const gr = d.groups();
    const mem = d.members();
    const sc = scratch[@min(thread, 63)].s;
    const nbits: usize = h.ngr / 64 + 1;
    const vis = sc[0..nbits];
    @memset(vis, 0);
    const stack: []u32 = @as([*]u32, @ptrCast(sc.ptr + nbits))[0 .. (sc.len - nbits) * 2];
    var sp: usize = d.roots.len;
    @memcpy(stack[0..sp], d.roots);
    const streamed = d.stream;
    var n1: u32 = 0;
    var n2: u32 = 0;
    var fru: u32 = 0;
    var occ: u32 = 0;
    var fall: u32 = 0;
    const hz = hz_use;
    const ncl = h.ncl;
    while (sp > 0) {
        sp -= 1;
        const ci = stack[sp];
        const c = &cl[ci];
        const g1 = d.creator[ci];
        if (g1 != 0) {
            // the group that made it: refine while its error is over px_err pixels
            const s = sphere(&c.lod, &ins.v, ins.s);
            const dist = @sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]) - s[3];
            if (c.err * ins.ks > dist) {
                const g = g1 - 1;
                const bit = @as(u64, 1) << @intCast(g & 63);
                if (vis[g >> 6] & bit != 0) continue; // expanded (or culled) already
                if (outside(.{ s[0], s[1], s[2], d.gcull[g] * ins.s })) {
                    vis[g >> 6] |= bit;
                    fru += 1;
                    continue;
                }
                const grp = &gr[g];
                if (!streamed or membersIn(d, mem[grp.mem..][0..grp.nmem], cl)) {
                    vis[g >> 6] |= bit;
                    @memcpy(stack[sp..][0..grp.nmem], mem[grp.mem..][0..grp.nmem]); // its members
                    sp += grp.nmem;
                    continue;
                }
                fall += 1; // not yet: the clusters it made stand in
            }
        }
        // to draw
        if (outside(sphere(&c.c, &ins.v, ins.s))) {
            fru += 1;
            continue;
        }
        if (streamed) stampCl(d, c);
        if (hz) |z| {
            if (occluded(z, sphere(&c.c, &ins.p, ins.s))) {
                if (n2 < ncl) { // (waits for the second batch)
                    ins.l2[n2] = ci;
                    n2 += 1;
                }
                occ += 1;
                continue;
            }
        }
        if (n1 < ncl) {
            ins.l1[n1] = ci;
            n1 += 1;
        }
    }
    ins.n1 = n1;
    ins.n2 = n2;
    ins.fru = fru;
    ins.occ = occ;
    ins.fall = fall;
}

fn pagesOf(c: *const vg.Cluster) [2]u32 {
    const a: u64 = @as(u64, c.data) * 16;
    const b = a + vg.clusterBytes(c) - 1;
    return .{ @intCast(a >> vg.VP_SHIFT), @intCast(b >> vg.VP_SHIFT) };
}

fn stampCl(d: *const Dag, c: *const vg.Cluster) void {
    const p = pagesOf(c);
    var k = p[0];
    while (k <= p[1]) : (k += 1) @atomicStore(u32, &d.stamp[k], frame, .monotonic);
}

/// All these members' pages are in memory (stamped as used; missing ones asked for).
fn membersIn(d: *Dag, mb: []const u32, cl: []const vg.Cluster) bool {
    var all = true;
    for (mb) |ci| {
        const p = pagesOf(&cl[ci]);
        var k = p[0];
        while (k <= p[1]) : (k += 1) {
            @atomicStore(u32, &d.stamp[k], frame, .monotonic);
            const st = @atomicLoad(u8, &d.state[k], .monotonic);
            if (st >= 2) continue;
            all = false;
            if (st != 0) continue;
            // ask for it (once)
            if (@cmpxchgStrong(u8, &d.state[k], 0, 1, .monotonic, .monotonic) != null) continue;
            const at = n_req.fetchAdd(1, .monotonic);
            if (at >= VD_RQ) {
                @atomicStore(u8, &d.state[k], 0, .monotonic); // (too many this frame)
                continue;
            }
            req[at] = .{ .d = d, .page = k };
        }
    }
    return all;
}

// --- occlusion: the depth pyramid --------------------------------------------------------------------

const HZ_MAXL = 24;
const Hz = struct {
    r: Rect = .{},
    ok: bool = false,
    cam: Cam = undefined,
    map: []f32 = &.{},
    nl: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    f: f32 = 1,
    cx: f32 = 0,
    cy: f32 = 0,
    lw: [HZ_MAXL + 1]u32 = undefined,
    lh: [HZ_MAXL + 1]u32 = undefined,
    lo: [HZ_MAXL + 1]u32 = undefined,
};
var hzs: [4]Hz = @splat(.{});
var hz_next: usize = 0;

/// This viewport's pyramid, if it has one.
fn hzFor(r: Rect) ?*Hz {
    for (&hzs) |*z| {
        if (z.ok and z.r.x == r.x and z.r.y == r.y and z.r.w == r.w and z.r.h == r.h) return z;
    }
    return null;
}

/// Every pixel the sphere (in the pyramid's camera space) may cover was nearer.
fn occluded(z: *const Hz, s: [4]f32) bool {
    const r = s[3];
    const nz = s[2] - r;
    if (!(nz > vp.near)) return false;
    const ni = 1.0 / nz; // 1 / near z
    const fi = 1.0 / (s[2] + r); // 1 / far z
    const lo = struct {
        fn f(a: f32, n_: f32, f_: f32) f32 {
            return if (a < 0) a * n_ else a * f_;
        }
    }.f;
    const hi = struct {
        fn f(a: f32, n_: f32, f_: f32) f32 {
            return if (a < 0) a * f_ else a * n_;
        }
    }.f;
    const px0 = lo(s[0] - r, ni, fi) * z.f + z.cx;
    const px1 = hi(s[0] + r, ni, fi) * z.f + z.cx;
    const py0 = z.cy - hi(s[1] + r, ni, fi) * z.f;
    const py1 = z.cy - lo(s[1] - r, ni, fi) * z.f;
    const zw: f32 = @floatFromInt(z.w);
    const zh: f32 = @floatFromInt(z.h);
    if (!(px1 >= 0) or !(py1 >= 0) or !(px0 < zw) or !(py0 < zh)) return false;
    const ix0: u32 = @intFromFloat(@max(px0, 0));
    const iy0: u32 = @intFromFloat(@max(py0, 0));
    const ix1: u32 = @intFromFloat(@min(px1, zw - 1));
    const iy1: u32 = @intFromFloat(@min(py1, zh - 1));
    var l: u5 = 1; // the level where it covers <= 2 x 2
    while (l < z.nl) : (l += 1) {
        if ((ix1 >> l) - (ix0 >> l) <= 1 and (iy1 >> l) - (iy0 >> l) <= 1) break;
    }
    const w = z.lw[l];
    const t = z.map[z.lo[l]..];
    var least: f32 = 3.0e38;
    var y = iy0 >> l;
    while (y <= iy1 >> l) : (y += 1) {
        var x = ix0 >> l;
        while (x <= ix1 >> l) : (x += 1) least = @min(least, t[y * w + x]);
    }
    return ni < least; // the nearest 1 / z < the farthest there
}

const HzJob = struct { z: *Hz, src: []const f32, stride: u32, sw: u32, sh: u32, dst: []f32, dw: u32 };

/// Each texel the least of its (up to) 2 x 2 source texels.
fn hzRows(j: *const HzJob, lo: usize, hi: usize) void {
    for (lo..hi) |y| {
        const y0: u32 = @intCast(y * 2);
        const y1: u32 = if (y0 + 1 < j.sh) y0 + 1 else y0;
        const r0 = j.src[y0 * j.stride..];
        const r1 = j.src[y1 * j.stride..];
        const out = j.dst[y * j.dw..];
        for (0..j.dw) |x| {
            const x0: u32 = @intCast(x * 2);
            const x1: u32 = if (x0 + 1 < j.sw) x0 + 1 else x0;
            out[x] = @min(@min(r0[x0], r0[x1]), @min(r1[x0], r1[x1]));
        }
    }
}

fn jobHz(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *const HzJob = @ptrCast(@alignCast(ctx));
    hzRows(j, lo, hi);
}

/// The pyramid from this frame's depth: the next frame's occluders, and those of
/// the clusters that waited.
fn hzBuild() void {
    const cv = canvas;
    const zb = cv.zbuf orelse return;
    const r = rect.intersect(cv.full());
    if (r.w != rect.w or r.h != rect.h or r.w <= 0 or r.h <= 0) return; // (a panel off the window)
    const z: *Hz = hzFor(rect) orelse blk: {
        // (the viewports take turns: each keeps its own)
        const x = &hzs[hz_next % hzs.len];
        hz_next += 1;
        x.ok = false;
        break :blk x;
    };
    z.ok = false;
    const w: u32 = @intCast(r.w);
    const h: u32 = @intCast(r.h);
    z.w = w;
    z.h = h;
    z.lw[0] = w;
    z.lh[0] = h;
    var cw = w;
    var ch = h;
    var nf: u32 = 0;
    var l: u32 = 1;
    while (true) {
        cw = (cw + 1) >> 1;
        ch = (ch + 1) >> 1;
        z.lw[l] = cw;
        z.lh[l] = ch;
        z.lo[l] = nf;
        nf += cw * ch;
        l += 1;
        if (l >= HZ_MAXL or (cw == 1 and ch == 1)) break;
    }
    z.nl = l - 1; // the top level
    if (z.map.len < nf) {
        const a = std.heap.page_allocator;
        if (z.map.len > 0) a.free(z.map);
        z.map = a.alloc(f32, nf) catch {
            z.map = &.{};
            return;
        };
    }
    const first: usize = @intCast(r.y * cv.w + r.x);
    const stride: u32 = @intCast(cv.w);
    var j = HzJob{ .z = z, .src = zb[first .. first + @as(usize, h - 1) * stride + w], .stride = stride, .sw = w, .sh = h, .dst = z.map[0..z.lw[1] * z.lh[1]], .dw = z.lw[1] };
    jobs.parallelFor(z.lh[1], 16, &j, jobHz);
    var k: u32 = 2;
    while (k <= z.nl) : (k += 1) {
        const s = z.map[z.lo[k - 1]..][0 .. z.lw[k - 1] * z.lh[k - 1]];
        var q = HzJob{ .z = z, .src = s, .stride = z.lw[k - 1], .sw = z.lw[k - 1], .sh = z.lh[k - 1], .dst = z.map[z.lo[k]..][0 .. z.lw[k] * z.lh[k]], .dw = z.lw[k] };
        hzRows(&q, 0, z.lh[k]);
    }
    z.r = rect;
    z.cam = cam.*;
    z.f = cam.f;
    z.cx = cam.cx - @as(f32, @floatFromInt(rect.x));
    z.cy = cam.cy - @as(f32, @floatFromInt(rect.y));
    z.ok = true;
    hz_use = z;
}

/// The clusters that waited, tested against this frame's pyramid.
fn jobOcc2(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const z = hz_use orelse return;
    for (lo..hi) |i| {
        const ins = &insts[i];
        const cl = ins.dag.clusters();
        var kept: u32 = 0;
        for (ins.l2[0..ins.n2]) |ci| {
            if (occluded(z, sphere(&cl[ci].c, &ins.v, ins.s))) continue;
            ins.l2[kept] = ci;
            kept += 1;
        }
        ins.n2 = kept;
    }
}

// --- drawing clusters ---------------------------------------------------------------------------------

fn drawBatch(batch: u32) void {
    var ne: usize = 0;
    var nv: usize = 0;
    var nt: usize = 0;
    for (insts[0..n_inst]) |*i| {
        const cl = i.dag.clusters();
        const l = if (batch == 0) i.l1[0..i.n1] else i.l2[0..i.n2];
        ne += l.len;
        for (l) |ci| {
            nv += cl[ci].nv;
            nt += cl[ci].nt;
        }
    }
    if (ne == 0) return;
    if (!ents.need(ne) or !vxs.need(nv) or !tcol.need(nt)) return;
    if (n_prev and !nrm.need(nv)) return;
    var at: usize = 0;
    var vb: u32 = 0;
    var tb: u32 = 0;
    for (insts[0..n_inst], 0..) |*i, k| {
        const cl = i.dag.clusters();
        const l = if (batch == 0) i.l1[0..i.n1] else i.l2[0..i.n2];
        for (l) |ci| {
            ents.s[at] = .{ .inst = @intCast(k), .cl = ci, .vb = vb, .tb = tb, .y0 = 0, .y1 = -1 };
            at += 1;
            vb += cl[ci].nv;
            tb += cl[ci].nt;
        }
    }
    n_ent = @intCast(ne);
    jobs.parallelFor(ne, 32, &ents, jobDecode);
    // the bands each cluster touches
    const r = rect.intersect(canvas.clip).intersect(canvas.full());
    if (r.w <= 0 or r.h <= 0) return;
    n_band = @intCast(@divFloor(r.h + BAND - 1, BAND));
    if (!bin_off.need(n_band + 2)) return;
    const off = bin_off.s[0 .. n_band + 2];
    @memset(off, 0);
    var total: usize = 0;
    for (ents.s[0..ne]) |*e| {
        if (e.y1 < e.y0) continue;
        const a = @max(@divFloor(e.y0 - r.y, BAND), 0);
        const b = @min(@divFloor(e.y1 - r.y, BAND), @as(i32, @intCast(n_band)) - 1);
        var k = a;
        while (k <= b) : (k += 1) {
            off[@as(usize, @intCast(k)) + 2] += 1;
            total += 1;
        }
    }
    if (!bin_ent.need(total)) return;
    for (2..n_band + 2) |k| off[k] += off[k - 1];
    for (ents.s[0..ne], 0..) |*e, x| {
        if (e.y1 < e.y0) continue;
        const a = @max(@divFloor(e.y0 - r.y, BAND), 0);
        const b = @min(@divFloor(e.y1 - r.y, BAND), @as(i32, @intCast(n_band)) - 1);
        var k = a;
        while (k <= b) : (k += 1) {
            const q = @as(usize, @intCast(k)) + 1;
            bin_ent.s[off[q]] = @intCast(x);
            off[q] += 1;
        }
    }
    var cr = r;
    const gr = @import("gpuraster.zig");
    if (!n_prev and !n_wire and gr.wanted()) {
        // (the tile stage on the GPU; what it cannot take the CPU draws)
        gr.setCanvas(canvas);
        _ = gr.begin();
        collect(r);
        gr.flush(canvas, r);
    } else jobs.parallelFor(n_band, 1, &cr, jobBand);
    vs_tri += @intCast(nt);
}

/// The batch's triangles through Canvas.triangle, in order, for gpuraster.zig.
fn collect(r: Rect) void {
    var lc = canvas.*;
    lc.clip = r;
    const c = cam;
    for (ents.s[0..n_ent]) |*e| {
        if (e.y1 < e.y0) continue;
        const ins = &insts[e.inst];
        const d = ins.dag;
        const k = &d.clusters()[e.cl];
        const tri = d.data(k) + @as(usize, k.nv) * 16;
        const vs = vxs.s[e.vb..][0..k.nv];
        const id: u16 = @intCast(ins.oi + 1);
        for (tcol.s[e.tb..][0..k.nt], 0..) |tc, t| {
            if (tc & DRAWN == 0) continue;
            const col = tc & 0xffffff;
            const a = &vs[tri[t * 3]];
            const b = &vs[tri[t * 3 + 1]];
            const cc = &vs[tri[t * 3 + 2]];
            const nr = vp.near;
            if (a.v[2] >= nr and b.v[2] >= nr and cc.v[2] >= nr) {
                lc.triangle(a.s, b.s, cc.s, col, id);
            } else vp.clipTri(&lc, c, .{ a.v, b.v, cc.v }, col, id);
        }
    }
}

/// Per cluster: vertices to view and screen space, triangles' culling and colours.
fn jobDecode(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const c = cam;
    const nr = vp.near;
    const clusters_coloured = view_mode == 1;
    for (ents.s[lo..hi]) |*e| {
        const ins = &insts[e.inst];
        const d = ins.dag;
        const h = d.hdr();
        const k = &d.clusters()[e.cl];
        const data = d.data(k);
        const vout = vxs.s[e.vb..][0..k.nv];
        const v = &ins.v;
        var ymin: f32 = 1.0e9;
        var ymax: f32 = -1.0e9;
        var behind = false;
        for (0..k.nv) |i| {
            const w: *align(1) const [4]i32 = @ptrCast(data + i * 16);
            const p = [3]f32{
                @as(f32, @floatFromInt(w[0])) * h.step + h.bmin[0],
                @as(f32, @floatFromInt(w[1])) * h.step + h.bmin[1],
                @as(f32, @floatFromInt(w[2])) * h.step + h.bmin[2],
            };
            const q: m.V3 = .{
                v[0][0] * p[0] + v[0][1] * p[1] + v[0][2] * p[2] + v[0][3],
                v[1][0] * p[0] + v[1][1] * p[1] + v[1][2] * p[2] + v[1][3],
                v[2][0] * p[0] + v[2][1] * p[1] + v[2][2] * p[2] + v[2][3],
            };
            var sc: [3]f32 = .{ 0, 0, 0 };
            if (q[2] >= nr) {
                const inv = 1.0 / q[2];
                sc = .{ c.cx + q[0] * inv * c.f, c.cy - q[1] * inv * c.f, inv }; // (not clamped: vp.scr)
                ymin = @min(ymin, sc[1]);
                ymax = @max(ymax, sc[1]);
            } else behind = true;
            vout[i] = .{ .v = q, .s = sc };
            if (n_prev) {
                const n = if (clusters_coloured) m.V3{ 0, 0, 0 } else @import("preview.zig").xformN(ins.nmat, vg.octLoad(@bitCast(w[3])));
                nrm.s[e.vb + i] = n;
            }
        }
        const tri = data + @as(usize, k.nv) * 16;
        const tc = tcol.s[e.tb..][0..k.nt];
        var base = ins.col;
        if (clusters_coloured) {
            var hc: u32 = e.cl *% 0x9e3779b1;
            hc = (hc ^ (hc >> 15)) *% 0x85ebca6b;
            hc = (hc ^ (hc >> 13)) | 0x404040;
            base = hc & 0xffffff;
        }
        var any = false;
        for (0..k.nt) |t| {
            tc[t] = 0;
            const ia = tri[t * 3];
            const ib = tri[t * 3 + 1];
            const ic = tri[t * 3 + 2];
            if (ia >= k.nv or ib >= k.nv or ic >= k.nv) continue; // (a damaged file)
            const a = vout[ia].v;
            const b = vout[ib].v;
            const cc = vout[ic].v;
            if (n_wire) {
                const s = a[0] + a[1] + a[2] + b[0] + b[1] + b[2] + cc[0] + cc[1] + cc[2];
                if (!std.math.isFinite(s)) continue;
                tc[t] = DRAWN;
                any = true;
                continue;
            }
            const cr = m.cross(m.sub(b, a), m.sub(cc, a));
            var n = m.norm(m.scale(cr, -1)); // (the view's axes are left-handed)
            if (m.dot(n, a) >= 0) {
                if (ins.closed) continue; // a back face
                n = m.scale(n, -1);
            }
            const lit = 0.28 + 0.72 * @abs(n[2]);
            if (!(lit >= 0 and lit <= 2)) continue;
            tc[t] = DRAWN | gfx.shade(base, lit);
            any = true;
        }
        if (!any) continue;
        if (behind) {
            e.y0 = -100000;
            e.y1 = 100000;
        } else {
            e.y0 = @intFromFloat(@floor(std.math.clamp(ymin, -1e9, 1e9)));
            e.y1 = @intFromFloat(@ceil(std.math.clamp(ymax, -1e9, 1e9)));
        }
    }
}

fn jobBand(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const r: *const Rect = @ptrCast(@alignCast(ctx));
    const preview = @import("preview.zig");
    const off = bin_off.s;
    const nb = if (n_prev) preview.nbuf.ptr else undefined;
    const nn = nrm.s;
    const c = cam;
    for (lo..hi) |band| {
        const y0 = r.y + @as(i32, @intCast(band)) * BAND;
        const y1 = @min(y0 + BAND, r.bottom());
        var lc = canvas.*; // (its own rows)
        lc.clip = .{ .x = r.x, .y = y0, .w = r.w, .h = y1 - y0 };
        const fy0: f32 = @floatFromInt(y0);
        const fy1: f32 = @floatFromInt(y1);
        for (bin_ent.s[off[band]..off[band + 1]]) |x| {
            const e = &ents.s[x];
            const ins = &insts[e.inst];
            const d = ins.dag;
            const k = &d.clusters()[e.cl];
            const tri = d.data(k) + @as(usize, k.nv) * 16;
            const vs = vxs.s[e.vb..][0..k.nv];
            const id: u16 = @intCast(ins.oi + 1);
            for (tcol.s[e.tb..][0..k.nt], 0..) |tc, t| {
                if (tc & DRAWN == 0) continue;
                const col = tc & 0xffffff;
                const ia = tri[t * 3];
                const ib = tri[t * 3 + 1];
                const ic = tri[t * 3 + 2];
                const a = &vs[ia];
                const b = &vs[ib];
                const cc = &vs[ic];
                if (n_wire) {
                    vp.viewLine(&lc, c, a.v, b.v, ins.wire);
                    vp.viewLine(&lc, c, b.v, cc.v, ins.wire);
                    vp.viewLine(&lc, c, cc.v, a.v, ins.wire);
                    continue;
                }
                const nr = vp.near;
                if (a.v[2] >= nr and b.v[2] >= nr and cc.v[2] >= nr) {
                    const ymn = @min(a.s[1], @min(b.s[1], cc.s[1]));
                    const ymx = @max(a.s[1], @max(b.s[1], cc.s[1]));
                    if (ymx < fy0 - 1 or ymn > fy1 + 1) continue;
                    if (n_prev) {
                        lc.triangleN(a.s, b.s, cc.s, .{ nn[e.vb + ia], nn[e.vb + ib], nn[e.vb + ic] }, col, id, nb);
                    } else lc.triangle(a.s, b.s, cc.s, col, id);
                } else if (n_prev) {
                    vp.clipTriN(&lc, c, .{ a.v, b.v, cc.v }, .{ nn[e.vb + ia], nn[e.vb + ib], nn[e.vb + ic] }, col, id);
                } else vp.clipTri(&lc, c, .{ a.v, b.v, cc.v }, col, id);
            }
        }
    }
}

/// (vgeo.view check) the first object's cut as drawn, the waiting clusters with it,
/// against its level 0: 1 when the sums of their directed edges agree (no crack),
/// 0 when not, -1 when the frustum took clusters away (no answer).
fn crackCheck() void {
    vs_crack = -1;
    if (!check_cut) return;
    const i = &insts[0];
    if (i.fru != 0) return;
    const d = i.dag;
    const n = d.hdr().ncl;
    const a = std.heap.page_allocator;
    const sel = a.alloc(u8, n) catch return;
    defer a.free(sel);
    @memset(sel, 0);
    for (i.l1[0..i.n1]) |c| sel[c] = 1;
    for (i.l2[0..i.n2]) |c| sel[c] = 1;
    const sum = vg.edges(d, sel);
    for (d.clusters(), 0..) |*c, k| sel[k] = @intFromBool(c.level == 0);
    vs_crack = @intFromBool(vg.edges(d, sel) == sum);
}

// --- the DAGs' runtime state, streaming --------------------------------------------------------------

const VD_RQ = 4096; // page requests a frame
const VD_FL = 256; // pages on their way
const VD_REG = 4096; // streamed DAGs
const Req = struct { d: *Dag, page: u32 };
const Fl = struct { d: *Dag, page: u32, waited: u32 };
var req: [VD_RQ]Req = undefined;
var n_req = std.atomic.Value(u32).init(0);
var fl: [VD_FL]Fl = undefined;
var n_fl: u32 = 0;
var reg: [VD_REG]*Dag = undefined;
var n_reg: u32 = 0;
var res_b: u64 = 0; // bytes of pages in memory
var flb: u64 = 0; // on their way
var pages_in: u32 = 0;

const MADV_WILLNEED = 3;
const MADV_DONTNEED = 4;

fn madvise(p: [*]const u8, n: usize, adv: u32) void {
    _ = linux.syscall3(.madvise, @intFromPtr(p), n, adv);
}

fn pageSpan(d: *const Dag, page: u32) []const u8 {
    const h = d.hdr();
    const off = @as(u64, page) << vg.VP_SHIFT;
    const left = h.dbytes - off;
    const n = std.mem.alignForward(u64, @min(left, vg.VP_BYTES), 4096);
    return (d.block.ptr + h.odata)[off..][0..@min(n, h.bytes - h.odata - off)];
}

const RJob = struct { d: *Dag };
fn jobRadii(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *const RJob = @ptrCast(@alignCast(ctx));
    const h = j.d.hdr();
    vg.trueRadii(j.d.clusters().ptr, j.d.block.ptr + h.odata, h.step, lo, hi);
}

/// Its creators, roots, page states made (once); a streamed DAG is listed and its
/// roots' pages read now and kept. (A DAG the original built gets its radii put
/// right first: that reads all of it, once.)
fn prep(d: *Dag) bool {
    if (d.ready) return true;
    const a = std.heap.page_allocator;
    const h = d.hdr();
    const cl = d.clusters();
    if (h.fixed != 0x31584952) {
        var j = RJob{ .d = d };
        jobs.parallelFor(h.ncl, 256, &j, jobRadii);
        // (the header is the DAG's own: a private mapping when it is the file's)
        const hw: *vg.Header = @ptrCast(@alignCast(d.block.ptr));
        hw.fixed = 0x31584952;
        if (d.stream) madvise(d.block.ptr + h.odata, std.mem.alignForward(u64, h.dbytes, 4096), MADV_DONTNEED);
    }
    var nroot: u32 = 0;
    for (cl) |*c| {
        if (@as(u32, @bitCast(c.perr)) == 0x7f7fffff) nroot += 1;
    }
    const npage: usize = @intCast((h.dbytes + vg.VP_BYTES - 1) >> vg.VP_SHIFT);
    d.creator = a.alloc(u32, h.ncl) catch return false;
    d.roots = a.alloc(u32, nroot) catch return false;
    d.gcull = a.alloc(f32, h.ngr) catch return false;
    d.state = a.alloc(u8, npage) catch return false;
    d.stamp = a.alloc(u32, npage) catch return false;
    @memset(d.creator, 0);
    @memset(d.state, 0);
    @memset(d.stamp, 0);
    const gr = d.groups();
    const mem = d.members();
    for (gr, 0..) |*g, i| {
        for (d.creator[g.par..][0..g.npar]) |*c| c.* = @intCast(i + 1);
    }
    var k: u32 = 0;
    for (cl, 0..) |*c, i| {
        if (@as(u32, @bitCast(c.perr)) != 0x7f7fffff) continue;
        d.roots[k] = @intCast(i);
        k += 1;
    }
    // a group's sphere for culling: holds its members' true bounds, and what they
    // stand for (the LOD spheres are for the error: they nest, but are made
    // from the original's radii)
    for (gr, 0..) |*g, i| {
        var r: f32 = 0;
        for (mem[g.mem..][0..g.nmem]) |mi| {
            const c = &cl[mi];
            r = @max(r, dist3(&g.lod, &c.c) + c.c[3]);
            const up = d.creator[mi];
            if (up != 0 and up - 1 < gr.len) r = @max(r, dist3(&g.lod, &gr[up - 1].lod) + d.gcull[up - 1]);
        }
        d.gcull[i] = r * 1.00001 + 1.0e-6;
    }
    if (d.stream) {
        if (n_reg < VD_REG) {
            reg[n_reg] = d;
            n_reg += 1;
            d.reg = n_reg;
            for (d.roots) |ri| { // the roots' pages: read, kept
                const p = pagesOf(&cl[ri]);
                var q = p[0];
                while (q <= p[1]) : (q += 1) {
                    if (d.state[q] == 3) continue;
                    d.state[q] = 3;
                    const s = pageSpan(d, q);
                    res_b += s.len;
                    var off: usize = 0;
                    while (off < s.len) : (off += 4096) std.mem.doNotOptimizeAway(s[off]);
                }
            }
        } else d.stream = false;
    }
    d.ready = true;
    return true;
}

fn dist3(a: *const [4]f32, b: *const [4]f32) f32 {
    const x = [3]f32{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
    return @sqrt(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]);
}

/// Pages on their way that are now all in memory: counted in. Returns how many.
fn tickIn() void {
    var i: u32 = 0;
    while (i < n_fl) {
        const f = &fl[i];
        const s = pageSpan(f.d, f.page);
        var vec: [16]u8 = undefined;
        const rc = linux.syscall3(.mincore, @intFromPtr(s.ptr), s.len, @intFromPtr(&vec));
        var inmem = linux.errno(rc) == .SUCCESS;
        if (inmem) {
            for (vec[0 .. s.len >> 12]) |b| inmem = inmem and b & 1 != 0;
        }
        if (!inmem) {
            f.waited += 1; // not yet
            if (f.waited >= 120) { // (asked again now and then)
                f.waited = 0;
                madvise(s.ptr, s.len, MADV_WILLNEED);
            }
            i += 1;
            continue;
        }
        pages_in +%= 1;
        flb -= s.len;
        res_b += s.len;
        f.d.state[f.page] = 2;
        f.d.stamp[f.page] = frame;
        n_fl -= 1; // (the last one takes its place)
        fl[i] = fl[n_fl];
    }
}

/// This frame's requests: read ahead while the pages in memory and on their way fit
/// the budget, the least recently used ones given back to make room.
fn tickOut() void {
    const n = @min(n_req.load(.monotonic), VD_RQ);
    for (req[0..n]) |*r| {
        const s = pageSpan(r.d, r.page);
        var room = n_fl < VD_FL;
        if (room and res_b + flb + s.len > budget) {
            evict(res_b + flb + s.len - budget);
            room = res_b + flb + s.len <= budget;
        }
        if (!room) {
            r.d.state[r.page] = 0; // no room: asked for again later
            continue;
        }
        flb += s.len;
        madvise(s.ptr, s.len, MADV_WILLNEED);
        fl[n_fl] = .{ .d = r.d, .page = r.page, .waited = 0 };
        n_fl += 1;
        vs_reqs += 1;
    }
    n_req.store(0, .monotonic);
}

/// Pages in memory not used this frame given back, the least recently used first,
/// until that much is freed (or none is left).
fn evict(bytes0: u64) void {
    var left: i64 = @intCast(bytes0);
    var pass: u32 = 16;
    while (left > 0 and pass > 0) : (pass -= 1) {
        var oldest: u32 = 0xffffffff;
        for (reg[0..n_reg]) |d| {
            for (d.state, d.stamp) |st, sm| {
                if (st != 2 or sm == frame) continue;
                oldest = @min(oldest, sm);
            }
        }
        if (oldest == 0xffffffff) return;
        for (reg[0..n_reg]) |d| { // give those back
            for (d.state, d.stamp, 0..) |*st, sm, k| {
                if (st.* != 2 or sm != oldest) continue;
                st.* = 0;
                const s = pageSpan(d, @intCast(k));
                res_b -= s.len;
                left -= @intCast(s.len);
                madvise(s.ptr, s.len, MADV_DONTNEED);
                vs_evict += 1;
            }
        }
    }
}

/// (its last use gone) Its runtime state, its pages in memory and on their way, its
/// place in the list.
pub fn forget(d: *Dag) void {
    if (!d.ready) return;
    const a = std.heap.page_allocator;
    if (d.reg != 0) {
        for (d.state, 0..) |st, k| {
            if (st >= 2) res_b -= pageSpan(d, @intCast(k)).len;
        }
        var i: u32 = 0;
        while (i < n_fl) {
            if (fl[i].d == d) {
                flb -= pageSpan(d, fl[i].page).len;
                n_fl -= 1;
                fl[i] = fl[n_fl];
            } else i += 1;
        }
        const at = d.reg - 1;
        n_reg -= 1;
        reg[at] = reg[n_reg];
        reg[at].reg = at + 1;
        d.reg = 0;
    }
    a.free(d.creator);
    a.free(d.roots);
    a.free(d.gcull);
    a.free(d.state);
    a.free(d.stamp);
    d.ready = false;
}

/// (after a save read all of it) A streamed DAG's pages given back but the roots' and
/// those on their way.
pub fn drop(d: *const Dag) void {
    if (!d.stream) return;
    const h = d.hdr();
    if (!d.ready) {
        madvise(d.block.ptr + h.odata, std.mem.alignForward(u64, h.dbytes, 4096), MADV_DONTNEED);
        return;
    }
    for (d.state, 0..) |*st, k| {
        if (st.* == 1 or st.* == 3) continue;
        const s = pageSpan(d, @intCast(k));
        if (st.* == 2) res_b -= s.len;
        st.* = 0;
        madvise(s.ptr, s.len, MADV_DONTNEED);
    }
}

/// (the main loop) Pages that came in: a frame to draw them. The time till a look
/// again, while some are on their way.
pub fn poll() ?i32 {
    if (n_fl == 0) return null;
    const had = pages_in;
    tickIn();
    if (pages_in != had) @import("app.zig").dirty = true;
    return if (n_fl == 0) null else 16;
}

// --- statistics and settings -------------------------------------------------------------------------

/// vgstat(k): the last frame's 0 objects drawn through DAGs, 1 clusters drawn, 2 their
/// triangles, 3 culled by the frustum, 4 occluded in the last frame's depth (tested
/// again), 5 of those drawn after all, 6 the objects' source triangles, 7 MB of
/// cluster pages in memory, 8 the budget (MB), 9 pages on their way, 10 pages read in
/// all, 11 pages given back in all, 12 refinements waiting for pages, 13 ms for the
/// cuts, 14 streamed DAGs, 15 the error allowed (pixels), 16 (vgeo.view check) the
/// first object's cut crack-free (1, 0; -1: not all of it in view, or not checking).
pub fn stat(k: u32) f32 {
    const f = struct {
        fn i(x: anytype) f32 {
            return @floatFromInt(x);
        }
    }.i;
    const mb = 9.5367432e-7;
    return switch (k) {
        0 => f(vs_inst),
        1 => f(vs_cl),
        2 => f(vs_tri),
        3 => f(vs_fru),
        4 => f(vs_occ),
        5 => f(vs_cl2),
        6 => f(vs_src),
        7 => f(res_b) * mb,
        8 => f(budget) * mb,
        9 => f(n_fl),
        10 => f(vs_reqs),
        11 => f(vs_evict),
        12 => f(vs_fall),
        13 => f(vs_us) / 1000.0,
        14 => f(n_reg),
        15 => px_err,
        16 => f(vs_crack),
        else => 0,
    };
}

fn number(arg: []const u8) ?f32 {
    var it = std.mem.tokenizeAny(u8, arg, " \t\"");
    const w = it.next() orelse return null;
    const v = std.fmt.parseFloat(f32, w) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

pub fn opBudget(arg: []const u8) void {
    const v = number(arg) orelse return;
    const mb: u64 = @intFromFloat(std.math.clamp(v, 1, 1.0e9));
    budget = mb << 20;
    if (res_b + flb > budget) {
        frame +%= 1; // (nothing in use)
        evict(res_b + flb - budget);
    }
    @import("app.zig").dirty = true;
}

pub fn opError(arg: []const u8) void {
    const v = number(arg) orelse return;
    px_err = @max(v, 1.0e-4);
    @import("app.zig").dirty = true;
}

/// vgeo.view clusters | shaded | off (the meshes themselves) | check (the first
/// object's drawn cut, for cracks); without a word: clusters coloured or not.
/// (The port's console has no vgstat() and vgeo(): `stats` and `info` print them;
/// `wait`: until a background build ends.)
pub fn opView(arg: []const u8) void {
    const app = @import("app.zig");
    var it = std.mem.tokenizeAny(u8, arg, " \t\"");
    const w = it.next() orelse "";
    if (std.mem.startsWith(u8, w, "ch")) {
        check_cut = !check_cut;
    } else if (std.mem.eql(u8, w, "stats")) {
        var b: [300]u8 = undefined;
        var o = std.Io.Writer.fixed(&b);
        o.print("vgstat", .{}) catch {};
        for (0..17) |k| o.print(" {d}", .{stat(@intCast(k))}) catch {};
        app.log("{s}", .{o.buffered()});
    } else if (std.mem.eql(u8, w, "info")) {
        const d = vg.activeDag() orelse return app.log("vgeo none", .{});
        var b: [300]u8 = undefined;
        var o = std.Io.Writer.fixed(&b);
        o.print("vgeo", .{}) catch {};
        for (1..15) |k| {
            const v: f32 = if (k == 12) @floatFromInt(@intFromBool(vg.check(d))) else vg.info(d, @intCast(k));
            o.print(" {d}", .{v}) catch {};
        }
        app.log("{s}", .{o.buffered()});
    } else if (std.mem.eql(u8, w, "wait")) {
        vg.waitBuild();
    } else if (w.len > 0 and w[0] == 's') {
        view_mode = 0;
    } else if (w.len > 0 and w[0] == 'c') {
        view_mode = 1;
    } else if (w.len > 0 and w[0] == 'o') {
        view_mode = 2;
    } else view_mode = (view_mode ^ 1) & 1; // toggled
    vg.version +%= 1;
    app.dirty = true;
}

// --- the panel (the Render tab) ------------------------------------------------------------------------

var budget_mb: f32 = 2048;

/// Below y; returns where it ends.
pub fn panel(salt: usize, bd: Rect, y0: i32) i32 {
    const ui = @import("ui.zig");
    const ops = @import("ops.zig");
    const cat = @import("catalog.zig");
    var y = y0 + 8;
    const old = gfx.useFace(.head);
    _ = ui.cv.text(bd.x, y + 2, "Virtualized Geometry", ui.th.accent_fg);
    _ = gfx.useFace(old);
    ui.record("heading", "Virtualized Geometry", .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, true);
    y += 26;
    const half = @divTrunc(bd.w - 4, 2);
    const btn = struct {
        fn f(wid: u32, r: Rect, id: []const u8, label: []const u8, arg: []const u8, tip: ?[]const u8) void {
            const oi = ops.byId(id) orelse return;
            const why = ops.reason(oi);
            if (ui.button(wid, r, label, .{ .enabled = why == null, .tip = tip orelse cat.entries[oi].doc, .why = why })) {
                ui.active = 0;
                const a = ops.arg;
                ops.arg = arg;
                ops.run(oi);
                ops.arg = a;
            }
        }
    }.f;
    btn(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = half, .h = 22 }, "vgeo.build", "Build", "", "Cluster LODs for the active mesh: millions of triangles stay fast");
    btn(ui.id(@src(), salt), .{ .x = bd.x + bd.w - half, .y = y, .w = half, .h = 22 }, "vgeo.clear", "Clear", "", null);
    y += 26;
    btn(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, "vgeo.view", "Show Clusters", "", "Colour each cluster");
    y += 26;
    var e = px_err;
    if (ui.valueField(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, &e, "Error (pixels)", .{ .step = 0.01, .lo = 0.1, .hi = 16, .dec = 2, .tip = "The detail allowed to go: more pixels, fewer triangles" })) {
        px_err = @max(e, 1.0e-4);
    }
    y += 26;
    budget_mb = @floatFromInt(budget >> 20);
    if (ui.valueField(ui.id(@src(), salt), .{ .x = bd.x, .y = y, .w = bd.w, .h = 22 }, &budget_mb, "Memory (MB)", .{ .step = 1, .lo = 64, .hi = 1048576, .dec = 0, .tip = "Memory for streamed cluster pages: past it the least recently used pages are given back" })) {
        var b: [24]u8 = undefined;
        opBudget(std.fmt.bufPrint(&b, "{d}", .{budget_mb}) catch "");
    }
    return y + 26;
}
