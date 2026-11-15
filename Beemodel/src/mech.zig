// Mechanisms (mech.s): CAD assemblies that move.
//
// A joint moves a part relative to its parent (another part, or the world):
// revolute (turned about an axis through a pivot) or slider (moved along an
// axis). Its value comes from an expression (CAD parameters, units, "frame"),
// or is another joint's times a ratio: gears (revolute from revolute) and racks
// (slider from revolute). Limits clamp it (and say so). Parameters are
// animation channels ("param:angle", anim.zig), so a keyed parameter moves the
// whole mechanism, and the feature tree rebuilds with it.
//
// The part as it is when the joint is made is where it is at 0 (its parent's
// place then is kept too); later its place is the parent's motion since, times
// the joint's. Joints are evaluated in order. The records live in the
// animation block (anim.zig: `rest`, the original's AN_MJ_), 208 bytes each, so
// undo and files carry them; their object references are oids in memory and
// uids in files (anim.zig translates). The evaluated value and the limit flag
// are written into the block in place, as the original does (not an edit).
//
// After the parts move, each moving part is checked against every other mesh
// (up to 64; not the part it is joined to): a triangle edge of one passing
// strictly through a triangle of the other. A pair that starts colliding is
// reported in the console.
//
// asm.mate (D4) places a part against another once: coincident, concentric,
// distance.
//
// Every number goes through the original's single-precision operations in its
// order (x87 for sin / cos / atan2, SSE for the rest), so values, places and
// files match it to the bit. The port keeps object rotations in degrees: a
// joint's radians are stored as the degrees that give them back exactly
// (degOf), so what is drawn and written is the original's.
const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");
const scene = @import("scene.zig");
const anim = @import("anim.zig");
const cad = @import("cad.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const mods = @import("mods.zig");
const m = @import("math.zig");
const xp = @import("animexpr.zig");

// ---- the record -------------------------------------------------------------------------

pub const MJ_SZ = 208;
pub const MJ_MAX = 64;
const MJ_TYPE = 0; // 1 revolute, 2 slider
const MJ_A = 4; // the parent (oid in memory; 0: world)
const MJ_B = 8; // the part
const MJ_FLAGS = 12; // 1: limits
const MJ_PIV = 16;
const MJ_AXIS = 28;
const MJ_MIN = 40;
const MJ_MAX_ = 44;
const MJ_RATIO = 48;
const MJ_SRC = 52; // driven by joint (1..; 0: its expression)
const MJ_VAL = 56;
const MJ_LIM = 60;
const MJ_EXPR = 64;
const MJ_EXPRSZ = 64;
const MJ_BREST = 128; // the part's place at 0 (loc rot scale, radians)
const MJ_AREST = 164; // its parent's then
const MC_MAXP = 64;
const MC_MAXHIT = 64;

const Rec = *[MJ_SZ]u8;

fn rdU(r: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, r[o..][0..4], .little);
}
fn wrU(r: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, r[o..][0..4], v, .little);
}
fn rdF(r: []const u8, o: usize) f32 {
    return @bitCast(rdU(r, o));
}
fn wrF(r: []u8, o: usize, v: f32) void {
    wrU(r, o, @bitCast(v));
}
fn rd3(r: []const u8, o: usize) [3]f32 {
    return .{ rdF(r, o), rdF(r, o + 4), rdF(r, o + 8) };
}

/// The joints in use (0 without a block).
pub fn count() u32 {
    const b = anim.cur orelse return 0;
    return @min(b.h.nmj, MJ_MAX);
}

fn recOf(b: *anim.Block, k: usize) Rec {
    return b.rest[k * MJ_SZ ..][0..MJ_SZ];
}

/// The expression's text: to its NUL, which a damaged record may not have
/// within its 64 bytes (the original reads on, so this does).
fn exprOf(b: *anim.Block, k: usize) []const u8 {
    return std.mem.sliceTo(b.rest[k * MJ_SZ + MJ_EXPR ..], 0);
}

pub fn typeOf(k: usize) u32 {
    return rdU(recOf(anim.cur.?, k), MJ_TYPE);
}
pub fn partOf(k: usize) u32 {
    return rdU(recOf(anim.cur.?, k), MJ_B);
}
pub fn exprText(k: usize) []const u8 {
    return exprOf(anim.cur.?, k);
}

/// mech_value: joint k's value now and whether a limit holds it, null: none.
pub const Value = struct { v: f32, lim: bool };
pub fn value(k: usize) ?Value {
    const b = anim.cur orelse return null;
    if (k >= b.h.nmj or k >= MJ_MAX) return null;
    const r = recOf(b, k);
    return .{ .v = rdF(r, MJ_VAL), .lim = rdU(r, MJ_LIM) != 0 };
}

/// MJ_LIM's word as it is (a file can hold any): BeeScript's joint(n, 1).
pub fn limWord(k: usize) ?u32 {
    const b = anim.cur orelse return null;
    if (k >= b.h.nmj or k >= MJ_MAX) return null;
    return rdU(recOf(b, k), MJ_LIM);
}

// ---- the x87 unit, as the original ------------------------------------------------------

const use_x87 = builtin.cpu.arch == .x86_64;

// fld dword [rdi]; fld dword [rdi+4]; fpatan; fstp dword [rdi]; ret
export const bee_x87_mech_atan2f: [10]u8 linksection(".text") = .{ 0xd9, 0x07, 0xd9, 0x47, 0x04, 0xd9, 0xf3, 0xd9, 0x1f, 0xc3 };
// o_mat_euler(rdi = R[9], rsi = out[3]): extended precision throughout
export const bee_x87_mech_mat_euler: [34]u8 linksection(".text") = .{
    0xd9, 0x47, 0x18, // fld dword [rdi+24]
    0xd9, 0xe0, // fchs
    0xd9, 0x07, // fld dword [rdi]
    0xd8, 0xc8, // fmul st, st
    0xd9, 0x47, 0x0c, // fld dword [rdi+12]
    0xd8, 0xc8, // fmul st, st
    0xde, 0xc1, // faddp
    0xd9, 0xfa, // fsqrt
    0xd9, 0xf3, // fpatan
    0xd9, 0x5e, 0x04, // fstp dword [rsi+4]
    0xd9, 0x47, 0x1c, // fld dword [rdi+28]
    0xd9, 0x47, 0x20, // fld dword [rdi+32]
    0xd9, 0xf3, // fpatan
    0xd9, 0x1e, // fstp dword [rsi]
    0xc3,
};

fn run87f(code: []const u8, y: f32, x: f32) f32 {
    var a: [2]f32 = .{ y, x };
    const f: *const fn (*[2]f32) callconv(.c) void = @ptrCast(code.ptr);
    f(&a);
    return a[0];
}

fn run87e(code: []const u8, r: *const [9]f32, o: *[3]f32) void {
    const f: *const fn (*const [9]f32, *[3]f32) callconv(.c) void = @ptrCast(code.ptr);
    f(r, o);
}

/// fpatan of two floats, stored single: atan2(y, x).
pub fn atan2f(y: f32, x: f32) f32 {
    if (!use_x87) return std.math.atan2(y, x);
    return run87f(&bee_x87_mech_atan2f, y, x);
}

/// o_mat_euler: the X Y Z angles of R = Rz Ry Rx.
fn matEuler(r: *const [9]f32) [3]f32 {
    var o: [3]f32 = undefined;
    if (!use_x87) {
        const y: f64 = -@as(f64, r[6]);
        const h = @sqrt(@as(f64, r[0]) * r[0] + @as(f64, r[3]) * r[3]);
        o[1] = @floatCast(std.math.atan2(y, h));
        o[0] = @floatCast(std.math.atan2(@as(f64, r[7]), @as(f64, r[8])));
    } else {
        run87e(&bee_x87_mech_mat_euler, r, &o);
    }
    o[2] = atan2f(r[3], r[0]);
    return o;
}

const sincos = xp.sincos32;

// ---- 3x4 matrices (row-major, the 4th column the translation) ---------------------------

const M = [12]f32;
const ident: M = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
const TINY: f32 = 1.0e-8;

fn mMul(a: *const M, b: *const M) M {
    var o: M = undefined;
    for (0..3) |r| {
        for (0..4) |c| {
            var v = a[r * 4] * b[c];
            v += a[r * 4 + 1] * b[4 + c];
            v += a[r * 4 + 2] * b[8 + c];
            if (c == 3) v += a[r * 4 + 3];
            o[r * 4 + c] = v;
        }
    }
    return o;
}

fn mInv(a: *const M) M {
    const c00 = a[5] * a[10] - a[6] * a[9];
    const c01 = a[6] * a[8] - a[4] * a[10];
    const c02 = a[4] * a[9] - a[5] * a[8];
    var det = a[0] * c00;
    det += a[1] * c01;
    det += a[2] * c02;
    if (!(@abs(det) > TINY)) return ident;
    const s = 1.0 / det;
    var o: M = undefined;
    o[0] = c00 * s;
    o[1] = (a[2] * a[9] - a[1] * a[10]) * s;
    o[2] = (a[1] * a[6] - a[2] * a[5]) * s;
    o[4] = c01 * s;
    o[5] = (a[0] * a[10] - a[2] * a[8]) * s;
    o[6] = (a[2] * a[4] - a[0] * a[6]) * s;
    o[8] = c02 * s;
    o[9] = (a[1] * a[8] - a[0] * a[9]) * s;
    o[10] = (a[0] * a[5] - a[1] * a[4]) * s;
    for (0..3) |r| {
        var t = o[r * 4] * a[3];
        t += o[r * 4 + 1] * a[7];
        t += o[r * 4 + 2] * a[11];
        o[r * 4 + 3] = 0.0 - t;
    }
    return o;
}

/// obj_matrix of loc / rot (radians) / scale: T Rz Ry Rx S.
fn objMatrixOf(loc: [3]f32, rot: [3]f32, scl: [3]f32) M {
    const x = sincos(rot[0]);
    const y = sincos(rot[1]);
    const z = sincos(rot[2]);
    const sx = x[0];
    const cx = x[1];
    const sy = y[0];
    const cy = y[1];
    const sz = z[0];
    const cz = z[1];
    var o: M = undefined;
    o[0] = cz * cy;
    o[1] = cz * sy * sx - sz * cx;
    o[2] = cz * sy * cx + sz * sx;
    o[4] = sz * cy;
    o[5] = sz * sy * sx + cz * cx;
    o[6] = sz * sy * cx - cz * sx;
    o[8] = 0.0 - sy;
    o[9] = cy * sx;
    o[10] = cy * cx;
    for (0..3) |r| {
        o[r * 4] = scl[0] * o[r * 4];
        o[r * 4 + 1] = scl[1] * o[r * 4 + 1];
        o[r * 4 + 2] = scl[2] * o[r * 4 + 2];
        o[r * 4 + 3] = loc[r];
    }
    return o;
}

const degf: f32 = m.deg;

/// An object's place as the original keeps it: world loc, rot (radians), scale.
const Place = struct { loc: [3]f32, rot: [3]f32, scl: [3]f32 };

fn placeOf(i: usize) Place {
    const o = &scene.objects[i];
    if (o.parent == null) return .{ .loc = o.loc, .rot = o.radians(), .scl = o.scl };
    const t = scene.worldTRS(i);
    return .{ .loc = t.loc, .rot = .{ t.rot[0] * degf, t.rot[1] * degf, t.rot[2] * degf }, .scl = t.scl };
}

fn placeIn(r: []u8, o: usize, p: Place) void {
    for (0..3) |c| {
        wrF(r, o + c * 4, p.loc[c]);
        wrF(r, o + 12 + c * 4, p.rot[c]);
        wrF(r, o + 24 + c * 4, p.scl[c]);
    }
}

fn placeAt(r: []const u8, o: usize) Place {
    return .{ .loc = rd3(r, o), .rot = rd3(r, o + 12), .scl = rd3(r, o + 24) };
}

fn objMatrix(i: usize) M {
    const p = placeOf(i);
    return objMatrixOf(p.loc, p.rot, p.scl);
}

pub const degOf = scene.degOf;

/// pose_from_mat: location, scale (column lengths), Euler XYZ.
fn poseFromMat(a: *const M) Place {
    var p: Place = undefined;
    p.loc = .{ a[3], a[7], a[11] };
    var r: [9]f32 = undefined;
    for (0..3) |c| {
        var l = a[c] * a[c];
        l += a[4 + c] * a[4 + c];
        l += a[8 + c] * a[8 + c];
        l = @sqrt(l);
        l = if (l > TINY) l else TINY;
        p.scl[c] = l;
        r[c] = a[c] / l;
        r[3 + c] = a[4 + c] / l;
        r[6 + c] = a[8 + c] / l;
    }
    p.rot[1] = atan2f(0.0 - r[6], @sqrt(r[0] * r[0] + r[3] * r[3]));
    p.rot[0] = atan2f(r[7], r[8]);
    p.rot[2] = atan2f(r[3], r[0]);
    return p;
}

/// The same bits (repe cmpsb).
fn same3(a: [3]f32, b: [3]f32) bool {
    const x: [3]u32 = @bitCast(a);
    const y: [3]u32 = @bitCast(b);
    return x[0] == y[0] and x[1] == y[1] and x[2] == y[2];
}

/// The part to this world place; true when that moved it.
fn putPlace(i: usize, p: Place) bool {
    const o = &scene.objects[i];
    if (o.parent == null) {
        if (same3(o.loc, p.loc) and same3(o.radians(), p.rot) and same3(o.scl, p.scl)) return false;
        undo.evalWrite();
        o.loc = p.loc;
        o.setRadians(p.rot);
        o.scl = p.scl;
        undo.absorb(i);
        return true;
    }
    // a child: its local values follow from where its parent is
    const now = placeOf(i);
    if (same3(now.loc, p.loc) and same3(now.rot, p.rot) and same3(now.scl, p.scl)) return false;
    const mt = objMatrixOf(p.loc, p.rot, p.scl);
    var w: m.M4 = m.identity();
    @memcpy(w[0..12], &mt);
    undo.evalWrite();
    const kl = o.loc;
    const kr = o.rot;
    const ks = o.scl;
    scene.setWorld(i, w);
    if (same3(kl, o.loc) and same3(kr, o.rot) and same3(ks, o.scl)) return false;
    undo.absorb(i);
    return true;
}

// ---- values -----------------------------------------------------------------------------

/// mj_name: "frame" (expr.s' hook).
fn mjName(w: []const u8) ?f64 {
    if (std.mem.eql(u8, w, "frame")) return anim.frame;
    return null;
}

const Ev = struct { v: f32, ok: bool };

/// mj_expr: the value (what the parse made of it even when it failed), ok.
fn mjExpr(text: []const u8) Ev {
    if (text.len == 0) return .{ .v = 0, .ok = true };
    const keep = xp.name_hook;
    xp.name_hook = mjName;
    defer xp.name_hook = keep;
    xp.param_lookup = cad.paramLookup;
    xp.unit_mm = cad.unitMm();
    const r = xp.evaluate(text);
    return .{ .v = @floatCast(r.v), .ok = r.ok };
}

/// mj_joint_mat: [R | p - R p] about the axis through the pivot, or [I | axis v].
fn jointMat(r: []const u8, v: f32) M {
    const ax = rd3(r, MJ_AXIS);
    var o: M = ident;
    if (rdU(r, MJ_TYPE) == 2) {
        for (0..3) |c| o[c * 4 + 3] = ax[c] * v;
        return o;
    }
    const sc = sincos(v);
    const s = sc[0];
    const c = sc[1];
    const t = 1.0 - c;
    for (0..3) |i| {
        for (0..3) |j| {
            var x = ax[i] * ax[j];
            x *= t;
            if (i == j) x += c;
            o[i * 4 + j] = x;
        }
    }
    const sx = ax[0] * s;
    const sy = ax[1] * s;
    const sz = ax[2] * s;
    o[1] -= sz;
    o[2] += sy;
    o[4] += sz;
    o[6] -= sx;
    o[8] -= sy;
    o[9] += sx;
    const p = rd3(r, MJ_PIV);
    for (0..3) |i| {
        var d = o[i * 4] * p[0];
        d += o[i * 4 + 1] * p[1];
        d += o[i * 4 + 2] * p[2];
        o[i * 4 + 3] = p[i] - d;
    }
    return o;
}

var busy = false;
/// Pairs colliding now (mech_hits).
pub var hits: u32 = 0;

/// maxss / minss: the second operand when unordered.
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

/// mech_eval: every joint's value, every part placed; collisions after a move.
pub fn eval() void {
    if (busy) return;
    const b = anim.cur orelse return;
    if (b.h.nmj == 0) return;
    busy = true;
    defer busy = false;
    var moved = false;
    const n = @min(b.h.nmj, MJ_MAX);
    for (0..n) |k| {
        const r = recOf(b, k);
        var v: f32 = 0;
        const src = rdU(r, MJ_SRC);
        if (src != 0) {
            const s = src -% 1;
            if (s < k) v = rdF(recOf(b, s), MJ_VAL) * rdF(r, MJ_RATIO);
        } else v = mjExpr(exprOf(b, k)).v;
        wrU(r, MJ_LIM, 0);
        if (rdU(r, MJ_FLAGS) & 1 != 0) {
            const was = v;
            v = minss(maxss(v, rdF(r, MJ_MIN)), rdF(r, MJ_MAX_));
            if (!(v == was or std.math.isNan(v) or std.math.isNan(was))) wrU(r, MJ_LIM, 1);
        }
        wrF(r, MJ_VAL, v);
        const bi = scene.findOid(rdU(r, MJ_B)) orelse continue;
        const j = jointMat(r, v);
        const b0 = placeAt(r, MJ_BREST);
        var mt = mMul(&j, &objMatrixOf(b0.loc, b0.rot, b0.scl));
        const a = rdU(r, MJ_A);
        if (a != 0) {
            if (scene.findOid(a)) |ai| {
                const am = objMatrix(ai);
                const a0 = placeAt(r, MJ_AREST);
                const inv = mInv(&objMatrixOf(a0.loc, a0.rot, a0.scl));
                const d = mMul(&am, &inv);
                mt = mMul(&d, &mt);
            }
        }
        if (putPlace(bi, poseFromMat(&mt))) moved = true;
    }
    if (moved) {
        app.dirty = true;
        _ = collide(false);
    }
}

// ---- collisions -------------------------------------------------------------------------

var mc_n: usize = 0;
var mc_pairs: [MC_MAXHIT][2]u32 = undefined; // (uids, as the original keeps them)

fn uidOf(oid: u32) u32 {
    return scene.uidOfOid(oid) orelse 0;
}

/// The file's type 0 (OT_MESH): what bee.zig writes as a mesh.
/// OT_MESH in the original: scene.Kind.isMesh (no lights, cameras, armatures,
/// sketches or force fields)
fn isMeshType(k: scene.Kind) bool {
    return k.isMesh();
}

/// mc_joined: a joint ties them directly.
fn joined(b: *anim.Block, x: u32, y: u32) bool {
    for (0..@min(b.h.nmj, MJ_MAX)) |k| {
        const r = recOf(b, k);
        const a = rdU(r, MJ_A);
        const p = rdU(r, MJ_B);
        if (a == x and p == y) return true;
        if (a == y and p == x) return true;
    }
    return false;
}

fn nameOf(oid: u32) []const u8 {
    if (scene.findOid(oid)) |i| return scene.objects[i].name();
    return "world";
}

/// mech_collide: the pairs colliding now; all reported (`all`), or the new ones.
pub fn collide(all: bool) u32 {
    const b = anim.cur orelse return 0;
    var parts: [MC_MAXP]u32 = undefined;
    var np: usize = 0;
    const add = struct {
        fn f(ps: *[MC_MAXP]u32, n: *usize, oid: u32) void {
            if (oid == 0) return;
            for (ps[0..n.*]) |q| if (q == oid) return;
            if (n.* >= MC_MAXP) return;
            ps[n.*] = oid;
            n.* += 1;
        }
    }.f;
    for (0..@min(b.h.nmj, MJ_MAX)) |k| add(&parts, &np, rdU(recOf(b, k), MJ_B));
    const nmov = np;
    for (scene.objects[0..scene.count]) |*o| {
        if (isMeshType(o.kind)) add(&parts, &np, o.oid);
    }
    var now: [MC_MAXHIT][2]u32 = undefined;
    var nh: usize = 0;
    for (0..nmov) |i| {
        for (i + 1..np) |j| {
            if (joined(b, parts[i], parts[j])) continue;
            if (!pair(parts[i], parts[j])) continue;
            if (nh >= MC_MAXHIT) continue;
            now[nh] = .{ parts[i], parts[j] };
            nh += 1;
        }
    }
    for (now[0..nh]) |p| {
        const u: [2]u32 = .{ uidOf(p[0]), uidOf(p[1]) };
        if (!all) {
            var seen = false;
            for (mc_pairs[0..mc_n]) |q| {
                if (q[0] == u[0] and q[1] == u[1]) seen = true;
            }
            if (seen) continue;
        }
        say(&.{ "  collision: ", nameOf(p[0]), " / ", nameOf(p[1]) });
    }
    for (now[0..nh], 0..) |p, k| mc_pairs[k] = .{ uidOf(p[0]), uidOf(p[1]) };
    mc_n = nh;
    hits = @intCast(nh);
    return hits;
}

const V = @Vector(4, f32);

fn v4(p: [3]f32) V {
    return .{ p[0], p[1], p[2], 0 };
}
fn minps(a: V, b: V) V {
    return @select(f32, a < b, a, b);
}
fn maxps(a: V, b: V) V {
    return @select(f32, a > b, a, b);
}
fn all3(c: @Vector(4, bool)) bool {
    return c[0] and c[1] and c[2];
}
/// DOT3 (dpps 0x71): (x0 y0 + x1 y1) + (x2 y2 + 0).
fn dot3(a: V, b: V) f32 {
    const p = a * b;
    return (p[0] + p[1]) + (p[2] + 0.0);
}
fn cross(a: V, b: V) V {
    const d = @shuffle(f32, b, undefined, [4]i32{ 1, 2, 0, 3 }) * a;
    const t = @shuffle(f32, a, undefined, [4]i32{ 1, 2, 0, 3 }) * b;
    const e = d - t;
    return @shuffle(f32, e, undefined, [4]i32{ 1, 2, 0, 3 });
}

const EPS: f32 = 1.0e-5;
const TINY12: f32 = 1.0e-12;

/// st_edge: q inside the edge from-to by more than eps x its length.
fn inside(from: V, to: V, q: V, n: V) bool {
    const e = to - from;
    const w = q - from;
    const c = dot3(cross(e, w), n);
    const l = @sqrt(dot3(e, e)) * EPS;
    return c > l;
}

/// seg_tri: the segment passes strictly through the triangle.
pub fn segTri(p0: V, p1: V, a: V, b: V, c: V) bool {
    var n = cross(b - a, c - a);
    const l = @sqrt(dot3(n, n));
    if (!(l > TINY12)) return false;
    n = n / @as(V, @splat(l));
    const d0 = dot3(p0 - a, n);
    const d1 = dot3(p1 - a, n);
    if (d0 > EPS) {
        if (d1 >= -EPS) return false;
    } else {
        if (d0 >= -EPS) return false;
        if (!(d1 > EPS)) return false;
    }
    const t = d0 / (d0 - d1);
    const q = (p1 - p0) * @as(V, @splat(t)) + p0;
    if (!inside(a, b, q, n)) return false;
    if (!inside(b, c, q, n)) return false;
    if (!inside(c, a, q, n)) return false;
    return true;
}

/// tris_cross: an edge of either passes strictly through the other.
fn trisCross(b: [3]V, a: [3]V) bool {
    if (segTri(a[0], a[1], b[0], b[1], b[2])) return true;
    if (segTri(a[1], a[2], b[0], b[1], b[2])) return true;
    if (segTri(a[2], a[0], b[0], b[1], b[2])) return true;
    for (0..3) |k| {
        if (segTri(b[k], b[(k + 1) % 3], a[0], a[1], a[2])) return true;
    }
    return false;
}

const Box = struct { lo: V, hi: V };

fn triBox(pts: []const V, t: [3]u32) Box {
    const p0 = pts[t[0]];
    var lo = p0;
    var hi = p0;
    lo = minps(lo, pts[t[1]]);
    hi = maxps(hi, pts[t[1]]);
    lo = minps(lo, pts[t[2]]);
    hi = maxps(hi, pts[t[2]]);
    return .{ .lo = lo, .hi = hi };
}

/// box_meets: (a's low <= b's high) and (b's low <= a's high), x y z.
fn meets(a: Box, b: Box) bool {
    return all3(a.lo <= b.hi) and all3(b.lo <= a.hi);
}

/// mc_points: a mesh's points in the world, and their bounds.
fn worldPoints(me: *const scene.Mesh, mt: *const M, out: []V) Box {
    var lo: V = @splat(1.0e30);
    var hi: V = @splat(-1.0e30);
    for (me.verts, 0..) |p, k| {
        var o: [3]f32 = undefined;
        for (0..3) |r| {
            var x = mt[r * 4] * p[0];
            x += mt[r * 4 + 1] * p[1];
            x += mt[r * 4 + 2] * p[2];
            x += mt[r * 4 + 3];
            o[r] = x;
        }
        out[k] = v4(o);
        lo = minps(lo, out[k]);
        hi = maxps(hi, out[k]);
    }
    return .{ .lo = lo, .hi = hi };
}

fn validTri(me: *const scene.Mesh, t: [3]u32) bool {
    return t[0] < me.verts.len and t[1] < me.verts.len and t[2] < me.verts.len;
}

// the scratch: both meshes' points in the world, B's triangles near A (kept
// between pairs and frames: the original maps it for each pair)
var sc_pts: []V = &.{};
var sc_tris: []u32 = &.{};

fn room(np: usize, nt: usize) bool {
    const A = std.heap.page_allocator;
    if (sc_pts.len < np) {
        if (sc_pts.len > 0) A.free(sc_pts);
        sc_pts = A.alloc(V, np + np / 2) catch {
            sc_pts = &.{};
            return false;
        };
    }
    if (sc_tris.len < nt) {
        if (sc_tris.len > 0) A.free(sc_tris);
        sc_tris = A.alloc(u32, nt + nt / 2) catch {
            sc_tris = &.{};
            return false;
        };
    }
    return true;
}

/// mc_pair: the two objects' meshes cross.
fn pair(x: u32, y: u32) bool {
    const ia = scene.findOid(x) orelse return false;
    const ib = scene.findOid(y) orelse return false;
    if (!isMeshType(scene.objects[ia].kind) or !isMeshType(scene.objects[ib].kind)) return false;
    const ma = mods.of(ia) orelse return false;
    const mb = mods.of(ib) orelse return false;
    if (!room(ma.verts.len + mb.verts.len, mb.tris.len)) return false;
    const pa = sc_pts[0..ma.verts.len];
    const pb = sc_pts[ma.verts.len..][0..mb.verts.len];
    const ba = worldPoints(ma, &objMatrix(ia), pa);
    const bb = worldPoints(mb, &objMatrix(ib), pb);
    const ov = Box{ .lo = maxps(ba.lo, bb.lo), .hi = minps(ba.hi, bb.hi) };
    if (!all3(ov.lo <= ov.hi)) return false;
    const tb = sc_tris[0..mb.tris.len];
    var nb: usize = 0;
    for (mb.tris, 0..) |t, k| {
        if (!validTri(mb, t)) continue;
        if (!meets(triBox(pb, t), ov)) continue;
        tb[nb] = @intCast(k);
        nb += 1;
    }
    if (nb == 0) return false;
    for (ma.tris) |t| {
        if (!validTri(ma, t)) continue;
        const bxa = triBox(pa, t);
        if (!meets(bxa, ov)) continue;
        const ca: [3]V = .{ pa[t[0]], pa[t[1]], pa[t[2]] };
        for (tb[0..nb]) |k| {
            const u = mb.tris[k];
            if (!meets(triBox(pb, u), bxa)) continue;
            if (trisCross(.{ pb[u[0]], pb[u[1]], pb[u[2]] }, ca)) return true;
        }
    }
    return false;
}

// ---- parameters as animation channels (anim.zig: K_PARAM) -------------------------------

/// param_chan: parameter k's value; with `set` a new value becomes its
/// expression, and the sketches and features rebuild. Null: no such parameter.
pub fn paramChan(k: u32, v: f32, set: bool) ?f32 {
    if (k >= cad.paramCount()) return null;
    const now: f32 = @floatCast(cad.paramValue(k) orelse 0);
    if (!set) return now;
    if (now == v) return now;
    var nb: [48]u8 = undefined;
    const text = fmtNum6(&nb, v);
    var name: [24]u8 = undefined;
    const nm = cad.paramName(k);
    @memcpy(name[0..nm.len], nm);
    undo.evalWrite();
    _ = cad.paramSet(name[0..nm.len], text);
    cad.rebuild();
    undo.absorbAll();
    return v;
}

/// fmt_num6: "-12.345678" (six decimals, rounded).
pub fn fmtNum6(buf: []u8, v0: f32) []const u8 {
    var x: f64 = v0;
    var w: usize = 0;
    if (!(x >= 0)) {
        buf[0] = '-';
        w = 1;
        x = 0.0 - x;
    }
    const y = x * 1000000.0 + 0.5;
    // cvttsd2si: out of range or NaN is the minimum (here unsigned)
    const k: u64 = if (y >= -9.223372036854775808e18 and y < 9.223372036854775808e18) @bitCast(@as(i64, @intFromFloat(y))) else 0x8000000000000000;
    const s = std.fmt.bufPrint(buf[w..], "{d}.{d:0>6}", .{ k / 1000000, k % 1000000 }) catch return buf[0..w];
    return buf[0 .. w + s.len];
}

// ---- console lines ---------------------------------------------------------------------

/// fmt_* into fmt_buf (126 characters at most), then a console line (log_line
/// keeps 95 of them: LOG_LINE_LEN).
fn say(parts: []const []const u8) void {
    var b: [128]u8 = undefined;
    var n: usize = 0;
    for (parts) |p| {
        for (p) |c| {
            if (n >= 95) break;
            b[n] = c;
            n += 1;
        }
    }
    app.log("{s}", .{b[0..n]});
}

/// mj_log: "  joint 2: revolute Gear2 / Gear1 = joint 1 x -0.5: 0.3"
fn logJoint(k: usize) void {
    const b = anim.cur orelse return;
    const r = recOf(b, k);
    var nb: [16]u8 = undefined;
    var sb: [16]u8 = undefined;
    var rb: [40]u8 = undefined;
    var vb: [40]u8 = undefined;
    const ty = rdU(r, MJ_TYPE) -% 1;
    const tn: []const u8 = if (ty & 1 == 0) "revolute" else "slider";
    const num = std.fmt.bufPrint(&nb, "{d}", .{k + 1}) catch "";
    const src = rdU(r, MJ_SRC);
    const val = cad.fmtVal3(&vb, rdF(r, MJ_VAL));
    const lim: []const u8 = if (rdU(r, MJ_LIM) != 0) " (at its limit)" else "";
    const pn = nameOf(rdU(r, MJ_B));
    const an = nameOf(rdU(r, MJ_A));
    if (src != 0) {
        const s = std.fmt.bufPrint(&sb, "{d}", .{@as(i32, @bitCast(src))}) catch "";
        say(&.{ "  joint ", num, ": ", tn, " ", pn, " / ", an, " = joint ", s, " x ", cad.fmtVal3(&rb, rdF(r, MJ_RATIO)), ": ", val, lim });
    } else {
        const e = exprOf(b, k);
        if (e.len > 0) {
            say(&.{ "  joint ", num, ": ", tn, " ", pn, " / ", an, " = ", e, ": ", val, lim });
        } else say(&.{ "  joint ", num, ": ", tn, " ", pn, " / ", an, ": ", val, lim });
    }
}

// ---- the argument's words (im_next_word) ---------------------------------------------------

var word_buf: [256]u8 = @splat(0);
var word_len: usize = 0;

fn word() []const u8 {
    return word_buf[0..word_len];
}

const Cur = struct {
    s: []const u8,
    i: usize = 0,

    fn at(c: *const Cur, k: usize) u8 {
        return if (k < c.s.len) c.s[k] else 0;
    }
    /// The next word into `word` (spaces part them): its length.
    fn next(c: *Cur) usize {
        word_len = 0;
        while (c.at(c.i) == ' ') c.i += 1;
        while (true) : (c.i += 1) {
            const ch = c.at(c.i);
            if (ch == 0 or ch == ' ') break;
            if (word_len < 255) {
                word_buf[word_len] = ch;
                word_len += 1;
            }
        }
        return word_len;
    }
    /// mx_num: the next word, a plain number.
    fn num(c: *Cur) ?f32 {
        if (c.next() == 0) return null;
        return parseFloat(word());
    }
    /// mx_word_expr: the next word, an expression (its value even when it failed).
    fn expr(c: *Cur) Ev {
        if (c.next() == 0) return .{ .v = 0, .ok = false };
        return mjExpr(word());
    }
};

/// parse_float: "-1.5e3" style; null when no digits.
pub fn parseFloat(s: []const u8) ?f32 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == 9)) i += 1;
    var v: f64 = 0;
    var neg = false;
    var digits: u32 = 0;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    } else if (i < s.len and s[i] == '+') i += 1;
    while (i < s.len and s[i] -% '0' <= 9) : (i += 1) {
        v = v * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
        digits += 1;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        var u: f64 = 1;
        while (i < s.len and s[i] -% '0' <= 9) : (i += 1) {
            u /= 10.0;
            v += @as(f64, @floatFromInt(s[i] - '0')) * u;
            digits += 1;
        }
    }
    if (i < s.len and s[i] | 0x20 == 'e') {
        i += 1;
        var eneg = false;
        if (i < s.len and s[i] == '-') {
            eneg = true;
            i += 1;
        } else if (i < s.len and s[i] == '+') i += 1;
        var e: u32 = 0;
        while (i < s.len and s[i] -% '0' <= 9) : (i += 1) e = e *% 10 +% (s[i] - '0');
        if (e > 38) e = 38;
        while (e > 0) : (e -= 1) v = if (eneg) v / 10.0 else v * 10.0;
    }
    if (neg) v = 0.0 - v;
    return if (digits > 0) @floatCast(v) else null;
}

/// cvttss2si: out of range or NaN gives the minimum.
fn cvtt(x: f32) i32 {
    if (x >= -2147483648.0 and x < 2147483648.0) return @intFromFloat(x);
    return std.math.minInt(i32);
}

/// obj_find: the object with exactly this name.
fn objNamed(nm: []const u8) ?usize {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (std.mem.eql(u8, o.name(), nm)) return i;
    }
    return null;
}

// ---- the operators ------------------------------------------------------------------------

const s_mj_bad = "  mech.joint <revolute|slider> <part> <parent|world> [pivot x y z] [axis x y z] [min e] [max e] [gear <joint> <ratio>] [value <expression>] - not understood: ";
const s_mj_none = "  no such mechanism joint: ";

/// mj_option: one option of a record (its keyword in `word`); false: not understood.
fn option(r: []u8, c: *Cur) bool {
    const w = word();
    if (std.mem.eql(u8, w, "value")) {
        // the rest: the expression
        while (c.at(c.i) == ' ') c.i += 1;
        const e = r[MJ_EXPR..][0..MJ_EXPRSZ];
        var k: usize = 0;
        while (true) {
            const ch = c.at(c.i + k);
            e[k] = ch;
            if (ch == 0) break;
            k += 1;
            if (k >= MJ_EXPRSZ - 1) {
                e[k] = 0;
                break;
            }
        }
        c.i += k;
        wrU(r, MJ_SRC, 0);
        return mjExpr(std.mem.sliceTo(e, 0)).ok;
    }
    const is_min = std.mem.eql(u8, w, "min");
    if (is_min or std.mem.eql(u8, w, "max")) {
        if (rdU(r, MJ_FLAGS) & 1 == 0) {
            wrU(r, MJ_FLAGS, rdU(r, MJ_FLAGS) | 1);
            wrU(r, MJ_MIN, 0xff7fffff);
            wrU(r, MJ_MAX_, 0x7f7fffff);
        }
        const x = c.expr();
        if (!x.ok) return false;
        wrF(r, if (is_min) MJ_MIN else MJ_MAX_, x.v);
        return true;
    }
    if (std.mem.eql(u8, w, "nolimits")) {
        wrU(r, MJ_FLAGS, rdU(r, MJ_FLAGS) & ~@as(u32, 1));
        return true;
    }
    if (std.mem.eql(u8, w, "gear")) {
        const s = c.num() orelse return false;
        wrU(r, MJ_SRC, @bitCast(cvtt(s)));
        const q = c.num() orelse return false;
        wrF(r, MJ_RATIO, q);
        r[MJ_EXPR] = 0;
        return true;
    }
    return false;
}

/// mj_unit_axis: its axis made unit (Y when none).
fn unitAxis(r: []u8) void {
    const a = rd3(r, MJ_AXIS);
    var l = a[0] * a[0];
    l += a[1] * a[1];
    l += a[2] * a[2];
    l = @sqrt(l);
    if (!(l > TINY12)) {
        wrF(r, MJ_AXIS, 0);
        wrF(r, MJ_AXIS + 4, 1);
        wrF(r, MJ_AXIS + 8, 0);
        return;
    }
    const s = 1.0 / l;
    for (0..3) |k| wrF(r, MJ_AXIS + k * 4, a[k] * s);
}

fn bad(msg: []const u8) void {
    say(&.{ msg, word() });
    undo.replaceCurrent();
}

/// mech.joint <revolute|slider> <part> <parent|world> [options]
pub fn opJoint() void {
    var nr: [MJ_SZ]u8 = @splat(0);
    const r: []u8 = &nr;
    wrF(r, MJ_AXIS + 4, 1);
    wrF(r, MJ_RATIO, 1);
    var c = Cur{ .s = ops.arg };
    _ = c.next();
    if (std.mem.eql(u8, word(), "revolute")) {
        wrU(r, MJ_TYPE, 1);
    } else if (std.mem.eql(u8, word(), "slider")) {
        wrU(r, MJ_TYPE, 2);
    } else return bad(s_mj_bad);
    _ = c.next();
    const pi = objNamed(word()) orelse return bad(s_mj_bad);
    wrU(r, MJ_B, scene.objects[pi].oid);
    const pp = placeOf(pi);
    placeIn(r, MJ_BREST, pp);
    for (0..3) |k| wrF(r, MJ_PIV + k * 4, pp.loc[k]);
    _ = c.next();
    if (!std.mem.eql(u8, word(), "world")) {
        const ai = objNamed(word()) orelse return bad(s_mj_bad);
        if (ai == pi) return bad(s_mj_bad);
        wrU(r, MJ_A, scene.objects[ai].oid);
        placeIn(r, MJ_AREST, placeOf(ai));
    }
    while (c.next() != 0) {
        const w = word();
        const o: ?usize = if (std.mem.eql(u8, w, "pivot")) MJ_PIV else if (std.mem.eql(u8, w, "axis")) MJ_AXIS else null;
        if (o) |off| {
            for (0..3) |k| {
                const x = c.expr();
                if (!x.ok) return bad(s_mj_bad);
                wrF(r, off + k * 4, x.v);
            }
            continue;
        }
        if (!option(r, &c)) return bad(s_mj_bad);
    }
    unitAxis(r);
    const src = rdU(r, MJ_SRC);
    if (src != 0) {
        const b = anim.own(0) orelse return full();
        if (src > b.h.nmj) return bad(s_mj_bad);
    }
    const b = anim.own(0) orelse return full();
    if (b.h.nmj >= MJ_MAX) return full();
    @memcpy(recOf(b, b.h.nmj), r);
    b.h.nmj += 1;
    logJoint(b.h.nmj - 1);
}

fn full() void {
    say(&.{"  no room for more mechanism joints"});
    undo.replaceCurrent();
}

/// mech.set <n> <option ...>
pub fn opSet() void {
    var c = Cur{ .s = ops.arg };
    const b = anim.own(0) orelse return bad(s_mj_none);
    const n = c.num() orelse return bad(s_mj_none);
    const k: u32 = @bitCast(cvtt(n) -% 1);
    if (k >= b.h.nmj or k >= MJ_MAX) return bad(s_mj_none);
    const r = recOf(b, k);
    while (c.next() != 0) {
        if (!option(r, &c)) return bad(s_mj_none);
    }
}

/// mech.remove <n>
pub fn opRemove() void {
    var c = Cur{ .s = ops.arg };
    const b = anim.own(0) orelse return bad(s_mj_none);
    const n = c.num() orelse return bad(s_mj_none);
    const k: u32 = @bitCast(cvtt(n) -% 1);
    if (k >= b.h.nmj or k >= MJ_MAX) return bad(s_mj_none);
    const nmj: usize = @min(b.h.nmj, MJ_MAX);
    std.mem.copyForwards(u8, b.rest[k * MJ_SZ .. (nmj - 1) * MJ_SZ], b.rest[(k + 1) * MJ_SZ .. nmj * MJ_SZ]);
    b.h.nmj -= 1;
    // gears after it renumbered; one driven by it is still
    for (0..@min(b.h.nmj, MJ_MAX)) |q| {
        const r = recOf(b, q);
        const s = rdU(r, MJ_SRC);
        if (s == k + 1) {
            wrU(r, MJ_SRC, 0);
        } else if (s > k + 1) wrU(r, MJ_SRC, s - 1);
    }
}

/// mech.list
pub fn opList() void {
    for (0..count()) |k| logJoint(k);
}

/// mech.check
pub fn opCheck() void {
    if (count() != 0 and collide(true) != 0) return;
    say(&.{"  no collisions"});
}

// ---- mates (D4) -------------------------------------------------------------------------
// A mate moves the part once, as a placing tool. References: a face number of
// the object's mesh (its centre and normal), or "axis px py pz dx dy dz" in the
// object's own space. It turns about its origin by the shortest arc, then
// moves the least.

const s_as_bad = "  asm.mate <coincident|concentric|distance> <part> <face|axis px py pz dx dy dz> <target> <face|axis ...> [distance] [flip] - not understood: ";

const V3 = [3]f32;

fn vdot(a: V3, b: V3) f32 {
    var x = a[0] * b[0];
    x += a[1] * b[1];
    x += a[2] * b[2];
    return x;
}
fn vcross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
/// normalize (meshops.s): unit, unchanged when about 0.
fn normalize(v: V3) V3 {
    var l = v[0] * v[0];
    l += v[1] * v[1];
    l += v[2] * v[2];
    if (!(l > 1.0e-12)) return v;
    const s = 1.0 / @sqrt(l);
    return .{ v[0] * s, v[1] * s, v[2] * s };
}

/// o_euler_mat: Rz Ry Rx.
fn eulerMat(a: V3) [9]f32 {
    const x = sincos(a[0]);
    const y = sincos(a[1]);
    const z = sincos(a[2]);
    const sx = x[0];
    const cx = x[1];
    const sy = y[0];
    const cy = y[1];
    const sz = z[0];
    const cz = z[1];
    return .{
        cy * cz,      sx * sy * cz - cx * sz, cx * sy * cz + sx * sz,
        cy * sz,      sx * sy * sz + cx * cz, cx * sy * sz - sx * cz,
        -sy,          sx * cy,                cx * cy,
    };
}

/// o_axis_mat: cos I + sin [a]x + (1 - cos) a a^T.
fn axisMat(a: V3, ang: f32) [9]f32 {
    const sc = sincos(ang);
    const s = sc[0];
    const c = sc[1];
    const t = 1.0 - c;
    var r: [9]f32 = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            var x = a[i] * a[j];
            x *= t;
            if (i == j) x += c;
            r[i * 3 + j] = x;
        }
    }
    const z = a[2] * s;
    r[1] -= z;
    r[3] += z;
    const y = a[1] * s;
    r[2] += y;
    r[6] -= y;
    const x = a[0] * s;
    r[5] -= x;
    r[7] += x;
    return r;
}

fn o3mul(a: [9]f32, b: [9]f32) [9]f32 {
    var o: [9]f32 = undefined;
    for (0..3) |r| {
        for (0..3) |c| {
            var x = a[r * 3] * b[c];
            x += a[r * 3 + 1] * b[3 + c];
            x += a[r * 3 + 2] * b[6 + c];
            o[r * 3 + c] = x;
        }
    }
    return o;
}

fn o3mulv(a: [9]f32, v: V3) V3 {
    var o: V3 = undefined;
    for (0..3) |r| {
        var x = a[r * 3] * v[0];
        x += a[r * 3 + 1] * v[1];
        x += a[r * 3 + 2] * v[2];
        o[r] = x;
    }
    return o;
}

/// as_wpoint: a point of the object's space in the world.
fn wpoint(i: usize, p: V3) V3 {
    const mt = objMatrix(i);
    var o: V3 = undefined;
    for (0..3) |r| {
        var x = mt[r * 4 + 3];
        x += mt[r * 4] * p[0];
        x += mt[r * 4 + 1] * p[1];
        x += mt[r * 4 + 2] * p[2];
        o[r] = x;
    }
    return o;
}

/// as_wdir: a direction of the object's space in the world (a normal under
/// its scale): R (n / s), unit.
fn wdir(i: usize, d: V3) V3 {
    const pl = placeOf(i);
    var o: V3 = undefined;
    for (0..3) |c| o[c] = if (pl.scl[c] == 0 or std.math.isNan(pl.scl[c])) d[c] else d[c] / pl.scl[c];
    return normalize(o3mulv(eulerMat(pl.rot), o));
}

const Ref = struct { p: V3, n: V3 };

/// as_ref: a face of the object's mesh (its centre and normal), or "axis ...".
fn ref(i: usize, c: *Cur) ?Ref {
    const before = c.i;
    if (c.next() == 0) return null;
    if (std.mem.eql(u8, word(), "axis")) {
        var v: [6]f32 = undefined;
        for (&v) |*x| {
            const e = c.expr();
            if (!e.ok) return null;
            x.* = e.v;
        }
        return .{ .p = .{ v[0], v[1], v[2] }, .n = normalize(.{ v[3], v[4], v[5] }) };
    }
    if (!isMeshType(scene.objects[i].kind)) return null;
    const me = scene.meshOfObj(i) orelse return null;
    c.i = before;
    const f = c.num() orelse return null;
    const k = cvtt(f);
    if (k < 0) return null;
    const np = me.poff.len -| 1;
    if (@as(u32, @intCast(k)) >= np) return null;
    const lo = me.poff[@intCast(k)];
    const hi = me.poff[@as(usize, @intCast(k)) + 1];
    var ctr: V3 = .{ 0, 0, 0 };
    var nx: f32 = 0;
    var ny: f32 = 0;
    var nz: f32 = 0;
    var q = lo;
    while (q < hi) : (q += 1) {
        const a = me.verts[me.loops[q]];
        const b = me.verts[me.loops[if (q + 1 < hi) q + 1 else lo]];
        for (0..3) |t| ctr[t] += a[t];
        nx += (a[1] - b[1]) * (a[2] + b[2]);
        ny += (a[2] - b[2]) * (a[0] + b[0]);
        nz += (a[0] - b[0]) * (a[1] + b[1]);
    }
    const cnt: f32 = @floatFromInt(@as(i32, @intCast(hi -% lo)));
    for (&ctr) |*x| x.* /= cnt;
    return .{ .p = ctr, .n = normalize(.{ nx, ny, nz }) };
}

/// asm.mate <coincident|concentric|distance> <part> <ref> <target> <ref> [distance] [flip]
pub fn opMate() void {
    var c = Cur{ .s = ops.arg };
    _ = c.next();
    const kind: u32 = if (std.mem.eql(u8, word(), "coincident")) 1 else if (std.mem.eql(u8, word(), "concentric")) 2 else if (std.mem.eql(u8, word(), "distance")) 3 else return bad(s_as_bad);
    _ = c.next();
    const pi = objNamed(word()) orelse return bad(s_as_bad);
    const pr = ref(pi, &c) orelse return bad(s_as_bad);
    _ = c.next();
    const ti = objNamed(word()) orelse return bad(s_as_bad);
    if (ti == pi) return bad(s_as_bad);
    const tr = ref(ti, &c) orelse return bad(s_as_bad);
    var dist: f32 = 0;
    if (kind == 3) {
        const e = c.expr();
        if (!e.ok) return bad(s_as_bad);
        dist = e.v;
    }
    var flip = false;
    while (c.next() != 0) {
        if (!std.mem.eql(u8, word(), "flip")) return bad(s_as_bad);
        flip = true;
    }
    const qw = wpoint(ti, tr.p);
    const mw = wdir(ti, tr.n);
    const nw = wdir(pi, pr.n);
    // where it should point: the target's way (concentric) or against it
    const neg = if (kind == 2) flip else !flip;
    var want = mw;
    if (neg) want = .{ 0.0 - mw[0], 0.0 - mw[1], 0.0 - mw[2] };
    var ax = vcross(nw, want);
    var l = @sqrt(vdot(ax, ax));
    var d = vdot(nw, want);
    var turn = true;
    if (!(l > EPS)) {
        if (d > 0) {
            turn = false;
        } else {
            // half a turn, about any axis across n
            const other: V3 = if (@abs(nw[0]) >= 0.9) .{ 0, 0, 1 } else .{ 1, 0, 0 };
            ax = vcross(nw, other);
            d = -1;
            l = 0;
        }
    }
    const o = &scene.objects[pi];
    if (turn) {
        ax = normalize(ax);
        const ang = atan2f(l, d);
        const rd = axisMat(ax, ang);
        const pl = placeOf(pi);
        const eu = matEuler(&o3mul(rd, eulerMat(pl.rot)));
        setRot(pi, eu);
    }
    const pw = wpoint(pi, pr.p);
    const v: V3 = .{ qw[0] - pw[0], qw[1] - pw[1], qw[2] - pw[2] };
    var t = vdot(v, mw);
    var loc = placeOf(pi).loc;
    if (kind != 2) {
        t += dist;
        for (0..3) |k| loc[k] = mw[k] * t + loc[k];
    } else {
        for (0..3) |k| loc[k] = (v[k] - mw[k] * t) + loc[k];
    }
    setLoc(pi, loc);
    app.dirty = true;
    say(&.{ "  mated: ", o.name(), " to ", scene.objects[ti].name() });
    // a step whatever stays moved (a mechanism's part goes back to its joint's
    // place at once): run_op pushed one before the mate
    anim.rigEval();
    undo.strokeStep("Mate Parts", null);
}

fn setRot(i: usize, eu: V3) void {
    const o = &scene.objects[i];
    if (o.parent == null) {
        o.setRadians(eu);
        return;
    }
    var p = placeOf(i);
    p.rot = eu;
    worldTo(i, p);
}

fn setLoc(i: usize, loc: V3) void {
    const o = &scene.objects[i];
    if (o.parent == null) {
        o.loc = loc;
        return;
    }
    var p = placeOf(i);
    p.loc = loc;
    worldTo(i, p);
}

fn worldTo(i: usize, p: Place) void {
    const mt = objMatrixOf(p.loc, p.rot, p.scl);
    var w: m.M4 = m.identity();
    @memcpy(w[0..12], &mt);
    scene.setWorld(i, w);
}

pub const list = .{
    .{ "mech.joint", ops.Impl{ .run = opJoint } },
    .{ "mech.set", ops.Impl{ .run = opSet } },
    .{ "mech.remove", ops.Impl{ .run = opRemove } },
    .{ "mech.list", ops.Impl{ .run = opList } },
    .{ "mech.check", ops.Impl{ .run = opCheck } },
    .{ "asm.mate", ops.Impl{ .run = opMate } },
};

// ---- tests --------------------------------------------------------------------------------

test "fmt_num6" {
    var b: [48]u8 = undefined;
    try std.testing.expectEqualStrings("0.500000", fmtNum6(&b, 0.5));
    try std.testing.expectEqualStrings("-2.250000", fmtNum6(&b, -2.25));
    try std.testing.expectEqualStrings("0.000000", fmtNum6(&b, -0.0));
    try std.testing.expectEqualStrings("-9223372036854.775808", fmtNum6(&b, std.math.nan(f32)));
    try std.testing.expectEqualStrings("0.100000", fmtNum6(&b, 0.1));
}

test "parse_float as the original" {
    try std.testing.expectEqual(@as(?f32, 3), parseFloat("3"));
    try std.testing.expectEqual(@as(?f32, -1500), parseFloat("-1.5e3"));
    try std.testing.expectEqual(@as(?f32, null), parseFloat("x"));
    try std.testing.expectEqual(@as(?f32, 2), parseFloat("2abc"));
    try std.testing.expectEqual(@as(?f32, null), parseFloat("-"));
}

test "degrees that give the radians back" {
    var rng = std.Random.DefaultPrng.init(7);
    var hit: u32 = 0;
    for (0..2000) |_| {
        const r = (rng.random().float(f32) - 0.5) * 12;
        const d = degOf(r);
        if (d * degf == r) hit += 1;
        try std.testing.expect(@abs(d - r / degf) <= @abs(r / degf) * 1e-6 + 1e-30);
    }
    try std.testing.expect(hit > 1800); // (about 1 in 20 radians has no degrees of its own: deg < 1)
}

test "a revolute joint's matrix keeps the pivot and turns about the axis" {
    var r: [MJ_SZ]u8 = @splat(0);
    wrU(&r, MJ_TYPE, 1);
    wrF(&r, MJ_AXIS + 8, 1);
    wrF(&r, MJ_PIV, 2);
    wrF(&r, MJ_PIV + 4, 1);
    const j = jointMat(&r, std.math.pi / 2.0);
    // the pivot stays
    const p = [3]f32{ 2, 1, 0 };
    for (0..3) |k| try std.testing.expectApproxEqAbs(p[k], j[k * 4] * p[0] + j[k * 4 + 1] * p[1] + j[k * 4 + 2] * p[2] + j[k * 4 + 3], 1e-6);
    // x turns into y about z
    try std.testing.expectApproxEqAbs(@as(f32, 1), j[4], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), j[1], 1e-6);
    // a slider moves along its axis
    wrU(&r, MJ_TYPE, 2);
    const s = jointMat(&r, 3);
    try std.testing.expectEqual(@as(f32, 3), s[11]);
    try std.testing.expectEqual(@as(f32, 0), s[3]);
}

test "a segment through a triangle, and one that touches it" {
    const a = v4(.{ 0, 0, 0 });
    const b = v4(.{ 1, 0, 0 });
    const c = v4(.{ 0, 1, 0 });
    try std.testing.expect(segTri(v4(.{ 0.2, 0.2, -1 }), v4(.{ 0.2, 0.2, 1 }), a, b, c));
    try std.testing.expect(!segTri(v4(.{ 0.2, 0.2, 0 }), v4(.{ 0.2, 0.2, 1 }), a, b, c)); // touching
    try std.testing.expect(!segTri(v4(.{ 2, 2, -1 }), v4(.{ 2, 2, 1 }), a, b, c)); // outside
    try std.testing.expect(!segTri(v4(.{ 0.5, 0, -1 }), v4(.{ 0.5, 0, 1 }), a, b, c)); // on an edge
}

test "pose from a matrix gives back the place" {
    const loc = [3]f32{ 1, 2, 3 };
    const rot = [3]f32{ 0.3, -0.4, 1.2 };
    const scl = [3]f32{ 2, 1, 0.5 };
    const p = poseFromMat(&objMatrixOf(loc, rot, scl));
    for (0..3) |k| {
        try std.testing.expectEqual(loc[k], p.loc[k]);
        try std.testing.expectApproxEqAbs(rot[k], p.rot[k], 1e-5);
        try std.testing.expectApproxEqAbs(scl[k], p.scl[k], 1e-5);
    }
}
