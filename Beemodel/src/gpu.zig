// The optional GPU helper (beemodel-gpu), from this side (gpu.s). BeeModel links
// nothing, so the GPU is reached through a separate program (src/gpu/helper.zig)
// with a SOCK_SEQPACKET socket on its fd 3; data goes through shared memory, one
// memfd per slot (src/gpu/ipc.zig).
//
// Everything falls back to the CPU: no helper, no Vulkan device, a scene the
// kernels do not cover, or the helper failing or dying mid-way (it is then
// stopped for the session and the work goes on where it was). BEEMODEL_GPU=off
// never starts it; BEEMODEL_GPU=any lets it use a CPU Vulkan (llvmpipe).
//
// Nothing here waits without a limit, and the UI's turns do not wait at all: a run
// is sent and its reply polled for. Replies come in order, so what was sent is
// remembered (a warm-up, slots mapped, one run) and a helper that goes quiet past
// the time allowed is killed. Slots are written only when no run is in flight.
const std = @import("std");
const linux = std.os.linux;
const ipc = @import("gpu/ipc.zig");
const spawn = @import("spawn.zig");
const app = @import("app.zig");
const A = std.heap.page_allocator;

const HELLO_MS = 15000; // a slow driver start is fine
const RUN_MS = 120000;

pub const Device = enum(u8) {
    auto,
    rtx,
    gpu,
    cpu,
    pub fn label(d: Device) []const u8 {
        return switch (d) {
            .auto => "Auto",
            .rtx => "GPU (RTX)",
            .gpu => "GPU",
            .cpu => "CPU",
        };
    }
};
/// Render > Device: where renders run.
pub var device: Device = .auto;

const State = enum { idle, starting, up, dead };
var state: State = .idle;
var fd: i32 = -1;
var pid: i32 = 0;
var told = false;
var name_buf: [48]u8 = @splat(0);
var dev_type: u32 = 0;
var has_rtx = false;
var has_host = false;
var has_gfx = false;
var run_ms_limit: i64 = RUN_MS;
/// Moves when the helper is lost: who holds work on it looks again.
pub var lost: u32 = 0;
/// GPU-side milliseconds and runs (render.device says them).
pub var total_ms: u64 = 0;
pub var total_runs: u64 = 0;

// replies expected, in order
const Expect = enum { none, warm, map, run };
var fifo: [16]Expect = @splat(.none);
var fifo_head: u32 = 0;
var fifo_n: u32 = 0;
var deadline: i64 = 0; // the oldest reply, by then
var run_out = false; // a run in flight

pub const Slot = struct { base: ?[*]u8 = null, size: u64 = 0 };
pub var slots: [ipc.NSLOT]Slot = @splat(.{});

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn envIs(name: []const u8, v: []const u8) bool {
    const s = spawn.getenv(name) orelse return false;
    return std.mem.eql(u8, s, v);
}

pub fn deviceName() []const u8 {
    return std.mem.sliceTo(&name_buf, 0);
}

/// The helper is up (no waiting).
pub fn isUp() bool {
    return state == .up;
}
/// It may yet come up: started, its hello not read.
pub fn isStarting() bool {
    return state == .starting;
}
pub fn hasRtx() bool {
    return state == .up and has_rtx;
}
/// The helper imports the shared memory (no copies).
pub fn hasGfx() bool {
    return state == .up and has_gfx;
}
pub fn hostMem() bool {
    return state == .up and has_host;
}
pub fn typeOf() u32 {
    return if (state == .up) dev_type else 0;
}

fn sayNone() void {
    if (told) return;
    told = true;
    app.log("  GPU helper: not used (CPU paths)", .{});
}

fn helperPath(buf: *[1024]u8) ?[*:0]const u8 {
    if (spawn.getenv("BEEMODEL_GPU_HELPER")) |p| {
        return (std.fmt.bufPrintSentinel(buf, "{s}", .{p}, 0) catch return null).ptr;
    }
    // next to this binary
    var self: [900]u8 = undefined;
    const n = linux.readlink("/proc/self/exe", &self, self.len);
    if (linux.errno(n) != .SUCCESS) return null;
    const slash = std.mem.lastIndexOfScalar(u8, self[0..n], '/') orelse return null;
    return (std.fmt.bufPrintSentinel(buf, "{s}/beemodel-gpu", .{self[0..slash]}, 0) catch return null).ptr;
}

/// Start it: its hello comes later (pump).
fn start() void {
    if (state != .idle) return;
    const e = spawn.getenv("BEEMODEL_GPU");
    if (e) |v| {
        if (std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "0")) return gone(false);
    }
    if (spawn.getenv("BEEMODEL_GPU_TIMEOUT_MS")) |v| run_ms_limit = std.fmt.parseInt(i64, v, 10) catch RUN_MS;
    var pb: [1024]u8 = undefined;
    const path = helperPath(&pb) orelse return gone(false);
    if (linux.errno(linux.access(path, linux.X_OK)) != .SUCCESS) return gone(false);
    var sv: [2]i32 = undefined;
    // (SOCK_CLOEXEC: the sockets stay out of what else gets started)
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0, &sv)) != .SUCCESS) return gone(false);
    const envp = spawn.environ();
    const argv = [_:null]?[*:0]const u8{"beemodel-gpu"};
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        _ = linux.close(sv[0]);
        _ = linux.close(sv[1]);
        return gone(false);
    }
    if (rc == 0) {
        // the child: its end on fd 3, nothing else; it goes when we do
        _ = linux.prctl(1, 9, 0, 0, 0); // PR_SET_PDEATHSIG, SIGKILL
        _ = linux.dup2(sv[1], 3);
        _ = linux.syscall3(.close_range, 4, std.math.maxInt(u32), 0);
        _ = linux.execve(path, &argv, envp);
        linux.exit_group(127);
    }
    _ = linux.close(sv[1]);
    fd = sv[0];
    pid = @intCast(rc);
    state = .starting;
    deadline = nowMs() + HELLO_MS;
}

fn gone(say: bool) void {
    if (say) {
        told = false;
    }
    state = .dead;
    sayNone();
}

/// It goes, for the session. Nothing waits on it for long (a helper stuck in its
/// driver is reaped by whatever turn comes next).
fn kill(why: []const u8) void {
    if (pid != 0) {
        _ = linux.kill(pid, .KILL);
        reap_pid = pid;
        pid = 0;
    }
    if (fd >= 0) _ = linux.close(fd);
    fd = -1;
    const was_up = state == .up;
    state = .dead;
    fifo_n = 0;
    run_out = false;
    lost +%= 1;
    for (&slots) |*s| {
        if (s.base) |b| _ = linux.munmap(b, s.size);
        s.* = .{};
    }
    if (was_up) app.log("  GPU helper: stopped ({s}): the CPU from here on", .{why}) else if (!told) {
        told = true;
        app.log("  GPU helper: not used ({s})", .{why});
    }
    app.dirty = true;
}
var reap_pid: i32 = 0;

fn reap() void {
    if (reap_pid == 0) return;
    var st: i32 = 0;
    const r = linux.wait4(reap_pid, &st, 1, null); // WNOHANG
    if (linux.errno(r) != .SUCCESS or r != 0) reap_pid = 0;
}

fn recv(m: *ipc.Msg, wait_ms: i32) enum { got, none, closed } {
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const r = linux.poll(&pfd, 1, wait_ms);
    if (linux.errno(r) == .INTR) return .none;
    if (linux.errno(r) != .SUCCESS) return .closed;
    if (r == 0) return .none;
    const n = linux.recvfrom(fd, std.mem.asBytes(m), ipc.GM_SZ, 0x40, null, null); // MSG_DONTWAIT
    const e = linux.errno(n);
    if (e == .AGAIN or e == .INTR) return .none;
    if (e != .SUCCESS or n != ipc.GM_SZ) return .closed;
    return .got;
}

fn takeHello(m: *const ipc.Msg) void {
    if (m.cmd != ipc.MSG_HELLO or m.a != ipc.GPU_MAGIC) return kill("a bad hello");
    if (m.slot != ipc.GH_OK) {
        const why: []const u8 = switch (m.slot) {
            ipc.GH_NOLOADER => "no Vulkan",
            ipc.GH_NODEVICE => "no usable device",
            ipc.GH_NOPIPE => "the shaders did not build",
            else => "a bad hello",
        };
        return kill(why);
    }
    if (m.b & ipc.GH_PORT == 0) return kill("not the port's helper");
    dev_type = m.b & 0xff;
    has_rtx = m.b & ipc.GH_RTX != 0;
    has_host = m.b & ipc.GH_HOSTMEM != 0;
    has_gfx = m.b & ipc.GH_GFX != 0;
    name_buf = m.nameC().*;
    name_buf[47] = 0;
    state = .up;
    deadline = nowMs() + run_ms_limit;
    app.log("  GPU helper: {s}{s}{s}", .{ deviceName(), if (has_rtx) " (RTX)" else "", if (has_host) ", shared memory imported" else "" });
    app.dirty = true;
}

/// What came in, waiting at most wait_ms; the deadline kept.
pub fn pump(wait_ms: i32) void {
    reap();
    if (state != .up and state != .starting) return;
    var left = wait_ms;
    while (true) {
        if (state == .up and fifo_n == 0) return;
        var m: ipc.Msg = undefined;
        const t0 = nowMs();
        switch (recv(&m, left)) {
            .closed => return kill("it ended"),
            .none => {
                if (nowMs() >= deadline) return kill("no answer in time");
                left -= @intCast(nowMs() - t0);
                if (left <= 0) return;
                continue;
            },
            .got => {},
        }
        if (state == .starting) {
            takeHello(&m);
            if (state != .up) return;
            left = 0;
            continue;
        }
        if (m.cmd != ipc.MSG_REPLY) return kill("a bad reply");
        if (m.slot != 0) return kill("a run failed");
        const k = fifo[fifo_head];
        fifo_head = (fifo_head + 1) % @as(u32, fifo.len);
        fifo_n -= 1;
        deadline = nowMs() + run_ms_limit;
        if (k == .run) {
            run_out = false;
            total_ms += m.a;
            total_runs += 1;
            return;
        }
        left = 0;
    }
}

fn expect(k: Expect) void {
    if (fifo_n == 0) deadline = nowMs() + run_ms_limit;
    fifo[(fifo_head + fifo_n) % @as(u32, fifo.len)] = k;
    fifo_n += 1;
}

fn sendMsg(m: *const ipc.Msg, pass_fd: i32) bool {
    if (fd < 0) return false;
    var iov = [1]std.posix.iovec_const{.{ .base = @ptrCast(m), .len = ipc.GM_SZ }};
    var ctl: [24]u8 align(8) = @splat(0);
    var h = linux.msghdr_const{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
    if (pass_fd >= 0) {
        std.mem.writeInt(u64, ctl[0..8], 20, .little); // cmsg_len
        std.mem.writeInt(u32, ctl[8..12], 1, .little); // SOL_SOCKET
        std.mem.writeInt(u32, ctl[12..16], 1, .little); // SCM_RIGHTS
        std.mem.writeInt(i32, ctl[16..20], pass_fd, .little);
        h.control = &ctl;
        h.controllen = ctl.len;
    }
    while (true) {
        const r = linux.sendmsg(fd, &h, 0x4000 | 0x40); // MSG_NOSIGNAL, MSG_DONTWAIT
        const e = linux.errno(r);
        if (e == .INTR) continue;
        if (e == .SUCCESS and r == ipc.GM_SZ) return true;
        kill("it ended");
        return false;
    }
}

/// The window opens: the helper in the background, its kernels made while we start.
pub fn prewarm() void {
    if (state != .idle or device == .cpu) return;
    start();
    if (state != .starting) return;
    const m = ipc.Msg{ .cmd = ipc.MSG_WARM, .slot = if (device == .gpu) 0 else 1 };
    if (sendMsg(&m, -1)) expect(.warm);
}

/// The helper is up: started if it was not, waiting for its hello at most
/// wait_ms. Render > Device CPU: no.
pub fn ready(wait_ms: i32) bool {
    reap();
    if (device == .cpu) return false;
    if (state == .idle) {
        start();
    }
    if (state == .starting) {
        const t0 = nowMs();
        while (state == .starting) {
            const left: i64 = wait_ms - (nowMs() - t0);
            pump(@intCast(std.math.clamp(left, 0, 50)));
            if (left <= 0) break;
        }
    }
    return state == .up;
}

/// A run's reply is awaited: slots stay as they are.
pub fn busy() bool {
    return run_out;
}

/// The slot's memory, at least `bytes`: 1 MiB steps, a new memfd when it grows
/// (what it held is gone: `fresh` says so). Null: no helper, or no memory. Only
/// when no run is in flight.
pub fn slot(i: usize, bytes: u64, fresh: *bool) ?[*]u8 {
    if (state != .up or run_out) return null;
    const s = &slots[i];
    fresh.* = false;
    if (s.base != null and s.size >= bytes) return s.base;
    if (fifo_n + 2 >= fifo.len) pump(100);
    if (state != .up or fifo_n + 2 >= fifo.len) return null;
    const size = (bytes + 0xfffff) & ~@as(u64, 0xfffff);
    const r = linux.memfd_create("beemodel-gpu", 1); // MFD_CLOEXEC
    if (linux.errno(r) != .SUCCESS) return null;
    const mf: i32 = @intCast(r);
    defer _ = linux.close(mf);
    if (linux.errno(linux.ftruncate(mf, @intCast(size))) != .SUCCESS) return null;
    const p = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, mf, 0);
    if (linux.errno(p) != .SUCCESS) return null;
    var m = ipc.Msg{ .cmd = ipc.MSG_MAP, .slot = @intCast(i) };
    m.setSize(size);
    if (!sendMsg(&m, mf)) {
        _ = linux.munmap(@ptrFromInt(p), size);
        return null;
    }
    expect(.map);
    if (s.base) |b| _ = linux.munmap(b, s.size);
    s.base = @ptrFromInt(p);
    s.size = size;
    fresh.* = true;
    return s.base;
}

/// MSG_RUN: the reply is for pump; run in flight until busy() says no.
pub fn runSend(i: usize, nbind: u32, gx: u32, gy: u32, kern: u32) bool {
    return runSendN(i, nbind, gx, gy, kern, 0);
}

/// With the viewport's draws.
pub fn runSendN(i: usize, nbind: u32, gx: u32, gy: u32, kern: u32, ndraw: u32) bool {
    if (state != .up or run_out or fifo_n + 1 >= fifo.len) return false;
    var m = ipc.Msg{ .cmd = ipc.MSG_RUN, .slot = @intCast(i), .a = nbind, .b = gx, .c = gy, .d = kern };
    m.rest[0] = ndraw;
    if (!sendMsg(&m, -1)) return false;
    expect(.run);
    run_out = true;
    return true;
}

/// A run's end, waiting at most wait_ms: true when no run is out (done, or the
/// helper lost: isUp says which).
pub fn runWait(wait_ms: i32) bool {
    const t0 = nowMs();
    while (run_out and state == .up) {
        const left: i64 = wait_ms - (nowMs() - t0);
        pump(@intCast(std.math.clamp(left, 0, 50)));
        if (left <= 0) break;
    }
    return !run_out;
}

/// Leaving: the helper goes with us.
pub fn stop() void {
    if (pid != 0) {
        const m = ipc.Msg{ .cmd = ipc.MSG_QUIT };
        _ = sendMsg(&m, -1);
    }
    const quiet = told;
    told = true;
    if (state == .up or state == .starting) kill("leaving");
    told = quiet;
    if (reap_pid != 0) _ = spawn.waitFor(reap_pid, 2000, null);
    reap_pid = 0;
}

/// render.device <auto|rtx|gpu|cpu>: from a word.
pub fn parseDevice(w: []const u8) ?Device {
    return std.meta.stringToEnum(Device, w);
}
