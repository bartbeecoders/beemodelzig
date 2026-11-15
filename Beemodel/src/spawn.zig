// Running other programs with no libc (the original's plat_spawn, ai_which):
// fork, the child's descriptors set up, execve. The environment is the one the
// kernel gave us (/proc/self/environ), read once.
const std = @import("std");
const linux = std.os.linux;
const A = std.heap.page_allocator;

pub const KEEP: i32 = -1; // the child keeps ours
pub const NULL: i32 = -2; // /dev/null

const MAX_VARS = 1024;
var env_data: []u8 = &.{};
var env_ptrs: [MAX_VARS + 1:null]?[*:0]const u8 = @splat(null);
var env_ok = false;

fn loadEnv() void {
    if (env_ok) return;
    env_ok = true;
    const fd = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    // (a file of no size: read until it ends, a megabyte at most)
    const buf = A.alloc(u8, 1 << 20) catch return;
    var n: usize = 0;
    while (n + 1 < buf.len) {
        const r = linux.read(@intCast(fd), buf[n..].ptr, buf.len - 1 - n);
        if (linux.errno(r) == .INTR) continue;
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    buf[n] = 0;
    env_data = buf[0 .. n + 1];
    var k: usize = 0;
    var o: usize = 0;
    while (o < n and k < MAX_VARS) {
        const e = std.mem.indexOfScalarPos(u8, env_data, o, 0) orelse break;
        if (e > o) {
            env_ptrs[k] = @ptrCast(env_data[o..].ptr);
            k += 1;
        }
        o = e + 1;
    }
}

/// The environment, as execve wants it.
pub fn environ() [*:null]const ?[*:0]const u8 {
    loadEnv();
    return &env_ptrs;
}

/// The value of an environment variable.
pub fn getenv(name: []const u8) ?[]const u8 {
    loadEnv();
    for (env_ptrs) |p0| {
        const p = p0 orelse break;
        const s = std.mem.sliceTo(p, 0);
        if (s.len > name.len and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name)) return s[name.len + 1 ..];
    }
    return null;
}

fn executable(p: [*:0]const u8) bool {
    return linux.errno(linux.access(p, linux.X_OK)) == .SUCCESS;
}

fn isFile(p: [*:0]const u8) bool {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, p, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return false;
    return st.mode & linux.S.IFMT != linux.S.IFDIR;
}

/// Where a program is: with a slash as it is, else on PATH. Into buf.
pub fn which(buf: []u8, prog: []const u8) ?[:0]const u8 {
    if (prog.len == 0) return null;
    if (std.mem.indexOfScalar(u8, prog, '/') != null) {
        const p = std.fmt.bufPrintSentinel(buf, "{s}", .{prog}, 0) catch return null;
        return if (executable(p) and isFile(p)) p else null;
    }
    var it = std.mem.tokenizeScalar(u8, getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin", ':');
    while (it.next()) |d| {
        const p = std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ d, prog }, 0) catch continue;
        if (executable(p) and isFile(p)) return p;
    }
    return null;
}

/// Start a program: its pid, or null. stdin, stdout, stderr: a descriptor, KEEP
/// or NULL. Everything else we have open stays out of the child.
pub fn spawn(exe: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, stdin: i32, stdout: i32, stderr: i32) ?i32 {
    loadEnv();
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return null;
    if (rc == 0) {
        // the child: nothing here allocates or returns
        const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        const nul: i32 = if (linux.errno(devnull) == .SUCCESS) @intCast(devnull) else -1;
        const want = [3]i32{ stdin, stdout, stderr };
        // (first out of the way of 0, 1, 2: a descriptor may be one of them)
        var src: [3]i32 = undefined;
        for (want, 0..) |w, k| {
            const s = if (w == NULL) nul else w;
            if (s < 0) {
                src[k] = -1;
                continue;
            }
            const d = linux.fcntl(s, linux.F.DUPFD, 10);
            src[k] = if (linux.errno(d) == .SUCCESS) @intCast(d) else -1;
        }
        for (src, 0..) |s, k| {
            if (s >= 0) _ = linux.dup2(s, @intCast(k));
        }
        _ = linux.syscall3(.close_range, 3, std.math.maxInt(u32), 0);
        _ = linux.execve(exe, argv, &env_ptrs);
        linux.exit_group(127);
    }
    return @intCast(rc);
}

/// Wait for a child: its status (0: it ended well). Null: no such child.
pub fn wait(pid: i32) ?u32 {
    while (true) {
        var st: i32 = 0;
        const r = linux.wait4(pid, &st, 0, null);
        const e = linux.errno(r);
        if (e == .INTR) continue;
        return if (e == .SUCCESS) @bitCast(st) else null;
    }
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Wait at most ms for a child, turning `tick` (the window) meanwhile; past
/// that it is killed. Its status, or null when it had to go.
pub fn waitFor(pid: i32, ms: i64, tick: ?*const fn () void) ?u32 {
    const t0 = nowMs();
    while (true) {
        var st: i32 = 0;
        const r = linux.wait4(pid, &st, 1, null); // WNOHANG
        const e = linux.errno(r);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return null;
        if (r != 0) return @bitCast(st);
        if (nowMs() - t0 > ms) {
            _ = linux.kill(pid, .KILL);
            _ = wait(pid);
            return null;
        }
        if (tick) |f| f();
        var ts = linux.timespec{ .sec = 0, .nsec = 5_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
}

/// mkdir -p: true when the folder is there.
pub fn ensureDir(path: []const u8) bool {
    var b: [1024]u8 = undefined;
    if (path.len == 0 or path.len >= b.len) return false;
    @memcpy(b[0..path.len], path);
    b[path.len] = 0;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and b[i] != '/') continue;
        const c = b[i];
        b[i] = 0;
        const e = linux.errno(linux.mkdir(@ptrCast(&b), 0o755));
        b[i] = c;
        if (e != .SUCCESS and e != .EXIST) return false;
    }
    var st: linux.Statx = undefined;
    b[path.len] = 0;
    if (linux.errno(linux.statx(linux.AT.FDCWD, @ptrCast(&b), 0, .{ .TYPE = true }, &st)) != .SUCCESS) return false;
    return st.mode & linux.S.IFMT == linux.S.IFDIR;
}

test "a child's exit status, its output, a kill past the time" {
    if (@import("builtin").os.tag != .linux) return;
    var b: [256]u8 = undefined;
    const sh = which(&b, "sh") orelse return error.SkipZigTest;
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds));
    const av = [_:null]?[*:0]const u8{ "sh", "-c", "echo hello; exit 3" };
    const pid = spawn(sh, &av, NULL, fds[1], NULL).?;
    _ = linux.close(fds[1]);
    var got: [32]u8 = undefined;
    const n = linux.read(fds[0], &got, got.len);
    try std.testing.expectEqualStrings("hello\n", got[0..n]);
    _ = linux.close(fds[0]);
    try std.testing.expectEqual(@as(?u32, 3 << 8), wait(pid));
    const av2 = [_:null]?[*:0]const u8{ "sh", "-c", "sleep 30" };
    const p2 = spawn(sh, &av2, NULL, NULL, NULL).?;
    try std.testing.expectEqual(@as(?u32, null), waitFor(p2, 50, null));
    try std.testing.expect(which(&b, "no-such-program-here") == null);
}
