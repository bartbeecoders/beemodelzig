// The values of the Preferences' own pages (prefs.s): Rendering (new scenes'
// render size, samples, denoise), System (threads) and the UI scale. The pages
// themselves are drawn by Zui (zuiprefs.zig).
const std = @import("std");
const app = @import("app.zig");
const prefs = @import("prefs.zig");
const keys = @import("keys.zig");

// --- values kept in the preferences -------------------------------------------------

pub var render_w: i32 = 960;
pub var render_h: i32 = 540;
pub var render_spp: i32 = 128;
pub var render_dn: bool = true;
/// Worker threads at start-up (0: one a CPU).
pub var threads: i32 = 0;

pub fn loadLine(k: []const u8, v: []const u8) bool {
    const eq = std.mem.eql;
    const int = std.fmt.parseInt(i32, v, 10) catch 0;
    if (eq(u8, k, "scale")) {
        const sc = @import("scale.zig");
        sc.pref = @intCast(std.math.clamp(int, 75, 200));
    } else if (eq(u8, k, "render_width")) {
        render_w = std.math.clamp(int, 16, 8192);
    } else if (eq(u8, k, "render_height")) {
        render_h = std.math.clamp(int, 16, 8192);
    } else if (eq(u8, k, "render_samples")) {
        render_spp = std.math.clamp(int, 1, 65536);
    } else if (eq(u8, k, "render_denoise")) {
        render_dn = int != 0;
    } else if (eq(u8, k, "threads")) {
        threads = std.math.clamp(int, 0, 255);
    } else if (@import("agent.zig").loadPref(k, v)) {
        return true;
    } else if (@import("ai.zig").loadPref(k, v)) {
        return true;
    } else return keys.loadLine(k, v);
    return true;
}

pub fn write(out: []u8, w: *usize) void {
    const sc = @import("scale.zig");
    const s = std.fmt.bufPrint(out[w.*..], "scale {d}\nrender_width {d}\nrender_height {d}\nrender_samples {d}\nrender_denoise {d}\nthreads {d}\n", .{ sc.pref, render_w, render_h, render_spp, @intFromBool(render_dn), threads }) catch return;
    w.* += s.len;
    @import("ai.zig").writePrefs(out, w);
    keys.write(out, w);
}

pub fn reset(c: usize) void {
    switch (c) {
        3 => keys.resetAll(),
        4 => {
            render_w = 960;
            render_h = 540;
            render_spp = 128;
            render_dn = true;
        },
        5 => threads = 0,
        6 => prefs.autosave = 25,
        7 => {
            @import("agent.zig").pr_tier = -1;
            @import("agent.zig").pr_mcp = 1;
            @import("ai.zig").resetPrefs();
        },
        else => {},
    }
}

// --- UI scale ----------------------------------------------------------------------

pub const scales = [_]u32{ 75, 100, 125, 150, 175, 200 };

/// view.ui_scale, and the list: everything bigger or smaller at once.
pub fn setScale(p: u32) void {
    const sc = @import("scale.zig");
    sc.pref = std.math.clamp(p, 75, 200);
    prefs.save();
    if (app.win) |w| w.push(.resize);
    app.dirty = true;
}
