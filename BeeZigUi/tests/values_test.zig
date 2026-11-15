//! Number fields, choices, disabled widgets, rich tooltips and the edit
//! lifecycle, driven by scripts.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const Shading = enum { wireframe, solid, material_preview, rendered };

const lights = [_]zui.Choice{
    .{ .label = "Point" },
    .{ .label = "Sun" },
    .{ .label = "Spot" },
    .{ .label = "Area", .disabled = "Needs the path tracer" },
};

const App = struct {
    size: f32 = 1,
    count: i32 = 5,
    length: f64 = 2,
    angle: f32 = 0,
    location: [3]f32 = .{ 0, 0, 0 },
    light: usize = 0,
    shading: Shading = .solid,
    mode: usize = 0,
    visible: bool = true,
    pastes: u32 = 0,
    have_clipboard: bool = false,
    // Edit lifecycle counts, as an undo system would see them.
    started: u32 = 0,
    committed: u32 = 0,
    cancelled: u32 = 0,
    context: u32 = 0,

    fn count_(app: *App, r: zui.Interaction) void {
        if (r.started) app.started += 1;
        if (r.committed) app.committed += 1;
        if (r.cancelled) app.cancelled += 1;
        if (r.context_clicked) app.context += 1;
    }

    fn frame(app: *App, ui: *zui.Ui) void {
        app.count_(ui.numberField("Size", &app.size, .{ .min = 0, .max = 10, .step = 0.5 }));
        app.count_(ui.numberField("Count", &app.count, .{ .min = 0, .max = 100 }));
        app.count_(ui.numberField("Length", &app.length, .{ .suffix = " m", .evaluator = &meters }));
        app.count_(ui.angleField("Angle", &app.angle, .{}));
        app.count_(ui.vectorField("Location", &app.location, .{}));
        app.count_(ui.dropdown("Light", &app.light, &lights, .{}));
        app.count_(ui.dropdownEnum("Shading", &app.shading, .{}));
        const modes = [_]zui.Choice{ .{ .label = "Object" }, .{ .label = "Edit" }, .{ .label = "Sculpt", .disabled = "No mesh" } };
        app.count_(ui.segmented("Mode", &app.mode, &modes, .{}));
        app.count_(ui.iconToggle("Visible", &app.visible, .{ .on = .{ .builtin = .check }, .off = .{ .builtin = .close } }));
        ui.pushDisabled(if (app.have_clipboard) null else "Copy something first");
        const paste = ui.button("Paste", .{});
        ui.popDisabled();
        if (paste.clicked) app.pastes += 1;
        ui.tooltipRich(ui.button("Save", .{}), .{ .title = "Save", .shortcut = "Ctrl+S", .body = "Writes the scene to its file, replacing what was there." });
    }
};

const meters: zui.Evaluator = .{ .units = &zui.expr.meters };

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
        f.ui.beginFrame(.{ .width = 700, .height = 600, .dt = dt });
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

test "dragging a number field is one edit" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("drag number:Size by 60 0");
    // 0.05 per unit by default (a tenth of the step); the threshold eats nothing.
    try testing.expectApproxEqAbs(@as(f32, 4), f.app.size, 0.06);
    try testing.expectEqual(@as(u32, 1), f.app.started);
    try testing.expectEqual(@as(u32, 1), f.app.committed);
    try testing.expectEqual(@as(u32, 0), f.app.cancelled);
    try f.play("drag number:Size by 400 0");
    try testing.expectEqual(@as(f32, 10), f.app.size);
}

test "typing values and expressions" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click number:Size
        \\type 2*pi/2
        \\key enter
        \\expect number:Size = 3.142
        \\click number:Length
        \\type 25mm + 1cm
        \\key enter
        \\expect number:Length = 0.035 m
        \\click number:Angle
        \\type 90
        \\key enter
        \\click number:Count
        \\type 7.6
        \\key enter
        \\expect number:Count = 8
    );
    try testing.expectApproxEqAbs(std.math.pi / 2.0, f.app.angle, 1e-5);
    try testing.expectEqual(@as(i32, 8), f.app.count);
    try testing.expectEqual(@as(u32, 4), f.app.committed);
}

test "Escape and nonsense leave the value alone" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click number:Size
        \\type 7
        \\key escape
        \\expect number:Size = 1
        \\click number:Size
        \\type banana
        \\key enter
        \\expect number:Size = 1
    );
    try testing.expectEqual(@as(u32, 0), f.app.committed);
    try testing.expectEqual(@as(u32, 2), f.app.cancelled);
}

test "arrows step a focused field; vectors edit one component" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\key tab
        \\expect number:Size focused
        \\key right
        \\key shift+right
        \\expect number:Size = 6.5
        \\drag number:Location Y by 40 0
    );
    try testing.expectEqual(@as(f32, 0), f.app.location[0]);
    try testing.expect(f.app.location[1] > 0.3);
}

test "drop-down lists: pick, skip disabled items, keys, enums" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click dropdown:Light
        \\expect Light > choice:Area disabled
        \\click choice:Spot
        \\expect dropdown:Light = Spot
        \\click dropdown:Shading
        \\click choice:Material preview
        \\expect dropdown:Shading = Material preview
    );
    try testing.expectEqual(@as(usize, 2), f.app.light);
    try testing.expectEqual(Shading.material_preview, f.app.shading);
    // From the keyboard: Down skips the disabled Area, which is last.
    f.ui.setFocus(f.ui.id("Light"));
    try f.play(
        \\key down
        \\expect dropdown:Light = Spot
        \\key up
        \\expect dropdown:Light = Sun
    );
}

test "segments and icon toggles" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click segment:Edit
        \\expect segment:Edit = true
        \\expect segment:Sculpt disabled
        \\click segment:Sculpt
        \\expect segment:Edit = true
        \\click toggle:Visible
        \\expect toggle:Visible = false
    );
    try testing.expectEqual(@as(usize, 1), f.app.mode);
    try testing.expect(!f.app.visible);
}

test "a disabled button says why, and its click is reported" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\expect button:Paste disabled
        \\hover button:Paste
        \\wait 1
        \\expect tooltip:Copy something first exists
    );
    try testing.expectEqualStrings("Copy something first", f.ui.findWidget("button:Paste").?.disabled_reason.?);
    try f.play("click button:Paste");
    try testing.expectEqual(@as(u32, 0), f.app.pastes);
    // The script's last frames came after the click; replay it by hand.
    const paste = f.ui.findWidget("button:Paste").?;
    f.ui.input.onMouseMove(.{ .x = paste.rect.x + 4, .y = paste.rect.y + 4 });
    try f.frame(0.016);
    f.ui.input.onMouseButton(.left, true);
    try f.frame(0.016);
    try testing.expectEqualStrings("Copy something first", f.ui.disabledClick().?);
    f.ui.input.onMouseButton(.left, false);
    try f.frame(0.016);
    try testing.expect(f.ui.disabledClick() == null);
    f.app.have_clipboard = true;
    try f.play("click button:Paste");
    try testing.expectEqual(@as(u32, 1), f.app.pastes);
}

test "Tab skips disabled widgets" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("frames 1");
    f.ui.setFocus(f.ui.id("Visible"));
    try f.play(
        \\key tab
        \\expect button:Save focused
    );
}

test "a rich tooltip and a right-click on a field" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\hover button:Save
        \\wait 1
        \\expect tooltip:Save exists
        \\right-click number:Size
    );
    try testing.expectEqual(@as(u32, 1), f.app.context);
    // The request is there for the frame right after the press.
    const size = f.ui.findWidget("number:Size").?;
    f.ui.input.onMouseMove(.{ .x = size.rect.x + 5, .y = size.rect.y + 5 });
    f.ui.input.onMouseButton(.right, true);
    try f.frame(0.016);
    try testing.expectEqual(f.ui.id("Size"), f.ui.contextRequest().?.widget);
    f.ui.input.onMouseButton(.right, false);
    try f.frame(0.016);
    try testing.expect(f.ui.contextRequest() == null);
}

test "a click inside one frame starts typing a number" {
    var font: zui.Font = try .initDefault(testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(testing.allocator, .{ .font = &font });
    defer ui.deinit();
    ui.recording = true;
    var v: f64 = 960;
    for (0..3) |_| {
        ui.beginFrame(.{ .width = 400, .height = 200 });
        _ = ui.numberField("Width", &v, .{});
        _ = try ui.endFrame();
    }
    const r = ui.findWidget("number:Width").?.rect;
    ui.input.onMouseMove(.{ .x = r.x + 10, .y = r.y + r.h / 2 });
    ui.input.onMouseButton(.left, true);
    ui.input.onMouseButton(.left, false);
    ui.beginFrame(.{ .width = 400, .height = 200 });
    _ = ui.numberField("Width", &v, .{});
    _ = try ui.endFrame();
    ui.input.onText("640");
    ui.input.onKeyPress(.enter);
    for (0..2) |_| {
        ui.beginFrame(.{ .width = 400, .height = 200 });
        _ = ui.numberField("Width", &v, .{});
        _ = try ui.endFrame();
    }
    try testing.expectEqual(@as(f64, 640), v);
}
