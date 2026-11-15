//! Phase 1 demo: the draw layer and software rasterizer, without any UI logic.
//! Move the mouse: the blue box follows it and is clipped to the outlined area.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");
const Color = zui.Color;

const App = struct {
    pub fn frame(_: *App, ctx: *harness.Context) !void {
        const list = ctx.list;

        // A row of corner radii, each with and without a border.
        for (0..7) |i| {
            const fi: f32 = @floatFromInt(i);
            const x = 30 + fi * 125;
            try list.addRect(.{
                .rect = .{ .x = x, .y = 30, .w = 105, .h = 70 },
                .fill = Color.hex(0x3A6FD8),
                .radius = fi * 6,
            });
            try list.addRect(.{
                .rect = .{ .x = x, .y = 115, .w = 105, .h = 70 },
                .fill = Color.hex(0x2B2E35),
                .border = Color.hex(0xE8A33D),
                .border_width = 1 + fi / 2,
                .radius = fi * 6,
            });
        }

        // Alpha blending over stripes.
        for (0..16) |i| {
            const fi: f32 = @floatFromInt(i);
            try list.addRect(.{
                .rect = .{ .x = 30 + fi * 28, .y = 210, .w = 14, .h = 160 },
                .fill = Color.hex(0xD0D3DA),
            });
        }
        for (0..5) |i| {
            const fi: f32 = @floatFromInt(i);
            try list.addRect(.{
                .rect = .{ .x = 30, .y = 214 + fi * 31, .w = 450, .h = 26 },
                .fill = Color.hex(0xD8483A).withAlpha(@intFromFloat(40 + fi * 50)),
                .radius = 6,
            });
        }

        // A circle orbiting, to show anti-aliased edges in motion.
        const a = ctx.time * 1.5;
        try list.addRect(.{
            .rect = .{ .x = 560 + 50 * @cos(a), .y = 275 + 50 * @sin(a), .w = 44, .h = 44 },
            .fill = Color.hex(0x45B36B),
            .radius = 22,
        });

        // Clipping: the box follows the mouse but stays inside this area.
        const area: zui.Rect = .{ .x = 30, .y = 400, .w = 900, .h = 200 };
        try list.addRect(.{ .rect = area, .border = Color.hex(0x6B7080), .border_width = 1 });
        try list.setClip(area.inset(1));
        const m = ctx.input.mouse_pos;
        try list.addRect(.{
            .rect = .{ .x = m.x - 60, .y = m.y - 40, .w = 120, .h = 80 },
            .fill = Color.hex(0x3A6FD8),
            .radius = 12,
        });
        try list.setClip(null);
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.run(init, .{ .title = "Zui 01: shapes", .animate = true }, &app);
}
