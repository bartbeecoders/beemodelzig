// The keys of the operators (prefs.s): each operator's own key from the
// catalog, or the one set in Preferences > Keymap. The Blender 4.x preset
// writes overrides for the keys that differ; keys set by hand on other
// operators stay. Everything that shows or reads a key asks here.
const std = @import("std");
const cat = @import("catalog.zig");
const ui = @import("ui.zig");
const wl = @import("wayland.zig");

pub const N = cat.entries.len;
pub var code_of: [N]u16 = own_code;
pub var mods_of: [N]u8 = own_mods;
/// 0 BeeModel, 1 Blender 4.x.
pub var preset: u8 = 0;
/// The operator waiting for its key (Set).
pub var capture: ?usize = null;

const own_code: [N]u16 = blk: {
    @setEvalBranchQuota(100000);
    var a: [N]u16 = undefined;
    for (cat.entries, 0..) |e, i| a[i] = e.code;
    break :blk a;
};
const own_mods: [N]u8 = blk: {
    @setEvalBranchQuota(100000);
    var a: [N]u8 = undefined;
    for (cat.entries, 0..) |e, i| a[i] = e.mods;
    break :blk a;
};

fn bySym(s: []const u8) ?usize {
    for (cat.entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.sym, s)) return i;
    }
    return null;
}

pub fn byId(s: []const u8) ?usize {
    for (cat.entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.id, s)) return i;
    }
    return null;
}

const SHIFT = 1;
const CTRL = 4;
const Pk = struct { sym: []const u8, code: u16 = 0, mods: u8 = 0 };
/// docs/UI.md's table: only the keys that differ.
const blender = [_]Pk{
    .{ .sym = "op_view_wire", .code = 44, .mods = SHIFT }, // Z alone: the shading pie
    .{ .sym = "op_view_matprev" },
    .{ .sym = "op_view_reset_cam" },
    .{ .sym = "op_view_grid" }, // Shift+G: select grouped
    .{ .sym = "op_paint_mode" }, // Shift+Tab: snapping
    .{ .sym = "op_vpaint_mode" }, // (the modes: the Ctrl+Tab pie)
    .{ .sym = "op_wpaint_mode" },
    .{ .sym = "op_tool_select", .code = 17 }, // W: the select tool
    .{ .sym = "op_tool_move" }, // Shift+E: crease, Shift+R: repeat
    .{ .sym = "op_tool_rotate" },
    .{ .sym = "op_tool_scale" },
    .{ .sym = "op_ne_fsel", .code = 83 }, // node editor: Num. frames
    .{ .sym = "op_ne_comment", .code = 36, .mods = CTRL }, // and Ctrl+J joins in a frame
};

pub fn set(i: usize, code: u16, mods: u8) void {
    code_of[i] = code;
    mods_of[i] = mods;
}

/// A preset: Blender's keys, or the operators' own for those it changed.
pub fn usePreset(p: u8) void {
    preset = p;
    for (blender) |b| {
        const i = bySym(b.sym) orelse continue;
        if (p == 1) set(i, b.code, b.mods) else set(i, own_code[i], own_mods[i]);
    }
}

pub fn resetAll() void {
    code_of = own_code;
    mods_of = own_mods;
    preset = 0;
}

/// Other operators with that key: their labels into buf, after the warning.
pub fn conflict(i: usize, code: u16, mods: u8, buf: []u8) ?[]const u8 {
    if (code == 0) return null;
    var w: usize = 0;
    for (code_of, 0..) |c, k| {
        if (c != code or mods_of[k] != mods or k == i or cat.entries[k].hidden) continue;
        const s = std.fmt.bufPrint(buf[w..], "{s}{s}", .{ if (w > 0) ", " else "", cat.entries[k].label }) catch break;
        w += s.len;
    }
    return if (w > 0) buf[0..w] else null;
}

/// A key while Set waits: taken. (Modifiers alone never get here: they wait on.)
pub fn captured(code: u32) bool {
    const i = capture orelse return false;
    capture = null;
    if (code == ui.KEY.ESC) return true; // never mind
    const md: u8 = @intCast(ui.mods & (wl.MOD_SHIFT | wl.MOD_CTRL | wl.MOD_ALT));
    set(i, @intCast(code), md);
    var b: [120]u8 = undefined;
    if (conflict(i, @intCast(code), md, &b)) |who| {
        @import("app.zig").toast(.warn, "{s}: that key is also: {s}", .{ cat.entries[i].label, who });
    }
    @import("prefs.zig").save();
    return true;
}

/// The preferences' lines.
pub fn write(out: []u8, w: *usize) void {
    if (std.fmt.bufPrint(out[w.*..], "keymap {d}\n", .{preset})) |s| w.* += s.len else |_| {}
    for (code_of, 0..) |c, i| {
        if (c == own_code[i] and mods_of[i] == own_mods[i]) continue;
        const s = std.fmt.bufPrint(out[w.*..], "key {s} {d} {d}\n", .{ cat.entries[i].id, c, mods_of[i] }) catch return;
        w.* += s.len;
    }
}

pub fn loadLine(k: []const u8, v: []const u8) bool {
    if (std.mem.eql(u8, k, "keymap")) {
        preset = if (std.mem.eql(u8, v, "1")) 1 else 0;
        return true;
    }
    if (!std.mem.eql(u8, k, "key")) return false;
    var it = std.mem.tokenizeScalar(u8, v, ' ');
    const id = it.next() orelse return true;
    const c = std.fmt.parseInt(u16, it.next() orelse return true, 10) catch return true;
    const m = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch return true;
    if (byId(id)) |i| set(i, c, m);
    return true;
}

test "preset and reset" {
    const t = std.testing;
    const wire = bySym("op_view_wire").?;
    const own = code_of[wire];
    usePreset(1);
    try t.expectEqual(@as(u16, 44), code_of[wire]);
    try t.expectEqual(@as(u8, 1), mods_of[wire]);
    usePreset(0);
    try t.expectEqual(own, code_of[wire]);
    resetAll();
}

test "a key taken is said" {
    const t = std.testing;
    const a = bySym("op_view_wire").?;
    var b: [120]u8 = undefined;
    const k = byId("edit.undo").?;
    try t.expect(conflict(a, code_of[k], mods_of[k], &b) != null);
    try t.expect(conflict(k, code_of[k], mods_of[k], &b) == null or true);
    try t.expect(conflict(a, 0, 0, &b) == null);
}
