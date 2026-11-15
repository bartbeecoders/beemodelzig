// Paint modes' face: the operators, the bar at the bottom of the viewport (vpnav.s
// tool_settings_draw), the settings line over it (paint_overlay), the brush at the
// pointer, the Paint Layers panel of the Material tab (matui.s layers_props), the
// tools area (tl_paint).
const std = @import("std");
const ops = @import("ops.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const app = @import("app.zig");
const zui = @import("zui");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const scene = @import("scene.zig");
const undo = @import("undo.zig");
const images = @import("images.zig");
const layers = @import("layers.zig");
const pthist = @import("pthist.zig");
const pt = @import("paint.zig");
const wp = @import("wpaint.zig");
const stroke = @import("stroke.zig");
const sculptui = @import("sculptui.zig");
const em = @import("editmesh.zig");
const armedit = @import("armedit.zig");
const Icon = @import("icons.zig").Icon;

const Impl = ops.Impl;
const Rect = gfx.Rect;
const COL_ACTIVE: u32 = 0xffb340;
const pf_grow: f32 = 1.15;
const pf_shrink: f32 = 0.8695652;
const pf_tenth: f32 = 0.1;

fn radiusBy(k: f32) void {
    pt.radius = stroke.minss(stroke.maxss(pt.radius * k, pt.rmin), pt.rmax);
    app.dirty = true;
}
fn radiusDown() void {
    radiusBy(pf_shrink);
}
fn radiusUp() void {
    radiusBy(pf_grow);
}
fn strengthBy(d: f32) void {
    pt.strength = stroke.minss(stroke.maxss(pt.strength + d, pf_tenth), 1);
    app.dirty = true;
}
fn strengthDown() void {
    strengthBy(-pf_tenth);
}
fn strengthUp() void {
    strengthBy(pf_tenth);
}

/// paint.color <r> <g> <b> (0-255)
fn opColor() void {
    var it = std.mem.tokenizeAny(u8, ops.arg, " ");
    var c: u32 = 0xff;
    for (0..3) |_| {
        const w = it.next() orelse return colorHelp();
        var v: u32 = 0;
        var n: usize = 0;
        for (w) |ch| {
            if (ch < '0' or ch > '9') break;
            v = @min(v * 10 + (ch - '0'), 1000000);
            n += 1;
        }
        if (n == 0) return colorHelp();
        c = c << 8 | @min(v, 255);
    }
    pt.col = c;
    app.dirty = true;
}
fn colorHelp() void {
    app.toast(.warn, "paint.color <r> <g> <b> (0-255)", .{});
}

/// paint.weight <0..1>
fn opWeightValue() void {
    const w = std.mem.trim(u8, ops.arg, " \"");
    if (w.len == 0) return;
    const f = std.fmt.parseFloat(f32, w) catch return;
    wp.value = stroke.minss(stroke.maxss(f, 0), 1);
    app.dirty = true;
}

/// Layers are texture paint's.
fn pollLayers() ?[]const u8 {
    if (!pt.on) return "Only in texture paint";
    return if (pt.kind == .texture) null else "Only texture paint has layers";
}

fn layerAdd() void {
    const im = pt.image() orelse return;
    _ = layers.op(im, .add, 0, 0);
    app.dirty = true;
}
fn layerStep(d: i32) void {
    const im = pt.image() orelse return;
    _ = layers.op(im, .active, layers.op(im, .get_active, 0, 0) + d, 0);
    app.dirty = true;
}
fn layerUp() void {
    layerStep(1);
}
fn layerDown() void {
    layerStep(-1);
}
fn layerMerge() void {
    const im = pt.image() orelse return;
    _ = layers.op(im, .merge, 0, 0);
    app.dirty = true;
}

/// do_pt_undo: vertex and weight paint undo as the scene does.
fn opUndo() void {
    if (pt.on and pt.kind != .texture) {
        ops.runId("edit.undo");
        return;
    }
    pthist.opUndo();
}
fn opRedo() void {
    if (pt.on and pt.kind != .texture) {
        ops.runId("edit.redo");
        return;
    }
    pthist.opRedo();
}

/// mode.*: out of the mode we are in, into this one.
fn modeSet(comptime k: pt.Kind) *const fn () void {
    return struct {
        fn f() void {
            if (pt.on and pt.kind == k) return;
            pt.exit();
            if (armedit.mode != 0) armedit.mode = 0;
            if (em.active) em.exit();
            @import("sculpt.zig").exit();
            switch (k) {
                .texture => pt.opTexture(),
                .vertex => pt.opVertex(),
                .weight => pt.opWeight(),
            }
        }
    }.f;
}

pub const list = .{
    .{ "object.texture_paint", Impl{ .run = pt.opTexture, .check = pt.isTexture } },
    .{ "object.vertex_paint", Impl{ .run = pt.opVertex, .check = pt.isVertex } },
    .{ "object.weight_paint", Impl{ .run = pt.opWeight, .check = pt.isWeight } },
    .{ "mode.texture_paint", Impl{ .run = modeSet(.texture), .check = pt.isTexture } },
    .{ "mode.vertex_paint", Impl{ .run = modeSet(.vertex), .check = pt.isVertex } },
    .{ "mode.weight_paint", Impl{ .run = modeSet(.weight), .check = pt.isWeight } },
    .{ "paint.radius_down", Impl{ .run = radiusDown, .ctx = .paint } },
    .{ "paint.radius_up", Impl{ .run = radiusUp, .ctx = .paint } },
    .{ "paint.strength_down", Impl{ .run = strengthDown, .ctx = .paint } },
    .{ "paint.strength_up", Impl{ .run = strengthUp, .ctx = .paint } },
    .{ "paint.color", Impl{ .run = opColor } },
    .{ "paint.weight", Impl{ .run = opWeightValue } },
    .{ "paint.layer_add", Impl{ .run = layerAdd, .ctx = .paint, .poll = pollLayers } },
    .{ "paint.layer_up", Impl{ .run = layerUp, .ctx = .paint, .poll = pollLayers } },
    .{ "paint.layer_down", Impl{ .run = layerDown, .ctx = .paint, .poll = pollLayers } },
    .{ "paint.layer_merge", Impl{ .run = layerMerge, .ctx = .paint, .poll = pollLayers } },
    .{ "paint.undo", Impl{ .run = opUndo, .ctx = .paint } }, // (their key: in the mode only)
    .{ "paint.redo", Impl{ .run = opRedo, .ctx = .paint } },
};

/// The tools area in the paint modes (tl_paint): an id, its icon; "" the LAYERS caption.
pub const tools = [_]struct { id: []const u8, ic: ?Icon }{
    .{ .id = "paint.color", .ic = .paint },       .{ .id = "paint.radius_up", .ic = null },
    .{ .id = "paint.radius_down", .ic = null },   .{ .id = "paint.strength_up", .ic = null },
    .{ .id = "paint.strength_down", .ic = null }, .{ .id = "", .ic = null },
    .{ .id = "paint.layer_add", .ic = .plus },     .{ .id = "paint.layer_up", .ic = null },
    .{ .id = "paint.layer_down", .ic = null },    .{ .id = "paint.layer_merge", .ic = null },
};

fn hudLine(b: []u8) []const u8 {
    var w = std.Io.Writer.fixed(b);
    switch (pt.kind) {
        .texture => {
            w.writeAll("Texture Paint: ") catch {};
            if (pt.image()) |im| w.writeAll(images.nameOf(im)) catch {};
        },
        .vertex => w.writeAll("Vertex Paint") catch {},
        .weight => w.writeAll("Weight Paint") catch {},
    }
    var vb: [24]u8 = undefined;
    w.print("  radius {d}  strength {s}", .{ stroke.trunc32(pt.radius), sculptui.val3(&vb, pt.strength) }) catch {};
    if (pt.image()) |im| {
        if (images.list[im].layers) |l| w.print("  layer {d}/{d}", .{ l.active, l.count - 1 }) catch {};
    }
    w.writeAll("  ([ ] radius, Shift+[ ] strength, Shift+N layer, PgUp/PgDn)") catch {};
    return w.buffered();
}

/// paint_overlay: the settings line, the colour, the brush at the pointer.
pub fn overlay(r: Rect) void {
    if (!pt.on) return;
    const cv = ui.cv;
    var buf: [240]u8 = undefined;
    _ = cv.text(r.x + 10, r.y + 62, hudLine(&buf), COL_ACTIVE);
    cv.fill(.{ .x = r.x + 10, .y = r.y + 80, .w = 40, .h = 12 }, pt.col & 0xffffff);
    if (ui.inside(r)) ui.cursor = .crosshair;
    if (ui.mx > -1000) {
        const old = cv.setClip(r.intersect(cv.clip));
        defer cv.clip = old;
        stroke.cursor(cv, ui.mx, ui.my, pt.radius, null);
    }
}

const WG_H = 22;
const swatches = [6]u32{ 0xffffff, 0x101010, 0xd04020, 0xe0b030, 0x40a050, 0x3070d0 };
var brush_rgb: u32 = 0;

fn colourPicked() void {
    pt.col = brush_rgb | 0xff000000;
    app.dirty = true;
}

/// What the bar covers (a press there is not a stroke).
pub fn barRect(r: Rect) Rect {
    var x = @divTrunc(r.x + r.right(), 2) - 270;
    x = @max(x, r.x + 250); // (not over the redo panel)
    return .{ .x = x - 6, .y = r.bottom() - 38 - 5, .w = 552, .h = WG_H + 10 };
}

fn boneLabel(k: usize) []const u8 {
    if (k == 0) return "No bone";
    const a = scene.active orelse return "";
    const b = wp.blockOf(a) orelse return "";
    return b.bones[k - 1].nameOf();
}
fn bonePick(k: usize) void {
    if (k == 0) return;
    const a = scene.active orelse return;
    const b = wp.blockOf(a) orelse return;
    b.act = @intCast(k - 1); // (no geometry changes)
    wp.bone = @intCast(k - 1);
    app.dirty = true;
}

/// The brush's settings at the bottom of the viewport: a Zui part over its
/// backing.
pub fn bar(i: i16, r: Rect) void {
    if (!pt.on) return;
    const bk = barRect(r);
    const z = host.beginPart("paint.bar", @intCast(i), bk) orelse return;
    defer host.endPart(z);
    sculptui.backing(z, bk);
    z.beginHorizontal(.{ .spacing = 6, .padding = 5 });
    defer z.endHorizontal();
    z.beginHorizontal(.{ .width = .px(150), .spacing = 0 });
    // (one decimal: [ and ] scale it by 1.15)
    if (bkit.numberRow(z, "Radius", &pt.radius, .{ .step = 0.5, .min = 1, .max = 1000, .decimals = 1, .tip = "The brush's radius in pixels ([ and ] change it)" }).changed) app.dirty = true;
    z.endHorizontal();
    z.beginHorizontal(.{ .width = .px(150), .spacing = 0 });
    if (bkit.numberRow(z, "Strength", &pt.strength, .{ .step = 0.005, .min = 0, .max = 1, .decimals = 2, .slider = true, .tip = "How strongly the brush paints (Shift+[ and Shift+])" }).changed) app.dirty = true;
    z.endHorizontal();
    if (pt.kind == .weight) {
        z.beginHorizontal(.{ .width = .px(96), .spacing = 0 });
        if (bkit.numberRow(z, "Weight", &wp.value, .{ .step = 0.005, .min = 0, .max = 1, .decimals = 2, .slider = true, .tip = "The weight painted towards (1: the bone moves it fully)" }).changed) app.dirty = true;
        z.endHorizontal();
        z.beginHorizontal(.{ .width = .px(120), .spacing = 0 });
        const bl = if (scene.active) |q| wp.blockOf(q) else null;
        var k: usize = if (bl) |b| @as(usize, b.act) + 1 else 0;
        const n: usize = if (bl) |b| @as(usize, b.n) + 1 else 1;
        if (bkit.choice(z, "##Bone", &k, n, boneLabel, "The bone whose weights are painted")) bonePick(k);
        z.endHorizontal();
    } else {
        brush_rgb = pt.col & 0xffffff;
        colourSwatch(z, "The paint colour", &brush_rgb, colourPicked);
        z.beginHorizontal(.{ .width = .auto, .spacing = 2 });
        for (swatches, 0..) |sw, k| {
            z.pushIdInt(k);
            defer z.popId();
            z.pushColor(.button, host.col(sw));
            z.pushColor(.button_hovered, host.col(sw));
            z.pushColor(.button_active, host.col(sw));
            const q = z.button("##swatch", .{ .width = .px(22) });
            z.popStyles(3);
            ui.record("swatch", "Paint with this colour", host.rectOf(q.rect), true);
            z.tooltipRich(q, .{ .title = "Swatch", .body = "Paint with this colour" });
            if (q.clicked) {
                pt.col = sw | 0xff000000;
                app.dirty = true;
            }
        }
        z.endHorizontal();
    }
}

/// A colour as a swatch only, 56 wide (bkit.colourRow without its label,
/// for the bar): a click opens BeeModel's colour picker, `cb` on each
/// change; in wg's field list for the context menu and Ctrl+C / Ctrl+V.
/// Recorded as `colour:<name>`. (A kit candidate.)
fn colourSwatch(z: *zui.Ui, name: []const u8, c: *u32, cb: ?*const fn () void) void {
    var nb: [64]u8 = undefined;
    z.pushColor(.button, host.col(c.*));
    z.pushColor(.button_hovered, host.col(c.*));
    z.pushColor(.button_active, host.col(c.*));
    const it = z.button(std.fmt.bufPrint(&nb, "##{s}", .{name}) catch "##colour", .{ .width = .px(56) });
    z.popStyles(3);
    const r = host.rectOf(it.rect);
    ui.record("colour", name, r, true);
    const x: u64 = @intFromEnum(it.id);
    @import("wg.zig").zuiColor(@truncate(x ^ (x >> 32)), r, c, cb, it.context_clicked);
    var hb: [8]u8 = undefined;
    z.tooltipRich(it, .{ .title = name, .body = std.fmt.bufPrint(&hb, "#{x:0>6}", .{c.*}) catch "" });
    if (it.clicked) @import("colorpick.zig").openFor(c, r, name, cb);
}

// the Paint Layers panel ---------------------------------------------------------------

fn blendLabel(k: usize) []const u8 {
    return ([_][]const u8{ "Normal", "Multiply", "Add" })[k];
}

/// layers_props: the top first, an eye, the name (a click paints on it), opacity and
/// blend; Add, Merge, Remove. y after them.
pub fn panel(salt: usize, bd: Rect, y0: i32) i32 {
    if (pt.image() == null) return y0;
    var f = bkit.Flow.begin("paint.layers", salt, bd, y0);
    if (f.z) |z| describePanel(z, bd);
    return f.end();
}

fn describePanel(z: *zui.Ui, bd: Rect) void {
    const im = pt.image() orelse return;
    bkit.heading(z, "Paint Layers");
    const e = &images.list[im];
    const w: f32 = @floatFromInt(bd.w);
    if (e.layers) |b| {
        var k: i32 = @intCast(b.count);
        while (k > 0) {
            k -= 1;
            const q: usize = @intCast(k);
            const l = &b.l[q];
            z.pushIdInt(q);
            defer z.popId();
            z.beginHorizontal(.{ .spacing = 4 });
            defer z.endHorizontal();
            var eye = l.vis != 0;
            if (bkit.checkRow(z, "##Visible", &eye, "Show the layer").changed) _ = layers.op(im, .visible, k, if (eye) 1 else 0);
            var nb: [12]u8 = undefined;
            const nm = if (k == 0) "Base" else std.fmt.bufPrint(&nb, "Layer {d}", .{k}) catch "";
            z.beginHorizontal(.{ .width = .px(w * 0.30), .spacing = 0 });
            if (bkit.row(z, nm, b.active == q, .{ .tip = "Paint on this layer" }).clicked) _ = layers.op(im, .active, k, 0);
            z.endHorizontal();
            if (k != 0) { // (the base: no opacity, no blend)
                z.beginHorizontal(.{ .width = .px(w * 0.28), .spacing = 0 });
                var v = l.opac;
                if (bkit.numberRow(z, "##Opacity", &v, .{ .step = 0.005, .min = 0, .max = 1, .decimals = 2, .slider = true, .tip = "The layer's opacity" }).changed) _ = layers.op(im, .opacity, k, v);
                z.endHorizontal();
                var bi: usize = if (l.blend <= 2) l.blend else 0;
                if (bkit.choice(z, "##Blend", &bi, 3, blendLabel, "How the layer mixes with the ones below")) _ = layers.op(im, .blend, k, @floatFromInt(bi));
            }
        }
    } else {
        bkit.note(z, "One layer: Add makes one to paint on.");
    }
    z.beginHorizontal(.{ .spacing = 4 });
    _ = bkit.opButton(z, "paint.layer_add", .{ .label = "Add" });
    _ = bkit.opButton(z, "paint.layer_merge", .{ .label = "Merge" });
    const act: i32 = if (e.layers) |b| @intCast(b.active) else 0;
    const rm = bkit.button(z, "Remove", "Remove the active layer (not the base)");
    z.endHorizontal();
    if (rm.clicked and act > 0) _ = layers.op(im, .remove, act, 0);
}

// the console: what scripts call ---------------------------------------------------------

fn nums(it: anytype, out: []f32) bool {
    for (out) |*x| {
        const t = it.next() orelse return false;
        const f = @import("expr.zig").eval(t) orelse return false;
        if (!std.math.isFinite(f)) return false;
        x.* = @floatCast(f);
    }
    return true;
}

fn colorOf(it: anytype) void {
    var c: [3]f32 = undefined;
    if (!nums(it, &c)) return;
    var v: u32 = 0xff;
    for (c) |x| {
        const k = stroke.trunc32(x);
        v = v << 8 | @as(u32, @intCast(std.math.clamp(k, 0, 255)));
    }
    pt.col = v;
}

fn meshNamed(n: []const u8) ?usize {
    const i = scene.find(n) orelse {
        app.log("no object called '{s}'", .{n});
        return null;
    };
    if (!scene.objects[i].kind.isMesh() or scene.objects[i].mesh == null) {
        app.log("  select a mesh", .{});
        return null;
    }
    return i;
}

/// paint object x y z radius [r g b], as paint() in a script.
pub fn consolePaint(line: []const u8) void {
    var it = std.mem.tokenizeAny(u8, line, " ");
    const n = it.next() orelse return app.log("paint object x y z radius [r g b]", .{});
    var v: [4]f32 = undefined;
    if (!nums(&it, &v)) return app.log("paint object x y z radius [r g b]", .{});
    colorOf(&it);
    const i = meshNamed(n) orelse return;
    if (!pt.dabWorld(i, .{ v[0], v[1], v[2] }, v[3])) app.log("  paint: no image to paint on {s}", .{n});
}

/// vpaint object x y z radius [r g b], as vpaint().
pub fn consoleVpaint(line: []const u8) void {
    var it = std.mem.tokenizeAny(u8, line, " ");
    const n = it.next() orelse return app.log("vpaint object x y z radius [r g b]", .{});
    var v: [4]f32 = undefined;
    if (!nums(&it, &v)) return app.log("vpaint object x y z radius [r g b]", .{});
    colorOf(&it);
    const i = meshNamed(n) orelse return;
    _ = pt.dabWorldMesh(i, .vertex, .{ v[0], v[1], v[2] }, v[3]);
}

/// wpaint object x y z radius bone weight, as wpaint(): the bone becomes the active one.
pub fn consoleWpaint(line: []const u8) void {
    var it = std.mem.tokenizeAny(u8, line, " ");
    const n = it.next() orelse return app.log("wpaint object x y z radius bone weight", .{});
    var v: [6]f32 = undefined;
    if (!nums(&it, &v)) return app.log("wpaint object x y z radius bone weight", .{});
    const i = meshNamed(n) orelse return;
    const bl = wp.blockOf(i) orelse return app.log("  wpaint: no armature", .{});
    const k = stroke.trunc32(v[4]);
    if (k < 0 or k >= bl.n) return app.log("  wpaint: no such bone", .{});
    bl.act = @intCast(k);
    const was = wp.value;
    defer wp.value = was;
    wp.value = v[5];
    _ = pt.dabWorldMesh(i, .weight, .{ v[0], v[1], v[2] }, v[3]);
}

/// layer image op [layer [value]], as layer(): the result in the log.
pub fn consoleLayer(line: []const u8) void {
    var it = std.mem.tokenizeAny(u8, line, " ");
    const n = it.next() orelse return app.log("layer image count|add|active|opacity|blend|visible|remove|merge [layer [value]]", .{});
    const w = it.next() orelse return app.log("layer image count|add|active|opacity|blend|visible|remove|merge [layer [value]]", .{});
    const im = images.find(n) orelse return app.log("no image called '{s}'", .{n});
    var which: ?layers.Op = null;
    for (layers.op_names, 0..) |x, k| {
        if (std.mem.eql(u8, x, w)) which = @enumFromInt(k);
    }
    var o = which orelse return app.log("no layer operation '{s}'", .{w});
    var layer: i32 = -1;
    var value: f32 = 0;
    var have: usize = 0;
    if (it.next()) |t| {
        layer = std.fmt.parseInt(i32, t, 10) catch -1;
        have = 1;
        if (it.next()) |u| value = std.fmt.parseFloat(f32, u) catch 0;
    }
    if (o == .active and have == 0) o = .get_active;
    app.log("  layer {s} {s}: {d}", .{ n, w, layers.op(im, o, layer, value) });
}

/// Vertex colours, for the tests: paint.vcol object vertex channel (0 r 1 g 2 b 3 a).
pub fn consoleVcol(line: []const u8) void {
    var it = std.mem.tokenizeAny(u8, line, " ");
    const n = it.next() orelse return;
    var v: [2]f32 = undefined;
    if (!nums(&it, &v)) return;
    const i = scene.find(n) orelse return app.log("  paint.vcol -1", .{});
    const me = scene.meshOfObj(i) orelse return app.log("  paint.vcol -1", .{});
    const k: usize = @intFromFloat(@max(v[0], 0));
    const c: u5 = switch (@as(u32, @intFromFloat(@max(v[1], 0)))) {
        0 => 16,
        1 => 8,
        2 => 0,
        else => 24,
    };
    if (me.vcol.len != me.verts.len or k >= me.vcol.len) return app.log("  paint.vcol -1", .{});
    app.log("  paint.vcol {d}", .{me.vcol[k] >> c & 255});
}

/// The mode, the brush, the history (the tests read it).
pub fn info() void {
    app.log("  paint.info on {d} kind {d} radius {d} strength {d} col {x} stroking {d} hist {d}/{d} bytes {d} weight {d} bone {d} dabs {d} us {d} changed {d}", .{ @intFromBool(pt.on), @intFromEnum(pt.kind), pt.radius, pt.strength, pt.col, @intFromBool(pt.stroking), pthist.position(), pthist.steps(), pthist.bytes(), wp.value, wp.bone, pt.dabs, @divTrunc(pt.work_ns, 1000), @intFromBool(@import("files.zig").changed()) });
}

/// The header's mode button.
pub fn modeName() []const u8 {
    return switch (pt.kind) {
        .texture => "Texture Paint",
        .vertex => "Vertex Paint",
        .weight => "Weight Paint",
    };
}
