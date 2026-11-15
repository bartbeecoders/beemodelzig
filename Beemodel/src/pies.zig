// Pie menus and the viewport's right-click wheel, as in the original.
// Zui draws them and takes the pointer and keys while one is open (`client`,
// a modal client of zuihost.zig); here: when they open, what is on them and
// what a choice runs.
//
// Pies: hold Z (shading), Ctrl+Tab (the mode) or Shift+S (the 3D cursor and
// snapping) over a 3D viewport and the choices appear around the pointer;
// release over one to pick it. A quick tap still does the key's own action.
//
// The wheel: a right click in the viewport opens a ring of coloured entries
// round the pointer. Hovering a group (Visibility, Boolean, Material,
// Physics) opens its choices on an outer arc. Click one, or keep the button
// down, drag onto it and let go. Each entry has a number: 1-9, 0, - pick it
// (a group's number opens it, Backspace goes back). Esc, the centre or a
// click outside closes it. Greyed entries say why above the wheel.
const std = @import("std");
const zui = @import("zui");
const host = @import("zuihost.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const ops = @import("ops.zig");
const cat = @import("catalog.zig");
const scene = @import("scene.zig");
const undo = @import("undo.zig");
const app = @import("app.zig");
const wl = @import("wayland.zig");

const Icon = gfx.Icon;

// --- pies -------------------------------------------------------------------

pub const PieKind = enum { shading, mode, snap };
const HOLD_MS = 200;
const PIE_R = 96;

const shading_items = [_][]const u8{ "view.shading_solid", "view.shading_wireframe", "view.shading_material", "view.shading_rendered" };
const mode_items = [_][]const u8{ "mode.object", "mode.edit", "mode.weight_paint", "mode.sculpt", "mode.vertex_paint", "mode.texture_paint" };
const snap_items = [_][]const u8{ "view.cursor_to_selected", "object.to_cursor", "object.to_grid", "view.toggle_snap", "view.cursor_reset" };


var armed: u32 = 0; // the pie key being held (0: none)
var armed_kind: PieKind = .shading;
var armed_at: i64 = 0;
var armed_x: i32 = 0;
var armed_y: i32 = 0;
pub var pie_open: bool = false;
var pie_kind: PieKind = .shading;
var pie_x: i32 = 0;
var pie_y: i32 = 0;
/// (Zui's) the pie or wheel is to be opened in Zui's next frame.
var open_req = false;
/// The key that armed the pie, as Zui's (its release picks).
var pie_key: ?zui.Key = null;

fn pieItems(k: PieKind) []const []const u8 {
    return switch (k) {
        .shading => &shading_items,
        .mode => &mode_items,
        .snap => &snap_items,
    };
}

/// A key press: arms a pie when it is one of the pie keys. Returns true
/// when the key was taken (also for the key repeats of a held pie key).
pub fn keyDown(code: u32, mods: u32, over_view3d: bool) bool {
    const K = ui.KEY;
    if (armed != 0 and code == armed) return true; // key repeat
    if (armed != 0 and !pie_open) armed = 0; // another key: no pie, no tap
    const md = mods & (wl.MOD_SHIFT | wl.MOD_CTRL | wl.MOD_ALT);
    if (!over_view3d) return false;
    // (Zui draws the pies, in the main window only until panels' windows are Zui's)
    if (@import("panelwin.zig").cur >= 0) return false;
    const kind: PieKind = if (code == K.Z and md == 0) .shading else if (code == K.TAB and md == wl.MOD_CTRL) .mode else if (code == K.S and md == wl.MOD_SHIFT and !@import("sculpt.zig").on) .snap else return false;
    armed = code;
    armed_kind = kind;
    armed_at = app.now_ms;
    armed_x = ui.mx;
    armed_y = ui.my;
    return true;
}

/// A key release: a tap runs the key's own action; a release over a choice picks it.
pub fn keyUp(code: u32) void {
    if (armed == 0 or code != armed) return;
    armed = 0;
    if (pie_open) return; // (Zui's: its release picks)
    // a quick tap: the key's own action
    switch (armed_kind) {
        .shading => ops.runId("view.toggle_wireframe"),
        // (an armature: its pose mode, as do_sculpt_mode)
        .mode => ops.runId("object.sculpt_mode"),
        .snap => {},
    }
}

/// Called from the timer: opens the pie once the key has been held long enough.
pub fn tick() ?i32 {
    if (armed == 0 or pie_open) return null;
    const left = armed_at + HOLD_MS - app.now_ms;
    if (left > 0) return @intCast(left);
    pie_open = true;
    open_req = true;
    pie_key = host.keyFor(armed);
    pie_kind = armed_kind;
    // where the key went down, kept in the window
    pie_x = std.math.clamp(armed_x, @min(170, @divTrunc(app.winW(), 2)), @max(@min(170, @divTrunc(app.winW(), 2)), app.winW() - 170));
    pie_y = std.math.clamp(armed_y, @min(80, @divTrunc(app.winH(), 2)), @max(@min(80, @divTrunc(app.winH(), 2)), app.winH() - 80));
    app.dirty = true;
    return null;
}

fn closePie() void {
    pie_open = false;
    armed = 0;
    app.dirty = true;
}

fn pick(k: usize) void {
    const items = pieItems(pie_kind);
    if (k >= items.len) return;
    const oi = ops.byId(items[k]) orelse return;
    ops.run(oi);
}

// --- the wheel ------------------------------------------------------------------

// the radii, scaled down when the window is small (set when it opens)
var R0: i32 = 50;
var R1: i32 = 156;
var R3: i32 = 238;

fn F(x: i32) f32 {
    return @floatFromInt(x);
}

fn setScale() void {
    // the outer arc fits the window's shorter side (never above full size)
    const room = @divTrunc(@min(app.winW(), app.winH() - 40), 2) - 8;
    const k = std.math.clamp(@as(f32, @floatFromInt(room)) / 238.0, 0.55, 1.0);
    const sc = struct {
        fn f(v: f32, kk: f32) i32 {
            return @intFromFloat(@round(v * kk));
        }
    }.f;
    R0 = sc(50, k);
    R1 = sc(156, k);
    R3 = sc(238, k);
}

const Choice = struct {
    op: []const u8 = "",
    label: []const u8,
    icon: Icon,
    /// a material preset: the colour it gives (0: an operator)
    preset: u32 = 0,
};

const Entry = struct {
    op: []const u8 = "", // an operator, or "" for a group
    label: []const u8,
    icon: Icon,
    color: u32,
    group: []const Choice = &.{},
};

const vis_group = [_]Choice{ .{ .op = "object.hide", .label = "Hide", .icon = .eye_off }, .{ .op = "object.reveal", .label = "Reveal", .icon = .eye } };
const bool_group = [_]Choice{
    .{ .op = "object.boolean_union", .label = "Union", .icon = .bool_union },
    .{ .op = "object.boolean_difference", .label = "Difference", .icon = .bool_diff },
    .{ .op = "object.boolean_intersect", .label = "Intersect", .icon = .bool_isect },
};
// the original's preset base colours (linear) shown as sRGB
const mat_group = [_]Choice{
    .{ .label = "Gold", .icon = .material, .preset = 0xffe29d },    .{ .label = "Chrome", .icon = .material, .preset = 0xc4c5c4 },
    .{ .label = "Plastic", .icon = .material, .preset = 0xdb453f }, .{ .label = "Rubber", .icon = .material, .preset = 0x3f3f3f },
    .{ .label = "Glass", .icon = .material, .preset = 0xeaf4ff },   .{ .label = "Wood", .icon = .material, .preset = 0xb38e65 },
    .{ .label = "Marble", .icon = .material, .preset = 0xf1f0ed },  .{ .label = "Emissive", .icon = .material, .preset = 0xffefcb },
};
const phys_group = [_]Choice{
    .{ .op = "rigid.add", .label = "Active", .icon = .physics },  .{ .op = "rigid.add", .label = "Passive", .icon = .lock },
    .{ .op = "rigid.material", .label = "Rubber", .icon = .dot }, .{ .op = "rigid.material", .label = "Ice", .icon = .dot },
    .{ .op = "rigid.material", .label = "Wood", .icon = .dot },   .{ .op = "rigid.material", .label = "Metal", .icon = .dot },
    .{ .op = "rigid.material", .label = "Stone", .icon = .dot },  .{ .op = "rigid.remove", .label = "Remove", .icon = .trash },
};

const wheel_object = [_]Entry{
    .{ .op = "ai.ask", .label = "Ask AI", .icon = .sparkle, .color = 0x8b5cf6 },
    .{ .op = "object.delete", .label = "Delete", .icon = .trash, .color = 0xe5484d },
    .{ .op = "object.duplicate", .label = "Duplicate", .icon = .duplicate, .color = 0x3b82f6 },
    .{ .label = "Visibility", .icon = .eye, .color = 0x14b8a6, .group = &vis_group },
    .{ .label = "Boolean", .icon = .bool_union, .color = 0x6366f1, .group = &bool_group },
    .{ .op = "mode.toggle_edit", .label = "Edit", .icon = .edit, .color = 0xf59e0b },
    .{ .label = "Material", .icon = .material, .color = 0xd946ef, .group = &mat_group },
    .{ .label = "Physics", .icon = .physics, .color = 0xf97316, .group = &phys_group },
    .{ .op = "object.measure", .label = "Measure", .icon = .weight, .color = 0x0ea5e9 },
    .{ .op = "view.camera_to_view", .label = "Camera", .icon = .camera, .color = 0xec4899 },
    .{ .op = "mesh.repair", .label = "Repair", .icon = .repair, .color = 0x22a55b },
};

// edit mode's wheel (wheel.s wheel_edit and its groups)
const cut_group = [_]Choice{ .{ .op = "mesh.loopcut", .label = "Loop Cut", .icon = .loopcut }, .{ .op = "mesh.knife", .label = "Knife", .icon = .knife } };
const merge_group = [_]Choice{
    .{ .op = "mesh.merge_center", .label = "At Center", .icon = .merge },
    .{ .op = "mesh.merge_collapse", .label = "Collapse", .icon = .dot },
    .{ .op = "mesh.merge_distance", .label = "By Distance", .icon = .measure },
};
const mdel_group = [_]Choice{
    .{ .op = "mesh.delete_vertices", .label = "Vertices", .icon = .vertex },
    .{ .op = "mesh.delete_edges", .label = "Edges", .icon = .edge },
    .{ .op = "mesh.delete_faces", .label = "Faces", .icon = .plane },
};
const more_group = [_]Choice{
    .{ .op = "mesh.subdivide", .label = "Subdivide", .icon = .subdivide },
    .{ .op = "mesh.fill", .label = "Fill", .icon = .fill },
    .{ .op = "mesh.bridge", .label = "Bridge", .icon = .bridge },
    .{ .op = "mesh.flip_normals", .label = "Flip", .icon = .flip },
    .{ .op = "mesh.recalc_normals", .label = "Normals", .icon = .normals },
};
const wheel_edit = [_]Entry{
    .{ .op = "ai.ask", .label = "Ask AI", .icon = .sparkle, .color = 0x8b5cf6 },
    .{ .op = "mesh.extrude", .label = "Extrude", .icon = .extrude, .color = 0x22a55b },
    .{ .op = "mesh.inset", .label = "Inset", .icon = .inset, .color = 0x14b8a6 },
    .{ .op = "mesh.bevel", .label = "Bevel", .icon = .bevel, .color = 0x0ea5e9 },
    .{ .label = "Cut", .icon = .knife, .color = 0xf97316, .group = &cut_group },
    .{ .label = "Merge", .icon = .merge, .color = 0x6366f1, .group = &merge_group },
    .{ .label = "Delete", .icon = .trash, .color = 0xe5484d, .group = &mdel_group },
    .{ .label = "More", .icon = .more, .color = 0x64748b, .group = &more_group },
    .{ .op = "mode.toggle_edit", .label = "Object", .icon = .object, .color = 0xf59e0b },
};

/// The wheel that is open: the object's or, in edit mode, the mesh's.
var wheel: []const Entry = &wheel_object;

pub var wheel_open: bool = false;
var wx: i32 = 0;
var wy: i32 = 0;
var wheel_area: i16 = -1;
var group: ?usize = null; // the open group
/// The right button that opened it is still down: its release picks.
var wheel_held = false;

/// Right-click in a viewport: open the wheel at (x, y).
pub fn openWheel(x: i32, y: i32, area: i16) void {
    // (Zui draws the wheel, in the main window only until panels' windows
    // are Zui's: in a panel's window, the list of the same)
    if (@import("panelwin.zig").cur >= 0) {
        const menus = @import("menus.zig");
        return menus.openAt(if (@import("editmesh.zig").active) &cat.ctx_edit else &cat.ctx_object, x, y, area);
    }
    wheel_open = true;
    wheel = if (@import("editmesh.zig").active) &wheel_edit else &wheel_object;
    setScale();
    // the whole outer ring inside the window, room for the line above (wheel.s)
    wx = std.math.clamp(x, R3 + 4, @max(R3 + 4, app.winW() - R3 - 4));
    wy = std.math.clamp(y, R3 + 40, @max(R3 + 40, app.winH() - R3 - 4 - 24));
    wheel_area = area;
    group = null;
    open_req = true;
    wheel_held = ui.down & ui.RMB != 0 or @import("zuihost.zig").buttonDown(.right);
    app.dirty = true;
}

pub fn closeWheel() void {
    wheel_open = false;
    group = null;
    app.dirty = true;
}

fn entryReason(e: *const Entry) ?[]const u8 {
    if (e.op.len == 0) return null;
    const oi = ops.byId(e.op) orelse return ops.not_ported;
    return ops.reason(oi);
}

fn choiceReason(c: *const Choice) ?[]const u8 {
    if (c.preset != 0) return if (scene.nSelected() == 0) "Select an object first" else null;
    const oi = ops.byId(c.op) orelse return ops.not_ported;
    return ops.reason(oi);
}

fn runEntry(i: usize) void {
    const e = &wheel[i];
    if (e.group.len > 0) {
        group = i;
        app.dirty = true;
        return;
    }
    if (entryReason(e)) |w| {
        app.toast(.warn, "{s}: {s}", .{ e.label, w });
        return;
    }
    closeWheel();
    if (wheel_area >= 0) app.setActiveArea(wheel_area);
    ops.runId2(e.op);
}

fn runChoice(g: usize, k: usize) void {
    const c = &wheel[g].group[k];
    if (choiceReason(c)) |w| {
        app.toast(.warn, "{s}: {s}", .{ c.label, w });
        return;
    }
    closeWheel();
    if (c.preset != 0) {
        var lb: [24]u8 = undefined;
        const pk = @import("material.zig").presetIndex(std.ascii.lowerString(&lb, c.label[0..@min(c.label.len, lb.len)])) orelse return;
        if (!@import("matops.zig").applyToSelected(pk)) {
            app.toast(.warn, "Material: select mesh objects", .{});
            return;
        }
        var b: [40]u8 = undefined;
        undo.label(std.fmt.bufPrint(&b, "Material: {s}", .{c.label}) catch "Material");
        app.toast(.ok, "Material: {s}", .{c.label});
        return;
    }
    if (wheel_area >= 0) app.setActiveArea(wheel_area);
    ops.runId2(c.op);
}

// --- Zui's pies and wheel ----------------------------------------------------

/// The open pie or wheel, drawn by Zui; it takes every event while open.
pub const client: host.Client = .{
    .visible = shown,
    .describe = describe,
    .modal = true,
    .key = padKey,
};

fn shown() bool {
    return pie_open or wheel_open;
}

/// The keypad's digits pick on the wheel as the top row's do.
fn padKey(z: *zui.Ui, code: u32) bool {
    if (!wheel_open) return false;
    const k: zui.Key = switch (code) {
        79 => .@"1",
        80 => .@"2",
        81 => .@"3",
        75 => .@"4",
        76 => .@"5",
        77 => .@"6",
        71 => .@"7",
        72 => .@"8",
        73 => .@"9",
        82 => .@"0",
        74 => .minus,
        else => return false,
    };
    z.input.onKeyPress(k);
    return true;
}

fn describe(z: *zui.Ui) void {
    if (pie_open) describePie(z) else if (wheel_open) describeWheel(z);
}

var pie_items: [8]zui.PieItem = undefined;

fn describePie(z: *zui.Ui) void {
    const name = "##pie";
    if (open_req) {
        open_req = false;
        z.openPieAt(name, pie_key, .{ .x = @floatFromInt(pie_x), .y = @floatFromInt(pie_y) }, true);
    }
    const ids = pieItems(pie_kind);
    const n = @min(ids.len, pie_items.len);
    for (ids[0..n], 0..) |id, k| {
        const oi = ops.byId(id);
        pie_items[k] = .{
            .label = if (oi) |i| cat.entries[i].label else id,
            .disabled = if (oi) |i| ops.reason(i) else ops.not_ported,
            .checked = if (oi) |i| ops.checked(i) orelse false else false,
        };
    }
    switch (z.pie(name, pie_items[0..n], .{ .radius = PIE_R })) {
        .none => {},
        .chosen => |k| {
            closePie();
            pick(k);
        },
        .tapped, .cancelled => closePie(),
    }
}

/// The wheel's entries and their groups' choices, as Zui's.
var w_items: [12]zui.WheelItem = undefined;
var w_kids: [12][8]zui.WheelItem = undefined;

fn wheelItems() []const zui.WheelItem {
    const n = @min(wheel.len, w_items.len);
    for (wheel[0..n], 0..) |*e, i| {
        const m = @min(e.group.len, w_kids[i].len);
        for (e.group[0..m], 0..) |*c, k| {
            w_kids[i][k] = .{ .label = c.label, .icon = host.icon(c.icon), .color = host.col(if (c.preset != 0) c.preset else e.color), .disabled = choiceReason(c) };
        }
        w_items[i] = .{ .label = e.label, .icon = host.icon(e.icon), .color = host.col(e.color), .disabled = entryReason(e), .children = w_kids[i][0..m] };
    }
    return w_items[0..n];
}

fn describeWheel(z: *zui.Ui) void {
    const name = "##wheel";
    if (open_req) {
        open_req = false;
        z.openWheelAt(name, if (wheel_held) .right else null, .{ .x = @floatFromInt(wx), .y = @floatFromInt(wy) });
    }
    switch (z.wheel(name, wheelItems(), .{ .inner = F(R0), .outer = F(R1), .labels = true })) {
        .none => {},
        .chosen => |c| if (c.child) |k| runChoice(c.item, k) else runEntry(c.item),
        .cancelled => closeWheel(),
    }
    // (Zui's state: the open group, for what runs from a group's choice)
    group = z.pie_state.group;
}
