// beemodel --selftest (selftest.s): the job system first, as the original, with
// its small serial against parallel benchmark, then what the port's safety
// rests on: scenes through the file format, atomic writes, PNG. The original's
// arena and pool checks have no counterpart here (the port has neither), its
// field JIT and SipHash neither (not ported yet). Used by CI: exit code 1 on a
// failure.
const std = @import("std");
const linux = std.os.linux;
const jobs = @import("jobs.zig");
const bee = @import("bee.zig");
const scene = @import("scene.zig");
const png = @import("png.zig");
const prims = @import("prims.zig");

const A = std.heap.page_allocator;
const BENCH_N = 8_000_000;
const PS_N = 4096;

var fails: u32 = 0;
var line_buf: [256]u8 = undefined;

fn out(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&line_buf, fmt, args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn check(ok: bool, label: []const u8) void {
    if (!ok) fails += 1;
    out("{s}{s}\n", .{ if (ok) "  ok   " else "  FAIL ", label });
}

fn nowUs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

/// A little real work per element, as the original's.
fn hash(i: u32) u32 {
    var x = i;
    for (0..24) |_| x = std.math.rotl(u32, (x *% 0x2c1b3c6d) ^ 0x297a2d39, 7);
    return x;
}

var arr: []u32 = &.{};
var seen_threads = std.atomic.Value(u64).init(0);

fn fill(_: *anyopaque, lo: usize, hi: usize, th: usize) void {
    _ = seen_threads.fetchOr(@as(u64, 1) << @intCast(th & 63), .monotonic);
    for (lo..hi) |i| arr[i] = hash(@intCast(i));
}

fn bump(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (arr[lo..hi]) |*x| _ = @atomicRmw(u32, x, .Add, 1, .monotonic);
}

/// 3000 calls in a row, their count and chunk changing each time: every element
/// run exactly once in each (a worker late from one call must not run the next's
/// twice).
fn stress() bool {
    const grains = [4]usize{ 1, 256, 16, 3 };
    var dummy: u32 = 0;
    @memset(arr[0..PS_N], 0);
    for (0..3000) |r| {
        const n = 1000 + (r % 7) * 400;
        jobs.parallelFor(n, grains[r & 3], &dummy, bump);
    }
    for (0..3400) |i| {
        var want: u32 = 0;
        for (0..7) |c| {
            if (i < 1000 + c * 400) want += @intCast((3000 - c + 6) / 7);
        }
        if (arr[i] != want) return false;
    }
    return true;
}

fn jobSystem() void {
    arr = A.alloc(u32, BENCH_N) catch {
        check(false, "memory for the test");
        return;
    };
    defer A.free(arr);
    const t0 = nowUs();
    for (0..BENCH_N) |i| arr[i] = hash(@intCast(i));
    const serial = nowUs() - t0;
    @memset(arr, 0xdeadbeef);
    seen_threads.store(0, .monotonic);
    const t1 = nowUs();
    var dummy: u32 = 0;
    jobs.parallelFor(BENCH_N, 16384, &dummy, fill);
    const par = nowUs() - t1;
    var ok = true;
    for (arr, 0..) |x, i| {
        if (x != hash(@intCast(i))) {
            ok = false;
            break;
        }
    }
    check(ok, "parallel_for: every element written exactly once");
    const ran = @popCount(seen_threads.load(.monotonic));
    check(jobs.count() == 1 or ran >= 2, "parallel_for: work spread over worker threads");
    check(stress(), "parallel_for: 3000 calls back to back, the grain changing - every element run once each time");
    out("  workers: {d} | threads that ran chunks: {d}\n", .{ jobs.count() - 1, ran });
    const sp = @as(f32, @floatFromInt(serial)) / @as(f32, @floatFromInt(@max(par, 1)));
    out("  bench (8M elements): serial {d:.1} ms, parallel {d:.1} ms, speed-up x{d:.1}\n", .{ @as(f32, @floatFromInt(serial)) / 1000, @as(f32, @floatFromInt(par)) / 1000, sp });
}

fn fileFormat() void {
    const data = bee.encode(null) catch {
        check(false, ".bee: the scene encodes");
        return;
    };
    defer A.free(data);
    check(bee.wellFormed(data), ".bee: the chunks walk to the last byte");
    // cut anywhere, it is no longer whole: what recovery and saving rely on
    var cuts_seen = true;
    var k: usize = 1;
    while (k < data.len) : (k += @max(data.len / 97, 1)) {
        if (bee.wellFormed(data[0 .. data.len - k])) cuts_seen = false;
    }
    check(cuts_seen, ".bee: a cut file is told from a whole one");
    const bad = A.dupe(u8, data) catch return;
    defer A.free(bad);
    bad[12] ^= 0xff; // the first chunk's size
    check(!bee.wellFormed(bad), ".bee: a damaged chunk size is told too");
}

fn atomicWrite() void {
    var pb: [80]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pb, "/tmp/beemodel-selftest-{d}", .{linux.getpid()}, 0) catch return;
    defer _ = linux.unlink(p);
    var ok = true;
    for ([_][]const u8{ "first", "second, longer", "3" }) |s| {
        bee.writeAtomic(p, s) catch {
            ok = false;
        };
        const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) {
            ok = false;
            continue;
        }
        var b: [32]u8 = undefined;
        const n = linux.read(@intCast(rc), &b, b.len);
        _ = linux.close(@intCast(rc));
        ok = ok and std.mem.eql(u8, b[0..n], s);
    }
    check(ok, "atomic writes: each write replaces the file whole");
}

fn pngFile() void {
    var px: [16 * 9]u32 = undefined;
    for (&px, 0..) |*p, i| p.* = @truncate(hash(@intCast(i)) & 0xffffff);
    const f = png.encode(A, 16, 9, &px) catch {
        check(false, "PNG: encodes");
        return;
    };
    defer A.free(f);
    const img = @import("image.zig").decodeData(A, f) catch {
        check(false, "PNG: decodes back");
        return;
    };
    defer A.free(img.px);
    var same = img.w == 16 and img.h == 9;
    if (same) {
        for (0..16 * 9) |i| {
            const p = px[i];
            const q = img.px[i];
            for (0..3) |c| {
                const want: u8 = @truncate(p >> @intCast(16 - c * 8));
                same = same and @as(u8, @intFromFloat(@round(q[c] * 255))) == want;
            }
        }
    }
    check(same, "PNG: a picture decodes back the same");
}

fn primitives() void {
    var c = prims.cone() catch return check(false, "primitives");
    defer c.deinit();
    var t = prims.torus() catch return check(false, "primitives");
    defer t.deinit();
    var g = prims.grid(20) catch return check(false, "primitives");
    defer g.deinit();
    check(c.v.items.len == 33 and t.v.items.len == 576 and g.v.items.len == 441, "primitives: the original's sizes");
}

/// The exit code.
pub fn run() u8 {
    out("BeeModel self-test\n", .{});
    jobSystem();
    fileFormat();
    atomicWrite();
    pngFile();
    primitives();
    out("{s}", .{if (fails == 0) "all self-tests passed\n" else "self-test FAILED\n"});
    return if (fails == 0) 0 else 1;
}
