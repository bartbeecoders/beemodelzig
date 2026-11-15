//! Embedding Zui in an app that owns its window and framebuffer, as
//! BeeModel does: the app draws its own pixels (a 3D view here), passes
//! its input events to `ui.input`, and lets the software renderer draw the
//! UI over its pixels, in place. No window library, no copy.
//!
//!     ./run.sh embed out.png
//!
//! The loop, in an app with a window of its own:
//!
//!     // input, from the app's own event loop
//!     ui.input.onMouseMove(.{ .x = x, .y = y });
//!     ui.input.onMouseButton(.left, pressed);
//!     ui.input.onKeyPress(.enter);
//!     ui.input.onText("é");
//!     // a frame
//!     drawMyScene(framebuffer);
//!     ui.beginFrame(.{ .width = units_w, .height = units_h, .dt = dt });
//!     describeUi(&ui);
//!     sw.useBuffer(framebuffer, pixel_w, pixel_h); // once, or when it moves
//!     sw.clear = false;                            // keep the app's pixels
//!     sw.renderer().render(try ui.endFrame(), ui.renderFrame(display_scale));
//!     present(framebuffer);
//!     window.setCursor(ui.cursor);
//!
//! While `ui.wantsKeyboard()` is true, keep keys to the UI; while the
//! pointer is over a window or widget (`ui.hovered_window`,
//! `ui.hoveredWidget()`), keep the pointer to it too.

const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");

const width = 720;
const height = 420;

/// The app's own drawing: a sky, a floor grid and a sun.
fn drawScene(pixels: []u32, t: f32) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const fy: f32 = @floatFromInt(y);
            const fx: f32 = @floatFromInt(x);
            var c: u32 = 0;
            if (y < height / 2) {
                const k = fy / (height / 2);
                c = 0xFF000000 | @as(u32, @intFromFloat(40 + 60 * k)) << 16 | @as(u32, @intFromFloat(70 + 80 * k)) << 8 | 160;
            } else {
                const gx = @mod(fx + t * 20, 40) < 1.5;
                const gy = @mod(fy, 24) < 1.5;
                c = if (gx or gy) 0xFF5A6070 else 0xFF2E3138;
            }
            const dx = fx - 560;
            const dy = fy - 90;
            if (dx * dx + dy * dy < 900) c = 0xFFF5D547;
            pixels[y * width + x] = c;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_path = if (args.len > 1) args[1] else "embed.png";
    const gpa = init.gpa;

    // The app's framebuffer: a window buffer in a real app.
    const pixels = try gpa.alloc(u32, width * height);
    defer gpa.free(pixels);

    var font: zui.Font = try .initDefault(gpa);
    defer font.deinit();
    var ui: zui.Ui = .init(gpa, .{ .font = &font });
    defer ui.deinit();
    var sw: software.SoftwareRenderer = .init(gpa);
    defer sw.deinit();
    sw.useBuffer(pixels, width, height);
    sw.clear = false;

    var exposure: f32 = 0.6;
    var shadows = true;
    var renders: u32 = 0;
    // A few frames of the app's loop, with input as its event loop would
    // pass it: the pointer goes to the Render button and clicks it.
    for (0..6) |frame| {
        if (frame == 2) ui.input.onMouseMove(.{ .x = 80, .y = 160 });
        if (frame == 3) ui.input.onMouseButton(.left, true);
        if (frame == 4) ui.input.onMouseButton(.left, false);

        drawScene(pixels, @floatFromInt(frame));
        ui.beginFrame(.{ .width = width, .height = height });
        if (ui.beginWindow("Render", .{ .position = .{ .x = 24, .y = 24 }, .size = .{ .x = 260, .y = 210 } })) {
            defer ui.endWindow();
            _ = ui.slider("Exposure", &exposure, 0, 1, .{ .width = .fill });
            _ = ui.checkbox("Shadows", &shadows, .{});
            if (ui.button("Render", .{ .width = .fill }).clicked) renders += 1;
            ui.labelf("Rendered {d} times", .{renders}, .{});
        }
        const list = try ui.endFrame();
        sw.renderer().render(list, ui.renderFrame(1));
    }

    var file = try std.Io.Dir.cwd().createFile(init.io, out_path, .{});
    defer file.close(init.io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try software.png.write(&writer.interface, pixels, width, height);
    try writer.interface.flush();
    std.log.info("wrote {s}; Render was clicked {d} time(s)", .{ out_path, renders });
}
