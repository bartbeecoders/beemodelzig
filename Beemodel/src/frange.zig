// The scene's frame range and speed (anim.s AN_START, AN_END, AN_FPS,
// anim.range). In files it travels in the ANIM chunk (anim.zig).
const std = @import("std");
const app = @import("app.zig");

pub const Range = extern struct { start: i32 = 1, end: i32 = 250, fps: f32 = 24 };
pub var r: Range = .{};

pub fn reset() void {
    r = .{};
}

/// Worth a chunk? (the original writes none until something asked for one)
pub fn isDefault() bool {
    return r.start == 1 and r.end == 250 and r.fps == 24;
}

const usage = "  anim.range <start> <end> [fps]";

/// anim.range <start> <end> [fps]
pub fn opRange() void {
    var it = std.mem.tokenizeAny(u8, @import("ops.zig").arg, " \"");
    const ex = @import("expr.zig");
    const a = ex.eval(it.next() orelse return app.log(usage, .{})) orelse return app.log(usage, .{});
    const b = ex.eval(it.next() orelse return app.log(usage, .{})) orelse return app.log(usage, .{});
    if (!std.math.isFinite(a) or !std.math.isFinite(b) or @abs(a) > 1e7 or @abs(b) > 1e7) return app.log(usage, .{});
    const s: i32 = @intFromFloat(a);
    const e: i32 = @intFromFloat(b);
    if (e < s) return app.log(usage, .{});
    // (an_own: the original makes the animation block here, and it stays -
    // fields.zig's time is frame / fps once there is one)
    _ = @import("anim.zig").own(0) orelse return;
    r.start = s;
    r.end = e;
    if (it.next()) |t| {
        if (ex.eval(t)) |f| {
            if (std.math.isFinite(f) and f > 0) r.fps = f;
        }
    }
    @import("undo.zig").label("Frame Range");
    app.dirty = true;
}
