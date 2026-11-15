//! Properties > Object > Text (textui.s tx_props): a text object's settings.
//! The body is one line to type, with \n where a new line starts; the font is
//! a list of the fonts on the system (Default: the UI's sans); then size,
//! depth, bevel, alignment, spacing, line height, slant and quality; letter by
//! letter: reveal, how a letter appears, over how many, a wave; and Convert to
//! Mesh. The values come from the text block each pass into tu_*; a change
//! builds a new block from them (text3d.setValues) and names the undo step
//! "Text", as the original's callbacks do after the widget's undo step.
//!
//! On Zui (bkit.Flow in the Object tab's page): a caption at the left with
//! its list on the right half, as the original's column.
const std = @import("std");
const zui = @import("zui");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const scene = @import("scene.zig");
const undo = @import("undo.zig");
const tx = @import("text3d.zig");
const Rect = gfx.Rect;

var tu_flt: [tx.NFLOAT]f32 = undefined;
var tu_align: u32 = 0;
var tu_rmode: u32 = 0;
var tu_font: u32 = 0;
var tu_body: [tx.BODY_MAX * 2]u8 = undefined;
var tu_body_n: usize = 0;
var obj: usize = 0;
/// The caption column: half the panel's width.
var cap_w: f32 = 100;
var col_w: i32 = 200;

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

const l_aligns = [_][]const u8{ "Left", "Center", "Right" };
const l_modes = [_][]const u8{ "Pop", "Scale", "Rise", "Drop" };

/// tu_val_cb: the shown values into a new block.
fn changed() void {
    if (tx.txActive() != obj) return;
    tx.setValues(obj, tu_flt, tu_align, tu_rmode, null, null);
    undo.label("Text");
}

const Pick = enum { font, alignment, mode };

fn pickSet(what: Pick, k: usize) void {
    if (tx.txActive() != obj) return;
    switch (what) {
        .font => {
            // tu_font_cb: its name, or Default (empty)
            tu_font = @intCast(k);
            tx.setValues(obj, tu_flt, tu_align, tu_rmode, null, tx.tfLabel(@intCast(k)) orelse "");
        },
        .alignment => {
            tu_align = @intCast(k);
            tx.setValues(obj, tu_flt, tu_align, tu_rmode, null, null);
        },
        .mode => {
            tu_rmode = @intCast(k);
            tx.setValues(obj, tu_flt, tu_align, tu_rmode, null, null);
        },
    }
    undo.label("Text");
}

/// (the font list can be long: every .ttf on the system)
var items: [4200]zui.Choice = undefined;

/// pnl_caption + a list (WK_ENUM) on the right half: the caption recorded
/// as `caption`, the list as `enum:<shown>`.
fn capEnum(z: *zui.Ui, cap: []const u8, what: Pick, n0: usize, tip: []const u8) void {
    z.beginHorizontal(.{ .spacing = 6, .alignment = .center });
    z.label(cap, .{ .color = host.col(ui.th.text_dim), .width = .px(cap_w) });
    ui.record("caption", cap, host.rectOf(z.lastRect()), true);
    const n = @min(n0, items.len);
    for (0..n) |k| items[k] = .{ .label = switch (what) {
        .font => tx.tfRowLabel(k),
        .alignment => l_aligns[k],
        .mode => l_modes[k],
    } };
    const cur: usize = switch (what) {
        .font => tu_font,
        .alignment => tu_align,
        .mode => tu_rmode,
    };
    var sel: usize = @min(cur, if (n == 0) 0 else n - 1);
    const r = step(z.dropdown(switch (what) {
        .font => "##font",
        .alignment => "##align",
        .mode => "##appear",
    }, &sel, items[0..n], .{ .width = .fill }));
    if (n > 0) ui.record("enum", items[sel].label, host.rectOf(r.rect), true);
    z.tooltipRich(r, .{ .title = cap, .body = tip });
    z.endHorizontal();
    if (r.changed) pickSet(what, sel);
}

const NumOpts = struct { step: f32, lo: f32, hi: f32, dec: u8, slider: bool = false };

/// pnl_full: a number field across the column (I over it: text:<name>:<value>).
fn num(z: *zui.Ui, k: usize, label: []const u8, o: NumOpts, tip: []const u8) void {
    const it = step(bkit.numberRow(z, label, &tu_flt[k], .{ .step = o.step, .min = o.lo, .max = o.hi, .decimals = o.dec, .slider = o.slider, .tip = tip, .path = .{ .text = @intCast(k) } }));
    if (it.changed) changed();
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


/// pnl_hint: dim, wrapped to the column; recorded as `info`.
fn hint(z: *zui.Ui, s: []const u8) void {
    z.wrappedText(s, .{ .color = host.col(ui.th.text_dim) });
    ui.record("info", s, host.rectOf(z.lastRect()), true);
}

/// tx_props(y, text object): its Text section; the y below it.
pub fn props(salt: usize, s: usize, x: i32, w: i32, y0: i32) i32 {
    const b = tx.txOf(s) orelse return y0;
    obj = s;
    // its values, as they are
    tu_flt = b.f;
    tu_align = b.alignment;
    tu_rmode = b.rmode;
    tu_body_n = 0;
    for (b.bodyText()) |c| {
        if (c == 10) {
            tu_body[tu_body_n] = '\\';
            tu_body[tu_body_n + 1] = 'n';
            tu_body_n += 2;
        } else {
            tu_body[tu_body_n] = c;
            tu_body_n += 1;
        }
    }
    tu_font = tx.tfIndex(b.fontName());
    cap_w = @floatFromInt((w >> 1) - 3);
    col_w = w;
    var f = bkit.Flow.begin("text", salt, .{ .x = x, .y = y0, .w = w, .h = 0 }, y0);
    if (f.z) |z| {
        did = false;
        describe(z, s);
        if (did) undo.sync();
    }
    return f.end();
}

fn describe(z: *zui.Ui, s: usize) void {
    // (rows 26 apart, as the original's column: the panel is long)
    beginColumn(z, col_w, 4);
    defer endColumn(z);
    z.spacer(.px(6));
    {
        z.pushFont(host.headFont());
        defer z.popFont();
        z.label("Text", .{ .color = host.col(ui.th.accent_fg) });
        ui.record("heading", "Text", host.rectOf(z.lastRect()), true);
    }
    // (the fields change the active text, as the original's callbacks do)
    const active = tx.txActive() == s;
    if (bkit.textRow(z, "##body", tu_body[0..tu_body_n], "")) |t| {
        if (active) {
            undo.sync();
            tx.setValues(s, tu_flt, tu_align, tu_rmode, t, null);
            undo.label("Text");
            did = true;
        }
    }
    {
        const lr = z.lastRect();
        z.tooltipRich(.{ .rect = lr, .hovered = lr.contains(z.input.mouse_pos) }, .{ .title = "Text", .body = "What it says (Enter applies). \\n starts a new line. An expression in curly brackets (frame, time, floor(time / 60)) is worked out every frame: counters and clocks" });
    }
    capEnum(z, "Font", .font, tx.tfCount(), "The font: any TrueType font on the system (Default: the interface's)");
    num(z, tx.F_SIZE, "Size (m)", .{ .step = 0.01, .lo = 0.001, .hi = 10000, .dec = 3 }, "The height of a line of capitals and descenders (the em). Keyframe it as text:Name:size");
    num(z, tx.F_DEPTH, "Depth (m)", .{ .step = 0.005, .lo = 0, .hi = 10000, .dec = 3 }, "How thick the letters are (0: flat)");
    num(z, tx.F_BEVEL, "Bevel (m)", .{ .step = 0.002, .lo = 0, .hi = 1000, .dec = 3 }, "A 45-degree chamfer round the front and back edges (at most half the depth)");
    capEnum(z, "Align", .alignment, 3, "Where the lines sit: right of the origin, centred on it, or left of it");
    num(z, tx.F_SPACING, "Letter spacing (em)", .{ .step = 0.005, .lo = -1, .hi = 10, .dec = 3 }, "Extra room between letters, in ems");
    num(z, tx.F_LINE, "Line height (em)", .{ .step = 0.01, .lo = 0, .hi = 100, .dec = 2 }, "From one line's baseline to the next, in ems");
    num(z, tx.F_SHEAR, "Slant", .{ .step = 0.01, .lo = -2, .hi = 2, .dec = 2 }, "Leans the letters (italic): sideways per unit up");
    num(z, tx.F_QUALITY, "Quality", .{ .step = 0.01, .lo = 0.25, .hi = 8, .dec = 2 }, "How finely curves are cut into straight pieces (1: normal)");
    z.spacer(.px(0)); // (4 more between, as the original)
    hint(z, "Letter by letter (I over a value: key)");
    num(z, tx.F_REVEAL, "Reveal", .{ .step = 0.005, .lo = 0, .hi = 1, .dec = 2, .slider = true }, "How much of the text shows, letter by letter (0 none, 1 all). Key it from 0 to 1 to type it on: text:Name:reveal");
    capEnum(z, "Appear", .mode, 4, "How each letter appears: at once (a typewriter), growing, rising from below or dropping from above");
    num(z, tx.F_SOFT, "Over letters", .{ .step = 0.05, .lo = 0, .hi = 100, .dec = 1 }, "How many letters are appearing at a time (Scale, Rise, Drop)");
    num(z, tx.F_WAVE, "Wave (em)", .{ .step = 0.005, .lo = -10, .hi = 10, .dec = 3 }, "Letters bob up and down by this much, along a wave. Key the phase to make it travel");
    num(z, tx.F_WLEN, "Wavelength (letters)", .{ .step = 0.05, .lo = 0.1, .hi = 1000, .dec = 1 }, "How many letters one wave spans");
    num(z, tx.F_PHASE, "Phase (turns)", .{ .step = 0.01, .lo = -1000, .hi = 1000, .dec = 2 }, "Where along the wave the first letter is: key it from 0 to 1 and the wave travels once along the text");
    z.spacer(.px(0));
    if (step(bkit.button(z, "Convert to Mesh", "Make it a plain mesh to edit (the text is no longer editable)")).clicked) {
        @import("ops.zig").runId("text.to_mesh");
    }
    z.spacer(.px(4));
}
