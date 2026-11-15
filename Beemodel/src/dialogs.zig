// Dialogs. Drawn by Zui (clients of zuihost.zig): About, Keyboard Shortcuts
// (every shortcut, searchable; F1), Undo History (click a step to go there),
// the operator forms (forms.zig), and the prompts: "Save changes?", saving
// over a file with parts the port does not keep, recovering an autosave.
// The Preferences are zuiprefs.zig's, also in an area of the layout
// (`areaBody`). The welcome screen and Ask AI are still drawn by BeeModel
// (welcome.zig, aiask.zig; milestones M6 and M5).
const std = @import("std");
const zui = @import("zui");
const host = @import("zuihost.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const ops = @import("ops.zig");
const cat = @import("catalog.zig");
const undo = @import("undo.zig");
const app = @import("app.zig");
const files = @import("files.zig");
const colorpick = @import("colorpick.zig");

const Rect = gfx.Rect;
const col = host.col;

pub const Kind = enum { about, shortcuts, history, prefs, form, welcome, ask };

var cur: ?Kind = null;

pub fn isOpen() bool {
    return cur != null;
}

/// The dialog shown, if any.
pub fn current() ?Kind {
    return cur;
}

/// The Preferences are being drawn in an area of the layout.
pub fn inArea() bool {
    return in_area;
}

pub fn open(k: Kind) void {
    cur = k;
    if (k == .shortcuts) {
        sc_len = 0;
        sc_st = .{};
        sc_scroll_to_top = true;
        sc_focus = true;
    }
    if (k == .prefs) @import("zuiprefs.zig").opened();
    if (k == .history) {
        // the current step in view
        hist_st = .{ .cursor = undo.current(), .reveal = true };
    }
    app.dirty = true;
}

pub fn close() void {
    if (cur == .ask) @import("aiask.zig").closing(); // (its prompt stops taking keys)
    cur = null;
    @import("keys.zig").capture = null; // (Set no longer waits for its key)
    if (colorpick.open) colorpick.close();
    app.dirty = true;
}

pub fn dim(cv: *gfx.Canvas) void {
    if (!cv.enabled) return;
    const n: usize = @intCast(cv.w * cv.h);
    for (cv.px[0..n]) |*p| p.* = (p.* >> 1) & 0x7f7f7f;
}

// --- the Preferences in an area ------------------------------------------------------

var in_area = false;

/// The Preferences in an area of the layout: the same page, without the box.
pub fn areaBody(r: Rect) void {
    in_area = true;
    defer in_area = false;
    @import("zuiprefs.zig").areaPart(r);
}

// --- Zui's dialogs ---------------------------------------------------------------------

/// About, Shortcuts, Undo History and the forms, as one modal client.
pub const client: host.Client = .{
    .visible = zuiShown,
    .describe = describe,
    .modal = true,
    .key = dialogKey,
};

fn zuiShown() bool {
    return switch (cur orelse return false) {
        .about, .shortcuts, .history, .form, .ask, .welcome => true,
        else => false,
    };
}

fn describe(z: *zui.Ui) void {
    switch (cur orelse return) {
        .about => about(z),
        .shortcuts => shortcuts(z),
        .history => history(z),
        .form => @import("forms.zig").describe(z),
        .ask => @import("aiask.zig").describe(z),
        .welcome => @import("welcome.zig").describe(z),
        else => {},
    }
}

/// Esc closes the shortcuts at once, typed search or not; Up / Down /
/// Page Up / Page Down scroll the shortcuts while the search is typed in
/// (the lists take them themselves when focused).
fn dialogKey(z: *zui.Ui, code: u32) bool {
    const K = ui.KEY;
    if (cur == .ask) return @import("aiask.zig").key(z, code);
    if (cur != .shortcuts) return false;
    if (code == K.ESC) {
        close();
        return true;
    }
    if (z.focused == sc_list_id) return false;
    const rows: f32 = switch (code) {
        K.UP => -1,
        K.DOWN => 1,
        K.PAGEUP => -10,
        K.PAGEDOWN => 10,
        else => return false,
    };
    if (z.scroll_states.getPtr(sc_list_id)) |st| st.scroll = @max(0, st.scroll + rows * ROW_H);
    z.requestRedraw();
    return true;
}

var dlg_open = true;

/// A Zui dialog titled `title`; `outside_closes`: a click outside it closes
/// it, as BeeModel's About, Shortcuts and History. Describe its content when
/// true, then call `endDialog`.
pub fn beginDialog(z: *zui.Ui, title: []const u8, min_width: f32, outside_closes: bool) bool {
    if (outside_closes and host.pressedOutsideDialog(z)) {
        close();
        return false;
    }
    dlg_open = true;
    return z.beginDialog(title, &dlg_open, .{ .min_width = min_width });
}

/// Ends it; Escape (not used by a button) closes the dialog.
pub fn endDialog(z: *zui.Ui) void {
    z.endDialog();
    if (!dlg_open) close();
}

fn muted(z: *zui.Ui, s: []const u8) void {
    z.pushColor(.text, col(ui.th.text_dim));
    z.label(s, .{});
    z.popStyle();
}

fn about(z: *zui.Ui) void {
    if (!beginDialog(z, "About BeeModel", 360, true)) return;
    defer endDialog(z);
    var b1: [96]u8 = undefined;
    z.pushColor(.text, col(ui.th.accent));
    z.label("BeeModel - Zig", .{});
    z.popStyle();
    z.spacer(.{ .fixed = 6 });
    const lines = [_][]const u8{
        "A 3D modeling tool written in Zig.",
        "It links nothing: no libc, no libwayland, no",
        "toolkit. It speaks the Wayland wire protocol on a",
        "UNIX socket and draws every pixel in software.",
        "Its UI is drawn by BeeZigUi.",
    };
    for (lines) |l| z.label(l, .{});
    z.spacer(.{ .fixed = 6 });
    z.label(std.fmt.bufPrint(&b1, "{d} of its {d} commands are available so far.", .{ ops.implementedCount(), ops.N }) catch "", .{});
    z.label("Built with Zig " ++ @import("builtin").zig_version_string, .{});
    if (z.dialogButtons(&.{"OK"}, .{ .default = 0, .cancel = 0 }) != null) close();
}

// --- Keyboard Shortcuts -------------------------------------------------------------------

var sc_query: [96]u8 = undefined;
var sc_len: usize = 0;
var sc_st: zui.ListState = .{};
var sc_sel: [ops.N]bool = @splat(false);
var sc_list_id: zui.Id = .none;
var sc_scroll_to_top = false;
var sc_focus = false;

fn containsI(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

const SC_W = 720;
const ROW_H = 22;

fn rowsShown() usize {
    return @intCast(std.math.clamp(@divTrunc(@divTrunc(app.winH() * 8, 10) - 170, ROW_H), 6, 24));
}

/// A frameless Zui list `rows` rows high, its rows ROW_H apart (until `endRows`).
fn beginRows(z: *zui.Ui, name: []const u8, sel: []bool, st: *zui.ListState, rows: usize) zui.List {
    z.pushMetric(.frame_padding, .{ .x = 8, .y = @max(0, ROW_H - z.textSize("").y) });
    const l = z.beginList(name, sel, st, .{ .height = .px(@as(f32, @floatFromInt(rows)) * ROW_H + 4), .frame = false });
    z.popStyle();
    return l;
}

fn shortcuts(z: *zui.Ui) void {
    if (!beginDialog(z, "Keyboard Shortcuts", SC_W, true)) return;
    defer endDialog(z);
    const t = ui.th;
    if (sc_focus) {
        sc_focus = false;
        z.setFocus(z.id("##Search shortcuts"));
    }
    const f = z.textInput("##Search shortcuts", &sc_query, &sc_len, .{ .width = .fill, .hint = "Search shortcuts: a key, a command or what it does" });
    const q = sc_query[0..sc_len];

    var list: [ops.N]u16 = undefined;
    var n: usize = 0;
    var kb: [40]u8 = undefined;
    for (&cat.entries, 0..) |*e, i| {
        if (@import("keys.zig").code_of[i] == 0 or e.hidden) continue;
        const key_s = ops.keyLabel(i, &kb);
        if (q.len > 0 and !containsI(e.label, q) and !containsI(e.id, q) and !containsI(key_s, q) and !containsI(e.doc, q)) continue;
        list[n] = @intCast(i);
        n += 1;
    }
    // what works first, then by name
    std.sort.pdq(u16, list[0..n], {}, struct {
        fn lt(_: void, a: u16, b: u16) bool {
            const ia = ops.implemented(a);
            const ib = ops.implemented(b);
            if (ia != ib) return ia;
            return std.mem.lessThan(u8, cat.entries[a].label, cat.entries[b].label);
        }
    }.lt);

    // the list (no selection: a row is a tooltip and a click on it nothing)
    sc_list_id = z.id("##shortcuts");
    if (f.changed or sc_scroll_to_top) {
        sc_scroll_to_top = false;
        if (z.scroll_states.getPtr(sc_list_id)) |st| st.scroll = 0;
    }
    @memset(sc_sel[0..n], false);
    var l = beginRows(z, "##shortcuts", sc_sel[0..n], &sc_st, rowsShown());
    for (l.first..l.end) |k| {
        const i = list[k];
        const e = &cat.entries[i];
        const on = ops.implemented(i);
        const ks = ops.keyLabel(i, &kb);
        const fg = col(if (on) t.text else t.text_off);
        z.beginRow(&l, k, .{ .label = "" });
        const it = z.endRow(&l).interaction;
        // (after the row: inside it, its label's clip would cut the key)
        const row = it.rect;
        const ty = row.y + (row.h - z.textSize("").y) / 2;
        const kw = @min(150, z.textSize(ks).x + 10);
        z.drawRect(.{ .rect = .{ .x = row.x, .y = row.y + 2, .w = kw, .h = row.h - 4 }, .fill = col(t.btn), .radius = 3 });
        z.pushClip(.{ .x = row.x, .y = row.y, .w = kw, .h = row.h });
        z.drawText(.{ .x = row.x + 5, .y = ty }, fg, ks);
        z.popClip();
        z.drawText(.{ .x = row.x + 164, .y = ty }, fg, e.label);
        if (!on) z.drawText(.{ .x = row.x + 176 + z.textSize(e.label).x, .y = ty }, col(t.text_off), "(not available yet)");
        ui.record("shortcut", e.label, host.rectOf(row), on);
        z.tooltipRich(it, .{ .title = e.label, .shortcut = ks, .body = e.doc, .warning = if (on) "" else ops.not_ported });
    }
    _ = z.endList(&l);
    var fb: [96]u8 = undefined;
    muted(z, std.fmt.bufPrint(&fb, "{d} shortcuts   Wheel / PageUp / PageDown scroll   Esc closes", .{n}) catch "");
}

// --- Undo History ---------------------------------------------------------------------------

var hist_st: zui.ListState = .{};
var hist_sel: [undo.N + 1]bool = @splat(false);

/// The steps, the current one in the accent and the undone ones dimmed; a
/// click (or the keyboard, the list focused) goes to a step.
fn history(z: *zui.Ui) void {
    if (!beginDialog(z, "Undo History", 380, true)) return;
    defer endDialog(z);
    const t = ui.th;
    const n = @min(undo.count(), hist_sel.len);
    const now = undo.current();
    for (hist_sel[0..n], 0..) |*s, k| s.* = k == now;
    var l = beginRows(z, "##steps", hist_sel[0..n], &hist_st, std.math.clamp(n, 6, 16));
    z.pushColor(.button_active, col(t.accent));
    for (l.first..l.end) |k| {
        var b: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "{d:>3}  {s}", .{ k, undo.nameOf(k) }) catch "";
        z.beginRow(&l, k, .{ .label = s, .text_color = col(if (k == now) t.accent_text else if (k > now) t.text_off else t.text) });
        const r = z.endRow(&l);
        // BeeModel's name for a step, as the tests click it
        ui.record("step", undo.nameOf(k), host.rectOf(r.rect), true);
    }
    z.popStyle();
    const lr = z.endList(&l);
    if (lr.changed) if (hist_st.cursor) |k| if (k < n and k != now) {
        undo.goto(k);
        app.toast(.ok, "History: step {d}, {s}", .{ k, undo.nameOf(k) });
    };
    if (z.dialogButtons(&.{"OK"}, .{ .default = 0, .cancel = 0 }) != null) close();
}

// --- the prompts -------------------------------------------------------------------------

/// "Save changes?", saving over a lossy file, recovering an autosave.
pub const prompt_client: host.Client = .{
    .visible = promptShown,
    .describe = prompt,
    .modal = true,
};

fn promptShown() bool {
    return files.asking or files.asking_lossy or @import("autosave.zig").asking;
}

fn prompt(z: *zui.Ui) void {
    if (@import("autosave.zig").asking) return @import("autosave.zig").describe(z);
    if (files.asking_lossy) return lossy(z);
    if (files.asking) return saveChanges(z);
}

/// The open flag of a prompt: it has a Cancel of its own, so Escape presses that.
var prompt_open = true;

/// "Save changes?" before New, Open, Exit: the original's wording and order.
fn saveChanges(z: *zui.Ui) void {
    prompt_open = true;
    if (!z.beginDialog("Save changes to this scene?", &prompt_open, .{ .min_width = 400 })) return;
    defer z.endDialog();
    muted(z, "Your changes are lost if you don't save them.");
    if (z.dialogButtons(&.{ "Don't Save", "Cancel", "Save" }, .{ .default = 2, .cancel = 1 })) |b| {
        files.answer(switch (b) {
            0 => .discard,
            1 => .cancel,
            else => .save,
        });
    }
}

/// Saving over a file with parts the port does not keep.
fn lossy(z: *zui.Ui) void {
    prompt_open = true;
    if (!z.beginDialog("Save over this file?", &prompt_open, .{ .min_width = 460 })) return;
    defer z.endDialog();
    var b: [300]u8 = undefined;
    muted(z, std.fmt.bufPrint(&b, "{s} has parts BeeModel does not keep yet", .{files.name()}) catch "");
    muted(z, "(materials, modifiers, sketches ...): saving over it loses them.");
    if (z.dialogButtons(&.{ "Save Anyway", "Cancel", "Save As..." }, .{ .default = 2, .cancel = 1 })) |p| {
        files.answerLossy(switch (p) {
            0 => .overwrite,
            1 => .cancel,
            else => .save_as,
        });
    }
}

/// For autosave.describe: a muted line of a prompt.
pub fn promptLine(z: *zui.Ui, s: []const u8) void {
    muted(z, s);
}

/// For autosave.describe: begins the recover prompt (Escape: Not Now).
pub fn beginPrompt(z: *zui.Ui, title: []const u8, min_width: f32) bool {
    prompt_open = true;
    return z.beginDialog(title, &prompt_open, .{ .min_width = min_width });
}
