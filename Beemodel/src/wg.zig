// The widgets of the last pass, as a list (widgets.s wg_list): what the
// keyboard's focus ring walks (a11y.s: Tab / Shift+Tab, Enter / Space, the
// arrows, Esc) and what a right-click or Ctrl+C / Ctrl+V over a field acts on
// (ctxui.s). Every ui.press with the left button adds its widget, so a new
// widget takes part without saying so; fields add their value too.
//
// A value set from here goes in as if typed: the field's own commit runs on
// the next pass, with its clamps, its callers' side effects and its undo step.
const std = @import("std");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const wl = @import("wayland.zig");
const clipboard = @import("clipboard.zig");

const Rect = gfx.Rect;

pub const Kind = enum(u8) { plain, number, text, color };

/// What Copy Data Path says for a field (animui.s field_key).
pub const Path = union(enum) {
    none,
    /// x y z rx ry rz sx sy sz of the active object
    transform: u8,
    /// material:<name>:<value's name>
    material: []const u8,
    /// modifier:<object>:<index>:<parameter>
    modifier: struct { index: u8, param: u8 },
    /// shape:<object>:<key>
    shape: u32,
    /// text:<object>:<value> (text3d.zig's value index)
    text: u8,
};

pub const E = struct {
    id: u32 = 0,
    kind: Kind = .plain,
    r: Rect = .{},
    clip: Rect = .{},
    layer: u8 = 0,
    val: f32 = 0,
    step: f32 = 0,
    lo: f32 = -std.math.inf(f32),
    hi: f32 = std.math.inf(f32),
    integer: bool = false,
    def: f32 = std.math.nan(f32),
    col: ?*u32 = null,
    cb: ?*const fn () void = null,
    path: Path = .none,
    /// A Zui field (bkit): a value for it waits in `zui_pending`.
    zui: bool = false,
    /// The Zui part it is in (zuihost's region id), for the hit passes.
    part: u64 = 0,
    text: [80]u8 = undefined,
    text_len: u8 = 0,
    label: [32]u8 = undefined,
    label_len: u8 = 0,

    pub fn txt(e: *const E) []const u8 {
        return e.text[0..e.text_len];
    }
    pub fn name(e: *const E) []const u8 {
        return e.label[0..e.label_len];
    }
};

pub var list: [900]E = undefined;
pub var n: usize = 0;
/// The widget with the keyboard's focus (0: none).
pub var kfocus: u32 = 0;
/// Enter / Space on a plain widget: its next press says yes.
pub var activate_id: u32 = 0;

/// The field the context menu is for.
pub var ctx: E = .{};
pub var ctx_on = false;

var next_label: []const u8 = "";
var next_def: f32 = std.math.nan(f32);
var next_path: Path = .none;

/// The default of labelled fields (the original's WIDGET ... def=).
const defaults = std.StaticStringMap(f32).initComptime(.{
    .{ "Alpha", 1.0 },            .{ "Clear coat", 0.0 },      .{ "Coat roughness", 0.03 },
    .{ "Emission strength", 0.0 }, .{ "IOR", 1.45 },           .{ "Metallic", 0.0 },
    .{ "Opacity", 1.0 },          .{ "Roughness", 0.5 },       .{ "Specular", 0.5 },
    .{ "Transmission", 0.0 },     .{ "Strength", 1.0 },        .{ "Rotation", 0.0 },
});

pub fn begin() void {
    n = 0;
    if (ui.cv.enabled) {
        // a draw pass: Zui describes its fields again; what it described
        // last time stays for the hit passes until then
        @memcpy(zui_keep[0..zui_next_n], zui_next[0..zui_next_n]);
        zui_keep_n = zui_next_n;
        zui_next_n = 0;
    }
}

/// The Zui part being described (zuihost sets it), so its entries can be
/// put back in its place.
pub var zui_part: u64 = 0;

/// A hit pass at the place of Zui part `part`: Zui describes nothing then
/// (it has the input already), its entries are those of the last draw pass,
/// in the same order among BeeModel's own widgets.
pub fn replayZui(part: u64) void {
    for (zui_keep[0..zui_keep_n]) |e| {
        if (e.part != part) continue;
        if (n >= list.len) break;
        list[n] = e;
        n += 1;
    }
}

/// Enter / Space from the focus ring on a Zui widget: it acts on the next
/// draw pass (`takeActivate`).
pub var zui_activate: u32 = 0;

pub fn takeActivate(id: u32) bool {
    if (zui_activate == 0 or zui_activate != id) return false;
    zui_activate = 0;
    return true;
}

/// A Zui button, check box, drop-down or row (bkit): in the list for the
/// focus ring.
pub fn zuiPlain(id: u32, r: Rect, label: []const u8) void {
    const e = slot(id, r) orelse return;
    e.kind = .plain;
    e.zui = true;
    setLabel(e, label);
    keepZui(e);
}

var zui_keep: [128]E = undefined;
var zui_keep_n: usize = 0;
var zui_next: [128]E = undefined;
var zui_next_n: usize = 0;

/// A Zui field's entry is complete: kept for the hit passes.
fn keepZui(e: *E) void {
    e.part = zui_part;
    if (zui_next_n >= zui_next.len) return;
    zui_next[zui_next_n] = e.*;
    zui_next_n += 1;
}

fn slot(id: u32, r: Rect) ?*E {
    if (n > 0 and list[n - 1].id == id) return &list[n - 1];
    if (n >= list.len) return null;
    const c = r.intersect(ui.cv.clip);
    if (c.w <= 0 or c.h <= 0) return null;
    list[n] = .{ .id = id, .r = r, .clip = ui.cv.clip, .layer = ui.layer };
    n += 1;
    return &list[n - 1];
}

/// A clickable widget (from ui.press).
pub fn add(id: u32, r: Rect) void {
    _ = slot(id, r);
}

/// The next field's name, default and data path (fields that do not say).
pub fn info(label: []const u8, def: f32, path: Path) void {
    next_label = label;
    next_def = def;
    next_path = path;
}

fn setText(e: *E, s: []const u8) void {
    const k = @min(s.len, e.text.len);
    @memcpy(e.text[0..k], s[0..k]);
    e.text_len = @intCast(k);
}

fn setLabel(e: *E, s: []const u8) void {
    const k = @min(s.len, e.label.len);
    @memcpy(e.label[0..k], s[0..k]);
    e.label_len = @intCast(k);
}

fn finish(e: *E) void {
    if (next_label.len > 0) setLabel(e, next_label);
    if (!std.math.isNan(next_def)) e.def = next_def;
    e.path = next_path;
    next_label = "";
    next_def = std.math.nan(f32);
    next_path = .none;
    if (ui.hit and ui.pressed & ui.RMB != 0 and ui.active == 0 and ui.inside(e.r)) openMenu(e);
}

pub fn number(id: u32, r: Rect, v: f32, st: f32, lo: f32, hi: f32, integer: bool, label: []const u8) void {
    const e = slot(id, r) orelse return;
    e.kind = .number;
    e.val = v;
    e.step = st;
    e.lo = lo;
    e.hi = hi;
    e.integer = integer;
    setLabel(e, label);
    if (defaults.get(label)) |d| e.def = d;
    finish(e);
}

/// A Zui number field (bkit.numberRow, vec3Row), described in the draw
/// pass: in the list for the context menu, Ctrl+C / Ctrl+V and I, with its
/// right-click (`context`) opening the menu here.
pub fn zuiNumber(id: u32, r: Rect, v: f32, st: f32, lo: f32, hi: f32, integer: bool, label: []const u8, context: bool) void {
    const e = slot(id, r) orelse return;
    e.kind = .number;
    e.val = v;
    e.step = st;
    e.lo = lo;
    e.hi = hi;
    e.integer = integer;
    e.zui = true;
    setLabel(e, label);
    if (defaults.get(label)) |d| e.def = d;
    finish(e);
    keepZui(e);
    if (context) openMenu(e);
}

/// A Zui text field (bkit.textRow), as `zuiNumber`.
pub fn zuiText(id: u32, r: Rect, s: []const u8, context: bool) void {
    const e = slot(id, r) orelse return;
    e.kind = .text;
    e.zui = true;
    setText(e, s);
    finish(e);
    keepZui(e);
    if (context) openMenu(e);
}

/// A Zui colour row (bkit.colourRow), as `zuiNumber`.
pub fn zuiColor(id: u32, r: Rect, c: *u32, cb: ?*const fn () void, context: bool) void {
    const e = slot(id, r) orelse return;
    e.kind = .color;
    e.col = c;
    e.cb = cb;
    e.zui = true;
    finish(e);
    keepZui(e);
    if (context) openMenu(e);
}

/// A value typed into a Zui field from here (the menu, Ctrl+V): its field
/// takes it the next time it is described.
pub const Pending = struct { id: u32, text: [64]u8, len: usize };
pub var zui_pending: ?Pending = null;

/// The value waiting for Zui field `id`, taken.
pub fn takeZui(id: u32) ?Pending {
    const p = zui_pending orelse return null;
    if (p.id != id) return null;
    zui_pending = null;
    return p;
}

pub fn text(id: u32, r: Rect, s: []const u8) void {
    const e = slot(id, r) orelse return;
    e.kind = .text;
    setText(e, s);
    finish(e);
}

pub fn color(id: u32, r: Rect, c: *u32, cb: ?*const fn () void) void {
    const e = slot(id, r) orelse return;
    e.kind = .color;
    e.col = c;
    e.cb = cb;
    finish(e);
}

// --- values ------------------------------------------------------------------------

/// A number with all the digits it needs (wg_ftoa, 6 decimals, zeros dropped).
fn numText(buf: []u8, v: f32) []const u8 {
    const s = std.fmt.bufPrint(buf, "{d:.6}", .{v}) catch return "0";
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var k = s.len;
    while (s[k - 1] == '0') k -= 1;
    if (s[k - 1] == '.') k -= 1;
    return s[0..k];
}

/// What the field would have typed in it.
fn valueText(buf: []u8, e: *const E) []const u8 {
    return switch (e.kind) {
        .number => numText(buf, e.val),
        .text => e.txt(),
        .color => std.fmt.bufPrint(buf, "#{x:0>6}", .{if (e.col) |c| c.* else 0}) catch "",
        .plain => "",
    };
}

/// Type s into the field and confirm it (on the next pass).
fn enter(e: *const E, s: []const u8) void {
    if (e.kind == .color) {
        const c = @import("colorpick.zig").parseHex(s) orelse return;
        if (e.col) |p| {
            p.* = c;
            if (e.cb) |f| f();
        }
        return;
    }
    if (e.zui) {
        var p = Pending{ .id = e.id, .text = undefined, .len = @min(s.len, 64) };
        @memcpy(p.text[0..p.len], s[0..p.len]);
        zui_pending = p;
        @import("app.zig").dirty = true;
        return;
    }
    ui.editSet(e.id, s, true);
    ui.edit_submit = true;
}

/// A value is on its way into a field: another pass commits it.
pub fn pending() bool {
    return ui.edit_submit and ui.edit_id != 0;
}

/// The pass ran: the field was not shown any more.
pub fn afterPass() void {
    if (pending()) {
        ui.edit_submit = false;
        ui.edit_id = 0;
    }
}

pub fn copyValue(e: *const E) void {
    var b: [64]u8 = undefined;
    clipboard.copy(valueText(&b, e));
}

pub fn pasteValue(e: *const E) void {
    var b: [250]u8 = undefined;
    const got = clipboard.paste(&b);
    if (got == 0) return;
    for (b[0..got]) |*c| {
        if (c.* < 0x20) c.* = ' ';
    }
    enter(e, std.mem.trim(u8, b[0..got], " "));
}

pub fn resetValue(e: *const E) void {
    if (std.math.isNan(e.def)) return;
    var b: [64]u8 = undefined;
    enter(e, numText(&b, e.def));
}

// --- the field's menu (ctxui.s) -----------------------------------------------------

const cat = @import("catalog.zig");
const menu_items = [_]cat.Item{ .{ .op = "op_fld_reset" }, .sep, .{ .op = "op_fld_copy" }, .{ .op = "op_fld_paste" }, .sep, .{ .op = "op_fld_key" }, .{ .op = "op_fld_path" } };

fn openMenu(e: *const E) void {
    ctx = e.*;
    ctx_on = true;
    @import("menus.zig").openAt(&menu_items, ui.mx, ui.my, -1);
}

fn shown() bool {
    if (!ctx_on) return false;
    for (list[0..n]) |*e| {
        if (e.id == ctx.id) return true;
    }
    return false;
}

const s_gone = "The field is no longer shown";

pub fn pollReset() ?[]const u8 {
    if (!shown()) return s_gone;
    if (ctx.kind == .text or ctx.kind == .plain or std.math.isNan(ctx.def)) return "This field has no default value";
    return null;
}
pub fn pollValue() ?[]const u8 {
    return if (shown()) null else s_gone;
}
pub fn pollKey() ?[]const u8 {
    if (!shown()) return s_gone;
    if (ctx.kind == .text) return "Only numbers and colours can be keyed";
    return null;
}
pub fn pollPath() ?[]const u8 {
    if (!shown()) return s_gone;
    if (ctx.kind == .text) return "Only numbers and colours can be keyed";
    return null;
}
pub fn opReset() void {
    resetValue(&ctx);
}
pub fn opCopy() void {
    copyValue(&ctx);
}
pub fn opPaste() void {
    pasteValue(&ctx);
}
pub fn opKey() void {
    _ = @import("animui.zig").fieldKey(&ctx);
}

pub fn opPath() void {
    const scene = @import("scene.zig");
    const app = @import("app.zig");
    var b: [128]u8 = undefined;
    const names = [_][]const u8{ "x", "y", "z", "rx", "ry", "rz", "sx", "sy", "sz" };
    const s: []const u8 = switch (ctx.path) {
        .transform => |k| if (scene.active) |a| (std.fmt.bufPrint(&b, "{s}:{s}", .{ scene.objects[a].name(), names[k] }) catch "") else "",
        .material => |m| std.fmt.bufPrint(&b, "material:{s}:{s}", .{ m, if (@import("material.zig").paramOfLabel(ctx.name())) |p| @import("material.zig").params[p].name else lowerName(ctx.name()) }) catch "",
        .modifier => |d| blk: {
            const a = scene.active orelse break :blk "";
            const o = &scene.objects[a];
            if (d.index >= o.mods.n) break :blk "";
            const ps = @import("mods.zig").params(o.mods.m[d.index].kind);
            if (d.param >= ps.len) break :blk "";
            break :blk std.fmt.bufPrint(&b, "modifier:{s}:{d}:{s}", .{ o.name(), d.index, ps[d.param].name }) catch "";
        },
        .shape => |k| blk: {
            const a = scene.active orelse break :blk "";
            const sk = @import("shape.zig").of(a) orelse break :blk "";
            if (k >= sk.h.n) break :blk "";
            break :blk std.fmt.bufPrint(&b, "shape:{s}:{s}", .{ scene.objects[a].name(), @import("shape.zig").name(&sk.h.keys[k]) }) catch "";
        },
        .text => |k| if (scene.active) |a| (std.fmt.bufPrint(&b, "text:{s}:{s}", .{ scene.objects[a].name(), @import("text3d.zig").keyName(k) }) catch "") else "",
        .none => "",
    };
    if (s.len == 0) return app.log("This field has no data path for scripts", .{});
    clipboard.copy(s);
}

/// "Coat roughness" -> "coat_roughness" (the values' names in scripts).
fn lowerName(s: []const u8) []const u8 {
    const S = struct {
        var b: [32]u8 = undefined;
    };
    const k = @min(s.len, S.b.len);
    for (s[0..k], 0..) |c, i| S.b[i] = if (c == ' ') '_' else std.ascii.toLower(c);
    return S.b[0..k];
}

// --- Ctrl+C / Ctrl+V over a field ---------------------------------------------------

/// The field under the pointer.
pub fn hoveredField() ?*const E {
    return hovered();
}

fn hovered() ?*const E {
    var i = n;
    while (i > 0) {
        i -= 1;
        const e = &list[i];
        if (e.layer == ui.hot_layer and e.kind != .plain and e.r.intersect(e.clip).contains(ui.mx, ui.my)) return e;
    }
    return null;
}

/// The key on the keyboard's letter: was it Ctrl+C / Ctrl+V over a field?
pub fn clipKey(code: u32) bool {
    if (ui.mods & (wl.MOD_CTRL | wl.MOD_ALT | wl.MOD_SHIFT) != wl.MOD_CTRL) return false;
    if (code != 46 and code != 47) return false;
    const e = hovered() orelse return false;
    if (e.kind == .color) return false; // (the original: values only)
    if (code == 46) copyValue(e) else pasteValue(e);
    return true;
}

// --- the keyboard's focus (a11y.s, wg_focus_step) ------------------------------------

pub const Scope = struct { layer: ?u8 = null, area: ?Rect = null };

fn inScope(e: *const E, s: Scope) bool {
    if (e.r.intersect(e.clip).w <= 0) return false;
    if (s.layer) |l| {
        if (e.layer != l) return false;
    }
    if (s.area) |a| {
        if (!a.contains(e.r.x + @divTrunc(e.r.w, 2), e.r.y + @divTrunc(e.r.h, 2))) return false;
    }
    return true;
}

/// The next widget in scope takes the focus. False: there is none.
pub fn step(dir: i32, s: Scope) bool {
    var at: i64 = -1;
    for (list[0..n], 0..) |*e, i| {
        if (e.id == kfocus) at = @intCast(i);
    }
    const count: i64 = @intCast(n);
    if (count == 0) return false;
    var i = at;
    if (at < 0 and dir < 0) i = 0;
    var lap: i64 = 0;
    while (lap < count) : (lap += 1) {
        i = @mod(i + dir, count);
        const e = &list[@intCast(i)];
        if (inScope(e, s)) {
            kfocus = e.id;
            return true;
        }
    }
    return false;
}

pub fn focused() ?*const E {
    if (kfocus == 0) return null;
    for (list[0..n]) |*e| {
        if (e.id == kfocus) return e;
    }
    kfocus = 0;
    return null;
}

/// Enter / Space: a field is typed into; anything else as if clicked (the
/// caller runs a pass, then lets go of it).
pub fn activate() void {
    const e = focused() orelse return;
    if (e.zui) {
        zui_activate = e.id;
        @import("app.zig").dirty = true;
        return;
    }
    if (e.kind == .number or e.kind == .text) {
        var b: [64]u8 = undefined;
        ui.editSet(e.id, valueText(&b, e), true);
    } else activate_id = e.id;
}

/// The arrows: a step of the number.
pub fn nudge(dir: i32) void {
    const e = focused() orelse return;
    if (e.kind != .number) return;
    const d: f32 = @floatFromInt(dir);
    const v = std.math.clamp(e.val + (if (e.integer) d else d * e.step * 10), e.lo, e.hi);
    var b: [64]u8 = undefined;
    enter(e, numText(&b, v));
}

/// The ring round the focused widget.
pub fn drawRing() void {
    const e = focused() orelse return;
    const cv = ui.cv;
    ui.record("focus", e.name(), e.r, true);
    const old = cv.clip;
    defer cv.clip = old;
    _ = cv.setClip(e.clip.intersect(old));
    const th = ui.th;
    cv.rectLine(.{ .x = e.r.x - 2, .y = e.r.y - 2, .w = e.r.w + 4, .h = e.r.h + 4 }, th.focus);
    cv.rectLine(.{ .x = e.r.x - 1, .y = e.r.y - 1, .w = e.r.w + 2, .h = e.r.h + 2 }, th.focus);
}

test "number text" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.5", numText(&b, 1.5));
    try std.testing.expectEqualStrings("2", numText(&b, 2));
    try std.testing.expectEqualStrings("-0.25", numText(&b, -0.25));
}
