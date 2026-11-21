//! Pie menus and the radial wheel.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const kids = [_]zui.WheelItem{ .{ .label = "Cube" }, .{ .label = "Sphere" }, .{ .label = "Torus", .disabled = "Not yet" } };
const entries = [_]zui.WheelItem{
    .{ .label = "Add", .children = &kids },
    .{ .label = "Delete" },
    .{ .label = "Parent", .disabled = "Select two objects" },
    .{ .label = "Hide" },
};
const choices = [_]zui.PieItem{ .{ .label = "Left" }, .{ .label = "Right" }, .{ .label = "Down" }, .{ .label = "Up", .disabled = "Not here" } };

const App = struct {
    pie: ?zui.PieResult = null,
    wheel: ?zui.WheelResult = null,
    behind: u32 = 0,

    fn frame(app: *App, ui: *zui.Ui) void {
        if (ui.button("Behind", .{ .width = .fill, .height = .px(500) }).clicked) app.behind += 1;
        if ((zui.Shortcut{ .key = .z }).pressed(&ui.input)) ui.openPie("Pie", .z);
        if (ui.input.mouse_pressed.contains(.right)) ui.openWheel("Wheel", .right);
        const p = ui.pie("Pie", &choices, .{});
        if (p != .none) app.pie = p;
        const w = ui.wheel("Wheel", &entries, .{});
        if (w != .none) app.wheel = w;
    }
};

const Fixture = struct {
    font: zui.Font,
    ui: zui.Ui,
    app: App = .{},

    fn create() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .font = try .initDefault(testing.allocator), .ui = undefined };
        f.ui = .init(testing.allocator, .{ .font = &f.font });
        f.ui.recording = true;
        return f;
    }

    fn destroy(f: *Fixture) void {
        f.ui.deinit();
        f.font.deinit();
        testing.allocator.destroy(f);
    }

    fn frame(f: *Fixture, dt: f32) !void {
        f.ui.beginFrame(.{ .width = 800, .height = 600, .dt = dt });
        f.app.frame(&f.ui);
        _ = try f.ui.endFrame();
    }

    fn play(f: *Fixture, script: []const u8) !void {
        var player: zui.ScriptPlayer = try .init(testing.allocator, script);
        defer player.deinit();
        while (player.next(&f.ui) catch |err| {
            std.debug.print("{s}\n", .{player.message()});
            return err;
        }) |step| switch (step) {
            .frame => |dt| try f.frame(dt),
            .shot => {},
        };
    }
};

test "a quick tap reports tapped; a hold and flick picks by direction" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\move 400 300
        \\key z
    );
    try testing.expectEqual(zui.PieResult.tapped, f.app.pie.?);
    try f.play(
        \\hold z
        \\move 520 310
        \\release z
    );
    try testing.expectEqual(zui.PieResult{ .chosen = 1 }, f.app.pie.?);
    // Held long without moving, let go in the middle: stays open for a
    // click; the click picks.
    f.app.pie = null;
    try f.play(
        \\move 400 300
        \\hold z
        \\wait 0.5
        \\release z
        \\expect pie:Pie exists
        \\click pie_item:Down
    );
    try testing.expectEqual(zui.PieResult{ .chosen = 2 }, f.app.pie.?);
    try testing.expectEqual(@as(u32, 0), f.app.behind);
}

test "a greyed choice isn't picked; Escape and a click in the middle close" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\move 400 300
        \\hold z
        \\move 400 150
        \\expect pie_item:Up = Not here
        \\release z
        \\expect pie:Pie exists
        \\key escape
        \\expect pie:Pie missing
    );
    try testing.expectEqual(zui.PieResult.cancelled, f.app.pie.?);
    f.app.pie = null;
    try f.play(
        \\hold z
        \\wait 0.5
        \\release z
        \\click pie:Pie
        \\expect pie:Pie missing
    );
    try testing.expectEqual(zui.PieResult.cancelled, f.app.pie.?);
    try testing.expectEqual(@as(u32, 0), f.app.behind);
}

test "the wheel: click, arcs, number keys, Backspace" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\move 400 300
        \\right-click button:Behind
        \\click pie_item:Delete
    );
    try testing.expectEqual(zui.WheelChoice{ .item = 1 }, f.app.wheel.?.chosen);
    try f.play(
        \\right-click button:Behind
        \\key 1
        \\expect pie_item:Add = open
        \\key backspace
        \\expect pie_item:Cube missing
        \\key 1
        \\key 3
        \\expect pie:Wheel exists
        \\key 2
    );
    try testing.expectEqual(zui.WheelChoice{ .item = 0, .child = 1 }, f.app.wheel.?.chosen);
    try f.play(
        \\right-click button:Behind
        \\click pie_item:Parent
        \\expect pie:Wheel exists
        \\key 3
        \\expect pie:Wheel exists
        \\key escape
    );
    try testing.expectEqual(zui.WheelResult.cancelled, f.app.wheel.?);
    try testing.expectEqual(@as(u32, 0), f.app.behind);
}

test "the wheel: press, drag and let go picks" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.frame(0.016);
    try f.frame(0.016);
    f.ui.input.onMouseMove(.{ .x = 400, .y = 300 });
    try f.frame(0.016);
    f.ui.input.onMouseButton(.right, true);
    try f.frame(0.016);
    // Down is the third of four entries: Parent, greyed; left is Hide.
    f.ui.input.onMouseMove(.{ .x = 320, .y = 300 });
    try f.frame(0.016);
    f.ui.input.onMouseButton(.right, false);
    try f.frame(0.016);
    try testing.expectEqual(zui.WheelChoice{ .item = 3 }, f.app.wheel.?.chosen);
    try testing.expect(!f.ui.radialOpen());
}

test "a pie opened after the app saw the key held: its release picks, at once" {
    var font = try zui.Font.initDefault(testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(testing.allocator, .{ .font = &font });
    defer ui.deinit();
    var result: zui.PieResult = .none;
    var open_at: ?zui.Vec2 = .{ .x = 300, .y = 200 };
    const frame = struct {
        fn f(u: *zui.Ui, at: *?zui.Vec2, r: *zui.PieResult) !void {
            u.beginFrame(.{ .width = 640, .height = 420, .dt = 1.0 / 60.0 });
            if (at.*) |p| {
                u.openPieAt("Pie", .z, p, true);
                at.* = null;
            }
            const res = u.pie("Pie", &choices, .{});
            if (res != .none) r.* = res;
            _ = try u.endFrame();
        }
    }.f;
    // the pointer already right of where the key went down
    ui.input.onMouseMove(.{ .x = 380, .y = 200 });
    try frame(&ui, &open_at, &result);
    try testing.expectEqual(@as(f32, 300), ui.pie_state.center.x);
    ui.input.onKeyRelease(.z);
    try frame(&ui, &open_at, &result);
    try testing.expectEqual(zui.PieResult{ .chosen = 1 }, result);
}

test "the wheel: Backspace with the pointer on a child of the open arc" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\move 400 300
        \\right-click button:Behind
        \\key 1
        \\hover pie_item:Sphere
    );
    // Backspace and a frame: the arc goes with the child under the pointer.
    f.ui.input.onKeyPress(.backspace);
    try f.frame(0.016);
    try f.play("expect pie_item:Sphere missing");
}

test "the wheel: a click outside closes it" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.frame(0.016);
    f.ui.input.onMouseMove(.{ .x = 400, .y = 300 });
    try f.frame(0.016);
    f.ui.openWheel("Wheel", null);
    try f.frame(0.016);
    f.ui.input.onMouseMove(.{ .x = 700, .y = 300 });
    try f.frame(0.016);
    f.ui.input.onMouseButton(.left, true);
    try f.frame(0.016);
    try testing.expectEqual(zui.WheelResult.cancelled, f.app.wheel.?);
    try testing.expect(!f.ui.radialOpen());
    try testing.expectEqual(@as(u32, 0), f.app.behind);
}
