//! Docking and tabs, driven by scripts and by hand.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const editors = [_]zui.Choice{ .{ .label = "Viewport" }, .{ .label = "Outliner" }, .{ .label = "Console" } };

const App = struct {
    dock: zui.Dock = .init(0),
    changes: zui.DockChanges = .{},
    created: ?zui.AreaId = null,
    tabs: [4][]const u8 = .{ "Modeling", "Shading", "", "" },
    tab_count: usize = 2,
    tab: usize = 0,
    renamed: [32]u8 = undefined,
    renamed_len: usize = 0,
    added: u32 = 0,
    pressed: [8]u32 = @splat(0),

    fn frame(app: *App, ui: *zui.Ui) void {
        const r = ui.tabBar("workspaces", &app.tab, &.{ .{ .label = app.tabs[0] }, .{ .label = app.tabs[1] } }, .{ .addable = true, .renamable = true });
        if (r.add) app.added += 1;
        if (r.rename) |rn| {
            @memcpy(app.renamed[0..rn.text.len], rn.text);
            app.renamed_len = rn.text.len;
        }
        ui.beginDockSpace("dock", &app.dock, .{ .editors = &editors });
        var buffer: [zui.Dock.max_areas]zui.AreaId = undefined;
        for (app.dock.areas(&buffer)) |id| {
            _ = ui.beginArea(id) orelse continue;
            defer ui.endArea();
            ui.areaBody();
            if (ui.button("Press", .{}).clicked) app.pressed[@min(id, 7)] += 1;
            _ = ui.button("Other", .{});
        }
        app.changes = ui.endDockSpace();
        if (app.changes.created) |c| app.created = c;
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
        // Viewport | Outliner, Console below the viewport.
        const out = f.app.dock.split(0, .right, 1).?;
        _ = out;
        _ = f.app.dock.split(0, .bottom, 2).?;
        return f;
    }

    fn destroy(f: *Fixture) void {
        f.ui.deinit();
        f.font.deinit();
        testing.allocator.destroy(f);
    }

    fn frame(f: *Fixture, dt: f32) !void {
        f.ui.beginFrame(.{ .width = 900, .height = 600, .dt = dt });
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

    fn playf(f: *Fixture, comptime fmt: []const u8, args: anytype) !void {
        var b: [512]u8 = undefined;
        try f.play(try std.fmt.bufPrint(&b, fmt, args));
    }

    fn rect(f: *Fixture, name: []const u8) zui.Rect {
        return (f.ui.findWidget(name) orelse std.debug.panic("no {s}", .{name})).rect;
    }
};

test "split, maximize and close from the header buttons" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click Outliner > button:split
        \\expect Viewport exists
    );
    try testing.expectEqual(@as(usize, 4), f.app.dock.dockedCount());
    try testing.expect(f.app.created != null);
    try f.play(
        \\click Console > button:maximize
        \\expect area:Viewport missing
        \\click Console > button:maximize
        \\expect area:Viewport exists
        \\click Console > button:close
        \\expect area:Console missing
    );
    try testing.expectEqual(@as(usize, 3), f.app.dock.dockedCount());
}

test "dragging a header: an edge splits there, the middle swaps" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("frames 2");
    const viewport = f.rect("area:Viewport");
    const header = f.rect("Console > custom:header");
    // Onto the viewport's right edge: the console goes to its right.
    const to = zui.Vec2{ .x = viewport.right() - 10, .y = viewport.y + viewport.h / 2 };
    const from = zui.Vec2{ .x = header.x + header.w * 0.75, .y = header.y + header.h / 2 };
    try f.playf("drag Console > custom:header by {d} {d}", .{ to.x - from.x, to.y - from.y });
    try f.play("frames 2");
    const console = f.rect("area:Console");
    const viewport2 = f.rect("area:Viewport");
    try testing.expect(console.x > viewport2.x);
    try testing.expectApproxEqAbs(console.y, viewport2.y, 1);
    // Onto the middle of the outliner: they swap.
    const outliner = f.rect("area:Outliner");
    try f.play("drag Console > custom:header to area:Outliner");
    try f.play("frames 2");
    try testing.expectApproxEqAbs(outliner.x, f.rect("area:Console").x, 1);
}

test "dragging the corner into a neighbour joins them" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\drag Viewport > custom:corner to area:Console
        \\expect area:Console missing
    );
    try testing.expectEqual(@as(usize, 2), f.app.dock.dockedCount());
    try testing.expect(f.app.changes.closed != null or f.app.dock.dockedCount() == 2);
}

test "float an area, then dock the panel on a guide" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\right-click Console > custom:header
        \\click Area > menu_item:Float Area
        \\frames 2
        \\expect window:Console exists
    );
    try testing.expectEqual(@as(usize, 2), f.app.dock.dockedCount());
    try testing.expectEqual(@as(u8, 1), f.app.dock.floating_count);
    // Drag the panel's title over the outliner and onto its left guide.
    const title = f.rect("window:Console");
    const target = f.rect("area:Outliner");
    const from = zui.Vec2{ .x = title.x + title.w / 2, .y = title.y + title.h / 2 };
    const guide = zui.Vec2{ .x = target.x + target.w / 2 - 32, .y = target.y + target.h / 2 };
    try f.playf("drag window:Console by {d} {d}", .{ guide.x - from.x, guide.y - from.y });
    try f.play("frames 2");
    try testing.expectEqual(@as(u8, 0), f.app.dock.floating_count);
    const console = f.rect("area:Console");
    const outliner = f.rect("area:Outliner");
    try testing.expect(console.x < outliner.x);
    try testing.expectApproxEqAbs(console.y, outliner.y, 1);
}

test "F6 cycles the active area, and Tab stays inside it" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\key f6
        \\expect area:Viewport = active
        \\key f6
        \\expect area:Console = active
        \\key tab
        \\expect Console > dropdown:editor focused
        \\key tab
        \\key tab
        \\key tab
        \\key tab
        \\expect Console > button:Press focused
        \\key tab
        \\expect Console > button:Other focused
        \\key tab
        \\expect Console > dropdown:editor focused
    );
}

test "a layout survives writing and reading" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("click Console > button:split");
    var b: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&b);
    try f.app.dock.write(&w);
    f.app.dock = try zui.Dock.read(w.buffered());
    try f.play("frames 2");
    try testing.expectEqual(@as(usize, 4), f.app.dock.dockedCount());
}

test "workspace tabs: switch, rename by double-click, add" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click tab:Shading
        \\expect tab:Shading = true
        \\double-click tab:Modeling
        \\key ctrl+a
        \\type Sculpt
        \\key enter
        \\click button:add
    );
    // The double-click on Modeling chose it, too.
    try testing.expectEqual(@as(usize, 0), f.app.tab);
    try testing.expectEqualStrings("Sculpt", f.app.renamed[0..f.app.renamed_len]);
    try testing.expectEqual(@as(u32, 1), f.app.added);
}

test "a panel's Dock button puts it back beside the area under it" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\right-click Console > custom:header
        \\click Area > menu_item:Float Area
        \\expect window:Console exists
        \\click Console > button:dock
        \\expect window:Console missing
    );
    try testing.expectEqual(@as(u8, 0), f.app.dock.floating_count);
    try testing.expectEqual(@as(usize, 3), f.app.dock.dockedCount());
}
