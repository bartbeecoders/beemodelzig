// The redo panel, as the original's redo.s: the last mesh tool's values at the
// bottom left of the viewport. Drag one, Ctrl+wheel, or click and type (an
// expression too), or F9 for all of them on the command line, or
// edit.redo_last "values": the tool runs again from the mesh it began with, and
// it all stays one undo step. A new step, an undo or leaving the object ends it.
const std = @import("std");
const m = @import("math.zig");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const host = @import("zuihost.zig");
const scene = @import("scene.zig");
const em = @import("editmesh.zig");
const undo = @import("undo.zig");
const xform = @import("xform.zig");
const mo = @import("meshops.zig");
const mo2 = @import("meshops2.zig");

const Rect = gfx.Rect;
const A = @import("alloc.zig").A;

pub const Op = enum { extrude, extrude_individual, inset, bevel, loopcut, merge_distance, spin };

const Kind = enum { float, int, hidden, axis };
const Param = struct { name: []const u8, kind: Kind, step: f32, min: f32 };

fn params(op: Op) []const Param {
    return switch (op) {
        .extrude, .extrude_individual => &.{.{ .name = "Distance", .kind = .float, .step = 0.01, .min = -1e9 }},
        .inset => &.{.{ .name = "Thickness", .kind = .float, .step = 0.005, .min = 0 }},
        .bevel => &.{ .{ .name = "Width", .kind = .float, .step = 0.005, .min = 0 }, .{ .name = "Segments", .kind = .int, .step = 0.1, .min = 1 } },
        .loopcut => &.{ .{ .name = "", .kind = .hidden, .step = 0, .min = 0 }, .{ .name = "", .kind = .hidden, .step = 0, .min = 0 }, .{ .name = "Cuts", .kind = .int, .step = 0.1, .min = 1 } },
        .merge_distance => &.{.{ .name = "Distance", .kind = .float, .step = 0.0005, .min = 0 }},
        .spin => &.{ .{ .name = "Steps", .kind = .int, .step = 0.1, .min = 1 }, .{ .name = "Angle", .kind = .float, .step = 1, .min = -3600 }, .{ .name = "Axis", .kind = .axis, .step = 1, .min = 0 } },
    };
}

fn title(op: Op) []const u8 {
    return switch (op) {
        .extrude => "Extrude",
        .extrude_individual => "Extrude Individual Faces",
        .inset => "Inset Faces",
        .bevel => "Bevel",
        .loopcut => "Loop Cut",
        .merge_distance => "Merge by Distance",
        .spin => "Spin",
    };
}

var cur: ?Op = null;
var vals: [6]f32 = @splat(0);
/// Set, waiting for its undo step.
var fresh = false;
var step: usize = 0;
var oid: u32 = 0;
/// What the tool began with, and the selection then.
var base_mesh: ?u16 = null;
var base_sel: []bool = &.{};

// --- what the tools report ---------------------------------------------------

/// A tool is about to change the mesh.
pub fn before() void {
    if (!em.active) return;
    base_mesh = scene.objects[em.obj].mesh;
    if (base_sel.len > 0) A.free(base_sel);
    base_sel = A.dupe(bool, em.sel) catch &.{};
}

/// The selection the tool began with, when before() came after it.
pub fn takeSelection(s: []const bool) void {
    if (base_sel.len > 0) A.free(base_sel);
    base_sel = A.dupe(bool, s) catch &.{};
}

/// It did: these are its values (the step comes when the input ends).
pub fn set(op: Op, v: []const f32) void {
    if (!em.active or base_mesh == null) return;
    cur = op;
    for (v, 0..) |x, i| vals[i] = x;
    fresh = true;
    oid = scene.objects[em.obj].oid;
    app.dirty = true;
}

/// The modal extrude ended: along the normal still, or moved anywhere else.
pub fn cancel() void {
    cur = null;
    fresh = false;
}

/// mesh.extrude <distance>: no modal. The tool's before() has run.
pub fn extrudeBy(dir: m.V3, d: f32) void {
    moveAlong(dir, d);
    set(.extrude, &.{d});
}

/// undo.sync made a step: the tool's, or a new one that ends the panel.
pub fn onStep() void {
    if (fresh) {
        fresh = false;
        step = undo.current();
    } else cur = null;
}

/// undo.sync found nothing changed.
pub fn noStep() void {
    if (fresh) cancel();
}

fn valid() bool {
    const op = cur orelse return false;
    _ = op;
    if (fresh or !em.active or undo.current() != step) return false;
    if (xform.active or mo.modal != null or em.obj >= scene.count or scene.objects[em.obj].oid != oid) return false;
    const b = base_mesh orelse return false;
    return scene.meshes[b] != null;
}

// --- running it again --------------------------------------------------------

/// The new faces along their direction, as the modal move left them.
fn moveAlong(dir: m.V3, dist: f32) void {
    if (!em.beginMove()) return;
    const w = scene.world(em.obj);
    const inv = m.inverseAffine(w);
    const vs = em.workVerts();
    for (em.sel, 0..) |on, i| {
        if (on and i < vs.len) vs[i] = m.xform(inv, m.add(m.xform(w, vs[i]), m.scale(dir, dist)));
    }
    em.endMove(true, "Extrude");
}

fn run(op: Op) ?[]const u8 {
    const v = vals;
    switch (op) {
        .extrude => {
            const dir = (mo.extrude() catch null) orelse return "nothing to extrude";
            moveAlong(dir, v[0]);
        },
        .extrude_individual => if (!(mo.extrudeIndividual(v[0]) catch false)) return "it failed",
        .inset => if (!(mo.inset(v[0]) catch false)) return "it failed",
        .bevel => return mo2.bevel(v[0], @intFromFloat(std.math.clamp(v[1], 1, 32))) catch "it failed",
        .loopcut => return mo2.loopCut(@intFromFloat(v[0]), @intFromFloat(v[1]), @intFromFloat(std.math.clamp(v[2], 1, 64))) catch "it failed",
        .merge_distance => _ = (mo2.mergeDistance(v[0]) catch null) orelse return "it failed",
        .spin => return mo2.spin(@intFromFloat(std.math.clamp(v[0], 1, 256)), v[1], @intFromFloat(std.math.clamp(v[2], 0, 2))) catch "it failed",
    }
    return null;
}

/// From the mesh and selection it began with, without a new undo step.
fn rerun() void {
    const op = cur orelse return;
    scene.objects[em.obj].mesh = base_mesh;
    em.validate();
    const n = @min(em.sel.len, base_sel.len);
    @memcpy(em.sel[0..n], base_sel[0..n]);
    if (run(op)) |why| app.toast(.warn, "{s}: {s}", .{ title(op), why });
    em.version +%= 1;
    undo.replaceCurrent();
    step = undo.current();
    app.dirty = true;
}

fn clampTo(p: Param, x: f32) f32 {
    if (p.kind == .axis) return std.math.clamp(@round(x), 0, 2);
    const y = @max(x, p.min);
    return if (p.kind == .int) @round(y) else y;
}

/// edit.redo_last "values": new values in order, missing ones keep the old.
pub fn opLast(arg: []const u8) void {
    if (!valid()) return app.log("  nothing to adjust: run an operator with values first (extrude, inset, bevel...)", .{});
    const ps = params(cur.?);
    var it = std.mem.tokenizeAny(u8, arg, " \"");
    var k: usize = 0;
    while (k < ps.len) : (k += 1) {
        const t = it.next() orelse break;
        var x: f32 = undefined;
        if (t.len == 1 and (t[0] | 0x20) >= 'x' and (t[0] | 0x20) <= 'z') {
            x = @floatFromInt((t[0] | 0x20) - 'x');
        } else {
            x = @import("expr.zig").eval(t) orelse continue;
            if (!std.math.isFinite(x)) continue;
        }
        vals[k] = clampTo(ps[k], x);
    }
    rerun();
}

fn writeVal(w: *std.Io.Writer, p: Param, x: f32) void {
    switch (p.kind) {
        .axis => w.writeByte("xyz"[@intFromFloat(std.math.clamp(x, 0, 2))]) catch {},
        .float => {
            // 4 decimals, trailing zeros trimmed
            var b: [32]u8 = undefined;
            w.writeAll(ui.fmtDec(&b, x, 4)) catch {};
        },
        else => w.print("{d}", .{@as(i64, @intFromFloat(x))}) catch {},
    }
}

/// F9: the values on the command line.
pub fn opPrompt() void {
    if (!valid()) return app.log("  nothing to adjust: run an operator with values first (extrude, inset, bevel...)", .{});
    var b: [160]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    w.writeAll("edit.redo_last ") catch {};
    for (params(cur.?), 0..) |p, i| {
        if (i > 0) w.writeByte(' ') catch {};
        writeVal(&w, p, vals[i]);
    }
    @import("editors.zig").prefillConsole(w.buffered());
}

// --- the panel ---------------------------------------------------------------

const PANEL_W = 236;
const ROW_H = 22;

/// Right of the orientation gizmo, at the bottom of the viewport being drawn:
/// a Zui part over the view (zuihost.beginPart), so a click on it stays on it.
pub fn draw(i: i16, r: Rect) void {
    if (!valid() or i != app.viewportArea()) return;
    const op = cur.?;
    const ps = params(op);
    var rows: i32 = 0;
    for (ps) |p| rows += @intFromBool(p.kind != .hidden);
    if (rows == 0) return;
    const h = (rows + 1) * ROW_H + 26;
    const x = r.x + 100;
    const y = r.bottom() - 12 - h;
    if (y < r.y or x + PANEL_W > r.right()) return;
    const pr = Rect{ .x = x, .y = y, .w = PANEL_W, .h = h };
    const z = host.beginPart("redo", 0, pr) orelse return;
    defer host.endPart(z);
    const t = ui.th;
    z.drawRect(.{ .rect = host.zr(pr), .fill = host.col(t.drop_bg) });
    z.drawText(.{ .x = @floatFromInt(x + 10), .y = @floatFromInt(y + 4) }, host.col(t.accent), title(op));
    ui.record("redo", title(op), pr, true);
    var changed = false;
    var row: i32 = 0;
    for (ps, 0..) |p, k| {
        if (p.kind == .hidden) continue;
        const ty = y + row * ROW_H;
        z.drawText(.{ .x = @floatFromInt(x + 10), .y = @floatFromInt(ty + 28) }, host.col(t.text_dim), p.name);
        const fr = Rect{ .x = x + 110, .y = ty + 27, .w = PANEL_W - 120, .h = ROW_H - 2 };
        // BeeModel's record of a value: "Thickness 0.1", as the tests look for it
        var rb: [40]u8 = undefined;
        var w = std.Io.Writer.fixed(&rb);
        w.print("{s} ", .{p.name}) catch {};
        writeVal(&w, p, vals[k]);
        ui.record("redo", w.buffered(), fr, true);
        host.at(z, p.name, k, fr);
        defer z.endRegion();
        var nb: [40]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "##{s}", .{p.name}) catch p.name;
        if (p.kind == .axis) {
            var sel: usize = @intFromFloat(std.math.clamp(vals[k], 0, 2));
            if (z.segmented(name, &sel, &.{ .{ .label = "X" }, .{ .label = "Y" }, .{ .label = "Z" } }, .{ .width = .fill }).changed) {
                vals[k] = @floatFromInt(sel);
                changed = true;
            }
        } else {
            var v: f64 = vals[k];
            const f = z.numberField(name, &v, .{
                .width = .fill,
                .min = p.min,
                .step = p.step,
                // BeeModel's fields: a pixel of drag is a step
                .drag_step = p.step,
                .decimals = if (p.kind == .int) 0 else 4,
                .evaluator = &@import("bkit.zig").evaluator,
            });
            if (f.changed) {
                const nv = clampTo(p, @floatCast(v));
                if (nv != vals[k]) {
                    vals[k] = nv;
                    changed = true;
                }
            }
        }
        row += 1;
    }
    z.pushMetric(.font_size, 13);
    z.drawText(.{ .x = @floatFromInt(x + 10), .y = @floatFromInt(y + rows * ROW_H + 30) }, host.col(t.text_dim), "drag or type a value, F9: all");
    z.popStyle();
    if (changed) rerun();
}

test "the original's parameters" {
    try std.testing.expectEqual(1, params(.extrude).len);
    try std.testing.expectEqual(0.005, params(.inset)[0].step);
    try std.testing.expectEqual(Kind.hidden, params(.loopcut)[1].kind);
    try std.testing.expectEqual(Kind.axis, params(.spin)[2].kind);
    try std.testing.expectEqual(@as(f32, 0), clampTo(params(.inset)[0], -3));
    try std.testing.expectEqual(@as(f32, 1), clampTo(params(.bevel)[1], 0.2));
    try std.testing.expectEqual(@as(f32, 2), clampTo(params(.spin)[2], 9));
}
