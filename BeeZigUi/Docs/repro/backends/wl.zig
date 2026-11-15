const std = @import("std");
const zui = @import("zui");
const wl = @import("wl");
const software = @import("zui_software");
const linux = std.os.linux;
const testing = std.testing;

fn msg(buf: *std.ArrayList(u8), obj: u32, op: u16, args: []const u32) void {
    const len: u32 = @intCast(8 + 4 * args.len);
    buf.appendSlice(testing.allocator, std.mem.asBytes(&obj)) catch unreachable;
    const so: u32 = (len << 16) | op;
    buf.appendSlice(testing.allocator, std.mem.asBytes(&so)) catch unreachable;
    for (args) |a| buf.appendSlice(testing.allocator, std.mem.asBytes(&a)) catch unreachable;
}

fn pair() [2]i32 {
    var sv: [2]i32 = undefined;
    _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv);
    return sv;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "repeat_rate 0 while a key is held: wait(-1) spins" {
    const sv = pair();
    const d = try testing.allocator.create(wl.Display);
    defer testing.allocator.destroy(d);
    d.* = .{ .gpa = testing.allocator, .sw = .init(testing.allocator) };
    defer d.sw.deinit();
    d.fd = sv[0];
    d.keyboard = 50;
    var input: zui.Input = .{};
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(testing.allocator);
    msg(&b, 50, 5, &.{ 0, 10 }); // repeat_info(rate 0, delay 10)
    msg(&b, 50, 3, &.{ 1, 0, 30, 1 }); // key a down
    _ = linux.write(sv[1], b.items.ptr, b.items.len);
    _ = try d.wait(&input, 100);
    var spins: usize = 0;
    const t0 = nowMs();
    while (nowMs() - t0 < 200) : (spins += 1) _ = try d.wait(&input, -1); // -1: "until something happens"
    std.debug.print("wait(-1) returned {d} times in 200 ms with nothing arriving\n", .{spins});
    try testing.expect(spins > 1000);
}

test "five surfaces drawn first in one present overflow ofds[4]" {
    const sv = pair();
    const gpa = testing.allocator;
    const d = try gpa.create(wl.Display);
    defer gpa.destroy(d);
    d.* = .{ .gpa = gpa, .sw = .init(gpa) };
    d.fd = sv[0];
    d.shm = 3;
    d.compositor = 4;
    var font = try zui.Font.initDefault(gpa);
    defer font.deinit();
    var ui: zui.Ui = .init(gpa, .{ .font = &font });
    defer ui.deinit();
    const titles = [_][]const u8{ "A", "B", "C", "D", "E" };
    var list: *const zui.DrawList = undefined;
    for (0..2) |_| {
        ui.beginFrame(.{ .width = 200, .height = 200, .dt = 0.016 });
        inline for (titles) |t| if (ui.beginWindow(t, .{ .size = .{ .x = 50, .y = 50 }, .detached = true })) ui.endWindow();
        list = try ui.endFrame();
    }
    // Main window already has its pool (as after the first present); the five
    // detached windows got their configure in the same dispatch.
    d.surfaces[0] = .{ .configured = true, .width = 20, .height = 20, .surface = 100, .pool = 101, .pool_size = 1 << 20, .mem_fd = -1 };
    const mm = linux.mmap(null, 1 << 20, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    d.surfaces[0].mem = @ptrFromInt(mm);
    d.surface_count = 1;
    for (ui.viewports(), 0..) |vp, k| {
        d.surfaces[1 + k] = .{ .viewport = vp.id, .configured = true, .width = 20, .height = 20, .surface = @intCast(200 + k * 10), .toplevel = @intCast(201 + k * 10) };
        d.surface_count += 1;
    }
    std.debug.print("viewports: {d}\n", .{ui.viewports().len});
    d.next_id = 1000;
    try d.present(&ui, list); // panics: index out of bounds in req() when onfd reaches 4
}

fn sendWithFd(sock: i32, bytes: []const u8, fd: i32) void {
    var iov = [1]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    var ctrl: [24]u8 align(8) = @splat(0);
    std.mem.writeInt(usize, ctrl[0..8], 20, .little);
    std.mem.writeInt(i32, ctrl[8..12], linux.SOL.SOCKET, .little);
    std.mem.writeInt(i32, ctrl[12..16], linux.SCM.RIGHTS, .little);
    std.mem.writeInt(i32, ctrl[16..20], fd, .little);
    var m = linux.msghdr_const{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &ctrl, .controllen = 24, .flags = 0 };
    _ = linux.sendmsg(sock, &m, 0);
}

test "an fd sent to a destroyed data source stays queued and is later taken as the keymap" {
    const sv = pair();
    const gpa = testing.allocator;
    const d = try gpa.create(wl.Display);
    defer gpa.destroy(d);
    d.* = .{ .gpa = gpa, .sw = .init(gpa) };
    defer d.sw.deinit();
    d.fd = sv[0];
    d.keyboard = 50;
    var input: zui.Input = .{};
    // wl_data_source.send("text/plain", fd) for source 77, already destroyed (d.source == 0)
    var p: [2]i32 = undefined;
    _ = linux.pipe2(&p, .{ .CLOEXEC = true });
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    const mime = "text/plain\x00\x00";
    const obj: u32 = 77;
    const so: u32 = ((8 + 4 + 12) << 16) | 1;
    try b.appendSlice(gpa, std.mem.asBytes(&obj));
    try b.appendSlice(gpa, std.mem.asBytes(&so));
    const n: u32 = 11;
    try b.appendSlice(gpa, std.mem.asBytes(&n));
    try b.appendSlice(gpa, mime);
    sendWithFd(sv[1], b.items, p[1]);
    _ = try d.wait(&input, 100);
    std.debug.print("fds still queued after the unhandled send: {d}\n", .{d.ifd_n});
    // Now the real keymap arrives with its own fd.
    const text = @embedFile("fr.xkb");
    const mf: i32 = @intCast(linux.memfd_create("km", 0));
    _ = linux.write(mf, text.ptr, text.len);
    b.clearRetainingCapacity();
    msg(&b, 50, 0, &.{ 1, text.len + 1 });
    sendWithFd(sv[1], b.items, mf);
    _ = try d.wait(&input, 100);
    std.debug.print("keymap loaded: {}  fds queued: {d}\n", .{ d.keymap.loaded, d.ifd_n });
    try testing.expect(!d.keymap.loaded);
}
