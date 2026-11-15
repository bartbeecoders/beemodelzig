// The Rig tab of Properties (animui.s): the armature's bones and the active
// bone's pose, the constraints on the active object, Parent to Armature.
const std = @import("std");
const zui = @import("zui");
const gfx = @import("gfx.zig");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const ui = @import("ui.zig");
const anim = @import("anim.zig");
const scene = @import("scene.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const arm = @import("arm.zig");
const rig = @import("rig.zig");
const aops = @import("animops.zig");
const editors = @import("editors.zig");
const Rect = gfx.Rect;

const MAXROW = 32;

fn poseSet(ai: usize, k: usize, what: []const u8, v: *const [3]f32, rad: bool) void {
    _ = ai;
    const b = 180.0 / std.math.pi;
    const s: f32 = if (rad) b else 1;
    var nb: [96]u8 = undefined;
    const x = &arm.of(scene.active.?).?.bones[k];
    aops.runText("arm.pose", std.fmt.bufPrint(&nb, "{s} {s} {d} {d} {d}", .{ x.nameOf(), what, v[0] * s, v[1] * s, v[2] * s }) catch "");
    undo.label("Pose");
}

pub fn props(i: i16, bd: Rect, y0: i32) i32 {
    var f = bkit.Flow.begin("rig", @intCast(i), bd, y0);
    if (f.z) |z| describe(z);
    return f.end();
}

fn describe(z: *zui.Ui) void {
    const ai = scene.active orelse return;
    const o = &scene.objects[ai];
    // ---- bones ----
    if (bkit.section(z, "Bones", &editors.sec_open[20])) {
        if (arm.of(ai)) |b| {
            var k: usize = 0;
            while (k < b.n and k < 64) : (k += 1) {
                const x = &b.bones[k];
                z.pushIdInt(k);
                defer z.popId();
                const r = bkit.row(z, x.nameOf(), k == b.act, .{ .tip = "Make it the active bone", .tip_title = "Bone", .indent = if (x.parent >= 0) 12 else 0 });
                if (r.clicked) aops.runText("arm.select_bone", x.nameOf());
            }
            // the active bone's pose
            if (b.act < b.n) {
                const k2: usize = b.act;
                const x = &b.bones[k2];
                var tb: [48]u8 = undefined;
                z.spacer(.px(2));
                z.label(std.fmt.bufPrint(&tb, "Pose of {s}", .{x.nameOf()}) catch "", .{ .color = host.col(ui.th.accent_fg) });
                const rows = [_]struct { w: []const u8, l: []const u8, rad: bool, step: f32, dec: u8 }{
                    .{ .w = "loc", .l = "Location", .rad = false, .step = 0.01, .dec = 3 },
                    .{ .w = "rot", .l = "Rotation", .rad = true, .step = 0.5, .dec = 1 },
                    .{ .w = "scale", .l = "Scale", .rad = false, .step = 0.005, .dec = 3 },
                };
                for (rows, 0..) |rw, ri| {
                    const src: *const [3]f32 = switch (ri) {
                        0 => &x.loc,
                        1 => &x.rot,
                        else => &x.scale,
                    };
                    var v = src.*;
                    const s: f32 = if (rw.rad) 180.0 / std.math.pi else 1;
                    for (&v) |*c| c.* *= s;
                    if (bkit.vec3Row(z, rw.l, &v, .{ .step = rw.step, .min = -1e6, .max = 1e6, .decimals = rw.dec, .suffix = if (rw.rad) "\u{00B0}" else "" })) {
                        var t = v;
                        for (&t) |*c| c.* /= s;
                        poseSet(ai, k2, rw.w, &t, rw.rad);
                    }
                }
            }
        } else {
            bkit.info(z, "Select an armature for its bones.");
            if (o.kind.isMesh() and o.mesh != null) {
                if (bkit.button(z, "Parent to Armature...", "Skin this mesh to an armature with automatic weights").clicked) ops.runId("arm.parent");
            }
        }
        z.spacer(.px(4));
    }
    // ---- constraints on it ----
    if (bkit.section(z, "Constraints", &editors.sec_open[21])) {
        var shown: usize = 0;
        if (anim.cur) |b| {
            var k: usize = 0;
            while (k < b.h.ncon and k < MAXROW) : (k += 1) {
                const c = &b.h.con[k];
                if (c.owner != o.oid) continue;
                z.pushIdInt(k);
                defer z.popId();
                var t: [96]u8 = undefined;
                const lb: []const u8 = if (c.ctype < rig.labels.len) rig.labels[c.ctype] else "?";
                const tn: []const u8 = if (scene.findOid(c.target)) |g| scene.objects[g].name() else "";
                const s = if (tn.len > 0) std.fmt.bufPrint(&t, "{s} -> {s}", .{ lb, tn }) catch lb else lb;
                z.beginHorizontal(.{ .spacing = 4 });
                bkit.info(z, s);
                const xb = z.button("x", .{ .width = .px(18), .variant = .flat });
                z.tooltipRich(xb, .{ .title = "x", .body = "Remove the constraint" });
                z.endHorizontal();
                if (xb.clicked) {
                    var a: [16]u8 = undefined;
                    aops.runText("constraint.remove", std.fmt.bufPrint(&a, "{d}", .{k + 1}) catch "");
                    break;
                }
                z.beginHorizontal(.{ .spacing = 4 });
                var muted = c.flags & rig.F_MUTE != 0;
                if (bkit.checkRow(z, "Mute", &muted, "").changed) {
                    var a: [32]u8 = undefined;
                    aops.runText("constraint.set", std.fmt.bufPrint(&a, "{d} mute {d}", .{ k + 1, @intFromBool(muted) }) catch "");
                }
                var inf = c.infl;
                if (bkit.numberRow(z, "Influence", &inf, .{ .step = 0.005, .min = 0, .max = 1, .decimals = 2 }).changed) {
                    rig.setInfluence(k, inf);
                    undo.label("Constraint");
                }
                z.endHorizontal();
                shown += 1;
            }
        }
        if (shown == 0) bkit.info(z, "Constraints make an object follow, aim at or stay near another.");
        if (bkit.button(z, "Add Constraint...", "").clicked) ops.runId("constraint.add");
    }
}
