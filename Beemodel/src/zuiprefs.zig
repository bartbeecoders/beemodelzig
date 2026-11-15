// The Preferences, drawn by Zui: as a dialog (a client of zuihost.zig, Ctrl+,)
// and in an area of the layout (a part, `areaPart`). The values are
// BeeModel's (prefs.zig, prefpages.zig, keys.zig, ai.zig, agent.zig); only the
// drawing and the widgets are Zui's.
const std = @import("std");
const zui = @import("zui");
const host = @import("zuihost.zig");
const bkit = @import("bkit.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const theme = @import("theme.zig");
const prefs = @import("prefs.zig");
const pp = @import("prefpages.zig");
const keys = @import("keys.zig");
const cat = @import("catalog.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const dialogs = @import("dialogs.zig");
const scale = @import("scale.zig");

const Rect = gfx.Rect;
const col = host.col;
const zr = host.zr;
const at = host.at;

/// The dialog as a client of the host: modal, over BeeModel's dimmed UI.
pub const client: host.Client = .{
    .visible = active,
    .describe = describeClient,
    .modal = true,
    .key = key,
    .under = under,
};

// What the dialog shows: a category or a search, as BeeModel's.
var pref_cat: usize = 0;
var query: [64]u8 = undefined;
var query_len: usize = 0;
var find: [48]u8 = undefined;
var find_len: usize = 0;
var accent_edit: zui.Color = zui.Color.hex(0xf2b134);

const categories = [_][]const u8{ "Interface", "Viewport", "Input", "Keymap", "Rendering", "System", "Files", "AI" };

/// Whether Zui has the Preferences now.
pub fn active() bool {
    return dialogs.current() == .prefs and !dialogs.inArea();
}

/// The dialog opened: a fresh look, as BeeModel's.
pub fn opened() void {
    query_len = 0;
    host.get().focused = .none;
}

/// A key before Zui sees it: the keymap's Set takes it, Esc and Enter
/// close the dialog (when no list is open and no field is typed in).
fn key(z: *zui.Ui, code: u32) bool {
    if (keys.capture != null) {
        _ = keys.captured(code);
        prefs.save();
        return true;
    }
    const busy = z.popup_count > 0;
    if (code == ui.KEY.ESC and !busy) {
        dialogs.close();
        return true;
    }
    if ((code == ui.KEY.ENTER or code == ui.KEY.KPENTER) and !busy and !z.wantsKeyboard()) {
        dialogs.close();
        return true;
    }
    return false;
}

/// The rest at half brightness, as BeeModel dims.
fn under() void {
    dialogs.dim(ui.cv);
}

fn frameRect(w: i32, h: i32) Rect {
    const ww = @min(w, app.winW() - 40);
    const hh = @min(h, app.winH() - 80);
    return .{ .x = @divTrunc(app.winW() - ww, 2), .y = @divTrunc(app.winH() - hh, 2), .w = ww, .h = hh };
}

/// Where the dialog is: about 70 % x 80 % of the window, as BeeModel's.
pub fn rect() Rect {
    return frameRect(std.math.clamp(@divTrunc(app.winW() * 7, 10), 560, 980), std.math.clamp(@divTrunc(app.winH() * 8, 10), 400, 700));
}

fn describeClient(z: *zui.Ui) void {
    describe(z, rect(), true);
}

/// The Preferences in an area of the layout at `r`: the same pages, without
/// the box and Close.
pub fn areaPart(r: Rect) void {
    const z = host.beginPart("preferences", 0, r) orelse return;
    defer host.endPart(z);
    describe(z, r, false);
}

fn containsI(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

const RowKind = enum { theme, accent, ui_scale, int_ms, float, flag, note };
const Row = struct {
    cat: u8,
    label: []const u8,
    tip: []const u8,
    kind: RowKind,
    b: ?*bool = null,
    f: ?*f32 = null,
    i: ?*i32 = null,
    step: f32 = 1,
    suffix: []const u8 = "",
    ported: bool = true,
};

fn rows() [23]Row {
    return .{
        .{ .cat = 0, .label = "Theme", .tip = "The UI's colours: Dark, Light, High contrast, Honey, Graphite, Nord, Solarized Dark / Light, Dracula", .kind = .theme },
        .{ .cat = 0, .label = "Accent", .tip = "The accent colour, in any theme (Theme's Accent goes back)", .kind = .accent },
        .{ .cat = 0, .label = "UI scale", .tip = "75 - 200 %, on top of the compositor's scale", .kind = .ui_scale },
        .{ .cat = 0, .label = "Tooltip delay (ms)", .tip = "How long the pointer rests before a tooltip shows", .kind = .int_ms, .i = &prefs.tooltip_ms },
        .{ .cat = 0, .label = "Colour-blind-safe axis colours", .tip = "X, Y, Z in orange, sky blue and purple instead of red, green and blue", .kind = .flag, .b = &prefs.colorblind_axes },
        .{ .cat = 0, .label = "Reduce motion", .tip = "Views jump where they go instead of gliding", .kind = .flag, .b = &prefs.reduce_motion },
        .{ .cat = 0, .label = "Show the frame rate in the status bar", .tip = "Frames drawn in the last second while something moves", .kind = .flag, .b = &prefs.show_frame_rate },
        .{ .cat = 0, .label = "Show the welcome screen at start", .tip = "Templates, recent files and the keymap at start-up", .kind = .flag, .b = &prefs.welcome },
        .{ .cat = 1, .label = "Ground grid", .tip = "Show the ground grid and axes (Shift+G)", .kind = .flag, .b = &scene.show_grid },
        .{ .cat = 1, .label = "Field of view", .tip = "The viewports' vertical field of view", .kind = .float, .f = &prefs.fov, .step = 0.5, .suffix = "\u{00B0}" },
        .{ .cat = 1, .label = "Clip start", .tip = "Nothing nearer the eye than this is drawn", .kind = .float, .f = &prefs.clip_start, .step = 0.005, .suffix = " m" },
        .{ .cat = 1, .label = "Rendered samples", .tip = "Path-traced samples of Rendered shading when the view is still (0: Material Preview alone)", .kind = .int_ms, .i = &prefs.rendered_samples },
        .{ .cat = 1, .label = "Rendered denoise", .tip = "Denoise Rendered shading's samples", .kind = .flag, .b = &prefs.rendered_denoise },
        .{ .cat = 1, .label = "Rendered motion samples", .tip = "Path-traced samples a frame while the view moves, 0 to 4 (0: the GPU's raycast, or Material Preview on the CPU)", .kind = .int_ms, .i = &prefs.rendered_motion },
        .{ .cat = 1, .label = "Rendered playback samples", .tip = "Path-traced samples a frame while the animation plays, 0 to 64 (0: as while moving)", .kind = .int_ms, .i = &prefs.rendered_playback },
        .{ .cat = 2, .label = "Alt + left button as the middle button", .tip = "For a laptop without a middle button: Alt + drag pans", .kind = .flag, .b = &prefs.emulate_middle },
        .{ .cat = 2, .label = "Orbit speed", .tip = "How fast a drag turns the view", .kind = .float, .f = &prefs.orbit_speed, .step = 0.02, .suffix = "x" },
        .{ .cat = 2, .label = "Right-click wheel in the viewport", .tip = "Off: the right-click menu is a list, as elsewhere", .kind = .flag, .b = &prefs.wheel_menu },
        .{ .cat = 3, .label = "Preset (BeeModel / Blender 4.x), Set, Clear, Reset", .tip = "Every operator's key; F1 lists them", .kind = .note, .ported = false },
        .{ .cat = 4, .label = "Render width, height, samples, denoise", .tip = "New scenes' render settings", .kind = .note, .ported = false },
        .{ .cat = 5, .label = "Worker threads, the GPU, the JIT", .tip = "System settings", .kind = .note, .ported = false },
        .{ .cat = 6, .label = "Autosave every N changes (0: never)", .tip = "The scene goes to the cache folder every so many changes; your own file is never touched. File > Recover Autosave opens the last one, and the next start offers it after a crash", .kind = .int_ms, .i = &prefs.autosave },
        .{ .cat = 6, .label = "Library folders", .tip = "Files", .kind = .note, .ported = false },
    };
}

fn changed() void {
    prefs.fov = std.math.clamp(prefs.fov, 5, 140);
    prefs.rendered_samples = std.math.clamp(prefs.rendered_samples, 0, 4096);
    prefs.rendered_motion = std.math.clamp(prefs.rendered_motion, 0, 4);
    prefs.rendered_playback = std.math.clamp(prefs.rendered_playback, 0, 64);
    @import("live.zig").denoiseChanged();
    prefs.clip_start = std.math.clamp(prefs.clip_start, 0.001, 10);
    prefs.orbit_speed = std.math.clamp(prefs.orbit_speed, 0.1, 5);
    prefs.apply();
    prefs.save();
}

fn heading(z: *zui.Ui, x: i32, y: i32, text: []const u8, color: zui.Color) void {
    z.pushFont(host.headFont());
    z.pushMetric(.font_size, 16);
    z.drawText(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, color, text);
    z.popStyle();
    z.popFont();
}

/// A button in BeeModel's styles: plain, `selected` (the accent, as Close),
/// `soft` (a dark accent, as the chosen category), `flat` (no fill).
fn button(z: *zui.Ui, name: []const u8, salt: usize, r: Rect, o: struct { selected: bool = false, soft: bool = false, flat: bool = false, center: bool = true, tip: []const u8 = "", why: ?[]const u8 = null }) bool {
    const t = ui.th;
    var pushed: usize = 0;
    if (o.selected) {
        // Chosen stays chosen under the pointer, as BeeModel's.
        z.pushColor(.button, col(if (o.soft) t.accent_dark else t.accent));
        z.pushColor(.button_hovered, col(if (o.soft) t.accent_dark else t.accent));
        z.pushColor(.text, col(if (o.soft) t.accent_fg else t.accent_text));
        pushed += 3;
    } else if (o.flat) {
        z.pushColor(.button, zui.Color.transparent);
        pushed += 1;
    }
    defer z.popStyles(pushed);
    at(z, name, salt, r);
    defer z.endRegion();
    z.pushDisabled(o.why);
    defer z.popDisabled();
    // Greyed as BeeModel greys: the fill stays, the text dims.
    if (o.why != null) {
        z.pushColor(.button, col(t.btn));
        z.pushColor(.text, col(t.text_off));
    }
    defer if (o.why != null) z.popStyles(2);
    const b = z.button(name, .{ .width = .fill, .height = .fill, .alignment = if (o.center) .center else .start });
    if (o.tip.len > 0 or o.why != null) z.tooltipRich(b, .{ .title = zui.Ui.visibleLabel(name), .body = o.tip });
    return b.clicked;
}

/// The Preferences at `r`; `boxed`: as the dialog (a shadow, the box,
/// Close), else on the area's background.
fn describe(z: *zui.Ui, r: Rect, boxed: bool) void {
    const t = ui.th;
    const zrr = zr(r);
    if (boxed) {
        // BeeModel's dialog: a shadow, the box (the rest is dimmed by `under`).
        z.drawRect(.{ .rect = .{ .x = zrr.x + 4, .y = zrr.y + 6, .w = zrr.w, .h = zrr.h }, .fill = col(t.shadow).withAlpha(160), .radius = 8 });
        z.drawRect(.{ .rect = zrr, .fill = col(t.drop_bg), .border = col(t.drop_border), .border_width = 1, .radius = 8 });
    } else z.drawRect(.{ .rect = zrr, .fill = col(t.pane_bg) });
    heading(z, r.x + 14, r.y + 8, "Preferences", col(t.text));
    if (boxed and button(z, "Close", 0, .{ .x = r.right() - 84, .y = r.y + 8, .w = 70, .h = 24 }, .{ .selected = true, .tip = "Close the preferences (Esc); every change is saved at once" })) {
        dialogs.close();
        return;
    }

    // Left: the search and the categories.
    const left = Rect{ .x = r.x, .y = r.y + 40, .w = 140, .h = r.h - 40 };
    z.drawRect(.{ .rect = zr(.{ .x = left.right(), .y = left.y, .w = 1, .h = left.h }), .fill = col(t.sep) });
    const sf = Rect{ .x = left.x + 8, .y = left.y + 4, .w = left.w - 16, .h = 22 };
    at(z, "search", 0, sf);
    _ = z.textInput("##Search settings", &query, &query_len, .{ .width = .fill, .hint = "Search settings" });
    z.endRegion();
    const q = query[0..query_len];
    var y = sf.bottom() + 12;
    for (categories, 0..) |c, k| {
        if (button(z, c, k, .{ .x = left.x + 8, .y = y, .w = left.w - 16, .h = 22 }, .{ .selected = pref_cat == k and q.len == 0, .soft = true, .flat = true, .center = false })) {
            pref_cat = k;
            query_len = 0;
            z.focused = .none;
        }
        y += 26;
    }

    // Right: the category's settings, or every match of the search.
    const body = Rect{ .x = left.right() + 14, .y = left.y + 4, .w = r.right() - left.right() - 28, .h = left.h - 8 };
    heading(z, body.x, body.y, if (q.len > 0) "Search" else categories[pref_cat], col(t.accent_fg));
    if (q.len == 0 and button(z, "Reset to Defaults", 0, .{ .x = body.right() - 130, .y = body.y, .w = 130, .h = 22 }, .{ .tip = "This category back as BeeModel comes" })) {
        prefs.resetCategory(pref_cat);
        @import("live.zig").denoiseChanged();
        app.toast(.ok, "{s}: defaults", .{categories[pref_cat]});
    }
    y = body.y + 32;
    if (q.len == 0 and pref_cat >= 3 and pref_cat <= 7) {
        switch (pref_cat) {
            3 => keymapPage(z, body, y),
            4 => renderingPage(z, body, y),
            5 => systemPage(z, body, y),
            7 => aiPage(z, body, y),
            else => filesPage(z, body, y),
        }
        return;
    }
    const lw = @divTrunc(body.w * 45, 100);
    var any = false;
    for (rows(), 0..) |row, k| {
        if (q.len > 0) {
            if (!containsI(row.label, q) and !containsI(row.tip, q)) continue;
        } else if (row.cat != pref_cat) continue;
        any = true;
        const rr = Rect{ .x = body.x, .y = y, .w = body.w, .h = 24 };
        const vr = Rect{ .x = body.x + lw, .y = y + 1, .w = body.w - lw, .h = 22 };
        const fg = col(if (row.ported) t.text_dim else t.text_off);
        z.pushIdInt(k);
        defer z.popId();
        switch (row.kind) {
            .flag => {
                at(z, "row", k, rr);
                if (bkit.checkRow(z, row.label, row.b.?, row.tip).changed) changed();
                z.endRegion();
            },
            .note => z.drawText(.{ .x = @floatFromInt(rr.x), .y = @floatFromInt(rr.y + 2) }, col(t.text_off), row.label),
            else => {
                z.drawText(.{ .x = @floatFromInt(rr.x), .y = @floatFromInt(rr.y + 2) }, fg, row.label);
                at(z, "value", k, vr);
                defer z.endRegion();
                switch (row.kind) {
                    .theme => {
                        var choices: [16]zui.Choice = undefined;
                        var current: usize = 0;
                        for (theme.all, 0..) |th, i| {
                            choices[i] = .{ .label = th.name };
                            if (std.mem.eql(u8, th.name, theme.base.name)) current = i;
                        }
                        const before = current;
                        _ = z.dropdown("##Theme", &current, choices[0..theme.all.len], .{ .width = .fill });
                        if (current != before) {
                            theme.set(theme.all[current]);
                            prefs.save();
                        }
                    },
                    .accent => {
                        if (theme.accent == null) accent_edit = col(theme.cur.accent);
                        z.beginHorizontal(.{ .spacing = 6 });
                        const e = z.colorEdit("##Accent", &accent_edit, .{ .alpha = false, .compact = true });
                        if (e.changed) {
                            theme.setAccent(@as(u32, accent_edit.r) << 16 | @as(u32, accent_edit.g) << 8 | accent_edit.b);
                            prefs.save();
                        }
                        z.pushDisabled(if (theme.accent == null) "The theme's accent is in use" else null);
                        const own = z.button("Theme's", .{ .width = .px(104), .height = .fill });
                        z.tooltipRich(own, .{ .title = "Theme's", .body = "The theme's own accent" });
                        if (own.clicked) {
                            theme.setAccent(null);
                            prefs.save();
                        }
                        z.popDisabled();
                        z.endHorizontal();
                    },
                    .ui_scale => {
                        var choices: [pp.scales.len]zui.Choice = undefined;
                        var current: usize = 1;
                        var names: [pp.scales.len][8]u8 = undefined;
                        for (pp.scales, 0..) |sc, i| {
                            choices[i] = .{ .label = std.fmt.bufPrint(&names[i], "{d} %", .{sc}) catch "" };
                            if (sc == scale.pref) current = i;
                        }
                        const before = current;
                        _ = z.dropdown("##UI scale", &current, &choices, .{ .width = .fill });
                        if (current != before) pp.setScale(pp.scales[current]);
                    },
                    .int_ms => {
                        var v: f64 = @floatFromInt(row.i.?.*);
                        var id_buf: [64]u8 = undefined;
                        const f = z.numberField(std.fmt.bufPrint(&id_buf, "##{s}", .{row.label}) catch row.label, &v, .{ .width = .fill, .decimals = 0, .step = 10, .label = .inside });
                        if (f.changed) {
                            row.i.?.* = @intFromFloat(std.math.clamp(if (std.math.isFinite(v)) @round(v) else 500, 0, 5000));
                            changed();
                        }
                    },
                    .float => {
                        var v: f64 = row.f.?.*;
                        var id_buf: [64]u8 = undefined;
                        const f = z.numberField(std.fmt.bufPrint(&id_buf, "##{s}", .{row.label}) catch row.label, &v, .{ .width = .fill, .decimals = 3, .step = row.step, .suffix = row.suffix, .label = .inside });
                        if (f.changed) {
                            row.f.?.* = @floatCast(v);
                            changed();
                        }
                    },
                    else => {},
                }
            },
        }
        y += 28;
    }
    if (!any) z.drawText(.{ .x = @floatFromInt(body.x), .y = @floatFromInt(y) }, col(t.text_dim), if (q.len > 0) "No setting matches" else "Nothing here yet");
}

/// A whole-width number row with its label inside, as BeeModel's.
fn intRow(z: *zui.Ui, body: Rect, y: i32, label: []const u8, v: *i32, lo: f64, hi: f64, tip: []const u8) void {
    at(z, label, 0, .{ .x = body.x, .y = y, .w = body.w, .h = 22 });
    defer z.endRegion();
    var f: f64 = @floatFromInt(v.*);
    const item = z.numberField(label, &f, .{ .width = .fill, .min = lo, .max = hi, .step = 1, .decimals = 0, .label = .inside });
    z.tooltipRich(item, .{ .title = label, .body = tip });
    if (item.changed) {
        v.* = @intFromFloat(std.math.clamp(@round(f), lo, hi));
        prefs.save();
    }
}

fn hint(z: *zui.Ui, body: Rect, y: i32, s: []const u8) void {
    z.pushMetric(.font_size, 13);
    defer z.popStyle();
    z.drawText(.{ .x = @floatFromInt(body.x), .y = @floatFromInt(y) }, col(ui.th.text_dim), s);
}

fn greyed(z: *zui.Ui, body: Rect, y: i32, s: []const u8, why: []const u8) void {
    _ = button(z, s, @intCast(y & 0xffff), .{ .x = body.x, .y = y, .w = body.w, .h = 22 }, .{ .why = why, .center = false });
}

fn renderingPage(z: *zui.Ui, body: Rect, y0: i32) void {
    var y = y0;
    intRow(z, body, y, "Width (px)", &pp.render_w, 16, 8192, "New scenes render this wide (each scene keeps its own)");
    y += 28;
    intRow(z, body, y, "Height (px)", &pp.render_h, 16, 8192, "New scenes render this high");
    y += 28;
    intRow(z, body, y, "Samples", &pp.render_spp, 1, 65536, "New scenes' samples per pixel");
    y += 28;
    at(z, "denoise", 0, .{ .x = body.x, .y = y, .w = body.w, .h = 22 });
    if (bkit.checkRow(z, "Denoise the finished render", &pp.render_dn, "").changed) prefs.save();
    z.endRegion();
    y += 30;
    hint(z, body, y, "For new scenes: a scene keeps its own (the Render area).");
}

const dev_names = [_][]const u8{ "Auto", "GPU (RTX)", "GPU", "CPU" };

fn systemPage(z: *zui.Ui, body: Rect, y0: i32) void {
    var y = y0;
    intRow(z, body, y, "Worker threads (0: one a CPU)", &pp.threads, 0, 255, "How many threads the heavy work uses");
    y += 28;
    z.drawText(.{ .x = @floatFromInt(body.x), .y = @floatFromInt(y + 2) }, col(ui.th.text_dim), "Render device");
    const lw = @divTrunc(body.w * 45, 100);
    at(z, "device", 0, .{ .x = body.x + lw, .y = y, .w = body.w - lw, .h = 22 });
    var choices: [dev_names.len]zui.Choice = undefined;
    for (dev_names, 0..) |d, i| choices[i] = .{ .label = d };
    var current: usize = @intCast(std.math.clamp(prefs.render_device, 0, 3));
    const before = current;
    const dd = z.dropdown("##Render device", &current, &choices, .{ .width = .fill });
    z.tooltipRich(dd, .{ .title = "Render device", .body = "Where renders run. Auto: RTX ray tracing when the GPU has it, else the GPU, else the CPU" });
    if (current != before) {
        prefs.render_device = @intCast(current);
        @import("gpu.zig").device = @enumFromInt(@as(u8, @intCast(current)));
        prefs.save();
    }
    z.endRegion();
    y += 28;
    greyed(z, body, y, "Compile node programs to machine code (JIT)", "Node programs come with phase 11");
    y += 30;
    hint(z, body, y, "Takes effect when BeeModel starts again.");
}

fn filesPage(z: *zui.Ui, body: Rect, y0: i32) void {
    var y = y0;
    intRow(z, body, y, "Autosave every N changes (0: never)", &prefs.autosave, 0, 10000, "Keeps a copy of the scene after so many changes");
    y += 28;
    greyed(z, body, y, "Add Library Folder...", "The content library comes with phase 11");
    y += 28;
    greyed(z, body, y, "Blender program", ".blend export comes with phase 3's Blender row");
}

fn hasWord(s: []const u8, w: []const u8) bool {
    return containsI(s, w);
}

const km_names = [_][]const u8{ "BeeModel", "Blender 4.x" };

fn keymapPage(z: *zui.Ui, body: Rect, y0: i32) void {
    const t = ui.th;
    var y = y0;
    const lw = @divTrunc(body.w * 45, 100);
    z.drawText(.{ .x = @floatFromInt(body.x), .y = @floatFromInt(y + 2) }, col(t.text_dim), "Keymap");
    at(z, "preset", 0, .{ .x = body.x + lw, .y = y, .w = body.w - lw, .h = 22 });
    var current: usize = keys.preset;
    const dd = z.dropdown("##Keymap", &current, &.{ .{ .label = km_names[0] }, .{ .label = km_names[1] } }, .{ .width = .fill });
    z.tooltipRich(dd, .{ .title = "Keymap", .body = "Blender 4.x: Blender's keys where BeeModel's differ. Keys you set yourself stay" });
    if (current != keys.preset) {
        keys.usePreset(@intCast(current));
        prefs.save();
    }
    z.endRegion();
    y += 28;
    at(z, "find", 0, .{ .x = body.x, .y = y, .w = body.w - 130, .h = 22 });
    const f = z.textInput("##Find", &find, &find_len, .{ .width = .fill, .hint = "Find" });
    // Enter lets go of the field, so Esc closes the dialog as BeeModel's.
    if (f.submitted) z.focused = .none;
    z.endRegion();
    if (button(z, "Reset All Keys", 0, .{ .x = body.right() - 124, .y = y, .w = 124, .h = 22 }, .{ .tip = "Every operator back to its own key" })) {
        keys.resetAll();
        prefs.save();
    }
    y += 28;

    // The operators: label, key, Set, Clear, as a Zui list (only the rows in
    // view are described). Enter or a double click on a row: Set.
    const list = Rect{ .x = body.x, .y = y, .w = body.w, .h = body.bottom() - y };
    const q = find[0..find_len];
    var n: usize = 0;
    for (&cat.entries, 0..) |*e, i| {
        if (e.hidden or !(hasWord(e.id, q) or hasWord(e.label, q))) continue;
        key_idx[n] = @intCast(i);
        n += 1;
    }
    // (the picked row stays on its operator as the search narrows the list)
    for (key_idx[0..n], 0..) |i, k| key_sel[k] = key_pick != null and key_pick.? == i;
    z.beginRegion(z.id("##keys"), zr(list), .vertical, 0, .start);
    defer z.endRegion();
    z.pushMetric(.font_size, 13);
    defer z.popStyle();
    // rows 22 apart, as BeeModel's
    z.pushMetric(.frame_padding, .{ .x = 8, .y = @max(0, KEY_ROW - z.textSize("").y) });
    var l = z.beginList("##operators", key_sel[0..n], &key_st, .{ .height = .fill, .frame = false });
    z.popStyle();
    z.pushColor(.button_active, col(t.accent_dark));
    var kb: [40]u8 = undefined;
    for (l.first..l.end) |k| {
        const i = key_idx[k];
        const e = &cat.entries[i];
        z.beginRow(&l, k, .{ .label = "" });
        const rr = host.rectOf(l.row_rect);
        const ry = rr.y + @divTrunc(rr.h - 20, 2);
        const ty: f32 = l.row_rect.y + (l.row_rect.h - z.textSize("").y) / 2;
        ui.record("keyrow", e.label, .{ .x = body.x, .y = ry, .w = body.w - 112, .h = 20 }, true);
        const ks = if (keys.capture != null and keys.capture.? == i) "press a key (Esc: never mind)" else blk: {
            const kl = ops.keyLabel(i, &kb);
            break :blk if (kl.len > 0) kl else "-";
        };
        ui.record("key", ks, .{ .x = body.x + lw, .y = ry, .w = body.w - lw - 114, .h = 20 }, true);
        const bx = rr.right() - 112;
        if (button(z, "Set", i, .{ .x = bx, .y = ry, .w = 52, .h = 20 }, .{ .tip = "Then press the key (with Ctrl / Shift / Alt) for it" })) {
            keys.capture = i;
        }
        if (button(z, "Clear", i, .{ .x = bx + 56, .y = ry, .w = 54, .h = 20 }, .{ .tip = "No key for it" })) {
            keys.set(i, 0, 0);
            prefs.save();
        }
        if (z.endRow(&l).activated) keys.capture = i;
        // (after the row: inside it, its label's clip would cut these)
        z.pushClip(l.row_rect);
        z.drawText(.{ .x = @floatFromInt(body.x + 4), .y = ty }, col(if (ops.implemented(i)) t.text else t.text_off), e.label);
        z.drawText(.{ .x = @floatFromInt(body.x + lw), .y = ty }, col(t.accent_fg), ks);
        z.popClip();
    }
    z.popStyle();
    const lr = z.endList(&l);
    if (lr.changed) {
        key_pick = null;
        if (key_st.cursor) |c| if (c < n and key_sel[c]) {
            key_pick = key_idx[c];
        };
    }
}

/// The keymap's list: the operators shown (the search's), which is picked.
const KEY_ROW: f32 = 22;
var key_idx: [ops.N]u16 = undefined;
var key_sel: [ops.N]bool = @splat(false);
var key_st: zui.ListState = .{};
var key_pick: ?u16 = null;

// --- AI: the AI Assistant's connections and the agents ------------------------------

const aim = @import("ai.zig");
const agent = @import("agent.zig");
var ai_scroll: f32 = 0;
const prov_labels = [_][]const u8{ "Claude Code", "Grok CLI", "OpenRouter", "Ollama (local)" };
const tier_labels = [_][]const u8{ "As started (BEEMODEL_AGENT_PERMISSION)", "Read only", "May edit", "Edit and files" };
/// The OpenRouter key as it is typed: never shown once kept.
var key_edit: [256]u8 = undefined;
var key_edit_len: usize = 0;

/// A label in the left 45 %, its value at the right: the value's rect.
fn valueRect(z: *zui.Ui, body: Rect, y: i32, label: []const u8) Rect {
    const lw = @divTrunc(body.w * 45, 100);
    z.drawText(.{ .x = @floatFromInt(body.x), .y = @floatFromInt(y + 2) }, col(ui.th.text_dim), label);
    return .{ .x = body.x + lw, .y = y, .w = body.w - lw, .h = 22 };
}

/// A choice from a list (WK_ENUM); the new choice if it changed.
fn enumRow(z: *zui.Ui, body: Rect, y: i32, label: []const u8, items: []const []const u8, current: usize, tip: []const u8) ?usize {
    at(z, label, 0, valueRect(z, body, y, label));
    defer z.endRegion();
    var choices: [8]zui.Choice = undefined;
    for (items, 0..) |l, i| choices[i] = .{ .label = l };
    var sel = current;
    var nb: [80]u8 = undefined;
    const d = z.dropdown(std.fmt.bufPrint(&nb, "##{s}", .{label}) catch label, &sel, choices[0..items.len], .{ .width = .fill });
    z.tooltipRich(d, .{ .title = label, .body = tip });
    return if (sel != current) sel else null;
}

/// A text setting (WK_TEXT), kept when typing ends (Enter, or the field
/// let go); Esc puts it back. `secret`: typed into an empty field, shown as
/// "(set)" once kept, and saved in the secrets file only.
fn textRow(z: *zui.Ui, body: Rect, y: i32, label: []const u8, v: *aim.Str, secret: bool, tip: []const u8, salt: usize) void {
    at(z, label, salt, valueRect(z, body, y, label));
    defer z.endRegion();
    var nb: [80]u8 = undefined;
    const name = std.fmt.bufPrint(&nb, "##{s}", .{label}) catch label;
    if (secret) {
        const f = z.textInput(name, &key_edit, &key_edit_len, .{ .width = .fill, .hint = if (v.n > 0) "(set)" else "", .select_on_click = true });
        z.tooltipRich(f, .{ .title = label, .body = tip });
        if ((f.committed or f.submitted) and key_edit_len > 0) {
            v.set(key_edit[0..key_edit_len]);
            key_edit_len = 0;
            aim.secretsSave(); // (the secrets file only)
        }
        return;
    }
    const f = z.textInput(name, v.b[0 .. v.b.len - 1], &v.n, .{ .width = .fill, .select_on_click = true });
    if (f.changed) v.b[v.n] = 0;
    z.tooltipRich(f, .{ .title = label, .body = tip });
    if (f.committed or f.submitted) prefs.save();
}

fn testButton(z: *zui.Ui, body: Rect, y: i32, label: []const u8, tip: []const u8, which: u32) void {
    if (button(z, label, which, .{ .x = body.x, .y = y, .w = body.w, .h = 22 }, .{ .tip = tip })) aim.testConn(which);
}

fn aiPage(z: *zui.Ui, body: Rect, y0: i32) void {
    const view = Rect{ .x = body.x, .y = y0, .w = body.w, .h = body.bottom() - y0 };
    const zv = zr(view);
    const content: f32 = 22 * 28 + 5 * 30 + 24;
    if (zv.contains(z.input.mouse_pos) and z.input.scroll.y != 0) {
        ai_scroll -= z.input.scroll.y * 66;
        z.input.scroll = .{};
    }
    ai_scroll = std.math.clamp(ai_scroll, 0, @max(0, content - zv.h));
    z.pushClip(zv);
    defer z.popClip();
    var y = y0 - @as(i32, @intFromFloat(ai_scroll));
    // Rows outside the view are left out, so nothing hidden takes a click.
    const shown = struct {
        fn f(v: Rect, yy: i32) bool {
            return yy + 22 > v.y and yy < v.bottom();
        }
    }.f;

    if (shown(view, y)) if (enumRow(z, body, y, "The AI Assistant uses", &prov_labels, @intCast(std.math.clamp(aim.prov, 0, 3)), "Which connection the AI Assistant uses")) |k| {
        aim.prov = @intCast(k);
        prefs.save();
    };
    y += 28;
    if (shown(view, y)) textRow(z, body, y, "Also tell the AI", &aim.extra, false, "Text added to every request's instructions (a style, units, what to avoid)", 0);
    y += 28;

    const Conn = struct { head: []const u8, rows: []const struct { []const u8, *aim.Str, bool, []const u8 }, turns_label: []const u8, turns: *i32, test_label: []const u8, test_tip: []const u8 };
    const conns = [_]Conn{
        .{ .head = "Claude Code", .rows = &.{
            .{ "Program", &aim.cl_path, false, "The claude program (empty: the one on PATH)" },
            .{ "Model", &aim.cl_model, false, "A model name or alias such as sonnet or opus (empty: Claude Code's default)" },
        }, .turns_label = "Turns at most", .turns = &aim.cl_turns, .test_label = "Test Claude Code", .test_tip = "Run claude --version: the answer shows as a message" },
        .{ .head = "Grok CLI", .rows = &.{
            .{ "Program", &aim.gk_path, false, "The grok program (empty: the one on PATH)" },
            .{ "Model", &aim.gk_model, false, "A Grok model name (empty: the CLI's default)" },
        }, .turns_label = "Turns at most", .turns = &aim.gk_turns, .test_label = "Test Grok", .test_tip = "Run grok --version: the answer shows as a message" },
        .{ .head = "OpenRouter", .rows = &.{
            .{ "API key", &aim.or_key, true, "Your OpenRouter key: kept in ~/.config/beemodel-zig/secrets (yours alone to read), never shown or logged (empty: OPENROUTER_API_KEY)" },
            .{ "Model", &aim.or_model, false, "Any OpenRouter model id with tool calling, such as anthropic/claude-sonnet-4.5 or openai/gpt-4.1" },
            .{ "Address", &aim.or_url, false, "The API's address (another OpenAI-compatible server works too)" },
        }, .turns_label = "Steps at most", .turns = &aim.or_steps, .test_label = "Test OpenRouter", .test_tip = "Ask OpenRouter whether the key works (it costs nothing)" },
        .{ .head = "Ollama (local)", .rows = &.{
            .{ "Model", &aim.ol_model, false, "An Ollama model with tool calling, as ollama list names it, such as qwen3.5:4b. It is asked not to think" },
            .{ "Address", &aim.ol_url, false, "Ollama's OpenAI-compatible address (no key is sent)" },
        }, .turns_label = "Steps at most", .turns = &aim.ol_steps, .test_label = "Test Ollama", .test_tip = "Ask Ollama whether it runs and has the model" },
    };
    for (conns, 0..) |c, ci| {
        z.pushIdInt(100 + ci);
        defer z.popId();
        if (shown(view, y)) heading(z, body.x, y + 4, c.head, col(ui.th.accent));
        y += 30;
        for (c.rows, 0..) |row, ri| {
            if (shown(view, y)) textRow(z, body, y, row[0], row[1], row[2], row[3], ri);
            y += 28;
        }
        if (shown(view, y)) intRow(z, body, y, c.turns_label, c.turns, 1, 500, "How many rounds of tool calls one request may take");
        y += 28;
        if (shown(view, y)) testButton(z, body, y, c.test_label, c.test_tip, @intCast(ci));
        y += 28;
    }

    if (shown(view, y)) heading(z, body.x, y + 4, "Agents", col(ui.th.accent));
    y += 30;
    if (shown(view, y)) if (enumRow(z, body, y, "AI agents may", &tier_labels, @intCast(std.math.clamp(agent.pr_tier + 1, 0, 3)), "What AI agents may do when BeeModel starts")) |k| {
        agent.pr_tier = @as(i32, @intCast(k)) - 1;
        prefs.save();
    };
    y += 28;
    if (shown(view, y)) {
        at(z, "mcp", 0, .{ .x = body.x, .y = y, .w = body.w, .h = 22 });
        var on = agent.pr_mcp != 0;
        if (bkit.checkRow(z, "Listen for MCP clients (AI agents)", &on, "AI agents connect through the MCP server").changed) {
            agent.pr_mcp = @intFromBool(on);
            prefs.save();
        }
        z.endRegion();
    }
    y += 30;
    if (shown(view, y)) hint(z, body, y, "Takes effect when BeeModel starts again.");
}
