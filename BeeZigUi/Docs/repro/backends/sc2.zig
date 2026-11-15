const std = @import("std");
const zui = @import("zui");
test "frames inf" {
    var font = try zui.Font.initDefault(std.testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(std.testing.allocator, .{ .font = &font });
    defer ui.deinit();
    var player: zui.ScriptPlayer = try .init(std.testing.allocator, "frames inf\n");
    defer player.deinit();
    while (try player.next(&ui)) |step| switch (step) {
        .frame => |dt| { ui.beginFrame(.{ .width = 400, .height = 300, .dt = dt }); _ = try ui.endFrame(); },
        .shot => {},
    };
}
