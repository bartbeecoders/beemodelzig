//! Phase 21 demo: BeeModel's colour picker and theme settings.
//!
//! Try: click a swatch for the picker; drag in the square and the strips;
//! type a hex code; switch to HSV; click the old colour to go back; take a
//! colour with the eyedropper (Esc cancels); right-click a swatch to copy,
//! paste or reset. Pick a theme on the right, or build one from three
//! colours; change the UI scale.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const palette = [_]zui.Color{
    zui.Color.hex(0xE5534B), zui.Color.hex(0xE0873A), zui.Color.hex(0xF5D547), zui.Color.hex(0x6CBF43),
    zui.Color.hex(0x2BBF94), zui.Color.hex(0x4C8DF0), zui.Color.hex(0x8E7CF0), zui.Color.hex(0xD46FB4),
    zui.Color.hex(0xFFFFFF), zui.Color.hex(0xB0B0B0), zui.Color.hex(0x606060), zui.Color.hex(0x101010),
};

const App = struct {
    base: zui.Color = zui.Color.hex(0xC8C8C8),
    emission: zui.Color = zui.Color.hex(0x000000),
    light: zui.Color = zui.Color.hex(0xFFE7C2),
    paint: zui.Color = zui.Color.hex(0x4C8DF0),
    glass: zui.Color = zui.Color.hex(0x8FD3FF).withAlpha(96),
    recent: zui.RecentColors = .{},
    /// Index into the presets, or `presets.len` for the custom theme.
    theme: usize = 0,
    custom: zui.ThemeBase = .{ .background = zui.Color.hex(0x1B1D22), .text = zui.Color.hex(0xE8E8EA), .accent = zui.Color.hex(0xE0873A) },
    scale: f64 = 100,
    location: [3]f64 = .{ 1.5, -2, 0.25 },
    styles: [zui.theme.presets.len]zui.Style = undefined,
    custom_style: zui.Style = undefined,

    fn init() App {
        var app: App = .{};
        for (zui.theme.presets, 0..) |p, i| app.styles[i] = p.style();
        app.custom_style = zui.theme.build(app.custom);
        return app;
    }

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        ui.style = if (app.theme < app.styles.len) app.styles[app.theme] else app.custom_style;
        const colors = ui.style.colors;
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start, .spacing = 20 });

        // Material and light colours, each opening the picker.
        ui.beginVertical(.{ .width = .px(300), .height = .fill });
        ui.label("Material", .{ .color = colors.text_muted });
        _ = ui.colorEdit("Base Color", &app.base, .{ .recent = &app.recent, .swatches = &palette, .default = zui.Color.hex(0xC8C8C8), .alpha = false });
        _ = ui.colorEdit("Emission", &app.emission, .{ .recent = &app.recent, .swatches = &palette, .default = zui.Color.hex(0x000000), .alpha = false });
        _ = ui.colorEdit("Glass Tint", &app.glass, .{ .recent = &app.recent, .default = zui.Color.hex(0x8FD3FF).withAlpha(96) });
        ui.label("Light", .{ .color = colors.text_muted });
        _ = ui.colorEdit("Light Color", &app.light, .{ .recent = &app.recent, .default = zui.Color.hex(0xFFFFFF), .alpha = false });
        ui.separator();
        ui.label("Axes", .{ .color = colors.text_muted });
        _ = ui.vectorField("Location", &app.location, .{ .width = .fill, .number = .{ .suffix = " m" } });
        ui.separator();
        ui.label("Interface", .{ .color = colors.text_muted });
        if (ui.numberField("UI Scale", &app.scale, .{ .width = .fill, .min = 75, .max = 200, .step = 25, .decimals = 0, .suffix = "%", .slider = true }).committed) {
            ui.setScale(@floatCast(app.scale / 100));
        }
        ui.endVertical();

        // Texture paint: the picker always out.
        ui.beginVertical(.{ .width = .px(290), .height = .fill });
        ui.label("Paint Colour", .{ .color = colors.text_muted });
        _ = ui.colorPicker("paint", &app.paint, .{ .recent = &app.recent, .swatches = &palette, .alpha = false, .default = zui.Color.hex(0x4C8DF0) });
        ui.endVertical();

        // Themes.
        ui.beginVertical(.{ .width = .fill, .height = .fill });
        ui.label("Theme", .{ .color = colors.text_muted });
        for (zui.theme.presets, 0..) |p, i| {
            if (ui.themePreview(p.name, &app.styles[i], .{ .selected = app.theme == i }).clicked) app.theme = i;
        }
        if (ui.themePreview("Custom", &app.custom_style, .{ .selected = app.theme == app.styles.len }).clicked) app.theme = app.styles.len;
        var changed = false;
        changed = ui.colorEdit("Background", &app.custom.background, .{ .alpha = false }).changed or changed;
        changed = ui.colorEdit("Text", &app.custom.text, .{ .alpha = false }).changed or changed;
        changed = ui.colorEdit("Accent", &app.custom.accent, .{ .alpha = false }).changed or changed;
        if (changed) {
            app.custom_style = zui.theme.build(app.custom);
            app.theme = app.styles.len;
        }
        var problems: [32]zui.ContrastProblem = undefined;
        const found = zui.theme.contrastProblems(ui.style, &problems);
        if (found.len == 0) {
            ui.label("Contrast: every text is at least 4.5:1", .{ .color = colors.text_muted });
        } else for (found) |q| {
            ui.labelf("{s} on {s}: {d:.1}:1", .{ q.foreground, q.background, q.ratio }, .{ .color = colors.warning });
        }
        ui.endVertical();
        ui.endHorizontal();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .init();
    try harness.runUi(init, .{ .title = "Zui 21: colour", .width = 1080, .height = 760 }, &app);
}
