const std = @import("std");
const zui = @import("zui");
const testing = std.testing;
const Fixture = @import("fixture.zig").Fixture;

const App = struct {
    a: f64 = 1,
    b: f64 = 1,
    small: f32 = 1.2345e-7,
    third: f64 = 1.0 / 3.0,
    big: i64 = 5,
    committed: u32 = 0,
    pub fn frame(app: *App, ui: *zui.Ui) void {
        if (ui.numberField("A", &app.a, .{}).committed) app.committed += 1;
        if (ui.numberField("B", &app.b, .{}).committed) app.committed += 1;
        _ = ui.numberField("Small", &app.small, .{});
        _ = ui.numberField("Third", &app.third, .{});
        _ = ui.numberField("Big", &app.big, .{});
    }
};

test "typed value lost when clicking straight into another number field" {
    const f = try Fixture(App).create();
    defer f.destroy();
    try f.play(
        \\click number:A
        \\type 7
        \\click number:B
    );
    try f.play("key escape");
    std.debug.print("a after click-away = {d} (expected 7) committed={d}\n", .{ f.app.a, f.app.committed });
    try testing.expectEqual(@as(f64, 7), f.app.a);
}

test "click + Enter without typing changes value (precision)" {
    const f = try Fixture(App).create();
    defer f.destroy();
    try f.play(
        \\click number:Small
        \\key enter
        \\click number:Third
        \\key enter
    );
    std.debug.print("small = {e} third = {d}\n", .{ f.app.small, f.app.third });
    try testing.expectEqual(@as(f32, 1.2345e-7), f.app.small);
    try testing.expectEqual(@as(f64, 1.0 / 3.0), f.app.third);
}

test "i64 field typed 1e30 overflows intFromFloat" {
    const f = try Fixture(App).create();
    defer f.destroy();
    try f.play(
        \\click number:Big
        \\type 1e30
        \\key enter
    );
    std.debug.print("big = {d}\n", .{f.app.big});
}
