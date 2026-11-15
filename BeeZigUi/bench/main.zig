//! Frame-time benchmark. Describes a busy UI many times, headless, and reports
//! how long the UI pass (describe + `endFrame`) and the software render take,
//! and how many allocations the measured frames made.
//!
//!     zig build bench                 # 1000 frames at 1280x800
//!     zig build bench -- 5000 1920 1080
//!     zig build bench -- 1000 1280 800 record   # with the widget record on
//!     zig build bench -- 1000 1280 800 nodes    # a 200-node graph instead

const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");
const nodes = @import("zui_nodes");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const frames = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 1000;
    const width: u32 = if (args.len > 2) try std.fmt.parseInt(u32, args[2], 10) else 1280;
    const height: u32 = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 800;
    const io = init.io;

    // Counts every allocation the Ui and renderer make.
    var counting: std.testing.FailingAllocator = .init(init.gpa, .{});
    const gpa = counting.allocator();

    var font: zui.Font = try .initDefault(gpa);
    defer font.deinit();
    var ui: zui.Ui = .init(gpa, .{ .font = &font });
    defer ui.deinit();
    // A fourth argument "record" keeps the widget record, as tests and
    // agents would.
    ui.recording = args.len > 4 and std.mem.eql(u8, args[4], "record");
    const node_mode = args.len > 4 and std.mem.eql(u8, args[4], "nodes");
    var graph: NodeScene = .{ .editor = .init(gpa) };
    defer graph.editor.deinit();
    var sw: software.SoftwareRenderer = .init(gpa);
    defer sw.deinit();
    try sw.resize(width, height);

    var scene: Scene = .{};
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);

    const ui_times = try init.arena.allocator().alloc(u64, frames);
    const render_times = try init.arena.allocator().alloc(u64, frames);
    var commands: usize = 0;
    var allocations_before: usize = 0;

    // A few frames to settle layout and warm the glyph cache, then measure.
    const warmup = 20;
    for (0..warmup + frames) |i| {
        if (i == warmup) allocations_before = counting.allocations;
        // Move the pointer around so hover states change, like real use.
        const t: f32 = @floatFromInt(i % 200);
        ui.input.onMouseMove(.{ .x = 40 + t * 4, .y = 60 + t * 2.5 });

        const start = now(io);
        ui.beginFrame(.{ .width = w, .height = h });
        if (node_mode) graph.frame(&ui) else scene.frame(&ui);
        const list = try ui.endFrame();
        const mid = now(io);
        sw.renderer().render(list, .{ .width = w, .height = h });
        const end = now(io);

        if (i >= warmup) {
            ui_times[i - warmup] = mid - start;
            render_times[i - warmup] = end - mid;
            commands = list.commands.items.len;
        }
    }
    const allocations = counting.allocations - allocations_before;

    const shown = if (node_mode) NodeScene.count else scene.widgets;
    std.debug.print("{d} frames at {d}x{d}, {d} {s}, {d} draw commands per frame\n\n", .{ frames, width, height, shown, if (node_mode) "nodes" else "widgets", commands });
    report("UI (describe + endFrame)", ui_times);
    report("Software render", render_times);
    std.debug.print("\nAllocations during measured frames: {d}\n", .{allocations});
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn report(name: []const u8, times: []u64) void {
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    var total: u64 = 0;
    for (times) |t| total += t;
    const us = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1000;
        }
    }.f;
    std.debug.print("{s:<26} mean {d:>8.1} us   median {d:>8.1} us   p99 {d:>8.1} us   max {d:>8.1} us\n", .{
        name,
        us(total / times.len),
        us(times[times.len / 2]),
        us(times[times.len * 99 / 100]),
        us(times[times.len - 1]),
    });
}

/// About three hundred widgets across the root and two windows, plus an open
/// popup: busier than most tool UIs.
const Scene = struct {
    values: [64]f32 = @splat(0.5),
    counts: [64]i32 = @splat(3),
    flags: [64]bool = @splat(true),
    text: [64]u8 = "Benchmark text field".* ++ @as([44]u8, @splat(0)),
    text_len: usize = 20,
    color: zui.Color = zui.Color.hex(0x4E8FE0),
    widgets: usize = 0,

    fn frame(s: *Scene, ui: *zui.Ui) void {
        s.widgets = 0;
        if (ui.frame_index == 1) ui.openPopup("popup");
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start });
        for (0..3) |column| {
            ui.pushIdInt(column);
            defer ui.popId();
            ui.beginVertical(.{ .width = .fill });
            for (0..20) |row| {
                const i = column * 20 + row;
                ui.pushIdInt(row);
                defer ui.popId();
                ui.beginHorizontal(.{});
                ui.labelf("Row {d}", .{i}, .{});
                _ = ui.button("Press", .{});
                _ = ui.checkbox("##flag", &s.flags[i], .{});
                ui.endHorizontal();
                s.widgets += 3;
            }
            ui.endVertical();
        }
        ui.endHorizontal();

        for (0..2) |n| {
            ui.pushIdInt(n);
            defer ui.popId();
            if (ui.beginWindow("Window##bench", .{ .position = .{ .x = 300 + @as(f32, @floatFromInt(n)) * 420, .y = 120 }, .size = .{ .x = 400, .y = 500 } })) {
                defer ui.endWindow();
                for (0..30) |row| {
                    const i = n * 30 + row;
                    ui.pushIdInt(row);
                    defer ui.popId();
                    _ = ui.slider("Float", &s.values[i], 0, 1, .{});
                    _ = ui.slider("Int", &s.counts[i], 0, 10, .{});
                    s.widgets += 2;
                }
                _ = ui.textInput("Text", &s.text, &s.text_len, .{});
                _ = ui.colorEdit("Color", &s.color, .{});
                s.widgets += 2;
            }
        }
        if (ui.beginPopup("popup", .{})) {
            defer ui.endPopup();
            ui.label("An open popup", .{});
            _ = ui.button("In the popup", .{});
            s.widgets += 2;
        }
    }
};

/// Two hundred nodes with a field each and three hundred wires, zoomed out
/// so every one is in view: a big material.
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
