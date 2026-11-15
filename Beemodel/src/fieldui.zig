// Properties > Physics for a force field (fieldui.s): a Force Field section
// (its type and what it does, on, strength, falloff and reach, the type's own
// values, the collision group it acts on); physui.zig then draws the World
// section. The values come from the field's record each pass into a copy; a
// change writes the copy back into the owned record and names the undo step
// ("Field"), as the original's callbacks do after the widget's undo step.
const std = @import("std");
const zui = @import("zui");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const scene = @import("scene.zig");
const undo = @import("undo.zig");
const fl = @import("fields.zig");
const Rect = gfx.Rect;

const UNDO = "Field";

/// The field's values, as shown (fu_rec), on (fu_on), the group (fu_grp, -1: all).
var rec: fl.Rec = .{ .uid = 0 };
var on = true;
var grp: i32 = -1;
var open = true;
/// The caption column: half the panel's width.
var cap_w: f32 = 100;

/// The panel's column, `w` wide: its rows `spacing` apart (null: the
/// kit's), fields no wider than it (Zui's natural width is wider than a
/// narrow column). As physui.zig's flow.
fn beginColumn(z: *zui.Ui, w: i32, spacing: ?f32) void {
    z.beginVertical(.{ .width = .px(@floatFromInt(w)), .spacing = spacing });
    z.pushMetric(.widget_width, 60);
}

fn endColumn(z: *zui.Ui) void {
    z.popStyle();
    z.endVertical();
}

const tips = [fl.N_TYPES][]const u8{ "Pulls things towards it.", "Inside, down is its -Y.", "Blows along its +X.", "Turns things round its +Y.", "Swirls things about.", "Slows things down." };
const falls = [_][]const u8{ "None", "Radius", "Smooth" };
const laws = [_][]const u8{ "1 / d^2", "1 / d" };
const shapes = [_][]const u8{ "Box", "Sphere" };

/// fu_own: the active field's record, writable.
fn own() ?*fl.Rec {
    const i = fl.active() orelse return null;
    return fl.recOwn(scene.objects[i].uid, fl.view(i).typ);
}

/// fval_cb: the copy into the record (the type stays), the group, on.
fn valChanged() void {
    const r = own() orelse return;
    const t = r.typ;
    const uid = r.uid;
    r.* = rec;
    r.uid = uid;
    r.typ = t;
    const g = std.math.clamp(grp, -1, 15);
    r.skip = if (g < 0) 0 else 0xffff & ~(@as(u32, 1) << @intCast(g));
    r.flags &= ~@as(u32, 1);
    if (!on) r.flags |= 1;
    app.dirty = true;
    undo.label(UNDO);
}

/// ftype_cb: another type, its defaults (on or off stays).
fn typeChanged(t: u32) void {
    const r = own() orelse return;
    const f = r.flags;
    fl.setType(r, t);
    r.flags = f;
    app.dirty = true;
    undo.label(UNDO);
}

// ---- the lists (WK_ENUM) ----
const Pick = enum { typ, fall, law, shape };
fn labelsOf(w: Pick) []const []const u8 {
    return switch (w) {
        .typ => &fl.tnames,
        .fall => &falls,
        .law => &laws,
        .shape => &shapes,
    };
}
fn curOf(w: Pick) u32 {
    return switch (w) {
        .typ => rec.typ,
        .fall => rec.fall,
        .law, .shape => rec.law,
    };
}
fn pickSet(what: Pick, k: usize) void {
    const v: u32 = @intCast(k);
    switch (what) {
        .typ => return typeChanged(v),
        .fall => rec.fall = v,
        .law, .shape => rec.law = v,
    }
    valChanged();
}

fn syncFlags() void {
    on = rec.flags & 1 == 0;
    const nk = ~rec.skip & 0xffff;
    grp = if (rec.skip == 0 or nk == 0) -1 else @intCast(@ctz(nk));
}

/// fu_cap: the caption at the left (recorded as `caption`), a list at the
/// right half (`enum:<shown>`).
fn capEnum(z: *zui.Ui, cap: []const u8, what: Pick, tip: []const u8) void {
    z.beginHorizontal(.{ .spacing = 6, .alignment = .center });
    z.label(cap, .{ .color = host.col(ui.th.text_dim), .width = .px(cap_w) });
    ui.record("caption", cap, host.rectOf(z.lastRect()), true);
    const ls = labelsOf(what);
    var items: [8]zui.Choice = undefined;
    for (ls, 0..) |l, k| items[k] = .{ .label = l };
    var sel: usize = @min(curOf(what), ls.len - 1);
    z.pushId(cap);
    const r = step(z.dropdown("##list", &sel, items[0..ls.len], .{ .width = .fill }));
    z.popId();
    ui.record("enum", items[sel].label, host.rectOf(r.rect), true);
    z.tooltipRich(r, .{ .title = cap, .body = tip });
    z.endHorizontal();
    if (r.changed) pickSet(what, sel);
}

/// pnl_full: a number field across the column.
fn num(z: *zui.Ui, v: *f32, label: []const u8, st: f32, lo: f32, hi: f32, dec: u8, slider: bool, tip: []const u8) void {
    const it = step(bkit.numberRow(z, label, v, .{ .step = st, .min = lo, .max = hi, .decimals = dec, .slider = slider, .tip = tip }));
    if (it.changed) valChanged();
}

/// Undo steps. Zui acts in BeeModel's draw pass, and an event Zui takes
/// skips app.afterInput's undo.sync: so a change begun here first closes
/// the step of what came before (else it would join this one), and one
/// made here is its own step when it is committed (`did`, synced at the
/// panel's end; else the next Ctrl+Z would undo the step before it). A
/// drag is one step: begun at its start, made at its release.
var did = false;

fn step(it: zui.Interaction) zui.Interaction {
    if (it.started or it.clicked) undo.sync();
    if (it.committed or it.clicked) did = true;
    return it;
}


/// A whole number field (WK_INT) on an i32.
fn int(z: *zui.Ui, v: *i32, label: []const u8, lo: f32, hi: f32, tip: []const u8) void {
    var f: f32 = @floatFromInt(v.*);
    const it = step(bkit.numberRow(z, label, &f, .{ .step = 0.1, .min = lo, .max = hi, .decimals = 0, .tip = tip }));
    if (it.changed) {
        v.* = @intFromFloat(@round(f));
        valChanged();
    }
}

/// pnl_hint: dim, wrapped to the column; recorded as `info`.
fn hint(z: *zui.Ui, s: []const u8) void {
    z.wrappedText(s, .{ .color = host.col(ui.th.text_dim) });
    ui.record("info", s, host.rectOf(z.lastRect()), true);
}

/// fl_props: the active field's section in the column `bd` (pnl_begin's),
/// from y0; y below it. Nothing when the active object is no field.
pub fn props(i: i16, bd: Rect, y0: i32) i32 {
    const oi = fl.active() orelse return y0;
    rec = fl.view(oi);
    syncFlags();
    cap_w = @floatFromInt((bd.w >> 1) - 3);
    var f = bkit.Flow.begin("field", @intCast(i), bd, y0);
    if (f.z) |z| {
        did = false;
        // (22 a row, 4 between: the original's pitch, as physui's rows)
        beginColumn(z, bd.w, 4);
        describe(z);
        endColumn(z);
        if (did) undo.sync();
    }
    return f.end();
}

fn describe(z: *zui.Ui) void {
    const t: usize = if (rec.typ < fl.N_TYPES) rec.typ else 0;
    if (!bkit.section(z, "Force Field", &open)) return;
    hint(z, tips[t]);
    capEnum(z, "Type", .typ, "What it does: pull, a zone with its own down, wind, a vortex, turbulence or drag");
    if (step(bkit.checkRow(z, "On", &on, "")).changed) valChanged();
    num(z, &rec.str, "Strength", 0.05, -1000000, 1000000, 2, false, "How hard it acts (m/s2: an attractor's pull at 1 m, a zone's gravity, wind's push). Keyframe it as field:Name:strength");
    if (t == fl.ZONE) {
        capEnum(z, "Shape", .shape, "The zone's shape");
        num(z, &rec.rad, "Half size (m)", 0.05, 0.01, 100000, 2, false, "The zone's half size (times the object's scale): a box or a sphere's radius");
    } else {
        capEnum(z, "Falloff", .fall, "How it fades: not at all, stopping at the radius, or smoothly to the radius");
        if (rec.fall != 0) num(z, &rec.rad, "Radius (m)", 0.05, 0.01, 100000, 2, false, "Its reach (times the object's scale)");
        switch (t) {
            fl.ATTR => {
                capEnum(z, "Pull", .law, "Inverse square: like gravity (orbits). 1 / distance: a gentler pull");
                num(z, &rec.soft, "Soft core (m)", 0.01, 0, 1000, 2, false, "Near the centre the pull softens over this distance (no infinite pull)");
            },
            fl.WIND => {
                num(z, &rec.gust, "Gusts", 0.01, 0, 1, 2, true, "How much the wind rises and falls");
                int(z, &rec.seed, "Seed", 0, 100000, "Another pattern (turbulence, gusts)");
            },
            fl.VORTEX => {
                num(z, &rec.lift, "Lift", 0.05, -1000000, 1000000, 2, false, "A pull along its axis (a tornado lifts)");
                num(z, &rec.inflow, "Inflow", 0.05, -1000000, 1000000, 2, false, "A pull towards its axis");
            },
            fl.TURB => {
                num(z, &rec.scale, "Swirl size (m)", 0.05, 0.01, 10000, 2, false, "How large its swirls are");
                int(z, &rec.seed, "Seed", 0, 100000, "Another pattern (turbulence, gusts)");
            },
            else => {},
        }
    }
    int(z, &grp, "Only group (-1: all)", -1, 15, "The collision group it acts on, or -1 for every group (cloth and particles are group 0)");
    z.spacer(.px(2));
}
