// The CAD tab of the Properties editor and the CAD document's commands
// (cadui.s): parameters, units, the kernel switch, the feature list
// (feature.zig: a row per feature, its value, On, up / down, what failed, and
// the feature buttons), measuring. The mechanism's joints come with their
// layer (mech.s): until then their row shows what it will hold, greyed.
// Sketches add their section in `sketchSection` below.
const std = @import("std");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const zui = @import("zui");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const cad = @import("cad.zig");
const measure = @import("measure.zig");
const print = @import("print.zig");
const Impl = ops.Impl;
const Rect = gfx.Rect;

pub const list = .{
    .{ "param.set", Impl{ .run = cad.opParamSet } },
    .{ "param.remove", Impl{ .run = cad.opParamRemove } },
    .{ "param.list", Impl{ .run = cad.opParamList } },
    .{ "scene.units", Impl{ .run = cad.opSceneUnits } },
    .{ "cad.kernel", Impl{ .run = cad.opKernel, .check = cad.isKernel } },
    .{ "object.measure", Impl{ .run = measure.opObjMeasure } },
    .{ "view.measure", Impl{ .run = measure.opViewMeasure, .check = measure.isOn, .ctx = .view3d } },
    .{ "mesh.print_check", Impl{ .run = print.opPrintCheck } },
    .{ "view.show_thickness", Impl{ .run = print.opShowThin, .check = print.isThin } },
    .{ "mesh.print_show", Impl{ .run = print.opShow } },
    .{ "file.export_3mf", Impl{ .run = @import("fab.zig").opExport3mf } },
    .{ "file.export_pdf", Impl{ .run = @import("drawing.zig").opExportPdf } },
    .{ "drawing.options", Impl{ .run = @import("drawing.zig").opOptions } },
};

/// Run an operator with this argument (run_arg).
fn runArg(id: []const u8, arg: []const u8) void {
    @import("animops.zig").runText(id, arg);
}

/// A hint, wrapped onto as many lines as it needs (pnl_hint), recorded as
/// `info`.
fn hint(z: *zui.Ui, s: []const u8) void {
    z.pushMetric(.font_size, SMALL); // (pnl_hint: FONT_SMALL)
    defer z.popStyle();
    z.wrappedText(s, .{ .color = host.col(ui.th.text_dim) });
    ui.record("info", s, host.rectOf(z.lastRect()), true);
}

/// FONT_SMALL's size, for hints; rows 4 apart, as BeeModel's 26-unit pitch.
const SMALL = 12;
const ROW_GAP: zui.Vec2 = .{ .x = 6, .y = 4 };

/// A small icon button (WGF_ICON|WGF_COMPACT), recorded as `icon:<name>`.
fn iconButton(z: *zui.Ui, ic: @import("icons.zig").Icon, name: []const u8, tip: []const u8) bool {
    var nb: [64]u8 = undefined;
    const b = z.button(std.fmt.bufPrint(&nb, "##{s}", .{name}) catch "##icon", .{ .icon = host.icon(ic), .width = .px(18), .variant = .flat });
    ui.record("icon", name, host.rectOf(b.rect), true);
    z.tooltipRich(b, .{ .title = name, .body = tip });
    return b.clicked;
}

/// An expression's text field (bkit.textRow) with its tooltip; the new
/// text on Enter. Recorded as `text:<its text>` here too (the tests read the
/// feature rows' records in order).
fn exprField(z: *zui.Ui, title: []const u8, text: []const u8, tip: []const u8, record: bool) ?[]const u8 {
    var nb: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&nb, "##{s}", .{title}) catch "##expr";
    const typed = bkit.textRow(z, name, text, "");
    const r = z.lastRect();
    if (record) ui.record("text", text, host.rectOf(r), true);
    z.tooltipRich(.{ .id = z.id(name), .rect = r, .hovered = r.contains(z.input.mouse_pos) and z.hot == z.id(name) }, .{ .title = title, .body = tip });
    return typed;
}

/// Dim text at the right of what is left of the row, recorded as `info`.
fn rightInfo(z: *zui.Ui, s: []const u8) void {
    z.label(s, .{ .color = host.col(ui.th.text_dim), .width = .fill, .alignment = .end });
    ui.record("info", s, host.rectOf(z.lastRect()), true);
}

fn unitLabel(k: usize) []const u8 {
    return cad.units_labels[k];
}

/// The CAD tab: y below it. Parameters, then the sketches' section (the
/// sketch layer's, drawn by BeeModel), then features, mechanism, measure.
pub fn props(i: i16, bd: Rect, y0: i32) i32 {
    var f = bkit.Flow.begin("cad.params", @intCast(i), bd, y0);
    if (f.z) |z| describeParams(z, bd);
    var y = f.end();
    // ---- sketches (the sketch layer) ----
    y = sketchSection(i, bd, y);
    var g = bkit.Flow.begin("cad.features", @intCast(i), bd, y);
    if (g.z) |z| describeRest(z, bd);
    return g.end();
}

fn describeParams(z: *zui.Ui, bd: Rect) void {
    z.pushMetric(.item_spacing, ROW_GAP);
    defer z.popStyle();
    // (the part's own column took the style's gap before the push)
    z.beginVertical(.{ .width = .fill });
    defer z.endVertical();
    var vb: [32]u8 = undefined;
    bkit.heading(z, "Parameters");
    if (cad.paramCount() == 0) hint(z, "Parameters are named values (with units) that dimensions use.");
    const w: f32 = @floatFromInt(bd.w);
    // (the rows 1 apart, as BeeModel's 22-unit list)
    z.beginVertical(.{ .width = .fill, .spacing = 1 });
    var k: usize = 0;
    while (k < cad.paramCount() and k < cad.MAX_PARAMS) : (k += 1) {
        const name = cad.paramName(k);
        z.pushIdInt(k);
        defer z.popId();
        z.beginHorizontal(.{ .spacing = 4 });
        z.label(name, .{ .width = .px(w * 0.28 - 4) });
        z.beginHorizontal(.{ .width = .px(w * 0.34), .spacing = 0 });
        const typed = exprField(z, "cad.param", cad.paramExpr(k), "The parameter's expression: a number with units, other parameters, + - * / ( ) (Enter)", false);
        z.endHorizontal();
        // "= value", right-aligned before the x
        var tb: [40]u8 = undefined;
        const v = cad.paramValue(k) orelse 0;
        rightInfo(z, std.fmt.bufPrint(&tb, "= {s}", .{cad.fmtVal3(&vb, @floatCast(v))}) catch "");
        const removed = iconButton(z, .close, "cad.param.remove", "Remove this parameter");
        z.endHorizontal();
        if (typed) |t| {
            var a: [160]u8 = undefined;
            runArg("param.set", std.fmt.bufPrint(&a, "{s} {s}", .{ name, t }) catch "");
            break; // (the list may have changed)
        }
        if (removed) {
            var a: [32]u8 = undefined;
            runArg("param.remove", std.fmt.bufPrint(&a, "{s}", .{name}) catch "");
            break; // (the list changed)
        }
    }
    z.endVertical();
    _ = bkit.opButton(z, "param.set", .{ .label = "Add Parameter..." });
    // the units: the caption on the left half, the list on the right
    bkit.beginPair(z);
    z.label("Scene units", .{ .color = host.col(ui.th.text_dim), .width = .fill });
    var uk: usize = 0;
    while (uk < 3 and cad.unitMm() != cad.units_mm[uk]) uk += 1;
    if (bkit.choice(z, "##Scene units", &uk, 4, unitLabel, "What one scene unit is (typed lengths with units convert)")) runArg("scene.units", cad.units_names[uk]);
    bkit.endPair(z);
    var kon = cad.kernel();
    if (bkit.checkRow(z, "Exact B-rep solids", &kon, "").changed) runArg("cad.kernel", if (kon) "on" else "off");
    z.spacer(.px(4)); // (the 8 before a heading, with the row gap)
}

fn describeRest(z: *zui.Ui, bd: Rect) void {
    z.pushMetric(.item_spacing, ROW_GAP);
    defer z.popStyle();
    // (the part's own column took the style's gap before the push)
    z.beginVertical(.{ .width = .fill });
    defer z.endVertical();
    var vb: [32]u8 = undefined;
    // ---- features (feature.zig) ----
    bkit.heading(z, "Features");
    if (cad.featCount() == 0) hint(z, "Make a sketch (Add > Sketch), then Pad it into a part.");
    featureRows(z, bd);
    _ = bkit.opButton(z, "cad.sketch", .{ .label = "New Sketch...", .primary = true }); // (WGF_PRIMARY)
    const feats = [_][2][]const u8{
        .{ "cad.pad", "Pad" },         .{ "cad.pocket", "Pocket" },   .{ "cad.revolve", "Revolve" },
        .{ "cad.hole", "Hole" },       .{ "cad.shell", "Shell" },     .{ "cad.fillet", "Fillet" },
        .{ "cad.chamfer", "Chamfer" }, .{ "cad.pattern", "Pattern" }, .{ "cad.infill", "Infill" },
    };
    var row: usize = 0;
    while (row < 3) : (row += 1) {
        z.beginHorizontal(.{ .spacing = 4 });
        defer z.endHorizontal();
        for (feats[row * 3 ..][0..3]) |ft| {
            // (never greyed, as the original's: a click says why when it cannot run)
            const oi = ops.byId(ft[0]).?;
            if (bkit.button(z, ft[1], @import("catalog.zig").entries[oi].doc).clicked) ops.run(oi);
        }
    }
    z.spacer(.px(4)); // (the 8 before a heading, with the row gap)

    // ---- mechanism (mech.s: the last layer) ----
    bkit.heading(z, "Mechanism");
    {
        const mech = @import("mech.zig");
        const nj = mech.count();
        if (nj == 0) hint(z, "Joints make parts move: a revolute turns, a slider slides.");
        var k: usize = 0;
        while (k < nj and k < 32) : (k += 1) {
            z.pushIdInt(k);
            defer z.popId();
            // "1 Revolute Part", its value at the right, the expression under it
            var tb: [64]u8 = undefined;
            const rev = mech.typeOf(k) == 1;
            const pn = if (scene.findOid(mech.partOf(k))) |oi| scene.objects[oi].name() else "";
            const s = std.fmt.bufPrint(&tb, "{d} {s}{s}", .{ k + 1, if (rev) "Revolute " else "Slider ", pn }) catch "";
            var vb2: [40]u8 = undefined;
            const v = if (mech.value(k)) |x| x.v else 0;
            const vs = if (rev) (std.fmt.bufPrint(&vb2, "{s} deg", .{cad.fmtVal3(&vb, v * 57.29578)}) catch "") else cad.fmtVal3(&vb2, v);
            z.beginVertical(.{ .width = .fill, .spacing = 0 });
            defer z.endVertical();
            bkit.beginPair(z);
            z.label(s, .{ .width = .fill });
            ui.record("info", s, host.rectOf(z.lastRect()), true);
            rightInfo(z, vs);
            bkit.endPair(z);
            z.beginHorizontal(.{ .spacing = 0 });
            z.spacer(.px(14));
            const typed = exprField(z, "cad.joint.value", mech.exprText(k), "The joint's value: an angle or a distance, an expression of parameters and the frame (Enter)", false);
            z.endHorizontal();
            if (typed) |t| {
                var a: [160]u8 = undefined;
                runArg("mech.set", std.fmt.bufPrint(&a, "{d} value {s}", .{ k + 1, t }) catch "");
                break; // (the rows may have changed)
            }
        }
        _ = bkit.opButton(z, "mech.joint", .{ .label = "Add Joint..." });
        z.spacer(.px(4));
    }

    // ---- measure ----
    bkit.heading(z, "Measure");
    _ = bkit.opButton(z, "view.measure", .{ .label = "Measure Tool" });
    if (bkit.button(z, "Mass Properties", "Volume, area, mass and centre of mass of the active part").clicked) measure.massNow();
    var tb: [96]u8 = undefined;
    switch (measure.value()) {
        .none => {},
        .dist => |d| {
            var w = std.Io.Writer.fixed(&tb);
            w.print("Distance {s} {s}", .{ cad.fmtVal3(&vb, @floatCast(d)), cad.unitName() orelse "units" }) catch {};
            hint(z, w.buffered());
        },
        .angle => |a| {
            const deg: f32 = @as(f32, @floatCast(a)) * 57.29578;
            hint(z, std.fmt.bufPrint(&tb, "Angle {s} deg", .{cad.fmtVal3(&vb, deg)}) catch "");
        },
    }
    // the active part's mass properties: a line per ", " part
    if (scene.active) |a| {
        if (measure.mass_len > 0 and scene.objects[a].oid == measure.mass_oid) {
            var it = std.mem.splitSequence(u8, measure.mass_text[0..measure.mass_len], ", ");
            while (it.next()) |part| hint(z, part);
        }
    }
}

/// The feature list: a row per feature (its health, number, type and body,
/// up / down, its value, On), what is wrong under one that fails (cadui.s).
/// Each row records info, icon up, icon down, text, checkbox in that order
/// (tests/feature.py reads them so).
fn featureRows(z: *zui.Ui, bd: Rect) void {
    const feature = @import("feature.zig");
    const th = ui.th;
    const w: f32 = @floatFromInt(bd.w);
    z.beginVertical(.{ .width = .fill, .spacing = 1 });
    defer z.endVertical();
    var k: usize = 0;
    while (k < feature.count() and k < cad.MAX_FEATS) : (k += 1) {
        const r = feature.rec(k);
        const st = feature.status(k);
        z.pushIdInt(k);
        defer z.popId();
        z.beginHorizontal(.{ .spacing = 4 });
        // health: a dot
        const dot: u32 = if (st == feature.S_OK) th.ok else if (st == feature.S_OFF) COL_TEXT_OFF else COL_REC;
        const dr = z.placeSized(.px(10), .px(18), .{ .x = 10, .y = 18 });
        z.painter().circle(.{ .x = dr.x + 4, .y = dr.y + dr.h / 2 }, 4, host.col(dot));
        // "0 Pad  Body"
        var tb: [96]u8 = undefined;
        var tw = std.Io.Writer.fixed(&tb);
        tw.print("{d} {s}  ", .{ k, feature.typeName(feature.get(r, feature.FT_TYPE)) }) catch {};
        if (scene.findOid(feature.get(r, feature.FT_BODY))) |oi| {
            if (cad.cur.?.fraw[k] & 1 == 0) tw.writeAll(scene.objects[oi].name()) catch {};
        }
        z.label(tw.buffered(), .{ .width = .fill, .color = host.col(if (st == feature.S_OK) th.text else th.text_dim) });
        ui.record("info", tw.buffered(), host.rectOf(z.lastRect()), true);
        // up / down, left of the value
        var moved: ?[]const u8 = null;
        if (iconButton(z, .chevron_up, "cad.feature.up", "Move the feature up: it runs earlier when the part rebuilds")) moved = "up";
        if (iconButton(z, .chevron_down, "cad.feature.down", "Move the feature down: it runs later when the part rebuilds")) moved = "down";
        // the value: its text, or the number
        const s0 = feature.slot(r, 0);
        var vb: [40]u8 = undefined;
        const txt: []const u8 = if (s0[0] == 1) feature.ftoa(&vb, @floatCast(feature.slotVal(s0).?), 3) else std.mem.sliceTo(s0, 0);
        z.beginHorizontal(.{ .width = .px(w * 0.26), .spacing = 0 });
        const typed = exprField(z, "cad.feature.value", txt, "The feature's size: distance, depth, diameter, wall, radius or step - a number or an expression (Enter)", true);
        z.endHorizontal();
        // On
        var on = feature.get(r, feature.FT_FLAGS) & feature.FF_OFF == 0;
        const oc = bkit.checkRow(z, "On", &on, "Suppress the feature (it is skipped when the part rebuilds)");
        ui.record("checkbox", "On", host.rectOf(oc.rect), true);
        z.endHorizontal();
        if (moved) |d| {
            var a: [32]u8 = undefined;
            runArg("cad.feature_move", std.fmt.bufPrint(&a, "{d} {s}", .{ k, d }) catch "");
            break; // (the list changed)
        }
        if (typed) |t| {
            var tc: [96]u8 = undefined;
            const n = @min(t.len, tc.len);
            @memcpy(tc[0..n], t[0..n]);
            _ = feature.feature(@intCast(k), 0, tc[0..n], 0);
            app.dirty = true;
            break;
        }
        if (oc.changed) {
            _ = feature.feature(@intCast(k), 3, null, if (on) 0 else 1);
            app.dirty = true;
            break;
        }
        // what is wrong, under it
        if (st != feature.S_OK and st != feature.S_OFF) {
            z.beginHorizontal(.{ .spacing = 0 });
            z.spacer(.px(14));
            z.label(feature.statusName(st), .{ .color = host.col(COL_REC), .width = .fill });
            ui.record("info", feature.statusName(st), host.rectOf(z.lastRect()), true);
            z.endHorizontal();
        }
    }
}

/// COL_REC: what failed; COL_TEXT_OFF: suppressed (the original's constants).
const COL_REC: u32 = 0xe5484d;
const COL_TEXT_OFF: u32 = 0x5f6672;

/// The sketches' part of the CAD tab (the sketch layer fills it in).
pub var sketch_hook: ?*const fn (i16, Rect, i32) i32 = null;

fn sketchSection(i: i16, bd: Rect, y: i32) i32 {
    if (sketch_hook) |h| return h(i, bd, y);
    return y;
}
