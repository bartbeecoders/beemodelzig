//! The allocator for many small blocks (mesh editing, per-mesh data): the
//! page allocator would map at least a page per block.
//!
//! It is not thread safe: only the main thread may allocate or free through
//! it (job callbacks work in memory prepared before parallelFor). Debug builds
//! check both: the allocator's own safety (double frees, wrong sizes) and that
//! every call comes from the thread that made the first one.
const std = @import("std");
const builtin = @import("builtin");

const debug = builtin.mode == .debug;

var gpa: std.heap.DebugAllocator(.{
    .safety = debug,
    .thread_safe = false,
    .stack_trace_frames = 0,
}) = .init;

pub const A: std.mem.Allocator = if (debug) .{ .ptr = undefined, .vtable = &checked } else gpa.allocator();

// ---- debug: the main thread only -------------------------------------------------------

var owner = std.atomic.Value(u64).init(0);

fn mainOnly() void {
    const me: u64 = @intCast(std.Thread.getCurrentId());
    const was = owner.cmpxchgStrong(0, me, .monotonic, .monotonic) orelse return;
    if (was != me) std.debug.panic("alloc.A used from thread {d} (main thread {d}): not thread safe", .{ me, was });
}

const checked: std.mem.Allocator.VTable = .{ .alloc = cAlloc, .resize = cResize, .remap = cRemap, .free = cFree };

fn cAlloc(_: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
    mainOnly();
    const g = gpa.allocator();
    return g.vtable.alloc(g.ptr, len, al, ra);
}
fn cResize(_: *anyopaque, mem: []u8, al: std.mem.Alignment, n: usize, ra: usize) bool {
    mainOnly();
    const g = gpa.allocator();
    return g.vtable.resize(g.ptr, mem, al, n, ra);
}
fn cRemap(_: *anyopaque, mem: []u8, al: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
    mainOnly();
    const g = gpa.allocator();
    return g.vtable.remap(g.ptr, mem, al, n, ra);
}
fn cFree(_: *anyopaque, mem: []u8, al: std.mem.Alignment, ra: usize) void {
    mainOnly();
    const g = gpa.allocator();
    g.vtable.free(g.ptr, mem, al, ra);
}

test "the checked allocator allocates, grows and frees on one thread" {
    const p = try A.alloc(u8, 100);
    const q = try A.realloc(p, 5000);
    A.free(q);
}
