// The Render tab's Light Probes and Lightmap panels, on Zui (bkit.Flow in
// the Render tab's page).
const std = @import("std");
const zui = @import("zui");
const gfx = @import("gfx.zig");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const ui = @import("ui.zig");
const probe = @import("probe.zig");
const lightmap = @import("lightmap.zig");
const Rect = gfx.Rect;

var rays: f32 = 256;
var lm_size: f32 = 512;
var lm_rays: f32 = 64;

fn heading(z: *zui.Ui, s: []const u8) void {
    z.spacer(.px(2));
    z.pushFont(host.headFont());
    defer z.popFont();
    z.label(s, .{ .color = host.col(ui.th.accent_fg) });
}

fn lastBake(z: *zui.Ui, ms: i64) void {
    if (ms <= 0) return;
    var b: [40]u8 = undefined;
    bkit.note(z, std.fmt.bufPrint(&b, "Last bake: {d} ms", .{ms}) catch return);
}

/// Below y; returns where it ends.
pub fn draw(salt: usize, bd: Rect, y0: i32) i32 {
    var f = bkit.Flow.begin("bake", salt, bd, y0);
    if (f.z) |z| describe(z);
    return f.end();
}

fn describe(z: *zui.Ui) void {
    heading(z, "Light Probes");
    bkit.beginPair(z);
    _ = bkit.opButton(z, "probe.add", .{ .label = "Add Irradiance", .arg = "irradiance", .tip = "An irradiance volume at the 3D cursor" });
    _ = bkit.opButton(z, "probe.add", .{ .label = "Add Reflection", .arg = "reflection", .tip = "A reflection probe at the 3D cursor" });
    bkit.endPair(z);
    _ = bkit.numberRow(z, "Rays a point", &rays, .{ .step = 1, .min = 4, .max = 65536, .decimals = 0, .tip = "Rays a grid point; a reflection probe's texels take an eighth of that" });
    var ab: [16]u8 = undefined;
    const arg = std.fmt.bufPrint(&ab, "{d}", .{@as(u32, @intFromFloat(@round(rays)))}) catch "";
    bkit.beginPair(z);
    _ = bkit.opButton(z, "probe.bake", .{ .label = "Bake Probes", .arg = arg });
    _ = bkit.opButton(z, "probe.clear", .{ .label = "Remove All" });
    bkit.endPair(z);
    lastBake(z, probe.last_ms);

    heading(z, "Lightmap");
    _ = bkit.numberRow(z, "Size (texels)", &lm_size, .{ .step = 1, .min = 64, .max = 4096, .decimals = 0, .tip = "The atlas's side" });
    _ = bkit.numberRow(z, "Rays a texel", &lm_rays, .{ .step = 0.5, .min = 1, .max = 4096, .decimals = 0, .tip = "Rays gathered at each covered texel" });
    var lb: [32]u8 = undefined;
    const larg = std.fmt.bufPrint(&lb, "{d} {d}", .{ @as(u32, @intFromFloat(@round(lm_size))), @as(u32, @intFromFloat(@round(lm_rays))) }) catch "";
    _ = bkit.opButton(z, "lightmap.bake", .{ .label = "Bake Lightmap", .arg = larg });
    bkit.beginPair(z);
    _ = bkit.opButton(z, "lightmap.save", .{ .label = "Save..." });
    _ = bkit.opButton(z, "lightmap.clear", .{ .label = "Clear" });
    bkit.endPair(z);
    lastBake(z, if (lightmap.rgb.len > 0) lightmap.ms else 0);
    z.spacer(.px(2));
}
