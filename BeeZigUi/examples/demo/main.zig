//! The Zui showcase: every widget, theme switching, windows and popups.
//!
//! Unlike the phase demos, this one has its own main loop, so it shows
//! everything an app needs: a font, a `Ui`, an SDL3 window, the software
//! renderer, and a loop that sleeps while nothing happens.
//!
//! Build it on its own with `zig build run` in this folder, or with
//! `zig build run-demo` from the project root. Pass `--gl` to draw with the
//! OpenGL renderer instead of the software one.

const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");
const sdl3 = @import("zui_sdl3");
const opengl = @import("zui_opengl");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const use_gl = args.len > 1 and std.mem.eql(u8, args[1], "--gl");

    var font: zui.Font = try .initDefault(gpa);
    defer font.deinit();
    var ui: zui.Ui = .init(gpa, .{ .font = &font });
    defer ui.deinit();

    var window = sdl3.Window.init(.{
        .title = "Zui demo",
        .width = 1100,
        .height = 720,
        .graphics = if (use_gl) .opengl else .software,
    }) catch |err| {
        std.log.err("could not open a window: {s}", .{sdl3.lastError()});
        return err;
    };
    defer window.deinit();
    ui.clipboard = window.clipboard();

    // Either renderer draws the same draw list; only presenting differs.
    var renderer: software.SoftwareRenderer = .init(gpa);
    defer renderer.deinit();
    var gl: ?opengl.GlRenderer = if (use_gl) try opengl.GlRenderer.init(gpa, sdl3.glGetProcAddress) else null;
    defer if (gl) |*g| g.deinit();

    var app: App = .{};
    var previous = sdl3.ticksNs();
    // A widget described early in a frame can be changed by one described
    // later, so each burst of input is followed by one more frame.
    var frames_left: u32 = 2;
    while (!window.close_requested) {
        // Sleep until input arrives, or until the UI has a timed change
        // coming (caret blink, tooltip delay). Never sleep while the UI has
        // asked for another frame.
        const idle = frames_left == 0 and !ui.redraw_requested;
        const timeout: ?i32 = if (idle) waitMs(ui.redraw_in) else null;
        if (window.pollEvents(&ui.input, timeout)) frames_left = 2;
        if (frames_left > 0) frames_left -= 1;

        const now = sdl3.ticksNs();
        const dt: f32 = @as(f32, @floatFromInt(now - previous)) / 1e9;
        previous = now;

        const size = window.size();
        const width: f32 = @floatFromInt(size.width);
        const height: f32 = @floatFromInt(size.height);

        ui.beginFrame(.{ .width = width, .height = height, .dt = dt });
        app.frame(&ui);
        const list = try ui.endFrame();

        const frame: zui.Frame = .{ .width = width, .height = height, .scale = size.scale };
        if (gl) |*g| {
            g.clear_color = ui.style.colors.background;
            g.renderer().render(list, frame);
            try window.swap();
        } else {
            try renderer.resize(size.pixel_width, size.pixel_height);
            renderer.clear_color = ui.style.colors.background;
            renderer.renderer().render(list, frame);
            try window.present(renderer.pixels, renderer.width, renderer.height);
        }
    }
}

/// Milliseconds to wait for input: until `seconds` from now, or forever.
fn waitMs(seconds: ?f32) i32 {
    const s = seconds orelse return -1;
    const ms = @ceil(s * 1000);
    if (ms >= 1_000_000) return 1_000_000;
    return @intFromFloat(ms);
}

/// A fixed-capacity text field, the shape `textInput` edits.
fn Text(comptime capacity: usize) type {
    return struct {
        buffer: [capacity]u8 = undefined,
        len: usize = 0,

        fn init(initial: []const u8) @This() {
            var t: @This() = .{};
            @memcpy(t.buffer[0..initial.len], initial);
            t.len = initial.len;
            return t;
        }

        fn slice(t: *const @This()) []const u8 {
            return t.buffer[0..t.len];
        }
    };
}

/// The last few things that happened, newest last.
const Log = struct {
    lines: [64]Text(96) = undefined,
    count: usize = 0,
    next: usize = 0,

    fn add(log: *Log, comptime fmt: []const u8, args: anytype) void {
        var line: Text(96) = .{};
        const written = std.fmt.bufPrint(&line.buffer, fmt, args) catch line.buffer[0..];
        line.len = written.len;
        log.lines[log.next] = line;
        log.next = (log.next + 1) % log.lines.len;
        log.count = @min(log.count + 1, log.lines.len);
    }

    fn get(log: *const Log, i: usize) []const u8 {
        const start = (log.next + log.lines.len - log.count) % log.lines.len;
        return log.lines[(start + i) % log.lines.len].slice();
    }
};

const App = struct {
    name: Text(64) = .init("Ada Lovelace"),
    email: Text(96) = .{},
    favourite: zui.Color = zui.Color.hex(0x4E8FE0),
    subscribe: bool = true,
    age: i32 = 36,
    volume: f32 = 0.7,
    show_tools: bool = true,
    show_log: bool = true,
    show_files: bool = false,
    chosen_file: usize = 0,
    pinned: bool = false,
    seed: u32 = 0x9E3779B9,
    log: Log = .{},

    fn frame(app: *App, ui: *zui.Ui) void {
        // Right-click on empty space anywhere opens a context menu.
        if (ui.input.mouse_pressed.contains(.right) and ui.hovered_window == null) ui.openPopup("context");

        app.toolbar(ui);
        ui.separator();
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start, .spacing = 28 });
        app.profile(ui);
        app.layoutShowcase(ui);
        ui.endHorizontal();

        app.popups(ui);
        if (app.show_tools) app.toolsWindow(ui);
        if (app.show_log) app.logWindow(ui);
        if (app.show_files) app.filesWindow(ui);
    }

    /// Tree nodes, a collapsing header and a table.
    fn filesWindow(app: *App, ui: *zui.Ui) void {
        if (!ui.beginWindow("Files", .{ .position = .{ .x = 300, .y = 120 }, .size = .{ .x = 420, .y = 420 }, .open = &app.show_files })) return;
        defer ui.endWindow();
        const names = [_][]const u8{ "main.zig", "build.zig", "README.md", "AVATAR.png", "notes.txt" };
        const sizes = [_]u32{ 12, 4, 9, 412, 1 };
        if (ui.treeNode("project", .{ .default_open = true })) {
            defer ui.treePop();
            if (ui.treeNode("src", .{ .default_open = true })) {
                defer ui.treePop();
                for (names[0..2], 0..) |name, i| {
                    ui.pushIdInt(i);
                    defer ui.popId();
                    if (ui.selectable(name, app.chosen_file == i, .{}).clicked) app.chosen_file = i;
                }
            }
        }
        if (ui.collapsingHeader("All files", .{ .default_open = true })) {
            const columns = [_]zui.TableColumn{ .{ .name = "Name" }, .{ .name = "Size", .width = .px(90) } };
            _ = ui.beginTable("files", &columns, .{ .height = .px(170) });
            for (names, sizes, 0..) |name, kb, i| {
                ui.tableRow();
                if (ui.selectable(name, app.chosen_file == i, .{}).clicked) app.chosen_file = i;
                ui.tableNextColumn();
                ui.labelf("{d} KB", .{kb}, .{});
            }
            ui.endTable();
        }
    }

    fn toolbar(app: *App, ui: *zui.Ui) void {
        ui.beginHorizontal(.{});
        ui.label("Zui demo", .{});
        ui.spacer(.fill);
        const dark = ui.style.colors.background.r < 128;
        if (themeButton(ui, "Dark", dark)) {
            ui.style = .dark;
            app.log.add("Theme: dark", .{});
        }
        if (themeButton(ui, "Light", !dark)) {
            ui.style = .light;
            app.log.add("Theme: light", .{});
        }
        _ = ui.checkbox("Tools", &app.show_tools, .{});
        _ = ui.checkbox("Log", &app.show_log, .{});
        _ = ui.checkbox("Files", &app.show_files, .{});
        ui.endHorizontal();
    }

    /// A button that looks pressed while its option is the current one.
    fn themeButton(ui: *zui.Ui, name: []const u8, current: bool) bool {
        if (current) ui.pushColor(.button, ui.style.colors.button_active);
        defer if (current) ui.popStyle();
        return ui.button(name, .{}).clicked and !current;
    }

    fn profile(app: *App, ui: *zui.Ui) void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };
        ui.beginVertical(.{ .width = .px(400) });
        ui.label("Profile", muted);
        if (ui.textInput("Name", &app.name.buffer, &app.name.len, .{}).submitted) {
            app.log.add("Name set to \"{s}\"", .{app.name.slice()});
        }
        _ = ui.textInput("Email", &app.email.buffer, &app.email.len, .{ .hint = "you@example.com" });
        _ = ui.colorEdit("Favourite color", &app.favourite, .{ .alpha = false });
        if (ui.checkbox("Subscribe to news", &app.subscribe, .{}).changed) {
            app.log.add("Subscribe: {}", .{app.subscribe});
        }
        _ = ui.slider("Age (i32)", &app.age, 0, 120, .{});
        _ = ui.slider("Volume (f32)", &app.volume, 0, 1, .{});

        ui.spacer(.px(4));
        ui.beginHorizontal(.{});
        const save = ui.button("Save", .{});
        ui.tooltip(save, "Pretends to save the profile.\nThe log window shows it.");
        if (save.clicked) app.log.add("Saved {s}, age {d}", .{ app.name.slice(), app.age });
        if (ui.button("Reset", .{}).clicked) {
            const log = app.log;
            app.* = .{ .log = log };
            app.log.add("Profile reset", .{});
        }
        const more = ui.button("More...", .{});
        if (more.clicked) ui.openPopupAt("more", more.rect);
        ui.endHorizontal();

        ui.spacer(.px(8));
        ui.label("Preview", muted);
        const card = ui.placeSized(.fill, .px(84), .{});
        ui.drawRect(.{ .rect = card, .fill = app.favourite, .radius = ui.style.rounding * 2 });
        ui.pushClip(card);
        ui.drawText(.{ .x = card.x + 14, .y = card.y + 14 }, zui.Color.white, app.name.slice());
        const shown = if (app.email.len > 0) app.email.slice() else "no email";
        ui.drawText(.{ .x = card.x + 14, .y = card.y + 44 }, zui.Color.white.withAlpha(200), shown);
        ui.popClip();
        ui.endVertical();
    }

    fn layoutShowcase(app: *App, ui: *zui.Ui) void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };
        ui.beginVertical(.{ .width = .fill });
        ui.label("Layout", muted);

        ui.label("Rows share the width; .fill items grow:", .{});
        ui.beginHorizontal(.{});
        _ = ui.button("Fixed", .{ .width = .px(90) });
        _ = ui.button("Grows", .{ .width = .fill });
        _ = ui.button("Grows too", .{ .width = .fill });
        ui.endHorizontal();

        ui.label("Items in a row are centered vertically:", .{});
        ui.beginHorizontal(.{ .padding = 8, .border = ui.style.colors.border });
        ui.label("Short", .{});
        _ = ui.button("Taller button", .{ .height = .px(44) });
        ui.label("Short again", .{});
        ui.spacer(.fill);
        _ = ui.checkbox("Pushed right", &app.pinned, .{});
        ui.endHorizontal();

        ui.label("Nested groups with padding and a background:", .{});
        ui.beginHorizontal(.{ .padding = 10, .fill = ui.style.colors.window, .border = ui.style.colors.border });
        for (0..3) |i| {
            ui.pushIdInt(i);
            defer ui.popId();
            ui.beginVertical(.{ .width = .fill, .padding = 8, .border = ui.style.colors.border });
            ui.labelf("Column {d}", .{i + 1}, .{});
            ui.label("item", muted);
            ui.label("item", muted);
            ui.endVertical();
        }
        ui.endHorizontal();

        ui.separator();
        ui.label("Scoped style overrides:", .{});
        ui.beginHorizontal(.{});
        ui.pushColor(.button, zui.Color.hex(0xB33A3A));
        ui.pushColor(.button_hovered, zui.Color.hex(0xC94B4B));
        ui.pushColor(.text, zui.Color.white);
        const delete = ui.button("Delete everything", .{});
        ui.popStyles(3);
        ui.tooltip(delete, "Red only between pushColor and popStyle.");
        if (delete.clicked) app.log.add("Nothing was deleted", .{});
        ui.pushMetric(.rounding, 14);
        _ = ui.button("Rounded", .{});
        ui.popStyle();
        _ = ui.button("Normal", .{});
        ui.endHorizontal();
        ui.label("Right-click empty space for a menu. Tab moves focus.", muted);
        ui.endVertical();
    }

    fn popups(app: *App, ui: *zui.Ui) void {
        if (ui.beginPopup("more", .{ .min_width = 170 })) {
            defer ui.endPopup();
            if (ui.button("Copy name", .{ .width = .fill }).clicked) {
                ui.setClipboard(app.name.slice());
                app.log.add("Copied the name to the clipboard", .{});
                ui.closeAllPopups();
            }
            if (ui.button("Random color", .{ .width = .fill }).clicked) {
                // xorshift: good enough for picking a color.
                app.seed ^= app.seed << 13;
                app.seed ^= app.seed >> 17;
                app.seed ^= app.seed << 5;
                app.favourite = zui.Color.hex(@truncate(app.seed));
                app.log.add("Picked a random color", .{});
                ui.closeAllPopups();
            }
        }
        if (ui.beginPopup("context", .{ .min_width = 170 })) {
            defer ui.endPopup();
            ui.label("Context menu", .{ .color = ui.style.colors.text_muted });
            if (ui.button("Show tools", .{ .width = .fill }).clicked) {
                app.show_tools = true;
                ui.closeAllPopups();
            }
            if (ui.button("Show log", .{ .width = .fill }).clicked) {
                app.show_log = true;
                ui.closeAllPopups();
            }
            if (ui.button("Clear log", .{ .width = .fill }).clicked) {
                app.log = .{};
                ui.closeAllPopups();
            }
        }
    }

    fn toolsWindow(app: *App, ui: *zui.Ui) void {
        if (!ui.beginWindow("Tools", .{ .position = .{ .x = 16, .y = 500 }, .size = .{ .x = 340, .y = 200 }, .open = &app.show_tools })) return;
        defer ui.endWindow();
        ui.label("Drag the title, resize from the corner.", .{ .color = ui.style.colors.text_muted });
        _ = ui.slider("Font size", &ui.style.font_size, 11, 22, .{ .decimals = 0 });
        _ = ui.slider("Rounding", &ui.style.rounding, 0, 12, .{ .decimals = 0 });
        _ = ui.colorEdit("Accent", &ui.style.colors.accent, .{ .alpha = false });
        _ = ui.colorEdit("Buttons", &ui.style.colors.button, .{});
    }

    fn logWindow(app: *App, ui: *zui.Ui) void {
        if (!ui.beginWindow("Log", .{ .position = .{ .x = @max(16, ui.width - 356), .y = 500 }, .size = .{ .x = 340, .y = 200 }, .open = &app.show_log })) return;
        defer ui.endWindow();
        if (app.log.count == 0) ui.label("Nothing yet. Press Save.", .{ .color = ui.style.colors.text_muted });
        for (0..app.log.count) |i| {
            ui.pushIdInt(i);
            defer ui.popId();
            ui.label(app.log.get(i), .{});
        }
    }
};
