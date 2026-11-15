// Worker threads (the original's jobs.s parallel_for): one per core, asleep
// on a futex until there is work. parallelFor splits a range into chunks the
// threads (and the caller) take in turn; it returns when all are done.
// Workers must not allocate through alloc.zig (it is not thread-safe) or
// touch the UI: they compute into memory the caller gave them.
const std = @import("std");
const linux = std.os.linux;

pub const Fn = *const fn (ctx: *anyopaque, lo: usize, hi: usize, thread: usize) void;

const MAX = 64;
var n_workers: usize = 0; // besides the caller
var threads: [MAX]std.Thread = undefined;

// the job (written by the caller before `gen` moves on)
var job_fn: Fn = undefined;
var job_ctx: *anyopaque = undefined;
var job_n: usize = 0;
var job_chunk: usize = 1;
var next = std.atomic.Value(usize).init(0);
var gen = std.atomic.Value(u32).init(0);
var busy = std.atomic.Value(u32).init(0);
var running = false;

fn wait(ptr: *const std.atomic.Value(u32), expected: u32) void {
    _ = linux.futex_4arg(&ptr.raw, .{ .cmd = .WAIT, .private = true }, expected, null);
}
fn wake(ptr: *const std.atomic.Value(u32), n: u32) void {
    _ = linux.futex_3arg(&ptr.raw, .{ .cmd = .WAKE, .private = true }, n);
}

/// Preferences > System: how many threads (0: one a CPU).
pub var want_threads: usize = 0;

/// Start the workers (once). Fewer cores, or none spawned: the caller works alone.
pub fn init() void {
    if (running) return;
    running = true;
    const cpus = if (want_threads > 0) want_threads else std.Thread.getCpuCount() catch 1;
    const extra = @min(@max(cpus, 1), MAX) - 1;
    var k: usize = 0;
    while (k < extra) : (k += 1) {
        threads[k] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, worker, .{k + 1}) catch break;
        n_workers += 1;
    }
}

/// Threads that run a parallelFor (the caller included).
pub fn count() usize {
    return n_workers + 1;
}

fn take(thread: usize) void {
    while (true) {
        const lo = next.fetchAdd(job_chunk, .acq_rel);
        if (lo >= job_n) return;
        job_fn(job_ctx, lo, @min(lo + job_chunk, job_n), thread);
    }
}

fn worker(id: usize) void {
    var seen: u32 = 0;
    while (true) {
        var g = gen.load(.acquire);
        while (g == seen) {
            wait(&gen, seen);
            g = gen.load(.acquire);
        }
        seen = g;
        take(id);
        if (busy.fetchSub(1, .acq_rel) == 1) wake(&busy, 1);
    }
}

/// Run f over [0, n) in chunks of `chunk`, on every thread; returns when done.
/// f gets the thread's number (0: the caller) for per-thread scratch.
pub fn parallelFor(n: usize, chunk: usize, ctx: *anyopaque, f: Fn) void {
    if (n == 0) return;
    if (n_workers == 0 or n <= chunk) {
        f(ctx, 0, n, 0);
        return;
    }
    job_fn = f;
    job_ctx = ctx;
    job_n = n;
    job_chunk = @max(chunk, 1);
    next.store(0, .release);
    busy.store(@intCast(n_workers), .release);
    _ = gen.fetchAdd(1, .acq_rel);
    wake(&gen, std.math.maxInt(i32));
    take(0);
    while (true) {
        const b = busy.load(.acquire);
        if (b == 0) break;
        wait(&busy, b);
    }
}

test "parallelFor covers every item once" {
    init();
    var hits: [10000]u8 = @splat(0);
    const C = struct {
        fn run(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
            const h: *[10000]u8 = @ptrCast(@alignCast(ctx));
            for (lo..hi) |i| h[i] += 1;
        }
    };
    for (0..50) |_| parallelFor(hits.len, 37, &hits, C.run);
    for (hits) |x| try std.testing.expectEqual(@as(u8, 50), x);
}
