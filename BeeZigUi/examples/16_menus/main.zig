//! Phase 16 demo: a menu bar like BeeModel's, submenus, checked and greyed
//! items, a context menu, F3 command search over every item, and a small
//! keymap whose shortcuts you can change.
//!
//! Try: F10 or Alt+F and the arrow keys; hover across the bar; F3 and type
//! "sub" or "lc"; right-click the big area; click a shortcut and press keys.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const Item = struct {
    label: []const u8,
    shortcut: []const u8 = "",
    disabled: ?[]const u8 = null,
    tooltip: []const u8 = "",
    /// Items of a submenu; empty for a plain item.
    sub: []const Item = &.{},
    separator_before: bool = false,
};

const not_ported = "Not in the port yet";

const menus = [_]struct { name: []const u8, items: []const Item }{
    .{ .name = "File", .items = &.{
        .{ .label = "New", .shortcut = "Ctrl+N", .tooltip = "Starts an empty scene." },
        .{ .label = "Open...", .shortcut = "Ctrl+O" },
        .{ .label = "Open Recent", .sub = &.{ .{ .label = "chair.bee" }, .{ .label = "house.bee" }, .{ .label = "robot.bee" } } },
        .{ .label = "Save", .shortcut = "Ctrl+S", .separator_before = true },
        .{ .label = "Save As...", .shortcut = "Ctrl+Shift+S" },
        .{ .label = "Import", .sub = &.{ .{ .label = "OBJ..." }, .{ .label = "STL..." }, .{ .label = "glTF...", .disabled = not_ported } } },
        .{ .label = "Export", .sub = &.{ .{ .label = "OBJ..." }, .{ .label = "STL..." }, .{ .label = "STEP...", .disabled = not_ported } } },
        .{ .label = "Quit", .shortcut = "Ctrl+Q", .separator_before = true },
    } },
    .{ .name = "Edit", .items = &.{
        .{ .label = "Undo", .shortcut = "Ctrl+Z" },
        .{ .label = "Redo", .shortcut = "Ctrl+Shift+Z" },
        .{ .label = "Undo History", .separator_before = true },
        .{ .label = "Preferences...", .shortcut = "Ctrl+," },
    } },
    .{ .name = "View", .items = &.{
        .{ .label = "Frame Selected", .shortcut = "Numpad ." },
        .{ .label = "Camera View", .shortcut = "Numpad 0" },
        .{ .label = "Orthographic", .shortcut = "Numpad 5" },
        .{ .label = "Theme", .sub = &.{ .{ .label = "Dark" }, .{ .label = "Light" }, .{ .label = "High Contrast", .disabled = not_ported } } },
    } },
    .{ .name = "Select", .items = &.{
        .{ .label = "All", .shortcut = "A" },
        .{ .label = "None", .shortcut = "Alt+A" },
        .{ .label = "Invert", .shortcut = "Ctrl+I" },
        .{ .label = "Box Select", .shortcut = "B" },
        .{ .label = "Select Linked", .shortcut = "Ctrl+L" },
    } },
    .{ .name = "Add", .items = &.{
        .{ .label = "Mesh", .sub = &.{ .{ .label = "Cube" }, .{ .label = "UV Sphere" }, .{ .label = "Cylinder" }, .{ .label = "Cone" }, .{ .label = "Torus" }, .{ .label = "Plane" } } },
        .{ .label = "Light", .sub = &.{ .{ .label = "Point" }, .{ .label = "Sun" }, .{ .label = "Spot" }, .{ .label = "Area" } } },
        .{ .label = "Camera" },
        .{ .label = "Text", .disabled = not_ported },
    } },
    .{ .name = "Mesh", .items = &.{
        .{ .label = "Extrude", .shortcut = "E", .disabled = "Enter Edit mode first" },
        .{ .label = "Inset", .shortcut = "I", .disabled = "Enter Edit mode first" },
        .{ .label = "Loop Cut and Slide", .shortcut = "Ctrl+R", .disabled = "Enter Edit mode first" },
        .{ .label = "Bevel", .shortcut = "Ctrl+B", .disabled = "Enter Edit mode first" },
        .{ .label = "Subdivide", .disabled = "Enter Edit mode first" },
        .{ .label = "Merge", .shortcut = "M", .disabled = "Enter Edit mode first" },
    } },
    .{ .name = "Help", .items = &.{
        .{ .label = "Shortcuts", .shortcut = "F1" },
        .{ .label = "About" },
    } },
};

/// Every leaf item as a palette command, "Menu > Item".
const all_commands = blk: {
    var n = 0;
    for (menus) |m| for (m.items) |it| {
        n += if (it.sub.len > 0) it.sub.len else 1;
    };
    var out: [n]zui.PaletteCommand = undefined;
    var i = 0;
    for (menus) |m| for (m.items) |it| {
        if (it.sub.len > 0) {
            for (it.sub) |s| {
                out[i] = .{ .label = s.label, .category = m.name ++ " > " ++ it.label, .shortcut = s.shortcut, .disabled = s.disabled };
                i += 1;
            }
        } else {
            out[i] = .{ .label = it.label, .category = m.name, .shortcut = it.shortcut, .disabled = it.disabled, .tooltip = it.tooltip };
            i += 1;
        }
    };
    const final = out;
    break :blk final;
};

const Binding = struct { name: []const u8, key: ?zui.Shortcut };

const App = struct {
    last: [96]u8 = undefined,
    last_len: usize = 0,
    show_grid: bool = true,
    show_stats: bool = false,
    palette: bool = false,
    keymap: [4]Binding = .{
        .{ .name = "Search commands", .key = zui.Shortcut.parse("f3") },
        .{ .name = "Save", .key = zui.Shortcut.parse("ctrl+s") },
        .{ .name = "Undo", .key = zui.Shortcut.parse("ctrl+z") },
        .{ .name = "Toggle grid", .key = zui.Shortcut.parse("shift+g") },
    },

    fn ran(app: *App, comptime fmt: []const u8, args: anytype) void {
        const t = std.fmt.bufPrint(&app.last, fmt, args) catch "";
        app.last_len = t.len;
    }

    fn items(app: *App, ui: *zui.Ui, list: []const Item, path: []const u8) void {
        for (list) |it| {
            if (it.separator_before) ui.menuSeparator();
            if (it.sub.len > 0) {
                if (ui.beginSubmenu(it.label, .{ .disabled = it.disabled })) {
                    defer ui.endMenu();
                    app.items(ui, it.sub, it.label);
                }
            } else if (ui.menuItem(it.label, .{ .shortcut = it.shortcut, .disabled = it.disabled, .tooltip = it.tooltip })) {
                app.ran("{s}: {s}", .{ path, it.label });
            }
        }
    }

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        // The keymap, unless a field is taking keys.
        if (!ui.wantsKeyboard()) {
            for (app.keymap, 0..) |b, i| if (b.key) |k| if (k.pressed(&ui.input)) switch (i) {
                0 => app.palette = true,
                1 => app.ran("Save (from its shortcut)", .{}),
                2 => app.ran("Undo (from its shortcut)", .{}),
                else => app.show_grid = !app.show_grid,
            };
        }

        ui.beginMenuBar();
        for (menus) |m| {
            if (ui.beginMenu(m.name)) {
                defer ui.endMenu();
                app.items(ui, m.items, m.name);
                if (std.mem.eql(u8, m.name, "View")) {
                    ui.menuSeparator();
                    if (ui.menuItem("Ground Grid", .{ .checked = app.show_grid, .shortcut = "Shift+G" })) app.show_grid = !app.show_grid;
                    if (ui.menuItem("Statistics", .{ .checked = app.show_stats })) app.show_stats = !app.show_stats;
                }
            }
        }
        ui.endMenuBar();

        ui.beginHorizontal(.{ .alignment = .start, .height = .fill, .spacing = 16 });
        const c = ui.beginCanvas("viewport", .{ .width = .fill, .height = .fill, .background = ui.style.colors.window });
        if (app.show_grid) {
            var x: f32 = c.rect.x;
            while (x < c.rect.right()) : (x += 40) c.painter.line(.{ .x = x, .y = c.rect.y }, .{ .x = x, .y = c.rect.bottom() }, ui.style.colors.separator, 1);
            var y: f32 = c.rect.y;
            while (y < c.rect.bottom()) : (y += 40) c.painter.line(.{ .x = c.rect.x, .y = y }, .{ .x = c.rect.right(), .y = y }, ui.style.colors.separator, 1);
        }
        c.painter.text(.{ .x = c.rect.x + 12, .y = c.rect.y + 10 }, ui.style.colors.text_muted, "Right-click here for the context menu. F3 searches every command.");
        if (app.show_stats) c.painter.text(.{ .x = c.rect.x + 12, .y = c.rect.y + 34 }, ui.style.colors.text_muted, "Objects 3   Vertices 1,208   Faces 1,170");
        ui.endCanvas();
        if (ui.beginContextMenu(c.interaction, "Viewport menu")) {
            defer ui.endMenu();
            if (ui.menuItem("Frame Selected", .{ .shortcut = "Numpad ." })) app.ran("Frame Selected", .{});
            if (ui.beginSubmenu("Add", .{})) {
                defer ui.endMenu();
                app.items(ui, menus[4].items[0].sub, "Add");
            }
            ui.menuSeparator();
            if (ui.menuItem("Delete", .{ .shortcut = "X", .disabled = "Nothing is selected" })) app.ran("Delete", .{});
        }

        ui.beginVertical(.{ .width = .px(300) });
        ui.label("Keymap: click a shortcut, press keys", .{ .color = ui.style.colors.text_muted });
        for (&app.keymap) |*b| _ = ui.shortcutField(b.name, &b.key, .{});
        ui.separator();
        ui.label("Last command:", .{ .color = ui.style.colors.text_muted });
        ui.label(if (app.last_len > 0) app.last[0..app.last_len] else "(none yet)", .{});
        if (ui.disabledClick()) |why| app.ran("Not now: {s}", .{why});
        ui.endVertical();
        ui.endHorizontal();

        if (ui.commandPalette("palette", &app.palette, &all_commands, .{})) |i| {
            app.ran("{s}: {s} (from search)", .{ all_commands[i].category, all_commands[i].label });
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 16: menus", .width = 1000, .height = 640 }, &app);
}
