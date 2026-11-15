// Rigid bodies (rbody.s): the shared layer. The runtime records with the
// original's layouts (BD_*, PT_*, MF_*, CP_*, JR_* ... as extern structs at the
// same offsets), the world's arrays (rb_bd, rb_pt ... as slices), the settings
// of the step, and the vector helpers in the original's operation order
// (DOT3 = dpps 0x71, CROSS, MV3, MTV3, q_rows, rows_q, q_mul).
//
// The files that make the simulation: rbody.zig (the world: build, step,
// broad phase, frames, cache records, the ops), rbshape.zig (bodies and their
// parts: hulls, compounds, meshes' trees, mass), rbnarrow.zig (contacts:
// narrow phase, manifolds), rbsolve.zig (islands, the solver, joints),
// collide.zig (GJK / EPA), nbody.zig (bodies that attract).
//
// Every number goes through the original's single-precision operations in its
// order, so the places match it to the bit.
const std = @import("std");

pub const V4 = @Vector(4, f32);
pub const B4 = @Vector(4, bool);

// ---- the records in the animation block (anim.zig: rb, jt, the world in h.rw) ----

pub const RB_SZ = 80;
pub const RB_MAX = 4096;
pub const RB_UID = 0; // (an oid in memory, a uid in files: anim.zig)
pub const RB_TYPE = 4; // 1 active, 2 passive
pub const RB_SHAPE = 8; // 0 box 1 sphere 2 capsule 3 hull 4 compound 5 mesh 6 plane
pub const RB_MASS = 12;
pub const RB_FRIC = 16;
pub const RB_REST = 20;
pub const RB_DAMP = 24;
pub const RB_FLAGS = 28; // bit 0 RB_INIT holds the start; bit 1 instances; 4-7 group; 16-31 ignored; 0x100 attracts
pub const RB_INIT = 32; // loc rot (radians) scale at the start
pub const RB_VEL = 68;
pub const RBF_GRP = 4;
pub const RBF_IGN = 16;
pub const RBF_ATTR = 0x100;

pub const JT_SZ = 64;
pub const JT_MAX = 16384;
pub const JT_TYPE = 0; // 1 fixed 2 hinge 3 point 4 slider (5: shatter's marker)
pub const JT_A = 4;
pub const JT_B = 8;
pub const JT_PIV = 16;
pub const JT_AXIS = 28;
pub const JT_BRK = 40;
pub const JT_LO = 44;
pub const JT_HI = 48;
pub const JT_MSPD = 52;
pub const JT_MFOR = 56;
pub const JT_FLG = 60;

pub const RW_SZ = 32;
pub const RW_GRAV = 0;
pub const RW_RATE = 12;
pub const RW_ITER = 16;
pub const RW_SET = 20;
pub const RW_SUB = 24;
pub const RW_G = 28;

pub fn rdU(r: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, r[o..][0..4], .little);
}
pub fn wrU(r: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, r[o..][0..4], v, .little);
}
pub fn rdF(r: []const u8, o: usize) f32 {
    return @bitCast(rdU(r, o));
}
pub fn wrF(r: []u8, o: usize, v: f32) void {
    wrU(r, o, @bitCast(v));
}
pub fn rd3(r: []const u8, o: usize) [3]f32 {
    return .{ rdF(r, o), rdF(r, o + 4), rdF(r, o + 8) };
}
/// movups of 3 floats + the next 4 bytes, w cleared (andps rx_xyz).
pub fn rdV3(r: []const u8, o: usize) V4 {
    return .{ rdF(r, o), rdF(r, o + 4), rdF(r, o + 8), 0 };
}

// ---- runtime records ----------------------------------------------------------------

pub const PT_MAXB = 16; // parts a body
pub const HULL_MAX = 64; // points a hull part

/// A body (BD_*, 368 bytes).
pub const Body = struct {
    pos: V4 align(16) = @splat(0), // centre of mass (world)
    q: V4 = @splat(0), // orientation x y z w
    v: V4 = @splat(0),
    w: V4 = @splat(0),
    iil: V4 = @splat(0), // inverse inertia (body axes)
    iiw: [3]V4 = @splat(@splat(0)), // inverse inertia (world), rows
    r: [3]V4 = @splat(@splat(0)), // rotation rows
    com: V4 = @splat(0), // centre of mass in the object (scaled)
    min: V4 = @splat(0),
    max: V4 = @splat(0),
    im: f32 = 0, // 224 inverse mass
    fric: f32 = 0,
    rest: f32 = 0,
    typ: u32 = 0, // 236: 1 moving, 2 static, 3 dormant
    sleep: f32 = 0, // 240 seconds at rest
    asleep: u32 = 0,
    p0: u32 = 0, // 248 its parts
    np: u32 = 0,
    obj: u32 = 0, // 256 its object (oid; the original: a pointer)
    obj_hi: u32 = 0,
    isl: u32 = 0, // 264
    damp: f32 = 0,
    joint: u32 = 0, // 272 in a joint (no contact with its partner)
    inst: u32 = 0, // 276 an instance: its index + 1
    bvh: u32 = 0, // 280 a mesh: its tree's root + 1
    grp: u32 = 0, // 284 its group's bit | groups it does not meet << 16
    scl: V4 = @splat(0), // 288
    pp: V4 = @splat(0), // 304 where the step began
    pq: V4 = @splat(0), // 320
    grp0: u32 = 0, // 336
    am: f32 = 0, // 340 attracting mass (nbody)
    pad0: [2]u32 = .{ 0, 0 },
    nba: V4 = @splat(0), // 352 the bodies' pull this step (nbody)
};

/// A part (PT_*, 64 bytes; collide.zig's too).
pub const Part = struct {
    typ: u32 = 0, // 0 box core, 1 hull, 2 plane, (mesh triangle: hull with flg 1)
    nv: u32 = 0,
    verts: ?[*]V4 = null, // hull points (part-local)
    rad: f32 = 0, // 16
    body: u32 = 0, // 20
    flg: u32 = 0, // 24: 1 a mesh's triangle | active edges (bits 1-3)
    tw: u32 = 0, // 28 a triangle: its corners' slot (world)
    half: V4 = @splat(0), // 32 box: half extents
    off: V4 = @splat(0), // 48 its centre in the body
};

/// A proxy (PX_*, 80 bytes): a part placed in the world.
pub const Proxy = struct {
    r: [3]V4 align(16) = @splat(@splat(0)),
    c: V4 = @splat(0),
    part: ?*const Part = null,
    pad: u64 = 0,
};

/// collide's result (CR_*).
pub const Hit = struct {
    sep: f32 align(16) = 0,
    pad: [3]u32 = .{ 0, 0, 0 },
    pa: V4 = @splat(0),
    pb: V4 = @splat(0),
    n: V4 = @splat(0),
};

/// A solver row (RW_*): rA x d, rB x d, IA (rA x d), IB (rB x d).
pub const Row = struct {
    ax: V4 align(16) = @splat(0),
    bx: V4 = @splat(0),
    ia: V4 = @splat(0),
    ib: V4 = @splat(0),
};

/// A contact point (CP_*, 320 bytes).
pub const Contact = struct {
    la: V4 align(16) = @splat(0), // anchors (body axes, from its centre)
    lb: V4 = @splat(0),
    ra: V4 = @splat(0), // world, from the centres
    rb: V4 = @splat(0),
    sep: f32 = 0, // 64
    jn: f32 = 0, // impulses so far
    jt1: f32 = 0,
    jt2: f32 = 0,
    mn: f32 = 0, // 80 effective masses
    mt1: f32 = 0,
    mt2: f32 = 0,
    bias: f32 = 0,
    wa: V4 = @splat(0), // 96 where it is on A (world)
    c0: f32 = 0, // 112
    vn0: f32 = 0,
    jmax: f32 = 0,
    pad: u32 = 0,
    rn: Row = .{}, // 128
    rt1: Row = .{},
    rt2: Row = .{},
};

/// A manifold (MF_*, 96 + 4 x 320).
pub const Manifold = struct {
    a: u32 = 0,
    b: u32 = 0,
    pa: u32 = 0,
    pb: u32 = 0,
    n: u32 = 0, // 16 points
    keep: u32 = 0, // the step it was last seen in
    fric: f32 = 0,
    rest: f32 = 0,
    nrm: V4 align(16) = @splat(0), // 32 A to B
    t1: V4 = @splat(0),
    t2: V4 = @splat(0),
    dir: u32 = 0, // 80
    pad: [3]u32 = .{ 0, 0, 0 },
    pts: [4]Contact = @splat(.{}),
};

/// A manifold's keys, dense (MX_*, 32 bytes).
pub const Mx = extern struct {
    a: u32 = 0,
    b: u32 = 0,
    pa: u32 = 0,
    pb: u32 = 0,
    keep: u32 = 0,
    n: u32 = 0,
    pad: [2]u32 = .{ 0, 0 },
};

/// A joint at run time (JR_*, 288 bytes).
pub const Joint = struct {
    a: u32 = 0,
    b: u32 = 0,
    typ: u32 = 0,
    pad0: u32 = 0,
    la: V4 align(16) = @splat(0), // 16
    lb: V4 = @splat(0),
    axa: V4 = @splat(0), // 48
    axb: V4 = @splat(0),
    q0: V4 = @splat(0), // 80 conj(qB) qA at the start
    ra: V4 = @splat(0), // 96
    rb: V4 = @splat(0),
    err: V4 = @splat(0), // 128
    p: V4 = @splat(0), // 144
    q: V4 = @splat(0), // 160
    c: V4 = @splat(0), // 176 pB - pA (world)
    brk: f32 = 0, // 192
    lo: f32 = 0,
    hi: f32 = 0,
    ms: f32 = 0,
    mf: f32 = 0, // 208
    fl: u32 = 0, // 1 limited 2 motor 4 broken
    pad1: u32 = 0,
    macc: f32 = 0, // 220
    aw: V4 = @splat(0), // 224
    pos: f32 = 0, // 240
    imp: [3]f32 = .{ 0, 0, 0 }, // 244
    wl: V4 = @splat(0), // 256
    wa: V4 = @splat(0), // 272
};

/// A tree node (BV_*, 32 bytes): min, left (| 1 << 31: a leaf, its first); max, right (a leaf: how many).
pub const BvNode = extern struct {
    min: [3]f32 = .{ 0, 0, 0 },
    left: u32 = 0,
    max: [3]f32 = .{ 0, 0, 0 },
    right: u32 = 0,
};

// (plain structs: the original's offsets are in the field comments; vectors
// cannot be extern)

// ---- the world (rb_* globals) ---------------------------------------------------------

pub var on: bool = false; // rb_on
pub var islive: bool = false;
pub var nb: u32 = 0; // bodies (the world last)
pub var npt: u32 = 0;
pub var nvx: u32 = 0;
pub var nmf: u32 = 0;
pub var capmf: u32 = 0;
pub var npr: u32 = 0;
pub var njr: u32 = 0;
pub var nisl: u32 = 0;
pub var hmask: u32 = 0;
pub var gmask: u32 = 0;
pub var gsh: u32 = 0;
pub var gn: u32 = 0;
pub var gnbig: u32 = 0;
pub var npair: u32 = 0;
pub var nbvh: u32 = 0;
pub var nbvi: u32 = 0;
pub var xparts: u32 = 0;
pub var cappair: u32 = 0;
pub var gcs: f32 = 0;
pub var ginv: f32 = 0;
pub var stepno: u32 = 0;
pub var iter: u32 = 0;

pub var bd: []Body = &.{};
pub var pt: []Part = &.{};
pub var vx: []V4 = &.{};
pub var mf: []Manifold = &.{};
pub var mx: []Mx = &.{};
pub var hs: []u32 = &.{};
pub var ord: []u32 = &.{};
pub var gent: []u64 = &.{}; // (cell, body) entries (16 bytes each in the original: see rbody.zig)
pub var gsrt: []u64 = &.{};
pub var gtab: []u32 = &.{};
pub var gbig: []u32 = &.{};
pub var pairs: []u64 = &.{};
pub var gcc: []u32 = &.{};
pub var bcon: []u32 = &.{};
pub var bsrt: []u32 = &.{};
pub var bcol: []u32 = &.{};
pub var bmask: []u64 = &.{};
pub var bcst: []u32 = &.{};
pub var bvh: []BvNode = &.{};
pub var bvi: []u32 = &.{};
pub var bvb: []BvNode = &.{};
pub var tvw: []V4 = &.{}; // triangles' corners (world, 3 a triangle)
pub var stg: []u8 = &.{};
pub var scnt: []u8 = &.{};
pub var nstg: u32 = 0;
pub var islj: u32 = 0;
pub var par: []u32 = &.{};
pub var ib: []u32 = &.{};
pub var imf: []u32 = &.{};
pub var ij: []u32 = &.{};
pub var isb: []u32 = &.{};
pub var ism: []u32 = &.{};
pub var isj: []u32 = &.{};
pub var iaw: []u32 = &.{};
pub var jh: []u64 = &.{};
pub var jhv: []u32 = &.{};
pub var uh: []u64 = &.{};
pub var jr: []Joint = &.{};

// the step's settings (rb_settings)
pub var g: V4 = .{ 0, -9.81, 0, 0 };
pub var dt: f32 = 0;
pub var h: f32 = 0;
pub var nsub: u32 = 4;
pub var jsoft: [3]f32 = .{ 0, 0, 0 };
pub var jhard: f32 = 0;
pub var brate: f32 = 0;
pub var mscale: f32 = 0;
pub var iscale: f32 = 0;
pub var brate_s: f32 = 0;
pub var mscale_s: f32 = 0;
pub var iscale_s: f32 = 0;
pub var mffull: u32 = 0;
pub var nbroken: u32 = 0;
pub var time: f32 = 0;
pub var tns: [6]u64 = @splat(0);

// ---- constants (rodata) ---------------------------------------------------------------

pub const xyz: @Vector(4, u32) = .{ 0xffffffff, 0xffffffff, 0xffffffff, 0 };
pub const one4: V4 = .{ 1, 1, 1, 0 };
pub const half4: V4 = .{ 0.5, 0.5, 0.5, 0 };
pub const qid: V4 = .{ 0, 0, 0, 1 };
pub const tiny4: V4 = .{ 1e-9, 1e-9, 1e-9, 1 };
pub const ident: [3]V4 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 } };
pub const marg4: V4 = .{ 0.04, 0.04, 0.04, 0 };
pub const big4: V4 = .{ 1e30, 1e30, 1e30, 0 };
pub const nbig4: V4 = .{ -1e30, -1e30, -1e30, 0 };

// ---- vector helpers (the original's macros) --------------------------------------------

pub inline fn splat(x: f32) V4 {
    return @splat(x);
}
/// andps rx_xyz: w cleared (bits).
pub inline fn andXyz(a: V4) V4 {
    const u: @Vector(4, u32) = @bitCast(a);
    return @bitCast(u & xyz);
}
/// andps rx_abs (|x| |y| |z|, w 0).
pub inline fn abs3(a: V4) V4 {
    const u: @Vector(4, u32) = @bitCast(a);
    return @bitCast(u & @Vector(4, u32){ 0x7fffffff, 0x7fffffff, 0x7fffffff, 0 });
}
/// andps with all four lanes' sign cleared.
pub inline fn abs4(a: V4) V4 {
    const u: @Vector(4, u32) = @bitCast(a);
    return @bitCast(u & @as(@Vector(4, u32), @splat(0x7fffffff)));
}
/// xorps rx_sign: x y z negated (w kept).
pub inline fn neg3(a: V4) V4 {
    const u: @Vector(4, u32) = @bitCast(a);
    return @bitCast(u ^ @Vector(4, u32){ 0x80000000, 0x80000000, 0x80000000, 0 });
}
/// xorps rx_sign4.
pub inline fn neg4(a: V4) V4 {
    const u: @Vector(4, u32) = @bitCast(a);
    return @bitCast(u ^ @as(@Vector(4, u32), @splat(0x80000000)));
}
/// minps a, b: per lane a < b ? a : b (b when either is NaN).
pub inline fn minps(a: V4, b: V4) V4 {
    return @select(f32, a < b, a, b);
}
pub inline fn maxps(a: V4, b: V4) V4 {
    return @select(f32, a > b, a, b);
}
/// minss / maxss on scalars (the second when unordered).
pub inline fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
pub inline fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
/// DOT3 (dpps 0x71): (x0 y0 + x1 y1) + (x2 y2 + 0).
pub inline fn dot3(a: V4, b: V4) f32 {
    const p = a * b;
    return (p[0] + p[1]) + (p[2] + 0.0);
}
/// dpps 0xF1: all four lanes.
pub inline fn dot4(a: V4, b: V4) f32 {
    const p = a * b;
    return (p[0] + p[1]) + (p[2] + p[3]);
}
/// CROSS d, a, b (shuffles 0xC9).
pub inline fn cross(a: V4, b: V4) V4 {
    const d = @shuffle(f32, b, undefined, [4]i32{ 1, 2, 0, 3 }) * a;
    const t = @shuffle(f32, a, undefined, [4]i32{ 1, 2, 0, 3 }) * b;
    const e = d - t;
    return @shuffle(f32, e, undefined, [4]i32{ 1, 2, 0, 3 });
}
/// MV3: M v (rows), lanes x y z from three DOT3s, w 0.
pub inline fn mv3(mr: *const [3]V4, v: V4) V4 {
    return .{ dot3(mr[0], v), dot3(mr[1], v), dot3(mr[2], v), 0 };
}
/// MTV3: M^T v (rows): v.x row0 + v.y row1 + v.z row2 (all four lanes).
pub inline fn mtv3(mr: *const [3]V4, v: V4) V4 {
    var d = splat(v[0]) * mr[0];
    d += splat(v[1]) * mr[1];
    d += splat(v[2]) * mr[2];
    return d;
}
pub inline fn setW(a: V4, w: f32) V4 {
    return .{ a[0], a[1], a[2], w };
}

/// q_rows: R from q (x y z w); rows' w 0.
pub fn qRows(q: V4, o: *[3]V4) void {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    const xx = x * x;
    const yy = y * y;
    const zz = z * z;
    var t = yy + zz;
    t += t;
    o[0][0] = 1.0 - t;
    var a = x * y;
    var b = w * z;
    var c = a - b;
    c += c;
    o[0][1] = c;
    a += b;
    a += a;
    o[1][0] = a;
    a = x * z;
    b = w * y;
    c = a + b;
    c += c;
    o[0][2] = c;
    a -= b;
    a += a;
    o[2][0] = a;
    t = xx + zz;
    t += t;
    o[1][1] = 1.0 - t;
    a = y * z;
    b = w * x;
    c = a - b;
    c += c;
    o[1][2] = c;
    a += b;
    a += a;
    o[2][1] = a;
    t = xx + yy;
    t += t;
    o[2][2] = 1.0 - t;
    o[0][3] = 0;
    o[1][3] = 0;
    o[2][3] = 0;
}

/// rows_q: Shepperd.
pub fn rowsQ(m: *const [3]V4) V4 {
    const m00 = m[0][0];
    const m11 = m[1][1];
    const m22 = m[2][2];
    var q: V4 = undefined;
    const tr = (m00 + m11) + m22;
    if (tr > 0) {
        var s = @sqrt(tr + 1.0);
        s += s;
        q[3] = s * 0.25;
        q[0] = (m[2][1] - m[1][2]) / s;
        q[1] = (m[0][2] - m[2][0]) / s;
        q[2] = (m[1][0] - m[0][1]) / s;
    } else if (m00 > m11 and m00 > m22) {
        var s = @sqrt(((1.0 + m00) - m11) - m22);
        s += s;
        q[0] = s * 0.25;
        q[3] = (m[2][1] - m[1][2]) / s;
        q[1] = (m[0][1] + m[1][0]) / s;
        q[2] = (m[0][2] + m[2][0]) / s;
    } else if (m11 > m22) {
        var s = @sqrt(((1.0 + m11) - m00) - m22);
        s += s;
        q[1] = s * 0.25;
        q[3] = (m[0][2] - m[2][0]) / s;
        q[0] = (m[0][1] + m[1][0]) / s;
        q[2] = (m[1][2] + m[2][1]) / s;
    } else {
        var s = @sqrt(((1.0 + m22) - m00) - m11);
        s += s;
        q[2] = s * 0.25;
        q[3] = (m[1][0] - m[0][1]) / s;
        q[0] = (m[0][2] + m[2][0]) / s;
        q[1] = (m[1][2] + m[2][1]) / s;
    }
    return q;
}

/// q_mul: a b (x y z w).
pub fn qMul(a: V4, b: V4) V4 {
    const aw = splat(a[3]);
    const bw = splat(b[3]);
    var v = aw * b + bw * a;
    const av = andXyz(a);
    const bv = andXyz(b);
    v += cross(av, bv);
    const d = dot3(av, bv);
    const w = a[3] * b[3] - d;
    return .{ v[0], v[1], v[2], w };
}
/// q_conj: the vector part negated.
pub inline fn qConj(q: V4) V4 {
    return neg3(q);
}

/// body_update: rotation rows, world inverse inertia, bounds.
pub fn bodyUpdate(b: *Body) void {
    qRows(b.q, &b.r);
    for (0..3) |i| {
        const ri = b.r[i] * b.iil;
        b.iiw[i] = andXyz(mv3(&b.r, ri));
    }
    bodyBounds(b);
}

/// body_bounds: BD_MIN / BD_MAX over its parts (with the margin), and how far it goes in a step.
pub fn bodyBounds(b: *Body) void {
    var lo = big4;
    var hi = nbig4;
    const a0 = abs3(b.r[0]);
    const a1 = abs3(b.r[1]);
    const a2 = abs3(b.r[2]);
    var k: u32 = 0;
    while (k < b.np) : (k += 1) {
        const p = &pt[b.p0 + k];
        if (p.typ == 2) { // a plane: without end
            lo = nbig4;
            hi = big4;
            break;
        }
        var c = mv3(&b.r, p.off);
        c += b.pos;
        const e = andXyz(splat(p.rad)) + p.half;
        var ext: V4 = .{ dot3(a0, e), dot3(a1, e), dot3(a2, e), 0 };
        ext += marg4;
        lo = minps(lo, c - ext);
        hi = maxps(hi, c + ext);
    }
    const sp = andXyz(abs3(b.v) * splat(dt));
    b.min = lo - sp;
    b.max = hi + sp;
}

/// rb_body.
pub inline fn body(i: u32) *Body {
    return &bd[i];
}

test "q_rows / rows_q round trip" {
    const q: V4 = .{ 0.1825742, 0.3651484, 0.5477226, 0.7302967 };
    var r: [3]V4 = undefined;
    qRows(q, &r);
    const q2 = rowsQ(&r);
    inline for (0..4) |k| try std.testing.expectApproxEqAbs(q[k], q2[k], 1e-6);
    const p = qMul(q, qConj(q));
    try std.testing.expectApproxEqAbs(@as(f32, 1), p[3], 1e-6);
}

/// now_ns: the monotonic clock (ns).
pub fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
