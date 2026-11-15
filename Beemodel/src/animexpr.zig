// Expressions with units (expr.s): "10*wall + 2mm", "sin(30deg)".
//
//    expr    := term { (+|-) term }
//    term    := unary { (*|/) unary }
//    unary   := (-|+) unary | power
//    power   := primary [ ^ unary ]
//    primary := number [unit] | ( expr ) [unit] | name ( args ) | name
//
// Lengths become scene units (mm cm m in ft; `unit_mm` says how many mm one
// scene unit is: cad.zig keeps it), angles radians (deg rad); plain numbers stay
// as typed. Names are pi, e, a driver's variables (the hook), then the CAD
// parameters (cad.zig, with cycle detection). Functions: sin cos tan asin acos
// atan sqrt abs min max floor ceil round. Doubles throughout; the trigonometry
// and ^ go through the x87 unit as the original's do, so values match it to
// the bit. Not the number fields' expr.zig: that one's trigonometry is in
// degrees.
//
// As the original, a parse goes on after an error with 0 for the part that
// failed, and the first error is the one kept (`err`); evaluations nest (a
// parameter's expression is evaluated inside another's) and share the depth.
const std = @import("std");
const builtin = @import("builtin");

pub const Name = *const fn (name: []const u8) ?f64;

/// The first error of the last evaluation (null: none).
pub var err: ?[]const u8 = null;
/// mm per scene unit (cad.zig keeps it: cad_sync).
pub var unit_mm: f64 = 1000.0;
/// A driver's variables (rig.s' expr_name_hook), asked before the parameters.
pub var name_hook: ?Name = null;
/// The CAD parameters (cad.zig sets it): a value, null when no such parameter.
/// A parameter that fails sets `err` and still counts as known.
pub var param_lookup: Name = noName;

pub const e_syntax = "syntax error";
pub const e_paren = "missing )";
pub const e_name = "unknown name";
pub const e_func = "unknown function";
pub const e_args = "wrong number of arguments";
pub const e_trail = "unexpected text after the expression";
pub const e_deep = "expression too deep";
pub const e_math = "not a number (domain or division)";

// the cursor (ex_p) and the depth (ex_depth): shared by nested evaluations
var src: []const u8 = "";
var pos: usize = 0;
var depth: u32 = 0;

const xd_deg: f64 = 0.017453292519943295;

fn at(k: usize) u8 {
    return if (pos + k < src.len) src[pos + k] else 0;
}

fn ws() void {
    while (at(0) == ' ' or at(0) == 9) pos += 1;
}

fn fail(msg: []const u8) f64 {
    if (err == null) err = msg;
    return 0;
}

fn isLetter(c: u8) bool {
    return (c | 0x20) -% 'a' < 26;
}

/// A name at the cursor (letters, digits after the first, _); the cursor moves
/// past it. The word is its first 31 characters (ex_word).
fn ident() []const u8 {
    const st = pos;
    var n: usize = 0;
    while (true) : (n += 1) {
        const c = at(n);
        if (isLetter(c) or c == '_') continue;
        if (n > 0 and c -% '0' < 10) continue;
        break;
    }
    pos += n;
    return src[st .. st + @min(n, 31)];
}

fn number() f64 {
    var v: f64 = 0;
    while (at(0) -% '0' < 10) : (pos += 1) v = v * 10.0 + @as(f64, @floatFromInt(at(0) - '0'));
    if (at(0) == '.') {
        pos += 1;
        var u: f64 = 1;
        while (at(0) -% '0' < 10) : (pos += 1) {
            u /= 10.0;
            v += @as(f64, @floatFromInt(at(0) - '0')) * u;
        }
    }
    if (at(0) | 0x20 == 'e') {
        var k: usize = 1;
        const neg = at(1) == '-';
        if (neg or at(1) == '+') k = 2;
        if (at(k) -% '0' < 10) {
            var e: u32 = 0;
            while (at(k) -% '0' < 10 and e < 400) : (k += 1) e = e * 10 + (at(k) - '0');
            pos += k;
            while (e > 0) : (e -= 1) v = if (neg) v / 10.0 else v * 10.0;
        }
    }
    return v;
}

const units = [_]struct { []const u8, f64 }{
    .{ "mm", 1.0 }, .{ "cm", 10.0 }, .{ "m", 1000.0 }, .{ "in", 25.4 }, .{ "ft", 304.8 },
    .{ "deg", -1.0 }, .{ "rad", -2.0 },
};

/// v scaled by a unit name right after it, if there is one.
fn unit(v: f64) f64 {
    ws();
    const back = pos;
    if (!isLetter(at(0))) return v;
    const w = ident();
    for (units) |u| {
        if (!std.mem.eql(u8, u[0], w)) continue;
        if (u[1] >= 0) {
            var r = v * u[1]; // a length: mm, then scene units
            if (unit_mm > 0) r /= unit_mm;
            return r;
        }
        return if (u[1] == -1.0) v * xd_deg else v;
    }
    pos = back; // not a unit: the name goes back
    return v;
}

fn parseExpr() f64 {
    depth += 1;
    defer depth -= 1;
    if (depth > 64) return fail(e_deep);
    var v = parseTerm();
    while (true) {
        ws();
        const c = at(0);
        if (c != '+' and c != '-') return v;
        pos += 1;
        const r = parseTerm();
        v = if (c == '+') v + r else v - r;
    }
}

fn parseTerm() f64 {
    var v = parseUnary();
    while (true) {
        ws();
        const c = at(0);
        if (c != '*' and c != '/') return v;
        pos += 1;
        const r = parseUnary();
        v = if (c == '*') v * r else v / r;
    }
}

fn parseUnary() f64 {
    ws();
    if (at(0) == '-') {
        pos += 1;
        return 0.0 - parseUnary();
    }
    if (at(0) == '+') {
        pos += 1;
        return parseUnary();
    }
    return parsePow();
}

fn parsePow() f64 {
    const a = parsePrimary();
    ws();
    if (at(0) != '^') return a;
    pos += 1;
    const b = parseUnary();
    if (!(a > 0)) return 0; // 0^b = 0 (b > 0); negatives: the domain
    return x87pow(a, b);
}

fn parsePrimary() f64 {
    ws();
    const c = at(0);
    if (c == '(') {
        pos += 1;
        const v = parseExpr();
        ws();
        if (at(0) != ')') return fail(e_paren);
        pos += 1;
        return unit(v);
    }
    if (c -% '0' < 10 or c == '.') return unit(number());
    if (!isLetter(c) and c != '_') return fail(e_syntax);
    const w = ident();
    ws();
    if (at(0) == '(') {
        pos += 1;
        return call(w);
    }
    if (std.mem.eql(u8, w, "pi")) return 3.14159265358979323846;
    if (std.mem.eql(u8, w, "e")) return 2.71828182845904523536;
    // a driver's variables, then the parameters (which may evaluate other text)
    const keep_pos = pos;
    const keep_src = src;
    const keep_depth = depth;
    var got: ?f64 = null;
    if (name_hook) |h| got = h(w);
    if (got == null) got = param_lookup(w);
    src = keep_src;
    pos = keep_pos;
    depth = keep_depth;
    return got orelse fail(e_name);
}

const funcs = [_][]const u8{ "sin", "cos", "tan", "asin", "acos", "atan", "sqrt", "abs", "floor", "ceil", "round", "min", "max" };

fn call(f: []const u8) f64 {
    var k: usize = 0;
    while (k < funcs.len and !std.mem.eql(u8, funcs[k], f)) k += 1;
    if (k == funcs.len) return fail(e_func);
    const a = parseExpr();
    ws();
    var b: f64 = 0;
    if (k >= 11) { // min, max: two
        if (at(0) != ',') return fail(e_args);
        pos += 1;
        b = parseExpr();
        ws();
    }
    if (at(0) != ')') return fail(e_paren);
    pos += 1;
    return switch (k) {
        0 => x87un(.sin, a),
        1 => x87un(.cos, a),
        2 => x87un(.tan, a),
        3, 4 => blk: { // asin x = atan2(x, s), acos x = atan2(s, x), s = sqrt(1 - x^2)
            var s = 1.0 - a * a;
            s = if (s > 0) s else 0; // (maxsd: NaN gives 0)
            s = @sqrt(s);
            break :blk if (k == 3) x87atan2(a, s) else x87atan2(s, a);
        },
        5 => x87atan2(a, 1.0),
        6 => @sqrt(a),
        7 => @abs(a),
        8 => floorC(a),
        9 => ceilC(a),
        10 => floorC(a + 0.5),
        11 => if (a < b) a else b, // minsd
        else => if (a > b) a else b, // maxsd
    };
}

/// cvttsd2si: the 64-bit integer toward zero; out of range or NaN: the minimum.
fn cvtt64(x: f64) f64 {
    if (!(x >= -9223372036854775808.0 and x < 9223372036854775808.0)) return -9223372036854775808.0;
    return @floatFromInt(@as(i64, @intFromFloat(x)));
}

fn floorC(x: f64) f64 {
    const r = cvtt64(x);
    return if (r > x) r - 1.0 else r;
}

fn ceilC(x: f64) f64 {
    const r = cvtt64(x);
    return if (r < x) r + 1.0 else r;
}

// ---- the x87 unit, as the original computes ------------------------------------
// Each routine is machine code in .text, called with rdi = &m[0] (m[0] in and
// out, m[1] the second operand): inline assembly differs between Zig's two x86
// backends, bytes do not. The bytes are the original's instructions.

const use_x87 = builtin.cpu.arch == .x86_64;

const X87 = *const fn (*[2]f64) callconv(.c) void;

// fld qword [rdi] = dd 07, fld qword [rdi+8] = dd 47 08, fstp qword [rdi] = dd 1f, ret = c3
export const bee_x87_sin: [7]u8 linksection(".text") = .{ 0xdd, 0x07, 0xd9, 0xfe, 0xdd, 0x1f, 0xc3 };
export const bee_x87_cos: [7]u8 linksection(".text") = .{ 0xdd, 0x07, 0xd9, 0xff, 0xdd, 0x1f, 0xc3 };
// fptan pushes 1 after tan x (nothing when x is out of range: then the pop
// takes x and the store reads an empty register, the indefinite NaN)
export const bee_x87_tan: [9]u8 linksection(".text") = .{ 0xdd, 0x07, 0xd9, 0xf2, 0xdd, 0xd8, 0xdd, 0x1f, 0xc3 };
// fld y; fld x; fpatan: atan(y / x) in the quadrant of (x, y)
export const bee_x87_atan2: [10]u8 linksection(".text") = .{ 0xdd, 0x07, 0xdd, 0x47, 0x08, 0xd9, 0xf3, 0xdd, 0x1f, 0xc3 };
// a^b = 2^(b log2 a): fld b; fld a; fyl2x; fld st0; frndint; fsub st1, st0;
// fxch st1; f2xm1; fld1; faddp st1, st0; fscale; fstp st1; fstp [rdi]
export const bee_x87_pow: [28]u8 linksection(".text") = .{
    0xdd, 0x47, 0x08, 0xdd, 0x07, 0xd9, 0xf1, 0xd9, 0xc0, 0xd9, 0xfc, 0xdc, 0xe9, 0xd9,
    0xc9, 0xd9, 0xf0, 0xd9, 0xe8, 0xde, 0xc1, 0xd9, 0xfd, 0xdd, 0xd9, 0xdd, 0x1f, 0xc3,
};

// fld dword [rdi]; fsincos; fstp dword [rdi+4] (cos); fstp dword [rdi] (sin)
export const bee_x87_sincos32: [10]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0xfb, 0xd9, 0x5f, 0x04, 0xd9, 0x1f, 0xc3 };

/// fsincos of an f32 angle (radians), each rounded to f32: sin, cos (scene.s obj_matrix).
pub fn sincos32(x: f32) [2]f32 {
    if (!use_x87) return .{ @sin(x), @cos(x) };
    return run87f(&bee_x87_sincos32, x);
}

fn run87f(code: []const u8, x: f32) [2]f32 {
    var m: [2]f32 = .{ x, 0 };
    const f: *const fn (*[2]f32) callconv(.c) void = @ptrCast(code.ptr);
    f(&m);
    return m;
}

fn run87(code: []const u8, a: f64, b: f64) f64 {
    var m: [2]f64 = .{ a, b };
    const f: X87 = @ptrCast(code.ptr);
    f(&m);
    return m[0];
}

pub const Un = enum { sin, cos, tan };

pub fn x87un(comptime op: Un, a: f64) f64 {
    if (!use_x87) return switch (op) {
        .sin => @sin(a),
        .cos => @cos(a),
        .tan => @tan(a),
    };
    return switch (op) {
        .sin => run87(&bee_x87_sin, a, 0),
        .cos => run87(&bee_x87_cos, a, 0),
        .tan => run87(&bee_x87_tan, a, 0),
    };
}

/// fpatan: atan(y / x) in the quadrant of (x, y).
pub fn atan2x87(y: f64, x: f64) f64 {
    return x87atan2(y, x);
}

fn x87atan2(y: f64, x: f64) f64 {
    if (!use_x87) return std.math.atan2(y, x);
    return run87(&bee_x87_atan2, y, x);
}

/// a^b = 2^(b log2 a), a > 0.
pub fn x87pow(a: f64, b: f64) f64 {
    if (!use_x87) return std.math.pow(f64, a, b);
    return run87(&bee_x87_pow, a, b);
}

// ---- evaluation ------------------------------------------------------------------

pub const Result = struct { v: f64, ok: bool };

/// expr_eval: the value, ok when no error (else `err` says what). Nested
/// evaluations (a parameter's) keep the error of the outer one going.
pub fn evaluate(text: []const u8) Result {
    const keep_src = src;
    const keep_pos = pos;
    const keep_depth = depth;
    defer {
        src = keep_src;
        pos = keep_pos;
        depth = keep_depth;
    }
    src = text;
    pos = 0;
    if (keep_depth == 0) err = null;
    const v = parseExpr();
    ws();
    if (at(0) != 0) _ = fail(e_trail);
    if (std.math.isNan(v) or std.math.isInf(v)) {
        _ = fail(e_math);
    }
    return .{ .v = v, .ok = err == null };
}

fn noName(_: []const u8) ?f64 {
    return null;
}

/// A driver's expression: its value, null when it does not evaluate.
pub fn eval(text: []const u8, hook: Name) ?f64 {
    const keep = name_hook;
    name_hook = hook;
    defer name_hook = keep;
    const r = evaluate(text);
    return if (r.ok) r.v else null;
}

test "drivers' expressions" {
    const T = std.testing;
    try T.expectApproxEqAbs(@as(f64, 0.5), eval("sin(30deg)", noName).?, 1e-12);
    try T.expectApproxEqAbs(@as(f64, 8), eval("2^3", noName).?, 1e-9);
    try T.expectEqual(@as(f64, -4), eval("-2*2", noName).?);
    try T.expectEqual(@as(f64, 3), eval("max(1, 3)", noName).?);
    try T.expectEqual(@as(f64, 0.025), eval("25mm", noName).?);
    try T.expect(eval("1/0", noName) == null);
    try T.expect(eval("nosuch", noName) == null);
    try T.expect(eval("1 2", noName) == null);
    try T.expect(eval("sqrt(-1)", noName) == null);
}

test "errors and units as expr.s" {
    const T = std.testing;
    try T.expect(!evaluate("1 +").ok);
    try T.expectEqualStrings(e_syntax, err.?);
    try T.expect(!evaluate("(1+2").ok);
    try T.expectEqualStrings(e_paren, err.?);
    try T.expect(!evaluate("foo(2)").ok);
    try T.expectEqualStrings(e_func, err.?);
    try T.expect(!evaluate("min(2)").ok);
    try T.expectEqualStrings(e_args, err.?);
    try T.expect(!evaluate("2 MM").ok);
    try T.expectEqualStrings(e_trail, err.?);
    try T.expect(!evaluate("x").ok);
    try T.expectEqualStrings(e_name, err.?);
    try T.expect(!evaluate("1/0").ok);
    try T.expectEqualStrings(e_math, err.?);
    var deep: [200]u8 = undefined;
    @memset(deep[0..100], '(');
    @memset(deep[100..200], ')');
    try T.expect(!evaluate(&deep).ok);
    try T.expectEqualStrings(e_deep, err.?);
    unit_mm = 1.0;
    defer unit_mm = 1000.0;
    try T.expectEqual(@as(f64, 2.54), evaluate("0.1in").v);
    try T.expectEqual(@as(f64, 22), evaluate("10*2mm + 2 mm").v);
    try T.expectEqual(@as(f64, 3), evaluate("round(2.5)").v);
    try T.expectEqual(@as(f64, -3), evaluate("floor(-2.5)").v);
    try T.expectEqual(@as(f64, 0), evaluate("(-2)^2").v); // as the original: a <= 0 gives 0
    try T.expectApproxEqAbs(@as(f64, std.math.pi / 6.0), evaluate("asin(0.5)").v, 1e-15);
}
