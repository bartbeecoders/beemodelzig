//! Phase 6 demo: checkboxes and sliders, generic over the value type.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const App = struct {
    show_preview: bool = true,
    rounded: bool = true,
    border: bool = false,
    red: u8 = 70,
    green: u8 = 130,
    blue: u8 = 220,
    alpha: f32 = 1,
    radius: f32 = 12,
    size: i32 = 120,
    snapped: f64 = 0.5,
    changes: u32 = 0,

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };

        ui.beginHorizontal(.{ .height = .fill, .alignment = .start, .spacing = 24 });

        ui.beginVertical(.{});
        ui.label("Color (u8 sliders)", muted);
        app.track(ui.slider("Red", &app.red, 0, 255, .{}));
        app.track(ui.slider("Green", &app.green, 0, 255, .{}));
        app.track(ui.slider("Blue", &app.blue, 0, 255, .{}));
        app.track(ui.slider("Alpha", &app.alpha, 0, 1, .{}));
        ui.spacer(.px(8));
        ui.label("Shape", muted);
        app.track(ui.slider("Size (i32)", &app.size, 40, 220, .{}));
        app.track(ui.slider("Radius (f32)", &app.radius, 0, 60, .{ .decimals = 1 }));
        app.track(ui.slider("Step 0.25 (f64)", &app.snapped, 0, 2, .{ .step = 0.25 }));
        ui.spacer(.px(8));
        app.track(ui.checkbox("Show preview", &app.show_preview, .{}));
        app.track(ui.checkbox("Rounded corners", &app.rounded, .{}));
        app.track(ui.checkbox("Border", &app.border, .{}));
        ui.spacer(.px(8));
        ui.labelf("Values changed {d} times", .{app.changes}, muted);
        ui.endVertical();

        ui.beginVertical(.{ .width = .fill, .height = .fill });
        ui.label("Preview", muted);
        if (app.show_preview) {
            const s: f32 = @floatFromInt(app.size);
            const rect = ui.place(.{ .x = s, .y = s });
            ui.drawRect(.{
                .rect = rect,
                .fill = .{ .r = app.red, .g = app.green, .b = app.blue, .a = @intFromFloat(app.alpha * 255) },
                .radius = if (app.rounded) app.radius else 0,
                .border = ui.style.colors.text,
                .border_width = if (app.border) 3 else 0,
            });
        } else {
            ui.label("(hidden)", muted);
        }
        ui.spacer(.fill);
        ui.label("A fill-width slider:", muted);
        app.track(ui.slider("##wide", &app.alpha, 0, 1, .{ .width = .fill }));
        ui.endVertical();

        ui.endHorizontal();
    }

    fn track(app: *App, result: zui.Interaction) void {
        if (result.changed) app.changes += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 06: widgets", .width = 760, .height = 520 }, &app);
}
