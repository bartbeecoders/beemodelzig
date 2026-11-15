const std = @import("std");
const zui = @import("zui");
const testing = std.testing;
const Fixture = @import("fixture.zig").Fixture;
const items = [_]zui.Choice{ .{ .label = "One" }, .{ .label = "Two" }, .{ .label = "Three" } };
const App = struct {
    sel: usize = 0,
    pub fn frame(app: *App, ui: *zui.Ui) void {
        _ = ui.dropdown("Pick", &app.sel, &items, .{});
    }
};
test "dropdown opened with Enter, then Down, Enter" {
    const f = try Fixture(App).create();
    defer f.destroy();
    f.ui.setFocus(f.ui.id("Pick"));
    try f.play("key enter");
    std.debug.print("open after enter: {}\n", .{f.ui.isPopupOpen("Pick##list")});
    try f.play(
        \\key down
        \\key enter
    );
    std.debug.print("sel={d}\n", .{f.app.sel});
    try testing.expectEqual(@as(usize, 1), f.app.sel);
}
