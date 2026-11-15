const std = @import("std");
const zui = @import("zui");
test "wrappedText cost vs length" {
    const A = std.heap.page_allocator;
    var font: zui.Font = try .initDefault(A);
    var ui: zui.Ui = .init(A, .{ .font = &font });
    for ([_]usize{ 1000, 4000, 16000 }) |n| {
        const text = try A.alloc(u8, n);
        for (text, 0..) |*c, i| c.* = if (i % 6 == 5) ' ' else 'a';
        const io = std.testing.io; const t0 = std.Io.Clock.awake.now(io).nanoseconds;
        for (0..5) |_| {
            ui.beginFrame(.{ .width = 500, .height = 300 });
            ui.wrappedText(text, .{});
            _ = try ui.endFrame();
        }
        std.debug.print("\nchars={} ms/frame={d:.2}\n", .{ n, @as(f64, @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds - t0)) / 5e6 });
    }
}
