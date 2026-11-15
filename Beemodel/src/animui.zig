// The Animation tab of Properties (animui.s): shape keys, actions and layers,
// drivers, onion skins and motion paths. And I over a field: a key on that value.
const std = @import("std");
const zui = @import("zui");
const gfx = @import("gfx.zig");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const anim = @import("anim.zig");
const aops = @import("animops.zig");
const shape = @import("shape.zig");
const motion = @import("motion.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const mods = @import("mods.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const editors = @import("editors.zig");
const wg = @import("wg.zig");
const Rect = gfx.Rect;

const MAXROW = 32;

/// A list row's name: the left 38 % of the column, cut with an ellipsis.
fn rowName(z: *zui.Ui, s: []const u8) void {
    z.label(s, .{ .width = .px(name_w), .ellipsis = true });
}

/// A list row's slider (0..1, label-less), recorded as BeeModel's `slider`.
fn rowSlider(z: *zui.Ui, v: *f32, tip: []const u8, path: wg.Path) bool {
    const it = step(bkit.numberRow(z, "##value", v, .{ .step = 0.005, .min = 0, .max = 1, .decimals = 2, .slider = true, .tip = tip, .path = path }));
    return it.changed;
}

/// The x at a row's end.
fn xBtn(z: *zui.Ui, tip: []const u8) bool {
    const b = step(z.button("x", .{ .width = .px(18), .variant = .flat }));
    z.tooltipRich(b, .{ .title = "x", .body = tip });
    return b.clicked;
}

/// A Mute check box under a row, 12 in.
fn muteRow(z: *zui.Ui, v: *bool) bool {
    z.beginHorizontal(.{ .spacing = 0 });
    z.spacer(.px(12));
    const c = step(bkit.checkRow(z, "Mute", v, ""));
    z.endHorizontal();
    return c.changed;
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

/// A button that acted.
fn act(b: zui.Interaction) bool {
    return step(b).clicked;
}

var name_w: f32 = 80;

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

pub fn props(i: i16, bd: Rect, y0: i32) i32 {
    name_w = @floatFromInt(@divTrunc(bd.w * 38, 100));
    var f = bkit.Flow.begin("anim", @intCast(i), bd, y0);
    if (f.z) |z| {
        did = false;
        beginColumn(z, bd.w, null);
        describe(z);
        endColumn(z);
        if (did) undo.sync();
    }
    return f.end();
}

fn describe(z: *zui.Ui) void {
    // ---- shape keys (a mesh) ----
    if (scene.active) |ai| {
        const o = &scene.objects[ai];
        if (o.kind.isMesh() and o.mesh != null and bkit.section(z, "Shape Keys", &editors.sec_open[16])) {
            const b = shape.of(ai);
            if (b == null or b.?.h.n <= 1) bkit.note(z, "Shape keys store poses of the mesh to blend.");
            if (b) |sk| {
                var k: u32 = 1;
                while (k < sk.h.n and k < MAXROW) : (k += 1) {
                    const rec = &sk.h.keys[k];
                    z.pushIdInt(k);
                    defer z.popId();
                    z.beginHorizontal(.{ .spacing = 4, .alignment = .center });
                    rowName(z, shape.name(rec));
                    var v = rec.val;
                    if (rowSlider(z, &v, "How much of this shape is mixed in (I: key it)", .{ .shape = k })) {
                        shape.setValue(ai, k, v);
                        undo.label("Shape Key");
                    }
                    const x = xBtn(z, "Remove the shape key");
                    z.endHorizontal();
                    if (x) {
                        var t: [80]u8 = undefined;
                        aops.runText("shape.remove", std.fmt.bufPrint(&t, "{s} {s}", .{ shape.name(rec), o.name() }) catch "");
                        break;
                    }
                }
            }
            if (act(bkit.button(z, "Add Shape Key...", ""))) ops.runId("shape.add");
            z.spacer(.px(6));
        }
    }
    // ---- actions and layers ----
    if (bkit.section(z, "Actions and Layers", &editors.sec_open[17])) {
        const b = anim.cur;
        if (b == null or b.?.h.nact == 0) bkit.note(z, "Key some objects, then New Action keeps their keys.");
        if (b) |x| {
            for (x.actions()[0..@min(x.h.nact, MAXROW)]) |*a| {
                var t: [80]u8 = undefined;
                bkit.note(z, std.fmt.bufPrint(&t, "{s} frames {d} - {d}", .{ std.mem.sliceTo(&a.name, 0), @round(std.math.clamp(a.start, -1e9, 1e9)), @round(std.math.clamp(a.end, -1e9, 1e9)) }) catch "");
            }
            var l: usize = 0;
            while (l < x.h.nlay and l < MAXROW) : (l += 1) {
                const ly = x.h.lay[l];
                z.pushIdInt(l);
                defer z.popId();
                var t: [64]u8 = undefined;
                const an = if (ly.act > 0 and ly.act <= x.h.nact) std.mem.sliceTo(&x.h.act[ly.act - 1].name, 0) else "";
                z.beginHorizontal(.{ .spacing = 4, .alignment = .center });
                rowName(z, std.fmt.bufPrint(&t, "Layer {d} {s}", .{ l + 1, an }) catch "");
                var v = ly.infl;
                if (rowSlider(z, &v, "How strongly the layer's action plays", .none)) {
                    if (anim.own(0)) |n| n.h.lay[l].infl = v;
                    undo.label("Layer");
                    app.dirty = true;
                }
                const rm = xBtn(z, "Remove the layer");
                z.endHorizontal();
                if (rm) {
                    var a: [16]u8 = undefined;
                    aops.runText("anim.layer_remove", std.fmt.bufPrint(&a, "{d}", .{l + 1}) catch "");
                    break;
                }
                var muted = ly.mute != 0;
                if (muteRow(z, &muted)) {
                    if (anim.own(0)) |n| n.h.lay[l].mute = @intFromBool(muted);
                    undo.label("Layer");
                    app.dirty = true;
                }
            }
        }
        bkit.beginPair(z);
        if (act(bkit.button(z, "New Action...", ""))) ops.runId("anim.action");
        if (act(bkit.button(z, "Add Layer...", ""))) ops.runId("anim.layer");
        bkit.endPair(z);
        z.spacer(.px(8));
    }
    // ---- drivers ----
    if (bkit.section(z, "Drivers", &editors.sec_open[18])) {
        const b = anim.cur;
        if (b == null or b.?.h.ndrv == 0) bkit.note(z, "A driver sets a value from an expression (anim.driver).");
        if (b) |x| {
            var d: usize = 0;
            while (d < x.h.ndrv and d < MAXROW) : (d += 1) {
                z.pushIdInt(d);
                defer z.popId();
                var t: [32]u8 = undefined;
                const dr = &x.h.drv[d];
                z.beginHorizontal(.{ .spacing = 4, .alignment = .center });
                rowName(z, std.fmt.bufPrint(&t, "Driver {d}", .{d + 1}) catch "");
                if (bkit.textRow(z, "##expression", std.mem.sliceTo(&dr.expr, 0), "expression")) |nt| {
                    undo.sync();
                    did = true;
                    var a: [180]u8 = undefined;
                    aops.runText("anim.driver_set", std.fmt.bufPrint(&a, "{d} expression {s}", .{ d + 1, nt }) catch "");
                }
                const rm = xBtn(z, "Remove the driver");
                z.endHorizontal();
                if (rm) {
                    var a: [32]u8 = undefined;
                    aops.runText("anim.driver_set", std.fmt.bufPrint(&a, "{d} remove", .{d + 1}) catch "");
                    break;
                }
                var muted = dr.mute != 0;
                if (muteRow(z, &muted)) {
                    var a: [32]u8 = undefined;
                    aops.runText("anim.driver_set", std.fmt.bufPrint(&a, "{d} mute {d}", .{ d + 1, @intFromBool(muted) }) catch "");
                }
            }
        }
        z.spacer(.px(8));
    }
    // ---- onion skins, motion paths ----
    if (bkit.section(z, "Onion Skins and Motion Paths", &editors.sec_open[19])) {
        var on = motion.on_on;
        var changed = false;
        if (step(bkit.checkRow(z, "Onion skins", &on, "")).changed) changed = true;
        var vb: f32 = @floatFromInt(motion.on_before);
        var va: f32 = @floatFromInt(motion.on_after);
        var vs: f32 = @floatFromInt(motion.on_step);
        for ([_]zui.Interaction{
            step(bkit.numberRow(z, "Before", &vb, .{ .step = 0.05, .min = 0, .max = 4, .decimals = 0 })),
            step(bkit.numberRow(z, "After", &va, .{ .step = 0.05, .min = 0, .max = 4, .decimals = 0 })),
            step(bkit.numberRow(z, "Every", &vs, .{ .step = 0.05, .min = 1, .max = 100, .decimals = 0, .tip = "Frames between ghosts" })),
        }) |it| {
            if (it.changed) changed = true;
        }
        if (changed) {
            var a: [48]u8 = undefined;
            const t: []const u8 = if (on) (std.fmt.bufPrint(&a, "{d} {d} {d}", .{ @round(vb), @round(va), @round(vs) }) catch "") else "off";
            aops.runText("anim.onion", t);
        }
        bkit.beginPair(z);
        if (act(bkit.button(z, "Motion Paths", ""))) aops.runText("anim.motion_paths", "");
        if (act(bkit.button(z, "Clear Paths", ""))) aops.runText("anim.motion_paths", "clear");
        bkit.endPair(z);
        z.spacer(.px(2));
    }
}

fn keyPath(path: []const u8) void {
    aops.runText("anim.key", path);
}

/// I over a field, Insert Keyframe of its menu: true when it keyed it.
pub fn fieldKey(e: *const wg.E) bool {
    if (e.kind != .number and e.kind != .color) return false;
    const ai = scene.active orelse return false;
    const o = &scene.objects[ai];
    var b: [160]u8 = undefined;
    switch (e.path) {
        .none => return false,
        .transform => |k| keyPath(std.fmt.bufPrint(&b, "{s}:{s}", .{ o.name(), anim.obj_props[k] }) catch return false),
        .modifier => |d| {
            if (d.index >= o.mods.n) return false;
            const ps = mods.params(o.mods.m[d.index].kind);
            if (d.param >= ps.len) return false;
            keyPath(std.fmt.bufPrint(&b, "modifier:{s}:{d}:{s}", .{ o.name(), d.index, ps[d.param].name }) catch return false);
        },
        .shape => |k| {
            const sk = shape.of(ai) orelse return false;
            if (k >= sk.h.n) return false;
            keyPath(std.fmt.bufPrint(&b, "shape:{s}:{s}", .{ o.name(), shape.name(&sk.h.keys[k]) }) catch return false);
        },
        .text => |k| keyPath(std.fmt.bufPrint(&b, "text:{s}:{s}", .{ o.name(), @import("text3d.zig").keyName(k) }) catch return false),
        .material => |nm| {
            const p = material.paramOfLabel(e.name()) orelse return false;
            const comps = material.params[p].comps;
            if (comps == 1) {
                keyPath(std.fmt.bufPrint(&b, "material:{s}:{s}", .{ nm, material.params[p].name }) catch return false);
            } else for (0..comps) |c| {
                keyPath(std.fmt.bufPrint(&b, "material:{s}:{s}:{d}", .{ nm, material.params[p].name, c }) catch return false);
            }
        },
    }
    return true;
}
