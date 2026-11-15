// The Timeline, the Dope Sheet and the Graph Editor (anim.s, animed.s, animui.s),
// Zui parts drawn with Zui's painter in the original's layout:
// keys to look at and edit. Both key editors show the scene's curves over the
// frame range, the current frame as a line. Click selects a key (Shift adds), a
// click on nothing clears the selection, a drag on nothing is a box, a drag
// moves the selected keys (whole frames in the dope sheet; frames and values in
// the graph editor) and in the graph editor a drag on a selected key's handle
// shapes it. Each edit runs the anim.* operators (one undo step). Over either:
// X deletes the selected keys, A selects all or none, Shift+D copies them ten
// frames on. The original has no box: it is the port's, on what was a drag on
// nothing there, and a click stays a click.
const std = @import("std");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const anim = @import("anim.zig");
const aops = @import("animops.zig");
const frange = @import("frange.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const menus = @import("menus.zig");
const cat = @import("catalog.zig");
const undo = @import("undo.zig");
const editors = @import("editors.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");
const bkit = @import("bkit.zig");

const Rect = gfx.Rect;
const K = anim;

const TL_L = 44;
const TL_R = 24;
const TL_RULER = 28;
const TL_RH = 20;
const COL_TL_RULER: u32 = 0x2b2f37;
const COL_TL_TICK: u32 = 0x5b6270;
const COL_TL_TEXT: u32 = 0xa9b1bd;
const COL_TL_NOW: u32 = 0xf2b134;
const COL_TL_KEY: u32 = 0xe8c547;
const COL_TL_KEYDIM: u32 = 0x8a7a40;
const tl_steps = [_]i32{ 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000 };

const DS_NAMEW = 170;
const DS_TOP = 46;
const DS_ROW = 18;
const DS_MAXR = 256;
const GE_TOP = 46;
const GE_L = 50;
const GE_R = 20;
const PICK = 7;
const COL_AE_TEXT: u32 = 0xa9b1bd;
const COL_AE_DIM: u32 = 0x5b6270;
const COL_AE_ROW: u32 = 0x262a31;
const COL_AE_KEY: u32 = 0xd9dde4;
const COL_AE_SEL: u32 = 0xffa030;
const COL_AE_NOW: u32 = 0xf2b134;
const COL_AE_HANDLE: u32 = 0x9a86d8;
const COL_BOX: u32 = 0xffa030;
const ge_cols = [_]u32{ 0xe06c6c, 0x6cc46c, 0x6c9ce0, 0xe0c06c, 0xc06ce0, 0x6ce0d8, 0xe0906c, 0xa0a0a0 };

const Drag = enum { none, move_ds, move_ge, handle, scrub, box };
var drag: Drag = .none;
var side: u32 = 0;
var d_curve: usize = 0;
var d_key: usize = 0;
var dx0: i32 = 0;
var dy0: i32 = 0;
var d_editor: app.Editor = .dopesheet;

var ds_x0: i32 = 0;
var ds_w: i32 = 20;
var ds_y0: i32 = 0;
var ge_x0: i32 = 0;
var ge_w: i32 = 20;
var ge_y0: i32 = 0;
var ge_h: i32 = 20;
var ge_vmin: f32 = 0;
var ge_vmax: f32 = 1;
var rows: [DS_MAXR]u32 = undefined;
var n_rows: usize = 0;

// --- drawing and the pointer, through the Zui part being described --------------------

var Z: *zui.Ui = undefined;

fn fill(r: Rect, c: u32) void {
    Z.drawRect(.{ .rect = host.zr(r), .fill = host.col(c) });
}

fn line(x1: i32, y1: i32, x2: i32, y2: i32, c: u32) void {
    const f = struct {
        fn v(a: i32) f32 {
            return @as(f32, @floatFromInt(a)) + 0.5;
        }
    }.v;
    Z.painter().line(.{ .x = f(x1), .y = f(y1) }, .{ .x = f(x2), .y = f(y2) }, host.col(c), 1);
}

fn text(x: i32, y: i32, s: []const u8, c: u32) void {
    Z.drawText(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, host.col(c), s);
}

fn mx() i32 {
    return @intFromFloat(Z.input.mouse_pos.x);
}

fn my() i32 {
    return @intFromFloat(Z.input.mouse_pos.y);
}

fn shift() bool {
    return Z.input.modifiers.shift;
}

/// a float to a pixel: whatever the file says
fn px(x: f32) i32 {
    if (std.math.isNan(x)) return 0;
    const r = @round(std.math.clamp(x, -1e7, 1e7));
    return @intFromFloat(r);
}

fn fx(f: f32, x0: i32, w: i32) i32 {
    const a: f32 = @floatFromInt(frange.r.start);
    const d: f32 = @floatFromInt(@max(frange.r.end - frange.r.start, 1));
    return px((f - a) / d * @as(f32, @floatFromInt(w))) +| x0;
}

fn xf(x: i32, x0: i32, w: i32) f32 {
    const d: f32 = @floatFromInt(frange.r.end - frange.r.start);
    return @as(f32, @floatFromInt(x - x0)) * d / @as(f32, @floatFromInt(@max(w, 1))) + @as(f32, @floatFromInt(frange.r.start));
}

fn gy(v: f32) i32 {
    const f = (v - ge_vmin) / (ge_vmax - ge_vmin) * @as(f32, @floatFromInt(ge_h));
    return ge_y0 +| ge_h -| px(f);
}

// --- labels ----------------------------------------------------------------------------

fn objName(oid: u32) []const u8 {
    const i = scene.findOid(oid) orelse return "?";
    return scene.objects[i].name();
}

/// "Cube x", "material Red 3", "Cube modifier 0:2", "node tree 1 3:5"
pub fn curveLabel(buf: []u8, c: *const K.Curve) []const u8 {
    const f = std.fmt.bufPrint;
    return switch (c.kind) {
        K.K_OBJ => f(buf, "{s} {s}", .{ objName(c.a), if (c.c < 9) K.obj_props[c.c] else "" }) catch "",
        K.K_MOD => f(buf, "{s} modifier {d}:{d}", .{ objName(c.a), c.b, c.c }) catch "",
        K.K_MAT => f(buf, "material {s} {d}", .{ if (material.get(c.a)) |m| m.nameOf() else "?", c.b }) catch "",
        K.K_FIELD => f(buf, "{s} strength", .{objName(c.a)}) catch "",
        K.K_TEXT => f(buf, "{s} {s}", .{ objName(c.a), @import("text3d.zig").keyName(c.b) }) catch "",
        K.K_SHAPE, K.K_BONE, K.K_PARAM, K.K_NODE => f(buf, "node tree {d} {d}:{d}", .{ c.a +% 1, c.b, c.c >> 2 }) catch "",
        else => f(buf, "node tree {d} {d}:{d}", .{ c.a +% 1, c.b, c.c >> 2 }) catch "",
    };
}

/// The scene's curves (not the actions').
fn findRows() void {
    n_rows = 0;
    const b = anim.cur orelse return;
    for (b.curves(), 0..) |*c, i| {
        if (c.act != 0) continue;
        if (n_rows >= DS_MAXR) return;
        rows[n_rows] = @intCast(i);
        n_rows += 1;
    }
}

fn keyPtr(ci: usize, k: usize) ?*K.Key {
    const b = anim.cur orelse return null;
    if (ci >= b.h.ncur) return null;
    const c = &b.h.cur[ci];
    return if (k < c.n) &b.keys[c.first + k] else null;
}

fn nowLine(x0: i32, w: i32, r: Rect) void {
    const x = fx(anim.frame, x0, w);
    line(x, r.y + 24, x, r.bottom() - 4, COL_AE_NOW);
}

/// Frame numbers along the top: a step leaving ~50 px a label.
fn ruler(x0: i32, w: i32, r: Rect) void {
    const first = frange.r.start;
    const last = frange.r.end;
    const span: i64 = @as(i64, last) - first + 1;
    const want: i64 = @divTrunc(span * 50, @max(w, 1)) + 1;
    var st: i64 = 1;
    while (st < want) {
        st *= 2;
        if (st >= want) break;
        st = @divTrunc(st * 5, 2);
    }
    var fr: i64 = @divTrunc(first, st) * st;
    if (fr < first) fr += st;
    var b: [16]u8 = undefined;
    while (fr <= last) : (fr += st) {
        const x = fx(@floatFromInt(fr), x0, w);
        text(x + 2, r.y + 24, std.fmt.bufPrint(&b, "{d}", .{fr}) catch "", COL_AE_DIM);
    }
}

fn wantMenu(i: i16, it: zui.Interaction, items: []const cat.Item) void {
    if (!it.context_clicked) return;
    menus.openAt(items, mx(), my(), i);
}

const ctx_timeline = [_]cat.Item{ .{ .op = "op_an_play" }, .sep, .{ .op = "op_an_first" }, .{ .op = "op_an_last" }, .sep, .{ .op = "op_tl_start_here" }, .{ .op = "op_tl_end_here" }, .sep, .{ .op = "op_an_key" } };
const ctx_keys = [_]cat.Item{ .{ .op = "op_keys_const" }, .{ .op = "op_keys_lin" }, .{ .op = "op_keys_bez" }, .sep, .{ .op = "op_keys_auto" }, .{ .op = "op_keys_free" }, .sep, .{ .op = "op_ae_dup" }, .{ .op = "op_ae_del" }, .{ .op = "op_ae_all" } };

// --- the Timeline ----------------------------------------------------------------------

var tl_x0: i32 = 0;
var tl_w: i32 = 20;

fn tlX(f: i64) i32 {
    const a: i64 = frange.r.start;
    const d: f32 = @floatFromInt(@max(@as(i64, frange.r.end) - a, 1));
    return @as(i32, @intFromFloat(std.math.clamp(@trunc(@as(f32, @floatFromInt(f - a)) / d * @as(f32, @floatFromInt(tl_w))), -1e7, 1e7))) +| tl_x0;
}

fn tlFrameAt(x: i32) f32 {
    const a = frange.r.start;
    const e = frange.r.end;
    const v = @as(f32, @floatFromInt(x - tl_x0)) * @as(f32, @floatFromInt(e - a)) / @as(f32, @floatFromInt(@max(tl_w, 1)));
    const c = @as(i64, px(v)) + a;
    return @floatFromInt(std.math.clamp(c, a, e));
}

fn tlKeys(r: Rect) void {
    const b = anim.cur orelse return;
    for (b.curves()) |*c| {
        if (c.act != 0 or (c.kind != K.K_OBJ and c.kind != K.K_MOD)) continue;
        const i = scene.findOid(c.a) orelse continue;
        if (!scene.objects[i].selected) continue;
        for (b.keysOf(c)) |*k| {
            const f: i64 = px(k.f);
            if (f < frange.r.start or f > frange.r.end) continue;
            const now: i64 = if (@abs(anim.frame) < 1e9) @intFromFloat(anim.frame) else 0;
            fill(.{ .x = tlX(f) - 3, .y = r.y + TL_RULER + TL_RH + 8, .w = 7, .h = 7 }, if (f == now) COL_TL_KEY else COL_TL_KEYDIM);
        }
    }
}

pub fn timeline(i: i16, r: Rect) void {
    Z = host.beginPart("timeline", @intCast(i), r) orelse return;
    defer host.endPart(Z);
    fill(r, ui.th.pane_bg);
    const start = frange.r.start;
    const end = frange.r.end;
    const now: i64 = if (@abs(anim.frame) < 1e9) @intFromFloat(anim.frame) else 0;
    var buf: [120]u8 = undefined;
    const hint: []const u8 = if (anim.playing) "    playing (Space pauses)" else "    Space: play / pause   Left, Right: step   I: key";
    const fps: i64 = px(frange.r.fps);
    text(r.x + 8, r.y + 4, std.fmt.bufPrint(&buf, "Frame {d}    Range {d} - {d}    fps {d}{s}", .{ now, start, end, fps, hint }) catch "", COL_TL_TEXT);
    tl_x0 = r.x + TL_L;
    tl_w = @max(r.w - (TL_L + TL_R), 20);
    const rule = Rect{ .x = tl_x0, .y = r.y + TL_RULER, .w = tl_w, .h = TL_RH };
    ui.record("timeline", "ruler", rule, true);
    fill(rule, COL_TL_RULER);
    // ticks: a step that leaves 40 px each
    const span: f32 = @floatFromInt(@as(i64, end) - start + 1);
    const pxf = @as(f32, @floatFromInt(tl_w)) / span;
    var st: i64 = 1000;
    for (tl_steps) |s| {
        if (@as(f32, @floatFromInt(s)) * pxf >= 40) {
            st = s;
            break;
        }
    }
    var f: i64 = @divTrunc(start, st) * st;
    if (f < start) f += st;
    var count: u32 = 0;
    while (f <= end and count < 4096) : ({
        f += st;
        count += 1;
    }) {
        const x = tlX(f);
        line(x, r.y + TL_RULER, x, r.y + TL_RULER + 6, COL_TL_TICK);
        var b: [16]u8 = undefined;
        text(x + 3, r.y + TL_RULER + 2, std.fmt.bufPrint(&b, "{d}", .{f}) catch "", COL_TL_TEXT);
    }
    tlKeys(r);
    if (now >= start and now <= end) {
        const x = tlX(now);
        line(x, r.y + TL_RULER, x, r.bottom() - 4, COL_TL_NOW);
        line(x + 1, r.y + TL_RULER, x + 1, r.bottom() - 4, COL_TL_NOW);
    }
    // a press anywhere in it scrubs
    const it = Z.interact(Z.id("##scrub"), host.zr(r));
    wantMenu(i, it, &ctx_timeline);
    if (it.pressed) {
        anim.apply(tlFrameAt(mx()));
    } else if (it.held) {
        const nf = tlFrameAt(mx());
        if (nf != anim.frame) anim.apply(nf);
    }
}

/// |< < play > >| frame, start, end, fps, auto-key
pub fn timelineHeader(i: i16, r: Rect) void {
    const z = host.beginPart("timeline.head", @intCast(i), .{ .x = r.x, .y = r.y + 1, .w = r.w, .h = r.h - 2 }) orelse return;
    defer host.endPart(z);
    z.beginHorizontal(.{ .spacing = 4, .height = .px(@floatFromInt(r.h - 2)) });
    defer z.endHorizontal();
    const h: f32 = @floatFromInt(app.HDR_H - 2);
    const Btn = struct { ic: @import("icons.zig").Icon, id: []const u8 };
    const items = [_]Btn{
        .{ .ic = .first, .id = "anim.first_frame" }, .{ .ic = .prev, .id = "anim.prev_frame" },
        .{ .ic = if (anim.playing) .pause else .play, .id = "anim.play" }, .{ .ic = .next, .id = "anim.next_frame" },
        .{ .ic = .last, .id = "anim.last_frame" },
    };
    for (items) |b| editors.zOpIcon(z, b.ic, b.id, i, h);
    z.spacer(.px(4));
    var f = @round(if (std.math.isFinite(anim.frame)) anim.frame else 0);
    if (bkit.numberRow(z, "Frame", &f, .{ .width = .px(100), .step = 1, .min = -100000, .max = 100000, .decimals = 0, .tip = "The current frame (drag, or type a number)" }).changed) {
        var b: [32]u8 = undefined;
        aops.runText("anim.frame", std.fmt.bufPrint(&b, "{d}", .{@as(i64, @intFromFloat(f))}) catch "");
    }
    var st: f32 = @floatFromInt(std.math.clamp(frange.r.start, -100000, 100000));
    var en: f32 = @floatFromInt(std.math.clamp(frange.r.end, -100000, 100000));
    var fps: f32 = @round(frange.r.fps);
    var changed = false;
    inline for (.{ .{ "Start", &st, 86, "The first frame" }, .{ "End", &en, 86, "The last frame" }, .{ "fps", &fps, 70, "Frames per second" } }) |q| {
        if (bkit.numberRow(z, q[0], q[1], .{ .width = .px(q[2]), .step = 1, .min = if (q[2] == 70) 1 else -100000, .max = if (q[2] == 70) 1000 else 100000, .decimals = 0, .tip = q[3] }).committed) changed = true;
    }
    if (changed) aops.rangeFps(@intFromFloat(st), @intFromFloat(en), fps);
    editors.zOpIcon(z, .record, "anim.auto_key", i, h);
}

/// The key editors' header: interpolation, handles, duplicate, delete.
pub fn keysHeader(i: i16, r: Rect) void {
    const z = host.beginPart("keys.head", @intCast(i), .{ .x = r.x, .y = r.y + 2, .w = r.w, .h = r.h - 4 }) orelse return;
    defer host.endPart(z);
    z.beginHorizontal(.{ .spacing = 4 });
    defer z.endHorizontal();
    const Btn = struct { l: []const u8, w: f32, id: []const u8, tip: []const u8 };
    const items = [_]Btn{
        .{ .l = "Constant", .w = 70, .id = "anim.keys_constant", .tip = "The selected keys hold until the next one" },
        .{ .l = "Linear", .w = 56, .id = "anim.keys_linear", .tip = "Straight from key to key" },
        .{ .l = "Bezier", .w = 56, .id = "anim.keys_bezier", .tip = "Smooth curves through the keys (handles)" },
        .{ .l = "Auto", .w = 44, .id = "anim.keys_handles_auto", .tip = "Handles that keep the curve smooth" },
        .{ .l = "Free", .w = 44, .id = "anim.keys_handles_free", .tip = "Handles you move yourself (graph editor)" },
        .{ .l = "Duplicate", .w = 76, .id = "anim.duplicate_keys_key", .tip = "" },
        .{ .l = "Delete", .w = 56, .id = "anim.delete_keys_key", .tip = "" },
    };
    for (items) |b| {
        const it = z.button(b.l, .{ .width = .px(b.w), .height = .px(@floatFromInt(app.HDR_H - 4)) });
        if (b.tip.len > 0) z.tooltipRich(it, .{ .title = b.l, .body = b.tip });
        if (it.clicked) aops.runText(b.id, "");
    }
}

// --- the Dope Sheet --------------------------------------------------------------------

const s_ae_empty = "No keys yet: I keys the selection, key(\"Cube:x\", frame, value) in scripts.";

fn boxRect() Rect {
    const x = @min(dx0, mx());
    const y = @min(dy0, my());
    return .{ .x = x, .y = y, .w = @max(dx0, mx()) - x, .h = @max(dy0, my()) - y };
}

fn drawBox() void {
    if (drag == .box) Z.drawRect(.{ .rect = host.zr(boxRect()), .border = host.col(COL_BOX), .border_width = 1 });
}

pub fn dopeSheet(i: i16, r: Rect) void {
    Z = host.beginPart("dopesheet", @intCast(i), r) orelse return;
    defer host.endPart(Z);
    fill(r, ui.th.pane_bg);
    text(r.x + 8, r.y + 4, "Dope Sheet   click: select (Shift adds)   drag: move   X delete   A all   Shift+D copy", COL_AE_TEXT);
    ds_x0 = r.x + DS_NAMEW;
    ds_w = @max(r.w - (DS_NAMEW + 20), 20);
    ds_y0 = r.y + DS_TOP;
    ruler(ds_x0, ds_w, r);
    findRows();
    if (n_rows == 0) text(r.x + 8, ds_y0, s_ae_empty, COL_AE_DIM);
    const b = anim.cur;
    for (rows[0..n_rows], 0..) |ci, row| {
        const y = ds_y0 + @as(i32, @intCast(row)) * DS_ROW;
        if (y - r.y + DS_ROW > r.h) break;
        if (row & 1 != 0) fill(.{ .x = r.x, .y = y, .w = r.w, .h = DS_ROW }, COL_AE_ROW);
        const c = &b.?.h.cur[ci];
        var lb: [120]u8 = undefined;
        const name = curveLabel(&lb, c);
        text(r.x + 8, y + 1, name, COL_AE_TEXT);
        ui.record("channel", name, .{ .x = r.x, .y = y, .w = DS_NAMEW, .h = DS_ROW }, true);
        for (b.?.keysOf(c)) |*k| {
            const x = fx(k.f, ds_x0, ds_w);
            if (x < ds_x0 or x > ds_x0 + ds_w) continue;
            fill(.{ .x = x - 4, .y = y + 5, .w = 9, .h = 9 }, if (k.sel != 0) COL_AE_SEL else COL_AE_KEY);
        }
    }
    nowLine(ds_x0, ds_w, r);
    input(i, r, .dopesheet);
    if (drag == .move_ds) {
        var t: [16]u8 = undefined;
        text(mx() + 10, my() - 18, std.fmt.bufPrint(&t, "+{d}", .{dragFrames()}) catch "", COL_AE_SEL);
    }
    drawBox();
}

fn dragFrames() i32 {
    return px(xf(mx(), ds_x0, ds_w) - xf(dx0, ds_x0, ds_w));
}

const Pick = struct { ci: usize, k: ?usize, part: u32 = 0 };

fn dsPick(x: i32, y: i32) ?Pick {
    if (y < ds_y0) return null;
    const row: usize = @intCast(@divTrunc(y - ds_y0, DS_ROW));
    if (row >= n_rows) return null;
    const ci = rows[row];
    const b = anim.cur orelse return null;
    for (b.keysOf(&b.h.cur[ci]), 0..) |*k, q| {
        if (@abs(fx(k.f, ds_x0, ds_w) - x) <= PICK) return .{ .ci = ci, .k = q };
    }
    return .{ .ci = ci, .k = null };
}

// --- the Graph Editor ------------------------------------------------------------------

/// The value range: every key and handle of the scene's curves.
fn geFit() void {
    var lo: f32 = 1.0e30;
    var hi: f32 = -1.0e30;
    if (anim.cur) |b| {
        for (b.curves()) |*c| {
            if (c.act != 0) continue;
            for (b.keysOf(c)) |*k| {
                const a = k.v + k.hly;
                const d = k.v + k.hry;
                for ([_]f32{ k.v, a, d }) |x| {
                    if (x < lo) lo = x;
                    if (x > hi) hi = x;
                }
            }
        }
    }
    if (!(hi >= lo)) {
        hi = 0;
        lo = 0;
    }
    var d = hi - lo;
    if (!(d >= 0.1)) {
        hi += 1;
        lo -= 1;
        d = hi - lo;
    }
    d *= 0.1;
    ge_vmax = hi + d;
    ge_vmin = lo - d;
    if (!(ge_vmax > ge_vmin) or !std.math.isFinite(ge_vmax - ge_vmin)) {
        ge_vmin = -1;
        ge_vmax = 1;
    }
}

fn fix1(buf: []u8, v: f32) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.1}", .{std.math.clamp(v, -1e9, 1e9)}) catch "";
}

pub fn graphEditor(i: i16, r: Rect) void {
    Z = host.beginPart("graph", @intCast(i), r) orelse return;
    defer host.endPart(Z);
    fill(r, ui.th.pane_bg);
    text(r.x + 8, r.y + 4, "Graph Editor   click: select   drag: move a key or a selected key's handle   X delete   A all", COL_AE_TEXT);
    ge_x0 = r.x + GE_L;
    ge_w = @max(r.w - (GE_L + GE_R), 20);
    ge_y0 = r.y + GE_TOP;
    ge_h = @max(r.h - (GE_TOP + 12), 20);
    geFit();
    ruler(ge_x0, ge_w, r);
    var b1: [32]u8 = undefined;
    text(r.x + 4, ge_y0, fix1(&b1, ge_vmax), COL_AE_DIM);
    text(r.x + 4, ge_y0 + ge_h - 16, fix1(&b1, ge_vmin), COL_AE_DIM);
    const zy = gy(0);
    if (zy >= ge_y0 and zy <= ge_y0 + ge_h) line(ge_x0, zy, ge_x0 + ge_w, zy, COL_AE_ROW);
    findRows();
    if (anim.cur) |b| {
        var pts: [2048]zui.Vec2 = undefined;
        for (rows[0..n_rows], 0..) |ci, row| {
            const col = ge_cols[row & 7];
            var n: usize = 0;
            var x: i32 = 0;
            while (x <= ge_w and n < pts.len) : (x += 2) {
                const v = anim.evalCurve(b, ci, xf(ge_x0 + x, ge_x0, ge_w));
                pts[n] = .{ .x = @as(f32, @floatFromInt(ge_x0 + x)) + 0.5, .y = @as(f32, @floatFromInt(gy(v))) + 0.5 };
                n += 1;
            }
            if (n > 1) Z.painter().polyline(pts[0..n], host.col(col), 1, false);
            for (b.keysOf(&b.h.cur[ci])) |*k| {
                const kx = fx(k.f, ge_x0, ge_w);
                const ky = gy(k.v);
                if (k.sel != 0) {
                    const hs = [2][2]f32{ .{ k.hlx, k.hly }, .{ k.hrx, k.hry } };
                    for (hs) |h| {
                        const hx = fx(k.f + h[0], ge_x0, ge_w);
                        const hy = gy(k.v + h[1]);
                        line(kx, ky, hx, hy, COL_AE_HANDLE);
                        fill(.{ .x = hx - 3, .y = hy - 3, .w = 7, .h = 7 }, COL_AE_HANDLE);
                    }
                }
                fill(.{ .x = kx - 4, .y = ky - 4, .w = 9, .h = 9 }, if (k.sel != 0) COL_AE_SEL else COL_AE_KEY);
            }
        }
    }
    nowLine(ge_x0, ge_w, r);
    input(i, r, .graph);
    drawBox();
}

fn gePick(x: i32, y: i32) ?Pick {
    const b = anim.cur orelse return null;
    var best: ?Pick = null;
    var dist: i64 = PICK * PICK + 1;
    for (rows[0..n_rows]) |ci| {
        for (b.keysOf(&b.h.cur[ci]), 0..) |*k, q| {
            var part: u32 = 0;
            while (part < 3) : (part += 1) {
                if (part > 0 and k.sel == 0) break;
                var f = k.f;
                var v = k.v;
                if (part == 1) {
                    f += k.hlx;
                    v += k.hly;
                } else if (part == 2) {
                    f += k.hrx;
                    v += k.hry;
                }
                const dx: i64 = @as(i64, fx(f, ge_x0, ge_w)) - x;
                const dy: i64 = @as(i64, gy(v)) - y;
                const d = dx * dx + dy * dy;
                if (d < dist) {
                    dist = d;
                    best = .{ .ci = ci, .k = q, .part = part };
                }
            }
        }
    }
    return best;
}

// --- input -----------------------------------------------------------------------------

fn run(id: []const u8, words: []const u8) void {
    aops.runText(id, words);
}

fn boxSelect(ed: app.Editor) void {
    const b = anim.cur orelse return;
    const box = boxRect();
    const hit = struct {
        fn f(bx: Rect, x: i32, y: i32) bool {
            return x >= bx.x and x <= bx.right() and y >= bx.y and y <= bx.bottom();
        }
    }.f;
    for (rows[0..n_rows], 0..) |ci, row| {
        const y = ds_y0 + @as(i32, @intCast(row)) * DS_ROW + DS_ROW / 2;
        for (b.keysOf(&b.h.cur[ci])) |*k| {
            const on = if (ed == .graph) hit(box, fx(k.f, ge_x0, ge_w), gy(k.v)) else hit(box, fx(k.f, ds_x0, ds_w), y);
            if (on) k.sel = 1;
        }
    }
}

fn release(ed: app.Editor) void {
    const was = drag;
    drag = .none;
    app.dirty = true;
    var t: [64]u8 = undefined;
    switch (was) {
        .move_ds => {
            const n = dragFrames();
            if (n != 0) run("anim.move_keys", std.fmt.bufPrint(&t, "{d}", .{n}) catch return);
        },
        .move_ge => {
            const n = px(xf(mx(), ge_x0, ge_w) - xf(dx0, ge_x0, ge_w));
            const dv = @as(f32, @floatFromInt(-(my() - dy0))) * (ge_vmax - ge_vmin) / @as(f32, @floatFromInt(ge_h));
            if (n != 0 or dv != 0) run("anim.move_keys", std.fmt.bufPrint(&t, "{d} {d:.3}", .{ n, dv }) catch return);
        },
        .handle => {
            // the handle where the pointer is
            _ = anim.own(0) orelse return;
            const k = keyPtr(d_curve, d_key) orelse return;
            const hx = xf(mx(), ge_x0, ge_w) - k.f;
            const hy = @as(f32, @floatFromInt(ge_y0 + ge_h - my())) * (ge_vmax - ge_vmin) / @as(f32, @floatFromInt(ge_h)) + ge_vmin - k.v;
            k.ht = 1;
            if (side == 2) {
                k.hrx = hx;
                k.hry = hy;
            } else {
                k.hlx = hx;
                k.hly = hy;
            }
            undo.label("Key Handle");
            anim.apply(anim.frame);
        },
        .box => boxSelect(ed),
        else => {},
    }
}

/// The pointer in a key editor: a press picks (a key, a handle, the ruler
/// to scrub) or starts a box; a drag moves; the release does the edit.
fn input(i: i16, r: Rect, ed: app.Editor) void {
    const it = Z.interact(Z.id("##keys"), host.zr(r));
    wantMenu(i, it, &ctx_keys);
    if (d_editor == ed and drag != .none and !it.held and !it.pressed) {
        // let go: the edit
        release(ed);
        return;
    }
    if (it.held and !it.pressed) {
        if (drag == .scrub) {
            const nf = @round(xf(mx(), ds_x0, ds_w));
            if (nf != anim.frame) anim.apply(nf);
        }
        app.dirty = true;
        return;
    }
    if (!it.pressed) return;
    const p0 = Z.input.press_pos.get(.left);
    dx0 = @intFromFloat(p0.x);
    dy0 = @intFromFloat(p0.y);
    d_editor = ed;
    app.dirty = true;
    if (ed == .dopesheet and dy0 < ds_y0) {
        anim.apply(@round(xf(dx0, ds_x0, ds_w)));
        drag = .scrub;
        return;
    }
    const pk = if (ed == .graph) gePick(dx0, dy0) else dsPick(dx0, dy0);
    if (pk != null and pk.?.k != null) {
        const p = pk.?;
        d_curve = p.ci;
        d_key = p.k.?;
        if (ed == .graph and p.part != 0) {
            side = p.part;
            drag = .handle;
            sameFrameRelease(ed);
            return;
        }
        const k = keyPtr(p.ci, p.k.?) orelse return;
        if (shift()) {
            k.sel ^= 1;
            return;
        }
        if (k.sel == 0) {
            aops.selAll(false);
            k.sel = 1;
        }
        drag = if (ed == .graph) .move_ge else .move_ds;
        sameFrameRelease(ed);
        return;
    }
    // nothing: the selection clears, and a drag is a box
    if (!shift()) aops.selAll(false);
    drag = .box;
    sameFrameRelease(ed);
}

/// A press and its release in one frame (a quick drag, a batch of input):
/// the edit at once.
fn sameFrameRelease(ed: app.Editor) void {
    if (!Z.input.mouse_down.contains(.left)) release(ed);
}
