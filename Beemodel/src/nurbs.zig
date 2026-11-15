//! nurbs.s: the B-rep kernel's geometry. Curves are lines, circles, ellipses
//! or NURBS; surfaces are planes, cylinders, cones, spheres, tori or NURBS
//! (rational, tensor product). The analytic ones are evaluated in closed form
//! with the parametrisations STEP and OpenCASCADE use:
//!
//!   plane     O + u X + v Y
//!   cylinder  O + R (cos u X + sin u Y) + v Z
//!   cone      O + (R + v sin a)(cos u X + sin u Y) + v cos a Z
//!   sphere    O + R cos v (cos u X + sin u Y) + R sin v Z
//!   torus     O + (R + r cos v)(cos u X + sin u Y) + r sin v Z
//!
//! NURBS keep homogeneous control points (w x, w y, w z, w) and clamped knot
//! vectors (The NURBS Book A2.2 / A2.3, A5.1, degree elevation by Bezier
//! pieces). Everything is in doubles, in the original's order of operations
//! (no fused multiply-adds), so values match it bit for bit; sines, cosines
//! and arctangents go through the x87 as the original's do. The kernel's
//! memory is a set of arenas reset by each rebuild; records name each other
//! by index, as in the original.
//!
//! nbcheck.s (nurbscheck(k)) is at the end.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// ---- comparisons as the original's branches take them (NaN included) --------------
// comisd a, b then: jb (a < b or unordered), ja (a > b), jae (a >= b),
// jbe (a <= b or unordered); ucomisd then je (equal or unordered), jp.
pub inline fn jb(a: f64, b: f64) bool {
    return !(a >= b);
}
pub inline fn ja(a: f64, b: f64) bool {
    return a > b;
}
pub inline fn jae(a: f64, b: f64) bool {
    return a >= b;
}
pub inline fn jbe(a: f64, b: f64) bool {
    return !(a > b);
}
pub inline fn je(a: f64, b: f64) bool {
    return !(a < b or a > b);
}
/// maxsd a, b: a when a > b, else b (NaN: b).
pub inline fn maxsd(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}
/// minsd a, b: a when a < b, else b (NaN: b).
pub inline fn minsd(a: f64, b: f64) f64 {
    return if (a < b) a else b;
}
pub inline fn fabs(a: f64) f64 {
    return @bitCast(@as(u64, @bitCast(a)) & 0x7fffffffffffffff);
}
pub inline fn fneg(a: f64) f64 {
    return @bitCast(@as(u64, @bitCast(a)) ^ 0x8000000000000000);
}
/// cvttsd2si (32-bit): out of range or NaN gives the integer indefinite.
pub inline fn cvtt(a: f64) i32 {
    if (!(a > -2147483649.0 and a < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(a);
}
/// cvttsd2si (64-bit).
pub inline fn cvtt64(a: f64) i64 {
    if (!(a > -9223372036854777856.0 and a < 9223372036854775808.0)) return std.math.minInt(i64);
    return @intFromFloat(a);
}
/// cvtsd2si (32-bit, round to nearest even).
pub inline fn cvtr(a: f64) i32 {
    const r = @round(a);
    const e = if (@abs(a - @trunc(a)) == 0.5) 2.0 * @round(a / 2.0) else r;
    return cvtt(e);
}
pub inline fn fl(i: anytype) f64 {
    return @floatFromInt(i);
}

// ---- the x87, as the original computes ---------------------------------------------
const sk = @import("sketch.zig");
/// fld a; fsincos -> .{ sin, cos }
pub inline fn dsincos(a: f64) [2]f64 {
    return sk.fsincos(a);
}
/// fld y; fld x; fpatan
pub inline fn datan2(y: f64, x: f64) f64 {
    return sk.fpatan(y, x);
}

pub const nk_pi: f64 = 3.14159265358979323846;
pub const nk_2pi: f64 = 6.28318530717958647692;
pub const nk_hpi: f64 = 1.57079632679489661923;
pub const nk_qpi: f64 = 0.78539816339744830962;
const nk_tiny: f64 = 1.0e-12;

// ---- arenas (mem.s): reserved address space, bump allocation, reset ---------------
pub const Arena = struct {
    base: [*]align(4096) u8 = undefined,
    cap: usize,
    used: usize = 0,
    peak: usize = 0,
    warm: usize = 1 << 20,
    low: u32 = 0,
    ready: bool = false,

    pub fn init(a: *Arena) bool {
        if (a.ready) return true;
        const rc = linux.mmap(null, a.cap, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
        if (linux.errno(rc) != .SUCCESS) return false;
        a.base = @ptrFromInt(rc);
        a.ready = true;
        return true;
    }

    /// 16-byte aligned, not cleared; null when the arena is full.
    pub fn alloc(a: *Arena, n: usize) ?[*]align(16) u8 {
        if (!a.ready) return null;
        const at = std.mem.alignForward(usize, a.used, 16);
        if (n > a.cap or at + n > a.cap) return null;
        a.used = at + n;
        if (a.used > a.peak) a.peak = a.used;
        return @alignCast(a.base + at);
    }

    pub fn reset(a: *Arena) void {
        const peak = a.peak;
        a.used = 0;
        a.peak = 0;
        if (peak > a.warm) {
            a.warm = peak;
            a.low = 0;
            return;
        }
        if (peak >= a.warm >> 1) {
            a.low = 0;
            return;
        }
        a.low += 1;
        if (a.low < 16) return;
        const keep = std.mem.alignForward(usize, @max(peak, 1 << 20), 4096);
        const old = a.warm;
        a.warm = keep;
        a.low = 0;
        if (old > keep and a.ready) _ = linux.madvise(a.base + keep, old - keep, linux.MADV.DONTNEED);
    }

    /// The record at index i (records of one size from the arena's start).
    pub inline fn rec(a: *Arena, comptime T: type, i: usize) *T {
        return @ptrCast(@alignCast(a.base + i * @sizeOf(T)));
    }
    pub inline fn count(a: *Arena, comptime T: type) usize {
        return a.used / @sizeOf(T);
    }
};

// ---- records (brep.inc) ---------------------------------------------------------------
pub const CT_LINE = 1;
pub const CT_CIRCLE = 2;
pub const CT_ELLIPSE = 3;
pub const CT_NURBS = 4;

pub const Curve = extern struct {
    typ: u32,
    dim: u32, // 3, or 2 for a curve in a face's (u, v)
    deg: u32,
    n: u32,
    kn: ?[*]f64, // N + p + 1 knots
    cp: ?[*]f64, // homogeneous points (w x, w y, w z, w)
    o: [3]f64,
    x: [3]f64,
    y: [3]f64,
    r1: f64,
    r2: f64,
    flags: u32,
    _pad: u32,
};

pub const ST_PLANE = 1;
pub const ST_CYL = 2;
pub const ST_CONE = 3;
pub const ST_SPHERE = 4;
pub const ST_TORUS = 5;
pub const ST_NURBS = 6;

pub const Surface = extern struct {
    typ: u32,
    du: u32,
    dv: u32,
    nu: u32,
    nv: u32,
    flags: u32,
    ku: ?[*]f64,
    kv: ?[*]f64,
    cp: ?[*]f64, // nu * nv points, u major
    o: [3]f64,
    x: [3]f64,
    y: [3]f64,
    z: [3]f64, // (Z = X x Y)
    r1: f64, // radius / major radius
    r2: f64, // torus: minor radius; cone: half angle
    sa: f64, // cone: sin, cos of the half angle
    ca: f64,
    id: u32,
    _pad: [3]u32,
};

comptime {
    std.debug.assert(@sizeOf(Curve) == 128);
    std.debug.assert(@offsetOf(Curve, "o") == 32);
    std.debug.assert(@offsetOf(Curve, "r1") == 104);
    std.debug.assert(@offsetOf(Curve, "flags") == 120);
    std.debug.assert(@sizeOf(Surface) == 192);
    std.debug.assert(@offsetOf(Surface, "o") == 48);
    std.debug.assert(@offsetOf(Surface, "r1") == 144);
    std.debug.assert(@offsetOf(Surface, "id") == 176);
}

pub var bk_d: Arena = .{ .cap = 0x80000000 }; // knots, control points, scratch
pub var bk_cv: Arena = .{ .cap = 0x10000000 }; // curves
pub var bk_sf: Arena = .{ .cap = 0x10000000 }; // surfaces

/// bk_init: the arenas (once).
pub fn init() void {
    _ = bk_d.init();
    _ = bk_cv.init();
    _ = bk_sf.init();
}

/// bk_reset: everything the last rebuild made goes.
pub fn reset() void {
    init();
    bk_d.reset();
    bk_cv.reset();
    bk_sf.reset();
}

/// bk_data: 16-byte aligned memory (not cleared).
pub fn data(bytes: usize) ?[*]align(16) u8 {
    return bk_d.alloc(bytes);
}
pub fn doubles(n: usize) ?[*]f64 {
    const p = bk_d.alloc(n * 8) orelse return null;
    return @ptrCast(p);
}

/// kc_new: a cleared curve.
pub fn kcNew() ?*Curve {
    const p = bk_cv.alloc(@sizeOf(Curve)) orelse return null;
    const c: *Curve = @ptrCast(p);
    c.* = std.mem.zeroes(Curve);
    return c;
}
/// ks_new: a cleared surface.
pub fn ksNew() ?*Surface {
    const p = bk_sf.alloc(@sizeOf(Surface)) orelse return null;
    const s: *Surface = @ptrCast(p);
    s.* = std.mem.zeroes(Surface);
    return s;
}
pub fn cv(i: usize) *Curve {
    return bk_cv.rec(Curve, i);
}
pub fn sf(i: usize) *Surface {
    return bk_sf.rec(Surface, i);
}
pub fn cvIndex(c: *const Curve) u32 {
    return @intCast((@intFromPtr(c) - @intFromPtr(bk_cv.base)) / @sizeOf(Curve));
}
pub fn sfIndex(s: *const Surface) u32 {
    return @intCast((@intFromPtr(s) - @intFromPtr(bk_sf.base)) / @sizeOf(Surface));
}
pub fn nCurves() u32 {
    return @intCast(bk_cv.count(Curve));
}
pub fn nSurfaces() u32 {
    return @intCast(bk_sf.count(Surface));
}

// ---- small helpers (doubles; 3-vectors) ---------------------------------------------
pub const V3 = [3]f64;

/// lin3: O + a A + b B + c C (any of O, B, C may be absent)
pub fn lin3(o: ?*const V3, A: *const V3, a: f64, B: ?*const V3, b: f64, C: ?*const V3, c: f64) V3 {
    var r: V3 = .{ 0, 0, 0 };
    if (o) |p| r = p.*;
    r[0] += A[0] * a;
    r[1] += A[1] * a;
    r[2] += A[2] * a;
    if (B) |p| {
        r[0] += p[0] * b;
        r[1] += p[1] * b;
        r[2] += p[2] * b;
    }
    if (C) |p| {
        r[0] += p[0] * c;
        r[1] += p[1] * c;
        r[2] += p[2] * c;
    }
    return r;
}
pub inline fn v3sub(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
pub inline fn v3add(a: V3, b: V3) V3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
pub inline fn v3dot(a: V3, b: V3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
pub inline fn v3cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
pub inline fn v3len(a: V3) f64 {
    return @sqrt(v3dot(a, a));
}
pub inline fn v3dist(a: V3, b: V3) f64 {
    const x = a[0] - b[0];
    const y = a[1] - b[1];
    const z = a[2] - b[2];
    return @sqrt(x * x + y * y + z * z);
}
/// v3norm: made unit length in place -> the old length
pub fn v3norm(a: *V3) f64 {
    const l = v3len(a.*);
    if (je(l, 0)) return l;
    const k = 1.0 / l;
    a[0] *= k;
    a[1] *= k;
    a[2] *= k;
    return l;
}
pub inline fn v3scale(a: V3, s: f64) V3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
/// v3axpy: out += s a
pub inline fn v3axpy(out: *V3, a: V3, s: f64) void {
    out[0] = a[0] * s + out[0];
    out[1] = a[1] * s + out[1];
    out[2] = a[2] * s + out[2];
}

// ---- B-spline basis ------------------------------------------------------------------
pub const MAXP = 15;

/// nb_span(n: the last control point's index, p, u, knots) -> the knot span
/// holding u (p .. n)
pub fn span(n: u32, p: u32, u: f64, kn: [*]const f64) u32 {
    if (!jb(u, kn[n + 1])) return n;
    if (!ja(u, kn[p])) return p;
    var lo: u32 = p;
    var hi: u32 = n + 1;
    while (true) {
        const mid = (lo +% hi) >> 1;
        if (jb(u, kn[mid])) {
            hi = mid;
        } else if (jb(u, kn[mid + 1])) {
            return mid;
        } else lo = mid;
    }
}

/// nb_ders rows: out[k][j] is the k-th derivative of N(span - p + j).
pub const Ders = [3][16]f64;

/// nb_ders(span, p, derivatives 0..2, u, knots, out)
pub fn ders(sp: u32, p: u32, nd_in: u32, u: f64, kn: [*]const f64, out: [][16]f64) void {
    var ndu: [16][16]f64 = undefined;
    var left: [16]f64 = undefined;
    var right: [16]f64 = undefined;
    var a: [2][16]f64 = undefined;
    var nd = nd_in;
    // rows 1 .. nd start at zero (derivatives above p stay zero)
    var k: u32 = 1;
    while (k <= nd) : (k += 1) {
        var j: u32 = 0;
        while (j <= p) : (j += 1) out[k][j] = 0;
    }
    if (nd > p) nd = p;
    ndu[0][0] = 1.0;
    var j: u32 = 1;
    while (j <= p) : (j += 1) {
        left[j] = u - kn[sp + 1 - j];
        right[j] = kn[sp + j] - u;
        var saved: f64 = 0;
        var r: u32 = 0;
        while (r < j) : (r += 1) {
            const rr = right[r + 1];
            const ll = left[j - r];
            const s = rr + ll;
            ndu[j][r] = s;
            const temp = ndu[r][j - 1] / s;
            ndu[r][j] = rr * temp + saved;
            saved = ll * temp;
        }
        ndu[j][j] = saved;
    }
    j = 0;
    while (j <= p) : (j += 1) out[0][j] = ndu[j][p];
    if (nd == 0) return;
    const pi: i32 = @intCast(p);
    var r: i32 = 0;
    while (r <= pi) : (r += 1) {
        a[0][0] = 1.0;
        var s1: usize = 0;
        var s2: usize = 1;
        var kk: i32 = 1;
        while (kk <= @as(i32, @intCast(nd))) : (kk += 1) {
            var d: f64 = 0;
            const rk = r - kk;
            const pk = pi - kk;
            const upk: usize = @intCast(pk);
            if (r >= kk) {
                const urk: usize = @intCast(rk);
                const v = a[s1][0] / ndu[upk + 1][urk];
                a[s2][0] = v;
                d = v * ndu[urk][upk];
            }
            const j1: i32 = if (rk >= -1) 1 else -rk;
            const j2: i32 = if (r - 1 <= pk) kk - 1 else pi - r;
            var jj: i32 = j1;
            while (jj <= j2) : (jj += 1) {
                const uj: usize = @intCast(jj);
                const rkj: usize = @intCast(rk + jj);
                const v = (a[s1][uj] - a[s1][uj - 1]) / ndu[upk + 1][rkj];
                a[s2][uj] = v;
                d += v * ndu[rkj][upk];
            }
            if (r <= pk) {
                const uk: usize = @intCast(kk);
                const ur: usize = @intCast(r);
                const v = fneg(a[s1][uk - 1]) / ndu[upk + 1][ur];
                a[s2][uk] = v;
                d += v * ndu[ur][upk];
            }
            out[@intCast(kk)][@intCast(r)] = d;
            const t = s1;
            s1 = s2;
            s2 = t;
        }
    }
    // times p (p - 1) ...
    var m = fl(p);
    k = 1;
    while (k <= nd) : (k += 1) {
        j = 0;
        while (j <= p) : (j += 1) out[k][j] *= m;
        m *= fl(p - k);
    }
}

// ---- curves ----------------------------------------------------------------------------
/// The point and the first and second derivative.
pub const CEval = [3]V3;

/// crv_eval(curve, t)
pub fn crvEval(c: *const Curve, t: f64) CEval {
    switch (c.typ) {
        CT_LINE => {
            return .{ lin3(&c.o, &c.x, t, null, 0, null, 0), c.x, .{ 0, 0, 0 } };
        },
        CT_CIRCLE, CT_ELLIPSE => {
            const sc = dsincos(t);
            const s = sc[0];
            const co = sc[1];
            const a = c.r1;
            const b = if (c.typ == CT_ELLIPSE) c.r2 else a;
            const ac = a * co;
            const bs = b * s;
            const as_ = a * s;
            const bc = b * co;
            return .{
                lin3(&c.o, &c.x, ac, &c.y, bs, null, 0),
                lin3(null, &c.x, fneg(as_), &c.y, bc, null, 0),
                lin3(null, &c.x, fneg(ac), &c.y, fneg(bs), null, 0),
            };
        },
        CT_NURBS => return crvNurbs(c, t),
        else => return .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } },
    }
}

fn crvNurbs(c: *const Curve, t_in: f64) CEval {
    const p = c.deg;
    const kn = c.kn.?;
    var t = maxsd(t_in, kn[p]);
    t = minsd(t, kn[c.n]);
    const sp = span(c.n -% 1, p, t, kn);
    var d: [3][16]f64 = undefined;
    ders(sp, p, 2, t, kn, &d);
    var A: [3][4]f64 = undefined;
    const cp = c.cp.? + (sp - p) * 4;
    for (0..3) |k| {
        var s: [4]f64 = .{ 0, 0, 0, 0 };
        for (0..p + 1) |j| {
            const w = d[k][j];
            for (0..4) |q| s[q] += cp[j * 4 + q] * w;
        }
        A[k] = s;
    }
    return rational(&A);
}

/// rational: the point and two derivatives of the projected curve
fn rational(A: *const [3][4]f64) CEval {
    var o: CEval = undefined;
    const w = A[0][3];
    const iw = 1.0 / w;
    for (0..3) |i| {
        const c0 = A[0][i] * iw;
        o[0][i] = c0;
        const c1 = (A[1][i] - A[1][3] * c0) * iw;
        o[1][i] = c1;
        const t3 = (A[1][3] + A[1][3]) * c1;
        const t4 = A[2][3] * c0;
        o[2][i] = (A[2][i] - t3 - t4) * iw;
    }
    return o;
}

// ---- surfaces --------------------------------------------------------------------------
/// The point and the partial derivatives Su, Sv.
pub const SEval = [3]V3;

/// srf_eval(surface, u, v)
pub fn srfEval(s: *const Surface, u: f64, v: f64) SEval {
    if (s.typ == ST_NURBS) return srfNurbs(s, u, v);
    if (s.typ == ST_PLANE) {
        return .{ lin3(&s.o, &s.x, u, &s.y, v, null, 0), v3scale(s.x, 1.0), v3scale(s.y, 1.0) };
    }
    const scu = dsincos(u);
    const su = scu[0];
    const cu = scu[1];
    const scv = dsincos(v);
    const sv = scv[0];
    const cvv = scv[1];
    var o: SEval = undefined;
    switch (s.typ) {
        ST_CYL => {
            ring(s, &o, s.r1, v, su, cu);
            o[2] = v3scale(s.z, 1.0);
        },
        ST_CONE => {
            ring(s, &o, v * s.sa + s.r1, v * s.ca, su, cu);
            o[2] = lin3(null, &s.x, cu * s.sa, &s.y, su * s.sa, &s.z, s.ca);
        },
        ST_SPHERE => {
            ring(s, &o, s.r1 * cvv, s.r1 * sv, su, cu);
            meridian(s, &o, s.r1, sv, cvv, su, cu);
        },
        ST_TORUS => {
            ring(s, &o, s.r2 * cvv + s.r1, s.r2 * sv, su, cu);
            meridian(s, &o, s.r2, sv, cvv, su, cu);
        },
        else => return .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } },
    }
    return o;
}

// ring: P = O + rho (cu X + su Y) + h Z and Su = rho (-su X + cu Y)
fn ring(s: *const Surface, o: *SEval, rho: f64, h: f64, su: f64, cu: f64) void {
    o[0] = lin3(&s.o, &s.x, rho * cu, &s.y, rho * su, &s.z, h);
    o[1] = lin3(null, &s.x, fneg(rho * su), &s.y, rho * cu, null, 0);
}
// Sv = -r sv (cu X + su Y) + r cv Z
fn meridian(s: *const Surface, o: *SEval, r: f64, sv: f64, cvv: f64, su: f64, cu: f64) void {
    o[2] = lin3(null, &s.x, fneg(sv * r * cu), &s.y, fneg(sv * r * su), &s.z, cvv * r);
}

fn srfNurbs(s: *const Surface, u_in: f64, v_in: f64) SEval {
    const ku = s.ku.?;
    const kv = s.kv.?;
    const u = minsd(maxsd(u_in, ku[s.du]), ku[s.nu]);
    const v = minsd(maxsd(v_in, kv[s.dv]), kv[s.nv]);
    const spu = span(s.nu -% 1, s.du, u, ku);
    var nu: [2][16]f64 = undefined;
    ders(spu, s.du, 1, u, ku, &nu);
    const spv = span(s.nv -% 1, s.dv, v, kv);
    var nv: [2][16]f64 = undefined;
    ders(spv, s.dv, 1, v, kv, &nv);
    var S: [3][4]f64 = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } };
    const cp = s.cp.?;
    var i: u32 = 0;
    while (i <= s.du) : (i += 1) {
        const row = ((spu - s.du + i) * s.nv + spv - s.dv) * 4;
        var t0: [4]f64 = .{ 0, 0, 0, 0 };
        var t1: [4]f64 = .{ 0, 0, 0, 0 };
        var c: u32 = 0;
        while (c <= s.dv) : (c += 1) {
            const a = nv[0][c];
            const b = nv[1][c];
            for (0..4) |q| {
                const pw = cp[row + c * 4 + q];
                t0[q] += pw * a;
                t1[q] += pw * b;
            }
        }
        const a = nu[0][i];
        const b = nu[1][i];
        for (0..4) |q| {
            S[0][q] += t0[q] * a;
            S[1][q] += t0[q] * b;
            S[2][q] += t1[q] * a;
        }
    }
    var o: SEval = undefined;
    const iw = 1.0 / S[0][3];
    for (0..3) |q| {
        const p0 = S[0][q] * iw;
        o[0][q] = p0;
        o[1][q] = (S[1][q] - S[1][3] * p0) * iw;
        o[2][q] = (S[2][q] - S[2][3] * p0) * iw;
    }
    return o;
}

// ---- knot insertion, degree elevation ------------------------------------------------
/// nb_new: a NURBS curve with room for its knots and control points.
pub fn nbNew(deg: u32, n: u32) ?*Curve {
    const c = kcNew() orelse return null;
    c.typ = CT_NURBS;
    c.dim = 3;
    c.deg = deg;
    c.n = n;
    c.kn = doubles(deg + n + 1) orelse return null;
    c.cp = doubles(@as(usize, n) * 4) orelse return null;
    return c;
}

/// nb_mult: how often u is a knot
fn mult(c: *const Curve, u: f64) u32 {
    var m: u32 = 0;
    const kn = c.kn.?;
    var i: u32 = c.n + c.deg + 1;
    while (i > 0) {
        i -= 1;
        if (u == kn[i]) m += 1;
    }
    return m;
}

/// nb_insert: the curve with u inserted `times` times (at most up to
/// multiplicity p), or the curve itself when it cannot take more.
pub fn insert(c: *Curve, u: f64, times: i32) *Curve {
    const p = c.deg;
    const s = mult(c, u);
    var r: i32 = times;
    const lim: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(s));
    if (r > lim) r = lim;
    if (r <= 0) return c;
    const kn = c.kn.?;
    if (!ja(u, kn[p])) return c;
    if (jae(u, kn[c.n])) return c;
    const k = span(c.n - 1, p, u, kn);
    const ur: u32 = @intCast(r);
    const q = nbNew(p, c.n + ur) orelse return c;
    q.dim = c.dim;
    const qk = q.kn.?;
    var i: u32 = 0;
    while (i <= k) : (i += 1) qk[i] = kn[i];
    i = 1;
    while (i <= ur) : (i += 1) qk[k + i] = u;
    i = k + 1;
    while (i <= c.n + p) : (i += 1) qk[i + ur] = kn[i];
    const P = c.cp.?;
    const Q = q.cp.?;
    const ki: i32 = @intCast(k);
    const pi: i32 = @intCast(p);
    const si: i32 = @intCast(s);
    var ii: i32 = 0;
    while (ii <= ki - pi) : (ii += 1) cp4(Q, @intCast(ii), P, @intCast(ii));
    ii = ki - si;
    while (ii < @as(i32, @intCast(c.n))) : (ii += 1) cp4(Q, @intCast(ii + r), P, @intCast(ii));
    var Rw: [16][4]f64 = undefined;
    ii = 0;
    while (ii <= pi - si) : (ii += 1) {
        const at = @as(usize, @intCast(ki - pi + ii)) * 4;
        Rw[@intCast(ii)] = .{ P[at], P[at + 1], P[at + 2], P[at + 3] };
    }
    var L: i32 = 0;
    var j: i32 = 1;
    while (j <= r) : (j += 1) {
        L = ki - pi + j;
        ii = 0;
        while (ii <= pi - j - si) : (ii += 1) {
            const ui: usize = @intCast(ii);
            const kl = kn[@intCast(L + ii)];
            const alpha = (u - kl) / (kn[@intCast(ii + ki + 1)] - kl);
            const beta = 1.0 - alpha;
            for (0..4) |m| Rw[ui][m] = Rw[ui + 1][m] * alpha + Rw[ui][m] * beta;
        }
        put4(Q, @intCast(L), Rw[0]);
        put4(Q, @intCast(ki + r - j - si), Rw[@intCast(pi - j - si)]);
    }
    ii = L + 1;
    while (ii <= ki - si - 1) : (ii += 1) put4(Q, @intCast(ii), Rw[@intCast(ii - L)]);
    return q;
}

inline fn cp4(Q: [*]f64, qi: usize, P: [*]const f64, pi: usize) void {
    for (0..4) |m| Q[qi * 4 + m] = P[pi * 4 + m];
}
inline fn put4(Q: [*]f64, qi: usize, v: [4]f64) void {
    for (0..4) |m| Q[qi * 4 + m] = v[m];
}

/// nb_elevate: the same curve one degree higher, or null: knots made
/// p-fold (Bezier pieces), each piece raised, joined with (p+1)-fold knots.
pub fn elevate(c_in: *Curve) ?*Curve {
    var c = c_in;
    const p = c.deg;
    if (p + 1 > MAXP) return null;
    // the distinct inner knots (into the scratch arena)
    const inner = doubles(@as(usize, c.n) + 1) orelse return null;
    var ni: u32 = 0;
    const kn = c.kn.?;
    var i: u32 = p + 1;
    while (i < c.n) : (i += 1) {
        const x = kn[i];
        if (!ja(x, kn[p])) continue;
        if (ni != 0 and je(x, inner[ni - 1])) continue;
        inner[ni] = x;
        ni += 1;
    }
    var b: u32 = 0;
    while (b < ni) : (b += 1) {
        const m = mult(c, inner[b]);
        const t: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(m));
        if (t <= 0) continue;
        c = insert(c, inner[b], t);
    }
    const pieces = ni + 1;
    if (pieces * p + 1 != c.n) return null;
    const q = nbNew(p + 1, pieces * (p + 1) + 1) orelse return null;
    q.dim = c.dim;
    const qk = q.kn.?;
    const ck = c.kn.?;
    var w: usize = 0;
    const a = ck[p];
    for (0..p + 2) |_| {
        qk[w] = a;
        w += 1;
    }
    for (0..ni) |d| {
        for (0..p + 1) |_| {
            qk[w] = inner[d];
            w += 1;
        }
    }
    const e = ck[c.n];
    for (0..p + 2) |_| {
        qk[w] = e;
        w += 1;
    }
    // each piece Q0..Qp -> R0..R(p+1): Ri = i/(p+1) Q(i-1) + (1 - i/(p+1)) Qi
    const pp1 = fl(p + 1);
    var pc: u32 = 0;
    while (pc < pieces) : (pc += 1) {
        const Q0 = c.cp.? + pc * p * 4;
        const R0 = q.cp.? + pc * (p + 1) * 4;
        var k: u32 = 0;
        while (k <= p + 1) : (k += 1) {
            const alpha = fl(k) / pp1;
            const beta = 1.0 - alpha;
            var acc: [4]f64 = .{ 0, 0, 0, 0 };
            if (k != 0) {
                for (0..4) |m| acc[m] += Q0[(k - 1) * 4 + m] * alpha;
            }
            if (k <= p) {
                for (0..4) |m| acc[m] += Q0[k * 4 + m] * beta;
            }
            for (0..4) |m| R0[k * 4 + m] = acc[m];
        }
    }
    return q;
}

const RowOp = enum { insert, elevate };

/// ns_rows: the operation applied to every row of control points along the
/// direction (0 u, 1 v), or null.
fn nsRows(s: *const Surface, dir: u32, op: RowOp, t: f64, r: i32) ?*Surface {
    var rows = s.nv;
    var len = s.nu;
    if (dir != 0) {
        rows = s.nu;
        len = s.nv;
    }
    const tmp = nbNew(if (dir != 0) s.dv else s.du, len) orelse return null;
    const src = if (dir != 0) s.kv.? else s.ku.?;
    @memcpy(tmp.kn.?[0 .. tmp.n + tmp.deg + 1], src[0 .. tmp.n + tmp.deg + 1]);
    const ns = ksNew() orelse return null;
    ns.* = s.*;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const tc = tmp.cp.?;
        var c: u32 = 0;
        while (c < len) : (c += 1) {
            const at = if (dir == 0) c * s.nv + row else row * s.nv + c;
            cp4(tc, c, s.cp.?, at);
        }
        const after = switch (op) {
            .insert => insert(tmp, t, r),
            .elevate => elevate(tmp) orelse return null,
        };
        if (row == 0) {
            if (dir == 0) {
                ns.nu = after.n;
                ns.du = after.deg;
                ns.ku = after.kn;
            } else {
                ns.nv = after.n;
                ns.dv = after.deg;
                ns.kv = after.kn;
            }
            ns.cp = doubles(@as(usize, ns.nu) * ns.nv * 4) orelse return null;
        }
        if (after.n != (if (dir == 0) ns.nu else ns.nv)) return null;
        c = 0;
        while (c < after.n) : (c += 1) {
            const at = if (dir == 0) c * ns.nv + row else row * ns.nv + c;
            cp4(ns.cp.?, at, after.cp.?, c);
        }
    }
    return ns;
}

/// ns_insert(surface, direction, knot, times)
pub fn nsInsert(s: *const Surface, dir: u32, u: f64, times: i32) ?*Surface {
    return nsRows(s, dir, .insert, u, times);
}
/// ns_elevate(surface, direction)
pub fn nsElevate(s: *const Surface, dir: u32) ?*Surface {
    return nsRows(s, dir, .elevate, 0, 0);
}

// ---- construction ---------------------------------------------------------------------
/// nb_line: the segment as a degree 1 NURBS
pub fn nbLine(a: V3, b: V3) ?*Curve {
    const c = nbNew(1, 2) orelse return null;
    const k = c.kn.?;
    k[0] = 0;
    k[1] = 0;
    k[2] = 1;
    k[3] = 1;
    const p = c.cp.?;
    p[0] = a[0];
    p[1] = a[1];
    p[2] = a[2];
    p[3] = 1;
    p[4] = b[0];
    p[5] = b[1];
    p[6] = b[2];
    p[7] = 1;
    return c;
}

/// nb_arc(frame O X Y, r, a0, a1): the circular arc as a rational quadratic
/// NURBS (pieces of at most 90 degrees, The NURBS Book A7.1), parameter 0 .. 1
pub fn nbArc(fr: *const [3]V3, r: f64, a0: f64, a1: f64) ?*Curve {
    var sweep = a1 - a0;
    var n = cvtt(fabs(sweep) / nk_hpi - nk_tiny) +% 1;
    if (n < 1) n = 1;
    if (n > 4) n = 4;
    sweep = sweep / fl(n);
    const d = sweep;
    const sc = dsincos(d * 0.5);
    const w = sc[1];
    const tn = sc[0] / sc[1] * r;
    const un: u32 = @intCast(n);
    const c = nbNew(2, un * 2 + 1) orelse return null;
    const k = c.kn.?;
    k[0] = 0;
    k[1] = 0;
    k[2] = 0;
    var at: usize = 3;
    var i: u32 = 1;
    while (i < un) : (i += 1) {
        const x = fl(i) / fl(n);
        k[at] = x;
        k[at + 1] = x;
        at += 2;
    }
    k[at] = 1;
    k[at + 1] = 1;
    k[at + 2] = 1;
    var ang = a0;
    var pt = arcAt(fr, r, ang);
    var cur = c.cp.?;
    putW(&cur, pt[0], 1.0);
    i = 0;
    while (i < un) : (i += 1) {
        ang = ang + d;
        const p2 = arcAt(fr, r, ang);
        v3axpy(&pt[0], pt[1], tn);
        putW(&cur, pt[0], w);
        putW(&cur, p2[0], 1.0);
        pt = p2;
    }
    return c;
}
fn arcAt(fr: *const [3]V3, r: f64, a: f64) [2]V3 {
    const sc = dsincos(a);
    return .{
        lin3(&fr[0], &fr[1], sc[1] * r, &fr[2], sc[0] * r, null, 0),
        lin3(null, &fr[1], fneg(sc[0]), &fr[2], sc[1], null, 0),
    };
}
fn putW(cur: *[*]f64, p: V3, w: f64) void {
    cur.*[0] = p[0] * w;
    cur.*[1] = p[1] * w;
    cur.*[2] = p[2] * w;
    cur.*[3] = w;
    cur.* += 4;
}

/// ns_revolve(profile (NURBS: x radial, z along the axis), frame O X Y Z,
/// a0, a1): the surface of revolution as a NURBS surface (u around, v along
/// the profile), or null
pub fn nsRevolve(prof: *const Curve, fr: *const [4]V3, a0: f64, a1: f64) ?*Surface {
    const unit: [3]V3 = .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    const arc = nbArc(&unit, 1.0, a0, a1) orelse return null;
    const s = ksNew() orelse return null;
    s.typ = ST_NURBS;
    s.du = 2;
    s.dv = prof.deg;
    s.nu = arc.n;
    s.nv = prof.n;
    s.ku = arc.kn;
    s.kv = prof.kn;
    const cp = doubles(@as(usize, s.nu) * s.nv * 4) orelse return null;
    s.cp = cp;
    var i: u32 = 0;
    while (i < s.nu) : (i += 1) {
        const A = arc.cp.? + i * 4;
        const wa = A[3];
        const ax = A[0] / wa;
        const ay = A[1] / wa;
        var j: u32 = 0;
        while (j < s.nv) : (j += 1) {
            const P = prof.cp.? + j * 4;
            const wp = P[3];
            const px = P[0] / wp;
            const pz = P[2] / wp;
            const w = wp * wa;
            const q = lin3(&fr[0], &fr[1], px * ax, &fr[2], px * ay, &fr[3], pz);
            const o = cp + (i * s.nv + j) * 4;
            o[0] = q[0] * w;
            o[1] = q[1] * w;
            o[2] = q[2] * w;
            o[3] = w;
        }
    }
    return s;
}

// ---- nbcheck.s: nurbscheck(k) -> the largest error ------------------------------------
//   0  a rational quadratic arc lies on its circle (radius, plane)
//   1  knot insertion leaves the curve where it was
//   2  degree elevation leaves the curve where it was
//   3  curve derivatives against central differences (relative)
//   4  a revolved NURBS cylinder lies on the cylinder; inserting knots and
//      raising degrees in u and v leaves the surface where it was
//   5  surface derivatives Su, Sv against central differences (relative)
//   6  a NURBS torus (a revolved NURBS circle) lies on the torus
const nc_h: f64 = 1.0e-6;
const nc_ins: f64 = 0.37;
const nc_arcf: [3]V3 = .{ .{ 1, 2, 3 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
const nc_cylf: [4]V3 = .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
const nc_tubf: [3]V3 = .{ .{ 3, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 } };

var nc_err: f64 = 0;
fn upd(e: f64) void {
    nc_err = maxsd(fabs(e), nc_err);
}
fn tpar(i: u32) f64 {
    return fl(i) / 50.0;
}
fn uvpar(i: u32, j: u32) [2]f64 {
    return .{ (fl(i) + 1.0) / 9.0, (fl(j) + 1.0) / 9.0 };
}
fn fdErr(fp: V3, fm: V3, d: V3) void {
    const h2 = nc_h + nc_h;
    var e: V3 = undefined;
    for (0..3) |i| e[i] = (fp[i] - fm[i]) / h2 - d[i];
    const l = v3len(e);
    upd(l / maxsd(v3len(d), 1.0));
}

pub fn nbCheck(which: i64) f64 {
    init();
    nc_err = 0;
    const a = nbArc(&nc_arcf, 2.0, 0.3, 4.0) orelse return 1;
    switch (which) {
        0 => {
            var i: u32 = 0;
            while (i <= 50) : (i += 1) {
                const p = crvEval(a, tpar(i));
                upd(v3dist(p[0], nc_arcf[0]) - 2.0);
                upd(p[0][2] - 3.0);
            }
        },
        1, 2 => {
            var b: *Curve = undefined;
            if (which == 1) {
                b = insert(a, nc_ins, 2);
            } else {
                b = elevate(a) orelse return bad();
                b = elevate(b) orelse return bad();
            }
            var i: u32 = 0;
            while (i <= 50) : (i += 1) {
                const t = tpar(i);
                upd(v3dist(crvEval(a, t)[0], crvEval(b, t)[0]));
            }
        },
        3 => {
            var i: u32 = 0;
            while (i <= 48) : (i += 1) {
                const t = tpar(i + 1);
                const p = crvEval(a, t);
                const q = crvEval(a, t + nc_h);
                const r = crvEval(a, t - nc_h);
                fdErr(q[0], r[0], p[1]);
                fdErr(q[1], r[1], p[2]);
            }
        },
        4 => {
            const l = nbLine(.{ 1, 0, 0 }, .{ 1, 0, 2 }) orelse return bad();
            const s = nsRevolve(l, &nc_cylf, 0, nk_2pi) orelse return bad();
            cylGrid(s, null);
            var t = nsInsert(s, 0, nc_ins, 1) orelse return bad();
            t = nsInsert(t, 1, nc_ins + nc_ins, 1) orelse return bad();
            t = nsElevate(t, 0) orelse return bad();
            t = nsElevate(t, 1) orelse return bad();
            cylGrid(s, t);
        },
        5 => {
            const tube = nbArc(&nc_tubf, 1.0, 0, nk_2pi) orelse return bad();
            const s = nsRevolve(tube, &nc_cylf, 0, nk_2pi) orelse return bad();
            var i: u32 = 0;
            while (i < 7) : (i += 1) {
                var j: u32 = 0;
                while (j < 7) : (j += 1) {
                    const uv = uvpar(i, j);
                    const p = srfEval(s, uv[0], uv[1]);
                    var q = srfEval(s, uv[0] + nc_h, uv[1]);
                    var r = srfEval(s, uv[0] - nc_h, uv[1]);
                    fdErr(q[0], r[0], p[1]);
                    q = srfEval(s, uv[0], uv[1] + nc_h);
                    r = srfEval(s, uv[0], uv[1] - nc_h);
                    fdErr(q[0], r[0], p[2]);
                }
            }
        },
        6 => {
            const tube = nbArc(&nc_tubf, 1.0, 0, nk_2pi) orelse return bad();
            const s = nsRevolve(tube, &nc_cylf, 0, nk_2pi) orelse return bad();
            var i: u32 = 0;
            while (i < 9) : (i += 1) {
                var j: u32 = 0;
                while (j < 9) : (j += 1) {
                    const uv = uvpar(i, j);
                    const p = srfEval(s, uv[0], uv[1])[0];
                    var x = @sqrt(p[0] * p[0] + p[1] * p[1]) - 3.0;
                    x = x * x + p[2] * p[2];
                    upd(x - 1.0);
                }
            }
        },
        else => {},
    }
    return nc_err;
}
fn bad() f64 {
    nc_err = 1;
    return nc_err;
}
fn cylGrid(s: *const Surface, b: ?*const Surface) void {
    var i: u32 = 0;
    while (i < 9) : (i += 1) {
        var j: u32 = 0;
        while (j < 9) : (j += 1) {
            const uv = uvpar(i, j);
            const p = srfEval(s, uv[0], uv[1])[0];
            if (b) |t| {
                upd(v3dist(p, srfEval(t, uv[0], uv[1])[0]));
            } else {
                upd(@sqrt(p[0] * p[0] + p[1] * p[1]) - 1.0);
            }
        }
    }
}

test "nurbscheck: every check within the original's tolerances" {
    for (0..7) |k| {
        const e = nbCheck(@intCast(k));
        const tol: f64 = if (k == 3 or k == 5) 1e-8 else 1e-12;
        try std.testing.expect(e < tol);
    }
}

test "nurbscheck: the original's values (its 7 digits)" {
    const want = [_]f64{ 8.881784e-16, 1.334073e-15, 1.831027e-15, 1.403814e-10, 8.308148e-16, 1.06611e-10, 1.998401e-15 };
    for (want, 0..) |w, k| {
        const e = nbCheck(@intCast(k));
        try std.testing.expect(@abs(e - w) <= w * 1e-6);
    }
}
