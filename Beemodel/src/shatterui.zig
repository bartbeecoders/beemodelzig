// Properties > Physics > Shatter (physui.s rp_shatter, sp_run, sp_sync): the
// pattern and preset, count and seed, glue (and Show glued faces), the blow it
// breaks at, a brick's gap, the cut faces' colour, then Shatter (on a piece
// whose original is hidden: Re-cut, "again"). The values are the panel's own
// (a preset shows its pattern and values); the last shatter's are shown after
// it (sync). The button runs object.shatter with what differs from the preset
// (its own undo step). physui.zig draws the section's heading and calls props.
const std = @import("std");
const zui = @import("zui");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const scene = @import("scene.zig");
const Rect = gfx.Rect;

const pat_labels = [_][]const u8{ "Shards", "Bricks", "Balls" };
const pat_kw = [_][]const u8{ "shards ", "bricks ", "balls " };
const pre_labels = [_][]const u8{ "No preset", "Brick wall", "Glass", "Stone", "Gravel balls" };
const pre_kw = [_][]const u8{ "", "preset brickwall ", "preset glass ", "preset stone ", "preset gravel " };
/// (so_pdata: pattern, count, glue, impact)
const pre_vals = [4]struct { pat: u32, count: f32, glue: f32, impact: f32 }{
    .{ .pat = 1, .count = 50, .glue = 40000, .impact = 0 },
    .{ .pat = 0, .count = 60, .glue = 15000, .impact = 10 },
    .{ .pat = 0, .count = 25, .glue = 150000, .impact = 0 },
    .{ .pat = 2, .count = 300, .glue = 0, .impact = 0 },
};

/// The panel's settings (sp_*).
pub var pat: u32 = 0;
pub var pre: u32 = 0;
pub var count: f32 = 50;
pub var glue: f32 = 0;
pub var impact: f32 = 0;
pub var seed: f32 = 1;
pub var gap: f32 = 0;
pub var inner_on = false;
pub var paint = false;
/// sRGB as shown (the original's linear 0.36 0.34 0.31: #99958e)
pub var inner: u32 = 0x99958e;

/// sp_sync: the last shatter's settings, shown for a re-cut.
pub fn sync(p: u32, preset: u32, n: i32, g: f32, imp: f32) void {
    pat = p;
    pre = preset;
    count = @floatFromInt(n);
    glue = g;
    impact = imp;
}

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

const Pick = enum { pat, pre };
fn labels(w: Pick) []const []const u8 {
    return if (w == .pat) &pat_labels else &pre_labels;
}
fn pickSet(what: Pick, k: usize) void {
    if (what == .pat) {
        pat = @intCast(k);
        pre = 0; // (pat_cb)
        return;
    }
    pre = @intCast(k);
    if (pre == 0) return;
    const v = pre_vals[pre - 1]; // (pre_cb: its pattern and values shown)
    pat = v.pat;
    count = v.count;
    glue = v.glue;
    impact = v.impact;
}

/// The caption at the left (recorded as `caption`), a list at the right
/// half (`enum:<shown>`).
fn capEnum(z: *zui.Ui, cap: []const u8, what: Pick, tip: []const u8) void {
    z.beginHorizontal(.{ .spacing = 6, .alignment = .center });
    z.label(cap, .{ .color = host.col(ui.th.text_dim), .width = .px(cap_w) });
    ui.record("caption", cap, host.rectOf(z.lastRect()), true);
    const ls = labels(what);
    var items: [8]zui.Choice = undefined;
    for (ls, 0..) |l, k| items[k] = .{ .label = l };
    var sel: usize = @min(if (what == .pat) pat else pre, ls.len - 1);
    z.pushId(cap);
    const r = z.dropdown("##list", &sel, items[0..ls.len], .{ .width = .fill });
    z.popId();
    ui.record("enum", items[sel].label, host.rectOf(r.rect), true);
    z.tooltipRich(r, .{ .title = cap, .body = tip });
    z.endHorizontal();
    if (r.changed) pickSet(what, sel);
}

/// Re-cut: the active object a piece whose original is hidden.
fn recut() bool {
    const a = scene.active orelse return false;
    if (a >= scene.count) return false;
    const p = scene.objects[a].parent orelse return false;
    return !scene.objects[p].visible;
}

/// The section's rows in the column `bd` from y0 (below its heading): y below.
pub fn props(i: i16, bd: Rect, y0: i32) i32 {
    cap_w = @floatFromInt((bd.w >> 1) - 3);
    var f = bkit.Flow.begin("shatter", @intCast(i), bd, y0);
    if (f.z) |z| {
        // (22 a row, 4 between: the original's pitch, as physui's rows)
        beginColumn(z, bd.w, 4);
        describe(z);
        endColumn(z);
    }
    return f.end();
}

fn describe(z: *zui.Ui) void {
    capEnum(z, "Pattern", .pat, "Shards (Voronoi cells), bricks (a running bond) or balls");
    capEnum(z, "Preset", .pre, "A pattern and values to start from");
    bkit.beginPair(z);
    {
        var c = @round(count);
        if (bkit.numberRow(z, "Count", &c, .{ .step = 0.25, .min = 1, .max = 4096, .decimals = 0, .tip = "Shards: cells. Bricks: a row (in half as many rows). Balls: about how many" }).changed) count = @round(c);
        _ = bkit.numberRow(z, "Seed", &seed, .{ .step = 0.1, .min = 0, .max = 100000, .decimals = 0, .tip = "Another seed: other cells" });
        seed = @round(seed);
    }
    bkit.endPair(z);
    _ = bkit.numberRow(z, "Glue (N/m2)", &glue, .{ .step = 200, .min = 0, .max = 100000000, .decimals = 0, .tip = "Joints between touching pieces, this strong per square metre of shared face (0: none). A blow breaks those near it" });
    if (glue != 0) _ = bkit.checkRow(z, "Show glued faces", &paint, "");
    _ = bkit.numberRow(z, "Breaks at (N s, 0 now)", &impact, .{ .step = 0.5, .min = 0, .max = 1000000, .decimals = 1, .tip = "Whole until a blow of this size, then it breaks while the simulation runs" });
    if (pat == 1) _ = bkit.numberRow(z, "Gap (m)", &gap, .{ .step = 0.001, .min = 0, .max = 1, .decimals = 3, .tip = "Bricks: a mortar gap taken off every face" });
    bkit.beginPair(z);
    {
        // (the check box half the width, the colour the other half)
        z.beginGroup(.{ .width = .fill });
        _ = bkit.checkRow(z, "Colour the cut faces", &inner_on, "");
        z.endGroup();
        if (inner_on) _ = bkit.colourRow(z, "Colour", &inner, null, "") else z.spacer(.fill);
    }
    bkit.endPair(z);
    const again = recut();
    const label = if (again) "Re-cut" else "Shatter";
    // (the panel's main action: the accent fill, as the original's WGF_PRIMARY)
    z.pushColor(.button, host.col(ui.th.accent));
    z.pushColor(.button_hovered, host.col(ui.th.accent));
    z.pushColor(.text, host.col(ui.th.accent_text));
    const b = bkit.button(z, label, "Break it with these settings (on a piece: Re-cut, the original broken again)");
    z.popStyles(3);
    if (b.clicked) {
        // (Zui acts in BeeModel's draw pass, and an event Zui takes skips
        // app.afterInput's undo.sync: what came before is its own step, and
        // the shatter one now, not at the next event)
        const undo = @import("undo.zig");
        undo.sync();
        var buf: [256]u8 = undefined;
        @import("animops.zig").runText("object.shatter", argText(&buf, again));
        undo.sync();
    }
    z.spacer(.px(0));
}

/// fmt_val3: up to three decimals, trailing zeros off.
fn val3(w: anytype, x0: f32) void {
    var x = x0;
    if (!(x >= 0)) {
        w.writeByte('-') catch {};
        x = 0 - x;
    }
    const v: u32 = @bitCast(cvtts(x * 1000.0 + 0.5));
    w.print("{d}", .{v / 1000}) catch {};
    const f = v % 1000;
    if (f == 0) return;
    var d = [3]u8{ '0' + @as(u8, @intCast(f / 100)), '0' + @as(u8, @intCast(f / 10 % 10)), '0' + @as(u8, @intCast(f % 10)) };
    var n: usize = 3;
    while (n > 1 and d[n - 1] == '0') n -= 1;
    w.writeByte('.') catch {};
    w.writeAll(d[0..n]) catch {};
}

fn cvtts(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}
fn cvtss(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return std.math.minInt(i32);
    var r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5 and @mod(r, 2) != 0) r -= std.math.sign(x);
    return @intFromFloat(r);
}

/// sp_run's argument: what differs from the preset.
pub fn argText(buf: []u8, again: bool) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    if (again) w.writeAll("again ") catch {};
    w.writeAll(pre_kw[pre]) catch {};
    const pv = if (pre > 0) pre_vals[pre - 1] else null;
    if (pv == null or pv.?.pat != pat) w.writeAll(pat_kw[pat]) catch {};
    w.print("count {d}", .{cvtss(count)}) catch {};
    const sd: u32 = @intFromFloat(seed);
    if (sd != 1) w.print(" seed {d}", .{sd}) catch {};
    const gb: u32 = @bitCast(glue);
    const show_glue = paint or (if (pv) |v| gb != @as(u32, @bitCast(v.glue)) else gb != 0);
    if (show_glue) {
        w.writeAll(" glue ") catch {};
        val3(&w, glue);
        if (paint) w.writeAll(" paint") catch {};
    }
    const ib: u32 = @bitCast(impact);
    if (if (pv) |v| ib != @as(u32, @bitCast(v.impact)) else ib != 0) {
        w.writeAll(" impact ") catch {};
        val3(&w, impact);
    }
    if (pat == 1 and gap != 0) {
        w.writeAll(" gap ") catch {};
        val3(&w, gap);
    }
    if (inner_on) {
        w.writeAll(" inner ") catch {};
        var sh: u5 = 16;
        while (true) {
            const b: f32 = @floatFromInt((inner >> sh) & 255);
            val3(&w, b / 255.0);
            if (sh == 0) break;
            w.writeByte(' ') catch {};
            sh -= 8;
        }
    }
    return w.buffered();
}

test "sp_run's words" {
    var b: [256]u8 = undefined;
    pat = 0;
    pre = 0;
    count = 50;
    seed = 1;
    glue = 0;
    impact = 0;
    try std.testing.expectEqualStrings("shards count 50", argText(&b, false));
    pre = 2;
    pat = 0;
    count = 60;
    glue = 15000;
    impact = 10;
    try std.testing.expectEqualStrings("again preset glass count 60", argText(&b, true));
    glue = 2500.5;
    inner_on = true;
    inner = 0x99958e;
    try std.testing.expectEqualStrings("preset glass count 60 glue 2500.5 inner 0.6 0.584 0.557", argText(&b, false));
    inner_on = false;
}
