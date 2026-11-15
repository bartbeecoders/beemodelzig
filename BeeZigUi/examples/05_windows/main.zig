//! Phase 5 demo: floating windows. Drag titles, resize from the corner,
//! collapse with the arrow, close with the cross, scroll the long list.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const App = struct {
    show_settings: bool = true,
    show_log: bool = true,
    count: u32 = 0,
    log_lines: u32 = 60,

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };

        // The background, outside any window.
        ui.label("Top level. Windows always draw above this.", muted);
        ui.beginHorizontal(.{ .width = .auto });
        if (ui.button("Show settings", .{}).clicked) app.show_settings = true;
        if (ui.button("Show log", .{}).clicked) app.show_log = true;
        ui.endHorizontal();

        if (ui.beginWindow("Counter", .{ .position = .{ .x = 30, .y = 110 }, .size = .{ .x = 260, .y = 180 } })) {
            defer ui.endWindow();
            ui.labelf("Clicked {d} times", .{app.count}, .{});
            if (ui.button("Click me", .{ .width = .fill }).clicked) app.count += 1;
            ui.label("This window can't be closed.", muted);
        }

        if (ui.beginWindow("Settings", .{
            .position = .{ .x = 330, .y = 60 },
            .size = .{ .x = 300, .y = 220 },
            .open = &app.show_settings,
        })) {
            defer ui.endWindow();
            ui.label("Close me with the cross.", .{});
            ui.separator();
            ui.beginHorizontal(.{});
            ui.label("Theme", muted);
            ui.spacer(.fill);
            if (ui.button("Dark", .{}).clicked) ui.style = .dark;
            if (ui.button("Light", .{}).clicked) ui.style = .light;
            ui.endHorizontal();
            ui.spacer(.fill);
            ui.label("Resize from the lower-right corner.", muted);
        }

        if (ui.beginWindow("Log", .{
            .position = .{ .x = 420, .y = 300 },
            .size = .{ .x = 340, .y = 240 },
            .open = &app.show_log,
        })) {
            defer ui.endWindow();
            ui.beginHorizontal(.{});
            if (ui.button("Add 10 lines", .{}).clicked) app.log_lines += 10;
            if (ui.button("Clear", .{}).clicked) app.log_lines = 0;
            ui.endHorizontal();
            for (0..app.log_lines) |i| {
                ui.labelf("{d:0>4}  frame event, nothing to worry about", .{i}, muted);
            }
        }

        if (ui.beginWindow("A window with a long title that gets clipped##long", .{
            .position = .{ .x = 40, .y = 340 },
            .size = .{ .x = 280, .y = 120 },
        })) {
            defer ui.endWindow();
            ui.label("Titles are clipped before the buttons.", muted);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 05: windows", .width = 820, .height = 580 }, &app);
}
