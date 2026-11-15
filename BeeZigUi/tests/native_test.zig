//! What native backends rely on: the client-side frame, windows in OS
//! windows of their own (viewports), and drawing into an app's buffer.

const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");
const testing = std.testing;

const App = struct {
    action: zui.FrameAction = .none,
    maximized: bool = false,
    detached: bool = true,
    panel_open: bool = true,
    main_clicks: u32 = 0,
    panel_clicks: u32 = 0,
    picked: usize = 0,

    fn frame(app: *App, ui: *zui.Ui) void {
        const a = ui.clientFrame("Native", .{ .maximized = app.maximized });
        if (a != .none) app.action = a;
        if (ui.button("Main button", .{}).clicked) app.main_clicks += 1;
        if (ui.beginWindow("Panel", .{ .size = .{ .x = 300, .y = 200 }, .detached = app.detached, .open = &app.panel_open })) {
            defer ui.endWindow();
            const b = ui.button("Panel button", .{});
            if (b.clicked) app.panel_clicks += 1;
            ui.tooltip(b, "In the panel");
            _ = ui.dropdown("Mode", &app.picked, &.{ .{ .label = "One" }, .{ .label = "Two" } }, .{});
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
        f.ui.recording = true;
        return f;
    }

    fn destroy(f: *Fixture) void {
        f.ui.deinit();
        f.font.deinit();
        testing.allocator.destroy(f);
    }

    fn frame(f: *Fixture) !void {
        f.ui.beginFrame(.{ .width = 800, .height = 600, .dt = 0.016 });
        f.app.frame(&f.ui);
        _ = try f.ui.endFrame();
    }

    fn clickAt(f: *Fixture, viewport: zui.Id, p: zui.Vec2) !void {
        f.ui.input.viewport = viewport;
        f.ui.input.onMouseMove(p);
        try f.frame();
        f.ui.input.onMouseButton(.left, true);
        try f.frame();
        f.ui.input.onMouseButton(.left, false);
        try f.frame();
    }

    fn center(f: *Fixture, name: []const u8) zui.Vec2 {
        const r = f.ui.findWidget(name).?.rect;
        return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
    }
};

test "the client frame: buttons, move, resize, double click; the UI starts below it" {
    const f = try Fixture.create();
    defer f.destroy();
    f.app.detached = false;
    for (0..3) |_| try f.frame();
    const b = f.ui.findWidget("button:Main button").?.rect;
    try testing.expect(b.y > 30);
    try f.clickAt(.none, f.center("window_button:Close"));
    try testing.expectEqual(zui.FrameAction.close, f.app.action);
    try f.clickAt(.none, f.center("window_button:Maximize"));
    try testing.expectEqual(zui.FrameAction.maximize, f.app.action);
    try f.clickAt(.none, .{ .x = 100, .y = 10 });
    try testing.expectEqual(zui.FrameAction.move, f.app.action);
    try f.clickAt(.none, .{ .x = 799, .y = 599 });
    try testing.expectEqual(zui.FrameAction{ .resize = .{ .bottom = true, .right = true } }, f.app.action);
    try f.clickAt(.none, .{ .x = 400, .y = 1 });
    try testing.expectEqual(zui.FrameAction{ .resize = .{ .top = true } }, f.app.action);
    // Maximized: no edges, and the button restores.
    f.app.maximized = true;
    try f.clickAt(.none, .{ .x = 400, .y = 1 });
    try testing.expectEqual(zui.FrameAction.move, f.app.action);
    try testing.expect(f.ui.findWidget("window_button:Restore") != null);
}

test "a detached window is drawn in its own viewport and takes its own input" {
    const f = try Fixture.create();
    defer f.destroy();
    for (0..3) |_| try f.frame();
    const vps = f.ui.viewports();
    try testing.expectEqual(@as(usize, 1), vps.len);
    const vp = vps[0];
    try testing.expectEqualStrings("Panel", vp.title);
    try testing.expectEqual(@as(f32, 300), vp.size.x);
    try testing.expect(vp.list.commands.items.len > 0);
    // The panel's button sits at its own (0, 0), overlapping the main
    // window's area; the pointer's OS window decides which is clicked.
    const p = f.center("button:Panel button");
    try f.clickAt(vp.id, p);
    try testing.expectEqual(@as(u32, 1), f.app.panel_clicks);
    try testing.expectEqual(@as(u32, 0), f.app.main_clicks);
    try f.clickAt(.none, f.center("button:Main button"));
    try testing.expectEqual(@as(u32, 1), f.app.main_clicks);
    try testing.expectEqual(@as(u32, 1), f.app.panel_clicks);

    // Its title bar asks the system to move it.
    f.ui.input.viewport = vp.id;
    f.ui.input.onMouseMove(.{ .x = 100, .y = 8 });
    try f.frame();
    f.ui.input.onMouseButton(.left, true);
    try f.frame();
    try testing.expectEqual(zui.ViewportRequest.move, f.ui.viewports()[0].request);
    f.ui.input.onMouseButton(.left, false);
    try f.frame();
}

test "popups and tooltips go to the viewport they belong to" {
    const f = try Fixture.create();
    defer f.destroy();
    for (0..3) |_| try f.frame();
    const id = f.ui.viewports()[0].id;
    const main_before = f.ui.output.commands.items.len;
    try f.clickAt(id, f.center("dropdown:Mode"));
    try f.frame();
    // The list opened inside the panel's OS window, not the main one.
    try testing.expect(f.ui.findWidget("choice:Two") != null);
    try testing.expectEqual(main_before, f.ui.output.commands.items.len);
    try f.clickAt(id, f.center("choice:Two"));
    try testing.expectEqual(@as(usize, 1), f.app.picked);
    // A tooltip shows with the pointer in the panel.
    f.ui.input.viewport = id;
    f.ui.input.onMouseMove(f.center("button:Panel button"));
    for (0..4) |_| {
        f.ui.beginFrame(.{ .width = 800, .height = 600, .dt = 0.4 });
        f.app.frame(&f.ui);
        _ = try f.ui.endFrame();
    }
    const panel_cmds = f.ui.viewports()[0].list.commands.items.len;
    try testing.expect(f.ui.overlay.commands.items.len > 0);
    try testing.expectEqual(main_before, f.ui.output.commands.items.len);
    try testing.expect(panel_cmds > 0);
}

test "the system resizes and closes a viewport; reattaching brings it back" {
    const f = try Fixture.create();
    defer f.destroy();
    for (0..3) |_| try f.frame();
    const id = f.ui.viewports()[0].id;
    f.ui.setViewportSize(id, .{ .x = 420, .y = 330 });
    try f.frame();
    try testing.expectEqual(@as(f32, 420), f.ui.viewports()[0].size.x);
    f.app.detached = false;
    try f.frame();
    try testing.expectEqual(@as(usize, 0), f.ui.viewports().len);
    try testing.expect(f.ui.findWidget("button:Panel button") != null);
    f.app.detached = true;
    try f.frame();
    f.ui.closeViewport(id);
    try f.frame();
    try testing.expect(!f.app.panel_open);
    try testing.expectEqual(@as(usize, 0), f.ui.viewports().len);
}

test "embedding: Zui drawn over an app's own framebuffer" {
    // The app owns the pixels (a window buffer) and has drawn into them.
    const w = 200;
    const h = 100;
    var pixels: [w * h]u32 = @splat(0xFF0A3D62);
    var font: zui.Font = try .initDefault(testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(testing.allocator, .{ .font = &font });
    defer ui.deinit();
    var sw: software.SoftwareRenderer = .init(testing.allocator);
    defer sw.deinit();
    sw.useBuffer(&pixels, w, h);
    sw.clear = false;
    ui.beginFrame(.{ .width = w, .height = h });
    _ = ui.button("Over the app", .{});
    const list = try ui.endFrame();
    sw.renderer().render(list, ui.renderFrame(1));
    // The corner far from the button keeps the app's colour; the button
    // replaced some pixels.
    try testing.expectEqual(@as(u32, 0xFF0A3D62), pixels[w * h - 1]);
    var changed: usize = 0;
    for (pixels) |p| changed += @intFromBool(p != 0xFF0A3D62);
    try testing.expect(changed > 100);
}

test "Tab stays in the OS window that has the keyboard" {
    const f = try Fixture.create();
    defer f.destroy();
    for (0..3) |_| try f.frame();
    const id = f.ui.viewports()[0].id;
    f.ui.input.keyboard_viewport = id;
    f.ui.input.onKeyPress(.tab);
    try f.frame();
    try f.frame();
    try testing.expect(f.ui.findWidget("button:Panel button").?.focused);
    // Enter presses it there.
    f.ui.input.onKeyPress(.enter);
    try f.frame();
    try testing.expectEqual(@as(u32, 1), f.app.panel_clicks);
    // Back to the main window: the panel's focus doesn't follow.
    f.ui.input.keyboard_viewport = .none;
    try f.frame();
    try testing.expect(!f.ui.findWidget("button:Panel button").?.focused);
}
