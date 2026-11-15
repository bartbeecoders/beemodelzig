//! The Landscape tab of the Properties editor (landui.s land_props), shown
//! when the active object is a landscape. Under a line of what it is
//! (samples, size, the heights' range, layers, the last evaluation), sections
//! that fold:
//!   - Size and Samples (closed at first): size, samples a side, display
//!     detail (landscape.set).
//!   - Layers: the stack as a list, top first (an eye to hide one, the row to
//!     pick it); the one picked has its strength and its own values; Add (a
//!     list of the types), Up, Down, Remove (landscape.layer).
//!   - Paint: the paint layers with their colours; the one picked has its
//!     colour, friction, bounce and rule (heights, slopes); Add, Remove, Auto
//!     Paint (landscape.paint).
//!   - Sea and Files (closed at first): Add Sea, Import Heightmap, Export
//!     Heights, To Mesh, Split into Tiles.
//! A value changed in a field runs the operator quietly, the step named
//! "Landscape" (the field's own undo step, as the original's); buttons and
//! lists run the operator (its undo step). The operator's words are made as
//! the original's are (fmt_val3: three decimals at most), so a field gives the
//! very values the original's does.
//!
//! On Zui (bkit.Flow in the tab's page, which editors.zig scrolls), at the
//! original's pitch (22 a row, 4 between): the lists are drop-downs
//! (recorded as `enum` too, their captions as `caption`), the layer rows
//! bkit.row with their eye a check box without a label, the paint colour
//! bkit.colourRow.
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
const la = @import("landscape.zig");
const cad = @import("cad.zig");
const Rect = gfx.Rect;

const l_types = [_][]const u8{ "Generate", "Erode", "Terrace", "Sculpted", "Flatten", "Heightmap" };
const l_addl = [_][]const u8{ "Add Layer...", "Generate", "Erode", "Terrace", "Sculpted", "Flatten" };
const kw_types = [_][]const u8{ "generate", "erode", "terrace", "sculpted", "flatten" };
const l_noise = [_][]const u8{ "fBm", "Ridged", "Billow", "Cells" };
const kw_noise = [_][]const u8{ "fbm", "ridged", "billow", "cells" };
const l_mats = [_][]const u8{ "Rock", "Grass", "Sand", "Snow", "Dirt", "Gravel", "Moss", "Mud" };
const l_addp = [_][]const u8{ "Add Paint Layer...", "Rock", "Grass", "Sand", "Snow", "Dirt", "Gravel", "Moss", "Mud" };
const kw_mats = [_][]const u8{ "rock", "grass", "sand", "snow", "dirt", "gravel", "moss", "mud" };
const l_res = [_][]const u8{ "65", "129", "257", "513", "1025", "2049", "4097" };
const res_n = [_]u32{ 65, 129, 257, 513, 1025, 2049, 4097 };

/// Each layer type's keys (by slot).
const pk_types = [6][]const []const u8{
    &.{ "noise", "seed", "scale", "height", "octaves", "island", "offset" },
    &.{ "droplets", "rate", "seed", "thermal", "talus" },
    &.{ "steps", "smooth" },
    &.{},
    &.{"height"},
    &.{},
};

/// A layer value's widget (landui.s lv_*): its kind, the slot, label, range.
const VK = enum { float, int, noise, toggle };
const V = struct { k: VK, slot: u8, label: []const u8 = "", lo: f32 = 0, hi: f32 = 0, step: f32 = 0.01, dec: u8 = 3, tip: []const u8 = "" };
const lv_gen = [_]V{
    .{ .k = .noise, .slot = 0, .tip = "fBm: rolling. Ridged: sharp crests. Billow: puffy. Cells: Voronoi" },
    .{ .k = .int, .slot = 1, .label = "Seed", .lo = 0, .hi = 100000, .step = 0.1 },
    .{ .k = .float, .slot = 2, .label = "Scale (features across)", .lo = 0.1, .hi = 100, .step = 0.01, .dec = 2 },
    .{ .k = .float, .slot = 3, .label = "Height (m)", .lo = -10000, .hi = 10000, .step = 0.2, .dec = 1 },
    .{ .k = .int, .slot = 4, .label = "Octaves", .lo = 1, .hi = 12, .step = 0.05, .tip = "Layers of detail" },
    .{ .k = .toggle, .slot = 5, .label = "Down to the edges (an island)" },
    .{ .k = .float, .slot = 6, .label = "Offset (m)", .lo = -10000, .hi = 10000, .step = 0.2, .dec = 1, .tip = "Moved up or down" },
};
const lv_ero = [_]V{
    .{ .k = .int, .slot = 0, .label = "Droplets (0: N x N / 8)", .lo = 0, .hi = 100000000, .step = 50 },
    .{ .k = .float, .slot = 1, .label = "Rate", .lo = 0, .hi = 1, .step = 0.005, .dec = 3, .tip = "How much a droplet carries off" },
    .{ .k = .int, .slot = 2, .label = "Seed", .lo = 0, .hi = 100000, .step = 0.1 },
    .{ .k = .int, .slot = 3, .label = "Thermal passes", .lo = 0, .hi = 100, .step = 0.05, .tip = "Material slides where it is steeper than the talus" },
    .{ .k = .float, .slot = 4, .label = "Talus (deg)", .lo = 0, .hi = 90, .step = 0.1, .dec = 1 },
};
const lv_ter = [_]V{
    .{ .k = .int, .slot = 0, .label = "Steps", .lo = 1, .hi = 100, .step = 0.05 },
    .{ .k = .float, .slot = 1, .label = "Smooth", .lo = 0, .hi = 1, .step = 0.005, .dec = 3, .tip = "The risers' share of a step" },
};
const lv_fla = [_]V{
    .{ .k = .float, .slot = 0, .label = "Level (m)", .lo = -10000, .hi = 10000, .step = 0.1, .dec = 2 },
};
const lv_types = [6][]const V{ &lv_gen, &lv_ero, &lv_ter, &.{}, &lv_fla, &.{} };

// the landscape's values, as shown
var lu_size: f32 = 0;
var lu_res: u32 = 0;
var lu_det: u32 = 0;
/// The layer picked.
pub var lu_sel: u32 = 0;
var lu_str: f32 = 0;
var lu_pf: [10]f32 = @splat(0);
var lu_pi: [10]i32 = @splat(0);
var lu_type: u32 = 0;
/// The paint layer picked.
pub var lp_sel: u32 = 0;
var lp_col: u32 = 0;
var lp_fric: f32 = 0;
var lp_bounce: f32 = 0;
var lp_h: [2]f32 = .{ 0, 0 };
var lp_s: [2]f32 = .{ 0, 0 };

var col: Rect = .{};

// sections: open or not (WGF_SHUT: closed at first)
const S_LAND = 0;
const S_LAY = 1;
const S_PAINT = 2;
const S_MORE = 3;
var sec_open = [4]bool{ false, true, true, false };

/// land_is_active: the active object's landscape block, or null.
pub fn active() ?*la.Block {
    const a = scene.active orelse return null;
    return la.ofIndex(a);
}

// ---- running the operators ---------------------------------------------------------

var arg_buf: [192]u8 = undefined;

/// lu_exec: the operator, quietly (a field made the undo step: "Landscape").
fn exec(id: []const u8, text: []const u8) void {
    const i = ops.byId(id) orelse return;
    const keep_a = ops.arg;
    const keep_q = ops.quiet;
    ops.arg = text;
    ops.quiet = true;
    ops.run(i);
    ops.arg = keep_a;
    ops.quiet = keep_q;
    undo.label("Landscape");
    app.dirty = true;
}

/// lu_run: the operator (its own undo step).
fn run(id: []const u8, text: []const u8) void {
    const i = ops.byId(id) orelse return;
    const keep_a = ops.arg;
    ops.arg = text;
    ops.run(i);
    ops.arg = keep_a;
    app.dirty = true;
}

fn val3(w: *std.Io.Writer, v: f32) void {
    var b: [32]u8 = undefined;
    w.writeAll(cad.fmtVal3(&b, v)) catch {};
}

// ---- callbacks -------------------------------------------------------------------

const SetWhat = enum { size, res, detail };

/// set_cb: size, samples, detail: landscape.set.
fn setCb(what: SetWhat) void {
    var w = std.Io.Writer.fixed(&arg_buf);
    switch (what) {
        .size => {
            w.writeAll("size ") catch {};
            val3(&w, lu_size);
        },
        .res => w.print("res {d}", .{res_n[lu_res]}) catch {},
        .detail => w.print("detail {d}", .{res_n[lu_det]}) catch {},
    }
    exec("landscape.set", w.buffered());
}

/// vis_cb: the layer shown or hidden.
fn visCb(k: u32, shown: bool) void {
    var w = std.Io.Writer.fixed(&arg_buf);
    w.print("{s}{d}", .{ if (shown) "show " else "hide ", k }) catch {};
    exec("landscape.layer", w.buffered());
}

/// lay_cb: a value of the layer picked (slot 10: the strength).
fn layCb(slot: usize, kind: VK) void {
    var w = std.Io.Writer.fixed(&arg_buf);
    w.print("set {d}", .{lu_sel}) catch {};
    if (slot == 10) {
        w.writeAll(" strength ") catch {};
        val3(&w, lu_str);
    } else {
        const keys = pk_types[lu_type];
        if (keys.len == 0) return;
        w.print(" {s} ", .{keys[slot]}) catch {};
        if (kind == .float) {
            val3(&w, lu_pf[slot]);
        } else if (slot == 0 and lu_type == 0) {
            w.writeAll(kw_noise[@as(u32, @bitCast(lu_pi[0])) & 3]) catch {};
        } else w.print("{d}", .{lu_pi[slot]}) catch {};
    }
    exec("landscape.layer", w.buffered());
}

/// rule_cb: the paint layer picked, all of it.
fn ruleCb() void {
    var w = std.Io.Writer.fixed(&arg_buf);
    w.print("rule {d} colour ", .{lp_sel}) catch {};
    const c = lp_col & 0xffffff;
    var sh: i32 = 16;
    while (true) {
        const v: f32 = @floatFromInt((c >> @intCast(sh)) & 255);
        val3(&w, v / 255.0);
        sh -= 8;
        if (sh < 0) break;
        w.writeByte(' ') catch {};
    }
    w.writeAll(" friction ") catch {};
    val3(&w, lp_fric);
    w.writeAll(" bounce ") catch {};
    val3(&w, lp_bounce);
    w.writeAll(" height ") catch {};
    val3(&w, lp_h[0]);
    w.writeByte(' ') catch {};
    val3(&w, lp_h[1]);
    w.writeAll(" slope ") catch {};
    val3(&w, lp_s[0]);
    w.writeByte(' ') catch {};
    val3(&w, lp_s[1]);
    exec("landscape.paint", w.buffered());
}

fn loadLayer(l: *const la.Layer) void {
    lu_type = if (l.typ -% 1 <= 5) l.typ - 1 else 0;
    lu_str = l.str;
    for (0..10) |k| {
        lu_pf[k] = l.p[k];
        lu_pi[k] = @import("procgen.zig").cvt(l.p[k]);
    }
}
fn loadPaint(p: *const la.Paint) void {
    lp_col = p.col;
    lp_fric = p.fric;
    lp_bounce = p.bounce;
    lp_h = .{ p.hlo, p.hhi };
    lp_s = .{ p.slo, p.shi };
}

/// res_index: its place in l_res (the nearest below).
fn resIndex(n: u32) u32 {
    var k: u32 = 0;
    while (k + 1 < res_n.len and n >= res_n[k + 1]) k += 1;
    return k;
}

// ---- the widgets -----------------------------------------------------------------

/// pnl_text / pnl_hint: wrapped to the column, recorded as `info`.
fn para(z: *zui.Ui, s: []const u8, c: u32) void {
    z.wrappedText(s, .{ .color = host.col(c), .width = @floatFromInt(col.w) });
    ui.record("info", s, host.rectOf(z.lastRect()), true);
}

/// A drop-down of `labels` (name "##..." to hide it), the width it is
/// given, the chosen one `v.*`; recorded as `enum` too. True when another
/// was picked.
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

/// lu_cap: the caption in the left half, a drop-down in the right half;
/// the caption recorded as `caption`, on the drop-down's line.
fn capEnum(z: *zui.Ui, cap: []const u8, v: *u32, labels: []const []const u8, tip: []const u8) bool {
    z.pushId(cap);
    defer z.popId();
    bkit.beginCaptioned(z, cap, @floatFromInt(@divTrunc(col.w, 2) - 6));
    const changed = enumField(z, "##list", v, labels, tip);
    const r = host.rectOf(z.lastRect());
    bkit.endCaptioned(z);
    ui.record("caption", cap, .{ .x = col.x, .y = r.y, .w = col.w >> 1, .h = r.h }, true);
    return changed;
}

/// A caption on a line of its own (dim), recorded as `caption`.
fn caption(z: *zui.Ui, s: []const u8) void {
    z.label(s, .{ .color = host.col(ui.th.text_dim) });
    const r = host.rectOf(z.lastRect());
    ui.record("caption", s, .{ .x = col.x, .y = r.y, .w = col.w >> 1, .h = r.h }, true);
}

/// A number field (WK_FLOAT), the width it is given. True when changed.
fn num(z: *zui.Ui, v: *f32, label: []const u8, lo: f32, hi: f32, step: f32, dec: u8, tip: []const u8) bool {
    if (bkit.numberRow(z, label, v, .{ .step = step, .min = lo, .max = hi, .decimals = dec, .tip = tip }).changed) {
        v.* = std.math.clamp(v.*, lo, hi);
        return true;
    }
    return false;
}

/// A whole number field (WK_INT). True when changed.
fn int(z: *zui.Ui, v: *i32, label: []const u8, lo: f32, hi: f32, step: f32, tip: []const u8) bool {
    var f: f32 = @floatFromInt(v.*);
    if (bkit.numberRow(z, label, &f, .{ .step = step, .min = lo, .max = hi, .decimals = 0, .tip = tip }).changed) {
        v.* = @intFromFloat(@round(std.math.clamp(f, lo, hi)));
        return true;
    }
    return false;
}

fn colourDone() void {
    ruleCb();
}

// ---- the tab -----------------------------------------------------------------------

/// land_props: the Landscape page in the column `bd` (pnl_begin's), from y0:
/// y below it.
pub fn props(i: i16, bd: Rect, y0: i32) i32 {
    col = bd;
    if (active() == null) return y0;
    var f = bkit.Flow.begin("landscape", @intCast(i), bd, y0);
    if (f.z) |z| {
        // (the original's pitch: 22 a row, 4 between)
        z.beginVertical(.{ .width = .px(@floatFromInt(bd.w)), .spacing = 4 });
        // (fields as narrow as the column: Zui's natural width is wider)
        z.pushMetric(.widget_width, 60);
        defer z.popStyle();
        describe(z);
        z.endVertical();
    }
    return f.end();
}

fn describe(z: *zui.Ui) void {
    const b = active() orelse return;
    info(z, b);
    if (bkit.section(z, "Size and Samples", &sec_open[S_LAND])) {
        z.pushId("§Size and Samples");
        defer z.popId();
        lu_size = b.size;
        lu_res = resIndex(b.n);
        lu_det = resIndex(if (b.disp == 0) la.LA_DISP else b.disp);
        if (num(z, &lu_size, "Size (m)", 1, 100000, 0.5, 1, "Metres a side (the heights stay, stretched)")) setCb(.size);
        if (capEnum(z, "Samples a side", &lu_res, &l_res, "Samples a side: more is finer and slower (the heights resampled)")) setCb(.res);
        if (capEnum(z, "Display detail", &lu_det, l_res[0..4], "The display's samples a side at most (colliders use them all)")) setCb(.detail);
    }
    if (bkit.section(z, "Layers", &sec_open[S_LAY])) {
        z.pushId("§Layers");
        defer z.popId();
        layers(z, b);
    }
    if (bkit.section(z, "Paint", &sec_open[S_PAINT])) {
        z.pushId("§Paint");
        defer z.popId();
        // (a layer added or removed above: the block now)
        paint(z, active() orelse return);
    }
    if (bkit.section(z, "Sea and Files", &sec_open[S_MORE])) {
        z.pushId("§Sea and Files");
        defer z.popId();
        _ = bkit.opButton(z, "landscape.sea", .{ .label = "Add Sea" });
        bkit.beginPair(z);
        _ = bkit.opButton(z, "landscape.import", .{ .label = "Import Heightmap..." });
        _ = bkit.opButton(z, "landscape.export", .{ .label = "Export Heights..." });
        bkit.endPair(z);
        bkit.beginPair(z);
        _ = bkit.opButton(z, "landscape.to_mesh", .{ .label = "To Mesh" });
        _ = bkit.opButton(z, "landscape.tiles", .{ .label = "Split into Tiles..." });
        bkit.endPair(z);
    }
}

/// lu_info: "513 x 513 samples over 200 m" / "-14 to 24 m, 2 layers,
/// evaluated in 48 ms".
fn info(z: *zui.Ui, b: *la.Block) void {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("{d} x {d} samples over ", .{ b.n, b.n }) catch {};
    val3(&w, b.size);
    w.writeAll(" m") catch {};
    para(z, w.buffered(), ui.th.text);
    var buf2: [128]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    val3(&w2, b.hmin);
    w2.writeAll(" to ") catch {};
    val3(&w2, b.hmax);
    w2.print(" m, {d} layers, evaluated in {d} ms", .{ @as(i32, @bitCast(b.nl)), @as(i32, @bitCast(b.ms)) }) catch {};
    para(z, w2.buffered(), ui.th.text_dim);
    z.spacer(.px(2));
}

/// lu_layers: the stack, top first; the one picked; Add, Up, Down, Remove.
fn layers(z: *zui.Ui, b: *la.Block) void {
    const nl = @min(b.nl, la.LA_MAXL);
    if (nl == 0) {
        para(z, "No layers: add one below.", ui.th.text_dim);
    } else {
        if (lu_sel >= nl) lu_sel = nl - 1;
        var k: i32 = @as(i32, @intCast(nl)) - 1;
        while (k >= 0) : (k -= 1) {
            const ku: u32 = @intCast(k);
            const l = &b.lay[ku];
            var shown = l.flg & 1 == 0;
            const tn = l_types[if (l.typ -% 1 <= 5) l.typ - 1 else 0];
            z.pushIdInt(ku);
            defer z.popId();
            z.beginHorizontal(.{ .spacing = 4, .alignment = .start });
            // (its eye: a check box without a label, as the original's)
            if (bkit.checkRow(z, "", &shown, "Shown (its effect on the heights) or hidden").changed) visCb(ku, shown);
            // (hidden: the theme's own COL_TEXT_OFF: a name, not a control)
            const hidden = l.flg & 1 != 0;
            if (hidden) z.pushColor(.text, host.col(@import("theme.zig").base.text_off));
            const r = bkit.row(z, tn, ku == lu_sel, .{ .tip = "A layer of the stack: click to edit it" });
            if (hidden) z.popStyle();
            z.endHorizontal();
            if (r.clicked) {
                lu_sel = ku;
                app.dirty = true;
            }
        }
        // the one picked: its values
        z.spacer(.px(2));
        loadLayer(&b.lay[lu_sel]);
        if (num(z, &lu_str, "Strength", 0, 10, 0.005, 3, "How much of it is added (1: all)")) layCb(10, .float);
        for (lv_types[lu_type], 0..) |v, vi| {
            z.pushIdInt(vi);
            defer z.popId();
            var changed = false;
            switch (v.k) {
                .noise => {
                    var nz: u32 = @as(u32, @bitCast(lu_pi[0])) & 3;
                    if (capEnum(z, "Noise", &nz, &l_noise, v.tip)) {
                        lu_pi[0] = @intCast(nz);
                        layCb(0, .noise);
                    }
                },
                .float => changed = num(z, &lu_pf[v.slot], v.label, v.lo, v.hi, v.step, v.dec, v.tip),
                .int => changed = int(z, &lu_pi[v.slot], v.label, v.lo, v.hi, v.step, v.tip),
                .toggle => {
                    var on = lu_pi[v.slot] != 0;
                    if (bkit.checkRow(z, v.label, &on, v.tip).changed) {
                        lu_pi[v.slot] = @intFromBool(on);
                        changed = true;
                    }
                },
            }
            if (changed) layCb(v.slot, v.k);
        }
    }
    // Add, Up, Down, Remove
    z.beginHorizontal(.{ .spacing = 4 });
    var add: u32 = 0;
    if (enumField(z, "##addl", &add, &l_addl, "A new layer on top of the stack") and add > 0) {
        var w = std.Io.Writer.fixed(&arg_buf);
        w.print("add {s}", .{kw_types[add - 1]}) catch {};
        run("landscape.layer", w.buffered());
    }
    if (nl > 0) {
        if (bkit.button(z, "Up", "Move the layer picked up the stack").clicked) {
            var w = std.Io.Writer.fixed(&arg_buf);
            w.print("up {d}", .{lu_sel}) catch {};
            run("landscape.layer", w.buffered());
            // (the pick follows it)
            if (active()) |nb| {
                if (lu_sel + 1 < nb.nl) lu_sel += 1;
            }
        }
        if (bkit.button(z, "Down", "Move it down").clicked) {
            var w = std.Io.Writer.fixed(&arg_buf);
            w.print("down {d}", .{lu_sel}) catch {};
            run("landscape.layer", w.buffered());
            if (lu_sel > 0) lu_sel -= 1;
        }
    } else {
        // (the original's: Add in the first third of the row)
        z.spacer(.fill);
        z.spacer(.fill);
    }
    z.endHorizontal();
    if (nl == 0) return;
    if (bkit.button(z, "Remove", "Remove the layer picked").clicked) {
        var w = std.Io.Writer.fixed(&arg_buf);
        w.print("remove {d}", .{lu_sel}) catch {};
        run("landscape.layer", w.buffered());
        return;
    }
    // (the original's: a row's room after Remove whenever there are layers)
    z.spacer(.px(22));
}

/// lu_paint: the paint layers, the one picked, Add, Remove, Auto Paint.
fn paint(z: *zui.Ui, b: *la.Block) void {
    const np = @min(b.np, la.LA_MAXP);
    if (np == 0) {
        para(z, "No paint layers: add one, or Auto Paint.", ui.th.text_dim);
    } else {
        if (lp_sel >= np) lp_sel = 0;
        for (0..np) |k| {
            const p = &b.paint[k];
            const name = l_mats[p.mat & 7];
            z.pushIdInt(k);
            defer z.popId();
            z.beginHorizontal(.{ .spacing = 6, .alignment = .center });
            // its colour, as it is
            const sw = z.place(.{ .x = 14, .y = 14 });
            z.drawRect(.{ .rect = sw, .fill = host.col(p.col), .radius = 3 });
            const r = bkit.row(z, name, k == lp_sel, .{ .tip = "A paint layer: click to edit it" });
            z.endHorizontal();
            if (r.clicked) {
                lp_sel = @intCast(k);
                app.dirty = true;
            }
        }
        z.spacer(.px(2));
        loadPaint(&b.paint[lp_sel]);
        _ = bkit.colourRow(z, "Colour", &lp_col, colourDone, "Its colour (the viewport and both path tracers)");
        var ch = false;
        bkit.beginPair(z);
        ch = num(z, &lp_fric, "Friction", 0, 2, 0.005, 3, "Rigid bodies grip this much where it is painted") or ch;
        ch = num(z, &lp_bounce, "Bounce", 0, 1, 0.005, 3, "") or ch;
        bkit.endPair(z);
        caption(z, "Heights (0-1)");
        z.pushId("heights");
        bkit.beginPair(z);
        ch = num(z, &lp_h[0], "From", 0, 1, 0.005, 2, "Auto Paint: the lowest height (0 the lowest ground, 1 the highest)") or ch;
        ch = num(z, &lp_h[1], "To", 0, 1, 0.005, 2, "") or ch;
        bkit.endPair(z);
        z.popId();
        caption(z, "Slopes (deg)");
        z.pushId("slopes");
        bkit.beginPair(z);
        ch = num(z, &lp_s[0], "From", 0, 90, 0.1, 0, "Auto Paint: the gentlest slope (degrees)") or ch;
        ch = num(z, &lp_s[1], "To", 0, 90, 0.1, 0, "") or ch;
        bkit.endPair(z);
        z.popId();
        if (ch) ruleCb();
    }
    z.beginHorizontal(.{ .spacing = 4 });
    var add: u32 = 0;
    if (enumField(z, "##addp", &add, &l_addp, "A new paint layer of a material") and add > 0) {
        var w = std.Io.Writer.fixed(&arg_buf);
        w.print("add {s}", .{kw_mats[add - 1]}) catch {};
        run("landscape.paint", w.buffered());
    }
    if (np > 0) {
        if (bkit.button(z, "Remove", "Remove the paint layer picked (its paint too)").clicked) {
            var w = std.Io.Writer.fixed(&arg_buf);
            w.print("remove {d}", .{lp_sel}) catch {};
            run("landscape.paint", w.buffered());
        }
    } else z.spacer(.fill);
    _ = bkit.opButton(z, "landscape.paint_auto", .{ .label = "Auto Paint" });
    z.endHorizontal();
}

test "res_index: the nearest below" {
    try std.testing.expectEqual(@as(u32, 0), resIndex(65));
    try std.testing.expectEqual(@as(u32, 3), resIndex(513));
    try std.testing.expectEqual(@as(u32, 3), resIndex(1000));
    try std.testing.expectEqual(@as(u32, 6), resIndex(4097));
    try std.testing.expectEqual(@as(u32, 0), resIndex(2));
}
