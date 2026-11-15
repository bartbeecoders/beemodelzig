// Files written so that a kill at any moment leaves either the old file whole
// or the new one whole, never a part of one: the bytes go to a temporary file
// beside the target (its name has this process's id: two windows saving the
// same file do not mix), are synced to the disk, and only then renamed over
// it, and the folder is synced so that the rename itself survives a crash.
// A failure at any step leaves the target as it was.
const std = @import("std");
const linux = std.os.linux;

pub const Error = error{CannotWrite};

/// Tests: writes crawl, so that a kill lands in the middle of one (--slow-writes).
pub var slow = false;

fn tmpName(buf: []u8, path: []const u8, n: u32) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}.{d}-{d}.tmp", .{ path, linux.getpid(), n }, 0) catch null;
}

/// Where the bytes go when `path` is a symbolic link: its target (a rename
/// would replace the link and leave the file it points to as it was).
fn followLink(p: [:0]const u8, buf: *[600]u8) ?[:0]const u8 {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) != .SUCCESS) return null;
    if (st.mode & linux.S.IFMT != linux.S.IFLNK) return null;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .PATH = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null; // (a dangling link: replaced)
    defer _ = linux.close(@intCast(rc));
    var pb: [40]u8 = undefined;
    const lk = std.fmt.bufPrintSentinel(&pb, "/proc/self/fd/{d}", .{rc}, 0) catch return null;
    const n = linux.readlink(lk, buf, buf.len - 1);
    if (linux.errno(n) != .SUCCESS or n == 0 or n >= buf.len - 1) return null;
    buf[n] = 0;
    return buf[0..n :0];
}

fn syncFolder(path: []const u8) void {
    var b: [600]u8 = undefined;
    const sl = std.mem.lastIndexOfScalar(u8, path, '/') orelse return syncDir(".");
    const d = std.fmt.bufPrintSentinel(&b, "{s}", .{if (sl == 0) "/" else path[0..sl]}, 0) catch return;
    syncDir(d);
}

fn syncDir(d: [:0]const u8) void {
    const rc = linux.open(d, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    _ = linux.fsync(@intCast(rc));
    _ = linux.close(@intCast(rc));
}

/// Write `data` to `path` atomically. A file the user made read-only stays.
pub fn write(path: []const u8, data: []const u8) Error!void {
    if (path.len == 0 or path[path.len - 1] == '/') return Error.CannotWrite;
    var pb: [600]u8 = undefined;
    var lb: [600]u8 = undefined;
    var tb: [640]u8 = undefined;
    const p0 = std.fmt.bufPrintSentinel(&pb, "{s}", .{path}, 0) catch return Error.CannotWrite;
    const p = followLink(p0, &lb) orelse p0;
    // not over a folder; keep the old file's permissions
    var st: linux.Statx = undefined;
    var mode: u32 = 0o644;
    if (linux.errno(linux.statx(linux.AT.FDCWD, p, 0, .{ .TYPE = true, .MODE = true }, &st)) == .SUCCESS) {
        if (st.mode & linux.S.IFMT != linux.S.IFREG) return Error.CannotWrite;
        mode = st.mode & 0o7777;
        if (linux.errno(linux.access(p, linux.W_OK)) != .SUCCESS) return Error.CannotWrite;
    }
    // a temporary name nothing else has (one left by a killed process stays
    // out of the way: nothing ever opens it again)
    var t: [:0]const u8 = undefined;
    var fd: i32 = -1;
    var n: u32 = 0;
    while (n < 64) : (n += 1) {
        t = tmpName(&tb, p, n) orelse return Error.CannotWrite;
        const rc = linux.open(t, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, mode);
        const er = linux.errno(rc);
        if (er == .EXIST) continue;
        if (er != .SUCCESS) return Error.CannotWrite;
        fd = @intCast(rc);
        break;
    }
    if (fd < 0) return Error.CannotWrite;
    var off: usize = 0;
    while (off < data.len) {
        const w = linux.write(fd, data[off..].ptr, if (slow) @min(data.len - off, 4096) else data.len - off);
        if (slow) {
            const ts = linux.timespec{ .sec = 0, .nsec = 100_000 };
            _ = linux.nanosleep(&ts, null);
        }
        const er = linux.errno(w);
        if (er == .INTR) continue;
        if (er != .SUCCESS or w == 0) {
            _ = linux.close(fd);
            _ = linux.unlink(t);
            return Error.CannotWrite;
        }
        off += w;
    }
    // (a full disk can surface only here)
    var fs = linux.fsync(fd);
    while (linux.errno(fs) == .INTR) fs = linux.fsync(fd);
    const fsync_ok = linux.errno(fs) == .SUCCESS;
    _ = linux.close(fd);
    if (!fsync_ok or linux.errno(linux.rename(t, p)) != .SUCCESS) {
        _ = linux.unlink(t);
        return Error.CannotWrite;
    }
    syncFolder(p);
}

const testing = std.testing;

fn slurp(path: [:0]const u8, buf: []u8) []const u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return "";
    defer _ = linux.close(@intCast(rc));
    const n = linux.read(@intCast(rc), buf.ptr, buf.len);
    return buf[0..if (linux.errno(n) == .SUCCESS) n else 0];
}

fn testDir(buf: []u8) [:0]const u8 {
    const d = std.fmt.bufPrintSentinel(buf, "/tmp/beemodel-atomic-{d}", .{linux.getpid()}, 0) catch unreachable;
    _ = linux.mkdir(d, 0o755);
    return d;
}

test "a file is replaced whole, no temporary file stays" {
    var db: [100]u8 = undefined;
    const d = testDir(&db);
    var pb: [160]u8 = undefined;
    const p = try std.fmt.bufPrintSentinel(&pb, "{s}/a.bee", .{d}, 0);
    defer _ = linux.unlink(p);
    try write(p, "first");
    try write(p, "second");
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("second", slurp(p, &b));
    // the folder holds a.bee alone
    const rc = linux.open(d, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    defer _ = linux.close(@intCast(rc));
    var eb: [2048]u8 align(8) = undefined;
    const n = linux.getdents64(@intCast(rc), &eb, eb.len);
    var off: usize = 0;
    var files: usize = 0;
    while (off < n) {
        const e: *align(1) linux.dirent64 = @ptrCast(&eb[off]);
        const nm_ptr: [*:0]const u8 = @ptrCast(&eb[off + @offsetOf(linux.dirent64, "name")]);
        off += e.reclen;
        if (nm_ptr[0] != '.') files += 1;
    }
    try testing.expectEqual(1, files);
}

test "a folder or a read-only file is not replaced" {
    var db: [100]u8 = undefined;
    const d = testDir(&db);
    try testing.expectError(Error.CannotWrite, write(d, "x"));
    var pb: [160]u8 = undefined;
    const p = try std.fmt.bufPrintSentinel(&pb, "{s}/ro.bee", .{d}, 0);
    defer _ = linux.unlink(p);
    try write(p, "keep");
    _ = linux.chmod(p, 0o444);
    // (root may write anyway)
    if (linux.getuid() != 0) try testing.expectError(Error.CannotWrite, write(p, "lost"));
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("keep", slurp(p, &b));
}

test "a symbolic link stays one, its target gets the bytes" {
    var db: [100]u8 = undefined;
    const d = testDir(&db);
    var pb: [160]u8 = undefined;
    var lb: [160]u8 = undefined;
    const p = try std.fmt.bufPrintSentinel(&pb, "{s}/target.bee", .{d}, 0);
    const l = try std.fmt.bufPrintSentinel(&lb, "{s}/link.bee", .{d}, 0);
    defer _ = linux.unlink(p);
    defer _ = linux.unlink(l);
    try write(p, "one");
    _ = linux.symlink(p, l);
    try write(l, "two");
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("two", slurp(p, &b));
    var st: linux.Statx = undefined;
    _ = linux.statx(linux.AT.FDCWD, l, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st);
    try testing.expectEqual(linux.S.IFLNK, st.mode & linux.S.IFMT);
}
