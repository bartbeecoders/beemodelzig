// Instances (inst.s): one mesh drawn many times.
//
// A mesh may carry an instance block (ME_INST, geonodes.Geo.inst, and what the
// modifier stack shows of it): up to 8 prototype meshes (referenced) and, per
// instance, a 3x4 matrix (prototype space -> the mesh's space) and its
// prototype. Geometry nodes make them (Instance on Points); Realize Instances
// turns them into plain geometry.
//
// The viewport draws them without realizing (draw): every instance's
// prototype sphere is projected once; one smaller than about a pixel is a
// depth-tested splat, a bigger one has its prototype's triangles rasterized,
// flat shaded. Instances are binned into screen tiles first and the tiles
// drawn in parallel (no two threads write one pixel).
//
// Deliberate difference: the original reads each tile's list one tile off
// (its offsets are kept one place on: [toff[t], toff[t + 1]) is tile t - 1's),
// so a tile draws its left neighbour's instances, clipped to itself: the
// instances show in stripes. The port draws every tile's own. And particles
// drawn as objects moving straight up or down: the original's helper axis is
// always Y (it tests a stale lane), their matrices flat, so they are not seen;
// the port's turns to X as intended. (BEEMODEL_INST_TILES=orig draws both the
// original's way, for the tests.)
const std = @import("std");
const gn = @import("geonodes.zig");
const A = @import("alloc.zig").A;

const Geo = gn.Geo;
const V3 = gn.V3;
pub const M34 = [12]f32;

pub const MAXP = 8;

pub const Block = struct {
    refs: u32 = 1,
    n: u32 = 0,
    np: u32 = 0,
    cap: u32 = 0,
    proto: [MAXP]?*Geo = @splat(null),
    /// a matrix per instance (cap of them)
    mats: []M34,
    /// a prototype per instance
    pids: []u8,
};

/// Bumped when instances move in place (rigid bodies): what is drawn changed.
pub var ver: u32 = 0;

/// inst_new: a block for `cap` instances (refs 1, count 0), or null.
pub fn new(cap: u32) ?*Block {
    const b = A.create(Block) catch return null;
    const mt = A.alloc(M34, cap) catch {
        A.destroy(b);
        return null;
    };
    const p = A.alloc(u8, cap) catch {
        A.free(mt);
        A.destroy(b);
        return null;
    };
    @memset(p, 0);
    b.* = .{ .cap = cap, .mats = mt, .pids = p };
    return b;
}

pub fn ref(b: ?*Block) void {
    if (b) |x| x.refs += 1;
}

/// inst_unref: the last reference frees it (and drops its prototypes).
pub fn unref(b: ?*Block) void {
    const x = b orelse return;
    x.refs -= 1;
    if (x.refs != 0) return;
    for (x.proto[0..x.np]) |p| gn.unref(p);
    A.free(x.mats);
    A.free(x.pids);
    A.destroy(x);
}

/// inst_count of a mesh.
pub fn count(g: *const Geo) u32 {
    return if (g.inst) |b| b.n else 0;
}

/// inst_proto: the mesh's prototype id in the block (added, a reference taken;
/// -1: eight already).
pub fn proto(b: *Block, g: *Geo) i32 {
    for (b.proto[0..b.np], 0..) |p, k| {
        if (p == g) return @intCast(k);
    }
    if (b.np >= MAXP) return -1;
    b.proto[b.np] = g;
    b.np += 1;
    gn.ref(g);
    return @intCast(b.np - 1);
}

const ident: M34 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };

/// ir_append: a mesh's vertices placed by a matrix, its polygons after the
/// ones there (more than 255 corners: the first 255).
fn appendPlaced(v: *std.ArrayList(V3), o: *std.ArrayList(u32), l: *std.ArrayList(u32), g: *const Geo, mt: *const M34) !void {
    const off: u32 = @intCast(v.items.len);
    for (g.verts) |p| try v.append(A, gn.xf(mt, p));
    for (0..g.faces()) |p| {
        const idx = g.loops[g.poff[p]..g.poff[p + 1]];
        for (idx[0..@min(idx.len, 255)]) |x| try l.append(A, x + off);
        try o.append(A, @intCast(l.items.len));
    }
}

/// inst_realize: a new mesh: the mesh's own geometry and every instance's
/// prototype placed (no instances), or null.
pub fn realize(g: *Geo) ?*Geo {
    const b = g.inst orelse return gn.copy(g);
    var v: std.ArrayList(V3) = .empty;
    var o: std.ArrayList(u32) = .empty;
    var l: std.ArrayList(u32) = .empty;
    errdefer {
        v.deinit(A);
        o.deinit(A);
        l.deinit(A);
    }
    const fail = struct {
        fn f(vv: *std.ArrayList(V3), oo: *std.ArrayList(u32), ll: *std.ArrayList(u32)) ?*Geo {
            vv.deinit(A);
            oo.deinit(A);
            ll.deinit(A);
            return null;
        }
    }.f;
    o.append(A, 0) catch return fail(&v, &o, &l);
    appendPlaced(&v, &o, &l, g, &ident) catch return fail(&v, &o, &l);
    for (0..b.n) |i| {
        const p = b.proto[b.pids[i]] orelse continue;
        appendPlaced(&v, &o, &l, p, &b.mats[i]) catch return fail(&v, &o, &l);
    }
    const vs = v.toOwnedSlice(A) catch return fail(&v, &o, &l);
    const os = o.toOwnedSlice(A) catch {
        A.free(vs);
        return fail(&v, &o, &l);
    };
    const ls = l.toOwnedSlice(A) catch {
        A.free(vs);
        A.free(os);
        return null;
    };
    return gn.geoOf(vs, os, ls);
}

/// inst_mul: a x b (affine 3x4).
pub fn mul(a: *const M34, b: *const M34) M34 {
    var o: M34 = undefined;
    for (0..3) |r| {
        for (0..4) |c| {
            var x = a[r * 4] * b[c];
            x += a[r * 4 + 1] * b[4 + c];
            x += a[r * 4 + 2] * b[8 + c];
            if (c == 3) x += a[r * 4 + 3];
            o[r * 4 + c] = x;
        }
    }
    return o;
}

/// inst_xform: a new block: the same prototypes, every matrix placed by mt.
pub fn xform(b: *const Block, mt: *const M34) ?*Block {
    const nb = new(b.n) orelse return null;
    nb.n = b.n;
    for (b.proto[0..b.np]) |p| _ = proto(nb, p.?);
    @memcpy(nb.pids[0..b.n], b.pids[0..b.n]);
    for (0..b.n) |i| nb.mats[i] = mul(mt, &b.mats[i]);
    return nb;
}

/// im_copy: a block's matrices and prototypes into another at `first`
/// (prototypes renumbered; past eight: the first).
fn copyInto(from: *const Block, into: *Block, first: u32) void {
    var map: [MAXP]u8 = @splat(0);
    for (from.proto[0..from.np], 0..) |p, k| {
        const id = proto(into, p.?);
        map[k] = if (id < 0) 0 else @intCast(id);
    }
    @memcpy(into.mats[first..][0..from.n], from.mats[0..from.n]);
    for (0..from.n) |i| into.pids[first + i] = map[from.pids[i] & 7];
}

/// inst_merge: one block with both's instances (a reference: one of them when
/// the other is null; null for none).
pub fn merge(a: ?*Block, b: ?*Block) ?*Block {
    const x = a orelse {
        ref(b);
        return b;
    };
    const y = b orelse {
        ref(x);
        return x;
    };
    const nb = new(x.n + y.n) orelse return null;
    nb.n = x.n + y.n;
    copyInto(x, nb, 0);
    copyInto(y, nb, x.n);
    return nb;
}

// --- drawing (inst_draw) --------------------------------------------------------------------

const TILE = 16;
const gfx = @import("gfx.zig");
const jobs = @import("jobs.zig");
const fv = @import("fieldvm.zig");

/// Per instance: T (prototype -> camera), the box on screen, the mode (0
/// none, 1 splat, 2 triangles), 1/z.
const Rec = struct {
    t: M34,
    box: [4]i32,
    mode: u32,
    iz: f32,
};

const Draw = struct {
    b: *const Block,
    cw: M34,
    col: u32,
    w: i32,
    h: i32,
    focal: f32,
    cx: f32, // the centre, in the viewport (vp_cx - rs_x0)
    cy: f32,
    near: f32,
    pc: [MAXP][4]f32, // per prototype: centre, radius
    ptris: [MAXP][]const [3]u32,
    rec: []Rec,
    ntx: u32,
    nty: u32,
    toff: []u32,
    tlist: []u32,
    // the canvas
    px: [*]u32,
    zb: [*]f32,
    stride: usize,
    x0: i32,
    y0: i32,
};

fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

/// id_colour: the object's colour scaled (0x00RRGGBB).
fn colour(c: u32, k: f32) u32 {
    var out: u32 = 0;
    var sh: u5 = 16;
    while (true) {
        const ch: f32 = @floatFromInt((c >> sh) & 0xff);
        var v: u32 = @bitCast(fv.cvtt(ch * k));
        if (v > 255) v = 255;
        out |= v << sh;
        if (sh == 0) break;
        sh -= 8;
    }
    return out;
}

/// id_job_project: T = cw x M; the sphere on screen -> mode, box, 1/z.
fn project(p: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const d: *Draw = @ptrCast(@alignCast(p));
    for (lo..hi) |i| {
        const r = &d.rec[i];
        r.mode = 0;
        r.t = mul(&d.cw, &d.b.mats[i]);
        const t = &r.t;
        const pc = d.pc[d.b.pids[i] & 7];
        var c: [3]f32 = undefined;
        for (0..3) |row| {
            var x = t[row * 4] * pc[0];
            x += t[row * 4 + 1] * pc[1];
            x += t[row * 4 + 2] * pc[2];
            x += t[row * 4 + 3];
            c[row] = x;
        }
        var s0 = t[0] * t[0];
        s0 += t[4] * t[4];
        s0 += t[8] * t[8];
        var s1 = t[1] * t[1];
        s1 += t[5] * t[5];
        s1 += t[9] * t[9];
        s0 = maxss(s0, s1);
        var s2 = t[2] * t[2];
        s2 += t[6] * t[6];
        s2 += t[10] * t[10];
        s0 = maxss(s0, s2);
        const rad = @sqrt(s0) * pc[3];
        if (!(c[2] - rad >= d.near)) continue;
        const iz = 1.0 / c[2];
        r.iz = iz;
        const k = iz * d.focal;
        var x = c[0] * k;
        x += d.cx;
        var y = c[1] * k;
        y = d.cy - y;
        const rp = k * rad;
        r.box = .{ fv.cvtt(x - rp), fv.cvtt(y - rp), fv.cvtt(x + rp) +% 1, fv.cvtt(y + rp) +% 1 };
        if (r.box[2] <= 0 or r.box[3] <= 0 or r.box[0] >= d.w or r.box[1] >= d.h) continue;
        r.mode = 2;
        if (rp >= 3.0) continue; // (triangles; else a square at the centre: 1.4 radii, 1 px at least)
        var side = fv.cvtt(rp * 1.4);
        if (side < 1) side = 1;
        const half = side >> 1;
        const bx = fv.cvtt(x) -% half;
        const by = fv.cvtt(y) -% half;
        r.box = .{ bx, by, bx +% side, by +% side };
        r.mode = if (r.box[2] <= 0 or r.box[3] <= 0 or r.box[0] >= d.w or r.box[1] >= d.h) 0 else 1;
    }
}

/// id_tiles: a record's tile range (x0 y0 x1 y1, inclusive).
fn tilesOf(d: *const Draw, r: *const Rec) [4]i32 {
    const x0 = @max(r.box[0], 0) >> 4;
    const y0 = @max(r.box[1], 0) >> 4;
    var x1 = (r.box[2] -% 1) >> 4;
    if (x1 >= @as(i32, @intCast(d.ntx))) x1 = @as(i32, @intCast(d.ntx)) - 1;
    var y1 = (r.box[3] -% 1) >> 4;
    if (y1 >= @as(i32, @intCast(d.nty))) y1 = @as(i32, @intCast(d.nty)) - 1;
    return .{ x0, y0, x1, y1 };
}

/// id_plot: depth tested (1/z: nearer is larger).
inline fn plot(d: *const Draw, x: i32, y: i32, iz: f32, col: u32) void {
    const o = @as(usize, @intCast(d.y0 + y)) * d.stride + @as(usize, @intCast(d.x0 + x));
    if (!(iz > d.zb[o])) return;
    d.zb[o] = iz;
    d.px[o] = col;
}

/// id_job_tile: each tile's instances drawn into it.
fn tileJob(p: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const d: *Draw = @ptrCast(@alignCast(p));
    for (lo..hi) |ti| {
        const tx: i32 = @intCast(ti % d.ntx);
        const ty: i32 = @intCast(ti / d.ntx);
        const tb: [4]i32 = .{ tx * TILE, ty * TILE, @min(tx * TILE + TILE, d.w), @min(ty * TILE + TILE, d.h) };
        // (BEEMODEL_INST_TILES=orig: the original's off-by-one, each tile
        // drawn with its predecessor's list - tests compare pixels so)
        const lt = if (orig_tiles) (if (ti == 0) continue else ti - 1) else ti;
        for (d.tlist[d.toff[lt]..d.toff[lt + 1]]) |i| {
            const r = &d.rec[i];
            if (r.mode == 1) {
                const col = colour(d.col, 0.85);
                const ya = @max(r.box[1], tb[1]);
                const yb = @min(r.box[3], tb[3]);
                var y = ya;
                while (y < yb) : (y += 1) {
                    var x = @max(r.box[0], tb[0]);
                    const xb = @min(r.box[2], tb[2]);
                    while (x < xb) : (x += 1) plot(d, x, y, r.iz, col);
                }
                continue;
            }
            tris(d, &tb, i);
        }
    }
}

/// id_tris: an instance's prototype triangles (T: prototype -> camera), flat
/// shaded, clipped to the tile (triangles reaching behind the eye skipped).
fn tris(d: *const Draw, tb: *const [4]i32, i: u32) void {
    const r = &d.rec[i];
    const pid = d.b.pids[i] & 7;
    const g = d.b.proto[pid] orelse return;
    const t = &r.t;
    tri: for (d.ptris[pid]) |tr| {
        var cam: [3][3]f32 = undefined;
        var sc: [3][3]f32 = undefined;
        for (0..3) |q| {
            const p = g.verts[tr[q]];
            for (0..3) |row| {
                var x = t[row * 4] * p[0];
                x += t[row * 4 + 1] * p[1];
                x += t[row * 4 + 2] * p[2];
                x += t[row * 4 + 3];
                cam[q][row] = x;
            }
            if (!(cam[q][2] >= d.near)) continue :tri;
            const iz = 1.0 / cam[q][2];
            const k = iz * d.focal;
            var x = cam[q][0] * k;
            x += d.cx;
            var y = cam[q][1] * k;
            y = d.cy - y;
            sc[q] = .{ x, y, iz };
        }
        // area (signed: back faces skipped)
        var area = (sc[1][0] - sc[0][0]) * (sc[2][1] - sc[0][1]);
        area -= (sc[1][1] - sc[0][1]) * (sc[2][0] - sc[0][0]);
        if (!(area > 0)) continue;
        if (!(@abs(area) > 1.0e-20)) continue;
        var bx0 = fv.cvtt(minss(minss(sc[0][0], sc[1][0]), sc[2][0]));
        if (bx0 < tb[0]) bx0 = tb[0];
        var bx1 = fv.cvtt(maxss(maxss(sc[0][0], sc[1][0]), sc[2][0])) +% 1;
        if (bx1 > tb[2]) bx1 = tb[2];
        var by0 = fv.cvtt(minss(minss(sc[0][1], sc[1][1]), sc[2][1]));
        if (by0 < tb[1]) by0 = tb[1];
        var by1 = fv.cvtt(maxss(maxss(sc[0][1], sc[1][1]), sc[2][1])) +% 1;
        if (by1 > tb[3]) by1 = tb[3];
        if (bx0 >= bx1 or by0 >= by1) continue;
        // id_face_shade: ambient + diffuse x |n.z| / |n|
        const e1: [3]f32 = .{ cam[1][0] - cam[0][0], cam[1][1] - cam[0][1], cam[1][2] - cam[0][2] };
        const e2: [3]f32 = .{ cam[2][0] - cam[0][0], cam[2][1] - cam[0][1], cam[2][2] - cam[0][2] };
        const nx = e1[1] * e2[2] - e1[2] * e2[1];
        const ny = e1[2] * e2[0] - e2[2] * e1[0];
        const nz = e1[0] * e2[1] - e1[1] * e2[0];
        var l = nx * nx;
        l += ny * ny;
        l += nz * nz;
        l = maxss(@sqrt(l), 1.0e-20);
        var lit = @abs(nz) / l;
        lit *= 0.75;
        lit += 0.25;
        const col = colour(d.col, lit);
        // edge functions, stepped: w_k = (a_k x + b_k y + c_k) / area
        const inv = 1.0 / area;
        var ea: [3]f32 = undefined;
        var eb: [3]f32 = undefined;
        var ec: [3]f32 = undefined;
        for (0..3) |k| {
            const a_ = (k + 1) % 3;
            const b_ = (k + 2) % 3;
            const ka = sc[a_][1] - sc[b_][1];
            const kb = sc[b_][0] - sc[a_][0];
            var kc = kb * sc[a_][1];
            kc += ka * sc[a_][0];
            kc = 0 - kc;
            ea[k] = ka * inv;
            eb[k] = kb * inv;
            ec[k] = kc * inv;
        }
        var y = by0;
        while (y < by1) : (y += 1) {
            const fx = @as(f32, @floatFromInt(bx0)) + 0.5;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            var w: [3]f32 = undefined;
            for (0..3) |k| {
                var v = ea[k] * fx;
                v += eb[k] * fy;
                v += ec[k];
                w[k] = v;
            }
            var x = bx0;
            while (x < bx1) : (x += 1) {
                if (w[0] >= 0 and w[1] >= 0 and w[2] >= 0) {
                    var iz = w[0] * sc[0][2];
                    iz += w[1] * sc[1][2];
                    iz += w[2] * sc[2][2];
                    plot(d, x, y, iz, col);
                }
                w[0] += ea[0];
                w[1] += ea[1];
                w[2] += ea[2];
            }
        }
    }
}

/// The original's tile lists, read one off (see tileJob).
var orig_tiles = false;
var orig_tiles_known = false;

fn readOrigEnv() void {
    if (orig_tiles_known) return;
    orig_tiles_known = true;
    if (@import("spawn.zig").getenv("BEEMODEL_INST_TILES")) |v| orig_tiles = std.mem.eql(u8, v, "orig");
}

/// The instances drawn so far this frame (tests, the status).
pub var drawn: u32 = 0;

/// inst_draw_ib / id_object: a block of instances placed by `mtx` (a 4x4 row
/// major, world) drawn into the viewport `r` of the canvas (after the
/// rasterizer: its colour and depth), in colour `col`.
pub fn drawBlock(cv: *gfx.Canvas, r: gfx.Rect, cam: anytype, near: f32, b: *const Block, mtx: [16]f32, col: u32) void {
    if (b.n == 0 or r.w <= 0 or r.h <= 0) return;
    const zb = cv.zbuf orelse return;
    var d: Draw = undefined;
    d.b = b;
    d.col = col;
    d.w = r.w;
    d.h = r.h;
    d.focal = cam.f;
    d.cx = cam.cx - @as(f32, @floatFromInt(r.x));
    d.cy = cam.cy - @as(f32, @floatFromInt(r.y));
    d.near = near;
    d.px = cv.px;
    d.zb = zb;
    d.stride = @intCast(cv.w);
    d.x0 = r.x;
    d.y0 = r.y;
    // id_cam: cw = view x object
    const rows = [3]V3{ cam.right, cam.up, cam.fwd };
    for (0..3) |row| {
        const R = rows[row];
        for (0..3) |j| {
            var x = R[0] * mtx[j];
            x += R[1] * mtx[4 + j];
            x += R[2] * mtx[8 + j];
            d.cw[row * 4 + j] = x;
        }
        var x = (mtx[3] - cam.eye[0]) * R[0];
        x += (mtx[7] - cam.eye[1]) * R[1];
        x += (mtx[11] - cam.eye[2]) * R[2];
        d.cw[row * 4 + 3] = x;
    }
    // prototype spheres, triangles
    for (0..MAXP) |k| {
        d.ptris[k] = &.{};
        d.pc[k] = .{ 0, 0, 0, 0 };
        if (k >= b.np) continue;
        const g = b.proto[k] orelse continue;
        var lo: V3 = .{ 1.0e30, 1.0e30, 1.0e30 };
        var hi: V3 = .{ -1.0e30, -1.0e30, -1.0e30 };
        for (g.verts) |p| for (0..3) |c| {
            lo[c] = minss(lo[c], p[c]);
            hi[c] = maxss(hi[c], p[c]);
        };
        var rr: f32 = 0;
        for (0..3) |c| {
            d.pc[k][c] = (lo[c] + hi[c]) * 0.5;
            const e = hi[c] - lo[c];
            rr += e * e;
        }
        d.pc[k][3] = @sqrt(rr) * 0.5;
        d.ptris[k] = gn.trisOf(g);
    }
    d.rec = A.alloc(Rec, b.n) catch return;
    defer A.free(d.rec);
    jobs.parallelFor(b.n, 4096, &d, project);
    d.ntx = @intCast(@divTrunc(r.w + TILE - 1, TILE));
    d.nty = @intCast(@divTrunc(r.h + TILE - 1, TILE));
    const nt_ = d.ntx * d.nty;
    d.toff = A.alloc(u32, nt_ + 1) catch return;
    defer A.free(d.toff);
    @memset(d.toff, 0);
    // tiles -> instances (in instance order: the same picture on any number of threads)
    var total: usize = 0;
    for (d.rec) |*rc| {
        if (rc.mode == 0) continue;
        const tr = tilesOf(&d, rc);
        var y = tr[1];
        while (y <= tr[3]) : (y += 1) {
            var x = tr[0];
            while (x <= tr[2]) : (x += 1) {
                d.toff[@as(usize, @intCast(y)) * d.ntx + @as(usize, @intCast(x))] += 1;
                total += 1;
            }
        }
    }
    var sum: u32 = 0;
    for (d.toff[0..nt_]) |*c| {
        const t = c.*;
        c.* = sum;
        sum += t;
    }
    d.toff[nt_] = sum;
    d.tlist = A.alloc(u32, total) catch return;
    defer A.free(d.tlist);
    const cur = A.dupe(u32, d.toff[0..nt_]) catch return;
    defer A.free(cur);
    for (d.rec, 0..) |*rc, i| {
        if (rc.mode == 0) continue;
        const tr = tilesOf(&d, rc);
        var y = tr[1];
        while (y <= tr[3]) : (y += 1) {
            var x = tr[0];
            while (x <= tr[2]) : (x += 1) {
                const ti = @as(usize, @intCast(y)) * d.ntx + @as(usize, @intCast(x));
                d.tlist[cur[ti]] = @intCast(i);
                cur[ti] += 1;
            }
        }
    }
    jobs.parallelFor(nt_, 1, &d, tileJob);
    drawn += b.n;
}

/// inst_draw: every mesh object's instances into the viewport.
pub fn draw(cv: *gfx.Canvas, r: gfx.Rect, cam: anytype, near: f32) void {
    drawn = 0;
    readOrigEnv();
    const scene = @import("scene.zig");
    const mods = @import("mods.zig");
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.kind.isMesh() or !o.visible) continue;
        const b = mods.instancesOf(oi) orelse continue;
        if (b.n == 0) continue;
        // mat_display_color: the material's base, else COL_SOLID (the original's
        // colour for objects without one, as inst_draw has it)
        const mat = @import("material.zig");
        const col: u32 = if (mat.of(o) != null) mat.displayColor(o) else 0xbfc3ca;
        drawBlock(cv, r, cam, near, b, scene.world(oi), col);
    }
}

// --- particles drawn as objects (pt_iblock, inst_draw_ib) --------------------------------

/// Per running system: its instance block and what it was made for.
var pd_ib: [64]?*Block = @splat(null);
var pd_ibk: [64]u64 = @splat(0);
/// The particles' ball when a system names no objects (an icosahedron).
var pt_sphere: ?*Geo = null;

fn icosahedron() ?*Geo {
    if (pt_sphere) |g| return g;
    const v = [12]V3{
        .{ -0.52573111, 0.85065081, 0 }, .{ 0.52573111, 0.85065081, 0 },  .{ -0.52573111, -0.85065081, 0 }, .{ 0.52573111, -0.85065081, 0 },
        .{ 0, -0.52573111, 0.85065081 }, .{ 0, 0.52573111, 0.85065081 },  .{ 0, -0.52573111, -0.85065081 }, .{ 0, 0.52573111, -0.85065081 },
        .{ 0.85065081, 0, -0.52573111 }, .{ 0.85065081, 0, 0.52573111 },  .{ -0.85065081, 0, -0.52573111 }, .{ -0.85065081, 0, 0.52573111 },
    };
    const f = [60]u32{ 0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8, 3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1 };
    var o: [21]u32 = undefined;
    for (&o, 0..) |*x, k| x.* = @intCast(k * 3);
    pt_sphere = gn.geoCopyP(.{ .verts = @constCast(&v), .poff = &o, .loops = @constCast(&f) });
    return pt_sphere;
}

/// pt_iblock: system si's particles as instances (made again when they move):
/// prototypes its objects (their evaluated meshes) or a ball; per particle one
/// of them by its id, its size over its life, turned along its velocity or at
/// random, at its place. Null: none.
pub fn particleBlock(si: u32) ?*Block {
    const pt = @import("particles.zig");
    const rc = @import("rbcore.zig");
    const scene = @import("scene.zig");
    if (si >= pd_ib.len) return null;
    const s = &pt.sr[si];
    const key = pt.stateWord();
    if (pd_ib[si] != null and pd_ibk[si] == key) return pd_ib[si];
    pd_ibk[si] = key;
    unref(pd_ib[si]);
    pd_ib[si] = null;
    const r = pt.nth(s.uid, s.k) orelse return null;
    if (s.n == 0) return null;
    const b = new(s.n) orelse return null;
    pd_ib[si] = b;
    var ids: [MAXP]u8 = undefined;
    var nid: u32 = 0;
    if (r.draw == 2) {
        for (r.objs[0..@min(r.nobj, 8)]) |uid| {
            const oi = scene.findUid(uid) orelse continue;
            const me = @import("mods.zig").of(oi) orelse continue;
            if (me.tris.len == 0) continue;
            const g = gn.geoCopyP(.{ .verts = me.verts, .poff = me.poff, .loops = me.loops }) orelse continue;
            const id = proto(b, g);
            gn.unref(g); // (the block holds it)
            if (id < 0) continue;
            ids[nid] = @intCast(id);
            nid += 1;
        }
    }
    if (nid == 0) {
        const g = icosahedron() orelse return null;
        _ = proto(b, g);
        ids[0] = 0;
        nid = 1;
    }
    b.n = s.n;
    var k: u32 = 0;
    for (pt.sblk[si][0..s.nb]) |bk| {
        const cnt = pt.bn[bk];
        const id_a = pt.arrU(bk, pt.A_ID);
        for (0..cnt) |j| {
            if (k >= b.cap) break;
            const id = id_a[j];
            var w = fv.cvtt(pt.prand(id, 9, s.seed) * @as(f32, @floatFromInt(nid)));
            if (@as(u32, @bitCast(w)) > nid - 1) w = @intCast(nid - 1);
            b.pids[k] = ids[@intCast(w)];
            var t = pt.arr(bk, pt.A_AGE)[j] / pt.arr(bk, pt.A_LIFE)[j];
            t = if (t > 0) t else 0;
            t = if (t < 1) t else 1;
            var sc = (r.sizeend - 1.0) * t;
            sc += 1.0;
            sc *= pt.arr(bk, pt.A_SIZE)[j];
            if (r.draw != 2) sc *= 0.5;
            const vel: rc.V4 = .{ pt.arr(bk, pt.A_VX)[j], pt.arr(bk, pt.A_VY)[j], pt.arr(bk, pt.A_VZ)[j], 0 };
            var x: rc.V4 = undefined;
            if (r.alignv == 1 and rc.dot3(vel, vel) > 1.0e-12) {
                x = vel;
            } else {
                var c = pt.prand(id, 10, s.seed);
                c += c;
                c -= 1.0;
                const ph = pt.prand(id, 11, s.seed) * 6.28318531;
                const scs = fv.x87sincos(ph);
                var q = 1.0 - c * c;
                q = if (q > 0) q else 0;
                q = @sqrt(q);
                x = .{ scs[1] * q, scs[0] * q, c, 0 };
            }
            x = pt.unit(x);
            // (a helper axis: X when x is near Y. The original tests a stale
            // lane - always 0 - so it always takes Y, and a particle moving
            // straight up or down gets a flat matrix and is not seen: kept
            // with BEEMODEL_INST_TILES=orig for the tests)
            const helper: rc.V4 = if (!orig_tiles and @abs(x[1]) > 0.9) .{ 1, 0, 0, 0 } else .{ 0, 1, 0, 0 };
            const z = pt.unit(rc.cross(x, helper));
            const y = rc.cross(z, x);
            const pos = [3]f32{ pt.arr(bk, pt.A_X)[j], pt.arr(bk, pt.A_Y)[j], pt.arr(bk, pt.A_Z)[j] };
            const xa: [4]f32 = x;
            const ya: [4]f32 = y;
            const za: [4]f32 = z;
            for (0..3) |row| {
                b.mats[k][row * 4] = xa[row] * sc;
                b.mats[k][row * 4 + 1] = ya[row] * sc;
                b.mats[k][row * 4 + 2] = za[row] * sc;
                b.mats[k][row * 4 + 3] = pos[row];
            }
            k += 1;
        }
    }
    b.n = k;
    return b;
}

const ident4: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

/// inst_draw_ib: system si's particles drawn as objects (in the world, its colour).
pub fn drawParticles(cv: *gfx.Canvas, r: gfx.Rect, cam: anytype, near: f32, si: u32, col: u32) void {
    readOrigEnv();
    const b = particleBlock(si) orelse return;
    drawBlock(cv, r, cam, near, b, ident4, col);
}

// --- tests ---------------------------------------------------------------------------------

test "merge, transform, realize" {
    const cube = gn.geoCopyP(.{ .verts = @constCast(&[_]V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } }), .poff = @constCast(&[_]u32{ 0, 3 }), .loops = @constCast(&[_]u32{ 0, 1, 2 }) }).?;
    defer gn.unref(cube);
    const b = new(2).?;
    b.n = 2;
    try std.testing.expectEqual(@as(i32, 0), proto(b, cube));
    try std.testing.expectEqual(@as(i32, 0), proto(b, cube));
    b.mats[0] = ident;
    b.mats[1] = .{ 2, 0, 0, 5, 0, 2, 0, 0, 0, 0, 2, 0 };
    const c = merge(b, b).?;
    try std.testing.expectEqual(@as(u32, 4), c.n);
    try std.testing.expectEqual(@as(u32, 1), c.np);
    const t = xform(c, &.{ 1, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1, 3 }).?;
    try std.testing.expectEqual(@as(f32, 6), t.mats[1][3]);
    const holder = gn.empty().?;
    holder.inst = t;
    const r = realize(holder).?;
    try std.testing.expectEqual(@as(usize, 12), r.verts.len);
    try std.testing.expectEqual(@as(u32, 4), r.faces());
    try std.testing.expectEqual(V3{ 8, 2, 3 }, r.verts[4]);
    gn.unref(r);
    gn.unref(holder);
    unref(c);
    unref(b);
}

test "projection: a sphere 2.5 px across is a 3 px splat, a big one triangles, behind the eye none" {
    const cube = gn.geoCopyP(.{ .verts = @constCast(&[_]V3{ .{ -1, -1, -1 }, .{ 1, 1, 1 } }), .poff = @constCast(&[_]u32{0}), .loops = @constCast(&[_]u32{}) }).?;
    defer gn.unref(cube);
    const b = new(3).?;
    defer unref(b);
    b.n = 3;
    _ = proto(b, cube);
    // radius sqrt(12) / 2 = 1.7320508; at z 100 with focal 144.33757: 2.5 px
    const s: f32 = 1.0;
    b.mats[0] = .{ s, 0, 0, 0, 0, s, 0, 0, 0, 0, s, 100 };
    b.mats[1] = .{ s, 0, 0, 0, 0, s, 0, 0, 0, 0, s, 10 };
    b.mats[2] = .{ s, 0, 0, 0, 0, s, 0, 0, 0, 0, s, -5 };
    var rec: [3]Rec = undefined;
    var d: Draw = undefined;
    d.b = b;
    d.cw = ident;
    d.w = 200;
    d.h = 200;
    d.focal = 144.33757;
    d.cx = 100;
    d.cy = 100;
    d.near = 0.05;
    d.pc[0] = .{ 0, 0, 0, @sqrt(@as(f32, 12)) * 0.5 };
    d.rec = &rec;
    project(&d, 0, 3, 0);
    try std.testing.expectEqual(@as(u32, 1), rec[0].mode);
    // side cvtt(2.5 x 1.4) = 3, half 1: from 99 to 102
    try std.testing.expectEqual([4]i32{ 99, 99, 102, 102 }, rec[0].box);
    try std.testing.expectEqual(@as(u32, 2), rec[1].mode);
    try std.testing.expectEqual(@as(u32, 0), rec[2].mode);
}
