//! Shared demo driver: opens a window, or with `--shot FILE` renders off-screen
//! to a PNG. Demos only supply a function that describes one frame.
//!
//! Flags: `--frames N` quits after N frames, `--shot FILE` writes a PNG without
//! opening a window, `--mouse X,Y` places the pointer for that PNG, `--scale S`
//! renders that PNG at S pixels per unit (HiDPI), `--gl` draws with the OpenGL
//! renderer instead of the software one.
//!
//! `--script FILE` plays a script of clicks, keys and checks without a window
//! (see `zui.ScriptPlayer`); its `shot` lines write PNGs, and a failed line
//! ends the program with an error. `--dump-ui` prints the widgets of the last
//! frame as JSON (`--dump-ui text` for one line each). Both need a `Ui` demo.

const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");
const sdl3 = @import("zui_sdl3");
const opengl = @import("zui_opengl");

/// Window settings.
pub const Options = struct {
    title: [:0]const u8 = "Zui demo",
    width: u32 = 960,
    height: u32 = 640,
    /// Redraw continuously instead of waiting for input.
    animate: bool = false,
};

/// What a raw (no `Ui`) demo gets each frame.
pub const Context = struct {
    list: *zui.DrawList,
    input: *const zui.Input,
    width: f32,
    height: f32,
    /// Seconds since the first frame.
    time: f32,
};

const Args = struct {
    frames: ?u64 = null,
    shot: ?[]const u8 = null,
    mouse: ?zui.Vec2 = null,
    scale: f32 = 1,
    gl: bool = false,
    script: ?[]const u8 = null,
    dump: ?zui.WidgetFormat = null,

    fn parse(init: std.process.Init) !Args {
        const argv = try init.minimal.args.toSlice(init.arena.allocator());
        var args: Args = .{};
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            const has_value = i + 1 < argv.len;
            if (std.mem.eql(u8, argv[i], "--frames") and has_value) {
                i += 1;
                args.frames = try std.fmt.parseInt(u64, argv[i], 10);
            } else if (std.mem.eql(u8, argv[i], "--shot") and has_value) {
                i += 1;
                args.shot = argv[i];
            } else if (std.mem.eql(u8, argv[i], "--scale") and has_value) {
                i += 1;
                args.scale = std.math.clamp(try std.fmt.parseFloat(f32, argv[i]), 0.5, 4);
            } else if (std.mem.eql(u8, argv[i], "--script") and has_value) {
                i += 1;
                args.script = argv[i];
            } else if (std.mem.eql(u8, argv[i], "--dump-ui")) {
                args.dump = .json;
                if (has_value and std.mem.eql(u8, argv[i + 1], "text")) {
                    i += 1;
                    args.dump = .text;
                } else if (has_value and std.mem.eql(u8, argv[i + 1], "json")) {
                    i += 1;
                }
            } else if (std.mem.eql(u8, argv[i], "--gl")) {
                args.gl = true;
            } else if (std.mem.eql(u8, argv[i], "--mouse") and has_value) {
                i += 1;
                var parts = std.mem.splitScalar(u8, argv[i], ',');
                args.mouse = .{
                    .x = try std.fmt.parseFloat(f32, parts.first()),
                    .y = try std.fmt.parseFloat(f32, parts.next() orelse return error.InvalidArguments),
                };
            } else {
                std.log.err("unknown argument: {s}", .{argv[i]});
                return error.InvalidArguments;
            }
        }
        return args;
    }
};

const FrameInfo = struct { width: f32, height: f32, time: f32, dt: f32 };

/// A frame source: either raw draw commands or a `Ui`.
fn RawDriver(comptime App: type) type {
    return struct {
        app: App,
        input: *zui.Input,
        list: *zui.DrawList,
        clear: zui.Color = zui.Color.hex(0x202226),
        animate: bool,

        fn frame(self: *@This(), info: FrameInfo) !*const zui.DrawList {
            var ctx: Context = .{
                .list = self.list,
                .input = self.input,
                .width = info.width,
                .height = info.height,
                .time = info.time,
            };
            self.list.clear();
            try self.app.frame(&ctx);
            self.input.clearEdges();
            return self.list;
        }

        fn wantsRedraw(self: *const @This()) bool {
            return self.animate;
        }

        fn redrawIn(_: *const @This()) ?f32 {
            return null;
        }

        fn setClipboard(_: *@This(), _: zui.Clipboard) void {}

        fn cursor(_: *const @This()) zui.Cursor {
            return .default;
        }

        fn renderFrame(_: *const @This(), width: f32, height: f32, scale: f32) zui.Frame {
            return .{ .width = width, .height = height, .scale = scale };
        }

        fn samplePoint(_: *const @This()) ?zui.Vec2 {
            return null;
        }
    };
}

fn UiDriver(comptime App: type) type {
    return struct {
        app: App,
        ui: *zui.Ui,
        input: *zui.Input,
        clear: zui.Color = .black,
        animate: bool,

        fn frame(self: *@This(), info: FrameInfo) !*const zui.DrawList {
            self.ui.beginFrame(.{ .width = info.width, .height = info.height, .dt = info.dt });
            try self.app.frame(self.ui);
            self.clear = self.ui.style.colors.background;
            return self.ui.endFrame();
        }

        fn wantsRedraw(self: *const @This()) bool {
            return self.animate or self.ui.redraw_requested;
        }

        fn redrawIn(self: *const @This()) ?f32 {
            return self.ui.redraw_in;
        }

        fn setClipboard(self: *@This(), clipboard: zui.Clipboard) void {
            self.ui.clipboard = clipboard;
        }

        fn cursor(self: *const @This()) zui.Cursor {
            return self.ui.cursor;
        }

        fn renderFrame(self: *const @This(), _: f32, _: f32, scale: f32) zui.Frame {
            return self.ui.renderFrame(scale);
        }

        /// Where the eyedropper wants a pixel, in UI units.
        fn samplePoint(self: *const @This()) ?zui.Vec2 {
            return self.ui.sample_request;
        }
    };
}

/// Reads back the pixel the eyedropper asked for; true if it changed.
fn sample(driver: anytype, frame: zui.Frame, renderer: anytype) bool {
    const p = driver.samplePoint() orelse return false;
    const x: i32 = @intFromFloat(@floor(p.x * frame.scale));
    const y: i32 = @intFromFloat(@floor(p.y * frame.scale));
    const c = renderer.pixelAt(x, y) orelse return false;
    return driver.input.onColorSample(c);
}

/// Writes the renderer's framebuffer to a PNG at `path`.
pub fn writeShot(io: std.Io, sw: *const software.SoftwareRenderer, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try software.png.write(&writer.interface, sw.pixels, sw.width, sw.height);
    try writer.interface.flush();
}

/// Runs a demo that records raw draw commands.
/// `app.frame(ctx: *Context) !void` is called once per frame.
pub fn run(init: std.process.Init, options: Options, app: anytype) !void {
    var list: zui.DrawList = .init(init.gpa);
    defer list.deinit();
    var input: zui.Input = .{};
    var driver: RawDriver(@TypeOf(app)) = .{ .app = app, .input = &input, .list = &list, .animate = options.animate };
    try loop(init, options, &driver);
}

/// Runs a demo built on `Ui`, with the default font.
/// `app.frame(ui: *zui.Ui) !void` is called once per frame.
pub fn runUi(init: std.process.Init, options: Options, app: anytype) !void {
    var font: zui.Font = try .initDefault(init.gpa);
    defer font.deinit();
    var ui: zui.Ui = .init(init.gpa, .{ .font = &font });
    defer ui.deinit();
    var driver: UiDriver(@TypeOf(app)) = .{ .app = app, .ui = &ui, .input = &ui.input, .animate = options.animate };
    try loop(init, options, &driver);
}

/// Runs without a window: plays the script, writes shots, dumps widgets.
fn headless(init: std.process.Init, options: Options, args: Args, driver: anytype, sw: *software.SoftwareRenderer) !void {
    const has_ui = @hasField(@TypeOf(driver.*), "ui");
    if (!has_ui and (args.script != null or args.dump != null)) {
        std.log.err("--script and --dump-ui need a demo built on zui.Ui", .{});
        return error.InvalidArguments;
    }
    const scale = args.scale;
    try sw.resize(@intFromFloat(@round(@as(f32, @floatFromInt(options.width)) * scale)), @intFromFloat(@round(@as(f32, @floatFromInt(options.height)) * scale)));
    const width: f32 = @floatFromInt(options.width);
    const height: f32 = @floatFromInt(options.height);
    var time: f32 = 0;
    var list: *const zui.DrawList = undefined;
    if (has_ui) driver.ui.recording = args.dump != null;

    if (has_ui and args.script != null) {
        const path = args.script.?;
        const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1024 * 1024)) catch |err| {
            std.log.err("could not read {s}: {s}", .{ path, @errorName(err) });
            return err;
        };
        defer init.gpa.free(text);
        var player: zui.ScriptPlayer = try .init(init.gpa, text);
        defer player.deinit();
        var frames: usize = 0;
        while (player.next(driver.ui) catch |err| {
            std.log.err("{s}: {s}", .{ path, player.message() });
            return err;
        }) |step| switch (step) {
            .frame => |dt| {
                time += dt;
                list = try driver.frame(.{ .width = width, .height = height, .time = time, .dt = dt });
                frames += 1;
                // The eyedropper needs the pixels of each frame.
                if (driver.samplePoint() != null) {
                    const f = driver.renderFrame(width, height, scale);
                    sw.clear_color = driver.clear;
                    sw.renderer().render(list, f);
                    _ = sample(driver, f, sw);
                }
            },
            .shot => |shot| {
                sw.clear_color = driver.clear;
                sw.renderer().render(list, driver.renderFrame(width, height, scale));
                try writeShot(init.io, sw, shot);
            },
        };
        std.log.info("{s}: done, {d} frames", .{ path, frames });
    } else {
        // Run until the layout settles, the same as the window loop does.
        for (0..8) |_| {
            if (args.mouse) |m| driver.input.onMouseMove(m);
            list = try driver.frame(.{ .width = width, .height = height, .time = 0, .dt = 1.0 / 60.0 });
            if (!driver.wantsRedraw()) break;
        }
    }

    if (args.shot) |path| {
        sw.clear_color = driver.clear;
        sw.renderer().render(list, driver.renderFrame(width, height, scale));
        try writeShot(init.io, sw, path);
    }
    if (has_ui) if (args.dump) |format| {
        var buffer: [64 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writer(init.io, &buffer);
        try driver.ui.writeWidgets(&out.interface, format);
        try out.interface.flush();
    };
}

/// How long the event wait may sleep: until `seconds` from now, or forever.
fn waitMs(seconds: ?f32) i32 {
    const s = seconds orelse return -1;
    const ms = @ceil(s * 1000);
    if (ms >= 1_000_000) return 1_000_000;
    return @intFromFloat(ms);
}

fn loop(init: std.process.Init, options: Options, driver: anytype) !void {
    const args = try Args.parse(init);
    var sw: software.SoftwareRenderer = .init(init.gpa);
    defer sw.deinit();

    if (args.shot != null or args.script != null or args.dump != null) return headless(init, options, args, driver, &sw);

    var window = sdl3.Window.init(.{
        .title = options.title,
        .width = options.width,
        .height = options.height,
        .graphics = if (args.gl) .opengl else .software,
    }) catch |err| {
        std.log.err("could not open a window: {s}", .{sdl3.lastError()});
        return err;
    };
    defer window.deinit();
    driver.setClipboard(window.clipboard());
    var gl: ?opengl.GlRenderer = if (args.gl) try opengl.GlRenderer.init(init.gpa, sdl3.glGetProcAddress) else null;
    defer if (gl) |*g| g.deinit();

    const start = sdl3.ticksNs();
    var previous = start;
    var frame: u64 = 0;
    // Input can change what an earlier-described widget should show, so every
    // event is followed by one extra frame before going back to sleep.
    var pending_frames: u32 = 2;
    while (!window.close_requested) : (frame += 1) {
        if (args.frames) |limit| if (frame >= limit) break;

        const can_sleep = args.frames == null and pending_frames == 0 and !driver.wantsRedraw();
        // Sleep until input arrives, or until the UI's next timed change.
        const timeout: ?i32 = if (can_sleep) waitMs(driver.redrawIn()) else null;
        if (window.pollEvents(driver.input, timeout)) pending_frames = 2;
        if (pending_frames > 0) pending_frames -= 1;

        const now = sdl3.ticksNs();
        const size = window.size();
        if (gl == null) try sw.resize(size.pixel_width, size.pixel_height);
        const width: f32 = @floatFromInt(size.width);
        const height: f32 = @floatFromInt(size.height);
        const list = try driver.frame(.{
            .width = width,
            .height = height,
            .time = @as(f32, @floatFromInt(now - start)) / 1e9,
            .dt = @as(f32, @floatFromInt(now - previous)) / 1e9,
        });
        previous = now;
        window.setCursor(driver.cursor());
        const frame_info = driver.renderFrame(width, height, size.scale);
        if (gl) |*g| {
            g.clear_color = driver.clear;
            g.renderer().render(list, frame_info);
            if (sample(driver, frame_info, g)) pending_frames = 2;
            try window.swap();
        } else {
            sw.clear_color = driver.clear;
            sw.renderer().render(list, frame_info);
            if (sample(driver, frame_info, &sw)) pending_frames = 2;
            try window.present(sw.pixels, sw.width, sw.height);
        }
    }
}
