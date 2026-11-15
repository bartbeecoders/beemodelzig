// Modal transforms, as in the original: G moves, R turns, S scales the
// selected objects with the mouse. X / Y / Z lock an axis (again: free),
// Ctrl snaps (Shift+Ctrl finer), a typed value sets the amount (G X 2 Enter),
// Enter or the left button confirms, Esc or the right button cancels.
const std = @import("std");
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const scene = @import("scene.zig");
const vp = @import("viewport.zig");
const ui = @import("ui.zig");
const em = @import("editmesh.zig");
const armedit = @import("armedit.zig");

/// Armature modes: the selected joints or bones move.
var bones_mode = false;
/// curve edit mode: its points and handles move (curveui.zig, cve_tm_*)
var curve_mode = false;
const crvui = @import("curveui.zig");
/// Edit mode: the selected vertices move (in a working copy of the mesh).
var verts_mode = false;
var vw: m.M4 = undefined; // the object's world matrix
var vinv: m.M4 = undefined;

/// A selected vertex's new world position -> the working mesh.
fn putVert(i: usize, wp: m.V3) void {
    const wv = em.workVerts();
    if (i < wv.len) wv[i] = m.xform(vinv, wp);
}

fn origVertW(i: usize) m.V3 {
    return m.xform(vw, em.originalVerts()[i]);
}

const Rect = gfx.Rect;

pub const Mode = enum { move, rotate, scale };
pub const Axis = enum { free, x, y, z };
pub const Pivot = enum { median, cursor, individual, active };
pub const Orient = enum { global, local, view, normal };
/// What X, Y and Z mean while moving or turning (view.orientation).
pub var orient: Orient = .global;
/// The axes for this transform (columns: X, Y, Z).
var basis: [3]m.V3 = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };

pub var active: bool = false;
pub var mode: Mode = .move;
pub var axis: Axis = .free;
/// The viewport (area node) the transform runs in.
pub var node: i16 = -1;
/// What turning and scaling go around (view.pivot).
pub var pivot_mode: Pivot = .median;
/// Snapping on by default (view.toggle_snap); Ctrl does the opposite.
pub var snap_default: bool = false;

var start_x: i32 = 0;
var start_y: i32 = 0;
var cur_x: i32 = 0;
var cur_y: i32 = 0;
var pivot: m.V3 = .{ 0, 0, 0 };
/// Each object's own values (to cancel) and its world transform (to work on).
var orig: [scene.max_objects]struct { loc: m.V3, rot: m.V3, scl: m.V3 } = undefined;
var orig_oid: [scene.max_objects]u32 = undefined;
var orig_w: [scene.max_objects]m.TRS = undefined;
/// Moved by the transform: selected, and not following a selected parent.
var moves: [scene.max_objects]bool = undefined;

var typed: [24]u8 = undefined;
var typed_len: usize = 0;
/// The amount last applied (for the status line).
var amount: m.V3 = .{ 0, 0, 0 };
var amount1: f32 = 0;

pub fn begin(md: Mode, area: i16, mx: i32, my: i32) bool {
    bones_mode = armedit.active();
    curve_mode = !bones_mode and crvui.on();
    verts_mode = em.active and !bones_mode and !curve_mode;
    extruding = false;
    if (bones_mode) {
        if (armedit.tmBegin(&pivot) == 0) return false;
    } else if (curve_mode) {
        if (crvui.tmBegin(&pivot) == 0) return false;
    } else if (verts_mode) {
        if (!em.beginMove()) return false;
        vw = scene.world(em.obj);
        vinv = m.inverseAffine(vw);
    } else if (scene.nSelected() == 0) return false;
    active = true;
    mode = md;
    axis = .free;
    node = area;
    start_x = mx;
    start_y = my;
    cur_x = mx;
    cur_y = my;
    typed_len = 0;
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        orig[i] = .{ .loc = o.loc, .rot = o.rot, .scl = o.scl };
        orig_w[i] = scene.worldTRS(i);
        moves[i] = o.selected and !scene.followsSelected(i);
        orig_oid[i] = o.oid;
    }
    if (bones_mode or curve_mode) {
        if (pivot_mode == .cursor) pivot = scene.cursor;
    } else if (verts_mode) {
        // the middle of the selected vertices (or the 3D cursor)
        var c: m.V3 = .{ 0, 0, 0 };
        var n: f32 = 0;
        for (em.originalVerts(), 0..) |p, i| {
            if (i < em.sel.len and em.sel[i]) {
                c = m.add(c, m.xform(vw, p));
                n += 1;
            }
        }
        pivot = if (pivot_mode == .cursor) scene.cursor else m.scale(c, 1 / @max(1, n));
    } else pivot = switch (pivot_mode) {
        .cursor => scene.cursor,
        .active => if (scene.active) |a| scene.worldLoc(a) else scene.selCenter().?,
        else => scene.selCenter().?,
    };
    amount = .{ 0, 0, 0 };
    amount1 = if (md == .scale) 1 else 0;
    basis = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    switch (orient) {
        .global => {},
        .local, .normal => if (bones_mode or curve_mode) {} else if (verts_mode) {
            const R = m.rotationOf(vw);
            basis = .{ .{ R[0], R[3], R[6] }, .{ R[1], R[4], R[7] }, .{ R[2], R[5], R[8] } };
        } else if (scene.active) |a| {
            const R = m.eulerMat(orig_w[a].rot);
            basis = .{ .{ R[0], R[3], R[6] }, .{ R[1], R[4], R[7] }, .{ R[2], R[5], R[8] } };
        },
        .view => view_basis_pending = true,
    }
    return true;
}

/// Move along one direction (extrude: the faces' normal), as G with that axis locked.
pub fn beginAlong(dir: m.V3, area: i16, mx: i32, my: i32) bool {
    if (!begin(.move, area, mx, my)) return false;
    basis[2] = m.norm(dir);
    axis = .z;
    extruding = true;
    return true;
}

/// Started by extrude: the readout says "Extrude: distance".
var extruding = false;

/// Switch between G / R / S while one runs (keeps the originals).
pub fn switchMode(md: Mode) void {
    restore();
    mode = md;
    typed_len = 0;
    start_x = cur_x;
    start_y = cur_y;
}

fn restore() void {
    if (bones_mode) return armedit.tmRestore();
    if (curve_mode) return crvui.tmRestore();
    if (verts_mode) {
        const wv = em.workVerts();
        const ov = em.originalVerts();
        if (wv.len == ov.len) for (em.movingVerts()) |i| {
            wv[i] = ov[i];
        };
        return;
    }
    // (only what the transform moves: others' edits - a co-editing peer's -
    // that came in meanwhile stay, as the original's restore leaves them)
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (!moves[i] or orig_oid[i] != o.oid) continue;
        o.loc = orig[i].loc;
        o.rot = orig[i].rot;
        o.scl = orig[i].scl;
    }
}

/// Give object i this world transform.
fn put(i: usize, loc: m.V3, rot: m.V3, scl: m.V3) void {
    if (scene.objects[i].parent == null) {
        scene.objects[i].loc = loc;
        scene.objects[i].rot = rot;
        scene.objects[i].scl = scl;
    } else scene.setWorld(i, m.trs(loc, rot, scl));
}

pub fn cancel() void {
    if (bones_mode) armedit.tmCancel() else if (curve_mode) crvui.tmCancel() else restore();
    if (verts_mode) em.endMove(false, "");
    active = false;
    if (extruding) @import("redo.zig").cancel();
}

pub fn confirm() void {
    if (verts_mode) em.endMove(true, modeLabel());
    active = false;
    if (!verts_mode and !bones_mode and !curve_mode) {
        @import("bscript.zig").macroTransform(@intFromEnum(mode) + 1); // (recording a macro: move("Cube", ...))
        @import("animops.zig").autokeyConfirm(); // (the objects get keys)
    }
    // the redo panel: the distance, while it is still along the normal
    if (extruding and mode == .move and axis == .z) {
        @import("redo.zig").set(.extrude, &.{m.dot(amount, basis[2])});
    } else if (extruding) @import("redo.zig").cancel();
}

var view_basis_pending = false;

fn axisDir(a: Axis) m.V3 {
    return switch (a) {
        .x => basis[0],
        .y => basis[1],
        .z => basis[2],
        .free => .{ 0, 0, 0 },
    };
}

pub fn setAxis(a: Axis) void {
    axis = if (axis == a) .free else a;
}

fn snapping() bool {
    return snap_default != ui.ctrl();
}

fn typedValue() ?f32 {
    if (typed_len == 0) return null;
    const s = typed[0..typed_len];
    if (std.mem.eql(u8, s, "-")) return -1; // a lone minus flips the direction
    return std.fmt.parseFloat(f32, s) catch null;
}

pub fn hasTyped() bool {
    return typed_len > 0;
}

/// Recompute the transform for the pointer at (mx, my) in viewport r.
pub fn update(v: *const vp.View, r: Rect, mx: i32, my: i32) void {
    updateInner(v, r, mx, my);
    if (bones_mode) armedit.tmUpdate();
    if (curve_mode) crvui.tmUpdate();
    if (verts_mode) em.moved();
}

fn updateInner(v: *const vp.View, r: Rect, mx: i32, my: i32) void {
    cur_x = mx;
    cur_y = my;
    restore();
    const c = vp.Cam.init(v, r);
    if (view_basis_pending) {
        // View: X is screen right, Y screen up, Z towards you
        basis = .{ c.right, c.up, m.scale(c.fwd, -1) };
        view_basis_pending = false;
    }
    const ps = c.project(pivot) orelse .{ start_x, start_y };
    const fine = ui.shift();
    switch (mode) {
        .move => {
            var d: m.V3 = undefined;
            if (typedValue()) |val| {
                d = m.scale(if (axis == .free) m.V3{ 1, 0, 0 } else axisDir(axis), val);
            } else {
                const ddx: f32 = @floatFromInt(mx - start_x);
                const ddy: f32 = @floatFromInt(my - start_y);
                if (axis == .free) {
                    const k = c.pixelSize(pivot);
                    d = m.add(m.scale(c.right, ddx * k), m.scale(c.up, -ddy * k));
                } else {
                    const a = axisDir(axis);
                    const p0 = c.projectF(pivot);
                    const p1 = c.projectF(m.add(pivot, a));
                    var t: f32 = 0;
                    if (p0 != null and p1 != null) {
                        const sx: f32 = @trunc(p1.?[0]) - @trunc(p0.?[0]);
                        const sy: f32 = @trunc(p1.?[1]) - @trunc(p0.?[1]);
                        const l2 = sx * sx + sy * sy;
                        if (l2 > 1e-3) t = (ddx * sx + ddy * sy) / l2;
                    }
                    d = m.scale(a, t);
                }
                if (snapping()) {
                    const step: f32 = if (fine) 0.1 else 1.0;
                    for (&d) |*x| x.* = @round(x.* / step) * step;
                }
            }
            if (fine and !snapping() and typedValue() == null) {
                // Shift: a tenth of the speed from where it is
                d = m.scale(d, 0.1);
            }
            amount = d;
            if (bones_mode) return armedit.tmGrab(d);
            if (curve_mode) return crvui.tmGrab(d);
            if (verts_mode) {
                for (em.sel, 0..) |on, i| {
                    if (on) putVert(i, m.add(origVertW(i), d));
                }
                return;
            }
            for (0..scene.count) |i| {
                if (moves[i]) put(i, m.add(orig_w[i].loc, d), orig_w[i].rot, orig_w[i].scl);
            }
        },
        .rotate => {
            var ang: f32 = 0; // degrees
            if (typedValue()) |val| {
                ang = val;
            } else {
                const a0 = std.math.atan2(@as(f32, @floatFromInt(start_y - ps[1])), @as(f32, @floatFromInt(start_x - ps[0])));
                const a1 = std.math.atan2(@as(f32, @floatFromInt(my - ps[1])), @as(f32, @floatFromInt(mx - ps[0])));
                ang = (a1 - a0) / m.deg;
                if (ang > 180) ang -= 360;
                if (ang < -180) ang += 360;
                if (snapping()) {
                    const step: f32 = if (fine) 1 else 5;
                    ang = @round(ang / step) * step;
                }
            }
            amount1 = ang;
            // screen angles grow clockwise; turning about the view direction follows the mouse
            var ax = c.fwd;
            var sign: f32 = 1;
            if (axis != .free) {
                ax = axisDir(axis);
                sign = if (m.dot(ax, c.fwd) >= 0) 1 else -1;
            }
            const typed_now = typedValue() != null;
            const rad = ang * m.deg * (if (typed_now and axis != .free) 1 else sign);
            const R = m.axisAngle(ax, if (typed_now and axis == .free) -rad else rad);
            if (curve_mode) {
                // (the original's component rotation: about a world axis, Y when free;
                // a typed angle through its own constant, sin and cos through the x87)
                const ai: u32 = if (axis == .free) 2 else @intFromEnum(axis);
                const rc = if (typedValue()) |val| val * @as(f32, 0.017453293) else ang * m.deg * sign;
                return crvui.tmRotateAxis(ai, rc, pivot);
            }
            if (bones_mode) {
                const rw: [12]f32 = .{ R[0], R[1], R[2], 0, R[3], R[4], R[5], 0, R[6], R[7], R[8], 0 };
                return armedit.tmRotate(&rw, pivot);
            }
            if (verts_mode) {
                for (em.sel, 0..) |on, i| {
                    if (on) putVert(i, m.add(pivot, m.apply3(R, m.sub(origVertW(i), pivot))));
                }
                return;
            }
            for (0..scene.count) |i| {
                if (!moves[i]) continue;
                const w = orig_w[i];
                const rot = m.matEuler(m.mul3(R, m.eulerMat(w.rot)));
                const loc = if (pivot_mode != .individual) m.add(pivot, m.apply3(R, m.sub(w.loc, pivot))) else w.loc;
                put(i, loc, rot, w.scl);
            }
        },
        .scale => {
            var f: f32 = 1;
            if (typedValue()) |val| {
                f = val;
            } else {
                const d0x: f32 = @floatFromInt(start_x - ps[0]);
                const d0y: f32 = @floatFromInt(start_y - ps[1]);
                const d1x: f32 = @floatFromInt(mx - ps[0]);
                const d1y: f32 = @floatFromInt(my - ps[1]);
                f = @sqrt(d1x * d1x + d1y * d1y) / @max(1.0, @sqrt(d0x * d0x + d0y * d0y));
                if (snapping()) {
                    const step: f32 = if (fine) 0.01 else 0.1;
                    f = @round(f / step) * step;
                }
            }
            amount1 = f;
            const a = axisDir(axis);
            if (bones_mode) return armedit.tmScale(f, @intFromEnum(axis), pivot);
            if (curve_mode) return crvui.tmScale(f, @intFromEnum(axis), pivot);
            if (verts_mode) {
                for (em.sel, 0..) |on, i| {
                    if (!on) continue;
                    const d = m.sub(origVertW(i), pivot);
                    putVert(i, if (axis == .free) m.add(pivot, m.scale(d, f)) else m.add(m.add(pivot, d), m.scale(a, m.dot(d, a) * (f - 1))));
                }
                return;
            }
            for (0..scene.count) |i| {
                if (!moves[i]) continue;
                const w = orig_w[i];
                var scl = w.scl;
                var loc = w.loc;
                if (axis == .free) {
                    scl = m.scale(w.scl, f);
                } else {
                    // the object's own axis closest to the world axis
                    const R = m.eulerMat(w.rot);
                    var best: usize = 0;
                    var bd: f32 = -1;
                    for (0..3) |k| {
                        const col: m.V3 = .{ R[k], R[3 + k], R[6 + k] };
                        const dd = @abs(m.dot(col, a));
                        if (dd > bd) {
                            bd = dd;
                            best = k;
                        }
                    }
                    scl[best] = w.scl[best] * f;
                }
                if (pivot_mode != .individual) {
                    const d = m.sub(w.loc, pivot);
                    loc = if (axis == .free) m.add(pivot, m.scale(d, f)) else m.add(m.add(pivot, d), m.scale(a, m.dot(d, a) * (f - 1)));
                }
                put(i, loc, w.rot, scl);
            }
        },
    }
}

/// A typed character (digits, '.', '-' as the layout makes them). True when used.
pub fn typeChar(cp: u32) bool {
    if (cp == '-') return key(ui.KEY.MINUS);
    if (!((cp >= '0' and cp <= '9') or cp == '.' or cp == ',')) return false;
    if (typed_len < typed.len) {
        typed[typed_len] = if (cp == ',') '.' else @intCast(cp);
        typed_len += 1;
    }
    return true;
}

/// A key while transforming. Returns true when it was used.
pub fn key(code: u32) bool {
    const K = ui.KEY;
    switch (code) {
        K.X => setAxis(.x),
        K.Y => setAxis(.y),
        K.Z => setAxis(.z),
        K.G => switchMode(.move),
        K.R => switchMode(.rotate),
        K.S => switchMode(.scale),
        K.BACKSPACE => typed_len -|= 1,
        K.MINUS, K.KPMINUS => {
            if (typed_len > 0 and typed[0] == '-') {
                std.mem.copyForwards(u8, typed[0 .. typed_len - 1], typed[1..typed_len]);
                typed_len -= 1;
            } else if (typed_len < typed.len) {
                std.mem.copyBackwards(u8, typed[1 .. typed_len + 1], typed[0..typed_len]);
                typed[0] = '-';
                typed_len += 1;
            }
        },
        else => {
            const ch: u8 = switch (code) {
                2...10 => @intCast('1' + code - 2),
                11 => '0',
                K.DOT, K.KPDOT => '.',
                K.KP0 => '0',
                K.KP1 => '1',
                K.KP2 => '2',
                K.KP3 => '3',
                K.KP4 => '4',
                K.KP5 => '5',
                K.KP6 => '6',
                K.KP7 => '7',
                K.KP8 => '8',
                K.KP9 => '9',
                else => return false,
            };
            if (typed_len < typed.len) {
                typed[typed_len] = ch;
                typed_len += 1;
            }
        },
    }
    return true;
}

pub fn modeLabel() []const u8 {
    if (extruding and mode == .move) return "Extrude";
    return switch (mode) {
        .move => "Move",
        .rotate => "Rotate",
        .scale => "Scale",
    };
}

/// "Move X 1.25" style text for the viewport and the status bar.
pub fn describe(buf: []u8) []const u8 {
    const ax: []const u8 = switch (axis) {
        .free => "",
        .x => " along X",
        .y => " along Y",
        .z => " along Z",
    };
    const t: []const u8 = if (typed_len > 0) typed[0..typed_len] else "";
    const caret: []const u8 = if (typed_len > 0) "|" else "";
    if (extruding and mode == .move and axis == .z) {
        return if (typed_len > 0)
            std.fmt.bufPrint(buf, "Extrude N  {s}{s}", .{ t, caret }) catch ""
        else
            std.fmt.bufPrint(buf, "Extrude N  {d:.1}", .{m.dot(amount, basis[2])}) catch "";
    }
    return switch (mode) {
        .move => if (typed_len > 0)
            std.fmt.bufPrint(buf, "Move{s}: {s}{s}", .{ ax, t, caret }) catch ""
        else
            std.fmt.bufPrint(buf, "Move{s}: {d:.3}  {d:.3}  {d:.3}", .{ ax, amount[0], amount[1], amount[2] }) catch "",
        .rotate => if (typed_len > 0)
            std.fmt.bufPrint(buf, "Rotate{s}: {s}{s}°", .{ ax, t, caret }) catch ""
        else
            std.fmt.bufPrint(buf, "Rotate{s}: {d:.1}°", .{ ax, amount1 }) catch "",
        .scale => if (typed_len > 0)
            std.fmt.bufPrint(buf, "Scale{s}: {s}{s}", .{ ax, t, caret }) catch ""
        else
            std.fmt.bufPrint(buf, "Scale{s}: {d:.3}", .{ ax, amount1 }) catch "",
    };
}

/// Guides in the viewport: the locked axis through the pivot, and a line
/// from the pivot to the pointer while turning or scaling.
pub fn draw(cv: *gfx.Canvas, v: *const vp.View, r: Rect, th: anytype) void {
    if (!active or !cv.enabled) return;
    const c = vp.Cam.init(v, r);
    const old = cv.setClip(r);
    defer cv.clip = old;
    if (axis != .free) {
        const a = axisDir(axis);
        // extrude's normal: the accent (transform.s axis_col[3])
        const col = if (extruding and axis == .z) th.accent else switch (axis) {
            .x => th.axis_x,
            .y => th.axis_y,
            else => th.axis_z,
        };
        vp.line3(cv, &c, m.sub(pivot, m.scale(a, 1000)), m.add(pivot, m.scale(a, 1000)), col);
    }
    if (mode != .move) {
        if (c.project(pivot)) |p| {
            dashed(cv, p[0], p[1], cur_x, cur_y, th.text);
            cv.fillCircle(p[0], p[1], 3, th.text);
        }
    }
}

fn dashed(cv: *gfx.Canvas, x0: i32, y0: i32, x1: i32, y1: i32, col: u32) void {
    const dx: f32 = @floatFromInt(x1 - x0);
    const dy: f32 = @floatFromInt(y1 - y0);
    const l = @sqrt(dx * dx + dy * dy);
    if (l < 1) return;
    var t: f32 = 0;
    while (t < l) : (t += 10) {
        const t2 = @min(l, t + 5);
        cv.line(x0 + @as(i32, @intFromFloat(dx * t / l)), y0 + @as(i32, @intFromFloat(dy * t / l)), x0 + @as(i32, @intFromFloat(dx * t2 / l)), y0 + @as(i32, @intFromFloat(dy * t2 / l)), col);
    }
}
