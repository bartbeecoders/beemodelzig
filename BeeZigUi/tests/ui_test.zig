//! Drives `Ui` with simulated input, with no window or renderer involved.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const Fixture = struct {
    font: zui.Font,
    ui: zui.Ui,

    fn create(allocator: std.mem.Allocator) !*Fixture {
        const f = try allocator.create(Fixture);
        f.font = try .initDefault(allocator);
        f.ui = .init(allocator, .{ .font = &f.font });
        return f;
    }

    fn destroy(f: *Fixture, allocator: std.mem.Allocator) void {
        f.ui.deinit();
        f.font.deinit();
        allocator.destroy(f);
    }

    /// One frame with a single button. Returns its interaction.
    fn buttonFrame(f: *Fixture) !zui.Interaction {
        f.ui.beginFrame(.{ .width = 400, .height = 300 });
        const result = f.ui.button("OK", .{});
        _ = try f.ui.endFrame();
        return result;
    }
};

const on_button: zui.Vec2 = .{ .x = 25, .y = 25 };
const off_button: zui.Vec2 = .{ .x = 300, .y = 200 };

test "hovering reports hovered, not clicked" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.input.onMouseMove(on_button);
    const r = try f.buttonFrame();
    try testing.expect(r.hovered and !r.clicked and !r.held);
}

test "press then release on the button clicks once" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.input.onMouseMove(on_button);
    _ = try f.buttonFrame();

    f.ui.input.onMouseButton(.left, true);
    const pressed = try f.buttonFrame();
    try testing.expect(pressed.held and !pressed.clicked);

    f.ui.input.onMouseButton(.left, false);
    const released = try f.buttonFrame();
    try testing.expect(released.clicked and !released.held);

    try testing.expect(!(try f.buttonFrame()).clicked);
}

test "a click inside a single frame still counts" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.input.onMouseMove(on_button);
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try testing.expect((try f.buttonFrame()).clicked);
    try testing.expectEqual(zui.Id.none, f.ui.active);
}

test "dragging off keeps the capture and cancels the click" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.input.onMouseMove(on_button);
    f.ui.input.onMouseButton(.left, true);
    _ = try f.buttonFrame();

    f.ui.input.onMouseMove(off_button);
    const dragged = try f.buttonFrame();
    try testing.expect(dragged.held and !dragged.hovered);

    f.ui.input.onMouseButton(.left, false);
    try testing.expect(!(try f.buttonFrame()).clicked);
}

test "a press on empty space doesn't light up buttons it crosses" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.input.onMouseMove(off_button);
    f.ui.input.onMouseButton(.left, true);
    _ = try f.buttonFrame();

    f.ui.input.onMouseMove(on_button);
    try testing.expect(!(try f.buttonFrame()).hovered);

    f.ui.input.onMouseButton(.left, false);
    const released = try f.buttonFrame();
    try testing.expect(!released.clicked);
    try testing.expect((try f.buttonFrame()).hovered);
}

test "a held widget that disappears releases the mouse" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.input.onMouseMove(on_button);
    f.ui.input.onMouseButton(.left, true);
    _ = try f.buttonFrame();
    try testing.expect(f.ui.active != .none);

    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    _ = try f.ui.endFrame();
    try testing.expectEqual(zui.Id.none, f.ui.active);
}

test "ids depend on the id stack and the hidden suffix" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    try testing.expect(ui.id("Save##a") != ui.id("Save##b"));
    const plain = ui.id("Save");
    ui.pushIdInt(1);
    const first = ui.id("Save");
    ui.popId();
    ui.pushIdInt(2);
    const second = ui.id("Save");
    ui.popId();
    try testing.expect(plain != first and first != second);
    try testing.expectEqual(plain, ui.id("Save"));
    try testing.expectEqualStrings("Save", zui.Ui.visibleLabel("Save##a"));
}

test "same-label buttons in a loop act independently" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;

    var second_x: f32 = 0;
    for (0..3) |frame| {
        if (frame == 1) {
            ui.input.onMouseMove(.{ .x = second_x + 5, .y = 25 });
            ui.input.onMouseButton(.left, true);
        }
        if (frame == 2) ui.input.onMouseButton(.left, false);

        ui.beginFrame(.{ .width = 400, .height = 300 });
        var clicked: ?usize = null;
        for (0..3) |i| {
            ui.pushIdInt(i);
            defer ui.popId();
            if (i > 0) ui.sameLine();
            const r = ui.button("Pick", .{});
            if (i == 1) second_x = r.rect.x;
            if (r.clicked) clicked = i;
        }
        _ = try ui.endFrame();
        if (frame == 2) try testing.expectEqual(@as(?usize, 1), clicked);
    }
}

test "a stable frame does not allocate" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const allocator = failing.allocator();
    const f = try Fixture.create(allocator);
    defer f.destroy(allocator);

    const frame = struct {
        fn run(ui: *zui.Ui) !void {
            ui.beginFrame(.{ .width = 400, .height = 300 });
            for (0..20) |i| {
                ui.pushIdInt(i);
                defer ui.popId();
                ui.labelf("Row {d}", .{i}, .{});
                _ = ui.button("Press", .{});
            }
            _ = try ui.endFrame();
        }
    }.run;

    for (0..3) |_| try frame(&f.ui);
    const settled = failing.allocations;
    for (0..50) |_| try frame(&f.ui);
    try testing.expectEqual(settled, failing.allocations);
}

test "an allocation failure surfaces from endFrame and the next frame recovers" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    f.ui.draw_list.allocator = failing.allocator();

    try testing.expectError(error.OutOfMemory, f.buttonFrame());

    f.ui.draw_list.deinit();
    f.ui.draw_list = .init(testing.allocator);
    _ = try f.buttonFrame();
}

test "widgets far outside the viewport are harmless" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.input.onMouseMove(.{ .x = 25, .y = 2025 });
    f.ui.beginFrame(.{ .width = 100, .height = 50 });
    for (0..100) |i| {
        f.ui.pushIdInt(i);
        defer f.ui.popId();
        _ = f.ui.button("Far", .{});
    }
    _ = try f.ui.endFrame();
}

test "a grow button fills its row after the layout settles" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;

    var rect: zui.Rect = .{};
    var redraw = true;
    var frames: u32 = 0;
    while (redraw) : (frames += 1) {
        try testing.expect(frames < 5);
        ui.beginFrame(.{ .width = 400, .height = 300 });
        ui.beginHorizontal(.{});
        _ = ui.button("Fixed", .{ .width = .px(100) });
        rect = ui.button("Grow", .{ .width = .fill }).rect;
        ui.endHorizontal();
        _ = try ui.endFrame();
        redraw = ui.redraw_requested;
    }
    const padding = ui.style.window_padding;
    try testing.expectApproxEqAbs(400 - padding, rect.right(), 0.01);
}

test "a stable frame with groups asks for no more frames" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    for (0..6) |_| {
        ui.beginFrame(.{ .width = 400, .height = 300 });
        ui.beginHorizontal(.{ .padding = 4 });
        ui.spacer(.fill);
        ui.beginVertical(.{ .padding = 4 });
        ui.label("Nested", .{});
        ui.endVertical();
        ui.endHorizontal();
        _ = try ui.endFrame();
    }
    try testing.expect(!ui.redraw_requested);
}

test "groups don't allocate once stable" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const allocator = failing.allocator();
    const f = try Fixture.create(allocator);
    defer f.destroy(allocator);
    const ui = &f.ui;
    const frame = struct {
        fn run(u: *zui.Ui) !void {
            u.beginFrame(.{ .width = 400, .height = 300 });
            for (0..10) |i| {
                u.pushIdInt(i);
                defer u.popId();
                u.beginHorizontal(.{ .id = "row" });
                u.label("Item", .{});
                u.spacer(.fill);
                _ = u.button("Open", .{});
                u.endHorizontal();
            }
            _ = try u.endFrame();
        }
    }.run;
    for (0..3) |_| try frame(ui);
    const settled = failing.allocations;
    for (0..20) |_| try frame(ui);
    try testing.expectEqual(settled, failing.allocations);
}

/// A scene with a button at the top level and a window covering it.
const WindowScene = struct {
    behind: zui.Interaction = .{},
    inside: zui.Interaction = .{},
    window_open: bool = true,
    window_visible: bool = false,
    rows: usize = 0,

    fn run(scene: *WindowScene, ui: *zui.Ui) !void {
        ui.beginFrame(.{ .width = 600, .height = 400 });
        scene.behind = ui.button("Behind", .{ .width = .px(300), .height = .px(200) });
        scene.window_visible = ui.beginWindow("Win", .{
            .position = .{ .x = 100, .y = 50 },
            .size = .{ .x = 200, .y = 150 },
            .open = &scene.window_open,
        });
        if (scene.window_visible) {
            defer ui.endWindow();
            scene.inside = ui.button("Inside", .{});
            for (0..scene.rows) |i| ui.labelf("Row {d}", .{i}, .{});
        }
        _ = try ui.endFrame();
    }
};

fn click(ui: *zui.Ui, scene: *WindowScene, at: zui.Vec2) !void {
    ui.input.onMouseMove(at);
    try scene.run(ui);
    ui.input.onMouseButton(.left, true);
    try scene.run(ui);
    ui.input.onMouseButton(.left, false);
    try scene.run(ui);
}

test "a window blocks clicks to what is behind it" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var scene: WindowScene = .{};
    try scene.run(&f.ui);

    // Inside the window but not on its button: the root button must not react.
    f.ui.input.onMouseMove(.{ .x = 250, .y = 180 });
    try scene.run(&f.ui);
    try testing.expect(!scene.behind.hovered);

    // Outside the window, the root button works.
    f.ui.input.onMouseMove(.{ .x = 50, .y = 180 });
    try scene.run(&f.ui);
    try testing.expect(scene.behind.hovered);
}

test "window buttons work and windows draw after the top level" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var scene: WindowScene = .{};
    try scene.run(&f.ui);
    const at = scene.inside.rect;
    f.ui.input.onMouseMove(.{ .x = at.x + 4, .y = at.y + 4 });
    try scene.run(&f.ui);
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try scene.run(&f.ui);
    try testing.expect(scene.inside.clicked);
}

test "dragging the title moves the window and keeps it reachable" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var scene: WindowScene = .{};
    try scene.run(ui);

    ui.input.onMouseMove(.{ .x = 150, .y = 60 });
    try scene.run(ui);
    ui.input.onMouseButton(.left, true);
    try scene.run(ui);
    ui.input.onMouseMove(.{ .x = 200, .y = 100 });
    try scene.run(ui);
    const w = ui.windows.get(ui.id("Win")).?;
    try testing.expectEqual(@as(f32, 150), w.rect.x);
    try testing.expectEqual(@as(f32, 90), w.rect.y);

    // Throw it far off-screen: the title bar must stay grabbable.
    ui.input.onMouseMove(.{ .x = 5000, .y = -5000 });
    try scene.run(ui);
    ui.input.onMouseButton(.left, false);
    try scene.run(ui);
    try testing.expect(w.rect.x <= 600 - 48 and w.rect.y >= 0);
}

test "collapse hides the content and close hides the window" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var scene: WindowScene = .{};
    try scene.run(ui);
    const title_h = ui.windows.get(ui.id("Win")).?.title_height;

    try click(ui, &scene, .{ .x = 100 + title_h / 2, .y = 50 + title_h / 2 }); // collapse arrow
    try testing.expect(!scene.window_visible and scene.window_open);
    try click(ui, &scene, .{ .x = 100 + title_h / 2, .y = 50 + title_h / 2 });
    try testing.expect(scene.window_visible);

    try click(ui, &scene, .{ .x = 300 - title_h / 2, .y = 50 + title_h / 2 }); // close
    try testing.expect(!scene.window_open and !scene.window_visible);
    // Closed windows no longer block the mouse.
    ui.input.onMouseMove(.{ .x = 250, .y = 180 });
    try scene.run(ui);
    try scene.run(ui);
    try testing.expect(scene.behind.hovered);
}

test "clicking a lower window raises it" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    const two = struct {
        fn run(u: *zui.Ui) !void {
            u.beginFrame(.{ .width = 600, .height = 400 });
            if (u.beginWindow("A", .{ .position = .{ .x = 0, .y = 0 } })) u.endWindow();
            if (u.beginWindow("B", .{ .position = .{ .x = 100, .y = 100 } })) u.endWindow();
            _ = try u.endFrame();
        }
    }.run;
    try two(ui);
    const a = ui.windows.get(ui.id("A")).?;
    try testing.expect(ui.window_order.items[1] != a);
    ui.input.onMouseMove(.{ .x = 50, .y = 150 }); // only A is here
    try two(ui);
    ui.input.onMouseButton(.left, true);
    try two(ui);
    try testing.expectEqual(a, ui.window_order.items[1]);
}

test "the mouse wheel scrolls overflowing content" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var scene: WindowScene = .{ .rows = 40 };
    try scene.run(ui);
    const before = scene.inside.rect.y;
    ui.input.onMouseMove(.{ .x = 200, .y = 150 });
    try scene.run(ui);
    ui.input.onScroll(.{ .y = -2 });
    try scene.run(ui);
    try scene.run(ui);
    try testing.expect(scene.inside.rect.y < before - 50);
    // The top-level button doesn't see the wheel or the hover.
    try testing.expect(!scene.behind.hovered);
}

test "windows don't allocate once stable" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const allocator = failing.allocator();
    const f = try Fixture.create(allocator);
    defer f.destroy(allocator);
    var scene: WindowScene = .{ .rows = 30 };
    for (0..3) |_| try scene.run(&f.ui);
    const settled = failing.allocations;
    for (0..20) |_| try scene.run(&f.ui);
    try testing.expectEqual(settled, failing.allocations);
}

test "a drag whose press and first motion share a frame still moves the window" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var scene: WindowScene = .{};
    ui.input.onMouseMove(.{ .x = 500, .y = 350 });
    try scene.run(ui);
    try scene.run(ui);

    // What SDL delivered in the failing live run: the press lands on the
    // title bar, but by the time the frame runs the mouse is below it.
    ui.input.onMouseMove(.{ .x = 150, .y = 60 });
    ui.input.onMouseButton(.left, true);
    ui.input.onMouseMove(.{ .x = 160, .y = 95 });
    try scene.run(ui);
    ui.input.onMouseMove(.{ .x = 200, .y = 120 });
    try scene.run(ui);
    const w = ui.windows.get(ui.id("Win")).?;
    try testing.expectEqual(@as(f32, 150), w.rect.x);
    try testing.expectEqual(@as(f32, 110), w.rect.y);
}

test "checkbox toggles on click, including on its label" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var value = false;
    var r: zui.Interaction = .{};
    const frame = struct {
        fn run(u: *zui.Ui, v: *bool) !zui.Interaction {
            u.beginFrame(.{ .width = 400, .height = 300 });
            const result = u.checkbox("Enabled", v, .{});
            _ = try u.endFrame();
            return result;
        }
    }.run;
    r = try frame(ui, &value);
    ui.input.onMouseMove(.{ .x = r.rect.right() - 3, .y = r.rect.y + 5 }); // on the label
    ui.input.onMouseButton(.left, true);
    ui.input.onMouseButton(.left, false);
    r = try frame(ui, &value);
    try testing.expect(value and r.changed);
    ui.input.onMouseButton(.left, true);
    ui.input.onMouseButton(.left, false);
    r = try frame(ui, &value);
    try testing.expect(!value and r.changed);
    r = try frame(ui, &value);
    try testing.expect(!r.changed);
}

fn SliderScene(comptime T: type) type {
    return struct {
        value: T,
        result: zui.Interaction = .{},

        fn run(self: *@This(), ui: *zui.Ui, min: T, max: T) !void {
            ui.beginFrame(.{ .width = 400, .height = 300 });
            self.result = ui.slider("Value", &self.value, min, max, .{});
            _ = try ui.endFrame();
        }
    };
}

test "slider follows a drag and clamps outside the track" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var scene: SliderScene(f32) = .{ .value = 0.5 };
    try scene.run(ui, 0, 1);
    const track = scene.result.rect;

    ui.input.onMouseMove(.{ .x = track.x + 10, .y = track.y + 5 });
    ui.input.onMouseButton(.left, true);
    try scene.run(ui, 0, 1);
    try testing.expect(scene.result.changed);
    try testing.expect(scene.value < 0.05);

    // Far past the right end, and off the widget vertically: still captured.
    ui.input.onMouseMove(.{ .x = 2000, .y = 250 });
    try scene.run(ui, 0, 1);
    try testing.expectEqual(@as(f32, 1), scene.value);

    ui.input.onMouseButton(.left, false);
    try scene.run(ui, 0, 1);
    ui.input.onMouseMove(.{ .x = track.x, .y = track.y + 5 });
    try scene.run(ui, 0, 1);
    try testing.expectEqual(@as(f32, 1), scene.value); // released: no longer tracking
}

test "integer slider produces whole values within range" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var scene: SliderScene(i32) = .{ .value = 0 };
    try scene.run(ui, -10, 10);
    const track = scene.result.rect;
    ui.input.onMouseMove(.{ .x = track.x + 70, .y = track.y + 5 });
    ui.input.onMouseButton(.left, true);
    try scene.run(ui, -10, 10);
    try testing.expect(scene.value >= -10 and scene.value <= 10);
    try testing.expect(scene.result.changed);
}

const TextScene = struct {
    buffer: [32]u8 = undefined,
    len: usize = 0,
    result: zui.Interaction = .{},
    other: zui.Interaction = .{},
    select_on_click: bool = false,

    fn init(initial: []const u8) TextScene {
        var s: TextScene = .{};
        @memcpy(s.buffer[0..initial.len], initial);
        s.len = initial.len;
        return s;
    }

    fn text(s: *const TextScene) []const u8 {
        return s.buffer[0..s.len];
    }

    fn run(s: *TextScene, ui: *zui.Ui) !void {
        ui.beginFrame(.{ .width = 400, .height = 300 });
        s.result = ui.textInput("Field", &s.buffer, &s.len, .{ .select_on_click = s.select_on_click });
        s.other = ui.button("Elsewhere", .{});
        _ = try ui.endFrame();
    }

    /// Clicks into the field at `x` units from its left edge.
    fn click(s: *TextScene, ui: *zui.Ui, x: f32) !void {
        const r = s.result.rect;
        ui.input.onMouseMove(.{ .x = r.x + x, .y = r.y + r.h / 2 });
        ui.input.onMouseButton(.left, true);
        ui.input.onMouseButton(.left, false);
        try s.run(ui);
    }

    /// Clicks into the field and puts the caret at the end.
    fn focus(s: *TextScene, ui: *zui.Ui) !void {
        try s.run(ui);
        try s.click(ui, 5);
        try s.key(ui, .end, .{});
    }

    fn key(s: *TextScene, ui: *zui.Ui, k: zui.Key, mods: zui.Modifiers) !void {
        ui.input.modifiers = mods;
        ui.input.onKeyPress(k);
        ui.input.modifiers = .{};
        try s.run(ui);
    }

    fn typeText(s: *TextScene, ui: *zui.Ui, t: []const u8) !void {
        ui.input.onText(t);
        try s.run(ui);
    }
};

const ctrl: zui.Modifiers = .{ .ctrl = true };
const shift: zui.Modifiers = .{ .shift = true };

test "select_on_click: the first click selects all, typing replaces it" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s = TextScene.init("none");
    s.select_on_click = true;
    try s.run(&f.ui);
    try s.click(&f.ui, 12);
    try s.typeText(&f.ui, "Props");
    try testing.expectEqualStrings("Props", s.text());
    // A click into the focused field places the caret, as without the option.
    try s.click(&f.ui, 2);
    try s.typeText(&f.ui, "x");
    try testing.expectEqualStrings("xProps", s.text());
}

test "clicking a text input focuses it and typing inserts" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("");
    try s.run(&f.ui);
    try testing.expect(!s.result.focused);
    try s.typeText(&f.ui, "ignored");
    try testing.expectEqualStrings("", s.text());

    try s.focus(&f.ui);
    try testing.expect(s.result.focused and f.ui.wantsKeyboard());
    try s.typeText(&f.ui, "héllo");
    try testing.expect(s.result.changed);
    try testing.expectEqualStrings("héllo", s.text());
    try s.run(&f.ui);
    try testing.expect(!s.result.changed);
}

test "typing and keys in one frame apply in order" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("");
    try s.focus(&f.ui);
    f.ui.input.onText("ab");
    f.ui.input.onKeyPress(.backspace);
    f.ui.input.onText("c");
    f.ui.input.onKeyPress(.home);
    f.ui.input.onText(">");
    try s.run(&f.ui);
    try testing.expectEqualStrings(">ac", s.text());
}

test "editing respects codepoint boundaries" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("aé€b");
    try s.focus(&f.ui);
    try s.key(&f.ui, .left, .{});
    try s.key(&f.ui, .backspace, .{});
    try testing.expectEqualStrings("aéb", s.text());
    try s.key(&f.ui, .left, .{});
    try s.key(&f.ui, .delete, .{});
    try testing.expectEqualStrings("ab", s.text());
}

test "a full buffer cuts typing at a codepoint boundary" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("xxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
    try s.focus(&f.ui);
    try s.typeText(&f.ui, "éé");
    try testing.expectEqual(@as(usize, 31), s.len);
    try testing.expectEqualStrings("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxé", s.text());
}

test "selection with shift, select all, and typing over it" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("hello world");
    try s.focus(&f.ui);
    try s.key(&f.ui, .left, .{ .shift = true, .ctrl = true });
    try s.typeText(&f.ui, "there");
    try testing.expectEqualStrings("hello there", s.text());
    try s.key(&f.ui, .a, ctrl);
    try s.typeText(&f.ui, "x");
    try testing.expectEqualStrings("x", s.text());
}

test "word jump and word delete" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("one two three");
    try s.focus(&f.ui);
    try s.key(&f.ui, .backspace, ctrl);
    try testing.expectEqualStrings("one two ", s.text());
    try s.key(&f.ui, .home, .{});
    try s.key(&f.ui, .right, ctrl);
    try s.key(&f.ui, .delete, ctrl);
    try testing.expectEqualStrings("one ", s.text());
}

test "copy, cut and paste through the built-in clipboard" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("abc");
    try s.focus(&f.ui);
    try s.key(&f.ui, .a, ctrl);
    try s.key(&f.ui, .c, ctrl);
    try s.key(&f.ui, .end, .{});
    try s.key(&f.ui, .v, ctrl);
    try testing.expectEqualStrings("abcabc", s.text());
    try s.key(&f.ui, .home, shift);
    try s.key(&f.ui, .x, ctrl);
    try testing.expectEqualStrings("", s.text());
    try testing.expectEqualStrings("abcabc", f.ui.getClipboard());
}

test "paste goes through the clipboard hook and is made single-line" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const Fake = struct {
        stored: []const u8 = "line one\r\nline two",
        fn get(ctx: *anyopaque) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.stored;
        }
        fn set(ctx: *anyopaque, t: []const u8) void {
            _ = ctx;
            _ = t;
        }
    };
    var fake: Fake = .{};
    f.ui.clipboard = .{ .context = &fake, .getFn = Fake.get, .setFn = Fake.set };
    var s: TextScene = .init("");
    try s.focus(&f.ui);
    try s.key(&f.ui, .v, ctrl);
    try testing.expectEqualStrings("line one line two", s.text());
}

test "undo groups typing by word and redo restores it" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("");
    try s.focus(&f.ui);
    for ("hello world") |c| try s.typeText(&f.ui, &.{c});
    try s.key(&f.ui, .z, ctrl);
    try testing.expectEqualStrings("hello", s.text());
    try s.key(&f.ui, .z, ctrl);
    try testing.expectEqualStrings("", s.text());
    try s.key(&f.ui, .z, ctrl); // nothing left: no change
    try testing.expectEqualStrings("", s.text());
    try s.key(&f.ui, .z, .{ .ctrl = true, .shift = true });
    try testing.expectEqualStrings("hello", s.text());
    try s.key(&f.ui, .y, ctrl);
    try testing.expectEqualStrings("hello world", s.text());
    try s.typeText(&f.ui, "!");
    try s.key(&f.ui, .y, ctrl); // a new edit clears redo
    try testing.expectEqualStrings("hello world!", s.text());
}

test "enter submits and ends editing, escape and clicks elsewhere end it too" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("x");
    try s.focus(&f.ui);
    try s.key(&f.ui, .enter, .{});
    try testing.expect(s.result.submitted and !s.result.focused);
    try s.run(&f.ui);
    try testing.expect(!s.result.submitted and !f.ui.wantsKeyboard());

    try s.focus(&f.ui);
    try s.key(&f.ui, .escape, .{});
    try testing.expect(!s.result.focused);

    try s.focus(&f.ui);
    const b = s.other.rect;
    f.ui.input.onMouseMove(.{ .x = b.x + 5, .y = b.y + 5 });
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try s.run(&f.ui);
    try testing.expect(!s.result.focused and s.other.clicked);
}

test "a focused input that stops being described loses focus" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("");
    try s.focus(&f.ui);
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    _ = try f.ui.endFrame();
    try testing.expect(!f.ui.wantsKeyboard());
}

test "dragging selects, double click selects a word, triple click all" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("alpha beta");
    try s.run(&f.ui);
    const r = s.result.rect;
    const y = r.y + r.h / 2;

    f.ui.input.onMouseMove(.{ .x = r.x + 2, .y = y });
    f.ui.input.onMouseButton(.left, true);
    try s.run(&f.ui);
    f.ui.input.onMouseMove(.{ .x = r.x + 1000, .y = y + 100 }); // far outside: still captured
    try s.run(&f.ui);
    f.ui.input.onMouseButton(.left, false);
    try s.run(&f.ui);
    try testing.expectEqual([2]usize{ 0, 10 }, f.ui.text_edit.selection());

    // A double click on "beta", which starts well right of "alpha ".
    const beta_x = r.x + 8 + f.ui.textSize("alpha b").x;
    f.ui.input.onMouseMove(.{ .x = beta_x, .y = y });
    f.ui.input.onMouseButtonClicks(.left, true, 2);
    f.ui.input.onMouseButton(.left, false);
    try s.run(&f.ui);
    try testing.expectEqual([2]usize{ 6, 10 }, f.ui.text_edit.selection());

    f.ui.input.onMouseButtonClicks(.left, true, 3);
    f.ui.input.onMouseButton(.left, false);
    try s.run(&f.ui);
    try testing.expectEqual([2]usize{ 0, 10 }, f.ui.text_edit.selection());
}

test "the caret blink schedules a wake-up only while focused" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("");
    try s.run(&f.ui);
    try testing.expectEqual(@as(?f32, null), f.ui.redraw_in);
    try s.focus(&f.ui);
    const wait = f.ui.redraw_in orelse return error.NoWakeUp;
    try testing.expect(wait > 0 and wait <= 0.5);
}

test "a focused text input doesn't allocate once stable" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const allocator = failing.allocator();
    const f = try Fixture.create(allocator);
    defer f.destroy(allocator);
    var s: TextScene = .init("some text");
    try s.focus(&f.ui);
    for (0..3) |_| try s.run(&f.ui);
    const settled = failing.allocations;
    for (0..50) |_| try s.run(&f.ui);
    try testing.expectEqual(settled, failing.allocations);
}

test "long text scrolls to keep the caret in view" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TextScene = .init("");
    try s.focus(&f.ui);
    try s.typeText(&f.ui, "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWW");
    const scrolled = f.ui.text_edit.scroll;
    try testing.expect(scrolled > 0);
    try s.key(&f.ui, .home, .{});
    try testing.expectEqual(@as(f32, 0), f.ui.text_edit.scroll);
}

/// One of each focusable widget, in this order: text, checkbox, slider, button.
const NavScene = struct {
    buffer: [32]u8 = undefined,
    len: usize = 0,
    checked: bool = false,
    level: i32 = 50,
    text: zui.Interaction = .{},
    check: zui.Interaction = .{},
    slide: zui.Interaction = .{},
    press: zui.Interaction = .{},

    fn run(s: *NavScene, ui: *zui.Ui) !void {
        ui.beginFrame(.{ .width = 400, .height = 300 });
        s.text = ui.textInput("Text", &s.buffer, &s.len, .{});
        s.check = ui.checkbox("Check", &s.checked, .{});
        s.slide = ui.slider("Level", &s.level, 0, 100, .{});
        s.press = ui.button("Press", .{});
        _ = try ui.endFrame();
    }

    fn key(s: *NavScene, ui: *zui.Ui, k: zui.Key, mods: zui.Modifiers) !void {
        ui.input.modifiers = mods;
        ui.input.onKeyPress(k);
        ui.input.modifiers = .{};
        try s.run(ui);
        // Let a focus change that wrapped around reach its widget.
        if (ui.redraw_requested) try s.run(ui);
    }

    fn focusedName(s: *const NavScene) []const u8 {
        if (s.text.focused) return "text";
        if (s.check.focused) return "check";
        if (s.slide.focused) return "slide";
        if (s.press.focused) return "press";
        return "none";
    }
};

test "tab and shift+tab walk the widgets in order and wrap around" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: NavScene = .{};
    try s.run(&f.ui);
    try testing.expectEqualStrings("none", s.focusedName());
    const forward = [_][]const u8{ "text", "check", "slide", "press", "text" };
    for (forward) |name| {
        try s.key(&f.ui, .tab, .{});
        try testing.expectEqualStrings(name, s.focusedName());
    }
    const backward = [_][]const u8{ "press", "slide", "check", "text" };
    for (backward) |name| {
        try s.key(&f.ui, .tab, shift);
        try testing.expectEqualStrings(name, s.focusedName());
    }
}

test "shift+tab with nothing focused goes to the last widget" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: NavScene = .{};
    try s.run(&f.ui);
    try s.key(&f.ui, .tab, shift);
    try testing.expectEqualStrings("press", s.focusedName());
}

test "the focus ring shows after tab and hides after a click" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: NavScene = .{};
    try s.run(&f.ui);
    const b = s.press.rect;
    f.ui.input.onMouseMove(.{ .x = b.x + 5, .y = b.y + 5 });
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try s.run(&f.ui);
    try testing.expect(s.press.focused and !f.ui.focus_visible and !f.ui.wantsKeyboard());

    try s.key(&f.ui, .tab, shift);
    try testing.expect(s.slide.focused and f.ui.focus_visible and f.ui.wantsKeyboard());

    f.ui.input.onMouseMove(.{ .x = 390, .y = 290 }); // empty space
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try s.run(&f.ui);
    try testing.expectEqualStrings("none", s.focusedName());
    try testing.expect(!f.ui.focus_visible);
}

test "enter and space activate the focused button and checkbox" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: NavScene = .{};
    try s.run(&f.ui);
    try s.key(&f.ui, .tab, shift);
    try s.key(&f.ui, .enter, .{});
    try testing.expect(s.press.clicked);
    try s.key(&f.ui, .space, .{});
    try testing.expect(s.press.clicked);
    try s.run(&f.ui);
    try testing.expect(!s.press.clicked);

    try s.key(&f.ui, .tab, shift);
    try s.key(&f.ui, .tab, shift);
    try s.key(&f.ui, .space, .{});
    try testing.expect(s.checked and s.check.changed);
    try s.key(&f.ui, .enter, .{});
    try testing.expect(!s.checked);
}

test "escape takes focus off a button" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: NavScene = .{};
    try s.run(&f.ui);
    try s.key(&f.ui, .tab, shift);
    try s.key(&f.ui, .escape, .{});
    try testing.expectEqualStrings("none", s.focusedName());
    try s.key(&f.ui, .enter, .{});
    try testing.expect(!s.press.clicked);
}

test "arrow, page and home/end keys step a focused slider" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: NavScene = .{};
    try s.run(&f.ui);
    try s.key(&f.ui, .tab, .{});
    try s.key(&f.ui, .tab, .{});
    try s.key(&f.ui, .tab, .{});
    try testing.expect(s.slide.focused);
    try s.key(&f.ui, .right, .{});
    try testing.expectEqual(@as(i32, 51), s.level);
    try testing.expect(s.slide.changed);
    try s.key(&f.ui, .down, .{});
    try s.key(&f.ui, .left, shift);
    try testing.expectEqual(@as(i32, 40), s.level);
    try s.key(&f.ui, .page_up, .{});
    try testing.expectEqual(@as(i32, 50), s.level);
    try s.key(&f.ui, .end, .{});
    try testing.expectEqual(@as(i32, 100), s.level);
    try s.key(&f.ui, .right, .{}); // clamped
    try testing.expectEqual(@as(i32, 100), s.level);
    try testing.expect(!s.slide.changed);
    try s.key(&f.ui, .home, .{});
    try testing.expectEqual(@as(i32, 0), s.level);
}

test "a float slider steps by its step or a hundredth of its range" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var value: f32 = 0.5;
    var snapped: f64 = 1;
    const frame = struct {
        fn run(u: *zui.Ui, v: *f32, w: *f64) !void {
            u.beginFrame(.{ .width = 400, .height = 300 });
            _ = u.slider("A", v, 0, 2, .{});
            _ = u.slider("B", w, 0, 2, .{ .step = 0.25 });
            _ = try u.endFrame();
        }
    }.run;
    try frame(&f.ui, &value, &snapped);
    f.ui.input.onKeyPress(.tab);
    try frame(&f.ui, &value, &snapped);
    f.ui.input.onKeyPress(.right);
    try frame(&f.ui, &value, &snapped);
    try testing.expectApproxEqAbs(@as(f32, 0.52), value, 1e-6);
    f.ui.input.onKeyPress(.tab);
    try frame(&f.ui, &value, &snapped);
    f.ui.input.onKeyPress(.left);
    try frame(&f.ui, &value, &snapped);
    try testing.expectEqual(@as(f64, 0.75), snapped);
}

test "escape during a slider drag puts the old value back" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: NavScene = .{};
    try s.run(&f.ui);
    const track = s.slide.rect;
    f.ui.input.onMouseMove(.{ .x = track.x + 2, .y = track.y + 5 });
    f.ui.input.onMouseButton(.left, true);
    try s.run(&f.ui);
    try testing.expectEqual(@as(i32, 0), s.level);
    f.ui.input.onKeyPress(.escape);
    try s.run(&f.ui);
    try testing.expectEqual(@as(i32, 50), s.level);
    try testing.expect(s.slide.changed);
    // Still holding the button: the slider no longer follows the mouse.
    f.ui.input.onMouseMove(.{ .x = track.x + 100, .y = track.y + 5 });
    try s.run(&f.ui);
    try testing.expectEqual(@as(i32, 50), s.level);
    f.ui.input.onMouseButton(.left, false);
    try s.run(&f.ui);
}

test "tabbing into a text field selects it, escape reverts the edit" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: NavScene = .{};
    @memcpy(s.buffer[0..5], "hello");
    s.len = 5;
    try s.run(&f.ui);
    try s.key(&f.ui, .tab, .{});
    try testing.expect(s.text.focused);
    try testing.expectEqual([2]usize{ 0, 5 }, f.ui.text_edit.selection());
    f.ui.input.onText("bye");
    try s.run(&f.ui);
    try testing.expectEqualStrings("bye", s.buffer[0..s.len]);
    try s.key(&f.ui, .escape, .{});
    try testing.expectEqualStrings("hello", s.buffer[0..s.len]);
    try testing.expect(s.text.changed and !s.text.focused);
}

test "tab moves on from a text field and keeps its edit" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: NavScene = .{};
    try s.run(&f.ui);
    try s.key(&f.ui, .tab, .{});
    f.ui.input.onText("abc");
    try s.run(&f.ui);
    try s.key(&f.ui, .tab, .{});
    try testing.expect(s.check.focused);
    try testing.expectEqualStrings("abc", s.buffer[0..s.len]);
}

test "tabbing to a widget in a scrolled window scrolls it into view" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var last: zui.Interaction = .{};
    const frame = struct {
        fn run(u: *zui.Ui, out: *zui.Interaction) !void {
            u.beginFrame(.{ .width = 600, .height = 400 });
            if (u.beginWindow("List", .{ .position = .{ .x = 10, .y = 10 }, .size = .{ .x = 200, .y = 150 } })) {
                defer u.endWindow();
                for (0..20) |i| {
                    u.pushIdInt(i);
                    defer u.popId();
                    out.* = u.button("Item", .{});
                }
            }
            _ = try u.endFrame();
        }
    }.run;
    for (0..3) |_| try frame(ui, &last);
    ui.input.modifiers = shift;
    ui.input.onKeyPress(.tab); // wraps to the last item, far below
    ui.input.modifiers = .{};
    for (0..4) |_| try frame(ui, &last);
    try testing.expect(last.focused);
    const w = ui.windows.get(ui.id("List")).?;
    try testing.expect(w.scroll > 0);
    try testing.expect(last.rect.bottom() <= w.rect.bottom());
}

test "focus navigation doesn't allocate once stable" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const allocator = failing.allocator();
    const f = try Fixture.create(allocator);
    defer f.destroy(allocator);
    var s: NavScene = .{};
    try s.run(&f.ui);
    // One full lap first, so the text field has its memory.
    for (0..4) |_| try s.key(&f.ui, .tab, .{});
    const settled = failing.allocations;
    for (0..20) |_| try s.key(&f.ui, .tab, .{});
    try testing.expectEqual(settled, failing.allocations);
}

/// The fills of every rect drawn in the last frame, in order.
fn rectFills(ui: *const zui.Ui, out: []zui.Color) []zui.Color {
    var n: usize = 0;
    for (ui.output.commands.items) |cmd| switch (cmd) {
        .rect => |r| if (r.fill.a != 0 and n < out.len) {
            out[n] = r.fill;
            n += 1;
        },
        else => {},
    };
    return out[0..n];
}

test "a pushed color applies until its pop and no further" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    const red = zui.Color.hex(0xFF0000);
    ui.beginFrame(.{ .width = 400, .height = 300 });
    _ = ui.button("Before", .{});
    ui.pushColor(.button, red);
    _ = ui.button("Inside", .{});
    ui.popStyle();
    _ = ui.button("After", .{});
    _ = try ui.endFrame();

    var buffer: [8]zui.Color = undefined;
    const fills = rectFills(ui, &buffer);
    try testing.expectEqual(@as(usize, 3), fills.len);
    try testing.expectEqual(ui.style.colors.button, fills[0]);
    try testing.expectEqual(red, fills[1]);
    try testing.expectEqual(ui.style.colors.button, fills[2]);
}

test "nested overrides unwind in order, and popStyles pops several" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    const base = ui.style;
    ui.beginFrame(.{ .width = 400, .height = 300 });
    ui.pushMetric(.rounding, 0);
    ui.pushMetric(.frame_padding, .{ .x = 2, .y = 1 });
    ui.pushMetric(.rounding, 20);
    try testing.expectEqual(@as(f32, 20), ui.style.rounding);
    ui.popStyle();
    try testing.expectEqual(@as(f32, 0), ui.style.rounding);
    try testing.expectEqual(@as(f32, 2), ui.style.frame_padding.x);
    ui.popStyles(2);
    try testing.expectEqual(base.rounding, ui.style.rounding);
    try testing.expectEqual(base.frame_padding, ui.style.frame_padding);
    _ = try ui.endFrame();
}

test "a pushed theme covers its scope, then the base theme returns" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    ui.beginFrame(.{ .width = 400, .height = 300 });
    ui.pushStyle(zui.Style.light);
    _ = ui.button("Light", .{});
    ui.popStyle();
    _ = ui.button("Dark", .{});
    _ = try ui.endFrame();

    var buffer: [8]zui.Color = undefined;
    const fills = rectFills(ui, &buffer);
    try testing.expectEqual(zui.Style.light.colors.button, fills[0]);
    try testing.expectEqual(zui.Style.dark.colors.button, fills[1]);
    try testing.expectEqual(zui.Style.dark.colors.background, ui.style.colors.background);
}

test "a metric override changes layout inside its scope only" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    ui.beginFrame(.{ .width = 400, .height = 300 });
    const normal = ui.button("Same", .{}).rect;
    ui.pushMetric(.frame_padding, .{ .x = 30, .y = 20 });
    const big = ui.button("Same##2", .{}).rect;
    ui.popStyle();
    const again = ui.button("Same##3", .{}).rect;
    _ = try ui.endFrame();
    try testing.expectApproxEqAbs(normal.w + 36, big.w, 0.01);
    try testing.expectApproxEqAbs(normal.h + 28, big.h, 0.01);
    try testing.expectEqual(normal.w, again.w);
}

test "every color of both themes is opaque or deliberately translucent" {
    inline for (.{ zui.Style.dark, zui.Style.light }) |theme| {
        inline for (comptime std.meta.fieldNames(zui.Colors)) |name| {
            const c = @field(theme.colors, name);
            const translucent = comptime std.mem.eql(u8, name, "selection") or std.mem.eql(u8, name, "slider_fill") or std.mem.eql(u8, name, "shadow") or std.mem.eql(u8, name, "backdrop");
            if (!translucent) try testing.expectEqual(@as(u8, 255), c.a);
            if (translucent) try testing.expect(c.a > 0 and c.a < 255);
        }
    }
}

/// A button that opens a popup with two buttons, one of which opens a
/// nested popup; a plain button under where the popup appears; a window.
const PopupScene = struct {
    opener: zui.Interaction = .{},
    under: zui.Interaction = .{},
    item: zui.Interaction = .{},
    close: zui.Interaction = .{},
    child_item: zui.Interaction = .{},
    open: bool = false,
    child_open: bool = false,
    with_popup: bool = true,
    with_window: bool = false,
    popup_rect: zui.Rect = .{},

    fn run(s: *PopupScene, ui: *zui.Ui) !void {
        ui.beginFrame(.{ .width = 400, .height = 300 });
        if (s.with_window) {
            if (ui.beginWindow("Win", .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 400, .y = 300 } })) ui.endWindow();
        }
        s.opener = ui.button("Open", .{});
        if (s.opener.clicked) ui.openPopupAt("menu", s.opener.rect);
        s.under = ui.button("Under the popup", .{});
        s.open = false;
        s.child_open = false;
        if (s.with_popup and ui.beginPopup("menu", .{ .min_width = 150 })) {
            s.open = true;
            s.item = ui.button("Item", .{ .width = .fill });
            if (s.item.clicked) ui.openPopup("child");
            s.close = ui.button("Close", .{ .width = .fill });
            if (s.close.clicked) ui.closePopup();
            if (ui.beginPopup("child", .{})) {
                s.child_open = true;
                s.child_item = ui.button("Child item", .{});
                ui.endPopup();
            }
            s.popup_rect = ui.current_window.?.rect;
            ui.endPopup();
        }
        _ = try ui.endFrame();
    }

    fn settle(s: *PopupScene, ui: *zui.Ui) !void {
        for (0..3) |_| try s.run(ui);
    }

    fn clickAt(s: *PopupScene, ui: *zui.Ui, at: zui.Vec2) !void {
        ui.input.onMouseMove(at);
        ui.input.onMouseButton(.left, true);
        ui.input.onMouseButton(.left, false);
        try s.run(ui);
        try s.settle(ui);
    }

    fn clickOn(s: *PopupScene, ui: *zui.Ui, r: zui.Rect) !void {
        try s.clickAt(ui, .{ .x = r.x + 5, .y = r.y + r.h / 2 });
    }
};

test "a popup opens below its anchor, takes clicks, and closes on a click elsewhere" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: PopupScene = .{};
    try s.settle(&f.ui);
    try testing.expect(!s.open);
    try s.clickOn(&f.ui, s.opener.rect);
    try testing.expect(s.open);
    try testing.expect(s.popup_rect.y >= s.opener.rect.bottom());

    // The popup covers the button below the opener: a click there hits the
    // popup's item, not the button.
    const item = s.item.rect;
    try testing.expect(item.intersect(s.under.rect).w > 0);
    f.ui.input.onMouseMove(.{ .x = item.x + 5, .y = item.y + item.h / 2 });
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try s.run(&f.ui);
    try testing.expect(s.item.clicked and !s.under.clicked);
    try s.settle(&f.ui);
    try testing.expect(s.open and s.child_open);

    try s.clickAt(&f.ui, .{ .x = 390, .y = 290 }); // empty space
    try testing.expect(!s.open and !s.child_open);
}

test "a click in a parent popup closes its child only" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: PopupScene = .{};
    try s.settle(&f.ui);
    try s.clickOn(&f.ui, s.opener.rect);
    try s.clickOn(&f.ui, s.item.rect);
    try testing.expect(s.child_open);
    // A spot in the parent outside the child: the parent's right edge.
    try s.clickAt(&f.ui, .{ .x = s.popup_rect.right() - 3, .y = s.popup_rect.bottom() - 3 });
    try testing.expect(s.open and !s.child_open);
}

test "escape, closePopup and no longer describing a popup close it" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: PopupScene = .{};
    try s.settle(&f.ui);
    try s.clickOn(&f.ui, s.opener.rect);
    f.ui.input.onKeyPress(.escape);
    try s.settle(&f.ui);
    try testing.expect(!s.open);

    try s.clickOn(&f.ui, s.opener.rect);
    try s.clickOn(&f.ui, s.close.rect);
    try testing.expect(!s.open);

    try s.clickOn(&f.ui, s.opener.rect);
    s.with_popup = false;
    try s.settle(&f.ui);
    s.with_popup = true;
    try s.settle(&f.ui);
    try testing.expect(!s.open);
}

test "popups draw above windows described after them" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: PopupScene = .{ .with_window = true };
    try s.settle(&f.ui);
    // Open it programmatically; the window covers the opener button.
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    f.ui.openPopup("menu");
    _ = try f.ui.endFrame();
    try s.settle(&f.ui);
    try testing.expect(s.open);
    var window_at: ?usize = null;
    var popup_at: ?usize = null;
    for (f.ui.output.commands.items, 0..) |cmd, i| switch (cmd) {
        .rect => |r| {
            if (window_at == null and std.meta.eql(r.fill, f.ui.style.colors.window)) window_at = i;
            if (popup_at == null and std.meta.eql(r.fill, f.ui.style.colors.popup)) popup_at = i;
        },
        else => {},
    };
    try testing.expect(popup_at.? > window_at.?);
}

test "popups stay on screen near the edges" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var rect: zui.Rect = .{};
    const frame = struct {
        fn run(u: *zui.Ui, out: *zui.Rect) !void {
            u.beginFrame(.{ .width = 400, .height = 300 });
            if (u.beginPopup("edge", .{})) {
                u.label("A popup with a fairly long line of text", .{});
                u.label("and a second line", .{});
                out.* = u.current_window.?.rect;
                u.endPopup();
            }
            _ = try u.endFrame();
        }
    }.run;
    // At the mouse in the bottom-right corner.
    ui.input.onMouseMove(.{ .x = 395, .y = 295 });
    ui.beginFrame(.{ .width = 400, .height = 300 });
    ui.openPopup("edge");
    _ = try ui.endFrame();
    for (0..3) |_| try frame(ui, &rect);
    try testing.expect(rect.w > 100);
    try testing.expect(rect.x >= 0 and rect.right() <= 400.01 and rect.y >= 0 and rect.bottom() <= 300.01);
    try testing.expect(rect.bottom() <= 295.01); // flipped above the pointer

    // Below an anchor near the bottom: flips above it.
    const anchor: zui.Rect = .{ .x = 20, .y = 260, .w = 80, .h = 30 };
    ui.beginFrame(.{ .width = 400, .height = 300 });
    ui.openPopupAt("edge", anchor);
    _ = try ui.endFrame();
    for (0..3) |_| try frame(ui, &rect);
    try testing.expect(rect.bottom() <= anchor.y);
}

const TooltipScene = struct {
    button: zui.Interaction = .{},
    at: zui.Vec2 = .{ .x = 16, .y = 16 },

    fn run(s: *TooltipScene, ui: *zui.Ui, dt: f32) !void {
        ui.beginFrame(.{ .width = 400, .height = 300, .dt = dt });
        ui.beginVertical(.{});
        ui.spacer(.px(s.at.y - 16));
        ui.beginHorizontal(.{});
        ui.spacer(.px(s.at.x - 16));
        s.button = ui.button("Hover me", .{});
        ui.tooltip(s.button, "A helpful tip\nover two lines");
        ui.endHorizontal();
        ui.endVertical();
        _ = try ui.endFrame();
    }

    fn tooltipRect(ui: *const zui.Ui) ?zui.Rect {
        for (ui.overlay.commands.items) |cmd| switch (cmd) {
            .rect => |r| return r.rect,
            else => {},
        };
        return null;
    }
};

test "a tooltip waits for its delay and wakes the UI to show it" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TooltipScene = .{};
    for (0..3) |_| try s.run(&f.ui, 0.016);
    const b = s.button.rect;
    f.ui.input.onMouseMove(.{ .x = b.x + 5, .y = b.y + 5 });
    try s.run(&f.ui, 0.016);
    try testing.expect(TooltipScene.tooltipRect(&f.ui) == null);
    const wait = f.ui.redraw_in orelse return error.NoWakeUp;
    try testing.expectApproxEqAbs(f.ui.style.tooltip_delay, wait, 0.001);

    try s.run(&f.ui, 0.2);
    try testing.expect(TooltipScene.tooltipRect(&f.ui) == null);
    try s.run(&f.ui, wait);
    try testing.expect(TooltipScene.tooltipRect(&f.ui) != null);

    // Pressing hides it.
    f.ui.input.onMouseButton(.left, true);
    try s.run(&f.ui, 0.016);
    try testing.expect(TooltipScene.tooltipRect(&f.ui) == null);
    f.ui.input.onMouseButton(.left, false);
    try s.run(&f.ui, 0.016);
}

test "a tooltip near the corner stays on screen" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TooltipScene = .{ .at = .{ .x = 300, .y = 260 } };
    for (0..4) |_| try s.run(&f.ui, 0.016);
    const b = s.button.rect;
    f.ui.input.onMouseMove(.{ .x = b.right() - 2, .y = b.bottom() - 2 });
    for (0..3) |_| try s.run(&f.ui, 1);
    const r = TooltipScene.tooltipRect(&f.ui) orelse return error.NoTooltip;
    try testing.expect(r.x >= 0 and r.right() <= 400 and r.y >= 0 and r.bottom() <= 300);
}

const ColorScene = struct {
    color: zui.Color = zui.Color.hex(0x336699),
    result: zui.Interaction = .{},

    fn run(s: *ColorScene, ui: *zui.Ui) !void {
        ui.beginFrame(.{ .width = 500, .height = 400 });
        s.result = ui.colorEdit("Tint", &s.color, .{});
        _ = try ui.endFrame();
    }
};

test "color edit opens a picker whose sliders and hex field edit the color" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var s: ColorScene = .{};
    for (0..3) |_| try s.run(ui);
    const sw = s.result.rect;
    ui.input.onMouseMove(.{ .x = sw.x + 5, .y = sw.y + 5 });
    ui.input.onMouseButton(.left, true);
    ui.input.onMouseButton(.left, false);
    for (0..3) |_| try s.run(ui);
    try testing.expectEqual(@as(usize, 1), ui.popup_count);

    // Tab moves into the picker: the eyedropper, then the hex field.
    for (0..2) |_| {
        ui.input.onKeyPress(.tab);
        try s.run(ui);
    }
    try testing.expectEqual(ui.text_edit.id, ui.focused);
    ui.input.onText("#ff000080");
    try s.run(ui);
    try testing.expect(s.result.changed);
    try testing.expectEqual(zui.Color{ .r = 255, .g = 0, .b = 0, .a = 128 }, s.color);

    // The R field follows the arrow keys once focused: past the RGB / HSV
    // switch.
    for (0..2) |_| {
        ui.input.onKeyPress(.tab);
        try s.run(ui);
    }
    ui.input.onKeyPress(.left);
    try s.run(ui);
    try testing.expectEqual(@as(u8, 254), s.color.r);
}

test "open nested popups don't allocate once stable" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const allocator = failing.allocator();
    const f = try Fixture.create(allocator);
    defer f.destroy(allocator);
    var s: PopupScene = .{};
    try s.settle(&f.ui);
    try s.clickOn(&f.ui, s.opener.rect);
    try s.clickOn(&f.ui, s.item.rect);
    try testing.expect(s.child_open);
    const settled = failing.allocations;
    for (0..30) |_| try s.run(&f.ui);
    try testing.expectEqual(settled, failing.allocations);
}

test "a showing tooltip doesn't allocate once stable" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const allocator = failing.allocator();
    const f = try Fixture.create(allocator);
    defer f.destroy(allocator);
    var t: TooltipScene = .{};
    for (0..3) |_| try t.run(&f.ui, 0.016);
    f.ui.input.onMouseMove(.{ .x = t.button.rect.x + 5, .y = t.button.rect.y + 5 });
    for (0..3) |_| try t.run(&f.ui, 1);
    try testing.expect(TooltipScene.tooltipRect(&f.ui) != null);
    const settled = failing.allocations;
    for (0..30) |_| try t.run(&f.ui, 0.016);
    try testing.expectEqual(settled, failing.allocations);
}

/// Every widget at once, with the busy states that keep extra memory: a
/// focused text field, an open color picker, a showing tooltip, a window.
const EverythingScene = struct {
    flag: bool = true,
    float: f32 = 0.5,
    int: i32 = 4,
    text: [32]u8 = "edit me".* ++ @as([25]u8, @splat(0)),
    text_len: usize = 7,
    color: zui.Color = zui.Color.hex(0x336699),
    tip: zui.Interaction = .{},
    field: zui.Interaction = .{},
    swatch: zui.Interaction = .{},

    fn run(s: *EverythingScene, ui: *zui.Ui, dt: f32) !void {
        ui.beginFrame(.{ .width = 800, .height = 600, .dt = dt });
        ui.label("Label", .{});
        ui.labelf("Formatted {d}", .{s.int}, .{});
        s.tip = ui.button("Tip", .{});
        ui.tooltip(s.tip, "A tooltip");
        _ = ui.checkbox("Check", &s.flag, .{});
        _ = ui.slider("Float", &s.float, 0, 1, .{});
        _ = ui.slider("Int", &s.int, 0, 10, .{});
        s.field = ui.textInput("Text", &s.text, &s.text_len, .{});
        ui.separator();
        ui.beginHorizontal(.{ .padding = 4, .border = ui.style.colors.border });
        ui.pushColor(.button, zui.Color.hex(0xAA0000));
        _ = ui.button("Styled", .{});
        ui.popStyle();
        ui.spacer(.fill);
        s.swatch = ui.colorEdit("Color", &s.color, .{});
        ui.endHorizontal();
        if (ui.beginWindow("Window", .{ .position = .{ .x = 450, .y = 300 } })) {
            defer ui.endWindow();
            for (0..20) |i| {
                ui.pushIdInt(i);
                defer ui.popId();
                _ = ui.button("Row", .{});
            }
        }
        _ = try ui.endFrame();
    }
};

test "a frame with every widget in a busy state doesn't allocate once stable" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const allocator = failing.allocator();
    const f = try Fixture.create(allocator);
    defer f.destroy(allocator);
    const ui = &f.ui;
    var s: EverythingScene = .{};
    for (0..3) |_| try s.run(ui, 0.016);

    // Focus the text field, open the color picker, then rest on the button.
    const field = s.field.rect;
    ui.input.onMouseMove(.{ .x = field.x + 5, .y = field.y + 5 });
    ui.input.onMouseButton(.left, true);
    ui.input.onMouseButton(.left, false);
    try s.run(ui, 0.016);
    try testing.expect(s.field.focused);
    ui.focused = .none; // the swatch click would take focus anyway
    const swatch = s.swatch.rect;
    ui.input.onMouseMove(.{ .x = swatch.x + 5, .y = swatch.y + 5 });
    ui.input.onMouseButton(.left, true);
    ui.input.onMouseButton(.left, false);
    for (0..3) |_| try s.run(ui, 0.016);
    try testing.expectEqual(@as(usize, 1), ui.popup_count);
    // Tab past the eyedropper to the picker's hex field: a focused text
    // field inside an open popup.
    for (0..2) |_| {
        ui.input.onKeyPress(.tab);
        try s.run(ui, 0.016);
    }
    try testing.expectEqual(ui.text_edit.id, ui.focused);
    const tip = s.tip.rect;
    ui.input.onMouseMove(.{ .x = tip.x + 5, .y = tip.y + 5 });
    for (0..3) |_| try s.run(ui, 1);
    try testing.expect(ui.overlay.commands.items.len > 0);
    try testing.expectEqual(@as(usize, 1), ui.popup_count);
    try testing.expectEqual(ui.text_edit.id, ui.focused);

    const settled = failing.allocations;
    for (0..100) |_| try s.run(ui, 0.016);
    try testing.expectEqual(settled, failing.allocations);
}

fn clickRect(ui: *zui.Ui, r: zui.Rect) void {
    ui.input.onMouseMove(.{ .x = r.x + 5, .y = r.y + r.h / 2 });
    ui.input.onMouseButton(.left, true);
    ui.input.onMouseButton(.left, false);
}

const TreeScene = struct {
    header_open: bool = false,
    node: zui.Interaction = .{},
    node_rect: zui.Rect = .{},
    child_rect: ?zui.Rect = null,
    header_rect: zui.Rect = .{},
    external: bool = true,
    external_child: bool = false,

    fn run(s: *TreeScene, ui: *zui.Ui) !void {
        ui.beginFrame(.{ .width = 400, .height = 300 });
        s.child_rect = null;
        const open = ui.treeNode("Root", .{});
        s.node_rect = ui.last_rect;
        if (open) {
            s.child_rect = ui.button("Child", .{}).rect;
            ui.treePop();
        }
        s.header_open = ui.collapsingHeader("Section", .{});
        s.header_rect = ui.last_rect;
        s.external_child = false;
        if (ui.treeNode("Mine", .{ .open = &s.external })) {
            s.external_child = true;
            ui.treePop();
        }
        _ = try ui.endFrame();
    }
};

test "tree nodes open on click, indent their children, and remember" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TreeScene = .{};
    try s.run(&f.ui);
    try testing.expect(s.child_rect == null);
    const root_rect = s.node_rect;
    clickRect(&f.ui, root_rect);
    try s.run(&f.ui);
    try s.run(&f.ui);
    const child = s.child_rect orelse return error.NotOpen;
    try testing.expectApproxEqAbs(root_rect.x + f.ui.style.indent, child.x, 0.01);
    try testing.expect(child.y > root_rect.bottom());

    // A node with its state in the app's variable.
    try testing.expect(s.external_child);
    s.external = false;
    try s.run(&f.ui);
    try testing.expect(!s.external_child);
}

test "a collapsing header spans the width and toggles from the keyboard" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TreeScene = .{};
    for (0..3) |_| try s.run(&f.ui);
    try testing.expectApproxEqAbs(400 - 2 * f.ui.style.window_padding, s.header_rect.w, 0.01);
    try testing.expect(!s.header_open);
    // Tab: Root, then Section.
    for (0..2) |_| {
        f.ui.input.onKeyPress(.tab);
        try s.run(&f.ui);
    }
    f.ui.input.onKeyPress(.right);
    try s.run(&f.ui);
    try testing.expect(s.header_open);
    f.ui.input.onKeyPress(.space);
    try s.run(&f.ui);
    try testing.expect(!s.header_open);
}

const ListScene = struct {
    chosen: usize = 0,
    rows: [40]zui.Interaction = undefined,
    area: zui.Rect = .{},
    in_window: bool = false,

    fn run(s: *ListScene, ui: *zui.Ui) !void {
        ui.beginFrame(.{ .width = 400, .height = 300 });
        if (s.in_window) {
            if (ui.beginWindow("Host", .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 380, .y = 200 } })) {
                defer ui.endWindow();
                s.list(ui);
                for (0..10) |i| { // make the window itself scrollable too
                    ui.pushIdInt(i);
                    defer ui.popId();
                    ui.label("Filler", .{});
                }
            }
        } else s.list(ui);
        _ = try ui.endFrame();
    }

    fn list(s: *ListScene, ui: *zui.Ui) void {
        ui.beginScrollArea("list", .{ .height = .px(120) });
        for (&s.rows, 0..) |*r, i| {
            ui.pushIdInt(i);
            defer ui.popId();
            r.* = ui.selectable("Row", i == s.chosen, .{});
            if (r.clicked) s.chosen = i;
        }
        ui.endScrollArea();
        s.area = ui.last_rect;
    }
};

test "a scroll area clips its rows, scrolls with the wheel, and rows select" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: ListScene = .{};
    for (0..3) |_| try s.run(&f.ui);
    const first_y = s.rows[0].rect.y;
    try testing.expect(s.rows[39].rect.y > s.area.bottom()); // overflows

    f.ui.input.onMouseMove(.{ .x = s.area.x + 20, .y = s.area.y + 30 });
    f.ui.input.onScroll(.{ .y = -1 });
    for (0..2) |_| try s.run(&f.ui);
    try testing.expect(s.rows[0].rect.y < first_y);

    // A click picks the row under the mouse, wherever it scrolled to.
    var target: usize = 0;
    for (s.rows, 0..) |r, i| {
        if (r.rect.y > s.area.y + 10 and r.rect.bottom() < s.area.bottom()) {
            target = i;
            break;
        }
    }
    try testing.expect(target > 0);
    clickRect(&f.ui, s.rows[target].rect);
    try s.run(&f.ui);
    try testing.expectEqual(target, s.chosen);
}

test "the wheel scrolls the innermost area, not the window around it" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: ListScene = .{ .in_window = true };
    for (0..4) |_| try s.run(&f.ui);
    const w = f.ui.windows.get(f.ui.id("Host")).?;
    const first_y = s.rows[0].rect.y;
    f.ui.input.onMouseMove(.{ .x = s.area.x + 20, .y = s.area.y + 30 });
    f.ui.input.onScroll(.{ .y = -1 });
    for (0..2) |_| try s.run(&f.ui);
    try testing.expect(s.rows[0].rect.y < first_y);
    try testing.expectEqual(@as(f32, 0), w.scroll);
}

test "tabbing to a hidden row scrolls the area to it" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: ListScene = .{};
    for (0..3) |_| try s.run(&f.ui);
    f.ui.input.modifiers = shift;
    f.ui.input.onKeyPress(.tab); // wraps to the last row
    f.ui.input.modifiers = .{};
    for (0..4) |_| try s.run(&f.ui);
    try testing.expect(s.rows[39].focused);
    try testing.expect(s.rows[39].rect.bottom() <= s.area.bottom());
}

const TableScene = struct {
    columns: [3]zui.TableColumn = .{
        .{ .name = "Name" },
        .{ .name = "Size", .width = .px(80) },
        .{ .name = "Kind", .width = .{ .grow = 2 } },
    },
    result: zui.TableResult = .{},
    cells: [3]zui.Rect = undefined,
    table_rect: zui.Rect = .{},

    fn run(s: *TableScene, ui: *zui.Ui) !void {
        ui.beginFrame(.{ .width = 500, .height = 400 });
        s.result = ui.beginTable("files", &s.columns, .{ .height = .px(200) });
        for (0..30) |i| {
            ui.tableRow();
            ui.labelf("file {d}", .{i}, .{});
            if (i == 0) s.cells[0] = ui.last_rect;
            ui.tableNextColumn();
            ui.labelf("{d} KB", .{i * 3}, .{});
            if (i == 0) s.cells[1] = ui.last_rect;
            ui.tableNextColumn();
            ui.label("text", .{});
            if (i == 0) s.cells[2] = ui.last_rect;
        }
        ui.endTable();
        s.table_rect = ui.last_rect;
        _ = try ui.endFrame();
    }
};

test "table columns split the width and header clicks are reported" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: TableScene = .{};
    for (0..3) |_| try s.run(&f.ui);
    const t = f.ui.style.frame_padding.y; // cell padding
    const left = f.ui.style.window_padding;
    // 30 rows overflow, so the scrollbar takes its width from the columns.
    const available = (500 - 2 * left) - (f.ui.style.scrollbar_width + 4);
    const name_w = (available - 80) / 3;
    try testing.expectApproxEqAbs(left + t, s.cells[0].x, 0.01);
    try testing.expectApproxEqAbs(left + name_w + t, s.cells[1].x, 0.01);
    try testing.expectApproxEqAbs(left + name_w + 80 + t, s.cells[2].x, 0.01);

    const header_y = left + 5;
    f.ui.input.onMouseMove(.{ .x = left + name_w + 20, .y = header_y });
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try s.run(&f.ui);
    try testing.expectEqual(@as(?usize, 1), s.result.header_clicked);
    try s.run(&f.ui);
    try testing.expectEqual(@as(?usize, null), s.result.header_clicked);
}

test "trees, lists and tables don't allocate once stable" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const allocator = failing.allocator();
    const f = try Fixture.create(allocator);
    defer f.destroy(allocator);
    var tree: TreeScene = .{};
    var list: ListScene = .{};
    var table: TableScene = .{};
    for (0..3) |_| {
        try tree.run(&f.ui);
        try list.run(&f.ui);
        try table.run(&f.ui);
    }
    clickRect(&f.ui, tree.node_rect);
    for (0..3) |_| try tree.run(&f.ui);
    const settled = failing.allocations;
    for (0..20) |_| {
        try tree.run(&f.ui);
        try list.run(&f.ui);
        try table.run(&f.ui);
    }
    try testing.expectEqual(settled, failing.allocations);
}

/// Two windows, a tree node and a scroll area: everything that persists.
const PersistScene = struct {
    rows: [30]zui.Interaction = undefined,

    fn run(s: *PersistScene, ui: *zui.Ui) !void {
        ui.beginFrame(.{ .width = 600, .height = 400 });
        if (ui.treeNode("Node", .{})) ui.treePop();
        ui.beginScrollArea("area", .{ .height = .px(100) });
        for (&s.rows, 0..) |*r, i| {
            ui.pushIdInt(i);
            defer ui.popId();
            r.* = ui.selectable("Row", false, .{});
        }
        ui.endScrollArea();
        if (ui.beginWindow("A", .{ .position = .{ .x = 300, .y = 20 } })) ui.endWindow();
        if (ui.beginWindow("B", .{ .position = .{ .x = 320, .y = 60 } })) ui.endWindow();
        _ = try ui.endFrame();
    }
};

test "saved state restores windows, open nodes and scroll into a new Ui" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const ui = &f.ui;
    var s: PersistScene = .{};
    for (0..3) |_| try s.run(ui);

    // Change everything: move and resize A, collapse B, open the node,
    // scroll the area.
    const a = ui.windows.get(ui.id("A")).?;
    a.rect = .{ .x = 111, .y = 222, .w = 250, .h = 140 };
    ui.windows.get(ui.id("B")).?.collapsed = true;
    try ui.open_states.put(ui.allocator, ui.id("Node"), true);
    ui.input.onMouseMove(.{ .x = 40, .y = 100 });
    ui.input.onScroll(.{ .y = -1 });
    for (0..3) |_| try s.run(ui);
    const scrolled_row = s.rows[0].rect.y;

    const bytes = try ui.saveState(testing.allocator);
    defer testing.allocator.free(bytes);

    // A brand-new Ui, as after a reload.
    const g = try Fixture.create(testing.allocator);
    defer g.destroy(testing.allocator);
    try g.ui.restoreState(bytes);
    var t: PersistScene = .{};
    for (0..3) |_| try t.run(&g.ui);

    const a2 = g.ui.windows.get(g.ui.id("A")).?;
    try testing.expectEqual(zui.Rect{ .x = 111, .y = 222, .w = 250, .h = 140 }, a2.rect);
    try testing.expect(g.ui.windows.get(g.ui.id("B")).?.collapsed);
    try testing.expectEqual(true, g.ui.open_states.get(g.ui.id("Node")).?);
    try testing.expectApproxEqAbs(scrolled_row, t.rows[0].rect.y, 0.01);
    // Same z-order: B was described last, so it is in front in both.
    const order = g.ui.window_order.items;
    try testing.expectEqual(g.ui.id("B"), order[order.len - 1].id);
}

test "damaged saved state is rejected and changes nothing" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var s: PersistScene = .{};
    for (0..3) |_| try s.run(&f.ui);
    const bytes = try f.ui.saveState(testing.allocator);
    defer testing.allocator.free(bytes);

    const g = try Fixture.create(testing.allocator);
    defer g.destroy(testing.allocator);
    // Every truncation fails, and so does trailing junk.
    for (0..bytes.len) |n| try testing.expectError(error.InvalidState, g.ui.restoreState(bytes[0..n]));
    var longer: [512]u8 = undefined;
    @memcpy(longer[0..bytes.len], bytes);
    longer[bytes.len] = 0;
    try testing.expectError(error.InvalidState, g.ui.restoreState(longer[0 .. bytes.len + 1]));
    // A NaN where a window's x should be.
    var bad = longer[0..bytes.len];
    @memcpy(bad, bytes);
    const nan: u32 = 0x7FC00000;
    std.mem.writeInt(u32, bad[4 + 2 + 4 + 8 ..][0..4], nan, .little);
    try testing.expectError(error.InvalidState, g.ui.restoreState(bad));
    try testing.expectEqual(@as(usize, 0), g.ui.windows.count());
}

// ---- Phase 13: canvases, cursors, fonts, icons ----

/// One frame with a 200 x 100 canvas at the top-left of a window-less UI.
fn canvasFrame(f: *Fixture, options: zui.CanvasOptions) !zui.Canvas {
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    var opts = options;
    opts.width = .px(200);
    opts.height = .px(100);
    const c = f.ui.beginCanvas("canvas", opts);
    f.ui.endCanvas();
    _ = try f.ui.endFrame();
    return c;
}

test "a canvas keeps the middle button while the pointer leaves it" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.input.onMouseMove(.{ .x = 390, .y = 290 });
    _ = try canvasFrame(f, .{});
    // Arrive from far away, press and move a little, all in one frame:
    // only the movement after the press counts.
    f.ui.input.onMouseMove(.{ .x = 47, .y = 50 });
    f.ui.input.onMouseButton(.middle, true);
    f.ui.input.onMouseMove(.{ .x = 50, .y = 50 });
    const pressed = try canvasFrame(f, .{});
    try testing.expect(pressed.middle_pressed);
    try testing.expectEqual(@as(f32, 3), pressed.delta.x);
    try testing.expectEqual(@as(?zui.MouseButton, .middle), pressed.dragging);

    f.ui.input.onMouseMove(.{ .x = 350, .y = 250 });
    const outside = try canvasFrame(f, .{});
    try testing.expectEqual(@as(?zui.MouseButton, .middle), outside.dragging);
    try testing.expect(!outside.hovered);
    try testing.expectEqual(@as(f32, 300), outside.delta.x);

    f.ui.input.onMouseButton(.middle, false);
    const released = try canvasFrame(f, .{});
    try testing.expectEqual(@as(?zui.MouseButton, null), released.dragging);
}

test "a canvas takes the wheel only while hovered, and sets its cursor" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.input.onMouseMove(.{ .x = 50, .y = 50 });
    f.ui.input.onScroll(.{ .y = 2 });
    const over = try canvasFrame(f, .{ .cursor = .crosshair });
    try testing.expectEqual(@as(f32, 2), over.wheel.y);
    try testing.expectEqual(zui.Cursor.crosshair, f.ui.cursor);
    try testing.expectEqual(50 - over.rect.x, over.mouse.x);

    f.ui.input.onMouseMove(.{ .x = 350, .y = 250 });
    f.ui.input.onScroll(.{ .y = 2 });
    const away = try canvasFrame(f, .{ .cursor = .crosshair });
    try testing.expectEqual(@as(f32, 0), away.wheel.y);
    try testing.expectEqual(zui.Cursor.default, f.ui.cursor);
}

test "a canvas at a rect of its own, and the pointer's events in order" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    _ = f.ui.beginCanvas("placed", .{ .rect = .{ .x = 100, .y = 120, .w = 50, .h = 40 } });
    f.ui.endCanvas();
    _ = try f.ui.endFrame();
    // A whole stroke between two frames: every sample is there, in order.
    f.ui.input.onMouseMove(.{ .x = 110, .y = 130 });
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseMove(.{ .x = 115, .y = 131 });
    f.ui.input.onMouseMove(.{ .x = 120, .y = 133 });
    f.ui.input.onMouseButton(.left, false);
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    const c = f.ui.beginCanvas("placed", .{ .rect = .{ .x = 100, .y = 120, .w = 50, .h = 40 } });
    f.ui.endCanvas();
    try testing.expectEqual(@as(f32, 100), c.rect.x);
    try testing.expectEqual(@as(f32, 40), c.rect.h);
    try testing.expect(c.interaction.pressed);
    const evs = f.ui.input.pointerEvents();
    try testing.expectEqual(@as(usize, 5), evs.len);
    try testing.expectEqual(zui.PointerEvent.Kind.press, evs[1].kind);
    try testing.expectEqual(@as(f32, 115), evs[2].pos.x);
    try testing.expectEqual(zui.PointerEvent.Kind.release, evs[4].kind);
    _ = try f.ui.endFrame();
    try testing.expectEqual(@as(usize, 0), f.ui.input.pointerEvents().len);
}

test "a text field asks for the text cursor" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var buffer: [16]u8 = undefined;
    var len: usize = 0;
    f.ui.input.onMouseMove(.{ .x = 30, .y = 18 });
    for (0..2) |_| {
        f.ui.beginFrame(.{ .width = 400, .height = 300 });
        _ = f.ui.textInput("Name", &buffer, &len, .{});
        _ = try f.ui.endFrame();
    }
    try testing.expectEqual(zui.Cursor.text, f.ui.cursor);
}

test "pushFont measures with the pushed font, popFont restores" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    var mono: zui.Font = try .initMono(testing.allocator);
    defer mono.deinit();
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    const sans_w = f.ui.textSize("iiii").x;
    f.ui.pushFont(&mono);
    const mono_i = f.ui.textSize("iiii").x;
    const mono_w = f.ui.textSize("WWWW").x;
    f.ui.popFont();
    _ = try f.ui.endFrame();
    try testing.expectApproxEqAbs(mono_i, mono_w, 0.01);
    try testing.expect(mono_i > sans_w);
    try testing.expect(f.ui.font == &f.font);
}

test "a fallback font supplies glyphs the main font lacks" {
    var main_font: zui.Font = try .initDefault(testing.allocator);
    defer main_font.deinit();
    // A system font with symbols; skipped where it isn't installed.
    var symbols = zui.Font.loadFile(testing.allocator, testing.io, "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf") catch return error.SkipZigTest;
    defer symbols.deinit();
    const star: u21 = 0x2605;
    try testing.expect(!main_font.hasGlyph(star));
    try testing.expect(symbols.hasGlyph(star));
    const missing = main_font.advance(star, 16);
    main_font.fallback = &symbols;
    try testing.expectApproxEqAbs(symbols.advance(star, 16), main_font.advance(star, 16), 0.001);
    try testing.expect(main_font.advance(star, 16) != missing);
    try testing.expect((try main_font.glyph(star, 16, 0)).width > 0);
    // Letters the main font has still come from it.
    try testing.expectApproxEqAbs(main_font.advance('A', 16), 16 * 0.667, 0.05);
}

test "pixel-art icons keep a whole multiple of their size" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    const mask: [32 * 16]u8 = @splat(255);
    const img: zui.Image = .initAlpha(&mask, 32, 16);
    var set: zui.IconSet = .grid(&img, 16, 16);
    for ([_]bool{ false, true }) |whole| {
        set.whole_pixels = whole;
        f.ui.beginFrame(.{ .width = 400, .height = 300 });
        // 18 units: stretched to fit, or kept at 16 and centred
        f.ui.painter().icon(set.icon(1), .{ .x = 10, .y = 10, .w = 18, .h = 18 }, zui.Color.white);
        // 40 units: twice its size
        f.ui.painter().icon(set.icon(1), .{ .x = 100, .y = 10, .w = 40, .h = 40 }, zui.Color.white);
        const list = try f.ui.endFrame();
        var widths: [2]f32 = .{ 0, 0 };
        var n: usize = 0;
        for (list.commands.items) |cmd| if (cmd == .image and n < 2) {
            widths[n] = cmd.image.rect.w;
            if (n == 0 and whole) try testing.expectEqual(@as(f32, 11), cmd.image.rect.x);
            n += 1;
        };
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expectEqual(@as(f32, if (whole) 16 else 18), widths[0]);
        try testing.expectEqual(@as(f32, if (whole) 32 else 40), widths[1]);
    }
}

test "an icon button is square and records its icon" {
    const f = try Fixture.create(testing.allocator);
    defer f.destroy(testing.allocator);
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    _ = f.ui.button("##close", .{ .icon = .{ .builtin = .close } });
    const r = f.ui.lastRect();
    const list = try f.ui.endFrame();
    try testing.expectApproxEqAbs(r.w, r.h, 0.5);
    var paths: usize = 0;
    for (list.commands.items) |cmd| {
        if (cmd == .path) paths += 1;
    }
    try testing.expectEqual(@as(usize, 2), paths);
}
