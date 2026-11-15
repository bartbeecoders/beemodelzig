//! Phase 23 demo: the building blocks of BeeModel's 2D editors: a dope
//! sheet with a timeline, a graph editor and an image viewer.
//!
//! Try: the wheel zooms about the pointer (the timeline only sideways);
//! Ctrl+wheel and Shift+wheel pan; drag with the middle button; Home fits.
//! Scrub on the top ruler; drag the range ends. Click keys (Shift adds),
//! drag one and the selected ones follow, snapped to frames (Ctrl: free);
//! drag on empty space for a box (Shift adds, Ctrl removes). In the image
//! viewer zoom up to 32 times and drag the minimap.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const Key = struct {
    pos: zui.Vec2,
    selected: bool = false,
};

const channels = [_][]const u8{ "Cube", "Camera", "Light" };

const App = struct {
    timeline: zui.View2D = .{ .origin = .{ .x = 0, .y = -0.8 }, .zoom = .{ .x = 1, .y = 30 } },
    graph: zui.View2D = .{},
    viewer: zui.View2D = .{},
    current: f32 = 24,
    start: f32 = 1,
    end: f32 = 120,
    dope: [12]Key = undefined,
    curve: [6]Key = undefined,
    pixels: []u32,
    image: zui.Image = undefined,

    fn init(gpa: std.mem.Allocator) !App {
        var app: App = .{ .pixels = try gpa.alloc(u32, 256 * 256) };
        for (&app.dope, 0..) |*k, i| k.* = .{ .pos = .{ .x = @floatFromInt(1 + (i % 4) * 24 + (i / 4) * 6), .y = @floatFromInt(i / 4) } };
        const ys = [_]f32{ 0, 2.5, 1, 3.5, 0.5, 2 };
        for (&app.curve, 0..) |*k, i| k.* = .{ .pos = .{ .x = @floatFromInt(1 + i * 20), .y = ys[i] } };
        // A test card: hue across, light down, with a pixel grid.
        for (0..256) |y| for (0..256) |x| {
            const h: f32 = @as(f32, @floatFromInt(x)) / 256 * 360;
            const v: f32 = 1 - @as(f32, @floatFromInt(y)) / 300;
            var c = zui.color.fromHsv(.{ .h = h, .s = 0.75, .v = v }, 255);
            if (x % 32 == 0 or y % 32 == 0) c = zui.Color.hex(0xFFFFFF);
            if ((x / 4 + y / 4) % 2 == 0 and x > 112 and x < 144 and y > 112 and y < 144) c = zui.Color.hex(0x000000);
            app.pixels[y * 256 + x] = 0xFF000000 | @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
        };
        app.image = .initArgb(app.pixels, 256, 256);
        return app;
    }

    /// Selects `keys[i]` on a press: alone, or toggled with Shift.
    fn pick(keys: []Key, i: usize, shift: bool) void {
        if (shift) {
            keys[i].selected = !keys[i].selected;
        } else if (!keys[i].selected) {
            for (keys) |*k| k.selected = false;
            keys[i].selected = true;
        }
    }

    fn boxSelect(keys: []Key, result: zui.ViewResult, shift: bool) void {
        if (result.box) |box| {
            for (keys) |*k| {
                const inside = box.rect.contains(k.pos) or (k.pos.x >= box.rect.x and k.pos.x <= box.rect.right() and k.pos.y >= box.rect.y and k.pos.y <= box.rect.bottom());
                switch (box.mode) {
                    .set => k.selected = inside,
                    .add => k.selected = k.selected or inside,
                    .remove => k.selected = k.selected and !inside,
                }
            }
        } else if (result.clicked != null and !shift) {
            for (keys) |*k| k.selected = false;
        }
    }

    /// Handles for `keys`; dragging one moves every selected one.
    fn handles(ui: *zui.Ui, v: zui.ViewFrame, keys: []Key, options: zui.HandleOptions, labels: []const u8) void {
        for (keys, 0..) |*k, i| {
            var o = options;
            o.selected = k.selected;
            var buffer: [32]u8 = undefined;
            o.label = std.fmt.bufPrint(&buffer, "{s} {d}", .{ labels, i + 1 }) catch "";
            const h = ui.viewHandle(v, i, &k.pos, o);
            if (h.interaction.pressed) pick(keys, i, ui.input.modifiers.shift);
            if (h.delta.x != 0 or h.delta.y != 0) for (keys, 0..) |*other, j| {
                if (j != i and other.selected) other.pos = other.pos.add(h.delta);
            };
        }
    }

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const colors = ui.style.colors;
        const shift = ui.input.modifiers.shift;

        // Dope sheet: channels down, frames across; zooms sideways only.
        ui.label("Dope Sheet", .{ .color = colors.text_muted });
        const t = ui.beginView2D("timeline", &app.timeline, .{
            .height = .px(170),
            .zoom_axes = .x,
            .rulers = .{ .x = .frames },
            .content = .{ .x = 0, .y = -0.6, .w = 125, .h = 3 },
            .min_zoom = .{ .x = 0.5, .y = 1 },
            .max_zoom = .{ .x = 80, .y = 200 },
        });
        // Channel rows.
        for (channels, 0..) |name, row| {
            const y = t.toScreen(.{ .x = 0, .y = @floatFromInt(row) }).y;
            if (row % 2 == 0) ui.drawRect(.{ .rect = .{ .x = t.rect.x, .y = y - 14, .w = t.rect.w, .h = 28 }, .fill = colors.text.withAlpha(10) });
            ui.drawText(.{ .x = t.rect.x + 6, .y = y - 9 }, colors.text_muted, name);
        }
        _ = ui.frameRange(t, &app.start, &app.end);
        handles(ui, t, &app.dope, .{ .shape = .diamond, .snap = .{ .x = 1, .y = 0 }, .lock_y = true, .color = zui.Color.hex(0xC9C9C9) }, "key");
        _ = ui.playhead(t, &app.current, .{});
        boxSelect(&app.dope, ui.endView2D(), shift);

        ui.beginHorizontal(.{ .height = .fill, .alignment = .start });
        ui.beginVertical(.{ .width = .fill, .height = .fill });
        ui.label("Graph Editor", .{ .color = colors.text_muted });
        const g = ui.beginView2D("graph", &app.graph, .{
            .y_up = true,
            .rulers = .{ .x = .frames, .y = .values },
            .content = .{ .x = 0, .y = -0.5, .w = 105, .h = 4.5 },
            .min_zoom = .{ .x = 0.2, .y = 2 },
            .max_zoom = .{ .x = 200, .y = 2000 },
        });
        // The curve: smooth segments between keys, flat tangents.
        for (app.curve[0 .. app.curve.len - 1], app.curve[1..]) |a, b| {
            const dx = (b.pos.x - a.pos.x) / 3;
            g.painter.bezier(g.toScreen(a.pos), g.toScreen(.{ .x = a.pos.x + dx, .y = a.pos.y }), g.toScreen(.{ .x = b.pos.x - dx, .y = b.pos.y }), g.toScreen(b.pos), colors.axis_x, 2);
        }
        handles(ui, g, &app.curve, .{ .snap = .{ .x = 1, .y = 0 } }, "point");
        _ = ui.playhead(g, &app.current, .{});
        boxSelect(&app.curve, ui.endView2D(), shift);
        ui.endVertical();

        ui.beginVertical(.{ .width = .fill, .height = .fill });
        ui.labelf("Image Viewer  {d:.0}%", .{app.viewer.zoom.x * 100}, .{ .color = colors.text_muted });
        const iv = ui.imageView("image", &app.image, &app.viewer, .{});
        // A crop rect drawn over the image, in pixels.
        const crop = iv.rectToScreen(.{ .x = 64, .y = 64, .w = 128, .h = 96 });
        ui.drawRect(.{ .rect = crop, .border = zui.Color.hex(0xF5D547), .border_width = 1.5 });
        _ = ui.endView2D();
        ui.endVertical();
        ui.endHorizontal();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = try .init(init.gpa);
    defer init.gpa.free(app.pixels);
    try harness.runUi(init, .{ .title = "Zui 23: 2D views", .width = 1100, .height = 760 }, &app);
}
