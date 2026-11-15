//! 2D views: zoom about the pointer, pan, fit, limits, handles, boxes,
//! the playhead.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const App = struct {
    view: zui.View2D = .{},
    current: f32 = 10,
    point: zui.Vec2 = .{ .x = 50, .y = 50 },
    other: zui.Vec2 = .{ .x = 20, .y = 20 },
    result: zui.ViewResult = .{},
    handle: zui.HandleResult = .{ .interaction = .{} },
    commits: u32 = 0,
    v: ?zui.ViewFrame = null,

    fn frame(app: *App, ui: *zui.Ui) void {
        const v = ui.beginView2D("view", &app.view, .{
            .rulers = .{ .x = .frames },
            .content = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
            .limits = .{ .x = -50, .y = -50, .w = 200, .h = 200 },
            .max_zoom = .{ .x = 50, .y = 50 },
        });
        app.v = v;
        _ = ui.playhead(v, &app.current, .{});
        app.handle = ui.viewHandle(v, 1, &app.point, .{ .label = "point", .snap = .{ .x = 5, .y = 5 } });
        if (app.handle.interaction.committed) app.commits += 1;
        if (app.handle.delta.x != 0 or app.handle.delta.y != 0) app.other = app.other.add(app.handle.delta);
        app.result = ui.endView2D();
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

    fn frame(f: *Fixture) !void {
        f.ui.beginFrame(.{ .width = 600, .height = 500, .dt = 0.016 });
        f.app.frame(&f.ui);
        _ = try f.ui.endFrame();
    }

    fn settle(f: *Fixture) !void {
        for (0..4) |_| try f.frame();
    }

    fn play(f: *Fixture, script: []const u8) !void {
        var player: zui.ScriptPlayer = try .init(testing.allocator, script);
        defer player.deinit();
        while (player.next(&f.ui) catch |err| {
            std.debug.print("{s}\n", .{player.message()});
            return err;
        }) |step| switch (step) {
            .frame => try f.frame(),
            .shot => {},
        };
    }
};

test "the wheel zooms about the pointer; Home fits again" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.settle();
    const v = f.app.v.?;
    const at: zui.Vec2 = .{ .x = v.rect.x + 100, .y = v.rect.y + 80 };
    f.ui.input.onMouseMove(at);
    try f.frame();
    const before = f.app.v.?.toWorld(at);
    const zoom = f.app.view.zoom.x;
    f.ui.input.onScroll(.{ .x = 0, .y = 3 });
    try f.frame();
    try testing.expectApproxEqAbs(zoom * std.math.pow(f32, 1.2, 3), f.app.view.zoom.x, 1e-3);
    const after = f.app.v.?.toWorld(at);
    try testing.expectApproxEqAbs(before.x, after.x, 1e-3);
    try testing.expectApproxEqAbs(before.y, after.y, 1e-3);
    // Limits: zooming in a lot stops at the maximum.
    f.ui.input.onScroll(.{ .x = 0, .y = 60 });
    try f.frame();
    try testing.expectEqual(@as(f32, 50), f.app.view.zoom.x);
    f.ui.input.onKeyPress(.home);
    try f.frame();
    try testing.expectApproxEqAbs(zoom, f.app.view.zoom.x, 1e-3);
}

test "the middle button pans; the view can't wander off" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.settle();
    const v = f.app.v.?;
    const origin = f.app.view.origin;
    f.ui.input.onMouseMove(.{ .x = v.rect.x + 50, .y = v.rect.y + 50 });
    try f.frame();
    f.ui.input.onMouseButton(.middle, true);
    try f.frame();
    f.ui.input.onMouseMove(.{ .x = v.rect.x + 90, .y = v.rect.y + 70 });
    try f.frame();
    const z = f.app.view.zoom;
    try testing.expectApproxEqAbs(origin.x - 40 / z.x, f.app.view.origin.x, 1e-3);
    try testing.expectApproxEqAbs(origin.y - 20 / z.y, f.app.view.origin.y, 1e-3);
    // Far away: the limits hold it.
    f.ui.input.onMouseMove(.{ .x = v.rect.x + 5000, .y = v.rect.y + 70 });
    try f.frame();
    f.ui.input.onMouseButton(.middle, false);
    try f.frame();
    try testing.expect(f.app.v.?.visible().right() > -50);
    try testing.expect(!f.app.view.follow_fit);
}

test "a handle drags in world units, snaps, and Escape takes it back" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\drag handle:point by 40 0
    );
    // Snapped to 5s; the other point followed by the same amount.
    try testing.expectEqual(@as(f32, 0), @mod(f.app.point.x, 5));
    try testing.expect(f.app.point.x > 50);
    try testing.expectEqual(f.app.point.x - 50, f.app.other.x - 20);
    try testing.expectEqual(@as(u32, 1), f.app.commits);

    const start = f.app.point;
    const other = f.app.other;
    const h = f.ui.findWidget("handle:point").?;
    f.ui.input.onMouseMove(.{ .x = h.rect.x + h.rect.w / 2, .y = h.rect.y + h.rect.h / 2 });
    try f.frame();
    f.ui.input.onMouseButton(.left, true);
    try f.frame();
    f.ui.input.onMouseMove(.{ .x = h.rect.x + 200, .y = h.rect.y + 100 });
    try f.frame();
    try testing.expect(!std.meta.eql(start, f.app.point));
    f.ui.input.onKeyPress(.escape);
    try f.frame();
    try testing.expect(f.app.handle.interaction.cancelled);
    try testing.expectEqual(start, f.app.point);
    try testing.expectEqual(other, f.app.other);
    f.ui.input.onMouseButton(.left, false);
    try f.frame();
}

test "a box on empty space, by modifiers; a click is a click" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.settle();
    const v = f.app.v.?;
    const a: zui.Vec2 = .{ .x = v.rect.x + 10, .y = v.rect.y + 10 };
    f.ui.input.onMouseMove(a);
    try f.frame();
    f.ui.input.modifiers = .{ .shift = true };
    f.ui.input.onMouseButton(.left, true);
    try f.frame();
    f.ui.input.modifiers = .{};
    f.ui.input.onMouseMove(.{ .x = a.x + 60, .y = a.y + 40 });
    try f.frame();
    f.ui.input.onMouseButton(.left, false);
    try f.frame();
    const box = f.app.result.box orelse return error.NoBox;
    try testing.expectEqual(zui.BoxMode.add, box.mode);
    try testing.expectApproxEqAbs(60 / f.app.view.zoom.x, box.rect.w, 1e-3);
    // A click without a drag.
    f.ui.input.onMouseButton(.left, true);
    try f.frame();
    f.ui.input.onMouseButton(.left, false);
    try f.frame();
    try testing.expect(f.app.result.clicked != null);
    try testing.expect(f.app.result.box == null);
}

test "the playhead scrubs whole frames on the ruler" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\drag playhead:playhead to 50%
    );
    try testing.expectEqual(@round(f.app.current), f.app.current);
    try testing.expectApproxEqAbs(@as(f32, 50), f.app.current, 1);
}
