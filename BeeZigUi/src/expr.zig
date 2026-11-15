//! Expressions typed into number fields: `2*pi`, `width/2`, `25mm + 1cm`.
//!
//! Numbers, `+ - * / %`, `^` for powers, parentheses, `pi`, `tau` and `e`,
//! the functions below, units the field knows (`25mm`, `3 ft`), names the
//! app defines, and a number right before a name multiplies (`2pi`).
//! Functions: sqrt, abs, sin, cos, tan, asin, acos, atan, atan2, min, max,
//! floor, ceil, round, exp, ln, log10, pow, hypot. Angles in trig functions
//! are radians.
//!
//! An app with its own expression language replaces all of this with
//! `Evaluator.parse`.

const std = @import("std");

/// A unit a value can be typed in, and what it is worth in the field's own
/// unit. A field in meters has `.{ .name = "mm", .factor = 0.001 }`.
pub const Unit = struct {
    name: []const u8,
    factor: f64,
};

/// Lengths for a field whose value is in meters.
pub const meters = [_]Unit{
    .{ .name = "mm", .factor = 0.001 },  .{ .name = "cm", .factor = 0.01 },
    .{ .name = "m", .factor = 1 },       .{ .name = "km", .factor = 1000 },
    .{ .name = "in", .factor = 0.0254 }, .{ .name = "ft", .factor = 0.3048 },
    .{ .name = "\"", .factor = 0.0254 }, .{ .name = "'", .factor = 0.3048 },
};

/// Lengths for a field whose value is in millimeters.
pub const millimeters = [_]Unit{
    .{ .name = "mm", .factor = 1 },     .{ .name = "cm", .factor = 10 },
    .{ .name = "m", .factor = 1000 },   .{ .name = "in", .factor = 25.4 },
    .{ .name = "ft", .factor = 304.8 }, .{ .name = "\"", .factor = 25.4 },
};

/// Angles for a field shown in degrees.
pub const degrees = [_]Unit{
    .{ .name = "deg", .factor = 1 },
    .{ .name = "\u{00B0}", .factor = 1 },
    .{ .name = "rad", .factor = 180.0 / std.math.pi },
    .{ .name = "turn", .factor = 360 },
};

/// How a field turns typed text into a number.
pub const Evaluator = struct {
    /// Units that may follow a number.
    units: []const Unit = &.{},
    /// Passed to `lookup` and `parse`.
    context: ?*anyopaque = null,
    /// Values for names the app defines, such as "width". Null if unknown.
    lookup: ?*const fn (context: ?*anyopaque, name: []const u8) ?f64 = null,
    /// Replaces the built-in parser entirely.
    parse: ?*const fn (context: ?*anyopaque, text: []const u8) ?f64 = null,

    /// The value of `text`, or null if it isn't a valid expression or isn't
    /// a finite number.
    pub fn eval(self: *const Evaluator, text: []const u8) ?f64 {
        const v = if (self.parse) |p| p(self.context, text) else blk: {
            var parser: Parser = .{ .text = text, .ev = self };
            const v = parser.expression() orelse return null;
            parser.skipSpace();
            if (parser.i != text.len) return null;
            break :blk v;
        };
        const value = v orelse return null;
        return if (std.math.isFinite(value)) value else null;
    }
};

const Parser = struct {
    text: []const u8,
    i: usize = 0,
    ev: *const Evaluator,
    depth: u32 = 0,

    fn skipSpace(p: *Parser) void {
        while (p.i < p.text.len and (p.text[p.i] == ' ' or p.text[p.i] == '\t')) p.i += 1;
    }

    fn peek(p: *Parser) ?u8 {
        p.skipSpace();
        return if (p.i < p.text.len) p.text[p.i] else null;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() == c) {
            p.i += 1;
            return true;
        }
        return false;
    }

    fn expression(p: *Parser) ?f64 {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > 64) return null; // nesting too deep for a typed value
        var v = p.term() orelse return null;
        while (true) {
            if (p.eat('+')) {
                v += p.term() orelse return null;
            } else if (p.eat('-')) {
                v -= p.term() orelse return null;
            } else return v;
        }
    }

    fn term(p: *Parser) ?f64 {
        var v = p.unary() orelse return null;
        while (true) {
            if (p.eat('*')) {
                v *= p.unary() orelse return null;
            } else if (p.eat('/')) {
                v /= p.unary() orelse return null;
            } else if (p.eat('%')) {
                v = @rem(v, p.unary() orelse return null);
            } else if (p.peekName() and !p.nextIsUnit()) {
                // A name right after a value multiplies: 2pi, 3 width.
                v *= p.power() orelse return null;
            } else return v;
        }
    }

    /// A sign binds looser than a power: -2^2 is -4.
    fn unary(p: *Parser) ?f64 {
        if (p.eat('-')) return -(p.unary() orelse return null);
        if (p.eat('+')) return p.unary();
        return p.power();
    }

    fn power(p: *Parser) ?f64 {
        const base = p.postfix() orelse return null;
        if (p.eat('^')) return std.math.pow(f64, base, p.unary() orelse return null);
        return base;
    }

    /// A value and the unit after it, if any.
    fn postfix(p: *Parser) ?f64 {
        const v = p.primary() orelse return null;
        p.skipSpace();
        if (p.unitHere()) |u| {
            p.i += u.name.len;
            return v * u.factor;
        }
        return v;
    }

    /// The longest unit name at the cursor that isn't the start of a
    /// longer name ("m" in "mm" is mm; "m" before "ax" isn't a unit).
    fn unitHere(p: *Parser) ?Unit {
        var best: ?Unit = null;
        for (p.ev.units) |u| {
            if (!std.mem.startsWith(u8, p.text[p.i..], u.name)) continue;
            const end = p.i + u.name.len;
            const alpha = std.ascii.isAlphabetic(u.name[u.name.len - 1]);
            if (alpha and end < p.text.len and (std.ascii.isAlphanumeric(p.text[end]) or p.text[end] == '_')) continue;
            if (best == null or u.name.len > best.?.name.len) best = u;
        }
        return best;
    }

    fn nextIsUnit(p: *Parser) bool {
        p.skipSpace();
        return p.unitHere() != null;
    }

    fn peekName(p: *Parser) bool {
        const c = p.peek() orelse return false;
        return std.ascii.isAlphabetic(c) or c == '_' or c == '(';
    }

    fn primary(p: *Parser) ?f64 {
        const c = p.peek() orelse return null;
        if (c == '(') {
            p.i += 1;
            const v = p.expression() orelse return null;
            if (!p.eat(')')) return null;
            return v;
        }
        if (std.ascii.isDigit(c) or c == '.') return p.number();
        if (std.ascii.isAlphabetic(c) or c == '_') return p.name();
        return null;
    }

    fn number(p: *Parser) ?f64 {
        const start = p.i;
        while (p.i < p.text.len and (std.ascii.isDigit(p.text[p.i]) or p.text[p.i] == '.')) p.i += 1;
        // An exponent, but not the start of a name like "e" or "em".
        if (p.i + 1 < p.text.len and (p.text[p.i] == 'e' or p.text[p.i] == 'E')) {
            var j = p.i + 1;
            if (p.text[j] == '+' or p.text[j] == '-') j += 1;
            if (j < p.text.len and std.ascii.isDigit(p.text[j])) {
                p.i = j;
                while (p.i < p.text.len and std.ascii.isDigit(p.text[p.i])) p.i += 1;
            }
        }
        return std.fmt.parseFloat(f64, p.text[start..p.i]) catch null;
    }

    fn name(p: *Parser) ?f64 {
        const start = p.i;
        while (p.i < p.text.len and (std.ascii.isAlphanumeric(p.text[p.i]) or p.text[p.i] == '_')) p.i += 1;
        const id = p.text[start..p.i];
        if (p.peek() == '(') {
            p.i += 1;
            var args: [2]f64 = undefined;
            var n: usize = 0;
            if (!p.eat(')')) {
                while (true) {
                    if (n == args.len) return null;
                    args[n] = p.expression() orelse return null;
                    n += 1;
                    if (p.eat(')')) break;
                    if (!p.eat(',')) return null;
                }
            }
            return call(id, args[0..n]);
        }
        if (std.mem.eql(u8, id, "pi")) return std.math.pi;
        if (std.mem.eql(u8, id, "tau")) return 2 * std.math.pi;
        if (std.mem.eql(u8, id, "e")) return std.math.e;
        if (p.ev.lookup) |f| return f(p.ev.context, id);
        return null;
    }
};

fn call(name: []const u8, args: []const f64) ?f64 {
    const one = [_]struct { []const u8, *const fn (f64) f64 }{
        .{ "sqrt", sqrt },   .{ "abs", abs },     .{ "sin", sin },   .{ "cos", cos },
        .{ "tan", tan },     .{ "asin", asin },   .{ "acos", acos }, .{ "atan", atan },
        .{ "floor", floor }, .{ "ceil", ceil },   .{ "round", round }, .{ "exp", exp },
        .{ "ln", ln },       .{ "log10", log10 },
    };
    for (one) |f| if (std.mem.eql(u8, f[0], name)) return if (args.len == 1) f[1](args[0]) else null;
    if (args.len != 2) return null;
    const a = args[0];
    const b = args[1];
    if (std.mem.eql(u8, name, "min")) return @min(a, b);
    if (std.mem.eql(u8, name, "max")) return @max(a, b);
    if (std.mem.eql(u8, name, "pow")) return std.math.pow(f64, a, b);
    if (std.mem.eql(u8, name, "atan2")) return std.math.atan2(a, b);
    if (std.mem.eql(u8, name, "hypot")) return std.math.hypot(a, b);
    return null;
}

fn sqrt(x: f64) f64 {
    return @sqrt(x);
}
fn abs(x: f64) f64 {
    return @abs(x);
}
fn sin(x: f64) f64 {
    return @sin(x);
}
fn cos(x: f64) f64 {
    return @cos(x);
}
fn tan(x: f64) f64 {
    return @tan(x);
}
fn asin(x: f64) f64 {
    return std.math.asin(x);
}
fn acos(x: f64) f64 {
    return std.math.acos(x);
}
fn atan(x: f64) f64 {
    return std.math.atan(x);
}
fn floor(x: f64) f64 {
    return @floor(x);
}
fn ceil(x: f64) f64 {
    return @ceil(x);
}
fn round(x: f64) f64 {
    return @round(x);
}
fn exp(x: f64) f64 {
    return @exp(x);
}
fn ln(x: f64) f64 {
    return @log(x);
}
fn log10(x: f64) f64 {
    return @log10(x);
}

const testing = std.testing;

fn expectValue(ev: Evaluator, text: []const u8, want: f64) !void {
    const got = ev.eval(text) orelse {
        std.debug.print("could not evaluate \"{s}\"\n", .{text});
        return error.TestUnexpectedResult;
    };
    try testing.expectApproxEqAbs(want, got, 1e-9);
}

test "arithmetic, precedence and functions" {
    const ev: Evaluator = .{};
    try expectValue(ev, "1 + 2 * 3", 7);
    try expectValue(ev, "(1 + 2) * 3", 9);
    try expectValue(ev, "2^3^2", 512);
    try expectValue(ev, "-2^2", -4);
    try expectValue(ev, "10 % 4", 2);
    try expectValue(ev, "2*pi", 2 * std.math.pi);
    try expectValue(ev, "2pi", 2 * std.math.pi);
    try expectValue(ev, "sqrt(16) + max(2, 5)", 9);
    try expectValue(ev, "1.5e3", 1500);
    try expectValue(ev, ".5", 0.5);
    try testing.expectEqual(@as(?f64, null), ev.eval("1 +"));
    try testing.expectEqual(@as(?f64, null), ev.eval("1/0"));
    try testing.expectEqual(@as(?f64, null), ev.eval("width"));
    try testing.expectEqual(@as(?f64, null), ev.eval("2 3"));
}

test "units and app names" {
    const Ctx = struct {
        fn lookup(_: ?*anyopaque, n: []const u8) ?f64 {
            return if (std.mem.eql(u8, n, "width")) 0.8 else null;
        }
    };
    const ev: Evaluator = .{ .units = &meters, .lookup = Ctx.lookup };
    try expectValue(ev, "25mm", 0.025);
    try expectValue(ev, "1m + 20 cm", 1.2);
    try expectValue(ev, "2ft", 0.6096);
    try expectValue(ev, "width/2", 0.4);
    try expectValue(ev, "3 width", 2.4);
    const deg: Evaluator = .{ .units = &degrees };
    try expectValue(deg, "90\u{00B0}", 90);
    try expectValue(deg, "pi rad", 180);
}

test "deep nesting is refused, not a crash" {
    const ev: Evaluator = .{};
    var deep: [401]u8 = undefined;
    @memset(deep[0..200], '(');
    deep[200] = '1';
    @memset(deep[201..], ')');
    try testing.expectEqual(@as(?f64, null), ev.eval(&deep));
}
