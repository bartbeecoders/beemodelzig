// The primitives the original adds beyond cube, sphere, cylinder and plane
// (mesh.s prim_cone, prim_torus, prim_grid_n; ground.s): the same vertices in the
// same order, built the same way in single precision, so that the files match.
//   Cone    32 segments, radius 1, from y = -1 to the apex at y = 1
//   Torus   48 x 12, major radius 1, minor 0.25
//   Grid    2 x 2 m on the XZ plane, 10 x 10 quads
//   Ground  an endless floor: a 1 km square in 50 m cells, drawn as a grid that
//           fades with the distance from the view's centre. A scene has one.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const gfx = @import("gfx.zig");
const app = @import("app.zig");
const vp = @import("viewport.zig");
const theme = @import("theme.zig");
const undo = @import("undo.zig");

const A = std.heap.page_allocator;
pub const OBF_GROUND: u32 = 0x2000;
pub const OBF_CATCH: u32 = 0x4000;
const TAU: f32 = 6.2831853;

/// As the original's x87 fsincos, rounded to single.
fn sincos(x: f32) [2]f32 {
    const d: f64 = x;
    return .{ @floatCast(@sin(d)), @floatCast(@cos(d)) };
}

const Poly = struct {
    v: std.ArrayList(m.V3) = .empty,
    off: std.ArrayList(u32) = .empty,
    loops: std.ArrayList(u32) = .empty,

    fn init() !Poly {
        var p = Poly{};
        try p.off.append(A, 0);
        return p;
    }
    fn face(p: *Poly, l: []const u32) !void {
        try p.loops.appendSlice(A, l);
        try p.off.append(A, @intCast(p.loops.items.len));
    }
    pub fn deinit(p: *Poly) void {
        p.v.deinit(A);
        p.off.deinit(A);
        p.loops.deinit(A);
    }
    fn mesh(p: *const Poly) ?u16 {
        return scene.addMesh(p.v.items, p.off.items, p.loops.items);
    }
};

pub fn cone() !Poly {
    const n = 32;
    var p = try Poly.init();
    errdefer p.deinit();
    for (0..n) |i| {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, n) * TAU;
        const sc = sincos(a);
        try p.v.append(A, .{ sc[1], -1, sc[0] });
    }
    try p.v.append(A, .{ 0, 1, 0 });
    for (0..n) |i| try p.face(&.{ @intCast(i), n, @intCast((i + 1) % n) });
    var cap: [n]u32 = undefined;
    for (&cap, 0..) |*c, i| c.* = @intCast(i);
    try p.face(&cap);
    return p;
}

pub fn torus() !Poly {
    const nu = 48;
    const nv = 12;
    var p = try Poly.init();
    errdefer p.deinit();
    for (0..nu) |i| {
        const su = sincos(@as(f32, @floatFromInt(i)) * TAU / @as(f32, nu));
        for (0..nv) |j| {
            const sv = sincos(@as(f32, @floatFromInt(j)) * TAU / @as(f32, nv));
            const ring = sv[1] * 0.25 + 1.0;
            try p.v.append(A, .{ ring * su[1], sv[0] * 0.25, ring * su[0] });
        }
    }
    for (0..nu) |i| {
        const r0: u32 = @intCast(i * nv);
        const r1: u32 = @intCast(((i + 1) % nu) * nv);
        for (0..nv) |j| {
            const a: u32 = @intCast(j);
            const b: u32 = @intCast((j + 1) % nv);
            try p.face(&.{ r0 + a, r0 + b, r1 + b, r1 + a });
        }
    }
    return p;
}

/// n x n quads, facing up, 2 x 2 m.
pub fn grid(n: u32) !Poly {
    var p = try Poly.init();
    errdefer p.deinit();
    const fnn: f32 = @floatFromInt(n);
    for (0..n + 1) |r| {
        for (0..n + 1) |c| {
            const fc: f32 = @floatFromInt(c);
            const fr: f32 = @floatFromInt(r);
            try p.v.append(A, .{ (fc + fc) / fnn - 1, 0, (fr + fr) / fnn - 1 });
        }
    }
    for (0..n) |r| {
        for (0..n) |c| {
            const a: u32 = @intCast(r * (n + 1) + c);
            try p.face(&.{ a, a + n + 1, a + n + 2, a + 1 });
        }
    }
    return p;
}

fn uniqueName(o: *scene.Object, base: []const u8) void {
    o.setName(base);
    var buf: [32]u8 = undefined;
    var k: u32 = 1;
    while (scene.find(o.name()) != null) : (k += 1) {
        o.setName(std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ base, k }) catch return);
    }
}

fn addObject(name: []const u8, p: *Poly) ?usize {
    defer p.deinit();
    if (scene.count >= scene.max_objects) {
        app.toast(.warn, "The scene is full ({d} objects)", .{scene.max_objects});
        return null;
    }
    const mi = p.mesh() orelse {
        app.toast(.warn, "There is not enough memory", .{});
        return null;
    };
    var o = scene.Object{ .kind = .mesh, .mesh = mi, .loc = scene.cursor, .color = 0xb4b8c0 }; // (type_colors: a mesh)
    uniqueName(&o, name);
    scene.objects[scene.count] = o;
    scene.stamp(scene.count);
    scene.count += 1;
    scene.selectOnly(scene.count - 1);
    undo.label("Add");
    if (!@import("ops.zig").quiet) app.toast(.ok, "  added {s}", .{scene.objects[scene.count - 1].name()}); // (the original's console line; quiet in scripts)
    return scene.count - 1;
}

pub fn opCone() void {
    var p = cone() catch return;
    _ = addObject("Cone", &p);
}
pub fn opTorus() void {
    var p = torus() catch return;
    _ = addObject("Torus", &p);
}
pub fn opGrid() void {
    var p = grid(10) catch return;
    _ = addObject("Grid", &p);
}

// --- the Ground --------------------------------------------------------------

/// The scene's Ground.
pub fn find() ?usize {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.gflags & OBF_GROUND != 0) return i;
    }
    return null;
}

/// create.ground [height h]: with one there it is selected.
pub fn opGround(arg: []const u8) void {
    var height: f32 = 0;
    var it = std.mem.tokenizeScalar(u8, arg, ' ');
    while (it.next()) |w| {
        if (!std.mem.eql(u8, w, "height")) continue;
        const v = std.fmt.parseFloat(f32, it.next() orelse break) catch continue;
        if (std.math.isFinite(v)) height = v;
    }
    if (find()) |g| {
        scene.selectOnly(g);
        return app.log("  selected the Ground (a scene has one)", .{});
    }
    var p = grid(20) catch return;
    for (p.v.items) |*v| {
        v[0] *= 500;
        v[2] *= 500;
    }
    const i = addObject("Ground", &p) orelse return;
    const o = &scene.objects[i];
    o.gflags = OBF_GROUND | OBF_CATCH;
    o.loc = .{ 0, height, 0 };
}

fn mix(a: u32, b: u32, t: f32) u32 {
    var out: u32 = 0;
    var sh: u5 = 16;
    while (true) : (sh -= 8) {
        const x: f32 = @floatFromInt((a >> sh) & 255);
        const y: f32 = @floatFromInt((b >> sh) & 255);
        out |= @as(u32, @intFromFloat(std.math.clamp(@round(x + (y - x) * t), 0, 255))) << sh;
        if (sh == 0) break;
    }
    return out;
}

const GG_N = 40;

/// Lines across the Ground's plane every grid step, ten times coarser while 40
/// steps do not reach, around the view's centre, fading to the background with
/// the distance from it; every 10th line major. False: no Ground to draw.
pub fn drawGrid(cv: *gfx.Canvas, c: *const vp.Cam, v: *const vp.View, th: *const theme.Theme) bool {
    const gi = find() orelse return false;
    const g = &scene.objects[gi];
    if (!g.visible) return false;
    const y = g.loc[1];
    const reach = @max(v.dist * 2, 8.0);
    var step: f32 = 1;
    while (step * GG_N < reach) step *= 10;
    const centre = [2]f32{ v.target[0], v.target[2] };
    const steps = [2]i32{ @intFromFloat(@round(std.math.clamp(centre[0] / step, -1e8, 1e8))), @intFromFloat(@round(std.math.clamp(centre[1] / step, -1e8, 1e8))) };
    const base = [2]f32{ @as(f32, @floatFromInt(steps[0])) * step, @as(f32, @floatFromInt(steps[1])) * step };
    for (0..2) |dir| {
        const other = dir ^ 1;
        var l: i32 = -GG_N;
        while (l <= GG_N) : (l += 1) {
            const major = @mod(steps[dir] + l, 10) == 0;
            const col = if (!major) th.grid else if (g.selected) th.selected else th.grid_major;
            const across = @as(f32, @floatFromInt(l)) * step + base[dir];
            const d0 = (across - centre[dir]) * (across - centre[dir]);
            var s: i32 = -GG_N;
            while (s < GG_N) : (s += 1) {
                const fs: f32 = @floatFromInt(s);
                const mid = (fs + 0.5) * step + base[other] - centre[other];
                const fade = 1 - @sqrt(mid * mid + d0) / reach;
                if (fade <= 0) continue;
                const a = fs * step + base[other];
                const b = a + step;
                const shade = mix(th.canvas_bot, col, fade);
                if (dir == 0) vp.line3(cv, c, .{ across, y, a }, .{ across, y, b }, shade) else vp.line3(cv, c, .{ a, y, across }, .{ b, y, across }, shade);
            }
        }
    }
    return true;
}

const testing = std.testing;

test "sizes as the original's" {
    var c = try cone();
    defer c.deinit();
    try testing.expectEqual(33, c.v.items.len);
    try testing.expectEqual(34, c.off.items.len);
    var t = try torus();
    defer t.deinit();
    try testing.expectEqual(576, t.v.items.len);
    try testing.expectEqual(577, t.off.items.len);
    var g = try grid(10);
    defer g.deinit();
    try testing.expectEqual(121, g.v.items.len);
    try testing.expectEqual(100, g.off.items.len - 1);
}

test "the fade goes from the line colour to the background" {
    try testing.expectEqual(@as(u32, 0x804020), mix(0x804020, 0xffffff, 0));
    try testing.expectEqual(@as(u32, 0xffffff), mix(0x804020, 0xffffff, 1));
}
