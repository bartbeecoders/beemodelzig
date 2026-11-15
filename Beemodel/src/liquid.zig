// The liquid solver (liquid.s, stage P4): position-based fluids.
//
// A particle system with liquid on is water (or oil, or honey): each frame
// its particles (gathered by particles.zig into x, v) are moved in a few
// substeps. Each substep:
//   predict    v += a dt, p = x + v dt
//   neighbours a hash grid of cells the kernel's size (counting sort, in the
//              particles' order), up to 96 neighbours each within h
//   iterations density constraints (Macklin & Muller 2013): lambda_i =
//              -C_i / (sum |grad C|^2 + eps), C = rho / rho0 - 1 (not below
//              0); dp_i = (m / rho0) sum (lambda_i + lambda_j + s_corr) grad W
//              (s_corr: the tensile term, surface tension); then the domain
//              box, and moving rigid bodies push the liquid out and are pushed
//              back (their impulses summed per chunk, in order)
//   colliders  the step's path cast against the ground and triangles
//              (particles.zig cast)
//   velocity   v = (p - x) / dt, XSPH viscosity, vorticity confinement
// The kernels are poly6 for density and spiky for gradients, h = 2 x the
// spacing; the particles' mass makes a lattice at that spacing exactly the
// rest density. The domain's faces and the Ground are walls: a lattice beyond
// them adds its density and pressure (a table by distance). Everything per
// particle runs in parallel; the sums are in a fixed order, so the same on
// any number of threads, and the same numbers as the original's.
//
// Not in the port yet: the GPU path (liquid.s lq_gpu, the helper's liq.comp):
// the CPU's always, which is what the original does without a GPU or with
// BEEMODEL_GPU_LIQUID=off.
const std = @import("std");
const linux = std.os.linux;
const rc = @import("rbcore.zig");
const jobs = @import("jobs.zig");
const fields = @import("fields.zig");
const pt = @import("particles.zig");

const V4 = rc.V4;
const dot3 = rc.dot3;
const cross = rc.cross;
const minss = rc.minss;
const maxss = rc.maxss;
const minps = rc.minps;
const maxps = rc.maxps;
const andXyz = rc.andXyz;
const splat = rc.splat;

pub const MAXN = 4194304;
const NB = 96; // neighbours at most
const GRAIN = 2048;
const MAXB = 16; // moving bodies the liquid pushes
const MAXCH = MAXN / GRAIN; // chunks (impulse sums)
const WT = 32; // the walls' table: steps over h
const MAXW = 8;

pub var x: [*]V4 = undefined; // positions, velocities
pub var v: [*]V4 = undefined;
var p: [*]V4 = undefined; // predicted
var dp: [*]V4 = undefined;
var w: [*]V4 = undefined; // vorticity
var v2: [*]V4 = undefined;
var lam: [*]f32 = undefined;
var rho: [*]f32 = undefined;
var cell: [*]u32 = undefined;
var sort: [*]u32 = undefined;
var start: [*]u32 = undefined; // each bucket's first (table + 1)
var nb: [*]u32 = undefined; // neighbours (NB each)
pub var nn: [*]u32 = undefined; //  how many
var imp: [*]V4 = undefined; // impulses: chunk x body
var cap: u32 = 0;

var n: u32 = 0;
var mask: u32 = 0;
var h: f32 = 0;
var h2: f32 = 0;
var ih: f32 = 0;
var k6: f32 = 0;
var ks: f32 = 0;
var m: f32 = 0; // mass
var mr: f32 = 0; // mass / rest density
var rho0: f32 = 0;
var eps: f32 = 0;
var wdq: f32 = 0; // W(0.2 h)
var tk: f32 = 0; // the tensile term's k
var dt: f32 = 0; // the substep
var idt: f32 = 0;
var rp: f32 = 0; // a particle's radius
var dom: bool = false;
var visc: f32 = 0;
var vort: f32 = 0;
var nfields: u32 = 0;
var gbit: u32 = 0;
var acc: V4 = @splat(0);
var gadj: V4 = @splat(0);
var dmin: V4 = @splat(0);
var dmax: V4 = @splat(0);
var fdt: f32 = 0; // the frame's step
var ms: f32 = 0; // the last solve (ms)
var nmax: u32 = 0;
var rmax: u32 = 0; // the densest (rho / rho0's bits; a statistic)
var rmaxi: u32 = 0;
var tjob: u64 = 0;

// the walls: each its normal into the liquid (w: its offset: s = n.p - w)
var wall: [MAXW]V4 = undefined;
var nw: u32 = 0;
var wd: [WT + 2]f32 = undefined; // a wall's density at s (sum of W),
var wg: [WT + 2]f32 = undefined; //  its grad W along the normal

// the moving bodies
var nbd: u32 = 0;
var bc: [MAXB]V4 = undefined; // centre now (this substep)
var bh: [MAXB]V4 = undefined; // half size (w: rounding + radius)
var br: [MAXB][3]V4 = undefined; // rotation rows
var bmin: [MAXB]V4 = undefined;
var bmax: [MAXB]V4 = undefined;
var bc0: [MAXB]V4 = undefined; // where each was the frame before
var bc1: [MAXB]V4 = undefined; //  and is now
var bobj: [MAXB]u32 = undefined;
var bptr: [MAXB]u32 = undefined;
var pc: [MAXB]V4 = undefined; // (kept: the last frame's centres)
var pobj: [MAXB]u32 = undefined;
var np: u32 = 0;

fn map(bytes: usize) ?[*]u8 {
    const r = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    if (linux.errno(r) != .SUCCESS) return null;
    return @ptrFromInt(r);
}

/// lq_room: the arrays have room for that many particles.
pub fn room(count: u32) bool {
    if (count > MAXN) return false;
    if (cap != 0) return true;
    const N: usize = MAXN;
    x = @ptrCast(@alignCast(map(N * 16 + 4096) orelse return false));
    v = @ptrCast(@alignCast(map(N * 16 + 4096) orelse return false));
    p = @ptrCast(@alignCast(map(N * 16 + 4096) orelse return false));
    dp = @ptrCast(@alignCast(map(N * 16 + 4096) orelse return false));
    w = @ptrCast(@alignCast(map(N * 16 + 4096) orelse return false));
    v2 = @ptrCast(@alignCast(map(N * 16 + 4096) orelse return false));
    lam = @ptrCast(@alignCast(map(N * 4 + 4096) orelse return false));
    rho = @ptrCast(@alignCast(map(N * 4 + 4096) orelse return false));
    cell = @ptrCast(@alignCast(map(N * 4 + 4096) orelse return false));
    sort = @ptrCast(@alignCast(map(N * 4 + 4096) orelse return false));
    start = @ptrCast(@alignCast(map(N * 16 + 4096) orelse return false));
    nb = @ptrCast(@alignCast(map(N * NB * 4 + 4096) orelse return false));
    nn = @ptrCast(@alignCast(map(N * 4 + 4096) orelse return false));
    imp = @ptrCast(@alignCast(map(MAXCH * MAXB * 16) orelse return false));
    cap = MAXN;
    return true;
}

/// lq_info: 0 the last solve (ms), 1 the most neighbours, 2 the mass, 3 the
/// kernel's size, 4 the densest (rho / rho0), 5..7 where it is, 8 the jobs'
/// share (ms).
pub fn info(k: i32) f32 {
    return switch (k) {
        0 => ms,
        1 => @floatFromInt(nmax),
        2 => m,
        3 => h,
        4 => @bitCast(rmax),
        8 => @as(f32, @floatFromInt(@as(i64, @intCast(tjob)))) * 0.001 * 0.001,
        5 => if (cap != 0) x[rmaxi][0] else 0,
        6 => if (cap != 0) x[rmaxi][1] else 0,
        7 => if (cap != 0) x[rmaxi][2] else 0,
        else => 0,
    };
}

/// w6: poly6 W at r^2 (0 past h).
inline fn w6(r2: f32) f32 {
    const t = h2 - r2;
    if (!(t > 0)) return 0;
    return t * t * t * k6;
}

/// apart: two at one place get a small way apart (odd in i - j: the pair's
/// two sides agree): the difference and its length squared.
inline fn apart(i: u32, j: u32, d: V4, r2: f32) struct { d: V4, r2: f32 } {
    if (r2 >= 1.0e-10) return .{ .d = d, .r2 = r2 };
    const df: i32 = @as(i32, @bitCast(i)) -% @as(i32, @bitCast(j));
    const neg = df < 0;
    const a: u32 = @bitCast(if (neg) -%df else df);
    const hsh = a *% 0x9E3779B1;
    var q: V4 = .{ @floatFromInt(hsh & 255), @floatFromInt(hsh >> 8 & 255), @floatFromInt(hsh >> 16 & 255), 0 };
    q = andXyz(q - splat(128));
    if (neg) q = rc.neg3(q);
    const s = 0.001 * h / 128.0;
    q = andXyz(q * splat(s));
    return .{ .d = q, .r2 = maxss(dot3(q, q), 1.0e-12) };
}

/// gw: spiky grad W of d (p_i - p_j) at r.
inline fn gw(d: V4, r: f32) V4 {
    var c = h - r;
    c = c * c;
    c = c * ks;
    c = c / maxss(r, 1.0e-12);
    return andXyz(d * splat(c));
}

/// cvtps2dq of floored values (out of range: 0x80000000).
inline fn icell(q: V4) [3]i32 {
    const f: [4]f32 = @as(V4, @floor(q * splat(ih)));
    var c: [3]i32 = undefined;
    for (0..3) |k| c[k] = if (f[k] >= -2147483648.0 and f[k] < 2147483648.0) @intFromFloat(f[k]) else std.math.minInt(i32);
    return c;
}

inline fn hashc(c: [3]i32) u32 {
    const a: u32 = @bitCast(c[0] *% 73856093);
    const b: u32 = @bitCast(c[1] *% 19349663);
    const e: u32 = @bitCast(c[2] *% 83492791);
    return (a ^ b ^ e) & mask;
}

/// clampd: inside the domain.
inline fn clampd(q: V4) V4 {
    if (!dom) return q;
    return andXyz(minps(maxps(q, dmin), dmax));
}

/// walls: the walls' sum of W at q, and their sum of grad W.
inline fn walls(q: V4) struct { s: f32, g: V4 } {
    var s0: f32 = 0;
    var g0: V4 = @splat(0);
    for (wall[0..nw]) |wl| {
        var s = dot3(q, wl) - wl[3];
        s = maxss(s, 0);
        if (s >= h) continue;
        var t = s * @as(f32, WT);
        t = t / h;
        // (NaN or past the table: none; the original reads out of it)
        if (!(t >= 0 and t < WT + 1)) continue;
        const i: usize = @intFromFloat(t);
        const fr = t - @as(f32, @floatFromInt(i));
        var a = (wd[i + 1] - wd[i]) * fr;
        a += wd[i];
        s0 += a;
        var b = (wg[i + 1] - wg[i]) * fr;
        b += wg[i];
        g0 += splat(b) * andXyz(wl);
    }
    return .{ .s = s0, .g = g0 };
}

/// lq_reset: the simulation begins again (no centres kept).
pub fn resetBodies() void {
    np = 0;
}

// ---- the solve -------------------------------------------------------------------------------

/// lq_solve: x and v (n particles) moved on by the frame's step (s), with
/// these settings, gravity x its factor (and x its factor - 1), its group's bit.
pub fn solve(count: u32, rec: *const pt.Rec, fstep: f32, a: V4, ga: V4, bit: u32) void {
    n = count;
    fdt = fstep;
    acc = andXyz(a);
    gadj = andXyz(ga);
    gbit = bit;
    const t_0 = rc.nowNs();
    tjob = 0;
    defer ms = @as(f32, @floatFromInt(@as(i64, @intCast(rc.nowNs() - t_0)))) * 0.001 * 0.001;
    if (n == 0) return;
    nfields = fields.n;
    consts(rec);
    bodies();
    var bk: u32 = 1024;
    while (bk < n *% 2) bk <<= 1;
    mask = bk - 1;
    @memset(imp[0 .. MAXCH * MAXB], @splat(0));
    var K: i32 = @bitCast(rec.lsub);
    if (K < 1) K = 1;
    if (K > 32) K = 32;
    dt = fstep / @as(f32, @floatFromInt(K));
    idt = 1.0 / dt;
    visc = dt * 60.0 * rec.visc;
    nmax = 0;
    var it: i32 = @bitCast(rec.liter);
    if (it < 1) it = 1;
    if (it > 50) it = 50;
    var k: i32 = 0;
    while (k < K) : (k += 1) {
        placeBodies(@intCast(k), @intCast(K));
        run(jPredict);
        run(jHash);
        sortCells();
        run(jNbrs);
        rmax = 0;
        var q: i32 = 0;
        while (q < it) : (q += 1) {
            run(jLambda);
            run(jDelta);
            run(jApply);
        }
        if (pt.pc_any) run(jCollide);
        run(jVel);
        run(jXsph);
        if (vort > 0) run(jVort);
        run(jCommit);
    }
    pushBodies();
    keepBodies();
}

const Job = *const fn (lo: u32, hi: u32) void;

/// lq_run: over every particle, in chunks of GRAIN.
fn run(comptime f: Job) void {
    const t_0 = rc.nowNs();
    const W = struct {
        fn job(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
            // (always chunk by chunk: the impulses are summed a chunk at a time)
            var a = lo;
            while (a < hi) {
                const b = @min(hi, (a / GRAIN + 1) * GRAIN);
                f(@intCast(a), @intCast(b));
                a = b;
            }
        }
    };
    var dummy: u8 = 0;
    jobs.parallelFor(n, GRAIN, &dummy, W.job);
    tjob += rc.nowNs() - t_0;
}

/// lq_consts: the kernel, the mass, the rest.
fn consts(r: *const pt.Rec) void {
    const d = maxss(r.size, 0.001);
    rp = d * 0.5;
    h = d + d;
    h2 = h * h;
    ih = 1.0 / h;
    var h9 = h2 * h2;
    h9 = h9 * h9;
    h9 = h9 * h;
    const pi32: f32 = 3.14159265;
    var t64: f32 = 64.0;
    t64 *= pi32;
    t64 *= h9;
    k6 = 315.0 / t64;
    var h6 = h2 * h2;
    h6 = h6 * h2;
    h6 = h6 * pi32;
    ks = -(45.0 / h6);
    rho0 = maxss(r.dens, 1.0);
    // a lattice at d: its sum of W, and of |grad W|^2
    var s6: f32 = 0;
    var s7: f32 = 0;
    var a: i32 = -2;
    while (a <= 2) : (a += 1) {
        var b: i32 = -2;
        while (b <= 2) : (b += 1) {
            var c: i32 = -2;
            while (c <= 2) : (c += 1) {
                const q = andXyz(V4{ @floatFromInt(a), @floatFromInt(b), @floatFromInt(c), 0 } * splat(d));
                const r2 = dot3(q, q);
                s6 += w6(r2);
                const rr = @sqrt(r2);
                if (!(rr > 1.0e-12)) continue;
                if (rr >= h) continue;
                const g = gw(q, rr);
                s7 += dot3(g, g);
            }
        }
    }
    m = rho0 / maxss(s6, 1.0e-12);
    mr = m / rho0;
    eps = maxss(s7 * mr * mr * 0.01, 1.0e-12);
    const q2 = h * 0.2;
    wdq = maxss(w6(q2 * q2), 1.0e-12);
    wallsMake(r);
    tk = r.tens * mr * mr / eps * 0.01;
    vort = r.vort;
    dom = r.domon & 1 != 0;
    const rv = splat(rp);
    dmin = andXyz(andXyz(V4{ r.domain[0], r.domain[1], r.domain[2], 0 }) + rv);
    dmax = andXyz(andXyz(V4{ r.domain[3], r.domain[4], r.domain[5], 0 }) - rv);
}

/// lq_walls: the walls (the domain's faces, the ground) and what a half-space
/// of the lattice beyond one adds at a distance s: rows at s + d/2, s + 3d/2
/// ... deep.
fn wallsMake(r: *const pt.Rec) void {
    for (0..WT + 2) |bi| {
        const s = @as(f32, @floatFromInt(bi)) * h / @as(f32, WT);
        var sw: f32 = 0;
        var sg: f32 = 0;
        for (0..3) |row| {
            var depth = @as(f32, @floatFromInt(row)) + 0.5;
            depth = depth * r.size;
            depth += s;
            var a: i32 = -2;
            while (a <= 2) : (a += 1) {
                var c: i32 = -2;
                while (c <= 2) : (c += 1) {
                    const x0 = @as(f32, @floatFromInt(a)) * r.size;
                    const z0 = @as(f32, @floatFromInt(c)) * r.size;
                    var y0 = depth / r.size;
                    y0 = y0 * r.size;
                    const q = andXyz(V4{ x0, y0, z0, 0 });
                    const r2 = dot3(q, q);
                    sw += w6(r2);
                    const rr = @sqrt(r2);
                    if (rr >= h) continue;
                    sg += gw(q, rr)[1];
                }
            }
        }
        wd[bi] = sw;
        wg[bi] = sg;
    }
    nw = 0;
    if (r.domon & 1 != 0) {
        for (0..3) |a| {
            var q: [4]f32 = @splat(0);
            q[a] = 1.0;
            q[3] = r.domain[a];
            wall[nw] = q;
            nw += 1;
            q = @splat(0);
            q[a] = -1.0;
            q[3] = -r.domain[3 + a];
            wall[nw] = q;
            nw += 1;
        }
    }
    if (pt.pc_gnd) {
        wall[nw] = .{ 0, 1.0, 0, pt.pc_gy };
        nw += 1;
    }
}

/// lq_bodies: the moving rigid bodies made of one box, ball or capsule:
/// where they are now (bodies made of more parts, or meshes, are left to the
/// colliders).
fn bodies() void {
    nbd = 0;
    if (!rc.on) return;
    for (rc.bd[0..rc.nb], 0..) |*b, bi| {
        if (b.typ != 1 or b.np != 1) continue;
        const prt = &rc.pt[b.p0];
        if (prt.typ != 0) continue;
        if (nbd >= MAXB) return;
        const c = nbd;
        nbd += 1;
        bobj[c] = b.obj;
        bptr[c] = @intCast(bi);
        br[c] = b.r;
        const o = prt.off;
        const cen = andXyz(V4{ dot3(o, b.r[0]), dot3(o, b.r[1]), dot3(o, b.r[2]), 0 } + b.pos);
        bc[c] = cen;
        bc1[c] = cen;
        bc0[c] = cen;
        for (0..np) |k| {
            if (pobj[k] == b.obj) {
                bc0[c] = pc[k];
                break;
            }
        }
        var hh = andXyz(prt.half);
        hh[3] = prt.rad + rp;
        bh[c] = hh;
        const grow = splat(h) + rc.abs3(bc1[c] - bc0[c]);
        bmin[c] = b.min - grow;
        bmax[c] = b.max + grow;
    }
}

/// lq_keep: the bodies' centres now, for the next frame.
fn keepBodies() void {
    np = nbd;
    for (0..nbd) |k| {
        pobj[k] = bobj[k];
        pc[k] = bc1[k];
    }
}

/// lq_place_bodies: the bodies on their way: c0 + (c1 - c0) (k + 1) / K.
fn placeBodies(k: u32, K: u32) void {
    const f = splat(@as(f32, @floatFromInt(k + 1)) / @as(f32, @floatFromInt(K)));
    for (0..nbd) |c| bc[c] = andXyz((bc1[c] - bc0[c]) * f + bc0[c]);
}

/// lq_push_bodies: each body's impulses (the chunks' in order) given to it.
fn pushBodies() void {
    const nch = (n + GRAIN - 1) / GRAIN;
    for (0..nbd) |b| {
        var s: V4 = @splat(0);
        for (0..nch) |c| s += imp[c * MAXB + b];
        s = andXyz(s);
        var len = @sqrt(dot3(s, s));
        if (!(len > 1.0e-12)) continue;
        const nrm = s / splat(len);
        const body = &rc.bd[bptr[b]];
        const vn = dot3(body.v, nrm);
        var im = body.im;
        len = len * im;
        const cap_ = @sqrt(dot3(acc, acc)) * fdt;
        if (vn + len > cap_) len = maxss(cap_ - vn, 0);
        im = maxss(im, 1.0e-12);
        len = len / im;
        _ = @import("rbody.zig").impulse(bobj[b], nrm * splat(len));
    }
}

/// lq_sort_cells: the particles by bucket (counting sort: in their order
/// within a bucket).
fn sortCells() void {
    const nbk = mask + 1;
    @memset(start[0 .. nbk + 1], 0);
    for (0..n) |i| start[cell[i] + 1] += 1;
    var s: u32 = 0;
    for (0..nbk) |b| {
        s +%= start[b + 1];
        start[b + 1] = s;
    }
    for (0..n) |i| {
        const b = cell[i];
        sort[start[b]] = @intCast(i);
        start[b] += 1;
    }
    var c = nbk;
    while (c > 0) : (c -= 1) start[c] = start[c - 1];
    start[0] = 0;
}

// ---- the jobs ------------------------------------------------------------------------------------

/// predict: v += a dt, p = x + v dt (in the domain).
fn jPredict(lo: u32, hi: u32) void {
    const d = splat(dt);
    for (lo..hi) |i| {
        var a = acc;
        if (nfields != 0) {
            const f = fields.accel(.{ x[i][0], x[i][1], x[i][2] }, .{ v[i][0], v[i][1], v[i][2] }, gbit, false);
            a = V4{ f[0], f[1], f[2], 0 } + gadj;
        }
        const vv = andXyz(a * d + v[i]);
        v[i] = vv;
        p[i] = clampd(vv * d + x[i]);
    }
}

/// hash: each particle's bucket.
fn jHash(lo: u32, hi: u32) void {
    for (lo..hi) |i| cell[i] = hashc(icell(p[i]));
}

/// nbrs: the particles within h, from the 27 cells round it (each bucket once).
fn jNbrs(lo: u32, hi: u32) void {
    var most: u32 = 0;
    for (lo..hi) |i| {
        const pi = p[i];
        const ci = icell(pi);
        const l = nb + i * NB;
        var found: u32 = 0;
        var seen: [27]u32 = undefined;
        var nseen: u32 = 0;
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                outer: while (dx <= 1) : (dx += 1) {
                    const b = hashc(.{ ci[0] +% dx, ci[1] +% dy, ci[2] +% dz });
                    for (seen[0..nseen]) |q| {
                        if (q == b) continue :outer;
                    }
                    seen[nseen] = b;
                    nseen += 1;
                    var q = start[b];
                    const e = start[b + 1];
                    while (q < e) : (q += 1) {
                        const j = sort[q];
                        if (j == i) continue;
                        const d = andXyz(pi - p[j]);
                        if (dot3(d, d) >= h2) continue;
                        if (found >= NB) continue;
                        l[found] = j;
                        found += 1;
                    }
                }
            }
        }
        nn[i] = found;
        if (found > most) most = found;
    }
    // (a statistic: races are harmless)
    if (most > nmax) nmax = most;
}

/// lambda: each particle's density and its constraint's lambda.
fn jLambda(lo: u32, hi: u32) void {
    for (lo..hi) |ii| {
        const i: u32 = @intCast(ii);
        const pi = p[i];
        var sum = w6(0);
        var gi: V4 = @splat(0);
        var g2: f32 = 0;
        const l = nb + @as(usize, i) * NB;
        for (l[0..nn[i]]) |j| {
            const d0 = andXyz(pi - p[j]);
            const ap = apart(i, j, d0, dot3(d0, d0));
            sum = w6(ap.r2) + sum;
            const g = gw(ap.d, @sqrt(ap.r2)) * splat(mr);
            gi += g;
            g2 += dot3(g, g);
        }
        const wl = walls(pi);
        sum = wl.s + sum;
        gi += wl.g * splat(mr);
        const rh = sum * m;
        rho[i] = rh;
        var c = rh / rho0;
        const cb: u32 = @bitCast(c);
        if (cb > rmax) {
            rmax = cb;
            rmaxi = i;
        }
        c = maxss(c - 1.0, 0);
        g2 += dot3(gi, gi);
        g2 += eps;
        lam[i] = -(c / g2);
    }
}

/// delta: dp_i = (m / rho0) sum (l_i + l_j + s_corr) grad W.
fn jDelta(lo: u32, hi: u32) void {
    for (lo..hi) |ii| {
        const i: u32 = @intCast(ii);
        const pi = p[i];
        const li = lam[i];
        var s: V4 = @splat(0);
        const l = nb + @as(usize, i) * NB;
        for (l[0..nn[i]]) |j| {
            var c = lam[j] + li;
            const d0 = andXyz(pi - p[j]);
            const ap = apart(i, j, d0, dot3(d0, d0));
            var q = w6(ap.r2) / wdq;
            q = q * q;
            q = q * q;
            q = q * tk;
            c = c - q;
            s += gw(ap.d, @sqrt(ap.r2)) * splat(c);
        }
        // the walls (mirrored: their lambda as its own)
        const wl = walls(pi);
        s += wl.g * splat(li + li);
        dp[i] = andXyz(s * splat(mr));
    }
}

/// apply: p += dp, in the domain; the moving bodies push it out (and get the
/// opposite impulse, summed for this chunk).
fn jApply(lo: u32, hi: u32) void {
    const row = imp + (lo / GRAIN) * MAXB;
    for (lo..hi) |i| {
        p[i] = clampd(p[i] + dp[i]);
        for (0..nbd) |b| {
            const q0 = p[i];
            const out = (q0 < bmin[b]) | (bmax[b] < q0);
            if (out[0] or out[1] or out[2]) continue;
            const d = andXyz(q0 - bc[b]);
            var loc = splat(d[0]) * br[b][0];
            loc += splat(d[1]) * br[b][1];
            loc += splat(d[2]) * br[b][2];
            loc = andXyz(loc);
            const half = bh[b];
            const rad = half[3];
            const q = andXyz(rc.abs4(loc) - half);
            var qm = maxss(q[0], q[1]);
            qm = maxss(qm, q[2]);
            var push: f32 = undefined;
            var nrm: V4 = @splat(0);
            const loca: [4]f32 = loc;
            const qa: [4]f32 = q;
            if (!(qm >= 0)) {
                // inside the core: out of its nearest face
                var ax: usize = 0;
                var mm = qa[0];
                if (qa[1] > mm) {
                    ax = 1;
                    mm = qa[1];
                }
                if (qa[2] > mm) {
                    ax = 2;
                    mm = qa[2];
                }
                push = rad - mm;
                const sb = @as(u32, @bitCast(loca[ax])) & 0x80000000;
                var na: [4]f32 = @splat(0);
                na[ax] = @bitCast(sb | @as(u32, @bitCast(@as(f32, 1.0))));
                nrm = na;
            } else {
                // outside the core: within its rounding?
                const qp = andXyz(maxps(q, @splat(0)));
                const len = @sqrt(dot3(qp, qp));
                if (len >= rad) continue;
                if (!(len > 1.0e-12)) continue;
                push = rad - len;
                const sg: @Vector(4, u32) = @as(@Vector(4, u32), @bitCast(loc)) & @Vector(4, u32){ 0x80000000, 0x80000000, 0x80000000, 0 };
                const qs: V4 = @bitCast(@as(@Vector(4, u32), @bitCast(qp)) | sg);
                nrm = andXyz(qs / splat(len));
            }
            // to the world: n_w = R n
            const r = &br[b];
            const nw_ = andXyz(V4{ dot3(nrm, r[0]), dot3(nrm, r[1]), dot3(nrm, r[2]), 0 });
            const pv = nw_ * splat(push);
            p[i] = q0 + pv;
            // the body: - m push / dt
            row[b] = row[b] - pv * splat(m * idt);
        }
    }
}

/// collide: the substep's path against the scene's colliders.
fn jCollide(lo: u32, hi: u32) void {
    for (lo..hi) |i| {
        if (pt.cast(x[i], p[i])) |hit| p[i] = andXyz(splat(rp) * hit.n + hit.p);
    }
}

/// vel: v = (p - x) / dt.
fn jVel(lo: u32, hi: u32) void {
    const k = splat(idt);
    for (lo..hi) |i| v[i] = andXyz((p[i] - x[i]) * k);
}

/// xsph: v2_i = v_i + c sum (m / rho_j) (v_j - v_i) W; the vorticity w_i =
/// sum (m / rho_j) (v_j - v_i) x grad W.
fn jXsph(lo: u32, hi: u32) void {
    for (lo..hi) |ii| {
        const i: u32 = @intCast(ii);
        const pi = p[i];
        const vi = v[i];
        var vs: V4 = @splat(0);
        var vo: V4 = @splat(0);
        const l = nb + @as(usize, i) * NB;
        for (l[0..nn[i]]) |j| {
            const mj = m / maxss(rho[j], 1.0e-12);
            const dv = v[j] - vi;
            const d = andXyz(pi - p[j]);
            const r2 = dot3(d, d);
            const wv = w6(r2) * mj;
            vs += splat(wv) * dv;
            const g = gw(d, @sqrt(r2));
            vo += cross(dv, g) * splat(mj);
        }
        // the walls: still particles there
        const wl = walls(pi);
        vs -= splat(wl.s * mr) * vi;
        vs *= splat(visc);
        v2[i] = andXyz(vs + vi);
        w[i] = andXyz(vo);
    }
}

/// vort: f = eps (N x w), N = eta / |eta|, eta = sum (m / rho_j) |w_j| grad W.
fn jVort(lo: u32, hi: u32) void {
    for (lo..hi) |ii| {
        const i: u32 = @intCast(ii);
        const pi = p[i];
        var eta: V4 = @splat(0);
        const l = nb + @as(usize, i) * NB;
        for (l[0..nn[i]]) |j| {
            var mj = m / maxss(rho[j], 1.0e-12);
            mj = mj * @sqrt(dot3(w[j], w[j]));
            const d = andXyz(pi - p[j]);
            const g = gw(d, @sqrt(dot3(d, d)));
            eta += g * splat(mj);
        }
        const e2 = dot3(eta, eta);
        if (!(e2 > 1.0e-12)) continue;
        const N = eta / splat(@sqrt(e2));
        const f = andXyz(cross(N, w[i]) * splat(vort * dt));
        v2[i] = f + v2[i];
    }
}

/// commit: x = p, v = v2.
fn jCommit(lo: u32, hi: u32) void {
    for (lo..hi) |i| {
        x[i] = p[i];
        v[i] = v2[i];
    }
}

test "the kernel's lattice is the rest density" {
    var r = pt.Rec{};
    r.size = 0.05;
    r.liq = 1;
    pt.pc_gnd = false;
    consts(&r);
    try std.testing.expect(m > 0 and h == 0.1);
    try std.testing.expect(eps > 0 and wdq > 0);
}
