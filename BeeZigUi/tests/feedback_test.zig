//! Dialogs, the status bar, toasts, progress and cards.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const App = struct {
    asking: bool = false,
    answer: ?usize = null,
    behind: u32 = 0,
    name: [32]u8 = undefined,
    name_len: usize = 0,
    toast_id: u32 = 0,
    toast_clicked: bool = false,
    under_toast: u32 = 0,
    opened: ?[]const u8 = null,
    progress: ?f32 = 0.3,

    fn frame(app: *App, ui: *zui.Ui) void {
        if (ui.clickedToast()) |id| {
            if (id == app.toast_id) app.toast_clicked = true;
        }
        if (ui.button("Behind", .{}).clicked) app.behind += 1;
        if (ui.button("Ask", .{}).clicked) app.asking = true;
        if (ui.card("Character", .{ .icon = .{ .builtin = .dot }, .subtitle = "A rigged figure" }).clicked) app.opened = "Character";
        _ = ui.card("Terrain", .{ .icon = .{ .builtin = .warning }, .disabled = "Needs phase 11" });
        ui.progressBar(app.progress, .{});
        ui.spacer(.fill);
        if (ui.button("Under the toast", .{ .width = .fill }).clicked) app.under_toast += 1;
        ui.beginStatusBar();
        ui.keyHint("G", "Move");
        ui.keyHint("Shift Click", "Add to selection");
        ui.spacer(.fill);
        _ = ui.jobChip("Rendering", 0.5, 4, .{ .action = "Stop" });
        ui.endStatusBar();

        if (ui.beginDialog("Save changes?", &app.asking, .{})) {
            defer ui.endDialog();
            ui.label("The scene has changes that aren't saved.", .{});
            _ = ui.textInput("File name", &app.name, &app.name_len, .{});
            if (ui.dialogButtons(&.{ "Save", "Don't Save", "Cancel" }, .{ .default = 0, .cancel = 2 })) |i| {
                app.answer = i;
                app.asking = false;
            }
        }
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
        return f;
    }

    fn destroy(f: *Fixture) void {
        f.ui.deinit();
        f.font.deinit();
        testing.allocator.destroy(f);
    }

    fn frame(f: *Fixture, dt: f32) !void {
        f.ui.beginFrame(.{ .width = 800, .height = 560, .dt = dt });
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

test "a dialog blocks what is behind it; its buttons answer" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click button:Ask
        \\expect Save changes? > button:Save exists
        \\click button:Behind
        \\click Save changes? > button:Don't Save
        \\expect dialog:Save changes? missing
    );
    try testing.expectEqual(@as(u32, 0), f.app.behind);
    try testing.expectEqual(@as(?usize, 1), f.app.answer);
}

test "Enter is the default button, Escape the cancel one" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click button:Ask
        \\expect button:Save focused
        \\key enter
        \\expect dialog:Save changes? missing
    );
    try testing.expectEqual(@as(?usize, 0), f.app.answer);
    try f.play(
        \\click button:Ask
        \\key escape
        \\expect dialog:Save changes? missing
    );
    try testing.expectEqual(@as(?usize, 2), f.app.answer);
}

test "Tab stays inside the dialog; Enter on a focused button presses it" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click button:Ask
        \\key tab
        \\expect button:Don't Save focused
        \\key tab
        \\key tab
        \\expect text_input:File name focused
        \\key tab
        \\expect button:Save focused
        \\key tab
        \\key enter
    );
    try testing.expectEqual(@as(?usize, 1), f.app.answer);
}

test "typing in a dialog field, then Escape undoes the edit before closing" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click button:Ask
        \\click text_input:File name
        \\type chair
        \\key escape
        \\expect dialog:Save changes? exists
        \\expect text_input:File name =
        \\key escape
        \\expect dialog:Save changes? missing
    );
}

test "toasts expire, and a click on one doesn't reach what is under it" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("frames 2");
    f.app.toast_id = f.ui.toast("Saved chair.bee", .success, .{ .seconds = 1 });
    try f.play(
        \\expect toast:Saved chair.bee exists
        \\click toast:Saved chair.bee
    );
    try testing.expect(f.app.toast_clicked);
    try testing.expectEqual(@as(u32, 0), f.app.under_toast);
    try f.play(
        \\wait 1.2
        \\expect toast:Saved chair.bee missing
    );
    // An idle UI sleeps until the toast is due to go.
    _ = f.ui.toast("Short", .warning, .{ .seconds = 0.5 });
    try f.frame(0.016);
    try testing.expect(f.ui.redraw_in.? <= 0.5);
}

test "status bar hints, job chip, progress and cards" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\expect key_hint:Move = G
        \\expect key_hint:Add to selection = Shift Click
        \\expect job:Rendering = Rendering 50%, 4 s, about 4 s left   Stop
        \\expect progress:progress = 30%
        \\expect card:Terrain disabled
        \\click card:Character
    );
    try testing.expectEqualStrings("Character", f.app.opened.?);
    // Unknown progress glides and asks for frames while shown.
    f.app.progress = null;
    try f.frame(0.016);
    try testing.expect(f.ui.redraw_in != null);
}

test "what follows a spacer in a filling row comes back into view" {
    var font: zui.Font = try .initDefault(testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(testing.allocator, .{ .font = &font });
    defer ui.deinit();
    ui.recording = true;
    var last: zui.Rect = .{};
    for (0..6) |i| {
        ui.beginFrame(.{ .width = 800, .height = 300 });
        ui.spacer(.fill);
        ui.beginStatusBar();
        ui.keyHint("G", "Move");
        ui.spacer(.fill);
        if (i >= 2) _ = ui.button("Rendering", .{});
        ui.endStatusBar();
        _ = try ui.endFrame();
        if (ui.findWidget("button:Rendering")) |w| last = w.rect;
    }
    // Whole, and against the right edge (800 minus the paddings).
    try testing.expect(last.w > 60);
    try testing.expectApproxEqAbs(@as(f32, 800 - 16 - 3), last.right(), 1);
}

test "a dialog shown in a Ui's first frame: Enter, pressed and released in one frame, is the default button" {
    const f = try Fixture.create();
    defer f.destroy();
    f.app.asking = true;
    for (0..3) |_| try f.frame(0.016);
    f.ui.input.onKeyPress(.enter);
    f.ui.input.onKeyRelease(.enter);
    try f.frame(0.016);
    try testing.expectEqual(@as(?usize, 0), f.app.answer);
}

test "Enter that ends typing in a dialog's field is the field's, not the default button's" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click button:Ask
        \\click Save changes? > text_input:File name
        \\type scene
        \\key enter
        \\expect Save changes? > button:Save exists
    );
    try testing.expectEqual(@as(?usize, null), f.app.answer);
    try testing.expectEqualStrings("scene", f.app.name[0..f.app.name_len]);
    // The next Enter, with no field typed in, is the default button's.
    try f.play(
        \\key enter
        \\expect dialog:Save changes? missing
    );
    try testing.expectEqual(@as(?usize, 0), f.app.answer);
}

test "toasts at the right edge" {
    const f = try Fixture.create();
    defer f.destroy();
    f.ui.toast_align = .right;
    f.ui.toast_margin = 30;
    try f.play("frames 1");
    _ = f.ui.toast("Saved", .success, .{});
    try f.play("expect toast:Saved exists");
    const t = f.ui.findWidget("toast:Saved") orelse return error.NoToast;
    try testing.expectApproxEqAbs(@as(f32, 800 - 12), t.rect.right(), 1);
    try testing.expectApproxEqAbs(@as(f32, 560 - 30), t.rect.bottom(), 1);
}

test "a toast made between two frames lasts its seconds from when it shows" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("frames 1");
    _ = f.ui.toast("Kept", .info, .{ .seconds = 1 });
    // (the next frame comes long after the last one: an idle app)
    try f.frame(3);
    try testing.expect(f.ui.findWidget("toast:Kept") != null);
    try f.frame(0.6);
    try testing.expect(f.ui.findWidget("toast:Kept") != null);
    try f.frame(0.6);
    try testing.expect(f.ui.findWidget("toast:Kept") == null);
}
