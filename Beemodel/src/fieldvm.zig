// The field VM (fieldvm.s, fvjit.s): per-element programs for geometry nodes.
//
// A field (a value or vector per point, made of position, normal, index, math,
// noise and random nodes) compiles to a small program over scalar registers (a
// vector is three). It runs a block of 256 elements at a time, the blocks
// spread over the job threads.
//
// The original has two ways to run a program: an interpreter (one SSE loop per
// instruction over a block) and, for 1024 elements or more, a template JIT that
// emits x86-64 at run time (AVX, 8 lanes, the program fused into one loop over
// the block, 32 lanes at a time). Every operation is lane-wise and both call the
// same per-element function for pow, mod, sin, cos, noise and random, so both
// give the same bits (its self-test checks that). The port does the same
// without writing code at run time: `interp` is the interpreter, `fused` the
// JIT's shape (@Vector(8) code, all instructions per 32-lane chunk, the
// registers in a small L1 frame). BEEMODEL_JIT=0 turns the fused path off,
// =sse keeps it to 4 lanes (the original's modes).
//
// The transcendentals are the original's x87 instructions (fsin, fcos, fyl2x /
// f2xm1 / fscale), run as such: a libm would differ in the last bit.
//
// An instruction is 24 bytes: op, dst, a, b, c (registers), three spare bytes,
// four immediates.
const std = @import("std");
const builtin = @import("builtin");
const m = @import("math.zig");
const jobs = @import("jobs.zig");
const fbm = @import("shgraph.zig").fbm;

pub const B = 256; // elements per block
pub const REGS = 64;
pub const JIT_MIN = 1024; // elements worth "compiling" for
const MAX_THREADS = 65;

pub const OP_CONST = 1;
pub const OP_PX = 2;
pub const OP_PY = 3;
pub const OP_PZ = 4;
pub const OP_NX = 5;
pub const OP_NY = 6;
pub const OP_NZ = 7;
pub const OP_INDEX = 8;
pub const OP_ADD = 10;
pub const OP_SUB = 11;
pub const OP_MUL = 12;
pub const OP_DIV = 13;
pub const OP_MIN = 14;
pub const OP_MAX = 15;
pub const OP_LT = 16;
pub const OP_GT = 17;
pub const OP_POW = 18;
pub const OP_MOD = 19;
pub const OP_ABS = 20;
pub const OP_SQRT = 21;
pub const OP_FLOOR = 22;
pub const OP_SIN = 23;
pub const OP_COS = 24;
pub const OP_NOISE = 26;
pub const OP_RAND = 27;
pub const OP_MOV = 28;
pub const OP_SEL = 29; // dst = c > 0.5 ? a : b

pub const Ins = extern struct {
    op: u8 = 0,
    dst: u8 = 0,
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    imm: [4]f32 = .{ 0, 0, 0, 0 },
};
comptime {
    std.debug.assert(@sizeOf(Ins) == 24);
}

pub const Out = struct {
    reg: u32,
    dst: [*]f32,
};

/// fv_ctx: the program, its inputs (structure of arrays: px py pz nx ny nz
/// index; null reads 0) and where registers go when a block ends.
pub const Ctx = struct {
    n: u32 = 0,
    prog: []const Ins = &.{},
    in: [7]?[*]const f32 = @splat(null),
    outs: []const Out = &.{},
};

pub const Mode = enum(u8) { off = 0, sse = 1, avx = 2 };
/// fvj_mode: null until decided (BEEMODEL_JIT, the preference).
pub var mode: ?Mode = null;
/// Preferences: the JIT on (pr_jit).
pub var pref_jit: bool = true;
/// Programs run the fused way (fvj_compiles counts compilations; here runs).
pub var fused_runs: u32 = 0;

fn decide() Mode {
    if (mode) |md| return md;
    var md: Mode = if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx)) .avx else .sse;
    if (!pref_jit) md = .off;
    if (@import("spawn.zig").getenv("BEEMODEL_JIT")) |v| {
        if (v.len > 0 and v[0] == '0') md = .off;
        if (v.len > 0 and v[0] == 's') md = .sse;
    }
    mode = md;
    return md;
}

// --- the per-element operations (fv_scalar1) --------------------------------------------

/// cvttss2si: out of range or NaN gives the "integer indefinite".
pub inline fn cvtt(x: f32) i32 {
    return asm ("cvttss2si %[x], %[r]"
        : [r] "=r" (-> i32),
        : [x] "x" (x),
    );
}

// The x87 instructions in both of Zig's backends: the self-hosted one (debug
// builds) reads an AT&T "l" suffix as a dword and names registers %st1; LLVM
// wants "s" for a single and %st(1).
const LLVM = builtin.zig_backend == .stage2_llvm;
const LD32 = if (LLVM) "flds" else "fldl";
const ST32 = if (LLVM) "fstps" else "fstpl";
const R0 = if (LLVM) "%%st(0)" else "%%st0";
const R1 = if (LLVM) "%%st(1)" else "%%st1";
/// st0 = st0 - st1
const SUB01 = if (LLVM) "fsub %%st(1), %%st" else "fsub %%st1, %%st0";

const asm_sin = LD32 ++ " (%%rax)\nfsin\n" ++ ST32 ++ " (%%rax)\n";
const asm_cos = LD32 ++ " (%%rax)\nfcos\n" ++ ST32 ++ " (%%rax)\n";
const asm_sincos = LD32 ++ " (%%rax)\nfsincos\n" ++ ST32 ++ " 4(%%rax)\n" ++ ST32 ++ " (%%rax)\n";
// fld b; fld a; fyl2x; fld st0; frndint; then y - r (the original's fsub
// st(1), st(0) and fxch, as fxch and fsub st(0), st(1): the same values);
// f2xm1; fld1; faddp; fscale; fstp st(1)
const asm_pow = LD32 ++ " (%%rax)\n" ++ LD32 ++ " 4(%%rax)\nfyl2x\nfld " ++ R0 ++ "\nfrndint\nfxch " ++ R1 ++ "\n" ++ SUB01 ++
    "\nf2xm1\nfld1\nfaddp " ++ R0 ++ ", " ++ R1 ++ "\nfscale\nfstp " ++ R1 ++ "\n" ++ ST32 ++ " (%%rax)\n";

/// fsin through fstp single.
pub fn x87sin(x: f32) f32 {
    var v: f32 = x;
    asm volatile (asm_sin
        :
        : [p] "{rax}" (&v),
        : .{ .memory = true });
    return v;
}
/// fcos through fstp single.
pub fn x87cos(x: f32) f32 {
    var v: f32 = x;
    asm volatile (asm_cos
        :
        : [p] "{rax}" (&v),
        : .{ .memory = true });
    return v;
}
/// fsincos through fstp single: .{ sin, cos } (sincos in mesh.s).
pub fn x87sincos(x: f32) [2]f32 {
    var v: [2]f32 = .{ x, 0 };
    asm volatile (asm_sincos
        :
        : [p] "{rax}" (&v),
        : .{ .memory = true });
    return v;
}
/// a^b = 2^(b log2 a) on the x87 (a > 0).
pub fn x87pow(a: f32, b: f32) f32 {
    var v: [2]f32 = .{ b, a };
    asm volatile (asm_pow
        :
        : [p] "{rax}" (&v),
        : .{ .memory = true });
    return v[0];
}

const noff = [9]f32{ 0, 0, 0, 17.31, 41.77, 7.13, 31.59, 3.23, 23.41 };
const inv24: f32 = 5.9604645e-8;

/// gn_hash's cousin: the Random Value node's hash of (index, seed).
pub fn randHash(index: i32, seed: i32) u32 {
    var a: u32 = @as(u32, @bitCast(index)) *% 0x27d4eb2d;
    const d: u32 = @as(u32, @bitCast(seed)) *% 0x165667b1;
    a ^= d;
    a ^= a >> 15;
    a *%= 0x2c1b3c6d;
    a ^= a >> 12;
    a *%= 0x297a2d39;
    a ^= a >> 15;
    return a;
}

/// fv_scalar1: pow, mod, sin, cos, noise, rand for one element.
pub fn scalar1(in: *const Ins, a: f32, b: f32, c: f32) f32 {
    switch (in.op) {
        OP_POW => {
            if (!(a > 0)) return 0;
            return x87pow(a, b);
        },
        OP_MOD => {
            if (b == 0 or std.math.isNan(b)) return 0; // (comiss: equal or unordered)
            var t = a / b;
            t = @floor(t);
            t *= b;
            return a - t;
        },
        OP_SIN => return x87sin(a),
        OP_COS => return x87cos(a),
        OP_NOISE => {
            var k: u32 = @as(u32, @bitCast(cvtt(in.imm[3]))) & 3;
            if (k > 2) k = 0;
            const p: m.V3 = .{ a + noff[k * 3], b + noff[k * 3 + 1], c + noff[k * 3 + 2] };
            return fbm(p, in.imm[0], cvtt(in.imm[1]), in.imm[2]);
        },
        OP_RAND => {
            const h = randHash(cvtt(a), cvtt(in.imm[0])) >> 8;
            var u = @as(f32, @floatFromInt(h)) * inv24;
            const span = in.imm[2] - in.imm[1];
            u *= span;
            return u + in.imm[1];
        },
        else => return 0,
    }
}

fn isScalar(op: u8) bool {
    return switch (op) {
        OP_POW, OP_MOD, OP_SIN, OP_COS, OP_NOISE, OP_RAND => true,
        OP_CONST, OP_PX...OP_INDEX, OP_ADD...OP_GT, OP_ABS, OP_SQRT, OP_FLOOR, OP_MOV, OP_SEL => false,
        else => true, // (unknown: fv_scalar1 gives 0)
    };
}

// --- the lane-wise operations, any width ------------------------------------------------

fn Lanes(comptime W: usize) type {
    return struct {
        const V = @Vector(W, f32);
        const U = @Vector(W, u32);
        const zero: V = @splat(0);
        const one: V = @splat(1);
        const half: V = @splat(0.5);

        /// One instruction over `len` lanes (a multiple of W) of registers in
        /// `regs` (register r at r * stride), inputs from element `first`.
        inline fn op(ins: *const Ins, regs: [*]f32, stride: usize, len: usize, ctx: *const Ctx, first: usize, n_live: usize) void {
            const d = regs + @as(usize, ins.dst) * stride;
            const pa = regs + @as(usize, ins.a) * stride;
            const pb = regs + @as(usize, ins.b) * stride;
            const pc = regs + @as(usize, ins.c) * stride;
            var i: usize = 0;
            switch (ins.op) {
                OP_CONST => {
                    const k: V = @splat(ins.imm[0]);
                    while (i < len) : (i += W) st(d + i, k);
                },
                OP_PX...OP_INDEX => {
                    if (ctx.in[ins.op - OP_PX]) |src| {
                        // (only the live elements: the rest of a short block stays)
                        @memcpy(d[0..n_live], src[first..][0..n_live]);
                    } else {
                        while (i < len) : (i += W) st(d + i, zero);
                    }
                },
                OP_ADD => while (i < len) : (i += W) st(d + i, ld(pa + i) + ld(pb + i)),
                OP_SUB => while (i < len) : (i += W) st(d + i, ld(pa + i) - ld(pb + i)),
                OP_MUL => while (i < len) : (i += W) st(d + i, ld(pa + i) * ld(pb + i)),
                OP_DIV => while (i < len) : (i += W) {
                    // (0 where b is 0: cmpneqps, so a NaN b divides)
                    const x = ld(pa + i);
                    const y = ld(pb + i);
                    st(d + i, @select(f32, y != zero, x / y, zero));
                },
                OP_MIN => while (i < len) : (i += W) {
                    const x = ld(pa + i);
                    const y = ld(pb + i);
                    st(d + i, @select(f32, x < y, x, y));
                },
                OP_MAX => while (i < len) : (i += W) {
                    const x = ld(pa + i);
                    const y = ld(pb + i);
                    st(d + i, @select(f32, x > y, x, y));
                },
                OP_LT => while (i < len) : (i += W) st(d + i, @select(f32, ld(pa + i) < ld(pb + i), one, zero)),
                OP_GT => while (i < len) : (i += W) st(d + i, @select(f32, ld(pb + i) < ld(pa + i), one, zero)),
                OP_ABS => while (i < len) : (i += W) {
                    const x: U = @bitCast(ld(pa + i));
                    st(d + i, @bitCast(x & @as(U, @splat(0x7fffffff))));
                },
                OP_SQRT => while (i < len) : (i += W) {
                    const x = ld(pa + i);
                    st(d + i, @sqrt(@select(f32, x > zero, x, zero)));
                },
                OP_FLOOR => while (i < len) : (i += W) st(d + i, @floor(ld(pa + i))),
                OP_MOV => while (i < len) : (i += W) st(d + i, ld(pa + i)),
                OP_SEL => while (i < len) : (i += W) {
                    st(d + i, @select(f32, half < ld(pc + i), ld(pa + i), ld(pb + i)));
                },
                else => {
                    var e: usize = 0;
                    while (e < n_live) : (e += 1) d[e] = scalar1(ins, pa[e], pb[e], pc[e]);
                },
            }
        }
        inline fn ld(p: [*]const f32) V {
            return p[0..W].*;
        }
        inline fn st(p: [*]f32, v: V) void {
            p[0..W].* = v;
        }
    };
}

// --- the interpreter (fv_job) -----------------------------------------------------------

/// Each thread's registers: 64 x 256 floats.
var scratch: [MAX_THREADS]?[]align(64) f32 = @splat(null);

fn regsOf(thread: usize) ?[*]f32 {
    const t = @min(thread, MAX_THREADS - 1);
    if (scratch[t] == null) return null;
    return scratch[t].?.ptr;
}

/// Run blocks [lo, hi) of the program, the interpreter's way.
fn interpBlocks(ctx: *const Ctx, regs: [*]f32, lo: usize, hi: usize) void {
    const L = Lanes(4);
    var blk = lo;
    while (blk < hi) : (blk += 1) {
        const first = blk * B;
        const n_live = @min(B, ctx.n - first);
        const len = (n_live + 3) & ~@as(usize, 3); // (whole SSE groups)
        for (ctx.prog) |*ins| L.op(ins, regs, B, len, ctx, first, n_live);
        for (ctx.outs) |o| @memcpy(o.dst[first..][0..n_live], (regs + o.reg * B)[0..n_live]);
    }
}

// --- the JIT's shape --------------------------------------------------------------------

/// The fused loop's chunk: 4 groups of 8 lanes (fvj: FVJ_U interleaved groups).
const CH = 32;

fn fusedBlock(comptime W: usize, ctx: *const Ctx, frame: [*]f32, first: usize) void {
    const L = Lanes(W);
    var off: usize = 0;
    while (off < B) : (off += CH) {
        for (ctx.prog) |*ins| L.op(ins, frame, CH, CH, ctx, first + off, CH);
        for (ctx.outs) |o| @memcpy(o.dst[first + off ..][0..CH], (frame + o.reg * CH)[0..CH]);
    }
}

fn fusedBlocks(ctx: *const Ctx, regs: [*]f32, md: Mode, lo: usize, hi: usize) void {
    var blk = lo;
    while (blk < hi) : (blk += 1) {
        const first = blk * B;
        if (ctx.n - first < B) {
            interpBlocks(ctx, regs, blk, blk + 1); // (a short block: interpreted)
            continue;
        }
        if (md == .avx) fusedBlock(8, ctx, regs, first) else fusedBlock(4, ctx, regs, first);
    }
}

const Job = struct {
    ctx: *const Ctx,
    md: Mode,
    fail: bool = false,
};

fn job(p: *anyopaque, lo: usize, hi: usize, thread: usize) void {
    const j: *Job = @ptrCast(@alignCast(p));
    const regs = regsOf(thread) orelse {
        j.fail = true;
        return;
    };
    if (j.md == .off) interpBlocks(j.ctx, regs, lo, hi) else fusedBlocks(j.ctx, regs, j.md, lo, hi);
}

/// The registers every thread uses (the caller allocates: workers may not).
fn ensureScratch() bool {
    const n = @min(jobs.count(), MAX_THREADS);
    for (0..n) |t| {
        if (scratch[t] != null) continue;
        scratch[t] = std.heap.page_allocator.alignedAlloc(f32, .@"64", REGS * B) catch return false;
    }
    return true;
}

/// fv_run: the program over its elements (parallel). False: no memory.
pub fn run(ctx: *const Ctx) bool {
    return runAs(ctx, if (ctx.n >= JIT_MIN and ctx.prog.len > 0) decide() else .off);
}

/// The program run one way (tests compare the ways).
pub fn runAs(ctx: *const Ctx, md: Mode) bool {
    const blocks = (@as(usize, ctx.n) + B - 1) / B;
    if (blocks == 0) return true;
    if (!ensureScratch()) return false;
    for (ctx.prog) |ins| {
        // (registers past 63 read and write the next thread's: never made)
        if (ins.dst >= REGS or ins.a >= REGS or ins.b >= REGS or ins.c >= REGS) return false;
    }
    for (ctx.outs) |o| if (o.reg >= REGS) return false;
    if (md != .off) fused_runs +%= 1;
    var j = Job{ .ctx = ctx, .md = md };
    jobs.parallelFor(blocks, 2, &j, job);
    return !j.fail;
}

// --- tests ------------------------------------------------------------------------------

const ft_ops = [_]u8{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 26, 27, 28, 29, 10 };

/// A random program (the self-test's shape): loads, constants, then random ops.
fn randomProg(r: std.Random, prog: []Ins) []Ins {
    var n: usize = 0;
    for (0..7) |k| {
        prog[n] = .{ .op = @intCast(OP_PX + k), .dst = @intCast(k) };
        n += 1;
    }
    prog[n] = .{ .op = OP_CONST, .dst = 7, .imm = .{ r.float(f32) * 4 - 2, 0, 0, 0 } };
    n += 1;
    var used: u8 = 8;
    while (n < prog.len) : (n += 1) {
        const op = ft_ops[r.uintLessThan(usize, ft_ops.len)];
        var in = Ins{ .op = op, .dst = if (used < REGS) used else r.uintLessThan(u8, REGS), .a = r.uintLessThan(u8, used), .b = r.uintLessThan(u8, used), .c = r.uintLessThan(u8, used) };
        if (used < REGS) used += 1;
        if (op == OP_NOISE) in.imm = .{ 0.5 + r.float(f32), @floatFromInt(r.uintLessThan(u8, 4) + 1), 0.5, @floatFromInt(r.uintLessThan(u8, 3)) };
        if (op == OP_RAND) in.imm = .{ @floatFromInt(r.uintLessThan(u8, 100)), -1, 1, 0 };
        prog[n] = in;
    }
    return prog[0..n];
}

test "the interpreter and the fused paths give the same bits" {
    jobs.init();
    var prng = std.Random.DefaultPrng.init(1234);
    const r = prng.random();
    const N = 3000; // (whole blocks and a short one)
    const ta = std.testing.allocator;
    var ins: [7][]f32 = undefined;
    for (&ins, 0..) |*a, k| {
        a.* = try ta.alloc(f32, N);
        for (a.*, 0..) |*x, i| x.* = if (k == 6) @floatFromInt(i) else r.float(f32) * 8 - 4;
    }
    defer for (ins) |a| ta.free(a);
    var outs: [3][3][]f32 = undefined;
    for (&outs) |*w| for (w) |*a| {
        a.* = try ta.alloc(f32, N);
    };
    defer for (outs) |w| for (w) |a| ta.free(a);
    var progbuf: [40]Ins = undefined;
    for (0..60) |_| {
        const prog = randomProg(r, &progbuf);
        for ([_]Mode{ .off, .sse, .avx }, 0..) |md, w| {
            const o = [_]Out{ .{ .reg = prog[prog.len - 1].dst, .dst = outs[w][0].ptr }, .{ .reg = prog[prog.len - 2].dst, .dst = outs[w][1].ptr }, .{ .reg = prog[prog.len - 5].dst, .dst = outs[w][2].ptr } };
            var ctx = Ctx{ .n = N, .prog = prog, .outs = &o };
            for (0..7) |k| ctx.in[k] = ins[k].ptr;
            try std.testing.expect(runAs(&ctx, md));
        }
        for (1..3) |w| for (0..3) |q| {
            try std.testing.expectEqualSlices(u32, @as([]const u32, @ptrCast(outs[0][q])), @as([]const u32, @ptrCast(outs[w][q])));
        };
    }
}

test "the operations' edge cases (the original's instructions)" {
    // div: 0 where b is 0; min / max: b when they do not compare
    const L = Lanes(4);
    var regs: [4 * 4]f32 = undefined;
    const ctx = Ctx{};
    regs[0..4].* = .{ 1, -1, std.math.nan(f32), 0 };
    regs[4..8].* = .{ 0, -0.0, 2, std.math.nan(f32) };
    L.op(&.{ .op = OP_DIV, .dst = 2, .a = 0, .b = 1 }, &regs, 4, 4, &ctx, 0, 4);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(regs[8])));
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(regs[9])));
    try std.testing.expect(std.math.isNan(regs[10]) and std.math.isNan(regs[11]));
    L.op(&.{ .op = OP_MIN, .dst = 2, .a = 0, .b = 1 }, &regs, 4, 4, &ctx, 0, 4);
    try std.testing.expect(regs[8] == 0 and regs[9] == -1 and regs[10] == 2 and std.math.isNan(regs[11]));
    L.op(&.{ .op = OP_SQRT, .dst = 2, .a = 0 }, &regs, 4, 4, &ctx, 0, 4);
    try std.testing.expect(regs[8] == 1 and regs[9] == 0 and regs[10] == 0 and regs[11] == 0);
    // pow: 2^(b log2 a) on the x87; mod; rand in [min, max)
    try std.testing.expectEqual(@as(f32, 8), scalar1(&.{ .op = OP_POW }, 2, 3, 0));
    try std.testing.expectEqual(@as(f32, 0), scalar1(&.{ .op = OP_POW }, -2, 3, 0));
    try std.testing.expectEqual(@as(f32, 1), scalar1(&.{ .op = OP_MOD }, -3, 2, 0));
    try std.testing.expectEqual(@as(f32, 0), scalar1(&.{ .op = OP_MOD }, 3, std.math.nan(f32), 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.84147096), scalar1(&.{ .op = OP_SIN }, 1, 0, 0), 1e-7);
    // fsin leaves a huge argument as it is (C2): not a libm sin
    try std.testing.expectEqual(@as(f32, 1e30), x87sin(1e30));
    const sc = x87sincos(0.5);
    try std.testing.expectEqual(x87sin(0.5), sc[0]);
    try std.testing.expectEqual(x87cos(0.5), sc[1]);
    for (0..100) |i| {
        const v = scalar1(&.{ .op = OP_RAND, .imm = .{ 3, -2, 5, 0 } }, @floatFromInt(i), 0, 0);
        try std.testing.expect(v >= -2 and v < 5);
    }
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), cvtt(std.math.nan(f32)));
}
