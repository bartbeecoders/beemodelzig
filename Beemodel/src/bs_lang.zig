// BeeScript's language and math builtins (script.s b_print .. b_seed, b_clock,
// b_expr): print str num len sin cos tan sqrt abs floor round deg rad min max
// pow atan2 rand seed clock expr. The trigonometry and pow's general case go
// through the x87 unit as the original's do (animexpr.zig), so values match it
// to the bit; min / max keep minsd / maxsd's answer for NaN and signed zeros.
const std = @import("std");
const linux = std.os.linux;
const bs = @import("bscript.zig");
const ax = @import("animexpr.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "print", .f = print },
    .{ .name = "str", .f = str },
    .{ .name = "num", .f = num },
    .{ .name = "len", .f = len },
    .{ .name = "sin", .f = sin },
    .{ .name = "cos", .f = cos },
    .{ .name = "tan", .f = tan },
    .{ .name = "sqrt", .f = sqrt },
    .{ .name = "abs", .f = abs },
    .{ .name = "floor", .f = floor },
    .{ .name = "round", .f = round },
    .{ .name = "deg", .f = deg },
    .{ .name = "rad", .f = rad },
    .{ .name = "min", .f = min },
    .{ .name = "max", .f = max },
    .{ .name = "pow", .f = pow },
    .{ .name = "atan2", .f = atan2 },
    .{ .name = "rand", .f = rand },
    .{ .name = "seed", .f = seed },
    .{ .name = "clock", .f = clock },
    .{ .name = "expr", .f = expr },
};

fn print(a: []const V) Err!V {
    bs.printValues(a);
    return bs.nil;
}

fn str(a: []const V) Err!V {
    return bs.toText(a[0]);
}

/// num(text): "2cm" -> 0.02, " -0x10" -> -16; nil when it is not one number.
fn num(a: []const V) Err!V {
    if (a[0].t == .num) return a[0];
    _ = try bs.argStr(a[0]);
    const s = std.mem.span(a[0].u.s);
    const z = s.ptr[0 .. s.len + 1]; // (with its 0)
    var i: usize = 0;
    while (z[i] == ' ') i += 1;
    var neg = false;
    if (z[i] == '-') {
        i += 1;
        neg = true;
    }
    const r = bs.parseNum(z, i);
    if (r.status != 0 or z[r.end] != 0) return bs.nil;
    return bs.num(if (neg) -r.v else r.v);
}

fn len(a: []const V) Err!V {
    return bs.num(@floatFromInt((try bs.argStr(a[0])).len));
}

fn sinF(x: f64) f64 {
    return ax.x87un(.sin, x);
}
fn cosF(x: f64) f64 {
    return ax.x87un(.cos, x);
}
fn tanF(x: f64) f64 {
    return ax.x87un(.tan, x);
}
fn sqrtF(x: f64) f64 {
    return @sqrt(x);
}
fn absF(x: f64) f64 {
    return @abs(x);
}
fn floorF(x: f64) f64 {
    return @floor(x);
}

/// The one-number builtins as plain functions: the VM calls these straight
/// when the argument is a number (bscript.zig OP_CALLB); anything else goes
/// the builtin's way below, with its error.
pub const num1 = .{
    .{ "sin", sinF },   .{ "cos", cosF },     .{ "tan", tanF },
    .{ "sqrt", sqrtF }, .{ "abs", absF },     .{ "floor", floorF },
};

fn wrap1(comptime f: fn (f64) f64) Fn1 {
    return struct {
        fn g(a: []const V) Err!V {
            return bs.num(f(try bs.argNum(a[0])));
        }
    }.g;
}
const Fn1 = fn ([]const V) Err!V;
const sin = wrap1(sinF);
const cos = wrap1(cosF);
const tan = wrap1(tanF);
const sqrt = wrap1(sqrtF);
const abs = wrap1(absF);
const floor = wrap1(floorF);
/// floor(x + 0.5)
fn round(a: []const V) Err!V {
    return bs.num(@floor(try bs.argNum(a[0]) + 0.5));
}
fn deg(a: []const V) Err!V {
    return bs.num(try bs.argNum(a[0]) * 57.29577951308232);
}
fn rad(a: []const V) Err!V {
    return bs.num(try bs.argNum(a[0]) * 0.017453292519943295);
}

/// minsd x, acc: x when x < acc, else acc (NaN either side: acc).
fn minmax(a: []const V, comptime is_max: bool) Err!V {
    var acc = try bs.argNum(a[0]);
    for (a[1..]) |v| {
        const x = try bs.argNum(v);
        acc = if (is_max) (if (x > acc) x else acc) else (if (x < acc) x else acc);
    }
    return bs.num(acc);
}
fn min(a: []const V) Err!V {
    return minmax(a, false);
}
fn max(a: []const V) Err!V {
    return minmax(a, true);
}

/// pow(x, y): exact for whole y (|y| <= 2^20, square and multiply), else
/// 2^(y log2 x) on the x87 unit; 0^y and NaN^y are x itself there.
fn pow(a: []const V) Err!V {
    const x = try bs.argNum(a[0]);
    const y = try bs.argNum(a[1]);
    const t = @trunc(y);
    if (t == y) {
        const n = bs.ci64(y);
        const m: u64 = if (n < 0) 0 -% @as(u64, @bitCast(n)) else @intCast(n);
        if (m <= 1048576) {
            var r: f64 = 1.0;
            var b = x;
            var k = m;
            while (k != 0) : (k >>= 1) {
                if (k & 1 != 0) r *= b;
                b *= b;
            }
            return bs.num(if (n < 0) 1.0 / r else r);
        }
    }
    if (x == 0 or std.math.isNan(x)) return bs.num(x);
    return bs.num(ax.x87pow(x, y));
}

fn atan2(a: []const V) Err!V {
    const y = try bs.argNum(a[0]);
    const x = try bs.argNum(a[1]);
    return bs.num(ax.atan2x87(y, x));
}

fn rand(_: []const V) Err!V {
    return bs.num(bs.rand());
}

fn seed(a: []const V) Err!V {
    bs.seed(try bs.argNum(a[0]));
    return bs.nil;
}

/// clock(): milliseconds, monotonic (to time scripts)
fn clock(_: []const V) Err!V {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    const s: f64 = @floatFromInt(@as(i64, @intCast(ts.sec)));
    const ns: f64 = @floatFromInt(@as(i64, @intCast(ts.nsec)));
    return bs.num(s * 1000.0 + ns / 1000000.0);
}

/// expr(text): an expression with units and the CAD parameters (expr.s)
fn expr(a: []const V) Err!V {
    const s = try bs.argStr(a[0]);
    const r = ax.evaluate(s);
    if (!r.ok) return bs.fail("parameter: ", ax.err orelse "");
    return bs.num(r.v);
}
