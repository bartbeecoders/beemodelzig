//! Phase 2 demo: pure-Zig font rendering. No UI logic yet, just the draw layer.
//! Move the mouse over the lower box to see text clipped against it.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");
const Color = zui.Color;

const App = struct {
    font: zui.Font,

    fn text(app: *App, ctx: *harness.Context, x: f32, y: f32, size: f32, color: Color, s: []const u8) !void {
        try ctx.list.addText(.{ .font = &app.font, .pos = .{ .x = x, .y = y }, .size = size, .color = color, .text = s });
    }

    pub fn frame(app: *App, ctx: *harness.Context) !void {
        const fg = Color.hex(0xE6E7EA);
        const dim = Color.hex(0x9A9EA8);

        var y: f32 = 34;
        for ([_]f32{ 11, 12, 13, 14, 15, 16, 18, 22, 28, 40 }) |size| {
            var label: [16]u8 = undefined;
            try app.text(ctx, 24, y, 12, dim, try std.fmt.bufPrint(&label, "{d} px", .{size}));
            try app.text(ctx, 80, y, size, fg, "The quick brown fox jumps over the lazy dog 0123456789");
            y += size + 12;
        }

        try app.text(ctx, 24, y + 10, 18, fg, "Accents: élève, naïve, Müller, señor, façade, Ærø, Ελληνικά, Кириллица");

        // Dark text on light, and translucent text.
        const panel: zui.Rect = .{ .x = 24, .y = y + 30, .w = 440, .h = 70 };
        try ctx.list.addRect(.{ .rect = panel, .fill = Color.hex(0xF4F4F1), .radius = 6 });
        try app.text(ctx, 40, y + 58, 15, Color.hex(0x1D1F23), "Dark text on a light background");
        try app.text(ctx, 40, y + 84, 15, Color.hex(0x1D1F23).withAlpha(120), "Translucent text");

        // Clipping follows the mouse.
        const box: zui.Rect = .{ .x = 490, .y = y + 30, .w = 420, .h = 70 };
        try ctx.list.addRect(.{ .rect = box, .border = dim, .border_width = 1 });
        const m = ctx.input.mouse_pos;
        try ctx.list.setClip(box.inset(1).intersect(.{ .x = m.x - 150, .y = m.y - 60, .w = 300, .h = 120 }));
        try app.text(ctx, 500, y + 74, 26, Color.hex(0x7EA6F5), "Clip me with the mouse!");
        try ctx.list.setClip(null);
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{ .font = try .initDefault(init.gpa) };
    defer app.font.deinit();
    try harness.run(init, .{ .title = "Zui 02: text", .width = 960, .height = 560 }, &app);
}
