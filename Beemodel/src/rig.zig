// Constraints and inverse kinematics (rig.s). Both live in the animation block,
// so they are shared with undo steps, copied before a change and saved with the
// keys.
//
// Object constraints act on the owner's own transform (its base, what the user
// or the keys last set it to), in their order: copy location / rotation / scale
// (some axes, optionally added to the base), track to, limit location / rotation
// / scale, child of (the target's motion since the constraint was made). The
// result is written into the object; a later difference from what was written is
// the user's edit and becomes the new base.
//
// IK (on a bone): the chain from the bone up its parents (chain length, 0: to the
// root) reaches for a target object, FABRIK or CCD, then turns about its
// root-to-tip line towards a pole object. Bones get the rotation from their posed
// direction to the solved one; arm.zig poses the armature again with those.
//
// As arm.zig, this is the original's arithmetic, single precision, step by step.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const anim = @import("anim.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const arm = @import("arm.zig");
const undo = @import("undo.zig");
const motion = @import("motion.zig");
const maxss = arm.maxss;
const minss = arm.minss;
const M = arm.M;
const Con = anim.Constraint;
const V = [3]f32;

pub const COPYLOC = 1;
pub const COPYROT = 2;
pub const COPYSCL = 3;
pub const TRACK = 4;
pub const LIMLOC = 5;
pub const LIMROT = 6;
pub const LIMSCL = 7;
pub const CHILD = 8;
pub const IK = 9;
pub const F_OFFSET = 1; // copy: add to the base
pub const F_BASE = 2; // base is set
pub const F_MUTE = 4;

pub const names = [_][]const u8{ "-", "copy_location", "copy_rotation", "copy_scale", "track_to", "limit_location", "limit_rotation", "limit_scale", "child_of", "ik" };
pub const labels = [_][]const u8{ "-", "Copy Location", "Copy Rotation", "Copy Scale", "Track To", "Limit Location", "Limit Rotation", "Limit Scale", "Child Of", "IK" };

const TINY: f32 = 1.0e-8;
const TOL: f32 = 1.0e-4;
const IK_MAXB = 32;
/// A file's iteration count is not to hang on.
const IK_MAXITER = 4096;

// --- vectors -----------------------------------------------------------------------------

fn vsub(a: V, b: V) V {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn vdot(a: V, b: V) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn vlen(a: V) f32 {
    return @sqrt(vdot(a, a));
}
/// Unit in place (unchanged when ~0): its length.
fn vnorm(a: *V) f32 {
    const l = vlen(a.*);
    if (l > TINY) {
        const s = 1.0 / l;
        a[0] *= s;
        a[1] *= s;
        a[2] *= s;
    }
    return l;
}
/// a + s d
fn vaxpy(a: V, d: V, s: f32) V {
    return .{ d[0] * s + a[0], d[1] * s + a[1], d[2] * s + a[2] };
}
fn vcross(a: V, b: V) V {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn addSkew(o: *M, v: V, s: f32) void {
    const x = v[0] * s;
    const y = v[1] * s;
    const z = v[2] * s;
    o[1] -= z;
    o[2] += y;
    o[4] += z;
    o[6] -= x;
    o[8] -= y;
    o[9] += x;
}

/// R = c I + s [k]x + (1 - c) k k^T
fn rotAxis(k: V, angle: f32) M {
    const sc = arm.sincos(angle);
    const c1 = 1.0 - sc[1];
    var o: M = undefined;
    for (0..3) |r| {
        for (0..3) |c| {
            var v = k[r] * k[c] * c1;
            if (r == c) v += sc[1];
            o[r * 4 + c] = v;
        }
        o[r * 4 + 3] = 0;
    }
    addSkew(&o, k, sc[0]);
    return o;
}

/// The shortest rotation taking unit a to unit b.
fn rotAb(a: V, b: V) M {
    const v = vcross(a, b);
    const c = vdot(a, b);
    if (!(c > -0.99999)) {
        // opposite: half a turn about an axis square to a
        var w = vcross(a, .{ 1, 0, 0 });
        if (!(vnorm(&w) > TOL)) {
            w = vcross(a, .{ 0, 1, 0 });
            _ = vnorm(&w);
        }
        return rotAxis(w, 3.14159265);
    }
    const f = 1.0 / (c + 1.0);
    const vv = vdot(v, v);
    var o: M = undefined;
    for (0..3) |r| {
        for (0..3) |q| {
            var x = v[r] * v[q];
            if (r == q) x -= vv;
            x *= f;
            if (r == q) x += 1.0;
            o[r * 4 + q] = x;
        }
        o[r * 4 + 3] = 0;
    }
    addSkew(&o, v, 1.0);
    return o;
}

// --- objects, as the constraints see them ------------------------------------------------

const T = [9]f32; // loc, rot (radians), scale: an object's world values

fn val(oid: u32, c: u32) f32 {
    return anim.chanGet(.{ .kind = anim.K_OBJ, .a = oid, .c = c }, anim.hintFree()) orelse 0;
}
fn vals(oid: u32) T {
    var t: T = undefined;
    for (&t, 0..) |*x, c| x.* = val(oid, @intCast(c));
    return t;
}
fn locOf(oid: u32) V {
    return .{ val(oid, 0), val(oid, 1), val(oid, 2) };
}
fn write(oid: u32, t: *const T) void {
    // (a parented object's values come back from its matrix: no change, no write)
    if (scene.findOid(oid)) |i| {
        if (scene.objects[i].parent != null and asWritten(i, oid, t)) return;
    }
    for (t, 0..) |x, c| {
        _ = anim.chanSet(.{ .kind = anim.K_OBJ, .a = oid, .c = @intCast(c) }, anim.hintFree(), x);
    }
}

fn matOf(t: *const T) M {
    return arm.trs(t[0..3], t[3..6], t[6..9]);
}

/// Is the object still as `last` left it? (a parented object's values come back
/// from its matrix: ulps; a turn is a turn)
fn asWritten(i: usize, oid: u32, last: *const T) bool {
    const o = &scene.objects[i];
    if (o.parent == null) {
        for (0..3) |k| {
            if (o.loc[k] != last[k] or o.scl[k] != last[6 + k]) return false;
            if (o.rot[k] != last[3 + k] / m.deg and o.rot[k] * m.deg != last[3 + k]) return false;
        }
        return true;
    }
    const v = vals(oid);
    for (0..9) |k| {
        var d = @abs(v[k] - last[k]);
        if (k >= 3 and k < 6) d = @min(d, @abs(d - 2 * std.math.pi));
        if (d > 1e-4 * @max(1.0, @abs(last[k]))) return false;
    }
    return true;
}

// --- constraints ----------------------------------------------------------------------------

fn live(c: *const Con) bool {
    return c.flags & F_MUTE == 0 and c.ctype != IK;
}

fn track(c: *const Con, t: *T, tgt: V) void {
    var f = vsub(tgt, t[0..3].*);
    if (!(vnorm(&f) > TINY)) return;
    const ta = c.track % 3;
    const neg = c.track / 3;
    var up: u32 = if (c.up < 3) c.up else 0;
    if (up == ta) up = (ta + 1) % 3;
    var cols: [3]V = undefined;
    cols[ta] = f;
    if (neg != 0) {
        for (&cols[ta]) |*x| x.* = 0.0 - x.*;
    }
    const ca = cols[ta];
    var w: V = .{ 0, 1, 0 };
    if (@abs(ca[1]) >= 0.999) w = .{ 0, 0, 1 };
    cols[up] = vaxpy(w, ca, 0.0 - vdot(w, ca));
    _ = vnorm(&cols[up]);
    const r = 3 - ta - up;
    cols[r] = vcross(cols[(r + 1) % 3], cols[(r + 2) % 3]);
    var mt: M = undefined;
    for (0..3) |rw| {
        for (0..3) |k| mt[rw * 4 + k] = cols[k][rw];
        mt[rw * 4 + 3] = t[rw];
    }
    const p = arm.poseFromMat(&mt);
    t[3] = p.rot[0];
    t[4] = p.rot[1];
    t[5] = p.rot[2];
}

/// t through one constraint.
fn applyCon(c: *const Con, t: *T) void {
    const prev = t.*;
    const has = c.target != 0 and scene.findOid(c.target) != null;
    switch (c.ctype) {
        COPYLOC, COPYROT, COPYSCL => if (has) {
            const tv = vals(c.target);
            const o: usize = (c.ctype - 1) * 3;
            for (0..3) |k| {
                if (c.axes >> @intCast(k) & 1 == 0) continue;
                var x = tv[o + k];
                if (c.flags & F_OFFSET != 0) {
                    if (c.ctype == COPYSCL) x *= t[o + k] else x += t[o + k];
                }
                t[o + k] = x;
            }
        },
        LIMLOC, LIMROT, LIMSCL => {
            const o: usize = (c.ctype - LIMLOC) * 3;
            for (0..3) |k| {
                if (c.axes >> @intCast(k) & 1 == 0) continue;
                t[o + k] = maxss(minss(t[o + k], c.max[k]), c.min[k]);
            }
        },
        TRACK => if (has) track(c, t, locOf(c.target)),
        CHILD => if (has) {
            const tv = vals(c.target);
            const a = matOf(&tv);
            const a2 = arm.mMul(&a, c.inv[0..12]);
            const a3 = matOf(t);
            const r = arm.mMul(&a2, &a3);
            const p = arm.poseFromMat(&r);
            t.* = .{ p.loc[0], p.loc[1], p.loc[2], p.rot[0], p.rot[1], p.rot[2], p.scale[0], p.scale[1], p.scale[2] };
        },
        else => {},
    }
    const inf = c.infl;
    if (inf >= 1.0) return;
    for (t, prev) |*x, q| x.* = (x.* - q) * inf + q;
}

fn cons(b: *anim.Block) []Con {
    return b.h.con[0..@min(b.h.ncon, anim.MAXCON)];
}

fn constraints(b: *anim.Block) void {
    const cs = cons(b);
    for (cs, 0..) |*c, n| {
        if (!live(c)) continue;
        // its owner's first?
        var first = true;
        for (cs[0..n]) |*e| {
            if (e.owner == c.owner and live(e)) first = false;
        }
        if (!first) continue;
        const i = scene.findOid(c.owner) orelse continue;
        if (c.flags & F_BASE == 0 or !asWritten(i, c.owner, &c.last)) {
            c.base = vals(c.owner);
            c.flags |= F_BASE;
        }
        var t = c.base;
        for (cs[n..]) |*e| {
            if (e.owner == c.owner and live(e)) applyCon(e, &t);
        }
        write(c.owner, &t);
        // (the object holds degrees: what it holds now is what a look finds)
        c.last = t;
        if (scene.objects[i].parent == null) {
            for (0..3) |k| c.last[3 + k] = scene.objects[i].rot[k] * m.deg;
        }
    }
}

var ik_hash: u64 = 0;

/// A stamp of every IK constraint and the transforms it reads; when it
/// changes, armatures are posed again.
fn ikCheck(b: *anim.Block) void {
    var h = std.hash.Wyhash.init(0x696b);
    var any = false;
    for (cons(b)) |*c| {
        if (c.ctype != IK) continue;
        any = true;
        h.update(std.mem.asBytes(c)[0..48]);
        for ([_]u32{ c.owner, c.target, c.pole }) |oid| {
            if (oid == 0 or scene.findOid(oid) == null) continue;
            const v = vals(oid);
            h.update(std.mem.sliceAsBytes(&v));
        }
    }
    const x = if (any) h.final() else 0;
    if (x != ik_hash) {
        ik_hash = x;
        arm.allDirty();
    }
}

var busy = false;

/// rig_eval, after the drivers: constraints into the scene, then armatures whose
/// pose changed show it.
pub fn eval() void {
    if (busy) return;
    busy = true;
    defer busy = false;
    if (anim.cur) |b| {
        if (b.h.ncon != 0) {
            constraints(b);
            ikCheck(b);
        } else if (ik_hash != 0) {
            ik_hash = 0;
            arm.allDirty();
        }
    } else if (ik_hash != 0) {
        ik_hash = 0;
        arm.allDirty();
    }
    arm.refresh();
}

pub fn reset() void {
    ik_hash = 0;
}

/// A file's object holds its world values: what was written is what it holds.
pub fn beforeWrite(h: *anim.Head) void {
    const cs = h.con[0..@min(h.ncon, anim.MAXCON)];
    for (cs) |*c| {
        if (c.flags & F_BASE == 0 or !live(c)) continue;
        const i = scene.findOid(c.owner) orelse continue;
        if (scene.objects[i].parent != null and asWritten(i, c.owner, &c.last)) c.last = vals(c.owner);
    }
}

// --- IK ---------------------------------------------------------------------------------------

var ik_b: [IK_MAXB]u32 = undefined;
var ik_p: [IK_MAXB + 1]V = undefined; // joints: solved,
var ik_o: [IK_MAXB + 1]V = undefined; //  as posed
var ik_l: [IK_MAXB]f32 = undefined;
var ik_n: usize = 0;
var ik_tgt: V = undefined;
var ik_pole: V = undefined;

fn chainOf(b: *const arm.Block, c: *const Con) void {
    var want: usize = c.chain;
    if (want == 0 or want > IK_MAXB) want = IK_MAXB;
    var n: usize = 0;
    var bone: i32 = @intCast(c.bone);
    while (true) {
        ik_b[n] = @intCast(bone);
        n += 1;
        if (n >= want) break;
        bone = b.bones[@intCast(bone)].parent;
        if (bone < 0) break;
    }
    ik_n = n;
    std.mem.reverse(u32, ik_b[0..n]);
    for (0..n) |k| {
        const a = &arm.am_m[ik_b[k]];
        ik_o[k] = .{ a[3], a[7], a[11] };
    }
    ik_o[n] = arm.tailOf(b, ik_b[n - 1]);
    for (0..n) |k| ik_l[k] = vlen(vsub(ik_o[k + 1], ik_o[k]));
    @memcpy(ik_p[0 .. n + 1], ik_o[0 .. n + 1]);
}

fn fabrik(iters: u32) void {
    const n = ik_n;
    var d = vsub(ik_tgt, ik_p[0]);
    const dist = vnorm(&d);
    var sum: f32 = 0;
    for (ik_l[0..n]) |l| sum += l;
    if (!(sum > dist)) {
        // out of reach: straight at it
        for (0..n) |k| ik_p[k + 1] = vaxpy(ik_p[k], d, ik_l[k]);
        return;
    }
    const root = ik_p[0];
    var left = iters;
    while (left > 0) {
        left -= 1;
        ik_p[n] = ik_tgt;
        var k = n;
        while (k > 0) {
            k -= 1;
            var e = vsub(ik_p[k], ik_p[k + 1]);
            _ = vnorm(&e);
            ik_p[k] = vaxpy(ik_p[k + 1], e, ik_l[k]);
        }
        ik_p[0] = root;
        for (0..n) |q| {
            var e = vsub(ik_p[q + 1], ik_p[q]);
            _ = vnorm(&e);
            ik_p[q + 1] = vaxpy(ik_p[q], e, ik_l[q]);
        }
        if (!(vlen(vsub(ik_p[n], ik_tgt)) > TOL)) break;
    }
}

fn ccd(iters: u32) void {
    const n = ik_n;
    var left = iters;
    while (left > 0) {
        left -= 1;
        var i = n;
        while (i > 0) {
            i -= 1;
            var a = vsub(ik_p[n], ik_p[i]);
            _ = vnorm(&a);
            var b = vsub(ik_tgt, ik_p[i]);
            _ = vnorm(&b);
            const r = rotAb(a, b);
            var j = i + 1;
            while (j <= n) : (j += 1) {
                const q = arm.xformPoint(&r, vsub(ik_p[j], ik_p[i]));
                ik_p[j] = vaxpy(ik_p[i], q, 1.0);
            }
        }
        if (!(vlen(vsub(ik_p[n], ik_tgt)) > TOL)) break;
    }
}

fn flat(v: *V, k: V) bool {
    v.* = vaxpy(v.*, k, 0.0 - vdot(v.*, k));
    return vnorm(v) > TINY;
}

/// The chain's inner joints turn about the root-to-tip line, the first towards
/// the pole (lengths and ends stay).
fn poleTurn() void {
    const n = ik_n;
    if (n < 2) return;
    var k = vsub(ik_p[n], ik_p[0]);
    if (!(vnorm(&k) > TINY)) return;
    var v = vsub(ik_p[1], ik_p[0]);
    if (!flat(&v, k)) return;
    var w = vsub(ik_pole, ik_p[0]);
    if (!flat(&w, k)) return;
    const angle = arm.atan2(vdot(vcross(v, w), k), vdot(v, w));
    const r = rotAxis(k, angle);
    for (1..n) |j| {
        const q = arm.xformPoint(&r, vsub(ik_p[j], ik_p[0]));
        ik_p[j] = vaxpy(ik_p[0], q, 1.0);
    }
}

fn solve(c: *const Con, ai: *const M) void {
    var iters = c.iter;
    if (iters == 0) iters = 20;
    iters = @min(iters, IK_MAXITER);
    if (c.track == 1) ccd(iters) else fabrik(iters);
    if (c.pole != 0 and scene.findOid(c.pole) != null) {
        ik_pole = arm.xformPoint(ai, locOf(c.pole));
        poleTurn();
    }
    const inf = c.infl;
    if (inf >= 1.0) return;
    for (0..ik_n + 1) |j| {
        for (0..3) |k| ik_p[j][k] = (ik_p[j][k] - ik_o[j][k]) * inf + ik_o[j][k];
    }
}

/// The chain's bones turned onto the solved joints: M' = [Q M | p], Q from its
/// posed direction to its solved one; the pose that makes it, into am_ov.
fn poseChain(b: *const arm.Block) void {
    for (0..ik_n) |i| {
        const bone = ik_b[i];
        var d0 = vsub(ik_o[i + 1], ik_o[i]);
        _ = vnorm(&d0);
        var d1 = vsub(ik_p[i + 1], ik_p[i]);
        _ = vnorm(&d1);
        const q = rotAb(d0, d1);
        var mo = arm.am_m[bone];
        mo[3] = 0;
        mo[7] = 0;
        mo[11] = 0;
        var mn = arm.mMul(&q, &mo);
        mn[3] = ik_p[i][0];
        mn[7] = ik_p[i][1];
        mn[11] = ik_p[i][2];
        const par = b.bones[bone].parent;
        var t3: M = mn;
        if (par >= 0) {
            const k: usize = @intCast(par);
            const t1 = arm.mInv(&arm.am_m[k]);
            const t2 = arm.mMul(&arm.am_r[k], &t1);
            t3 = arm.mMul(&t2, &mn);
        }
        const t1 = arm.mInv(&arm.am_r[bone]);
        arm.am_ov[bone] = arm.mMul(&t1, &t3);
        arm.am_ovf[bone] = true;
        arm.am_m[bone] = mn; // (the children see it)
    }
}

fn finite(ps: []const V) bool {
    for (ps) |p| {
        for (p) |x| {
            if (!std.math.isFinite(x)) return false;
        }
    }
    return true;
}

/// True when IK posed some bones: am_ov, am_ovf (am_m, am_r: posed without IK).
pub fn ik(b: *const arm.Block, owner: usize) bool {
    const blk = anim.cur orelse return false;
    const list = cons(blk);
    if (list.len == 0) return false;
    const a = arm.objMat(owner);
    const ai = arm.mInv(&a);
    const oid = scene.objects[owner].oid;
    var any = false;
    for (list) |*c| {
        if (c.ctype != IK or c.flags & F_MUTE != 0 or c.owner != oid or c.bone >= b.n) continue;
        if (c.target == 0 or scene.findOid(c.target) == null) continue;
        ik_tgt = arm.xformPoint(&ai, locOf(c.target));
        chainOf(b, c);
        solve(c, &ai);
        if (!finite(ik_p[0 .. ik_n + 1])) continue; // (a damaged file)
        poseChain(b);
        any = true;
    }
    return any;
}

// --- operators -----------------------------------------------------------------------------

const Words = std.mem.TokenIterator(u8, .any);

fn num(w: ?[]const u8) ?f32 {
    const s = w orelse return null;
    const v = std.fmt.parseFloat(f32, s) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

fn index(w: []const u8, list: []const []const u8) ?u32 {
    for (list, 0..) |s, k| {
        if (std.mem.eql(u8, s, w)) return @intCast(k);
    }
    return null;
}

const axis_names = [_][]const u8{ "x", "y", "z", "-x", "-y", "-z" };

fn nameOf(oid: u32) []const u8 {
    return if (scene.findOid(oid)) |i| scene.objects[i].name() else "-";
}

/// "  constraint 2: copy_location on Cube -> Target"
fn logCon(k: usize) void {
    const b = anim.cur orelse return;
    const c = &b.h.con[k];
    var t: [240]u8 = undefined;
    var w: usize = 0;
    const add = struct {
        fn f(buf: []u8, at: *usize, s: []const u8) void {
            const n = @min(s.len, buf.len - at.*);
            @memcpy(buf[at.*..][0..n], s[0..n]);
            at.* += n;
        }
    }.f;
    var nb: [16]u8 = undefined;
    add(&t, &w, std.fmt.bufPrint(&nb, "{d}: ", .{k + 1}) catch "");
    if (c.ctype < names.len) add(&t, &w, names[c.ctype]);
    add(&t, &w, " on ");
    add(&t, &w, nameOf(c.owner));
    if (c.bone < arm.MAXB) {
        if (scene.findOid(c.owner)) |i| {
            if (arm.of(i)) |bk| {
                if (c.bone < bk.n) {
                    add(&t, &w, ":");
                    add(&t, &w, bk.bones[c.bone].nameOf());
                }
            }
        }
    }
    if (c.target != 0) {
        add(&t, &w, " -> ");
        add(&t, &w, nameOf(c.target));
    }
    if (c.flags & F_MUTE != 0) add(&t, &w, " (muted)");
    app.log("  constraint {s}", .{t[0..w]});
}

/// constraint.add <object|armature:bone> <type> [target] [options]
pub fn opAdd() void {
    const bad = "  constraint.add <object|armature:bone> <type> [target] [options] - not understood: {s}";
    var c = std.mem.zeroes(Con);
    c.bone = 0xffffffff;
    c.axes = 7;
    c.track = 5;
    c.up = 1;
    c.infl = 1;
    var it = std.mem.tokenizeAny(u8, ops.arg, " \"");
    const own = it.next() orelse return app.log(bad, .{""});
    const colon = std.mem.indexOfScalar(u8, own, ':');
    const oi = scene.find(if (colon) |p| own[0..p] else own) orelse return app.log(bad, .{own});
    c.owner = scene.objects[oi].oid;
    if (colon) |p| {
        const b = arm.of(oi) orelse return app.log(bad, .{own});
        c.bone = arm.findBone(b, own[p + 1..]) orelse return app.log(bad, .{own});
    }
    const tw = it.next() orelse return app.log(bad, .{""});
    const ty = index(tw, &names) orelse return app.log(bad, .{tw});
    if (ty == 0) return app.log(bad, .{tw});
    c.ctype = ty;
    if (ty == IK) c.track = 0; // (FABRIK unless a solver is named)
    if ((ty == IK) != (c.bone != 0xffffffff)) return app.log("  only ik works on a bone (armature:bone), and ik only on one", .{});
    if (ty < LIMLOC or ty > LIMSCL) {
        const gw = it.next() orelse return app.log("  that constraint needs a target object", .{});
        const ti = scene.find(gw) orelse return app.log("  that constraint needs a target object", .{});
        if (ti == oi) return app.log("  that constraint needs a target object", .{});
        c.target = scene.objects[ti].oid;
        if (ty == CHILD) {
            const tv = vals(c.target);
            const a = matOf(&tv);
            const inv = arm.mInv(&a);
            @memcpy(c.inv[0..12], &inv);
        }
    }
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "axes")) {
            const s = it.next() orelse "";
            var a: u32 = 0;
            for (s) |ch| {
                if (ch < 'x' or ch > 'z') return app.log(bad, .{s});
                a |= @as(u32, 1) << @intCast(ch - 'x');
            }
            c.axes = a;
        } else if (std.mem.eql(u8, w, "offset")) {
            c.flags |= F_OFFSET;
        } else if (std.mem.eql(u8, w, "influence")) {
            c.infl = minss(maxss(num(it.next()) orelse return app.log(bad, .{w}), 0), 1);
        } else if (std.mem.eql(u8, w, "min") or std.mem.eql(u8, w, "max")) {
            const to = if (w[1] == 'i') &c.min else &c.max;
            for (to) |*x| {
                const v = num(it.next()) orelse return app.log(bad, .{w});
                x.* = if (ty == LIMROT) v * 0.017453292 else v;
            }
        } else if (std.mem.eql(u8, w, "track") or std.mem.eql(u8, w, "up")) {
            const s = it.next() orelse "";
            const a = index(s, &axis_names) orelse return app.log(bad, .{s});
            if (w[0] == 't') {
                c.track = a;
            } else {
                if (a >= 3) return app.log(bad, .{s});
                c.up = a;
            }
        } else if (std.mem.eql(u8, w, "chain")) {
            const v = num(it.next()) orelse return app.log(bad, .{w});
            c.chain = if (v >= 0 and v < 1e6) @intFromFloat(v) else 0;
        } else if (std.mem.eql(u8, w, "iterations")) {
            const v = num(it.next()) orelse return app.log(bad, .{w});
            c.iter = if (v >= 0 and v < 1e6) @intFromFloat(v) else 0;
        } else if (std.mem.eql(u8, w, "pole")) {
            const s = it.next() orelse "";
            const p = scene.find(s) orelse return app.log(bad, .{s});
            c.pole = scene.objects[p].oid;
        } else if (std.mem.eql(u8, w, "solver")) {
            c.track = @intFromBool(std.mem.eql(u8, it.next() orelse "", "ccd"));
        } else return app.log(bad, .{w});
    }
    const b = anim.own(0) orelse return app.log("  no room for more constraints / drivers", .{});
    if (b.h.ncon >= anim.MAXCON) return app.log("  no room for more constraints / drivers", .{});
    b.h.con[b.h.ncon] = c;
    b.h.ncon += 1;
    logCon(b.h.ncon - 1);
}

/// Before it goes: an owner's first live constraint gives the object back its
/// own transform.
fn unbase(b: *anim.Block, k: usize) void {
    const c = &b.h.con[k];
    if (c.flags & F_BASE == 0) return;
    c.flags &= ~@as(u32, F_BASE);
    if (scene.findOid(c.owner) != null) write(c.owner, &c.base);
}

fn delete(b: *anim.Block, k: usize) void {
    unbase(b, k);
    const n = b.h.ncon;
    std.mem.copyForwards(Con, b.h.con[k .. n - 1], b.h.con[k + 1 .. n]);
    b.h.ncon -= 1;
}

/// constraint.remove <n|object>
pub fn opRemove() void {
    var it = std.mem.tokenizeAny(u8, ops.arg, " \"");
    const w = it.next() orelse return app.log("  no such constraint: ", .{});
    const b0 = anim.cur orelse return app.log("  no such constraint: {s}", .{w});
    if (scene.find(w)) |i| {
        const oid = scene.objects[i].oid;
        var any = false;
        for (cons(b0)) |*c| {
            if (c.owner == oid) any = true;
        }
        if (!any) return app.log("  no such constraint: {s}", .{w});
        const b = anim.own(0) orelse return;
        var n: usize = 0;
        var k = b.h.ncon;
        while (k > 0) {
            k -= 1;
            if (b.h.con[k].owner == oid) {
                delete(b, k);
                n += 1;
            }
        }
        return;
    }
    const v = num(w) orelse return app.log("  no such constraint: {s}", .{w});
    if (!(v >= 1 and v <= @as(f32, @floatFromInt(b0.h.ncon)))) return app.log("  no such constraint: {s}", .{w});
    const b = anim.own(0) orelse return;
    delete(b, @as(usize, @intFromFloat(v)) - 1);
}

/// constraint.set <n> <influence|mute> <value>
pub fn setInfluence(k: usize, v: f32) void {
    const b = anim.own(0) orelse return;
    if (k < b.h.ncon) b.h.con[k].infl = minss(maxss(v, 0), 1);
}
pub fn setMute(k: usize, on: bool) void {
    const b = anim.own(0) orelse return;
    if (k >= b.h.ncon) return;
    b.h.con[k].flags &= ~@as(u32, F_MUTE);
    if (on) {
        unbase(b, k); // muted: the object its own again
        b.h.con[k].flags |= F_MUTE;
    }
}

pub fn opSet() void {
    const bad = "  no such constraint: {s}";
    var it = std.mem.tokenizeAny(u8, ops.arg, " \"");
    const nw = it.next() orelse return app.log(bad, .{""});
    const v = num(nw) orelse return app.log(bad, .{nw});
    const b = anim.cur orelse return app.log(bad, .{nw});
    if (!(v >= 1 and v <= @as(f32, @floatFromInt(b.h.ncon)))) return app.log(bad, .{nw});
    const k = @as(usize, @intFromFloat(v)) - 1;
    const w = it.next() orelse return app.log(bad, .{nw});
    const x = num(it.next()) orelse return app.log(bad, .{w});
    if (std.mem.eql(u8, w, "influence")) {
        setInfluence(k, x);
    } else if (std.mem.eql(u8, w, "mute")) {
        setMute(k, x != 0);
    } else app.log(bad, .{w});
}

/// constraint.list
pub fn opList() void {
    const b = anim.cur orelse return;
    for (0..cons(b).len) |k| logCon(k);
    for (b.drivers(), 0..) |*d, k| app.log("  driver {d}: {s}", .{ k + 1, std.mem.sliceTo(&d.expr, 0) });
}

test "the shortest turn takes a to b" {
    var a: V = .{ 0.2, 0.9, -0.3 };
    var b: V = .{ -0.7, 0.1, 0.6 };
    _ = vnorm(&a);
    _ = vnorm(&b);
    const r = rotAb(a, b);
    const c = arm.xformPoint(&r, a);
    for (c, b) |x, y| try std.testing.expect(@abs(x - y) < 1e-5);
    // opposite: half a turn
    const o = rotAb(a, .{ -a[0], -a[1], -a[2] });
    const d = arm.xformPoint(&o, a);
    for (d, a) |x, y| try std.testing.expect(@abs(x + y) < 1e-4);
}
