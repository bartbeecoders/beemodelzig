// The Particles tab of the Properties editor (partui.s part_props). For the
// active object: its particle systems (the one picked by number, its name),
// Add (a preset or an empty system) and Remove; then sections that fold:
//   - Emission: from where (faces, volume, vertices, point, events, a fill),
//     at a rate or all at once, how many, from and until which frame.
//   - Motion: lifetime, speed, spread, gravity, drag (and how random).
//   - Look: points, sprites or objects; size (at the end too), the colour
//     and the colour it ends with, in renders.
//   - Collisions (closed at first): on, bounce, friction, what a hit does.
//   - Liquid (closed at first): on, viscosity, vorticity, tension, substeps,
//     iterations, the surface.
//   - Cache (closed at first): frames and memory, Bake, Free (sim.bake
//     particles liquid).
// The values come from the record each pass into a copy; a change writes the
// copy back into the owned record and names the undo step ("Particles"), as
// the original's callbacks do after the widget's own undo step.
//
// On Zui (bkit.Flow in the tab's page, which editors.zig scrolls): the
// lists are drop-downs (recorded as `enum` too, their captions as
// `caption`), the colours Zui's swatches with the picker.
const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const ops = @import("ops.zig");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const scene = @import("scene.zig");
const undo = @import("undo.zig");
const pt = @import("particles.zig");
const sc = @import("simcache.zig");
const Rect = gfx.Rect;

const UNDO = "Particles";

/// The system's values, as shown (pu_rec), its toggles and colours.
var rec: pt.Rec = .{};
var sel: i32 = 1; // the system picked (1 ..)
var n_sys: u32 = 0;
var coll = false;
var ramp = false;
var liq = false;
var surf = false;
var render = true;
var c1: u32 = 0;
var c2: u32 = 0;
var col: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

// sections: open or not (WGF_SHUT: closed at first)
const S_EMIT = 0;
const S_MOVE = 1;
const S_LOOK = 2;
const S_COLL = 3;
const S_LIQ = 4;
const S_CACHE = 5;
var sec_open = [6]bool{ true, true, true, false, false, false };

const l_froms = [_][]const u8{ "Faces", "Volume", "Vertices", "Point", "Events", "Fill" };
const l_modes = [_][]const u8{ "At a rate", "All at once" };
const l_draws = [_][]const u8{ "Points", "Sprites", "Objects" };
const l_hits = [_][]const u8{ "Bounces", "Dies", "Sticks", "Splits" };
const l_adds = [_][]const u8{ "Add System...", "Rain", "Snow", "Sparks", "Confetti", "Fountain", "Water Tank", "Empty" };
const k_adds = [_][]const u8{ "rain", "snow", "sparks", "confetti", "fountain", "tank", "" };

fn activeObj() ?usize {
    const a = scene.active orelse return null;
    return if (a < scene.count) a else null;
}

/// val_cb: the copy (and the toggles, the colours) into the system picked.
fn valChanged() void {
    const i = activeObj() orelse return;
    const r = pt.nthOwn(scene.objects[i].uid, @intCast(@max(sel - 1, 0))) orelse return;
    rec.coll = (rec.coll & ~@as(u32, 1)) | @intFromBool(coll);
    rec.ramp = (rec.ramp & ~@as(u32, 1)) | @intFromBool(ramp);
    rec.liq = (rec.liq & ~@as(u32, 1)) | @intFromBool(liq);
    rec.surf = (rec.surf & ~@as(u32, 1)) | @intFromBool(surf);
    rec.rflags |= 1;
    if (render) rec.rflags &= ~@as(u32, 1);
    rec.color = c1 & 0xffffff;
    rec.color2 = c2 & 0xffffff;
    const uid = r.uid;
    r.* = rec;
    r.uid = uid;
    app.dirty = true;
    undo.label(UNDO);
}

/// add_cb: a preset (or an empty system) on the object, the new one picked.
fn addPicked(k: usize) void {
    if (k == 0) return;
    const keep = ops.arg;
    defer ops.arg = keep;
    ops.arg = k_adds[k - 1];
    ops.runId("particles.add");
    if (activeObj()) |i| sel = @intCast(pt.count(scene.objects[i].uid));
    app.dirty = true;
}

fn load(r: *const pt.Rec) void {
    rec = r.*;
    coll = r.coll & 1 != 0;
    ramp = r.ramp & 1 != 0;
    liq = r.liq & 1 != 0;
    surf = r.surf & 1 != 0;
    render = r.rflags & 1 == 0;
    c1 = r.color;
    c2 = r.color2;
}

// ---- the widgets -----------------------------------------------------------------

/// pnl_hint: dim text wrapped to the column, recorded as `info`.
fn hint(z: *zui.Ui, s: []const u8) void {
    z.wrappedText(s, .{ .color = host.col(ui.th.text_dim), .width = @floatFromInt(col.w) });
    ui.record("info", s, host.rectOf(z.lastRect()), true);
}

/// A drop-down of `labels`, the whole width (name "##..." to hide it), the
/// chosen one `v.*`; recorded as `enum` too. True when another was picked.
fn enumField(z: *zui.Ui, name: []const u8, v: *u32, labels: []const []const u8, tip: []const u8) bool {
    var items: [16]zui.Choice = undefined;
    const n = @min(labels.len, items.len);
    for (0..n) |k| items[k] = .{ .label = labels[k] };
    var s: usize = @min(v.*, n - 1);
    const r = z.dropdown(name, &s, items[0..n], .{ .width = .fill });
    if (tip.len > 0) z.tooltipRich(r, .{ .title = labels[s], .body = tip });
    ui.record("enum", labels[s], host.rectOf(r.rect), true);
    if (!r.changed) return false;
    v.* = @intCast(s);
    return true;
}

/// pu_cap: the caption in the left half, a drop-down in the right half;
/// the caption recorded as `caption`, on the drop-down's line.
fn capEnum(z: *zui.Ui, cap: []const u8, v: *u32, labels: []const []const u8, tip: []const u8) void {
    z.pushId(cap);
    defer z.popId();
    bkit.beginCaptioned(z, cap, @floatFromInt(@divTrunc(col.w, 2) - 6));
    const changed = enumField(z, "##list", v, labels, tip);
    const r = host.rectOf(z.lastRect());
    bkit.endCaptioned(z);
    ui.record("caption", cap, .{ .x = col.x, .y = r.y, .w = col.w >> 1, .h = r.h }, true);
    if (changed) valChanged();
}

/// pnl_full: a number field across the column.
fn num(z: *zui.Ui, v: *f32, label: []const u8, o: struct { step: f32, lo: f32, hi: f32, dec: u8 = 2, slider: bool = false }, tip: []const u8) void {
    if (bkit.numberRow(z, label, v, .{ .step = o.step, .min = o.lo, .max = o.hi, .decimals = o.dec, .slider = o.slider, .tip = tip }).changed) valChanged();
}

/// A whole number field (WK_INT) on a u32, across the column.
fn int(z: *zui.Ui, v: *u32, label: []const u8, lo: f32, hi: f32, step: f32, tip: []const u8) void {
    var f: f32 = @floatFromInt(@as(i32, @bitCast(v.*)));
    if (bkit.numberRow(z, label, &f, .{ .step = step, .min = lo, .max = hi, .decimals = 0, .tip = tip }).changed) {
        v.* = @bitCast(@as(i32, @intFromFloat(@round(std.math.clamp(f, lo, hi)))));
        valChanged();
    }
}

fn toggle(z: *zui.Ui, label: []const u8, v: *bool, tip: []const u8) void {
    if (bkit.checkRow(z, label, v, tip).changed) valChanged();
}

fn colourDone() void {
    valChanged();
}

// ---- the tab -----------------------------------------------------------------------

/// part_props: the Particles page in the column `bd` (pnl_begin's), from y0:
/// y below it.
pub fn props(i: i16, bd: Rect, y0: i32) i32 {
    col = bd;
    var f = bkit.Flow.begin("particles", @intCast(i), bd, y0);
    if (f.z) |z| {
        // (the original's pitch: 22 a row, 4 between)
        z.beginVertical(.{ .width = .px(@floatFromInt(bd.w)), .spacing = 4 });
        // (fields as narrow as the column: Zui's natural width is wider)
        z.pushMetric(.widget_width, 60);
        defer z.popStyle();
        describe(z);
        z.endVertical();
    }
    return f.end() + 6;
}

fn describe(z: *zui.Ui) void {
    const oi = activeObj() orelse {
        hint(z, "Select an object to emit particles from.");
        return;
    };
    const uid = scene.objects[oi].uid;
    n_sys = pt.count(uid);
    // the Add list (an option shown: "Add System...")
    var add: u32 = 0;
    if (enumField(z, "##add", &add, &l_adds, "A new particle system on the active object: a preset, or an empty one")) addPicked(add);
    if (n_sys == 0) {
        hint(z, "No particle systems: add one (a preset, or an empty system).");
        return;
    }
    // the one picked (1 .. n), Remove
    sel = std.math.clamp(sel, 1, @as(i32, @intCast(n_sys)));
    {
        var fs: f32 = @floatFromInt(sel);
        bkit.beginPair(z);
        if (bkit.numberRow(z, "System", &fs, .{ .step = 0.05, .min = 1, .max = 64, .decimals = 0, .tip = "Which of the object's systems the settings below are" }).changed) {
            sel = std.math.clamp(@as(i32, @intFromFloat(@round(fs))), 1, 64);
        }
        const rm = bkit.button(z, "Remove", "Remove the system picked").clicked;
        bkit.endPair(z);
        if (rm) {
            var b: [32]u8 = undefined;
            const keep = ops.arg;
            defer ops.arg = keep;
            ops.arg = std.fmt.bufPrint(&b, "system {d}", .{sel}) catch "";
            ops.runId("particles.remove");
            app.dirty = true;
            return;
        }
    }
    const r = pt.nth(uid, @intCast(sel - 1)) orelse return;
    load(r);
    {
        var b: [96]u8 = undefined;
        hint(z, std.fmt.bufPrint(&b, "System {d} of {d}: {s}", .{ sel, n_sys, pt.cstr(&r.name) }) catch "");
    }
    z.spacer(.px(4));

    if (bkit.section(z, "Emission", &sec_open[S_EMIT])) {
        z.pushId("§Emission");
        defer z.popId();
        capEnum(z, "From", &rec.from, &l_froms, "Where they are born: on its faces (by area), inside it, at its vertices, at its origin, from another system's events, or on a lattice filling it (liquids)");
        capEnum(z, "Emits", &rec.mode, &l_modes, "Born steadily from the start to the end frame, or all at once at the start");
        if (rec.mode == 0) {
            num(z, &rec.rate, "A second", .{ .step = 1.0, .lo = 0, .hi = 10000000, .dec = 0 }, "How many are born a second");
            num(z, &rec.start, "From frame", .{ .step = 0.2, .lo = -100000, .hi = 100000, .dec = 0 }, "The frame they start being born");
            num(z, &rec.end, "Until frame", .{ .step = 0.2, .lo = -100000, .hi = 1000000, .dec = 0 }, "The frame they stop being born");
        } else {
            int(z, &rec.num, "How many", 0, 4194304, 1.0, "How many are born at once");
            num(z, &rec.start, "From frame", .{ .step = 0.2, .lo = -100000, .hi = 100000, .dec = 0 }, "The frame they start being born");
        }
    }
    if (bkit.section(z, "Motion", &sec_open[S_MOVE])) {
        z.pushId("§Motion");
        defer z.popId();
        num(z, &rec.life, "Lifetime (s)", .{ .step = 0.02, .lo = 0, .hi = 100000 }, "How long each lives");
        num(z, &rec.lifer, "Lifetime random", .{ .step = 0.01, .lo = 0, .hi = 1, .slider = true }, "Some live shorter, by up to this part");
        num(z, &rec.speed, "Speed (m/s)", .{ .step = 0.05, .lo = -10000, .hi = 10000 }, "How fast they are born, along the surface's normal (or the direction)");
        num(z, &rec.speedr, "Speed random", .{ .step = 0.01, .lo = 0, .hi = 1, .slider = true }, "Faster or slower by up to this part");
        num(z, &rec.spread, "Spread (deg)", .{ .step = 0.5, .lo = 0, .hi = 180, .dec = 1 }, "A cone round their way: 0 all the same way, 180 every way");
        num(z, &rec.grav, "Gravity", .{ .step = 0.02, .lo = -100, .hi = 100 }, "How much gravity pulls them (1: as everything else)");
        num(z, &rec.drag, "Drag (1/s)", .{ .step = 0.02, .lo = 0, .hi = 1000 }, "How fast the air slows them");
    }
    if (bkit.section(z, "Look", &sec_open[S_LOOK])) {
        z.pushId("§Look");
        defer z.popId();
        capEnum(z, "Drawn as", &rec.draw, &l_draws, "Drawn as points (a few pixels), sprites (round, their size) or objects (set with particles.set objects A,B)");
        num(z, &rec.size, "Size (m)", .{ .step = 0.002, .lo = 0, .hi = 1000, .dec = 3 }, "How big each is (a liquid: its spacing)");
        num(z, &rec.sizer, "Size random", .{ .step = 0.01, .lo = 0, .hi = 1, .slider = true }, "Bigger or smaller by up to this part");
        num(z, &rec.sizeend, "Size at the end", .{ .step = 0.02, .lo = 0, .hi = 100 }, "Its size times this at the end of its life");
        _ = bkit.colourRow(z, "Colour", &c1, colourDone, "");
        toggle(z, "Changes to", &ramp, "Their colour changes over their life to this one");
        if (ramp) _ = bkit.colourRow(z, "Colour at the end", &c2, colourDone, "");
        toggle(z, "In renders", &render, "Rendered (as balls, or the objects) - off: only in the viewport");
    }
    if (bkit.section(z, "Collisions", &sec_open[S_COLL])) {
        z.pushId("§Collisions");
        defer z.popId();
        toggle(z, "Collide", &coll, "They hit the ground, landscapes, rigid bodies and cloth colliders");
        if (coll) {
            num(z, &rec.bounce, "Bounce", .{ .step = 0.01, .lo = 0, .hi = 1, .slider = true }, "How much of their speed into a surface comes back");
            num(z, &rec.fric, "Friction", .{ .step = 0.01, .lo = 0, .hi = 1, .slider = true }, "How much of their speed along it is lost");
            capEnum(z, "On a hit", &rec.onhit, &l_hits, "What a hit does");
        }
    }
    if (bkit.section(z, "Liquid", &sec_open[S_LIQ])) {
        z.pushId("§Liquid");
        defer z.popId();
        toggle(z, "Liquid", &liq, "They flow as a liquid (position-based fluids): their size is the spacing");
        if (liq) {
            num(z, &rec.visc, "Viscosity", .{ .step = 0.005, .lo = 0, .hi = 1, .dec = 3 }, "Water 0.02, oil 0.2, honey 0.6");
            num(z, &rec.vort, "Vorticity", .{ .step = 0.01, .lo = 0, .hi = 100 }, "Keeps its swirls alive");
            num(z, &rec.tens, "Surface tension", .{ .step = 0.01, .lo = 0, .hi = 10 }, "Holds drops together");
            int(z, &rec.lsub, "Substeps", 1, 32, 0.05, "Steps a frame: more for tall water");
            int(z, &rec.liter, "Iterations", 1, 50, 0.05, "Solver passes a substep");
            toggle(z, "Surface", &surf, "Meshed into a surface each frame (its object shows it)");
        }
    }
    if (bkit.section(z, "Cache", &sec_open[S_CACHE])) {
        z.pushId("§Cache");
        defer z.popId();
        var b: [96]u8 = undefined;
        var fb: [32]u8 = undefined;
        const t = std.fmt.bufPrint(&b, "Cached: {d} + {d} frames, {s} MB{s}", .{
            pt.cvtt(sc.info(7)),          pt.cvtt(sc.info(8)), sc.fix1(&fb, sc.info(2)),
            if (sc.info(9) > 0) " (baked)" else "",
        }) catch "";
        hint(z, t);
        bkit.beginPair(z);
        if (bkit.button(z, "Bake", "Simulate the frame range and keep every frame of the particles (saved with the file)").clicked) ops.runId("particles.bake");
        if (bkit.button(z, "Free", "Forget the particles' cache and bake").clicked) ops.runId("particles.free");
        bkit.endPair(z);
    }
}
