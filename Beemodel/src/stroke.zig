// What a brush stroke is, whatever it paints on: the pen's pressure through a
// curve, the stabilizer's string, the dabs along the pointer's way and the circle
// at the pointer. Sculpt mode uses it (sculpt.zig); texture, vertex-colour and
// weight painting will too, so nothing here knows about meshes.
//
// A pen's pressure (tablet.zig) scales the strength and / or the radius of each
// dab through a curve; its eraser end inverts. The stabilizer drags the stroke
// point behind the pointer on a string. As sculpt.s (pen_factor, sculpt_drag, the
// overlay) and window.s (in_pressure, in_eraser, in_pen).
const std = @import("std");
const gfx = @import("gfx.zig");

/// The pen's pressure 0..1 (the mouse: 1), its eraser end, a tablet tool was seen.
pub var pressure: f32 = 1;
pub var eraser: bool = false;
pub var pen_seen: bool = false;

/// What pressure drives: 1 strength, 2 radius.
pub var pmap: u32 = 1;
/// 0 soft (sqrt), 1 linear, 2 hard (^2).
pub var pcurve: u32 = 1;
/// The stabilizer's string, pixels (0: off).
pub var lazy: u32 = 0;

pub const curve_names = [3][]const u8{ " (soft)", " (linear)", " (hard)" };

/// cvttss2si: a float that does not fit gives minInt, never a trap.
pub inline fn trunc32(x: f32) i32 {
    return asm ("cvttss2si %[x], %[r]"
        : [r] "=r" (-> i32),
        : [x] "x" (x),
    );
}

/// cvtss2si: to the nearest, ties to even.
pub inline fn round32(x: f32) i32 {
    return asm ("cvtss2si %[x], %[r]"
        : [r] "=r" (-> i32),
        : [x] "x" (x),
    );
}

/// minss a, b: a when it is less, else b (a NaN gives b).
pub inline fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
/// maxss a, b: a when it is more, else b (a NaN gives b).
pub inline fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

/// The pen's pressure through the curve (hand false: scripts, 1).
pub fn penFactor(hand: bool) f32 {
    if (!hand) return 1;
    const p = minss(maxss(pressure, 0), 1);
    return switch (pcurve) {
        0 => @sqrt(p),
        2 => p * p,
        else => p,
    };
}

/// A pointer event: full pressure, no eraser.
pub fn mouseInput() void {
    pressure = 1;
    eraser = false;
}

/// Off, 10, 25, 50 pixels.
pub fn cycleLazy() void {
    lazy = switch (lazy) {
        0 => 10,
        10 => 25,
        25 => 50,
        else => 0,
    };
}

/// How many dabs over a distance: one every `every`, at most 64; 0: not yet.
pub fn dabsAlong(d: f32, every: f32) i32 {
    const n = trunc32(d / every);
    if (n <= 0) return 0;
    return @min(n, 64);
}

/// One stroke's way over the screen.
pub const Way = struct {
    /// the stabilized pointer
    lz_x: f32 = 0,
    lz_y: f32 = 0,
    /// where the last dab went
    last_x: i32 = 0,
    last_y: i32 = 0,

    pub fn begin(w: *Way, x: i32, y: i32) void {
        w.lz_x = @floatFromInt(x);
        w.lz_y = @floatFromInt(y);
        w.last_x = x;
        w.last_y = y;
    }

    /// The stabilizer on the pointer: where the stroke is now, null while the
    /// pointer is within the string.
    pub fn follow(w: *Way, x: i32, y: i32) ?[2]i32 {
        if (lazy == 0) return .{ x, y };
        const len: f32 = @floatFromInt(lazy);
        const dx = @as(f32, @floatFromInt(x)) - w.lz_x;
        const dy = @as(f32, @floatFromInt(y)) - w.lz_y;
        const d = @sqrt(dx * dx + dy * dy);
        if (!(d > len)) return null;
        const k = (d - len) / d;
        w.lz_x = dx * k + w.lz_x;
        w.lz_y = dy * k + w.lz_y;
        return .{ round32(w.lz_x), round32(w.lz_y) };
    }

    /// How many dabs from the last point to (x, y): one every `every` pixels, at
    /// most 64; 0: not yet (the last point stays).
    pub fn dabs(w: *const Way, x: i32, y: i32, radius: f32) i32 {
        const dx: f32 = @floatFromInt(x -% w.last_x);
        const dy: f32 = @floatFromInt(y -% w.last_y);
        const d = @sqrt(dx * dx + dy * dy);
        return dabsAlong(d, maxss(radius * spacing, 1));
    }

    /// The k-th of n points on the way to (x, y).
    pub fn at(w: *const Way, x: i32, y: i32, k: i32, n: i32) [2]i32 {
        const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        const dx: f32 = @floatFromInt(x -% w.last_x);
        const dy: f32 = @floatFromInt(y -% w.last_y);
        return .{ trunc32(dx * t) +% w.last_x, trunc32(dy * t) +% w.last_y };
    }

    pub fn arrived(w: *Way, x: i32, y: i32) void {
        w.last_x = x;
        w.last_y = y;
    }
};

/// Dabs: every 10% of the radius.
pub const spacing: f32 = 0.10;

const COL: u32 = 0xf0f0f0;
const sf_2pi32: f32 = 0.19634954; // 2 pi / 32

/// The brush at the pointer (logical pixels): 32 segments, and while the
/// stabilizer holds a stroke its string, from the stroke to the pointer.
pub fn cursor(cv: *gfx.Canvas, x: i32, y: i32, radius: f32, string: ?*const Way) void {
    if (string) |w| {
        if (lazy != 0) cv.line(trunc32(w.lz_x), trunc32(w.lz_y), x, y, COL);
    }
    var k: usize = 0;
    while (k < 32) : (k += 1) {
        const a = circPt(k, x, y, radius);
        const b = circPt(k + 1, x, y, radius);
        cv.line(a[0], a[1], b[0], b[1], COL);
    }
}

fn circPt(k: usize, x: i32, y: i32, radius: f32) [2]i32 {
    const t = @as(f32, @floatFromInt(k)) * sf_2pi32;
    return .{ trunc32(@cos(t) * radius) +% x, trunc32(@sin(t) * radius) +% y };
}

test "the pen's curve" {
    pressure = 0.25;
    pcurve = 0;
    try std.testing.expectEqual(@as(f32, 0.5), penFactor(true));
    pcurve = 1;
    try std.testing.expectEqual(@as(f32, 0.25), penFactor(true));
    pcurve = 2;
    try std.testing.expectEqual(@as(f32, 0.0625), penFactor(true));
    try std.testing.expectEqual(@as(f32, 1), penFactor(false));
    pressure = std.math.nan(f32);
    pcurve = 1;
    try std.testing.expect(penFactor(true) == 0); // (a NaN never reaches a dab)
    pressure = 7;
    try std.testing.expectEqual(@as(f32, 1), penFactor(true));
    pressure = 1;
}

test "the string holds short moves and trails long ones" {
    lazy = 10;
    defer lazy = 0;
    var w = Way{};
    w.begin(100, 100);
    try std.testing.expect(w.follow(105, 100) == null);
    try std.testing.expect(w.follow(110, 100) == null); // (exactly its length)
    const p = w.follow(130, 100).?;
    try std.testing.expectEqual(@as(i32, 120), p[0]);
    try std.testing.expectEqual(@as(i32, 100), p[1]);
}

test "dabs along the way" {
    var w = Way{};
    w.begin(0, 0);
    try std.testing.expectEqual(@as(i32, 0), w.dabs(4, 0, 50)); // (5 px apart)
    try std.testing.expectEqual(@as(i32, 2), w.dabs(10, 0, 50));
    try std.testing.expectEqual(@as(i32, 64), w.dabs(5000, 0, 50));
    try std.testing.expectEqual(@as(i32, 10), w.dabs(10, 0, 1)); // (at least 1 px apart)
    try std.testing.expectEqual(@as(i32, 5), w.at(10, 0, 1, 2)[0]);
    try std.testing.expectEqual(@as(i32, 10), w.at(10, 0, 2, 2)[0]);
}

test "the conversions keep the original's edges" {
    try std.testing.expectEqual(@as(i32, -2147483648), trunc32(std.math.nan(f32)));
    try std.testing.expectEqual(@as(i32, -2147483648), trunc32(1e20));
    try std.testing.expectEqual(@as(i32, 2), round32(2.5));
    try std.testing.expectEqual(@as(i32, 4), round32(3.5));
    try std.testing.expectEqual(@as(i32, -1), trunc32(-1.9));
    try std.testing.expectEqual(@as(f32, 2), minss(std.math.nan(f32), 2));
    try std.testing.expectEqual(@as(f32, 2), maxss(std.math.nan(f32), 2));
}

