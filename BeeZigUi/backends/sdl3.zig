//! Window, input and presentation through SDL3.
//!
//! This is the only module in the project that needs a C library. The SDL API
//! is declared by hand, so building needs the SDL3 shared library but no
//! headers. `Window` knows nothing about how pixels are produced: `present`
//! takes any `0xAARRGGBB` buffer.

const std = @import("std");
const zui = @import("zui");

const c = struct {
    const Window = opaque {};
    const Renderer = opaque {};
    const Texture = opaque {};

    const init_video: u32 = 0x20;
    const window_opengl: u64 = 0x2;
    const window_hidden: u64 = 0x8;
    const window_resizable: u64 = 0x20;
    const gl_doublebuffer: c_int = 5;
    const gl_context_major_version: c_int = 17;
    const gl_context_minor_version: c_int = 18;
    const gl_context_profile_mask: c_int = 20;
    const gl_context_profile_core: c_int = 1;
    const window_high_pixel_density: u64 = 0x2000;
    const pixelformat_argb8888: u32 = 0x16362004;
    const textureaccess_streaming: c_int = 1;

    const event_quit: u32 = 0x100;
    const event_key_down: u32 = 0x300;
    const event_key_up: u32 = 0x301;
    const event_text_input: u32 = 0x303;
    const event_mouse_motion: u32 = 0x400;
    const event_mouse_button_down: u32 = 0x401;
    const event_mouse_button_up: u32 = 0x402;
    const event_mouse_wheel: u32 = 0x403;
    const event_drop_file: u32 = 0x1000;
    const event_window_first: u32 = 0x202;
    const event_window_last: u32 = 0x21F;

    const kmod_shift: u16 = 0x0003;
    const kmod_ctrl: u16 = 0x00C0;
    const kmod_alt: u16 = 0x0300;
    const kmod_gui: u16 = 0x0C00;

    const Header = extern struct { type: u32, reserved: u32, timestamp: u64 };
    const KeyboardEvent = extern struct {
        header: Header,
        window_id: u32,
        which: u32,
        scancode: u32,
        key: u32,
        mod: u16,
        raw: u16,
        down: bool,
        repeat: bool,
    };
    const TextInputEvent = extern struct {
        header: Header,
        window_id: u32,
        text: [*:0]const u8,
    };
    const MouseMotionEvent = extern struct {
        header: Header,
        window_id: u32,
        which: u32,
        state: u32,
        x: f32,
        y: f32,
        xrel: f32,
        yrel: f32,
    };
    const MouseButtonEvent = extern struct {
        header: Header,
        window_id: u32,
        which: u32,
        button: u8,
        down: bool,
        clicks: u8,
        padding: u8,
        x: f32,
        y: f32,
    };
    const MouseWheelEvent = extern struct {
        header: Header,
        window_id: u32,
        which: u32,
        x: f32,
        y: f32,
        direction: u32,
        mouse_x: f32,
        mouse_y: f32,
    };
    const DropEvent = extern struct {
        header: Header,
        window_id: u32,
        x: f32,
        y: f32,
        source: ?[*:0]const u8,
        data: ?[*:0]const u8,
    };
    const Event = extern union {
        drop: DropEvent,
        header: Header,
        key: KeyboardEvent,
        text: TextInputEvent,
        motion: MouseMotionEvent,
        button: MouseButtonEvent,
        wheel: MouseWheelEvent,
        padding: [128]u8,
    };

    extern fn SDL_Init(flags: u32) bool;
    extern fn SDL_Quit() void;
    extern fn SDL_GetError() [*:0]const u8;
    extern fn SDL_CreateWindow(title: [*:0]const u8, w: c_int, h: c_int, flags: u64) ?*c.Window;
    extern fn SDL_DestroyWindow(window: *c.Window) void;
    extern fn SDL_GetWindowSize(window: *c.Window, w: *c_int, h: *c_int) bool;
    extern fn SDL_GetWindowSizeInPixels(window: *c.Window, w: *c_int, h: *c_int) bool;
    extern fn SDL_StartTextInput(window: *c.Window) bool;
    extern fn SDL_CreateRenderer(window: *c.Window, name: ?[*:0]const u8) ?*c.Renderer;
    extern fn SDL_DestroyRenderer(renderer: *c.Renderer) void;
    extern fn SDL_SetRenderVSync(renderer: *c.Renderer, vsync: c_int) bool;
    extern fn SDL_CreateTexture(renderer: *c.Renderer, format: u32, access: c_int, w: c_int, h: c_int) ?*c.Texture;
    extern fn SDL_DestroyTexture(texture: *c.Texture) void;
    extern fn SDL_UpdateTexture(texture: *c.Texture, rect: ?*const anyopaque, pixels: *const anyopaque, pitch: c_int) bool;
    extern fn SDL_RenderTexture(renderer: *c.Renderer, texture: *c.Texture, src: ?*const anyopaque, dst: ?*const anyopaque) bool;
    extern fn SDL_RenderPresent(renderer: *c.Renderer) bool;
    extern fn SDL_PollEvent(event: *Event) bool;
    extern fn SDL_WaitEventTimeout(event: *Event, timeout_ms: i32) bool;
    extern fn SDL_GetTicksNS() u64;
    extern fn SDL_GetModState() u16;
    extern fn SDL_GL_SetAttribute(attr: c_int, value: c_int) bool;
    extern fn SDL_GL_CreateContext(window: *c.Window) ?*anyopaque;
    extern fn SDL_GL_DestroyContext(context: *anyopaque) bool;
    extern fn SDL_GL_MakeCurrent(window: *c.Window, context: ?*anyopaque) bool;
    extern fn SDL_GL_SetSwapInterval(interval: c_int) bool;
    extern fn SDL_GL_SwapWindow(window: *c.Window) bool;
    extern fn SDL_GL_GetProcAddress(name: [*:0]const u8) ?*const fn () callconv(.c) void;
    extern fn SDL_GetClipboardText() ?[*:0]u8;
    extern fn SDL_SetClipboardText(text: [*:0]const u8) bool;
    extern fn SDL_strndup(text: [*]const u8, max_len: usize) ?[*:0]u8;
    extern fn SDL_free(memory: ?*anyopaque) void;
    extern fn SDL_CreateSystemCursor(id: c_int) ?*anyopaque;
    extern fn SDL_SetCursor(cursor: ?*anyopaque) bool;
    extern fn SDL_DestroyCursor(cursor: *anyopaque) void;
};

/// Errors from SDL. Call `lastError` for the message.
pub const Error = error{SdlFailed};

/// Returns SDL's message for the most recent failure.
pub fn lastError() [:0]const u8 {
    return std.mem.span(c.SDL_GetError());
}

/// Returns a monotonic timestamp in nanoseconds.
pub fn ticksNs() u64 {
    return c.SDL_GetTicksNS();
}

/// Looks up an OpenGL function, for an OpenGL renderer's loader. Needs a
/// window opened with `.graphics = .opengl`.
pub fn glGetProcAddress(name: [*:0]const u8) ?*const anyopaque {
    const f = c.SDL_GL_GetProcAddress(name) orelse return null;
    return @ptrCast(f);
}

/// How a window's contents get to the screen.
pub const Graphics = enum {
    /// `present` uploads a CPU pixel buffer.
    software,
    /// An OpenGL 3.3 core context is current; draw with GL, then `swap`.
    opengl,
};

/// A resizable OS window that shows a CPU pixel buffer, or hosts an OpenGL
/// context.
pub const Window = struct {
    window: *c.Window,
    /// Set for `.software` windows.
    renderer: ?*c.Renderer = null,
    /// Set for `.opengl` windows.
    gl_context: ?*anyopaque = null,
    texture: ?*c.Texture = null,
    texture_width: u32 = 0,
    texture_height: u32 = 0,
    /// Set once the user asks to close the window.
    close_requested: bool = false,
    /// The last text read from the clipboard, owned by SDL.
    clipboard_text: ?[*:0]u8 = null,
    /// System cursors, created on first use.
    cursors: std.EnumArray(zui.Cursor, ?*anyopaque) = .initFill(null),
    cursor: zui.Cursor = .default,

    /// Options for `init`.
    pub const Options = struct {
        title: [:0]const u8 = "Zui",
        /// Logical width.
        width: u32 = 960,
        /// Logical height.
        height: u32 = 640,
        graphics: Graphics = .software,
        /// Don't show the window, for example to render off-screen with GL.
        hidden: bool = false,
    };

    /// Logical size, pixel size and their ratio.
    pub const Size = struct { width: u32, height: u32, pixel_width: u32, pixel_height: u32, scale: f32 };

    /// Opens a window. Pair with `deinit`.
    pub fn init(options: Options) Error!Window {
        if (!c.SDL_Init(c.init_video)) return error.SdlFailed;
        errdefer c.SDL_Quit();

        var flags = c.window_resizable | c.window_high_pixel_density;
        if (options.hidden) flags |= c.window_hidden;
        if (options.graphics == .opengl) {
            flags |= c.window_opengl;
            _ = c.SDL_GL_SetAttribute(c.gl_context_major_version, 3);
            _ = c.SDL_GL_SetAttribute(c.gl_context_minor_version, 3);
            _ = c.SDL_GL_SetAttribute(c.gl_context_profile_mask, c.gl_context_profile_core);
            _ = c.SDL_GL_SetAttribute(c.gl_doublebuffer, 1);
        }
        const window = c.SDL_CreateWindow(options.title, @intCast(options.width), @intCast(options.height), flags) orelse
            return error.SdlFailed;
        errdefer c.SDL_DestroyWindow(window);
        _ = c.SDL_StartTextInput(window);

        switch (options.graphics) {
            .software => {
                const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlFailed;
                // VSync is best effort; some drivers refuse it.
                _ = c.SDL_SetRenderVSync(renderer, 1);
                return .{ .window = window, .renderer = renderer };
            },
            .opengl => {
                const context = c.SDL_GL_CreateContext(window) orelse return error.SdlFailed;
                errdefer _ = c.SDL_GL_DestroyContext(context);
                if (!c.SDL_GL_MakeCurrent(window, context)) return error.SdlFailed;
                _ = c.SDL_GL_SetSwapInterval(1);
                return .{ .window = window, .gl_context = context };
            },
        }
    }

    /// Closes the window and shuts SDL down.
    pub fn deinit(self: *Window) void {
        c.SDL_free(self.clipboard_text);
        for (self.cursors.values) |cur| if (cur) |p| c.SDL_DestroyCursor(p);
        if (self.texture) |t| c.SDL_DestroyTexture(t);
        if (self.renderer) |r| c.SDL_DestroyRenderer(r);
        if (self.gl_context) |ctx| _ = c.SDL_GL_DestroyContext(ctx);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    /// Shows `cursor` while the pointer is over the window. Cheap to call
    /// every frame with `ui.cursor`.
    pub fn setCursor(self: *Window, cursor: zui.Cursor) void {
        if (cursor == self.cursor) return;
        const id: c_int = switch (cursor) {
            .default => 0,
            .text => 1,
            .crosshair => 3,
            .resize_nwse => 5,
            .resize_nesw => 6,
            .resize_ew => 7,
            .resize_ns => 8,
            .move => 9,
            .not_allowed => 10,
            // (no hands: the link hand, the four arrows)
            .pointer, .grab => 11,
            .grabbing => 9,
        };
        const slot = self.cursors.getPtr(cursor);
        if (slot.* == null) slot.* = c.SDL_CreateSystemCursor(id);
        // A missing cursor shape keeps the current one.
        if (slot.*) |p| {
            if (c.SDL_SetCursor(p)) self.cursor = cursor;
        }
    }

    /// Returns the current size. Never returns a zero dimension.
    pub fn size(self: *const Window) Size {
        var w: c_int = 1;
        var h: c_int = 1;
        var pw: c_int = 1;
        var ph: c_int = 1;
        _ = c.SDL_GetWindowSize(self.window, &w, &h);
        _ = c.SDL_GetWindowSizeInPixels(self.window, &pw, &ph);
        const width: u32 = @intCast(@max(1, w));
        const pixel_width: u32 = @intCast(@max(1, pw));
        return .{
            .width = width,
            .height = @intCast(@max(1, h)),
            .pixel_width = pixel_width,
            .pixel_height = @intCast(@max(1, ph)),
            .scale = @as(f32, @floatFromInt(pixel_width)) / @as(f32, @floatFromInt(width)),
        };
    }

    /// Returns a clipboard hook for `Ui.clipboard`. The window must not move
    /// in memory while the hook is in use.
    pub fn clipboard(self: *Window) zui.Clipboard {
        return .{ .context = self, .getFn = getClipboard, .setFn = setClipboard };
    }

    fn getClipboard(context: *anyopaque) []const u8 {
        const self: *Window = @ptrCast(@alignCast(context));
        c.SDL_free(self.clipboard_text);
        self.clipboard_text = c.SDL_GetClipboardText();
        return if (self.clipboard_text) |t| std.mem.span(t) else "";
    }

    fn setClipboard(context: *anyopaque, text: []const u8) void {
        _ = context;
        // SDL wants a terminated string; text from the UI is not.
        const copy = c.SDL_strndup(text.ptr, text.len) orelse return;
        defer c.SDL_free(copy);
        _ = c.SDL_SetClipboardText(copy);
    }

    /// Moves pending events into `input`. With `timeout_ms` non-null and no
    /// event pending, sleeps until one arrives or the timeout expires, which
    /// lets an idle UI use no CPU. Negative waits forever. Returns true if any
    /// event was seen.
    pub fn pollEvents(self: *Window, input: *zui.Input, timeout_ms: ?i32) bool {
        var seen = false;
        var event: c.Event = undefined;
        if (timeout_ms) |ms| {
            if (c.SDL_WaitEventTimeout(&event, ms)) {
                self.handle(&event, input);
                seen = true;
            }
        }
        while (c.SDL_PollEvent(&event)) {
            self.handle(&event, input);
            seen = true;
        }
        return seen;
    }

    fn handle(self: *Window, event: *const c.Event, input: *zui.Input) void {
        switch (event.header.type) {
            c.event_quit => self.close_requested = true,
            c.event_mouse_motion => input.onMouseMove(.{ .x = event.motion.x, .y = event.motion.y }),
            c.event_mouse_button_down, c.event_mouse_button_up => {
                const button: zui.MouseButton = switch (event.button.button) {
                    1 => .left,
                    2 => .middle,
                    3 => .right,
                    else => return,
                };
                input.modifiers = modifiers(c.SDL_GetModState());
                input.onMouseMove(.{ .x = event.button.x, .y = event.button.y });
                input.onMouseButtonClicks(button, event.button.down, event.button.clicks);
            },
            c.event_drop_file => if (event.drop.data) |path| {
                input.onFileDrop(std.mem.span(path), .{ .x = event.drop.x, .y = event.drop.y });
            },
            c.event_mouse_wheel => {
                // Direction 1 is SDL_MOUSEWHEEL_FLIPPED ("natural" scrolling).
                const sign: f32 = if (event.wheel.direction == 1) -1 else 1;
                // SDL's x is positive to the right; Zui's, as the native
                // backends give it, is positive to the left (like y: up).
                input.onScroll(.{ .x = -event.wheel.x * sign, .y = event.wheel.y * sign });
            },
            c.event_key_down => {
                input.modifiers = modifiers(event.key.mod);
                if (mapKey(event.key.scancode, event.key.key)) |key| input.onKeyPress(key);
            },
            c.event_key_up => {
                input.modifiers = modifiers(event.key.mod);
                if (mapKey(event.key.scancode, event.key.key)) |key| input.onKeyRelease(key);
            },
            c.event_text_input => input.onText(std.mem.span(event.text.text)),
            else => {},
        }
    }

    /// Shows what was drawn with OpenGL. For `.opengl` windows.
    pub fn swap(self: *Window) Error!void {
        if (!c.SDL_GL_SwapWindow(self.window)) return error.SdlFailed;
    }

    /// Shows a frame. `pixels` holds `width * height` values, `0xAARRGGBB`.
    /// For `.software` windows.
    pub fn present(self: *Window, pixels: []const u32, width: u32, height: u32) Error!void {
        const renderer = self.renderer orelse return error.SdlFailed; // an .opengl window
        if (self.texture == null or width != self.texture_width or height != self.texture_height) {
            if (self.texture) |t| c.SDL_DestroyTexture(t);
            self.texture = c.SDL_CreateTexture(
                renderer,
                c.pixelformat_argb8888,
                c.textureaccess_streaming,
                @intCast(width),
                @intCast(height),
            ) orelse return error.SdlFailed;
            self.texture_width = width;
            self.texture_height = height;
        }
        const texture = self.texture.?;
        if (!c.SDL_UpdateTexture(texture, null, pixels.ptr, @intCast(width * 4))) return error.SdlFailed;
        if (!c.SDL_RenderTexture(renderer, texture, null, null)) return error.SdlFailed;
        if (!c.SDL_RenderPresent(renderer)) return error.SdlFailed;
    }
};

fn modifiers(mod: u16) zui.Modifiers {
    return .{
        .shift = mod & c.kmod_shift != 0,
        .ctrl = mod & c.kmod_ctrl != 0,
        .alt = mod & c.kmod_alt != 0,
        .super = mod & c.kmod_gui != 0,
    };
}

/// Navigation keys use the physical scancode. Letters use the layout's keycode,
/// so that Ctrl+C means "the key labelled C" on non-QWERTY layouts.
fn mapKey(scancode: u32, keycode: u32) ?zui.Key {
    switch (keycode) {
        'a'...'z' => return @enumFromInt(@intFromEnum(zui.Key.a) + (keycode - 'a')),
        '0'...'9' => return @enumFromInt(@intFromEnum(zui.Key.@"0") + (keycode - '0')),
        '-' => return .minus,
        '=' => return .equal,
        ',' => return .comma,
        '.' => return .period,
        '/' => return .slash,
        else => {},
    }
    // F1 to F12 have consecutive scancodes.
    if (scancode >= 58 and scancode <= 69) return @enumFromInt(@intFromEnum(zui.Key.f1) + (scancode - 58));
    if (scancode == 73) return .insert;
    return switch (scancode) {
        40, 88 => .enter, // return, keypad enter
        41 => .escape,
        42 => .backspace,
        43 => .tab,
        44 => .space,
        74 => .home,
        75 => .page_up,
        76 => .delete,
        77 => .end,
        78 => .page_down,
        79 => .right,
        80 => .left,
        81 => .down,
        82 => .up,
        else => null,
    };
}
