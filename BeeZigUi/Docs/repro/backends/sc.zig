const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

fn play(script: []const u8, gpa: std.mem.Allocator) !void {
    var font = try zui.Font.initDefault(testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(testing.allocator, .{ .font = &font });
    defer ui.deinit();
    var player: zui.ScriptPlayer = try .init(gpa, script);
    defer player.deinit();
    var n: usize = 0;
    while (try player.next(&ui)) |step| switch (step) {
        .frame => |dt| {
            ui.beginFrame(.{ .width = 400, .height = 300, .dt = dt });
            _ = ui.button("B", .{});
            _ = try ui.endFrame();
            n += 1;
            if (n > 100) return;
        },
        .shot => {},
    };
}

test "type with a run of 49 continuation bytes never advances" {
    var mem: [1 << 20]u8 = undefined;
    var fa: std.heap.FixedBufferAllocator = .init(&mem);
    const run: [60]u8 = @splat(0x80);
    const script = "type " ++ run ++ "\n";
    const r = play(script, fa.allocator());
    std.debug.print("result: {any}, bytes used: {d}\n", .{ r, fa.end_index });
    try testing.expectError(error.OutOfMemory, r);
}

test "wait 1e9 queues 6e10 frames up front" {
    var mem: [1 << 20]u8 = undefined;
    var fa: std.heap.FixedBufferAllocator = .init(&mem);
    const r = play("wait 1e9\n", fa.allocator());
    std.debug.print("wait 1e9: {any}\n", .{r});
}
