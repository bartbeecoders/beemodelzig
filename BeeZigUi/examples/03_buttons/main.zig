//! Phase 3 demo: the immediate-mode loop. Labels, buttons, IDs, a custom widget.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const App = struct {
    count: i32 = 0,
    charge: f32 = 0,
    charged_shots: u32 = 0,
    use_light_theme: bool = false,
    picked: ?usize = null,

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };

        ui.label("Counter", .{});
        if (ui.button("Decrement", .{}).clicked) app.count -= 1;
        ui.sameLine();
        if (ui.button("Increment", .{}).clicked) app.count += 1;
        ui.sameLine();
        if (ui.button("Reset", .{}).clicked) app.count = 0;
        ui.labelf("Count: {d}", .{app.count}, .{});

        ui.spacer(.px(8));
        ui.label("Hold the button to charge. Release early and nothing happens.", muted);
        const hold = ui.button("Hold me", .{ .width = .px(120) });
        app.updateCharge(ui, hold);
        ui.sameLine();
        progressBar(ui, app.charge, 220);
        ui.labelf("Full charges: {d}", .{app.charged_shots}, .{});

        ui.spacer(.px(8));
        ui.label("Same label in a loop: pushIdInt keeps the buttons distinct.", muted);
        for (0..5) |i| {
            ui.pushIdInt(i);
            defer ui.popId();
            if (i > 0) ui.sameLine();
            if (ui.button("Pick", .{}).clicked) app.picked = i;
        }
        if (app.picked) |i| {
            ui.labelf("Picked button {d}", .{i}, .{});
        } else {
            ui.label("Nothing picked yet", muted);
        }

        ui.spacer(.px(8));
        const theme_name = if (app.use_light_theme) "Switch to dark" else "Switch to light";
        if (ui.button(theme_name, .{ .width = .px(150) }).clicked) {
            app.use_light_theme = !app.use_light_theme;
            ui.style = if (app.use_light_theme) .light else .dark;
        }
        ui.sameLine();
        const save = ui.button("Save##toolbar", .{});
        ui.sameLine();
        const status = if (save.held) "held" else if (save.hovered) "hovered" else "idle";
        ui.labelf("Second button is {s}", .{status}, muted);
    }

    fn updateCharge(app: *App, ui: *zui.Ui, hold: zui.Interaction) void {
        if (hold.held) {
            app.charge = @min(1, app.charge + ui.dt / 1.2);
            ui.requestRedraw();
        } else if (app.charge > 0) {
            if (app.charge >= 1) app.charged_shots += 1;
            app.charge = 0;
        }
    }
};

/// A custom widget: reserve space, then draw. Nothing about it is special.
fn progressBar(ui: *zui.Ui, value: f32, width: f32) void {
    const colors = ui.style.colors;
    const rect = ui.place(.{ .x = width, .y = 30 });
    ui.drawRect(.{
        .rect = rect,
        .fill = colors.button,
        .border = colors.border,
        .border_width = 1,
        .radius = 5,
    });
    if (value > 0) {
        ui.drawRect(.{
            .rect = .{ .x = rect.x, .y = rect.y, .w = rect.w * value, .h = rect.h },
            .fill = colors.accent,
            .radius = 5,
        });
    }
}

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 03: buttons", .width = 620, .height = 480 }, &app);
}
