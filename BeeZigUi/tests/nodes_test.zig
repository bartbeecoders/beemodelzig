//! The node editor add-on: links, cuts, selection, moves, keys.

const std = @import("std");
const zui = @import("zui");
const nodes = @import("zui_nodes");
const testing = std.testing;

const N = struct { id: u64, pos: zui.Vec2, selected: bool = false, collapsed: bool = false };

const App = struct {
    editor: nodes.Editor,
    list: [3]N = .{
        .{ .id = 1, .pos = .{ .x = 0, .y = 0 } },
        .{ .id = 2, .pos = .{ .x = 300, .y = 0 } },
        .{ .id = 3, .pos = .{ .x = 600, .y = 200 } },
    },
    linked: bool = true,
    edits: std.ArrayList(nodes.Edit) = .empty,
    align_left: bool = false,
    distribute: bool = false,

    fn frame(app: *App, ui: *zui.Ui) void {
        var g = nodes.begin(ui, "graph", &app.editor, .{ .minimap = false });
        for (&app.list) |*n| {
            var node = g.beginNode(n.id, n.pos, .{ .title = if (n.id == 1) "A" else if (n.id == 2) "B" else "C", .selected = n.selected, .collapsed = n.collapsed });
            g.output(&node, n.id * 10 + 1, "Out", .{});
            _ = g.beginInput(&node, n.id * 10, "In", .{});
            g.endInput(&node);
            g.endNode(&node);
        }
        if (app.linked) g.link(99, 11, 20);
        if (app.align_left) g.alignSelected(.left);
        if (app.distribute) g.distributeSelected(.horizontal);
        app.align_left = false;
        app.distribute = false;
        for (g.end()) |e| {
            app.edits.append(testing.allocator, e) catch {};
            switch (e) {
                .move => |m| for (&app.list) |*n| {
                    if (n.id == m.node) n.pos = n.pos.add(m.delta);
                },
                .select => |s| for (&app.list) |*n| {
                    if (n.id == s.node) n.selected = s.selected;
                },
                .collapse => |id| for (&app.list) |*n| {
                    if (n.id == id) n.collapsed = !n.collapsed;
                },
                .unlink => app.linked = false,
                else => {},
            }
        }
    }

    fn count(app: *const App, tag: std.meta.Tag(nodes.Edit)) usize {
        var n: usize = 0;
        for (app.edits.items) |e| if (e == tag) {
            n += 1;
        };
        return n;
    }
};

const Fixture = struct {
    font: zui.Font,
    ui: zui.Ui,
    app: App,

    fn create() !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .font = try .initDefault(testing.allocator), .ui = undefined, .app = .{ .editor = .init(testing.allocator) } };
        f.ui = .init(testing.allocator, .{ .font = &f.font });
        f.ui.recording = true;
        return f;
    }

    fn destroy(f: *Fixture) void {
        f.app.editor.deinit();
        f.app.edits.deinit(testing.allocator);
        f.ui.deinit();
        f.font.deinit();
        testing.allocator.destroy(f);
    }

    fn frame(f: *Fixture) !void {
        f.ui.beginFrame(.{ .width = 1000, .height = 600, .dt = 0.016 });
        f.app.frame(&f.ui);
        _ = try f.ui.endFrame();
    }

    fn play(f: *Fixture, script: []const u8) !void {
        var player: zui.ScriptPlayer = try .init(testing.allocator, script);
        defer player.deinit();
        while (player.next(&f.ui) catch |err| {
            std.debug.print("{s}\n", .{player.message()});
            return err;
        }) |step| switch (step) {
            .frame => try f.frame(),
            .shot => {},
        };
    }

    fn press(f: *Fixture, at: zui.Vec2, mods: zui.Modifiers) !void {
        f.ui.input.onMouseMove(at);
        try f.frame();
        f.ui.input.modifiers = mods;
        f.ui.input.onMouseButton(.left, true);
        try f.frame();
    }

    fn release(f: *Fixture) !void {
        f.ui.input.onMouseButton(.left, false);
        try f.frame();
        f.ui.input.modifiers = .{};
        try f.frame();
    }
};

test "a click selects one node; dragging a selected node moves all selected" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\frames 4
        \\click node:A
        \\expect node:A = selected
        \\click node:B
        \\expect node:B = selected
        \\expect node:A =
    );
    f.app.list[0].selected = true;
    const a0 = f.app.list[0].pos;
    const c0 = f.app.list[2].pos;
    try f.play("drag node:B by 50 20");
    const moved = f.app.list[0].pos.sub(a0);
    try testing.expect(moved.x > 30);
    try testing.expectEqual(c0, f.app.list[2].pos);
    try testing.expect(f.app.count(.commit) >= 1);
}

test "Alt+click cuts a wire; the knife cuts what it crosses" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("frames 4");
    const w = f.ui.findWidget("link:Out -> In") orelse return error.NoLink;
    const mid: zui.Vec2 = .{ .x = w.rect.x + 4, .y = w.rect.y + 4 };
    try f.press(mid, .{ .alt = true });
    try f.release();
    try testing.expect(!f.app.linked);
    try testing.expectEqual(@as(usize, 1), f.app.count(.unlink));

    f.app.linked = true;
    try f.play("frames 3");
    try f.press(.{ .x = mid.x, .y = mid.y - 60 }, .{ .alt = true });
    f.ui.input.onMouseMove(.{ .x = mid.x + 5, .y = mid.y });
    try f.frame();
    f.ui.input.onMouseMove(.{ .x = mid.x + 10, .y = mid.y + 60 });
    try f.frame();
    try f.release();
    try testing.expect(!f.app.linked);
    try testing.expectEqual(@as(usize, 2), f.app.count(.unlink));
}

test "a box selects, Shift adds, Ctrl removes; a click on empty space clears" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play("frames 4");
    const a = f.ui.findWidget("node:A").?.rect;
    const b = f.ui.findWidget("node:B").?.rect;
    // From above-left of A to past B's header.
    try f.press(.{ .x = a.x - 10, .y = a.y - 10 }, .{});
    f.ui.input.onMouseMove(.{ .x = b.right() - 10, .y = b.y + 10 });
    try f.frame();
    try f.release();
    try testing.expect(f.app.list[0].selected and f.app.list[1].selected and !f.app.list[2].selected);
    const c = f.ui.findWidget("node:C").?.rect;
    try f.press(.{ .x = c.x - 10, .y = c.y - 10 }, .{ .shift = true });
    f.ui.input.onMouseMove(.{ .x = c.x + 20, .y = c.y + 10 });
    try f.frame();
    try f.release();
    try testing.expect(f.app.list[2].selected and f.app.list[0].selected);
    try f.press(.{ .x = a.x - 10, .y = a.y - 10 }, .{ .ctrl = true });
    f.ui.input.onMouseMove(.{ .x = a.x + 20, .y = a.y + 10 });
    try f.frame();
    try f.release();
    try testing.expect(!f.app.list[0].selected and f.app.list[1].selected);
    try f.press(.{ .x = a.x - 30, .y = a.bottom() + 120 }, .{});
    try f.release();
    for (f.app.list) |n| try testing.expect(!n.selected);
}

test "keys, folding, aligning and distributing" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.play(
        \\frames 4
        \\hover node:A
        \\key x
        \\key shift+d
        \\key ctrl+c
        \\key ctrl+v
        \\key shift+a
    );
    try testing.expectEqual(@as(usize, 1), f.app.count(.delete));
    try testing.expectEqual(@as(usize, 1), f.app.count(.duplicate));
    try testing.expectEqual(@as(usize, 1), f.app.count(.copy));
    try testing.expectEqual(@as(usize, 1), f.app.count(.paste));
    try testing.expectEqual(@as(usize, 1), f.app.count(.add));
    const a = f.ui.findWidget("node:A").?.rect;
    try f.press(.{ .x = a.x + 6, .y = a.y + a.h / 2 }, .{});
    try f.release();
    try testing.expect(f.app.list[0].collapsed);

    for (&f.app.list) |*n| n.selected = true;
    f.app.list[1].pos.y = 40;
    f.app.list[2].pos.x = 900;
    f.app.align_left = true;
    try f.frame();
    try testing.expectEqual(f.app.list[0].pos.x, f.app.list[2].pos.x);
    f.app.list[1].pos.x = 100;
    f.app.list[2].pos.x = 1000;
    f.app.distribute = true;
    try f.frame();
    // Equal gaps between the three.
    const w: f32 = 170;
    const gap1 = f.app.list[1].pos.x - (f.app.list[0].pos.x + w);
    const gap2 = f.app.list[2].pos.x - (f.app.list[1].pos.x + w);
    try testing.expectApproxEqAbs(gap1, gap2, 0.5);
}
