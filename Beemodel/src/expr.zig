// Numbers in the console's arguments (the original's parse_float takes plain
// numbers; this takes those and more). Not the number fields: they commit
// through cad.eval (animexpr.zig, the port of expr.s), as wg_commit does.
// The forms: 2*pi, (1+2)/3, -4^2,
// sqrt(2), units (25mm, 2.5cm, 1m, 3in, 1ft; one unit is a metre) and a
// trailing ° for angles. Returns null when the text is not an expression.
const std = @import("std");

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn skip(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }

    fn peek(p: *Parser) u8 {
        p.skip();
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() == c) {
            p.i += 1;
            return true;
        }
        return false;
    }

    // sum := term (('+'|'-') term)*
    fn sum(p: *Parser) ?f64 {
        var v = p.term() orelse return null;
        while (true) {
            if (p.eat('+')) {
                v += p.term() orelse return null;
            } else if (p.eat('-')) {
                v -= p.term() orelse return null;
            } else return v;
        }
    }

    // term := unary (('*'|'/'|'%') unary)*
    fn term(p: *Parser) ?f64 {
        var v = p.unary() orelse return null;
        while (true) {
            if (p.eat('*')) {
                v *= p.unary() orelse return null;
            } else if (p.eat('/')) {
                const d = p.unary() orelse return null;
                if (d == 0) return null;
                v /= d;
            } else if (p.eat('%')) {
                const d = p.unary() orelse return null;
                if (d == 0) return null;
                v = @mod(v, d);
            } else return v;
        }
    }

    // unary := '-' unary | '+' unary | power
    fn unary(p: *Parser) ?f64 {
        if (p.eat('-')) return -(p.unary() orelse return null);
        if (p.eat('+')) return p.unary();
        return p.power();
    }

    // power := atom ('^' unary)?
    fn power(p: *Parser) ?f64 {
        const b = p.atom() orelse return null;
        if (p.eat('^')) {
            const e = p.unary() orelse return null;
            return std.math.pow(f64, b, e);
        }
        return b;
    }

    fn atom(p: *Parser) ?f64 {
        const c = p.peek();
        var v: f64 = undefined;
        if (c == '(') {
            p.i += 1;
            v = p.sum() orelse return null;
            if (!p.eat(')')) return null;
        } else if (std.ascii.isDigit(c) or c == '.') {
            const st = p.i;
            while (p.i < p.s.len and (std.ascii.isDigit(p.s[p.i]) or p.s[p.i] == '.')) p.i += 1;
            // exponent: 1e-3
            if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E') and p.i + 1 < p.s.len and
                (std.ascii.isDigit(p.s[p.i + 1]) or ((p.s[p.i + 1] == '-' or p.s[p.i + 1] == '+') and p.i + 2 < p.s.len and std.ascii.isDigit(p.s[p.i + 2]))))
            {
                p.i += 2;
                while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
            }
            v = std.fmt.parseFloat(f64, p.s[st..p.i]) catch return null;
        } else if (std.ascii.isAlphabetic(c)) {
            const st = p.i;
            while (p.i < p.s.len and (std.ascii.isAlphabetic(p.s[p.i]) or (p.i > st and (std.ascii.isDigit(p.s[p.i]) or p.s[p.i] == '_')))) p.i += 1;
            const name = p.s[st..p.i];
            if (eq(name, "pi")) {
                v = std.math.pi;
            } else if (eq(name, "tau")) {
                v = std.math.tau;
            } else if (eq(name, "e")) {
                v = std.math.e;
            } else if (p.peek() != '(') {
                // a name through the hook (none is set in the app)
                return (param_value orelse return null)(name);
            } else {
                // a function of one argument
                if (!p.eat('(')) return null;
                const a = p.sum() orelse return null;
                if (!p.eat(')')) return null;
                const r = std.math.pi / 180.0;
                v = if (eq(name, "sqrt")) (if (a < 0) return null else @sqrt(a)) else if (eq(name, "abs")) @abs(a) else if (eq(name, "sin")) @sin(a * r) else if (eq(name, "cos")) @cos(a * r) else if (eq(name, "tan")) @tan(a * r) else if (eq(name, "round")) @round(a) else if (eq(name, "floor")) @floor(a) else if (eq(name, "ceil")) @ceil(a) else return null;
            }
        } else return null;
        return v * p.unit();
    }

    /// An optional unit right after a number: the factor to metres.
    fn unit(p: *Parser) f64 {
        const st = p.i;
        var j = p.i;
        while (j < p.s.len and std.ascii.isAlphabetic(p.s[j])) j += 1;
        const u = p.s[st..j];
        const units = [_]struct { []const u8, f64 }{
            .{ "mm", 0.001 }, .{ "cm", 0.01 }, .{ "dm", 0.1 }, .{ "m", 1 }, .{ "km", 1000 },
            .{ "in", 0.0254 }, .{ "ft", 0.3048 }, .{ "um", 1e-6 },
        };
        for (units) |un| {
            if (u.len > 0 and eq(u, un[0])) {
                p.i = j;
                return un[1];
            }
        }
        // a degree sign (UTF-8 C2 B0) or "deg" is just the number
        if (p.i + 1 < p.s.len and p.s[p.i] == 0xC2 and p.s[p.i + 1] == 0xB0) p.i += 2;
        if (eq(u, "deg")) p.i = j;
        return 1;
    }
};

/// Names' values (a test sets it): null when none by that name.
pub var param_value: ?*const fn ([]const u8) ?f64 = null;

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn eval(text: []const u8) ?f32 {
    const s = std.mem.trim(u8, text, " \t");
    if (s.len == 0) return null;
    var p = Parser{ .s = s };
    const v = p.sum() orelse return null;
    p.skip();
    if (p.i != s.len) return null;
    if (std.math.isNan(v) or std.math.isInf(v)) return null;
    return @floatCast(v);
}

test "expressions" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.025), eval("25mm").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6.2831853), eval("2*pi").?, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), eval("(1+2)/3").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -16), eval("-4^2").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0254), eval("1m + 1in").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), eval("sin(30)").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 45), eval("45°").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.001), eval("1e-3").?, 1e-9);
    try std.testing.expect(eval("2*") == null);
    try std.testing.expect(eval("1/0") == null);
    try std.testing.expect(eval("abc") == null);
    try std.testing.expect(eval("") == null);
    // names: the CAD parameters when there are any
    try std.testing.expect(eval("wall") == null);
    param_value = struct {
        fn f(n: []const u8) ?f64 {
            return if (std.mem.eql(u8, n, "wall2")) 0.002 else null;
        }
    }.f;
    defer param_value = null;
    try std.testing.expectApproxEqAbs(@as(f32, 0.022), eval("10*wall2 + 2mm").?, 1e-7);
    try std.testing.expect(eval("wall") == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), eval("sin(30)").?, 1e-6);
}
