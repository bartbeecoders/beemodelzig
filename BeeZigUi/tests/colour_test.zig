//! The colour picker, the eyedropper, themes and UI scale.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const App = struct {
    paint: zui.Color = zui.Color.hex(0x808080),
    base: zui.Color = zui.Color.hex(0x336699),
    recent: zui.RecentColors = .{},
    commits: u32 = 0,
    cancels: u32 = 0,
    clicks: u32 = 0,

    fn frame(app: *App, ui: *zui.Ui) void {
        if (ui.button("Elsewhere", .{}).clicked) app.clicks += 1;
        _ = ui.colorEdit("Base", &app.base, .{ .recent = &app.recent, .default = zui.Color.hex(0xFFFFFF) });
        ui.beginVertical(.{ .width = .px(280) });
        const p = ui.colorPicker("paint", &app.paint, .{ .recent = &app.recent, .alpha = false, .swatches = &.{ zui.Color.hex(0xFF0000), zui.Color.hex(0x00FF00) } });
        ui.endVertical();
        if (p.committed) app.commits += 1;
        if (p.cancelled) app.cancels += 1;
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
        f.ui.beginFrame(.{ .width = 800, .height = 700, .dt = dt });
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

test "a drag in the square is one commit; the hue survives grey" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\drag color_area:Hue to 0% 50%
        \\drag color_area:Saturation and value to 100% 0%
        \\expect swatch:New = #00FFFF
        \\drag color_area:Saturation and value to 0% 50%
        \\drag color_area:Saturation and value to 100% 0%
        \\expect swatch:New = #00FFFF
    );
    // Three drags that changed the colour (the hue of a grey changes
    // nothing to keep), each one commit, each remembered once.
    try testing.expectEqual(zui.Color.hex(0x00FFFF), f.app.paint);
    try testing.expectEqual(@as(u32, 3), f.app.commits);
    try testing.expectEqual(zui.Color.hex(0x00FFFF), f.app.recent.slice()[0]);
}

test "Escape during a drag puts the colour back" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.frame(0.016);
    try f.frame(0.016);
    const sq = f.ui.findWidget("color_area:Saturation and value") orelse return error.Missing;
    f.ui.input.onMouseMove(.{ .x = sq.rect.x + 5, .y = sq.rect.y + 5 });
    try f.frame(0.016);
    f.ui.input.onMouseButton(.left, true);
    try f.frame(0.016);
    f.ui.input.onMouseMove(.{ .x = sq.rect.right() - 2, .y = sq.rect.y + 2 });
    try f.frame(0.016);
    try testing.expect(!f.app.paint.eql(zui.Color.hex(0x808080)));
    f.ui.input.onKeyPress(.escape);
    try f.frame(0.016);
    f.ui.input.onMouseButton(.left, false);
    try f.frame(0.016);
    try testing.expectEqual(zui.Color.hex(0x808080), f.app.paint);
    try testing.expectEqual(@as(u32, 0), f.app.commits);
    try testing.expectEqual(@as(u32, 1), f.app.cancels);
}

test "the eyedropper shows the colour under the pointer and keeps it on click" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("click button:eyedropper");
    try testing.expect(f.ui.sample_request != null);
    // The backend reads the pixel back after rendering.
    _ = f.ui.input.onColorSample(zui.Color.hex(0x123456));
    try f.frame(0.016);
    try testing.expectEqual(zui.Color.hex(0x123456), f.app.paint);
    try testing.expectEqual(zui.Cursor.crosshair, f.ui.cursor);
    // The click is the eyedropper's: the button under it isn't pressed.
    try f.play("click button:Elsewhere");
    try testing.expectEqual(@as(u32, 0), f.app.clicks);
    try testing.expectEqual(@as(?zui.Vec2, null), f.ui.sample_request);
    try testing.expectEqual(@as(u32, 1), f.app.commits);
    try testing.expectEqual(zui.Color.hex(0x123456), f.app.paint);
}

test "Escape puts the colour from before the eyedropper back" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("click button:eyedropper");
    _ = f.ui.input.onColorSample(zui.Color.hex(0xABCDEF));
    try f.frame(0.016);
    try testing.expectEqual(zui.Color.hex(0xABCDEF), f.app.paint);
    try f.play("key escape");
    try testing.expectEqual(zui.Color.hex(0x808080), f.app.paint);
    try testing.expectEqual(@as(?zui.Vec2, null), f.ui.sample_request);
    try f.play("click button:Elsewhere");
    try testing.expectEqual(@as(u32, 1), f.app.clicks);
}

test "swatches, the old colour, and the swatch menu" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click swatch:#FF0000
        \\expect swatch:New = #FF0000
        \\expect swatch:Old = #808080
        \\click swatch:Old
        \\expect swatch:New = #808080
        \\right-click color_edit:Base
        \\click menu_item:Copy Hex
        \\right-click color_edit:Base
        \\click menu_item:Reset
        \\expect color_edit:Base = #FFFFFFFF
        \\right-click color_edit:Base
        \\click menu_item:Paste Hex
        \\expect color_edit:Base = #336699FF
    );
    try testing.expectEqual(zui.Color.hex(0x336699), f.app.base);
}

test "a typed hex code, then HSV fields" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click text_input:Hex
        \\key ctrl+a
        \\type #FF8000
        \\key enter
        \\expect swatch:New = #FF8000
        \\click segment:HSV
        \\expect number:H = 30.1°
        \\click number:V
        \\key ctrl+a
        \\type 50
        \\key enter
        \\expect swatch:New = #804000
    );
}

test "UI scale: the UI is smaller in units, pointer positions follow" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.frame(0.016);
    try testing.expectEqual(@as(f32, 800), f.ui.width);
    f.ui.setScale(2);
    try f.frame(0.016);
    try testing.expectEqual(@as(f32, 400), f.ui.width);
    try testing.expectEqual(@as(f32, 2), f.ui.renderFrame(1.5).scale / 1.5);
    try f.frame(0.016);
    // A click at window position (2x the button's units) hits it.
    const b = f.ui.findWidget("button:Elsewhere") orelse return error.Missing;
    f.ui.input.onMouseMove(.{ .x = (b.rect.x + 4) * 2, .y = (b.rect.y + 4) * 2 });
    f.ui.input.onMouseButton(.left, true);
    try f.frame(0.016);
    f.ui.input.onMouseButton(.left, false);
    try f.frame(0.016);
    try testing.expectEqual(@as(u32, 1), f.app.clicks);
    // Scripts name widgets, so they work at any scale.
    try f.play("click button:Elsewhere");
    try testing.expectEqual(@as(u32, 2), f.app.clicks);
    f.ui.setScale(9);
    try f.frame(0.016);
    try testing.expectEqual(zui.Ui.max_scale, f.ui.ui_scale);
}

test "built themes pass the contrast check" {
    var buffer: [32]zui.ContrastProblem = undefined;
    for (zui.theme.presets) |p| try testing.expectEqual(@as(usize, 0), zui.theme.contrastProblems(p.style(), &buffer).len);
    const s = zui.theme.build(.{ .background = zui.Color.hex(0xF0F0F0), .text = zui.Color.hex(0x202020), .accent = zui.Color.hex(0x22AA55) });
    try testing.expect(zui.color.contrast(s.colors.check_mark, s.colors.button_active) >= 4.5);
    try testing.expect(zui.theme.preset("Paper") != null);
    try testing.expect(zui.theme.preset("Nope") == null);
}
