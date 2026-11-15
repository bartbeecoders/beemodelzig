// Armature edit mode (Tab: the rest bones' joints) and pose mode (Ctrl+Tab: the
// bones' poses), and the armature operators (arm.s): picking, the overlay,
// transforms, keys. The file's other half, the bones and skinning, is arm.zig.
const std = @import("std");
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const scene = @import("scene.zig");
const anim = @import("anim.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const arm = @import("arm.zig");
const mods = @import("mods.zig");
const em = @import("editmesh.zig");
const vp = @import("viewport.zig");
const ui = @import("ui.zig");
const M = arm.M;
const Block = arm.Block;

pub const COL_BONE: u32 = 0xc8ccd4;
pub const COL_BONE_SEL: u32 = 0xffa030;
pub const COL_BONE_ACT: u32 = 0xffd27a;

const AT_MAX = 256;

/// 0 none, 1 armature edit mode, 2 pose mode.
pub var mode: u32 = 0;
/// The object in a mode (oid).
pub var oid: u32 = 0;

const Entry = struct {
    bone: u32,
    part: u32, // 0 head, 1 tail, 2 the pose
    world: [3]f32 = .{ 0, 0, 0 },
    loc: [3]f32 = .{ 0, 0, 0 },
    pose: [9]f32 = @splat(0),
    f: M = undefined, // the frame its pose sits in: M = F P
};
var at_buf: [AT_MAX]Entry = undefined;
var at_n: usize = 0;
var at_mesh: ?u16 = null; // the mesh it had before (a cancel goes back to it)
var au_a: M = undefined; // the armature object's matrix
var au_ai: M = undefined; // and its inverse

/// The object in a mode (leaves it when it went).
fn get() ?usize {
    if (mode == 0) return null;
    const i = scene.findOid(oid) orelse {
        mode = 0;
        return null;
    };
    if (scene.objects[i].kind != .armature) {
        mode = 0;
        return null;
    }
    return i;
}

pub fn active() bool {
    return get() != null;
}

fn enter(md: u32) bool {
    if (mode != 0) {
        if (mode == md) {
            mode = 0;
            app.dirty = true;
            return true;
        }
    } else {
        const a = scene.active orelse return false;
        if (scene.objects[a].kind != .armature) return false;
        oid = scene.objects[a].oid;
    }
    mode = md;
    app.log("{s}", .{if (md == 1) "  armature edit mode (Tab leaves; click joints, G/R/S, E extrude, X delete)" else "  pose mode (Ctrl+Tab leaves; click bones, G/R/S, I key, Alt+R clear)"});
    app.dirty = true;
    return true;
}

/// Tab: true when it meant an armature mode.
pub fn tab() bool {
    return enter(1);
}
/// Ctrl+Tab: the same for pose mode.
pub fn ctrlTab() bool {
    return enter(2);
}

fn setup(i: usize) void {
    au_a = arm.objMat(i);
    au_ai = arm.mInv(&au_a);
    if (arm.of(i)) |b| arm.poseMats(b, i);
}

/// Where a joint is shown: rest (edit mode) or posed (pose mode), in the world.
fn joint(b: *const Block, k: usize, tail: bool) [3]f32 {
    const x = &b.bones[k];
    if (mode == 2) {
        const l: [3]f32 = if (tail) arm.tailOf(b, k) else .{ arm.am_m[k][3], arm.am_m[k][7], arm.am_m[k][11] };
        return arm.xformPoint(&au_a, l);
    }
    return arm.xformPoint(&au_a, if (tail) x.tail else x.head);
}

/// The bones as lines (selected orange, the active one brighter), joints as
/// dots in edit mode.
pub fn overlay(cv: *gfx.Canvas, c: *const vp.Cam) void {
    const i = get() orelse return;
    const b = arm.of(i) orelse return;
    setup(i);
    for (b.bones[0..b.n], 0..) |*x, k| {
        const p0 = joint(b, k, false);
        const p1 = joint(b, k, true);
        var col = COL_BONE;
        if (x.sel & arm.SEL_BONE != 0) col = if (k == b.act) COL_BONE_ACT else COL_BONE_SEL;
        vp.line3(cv, c, p0, p1, col);
        if (mode != 1) continue;
        for ([_][3]f32{ p0, p1 }, [_]u8{ arm.SEL_HEAD, arm.SEL_TAIL }) |p, bit| {
            const s = c.project(p) orelse continue;
            cv.fillCircle(s[0], s[1], 3, if (x.sel & bit != 0) COL_BONE_SEL else COL_BONE);
        }
    }
}

/// A click in a mode: the nearest joint (edit mode) or bone; Shift toggles, else
/// it alone. True when in a mode.
pub fn click(v: *const vp.View, r: gfx.Rect, x: i32, y: i32, shift: bool) bool {
    const i = get() orelse return false;
    const b = arm.of(i) orelse return false;
    const c = vp.Cam.init(v, r);
    setup(i);
    var best: i32 = -1;
    var bits: u8 = 0;
    var bd: i32 = 14 * 14;
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    for (0..b.n) |k| {
        const a = c.project(joint(b, k, false)) orelse continue;
        const e = c.project(joint(b, k, true)) orelse continue;
        const pa: [2]f32 = .{ @floatFromInt(a[0]), @floatFromInt(a[1]) };
        const pe: [2]f32 = .{ @floatFromInt(e[0]), @floatFromInt(e[1]) };
        if (mode == 1) {
            for ([_][2]f32{ pa, pe }, 0..) |p, q| {
                const d: i32 = @intFromFloat(@min((p[0] - fx) * (p[0] - fx) + (p[1] - fy) * (p[1] - fy), 1e9));
                if (d < bd) {
                    bd = d;
                    best = @intCast(k);
                    bits = @intCast(q + 1);
                }
            }
        }
        // the bone: distance to its segment on screen (worse than a joint)
        const dx = pe[0] - pa[0];
        const dy = pe[1] - pa[1];
        const ex = fx - pa[0];
        const ey = fy - pa[1];
        var t = (dx * ex + dy * ey) / arm.maxss(dx * dx + dy * dy, 1e-6);
        t = arm.minss(arm.maxss(t, 0), 1);
        const qx = ex - dx * t;
        const qy = ey - dy * t;
        const d: i32 = @as(i32, @intFromFloat(@min(qx * qx + qy * qy, 1e9))) + 30; // (a joint wins when as near)
        if (d < bd) {
            bd = d;
            best = @intCast(k);
            bits = 7;
        }
    }
    if (!shift) {
        for (b.bones[0..b.n]) |*q| q.sel = 0;
    }
    if (best >= 0) {
        const q = &b.bones[@intCast(best)];
        if (shift) q.sel ^= bits else q.sel = bits;
        b.act = @intCast(best);
    }
    app.dirty = true;
    return true;
}

// --- transforms ----------------------------------------------------------------------------

/// The middle of the selected parts.
fn median(b: *const Block, n: *usize) [3]f32 {
    var s: [3]f32 = .{ 0, 0, 0 };
    n.* = 0;
    for (b.bones[0..b.n], 0..) |*x, k| {
        if (x.sel == 0) continue;
        const p = joint(b, k, x.sel == arm.SEL_TAIL); // (its head, or its tail alone)
        for (0..3) |c| s[c] += p[c];
        n.* += 1;
    }
    if (n.* == 0) return s;
    const f: f32 = @floatFromInt(n.*);
    return .{ s[0] / f, s[1] / f, s[2] / f };
}

/// Parts that move: each selected joint (edit mode) or bone (pose mode). The
/// bones are the object's own from here on; a cancel gives its mesh back.
pub fn tmBegin(pivot: *[3]f32) usize {
    at_n = 0;
    const i = get() orelse return 0;
    at_mesh = scene.objects[i].mesh;
    var any: u8 = 0;
    for ((arm.of(i) orelse return 0).bones[0..arm.of(i).?.n]) |*x| any |= x.sel;
    if (any == 0) return 0;
    const b = arm.own(i) orelse return 0;
    setup(i);
    var n: usize = 0;
    pivot.* = median(b, &n);
    for (b.bones[0..b.n], 0..) |*x, k| {
        if (x.sel == 0) continue;
        if (mode == 2) {
            if (at_n == AT_MAX) break;
            var e = Entry{ .bone = @intCast(k), .part = 2 };
            e.pose = @as(*const [9]f32, @ptrCast(&x.loc)).*;
            const p = arm.trs(&x.loc, &x.rot, &x.scale);
            const pi = arm.mInv(&p);
            e.f = arm.mMul(&arm.am_m[k], &pi);
            at_buf[at_n] = e;
            at_n += 1;
            continue;
        }
        for ([_]u8{ arm.SEL_HEAD, arm.SEL_TAIL }, 0..) |bit, part| {
            if (x.sel & bit == 0 or at_n == AT_MAX) continue;
            const l = if (part == 0) x.head else x.tail;
            at_buf[at_n] = .{ .bone = @intCast(k), .part = @intCast(part), .loc = l, .world = arm.xformPoint(&au_a, l) };
            at_n += 1;
        }
    }
    return at_n;
}

fn store(b: *Block, e: *const Entry, w: [3]f32) void {
    const x = &b.bones[e.bone];
    const l = arm.xformPoint(&au_ai, w);
    if (e.part == 0) x.head = l else x.tail = l;
}

fn restorePose(b: *Block, e: *const Entry) *arm.Bone {
    const x = &b.bones[e.bone];
    @as(*[9]f32, @ptrCast(&x.loc)).* = e.pose;
    return x;
}

/// Joined joints follow, the display mesh shows it.
fn finish(i: usize, b: *Block) void {
    if (mode == 1) {
        for (b.bones[0..b.n]) |*x| {
            if (x.conn == 0 or x.parent < 0) continue;
            const p = &b.bones[@intCast(x.parent)];
            if (x.sel & arm.SEL_HEAD != 0 and p.sel & arm.SEL_TAIL == 0) p.tail = x.head else x.head = p.tail;
        }
    }
    arm.rebuild(i);
}

/// Back to the start of the transform, the values of each part.
pub fn tmRestore() void {
    const i = get() orelse return;
    const b = arm.of(i) orelse return;
    for (at_buf[0..at_n]) |*e| {
        if (e.part == 2) {
            _ = restorePose(b, e);
        } else store(b, e, e.world);
    }
}

/// After a step of the transform: joined joints, the display mesh.
pub fn tmUpdate() void {
    const i = get() orelse return;
    const b = arm.of(i) orelse return;
    finish(i, b);
}

/// `d`: a world delta.
pub fn tmGrab(d: [3]f32) void {
    const i = get() orelse return;
    const b = arm.of(i) orelse return;
    for (at_buf[0..at_n]) |*e| {
        if (e.part != 2) {
            store(b, e, .{ e.world[0] + d[0], e.world[1] + d[1], e.world[2] + d[2] });
            continue;
        }
        // a bone: the delta into F's axes
        const x = restorePose(b, e);
        var ad: [3]f32 = undefined;
        for (0..3) |r| ad[r] = au_ai[r * 4] * d[0] + au_ai[r * 4 + 1] * d[1] + au_ai[r * 4 + 2] * d[2];
        const fi = arm.mInv(&e.f);
        for (0..3) |r| x.loc[r] = fi[r * 4] * ad[0] + fi[r * 4 + 1] * ad[1] + fi[r * 4 + 2] * ad[2] + x.loc[r];
    }
}

/// `rw`: a world rotation. Joints about the pivot; bones about their own heads
/// (their pose's rotation).
pub fn tmRotate(rw: *const M, pivot: [3]f32) void {
    const i = get() orelse return;
    const b = arm.of(i) orelse return;
    for (at_buf[0..at_n]) |*e| {
        if (e.part != 2) {
            const q = arm.xformPoint(rw, .{ e.world[0] - pivot[0], e.world[1] - pivot[1], e.world[2] - pivot[2] });
            store(b, e, .{ q[0] + pivot[0], q[1] + pivot[1], q[2] + pivot[2] });
            continue;
        }
        // P' = F^-1 Ra (F P), Ra = A^-1 Rw A
        const x = restorePose(b, e);
        const t1 = arm.mMul(rw, &au_a);
        var ra = arm.mMul(&au_ai, &t1);
        const p = arm.trs(&x.loc, &x.rot, &x.scale);
        const cur = arm.mMul(&e.f, &p);
        ra[3] = 0;
        ra[7] = 0;
        ra[11] = 0;
        var nw = arm.mMul(&ra, &cur);
        nw[3] = cur[3];
        nw[7] = cur[7];
        nw[11] = cur[11];
        const fi = arm.mInv(&e.f);
        const pn = arm.mMul(&fi, &nw);
        const q = arm.poseFromMat(&pn);
        x.loc = q.loc;
        x.rot = q.rot;
        x.scale = q.scale;
    }
}

/// `axis`: 0 all, else a world axis (a joint) or the bone's (a pose) 1..3.
pub fn tmScale(f: f32, axis: u32, pivot: [3]f32) void {
    const i = get() orelse return;
    const b = arm.of(i) orelse return;
    for (at_buf[0..at_n]) |*e| {
        if (e.part != 2) {
            var q = e.world;
            for (0..3) |c| {
                if (axis == 0 or axis == c + 1) q[c] = (q[c] - pivot[c]) * f + pivot[c];
            }
            store(b, e, q);
            continue;
        }
        const x = restorePose(b, e);
        for (0..3) |c| {
            if (axis == 0 or axis == c + 1) x.scale[c] *= f;
        }
    }
}

/// A cancelled transform: the mesh as it was.
pub fn tmCancel() void {
    tmRestore();
    const i = get() orelse return;
    if (at_mesh) |mi| {
        if (scene.objects[i].mesh != mi and scene.meshes[mi] != null) {
            scene.objects[i].mesh = mi;
            return;
        }
    }
    if (arm.of(i)) |b| finish(i, b);
}

// --- operators -----------------------------------------------------------------------------

const Words = std.mem.TokenIterator(u8, .any);
fn words() Words {
    return std.mem.tokenizeAny(u8, ops.arg, " \"");
}

fn num(w: ?[]const u8) ?f32 {
    const s = w orelse return null;
    const v = std.fmt.parseFloat(f32, s) catch return null;
    return if (std.math.isFinite(v)) v else null;
}
fn three(it: *Words) ?[3]f32 {
    var o: [3]f32 = undefined;
    for (&o) |*x| x.* = num(it.next()) orelse return null;
    return o;
}

/// The active object when it is an armature.
fn target() ?usize {
    const a = scene.active;
    if (a) |i| {
        if (scene.objects[i].kind == .armature) return i;
    }
    app.log("  not an armature (create.armature makes one)", .{});
    return null;
}

/// create.armature [name] (a script names it)
pub fn opAdd() void {
    const nm = std.mem.trim(u8, ops.arg, " \"");
    const i = arm.create(if (nm.len > 0) nm else null) orelse return;
    scene.objects[i].loc = scene.cursor;
    app.log("  added {s}", .{scene.objects[i].name()});
}

/// arm.bone <name> <parent|-> <hx hy hz> <tx ty tz>
pub fn opBone() void {
    const bad = "  arm.bone <name> <parent|-> <hx hy hz> <tx ty tz>";
    const i = target() orelse return;
    var it = words();
    const nm = it.next() orelse return app.log(bad, .{});
    const pw = it.next() orelse return app.log(bad, .{});
    var par: i32 = -1;
    if (!std.mem.eql(u8, pw, "-")) {
        const b = arm.of(i) orelse return;
        par = @intCast(arm.findBone(b, pw) orelse return app.log("  no bone named {s}", .{pw}));
    }
    const h = three(&it) orelse return app.log(bad, .{});
    const t = three(&it) orelse return app.log(bad, .{});
    const b = arm.own(i) orelse return;
    const k = arm.addBone(b, nm, par, h, t) orelse return app.log(bad, .{});
    if (par >= 0) {
        const p = &b.bones[@intCast(par)];
        var joined = true;
        for (0..3) |c| {
            if (!(@abs(h[c] - p.tail[c]) <= 1.0e-4)) joined = false;
        }
        if (joined) b.bones[k].conn = 1;
    }
    arm.rebuild(i);
}

/// arm.pose <bone> <loc|rot|scale> <x> <y> <z>
pub fn opPose() void {
    const i = target() orelse return;
    var it = words();
    const nm = it.next() orelse "";
    const b0 = arm.of(i) orelse return;
    const k = arm.findBone(b0, nm) orelse return app.log("  no bone named {s}", .{nm});
    const what = it.next() orelse "";
    var v = three(&it) orelse return app.log("  no bone named {s}", .{nm});
    const rot = std.mem.eql(u8, what, "rot");
    const scl = std.mem.eql(u8, what, "scale");
    if (rot) {
        for (&v) |*x| x.* *= 0.017453292;
    }
    const b = arm.own(i) orelse return;
    const x = &b.bones[k];
    if (rot) x.rot = v else if (scl) x.scale = v else x.loc = v;
    arm.rebuild(i);
}

/// arm.select_bone <bone> [extend]
pub fn opSelect() void {
    const i = target() orelse return;
    const b = arm.of(i) orelse return;
    var it = words();
    const k = arm.findBone(b, it.next() orelse "") orelse return;
    if (!std.mem.eql(u8, it.next() orelse "", "extend")) {
        for (b.bones[0..b.n]) |*x| x.sel = 0;
    }
    b.bones[k].sel = 7;
    b.act = k;
    app.dirty = true;
}

/// A mesh object by name (null: it says how).
fn meshByName(w: []const u8) ?usize {
    const i = scene.find(w) orelse return null;
    const o = &scene.objects[i];
    return if (o.kind.isMesh() and o.mesh != null) i else null;
}

/// The object its first Armature modifier names.
pub fn modTarget(i: usize) ?usize {
    const o = &scene.objects[i];
    for (o.mods.m[0..o.mods.n]) |*d| {
        if (d.kind != mods.ARMATURE) continue;
        const t = mods.target(d) orelse return null;
        return if (scene.objects[t].kind == .armature) t else null;
    }
    return null;
}

fn modIndex(i: usize) ?usize {
    const o = &scene.objects[i];
    for (o.mods.m[0..o.mods.n], 0..) |*d, k| {
        if (d.kind == mods.ARMATURE) return k;
    }
    return null;
}

/// arm.parent <mesh> <armature> [dual]: an Armature modifier, automatic weights.
pub fn opParent() void {
    const bad = "  arm.parent <mesh> <armature> [dual]";
    var it = words();
    const mo = meshByName(it.next() orelse "") orelse return app.log(bad, .{});
    const ai = scene.find(it.next() orelse "") orelse return app.log(bad, .{});
    if (scene.objects[ai].kind != .armature) return app.log(bad, .{});
    const dual = std.mem.eql(u8, it.next() orelse "", "dual");
    const k = modIndex(mo) orelse (mods.add(mo, mods.ARMATURE) orelse return app.log(bad, .{}));
    const d = &scene.objects[mo].mods.m[k];
    d.p[0] = scene.objects[ai].oid;
    mods.setF(d, 1, if (dual) 1 else 0);
    _ = arm.autoWeights(mo, ai);
    app.log("  automatic weights: {s}", .{scene.objects[mo].name()});
}

/// arm.auto_weights <mesh>
pub fn opAutoWeights() void {
    var it = words();
    const mo = meshByName(it.next() orelse "") orelse return;
    const ai = modTarget(mo) orelse return app.log("  no weights: the mesh needs an Armature modifier (arm.parent)", .{});
    _ = arm.autoWeights(mo, ai);
}

/// arm.clear_pose: back to rest, the selected bones (all when none is).
pub fn opClear() void {
    const i = target() orelse return;
    const b = arm.own(i) orelse return;
    var any: u8 = 0;
    for (b.bones[0..b.n]) |*x| any |= x.sel;
    for (b.bones[0..b.n]) |*x| {
        if (any != 0 and x.sel == 0) continue;
        x.loc = .{ 0, 0, 0 };
        x.rot = .{ 0, 0, 0 };
        x.scale = .{ 1, 1, 1 };
    }
    arm.rebuild(i);
}

pub fn pollMode() ?[]const u8 {
    return if (mode == 0) "Only in an armature mode (Tab, Ctrl+Tab)" else null;
}

/// arm.extrude: a new bone from each selected tail (as long, the same way),
/// joined, then move it.
pub fn opExtrude() void {
    const i = get() orelse return;
    if (mode != 1) return;
    var any: u8 = 0;
    for ((arm.of(i) orelse return).bones[0..arm.of(i).?.n]) |*x| any |= x.sel & arm.SEL_TAIL;
    if (any == 0) return app.log("  select a bone's tail to extrude from", .{});
    const b = arm.own(i) orelse return;
    const n0 = b.n;
    var made: usize = 0;
    for (0..n0) |k| {
        const x = &b.bones[k];
        if (x.sel & arm.SEL_TAIL == 0) continue;
        x.sel = 0;
        var t: [3]f32 = undefined;
        for (0..3) |c| t[c] = (x.tail[c] + x.tail[c]) - x.head[c];
        const nb = arm.addBone(b, null, @intCast(k), x.tail, t) orelse continue;
        b.bones[nb].conn = 1;
        b.bones[nb].sel = arm.SEL_TAIL; // its tail, ready to move
        made += 1;
    }
    arm.rebuild(i);
    if (!ops.scripted) _ = app.beginTransform(.move);
}

/// arm.delete_bones: the selected bones go; their children take their parent;
/// every mesh skinned by this armature has its weights renumbered.
pub fn opDelete() void {
    const i = get() orelse return;
    if (mode != 1) return;
    var picked: u32 = 0;
    const b0 = arm.of(i) orelse return;
    for (b0.bones[0..b0.n]) |*x| picked += @intFromBool(x.sel & arm.SEL_BONE != 0);
    if (picked == 0 or picked == b0.n) return; // (nothing selected; not every bone)
    const b = arm.own(i) orelse return;
    var map: [arm.MAXB]u8 = @splat(0xff);
    var left: u32 = 0;
    for (b.bones[0..b.n], 0..) |*x, k| {
        if (x.sel & arm.SEL_BONE != 0) continue;
        map[k] = @intCast(left);
        left += 1;
    }
    for (b.bones[0..b.n]) |*x| {
        while (x.parent >= 0 and map[@intCast(x.parent)] == 0xff) {
            x.parent = b.bones[@intCast(x.parent)].parent;
            x.conn = 0;
        }
    }
    var at: usize = 0;
    for (0..b.n) |k| {
        if (map[k] == 0xff) continue;
        const x = &b.bones[k];
        if (x.parent >= 0) x.parent = map[@intCast(x.parent)];
        if (at != k) b.bones[at] = x.*;
        at += 1;
    }
    b.n = left;
    b.act = 0;
    arm.rebuild(i);
    for (0..scene.count) |k| {
        if (modTarget(k) != i) continue;
        if (scene.meshOfObj(k) == null or scene.meshOfObj(k).?.wgt.len == 0) continue;
        const me = arm.meshOwn(k) orelse continue;
        for (me.wgt) |*g| {
            for (0..4) |c| {
                if (g.bone[c] == 0xff) continue;
                const nb = if (g.bone[c] < arm.MAXB) map[g.bone[c]] else 0xff;
                g.bone[c] = nb;
                if (nb == 0xff) g.w[c] = 0;
            }
        }
        scene.bumpShape(scene.objects[k].mesh.?);
    }
}

/// arm.select_all: every bone, or none when some are.
pub fn opSelectAll() void {
    const i = get() orelse return;
    const b = arm.of(i) orelse return;
    var any: u8 = 0;
    for (b.bones[0..b.n]) |*x| any |= x.sel;
    for (b.bones[0..b.n]) |*x| x.sel = if (any != 0) 0 else 7;
    app.dirty = true;
}

/// arm.insert_key: pose mode, the selected bones' nine channels at the frame.
pub fn opKey() void {
    const i = get() orelse return;
    if (mode != 2) return;
    const b = arm.of(i) orelse return;
    const id = scene.objects[i].oid;
    for (0..b.n) |k| {
        if (b.bones[k].sel == 0) continue;
        for (0..9) |c| anim.keyBone(id, @intCast(k), @intCast(c));
    }
}

/// anim.motion_paths: pose mode's selected bones.
pub fn selectedBones(who: *[4][2]i64) usize {
    const i = get() orelse return 0;
    if (mode != 2) return 0;
    const b = arm.of(i) orelse return 0;
    var n: usize = 0;
    for (b.bones[0..b.n], 0..) |*x, k| {
        if (n == who.len) break;
        if (x.sel & arm.SEL_BONE == 0) continue;
        who[n] = .{ scene.objects[i].oid, @intCast(k) };
        n += 1;
    }
    return n;
}
