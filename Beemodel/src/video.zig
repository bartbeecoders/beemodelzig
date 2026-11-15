// An animation rendered into a video (render.animation <file>; video.s and the
// frame loop of hive_render_frames, render.s do_render_anim). By the file's
// extension:
//   .mp4 .mov .mkv  H.264 through ffmpeg   .webm  VP9 through ffmpeg
//   .gif            a GIF with its own palette, through ffmpeg
//   .apng           an animated PNG, written here (apng.zig), no ffmpeg needed
//   .png            a folder of frames named like the file (shot.png:
//                   shot/0001.png ...); anything else is a folder.
// ffmpeg (on PATH, or $BEEMODEL_FFMPEG) gets the frames raw on its stdin (a
// socket: a dead ffmpeg is an error, not a SIGPIPE) and encodes one while the
// next renders; what it says goes to ~/.cache/beemodel/ffmpeg.log, and its
// first line into the console when it fails.
const std = @import("std");
const linux = std.os.linux;
const app = @import("app.zig");
const pt = @import("pt.zig");
const render = @import("render.zig");
const jobui = @import("jobui.zig");
const files = @import("files.zig");
const spawn = @import("spawn.zig");
const apng = @import("apng.zig");
const frange = @import("frange.zig");
const editors = @import("editors.zig");
const denoise = @import("denoise.zig");
const ops = @import("ops.zig");
const A = std.heap.page_allocator;

pub const Kind = enum { folder, mkv, mp4, webm, gif, apng, pngs };

/// What a path asks for, by its extension in any case (vid_open).
pub fn kindOf(path: []const u8) Kind {
    const base = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return .folder;
    const e = base[dot + 1 ..];
    const T = struct { []const u8, Kind };
    for ([_]T{ .{ "mp4", .mp4 }, .{ "mov", .mp4 }, .{ "mkv", .mkv }, .{ "webm", .webm }, .{ "gif", .gif }, .{ "apng", .apng }, .{ "png", .pngs } }) |t| {
        if (std.ascii.eqlIgnoreCase(e, t[0])) return t[1];
    }
    return .folder;
}

/// ffmpeg's argument list after the head and -i -. Fits MAX_ARGS.
fn codecArgs(k: Kind) []const [*:0]const u8 {
    const even = "crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0";
    return switch (k) {
        .mkv => &.{ "-vf", even, "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p" },
        .mp4 => &.{ "-vf", even, "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart" },
        .webm => &.{ "-vf", even, "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuv420p" },
        .gif => &.{ "-vf", "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse", "-loop", "0" },
        else => &.{},
    };
}

const MAX_ARGS = 48;

const Out = struct {
    kind: Kind = .folder,
    path: [1040:0]u8 = undefined,
    path_len: usize = 0,
    log: [600:0]u8 = undefined,
    // ffmpeg
    fd: i32 = -1,
    pid: i32 = 0,
    gone: bool = false,
    n: u32 = 0,
    ap: apng.Writer = .{},

    fn pathS(o: *const Out) []const u8 {
        return o.path[0..o.path_len];
    }
};
var out: Out = .{};

fn setPath(p: []const u8) void {
    const n = @min(p.len, out.path.len - 1);
    @memcpy(out.path[0..n], p[0..n]);
    out.path[n] = 0;
    out.path_len = n;
}

/// The folder a file goes in, made: false when it cannot be.
fn makeParent(path: []const u8) bool {
    const s = std.mem.lastIndexOfScalar(u8, path, '/') orelse return true;
    if (s == 0) return true;
    return spawn.ensureDir(path[0..s]);
}

const Opened = enum { video, folder, failed };

/// Set the output up. A folder: `folder` holds its path (for .png, the name
/// without it).
fn open(path: []const u8, w: u32, h: u32, total: u32, fps: f32, folder: *[]const u8) Opened {
    const k = kindOf(path);
    out.kind = k;
    out.n = 0;
    out.gone = false;
    if (k == .folder or k == .pngs) {
        var t = path;
        if (k == .pngs) t = path[0..std.mem.lastIndexOfScalar(u8, path, '.').?];
        while (t.len > 1 and t[t.len - 1] == '/') t = t[0 .. t.len - 1];
        folder.* = t;
        return if (t.len == 0) .failed else .folder;
    }
    if (path.len >= out.path.len or std.mem.indexOfScalar(u8, path, 0) != null) {
        out.kind = .folder;
        app.log("  render.animation: could not write the file", .{});
        return .failed;
    }
    setPath(path);
    if (k == .apng) {
        if (!makeParent(path) or !out.ap.open(&out.path, total, fps)) {
            out.kind = .folder;
            app.log("  render.animation: could not write the file", .{});
            return .failed;
        }
        return .video;
    }
    return openFfmpeg(w, h, fps);
}

fn openFfmpeg(w: u32, h: u32, fps: f32) Opened {
    const fail = struct {
        fn nofile() Opened {
            out.kind = .folder;
            app.log("  render.animation: could not write the file", .{});
            return .failed;
        }
    };
    var exe_b: [512]u8 = undefined;
    const want = blk: {
        const e = spawn.getenv("BEEMODEL_FFMPEG") orelse "ffmpeg";
        break :blk if (e.len == 0) "ffmpeg" else e;
    };
    const exe = spawn.which(&exe_b, want) orelse {
        out.kind = .folder;
        app.log("  render.animation: ffmpeg was not found (install it, or point BEEMODEL_FFMPEG at it); .apng and .png (a folder of frames) work without it", .{});
        return .failed;
    };
    if (!makeParent(out.pathS())) return fail.nofile();
    // its log
    const home = @import("filebrowser.zig").homeDir();
    var dir_b: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_b, "{s}/.cache/beemodel", .{home}) catch return fail.nofile();
    if (!spawn.ensureDir(dir)) return fail.nofile();
    const lg = std.fmt.bufPrintSentinel(&out.log, "{s}/ffmpeg.log", .{dir}, 0) catch return fail.nofile();
    var size_b: [32]u8 = undefined;
    const size = std.fmt.bufPrintSentinel(&size_b, "{d}x{d}", .{ w, h }, 0) catch return fail.nofile();
    var rate_b: [32]u8 = undefined;
    var n1000: i64 = 1000;
    const scaled = fps * 1000 + 0.5;
    if (std.math.isFinite(scaled) and scaled >= 1 and scaled < 2e9) n1000 = @intFromFloat(scaled);
    const rate = std.fmt.bufPrintSentinel(&rate_b, "{d}/1000", .{n1000}, 0) catch return fail.nofile();
    var argv: [MAX_ARGS:null]?[*:0]const u8 = @splat(null);
    var ac: usize = 0;
    const head = [_][*:0]const u8{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr0", "-video_size", size.ptr, "-framerate", rate.ptr, "-i", "-" };
    for (head) |a| {
        argv[ac] = a;
        ac += 1;
    }
    for (codecArgs(out.kind)) |a| {
        argv[ac] = a;
        ac += 1;
    }
    argv[ac] = &out.path;
    const lrc = linux.open(lg.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(lrc) != .SUCCESS) return fail.nofile();
    const lfd: i32 = @intCast(lrc);
    defer _ = linux.close(lfd);
    var sv: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv)) != .SUCCESS) return fail.nofile();
    const pid = spawn.spawn(exe.ptr, &argv, sv[1], lfd, lfd) orelse {
        _ = linux.close(sv[0]);
        _ = linux.close(sv[1]);
        return fail.nofile();
    };
    _ = linux.close(sv[1]);
    out.fd = sv[0];
    out.pid = pid;
    return .video;
}

/// A frame to ffmpeg's stdin. False: ffmpeg is gone.
fn pipe(px: []const u32) bool {
    const d = std.mem.sliceAsBytes(px);
    var o: usize = 0;
    while (o < d.len) {
        // (no send blocks for ever: the window goes on, Esc reaches a stuck ffmpeg)
        var pfd = [1]linux.pollfd{.{ .fd = out.fd, .events = linux.POLL.OUT, .revents = 0 }};
        _ = linux.poll(&pfd, 1, 200);
        if (pfd[0].revents == 0) {
            jobui.pump();
            // five seconds after Esc; ten minutes of nothing is not an ffmpeg working
            stuck += 1;
            if (stuck > (if (jobui.stop) @as(u32, 25) else 3000)) return false;
            continue;
        }
        const r = linux.sendto(out.fd, d[o..].ptr, d.len - o, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT, null, 0);
        const e = linux.errno(r);
        if (e == .INTR or e == .AGAIN) continue;
        if (e != .SUCCESS or r == 0) return false;
        o += r;
        stuck = 0;
    }
    out.n += 1;
    return true;
}
var stuck: u32 = 0;

/// The frames are all there: finish the file. False: it is not made (said).
fn close() bool {
    const k = out.kind;
    out.kind = .folder;
    if (k == .apng) {
        if (out.ap.close()) return true;
        app.log("  render.animation: could not write the file", .{});
        return false;
    }
    _ = linux.close(out.fd);
    out.fd = -1;
    // (ten minutes for a big file to be finished; what never ends is killed)
    const st = spawn.waitFor(out.pid, 600_000, jobui.pump);
    if (st != null and st.? == 0) return true;
    var first: [97]u8 = undefined;
    var n: usize = 0;
    if (@import("ttf.zig").mapFile(std.mem.sliceTo(&out.log, 0))) |raw| {
        defer _ = linux.munmap(raw.ptr, raw.len);
        while (n < raw.len and n < 96 and raw[n] != '\n') : (n += 1) first[n] = raw[n];
    }
    app.log("  render.animation: ffmpeg could not make the video: {s}", .{if (n > 0) first[0..n] else "(see ~/.cache/beemodel/ffmpeg.log)"});
    return false;
}

fn wallMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// folder/NNNN.png: four digits at least, as the frames are numbered.
fn framePath(buf: []u8, folder: []const u8, f: i32) ?[]const u8 {
    return if (f < 0)
        std.fmt.bufPrint(buf, "{s}/-{d:0>4}.png", .{ folder, @as(u32, @intCast(-@as(i64, f))) }) catch null
    else
        std.fmt.bufPrint(buf, "{s}/{d:0>4}.png", .{ folder, @as(u32, @intCast(f)) }) catch null;
}

/// One frame resolved to its place. False: failed.
fn writeFrame(px: []const u32, w: u32, h: u32, folder: []const u8, video: bool, f: i32) bool {
    if (video and out.kind != .apng) return pipe(px);
    const data = @import("png.zig").encode(A, w, h, px) catch return false;
    defer A.free(data);
    if (video) return out.ap.frame(data, w, h);
    var b: [1100]u8 = undefined;
    const p = framePath(&b, folder, f) orelse return false;
    @import("bee.zig").writeAtomic(p, data) catch return false;
    return true;
}

/// Every frame through the path tracer: the milliseconds, null on a failure.
/// `last_done` is the last frame rendered.
fn frames(first: i32, last: i32, folder: []const u8, video: bool, last_done: *i32) ?i64 {
    const w = render.width;
    const h = render.height;
    const n = @as(usize, w) * h;
    const px = A.alloc(u32, n) catch return null;
    defer A.free(px);
    const t0 = wallMs();
    render.abandon();
    defer pt.freeFilm();
    const count = @as(i64, last) - first + 1;
    var f = first;
    while (true) {
        @import("anim.zig").apply(@floatFromInt(f));
        const base = @as(f32, @floatFromInt(@as(i64, f) - first)) / @as(f32, @floatFromInt(count));
        const share = 1.0 / @as(f32, @floatFromInt(count));
        jobui.set(base);
        // (it builds the scene again: a frame may move it)
        if (!pt.start(w, h, render.samples, render.frameCamera())) return null;
        const gp = @import("gpupt.zig");
        _ = gp.begin(500);
        while (gp.turn(14, wallMs)) {
            jobui.set(base + share * (@as(f32, @floatFromInt(pt.minSpp())) / @as(f32, @floatFromInt(@max(pt.target, 1)))));
        }
        var den: ?[][4]f32 = null;
        if (render.denoise and denoise.run()) den = denoise.out;
        pt.resolve(px, .beauty, den);
        denoise.on = false;
        if (!writeFrame(px, w, h, folder, video, f)) return null;
        last_done.* = f;
        jobui.between();
        if (jobui.stop or f >= last) break;
        f += 1;
    }
    return wallMs() - t0;
}

/// hive_render_frames (BeeScript's render_frames): frames first..last at w x h,
/// spp samples, denoised or not, into folder/NNNN.png (the folder made; its
/// trailing slashes dropped). The milliseconds, null on a failure. The render
/// settings stay as they were.
pub fn renderFrames(folder0: []const u8, w: u32, h: u32, spp: u32, dn: bool, first: i32, last: i32) ?i64 {
    if (first > last) return null;
    if (folder0.len >= 1000) return null;
    var folder = folder0;
    while (folder.len > 1 and folder[folder.len - 1] == '/') folder = folder[0 .. folder.len - 1];
    if (folder.len == 0) return null;
    if (@as(u64, w) * h * 28 >= 1 << 31) return null; // (the film's buffers: the original's 32-bit sizes)
    if (!files.mayWrite(folder)) return null;
    _ = spawn.ensureDir(folder); // (a failure shows as the first frame not written)
    const keep = .{ render.width, render.height, render.samples, render.denoise };
    defer {
        render.width = keep[0];
        render.height = keep[1];
        render.samples = keep[2];
        render.denoise = keep[3];
    }
    render.width = w;
    render.height = h;
    render.samples = spp;
    render.denoise = dn;
    var done: i32 = first;
    return frames(first, last, folder, false, &done);
}

fn job(path: []const u8, a: usize, b: usize) void {
    const first: i32 = @intCast(@as(isize, @bitCast(a)));
    const last: i32 = @intCast(@as(isize, @bitCast(b)));
    stuck = 0;
    if (first > last) return app.log("  render.animation: could not render or write the frames", .{});
    if (!files.mayWrite(path)) return app.log("  render.animation: not written (tests write under /tmp only): {s}", .{path});
    var folder: []const u8 = "";
    const frames_n: u32 = @intCast(@min(@as(i64, last) - first + 1, std.math.maxInt(u32)));
    const op = open(path, render.width, render.height, frames_n, frange.r.fps, &folder);
    if (op == .failed) return;
    const video = op == .video;
    if (!video and !spawn.ensureDir(folder)) return app.log("  render.animation: could not render or write the frames", .{});
    var done: i32 = first;
    const ms = frames(first, last, folder, video, &done);
    if (video and !close()) return;
    const t = ms orelse return app.log("  render.animation: could not render or write the frames", .{});
    if (video) {
        app.log("  rendered frames {d} to {d} -> {s}, ms: {d}{s}", .{ first, done, path, t, if (jobui.stop) " (stopped)" else "" });
    } else {
        app.log("  rendered frames {d} to {d}, ms: {d}{s}", .{ first, done, t, if (jobui.stop) " (stopped)" else "" });
    }
}

fn start(path: []const u8, first: i32, last: i32) void {
    const f: isize = first;
    const l: isize = last;
    jobui.later(job, "Rendering the animation (Esc stops)", path, @bitCast(f), @bitCast(l));
}

fn picked(path: []const u8) void {
    start(path, frange.r.start, frange.r.end);
}

pub const extensions = ".mp4 .mkv .mov .webm .gif .apng .png";

/// render.animation <file or folder> [first last]
pub fn opAnimation() void {
    var it = std.mem.tokenizeAny(u8, ops.arg, " ");
    const raw = it.next() orelse {
        @import("filebrowser.zig").show(.save, "Render Animation", extensions, "animation.mp4", picked);
        return;
    };
    var first = frange.r.start;
    var last = frange.r.end;
    if (it.next()) |s| {
        if (@import("expr.zig").eval(s)) |x| {
            if (std.math.isFinite(x) and @abs(x) < 1e7) {
                first = @intFromFloat(x);
                if (it.next()) |e| {
                    if (@import("expr.zig").eval(e)) |y| {
                        if (std.math.isFinite(y) and @abs(y) < 1e7) last = @intFromFloat(y);
                    }
                }
            }
        }
    }
    var pb: [1024]u8 = undefined;
    const path = files.expandHome(&pb, std.mem.trim(u8, raw, "\"")) orelse return app.log("  render.animation <folder> [first last]", .{});
    start(path, first, last);
}

test "the kinds, by extension" {
    try std.testing.expectEqual(Kind.mp4, kindOf("/a/b.MP4"));
    try std.testing.expectEqual(Kind.mp4, kindOf("x.mov"));
    try std.testing.expectEqual(Kind.mkv, kindOf("x.mkv"));
    try std.testing.expectEqual(Kind.webm, kindOf("x.webm"));
    try std.testing.expectEqual(Kind.gif, kindOf("x.gif"));
    try std.testing.expectEqual(Kind.apng, kindOf("x.apng"));
    try std.testing.expectEqual(Kind.pngs, kindOf("/x/shot.png"));
    try std.testing.expectEqual(Kind.folder, kindOf("/x.mp4/frames"));
    try std.testing.expectEqual(Kind.folder, kindOf("/x/frames.d"));
}
