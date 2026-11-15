const std = @import("std");
const zui = @import("zui");
const sw1 = @import("zui_software");
const sw2 = @import("sw2");
const C = zui.Color;

var g_io: std.Io = undefined;
fn now() u64 {
    return @intCast(std.Io.Clock.awake.now(g_io).nanoseconds);
}

fn bench(name: []const u8, list: *zui.DrawList, a: anytype, b: anytype, iters: usize, scale: f32) void {
    const f: zui.Frame = .{ .width = 1280 / scale, .height = 800 / scale, .scale = scale };
    var t: [2]u64 = .{ 0, 0 };
    for (0..iters) |_| {
        // clear outside the timed region
        @memset(a.pixels, 0xFF202226);
        var s = now();
        a.renderer().render(list, f);
        t[0] += now() - s;
        @memset(b.pixels, 0xFF202226);
        s = now();
        b.renderer().render(list, f);
        t[1] += now() - s;
    }
    var diff: u32 = 0;
    var maxd: u32 = 0;
    for (a.pixels, b.pixels) |p, q| {
        if (p != q) diff += 1;
        inline for (.{ 0, 8, 16 }) |sh| {
            const x: i32 = @intCast((p >> sh) & 0xFF);
            const y: i32 = @intCast((q >> sh) & 0xFF);
            maxd = @max(maxd, @abs(x - y));
        }
    }
    std.debug.print("{s:<34} orig {d:>8.1} us   new {d:>8.1} us   ({d:.2}x)  diff px {d} max {d}\n", .{ name, @as(f64, @floatFromInt(t[0] / iters)) / 1000, @as(f64, @floatFromInt(t[1] / iters)) / 1000, @as(f64, @floatFromInt(t[0])) / @as(f64, @floatFromInt(t[1])), diff, maxd });
}

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    const gpa = init.gpa;
    var a: sw1.SoftwareRenderer = .init(gpa);
    defer a.deinit();
    try a.resize(1280, 800);
    a.clear = false;
    var b: sw2.SoftwareRenderer = .init(gpa);
    defer b.deinit();
    try b.resize(1280, 800);
    b.clear = false;
    var list: zui.DrawList = .init(gpa);
    defer list.deinit();
    const iters = 200;

    for ([_]f32{ 1, 1.25 }) |sc| {
        std.debug.print("--- scale {d}\n", .{sc});
        const W = 1280 / sc;
        const H = 800 / sc;
        list.clear();
        try list.addRect(.{ .rect = .{ .w = W, .h = H }, .fill = C.black.withAlpha(110) });
        bench("fullscreen backdrop a=110", &list, &a, &b, iters, sc);
        list.clear();
        try list.addRect(.{ .rect = .{ .w = W, .h = H }, .fill = C.hex(0x303030) });
        bench("fullscreen opaque", &list, &a, &b, iters, sc);
        list.clear();
        const dlg: zui.Rect = .{ .x = 390, .y = 250, .w = 500, .h = 300 };
        try list.addShadow(.{ .rect = .{ .x = dlg.x, .y = dlg.y + 4, .w = dlg.w, .h = dlg.h }, .radius = 8, .blur = 14, .color = C.black.withAlpha(110), .covered = dlg.inset(8) });
        bench("dialog shadow 500x300", &list, &a, &b, iters, sc);
        list.clear();
        try list.addRect(.{ .rect = .{ .x = 300, .y = 120, .w = 400, .h = 500 }, .fill = C.hex(0x303030), .radius = 8 });
        bench("rect 400x500 r8", &list, &a, &b, iters, sc);
        list.clear();
        try list.addRect(.{ .rect = .{ .x = 300, .y = 120, .w = 400, .h = 500 }, .border = C.hex(0x505050), .border_width = 1, .radius = 8 });
        bench("outline 400x500 r8 b1", &list, &a, &b, iters, sc);
        list.clear();
        for (0..40) |i| try list.addRect(.{ .rect = .{ .x = 20 + @as(f32, @floatFromInt(i % 4)) * 210, .y = 20 + @as(f32, @floatFromInt(i / 4)) * 35, .w = 200, .h = 29 }, .fill = C.hex(0x404040), .border = C.hex(0x606060), .border_width = 1, .radius = 5 });
        bench("40 buttons 200x29 r5 b1", &list, &a, &b, iters, sc);
        list.clear();
        for (0..20) |i| {
            const y = 40 + @as(f32, @floatFromInt(i)) * 30;
            try list.addBezier(.{ .x = 50, .y = y }, .{ .x = 400, .y = y }, .{ .x = 600, .y = 700 - y }, .{ .x = 1000, .y = 700 - y }, C.hex(0xC0C0C0).withAlpha(200), 1.5);
        }
        bench("20 bezier wires w1.5", &list, &a, &b, iters, sc);
        {
            var tess: zui.tessellate.Tessellator = .init(gpa);
            defer tess.deinit();
            var tris: usize = 0;
            var area: f64 = 0;
            const s0 = now();
            for (0..iters) |_| {
                tris = 0;
                for (list.commands.items) |cmd| {
                    const p = cmd.path;
                    try tess.path(.{ .points = list.points.items[p.start..][0..p.len], .color = p.color, .width = p.width }, sc);
                    tris += tess.triangles.items.len / 3;
                    var i: usize = 0;
                    while (i < tess.triangles.items.len) : (i += 3) {
                        const t = tess.triangles.items[i..][0..3];
                        area += @abs((t[1].x - t[0].x) * (t[2].y - t[0].y) - (t[2].x - t[0].x) * (t[1].y - t[0].y)) / 2;
                    }
                }
            }
            std.debug.print("   tessellate only: {d:.1} us, {d} triangles, {d:.0} px area\n", .{ @as(f64, @floatFromInt((now() - s0) / iters)) / 1000, tris, area / iters });
        }
        list.clear();
        try list.addGradient(.{ .x = 100, .y = 100, .w = 500, .h = 500 }, C.hex(0xFF0000), C.hex(0x00FF00), C.hex(0x0000FF), C.hex(0xFFFFFF));
        bench("gradient mesh 500x500", &list, &a, &b, iters, sc);
        list.clear();
        try list.addGradient(.{ .x = 100, .y = 100, .w = 500, .h = 500 }, C.hex(0xFF0000), C.hex(0xFF0000).withAlpha(0), C.hex(0xFF0000), C.hex(0xFF0000).withAlpha(0));
        bench("alpha-only mesh 500x500", &list, &a, &b, iters, sc);
        list.clear();
        try list.addMesh(.{ .vertices = &.{ .{ .pos = .{ .x = 100, .y = 100 }, .color = C.hex(0xFF0000).withAlpha(128) }, .{ .pos = .{ .x = 600, .y = 100 }, .color = C.hex(0xFF0000).withAlpha(128) }, .{ .pos = .{ .x = 600, .y = 600 }, .color = C.hex(0xFF0000).withAlpha(128) }, .{ .pos = .{ .x = 100, .y = 600 }, .color = C.hex(0xFF0000).withAlpha(128) } }, .indices = &.{ 0, 1, 2, 0, 2, 3 } });
        bench("flat translucent mesh 500x500", &list, &a, &b, iters, sc);
        list.clear();
        var wang_n: u32 = 0;
        for (0..20) |i| {
            const y = 40 + @as(f32, @floatFromInt(i)) * 30;
            const P = [4]zui.Vec2{ .{ .x = 50, .y = y }, .{ .x = 400, .y = y }, .{ .x = 600, .y = 700 - y }, .{ .x = 1000, .y = 700 - y } };
            // Wang's formula, 0.2 px tolerance at this scale.
            const d1 = P[0].sub(P[1].scale(2)).add(P[2]).length();
            const d2 = P[1].sub(P[2].scale(2)).add(P[3]).length();
            const n: u32 = @intFromFloat(std.math.clamp(@ceil(@sqrt(0.75 * @max(d1, d2) * sc / 0.2)), 2, 200));
            wang_n = n;
            const start = list.beginPath();
            for (0..n + 1) |k| {
                const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
                const u = 1 - t;
                try list.pathPoint(.{ .x = u * u * u * P[0].x + 3 * u * u * t * P[1].x + 3 * u * t * t * P[2].x + t * t * t * P[3].x, .y = u * u * u * P[0].y + 3 * u * u * t * P[1].y + 3 * u * t * t * P[2].y + t * t * t * P[3].y });
            }
            try list.endPath(start, C.hex(0xC0C0C0).withAlpha(200), 1.5, false);
        }
        std.debug.print("   wang n = {d}\n", .{wang_n});
        bench("20 wires, Wang segment count", &list, &a, &b, iters, sc);
        list.clear();
        for (0..200) |i| try list.addCircle(.{ .x = 20 + @as(f32, @floatFromInt(i % 40)) * 25, .y = 30 + @as(f32, @floatFromInt(i / 40)) * 25 }, 4, C.hex(0xC7C729), 0);
        bench("200 filled circles r4", &list, &a, &b, iters, sc);
    }
}
