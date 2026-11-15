// Shader graphs (graph.s, matnodes.s, matfunc.s): the nodes after a material's
// principled values, evaluated where a renderer shades. A material record holds
// up to 48 nodes of 72 bytes (a type, three inputs, four values), each input a
// constant or a link (node + 1, the output in bits 16..23), and 13 Material
// Output pins linked the same way. Every output is a colour and a value. Nodes
// run in order, so a link always points to an earlier node; only those leading
// to a pin are evaluated.
//
// Graphs come from files, so nothing here trusts them: bad numbers, types, links
// and image or function numbers give black, never a crash. shade() allocates
// nothing and only reads: the tracer's workers run it. A graph bigger than the
// original evaluates is cut, not refused.
const std = @import("std");
const m = @import("math.zig");
const material = @import("material.zig");
const images = @import("images.zig");
const tx = @import("texture.zig");
const shnodes = @import("shnodes.zig");
const Material = material.Material;

pub const NODE_SZ = 72;
pub const MAX_NODES = 48;
pub const NOUTS = 8;
pub const NPINS = 13;
const NODES_AT = 160 - material.FILE_PART;
const PINS_AT = 3616 - material.FILE_PART;
pub const NFLAGS_AT = 3968 - material.FILE_PART;
const MF_DEPTH = 8;
const MAX_CALLS = 512; // function calls per shading point

pub const PIN_BASE = 0;
pub const PIN_METAL = 1;
pub const PIN_SPEC = 2;
pub const PIN_ROUGH = 3;
pub const PIN_EMIT = 4;
pub const PIN_ALPHA = 5;
pub const PIN_NORMAL = 6;
pub const PIN_AO = 7;
pub const PIN_COAT = 8;
pub const PIN_COATR = 9;
pub const PIN_TRANS = 10;
pub const PIN_IOR = 11;
pub const PIN_MASK = 12;
pub const SCF_VCOL: u32 = 0x80000000; // the graph reads the vertex colour

pub const T_IMAGE = 1;
pub const T_BUMP = 8;
pub const T_NMAP = 9;
pub const T_TEXPARAM = 39;
pub const T_FNIN = 40;
pub const T_FNOUT = 41;
pub const T_FNCALL = 42;

pub const In = extern struct { link: u32, v: [3]f32 };
pub const Node = extern struct {
    type: u32,
    in: [3]In,
    p: [4]f32,
    pos: [2]i16,
};
comptime {
    std.debug.assert(@sizeOf(Node) == NODE_SZ);
}

pub fn nodesOf(ma: *const Material) *const [MAX_NODES]Node {
    return @ptrCast(@alignCast(&ma.graph[NODES_AT]));
}
pub fn nodesMut(ma: *Material) *[MAX_NODES]Node {
    return @ptrCast(@alignCast(&ma.graph[NODES_AT]));
}
pub fn pinsOf(ma: *const Material) *const [16]u32 {
    return @ptrCast(@alignCast(&ma.graph[PINS_AT]));
}
pub fn pinsMut(ma: *Material) *[16]u32 {
    return @ptrCast(@alignCast(&ma.graph[PINS_AT]));
}
pub fn count(ma: *const Material) u32 {
    return @min(ma.nodes(), MAX_NODES);
}

/// Whether a graph drives pin p.
pub fn drives(ma: *const Material, p: usize) bool {
    return ma.nodes() != 0 and pinsOf(ma)[p] != 0;
}

/// The shading context: what a renderer knows of the point.
pub const SC = struct {
    p0o: m.V3 = .{ 0, 0, 0 }, // object-space corner, edges
    e1o: m.V3 = .{ 0, 0, 0 },
    e2o: m.V3 = .{ 0, 0, 0 },
    u: f32 = 0,
    v: f32 = 0,
    pu: m.V3 = .{ 0, 0, 0 }, // dp/du, dp/dv in the normal's space
    pv: m.V3 = .{ 0, 0, 0 },
    n: m.V3 = .{ 0, 1, 0 }, // the shading normal (in / out)
    flags: u32 = 0, // bit p: pin p drove the copy (PIN_NORMAL: n)
    uvp: ?*const [6]f32 = null, // the triangle's UVs, or null: box projection
    wp: m.V3 = .{ 0, 0, 0 }, // the world point
    wv: m.V3 = .{ 0, 0, 1 }, // towards the eye, unit (world)
    vc: m.V3 = .{ 1, 1, 1 }, // the vertex colour (linear)
    box: [6]f32 = @splat(0), // the corners' UVs as used
};

const Frame = struct {
    p: m.V3,
    uv: [2]f32,
    depth: u32,
    live: u64,
    sc: *SC,
    args: ?*const [3][4]f32,
    mats: []const Material,
    /// function calls left at this point (a file can nest them to no end)
    calls: *u32,
    val: [MAX_NODES][NOUTS][4]f32,
};

/// Seconds at the scene's frame (the Time node, panners).
pub var scene_time: f32 = 0;

// --- what the original's instructions do with bad numbers ------------------------------

/// cvttss2si: truncates; out of range or NaN gives the "integer indefinite".
fn cvtt(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}
/// maxss a, b / minss a, b: b when they do not compare.
fn smax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
fn smin(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
fn sat(x: f32) f32 {
    return smin(smax(x, 0), 1);
}
fn roundEven(x: f32) f32 {
    if (!std.math.isFinite(x)) return x;
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) return 2 * @round(x / 2);
    return r;
}
const tiny: f32 = 1.0e-12;
const lum_k = [3]f32{ 0.2126, 0.7152, 0.0722 };

// --- the x87 unit, as the original computes ---------------------------------------------
// matnodes.s / graph.s / texture.s run pow, exp, log, sin, cos, tan, atan2 and
// fsincos on the x87 unit from f32 operands, storing f32: a libm differs in the
// last bit. Each routine is the original's instructions as machine code in .text
// (rdi = &m: m[0] in and out, m[1] the second operand); inline assembly differs
// between Zig's x86 backends, bytes do not.

const use_x87 = @import("builtin").cpu.arch == .x86_64;

// fld dword [rdi]; fsin / fcos; fstp dword [rdi]; ret
export const bee_sh87_sin: [7]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0xfe, 0xd9, 0x1f, 0xc3 };
export const bee_sh87_cos: [7]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0xff, 0xd9, 0x1f, 0xc3 };
// fptan; fstp st0 (out of range: x stays, the store reads the empty register)
export const bee_sh87_tan: [9]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0xf2, 0xdd, 0xd8, 0xd9, 0x1f, 0xc3 };
// fld a; fld b; fpatan: atan2(a, b)
export const bee_sh87_atan2: [10]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0x47, 0x04, 0xd9, 0xf3, 0xd9, 0x1f, 0xc3 };
// fldln2; fld a; fyl2x: ln a
export const bee_sh87_log: [9]u8 linksection(".text") = .{ 0xd9, 0xed, 0xd9, 0x07, 0xd9, 0xf1, 0xd9, 0x1f, 0xc3 };
// fld b; fld a; fyl2x; then fexp2: fld st0; frndint; fsub st1, st0; fxch st1;
// f2xm1; fld1; faddp st1, st0; fscale; fstp st1; fstp dword [rdi]
export const bee_sh87_pow: [28]u8 linksection(".text") = .{
    0xd9, 0x47, 0x04, 0xd9, 0x07, 0xd9, 0xf1, 0xd9, 0xc0, 0xd9, 0xfc, 0xdc, 0xe9, 0xd9,
    0xc9, 0xd9, 0xf0, 0xd9, 0xe8, 0xde, 0xc1, 0xd9, 0xfd, 0xdd, 0xd9, 0xd9, 0x1f, 0xc3,
};
// fld a; fldl2e; fmulp st1, st0; fexp2 as above
export const bee_sh87_exp: [27]u8 linksection(".text") = .{
    0xd9, 0x07, 0xd9, 0xea, 0xde, 0xc9, 0xd9, 0xc0, 0xd9, 0xfc, 0xdc, 0xe9, 0xd9, 0xc9,
    0xd9, 0xf0, 0xd9, 0xe8, 0xde, 0xc1, 0xd9, 0xfd, 0xdd, 0xd9, 0xd9, 0x1f, 0xc3,
};
// fld a; fsincos; fstp dword [rdi+4] (cos); fstp dword [rdi] (sin)
export const bee_sh87_sincos: [10]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0xfb, 0xd9, 0x5f, 0x04, 0xd9, 0x1f, 0xc3 };

fn run87(code: []const u8, a: f32, b: f32) [2]f32 {
    var mm: [2]f32 = .{ a, b };
    const f: *const fn (*[2]f32) callconv(.c) void = @ptrCast(code.ptr);
    f(&mm);
    return mm;
}

const X = enum { sin, cos, tan, log, exp };

fn x87(comptime op: X, a: f32) f32 {
    if (!use_x87) {
        const d: f64 = a;
        return @floatCast(switch (op) {
            .sin => @sin(d),
            .cos => @cos(d),
            .tan => @tan(d),
            .log => @log(d),
            .exp => @exp(d),
        });
    }
    return run87(switch (op) {
        .sin => &bee_sh87_sin,
        .cos => &bee_sh87_cos,
        .tan => &bee_sh87_tan,
        .log => &bee_sh87_log,
        .exp => &bee_sh87_exp,
    }, a, 0)[0];
}

/// fpatan: atan2(a, b).
fn atan2x(a: f32, b: f32) f32 {
    if (!use_x87) return @floatCast(std.math.atan2(@as(f64, a), @as(f64, b)));
    return run87(&bee_sh87_atan2, a, b)[0];
}

/// a^b through fyl2x and f2xm1 (a <= 0: 0).
fn fpow(a: f32, b: f32) f32 {
    if (!(a > 0)) return 0;
    if (!use_x87) return @floatCast(std.math.pow(f64, a, b));
    return run87(&bee_sh87_pow, a, b)[0];
}

/// fsincos: sin, cos.
fn sincos(a: f32) [2]f32 {
    if (!use_x87) return .{ @floatCast(@sin(@as(f64, a))), @floatCast(@cos(@as(f64, a))) };
    return run87(&bee_sh87_sincos, a, 0);
}

pub fn mathOp(op: i32, a: f32, b: f32, c: f32) f32 {
    if (op < 0 or op > 30) return a;
    return switch (op) {
        0 => a + b,
        1 => a - b,
        2 => a * b,
        3 => if (@abs(b) > tiny) a / b else 0,
        4 => fpow(a, b),
        5 => smin(a, b),
        6 => smax(a, b),
        7 => if (a > b) 1 else 0,
        8 => x87(.sin, a),
        9 => @abs(a),
        10 => x87(.cos, a),
        11 => x87(.tan, a),
        12 => @sqrt(smax(a, 0)),
        13 => @floor(a),
        14 => @ceil(a),
        15 => a - @floor(a),
        16 => roundEven(a),
        17 => if (a > 0) 1 else if (a == 0) 0 else -1,
        18 => 1 - a,
        19 => sat(a),
        20 => smin(smax(a, b), c),
        21 => a + (b - a) * c,
        22 => if (b >= a) 1 else 0,
        23 => blk: {
            const d = b - a;
            if (!(@abs(d) > tiny)) break :blk 0;
            const t = sat((c - a) / d);
            break :blk (3 - (t + t)) * t * t;
        },
        24 => if (@abs(b) > tiny) a - @trunc(a / b) * b else 0,
        25 => x87(.exp, a),
        26 => if (a > 0) x87(.log, a) else 0,
        27 => atan2x(a, b),
        28 => if (a >= b) 0 else 1,
        29 => -a,
        30 => a * b + c,
        else => a,
    };
}

// --- noise: improved Perlin noise, fBm --------------------------------------------------

const perm = [256]u8{
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225, 140, 36,  103, 30,  69,  142,
    8,   99,  37,  240, 21,  10,  23,  190, 6,   148, 247, 120, 234, 75,  0,   26,  197, 62,  94,  252, 219, 203,
    117, 35,  11,  32,  57,  177, 33,  88,  237, 149, 56,  87,  174, 20,  125, 136, 171, 168, 68,  175, 74,  165,
    71,  134, 139, 48,  27,  166, 77,  146, 158, 231, 83,  111, 229, 122, 60,  211, 133, 230, 220, 105, 92,  41,
    55,  46,  245, 40,  244, 102, 143, 54,  65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,
    18,  169, 200, 196, 135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,  52,  217, 226, 250,
    124, 123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212, 207, 206, 59,  227, 47,  16,  58,  17,  182, 189,
    28,  42,  223, 183, 170, 213, 119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101, 155, 167, 43,  172, 9,
    129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185, 112, 104, 218, 246, 97,  228, 251, 34,
    242, 193, 238, 210, 144, 12,  191, 179, 162, 241, 81,  51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,
    181, 199, 106, 157, 184, 84,  204, 176, 115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,  222, 114,
    67,  29,  24,  72,  243, 141, 128, 195, 78,  66,  215, 61,  156, 180,
};

fn pm(x: i32) i32 {
    return perm[@as(u32, @bitCast(x)) & 255];
}

fn fade(t: f32) f32 {
    return (((t * 6 - 15) * t + 10) * t) * t * t;
}

fn grad(h0: i32, x: f32, y: f32, z: f32) f32 {
    const h = h0 & 15;
    var u = if (h < 8) x else y;
    var v = if (h < 4) y else if (h == 12 or h == 14) x else z;
    if (h & 1 != 0) u = -u;
    if (h & 2 != 0) v = -v;
    return u + v;
}

/// About -1 .. 1.
pub fn perlin(p: m.V3) f32 {
    var cell: [3]i32 = undefined;
    var f: [3]f32 = undefined;
    var w: [3]f32 = undefined;
    for (0..3) |i| {
        var c = cvtt(p[i]);
        var fl: f32 = @floatFromInt(c);
        if (fl > p[i]) {
            c -%= 1;
            fl = @floatFromInt(c);
        }
        cell[i] = c & 255;
        f[i] = p[i] - fl;
        w[i] = fade(f[i]);
    }
    const a = pm(cell[0]) + cell[1];
    const aa = pm(a) + cell[2];
    const ab = pm(a + 1) + cell[2];
    const b = pm(cell[0] + 1) + cell[1];
    const ba = pm(b) + cell[2];
    const bb = pm(b + 1) + cell[2];
    var g: [8]f32 = undefined;
    for (0..8) |k| {
        var h = if (k & 1 != 0) ba else aa;
        if (k & 2 != 0) h = if (k & 1 != 0) bb else ab;
        if (k & 4 != 0) h += 1;
        const x = if (k & 1 != 0) f[0] - 1 else f[0];
        const y = if (k & 2 != 0) f[1] - 1 else f[1];
        const z = if (k & 4 != 0) f[2] - 1 else f[2];
        g[k] = grad(pm(h), x, y, z);
    }
    var l: [4]f32 = undefined;
    for (0..4) |i| l[i] = g[i * 2] + (g[i * 2 + 1] - g[i * 2]) * w[0];
    const c0 = l[0] + (l[1] - l[0]) * w[1];
    const c1 = l[2] + (l[3] - l[2]) * w[1];
    return c0 + (c1 - c0) * w[2];
}

/// In 0 .. 1.
pub fn fbm(p: m.V3, scale: f32, octaves: i32, gain: f32) f32 {
    const n: i32 = std.math.clamp(octaves, 1, 8);
    var freq = scale;
    var amp: f32 = 1;
    var sum: f32 = 0;
    var total: f32 = 0;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        sum += perlin(.{ p[0] * freq, p[1] * freq, p[2] * freq }) * amp;
        total += amp;
        amp *= gain;
        freq *= 2;
    }
    return sat(sum / total * 0.5 + 0.5);
}

// --- hashing (Voronoi, bricks, white noise) ---------------------------------------------

fn ihash(x0: u32) u32 {
    var x = x0;
    x ^= x >> 16;
    x *%= 0x85ebca6b;
    x ^= x >> 13;
    x *%= 0xc2b2ae35;
    x ^= x >> 16;
    return x;
}
fn hash3i(a: i32, b: i32, c: i32) u32 {
    const x = @as(u32, @bitCast(a)) *% 73856093;
    const y = @as(u32, @bitCast(b)) *% 19349663;
    const z = @as(u32, @bitCast(c)) *% 83492791;
    return ihash(x ^ y ^ z);
}
/// In 0 .. 1; h is mixed again for the next one.
fn h01(h: *u32) f32 {
    h.* = ihash(h.*);
    return @as(f32, @floatFromInt(h.* >> 1)) * 4.656613e-10;
}

// --- evaluation -------------------------------------------------------------------------

const Ev = struct {
    ma: *const Material,
    nd: *const Node,
    fr: *Frame,
    i: usize,

    fn row(e: Ev) *[NOUTS][4]f32 {
        return &e.fr.val[e.i];
    }
    /// An input: its colour and value.
    fn input(e: Ev, k: usize) [4]f32 {
        return inOf(e.nd, k, e.fr, e.i);
    }
    fn linked(e: Ev, k: usize) bool {
        return e.nd.in[k].link & 0xffff != 0;
    }
    fn out(e: Ev, k: usize, c: [4]f32) void {
        e.row()[k] = c;
    }
    /// The node's colour, value = luminance.
    fn put(e: Ev, c0: f32, c1: f32, c2: f32) void {
        e.row()[0] = .{ c0, c1, c2, c0 * lum_k[0] + c1 * lum_k[1] + c2 * lum_k[2] };
    }
    /// Grey colour and value.
    fn putv(e: Ev, v: f32) void {
        e.row()[0] = .{ v, v, v, v };
    }
    /// Output 0 the vector (value: x), 1..3 x y z.
    fn vecOut(e: Ev, v: m.V3) void {
        e.row()[1] = .{ v[0], v[0], v[0], v[0] };
        e.row()[2] = .{ v[1], v[1], v[1], v[1] };
        e.row()[3] = .{ v[2], v[2], v[2], v[2] };
        e.row()[0] = .{ v[0], v[1], v[2], v[0] };
    }
    /// The linked vector, or the point's own (UV, or the object position).
    fn inVec(e: Ev, k: usize, position: bool) m.V3 {
        if (e.linked(k)) {
            const c = e.input(k);
            return .{ c[0], c[1], c[2] };
        }
        if (position) return e.fr.p;
        return .{ e.fr.uv[0], e.fr.uv[1], 0 };
    }
    fn nodeT(e: Ev, k: usize) f32 {
        return if (e.linked(k)) e.input(k)[3] else scene_time;
    }
    /// [rsp] the input colour, r the result, f the factor.
    fn mixOut(e: Ev, c: [4]f32, r: m.V3, f: f32) void {
        e.put((r[0] - c[0]) * f + c[0], (r[1] - c[1]) * f + c[1], (r[2] - c[2]) * f + c[2]);
    }
};

fn inOf(nd: *const Node, k: usize, fr: *const Frame, self: usize) [4]f32 {
    const l = nd.in[k].link;
    const lo = l & 0xffff;
    if (lo == 0) {
        const v = nd.in[k].v;
        return .{ v[0], v[1], v[2], v[0] };
    }
    if (lo > self) return .{ 0, 0, 0, 0 }; // (not an earlier node: damaged)
    return fr.val[lo - 1][(l >> 16) & (NOUTS - 1)];
}

fn unit3(v: *m.V3) void {
    const l = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (!(l > tiny)) return;
    const k = 1 / l;
    v.* = .{ v[0] * k, v[1] * k, v[2] * k };
}

fn dot3(a: m.V3, b: m.V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn imageOf(p0: f32) ?*const images.Entry {
    const i = cvtt(p0) -% 1;
    if (i < 0 or i >= images.count) return null;
    const e = &images.list[@intCast(i)];
    if (e.img.w == 0 or e.img.h == 0) return null;
    return e;
}

fn mirror(u: f32) f32 {
    var x = u * 0.5;
    x -= @floor(x);
    x += x;
    x -= 1;
    return smin(1 - @abs(x), 0.9999);
}

fn evalImage(e: Ev) void {
    const n = e.nd;
    const img = imageOf(n.p[0]) orelse return e.putv(0);
    const size: f32 = if (n.p[1] > 0) n.p[1] else 1;
    var u = e.fr.uv[0];
    var v = e.fr.uv[1];
    if (n.in[0].link != 0) {
        const c = e.input(0);
        u = c[0];
        v = c[1];
    }
    u /= size;
    v /= size;
    const wrap = cvtt(n.p[3]); // repeat, clamp, mirror
    var mode: u32 = if (wrap == 1) tx.CLAMP else 0;
    if (wrap > 1) {
        u = mirror(u);
        v = mirror(v);
    }
    if (n.p[2] >= 0.5) mode |= tx.DATA; // data (not colours) unless a colour
    const c = tx.sample4(img, u, v, mode);
    for (0..4) |k| e.out(k + 1, .{ c[k], c[k], c[k], c[k] });
    e.put(c[0], c[1], c[2]);
}

fn evalNoise(e: Ev) void {
    const c = e.input(0);
    const p: m.V3 = .{ c[0] + e.fr.p[0], c[1] + e.fr.p[1], c[2] + e.fr.p[2] };
    const q: m.V3 = .{ p[0] + 17.31, p[1] + 41.77, p[2] + 7.13 };
    const r: m.V3 = .{ p[0] + 31.59, p[1] + 3.23, p[2] + 23.41 };
    const oct = cvtt(e.nd.p[1]);
    const a = fbm(p, e.nd.p[0], oct, e.nd.p[2]);
    const b = fbm(q, e.nd.p[0], oct, e.nd.p[2]);
    const d = fbm(r, e.nd.p[0], oct, e.nd.p[2]);
    e.put(a, b, d);
    e.row()[0][3] = a;
}

fn evalChecker(e: Ev) void {
    var s: i32 = 0;
    for (0..3) |i| {
        const x = e.fr.p[i] * e.nd.p[0];
        var c = cvtt(x);
        if (@as(f32, @floatFromInt(c)) > x) c -%= 1;
        s +%= c;
    }
    const k: usize = @intCast(s & 1);
    const c = e.input(k);
    e.put(c[0], c[1], c[2]);
    e.row()[0][3] = @floatFromInt(k);
}

fn evalGradient(e: Ev) void {
    const n = e.nd;
    var axis = cvtt(n.p[0]);
    if (axis == 3 or axis == 4) {
        const p = e.fr.p;
        var x: f32 = undefined;
        if (axis == 3) {
            // around y: the angle, 0..1
            const a = atan2x(p[2], p[0]);
            x = a * 0.15915494 + 0.5;
        } else x = 1 - @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]) * n.p[1];
        return e.putv(sat(x + n.p[2]));
    }
    if (axis < 0 or axis > 2) axis = 1;
    e.putv(sat(e.fr.p[@intCast(axis)] * n.p[1] * 0.5 + 0.5 + n.p[2]));
}

fn mixOp(mode: i32, a: f32, b: f32) f32 {
    return switch (mode) {
        0 => b,
        1 => b + a,
        2 => b * a,
        3 => a - b,
        4 => 1 - (1 - a) * (1 - b),
        5 => if (a >= 0.5) 1 - 2 * ((1 - a) * (1 - b)) else b * a * 2,
        6 => smin(b, a),
        7 => smax(b, a),
        8 => @abs(b - a),
        9 => (1 - (b + b)) * a * a + (b + b) * a,
        10 => if (@abs(b) > tiny) a / b else 0,
        else => a,
    };
}

fn evalMix(e: Ev) void {
    const f = sat(e.input(0)[3]);
    const a = e.input(1);
    const b = e.input(2);
    const mode = cvtt(e.nd.p[0]);
    var r: m.V3 = undefined;
    for (0..3) |c| r[c] = a[c] + (mixOp(mode, a[c], b[c]) - a[c]) * f;
    e.put(r[0], r[1], r[2]);
}

fn evalRamp(e: Ev) void {
    var t = e.input(0)[3] - e.nd.p[0];
    const d = e.nd.p[1] - e.nd.p[0];
    if (@abs(d) > tiny) t /= d;
    t = sat(t);
    const a = e.input(1);
    const b = e.input(2);
    e.put((b[0] - a[0]) * t + a[0], (b[1] - a[1]) * t + a[1], (b[2] - a[2]) * t + a[2]);
}

fn evalFresnel(e: Ev) void {
    var n = e.fr.sc.n;
    if (e.linked(0)) {
        const c = e.input(0);
        n = .{ c[0], c[1], c[2] };
        unit3(&n);
    }
    const d = smin(@abs(dot3(n, e.fr.sc.wv)), 1);
    const k = fpow(1 - d, e.nd.p[0]);
    e.putv(k * (1 - e.nd.p[1]) + e.nd.p[1]);
}

const vm_map = [20]u8{ 0, 1, 2, 3, 5, 6, 9, 13, 15, 0, 0, 0, 0, 0, 0, 0, 21, 18, 19, 4 };

fn evalVmath(e: Ev) void {
    const a4 = e.input(0);
    const b4 = e.input(1);
    const c4 = e.input(2);
    const a: m.V3 = .{ a4[0], a4[1], a4[2] };
    var b: m.V3 = .{ b4[0], b4[1], b4[2] };
    var r: m.V3 = undefined;
    const op = cvtt(e.nd.p[0]);
    switch (op) {
        9 => r = .{ a[0] * b4[3], a[1] * b4[3], a[2] * b4[3] },
        10 => return e.putv(dot3(a, b)),
        11 => r = .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] },
        12 => {
            r = a;
            unit3(&r);
        },
        13 => return e.putv(@sqrt(dot3(a, a))),
        14 => {
            const d: m.V3 = .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
            return e.putv(@sqrt(dot3(d, d)));
        },
        15 => {
            unit3(&b);
            const k = dot3(a, b) * 2;
            r = .{ a[0] - b[0] * k, a[1] - b[1] * k, a[2] - b[2] * k };
        },
        else => {
            if (op < 0 or op > 19) return e.putv(0);
            const o: i32 = vm_map[@intCast(op)];
            for (0..3) |i| r[i] = mathOp(o, a[i], b[i], c4[3]);
        },
    }
    e.vecOut(r);
    e.put(r[0], r[1], r[2]);
}

fn turn2(v: *m.V3, a: f32) void {
    const sc = sincos(a);
    const c = sc[1];
    const s = sc[0];
    const x = v[0];
    const y = v[1];
    v[0] = x * c - y * s;
    v[1] = x * s + y * c;
}

fn evalVoronoi(e: Ev) void {
    const n = e.nd;
    const q = e.inVec(0, true);
    var p: m.V3 = undefined;
    var cell: [3]i32 = undefined;
    for (0..3) |i| {
        p[i] = q[i] * n.p[0];
        cell[i] = cvtt(@floor(p[i]));
    }
    var f1: f32 = 1.0e30;
    var f2: f32 = 1.0e30;
    var near: u32 = 0;
    var dz: i32 = -1;
    while (dz <= 1) : (dz += 1) {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const c = [3]i32{ cell[0] +% dx, cell[1] +% dy, cell[2] +% dz };
                const id = hash3i(c[0], c[1], c[2]);
                var d2: f32 = 0;
                for (0..3) |k| {
                    var h = (id +% @as(u32, @intCast(k))) *% 0x27d4eb2f;
                    const r = (h01(&h) - 0.5) * n.p[1] + 0.5 + @as(f32, @floatFromInt(c[k])) - p[k];
                    d2 += r * r;
                }
                const d = @sqrt(d2);
                if (!(d >= f1)) {
                    f2 = f1;
                    f1 = d;
                    near = id;
                } else if (!(d >= f2)) f2 = d;
            }
        }
    }
    const mode = cvtt(n.p[2]);
    const fac = if (mode == 1) f2 else if (mode == 2) f2 - f1 else f1;
    var h = near ^ 0x5bd1e995;
    const r = h01(&h);
    const g = h01(&h);
    const b = h01(&h);
    e.out(1, .{ r, g, b, r });
    e.putv(fac);
}

fn evalWhite(e: Ev) void {
    const q = e.inVec(0, true);
    var h = hash3i(@bitCast(q[0]), @bitCast(q[1]), @bitCast(q[2]));
    // (hash3i's result goes through h01's own mixing as it stands)
    const r = h01(&h);
    const g = h01(&h);
    const b = h01(&h);
    e.out(1, .{ r, g, b, r });
    e.putv(r);
}

fn evalBrick(e: Ev) void {
    const n = e.nd;
    const q = e.inVec(0, false);
    var x = q[0] * n.p[0];
    var y = q[1] * n.p[0];
    y += y;
    const fy = @floor(y);
    const row = cvtt(fy);
    y -= fy;
    if (row & 1 != 0) x += n.p[2]; // (odd rows: shifted)
    const fx = @floor(x);
    const brick = cvtt(fx);
    x -= fx;
    const mt = n.p[1]; // mortar: near any edge
    const my = mt + mt; // (rows are half as high)
    const mortar = !(x >= mt) or x > 1 - mt or !(y >= my) or y > 1 - my;
    var c: [4]f32 = undefined;
    if (mortar) {
        c = e.input(2);
    } else {
        var h = hash3i(brick, row, 0);
        const t = h01(&h) * 0.4 + 0.8;
        c = e.input(1);
        c = .{ c[0] * t, c[1] * t, c[2] * t, c[3] };
    }
    const fac: f32 = if (mortar) 1 else 0;
    e.out(1, .{ fac, fac, fac, fac });
    e.put(c[0], c[1], c[2]);
}

fn evalWave(e: Ev) void {
    const n = e.nd;
    const q = e.inVec(0, true);
    var x: f32 = undefined;
    if (cvtt(n.p[2]) == 0) {
        var axis = cvtt(n.p[3]);
        if (axis < 0 or axis > 2) axis = 0;
        x = q[@intCast(axis)];
    } else x = @sqrt(dot3(q, q));
    x *= n.p[0];
    if (n.p[1] != 0 and n.p[1] == n.p[1]) x = (fbm(q, n.p[0], 2, 0.5) - 0.5) * n.p[1] + x;
    const s = x87(.sin, x * 6.2831853);
    const v = s * 0.5 + 0.5;
    e.out(1, .{ v, v, v, v });
    e.putv(v);
}

fn bits(x: f32) i32 {
    return @bitCast(x);
}

fn evalTriplanar(e: Ev) void {
    const n = e.nd;
    const img = imageOf(n.p[0]) orelse return e.putv(0);
    const sc = e.fr.sc;
    var w: [3]f32 = undefined;
    var sum: f32 = 0;
    for (0..3) |i| {
        w[i] = fpow(@abs(sc.n[i]), n.p[2]);
        sum += w[i];
    }
    sum = smax(sum, tiny);
    const size: f32 = if (n.p[1] > 0) n.p[1] else 1;
    const axes = [3][2]usize{ .{ 2, 1 }, .{ 0, 2 }, .{ 0, 1 } };
    const mode: u32 = if (bits(n.p[3]) >= 0x3f000000) tx.DATA else 0;
    var s: [4]f32 = @splat(0);
    for (0..3) |k| {
        const c = tx.sample4(img, sc.wp[axes[k][0]] / size, sc.wp[axes[k][1]] / size, mode);
        const f = w[k] / sum;
        for (0..4) |i| s[i] += c[i] * f;
    }
    e.out(1, .{ s[3], s[3], s[3], s[3] });
    e.put(s[0], s[1], s[2]);
}

fn rgbHsv(c: m.V3) m.V3 {
    const v = smax(smax(c[0], c[1]), c[2]);
    const mn = smin(smin(c[0], c[1]), c[2]);
    const d = v - mn;
    const s: f32 = if (v > tiny) d / v else 0;
    var h: f32 = 0;
    if (d > tiny) {
        if (c[0] == v) {
            h = (c[1] - c[2]) / d;
        } else if (c[1] == v) {
            h = (c[2] - c[0]) / d + 2;
        } else h = (c[0] - c[1]) / d + 2 + 2;
        h /= 6;
        if (!(h >= 0)) h += 1;
    }
    return .{ h, s, v };
}

fn hsvRgb(c: m.V3) m.V3 {
    const h = c[0] * 6;
    const fl = @floor(h);
    const f = h - fl;
    const i = @mod(cvtt(fl), 6);
    const v = c[2];
    const s = c[1];
    const p = (1 - s) * v;
    const q = (1 - s * f) * v;
    const t = (1 - (1 - f) * s) * v;
    return switch (i) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
}

fn evalHsv(e: Ev) void {
    const n = e.nd;
    const c = e.input(0);
    var h = rgbHsv(.{ c[0], c[1], c[2] });
    h[0] += n.p[0];
    h[0] -= @floor(h[0]);
    h[1] = sat(h[1] * n.p[1]);
    h[2] = smax(h[2] * n.p[2], 0);
    e.mixOut(c, hsvRgb(h), n.p[3]);
}

fn srgbToLin(c: f32) f32 {
    if (!(c > 0.04045)) return c * 0.0773993808;
    return fpow(c * 0.9478672986 + 0.0521327014, 2.4); // (texture.s: x87, 2.4 as a float)
}

fn evalBlackbody(e: Ev) void {
    const t = smax(e.nd.p[0] * 0.01, 10);
    var c: m.V3 = undefined;
    if (t > 66) {
        const a = t - 60;
        c[0] = fpow(a, -0.1332047592) * 329.698727446;
        c[1] = fpow(a, -0.0755148492) * 288.1221695283;
    } else {
        c[0] = 255;
        c[1] = mathOp(26, t, 0, 0) * 99.4708025861 - 161.1195681661;
    }
    c[2] = 255;
    if (!(t >= 66)) {
        c[2] = 0;
        if (t > 19) c[2] = mathOp(26, t - 10, 0, 0) * 138.5177312231 - 305.0447927307;
    }
    for (&c) |*x| x.* = srgbToLin(smin(smax(x.*, 0), 255) * 0.003921569);
    e.put(c[0], c[1], c[2]);
}

fn fnInput(e: Ev) void {
    if (e.fr.args) |a| {
        const k = std.math.clamp(cvtt(e.nd.p[0]), 0, 2);
        e.out(0, a[@intCast(k)]);
    } else e.out(0, e.input(0));
}

fn fnCall(e: Ev) void {
    const fr = e.fr;
    const fi = cvtt(e.nd.p[0]) -% 1;
    if (fr.depth >= MF_DEPTH or fi < 0 or fi >= fr.mats.len or fr.calls.* == 0) return;
    fr.calls.* -= 1;
    const f = &fr.mats[@intCast(fi)];
    if (f.func != 1) return;
    const n = count(f);
    const nodes = nodesOf(f);
    var o: usize = 0;
    while (o < n and nodes[o].type != T_FNOUT) o += 1;
    if (o >= n) return;
    const args = [3][4]f32{ e.input(0), e.input(1), e.input(2) };
    var sub: Frame = undefined;
    sub.p = fr.p;
    sub.uv = fr.uv;
    sub.sc = fr.sc;
    sub.mats = fr.mats;
    sub.calls = fr.calls;
    sub.depth = fr.depth + 1;
    sub.args = &args;
    sub.live = liveOf(f, @as(u64, 1) << @intCast(o));
    evalGraph(f, &sub);
    for (0..3) |k| e.out(k, inOf(&nodes[o], k, &sub, o));
}

fn evalNode(e: Ev) void {
    const n = e.nd;
    switch (n.type) {
        T_IMAGE, T_TEXPARAM => evalImage(e),
        2 => evalNoise(e),
        3 => evalChecker(e),
        4 => evalGradient(e),
        5 => evalMix(e),
        6 => evalRamp(e),
        7 => e.putv(mathOp(cvtt(n.p[0]), e.input(0)[3], e.input(1)[3], e.input(2)[3])),
        T_BUMP => e.putv(e.input(0)[3] * n.p[1]), // value = height x distance
        T_NMAP => {
            const c = e.input(0);
            e.put(c[0], c[1], c[2]);
        },
        10 => e.vecOut(.{ e.fr.uv[0] * n.p[0] + n.p[2], e.fr.uv[1] * n.p[1] + n.p[3], 0 }),
        11 => e.vecOut(if (bits(n.p[0]) >= 0x3f000000) e.fr.sc.wp else e.fr.p),
        12 => e.vecOut(e.fr.sc.n),
        13 => e.vecOut(e.fr.sc.wv),
        14 => {
            e.fr.sc.flags |= SCF_VCOL; // (no tint after the graph)
            e.put(e.fr.sc.vc[0], e.fr.sc.vc[1], e.fr.sc.vc[2]);
        },
        15 => e.putv(scene_time * n.p[0]),
        16 => e.putv(n.p[0]),
        17 => {
            const c = e.input(0);
            e.put(c[0], c[1], c[2]);
        },
        18 => evalFresnel(e),
        19 => evalVmath(e),
        20 => {
            const c = e.input(0);
            for (0..3) |k| e.out(k, .{ c[k], c[k], c[k], c[k] });
        },
        21 => e.put(e.input(0)[3], e.input(1)[3], e.input(2)[3]),
        22 => {
            var v = e.inVec(0, false);
            const s = e.input(2);
            v = .{ v[0] * s[0], v[1] * s[1], v[2] * s[2] };
            turn2(&v, n.p[0] * 0.017453293);
            const o = e.input(1);
            e.vecOut(.{ o[0] + v[0], o[1] + v[1], o[2] + v[2] });
        },
        23 => {
            var v = e.inVec(0, false);
            const t = e.nodeT(1);
            v[0] = t * n.p[0] + v[0];
            v[1] = t * n.p[1] + v[1];
            e.vecOut(v);
        },
        24 => {
            var v = e.inVec(0, false);
            v[0] -= n.p[0];
            v[1] -= n.p[1];
            turn2(&v, e.nodeT(1) * n.p[2]);
            v[0] += n.p[0];
            v[1] += n.p[1];
            e.vecOut(v);
        },
        25 => evalVoronoi(e),
        26 => evalHsv(e),
        27 => {
            const c = e.input(0);
            e.mixOut(c, .{ 1 - c[0], 1 - c[1], 1 - c[2] }, n.p[0]);
        },
        28 => {
            const c = e.input(0);
            const a = 1 + n.p[1];
            const b = n.p[0] - n.p[1] * 0.5;
            e.put(smax(c[0] * a + b, 0), smax(c[1] * a + b, 0), smax(c[2] * a + b, 0));
        },
        29 => {
            const c = e.input(0);
            const l = c[0] * lum_k[0] + c[1] * lum_k[1] + c[2] * lum_k[2];
            e.mixOut(c, .{ l, l, l }, n.p[0]);
        },
        30 => {
            const c = e.input(0);
            e.put(fpow(c[0], n.p[0]), fpow(c[1], n.p[0]), fpow(c[2], n.p[0]));
        },
        31 => evalBlackbody(e),
        32 => evalBrick(e),
        33 => evalWave(e),
        34 => evalWhite(e),
        35 => evalTriplanar(e),
        36 => e.out(0, e.input(0)),
        37 => e.putv(n.p[0]),
        38 => e.put(n.p[0], n.p[1], n.p[2]),
        T_FNIN => fnInput(e),
        T_FNCALL => fnCall(e),
        else => e.putv(0),
    }
}

fn evalGraph(ma: *const Material, fr: *Frame) void {
    const n = count(ma);
    const nodes = nodesOf(ma);
    var left = fr.live;
    while (left != 0) {
        const i: usize = @ctz(left);
        left &= left - 1;
        if (i >= n) break;
        fr.val[i] = std.mem.zeroes([NOUTS][4]f32);
        evalNode(.{ .ma = ma, .nd = &nodes[i], .fr = fr, .i = i });
    }
}

// --- constant folding (matcache.s) -------------------------------------------------------
// A graph is compiled once per edit into what does not depend on the point: nodes
// of a pure type whose links all come from such nodes. They are evaluated once;
// each shading call copies only the results that varying nodes or pins read.
// The table (GC_N entries by record address) is shared by the render threads:
// whichever finds an entry stale and takes its lock rebuilds it (the others
// shade without folding meanwhile), and readers check its sequence number
// around the copy (a change: they evaluate everything).

const GC_N = 32;
/// node types that are pure functions of their inputs and values
const gc_pure = [60]u1{
    0, 0, 0, 0, 0, 1, 1, 1, 0, 0, // 0 .. 9: mix, ramp, math
    0, 0, 0, 0, 0, 0, 1, 1, 0, 1, // 10 ..: constant, color, vmath
    1, 1, 0, 0, 0, 0, 1, 1, 1, 1, // 20 ..: separate, combine, hsv ...
    1, 1, 0, 0, 0, 0, 1, 1, 1, 0, // 30 ..: gamma, blackbody, reroute, params
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 40 ..: functions (no)
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

const GcEntry = struct {
    rec: usize = 0,
    ver: u32 = 0,
    gen: u32 = 0,
    seq: u32 = 0, // odd while being written
    lock: u32 = 0,
    konst: u64 = 0, // the constant nodes
    front: u64 = 0, // those read by the rest or by pins
    vals: [MAX_NODES][NOUTS * 4]u32 = undefined,
};
var gc_tab: [GC_N]GcEntry = @splat(.{});
/// Bumped when instances are synced (their graphs change, material.version not).
pub var sync_gen: u32 = 0;
/// Off: every node evaluated at every point (the tests compare both).
pub var fold_on = true;

fn gcBuild(ma: *const Material, e: *GcEntry) bool {
    if (@cmpxchgStrong(u32, &e.lock, 0, 1, .acquire, .monotonic) != null) return false;
    defer @atomicStore(u32, &e.lock, 0, .release);
    _ = @atomicRmw(u32, &e.seq, .Add, 1, .acq_rel); // (odd: being written)
    @atomicStore(usize, &e.rec, @intFromPtr(ma), .monotonic);
    @atomicStore(u32, &e.ver, material.version, .monotonic);
    @atomicStore(u32, &e.gen, sync_gen, .monotonic);
    const n = count(ma);
    const nodes = nodesOf(ma);
    var konst: u64 = 0;
    for (nodes[0..n], 0..) |*nd, i| {
        if (nd.type >= gc_pure.len or gc_pure[nd.type] == 0) continue;
        var ok = true;
        for (nd.in) |l| {
            const lo = l.link & 0xffff;
            if (lo != 0 and (lo - 1 >= 64 or konst & (@as(u64, 1) << @intCast(lo - 1)) == 0)) ok = false;
        }
        if (ok) konst |= @as(u64, 1) << @intCast(i);
    }
    var front: u64 = 0;
    for (nodes[0..n], 0..) |*nd, i| {
        if (konst & (@as(u64, 1) << @intCast(i)) != 0) continue;
        for (nd.in) |l| {
            const lo = l.link & 0xffff;
            if (lo != 0 and lo - 1 < 64 and konst & (@as(u64, 1) << @intCast(lo - 1)) != 0) front |= @as(u64, 1) << @intCast(lo - 1);
        }
    }
    for (pinsOf(ma)[0..NPINS]) |p| {
        const lo = p & 0xffff;
        if (lo != 0 and lo - 1 < 64 and konst & (@as(u64, 1) << @intCast(lo - 1)) != 0) front |= @as(u64, 1) << @intCast(lo - 1);
    }
    @atomicStore(u64, &e.konst, konst, .monotonic);
    @atomicStore(u64, &e.front, front, .monotonic);
    if (konst != 0) {
        var sc = SC{};
        var calls: u32 = MAX_CALLS;
        var fr: Frame = undefined;
        fr.p = .{ 0, 0, 0 };
        fr.uv = .{ 0, 0 };
        fr.depth = 0;
        fr.live = konst;
        fr.sc = &sc;
        fr.args = null;
        fr.mats = &.{};
        fr.calls = &calls;
        evalGraph(ma, &fr);
        var f = front;
        while (f != 0) {
            const i: usize = @ctz(f);
            f &= f - 1;
            const src: *const [NOUTS * 4]u32 = @ptrCast(&fr.val[i]);
            for (&e.vals[i], src) |*d, s| @atomicStore(u32, d, s, .monotonic);
        }
    }
    _ = @atomicRmw(u32, &e.seq, .Add, 1, .release); // (even: done)
    return true;
}

/// The constant nodes' results that matter copied into the frame: the nodes
/// still to evaluate are `live` without the returned ones (0: none folded).
fn gcFold(ma: *const Material, fr: *Frame) u64 {
    if (!fold_on) return 0;
    const e = &gc_tab[(@intFromPtr(ma) >> 12) & (GC_N - 1)];
    var seq = @atomicLoad(u32, &e.seq, .acquire);
    if (seq & 1 != 0) return 0;
    if (@atomicLoad(usize, &e.rec, .monotonic) != @intFromPtr(ma) or @atomicLoad(u32, &e.ver, .monotonic) != material.version or @atomicLoad(u32, &e.gen, .monotonic) != sync_gen) {
        if (!gcBuild(ma, e)) return 0;
        seq = @atomicLoad(u32, &e.seq, .acquire);
        if (seq & 1 != 0) return 0;
    }
    const konst = @atomicLoad(u64, &e.konst, .monotonic);
    if (konst == 0) return 0;
    var rows = @atomicLoad(u64, &e.front, .monotonic) & fr.live;
    while (rows != 0) {
        const i: usize = @ctz(rows);
        rows &= rows - 1;
        const dst: *[NOUTS * 4]u32 = @ptrCast(&fr.val[i]);
        for (dst, &e.vals[i]) |*d, *s| d.* = @atomicLoad(u32, s, .monotonic);
    }
    // (written meanwhile: no folding)
    if (@atomicLoad(u32, &e.seq, .acquire) != seq or @atomicLoad(usize, &e.rec, .monotonic) != @intFromPtr(ma)) return 0;
    return konst;
}

/// The nodes wanted and every node feeding them (links point to earlier nodes).
pub fn liveOf(ma: *const Material, want: u64) u64 {
    var live = want;
    var i: usize = count(ma);
    const nodes = nodesOf(ma);
    while (i > 0) {
        i -= 1;
        if (live & (@as(u64, 1) << @intCast(i)) == 0) continue;
        for (nodes[i].in) |l| {
            const lo = l.link & 0xffff;
            if (lo != 0 and lo <= i) live |= @as(u64, 1) << @intCast(lo - 1);
        }
    }
    return live;
}

fn fnOut(ma: *const Material) ?usize {
    const n = count(ma);
    for (nodesOf(ma)[0..n], 0..) |*x, i| {
        if (x.type == T_FNOUT) return i;
    }
    return null;
}

fn at(ma: *const Material, sc: *SC, fr: *Frame, u: f32, v: f32) void {
    const w0 = 1 - u - v;
    for (0..3) |c| fr.p[c] = sc.e1o[c] * u + sc.e2o[c] * v + sc.p0o[c];
    for (0..2) |c| fr.uv[c] = sc.box[c] * w0 + sc.box[2 + c] * u + sc.box[4 + c] * v;
    evalGraph(ma, fr);
}

fn cross(a: m.V3, b: m.V3) m.V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn unitOf(v0: m.V3) ?m.V3 {
    const l = @sqrt(dot3(v0, v0));
    if (!(l > tiny)) return null;
    const k = 1 / l;
    return .{ v0[0] * k, v0[1] * k, v0[2] * k };
}

/// Without its n part, unit (0 stays 0).
fn orthoTo(v: m.V3, n: m.V3) m.V3 {
    const d = dot3(v, n);
    const r: m.V3 = .{ v[0] - n[0] * d, v[1] - n[1] * d, v[2] - n[2] * d };
    return unitOf(r) orelse r;
}

fn setF(ma: *Material, i: usize, v: f32) void {
    ma.rt[i] = @bitCast(v);
}
pub fn rtAo(ma: *const Material) f32 {
    return @bitCast(ma.rt[0]);
}
pub fn rtMask(ma: *const Material) f32 {
    return @bitCast(ma.rt[1]);
}

/// A shading copy of a material: its 128-byte values; the graph part is not
/// copied (it is not read through a copy).
pub fn copyValues(dst: *Material, src: *const Material) void {
    const d: [*]u8 = @ptrCast(dst);
    const s: [*]const u8 = @ptrCast(src);
    @memcpy(d[0..material.FILE_PART], s[0..material.FILE_PART]);
}

/// graph_shade: the pins' results in the copy (emission without a strength
/// gets 1), the normal in sc.n, sc.flags which ones. mode_coverage: the
/// opacity and mask only, not the normal. False: the material has no graph.
pub fn shade(ma: *const Material, mats: []const Material, sc: *SC, copy: *Material, coverage: bool) bool {
    sc.flags = 0;
    if (ma.nodes() == 0) return false;
    const n = count(ma);
    const pins = pinsOf(ma);
    var want: u64 = 0;
    for (pins[0..NPINS], 0..) |pin, p| {
        if (p == PIN_NORMAL and coverage) continue;
        const lo = pin & 0xffff;
        if (lo != 0 and lo <= MAX_NODES) want |= @as(u64, 1) << @intCast(lo - 1);
    }
    const out_node = if (ma.func == 1) fnOut(ma) else null;
    if (out_node) |o| want |= @as(u64, 1) << @intCast(o);
    var fr: Frame = undefined;
    fr.sc = sc;
    fr.depth = 0;
    fr.args = null;
    fr.mats = mats;
    var calls: u32 = MAX_CALLS;
    fr.calls = &calls;
    fr.live = liveOf(ma, want);
    const konst = gcFold(ma, &fr); // (what does not vary: copied in)
    fr.live &= ~konst;
    // the box coordinates of the corners, or the mesh's UVs
    if (sc.uvp) |uv| {
        sc.box = uv.*;
    } else sc.box = tx.boxUv(sc.p0o, m.add(sc.p0o, sc.e1o), m.add(sc.p0o, sc.e2o));
    at(ma, sc, &fr, sc.u, sc.v);
    if (out_node) |o| {
        const c = inOf(&nodesOf(ma)[o], 0, &fr, o);
        copy.base = .{ c[0], c[1], c[2] };
        sc.flags |= 1 << PIN_BASE;
    }
    // the pins into the copy
    for (pins[0..NPINS], 0..) |pin, p| {
        const lo = pin & 0xffff;
        if (lo == 0 or lo > n or p == PIN_NORMAL) continue;
        const r = fr.val[lo - 1][(pin >> 16) & (NOUTS - 1)];
        switch (p) {
            PIN_BASE => copy.base = .{ r[0], r[1], r[2] },
            PIN_METAL => copy.metallic = sat(r[3]),
            PIN_SPEC => copy.specular = sat(r[3]),
            PIN_ROUGH => copy.roughness = sat(r[3]),
            PIN_EMIT => {
                copy.emission = .{ r[0], r[1], r[2] };
                if (!(copy.strength > 0)) copy.strength = 1;
            },
            PIN_ALPHA => copy.alpha = sat(r[3]),
            PIN_AO => setF(copy, 0, sat(r[3])),
            PIN_COAT => copy.coat = sat(r[3]),
            PIN_COATR => copy.coat_rough = sat(r[3]),
            PIN_TRANS => copy.transmission = sat(r[3]),
            PIN_IOR => copy.ior = smin(smax(r[3], 1), 3),
            PIN_MASK => setF(copy, 1, sat(r[3])),
            else => {},
        }
        sc.flags |= @as(u32, 1) << @intCast(p);
    }
    if (coverage) return true;
    // the normal
    const pl = pins[PIN_NORMAL] & 0xffff;
    if (pl == 0 or pl > n) return true;
    const b = pl - 1;
    const nd = &nodesOf(ma)[b];
    if (nd.type == T_NMAP) {
        normalMap(ma, sc, &fr, b, nd);
    } else if (nd.type == T_BUMP) {
        bump(ma, sc, &fr, b, nd, konst);
    }
    return true;
}

/// A bump node's height, a little along both edges; Blinn's tilt.
fn bump(ma: *const Material, sc: *SC, fr: *Frame, b: u32, nd: *const Node, konst: u64) void {
    const strength0 = nd.p[0];
    const h = fr.val[b][0][3];
    fr.live = liveOf(ma, @as(u64, 1) << @intCast(b)) & ~konst; // from here on only its height (its constants: in the frame)
    const eps: f32 = 0.001; // the step in object units
    const du = smin(eps / smax(@sqrt(dot3(sc.e1o, sc.e1o)), tiny), 0.1);
    const dv = smin(eps / smax(@sqrt(dot3(sc.e2o, sc.e2o)), tiny), 0.1);
    at(ma, sc, fr, sc.u + du, sc.v);
    const hu = (fr.val[b][0][3] - h) / du;
    at(ma, sc, fr, sc.u, sc.v + dv);
    const hv = (fr.val[b][0][3] - h) / dv;
    // N = Pu x Pv; D = (hu (N x Pv) - hv (N x Pu)) / |N|^2
    const nn = cross(sc.pu, sc.pv);
    const l = @sqrt(dot3(nn, nn));
    const l2 = l * l;
    if (!(l2 > tiny)) return;
    const inv = 1 / l2;
    const nv = cross(nn, sc.pv);
    const nu = cross(nn, sc.pu);
    const side = dot3(nn, sc.n);
    const s = (if (side >= 0) strength0 else -strength0) * inv;
    var r: m.V3 = undefined;
    for (0..3) |c| r[c] = (nv[c] * hu - nu[c] * hv) * s + sc.n[c];
    if (unitOf(r)) |u| {
        sc.n = u;
        sc.flags |= 1 << PIN_NORMAL;
    }
}

/// A tangent-space map: the frame comes from the mesh's UVs (OpenGL: green = +v).
fn normalMap(ma: *const Material, sc: *SC, fr: *const Frame, b: u32, nd: *const Node) void {
    const uv = sc.uvp orelse return;
    // fed by an image read as data: its values as they are
    var raw = false;
    const from = nd.in[0].link & 0xffff;
    if (from != 0 and from <= MAX_NODES) {
        const f = &nodesOf(ma)[from - 1];
        if (f.type == T_IMAGE and f.p[2] >= 0.5) raw = true;
    }
    const c = fr.val[b][0];
    var t: m.V3 = undefined;
    for (0..3) |k| {
        const x = if (raw) c[k] else tx.unlin(c[k]);
        t[k] = x + x - 1;
        if (k != 2) t[k] *= nd.p[0];
    }
    if (nd.p[1] >= 0.5) t[1] = -t[1]; // (DirectX maps: green points down)
    const du1 = uv[2] - uv[0];
    const dv1 = uv[3] - uv[1];
    const du2 = uv[4] - uv[0];
    const dv2 = uv[5] - uv[1];
    const det = du1 * dv2 - du2 * dv1;
    if (!(@abs(det) > tiny)) return;
    const k = 1 / det;
    var tt: m.V3 = undefined;
    var bb: m.V3 = undefined;
    for (0..3) |i| {
        tt[i] = (sc.pu[i] * dv2 - sc.pv[i] * dv1) * k;
        bb[i] = (sc.pv[i] * du1 - sc.pu[i] * du2) * k;
    }
    tt = orthoTo(tt, sc.n);
    bb = orthoTo(bb, sc.n);
    var r: m.V3 = undefined;
    for (0..3) |i| r[i] = tt[i] * t[0] + bb[i] * t[1] + sc.n[i] * t[2];
    if (unitOf(r)) |u| {
        sc.n = u;
        sc.flags |= 1 << PIN_NORMAL;
    }
}

/// graph_thumbs: every node's first output over a square (u, v 0..1; the object
/// point (2u - 1, 2v - 1, 0), the normal and the eye along +z), out[node][pixel]
/// (nn x nn): colours as sqrt bytes (sRGB-ish), values grey (sqrt too), vectors as
/// 0.5 + v / 2. The node editor's thumbnails.
pub fn thumbs(ma: *const Material, mats: []const Material, out: []u32, nn: u32) void {
    var sc = SC{};
    sc.e1o = .{ 0.001, 0, 0 };
    sc.e2o = .{ 0, 0.001, 0 };
    sc.pu = .{ 0.001, 0, 0 };
    sc.pv = .{ 0, 0.001, 0 };
    sc.n = .{ 0, 0, 1 };
    sc.wv = .{ 0, 0, 1 };
    sc.vc = .{ 1, 1, 1 };
    var uvs: [6]f32 = undefined;
    sc.uvp = &uvs;
    var fr: Frame = undefined;
    fr.live = ~@as(u64, 0);
    fr.depth = 0;
    fr.args = null;
    fr.sc = &sc;
    fr.mats = mats;
    const nf: f32 = @floatFromInt(nn);
    const cnt = @min(std.mem.readInt(u32, ma.graph[0..4], .little), MAX_NODES);
    var px: u32 = 0;
    while (px < nn * nn) : (px += 1) {
        const u = (@as(f32, @floatFromInt(px % nn)) + 0.5) / nf;
        const v = 1.0 - (@as(f32, @floatFromInt(px / nn)) + 0.5) / nf;
        uvs = .{ u, v, u, v, u, v };
        const p: m.V3 = .{ u + u - 1.0, v + v - 1.0, 0 };
        fr.uv = .{ u, v };
        fr.p = p;
        sc.p0o = p;
        sc.wp = p;
        var calls: u32 = MAX_CALLS;
        fr.calls = &calls;
        evalGraph(ma, &fr);
        for (0..cnt) |i| {
            const t = nodesOf(ma)[i].type;
            const kind: u8 = if (t >= 1 and t <= shnodes.metas.len) shnodes.metas[t - 1].out_kinds[0] else 0;
            const val = fr.val[i][0];
            var c: u32 = 0;
            for (0..3) |ch| {
                var x = val[ch];
                if (kind == 1) x = val[3];
                if (kind == 2) {
                    x = x * 0.5 + 0.5;
                } else {
                    x = if (x > 0) x else 0;
                    x = @sqrt(x);
                }
                x = if (x > 0) x else 0;
                x = if (x < 1) x else 1;
                c = (c << 8) | @as(u32, @intCast(@as(i32, @intFromFloat(roundEven(x * 255.0))) & 0xff));
            }
            out[i * nn * nn + px] = c;
        }
    }
}

/// graph_probe (the original's `nodeval`): every node at a point (the object
/// and world position xyz, UV u v, normal +y, the eye along +z): node's (1..)
/// output k / 4, channel k % 4 (0..2 the colour, 3 the value).
pub fn probe(ma: *const Material, mats: []const Material, node: u32, k: u32, xyz: m.V3, uv: [2]f32) ?f32 {
    if (node == 0 or node > count(ma)) return null;
    var sc = SC{};
    sc.p0o = xyz;
    sc.wp = xyz;
    sc.e1o = .{ 0.001, 0, 0 };
    sc.e2o = .{ 0, 0, 0.001 };
    sc.pu = sc.e1o;
    sc.pv = sc.e2o;
    const uvs = [6]f32{ uv[0], uv[1], uv[0], uv[1], uv[0], uv[1] };
    sc.uvp = &uvs;
    var fr: Frame = undefined;
    fr.p = xyz;
    fr.uv = uv;
    fr.live = ~@as(u64, 0);
    fr.depth = 0;
    fr.args = null;
    fr.sc = &sc;
    fr.mats = mats;
    var calls: u32 = MAX_CALLS;
    fr.calls = &calls;
    evalGraph(ma, &fr);
    return fr.val[node - 1][(k >> 2) & (NOUTS - 1)][k & 3];
}

// --- tests --------------------------------------------------------------------------------

const t_ = std.testing;

test "noise: Ken Perlin's numbers, fBm in range" {
    try t_.expectEqual(@as(f32, 0), perlin(.{ 0, 0, 0 }));
    try t_.expectEqual(@as(f32, 0), perlin(.{ 3, 7, 2 }));
    // his reference implementation at (3.14, 42, 7) is 0.13691995878400012
    try t_.expectApproxEqAbs(@as(f32, 0.13691995878400012), perlin(.{ 3.14, 42, 7 }), 1e-5);
    for (0..200) |i| {
        const x = @as(f32, @floatFromInt(i)) * 0.37 - 20;
        const v = fbm(.{ x, x * 0.5, -x }, 2.5, 5, 0.6);
        try t_.expect(v >= 0 and v <= 1);
    }
}

test "math: the operations' edge cases as the original" {
    try t_.expectEqual(@as(f32, 0), mathOp(3, 1, 0, 0)); // divide by 0
    try t_.expectEqual(@as(f32, 0), mathOp(4, -2, 2, 0)); // pow of a negative
    try t_.expectEqual(@as(f32, 2), mathOp(16, 2.5, 0, 0)); // round: to even
    try t_.expectEqual(@as(f32, 4), mathOp(16, 3.5, 0, 0));
    try t_.expectEqual(@as(f32, -1), mathOp(24, -7, 3, 0)); // mod: truncating
    try t_.expectEqual(@as(f32, 1), mathOp(22, 1, 1, 0)); // step
    try t_.expectEqual(@as(f32, 0.5), mathOp(23, 0, 1, 0.5)); // smoothstep
    try t_.expectEqual(@as(f32, 9), mathOp(99, 9, 1, 1)); // unknown: a
}

test "damaged graphs: nothing crashes, nothing reads outside the frame" {
    var ma = Material{};
    const mats = [_]Material{};
    var rng = std.Random.DefaultPrng.init(0x7eb1);
    const r = rng.random();
    for (0..4000) |_| {
        r.bytes(&ma.graph);
        ma.func = r.int(u32) & 1;
        std.mem.writeInt(u32, ma.graph[0..4], r.int(u32) % 200, .little);
        // every value bad, in some graphs: NaN, huge
        if (r.boolean()) {
            for (nodesMut(&ma)) |*nd| {
                nd.type = r.int(u32) % 50;
                for (&nd.p) |*p| p.* = if (r.boolean()) std.math.nan(f32) else r.float(f32) * 1e30;
            }
        }
        var sc = SC{ .e1o = .{ 1, 0, 0 }, .e2o = .{ 0, 0, 1 }, .pu = .{ 1, 0, 0 }, .pv = .{ 0, 0, 1 } };
        var copy = ma;
        _ = shade(&ma, &mats, &sc, &copy, false);
        _ = probe(&ma, &mats, 1, 3, .{ 1, 2, 3 }, .{ 0.5, 0.5 });
    }
}

test "a function calling itself gives up, not the stack" {
    var mats = [_]Material{Material{}};
    const f = &mats[0];
    f.func = 1;
    std.mem.writeInt(u32, f.graph[0..4], 3, .little);
    const nodes = nodesMut(f);
    for (nodes[0..2]) |*x| {
        x.* = std.mem.zeroes(Node);
        x.type = T_FNCALL;
        x.p[0] = 1; // itself
        x.in[0].v = .{ 1, 1, 1 };
    }
    nodes[1].in[0].link = 1;
    nodes[2] = std.mem.zeroes(Node);
    nodes[2].type = T_FNOUT;
    nodes[2].in[0].link = 2;
    var sc = SC{ .e1o = .{ 1, 0, 0 }, .e2o = .{ 0, 0, 1 }, .pu = .{ 1, 0, 0 }, .pv = .{ 0, 0, 1 } };
    var copy = mats[0];
    try t_.expect(shade(f, &mats, &sc, &copy, false));
    try t_.expectEqual(@as(f32, 0), copy.base[0]); // (black, deep down)
}

test "folded constants give the same results as evaluating all (matcache's self-test, wider)" {
    var mats = [_]Material{Material{}};
    const ma = &mats[0];
    var rng = std.Random.DefaultPrng.init(0x2545f491);
    const r = rng.random();
    const types = [_]u32{ 7, 7, 7, 5, 19, 26, 17, 16, 2, 10, 6, 21, 20, 28, 31, 36, 37, 38, 25, 11, 29, 30, 27, 8 };
    var bad: usize = 0;
    var folded: usize = 0;
    for (0..300) |_| {
        ma.graph = @splat(0);
        const n: u32 = 2 + r.uintLessThan(u32, MAX_NODES - 1);
        std.mem.writeInt(u32, ma.graph[0..4], n, .little);
        for (nodesMut(ma)[0..n], 0..) |*nd, i| {
            nd.* = std.mem.zeroes(Node);
            nd.type = if (i == 0) 10 else types[r.uintLessThan(usize, types.len)];
            nd.p = .{ @floatFromInt(r.uintLessThan(u32, 32)), r.float(f32) * 4 + 0.5, 2, r.float(f32) };
            for (&nd.in) |*l| {
                const x = (r.float(f32) - 0.5) * 16;
                l.v = .{ x, x * 0.5, -x };
                if (i > 0 and r.boolean()) l.link = (r.uintLessThan(u32, 4) << 16) | (1 + r.uintLessThan(u32, @intCast(i)));
            }
        }
        for (pinsMut(ma)[0..NPINS]) |*p| p.* = if (r.uintLessThan(u32, 3) == 0) (1 + r.uintLessThan(u32, n)) else 0;
        pinsMut(ma)[PIN_BASE] = n;
        pinsMut(ma)[PIN_NORMAL] = if (r.boolean()) 1 + r.uintLessThan(u32, n) else 0;
        material.version +%= 1;
        for (0..4) |k| {
            const kf: f32 = @floatFromInt(k);
            var sc = SC{ .p0o = .{ kf, kf * 2, -kf }, .e1o = .{ 1, 0, 0 }, .e2o = .{ 0, 0, 1 }, .pu = .{ 1, 0, 0 }, .pv = .{ 0, 0, 1 }, .u = 0.25, .v = 0.5 };
            var a = mats[0];
            var b = mats[0];
            var sc2 = sc;
            fold_on = false;
            _ = shade(ma, &mats, &sc, &a, false);
            fold_on = true;
            _ = shade(ma, &mats, &sc2, &b, false);
            if (!std.mem.eql(u8, std.mem.asBytes(&a)[0..material.FILE_PART], std.mem.asBytes(&b)[0..material.FILE_PART]) or
                !std.mem.eql(u8, std.mem.asBytes(&sc.n), std.mem.asBytes(&sc2.n)) or sc.flags != sc2.flags) bad += 1;
        }
        const e = &gc_tab[(@intFromPtr(ma) >> 12) & (GC_N - 1)];
        if (e.konst != 0) folded += 1;
    }
    try t_.expectEqual(@as(usize, 0), bad);
    try t_.expect(folded > 100); // (and something was folded)
}
