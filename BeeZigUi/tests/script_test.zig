//! The widget record and scripted input, driving a small app by widget name.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const App = struct {
    saves: u32 = 0,
    tool_saves: u32 = 0,
    snap: bool = false,
    volume: f32 = 0.2,
    name: [96]u8 = undefined,
    name_len: usize = 0,
    deleted: bool = false,
    show_tools: bool = true,

    fn frame(app: *App, ui: *zui.Ui) void {
        const save = ui.button("Save", .{});
        if (save.clicked) app.saves += 1;
        ui.tooltip(save, "Write the file");
        _ = ui.checkbox("Snap", &app.snap, .{});
        _ = ui.slider("Volume", &app.volume, 0, 1, .{});
        _ = ui.textInput("Name", &app.name, &app.name_len, .{});
        const menu = ui.button("Menu", .{});
        if (menu.clicked) ui.openPopupAt("menu", menu.rect);
        if (ui.beginPopup("menu", .{})) {
            defer ui.endPopup();
            if (ui.button("Delete", .{}).clicked) {
                app.deleted = true;
                ui.closeAllPopups();
            }
        }
        if (ui.beginWindow("Tools", .{ .position = .{ .x = 300, .y = 40 }, .size = .{ .x = 180, .y = 140 }, .open = &app.show_tools })) {
            defer ui.endWindow();
            if (ui.button("Save", .{}).clicked) app.tool_saves += 1;
        }
    }
};

const Failure = struct { err: anyerror };

const Fixture = struct {
    font: zui.Font,
    ui: zui.Ui,
    app: App = .{},

    fn create() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .font = try .initDefault(testing.allocator), .ui = undefined };
        f.ui = .init(testing.allocator, .{ .font = &f.font });
        return f;
    }

    fn destroy(f: *Fixture) void {
        f.ui.deinit();
        f.font.deinit();
        testing.allocator.destroy(f);
    }

    fn frame(f: *Fixture, dt: f32) !void {
        f.ui.beginFrame(.{ .width = 520, .height = 400, .dt = dt });
        f.app.frame(&f.ui);
        _ = try f.ui.endFrame();
    }

    /// Plays `script`; on failure prints the player's message.
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

    /// Plays `script` and returns the error it should fail with, after
    /// checking the player's message contains `message`.
    fn playFailing(f: *Fixture, script: []const u8, message: []const u8) !Failure {
        var player: zui.ScriptPlayer = try .init(testing.allocator, script);
        defer player.deinit();
        while (true) {
            const step = player.next(&f.ui) catch |err| {
                try testing.expect(std.mem.indexOf(u8, player.message(), message) != null);
                return .{ .err = err };
            } orelse return error.TestUnexpectedSuccess;
            switch (step) {
                .frame => |dt| try f.frame(dt),
                .shot => {},
            }
        }
    }
};

test "clicks find widgets by label, kind and window" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click Save
        \\click Tools > button:Save
        \\click Tools > button:Save
    );
    try testing.expectEqual(@as(u32, 1), f.app.saves);
    try testing.expectEqual(@as(u32, 2), f.app.tool_saves);
}

test "a checkbox, a slider and the expected values" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\expect checkbox:Snap = false
        \\click checkbox:Snap
        \\expect checkbox:Snap = true
        \\drag slider:Volume to 75%
    );
    try testing.expect(f.app.snap);
    try testing.expectApproxEqAbs(@as(f32, 0.75), f.app.volume, 0.08);
}

test "typing, keys with modifiers, and focus" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click text_input:Name
        \\expect text_input:Name focused
        \\type hello # world
        \\expect text_input:Name = hello # world
        \\key ctrl+a
        \\type Zui
        \\expect text_input:Name = Zui
        \\key shift+tab
        \\expect slider:Volume focused
    );
    try testing.expectEqualStrings("Zui", f.app.name[0..f.app.name_len]);
}

test "popups: wait for the item, click it, and it is gone" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\expect button:Delete missing
        \\click button:Menu
        \\click menu > button:Delete
        \\expect button:Delete missing
    );
    try testing.expect(f.app.deleted);
}

test "windows: drag by the title, close with its button" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("frames 2");
    const before = f.ui.findWidget("window:Tools").?.rect;
    try f.play(
        \\drag window:Tools by -60 30
        \\click Tools > window_button:Close
        \\expect window:Tools missing
    );
    try testing.expect(!f.app.show_tools);
    f.app.show_tools = true;
    try f.play("frames 2");
    const after = f.ui.findWidget("window:Tools").?.rect;
    try testing.expectApproxEqAbs(before.x - 60, after.x, 0.5);
    try testing.expectApproxEqAbs(before.y + 30, after.y, 0.5);
}

test "tooltips are in the record, and show after a wait" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("frames 2");
    try testing.expectEqualStrings("Write the file", f.ui.findWidget("button:Save").?.tooltip.?);
    try testing.expect(f.ui.findWidget("tooltip:Write the file") == null);
    try f.play(
        \\hover button:Save
        \\wait 1
        \\expect tooltip:Write the file exists
    );
}

test "a widget that never shows fails with the line and the name" {
    const f = try Fixture.create();
    defer f.destroy();
    const err = try f.playFailing(
        \\click Save
        \\click button:Nowhere
    , "line 2: no widget \"button:Nowhere\"");
    try testing.expectEqual(error.WidgetNotFound, err.err);
    try testing.expectEqual(error.ExpectationFailed, (try f.playFailing("expect checkbox:Snap = true", "is false, expected true")).err);
    try testing.expectEqual(error.ScriptSyntax, (try f.playFailing("jump Save", "unknown command")).err);
}

test "long typed text arrives whole, accents included" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click text_input:Name
        \\type Zürich, Genève, Málaga and København are all fine
    );
    try testing.expectEqualStrings("Zürich, Genève, Málaga and København are all fine", f.app.name[0..f.app.name_len]);
}

test "a popup on its first, hidden frame is not in the record" {
    const f = try Fixture.create();
    defer f.destroy();
    f.ui.recording = true;
    try f.frame(1.0 / 60.0);
    f.ui.openPopupAt("menu", .{ .x = 10, .y = 10 });
    try f.frame(1.0 / 60.0);
    try testing.expect(f.ui.findWidget("button:Delete") == null);
    try f.frame(1.0 / 60.0);
    try testing.expect(f.ui.findWidget("menu > button:Delete") != null);
}

test "the hovered widget is known without recording" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.frame(1.0 / 60.0);
    try f.frame(1.0 / 60.0);
    try testing.expectEqual(@as(usize, 0), f.ui.widgets().len);
    f.ui.recording = true;
    try f.frame(1.0 / 60.0);
    const snap = f.ui.findWidget("checkbox:Snap").?;
    f.ui.recording = false;
    f.ui.input.onMouseMove(.{ .x = snap.rect.x + 4, .y = snap.rect.y + snap.rect.h / 2 });
    try f.frame(1.0 / 60.0);
    const h = f.ui.hoveredWidget().?;
    try testing.expectEqual(zui.WidgetKind.checkbox, h.kind);
    try testing.expectEqual(f.ui.id("Snap"), h.id);
}

test "the record as JSON and text" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("frames 1");
    var buffer: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try f.ui.writeWidgets(&w, .json);
    const json = w.buffered();
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"checkbox\", \"label\": \"Snap\", \"value\": \"false\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"window\": \"Tools\"") != null);
    w = .fixed(&buffer);
    try f.ui.writeWidgets(&w, .text);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "slider:Volume = 0.20") != null);
}

test "a widget hidden behind a window can't be clicked" {
    const f = try Fixture.create();
    defer f.destroy();
    // The Tools window is in front of where this button will be.
    const Covered = struct {
        fn frame(fx: *Fixture) !void {
            fx.ui.beginFrame(.{ .width = 520, .height = 400 });
            _ = fx.ui.beginWindow("Front", .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 300, .y = 200 } });
            fx.ui.endWindow();
            _ = fx.ui.button("Under", .{});
            _ = try fx.ui.endFrame();
        }
    };
    f.ui.recording = true;
    for (0..3) |_| try Covered.frame(f);
    const under = f.ui.findWidget("button:Under").?;
    try testing.expect(under.layer < f.ui.findWidget("window:Front").?.layer);
    try testing.expect(zui.ScriptPlayer.clickPointOf(&f.ui, under) == null);
}
