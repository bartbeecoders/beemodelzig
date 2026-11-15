// BeeModel's panel kit on Zui: what every panel repeats, in BeeModel's look,
// so the panels moved to Zui (Docs/beezigui-migration.html, M1 on) share one
// way of doing it. It takes the place of editors.section, editors.opButtonL
// and the panels' own row helpers.
//
//   section     a heading that folds what is under it
//   opButton    a catalog operator: its label, its key, its doc as the
//               tooltip, greyed with the reason it can't run now
//   numberRow   a value with its label inside, typed values through
//               BeeModel's expressions (units and parameters, cad.eval)
//   checkRow    a check box with its tooltip
//   Flow        a panel in BeeModel's own page (Properties): it says how
//               tall it is, the page lays out what follows
//
// Each records under BeeModel's kinds (section, button, number, checkbox)
// through zuihost's record bridge.
const std = @import("std");
const zui = @import("zui");
const host = @import("zuihost.zig");
const ui = @import("ui.zig");
const icons = @import("icons.zig");
const wg = @import("wg.zig");

const col = host.col;
const Rect = @import("gfx.zig").Rect;

/// A panel described with Zui inside a page BeeModel lays out and scrolls
/// itself (the Properties tabs): begin it at the page's y, describe it when
/// `z` is set, and `end` gives the y below it. In the hit pass nothing is
/// described (Zui has the input already) and `end` gives the height of the
/// last drawn frame, so BeeModel's own rows below it are hit where they are
/// drawn.
///
///     var f = bkit.Flow.begin("bake", salt, bd, y);
///     if (f.z) |z| { ... }
///     return f.end();
pub const Flow = struct {
    z: ?*zui.Ui,
    y: i32,
    key: u64,

    pub fn begin(name: []const u8, salt: usize, bd: Rect, y: i32) Flow {
        const key = std.hash.Wyhash.hash(salt, name);
        return .{ .z = host.beginFlowPart(name, salt, bd.x, y, bd.w, ui.cv.clip), .y = y, .key = key };
    }

    pub fn end(f: Flow) i32 {
        const z = f.z orelse return f.y + heightOf(f.key);
        const h = host.endFlowPart(z);
        remember(f.key, h);
        return f.y + h;
    }
};

var heights_key: [32]u64 = @splat(0);
var heights: [32]i32 = @splat(0);
var heights_next: usize = 0;

fn heightOf(key: u64) i32 {
    for (heights_key, heights) |k, h| if (k == key) return h;
    return 0;
}

fn remember(key: u64, h: i32) void {
    for (&heights_key, &heights) |k, *h0| if (k == key) {
        h0.* = h;
        return;
    };
    heights_key[heights_next] = key;
    heights[heights_next] = h;
    heights_next = (heights_next + 1) % heights.len;
}

/// Two widgets side by side, each half the width: `beginPair`, two
/// widgets with width .fill, `endPair`.
pub fn beginPair(z: *zui.Ui) void {
    z.beginHorizontal(.{ .spacing = 4 });
}

pub fn endPair(z: *zui.Ui) void {
    z.endHorizontal();
}

/// Dim text the whole width, cut with an ellipsis.
pub fn note(z: *zui.Ui, text: []const u8) void {
    z.label(text, .{ .color = col(ui.th.text_dim), .width = .fill, .ellipsis = true });
}

/// Typed values as BeeModel reads them: arithmetic, units (25mm + 1cm) and
/// the scene's parameters (width / 2), in scene units.
pub const evaluator: zui.Evaluator = .{ .parse = parseValue };

fn parseValue(_: ?*anyopaque, text: []const u8) ?f64 {
    return @import("cad.zig").eval(text);
}

/// A heading that folds what is under it, open state in `open` (the
/// caller's, so it can be saved). Returns whether it is open: then describe
/// its rows. Rows are not indented, as BeeModel's.
pub fn section(z: *zui.Ui, title: []const u8, open: *bool) bool {
    z.pushFont(host.headFont());
    defer z.popFont();
    z.pushColor(.text, col(ui.th.accent_fg));
    defer z.popStyle();
    return z.collapsingHeader(title, .{ .open = open });
}

pub const OpOptions = struct {
    /// Instead of the catalog's label.
    label: ?[]const u8 = null,
    /// The accent fill: the panel's main action (the original's WGF_PRIMARY).
    primary: bool = false,
    icon: ?icons.Icon = null,
    width: zui.Size = .fill,
    height: zui.Size = .auto,
    /// The words it runs with (ops.arg), such as a probe's kind.
    arg: []const u8 = "",
    /// Instead of the catalog's doc, as the tooltip's body.
    tip: ?[]const u8 = null,
};

/// A catalog operator as a button (operator id as in catalog.zig, such as
/// "object.delete"). Greyed, with the reason as the tooltip's warning, when it
/// can't run now. Returns true if it ran. Unknown ids show nothing.
pub fn opButton(z: *zui.Ui, id: []const u8, o: OpOptions) bool {
    const ops = @import("ops.zig");
    const oi = ops.byId(id) orelse return false;
    const e = &@import("catalog.zig").entries[oi];
    const why = ops.reason(oi);
    const label = o.label orelse e.label;
    const t = ui.th;

    var pushed: usize = 0;
    if (o.primary and why == null) {
        z.pushColor(.button, col(t.accent));
        z.pushColor(.button_hovered, col(t.accent));
        z.pushColor(.text, col(t.accent_text));
        pushed = 3;
    } else if (why != null) {
        // Greyed as BeeModel greys: the fill stays, the text dims.
        z.pushColor(.button, col(t.btn));
        z.pushColor(.text, col(t.text_off));
        pushed = 2;
    }
    defer z.popStyles(pushed);

    z.pushIdInt(oi);
    defer z.popId();
    // (one operator twice in a panel, with other words: Add Irradiance, Add Reflection)
    z.pushId(label);
    defer z.popId();
    z.pushDisabled(why);
    const b = z.button(label, .{
        .width = o.width,
        .height = o.height,
        .icon = if (o.icon) |i| host.icon(i) else null,
    });
    z.popDisabled();
    var kb: [40]u8 = undefined;
    z.tooltipRich(b, .{ .title = zui.Ui.visibleLabel(label), .shortcut = ops.keyLabel(oi, &kb), .body = o.tip orelse e.doc, .warning = why orelse "" });
    const by_ring = ring(b, label);
    if (!(b.clicked or by_ring) or why != null) return false;
    const old = ops.arg;
    ops.arg = o.arg;
    defer ops.arg = old;
    ops.run(oi);
    return true;
}

pub const NumberRowOptions = struct {
    tip: []const u8 = "",
    /// The whole width by default.
    width: zui.Size = .fill,
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    decimals: u8 = 3,
    suffix: []const u8 = "",
    /// Fill the field up to the value, between min and max.
    slider: bool = false,
    /// What Copy Data Path and Insert Keyframe (I) say for it.
    path: wg.Path = .none,
    /// Reset to Default's value (else wg's default for the label, if any).
    def: ?f32 = null,
};

/// A Zui number field joins BeeModel's list of fields (wg): its
/// right-click opens the field menu (Reset to Default, Copy / Paste Value,
/// Insert Keyframe, Copy Data Path), Ctrl+C / Ctrl+V and I act on it while
/// hovered, and a value from those comes in here. Call before describing
/// the field: true if `v` was set from there (one undo step, committed).
fn takeValue(z: *zui.Ui, label: []const u8, v: anytype) bool {
    const id = idOf(z.id(label));
    if (!host.bridging()) return false;
    const p = wg.takeZui(id) orelse return false;
    host.noteActed();
    const t = p.text[0..p.len];
    const x = @import("cad.zig").eval(t) orelse return false;
    setNum(v, x);
    return true;
}

/// A Zui button, check box, row or drop-down joins BeeModel's focus ring
/// (wg): true when the ring's Enter / Space acts on it (as a click).
pub fn ring(it: zui.Interaction, label: []const u8) bool {
    if (host.bridging()) wg.zuiPlain(idOf(it.id), host.rectOf(it.rect), zui.Ui.visibleLabel(label));
    if (!host.bridging() or !wg.takeActivate(idOf(it.id))) return false;
    host.noteActed();
    return true;
}

pub fn idOf(id: zui.Id) u32 {
    const x: u64 = @intFromEnum(id);
    return @truncate(x ^ (x >> 32));
}

fn setNum(v: anytype, x: f64) void {
    const T = @typeInfo(@TypeOf(v)).pointer.child;
    v.* = switch (@typeInfo(T)) {
        .float => @floatCast(x),
        .int => @intFromFloat(std.math.clamp(@round(x), @as(f64, @floatFromInt(std.math.minInt(T))), @as(f64, @floatFromInt(std.math.maxInt(T))))),
        else => @compileError("a number"),
    };
}

fn getNum(v: anytype) f32 {
    const T = @typeInfo(@TypeOf(v)).pointer.child;
    return switch (@typeInfo(T)) {
        .float => @floatCast(v.*),
        .int => @floatFromInt(v.*),
        else => @compileError("a number"),
    };
}

fn joinList(item: zui.Interaction, label: []const u8, v: anytype, o: NumberRowOptions) void {
    if (!host.bridging()) return;
    const T = @typeInfo(@TypeOf(v)).pointer.child;
    wg.info(zui.Ui.visibleLabel(label), o.def orelse std.math.nan(f32), o.path);
    const inf = std.math.inf(f32);
    wg.zuiNumber(idOf(item.id), host.rectOf(item.rect), getNum(v), @floatCast(o.step orelse 0), if (o.min) |m| @floatCast(m) else -inf, if (o.max) |m| @floatCast(m) else inf, @typeInfo(T) == .int, zui.Ui.visibleLabel(label), item.context_clicked);
}

/// A value with its label inside, the whole width; typed text goes through
/// `evaluator`. One drag or typed value is one `committed`: one undo step.
pub fn numberRow(z: *zui.Ui, label: []const u8, v: anytype, o: NumberRowOptions) zui.Interaction {
    const taken = takeValue(z, label, v);
    var item = z.numberField(label, v, .{
        .width = o.width,
        .min = o.min,
        .max = o.max,
        .step = o.step,
        // BeeModel's fields: a pixel of drag is a step
        .drag_step = o.step,
        .decimals = o.decimals,
        .suffix = o.suffix,
        .slider = o.slider,
        .label = .inside,
        .evaluator = &evaluator,
    });
    if (o.tip.len > 0) z.tooltipRich(item, .{ .title = zui.Ui.visibleLabel(label), .body = o.tip });
    joinList(item, label, v, o);
    if (o.slider) rec("slider", zui.Ui.visibleLabel(label), host.rectOf(item.rect), true);
    if (taken) {
        item.started = true;
        item.changed = true;
        item.committed = true;
    }
    return item;
}

/// A row with a caption in a column of its own, `caption_w` units wide, in
/// BeeModel's dim text: describe the value widget (width .fill) after it,
/// then call `endCaptioned`.
pub fn beginCaptioned(z: *zui.Ui, caption: []const u8, caption_w: f32) void {
    z.beginHorizontal(.{ .spacing = 6, .alignment = .center });
    z.beginGroup(.{ .width = .px(caption_w) });
    z.label(caption, .{ .color = col(ui.th.text_dim) });
    z.endGroup();
}

pub fn endCaptioned(z: *zui.Ui) void {
    z.endHorizontal();
}

/// A check box on BeeModel's field colour, 14 units, with its tooltip.
pub fn checkRow(z: *zui.Ui, label: []const u8, v: *bool, tip: []const u8) zui.Interaction {
    z.pushColor(.button, col(ui.th.field));
    z.pushMetric(.checkbox_padding, -3);
    defer z.popStyles(2);
    var c = z.checkbox(label, v, .{});
    if (tip.len > 0) z.tooltipRich(c, .{ .title = zui.Ui.visibleLabel(label), .body = tip });
    if (ring(c, label)) {
        v.* = !v.*;
        c.clicked = true;
        c.changed = true;
        c.started = true;
        c.committed = true;
    }
    return c;
}

/// A line of dim text, recorded as BeeModel's `info` (tests read them).
pub fn info(z: *zui.Ui, text: []const u8) void {
    note(z, text);
    rec("info", text, host.rectOf(z.lastRect()), true);
}

pub const RowOptions = struct {
    tip: []const u8 = "",
    tip_title: []const u8 = "",
    /// Units the text starts further in (a child bone, a nested item).
    indent: f32 = 0,
};

/// A row of a list that can be the chosen one, recorded as BeeModel's
/// `row`. Returns its interaction (clicked: make it the chosen one).
pub fn row(z: *zui.Ui, label: []const u8, selected: bool, o: RowOptions) zui.Interaction {
    if (o.indent > 0) {
        z.beginHorizontal(.{ .spacing = 0 });
        z.spacer(.px(o.indent));
    }
    // (the chosen row on the dark accent, its text readable, as BeeModel's)
    z.pushColor(.button_active, col(ui.th.accent_dark));
    var r = z.selectable(label, selected, .{});
    z.popStyle();
    if (ring(r, label)) r.clicked = true;
    if (o.indent > 0) z.endHorizontal();
    rec("row", zui.Ui.visibleLabel(label), host.rectOf(r.rect), true);
    if (o.tip.len > 0) z.tooltipRich(r, .{ .title = if (o.tip_title.len > 0) o.tip_title else zui.Ui.visibleLabel(label), .body = o.tip });
    return r;
}

/// A drop-down of `n` items named by `labelOf`, the chosen one `selected.*`;
/// returns true when another was picked (`selected` is set). Its items are
/// recorded as `menuitem`, the drop-down as a button showing the choice.
pub fn choice(z: *zui.Ui, name: []const u8, selected: *usize, n: usize, labelOf: *const fn (usize) []const u8, tip: []const u8) bool {
    // (as many as there are: images, fonts, profiles; for this frame only)
    var few: [64]zui.Choice = undefined;
    const items: []zui.Choice = if (n <= few.len) &few else z.frameAllocator().alloc(zui.Choice, n) catch &few;
    const m = @min(n, items.len);
    for (0..m) |k| items[k] = .{ .label = labelOf(k) };
    var sel: usize = @min(selected.*, if (m == 0) 0 else m - 1);
    const r = z.dropdown(name, &sel, items[0..m], .{ .width = .fill });
    // (BeeModel's panels record a drop-down as `enum:<shown value>`)
    if (m > 0) rec("enum", items[sel].label, host.rectOf(r.rect), true);
    _ = ring(r, if (m > 0) items[sel].label else name);
    if (tip.len > 0) z.tooltipRich(r, .{ .title = zui.Ui.visibleLabel(name), .body = tip });
    if (!r.changed) return false;
    selected.* = sel;
    return true;
}

/// A text field showing `text` (not edited in place): while it has focus it
/// edits a copy, and Enter (or leaving it changed) returns the new text,
/// valid until the next call. Recorded under its text, its hint when empty.
pub fn textRow(z: *zui.Ui, name: []const u8, text: []const u8, hint: []const u8) ?[]const u8 {
    const id = z.id(name);
    // a value from the field menu or Ctrl+V while hovered (wg): as typed and confirmed
    if (if (host.bridging()) wg.takeZui(idOf(id)) else null) |p| {
        host.noteActed();
        edit_len = p.len;
        @memcpy(edit_buf[0..p.len], p.text[0..p.len]);
        if (z.focused == id) z.focused = .none;
        edit_id = .none;
        return edit_buf[0..edit_len];
    }
    const focused = z.focused == id;
    if (focused and edit_id != id) {
        edit_id = id;
        edit_len = @min(text.len, edit_buf.len);
        @memcpy(edit_buf[0..edit_len], text[0..edit_len]);
    }
    if (focused) {
        const r = z.textInput(name, &edit_buf, &edit_len, .{ .width = .fill, .hint = hint, .select_on_click = true, .copy_all = true });
        if (host.bridging()) wg.zuiText(idOf(id), host.rectOf(r.rect), edit_buf[0..edit_len], r.context_clicked);
        if (r.submitted) {
            edit_id = .none;
            z.focused = .none;
            return edit_buf[0..edit_len];
        }
        return null;
    }
    // (the record keeps the text it shows until the next frame: a buffer
    // that lives that long, one per field shown)
    const buf = &shown_bufs[shown_next];
    shown_next = (shown_next + 1) % shown_bufs.len;
    var n: usize = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    const r = z.textInput(name, buf, &n, .{ .width = .fill, .hint = hint, .select_on_click = true, .copy_all = true });
    if (host.bridging()) wg.zuiText(idOf(id), host.rectOf(r.rect), buf[0..n], r.context_clicked);
    if (edit_id == id) {
        // focus left it: keep what was typed if it changed
        edit_id = .none;
        if (!std.mem.eql(u8, edit_buf[0..edit_len], text)) return edit_buf[0..edit_len];
    }
    return null;
}

var shown_bufs: [64][256]u8 = undefined;
var shown_next: usize = 0;

var edit_id: zui.Id = .none;
var edit_buf: [256]u8 = undefined;
var edit_len: usize = 0;

/// A colour: its label on the field's fill, the swatch on the right half;
/// a click opens BeeModel's colour picker (colorpick.zig, until M6 moves
/// it), `cb` runs on each change. Recorded as `colour:<label>` at the
/// swatch; in the field list for the context menu and Ctrl+C / Ctrl+V.
pub fn colourRow(z: *zui.Ui, label: []const u8, c: *u32, cb: ?*const fn () void, tip: []const u8) zui.Interaction {
    const t = ui.th;
    const st = &z.style;
    const name = zui.Ui.visibleLabel(label);
    const h = z.textSize(name).y + 2 * st.frame_padding.y;
    const r = z.placeSized(.fill, .auto, .{ .x = 120, .y = h });
    const id = z.id(label);
    const it = z.interact(id, r);
    z.drawRect(.{ .rect = r, .fill = col(if (it.hovered or it.held) t.field_hover else t.field), .radius = st.rounding });
    z.pushClip(.{ .x = r.x, .y = r.y, .w = r.w / 2 - 4, .h = r.h });
    z.drawText(.{ .x = r.x + 7, .y = r.y + st.frame_padding.y }, col(t.text_dim), name);
    z.popClip();
    const sw = zui.Rect{ .x = r.x + r.w / 2, .y = r.y + 3, .w = r.w - r.w / 2 - 4, .h = r.h - 6 };
    z.drawRect(.{ .rect = sw, .fill = col(c.*), .radius = 3 });
    rec("colour", name, host.rectOf(sw), true);
    if (host.bridging()) wg.zuiColor(idOf(id), host.rectOf(r), c, cb, it.context_clicked);
    if (tip.len > 0) z.tooltipRich(it, .{ .title = name, .body = tip });
    const by_ring = host.bridging() and wg.takeActivate(idOf(id));
    if (by_ring) host.noteActed();
    if (it.clicked or by_ring) @import("colorpick.zig").openFor(c, host.rectOf(sw), name, cb);
    return it;
}

/// Three compact fields in a row with the axis colours (a vector: location,
/// rotation, scale), labelled `label` each. Returns true if one changed.
pub fn vec3Row(z: *zui.Ui, label: []const u8, v: *[3]f32, o: NumberRowOptions) bool {
    const axes = [3]u32{ ui.th.axis_x, ui.th.axis_y, ui.th.axis_z };
    var changed = false;
    z.beginHorizontal(.{ .spacing = 4 });
    for (0..3) |c| {
        z.pushIdInt(c);
        defer z.popId();
        if (takeValue(z, label, &v[c])) changed = true;
        const item = z.numberField(label, &v[c], .{
            .width = .fill,
            .min = o.min,
            .max = o.max,
            .step = o.step,
            .drag_step = o.step,
            .decimals = o.decimals,
            .suffix = o.suffix,
            // (compact, as BeeModel's: the axis colour says which)
            .label = .none,
            .accent = col(axes[c]),
            .evaluator = &evaluator,
        });
        if (item.changed) changed = true;
        if (o.tip.len > 0) z.tooltipRich(item, .{ .title = zui.Ui.visibleLabel(label), .body = o.tip });
        // (BeeModel's compact fields were recorded by their value: number:0 m)
        var vb: [32]u8 = undefined;
        rec("number", ui.fmtNum(&vb, v[c], o.suffix), host.rectOf(item.rect), true);
        var oc = o;
        if (o.path == .transform) oc.path = .{ .transform = o.path.transform + @as(u8, @intCast(c)) };
        joinList(item, label, &v[c], oc);
    }
    z.endHorizontal();
    return changed;
}

/// A plain button the whole width (not an operator: see opButton), with
/// its tooltip. Returns its interaction.
pub fn button(z: *zui.Ui, label: []const u8, tip: []const u8) zui.Interaction {
    var b = z.button(label, .{ .width = .fill });
    if (tip.len > 0) z.tooltipRich(b, .{ .title = zui.Ui.visibleLabel(label), .body = tip });
    if (ring(b, label)) b.clicked = true;
    return b;
}

/// A button that shows whether its choice is the one (shading: Solid,
/// Wireframe; a modifier's axis), with its tooltip.
pub fn toggle(z: *zui.Ui, label: []const u8, on: bool, tip: []const u8) zui.Interaction {
    var b = z.button(label, .{ .width = .fill, .variant = if (on) .selected else .normal });
    if (tip.len > 0) z.tooltipRich(b, .{ .title = zui.Ui.visibleLabel(label), .body = tip });
    if (ring(b, label)) b.clicked = true;
    return b;
}

/// A heading in BeeModel's head font and accent, recorded as `heading`.
pub fn heading(z: *zui.Ui, title: []const u8) void {
    z.pushFont(host.headFont());
    z.label(title, .{ .color = col(ui.th.accent_fg) });
    z.popFont();
    rec("heading", title, host.rectOf(z.lastRect()), true);
}

/// A caption and a value in plain text (Objects: 3 of 4096).
pub fn infoPair(z: *zui.Ui, caption: []const u8, value: []const u8, caption_w: f32) void {
    beginCaptioned(z, caption, caption_w);
    z.label(value, .{ .width = .fill });
    rec("info", value, host.rectOf(z.lastRect()), true);
    endCaptioned(z);
}

/// The width the current column has, in units (for a field that should be
/// at most so wide: `.px(@min(240, columnWidth(z)))`).
pub fn columnWidth(z: *zui.Ui) f32 {
    return z.current().layout.options.cross_extent orelse 240;
}

/// BeeModel's record (ui.record), while Zui describes in BeeModel's frame.
fn rec(kind: []const u8, label: []const u8, r: Rect, enabled: bool) void {
    if (host.bridging()) ui.record(kind, label, r, enabled);
}
