//! Phase 9 demo: the style system. Edit the theme live, and see scoped
//! overrides that end at their pop.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const color_names = std.meta.fieldNames(zui.Colors);

const App = struct {
    checked: bool = true,
    amount: f32 = 0.4,
    count: i32 = 3,
    text_buffer: [64]u8 = undefined,
    text_len: usize = 0,
    status: []const u8 = "",

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start, .spacing = 32 });
        app.editor(ui);
        app.preview(ui);
        ui.endHorizontal();
        colorWindow(ui);
    }

    /// Edits `ui.style` directly, so the editor restyles itself as you go.
    fn editor(app: *App, ui: *zui.Ui) void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };
        ui.beginVertical(.{ .width = .px(330) });
        ui.label("Theme", muted);
        ui.beginHorizontal(.{});
        if (ui.button("Dark", .{}).clicked) ui.style = .dark;
        if (ui.button("Light", .{}).clicked) ui.style = .light;
        ui.endHorizontal();

        ui.spacer(.px(4));
        ui.label("Sizes", muted);
        const s = &ui.style;
        const wide: zui.SliderOptions = .{ .decimals = 0 };
        _ = ui.slider("Font size", &s.font_size, 10, 24, wide);
        _ = ui.slider("Rounding", &s.rounding, 0, 14, wide);
        _ = ui.slider("Padding x", &s.frame_padding.x, 2, 24, wide);
        _ = ui.slider("Padding y", &s.frame_padding.y, 1, 14, wide);
        _ = ui.slider("Spacing", &s.item_spacing.y, 0, 20, wide);
        s.item_spacing.x = s.item_spacing.y;
        _ = ui.slider("Border", &s.border_width, 0, 3, .{ .decimals = 1, .step = 0.5 });
        _ = ui.slider("Window rounding", &s.window_rounding, 0, 16, wide);

        ui.spacer(.px(4));
        ui.beginHorizontal(.{});
        if (ui.button("Copy theme as Zig", .{}).clicked) app.copyTheme(ui);
        ui.label(app.status, muted);
        ui.endHorizontal();
        ui.endVertical();
    }

    /// Every widget, plus overrides that must not leak past their pop.
    fn preview(app: *App, ui: *zui.Ui) void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };
        ui.beginVertical(.{ .width = .fill });
        ui.label("Preview", muted);
        ui.label("Regular text, and muted text below.", .{});
        ui.label("Secondary information", muted);
        ui.beginHorizontal(.{});
        _ = ui.button("Button", .{});
        _ = ui.button("Another", .{});
        ui.endHorizontal();
        _ = ui.checkbox("A checkbox", &app.checked, .{});
        _ = ui.slider("Float", &app.amount, 0, 1, .{});
        _ = ui.slider("Integer", &app.count, 0, 10, .{});
        _ = ui.textInput("Text", &app.text_buffer, &app.text_len, .{ .hint = "Hint text" });
        ui.separator();

        ui.label("Scoped overrides", muted);
        ui.beginHorizontal(.{});
        ui.pushColor(.button, zui.Color.hex(0xB33A3A));
        ui.pushColor(.button_hovered, zui.Color.hex(0xC94B4B));
        ui.pushColor(.text, zui.Color.white);
        _ = ui.button("Delete", .{});
        ui.popStyles(3);
        _ = ui.button("Cancel (not red)", .{});
        ui.endHorizontal();

        ui.beginHorizontal(.{});
        ui.pushMetric(.rounding, 14);
        ui.pushMetric(.frame_padding, .{ .x = 18, .y = 4 });
        _ = ui.button("Pill", .{});
        _ = ui.button("Shaped", .{});
        ui.popStyles(2);
        _ = ui.button("Normal again", .{});
        ui.endHorizontal();

        // A panel in the opposite theme, keeping the edited sizes.
        var other: zui.Style = if (ui.style.colors.background.r < 128) .light else .dark;
        other.colors.accent = ui.style.colors.accent;
        inline for (comptime std.meta.fieldNames(zui.Style)) |name| {
            if (comptime !std.mem.eql(u8, name, "colors")) @field(other, name) = @field(ui.style, name);
        }
        ui.pushStyle(other);
        ui.beginVertical(.{ .width = .fill, .padding = 12, .fill = other.colors.window, .border = other.colors.border });
        ui.label("This panel uses the other theme via pushStyle.", .{});
        ui.beginHorizontal(.{});
        _ = ui.button("Inside", .{});
        _ = ui.checkbox("Also inside", &app.checked, .{});
        ui.endHorizontal();
        ui.endVertical();
        ui.popStyle();
        ui.label("And this label is back to the edited theme.", .{});
        ui.endVertical();
    }

    /// Every theme color, each with its own picker.
    fn colorWindow(ui: *zui.Ui) void {
        if (!ui.beginWindow("Colors", .{ .position = .{ .x = 16, .y = 440 }, .size = .{ .x = 340, .y = 240 } })) return;
        defer ui.endWindow();
        inline for (color_names) |name| {
            _ = ui.colorEdit(name, &@field(ui.style.colors, name), .{});
        }
    }

    /// Puts the current theme on the clipboard as a `zui.Style` literal.
    fn copyTheme(app: *App, ui: *zui.Ui) void {
        var buffer: [4096]u8 = undefined;
        var out: Builder = .{ .buffer = &buffer };
        out.print(".{{\n    .colors = .{{\n", .{});
        inline for (color_names) |name| {
            const c = @field(ui.style.colors, name);
            if (c.a == 255) {
                out.print("        .{s} = .hex(0x{X:0>2}{X:0>2}{X:0>2}),\n", .{ name, c.r, c.g, c.b });
            } else {
                out.print("        .{s} = .{{ .r = {d}, .g = {d}, .b = {d}, .a = {d} }},\n", .{ name, c.r, c.g, c.b, c.a });
            }
        }
        out.print("    }},\n", .{});
        inline for (comptime std.meta.fieldNames(zui.Style)) |name| {
            const value = @field(ui.style, name);
            switch (@TypeOf(value)) {
                f32 => out.print("    .{s} = {d},\n", .{ name, value }),
                zui.Vec2 => out.print("    .{s} = .{{ .x = {d}, .y = {d} }},\n", .{ name, value.x, value.y }),
                else => {},
            }
        }
        out.print("}}\n", .{});
        ui.setClipboard(out.text());
        app.status = if (out.overflowed) "Too long to copy" else "Copied";
    }
};

/// Formats into a fixed buffer, noting if it ran out of room.
const Builder = struct {
    buffer: []u8,
    len: usize = 0,
    overflowed: bool = false,

    fn print(b: *Builder, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(b.buffer[b.len..], fmt, args) catch {
            b.overflowed = true;
            return;
        };
        b.len += written.len;
    }

    fn text(b: *const Builder) []const u8 {
        return b.buffer[0..b.len];
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 09: style", .width = 900, .height = 700 }, &app);
}
