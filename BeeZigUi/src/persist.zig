//! Saving and restoring the state a `Ui` keeps between frames: window
//! positions, sizes, collapse and scroll, z-order, open tree nodes and
//! headers, and scroll areas. Use it to carry the UI across a hot reload, or
//! to reopen an app the way the user left it.
//!
//! Popups, focus, hover and text being edited are not saved; they belong to
//! the moment. The format is a small versioned binary, little-endian, and
//! restoring checks every byte, so a damaged file fails cleanly.

const std = @import("std");
const draw = @import("draw.zig");
const window = @import("window.zig");
const containers = @import("containers.zig");
const ui_mod = @import("ui.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Allocator = std.mem.Allocator;

const magic = "ZUIS";
const version: u16 = 1;

/// Why saved state could not be restored.
pub const RestoreError = error{InvalidState} || Allocator.Error;

/// Returns the `Ui`'s persistent state as bytes owned by the caller.
pub fn saveState(ui: *const Ui, allocator: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, magic);
    try writeInt(&out, allocator, u16, version);

    // Windows back to front, so restoring in order rebuilds the z-order.
    var windows: u32 = 0;
    for (ui.window_order.items) |w| {
        if (!w.popup) windows += 1;
    }
    try writeInt(&out, allocator, u32, windows);
    for (ui.window_order.items) |w| {
        if (w.popup) continue;
        try writeInt(&out, allocator, u64, @intFromEnum(w.id));
        for ([_]f32{ w.rect.x, w.rect.y, w.rect.w, w.rect.h, w.scroll }) |v| try writeFloat(&out, allocator, v);
        try out.append(allocator, @intFromBool(w.collapsed));
    }

    try writeInt(&out, allocator, u32, ui.open_states.count());
    var opens = ui.open_states.iterator();
    while (opens.next()) |e| {
        try writeInt(&out, allocator, u64, @intFromEnum(e.key_ptr.*));
        try out.append(allocator, @intFromBool(e.value_ptr.*));
    }

    try writeInt(&out, allocator, u32, ui.scroll_states.count());
    var scrolls = ui.scroll_states.iterator();
    while (scrolls.next()) |e| {
        try writeInt(&out, allocator, u64, @intFromEnum(e.key_ptr.*));
        try writeFloat(&out, allocator, e.value_ptr.scroll);
        try writeFloat(&out, allocator, e.value_ptr.content_height);
    }
    return out.toOwnedSlice(allocator);
}

/// Applies state from `saveState`. Call it before the first frame of a new
/// `Ui`, or between frames. Nothing changes unless the whole of `bytes` is
/// valid.
pub fn restoreState(ui: *Ui, bytes: []const u8) RestoreError!void {
    // Check everything first, so a bad file can't leave half a state.
    var counts: Counts = .{};
    var check: Reader = .{ .bytes = bytes };
    try apply(ui, &check, .check, &counts);
    if (check.pos != bytes.len) return error.InvalidState;
    // Then make room for all of it, so running out of memory can't either:
    // window states made here are empty until the last pass fills them.
    try ui.open_states.ensureUnusedCapacity(ui.allocator, counts.opens);
    try ui.scroll_states.ensureUnusedCapacity(ui.allocator, counts.scrolls);
    var make: Reader = .{ .bytes = bytes };
    try apply(ui, &make, .make_windows, &counts);
    var reader: Reader = .{ .bytes = bytes };
    try apply(ui, &reader, .apply, &counts);
}

const Counts = struct { opens: u32 = 0, scrolls: u32 = 0 };
const Phase = enum { check, make_windows, apply };

/// Reads saved state: checks it, makes the windows it names, or applies it
/// (which then can't fail part way).
fn apply(ui: *Ui, r: *Reader, phase: Phase, counts: *Counts) RestoreError!void {
    if (!std.mem.eql(u8, try r.take(4), magic)) return error.InvalidState;
    if (try r.int(u16) != version) return error.InvalidState;

    const windows = try r.int(u32);
    for (0..windows) |_| {
        const id = try r.id();
        const rect: draw.Rect = .{ .x = try r.float(), .y = try r.float(), .w = try r.float(), .h = try r.float() };
        const scroll = try r.float();
        const collapsed = try r.boolean();
        if (rect.w < 0 or rect.h < 0 or scroll < 0) return error.InvalidState;
        switch (phase) {
            .check => {},
            .make_windows => _ = try window.getOrCreate(ui, id, .{}),
            .apply => {
                const w = ui.windows.get(id) orelse unreachable; // made by .make_windows
                w.rect = rect;
                w.scroll = scroll;
                w.collapsed = collapsed;
                window.raise(ui, w);
            },
        }
    }

    const opens = try r.int(u32);
    if (phase == .check) counts.opens = opens;
    for (0..opens) |_| {
        const id = try r.id();
        const open = try r.boolean();
        if (phase == .apply) ui.open_states.putAssumeCapacity(id, open);
    }

    const scrolls = try r.int(u32);
    if (phase == .check) counts.scrolls = scrolls;
    for (0..scrolls) |_| {
        const id = try r.id();
        const state: containers.ScrollState = .{ .scroll = try r.float(), .content_height = try r.float() };
        if (state.scroll < 0 or state.content_height < 0) return error.InvalidState;
        if (phase == .apply) ui.scroll_states.putAssumeCapacity(id, state);
    }
}

fn writeInt(out: *std.ArrayList(u8), allocator: Allocator, comptime T: type, value: T) Allocator.Error!void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try out.appendSlice(allocator, &buffer);
}

fn writeFloat(out: *std.ArrayList(u8), allocator: Allocator, value: f32) Allocator.Error!void {
    try writeInt(out, allocator, u32, @bitCast(value));
}

/// Bounds-checked reading of saved state.
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(r: *Reader, n: usize) RestoreError![]const u8 {
        if (r.bytes.len - r.pos < n) return error.InvalidState;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }

    fn int(r: *Reader, comptime T: type) RestoreError!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn float(r: *Reader) RestoreError!f32 {
        const v: f32 = @bitCast(try r.int(u32));
        if (!std.math.isFinite(v)) return error.InvalidState;
        return v;
    }

    fn boolean(r: *Reader) RestoreError!bool {
        return switch (try r.int(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidState,
        };
    }

    fn id(r: *Reader) RestoreError!Id {
        const v = try r.int(u64);
        if (v == 0) return error.InvalidState;
        return @enumFromInt(v);
    }
};
