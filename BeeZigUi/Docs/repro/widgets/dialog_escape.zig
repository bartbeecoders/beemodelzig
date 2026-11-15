const std = @import("std");
const zui = @import("zui");
const testing = std.testing;
const Fixture = @import("fixture.zig").Fixture;
const App = struct {
    open: bool = true,
    v: f32 = 0.5,
    n: f32 = 1,
    rect: zui.Rect = .{},
    nrect: zui.Rect = .{},
    cancelled: bool = false,
    pub fn frame(app: *App, ui: *zui.Ui) void {
        if (ui.beginDialog("Settings", &app.open, .{})) {
            const r = ui.slider("Amount", &app.v, 0, 1, .{});
            app.rect = r.rect;
            const n = ui.numberField("Size", &app.n, .{});
            app.nrect = n.rect;
            if (r.cancelled) app.cancelled = true;
            ui.endDialog();
        }
    }
};
fn dragThenEscape(f: anytype, rect: zui.Rect) !void {
    const in = &f.ui.input;
    in.onMouseMove(.{ .x = rect.x + 20, .y = rect.y + rect.h / 2 });
    try f.frame(0.016);
    in.onMouseButton(.left, true);
    try f.frame(0.016);
    in.onMouseMove(.{ .x = rect.x + 80, .y = rect.y + rect.h / 2 });
    try f.frame(0.016);
    in.onKeyPress(.escape);
    try f.frame(0.016);
    in.onMouseButton(.left, false);
    try f.frame(0.016);
}
test "Escape cancelling a slider drag also closes the dialog" {
    const f = try Fixture(App).create();
    defer f.destroy();
    try f.frame(0.016);
    try f.frame(0.016);
    try dragThenEscape(f, f.app.rect);
    std.debug.print("slider: v={d} cancelled={} dialog open={}\n", .{ f.app.v, f.app.cancelled, f.app.open });
    try testing.expect(f.app.open);
}
test "Escape cancelling a number drag also closes the dialog" {
    const f = try Fixture(App).create();
    defer f.destroy();
    try f.frame(0.016);
    try f.frame(0.016);
    try dragThenEscape(f, f.app.nrect);
    std.debug.print("number: n={d} dialog open={}\n", .{ f.app.n, f.app.open });
    try testing.expect(f.app.open);
}
