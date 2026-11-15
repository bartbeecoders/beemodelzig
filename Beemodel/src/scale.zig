// The scale the UI is drawn at (draw.s): the compositor's (1/120ths, from
// wp_fractional_scale) times the UI scale preference (percent). The UI works
// in its own units; the window's size in them is the compositor's size over
// the preference, and the buffer's pixels are the compositor's size times its
// scale. gfx.Canvas maps units to pixels; text is rasterized at the real size.
const std = @import("std");
const tx = @import("text.zig");

pub const ONE: i32 = 65536;

/// The compositor's part, in 1/120ths (120: none).
pub var comp_s120: u32 = 120;
/// The preference, in percent (Preferences > Interface > UI scale, view.ui_scale).
pub var pref: u32 = 100;
/// Pointer events come in UI units already (the headless driver).
pub var ptr_in_units: bool = false;

/// Units -> pixels, 16.16.
pub fn q16() i32 {
    return @intCast((@as(u64, comp_s120) * pref << 16) / 12000);
}

/// A compositor size in the buffer's pixels.
pub fn px(comp: i32) i32 {
    return @intCast(@divTrunc(@as(i64, comp) * comp_s120 + 60, 120));
}

/// The buffer's pixels in UI units, rounded up: the last row of pixels is covered.
pub fn units(pixels: i32) i32 {
    return @intCast(@divTrunc((@as(i64, pixels) << 16) + q16() - 1, q16()));
}

/// A pointer position (compositor units) in UI units.
pub fn ptr(v: f32) f32 {
    if (ptr_in_units or pref == 100) return v;
    return v * 100.0 / @as(f32, @floatFromInt(pref));
}

/// Fonts for the scale in use: returns whether anything changed.
pub fn apply() bool {
    const s = @as(f32, @floatFromInt(q16())) / 65536.0;
    if (s == tx.ui_scale) return false;
    tx.setScale(s);
    return true;
}

test "units and pixels" {
    const t = std.testing;
    comp_s120 = 150; // a 1.25 screen
    pref = 100;
    try t.expectEqual(@as(i32, 1600), px(1280));
    try t.expectEqual(@as(i32, 1280), units(1600));
    pref = 150;
    // every pixel of the buffer is in reach of the last unit
    var w: i32 = 300;
    while (w < 2000) : (w += 7) {
        const u = units(px(w));
        const last: i64 = (@as(i64, u) * q16() + 0x8000) >> 16;
        try t.expect(last >= px(w));
    }
    comp_s120 = 120;
    pref = 100;
    try t.expectEqual(@as(i32, 65536), q16());
    try t.expectEqual(@as(i32, 1280), units(1280));
}
