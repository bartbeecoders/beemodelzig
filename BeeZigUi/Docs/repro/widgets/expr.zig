const std = @import("std");
const zui = @import("zui");
test "expr edges" {
    const ev: zui.Evaluator = .{ .units = &zui.expr.meters };
    const cases = [_][]const u8{ "5 % 0", "5' 3\"", "1/2pi", "2^-1", "-(-(-1))", "2 m^2", "3mm*2", "1e", "1.e3", "max(1;2)", "2(3)", "e2", "1 e", "2 in", "tau/0", "0^-1", "2--3", "5%%2" };
    for (cases) |c| std.debug.print("{s:12} -> {?d}\n", .{ c, ev.eval(c) });
    var buf: [200000]u8 = undefined;
    @memset(buf[0 .. buf.len - 1], '-');
    buf[buf.len - 1] = '1';
    std.debug.print("deep minus -> {?d}\n", .{ev.eval(&buf)});
}
