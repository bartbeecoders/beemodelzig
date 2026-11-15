const std = @import("std");
const zui = @import("zui");
const sw = @import("zui_software");
const C = zui.Color;

fn run(cmdfn: anytype) !void {
    var r: sw.SoftwareRenderer = .init(std.testing.allocator);
    defer r.deinit();
    try r.resize(64, 64);
    var list: zui.DrawList = .init(std.testing.allocator);
    defer list.deinit();
    try cmdfn(&list);
    r.renderer().render(&list, .{ .width = 64, .height = 64 });
}

test "rect huge" {
    try run(struct { fn f(l: *zui.DrawList) !void { try l.addRect(.{ .rect = .{ .x = -1e10, .y = 0, .w = 2e10, .h = 10 }, .fill = C.white }); } }.f);
}
test "rect nan" {
    try run(struct { fn f(l: *zui.DrawList) !void { try l.addRect(.{ .rect = .{ .x = std.math.nan(f32), .y = 0, .w = 10, .h = 10 }, .fill = C.white }); } }.f);
}
test "rect huge radius border" {
    try run(struct { fn f(l: *zui.DrawList) !void { try l.addRect(.{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .fill = C.white, .border = C.black, .border_width = 1e10 }); } }.f);
}
test "shadow huge" {
    try run(struct { fn f(l: *zui.DrawList) !void { try l.addShadow(.{ .rect = .{ .x = -1e10, .y = 0, .w = 2e10, .h = 10 }, .color = C.black }); } }.f);
}
test "mesh far vertex" {
    try run(struct { fn f(l: *zui.DrawList) !void { try l.addMesh(.{ .vertices = &.{ .{ .pos = .{ .x = 0, .y = 0 }, .color = C.white }, .{ .pos = .{ .x = 3e9, .y = 0 }, .color = C.white }, .{ .pos = .{ .x = 0, .y = 30 }, .color = C.white } }, .indices = &.{ 0, 1, 2 } }); } }.f);
}
test "mesh 2e7 vertex (i64 overflow)" {
    try run(struct { fn f(l: *zui.DrawList) !void { try l.addMesh(.{ .vertices = &.{ .{ .pos = .{ .x = -2e7, .y = -2e7 }, .color = C.white }, .{ .pos = .{ .x = 2e7, .y = -1e7 }, .color = C.white }, .{ .pos = .{ .x = 10, .y = 3e7 }, .color = C.white } }, .indices = &.{ 0, 1, 2 } }); } }.f);
}
test "mesh nan vertex" {
    try run(struct { fn f(l: *zui.DrawList) !void { try l.addMesh(.{ .vertices = &.{ .{ .pos = .{ .x = std.math.nan(f32), .y = 0 }, .color = C.white }, .{ .pos = .{ .x = 30, .y = 0 }, .color = C.white }, .{ .pos = .{ .x = 0, .y = 30 }, .color = C.white } }, .indices = &.{ 0, 1, 2 } }); } }.f);
}
test "line far" {
    try run(struct { fn f(l: *zui.DrawList) !void { try l.addLine(.{ .x = 10, .y = 10 }, .{ .x = 5e7, .y = 3e7 }, C.white, 1); } }.f);
}
test "image huge rect" {
    try run(struct { fn f(l: *zui.DrawList) !void {
        const S = struct { var px = [_]u32{ 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF }; var img: zui.Image = undefined; };
        S.img = .initArgb(&S.px, 2, 2);
        try l.addImage(.{ .image = &S.img, .rect = .{ .x = -1e10, .y = 0, .w = 2e10, .h = 10 } }); } }.f);
}
test "text huge size" {
    var font: zui.Font = try .initDefault(std.testing.allocator);
    defer font.deinit();
    var r: sw.SoftwareRenderer = .init(std.testing.allocator);
    defer r.deinit();
    try r.resize(64, 64);
    var list: zui.DrawList = .init(std.testing.allocator);
    defer list.deinit();
    try list.addText(.{ .font = &font, .pos = .{ .x = 0, .y = 30 }, .size = 3000, .color = C.white, .text = "W" });
    r.renderer().render(&list, .{ .width = 64, .height = 64 });
    const g = try font.glyph('W', 3000, 0);
    std.debug.print("\n3000px W glyph: {d}x{d} = {d} KB cached per subpixel variant\n", .{ g.width, g.height, g.width * g.height / 1024 });
}
test "glyph cache growth under smooth zoom" {
    var font: zui.Font = try .initDefault(std.testing.allocator);
    defer font.deinit();
    var size: f32 = 8;
    while (size < 40) : (size *= 1.01) {
        for ("The quick brown fox 0123456789") |c| for (0..4) |sp| {
            _ = try font.glyph(c, size, @intCast(sp));
        };
    }
    std.debug.print("\nzoom 8->40px: {d} cache entries, arena {d} KB\n", .{ font.cache.count(), font.arena.queryCapacity() / 1024 });
}
test "dashed line stall" {
    var list: zui.DrawList = .init(std.testing.allocator);
    defer list.deinit();
    // total 4e7, dash 1 gap 0.5: once at >= 2^24 adding 1.5 can round to no progress? check quickly with bounded count
    var at: f32 = 16777216;
    const before = at;
    at += 1 + 0.5;
    at += 1 + 0.5;
    std.debug.print("\nf32 2^24 + 1.5 + 1.5 = {d} (from {d})\n", .{ at, before });
    var at2: f32 = 33554432;
    at2 += 1 + 0.5;
    std.debug.print("f32 2^25 + 1.5 = {d}  stalls={}\n", .{ at2, at2 == 33554432 });
}
test "icon atlas bleed" {
    var r: sw.SoftwareRenderer = .init(std.testing.allocator);
    defer r.deinit();
    try r.resize(20, 20);
    r.clear_color = C.black;
    var list: zui.DrawList = .init(std.testing.allocator);
    defer list.deinit();
    // Two 4x4 alpha cells side by side: cell 0 empty, cell 1 solid.
    var px: [8 * 4]u8 = undefined;
    for (0..4) |y| for (0..8) |x| {
        px[y * 8 + x] = if (x >= 4) 255 else 0;
    };
    const img: zui.Image = .initAlpha(&px, 8, 4);
    const set = zui.IconSet.grid(&img, 4, 4);
    try list.addImage(.{ .image = &img, .rect = .{ .x = 2, .y = 2, .w = 4, .h = 4 }, .uv = set.uv(0), .tint = C.white, .filter = .auto });
    r.renderer().render(&list, .{ .width = 16, .height = 16, .scale = 1.25 });
    var lit: u32 = 0;
    var maxv: u32 = 0;
    for (r.pixels) |p| if (p & 0xFF != 0) {
        lit += 1;
        maxv = @max(maxv, p & 0xFF);
    };
    std.debug.print("\nempty icon drawn at 1.25x: {d} lit pixels, max {d}\n", .{ lit, maxv });
}
