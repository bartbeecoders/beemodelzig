//! Renders a UI to a PNG file, with no window and no C library.
//!
//!     zig build run-render_png -- out.png
//!
//! This is the whole backend story in one file: describe frames with `Ui`,
//! feed it input yourself, and hand the draw list to any `Renderer`. Here the
//! renderer is the pure-Zig software rasterizer and the output is a file, but
//! the same list could go to a GPU, a terminal or a test that inspects it.

const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else "render_png.png";

    var font: zui.Font = try .initDefault(gpa);
    defer font.deinit();
    var ui: zui.Ui = .init(gpa, .{ .font = &font, .style = .light });
    defer ui.deinit();

    const width = 480;
    const height = 260;
    var report: Report = .{};

    // Input is just data. Put the pointer over the button so it renders in
    // its hovered state.
    ui.input.onMouseMove(.{ .x = 60, .y = 150 });

    // Layout settles over a frame or two (groups remember their size), and
    // the Ui says when it wants another frame.
    var list: *const zui.DrawList = undefined;
    var frames: u32 = 0;
    while (true) {
        frames += 1;
        ui.beginFrame(.{ .width = width, .height = height });
        report.frame(&ui);
        list = try ui.endFrame();
        if (!ui.redraw_requested or frames == 10) break;
    }

    var sw: software.SoftwareRenderer = .init(gpa);
    defer sw.deinit();
    try sw.resize(width, height);
    sw.clear_color = ui.style.colors.background;
    sw.renderer().render(list, .{ .width = width, .height = height });

    const io = init.io;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try software.png.write(&writer.interface, sw.pixels, sw.width, sw.height);
    try writer.interface.flush();
    std.debug.print("wrote {s} ({d}x{d}, {d} frames to settle, {d} draw commands)\n", .{ path, width, height, frames, list.commands.items.len });
}

/// A small status report, the sort of thing a tool might render into a CI
/// artifact or an email.
const Report = struct {
    passed: u32 = 1287,
    failed: u32 = 3,
    coverage: f32 = 0.84,
    strict: bool = true,

    fn frame(r: *Report, ui: *zui.Ui) void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };
        ui.label("Nightly build report", .{});
        ui.labelf("{d} tests passed, {d} failed", .{ r.passed, r.failed }, muted);
        ui.separator();
        _ = ui.slider("Coverage", &r.coverage, 0, 1, .{ .decimals = 2 });
        _ = ui.checkbox("Strict mode", &r.strict, .{});
        ui.beginHorizontal(.{});
        _ = ui.button("Open details", .{});
        ui.pushColor(.button, zui.Color.hex(0xD9534F));
        ui.pushColor(.text, zui.Color.white);
        _ = ui.button("3 failures", .{});
        ui.popStyles(2);
        ui.endHorizontal();
    }
};
