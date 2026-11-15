// Sketch mode (sketchui.s): draw, select, drag and constrain in the viewport.
//
// Tab on a sketch object enters it. Tools: L line (a chain; clicks on points
// reuse them, nearly level / plumb lines become horizontal / vertical), O
// circle (centre, then a point on it), R rectangle (two corners); Esc ends a
// tool, then clears the selection, then leaves. Without a tool a click picks
// points and entities (Shift adds) and points can be dragged: the sketch
// solves as they move. Keys on the selection: C coincident (point + line /
// circle: on it), H horizontal, V vertical, E equal, P parallel, N
// perpendicular, T tangent, F fix, M midpoint, D dimension (length, distance,
// radius / diameter, angle; typed on the command line, expressions welcome),
// X delete.
const std = @import("std");
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const scene = @import("scene.zig");
const ops = @import("ops.zig");
const vp = @import("viewport.zig");
const sk = @import("sketch.zig");
const skobj = @import("skobj.zig");
/// s_sm_head: a sketch edit's undo step, as the original's History names it
/// (with its space: the same text heads its status line).
const s_sm_head = "Sketch ";
const cad = @import("cad.zig");
const Rect = gfx.Rect;
const Impl = ops.Impl;

pub const T_SELECT = 0;
pub const T_LINE = 1;
pub const T_CIRCLE = 2;
pub const T_RECT = 3;
const MAX_SEL = 64;
const K_PT: u32 = 1; // selection kinds (<< 16 | index)
const K_ENT: u32 = 2;
const SNAP2: f32 = 81.0; // the pick radius (9 px), squared
const md_tan: f64 = 0.035; // |dy| / |dx| below this: horizontal

/// The sketch object being edited (its oid; 0: not in sketch mode).
pub var obj_oid: u32 = 0;
pub var tool: u32 = T_SELECT;
var stage: u32 = 0; // 0: waiting for the first click
var prev: i32 = -1; // the chain's last point
var first: i32 = -1; // a rectangle's snapped first corner
var p0: [2]f64 = .{ 0, 0 }; // the first click (u, v)
pub var sel: [MAX_SEL]u32 = undefined;
pub var nsel: usize = 0;
var dimsel: [MAX_SEL]u32 = undefined; // the selection a pending D measures
var ndimsel: usize = 0;
var drag_pt: i32 = -1;
var drag_con: i32 = -1;
var hx: i32 = 0; // the pointer over ...
var hy: i32 = 0;
var hvp: i16 = -1; // ... this area, for previews
/// Bumped when what the overlay shows changes (tests, redraws).
pub var version: u32 = 0;

fn touch() void {
    version +%= 1;
    app.dirty = true;
}

/// The sketch object being edited (null, and sketch mode ends, when it is
/// gone or no longer a sketch).
pub fn cur() ?usize {
    if (obj_oid == 0) return null;
    const i = scene.findOid(obj_oid) orelse {
        obj_oid = 0;
        return null;
    };
    if (skobj.of(i) == null) {
        obj_oid = 0;
        return null;
    }
    return i;
}

pub fn on() bool {
    return cur() != null;
}

/// skm_can: the active object is a sketch.
pub fn can() bool {
    const a = scene.active orelse return false;
    return scene.objects[a].kind == .sketch;
}

/// skm_toggle: Tab on a sketch, in or out of sketch mode.
pub fn toggle() void {
    if (obj_oid != 0) {
        obj_oid = 0;
    } else {
        const a = scene.active orelse return;
        obj_oid = scene.objects[a].oid;
        tool = T_SELECT;
        stage = 0;
        nsel = 0;
        app.log("  sketch mode: L line, O circle, R rectangle; C H V E P N T F M constraints, D dimension, X delete; Tab leaves", .{});
    }
    touch();
}

/// Tab (edit.s): sketch mode in or out -> true when it took the key.
pub fn tab() bool {
    if (obj_oid != 0 or can()) {
        if (obj_oid == 0 and @import("editmesh.zig").active) return false;
        toggle();
        return true;
    }
    return false;
}

/// skm_escape: true when sketch mode took the Esc (a tool ends, then the
/// selection clears, then sketch mode ends).
pub fn escape() bool {
    if (obj_oid == 0) return false;
    touch();
    if (tool != T_SELECT) {
        tool = T_SELECT;
        stage = 0;
        return true;
    }
    if (nsel != 0) {
        nsel = 0;
        return true;
    }
    obj_oid = 0;
    return true;
}

/// skm_hover: previews follow the pointer.
pub fn hover(x: i32, y: i32, area: i16) void {
    if (obj_oid == 0) return;
    hx = x;
    hy = y;
    hvp = area;
    if (tool != T_SELECT) touch();
}

// --- the plane on the screen ----------------------------------------------------------

/// The object's matrix and the plane's world origin and axes (frame).
const Frame = struct {
    mtx: m.M4,
    o: m.V3,
    u: m.V3,
    v: m.V3,
    b: *const sk.Block,
};

fn v3(p: [3]f32) m.V3 {
    return .{ p[0], p[1], p[2] };
}

fn frameOf(i: usize) ?Frame {
    const b = skobj.of(i) orelse return null;
    const mtx = scene.world(i);
    const o = m.xform(mtx, v3(sk.planeXyz(b, 0, 0)));
    const u = m.xform(mtx, v3(sk.planeXyz(b, 1, 0)));
    const v = m.xform(mtx, v3(sk.planeXyz(b, 0, 1)));
    return .{ .mtx = mtx, .o = o, .u = m.sub(u, o), .v = m.sub(v, o), .b = b };
}

fn dot3(a: m.V3, b: m.V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// ray_uv: the pointer's ray on the sketch plane -> (u, v), or null.
fn rayUv(f: *const Frame, c: *const vp.Cam, x: i32, y: i32) ?[2]f64 {
    const sx = (@as(f32, @floatFromInt(x)) - c.cx) / c.f;
    const sy = (c.cy - @as(f32, @floatFromInt(y))) / c.f;
    var d: m.V3 = undefined;
    for (0..3) |k| d[k] = c.right[k] * sx + c.up[k] * sy + c.fwd[k];
    const n: m.V3 = .{
        f.u[1] * f.v[2] - f.u[2] * f.v[1],
        f.u[2] * f.v[0] - f.u[0] * f.v[2],
        f.u[0] * f.v[1] - f.u[1] * f.v[0],
    };
    const dn = dot3(d, n);
    if (!(@abs(dn) > 1e-9)) return null;
    const t = dot3(m.sub(f.o, c.eye), n) / dn;
    var w: m.V3 = undefined;
    for (0..3) |k| w[k] = d[k] * t + c.eye[k] - f.o[k];
    // [UU UV; UV VV] [u v] = [U.w V.w]
    const a: f64 = dot3(f.u, f.u);
    const b: f64 = dot3(f.u, f.v);
    const cc: f64 = dot3(f.v, f.v);
    const p: f64 = dot3(f.u, w);
    const q: f64 = dot3(f.v, w);
    const det = a * cc - b * b;
    return .{ (p * cc - q * b) / det, (q * a - p * b) / det };
}

/// The screen spot of (u, v) on the plane, or null behind the eye.
fn screen(f: *const Frame, c: *const vp.Cam, u: f64, v: f64) ?[2]f32 {
    const w = m.xform(f.mtx, v3(sk.planeXyz(f.b, u, v)));
    const cv = c.toView(w);
    if (!(cv[2] >= 0.05)) return null;
    const s = c.screen(cv);
    return .{ s[0], s[1] };
}

fn pscreen(f: *const Frame, c: *const vp.Cam, p: i32) ?[2]f32 {
    const q = sk.pointXY(f.b, p);
    return screen(f, c, q[0], q[1]);
}

/// pick_point: the nearest point within the pick radius, or -1.
fn pickPoint(f: *const Frame, c: *const vp.Cam, x: i32, y: i32) i32 {
    var best: i32 = -1;
    var bd: f32 = SNAP2;
    const px: f32 = @floatFromInt(x);
    const py: f32 = @floatFromInt(y);
    var k: u32 = 0;
    while (k < f.b.npt and k < sk.MAX_PT) : (k += 1) {
        const s = pscreen(f, c, @intCast(k)) orelse continue;
        const dx = s[0] - px;
        const dy = s[1] - py;
        const d = dx * dx + dy * dy;
        if (d < bd) {
            bd = d;
            best = @intCast(k);
        }
    }
    return best;
}

/// seg_d2: the distance squared from p to the segment a b
fn segD2(a: [2]f32, b: [2]f32, p: [2]f32) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const ax = p[0] - a[0];
    const ay = p[1] - a[1];
    const pd = ax * dx + ay * dy;
    var dd = dx * dx + dy * dy;
    dd = if (dd > 1e-9) dd else 1e-9;
    var t = pd / dd;
    t = if (t > 0) t else 0;
    t = if (t < 1) t else 1;
    const ex = ax - dx * t;
    const ey = ay - dy * t;
    return ex * ex + ey * ey;
}

fn entScreen(f: *const Frame, c: *const vp.Cam, e: *const sk.Ent, i: u32, n: u32) ?[2]f32 {
    const uv = sk.entAt(f.b, e, i, n);
    return screen(f, c, uv[0], uv[1]);
}

/// pick_entity: the nearest entity within the pick radius, or -1.
fn pickEntity(f: *const Frame, c: *const vp.Cam, x: i32, y: i32) i32 {
    var best: i32 = -1;
    var bd: f32 = SNAP2;
    const p: [2]f32 = .{ @floatFromInt(x), @floatFromInt(y) };
    var k: u32 = 0;
    while (k < f.b.nent and k < sk.MAX_ENT) : (k += 1) {
        const e = &f.b.ents[k];
        const n = sk.entSegs(e);
        var a = entScreen(f, c, e, 0, n) orelse continue;
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const b = entScreen(f, c, e, i, n) orelse break;
            const d = segD2(a, b, p);
            if (d < bd) {
                bd = d;
                best = @intCast(k);
            }
            a = b;
        }
    }
    return best;
}

// --- clicks ------------------------------------------------------------------------------

/// snap: a point under the pointer (its position), else the ray on the plane.
fn snap(f: *const Frame, c: *const vp.Cam, x: i32, y: i32, pt: *i32) ?[2]f64 {
    pt.* = pickPoint(f, c, x, y);
    if (pt.* >= 0) return sk.pointXY(f.b, pt.*);
    return rayUv(f, c, x, y);
}

fn addCoin(b: *sk.Block, p: i32, q: i32) void {
    if (p != q) _ = sk.addCon(b, sk.C_COINCIDENT, p, q, -1, 0, null);
}

/// skm_click: a click in sketch mode (r: the viewport's body).
pub fn click(v: *const vp.View, r: Rect, x: i32, y: i32, shift: bool) void {
    defer touch();
    const i = cur() orelse return;
    const f = frameOf(i) orelse return;
    const c = vp.Cam.init(v, r);
    if (tool == T_SELECT) {
        var key: u32 = 0;
        const pp = pickPoint(&f, &c, x, y);
        if (pp >= 0) {
            key = K_PT << 16 | @as(u32, @intCast(pp));
        } else {
            const pe = pickEntity(&f, &c, x, y);
            if (pe >= 0) key = K_ENT << 16 | @as(u32, @intCast(pe));
        }
        if (key == 0) {
            if (!shift) nsel = 0; // nothing: clear
            return;
        }
        if (!shift) nsel = 0;
        selToggle(key);
        return;
    }
    var spt: i32 = -1;
    const uv = snap(&f, &c, x, y, &spt) orelse return;
    if (stage == 0) {
        stage = 1; // the first click
        p0 = uv;
        prev = spt;
        first = spt;
        return;
    }
    @import("undo.zig").label(s_sm_head);
    const b = skobj.begin(i) orelse return;
    defer _ = skobj.end(i);
    switch (tool) {
        T_RECT => {
            // from the first corner to here; snapped corners joined
            const e = skobj.rect(b, p0[0], p0[1], uv[0] - p0[0], uv[1] - p0[1]);
            if (e < 0) return;
            if (first >= 0) addCoin(b, sk.entPoint(b, e, 0), first);
            if (spt >= 0) addCoin(b, sk.entPoint(b, e + 1, 1), spt);
            stage = 0;
        },
        T_LINE => {
            var a = prev; // the start: the chain's point
            if (a < 0) {
                a = sk.addPoint(b, p0[0], p0[1]);
                if (a < 0) return;
            }
            var e = spt; // the end: a snapped point, or new
            if (e < 0) {
                e = sk.addPoint(b, uv[0], uv[1]);
                if (e < 0) return;
            }
            const l = sk.addLine(b, a, e);
            if (l < 0) return;
            // level or plumb: say so
            const dx = @abs(uv[0] - p0[0]);
            const dy = @abs(uv[1] - p0[1]);
            if (dy < dx * md_tan) {
                _ = sk.addCon(b, sk.C_HORIZONTAL, l, -1, -1, 0, null);
            } else if (dx < dy * md_tan) {
                _ = sk.addCon(b, sk.C_VERTICAL, l, -1, -1, 0, null);
            }
            prev = e; // the chain goes on from here
            p0 = uv;
        },
        else => {
            var ce = prev; // the centre (a snapped one is shared)
            if (ce < 0) {
                ce = sk.addPoint(b, p0[0], p0[1]);
                if (ce < 0) return;
            }
            const dx = uv[0] - p0[0];
            const dy = uv[1] - p0[1];
            _ = sk.addCircle(b, ce, @sqrt(dx * dx + dy * dy));
            stage = 0;
        },
    }
}

fn selToggle(key: u32) void {
    for (sel[0..nsel], 0..) |s, k| {
        if (s == key) {
            // there: out (the last one moves in)
            nsel -= 1;
            sel[k] = sel[nsel];
            return;
        }
    }
    if (nsel < MAX_SEL) {
        sel[nsel] = key;
        nsel += 1;
    }
}

fn selHas(key: u32) bool {
    for (sel[0..nsel]) |s| {
        if (s == key) return true;
    }
    return false;
}

// --- dragging points --------------------------------------------------------------------

/// skm_press: true when a point is grabbed (the select tool, a point under it).
pub fn press(v: *const vp.View, r: Rect, x: i32, y: i32) bool {
    if (obj_oid == 0 or tool != T_SELECT) return false;
    const i = cur() orelse return false;
    const f = frameOf(i) orelse return false;
    const c = vp.Cam.init(v, r);
    const p = pickPoint(&f, &c, x, y);
    if (p < 0) return false;
    drag_pt = p;
    drag_con = -1;
    dragged = false;
    @import("undo.zig").label(s_sm_head);
    return true;
}
var dragged = false;

/// skm_drag: the grabbed point follows (a temporary fix there).
pub fn drag(v: *const vp.View, r: Rect, x: i32, y: i32) void {
    const i = cur() orelse return;
    const f = frameOf(i) orelse return;
    const c = vp.Cam.init(v, r);
    const uv = rayUv(&f, &c, x, y) orelse return;
    const b = skobj.begin(i) orelse return;
    dragged = true;
    if (drag_con >= 0) sk.dropCon(b, @intCast(drag_con));
    if (drag_pt >= 0 and drag_pt < sk.MAX_PT) {
        const q = &b.pts[@intCast(drag_pt)];
        q.x = uv[0];
        q.y = uv[1];
    }
    drag_con = sk.addCon(b, sk.C_FIXED, drag_pt, -1, -1, 0, null);
    _ = skobj.end(i);
    touch();
}

/// skm_release: the temporary fix goes; the sketch settles. A press that did
/// not move is a click (it selects the point).
pub fn release(v: *const vp.View, r: Rect, x: i32, y: i32, shift: bool) void {
    const i = cur() orelse return;
    if (drag_con >= 0) {
        if (skobj.begin(i)) |b| sk.dropCon(b, @intCast(drag_con));
        drag_con = -1;
    }
    if (dragged) {
        _ = skobj.end(i);
    } else click(v, r, x, y, shift);
    dragged = false;
    touch();
}

// --- operators --------------------------------------------------------------------------

fn toolOp(comptime t: u32) *const fn () void {
    return struct {
        fn f() void {
            if (obj_oid == 0) return;
            tool = t;
            stage = 0;
            nsel = 0;
            touch();
        }
    }.f;
}
fn toolIs(comptime t: u32) *const fn () bool {
    return struct {
        fn f() bool {
            return tool == t;
        }
    }.f;
}

fn selCount(kind: u32) usize {
    var n: usize = 0;
    for (sel[0..nsel]) |s| {
        if (s >> 16 == kind) n += 1;
    }
    return n;
}
fn selNth(kind: u32, n0: usize) i32 {
    var n = n0;
    for (sel[0..nsel]) |s| {
        if (s >> 16 != kind) continue;
        if (n == 0) return @intCast(s & 0xffff);
        n -= 1;
    }
    return -1;
}

fn etype(b: *const sk.Block, e: i32) u32 {
    if (e < 0 or e >= sk.MAX_ENT) return 0;
    return b.ents[@intCast(e)].typ;
}

fn need() void {
    app.log("  sketch: select what to constrain first", .{});
}

/// do_con: a constraint (or one per line / point) from the selection.
fn conOp(comptime t: u32) *const fn () void {
    return struct {
        fn f() void {
            doCon(t);
        }
    }.f;
}

fn doCon(t: u32) void {
    const i = cur() orelse return need();
    const pts = selCount(K_PT);
    const ents = selCount(K_ENT);
    // (decided before the block is ours: nothing to add, nothing copied)
    const ok = switch (t) {
        sk.C_COINCIDENT => (pts == 2 and ents == 0) or (pts == 1 and ents == 1),
        sk.C_HORIZONTAL, sk.C_VERTICAL => ents > 0 or (pts == 2 and ents == 0),
        sk.C_FIXED => pts > 0,
        sk.C_MIDPOINT => pts == 1 and ents == 1,
        else => pts == 0 and ents == 2,
    };
    if (!ok) return need();
    const b = skobj.begin(i) orelse return need();
    switch (t) {
        sk.C_COINCIDENT => {
            if (ents == 0) {
                _ = sk.addCon(b, sk.C_COINCIDENT, selNth(K_PT, 0), selNth(K_PT, 1), -1, 0, null);
            } else {
                // a point on a line / circle
                const e = selNth(K_ENT, 0);
                const ty: u32 = if (etype(b, e) == sk.E_LINE) sk.C_ONLINE else sk.C_ONCIRCLE;
                _ = sk.addCon(b, ty, selNth(K_PT, 0), e, -1, 0, null);
            }
        },
        sk.C_HORIZONTAL, sk.C_VERTICAL => {
            if (ents > 0) {
                // lines: each one
                var k: usize = 0;
                while (true) : (k += 1) {
                    const e = selNth(K_ENT, k);
                    if (e < 0) break;
                    if (etype(b, e) == sk.E_LINE) _ = sk.addCon(b, t, e, -1, -1, 0, null);
                }
            } else {
                // two points: level (vdistance 0) / plumb (hdistance 0)
                const ty: u32 = if (t == sk.C_HORIZONTAL) sk.C_VDIST else sk.C_HDIST;
                _ = sk.addCon(b, ty, selNth(K_PT, 0), selNth(K_PT, 1), -1, 0, null);
            }
        },
        sk.C_FIXED => {
            var k: usize = 0;
            while (true) : (k += 1) {
                const p = selNth(K_PT, k);
                if (p < 0) break;
                _ = sk.addCon(b, sk.C_FIXED, p, -1, -1, 0, null);
            }
        },
        sk.C_MIDPOINT => _ = sk.addCon(b, sk.C_MIDPOINT, selNth(K_PT, 0), selNth(K_ENT, 0), -1, 0, null),
        else => _ = sk.addCon(b, t, selNth(K_ENT, 0), selNth(K_ENT, 1), -1, 0, null),
    }
    _ = skobj.end(i);
    nsel = 0;
    touch();
}

const Dim = struct { t: u32, a: i32, b: i32, v: f64 };

/// dim_kind: what the selection kept by D measures, and its value now
/// (radians for angles), or null.
fn dimKind(b: *const sk.Block) ?Dim {
    var pts: [2]i32 = .{ -1, -1 };
    var ents: [2]i32 = .{ -1, -1 };
    var np: usize = 0;
    var ne: usize = 0;
    for (dimsel[0..ndimsel]) |s| {
        const ix: i32 = @intCast(s & 0xffff);
        if (s >> 16 == K_PT) {
            if (np < 2) {
                pts[np] = ix;
                np += 1;
            }
        } else if (ne < 2) {
            ents[ne] = ix;
            ne += 1;
        }
    }
    if (np == 2) {
        if (ne != 0) return null;
        const a = sk.pointXY(b, pts[0]);
        const c = sk.pointXY(b, pts[1]);
        const dx = c[0] - a[0];
        const dy = c[1] - a[1];
        return .{ .t = sk.C_DISTANCE, .a = pts[0], .b = pts[1], .v = @sqrt(dx * dx + dy * dy) };
    }
    if (np != 0) return null;
    if (ne == 1) {
        const e = ents[0];
        if (e < 0 or e >= sk.MAX_ENT) return null;
        const en = &b.ents[@intCast(e)];
        if (en.typ == sk.E_LINE) {
            const a = sk.pointXY(b, en.p[0]);
            const c = sk.pointXY(b, en.p[1]);
            const dx = c[0] - a[0];
            const dy = c[1] - a[1];
            return .{ .t = sk.C_LENGTH, .a = e, .b = -1, .v = @sqrt(dx * dx + dy * dy) };
        }
        if (en.typ == sk.E_CIRCLE) return .{ .t = sk.C_DIAMETER, .a = e, .b = -1, .v = en.r + en.r };
        return .{ .t = sk.C_RADIUS, .a = e, .b = -1, .v = en.r };
    }
    if (ne == 2) {
        // two lines: the angle between
        const d1 = ldir(b, ents[0]);
        const d2 = ldir(b, ents[1]);
        const cr = d1[0] * d2[1] - d1[1] * d2[0];
        const dt = d1[0] * d2[0] + d1[1] * d2[1];
        return .{ .t = sk.C_ANGLE, .a = ents[0], .b = ents[1], .v = sk.fpatan(cr, dt) };
    }
    return null;
}

fn ldir(b: *const sk.Block, e: i32) [2]f64 {
    if (e < 0 or e >= sk.MAX_ENT) return .{ 0, 0 };
    const en = &b.ents[@intCast(e)];
    const a = sk.pointXY(b, en.p[0]);
    const c = sk.pointXY(b, en.p[1]);
    return .{ c[0] - a[0], c[1] - a[1] };
}

const md_rad2deg: f64 = 57.29577951308232;
const md_deg: f64 = 0.017453292519943295;

/// D: keep the selection, put "sketch.dim " on the command line.
fn opDimKey() void {
    const i = cur() orelse return;
    const b = skobj.of(i) orelse return;
    ndimsel = nsel;
    @memcpy(dimsel[0..nsel], sel[0..nsel]);
    const d = dimKind(b) orelse {
        app.log("  sketch: that selection takes no dimension (a line, two points, a circle or two lines)", .{});
        return;
    };
    var v = d.v;
    if (d.t == sk.C_ANGLE) v *= md_rad2deg;
    var vb: [32]u8 = undefined;
    app.log("  dimension now: {s}", .{cad.fmtVal3(&vb, @floatCast(v))});
    @import("editors.zig").prefillConsole("sketch.dim ");
}

/// has_unit: letters in it (a unit, a name)
fn hasUnit(s: []const u8) bool {
    for (s) |ch| {
        if ((ch | 0x20) -% 'a' < 26) return true;
    }
    return false;
}

/// sketch.dim <value or expression>: on the selection kept by D.
fn opDim() void {
    const arg = std.mem.sliceTo(ops.arg, 0);
    const i = (if (arg.len > 0) cur() else null) orelse {
        app.log("  sketch.dim <value or expression> (after D on a selection)", .{});
        return;
    };
    const b0 = skobj.of(i) orelse return;
    const d = dimKind(b0) orelse {
        app.log("  sketch: that selection takes no dimension (a line, two points, a circle or two lines)", .{});
        return;
    };
    var v = cad.eval(arg) orelse {
        app.log("  sketch.dim: {s}", .{cad.expr.err orelse ""});
        return;
    };
    var text: ?[]const u8 = arg; // (kept as text, so parameters drive it)
    if (d.t == sk.C_ANGLE and !hasUnit(arg)) {
        // angles: plain numbers are degrees (stored as the number then)
        v *= md_deg;
        text = null;
    }
    const b = skobj.begin(i) orelse return;
    _ = sk.addCon(b, d.t, d.a, d.b, -1, v, text);
    _ = skobj.end(i);
    nsel = 0;
    touch();
}

/// sketch.delete: the selected entities (and loose selected points).
fn opDelete() void {
    const i = cur() orelse return need();
    if (nsel == 0) return need();
    const b = skobj.begin(i) orelse return need();
    var ents: [sk.MAX_ENT]u8 = @splat(0);
    var pts: [sk.MAX_PT]u8 = @splat(0);
    for (sel[0..nsel]) |s| {
        const ix = s & 0xffff;
        if (ix >= 256) continue;
        if (s >> 16 == K_ENT) ents[ix] = 1 else pts[ix] = 1;
    }
    sk.delete(b, &ents, &pts);
    nsel = 0;
    _ = skobj.end(i);
    touch();
}

// --- cad.sketch (cadui.s): a new sketch, then sketch mode on it ------------------------

/// The argument's words ("quoted words" are one): name, plane, offset.
fn words(arg: []const u8, out: *[3][]const u8) void {
    out.* = .{ "", "", "" };
    var i: usize = 0;
    var n: usize = 0;
    while (n < 3) {
        while (i < arg.len and arg[i] == ' ') i += 1;
        if (i >= arg.len) break;
        var end: u8 = ' ';
        if (arg[i] == '"') {
            end = '"';
            i += 1;
        }
        const s0 = i;
        while (i < arg.len and arg[i] != end) i += 1;
        out[n] = arg[s0..i];
        n += 1;
        if (i < arg.len) i += 1;
    }
}

/// cad.sketch <name> <XY|XZ|YZ> <offset>: select(sketch(name, plane, offset)),
/// then sketch mode on it.
fn opCadSketch() void {
    var w: [3][]const u8 = undefined;
    words(std.mem.sliceTo(ops.arg, 0), &w);
    const planes = [_][]const u8{ "XY", "XZ", "YZ" };
    var plane: ?u32 = null;
    for (planes, 0..) |pn, k| {
        if (std.mem.eql(u8, pn, w[1])) plane = @intCast(k);
    }
    const pl = plane orelse return app.log("  error: line 1: sketch plane: XY, XZ or YZ, not {s}", .{w[1]});
    const off = if (w[2].len == 0) 0 else cad.eval(w[2]) orelse return app.log("  error: line 1: parameter: {s}", .{cad.expr.err orelse ""});
    const i = skobj.create(w[0], pl, off) orelse return app.log("  error: line 1: the sketch is full", .{});
    scene.selectOnly(i);
    @import("undo.zig").label("Script"); // (the original's console and form run it as a script line: its step is "Script")
    if (can() and obj_oid == 0) toggle();
}

pub const list = .{
    .{ "cad.sketch", Impl{ .run = opCadSketch } },
    .{ "sketch.tool_line", Impl{ .run = toolOp(T_LINE), .check = toolIs(T_LINE), .mode = .sketch } },
    .{ "sketch.tool_circle", Impl{ .run = toolOp(T_CIRCLE), .check = toolIs(T_CIRCLE), .mode = .sketch } },
    .{ "sketch.tool_rect", Impl{ .run = toolOp(T_RECT), .check = toolIs(T_RECT), .mode = .sketch } },
    .{ "sketch.coincident", Impl{ .run = conOp(sk.C_COINCIDENT), .mode = .sketch } },
    .{ "sketch.horizontal", Impl{ .run = conOp(sk.C_HORIZONTAL), .mode = .sketch } },
    .{ "sketch.vertical", Impl{ .run = conOp(sk.C_VERTICAL), .mode = .sketch } },
    .{ "sketch.equal", Impl{ .run = conOp(sk.C_EQUAL), .mode = .sketch } },
    .{ "sketch.parallel", Impl{ .run = conOp(sk.C_PARALLEL), .mode = .sketch } },
    .{ "sketch.perpendicular", Impl{ .run = conOp(sk.C_PERP), .mode = .sketch } },
    .{ "sketch.tangent", Impl{ .run = conOp(sk.C_TANGENT), .mode = .sketch } },
    .{ "sketch.fix", Impl{ .run = conOp(sk.C_FIXED), .mode = .sketch } },
    .{ "sketch.midpoint", Impl{ .run = conOp(sk.C_MIDPOINT), .mode = .sketch } },
    .{ "sketch.dimension", Impl{ .run = opDimKey, .mode = .sketch } },
    .{ "sketch.dim", Impl{ .run = opDim } },
    .{ "sketch.delete", Impl{ .run = opDelete, .mode = .sketch } },
};

/// The Tools pane in sketch mode (tl_sketch): "" is the CONSTRAIN caption.
pub const tools = [_]struct { id: []const u8, ic: ?gfx.Icon }{
    .{ .id = "sketch.tool_line", .ic = .sketch },   .{ .id = "sketch.tool_circle", .ic = .torus },
    .{ .id = "sketch.tool_rect", .ic = .plane },    .{ .id = "sketch.dimension", .ic = .measure },
    .{ .id = "sketch.delete", .ic = .close },       .{ .id = "", .ic = null },
    .{ .id = "sketch.coincident", .ic = null },     .{ .id = "sketch.horizontal", .ic = null },
    .{ .id = "sketch.vertical", .ic = null },       .{ .id = "sketch.equal", .ic = null },
    .{ .id = "sketch.parallel", .ic = null },       .{ .id = "sketch.perpendicular", .ic = null },
    .{ .id = "sketch.tangent", .ic = null },        .{ .id = "sketch.fix", .ic = null },
    .{ .id = "sketch.midpoint", .ic = null },
};

// --- the overlay ------------------------------------------------------------------------

/// skm_overlay: points, the selection, labels, the tool's preview and the
/// status lines, over the viewport (area, its body r).
pub fn overlay(area: i16, v: *const vp.View, r: Rect) void {
    const i = cur() orelse return;
    const f = frameOf(i) orelse return;
    const cv = ui.cv;
    if (!cv.enabled) return;
    const th = ui.th;
    const c = vp.Cam.init(v, r);
    const old = cv.setClip(r);
    defer cv.clip = old;
    const b = f.b;
    // the selected entities, highlighted
    for (sel[0..nsel]) |s| {
        if (s >> 16 != K_ENT) continue;
        const e = s & 0xffff;
        if (e >= sk.MAX_ENT) continue;
        drawEnt(cv, &f, &c, &b.ents[e], th.accent);
    }
    // points: little squares, coloured by status (selected: the accent)
    var k: u32 = 0;
    while (k < b.npt and k < sk.MAX_PT) : (k += 1) {
        const s = pscreen(&f, &c, @intCast(k)) orelse continue;
        const sx: i32 = trunc(s[0]);
        const sy: i32 = trunc(s[1]);
        var col: u32 = if (b.pts[k].flags & sk.F_FULL != 0) skobj.COL_FULLY else skobj.COL_UNDER;
        if (selHas(K_PT << 16 | k)) col = th.accent;
        cv.fill(.{ .x = sx - 2, .y = sy - 2, .w = 5, .h = 5 }, col);
    }
    labels(cv, &f, &c, th);
    // the tool's preview: from the first click to the pointer
    if (tool != T_SELECT and stage != 0 and hvp == area) {
        if (rayUv(&f, &c, hx, hy)) |q| {
            const w0 = world(&f, p0[0], p0[1]);
            switch (tool) {
                T_LINE => vp.line3(cv, &c, w0, world(&f, q[0], q[1]), th.accent),
                T_RECT => {
                    const cs = [4][2]f64{ .{ q[0], p0[1] }, q, .{ p0[0], q[1] }, p0 };
                    var a = w0;
                    for (cs) |p| {
                        const w = world(&f, p[0], p[1]);
                        vp.line3(cv, &c, a, w, th.accent);
                        a = w;
                    }
                },
                else => vp.line3(cv, &c, w0, world(&f, q[0], q[1]), th.accent), // the radius
            }
        }
    }
}

/// The sketch's two lines in the view's corner (the viewport's text,
/// Zui's): its name, conflicts and freedom; what the tool wants.
pub fn status(buf: *[160]u8) ?[2][]const u8 {
    const i = cur() orelse return null;
    const f = frameOf(i) orelse return null;
    const b = f.b;
    var w = std.Io.Writer.fixed(buf);
    w.print("Sketch {s}", .{scene.objects[i].name()}) catch {};
    if (b.nbad != 0) w.print("  \u{b7}  conflicts {d}", .{b.nbad}) catch {};
    if (b.dof == 0) {
        w.writeAll("  \u{b7}  fully constrained") catch {};
    } else w.print("  \u{b7}  DOF {d}", .{b.dof}) catch {};
    const t2 = switch (tool) {
        T_LINE => "Line: click points, Esc ends",
        T_CIRCLE => "Circle: click the centre, then a point on it",
        T_RECT => "Rectangle: click two corners",
        else => "L line  O circle  R rectangle  \u{b7}  C H V E P N T F M  D dimension  X delete  \u{b7}  Tab",
    };
    return .{ w.buffered(), t2 };
}

/// cvttss2si
fn trunc(x: f32) i32 {
    if (!(x > -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}

fn world(f: *const Frame, u: f64, v: f64) m.V3 {
    return m.xform(f.mtx, v3(sk.planeXyz(f.b, u, v)));
}

fn drawEnt(cv: *gfx.Canvas, f: *const Frame, c: *const vp.Cam, e: *const sk.Ent, col: u32) void {
    const n = sk.entSegs(e);
    var uv = sk.entAt(f.b, e, 0, n);
    var a = world(f, uv[0], uv[1]);
    var k: u32 = 1;
    while (k <= n) : (k += 1) {
        uv = sk.entAt(f.b, e, k, n);
        const w = world(f, uv[0], uv[1]);
        vp.line3(cv, c, a, w, col);
        a = w;
    }
}

/// A short label per constraint at its entity (dimensions: their values).
fn labels(cv: *gfx.Canvas, f: *const Frame, c: *const vp.Cam, th: anytype) void {
    const b = f.b;
    var k: u32 = 0;
    while (k < b.ncon and k < sk.MAX_CON) : (k += 1) {
        const cn = &b.cons[k];
        var buf: [96]u8 = undefined;
        var txt: []const u8 = "";
        var at: [2]f64 = undefined;
        switch (cn.typ) {
            sk.C_HORIZONTAL, sk.C_VERTICAL, sk.C_PARALLEL, sk.C_PERP, sk.C_EQUAL, sk.C_TANGENT, sk.C_LENGTH, sk.C_RADIUS, sk.C_DIAMETER, sk.C_ANGLE => {
                txt = switch (cn.typ) {
                    sk.C_HORIZONTAL => "H",
                    sk.C_VERTICAL => "V",
                    sk.C_PARALLEL => "//",
                    sk.C_PERP => "_|_",
                    sk.C_EQUAL => "=",
                    sk.C_TANGENT => "T",
                    else => valueText(&buf, cn),
                };
                // at the entity's middle
                if (cn.a < 0 or @as(u32, @intCast(cn.a)) >= b.nent) continue;
                const e = &b.ents[@intCast(cn.a)];
                if (e.typ == sk.E_LINE) {
                    const p = sk.pointXY(b, e.p[0]);
                    const q = sk.pointXY(b, e.p[1]);
                    at = .{ (q[0] + p[0]) * 0.5, (q[1] + p[1]) * 0.5 };
                } else {
                    // circles: above the centre by r
                    const p = sk.pointXY(b, e.p[0]);
                    at = .{ p[0], p[1] + e.r };
                }
            },
            sk.C_FIXED, sk.C_MIDPOINT => {
                txt = if (cn.typ == sk.C_FIXED) "F" else "M";
                if (cn.a < 0 or @as(u32, @intCast(cn.a)) >= b.npt) continue;
                at = sk.pointXY(b, cn.a);
            },
            sk.C_DISTANCE, sk.C_HDIST, sk.C_VDIST => {
                if (cn.a < 0 or @as(u32, @intCast(cn.a)) >= b.npt) continue;
                if (cn.b < 0 or @as(u32, @intCast(cn.b)) >= b.npt) continue;
                const p = sk.pointXY(b, cn.a);
                const q = sk.pointXY(b, cn.b);
                at = .{ (q[0] + p[0]) * 0.5, (q[1] + p[1]) * 0.5 };
                if (cn.expr[0] != 0) {
                    txt = std.mem.sliceTo(&cn.expr, 0);
                } else txt = cad.fmtVal3(&buf, @floatCast(cn.val));
            },
            else => continue,
        }
        const s = screen(f, c, at[0], at[1]) orelse continue;
        const col: u32 = if (cn.flags & sk.F_BAD != 0) skobj.COL_CONFL else th.text;
        _ = cv.text(trunc(s[0]) + 6, trunc(s[1]) - 18, txt, col);
    }
}

/// A dimension's label: R / D, then its expression or its value (angles in degrees).
fn valueText(buf: []u8, cn: *const sk.Con) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    if (cn.typ == sk.C_RADIUS) w.writeAll("R") catch {};
    if (cn.typ == sk.C_DIAMETER) w.writeAll("D") catch {};
    if (cn.expr[0] != 0) {
        w.writeAll(std.mem.sliceTo(&cn.expr, 0)) catch {};
    } else {
        var v = cn.val;
        if (cn.typ == sk.C_ANGLE) v *= md_rad2deg;
        var vb: [32]u8 = undefined;
        w.writeAll(cad.fmtVal3(&vb, @floatCast(v))) catch {};
        if (cn.typ == sk.C_ANGLE) w.writeAll("deg") catch {};
    }
    return w.buffered();
}

test "seg_d2" {
    try std.testing.expectEqual(@as(f32, 4), segD2(.{ 0, 0 }, .{ 10, 0 }, .{ 5, 2 }));
    try std.testing.expectEqual(@as(f32, 8), segD2(.{ 0, 0 }, .{ 10, 0 }, .{ -2, 2 }));
}

/// The Object tab's sketch rows (areas.s): "Sketch  XY plane, 5 entities, 9
/// constraints" and "DOF  6, conflicts 1" -> y below them.
pub fn propRows(lx: i32, vx: i32, right: i32, y0: i32, oi: usize) i32 {
    const b = skobj.of(oi) orelse return y0;
    const cv = ui.cv;
    const th = ui.th;
    var y = y0;
    const planes = [_][]const u8{ "XY", "XZ", "YZ" };
    var buf: [96]u8 = undefined;
    const pl = if (b.plane < 3) planes[b.plane] else "YZ";
    const t1 = std.fmt.bufPrint(&buf, "{s} plane, {d} entities, {d} constraints", .{ pl, b.nent, b.ncon }) catch "";
    _ = cv.text(lx, y, "Sketch", th.text_dim);
    _ = cv.textFit(vx, y, right - vx, t1, th.text);
    ui.record("info", t1, .{ .x = vx, .y = y, .w = 200, .h = 18 }, true);
    y += 18;
    var b2: [48]u8 = undefined;
    const t2 = if (b.nbad != 0) std.fmt.bufPrint(&b2, "{d}, conflicts {d}", .{ b.dof, b.nbad }) catch "" else std.fmt.bufPrint(&b2, "{d}", .{b.dof}) catch "";
    _ = cv.text(lx, y, "DOF", th.text_dim);
    _ = cv.text(vx, y, t2, th.text);
    ui.record("info", t2, .{ .x = vx, .y = y, .w = 200, .h = 18 }, true);
    return y + 24;
}
