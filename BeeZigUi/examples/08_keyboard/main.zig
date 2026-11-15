//! Phase 8 demo: keyboard navigation. Everything here works without a mouse.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const App = struct {
    name_buffer: [64]u8 = "Untitled".* ++ @as([56]u8, undefined),
    name_len: usize = 8,
    autosave: bool = true,
    backups: bool = false,
    interval: i32 = 5,
    volume: f32 = 0.6,
    last_action: []const u8 = "nothing yet",
    picked: ?usize = null,

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };

        ui.label("Tab and Shift+Tab move between widgets, including into the window.", muted);
        ui.label("Enter or Space press buttons and toggle boxes. Arrows, Page Up/Down and", muted);
        ui.label("Home/End move sliders; Shift steps by ten. Escape lets go, or undoes an edit.", muted);
        ui.spacer(.px(4));

        _ = ui.textInput("Project name", &app.name_buffer, &app.name_len, .{});
        _ = ui.checkbox("Save automatically", &app.autosave, .{});
        _ = ui.checkbox("Keep backups", &app.backups, .{});
        _ = ui.slider("Interval, minutes (i32)", &app.interval, 1, 60, .{});
        _ = ui.slider("Volume (f32)", &app.volume, 0, 1, .{});

        ui.beginHorizontal(.{});
        if (ui.button("Save", .{}).clicked) app.last_action = "Save";
        if (ui.button("Revert", .{}).clicked) app.last_action = "Revert";
        if (ui.button("Help", .{}).clicked) app.last_action = "Help";
        ui.endHorizontal();

        ui.separator();
        ui.labelf("Last button: {s}", .{app.last_action}, .{});
        if (app.picked) |i| ui.labelf("Picked from the list: item {d}", .{i + 1}, .{}) else ui.label("Picked from the list: none", .{});
        ui.labelf("App may use keys: {s}", .{if (ui.wantsKeyboard()) "no, the UI has them" else "yes"}, muted);

        if (ui.beginWindow("Long list", .{ .position = .{ .x = 520, .y = 150 }, .size = .{ .x = 220, .y = 260 } })) {
            defer ui.endWindow();
            ui.label("Tab scrolls this list.", muted);
            for (0..30) |i| {
                ui.pushIdInt(i);
                defer ui.popId();
                const label = std.fmt.allocPrint(ui.frameAllocator(), "Item {d}##item", .{i + 1}) catch "Item";
                if (ui.button(label, .{ .width = .fill }).clicked) app.picked = i;
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 08: keyboard", .width = 780, .height = 480 }, &app);
}
