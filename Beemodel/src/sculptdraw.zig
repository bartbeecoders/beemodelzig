// Drawing the sculpted mesh (sculpt_draw): it skips the triangle rasterizer. The
// leaves are binned into screen tiles and the tiles drawn in parallel - a leaf with
// two vertices or more a pixel splats them (smooth normals; every k-th when there
// are more), a closer one rasterizes its triangles - into the same colour and depth
// buffers as the other objects. Splats are projected and shaded once into records
// that stay while the view does: during a stroke only the leaves it changed are
// projected again, and a tile cache (the viewport's colour and depth after the last
// frame) supplies every tile no changed leaf covers.
const std = @import("std");
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const jobs = @import("jobs.zig");
const sc = @import("sculpt.zig");
const vp = @import("viewport.zig");
const stroke = @import("stroke.zig");

const V3 = m.V3;
const trunc32 = stroke.trunc32;
const minss = stroke.minss;
const maxss = stroke.maxss;
const Rect = gfx.Rect;

const TILE_SH = 4;
const TILE = 1 << TILE_SH;
const clay_r: f32 = 0.80;
const clay_g: f32 = 0.76;
const clay_b: f32 = 0.70;
const mask_k: f32 = 0.55; // masked: darker
const sf_tiny: f32 = 1.0e-20;

/// x0 y0 x1 y1 (inclusive viewport pixels), mode (0 culled, 1 splats, 2 triangles),
/// splat stride.
const Leaf = extern struct { x0: i32, y0: i32, x1: i32, y1: i32, mode: u32, stride: u32, pad: [2]u32 = .{ 0, 0 } };
/// A leaf's splat records: first, room, how many, their stride.
const LRec = extern struct { first: u32, room: u32, n: u32, stride: u32 };
/// A splat: viewport x, y, 1/z, colour, kept while the view stays.
const Rec = extern struct { x: i32, y: i32, iz: f32, col: u32 };

/// local -> camera; the largest column length of it; the camera.
pub var sd_c: [12]f32 = undefined;
var sd_scale: f32 = 1;
pub var focal: f32 = 1;
var cx: f32 = 0;
var cy: f32 = 0;

var sd_nodes: []Leaf = &.{};
var lrec: []LRec = &.{};
var rbuf: []Rec = &.{};
var rused: u32 = 0;
var key: [20]u32 = @splat(0);
var key_on = false;
var toff: []u32 = &.{};
var tlist: []u32 = &.{};
var ntx: i32 = 0;
var nty: i32 = 0;
var dirty_tiles: []u8 = &.{};

// the tile cache
var sdc_col: []u32 = &.{};
var sdc_dep: []f32 = &.{};
var sdc_prev: []Leaf = &.{};
var sdc_key: [6]i32 = @splat(0);
var sdc_valid = false;
var sdc_use = false;
var sdc_store = false;

// this frame
var cv_px: [*]u32 = undefined;
var cv_z: [*]f32 = undefined;
var cv_w: i32 = 0;
var rs_x0: i32 = 0;
var rs_y0: i32 = 0;
var rs_w: i32 = 0;
var rs_h: i32 = 0;
var near: f32 = 0;
var dummy: u8 = 0;

/// How many tiles and leaves the last frame drew anew (tests, the bench).
pub var tiles_drawn = std.atomic.Value(u32).init(0);
pub var tiles_total: u32 = 0;
pub var leaves_projected = std.atomic.Value(u32).init(0);

/// sd_c = camera (right, up, fwd rows; eye at 0) x object matrix.
pub fn setCam(c: *const vp.Cam) void {
    const a = &sc.sc_m;
    const rows = [3]V3{ c.right, c.up, c.fwd };
    for (rows, 0..) |r, i| {
        for (0..3) |j| sd_c[i * 4 + j] = r[0] * a[j] + r[1] * a[4 + j] + r[2] * a[8 + j];
        sd_c[i * 4 + 3] = (a[3] - c.eye[0]) * r[0] + (a[7] - c.eye[1]) * r[1] + (a[11] - c.eye[2]) * r[2];
    }
    focal = c.f;
    cx = c.cx;
    cy = c.cy;
}

fn camScale() void {
    var x: f32 = 0;
    for (0..3) |k| {
        const s = sd_c[k] * sd_c[k] + sd_c[4 + k] * sd_c[4 + k] + sd_c[8 + k] * sd_c[8 + k];
        x = maxss(x, s);
    }
    sd_scale = @sqrt(x);
}

pub fn allocLeaves() bool {
    const n = sc.nnodes;
    sd_nodes = sc.smap(Leaf, n) orelse return false;
    lrec = sc.smap(LRec, n) orelse return false;
    return true;
}

pub fn freeLeaves() void {
    sc.sfree(&sd_nodes);
    sc.sfree(&lrec);
    sc.sfree(&rbuf);
    key_on = false;
}

/// The tile cache goes.
pub fn free() void {
    sdc_valid = false;
    sdc_store = false;
    sdc_use = false;
    sc.sfree(&sdc_col);
    sc.sfree(&sdc_dep);
    sc.sfree(&sdc_prev);
    sc.sfree(&toff);
    sc.sfree(&tlist);
    sc.sfree(&dirty_tiles);
}

fn viewKey() void {
    var k: [20]u32 = undefined;
    for (sd_c, 0..) |x, i| k[i] = @bitCast(x);
    k[12] = @bitCast(rs_x0);
    k[13] = @bitCast(rs_y0);
    k[14] = @bitCast(rs_w);
    k[15] = @bitCast(rs_h);
    k[16] = @bitCast(focal);
    k[17] = @bitCast(cx);
    k[18] = @bitCast(cy);
    k[19] = @bitCast(near);
    if (key_on and std.mem.eql(u32, &k, &key)) return;
    key = k;
    key_on = true;
    sc.full = true;
}

/// The sculpt object into the viewport being drawn (after the other meshes: their
/// colour and depth buffers). r in pixels.
pub fn draw(cv: *gfx.Canvas, r0: Rect, c: *const vp.Cam) void {
    if (!sc.on or sc.land) return;
    const r = r0.intersect(cv.clip).intersect(.{ .w = cv.w, .h = cv.h });
    if (r.w <= 0 or r.h <= 0 or cv.zbuf == null) return;
    if (!sc.valid()) return;
    sc.normalsDue();
    setCam(c);
    camScale();
    cv_px = cv.px;
    cv_z = cv.zbuf.?;
    cv_w = cv.w;
    rs_x0 = r.x;
    rs_y0 = r.y;
    rs_w = r.w;
    rs_h = r.h;
    near = vp.near;
    viewKey();
    // each leaf: its screen rectangle (viewport pixels) and how to draw it
    jobs.parallelFor(sc.nnodes, 256, &dummy, jobLeaves);
    if (!planRecords()) return;
    // tiles -> leaves (CSR)
    ntx = (rs_w + TILE - 1) >> TILE_SH;
    nty = (rs_h + TILE - 1) >> TILE_SH;
    const ntiles: usize = @intCast(ntx * nty);
    if (toff.len < ntiles + 2) {
        sc.sfree(&toff);
        toff = sc.smap(u32, ntiles + 2) orelse return;
    }
    @memset(toff[0 .. ntiles + 2], 0);
    for (sd_nodes[0..sc.nnodes]) |*n| {
        if (n.mode == 0) continue;
        var ty = n.y0 >> TILE_SH;
        while (ty <= n.y1 >> TILE_SH) : (ty += 1) {
            var tx = n.x0 >> TILE_SH;
            while (tx <= n.x1 >> TILE_SH) : (tx += 1) toff[@intCast(ty * ntx + tx + 1)] += 1;
        }
    }
    var sum: u32 = 0;
    for (toff[1 .. ntiles + 1]) |*t| {
        sum += t.*;
        t.* = sum;
    }
    if (tlist.len < sum) {
        sc.sfree(&tlist);
        tlist = sc.smap(u32, sum + sum / 4 + 64) orelse return;
    }
    for (sd_nodes[0..sc.nnodes], 0..) |*n, l| {
        if (n.mode == 0) continue;
        var ty = n.y0 >> TILE_SH;
        while (ty <= n.y1 >> TILE_SH) : (ty += 1) {
            var tx = n.x0 >> TILE_SH;
            while (tx <= n.x1 >> TILE_SH) : (tx += 1) {
                const i: usize = @intCast(ty * ntx + tx);
                tlist[toff[i]] = @intCast(l);
                toff[i] += 1;
            }
        }
    }
    var i = ntiles;
    while (i > 0) : (i -= 1) toff[i] = toff[i - 1];
    toff[0] = 0;
    cachePlan(ntiles); // which tiles to draw (strokes: few)
    leaves_projected.store(0, .monotonic);
    jobs.parallelFor(sc.nnodes, 64, &dummy, jobProj);
    sc.full = false;
    tiles_drawn.store(0, .monotonic);
    tiles_total = @intCast(ntiles);
    jobs.parallelFor(ntiles, 1, &dummy, tileJob);
    cacheDone();
}

/// Each leaf's screen rectangle from its bounding sphere (one transform;
/// conservative), culled when behind the eye or off the viewport; splat or
/// triangles; the splat stride.
fn jobLeaves(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |l| {
        const n = &sc.nodes[l];
        const d = &sd_nodes[l];
        d.mode = 0; // culled
        var sq: f32 = 0; // centre, radius
        var ctr: V3 = undefined;
        for (0..3) |k| {
            const e = n.max[k] - n.min[k];
            sq += e * e;
            ctr[k] = (n.min[k] + n.max[k]) * 0.5;
        }
        const rad = @sqrt(sq) * 0.5 * sd_scale; // (in camera units)
        const cam = sc.tocam(ctr);
        const zf = cam[2] - rad; // z of the sphere's front
        const zb = cam[2] + rad;
        if (!(zb >= near)) continue; // wholly behind: culled
        if (!(zf >= near)) { // reaching behind: anywhere, triangles
            d.x0 = 0;
            d.y0 = 0;
            d.x1 = rs_w - 1;
            d.y1 = rs_h - 1;
            d.mode = 2;
            continue;
        }
        // centre on screen, radius there (at the front: conservative)
        const k0 = focal / cam[2];
        const sx = cam[0] * k0 + cx;
        const sy = cy - cam[1] * k0;
        const sr = focal / zf * rad;
        var x0 = trunc32(sx - sr) -% rs_x0;
        var x1 = trunc32(sx + sr) -% rs_x0;
        var y0 = trunc32(sy - sr) -% rs_y0;
        var y1 = trunc32(sy + sr) -% rs_y0;
        if (x1 < 0 or y1 < 0 or x0 >= rs_w or y0 >= rs_h) continue;
        // pixels (before the clamp)
        const pix: u32 = @bitCast((x1 -% x0 +% 1) *% (y1 -% y0 +% 1));
        x0 = @max(x0, 0);
        y0 = @max(y0, 0);
        x1 = @min(x1, rs_w - 1);
        y1 = @min(y1, rs_h - 1);
        d.x0 = x0;
        d.y0 = y0;
        d.x1 = x1;
        d.y1 = y1;
        // splat when 2 vertices or more a pixel (fewer leave holes)
        d.mode = 1;
        d.stride = 1; // (every vertex)
        if (pix > n.vn >> 1) {
            d.mode = 2;
            continue;
        }
        // more than 2 vertices a pixel: every k-th, k = vertices / (2 pixels)
        const dbl = pix *% 2;
        if (dbl == 0) continue;
        const k = n.vn / dbl;
        if (k > 1) d.stride = k;
    }
}

/// Whether this frame draws only the tiles of the leaves that changed (a stroke, the
/// same view and viewport as the cached frame).
fn cachePlan(tiles: usize) void {
    sdc_use = false;
    sdc_store = false;
    const px: usize = @intCast(rs_w * rs_h);
    if (px > sdc_col.len) { // the buffers: viewport sized
        sdc_valid = false;
        sc.sfree(&sdc_col);
        sc.sfree(&sdc_dep);
        sdc_col = sc.smap(u32, px) orelse return none();
        sdc_dep = sc.smap(f32, px) orelse return none();
    }
    if (sc.nnodes > sdc_prev.len) { // last frame's leaf rectangles
        sdc_valid = false;
        sc.sfree(&sdc_prev);
        sdc_prev = sc.smap(Leaf, sc.nnodes) orelse return none();
    }
    const k = [6]i32{ rs_x0, rs_y0, rs_w, rs_h, cv_w, @intCast(sc.nnodes) }; // the same viewport as the cache?
    if (!std.mem.eql(i32, &k, &sdc_key)) {
        sdc_valid = false;
        sdc_key = k;
    }
    sdc_store = true;
    if (!sdc_valid or sc.full or !sc.stroking) return;
    if (dirty_tiles.len < tiles) { // the tiles of the changed leaves
        sc.sfree(&dirty_tiles);
        dirty_tiles = sc.smap(u8, tiles) orelse return;
    }
    @memset(dirty_tiles[0..tiles], 0);
    for (0..sc.nnodes) |l| {
        if (sc.lchg[l] == 0) continue;
        markTiles(&sd_nodes[l]); // where it is
        markTiles(&sdc_prev[l]); // where it was
    }
    sdc_use = true;
}

fn none() void {
    free();
}

fn markTiles(n: *const Leaf) void {
    if (n.mode == 0) return;
    const y0 = @max(n.y0 >> TILE_SH, 0);
    const y1 = @min(n.y1 >> TILE_SH, nty - 1);
    const x0 = @max(n.x0 >> TILE_SH, 0);
    const x1 = @min(n.x1 >> TILE_SH, ntx - 1);
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) dirty_tiles[@intCast(y * ntx + x)] = 1;
    }
}

/// This frame's leaf rectangles kept; the cache is this frame.
fn cacheDone() void {
    if (!sdc_store) return;
    @memcpy(sdc_prev[0..sc.nnodes], sd_nodes[0..sc.nnodes]);
    sdc_valid = true;
}

/// Its colour and depth, from the cache or into it.
fn tileCopy(x0: i32, y0: i32, x1: i32, y1: i32, from: bool) void {
    const w: usize = @intCast(x1 - x0);
    var y = y0;
    while (y < y1) : (y += 1) {
        const v: usize = @intCast(y * rs_w + x0); // the viewport's row: the cache
        const f: usize = @intCast((rs_y0 + y) * cv_w + rs_x0 + x0); // the buffers'
        if (from) {
            @memcpy(cv_px[f..][0..w], sdc_col[v..][0..w]);
            @memcpy(cv_z[f..][0..w], sdc_dep[v..][0..w]);
        } else {
            @memcpy(sdc_col[v..][0..w], cv_px[f..][0..w]);
            @memcpy(sdc_dep[v..][0..w], cv_z[f..][0..w]);
        }
    }
}

/// The leaves of each tile.
fn tileJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |t| {
        const ti: i32 = @intCast(t);
        const tx = @rem(ti, ntx);
        const ty = @divTrunc(ti, ntx);
        const x0 = tx << TILE_SH;
        const y0 = ty << TILE_SH;
        const x1 = @min(x0 + TILE, rs_w);
        const y1 = @min(y0 + TILE, rs_h);
        if (sdc_use and dirty_tiles[t] == 0) { // a clean tile: the last frame's
            tileCopy(x0, y0, x1, y1, true);
            continue;
        }
        _ = tiles_drawn.fetchAdd(1, .monotonic);
        for (tlist[toff[t]..toff[t + 1]]) |l| {
            if (sd_nodes[l].mode == 1) {
                drawSplats(x0, y0, x1, y1, l);
            } else drawTris(x0, y0, x1, y1, l);
        }
        if (sdc_store) tileCopy(x0, y0, x1, y1, false); // (kept for the next frame)
    }
}

/// Two-sided headlight in camera space; masked vertices darker.
inline fn shade(n: V3, mask: u8) u32 {
    const c = &sd_c;
    var v = c[8] * n[0] + c[9] * n[1] + c[10] * n[2]; // camera z of the normal
    const a = c[8] * c[8] + c[9] * c[9] + c[10] * c[10]; // |rotated n| (the scale)
    const b = n[0] * n[0] + n[1] * n[1] + n[2] * n[2]; // |n| (face normals are not unit)
    const l = maxss(@sqrt(a * b), sf_tiny);
    v = v / l;
    v = minss(@abs(v), 1);
    v = v * 0.75;
    v = v + 0.25;
    if (mask != 0) { // masked: towards dark
        const k = @as(f32, @floatFromInt(mask)) * sc.sf_mask * mask_k;
        v = v * (1.0 - k);
    }
    v = v * 255.0;
    const r: u32 = @bitCast(trunc32(v * clay_r));
    const g: u32 = @bitCast(trunc32(v * clay_g));
    const bl: u32 = @bitCast(trunc32(v * clay_b));
    return r << 16 | g << 8 | bl;
}

/// Each splat leaf's room in the records: kept while the view stays (a leaf that
/// changed and needs more goes to the end, into the quarter kept spare), else all
/// laid out again. False: no memory.
fn planRecords() bool {
    if (!sc.full) {
        var ok = true;
        for (0..sc.nnodes) |l| {
            const d = &sd_nodes[l];
            const q = &lrec[l];
            if (d.mode != 1) {
                q.stride = 0; // not splats: no records to keep
                continue;
            }
            // a stroke keeps each leaf's splat stride (and so its room; without
            // this, growing leaves fill the spare and every leaf is laid out
            // again); its end lays them out for the view again
            if (sc.stroking and q.stride != 0) d.stride = q.stride;
            if (d.stride == q.stride and sc.lchg[l] == 0) continue; // the same stride and unchanged: the same room
            // changed (grown, shrunk, now splats): its room, if it fits, else at
            // the end, else everything again
            const need = sc.nodes[l].vn / d.stride + 1;
            if (need > q.room) {
                const e = rused + need;
                if (e > rbuf.len) {
                    ok = false;
                    break;
                }
                q.first = rused;
                q.room = need;
                rused = e;
            }
            q.stride = d.stride;
            sc.lchg[l] = 1;
        }
        if (ok) return true;
    }
    sc.full = true;
    var total: u32 = 0;
    for (0..sc.nnodes) |l| {
        const d = &sd_nodes[l];
        const q = &lrec[l];
        q.* = .{ .first = 0, .room = 0, .n = 0, .stride = 0 };
        if (d.mode != 1) continue;
        const need = sc.nodes[l].vn / d.stride + 1;
        q.first = total;
        q.room = need;
        total += need;
        q.stride = d.stride;
    }
    rused = total;
    if (total > rbuf.len) {
        sc.sfree(&rbuf); // (a quarter more: room to grow)
        rbuf = sc.smap(Rec, @as(usize, total) + total / 4) orelse return false;
    }
    return true;
}

/// Each splat leaf's sampled vertices projected and shaded once into its records (the
/// tiles it covers only depth-test them); while the view stays, only the leaves
/// that changed.
fn jobProj(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const use_mask = sc.masked;
    const p = sc.pos;
    const nrm = sc.vn.ptr;
    const vl = sc.vl.ptr;
    for (lo..hi) |l| {
        const chg = sc.lchg[l];
        sc.lchg[l] = 0; // (changed: drawn from now on)
        if (chg == 0 and !sc.full) continue;
        const d = &sd_nodes[l];
        if (d.mode != 1) continue;
        _ = leaves_projected.fetchAdd(1, .monotonic);
        const q = &lrec[l];
        const n = &sc.nodes[l];
        var i = n.voff;
        const e = n.voff + n.vn;
        const out = rbuf.ptr + q.first;
        var k: u32 = 0;
        while (i < e) : (i += d.stride) {
            const v = vl[i];
            const cam = sc.tocam(p[v]);
            if (!(cam[2] >= near)) continue;
            const iz = 1.0 / cam[2]; // 1/z
            const s = iz * focal;
            const x = trunc32(cam[0] * s + cx) -% rs_x0;
            const y = trunc32(cy - cam[1] * s) -% rs_y0;
            if (x < d.x0 or x > d.x1 or y < d.y0 or y > d.y1) continue; // (inside the leaf's clamped box)
            out[k] = .{ .x = x, .y = y, .iz = iz, .col = shade(nrm[v], if (use_mask) sc.mask[v] else 0) };
            k += 1;
        }
        q.n = k;
    }
}

/// Its records in the tile.
fn drawSplats(x0: i32, y0: i32, x1: i32, y1: i32, l: u32) void {
    const q = &lrec[l];
    const rw = rs_w;
    _ = rw;
    const base = rs_y0;
    for (rbuf[q.first..][0..q.n]) |*s| {
        if (s.x < x0 or s.x >= x1 or s.y < y0 or s.y >= y1) continue;
        const o: usize = @intCast((base + s.y) * cv_w + rs_x0 + s.x);
        if (s.iz <= cv_z[o]) continue;
        cv_z[o] = s.iz;
        cv_px[o] = s.col;
    }
}

inline fn edge(a: [3]f32, b: [3]f32, x: f32, y: f32) f32 {
    return (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]);
}

/// Its triangles, flat shaded, clipped to the tile (triangles reaching behind the
/// eye are skipped).
fn drawTris(tx0: i32, ty0: i32, tx1: i32, ty1: i32, l: u32) void {
    const n = &sc.nodes[l];
    const p = sc.pos;
    const fx: f32 = @floatFromInt(rs_x0);
    const fy: f32 = @floatFromInt(rs_y0);
    next: for (sc.tri[n.toff .. n.toff + n.tn]) |t| {
        var c: [3][3]f32 = undefined; // corners: screen x, y, 1/z
        const q = sc.tris[t];
        for (0..3) |k| {
            const cam = sc.tocam(p[q[k]]);
            if (!(cam[2] >= near)) continue :next;
            const iz = 1.0 / cam[2];
            const s = iz * focal;
            c[k] = .{ cam[0] * s + cx - fx, cy - cam[1] * s - fy, iz };
        }
        // area (signed, either side drawn)
        const area = (c[1][0] - c[0][0]) * (c[2][1] - c[0][1]) - (c[1][1] - c[0][1]) * (c[2][0] - c[0][0]);
        if (!(@abs(area) > sf_tiny)) continue;
        const col = shade(sc.faceN(t), 0); // its colour
        // the box, within the tile
        const x0 = @max(trunc32(minss(minss(c[0][0], c[1][0]), c[2][0])), tx0);
        const x1 = @min(trunc32(maxss(maxss(c[0][0], c[1][0]), c[2][0])) +% 1, tx1);
        const y0 = @max(trunc32(minss(minss(c[0][1], c[1][1]), c[2][1])), ty0);
        const y1 = @min(trunc32(maxss(maxss(c[0][1], c[1][1]), c[2][1])) +% 1, ty1);
        var y = y0;
        while (y < y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            var x = x0;
            while (x < x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                // weights: edge (b c) for a, (c a) for b, (a b) for c, over the area
                const w0 = edge(c[1], c[2], px, py) / area;
                const w1 = edge(c[2], c[0], px, py) / area;
                const w2 = edge(c[0], c[1], px, py) / area;
                if (w2 < 0 or w0 < 0 or w1 < 0) continue;
                const iz = w2 * c[2][2] + w0 * c[0][2] + w1 * c[1][2]; // 1/z interpolated
                const o: usize = @intCast((rs_y0 + y) * cv_w + rs_x0 + x);
                if (iz <= cv_z[o]) continue;
                cv_z[o] = iz;
                cv_px[o] = col;
            }
        }
    }
}
