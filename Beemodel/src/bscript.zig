// BeeScript (script.s): the scripting language of the console, macros, --run /
// --eval and agents. Source -> tokens -> bytecode (one pass, no syntax tree)
// -> a stack VM, as the original:
//
//    x = 2m                      numbers carry units: m cm mm km deg rad
//    for i in 0..5 { add("cube", "Box" + i, i * 3, 0, 0) }
//    fn twice(a) { return a * 2 }
//    if count() > 3 { print("busy scene") } else { print(count()) }
//
// Values are nil, a number (double) or a text. Variables and functions defined
// at the top level live on between runs (the console is a REPL); a whole run
// is one undo step. Every limit is the original's: 64 KiB of source, 65536
// tokens, 128 KiB of main code and 256 KiB of function code (kept between
// runs until script.reset), 512 variables, 128 functions, 64 locals, 16 nested
// loops with 16 break / continue each, nesting 200 deep, a value stack of 16384,
// 2048 calls deep, a 1 MiB text heap (two halves: a run starts with the texts
// the variables hold copied over), 500 million steps. Errors are its words,
// "error: line N: ...", at the token (compiling) or the statement (running).
//
// The builtins are a table in the original's order (bs_table.zig: the bytecode
// calls one by its index); their code lives in one file per area of BeeModel
// (bs_areas.zig lists them). This file is the language: lexer, compiler, VM,
// texts, numbers as the original prints them, the REPL, script files, macro
// recording and the script.* operators.
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const cat = @import("catalog.zig");
const tbl = @import("bs_table.zig");

// ---- values -----------------------------------------------------------------------------

pub const T = enum(u8) { unset = 0, nil = 1, num = 2, str = 3 };

/// 16 bytes, as the original's { type, payload }: u.n a number, u.s a text.
pub const Value = extern struct {
    t: T = .nil,
    u: extern union { n: f64, s: [*:0]const u8 } = .{ .n = 0 },
};

pub const nil: Value = .{ .t = .nil };

pub fn num(x: f64) Value {
    return .{ .t = .num, .u = .{ .n = x } };
}

/// A builtin's or the VM's error: the message is printed, the run unwinds.
pub const Err = error{Script};

/// A builtin: its arguments (as many as the table allows) -> its value.
pub const Fn = *const fn (a: []const Value) Err!Value;

/// What an area file lists: the name (one of bs_table.zig's) and its code.
pub const Builtin = struct { name: []const u8, f: Fn };

// ---- limits (script.s) --------------------------------------------------------------------

const TOK_MAX = 65536;
const MAIN_CODE = 131072;
const FN_CODE = 262144;
const G_MAX = 512;
const F_MAX = 128;
const L_MAX = 64;
const LP_MAX = 16;
const LP_JUMPS = 16;
const VS_N = 16384;
const FR_N = 2048;
const SH_SIZE = 1048576;
pub const SRC_MAX = 65536;
const OUT_MAX = 65536;
const MAC_MAX = 65536;
const LN_MAX = 1024;
const STEP_MAX: u64 = 500000000;
const NEST_MAX = 200;

// tokens
const TK_EOF = 0;
const TK_SEP = 1;
const TK_NUM = 2;
const TK_STR = 3;
const TK_NAME = 4;
const TK_LP = 5;
const TK_RP = 6;
const TK_LB = 7;
const TK_RB = 8;
const TK_COMMA = 9;
const TK_ASSIGN = 10;
const TK_EQ = 11; // == != < <= > >= (the order of OP_EQ ..)
const TK_NE = 12;
const TK_LT = 13;
const TK_LE = 14;
const TK_GT = 15;
const TK_GE = 16;
const TK_PLUS = 17;
const TK_MINUS = 18;
const TK_STAR = 19;
const TK_SLASH = 20;
const TK_PCT = 21;
const TK_DOTDOT = 22;
const TK_FN = 23;
const TK_IF = 24;
const TK_ELSE = 25;
const TK_WHILE = 26;
const TK_FOR = 27;
const TK_IN = 28;
const TK_RETURN = 29;
const TK_BREAK = 30;
const TK_CONTINUE = 31;
const TK_AND = 32;
const TK_OR = 33;
const TK_NOT = 34;
const TK_TRUE = 35;
const TK_FALSE = 36;
const TK_NIL = 37;
const TK_PI = 38;
const TK_ADDEQ = 39; // += -= *= /=
const TK_SUBEQ = 40;
const TK_MULEQ = 41;
const TK_DIVEQ = 42;

// opcodes
const OP_HALT = 0;
const OP_LINE = 1; // u16 source line
const OP_NUM = 2; // f64
const OP_STR = 3; // u16 length, bytes, 0
const OP_NIL = 4;
const OP_GETG = 5; // u16 global
const OP_SETG = 6;
const OP_GETL = 7; // u8 local
const OP_SETL = 8;
const OP_ADD = 9;
const OP_SUB = 10;
const OP_MUL = 11;
const OP_DIV = 12;
const OP_MOD = 13;
const OP_NEG = 14;
const OP_NOT = 15;
const OP_EQ = 16;
const OP_NE = 17;
const OP_LT = 18;
const OP_LE = 19;
const OP_GT = 20;
const OP_GE = 21;
const OP_JMP = 22; // rel32 (from the end of the operand)
const OP_JF = 23; // pop, jump if false
const OP_JFK = 24; // jump if false keeping the value, else pop
const OP_JTK = 25; // jump if true keeping the value, else pop
const OP_CALLB = 26; // u8 builtin, u8 argc
const OP_CALLF = 27; // u16 function, u8 argc
const OP_RET = 28;
const OP_POP = 29;
const OP_POPR = 30; // pop into the result register (REPL echo)
const OP_CLRR = 31;

const units = [_]struct { []const u8, f64 }{
    .{ "m", 1.0 },     .{ "cm", 0.01 },                  .{ "mm", 0.001 },
    .{ "km", 1000.0 }, .{ "deg", 0.017453292519943295 }, .{ "rad", 1.0 },
};

const keywords = [_]struct { []const u8, u8 }{
    .{ "fn", TK_FN },             .{ "if", TK_IF },       .{ "else", TK_ELSE },     .{ "while", TK_WHILE },
    .{ "for", TK_FOR },           .{ "in", TK_IN },       .{ "return", TK_RETURN }, .{ "break", TK_BREAK },
    .{ "continue", TK_CONTINUE }, .{ "and", TK_AND },     .{ "or", TK_OR },         .{ "not", TK_NOT },
    .{ "true", TK_TRUE },         .{ "false", TK_FALSE }, .{ "nil", TK_NIL },       .{ "pi", TK_PI },
};

// ---- messages (script.s, word for word) ----------------------------------------------------

const e_char = "unexpected character";
const e_char_list = " [ or ] (there are no lists: write each item, or loop with for i in 0..n)";
const e_string = "unterminated text (missing quote)";
const e_unit = "unknown unit (m cm mm km deg rad)";
const e_toolong = "script too long";
const e_name_long = "name too long (31 characters max)";
const e_value = "expected a value";
const e_rp = "expected )";
const e_lb = "expected {";
const e_rb = "missing }";
const e_stray_rb = "unexpected }";
const e_end = "expected a new line or ; after the statement";
const e_in = "expected 'in' after the loop variable";
const e_dotdot = "expected .. in the range (for i in 0..10)";
const e_var = "expected a variable name";
const e_fn_name = "expected a function name";
const e_fn_top = "fn can only be defined at the top level";
const e_fn_builtin = "that name belongs to a builtin: ";
const e_dup_param = "duplicate parameter";
const e_break = "break / continue outside a loop";
const e_jumps = "too many break / continue in one loop";
const e_nest = "nested too deeply";
const e_loops = "loops nested too deeply";
const e_vars = "too many variables";
const e_fns = "too many functions";
const e_locals = "too many local variables";
const e_code_full = "script too large to compile";
const e_args = "wrong number of arguments for ";
const e_text_long = "text too long";
const e_undef = "not defined: ";
const e_nofn = "function not defined: ";
const e_recursion = "too much recursion";
const e_stack = "expression stack overflow";
const e_steps = "stopped after 500 million steps (endless loop?)";
const e_add = "+ needs two numbers, or a text";
const e_arith = "arithmetic needs numbers";
const e_cmp = "only numbers can be compared with < <= > >=";
const e_div0 = "division by zero";
const e_strmem = "out of text memory";
pub const e_want_num = "expected a number";
pub const e_want_str = "expected a text";
pub const e_no_obj = "no object named ";
pub const e_range = "index out of range";
/// A builtin of the original that no area file implements yet.
pub const e_not_ported = "not available yet: ";

const s_busy = "  a script is already running";
const s_rec_start = "  recording a macro - run script.record again to stop";
const s_rec_empty = "  macro is empty - nothing saved";
const s_rec_saved = "  macro saved: ";
const s_rec_hint = "  script.run plays it back";
const s_rec_fail = "  could not save the macro";
const s_cant_read = "can't read ";
const s_too_big = "script too large (64 KiB max)";
const s_reset = "  script variables and functions cleared";

// ---- state ------------------------------------------------------------------------------

var src: [SRC_MAX]u8 = undefined;

var tk_t: [TOK_MAX]u8 = undefined;
var tk_line: [TOK_MAX]u32 = undefined;
var tk_len: [TOK_MAX]u32 = undefined;
var tk_at: [TOK_MAX]u32 = undefined;
var tk_num: [TOK_MAX]f64 = undefined;
var tkp: usize = 0;

/// Main code [0, MAIN_CODE), function code [MAIN_CODE, MAIN_CODE + FN_CODE).
var code: [MAIN_CODE + FN_CODE]u8 = undefined;
var em_ptr: usize = 0;
var em_end: usize = 0;
var fn_pos: usize = MAIN_CODE;
var fn_pos_save: usize = MAIN_CODE;

var gnames: [G_MAX][32]u8 = undefined;
var gvals: [G_MAX]Value = undefined;
var gcount: usize = 0;

const Func = struct { name: [32]u8 = @splat(0), code: u32 = 0, params: u8 = 0, locals: u8 = 0 };
var fntab: [F_MAX]Func = undefined;
var fntab_save: [F_MAX]Func = undefined;
var fcount: usize = 0;
var fcount_save: usize = 0;

var lnames: [L_MAX][32]u8 = undefined;
var nlocals: usize = 0;

const Loop = struct { nb: u32 = 0, nc: u32 = 0, brk: [LP_JUMPS]u32 = undefined, cont: [LP_JUMPS]u32 = undefined };
var loops: [LP_MAX]Loop = undefined;
var loop_depth: usize = 0;
var fn_mode = false;
var c_depth: usize = 0;

/// An else-if chain's jumps over the elses, all landing at its end.
var chain: [32768]u32 = undefined;
var chain_n: usize = 0;

var name_tmp: [32]u8 = @splat(0);
var name_len: usize = 0;

var vstack: [VS_N]Value = undefined;
const Frame = struct { ip: u32, base: u32 };
var frames: [FR_N]Frame = undefined;

var sh: [2][SH_SIZE]u8 = undefined;
var sh_half: usize = 1;
var sh_pos: usize = 0;

var out: [OUT_MAX]u8 = undefined;
var out_len: usize = 0;

var ln: [LN_MAX + 64]u8 = undefined;

var sc_line: u32 = 0;
var running = false;
var phase: u8 = 0; // 0 compiling, 1 running
var agent = false;
var result: Value = nil;

var rng_state: u64 = 0x9E3779B97F4A7C15;

/// The builtins' code by index (null: not in the port yet).
const handlers: [tbl.specs.len]?Fn = blk: {
    @setEvalBranchQuota(200000);
    var h: [tbl.specs.len]?Fn = @splat(null);
    for (@import("bs_areas.zig").areas) |area| {
        for (area.builtins) |b| {
            var found = false;
            for (tbl.specs, 0..) |s, k| {
                if (std.mem.eql(u8, s.name, b.name)) {
                    if (h[k] != null) @compileError("BeeScript builtin given twice: " ++ b.name);
                    h[k] = b.f;
                    found = true;
                }
            }
            if (!found) @compileError("not a builtin of the original: " ++ b.name);
        }
    }
    break :blk h;
};

/// The one-number builtins' plain functions by index (bs_lang.num1), for OP_CALLB.
const num1_of: [tbl.specs.len]?*const fn (f64) f64 = blk: {
    @setEvalBranchQuota(200000);
    var h: [tbl.specs.len]?*const fn (f64) f64 = @splat(null);
    for (@import("bs_lang.zig").num1) |e| {
        for (tbl.specs, 0..) |s, k| {
            if (std.mem.eql(u8, s.name, e[0])) h[k] = e[1];
        }
    }
    break :blk h;
};

/// Is builtin `name` implemented in the port?
pub fn ported(name: []const u8) bool {
    for (tbl.specs, 0..) |s, k| {
        if (std.mem.eql(u8, s.name, name)) return handlers[k] != null;
    }
    return false;
}

const builtin_map = blk: {
    @setEvalBranchQuota(200000);
    var kv: [tbl.specs.len]struct { []const u8, u8 } = undefined;
    for (tbl.specs, 0..) |s, k| kv[k] = .{ s.name, k };
    break :blk std.StaticStringMap(u8).initComptime(kv);
};

// ---- output ---------------------------------------------------------------------------------

/// What the last run printed (print, the result, errors), a line each.
pub fn output() []const u8 {
    return out[0..out_len];
}

/// sc_print: one output line, to the console and to the run's output.
fn scPrint(line: []const u8) void {
    app.log("  {s}", .{line});
    for (line) |c| {
        if (out_len >= OUT_MAX - 2) break;
        out[out_len] = c;
        out_len += 1;
    }
    if (out_len < OUT_MAX - 2) {
        out[out_len] = '\n';
        out_len += 1;
    }
}

/// ln_str: append to the line being built, bounded at LN_MAX - 2.
fn lnStr(at: *usize, s: []const u8) void {
    for (s) |c| {
        if (c == 0 or at.* >= LN_MAX - 2) return;
        ln[at.*] = c;
        at.* += 1;
    }
}

fn cstr(p: [*:0]const u8) []const u8 {
    return std.mem.span(p);
}

/// sc_err: "error: line N: message detail" (no line when 0); the run ends.
fn scErr(msg: []const u8, detail: []const u8, line: u32) Err {
    var at: usize = 0;
    lnStr(&at, "error: ");
    if (line != 0) {
        lnStr(&at, "line ");
        var nb: [16]u8 = undefined;
        lnStr(&at, std.fmt.bufPrint(&nb, "{d}", .{line}) catch "");
        lnStr(&at, ": ");
    }
    lnStr(&at, msg);
    lnStr(&at, detail);
    scPrint(ln[0..at]);
    return error.Script;
}

/// A runtime error at the statement running (builtins use it).
pub fn fail(msg: []const u8, detail: []const u8) Err {
    return scErr(msg, detail, sc_line);
}

/// A compile error at the current token.
fn cError(msg: []const u8) Err {
    return scErr(msg, "", tk_line[tkp]);
}

// ---- numbers as the original prints them (numfmt) -----------------------------------------

/// roundsd mode 3 / cvttsd2si: toward zero.
fn trunc(x: f64) f64 {
    return @trunc(x);
}

/// cvttsd2si r64: toward zero; NaN or out of range: the minimum.
pub fn ci64(x: f64) i64 {
    if (!(x >= -9223372036854775808.0 and x < 9223372036854775808.0)) return std.math.minInt(i64);
    return @intFromFloat(x);
}

/// cvttsd2si r32: toward zero; NaN or out of range: the minimum.
pub fn ci32(x: f64) i32 {
    if (!(x > -2147483649.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}

/// cvtsd2ss: to the nearest float.
pub fn f32of(x: f64) f32 {
    return @floatCast(x);
}

fn putU64(buf: []u8, at: *usize, v0: u64) void {
    var d: [24]u8 = undefined;
    var k: usize = d.len;
    var v = v0;
    while (true) {
        k -= 1;
        d[k] = @intCast('0' + v % 10);
        v /= 10;
        if (v == 0) break;
    }
    for (d[k..]) |c| {
        buf[at.*] = c;
        at.* += 1;
    }
}

/// ".dddddd" without trailing zeros (f: 1 .. 999999).
fn putFrac6(buf: []u8, at: *usize, f: u64) void {
    buf[at.*] = '.';
    var v = f;
    var k: usize = 6;
    while (k > 0) : (k -= 1) {
        buf[at.* + k] = @intCast('0' + v % 10);
        v /= 10;
    }
    at.* += 7;
    while (buf[at.* - 1] == '0') at.* -= 1;
}

/// numfmt: integers plainly, else up to 6 decimals; huge / tiny as 1.5e20.
pub fn fmtNum(buf: *[64]u8, x0: f64) []const u8 {
    var at: usize = 0;
    var x = x0;
    if (std.math.isNan(x)) return "nan";
    if (x == 0) return "0";
    if (x < 0) {
        buf[at] = '-';
        at += 1;
        x = @abs(x);
    }
    if (x > 1.0e308) {
        @memcpy(buf[at .. at + 3], "inf");
        return buf[0 .. at + 3];
    }
    if (x >= 1.0e15 or x < 1.0e-4) {
        var e: i32 = 0;
        while (x >= 10.0) {
            x /= 10.0;
            e += 1;
        }
        while (x < 1.0) {
            x *= 10.0;
            e -= 1;
        }
        var mm: u64 = @intCast(ci64(roundEven(x * 1000000.0)));
        if (mm >= 10000000) {
            mm /= 10;
            e += 1;
        }
        putU64(buf, &at, mm / 1000000);
        if (mm % 1000000 != 0) putFrac6(buf, &at, mm % 1000000);
        buf[at] = 'e';
        at += 1;
        if (e < 0) {
            buf[at] = '-';
            at += 1;
            e = -e;
        }
        putU64(buf, &at, @intCast(e));
        return buf[0..at];
    }
    const ip = trunc(x);
    const fr = roundEven((x - ip) * 1000000.0);
    var f: u64 = @intCast(ci64(fr));
    var i: u64 = @intCast(ci64(ip));
    if (f >= 1000000) {
        i += 1;
        f -= 1000000;
    }
    putU64(buf, &at, i);
    if (f != 0) putFrac6(buf, &at, f);
    return buf[0..at];
}

/// roundsd mode 0: to the nearest, ties to even.
fn roundEven(x: f64) f64 {
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5) {
        const t = @trunc(x);
        return if (@mod(t, 2.0) == 0) t else r;
    }
    return r;
}

/// val_to: the value's text at buf[at..], bounded by end; the new end.
fn valTo(v: Value, buf: []u8, at0: usize, end: usize) usize {
    var nb: [64]u8 = undefined;
    const s: []const u8 = switch (v.t) {
        .num => fmtNum(&nb, v.u.n),
        .str => cstr(v.u.s),
        else => "nil",
    };
    var at = at0;
    for (s) |c| {
        if (at >= end) break;
        buf[at] = c;
        at += 1;
    }
    return at;
}

// ---- the text heap -----------------------------------------------------------------------

fn shBase() []u8 {
    return &sh[sh_half];
}

/// sh_val: the value's text appended to the heap.
fn shVal(v: Value) Err!void {
    const h = shBase();
    const at = valTo(v, h, sh_pos, SH_SIZE);
    if (at >= SH_SIZE) return fail(e_strmem, "");
    sh_pos = at;
}

fn shNul() Err!void {
    if (sh_pos >= SH_SIZE) return fail(e_strmem, "");
    shBase()[sh_pos] = 0;
    sh_pos += 1;
}

fn shPtr(at: usize) [*:0]const u8 {
    return @ptrCast(&shBase()[at]);
}

/// A copy of this text in the heap, as a value (sh_dup; ret_name).
pub fn text(s: []const u8) Err!Value {
    const at = sh_pos;
    const h = shBase();
    var k = sh_pos;
    for (s) |c| {
        if (c == 0) break;
        if (k >= SH_SIZE) return fail(e_strmem, "");
        h[k] = c;
        k += 1;
    }
    if (k >= SH_SIZE) return fail(e_strmem, "");
    h[k] = 0;
    sh_pos = k + 1;
    return .{ .t = .str, .u = .{ .s = shPtr(at) } };
}

/// str(v): its text, made in the heap.
pub fn toText(v: Value) Err!Value {
    const at = sh_pos;
    try shVal(v);
    try shNul();
    return .{ .t = .str, .u = .{ .s = shPtr(at) } };
}

fn concat(a: Value, b: Value) Err!Value {
    const at = sh_pos;
    try shVal(a);
    try shVal(b);
    try shNul();
    return .{ .t = .str, .u = .{ .s = shPtr(at) } };
}

/// sh_compact: a run starts in the other half, holding only the texts the
/// global variables still use (one that does not fit becomes nil).
fn shCompact() void {
    sh_half ^= 1;
    sh_pos = 0;
    const h = shBase();
    for (gvals[0..gcount]) |*g| {
        if (g.t != .str) continue;
        const s = cstr(g.u.s);
        const at = sh_pos;
        var k = sh_pos;
        var ok = false;
        for (s) |c| {
            if (k >= SH_SIZE) break;
            h[k] = c;
            k += 1;
        } else {
            if (k < SH_SIZE) {
                h[k] = 0;
                k += 1;
                ok = true;
            }
        }
        if (ok) {
            sh_pos = k;
            g.u.s = shPtr(at);
        } else g.t = .nil;
    }
}

// ---- argument helpers for builtins --------------------------------------------------------

/// a_num
pub fn argNum(v: Value) Err!f64 {
    if (v.t != .num) return fail(e_want_num, "");
    return v.u.n;
}

/// a_str
pub fn argStr(v: Value) Err![]const u8 {
    if (v.t != .str) return fail(e_want_str, "");
    return cstr(v.u.s);
}

pub fn truthy(v: Value) bool {
    return switch (v.t) {
        .num => v.u.n != 0 or std.math.isNan(v.u.n),
        .str => v.u.s[0] != 0,
        else => false,
    };
}

/// The xorshift64* state of rand() / seed().
pub fn rand() f64 {
    var x = rng_state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rng_state = x;
    const r = x *% 0x2545F4914F6CDD1D;
    return @as(f64, @floatFromInt(r >> 11)) * 1.1102230246251565e-16;
}

pub fn seed(x: f64) void {
    const v = ci64(x);
    rng_state = if (v == 0) 0x9E3779B97F4A7C15 else @bitCast(v);
}

/// print(...): the values with a space between, one line (as the original
/// bounds it: each value stops at 1022 characters, the spaces still come).
pub fn printValues(a: []const Value) void {
    var at: usize = 0;
    for (a, 0..) |v, k| {
        if (k > 0) {
            ln[at] = ' ';
            at += 1;
        }
        at = valTo(v, &ln, at, LN_MAX - 2);
    }
    scPrint(ln[0..at]);
}

/// The text of a value as the original writes it (numbers by numfmt), bounded.
pub fn valText(v: Value, buf: []u8) []const u8 {
    return buf[0..valTo(v, buf, 0, buf.len)];
}

/// Frames the window drew, and the last 256 frames' drawing times (ns) and
/// their input work (frames(), frametime(): window.s fr_count, fr_ns, fr_wk).
pub var frame_count: u32 = 0;
pub var frame_ns: [256]u64 = @splat(0);
pub var frame_work: [256]u64 = @splat(0);

/// A frame was drawn in this many ns (main.zig).
pub fn frameDrawn(ns: u64, work: u64) void {
    frame_ns[frame_count & 255] = ns;
    frame_work[frame_count & 255] = work;
    frame_count +%= 1;
}

/// Is an agent running this script (MCP)?
pub fn byAgent() bool {
    return agent;
}

/// The line the run is at (for builtins that print their own messages).
pub fn curLine() u32 {
    return sc_line;
}

// ---- lexer ------------------------------------------------------------------------------

fn isIdent(c: u8) bool {
    return c == '_' or (c >= '0' and c <= '9') or ((c | 0x20) >= 'a' and (c | 0x20) <= 'z');
}

const Num = struct { v: f64, end: usize, status: u8 }; // 0 ok, 1 unknown unit, 2 no digits

/// parse_num: a number at s[i..] (s ends with a 0): hexadecimal 0xff (no
/// units), else digits, a fraction, an exponent and a unit.
pub fn parseNum(s: []const u8, start: usize) Num {
    var i = start;
    if (s[i] == '0' and (s[i + 1] | 0x20) == 'x') {
        var k = i + 2;
        var v: u64 = 0;
        var nd: u32 = 0;
        while (nd < 15) {
            const c = s[k];
            const d: u64 = if (c >= '0' and c <= '9') c - '0' else if ((c | 0x20) >= 'a' and (c | 0x20) <= 'f') (c | 0x20) - 'a' + 10 else break;
            v = (v << 4) | d;
            k += 1;
            nd += 1;
        }
        if (nd > 0) {
            const x: f64 = @floatFromInt(@as(i64, @bitCast(v)));
            if (isIdent(s[k])) return .{ .v = x, .end = k, .status = 1 };
            return .{ .v = x, .end = k, .status = 0 };
        }
    }
    var x: f64 = 0;
    var frac: i64 = 0;
    var any = false;
    while (s[i] >= '0' and s[i] <= '9') {
        x = x * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
        i += 1;
        any = true;
    }
    if (s[i] == '.' and s[i + 1] >= '0' and s[i + 1] <= '9') {
        i += 1;
        while (s[i] >= '0' and s[i] <= '9') {
            x = x * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
            i += 1;
            frac += 1;
            any = true;
        }
    }
    if (!any) return .{ .v = 0, .end = i, .status = 2 };
    if ((s[i] | 0x20) == 'e') {
        var k = i + 1;
        var neg = false;
        if (s[k] == '+') {
            k += 1;
        } else if (s[k] == '-') {
            neg = true;
            k += 1;
        }
        if (s[k] >= '0' and s[k] <= '9') {
            var e: i64 = 0;
            while (s[k] >= '0' and s[k] <= '9') : (k += 1) {
                if (e < 400) e = e * 10 + (s[k] - '0');
            }
            i = k;
            if (neg) frac += e else frac -= e;
        }
    }
    if (frac > 0) {
        var p: f64 = 1.0;
        var c = frac;
        while (c > 0) : (c -= 1) p *= 10.0;
        x /= p;
    } else if (frac < 0) {
        var c = -frac;
        while (c > 0) : (c -= 1) x *= 10.0;
    }
    if (!isIdent(s[i])) return .{ .v = x, .end = i, .status = 0 };
    const ustart = i;
    while (isIdent(s[i])) i += 1;
    const u = s[ustart..i];
    if (u.len <= 7) {
        for (units) |un| {
            if (std.mem.eql(u8, un[0], u)) return .{ .v = x * un[1], .end = i, .status = 0 };
        }
    }
    return .{ .v = x, .end = i, .status = 1 };
}

var ntok: usize = 0;

fn tok(t: u8, line_: u32) void {
    tk_t[ntok] = t;
    tk_line[ntok] = line_;
    tk_len[ntok] = 0;
    ntok += 1;
}

const punct = [_]struct { u8, u8 }{
    .{ '(', TK_LP },     .{ ')', TK_RP },    .{ '{', TK_LB },  .{ '}', TK_RB },   .{ ',', TK_COMMA },
    .{ '=', TK_ASSIGN }, .{ '<', TK_LT },    .{ '>', TK_GT },  .{ '+', TK_PLUS }, .{ '-', TK_MINUS },
    .{ '*', TK_STAR },   .{ '/', TK_SLASH }, .{ '%', TK_PCT },
};

fn lex() Err!void {
    ntok = 0;
    var i: usize = 0;
    var line_: u32 = 1;
    var depth: u32 = 0; // ( ) depth: newlines inside are spaces
    while (true) {
        if (ntok >= TOK_MAX - 2) return scErr(e_toolong, "", line_);
        const c = src[i];
        switch (c) {
            0 => {
                tok(TK_SEP, line_);
                tok(TK_EOF, line_);
                return;
            },
            ' ', 9, 13 => i += 1,
            '#' => {
                i += 1;
                while (src[i] != 0 and src[i] != 10) i += 1;
            },
            10 => {
                if (depth == 0) tok(TK_SEP, line_);
                line_ += 1;
                i += 1;
            },
            ';' => {
                tok(TK_SEP, line_);
                i += 1;
            },
            '"', '\'' => {
                const q = c;
                var k = i + 1;
                while (true) {
                    const d = src[k];
                    if (d == 0 or d == 10) return scErr(e_string, "", line_);
                    if (d == q) break;
                    if (d == '\\') {
                        if (src[k + 1] == 0) return scErr(e_string, "", line_);
                        k += 1;
                    }
                    k += 1;
                }
                tok(TK_STR, line_);
                tk_len[ntok - 1] = @intCast(k - (i + 1));
                tk_at[ntok - 1] = @intCast(i + 1);
                i = k + 1;
            },
            else => {
                if ((c >= '0' and c <= '9') or (c == '.' and src[i + 1] >= '0' and src[i + 1] <= '9')) {
                    const r = parseNum(&src, i);
                    if (r.status != 0) return scErr(e_unit, "", line_);
                    tok(TK_NUM, line_);
                    tk_num[ntok - 1] = r.v;
                    i = r.end;
                    continue;
                }
                if (c == '.') {
                    if (src[i + 1] != '.') return badChar(c, line_);
                    tok(TK_DOTDOT, line_);
                    i += 2;
                    continue;
                }
                if (c == '_' or ((c | 0x20) >= 'a' and (c | 0x20) <= 'z')) {
                    const s0 = i;
                    i += 1;
                    while (isIdent(src[i])) i += 1;
                    const w = src[s0..i];
                    var t: u8 = TK_NAME;
                    if (w.len <= 8) {
                        for (keywords) |kw| {
                            if (std.mem.eql(u8, kw[0], w)) t = kw[1];
                        }
                    }
                    tok(t, line_);
                    tk_len[ntok - 1] = @intCast(w.len);
                    tk_at[ntok - 1] = @intCast(s0);
                    continue;
                }
                const two: u8 = switch (c) {
                    '=' => TK_EQ,
                    '!' => TK_NE,
                    '<' => TK_LE,
                    '>' => TK_GE,
                    '+' => TK_ADDEQ,
                    '-' => TK_SUBEQ,
                    '*' => TK_MULEQ,
                    '/' => TK_DIVEQ,
                    else => 0,
                };
                if (two != 0 and src[i + 1] == '=') {
                    tok(two, line_);
                    i += 2;
                    continue;
                }
                for (punct) |p| {
                    if (p[0] == c) {
                        tok(p[1], line_);
                        i += 1;
                        if (c == '(') depth += 1;
                        if (c == ')' and depth > 0) depth -= 1;
                        break;
                    }
                } else return badChar(c, line_);
            },
        }
    }
}

fn badChar(c: u8, line_: u32) Err {
    if (c == '[' or c == ']') return scErr(e_char, e_char_list, line_);
    if (c >= 0x21 and c <= 0x7e) {
        const d = [4]u8{ ' ', '\'', c, '\'' };
        return scErr(e_char, &d, line_);
    }
    return scErr(e_char, "", line_);
}

// ---- compiler --------------------------------------------------------------------------

inline fn tkType() u8 {
    return tk_t[tkp];
}
inline fn tkNext() void {
    tkp += 1;
}
inline fn tkPeek2() u8 {
    return tk_t[tkp + 1];
}

fn expect(t: u8, msg: []const u8) Err!void {
    if (tk_t[tkp] != t) return cError(msg);
    tkp += 1;
}

fn skipSeps() void {
    while (tk_t[tkp] == TK_SEP) tkp += 1;
}

fn emByte(b: u8) Err!void {
    if (em_ptr >= em_end) return cError(e_code_full);
    code[em_ptr] = b;
    em_ptr += 1;
}
fn emU16(v: u16) Err!void {
    if (em_ptr + 2 > em_end) return cError(e_code_full);
    std.mem.writeInt(u16, code[em_ptr..][0..2], v, .little);
    em_ptr += 2;
}
fn emU32(v: u32) Err!void {
    if (em_ptr + 4 > em_end) return cError(e_code_full);
    std.mem.writeInt(u32, code[em_ptr..][0..4], v, .little);
    em_ptr += 4;
}
fn emU64(v: u64) Err!void {
    if (em_ptr + 8 > em_end) return cError(e_code_full);
    std.mem.writeInt(u64, code[em_ptr..][0..8], v, .little);
    em_ptr += 8;
}
fn emNum(x: f64) Err!void {
    try emByte(OP_NUM);
    try emU64(@bitCast(x));
}
/// em_jump: the address of its rel32, patched later.
fn emJump(op: u8) Err!usize {
    try emByte(op);
    try emU32(0);
    return em_ptr - 4;
}
fn patchHere(at: usize) void {
    const rel: i32 = @intCast(@as(i64, @intCast(em_ptr)) - @as(i64, @intCast(at + 4)));
    std.mem.writeInt(i32, code[at..][0..4], rel, .little);
}
fn emJumpTo(op: u8, target: usize) Err!void {
    try emByte(op);
    const rel: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(em_ptr + 4)));
    try emU32(@bitCast(rel));
}

/// tok_name: the current token's name into name_tmp.
fn tokName() Err!void {
    const n = tk_len[tkp];
    if (n > 31) return cError(e_name_long);
    @memcpy(name_tmp[0..n], src[tk_at[tkp]..][0..n]);
    name_tmp[n] = 0;
    name_len = n;
}

fn nameOf(b: *const [32]u8) []const u8 {
    return std.mem.sliceTo(b, 0);
}

fn tmp() []const u8 {
    return name_tmp[0..name_len];
}

/// global_ref: the global named name_tmp (made, unset, if new).
fn globalRef() Err!u32 {
    for (0..gcount) |k| {
        if (std.mem.eql(u8, nameOf(&gnames[k]), tmp())) return @intCast(k);
    }
    if (gcount >= G_MAX) return cError(e_vars);
    gnames[gcount] = name_tmp;
    gvals[gcount] = .{ .t = .unset };
    gcount += 1;
    return @intCast(gcount - 1);
}

fn localFind() ?u32 {
    for (0..nlocals) |k| {
        if (std.mem.eql(u8, nameOf(&lnames[k]), tmp())) return @intCast(k);
    }
    return null;
}

fn localAdd() Err!u32 {
    if (nlocals >= L_MAX) return cError(e_locals);
    lnames[nlocals] = name_tmp;
    nlocals += 1;
    return @intCast(nlocals - 1);
}

const LOCAL = 0x10000;

fn refRead() Err!u32 {
    if (!fn_mode) return globalRef();
    if (localFind()) |k| return k | LOCAL;
    return globalRef();
}

fn refWrite() Err!u32 {
    if (!fn_mode) return globalRef();
    if (localFind()) |k| return k | LOCAL;
    return (try localAdd()) | LOCAL;
}

fn emitGet(v: u32) Err!void {
    if (v & LOCAL == 0) {
        try emByte(OP_GETG);
        try emU16(@truncate(v));
    } else {
        try emByte(OP_GETL);
        try emByte(@truncate(v));
    }
}

fn emitSet(v: u32) Err!void {
    if (v & LOCAL == 0) {
        try emByte(OP_SETG);
        try emU16(@truncate(v));
    } else {
        try emByte(OP_SETL);
        try emByte(@truncate(v));
    }
}

/// fn_ref: the function named name_tmp (made, undefined, if new).
fn fnRef() Err!u32 {
    for (0..fcount) |k| {
        if (std.mem.eql(u8, nameOf(&fntab[k].name), tmp())) return @intCast(k);
    }
    if (fcount >= F_MAX) return cError(e_fns);
    fntab[fcount] = .{ .name = name_tmp };
    fcount += 1;
    return @intCast(fcount - 1);
}

fn builtinFind() ?u8 {
    return builtin_map.get(tmp());
}

fn nestIn() Err!void {
    c_depth += 1;
    if (c_depth > NEST_MAX) return cError(e_nest);
}
fn nestOut() void {
    c_depth -= 1;
}

fn compile() Err!void {
    tkp = 0;
    em_ptr = 0;
    em_end = MAIN_CODE;
    fn_mode = false;
    loop_depth = 0;
    c_depth = 0;
    chain_n = 0;
    while (true) {
        skipSeps();
        const t = tkType();
        if (t == TK_EOF) break;
        if (t == TK_RB) return cError(e_stray_rb);
        try cStmt(true);
    }
    try emByte(OP_HALT);
}

fn cStmt(top0: bool) Err!void {
    const top = top0 and !fn_mode; // (REPL echo only for top-level code)
    try emByte(OP_LINE);
    try emU16(@intCast(@min(tk_line[tkp], 0xffff)));
    const t = tkType();
    var clr = true;
    switch (t) {
        TK_IF => try cIf(),
        TK_WHILE => try cWhile(),
        TK_FOR => try cFor(),
        TK_FN => {
            if (!top or c_depth != 0) return cError(e_fn_top);
            try cFn();
        },
        TK_RETURN => {
            tkNext();
            const n = tkType();
            if (n == TK_SEP or n == TK_RB or n == TK_EOF) try emByte(OP_NIL) else try cExpr();
            try emByte(OP_RET);
            clr = false;
        },
        TK_BREAK, TK_CONTINUE => {
            if (loop_depth == 0) return cError(e_break);
            const lp = &loops[loop_depth - 1];
            const cnt = if (t == TK_BREAK) &lp.nb else &lp.nc;
            if (cnt.* >= LP_JUMPS) return cError(e_jumps);
            const at = try emJump(OP_JMP);
            if (t == TK_BREAK) lp.brk[cnt.*] = @intCast(at) else lp.cont[cnt.*] = @intCast(at);
            cnt.* += 1;
            tkNext();
            clr = false;
        },
        else => {
            const p2 = tkPeek2();
            if (t == TK_NAME and (p2 == TK_ASSIGN or (p2 >= TK_ADDEQ and p2 <= TK_DIVEQ))) {
                try tokName();
                const v = try refWrite();
                tkNext();
                const op = tkType();
                tkNext();
                if (op != TK_ASSIGN) try emitGet(v);
                try cExpr();
                if (op != TK_ASSIGN) try emByte(op - TK_ADDEQ + OP_ADD);
                try emitSet(v);
            } else {
                try cExpr();
                try emByte(if (top) OP_POPR else OP_POP);
                clr = false;
            }
        },
    }
    if (clr and top) try emByte(OP_CLRR);
    const e = tkType();
    if (e != TK_SEP and e != TK_RB and e != TK_EOF) return cError(e_end);
}

fn cBlock() Err!void {
    try nestIn();
    try expect(TK_LB, e_lb);
    while (true) {
        skipSeps();
        const t = tkType();
        if (t == TK_RB) break;
        if (t == TK_EOF) return cError(e_rb);
        try cStmt(false);
    }
    tkNext();
    nestOut();
}

/// if cond { } [else if ... | else { }] (an else-if chain without recursion)
fn cIf() Err!void {
    const base = chain_n;
    while (true) {
        tkNext();
        try cExpr();
        const jf = try emJump(OP_JF);
        try cBlock();
        const keep = tkp; // else may follow on the next line
        skipSeps();
        if (tkType() != TK_ELSE) {
            tkp = keep;
            patchHere(jf);
            break;
        }
        const j = try emJump(OP_JMP);
        patchHere(jf);
        tkNext();
        chain[chain_n] = @intCast(j);
        chain_n += 1;
        if (tkType() == TK_IF) continue;
        try cBlock();
        break;
    }
    while (chain_n > base) {
        chain_n -= 1;
        patchHere(chain[chain_n]);
    }
}

fn loopPush() Err!void {
    if (loop_depth >= LP_MAX) return cError(e_loops);
    loops[loop_depth].nb = 0;
    loops[loop_depth].nc = 0;
    loop_depth += 1;
}

fn loopPatchCont(target: usize) void {
    const lp = &loops[loop_depth - 1];
    for (lp.cont[0..lp.nc]) |at| {
        const rel: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(at + 4)));
        std.mem.writeInt(i32, code[at..][0..4], rel, .little);
    }
}

fn loopPop() void {
    loop_depth -= 1;
    const lp = &loops[loop_depth];
    for (lp.brk[0..lp.nb]) |at| patchHere(at);
}

fn cWhile() Err!void {
    const top = em_ptr;
    tkNext();
    try cExpr();
    const jf = try emJump(OP_JF);
    try loopPush();
    try cBlock();
    loopPatchCont(top);
    try emJumpTo(OP_JMP, top);
    patchHere(jf);
    loopPop();
}

/// for v in a..b { }   (b exclusive, step 1)
fn cFor() Err!void {
    tkNext();
    if (tkType() != TK_NAME) return cError(e_var);
    try tokName();
    const v = try refWrite();
    tkNext();
    try expect(TK_IN, e_in);
    try cExpr();
    try emitSet(v);
    try expect(TK_DOTDOT, e_dotdot);
    try cExpr();
    name_tmp[0] = 1; // a hidden end variable per depth
    name_tmp[1] = @intCast('0' + loop_depth);
    name_tmp[2] = 0;
    name_len = 2;
    const e = try refWrite();
    try emitSet(e);
    const top = em_ptr;
    try emitGet(v);
    try emitGet(e);
    try emByte(OP_LT);
    const jf = try emJump(OP_JF);
    try loopPush();
    try cBlock();
    loopPatchCont(em_ptr);
    try emitGet(v);
    try emNum(1.0);
    try emByte(OP_ADD);
    try emitSet(v);
    try emJumpTo(OP_JMP, top);
    patchHere(jf);
    loopPop();
}

/// fn name(a, b) { }   (top level; the body goes to the function code)
fn cFn() Err!void {
    tkNext();
    if (tkType() != TK_NAME) return cError(e_fn_name);
    try tokName();
    if (builtinFind() != null) return scErr(e_fn_builtin, tmp(), tk_line[tkp]);
    const f = try fnRef();
    tkNext();
    try expect(TK_LP, e_value);
    fn_mode = true;
    nlocals = 0;
    if (tkType() != TK_RP) {
        while (true) {
            if (tkType() != TK_NAME) return cError(e_var);
            try tokName();
            if (localFind() != null) return cError(e_dup_param);
            _ = try localAdd();
            tkNext();
            if (tkType() != TK_COMMA) break;
            tkNext();
        }
    }
    try expect(TK_RP, e_rp);
    const params = nlocals;
    const keep_ptr = em_ptr;
    const keep_end = em_end;
    em_ptr = fn_pos;
    em_end = MAIN_CODE + FN_CODE;
    const entry = fn_pos;
    try cBlock();
    try emByte(OP_NIL);
    try emByte(OP_RET);
    fn_pos = em_ptr;
    em_ptr = keep_ptr;
    em_end = keep_end;
    fntab[f].code = @intCast(entry);
    fntab[f].params = @intCast(params);
    fntab[f].locals = @intCast(nlocals);
    fn_mode = false;
}

fn cExpr() Err!void {
    try nestIn();
    try cAnd();
    while (tkType() == TK_OR) {
        const j = try emJump(OP_JTK);
        tkNext();
        try cAnd();
        patchHere(j);
    }
    nestOut();
}

fn cAnd() Err!void {
    try cNot();
    while (tkType() == TK_AND) {
        const j = try emJump(OP_JFK);
        tkNext();
        try cNot();
        patchHere(j);
    }
}

fn cNot() Err!void {
    var n: usize = 0;
    while (tkType() == TK_NOT) {
        tkNext();
        n += 1;
    }
    try cCmp();
    while (n > 0) : (n -= 1) try emByte(OP_NOT);
}

fn cCmp() Err!void {
    try cAdd();
    const t = tkType();
    if (t >= TK_EQ and t <= TK_GE) {
        tkNext();
        try cAdd();
        try emByte(t - TK_EQ + OP_EQ);
    }
}

fn cAdd() Err!void {
    try cMul();
    while (true) {
        const t = tkType();
        const op: u8 = if (t == TK_PLUS) OP_ADD else if (t == TK_MINUS) OP_SUB else break;
        tkNext();
        try cMul();
        try emByte(op);
    }
}

fn cMul() Err!void {
    try cUnary();
    while (true) {
        const t = tkType();
        const op: u8 = if (t == TK_STAR) OP_MUL else if (t == TK_SLASH) OP_DIV else if (t == TK_PCT) OP_MOD else break;
        tkNext();
        try cUnary();
        try emByte(op);
    }
}

fn cUnary() Err!void {
    if (tkType() != TK_MINUS) return cPrimary();
    tkNext();
    try nestIn();
    try cUnary();
    nestOut();
    try emByte(OP_NEG);
}

fn cPrimary() Err!void {
    switch (tkType()) {
        TK_NUM => try emNum(tk_num[tkp]),
        TK_TRUE => try emNum(1.0),
        TK_FALSE => try emNum(0.0),
        TK_PI => try emNum(3.141592653589793),
        TK_NIL => try emByte(OP_NIL),
        TK_STR => try cString(),
        TK_LP => {
            tkNext();
            try cExpr();
            return expect(TK_RP, e_rp);
        },
        TK_NAME => {
            if (tkPeek2() == TK_LP) return cCall();
            try tokName();
            try emitGet(try refRead());
        },
        else => return cError(e_value),
    }
    tkNext();
}

/// name(args): a builtin or a script function
fn cCall() Err!void {
    try tokName();
    const b = builtinFind();
    const name_tok = tkp;
    var f: u32 = 0;
    var fname: [32]u8 = name_tmp;
    if (b == null) f = try fnRef();
    fname = name_tmp;
    tkNext();
    tkNext();
    var argc: usize = 0;
    if (tkType() != TK_RP) {
        while (true) {
            try cExpr();
            argc += 1;
            if (tkType() != TK_COMMA) break;
            tkNext();
        }
    }
    try expect(TK_RP, e_rp);
    if (b) |k| {
        const s = tbl.specs[k];
        if (argc < s.min or argc > s.max) return scErr(e_args, s.name, tk_line[name_tok]);
        try emByte(OP_CALLB);
        try emByte(k);
        try emByte(@intCast(argc));
        return;
    }
    // (the original crashes past 255 arguments: here it is this error)
    if (argc > 255) return scErr(e_args, nameOf(&fname), tk_line[name_tok]);
    try emByte(OP_CALLF);
    try emU16(@intCast(f));
    try emByte(@intCast(argc));
}

/// The current text token, escapes resolved (\n, \t; \x is x).
fn cString() Err!void {
    try emByte(OP_STR);
    try emU16(0);
    const start = em_ptr;
    var p: usize = tk_at[tkp];
    var n: usize = tk_len[tkp];
    while (n > 0) {
        var c = src[p];
        p += 1;
        n -= 1;
        if (c == '\\' and n > 0) {
            c = src[p];
            p += 1;
            n -= 1;
            if (c == 'n') c = 10;
            if (c == 't') c = 9;
        }
        try emByte(c);
    }
    const len = em_ptr - start;
    if (len > 0xffff) return cError(e_text_long);
    std.mem.writeInt(u16, code[start - 2 ..][0..2], @intCast(len), .little);
    try emByte(0);
}

// ---- VM -------------------------------------------------------------------------------

fn rd16(at: usize) u16 {
    return std.mem.readInt(u16, code[at..][0..2], .little);
}
fn rdRel(at: usize) i64 {
    return std.mem.readInt(i32, code[at..][0..4], .little);
}

fn cmpNums(a: Value, b: Value) Err!void {
    if (a.t != .num or b.t != .num) return fail(e_cmp, "");
}

fn valEq(a: Value, b: Value) bool {
    if (a.t != b.t) return false;
    return switch (a.t) {
        .num => a.u.n == b.u.n,
        .str => std.mem.eql(u8, cstr(a.u.s), cstr(b.u.s)),
        else => true,
    };
}

fn bool01(b: bool) Value {
    return num(if (b) 1.0 else 0.0);
}

/// The next operation (500 million at most: the original's budget).
inline fn nx(ip: *usize, steps: *u64) Err!u8 {
    steps.* -= 1;
    if (steps.* == 0) return fail(e_steps, "");
    const o = code[ip.*];
    ip.* += 1;
    return o;
}

fn run() Err!void {
    var sp: usize = 0;
    var ip: usize = 0;
    var base: usize = 0;
    var fp: usize = 0;
    var steps: u64 = STEP_MAX;
    // threaded dispatch: each operation goes straight to the next one's code
    vm: switch (try nx(&ip, &steps)) {
        OP_HALT => return,
        OP_LINE => {
            sc_line = rd16(ip);
            ip += 2;
            continue :vm try nx(&ip, &steps);
        },
        OP_NUM => {
            if (sp >= VS_N - 2) return fail(e_stack, "");
            vstack[sp] = num(@bitCast(std.mem.readInt(u64, code[ip..][0..8], .little)));
            ip += 8;
            sp += 1;
            continue :vm try nx(&ip, &steps);
        },
        OP_STR => {
            if (sp >= VS_N - 2) return fail(e_stack, "");
            const n = rd16(ip);
            vstack[sp] = .{ .t = .str, .u = .{ .s = @ptrCast(&code[ip + 2]) } };
            ip += n + 3;
            sp += 1;
            continue :vm try nx(&ip, &steps);
        },
        OP_NIL => {
            if (sp >= VS_N - 2) return fail(e_stack, "");
            vstack[sp] = nil;
            sp += 1;
            continue :vm try nx(&ip, &steps);
        },
        OP_GETG => {
            if (sp >= VS_N - 2) return fail(e_stack, "");
            const g = rd16(ip);
            ip += 2;
            if (gvals[g].t == .unset) return fail(e_undef, nameOf(&gnames[g]));
            vstack[sp] = gvals[g];
            sp += 1;
            continue :vm try nx(&ip, &steps);
        },
        OP_SETG => {
            const g = rd16(ip);
            ip += 2;
            sp -= 1;
            gvals[g] = vstack[sp];
            continue :vm try nx(&ip, &steps);
        },
        OP_GETL => {
            if (sp >= VS_N - 2) return fail(e_stack, "");
            vstack[sp] = vstack[base + code[ip]];
            ip += 1;
            sp += 1;
            continue :vm try nx(&ip, &steps);
        },
        OP_SETL => {
            sp -= 1;
            vstack[base + code[ip]] = vstack[sp];
            ip += 1;
            continue :vm try nx(&ip, &steps);
        },
        OP_ADD => {
            sp -= 1;
            const a = vstack[sp - 1];
            const b = vstack[sp];
            if (a.t == .num and b.t == .num) {
                vstack[sp - 1].u.n = a.u.n + b.u.n;
            } else if (a.t == .str or b.t == .str) {
                vstack[sp - 1] = try concat(a, b);
            } else return fail(e_add, "");
            continue :vm try nx(&ip, &steps);
        },
        inline OP_SUB, OP_MUL, OP_DIV, OP_MOD => |op| {
            sp -= 1;
            const a = vstack[sp - 1];
            const b = vstack[sp];
            if (b.t != .num or a.t != .num) return fail(e_arith, "");
            vstack[sp - 1].u.n = switch (op) {
                OP_SUB => a.u.n - b.u.n,
                OP_MUL => a.u.n * b.u.n,
                OP_DIV => blk: {
                    if (b.u.n == 0 or std.math.isNan(b.u.n)) return fail(e_div0, "");
                    break :blk a.u.n / b.u.n;
                },
                else => blk: { // a - floor(a / b) * b
                    if (b.u.n == 0 or std.math.isNan(b.u.n)) return fail(e_div0, "");
                    break :blk a.u.n - @floor(a.u.n / b.u.n) * b.u.n;
                },
            };
            continue :vm try nx(&ip, &steps);
        },
        OP_NEG => {
            if (vstack[sp - 1].t != .num) return fail(e_arith, "");
            vstack[sp - 1].u.n = -vstack[sp - 1].u.n;
            continue :vm try nx(&ip, &steps);
        },
        OP_NOT => {
            vstack[sp - 1] = bool01(!truthy(vstack[sp - 1]));
            continue :vm try nx(&ip, &steps);
        },
        inline OP_EQ, OP_NE => |op| {
            sp -= 1;
            const e = valEq(vstack[sp - 1], vstack[sp]);
            vstack[sp - 1] = bool01(if (op == OP_EQ) e else !e);
            continue :vm try nx(&ip, &steps);
        },
        inline OP_LT, OP_LE, OP_GT, OP_GE => |op| {
            sp -= 1;
            const a = vstack[sp - 1];
            const b = vstack[sp];
            try cmpNums(a, b);
            // ucomisd: an unordered pair reads as "below and equal"
            const un = std.math.isNan(a.u.n) or std.math.isNan(b.u.n);
            const r = switch (op) {
                OP_LT => un or a.u.n < b.u.n,
                OP_LE => un or a.u.n <= b.u.n,
                OP_GT => !un and a.u.n > b.u.n,
                else => !un and a.u.n >= b.u.n,
            };
            vstack[sp - 1] = bool01(r);
            continue :vm try nx(&ip, &steps);
        },
        OP_JMP => {
            ip = @intCast(@as(i64, @intCast(ip)) + rdRel(ip) + 4);
            continue :vm try nx(&ip, &steps);
        },
        OP_JF => {
            sp -= 1;
            if (!truthy(vstack[sp])) ip = @intCast(@as(i64, @intCast(ip)) + rdRel(ip) + 4) else ip += 4;
            continue :vm try nx(&ip, &steps);
        },
        OP_JFK => {
            if (!truthy(vstack[sp - 1])) ip = @intCast(@as(i64, @intCast(ip)) + rdRel(ip) + 4) else {
                sp -= 1;
                ip += 4;
            }
            continue :vm try nx(&ip, &steps);
        },
        OP_JTK => {
            if (truthy(vstack[sp - 1])) ip = @intCast(@as(i64, @intCast(ip)) + rdRel(ip) + 4) else {
                sp -= 1;
                ip += 4;
            }
            continue :vm try nx(&ip, &steps);
        },
        OP_CALLB => {
            if (sp >= VS_N - 2) return fail(e_stack, "");
            const k = code[ip];
            const argc = code[ip + 1];
            ip += 2;
            sp -= argc;
            const an = @import("anim.zig");
            if (an.after_drivers != null or an.cur != null) an.rigEval(); // (what the script changed, rigged)
            if (argc == 1 and vstack[sp].t == .num) {
                if (num1_of[k]) |f| { // (sin, sqrt, floor ...: no slice, no error union)
                    vstack[sp] = num(f(vstack[sp].u.n));
                    sp += 1;
                    continue :vm try nx(&ip, &steps);
                }
            }
            const h = handlers[k] orelse return fail(e_not_ported, tbl.specs[k].name);
            vstack[sp] = try h(vstack[sp .. sp + argc]);
            sp += 1;
            continue :vm try nx(&ip, &steps);
        },
        OP_CALLF => {
            const f = &fntab[rd16(ip)];
            const argc = code[ip + 2];
            ip += 3;
            if (f.code == 0) return fail(e_nofn, nameOf(&f.name));
            if (argc != f.params) return fail(e_args, nameOf(&f.name));
            if (fp >= FR_N - 1) return fail(e_recursion, "");
            frames[fp] = .{ .ip = @intCast(ip), .base = @intCast(base) };
            fp += 1;
            base = sp - argc; // locals start at the first argument
            const plain = f.locals - f.params; // plain locals start as nil
            if (sp + plain >= VS_N - 4) return fail(e_stack, "");
            for (0..plain) |_| {
                vstack[sp] = nil;
                sp += 1;
            }
            ip = f.code;
            continue :vm try nx(&ip, &steps);
        },
        OP_RET => {
            sp -= 1;
            const v = vstack[sp];
            if (fp == 0) { // return at the top level ends the run
                result = v;
                return;
            }
            fp -= 1;
            sp = base;
            ip = frames[fp].ip;
            base = frames[fp].base;
            vstack[sp] = v;
            sp += 1;
            continue :vm try nx(&ip, &steps);
        },
        OP_POP => {
            sp -= 1;
            continue :vm try nx(&ip, &steps);
        },
        OP_POPR => {
            sp -= 1;
            result = vstack[sp];
            continue :vm try nx(&ip, &steps);
        },
        OP_CLRR => {
            result = nil;
            continue :vm try nx(&ip, &steps);
        },
        else => unreachable,
    }
}

// ---- running ---------------------------------------------------------------------------

/// Hooks for the agent side (MCP, agent permissions): may this agent run
/// operator i? null: yes; else the original's message (its text ends with
/// ": ", the operator id follows).
pub var agent_gate: ?*const fn (op: usize) ?[]const u8 = null;

/// Is a script running now (scripts can't start scripts; macros record nothing)?
pub fn isRunning() bool {
    return running;
}

/// script_eval: run BeeScript. 0 ok, 1 an error (it was printed). Output
/// (print, the result, errors) goes to the console and to output().
pub fn eval(source: []const u8, by_agent: bool) u8 {
    if (running) {
        app.log("{s}", .{s_busy});
        return 1;
    }
    agent = by_agent;
    const n = @min(std.mem.indexOfScalar(u8, source, 0) orelse source.len, SRC_MAX - 1);
    if (source.ptr != &src) std.mem.copyForwards(u8, src[0..n], source[0..n]);
    src[n] = 0;
    return evalSrc();
}

fn evalSrc() u8 {
    out_len = 0;
    running = true;
    phase = 0;
    sc_line = 0;
    result = nil;
    shCompact();
    fntab_save = fntab; // compile errors roll functions back
    fcount_save = fcount;
    fn_pos_save = fn_pos;
    var failed = false;
    const keep_frozen = undo.frozen;
    if (lex()) {
        if (compile()) {
            phase = 1;
            ops.quiet = true;
            undo.frozen = true; // the whole run is one undo step
            if (run()) {
                if (result.t == .num or result.t == .str) {
                    var at: usize = 0;
                    lnStr(&at, "= ");
                    if (result.t == .str) {
                        ln[at] = '"';
                        at += 1;
                    }
                    at = valTo(result, &ln, at, LN_MAX - 2);
                    if (result.t == .str) {
                        ln[at] = '"';
                        at += 1;
                    }
                    scPrint(ln[0..at]);
                }
            } else |_| failed = true;
            undo.frozen = keep_frozen;
            undo.label("Script");
        } else |_| failed = true;
    } else |_| failed = true;
    if (failed and phase == 0) {
        fntab = fntab_save;
        fcount = fcount_save;
        fn_pos = fn_pos_save;
    }
    ops.quiet = false;
    ops.arg = "";
    running = false;
    agent = false;
    app.dirty = true;
    return if (failed) 1 else 0;
}

/// script_run_file: 0 ok, 1 a script error, 2 unreadable (said in the output).
pub fn runFile(path: []const u8) u8 {
    out_len = 0;
    var pb: [600]u8 = undefined;
    if (path.len >= pb.len) return cantRead(path);
    @memcpy(pb[0..path.len], path);
    pb[path.len] = 0;
    const fd_rc = linux.open(@ptrCast(&pb), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return cantRead(path);
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true, .TYPE = true }, &st)) != .SUCCESS) return cantRead(path);
    if (st.mode & linux.S.IFMT == linux.S.IFDIR or st.size == 0) return cantRead(path);
    if (st.size >= SRC_MAX - 1) {
        scPrint(s_too_big);
        return 2;
    }
    if (running) {
        app.log("{s}", .{s_busy});
        return 1;
    }
    var got: usize = 0;
    while (got < st.size) {
        const r = linux.read(fd, src[got..].ptr, st.size - got);
        if (linux.errno(r) != .SUCCESS) return cantRead(path);
        if (r == 0) break;
        got += r;
    }
    src[got] = 0;
    app.log("  running {s}", .{path});
    ops.arg = "";
    agent = false;
    return evalSrc();
}

fn cantRead(path: []const u8) u8 {
    var at: usize = 0;
    lnStr(&at, s_cant_read);
    lnStr(&at, path);
    scPrint(ln[0..at]);
    return 2;
}

/// script.reset: variables and functions forgotten.
pub fn reset() void {
    gcount = 0;
    fcount = 0;
    fn_pos = MAIN_CODE;
    app.log("{s}", .{s_reset});
}

// ---- macro recording --------------------------------------------------------------------

var mac: [MAC_MAX]u8 = undefined;
var mac_len: usize = 0;
pub var macro_on = false;

fn mStr(s: []const u8) void {
    for (s) |c| {
        if (c == 0 or mac_len >= MAC_MAX - 2) return;
        mac[mac_len] = c;
        mac_len += 1;
    }
}

fn mQuoted(s: []const u8) void {
    if (mac_len >= MAC_MAX - 4) return;
    mac[mac_len] = '"';
    mac_len += 1;
    for (s) |c| {
        if (c == 0 or mac_len >= MAC_MAX - 4) break;
        if (c == '"' or c == '\\') {
            mac[mac_len] = '\\';
            mac_len += 1;
        }
        mac[mac_len] = c;
        mac_len += 1;
    }
    mac[mac_len] = '"';
    mac_len += 1;
}

fn mNum(x: f64) void {
    var nb: [64]u8 = undefined;
    mStr(fmtNum(&nb, x));
}

fn recording() bool {
    return macro_on and !running;
}

/// macro_op (after an operator ran): op("id", "argument") when it changed the
/// scene (it makes an undo step, or it is an object.* operator).
pub fn macroOp(i: usize) void {
    macroOpArg(i, ops.arg);
}

/// The same for an operator the console ran itself, with its argument.
pub fn macroOpArg(i: usize, arg: []const u8) void {
    if (!recording()) return;
    const id = cat.entries[i].id;
    if (std.mem.startsWith(u8, id, "transform.") or std.mem.startsWith(u8, id, "script.")) return;
    if (!makesUndo(id) and !std.mem.startsWith(u8, id, "object.")) return;
    mStr("op(");
    mQuoted(id);
    if (arg.len > 0) {
        mStr(", ");
        mQuoted(arg);
    }
    mStr(")\n");
}

fn makesUndo(id: []const u8) bool {
    for (@import("opundo.zig").ids) |u| {
        if (std.mem.eql(u8, u, id)) return true;
    }
    return false;
}

/// macro_select (after a click selection): select("A", "B"), the active last.
pub fn macroSelect() void {
    if (!recording()) return;
    const scene = @import("scene.zig");
    mStr("select(");
    var n: usize = 0;
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (scene.active != null and scene.active.? == k) continue;
        if (!o.selected) continue;
        if (n > 0) mStr(", ");
        n += 1;
        mQuoted(o.name());
    }
    if (scene.active) |a| {
        if (a < scene.count and scene.objects[a].selected) {
            if (n > 0) mStr(", ");
            mQuoted(scene.objects[a].name());
        }
    }
    mStr(")\n");
}

/// macro_transform (after G / R / S): the selected objects' final values,
/// e.g. rotate("Cube", 0deg, 45deg, 0deg). kind: 1 move, 2 rotate, 3 scale.
pub fn macroTransform(kind: u8) void {
    if (!recording()) return;
    const scene = @import("scene.zig");
    for (scene.objects[0..scene.count]) |*o| {
        if (!o.selected) continue;
        mStr(switch (kind) {
            1 => "move(",
            2 => "rotate(",
            else => "scale(",
        });
        mQuoted(o.name());
        const v: [3]f32 = switch (kind) {
            1 => o.loc,
            2 => o.radians(),
            else => o.scl,
        };
        for (v) |c| {
            mStr(", ");
            if (kind == 2) {
                mNum(@as(f64, c) * 57.29577951308232);
                mStr("deg");
            } else mNum(c);
        }
        mStr(")\n");
    }
}

/// The macro recorded so far (tests).
pub fn macroText() []const u8 {
    return mac[0..mac_len];
}

/// mac_default: ~/BeeModel/scripts/macro.bees (the folder made).
fn macPath(buf: []u8) []const u8 {
    const home = @import("filebrowser.zig").homeDir();
    const d = std.fmt.bufPrint(buf, "{s}/BeeModel/scripts", .{home}) catch return "";
    _ = @import("spawn.zig").ensureDir(d);
    return std.fmt.bufPrint(buf, "{s}/BeeModel/scripts/macro.bees", .{home}) catch "";
}

fn opRecord() void {
    if (!macro_on) {
        mac_len = 0;
        macro_on = true;
        app.log("{s}", .{s_rec_start});
        return;
    }
    macro_on = false;
    if (mac_len == 0) return app.log("{s}", .{s_rec_empty});
    var pb: [600]u8 = undefined;
    const p = macPath(&pb);
    @import("atomicfile.zig").write(p, mac[0..mac_len]) catch return app.log("{s}", .{s_rec_fail});
    app.log("{s}{s}", .{ s_rec_saved, p });
    app.log("{s}", .{s_rec_hint});
}

fn isRecordingCheck() bool {
    return macro_on;
}

fn runPath(p: []const u8) void {
    var eb: [600]u8 = undefined;
    const path = @import("files.zig").expandHome(&eb, p) orelse p;
    _ = runFile(path);
}

fn opRun() void {
    const a = std.mem.trim(u8, ops.arg, " ");
    if (a.len > 0) return runPath(a);
    // from a menu or a key: which file (the original's path form)
    if (!ops.scripted and app.win != null) return @import("filebrowser.zig").show(.open, "Run Script", ".bees", "", runPath);
    var pb: [600]u8 = undefined;
    _ = runFile(macPath(&pb));
}

fn opReset() void {
    reset();
}

pub const list = .{
    .{ "script.record", ops.Impl{ .run = opRecord, .check = isRecordingCheck } },
    .{ "script.run", ops.Impl{ .run = opRun } },
    .{ "script.reset", ops.Impl{ .run = opReset } },
};

// ---- tests ------------------------------------------------------------------------------

test "numbers print as the original's numfmt" {
    const t = std.testing;
    var b: [64]u8 = undefined;
    try t.expectEqualStrings("0", fmtNum(&b, 0));
    try t.expectEqualStrings("0", fmtNum(&b, -0.0));
    try t.expectEqualStrings("3", fmtNum(&b, 3));
    try t.expectEqualStrings("-2.5", fmtNum(&b, -2.5));
    try t.expectEqualStrings("0.333333", fmtNum(&b, 1.0 / 3.0));
    try t.expectEqualStrings("0.3", fmtNum(&b, 0.1 + 0.2));
    try t.expectEqualStrings("1e20", fmtNum(&b, 1e20));
    try t.expectEqualStrings("-1e-5", fmtNum(&b, -0.00001));
    try t.expectEqualStrings("1.234568e15", fmtNum(&b, 1234567890123456));
    try t.expectEqualStrings("inf", fmtNum(&b, std.math.inf(f64)));
    try t.expectEqualStrings("-inf", fmtNum(&b, -std.math.inf(f64)));
    try t.expectEqualStrings("nan", fmtNum(&b, std.math.nan(f64)));
    try t.expectEqualStrings("1", fmtNum(&b, 0.9999999));
}

test "numbers parse with units, hexadecimal and exponents" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 0.02), parseNum("2cm\x00", 0).v);
    try t.expectEqual(@as(f64, 255), parseNum("0xff\x00", 0).v);
    try t.expectEqual(@as(u8, 1), parseNum("0xffm\x00", 0).status);
    try t.expectEqual(@as(u8, 1), parseNum("2M\x00", 0).status);
    try t.expectEqual(@as(f64, 1500), parseNum("1.5e3\x00", 0).v);
    try t.expectEqual(@as(u8, 1), parseNum("1e\x00", 0).status);
    try t.expectEqual(@as(usize, 1), parseNum("1..5\x00", 0).end);
    try t.expectEqual(@as(u8, 2), parseNum(".\x00", 0).status);
}

test "cvttsd2si out of range" {
    const t = std.testing;
    try t.expectEqual(std.math.minInt(i64), ci64(std.math.nan(f64)));
    try t.expectEqual(std.math.minInt(i32), ci32(3e9));
    try t.expectEqual(@as(i32, -3), ci32(-3.9));
}
