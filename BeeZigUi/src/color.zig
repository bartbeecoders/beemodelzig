//! Colour maths: HSV, mixing, relative luminance and contrast (WCAG 2).
//!
//!     const hsv = zui.color.toHsv(c);
//!     const back = zui.color.fromHsv(hsv, c.a);
//!     if (zui.color.contrast(text, background) < 4.5) ...
//!     const label = zui.color.textOn(accent); // black or white

const std = @import("std");
const draw = @import("draw.zig");
const Color = draw.Color;

/// Hue in degrees (0 to 360), saturation and value from 0 to 1.
pub const Hsv = struct {
    h: f32 = 0,
    s: f32 = 0,
    v: f32 = 0,
};

/// The colour's hue, saturation and value. Greys have hue 0.
pub fn toHsv(c: Color) Hsv {
    const r = @as(f32, @floatFromInt(c.r)) / 255;
    const g = @as(f32, @floatFromInt(c.g)) / 255;
    const b = @as(f32, @floatFromInt(c.b)) / 255;
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const d = max - min;
    var h: f32 = 0;
    if (d > 0) {
        if (max == r) {
            h = 60 * @mod((g - b) / d, 6);
        } else if (max == g) {
            h = 60 * ((b - r) / d + 2);
        } else {
            h = 60 * ((r - g) / d + 4);
        }
    }
    return .{ .h = h, .s = if (max > 0) d / max else 0, .v = max };
}

/// The colour with this hue, saturation and value, and alpha `a`.
pub fn fromHsv(hsv: Hsv, a: u8) Color {
    // (a hue that isn't a number counts as red)
    const h = if (std.math.isFinite(hsv.h)) @mod(hsv.h, 360) / 60 else 0;
    const s = std.math.clamp(hsv.s, 0, 1);
    const v = std.math.clamp(hsv.v, 0, 1);
    const c = v * s;
    const x = c * (1 - @abs(@mod(h, 2) - 1));
    const m = v - c;
    const rgb: [3]f32 = switch (@as(u32, @intFromFloat(@floor(h)))) {
        0 => .{ c, x, 0 },
        1 => .{ x, c, 0 },
        2 => .{ 0, c, x },
        3 => .{ 0, x, c },
        4 => .{ x, 0, c },
        else => .{ c, 0, x },
    };
    return .{ .r = toByte(rgb[0] + m), .g = toByte(rgb[1] + m), .b = toByte(rgb[2] + m), .a = a };
}

fn toByte(f: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(f, 0, 1) * 255));
}

/// `a` moved towards `b` by `t` (0: `a`, 1: `b`), alpha included.
pub fn mix(a: Color, b: Color, t: f32) Color {
    const k = std.math.clamp(t, 0, 1);
    const lerp = struct {
        fn f(x: u8, y: u8, w: f32) u8 {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            return @intFromFloat(@round(fx + (fy - fx) * w));
        }
    }.f;
    return .{ .r = lerp(a.r, b.r, k), .g = lerp(a.g, b.g, k), .b = lerp(a.b, b.b, k), .a = lerp(a.a, b.a, k) };
}

/// Relative luminance, 0 for black to 1 for white (WCAG 2). Ignores alpha.
pub fn luminance(c: Color) f32 {
    const channel = struct {
        fn f(v: u8) f32 {
            const s = @as(f32, @floatFromInt(v)) / 255;
            return if (s <= 0.04045) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
        }
    }.f;
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// The contrast ratio of two colours, from 1 (the same) to 21 (black and
/// white). Body text needs 4.5, large text and outlines 3.
pub fn contrast(a: Color, b: Color) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// Black or white, whichever reads better on `background`.
pub fn textOn(background: Color) Color {
    return if (contrast(Color.white, background) >= contrast(Color.black, background)) Color.white else Color.black;
}

/// `fg` moved towards `toward` just far enough to reach `min` contrast
/// against `bg`, or all the way if it never does.
pub fn ensureContrast(fg: Color, bg: Color, toward: Color, min: f32) Color {
    if (contrast(fg, bg) >= min) return fg;
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..12) |_| {
        const mid = (lo + hi) / 2;
        if (contrast(mix(fg, toward, mid), bg) >= min) hi = mid else lo = mid;
    }
    return mix(fg, toward, hi);
}

/// The colour composited over an opaque `under`, as the eye sees it.
pub fn over(c: Color, under: Color) Color {
    return mix(under.withAlpha(255), c.withAlpha(255), @as(f32, @floatFromInt(c.a)) / 255);
}

const testing = std.testing;

test "hsv round trip" {
    const samples = [_]Color{ Color.hex(0xFF0000), Color.hex(0x00FF00), Color.hex(0x0000FF), Color.hex(0x12ABEF), Color.hex(0x808080), Color.hex(0xFFFFFF), Color.hex(0x000000), Color.hex(0xC0FFEE) };
    for (samples) |c| try testing.expectEqual(c, fromHsv(toHsv(c), 255));
    const red = toHsv(Color.hex(0xFF0000));
    try testing.expectEqual(@as(f32, 0), red.h);
    try testing.expectEqual(@as(f32, 1), red.s);
    try testing.expectApproxEqAbs(@as(f32, 240), toHsv(Color.hex(0x0000FF)).h, 0.01);
    try testing.expectEqual(Color.hex(0x00FFFF), fromHsv(.{ .h = 180, .s = 1, .v = 1 }, 255));
    try testing.expectEqual(Color.hex(0xFF0000), fromHsv(.{ .h = 360, .s = 1, .v = 1 }, 255));
}

test "contrast and text on a colour" {
    try testing.expectApproxEqAbs(@as(f32, 21), contrast(Color.white, Color.black), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), contrast(Color.hex(0x336699), Color.hex(0x336699)), 0.001);
    try testing.expectEqual(Color.white, textOn(Color.hex(0x2F5FC4)));
    try testing.expectEqual(Color.black, textOn(Color.hex(0xF5D547)));
    const fixed = ensureContrast(Color.hex(0x777777), Color.hex(0x666666), Color.white, 4.5);
    try testing.expect(contrast(fixed, Color.hex(0x666666)) >= 4.5);
}
