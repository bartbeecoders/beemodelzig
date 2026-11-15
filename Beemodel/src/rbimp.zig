// Shatter on impact (rbody.s: imp_register, imp_check, imp_break,
// rb_shatter_obj, imp_show, imp_restore).
//
// An original (a body) whose pieces wait as dormant bodies (type 3: in no
// collision group, their glue asleep) until it is hit hard enough. A marker
// joint (type 5: the original, the threshold as its breaking force, N s) ties
// them: each piece is a child of the original. After the narrow phase, the
// original's contacts are read: a point closing at v with the two's effective
// mass m is a blow m v; past the threshold the original goes dormant and
// hidden and its pieces take its place (where it is now, its velocity at
// each), visible, their glue awake - in time for the blow to land on them this
// step. rb_shatter_obj (the logic node) breaks one at once.
//
// Every number goes through the original's single-precision operations in its
// order (bit for bit).
const std = @import("std");
const rc = @import("rbcore.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const undo = @import("undo.zig");

/// An object shown or hidden (deselected): an evaluation (undo keeps it apart
/// from edits, as the places the simulation writes).
fn setShown(i: usize, shown: bool, deselect: bool) void {
    undo.evalWrite();
    scene.objects[i].visible = shown;
    if (deselect) scene.objects[i].selected = false;
    undo.absorb(i);
}

const V4 = rc.V4;
const splat = rc.splat;
const andXyz = rc.andXyz;

pub const IMP_MAX = 64;
const rx_tiny: f32 = 1.0e-9;

/// A group (IMP_*).
pub const Imp = struct {
    body: u32 = 0, // the original's body
    thr: f32 = 0, // the blow it takes (N s)
    on: u32 = 0, // broken
    frame: i32 = -1, // (when)
    p0: u32 = 0, // its pieces in impc
    np: u32 = 0,
    pend: u32 = 0, // asked to break
    hit: V4 = @splat(0), // where
};

pub var imp: [IMP_MAX]Imp = @splat(.{});
pub var nimp: u32 = 0;
pub var nimpc: u32 = 0;
var impc: [rc.RB_MAX]u32 = undefined;
/// each piece: where it is from the original (R0^T (p - p0)), its turn (conj(q0) q)
var imprel: [rc.RB_MAX][2]V4 = undefined;

/// (shatter on impact: anew)
pub fn reset() void {
    nimp = 0;
    nimpc = 0;
}

/// The object of a body (its index), or null.
fn objOf(b: *const rc.Body) ?usize {
    if (b.obj == 0) return null;
    return scene.findOid(b.obj);
}

/// imp_register: a group from a marker joint record: the original, its
/// threshold, its pieces (the dormant bodies that are its children) and where
/// each is from it.
pub fn register(r: []const u8) void {
    if (nimp >= IMP_MAX) return;
    const ia = @import("rbshape.zig").bodyOfUid(rc.rdU(r, rc.JT_A)) orelse return;
    const o = &rc.bd[ia];
    if (o.typ != 1) return;
    const g = &imp[nimp];
    nimp += 1;
    g.body = ia;
    g.thr = rc.rdF(r, rc.JT_BRK);
    g.on = 0;
    g.pend = 0;
    g.frame = -1;
    g.p0 = nimpc;
    g.np = 0;
    const oi = objOf(o);
    if (oi) |i| setShown(i, true, false); // (the original shown)
    var k: u32 = 0;
    while (k < rc.nb - 1) : (k += 1) {
        const p = &rc.bd[k];
        if (p.typ != 3) continue;
        const pi = objOf(p) orelse continue;
        const par = scene.objects[pi].parent;
        if (par == null or oi == null or par.? != oi.?) continue;
        if (nimpc >= rc.RB_MAX) continue;
        impc[nimpc] = k;
        // where: R0^T (p - p0), conj(q0) q
        imprel[nimpc][0] = andXyz(rc.mtv3(&o.r, p.pos - o.pos));
        imprel[nimpc][1] = rc.qMul(rc.neg3(o.q), p.q);
        nimpc += 1;
        g.np += 1;
        setShown(pi, false, false); // (hidden)
    }
}

/// imp_check: after the narrow phase, before the solve: each original not
/// broken yet, hit hard enough (or asked to break): broken. True when one broke.
pub fn check(fnow: f32) bool {
    var any = false;
    for (imp[0..nimp]) |*g| {
        if (g.on != 0) continue;
        if (g.pend == 0) {
            // the hardest blow, where
            var best: f32 = 0;
            var where: V4 = @splat(0);
            for (rc.mf[0..rc.nmf]) |*m| {
                if (m.a != g.body and m.b != g.body) continue;
                const A = &rc.bd[m.a];
                const B = &rc.bd[m.b];
                // 1 / (imA + imB): moving ones'
                var ims: f32 = 0;
                if (A.typ == 1) ims += A.im;
                if (B.typ == 1) ims += B.im;
                if (!(ims > rx_tiny)) continue;
                const meff = 1.0 / ims;
                for (m.pts[0..m.n]) |*p| {
                    // vA + wA x rA, vB + wB x rB (r: the point on A from each centre)
                    const va = rc.cross(A.w, andXyz(p.wa - A.pos)) + A.v;
                    const vb = rc.cross(B.w, andXyz(p.wa - B.pos)) + B.v;
                    var x = rc.dot3(vb - va, m.nrm); // (B - A) . n: closing when < 0
                    x = -x;
                    x *= meff;
                    if (x > best) {
                        best = x;
                        where = p.wa;
                    }
                }
            }
            if (!(best > g.thr)) continue;
            g.hit = where;
        }
        breakGroup(g, fnow);
        any = true;
    }
    return any;
}

/// imp_break: the original dormant and hidden; its pieces where it is now,
/// moving with it, shown, their glue awake.
fn breakGroup(g: *Imp, fnow: f32) void {
    g.on = 1;
    g.pend = 0;
    g.frame = cvtt(fnow);
    const o = &rc.bd[g.body];
    o.grp0 = o.grp;
    o.grp = 0xffff0000;
    o.typ = 3;
    if (objOf(o)) |i| setShown(i, false, true);
    // its contacts: stale, so the pairs found again leave them out
    const old = rc.stepno -% 1;
    for (rc.mf[0..rc.nmf], 0..) |*m, k| {
        if (m.a != g.body and m.b != g.body) continue;
        m.keep = old;
        rc.mx[k].keep = old;
    }
    for (0..g.np) |k| {
        const ci = g.p0 + @as(u32, @intCast(k));
        const p = &rc.bd[impc[ci]];
        const rel = imprel[ci];
        var q = rc.qMul(o.q, rel[1]); // q = q0 rel (unit)
        q = q / splat(@sqrt(rc.dot4(q, q)));
        p.q = q;
        rc.qRows(p.q, &p.r);
        const r = andXyz(rc.mv3(&o.r, rel[0])); // p = p0 + R0 rel
        p.pos = r + o.pos;
        p.pp = p.pos;
        p.pq = p.q;
        p.v = andXyz(rc.cross(o.w, r) + o.v); // v = v0 + w0 x r, w = w0
        p.w = o.w;
        p.grp = p.grp0;
        p.typ = 1;
        p.asleep = 0;
        p.sleep = 0;
        rc.bodyUpdate(p);
        if (objOf(p)) |i| setShown(i, true, false);
    }
    // glue between awake bodies: awake
    for (rc.jr[0..rc.njr]) |*j| {
        if (j.fl & 8 == 0) continue;
        if (rc.bd[j.a].typ == 3 or rc.bd[j.b].typ == 3) continue;
        j.fl &= ~@as(u32, 12);
    }
    app.dirty = true;
}

/// cvttss2si.
fn cvtt(x: f32) i32 {
    if (x >= -2147483648.0 and x < 2147483648.0) return @intFromFloat(x);
    return std.math.minInt(i32);
}

/// rb_shatter_obj (bodies made): its pieces take its place at the next step;
/// true when it is an original not broken yet.
pub fn shatterNow(oid: u32) bool {
    for (imp[0..nimp]) |*g| {
        const o = &rc.bd[g.body];
        if (o.obj != oid) continue;
        if (g.on != 0) return false;
        g.pend = 1;
        g.hit = o.pos;
        return true;
    }
    return false;
}

/// imp_show: the original hidden (broken) or shown, its children (its
/// pieces) the other way.
pub fn show(oi: usize, is_broken: bool) void {
    setShown(oi, !is_broken, false);
    for (scene.objects[0..scene.count], 0..) |*c, ci| {
        const par = c.parent orelse continue;
        if (par != oi) continue;
        setShown(ci, is_broken, false);
    }
    app.dirty = true;
}

/// imp_restore: back at the start: each marked original whole, shown, its
/// pieces hidden (the anim block's marker joints).
pub fn restoreAll() void {
    const b = @import("anim.zig").cur orelse return;
    const njt = @min(b.h.njt, @as(u32, @intCast(b.jt.len / rc.JT_SZ)));
    for (0..njt) |k| {
        const r = b.jt[k * rc.JT_SZ ..][0..rc.JT_SZ];
        if (rc.rdU(r, rc.JT_TYPE) != 5) continue;
        const i = scene.findOid(rc.rdU(r, rc.JT_A)) orelse continue;
        show(i, false);
    }
}

/// rbinfo(21): of them broken.
pub fn broken() u32 {
    var n: u32 = 0;
    for (imp[0..nimp]) |*g| n +%= g.on;
    return n;
}

test "imp: none broken at first" {
    reset();
    try std.testing.expectEqual(@as(u32, 0), broken());
    try std.testing.expect(!shatterNow(5));
    try std.testing.expectEqual(@as(i32, 5), cvtt(5.9));
    try std.testing.expectEqual(std.math.minInt(i32), cvtt(std.math.nan(f32)));
}
