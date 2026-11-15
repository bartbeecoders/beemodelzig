// The Physics tab of the Properties editor (physui.s rb_props_draw, then
// simui.s sim_props). For the active mesh object, under a status line
// ("Active Box, 2 kg, 1 joint"; "Not a rigid body"; while it runs "Running:
// 12 bodies, 3 awake, 4 ms"), sections that fold:
//   - Rigid Body: not a body yet: its type and shape, then Add Rigid Body
//     (rigid.add on the selection). A body: type, shape, a material preset,
//     mass, friction, bounce, damping, its start velocity, collision group,
//     Attracts the others, Remove. A change goes to every selected body (one
//     undo step, "Physics").
//   - Joints: the object's joints as rows (8 at most); the one picked has its
//     type, the other object (or the world), pivot, axis, limits, motor and the
//     force that breaks it. Add Joint... (the form), Remove Joint.
//   - Shatter (closed at first): its section heading (shatter's own layer
//     fills it).
//   - World (closed at first): gravity on, gravity, steps a second,
//     iterations, substeps, G.
// Then (simui.s) Cloth and Soft Body (closed unless the object is cloth),
// Cloth World (closed), and the Simulation Cache (closed): what is cached or
// baked, the memory it takes, Bake / Free, the memory budget.
//
// The values come from the animation block (anim.cur: the bodies, the joints,
// the world) every pass into the fields' own copies; a change writes them into
// an owned block (anim.own) and names the undo step, as the original's
// callbacks do after the widget's undo step. Records hold oids in memory
// (anim.zig turns them into uids in files), so they compare with Object.oid.
//
// On Zui (bkit.Flow in the tab's page, which editors.zig scrolls), at the
// original's pitch (22 a row, 4 between), in two flows: what is above
// Shatter, then World and the rest; Shatter's own fields (shatterui.zig)
// and a force field's (fieldui.zig) go between them, as they lay themselves
// out. The lists are drop-downs (recorded as `enum` too, their captions as
// `caption`), the joints bkit.row.
const std = @import("std");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const anim = @import("anim.zig");
const undo = @import("undo.zig");
const zui = @import("zui");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");
const cad = @import("cad.zig");
const rc = @import("rbcore.zig");
const Rect = gfx.Rect;

const MAXJROW = 8; // joints listed (glued pieces have many)
const UNDO = "Physics";

// ---- what the simulation and its cache say (set by rbody.zig / simcache.zig) ----

/// rb_info(what) as the original's: 0 bodies (while it runs, else 0), 2 awake,
/// 4 the last frame's milliseconds.
pub var rb_info_fn: ?*const fn (what: u32) f32 = &@import("rbody.zig").info;
/// sc_info(what): 0 rigid frames, 1 cloth frames, 2 MB in use, 3 rigid baked
/// (> 0), 4 cloth baked, 6 the budget (MB).
pub var sc_info_fn: ?*const fn (what: u32) f32 = &@import("simcache.zig").info;
/// rb_back: rb_frame(0) - no simulation, objects back where they began.
pub var back_fn: ?*const fn () void = &rbBackNow;
fn rbBackNow() void {
    @import("rbody.zig").frame(0); // rb_back: frame 0, at or before any start
}

fn rbInfo(w: u32) f32 {
    return if (rb_info_fn) |f| f(w) else 0;
}
fn scInfo(w: u32) f32 {
    if (sc_info_fn) |f| return f(w);
    return if (w == 6) 1024 else 0;
}
fn rbBack() void {
    if (back_fn) |f| f();
}

// ---- labels ---------------------------------------------------------------------

const l_type = [_][]const u8{ "Active", "Passive" };
const l_shape = [_][]const u8{ "Box", "Sphere", "Capsule", "Convex Hull", "Compound", "Mesh", "Plane" };
const kw_shape = [_][]const u8{ "box", "sphere", "capsule", "hull", "compound", "mesh", "plane" };
const l_mat = [_][]const u8{ "Default", "Rubber", "Ice", "Wood", "Metal", "Stone", "Custom" };
const l_jtype = [_][]const u8{ "Fixed", "Hinge", "Point", "Slider" };
const l_cltype = [_][]const u8{ "Cloth", "Soft body", "Collider" };
const kw_cltype = [_][]const u8{ "cloth", "soft", "collider" };
/// The material presets' friction and bounce (pm_fb).
const pm_fb = [6][2]f32{ .{ 0.5, 0.0 }, .{ 0.9, 0.8 }, .{ 0.02, 0.05 }, .{ 0.5, 0.3 }, .{ 0.35, 0.15 }, .{ 0.7, 0.1 } };
const DEG: f32 = 57.29578;

// ---- the fields' copies (rp_*) --------------------------------------------------

var rp_nshape: usize = 3; // a new body: active, a convex hull
var rp_ntype: usize = 0;
var rp_type: usize = 0;
var rp_shape: usize = 0;
var rp_mat: usize = 0;
var rp_vals: [4]f32 = @splat(0); // mass friction bounce damping
var rp_vel: [3]f32 = @splat(0);
var rp_grp: f32 = 0;
var rp_attr: bool = false;
var rp_g: f32 = 1;
var rp_grav: [3]f32 = .{ 0, -9.81, 0 };
var rp_gon: bool = true;
var rp_rate: f32 = 120;
var rp_iter: f32 = 10;
var rp_sub: f32 = 4;
var rp_jsel: usize = 0; // the joint picked (in the list)
var rp_jidx: usize = 0; //  its index in the block
var rp_juid: u32 = 0; //  this object's oid
var rp_jtype: usize = 0;
var rp_jother: usize = 0;
var rp_jpiv: [3]f32 = @splat(0);
var rp_jaxis: [3]f32 = @splat(0);
var rp_jlim: bool = false;
var rp_jmot: bool = false;
var rp_jlo: f32 = 0;
var rp_jhi: f32 = 0;
var rp_jspd: f32 = 0;
var rp_jfor: f32 = 0;
var rp_jbrk: f32 = 0;
var sm_type: usize = 0; // sm_cl: type - 1, the seven values, self
var sm_vals: [7]f32 = @splat(0);
var sm_self: bool = false;
var sm_wind: [3]f32 = @splat(0);
var sm_sub: f32 = 10;
var sm_budget: f32 = 1024;

// sections: open or not (WGF_SHUT: closed at first)
const S_BODY = 0;
const S_JOINT = 1;
const S_SHAT = 2;
const S_WORLD = 3;
const S_CLOTH = 4;
const S_CLOTH0 = 5;
const S_CWORLD = 6;
const S_CACHE = 7;
var sec_open = [8]bool{ true, true, false, false, true, false, false, false };

// ---- the records ------------------------------------------------------------------

/// rp_entry: the object's rigid body record in the block, or null.
fn entryOf(b: *anim.Block, oid: u32) ?[]u8 {
    var k: usize = 0;
    while (k < b.h.nrb and (k + 1) * rc.RB_SZ <= b.rb.len) : (k += 1) {
        const r = b.rb[k * rc.RB_SZ ..][0..rc.RB_SZ];
        if (rc.rdU(r, rc.RB_UID) == oid) return r;
    }
    return null;
}
fn jointAt(b: *anim.Block, k: usize) []u8 {
    return b.jt[k * rc.JT_SZ ..][0..rc.JT_SZ];
}
fn njt(b: *anim.Block) usize {
    return @min(b.h.njt, b.jt.len / rc.JT_SZ);
}

/// pm_which: the preset its friction and bounce are (6: its own).
fn pmWhich(r: []const u8) usize {
    for (pm_fb, 0..) |p, k| {
        if (rc.rdU(r, rc.RB_FRIC) == @as(u32, @bitCast(p[0])) and rc.rdU(r, rc.RB_REST) == @as(u32, @bitCast(p[1]))) return k;
    }
    return 6;
}

fn activeMesh() ?usize {
    const a = scene.active orelse return null;
    if (a >= scene.count or !scene.objects[a].kind.isMesh()) return null;
    return a;
}

/// rp_each: f for each body of the selection (the active one at least), in an
/// owned block; the step is named "Physics".
fn each(comptime f: fn ([]u8) void) void {
    const b = anim.own(0) orelse return;
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        const act = scene.active != null and scene.active.? == k;
        if (!act and !o.selected) continue;
        if (!o.kind.isMesh()) continue;
        if (entryOf(b, o.oid)) |r| f(r);
    }
    undo.label(UNDO);
    app.dirty = true;
}

fn putType(r: []u8) void {
    rc.wrU(r, rc.RB_TYPE, @intCast(rp_type + 1));
}
fn putShape(r: []u8) void {
    rc.wrU(r, rc.RB_SHAPE, @intCast(rp_shape));
}
fn putMat(r: []u8) void {
    rc.wrF(r, rc.RB_FRIC, pm_fb[rp_mat][0]);
    rc.wrF(r, rc.RB_REST, pm_fb[rp_mat][1]);
}
var val_k: usize = 0;
fn putVal(r: []u8) void {
    rc.wrF(r, rc.RB_MASS + val_k * 4, rp_vals[val_k]);
}
fn putVel(r: []u8) void {
    for (0..3) |c| rc.wrF(r, rc.RB_VEL + c * 4, rp_vel[c]);
}
fn putGrp(r: []u8) void {
    const g: u32 = @as(u32, @intFromFloat(rp_grp)) & 15;
    rc.wrU(r, rc.RB_FLAGS, rc.rdU(r, rc.RB_FLAGS) & ~@as(u32, 15 << 4) | g << 4);
}
fn putAttr(r: []u8) void {
    rc.wrU(r, rc.RB_FLAGS, rc.rdU(r, rc.RB_FLAGS) & ~@as(u32, 0x100) | @as(u32, @intFromBool(rp_attr)) << 8);
}

/// The world's settings into an owned block.
fn worldPut(comptime f: fn (*[32]u8) void) void {
    const b = anim.own(0) orelse return;
    f(&b.h.rw);
    undo.label(UNDO);
    app.dirty = true;
}
fn putG(w: *[32]u8) void {
    rc.wrF(w, rc.RW_G, rp_g);
}
fn putGrav(w: *[32]u8) void {
    for (0..3) |c| rc.wrF(w, rc.RW_GRAV + c * 4, rp_grav[c]);
    rc.wrU(w, rc.RW_SET, 1);
}
fn putNums(w: *[32]u8) void {
    rc.wrU(w, rc.RW_RATE, @intFromFloat(rp_rate));
    rc.wrU(w, rc.RW_ITER, @intFromFloat(rp_iter));
    rc.wrU(w, rc.RW_SUB, @intFromFloat(rp_sub));
}

/// jt_own: the joint picked in an owned block.
fn jtOwn() ?[]u8 {
    const b = anim.own(0) orelse return null;
    if (rp_jidx >= njt(b)) return null;
    undo.label(UNDO);
    app.dirty = true;
    return jointAt(b, rp_jidx);
}

/// jt_remove: the joint picked goes (the last into its place).
fn jtRemove() void {
    rbBack();
    const b = anim.own(0) orelse return;
    const n = njt(b);
    if (rp_jidx >= n) return;
    const last = n - 1;
    if (rp_jidx != last) @memcpy(jointAt(b, rp_jidx), jointAt(b, last));
    // (the block's slice holds the joints in use: one fewer, anim.zig's allocator)
    const A = @import("alloc.zig").A;
    const nj: []u8 = if (last == 0) &.{} else (A.dupe(u8, b.jt[0 .. last * rc.JT_SZ]) catch return);
    if (b.jt.len > 0) A.free(b.jt);
    b.jt = nj;
    b.h.njt = @intCast(last);
    rp_jsel = 0;
    undo.label(UNDO);
    app.dirty = true;
}

/// rp_exec: run an operator with this argument text (its own undo step).
fn exec(id: []const u8, arg: []const u8) void {
    @import("animops.zig").runText(id, arg);
    app.dirty = true;
}

/// rb_add_new: rigid.add <active|passive> <shape> on the selection.
fn addNew() void {
    var a: [48]u8 = undefined;
    exec("rigid.add", std.fmt.bufPrint(&a, "{s}{s}", .{ if (rp_ntype == 0) "active " else "passive ", kw_shape[rp_nshape] }) catch return);
}

// ---- rows ---------------------------------------------------------------------

var col: Rect = .{};

/// pnl_text / pnl_hint: wrapped to the column, recorded as `info`.
fn para(z: *zui.Ui, s: []const u8, c: u32) void {
    z.wrappedText(s, .{ .color = host.col(c), .width = @floatFromInt(col.w) });
    ui.record("info", s, host.rectOf(z.lastRect()), true);
}

/// The items of a drop-down: the labels, or for "Tied to" the world and the
/// scene's objects (up to 1023).
var items_buf: [1024]zui.Choice = undefined;

/// A drop-down (name "##..." to hide it), the width it is given, the chosen
/// one `v.*` of `items`; recorded as `enum` too. True when another was
/// picked.
fn enumField(z: *zui.Ui, name: []const u8, v: *usize, items: []const zui.Choice, tip: []const u8) bool {
    if (items.len == 0) return false;
    var s: usize = @min(v.*, items.len - 1);
    const r = z.dropdown(name, &s, items, .{ .width = .fill });
    if (tip.len > 0) z.tooltipRich(r, .{ .title = items[s].label, .body = tip });
    ui.record("enum", items[s].label, host.rectOf(r.rect), true);
    if (!r.changed) return false;
    v.* = s;
    return true;
}

fn choices(comptime labels: []const []const u8) *const [labels.len]zui.Choice {
    return comptime blk: {
        var c: [labels.len]zui.Choice = undefined;
        for (labels, 0..) |l, k| c[k] = .{ .label = l };
        const out = c;
        break :blk &out;
    };
}

/// "Tied to": the world, then the scene's objects.
fn otherChoices() []const zui.Choice {
    const n = @min(scene.count, items_buf.len - 1);
    items_buf[0] = .{ .label = "world" };
    for (0..n) |k| items_buf[k + 1] = .{ .label = scene.objects[k].name() };
    return items_buf[0 .. n + 1];
}

/// rp_cap: the caption in the left half, a drop-down in the right half;
/// the caption recorded as `caption`, on the drop-down's line.
fn capEnum(z: *zui.Ui, cap: []const u8, v: *usize, items: []const zui.Choice, tip: []const u8) bool {
    z.pushId(cap);
    defer z.popId();
    bkit.beginCaptioned(z, cap, @floatFromInt(@divTrunc(col.w, 2) - 6));
    const changed = enumField(z, "##list", v, items, tip);
    const r = host.rectOf(z.lastRect());
    bkit.endCaptioned(z);
    ui.record("caption", cap, .{ .x = col.x, .y = r.y, .w = col.w >> 1, .h = r.h }, true);
    return changed;
}

/// rp_vec3: the caption, three fields (no labels) at the right.
fn vec3(z: *zui.Ui, cap: []const u8, v: *[3]f32, step: f32, dec: u8, tip: []const u8) bool {
    z.pushId(cap);
    defer z.popId();
    bkit.beginCaptioned(z, cap, @floatFromInt(@divTrunc(col.w, 2) - 6));
    const changed = bkit.vec3Row(z, "", v, .{ .step = step, .min = -1e9, .max = 1e9, .decimals = dec, .tip = tip });
    const r = host.rectOf(z.lastRect());
    bkit.endCaptioned(z);
    ui.record("caption", cap, .{ .x = col.x, .y = r.y, .w = col.w >> 1, .h = r.h }, true);
    return changed;
}

/// A number field across the width it is given. True when changed.
fn num(z: *zui.Ui, label: []const u8, v: *f32, o: bkit.NumberRowOptions) bool {
    return bkit.numberRow(z, label, v, o).changed;
}

fn toggle(z: *zui.Ui, label: []const u8, v: *bool) bool {
    return bkit.checkRow(z, label, v, "").changed;
}

/// A flow of the page from y: its height comes back as the y below it.
fn flow(name: []const u8, i: i16, bd: Rect, y: i32, comptime f: fn (*zui.Ui) void) i32 {
    var fl = bkit.Flow.begin(name, @intCast(i), bd, y);
    if (fl.z) |z| {
        // (the original's pitch: 22 a row, 4 between)
        z.beginVertical(.{ .width = .px(@floatFromInt(bd.w)), .spacing = 4 });
        // (fields as narrow as the column: Zui's natural width is wider)
        z.pushMetric(.widget_width, 60);
        defer z.popStyle();
        f(z);
        z.endVertical();
    }
    return fl.end();
}

// ---- the tab ---------------------------------------------------------------------

/// The Physics tab in the column `bd` (pnl_begin's), from y0: y below it.
pub fn props(i: i16, bd: Rect, y0: i32) i32 {
    col = bd;
    var y = y0;
    var world_shown = false;
    if (activeMesh() != null) {
        y = flow("physics.body", i, bd, y + 8, bodyProps);
        if (sec_open[S_SHAT]) {
            // rp_shatter (pattern, preset, count, seed, glue, impact, gap, cut
            // faces, Shatter / Re-cut): shatterui.zig
            y = @import("shatterui.zig").props(i, bd, y);
            col = bd;
        }
        world_shown = true;
    } else if (@import("fields.zig").active() != null) {
        // a force field (fl_active): its section, then the world
        y = @import("fieldui.zig").props(i, bd, y + 8);
        col = bd;
        world_shown = true;
    }
    show_world = world_shown;
    return flow("physics.sim", i, bd, y, simProps);
}

var show_world = false;

fn bodyProps(z: *zui.Ui) void {
    const oi = activeMesh() orelse return;
    const o = &scene.objects[oi];
    const b = anim.cur;
    const e: ?[]u8 = if (b) |bb| entryOf(bb, o.oid) else null;
    // a piece: its original hidden (shatter): "Piece of X, "
    var orig: ?*const scene.Object = null;
    if (o.parent) |pi| {
        if (!scene.objects[pi].visible) orig = &scene.objects[pi];
    }
    status(z, o, b, e, orig);
    if (bkit.section(z, "Rigid Body", &sec_open[S_BODY])) {
        z.pushId("§Rigid Body");
        defer z.popId();
        if (e) |r| {
            rp_type = (rc.rdU(r, rc.RB_TYPE) -% 1) & 1;
            const sh = rc.rdU(r, rc.RB_SHAPE);
            rp_shape = if (sh <= 6) sh else 0;
            rp_mat = pmWhich(r);
            for (0..4) |k| rp_vals[k] = rc.rdF(r, rc.RB_MASS + k * 4);
            rp_vel = rc.rd3(r, rc.RB_VEL);
            rp_grp = @floatFromInt(rc.rdU(r, rc.RB_FLAGS) >> 4 & 15);
            rp_attr = rc.rdU(r, rc.RB_FLAGS) & 0x100 != 0;
            if (capEnum(z, "Type", &rp_type, choices(&l_type), "Active bodies fall and collide, passive ones stay put and are collided with")) each(putType);
            if (capEnum(z, "Shape", &rp_shape, choices(&l_shape), "The shape it collides as: a box, sphere or capsule is fastest, a hull fits a convex mesh, compound a concave one")) each(putShape);
            // HOOK(nodes): "Bodies" (The object / Its instances) when its
            // geometry has instances (inst_count of obj_eval) - geometry nodes
            // are not in the port yet.
            if (capEnum(z, "Material", &rp_mat, choices(&l_mat), "Friction and bounce of a material (Custom: your own values)")) {
                if (rp_mat < 6) each(putMat);
            }
            const rows = [4]struct { l: []const u8, lo: f32, hi: f32, step: f32, tip: []const u8 }{
                .{ .l = "Mass (kg)", .lo = 0.001, .hi = 1000000000, .step = 0.05, .tip = "" },
                .{ .l = "Friction", .lo = 0, .hi = 2, .step = 0.005, .tip = "How much it grips (0 ice, 1 rubber)" },
                .{ .l = "Bounce", .lo = 0, .hi = 1, .step = 0.005, .tip = "How much speed it keeps from a hit (0 none, 1 all)" },
                .{ .l = "Damping", .lo = 0, .hi = 10, .step = 0.005, .tip = "Air drag: speed lost a second" },
            };
            for (rows, 0..) |rw, k| {
                if (num(z, rw.l, &rp_vals[k], .{ .step = rw.step, .min = rw.lo, .max = rw.hi, .decimals = 3, .tip = rw.tip })) {
                    val_k = k;
                    each(putVal);
                }
            }
            if (vec3(z, "Velocity (m/s)", &rp_vel, 0.05, 2, "Its velocity when the run begins (m/s, X Y Z)")) each(putVel);
            if (num(z, "Collision group", &rp_grp, .{ .step = 0.1, .min = 0, .max = 15, .decimals = 0, .tip = "Its group, 0 to 15 (rigid.add collide picks the groups it meets)" })) each(putGrp);
            if (toggle(z, "Attracts the others", &rp_attr)) each(putAttr);
            _ = bkit.opButton(z, "rigid.remove", .{ .label = "Remove Rigid Body" });
        } else {
            _ = capEnum(z, "Type", &rp_ntype, choices(&l_type), "Active bodies fall and collide, passive ones stay put and are collided with");
            _ = capEnum(z, "Shape", &rp_nshape, choices(&l_shape), "The shape it collides as (Mesh and Plane: passive only)");
            const add = z.button("Add Rigid Body", .{ .width = .fill, .variant = .primary });
            z.tooltipRich(add, .{ .title = "Add Rigid Body", .body = "Make the selected objects rigid bodies of this type and shape" });
            if (add.clicked) addNew();
        }
    }
    if (bkit.section(z, "Joints", &sec_open[S_JOINT])) {
        z.pushId("§Joints");
        defer z.popId();
        joints(z, o, b);
    }
    // (its fields: shatterui.zig, below this flow)
    _ = bkit.section(z, "Shatter", &sec_open[S_SHAT]);
}

/// rp_status: one line (what it is), and while it runs what the simulation does.
fn status(z: *zui.Ui, o: *const scene.Object, b: ?*anim.Block, e: ?[]u8, orig: ?*const scene.Object) void {
    var buf: [160]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    if (orig) |po| w.print("Piece of {s}, ", .{po.name()}) catch {};
    if (e) |r| {
        const ty = rc.rdU(r, rc.RB_TYPE);
        const sh = rc.rdU(r, rc.RB_SHAPE);
        w.print("{s} {s}", .{ if (ty == 2) "Passive" else "Active", l_shape[if (sh <= 6) sh else 0] }) catch {};
        if (ty != 2) {
            var vb: [32]u8 = undefined;
            w.print(", {s} kg", .{cad.fmtVal3(&vb, rc.rdF(r, rc.RB_MASS))}) catch {};
        }
        if (rc.rdU(r, rc.RB_FLAGS) & 2 != 0) w.writeAll(", each instance a body") catch {};
        const nj = nJoints(o, b);
        if (nj > 0) w.print(", {d} {s}", .{ nj, if (nj == 1) "joint" else "joints" }) catch {};
    } else w.writeAll("Not a rigid body") catch {};
    para(z, w.buffered(), ui.th.text);
    if (rbInfo(0) > 0) {
        var b2: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&b2, "Running: {d} bodies, {d} awake, {d} ms", .{ cvtt(rbInfo(0)), cvtt(rbInfo(2)), cvtt(rbInfo(4)) }) catch "";
        para(z, s, ui.th.text_dim);
    }
    z.spacer(.px(2));
}

fn cvtt(x: f32) i32 {
    if (!(x > -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}

fn isOurs(j: []const u8, oid: u32) bool {
    if (rc.rdU(j, rc.JT_TYPE) & 7 > 4) return false; // (not the impact markers)
    return rc.rdU(j, rc.JT_A) == oid or rc.rdU(j, rc.JT_B) == oid;
}

/// rp_njoints: the joints it is in.
fn nJoints(o: *const scene.Object, b: ?*anim.Block) u32 {
    const bb = b orelse return 0;
    var n: u32 = 0;
    for (0..njt(bb)) |k| {
        if (isOurs(jointAt(bb, k), o.oid)) n += 1;
    }
    return n;
}

/// rp_joints: the rows, the one picked, Add / Remove.
fn joints(z: *zui.Ui, o: *const scene.Object, b: ?*anim.Block) void {
    rp_juid = o.oid;
    var listed: usize = 0;
    var more: usize = 0;
    var picked: ?usize = null;
    if (b) |bb| {
        for (0..njt(bb)) |k| {
            const j = jointAt(bb, k);
            if (!isOurs(j, o.oid)) continue;
            if (listed >= MAXJROW) {
                more += 1;
                continue;
            }
            if (listed == rp_jsel) picked = k;
            // a row: Hinge to Floor
            var other = rc.rdU(j, rc.JT_B);
            if (other == o.oid) other = rc.rdU(j, rc.JT_A);
            const on: []const u8 = if (other == 0) "world" else if (scene.findOid(other)) |q| scene.objects[q].name() else "world";
            var tb: [80]u8 = undefined;
            const s = std.fmt.bufPrint(&tb, "{s} to {s}", .{ l_jtype[((rc.rdU(j, rc.JT_TYPE) & 7) -% 1) & 3], on }) catch "";
            z.pushIdInt(listed);
            defer z.popId();
            if (bkit.row(z, s, listed == rp_jsel, .{ .tip = "A joint of this object: click to edit it", .tip_title = "Joint" }).clicked) {
                rp_jsel = listed;
                app.dirty = true;
            }
            listed += 1;
        }
    }
    if (listed == 0) {
        para(z, "No joints: select two objects (or one) and Add Joint.", ui.th.text_dim);
    } else {
        if (more > 0) {
            var mb: [48]u8 = undefined;
            para(z, std.fmt.bufPrint(&mb, "{d} more joints (glue)", .{more}) catch "", ui.th.text_dim);
        }
        if (picked) |k| {
            jointFields(z, o, b.?, k);
        } else rp_jsel = 0; // (the pick gone: the first)
    }
    bkit.beginPair(z);
    _ = bkit.opButton(z, "rigid.joint", .{ .label = "Add Joint..." });
    if (listed > 0) {
        if (bkit.button(z, "Remove Joint", "Remove the joint picked above").clicked) jtRemove();
    } else z.spacer(.fill);
    bkit.endPair(z);
}

fn jointFields(z: *zui.Ui, o: *const scene.Object, b: *anim.Block, k: usize) void {
    z.spacer(.px(0));
    rp_jidx = k;
    const j = jointAt(b, k);
    rp_jtype = ((rc.rdU(j, rc.JT_TYPE) & 7) -% 1) & 3;
    var other = rc.rdU(j, rc.JT_B);
    if (other == o.oid) other = rc.rdU(j, rc.JT_A);
    rp_jother = 0;
    if (other != 0) {
        if (scene.findOid(other)) |q| rp_jother = q + 1;
    }
    rp_jpiv = rc.rd3(j, rc.JT_PIV);
    rp_jaxis = rc.rd3(j, rc.JT_AXIS);
    const fl = rc.rdU(j, rc.JT_FLG);
    rp_jlim = fl & 1 != 0;
    rp_jmot = fl & 2 != 0;
    rp_jlo = rc.rdF(j, rc.JT_LO);
    rp_jhi = rc.rdF(j, rc.JT_HI);
    rp_jspd = rc.rdF(j, rc.JT_MSPD);
    rp_jfor = rc.rdF(j, rc.JT_MFOR);
    rp_jbrk = rc.rdF(j, rc.JT_BRK);
    if (capEnum(z, "Type", &rp_jtype, choices(&l_jtype), "Fixed: held together. Hinge: turns about an axis. Point: a ball joint. Slider: moves along an axis")) {
        if (jtOwn()) |jj| rc.wrU(jj, rc.JT_TYPE, @intCast(rp_jtype + 1));
    }
    if (capEnum(z, "Tied to", &rp_jother, otherChoices(), "The other body, or the world")) {
        if (jtOwn()) |jj| {
            // 0 the world (always B), i + 1 the i-th object (not itself)
            if (rp_jother == 0) {
                rc.wrU(jj, rc.JT_A, rp_juid);
                rc.wrU(jj, rc.JT_B, 0);
            } else if (rp_jother - 1 < scene.count) {
                const u = scene.objects[rp_jother - 1].oid;
                if (u != rp_juid) {
                    rc.wrU(jj, rc.JT_A, rp_juid);
                    rc.wrU(jj, rc.JT_B, u);
                }
            }
        }
    }
    if (vec3(z, "Pivot", &rp_jpiv, 0.01, 3, "Where it is (world, at the start)")) {
        if (jtOwn()) |jj| for (0..3) |c| rc.wrF(jj, rc.JT_PIV + c * 4, rp_jpiv[c]);
    }
    if (rp_jtype == 1 or rp_jtype == 3) {
        const slider = rp_jtype == 3;
        if (vec3(z, "Axis", &rp_jaxis, 0.01, 3, "The axis it turns about or slides along (world)")) {
            if (jtOwn()) |jj| for (0..3) |c| rc.wrF(jj, rc.JT_AXIS + c * 4, rp_jaxis[c]);
        }
        if (toggle(z, "Limits", &rp_jlim)) putFlags();
        if (rp_jlim) {
            // (hinge: degrees shown, radians kept - WGF_DEG)
            const s: f32 = if (slider) 1 else DEG;
            var lo = rp_jlo * s;
            var hi = rp_jhi * s;
            bkit.beginPair(z);
            if (num(z, if (slider) "From (m)" else "From", &lo, .{ .step = 0.01, .min = -1e9, .max = 1e9, .decimals = if (slider) 3 else 1, .suffix = if (slider) "" else "\u{00B0}", .tip = if (slider) "The lowest place along the axis" else "The lowest angle (degrees)" })) {
                if (jtOwn()) |jj| rc.wrF(jj, rc.JT_LO, lo / s);
            }
            if (num(z, if (slider) "To (m)" else "To", &hi, .{ .step = 0.01, .min = -1e9, .max = 1e9, .decimals = if (slider) 3 else 1, .suffix = if (slider) "" else "\u{00B0}", .tip = if (slider) "The highest place along the axis" else "The highest angle (degrees)" })) {
                if (jtOwn()) |jj| rc.wrF(jj, rc.JT_HI, hi / s);
            }
            bkit.endPair(z);
        }
        if (toggle(z, "Motor", &rp_jmot)) putFlags();
        if (rp_jmot) {
            const s: f32 = if (slider) 1 else DEG;
            var sp = rp_jspd * s;
            bkit.beginPair(z);
            if (num(z, if (slider) "Speed (m/s)" else "Speed (deg/s)", &sp, .{ .step = 0.01, .min = -1e9, .max = 1e9, .decimals = if (slider) 3 else 1, .suffix = if (slider) "" else "\u{00B0}" })) {
                if (jtOwn()) |jj| rc.wrF(jj, rc.JT_MSPD, sp / s);
            }
            if (num(z, "Force at most", &rp_jfor, .{ .step = 1, .min = 0, .max = 1000000000, .decimals = 1, .tip = "The torque (N m) or force (N) the motor gives at most" })) {
                if (jtOwn()) |jj| rc.wrF(jj, rc.JT_MFOR, rp_jfor);
            }
            bkit.endPair(z);
        }
    }
    if (num(z, "Breaks at (N, 0 never)", &rp_jbrk, .{ .step = 10, .min = 0, .max = 1000000000, .decimals = 0 })) {
        if (jtOwn()) |jj| rc.wrF(jj, rc.JT_BRK, rp_jbrk);
    }
}

/// rp_world: gravity, steps a second, iterations, substeps, G.
fn world(z: *zui.Ui, b: ?*anim.Block) void {
    rp_grav = .{ 0, -9.81, 0 };
    rp_rate = 120;
    rp_iter = 10;
    rp_sub = 4;
    rp_g = 1;
    if (b) |bb| {
        const w = &bb.h.rw;
        if (rc.rdU(w, rc.RW_G) != 0) rp_g = rc.rdF(w, rc.RW_G);
        if (rc.rdU(w, rc.RW_SET) != 0) rp_grav = rc.rd3(w, rc.RW_GRAV);
        if (rc.rdU(w, rc.RW_RATE) != 0) rp_rate = @floatFromInt(rc.rdU(w, rc.RW_RATE));
        if (rc.rdU(w, rc.RW_ITER) != 0) rp_iter = @floatFromInt(rc.rdU(w, rc.RW_ITER));
        if (rc.rdU(w, rc.RW_SUB) != 0) rp_sub = @floatFromInt(rc.rdU(w, rc.RW_SUB));
    }
    const gb: [3]u32 = @bitCast(rp_grav);
    rp_gon = (gb[0] | gb[1] | gb[2]) & 0x7fffffff != 0;
    if (toggle(z, "Gravity", &rp_gon)) {
        // on: Earth's again, off: none
        rp_grav = .{ 0, if (rp_gon) -9.81 else 0, 0 };
        worldPut(putGrav);
    }
    if (vec3(z, "Gravity", &rp_grav, 0.02, 2, "Gravity (m/s2, X Y Z, -9.81 Y on Earth)")) worldPut(putGrav);
    if (num(z, "Steps a second", &rp_rate, .{ .step = 0.5, .min = 1, .max = 1000, .decimals = 0, .tip = "More steps: fast things collide better, slower to run" })) worldPut(putNums);
    if (num(z, "Iterations", &rp_iter, .{ .step = 0.1, .min = 1, .max = 200, .decimals = 0, .tip = "Solver passes a step: stiffer stacks and joints" })) worldPut(putNums);
    if (num(z, "Substeps", &rp_sub, .{ .step = 0.05, .min = 1, .max = 64, .decimals = 0, .tip = "Soft steps a step" })) worldPut(putNums);
    if (num(z, "G (bodies' pull)", &rp_g, .{ .step = 0.01, .min = 0, .max = 1000000000, .decimals = 3, .tip = "How hard bodies that attract pull: a = G m / d2 (1: game scale)" })) worldPut(putG);
}

/// jflag_cb: limits (1), motor (2).
fn putFlags() void {
    const j = jtOwn() orelse return;
    const f = rc.rdU(j, rc.JT_FLG) & ~@as(u32, 3) | @as(u32, @intFromBool(rp_jlim)) | @as(u32, @intFromBool(rp_jmot)) << 1;
    rc.wrU(j, rc.JT_FLG, f);
}

// ---- simui.s sim_props: cloth, the cloth world, the cache -----------------------

const REST_CW = 13312; // (anim.zig: the cloth world in the block's rest)
const CW_WIND = 0;
const CW_SUB = 12;
const CW_N = 20;
const REST_CL = 13344;
const CL_SZ = 64;
const CL_MAX = 32;

/// cloth_rec: the object's cloth record, or null.
fn clothRec(oid: u32) ?[]const u8 {
    const b = anim.cur orelse return null;
    const n = @min(rc.rdU(&b.rest, REST_CW + CW_N), CL_MAX);
    for (0..n) |k| {
        const r = b.rest[REST_CL + k * CL_SZ ..][0..CL_SZ];
        if (rc.rdU(r, 0) == oid) return r;
    }
    return null;
}

fn simProps(z: *zui.Ui) void {
    if (show_world) {
        if (bkit.section(z, "World", &sec_open[S_WORLD])) {
            z.pushId("§World");
            defer z.popId();
            world(z, anim.cur);
        }
    }
    if (scene.active) |a| {
        if (a < scene.count) {
            const cr = clothRec(scene.objects[a].oid);
            // open on cloth, closed on the rest (two sections, each its own state)
            z.pushIdInt(@intFromBool(cr != null));
            const open = bkit.section(z, "Cloth and Soft Body", &sec_open[if (cr != null) S_CLOTH else S_CLOTH0]);
            z.popId();
            if (open) {
                z.pushId("§Cloth");
                defer z.popId();
                if (cr == null) {
                    para(z, "Make the selected objects cloth, soft bodies or colliders:", ui.th.text_dim);
                    z.beginHorizontal(.{ .spacing = 4 });
                    const ids = [_][]const u8{ "Cloth", "Soft Body", "Collider" };
                    for (ids, 0..) |lb, k| {
                        if (z.button(lb, .{ .width = .fill }).clicked) exec("cloth.add", kw_cltype[k]);
                    }
                    z.endHorizontal();
                } else clothFields(z, cr.?);
            }
        }
    }
    if (bkit.section(z, "Cloth World", &sec_open[S_CWORLD])) {
        z.pushId("§Cloth World");
        defer z.popId();
        if (anim.cur) |b| {
            sm_wind = rc.rd3(&b.rest, REST_CW + CW_WIND);
            const s = rc.rdU(&b.rest, REST_CW + CW_SUB);
            sm_sub = @floatFromInt(if (s != 0) s else 10);
            const lbs = [_][]const u8{ "Wind X", "Y", "Z" };
            var changed = false;
            z.beginHorizontal(.{ .spacing = 4 });
            for (0..3) |k| {
                if (num(z, lbs[k], &sm_wind[k], .{ .step = 0.01, .min = -1e9, .max = 1e9, .decimals = 2 })) changed = true;
            }
            z.endHorizontal();
            if (num(z, "Substeps", &sm_sub, .{ .step = 0.1, .min = 1, .max = 100, .decimals = 0, .tip = "More is more accurate and slower" })) changed = true;
            if (changed) windPut();
        }
    }
    if (bkit.section(z, "Simulation Cache", &sec_open[S_CACHE])) {
        z.pushId("§Simulation Cache");
        defer z.popId();
        cacheLine(z, "Rigid bodies: ", 0);
        cacheLine(z, "Cloth: ", 1);
        var vb: [32]u8 = undefined;
        var mb: [64]u8 = undefined;
        para(z, std.fmt.bufPrint(&mb, "Memory in use: {s} MB", .{cad.fmtVal3(&vb, scInfo(2))}) catch "", ui.th.text_dim);
        bkit.beginPair(z);
        _ = bkit.opButton(z, "sim.bake", .{ .label = "Bake" });
        _ = bkit.opButton(z, "sim.free", .{ .label = "Free" });
        bkit.endPair(z);
        sm_budget = @floatFromInt(cvts(scInfo(6)));
        if (num(z, "Memory budget (MB)", &sm_budget, .{ .step = 1, .min = 16, .max = 1048576, .decimals = 0 })) {
            var a: [32]u8 = undefined;
            exec("sim.cache", std.fmt.bufPrint(&a, "budget {d}", .{@as(i32, @intFromFloat(sm_budget))}) catch "");
        }
    }
}

const cl_rows = [7]struct { l: []const u8, lo: f32, hi: f32, step: f32, dec: u8, tip: []const u8 }{
    .{ .l = "Stretch compliance", .lo = 0, .hi = 1, .step = 0.00001, .dec = 6, .tip = "How much it stretches (m/N, 0: not at all)" },
    .{ .l = "Bend compliance", .lo = 0, .hi = 10, .step = 0.0001, .dec = 5, .tip = "How easily it folds (0: stiff)" },
    .{ .l = "Volume compliance", .lo = 0, .hi = 1, .step = 0.00001, .dec = 6, .tip = "Soft bodies: how much they squash" },
    .{ .l = "Mass (kg)", .lo = 0.001, .hi = 100000, .step = 0.01, .dec = 3, .tip = "" },
    .{ .l = "Damping", .lo = 0, .hi = 10, .step = 0.005, .dec = 3, .tip = "" },
    .{ .l = "Thickness", .lo = 0, .hi = 10, .step = 0.001, .dec = 3, .tip = "How far it stays from colliders" },
    .{ .l = "Friction", .lo = 0, .hi = 2, .step = 0.005, .dec = 3, .tip = "" },
};
const cl_words = [7][]const u8{ " stretch ", " bend ", " volume ", " mass ", " damping ", " thickness ", " friction " };

/// The cloth record's fields: type, the compliances, mass ... self
/// collision; Pin Selected | Unpin All; Remove.
fn clothFields(z: *zui.Ui, r: []const u8) void {
    const t = rc.rdU(r, 4);
    sm_type = (t -% 1) & 3;
    if (sm_type > 2) sm_type = 0;
    for (0..7) |k| sm_vals[k] = rc.rdF(r, 8 + k * 4);
    sm_self = rc.rdU(r, 36) & 1 != 0;
    if (enumField(z, "##cltype", &sm_type, choices(&l_cltype), "Cloth: a sheet. Soft body: a squashy solid. Collider: others bump into it")) clPut();
    for (cl_rows, 0..) |rw, k| {
        if (num(z, rw.l, &sm_vals[k], .{ .step = rw.step, .min = rw.lo, .max = rw.hi, .decimals = rw.dec, .tip = rw.tip })) clPut();
    }
    if (toggle(z, "Collides with itself", &sm_self)) clPut();
    bkit.beginPair(z);
    if (bkit.button(z, "Pin Selected", "Edit mode: the selected vertices hold to the object").clicked) exec("cloth.pin", "selected");
    if (bkit.button(z, "Unpin All", "").clicked) exec("cloth.pin", "none");
    bkit.endPair(z);
    _ = bkit.opButton(z, "cloth.remove", .{ .label = "Remove" });
}

/// sm_cache_line: "Rigid bodies: 120 frames (baked)". (The original's keeps its
/// channel in r12, the row's y, so it draws its line at the page's top, out of
/// sight, and the next row goes where it should have been: a bug, not copied -
/// the two lines show.)
fn cacheLine(z: *zui.Ui, label: []const u8, ch: u32) void {
    var b: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{s}{d} frames{s}", .{ label, cvts(scInfo(ch)), if (scInfo(ch + 3) > 0) " (baked)" else "" }) catch "";
    para(z, s, ui.th.text);
}

/// cl_cb: cloth.add <type> stretch .. friction .. [self] on the selection,
/// six decimals at most (put_num6); the field's step ("Cloth"). (Self off
/// turns it off: the original's cannot, cloth.add has no word for it.)
fn clPut() void {
    var a: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&a);
    w.writeAll(kw_cltype[sm_type]) catch {};
    for (0..7) |k| {
        var nb: [48]u8 = undefined;
        w.print("{s}{s}", .{ cl_words[k], cad_ftoa(&nb, sm_vals[k]) }) catch {};
    }
    if (sm_self) w.writeAll(" self") catch {};
    @import("cloth.zig").addFromPanel(w.buffered(), !sm_self);
    undo.label("Cloth");
    app.dirty = true;
}

fn cad_ftoa(buf: []u8, v: f32) []const u8 {
    return @import("feature.zig").ftoa(buf, v, 6);
}

/// wind_cb: cloth.world wind x y z substeps n; the field's step ("Cloth World").
fn windPut() void {
    var a: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&a);
    w.writeAll("wind ") catch {};
    for (0..3) |k| {
        var nb: [48]u8 = undefined;
        w.print("{s} ", .{cad_ftoa(&nb, sm_wind[k])}) catch {};
    }
    w.print(" substeps {d}", .{cvtt(sm_sub)}) catch {};
    @import("cloth.zig").worldFromPanel(w.buffered());
    undo.label("Cloth World");
    app.dirty = true;
}

/// cvtss2si: rounded to nearest.
fn cvts(x: f32) i32 {
    if (!(x > -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(@round(x));
}

test "material presets by their bits" {
    var r: [rc.RB_SZ]u8 = @splat(0);
    rc.wrF(&r, rc.RB_FRIC, 0.9);
    rc.wrF(&r, rc.RB_REST, 0.8);
    try std.testing.expectEqual(@as(usize, 1), pmWhich(&r));
    rc.wrF(&r, rc.RB_REST, 0.80001);
    try std.testing.expectEqual(@as(usize, 6), pmWhich(&r));
    rc.wrF(&r, rc.RB_FRIC, 0.5);
    rc.wrF(&r, rc.RB_REST, 0);
    try std.testing.expectEqual(@as(usize, 0), pmWhich(&r));
}
