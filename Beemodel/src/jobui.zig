// Long jobs in the status bar (jobui.s). A job runs on the UI thread, so it
// would freeze the window: begin / end bracket one, and while it runs set()
// presents a frame at most every 100 ms, with a chip showing its name and how
// far it is. A job asked for from a key or a click runs from the main loop
// (later), never inside the UI pass: its frames would run the UI inside itself.
// Input waits until it ends.
const std = @import("std");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");

/// Draw and show a frame now (main.zig; null headless: jobs run in place).
pub var present_fn: ?*const fn () void = null;

pub var on = false;
var label: []const u8 = "";
var frac: f32 = -1; // 0 .. 1, below 0: unknown
var t0: i64 = 0;
var last: i64 = 0;
var depth: u32 = 0;

pub const Fn = *const fn (path: []const u8, a: usize, b: usize) void;
const Job = struct { f: Fn, label: []const u8, path: [1024]u8, len: usize, a: usize, b: usize };
var queue: [8]Job = undefined;
var q_head: usize = 0;
var q_n: usize = 0;

fn wallMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn show() void {
    if (present_fn) |f| {
        last = wallMs();
        f();
    }
}

/// Esc while a job runs (the one key one listens to, main.zig): a job that can
/// stop looks at this between its steps.
pub var stop = false;

/// A job between its steps, where it looks at stop: whatever the time, so that a
/// quick step does not run past an Esc already on its way.
pub fn between() void {
    if (on) show();
}

/// A frame now and then while a job waits for something else.
pub fn pump() void {
    if (on and wallMs() - last >= 100) show();
}

/// Jobs inside a job count as it (an export saving ...).
pub fn begin(name: []const u8) void {
    depth += 1;
    if (depth > 1) return;
    on = true;
    stop = false;
    label = name;
    frac = -1;
    t0 = wallMs();
    show();
}

pub fn end() void {
    if (depth == 0) return;
    depth -= 1;
    if (depth > 0) return;
    on = false;
    app.dirty = true;
}

/// How far it is: 0 .. 1. A frame when the last is 100 ms old.
pub fn set(f: f32) void {
    if (!on) return;
    frac = f;
    if (wallMs() - last >= 100) show();
}

/// Run f as a job from the main loop; headless, at once; inside a script
/// at once too (the run is one undo step, and its next lines see the result).
pub fn later(f: Fn, name: []const u8, path: []const u8, a: usize, b: usize) void {
    if (present_fn == null or path.len > queue[0].path.len or @import("bscript.zig").isRunning()) {
        f(path, a, b);
        return;
    }
    if (q_n == queue.len) {
        app.toast(.warn, "{s}: too many jobs are waiting, nothing done", .{name});
        return;
    }
    const j = &queue[(q_head + q_n) % queue.len];
    j.* = .{ .f = f, .label = name, .path = undefined, .len = path.len, .a = a, .b = b };
    @memcpy(j.path[0..path.len], path);
    q_n += 1;
    app.dirty = true;
}

/// A job waits for the main loop: a later() now would be dropped.
pub fn queued() bool {
    return q_n > 0;
}

/// The main loop's turn: true when a job ran.
pub fn runPending() bool {
    if (q_n == 0) return false;
    const j = &queue[q_head];
    q_head = (q_head + 1) % queue.len;
    q_n -= 1;
    begin(j.label);
    j.f(j.path[0..j.len], j.a, j.b);
    end();
    return true;
}

pub const Progress = struct { label: []const u8, frac: f32, ms: i64 };

/// "Rendering the image 48%, 4 s, about 4 s left" (seconds after the first; how
/// long is left once a twentieth is done and two seconds have passed).
pub fn text(buf: []u8, p: Progress) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}", .{p.label}) catch {};
    if (p.frac >= 0) w.print(" {d}%", .{@as(u32, @intFromFloat(std.math.clamp(p.frac, 0, 1) * 100))}) catch {};
    if (p.ms >= 1000) {
        w.print(", {d} s", .{@divTrunc(p.ms + 999, 1000)}) catch {};
        if (p.frac >= 0.05 and p.ms >= 2000) {
            const left = @as(f32, @floatFromInt(p.ms)) * (1 - p.frac) / p.frac;
            w.print(", about {d} s left", .{@as(u32, @intFromFloat(left / 1000 + 0.999))}) catch {};
        }
    }
    return w.buffered();
}

/// The job at work (or a render, a geometry evaluation), if any.
pub fn progress() ?Progress {
    const rn = @import("render.zig");
    if (on) return .{ .label = label, .frac = frac, .ms = wallMs() - t0 };
    if (rn.active) return rn.progress();
    if (@import("vgeo.zig").progress()) |g| return .{ .label = g.label, .frac = g.frac, .ms = g.ms };
    return null;
}

test "the chip's words" {
    var b: [80]u8 = undefined;
    try std.testing.expectEqualStrings("Saving", text(&b, .{ .label = "Saving", .frac = -1, .ms = 200 }));
    try std.testing.expectEqualStrings("Saving, 3 s", text(&b, .{ .label = "Saving", .frac = -1, .ms = 2500 }));
    try std.testing.expectEqualStrings("Rendering the image 48%, 4 s, about 5 s left", text(&b, .{ .label = "Rendering the image", .frac = 0.48, .ms = 4000 }));
    try std.testing.expectEqualStrings("Baking 3%, 3 s", text(&b, .{ .label = "Baking", .frac = 0.03, .ms = 3000 }));
}
