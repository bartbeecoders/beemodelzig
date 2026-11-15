//! Hot reload host: owns the window, the renderer and the app's state, and
//! loads the UI code from a shared library that can be rebuilt while it runs.
//!
//!     ./run.sh 12_hot_reload          # terminal 1
//!     zig build hot-app               # terminal 2, after editing app.zig
//!
//! On a reload the host saves the `Ui` state, drops the `Ui` and the old
//! library, loads the new library, and restores the state into a fresh `Ui`.
//! The app's UI code reloads; a change to Zui itself or to state.zig needs a
//! restart, because the host is compiled against them too.

const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");
const sdl3 = @import("zui_sdl3");
const app = @import("state.zig");
const builtin = @import("builtin");

/// `std.DynLib` has no Windows support in Zig 0.17, so Windows gets its own.
const NativeLib = if (builtin.os.tag == .windows) WindowsLib else std.DynLib;

/// Loads a DLL with kernel32, with the same calls `std.DynLib` offers.
const WindowsLib = struct {
    handle: *anyopaque,

    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) c_int;

    fn open(path: []const u8) !WindowsLib {
        var buffer: [1024:0]u8 = undefined;
        if (path.len >= buffer.len) return error.NameTooLong;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;
        return .{ .handle = LoadLibraryA(&buffer) orelse return error.FileNotFound };
    }

    fn lookup(self: *WindowsLib, comptime T: type, name: [:0]const u8) ?T {
        const ptr = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn close(self: *WindowsLib) void {
        _ = FreeLibrary(self.handle);
    }
};

/// A loaded copy of the app library. The build overwrites the library in
/// place, which must not happen to a file that is mapped, so each load works
/// on a private copy.
const Library = struct {
    lib: NativeLib,
    frame: app.FrameFn,
    copy_path: []u8,
    mtime: i96,

    fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8, generation: u32) !Library {
        const cwd = std.Io.Dir.cwd();
        const stat = try cwd.statFile(io, path, .{});
        const copy_path = try std.fmt.allocPrint(gpa, "{s}.{d}", .{ path, generation });
        errdefer gpa.free(copy_path);
        try std.Io.Dir.copyFile(cwd, path, cwd, copy_path, io, .{});
        var lib = try NativeLib.open(copy_path);
        errdefer lib.close();
        const frame = lib.lookup(app.FrameFn, app.frame_symbol) orelse return error.SymbolMissing;
        return .{ .lib = lib, .frame = frame, .copy_path = copy_path, .mtime = stat.mtime.nanoseconds };
    }

    fn unload(self: *Library, io: std.Io, gpa: std.mem.Allocator) void {
        self.lib.close();
        std.Io.Dir.cwd().deleteFile(io, self.copy_path) catch {};
        gpa.free(self.copy_path);
    }

    /// True if the library on disk is newer than this copy.
    fn changed(self: *const Library, io: std.Io, path: []const u8) bool {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
        return stat.mtime.nanoseconds != self.mtime;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("usage: host <path to the app library>", .{});
        return error.InvalidArguments;
    }
    const lib_path = args[1];

    var font: zui.Font = try .initDefault(gpa);
    defer font.deinit();
    var window = sdl3.Window.init(.{ .title = "Zui 12: hot reload", .width = 760, .height = 460 }) catch |err| {
        std.log.err("could not open a window: {s}", .{sdl3.lastError()});
        return err;
    };
    defer window.deinit();
    var renderer: software.SoftwareRenderer = .init(gpa);
    defer renderer.deinit();

    var state: app.State = .{};
    var generation: u32 = 0;
    var library = try Library.load(io, gpa, lib_path, generation);
    defer library.unload(io, gpa);
    var ui: zui.Ui = .init(gpa, .{ .font = &font });
    defer ui.deinit();
    ui.clipboard = window.clipboard();

    var previous = sdl3.ticksNs();
    var frames_left: u32 = 2;
    while (!window.close_requested) {
        const idle = frames_left == 0 and !ui.redraw_requested;
        const timeout: ?i32 = if (idle) waitMs(ui.redraw_in) else null;
        if (window.pollEvents(&ui.input, timeout)) frames_left = 2;
        if (frames_left > 0) frames_left -= 1;

        if (library.changed(io, lib_path)) {
            // The build may still be writing; try again next time if the
            // new library can't be loaded yet.
            if (Library.load(io, gpa, lib_path, generation + 1)) |next| {
                const saved = try ui.saveState(gpa);
                defer gpa.free(saved);
                ui.deinit();
                library.unload(io, gpa);
                library = next;
                generation += 1;
                ui = .init(gpa, .{ .font = &font });
                ui.clipboard = window.clipboard();
                try ui.restoreState(saved);
                state.reloads += 1;
                frames_left = 2;
                std.log.info("reloaded {s} ({d} bytes of UI state carried over)", .{ lib_path, saved.len });
            } else |err| {
                std.log.warn("new library not ready yet: {s}", .{@errorName(err)});
            }
        }

        const now = sdl3.ticksNs();
        const dt: f32 = @as(f32, @floatFromInt(now - previous)) / 1e9;
        previous = now;
        const size = window.size();
        const width: f32 = @floatFromInt(size.width);
        const height: f32 = @floatFromInt(size.height);

        ui.beginFrame(.{ .width = width, .height = height, .dt = dt });
        library.frame(&ui, &state);
        // Look for a rebuilt library twice a second, even when idle.
        ui.requestRedrawIn(0.5);
        const list = try ui.endFrame();

        try renderer.resize(size.pixel_width, size.pixel_height);
        renderer.clear_color = ui.style.colors.background;
        renderer.renderer().render(list, .{ .width = width, .height = height, .scale = size.scale });
        try window.present(renderer.pixels, renderer.width, renderer.height);
    }
}

fn waitMs(seconds: ?f32) i32 {
    const s = seconds orelse return -1;
    return @intFromFloat(@min(@ceil(s * 1000), 1_000_000));
}
