// Getting started (help.s): the welcome screen at start-up (Start | Recent |
// Samples, the keymap, "Show this at start"), the templates and the quick
// actions in an empty viewport. The templates that need later phases stay
// listed, greyed, with the reason.
const std = @import("std");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const prefs = @import("prefs.zig");
const dialogs = @import("dialogs.zig");
const menus = @import("menus.zig");
const files = @import("files.zig");
const keys = @import("keys.zig");
const icons = @import("icons.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");

const Rect = gfx.Rect;
const WL_W = 720;
const WL_H = 420;
const WG_H = 22;

const Tpl = struct { key: []const u8, label: []const u8, tip: []const u8, why: ?[]const u8 = null, icon: icons.Icon = .scene };
const start = [_]Tpl{
    .{ .key = "", .label = "Default Scene", .tip = "A cube, a light and a camera", .icon = .cube },
    .{ .key = "empty", .label = "Empty Scene", .tip = "Nothing in it", .icon = .empty },
    .{ .key = "product", .label = "Product (CAD)", .tip = "A part from a sketch and parameters, in millimetres", .icon = .sketch },
    .{ .key = "character", .label = "Character", .tip = "A body skinned to an armature", .icon = .armature },
    .{ .key = "terrain", .label = "Terrain", .tip = "Hills to sculpt and paint (a landscape)", .icon = .world },
};
const samples = [_]Tpl{
    .{ .key = "tree", .label = "L-system Tree", .tip = "A plant grown by rewriting rules", .icon = .branch },
    .{ .key = "ball", .label = "Bouncing Ball", .tip = "Rigid bodies: press Space to play", .why = "Rigid bodies come with physics (phase 10)", .icon = .physics },
};
const km_labels = [_][]const u8{ "Keymap: BeeModel", "Keymap: laptop (Alt + left pans)", "Keymap: Blender 4.x", "Keymap: Blender 4.x, laptop" };

/// At start-up: unless a file was opened, or it is turned off.
pub fn atStart(env: ?[]const u8) void {
    if (env) |e| {
        if (std.mem.eql(u8, e, "0")) return;
    }
    if (prefs.welcome) dialogs.open(.welcome);
}

pub fn deleteAll() void {
    var i = scene.count;
    while (i > 0) {
        i -= 1;
        scene.remove(i);
        app.log("  objects deleted: 1", .{}); // (the templates' delete(name(0)), one by one)
    }
}

/// help.template <name> (help.s do_template).
pub fn opTemplate() void {
    const nm = std.mem.trim(u8, ops.arg, " ");
    for (start ++ samples) |t| {
        if (!std.mem.eql(u8, t.key, nm) or nm.len == 0) continue;
        if (t.why) |w| return app.toast(.warn, "{s}: {s}", .{ t.label, w });
        deleteAll();
        // (each template is a BeeScript in the original (help.s t_*): its operators quiet)
        const q = ops.quiet;
        defer ops.quiet = q;
        ops.quiet = true;
        if (std.mem.eql(u8, nm, "character")) character();
        if (std.mem.eql(u8, nm, "product")) product();
        if (std.mem.eql(u8, nm, "terrain")) terrain();
        if (std.mem.eql(u8, nm, "tree")) tree();
        app.dirty = true;
        return;
    }
    app.log("  help.template empty|product|character|terrain|tree|ball", .{});
}

/// t_character: a rig, a body skinned to it, a light and a camera.
fn character() void {
    const arm = @import("arm.zig");
    const edit = @import("armedit.zig");
    const old = ops.arg;
    defer ops.arg = old;
    _ = arm.create("Rig") orelse return;
    ops.arg = "Spine Bone 0 1 0 0 1.8 0";
    edit.opBone();
    const b = scene.add(.cylinder) orelse return;
    scene.objects[b].setName("Body");
    scene.objects[b].loc = .{ 0, 1, 0 };
    scene.objects[b].scl = .{ 0.4, 0.4, 0.4 };
    ops.arg = "Body Rig";
    edit.opParent();
    scene.selectOnly(b);
    ops.arg = "";
    ops.runId("create.light");
    ops.runId("create.camera");
}

/// t_product: millimetres, the parameters w d h, a sketch on the ground with
/// a 60 x 40 rectangle, padded h into "Part", its vertical edges filleted
/// 3 mm; a light and a camera.
fn product() void {
    const cad = @import("cad.zig");
    const skobj = @import("skobj.zig");
    const feature = @import("feature.zig");
    const old = ops.arg;
    defer ops.arg = old;
    ops.arg = "mm";
    ops.runId("scene.units");
    for ([_][2][]const u8{ .{ "w", "60mm" }, .{ "d", "40mm" }, .{ "h", "20mm" } }) |p| {
        if (cad.paramSet(p[0], p[1])) cad.rebuild();
    }
    const s = skobj.create("Base", 1, 0) orelse return;
    if (skobj.begin(s)) |b| _ = skobj.rect(b, 0, 0, 60, 40);
    _ = skobj.end(s);
    _ = feature.pad("Part", scene.objects[s].name(), "h");
    _ = feature.fillet("Part", "3mm", "vertical");
    if (feature.findExact("Part")) |i| scene.selectOnly(i);
    ops.arg = "";
    ops.runId("create.light");
    ops.runId("create.camera");
    @import("undo.zig").label("New from Template");
}

/// t_terrain: hills 40 m across, 4 m high (a landscape), a light and a camera
/// (a script: its operators quiet).
fn terrain() void {
    const old = ops.arg;
    const q = ops.quiet;
    defer {
        ops.arg = old;
        ops.quiet = q;
    }
    ops.quiet = true;
    ops.arg = "hills size 40";
    ops.runId("landscape.add");
    ops.arg = "set 0 height 4";
    ops.runId("landscape.layer");
    ops.arg = "";
    ops.runId("create.light");
    ops.runId("create.camera");
    @import("undo.zig").label("New from Template");
}

/// t_tree: select(lsystem("Tree", "X", "X=F+[[X]-X]-F[-FX]+X; F=FF", 5, 25,
/// 0.05, 0.01)), a light.
fn tree() void {
    const old = ops.arg;
    defer ops.arg = old;
    const A = @import("alloc.zig").A;
    var me = @import("procgen.zig").lsBuild(A, "X", "X=F+[[X]-X]-F[-FX]+X; F=FF", 5, 25, 0.05, 0.01) orelse return;
    defer me.deinit(A);
    if (me.verts.len > 0) {
        if (scene.addMesh(me.verts, me.poff, me.loops)) |mi| {
            if (@import("landscape.zig").newObject(mi, "Tree")) |k| scene.selectOnly(k);
        }
    }
    ops.arg = "";
    ops.runId("create.light");
    @import("undo.zig").label("New from Template");
}

fn runTemplate(t: Tpl) void {
    dialogs.close();
    if (t.key.len == 0) {
        // the scene it starts with; with changes, as File > New
        if (files.changed()) files.guarded(.new, "");
        return;
    }
    const old = ops.arg;
    defer ops.arg = old;
    ops.arg = t.key;
    ops.runId2("help.template");
}

fn kmValue() usize {
    return @as(usize, keys.preset) * 2 + @intFromBool(prefs.emulate_middle);
}
fn kmPick(k: usize) void {
    keys.usePreset(@intCast(k / 2));
    prefs.emulate_middle = k % 2 == 1;
    prefs.save();
}

const km_items = [_]zui.Choice{
    .{ .label = km_labels[0] },
    .{ .label = km_labels[1] },
    .{ .label = km_labels[2] },
    .{ .label = km_labels[3] },
};

fn heading(z: *zui.Ui, s: []const u8) void {
    z.pushFont(host.headFont());
    z.label(s, .{ .color = host.col(ui.th.accent) });
    z.popFont();
}

/// A template's card; true when picked.
fn card(z: *zui.Ui, t: Tpl) bool {
    const c = z.card(t.label, .{ .width = 124, .picture_height = 58, .icon = host.icon(t.icon), .disabled = t.why });
    z.tooltipRich(c, .{ .title = t.label, .body = t.tip, .warning = t.why orelse "" });
    return c.clicked;
}

var wl_open = true;

/// The welcome screen (help.s): Start (cards) | Recent | Samples, the
/// keymap, "Show this at start". A Zui dialog of the dialogs' client.
pub fn describe(z: *zui.Ui) void {
    const th = ui.th;
    wl_open = true;
    if (!z.beginDialog("Welcome to BeeModel", &wl_open, .{ .min_width = 700 })) return;
    defer z.endDialog();
    defer if (!wl_open) dialogs.close();
    z.label("A 3D modeler, CAD and renderer in one small program.", .{ .color = host.col(th.text_dim) });
    z.spacer(.px(6));
    heading(z, "Start");
    z.beginHorizontal(.{ .spacing = 8 });
    for (start) |t| if (card(z, t)) {
        z.endHorizontal();
        runTemplate(t);
        return;
    };
    z.endHorizontal();
    z.spacer(.px(6));
    z.beginHorizontal(.{ .spacing = 24, .alignment = .start });
    {
        // the recent files, Open...
        z.beginVertical(.{ .width = .px(300), .spacing = 2 });
        heading(z, "Recent");
        const nr = prefs.recentCount();
        if (nr == 0) z.label("Nothing opened yet.", .{ .color = host.col(th.text_dim) });
        for (0..nr) |k| {
            const p = prefs.recent_files[k][0..prefs.recent_files_len[k]];
            const nm = p[if (std.mem.lastIndexOfScalar(u8, p, '/')) |c| c + 1 else 0..];
            z.pushIdInt(k);
            const b = z.button(nm, .{ .width = .fill, .alignment = .start, .variant = .flat, .icon = host.icon(.file) });
            z.popId();
            z.tooltipRich(b, .{ .title = nm, .body = p });
            if (b.clicked) {
                z.endVertical();
                z.endHorizontal();
                dialogs.close();
                files.guarded(.recent, p);
                return;
            }
        }
        z.spacer(.px(4));
        if (z.button("Open...", .{ .icon = host.icon(.folder_open) }).clicked) {
            z.endVertical();
            z.endHorizontal();
            dialogs.close();
            ops.runId("file.open");
            return;
        }
        z.endVertical();
    }
    {
        // samples, the keymap
        z.beginVertical(.{ .spacing = 6 });
        heading(z, "Samples");
        z.beginHorizontal(.{ .spacing = 8 });
        for (samples) |t| if (card(z, t)) {
            z.endHorizontal();
            z.endVertical();
            z.endHorizontal();
            runTemplate(t);
            return;
        };
        z.endHorizontal();
        var km = kmValue();
        const d = z.dropdown("##keymap", &km, &km_items, .{ .width = .px(256) });
        z.tooltipRich(d, .{ .title = "Keymap", .body = "BeeModel's keys or Blender's, each also for a laptop" });
        if (d.changed) kmPick(km);
        z.endVertical();
    }
    z.endHorizontal();
    z.spacer(.px(8));
    // the bottom row: Show at start, Close
    z.beginHorizontal(.{ .width = .fill });
    if (z.checkbox("Show this at start", &prefs.welcome, .{}).changed) prefs.save();
    z.spacer(.fill);
    const cb = z.button("Close", .{ .width = .px(88) });
    z.tooltipRich(cb, .{ .title = "Close", .shortcut = "Esc" });
    z.endHorizontal();
    if (cb.clicked) dialogs.close();
}

// --- quick actions in an empty scene (vp_quick_draw) --------------------------------

const qa = [_]struct { label: []const u8, id: []const u8, primary: bool = false }{
    .{ .label = "Add a Cube", .id = "create.cube", .primary = true },
    .{ .label = "Start a Sketch...", .id = "cad.sketch" },
    .{ .label = "Open...", .id = "file.open" },
    .{ .label = "Import OBJ...", .id = "file.import_obj" },
    .{ .label = "Templates and Samples...", .id = "help.welcome" },
};

/// In the middle of a viewport, when the scene holds nothing: a Zui part.
pub fn quick(salt: usize, r: Rect) void {
    if (scene.count != 0 or r.w < 240 or r.h < 240) return;
    const th = ui.th;
    const x = r.x + @divTrunc(r.w, 2) - 130;
    const y = r.y + @divTrunc(r.h, 2) - 110;
    const z = host.beginPart("quick", salt, .{ .x = x, .y = y, .w = 260, .h = 220 }) orelse return;
    defer host.endPart(z);
    z.pushMetric(.item_spacing, .{ .x = 6, .y = 6 });
    defer z.popStyle();
    heading(z, "This scene is empty.");
    z.label("Add something, or open a scene.", .{ .color = host.col(th.text_dim) });
    z.spacer(.px(2));
    for (qa) |q| {
        const oi = ops.byId(q.id) orelse continue;
        const why = ops.reason(oi);
        z.pushDisabled(why);
        const b = z.button(q.label, .{ .width = .fill, .variant = if (q.primary) .selected else .normal });
        z.popDisabled();
        z.tooltipRich(b, .{ .title = q.label, .body = @import("catalog.zig").entries[oi].doc, .warning = why orelse "" });
        if (b.clicked) {
            ops.run(oi);
            return;
        }
    }
}
