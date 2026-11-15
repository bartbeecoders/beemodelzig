const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");
const nodes = @import("zui_nodes");

const NodeScene = struct {
    editor: nodes.Editor,
    values: [count]f64 = @splat(0.5),
    const count = 200;
    fn frame(s: *NodeScene, ui: *zui.Ui) void {
        if (ui.frame_index == 1) {
            s.editor.view.zoom = .{ .x = 0.3, .y = 0.3 };
            s.editor.view.follow_fit = false;
        }
        var g = nodes.begin(ui, "graph", &s.editor, .{});
        for (0..count) |i| {
            const pos: zui.Vec2 = .{ .x = @as(f32, @floatFromInt(i % 20)) * 210, .y = @as(f32, @floatFromInt(i / 20)) * 200 };
            var node = g.beginNode(i, pos, .{ .title = "Mix Color", .color = zui.Color.hex(0x6E4A8F) });
            g.output(&node, i * 4 + 3, "Result", .{ .color = zui.Color.hex(0xC7C729) });
            if (g.beginInput(&node, i * 4, "Factor", .{ .value = true })) _ = ui.numberField("Factor", &s.values[i], .{ .width = .fill, .slider = true, .min = 0, .max = 1 });
            g.endInput(&node);
            _ = g.beginInput(&node, i * 4 + 1, "A", .{ .color = zui.Color.hex(0xC7C729) });
            g.endInput(&node);
            _ = g.beginInput(&node, i * 4 + 2, "B", .{ .color = zui.Color.hex(0xC7C729) });
            g.endInput(&node);
            g.endNode(&node);
        }
        for (1..count) |i| {
            g.link(i, (i - 1) * 4 + 3, i * 4 + 1);
            if (i % 2 == 0 and i >= 2) g.link(1000 + i, (i - 2) * 4 + 3, i * 4 + 2);
        }
        _ = g.end();
    }
};

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var font: zui.Font = try .initDefault(gpa);
    var ui: zui.Ui = .init(gpa, .{ .font = &font });
    var scene: NodeScene = .{ .editor = .init(gpa) };
    var sw: software.SoftwareRenderer = .init(gpa);
    try sw.resize(1280, 800);
    var list: *const zui.DrawList = undefined;
    for (0..30) |_| {
        ui.beginFrame(.{ .width = 1280, .height = 800 });
        scene.frame(&ui);
        list = try ui.endFrame();
    }
    var counts: std.EnumArray(std.meta.Tag(zui.Command), usize) = .initFill(0);
    var path_pts: usize = 0;
    for (list.commands.items) |c| {
        counts.getPtr(c).* += 1;
        if (c == .path) path_pts += c.path.len;
    }
    for (std.enums.values(std.meta.Tag(zui.Command))) |t| std.debug.print("{s}: {d}\n", .{ @tagName(t), counts.get(t) });
    std.debug.print("path points: {d}\n", .{path_pts});
    // Copy, drop one kind, time.
    var copy = zui.DrawList.init(gpa);
    try copy.text_bytes.appendSlice(gpa, list.text_bytes.items);
    try copy.points.appendSlice(gpa, list.points.items);
    try copy.mesh_vertices.appendSlice(gpa, list.mesh_vertices.items);
    try copy.indices.appendSlice(gpa, list.indices.items);
    for ([_]bool{ true, false }) |closed| {
        copy.commands.clearRetainingCapacity();
        var n: usize = 0;
        var pts: usize = 0;
        for (list.commands.items) |c| {
            if (c == .path and c.path.closed == closed) { n += 1; pts += c.path.len; continue; }
            try copy.commands.append(gpa, c);
        }
        var best: u64 = std.math.maxInt(u64);
        for (0..40) |_| {
            const t0 = nowNs();
            sw.renderer().render(&copy, .{ .width = 1280, .height = 800 });
            best = @min(best, nowNs() - t0);
        }
        std.debug.print("without closed={} paths ({d}, {d} pts): {d:.2} ms\n", .{ closed, n, pts, @as(f64, @floatFromInt(best)) / 1e6 });
    }
    const kinds = [_]?std.meta.Tag(zui.Command){ null, .shadow, .path, .text, .rect, .mesh };
    for (kinds) |drop| {
        copy.commands.clearRetainingCapacity();
        for (list.commands.items) |c| if (drop == null or c != drop.?) try copy.commands.append(gpa, c);
        // drop wide rects only? keep simple
        var best: u64 = std.math.maxInt(u64);
        for (0..40) |_| {
            const t0 = nowNs();
            sw.renderer().render(&copy, .{ .width = 1280, .height = 800 });
            best = @min(best, nowNs() - t0);
        }
        std.debug.print("without {s}: {d:.2} ms\n", .{ if (drop) |d| @tagName(d) else "(nothing)", @as(f64, @floatFromInt(best)) / 1e6 });
    }
}
