// Sculpt mode's face: the operators, the brush bar at the bottom of the viewport
// (vpnav.s tool_settings_draw), the settings line over it (sculpt_overlay), the
// brush at the pointer.
const std = @import("std");
const ops = @import("ops.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const app = @import("app.zig");
const zui = @import("zui");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const sc = @import("sculpt.zig");
const stroke = @import("stroke.zig");
const dyntopo = @import("dyntopo.zig");
const multires = @import("multires.zig");
const armedit = @import("armedit.zig");
const em = @import("editmesh.zig");
const Icon = @import("icons.zig").Icon;

const Impl = ops.Impl;
const Rect = gfx.Rect;
const COL_ACTIVE: u32 = 0xffb340;

const sf_grow: f32 = 1.15;
const sf_shrink: f32 = 0.8695652;
const sf_rmin: f32 = 4.0;
const sf_rmax: f32 = 600.0;
const sf_tenth: f32 = 0.1;

// the mode ---------------------------------------------------------------------------

/// object.sculpt_mode: Ctrl+Tab toggles (an armature: pose mode instead).
fn opMode() void {
    if (!sc.on and armedit.ctrlTab()) return;
    if (sc.on) {
        sc.exit();
        app.toast(.ok, "sculpt mode off", .{});
        return;
    }
    _ = sc.enter(@import("scene.zig").active orelse std.math.maxInt(usize));
}
fn isMode() bool {
    return sc.on;
}

/// mode.sculpt: out of the mode we are in, into this one.
pub fn opModeSet() void {
    if (sc.on) return;
    if (armedit.mode != 0) armedit.mode = 0;
    if (em.active) em.exit();
    opMode();
}

// the brushes ----------------------------------------------------------------------

fn brushOp(comptime b: u32) *const fn () void {
    return struct {
        fn f() void {
            sc.brush = b;
            app.dirty = true;
        }
    }.f;
}

fn radiusBy(k: f32) void {
    sc.radius = stroke.minss(stroke.maxss(sc.radius * k, sf_rmin), sf_rmax);
    app.dirty = true;
}
fn radiusDown() void {
    radiusBy(sf_shrink);
}
fn radiusUp() void {
    radiusBy(sf_grow);
}
fn strengthBy(d: f32) void {
    sc.strength = stroke.minss(stroke.maxss(sc.strength + d, sf_tenth), 1);
    app.dirty = true;
}
fn strengthDown() void {
    strengthBy(-sf_tenth);
}
fn strengthUp() void {
    strengthBy(sf_tenth);
}

fn symOp(comptime bit: u32) *const fn () void {
    return struct {
        fn f() void {
            sc.sym ^= bit;
            app.dirty = true;
        }
    }.f;
}
fn symOn(comptime bit: u32) *const fn () bool {
    return struct {
        fn f() bool {
            return sc.sym & bit != 0;
        }
    }.f;
}

/// sculpt.symmetry none | x | y | z | xy | xz | yz | xyz: the letters in the argument.
fn opSymSet() void {
    var s: u32 = 0;
    for (ops.arg) |ch| {
        const c = ch | 0x20;
        if (c >= 'x' and c <= 'z') s |= @as(u32, 1) << @intCast(c - 'x');
    }
    sc.sym = s;
    app.dirty = true;
}

fn opMaskClear() void {
    sc.maskOp(0);
}
fn opMaskInvert() void {
    sc.maskOp(1);
}

fn opLazy() void {
    stroke.cycleLazy();
    app.toast(.ok, "sculpt stabilizer: {d} px", .{stroke.lazy});
}
fn isLazy() bool {
    return stroke.lazy != 0;
}

fn pmapOp(comptime bit: u32) *const fn () void {
    return struct {
        fn f() void {
            stroke.pmap ^= bit;
            app.dirty = true;
        }
    }.f;
}
fn pmapOn(comptime bit: u32) *const fn () bool {
    return struct {
        fn f() bool {
            return stroke.pmap & bit != 0;
        }
    }.f;
}
fn opCurve() void {
    stroke.pcurve = (stroke.pcurve + 1) % 3;
    app.dirty = true;
}

/// sculpt.falloff smooth|sphere|root|sharp|linear|constant
fn opFalloff() void {
    const w = std.mem.trim(u8, ops.arg, " \"");
    for (sc.fall_names, 0..) |n, k| {
        if (std.mem.eql(u8, n, w)) sc.falloff_kind = @intCast(k);
    }
    app.dirty = true;
}

pub const list = .{
    .{ "mode.sculpt", Impl{ .run = opModeSet, .check = isMode } },
    .{ "object.sculpt_mode", Impl{ .run = opMode, .check = isMode } },
    .{ "sculpt.brush_draw", Impl{ .run = brushOp(sc.DRAW), .mode = .sculpt } },
    .{ "sculpt.brush_clay", Impl{ .run = brushOp(sc.CLAY), .mode = .sculpt } },
    .{ "sculpt.brush_crease", Impl{ .run = brushOp(sc.CREASE), .mode = .sculpt } },
    .{ "sculpt.brush_inflate", Impl{ .run = brushOp(sc.INFLATE), .mode = .sculpt } },
    .{ "sculpt.brush_grab", Impl{ .run = brushOp(sc.GRAB), .mode = .sculpt } },
    .{ "sculpt.brush_snake", Impl{ .run = brushOp(sc.SNAKE), .mode = .sculpt } },
    .{ "sculpt.brush_smooth", Impl{ .run = brushOp(sc.SMOOTH), .mode = .sculpt } },
    .{ "sculpt.brush_flatten", Impl{ .run = brushOp(sc.FLATTEN), .mode = .sculpt } },
    .{ "sculpt.brush_pinch", Impl{ .run = brushOp(sc.PINCH), .mode = .sculpt } },
    .{ "sculpt.brush_layer", Impl{ .run = brushOp(sc.LAYER), .mode = .sculpt } },
    .{ "sculpt.brush_mask", Impl{ .run = brushOp(sc.MASK), .mode = .sculpt } },
    .{ "sculpt.radius_down", Impl{ .run = radiusDown, .mode = .sculpt } },
    .{ "sculpt.radius_up", Impl{ .run = radiusUp, .mode = .sculpt } },
    .{ "sculpt.strength_down", Impl{ .run = strengthDown, .mode = .sculpt } },
    .{ "sculpt.strength_up", Impl{ .run = strengthUp, .mode = .sculpt } },
    .{ "sculpt.symmetry_x", Impl{ .run = symOp(1), .check = symOn(1), .mode = .sculpt } },
    .{ "sculpt.symmetry_y", Impl{ .run = symOp(2), .check = symOn(2), .mode = .sculpt } },
    .{ "sculpt.symmetry_z", Impl{ .run = symOp(4), .check = symOn(4), .mode = .sculpt } },
    .{ "sculpt.symmetry", Impl{ .run = opSymSet } },
    .{ "sculpt.mask_clear", Impl{ .run = opMaskClear, .mode = .sculpt } },
    .{ "sculpt.mask_invert", Impl{ .run = opMaskInvert, .mode = .sculpt } },
    .{ "sculpt.stabilizer", Impl{ .run = opLazy, .check = isLazy, .mode = .sculpt } },
    .{ "sculpt.dyntopo", Impl{ .run = dyntopo.opToggle, .check = dyntopo.isOn, .mode = .sculpt } },
    .{ "sculpt.detail_finer", Impl{ .run = dyntopo.opFiner, .mode = .sculpt } },
    .{ "sculpt.detail_coarser", Impl{ .run = dyntopo.opCoarser, .mode = .sculpt } },
    .{ "sculpt.pressure_strength", Impl{ .run = pmapOp(1), .check = pmapOn(1) } },
    .{ "sculpt.pressure_radius", Impl{ .run = pmapOp(2), .check = pmapOn(2) } },
    .{ "sculpt.pressure_curve", Impl{ .run = opCurve } },
    .{ "sculpt.falloff", Impl{ .run = opFalloff } },
};

/// The tools area in sculpt mode (tl_sculpt): an id, its icon; "" a gap.
pub const tools = [_]struct { id: []const u8, ic: ?Icon }{
    .{ .id = "sculpt.brush_draw", .ic = .brush },    .{ .id = "sculpt.brush_clay", .ic = .brush },
    .{ .id = "sculpt.brush_crease", .ic = .brush },  .{ .id = "sculpt.brush_inflate", .ic = .sphere },
    .{ .id = "sculpt.brush_grab", .ic = .move },     .{ .id = "sculpt.brush_snake", .ic = .curve },
    .{ .id = "sculpt.brush_smooth", .ic = .brush },  .{ .id = "sculpt.brush_flatten", .ic = .plane },
    .{ .id = "sculpt.brush_pinch", .ic = .brush },   .{ .id = "sculpt.brush_layer", .ic = .brush },
    .{ .id = "sculpt.brush_mask", .ic = .sculpt },   .{ .id = "", .ic = null },
    .{ .id = "sculpt.mask_clear", .ic = null },      .{ .id = "sculpt.mask_invert", .ic = null },
    .{ .id = "sculpt.dyntopo", .ic = null },
};

// the settings line ---------------------------------------------------------------

/// fmt_val3: three decimals at most.
pub fn val3(b: []u8, v: f32) []const u8 {
    const k: u32 = @bitCast(stroke.trunc32(v * 1000 + 0.5));
    var f = k % 1000;
    var w: usize = 3;
    while (w > 0 and f % 10 == 0) : (w -= 1) f /= 10;
    if (w == 0) return std.fmt.bufPrint(b, "{d}", .{k / 1000}) catch "";
    return std.fmt.bufPrint(b, "{d}.{d:0>[2]}", .{ k / 1000, f, w }) catch "";
}

fn settingsLine(b: []u8) []const u8 {
    var vb: [24]u8 = undefined;
    var sy: [24]u8 = undefined;
    var n: usize = 0;
    if (sc.sym != 0) {
        const t = "  symmetry";
        @memcpy(sy[0..t.len], t);
        n = t.len;
        for (0..3) |k| {
            if (sc.sym >> @intCast(k) & 1 == 0) continue;
            sy[n] = ' ';
            sy[n + 1] = 'X' + @as(u8, @intCast(k));
            n += 2;
        }
    }
    return std.fmt.bufPrint(b, "Sculpt: {s}  radius {d}  strength {s}{s}  ([ ] radius, Shift+[ ] strength, Ctrl inverts, Shift smooths)", .{ if (sc.land) @import("lsculpt.zig").toolName() else sc.brush_names[sc.brush], stroke.trunc32(sc.radius), val3(&vb, sc.strength), sy[0..n] }) catch "";
}

fn penLine(b: []u8) []const u8 {
    var w = std.Io.Writer.fixed(b);
    var parts: u32 = 0;
    if (multires.owns()) {
        w.print("multires level {d}", .{multires.level()}) catch {};
        parts += 1;
    }
    if (stroke.lazy != 0) {
        if (parts != 0) w.writeAll("   ") catch {};
        w.print("stabilizer {d}", .{stroke.lazy}) catch {};
        parts += 1;
    }
    if (dyntopo.on) {
        if (parts != 0) w.writeAll("   ") catch {};
        w.print("dyntopo {d} px", .{stroke.trunc32(dyntopo.detail)}) catch {};
        parts += 1;
    }
    if (stroke.pen_seen) { // (once a pen has been seen)
        if (parts != 0) w.writeAll("   ") catch {};
        w.writeAll("pen:") catch {};
        if (stroke.pmap & 3 == 0) {
            w.writeAll(" -") catch {};
        } else {
            if (stroke.pmap & 1 != 0) w.writeAll(" strength") catch {};
            if (stroke.pmap & 2 != 0) w.writeAll(" radius") catch {};
            w.writeAll(stroke.curve_names[stroke.pcurve]) catch {};
        }
    }
    return w.buffered();
}

/// The brush circle, and the lines of settings (over the viewport, r its rectangle).
pub fn overlay(r: Rect) void {
    if (!sc.on) return;
    const cv = ui.cv;
    var buf: [200]u8 = undefined;
    _ = cv.text(r.x + 10, r.y + 62, settingsLine(&buf), COL_ACTIVE);
    const l2 = penLine(&buf);
    if (l2.len > 0) {
        _ = cv.text(r.x + 10, r.y + 80, l2, COL_ACTIVE);
        ui.record("info", l2, .{ .x = r.x + 10, .y = r.y + 80, .w = 300, .h = 18 }, true);
    }
    if (ui.inside(r)) ui.cursor = .crosshair;
    if (ui.mx > -1000) {
        const old = cv.setClip(r.intersect(cv.clip));
        defer cv.clip = old;
        stroke.cursor(cv, ui.mx, ui.my, sc.radius, if (sc.stroking) &sc.way else null);
    }
}

// the bar ---------------------------------------------------------------------------

const WG_H = 22;

fn fallLabel(k: usize) []const u8 {
    return ([_][]const u8{ "Smooth", "Sphere", "Root", "Sharp", "Linear", "Constant" })[k];
}
/// The bar's backing: rounded, 210 of 255 over the view (a Zui part's
/// first draw, over `bk`).
pub fn backing(z: *zui.Ui, bk: Rect) void {
    z.drawRect(.{ .rect = host.zr(bk), .fill = host.col(ui.th.pane_bg).withAlpha(210), .radius = 8 });
}

/// What the bar covers (a press there is not a stroke).
pub fn barRect(r: Rect) Rect {
    var x = @divTrunc(r.x + r.right(), 2) - 270;
    x = @max(x, r.x + 250); // (not over the redo panel)
    const y = r.bottom() - 38;
    return .{ .x = x - 6, .y = y - 5 - (WG_H + 6), .w = 552, .h = WG_H + 10 + WG_H + 6 };
}

/// The brush's settings at the bottom of the viewport: a Zui part over its
/// backing, the falloff (and dyntopo's detail) over radius, strength and
/// the mode's toggles.
pub fn bar(i: i16, r: Rect) void {
    if (!sc.on) return;
    const bk = barRect(r);
    const z = host.beginPart("sculpt.bar", @intCast(i), bk) orelse return;
    defer host.endPart(z);
    backing(z, bk);
    z.beginVertical(.{ .padding = 5, .spacing = 6 });
    defer z.endVertical();
    // the row above: falloff, dyntopo's detail
    z.beginHorizontal(.{ .spacing = 8 });
    {
        z.beginHorizontal(.{ .width = .px(150), .spacing = 0 });
        var fk: usize = sc.falloff_kind;
        if (bkit.choice(z, "##Falloff", &fk, 6, fallLabel, "How the brush fades towards its edge")) {
            sc.falloff_kind = @intCast(fk);
            app.dirty = true;
        }
        z.endHorizontal();
        if (dyntopo.on) {
            z.beginHorizontal(.{ .width = .px(150), .spacing = 0 });
            // (one decimal: Ctrl+[ ] step it by a fifth)
            if (bkit.numberRow(z, "Detail", &dyntopo.detail, .{ .step = 0.2, .min = 1, .max = 200, .decimals = 1, .tip = "Dynamic topology: the size of the new edges, in pixels on screen (smaller: more detail)" }).changed) app.dirty = true;
            z.endHorizontal();
        }
    }
    z.endHorizontal();
    z.beginHorizontal(.{ .spacing = 8 });
    {
        z.beginHorizontal(.{ .width = .px(150), .spacing = 0 });
        // (one decimal: [ and ] scale it by 1.15)
        if (bkit.numberRow(z, "Radius", &sc.radius, .{ .step = 0.5, .min = 2, .max = 1000, .decimals = 1, .tip = "The brush's radius in pixels ([ and ] change it)" }).changed) app.dirty = true;
        z.endHorizontal();
        z.beginHorizontal(.{ .width = .px(180), .spacing = 0 });
        if (bkit.numberRow(z, "Strength", &sc.strength, .{ .step = 0.005, .min = 0, .max = 1, .decimals = 2, .slider = true, .tip = "How strongly the brush acts (Shift+[ and Shift+])" }).changed) app.dirty = true;
        z.endHorizontal();
        const btns = [_]struct { id: []const u8, ic: Icon }{
            .{ .id = "sculpt.symmetry_x", .ic = .split_h }, .{ .id = "sculpt.symmetry_y", .ic = .letter_y },
            .{ .id = "sculpt.symmetry_z", .ic = .letter_z }, .{ .id = "sculpt.dyntopo", .ic = .grid },
            .{ .id = "sculpt.stabilizer", .ic = .curve },    .{ .id = "sculpt.pressure_strength", .ic = .brush },
            .{ .id = "sculpt.pressure_radius", .ic = .dot },
        };
        z.beginHorizontal(.{ .width = .auto, .spacing = 2 });
        for (btns) |b| opIcon(z, b.id, b.ic, i);
        z.endHorizontal();
    }
    z.endHorizontal();
}

/// An operator as an icon button (as editors.zOpIcon): its tooltip with
/// the key, greyed with the reason, on the dark accent while its state is
/// on; recorded as `icon:<label>`. A click makes area `area` the active one
/// first. (A kit candidate: bkit.opButton has no checked state.)
pub fn opIcon(z: *zui.Ui, id: []const u8, ic: Icon, area: i16) void {
    const oi = ops.byId(id) orelse return;
    const e = &@import("catalog.zig").entries[oi];
    const why = ops.reason(oi);
    const on = ops.checked(oi) orelse false;
    const t = ui.th;
    var pushed: usize = 0;
    if (why != null) {
        z.pushColor(.text, host.col(t.text_off));
        pushed = 1;
    } else if (on) {
        z.pushColor(.button, host.col(t.accent_dark));
        z.pushColor(.button_hovered, host.col(t.accent_dark));
        z.pushColor(.text, host.col(t.accent_fg));
        pushed = 3;
    }
    defer z.popStyles(pushed);
    var nb: [80]u8 = undefined;
    const name = std.fmt.bufPrint(&nb, "##{s}", .{e.label}) catch "##op";
    z.pushDisabled(why);
    const b = z.button(name, .{ .icon = host.icon(ic), .width = .px(24), .variant = if (on and why == null) .normal else .flat });
    z.popDisabled();
    ui.record("icon", e.label, host.rectOf(b.rect), why == null);
    var kb: [40]u8 = undefined;
    z.tooltipRich(b, .{ .title = e.label, .shortcut = ops.keyLabel(oi, &kb), .body = e.doc, .warning = why orelse "" });
    if (!b.clicked or why != null) return;
    if (area >= 0) app.setActiveArea(area);
    ops.run(oi);
}

test "values as the settings line shows them" {
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0.5", val3(&b, 0.5));
    try std.testing.expectEqualStrings("1", val3(&b, 1));
    try std.testing.expectEqualStrings("0.025", val3(&b, 0.025));
    try std.testing.expectEqualStrings("0.25", val3(&b, 0.25));
}
