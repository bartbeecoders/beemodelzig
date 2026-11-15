// A child process for the AI connections (the original's aiproc.s).
//
// One at a time: a program (found on PATH, or a path) with arguments and an
// optional working directory. Its stdout and stderr come back through one
// pipe the main loop polls without waiting (pollfds / tick); stdin is
// /dev/null. stop() ends it (TERM, then KILL a few ticks later), and a
// finished child is reaped. The text read is handed to a callback as it comes
// (the connection parses lines or waits for the end).
//
// HTTPS requests go through curl the same way: curl() writes the request body
// and the headers (with the key) to files only the user can read and gives
// curl their names, so nothing secret is on a command line.
const std = @import("std");
const linux = std.os.linux;
const spawn_ = @import("spawn.zig");

const MAXARG = 48;
const SIGTERM_TICKS = 6; // (a stop not taken: KILL after this many ticks)

var pid: i32 = 0; // the child (0: none)
var fd: i32 = -1; // its stdout + stderr (the read end)
/// How the last one ended: its exit code, -1 when a signal ended it.
pub var exit_code: i32 = 0;
var kill_at: u32 = 0;

/// cb(bytes): what the child wrote, as it comes.
pub var on_data: ?*const fn ([]const u8) void = null;
/// cb(exit code, -1: killed): the child ended (after the last of its output).
pub var on_exit: ?*const fn (i32) void = null;
/// Something worth a frame happened (the original's dirty).
pub var on_dirty: ?*const fn () void = null;

var buf: [65536]u8 = undefined;
/// This program (for the bridge), ai_exe.
pub var exe: [512]u8 = @splat(0);
pub var exe_len: usize = 0;
/// ~/.cache/beemodel/ai (ours alone), ai_dir.
pub var dir: [512]u8 = @splat(0);
pub var dir_len: usize = 0;
var which_buf: [512]u8 = undefined;

fn z(b: []u8, s: []const u8) [:0]const u8 {
    const n = @min(s.len, b.len - 1);
    @memcpy(b[0..n], s[0..n]);
    b[n] = 0;
    return b[0..n :0];
}

/// ai_dir_make: dir = $HOME/.cache/beemodel/ai, made, 0700; exe = this program.
pub fn dirMake() void {
    const home = spawn_.getenv("HOME") orelse "";
    const s = std.fmt.bufPrint(dir[0 .. dir.len - 1], "{s}/.cache/beemodel/ai", .{home}) catch "";
    dir_len = s.len;
    dir[dir_len] = 0;
    _ = spawn_.ensureDir(dir[0..dir_len]);
    _ = linux.chmod(@ptrCast(&dir), 0o700);
    const r = linux.readlink("/proc/self/exe", &exe, exe.len - 1);
    exe_len = if (linux.errno(r) == .SUCCESS) r else 0;
    exe[exe_len] = 0;
}

pub fn dirPath() []const u8 {
    return dir[0..dir_len];
}
pub fn exePath() []const u8 {
    return exe[0..exe_len];
}

fn runnable(p: [*:0]const u8) bool {
    return linux.errno(linux.access(p, linux.X_OK)) == .SUCCESS;
}

/// ai_which: the path of a program (one with a / as it is, else the first
/// PATH directory that has it runnable; empty directories skipped, 400 bytes
/// of a directory at most), or null.
pub fn which(name: []const u8) ?[:0]const u8 {
    if (std.mem.indexOfAny(u8, name, "/\\") != null) {
        const p = z(&which_buf, name);
        return if (runnable(p.ptr)) p else null;
    }
    const path = spawn_.getenv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |d0| {
        if (d0.len == 0) continue;
        const d = d0[0..@min(d0.len, 400)];
        const p = std.fmt.bufPrintSentinel(&which_buf, "{s}/{s}", .{ d, name }, 0) catch continue;
        if (runnable(p.ptr)) return p;
    }
    return null;
}

/// ai_proc_spawn: start a program (path, argv, working directory or null):
/// true when it started (false: one is running, or it failed).
pub fn spawn(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8) bool {
    if (pid != 0) return false;
    var p: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&p, .{ .CLOEXEC = true })) != .SUCCESS) return false;
    const envp = spawn_.environ();
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        _ = linux.close(p[0]);
        _ = linux.close(p[1]);
        return false;
    }
    if (rc == 0) {
        // the child: stdin nothing, stdout and stderr into the pipe
        const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(devnull) == .SUCCESS) _ = linux.dup2(@intCast(devnull), 0);
        _ = linux.dup2(p[1], 1);
        _ = linux.dup2(p[1], 2);
        _ = linux.syscall3(.close_range, 3, std.math.maxInt(u32), 0);
        if (cwd) |d| _ = linux.chdir(d);
        _ = linux.execve(path, argv, envp);
        linux.exit_group(127);
    }
    pid = @intCast(rc);
    _ = linux.close(p[1]);
    const fl = linux.fcntl(p[0], linux.F.GETFL, 0);
    _ = linux.fcntl(p[0], linux.F.SETFL, (if (linux.errno(fl) == .SUCCESS) fl else 0) | @as(usize, 0o4000)); // O_NONBLOCK
    fd = p[0];
    kill_at = 0;
    return true;
}

/// ai_proc_running
pub fn running() bool {
    return pid != 0;
}

/// ai_proc_stop: ask it to end (TERM; KILL if it is still there later).
pub fn stop() void {
    if (pid == 0) return;
    _ = linux.kill(pid, .TERM);
    kill_at = SIGTERM_TICKS;
}

/// ai_proc_kill: end it now (BeeModel is quitting).
pub fn kill() void {
    if (pid == 0) return;
    _ = linux.kill(pid, .KILL);
}

/// ai_pollfds: the child's pipe (entries written).
pub fn pollfds(p: []linux.pollfd) usize {
    if (fd < 0 or p.len == 0) return 0;
    p[0] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
    return 1;
}

fn deliver(n: usize) void {
    if (on_data) |f| f(buf[0..n]);
}

/// ai_tick: what the child wrote (to the callback); its end (reaped, then
/// the exit callback).
pub fn tick() void {
    if (pid == 0) return;
    if (kill_at > 0) {
        kill_at -= 1;
        if (kill_at == 0) _ = linux.kill(pid, .KILL);
    }
    if (fd >= 0) {
        while (true) {
            const r = linux.read(fd, &buf, buf.len - 1);
            if (linux.errno(r) != .SUCCESS) break; // (nothing now)
            if (r == 0) {
                _ = linux.close(fd); // its output is done
                fd = -1;
                break;
            }
            deliver(r);
        }
    }
    var st0: i32 = 0;
    const w = linux.wait4(pid, &st0, 1, null); // WNOHANG
    const st: u32 = @bitCast(st0);
    if (linux.errno(w) != .SUCCESS or w == 0) return;
    if (fd >= 0) {
        // (the pipe drained first: what it wrote before it ended)
        while (true) {
            const r = linux.read(fd, &buf, buf.len - 1);
            if (linux.errno(r) != .SUCCESS or r == 0) break;
            deliver(r);
        }
        _ = linux.close(fd);
        fd = -1;
    }
    pid = 0;
    kill_at = 0;
    exit_code = if (st & 0x7f != 0) -1 else @intCast((st >> 8) & 0xff);
    if (on_dirty) |f| f();
    if (on_exit) |f| f(exit_code);
}

/// file_write_private: a temporary file (0600), then renamed over the path.
pub fn writePrivate(path: []const u8, data: []const u8) bool {
    var pb: [600]u8 = undefined;
    var tb: [610]u8 = undefined;
    const pz = z(&pb, path);
    const tz = std.fmt.bufPrintSentinel(&tb, "{s}.tmp", .{path}, 0) catch return false;
    const o = linux.open(tz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(o) != .SUCCESS) return false;
    const f: i32 = @intCast(o);
    var off: usize = 0;
    while (off < data.len) {
        const r = linux.write(f, data[off..].ptr, data.len - off);
        if (linux.errno(r) == .INTR) continue;
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        off += r;
    }
    _ = linux.close(f);
    if (off < data.len) {
        _ = linux.unlink(tz);
        return false;
    }
    return linux.errno(linux.rename(tz, pz)) == .SUCCESS;
}

var curl_path: [512]u8 = undefined;
var url_z: [1024]u8 = undefined;
var hdr_arg: [600]u8 = undefined;
var body_arg: [600]u8 = undefined;
var hdr_txt: [1024]u8 = undefined;
var argv_buf: [MAXARG:null]?[*:0]const u8 = @splat(null);

/// ai_curl(URL, request body or null (a GET), one header line (the key:
/// "Authorization: Bearer ...") or null): true when it started; the reply
/// comes to on_data, the end to on_exit.
///   curl -sS -m 600 -H @<dir>/request.headers [--data-binary @<dir>/request.json] <url>
pub fn curl(url: []const u8, body: ?[]const u8, header: ?[]const u8) bool {
    if (pid != 0) return false;
    dirMake();
    const cp = which("curl") orelse return false;
    const cpz = z(&curl_path, cp);
    const uz = z(&url_z, url);
    var n: usize = 0;
    if (header) |h| {
        const k = @min(h.len, 900);
        @memcpy(hdr_txt[0..k], h[0..k]);
        hdr_txt[k] = 10;
        n = k + 1;
    }
    const ct = "Content-Type: application/json\n";
    @memcpy(hdr_txt[n .. n + ct.len], ct);
    n += ct.len;
    const ha = std.fmt.bufPrintSentinel(&hdr_arg, "@{s}/request.headers", .{dirPath()}, 0) catch return false;
    _ = writePrivate(ha[1..], hdr_txt[0..n]);
    var k: usize = 0;
    argv_buf[k] = "curl";
    argv_buf[k + 1] = "-sS";
    argv_buf[k + 2] = "-m";
    argv_buf[k + 3] = "600";
    argv_buf[k + 4] = "-H";
    argv_buf[k + 5] = ha.ptr;
    k += 6;
    if (body) |b| {
        const ba = std.fmt.bufPrintSentinel(&body_arg, "@{s}/request.json", .{dirPath()}, 0) catch return false;
        _ = writePrivate(ba[1..], b);
        argv_buf[k] = "--data-binary";
        argv_buf[k + 1] = ba.ptr;
        k += 2;
    }
    argv_buf[k] = uz.ptr;
    argv_buf[k + 1] = null;
    return spawn(cpz.ptr, &argv_buf, null);
}

test "a child's output through the pipe, its exit code, a stop" {
    const sh = which("sh") orelse return error.SkipZigTest;
    var shb: [512]u8 = undefined;
    const shz = z(&shb, sh);
    const S = struct {
        var got: [256]u8 = undefined;
        var n: usize = 0;
        var code: i32 = 99;
        fn data(b: []const u8) void {
            const k = @min(b.len, got.len - n);
            @memcpy(got[n .. n + k], b[0..k]);
            n += k;
        }
        fn exit(c: i32) void {
            code = c;
        }
    };
    on_data = S.data;
    on_exit = S.exit;
    defer {
        on_data = null;
        on_exit = null;
    }
    const av = [_:null]?[*:0]const u8{ "sh", "-c", "echo out; echo err >&2; exit 3" };
    try std.testing.expect(spawn(shz.ptr, &av, null));
    try std.testing.expect(!spawn(shz.ptr, &av, null)); // (one at a time)
    var k: usize = 0;
    while (running() and k < 2000) : (k += 1) {
        tick();
        var ts = linux.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    try std.testing.expect(!running());
    try std.testing.expectEqual(@as(i32, 3), S.code);
    try std.testing.expect(std.mem.indexOf(u8, S.got[0..S.n], "out\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, S.got[0..S.n], "err\n") != null);
    const av2 = [_:null]?[*:0]const u8{ "sh", "-c", "trap '' TERM; exec sleep 30" };
    try std.testing.expect(spawn(shz.ptr, &av2, null));
    var ts0 = linux.timespec{ .sec = 0, .nsec = 50_000_000 };
    _ = linux.nanosleep(&ts0, null);
    stop();
    k = 0;
    while (running() and k < 2000) : (k += 1) {
        tick();
        var ts = linux.timespec{ .sec = 0, .nsec = 2_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    try std.testing.expect(!running());
    try std.testing.expectEqual(@as(i32, -1), S.code);
    try std.testing.expect(which("no-such-program-here-x") == null);
}
