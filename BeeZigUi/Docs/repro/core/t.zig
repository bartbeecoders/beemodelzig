const std = @import("std");
const zui = @import("zui");
const testing = std.testing;
const A = testing.allocator;

const F = struct {
    font: zui.Font,
    ui: zui.Ui,
    fn create() !*F {
        const f = try A.create(F);
        f.font = try .initDefault(A);
        f.ui = .init(A, .{ .font = &f.font });
        return f;
    }
    fn destroy(f: *F) void {
        f.ui.deinit();
        f.font.deinit();
        A.destroy(f);
    }
};

// 1. A window that stops being described still takes the next frame's press.
test "stale hovered/pressed window swallows a press" {
    const f = try F.create();
    defer f.destroy();
    var r: zui.Interaction = undefined;
    for (0..3) |_| {
        f.ui.beginFrame(.{ .width = 400, .height = 300 });
        r = f.ui.button("OK", .{});
        if (f.ui.beginWindow("W", .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 300, .y = 200 } })) f.ui.endWindow();
        _ = try f.ui.endFrame();
    }
    const at: zui.Vec2 = .{ .x = r.rect.x + 5, .y = r.rect.y + 5 };
    // Window no longer described; user presses where the button now shows.
    f.ui.input.onMouseMove(at);
    f.ui.input.onMouseButton(.left, true);
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    const stale = f.ui.hovered_window != null;
    r = f.ui.button("OK", .{});
    _ = try f.ui.endFrame();
    std.debug.print("\n[1] hovered_window stale={} pressed={} hovered={} dead_press={}\n", .{ stale, r.pressed, r.hovered, f.ui.dead_press });
    f.ui.input.onMouseButton(.left, false);
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    r = f.ui.button("OK", .{});
    _ = try f.ui.endFrame();
    std.debug.print("[1] after release clicked={} hovered_window={}\n", .{ r.clicked, f.ui.hovered_window != null });
    try testing.expect(r.clicked);
}

// 2. Escape closes a popup inside a dialog AND the dialog.
test "escape closes popup and dialog together" {
    const f = try F.create();
    defer f.destroy();
    var open = true;
    var open_popup = true;
    for (0..4) |_| {
        f.ui.beginFrame(.{ .width = 600, .height = 400 });
        if (f.ui.beginDialog("Dlg", &open, .{})) {
            f.ui.label("hello", .{});
            if (open_popup) {
                f.ui.openPopupAt("pop", f.ui.lastRect());
                open_popup = false;
            }
            if (f.ui.beginPopup("pop", .{})) {
                f.ui.label("item", .{});
                f.ui.endPopup();
            }
            f.ui.endDialog();
        }
        _ = try f.ui.endFrame();
    }
    try testing.expectEqual(@as(usize, 1), f.ui.popup_count);
    f.ui.input.onKeyPress(.escape);
    f.ui.beginFrame(.{ .width = 600, .height = 400 });
    if (f.ui.beginDialog("Dlg", &open, .{})) {
        if (f.ui.beginPopup("pop", .{})) f.ui.endPopup();
        f.ui.endDialog();
    }
    _ = try f.ui.endFrame();
    std.debug.print("\n[2] popup_count={} dialog open={}\n", .{ f.ui.popup_count, open });
    try testing.expect(open);
}

fn twoButtons(f: *F, b_first: bool, ra: *zui.Interaction, rb: *zui.Interaction) !void {
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    if (b_first) {
        f.ui.beginHorizontal(.{});
        rb.* = f.ui.button("B", .{});
        ra.* = f.ui.button("A", .{});
        f.ui.endHorizontal();
    } else {
        f.ui.beginHorizontal(.{});
        ra.* = f.ui.button("A", .{});
        rb.* = f.ui.button("B", .{});
        f.ui.endHorizontal();
    }
    _ = try f.ui.endFrame();
}

// 3. Release on A, then press on B, in one frame: B's press/hold is lost.
test "release then press in one frame" {
    for ([_]bool{ false, true }) |b_first| {
        const f = try F.create();
        defer f.destroy();
        var ra: zui.Interaction = undefined;
        var rb: zui.Interaction = undefined;
        for (0..3) |_| try twoButtons(f, b_first, &ra, &rb);
        const pa: zui.Vec2 = .{ .x = ra.rect.x + 3, .y = ra.rect.y + 3 };
        const pb: zui.Vec2 = .{ .x = rb.rect.x + 3, .y = rb.rect.y + 3 };
        f.ui.input.onMouseMove(pa);
        f.ui.input.onMouseButton(.left, true);
        try twoButtons(f, b_first, &ra, &rb);
        // between frames: release on A, move to B, press on B (held)
        f.ui.input.onMouseButton(.left, false);
        f.ui.input.onMouseMove(pb);
        f.ui.input.onMouseButton(.left, true);
        try twoButtons(f, b_first, &ra, &rb);
        const a_clicked = ra.clicked;
        const b_held = rb.held;
        f.ui.input.onMouseButton(.left, false);
        try twoButtons(f, b_first, &ra, &rb);
        std.debug.print("\n[3] b_first={} A.clicked={} B.held(after press)={} B.clicked(after release)={}\n", .{ b_first, a_clicked, b_held, rb.clicked });
    }
}

// 4. press, release, press within one frame (button stays down): hold lost.
test "press release press in one frame" {
    const f = try F.create();
    defer f.destroy();
    var ra: zui.Interaction = undefined;
    var rb: zui.Interaction = undefined;
    for (0..3) |_| try twoButtons(f, false, &ra, &rb);
    f.ui.input.onMouseMove(.{ .x = ra.rect.x + 3, .y = ra.rect.y + 3 });
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    f.ui.input.onMouseButton(.left, true);
    try twoButtons(f, false, &ra, &rb);
    std.debug.print("\n[4] A.clicked={} A.held={} active={} mouse_down={}\n", .{ ra.clicked, ra.held, f.ui.active != .none, f.ui.input.mouse_down.contains(.left) });
    try twoButtons(f, false, &ra, &rb);
    std.debug.print("[4] next frame (still down) A.held={}\n", .{ra.held});
}

// 5. Horizontal scroll area: last part of content can't be scrolled to.
test "horizontal scroll area vertical clamp" {
    const f = try F.create();
    defer f.destroy();
    var area_rect: zui.Rect = .{};
    for (0..9) |i| {
        if (i >= 3 and i < 8) {
            f.ui.input.onMouseMove(.{ .x = 50, .y = 50 });
            f.ui.input.onScroll(.{ .y = -100 });
        }
        f.ui.beginFrame(.{ .width = 400, .height = 300 });
        f.ui.beginScrollArea("sa", .{ .height = .px(100), .horizontal = true });
        f.ui.label("a very very very very very very very very very very very very very very wide line", .{});
        for (0..20) |_| f.ui.label("row", .{});
        f.ui.endScrollArea();
        area_rect = f.ui.lastRect();
        _ = try f.ui.endFrame();
    }
    var it = f.ui.scroll_states.iterator();
    while (it.next()) |e| {
        const s = e.value_ptr.*;
        const body_h = area_rect.h - f.ui.style.scrollbar_width - 4;
        std.debug.print("\n[5] scroll={d:.1} content_h={d:.1} rect.h={d:.1} reachable-needed={d:.1} clamp-used={d:.1}\n", .{ s.scroll, s.content_height, area_rect.h, s.content_height - body_h, s.content_height - area_rect.h });
        try testing.expect(s.scroll >= s.content_height - body_h - 0.5);
    }
}

// 6. A .fill item in an auto-width column never shrinks back.
test "fill across in auto column never shrinks" {
    const f = try F.create();
    defer f.destroy();
    var r: zui.Interaction = undefined;
    for (0..12) |i| {
        f.ui.beginFrame(.{ .width = 800, .height = 300 });
        f.ui.beginVertical(.{});
        f.ui.label(if (i < 4) "a long long long long long long long label" else "short", .{});
        r = f.ui.button("Fill", .{ .width = .fill });
        f.ui.endVertical();
        _ = try f.ui.endFrame();
        if (i == 3 or i == 11) std.debug.print("\n[6] frame {} fill width={d:.1} redraw={}\n", .{ i, r.rect.w, f.ui.redraw_requested });
    }
    try testing.expect(r.rect.w < 200);
}

// 7. Window states for popups are never freed.
test "popup window states accumulate" {
    const f = try F.create();
    defer f.destroy();
    for (0..200) |i| {
        f.ui.beginFrame(.{ .width = 400, .height = 300 });
        f.ui.pushIdInt(i);
        f.ui.openPopupAt("ctx", .{ .x = 10, .y = 10 });
        if (f.ui.beginPopup("ctx", .{})) {
            f.ui.label("x", .{});
            f.ui.endPopup();
        }
        f.ui.popId();
        _ = try f.ui.endFrame();
    }
    std.debug.print("\n[7] windows={} window_order={} measures={}\n", .{ f.ui.windows.count(), f.ui.window_order.items.len, f.ui.measures.count() });
}

// 6b. A dialog never gets narrower while open (its .fill button row keeps the width).
test "dialog never shrinks" {
    const f = try F.create();
    defer f.destroy();
    var open = true;
    for (0..12) |i| {
        f.ui.beginFrame(.{ .width = 1000, .height = 400 });
        if (f.ui.beginDialog("Dlg", &open, .{})) {
            f.ui.label(if (i < 4) "a long long long long long long long long long long long long label" else "short", .{});
            _ = f.ui.dialogButtons(&.{ "OK", "Cancel" }, .{ .default = 0, .cancel = 1 });
            f.ui.endDialog();
        }
        _ = try f.ui.endFrame();
        if (i == 3 or i == 11) std.debug.print("\n[6b] frame {} dialog width={d:.1}\n", .{ i, f.ui.windows.get(f.ui.id("Dlg")).?.rect.w });
    }
}
