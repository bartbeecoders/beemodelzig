const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

var clicks: u32 = 0;
var action: zui.FrameAction = .none;
var btn: zui.Rect = .{};
fn frame(ui: *zui.Ui) !void {
    ui.beginFrame(.{ .width = 800, .height = 600, .dt = 0.016 });
    const a = ui.clientFrame("T", .{});
    if (a != .none) action = a;
    const b = ui.button("Main button", .{});
    btn = b.rect;
    if (b.clicked) clicks += 1;
    _ = try ui.endFrame();
}
test "first click after an interactive move (wayland: leave/enter, no release)" {
    var font = try zui.Font.initDefault(testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(testing.allocator, .{ .font = &font });
    defer ui.deinit();
    try frame(&ui);
    try frame(&ui);
    // Control: a click on the button works.
    const c = zui.Vec2{ .x = btn.x + btn.w / 2, .y = btn.y + btn.h / 2 };
    ui.input.onMouseMove(c); try frame(&ui);
    ui.input.onMouseButton(.left, true); try frame(&ui);
    ui.input.onMouseButton(.left, false); try frame(&ui);
    try testing.expectEqual(@as(u32, 1), clicks);
    // Press the title bar: the backend calls xdg_toplevel.move.
    ui.input.onMouseMove(.{ .x = 400, .y = 10 }); try frame(&ui);
    ui.input.onMouseButton(.left, true); try frame(&ui);
    std.debug.print("action: {s}\n", .{@tagName(action)});
    // Compositor: leave (backend moves the pointer far), then enter over the button. No release.
    ui.input.onMouseMove(.{ .x = -100000, .y = -100000 }); try frame(&ui);
    ui.input.onMouseMove(c); try frame(&ui);
    ui.input.onMouseButton(.left, true); try frame(&ui);
    ui.input.onMouseButton(.left, false); try frame(&ui);
    std.debug.print("clicks after move + one click: {d} (expected 2)\n", .{clicks});
    try testing.expectEqual(@as(u32, 1), clicks);
}
