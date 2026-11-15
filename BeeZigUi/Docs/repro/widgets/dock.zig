const std = @import("std");
const zui = @import("zui");
const Dock = zui.Dock;
test "more areas than max_areas; move of a floating panel into a full dock orphans it" {
    var d: Dock = .init(0);
    const root: zui.AreaId = d.root;
    // 32 floating panels: split then float, each frees its split node.
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const a = d.split(root, .right, i + 1).?;
        try std.testing.expect(d.float(a, .{ .x = 0, .y = 0, .w = 100, .h = 100 }));
    }
    // Docked areas until the node table is full.
    var docked: u32 = 1;
    while (d.split(root, .right, 100 + docked)) |_| docked += 1;
    var buf: [Dock.max_areas]zui.AreaId = undefined;
    var real: usize = 0;
    for (d.nodes) |n| {
        if (n.kind == .area) real += 1;
    }
    std.debug.print("areas in nodes = {d}, areas() lists = {d}, docked = {d}\n", .{ real, d.areas(&buf).len, d.dockedCount() });
    // Now move the first floating panel next to the root.
    const panel = d.floating[0];
    const ok = d.move(panel, root, .left);
    std.debug.print("move ok={} panel floats={} kind={s} floating_count={d}\n", .{ ok, d.nodes[panel].floats, @tagName(d.nodes[panel].kind), d.floating_count });
    var out: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try d.write(&w);
    std.debug.print("re-read: {any}\n", .{if (Dock.read(w.buffered())) |_| "ok" else |e| @errorName(e)});
}
