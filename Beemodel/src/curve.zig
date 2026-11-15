// Curves (curve.s): Bezier and poly splines, swept into meshes.
//
// A curve object is a mesh object whose mesh carries a curve block (ME_CURVE,
// scene.Mesh.curve): up to 32 splines of control points (a position, two
// handles, a radius, a tilt, a handle type). The mesh is what the curve makes:
// its splines sampled (resolution: points per Bezier span) as 2-point polygons,
// or swept into a tube (a bevel radius and sides) or along a profile curve.
//
// Frames along a path are parallel transported from the world up; a closed path
// spreads the remaining twist over its length; tilt turns the frame per point.
// A profile is read in its curve's XZ plane.
//
// Geometry nodes and the L-system see curves as chains of 2-point polygons: the
// chain functions here (ch_*, cn_*) work on the module's chains (ch_ep, ch_tab,
// ch_n, ch_total), as the original's globals. Each function keeps the
// original's label in a comment. The arithmetic is the original's, lane by
// lane (dpps sums (x x + y y) + (z z + 0); fsincos and fpatan through the x87).
//
// For the other modules (results are PMesh in the caller's allocator; null is
// the original's 0):
//   geonodes:  cnLine(a, node), cnCircle(a, node), cnToMesh(a, curve, profile?,
//              node), cnResample / cnTrim / cnFillet(a, mesh, node), cnPoints
//              (points + normals); node = the 72-byte NTRE node record (its
//              inputs' values at ND_IN + 16 k + 4, its values at ND_P), or the
//              *V variants with plain values
//   procgen:   chReserve(points, chains), then fill ch_ep[ch_total] /
//              ch_tab[ch_n]; profCircle(sides, r) (free it with curve.A);
//              chSweep(a, prof, closed, caps); chToLines(a)
const std = @import("std");
const builtin = @import("builtin");
const pm = @import("pmesh.zig");

pub const V3 = [3]f32;
pub const PMesh = pm.PMesh;

/// The allocator for the chains and the scratch (tests set their own).
pub var A: std.mem.Allocator = @import("alloc.zig").A;

// ---- the block (byte for byte the original's: the CURV chunk) ----------------------------

pub const CV_MAXS = 32;
pub const CV_MAXPTS = 4000000;
pub const ST_POLY = 0;
pub const ST_BEZ = 1;
/// CV_PTS: the header and the spline table
pub const CV_PTS = 576;
pub const CP_SZ = 48;

pub const Spl = extern struct {
    typ: u32 = ST_POLY,
    cyc: u32 = 0,
    first: u32 = 0,
    n: u32 = 0,
};

/// A control point (CP_*): co, left / right handle, radius, tilt, selection
/// (1 point, 2 left handle, 4 right), handle type (0 auto, 1 aligned, 2 vector,
/// 3 free), two bytes the original never sets (kept as read).
pub const CP = extern struct {
    co: V3,
    hl: V3,
    hr: V3,
    rad: f32,
    tilt: f32,
    sel: u8 = 0,
    ht: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
};

/// The block's first 576 bytes (CV_*).
pub const Hdr = extern struct {
    refs: u32 = 1, // 0
    nspl: u32 = 0, // 4
    npts: u32 = 0, // 8
    cap: u32 = 16, // 12
    bytes: u64 = 0, // 16 (the mapping's size: written to files as it is)
    res: i32 = 12, // 24
    bevel: f32 = 0, // 28
    sides: i32 = 8, // 32
    prof: u32 = 0, // 36
    fill: u32 = 0, // 40
    act: u32 = 0, // 44
    pad: [16]u8 = @splat(0), // 48
    spl: [CV_MAXS]Spl = @splat(.{}), // 64
};

comptime {
    std.debug.assert(@sizeOf(CP) == CP_SZ);
    std.debug.assert(@sizeOf(Hdr) == CV_PTS);
}

pub const Curve = struct {
    h: Hdr,
    /// cap records, npts used
    pts: []CP,

    pub fn spl(c: *Curve, i: usize) *Spl {
        return &c.h.spl[i];
    }
    pub fn used(c: *const Curve) []CP {
        return c.pts[0..c.h.npts];
    }
};

fn mapBytes(cap: u32) u64 {
    return (@as(u64, cap) * CP_SZ + CV_PTS + 4095) & ~@as(u64, 4095);
}

/// cv_new: an empty curve (resolution 12, 8 sides) with room for `cap` points
/// (16 at least), or null.
pub fn cvNew(cap_in: u32) ?*Curve {
    const cap = @max(cap_in, 16);
    const c = A.create(Curve) catch return null;
    c.pts = A.alloc(CP, cap) catch {
        A.destroy(c);
        return null;
    };
    @memset(std.mem.sliceAsBytes(c.pts), 0);
    c.h = .{ .cap = cap, .bytes = mapBytes(cap) };
    return c;
}

/// cv_ref
pub fn cvRef(c: ?*Curve) void {
    if (c) |x| x.h.refs += 1;
}

/// cv_unref
pub fn cvUnref(c: ?*Curve) void {
    const x = c orelse return;
    x.h.refs -%= 1;
    if (x.h.refs != 0) return;
    A.free(x.pts);
    A.destroy(x);
}

/// cv_copy(curve, room for more points): a copy, or null.
pub fn cvCopy(c: *const Curve, room: u32) ?*Curve {
    const n = cvNew(c.h.npts +% room) orelse return null;
    n.h.nspl = c.h.nspl;
    n.h.npts = c.h.npts;
    // CV_RES .. CV_PTS as they are
    const src = std.mem.asBytes(&c.h);
    const dst = std.mem.asBytes(&n.h);
    @memcpy(dst[24..CV_PTS], src[24..CV_PTS]);
    @memcpy(n.pts[0..c.h.npts], c.pts[0..c.h.npts]);
    return n;
}

/// cv_spline_new(type, cyclic): its index (it becomes the one points go to), or
/// null.
pub fn cvSplineNew(c: *Curve, typ: u32, cyc: u32) ?u32 {
    const i = c.h.nspl;
    if (i >= CV_MAXS) return null;
    c.h.spl[i] = .{ .typ = typ, .cyc = cyc, .first = c.h.npts, .n = 0 };
    c.h.nspl += 1;
    c.h.act = i;
    return i;
}

/// cv_insert(spline, place in it, record): the point's index, or null.
pub fn cvInsert(c: *Curve, s: u32, place: u32, rec: CP) ?u32 {
    if (c.h.npts >= c.h.cap) return null;
    if (s >= c.h.nspl) return null;
    const sp = &c.h.spl[s];
    const at = @min(place, sp.n) + sp.first;
    sp.n += 1;
    var k = s + 1;
    while (k < c.h.nspl) : (k += 1) c.h.spl[k].first += 1;
    std.mem.copyBackwards(CP, c.pts[at + 1 .. c.h.npts + 1], c.pts[at..c.h.npts]);
    c.pts[at] = rec;
    c.h.npts += 1;
    return at;
}

/// cv_spline_of(point): its spline and its place in it, or null.
pub fn cvSplineOf(c: *const Curve, p: u32) ?[2]u32 {
    var s: u32 = 0;
    while (s < c.h.nspl) : (s += 1) {
        const d = p -% c.h.spl[s].first;
        if (d < c.h.spl[s].n) return .{ s, d };
    }
    return null;
}

/// cv_remove(point): splines left empty go too.
pub fn cvRemove(c: *Curve, p: u32) void {
    if (p >= c.h.npts) return;
    const so = cvSplineOf(c, p) orelse return;
    c.h.spl[so[0]].n -= 1;
    var k = so[0] + 1;
    while (k < c.h.nspl) : (k += 1) c.h.spl[k].first -%= 1;
    std.mem.copyForwards(CP, c.pts[p .. c.h.npts - 1], c.pts[p + 1 .. c.h.npts]);
    c.h.npts -= 1;
    cvPrune(c);
}

/// cv_prune: drop splines without points.
pub fn cvPrune(c: *Curve) void {
    var w: u32 = 0;
    var r: u32 = 0;
    while (r < c.h.nspl) : (r += 1) {
        if (c.h.spl[r].n == 0) continue;
        c.h.spl[w] = c.h.spl[r];
        w += 1;
    }
    c.h.nspl = w;
    var a = c.h.act;
    if (a >= w) {
        a = w -% 1;
        if (@as(i32, @bitCast(a)) < 0) a = 0;
    }
    c.h.act = a;
}

// ---- lane arithmetic as the original's SSE ------------------------------------------------

inline fn sub(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
inline fn add(a: V3, b: V3) V3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
inline fn scl(a: V3, s: f32) V3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
inline fn divs(a: V3, s: f32) V3 {
    return .{ a[0] / s, a[1] / s, a[2] / s };
}
/// dpps (mask 0x7f / 0x71): (x x + y y) + (z z + 0)
inline fn dot(a: V3, b: V3) f32 {
    return (a[0] * b[0] + a[1] * b[1]) + (a[2] * b[2] + 0.0);
}
/// LEN
inline fn len(a: V3) f32 {
    return @sqrt(dot(a, a));
}
/// CROSS (the shuffles give the usual products)
inline fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

// ---- the x87 unit, as the original -------------------------------------------------------

const use_x87 = builtin.cpu.arch == .x86_64;

// fld dword [rdi]; fsincos; fstp dword [rdi+4] (cos); fstp dword [rdi] (sin); ret
export const bee_x87_crv_sincos: [10]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0xfb, 0xd9, 0x5f, 0x04, 0xd9, 0x1f, 0xc3 };
// fld dword [rdi]; fld dword [rdi+4]; fpatan; fstp dword [rdi]; ret
export const bee_x87_crv_atan2f: [10]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0x47, 0x04, 0xd9, 0xf3, 0xd9, 0x1f, 0xc3 };

fn run87(code: []const u8, a: f32, b: f32) [2]f32 {
    var mm: [2]f32 = .{ a, b };
    const f: *const fn (*[2]f32) callconv(.c) void = @ptrCast(code.ptr);
    f(&mm);
    return mm;
}

/// sincos (mesh.s): sin, cos of an f32 through fsincos.
pub fn sincos(x: f32) [2]f32 {
    if (!use_x87) return .{ @sin(x), @cos(x) };
    return run87(&bee_x87_crv_sincos, x, 0);
}

/// atan2f: fpatan of two f32, rounded to f32.
pub fn atan2f(y: f32, x: f32) f32 {
    if (!use_x87) return std.math.atan2(y, x);
    return run87(&bee_x87_crv_atan2f, y, x)[0];
}

/// cvttss2si: out of range or NaN gives the integer indefinite.
pub fn cvtt(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(@trunc(x));
}

/// cvtss2si (round to nearest even).
fn cvtr(x: f32) i32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    var r = @round(x); // (half away from zero, then to even)
    if (@abs(x - @trunc(x)) == 0.5 and @mod(r, 2.0) != 0) r -= std.math.sign(x);
    return @intFromFloat(r);
}

// ---- handles and evaluation ---------------------------------------------------------------

const k39: f32 = 0.39;
const third: f32 = 0.33333334;
const tiny: f32 = 1.0e-12;
const eps: f32 = 1.0e-6;

/// cv_handles: auto and vector handles from the neighbours (auto: along prev ->
/// next, 0.39 of each side's chord; vector: a third of the way to each
/// neighbour).
pub fn cvHandles(c: *Curve) void {
    var s: u32 = 0;
    while (s < c.h.nspl) : (s += 1) {
        const sp = c.h.spl[s];
        if (sp.typ != ST_BEZ) continue;
        const n = sp.n;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const p = &c.pts[sp.first + i];
            if (p.ht == 1 or p.ht == 3) continue;
            var prev: ?*const CP = null;
            var next: ?*const CP = null;
            if (i != 0) {
                prev = &c.pts[sp.first + i - 1];
            } else if (sp.cyc != 0 and n >= 2) {
                prev = &c.pts[sp.first + n - 1];
            }
            if (i + 1 < n) {
                next = &c.pts[sp.first + i + 1];
            } else if (sp.cyc != 0 and n >= 2) {
                next = &c.pts[sp.first];
            }
            const co = p.co;
            if (prev) |pv| {
                const a = sub(pv.co, co);
                if (next) |nx| {
                    const b = sub(nx.co, co);
                    if (p.ht != 2) {
                        var d = sub(b, a);
                        const l = len(d);
                        if (l > tiny) {
                            d = divs(d, l);
                            p.hl = sub(co, scl(d, len(a) * k39));
                            p.hr = add(co, scl(d, len(b) * k39));
                            continue;
                        }
                    }
                    p.hl = add(scl(a, third), co);
                    p.hr = add(scl(b, third), co);
                } else {
                    const t = scl(a, third);
                    p.hl = add(co, t);
                    p.hr = sub(co, t);
                }
            } else if (next) |nx| {
                const t = scl(sub(nx.co, co), third);
                p.hr = add(co, t);
                p.hl = sub(co, t);
            } else {
                const t: V3 = .{ third, 0, 0 };
                p.hr = add(co, t);
                p.hl = sub(co, t);
            }
        }
    }
}

/// res_clamp: 1..64
fn resClamp(r: i32) u32 {
    return @intCast(std.math.clamp(r, 1, 64));
}

/// cv_eval_count(spline): its evaluated points.
pub fn cvEvalCount(c: *const Curve, s: u32) u32 {
    const sp = c.h.spl[s];
    if (sp.typ != ST_BEZ or sp.n < 2) return sp.n;
    const r = resClamp(c.h.res);
    if (sp.cyc != 0) return sp.n *% r;
    return (sp.n - 1) *% r +% 1;
}

/// An evaluated point: position, radius, tilt (EP_SZ 20).
pub const EP = extern struct {
    p: V3,
    rad: f32,
    tilt: f32,
};
/// A chain: its first point, how many, closed (CH_SZ 12).
pub const Chain = extern struct {
    first: u32,
    n: u32,
    cyc: u32,
};

/// cv_eval(spline, out): the count written. Poly splines: their points;
/// Bezier: res samples a span (B(t) of co, right handle, next left handle,
/// next co), radius and tilt linear.
pub fn cvEval(c: *const Curve, s: u32, out: []EP) u32 {
    const sp = c.h.spl[s];
    const n = sp.n;
    var w: u32 = 0;
    if (sp.typ == ST_BEZ and n >= 2) {
        const r = resClamp(c.h.res);
        const inv = 1.0 / @as(f32, @floatFromInt(r));
        const spans = if (sp.cyc != 0) n else n - 1;
        var k: u32 = 0;
        while (k < spans) : (k += 1) {
            const P = &c.pts[sp.first + k];
            const Q = &c.pts[sp.first + (if (k + 1 < n) k + 1 else 0)];
            var j: u32 = 0;
            while (j < r) : (j += 1) {
                const t = @as(f32, @floatFromInt(j)) * inv;
                const u = 1.0 - t;
                const b0 = u * u * u;
                const b1 = u * u * t * 3.0;
                const b2 = u * t * t * 3.0;
                const b3 = t * t * t;
                const p = add(add(add(scl(P.co, b0), scl(P.hr, b1)), scl(Q.hl, b2)), scl(Q.co, b3));
                out[w] = .{ .p = p, .rad = P.rad * u + Q.rad * t, .tilt = P.tilt * u + Q.tilt * t };
                w += 1;
            }
        }
        if (sp.cyc == 0) {
            const L = &c.pts[sp.first + n - 1];
            out[w] = .{ .p = L.co, .rad = L.rad, .tilt = L.tilt };
            w += 1;
        }
        return w;
    }
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const P = &c.pts[sp.first + k];
        out[w] = .{ .p = P.co, .rad = P.rad, .tilt = P.tilt };
        w += 1;
    }
    return w;
}

// ---- chains -------------------------------------------------------------------------------

/// ch_ep, ch_tab, ch_n, ch_total: the chains (the evaluated splines, a mesh's
/// 2-point polygons, or what a caller filled: chReserve).
pub var ch_ep: []EP = &.{};
pub var ch_tab: []Chain = &.{};
pub var ch_n: u32 = 0;
pub var ch_total: u32 = 0;
/// cn_*: a result being made (ch_alloc, cn_begin, cn_put, ch_take)
var cn_ep: []EP = &.{};
var cn_tab: []Chain = &.{};
var cn_n: u32 = 0;
var cn_total: u32 = 0;

/// The module's two pairs of arrays (the original's frame arena): the chains
/// and a result being made never share one.
var own_ep: [2][]EP = .{ &.{}, &.{} };
var own_tab: [2][]Chain = .{ &.{}, &.{} };

fn grow(comptime T: type, s: *[]T, n: usize) bool {
    if (s.len >= n and s.len > 0) return true;
    const want = @max(n, 16);
    const x = A.alloc(T, want) catch return false;
    if (s.len > 0) A.free(s.*);
    s.* = x;
    return true;
}

/// Arrays of the module's for `pts` points and `chains` chains, not the ones
/// `busy` uses: their index, or null (no memory).
fn ownPair(pts: usize, chains: usize, busy: []const EP) ?usize {
    const k: usize = if (own_ep[0].len > 0 and own_ep[0].ptr == busy.ptr) 1 else 0;
    if (!grow(EP, &own_ep[k], pts) or !grow(Chain, &own_tab[k], chains)) return null;
    return k;
}

/// The chains made empty, with room for `pts` points and `chains` chains of the
/// module's (procgen's L-system fills them as the original's ls_build): false
/// when there is no memory.
pub fn chReserve(pts: usize, chains: usize) bool {
    ch_n = 0;
    ch_total = 0;
    const k = ownPair(pts, chains, cn_ep) orelse {
        ch_ep = &.{};
        ch_tab = &.{};
        return false;
    };
    ch_ep = own_ep[k];
    ch_tab = own_tab[k];
    return true;
}

/// The module's arrays given back (tests: no leaks).
pub fn chFree() void {
    for (0..2) |k| {
        if (own_ep[k].len > 0) A.free(own_ep[k]);
        if (own_tab[k].len > 0) A.free(own_tab[k]);
        own_ep[k] = &.{};
        own_tab[k] = &.{};
    }
    ch_ep = &.{};
    ch_tab = &.{};
    cn_ep = &.{};
    cn_tab = &.{};
    ch_n = 0;
    ch_total = 0;
    cn_n = 0;
    cn_total = 0;
}

/// ch_from_curve: the curve's splines evaluated (its auto handles set first):
/// false when there is no memory (no chains).
pub fn chFromCurve(c: *Curve) bool {
    cvHandles(c);
    var total: u64 = 0;
    var s: u32 = 0;
    while (s < c.h.nspl) : (s += 1) total += cvEvalCount(c, s);
    if (total > CV_MAXPTS or !chReserve(@intCast(total), CV_MAXS)) {
        ch_n = 0;
        ch_total = 0;
        return false;
    }
    var w: u32 = 0;
    s = 0;
    while (s < c.h.nspl) : (s += 1) {
        const n = cvEval(c, s, ch_ep[w..]);
        if (n == 0) continue;
        // closed with 3 or more points
        const cyc: u32 = if (n >= 3 and c.h.spl[s].cyc != 0) 1 else 0;
        ch_tab[ch_n] = .{ .first = w, .n = n, .cyc = cyc };
        w += n;
        ch_n += 1;
    }
    ch_total = w;
    return true;
}

/// ch_from_mesh: consecutive 2-point polygons that share an end make one
/// chain; one that comes back to its first point closes it. Radius 1, tilt 0.
pub fn chFromMesh(me: PMesh) bool {
    ch_n = 0;
    ch_total = 0;
    const np = me.faces();
    if (!chReserve(np * 2, np)) return false;
    var last: u32 = 0xffffffff; // the open chain's last vertex
    var first: u32 = 0xffffffff; //  and first
    var p: usize = 0;
    while (p < np) : (p += 1) {
        const s = me.poff[p];
        if (me.poff[p + 1] -% s != 2) continue;
        const a = me.loops[s];
        const b = me.loops[s + 1];
        if (a == last) {
            if (b == first and ch_tab[ch_n - 1].n >= 3) { // back to the start: closed
                ch_tab[ch_n - 1].cyc = 1;
                last = 0xffffffff;
                continue;
            }
            cmPut(me, b);
            last = b;
            continue;
        }
        ch_tab[ch_n] = .{ .first = ch_total, .n = 0, .cyc = 0 };
        ch_n += 1;
        cmPut(me, a);
        cmPut(me, b);
        first = a;
        last = b;
    }
    return true;
}

/// .Lcm_put: a vertex onto the last chain (one past the vertices: vertex 0).
fn cmPut(me: PMesh, v0: u32) void {
    const v = if (v0 < me.verts.len) v0 else 0;
    // (a mesh without vertices: the origin; the original reads past it)
    const p: V3 = if (me.verts.len > 0) me.verts[v] else .{ 0, 0, 0 };
    ch_ep[ch_total] = .{ .p = p, .rad = 1.0, .tilt = 0 };
    ch_total += 1;
    ch_tab[ch_n - 1].n += 1;
}

/// A mesh being made (mesh_new, mesh_add_vert, mesh_add_poly).
const Mk = struct {
    a: std.mem.Allocator,
    v: []V3,
    o: []u32,
    l: []u32,
    nv: u32 = 0,
    np: u32 = 0,
    nl: u32 = 0,

    fn init(a: std.mem.Allocator, nv: usize, nl: usize, np: usize) ?Mk {
        const v = a.alloc(V3, nv) catch return null;
        const o = a.alloc(u32, np + 1) catch {
            a.free(v);
            return null;
        };
        const l = a.alloc(u32, nl) catch {
            a.free(v);
            a.free(o);
            return null;
        };
        o[0] = 0;
        return .{ .a = a, .v = v, .o = o, .l = l };
    }
    fn vert(k: *Mk, p: V3) void {
        k.v[k.nv] = p;
        k.nv += 1;
    }
    fn poly(k: *Mk, idx: []const u32) void {
        @memcpy(k.l[k.nl..][0..idx.len], idx);
        k.nl += @intCast(idx.len);
        k.np += 1;
        k.o[k.np] = k.nl;
    }
    /// mesh_finish: the arrays as long as what was put in.
    fn finish(k: *Mk) ?PMesh {
        // (the counts are exact: nothing to give back; otherwise the arrays shrink)
        if (k.nv != k.v.len or k.np + 1 != k.o.len or k.nl != k.l.len) {
            k.v = k.a.realloc(k.v, k.nv) catch return k.fail();
            k.o = k.a.realloc(k.o, k.np + 1) catch return k.fail();
            k.l = k.a.realloc(k.l, k.nl) catch return k.fail();
        }
        return .{ .verts = k.v, .poff = k.o, .loops = k.l };
    }
    fn fail(k: *Mk) ?PMesh {
        k.free();
        return null;
    }
    fn free(k: *Mk) void {
        k.a.free(k.v);
        k.a.free(k.o);
        k.a.free(k.l);
    }
};

/// ch_to_lines: the chains as 2-point polygons (null: no memory).
pub fn chToLines(a: std.mem.Allocator) ?PMesh {
    var segs: u32 = 0;
    for (ch_tab[0..ch_n]) |ch| {
        if (ch.n == 0) continue;
        segs +%= ch.n - 1 +% ch.cyc;
    }
    var k = Mk.init(a, ch_total, @as(usize, segs) * 2, segs) orelse return null;
    for (ch_ep[0..ch_total]) |e| k.vert(e.p);
    for (ch_tab[0..ch_n]) |ch| {
        var j: u32 = 0;
        while (true) : (j += 1) {
            var b: u32 = j + 1;
            if (b >= ch.n) {
                if (ch.cyc == 0 or j >= ch.n) break; // the closing segment
                b = 0;
            }
            k.poly(&.{ ch.first + j, ch.first + b });
        }
    }
    return k.finish();
}

/// One frame along a path (T, N, B).
const Frame = struct { t: V3, n: V3, b: V3 };

/// .Lfr_up: the up axis across T (Z when T is along it).
fn frUp(t: V3) V3 {
    var u: V3 = .{ 0, 1, 0 };
    u = sub(u, scl(t, dot(u, t)));
    var l = len(u);
    if (!(l > eps)) {
        u = .{ 0, 0, 1 };
        u = sub(u, scl(t, dot(u, t)));
        l = len(u);
    }
    return divs(u, l);
}

/// ch_frames(points, closed, out): T along the path; N the world up carried
/// along (parallel transport), the twist of a closed path spread over it,
/// turned by the tilt; B = T x N.
fn chFrames(ep: []const EP, closed: bool, fr: []Frame) void {
    const n: u32 = @intCast(ep.len);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ia: u32 = if (i != 0) i - 1 else if (closed) n - 1 else 0;
        const ib: u32 = if (i + 1 < n) i + 1 else if (closed) 0 else n - 1;
        var t = sub(ep[ib].p, ep[ia].p);
        const l = len(t);
        if (l > tiny) {
            t = divs(t, l);
        } else {
            t = if (i == 0) .{ 1, 0, 0 } else fr[i - 1].t; // no length: the previous one
        }
        fr[i].t = t;
    }
    if (n == 0) return;
    fr[0].n = frUp(fr[0].t);
    i = 1;
    while (i < n) : (i += 1) {
        const t = fr[i].t;
        var v = fr[i - 1].n;
        v = sub(v, scl(t, dot(v, t)));
        const l = len(v);
        fr[i].n = if (l > eps) divs(v, l) else frUp(t);
    }
    var twist: f32 = 0;
    if (closed and n >= 3) {
        const t0 = fr[0].t;
        var v = fr[n - 1].n; // the last N, carried to T0
        v = sub(v, scl(t0, dot(v, t0)));
        const l = len(v);
        if (l > eps) {
            v = divs(v, l);
            const n0 = fr[0].n;
            const sn = dot(cross(v, n0), t0);
            const cs = dot(v, n0);
            twist = atan2f(sn, cs);
        }
    }
    const per = twist / @as(f32, @floatFromInt(n)); // twist a point
    i = 0;
    while (i < n) : (i += 1) {
        const ang = @as(f32, @floatFromInt(i)) * per + ep[i].tilt;
        const f = &fr[i];
        if (ang != 0 and !std.math.isNan(ang)) {
            const sc = sincos(ang); // N = N cos + (T x N) sin
            f.n = add(scl(f.n, sc[1]), scl(cross(f.t, f.n), sc[0]));
        }
        f.b = cross(f.t, f.n);
    }
}

/// ch_sweep(profile (x, z pairs), closed, caps): the chains swept into a mesh
/// (rings of the profile, scaled by the radius, quads between them; caps on
/// open paths of a closed profile), or null. Fewer than 2 profile points: the
/// lines.
pub fn chSweep(a: std.mem.Allocator, prof: []const [2]f32, closed_in: u32, caps_in: u32) ?PMesh {
    if (prof.len < 2) return chToLines(a);
    const m: u32 = @intCast(prof.len);
    const pclosed = closed_in;
    const caps: u32 = if (m >= 3 and pclosed != 0) caps_in else 0;
    var nv: u64 = 0;
    var nl: u64 = 0;
    var np: u64 = 0;
    for (ch_tab[0..ch_n]) |ch| {
        if (ch.n < 2) continue;
        nv += @as(u64, ch.n) * m;
        const q = @as(u64, ch.n - 1 +% ch.cyc) * (m - 1 +% pclosed);
        np += q;
        nl += q * 4;
        if (ch.cyc == 0 and caps != 0) {
            np += 2;
            nl += @as(u64, m) * 2;
        }
    }
    if (nv > 50000000) return null;
    var k = Mk.init(a, nv, nl, np) orelse return null;
    const cap = A.alloc(u32, m) catch {
        k.free();
        return null;
    };
    defer A.free(cap);
    // (one block of frames for the longest chain: an L-system's tubes are
    // thousands of short chains, and a block each cost more than the sweep)
    var maxn: u32 = 0;
    for (ch_tab[0..ch_n]) |ch| maxn = @max(maxn, ch.n);
    const frall = A.alloc(Frame, maxn) catch {
        k.free();
        return null;
    };
    defer A.free(frall);
    for (ch_tab[0..ch_n]) |ch| {
        if (ch.n < 2) continue;
        const fr = frall[0..ch.n];
        const ep = ch_ep[ch.first..][0..ch.n];
        chFrames(ep, ch.cyc != 0, fr);
        const base = k.nv;
        for (ep, fr) |e, f| {
            for (prof) |pz| { // x -> B, z -> N, times the radius
                const v = add(add(scl(f.b, pz[0] * e.rad), scl(f.n, pz[1] * e.rad)), e.p);
                k.vert(v);
            }
        }
        var i: u32 = 0;
        while (true) : (i += 1) {
            var ib = i + 1;
            if (ib >= ch.n) {
                if (ch.cyc == 0 or i >= ch.n) break;
                ib = 0;
            }
            var j: u32 = 0;
            while (true) : (j += 1) {
                var j2 = j + 1;
                if (j2 >= m) {
                    if (pclosed == 0 or j >= m) break;
                    j2 = 0;
                }
                const r0 = i * m + base;
                const r1 = ib * m + base;
                k.poly(&.{ r0 + j, r1 + j, r1 + j2, r0 + j2 });
            }
        }
        if (ch.cyc == 0 and caps != 0) {
            for (cap, 0..) |*x, c| x.* = base + @as(u32, @intCast(c)); // the start: ring 0, ascending
            k.poly(cap);
            var d = (ch.n - 1) * m + base + m; // the end: the last ring, descending
            for (cap) |*x| {
                d -= 1;
                x.* = d;
            }
            k.poly(cap);
        }
    }
    return k.finish();
}

/// prof_circle(sides, radius): (x, z) pairs, closed; sides clamped to 3..256.
/// Null: no memory. The caller frees it (A).
pub fn profCircle(sides_in: i32, radius: f32) ?[][2]f32 {
    const n: u32 = @intCast(std.math.clamp(sides_in, 3, 256));
    const out = A.alloc([2]f32, n) catch return null;
    const nf: f32 = @floatFromInt(n);
    for (out, 0..) |*o, i| {
        const ang = @as(f32, @floatFromInt(i)) * 6.2831853 / nf;
        const sc = sincos(ang);
        o.* = .{ sc[1] * radius, sc[0] * radius };
    }
    return out;
}

/// prof_chain0: the first chain as (x, z) pairs and whether it is closed
/// (empty: no chains or no memory). The caller frees it (A).
fn profChain0() struct { p: [][2]f32, closed: u32 } {
    if (ch_n == 0) return .{ .p = &.{}, .closed = 0 };
    const ch = ch_tab[0];
    const out = A.alloc([2]f32, ch.n) catch return .{ .p = &.{}, .closed = 0 };
    for (out, ch_ep[ch.first..][0..ch.n]) |*o, e| o.* = .{ e.p[0], e.p[2] };
    return .{ .p = out, .closed = ch.cyc };
}

fn freeProf(p: [][2]f32) void {
    if (p.len > 0) A.free(p);
}

// ---- chains: length, points along, results ----------------------------------------------

/// ch_len(chain): its length (the closing segment included).
pub fn chLen(c: u32) f32 {
    const ch = ch_tab[c];
    const p = ch_ep[ch.first..][0..ch.n];
    var s: f32 = 0;
    var i: u32 = 0;
    while (true) : (i += 1) {
        var b = i + 1;
        if (b >= ch.n) {
            if (ch.cyc == 0 or i >= ch.n) break;
            b = 0;
        }
        s += len(sub(p[b].p, p[i].p));
    }
    return s;
}

/// ch_at(chain, distance): the point there (clamped to its ends), its radius.
pub fn chAt(c: u32, d: f32) struct { p: V3, r: f32 } {
    const ch = ch_tab[c];
    const p = ch_ep[ch.first..];
    // (no points: the original reads what lies there; here the origin)
    if (ch.n == 0) return .{ .p = .{ 0, 0, 0 }, .r = 0 };
    if (ch.n <= 1) return .{ .p = p[0].p, .r = p[0].rad };
    var s0: f32 = 0; // where the segment starts
    var i: u32 = 0;
    while (true) : (i += 1) {
        var b = i + 1;
        if (b >= ch.n) {
            if (ch.cyc == 0) return .{ .p = p[ch.n - 1].p, .r = p[ch.n - 1].rad };
            if (i >= ch.n) return .{ .p = p[0].p, .r = p[0].rad };
            b = 0;
        }
        const dv = sub(p[b].p, p[i].p);
        const l = len(dv);
        const s1 = s0 + l;
        if (s1 >= d) { // in this one (comiss; jb: unordered goes on)
            var f = maxss(d - s0, 0);
            f = if (l > tiny) f / l else 0;
            f = minss(f, 1.0);
            const r = (p[b].rad - p[i].rad) * f + p[i].rad;
            return .{ .p = add(scl(dv, f), p[i].p), .r = r };
        }
        s0 = s1;
    }
}

/// maxss / minss: the second operand when unordered.
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

/// ch_alloc(points, chains): arrays for a result, false when out of memory.
fn chAlloc(pts: u64, chains: u32) bool {
    if (pts * 20 + 16 > 0x40000000) return false;
    const k = ownPair(@intCast(pts), chains, ch_ep) orelse return false;
    cn_ep = own_ep[k];
    cn_tab = own_tab[k];
    cn_n = 0;
    cn_total = 0;
    return true;
}

/// cn_begin(closed): a new result chain.
fn cnBegin(closed: u32) void {
    cn_tab[cn_n] = .{ .first = cn_total, .n = 0, .cyc = closed };
    cn_n += 1;
}

/// cn_put(position, radius): a point onto it.
fn cnPut(p: V3, r: f32) void {
    cn_ep[cn_total] = .{ .p = p, .rad = r, .tilt = 0 };
    cn_total += 1;
    cn_tab[cn_n - 1].n += 1;
}

/// ch_take: the result becomes the chains.
fn chTake() void {
    ch_ep = cn_ep;
    ch_tab = cn_tab;
    ch_n = cn_n;
    ch_total = cn_total;
}

// ---- curve nodes (geonodes.s): each returns a new mesh, or null ----------------------------

/// The node record's offsets (ntree.zig): its inputs' own values at ND_IN + 16
/// k + 4, its values at ND_P.
const ND_IN = 4;
const ND_P = 52;

fn ndF(node: []const u8, o: usize) f32 {
    return @bitCast(std.mem.readInt(u32, node[o..][0..4], .little));
}

/// cn_line(node): Start to End (its inputs' values).
pub fn cnLine(a: std.mem.Allocator, node: []const u8) ?PMesh {
    return cnLineV(a, .{ ndF(node, ND_IN + 4), ndF(node, ND_IN + 8), ndF(node, ND_IN + 12) }, .{ ndF(node, ND_IN + 20), ndF(node, ND_IN + 24), ndF(node, ND_IN + 28) });
}

pub fn cnLineV(a: std.mem.Allocator, p0: V3, p1: V3) ?PMesh {
    var k = Mk.init(a, 2, 2, 1) orelse return null;
    k.vert(p0);
    k.vert(p1);
    k.poly(&.{ 0, 1 });
    return k.finish();
}

/// cn_circle(node): resolution, radius: a closed chain in the XZ plane.
pub fn cnCircle(a: std.mem.Allocator, node: []const u8) ?PMesh {
    return cnCircleV(a, ndF(node, ND_P), ndF(node, ND_P + 4));
}

pub fn cnCircleV(a: std.mem.Allocator, res: f32, radius: f32) ?PMesh {
    const pc = profCircle(cvtt(res), radius) orelse return null;
    defer A.free(pc);
    if (!chAlloc(pc.len, 1)) return null;
    cnBegin(1);
    for (pc) |q| cnPut(.{ q[0], 0, q[1] }, 1.0);
    chTake();
    return chToLines(a);
}

/// cn_to_mesh(curve mesh, profile mesh or null, node): radius, sides, fill
/// caps; no profile and no radius: the curve as it is.
pub fn cnToMesh(a: std.mem.Allocator, curve: PMesh, profile: ?PMesh, node: []const u8) ?PMesh {
    return cnToMeshV(a, curve, profile, ndF(node, ND_P), ndF(node, ND_P + 4), ndF(node, ND_P + 8));
}

pub fn cnToMeshV(a: std.mem.Allocator, curve: PMesh, profile: ?PMesh, radius: f32, sides: f32, fill: f32) ?PMesh {
    var prof: [][2]f32 = &.{};
    var closed: u32 = 0;
    // (the profile's own points, freed once whatever prof becomes after)
    var chain: [][2]f32 = &.{};
    defer freeProf(chain);
    if (profile) |pf| {
        if (chFromMesh(pf)) {
            const r = profChain0();
            chain = r.p;
            prof = r.p;
            closed = r.closed;
        }
    }
    var circ: ?[][2]f32 = null;
    defer if (circ) |cc| A.free(cc);
    if (prof.len < 2 and radius > 0) {
        circ = profCircle(cvtt(sides), radius);
        if (circ) |cc| {
            prof = cc;
            closed = 1;
        } else {
            prof = &.{};
            closed = 0;
        }
    }
    if (!chFromMesh(curve)) return null;
    return chSweep(a, prof, closed, @bitCast(cvtt(fill)));
}

/// cn_resample(mesh, node): count, or length between points.
pub fn cnResample(a: std.mem.Allocator, me: PMesh, node: []const u8) ?PMesh {
    if (!chFromMesh(me)) return null;
    chResample(cvtt(ndF(node, ND_P)), ndF(node, ND_P + 4));
    return chToLines(a);
}

/// cn_trim(mesh, node): start, end (factors).
pub fn cnTrim(a: std.mem.Allocator, me: PMesh, node: []const u8) ?PMesh {
    if (!chFromMesh(me)) return null;
    chTrim(ndF(node, ND_P), ndF(node, ND_P + 4));
    return chToLines(a);
}

/// cn_fillet(mesh, node): radius, segments a corner.
pub fn cnFillet(a: std.mem.Allocator, me: PMesh, node: []const u8) ?PMesh {
    if (!chFromMesh(me)) return null;
    chFillet(ndF(node, ND_P), cvtt(ndF(node, ND_P + 4)));
    return chToLines(a);
}

/// A mesh of points with point normals (ch_points).
pub const Points = struct {
    verts: []V3,
    nrm: []V3,
    pub fn deinit(p: Points, a: std.mem.Allocator) void {
        a.free(p.verts);
        a.free(p.nrm);
    }
};

/// cn_points(mesh, node): count a chain (0: its points as they are).
pub fn cnPoints(a: std.mem.Allocator, me: PMesh, node: []const u8) ?Points {
    if (!chFromMesh(me)) return null;
    chResample(cvtt(ndF(node, ND_P)), 0);
    return chPoints(a);
}

/// ch_resample(count a chain, length): the chains as evenly spaced points: a
/// count, or as many as the length fits (neither: unchanged).
pub fn chResample(count: i32, length: f32) void {
    if (!(count > 0) and !(length > 0)) return;
    var total: u32 = 0;
    var c: u32 = 0;
    while (c < ch_n) : (c += 1) {
        total +%= @bitCast(rsCount(c, count, length));
        if (total > 50000000) return;
    }
    if (!chAlloc(total, ch_n)) return;
    c = 0;
    while (c < ch_n) : (c += 1) {
        const nn: u32 = @bitCast(rsCount(c, count, length));
        const ch = ch_tab[c];
        cnBegin(if (ch.n >= 2) ch.cyc else 0);
        const l = chLen(c);
        // the step: L / (n - 1), closed L / n
        var d: i32 = @as(i32, @bitCast(nn)) -% 1;
        if (ch.cyc != 0 and ch.n >= 2) d = @bitCast(nn);
        if (!(d > 0)) d = 1;
        const step = l / @as(f32, @floatFromInt(d));
        var i: u32 = 0;
        while (i < nn) : (i += 1) {
            const at = chAt(c, @as(f32, @floatFromInt(i)) * step);
            cnPut(at.p, at.r);
        }
    }
    chTake();
}

/// .Lrs_count: a chain's new count.
fn rsCount(c: u32, count: i32, length: f32) i32 {
    const ch = ch_tab[c];
    if (ch.n < 2) return @bitCast(ch.n);
    var n = count;
    if (!(n > 0)) {
        const q = chLen(c) / length;
        n = if (ch.cyc == 0) cvtt(q) +% 1 else cvtr(q);
    }
    if (n > 1000000) n = 1000000;
    const lo: i32 = if (ch.cyc != 0) 3 else 2;
    if (n < lo) n = lo;
    return n;
}

/// ch_trim(start, end: factors of each chain's length): open chains of the
/// part between.
pub fn chTrim(s0: f32, s1: f32) void {
    const a0 = minss(maxss(s0, 0), 1.0);
    var a1 = minss(maxss(s1, 0), 1.0);
    a1 = maxss(a1, a0);
    if (!chAlloc(@as(u64, ch_total) + @as(u64, ch_n) * 4, ch_n)) return;
    var c: u32 = 0;
    while (c < ch_n) : (c += 1) {
        const l = chLen(c);
        const sa = l * a0;
        const sb = l * a1;
        cnBegin(0);
        const pa = chAt(c, sa);
        cnPut(pa.p, pa.r);
        const ch = ch_tab[c];
        const p = ch_ep[ch.first..];
        var s: f32 = 0; // s at the segment's end
        var i: u32 = 0;
        while (true) {
            var b = i + 1;
            if (b >= ch.n) {
                if (ch.cyc == 0 or i >= ch.n) break;
                b = 0;
            }
            s += len(sub(p[b].p, p[i].p));
            if (s > sa) {
                if (s >= sb) break;
                cnPut(p[b].p, p[b].rad);
            }
            i += 1;
            if (i >= ch.n) break;
        }
        const pb = chAt(c, sb);
        cnPut(pb.p, pb.r);
    }
    chTake();
}

/// ch_fillet(radius, segments a corner): corners rounded, arcs tangent to both
/// legs (at most half of each leg used).
pub fn chFillet(radius: f32, segs_in: i32) void {
    const segs: u32 = @intCast(std.math.clamp(segs_in, 1, 64));
    if (!chAlloc(@as(u64, segs + 1) * ch_total, ch_n)) return;
    var c: u32 = 0;
    while (c < ch_n) : (c += 1) {
        const ch = ch_tab[c];
        const P = ch_ep[ch.first..][0..ch.n];
        cnBegin(ch.cyc);
        for (P, 0..) |*p1e, ii| {
            const i: u32 = @intCast(ii);
            if (!filletCorner(P, i, ch.cyc != 0, radius, segs)) cnPut(p1e.p, p1e.rad);
        }
    }
    chTake();
}

/// One corner of ch_fillet: false keeps the point as it is.
fn filletCorner(P: []const EP, i: u32, cyc: bool, radius: f32, segs: u32) bool {
    const n: u32 = @intCast(P.len);
    if (n < 3) return false;
    if (!cyc and (i == 0 or i + 1 >= n)) return false;
    const p0 = P[if (i != 0) i - 1 else n - 1].p;
    const p2 = P[if (i + 1 < n) i + 1 else 0].p;
    const p1 = P[i].p;
    var u = sub(p0, p1);
    var v = sub(p2, p1);
    const lu = len(u);
    const lv = len(v);
    if (!(lu > eps) or !(lv > eps)) return false;
    u = divs(u, lu);
    v = divs(v, lv);
    const most = minss(lu, lv) * 0.5; // the most a leg gives
    const cs = dot(u, v);
    const sn = len(cross(u, v));
    if (!(sn > eps)) return false; // straight on (or back): as it is
    const opc = 1.0 + cs;
    if (!(opc > eps)) return false;
    const tn = sn / opc; // tan(phi / 2)
    const d = minss(radius / tn, most);
    const A_ = add(scl(u, d), p1);
    const B_ = add(scl(v, d), p1);
    var bis = add(u, v);
    const lb = len(bis);
    if (!(lb > eps)) return false;
    bis = divs(bis, lb);
    const ch2 = @sqrt(opc * 0.5); // cos(phi / 2)
    const C = add(scl(bis, d / ch2), p1);
    const ca = sub(A_, C);
    const cb = sub(B_, C);
    const alpha = atan2f(sn, 0 - cs); // alpha = pi - phi
    const sa = sincos(alpha)[0];
    if (!(sa > eps)) return false;
    const r = P[i].rad;
    var k: u32 = 0;
    const sf: f32 = @floatFromInt(segs);
    while (k <= segs) : (k += 1) {
        const t = @as(f32, @floatFromInt(k)) / sf;
        const w0 = sincos((1.0 - t) * alpha)[0] / sa;
        const w1 = sincos(t * alpha)[0] / sa;
        const q = add(add(scl(cb, w1), scl(ca, w0)), C);
        cnPut(q, r);
    }
    return true;
}

/// ch_points: the chains' points with point normals (the frames' N), or null.
pub fn chPoints(a: std.mem.Allocator) ?Points {
    const v = a.alloc(V3, ch_total) catch return null;
    const nr = a.alloc(V3, ch_total) catch {
        a.free(v);
        return null;
    };
    var w: usize = 0;
    for (ch_tab[0..ch_n]) |ch| {
        if (ch.n == 0) continue;
        const fr = A.alloc(Frame, ch.n) catch {
            a.free(v);
            a.free(nr);
            return null;
        };
        defer A.free(fr);
        const ep = ch_ep[ch.first..][0..ch.n];
        chFrames(ep, ch.cyc != 0, fr);
        for (ep, fr) |e, f| {
            nr[w] = f.n;
            v[w] = e.p;
            w += 1;
        }
    }
    return .{ .verts = v[0..w], .nrm = nr[0..w] };
}

// ---- curve objects -----------------------------------------------------------------------

const scene = @import("scene.zig");
const app = @import("app.zig");
const nt = @import("ntree.zig");

/// cv_of(object): its curve, or null.
pub fn cvOf(i: ?usize) ?*Curve {
    const k = i orelse return null;
    if (k >= scene.count) return null;
    const o = &scene.objects[k];
    if (!o.kind.isMesh()) return null;
    const mi = o.mesh orelse return null;
    const me = &(scene.meshes[mi] orelse return null);
    return me.curve;
}

/// A mesh slot of what was made (no vertices: an empty one), or null.
fn slotOf(pmesh: PMesh) ?u16 {
    defer pmesh.deinit(A);
    if (pmesh.verts.len == 0) return scene.addEmptyMesh();
    return scene.addMesh(pmesh.verts, pmesh.poff, pmesh.loops);
}

/// cv_mesh(curve): the mesh slot it makes (carrying it), or null.
pub fn cvMesh(c: *Curve) ?u16 {
    var prof: [][2]f32 = &.{};
    var closed: u32 = 0;
    var own = false;
    defer if (own and prof.len > 0) A.free(prof);
    if (c.h.prof != 0) {
        if (cvOf(scene.findUid(c.h.prof))) |pc| {
            if (pc != c and chFromCurve(pc)) {
                const r = profChain0();
                prof = r.p;
                closed = r.closed;
                own = true;
            }
        }
    }
    if (prof.len < 2 and c.h.bevel > 0) {
        if (own and prof.len > 0) A.free(prof);
        own = false;
        prof = &.{};
        closed = 0;
        if (profCircle(c.h.sides, c.h.bevel)) |pc| {
            prof = pc;
            closed = 1;
            own = true;
        }
    }
    if (!chFromCurve(c)) return null;
    const pmesh = chSweep(A, prof, closed, c.h.fill) orelse return null;
    const mi = slotOf(pmesh) orelse return null;
    scene.meshes[mi].?.curve = c;
    c.h.refs += 1;
    return mi;
}

/// cv_guard: profile dependents follow one level.
var cv_guard = false;

/// cv_rebuild(object): its mesh made again from its curve; curves that use it
/// as their profile follow.
pub fn cvRebuild(i: usize) void {
    const c = cvOf(i) orelse return;
    const mi = cvMesh(c) orelse return;
    scene.objects[i].mesh = mi;
    app.dirty = true;
    if (cv_guard) return;
    cv_guard = true;
    defer cv_guard = false;
    const uid = scene.objects[i].uid;
    for (0..scene.count) |k| {
        if (k == i) continue;
        const pc = cvOf(k) orelse continue;
        if (pc.h.prof == uid) cvRebuild(k);
    }
}

/// Is mesh slot mi only this object's (no other object, no undo step)?
fn meshAlone(i: usize, mi: u16) bool {
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (k != i and o.mesh == mi) return false;
    }
    return !@import("undo.zig").anyStepHolds(mi);
}

/// cv_edit(object, room for more points): its curve, ready to change in place
/// (copied with a new mesh when an undo step or another object shares it, or
/// it is full), or null. Call cvRebuild after.
pub fn cvEdit(i: usize, room: u32) ?*Curve {
    const c = cvOf(i) orelse return null;
    const mi = scene.objects[i].mesh.?;
    if (meshAlone(i, mi) and c.h.refs == 1 and c.h.npts +% room <= c.h.cap) return c;
    const n = cvCopy(c, room +% 16) orelse return null;
    const nm = cvMesh(n);
    cvUnref(n); // (its mesh holds it)
    scene.objects[i].mesh = nm orelse return null;
    return n;
}

/// cv_add_point(curve, position): its index (appended to the active spline; a
/// Bezier spline first when there is none), or null.
pub fn cvAddPoint(c: *Curve, p: V3) ?u32 {
    if (c.h.nspl == 0) _ = cvSplineNew(c, ST_BEZ, 0);
    return cvInsert(c, c.h.act, 0x7fffffff, .{ .co = p, .hl = p, .hr = p, .rad = 1.0, .tilt = 0 });
}

const cc_names = [4][]const u8{ "BezierCurve", "BezierCircle", "Path", "Curve" };
const cc_circle = [_][2]f32{ .{ 1, 0 }, .{ 0, -1 }, .{ -1, 0 }, .{ 0, 1 } };
const cc_path = [_][2]f32{ .{ -2, 0 }, .{ -1, 0 }, .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 } };
const cc_bez = [2][3]V3{
    .{ .{ -1, 0, 0 }, .{ -1.5, 0, -0.5 }, .{ -0.5, 0, 0.5 } },
    .{ .{ 1, 0, 0 }, .{ 0.5, 0, -0.5 }, .{ 1.5, 0, 0.5 } },
};

fn uniqueName(o: *scene.Object, base: []const u8) void {
    o.setName(base);
    var buf: [32]u8 = undefined;
    var k: u32 = 1;
    while (nameTaken(o.name())) : (k += 1) {
        o.setName(std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ base, k }) catch return);
    }
}

fn nameTaken(s: []const u8) bool {
    for (scene.objects[0..scene.count]) |*o| if (std.mem.eql(u8, o.name(), s)) return true;
    return false;
}

/// cv_create(kind: 0 Bezier, 1 circle, 2 path, 3 empty, name or null): the new
/// object (at the origin), or null.
pub fn cvCreate(kind_in: u32, name: ?[]const u8) ?usize {
    const kind = @min(kind_in, 3);
    const nm = name orelse cc_names[kind];
    const c = cvNew(16) orelse return null;
    if (kind != 3) {
        const typ: u32 = if (kind == 2) ST_POLY else ST_BEZ;
        _ = cvSplineNew(c, typ, if (kind == 1) 1 else 0);
        if (kind == 0) { // two points, aligned handles
            for (cc_bez) |b| {
                const k = cvAddPoint(c, b[0]) orelse break;
                c.pts[k].hl = b[1];
                c.pts[k].hr = b[2];
                c.pts[k].ht = 1;
            }
        } else {
            const pts: []const [2]f32 = if (kind == 1) &cc_circle else &cc_path;
            for (pts) |q| _ = cvAddPoint(c, .{ q[0], 0, q[1] });
        }
    }
    const mi = cvMesh(c);
    cvUnref(c);
    const m_ = mi orelse return null;
    if (scene.count >= scene.max_objects) {
        scene.freeMeshSlot(m_);
        return null;
    }
    var o = scene.Object{ .kind = .mesh, .mesh = m_ };
    uniqueName(&o, nm);
    scene.objects[scene.count] = o;
    scene.stamp(scene.count);
    scene.count += 1;
    return scene.count - 1;
}

/// cv_count(object): its control points (null: not a curve).
pub fn cvCount(i: usize) ?u32 {
    return if (cvOf(i)) |c| c.h.npts else null;
}

/// cv_length(object): the length of what it makes (object space, along the
/// evaluated splines; -1: not a curve).
pub fn cvLength(i: usize) f32 {
    const c = cvOf(i) orelse return -1.0;
    _ = chFromCurve(c);
    var s: f32 = 0;
    var k: u32 = 0;
    while (k < ch_n) : (k += 1) s = chLen(k) + s;
    return s;
}

/// cv_load(block from the spline count on, points): a curve, or null when it
/// does not hold together.
pub fn cvLoad(d: []const u8, npts: u32) ?*Curve {
    if (npts > CV_MAXPTS) return null;
    if (d.len < CV_PTS - 4 + @as(usize, npts) * CP_SZ) return null;
    const c = cvNew(npts) orelse return null;
    const cap = c.h.cap;
    const bytes = c.h.bytes;
    const hb = std.mem.asBytes(&c.h);
    @memcpy(hb[4..CV_PTS], d[0 .. CV_PTS - 4]);
    @memcpy(std.mem.sliceAsBytes(c.pts[0..npts]), d[CV_PTS - 4 ..][0 .. @as(usize, npts) * CP_SZ]);
    c.h.refs = 1;
    c.h.cap = cap;
    c.h.bytes = bytes;
    ok: {
        if (c.h.npts != npts or c.h.nspl > CV_MAXS) break :ok;
        var at: u32 = 0; // splines tile the points in order
        for (c.h.spl[0..c.h.nspl]) |sp| {
            if (sp.first != at) break :ok;
            const ov = @addWithOverflow(at, sp.n);
            if (ov[1] != 0 or ov[0] > npts) break :ok;
            at = ov[0];
        }
        if (at != npts) break :ok;
        cvPrune(c);
        return c;
    }
    cvUnref(c);
    return null;
}

/// curv_write: per mesh (in the MESH chunks' order) made by a curve: its index,
/// points, the block from its spline count on.
pub fn writeChunk(out: *std.ArrayList(u8), a: std.mem.Allocator, mesh_ix: []const u32) !void {
    // (formats.s curv_write walks mesh_tab: the MESH chunks' order, not the
    // port's slot order, which differs once meshes are freed and reused)
    var by_ix: [scene.max_meshes]?u16 = @splat(null);
    for (mesh_ix, 0..) |ix, mi| {
        if (ix != 0xffffffff and ix < by_ix.len) by_ix[ix] = @intCast(mi);
    }
    for (by_ix) |x| {
        const mi = x orelse continue;
        const ix = mesh_ix[mi];
        const me = scene.meshes[mi] orelse continue;
        const c = me.curve orelse continue;
        var w: [8]u8 = undefined;
        std.mem.writeInt(u32, w[0..4], ix, .little);
        std.mem.writeInt(u32, w[4..8], c.h.npts, .little);
        try out.appendSlice(a, &w);
        try out.appendSlice(a, std.mem.asBytes(&c.h)[4..CV_PTS]);
        try out.appendSlice(a, std.mem.sliceAsBytes(c.pts[0..c.h.npts]));
    }
}

/// curv_read: curves back on the loaded meshes (slot of each MESH chunk's index).
pub fn readChunk(d: []const u8, slots: []const ?u16) void {
    var o: usize = 0;
    while (d.len - o >= 8) {
        const n = std.mem.readInt(u32, d[o + 4 ..][0..4], .little);
        if (n > 4000000) return;
        const rec: usize = @as(usize, n) * 48 + 580;
        if (rec > d.len - o) return;
        const ix = std.mem.readInt(u32, d[o..][0..4], .little);
        if (ix < slots.len) {
            if (slots[ix]) |mi| {
                if (cvLoad(d[o + 8 .. o + rec], n)) |c| {
                    if (scene.meshes[mi]) |*me| {
                        cvUnref(me.curve);
                        me.curve = c;
                    } else cvUnref(c);
                }
            }
        }
        o += rec;
    }
}

// ---- operators ---------------------------------------------------------------------------

/// The object in curve edit mode (its oid; 0: none).
pub var cve_obj: u32 = 0;

/// cve_get: the object in curve edit mode, or null (leaves the mode when it went
/// away or stopped being a curve).
pub fn cveGet() ?usize {
    if (cve_obj == 0) return null;
    const i = scene.findOid(cve_obj) orelse {
        cve_obj = 0;
        return null;
    };
    if (cvOf(i) == null) {
        cve_obj = 0;
        return null;
    }
    return i;
}

/// What curve edit mode shows (viewport stateKey): the object, its points'
/// selection and places (selection changes in place).
pub fn stateWord() u64 {
    const i = cveGet() orelse return 0;
    const c = cvOf(i) orelse return 0;
    var h = std.hash.Wyhash.init(cve_obj);
    h.update(std.mem.asBytes(&c.h.npts));
    if (c.h.npts <= 200000) h.update(std.mem.sliceAsBytes(c.used())) else h.update(std.mem.asBytes(&c));
    return h.final() | 1;
}

/// cv_target: the curve edited, else the active object when it is a curve
/// (logs and null otherwise).
fn cvTarget() ?usize {
    if (cveGet()) |i| return i;
    if (scene.active) |a| {
        if (cvOf(a) != null) return a;
    }
    app.log("  not a curve (curve.add makes one)", .{});
    return null;
}

const cv_kinds = [_][]const u8{ "bezier", "circle", "path", "empty" };
const cv_htypes = [_][]const u8{ "auto", "aligned", "vector", "free" };

fn wordIndex(w: []const u8, names: []const []const u8) ?u32 {
    for (names, 0..) |x, k| if (std.mem.eql(u8, w, x)) return @intCast(k);
    return null;
}

fn words() nt.Words {
    return .{ .s = @import("ops.zig").arg };
}

/// interactive: by hand (not typed in the console: no modal step after).
fn interactive() bool {
    return !@import("ops.zig").scripted;
}

/// do_cv_add: curve.add [kind] (the menu's kind; a word overrides).
fn cvAdd(comptime kind0: u32) *const fn () void {
    return &struct {
        fn f() void {
            var kind: u32 = kind0;
            var w = words();
            const wd = w.next();
            if (wd.len > 0) {
                if (wordIndex(wd, &cv_kinds)) |k| kind = k;
            }
            cve_obj = 0;
            const i = cvCreate(kind, null) orelse return;
            scene.selectOnly(i);
            scene.objects[i].loc = scene.cursor;
            @import("undo.zig").label("Add");
            app.log("  added {s}", .{scene.objects[i].name()});
        }
    }.f;
}

const s_cv_bad = "  curve.set: resolution 1-64, bevel >= 0, sides 3-64, fill 0/1, profile <curve>|none, cyclic 0/1";

/// do_cv_set: curve.set <resolution|bevel|sides|fill|profile|cyclic> <value>
fn cvSet() void {
    const i = cvTarget() orelse return;
    var w = words();
    const key = w.next();
    if (key.len == 0) return app.log(s_cv_bad, .{});
    if (std.mem.eql(u8, key, "profile")) {
        const nm = w.next();
        if (nm.len == 0) return app.log(s_cv_bad, .{});
        var uid: u32 = 0;
        if (!std.mem.eql(u8, nm, "none")) {
            const k = findName(nm) orelse return app.log("  not a curve to use as a profile: {s}", .{nm});
            if (k == i) return app.log("  not a curve to use as a profile: {s}", .{nm});
            uid = scene.objects[k].uid;
            if (cvOf(k) == null) return app.log("  not a curve to use as a profile: {s}", .{nm});
        }
        const c = cvEdit(i, 0) orelse return;
        c.h.prof = uid;
        return cvRebuild(i);
    }
    const cs_keys = [_][]const u8{ "resolution", "bevel", "sides", "fill", "cyclic" };
    const ki = wordIndex(key, &cs_keys) orelse return app.log(s_cv_bad, .{});
    const v = w.num() orelse return app.log(s_cv_bad, .{});
    const c = cvEdit(i, 0) orelse return;
    const n = cvtt(v);
    switch (ki) {
        0 => {
            if (n < 1 or n > 64) return app.log(s_cv_bad, .{});
            c.h.res = n;
        },
        1 => {
            if (v < 0 or std.math.isNan(v)) return app.log(s_cv_bad, .{});
            c.h.bevel = v;
        },
        2 => {
            if (n < 3 or n > 64) return app.log(s_cv_bad, .{});
            c.h.sides = n;
        },
        3 => c.h.fill = @intFromBool(n != 0),
        else => for (c.h.spl[0..c.h.nspl]) |*sp| {
            sp.cyc = @intFromBool(n != 0);
        },
    }
    cvRebuild(i);
}

/// obj_find: an object by its name.
fn findName(nm: []const u8) ?usize {
    for (scene.objects[0..scene.count], 0..) |*o, k| if (std.mem.eql(u8, o.name(), nm)) return k;
    return null;
}

/// do_cv_point: curve.point <x> <y> <z>
fn cvPoint() void {
    const i = cvTarget() orelse return;
    var w = words();
    var p: V3 = undefined;
    for (&p) |*x| x.* = w.num() orelse return;
    const c = cvEdit(i, 1) orelse return;
    if (cvAddPoint(c, p) == null) app.log("  the curve is full", .{});
    cvRebuild(i);
}

/// do_cv_spline: curve.spline <bezier|poly> [cyclic]
fn cvSpline() void {
    const i = cvTarget() orelse return;
    var typ: u32 = ST_BEZ;
    var cyc: u32 = 0;
    var w = words();
    while (true) {
        const wd = w.next();
        if (wd.len == 0) break;
        if (std.mem.eql(u8, wd, "poly")) typ = ST_POLY;
        if (std.mem.eql(u8, wd, "cyclic")) cyc = 1;
    }
    const c = cvEdit(i, 0) orelse return;
    if (cvSplineNew(c, typ, cyc) == null) app.log("  the curve is full", .{});
    cvRebuild(i);
}

/// do_cv_tomesh: curve.to_mesh - the plain mesh it makes.
fn cvToMesh() void {
    const i = cvTarget() orelse return;
    cve_obj = 0;
    const mi = scene.objects[i].mesh orelse return;
    const n = scene.cloneMesh(mi) orelse return; // (a copy carries no curve)
    scene.objects[i].mesh = n;
    app.log("  converted to a mesh: {s}", .{scene.objects[i].name()});
}

/// sel_all(curve, bits): every point's selection.
fn selAll(c: *Curve, bits: u8) void {
    for (c.used()) |*p| p.sel = bits;
    app.dirty = true;
}

/// do_cv_select: curve.select <i ...> | all | none
fn cvSelect() void {
    const i = cvTarget() orelse return;
    const c = cvOf(i).?;
    var w = words();
    const first = w.next();
    if (std.mem.eql(u8, first, "all")) return selAll(c, 7);
    selAll(c, 0); // none, or a list: from nothing
    w = words();
    while (w.num()) |v| {
        const k: u32 = @bitCast(cvtt(v));
        if (k < c.h.npts) c.pts[k].sel = 7;
    }
}

/// do_cv_selall: any selected: none, else all.
fn cvSelAll() void {
    const i = cveGet() orelse return;
    const c = cvOf(i).?;
    var any: u8 = 0;
    for (c.used()) |p| any |= p.sel;
    selAll(c, if (any != 0) 0 else 7);
}

/// do_cv_move: curve.move <i> <x> <y> <z> [left|right]
fn cvMove() void {
    const i = cvTarget() orelse return;
    var w = words();
    const kf = w.num() orelse return;
    const k: u32 = @bitCast(cvtt(kf));
    var p: V3 = undefined;
    for (&p) |*x| x.* = w.num() orelse return;
    var part: u32 = 0;
    const wd = w.next();
    if (wd.len > 0) {
        if (std.mem.eql(u8, wd, "left")) part |= 1;
        if (std.mem.eql(u8, wd, "right")) part |= 2;
    }
    const c = cvEdit(i, 0) orelse return;
    if (k >= c.h.npts) return;
    cpPlace(&c.pts[k], part, p);
    cvRebuild(i);
}

/// cp_place(point, part 0 point / 1 left / 2 right, position): a point brings
/// its handles along; a handle made auto / vector becomes aligned / free, and an
/// aligned one turns its partner.
pub fn cpPlace(p: *CP, part: u32, at: V3) void {
    if (part == 0) {
        const d = sub(at, p.co);
        p.co = at;
        p.hl = add(p.hl, d);
        p.hr = add(p.hr, d);
        return;
    }
    if (p.ht == 0) p.ht = 1;
    if (p.ht == 2) p.ht = 3;
    if (part == 1) p.hl = at else p.hr = at;
    cpAlign(p, part);
}

/// cp_align(point, the handle that moved: 1 left, 2 right): an aligned point's
/// other handle turns to the opposite side, its length kept.
pub fn cpAlign(p: *CP, part: u32) void {
    if (p.ht != 1) return;
    const co = p.co;
    const moved = if (part == 1) p.hl else p.hr;
    const other = if (part == 1) &p.hr else &p.hl;
    var d = sub(moved, co);
    const l = len(d);
    if (!(l > tiny)) return;
    d = divs(d, l);
    const lo = len(sub(other.*, co));
    other.* = sub(co, scl(d, lo));
}

/// do_cv_extrude: curve.extrude [dx dy dz] - new points after the selected end
/// points of open splines.
fn cvExtrude() void {
    const i = cvTarget() orelse return;
    const before = scene.objects[i].mesh;
    const c = cvEdit(i, CV_MAXS * 2) orelse return;
    var off: V3 = .{ 0, 0, 0 };
    var w = words();
    for (&off) |*x| x.* = w.num() orelse break;
    var made: u32 = 0;
    var s: u32 = 0;
    while (s < c.h.nspl) : (s += 1) {
        const sp = c.h.spl[s];
        if (sp.cyc != 0 or sp.n == 0) continue;
        const last = sp.first + sp.n - 1;
        if (c.pts[last].sel & 1 != 0) {
            if (cePut(c, s, last, sp.n, off)) made += 1;
        }
        const sp2 = c.h.spl[s];
        if (sp2.n < 2) continue;
        if (c.pts[sp2.first].sel & 1 != 0) {
            if (cePut(c, s, sp2.first, 0, off)) made += 1;
        }
    }
    if (made == 0) {
        app.log("  select an end point of an open spline", .{});
        scene.objects[i].mesh = before; // (undo_drop_last: no step)
        return;
    }
    cvRebuild(i);
    if (interactive() and cve_obj != 0) startMove();
}

/// .Lce_put: a copy of the end, moved by the offset, auto handles, selected (the
/// end deselected), at `place` in its spline.
fn cePut(c: *Curve, s: u32, end: u32, place: u32, off: V3) bool {
    var r = c.pts[end];
    c.pts[end].sel = 0;
    const p = add(r.co, off);
    r.co = p;
    r.hl = p;
    r.hr = p;
    r.ht = 0;
    r.sel = 7;
    return cvInsert(c, s, place, r) != null;
}

/// After an extrude by hand: move the new points (tm_start, no undo step of its own).
fn startMove() void {
    _ = app.beginTransform(.move);
}

/// sel_count(curve): points selected.
fn selCount(c: *const Curve) u32 {
    var n: u32 = 0;
    for (c.used()) |p| n += @intFromBool(p.sel & 1 != 0);
    return n;
}

/// do_cv_subdiv: a point between each pair of selected neighbours (the shape
/// kept: de Casteljau at a half).
fn cvSubdiv() void {
    const i = cvTarget() orelse return;
    const c = cvEdit(i, selCount(cvOf(i).?)) orelse return;
    cvHandles(c); // (auto handles as they are now)
    var made: u32 = 0;
    var s: u32 = 0;
    while (s < c.h.nspl) : (s += 1) {
        const n = c.h.spl[s].n;
        var k: i32 = @as(i32, @intCast(n)) - 2; // pairs from the last down
        if (c.h.spl[s].cyc != 0 and n >= 3) k += 1;
        while (k >= 0) : (k -= 1) {
            const sp = c.h.spl[s];
            const ku: u32 = @intCast(k);
            const qn = if (ku + 1 < n) ku + 1 else 0;
            const P = &c.pts[sp.first + ku];
            const Q = &c.pts[sp.first + qn];
            if (P.sel & 1 == 0 or Q.sel & 1 == 0) continue;
            const p0 = P.co;
            var p1 = P.hr;
            var p2 = Q.hl;
            const p3 = Q.co;
            if (sp.typ != ST_BEZ) { // poly: the middle
                p1 = p0;
                p2 = p3;
            }
            const a = scl(add(p0, p1), 0.5);
            const b = scl(add(p1, p2), 0.5);
            const cc = scl(add(p2, p3), 0.5);
            const d = scl(add(a, b), 0.5);
            const e = scl(add(b, cc), 0.5);
            const mid = scl(add(d, e), 0.5);
            var r = P.*; // the new point: P's record
            r.co = mid;
            r.hl = d;
            r.hr = e;
            r.rad = (P.rad + Q.rad) * 0.5;
            r.tilt = (P.tilt + Q.tilt) * 0.5;
            r.ht = 1;
            r.sel = 7;
            if (sp.typ == ST_BEZ) { // the neighbours' handles shortened
                P.hr = a;
                Q.hl = cc;
                keepHandles(P);
                keepHandles(Q);
            }
            if (cvInsert(c, s, ku + 1, r) != null) made += 1;
        }
    }
    if (made == 0) app.log("  no control points selected", .{});
    cvRebuild(i);
}

/// .Lcd_keep: a point's handles stay (auto -> aligned, vector -> free).
fn keepHandles(p: *CP) void {
    if (p.ht == 0) p.ht = 1;
    if (p.ht == 2) p.ht = 3;
}

/// do_cv_delete: the selected control points removed.
fn cvDelete() void {
    const i = cvTarget() orelse return;
    const c = cvEdit(i, 0) orelse return;
    var k = c.h.npts;
    while (k > 0) {
        k -= 1;
        if (k < c.h.npts and c.pts[k].sel & 1 != 0) cvRemove(c, k);
    }
    cvRebuild(i);
}

/// for_sel(fn, value): fn on each selected point of the curve edited (or the
/// active curve); how many.
fn forSel(f: *const fn (*CP, *Spl, f32) void, v: f32) u32 {
    const i = cvTarget() orelse return 0;
    const c = cvEdit(i, 0) orelse return 0;
    var n: u32 = 0;
    var k: u32 = 0;
    while (k < c.h.npts) : (k += 1) {
        const p = &c.pts[k];
        if (p.sel & 7 == 0) continue;
        const so = cvSplineOf(c, k);
        // (a point in no spline: the original's spline -1, the record before the table)
        const sp: *Spl = if (so) |x| &c.h.spl[x[0]] else &spl_none;
        f(p, sp, v);
        n += 1;
    }
    if (n == 0) app.log("  no control points selected", .{});
    cvRebuild(i);
    return n;
}
var spl_none: Spl = .{};

fn fsMark(_: *CP, sp: *Spl, _: f32) void {
    sp.cyc |= 2;
}

/// do_cv_cyclic: close (or open) the splines holding selected points.
fn cvCyclic() void {
    _ = forSel(fsMark, 0);
    const i = cvTarget() orelse return;
    const c = cvOf(i).?;
    for (c.h.spl[0..c.h.nspl]) |*sp| {
        if (sp.cyc & 2 == 0) continue;
        sp.cyc = (sp.cyc & 1) ^ 1;
    }
    cvRebuild(i);
}

var ht_next: i32 = -1;
fn fsHandle(p: *CP, _: *Spl, _: f32) void {
    if (ht_next < 0) ht_next = (@as(i32, p.ht) + 1) & 3; // (the first point decides the next)
    p.ht = @intCast(ht_next & 0xff);
}

/// do_cv_handle: curve.handle [auto|aligned|vector|free] (none: the next type).
fn cvHandle() void {
    var w = words();
    const wd = w.next();
    ht_next = -1;
    if (wd.len > 0) ht_next = if (wordIndex(wd, &cv_htypes)) |k| @intCast(k) else -1;
    _ = forSel(fsHandle, 0);
}

fn fsTilt(p: *CP, _: *Spl, v: f32) void {
    p.tilt = v;
}
fn fsRadius(p: *CP, _: *Spl, v: f32) void {
    p.rad = v;
}

/// do_cv_tilt: curve.tilt <degrees>
fn cvTilt() void {
    var w = words();
    const v = w.num() orelse return;
    _ = forSel(fsTilt, v * 0.017453292);
}

/// do_cv_radius: curve.radius <r>
fn cvRadius() void {
    var w = words();
    const v = w.num() orelse return;
    _ = forSel(fsRadius, maxss(v, 0));
}

const Impl = @import("ops.zig").Impl;
pub const list = .{
    .{ "create.bezier", Impl{ .run = cvAdd(0) } },
    .{ "create.curve_circle", Impl{ .run = cvAdd(1) } },
    .{ "create.path", Impl{ .run = cvAdd(2) } },
    .{ "curve.add", Impl{ .run = cvAdd(0) } },
    .{ "curve.set", Impl{ .run = cvSet } },
    .{ "curve.point", Impl{ .run = cvPoint } },
    .{ "curve.spline", Impl{ .run = cvSpline } },
    .{ "curve.to_mesh", Impl{ .run = cvToMesh } },
    .{ "curve.select", Impl{ .run = cvSelect } },
    .{ "curve.move", Impl{ .run = cvMove } },
    .{ "curve.select_all", Impl{ .run = cvSelAll, .mode = .curve } },
    .{ "curve.extrude", Impl{ .run = cvExtrude, .mode = .curve } },
    .{ "curve.subdivide", Impl{ .run = cvSubdiv, .mode = .curve } },
    .{ "curve.delete", Impl{ .run = cvDelete, .mode = .curve } },
    .{ "curve.delete_key", Impl{ .run = cvDelete, .mode = .curve } },
    .{ "curve.cyclic", Impl{ .run = cvCyclic, .mode = .curve } },
    .{ "curve.handle", Impl{ .run = cvHandle, .mode = .curve } },
    .{ "curve.tilt", Impl{ .run = cvTilt } },
    .{ "curve.radius", Impl{ .run = cvRadius } },
};

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

fn lineMesh(a: std.mem.Allocator, pts: []const V3, closed: bool) !PMesh {
    const n: u32 = @intCast(pts.len);
    const segs: u32 = if (closed) n else n - 1;
    const v = try a.dupe(V3, pts);
    const o = try a.alloc(u32, segs + 1);
    const l = try a.alloc(u32, segs * 2);
    for (0..segs + 1) |i| o[i] = @intCast(i * 2);
    for (0..segs) |i| {
        l[i * 2] = @intCast(i);
        l[i * 2 + 1] = @intCast((i + 1) % n);
    }
    return .{ .verts = v, .poff = o, .loops = l };
}

test "chains from 2-point polygons: open and closed" {
    A = testing.allocator;
    defer chFree();
    const a = testing.allocator;
    const sq = [_]V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 } };
    const m1 = try lineMesh(a, &sq, true);
    defer m1.deinit(a);
    try testing.expect(chFromMesh(m1));
    try testing.expectEqual(@as(u32, 1), ch_n);
    try testing.expectEqual(@as(u32, 4), ch_total);
    try testing.expectEqual(@as(u32, 1), ch_tab[0].cyc);
    try testing.expectEqual(@as(f32, 4), chLen(0));
    const back = chToLines(a).?;
    defer back.deinit(a);
    try testing.expectEqual(@as(usize, 4), back.faces());
    try testing.expectEqualSlices(u32, m1.loops, back.loops);
    const m2 = try lineMesh(a, sq[0..3], false);
    defer m2.deinit(a);
    try testing.expect(chFromMesh(m2));
    try testing.expectEqual(@as(u32, 0), ch_tab[0].cyc);
    try testing.expectEqual(@as(u32, 3), ch_tab[0].n);
}

test "a tube: rings of the profile, quads and caps" {
    A = testing.allocator;
    defer chFree();
    const a = testing.allocator;
    const pts = [_]V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 2, 0, 0 } };
    const cm = try lineMesh(a, &pts, false);
    defer cm.deinit(a);
    var node: [72]u8 = @splat(0);
    std.mem.writeInt(u32, node[ND_P..][0..4], @bitCast(@as(f32, 0.5)), .little);
    std.mem.writeInt(u32, node[ND_P + 4 ..][0..4], @bitCast(@as(f32, 6)), .little);
    std.mem.writeInt(u32, node[ND_P + 8 ..][0..4], @bitCast(@as(f32, 1)), .little);
    const t = cnToMesh(a, cm, null, &node).?;
    defer t.deinit(a);
    try testing.expectEqual(@as(usize, 18), t.verts.len);
    try testing.expectEqual(@as(usize, 2 * 6 + 2), t.faces());
    // the rings are round, of the radius, across the path (along X: in YZ)
    for (t.verts, 0..) |v, i| {
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(i / 6)), v[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0.5), @sqrt(v[1] * v[1] + v[2] * v[2]), 1e-6);
    }
    // no radius, no profile: the curve as it is
    std.mem.writeInt(u32, node[ND_P..][0..4], 0, .little);
    const l = cnToMesh(a, cm, null, &node).?;
    defer l.deinit(a);
    try testing.expectEqual(@as(usize, 2), l.faces());
}

test "curve circle and line nodes" {
    A = testing.allocator;
    defer chFree();
    const a = testing.allocator;
    const c = cnCircleV(a, 2, 1).?; // (3 sides at least)
    defer c.deinit(a);
    try testing.expectEqual(@as(usize, 3), c.verts.len);
    try testing.expectEqual(@as(usize, 3), c.faces());
    try testing.expectEqual(@as(f32, 1), c.verts[0][0]);
    const l = cnLineV(a, .{ 0, 0, 0 }, .{ 0, 0, 1 }).?;
    defer l.deinit(a);
    try testing.expectEqual(@as(usize, 1), l.faces());
}

test "resample, trim and fillet keep their counts" {
    A = testing.allocator;
    defer chFree();
    const a = testing.allocator;
    const pts = [_]V3{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 0, 2 } };
    const cm = try lineMesh(a, &pts, false);
    defer cm.deinit(a);
    try testing.expect(chFromMesh(cm));
    chResample(5, 0);
    try testing.expectEqual(@as(u32, 5), ch_total);
    try testing.expectEqual(@as(f32, 1), ch_ep[1].p[0]);
    try testing.expect(chFromMesh(cm));
    chTrim(0.25, 0.75);
    try testing.expectEqual(@as(u32, 3), ch_total);
    try testing.expectEqual(@as(f32, 1), ch_ep[0].p[0]);
    try testing.expect(chFromMesh(cm));
    chFillet(0.5, 4);
    try testing.expectEqual(@as(u32, 2 + 5), ch_total);
    const pp = chPoints(a).?;
    defer pp.deinit(a);
    try testing.expectEqual(@as(usize, 7), pp.verts.len);
}

test "the L-system's way: chains filled by the caller, swept with a hexagon" {
    A = testing.allocator;
    defer chFree();
    const a = testing.allocator;
    try testing.expect(chReserve(4, 2));
    ch_tab[0] = .{ .first = 0, .n = 2, .cyc = 0 };
    ch_ep[0] = .{ .p = .{ 0, 0, 0 }, .rad = 1, .tilt = 0 };
    ch_ep[1] = .{ .p = .{ 0, 1, 0 }, .rad = 0.5, .tilt = 0 };
    ch_n = 1;
    ch_total = 2;
    const pc = profCircle(6, 1).?;
    defer A.free(pc);
    const t = chSweep(a, pc, 1, 0).?;
    defer t.deinit(a);
    try testing.expectEqual(@as(usize, 12), t.verts.len);
    try testing.expectEqual(@as(usize, 6), t.faces());
}

test "handles: a 4-point circle is round" {
    A = testing.allocator;
    defer chFree();
    const c = cvNew(16).?;
    defer cvUnref(c);
    _ = cvSplineNew(c, ST_BEZ, 1);
    for ([_][2]f32{ .{ 1, 0 }, .{ 0, -1 }, .{ -1, 0 }, .{ 0, 1 } }) |q| {
        _ = cvInsert(c, c.h.act, 0x7fffffff, .{ .co = .{ q[0], 0, q[1] }, .hl = .{ q[0], 0, q[1] }, .hr = .{ q[0], 0, q[1] }, .rad = 1, .tilt = 0 }).?;
    }
    try testing.expect(chFromCurve(c));
    try testing.expectEqual(@as(u32, 48), ch_total);
    for (ch_ep[0..ch_total]) |e| try testing.expectApproxEqAbs(@as(f32, 1), len(e.p), 0.002);
}

test "a block through the file's bytes: cv_load takes it back, refuses what does not tile" {
    A = testing.allocator;
    defer chFree();
    const c = cvNew(16).?;
    defer cvUnref(c);
    _ = cvSplineNew(c, ST_POLY, 0);
    for (0..3) |k| _ = cvAddPoint(c, .{ @floatFromInt(k), 0, 0 }).?;
    _ = cvSplineNew(c, ST_BEZ, 1);
    _ = cvAddPoint(c, .{ 0, 1, 0 }).?;
    c.h.res = 7;
    var buf: [CV_PTS - 4 + 4 * CP_SZ]u8 = undefined;
    @memcpy(buf[0 .. CV_PTS - 4], std.mem.asBytes(&c.h)[4..CV_PTS]);
    @memcpy(buf[CV_PTS - 4 ..], std.mem.sliceAsBytes(c.pts[0..4]));
    const d = cvLoad(&buf, 4).?;
    defer cvUnref(d);
    try testing.expectEqual(@as(u32, 2), d.h.nspl);
    try testing.expectEqual(@as(i32, 7), d.h.res);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(c.pts[0..4]), std.mem.sliceAsBytes(d.pts[0..4]));
    // the second spline said to start at 2: no tiling
    std.mem.writeInt(u32, buf[64 - 4 + 16 + 8 ..][0..4], 2, .little);
    try testing.expect(cvLoad(&buf, 4) == null);
    // a copy has room for more and the same values
    const e = cvCopy(c, 30).?;
    defer cvUnref(e);
    try testing.expectEqual(@as(u32, 34), e.h.cap);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&c.h)[24..CV_PTS], std.mem.asBytes(&e.h)[24..CV_PTS]);
}

test "insert, remove and prune keep the splines tiling the points" {
    A = testing.allocator;
    const c = cvNew(16).?;
    defer cvUnref(c);
    _ = cvSplineNew(c, ST_POLY, 0);
    _ = cvAddPoint(c, .{ 0, 0, 0 }).?;
    _ = cvSplineNew(c, ST_POLY, 0);
    _ = cvAddPoint(c, .{ 1, 0, 0 }).?;
    _ = cvAddPoint(c, .{ 2, 0, 0 }).?;
    try testing.expectEqual(@as(u32, 1), c.h.spl[1].first);
    _ = cvInsert(c, 0, 0, .{ .co = .{ 9, 0, 0 }, .hl = .{ 9, 0, 0 }, .hr = .{ 9, 0, 0 }, .rad = 1, .tilt = 0 }).?;
    try testing.expectEqual(@as(u32, 2), c.h.spl[1].first);
    try testing.expectEqual(@as(f32, 9), c.pts[0].co[0]);
    cvRemove(c, 0);
    cvRemove(c, 0); // (the first spline empty: it goes)
    try testing.expectEqual(@as(u32, 1), c.h.nspl);
    try testing.expectEqual(@as(u32, 0), c.h.spl[0].first);
    try testing.expectEqual(@as(u32, 2), c.h.npts);
    try testing.expectEqual(@as(u32, 0), c.h.act);
}

test "to mesh: a profile without chains (a cube) and a radius: the circle, freed once" {
    A = testing.allocator;
    defer chFree();
    const a = testing.allocator;
    const pts = [_]V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 2, 0, 0 } };
    const cm = try lineMesh(a, &pts, false);
    defer cm.deinit(a);
    const cube = try pm.testCube(a);
    defer cube.deinit(a);
    const t = cnToMeshV(a, cm, cube, 0.5, 6, 0).?;
    defer t.deinit(a);
    try testing.expectEqual(@as(usize, 18), t.verts.len);
    // a profile of one chain of two points: used as it is, the radius not
    const two = try lineMesh(a, pts[0..2], false);
    defer two.deinit(a);
    const u = cnToMeshV(a, cm, two, 0.5, 6, 0).?;
    defer u.deinit(a);
    try testing.expectEqual(@as(usize, 6), u.verts.len);
}

