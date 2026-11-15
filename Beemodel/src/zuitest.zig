// Tests of BeeModel's Zui host (zuihost.zig) and panel kit (bkit.zig).
// They need the zui modules, so they run through the build:
//   zig build test-ui
const std = @import("std");
const zui = @import("zui");
const host = @import("zuihost.zig");
const bkit = @import("bkit.zig");
const icons = @import("icons.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

fn begin(z: *zui.Ui) void {
    z.beginFrame(.{ .width = 480, .height = 360, .dt = 0.016 });
}

fn find(z: *zui.Ui, kind: zui.WidgetKind, label: []const u8) ?zui.Widget {
    for (z.widgets()) |w| if (w.kind == kind and std.mem.eql(u8, w.label, label)) return w;
    return null;
}

/// Runs frames until the layout settles (Zui sizes groups from the last frame).
fn settle(z: *zui.Ui, describe: *const fn (z: *zui.Ui) void) !void {
    for (0..3) |_| {
        begin(z);
        describe(z);
        _ = try z.endFrame();
    }
}

test "Zui widgets map to BeeModel's record kinds" {
    try expectEqualStrings("button", host.kindOf(.button).?);
    try expectEqualStrings("button", host.kindOf(.dropdown).?);
    try expectEqualStrings("checkbox", host.kindOf(.checkbox).?);
    try expectEqualStrings("number", host.kindOf(.number).?);
    try expectEqualStrings("text", host.kindOf(.text_input).?);
    try expectEqualStrings("menuitem", host.kindOf(.choice).?);
    try expectEqualStrings("menuitem", host.kindOf(.menu_item).?);
    try expectEqualStrings("colour", host.kindOf(.color_edit).?);
    try expectEqualStrings("section", host.kindOf(.header).?);
    try expectEqualStrings("fold", host.kindOf(.tree_node).?);
    // Zui's furniture stays out of BeeModel's record.
    try expectEqual(@as(?[]const u8, null), host.kindOf(.label));
    try expectEqual(@as(?[]const u8, null), host.kindOf(.tooltip));
    try expectEqual(@as(?[]const u8, null), host.kindOf(.scroll_area));
}

test "the icon atlas holds BeeModel's masks" {
    const ic = host.icon(.cube);
    const set = ic.bitmap.set;
    try expectEqual(@as(u32, 16), set.cell_width);
    try expect(set.count >= icons.masks.len);
    // Every pixel of the cube's cell is its 4-bit alpha times 17.
    const m = &icons.masks[@intFromEnum(icons.Icon.cube)];
    const idx: usize = @intFromEnum(icons.Icon.cube);
    const ox = (idx % set.columns) * 16;
    const oy = (idx / set.columns) * 16;
    var lit: usize = 0;
    for (0..16) |y| for (0..16) |x| {
        const b = m[y * 8 + x / 2];
        const a4: u8 = if (x % 2 == 0) b & 15 else b >> 4;
        try expectEqual(a4 * 17, set.image.pixels[(oy + y) * set.image.width + ox + x]);
        if (a4 != 0) lit += 1;
    };
    try expect(lit > 0);
}

test "typed values go through BeeModel's expressions" {
    try expectEqual(@as(?f64, 6), bkit.evaluator.eval("2*3"));
    try expectEqual(@as(?f64, 0.5), bkit.evaluator.eval("1/2"));
    try expectEqual(@as(?f64, null), bkit.evaluator.eval("2 +"));
}

var sec_open = true;
var snap = false;
var size: f64 = 1;
var ran = false;

fn panel(z: *zui.Ui) void {
    if (bkit.section(z, "Transform", &sec_open)) {
        _ = bkit.checkRow(z, "Snap", &snap, "Snap while moving");
        _ = bkit.numberRow(z, "Size", &size, .{ .min = 0, .max = 10, .tip = "How big" });
    }
    ran = bkit.opButton(z, "object.delete", .{}) or ran;
    _ = bkit.opButton(z, "no.such.operator", .{});
}

test "the panel kit records under BeeModel's kinds" {
    const z = host.get();
    sec_open = true;
    try settle(z, panel);
    try expect(find(z, .header, "Transform") != null);
    try expect(find(z, .checkbox, "Snap") != null);
    try expect(find(z, .number, "Size") != null);
    // The catalog's label; an unknown id shows nothing.
    const del = find(z, .button, "Delete") orelse return error.NoDeleteButton;
    try expectEqualStrings("button", host.kindOf(del.kind).?);
    var buttons: usize = 0;
    for (z.widgets()) |w| if (w.kind == .button) {
        buttons += 1;
    };
    try expectEqual(@as(usize, 1), buttons);

    // A closed section hides its rows.
    sec_open = false;
    try settle(z, panel);
    try expect(find(z, .checkbox, "Snap") == null);
    try expect(find(z, .header, "Transform") != null);
}

test "a click on a kit check box changes the app's value" {
    const z = host.get();
    sec_open = true;
    snap = false;
    try settle(z, panel);
    const w = find(z, .checkbox, "Snap") orelse return error.NoSnap;
    const p: zui.Vec2 = .{ .x = w.rect.x + 6, .y = w.rect.y + w.rect.h / 2 };
    z.input.onMouseMove(p);
    z.input.onMouseButton(.left, true);
    try settle(z, panel);
    z.input.onMouseButton(.left, false);
    try settle(z, panel);
    try expect(snap);
}

var field_buf: [32]u8 = undefined;
var field_len: usize = 0;
var pick: usize = 1;

fn fields(z: *zui.Ui) void {
    _ = z.textInput("##Find", &field_buf, &field_len, .{ .hint = "Find" });
    _ = z.dropdown("##Keymap", &pick, &.{ .{ .label = "BeeModel" }, .{ .label = "Blender 4.x" } }, .{});
}

test "the record names a text field by its text, a drop-down by its choice" {
    const z = host.get();
    field_len = 0;
    try settle(z, fields);
    const empty = for (z.widgets()) |w| {
        if (w.kind == .text_input) break w;
    } else return error.NoField;
    try expectEqualStrings("Find", host.labelOf(empty));
    @memcpy(field_buf[0..5], "Props");
    field_len = 5;
    try settle(z, fields);
    for (z.widgets()) |w| switch (w.kind) {
        .text_input => try expectEqualStrings("Props", host.labelOf(w)),
        .dropdown => try expectEqualStrings("Blender 4.x", host.labelOf(w)),
        else => {},
    };
}
