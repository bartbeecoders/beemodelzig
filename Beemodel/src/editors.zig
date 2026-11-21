// The editors that live in areas: 3D Viewport, Tools, Outliner, Properties,
// Console and Timeline. Each draws into its area's body (and header) in
// both UI passes.
/// The original's COL_ACTIVE: tool lines in the viewport.
const COL_ACTIVE: u32 = 0xffc24a;
const std = @import("std");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const m = @import("math.zig");
const scene = @import("scene.zig");
const theme = @import("theme.zig");
const vp = @import("viewport.zig");
const ops = @import("ops.zig");
const cat = @import("catalog.zig");
const menus = @import("menus.zig");
const undo = @import("undo.zig");
const xform = @import("xform.zig");
const app = @import("app.zig");
const expr = @import("expr.zig");
const em = @import("editmesh.zig");
const frange = @import("frange.zig");
const zui = @import("zui");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");

const Rect = gfx.Rect;
const Icon = gfx.Icon;
const HDR_H = app.HDR_H;
const ROW = 20; // list rows, as the original's ROW_H

pub fn bodyRect(r: Rect) Rect {
    return .{ .x = r.x, .y = r.y + HDR_H, .w = r.w, .h = r.h - HDR_H };
}

// --- small widgets shared by the editors -------------------------------------

/// A catalog operator as a Zui icon button in a header part, square, `h`
/// high: lit while the operator's state is on, greyed with the reason when
/// it can't run; recorded as "icon:<label>" (as opIcon).
pub fn zOpIcon(z: *zui.Ui, icon: Icon, id: []const u8, area: i16, h: f32) void {
    zOpIconW(z, icon, id, area, h + 2, h);
}

/// `zOpIcon`, `w` wide.
pub fn zOpIconW(z: *zui.Ui, icon: Icon, id: []const u8, area: i16, w: f32, h: f32) void {
    const th = ui.th;
    const oi = ops.byId(id) orelse return;
    const e = &cat.entries[oi];
    const why = ops.reason(oi);
    const on = ops.checked(oi) orelse false;
    z.pushIdInt(oi);
    defer z.popId();
    if (on) {
        z.pushColor(.button, host.col(th.accent_dark));
        z.pushColor(.text, host.col(th.accent_fg));
    }
    z.pushDisabled(why);
    const b = z.button("##op", .{ .icon = host.icon(icon), .width = .px(w), .height = .px(h), .variant = if (on) .normal else .flat });
    z.popDisabled();
    if (on) z.popStyles(2);
    ui.record("icon", e.label, host.rectOf(b.rect), why == null);
    var kb: [32]u8 = undefined;
    z.tooltipRich(b, .{ .title = e.label, .shortcut = ops.keyLabel(oi, &kb), .body = e.doc, .warning = why orelse "" });
    if (b.clicked and why == null) {
        if (area >= 0) app.setActiveArea(area);
        ops.run(oi);
    }
}

/// A header button (Zui) that opens a menu: below it as it is pressed, or
/// (at_pointer: as the original's View / Select / Object buttons) where
/// the click is let go, as a context menu (ctx_open_list).
fn zMenuButton(z: *zui.Ui, label: []const u8, items: []const cat.Item, area: i16, w: f32, h: f32, chevron: bool, tip: []const u8, at_pointer: bool) void {
    const th = ui.th;
    const open = menus.cur != null and menus.cur.?.lv[0].items.ptr == items.ptr and menus.cur.?.area == area;
    z.pushIdInt(@intFromPtr(items.ptr));
    defer z.popId();
    if (open) z.pushColor(.button, host.col(th.hover));
    const b = z.button(label, .{ .width = .px(w), .height = .px(h), .alignment = if (chevron) .start else .center });
    if (open) z.popStyle();
    if (chevron) z.painter().icon(.{ .builtin = .chevron_down }, .{ .x = b.rect.right() - 17, .y = b.rect.y + (h - 12) / 2, .w = 12, .h = 12 }, host.col(th.text_dim));
    ui.record("button", label, host.rectOf(b.rect), true);
    if (tip.len > 0) z.tooltipRich(b, .{ .title = label, .body = tip });
    if (at_pointer) {
        if (b.clicked) zOpenAtRelease(z, items, area);
    } else if (b.pressed) {
        app.setActiveArea(area);
        menus.openAt(items, @intFromFloat(b.rect.x), @intFromFloat(b.rect.bottom() + 2), area);
    }
}

fn zOpenAtRelease(z: *zui.Ui, items: []const cat.Item, area: i16) void {
    const at = z.input.release_pos.get(.left);
    app.setActiveArea(area);
    menus.openAt(items, @intFromFloat(at.x), @intFromFloat(at.y), area);
}

/// An icon (Zui) that opens a menu where the click is let go.
fn zMenuIcon(z: *zui.Ui, icon: Icon, items: []const cat.Item, area: i16, w: f32, h: f32, title: []const u8, tip: []const u8) void {
    z.pushIdInt(@intFromPtr(items.ptr));
    defer z.popId();
    const b = z.button("##menu", .{ .icon = host.icon(icon), .width = .px(w), .height = .px(h), .variant = .flat });
    ui.record("icon", title, host.rectOf(b.rect), true);
    z.tooltipRich(b, .{ .title = title, .body = tip });
    if (b.clicked) zOpenAtRelease(z, items, area);
}

const mode_items = [_]cat.Item{ .{ .op = "op_mode_object" }, .{ .op = "op_mode_edit" }, .{ .op = "op_mode_sculpt" }, .sep, .{ .op = "op_mode_vcol" }, .{ .op = "op_mode_wgt" }, .{ .op = "op_mode_tex" } };
const pivot_items = [_]cat.Item{ .{ .op = "op_pv_med" }, .{ .op = "op_pv_cur" }, .{ .op = "op_pv_ind" }, .{ .op = "op_pv_act" }, .sep, .{ .op = "op_or_glob" }, .{ .op = "op_or_loc" }, .{ .op = "op_or_view" }, .{ .op = "op_or_nrm" } };
const overlay_items = [_]cat.Item{ .{ .op = "op_view_grid" }, .{ .op = "op_ov_text" }, .{ .op = "op_ov_stats" }, .{ .op = "op_ov_gizmo" }, .sep, .{ .op = "op_an_normals" }, .{ .op = "op_an_bound" }, .{ .op = "op_an_nonman" }, .{ .op = "op_an_degen" } };

/// Editor-specific widgets in the area header, in `r` (between the editor
/// menu and the area buttons). Items are dropped from the right when the
/// area is narrow.
pub fn header(i: i16, r: Rect) void {
    const n = app.N(i);
    switch (n.editor) {
        .viewport => vpHeader(i, r),
        .timeline => if (r.w > 100) @import("animed.zig").timelineHeader(i, r),
        .dopesheet, .graph => if (r.w > 100) @import("animed.zig").keysHeader(i, r),
        .render => @import("render.zig").header(i, r),
        .uved => @import("uved.zig").header(i, r),
        .nodes => @import("nodeed.zig").header(i, r),
        .assets => @import("libui.zig").header(i, r),
        .activity => @import("agent.zig").header(i, r),
        else => {},
    }
}

/// The 3D Viewport's header (Zui): the mode, the View / Select / Object
/// (Mesh) menus, the select modes in edit mode, the shading, grid, snap,
/// pivot and overlays, at the original's places; items are dropped from the
/// right when the area is narrow.
fn vpHeader(i: i16, r: Rect) void {
    const h: f32 = HDR_H - 4;
    const z = host.beginPart("vp.head", @intCast(i), .{ .x = r.x, .y = r.y + 2, .w = r.w, .h = HDR_H - 4 }) orelse return;
    defer host.endPart(z);
    z.beginHorizontal(.{ .spacing = 0 });
    defer z.endHorizontal();
    var x = r.x;
    const room = r.right();
    const mode_label = if (em.active) "Edit Mode" else if (sculpt.on) "Sculpt Mode" else if (paint.on) paintui.modeName() else "Object Mode";
    const mw = 130; // fixed, as the original's mode button
    if (x + mw > room) return;
    zMenuButton(z, mode_label, &mode_items, i, mw, h, true, "The mode: object, edit, sculpt or paint (Tab, Ctrl+Tab)", false);
    z.spacer(.px(6));
    x += mw + 6;
    const hm = [_]struct { l: []const u8, items: []const cat.Item }{ .{ .l = "View", .items = cat.bar[2] }, .{ .l = "Select", .items = cat.bar[3] }, if (em.active) .{ .l = "Mesh", .items = cat.bar[6] } else .{ .l = "Object", .items = cat.bar[5] } };
    // the original's widths (hdr_btn): 50 / 56 / 60, 4 apart
    const mws = [_]i32{ 50, 56, 60 };
    for (hm, 0..) |mm, k| {
        const w = @max(mws[k], gfx.textWidth(mm.l) + 12);
        if (x + w > room) return;
        zMenuButton(z, mm.l, mm.items, i, @floatFromInt(w), h, false, "", true);
        z.spacer(.px(4));
        x += w + 4;
    }
    z.spacer(.px(8));
    x += 8;
    if (em.active) {
        // vertex / edge / face select (after the menus, as the original)
        if (x + 3 * 26 + 10 > room) return;
        // ICON_DOT / MINUS / STOP, 24 wide at a 26 pitch (vpnav.s)
        const sm = [_]struct { ic: Icon, id: []const u8 }{ .{ .ic = .dot, .id = "mesh.select_mode_vertex" }, .{ .ic = .minus, .id = "mesh.select_mode_edge" }, .{ .ic = .stop, .id = "mesh.select_mode_face" } };
        for (sm) |sx| {
            zOpIconW(z, sx.ic, sx.id, i, 24, h);
            z.spacer(.px(2));
            x += 26;
        }
        z.spacer(.px(10));
        x += 10;
    }
    const shade = [_]struct { ic: Icon, id: []const u8 }{
        .{ .ic = .wire, .id = "view.shading_wireframe" },   .{ .ic = .solid, .id = "view.shading_solid" },
        .{ .ic = .material, .id = "view.shading_material" }, .{ .ic = .rendered, .id = "view.shading_rendered" },
    };
    if (x + 4 * 22 > room) return;
    for (shade) |sh| zOpIconW(z, sh.ic, sh.id, i, 22, h);
    z.spacer(.px(10));
    x += 4 * 22 + 10;
    if (x + 4 * 22 > room) return;
    zOpIconW(z, .grid, "view.toggle_grid", i, 22, h);
    zOpIconW(z, .snap, "view.toggle_snap", i, 22, h);
    zMenuIcon(z, .pivot, &pivot_items, i, 22, h, "Pivot and Orientation", "What turning and scaling go around, and what X, Y and Z mean while moving");
    zMenuIcon(z, .overlays, &overlay_items, i, 22, h, "Overlays", "The ground grid, the text in the corner, the statistics, the gizmo and the mesh checks");
}

pub fn body(i: i16, r: Rect) void {
    switch (app.N(i).editor) {
        .viewport => edViewport(i, r),
        .tools => edTools(i, r),
        .outliner => edOutliner(i, r),
        .properties => edProperties(i, r),
        .console => edConsole(i, r),
        .timeline => @import("animed.zig").timeline(i, r),
        .dopesheet => @import("animed.zig").dopeSheet(i, r),
        .graph => @import("animed.zig").graphEditor(i, r),
        .render => @import("render.zig").body(i, r),
        .uved => @import("uved.zig").body(i, r),
        .nodes => @import("nodeed.zig").body(i, r),
        .help => @import("helped.zig").body(r),
        .assets => @import("libui.zig").body(i, r),
        .activity => @import("agent.zig").body(i, r),
        .ai => @import("ai.zig").body(i, r),
        .versions => @import("versions.zig").body(i, r),
        .prefs => dialogs.areaBody(r),
        .other => {
            ui.cv.fill(r, ui.th.pane_bg);
            var b: [80]u8 = undefined;
            ui.cv.textCentered(r, std.fmt.bufPrint(&b, "{s}: {s}", .{ @import("wsfile.zig").otherLabel(app.N(i).raw_ed), ops.not_ported }) catch "", ui.th.text_off);
        },
    }
}

// --- 3D viewport ------------------------------------------------------------------

var drag_obj: ?usize = null;
var box_on = false;
var press_pick: ?usize = null;

fn clickSelect(p: ?usize) void {
    if (ui.shift()) {
        if (p) |o| scene.toggleSel(o);
    } else if (p) |o| {
        scene.selectOnly(o);
    } else scene.deselectAll();
    @import("bscript.zig").macroSelect(); // (recording a macro: select("A", "B"))
}

/// The object under the pointer that clicks may pick (locked ones pass through).
fn pickable(cv: *gfx.Canvas, v: *const vp.View, r: Rect) ?usize {
    const p = vp.pick(cv, v, r, ui.mx, ui.my) orelse return null;
    return if (scene.objects[p].locked) null else p;
}

fn orbit(v: *vp.View, dx: i32, dy: i32, k0: f32) void {
    const k = k0 * @import("prefs.zig").orbit_speed;
    vp.leaveCamView(v);
    v.gliding = false;
    if (v.auto_ortho) {
        // out of an axis view: perspective again
        v.ortho = false;
        v.auto_ortho = false;
    }
    v.yaw -= @as(f32, @floatFromInt(dx)) * k;
    v.pitch = std.math.clamp(v.pitch + @as(f32, @floatFromInt(dy)) * k, -89.9, 89.9);
}

fn pan(v: *vp.View, r: Rect, dx: i32, dy: i32) void {
    vp.leaveCamView(v);
    v.gliding = false;
    const c = vp.Cam.init(v, r);
    const k = c.pixelSize(v.target) / (if (v.ortho) @as(f32, 1) else 1);
    v.target = m.add(v.target, m.add(m.scale(c.right, -@as(f32, @floatFromInt(dx)) * k), m.scale(c.up, @as(f32, @floatFromInt(dy)) * k)));
}

fn zoom(v: *vp.View, steps: f32) void {
    vp.leaveCamView(v);
    v.gliding = false;
    v.dist = std.math.clamp(v.dist * std.math.pow(f32, 1.12, steps), 0.5, 500.0);
}

const sculpt = @import("sculpt.zig");
const sculptui = @import("sculptui.zig");
const paint = @import("paint.zig");
const paintui = @import("paintui.zig");

/// The 3D Viewport (a Zui part over the area's body). The panels over the
/// view come first, so a press on one is theirs (they are drawn with the
/// part, over the view); then the pointer's events of the frame, in order
/// (`viewInput`); then the view, rendered into BeeModel's canvas in place;
/// then what is drawn over it.
fn edViewport(i: i16, r: Rect) void {
    const n = app.N(i);
    // Camera View without a camera (deleted, undone): back to the free view
    if (n.view.cam_view and vp.sceneCamera() == null) {
        n.view.cam_view = false;
        n.view.setPose(n.view.before_cam);
    }
    const cv = ui.cv;
    const th = ui.th;
    const z_ = host.beginPart("viewport", @intCast(i), r);
    defer if (z_) |z| host.endPart(z);
    const mark = host.claimMark();
    @import("welcome.zig").quick(@intCast(i), r);
    @import("copilot.zig").banner(@intCast(i), r); // an AI proposal: Accept / Revert (cp_draw, cp_click)
    @import("redo.zig").draw(i, r); // the last tool's values
    sculptui.bar(i, r);
    paintui.bar(i, r);
    const z = z_ orelse return;
    // files dropped from the system on the view: they open where they land
    if (z.fileDrop(host.zr(r))) |_| {
        const p = z.input.drop_pos;
        @import("drop.zig").take(.{ .area = i, .x = @intFromFloat(p.x), .y = @intFromFloat(p.y) });
    }
    @import("vc.zig").panel(z, @intCast(i), r); // the merge panel's ours / theirs (vc_press)
    if (n.view.show_gizmo) navButtons(z, i, r);
    viewInput(z, i, r, mark);

    vp.draw_area = i;
    vp.render(cv, r, &n.view, th);
    @import("sketchui.zig").overlay(i, &n.view, r); // sketch mode: points, labels, tools
    if (xform.active and xform.node == i) xform.draw(cv, &n.view, r, th);
    const ms = @import("measure.zig");
    if (ms.on) ms.draw(cv, &n.view, r);
    const kn = @import("meshops2.zig");
    if (em.active and kn.kn_active) {
        const col: u32 = 0xf5e020;
        var k: usize = 0;
        while (k + 1 < kn.kn_n) : (k += 1) {
            cv.line(@intFromFloat(kn.kn_pts[k][0]), @intFromFloat(kn.kn_pts[k][1]), @intFromFloat(kn.kn_pts[k + 1][0]), @intFromFloat(kn.kn_pts[k + 1][1]), col);
        }
        if (kn.kn_n > 0 and r.contains(ui.mx, ui.my)) cv.line(@intFromFloat(kn.kn_pts[kn.kn_n - 1][0]), @intFromFloat(kn.kn_pts[kn.kn_n - 1][1]), ui.mx, ui.my, 0x8a8030);
    }
    if (em.active and kn.lc_active) {
        var lines: std.ArrayList([2]m.V3) = .empty;
        defer lines.deinit(@import("alloc.zig").A);
        kn.lcPreview(&lines);
        const c = vp.Cam.init(&n.view, r);
        for (lines.items) |ln| vp.line3(cv, &c, ln[0], ln[1], 0xf5e020);
    }
    if (vin.held == ui.LMB and vin.area == i and vin.mode == .edit and box_on and vin.moved) {
        const bx = Rect{ .x = @min(vin.px, ui.mx), .y = @min(vin.py, ui.my), .w = @intCast(@abs(ui.mx - vin.px)), .h = @intCast(@abs(ui.my - vin.py)) };
        // both corners inclusive, as the original
        cv.rectLine(.{ .x = bx.x, .y = bx.y, .w = bx.w + 1, .h = bx.h + 1 }, th.text);
    }
    @import("analysis.zig").legend(r);
    sculptui.overlay(r); // the brush
    paintui.overlay(r);
    hud(z, i, r);
    if (r.contains(ui.mx, ui.my) or vin.area == i) host.cursorFrom(z, viewCursor(i, r));
}

/// The text in the view's top-left corner (Zui's, over the view): what the
/// view looks through, the live render's line, the statistics, the mode's
/// or the selection's line, a mesh tool's line.
fn hud(z: *zui.Ui, i: i16, r: Rect) void {
    const n = app.N(i);
    const th = ui.th;
    const kn = @import("meshops2.zig");
    var buf: [128]u8 = undefined;
    var sb: [160]u8 = undefined;
    if (@import("sketchui.zig").status(&sb)) |ln| {
        hudText(z, r.x + 10, r.y + 48, r.w - 20, ln[0], th.accent, false);
        ui.record("info", ln[0], .{ .x = r.x + 10, .y = r.y + 48, .w = 300, .h = 18 }, true);
        hudText(z, r.x + 10, r.y + 66, r.w - 20, ln[1], th.text_dim, false);
    }
    if (@import("measure.zig").on) {
        var mb: [160]u8 = undefined;
        hudText(z, r.x + 10, r.y + 62, r.w - 20, @import("measure.zig").hint(&mb), COL_ACTIVE, false);
    }
    if (em.active and kn.kn_active) hudText(z, r.x + 10, r.y + 62, r.w - 20, "Knife: click points across faces, Enter cuts, Esc cancels", COL_ACTIVE, false);
    if (em.active and kn.lc_active) hudText(z, r.x + 10, r.y + 62, r.w - 20, std.fmt.bufPrint(&buf, "Loop Cut: hover an edge, wheel = number of cuts ({d}), click to cut, Esc cancels", .{kn.lc_cuts}) catch "", COL_ACTIVE, false);
    if (!n.view.show_text) return;
    const shadow = n.view.rendered and !n.view.wire; // (over a render: a shadow under it, as the original's)
    const what = if (n.view.cam_view and vp.sceneCamera() != null) scene.objects[vp.sceneCamera().?].name() else if (n.view.pitch > 89) "Top" else if (n.view.pitch < -89) "Bottom" else if (n.view.ortho) "Orthographic" else "Perspective";
    hudText(z, r.x + 10, r.y + 8, r.w - 20, std.fmt.bufPrint(&buf, "{s}{s}  |  Grid 1 m", .{ if (n.view.cam_view) "Camera: " else "", what }) catch "", th.text, shadow);
    var ty = r.y + 26;
    if (shadow) {
        var lb: [64]u8 = undefined;
        const ln = @import("live.zig").hudLine(&lb, i);
        hudText(z, r.x + 10, ty, r.w - 20, ln, th.text, true);
        ui.record("info", ln, .{ .x = r.x + 10, .y = ty, .w = 300, .h = 18 }, true);
        ty += 18;
    }
    if (n.view.show_stats) {
        hudText(z, r.x + 10, ty, r.w - 20, std.fmt.bufPrint(&buf, "{d} objects  {d} faces", .{ scene.count, scene.faceCount() }) catch "", th.text_dim, false);
        ty += 18;
    }
    if (em.active) {
        // the original's edit-mode line (edit.s s_lbl_v / e / f) at +44, a tool's line under it
        const t = switch (em.sel_mode) {
            .vertex => "Edit Mode  |  Vertex  (1 2 3, A all, B box, Alt+click loop, Ctrl+L linked, Tab exit)",
            .edge => "Edit Mode  |  Edge  (1 2 3, A all, B box, Alt+click loop, Ctrl+L linked, Tab exit)",
            .face => "Edit Mode  |  Face  (1 2 3, A all, B box, Alt+click loop, Ctrl+L linked, Tab exit)",
        };
        // (clear of the navigation gizmo on the right)
        const room = r.w - 20 - (if (n.view.show_gizmo) @as(i32, vp.gizmo_r * 2 + 30) else 0);
        hudText(z, r.x + 10, r.y + 44, room, t, th.accent_fg, false);
        const mo = @import("meshops.zig");
        if (xform.active and xform.node == i) {
            hudText(z, r.x + 10, r.y + 62, room, xform.describe(&buf), COL_ACTIVE, false);
        } else if (mo.modal != null) {
            hudText(z, r.x + 10, r.y + 62, room, mo.describe(&buf), COL_ACTIVE, false);
        }
    } else if (xform.active and xform.node == i) {
        hudText(z, r.x + 10, ty, r.w - 20, xform.describe(&buf), th.accent_fg, false);
    } else if (sculpt.on or paint.on or @import("sketchui.zig").on()) {
        // (the mode's own lines say what is going on)
    } else if (scene.active) |sel| {
        const ns = scene.nSelected();
        const t = if (ns > 1) std.fmt.bufPrint(&buf, "{s}  (+{d} selected)", .{ scene.objects[sel].name(), ns - 1 }) catch "" else scene.objects[sel].name();
        hudText(z, r.x + 10, ty, r.w - 20, t, th.accent_fg, false);
    }
}

/// A line of the corner text, `w` at most, with a shadow under it over a render.
fn hudText(z: *zui.Ui, x: i32, y: i32, w: i32, s: []const u8, col: u32, shadow: bool) void {
    if (s.len == 0 or w <= 0) return;
    z.pushClip(host.zr(.{ .x = x, .y = y - 2, .w = w, .h = 22 }));
    defer z.popClip();
    if (shadow) z.drawText(.{ .x = @floatFromInt(x + 1), .y = @floatFromInt(y + 1) }, host.col(0), s);
    z.drawText(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, host.col(col), s);
}

/// The buttons under the navigation gizmo (Zui's, before the view takes
/// the pointer): zoom and pan (drag them), orthographic and camera view.
fn navButtons(z: *zui.Ui, i: i16, r: Rect) void {
    const n = app.N(i);
    const th = ui.th;
    const c = vp.gizmoCenter(r);
    const icons_ = [_]Icon{ .search, .move, .grid, .camera };
    const tips = [_][2][]const u8{
        .{ "Zoom", "Drag up or down to zoom" },                               .{ "Pan", "Drag to move the view" },
        .{ "Orthographic", "Switch perspective / orthographic (Numpad 5)" }, .{ "Camera View", "Look through the scene's camera (Numpad 0)" },
    };
    z.pushIdInt(@intCast(i));
    defer z.popId();
    for (0..4) |k| {
        const b = Rect{ .x = c[0] - 11, .y = c[1] + vp.gizmo_r + 8 + @as(i32, @intCast(k)) * 26, .w = 22, .h = 22 };
        z.pushIdInt(k);
        const it = z.interact(z.id("##nav"), host.zr(b));
        z.popId();
        const on = (k == 2 and n.view.ortho) or (k == 3 and n.view.cam_view);
        ui.record("icon", tips[k][0], b, true);
        if (on) {
            z.drawRect(.{ .rect = host.zr(b), .fill = host.col(th.accent_dark), .radius = 4 });
        } else if (it.hovered or it.held) {
            z.painter().circle(.{ .x = @as(f32, @floatFromInt(b.x)) + 11, .y = @as(f32, @floatFromInt(b.y)) + 11 }, 11, host.col(gfx.mix(th.canvas_top, 0x000000, 70)));
        }
        z.painter().icon(host.icon(icons_[k]), host.zr(.{ .x = b.x + 3, .y = b.y + 3, .w = 16, .h = 16 }), host.col(if (on) th.accent_fg else th.text));
        z.tooltipRich(it, .{ .title = tips[k][0], .body = tips[k][1] });
        if (it.pressed) {
            app.setActiveArea(i);
            if (k == 2) ops.runId("view.toggle_ortho");
            if (k == 3) ops.runId("view.camera");
        }
        if (it.held and k < 2) {
            const d = z.mouse_delta;
            const dx: i32 = @intFromFloat(d.x);
            const dy: i32 = @intFromFloat(d.y);
            if (dx != 0 or dy != 0) {
                if (k == 0) zoom(&n.view, @as(f32, @floatFromInt(dy)) * 0.05) else pan(&n.view, r, -dx, -dy);
                app.dirty = true;
            }
            z.cursor = if (k == 0) .resize_ns else .move;
        }
    }
}

/// What the view does with a held button.
const Mode = enum { none, gizmo, sketch, edit, object, pan };

/// The button the view holds (BeeModel's bit: LMB, MMB, RMB) and its drag:
/// one at a time, as BeeModel's own widgets.
const VpIn = struct {
    held: u8 = 0,
    area: i16 = -1,
    mode: Mode = .none,
    /// Where it was pressed, and the last place seen.
    px: i32 = 0,
    py: i32 = 0,
    lx: i32 = 0,
    ly: i32 = 0,
    /// Moved more than 3 px from the press: a drag, not a click.
    moved: bool = false,
    /// The left button standing in for the middle one (Preferences > Input).
    emulated: bool = false,
};
var vin: VpIn = .{};

fn modsOf(md: zui.Modifiers) u32 {
    const wl = @import("wayland.zig");
    var v: u32 = 0;
    if (md.shift) v |= wl.MOD_SHIFT;
    if (md.ctrl) v |= wl.MOD_CTRL;
    if (md.alt) v |= wl.MOD_ALT;
    return v;
}

/// The pointer's events of this frame over the view, in the order they
/// came (Zui's log): a quick click, a whole drag or a stroke between two
/// frames is handled as BeeModel handled each event. A press on a panel
/// over the view (claimed since `mark`) or on something of Zui's in front
/// is not the view's.
fn viewInput(z: *zui.Ui, i: i16, r: Rect, mark: usize) void {
    const in = &z.input;
    // (a dialog, a menu or a popup of Zui's in front, described after the
    // view: a press on it is theirs, so the view does not take its turn)
    if (vin.held == 0 or vin.area != i) {
        if (host.modalOpen()) return;
        const pp = in.press_pos.get(.left);
        if (in.mouse_pressed.contains(.left) and host.inFront(@intFromFloat(pp.x), @intFromFloat(pp.y))) return;
    }
    const c = z.beginCanvas("##view", .{ .rect = host.zr(r), .take_wheel = false });
    z.endCanvas();
    const n = app.N(i);
    const v = &n.view;
    if (n.view.show_gizmo) {
        const gc = vp.gizmoCenter(r);
        const grect = Rect{ .x = gc[0] - vp.gizmo_r, .y = gc[1] - vp.gizmo_r, .w = vp.gizmo_r * 2, .h = vp.gizmo_r * 2 };
        z.tooltipRich(.{ .id = c.id, .rect = host.zr(grect), .hovered = c.hovered and vp.inGizmo(r, ui.mx, ui.my) }, .{ .title = "Navigation Gizmo", .body = "Click a ball to look along that axis, drag to orbit (Numpad 1 / 3 / 7, Ctrl: the other side)" });
    }
    const keep_mx = ui.mx;
    const keep_my = ui.my;
    const keep_mods = ui.mods;
    defer {
        ui.mx = keep_mx;
        ui.my = keep_my;
        ui.mods = keep_mods;
    }
    const wl = @import("wayland.zig");
    // (presses, releases and wheel turns that were not the view's: something
    // else of Zui's may act on them after the view was drawn)
    var others: usize = 0;
    for (in.pointerEvents()) |ev| {
        const x: i32 = @intFromFloat(ev.pos.x);
        const y: i32 = @intFromFloat(ev.pos.y);
        ui.mx = x;
        ui.my = y;
        ui.mods = modsOf(ev.modifiers);
        switch (ev.kind) {
            .move => if (vin.held != 0 and vin.area == i) {
                var dx = x - vin.lx;
                var dy = y - vin.ly;
                if (!vin.moved and (@abs(x - vin.px) > 3 or @abs(y - vin.py) > 3)) {
                    vin.moved = true;
                    dx = x - vin.px;
                    dy = y - vin.py;
                }
                vin.lx = x;
                vin.ly = y;
                viewDragged(i, r, v, x, y, dx, dy, ev.pressure);
            },
            .press => {
                others += 1;
                if (vin.held != 0) continue;
                var bit: u8 = switch (ev.button) {
                    .left => ui.LMB,
                    .middle => ui.MMB,
                    .right => ui.RMB,
                };
                const emulated = bit == ui.LMB and @import("prefs.zig").emulate_middle and ev.modifiers.alt;
                if (emulated) bit = ui.MMB;
                // (Zui's: nothing of Zui's in front took it; then not on a panel)
                const zui_ok = switch (ev.button) {
                    .left => c.interaction.pressed or c.interaction.held,
                    .middle => c.middle_pressed,
                    .right => c.right_pressed,
                };
                if (!zui_ok or !r.contains(x, y) or host.claimedSince(mark, x, y) or host.inFront(x, y)) continue;
                others -= 1;
                vin = .{ .held = bit, .area = i, .px = x, .py = y, .lx = x, .ly = y, .emulated = emulated };
                viewPressed(i, r, v, bit, x, y);
                app.dirty = true;
            },
            .release => {
                const bit: u8 = switch (ev.button) {
                    .left => if (vin.emulated) ui.MMB else ui.LMB,
                    .middle => ui.MMB,
                    .right => ui.RMB,
                };
                if (vin.held != bit or vin.area != i) {
                    others += 1;
                    continue;
                }
                vin.lx = x;
                vin.ly = y;
                viewReleased(i, r, v, x, y);
                vin.held = 0;
                vin.mode = .none;
                app.dirty = true;
            },
            .scroll => {
                if (vin.held != 0 or !r.contains(x, y) or host.claimedSince(mark, x, y) or ev.scroll.y == 0 or
                    host.inFront(x, y) or (z.active != .none and z.active != c.id))
                {
                    others += 1;
                    continue;
                }
                wheel(v, -ev.scroll.y);
                app.dirty = true;
            },
        }
    }
    // (let go where no event of it came through: the button is up)
    if (vin.held != 0 and vin.area == i) {
        const b: zui.MouseButton = if (vin.held == ui.LMB or vin.emulated) .left else if (vin.held == ui.MMB) .middle else .right;
        if (!in.mouse_down.contains(b)) {
            viewReleased(i, r, v, vin.lx, vin.ly);
            vin.held = 0;
            vin.mode = .none;
        }
    }
    _ = wl;
    if (others == 0 and in.pointerEvents().len > 0 and (c.hovered or (vin.held != 0 and vin.area == i)) and (z.active == .none or z.active == c.id)) host.viewTookAll();
    // the pointer over the view, nothing held: what is under it (a sketch's
    // point, the loop cut's ring)
    if (vin.held == 0 and c.hovered and r.contains(keep_mx, keep_my) and !host.claimedSince(mark, keep_mx, keep_my) and !host.inFront(keep_mx, keep_my)) {
        const kn = @import("meshops2.zig");
        if (@import("sketchui.zig").on()) @import("sketchui.zig").hover(keep_mx, keep_my, i);
        if (em.active and kn.lc_active) kn.lcHover(ui.cv, v, r, keep_mx, keep_my);
    }
}

/// A press the view takes (bit: LMB, MMB, RMB), at (x, y).
fn viewPressed(i: i16, r: Rect, v: *vp.View, bit: u8, x: i32, y: i32) void {
    const cv = ui.cv;
    const ms = @import("measure.zig");
    const kn = @import("meshops2.zig");
    const su = @import("sketchui.zig");
    // the measure tool: clicks add points, a right click ends
    if (ms.on) {
        if (bit == ui.LMB) {
            app.setActiveArea(i);
            ms.press(cv, v, r, x, y);
        } else if (bit == ui.RMB) ms.cancel();
        return;
    }
    // knife: clicks add points, Enter cuts
    if (em.active and kn.kn_active) {
        if (bit == ui.LMB) kn.knAdd(x, y) else if (bit == ui.RMB) kn.kn_active = false;
        return;
    }
    // loop cut: a click cuts at the ring under the pointer
    if (em.active and kn.lc_active) {
        if (bit == ui.LMB) {
            kn.lcHover(cv, v, r, x, y);
            if (kn.lc_edge) |e| {
                const rd = @import("redo.zig");
                rd.before();
                if (kn.loopCut(e[0], e[1], kn.lc_cuts) catch "it failed") |why| {
                    app.toast(.warn, "Loop Cut: {s}", .{why});
                } else rd.set(.loopcut, &.{ @floatFromInt(e[0]), @floatFromInt(e[1]), @floatFromInt(kn.lc_cuts) });
            }
            kn.lc_active = false;
        } else if (bit == ui.RMB) kn.lc_active = false;
        return;
    }
    if (bit == ui.MMB) {
        vin.mode = .pan;
        return;
    }
    if (bit == ui.RMB) return contextMenu(i, r, v, x, y);
    // the left button
    if (v.show_gizmo and vp.inGizmo(r, x, y)) {
        vin.mode = .gizmo;
        return;
    }
    if (@import("armedit.zig").active()) {
        // armature modes: clicks pick joints and bones
        _ = @import("armedit.zig").click(v, r, x, y, ui.shift());
    } else if (@import("curveui.zig").on()) {
        // curve edit mode: clicks pick points and handles, Ctrl+click adds
        _ = @import("curveui.zig").click(v, r, x, y, ui.shift(), ui.ctrl());
    } else if (su.on()) {
        // sketch mode: a press on a point grabs it (the sketch solves as it
        // moves), a click runs the tool or picks, a drag elsewhere orbits
        app.setActiveArea(i);
        sk_grab = su.press(v, r, x, y);
        vin.mode = .sketch;
    } else if (em.active) {
        // edit mode: clicks select vertices / edges / faces, B then a drag box-selects
        box_on = em.box_armed;
        em.box_armed = false;
        vin.mode = .edit;
    } else {
        vin.mode = .object;
        drag_obj = null;
        stroking = false;
        // sculpt or paint mode: a stroke on the mesh; off it the click is the viewport's
        const on_mesh = (sculpt.on and sculpt.press(cv, v, r, x, y, ui.shift(), ui.ctrl())) or (paint.on and paint.press(cv, v, r, x, y));
        if (on_mesh) stroking = true;
        const p = if (on_mesh) null else pickable(cv, v, r);
        if (app.tool != .select and p != null) {
            // a tool drags the object under the pointer (selecting it first)
            if (!scene.isSel(p.?)) scene.selectOnly(p.?) else scene.active = p.?;
            drag_obj = p;
        }
        press_pick = p;
    }
}

/// The held button moved to (x, y), (dx, dy) since the last event.
fn viewDragged(i: i16, r: Rect, v: *vp.View, x: i32, y: i32, dx: i32, dy: i32, pressure: f32) void {
    _ = i;
    switch (vin.mode) {
        .none => {},
        .pan => pan(v, r, dx, dy),
        .gizmo => if (vin.moved) orbit(v, dx, dy, 0.5),
        .sketch => if (sk_grab) {
            if (vin.moved and (dx != 0 or dy != 0)) @import("sketchui.zig").drag(v, r, x, y); // (a click that does not move selects)
        } else if (vin.moved) orbit(v, dx, dy, 0.4),
        .edit => if (vin.moved and !box_on) orbit(v, dx, dy, 0.4),
        .object => if (stroking) {
            if (dx != 0 or dy != 0) {
                const st = @import("stroke.zig");
                if (st.pen_seen) st.pressure = pressure;
                if (paint.stroking) paint.drag(ui.cv, v, r, x, y) else sculpt.drag(ui.cv, v, r, x, y);
            }
        } else if (vin.moved) {
            if (drag_obj != null) toolDrag(v, r, dx, dy) else orbit(v, dx, dy, 0.4);
        },
    }
}

/// The held button let go at (x, y).
fn viewReleased(i: i16, r: Rect, v: *vp.View, x: i32, y: i32) void {
    const cv = ui.cv;
    switch (vin.mode) {
        .none, .pan => {},
        .gizmo => if (!vin.moved) {
            if (vp.gizmoPick(v, r, x, y)) |yp| {
                app.setActiveArea(i);
                app.alignView(yp[0], yp[1]);
            }
        },
        .sketch => {
            const su = @import("sketchui.zig");
            if (sk_grab) {
                su.release(v, r, x, y, ui.shift());
                sk_grab = false;
            } else if (!vin.moved) su.click(v, r, x, y, ui.shift());
        },
        .edit => if (box_on) {
            const bx = Rect{ .x = @min(vin.px, x), .y = @min(vin.py, y), .w = @intCast(@abs(x - vin.px)), .h = @intCast(@abs(y - vin.py)) };
            em.boxSelect(cv, v, r, bx, ui.ctrl());
            box_on = false;
        } else if (!vin.moved) {
            if (ui.mods & @import("wayland.zig").MOD_ALT != 0) em.clickLoop(cv, v, r, x, y, ui.shift()) else em.click(cv, v, r, x, y, ui.shift());
        },
        .object => if (stroking) {
            if (paint.stroking) paint.release() else sculpt.release();
            stroking = false;
        } else {
            if (!vin.moved and drag_obj == null) clickSelect(press_pick);
            if (drag_obj != null) undo.label(switch (app.tool) {
                .move => "Move",
                .rotate => "Rotate",
                .scale => "Scale",
                .select => "Select",
            });
        },
    }
}

/// The right button on the view: the object's menu or wheel (Shift: place
/// the 3D cursor; Alt: Ask AI about what is under it).
fn contextMenu(i: i16, r: Rect, v: *vp.View, x: i32, y: i32) void {
    const cv = ui.cv;
    app.setActiveArea(i);
    if (ui.mods & @import("wayland.zig").MOD_ALT != 0) {
        // Alt: Ask AI about it (ask_pick: in object mode, the object under
        // the pointer selected first when it is not)
        if (!em.active and !@import("sketchui.zig").on()) {
            if (pickable(cv, v, r)) |o| {
                if (!scene.isSel(o)) scene.selectOnly(o);
            }
        }
        @import("aiask.zig").open(x, y);
        return;
    }
    if (ui.shift()) {
        scene.cursor = vp.surfacePoint(cv, v, r, x, y) orelse scene.cursor;
        undo.label("Place 3D Cursor");
        return;
    }
    if (em.active) {
        // the mesh's wheel (or its list, as the preference says)
        if (@import("prefs.zig").wheel_menu) @import("pies.zig").openWheel(x, y, i) else menus.openAt(&cat.ctx_edit, x, y, i);
        return;
    }
    if (@import("prefs.zig").wheel_menu) {
        if (pickable(cv, v, r)) |o| {
            if (!scene.isSel(o)) scene.selectOnly(o) else scene.active = o;
        }
        @import("pies.zig").openWheel(x, y, i);
    } else menus.openAt(&cat.ctx_object, x, y, i); // (the list: as the original's, the object menu, the selection kept)
}

/// The wheel over the view, `steps` notches (positive: away from you).
fn wheel(v: *vp.View, steps: f32) void {
    const kn = @import("meshops2.zig");
    if (@import("measure.zig").on) return;
    if (em.active and kn.lc_active) {
        kn.lc_cuts = std.math.clamp(@as(u32, @intCast(@max(1, @as(i32, @intCast(kn.lc_cuts)) + (if (steps > 0) @as(i32, -1) else 1)))), 1, 64);
        return;
    }
    zoom(v, steps);
}

/// The pointer's shape over the view (BeeModel's, given to Zui).
fn viewCursor(i: i16, r: Rect) @TypeOf(ui.cursor) {
    const kn = @import("meshops2.zig");
    const inside = r.contains(ui.mx, ui.my);
    if (vin.held != 0 and vin.area == i and vin.moved) {
        return switch (vin.mode) {
            .pan => .move,
            .edit => if (box_on) .crosshair else .move,
            .sketch => if (sk_grab) .grabbing else .move,
            .object => if (stroking) ui.cursor else if (drag_obj != null) .grabbing else .move,
            else => .move,
        };
    }
    if (inside and (@import("measure.zig").on or (em.active and (kn.kn_active or kn.lc_active or em.box_armed)))) return .crosshair;
    return ui.cursor;
}

var sk_grab = false;
/// A sculpt or paint stroke is under way (begun by the view's press).
var stroking = false;

fn toolDrag(v: *const vp.View, r: Rect, dx: i32, dy: i32) void {
    const fdx: f32 = @floatFromInt(dx);
    const fdy: f32 = @floatFromInt(dy);
    const c = vp.Cam.init(v, r);
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.selected or scene.followsSelected(oi)) continue;
        switch (app.tool) {
            .move => {
                const wl = scene.worldLoc(oi);
                const k = c.pixelSize(wl);
                scene.setWorldLoc(oi, m.add(wl, m.add(m.scale(c.right, fdx * k), m.scale(c.up, -fdy * k))));
            },
            .rotate => o.rot = m.matEuler(m.mul3(m.axisAngle(.{ 0, 1, 0 }, fdx * 0.8 * m.deg), m.eulerMat(o.rot))),
            .scale => {
                const f = std.math.clamp(1.0 + (fdx - fdy) * 0.01, 0.5, 1.5);
                for (&o.scl) |*sc| sc.* = std.math.clamp(sc.* * f, 0.001, 1000);
            },
            .select => {},
        }
    }
}

// --- tools ------------------------------------------------------------------------

/// A list row that runs operator `id`: icon, label, shortcut (when there is room).
/// A row of the Tools editor: a catalog operator, its icon (a bullet
/// without one), its label and, when there is room, its key on the right;
/// on the accent fill when `selected`. Greyed when it can't run now, a
/// click then says why.
const ToolItem = struct { id: []const u8 = "", ic: ?Icon = null, on: bool = false, heading: []const u8 = "", gap: i32 = 0 };

fn toolRow(z: *zui.Ui, it: ToolItem, show_key: bool) void {
    const th = ui.th;
    const oi = ops.byId(it.id) orelse return;
    const e = &cat.entries[oi];
    const why = ops.reason(oi);
    z.pushIdInt(oi);
    defer z.popId();
    const r = z.placeSized(.fill, .px(26), .{ .x = 100, .y = 26 });
    const wid = z.id("row");
    var b = z.interact(wid, r);
    const hv = why == null and (b.hovered or b.held);
    if (it.on) z.drawRect(.{ .rect = r, .fill = host.col(th.accent), .radius = 4 }) else if (hv) z.drawRect(.{ .rect = r, .fill = host.col(th.btn_hover), .radius = 4 });
    const fg = host.col(if (why != null) th.text_off else if (it.on) th.accent_text else th.text);
    var tx = r.x + 6;
    if (it.ic) |ic| {
        z.painter().icon(host.icon(ic), .{ .x = tx, .y = r.y + (r.h - 16) / 2, .w = 16, .h = 16 }, fg);
    } else {
        // no icon: a bullet, the label lines up with the others
        z.drawRect(.{ .rect = .{ .x = tx + 6, .y = r.y + r.h / 2 - 2, .w = 4, .h = 4 }, .fill = fg, .radius = 2 });
    }
    tx += 20;
    var kb: [32]u8 = undefined;
    var k = if (show_key) ops.keyLabel(oi, &kb) else "";
    // the whole label first: the shortcut goes when both do not fit
    const lw = z.textSize(e.label).x;
    if (k.len > 0 and tx + lw + z.textSize(k).x + 18 > r.right()) k = "";
    const kw: f32 = if (k.len > 0) z.textSize(k).x + 14 else 0;
    const ty = r.y + (r.h - z.textSize(e.label).y) / 2;
    z.pushClip(.{ .x = tx, .y = r.y, .w = @max(0, r.right() - tx - kw - 4), .h = r.h });
    z.drawText(.{ .x = tx, .y = ty }, fg, e.label);
    z.popClip();
    if (k.len > 0) z.drawText(.{ .x = r.right() - 8 - z.textSize(k).x, .y = ty }, host.col(if (it.on) th.accent_text else th.text_dim), k);
    ui.record("button", e.label, host.rectOf(r), why == null);
    z.tooltipRich(b, .{ .title = e.label, .shortcut = ops.keyLabel(oi, &kb), .body = e.doc, .warning = why orelse "" });
    if (bkit.ring(b, e.label)) b.clicked = true;
    if (b.clicked) {
        if (why) |w| app.toast(.warn, "{s}: {s}", .{ e.label, w }) else ops.run(oi);
    }
}

/// The Tools editor's rows (for the mode the scene is in), as many as fit.
fn toolList(r: Rect, items: []const ToolItem, top: i32) void {
    const salt: usize = @intCast(r.x *% 31 +% r.y);
    const z = host.beginPart("tools", salt, .{ .x = r.x + 6, .y = r.y + top, .w = r.w - 12, .h = r.h - top }) orelse return;
    defer host.endPart(z);
    z.beginGroup(.{ .width = .fill, .spacing = 4 });
    defer z.endGroup();
    const keys = r.w >= 150;
    var y = r.y + top;
    for (items, 0..) |it, k| {
        if (it.gap > 0) {
            y += it.gap;
            // (inside the rows' spacing of 4: a gap of `gap` more)
            z.spacer(.px(@floatFromInt(it.gap - 4)));
            continue;
        }
        if (it.heading.len > 0) {
            // a heading needs a row under it
            if (y + 10 + 18 + 26 > r.bottom()) return;
            y += 28;
            z.spacer(.px(2));
            z.pushMetric(.font_size, 12); // (BeeModel's small face)
            z.label(it.heading, .{ .color = host.col(ui.th.text_dim) });
            z.popStyle();
            continue;
        }
        _ = k;
        if (y + 26 > r.bottom()) return;
        toolRow(z, it, keys);
        y += 30;
    }
}

fn edTools(i: i16, r: Rect) void {
    _ = i;
    ui.cv.fill(r, ui.th.pane_bg);
    var buf: [40]ToolItem = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(b: *[40]ToolItem, c: *usize, it: ToolItem) void {
            if (c.* < b.len) {
                b[c.*] = it;
                c.* += 1;
            }
        }
    }.f;
    const checked = struct {
        fn f(id: []const u8) bool {
            return if (ops.byId(id)) |oi| ops.checked(oi) orelse false else false;
        }
    }.f;
    if (@import("armedit.zig").active()) {
        // armature modes: their tools (tl_arm)
        for ([_][]const u8{ "arm.extrude", "arm.delete_bones", "arm.select_all", "", "arm.insert_key", "arm.clear_pose_key", "arm.auto_weights" }) |id| add(&buf, &n, if (id.len == 0) .{ .gap = 10 } else .{ .id = id });
        return toolList(r, buf[0..n], 10);
    }
    if (@import("curveui.zig").on()) {
        // curve edit mode: its tools (tl_curve)
        for (@import("curveui.zig").tools) |id| add(&buf, &n, if (id.len == 0) .{ .gap = 10 } else .{ .id = id });
        return toolList(r, buf[0..n], 10);
    }
    if (@import("sketchui.zig").on()) {
        // sketch mode: its tools, then the constraints (tl_sketch)
        for (@import("sketchui.zig").tools) |a| add(&buf, &n, if (a.id.len == 0) .{ .heading = "CONSTRAIN" } else .{ .id = a.id, .ic = a.ic, .on = checked(a.id) });
        return toolList(r, buf[0..n], 10);
    }
    if (paint.on) {
        // the paint modes (tl_paint)
        for (paintui.tools) |a| add(&buf, &n, if (a.id.len == 0) .{ .heading = "LAYERS" } else .{ .id = a.id, .ic = a.ic });
        return toolList(r, buf[0..n], 10);
    }
    if (sculpt.on and sculpt.land) {
        // sculpt mode on a landscape: its brushes, PAINT (tl_lsculpt)
        for ([_][]const u8{ "landscape.tool_raise", "landscape.tool_lower", "landscape.tool_smooth", "landscape.tool_flatten", "landscape.tool_ramp", "landscape.tool_noise", "landscape.tool_erode", "", "landscape.paint_rock", "landscape.paint_grass", "landscape.paint_sand", "landscape.paint_snow", "landscape.paint_dirt", "landscape.paint_gravel", "landscape.paint_moss", "landscape.paint_mud", "landscape.paint_auto" }) |id| add(&buf, &n, if (id.len == 0) .{ .heading = "PAINT" } else .{ .id = id, .on = checked(id) });
        return toolList(r, buf[0..n], 10);
    }
    if (sculpt.on) {
        // sculpt mode: the brushes (tl_sculpt)
        for (sculptui.tools) |a| add(&buf, &n, if (a.id.len == 0) .{ .gap = 8 } else .{ .id = a.id, .ic = a.ic });
        return toolList(r, buf[0..n], 10);
    }
    if (em.active) {
        // edit mode: the mesh tools (tl_edit), then SELECT
        const mt = [_]ToolItem{
            .{ .id = "mesh.extrude", .ic = .extrude },   .{ .id = "mesh.extrude_individual", .ic = .extrude },
            .{ .id = "mesh.inset", .ic = .inset },       .{ .id = "mesh.bevel", .ic = .bevel },
            .{ .id = "mesh.loopcut", .ic = .loopcut },   .{ .id = "mesh.knife", .ic = .knife },
            .{ .id = "mesh.bisect", .ic = .knife },      .{ .id = "mesh.spin", .ic = .rotate },
            .{ .id = "mesh.subdivide", .ic = .grid },    .{ .id = "mesh.bridge" },
            .{ .id = "mesh.fill" },                      .{ .id = "mesh.dissolve" },
            .{ .heading = "SELECT" },                    .{ .id = "mesh.select_all", .ic = .select },
            .{ .id = "mesh.select_box", .ic = .select }, .{ .id = "mesh.select_linked" },
            .{ .id = "mesh.select_invert" },
        };
        return toolList(r, &mt, 10);
    }
    const tools = [_]struct { t: app.Tool, id: []const u8, ic: Icon }{
        .{ .t = .select, .id = "tool.select", .ic = .select }, .{ .t = .move, .id = "tool.move", .ic = .move },
        .{ .t = .rotate, .id = "tool.rotate", .ic = .rotate }, .{ .t = .scale, .id = "tool.scale", .ic = .scale },
    };
    for (tools) |t| add(&buf, &n, .{ .id = t.id, .ic = t.ic, .on = app.tool == t.t });
    add(&buf, &n, .{ .heading = "ADD" });
    for ([_]ToolItem{
        .{ .id = "create.cube", .ic = .cube },   .{ .id = "create.sphere", .ic = .sphere }, .{ .id = "create.cylinder", .ic = .cylinder },
        .{ .id = "create.plane", .ic = .plane }, .{ .id = "create.light", .ic = .light },   .{ .id = "create.camera", .ic = .camera },
        .{ .gap = 12 },
        .{ .id = "view.measure", .ic = .measure }, .{ .id = "view.cursor_reset", .ic = .cursor },
    }) |it| add(&buf, &n, it);
    toolList(r, buf[0..n], 6);
}

// --- outliner ------------------------------------------------------------------------

fn kindIcon(k: scene.Kind) Icon {
    return switch (k) {
        .mesh => .mesh,
        .cube => .cube,
        .sphere => .sphere,
        .cylinder => .cylinder,
        .plane => .plane,
        .light => .light,
        .camera => .camera,
        .armature => .armature,
        .sketch => .sketch,
        .field => .physics,
    };
}

const outf = @import("outfolders.zig");
const fd = @import("folders.zig");
const dialogs = @import("dialogs.zig");
var filter_buf: [48]u8 = undefined;
var filter_len: usize = 0;

fn containsI(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var k: usize = 0;
    while (k + needle.len <= hay.len) : (k += 1) {
        if (std.ascii.eqlIgnoreCase(hay[k .. k + needle.len], needle)) return true;
    }
    return false;
}

/// The Outliner's list state, one per area (by its index).
var out_states: [16]zui.ListState = @splat(.{});
/// One per row: the list keeps it, synced with the scene's selection.
var out_sel: [outf.ROWS_MAX]bool = undefined;
var out_order: [outf.ROWS_MAX]u16 = undefined;
/// F2 (renameActive): the object to rename, once its row is described.
var rename_req: ?usize = null;

fn edOutliner(i: i16, r: Rect) void {
    ui.cv.fill(r, ui.th.pane_bg);
    const z = host.beginPart("outliner", @intCast(i), r) orelse return;
    defer host.endPart(z);
    const th = ui.th;
    const filter = filter_buf[0..filter_len];
    // the rows: children under their parents (a flat list while filtering)
    var shown: usize = 0;
    indexChildren();
    if (filter.len > 0) {
        for (scene.objects[0..scene.count], 0..) |*o, k| {
            if (containsI(o.name(), filter)) {
                out_order[shown] = @intCast(k);
                shown += 1;
            }
        }
    } else outf.build(&out_order, &shown, treeRows);
    const order = out_order[0..shown];
    const sel = out_sel[0..shown];
    for (order, sel) |k8, *sl| sl.* = if (k8 >= outf.BASE) outf.picked == fd.list[k8 - outf.BASE].uid else scene.objects[k8].selected;
    const st = &out_states[@as(usize, @intCast(i)) % out_states.len];
    if (rename_req) |want| {
        rename_req = null;
        for (order, 0..) |k8, row| if (k8 == want) st.startRename(row);
    }
    const wide = r.w > 150;

    // BeeModel's look: rows 20 high, 14 in a level, the chosen ones on the
    // dark accent, the active one in gold
    z.pushMetric(.frame_padding, .{ .x = 8, .y = 0 });
    z.pushMetric(.indent, 14);
    z.pushColor(.button_active, host.col(th.accent_dark));
    z.pushColor(.accent, host.col(th.active));
    var list = z.beginList("##outliner", sel, st, .{ .frame = false, .height = .fill });
    var row = list.first;
    var dragged: ?usize = null;
    if (z.dragging()) |p| if (std.mem.eql(u8, p.kind, "object") and p.data < scene.count) {
        dragged = @intCast(p.data);
    };
    while (row < list.end) : (row += 1) {
        const k8 = order[row];
        if (k8 >= outf.BASE) {
            outf.describeRow(z, &list, row, k8 - outf.BASE, wide, dragged);
            continue;
        }
        const k: usize = k8;
        const o = &scene.objects[k];
        const act = scene.active != null and scene.active.? == k;
        z.beginRow(&list, row, .{
            .label = o.name(),
            .icon = host.icon(kindIcon(o.kind)),
            .icon_color = host.col(th.text_dim),
            .depth = if (filter.len > 0) 0 else @intCast(@min(8, scene.depth(k) + outf.objDepth(o))),
            .fold = if (filter.len == 0 and hasChildren(k)) !o.folded else null,
            .active = act,
            .renamable = true,
            .swatch = host.col(switch (o.kind) {
                .camera => 0x61afef,
                .light => 0xe5c07b,
                else => o.color,
            }),
            .text_color = host.col(if (o.selected) th.selected else if (o.visible) th.text else th.text_off),
        });
        // lock, render, eye: recorded as `toggle:<name>` in that order
        var locked = o.locked;
        var rend = o.render;
        var vis = o.visible;
        var lb: [96]u8 = undefined;
        if (wide) {
            const lk = z.iconToggle(std.fmt.bufPrint(&lb, "{s}##lock", .{o.name()}) catch "##lock", &locked, .{ .on = host.icon(.lock), .off = host.icon(.unlock), .size = 20 });
            z.tooltipRich(lk, .{ .title = "Lock", .body = "Locked: clicks in the viewport pass through it" });
            if (lk.changed) {
                o.locked = locked;
                undo.label(if (o.locked) "Lock" else "Unlock");
            }
            const rd = z.iconToggle(std.fmt.bufPrint(&lb, "{s}##render", .{o.name()}) catch "##render", &rend, .{ .on = host.icon(.render_on), .size = 20 });
            z.tooltipRich(rd, .{ .title = "Render", .body = "Off: renders leave it out" });
            if (rd.changed) {
                o.render = rend;
                undo.label("Render");
            }
        }
        const ey = z.iconToggle(std.fmt.bufPrint(&lb, "{s}##eye", .{o.name()}) catch "##eye", &vis, .{ .on = host.icon(.eye), .off = host.icon(.eye_off), .size = 20 });
        z.tooltipRich(ey, .{ .title = "Visibility", .body = "Show or hide the object (H hides the selection, Alt+H reveals)" });
        if (ey.changed) {
            o.visible = vis;
            if (!o.visible) o.selected = false;
            undo.label(if (o.visible) "Show" else "Hide");
        }
        const res = z.endRow(&list);
        if (res.fold_rect.w > 0) ui.record("fold", o.name(), host.rectOf(res.fold_rect), true);
        if (res.fold_clicked) o.folded = !o.folded;
        if (res.renamed) |nm| {
            o.setName(nm);
            undo.label("Rename");
        }
        if (res.interaction.pressed) @import("bscript.zig").macroSelect(); // (recording a macro)
        if (res.interaction.context_clicked) {
            if (!o.selected) scene.selectOnly(k) else scene.active = k;
            menus.openAt(&cat.ctx_outliner, ui.mx, ui.my, i);
        }
        _ = z.dragSource(res.interaction, .{ .kind = "object", .data = k, .label = o.name() });
        // a row dragged onto this one: this object's child
        if (dragged) |dk| if (dk != k) if (z.dropZone(res.rect, "object")) |d| {
            if (scene.isAncestor(dk, k)) {
                z.refuseDrop("Cannot: it is below it");
            } else {
                z.dropHint(std.fmt.bufPrint(&lb, "Child of {s}", .{o.name()}) catch "");
                if (d.released) {
                    var n_ok: usize = 0;
                    for (0..scene.count) |q| {
                        if ((q == dk or scene.objects[q].selected) and q != k and scene.setParent(q, k)) n_ok += 1;
                    }
                    undo.label("Parent");
                    if (n_ok > 0) app.toast(.ok, "Child of {s}", .{o.name()});
                }
            }
        };
    }
    const lr = z.endList(&list);
    // the empty part under the rows: no parent, no folder
    if (dragged) |dk| if (lr.empty.h > 0) if (z.dropZone(lr.empty, "object")) |d| {
        z.dropHint("No parent, no folder");
        if (d.released) {
            for (0..scene.count) |q| {
                if (q != dk and !scene.objects[q].selected) continue;
                if (scene.objects[q].parent != null) _ = scene.setParent(q, null);
                scene.objects[q].folder = 0;
            }
            undo.label("Clear Parent");
        }
    };
    z.popStyles(4);
    if (lr.changed) outSelect(order, sel, st, z.input.modifiers);

    // the filter row: Filter by name (as you type), Tidy, AI, + (folder)
    z.beginHorizontal(.{ .spacing = 3, .padding = 0 });
    _ = z.textInput("##Filter by name", &filter_buf, &filter_len, .{ .width = .fill, .hint = "Filter by name", .copy_all = true });
    if (r.w > 200) {
        _ = bkit.opButton(z, "outliner.tidy", .{ .label = "Tidy", .width = .auto });
        _ = bkit.opButton(z, "outliner.tidy_ai", .{ .label = "AI", .width = .auto });
        _ = bkit.opButton(z, "outliner.folder_new", .{ .label = "+", .width = .auto });
    }
    z.endHorizontal();
}

/// The list's selection, changed by a click or a key, into the scene's:
/// objects selected as their rows, the active one the row clicked; a
/// folder's row clicked alone picks the folder and selects what is in it.
fn outSelect(order: []const u16, sel: []const bool, st: *const zui.ListState, mods: zui.Modifiers) void {
    const at = st.cursor;
    if (at) |c| if (c < order.len and order[c] >= outf.BASE and sel[c] and !mods.ctrl and !mods.shift) {
        outf.pick(order[c] - outf.BASE);
        return;
    };
    // (a plain click: objects folded away or filtered out are let go too)
    if (!mods.ctrl and !mods.shift) scene.deselectAll();
    outf.picked = 0;
    for (order, sel) |k8, s8| {
        if (k8 >= outf.BASE) {
            if (s8) outf.picked = fd.list[k8 - outf.BASE].uid;
            continue;
        }
        scene.objects[k8].selected = s8;
    }
    if (at) |c| if (c < order.len and order[c] < outf.BASE) {
        const k: usize = order[c];
        scene.active = if (scene.objects[k].selected) k else null;
    };
    if (scene.active) |a| if (!scene.objects[a].selected) {
        scene.active = null;
    };
}

/// Each object's children, indexed once a frame so the tree costs O(n):
/// the first child and the next sibling, in object order (none: `no_kid`).
const no_kid = std.math.maxInt(u16);
var first_kid: [scene.max_objects]u16 = undefined;
var next_kid: [scene.max_objects]u16 = undefined;

fn indexChildren() void {
    const n = scene.count;
    @memset(first_kid[0..n], no_kid);
    var c = n;
    while (c > 0) {
        c -= 1;
        const p = scene.objects[c].parent orelse continue;
        if (p >= n or p == c) continue;
        next_kid[c] = first_kid[p];
        first_kid[p] = @intCast(c);
    }
}

fn hasChildren(k: usize) bool {
    return first_kid[k] != no_kid;
}

/// Object k and, unless it is folded, its children (depth first).
fn treeRows(k: usize, order: []u16, n: *usize) void {
    if (n.* >= order.len) return;
    order[n.*] = @intCast(k);
    n.* += 1;
    if (scene.objects[k].folded) return;
    var c = first_kid[k];
    while (c != no_kid) : (c = next_kid[c]) treeRows(c, order, n);
}

/// F2 renames the active object in the first outliner.
pub fn renameActive() bool {
    const a = scene.active orelse return false;
    if (!app.hasEditor(.outliner)) return false;
    rename_req = a;
    app.dirty = true;
    return true;
}

// --- properties ------------------------------------------------------------------

const swatches = [_]u32{ 0xb8bcc4, 0xe06c75, 0x98c379, 0x61afef, 0xf2b134, 0xc678dd, 0x56b6c2, 0xd19a66, 0xffffff, 0x5c6370, 0x2c313a, 0xbe5046 };

const Tab = struct { ic: Icon, name: []const u8, ported: bool };
const tabs = [_]Tab{
    .{ .ic = .object, .name = "Object", .ported = true },      .{ .ic = .modifier, .name = "Modifiers", .ported = true },
    .{ .ic = .material, .name = "Material", .ported = true },  .{ .ic = .physics, .name = "Physics", .ported = true },
    .{ .ic = .sketch, .name = "CAD", .ported = true },        .{ .ic = .scene, .name = "Scene", .ported = true },
    .{ .ic = .rendered, .name = "Render", .ported = true },   .{ .ic = .overlays, .name = "Viewport", .ported = true },
    .{ .ic = .key, .name = "Animation", .ported = true },     .{ .ic = .armature, .name = "Rig", .ported = true },
    .{ .ic = .sparkle, .name = "Particles", .ported = true },  .{ .ic = .grid, .name = "Landscape", .ported = true },
};
const TAB_MATERIAL = 2;
const TAB_SCENE = 5;
const TAB_RENDER = 6;
const TAB_MODS = 1;
const TAB_VIEWPORT = 7;
const TAB_ANIMATION = 8;
const TAB_RIG = 9;
const TAB_CAD = 4;
const TAB_PHYS = 3;
const TAB_PART = 10;
var part_h: i32 = 0;
/// Landscape (landui.zig): the last, only while the active object is one.
const TAB_LAND = 11;
var land_h: i32 = 0;

pub var sec_open: [32]bool = @splat(true);

/// A section title that folds what is under it. Returns whether it is open.
pub fn section(wid: u32, x: i32, y: *i32, w: i32, title: []const u8, k: usize) bool {
    const th = ui.th;
    const cv = ui.cv;
    const r = Rect{ .x = x - 4, .y = y.*, .w = w + 4, .h = 22 };
    ui.record("section", title, r, true);
    if (ui.hover(wid, r)) cv.fillRound(r, 3, th.hover);
    if (sec_open[k]) cv.chevronDown(r.x + 9, r.y + 11, th.text_dim) else cv.chevronRight(r.x + 9, r.y + 11, th.text_dim);
    const old = gfx.useFace(.head);
    _ = cv.text(r.x + 20, r.y + 3, title, th.accent_fg);
    _ = gfx.useFace(old);
    if (ui.press(wid, r, ui.LMB)) sec_open[k] = !sec_open[k];
    y.* += 26;
    return sec_open[k];
}

// --- a light's and a camera's rows (rnui.s lcam_props) -------------------------------

const light_types = [_]scene.LightType{ .point, .sun, .spot, .area };
var lt_obj: usize = 0;
fn ltLabel(k: usize) []const u8 {
    return light_types[k].label();
}
fn ltPick(k: usize) void {
    if (lt_obj >= scene.count or scene.objects[lt_obj].kind != .light) return;
    scene.objects[lt_obj].light_type = light_types[k];
    undo.label("Light");
    app.dirty = true;
}
fn ltChecked(k: usize) bool {
    return lt_obj < scene.count and scene.objects[lt_obj].light_type == light_types[k];
}
fn lightColDone() void {
    undo.label("Light");
}

/// The rows under the heading Light (Power as a multiple of the default,
/// Colour, the type, Size, a spot's Cone) or Camera (Lens (mm), then "This
/// camera renders" or Render from This Camera), on Zui in the column
/// (x, w). y below them.
fn lcamProps(salt: usize, s: usize, x: i32, w: i32, y0: i32) i32 {
    var f = bkit.Flow.begin("props.lcam", salt, .{ .x = x, .y = y0, .w = w, .h = 0 }, y0);
    if (f.z) |z| lcamDescribe(z, s);
    return f.end();
}

fn lcamDescribe(z: *zui.Ui, s: usize) void {
    const o = &scene.objects[s];
    bkit.heading(z, if (o.kind == .light) "Light" else "Camera");
    if (o.kind == .camera) {
        if (bkit.numberRow(z, "Lens (mm)", &o.lens, .{ .step = 0.1, .min = 1, .max = 1000, .decimals = 1, .tip = "Focal length: 18 wide, 50 normal, 135 tele" }).changed) undo.label("Camera");
        const renders = vp.sceneCamera() != null and vp.sceneCamera().? == s;
        if (renders) {
            bkit.info(z, "This camera renders");
        } else if (bkit.button(z, "Render from This Camera", "The camera renders and Camera View (Numpad 0) look through").clicked) {
            @import("lcam.zig").renderFrom(s); // (camera.set active)
            undo.label("Render Camera");
        }
        z.spacer(.px(2));
        return;
    }
    // power: the record's multiple of the default (1: 1000 W here)
    var pw = o.power / 1000.0;
    if (bkit.numberRow(z, "Power", &pw, .{ .step = 0.01, .min = 0, .max = 100000, .decimals = 2, .tip = "How strong the light is (1: the default)" }).changed) {
        o.power = pw * 1000.0;
        undo.label("Light");
    }
    _ = bkit.colourRow(z, "Colour", &o.light_color, lightColDone, "");
    var sel: usize = 0;
    for (light_types, 0..) |t, k| {
        if (t == o.light_type) sel = k;
    }
    if (bkit.choice(z, "##Light type", &sel, light_types.len, ltLabel, "Point: from a spot (or a ball of the size). Sun: from far away, one direction. Spot: a cone. Area: a square panel")) {
        o.light_type = light_types[sel];
        undo.label("Light");
        app.dirty = true;
    }
    if (bkit.numberRow(z, "Size", &o.size, .{ .step = 0.01, .min = 0, .max = 1000, .decimals = 2, .tip = "Point and spot: the radius (m), soft shadows grow with it. Sun: its angle (degrees). Area: the edge (m)" }).changed) undo.label("Light");
    if (o.light_type == .spot) {
        if (bkit.numberRow(z, "Cone (deg)", &o.cone, .{ .step = 0.2, .min = 1, .max = 179, .decimals = 1, .tip = "How wide the spot's cone is" }).changed) undo.label("Light");
    }
    z.spacer(.px(2));
}

/// A page's scroll bar when what it shows is taller than it (wg_scroll_end): a
/// thumb 4 wide, 6 in from the right, h x h / content high (24 at least); a
/// drag on the bar's 8 pixels scrolls.
fn pageBar(wid: u32, r: Rect, scroll: *i32, content: i32) void {
    if (content <= r.h or r.h <= 0) return;
    const th_h = @max(@divTrunc(r.h * r.h, content), 24);
    const bar = Rect{ .x = r.right() - 8, .y = r.y, .w = 8, .h = r.h };
    if (ui.press(wid, bar, ui.LMB) or (ui.isActive(wid) and ui.down & ui.LMB != 0)) {
        const span = @max(1, r.h - th_h);
        scroll.* = @divTrunc((ui.my - r.y - @divTrunc(th_h, 2)) * (content - r.h), span);
        app.dirty = true;
    }
    scroll.* = std.math.clamp(scroll.*, 0, content - r.h);
    const ty = r.y + @divTrunc(scroll.* * (r.h - th_h), content - r.h);
    ui.cv.fillRound(.{ .x = r.right() - 6, .y = ty, .w = 4, .h = th_h }, 2, ui.th.sep);
    ui.record("scrollbar", "props.page", bar, true);
}

fn fieldLabel(x: i32, y: i32, s: []const u8) void {
    _ = ui.cv.text(x, y + 2, s, ui.th.text_dim);
}

// --- the Material tab (matui.s) ------------------------------------------------------

const material = @import("material.zig");
const matops = @import("matops.zig");
const graphcmds = @import("graphcmds.zig");

/// Colour fields edit a copy in sRGB (the picker's), written back to the material.
var mt_base_col: u32 = 0;
var mt_emit_col: u32 = 0;
var mt_pick: usize = 0; // the material the picker edits

fn matBaseChanged() void {
    const ma = material.get(mt_pick) orelse return;
    ma.base = material.toLinear(mt_base_col);
    material.version +%= 1;
    undo.label("Material");
}
fn matEmitChanged() void {
    const ma = material.get(mt_pick) orelse return;
    ma.emission = material.toLinear(mt_emit_col);
    material.version +%= 1;
    undo.label("Material");
}

fn slotLabel(k: usize) []const u8 {
    return if (k == 0) "None" else material.list[k - 1].nameOf();
}
fn slotPick(k: usize) void {
    const a = matops.activeMesh() orelse return;
    scene.objects[a].mat = @intCast(k);
    undo.label("Assign Material");
}
fn slotChecked(k: usize) bool {
    const a = matops.activeMesh() orelse return false;
    return scene.objects[a].mat == k;
}
fn presetLabel(k: usize) []const u8 {
    return material.presets[k].name;
}
fn presetPick(k: usize) void {
    matops.presetActive(k);
}
const blend_names = [_][]const u8{ "Opaque", "Masked", "Translucent" };
fn blendLabel(k: usize) []const u8 {
    return blend_names[k];
}
fn blendPick(k: usize) void {
    const a = matops.activeMesh() orelse return;
    const ma = material.of(&scene.objects[a]) orelse return;
    ma.blend = @floatFromInt(k);
    material.version +%= 1;
    undo.label("Material");
}
fn blendChecked(k: usize) bool {
    const a = matops.activeMesh() orelse return false;
    const ma = material.of(&scene.objects[a]) orelse return false;
    return @as(usize, @intFromFloat(std.math.clamp(ma.blend, 0, 2))) == k;
}

/// A colour row: the label on the left, the swatch on the right half.
fn colourRow(wid: u32, r: Rect, mi: usize, label: []const u8, c: *u32, cb: *const fn () void, tipText: []const u8) void {
    const th = ui.th;
    if (ui.inside(r)) mt_pick = mi;
    const cv = ui.cv;
    const hv = ui.hover(wid, r);
    cv.fillRound(r, 4, if (hv) th.field_hover else th.field);
    _ = cv.textFit(r.x + 7, r.y + @divTrunc(r.h - gfx.glyph_h, 2), @divTrunc(r.w, 2) - 10, label, th.text_dim);
    const sw = Rect{ .x = r.x + @divTrunc(r.w, 2), .y = r.y + 3, .w = r.w - @divTrunc(r.w, 2) - 4, .h = r.h - 6 };
    @import("colorpick.zig").field(wid, sw, c, label, cb);
    if (ui.inside(r) and !ui.inside(sw)) ui.tip(wid, r, label, tipText, null);
    if (ui.press(wid +% 1, r, ui.LMB)) {
        ui.active = 0;
        @import("colorpick.zig").openFor(c, sw, label, cb);
    }
}

// --- the Modifiers tab (mods.s mods_props_draw) -------------------------------------------

var mods_h: i32 = 0; // the tab's height, last frame
var phys_h: i32 = 0; // the Physics tab's height
var cad_h: i32 = 0; // the CAD tab's
var mod_pick_obj: usize = 0;
var mod_pick_k: usize = 0;

fn modPickLabel(k: usize) []const u8 {
    return if (k == 0) "None" else scene.objects[k - 1].name();
}
fn modPickEntry() ?*scene.Mod {
    if (mod_pick_obj >= scene.count or mod_pick_k >= scene.objects[mod_pick_obj].mods.n) return null;
    return &scene.objects[mod_pick_obj].mods.m[mod_pick_k];
}
fn modPickChecked(k: usize) bool {
    const d = modPickEntry() orelse return false;
    return if (k == 0) d.p[0] == 0 else scene.objects[k - 1].oid == d.p[0];
}
fn modPick(k: usize) void {
    const d = modPickEntry() orelse return;
    const want_arm = d.kind == @import("mods.zig").ARMATURE;
    if (k > 0 and want_arm and scene.objects[k - 1].kind != .armature) {
        app.toast(.warn, "Armature: pick an armature", .{});
        return;
    }
    if (k > 0 and !want_arm and (k - 1 == mod_pick_obj or !scene.objects[k - 1].kind.isMesh() or scene.objects[k - 1].mesh == null)) {
        app.toast(.warn, "Boolean: pick another mesh object", .{});
        return;
    }
    d.p[0] = if (k == 0) 0 else scene.objects[k - 1].oid;
    undo.label(if (want_arm) "Armature Object" else "Boolean Object");
}

// A Geometry Nodes or Logic modifier's tree: "None" then the scene's trees
// (md_tree_names); the value is the tree's place + 1.
fn treePickLabel(k: usize) []const u8 {
    const nt = @import("ntree.zig");
    if (k == 0) return "None";
    return if (nt.get(@intCast(k - 1))) |r| nt.name(r) else "?";
}
fn treePickChecked(k: usize) bool {
    const d = modPickEntry() orelse return false;
    return @import("ntree.zig").cvtt(@import("mods.zig").getF(d, 0)) == @as(i32, @intCast(k));
}
fn treePick(k: usize) void {
    const d = modPickEntry() orelse return;
    @import("mods.zig").setF(d, 0, @floatFromInt(k));
    undo.label("Modifier");
    app.dirty = true;
}
fn drawModsTab(salt: usize, bd: Rect) i32 {
    var f = bkit.Flow.begin("props.mods", salt, bd, bd.y);
    if (f.z) |z| modsDescribe(z);
    return f.end();
}

/// A small flat button in a modifier's header row; greyed with `why`.
fn modButton(z: *zui.Ui, label: []const u8, w: f32, tip: []const u8, why: ?[]const u8) bool {
    z.pushDisabled(why);
    const b = z.button(label, .{ .width = .px(w), .variant = .flat });
    z.popDisabled();
    z.tooltipRich(b, .{ .title = label, .body = tip, .warning = why orelse "" });
    return (b.clicked or bkit.ring(b, label)) and why == null;
}

fn modsDescribe(z: *zui.Ui) void {
    const mods = @import("mods.zig");
    bkit.heading(z, "Modifiers");
    const a = scene.active orelse return bkit.info(z, "Select a mesh object");
    const o = &scene.objects[a];
    if (o.mesh == null or !o.kind.isMesh()) return bkit.info(z, "Select a mesh object");

    {
        const full = o.mods.n >= scene.MOD_MAX;
        z.pushDisabled(if (full) "The stack is full" else null);
        const b = z.button("Add Modifier", .{ .width = .px(@min(240, bkit.columnWidth(z))), .variant = .primary });
        z.popDisabled();
        z.tooltipRich(b, .{ .title = "Add Modifier", .body = "The list of types", .warning = if (full) "The stack is full" else "" });
        if (b.clicked and !full) menus.openAt(&cat.items_modadd, @intFromFloat(b.rect.x), @intFromFloat(b.rect.bottom() + 2), app.activeArea());
    }
    z.spacer(.px(2));
    if (o.mods.n == 0) return bkit.info(z, "No modifiers on this object");
    const bad = mods.failed(a);
    var k: usize = 0;
    while (k < o.mods.n) : (k += 1) {
        const d = &o.mods.m[k];
        z.pushIdInt(k);
        defer z.popId();
        // on / off and the name; ^ v Apply x on the right
        z.beginHorizontal(.{ .spacing = 2 });
        var on = d.flags & 1 != 0;
        const nm = mods.names[if (d.kind < mods.COUNT) d.kind else 0];
        z.beginGroup(.{ .width = .fill });
        if (bkit.checkRow(z, nm, &on, "").changed) {
            d.flags = (d.flags & ~@as(u32, 1)) | @intFromBool(on);
            undo.label("Toggle Modifier");
        }
        z.endGroup();
        const up = modButton(z, "^", 22, "Move it earlier in the stack", if (k > 0) null else "It is the first");
        const down = modButton(z, "v", 22, "Move it later in the stack", if (k + 1 < o.mods.n) null else "It is the last");
        const apply = modButton(z, "Apply", 48, "Make this modifier (and those above it) part of the mesh", if (em.active) "Not in Edit Mode" else null);
        const remove = modButton(z, "x", 22, "Remove this modifier", null);
        z.endHorizontal();
        if (remove) {
            _ = mods.remove(a, k);
            undo.label("Remove Modifier");
            app.dirty = true;
            return;
        }
        if (apply) {
            ops.applyModifier(a, k);
            undo.label("Apply Modifier");
            app.dirty = true;
            return;
        }
        if (down) {
            _ = mods.move(a, k, 1);
            undo.label("Move Modifier");
            app.dirty = true;
            return;
        }
        if (up) {
            _ = mods.move(a, k, -1);
            undo.label("Move Modifier");
            app.dirty = true;
            return;
        }
        if (!mods.ported(d.kind)) {
            bkit.note(z, ops.not_ported);
        } else if (bad & (@as(u8, 1) << @intCast(k)) != 0) {
            const why = "This modifier failed: the mesh passes through";
            z.label(why, .{ .color = host.col(0xe06c75), .width = .fill });
            ui.record("info", why, host.rectOf(z.lastRect()), true);
        }
        for (mods.params(d.kind), 0..) |p, q| {
            z.pushIdInt(q);
            defer z.popId();
            if (p.object) {
                const ti = mods.target(d);
                var sel: usize = if (ti) |t| t + 1 else 0;
                bkit.beginCaptioned(z, "Object", 70);
                mod_pick_obj = a;
                mod_pick_k = k;
                if (bkit.choice(z, "##Object", &sel, scene.count + 1, modPickLabel, if (d.kind == mods.ARMATURE) "The armature" else "The other mesh")) {
                    mod_pick_obj = a;
                    mod_pick_k = k;
                    modPick(sel);
                }
                bkit.endCaptioned(z);
                continue;
            }
            if ((d.kind == mods.GEONODES or d.kind == mods.LOGIC) and q == 0) {
                const nt = @import("ntree.zig");
                const t1 = nt.cvtt(mods.getF(d, 0));
                var sel: usize = if (t1 >= 1 and nt.get(@intCast(t1 - 1)) != null) @intCast(t1) else 0;
                bkit.beginCaptioned(z, "Tree", 70);
                if (bkit.choice(z, "##Tree", &sel, nt.count() + 1, treePickLabel, "The node tree it runs (Node Editor: Tab switches to it)")) {
                    mod_pick_obj = a;
                    mod_pick_k = k;
                    treePick(sel);
                }
                bkit.endCaptioned(z);
                continue;
            }
            if (d.kind == mods.BOOLEAN or d.kind == mods.ARMATURE or (d.kind == mods.MIRROR and q == 0)) {
                // one of a few: buttons
                const n: usize = if (d.kind == mods.ARMATURE) 2 else 3;
                z.beginHorizontal(.{ .spacing = 2 });
                for (0..n) |c| {
                    const lb: []const u8 = if (d.kind == mods.BOOLEAN) mods.op_names[c] else if (d.kind == mods.ARMATURE) mods.arm_modes[c] else (&[_][]const u8{ "X", "Y", "Z" })[c];
                    const sel = @round(mods.getF(d, q)) == @as(f32, @floatFromInt(c));
                    if (bkit.toggle(z, lb, sel, "").clicked) {
                        mods.setF(d, q, @floatFromInt(c));
                        undo.label("Set Modifier Value");
                        app.dirty = true;
                    }
                }
                z.endHorizontal();
                continue;
            }
            var v = mods.getF(d, q);
            var lb: [16]u8 = undefined;
            const title = capital(&lb, p.name);
            z.beginGroup(.{ .width = .px(@min(240, bkit.columnWidth(z))) });
            if (bkit.numberRow(z, title, &v, .{ .step = p.step, .min = p.lo, .max = p.hi, .decimals = if (p.int) 0 else 3, .path = .{ .modifier = .{ .index = @intCast(k), .param = @intCast(q) } } }).changed) {
                mods.setF(d, q, if (p.int) @round(v) else v);
                undo.label("Set Modifier Value");
            }
            z.endGroup();
        }
        if (d.kind == mods.MULTIRES) { // Subdivide, Propagate Down
            bkit.beginPair(z);
            if (bkit.button(z, "Subdivide", "One more level of detail to sculpt on").clicked) @import("multires.zig").subdivide(a, k);
            if (bkit.button(z, "Propagate", "Pass the sculpted detail of this level down to the coarser levels").clicked) @import("multires.zig").opDown();
            bkit.endPair(z);
        }
        z.spacer(.px(4));
    }
}

fn capital(b: []u8, s: []const u8) []const u8 {
    const n = @min(b.len, s.len);
    @memcpy(b[0..n], s[0..n]);
    if (n > 0) b[0] = std.ascii.toUpper(b[0]);
    return b[0..n];
}

fn emptyTab(bd: Rect, y: i32, s: []const u8) i32 {
    _ = ui.cv.textFit(bd.x, y + 2, bd.w, s, ui.th.text_dim);
    ui.record("info", s, .{ .x = bd.x, .y = y, .w = bd.w, .h = 20 }, true);
    return y + 24;
}
var mat_h: i32 = 0;

fn drawMaterialTab(salt: usize, bd: Rect) i32 {
    var y = bd.y + 2;
    {
        var f = bkit.Flow.begin("props.mat.head", salt, bd, y);
        if (f.z) |z| matHead(z);
        y = f.end();
    }
    const a = matops.activeMesh() orelse return y;
    const o = &scene.objects[a];
    if (material.of(o) == null) return y;
    const ma_i: usize = o.mat - 1;
    const ma = &material.list[ma_i];
    // texture painting: the layer stack first
    if (paint.isTexture()) y = paintui.panel(salt, bd, y) + 8;
    if (ma.parent != 0) {
        // an instance: its parameters only (its values are the parent's: matui.s)
        return graphcmds.instanceRows(salt, bd, y, ma_i);
    }
    {
        var f = bkit.Flow.begin("props.mat.inst", salt, bd, y);
        if (f.z) |z| {
            bkit.beginPair(z);
            z.spacer(.fill);
            _ = bkit.opButton(z, "material.new_instance", .{});
            bkit.endPair(z);
            z.spacer(.px(2));
        }
        y = f.end();
    }
    // the node selected in the node editor first (then a gap)
    {
        const y1 = @import("nodeed.zig").details(salt, bd, y, ma_i);
        if (y1 != y) y = y1 + 10;
    }
    var f = bkit.Flow.begin("props.mat.body", salt, bd, y);
    if (f.z) |z| matBody(z, ma_i);
    return f.end();
}

fn matHead(z: *zui.Ui) void {
    bkit.heading(z, "Material");
    const a = matops.activeMesh() orelse return bkit.info(z, "Materials go on meshes: select a mesh object.");
    const o = &scene.objects[a];
    // the slot: which material, New
    z.beginHorizontal(.{ .spacing = 6 });
    z.beginGroup(.{ .width = .fill });
    var sel: usize = o.mat;
    if (bkit.choice(z, "##Material slot", &sel, material.count + 1, slotLabel, "The object's material (the same material can go on many objects)")) slotPick(sel);
    z.endGroup();
    _ = bkit.opButton(z, "material.new", .{ .label = "New", .width = .px(60) });
    z.endHorizontal();
    // a preset, a texture set
    bkit.beginPair(z);
    z.beginGroup(.{ .width = .fill });
    var preset: usize = 0;
    const PresetMenu = struct {
        fn label(k: usize) []const u8 {
            return if (k == 0) "Preset..." else presetLabel(k - 1);
        }
    };
    if (bkit.choice(z, "##Preset", &preset, material.presets.len + 1, PresetMenu.label, "A preset look: metals, glass, plastics, wood, marble and more (a new material when there is none)") and preset > 0) presetPick(preset - 1);
    z.endGroup();
    _ = bkit.opButton(z, "material.import_textures", .{ .label = "Texture Set..." });
    bkit.endPair(z);
    if (material.of(o) == null) bkit.info(z, "No material: the object's colour is used. New makes one.");
    z.spacer(.px(2));
}

fn matBody(z: *zui.Ui, ma_i: usize) void {
    const ma = &material.list[ma_i];
    if (ma.nodes() > 0) bkit.info(z, "Driven by its node graph where linked.");
    const before = std.mem.toBytes(ma.*);
    // colours: the copies follow the material unless the picker edits them
    const cp = @import("colorpick.zig");
    if (!cp.open or mt_pick != ma_i) {
        mt_base_col = material.toSrgb(ma.base);
        mt_emit_col = material.toSrgb(ma.emission);
    }
    mt_pick = ma_i;
    const path: @import("wg.zig").Path = .{ .material = ma.nameOf() };
    _ = bkit.colourRow(z, "Base colour", &mt_base_col, matBaseChanged, "The surface colour (a click opens the colour picker)");
    const Row = struct { p: *f32, l: []const u8, step: f32, lo: f32, hi: f32, slider: bool, dec: u8, tip: []const u8, gap_after: f32 = 0 };
    const rows1 = [_]Row{
        .{ .p = &ma.metallic, .l = "Metallic", .step = 0.005, .lo = 0, .hi = 1, .slider = true, .dec = 3, .tip = "0: plastic, wood, paint ... 1: bare metal" },
        .{ .p = &ma.roughness, .l = "Roughness", .step = 0.005, .lo = 0, .hi = 1, .slider = true, .dec = 3, .tip = "0: a mirror finish, 1: matte" },
        .{ .p = &ma.specular, .l = "Specular", .step = 0.005, .lo = 0, .hi = 1, .slider = true, .dec = 3, .tip = "How strongly non-metals reflect (0.5 for most)" },
        .{ .p = &ma.ior, .l = "IOR", .step = 0.005, .lo = 1, .hi = 3, .slider = false, .dec = 3, .tip = "Index of refraction: water 1.33, glass 1.5, diamond 2.42" },
        .{ .p = &ma.transmission, .l = "Transmission", .step = 0.005, .lo = 0, .hi = 1, .slider = true, .dec = 3, .tip = "Light passing through (glass, water)", .gap_after = 6 },
    };
    const rows2 = [_]Row{
        .{ .p = &ma.strength, .l = "Emission strength", .step = 0.05, .lo = 0, .hi = 1000, .slider = false, .dec = 2, .tip = "How bright the emission is (0: none)", .gap_after = 6 },
        .{ .p = &ma.coat, .l = "Clear coat", .step = 0.005, .lo = 0, .hi = 1, .slider = true, .dec = 3, .tip = "A clear varnish layer on top" },
        .{ .p = &ma.coat_rough, .l = "Coat roughness", .step = 0.005, .lo = 0, .hi = 1, .slider = true, .dec = 3, .tip = "How rough the clear coat is" },
        .{ .p = &ma.alpha, .l = "Alpha", .step = 0.005, .lo = 0, .hi = 1, .slider = true, .dec = 3, .tip = "Opacity: 0 invisible, 1 solid" },
        .{ .p = &ma.density, .l = "Density (g/cm3)", .step = 0.01, .lo = 0, .hi = 25, .slider = false, .dec = 3, .tip = "For mass properties: water 1, aluminium 2.7, steel 7.85", .gap_after = 6 },
    };
    for ([_][]const Row{ &rows1, &rows2 }, 0..) |rows, part| {
        if (part == 1) _ = bkit.colourRow(z, "Emission", &mt_emit_col, matEmitChanged, "The colour of light it gives off");
        for (rows) |row| {
            if (bkit.numberRow(z, row.l, row.p, .{ .step = row.step, .min = row.lo, .max = row.hi, .slider = row.slider, .decimals = row.dec, .tip = row.tip, .path = path }).changed) undo.label("Material");
            if (row.gap_after > 0) z.spacer(.px(row.gap_after - 4));
        }
    }
    // blend mode, one-sided, the mask clip
    var bi: usize = @intFromFloat(std.math.clamp(ma.blend, 0, 2));
    bkit.beginCaptioned(z, "Blend mode", 100);
    if (bkit.choice(z, "##Blend mode", &bi, 3, blendLabel, "Opaque, Masked (holes where the opacity mask is below the clip value) or Translucent (light through by its opacity)")) blendPick(bi);
    bkit.endCaptioned(z);
    var sided = ma.one_sided >= 0.5;
    if (bkit.checkRow(z, "One-sided", &sided, "").changed) {
        ma.one_sided = if (sided) 1 else 0;
        undo.label("Material");
    }
    if (bi == 1) {
        if (bkit.numberRow(z, "Mask clip", &ma.clip, .{ .step = 0.005, .min = 0, .max = 1, .slider = true, .tip = "Masked: the opacity below which the surface is a hole (0 means 1/3)" }).changed) undo.label("Material");
    }
    // a texture: graphcmds' row in the place it is given
    z.spacer(.px(2));
    bkit.beginCaptioned(z, "Texture", 100);
    const tr = z.placeSized(.fill, .px(22), .{ .x = 100, .y = 22 });
    bkit.endCaptioned(z);
    graphcmds.textureRow(@truncate(ma_i *% 2654435761 +% 77), host.rectOf(tr), ma_i);
    z.spacer(.px(2));
    _ = bkit.opButton(z, "material.bake_active", .{ .label = "Bake to Maps..." });
    if (!std.mem.eql(u8, &before, &std.mem.toBytes(ma.*))) material.version +%= 1;
}

// --- the Render tab (rnui.s) ------------------------------------------------------------

var render_h: i32 = 0;
fn drawRenderTab(salt: usize, bd: Rect) i32 {
    var f = bkit.Flow.begin("props.render", salt, bd, bd.y + 2);
    if (f.z) |z| renderDescribe(z);
    const y = f.end();
    return @import("world.zig").panel(salt, bd, @import("vgdraw.zig").panel(salt, bd, @import("bakeui.zig").draw(salt, bd, y + 8)));
}

fn renderDescribe(z: *zui.Ui) void {
    const rn = @import("render.zig");
    bkit.heading(z, "Render");
    _ = bkit.numberRow(z, "Width", &rn.width, .{ .step = 4, .min = 1, .max = 8192, .decimals = 0, .tip = "The render's width in pixels" });
    _ = bkit.numberRow(z, "Height", &rn.height, .{ .step = 4, .min = 1, .max = 8192, .decimals = 0, .tip = "The render's height in pixels" });
    _ = bkit.numberRow(z, "Samples", &rn.samples, .{ .step = 1, .min = 1, .max = 65536, .decimals = 0, .tip = "Paths per pixel: more is smoother and slower" });
    var dn = rn.denoise;
    if (bkit.checkRow(z, "Denoise", &dn, "").changed) ops.runId("render.denoise");
    z.spacer(.px(2));
    _ = bkit.opButton(z, "render.start", .{ .label = "Render (F12)", .primary = true, .tip = "Render the scene progressively in a Render area (Esc stops)" });
    _ = bkit.opButton(z, "render.save", .{});
    z.spacer(.px(2));
    const pt = @import("pt.zig");
    _ = bkit.numberRow(z, "Bounces", &pt.bounces, .{ .step = 0.1, .min = 1, .max = 12, .decimals = 0, .tip = "How many times light may bounce on its way to the camera" });
    z.spacer(.px(2));
    // Device: Auto, GPU (RTX), GPU, CPU
    const gpu = @import("gpu.zig");
    z.beginHorizontal(.{ .spacing = 2 });
    z.label("Device", .{ .width = .px(50) });
    const devs = [_]gpu.Device{ .auto, .rtx, .gpu, .cpu };
    for (devs) |d| {
        const lab: []const u8 = if (d == .rtx) "RTX" else d.label();
        if (bkit.toggle(z, lab, gpu.device == d, "Where renders run: the best there is, ray queries, the GPU's compute path, or the CPU").clicked) rn.setDevice(d);
    }
    z.endHorizontal();
    var lb: [96]u8 = undefined;
    bkit.info(z, rn.deviceLine(&lb));
}

fn edProperties(i: i16, r: Rect) void {
    const th = ui.th;
    const cv = ui.cv;
    const n = app.N(i);
    const salt: usize = @intCast(i);
    cv.fill(r, th.pane_bg);
    // icon tabs down the left side
    const strip = Rect{ .x = r.x, .y = r.y, .w = 28, .h = r.h };
    cv.fill(strip, th.menu_bg);
    // (a tab the port has not, from a file: Object shows, the file keeps its own)
    const has_land = @import("landui.zig").active() != null;
    const shown_tab: u8 = if (n.tab >= tabs.len or !tabs[n.tab].ported or (n.tab == TAB_LAND and !has_land)) 0 else n.tab;
    propsTabs(salt, r, n, shown_tab, has_land);
    const bd = Rect{ .x = r.x + 36, .y = r.y + 6, .w = r.w - 44, .h = r.h - 6 };
    const y = bd.y;

    switch (shown_tab) {
        0 => objectTab(salt, r, bd),
        TAB_MATERIAL => {
            // taller than the panel: it scrolls
            const view = Rect{ .x = r.x, .y = bd.y, .w = r.w, .h = bd.h };
            if (ui.hit and ui.wheel != 0 and ui.inside(view)) n.scroll -= @intFromFloat(ui.wheel * 30);
            n.scroll = std.math.clamp(n.scroll, 0, @max(0, mat_h - (bd.h - 6)));
            const old = cv.setClip(view);
            defer cv.clip = old;
            ui.mask = view;
            defer ui.mask = null;
            var sb = bd;
            sb.y -= n.scroll;
            mat_h = drawMaterialTab(salt, sb) - sb.y;
            pageBar(ui.id(@src(), salt), r, &n.scroll, mat_h + 20);
        },
        TAB_MODS => {
            // taller than the panel with a long stack: it scrolls
            const view = Rect{ .x = r.x, .y = bd.y, .w = r.w, .h = bd.h };
            const room = bd.h - 6;
            if (ui.hit and ui.wheel != 0 and ui.inside(view)) n.scroll -= @intFromFloat(ui.wheel * 30);
            n.scroll = std.math.clamp(n.scroll, 0, @max(0, mods_h - room));
            const old = cv.setClip(view);
            defer cv.clip = old;
            ui.mask = view;
            defer ui.mask = null;
            var sb = bd;
            sb.y -= n.scroll;
            mods_h = drawModsTab(salt, sb) - sb.y;
        },
        TAB_RENDER => {
            // taller than the panel: it scrolls
            const view = Rect{ .x = r.x, .y = bd.y, .w = r.w, .h = bd.h };
            if (ui.hit and ui.wheel != 0 and ui.inside(view)) n.scroll -= @intFromFloat(ui.wheel * 30);
            n.scroll = std.math.clamp(n.scroll, 0, @max(0, render_h - (bd.h - 6)));
            const old = cv.setClip(view);
            defer cv.clip = old;
            ui.mask = view;
            defer ui.mask = null;
            var sb = bd;
            sb.y -= n.scroll;
            render_h = drawRenderTab(salt, sb) - sb.y;
        },
        TAB_SCENE => {
            var f = bkit.Flow.begin("props.scene", salt, bd, y);
            if (f.z) |z| sceneTab(z);
            _ = f.end();
        },
        TAB_ANIMATION => _ = @import("animui.zig").props(i, bd, y),
        TAB_RIG => _ = @import("rigui.zig").props(i, bd, y),
        TAB_PHYS => {
            // (as the CAD tab: the original's column, physui.zig; it scrolls)
            const view = Rect{ .x = r.x, .y = bd.y, .w = r.w, .h = bd.h };
            if (ui.hit and ui.wheel != 0 and ui.inside(view)) n.scroll -= @intFromFloat(ui.wheel * 30);
            n.scroll = std.math.clamp(n.scroll, 0, @max(0, phys_h + 20 - r.h));
            const old = cv.setClip(view);
            defer cv.clip = old;
            ui.mask = view;
            defer ui.mask = null;
            var sb = Rect{ .x = bd.x + 9, .y = r.y + 8, .w = r.right() - 14 - (bd.x + 9), .h = bd.h };
            sb.y -= n.scroll;
            phys_h = @import("physui.zig").props(i, sb, sb.y) - sb.y;
            pageBar(ui.id(@src(), salt), r, &n.scroll, phys_h + 20);
        },
        TAB_PART => {
            // (partui.zig: the original's column, as the Physics tab; it scrolls)
            const view = Rect{ .x = r.x, .y = bd.y, .w = r.w, .h = bd.h };
            if (ui.hit and ui.wheel != 0 and ui.inside(view)) n.scroll -= @intFromFloat(ui.wheel * 30);
            n.scroll = std.math.clamp(n.scroll, 0, @max(0, part_h + 20 - r.h));
            const old = cv.setClip(view);
            defer cv.clip = old;
            ui.mask = view;
            defer ui.mask = null;
            var sb = Rect{ .x = bd.x + 9, .y = r.y + 8, .w = r.right() - 14 - (bd.x + 9), .h = bd.h };
            sb.y -= n.scroll;
            part_h = @import("partui.zig").props(i, sb, sb.y) - sb.y;
            pageBar(ui.id(@src(), salt), r, &n.scroll, part_h + 20);
        },
        TAB_LAND => {
            // (landui.zig: the original's column, as the Particles tab; it scrolls)
            const view = Rect{ .x = r.x, .y = bd.y, .w = r.w, .h = bd.h };
            if (ui.hit and ui.wheel != 0 and ui.inside(view)) n.scroll -= @intFromFloat(ui.wheel * 30);
            n.scroll = std.math.clamp(n.scroll, 0, @max(0, land_h + 20 - r.h));
            const old = cv.setClip(view);
            defer cv.clip = old;
            ui.mask = view;
            defer ui.mask = null;
            var sb = Rect{ .x = bd.x + 9, .y = r.y + 8, .w = r.right() - 14 - (bd.x + 9), .h = bd.h };
            sb.y -= n.scroll;
            land_h = @import("landui.zig").props(i, sb, sb.y) - sb.y;
            pageBar(ui.id(@src(), salt), r, &n.scroll, land_h + 20);
        },
        TAB_CAD => {
            // taller than the panel with many parameters: it scrolls
            const view = Rect{ .x = r.x, .y = bd.y, .w = r.w, .h = bd.h };
            if (ui.hit and ui.wheel != 0 and ui.inside(view)) n.scroll -= @intFromFloat(ui.wheel * 30);
            n.scroll = std.math.clamp(n.scroll, 0, @max(0, cad_h + 20 - r.h)); // (wg_scroll_end: from 8 above the column to 12 below it)
            const old = cv.setClip(view);
            defer cv.clip = old;
            ui.mask = view;
            defer ui.mask = null;
            // (the original's column, pnl_begin: the page beside the tabs less 14 a
            // side; the page starts 8 down)
            var sb = Rect{ .x = bd.x + 9, .y = r.y + 8, .w = r.right() - 14 - (bd.x + 9), .h = bd.h };
            sb.y -= n.scroll;
            cad_h = @import("cadui.zig").props(i, sb, sb.y) - sb.y;
            pageBar(ui.id(@src(), salt), r, &n.scroll, cad_h + 20);
        },
        TAB_VIEWPORT => {
            var f = bkit.Flow.begin("props.viewport", salt, bd, y);
            if (f.z) |z| viewportTab(z);
            _ = f.end();
        },
        else => {},
    }
}

/// The icon tabs down the left side of the Properties editor, on Zui.
fn propsTabs(salt: usize, r: Rect, n: anytype, shown_tab: u8, has_land: bool) void {
    const z = host.beginPart("props.tabs", salt, .{ .x = r.x + 3, .y = r.y + 4, .w = 22, .h = r.h - 4 }) orelse return;
    defer host.endPart(z);
    z.beginGroup(.{ .spacing = 2 });
    defer z.endGroup();
    for (tabs, 0..) |t, k| {
        if (k == TAB_LAND and !has_land) break; // (only for a landscape)
        z.pushIdInt(k);
        defer z.popId();
        const sel = shown_tab == k;
        z.pushDisabled(if (t.ported) null else ops.not_ported);
        if (sel) z.pushColor(.button_active, host.col(ui.th.accent_dark));
        const b = z.button("##tab", .{ .icon = host.icon(t.ic), .width = .px(22), .height = .px(22), .variant = if (sel) .selected else .flat });
        if (sel) z.popStyle();
        z.popDisabled();
        ui.record("tab", t.name, host.rectOf(b.rect), t.ported);
        const by_ring = bkit.ring(b, t.name);
        z.tooltipRich(b, .{ .title = t.name, .body = "A tab of the Properties editor", .warning = if (t.ported) "" else ops.not_ported });
        if ((b.clicked or by_ring) and t.ported) n.tab = @intCast(k);
    }
}

const cap_w: f32 = 70;

fn objectTab(salt: usize, r: Rect, bd: Rect) void {
    var y = bd.y;
    {
        var f = bkit.Flow.begin("props.obj", salt, bd, y);
        if (f.z) |z| objectHead(z);
        y = f.end();
    }
    const s = scene.active orelse return;
    const o = &scene.objects[s];
    const label_w: i32 = 76;
    if (o.kind == .sketch) y = @import("sketchui.zig").propRows(bd.x, bd.x + label_w, bd.right(), y, s);
    if (@import("curve.zig").cvOf(s) != null) y = @import("curveui.zig").props(salt, s, bd.x, r.right() - 14 - bd.x, y);
    if (o.kind == .light or o.kind == .camera) y = lcamProps(salt, s, bd.x, r.right() - 14 - bd.x, y);
    if (o.ref != 0) {
        var f = bkit.Flow.begin("props.obj.ref", salt, bd, y);
        var open = sec_open[14];
        if (f.z) |z| open = bkit.section(z, "Reference image", &sec_open[14]);
        y = f.end();
        if (open) y = @import("refimg.zig").props(salt, s, bd, y, label_w);
    }
    if (@import("text3d.zig").txOf(s) != null) y = @import("textui.zig").props(salt, s, bd.x, r.right() - 14 - bd.x, y); // (its text: textui.zig)
    {
        var f = bkit.Flow.begin("props.obj.info", salt, bd, y);
        if (f.z) |z| {
            var buf: [64]u8 = undefined;
            if (o.kind == .sketch) {
                // (its rows above: the lines it shows are no mesh)
            } else if (scene.meshOfObj(s)) |me| {
                bkit.infoPair(z, "Mesh", std.fmt.bufPrint(&buf, "{d} v, {d} e, {d} f", .{ me.verts.len, me.edges, me.faces() }) catch "", cap_w);
            } else {
                bkit.infoPair(z, "Type", o.kind.label(), cap_w);
            }
            z.spacer(.px(4));
        }
        y = f.end();
    }
    // its Print Check findings (print.zig)
    if (scene.meshOfObj(s) != null) y = @import("print.zig").props(salt, s, bd, y);
    var f = bkit.Flow.begin("props.obj.ops", salt, bd, y);
    if (f.z) |z| {
        z.beginHorizontal(.{ .spacing = 6 });
        _ = bkit.opButton(z, "object.delete", .{ .width = .px(@min(120, (bkit.columnWidth(z) - 6) / 2)) });
        _ = bkit.opButton(z, "object.duplicate", .{ .width = .px(@min(120, (bkit.columnWidth(z) - 6) / 2)) });
        z.endHorizontal();
    }
    _ = f.end();
}

fn objectHead(z: *zui.Ui) void {
    const s = scene.active orelse return bkit.info(z, "Nothing selected");
    const o = &scene.objects[s];
    if (bkit.textRow(z, "##Name", o.name(), "Name")) |nm| {
        const t = std.mem.trim(u8, nm, " ");
        if (t.len > 0) o.setName(t);
        undo.label("Rename");
    }
    // (BeeModel's compact vector rows: fields 19 high, a row each 21)
    z.beginGroup(.{ .width = .fill, .spacing = 1 });
    z.pushMetric(.frame_padding, .{ .x = 8, .y = -0.5 });
    const rows = [_]struct { l: []const u8, v: *m.V3, step: f32, suf: []const u8 }{
        .{ .l = "Location", .v = &o.loc, .step = 0.02, .suf = " m" },
        .{ .l = "Rotation", .v = &o.rot, .step = 1.0, .suf = "°" },
        .{ .l = "Scale", .v = &o.scl, .step = 0.01, .suf = "" },
    };
    for (rows, 0..) |row, ri| {
        bkit.beginCaptioned(z, row.l, cap_w);
        var v: [3]f32 = .{ row.v[0], row.v[1], row.v[2] };
        if (bkit.vec3Row(z, row.l, &v, .{
            .step = row.step,
            .decimals = 3,
            .suffix = row.suf,
            .tip = "Drag to change (Shift finer, Ctrl in steps), Ctrl+wheel steps, click to type a value or an expression (25cm, 2*pi)",
            .path = .{ .transform = @intCast(ri * 3) },
            .def = if (ri == 2) 1 else 0,
        })) {
            for (0..3) |c| row.v[c] = v[c];
            undo.label(row.l);
        }
        bkit.endCaptioned(z);
    }
    z.popStyle();
    z.endGroup();
    z.spacer(.px(2));
    // the parent: a list of the objects it can follow
    bkit.beginCaptioned(z, "Parent", cap_w);
    parent_of = s;
    var sel: usize = if (o.parent) |p| p + 1 else 0;
    if (bkit.choice(z, "##Parent", &sel, scene.count + 1, parentLabel, "The object it follows: it keeps where it is, then moves, turns and scales with it (Ctrl+P, Alt+P)")) {
        parent_of = s;
        parentPick(sel);
    }
    bkit.endCaptioned(z);
    z.spacer(.px(2));
    if (bkit.checkRow(z, "Visible", &o.visible, "").changed) {
        if (!o.visible) o.selected = false;
        undo.label("Visible");
    }
    _ = bkit.colourRow(z, "Colour", &o.color, null, "");
    z.spacer(.px(4));
}

fn sceneTab(z: *zui.Ui) void {
    const th = ui.th;
    if (bkit.section(z, "Theme", &sec_open[2])) {
        const cols: usize = @intFromFloat(@max(1, @floor((bkit.columnWidth(z) + 6) / 156)));
        var k: usize = 0;
        while (k < theme.all.len) {
            z.beginHorizontal(.{ .spacing = 6 });
            var c: usize = 0;
            while (c < cols) : (c += 1) {
                if (k + c >= theme.all.len) {
                    z.spacer(.fill);
                    continue;
                }
                const t = theme.all[k + c];
                const tr = z.placeSized(.fill, .px(24), .{ .x = 100, .y = 24 });
                const it = z.interact(z.id(t.name), tr);
                const on = theme.base == t;
                z.drawRect(.{ .rect = tr, .fill = host.col(if (on) th.accent_dark else if (it.hovered) th.btn_hover else th.btn), .radius = 4 });
                // a strip of the theme's colours
                const sw = [_]u32{ t.pane_bg, t.pane_hdr, t.accent, t.text };
                for (sw, 0..) |sc, ci| z.drawRect(.{ .rect = .{ .x = tr.x + 6 + @as(f32, @floatFromInt(ci)) * 7, .y = tr.y + 7, .w = 6, .h = 10 }, .fill = host.col(sc) });
                z.pushClip(.{ .x = tr.x + 36, .y = tr.y, .w = @max(0, tr.w - 38), .h = tr.h });
                z.drawText(.{ .x = tr.x + 36, .y = tr.y + 4 }, host.col(if (on) th.accent_fg else th.text), t.name);
                z.popClip();
                ui.record("theme", t.name, host.rectOf(tr), true);
                if (it.clicked) app.setTheme(t);
            }
            z.endHorizontal();
            k += cols;
        }
        z.spacer(.px(4));
    }
    if (bkit.section(z, "World", &sec_open[8])) {
        const env = @import("env.zig");
        const images = @import("images.zig");
        bkit.beginCaptioned(z, "Sky", cap_w);
        var sky: usize = env.idx;
        if (bkit.choice(z, "##Sky", &sky, images.count + 1, worldLabel, "An equirectangular image lights the scene (image.load first)")) worldPick(sky);
        bkit.endCaptioned(z);
        z.beginGroup(.{ .width = .px(@min(160, bkit.columnWidth(z))) });
        if (bkit.button(z, "Load Image...", "A PNG, JPEG or Radiance HDR image").clicked) ops.runId("image.load");
        z.endGroup();
        z.beginGroup(.{ .width = .px(@min(240, bkit.columnWidth(z))) });
        if (bkit.numberRow(z, "Strength", &env.strength, .{ .step = 0.01, .min = 0, .max = 100, .decimals = 2 }).changed) app.dirty = true;
        var deg = env.rotation * 180 / std.math.pi;
        if (bkit.numberRow(z, "Rotation", &deg, .{ .step = 1, .min = -360, .max = 360, .decimals = 1, .suffix = "°" }).changed) {
            env.rotation = deg * std.math.pi / 180;
            app.dirty = true;
        }
        z.endGroup();
        z.spacer(.px(4));
    }
    if (bkit.section(z, "Frames", &sec_open[15])) {
        z.beginGroup(.{ .width = .px(@min(240, bkit.columnWidth(z))) });
        if (bkit.numberRow(z, "Start frame", &frange.r.start, .{ .step = 1, .min = -100000, .max = 100000, .decimals = 0, .tip = "The first frame of the animation" }).changed) {
            frange.r.end = @max(frange.r.start, frange.r.end);
            undo.label("Frame Range");
        }
        if (bkit.numberRow(z, "End frame", &frange.r.end, .{ .step = 1, .min = -100000, .max = 100000, .decimals = 0, .tip = "The last frame of the animation" }).changed) {
            frange.r.start = @min(frange.r.start, frange.r.end);
            undo.label("Frame Range");
        }
        if (bkit.numberRow(z, "Frame rate", &frange.r.fps, .{ .step = 1, .min = 1, .max = 1000, .decimals = 0, .tip = "Frames per second" }).changed) undo.label("Frame Range");
        z.endGroup();
        z.spacer(.px(4));
    }
    if (bkit.section(z, "Scene", &sec_open[3])) {
        var buf: [64]u8 = undefined;
        bkit.infoPair(z, "Objects", std.fmt.bufPrint(&buf, "{d} of {d}", .{ scene.count, scene.max_objects }) catch "", cap_w);
        bkit.infoPair(z, "Faces", std.fmt.bufPrint(&buf, "{d}", .{scene.faceCount()}) catch "", cap_w);
        bkit.infoPair(z, "Units", "Metres", cap_w);
    }
}

fn viewportTab(z: *zui.Ui) void {
    const vi = app.viewportArea();
    if (bkit.section(z, "Viewport", &sec_open[4])) {
        if (vi < 0) return bkit.info(z, "No 3D viewport in this workspace");
        const v = &app.N(vi).view;
        bkit.beginPair(z);
        if (bkit.toggle(z, "Solid", !v.wire, "Solid shading").clicked) {
            v.wire = false;
            v.material = false;
            v.rendered = false;
        }
        if (bkit.toggle(z, "Wireframe", v.wire, "Wireframe shading (Z)").clicked) {
            v.wire = true;
            v.material = false;
            v.rendered = false;
        }
        bkit.endPair(z);
        _ = bkit.checkRow(z, "Ground grid", &scene.show_grid, "");
        _ = bkit.checkRow(z, "Orthographic", &v.ortho, "");
        z.spacer(.px(2));
        const vals = [_]struct { l: []const u8, v: *f32, step: f32, suf: []const u8, lo: f32, hi: f32 }{
            .{ .l = "Yaw", .v = &v.yaw, .step = 1, .suf = "°", .lo = -1e9, .hi = 1e9 },
            .{ .l = "Pitch", .v = &v.pitch, .step = 1, .suf = "°", .lo = -89.9, .hi = 89.9 },
            .{ .l = "Distance", .v = &v.dist, .step = 0.1, .suf = " m", .lo = 0.5, .hi = 500 },
            .{ .l = "Lens (FOV)", .v = &vp.fov, .step = 0.5, .suf = "°", .lo = 5, .hi = 140 },
        };
        for (vals) |vv| {
            if (bkit.numberRow(z, vv.l, vv.v, .{ .step = vv.step, .suffix = vv.suf, .min = vv.lo, .max = vv.hi, .decimals = 2 }).changed) vp.leaveCamView(v);
        }
        v.pitch = std.math.clamp(v.pitch, -89.9, 89.9);
        v.dist = std.math.clamp(v.dist, 0.5, 500);
        vp.fov = std.math.clamp(vp.fov, 5, 140);
        z.spacer(.px(4));
    }
    if (bkit.section(z, "Overlays", &sec_open[5])) {
        if (vi < 0) return;
        const v = &app.N(vi).view;
        _ = bkit.checkRow(z, "Text in the corner", &v.show_text, "");
        _ = bkit.checkRow(z, "Statistics", &v.show_stats, "");
        _ = bkit.checkRow(z, "Navigation gizmo", &v.show_gizmo, "");
    }
}

fn worldLabel(k: usize) []const u8 {
    return if (k == 0) "Studio sky" else @import("images.zig").nameOf(k - 1);
}
fn worldChecked(k: usize) bool {
    return @import("env.zig").idx == k;
}
fn worldPick(k: usize) void {
    @import("env.zig").idx = @intCast(k);
    app.dirty = true;
}

var parent_of: usize = 0;

fn parentLabel(k: usize) []const u8 {
    return if (k == 0) "None" else scene.objects[k - 1].name();
}
fn parentChecked(k: usize) bool {
    if (parent_of >= scene.count) return false;
    const p = scene.objects[parent_of].parent;
    return if (k == 0) p == null else (p != null and p.? == k - 1);
}
fn parentPick(k: usize) void {
    if (parent_of >= scene.count) return;
    if (k == 0) {
        _ = scene.setParent(parent_of, null);
    } else if (k - 1 == parent_of or !scene.setParent(parent_of, k - 1)) {
        app.toast(.warn, "Parent: {s} cannot follow itself or what is below it", .{scene.objects[parent_of].name()});
        return;
    }
    undo.label("Parent");
}

fn opButton(wid: u32, r: Rect, id: []const u8) void {
    opButtonL(wid, r, id, null);
}

/// An operator's button with a label of its own (the original's WK_BUTTON labels).
pub fn opButtonL(wid: u32, r: Rect, id: []const u8, label: ?[]const u8) void {
    opButtonX(wid, r, id, label, false);
}

/// The same, the primary (orange) button: the original's WGF_PRIMARY.
pub fn opButtonX(wid: u32, r: Rect, id: []const u8, label: ?[]const u8, primary: bool) void {
    const oi = ops.byId(id) orelse return;
    const e = &cat.entries[oi];
    const why = ops.reason(oi);
    if (ui.button(wid, r, label orelse e.label, .{ .enabled = why == null, .tip = e.doc, .why = why, .selected = primary })) {
        ui.active = 0;
        ops.run(oi);
    }
}

// --- console ---------------------------------------------------------------------

/// The command line's Zui id (of the console last described).
var console_zid: zui.Id = .none;
var history: zui.History = .{};
var cmd_buf: [512]u8 = undefined;
var cmd_len: usize = 0;
var view_st: zui.TextViewState = .{};

pub fn focusConsole() void {
    // a console in this workspace (one is opened when there is none)
    if (!app.hasEditor(.console)) app.togglePane(.console);
    pending_focus = true;
    host.focusSoon();
}

var pending_focus = false;
/// The console's Enter is running a command.
pub var in_command = false;
var prefill_buf: [240]u8 = undefined;
var prefill_len: usize = 0;

/// The command line, with this typed on it (F9).
pub fn prefillConsole(s: []const u8) void {
    prefill_len = @min(s.len, prefill_buf.len);
    @memcpy(prefill_buf[0..prefill_len], s[0..prefill_len]);
    focusConsole();
}

/// The command line is being typed in.
pub fn consoleTyping() bool {
    return console_zid != .none and host.get().focused == console_zid;
}

/// Tab in the command line (textfield.s): the operator ids that start with
/// what was typed when Tab was first pressed (63 bytes of it), one a press,
/// in the original's order, round again at the end; none: it stays.
var tab_last: ?usize = null;
var tab_prefix: [63]u8 = undefined;
var tab_plen: usize = 0;

fn consoleComplete(_: ?*anyopaque, text: []const u8, out: []u8) ?usize {
    // (still the last completion: the next one; else what is typed is the prefix)
    const going_on = if (tab_last) |l| std.mem.eql(u8, text, cat.entries[l].id) else false;
    if (!going_on) {
        tab_last = null;
        tab_plen = @min(text.len, tab_prefix.len);
        @memcpy(tab_prefix[0..tab_plen], text[0..tab_plen]);
    }
    var k: usize = if (tab_last) |l| l + 1 else 0;
    var wrapped = false;
    while (true) {
        if (k >= cat.entries.len) {
            if (wrapped) return null;
            wrapped = true;
            k = 0;
        }
        if (std.mem.startsWith(u8, cat.entries[k].id, tab_prefix[0..tab_plen])) break;
        k += 1;
    }
    tab_last = k;
    const id = cat.entries[k].id;
    const n = @min(id.len, out.len);
    @memcpy(out[0..n], id[0..n]);
    return n;
}

/// The log, as Zui's text view reads it: commands in the accent, warnings
/// ("! ") in the warning colour.
const LogSource = struct {
    total: u64,

    pub fn len(_: *const LogSource) usize {
        return app.log_count - app.logFirst();
    }

    pub fn line(_: *const LogSource, i: usize) zui.TextLine {
        const l = app.logLine(app.logFirst() + i);
        const th = ui.th;
        const c: ?zui.Color = if (l.len > 0 and l[0] == '>') host.col(th.accent) else if (l.len > 1 and l[0] == '!' and l[1] == ' ') host.col(th.warn) else null;
        return .{ .text = l, .color = c };
    }
};

fn edConsole(i: i16, r: Rect) void {
    const th = ui.th;
    const z = host.beginPart("console", @intCast(i), r) orelse return;
    defer host.endPart(z);
    z.drawRect(.{ .rect = host.zr(r), .fill = host.col(th.pane_bg) });
    z.beginVertical(.{ .width = .fill, .height = .fill, .padding = 6, .spacing = 6 });
    defer z.endVertical();
    var src: LogSource = .{ .total = app.log_count };
    z.pushColor(.input, host.col(th.pane_bg));
    _ = z.textView("##log", &src, &view_st, .{ .font = host.monoFont() });
    z.popStyle();
    const cid = z.id("##console");
    console_zid = cid;
    const focus_now = pending_focus;
    if (pending_focus) {
        pending_focus = false;
        const n = @min(prefill_len, cmd_buf.len);
        @memcpy(cmd_buf[0..n], prefill_buf[0..n]);
        cmd_len = n;
        prefill_len = 0;
        z.setFocus(cid);
        z.requestRedraw();
    }
    z.pushFont(host.monoFont());
    const res = z.consoleInput("##console", &cmd_buf, &cmd_len, &history, .{ .hint = "> Enter: type a command or BeeScript (Tab completes, Up = history)", .complete = .{ .complete = consoleComplete } });
    z.popFont();
    if (focus_now) {
        // (typing goes on after what is there, rather than replacing it)
        z.text_edit.caret = cmd_len;
        z.text_edit.anchor = cmd_len;
    }
    if (res.submitted) {
        var copy: [512]u8 = undefined;
        const n = cmd_len;
        @memcpy(copy[0..n], cmd_buf[0..n]);
        cmd_len = 0;
        tab_last = null;
        in_command = true;
        runCommand(copy[0..n]);
        in_command = false;
        // (the log at its end again)
        view_st.at_bottom = true;
        view_st.seen_total = 0;
    }
}

/// An operator id and its argument, as the console and BeeScript's op() run
/// it: file paths, mesh tools' numbers, then any operator. False: no such
/// operator.
pub fn runOpLine(verb: []const u8, arg: []const u8) bool {
    // file commands take a path, as in the original (~ is the home folder);
    // like its run_op they never ask "Save changes?" (its menus and keys do)
    const files = @import("files.zig");
    const bs = @import("bscript.zig");
    if (arg.len > 0 and (eq(verb, "file.open") or eq(verb, "file.save") or eq(verb, "file.save_as"))) {
        if (eq(verb, "file.open")) files.unguarded(.recent, arg) else files.saveTo(arg);
        if (ops.byId(verb)) |oi| bs.macroOpArg(oi, arg);
        return true;
    }
    if (std.mem.eql(u8, verb, "file.new")) {
        files.unguarded(.new, "");
        bs.macroOpArg(ops.byId(verb).?, "");
        return true;
    }
    // mesh tools with numbers, as the original's scripts take them
    if (eq(verb, "mesh.bisect") or eq(verb, "mesh.spin") or eq(verb, "mesh.loopcut") or eq(verb, "mesh.merge_distance") or eq(verb, "mesh.bevel")) {
        var nums: [6]f32 = undefined;
        var nn: usize = 0;
        var axis: u2 = 1;
        var it2 = std.mem.tokenizeAny(u8, arg, " \"");
        while (it2.next()) |t| {
            if (eq(t, "x")) axis = 0 else if (eq(t, "y")) axis = 1 else if (eq(t, "z")) axis = 2 else if (nn < nums.len) {
                nums[nn] = expr.eval(t) orelse {
                    app.log("not a number: {s}", .{t});
                    return true;
                };
                if (!std.math.isFinite(nums[nn])) {
                    app.log("not a finite number: {s}", .{t});
                    return true;
                }
                nn += 1;
            }
        }
        const mo2 = @import("meshops2.zig");
        if (!em.active) {
            app.log("{s}: only in edit mode (Tab)", .{verb});
            return true;
        }
        const rd = @import("redo.zig");
        rd.before();
        defer if (eq(verb, "mesh.bevel") and nn >= 1) rd.set(.bevel, &.{ nums[0], if (nn >= 2) std.math.clamp(@round(nums[1]), 1, 32) else 1 }) else if (eq(verb, "mesh.merge_distance")) rd.set(.merge_distance, &.{if (nn >= 1) nums[0] else 0.0001}) else if (eq(verb, "mesh.spin")) rd.set(.spin, &.{ if (nn >= 1) std.math.clamp(@round(nums[0]), 1, 256) else 12, if (nn >= 2) nums[1] else 360, @floatFromInt(axis) }) else if (eq(verb, "mesh.loopcut") and nn >= 2) rd.set(.loopcut, &.{ @round(std.math.clamp(nums[0], 0, 1.6e7)), @round(std.math.clamp(nums[1], 0, 1.6e7)), if (nn >= 3) std.math.clamp(@round(nums[2]), 1, 64) else 1 });
        const why: ?[]const u8 = if (eq(verb, "mesh.bisect"))
            (if (nn >= 6) mo2.bisect(.{ nums[0], nums[1], nums[2] }, .{ nums[3], nums[4], nums[5] }) catch "it failed" else mo2.bisect(scene.cursor, .{ 0, 1, 0 }) catch "it failed")
        else if (eq(verb, "mesh.spin"))
            (mo2.spin(if (nn >= 1) @intFromFloat(std.math.clamp(nums[0], 1, 256)) else 12, if (nn >= 2) nums[1] else 360, axis) catch "it failed")
        else if (eq(verb, "mesh.bevel"))
            (if (nn >= 1) (mo2.bevel(nums[0], if (nn >= 2) @intFromFloat(std.math.clamp(nums[1], 1, 32)) else 1) catch "it failed") else "mesh.bevel \"width [segments]\"")
        else if (eq(verb, "mesh.loopcut"))
            (if (nn >= 2) mo2.loopCut(@intFromFloat(std.math.clamp(nums[0], 0, 4.0e9)), @intFromFloat(std.math.clamp(nums[1], 0, 4.0e9)), if (nn >= 3) @intFromFloat(std.math.clamp(nums[2], 1, 64)) else 1) catch "it failed" else "mesh.loopcut \"a b [cuts]\"")
        else blk: {
            const r = mo2.mergeDistance(if (nn >= 1) nums[0] else 0.0001) catch null;
            break :blk if (r == null) "it failed" else null;
        };
        if (why) |w| app.log("{s}: {s}", .{ verb, w });
        if (ops.byId(verb)) |oi| bs.macroOpArg(oi, arg);
        return true;
    }
    if (arg.len > 0 and (eq(verb, "file.import_obj") or eq(verb, "file.import_stl"))) {
        @import("files.zig").importPath(arg);
        return true;
    }
    if (arg.len > 0 and (eq(verb, "file.export_obj") or eq(verb, "file.export_stl"))) {
        @import("files.zig").exportPath(arg);
        return true;
    }
    // an operator id runs that operator
    if (std.mem.indexOfScalar(u8, verb, '.') != null) {
        if (ops.byId(verb)) |oi| {
            if (std.mem.eql(u8, verb, "view.theme") and arg.len > 0) {
                if (theme.byId(arg)) |t| app.setTheme(t) else app.log("view.theme: dark | light | contrast | honey | graphite | nord | solarized | solarized_light | dracula", .{});
                return true;
            }
            ops.arg = arg;
            defer ops.arg = "";
            ops.scripted = true; // (the console never sees a form)
            defer ops.scripted = false;
            ops.run(oi);
            return true;
        }
    }
    return false;
}

/// looks_like_op: the first word is "word.word" of letters, digits and _
/// (a mistyped operator id, not BeeScript).
fn looksLikeOp(line: []const u8) bool {
    if (line.len == 0 or (line[0] | 0x20) < 'a' or (line[0] | 0x20) > 'z') return false;
    var dots: usize = 0;
    for (line) |c| {
        if (c == ' ') break;
        if (c == '.') {
            dots += 1;
            continue;
        }
        const ok = c == '_' or (c >= '0' and c <= '9') or ((c | 0x20) >= 'a' and (c | 0x20) <= 'z');
        if (!ok) return false;
    }
    return dots > 0;
}

/// The port's own console words (help, list, add sphere ...) apply unless the
/// line reads as BeeScript after its first word: a call "( ...", an assignment.
fn scriptish(arg: []const u8) bool {
    if (arg.len == 0) return false;
    if (arg[0] == '(' or arg[0] == ',') return true;
    if (arg[0] == '=' and (arg.len == 1 or arg[1] != '=')) return true;
    if (arg.len >= 2 and arg[1] == '=' and std.mem.indexOfScalar(u8, "+-*/", arg[0]) != null) return true;
    return false;
}

pub fn runCommand(line: []const u8) void {
    const cmd = std.mem.trim(u8, line, " ");
    if (cmd.len == 0) return;
    // history (the command line's own Enter has put it there already: a repeat is not kept)
    history.push(cmd);

    app.log("> {s}", .{cmd});
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    const verb = it.next() orelse return;
    const arg = std.mem.trim(u8, it.rest(), " ");
    // a stroke, as the original's sculpt() in a script
    if (eq(verb, "sculpt")) return sculpt.console(arg);
    // shapes, as the original's ssphere() ... smesh() in a script (sdf.zig)
    if (@import("sdf.zig").console(verb, arg)) return;
    // the feature tree, as the original's feature(), fstatus(), features() (feature.zig)
    if (@import("feature.zig").console(verb, arg)) return;
    // a dab, a layer: as the original's paint(), vpaint(), wpaint(), layer()
    if (eq(verb, "paint")) return paintui.consolePaint(arg);
    if (eq(verb, "vpaint")) return paintui.consoleVpaint(arg);
    if (eq(verb, "wpaint")) return paintui.consoleWpaint(arg);
    if (eq(verb, "layer")) return paintui.consoleLayer(arg);
    if (eq(verb, "paint.vcol")) return paintui.consoleVcol(arg);
    if (eq(verb, "paint.info")) return paintui.info();
    if (eq(verb, "sculpt.stats")) return sculpt.stats(arg);
    if (eq(verb, "sculpt.info")) return sculpt.info();
    if (eq(verb, "sculpt.check")) return @import("dyntopo.zig").check();
    if (eq(verb, "sculpt.undoinfo")) return app.log("  sculpt.undoinfo step {d}", .{undo.deltaBytes()});
    if (runOpLine(verb, arg)) return;
    if (std.mem.indexOfScalar(u8, verb, '.') != null and looksLikeOp(cmd)) {
        app.log("  unknown command: {s}", .{verb});
        app.log("  Tab completes operator ids - console.list_ops lists them all; other lines run as BeeScript", .{});
        return;
    }
    // anything else is BeeScript (the port's own words first, as before)
    if (!isWord(verb) or scriptish(arg)) {
        _ = @import("bscript.zig").eval(cmd, false);
        return;
    }
    if (eq(verb, "help")) {
        app.log("help, list, add <cube|sphere|cylinder|plane|light|camera>, select <name>,", .{});
        app.log("delete [name], move <x> <y> <z> (expressions: 25cm, 2*pi), color <hex>,", .{});
        app.log("theme <name>, grid <on|off>, undo, redo, new, clear, ops, quit;", .{});
        app.log("or any operator id: file.new, view.toggle_grid ... (F3 lists them all)", .{});
        app.log("or BeeScript: x = 2m; add(\"cube\", \"Box\", x, 0, 0); for i in 0..3 {{ print(i) }}", .{});
    } else if (eq(verb, "list")) {
        for (scene.objects[0..scene.count]) |*o| app.log("  {s}{s:<16} {s:<9} ({d:.2}, {d:.2}, {d:.2})", .{ if (o.selected) "*" else " ", o.name(), o.kind.label(), nz(o.loc[0]), nz(o.loc[1]), nz(o.loc[2]) });
    } else if (eq(verb, "add")) {
        const kinds = [_]struct { scene.Kind, []const u8 }{
            .{ .cube, "create.cube" },   .{ .sphere, "create.sphere" }, .{ .cylinder, "create.cylinder" },
            .{ .plane, "create.plane" }, .{ .light, "create.light" },   .{ .camera, "create.camera" },
        };
        for (kinds) |k| {
            if (arg.len > 0 and std.ascii.startsWithIgnoreCase(k[0].label(), arg)) return ops.run(ops.byId(k[1]).?);
        }
        app.log("add what? cube, sphere, cylinder, plane, light, camera", .{});
    } else if (eq(verb, "select")) {
        if (scene.find(arg)) |k| {
            scene.selectOnly(k);
        } else app.log("no object called '{s}'", .{arg});
    } else if (eq(verb, "delete")) {
        if (arg.len > 0) {
            if (scene.find(arg)) |k| scene.selectOnly(k) else return app.log("no object called '{s}'", .{arg});
        }
        ops.runId("object.delete");
    } else if (eq(verb, "move")) {
        const s = scene.active orelse return app.log("nothing selected", .{});
        var v: m.V3 = scene.objects[s].loc;
        var ai = std.mem.tokenizeScalar(u8, arg, ' ');
        for (&v) |*c| {
            const t = ai.next() orelse break;
            c.* = expr.eval(t) orelse return app.log("not a number: {s}", .{t});
        }
        scene.objects[s].loc = v;
        undo.label("Move");
    } else if (eq(verb, "color") or eq(verb, "colour")) {
        const s = scene.active orelse return app.log("nothing selected", .{});
        const hex = std.mem.trimStart(u8, arg, "#");
        scene.objects[s].color = std.fmt.parseInt(u32, hex, 16) catch return app.log("colour as hex, e.g. color f2b134", .{});
        undo.label("Colour");
    } else if (eq(verb, "theme")) {
        if (theme.byId(arg)) |t| return app.setTheme(t);
        app.log("themes: dark, light, contrast, honey, graphite, nord, solarized, solarized_light, dracula", .{});
    } else if (eq(verb, "accent")) {
        if (arg.len == 0 or eq(arg, "theme")) return theme.setAccent(null);
        const hex = std.mem.trimStart(u8, arg, "#");
        theme.setAccent(std.fmt.parseInt(u32, hex, 16) catch return app.log("accent <hex> | theme", .{}));
    } else if (eq(verb, "grid")) {
        scene.show_grid = !eq(arg, "off");
    } else if (eq(verb, "undo")) {
        ops.runId("edit.undo");
    } else if (eq(verb, "redo")) {
        ops.runId("edit.redo");
    } else if (eq(verb, "ops")) {
        ops.runId("console.list_ops");
    } else if (eq(verb, "new")) {
        ops.runId("file.new");
    } else if (eq(verb, "clear")) {
        app.clearLog();
    } else if (eq(verb, "quit")) {
        app.quit = true;
    }
}

const words = [_][]const u8{ "help", "list", "add", "select", "delete", "move", "color", "colour", "theme", "accent", "grid", "undo", "redo", "ops", "new", "clear", "quit" };

fn isWord(verb: []const u8) bool {
    for (words) |w| {
        if (eq(verb, w)) return true;
    }
    return false;
}

/// No "-0.00": a value that rounds to zero prints as 0.
fn nz(v: f32) f32 {
    return if (@abs(v) < 0.005) 0 else v;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
