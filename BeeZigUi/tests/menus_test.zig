//! Menus, the command palette and shortcut fields, driven by scripts.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const commands = [_]zui.PaletteCommand{
    .{ .label = "Save", .shortcut = "Ctrl+S" },
    .{ .label = "Save As..." },
    .{ .label = "Select All", .category = "Edit" },
    .{ .label = "Subdivide", .category = "Mesh", .disabled = "Enter Edit mode first" },
    .{ .label = "Quit", .shortcut = "Ctrl+Q" },
};

const App = struct {
    picked: [64]u8 = undefined,
    picked_len: usize = 0,
    snap: bool = false,
    dirty: bool = false,
    palette_open: bool = false,
    palette_pick: ?usize = null,
    save_key: ?zui.Shortcut = zui.Shortcut.parse("ctrl+s"),

    fn pick(app: *App, what: []const u8) void {
        @memcpy(app.picked[0..what.len], what);
        app.picked_len = what.len;
    }

    fn picked_(app: *const App) []const u8 {
        return app.picked[0..app.picked_len];
    }

    fn frame(app: *App, ui: *zui.Ui) void {
        ui.beginMenuBar();
        if (ui.beginMenu("File")) {
            defer ui.endMenu();
            if (ui.menuItem("New", .{ .shortcut = "Ctrl+N" })) app.pick("New");
            if (ui.beginSubmenu("Open Recent", .{})) {
                defer ui.endMenu();
                if (ui.menuItem("a.bee", .{})) app.pick("a.bee");
                if (ui.menuItem("b.bee", .{})) app.pick("b.bee");
            }
            ui.menuSeparator();
            if (ui.menuItem("Save", .{ .shortcut = "Ctrl+S", .disabled = if (app.dirty) null else "Nothing to save" })) app.pick("Save");
            if (ui.menuItem("Quit", .{})) app.pick("Quit");
        }
        if (ui.beginMenu("Edit")) {
            defer ui.endMenu();
            if (ui.menuItem("Undo", .{})) app.pick("Undo");
            if (ui.menuItem("Redo", .{})) app.pick("Redo");
            if (ui.menuItem("Snap", .{ .checked = app.snap })) app.snap = !app.snap;
        }
        if (ui.beginMenu("View")) {
            defer ui.endMenu();
            for (0..60) |i| {
                var b: [16]u8 = undefined;
                const name = std.fmt.bufPrint(&b, "Item {d}", .{i}) catch unreachable;
                if (ui.menuItem(name, .{})) app.pick(name);
            }
        }
        ui.endMenuBar();

        const target = ui.button("Target", .{});
        if (ui.beginContextMenu(target, "Target menu")) {
            defer ui.endMenu();
            if (ui.menuItem("Delete", .{ .shortcut = "X" })) app.pick("Delete");
        }
        _ = ui.shortcutField("Save key", &app.save_key, .{});
        if (ui.commandPalette("palette", &app.palette_open, &commands, .{})) |i| app.palette_pick = i;
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
        f.ui.beginFrame(.{ .width = 640, .height = 420, .dt = dt });
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

test "click a menu, pick an item, and the menus close" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click menu:File
        \\click File > menu_item:New
        \\expect menu_item:New missing
    );
    try testing.expectEqualStrings("New", f.app.picked_());
}

test "hovering the bar switches menus; submenus open on hover" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click menu:File
        \\hover menu:Edit
        \\expect menu_item:Undo exists
        \\expect menu_item:New missing
        \\hover menu:File
        \\hover menu:Open Recent
        \\click Open Recent > menu_item:b.bee
    );
    try testing.expectEqualStrings("b.bee", f.app.picked_());
}

test "the keyboard: F10, arrows, Right into a submenu, Alt+letter" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\key f10
        \\expect File > menu_item:New exists
        \\key enter
    );
    try testing.expectEqualStrings("New", f.app.picked_());
    try f.play(
        \\key f10
        \\key down
        \\key right
        \\expect menu_item:a.bee exists
        \\key down
        \\key enter
    );
    try testing.expectEqualStrings("b.bee", f.app.picked_());
    try f.play(
        \\key alt+e
        \\key down
        \\key enter
    );
    try testing.expectEqualStrings("Redo", f.app.picked_());
    try f.play(
        \\key f10
        \\key right
        \\expect menu_item:Undo exists
        \\key left
        \\expect menu_item:New exists
        \\key escape
        \\expect menu_item:New missing
    );
}

test "Enter on a submenu's row opens it, and picks nothing in it" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\key f10
        \\key down
        \\key enter
        \\expect menu_item:a.bee exists
        \\expect menu_item:New exists
    );
    try testing.expectEqual(@as(usize, 0), f.app.picked_len);
}

test "Escape closes one level at a time" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click menu:File
        \\hover menu:Open Recent
        \\expect menu_item:a.bee exists
        \\key escape
        \\expect menu_item:a.bee missing
        \\expect menu_item:New exists
    );
}

test "disabled and checked items" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click menu:File
        \\expect menu_item:Save disabled
        \\click menu_item:Save
        \\expect menu_item:New exists
        \\key escape
        \\click menu:Edit
        \\expect menu_item:Snap = false
        \\click menu_item:Snap
        \\click menu:Edit
        \\expect menu_item:Snap = true
    );
    try testing.expectEqual(@as(usize, 0), f.app.picked_len);
    try testing.expect(f.app.snap);
}

test "a menu taller than the window scrolls" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\click menu:View
        \\expect menu_item:Item 0 exists
        \\expect menu_item:Item 59 missing
        \\scroll View > menu_item:Item 5 -40
        \\expect menu_item:Item 59 exists
        \\click menu_item:Item 59
    );
    try testing.expectEqualStrings("Item 59", f.app.picked_());
}

test "a context menu opens where the right button went down" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\right-click button:Target
        \\click Target menu > menu_item:Delete
    );
    try testing.expectEqualStrings("Delete", f.app.picked_());
}

test "the command palette filters, skips nothing, and runs the pick" {
    const f = try Fixture.create();
    defer f.destroy();
    f.app.palette_open = true;
    try f.play(
        \\expect command:Quit exists
        \\type sa
        \\expect command:Quit missing
        \\expect command:Save exists
        \\key down
        \\key enter
    );
    try testing.expectEqual(@as(?usize, 1), f.app.palette_pick);
    try testing.expect(!f.app.palette_open);
    f.app.palette_open = true;
    try f.play(
        \\type subd
        \\expect command:Subdivide disabled
        \\key enter
        \\expect command:Subdivide exists
        \\key escape
        \\expect command:Subdivide missing
    );
    try testing.expect(!f.app.palette_open);
    try testing.expectEqual(@as(?usize, 1), f.app.palette_pick);
}

test "a shortcut field takes the next keys" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\expect shortcut:Save key = Ctrl+S
        \\click shortcut:Save key
        \\expect shortcut:Save key = Press a key...
        \\key ctrl+shift+e
        \\expect shortcut:Save key = Ctrl+Shift+E
        \\click shortcut:Save key
        \\key escape
        \\expect shortcut:Save key = Ctrl+Shift+E
        \\click shortcut:Save key
        \\key backspace
        \\expect shortcut:Save key = None
    );
    try testing.expect(f.app.save_key == null);
}

/// A menu of a bar the app draws itself (BeeModel's), opened by a press the
/// app took: held until that button is let go.
const Held = struct {
    open_at: ?zui.Vec2 = null,
    hold: bool = true,
    index: u32 = 0,
    picked: ?[]const u8 = null,
    bar_request: ?u32 = null,

    fn frame(h: *Held, ui: *zui.Ui) void {
        if (h.open_at) |at| {
            ui.openPopupAt("held menu", .{ .x = at.x, .y = at.y });
            if (h.hold) ui.holdMenu(at);
            h.open_at = null;
        }
        ui.externalBar(h.index, 3);
        if (ui.beginPopupMenuSized("held menu", 230)) {
            defer ui.endMenu();
            for ([_][]const u8{ "One", "Two", "Three" }) |name| {
                if (ui.menuItem(name, .{})) h.picked = name;
            }
            if (ui.beginSubmenu("More", .{})) {
                defer ui.endMenu();
                if (ui.menuItem("Four", .{})) h.picked = "Four";
            }
        }
        if (ui.takeBarRequest()) |r| h.bar_request = r;
    }
};

fn heldFrame(ui: *zui.Ui, h: *Held) !void {
    ui.beginFrame(.{ .width = 640, .height = 420, .dt = 1.0 / 60.0 });
    h.frame(ui);
    _ = try ui.endFrame();
}

fn itemRect(ui: *zui.Ui, label: []const u8) ?zui.Rect {
    for (ui.widgets()) |w| if (w.kind == .menu_item and std.mem.eql(u8, w.label, label)) return w.rect;
    return null;
}

test "a held menu: the release over an item picks it, a right-click's own release picks nothing" {
    var font = try zui.Font.initDefault(testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(testing.allocator, .{ .font = &font });
    defer ui.deinit();
    ui.recording = true;
    var h: Held = .{};

    // A right-click at (100, 100) opens it there; letting go where it was
    // pressed picks nothing, though "One" is under the pointer.
    ui.input.onMouseMove(.{ .x = 100, .y = 100 });
    h.open_at = .{ .x = 100, .y = 100 };
    try heldFrame(&ui, &h);
    try heldFrame(&ui, &h); // (sized to its content)
    const one = itemRect(&ui, "One").?;
    ui.input.onMouseMove(.{ .x = 101, .y = 101 });
    ui.input.onMouseButton(.right, false);
    try heldFrame(&ui, &h);
    try testing.expect(h.picked == null);
    try testing.expect(itemRect(&ui, "One") != null);

    // Opened again, held; dragged onto "Two" and let go: picked, closed.
    ui.closeAllPopups();
    try heldFrame(&ui, &h);
    ui.input.onMouseMove(.{ .x = 100, .y = 100 });
    h.open_at = .{ .x = 100, .y = 100 };
    try heldFrame(&ui, &h);
    try heldFrame(&ui, &h);
    const two = itemRect(&ui, "Two").?;
    ui.input.onMouseMove(.{ .x = two.x + 10, .y = two.y + two.h / 2 });
    try heldFrame(&ui, &h);
    ui.input.onMouseButton(.left, false);
    try heldFrame(&ui, &h);
    try testing.expectEqualStrings("Two", h.picked.?);
    try heldFrame(&ui, &h);
    try testing.expect(itemRect(&ui, "One") == null);

    // Not held (opened by a click that ended): a release picks nothing.
    h.picked = null;
    h.hold = false;
    h.open_at = .{ .x = 100, .y = 100 };
    try heldFrame(&ui, &h);
    try heldFrame(&ui, &h);
    ui.input.onMouseMove(.{ .x = one.x + 10, .y = one.y + one.h / 2 });
    try heldFrame(&ui, &h);
    ui.input.onMouseButton(.left, false);
    try heldFrame(&ui, &h);
    try testing.expect(h.picked == null);
    try testing.expect(itemRect(&ui, "One") != null);
    // (its width: at least the one asked for)
    try testing.expect(one.w >= 230 - 2 * ui.style.popup_padding - 1);

    // The keys walk the app's bar: Right on an item without a submenu, Left.
    ui.input.onKeyPress(.down);
    try heldFrame(&ui, &h);
    ui.input.onKeyPress(.right);
    try heldFrame(&ui, &h);
    try testing.expectEqual(@as(?u32, 1), h.bar_request);
    h.bar_request = null;
    ui.input.onKeyPress(.left);
    try heldFrame(&ui, &h);
    try testing.expectEqual(@as(?u32, 2), h.bar_request);
}

test "a right press in an open menu, let go over an item: picked" {
    var font = try zui.Font.initDefault(testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(testing.allocator, .{ .font = &font });
    defer ui.deinit();
    ui.recording = true;
    var h: Held = .{ .hold = false };
    h.open_at = .{ .x = 100, .y = 100 };
    try heldFrame(&ui, &h);
    try heldFrame(&ui, &h);
    const one = itemRect(&ui, "One").?;
    const three = itemRect(&ui, "Three").?;
    ui.input.onMouseMove(.{ .x = one.x + 10, .y = one.y + one.h / 2 });
    try heldFrame(&ui, &h);
    ui.input.onMouseButton(.right, true);
    try heldFrame(&ui, &h);
    try testing.expect(h.picked == null);
    ui.input.onMouseMove(.{ .x = three.x + 10, .y = three.y + three.h / 2 });
    try heldFrame(&ui, &h);
    ui.input.onMouseButton(.right, false);
    try heldFrame(&ui, &h);
    try testing.expectEqualStrings("Three", h.picked.?);
}

/// The app's own ranking: only "Quit" and "Save" match "zz", Quit first.
fn zzScore(query: []const u8, index: usize) ?f32 {
    if (!std.mem.eql(u8, query, "zz")) return 0;
    return switch (index) {
        4 => 2,
        0 => 1,
        else => null,
    };
}

test "the palette ranks by the app's score, and shows a detail" {
    var font = try zui.Font.initDefault(testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(testing.allocator, .{ .font = &font });
    defer ui.deinit();
    ui.recording = true;
    var open = true;
    const cmds = [_]zui.PaletteCommand{
        .{ .label = "Save", .detail = "file.save" },
        .{ .label = "Save As..." },
        .{ .label = "Select All" },
        .{ .label = "Subdivide" },
        .{ .label = "Quit" },
    };
    var picked: ?usize = null;
    for (0..3) |_| {
        ui.beginFrame(.{ .width = 640, .height = 420, .dt = 1.0 / 60.0 });
        if (ui.commandPalette("p", &open, &cmds, .{ .score = zzScore })) |i| picked = i;
        _ = try ui.endFrame();
    }
    ui.input.onText("zz");
    for (0..2) |_| {
        ui.beginFrame(.{ .width = 640, .height = 420, .dt = 1.0 / 60.0 });
        if (ui.commandPalette("p", &open, &cmds, .{ .score = zzScore })) |i| picked = i;
        _ = try ui.endFrame();
    }
    var shown: [8][]const u8 = undefined;
    var n: usize = 0;
    for (ui.widgets()) |w| if (w.kind == .command) {
        shown[n] = w.label;
        n += 1;
    };
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("Quit", shown[0]);
    try testing.expectEqualStrings("Save", shown[1]);
    ui.input.onKeyPress(.enter);
    ui.beginFrame(.{ .width = 640, .height = 420, .dt = 1.0 / 60.0 });
    if (ui.commandPalette("p", &open, &cmds, .{ .score = zzScore })) |i| picked = i;
    _ = try ui.endFrame();
    try testing.expectEqual(@as(?usize, 4), picked);
    try testing.expect(!open);
}
