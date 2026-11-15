// Animation (anim.s, rig.s drivers): keys, F-curves, channels, actions, layers,
// drivers, the frame the scene shows, playback and the ANIM chunk.
//
// A channel names one number (kind, a, b, c); its curve is a run of keys
// (frame, value, Bezier handles, interpolation). All curves live in one
// reference-counted block shared with undo steps and copied on change, as in
// the original: a step holds the block it saw, so undo is a pointer back.
//
// In memory a channel's `a` is an object's oid (the port's session identity);
// the file has the objects' persistent uids (scene.Object.uid), so read and write
// translate every object reference in the block, whatever record it is in. A
// reference to an object no longer here (deleted, or one the file names but
// does not have) keeps its uid, as the original's does: scene.uidOfOid knows
// the uid a deleted object had, and a file's unknown uid gets an oid of its own
// (scene.foreignOid).
//
// Setting a frame writes every curve's value into its property. That is not
// an edit: an evaluation pass (apply, frameBegin, rigEval) keeps the undo snapshot
// in step, unless an edit is under way (undo.zig). Rotations are radians in channels (the port's objects: degrees), and a
// child's channels are its world values, as OB_LOC is in the original.
//
// For the rig (armatures and constraints come after this file): bone channels
// go through `bone_chan`, bone paths through `bone_path`, `an_bone_key` is
// keyBone, `arm_refresh` and constraints hang on `after_drivers`, and the
// records (Constraint, the rest of the block) are here and round trip.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const frange = @import("frange.zig");
const app = @import("app.zig");
const mods = @import("mods.zig");
const shape = @import("shape.zig");
const axpr = @import("animexpr.zig");
const undo = @import("undo.zig");
const A = @import("alloc.zig").A;

pub const K_OBJ = 1;
pub const K_MAT = 2;
pub const K_MOD = 3;
pub const K_NODE = 4;
pub const K_BONE = 5;
pub const K_SHAPE = 6;
pub const K_PARAM = 7;
pub const K_FIELD = 8;
pub const K_TEXT = 9;

pub const MAXC = 1024;
pub const MAXA = 32;
pub const MAXL = 32;
pub const MAXCON = 64;
pub const MAXDRV = 32;
pub const MAXRB = 4096;
pub const MAXRB_V1 = 1024;
pub const MAXJT = 16384;
pub const MAXJT_V2 = 128;
pub const RB_SZ = 80;
pub const JT_SZ = 64;
/// AN_KEYS - AN_MJ: mechanism joints, the cloth world, cloth objects
pub const REST = 15392;
const REST_NMJ_MAX = 64;
const MJ_SZ = 208;
const REST_CW_N = 13312 + 20;
const REST_CL = 13344;
const CL_SZ = 64;
const CL_MAX = 32;
const V2: u32 = 0x40000000;
const V3: u32 = 0x20000000;

pub const Curve = extern struct { kind: u32, a: u32, b: u32, c: u32, first: u32, n: u32, act: u32, pad: u32 = 0 };
pub const Key = extern struct {
    f: f32,
    v: f32,
    hlx: f32 = 0,
    hly: f32 = 0,
    hrx: f32 = 0,
    hry: f32 = 0,
    int: u8 = 0, // 0 constant, 1 linear, 2 Bezier
    ht: u8 = 0, // 0 auto-clamped, 1 free
    sel: u8 = 0,
    pad: [5]u8 = @splat(0),
};
pub const Action = extern struct { name: [32]u8, start: f32, end: f32, pad: [2]u32 = .{ 0, 0 } };
pub const Layer = extern struct { act: u32, target: u32, start: f32, infl: f32, mode: u32, repeat: f32, mute: u32, pad: u32 = 0 };
pub const Var = extern struct { name: [8]u8, kind: u32, a: u32, b: u32, c: u32 };
pub const Driver = extern struct { kind: u32, a: u32, b: u32, c: u32, nv: u32, mute: u32, vars: [4]Var, expr: [136]u8 };
pub const Constraint = extern struct {
    owner: u32,
    bone: u32,
    ctype: u32,
    target: u32,
    pole: u32,
    axes: u32,
    track: u32,
    up: u32,
    infl: f32,
    chain: u32,
    iter: u32,
    flags: u32,
    min: [3]f32,
    max: [3]f32,
    base: [9]f32,
    last: [9]f32,
    inv: [12]f32,
};

/// The block's start as in memory and in the file: AN_REFS .. AN_RB.
pub const Head = extern struct {
    refs: u32,
    ncur: u32,
    nkey: u32,
    capk: u32,
    bytes: u64,
    start: i32,
    end: i32,
    fps: f32,
    nact: u32,
    nlay: u32,
    ncon: u32,
    ndrv: u32,
    nrb: u32,
    njt: u32,
    nmj: u32,
    cur: [MAXC]Curve,
    act: [MAXA]Action,
    lay: [MAXL]Layer,
    con: [MAXCON]Constraint,
    drv: [MAXDRV]Driver,
    rw: [32]u8,
};

comptime {
    std.debug.assert(@sizeOf(Curve) == 32 and @sizeOf(Key) == 32);
    std.debug.assert(@sizeOf(Action) == 48 and @sizeOf(Layer) == 32);
    std.debug.assert(@sizeOf(Driver) == 256 and @sizeOf(Constraint) == 192);
    std.debug.assert(@offsetOf(Head, "cur") == 64 and @offsetOf(Head, "con") == 35392);
    std.debug.assert(@sizeOf(Head) == 55904);
    std.debug.assert(@offsetOf(Driver, "expr") == 120);
}

const AN_KEYS: usize = 1447552;

pub const Block = struct {
    h: Head,
    rb: []u8 = &.{}, // the bodies in use
    jt: []u8 = &.{}, // the joints in use
    rest: [REST]u8 = @splat(0),
    keys: []Key = &.{}, // capacity h.capk

    pub fn curves(b: *Block) []Curve {
        return b.h.cur[0..b.h.ncur];
    }
    pub fn keysOf(b: *Block, c: *const Curve) []Key {
        return b.keys[c.first..][0..c.n];
    }
    pub fn actions(b: *Block) []Action {
        return b.h.act[0..b.h.nact];
    }
    pub fn layers(b: *Block) []Layer {
        return b.h.lay[0..b.h.nlay];
    }
    pub fn drivers(b: *Block) []Driver {
        return b.h.drv[0..b.h.ndrv];
    }
};

/// The curves (null: none yet).
pub var cur: ?*Block = null;
/// The frame the scene shows.
pub var frame: f32 = 1;
pub var playing: bool = false;
var t0: i64 = 0;
var f0: i32 = 0;
pub var autokey: bool = false;

/// bone:Rig:Bone:rz, when armatures exist: (armature oid, bone, property, value, set) -> value.
pub var bone_chan: ?*const fn (a: u32, b: u32, c: u32, v: f32, set: bool) ?f32 = null;
/// (armature object's name, bone's name) -> (its oid, the bone).
pub var bone_path: ?*const fn (obj: []const u8, bone: []const u8) ?[2]u32 = null;
/// After the drivers, in every evaluation: constraints, IK, armatures posed.
pub var after_drivers: ?*const fn () void = null;
/// A new scene: what the rig keeps goes.
pub var on_reset: ?*const fn () void = null;
/// A copy of the block going into a file, before its references become uids.
pub var before_write: ?*const fn (h: *Head) void = null;

fn pages(cap: u32) u64 {
    return (@as(u64, cap) * @sizeOf(Key) + AN_KEYS + 4095) & ~@as(u64, 4095);
}

fn new(cap0: u32) ?*Block {
    const cap = @max(cap0, 256);
    const b = A.create(Block) catch return null;
    b.* = .{ .h = std.mem.zeroes(Head) };
    b.keys = A.alloc(Key, cap) catch {
        A.destroy(b);
        return null;
    };
    b.h.refs = 1;
    b.h.capk = cap;
    b.h.bytes = pages(cap);
    b.h.start = 1;
    b.h.end = 250;
    b.h.fps = 24;
    return b;
}

fn free(b: *Block) void {
    if (b.rb.len > 0) A.free(b.rb);
    if (b.jt.len > 0) A.free(b.jt);
    A.free(b.keys);
    A.destroy(b);
}

pub fn ref(b: ?*Block) void {
    if (b) |x| x.h.refs += 1;
}
pub fn unref(b: ?*Block) void {
    const x = b orelse return;
    x.h.refs -= 1;
    if (x.h.refs == 0) free(x);
}

/// Undo: a step keeps the block it saw.
pub fn keep(slot: *?*Block) void {
    if (slot.* == cur) return;
    ref(cur);
    unref(slot.*);
    slot.* = cur;
}
pub fn restore(b: ?*Block) void {
    if (b == cur) return;
    ref(b);
    unref(cur);
    cur = b;
}

/// A new scene: no animation.
pub fn reset() void {
    unref(cur);
    cur = null;
    frame = 1;
    playing = false;
    if (on_reset) |f| f();
    @import("motion.zig").reset();
}

/// The block, ready to change, with room for `room` more keys (made, or
/// copied when an undo step shares it or it is full).
pub fn own(room: u32) ?*Block {
    const b = cur orelse {
        cur = new(room + 256);
        return cur;
    };
    if (b.h.refs == 1 and b.h.nkey + room <= b.h.capk) return b;
    const c = new((b.h.nkey + room) *| 2) orelse return null;
    const cap = c.h.capk;
    const bytes = c.h.bytes;
    c.h = b.h;
    c.h.refs = 1;
    c.h.capk = cap;
    c.h.bytes = bytes;
    c.rest = b.rest;
    if (b.rb.len > 0) c.rb = A.dupe(u8, b.rb) catch {
        free(c);
        return null;
    };
    if (b.jt.len > 0) c.jt = A.dupe(u8, b.jt) catch {
        free(c);
        return null;
    };
    @memcpy(c.keys[0..b.h.nkey], b.keys[0..b.h.nkey]);
    unref(b);
    cur = c;
    return c;
}

// --- curves --------------------------------------------------------------------------

pub const Chan = struct { kind: u32, a: u32 = 0, b: u32 = 0, c: u32 = 0 };

/// What a written key carries besides its frame, value and interpolation.
pub const Extras = struct { sel: bool = false, ht: u8 = 0, h: [4]f32 = @splat(0) };

pub fn find(ch: Chan, act: u32) ?usize {
    const b = cur orelse return null;
    for (b.curves(), 0..) |*c, i| {
        if (c.kind == ch.kind and c.a == ch.a and c.b == ch.b and c.c == ch.c and c.act == act) return i;
    }
    return null;
}

fn sameFrame(a: f32, b: f32) bool {
    return @abs(a - b) < 1.0e-4;
}

fn extras(k: *Key, x: Extras) void {
    k.sel = @intFromBool(x.sel);
    k.ht = x.ht;
    if (x.ht != 0) {
        k.hlx = x.h[0];
        k.hly = x.h[1];
        k.hrx = x.h[2];
        k.hry = x.h[3];
    }
}

/// A key on a channel (a key on that frame is replaced): the curve's key
/// count, or null when there is no room.
pub fn key(ch: Chan, act: u32, f: f32, v: f32, int: u8, x: Extras) ?u32 {
    const b = own(1) orelse return null;
    const ci = find(ch, act) orelse blk: {
        if (b.h.ncur >= MAXC) return null;
        b.h.cur[b.h.ncur] = .{ .kind = ch.kind, .a = ch.a, .b = ch.b, .c = ch.c, .first = b.h.nkey, .n = 0, .act = act };
        b.h.ncur += 1;
        break :blk b.h.ncur - 1;
    };
    const c = &b.h.cur[ci];
    var place: u32 = 0;
    while (place < c.n) : (place += 1) {
        const k = &b.keys[c.first + place];
        if (sameFrame(k.f, f)) {
            k.v = v;
            k.int = int;
            extras(k, x);
            handles(b, ci);
            return c.n;
        }
        if (k.f > f) break;
    }
    const at = c.first + place;
    std.mem.copyBackwards(Key, b.keys[at + 1 .. b.h.nkey + 1], b.keys[at..b.h.nkey]);
    b.keys[at] = .{ .f = f, .v = v, .int = int };
    extras(&b.keys[at], x);
    b.h.nkey += 1;
    c.n += 1;
    for (b.h.cur[ci + 1..b.h.ncur]) |*l| l.first += 1;
    handles(b, ci);
    return c.n;
}

fn removeKey(b: *Block, ci: usize, at: u32) void {
    const c = &b.h.cur[ci];
    std.mem.copyForwards(Key, b.keys[at .. b.h.nkey - 1], b.keys[at + 1 .. b.h.nkey]);
    b.h.nkey -= 1;
    c.n -= 1;
    for (b.h.cur[ci + 1..b.h.ncur]) |*l| l.first -= 1;
}

fn removeCurve(b: *Block, ci: usize) void {
    std.mem.copyForwards(Curve, b.h.cur[ci .. b.h.ncur - 1], b.h.cur[ci + 1 .. b.h.ncur]);
    b.h.ncur -= 1;
}

/// That key goes (a curve left without keys too). True when one went.
pub fn unkey(ch: Chan, act: u32, f: f32) bool {
    const ci = find(ch, act) orelse return false;
    const b0 = cur.?;
    for (b0.keysOf(&b0.h.cur[ci]), 0..) |*k, p| {
        if (!sameFrame(k.f, f)) continue;
        // (only now: a block copied for nothing would be a step of nothing)
        const b = own(0) orelse return false;
        const c = &b.h.cur[ci];
        removeKey(b, ci, c.first + @as(u32, @intCast(p)));
        if (c.n == 0) removeCurve(b, ci) else handles(b, ci);
        return true;
    }
    return false;
}

/// Auto-clamped handles: a third of the way to each neighbour along the slope
/// between them, flat at extremes and at the ends.
pub fn handles(b: *Block, ci: usize) void {
    const c = &b.h.cur[ci];
    const ks = b.keysOf(c);
    for (ks, 0..) |*k, i| {
        if (k.ht != 0) continue;
        var slope: f32 = 0;
        const f = k.f;
        const v = k.v;
        const fl = if (i > 0) ks[i - 1].f else f;
        const vl = if (i > 0) ks[i - 1].v else v;
        const fr = if (i + 1 < ks.len) ks[i + 1].f else f;
        const vr = if (i + 1 < ks.len) ks[i + 1].v else v;
        if (i > 0 and i + 1 < ks.len and (v - vl) * (vr - v) > 0) {
            slope = vr - vl;
            const d = fr - fl;
            if (d > 1.0e-4) slope /= d else slope = vr - vl;
        }
        k.hlx = (fl - f) * 0.33333334;
        k.hly = k.hlx * slope;
        k.hrx = (fr - f) * 0.33333334;
        k.hry = k.hrx * slope;
    }
}

pub fn allHandles(b: *Block) void {
    for (0..b.h.ncur) |i| handles(b, i);
    app.dirty = true;
}

const Bz = struct { b: f32, d: f32 };

fn bez1(p: *const [4]f32, t: f32) Bz {
    const u = 1 - t;
    var r = u * u * u * p[0];
    r += u * u * t * 3 * p[1];
    r += u * t * t * 3 * p[2];
    r += t * t * t * p[3];
    var d = (p[1] - p[0]) * u * u * 3;
    d += (p[2] - p[1]) * u * t * 6;
    d += (p[3] - p[2]) * t * t * 3;
    return .{ .b = r, .d = d };
}

/// The value of a run of keys at a frame (before the first key: the first;
/// after the last: the last).
pub fn evalKeys(ks: []const Key, f: f32) f32 {
    if (ks.len == 0) return 0;
    if (ks.len == 1) return ks[0].v;
    if (!(f > ks[0].f)) return ks[0].v; // (comiss / jbe: a NaN frame too)
    const last = &ks[ks.len - 1];
    if (f >= last.f) return last.v;
    // the span: key i < frame <= key i+1
    var lo: usize = 0;
    var hi: usize = ks.len - 2;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (f <= ks[mid + 1].f) hi = mid else lo = mid + 1;
    }
    const p = &ks[lo];
    const q = &ks[lo + 1];
    if (p.int == 0) return p.v;
    const u = (f - p.f) / (q.f - p.f);
    if (p.int == 1) return (q.v - p.v) * u + p.v;
    // Bezier: x(t) = f by Newton from t = u, then y(t)
    const xs = [4]f32{ p.f, p.f + p.hrx, q.f + q.hlx, q.f };
    const ys = [4]f32{ p.v, p.v + p.hry, q.v + q.hly, q.v };
    var t = u;
    var i: u32 = 8;
    while (i > 0) : (i -= 1) {
        const x = bez1(&xs, t);
        if (!(x.d > 1.0e-4)) break;
        t -= (x.b - f) / x.d;
        t = if (t > 0) t else 0;
        t = if (t < 1) t else 1;
    }
    return bez1(&ys, t).b;
}

pub fn evalCurve(b: *Block, ci: usize, f: f32) f32 {
    return evalKeys(b.keysOf(&b.h.cur[ci]), f);
}

// --- channels ------------------------------------------------------------------------

/// A curve's last-seen object index: looking oids up is a scan of the scene.
var hints: [MAXC + MAXDRV * 5 + MAXL]u32 = @splat(0);
const H_DRV = MAXC;
const H_LAY = MAXC + MAXDRV * 5;

fn objectOf(oid: u32, hint: usize) ?usize {
    const h = hints[hint];
    if (h < scene.count and scene.objects[h].oid == oid) return h;
    const i = scene.findOid(oid) orelse return null;
    hints[hint] = @intCast(i);
    return i;
}

/// A child's channels are its world values (as OB_LOC in the original): while
/// an evaluation runs they collect here, then its local values follow from
/// where its parent was: the original's child takes the parent's change on
/// top (par_sync, D = M_new M_old^-1).
const Pend = struct { i: u32, w: [9]f32, pold: m.M4, changed: bool = false };
var pend: [MAXC + MAXDRV]Pend = undefined;
var pend_n: usize = 0;
var pend_slot: [scene.max_objects]u16 = @splat(0);

fn worldValues(i: usize) [9]f32 {
    const t = scene.worldTRS(i);
    return .{ t.loc[0], t.loc[1], t.loc[2], t.rot[0] * m.deg, t.rot[1] * m.deg, t.rot[2] * m.deg, t.scl[0], t.scl[1], t.scl[2] };
}

fn pendFor(i: usize) void {
    if (pend_slot[i] != 0 or pend_n >= pend.len) return;
    const par = scene.objects[i].parent orelse return;
    pend[pend_n] = .{ .i = @intCast(i), .w = worldValues(i), .pold = scene.world(par) };
    pend_n += 1;
    pend_slot[i] = @intCast(pend_n);
}

fn flushPend() void {
    const ps = pend[0..pend_n];
    for (ps) |*p| {
        pend_slot[p.i] = 0;
        if (!p.changed) continue;
        const w = p.w;
        const mt = m.trs(.{ w[0], w[1], w[2] }, .{ w[3] / m.deg, w[4] / m.deg, w[5] / m.deg }, .{ w[6], w[7], w[8] });
        const t = m.decompose(m.mul(m.inverseAffine(p.pold), mt));
        var ok = true;
        for ([_]m.V3{ t.loc, t.rot, t.scl }) |v| {
            for (v) |x| {
                if (!std.math.isFinite(x) or @abs(x) > 1e9) ok = false;
            }
        }
        if (!ok) continue;
        const o = &scene.objects[p.i];
        o.loc = t.loc;
        o.rot = t.rot;
        o.scl = t.scl;
        undo.absorb(p.i);
    }
    pend_n = 0;
}

/// Sets the material parameter's value through a parameter node's name hash.
fn pparam(a: u32, code: u32, comp: u32, v: f32, set: bool) ?f32 {
    const ma = material.get(a) orelse return null;
    const gops = @import("graphops.zig");
    if (comp >= 4) return null;
    return gops.paramByCode(ma, code, comp, v, set);
}

fn roundEven(x: f32) f32 {
    const r = @round(x);
    if (@abs(x - @trunc(x)) == 0.5 and @mod(r, 2) != 0) return r - std.math.sign(x);
    return r;
}

/// The property's value now, null when it is not there any more.
pub fn chanGet(ch: Chan, hint: usize) ?f32 {
    switch (ch.kind) {
        K_OBJ => {
            if (ch.c >= 9) return null;
            const i = objectOf(ch.a, hint) orelse return null;
            if (scene.objects[i].parent != null) {
                if (pend_slot[i] != 0) return pend[pend_slot[i] - 1].w[ch.c];
                return worldValues(i)[ch.c];
            }
            const o = &scene.objects[i];
            return switch (ch.c) {
                0...2 => o.loc[ch.c],
                3...5 => o.rot[ch.c - 3] * m.deg,
                else => o.scl[ch.c - 6],
            };
        },
        K_MAT => {
            if (ch.b >= 0x10000) return pparam(ch.a, ch.b, ch.c, 0, false);
            const ma = material.get(ch.a) orelse return null;
            if (ch.b >= material.params.len or ch.c >= material.params[ch.b].comps) return null;
            return material.ptr(ma, ch.b, ch.c).*;
        },
        K_MOD => {
            const i = objectOf(ch.a, hint) orelse return null;
            const o = &scene.objects[i];
            if (ch.b >= o.mods.n or ch.c >= 8) return null;
            return mods.getF(&o.mods.m[ch.b], ch.c);
        },
        K_SHAPE => {
            const i = objectOf(ch.a, hint) orelse return null;
            return shape.chanGet(i, ch.b);
        },
        K_BONE => {
            const f = bone_chan orelse return null;
            return f(ch.a, ch.b, ch.c, 0, false);
        },
        K_PARAM => return @import("mech.zig").paramChan(ch.a, 0, false),
        K_FIELD => return @import("fields.zig").chan(ch.a, 0, false),
        K_TEXT => return @import("text3d.zig").chan(ch.a, ch.b, false, 0),
        else => return null, // (node trees: not ported)
    }
}

/// Sets it (as an evaluation does: no undo step). False: it is not there.
pub fn chanSet(ch: Chan, hint: usize, v: f32) bool {
    if (!std.math.isFinite(v)) return false; // (a damaged file)
    undo.evalWrite();
    switch (ch.kind) {
        K_OBJ => {
            if (ch.c >= 9) return false;
            const i = objectOf(ch.a, hint) orelse return false;
            const o = &scene.objects[i];
            if (o.parent != null) {
                pendFor(i);
                if (pend_slot[i] == 0) return false;
                const p = &pend[pend_slot[i] - 1];
                if (p.w[ch.c] != v) {
                    p.w[ch.c] = v;
                    p.changed = true;
                }
                return true;
            }
            if (ch.c >= 3 and ch.c <= 5) {
                // a turn: the curve's radians as they are (the original's
                // OB_ROT), the degrees shown made from them - not radians made
                // again from those degrees, a bit apart now and then
                var r = o.radians();
                const k = ch.c - 3;
                if (@as(u32, @bitCast(r[k])) != @as(u32, @bitCast(v)) or o.rot[k] != v / m.deg) {
                    r[k] = v;
                    o.rot[k] = v / m.deg;
                    o.rad = r;
                    o.rad_deg = o.rot;
                    undo.absorb(i);
                    app.dirty = true;
                }
                return true;
            }
            const f: *f32 = switch (ch.c) {
                0...2 => &o.loc[ch.c],
                3...5 => &o.rot[ch.c - 3],
                else => &o.scl[ch.c - 6],
            };
            const nv = if (ch.c >= 3 and ch.c <= 5) v / m.deg else v;
            if (f.* != nv) {
                f.* = nv;
                undo.absorb(i);
                app.dirty = true;
            }
            return true;
        },
        K_MAT => {
            if (ch.b >= 0x10000) {
                const was = pparam(ch.a, ch.b, ch.c, 0, false) orelse return false;
                if (was != v) {
                    _ = pparam(ch.a, ch.b, ch.c, v, true);
                    material.version +%= 1;
                    undo.absorbMat(ch.a);
                }
                return true;
            }
            const ma = material.get(ch.a) orelse return false;
            if (ch.b >= material.params.len or ch.c >= material.params[ch.b].comps) return false;
            const p = material.params[ch.b];
            const nv = std.math.clamp(v, p.lo, p.hi);
            if (material.ptr(ma, ch.b, ch.c).* != nv) {
                _ = material.set(ch.a, ch.b, ch.c, nv);
                undo.absorbMat(ch.a);
                app.dirty = true;
            }
            return true;
        },
        K_MOD => {
            const i = objectOf(ch.a, hint) orelse return false;
            const o = &scene.objects[i];
            if (ch.b >= o.mods.n) return false;
            const d = &o.mods.m[ch.b];
            const ps = mods.params(d.kind);
            if (ch.c < ps.len and !ps[ch.c].object) {
                const p = ps[ch.c];
                var nv = @min(@max(v, p.lo), p.hi);
                if (p.int) nv = roundEven(nv);
                if (mods.getF(d, ch.c) != nv) {
                    mods.setF(d, ch.c, nv);
                    undo.absorb(i);
                    app.dirty = true;
                }
            }
            return ch.c < 8;
        },
        K_SHAPE => {
            const i = objectOf(ch.a, hint) orelse return false;
            return shape.chanSet(i, ch.b, v);
        },
        K_BONE => {
            const f = bone_chan orelse return false;
            return f(ch.a, ch.b, ch.c, v, true) != null;
        },
        K_PARAM => return @import("mech.zig").paramChan(ch.a, v, true) != null,
        K_FIELD => return @import("fields.zig").chan(ch.a, v, true) != null,
        K_TEXT => return @import("text3d.zig").chan(ch.a, ch.b, true, v) != null,
        else => return false,
    }
}

// --- evaluation ----------------------------------------------------------------------

fn curveChan(c: *const Curve) Chan {
    return .{ .kind = c.kind, .a = c.a, .b = c.b, .c = c.c };
}

/// Parented objects first see where their parents are (nothing moved yet).
fn prepass(b: *Block) void {
    for (b.curves(), 0..) |*c, ci| {
        if (c.kind != K_OBJ) continue;
        if (objectOf(c.a, ci)) |i| pendFor(i);
    }
    for (b.layers()) |*l| {
        if (l.target == 0) continue;
        if (scene.findOid(l.target)) |i| pendFor(i);
    }
    for (b.drivers()) |*d| {
        if (d.kind != K_OBJ) continue;
        if (scene.findOid(d.a)) |i| pendFor(i);
    }
}

fn layersEval(b: *Block) void {
    for (b.layers(), 0..) |*l, li| {
        if (l.mute != 0) continue;
        if (l.act == 0 or l.act > b.h.nact) continue;
        const ac = &b.h.act[l.act - 1];
        var t = frame - l.start;
        if (t < 0) continue; // (not started)
        var len = ac.end - ac.start; // past its repeats: its last pose held
        len = if (len > 1) len else 1;
        if (!(t <= len * l.repeat)) {
            t = ac.end;
        } else {
            t /= len;
            t = (t - @floor(t)) * len + ac.start;
        }
        for (b.curves(), 0..) |*c, ci| {
            if (c.act != l.act) continue;
            var ch = curveChan(c);
            if (l.target != 0 and (c.kind == K_OBJ or c.kind == K_MOD)) ch.a = l.target;
            const av = evalCurve(b, ci, t);
            const hint = if (l.target != 0) H_LAY + li else ci;
            const now = chanGet(ch, hint) orelse continue;
            const d = (if (l.mode == 0) av - now else av) * l.infl;
            _ = chanSet(ch, hint, now + d);
        }
    }
}

var dr_cur: *const Driver = undefined;
var dr_ix: usize = 0;

fn drName(name: []const u8) ?f64 {
    if (name.len > 8) return null;
    if (std.mem.eql(u8, name, "frame")) return frame;
    for (dr_cur.vars[0..@min(dr_cur.nv, 4)], 0..) |*v, k| {
        if (!std.mem.eql(u8, std.mem.sliceTo(&v.name, 0), name)) continue;
        return if (chanGet(.{ .kind = v.kind, .a = v.a, .b = v.b, .c = v.c }, H_DRV + dr_ix * 5 + k + 1)) |x| x else null;
    }
    return null;
}

/// The driver's expression's value, null: it does not evaluate.
pub fn driverValue(d: *const Driver, ix: usize) ?f32 {
    dr_cur = d;
    dr_ix = ix;
    const v = axpr.eval(std.mem.sliceTo(&d.expr, 0), drName) orelse return null;
    return @floatCast(v);
}

fn driversEval(b: *Block) void {
    for (b.drivers(), 0..) |*d, ix| {
        if (d.mute != 0) continue;
        const v = driverValue(d, ix) orelse continue;
        const ch = Chan{ .kind = d.kind, .a = d.a, .b = d.b, .c = d.c };
        const hint = H_DRV + ix * 5;
        const now = chanGet(ch, hint) orelse continue;
        if (now != v) {
            _ = chanSet(ch, hint, v);
            app.dirty = true;
        }
    }
}

/// Every curve's value at this frame into its property.
pub fn apply(f: f32) void {
    frame = f;
    app.dirty = true;
    const b = cur orelse {
        @import("rbody.zig").frame(f); // (no bodies: nothing cached)
        @import("cloth.zig").frame(f);
        @import("particles.zig").frame(f);
        undo.evalBegin(); // (texts counting frames: tx_frame)
        defer undo.evalEnd();
        return @import("text3d.zig").frame();
    };
    undo.evalBegin();
    defer undo.evalEnd();
    prepass(b);
    for (b.curves(), 0..) |*c, ci| {
        if (c.act != 0) continue;
        _ = chanSet(curveChan(c), ci, evalCurve(b, ci, f));
    }
    layersEval(b);
    driversEval(b);
    @import("rbody.zig").frame(f); // rigid bodies (rbody.zig), before rig_eval
    @import("cloth.zig").frame(f); // cloth (cloth.zig)
    @import("particles.zig").frame(f); // particles (particles.zig)
    @import("mech.zig").eval(); // (rig_eval: the mechanism after the drivers)
    if (after_drivers) |h| h();
    flushPend();
    @import("text3d.zig").frame(); // texts keyed or counting (tx_frame)
}

/// Once a drawn frame: drivers and what follows them (rig_tick); nothing
/// without them. Motion: the onion skins.
pub fn frameBegin() void {
    undo.evalBegin();
    if (cur) |b| {
        if (b.h.ndrv != 0 or b.h.nmj != 0 or after_drivers != null) {
            for (b.drivers()) |*d| {
                if (d.kind != K_OBJ) continue;
                if (scene.findOid(d.a)) |i| pendFor(i);
            }
            driversEval(b);
            @import("mech.zig").eval();
            if (after_drivers) |h| h();
            flushPend();
        }
    } else if (after_drivers) |h| h(); // (the last constraint went: bones lose their IK)
    undo.evalEnd();
    @import("motion.zig").frameBegin();
}

/// After an operator: what it changed, rigged (rig_eval; onion skins wait for the frame).
pub fn rigEval() void {
    if (after_drivers == null and (cur == null or cur.?.h.nmj == 0)) return;
    undo.evalBegin();
    defer undo.evalEnd();
    const b = cur orelse return after_drivers.?();
    for (b.drivers()) |*d| {
        if (d.kind != K_OBJ) continue;
        if (scene.findOid(d.a)) |i| pendFor(i);
    }
    driversEval(b);
    @import("mech.zig").eval(); // (mechanisms: rig_eval)
    if (after_drivers) |h| h();
    flushPend();
}

/// Playback: the frame the clock says, looping over the range. The ms until
/// the next one, null when not playing.
pub fn tick() ?i32 {
    if (!playing) return null;
    const ms = app.now_ms - t0;
    const fps = frange.r.fps;
    const start = frange.r.start;
    const span: i64 = @max(@as(i64, frange.r.end) - start + 1, 1);
    const gone: f32 = @as(f32, @floatFromInt(ms)) * fps / 1000;
    const whole: i64 = if (gone < 1e12) @intFromFloat(gone) else 0;
    const at = @mod(whole + f0 - start, span) + start;
    const nf: f32 = @floatFromInt(at);
    if (nf != frame) apply(nf);
    const left = (@as(f32, @floatFromInt(whole + 1)) * 1000 / fps) - @as(f32, @floatFromInt(ms));
    return @intFromFloat(std.math.clamp(@ceil(left), 1, 1000));
}

pub fn play() void {
    playing = !playing;
    if (!playing) return @import("live.zig").playbackEnded();
    t0 = app.now_ms;
    var c: i32 = if (@abs(frame) < 1e9) @intFromFloat(frame) else frange.r.start;
    if (c < frange.r.start) c = frange.r.start;
    if (c > frange.r.end) c = frange.r.start;
    f0 = c;
    app.dirty = true;
}

/// Something moves this object over time (an_moves).
pub fn moves(oid: u32) bool {
    const b = cur orelse return false;
    for (b.curves()) |*c| {
        if (c.kind == K_OBJ and c.a == oid) return true;
    }
    for (b.layers()) |*l| {
        if (l.target == oid) return true;
    }
    for (b.h.con[0..b.h.ncon]) |*c| {
        if (c.owner == oid) return true;
    }
    for (b.drivers()) |*d| {
        if (d.kind == K_OBJ and d.a == oid) return true;
    }
    for (0..@min(b.h.nmj, REST_NMJ_MAX)) |k| {
        if (rd(b.rest[k * MJ_SZ ..], 8) == oid) return true; // (a mechanism's part)
    }
    return false;
}

// --- paths ---------------------------------------------------------------------------

pub const obj_props = [9][]const u8{ "x", "y", "z", "rx", "ry", "rz", "sx", "sy", "sz" };

fn exactObject(nm: []const u8) ?usize {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (std.mem.eql(u8, o.name(), nm)) return i;
    }
    return null;
}

fn apNum(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v *% 10 +% (c - '0');
    }
    return v;
}

fn apComp(s: ?[]const u8) u32 {
    const w = s orelse return 0;
    const n = apNum(w) orelse return 0;
    return if (n <= 2) n else 0;
}

fn propIndex(s: []const u8) ?u32 {
    for (obj_props, 0..) |p, i| {
        if (std.mem.eql(u8, p, s)) return @intCast(i);
    }
    return null;
}

/// The channel a path names ("Cube:x", "material:Red:roughness[:k]",
/// "modifier:Cube:0:levels", "bone:Rig:Bone:rz", "shape:Cube:Smile").
pub fn parsePath(path: []const u8) ?Chan {
    var it = std.mem.splitScalar(u8, path, ':');
    const w = it.next() orelse return null;
    if (w.len == 0) return null;
    if (std.mem.eql(u8, w, "material")) {
        const mi = material.find(it.next() orelse return null) orelse return null;
        const nm = it.next() orelse return null;
        const code: u32 = if (material.paramIndex(nm)) |p| @intCast(p) else @import("graphops.zig").paramCode(&material.list[mi], nm) orelse return null;
        return .{ .kind = K_MAT, .a = @intCast(mi), .b = code, .c = apComp(it.next()) };
    }
    if (std.mem.eql(u8, w, "modifier")) {
        const i = exactObject(it.next() orelse return null) orelse return null;
        const o = &scene.objects[i];
        const k = apNum(it.next() orelse return null) orelse return null;
        if (k >= o.mods.n) return null;
        const nm = it.next() orelse return null;
        for (mods.params(o.mods.m[k].kind), 0..) |p, q| {
            if (std.mem.eql(u8, p.name, nm)) return .{ .kind = K_MOD, .a = o.oid, .b = k, .c = @intCast(q) };
        }
        return null;
    }
    if (std.mem.eql(u8, w, "bone")) {
        const f = bone_path orelse return null;
        const on = it.next() orelse return null;
        const bn = it.next() orelse return null;
        const r = f(on, bn) orelse return null;
        return .{ .kind = K_BONE, .a = r[0], .b = r[1], .c = propIndex(it.next() orelse return null) orelse return null };
    }
    if (std.mem.eql(u8, w, "shape")) {
        const i = exactObject(it.next() orelse return null) orelse return null;
        const k = shape.find(i, it.next() orelse return null) orelse return null;
        if (k == 0) return null; // (not the basis)
        return .{ .kind = K_SHAPE, .a = scene.objects[i].oid, .b = k };
    }
    if (std.mem.eql(u8, w, "param")) {
        // param:angle (a CAD parameter, mech.zig)
        const nm = it.next() orelse return null;
        if (nm.len == 0) return null;
        const k = @import("cad.zig").paramFind(nm) orelse return null;
        return .{ .kind = K_PARAM, .a = @intCast(k) };
    }
    if (std.mem.eql(u8, w, "field")) {
        // field:Wind:strength (fields.zig)
        const i = exactObject(it.next() orelse return null) orelse return null;
        if (scene.objects[i].kind != .field) return null;
        if (!std.mem.eql(u8, it.next() orelse return null, "strength")) return null;
        return .{ .kind = K_FIELD, .a = scene.objects[i].oid };
    }
    if (std.mem.eql(u8, w, "text")) {
        // text:Title:reveal (text3d.zig)
        const i = exactObject(it.next() orelse return null) orelse return null;
        const tx = @import("text3d.zig");
        if (tx.txOf(i) == null) return null;
        const k = tx.keyIdx(it.next() orelse return null) orelse return null;
        return .{ .kind = K_TEXT, .a = scene.objects[i].oid, .b = k };
    }
    if (std.mem.eql(u8, w, "node")) return null; // (not ported)
    const i = exactObject(w) orelse return null;
    return .{ .kind = K_OBJ, .a = scene.objects[i].oid, .c = propIndex(it.next() orelse return null) orelse return null };
}

/// Keyed at the frame; value null: what it is now. The curve's keys, null when
/// the path names nothing.
pub fn pathKey(path: []const u8, f: f32, value: ?f32, int: u8) ?u32 {
    const ch = parsePath(path) orelse return null;
    const v = value orelse chanGet(ch, hintFree()) orelse return null;
    return key(ch, 0, f, v, int, .{});
}

pub fn hintFree() usize {
    return H_LAY + MAXL - 1;
}

/// A bone's property keyed at the current frame with its value now (an_bone_key).
pub fn keyBone(armature: u32, bone: u32, prop: u32) void {
    const ch = Chan{ .kind = K_BONE, .a = armature, .b = bone, .c = prop };
    const v = chanGet(ch, hintFree()) orelse return;
    _ = key(ch, 0, frame, v, 2, .{});
}

/// What any property is now, by its path (tests, the console).
pub fn pathValue(path: []const u8) ?f32 {
    const ch = parsePath(path) orelse return null;
    return chanGet(ch, hintFree());
}

/// The value its curve gives at a frame.
pub fn pathEval(path: []const u8, f: f32) ?f32 {
    const ch = parsePath(path) orelse return null;
    const ci = find(ch, 0) orelse return null;
    return evalCurve(cur.?, ci, f);
}

/// The object's nine transform channels, as they are, keyed.
pub fn keyObject(i: usize, f: f32) void {
    const oid = scene.objects[i].oid;
    for (0..9) |c| {
        const ch = Chan{ .kind = K_OBJ, .a = oid, .c = @intCast(c) };
        const v = chanGet(ch, hintFree()) orelse continue;
        _ = key(ch, 0, f, v, 2, .{});
    }
}

pub fn unkeyObject(i: usize, f: f32) void {
    const oid = scene.objects[i].oid;
    for (0..9) |c| _ = unkey(.{ .kind = K_OBJ, .a = oid, .c = @intCast(c) }, 0, f);
}

// --- the file ------------------------------------------------------------------------

const UidMap = std.AutoHashMapUnmanaged(u32, u32);

fn toFile(map: *const UidMap, a: u32) u32 {
    if (a == 0) return 0;
    return map.get(a) orelse scene.uidOfOid(a) orelse 0;
}

pub fn isObjectKind(k: u32) bool {
    return k == K_OBJ or k == K_MOD or k == K_BONE or k == K_SHAPE or k == K_FIELD or k == K_TEXT;
}

/// Every object reference of a block's records through f.
fn mapRefs(h: *Head, rb: []u8, jt: []u8, rest: []u8, ctx: anytype, comptime f: anytype) void {
    for (h.cur[0..@min(h.ncur, MAXC)]) |*c| {
        if (isObjectKind(c.kind)) c.a = f(ctx, c.a);
    }
    for (h.lay[0..@min(h.nlay, MAXL)]) |*l| l.target = f(ctx, l.target);
    for (h.con[0..@min(h.ncon, MAXCON)]) |*c| {
        c.owner = f(ctx, c.owner);
        c.target = f(ctx, c.target);
        c.pole = f(ctx, c.pole);
    }
    for (h.drv[0..@min(h.ndrv, MAXDRV)]) |*d| {
        if (isObjectKind(d.kind)) d.a = f(ctx, d.a);
        for (&d.vars) |*v| {
            if (isObjectKind(v.kind)) v.a = f(ctx, v.a);
        }
    }
    var i: usize = 0;
    while (i + RB_SZ <= rb.len) : (i += RB_SZ) {
        const r = rb[i..][0..RB_SZ];
        wr(r, 0, f(ctx, rd(r, 0)));
    }
    i = 0;
    while (i + JT_SZ <= jt.len) : (i += JT_SZ) {
        const r = jt[i..][0..JT_SZ];
        wr(r, 4, f(ctx, rd(r, 4)));
        wr(r, 8, f(ctx, rd(r, 8)));
    }
    for (0..@min(h.nmj, REST_NMJ_MAX)) |k| {
        const r = rest[k * MJ_SZ..][0..MJ_SZ];
        wr(r, 4, f(ctx, rd(r, 4)));
        wr(r, 8, f(ctx, rd(r, 8)));
    }
    for (0..@min(rd(rest, REST_CW_N), CL_MAX)) |k| {
        const r = rest[REST_CL + k * CL_SZ..][0..CL_SZ];
        wr(r, 0, f(ctx, rd(r, 0)));
    }
}

fn wr(c: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, c[o..][0..4], v, .little);
}
fn rd(c: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, c[o..][0..4], .little);
}

/// Worth a chunk? (the original writes one once there is a block)
pub fn wanted() bool {
    return cur != null or !frange.isDefault();
}

pub fn writeChunk(out: anytype) void {
    var map: UidMap = .empty;
    defer map.deinit(A);
    map.ensureTotalCapacity(A, @intCast(scene.count)) catch return;
    for (scene.objects[0..scene.count]) |*o| map.putAssumeCapacity(o.oid, o.uid);
    const hd = A.create(Head) catch return;
    defer A.destroy(hd);
    const rest = A.alloc(u8, REST) catch return;
    defer A.free(rest);
    var rb: []u8 = &.{};
    var jt: []u8 = &.{};
    defer if (rb.len > 0) A.free(rb);
    defer if (jt.len > 0) A.free(jt);
    var keys: []const Key = &.{};
    if (cur) |b| {
        hd.* = b.h;
        @memcpy(rest, &b.rest);
        rb = A.dupe(u8, b.rb) catch return;
        jt = A.dupe(u8, b.jt) catch return;
        keys = b.keys[0..b.h.nkey];
    } else {
        hd.* = std.mem.zeroes(Head);
        @memset(rest, 0);
        // (what a first anim.range would have made)
        hd.capk = 256;
        hd.bytes = pages(256);
    }
    if (before_write) |f| f(hd);
    mapRefs(hd, rb, jt, rest, &map, toFile);
    hd.start = frange.r.start;
    hd.end = frange.r.end;
    hd.fps = frange.r.fps;
    out.u32_(@bitCast(frame));
    out.u32_(hd.nkey | V2 | V3);
    const raw = std.mem.asBytes(hd);
    out.bytes(raw[4..]);
    out.bytes(rb);
    out.bytes(jt);
    out.bytes(rest);
    out.bytes(std.mem.sliceAsBytes(keys));
}

fn fromFile(look: anytype, u: u32) u32 {
    if (u == 0) return 0;
    if (look.get(u)) |i| return scene.objects[i].oid;
    return scene.foreignOid(u);
}

/// The animation back from its chunk (all of it, or nothing of it: a damaged
/// chunk leaves none). False: it was damaged. `look`: uid -> our index.
pub fn readChunk(c: []const u8, look: anytype) bool {
    const HEAD = @sizeOf(Head) - 4;
    if (c.len < 8 + HEAD) return false;
    const vers = rd(c, 4);
    const nkey = vers & ~(V2 | V3);
    if (nkey > 0x1000000) return false;
    const hb = c[8..][0..HEAD];
    const nrb = rd(hb, @offsetOf(Head, "nrb") - 4);
    const njt = rd(hb, @offsetOf(Head, "njt") - 4);
    var o: usize = 8 + HEAD;
    var rb_bytes: usize = undefined;
    var jt_bytes: usize = undefined;
    var jt_room: usize = undefined;
    if (vers & V2 != 0) {
        if (nrb > MAXRB) return false;
        rb_bytes = @as(usize, nrb) * RB_SZ;
        if (vers & V3 != 0) {
            if (njt > MAXJT) return false;
            jt_bytes = @as(usize, njt) * JT_SZ;
            jt_room = jt_bytes;
        } else {
            if (njt > MAXJT_V2) return false;
            jt_bytes = @as(usize, njt) * JT_SZ;
            jt_room = MAXJT_V2 * JT_SZ;
        }
    } else {
        // before v0.17: the old block, room for 1024 bodies and 128 joints
        if (nrb > MAXRB_V1 or njt > MAXJT_V2) return false;
        rb_bytes = @as(usize, nrb) * RB_SZ;
        jt_bytes = @as(usize, njt) * JT_SZ;
        jt_room = jt_bytes; // (the rooms are skipped below)
    }
    const rb_room: usize = if (vers & V2 != 0) rb_bytes else MAXRB_V1 * RB_SZ;
    if (vers & V2 == 0) jt_room = MAXJT_V2 * JT_SZ;
    const need = o + rb_room + jt_room + REST + @as(usize, nkey) * @sizeOf(Key);
    if (need > c.len) return false;

    const b = new(nkey) orelse return false;
    var ok = false;
    defer if (!ok) unref(b);
    const cap = b.h.capk;
    const bytes = b.h.bytes;
    std.mem.asBytes(&b.h)[4..].* = hb.*;
    b.h.refs = 1;
    b.h.capk = cap;
    b.h.bytes = bytes;
    // the counts must fit their records, the curves tile the keys
    const hh = &b.h;
    if (hh.nkey != nkey or hh.ncur > MAXC or hh.nact > MAXA or hh.nlay > MAXL or hh.ncon > MAXCON or hh.ndrv > MAXDRV or hh.nmj > REST_NMJ_MAX) return false;
    var at: u32 = 0;
    for (hh.cur[0..hh.ncur]) |*l| {
        if (l.first != at or l.n > nkey - at) return false;
        at += l.n;
    }
    if (at != nkey) return false;
    for (hh.drv[0..hh.ndrv]) |*d| {
        if (d.nv > 4 or std.mem.indexOfScalar(u8, &d.expr, 0) == null) return false;
    }
    for (hh.act[0..hh.nact]) |*a| a.name[31] = 0;
    if (rb_bytes > 0) b.rb = A.dupe(u8, c[o..][0..rb_bytes]) catch return false;
    o += rb_room;
    if (jt_bytes > 0) b.jt = A.dupe(u8, c[o..][0..jt_bytes]) catch return false;
    o += jt_room;
    @memcpy(&b.rest, c[o..][0..REST]);
    o += REST;
    @memcpy(std.mem.sliceAsBytes(b.keys[0..nkey]), c[o..][0 .. @as(usize, nkey) * @sizeOf(Key)]);
    for (b.keys[0..nkey]) |*k| {
        if (!std.math.isFinite(k.f)) return false;
    }
    mapRefs(hh, b.rb, b.jt, &b.rest, look, fromFile);

    const st = hh.start;
    const en = hh.end;
    const fps = hh.fps;
    if (en >= st and @abs(st) <= 10_000_000 and @abs(en) <= 10_000_000) {
        frange.r.start = st;
        frange.r.end = en;
    }
    if (std.math.isFinite(fps) and fps > 0) frange.r.fps = @min(fps, 100000);
    unref(cur);
    cur = b;
    ok = true;
    const fr: f32 = @bitCast(rd(c, 0));
    frame = if (std.math.isFinite(fr) and @abs(fr) < 1e7) fr else 1;
    return true;
}

test "curves" {
    var ks = [_]Key{ .{ .f = 1, .v = 0, .int = 2 }, .{ .f = 25, .v = 4, .int = 2 } };
    ks[0].hrx = 8;
    ks[1].hlx = -8;
    try std.testing.expectEqual(@as(f32, 0), evalKeys(&ks, 1));
    try std.testing.expectEqual(@as(f32, 4), evalKeys(&ks, 30));
    try std.testing.expectApproxEqAbs(@as(f32, 2), evalKeys(&ks, 13), 1e-5);
    ks[0].int = 1;
    try std.testing.expectApproxEqAbs(@as(f32, 1), evalKeys(&ks, 7), 1e-6);
    ks[0].int = 0;
    try std.testing.expectEqual(@as(f32, 0), evalKeys(&ks, 24.5));
    // one key, whatever its frame
    const nan = [_]Key{.{ .f = std.math.nan(f32), .v = 3 }};
    try std.testing.expectEqual(@as(f32, 3), evalKeys(&nan, 2));
}
