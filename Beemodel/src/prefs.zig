// Preferences, as in the original: one "word value" line each, read at
// start-up and written on every change. The Zig port keeps its own file,
// ~/.config/beemodel-zig/prefs, so the assembly app's is never touched.
const std = @import("std");
const linux = std.os.linux;
const theme = @import("theme.zig");
const vp = @import("viewport.zig");
const ui = @import("ui.zig");
const scene = @import("scene.zig");

pub var tooltip_ms: i32 = 500;
pub var colorblind_axes: bool = false;
pub var reduce_motion: bool = false;
pub var show_frame_rate: bool = true;
pub var emulate_middle: bool = false;
pub var orbit_speed: f32 = 1.0;
pub var wheel_menu: bool = true;
pub var grid: bool = true;
pub var fov: f32 = 50;
pub var clip_start: f32 = 0.05;
/// Rendered shading: samples when the view is still (0: Material Preview alone), denoise.
pub var rendered_samples: i32 = 64;
pub var rendered_denoise: bool = true;
/// Path-traced samples a frame while the view moves (0: the raycast), while the animation plays.
pub var rendered_motion: i32 = 0;
pub var rendered_playback: i32 = 4;
/// Render > Device: 0 auto, 1 RTX, 2 GPU, 3 CPU.
pub var render_device: i32 = 0;
pub var welcome: bool = true;
/// Changes between autosaves (0: never), as the original's pr_autosave.
pub var autosave: i32 = 25;
/// The last scenes opened or saved (newest first).
pub var recent_files: [8][512]u8 = undefined;
pub var recent_files_len: [8]usize = @splat(0);

pub fn pushRecentFile(p: []const u8) void {
    if (p.len == 0 or p.len > 511) return;
    var i: usize = 0;
    while (i < recent_files.len and !(recent_files_len[i] == p.len and std.mem.eql(u8, recent_files[i][0..p.len], p))) i += 1;
    if (i == recent_files.len) i = recent_files.len - 1;
    while (i > 0) : (i -= 1) {
        recent_files[i] = recent_files[i - 1];
        recent_files_len[i] = recent_files_len[i - 1];
    }
    @memcpy(recent_files[0][0..p.len], p);
    recent_files_len[0] = p.len;
    save();
}

pub fn recentCount() usize {
    var n: usize = 0;
    while (n < recent_files.len and recent_files_len[n] > 0) n += 1;
    return n;
}

/// The last colours picked (newest first), 0xrrggbb + 1 (0: none).
pub var recent: [10]u32 = @splat(0);

var path_buf: [256]u8 = undefined;
var path_len: usize = 0;
var dir_len: usize = 0;

pub fn init(home: ?[]const u8) void {
    defer scene.show_grid = grid;
    const h = home orelse return;
    const dir = std.fmt.bufPrint(&path_buf, "{s}/.config/beemodel-zig", .{h}) catch return;
    dir_len = dir.len;
    const full = std.fmt.bufPrint(&path_buf, "{s}/.config/beemodel-zig/prefs", .{h}) catch return;
    path_len = full.len;
    load();
    apply();
}

/// Push the values into the parts of the app that use them.
pub fn apply() void {
    ui.tip_delay = tooltip_ms;
    vp.fov = fov;
    vp.near = clip_start;
    theme.setColorblind(colorblind_axes);
}

fn zpath(buf: []u8, len: usize) ?[*:0]const u8 {
    if (len == 0 or len >= buf.len) return null;
    buf[len] = 0;
    return @ptrCast(buf.ptr);
}

fn load() void {
    var pb: [257]u8 = undefined;
    @memcpy(pb[0..path_len], path_buf[0..path_len]);
    const p = zpath(&pb, path_len) orelse return;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var data: [32768]u8 = undefined;
    var n: usize = 0;
    while (n < data.len) {
        const r = linux.read(fd, data[n..].ptr, data.len - n);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    var lines = std.mem.tokenizeScalar(u8, data[0..n], '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const k = it.next() orelse continue;
        const v = std.mem.trim(u8, it.rest(), " \r");
        set(k, v);
    }
}

fn int(v: []const u8, d: i32) i32 {
    return std.fmt.parseInt(i32, v, 10) catch d;
}
fn flt(v: []const u8, d: f32) f32 {
    return std.fmt.parseFloat(f32, v) catch d;
}

fn set(k: []const u8, v: []const u8) void {
    const eq = std.mem.eql;
    if (eq(u8, k, "theme")) {
        if (theme.byId(v)) |t| theme.set(t);
    } else if (eq(u8, k, "accent")) {
        if (eq(u8, v, "theme")) theme.setAccent(null) else theme.setAccent(std.fmt.parseInt(u32, v, 16) catch null);
    } else if (eq(u8, k, "tooltip_ms")) {
        tooltip_ms = std.math.clamp(int(v, 500), 0, 5000);
    } else if (eq(u8, k, "colorblind_axes")) {
        colorblind_axes = int(v, 0) != 0;
    } else if (eq(u8, k, "reduce_motion")) {
        reduce_motion = int(v, 0) != 0;
    } else if (eq(u8, k, "show_frame_rate")) {
        show_frame_rate = int(v, 1) != 0;
    } else if (eq(u8, k, "emulate_middle")) {
        emulate_middle = int(v, 0) != 0;
    } else if (eq(u8, k, "orbit_speed")) {
        orbit_speed = std.math.clamp(flt(v, 1), 0.1, 5);
    } else if (eq(u8, k, "wheel_menu")) {
        wheel_menu = int(v, 1) != 0;
    } else if (eq(u8, k, "grid")) {
        grid = int(v, 1) != 0;
    } else if (eq(u8, k, "fov")) {
        fov = std.math.clamp(flt(v, 50), 5, 140);
    } else if (eq(u8, k, "rendered_samples")) {
        rendered_samples = std.math.clamp(int(v, 64), 0, 4096);
    } else if (eq(u8, k, "rendered_denoise")) {
        rendered_denoise = int(v, 1) != 0;
    } else if (eq(u8, k, "rendered_motion")) {
        rendered_motion = std.math.clamp(int(v, 0), 0, 4);
    } else if (eq(u8, k, "rendered_playback")) {
        rendered_playback = std.math.clamp(int(v, 4), 0, 64);
    } else if (eq(u8, k, "render_device")) {
        render_device = std.math.clamp(int(v, 0), 0, 3);
    } else if (eq(u8, k, "clip_start")) {
        clip_start = std.math.clamp(flt(v, 0.05), 0.001, 10);
    } else if (eq(u8, k, "welcome")) {
        welcome = int(v, 1) != 0;
    } else if (eq(u8, k, "autosave")) {
        autosave = std.math.clamp(int(v, 25), 0, 10000);
    } else if (eq(u8, k, "recent_file")) {
        const n = recentCount();
        if (n < recent_files.len and v.len > 0 and v.len < 512) {
            @memcpy(recent_files[n][0..v.len], v);
            recent_files_len[n] = v.len;
        }
    } else if (@import("prefpages.zig").loadLine(k, v)) {
        // (the UI scale, the keys, the pages' values)
    } else if (eq(u8, k, "recent_colours")) {
        var it = std.mem.tokenizeScalar(u8, v, ' ');
        var i: usize = 0;
        while (it.next()) |c| : (i += 1) {
            if (i >= recent.len) break;
            recent[i] = (std.fmt.parseInt(u32, c, 16) catch continue) + 1;
        }
    }
}

var pending = false;

/// Mark the preferences changed; they are written when the change ends
/// (not on every step of a drag).
pub fn save() void {
    pending = true;
}

/// Write them if they changed (after each input event).
pub fn flush() void {
    if (!pending) return;
    pending = false;
    write();
}

fn write() void {
    if (path_len == 0) return;
    grid = scene.show_grid;
    var db: [257]u8 = undefined;
    @memcpy(db[0..dir_len], path_buf[0..dir_len]);
    if (zpath(&db, dir_len)) |d| _ = linux.mkdir(d, 0o755);
    var out: [32768]u8 = undefined;
    var w: usize = 0;
    const put = struct {
        fn f(o: []u8, at: *usize, comptime fmt: []const u8, args: anytype) void {
            const s = std.fmt.bufPrint(o[at.*..], fmt, args) catch return;
            at.* += s.len;
        }
    }.f;
    put(&out, &w, "theme {s}\n", .{theme.base.id});
    if (theme.accent) |a| put(&out, &w, "accent {x:0>6}\n", .{a}) else put(&out, &w, "accent theme\n", .{});
    put(&out, &w, "tooltip_ms {d}\ncolorblind_axes {d}\nreduce_motion {d}\nshow_frame_rate {d}\n", .{ tooltip_ms, @intFromBool(colorblind_axes), @intFromBool(reduce_motion), @intFromBool(show_frame_rate) });
    put(&out, &w, "emulate_middle {d}\norbit_speed {d:.2}\nwheel_menu {d}\ngrid {d}\nfov {d:.1}\nclip_start {d:.3}\nwelcome {d}\n", .{ @intFromBool(emulate_middle), orbit_speed, @intFromBool(wheel_menu), @intFromBool(grid), fov, clip_start, @intFromBool(welcome) });
    put(&out, &w, "rendered_samples {d}\nrendered_denoise {d}\nautosave {d}\n", .{ rendered_samples, @intFromBool(rendered_denoise), autosave });
    put(&out, &w, "rendered_motion {d}\nrendered_playback {d}\nrender_device {d}\n", .{ rendered_motion, rendered_playback, render_device });
    @import("prefpages.zig").write(&out, &w);
    put(&out, &w, "recent_colours", .{});
    for (recent) |c| {
        if (c != 0) put(&out, &w, " {x:0>6}", .{c - 1});
    }
    put(&out, &w, "\n", .{});
    for (0..recentCount()) |k| put(&out, &w, "recent_file {s}\n", .{recent_files[k][0..recent_files_len[k]]});
    // a temporary file, then renamed over the old one
    @import("bee.zig").writeAtomic(path_buf[0..path_len], out[0..w]) catch {};
}

/// A colour was picked: first of the recent ones (once).
pub fn pushRecent(c: u32) void {
    var i: usize = 0;
    while (i < recent.len and recent[i] != c + 1) i += 1;
    if (i == recent.len) i = recent.len - 1;
    while (i > 0) : (i -= 1) recent[i] = recent[i - 1];
    recent[0] = c + 1;
    save();
}

pub fn resetCategory(cat: usize) void {
    switch (cat) {
        0 => {
            theme.set(theme.dark);
            theme.setAccent(null);
            tooltip_ms = 500;
            colorblind_axes = false;
            reduce_motion = false;
            show_frame_rate = true;
        },
        1 => {
            grid = true;
            scene.show_grid = true;
            fov = 50;
            clip_start = 0.05;
            rendered_samples = 64;
            rendered_denoise = true;
            rendered_motion = 0;
            rendered_playback = 4;
        },
        2 => {
            emulate_middle = false;
            orbit_speed = 1;
            wheel_menu = true;
        },
        else => @import("prefpages.zig").reset(cat),
    }
    apply();
    save();
}
