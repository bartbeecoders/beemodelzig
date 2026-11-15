//! Sketch profiles and the solids made from them (prof.s), step for step.
//!
//! build finds the closed loops of a sketch: lines and arcs chained end to
//! end (ends that coincide are welded), and whole circles. Loops inside loops
//! alternate between material and holes (even-odd); material loops turn
//! counter-clockwise, holes clockwise. Caps are triangulated by ear clipping
//! after bridging each hole into its outline (Eberly).
//!
//! prism extrudes every region between two heights along the sketch normal,
//! revolve sweeps the loops around a sketch axis, offset moves every loop
//! sideways (shells), points makes a circle at every loose point (holes).
//! Meshes come out closed and facing outwards (a signed-volume check flips
//! them when a mirroring transform turned them inside out). Plane coordinates
//! are doubles, the x87's sines and arctangents as the original's.
//!
//! The state is global as in the original (pf_*): build (or points), then
//! offset, then prism / revolve read it.
//!
//! Deliberate differences, all on damaged sketches where the original reads
//! outside its tables: an entity whose point indices are out of range is
//! left out, and an element with no points is not walked. A revolve of more
//! than 16M vertices (an angle of thousands of radians) fails at once.
const std = @import("std");
const m = @import("math.zig");
const sk = @import("sketch.zig");
const fm = @import("fmesh.zig");
/// The loops and their triangulation (prof.s's pf_* state, nest, merge,
/// earclip): one implementation, shared with the B-rep tessellation.
pub const T = @import("proftri.zig");

const V3 = m.V3;
const Allocator = std.mem.Allocator;

pub const MAXP = T.MAXP; // loop points
pub const MAXL = T.MAXL; // loops
const MAXEL = 256; // chained elements
const MAXEP = 8192; // their points
const CSEG = 64; // segments in a full circle
pub const MAXTRI = T.MAXTRI;

const TWO_PI: f64 = 6.28318530717958647692;
const WELD: f64 = 1.0e-7;
const EPS: f64 = 1.0e-12;
const BIG: f64 = 1.0e300;


var el_n: u32 = 0;
var el_a: [MAXEL]u32 = undefined;
var el_b: [MAXEL]u32 = undefined;
var el_s: [MAXEL]u32 = undefined;
var el_c: [MAXEL]u32 = undefined;
var el_used: [MAXL + MAXEL]u8 = undefined;
var el_np: u32 = 0;
var el_pt: [MAXEP][2]f64 = undefined;
var clus: [256]u32 = undefined;


/// maxsd: the second operand when either is NaN.
fn maxsd(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}
/// cvttsd2si: the indefinite integer when it does not fit.
fn cvtt(x: f64) i32 {
    if (!(x > -2147483649.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}
fn fi(x: anytype) f64 {
    return @floatFromInt(x);
}

fn skp(b: *const sk.Block, p: u32) [2]f64 {
    return .{ b.pts[p].x, b.pts[p].y };
}

fn addp(x: f64, y: f64) void {
    if (el_np >= MAXEP) return;
    el_pt[el_np] = .{ x, y };
    el_np += 1;
}

fn lpush(x: f64, y: f64) void {
    if (T.pf_np >= MAXP) return;
    T.pf_pt[T.pf_np] = .{ x, y };
    T.pf_np += 1;
}

/// arcpts: an arc's points start .. end counter-clockwise (to the chainer),
/// or a circle's CSEG (straight into a loop).
fn arcpts(b: *const sk.Block, e: *const sk.Ent, full: bool) void {
    const c = skp(b, @intCast(e.p[0]));
    var a0: f64 = 0;
    var sweep: f64 = TWO_PI;
    if (!full) {
        const p1 = skp(b, @intCast(e.p[1]));
        const p2 = skp(b, @intCast(e.p[2]));
        a0 = sk.fpatan(p1[1] - c[1], p1[0] - c[0]);
        const a1 = sk.fpatan(p2[1] - c[1], p2[0] - c[0]);
        sweep = a1 - a0;
        if (!(sweep > 0)) sweep += TWO_PI;
    }
    var n = cvtt(sweep / TWO_PI * fi(CSEG));
    if (n < 2) n = 2;
    const cnt: u32 = if (full) @intCast(n) else @intCast(n + 1);
    var i: u32 = 0;
    while (i < cnt) : (i += 1) {
        const t = fi(i) / fi(n) * sweep + a0;
        const sc = sk.fsincos(t);
        const x = sc[1] * e.r + c[0];
        const y = sc[0] * e.r + c[1];
        if (full) lpush(x, y) else addp(x, y);
    }
}

fn ptOk(b: *const sk.Block, p: i32) bool {
    return p >= 0 and p < @min(b.npt, sk.MAX_PT);
}

/// prof_build: the sketch's closed loops (nl of them).
pub fn build(b: *const sk.Block) u32 {
    T.pf_nl = 0;
    T.pf_np = 0;
    el_n = 0;
    el_np = 0;
    const npt = @min(b.npt, sk.MAX_PT);
    const nent = @min(b.nent, sk.MAX_ENT);
    // the scale: 1 + the largest coordinate (for welding)
    var s: f64 = 1.0;
    for (0..npt) |i| {
        const q = skp(b, @intCast(i));
        s = maxsd(s, @abs(q[0]));
        s = maxsd(s, @abs(q[1]));
    }
    T.pf_scale = s;
    var w = s * WELD;
    w *= w;
    // clusters: points that coincide
    for (0..npt) |i| {
        clus[i] = @intCast(i);
        const pi = skp(b, @intCast(i));
        for (0..i) |j| {
            const pj = skp(b, @intCast(j));
            var dx = pj[0] - pi[0];
            var dy = pj[1] - pi[1];
            dx *= dx;
            dy *= dy;
            if (!(dx + dy > w)) {
                clus[i] = clus[j];
                break;
            }
        }
    }
    // elements: circles become loops; lines and arcs go to the chainer
    for (0..nent) |k| {
        const e = &b.ents[k];
        if (e.flags & sk.F_CONSTR != 0) continue;
        if (e.typ == sk.E_CIRCLE) {
            if (T.pf_nl >= MAXL) continue;
            if (!ptOk(b, e.p[0])) continue;
            T.pf_ls[T.pf_nl] = T.pf_np;
            arcpts(b, e, true);
            T.pf_ln[T.pf_nl] = T.pf_np - T.pf_ls[T.pf_nl];
            T.pf_nl += 1;
            continue;
        }
        if (el_n >= MAXEL) continue;
        el_s[el_n] = el_np;
        var ea: u32 = 0;
        var eb: u32 = 0;
        if (e.typ == sk.E_LINE) {
            if (!ptOk(b, e.p[0]) or !ptOk(b, e.p[1])) continue;
            const p0 = skp(b, @intCast(e.p[0]));
            const p1 = skp(b, @intCast(e.p[1]));
            addp(p0[0], p0[1]);
            addp(p1[0], p1[1]);
            ea = @intCast(e.p[0]);
            eb = @intCast(e.p[1]);
        } else if (e.typ == sk.E_ARC) {
            if (!ptOk(b, e.p[0]) or !ptOk(b, e.p[1]) or !ptOk(b, e.p[2])) continue;
            arcpts(b, e, false);
            ea = @intCast(e.p[1]);
            eb = @intCast(e.p[2]);
        } else continue;
        el_a[el_n] = clus[ea];
        el_b[el_n] = clus[eb];
        el_c[el_n] = el_np - el_s[el_n];
        el_used[el_n] = 0;
        el_n += 1;
    }
    // walk: from an unused element, follow matching ends back to the start
    var k: u32 = 0;
    chain: while (k < el_n) : (k += 1) {
        if (el_used[k] != 0) continue;
        if (T.pf_nl >= MAXL) break;
        const first = T.pf_np;
        const start = el_a[k];
        var cur = k;
        var rev = false;
        while (true) {
            el_used[cur] = 1;
            putEl(cur, rev);
            const far = if (rev) el_a[cur] else el_b[cur];
            if (far == start) break;
            var c: u32 = 0;
            const found = while (c < el_n) : (c += 1) {
                if (el_used[c] != 0) continue;
                if (el_a[c] == far) {
                    rev = false;
                    break true;
                }
                if (el_b[c] == far) {
                    rev = true;
                    break true;
                }
            } else false;
            if (!found) {
                T.pf_np = first; // not closed: what it collected goes
                continue :chain;
            }
            cur = c;
        }
        T.pf_ls[T.pf_nl] = first;
        const cnt = T.pf_np - first;
        if (cnt < 3) {
            T.pf_np = first;
            continue;
        }
        T.pf_ln[T.pf_nl] = cnt;
        T.pf_nl += 1;
    }
    T.nest();
    return T.pf_nl;
}

/// put_el: an element's points except the last into the loop.
fn putEl(e: u32, rev: bool) void {
    const c = el_c[e];
    if (c == 0) return;
    var i: u32 = 0;
    while (i < c - 1) : (i += 1) {
        const idx = if (rev) c - 1 - i else i;
        const q = el_pt[el_s[e] + idx];
        lpush(q[0], q[1]);
    }
}

fn lp(i: u32) [2]f64 {
    return T.pf_pt[i];
}

/// prof_count: material loops (regions).
pub const count = T.count;

/// prof_points: a circle of radius r at each sketch point no entity uses.
pub fn points(b: *const sk.Block, r: f64) u32 {
    T.pf_nl = 0;
    T.pf_np = 0;
    const npt = @min(b.npt, sk.MAX_PT);
    const nent = @min(b.nent, sk.MAX_ENT);
    for (0..npt) |pi| {
        const p: i32 = @intCast(pi);
        const used = for (b.ents[0..nent]) |*e| {
            if (e.p[0] == p or e.p[1] == p or e.p[2] == p) break true;
        } else false;
        if (used) continue;
        if (T.pf_nl >= MAXL) break;
        T.pf_ls[T.pf_nl] = T.pf_np;
        T.pf_ln[T.pf_nl] = 32;
        T.pf_dep[T.pf_nl] = 0;
        T.pf_par[T.pf_nl] = -1;
        T.pf_nl += 1;
        const c = skp(b, @intCast(pi));
        for (0..32) |k| {
            const t = fi(k) / 32.0 * TWO_PI;
            const sc = sk.fsincos(t);
            var x = sc[1] * r;
            var y = sc[0] * r;
            x += c[0];
            y += c[1];
            lpush(x, y);
        }
    }
    return T.pf_nl;
}

/// lnorm: the unit left normal of a -> b.
fn lnorm(a: [2]f64, b: [2]f64) [2]f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    var l = dx * dx;
    l += dy * dy;
    l = maxsd(@sqrt(l), EPS);
    return .{ 0.0 - dy / l, dx / l };
}

/// prof_offset: every loop moves t to its left (material loops shrink, holes
/// grow), mitred corners.
pub fn offset(t: f64) void {
    for (0..T.pf_nl) |li| {
        const s = T.pf_ls[li];
        const n = T.pf_ln[li];
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const pv = lp(s + (i + n - 1) % n);
            const c = lp(s + i);
            const nx = lp(s + (i + 1) % n);
            const n1 = lnorm(pv, c);
            const n2 = lnorm(c, nx);
            var d = n1[0] * n2[0];
            d += n1[1] * n2[1];
            d += 1.0;
            d = maxsd(d, 0.5);
            const k = t / d;
            el_pt[i] = .{ (n1[0] + n2[0]) * k + c[0], (n1[1] + n2[1]) * k + c[1] };
        }
        @memcpy(T.pf_pt[s .. s + n], el_pt[0..n]);
    }
}

// ---- meshes ---------------------------------------------------------------------------

/// What maps plane points to the world: the sketch object's matrix (and a
/// pattern's extra transform).
pub const Place = struct {
    b: *const sk.Block,
    mtx: [12]f32,
    x: ?[12]f32 = null,
};

fn xformPoint(mt: *const [12]f32, p: [3]f32) [3]f32 {
    var r: [3]f32 = undefined;
    for (0..3) |c| {
        var v = mt[c * 4] * p[0];
        v += mt[c * 4 + 1] * p[1];
        v += mt[c * 4 + 2] * p[2];
        v += mt[c * 4 + 3];
        r[c] = v;
    }
    return r;
}

const Mk = struct {
    pl: *const Place,
    b: fm.Builder,
    vol: f64 = 0,

    /// world: a plane point lifted w along the normal, through the matrices.
    fn vert(k: *Mk, u: f64, v: f64, w: f64) !u32 {
        // (sk_plane_xyz with the offset moved by w for the moment)
        const fo: f32 = @floatCast(k.pl.b.offset + w);
        const fu: f32 = @floatCast(u);
        const fv: f32 = @floatCast(v);
        const q: [3]f32 = switch (k.pl.b.plane) {
            0 => .{ fu, fv, fo },
            1 => .{ fu, fo, -fv },
            else => .{ fo, fv, -fu },
        };
        var r = xformPoint(&k.pl.mtx, q);
        if (k.pl.x) |*x| r = xformPoint(x, r);
        return k.b.vert(r);
    }
    fn tetvol(k: *const Mk, ai: u32, bi: u32, ci: u32) f64 {
        const P = k.b.verts.items;
        const f = struct {
            fn f(x: f32) f64 {
                return @floatCast(x);
            }
        }.f;
        const a = P[ai];
        const b = P[bi];
        const c = P[ci];
        var x8 = f(b[1]) * f(c[2]);
        x8 -= f(b[2]) * f(c[1]);
        x8 *= f(a[0]);
        var x10 = f(b[2]) * f(c[0]);
        x10 -= f(b[0]) * f(c[2]);
        x10 *= f(a[1]);
        x8 += x10;
        x10 = f(b[0]) * f(c[1]);
        x10 -= f(b[1]) * f(c[0]);
        x10 *= f(a[2]);
        x8 += x10;
        return x8;
    }
    /// face / face_n: a polygon; its signed volume is added up.
    fn face(k: *Mk, idx: []const u32) !void {
        var i: usize = 1;
        while (i + 1 < idx.len) : (i += 1) k.vol = k.tetvol(idx[0], idx[i], idx[i + 1]) + k.vol;
        try k.b.poly(idx);
    }
    /// face_nodup: a quad, a triangle when two corners are one vertex, or nothing.
    fn faceNodup(k: *Mk, a0: u32, b0: u32, c0: u32, d0: u32) !void {
        var a = a0;
        var b = b0;
        var c = c0;
        if (a == b) {
            a = b0;
            b = c0;
            c = d0;
        } else if (b == c) {
            b = c0;
            c = d0;
        } else if (c == d0 or d0 == a) {} else return k.face(&.{ a0, b0, c0, d0 });
        if (a == b or b == c or c == a) return;
        return k.face(&.{ a, b, c });
    }
    /// finish: oriented outwards (flipped when its volume is not positive),
    /// or null when it has no faces.
    fn finish(k: *Mk) !?fm.M {
        if (k.b.npolys() == 0) return null;
        if (!(0 < k.vol)) {
            const o = k.b.poff.items;
            for (0..o.len - 1) |p| std.mem.reverse(u32, k.b.loops.items[o[p]..o[p + 1]]);
        }
        return try k.b.done();
    }
};

fn hasHoles(l: u32) bool {
    for (0..T.pf_nl) |c| {
        if (T.pf_par[c] == @as(i32, @intCast(l))) return true;
    }
    return false;
}

/// prof_prism: a closed mesh of every region from w0 to w1 (build / points
/// first), or null.
pub fn prism(a: Allocator, pl: *const Place, w0: f64, w1: f64) !?fm.M {
    var k = Mk{ .pl = pl, .b = try fm.Builder.init(a) };
    defer k.b.deinit();
    for (0..T.pf_np) |i| {
        _ = try k.vert(T.pf_pt[i][0], T.pf_pt[i][1], w0);
        _ = try k.vert(T.pf_pt[i][0], T.pf_pt[i][1], w1);
    }
    // walls: each loop edge (a, b): (a0, b0, b1, a1)
    for (0..T.pf_nl) |l| {
        const s = T.pf_ls[l];
        const n = T.pf_ln[l];
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const ia = s + i;
            const ib = s + (i + 1) % n;
            try k.face(&.{ 2 * ia, 2 * ib, 2 * ib + 1, 2 * ia + 1 });
        }
    }
    // caps: each material loop with its holes
    var buf: [MAXP]u32 = undefined;
    for (0..T.pf_nl) |li| {
        const l: u32 = @intCast(li);
        if (T.pf_dep[l] & 1 != 0) continue;
        const s = T.pf_ls[l];
        const n = T.pf_ln[l];
        if (!hasHoles(l)) {
            for (0..n) |c| buf[c] = 2 * (s + @as(u32, @intCast(c))) + 1;
            try k.face(buf[0..n]);
            for (0..n) |c| buf[c] = 2 * (s + n - 1 - @as(u32, @intCast(c)));
            try k.face(buf[0..n]);
            continue;
        }
        T.merge(l);
        T.earclip();
        for (T.pf_tri[0..T.pf_ntri]) |t| {
            try k.face(&.{ 2 * t[0] + 1, 2 * t[1] + 1, 2 * t[2] + 1 });
            try k.face(&.{ 2 * t[0], 2 * t[2], 2 * t[1] });
        }
    }
    return k.finish();
}

/// prof_revolve: the loops swept about the sketch's u (axis 0) or v axis by
/// an angle (radians), or null.
pub fn revolve(a: Allocator, pl: *const Place, angle: f64, axis: u32) !?fm.M {
    var steps = cvtt(@abs(angle) / TWO_PI * fi(CSEG));
    if (steps < 4) steps = 4;
    const st: u32 = @intCast(steps);
    // (a turn of thousands of radians: the original's mesh_new cannot hold
    // it either; here it fails before it asks for gigabytes)
    if (@as(u64, T.pf_np) * (@as(u64, st) + 1) > 1 << 24) return null;
    const full = @abs(angle) >= TWO_PI - EPS;
    var k = Mk{ .pl = pl, .b = try fm.Builder.init(a) };
    defer k.b.deinit();
    var s: u32 = 0;
    while (s <= st) : (s += 1) {
        const t = fi(s) / fi(st) * angle;
        const sc = sk.fsincos(t);
        for (0..T.pf_np) |i| {
            var u = T.pf_pt[i][0];
            var v = T.pf_pt[i][1];
            var w: f64 = undefined;
            if (axis == 0) {
                w = v * sc[0];
                v *= sc[1];
            } else {
                w = 0.0 - u * sc[0];
                u *= sc[1];
            }
            _ = try k.vert(u, v, w);
        }
    }
    const R = struct {
        st: u32,
        full: bool,
        axis: u32,
        fn v(r: @This(), p: u32, s0: u32) u32 {
            var sx = s0;
            if (sx == r.st and r.full) sx = 0;
            const q = lp(p);
            const d = if (r.axis == 0) q[1] else q[0];
            if (!(@abs(d) > T.pf_scale * WELD)) sx = 0;
            return sx * T.pf_np + p;
        }
    };
    const r = R{ .st = st, .full = full, .axis = axis };
    for (0..T.pf_nl) |l| {
        const s0 = T.pf_ls[l];
        const n = T.pf_ln[l];
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const pa = s0 + i;
            const pb = s0 + (i + 1) % n;
            var j: u32 = 0;
            while (j < st) : (j += 1) try k.faceNodup(r.v(pa, j), r.v(pb, j), r.v(pb, j + 1), r.v(pa, j + 1));
        }
    }
    if (!full) {
        for (0..T.pf_nl) |li| {
            const l: u32 = @intCast(li);
            if (T.pf_dep[l] & 1 != 0) continue;
            T.merge(l);
            T.earclip();
            for (T.pf_tri[0..T.pf_ntri]) |t| {
                try k.face(&.{ r.v(t[0], 0), r.v(t[2], 0), r.v(t[1], 0) });
                try k.face(&.{ r.v(t[0], st), r.v(t[1], st), r.v(t[2], st) });
            }
        }
    }
    return k.finish();
}

// ---- tests ------------------------------------------------------------------------------

fn testSketch() !*sk.Block {
    const b = sk.new(0).?;
    return b;
}

test "a rectangle with a round hole: two loops, one region, a closed prism" {
    const b = try testSketch();
    const p = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 2 }, .{ 0, 2 } };
    var ids: [4]i32 = undefined;
    for (p, 0..) |q, i| ids[i] = sk.addPoint(b, q[0], q[1]);
    for (0..4) |i| _ = sk.addLine(b, ids[i], ids[(i + 1) % 4]);
    const c = sk.addPoint(b, 2, 1);
    _ = sk.addCircle(b, c, 0.5);
    try std.testing.expectEqual(@as(u32, 2), build(b));
    try std.testing.expectEqual(@as(u32, 1), count());
    const pl = Place{ .b = b, .mtx = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 } };
    const a = std.testing.allocator;
    const r = (try prism(a, &pl, 0, 3)).?;
    defer r.deinit(a);
    try std.testing.expect(try fm.manifold(a, &r));
    try std.testing.expectEqual(@as(f32, 3), r.bmax[2]);
    const rv = (try revolve(a, &pl, 1.0, 1)).?;
    defer rv.deinit(a);
    const k = try fm.compact(a, &rv);
    defer k.deinit(a);
    try std.testing.expect(try fm.manifold(a, &k));
    // a loose point gives a hole circle
    try std.testing.expectEqual(@as(u32, 0), points(b, 0.1));
    _ = sk.addPoint(b, 1, 1);
    try std.testing.expectEqual(@as(u32, 1), points(b, 0.1));
}
