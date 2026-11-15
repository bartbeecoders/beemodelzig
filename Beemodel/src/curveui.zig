// Curves in the UI (curve.s, matui.s curve_props): the Object tab's Curve
// panel, curve edit mode (Tab on a curve: its line, handles and control points
// drawn over the view, clicks pick them, Ctrl+click adds a point after the
// selected end, G / R / S move the selected points and handles) and its tools.
const std = @import("std");
const cv = @import("curve.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const vp = @import("viewport.zig");
const m = @import("math.zig");
const undo = @import("undo.zig");
const zui = @import("zui");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const Rect = gfx.Rect;

// ---- the Object tab: a curve's values (curve_props) ------------------------------------

/// cv_cb: "key value" to curve.set (the field made the undo step).
fn set(comptime key: []const u8, val: []const u8) void {
    const ops = @import("ops.zig");
    var buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ key, val }) catch return;
    const old = ops.arg;
    ops.arg = line;
    defer ops.arg = old;
    cvSet();
    undo.label("Curve");
    app.dirty = true;
}

fn cvSet() void {
    inline for (cv.list) |e| {
        if (comptime std.mem.eql(u8, e[0], "curve.set")) return e[1].run();
    }
}

fn setInt(comptime key: []const u8, v: i32) void {
    var b: [16]u8 = undefined;
    set(key, std.fmt.bufPrint(&b, "{d}", .{v}) catch return);
}

var prof_obj: usize = 0;
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

/// cv_names: "None", then the scene's objects (78 at most).
fn profLabel(k: usize) []const u8 {
    if (k == 0) return "None";
    return if (k - 1 < scene.count) scene.objects[k - 1].name() else "";
}
fn profPick(k: usize) void {
    if (prof_obj >= scene.count) return;
    const old = scene.active;
    scene.active = prof_obj;
    defer {
        if (scene.active == prof_obj) scene.active = old;
    }
    set("profile", if (k == 0) "none" else if (k - 1 < scene.count) scene.objects[k - 1].name() else "none");
}
/// The profile's place in the list (0: none).
fn profPlace() usize {
    const c = cv.cvOf(prof_obj) orelse return 0;
    if (c.h.prof == 0) return 0;
    for (scene.objects[0..@min(scene.count, 78)], 0..) |*o, k| {
        if (o.uid == c.h.prof) return k + 1;
    }
    return 0;
}

/// The Curve panel under the object's rows: Resolution, Tube radius, Tube
/// sides, Cap the ends, Closed, Profile; 6 after. y below it.
pub fn props(salt: usize, s: usize, x: i32, w: i32, y0: i32) i32 {
    if (cv.cvOf(s) == null) return y0;
    prof_obj = s;
    cap_w = @floatFromInt(@divTrunc(w, 2) - 3);
    var f = bkit.Flow.begin("curve", salt, .{ .x = x, .y = y0, .w = w, .h = 0 }, y0);
    if (f.z) |z| {
        did = false;
        // (26 a row, as the original's)
        beginColumn(z, w, 4);
        describe(z, s);
        endColumn(z);
        if (did) undo.sync();
    }
    return f.end();
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

fn numChanged(it: zui.Interaction) bool {
    return step(it).changed;
}

fn describe(z: *zui.Ui, s: usize) void {
    const c = cv.cvOf(s) orelse return;
    {
        z.spacer(.px(1));
        z.pushFont(host.headFont());
        defer z.popFont();
        z.label("Curve", .{ .color = host.col(ui.th.accent_fg) });
        ui.record("heading", "Curve", host.rectOf(z.lastRect()), true);
    }
    const act = scene.active;
    // (the fields set the object shown, as the original's panel does the active one)
    if (act == null or act.? != s) return;
    var res: f32 = @floatFromInt(c.h.res);
    if (numChanged(bkit.numberRow(z, "Resolution", &res, .{ .step = 0.1, .min = 1, .max = 64, .decimals = 0, .tip = "Points per span: more is smoother" }))) setInt("resolution", @intFromFloat(@round(res)));
    var bev = c.h.bevel;
    if (numChanged(bkit.numberRow(z, "Tube radius", &bev, .{ .step = 0.005, .min = 0, .max = 100, .decimals = 3, .tip = "Make it a tube this thick (0: a line)" }))) {
        var b: [32]u8 = undefined;
        if (std.fmt.bufPrint(&b, "{d:.4}", .{bev})) |t| set("bevel", t) else |_| {}
    }
    var sides: f32 = @floatFromInt(c.h.sides);
    if (numChanged(bkit.numberRow(z, "Tube sides", &sides, .{ .step = 0.1, .min = 3, .max = 64, .decimals = 0, .tip = "How round the tube is" }))) setInt("sides", @intFromFloat(@round(sides)));
    var fill = c.h.fill != 0;
    if (step(bkit.checkRow(z, "Cap the ends", &fill, "")).changed) setInt("fill", @intFromBool(fill));
    var closed = c.h.nspl > 0 and c.h.spl[0].cyc != 0;
    if (step(bkit.checkRow(z, "Closed", &closed, "")).changed) setInt("cyclic", @intFromBool(closed));
    // the profile: a caption, a list on the right half
    z.beginHorizontal(.{ .spacing = 6, .alignment = .center });
    z.label("Profile", .{ .color = host.col(ui.th.text_dim), .width = .px(cap_w) });
    // (79 rows: more than bkit.choice holds)
    var items: [79]zui.Choice = undefined;
    const n = @min(scene.count, 78) + 1;
    for (0..n) |k| items[k] = .{ .label = profLabel(k) };
    var sel: usize = @min(profPlace(), n - 1);
    const r = step(z.dropdown("##profile", &sel, items[0..n], .{ .width = .fill }));
    ui.record("enum", items[sel].label, host.rectOf(r.rect), true);
    z.tooltipRich(r, .{ .title = "Profile", .body = "Sweep another curve's shape along this one instead of a round tube" });
    if (r.changed) profPick(sel);
    z.endHorizontal();
    z.spacer(.px(2));
}

// ---- curve edit mode -------------------------------------------------------------------

/// In curve edit mode.
pub fn on() bool {
    return cv.cveGet() != null;
}

/// cve_tab: true when Tab meant curve edit mode (entered or left).
pub fn tab() bool {
    if (cv.cve_obj != 0) {
        cv.cve_obj = 0;
        app.dirty = true;
        return true;
    }
    if (@import("editmesh.zig").active) return false;
    const a = scene.active orelse return false;
    if (cv.cvOf(a) == null) return false;
    cv.cve_obj = scene.objects[a].oid;
    app.log("  curve edit mode (Tab leaves; E extrude, W subdivide, X delete, V handles, Alt+C cyclic, Ctrl+click adds)", .{});
    app.dirty = true;
    return true;
}

/// Leave the mode (another mode starts, a file opens).
pub fn exit() void {
    if (cv.cve_obj == 0) return;
    cv.cve_obj = 0;
    app.dirty = true;
}

const COL_CURVE: u32 = 0xd8d8d8;
const COL_PT: u32 = 0x161616;
const COL_RIM: u32 = 0xe8e8e8;
const COL_SEL: u32 = 0xffa030;
const ht_col = [4]u32{ 0xc8c832, 0xd070d0, 0x60c060, 0x303030 };

/// cvo_dot: a rimmed square (size + 2 in the rim colour, then size).
fn dot(c: *gfx.Canvas, cam: *const vp.Cam, p: m.V3, col: u32, size: i32) void {
    const s = cam.project(p) orelse return;
    for ([2]i32{ size + 2, size }, [2]u32{ COL_RIM, col }) |z, k| {
        const h = @divTrunc(z, 2);
        c.fill(.{ .x = s[0] - h, .y = s[1] - h, .w = z, .h = z }, k);
    }
}

/// cve_overlay: the curve's line, handles and control points (not hidden by its
/// own surface).
pub fn overlay(c: *gfx.Canvas, cam: *const vp.Cam) void {
    const i = cv.cveGet() orelse return;
    const crv = cv.cvOf(i).?;
    const w = scene.world(i);
    if (cv.chFromCurve(crv)) {
        for (cv.ch_tab[0..cv.ch_n]) |ch| {
            var j: u32 = 0;
            while (true) : (j += 1) {
                var b = j + 1;
                if (b >= ch.n) {
                    if (ch.cyc == 0 or j >= ch.n) break;
                    b = 0;
                }
                vp.line3(c, cam, m.xform(w, cv.ch_ep[ch.first + j].p), m.xform(w, cv.ch_ep[ch.first + b].p), COL_CURVE);
            }
        }
    }
    for (crv.h.spl[0..crv.h.nspl]) |sp| {
        for (crv.pts[sp.first..][0..sp.n]) |*p| {
            const co = m.xform(w, p.co);
            if (sp.typ == cv.ST_BEZ) { // handles: lines in their type's colour
                const hc = ht_col[p.ht & 3];
                const hl = m.xform(w, p.hl);
                const hr = m.xform(w, p.hr);
                vp.line3(c, cam, co, hl, hc);
                vp.line3(c, cam, co, hr, hc);
                dot(c, cam, hl, if (p.sel & 2 != 0) COL_SEL else hc, 5);
                dot(c, cam, hr, if (p.sel & 4 != 0) COL_SEL else hc, 5);
            }
            dot(c, cam, co, if (p.sel & 1 != 0) COL_SEL else COL_PT, 7);
        }
    }
}

/// cve_click: the nearest point or handle (Shift: toggle it, else it alone;
/// nothing: none); Ctrl: a new point at the pointer after the selected end.
/// True when in the mode.
pub fn click(v: *const vp.View, r: Rect, x: i32, y: i32, shift: bool, ctrl: bool) bool {
    const i = cv.cveGet() orelse return false;
    const cam = vp.Cam.init(v, r);
    if (ctrl) {
        addAt(i, &cam, x, y);
        return true;
    }
    const c = cv.cvOf(i).?;
    const w = scene.world(i);
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    var best_d: f32 = 14 * 14;
    var best: ?u32 = null;
    var bits: u8 = 0;
    var k: u32 = 0;
    while (k < c.h.npts) : (k += 1) {
        const so = cv.cvSplineOf(c, k);
        const typ = if (so) |q| c.h.spl[q[0]].typ else cv.ST_POLY;
        const p = &c.pts[k];
        for ([3]m.V3{ p.co, p.hl, p.hr }, 0..) |q, part| {
            if (part != 0 and typ != cv.ST_BEZ) break; // (handles: Bezier only)
            const s = cam.projectF(m.xform(w, q)) orelse continue;
            const dx = s[0] - fx;
            const dy = s[1] - fy;
            const d = dx * dx + dy * dy;
            if (!(d < best_d)) continue;
            best_d = d;
            best = k;
            bits = if (part == 0) 7 else @as(u8, 1) << @intCast(part); // a point: with its handles
        }
    }
    if (!shift) for (c.used()) |*p| {
        p.sel = 0;
    };
    if (best) |b| {
        if (shift) c.pts[b].sel ^= bits else c.pts[b].sel = bits;
    }
    app.dirty = true;
    return true;
}

/// Ctrl+click: extrude to the pointer, in the plane of the end point facing the view.
fn addAt(i: usize, cam: *const vp.Cam, x: i32, y: i32) void {
    const c0 = cv.cvOf(i).?;
    var end: ?u32 = null; // the end point: last, else first of its spline
    var place: u32 = 0;
    var spl: u32 = 0;
    for (c0.h.spl[0..c0.h.nspl], 0..) |sp, s| {
        if (sp.cyc != 0 or sp.n == 0) continue;
        const last = sp.first + sp.n - 1;
        if (c0.pts[last].sel & 1 != 0) {
            end = last;
            place = sp.n;
            spl = @intCast(s);
            break;
        }
        if (c0.pts[sp.first].sel & 1 != 0) {
            end = sp.first;
            place = 0;
            spl = @intCast(s);
            break;
        }
    }
    const e = end orelse return app.log("  select an end point of an open spline", .{});
    const w = scene.world(i);
    const ew = m.xform(w, c0.pts[e].co);
    // the pointer's ray (dir . fwd = 1), cut by the plane through the end facing the view
    const dx = (@as(f32, @floatFromInt(x)) - cam.cx) / cam.f;
    const dy = (@as(f32, @floatFromInt(y)) - cam.cy) / cam.f;
    const dir = m.add(cam.fwd, m.sub(m.scale(cam.right, dx), m.scale(cam.up, dy)));
    const t = m.dot(m.sub(ew, cam.eye), cam.fwd);
    const pw = m.add(cam.eye, m.scale(dir, t));
    undo.label("Extrude Curve");
    const c = cv.cvEdit(i, 2) orelse return;
    c.pts[e].sel = 0;
    const pl = m.xform(m.inverseAffine(w), pw);
    _ = cv.cvInsert(c, spl, place, .{ .co = pl, .hl = pl, .hr = pl, .rad = 1.0, .tilt = 0, .sel = 7 });
    cv.cvRebuild(i);
}

// ---- G / R / S of the selected points and handles (cve_tm_*) ---------------------------

const Part = struct { pt: u32, part: u2, world: m.V3, local: m.V3 };
var parts: std.ArrayList(Part) = .empty;
var tm_mesh: ?u16 = null;
var tm_inv: m.M4 = undefined;

/// cve_tm_snapshot: the parts that move (the curve unshared first) and the
/// pivot (their median); 0: nothing selected. A selected point takes its
/// handles along; a handle alone turns auto -> aligned, vector -> free.
pub fn tmBegin(pivot: *m.V3) usize {
    parts.clearRetainingCapacity();
    const i = cv.cveGet() orelse return 0;
    var any: u8 = 0;
    for (cv.cvOf(i).?.used()) |p| any |= p.sel;
    if (any & 7 == 0) return 0;
    tm_mesh = scene.objects[i].mesh;
    const c = cv.cvEdit(i, 0) orelse return 0;
    const w = scene.world(i);
    tm_inv = m.inverseAffine(w);
    var sum: m.V3 = .{ 0, 0, 0 };
    var n: u32 = 0;
    for (c.used(), 0..) |*p, k| {
        if (p.sel & 1 != 0) {
            sum = m.add(sum, m.xform(w, p.co));
            n += 1;
            for (0..3) |q| add(k, @intCast(q), p, w);
            continue;
        }
        if (p.sel & 2 != 0) {
            add(k, 1, p, w);
            keep(p);
        }
        if (p.sel & 4 != 0) {
            add(k, 2, p, w);
            keep(p);
        }
    }
    const nf: f32 = @floatFromInt(n);
    pivot.* = if (n > 0) .{ sum[0] / nf, sum[1] / nf, sum[2] / nf } else .{ 0, 0, 0 };
    return parts.items.len;
}

fn keep(p: *cv.CP) void {
    if (p.ht == 0) p.ht = 1;
    if (p.ht == 2) p.ht = 3;
}

fn add(k: usize, part: u2, p: *cv.CP, w: m.M4) void {
    const l = partOf(p, part).*;
    parts.append(cv.A, .{ .pt = @intCast(k), .part = part, .world = m.xform(w, l), .local = l }) catch {};
}

fn partOf(p: *cv.CP, part: u2) *cv.V3 {
    return switch (part) {
        0 => &p.co,
        1 => &p.hl,
        else => &p.hr,
    };
}

fn curveNow() ?*cv.Curve {
    const i = cv.cveGet() orelse return null;
    return cv.cvOf(i);
}

/// cvt_store: a world position into its part (local).
fn store(c: *cv.Curve, e: *const Part, wpos: m.V3) void {
    if (e.pt >= c.h.npts) return;
    partOf(&c.pts[e.pt], e.part).* = m.xform(tm_inv, wpos);
}

/// The parts as they were.
pub fn tmRestore() void {
    const c = curveNow() orelse return;
    for (parts.items) |*e| {
        if (e.pt < c.h.npts) partOf(&c.pts[e.pt], e.part).* = e.local;
    }
}

/// cvt_finish: aligned partners turned, the mesh made again.
pub fn tmUpdate() void {
    const c = curveNow() orelse return;
    for (parts.items) |*e| {
        if (e.pt >= c.h.npts or c.pts[e.pt].sel & 1 != 0 or e.part == 0) continue;
        cv.cpAlign(&c.pts[e.pt], e.part);
    }
    cv.cvRebuild(cv.cveGet().?);
}

pub fn tmGrab(d: m.V3) void {
    const c = curveNow() orelse return;
    for (parts.items) |*e| store(c, e, m.add(e.world, d));
}

/// cve_tm_rotate(axis 1..3, angle, pivot): the two other components turn,
/// (a, b) = (Y, Z) for X, (Z, X) for Y, (X, Y) for Z.
pub fn tmRotateAxis(axis: u32, ang: f32, pivot: m.V3) void {
    const c = curveNow() orelse return;
    const sc = cv.sincos(ang);
    const a: usize = if (axis < 3) axis else 0;
    const b: usize = if (a + 1 < 3) a + 1 else 0;
    for (parts.items) |*e| {
        var q = e.world;
        const da = q[a] - pivot[a];
        const db = q[b] - pivot[b];
        q[a] = (da * sc[1] - db * sc[0]) + pivot[a];
        q[b] = (da * sc[0] + db * sc[1]) + pivot[b];
        store(c, e, q);
    }
}

/// axis: 0 all, 1..3 one.
pub fn tmScale(f: f32, axis: u32, pivot: m.V3) void {
    const c = curveNow() orelse return;
    for (parts.items) |*e| {
        var q = e.world;
        for (0..3) |k| {
            if (axis == 0 or axis == k + 1) q[k] = (q[k] - pivot[k]) * f + pivot[k];
        }
        store(c, e, q);
    }
}

/// A cancelled transform: the parts and the mesh as they were.
pub fn tmCancel() void {
    tmRestore();
    const i = cv.cveGet() orelse return;
    if (tm_mesh) |mi| {
        if (scene.objects[i].mesh != mi and scene.meshes[mi] != null) {
            scene.objects[i].mesh = mi;
            return;
        }
    }
    cv.cvRebuild(i);
}

/// The tools in curve edit mode (tl_curve; "" a gap).
pub const tools = [_][]const u8{ "curve.extrude", "curve.subdivide", "curve.delete", "curve.cyclic", "curve.handle", "curve.select_all", "", "curve.to_mesh" };
