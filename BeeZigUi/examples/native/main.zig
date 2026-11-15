//! Zui on the system's own window protocol, with no C at all: Wayland on
//! Linux (a static binary, no libc), Win32 on Windows. The same UI either
//! way; the window frame is Zui's on Wayland and the system's on Windows.
//!
//! Try: type with your keyboard layout (dead keys too); copy and paste
//! with other programs; drop files on the window; hover the cursor rows;
//! change the UI scale; tick "Own window" to move the Tools panel into an
//! OS window of its own (Wayland), and drag it to another monitor.
//!
//! Flags: --frames N quits after N frames; --detach starts with the panel
//! in its own window.

const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const native = @import("zui_native");

const windows = builtin.os.tag == .windows;
const Backend = if (windows) native.Window else native.Display;

const App = struct {
    text: [128]u8 = undefined,
    text_len: usize = 0,
    copied: [64]u8 = undefined,
    copied_len: usize = 0,
    detached: bool = false,
    tools_open: bool = true,
    scale: f64 = 100,
    color: zui.Color = zui.Color.hex(0x4C8DF0),
    drops: [6][256]u8 = undefined,
    drop_len: [6]usize = @splat(0),
    drop_n: usize = 0,
    value: f32 = 0.4,
    frames: u64 = 0,

    fn frame(app: *App, ui: *zui.Ui, backend: *Backend) void {
        app.frames += 1;
        if (!windows) backend.act(ui.clientFrame("Zui native", .{ .maximized = backend.maximized(), .active = backend.active() }));
        const colors = ui.style.colors;
        const size = backend.size();
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start, .spacing = 24 });

        ui.beginVertical(.{ .width = .px(380) });
        ui.label(if (windows) "Win32, no C runtime" else "Wayland, no libc, no libwayland", .{ .color = colors.accent });
        ui.labelf("{d:.0} x {d:.0} units at {d:.2}x, {d} frames", .{ size.width, size.height, size.scale, app.frames }, .{ .color = colors.text_muted });
        ui.separator();
        ui.label("Keyboard (your layout, dead keys, AltGr)", .{ .color = colors.text_muted });
        _ = ui.textInput("##text", &app.text, &app.text_len, .{ .width = .fill, .hint = "Type here" });
        ui.beginHorizontal(.{});
        if (ui.button("Copy", .{}).clicked) ui.setClipboard(app.text[0..app.text_len]);
        if (ui.button("Paste", .{}).clicked) {
            const t = ui.getClipboard();
            const n = @min(t.len, app.copied.len);
            @memcpy(app.copied[0..n], t[0..n]);
            app.copied_len = n;
        }
        ui.label(app.copied[0..app.copied_len], .{ .color = colors.text_muted });
        ui.endHorizontal();
        ui.separator();
        ui.label("Pointer shapes", .{ .color = colors.text_muted });
        const shapes = [_]struct { []const u8, zui.Cursor }{
            .{ "Text", .text },       .{ "Pointer", .pointer },          .{ "Crosshair", .crosshair },     .{ "Move", .move },
            .{ "Resize ↔", .resize_ew }, .{ "Resize ↕", .resize_ns }, .{ "Not allowed", .not_allowed },
        };
        ui.beginHorizontal(.{ .spacing = 4 });
        for (shapes[0..4]) |s| if (ui.button(s[0], .{}).hovered) {
            ui.cursor = s[1];
        };
        ui.endHorizontal();
        ui.beginHorizontal(.{ .spacing = 4 });
        for (shapes[4..]) |s| if (ui.button(s[0], .{}).hovered) {
            ui.cursor = s[1];
        };
        ui.endHorizontal();
        ui.separator();
        if (ui.numberField("UI Scale", &app.scale, .{ .width = .fill, .min = 75, .max = 200, .step = 25, .decimals = 0, .suffix = "%", .slider = true }).committed) {
            ui.setScale(@floatCast(app.scale / 100));
        }
        _ = ui.colorEdit("Colour (with eyedropper)", &app.color, .{});
        if (!windows) _ = ui.checkbox("Tools in its own window", &app.detached, .{});
        ui.endVertical();

        ui.beginVertical(.{ .width = .fill, .height = .fill });
        ui.label("Drop files here", .{ .color = colors.text_muted });
        const area = ui.placeSized(.fill, .px(160), .{});
        ui.drawRect(.{ .rect = area, .border = colors.border, .border_width = 1, .radius = ui.style.rounding });
        if (ui.fileDrop(area)) |drop| {
            var d = drop;
            while (d.next()) |path| {
                const slot = app.drop_n % app.drops.len;
                const n = @min(path.len, 256);
                @memcpy(app.drops[slot][0..n], path[0..n]);
                app.drop_len[slot] = n;
                app.drop_n += 1;
            }
        }
        for (0..@min(app.drop_n, app.drops.len)) |i| ui.label(app.drops[i][0..app.drop_len[i]], .{});
        ui.endVertical();
        ui.endHorizontal();

        if (ui.beginWindow("Tools", .{ .position = .{ .x = 520, .y = 320 }, .size = .{ .x = 320, .y = 220 }, .detached = app.detached, .open = &app.tools_open })) {
            defer ui.endWindow();
            ui.label(if (app.detached) "In an OS window of its own" else "Inside the main window", .{});
            _ = ui.slider("Amount", &app.value, 0, 1, .{ .width = .fill });
            _ = ui.dropdown("Mode", &mode, &.{ .{ .label = "Draw" }, .{ .label = "Erase" }, .{ .label = "Smooth" } }, .{});
            if (ui.button(if (app.detached) "Back into the main window" else "Into its own window", .{}).clicked) app.detached = !app.detached;
        }
        if (!app.tools_open) {
            if (ui.button("Show Tools again", .{}).clicked) app.tools_open = true;
        }
    }
};

var mode: usize = 0;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var max_frames: ?u64 = null;
    var app: App = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--frames") and i + 1 < args.len) {
            i += 1;
            max_frames = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--detach")) {
            app.detached = true;
        }
    }

    var font: zui.Font = try .initDefault(init.gpa);
    defer font.deinit();
    var ui: zui.Ui = .init(init.gpa, .{ .font = &font });
    defer ui.deinit();
    var backend: Backend = undefined;
    if (windows) {
        try backend.init(init.gpa, .{ .title = "Zui native", .width = 1000, .height = 680 });
    } else {
        try backend.init(init.gpa, init.environ_map, .{ .title = "Zui native", .app_id = "zui-native", .width = 1000, .height = 680 });
    }
    defer backend.deinit();
    ui.clipboard = backend.clipboard();

    var last = std.Io.Clock.awake.now(init.io);
    // Input can change what an earlier-described widget should show, so
    // every event is followed by one more frame.
    var pending: u32 = 2;
    while (!backend.close_requested) {
        if (max_frames) |m| if (app.frames >= m) break;
        const timeout: i32 = if (pending > 0 or ui.redraw_requested or max_frames != null)
            0
        else if (ui.redraw_in) |s|
            @intFromFloat(@min(1_000_000, @ceil(s * 1000)))
        else
            -1;
        const got = if (windows) backend.wait(&ui.input, timeout) else try backend.wait(&ui.input, timeout);
        if (got) pending = 2;
        // A frame the compositor wasn't ready for: draw it once more.
        if (!windows and !got and backend.needsFrame()) pending = @max(pending, 1);
        if (pending > 0) pending -= 1;

        const now = std.Io.Clock.awake.now(init.io);
        const dt: f32 = @as(f32, @floatFromInt(last.durationTo(now).nanoseconds)) / 1e9;
        last = now;
        const size = backend.size();
        ui.beginFrame(.{ .width = size.width, .height = size.height, .dt = dt });
        app.frame(&ui, &backend);
        const list = try ui.endFrame();
        if (windows) backend.present(&ui, list) else try backend.present(&ui, list);
    }
}
