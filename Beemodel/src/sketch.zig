// Sketches (sketch.s): 2D geometry on the XY, XZ or YZ plane with constraints,
// solved. A sketch is a block of exactly the original's layout (it goes into
// the .bee file as it is, SKCH): points, lines, circles and arcs, then the
// constraints. Constraints become residual equations over the unknowns (the
// points' coordinates, the radii), and a damped Gauss-Newton (Levenberg-
// Marquardt) solves each connected group of unknowns on its own, in doubles,
// in the original's order of operations, so the solved coordinates are the
// original's bit for bit (atan2, sin and cos through the x87 as it does).
//
// After a solve, the Jacobian's rank says how many degrees of freedom are
// left; unknowns outside its null space are fixed, so each point and entity
// knows whether it is fully constrained. Equations still unsatisfied are
// conflicts.
//
// Blocks are copy-on-write as the original's (sk_own): an edit works on a copy
// when anything else (an undo step, a duplicate) still holds the block, so a
// step keeps the sketch it saw. Here a block is a node in a list; what no
// object and no undo step holds any more is freed (collect).
const std = @import("std");
const builtin = @import("builtin");

pub const MAX_PT = 256;
pub const MAX_ENT = 256;
pub const MAX_CON = 256;
pub const MAX_VARS = MAX_PT * 2 + MAX_ENT;
pub const MAX_EQS = MAX_CON * 2 + MAX_ENT * 2;
const MAX_ITER = 60;

// flags
pub const F_FULL: u32 = 1; // fully constrained
pub const F_BAD: u32 = 2; // in conflict
pub const F_CONSTR: u32 = 4; // construction geometry
// entities
pub const E_LINE: u32 = 1;
pub const E_CIRCLE: u32 = 2;
pub const E_ARC: u32 = 3;
// constraints
pub const C_COINCIDENT: u32 = 1;
pub const C_HORIZONTAL: u32 = 2;
pub const C_VERTICAL: u32 = 3;
pub const C_PARALLEL: u32 = 4;
pub const C_PERP: u32 = 5;
pub const C_EQUAL: u32 = 6;
pub const C_TANGENT: u32 = 7;
pub const C_FIXED: u32 = 8;
pub const C_DISTANCE: u32 = 9;
pub const C_HDIST: u32 = 10;
pub const C_VDIST: u32 = 11;
pub const C_RADIUS: u32 = 12;
pub const C_ANGLE: u32 = 13;
pub const C_ONLINE: u32 = 14;
pub const C_ONCIRCLE: u32 = 15;
pub const C_MIDPOINT: u32 = 16;
pub const C_SYMMETRIC: u32 = 17;
pub const C_LENGTH: u32 = 18;
pub const C_DIAMETER: u32 = 19;
pub const NCTYPES = 19;

pub const Pt = extern struct { x: f64, y: f64, flags: u32, pad: u32 };
pub const Ent = extern struct { typ: u32, p: [3]i32, r: f64, flags: u32, pad: u32 };
pub const Con = extern struct { typ: u32, a: i32, b: i32, c: i32, val: f64, val2: f64, flags: u32, expr: [60]u8 };

/// The original's block (SK_*), byte for byte.
pub const Block = extern struct {
    refs: u32,
    bytes: u32,
    plane: u32, // 0 XY, 1 XZ, 2 YZ
    npt: u32,
    nent: u32,
    ncon: u32,
    dof: i32, // after a solve (-1: never solved)
    nbad: u32, // conflicting constraints
    offset: f64, // along the plane's normal
    pad0: [24]u8,
    pts: [MAX_PT]Pt,
    ents: [MAX_ENT]Ent,
    cons: [MAX_CON]Con,
};
pub const SK_SZ = 64 + MAX_PT * 24 + MAX_ENT * 32 + MAX_CON * 96;
pub const SK_BYTES: u32 = (SK_SZ + 4095) & ~@as(u32, 4095);
comptime {
    std.debug.assert(@sizeOf(Pt) == 24);
    std.debug.assert(@sizeOf(Ent) == 32);
    std.debug.assert(@sizeOf(Con) == 96);
    std.debug.assert(@offsetOf(Con, "expr") == 36);
    std.debug.assert(@offsetOf(Block, "offset") == 32);
    std.debug.assert(@offsetOf(Block, "pts") == 64);
    std.debug.assert(@offsetOf(Block, "ents") == 64 + MAX_PT * 24);
    std.debug.assert(@offsetOf(Block, "cons") == 64 + MAX_PT * 24 + MAX_ENT * 32);
    std.debug.assert(@sizeOf(Block) == SK_SZ);
}

pub fn bytesOf(b: *const Block) *const [SK_SZ]u8 {
    return @ptrCast(b);
}

// --- blocks ------------------------------------------------------------------

const Node = struct { blk: Block, mark: bool = false };
const A = std.heap.page_allocator;
var nodes: std.ArrayList(*Node) = .empty;
/// Bumped for every block made (collect runs when it moved).
pub var made: u32 = 0;

fn nodeOf(b: *Block) *Node {
    return @fieldParentPtr("blk", b);
}

/// A zeroed block (refs 1, never solved), or null.
fn alloc() ?*Block {
    nodes.ensureUnusedCapacity(A, 1) catch return null;
    const n = A.create(Node) catch return null;
    @memset(std.mem.asBytes(&n.blk), 0);
    n.mark = false;
    n.blk.refs = 1;
    n.blk.bytes = SK_BYTES;
    n.blk.dof = -1;
    nodes.appendAssumeCapacity(n);
    made +%= 1;
    return &n.blk;
}

/// sk_new: a new empty sketch on this plane.
pub fn new(plane: u32) ?*Block {
    const b = alloc() orelse return null;
    b.plane = plane;
    return b;
}

/// A copy of a block (all of it, as rep movsb), refs 1.
pub fn copy(src: *const Block) ?*Block {
    const b = alloc() orelse return null;
    b.* = src.*;
    b.refs = 1;
    return b;
}

/// How many blocks are alive (tests, the memory readout).
pub fn liveCount() usize {
    return nodes.items.len;
}

/// Free the blocks nobody marked: `mark` is called with a function that marks
/// a block as still held (the scene's objects, the undo steps).
pub fn collect(markAll: *const fn (*const fn (*Block) void) void) void {
    if (nodes.items.len == 0) return;
    for (nodes.items) |n| n.mark = false;
    markAll(markOne);
    var k: usize = 0;
    for (nodes.items) |n| {
        if (n.mark) {
            nodes.items[k] = n;
            k += 1;
        } else A.destroy(n);
    }
    nodes.items.len = k;
}
fn markOne(b: *Block) void {
    nodeOf(b).mark = true;
}

// --- adding ------------------------------------------------------------------

/// sk_add_point -> its index or -1
pub fn addPoint(sk: *Block, x: f64, y: f64) i32 {
    const n = sk.npt;
    if (n >= MAX_PT) return -1;
    sk.pts[n].x = x;
    sk.pts[n].y = y;
    sk.pts[n].flags = 0;
    sk.npt += 1;
    return @intCast(n);
}

fn ent(sk: *Block, typ: u32, p0: i32, p1: i32, p2: i32, r: f64) i32 {
    const n = sk.nent;
    if (n >= MAX_ENT) return -1;
    const e = &sk.ents[n];
    e.typ = typ;
    e.p = .{ p0, p1, p2 };
    e.r = r;
    e.flags = 0;
    sk.nent += 1;
    return @intCast(n);
}

pub fn addLine(sk: *Block, a: i32, b: i32) i32 {
    return ent(sk, E_LINE, a, b, -1, 0);
}
pub fn addCircle(sk: *Block, c: i32, r: f64) i32 {
    return ent(sk, E_CIRCLE, c, -1, -1, r);
}
/// An arc, counter-clockwise from start to end.
pub fn addArc(sk: *Block, c: i32, s: i32, e: i32, r: f64) i32 {
    return ent(sk, E_ARC, c, s, e, r);
}

/// sk_add_con -> the constraint or -1. Side information (a fixed position,
/// the tangent side) is taken from the geometry as it is.
pub fn addCon(sk: *Block, typ: u32, a: i32, b: i32, c: i32, value: f64, expr: ?[]const u8) i32 {
    if (sk.ncon >= MAX_CON) return -1;
    if (typ -% 1 >= NCTYPES) return -1;
    const k = sk.ncon;
    const cn = &sk.cons[k];
    cn.typ = typ;
    cn.a = a;
    cn.b = b;
    cn.c = c;
    cn.val = value;
    cn.val2 = 0;
    cn.flags = 0;
    cn.expr[0] = 0;
    if (expr) |t| {
        // up to 59 characters, then a 0 (the rest of the record stays as it was)
        var i: usize = 0;
        while (true) {
            const ch: u8 = if (i < t.len) t[i] else 0;
            cn.expr[i] = ch;
            if (ch == 0) break;
            i += 1;
            if (i >= 59) {
                cn.expr[i] = 0;
                break;
            }
        }
    }
    if (typ == C_FIXED) {
        if (ptOk(sk, a)) {
            cn.val = sk.pts[@intCast(a)].x;
            cn.val2 = sk.pts[@intCast(a)].y;
        }
    } else if (typ == C_TANGENT) {
        cn.val2 = tangentSide(sk, cn);
    }
    sk.ncon += 1;
    return @intCast(k);
}

fn ptOk(sk: *const Block, p: i32) bool {
    _ = sk;
    return p >= 0 and p < MAX_PT;
}
fn entOk(e: i32) bool {
    return e >= 0 and e < MAX_ENT;
}

/// The stored point (0, 0 for an index out of the table).
fn pxy(sk: *const Block, p: i32) [2]f64 {
    if (p < 0 or p >= MAX_PT) return .{ 0, 0 };
    const q = &sk.pts[@intCast(p)];
    return .{ q.x, q.y };
}

/// line-circle: the side of the centre (+1 / -1), the line first;
/// circle-circle: +1 outside, -1 inside
fn tangentSide(sk: *Block, cn: *Con) f64 {
    if (!entOk(cn.a) or !entOk(cn.b)) return 1;
    var ea = &sk.ents[@intCast(cn.a)];
    var eb = &sk.ents[@intCast(cn.b)];
    if (ea.typ != E_LINE) {
        if (eb.typ == E_LINE) {
            std.mem.swap(*Ent, &ea, &eb);
            std.mem.swap(i32, &cn.a, &cn.b);
        } else {
            const c1 = pxy(sk, ea.p[0]);
            const c2 = pxy(sk, eb.p[0]);
            const dx = c2[0] - c1[0];
            const dy = c2[1] - c1[1];
            const d = @sqrt(dx * dx + dy * dy);
            const rm = maxsd(ea.r, eb.r);
            return if (d >= rm) 1 else -1;
        }
    }
    const a = pxy(sk, ea.p[0]);
    const b = pxy(sk, ea.p[1]);
    const ux = b[0] - a[0];
    const uy = b[1] - a[1];
    const c = pxy(sk, eb.p[0]);
    const vx = c[0] - a[0];
    const vy = c[1] - a[1];
    const cr = ux * vy - uy * vx;
    return if (cr >= 0) 1 else -1;
}

pub fn pointXY(sk: *const Block, p: i32) [2]f64 {
    return pxy(sk, p);
}

/// sk_ent_point: the entity's point (which 0..2) or -1
pub fn entPoint(sk: *const Block, e: i32, which: i32) i32 {
    if (e < 0 or @as(u32, @intCast(e)) >= sk.nent or e >= MAX_ENT) return -1;
    if (which < 0 or which >= 3) return -1;
    return sk.ents[@intCast(e)].p[@intCast(which)];
}

pub const con_names = [_][]const u8{ "", "coincident", "horizontal", "vertical", "parallel", "perpendicular", "equal", "tangent", "fixed", "distance", "hdistance", "vdistance", "radius", "angle", "online", "oncircle", "midpoint", "symmetric", "length", "diameter" };
const con_neq = [_]u8{ 0, 2, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1 };

/// sk_con_type: the type of a constraint name, or -1
pub fn conType(name: []const u8) i32 {
    for (con_names[1..], 1..) |n, i| {
        if (std.mem.eql(u8, n, name)) return @intCast(i);
    }
    return -1;
}

// --- the instructions as the original uses them -----------------------------

/// maxsd a, b: a when a > b, else b (b also when either is NaN)
inline fn maxsd(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}

// The x87 as the original uses it: atan2 by fpatan, sine and cosine by
// fsincos, in extended precision, stored as doubles. Machine code in .text
// (neither inline nor global assembly works with every Zig backend; bytes
// do), called with rdi = &m[0]: no page made executable at run time.

const use_x87 = builtin.cpu.arch == .x86_64;

// fld qword [rdi]; fsincos; fstp qword [rdi+8] (cos); fstp qword [rdi] (sin); ret
export const bee_sk_x87_sincos: [10]u8 linksection(".text") = .{ 0xdd, 0x07, 0xd9, 0xfb, 0xdd, 0x5f, 0x08, 0xdd, 0x1f, 0xc3 };

/// atan2 as fld y; fld x; fpatan; fstp qword.
pub fn fpatan(y: f64, x: f64) f64 {
    return @import("animexpr.zig").atan2x87(y, x);
}

/// fld a; fsincos; fstp cos; fstp sin -> .{ sin, cos }
pub fn fsincos(a: f64) [2]f64 {
    if (!use_x87) return .{ @sin(a), @cos(a) };
    return run87(&bee_sk_x87_sincos, a);
}

// (the code through a slice: a function pointer cast straight from the
// constant's address calls 0 in Debug builds)
fn run87(code: []const u8, a: f64) [2]f64 {
    var m: [2]f64 = .{ a, 0 };
    const f: *const fn (*[2]f64) callconv(.c) void = @ptrCast(code.ptr);
    f(&m);
    return m;
}

// --- the solver's state (sketch.s keeps it in .bss: one solve at a time) -----

const tiny: f64 = 1.0e-300;
const sd_h: f64 = 1.0e-7; // finite-difference step (relative)
const sd_tol: f64 = 1.0e-9; // converged residual (relative)
const sd_rank: f64 = 1.0e-7; // rank tolerance (relative)
const sd_null: f64 = 1.0e-6;
const sd_mu: f64 = 1.0e-10; // regularises null directions
const sd_lam0: f64 = 1.0e-3;
const sd_up: f64 = 4.0;
const sd_down: f64 = 0.33333333333;
const sd_lmax: f64 = 1.0e12;
const sd_pi: f64 = 3.14159265358979323846;
const sd_2pi: f64 = 6.28318530717958647692;

var sv_sk: *Block = undefined;
var sv_x: [MAX_VARS]f64 = @splat(0);
var sv_nv: u32 = 0;
var sv_neq: u32 = 0;
var sv_eqc: [MAX_EQS]i32 = @splat(0); // equation -> constraint (or -1 - entity)
var sv_eqk: [MAX_EQS]u8 = @splat(0); // which of its equations
var sv_eqvars: [MAX_EQS][8]i32 = @splat(@splat(0)); // up to 8 unknowns (-1 end)
var sv_eqval: [MAX_EQS]f64 = @splat(0);
var sv_parent: [MAX_VARS]u32 = @splat(0);
var sv_comp: [MAX_VARS]u32 = @splat(0);
var sv_entvar: [MAX_ENT]i32 = @splat(-1);
var sv_free: [MAX_VARS]u8 = @splat(0);
var sv_cv: [MAX_VARS]u32 = @splat(0);
var sv_ce: [MAX_EQS]u32 = @splat(0);
var sv_f: [MAX_EQS]f64 = @splat(0);
var sv_f2: [MAX_EQS]f64 = @splat(0);
var sv_scale: f64 = 1;
var sv_mat: []f64 = &.{};
var sv_dof: i32 = 0;

/// The unknowns of point p (an index outside the table reads nothing).
fn pv(p: i32) [2]f64 {
    if (p < 0 or p >= MAX_PT) return .{ 0, 0 };
    const k: usize = @intCast(p);
    return .{ sv_x[2 * k], sv_x[2 * k + 1] };
}
fn entp(e: i32, which: usize) i32 {
    if (!entOk(e)) return -1;
    return sv_sk.ents[@intCast(e)].p[which];
}
fn entr(e: i32) f64 {
    if (!entOk(e)) return 0;
    const v = sv_entvar[@intCast(e)];
    if (v < 0 or v >= MAX_VARS) return 0;
    return sv_x[@intCast(v)];
}
fn etype(e: i32) u32 {
    if (!entOk(e)) return 0;
    return sv_sk.ents[@intCast(e)].typ;
}
/// b - a of a line, and a
fn ldir(e: i32) [4]f64 {
    const a = pv(entp(e, 0));
    const b = pv(entp(e, 1));
    return .{ b[0] - a[0], b[1] - a[1], a[0], a[1] };
}
inline fn len2(x: f64, y: f64) f64 {
    return @sqrt(x * x + y * y);
}

/// The residual of equation q.
fn resid(q: usize) f64 {
    const cidx = sv_eqc[q];
    const k = sv_eqk[q];
    const value = sv_eqval[q];
    if (cidx < 0) {
        // an arc's start / end on its circle
        const e = ~cidx;
        const c = pv(entp(e, 0));
        const p = pv(entp(e, @as(usize, k) + 1));
        return len2(p[0] - c[0], p[1] - c[1]) - entr(e);
    }
    const cn = &sv_sk.cons[@intCast(cidx)];
    switch (cn.typ) {
        C_COINCIDENT => {
            const p = pv(cn.a);
            const r = pv(cn.b);
            return if (k == 0) p[0] - r[0] else p[1] - r[1];
        },
        C_HORIZONTAL => return ldir(cn.a)[1],
        C_VERTICAL => return ldir(cn.a)[0],
        C_PARALLEL, C_PERP => {
            const d1 = ldir(cn.a);
            const d2 = ldir(cn.b);
            const num = if (cn.typ == C_PARALLEL) d1[0] * d2[1] - d1[1] * d2[0] else d1[0] * d2[0] + d1[1] * d2[1];
            const l1 = len2(d1[0], d1[1]);
            const l2 = len2(d2[0], d2[1]);
            return num / maxsd(l2 * l1, tiny);
        },
        C_EQUAL => {
            if (etype(cn.a) == E_LINE) {
                const d1 = ldir(cn.a);
                const l1 = len2(d1[0], d1[1]);
                const d2 = ldir(cn.b);
                return l1 - len2(d2[0], d2[1]);
            }
            const r1 = entr(cn.a);
            return r1 - entr(cn.b);
        },
        C_TANGENT => {
            if (etype(cn.a) == E_LINE) {
                // side * dist(c, line) - r
                const d = ldir(cn.a);
                const c = pv(entp(cn.b, 0));
                const vx = c[0] - d[2];
                const vy = c[1] - d[3];
                const cr = vy * d[0] - vx * d[1];
                const s = cr / maxsd(len2(d[0], d[1]), tiny) * cn.val2;
                return s - entr(cn.b);
            }
            // circles: |c1 c2| - (r1 + r2) outside, |r1 - r2| inside
            const c1 = pv(entp(cn.a, 0));
            const c2 = pv(entp(cn.b, 0));
            const dist = len2(c2[0] - c1[0], c2[1] - c1[1]);
            const r1 = entr(cn.a);
            const r2 = entr(cn.b);
            const rr = if (!(cn.val2 >= 0)) @abs(r2 - r1) else r2 + r1;
            return dist - rr;
        },
        C_FIXED => {
            const p = pv(cn.a);
            return if (k == 0) p[0] - cn.val else p[1] - cn.val2;
        },
        C_DISTANCE, C_HDIST, C_VDIST => {
            const p = pv(cn.a);
            const r = pv(cn.b);
            const dx = r[0] - p[0];
            const dy = r[1] - p[1];
            const v = switch (cn.typ) {
                C_HDIST => dx,
                C_VDIST => dy,
                else => len2(dx, dy),
            };
            return v - value;
        },
        C_LENGTH => {
            const d = ldir(cn.a);
            return len2(d[0], d[1]) - value;
        },
        C_RADIUS => return entr(cn.a) - value,
        C_DIAMETER => {
            const r = entr(cn.a);
            return (r + r) - value;
        },
        C_ANGLE => {
            const d1 = ldir(cn.a);
            const d2 = ldir(cn.b);
            const cr = d1[0] * d2[1] - d1[1] * d2[0];
            const dt = d1[0] * d2[0] + d1[1] * d2[1];
            var r = fpatan(cr, dt) - value;
            // into (-pi, pi]; (the original loops for ever on NaN or a huge value)
            if (std.math.isNan(r)) return r;
            if (@abs(r) > 1.0e8) r = @rem(r, sd_2pi);
            if (std.math.isNan(r)) return r; // (an infinite angle: NaN after the remainder)
            while (r > sd_pi) r -= sd_2pi;
            while (!(r > -sd_pi)) r += sd_2pi;
            return r;
        },
        C_ONLINE => {
            const d = ldir(cn.b);
            const p = pv(cn.a);
            const vx = p[0] - d[2];
            const vy = p[1] - d[3];
            const cr = vy * d[0] - vx * d[1];
            return cr / maxsd(len2(d[0], d[1]), tiny);
        },
        C_ONCIRCLE => {
            const c = pv(entp(cn.b, 0));
            const p = pv(cn.a);
            const l = len2(p[0] - c[0], p[1] - c[1]);
            return l - entr(cn.b);
        },
        C_MIDPOINT => {
            const d = ldir(cn.b);
            const mx = d[0] * 0.5 + d[2];
            const my = d[1] * 0.5 + d[3];
            const p = pv(cn.a);
            return if (k == 0) p[0] - mx else p[1] - my;
        },
        C_SYMMETRIC => {
            const d = ldir(cn.c);
            const pa = pv(cn.a);
            const pb = pv(cn.b);
            const num = if (k == 0) blk: {
                const mx = (pa[0] + pb[0]) * 0.5 - d[2];
                const my = (pa[1] + pb[1]) * 0.5 - d[3];
                break :blk my * d[0] - mx * d[1];
            } else (pb[0] - pa[0]) * d[0] + (pb[1] - pa[1]) * d[1];
            return num / maxsd(len2(d[0], d[1]), tiny);
        },
        else => return 0,
    }
}

// --- setup: unknowns, equations, their unknowns, components ---------------------

const VarList = struct {
    v: *[8]i32,
    n: usize = 0,
    fn put(l: *VarList, x: i32) void {
        if (l.n < 8) l.v[l.n] = x;
        l.n += 1;
    }
    fn pt(l: *VarList, p: i32) void {
        l.put(p +% p);
        l.put(p +% p +% 1);
    }
    /// the entity's points (a line) or its centre and radius
    fn ent(l: *VarList, e: i32) void {
        if (!entOk(e)) {
            l.pt(-1);
            l.pt(-1);
            return;
        }
        const en = &sv_sk.ents[@intCast(e)];
        l.pt(en.p[0]);
        if (en.typ == E_LINE) {
            l.pt(en.p[1]);
        } else l.put(sv_entvar[@intCast(e)]);
    }
};

fn eqVars(q: usize) void {
    var l = VarList{ .v = &sv_eqvars[q] };
    const cidx = sv_eqc[q];
    if (cidx < 0) {
        // an arc: centre, the point, radius
        const e = ~cidx;
        const en = &sv_sk.ents[@intCast(e)];
        l.pt(en.p[0]);
        l.pt(en.p[@as(usize, sv_eqk[q]) + 1]);
        l.put(sv_entvar[@intCast(e)]);
    } else {
        const cn = &sv_sk.cons[@intCast(cidx)];
        switch (cn.typ) {
            C_COINCIDENT, C_DISTANCE, C_HDIST, C_VDIST => {
                l.pt(cn.a);
                l.pt(cn.b);
            },
            C_FIXED => l.pt(cn.a),
            C_ONLINE, C_ONCIRCLE, C_MIDPOINT => {
                l.pt(cn.a);
                l.ent(cn.b);
            },
            C_SYMMETRIC => {
                l.pt(cn.a);
                l.pt(cn.b);
                l.ent(cn.c);
            },
            else => {
                l.ent(cn.a);
                switch (cn.typ) {
                    C_HORIZONTAL, C_VERTICAL, C_RADIUS, C_DIAMETER, C_LENGTH => {},
                    else => l.ent(cn.b),
                }
            },
        }
    }
    if (l.n < 8) l.v[l.n] = -1;
}

fn find(x0: u32) u32 {
    var x = x0;
    while (true) {
        const p = sv_parent[x];
        if (p == x) return x;
        const g = sv_parent[p];
        sv_parent[x] = g;
        x = g;
    }
}

/// Whether the constraint's references exist and fit.
fn checkRefs(sk: *const Block, cn: *const Con) bool {
    const t = cn.typ;
    const a: u32 = @bitCast(cn.a);
    const b: u32 = @bitCast(cn.b);
    const isLine = struct {
        fn f(s: *const Block, e: u32) bool {
            return s.ents[e].typ == E_LINE;
        }
    }.f;
    switch (t) {
        C_FIXED => return a < sk.npt,
        C_COINCIDENT, C_DISTANCE, C_HDIST, C_VDIST => return a < sk.npt and b < sk.npt,
        C_SYMMETRIC => {
            if (a >= sk.npt or b >= sk.npt) return false;
            const c: u32 = @bitCast(cn.c);
            if (c >= sk.nent) return false;
            return isLine(sk, c);
        },
        C_ONLINE, C_ONCIRCLE, C_MIDPOINT => {
            if (a >= sk.npt or b >= sk.nent) return false;
            const bl = isLine(sk, b);
            return if (t == C_ONCIRCLE) !bl else bl;
        },
        else => {},
    }
    if (a >= sk.nent) return false;
    switch (t) {
        C_HORIZONTAL, C_VERTICAL, C_LENGTH => return isLine(sk, a),
        C_RADIUS, C_DIAMETER => return !isLine(sk, a),
        else => {},
    }
    if (b >= sk.nent) return false;
    switch (t) {
        C_EQUAL => return isLine(sk, a) == isLine(sk, b),
        C_TANGENT => return !(isLine(sk, a) and isLine(sk, b)),
        else => return isLine(sk, a) and isLine(sk, b), // parallel, perpendicular, angle: lines
    }
}

/// The value of a constraint with an expression (sketch dimensions with
/// parameters): set by the app (cad.zig's evaluator); null: none (the value
/// stays as stored).
pub var evalExpr: ?*const fn ([]const u8) ?f64 = null;

/// Whether the entity's points are in the table (a damaged file, or an entity
/// whose point went, has some that are not: it takes no part).
fn entSane(sk: *const Block, e: u32) bool {
    const en = &sk.ents[e];
    const np: usize = switch (en.typ) {
        E_LINE => 2,
        E_CIRCLE => 1,
        E_ARC => 3,
        else => return false,
    };
    for (en.p[0..np]) |p| {
        if (p < 0 or p >= sk.npt) return false;
    }
    return true;
}

fn setup(sk: *Block) void {
    // unknowns: points, then radii
    var i: usize = 0;
    while (i < sk.npt) : (i += 1) {
        sv_x[2 * i] = sk.pts[i].x;
        sv_x[2 * i + 1] = sk.pts[i].y;
    }
    var nv: u32 = @intCast(2 * sk.npt);
    i = 0;
    while (i < sk.nent) : (i += 1) {
        sv_entvar[i] = -1;
        if (sk.ents[i].typ == E_LINE) continue;
        sv_entvar[i] = @intCast(nv);
        sv_x[nv] = sk.ents[i].r;
        nv += 1;
    }
    sv_nv = nv;
    // equations: arcs
    var neq: u32 = 0;
    i = 0;
    while (i < sk.nent) : (i += 1) {
        if (sk.ents[i].typ != E_ARC or !entSane(sk, @intCast(i))) continue;
        const e: i32 = @intCast(i);
        sv_eqc[neq] = ~e;
        sv_eqc[neq + 1] = ~e;
        sv_eqk[neq] = 0;
        sv_eqk[neq + 1] = 1;
        neq += 2;
    }
    // constraints
    i = 0;
    while (i < sk.ncon) : (i += 1) {
        const cn = &sk.cons[i];
        cn.flags &= ~F_BAD;
        if (!checkRefs(sk, cn) or !consSane(sk, cn)) {
            cn.flags |= F_BAD; // unusable: a conflict
            continue;
        }
        var value = cn.val;
        if (cn.expr[0] != 0) {
            const f = evalExpr orelse null;
            if (f) |fun| {
                const t = std.mem.sliceTo(&cn.expr, 0);
                if (fun(t)) |v| {
                    value = v;
                    cn.val = v; // (keep the last good value)
                } else {
                    cn.flags |= F_BAD;
                    continue;
                }
            }
        }
        // (a type out of the table - a damaged file - is checked as two lines
        // and makes no equation: what the original's checks do with it)
        const ne = if (cn.typ < con_neq.len) con_neq[cn.typ] else 0;
        var k: u8 = 0;
        while (k < ne) : (k += 1) {
            if (neq >= MAX_EQS) break;
            sv_eqc[neq] = @intCast(i);
            sv_eqk[neq] = k;
            sv_eqval[neq] = value;
            neq += 1;
        }
    }
    sv_neq = neq;
    var q: usize = 0;
    while (q < neq) : (q += 1) eqVars(q);
    // components (union-find)
    var v: u32 = 0;
    while (v < sv_nv) : (v += 1) sv_parent[v] = v;
    q = 0;
    while (q < neq) : (q += 1) {
        const vs = &sv_eqvars[q];
        const r0 = find(@intCast(vs[0]));
        var j: usize = 1;
        while (j < 8) : (j += 1) {
            if (vs[j] < 0) break;
            const r = find(@intCast(vs[j]));
            sv_parent[r] = r0;
        }
    }
    v = 0;
    while (v < sv_nv) : (v += 1) sv_comp[v] = find(v);
}

/// The entities a constraint names have their points in the table (the
/// original reads past them; here such a constraint is a conflict).
fn consSane(sk: *const Block, cn: *const Con) bool {
    const kinds = conKinds(cn.typ);
    const refs = [3]i32{ cn.a, cn.b, cn.c };
    for (kinds, refs) |kd, r| {
        if (kd == 2 and !entSane(sk, @intCast(r))) return false;
    }
    return true;
}

// --- solving one component ----------------------------------------------------------

fn compResid(out: []f64, m: usize) void {
    for (0..m) |i| out[i] = resid(sv_ce[i]);
}

fn sumsq(f: []const f64, m: usize) f64 {
    var s: f64 = 0;
    var i = m;
    while (i > 0) {
        i -= 1;
        s += f[i] * f[i];
    }
    return s;
}

const Mats = struct { J: []f64, A: []f64, M: []f64, g: []f64, d: []f64, x0: []f64 };

/// J[i][j] = d f_i / d x_j by forward differences (sv_f holds f)
fn jacobian(J: []f64, m: usize, n: usize) void {
    for (0..n) |j| {
        const v = sv_cv[j];
        const x = sv_x[v];
        const h = (@abs(x) + 1.0) * sd_h;
        sv_x[v] = x + h;
        compResid(&sv_f2, m);
        sv_x[v] = x;
        for (0..m) |i| J[i * n + j] = (sv_f2[i] - sv_f[i]) / h;
    }
}

/// A = J^T J, g = J^T f
fn normalEq(mt: *const Mats, m: usize, n: usize) void {
    for (0..n) |a| {
        for (0..n) |b| {
            var s: f64 = 0;
            for (0..m) |r| s += mt.J[r * n + a] * mt.J[r * n + b];
            mt.A[a * n + b] = s;
        }
        var s: f64 = 0;
        for (0..m) |r| s += mt.J[r * n + a] * sv_f[r];
        mt.g[a] = s;
    }
}

/// d from (A + lambda diag(A) + mu) d = -g by Cholesky; false: not positive
fn lmStep(mt: *const Mats, n: usize, lambda: f64) bool {
    const M = mt.M;
    for (0..n) |i| {
        for (0..n) |j| {
            var v = mt.A[i * n + j];
            if (i == j) {
                v = v + v * lambda;
                v += sd_mu;
            }
            M[i * n + j] = v;
        }
    }
    for (0..n) |i| {
        var j: usize = 0;
        while (j <= i) : (j += 1) {
            var s = M[i * n + j];
            for (0..j) |k| s -= M[i * n + k] * M[j * n + k];
            if (i == j) {
                if (!(s > 0)) return false;
                s = @sqrt(s);
            } else s /= M[j * n + j];
            M[i * n + j] = s;
        }
    }
    const d = mt.d;
    for (0..n) |i| {
        var s = -mt.g[i];
        for (0..i) |j| s -= M[i * n + j] * d[j];
        d[i] = s / M[i * n + i];
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        var s = d[i];
        for (i + 1..n) |j| s -= M[j * n + i] * d[j];
        d[i] = s / M[i * n + i];
    }
    return true;
}

/// Row-reduce J to find the pivot columns; unknowns some null-space vector
/// moves are free; DOF += n - rank.
fn rankFree(J: []f64, piv: []i32, m: usize, n: usize) void {
    var tol: f64 = 0;
    for (J[0 .. m * n]) |x| tol = maxsd(tol, @abs(x));
    tol = tol * sd_rank + tiny;
    var rank: usize = 0;
    for (0..n) |col| {
        piv[col] = -1;
        const r0 = rank;
        if (r0 >= m) continue;
        var best: f64 = 0;
        var br: i64 = -1;
        for (r0..m) |r| {
            const a = @abs(J[r * n + col]);
            if (a > best) {
                best = a;
                br = @intCast(r);
            }
        }
        if (!(best > tol)) continue; // no pivot: a free column
        const b: usize = @intCast(br);
        if (b != r0) {
            for (0..n) |c| std.mem.swap(f64, &J[r0 * n + c], &J[b * n + c]);
        }
        piv[col] = @intCast(r0);
        const p = J[r0 * n + col];
        for (0..n) |c| J[r0 * n + c] /= p;
        for (0..m) |r| {
            if (r == r0) continue;
            const f = J[r * n + col];
            if (f == 0) continue;
            for (0..n) |c| J[r * n + c] -= J[r0 * n + c] * f;
        }
        rank += 1;
    }
    sv_dof += @intCast(n - rank);
    // a free column moves itself and every pivot unknown whose row has an
    // entry in it
    for (0..n) |f| {
        if (piv[f] != -1) continue;
        sv_free[sv_cv[f]] = 1;
        for (0..n) |c| {
            const row = piv[c];
            if (row < 0) continue;
            if (@abs(J[@as(usize, @intCast(row)) * n + f]) > sd_null) sv_free[sv_cv[c]] = 1;
        }
    }
}

fn solveComp(root: u32) void {
    var n: usize = 0;
    var v: u32 = 0;
    while (v < sv_nv) : (v += 1) {
        if (sv_comp[v] != root) continue;
        sv_cv[n] = v;
        n += 1;
    }
    var m: usize = 0;
    var q: u32 = 0;
    while (q < sv_neq) : (q += 1) {
        const v0 = sv_eqvars[q][0];
        if (v0 < 0 or v0 >= MAX_VARS or sv_comp[@intCast(v0)] != root) continue;
        sv_ce[m] = q;
        m += 1;
    }
    if (m == 0) {
        for (0..n) |k| sv_free[sv_cv[k]] = 1;
        sv_dof += @intCast(n);
        return;
    }
    // scratch: J (m n), A (n n), M (n n), g (n), d (n), x0 (n)
    const need = m * n + 2 * n * n + 4 * n + 16;
    if (need > sv_mat.len) {
        if (sv_mat.len > 0) A.free(sv_mat);
        sv_mat = A.alloc(f64, need) catch {
            sv_mat = &.{};
            return;
        };
    }
    const base = sv_mat;
    const mt = Mats{
        .J = base[0 .. m * n],
        .A = base[m * n ..][0 .. n * n],
        .M = base[m * n + n * n ..][0 .. n * n],
        .g = base[m * n + 2 * n * n ..][0..n],
        .d = base[m * n + 2 * n * n + n ..][0..n],
        .x0 = base[m * n + 2 * n * n + 2 * n ..][0..n],
    };
    var lambda = sd_lam0;
    var iters: u32 = 0;
    compResid(&sv_f, m);
    var cost = sumsq(&sv_f, m);
    const tol = sd_tol * sv_scale;
    const tol2 = tol * tol;
    outer: while (true) {
        // converged?
        if (!(cost > tol2)) break;
        if (iters >= MAX_ITER) break;
        iters += 1;
        jacobian(mt.J, m, n);
        normalEq(&mt, m, n);
        while (true) {
            if (lmStep(&mt, n, lambda)) {
                for (0..n) |k| {
                    const vk = sv_cv[k];
                    const x = sv_x[vk];
                    mt.x0[k] = x;
                    sv_x[vk] = x + mt.d[k];
                }
                compResid(&sv_f2, m);
                const c2 = sumsq(&sv_f2, m);
                if (!(c2 >= cost)) {
                    // better: keep, lambda down
                    cost = c2;
                    @memcpy(sv_f[0..m], sv_f2[0..m]);
                    lambda *= sd_down;
                    continue :outer;
                }
                // worse: back
                for (0..n) |k| sv_x[sv_cv[k]] = mt.x0[k];
            }
            // lambda up
            lambda *= sd_up;
            if (lambda > sd_lmax) break :outer;
            iters += 1;
            if (iters >= MAX_ITER * 2) break :outer;
        }
    }
    // rank and null space at the result
    jacobian(mt.J, m, n);
    const piv: []i32 = @as([*]i32, @ptrCast(mt.x0.ptr))[0..n];
    rankFree(mt.J, piv, m, n);
}

/// Equations whose residual stayed are conflicts.
fn markBad(sk: *Block) void {
    const lim = sd_tol * sv_scale * sd_up * sd_up;
    var q: usize = 0;
    while (q < sv_neq) : (q += 1) {
        const r = @abs(resid(q));
        if (!(r > lim)) continue;
        const c = sv_eqc[q];
        if (c < 0) continue;
        sk.cons[@intCast(c)].flags |= F_BAD;
    }
}

/// sk_solve -> the degrees of freedom left (dof), nbad conflicts; the points,
/// radii and status flags are updated.
pub fn solve(sk: *Block) i32 {
    if (sk.npt > MAX_PT or sk.nent > MAX_ENT or sk.ncon > MAX_CON) return sk.dof;
    sv_sk = sk;
    setup(sk);
    sv_dof = 0;
    @memset(&sv_free, 0);
    var s: f64 = 1;
    for (sv_x[0..sv_nv]) |x| s = maxsd(s, @abs(x));
    sv_scale = s;
    var v: u32 = 0;
    while (v < sv_nv) : (v += 1) {
        if (sv_comp[v] == v) solveComp(v);
    }
    markBad(sk);
    // write back: points
    var i: usize = 0;
    while (i < sk.npt) : (i += 1) {
        sk.pts[i].x = sv_x[2 * i];
        sk.pts[i].y = sv_x[2 * i + 1];
        sk.pts[i].flags &= ~F_FULL; // fully constrained: neither x nor y free
        if (sv_free[2 * i] == 0 and sv_free[2 * i + 1] == 0) sk.pts[i].flags |= F_FULL;
    }
    // radii, entity status
    i = 0;
    while (i < sk.nent) : (i += 1) {
        const e = &sk.ents[i];
        e.flags &= ~F_FULL;
        var f: u32 = F_FULL;
        f &= pfull(e.p[0]);
        if (e.typ != E_CIRCLE) {
            f &= pfull(e.p[1]);
            if (e.typ != E_LINE) f &= pfull(e.p[2]);
        }
        if (e.typ != E_LINE) {
            const rv = sv_entvar[i];
            if (rv >= 0 and rv < MAX_VARS) {
                e.r = sv_x[@intCast(rv)];
                if (sv_free[@intCast(rv)] != 0) f = 0;
            }
        }
        e.flags |= f;
    }
    sk.dof = sv_dof;
    var bad: u32 = 0;
    i = 0;
    while (i < sk.ncon) : (i += 1) {
        if (sk.cons[i].flags & F_BAD != 0) bad += 1;
    }
    sk.nbad = bad;
    return sk.dof;
}

fn pfull(p: i32) u32 {
    if (p < 0 or p >= MAX_PT) return 0;
    const k: usize = @intCast(p);
    return if (sv_free[2 * k] == 0 and sv_free[2 * k + 1] == 0) F_FULL else 0;
}

// --- deleting -----------------------------------------------------------------------

/// sk_drop_con: remove one constraint (the rest move up; the last slot keeps
/// its old bytes, as the original's)
pub fn dropCon(sk: *Block, k: u32) void {
    if (k >= sk.ncon) return;
    const n = sk.ncon - k - 1;
    const b: [*]u8 = @ptrCast(&sk.cons);
    std.mem.copyForwards(u8, b[k * 96 ..][0 .. n * 96], b[(k + 1) * 96 ..][0 .. n * 96]);
    sk.ncon -= 1;
}

/// ref kinds per constraint type: 1 = point, 2 = entity, 0 = unused (a b c)
const con_kinds = [_][3]u8{
    .{ 0, 0, 0 }, .{ 1, 1, 0 }, .{ 2, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 2, 0 }, .{ 2, 2, 0 }, .{ 2, 2, 0 }, .{ 2, 2, 0 },
    .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 0 }, .{ 2, 0, 0 }, .{ 2, 2, 0 }, .{ 1, 2, 0 }, .{ 1, 2, 0 },
    .{ 1, 2, 0 }, .{ 1, 1, 2 }, .{ 2, 0, 0 }, .{ 2, 0, 0 },
};
fn conKinds(t: u32) [3]u8 {
    return if (t < con_kinds.len) con_kinds[t] else .{ 0, 0, 0 };
}

var dl_ent: [MAX_ENT]u8 = undefined; // 1: delete (in), new index + 1 (out)
var dl_pt: [MAX_PT]i32 = undefined; // new index of each point, -1 kept, -2 gone

fn markPt(p: i32, v: i32) void {
    if (p >= 0 and p < MAX_PT) dl_pt[@intCast(p)] = v;
}

/// The constraint names a deleted entity or a dropped point.
fn conRefsGone(sk: *const Block, cn: *const Con) bool {
    const kinds = conKinds(cn.typ);
    const refs = [3]i32{ cn.a, cn.b, cn.c };
    for (kinds, refs) |kd, r| {
        const u: u32 = @bitCast(r);
        if (kd == 1) {
            if (u >= sk.npt or dl_pt[u] == -2) return true;
        } else if (kd == 2) {
            if (u >= sk.nent or dl_ent[u] != 0) return true;
        }
    }
    return false;
}

/// sk_delete: these entities, then whatever referred to them, then the points
/// nothing uses any more (and these points, when given); indices are compacted.
/// A point an entity that stays still uses is kept (the original dropped it
/// too and left the entity pointing at nothing).
pub fn delete(sk: *Block, ents: *const [MAX_ENT]u8, pts: ?*const [MAX_PT]u8) void {
    dl_ent = ents.*;
    @memset(&dl_pt, -1);
    const ne = @min(sk.nent, MAX_ENT);
    for (0..ne) |i| {
        if (dl_ent[i] == 0) continue;
        for (sk.ents[i].p) |p| markPt(p, -2);
    }
    if (pts) |pm| {
        for (0..@min(sk.npt, MAX_PT)) |i| {
            if (pm[i] != 0) dl_pt[i] = -2;
        }
    }
    // unless a surviving entity uses them
    for (0..ne) |i| {
        if (dl_ent[i] != 0) continue;
        for (sk.ents[i].p) |p| markPt(p, -1);
    }
    // constraints touching deleted entities or dropped points
    var k: u32 = 0;
    while (k < sk.ncon) {
        if (conRefsGone(sk, &sk.cons[k])) {
            dropCon(sk, k);
        } else k += 1;
    }
    // new point indices
    var n: u32 = 0;
    for (0..@min(sk.npt, MAX_PT)) |i| {
        if (dl_pt[i] == -1) {
            dl_pt[i] = @intCast(n);
            sk.pts[n] = sk.pts[i];
            n += 1;
        } else dl_pt[i] = -1;
    }
    sk.npt = n;
    // entities: compact, renumber their points
    var e: u32 = 0;
    for (0..ne) |i| {
        if (dl_ent[i] != 0) {
            dl_ent[i] = 0;
            continue;
        }
        dl_ent[i] = @truncate(e + 1); // (256 wraps, as the original's byte)
        sk.ents[e] = sk.ents[i];
        for (&sk.ents[e].p) |*p| {
            if (p.* >= 0 and p.* < MAX_PT) p.* = dl_pt[@intCast(p.*)];
        }
        e += 1;
    }
    sk.nent = e;
    // constraints: their references
    k = 0;
    while (k < sk.ncon) : (k += 1) {
        const cn = &sk.cons[k];
        const kinds = conKinds(cn.typ);
        const refs = [3]*i32{ &cn.a, &cn.b, &cn.c };
        for (kinds, refs) |kd, r| {
            const u: u32 = @bitCast(r.*);
            if (kd == 1) {
                if (u < MAX_PT) r.* = dl_pt[u];
            } else if (kd == 2) {
                if (u < MAX_ENT) r.* = @as(i32, dl_ent[u]) - 1;
            }
        }
    }
}

// --- geometry for display ------------------------------------------------------------

/// sk_plane_xyz: the plane's local coordinates of (u, v) (floats, as the original)
pub fn planeXyz(sk: *const Block, u: f64, v: f64) [3]f32 {
    const fu: f32 = @floatCast(u);
    const fv: f32 = @floatCast(v);
    const fo: f32 = @floatCast(sk.offset);
    return switch (sk.plane) {
        0 => .{ fu, fv, fo }, // XY: (u, v, offset)
        1 => .{ fu, fo, -fv }, // XZ: (u, offset, -v): v away from the viewer looking down
        else => .{ fo, fv, -fu }, // YZ: (offset, v, -u)
    };
}

/// The i-th of n + 1 points along an entity, in sketch coordinates (u, v).
pub fn entAt(sk: *const Block, e: *const Ent, i: u32, n: u32) [2]f64 {
    if (e.typ == E_LINE) return pxy(sk, if (i == 0) e.p[0] else e.p[1]);
    const c = pxy(sk, e.p[0]);
    var a0: f64 = 0;
    var sweep: f64 = 6.28318530717958647692;
    if (e.typ == E_ARC) {
        const s = pxy(sk, e.p[1]);
        const t = pxy(sk, e.p[2]);
        a0 = fpatan(s[1] - c[1], s[0] - c[0]);
        const a1 = fpatan(t[1] - c[1], t[0] - c[0]);
        sweep = a1 - a0;
        if (!(sweep > 0)) sweep += 6.28318530717958647692;
    }
    const fi: f64 = @floatFromInt(i);
    const fnn: f64 = @floatFromInt(@as(i32, @bitCast(n)));
    const a = fi / fnn * sweep + a0;
    const sc = fsincos(a);
    return .{ sc[1] * e.r + c[0], sc[0] * e.r + c[1] };
}

/// Segments to draw an entity with.
pub fn entSegs(e: *const Ent) u32 {
    return if (e.typ == E_LINE) 1 else 48;
}

// --- tests ---------------------------------------------------------------------------

test "layout and a rectangle solves" {
    const sk = new(0).?;
    const p0 = addPoint(sk, 0, 0);
    const p1 = addPoint(sk, 4, 0.1);
    const l = addLine(sk, p0, p1);
    _ = addCon(sk, C_HORIZONTAL, l, -1, -1, 0, null);
    _ = addCon(sk, C_LENGTH, l, -1, -1, 3, null);
    _ = addCon(sk, C_FIXED, p0, -1, -1, 0, null);
    const dof = solve(sk);
    try std.testing.expectEqual(@as(i32, 0), dof);
    try std.testing.expectApproxEqAbs(@as(f64, 3), sk.pts[1].x, 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0), sk.pts[1].y, 1e-7);
    try std.testing.expect(sk.ents[0].flags & F_FULL != 0);
    try std.testing.expectEqual(@as(u32, 0), sk.nbad);
}

test "conflicts and degrees of freedom" {
    const sk = new(1).?;
    const p0 = addPoint(sk, 0, 0);
    const p1 = addPoint(sk, 1, 1);
    const l = addLine(sk, p0, p1);
    _ = addCon(sk, C_HORIZONTAL, l, -1, -1, 0, null);
    _ = addCon(sk, C_VERTICAL, l, -1, -1, 0, null);
    _ = addCon(sk, C_LENGTH, l, -1, -1, 2, null);
    _ = solve(sk);
    try std.testing.expect(sk.nbad > 0);
    const s2 = new(0).?;
    _ = addCircle(s2, addPoint(s2, 0, 0), 1);
    try std.testing.expectEqual(@as(i32, 3), solve(s2));
}

test "delete compacts and drops what referred" {
    const sk = new(0).?;
    const a = addPoint(sk, 0, 0);
    const b = addPoint(sk, 1, 0);
    const c = addPoint(sk, 1, 1);
    const l0 = addLine(sk, a, b);
    const l1 = addLine(sk, b, c);
    _ = addCon(sk, C_HORIZONTAL, l0, -1, -1, 0, null);
    _ = addCon(sk, C_VERTICAL, l1, -1, -1, 0, null);
    var ents: [MAX_ENT]u8 = @splat(0);
    ents[0] = 1;
    delete(sk, &ents, null);
    try std.testing.expectEqual(@as(u32, 2), sk.npt);
    try std.testing.expectEqual(@as(u32, 1), sk.nent);
    try std.testing.expectEqual(@as(u32, 1), sk.ncon);
    try std.testing.expectEqual(C_VERTICAL, sk.cons[0].typ);
    try std.testing.expectEqual(@as(i32, 0), sk.cons[0].a);
    try std.testing.expectEqual([3]i32{ 0, 1, -1 }, sk.ents[0].p);
}

test "x87 bits: as the page the port made at run time gave them" {
    // (input, sin, cos) and (y, x, atan2), captured from the mmap'd page this
    // .text code replaced, in Debug and ReleaseFast: the same bits (1e19 is
    // out of fsincos' range: the operand stays, the second store is empty)
    if (!use_x87) return;
    const sc = [_][3]u64{
        .{ 0x3fe0000000000000, 0x3fdeaee8744b05f0, 0x3fec1528065b7d50 },
        .{ 0x43e158e460913d00, 0xfff8000000000000, 0x43e158e460913d00 },
        .{ 0xc006000000000000, 0xbfd86d2239c183fb, 0xbfed93e294faed14 },
        .{ 0x01a56e1fc2f8f359, 0x01a56e1fc2f8f359, 0x3ff0000000000000 },
        .{ 0x41124f8000000000, 0x3fbb6885f8d1df2a, 0xbfefd0e9ec921065 },
    };
    for (sc) |t| {
        const r = fsincos(@bitCast(t[0]));
        try std.testing.expectEqual(t[1], @as(u64, @bitCast(r[0])));
        try std.testing.expectEqual(t[2], @as(u64, @bitCast(r[1])));
    }
    const at = [_][3]u64{
        .{ 0x3ff0000000000000, 0x4008000000000000, 0x3fd4978fa3269ee1 },
        .{ 0xbfd0000000000000, 0xc01c000000000000, 0xc008d8deb6788b7a },
        .{ 0x000012688b70e62b, 0xbff0000000000000, 0x400921fb54442d18 },
        .{ 0x4014000000000000, 0x0000000000000000, 0x3ff921fb54442d18 },
    };
    for (at) |t| try std.testing.expectEqual(t[2], @as(u64, @bitCast(fpatan(@bitCast(t[0]), @bitCast(t[1])))));
}

test "x87 atan2 and sincos" {
    try std.testing.expectEqual(@as(f64, std.math.pi / 4.0), fpatan(1, 1));
    const sc = fsincos(0.5);
    try std.testing.expectApproxEqAbs(@sin(@as(f64, 0.5)), sc[0], 1e-15);
    try std.testing.expectApproxEqAbs(@cos(@as(f64, 0.5)), sc[1], 1e-15);
}
