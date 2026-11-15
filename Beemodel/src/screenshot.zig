// view.screenshot (Shift+F12), as the original's op_shot: the window as it was
// last shown, as a PNG: view.screenshot [path], by default
// ~/BeeModel/screenshot.png. The picture is taken at once; packing it is a job.
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const ui = @import("ui.zig");
const files = @import("files.zig");
const fb = @import("filebrowser.zig");
const A = std.heap.page_allocator;

var copy: []u32 = &.{};
var cw: u32 = 0;
var ch: u32 = 0;

pub fn run(arg: []const u8) void {
    var pb: [600]u8 = undefined;
    const a = std.mem.trim(u8, arg, " \"");
    const path = if (a.len > 0) a else blk: {
        const dir = std.fmt.bufPrintSentinel(&pb, "{s}/BeeModel", .{fb.homeDir()}, 0) catch return;
        _ = linux.mkdir(dir, 0o755);
        break :blk std.fmt.bufPrint(&pb, "{s}/BeeModel/screenshot.png", .{fb.homeDir()}) catch return;
    };
    const cv = ui.cv;
    const n: usize = @intCast(cv.w * cv.h);
    if (n == 0) return;
    if (copy.len != n) {
        if (copy.len > 0) A.free(copy);
        copy = A.alloc(u32, n) catch {
            copy = &.{};
            return app.toast(.warn, "Screenshot: there is not enough memory", .{});
        };
    }
    @memcpy(copy, cv.px[0..n]);
    cw = @intCast(cv.w);
    ch = @intCast(cv.h);
    @import("jobui.zig").later(job, "Saving a screenshot", path, 0, 0);
}

fn job(p0: []const u8, _: usize, _: usize) void {
    var eb: [600]u8 = undefined;
    const p = files.expandHome(&eb, p0) orelse p0;
    if (!files.mayWrite(p)) return app.toast(.warn, "Headless: not writing outside /tmp ({s})", .{p});
    const data = @import("png.zig").encode(A, cw, ch, copy) catch return app.toast(.warn, "Screenshot: there is not enough memory", .{});
    defer A.free(data);
    @import("bee.zig").writeAtomic(p, data) catch return app.toast(.warn, "Screenshot: {s} cannot be written", .{p});
    app.toast(.ok, "Screenshot {s}", .{p});
}
