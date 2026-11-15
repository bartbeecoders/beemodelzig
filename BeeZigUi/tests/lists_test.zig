//! Lists, trees, drag and drop, tiles, file drops and sideways scrolling.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const max = 8192;

const Obj = struct {
    name: [24]u8 = undefined,
    len: usize = 0,
    parent: ?u32 = null,
    open: bool = true,
    visible: bool = true,

    fn label(o: *const Obj) []const u8 {
        return o.name[0..o.len];
    }
};

const App = struct {
    objs: [max]Obj = undefined,
    count: usize = 0,
    // The tree flattened in display order, rebuilt each frame.
    order: [max]u32 = undefined,
    depth: [max]u32 = undefined,
    shown: usize = 0,
    selected: [max]bool = @splat(false),
    state: zui.ListState = .{},
    deleted: bool = false,
    tiles_selected: [40]bool = @splat(false),
    tiles_state: zui.ListState = .{},
    opened_tile: ?usize = null,
    dropped: [128]u8 = undefined,
    dropped_len: usize = 0,
    rows_described: usize = 0,

    fn add(app: *App, name: []const u8, parent: ?u32) u32 {
        const i: u32 = @intCast(app.count);
        app.objs[i] = .{ .parent = parent };
        app.objs[i].len = name.len;
        @memcpy(app.objs[i].name[0..name.len], name);
        app.count += 1;
        return i;
    }

    fn small(app: *App) void {
        _ = app.add("Camera", null);
        _ = app.add("Cube", null);
        _ = app.add("Light", null);
        const chair = app.add("Chair", null);
        for (1..5) |k| {
            var b: [8]u8 = undefined;
            _ = app.add(std.fmt.bufPrint(&b, "Leg {d}", .{k}) catch unreachable, chair);
        }
        _ = app.add("Table", null);
    }

    fn big(app: *App) void {
        for (0..max) |i| {
            var b: [24]u8 = undefined;
            _ = app.add(std.fmt.bufPrint(&b, "Object {d}", .{i}) catch unreachable, null);
        }
    }

    fn flatten(app: *App, parent: ?u32, d: u32) void {
        for (app.objs[0..app.count], 0..) |o, i| {
            if (o.parent != parent) continue;
            app.order[app.shown] = @intCast(i);
            app.depth[app.shown] = d;
            app.shown += 1;
            if (o.open) app.flatten(@intCast(i), d + 1);
        }
    }

    fn hasChildren(app: *const App, i: u32) bool {
        for (app.objs[0..app.count]) |o| if (o.parent == i) return true;
        return false;
    }

    fn isAncestor(app: *const App, a: u32, of: u32) bool {
        var p = app.objs[of].parent;
        while (p) |x| : (p = app.objs[x].parent) if (x == a) return true;
        return false;
    }

    fn frame(app: *App, ui: *zui.Ui) void {
        app.shown = 0;
        app.flatten(null, 0);
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start });
        ui.beginVertical(.{ .width = .px(320), .height = .fill });
        var list = ui.beginList("outliner", app.selected[0..app.shown], &app.state, .{});
        app.rows_described = 0;
        for (list.first..list.end) |row| {
            const i = app.order[row];
            const o = &app.objs[i];
            app.rows_described += 1;
            ui.beginRow(&list, row, .{ .label = o.label(), .depth = app.depth[row], .fold = if (app.hasChildren(i)) o.open else null, .renamable = true });
            var b: [40]u8 = undefined;
            _ = ui.iconToggle(std.fmt.bufPrint(&b, "{s} visible", .{o.label()}) catch "visible", &o.visible, .{ .on = .{ .builtin = .eye }, .off = .{ .builtin = .eye_off } });
            const r = ui.endRow(&list);
            if (r.fold_clicked) o.open = !o.open;
            if (r.renamed) |name| {
                o.len = @min(name.len, o.name.len);
                @memcpy(o.name[0..o.len], name[0..o.len]);
            }
            _ = ui.dragSource(r.interaction, .{ .kind = "object", .data = i, .label = o.label() });
            if (ui.dropZone(r.rect, "object")) |drop| {
                const dragged: u32 = @intCast(drop.data);
                if (dragged == i or app.isAncestor(dragged, i)) {
                    ui.refuseDrop("It would be its own parent");
                } else {
                    var hb: [48]u8 = undefined;
                    ui.dropHint(std.fmt.bufPrint(&hb, "Child of {s}", .{o.label()}) catch "Child");
                    if (drop.released) app.objs[dragged].parent = i;
                }
            }
        }
        const lr = ui.endList(&list);
        if (lr.delete) app.deleted = true;
        if (ui.dropZone(lr.empty, "object")) |drop| {
            ui.dropHint("No parent");
            if (drop.released) app.objs[@intCast(drop.data)].parent = null;
        }
        ui.endVertical();

        ui.beginVertical(.{ .width = .fill, .height = .fill });
        var tiles = ui.beginTiles("assets", &app.tiles_selected, &app.tiles_state, .{ .height = .px(220), .tile_width = 100, .tile_height = 90 });
        for (tiles.list.first..tiles.list.end) |t| {
            var b: [16]u8 = undefined;
            const r = ui.tile(&tiles, t, .{ .label = std.fmt.bufPrint(&b, "Asset {d}", .{t}) catch "Asset", .icon = .{ .builtin = .dot } });
            if (r.activated) app.opened_tile = t;
        }
        _ = ui.endTiles(&tiles);
        if (ui.fileDrop(ui.lastRect())) |d| {
            var files = d;
            while (files.next()) |path| {
                @memcpy(app.dropped[0..path.len], path);
                app.dropped_len = path.len;
            }
        }
        ui.beginScrollArea("wide", .{ .height = .px(80), .horizontal = true });
        ui.beginHorizontal(.{});
        for (0..30) |k| ui.labelf("Column {d}", .{k}, .{});
        ui.endHorizontal();
        ui.endScrollArea();
        ui.endVertical();
        ui.endHorizontal();
    }
};

const Fixture = struct {
    font: zui.Font,
    ui: zui.Ui,
    app: App = .{},

    fn create(big: bool) !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .font = try .initDefault(testing.allocator), .ui = undefined };
        f.ui = .init(testing.allocator, .{ .font = &f.font });
        if (big) f.app.big() else f.app.small();
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
};

test "click, Ctrl+click and Shift+click select rows" {
    const f = try Fixture.create(false);
    defer f.destroy();
    try f.play(
        \\click row:Cube
        \\expect row:Cube = true
        \\click row:Light
        \\expect row:Cube = false
        \\click row:Camera
        \\key ctrl+down
        \\expect row:Cube = false
    );
    try f.play("frames 1");
    // Ctrl and Shift through the Input, as the script player sends clicks
    // without modifiers.
    const cube = f.ui.findWidget("row:Cube").?.rect;
    const table = f.ui.findWidget("row:Table").?.rect;
    f.ui.input.modifiers = .{ .ctrl = true };
    try clickAt(f, cube);
    f.ui.input.modifiers = .{ .shift = true };
    try clickAt(f, table);
    f.ui.input.modifiers = .{};
    try f.play("frames 1");
    // Camera (the anchor, then Ctrl+click Cube made Cube the anchor) to Table.
    try testing.expect(!f.app.selected[0]);
    for (1..f.app.shown) |r| try testing.expect(f.app.selected[r]);
}

fn clickAt(f: *Fixture, r: zui.Rect) !void {
    f.ui.input.onMouseMove(.{ .x = r.x + 30, .y = r.y + r.h / 2 });
    try f.frame(0.016);
    f.ui.input.onMouseButton(.left, true);
    try f.frame(0.016);
    f.ui.input.onMouseButton(.left, false);
    try f.frame(0.016);
}

test "the keyboard moves, extends, selects all, renames and deletes" {
    const f = try Fixture.create(false);
    defer f.destroy();
    try f.play(
        \\click row:Camera
        \\key down
        \\expect row:Cube = true
        \\key shift+down
        \\expect row:Cube = true
        \\expect row:Light = true
        \\key ctrl+a
        \\expect row:Table = true
        \\key down
        \\key f2
        \\key ctrl+a
        \\type Lamp
        \\key enter
        \\expect row:Lamp exists
        \\key delete
    );
    try testing.expect(f.app.deleted);
}

test "double-click renames; folding hides children" {
    const f = try Fixture.create(false);
    defer f.destroy();
    try f.play(
        \\double-click row:Cube
        \\key ctrl+a
        \\type Box
        \\key enter
        \\expect row:Box exists
        \\expect row:Leg 1 exists
        \\click custom:Chair fold
        \\expect row:Leg 1 missing
        \\click toggle:Light visible
        \\expect toggle:Light visible = false
    );
    try testing.expect(!f.app.objs[2].visible);
}

test "drag a row onto another to parent it; loops are refused; empty space frees" {
    const f = try Fixture.create(false);
    defer f.destroy();
    try f.play("drag row:Leg 1 to row:Table");
    try testing.expectEqual(@as(?u32, 8), f.app.objs[4].parent);
    try f.play("drag row:Chair to row:Leg 2");
    try testing.expectEqual(@as(?u32, null), f.app.objs[3].parent);
    try f.play("drag row:Leg 2 to list:list");
    try testing.expectEqual(@as(?u32, null), f.app.objs[5].parent);
}

test "the drag label says what letting go would do" {
    const f = try Fixture.create(false);
    defer f.destroy();
    try f.play("frames 2");
    const from = f.ui.findWidget("row:Cube").?.rect;
    const to = f.ui.findWidget("row:Light").?.rect;
    f.ui.input.onMouseMove(.{ .x = from.x + 40, .y = from.y + 5 });
    try f.frame(0.016);
    f.ui.input.onMouseButton(.left, true);
    try f.frame(0.016);
    f.ui.input.onMouseMove(.{ .x = to.x + 40, .y = to.y + 5 });
    try f.frame(0.016);
    try f.frame(0.016);
    try testing.expect(f.ui.dragging() != null);
    try testing.expect(f.ui.findWidget("drag:Cube") != null);
    try testing.expectEqual(zui.Cursor.move, f.ui.cursor);
    f.ui.input.onKeyPress(.escape);
    try f.frame(0.016);
    try testing.expect(f.ui.dragging() == null);
    f.ui.input.onMouseButton(.left, false);
    try f.frame(0.016);
    try testing.expectEqual(@as(?u32, null), f.app.objs[1].parent);
}

test "8192 rows: only the visible ones are described, and scrolling works" {
    const f = try Fixture.create(true);
    defer f.destroy();
    try f.play(
        \\expect row:Object 0 exists
        \\expect row:Object 8000 missing
        \\click row:Object 2
        \\key end
        \\expect row:Object 8191 exists
        \\expect row:Object 0 missing
    );
    try testing.expect(f.app.rows_described < 40);
    try testing.expect(f.app.selected[8191]);
}

test "tiles: click, arrows, double-click" {
    const f = try Fixture.create(false);
    defer f.destroy();
    try f.play(
        \\click tile:Asset 0
        \\key right
        \\expect tile:Asset 1 = true
        \\key down
        \\expect tile:Asset 1 = false
        \\double-click tile:Asset 3
    );
    try testing.expectEqual(@as(?usize, 3), f.app.opened_tile);
}

test "files dropped onto the tile grid arrive there" {
    const f = try Fixture.create(false);
    defer f.destroy();
    try f.play("frames 2");
    const grid = f.ui.findWidget("list:tiles").?.rect;
    f.ui.input.onFileDrop("/home/me/textures/brick.png", .{ .x = grid.x + 20, .y = grid.y + 20 });
    try f.frame(0.016);
    try testing.expectEqualStrings("/home/me/textures/brick.png", f.app.dropped[0..f.app.dropped_len]);
    // Dropped elsewhere: not the grid's.
    f.app.dropped_len = 0;
    f.ui.input.onFileDrop("/x.png", .{ .x = 5, .y = 590 });
    try f.frame(0.016);
    try testing.expectEqual(@as(usize, 0), f.app.dropped_len);
}

test "a wide area scrolls sideways with Shift+wheel" {
    const f = try Fixture.create(false);
    defer f.destroy();
    try f.play(
        \\expect label:Column 0 exists
        \\expect label:Column 29 missing
    );
    const area = f.ui.findWidget("scroll_area:wide").?.rect;
    f.ui.input.onMouseMove(.{ .x = area.x + 20, .y = area.y + 20 });
    f.ui.input.modifiers = .{ .shift = true };
    for (0..20) |_| {
        f.ui.input.onScroll(.{ .y = -3 });
        try f.frame(0.016);
    }
    f.ui.input.modifiers = .{};
    try f.play("frames 2");
    try testing.expect(f.ui.findWidget("label:Column 29") != null);
    try testing.expect(f.ui.findWidget("label:Column 0") == null);
}
