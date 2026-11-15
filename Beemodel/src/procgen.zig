//! Procedural generators (procgen.s): terrain, terracing, droplet erosion,
//! L-systems (and wave function collapse, below).
//!
//! Terrain (geometry nodes): a heightfield grid from octaves of Perlin noise,
//! smooth (fBm) or ridged, mixed; terracing into flat steps with risers;
//! hydraulic erosion by droplets that pick up sediment where they speed down a
//! slope and drop it where they slow (heights in cell units, bilinear
//! gradients, a bounded number of steps each).
//!
//! L-systems: an axiom rewritten by rules, then read by a 3D turtle (F draw, f
//! move, + - yaw, & ^ pitch, \ / roll, | turn round, [ ] a branch, ! thinner)
//! into chains of points with a radius each: lines, or with a radius tubes
//! that thin with every branch (curve.zig sweeps them).
//!
//! Every step is the original's single-precision arithmetic in its order, so
//! the meshes are the original's to the bit (perlin: shgraph.zig, graph.s).
//! Meshes are fmesh.M (positions, polygons, bounds over every position).
const std = @import("std");
const m = @import("math.zig");
const fmesh = @import("fmesh.zig");
const jobs = @import("jobs.zig");
const shgraph = @import("shgraph.zig");

pub const M = fmesh.M;
pub const V3 = m.V3;
const Allocator = std.mem.Allocator;

const TINY: f32 = 1.0e-6;

// ---- the original's conversions and SSE min / max ------------------------------------

/// cvttss2si: out of range or NaN gives 0x80000000.
pub fn cvtt(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}

/// cvtss2si (round to nearest, ties to even).
pub fn cvt(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return std.math.minInt(i32);
    var t = @floor(x);
    const d = x - t;
    if (d > 0.5 or (d == 0.5 and @mod(t, 2.0) != 0)) t += 1;
    if (!(t < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(t);
}

/// minss / maxss: the second operand when either is NaN.
pub inline fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
pub inline fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

/// cvtsi2ss of an i32.
inline fn fi(x: anytype) f32 {
    return @floatFromInt(x);
}

// ---- random numbers -------------------------------------------------------------------

/// pg_rand: xorshift, 32 bits.
pub fn rand(s: *u32) u32 {
    var x = s.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    s.* = x;
    return x;
}

/// pg_randf: in 0..1.
pub fn randf(s: *u32) f32 {
    const r: f32 = @floatFromInt(rand(s));
    return r * 2.3283064e-10;
}

// ---- terrain -------------------------------------------------------------------------

/// The Terrain node's settings: Size, Resolution, Height, Seed (its
/// parameters) and Noise = scale, detail (octaves), ridged (its inputs).
pub const Terrain = struct {
    size: f32 = 2,
    res: f32 = 64,
    height: f32 = 0.5,
    seed: f32 = 0,
    scale: f32 = 3,
    detail: f32 = 4,
    ridged: f32 = 0,
};

/// prim_grid_n: n x n quads, facing up, 2 x 2 on the XZ plane (row r along
/// Z, column c along X).
pub fn grid(a: Allocator, n: u32) !M {
    const nv = (n + 1) * (n + 1);
    const verts = try a.alloc(V3, nv);
    errdefer a.free(verts);
    const poff = try a.alloc(u32, n * n + 1);
    errdefer a.free(poff);
    const loops = try a.alloc(u32, n * n * 4);
    const fnn = fi(n);
    var k: usize = 0;
    for (0..n + 1) |r| {
        for (0..n + 1) |c| {
            const fc = fi(c);
            const fr = fi(r);
            verts[k] = .{ (fc + fc) / fnn - 1, 0, (fr + fr) / fnn - 1 };
            k += 1;
        }
    }
    poff[0] = 0;
    var p: usize = 0;
    for (0..n) |r| {
        for (0..n) |c| {
            const i: u32 = @intCast(r * (n + 1) + c);
            loops[p * 4 ..][0..4].* = .{ i, i + n + 1, i + n + 2, i + 1 };
            p += 1;
            poff[p] = @intCast(p * 4);
        }
    }
    return fmesh.finish(verts, poff, loops);
}

const TerrainJob = struct {
    verts: []V3,
    n: u32,
    oct: u32,
    scale: f32,
    ridge: f32,
    seed: f32,
    height: f32,
};

fn terrainRows(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *const TerrainJob = @ptrCast(@alignCast(ctx));
    const fnn = fi(j.n);
    for (lo..hi) |r| {
        for (0..j.n + 1) |c| {
            var x = fi(c) / fnn;
            var z = fi(r) / fnn;
            x *= j.scale;
            z *= j.scale;
            const b = [3]f32{ x + j.seed * 13.37, j.seed * 3.1 + 0.5, z + j.seed * 7.77 };
            var amp: f32 = 1;
            var freq: f32 = 1;
            var fbm: f32 = 0;
            var rid: f32 = 0;
            var tot: f32 = 0;
            for (0..j.oct) |_| {
                const nz = shgraph.perlin(.{ b[0] * freq, b[1] * freq, b[2] * freq });
                fbm = nz * amp + fbm;
                const q = 1.0 - @abs(nz);
                rid = (q * q) * amp + rid;
                tot = amp + tot;
                amp = amp * 0.5;
                freq = freq * 2.0;
            }
            const f = fbm / tot * 0.5 + 0.5;
            const g = rid / tot;
            const t = f + (g - f) * j.ridge;
            j.verts[r * (j.n + 1) + c][1] = t * j.height;
        }
    }
}

/// tg_terrain: a new grid of the noise's heights (Resolution 1..2048 a side).
pub fn terrain(a: Allocator, t: Terrain) !M {
    const n: u32 = @intCast(std.math.clamp(cvtt(t.res), 1, 2048));
    var g = try grid(a, n);
    var j = TerrainJob{
        .verts = g.verts,
        .n = n,
        .oct = @intCast(std.math.clamp(cvtt(t.detail), 1, 10)),
        .scale = t.scale,
        .ridge = minss(maxss(t.ridged, 0), 1),
        .seed = fi(cvtt(t.seed)),
        .height = t.height,
    };
    jobs.parallelFor(n + 1, 4, @ptrCast(&j), terrainRows);
    const h = t.size * 0.5;
    for (g.verts) |*v| {
        v[0] = v[0] * h;
        v[2] = v[2] * h;
    }
    const bb = fmesh.bbox(g.verts);
    g.bmin = bb[0];
    g.bmax = bb[1];
    return g;
}

/// tg_terrain as geonodes.s calls it: `p` the node's parameters (Size,
/// Resolution, Height, Seed), `in` its inputs' values (in[1..4]: scale,
/// detail, ridged).
pub fn terrainNode(a: Allocator, p: []const f32, in: []const f32) !M {
    return terrain(a, .{ .size = p[0], .res = p[1], .height = p[2], .seed = p[3], .scale = in[1], .detail = in[2], .ridged = in[3] });
}

/// tg_terrace: Steps, Smooth: heights (Y, over the mesh's range) into flat
/// steps; a riser takes the last Smooth of a step. A copy.
pub fn terrace(a: Allocator, src: *const M, steps_p: f32, smooth_p: f32) !M {
    var r = try src.clone(a);
    const steps = fi(@max(cvtt(steps_p), 1));
    const s = minss(maxss(smooth_p, TINY), 1);
    const lo = r.bmin[1];
    const range = maxss(r.bmax[1] - lo, TINY);
    for (r.verts) |*v| {
        var t = (v[1] - lo) / range * steps;
        const k = @floor(t);
        t = t - k;
        t = (t - (1.0 - s)) / s;
        t = minss(maxss(t, 0), 1);
        const ss = (t * t) * (3.0 - 2.0 * t);
        v[1] = (k + ss) / steps * range + lo;
    }
    const bb = fmesh.bbox(r.verts);
    r.bmin = bb[0];
    r.bmax = bb[1];
    return r;
}

// ---- hydraulic erosion -----------------------------------------------------------------

const ER_LIFE = 40;
const ER_INERTIA: f32 = 0.05;
const ER_CAPACITY: f32 = 4.0;
const ER_MINCAP: f32 = 0.01;
const ER_DEPOSIT: f32 = 0.3;
const ER_EVAP: f32 = 0.02;
const ER_GRAVITY: f32 = 4.0;
const er_w = [25]f32{ 0.000000, 0.015567, 0.029491, 0.015567, 0.000000, 0.015567, 0.064041, 0.088472, 0.064041, 0.015567, 0.029491, 0.088472, 0.147453, 0.088472, 0.029491, 0.015567, 0.064041, 0.088472, 0.064041, 0.015567, 0.000000, 0.015567, 0.029491, 0.015567, 0.000000 };

/// What er_run works on (er_h, er_n, er_rng): heights 0..1 over their range,
/// n a row, and the random state.
pub const Eroder = struct {
    h: []f32,
    n: u32,
    rng: u32,

    /// The random state from a seed (cvttss2si x 0x9E3779B1, odd).
    pub fn seedOf(seed: f32) u32 {
        return (@as(u32, @bitCast(cvtt(seed))) *% 0x9E3779B1) | 1;
    }

    const At = struct { h: f32, dx: f32, dz: f32, cell: u32 };

    /// er_at: bilinear height and gradient at (x, z) in cells.
    fn at(e: *const Eroder, x: f32, z: f32) At {
        const ix = cvtt(x);
        const iz = cvtt(z);
        const u = x - fi(ix);
        const v = z - fi(iz);
        const n = e.n;
        const i: u32 = @bitCast(iz *% @as(i32, @bitCast(n)) +% ix);
        const h00 = e.h[i];
        const h10 = e.h[i + 1];
        const h01 = e.h[i + n];
        const h11 = e.h[i + n + 1];
        const dx = (h10 - h00) * (1.0 - v) + (h11 - h01) * v;
        const dz = (h01 - h00) * (1.0 - u) + (h11 - h10) * u;
        const a0 = h00 * (1.0 - u) + h10 * u;
        const a1 = h01 * (1.0 - u) + h11 * u;
        return .{ .h = a0 * (1.0 - v) + a1 * v, .dx = dx, .dz = dz, .cell = i };
    }

    /// er_brush: `amount` taken away around the nearest vertex, radius 2.5.
    fn brush(e: *Eroder, amount: f32, x: f32, z: f32) void {
        const ax = cvt(x);
        const cz = cvt(z);
        var dz: i32 = -2;
        while (dz <= 2) : (dz += 1) {
            var dx: i32 = -2;
            while (dx <= 2) : (dx += 1) {
                const si: u32 = @bitCast(ax +% dx);
                const di: u32 = @bitCast(cz +% dz);
                if (si >= e.n or di >= e.n) continue;
                const k = di * e.n + si;
                const w = er_w[@intCast((dz + 2) * 5 + dx + 2)] * amount;
                const old = e.h[k];
                e.h[k] = minss(maxss(old - w, 0), old);
            }
        }
    }

    /// er_put: added to the cell's four corners by their bilinear weights.
    fn put(e: *Eroder, amount: f32, i: u32, u: f32, v: f32) void {
        const n = e.n;
        const iu = 1.0 - u;
        const iv = 1.0 - v;
        e.h[i] = amount * iu * iv + e.h[i];
        e.h[i + 1] = amount * u * iv + e.h[i + 1];
        e.h[i + n] = amount * iu * v + e.h[i + n];
        e.h[i + n + 1] = amount * u * v + e.h[i + n + 1];
    }

    /// er_run: `droplets` droplets, each starting anywhere inside and living
    /// up to ER_LIFE steps; `rate` the erosion rate.
    pub fn run(e: *Eroder, rate: f32, droplets: u32) void {
        if (e.n < 2) return;
        const far = fi(e.n - 1);
        var left = droplets;
        drop: while (left > 0) {
            left -= 1;
            var x = randf(&e.rng) * far;
            var z = randf(&e.rng) * far;
            var dirx: f32 = 0;
            var dirz: f32 = 0;
            var sed: f32 = 0;
            var speed: f32 = 1;
            var water: f32 = 1;
            var step: u32 = 0;
            while (step < ER_LIFE) : (step += 1) {
                const p = e.at(x, z);
                const u = x - @floor(x);
                const v = z - @floor(z);
                const gx = p.dx * (1.0 - ER_INERTIA);
                const gz = p.dz * (1.0 - ER_INERTIA);
                var ndx = dirx * ER_INERTIA - gx;
                var ndz = dirz * ER_INERTIA - gz;
                const len = @sqrt(ndx * ndx + ndz * ndz);
                if (!(len > TINY)) continue :drop;
                ndx /= len;
                ndz /= len;
                dirx = ndx;
                dirz = ndz;
                const nx = x + ndx;
                const nz = z + ndz;
                if (!(nx >= 0) or !(nz >= 0)) continue :drop;
                if (nx >= far or nz >= far) continue :drop;
                x = nx;
                z = nz;
                const dh = e.at(x, z).h - p.h;
                const cap = maxss((0 - dh) * speed * water * ER_CAPACITY, ER_MINCAP);
                if (dh > 0) {
                    const d = minss(dh, sed);
                    sed = sed - d;
                    e.put(d, p.cell, u, v);
                } else if (sed > cap) {
                    const d = (sed - cap) * ER_DEPOSIT;
                    sed = sed - d;
                    e.put(d, p.cell, u, v);
                } else {
                    const amt = minss((cap - sed) * rate, 0 - dh);
                    sed = sed + amt;
                    e.brush(amt, x - dirx, z - dirz);
                }
                speed = @sqrt(maxss(speed * speed - dh * ER_GRAVITY, 0));
                water = (1.0 - ER_EVAP) * water;
            }
        }
    }
};

/// tg_erode: Droplets, Strength, Seed on a grid mesh (row-major n x n
/// vertices on the XZ plane, as the terrain and grid nodes make): an eroded
/// copy (not a grid: an unchanged copy).
pub fn erode(a: Allocator, src: *const M, droplets_p: f32, rate_p: f32, seed: f32) !M {
    var r = try src.clone(a);
    errdefer r.deinit(a);
    const nv: u32 = @intCast(r.verts.len);
    const sq: f64 = @sqrt(@as(f64, @floatFromInt(nv)));
    const n: u32 = @intFromFloat(@round(sq)); // (cvtsd2si: sqrt of a u32 is never a tie)
    if (n * n != nv or n < 3) return r;
    const sp = r.verts[1][0] - r.verts[0][0];
    if (!(sp > TINY)) return r;
    if (@abs(r.verts[n][2] - r.verts[0][2] - sp) > TINY) return r; // (NaN goes on, as ja)
    const range = r.bmax[1] - r.bmin[1];
    if (!(range > TINY)) return r;
    const h = try a.alloc(f32, nv);
    defer a.free(h);
    for (r.verts, h) |v, *o| o.* = (v[1] - r.bmin[1]) / range;
    var e = Eroder{ .h = h, .n = n, .rng = Eroder.seedOf(seed) };
    const rate = minss(maxss(rate_p, 0), 1);
    const d = cvtt(droplets_p);
    if (d > 0) e.run(rate, @intCast(@min(d, 2000000)));
    for (r.verts, h) |*v, x| v[1] = x * range + r.bmin[1];
    const bb = fmesh.bbox(r.verts);
    r.bmin = bb[0];
    r.bmax = bb[1];
    return r;
}

/// tg_erode as geonodes.s calls it (p: Droplets, Strength, Seed).
pub fn erodeNode(a: Allocator, src: *const M, p: []const f32) !M {
    return erode(a, src, p[0], p[1], p[2]);
}

/// tg_terrace as geonodes.s calls it (p: Steps, Smooth).
pub fn terraceNode(a: Allocator, src: *const M, p: []const f32) !M {
    return terrace(a, src, p[0], p[1]);
}

// ---- L-systems -------------------------------------------------------------------------

/// Characters after rewriting, at most.
pub const LS_CAP: u32 = 8000000;
/// Branches open at once.
const LS_DEPTH = 256;
const LS_THIN: f32 = 0.7;

/// A chain point as curve.s keeps one (EP_SZ 20): place, radius, tilt.
pub const EP = extern struct { p: [3]f32, r: f32, tilt: f32 = 0 };
/// A chain (CH_SZ 12): its first point, how many, cyclic.
pub const CH = extern struct { first: u32, count: u32 = 0, cyclic: u32 = 0 };

/// The turtle's chains (curve.s ch_ep, ch_tab, ch_n, ch_total).
pub const Chains = struct {
    ep: []EP,
    tab: []CH,
    n: u32 = 0,
    total: u32 = 0,

    pub fn points(c: *const Chains) []const EP {
        return c.ep[0..c.total];
    }
    pub fn chains(c: *const Chains) []const CH {
        return c.tab[0..c.n];
    }
    pub fn deinit(c: *Chains, a: Allocator) void {
        a.free(c.ep);
        a.free(c.tab);
    }
};

/// ls_rules: the replacement table of "a=xyz; b=..".
const Rules = struct {
    rule: [256][]const u8 = undefined,
    has: [256]bool = @splat(false),

    fn parse(text: []const u8) Rules {
        var r = Rules{};
        var i: usize = 0;
        while (i < text.len and text[i] != 0) {
            const c = text[i];
            if (c == ' ' or c == ';' or c == ',' or c == '\n' or i + 1 >= text.len or text[i + 1] != '=') {
                i += 1;
                continue;
            }
            const s = i + 2;
            var e = s;
            while (e < text.len and text[e] != 0 and text[e] != ';' and text[e] != ',' and text[e] != '\n') e += 1;
            r.rule[c] = text[s..e];
            r.has[c] = true;
            i = e;
        }
        return r;
    }
};

/// ls_rewrite: the axiom rewritten `iters` times; stops before outgrowing
/// LS_CAP (the last string stays). Owned by the caller.
pub fn rewrite(a: Allocator, axiom: []const u8, rules_text: []const u8, iters: u32) ![]u8 {
    const r = Rules.parse(rules_text);
    var len: usize = 0;
    while (len < axiom.len and axiom[len] != 0 and len < LS_CAP) len += 1;
    var cur = try a.dupe(u8, axiom[0..len]);
    errdefer a.free(cur);
    var it = iters;
    while (it > 0) : (it -= 1) {
        var nl: u64 = 0;
        for (cur) |c| nl += if (r.has[c]) r.rule[c].len else 1;
        if (nl > LS_CAP) break;
        const nx = try a.alloc(u8, @intCast(nl));
        var k: usize = 0;
        for (cur) |c| {
            if (r.has[c]) {
                @memcpy(nx[k..][0..r.rule[c].len], r.rule[c]);
                k += r.rule[c].len;
            } else {
                nx[k] = c;
                k += 1;
            }
        }
        a.free(cur);
        cur = nx;
    }
    return cur;
}

/// The turtle (LT_SZ 80): place, heading H, left L, up U (4 lanes each, as
/// the original keeps them), radius.
const Turtle = struct {
    pos: [4]f32 = .{ 0, 0, 0, 0 },
    hd: [4]f32 = .{ 0, 1, 0, 0 },
    lf: [4]f32 = .{ -1, 0, 0, 0 },
    up: [4]f32 = .{ 0, 0, 1, 0 },
    radius: f32 = 0,
};

/// ls_turn: axes a, b turned in their plane: a' = a cos + b sin,
/// b' = b cos - a sin.
fn turn(a: *[4]f32, b: *[4]f32, s: f32, c: f32) void {
    for (0..4) |i| {
        const x = a[i];
        const y = b[i];
        a[i] = x * c + y * s;
        b[i] = y * c - x * s;
    }
}

/// sincos (x87 fsincos of a single, rounded to single).
pub fn sincos(x: f32) [2]f32 {
    const d: f64 = x;
    return .{ @floatCast(@sin(d)), @floatCast(@cos(d)) };
}

/// The turtle's reading of a rewritten string (ls_build up to the mesh): the
/// chains of points, a radius each.
pub fn turtle(a: Allocator, s: []const u8, angle_deg: f32, step: f32, radius: f32) !Chains {
    var nf: u32 = 0;
    for (s) |c| {
        if (c == 'F' or c == 'G') nf += 1;
    }
    const cap = nf * 2 + 16;
    const tcap = nf + 16;
    var ch = Chains{ .ep = try a.alloc(EP, cap), .tab = undefined };
    errdefer a.free(ch.ep);
    ch.tab = try a.alloc(CH, tcap);
    const stack = try a.alloc(Turtle, LS_DEPTH);
    defer a.free(stack);
    var sp: u32 = 0;
    var open = false;
    var t = Turtle{ .radius = radius };
    const sc = sincos(angle_deg * 0.017453292);
    const sn = sc[0];
    const cs = sc[1];
    const P = struct {
        fn point(c: *Chains, tt: *const Turtle, capn: u32) void {
            if (c.total >= capn) return;
            c.ep[c.total] = .{ .p = .{ tt.pos[0], tt.pos[1], tt.pos[2] }, .r = tt.radius };
            c.total += 1;
            c.tab[c.n - 1].count += 1;
        }
        fn fwd(tt: *Turtle, st: f32) void {
            for (0..4) |i| tt.pos[i] = st * tt.hd[i] + tt.pos[i];
        }
    };
    for (s) |c| {
        switch (c) {
            'F', 'G' => {
                if (!open) {
                    if (ch.n >= tcap) break;
                    ch.tab[ch.n] = .{ .first = ch.total };
                    ch.n += 1;
                    P.point(&ch, &t, cap);
                    open = true;
                }
                P.fwd(&t, step);
                P.point(&ch, &t, cap);
            },
            'f' => {
                P.fwd(&t, step);
                open = false;
            },
            '+' => turn(&t.hd, &t.lf, sn, cs),
            '-' => turn(&t.hd, &t.lf, -sn, cs),
            '&' => turn(&t.hd, &t.up, sn, cs),
            '^' => turn(&t.hd, &t.up, -sn, cs),
            '\\' => turn(&t.lf, &t.up, sn, cs),
            '/' => turn(&t.lf, &t.up, -sn, cs),
            '|' => {
                for (0..3) |i| {
                    t.hd[i] = -t.hd[i];
                    t.lf[i] = -t.lf[i];
                }
            },
            '[' => {
                open = false;
                if (sp < LS_DEPTH) {
                    stack[sp] = t;
                    sp += 1;
                    t.radius = t.radius * LS_THIN;
                }
            },
            ']' => {
                open = false;
                if (sp > 0) {
                    sp -= 1;
                    t = stack[sp];
                }
            },
            '!' => t.radius = t.radius * LS_THIN,
            else => {},
        }
    }
    return ch;
}

/// The chains of ls_build, from the axiom and rules: `iters` clamped 0..16.
pub fn lsChains(a: Allocator, axiom: []const u8, rules: []const u8, iters: i32, angle_deg: f32, step: f32, radius: f32) !Chains {
    const s = try rewrite(a, axiom, rules, @intCast(std.math.clamp(iters, 0, 16)));
    defer a.free(s);
    return turtle(a, s, angle_deg, step, radius);
}

/// Whether ls_build sweeps tubes (a radius above 0; NaN too, as the
/// original's comiss) or makes lines.
pub fn lsTubes(radius: f32) bool {
    return !(0 >= radius);
}

/// The presets (ls_presets): axiom, rules, angle.
pub const Preset = struct { axiom: []const u8, rules: []const u8, angle: f32 };
pub const presets = [4]Preset{
    .{ .axiom = "X", .rules = "X=F+[[X]-X]-F[-FX]+X; F=FF", .angle = 25 },
    .{ .axiom = "A", .rules = "A=[&FA]/////[&FA]///////[&FA]; F=S/////F; S=F", .angle = 22.5 },
    .{ .axiom = "F", .rules = "F=FF-[-F+F+F]+[+F-F-F]", .angle = 22.5 },
    .{ .axiom = "F-F-F-F", .rules = "F=F-F+F+FF-F-F+F", .angle = 90 },
};

/// tg_lsystem's settings from the node's parameters: Preset (plant, bush,
/// tree, Koch island), Iterations, Radius (0: lines), Step.
pub const LsNode = struct { preset: *const Preset, iters: i32, radius: f32, step: f32 };
pub fn lsNode(p: []const f32) LsNode {
    var k: u32 = @bitCast(cvtt(p[0]));
    if (k > 3) k = 0;
    return .{ .preset = &presets[k], .iters = cvtt(p[1]), .radius = p[2], .step = p[3] };
}

/// tg_lsystem up to the chains (the caller sweeps them: curve.zig ch_sweep
/// with prof_circle(6, 1) when lsTubes(radius), else ch_to_lines).
pub fn lsystemChains(a: Allocator, p: []const f32) !Chains {
    const q = lsNode(p);
    return lsChains(a, q.preset.axiom, q.preset.rules, q.iters, q.preset.angle, q.step, q.radius);
}

// ---- tests ----------------------------------------------------------------------------

test "xorshift and randf as pg_rand" {
    var s: u32 = 1;
    try std.testing.expectEqual(@as(u32, 270369), rand(&s));
    var t: u32 = 0xffffffff;
    const f = randf(&t);
    try std.testing.expect(f >= 0 and f <= 1.0);
}

test "cvt rounds ties to even, cvtt truncates" {
    try std.testing.expectEqual(@as(i32, 2), cvt(2.5));
    try std.testing.expectEqual(@as(i32, 4), cvt(3.5));
    try std.testing.expectEqual(@as(i32, -2), cvt(-2.5));
    try std.testing.expectEqual(@as(i32, 3), cvt(2.6));
    try std.testing.expectEqual(@as(i32, -2), cvtt(-2.9));
    try std.testing.expectEqual(std.math.minInt(i32), cvtt(std.math.nan(f32)));
}

test "grid as prim_grid_n" {
    const a = std.testing.allocator;
    var g = try grid(a, 4);
    defer g.deinit(a);
    try std.testing.expectEqual(@as(usize, 25), g.verts.len);
    try std.testing.expectEqual(@as(usize, 16), g.faces());
    try std.testing.expectEqualSlices(u32, &.{ 0, 5, 6, 1 }, g.poly(0));
    try std.testing.expectEqual(@as(f32, -0.5), g.verts[6][0]);
}

test "terrain: heights in 0..height, deterministic, sized" {
    const a = std.testing.allocator;
    var t = try terrain(a, .{ .size = 40, .res = 32, .height = 7, .seed = 3, .scale = 1.6, .detail = 6, .ridged = 0.6 });
    defer t.deinit(a);
    var u = try terrain(a, .{ .size = 40, .res = 32, .height = 7, .seed = 3, .scale = 1.6, .detail = 6, .ridged = 0.6 });
    defer u.deinit(a);
    try std.testing.expectEqual(@as(usize, 33 * 33), t.verts.len);
    for (t.verts, u.verts) |p, q| try std.testing.expectEqual(p, q);
    try std.testing.expectEqual(@as(f32, -20), t.bmin[0]);
    try std.testing.expectEqual(@as(f32, 20), t.bmax[2]);
    try std.testing.expect(t.bmin[1] >= 0 and t.bmax[1] <= 7 and t.bmax[1] > t.bmin[1]);
}

test "terrace: steps flat, monotone" {
    const a = std.testing.allocator;
    var t = try terrain(a, .{ .res = 16, .height = 1 });
    defer t.deinit(a);
    var s = try terrace(a, &t, 4, 0.0);
    defer s.deinit(a);
    // tiny smooth: every height lands on one of 5 levels
    var levels: [8]f32 = undefined;
    var nl: usize = 0;
    for (s.verts) |v| {
        const seen = for (levels[0..nl]) |l| {
            if (@abs(l - v[1]) < 1e-4) break true;
        } else false;
        if (!seen) {
            if (nl == levels.len) return error.TestUnexpectedResult;
            levels[nl] = v[1];
            nl += 1;
        }
    }
    try std.testing.expect(nl <= 5);
}

test "erode: moves material, keeps it a grid, not below zero" {
    const a = std.testing.allocator;
    var t = try terrain(a, .{ .size = 10, .res = 40, .height = 3, .seed = 1 });
    defer t.deinit(a);
    var e = try erode(a, &t, 5000, 0.3, 3);
    defer e.deinit(a);
    var moved: usize = 0;
    for (t.verts, e.verts) |p, q| {
        try std.testing.expectEqual(p[0], q[0]);
        try std.testing.expectEqual(p[2], q[2]);
        if (p[1] != q[1]) moved += 1;
    }
    try std.testing.expect(moved > 100);
    // not a grid: an unchanged copy
    var c = try terrace(a, &t, 3, 0.5);
    defer c.deinit(a);
    c.verts[1][0] = c.verts[0][0];
    var d = try erode(a, &c, 5000, 0.3, 3);
    defer d.deinit(a);
    for (c.verts, d.verts) |p, q| try std.testing.expectEqual(p, q);
}

test "rewrite: rules, unknown characters kept, cap" {
    const a = std.testing.allocator;
    const s = try rewrite(a, "F-F", "F=F+F; X=", 2);
    defer a.free(s);
    try std.testing.expectEqualStrings("F+F+F+F-F+F+F+F", s);
    const k = try rewrite(a, "X", "X=XX", 30);
    defer a.free(k);
    try std.testing.expect(k.len <= LS_CAP and k.len * 2 > LS_CAP);
}

test "turtle: Koch island closes, branches thin" {
    const a = std.testing.allocator;
    var c = try lsChains(a, "F-F-F-F", "", 0, 90, 1, 0);
    defer c.deinit(a);
    try std.testing.expectEqual(@as(u32, 1), c.n);
    try std.testing.expectEqual(@as(u32, 5), c.total);
    const last = c.ep[4].p;
    try std.testing.expect(@abs(last[0]) < 1e-5 and @abs(last[1]) < 1e-5);
    var b = try lsChains(a, "F[F]F", "", 0, 25, 1, 1);
    defer b.deinit(a);
    try std.testing.expectEqual(@as(u32, 3), b.n);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), b.ep[b.tab[1].first].r, 1e-6);
    try std.testing.expectEqual(@as(f32, 1), b.ep[b.tab[2].first].r);
}

test "lsNode: presets, out of range is the plant" {
    const q = lsNode(&.{ 7, 3, 0.03, 0.12 });
    try std.testing.expectEqualStrings("X", q.preset.axiom);
    const r = lsNode(&.{ 3, 2, 0, 1 });
    try std.testing.expectEqual(@as(f32, 90), r.preset.angle);
}

// ---- the L-system's mesh (curve.zig sweeps the chains) ---------------------------------

const curve = @import("curve.zig");
const PMesh = @import("pmesh.zig").PMesh;

/// The chains into curve.zig's (ch_ep, ch_tab), then ls_build's mesh: lines,
/// or tubes (a hexagon scaled by the radius) with a radius. Null: no memory.
pub fn chainsMesh(a: Allocator, c: *const Chains, radius: f32) ?PMesh {
    if (!curve.chReserve(c.total, c.n)) return null;
    for (c.points(), 0..) |p, i| curve.ch_ep[i] = .{ .p = p.p, .rad = p.r, .tilt = p.tilt };
    for (c.chains(), 0..) |h, i| curve.ch_tab[i] = .{ .first = h.first, .n = h.count, .cyc = h.cyclic };
    curve.ch_total = c.total;
    curve.ch_n = c.n;
    if (!lsTubes(radius)) return curve.chToLines(a);
    const prof = curve.profCircle(6, 1.0) orelse return null;
    defer curve.A.free(prof);
    return curve.chSweep(a, prof, 1, 0);
}

/// ls_build: the axiom rewritten by the rules, read by the turtle, made a
/// mesh (`iters` clamped 0..16).
pub fn lsBuild(a: Allocator, axiom: []const u8, rules: []const u8, iters: i32, angle_deg: f32, step: f32, radius: f32) ?PMesh {
    var c = lsChains(a, axiom, rules, iters, angle_deg, step, radius) catch return null;
    defer c.deinit(a);
    return chainsMesh(a, &c, radius);
}

/// tg_lsystem as geonodes.s calls it: `p` the node's parameters (Preset,
/// Iterations, Radius, Step).
pub fn lsystemNode(a: Allocator, p: []const f32) ?PMesh {
    const q = lsNode(p);
    return lsBuild(a, q.preset.axiom, q.preset.rules, q.iters, q.preset.angle, q.step, q.radius);
}

// ---- tests' window into it -------------------------------------------------------------

/// --dump-procgen "SPEC;OUT": a chain of nodes run in order, each on the last
/// one's mesh - "terrain size res height seed scale detail ridged", "erode
/// droplets strength seed", "terrace steps smooth", "lsystem preset iterations
/// radius step" - split by '|'; written to OUT: u32 vertices, polygons, the
/// vertices as f32 x y z, then each polygon as u32 count, indices.
pub fn dumpSpec(arg: []const u8) void {
    const a = std.heap.page_allocator;
    const semi = std.mem.lastIndexOfScalar(u8, arg, ';') orelse return;
    var cur: ?M = null;
    defer if (cur) |*c| c.deinit(a);
    var parts = std.mem.splitScalar(u8, arg[0..semi], '|');
    while (parts.next()) |part| {
        var w = std.mem.tokenizeScalar(u8, part, ' ');
        const kind = w.next() orelse continue;
        var v: [8]f32 = @splat(0);
        var k: usize = 0;
        while (w.next()) |x| : (k += 1) {
            if (k < v.len) v[k] = std.fmt.parseFloat(f32, x) catch 0;
        }
        const next: ?M = if (std.mem.eql(u8, kind, "terrain"))
            terrain(a, .{ .size = v[0], .res = v[1], .height = v[2], .seed = v[3], .scale = v[4], .detail = v[5], .ridged = v[6] }) catch null
        else if (std.mem.eql(u8, kind, "erode") and cur != null)
            erode(a, &cur.?, v[0], v[1], v[2]) catch null
        else if (std.mem.eql(u8, kind, "terrace") and cur != null)
            terrace(a, &cur.?, v[0], v[1]) catch null
        else if (std.mem.eql(u8, kind, "lsystem")) blk: {
            const p = lsystemNode(a, &v) orelse break :blk null;
            break :blk fmesh.fromP(p);
        } else null;
        if (cur) |*c| c.deinit(a);
        cur = next;
    }
    const r = cur orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const hdr = [2]u32{ @intCast(r.verts.len), @intCast(r.faces()) };
    out.appendSlice(a, std.mem.sliceAsBytes(&hdr)) catch return;
    out.appendSlice(a, std.mem.sliceAsBytes(r.verts)) catch return;
    for (0..r.faces()) |f| {
        const p = r.poly(f);
        out.appendSlice(a, std.mem.asBytes(&@as(u32, @intCast(p.len)))) catch return;
        out.appendSlice(a, std.mem.sliceAsBytes(p)) catch return;
    }
    @import("atomicfile.zig").write(arg[semi + 1 ..], out.items) catch {};
}
