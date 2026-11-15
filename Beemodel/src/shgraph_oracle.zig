// The evaluator against the assembly original: tests/files/graph_oracle.* hold
// every node type and operation as the original's `nodeval` gave them, from
// tools/legacy/gen_graph_oracle.py. (A test file: zig test src/shgraph_oracle.zig.)
const std = @import("std");
const material = @import("material.zig");
const images = @import("images.zig");
const sg = @import("shgraph.zig");

fn tol(want: f32) f32 {
    // the table has 10 digits; floats and x87 steps round a little differently
    return @max(@abs(want) * 2.5e-6, 1.0e-5);
}

test "every node type: the original's numbers" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    const bin = try dir.readFileAlloc(io, "tests/files/graph_oracle.bin", a, .limited(1 << 24));
    defer a.free(bin);
    const txt = try dir.readFileAlloc(io, "tests/files/graph_oracle.txt", a, .limited(1 << 24));
    defer a.free(txt);
    const n0 = std.mem.readInt(u32, bin[0..4], .little);
    try std.testing.expect(material.readMats(bin[4..][0..n0]));
    const rest = bin[4 + n0 ..];
    const n1 = std.mem.readInt(u32, rest[0..4], .little);
    try std.testing.expect(material.readGraphs(rest[4..][0..n1]));
    images.clear();
    _ = try images.load("tests/files/oracle_tex.png");
    defer images.clear();
    var lines = std.mem.tokenizeScalar(u8, txt, '\n');
    var total: usize = 0;
    var bad: usize = 0;
    var worst: f32 = 0;
    while (lines.next()) |l| {
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const nm = it.next().?;
        const node = try std.fmt.parseInt(u32, it.next().?, 10);
        const k = try std.fmt.parseInt(u32, it.next().?, 10);
        var f: [5]f32 = undefined;
        for (&f) |*x| x.* = try std.fmt.parseFloat(f32, it.next().?);
        const want = try std.fmt.parseFloat(f32, it.next().?);
        const mi = material.find(nm).?;
        const got = sg.probe(&material.list[mi], material.list[0..material.count], node, k, f[0..3].*, f[3..5].*).?;
        total += 1;
        const d = @abs(got - want);
        const same = std.math.isNan(got) == std.math.isNan(want) and (d <= tol(want) or (std.math.isInf(got) and got == want));
        if (!same) {
            bad += 1;
            if (bad <= 30) std.debug.print("{s}: got {d}, want {d} (type {d})\n", .{ l, got, want, sg.nodesOf(&material.list[mi])[node - 1].type });
        } else if (std.math.isFinite(d)) worst = @max(worst, d / @max(@abs(want), 1));
    }
    std.debug.print("graph oracle: {d} values, {d} differ, worst relative {e}\n", .{ total, bad, worst });
    try std.testing.expect(total > 5000);
    try std.testing.expectEqual(@as(usize, 0), bad);
}
