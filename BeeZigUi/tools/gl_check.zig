//! Renders the same UI with the software and OpenGL renderers, reads the GL
//! pixels back from an off-screen framebuffer, and reports how far apart they
//! are. Writes both images and an amplified difference to `gl_check/`.
//!
//!     zig build gl-check
//!
//! Exits with an error if the pictures differ by more than small rounding.

const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");
const sdl3 = @import("zui_sdl3");
const opengl = @import("zui_opengl");

const width = 900;
const height = 620;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var window = sdl3.Window.init(.{ .title = "gl_check", .width = 64, .height = 64, .graphics = .opengl, .hidden = true }) catch |err| {
        std.log.err("could not create a GL context: {s}", .{sdl3.lastError()});
        return err;
    };
    defer window.deinit();
    const fbo: Framebuffer = try .init(width * 2, height * 2);
    defer fbo.deinit();

    var font: zui.Font = try .initDefault(gpa);
    defer font.deinit();
    var gl: opengl.GlRenderer = try .init(gpa, sdl3.glGetProcAddress);
    defer gl.deinit();
    var sw: software.SoftwareRenderer = .init(gpa);
    defer sw.deinit();
    const gl_pixels = try gpa.alloc(u32, width * height * 4);
    defer gpa.free(gl_pixels);

    try std.Io.Dir.cwd().createDirPath(io, "gl_check");
    var failed = false;
    for ([_]zui.Style{ .dark, .light }, [_][]const u8{ "dark", "light" }) |style, theme| {
        for ([_]f32{ 1, 2 }) |scale| {
            var ui: zui.Ui = .init(gpa, .{ .font = &font, .style = style });
            defer ui.deinit();
            var scene: Scene = .{};
            var list: *const zui.DrawList = undefined;
            for (0..6) |_| {
                ui.input.onMouseMove(.{ .x = 70, .y = 92 }); // hover a button
                ui.beginFrame(.{ .width = width, .height = height });
                scene.frame(&ui);
                list = try ui.endFrame();
            }
            const frame: zui.Frame = .{ .width = width, .height = height, .scale = scale };
            const pw: u32 = @intFromFloat(width * scale);
            const ph: u32 = @intFromFloat(height * scale);

            try sw.resize(pw, ph);
            sw.clear_color = ui.style.colors.background;
            sw.renderer().render(list, frame);

            gl.clear_color = ui.style.colors.background;
            gl.renderer().render(list, frame);
            gl.readPixels(gl_pixels[0 .. pw * ph]);

            const stats = compare(sw.pixels, gl_pixels[0 .. pw * ph]);
            const ok = stats.mean < 0.25 and stats.over_16 * 1000 < pw * ph; // <0.1% of pixels visibly off
            if (!ok) failed = true;
            std.debug.print("{s:<5} x{d}: mean diff {d:.3}, max {d}, pixels off by >2: {d:.3}%, >16: {d:.3}%  {s}\n", .{
                theme,                                                  scale,
                stats.mean,                                             stats.max,
                percent(stats.over_2, pw * ph),                         percent(stats.over_16, pw * ph),
                if (ok) "ok" else "TOO DIFFERENT",
            });

            var name_buffer: [64]u8 = undefined;
            try writePng(io, try std.fmt.bufPrint(&name_buffer, "gl_check/{s}-x{d}-software.png", .{ theme, scale }), sw.pixels, pw, ph);
            try writePng(io, try std.fmt.bufPrint(&name_buffer, "gl_check/{s}-x{d}-opengl.png", .{ theme, scale }), gl_pixels[0 .. pw * ph], pw, ph);
            for (gl_pixels[0 .. pw * ph], sw.pixels) |*g, s| g.* = diffPixel(g.*, s);
            try writePng(io, try std.fmt.bufPrint(&name_buffer, "gl_check/{s}-x{d}-diff.png", .{ theme, scale }), gl_pixels[0 .. pw * ph], pw, ph);
        }
    }
    try timeRenderers(gpa, io, &font, &gl, &sw, fbo);
    if (failed) return error.RenderersDiffer;
}

/// Times both renderers on the same frame. `glFinish` makes the GPU's work
/// count, not just the time to queue it.
fn timeRenderers(gpa: std.mem.Allocator, io: std.Io, font: *zui.Font, gl: *opengl.GlRenderer, sw: *software.SoftwareRenderer, fbo: Framebuffer) !void {
    var ui: zui.Ui = .init(gpa, .{ .font = font });
    defer ui.deinit();
    var scene: Scene = .{};
    var list: *const zui.DrawList = undefined;
    for (0..6) |_| {
        ui.beginFrame(.{ .width = width, .height = height });
        scene.frame(&ui);
        list = try ui.endFrame();
    }
    const frame: zui.Frame = .{ .width = width, .height = height, .scale = 1 };
    try sw.resize(width, height);
    const runs = 300;
    var times: [2]u64 = .{ 0, 0 };
    for (0..2) |which| {
        // Warm up: glyphs into the atlas, shaders compiled, caches filled.
        for (0..10) |_| render(which, gl, sw, list, frame, fbo);
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        for (0..runs) |_| render(which, gl, sw, list, frame, fbo);
        times[which] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - start);
    }
    std.debug.print("\nRender time per frame at {d}x{d}: software {d:.0} us, OpenGL {d:.0} us\n", .{
        width, height, us(times[0] / runs), us(times[1] / runs),
    });
}

fn render(which: usize, gl: *opengl.GlRenderer, sw: *software.SoftwareRenderer, list: *const zui.DrawList, frame: zui.Frame, fbo: Framebuffer) void {
    if (which == 0) {
        sw.renderer().render(list, frame);
    } else {
        gl.renderer().render(list, frame);
        fbo.gl.Finish();
    }
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000;
}

const Stats = struct { mean: f64, max: u8, over_2: usize, over_16: usize };

fn compare(a: []const u32, b: []const u32) Stats {
    var total: u64 = 0;
    var stats: Stats = .{ .mean = 0, .max = 0, .over_2 = 0, .over_16 = 0 };
    for (a, b) |x, y| {
        const d = channelDiff(x, y);
        total += d;
        stats.max = @max(stats.max, d);
        if (d > 2) stats.over_2 += 1;
        if (d > 16) stats.over_16 += 1;
    }
    stats.mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(a.len));
    return stats;
}

/// The largest difference between two pixels in any channel.
fn channelDiff(x: u32, y: u32) u8 {
    var d: u8 = 0;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const cx: u8 = @truncate(x >> shift);
        const cy: u8 = @truncate(y >> shift);
        d = @max(d, if (cx > cy) cx - cy else cy - cx);
    }
    return d;
}

/// Black where equal, brighter red the more they differ (x8).
fn diffPixel(x: u32, y: u32) u32 {
    const d: u32 = @min(255, @as(u32, channelDiff(x, y)) * 8);
    return 0xFF000000 | (d << 16);
}

fn percent(n: usize, total: usize) f64 {
    return @as(f64, @floatFromInt(n)) * 100 / @as(f64, @floatFromInt(total));
}

fn writePng(io: std.Io, path: []const u8, pixels: []const u32, w: u32, h: u32) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try software.png.write(&writer.interface, pixels, w, h);
    try writer.interface.flush();
}

/// Every kind of thing the renderers draw.
const Scene = struct {
    flag: bool = true,
    value: f32 = 0.35,
    count: i32 = 7,
    text: [32]u8 = "Kerning: AVATAR, WAVE".* ++ @as([11]u8, @splat(0)),
    text_len: usize = 21,
    color: zui.Color = .{ .r = 220, .g = 80, .b = 60, .a = 140 },

    fn frame(s: *Scene, ui: *zui.Ui) void {
        ui.beginHorizontal(.{ .alignment = .start, .spacing = 24, .height = .fill });
        ui.beginVertical(.{ .width = .px(380) });
        ui.label("Labels at the theme size, and translucent:", .{});
        ui.label("Secondary text", .{ .color = ui.style.colors.text_muted });
        ui.beginHorizontal(.{});
        _ = ui.button("Hovered", .{});
        _ = ui.button("Plain", .{});
        ui.pushMetric(.rounding, 14);
        _ = ui.button("Round", .{});
        ui.popStyle();
        ui.endHorizontal();
        _ = ui.checkbox("Checkbox", &s.flag, .{});
        _ = ui.slider("Slider", &s.value, 0, 1, .{});
        _ = ui.slider("Int", &s.count, 0, 10, .{});
        _ = ui.textInput("Text", &s.text, &s.text_len, .{});
        _ = ui.colorEdit("Translucent", &s.color, .{});
        ui.separator();
        if (ui.treeNode("Tree", .{ .default_open = true })) {
            _ = ui.selectable("Selected row", true, .{});
            ui.label("Child", .{});
            ui.treePop();
        }
        ui.endVertical();

        ui.beginVertical(.{ .width = .fill });
        const columns = [_]zui.TableColumn{ .{ .name = "Name", .sort = .ascending }, .{ .name = "Size", .width = .px(90) } };
        _ = ui.beginTable("t", &columns, .{ .height = .px(150) });
        for (0..8) |i| {
            ui.tableRow();
            ui.labelf("Row {d}", .{i}, .{});
            ui.tableNextColumn();
            ui.labelf("{d} KB", .{i * 13}, .{});
        }
        ui.endTable();
        const r = ui.placeSized(.fill, .px(80), .{});
        ui.drawRect(.{ .rect = r, .fill = zui.Color.hex(0x3070D0).withAlpha(120), .border = zui.Color.hex(0xF0C040), .border_width = 3, .radius = 16 });
        shapes(ui);
        ui.endVertical();
        ui.endHorizontal();

        if (ui.beginWindow("Window with a shadow", .{ .position = .{ .x = 470, .y = 360 }, .size = .{ .x = 300, .y = 150 } })) {
            defer ui.endWindow();
            ui.label("Inside a window", .{});
            _ = ui.button("Button", .{});
        }
        // The radial wheel: wedges, its shadow, icons and an open arc.
        if (ui.frame_index == 1) ui.openWheel("wheel", null);
        _ = ui.wheel("wheel", &wheel_items, .{});
    }

    const wheel_kids = [_]zui.WheelItem{ .{ .label = "Cube" }, .{ .label = "Sphere", .icon = .{ .builtin = .dot } } };
    const wheel_items = [_]zui.WheelItem{
        .{ .label = "Add", .icon = .{ .builtin = .plus }, .color = zui.Color.hex(0x3C7A4F), .children = &wheel_kids },
        .{ .label = "Delete", .icon = .{ .builtin = .close }, .color = zui.Color.hex(0x9A3B36) },
        .{ .label = "Hide", .icon = .{ .builtin = .eye_off }, .color = zui.Color.hex(0x5C5F66) },
        .{ .label = "Parent", .icon = .{ .builtin = .link }, .disabled = "Select two" },
        .{ .label = "Snap", .icon = .{ .builtin = .lock }, .color = zui.Color.hex(0x7A3F6E) },
    };
};

var images_ready = false;
var argb_pixels: [32 * 32]u32 = undefined;
var alpha_pixels: [16 * 16]u8 = undefined;
var argb_image: zui.Image = undefined;
var alpha_image: zui.Image = undefined;
var icon_set: zui.IconSet = undefined;

/// Paths, meshes, images and icons, through a canvas.
fn shapes(ui: *zui.Ui) void {
    if (!images_ready) {
        // A translucent gradient with hard edges, and a ring mask.
        for (0..32) |y| for (0..32) |x| {
            const a: u32 = if ((x / 8 + y / 8) % 2 == 0) 255 else @intCast(x * 8);
            argb_pixels[y * 32 + x] = (a << 24) | (@as(u32, @intCast(y * 8)) << 16) | 0x4080;
        };
        for (0..16) |y| for (0..16) |x| {
            const dx = @as(f32, @floatFromInt(x)) - 7.5;
            const dy = @as(f32, @floatFromInt(y)) - 7.5;
            const d = @sqrt(dx * dx + dy * dy);
            alpha_pixels[y * 16 + x] = if (d > 3 and d < 7) 255 else 0;
        };
        argb_image = .initArgb(&argb_pixels, 32, 32);
        alpha_image = .initAlpha(&alpha_pixels, 16, 16);
        icon_set = .grid(&alpha_image, 16, 16);
        images_ready = true;
    }
    const c = ui.beginCanvas("shapes", .{ .height = .fill });
    defer ui.endCanvas();
    const p = c.painter;
    const o = c.rect;
    const at = struct {
        fn f(r: zui.Rect, x: f32, y: f32) zui.Vec2 {
            return .{ .x = r.x + x, .y = r.y + y };
        }
    }.f;
    const text = ui.style.colors.text;
    const accent = ui.style.colors.accent;
    for ([_]f32{ 0.5, 1, 2, 5 }, 0..) |w, i| {
        const fi: f32 = @floatFromInt(i);
        p.line(at(o, 10, 10 + fi * 12), at(o, 120, 30 + fi * 18), text, w);
    }
    p.line(at(o, 10, 95), at(o, 120, 95), text, 1);
    p.dashedLine(at(o, 10, 105), at(o, 120, 105), accent, 2, 6, 4);
    p.circle(at(o, 160, 30), 18, accent.withAlpha(180));
    p.circleOutline(at(o, 160, 30), 24, text, 1.5);
    p.ringSegment(at(o, 230, 45), 18, 34, -2.6, -0.6, accent);
    p.arc(at(o, 230, 45), 38, 0.3, 2.6, text, 3);
    p.pie(at(o, 290, 30), 22, 0.2, 2.5, zui.Color.hex(0x3C9A5F));
    p.polygon(&.{ at(o, 130, 70), at(o, 180, 62), at(o, 190, 100), at(o, 140, 108) }, zui.Color.hex(0xD05050).withAlpha(200));
    p.bezier(at(o, 200, 70), at(o, 260, 70), at(o, 240, 110), at(o, 320, 100), accent, 2.5);
    p.gradient(.{ .x = o.x + 330, .y = o.y + 8, .w = 60, .h = 60 }, .white, zui.Color.hex(0xFF3000), .black, .black);
    p.image(&argb_image, .{ .x = o.x + 330, .y = o.y + 75, .w = 32, .h = 32 }, .{ .filter = .nearest });
    p.image(&argb_image, .{ .x = o.x + 368, .y = o.y + 75, .w = 45, .h = 45 }, .{ .filter = .linear });
    p.icon(icon_set.icon(0), .{ .x = o.x + 300, .y = o.y + 80, .w = 16, .h = 16 }, text);
    p.icon(.{ .builtin = .search }, .{ .x = o.x + 270, .y = o.y + 80, .w = 20, .h = 20 }, text);
}

/// An off-screen RGBA8 framebuffer, so reading pixels back doesn't depend on
/// a visible window.
const Framebuffer = struct {
    fbo: u32,
    color: u32,
    gl: Fns,

    const Fns = struct {
        GenFramebuffers: *const fn (i32, *u32) callconv(.c) void,
        DeleteFramebuffers: *const fn (i32, *const u32) callconv(.c) void,
        BindFramebuffer: *const fn (u32, u32) callconv(.c) void,
        GenRenderbuffers: *const fn (i32, *u32) callconv(.c) void,
        DeleteRenderbuffers: *const fn (i32, *const u32) callconv(.c) void,
        BindRenderbuffer: *const fn (u32, u32) callconv(.c) void,
        RenderbufferStorage: *const fn (u32, u32, i32, i32) callconv(.c) void,
        FramebufferRenderbuffer: *const fn (u32, u32, u32, u32) callconv(.c) void,
        CheckFramebufferStatus: *const fn (u32) callconv(.c) u32,
        Finish: *const fn () callconv(.c) void,
    };

    const GL_FRAMEBUFFER = 0x8D40;
    const GL_RENDERBUFFER = 0x8D41;
    const GL_RGBA8 = 0x8058;
    const GL_COLOR_ATTACHMENT0 = 0x8CE0;
    const GL_FRAMEBUFFER_COMPLETE = 0x8CD5;

    fn init(w: i32, h: i32) !Framebuffer {
        var gl: Fns = undefined;
        inline for (comptime std.meta.fieldNames(Fns)) |name| {
            const ptr = sdl3.glGetProcAddress("gl" ++ name) orelse return error.MissingGlFunction;
            @field(gl, name) = @ptrCast(@alignCast(ptr));
        }
        var self: Framebuffer = .{ .fbo = 0, .color = 0, .gl = gl };
        gl.GenFramebuffers(1, &self.fbo);
        gl.BindFramebuffer(GL_FRAMEBUFFER, self.fbo);
        gl.GenRenderbuffers(1, &self.color);
        gl.BindRenderbuffer(GL_RENDERBUFFER, self.color);
        gl.RenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, w, h);
        gl.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, self.color);
        if (gl.CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return error.FramebufferIncomplete;
        return self;
    }

    fn deinit(self: *const Framebuffer) void {
        self.gl.DeleteRenderbuffers(1, &self.color);
        self.gl.DeleteFramebuffers(1, &self.fbo);
    }
};
