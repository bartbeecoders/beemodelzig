// Force fields (fields.s): objects that push and pull. Add > Force Field makes
// an object of kind .field (drawn as a light's wire octahedron, with a gizmo of
// its own): an Attractor (strength / d^2, softened near the centre, or / d), a
// Gravity Zone (inside its box or sphere down is its -Y), Wind (along its +X,
// with gusts), a Vortex (round its +Y, lift, inflow), Turbulence (curl noise)
// and Drag (-strength x velocity). Every field has a falloff (none, radius,
// smooth), a strength that can be keyframed (field:<name>:strength), the
// collision groups it leaves alone, and can be switched off.
//
// The settings are one block of 64-byte records by object uid, reference
// counted and copied on write like the light settings (lcam.zig), kept by the
// undo steps and in .bee files as FLDS. The solvers call `prep` once a step
// (the fields as they are now: the table) and `accel` per body or particle.
const std = @import("std");
const scene = @import("scene.zig");
const m = @import("math.zig");
const A = @import("alloc.zig").A;

pub const ATTR = 0;
pub const ZONE = 1;
pub const WIND = 2;
pub const VORTEX = 3;
pub const TURB = 4;
pub const DRAG = 5;
pub const N_TYPES = 6;

/// A field's record (FF_*), as in memory and in the file. Words are kept as
/// they come (a damaged file's type or falloff are what the original reads).
pub const Rec = extern struct {
    uid: u32,
    typ: u32 = 0,
    str: f32 = 10, // strength (keyframable)
    fall: u32 = 0, // 0 none, 1 radius (stops there), 2 smooth
    rad: f32 = 10, // its radius (m); a zone's half size
    law: u32 = 0, // an attractor: 0 inverse square, 1 1/d; a zone: 0 box, 1 sphere
    gust: f32 = 0, // wind: gusts 0..1
    scale: f32 = 2, // turbulence: its swirls (m)
    skip: u32 = 0, // the collision groups it leaves alone (bits)
    flags: u32 = 0, // 1: off
    lift: f32 = 0,
    inflow: f32 = 0,
    soft: f32 = 0.1, // an attractor's softening radius (m)
    seed: i32 = 0,
    pad: [2]u32 = .{ 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(Rec) == 64);
    std.debug.assert(@offsetOf(Rec, "str") == 8 and @offsetOf(Rec, "seed") == 52);
}

pub const MAX = 256;

pub const Block = struct {
    refs: u32 = 1,
    n: u32 = 0,
    r: [MAX]Rec = undefined,
};

/// The block now (null: none, as in a new scene).
pub var cur: ?*Block = null;

fn unref(b: ?*Block) void {
    const x = b orelse return;
    x.refs -= 1;
    if (x.refs == 0) A.destroy(x);
}

/// fl_reset: no block (a new scene, a file without FLDS).
pub fn reset() void {
    unref(cur);
    cur = null;
}

/// The undo steps: a snapshot holds a reference to the block it saw.
pub fn keep(slot: *?*Block) void {
    if (cur) |b| b.refs += 1;
    unref(slot.*);
    slot.* = cur;
}
pub fn restore(b: ?*Block) void {
    if (b) |x| x.refs += 1;
    unref(cur);
    cur = b;
}

/// fl_own: cur, unshared (made if none); null without memory.
fn own() ?*Block {
    if (cur) |b| {
        if (b.refs == 1) return b;
    }
    const nb = A.create(Block) catch return null;
    nb.* = .{};
    if (cur) |b| {
        nb.n = b.n;
        @memcpy(nb.r[0..b.n], b.r[0..b.n]);
    }
    unref(cur);
    cur = nb;
    return nb;
}

/// fl_get: its record (read only), or null.
pub fn get(uid: u32) ?*const Rec {
    const b = cur orelse return null;
    for (b.r[0..b.n]) |*r| {
        if (r.uid == uid) return r;
    }
    return null;
}

/// fl_view: object i's record, or the defaults (an attractor's).
pub fn view(i: usize) Rec {
    const uid = scene.objects[i].uid;
    if (get(uid)) |r| return r.*;
    var d = Rec{ .uid = uid };
    setType(&d, 0);
    return d;
}

/// The defaults per type (fl_defs): strength, falloff, radius, gust.
const defs = [N_TYPES][4]f32{
    .{ 10.0, 0, 10.0, 0 },
    .{ 9.81, 0, 2.0, 0 },
    .{ 5.0, 0, 10.0, 0.3 },
    .{ 5.0, 2, 5.0, 0 },
    .{ 5.0, 0, 10.0, 0 },
    .{ 0.5, 0, 10.0, 0 },
};

/// fl_set_type: that type with its defaults (everything after the type; a type
/// out of range: an attractor).
pub fn setType(r: *Rec, t0: u32) void {
    const t = if (t0 < N_TYPES) t0 else 0;
    const d = defs[t];
    r.* = .{ .uid = r.uid, .typ = t, .str = d[0], .fall = @intFromFloat(d[1]), .rad = d[2], .gust = d[3] };
}

/// fl_rec_own: its record, writable (a new one of this type with its
/// defaults); null when full or without memory.
pub fn recOwn(uid: u32, typ: u32) ?*Rec {
    const b = own() orelse return null;
    for (b.r[0..b.n]) |*r| {
        if (r.uid == uid) return r;
    }
    if (b.n >= MAX) return null;
    b.r[b.n] = .{ .uid = uid };
    setType(&b.r[b.n], typ);
    b.n += 1;
    return &b.r[b.n - 1];
}

/// fl_copy: a duplicate's settings (object.duplicate).
pub fn copy(uid: u32, new_uid: u32) void {
    if (get(uid) == null) return;
    const r = recOwn(new_uid, 0) orelse return;
    const s = get(uid) orelse return; // (the block may have been copied)
    const keep_uid = r.uid;
    r.* = s.*;
    r.uid = keep_uid;
}

/// fl_write: the FLDS chunk (count, then the records).
pub fn write(out: anytype) void {
    const b = cur orelse {
        out.u32_(0);
        return;
    };
    out.u32_(b.n);
    out.bytes(std.mem.sliceAsBytes(b.r[0..b.n]));
}

/// fl_read: a chunk as the original reads it: too short, or fewer bytes than
/// its count says, and there is no block (at most 256 records).
pub fn read(c: []const u8) void {
    reset();
    if (c.len < 4) return;
    const k: usize = @min(std.mem.readInt(u32, c[0..4], .little), MAX);
    if (k * 64 + 4 > c.len) return;
    const b = A.create(Block) catch return;
    b.* = .{ .n = @intCast(k) };
    @memcpy(std.mem.sliceAsBytes(b.r[0..k]), c[4..][0 .. k * 64]);
    cur = b;
}

/// What the viewport's drawing of the fields depends on (viewport stateKey).
pub fn stateWord() u64 {
    var h: u64 = 0x666c6473;
    if (cur) |b| h = scMix(h, std.mem.sliceAsBytes(b.r[0..b.n]));
    h = scMix(h, std.mem.asBytes(&[2]bool{ show_arrows, show_lines }));
    if (show_arrows or show_lines) {
        // (the overlay moves with time: gusts, turbulence; and the selection's seeds)
        h = scMix(h, std.mem.asBytes(&@import("anim.zig").frame));
        for (scene.objects[0..scene.count]) |*o| h = scMix(h, std.mem.asBytes(&o.selected));
    }
    return h;
}

// --- this step's fields ------------------------------------------------------------------

/// A field as it is this step (FT_*).
const FT = struct {
    c: [3]f32, // centre
    ax: [3]f32, // its axis: wind +X, else +Y (unit)
    u: [3]f32, // its +X, +Z (unit)
    v: [3]f32,
    hs: [3]f32, // a box zone's half sizes
    off: [3]f32, // turbulence: where in the noise
    typ: u32,
    fall: u32,
    str: f32, // (wind: with this moment's gust)
    rad: f32,
    law: u32,
    skip: u32,
    lift: f32,
    inflow: f32,
    soft2: f32,
    iscale: f32,
};
const FT_MAX = 64;
var tab: [FT_MAX]FT = undefined;
/// Fields this step (fl_n), of them wind (fl_nw).
pub var n: u32 = 0;
pub var nw: u32 = 0;
var grav: [3]f32 = .{ 0, 0, 0 };

const TINY: f32 = 1.0e-6;

fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
/// dpps 0x71: (x x' + y y') + z z'
fn dot3(a: [3]f32, b: [3]f32) f32 {
    return (a[0] * b[0] + a[1] * b[1]) + a[2] * b[2];
}
fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
fn add3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
fn mul3(a: [3]f32, s: f32) [3]f32 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
fn div3(a: [3]f32, s: f32) [3]f32 {
    return .{ a[0] / s, a[1] / s, a[2] / s };
}

/// The object's matrix as obj_matrix gives it (3 rows of 4): T Rz Ry Rx S from
/// the radians it holds; a child's from its world transform.
pub fn objMatrix(i: usize) [12]f32 {
    const o = &scene.objects[i];
    if (o.parent != null) return scene.world(i)[0..12].*;
    const sc = @import("animexpr.zig").sincos32;
    const rad = o.radians();
    const x = sc(rad[0]);
    const y = sc(rad[1]);
    const z = sc(rad[2]);
    const sx = x[0];
    const cx = x[1];
    const sy = y[0];
    const cy = y[1];
    const sz = z[0];
    const cz = z[1];
    var r: [12]f32 = .{
        cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx, o.loc[0],
        sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx, o.loc[1],
        0 - sy,  cy * sx,                cy * cx,                o.loc[2],
    };
    for (0..3) |row| {
        for (0..3) |c| r[row * 4 + c] = o.scl[c] * r[row * 4 + c];
    }
    return r;
}

/// fl_col: column c of a 3x4 matrix, unit; and its length (at least 1e-6).
fn col(mt: *const [12]f32, c: usize) struct { v: [3]f32, len: f32 } {
    const v = [3]f32{ mt[c], mt[4 + c], mt[8 + c] };
    const l = maxss(@sqrt(dot3(v, v)), TINY);
    return .{ .v = div3(v, l), .len = l };
}

/// The world's gravity (rb_gravity: the physics world's, -9.81 Y unless set).
pub fn worldGravity() [3]f32 {
    const an = @import("anim.zig");
    const b = an.cur orelse return .{ 0, -9.81, 0 };
    const rw = &b.h.rw;
    if (std.mem.readInt(u32, rw[20..24], .little) == 0) return .{ 0, -9.81, 0 };
    var g: [3]f32 = undefined;
    for (0..3) |k| g[k] = @bitCast(std.mem.readInt(u32, rw[k * 4 ..][0..4], .little));
    return g;
}
/// Where fl_sample takes gravity from (the rigid bodies' world: rbody may set it).
pub var gravity_fn: *const fn () [3]f32 = &worldGravity;

/// fl_prep: the table, every visible field that is on, as it is at time t (s);
/// g the world's gravity.
pub fn prep(t: f32, g: [3]f32) void {
    grav = g;
    n = 0;
    nw = 0;
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.kind != .field or !o.visible) continue;
        const r = view(i);
        if (r.flags & 1 != 0) continue;
        if (n >= FT_MAX) break;
        const f = &tab[n];
        const mt = objMatrix(i);
        f.c = .{ mt[3], mt[7], mt[11] };
        const cu = col(&mt, 0);
        const ca = col(&mt, 1);
        const cv = col(&mt, 2);
        f.u = cu.v;
        f.ax = ca.v;
        f.v = cv.v;
        f.hs = .{ cu.len, ca.len, cv.len };
        f.rad = r.rad * f.hs[0];
        f.hs = mul3(f.hs, r.rad);
        f.typ = r.typ;
        f.fall = r.fall;
        f.law = r.law;
        f.skip = r.skip & 0xffff;
        f.lift = r.lift;
        f.inflow = r.inflow;
        f.soft2 = r.soft * r.soft;
        f.iscale = 1.0 / maxss(r.scale, 0.01);
        const sd: f32 = @floatFromInt(r.seed);
        f.off = .{ sd * 13.7 + t * 0.25, sd * 3.1, sd * 5.9 };
        f.str = r.str;
        if (r.typ == WIND) {
            f.ax = f.u; // wind: along +X, with its gust now
            nw += 1;
            if (r.gust > 0) {
                const p = [3]f32{ t * 0.5, sd * 7.13 + 0.5, 0.37 };
                f.str = (perlin(p) * r.gust + 1.0) * f.str;
            }
        }
        n += 1;
    }
}

fn perlin(p: [3]f32) f32 {
    return @import("shgraph.zig").perlin(.{ p[0], p[1], p[2] });
}

/// fl_fall: the field's falloff at distance d.
fn fall(d: f32, f: *const FT) f32 {
    if (f.fall == 0) return 1;
    if (d >= f.rad) return 0;
    if (f.fall == 1) return 1;
    var q = d / maxss(f.rad, TINY);
    q = q * q;
    const s = 1.0 - q;
    return s * s;
}

/// fl_accel: the acceleration at p (velocity v, null: still) of a thing in the
/// collision group whose bit is `group_bit` (no_wind: cloth, where wind is
/// air): the fields' sum plus gravity (a gravity zone's when inside one, else
/// the world's). Reads the table only: the solvers' workers call it.
pub fn accel(p: [3]f32, v: ?[3]f32, group_bit: u32, no_wind: bool) [3]f32 {
    const vel = v orelse [3]f32{ 0, 0, 0 };
    var sum = [3]f32{ 0, 0, 0 };
    var zone = false;
    var zg: [3]f32 = undefined;
    for (tab[0..n]) |*f| {
        if (f.skip & group_bit != 0) continue;
        const d = sub3(p, f.c);
        switch (f.typ) {
            ATTR => {
                // -d s f / q^1.5 (q = d2 + soft2), or / q
                const d2 = dot3(d, d);
                const fv = fall(@sqrt(d2), f);
                var q = d2 + f.soft2;
                var s = f.str * fv;
                if (f.law == 0) q = q * @sqrt(q);
                q = maxss(q, TINY);
                s = s / q;
                sum = sub3(sum, mul3(d, s));
            },
            ZONE => {
                // inside: down = -Y s (the first zone)
                if (zone) continue;
                if (f.law == 0) {
                    if (@abs(dot3(d, f.u)) > f.hs[0]) continue;
                    if (@abs(dot3(d, f.ax)) > f.hs[1]) continue;
                    if (@abs(dot3(d, f.v)) > f.hs[2]) continue;
                } else {
                    if (@sqrt(dot3(d, d)) > f.rad) continue;
                }
                zg = mul3(f.ax, -f.str);
                zone = true;
            },
            WIND => {
                if (no_wind) continue;
                const s = fall(@sqrt(dot3(d, d)), f) * f.str;
                sum = add3(mul3(f.ax, s), sum);
            },
            VORTEX => {
                // f (s t - inflow r + lift a)
                const a = dot3(d, f.ax);
                const r = sub3(d, mul3(f.ax, a)); // off the axis
                const len = @sqrt(dot3(r, r));
                if (!(len > TINY)) continue;
                const fv = fall(len, f);
                const ax = f.ax;
                const cr = [3]f32{ ax[1] * r[2] - ax[2] * r[1], ax[2] * r[0] - ax[0] * r[2], ax[0] * r[1] - ax[1] * r[0] };
                var t = mul3(div3(cr, len), f.str);
                t = sub3(t, mul3(div3(r, len), f.inflow));
                t = add3(t, mul3(ax, f.lift));
                t = mul3(t, fv);
                sum = add3(t, sum);
            },
            TURB => {
                // s f curl(noise(p / scale + off))
                const fv = fall(@sqrt(dot3(d, d)), f);
                if (!(fv > 0)) continue;
                const q = add3(mul3(p, f.iscale), f.off);
                const c = curl(q);
                sum = add3(mul3(c, fv * f.str), sum);
            },
            DRAG => {
                const s = fall(@sqrt(dot3(d, d)), f) * f.str;
                sum = sub3(sum, mul3(vel, s));
            },
            else => {},
        }
    }
    return add3(if (zone) zg else grav, sum);
}

/// curl: (potential, axis, minus, into)
const curl_terms = [6][4]u8{ .{ 2, 1, 0, 0 }, .{ 1, 2, 1, 0 }, .{ 0, 2, 0, 1 }, .{ 2, 0, 1, 1 }, .{ 1, 0, 0, 2 }, .{ 0, 1, 1, 2 } };
const curl_offs = [3][3]f32{ .{ 0, 0, 0 }, .{ 31.416, -12.7, 47.1 }, .{ -19.3, 57.9, 7.3 } };

/// fl_curl: the curl of three noise potentials at q (central differences).
fn curl(q: [3]f32) [3]f32 {
    var out = [3]f32{ 0, 0, 0 };
    for (curl_terms) |t| {
        const o = curl_offs[t[0]];
        var p = add3(q, o);
        p[t[1]] = p[t[1]] + 0.01;
        const a = perlin(p);
        p[t[1]] = p[t[1]] - 0.02;
        const b = perlin(p);
        var dv = (a - b) * 50.0;
        if (t[2] != 0) dv = -dv;
        out[t[3]] = dv + out[t[3]];
    }
    return out;
}

/// fl_wind: the wind fields' air at p (cloth: group 0).
pub fn wind(p: [3]f32) [3]f32 {
    var s = [3]f32{ 0, 0, 0 };
    for (tab[0..n]) |*f| {
        if (f.typ != WIND or f.skip & 1 != 0) continue;
        const d = sub3(p, f.c);
        const w = fall(@sqrt(dot3(d, d)), f) * f.str;
        s = add3(s, mul3(f.ax, w));
    }
    return s;
}

/// fl_time: the scene's time now (s: frame / fps).
pub fn time() f32 {
    // (an_cur's AN_FPS, which the port keeps in frange.r; no block - the
    // original's an_cur unset - and the time is the frame itself)
    const an = @import("anim.zig");
    const fr = @import("frange.zig");
    if (an.cur == null) return an.frame;
    return an.frame / maxss(fr.r.fps, 1.0);
}

/// fl_sample: the acceleration a still thing of group 0 feels at p now
/// (BeeScript force(), the logic nodes).
pub fn sample(p: [3]f32) [3]f32 {
    prep(time(), gravity_fn());
    return accel(p, null, 1, false);
}

/// sc_mix (simcache.s): bytes into a hash (simcache.zig keeps the one).
pub fn scMix(h0: u64, b: []const u8) u64 {
    return @import("simcache.zig").mix(h0, b);
}

/// an_hash: the animation mixed in (start, end, fps, curves, actions, layers,
/// keys, drivers, constraints, mechanism joints).
pub fn animHash(h0: u64) u64 {
    const an = @import("anim.zig");
    const b = an.cur orelse return h0;
    var h = scMix(h0, std.mem.asBytes(&b.h)[24..36]);
    h = scMix(h, std.mem.sliceAsBytes(b.h.cur[0..@min(b.h.ncur, an.MAXC)]));
    h = scMix(h, std.mem.sliceAsBytes(b.h.act[0..@min(b.h.nact, an.MAXA)]));
    h = scMix(h, std.mem.sliceAsBytes(b.h.lay[0..@min(b.h.nlay, an.MAXL)]));
    h = scMix(h, std.mem.sliceAsBytes(b.keys[0..@min(b.h.nkey, b.keys.len)]));
    h = scMix(h, std.mem.sliceAsBytes(b.h.drv[0..@min(b.h.ndrv, an.MAXDRV)]));
    for (b.h.con[0..@min(b.h.ncon, an.MAXCON)]) |*c| h = scMix(h, std.mem.asBytes(c)[0..72]);
    const mj = 208;
    for (0..@min(b.h.nmj, 64)) |k| {
        if ((k + 1) * mj > b.rest.len) break;
        h = scMix(h, b.rest[k * mj ..][0..56]);
        h = scMix(h, b.rest[k * mj + 64 ..][0 .. mj - 64]);
    }
    return h;
}

/// an_fkeyed: the field's strength is keyed.
fn fkeyed(oid: u32) bool {
    const an = @import("anim.zig");
    const b = an.cur orelse return false;
    for (b.curves()) |*c| {
        if (c.kind == an.K_FIELD and c.a == oid) return true;
    }
    return false;
}

/// fl_mix: the fields (where they are, their settings) mixed into a
/// simulation's cache key. A field that something moves, or whose strength is
/// keyed, mixes in the animation instead of where it is and its strength now.
pub fn mix(h0: u64) u64 {
    var h = h0;
    var animated = false;
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.kind != .field) continue;
        if (@import("anim.zig").moves(o.oid)) {
            animated = true;
        } else {
            const rad = o.radians();
            const t = [9]f32{ o.loc[0], o.loc[1], o.loc[2], rad[0], rad[1], rad[2], o.scl[0], o.scl[1], o.scl[2] };
            h = scMix(h, std.mem.asBytes(&t));
        }
        if (!o.visible) h ^= 0x200; // (OBF_HIDDEN)
        var r = view(i);
        if (fkeyed(o.oid)) {
            animated = true;
            r.str = 0;
        }
        h = scMix(h, std.mem.asBytes(&r));
    }
    if (animated) h = animHash(h);
    return h;
}

/// fl_chan: the field:<name>:strength channel of object oid: its strength
/// (set: to v first); null when it is no field.
pub fn chan(oid: u32, v: f32, set: bool) ?f32 {
    const i = scene.findOid(oid) orelse return null;
    if (scene.objects[i].kind != .field) return null;
    if (set) {
        if (view(i).str != v) {
            const r = recOwn(scene.objects[i].uid, 0) orelse return null;
            r.str = v;
            @import("undo.zig").absorbFields();
        }
    }
    return view(i).str;
}

/// fl_active: the active object when it is a field.
pub fn active() ?usize {
    const i = scene.active orelse return null;
    if (i >= scene.count or scene.objects[i].kind != .field) return null;
    return i;
}

/// fl_info: 0 force fields in the scene, 1 the overlay's arrows (last drawn),
/// 2 its line segments, 3 the largest pull it showed.
pub fn info(k: u32) f32 {
    return switch (k) {
        1 => @floatFromInt(fo_na),
        2 => @floatFromInt(fo_nl),
        3 => fo_max,
        0 => blk: {
            var c: u32 = 0;
            for (scene.objects[0..scene.count]) |*o| {
                if (o.kind == .field) c += 1;
            }
            break :blk @floatFromInt(c);
        },
        else => 0,
    };
}

// --- operators --------------------------------------------------------------------------

pub const tnames = [N_TYPES][]const u8{ "Attractor", "Gravity Zone", "Wind", "Vortex", "Turbulence", "Drag" };
/// fl_kwtypes: the types, then the presets (field.set type planet: an attractor)
pub const kwtypes = [_][]const u8{ "attractor", "zone", "wind", "vortex", "turbulence", "drag", "planet", "blackhole", "tornado", "breeze" };
const Preset = struct { typ: u32, name: []const u8, set: []const u8 };
const presets = [4]Preset{
    .{ .typ = ATTR, .name = "Planet Core", .set = "strength 981 soft 1" },
    .{ .typ = ATTR, .name = "Black Hole", .set = "strength 2000 soft 0.2 falloff smooth radius 8" },
    .{ .typ = VORTEX, .name = "Tornado", .set = "strength 15 lift 8 inflow 4 falloff smooth radius 6" },
    .{ .typ = WIND, .name = "Breeze", .set = "strength 2 gust 0.6" },
};

/// fl_type_of: the field type (or preset) a word names, -1: none.
pub fn typeOf(s: []const u8) i32 {
    for (kwtypes, 0..) |k, i| {
        if (std.mem.eql(u8, k, s)) return @intCast(i);
    }
    return -1;
}

/// im_next_word: words split at spaces only, each at most 255 bytes.
const Words = struct {
    s: []const u8,
    i: usize = 0,
    fn next(w: *Words) ?[]const u8 {
        while (w.i < w.s.len and w.s[w.i] == ' ') w.i += 1;
        const st = w.i;
        while (w.i < w.s.len and w.s[w.i] != ' ' and w.s[w.i] != 0) w.i += 1;
        if (w.i == st) {
            w.i = w.s.len;
            return null;
        }
        return w.s[st..@min(w.i, st + 255)];
    }
};

const Kind = enum { float, whole, list, typ, groups, on, off };
const Word = struct { w: []const u8, off: usize, k: Kind, list: []const []const u8 = &.{} };
const kw_fall = [_][]const u8{ "none", "radius", "smooth" };
const kw_law = [_][]const u8{ "square", "linear" };
const kw_shape = [_][]const u8{ "box", "sphere" };
const fp_tab = [_]Word{
    .{ .w = "strength", .off = 8, .k = .float },
    .{ .w = "falloff", .off = 12, .k = .list, .list = &kw_fall },
    .{ .w = "radius", .off = 16, .k = .float },
    .{ .w = "size", .off = 16, .k = .float },
    .{ .w = "law", .off = 20, .k = .list, .list = &kw_law },
    .{ .w = "shape", .off = 20, .k = .list, .list = &kw_shape },
    .{ .w = "gust", .off = 24, .k = .float },
    .{ .w = "scale", .off = 28, .k = .float },
    .{ .w = "seed", .off = 52, .k = .whole },
    .{ .w = "lift", .off = 40, .k = .float },
    .{ .w = "inflow", .off = 44, .k = .float },
    .{ .w = "soft", .off = 48, .k = .float },
    .{ .w = "groups", .off = 32, .k = .groups },
    .{ .w = "type", .off = 4, .k = .typ },
    .{ .w = "on", .off = 0, .k = .on },
    .{ .w = "off", .off = 0, .k = .off },
};

fn indexIn(words: []const []const u8, w: []const u8) ?u32 {
    for (words, 0..) |x, i| {
        if (std.mem.eql(u8, x, w)) return @intCast(i);
    }
    return null;
}

/// cvttss2si: out of range or NaN gives 0x80000000.
fn cvtt(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(x);
}

/// fl_parse: "strength 20 falloff smooth ..." into a record; false at a word
/// it does not understand (said in the console; what came before it stays).
pub fn parse(r: *Rec, text: []const u8) bool {
    var it = Words{ .s = text };
    const bytes: *[64]u8 = @ptrCast(r);
    while (it.next()) |w| {
        const e = for (fp_tab) |e| {
            if (std.mem.eql(u8, e.w, w)) break e;
        } else return bad(w);
        switch (e.k) {
            .on => {
                r.flags &= ~@as(u32, 1);
                continue;
            },
            .off => {
                r.flags |= 1;
                continue;
            },
            else => {},
        }
        const val = it.next() orelse return bad("");
        switch (e.k) {
            .list => {
                const k = indexIn(e.list, val) orelse return bad(val);
                std.mem.writeInt(u32, bytes[e.off..][0..4], k, .little);
            },
            .typ => {
                const k = indexIn(&kwtypes, val) orelse return bad(val);
                if (k != r.typ) setType(r, k);
            },
            .groups => {
                if (std.mem.eql(u8, val, "all")) {
                    r.skip = 0;
                    continue;
                }
                var mask: u32 = 0;
                var num: u32 = 0;
                var digits: u32 = 0;
                var i: usize = 0;
                while (true) {
                    const ch: u8 = if (i < val.len) val[i] else 0;
                    i += 1;
                    if (ch >= '0' and ch <= '9') {
                        num = num *% 10 +% (ch - '0');
                        digits += 1;
                        continue;
                    }
                    if (ch > '9') return bad(val);
                    if (digits > 0) {
                        if (num > 15) return bad(val);
                        mask |= @as(u32, 1) << @intCast(num);
                    }
                    num = 0;
                    digits = 0;
                    if (ch == ',') continue;
                    if (ch != 0) return bad(val);
                    break;
                }
                if (mask == 0) return bad(val);
                r.skip = ~mask & 0xffff;
            },
            .float, .whole => {
                const x = @import("print.zig").parseFloat(val) orelse return bad(val);
                const bits: u32 = if (e.k == .whole) @bitCast(cvtt(x)) else @bitCast(x);
                std.mem.writeInt(u32, bytes[e.off..][0..4], bits, .little);
            },
            .on, .off => unreachable,
        }
    }
    return true;
}

fn bad(w: []const u8) bool {
    @import("app.zig").log("  field: not understood: {s}", .{w});
    return false;
}

/// unique_name: the base (26 bytes at most), then base.001 ...
fn uniqueName(i: usize, base0: []const u8) void {
    const base = base0[0..@min(base0.len, 26)];
    var buf: [32]u8 = undefined;
    scene.objects[i].name_len = 0;
    var k: u32 = 0;
    while (k < 1000) : (k += 1) {
        const nm = if (k == 0) base else std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ base, k }) catch base;
        if (scene.find(nm) == null) {
            scene.objects[i].setName(nm);
            return;
        }
    }
    scene.objects[i].setName(base);
}

/// fl_add_named: a field at the 3D cursor called `name`, with the preset's
/// settings, then the operator's.
fn addNamed(typ: u32, name: []const u8, pre: []const u8) void {
    const app = @import("app.zig");
    const ops = @import("ops.zig");
    const i = scene.add(.field) orelse return app.toast(.warn, "The scene is full ({d} objects)", .{scene.max_objects});
    const o = &scene.objects[i];
    uniqueName(i, name);
    o.loc = scene.cursor;
    if (recOwn(o.uid, typ)) |r| {
        _ = parse(r, pre);
        _ = parse(r, ops.arg);
    }
    app.dirty = true;
    if (!ops.quiet) app.log("  added {s}", .{o.name()});
}

fn add(comptime t: u32) *const fn () void {
    return &struct {
        fn f() void {
            addNamed(t, tnames[t], "");
            @import("undo.zig").label(tnames[t]);
        }
    }.f;
}

fn preset(comptime k: u32) *const fn () void {
    return &struct {
        fn f() void {
            const undo = @import("undo.zig");
            if (k == 0) {
                // a planet: a 10 m sphere at the cursor, the world's gravity off
                @import("ops.zig").runId("create.sphere");
                if (scene.active) |a| {
                    uniqueName(a, "Planet");
                    scene.objects[a].scl = .{ 10, 10, 10 };
                }
                if (@import("anim.zig").own(0)) |b| {
                    @memset(b.h.rw[0..12], 0);
                    std.mem.writeInt(u32, b.h.rw[20..24], 1, .little); // (RW_SET)
                }
            }
            const p = presets[k];
            addNamed(p.typ, p.name, p.set);
            undo.label(labels[k]);
        }
    }.f;
}
const labels = [4][]const u8{ "Planet", "Black Hole", "Tornado", "Breeze" };

/// field.set ... on the active field.
fn opSet() void {
    const i = active() orelse return @import("app.zig").log("  select a force field first (Add > Force Field)", .{});
    const r = recOwn(scene.objects[i].uid, 0) orelse return;
    _ = parse(r, @import("ops.zig").arg);
    @import("app.zig").dirty = true;
    @import("undo.zig").label("Field Settings");
}

/// View > Force Field Arrows / Lines.
pub var show_arrows = false;
pub var show_lines = false;
fn opArrows() void {
    show_arrows = !show_arrows;
    @import("app.zig").dirty = true;
}
fn opLines() void {
    show_lines = !show_lines;
    @import("app.zig").dirty = true;
}
fn isArrows() bool {
    return show_arrows;
}
fn isLines() bool {
    return show_lines;
}

const Impl = @import("ops.zig").Impl;
pub const list = .{
    .{ "field.add_attractor", Impl{ .run = add(ATTR) } },
    .{ "field.add_zone", Impl{ .run = add(ZONE) } },
    .{ "field.add_wind", Impl{ .run = add(WIND) } },
    .{ "field.add_vortex", Impl{ .run = add(VORTEX) } },
    .{ "field.add_turbulence", Impl{ .run = add(TURB) } },
    .{ "field.add_drag", Impl{ .run = add(DRAG) } },
    .{ "field.add_planet", Impl{ .run = preset(0) } },
    .{ "field.add_blackhole", Impl{ .run = preset(1) } },
    .{ "field.add_tornado", Impl{ .run = preset(2) } },
    .{ "field.add_breeze", Impl{ .run = preset(3) } },
    .{ "view.field_arrows", Impl{ .run = opArrows, .check = isArrows } },
    .{ "view.field_lines", Impl{ .run = opLines, .check = isLines } },
    .{ "field.set", Impl{ .run = opSet } },
};

// --- in the viewport ----------------------------------------------------------------------

/// The drawing frame (fd_*): centre, unit axes, the icon's size.
const Frame = struct {
    c: [3]f32 = .{ 0, 0, 0 },
    x: [3]f32 = .{ 1, 0, 0 },
    y: [3]f32 = .{ 0, 1, 0 },
    z: [3]f32 = .{ 0, 0, 1 },
    k: f32 = 1,
    col: u32 = 0,

    /// fd_at: centre + k (x X + y Y + z Z)
    fn at(f: *const Frame, x: f32, y: f32, z: f32) m.V3 {
        const a = mul3(f.x, x * f.k);
        const b = mul3(f.y, y * f.k);
        const cz = mul3(f.z, z * f.k);
        const s = add3(add3(add3(a, b), cz), f.c);
        return .{ s[0], s[1], s[2] };
    }
};

fn Drawer(comptime Cv: type, comptime C: type, comptime L: type) type {
    return struct {
        cv: Cv,
        c: C,
        line: *const L,
        f: Frame = .{},
        const D = @This();

        fn seg(d: *D, a: [3]f32, b: [3]f32) void {
            d.line(d.cv, d.c, d.f.at(a[0], a[1], a[2]), d.f.at(b[0], b[1], b[2]), d.f.col);
        }

        /// fd_circle: plane 0 XZ (round Y), 1 XY, 2 YZ; radius, offset along its normal.
        fn circle(d: *D, plane: u32, r: f32, off: f32) void {
            const sc = @import("animexpr.zig").sincos32;
            var prev: [3]f32 = undefined;
            var i: u32 = 0;
            while (i <= 24) : (i += 1) {
                const ang = @as(f32, @floatFromInt(i)) * 6.28318531 / 24.0;
                const s = sc(ang);
                const sn = s[0] * r;
                const cs = s[1] * r;
                const p: [3]f32 = switch (plane) {
                    1 => .{ cs, sn, off },
                    2 => .{ off, cs, sn },
                    else => .{ cs, off, sn },
                };
                if (i > 0) d.seg(prev, p);
                prev = p;
            }
        }

        /// fd_arrow: a line with a head (two strokes back from the tip, a quarter of it).
        fn arrow(d: *D, a: [3]f32, b: [3]f32) void {
            d.seg(a, b);
            const dir = mul3(sub3(b, a), 0.25);
            var side = [3]f32{ dir[1], -dir[0], 0 };
            if (!(side[0] * side[0] + side[1] * side[1] > TINY)) side = .{ dir[2], 0, -dir[0] };
            side = mul3(side, 0.5);
            const back = sub3(b, dir);
            d.seg(b, add3(back, side));
            d.seg(b, sub3(back, side));
        }

        /// fd_box: a box of half size h (icon sizes), its 12 edges.
        fn box(d: *D, h: f32) void {
            for (0..12) |e| {
                const s6 = if (e & 1 != 0) -h else h;
                const s7 = if (e & 2 != 0) -h else h;
                switch (e >> 2) {
                    0 => d.seg(.{ -h, s6, s7 }, .{ h, s6, s7 }),
                    1 => d.seg(.{ s6, -h, s7 }, .{ s6, h, s7 }),
                    else => d.seg(.{ s6, s7, -h }, .{ s6, s7, h }),
                }
            }
        }
    };
}

const gz = [9]f32{ 0.45, 0.9, 0.18, 1.5, 0.4, 0.8, 0.25, 1.0, 0.3 };

/// fl_draw: every visible field's gizmo (its kind, its reach), then the
/// overlay (View > Force Field Arrows / Lines). `line(cv, c, a, b, colour)`.
pub fn draw(cv: anytype, c: anytype, line: anytype, th: anytype) void {
    var d = Drawer(@TypeOf(cv), @TypeOf(c), @TypeOf(line)){ .cv = cv, .c = c, .line = &line };
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.kind != .field or !o.visible) continue;
        d.f.col = if (o.selected) th.accent else th.text_dim;
        const r = view(i);
        const mt = objMatrix(i);
        const cx = col(&mt, 0);
        d.f.x = cx.v;
        d.f.k = cx.len;
        d.f.y = col(&mt, 1).v;
        d.f.z = col(&mt, 2).v;
        d.f.c = .{ mt[3], mt[7], mt[11] };
        if (r.typ == ZONE) {
            // its box (or sphere), down
            if (r.law != 0) {
                d.circle(0, r.rad, 0);
                d.circle(1, r.rad, 0);
                d.circle(2, r.rad, 0);
            } else d.box(r.rad);
            d.arrow(.{ 0, gz[8], 0 }, .{ 0, -gz[7], 0 });
            continue;
        }
        if (r.fall != 0) {
            // its reach: three circles (a vortex: one)
            d.circle(0, r.rad, 0);
            if (r.typ != VORTEX) {
                d.circle(1, r.rad, 0);
                d.circle(2, r.rad, 0);
            }
        }
        switch (r.typ) {
            ATTR => {
                // six arrows in (out when it pushes)
                for (0..6) |k| {
                    var a = gz[1];
                    var b = gz[8];
                    if (0 > r.str) std.mem.swap(f32, &a, &b);
                    if (k & 1 != 0) {
                        a = -a;
                        b = -b;
                    }
                    switch (k >> 1) {
                        0 => d.arrow(.{ a, 0, 0 }, .{ b, 0, 0 }),
                        1 => d.arrow(.{ 0, a, 0 }, .{ 0, b, 0 }),
                        else => d.arrow(.{ 0, 0, a }, .{ 0, 0, b }),
                    }
                }
            },
            WIND => {
                // three arrows along +X
                for (0..3) |k| {
                    const y = @as(f32, @floatFromInt(@as(i32, @intCast(k)) - 1)) * gz[4];
                    d.arrow(.{ -gz[7], y, 0 }, .{ gz[3], y, 0 });
                }
            },
            VORTEX => {
                // its axis, rings round it, the way it turns
                d.arrow(.{ 0, -gz[7], 0 }, .{ 0, gz[7], 0 });
                d.circle(0, gz[5], -gz[4]);
                d.circle(0, gz[0], gz[4]);
                var a = -gz[6];
                var b = gz[6];
                if (0 > r.str) std.mem.swap(f32, &a, &b);
                d.arrow(.{ gz[5], 0, a }, .{ gz[5], 0, b });
            },
            TURB => {
                // a wavy line along X
                for (0..8) |k| {
                    const x = @as(f32, @floatFromInt(k)) * gz[6] - gz[7];
                    const y = @as(f32, @floatFromInt(@as(i32, @intCast(k & 1)) * 2 - 1)) * gz[2];
                    d.seg(.{ x, y, 0 }, .{ x + gz[6], -y, 0 });
                }
            },
            else => {
                // drag (and any type a file has that is none): two rings
                d.circle(0, gz[0], 0);
                d.circle(0, gz[5], 0);
            },
        }
    }
    overlay(&d);
}

var fo_na: u32 = 0;
var fo_nl: u32 = 0;
var fo_max: f32 = 0;
const FO_NX = 9;
const FO_NY = 5;
var fo_acc: [FO_NX * FO_NY * FO_NX][3]f32 = undefined;

/// fo_pull: the fields' pull at p (no gravity), its size.
fn pull(p: [3]f32) struct { a: [3]f32, s: f32 } {
    const a = accel(p, null, 1, false);
    return .{ .a = a, .s = @sqrt(dot3(a, a)) };
}

/// fl_overlay: the fields' pull as arrows on a grid round them, or as
/// streamlines from the selected objects.
fn overlay(d: anytype) void {
    fo_na = 0;
    fo_nl = 0;
    fo_max = 0;
    if (!show_arrows and !show_lines) return;
    prep(time(), .{ 0, 0, 0 });
    if (n == 0) return;
    d.f = .{ .col = 0x4fb0e0 };
    if (show_arrows) arrows: {
        // the grid: round the fields (their centres, their reach up to 10 m)
        var lo = [3]f32{ 1e30, 1e30, 1e30 };
        var hi = [3]f32{ -1e30, -1e30, -1e30 };
        for (tab[0..n]) |*f| {
            const r = minss(f.rad, 10.0);
            for (0..3) |a| {
                lo[a] = minss(lo[a], f.c[a] - r);
                hi[a] = maxss(hi[a], f.c[a] + r);
            }
        }
        var cen: [3]f32 = undefined;
        var h: [3]f32 = undefined;
        const minh = [3]f32{ 4, 2, 4 };
        const maxh = [3]f32{ 60, 30, 60 };
        for (0..3) |a| {
            cen[a] = (lo[a] + hi[a]) * 0.5;
            h[a] = minss(maxss((hi[a] - lo[a]) * 0.5 + 3.0, minh[a]), maxh[a]);
        }
        const nm1 = [3]f32{ 8, 4, 8 };
        var cm = minss(h[0], h[2]);
        cm = cm + cm;
        const cell = cm / 8.0 * 0.85;
        const point = struct {
            fn f(ix: usize, iy: usize, iz: usize, c0: [3]f32, h0: [3]f32, nn: [3]f32) [3]f32 {
                const ii = [3]f32{ @floatFromInt(ix), @floatFromInt(iy), @floatFromInt(iz) };
                var p: [3]f32 = undefined;
                for (0..3) |a| p[a] = (ii[a] * 2.0 / nn[a] - 1.0) * h0[a] + c0[a];
                return p;
            }
        }.f;
        var k: usize = 0;
        for (0..FO_NX) |ix| {
            for (0..FO_NY) |iy| {
                for (0..FO_NX) |iz| {
                    const pl = pull(point(ix, iy, iz, cen, h, nm1));
                    fo_acc[k] = pl.a;
                    fo_max = maxss(pl.s, fo_max);
                    k += 1;
                }
            }
        }
        if (!(fo_max > 1.0e-5)) break :arrows;
        k = 0;
        for (0..FO_NX) |ix| {
            for (0..FO_NY) |iy| {
                for (0..FO_NX) |iz| {
                    defer k += 1;
                    const a = fo_acc[k];
                    const s = @sqrt(dot3(a, a));
                    if (!(s > fo_max * 0.001)) continue;
                    const len = @sqrt(s / fo_max) * cell / s;
                    const p = point(ix, iy, iz, cen, h, nm1);
                    d.arrow(p, add3(p, mul3(a, len)));
                    fo_na += 1;
                }
            }
        }
    }
    if (!show_lines) return;
    // streamlines from the selected objects: two rings of 8 seeds round each
    const sc = @import("animexpr.zig").sincos32;
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.selected or !o.visible) continue;
        const wt = if (o.parent == null) m.TRS{ .loc = o.loc, .rot = o.rot, .scl = o.scl } else scene.worldTRS(oi);
        const r = maxss(wt.scl[0], 1.0) * 0.8;
        for (0..16) |k| {
            const s = sc(@as(f32, @floatFromInt(k & 7)) * 6.28318531 * 0.125);
            var y = r * 0.3;
            if (k >= 8) y = -y;
            var p = [3]f32{ s[0] * r + wt.loc[0], y + wt.loc[1], s[1] * r + wt.loc[2] };
            for (0..80) |_| {
                const a = pull(p);
                if (!(a.s > 1.0e-5)) break;
                const mid = add3(mul3(div3(a.a, a.s), 0.125), p);
                const b = pull(mid);
                if (!(b.s > 1.0e-5)) break;
                const q = add3(mul3(div3(b.a, b.s), 0.25), p);
                d.seg(p, q);
                fo_nl += 1;
                p = q;
            }
        }
    }
}

// --- tests ------------------------------------------------------------------------------

/// --dump-force OUT;x,y,z;[rep:N;]x,y,z...: what force(x, y, z) gives at each point (the
/// fields now and the world's gravity, on a still thing of group 0), a line of
/// three floats in hex each, then "info" fieldinfo(0..3).
pub fn dumpForce(spec: []const u8) void {
    const linux = std.os.linux;
    var it = std.mem.splitScalar(u8, spec, ';');
    var pb: [512]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&pb, "{s}", .{it.next() orelse return}, 0) catch return;
    const rc = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var b: [160]u8 = undefined;
    var rep: u32 = 1;
    while (it.next()) |pt| {
        if (std.mem.startsWith(u8, pt, "rep:")) {
            // rep:N - the next point N times, x 0.001 further each time (timing)
            rep = std.fmt.parseInt(u32, pt[4..], 10) catch 1;
            continue;
        }
        var c = std.mem.splitScalar(u8, pt, ',');
        var p: [3]f32 = undefined;
        for (&p) |*x| x.* = std.fmt.parseFloat(f32, c.next() orelse "0") catch 0;
        var a = sample(p);
        var k: u32 = 1;
        while (k < rep) : (k += 1) a = sample(.{ p[0] + @as(f32, @floatFromInt(k)) * 0.001, p[1], p[2] });
        rep = 1;
        const s = std.fmt.bufPrint(&b, "{x} {x} {x}\n", .{ a[0], a[1], a[2] }) catch continue;
        _ = linux.write(fd, s.ptr, s.len);
    }
    const s = std.fmt.bufPrint(&b, "info {d} {d} {d} {x}\n", .{ info(0), info(1), info(2), info(3) }) catch return;
    _ = linux.write(fd, s.ptr, s.len);
}

test "a record's defaults are fl_set_type's" {
    var r = Rec{ .uid = 7 };
    setType(&r, WIND);
    try std.testing.expectEqual(@as(f32, 5), r.str);
    try std.testing.expectEqual(@as(f32, 0.3), r.gust);
    try std.testing.expectEqual(@as(f32, 2), r.scale);
    try std.testing.expectEqual(@as(f32, 0.1), r.soft);
    setType(&r, 9);
    try std.testing.expectEqual(@as(u32, 0), r.typ);
    try std.testing.expectEqual(@as(u32, 7), r.uid);
}

test "parse: groups, types, a word it does not know" {
    var r = Rec{ .uid = 1 };
    setType(&r, ATTR);
    try std.testing.expect(parse(&r, "strength 20 falloff smooth groups 0,3 off seed 7.9"));
    try std.testing.expectEqual(@as(f32, 20), r.str);
    try std.testing.expectEqual(@as(u32, 2), r.fall);
    try std.testing.expectEqual(@as(u32, 0xfff6), r.skip);
    try std.testing.expectEqual(@as(u32, 1), r.flags);
    try std.testing.expectEqual(@as(i32, 7), r.seed);
    try std.testing.expect(parse(&r, "type planet"));
    try std.testing.expectEqual(@as(u32, 0), r.typ);
    try std.testing.expectEqual(@as(f32, 10), r.str);
}

test "sc_mix" {
    try std.testing.expectEqual(@as(u64, 0x9E3779B97F4A7C15), scMix(0, &[_]u8{1}));
}
