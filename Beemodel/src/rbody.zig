// Rigid body physics (rbody.s): the world, the step, the broad phase, frames
// on the timeline, the cache's records, the operators.
//
// Objects become rigid bodies (rigid.add): active ones fall and collide,
// passive ones stay where they are and are collided with. Shapes: box,
// sphere, capsule (a core and a radius), the convex hull of the mesh, or a
// compound of convex parts; a passive mesh collides with its triangles, a
// passive plane is without end. Joints (fixed, hinge, point, slider) tie two
// bodies or a body to the world. The settings live in the animation block
// (anim.zig: rb, jt, h.rw), so undo and files carry them.
//
// The simulation runs when the frame goes past the scene's start: bodies are
// made from the objects as they are there (that place is kept in the record,
// RB_INIT, and given back on the way back to the start), then fixed steps
// (the rate, 120 a second by default) until the frame's time; the bodies'
// places go into their objects (an evaluation: not an edit, undo keeps them
// apart as mech.zig does). Each whole frame reached is kept in the cache
// (simcache.zig, channel 0) and played back from it when the frame comes
// again; a change of what the simulation starts from (rb_key) drops it.
//
// A step: bounding boxes, a hash grid for pairs (here), a contact manifold
// per pair of parts that touch, kept between steps (rbnarrow.zig), islands
// solved with sequential impulses in substeps (rbsolve.zig). Shapes and joints
// are made in rbshape.zig, convex collision in collide.zig, bodies that
// attract in nbody.zig. The records, globals and vector helpers are in
// rbcore.zig.
//
// Landscapes as heightfields and water planes are in rbland.zig, shatter on
// impact (an original whose dormant pieces take its place when hit hard
// enough) in rbimp.zig. A shattered piece is a child of its original: its
// place is its world place as the original holds it (scene.worldPlace).
//
// Not in the port yet (later phases), left as marked hooks: geometry-node
// instances as bodies (HOOK(instances)), force fields
// (HOOK(fields) until fields.zig is there).
const std = @import("std");
const linux = std.os.linux;
const rc = @import("rbcore.zig");
const app = @import("app.zig");
const anim = @import("anim.zig");
const scene = @import("scene.zig");
const mods = @import("mods.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const sc = @import("simcache.zig");
const shape = @import("rbshape.zig");
const narrow = @import("rbnarrow.zig");
const solve = @import("rbsolve.zig");
const nbody = @import("nbody.zig");
const jobs = @import("jobs.zig");
const fields = @import("fields.zig");
const hfl = @import("rbland.zig");
const rbimp = @import("rbimp.zig");
const landscape = @import("landscape.zig");
const AL = @import("alloc.zig").A;

const V4 = rc.V4;
const Body = rc.Body;
const RB_SZ = rc.RB_SZ;
const JT_SZ = rc.JT_SZ;
const rdU = rc.rdU;
const wrU = rc.wrU;
const rdF = rc.rdF;
const wrF = rc.wrF;

const RBS_N = 8192; // frames whose counts are kept for rbinfo
const RBS_K = 16;
const rbs_keys = [RBS_K]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 14, 15, 16, 17, 18, 19, 20, 21 };
const JH_N = 32768;
const UH_N = 16384;
const ST_MAX = 8192;
const RB_CVER: u64 = 0x52425633; // the cache's records ("RBV3")
const HF_SLOTS = 131072;

const rx_keep: f32 = 0.04;
const rx_gmin: f32 = 0.05;
const rx_fric: f32 = 0.5;
const rx_deg: f32 = 0.017453292;

// ---- state ----------------------------------------------------------------------------

var pbf: i32 = -1; // the frame shown came from the cache: it (-1: live)
var npend: u32 = 0; // impulses before the bodies are made
var pend: [16]struct { oid: u32, imp: V4, shatter: bool } = undefined;
var hash: u64 = 0; // the settings it was made from
var pbkey: u64 = 0;
var st: [RBS_N]struct { key: u64, v: [RBS_K]f32 } = undefined;
var st_init = false;
var frame0: f32 = 0;
var fnow: f32 = 0;
pub var ms: f32 = 0; // the last frame's simulation time
var busy = false;
var noinst = false;
var base: []align(4096) u8 = &.{};

/// A grid entry (GE_*): its cell (packed), the body, the bucket.
const Ge = struct { key: u64, body: u32, b: u32 };
var gent: []Ge = &.{};
var gsrt: []Ge = &.{};
/// A pair of bodies (the lower first; B | 1 << 31: its manifolds to make).
const Pair = struct { a: u32, b: u32 };
var pairs: []Pair = &.{};

// ---- objects and records ---------------------------------------------------------------

/// The file's type 0 (OT_MESH).
fn isMeshType(k: scene.Kind) bool {
    return switch (k) {
        .light, .camera, .armature, .sketch, .field => false,
        else => true,
    };
}

fn recs(b: *anim.Block) []u8 {
    return b.rb[0 .. @min(b.h.nrb, b.rb.len / RB_SZ) * RB_SZ];
}
fn rec(b: *anim.Block, k: usize) []u8 {
    return b.rb[k * RB_SZ ..][0..RB_SZ];
}
fn nrb(b: *anim.Block) u32 {
    return @intCast(@min(b.h.nrb, b.rb.len / RB_SZ));
}
fn njt(b: *anim.Block) u32 {
    return @intCast(@min(b.h.njt, b.jt.len / JT_SZ));
}

/// rb_entry_obj: its object when it can be a body.
pub fn entryObj(r: []const u8) ?usize {
    if (rdU(r, rc.RB_TYPE) == 0) return null;
    const flags = rdU(r, rc.RB_FLAGS);
    const i = scene.findOid(rdU(r, rc.RB_UID)) orelse return null;
    const o = &scene.objects[i];
    if (!isMeshType(o.kind)) return null;
    // (a piece waiting for its original to break, an original that breaks:
    // hidden, still a body; hidden: not collided with)
    if (flags & (8 | 4) == 0 and !o.visible) return null;
    if (o.mesh == null) return null;
    return i;
}

/// An object's place as the original holds it (OB_LOC, OB_ROT radians,
/// OB_SCALE: a child's world place, scene.worldPlace).
fn placeBytes(i: usize) [36]u8 {
    return @bitCast(scene.worldPlace(i));
}

/// The place into the object: an evaluation (undo keeps it apart from edits).
fn putPlace(i: usize, loc: [3]f32, rot: [3]f32, scl: ?[3]f32) void {
    const o = &scene.objects[i];
    undo.evalWrite();
    if (o.parent != null) {
        // a child (a shattered piece): its world place, as the original's OB_*
        var p = scene.worldPlace(i);
        p[0..3].* = loc;
        p[3..6].* = rot;
        if (scl) |x| p[6..9].* = x;
        scene.setWorldPlace(i, p);
    } else {
        o.loc = loc;
        o.setRadians(rot);
        if (scl) |x| o.scl = x;
    }
    undo.absorb(i);
    app.dirty = true;
}

/// rb_restore: objects back where they were at the start; the start forgotten.
pub fn restore() void {
    const b = anim.cur orelse return;
    // (children after the others: a child's world place is kept against its
    // parent's place - a shattered piece of a body)
    for (0..2) |pass| {
        for (0..nrb(b)) |k| {
            const r = rec(b, k);
            const fl = rdU(r, rc.RB_FLAGS);
            if (fl & 1 == 0) continue;
            const i = entryObj(r);
            const child = if (i) |x| scene.objects[x].parent != null else false;
            if ((pass == 0) == child) continue;
            wrU(r, rc.RB_FLAGS, fl & ~@as(u32, 1));
            if (i) |x| restoreOne(r, x);
        }
    }
    rbimp.restoreAll(); // (shattering ones: whole again)
}

fn restoreOne(r: []const u8, i: usize) void {
    const p = rc.rd3(r, rc.RB_INIT);
    const q = rc.rd3(r, rc.RB_INIT + 12);
    const s = rc.rd3(r, rc.RB_INIT + 24);
    putPlace(i, p, q, s);
}

/// rb_capture: the starts not kept yet, from where the objects are.
fn capture() void {
    const b = anim.cur orelse return;
    for (0..nrb(b)) |k| {
        const r = rec(b, k);
        if (rdU(r, rc.RB_FLAGS) & 1 != 0) continue;
        const i = entryObj(r) orelse continue;
        @memcpy(r[rc.RB_INIT..][0..36], &placeBytes(i));
        wrU(r, rc.RB_FLAGS, rdU(r, rc.RB_FLAGS) | 1);
    }
}

// ---- building the world ------------------------------------------------------------------

/// rb_free: no simulation.
pub fn free() void {
    hfl.reset();
    rbiDrop();
    if (!rc.on) return;
    rc.on = false;
    if (base.len > 0) std.heap.page_allocator.free(base);
    base = &.{};
}

/// rb_reset: a new scene, no simulation.
pub fn reset() void {
    free();
}

const Lay = struct {
    off: usize = 0,
    fn put(l: *Lay, bytes: usize) usize {
        const o = l.off;
        l.off += (bytes + 63) & ~@as(usize, 63);
        return o;
    }
};

fn carve(comptime T: type, off: usize, n: usize) []T {
    const p: [*]T = @ptrCast(@alignCast(base.ptr + off));
    return p[0..n];
}

/// rb_build: the bodies and joints from the records, the world's arrays.
fn build() void {
    free();
    noinst = true;
    defer noinst = false;
    const b = anim.cur orelse return;
    var nbod: u32 = 0;
    var maxv: u32 = 0;
    var maxt: u32 = 0;
    rc.xparts = 0;
    hfl.xhf = 0;
    var nland: u32 = 0; // (landscapes)
    for (0..nrb(b)) |k| {
        const r = rec(b, k);
        const i = entryObj(r) orelse continue;
        const me = mods.of(i) orelse continue;
        if (rdU(r, rc.RB_FLAGS) & 2 != 0) {
            // its instances: one body each; their prototypes' sizes
            const ib = mods.instancesOf(i) orelse continue;
            nbod += ib.n;
            for (ib.proto[0..ib.np]) |pg| {
                const g = pg orelse continue;
                maxv = @max(maxv, @as(u32, @intCast(g.verts.len)));
                maxt = @max(maxt, @as(u32, @intCast(@import("geonodes.zig").trisOf(g).len)));
            }
            continue;
        }
        nbod += 1;
        if (rdU(r, rc.RB_SHAPE) == 5 and rdU(r, rc.RB_TYPE) == 2) {
            // a mesh collider: its triangles (a landscape: slots, not triangles)
            var ct: u32 = @intCast(me.tris.len);
            if (landscape.ofIndex(i) != null and nland < hfl.HF_MAX) {
                nland += 1;
                ct = hfl.HF_SLOTS;
            }
            rc.xparts += ct;
            hfl.xhf = nland;
        }
        maxv = @max(maxv, @as(u32, @intCast(me.verts.len)));
        maxt = @max(maxt, @as(u32, @intCast(me.tris.len)));
    }
    const nb = nbod + 1; // (the world, a body too)
    rc.nb = nb;
    const xp: usize = rc.xparts;
    const n: usize = nb;
    var l = Lay{};
    const o_bd = l.put(n * @sizeOf(Body));
    const n_pt = n * rc.PT_MAXB + xp;
    const o_pt = l.put(n_pt * @sizeOf(rc.Part));
    const n_bvh = xp * 2 + 64;
    const o_bvh = l.put(n_bvh * @sizeOf(rc.BvNode));
    const n_bvi = xp + 16;
    const o_bvi = l.put(n_bvi * 4);
    const n_bvb = xp + 16;
    const o_bvb = l.put(n_bvb * @sizeOf(rc.BvNode));
    const n_tvw = (xp + 16) * 3;
    const o_tvw = l.put(n_tvw * 16);
    const n_vx = (n * rc.PT_MAXB * rc.HULL_MAX * 16 + xp * 48 + @as(usize, maxv) * 48 + @as(usize, maxt) * 16 + 65536) / 16;
    const o_vx = l.put(n_vx * 16);
    // manifolds: 64 a body (packed small ones meet many), 128 more with a
    // mesh collider (a body on a fine mesh meets its triangles)
    var capmf: u32 = nb * 64 + 4096;
    if (rc.xparts != 0) capmf += nb * 128;
    rc.capmf = capmf;
    const o_mf = l.put(@as(usize, capmf) * @sizeOf(rc.Manifold));
    const o_mx = l.put(@as(usize, capmf) * @sizeOf(rc.Mx));
    // the hash: a power of two >= 4 x
    const hn: u32 = @as(u32, 1) << @intCast(32 - @clz(capmf << 2));
    rc.hmask = hn - 1;
    const o_hs = l.put(@as(usize, hn) * 4);
    const o_ord = l.put((n + 4) * 4);
    const n_ge = (n * 27 * 16 + 1024) / 16;
    const o_gent = l.put(n_ge * @sizeOf(Ge));
    const o_gsrt = l.put(n_ge * @sizeOf(Ge));
    // buckets: a power of two >= 16 nb
    const bits: u32 = 32 - @clz((nb *% 16) | 1023);
    const nbk: u32 = @as(u32, 1) << @intCast(bits);
    rc.gmask = nbk - 1;
    rc.gsh = 64 - bits;
    const o_gtab = l.put(@as(usize, nbk) * 4 + 16);
    const o_gbig = l.put((n + 4) * 4);
    rc.cappair = nb * 64 + 1024;
    const o_pairs = l.put(@as(usize, rc.cappair) * @sizeOf(Pair));
    const n_gcc = (rc.gmask >> 8) + 2;
    const o_gcc = l.put(@as(usize, n_gcc) * 4);
    const n_bc = @as(usize, capmf) + rc.JT_MAX + 16;
    const o_bcon = l.put(n_bc * 4);
    const o_bsrt = l.put(n_bc * 4);
    const o_bcol = l.put(n_bc * 4);
    const o_bmask = l.put((n + 2) * 8);
    const o_bcst = l.put(70 * 4);
    const o_stg = l.put(ST_MAX * 48);
    const o_scnt = l.put(ST_MAX * 128);
    const o_par = l.put((n + 4) * 4);
    const o_ib = l.put((n + 4) * 4);
    const o_imf = l.put(@as(usize, capmf) * 4);
    const o_ij = l.put(rc.JT_MAX * 4);
    const o_isb = l.put((n + 4) * 4);
    const o_ism = l.put((n + 4) * 4);
    const o_isj = l.put((n + 4) * 4);
    const o_iaw = l.put((n + 4) * 4);
    const o_jh = l.put(JH_N * 8);
    const o_jhv = l.put(JH_N * 4);
    const o_uh = l.put(UH_N * 8);
    const o_jr = l.put(rc.JT_MAX * @sizeOf(rc.Joint));
    const n_hf = @as(usize, hfl.xhf) * hfl.HF_SLOTS; // heightfields' slots
    const o_hkey = l.put(n_hf * 4 + 64);
    const o_hseen = l.put(n_hf * 4 + 64);
    const o_hfree = l.put(n_hf * 4 + 64);
    const o_hfric = l.put(n_hf * 4 + 64);
    const o_hrest = l.put(n_hf * 4 + 64);
    const n_htab = @as(usize, hfl.xhf) << 18;
    const o_htab = l.put(n_htab * 4 + 64);
    base = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), l.off) catch {
        rc.on = false;
        return;
    };
    @memset(base, 0);
    rc.bd = carve(Body, o_bd, n);
    for (rc.bd) |*x| x.* = .{};
    rc.pt = carve(rc.Part, o_pt, n_pt);
    for (rc.pt) |*x| x.* = .{};
    rc.bvh = carve(rc.BvNode, o_bvh, n_bvh);
    rc.bvi = carve(u32, o_bvi, n_bvi);
    rc.bvb = carve(rc.BvNode, o_bvb, n_bvb);
    rc.tvw = carve(V4, o_tvw, n_tvw);
    rc.vx = carve(V4, o_vx, n_vx);
    rc.mf = carve(rc.Manifold, o_mf, capmf);
    rc.mx = carve(rc.Mx, o_mx, capmf);
    rc.hs = carve(u32, o_hs, hn);
    rc.ord = carve(u32, o_ord, n + 4);
    gent = carve(Ge, o_gent, n_ge);
    gsrt = carve(Ge, o_gsrt, n_ge);
    rc.gtab = carve(u32, o_gtab, nbk + 4);
    rc.gbig = carve(u32, o_gbig, n + 4);
    pairs = carve(Pair, o_pairs, rc.cappair);
    rc.gcc = carve(u32, o_gcc, n_gcc);
    rc.bcon = carve(u32, o_bcon, n_bc);
    rc.bsrt = carve(u32, o_bsrt, n_bc);
    rc.bcol = carve(u32, o_bcol, n_bc);
    rc.bmask = carve(u64, o_bmask, n + 2);
    rc.bcst = carve(u32, o_bcst, 70);
    rc.stg = base[o_stg..][0 .. ST_MAX * 48];
    rc.scnt = base[o_scnt..][0 .. ST_MAX * 128];
    rc.par = carve(u32, o_par, n + 4);
    rc.ib = carve(u32, o_ib, n + 4);
    rc.imf = carve(u32, o_imf, capmf);
    rc.ij = carve(u32, o_ij, rc.JT_MAX);
    rc.isb = carve(u32, o_isb, n + 4);
    rc.ism = carve(u32, o_ism, n + 4);
    rc.isj = carve(u32, o_isj, n + 4);
    rc.iaw = carve(u32, o_iaw, n + 4);
    rc.jh = carve(u64, o_jh, JH_N);
    rc.jhv = carve(u32, o_jhv, JH_N);
    rc.uh = carve(u64, o_uh, UH_N);
    rc.jr = carve(rc.Joint, o_jr, rc.JT_MAX);
    for (rc.jr) |*x| x.* = .{};
    hfl.keyp = carve(u32, o_hkey, n_hf);
    hfl.seenp = carve(u32, o_hseen, n_hf);
    hfl.freelp = carve(u32, o_hfree, n_hf);
    hfl.fricp = carve(f32, o_hfric, n_hf);
    hfl.restp = carve(f32, o_hrest, n_hf);
    hfl.tabp = carve(u32, o_htab, n_htab);
    rc.on = true;
    rc.mffull = 0;
    rc.nbroken = 0;
    rc.tns = @splat(0);
    rc.npt = 0;
    rc.nvx = 0;
    rc.nmf = 0;
    rc.nbvh = 0;
    rc.nbvi = 0;
    rc.njr = 0;
    rc.stepno = 0;
    // the bodies
    var made: u32 = 0;
    for (0..nrb(b)) |k| {
        const r = rec(b, k);
        const i = entryObj(r) orelse continue;
        if (made >= nb - 1) break; // (counted when its mesh evaluated)
        if (rdU(r, rc.RB_FLAGS) & 1 != 0) {
            // the start kept: the object there
            const p = rc.rd3(r, rc.RB_INIT);
            const q = rc.rd3(r, rc.RB_INIT + 12);
            const s = rc.rd3(r, rc.RB_INIT + 24);
            putPlace(i, p, q, s);
        } else {
            @memcpy(r[rc.RB_INIT..][0..36], &placeBytes(i));
            wrU(r, rc.RB_FLAGS, rdU(r, rc.RB_FLAGS) | 1);
        }
        if (rdU(r, rc.RB_FLAGS) & 2 != 0) {
            made += instBodies(made, nb - 1, r, i); // its instances
            continue;
        }
        if (mods.of(i) == null) continue;
        shape.makeBody(made, r, i);
        if (rdU(r, rc.RB_FLAGS) & 8 != 0) {
            // a piece waiting for its original: dormant (in no group, still)
            const x = &rc.bd[made];
            x.grp0 = x.grp;
            x.grp = 0xffff0000;
            x.typ = 3;
            x.v = @splat(0);
            x.w = @splat(0);
        }
        made += 1;
    }
    rbimp.reset(); // (shatter on impact: anew)
    const w = &rc.bd[made]; // the world: static, at the origin
    w.typ = 2;
    w.q = rc.qid;
    rc.bodyUpdate(w);
    shape.makeJoints();
    for (0..rc.nb) |k| rc.ord[k] = @intCast(k);
    settings();
}

/// rb_gravity: the world's gravity (w 0).
pub fn gravity() V4 {
    settings();
    return rc.g;
}

/// rb_settings: gravity, step, iterations from the world settings.
pub fn settings() void {
    var g: V4 = .{ 0, -9.81, 0, 0 };
    var rate: u32 = 120;
    var it: u32 = 10;
    var sub: u32 = 4;
    if (anim.cur) |b| {
        const w = &b.h.rw;
        if (rdU(w, rc.RW_SUB) != 0) sub = rdU(w, rc.RW_SUB);
        if (rdU(w, rc.RW_SET) != 0) g = rc.rdV3(w, rc.RW_GRAV);
        if (rdU(w, rc.RW_RATE) != 0) rate = rdU(w, rc.RW_RATE);
        if (rdU(w, rc.RW_ITER) != 0) it = rdU(w, rc.RW_ITER);
    }
    rc.g = g;
    rc.nsub = sub;
    // iterations: spread over the substeps (at least 1)
    var q = it / sub;
    if (q < 1) q += 1;
    rc.iter = q;
    const xr: f32 = @floatFromInt(@as(i32, @bitCast(rate)));
    const dt = 1.0 / xr;
    rc.dt = dt;
    const xs: f32 = @floatFromInt(@as(i32, @bitCast(sub)));
    const h = dt / xs;
    rc.h = h;
    // soft contacts: w = 2 pi min(30, rate x substeps / 4), z = 10
    var w = xr * xs;
    w *= 0.25;
    w = rc.minss(w, 60.0);
    w *= 6.2831853;
    soft(w, h, 10.0, &rc.brate, &rc.mscale, &rc.iscale);
    soft(w + w, h, 10.0, &rc.brate_s, &rc.mscale_s, &rc.iscale_s);
    rc.jhard = 0.2 / h;
    // joints: w = 2 pi substeps a second / 4, z 5
    var jw: f32 = 6.2831853;
    jw *= 0.25;
    jw /= h;
    soft(jw, h, 5.0, &rc.jsoft[0], &rc.jsoft[1], &rc.jsoft[2]);
}

/// rb_soft_z: a1 = 2z + hw, a2 = hw a1, a3 = 1 / (1 + a2): bias w / a1,
/// mass a2 a3, impulse a3.
fn soft(w: f32, h: f32, z: f32, bias: *f32, mass: *f32, imp: *f32) void {
    const hw = h * w;
    var a1 = z + z;
    a1 += hw;
    const a2 = hw * a1;
    const a3 = 1.0 / (1.0 + a2);
    bias.* = w / a1;
    mass.* = a2 * a3;
    imp.* = a3;
}

// ---- the manifolds' hash ---------------------------------------------------------------

const mfHash = narrow.mfHash;
pub const hfSlot = narrow.hfSlot;
pub const hfDelete = narrow.hfDelete;

/// mf_find: the manifold's keys of these parts, or null.
pub fn mfFind(pa: u32, pb: u32) ?*rc.Mx {
    var s = mfHash(pa, pb);
    while (true) {
        const e = rc.hs[s];
        if (e == 0) return null;
        const x = &rc.mx[e - 1];
        if (x.pa == pa and x.pb == pb) return x;
        s = (s + 1) & rc.hmask;
    }
}

/// mf_get: the manifold of the two parts kept this step (made when new; none when full).
pub fn mfGet(a: u32, b: u32, pa: u32, pb: u32) void {
    var s = mfHash(pa, pb);
    while (true) {
        const e = rc.hs[s];
        if (e == 0) break;
        const x = &rc.mx[e - 1];
        if (x.pa == pa and x.pb == pb) {
            x.keep = rc.stepno;
            return;
        }
        s = (s + 1) & rc.hmask;
    }
    // a new one (room, and the hash at most half full)
    const k = rc.nmf;
    if (k >= rc.hmask >> 1 or k >= rc.capmf) {
        rc.mffull += 1; // (none left: counted, rbinfo(14); said once)
        if (rc.mffull == 1) say(&.{"  rigid bodies: no room for more contacts - some bodies may pass through others"});
        return;
    }
    rc.nmf += 1;
    rc.hs[s] = k + 1;
    const m = &rc.mf[k];
    m.a = a;
    m.b = b;
    m.pa = pa;
    m.pb = pb;
    m.n = 0;
    rc.mx[k] = .{ .a = a, .b = b, .pa = pa, .pb = pb, .n = 0, .keep = rc.stepno };
    const ba = &rc.bd[a];
    const bb = &rc.bd[b];
    m.fric = @sqrt(ba.fric * bb.fric);
    m.rest = rc.maxss(ba.rest, bb.rest);
    // a heightfield's triangle: the paint's friction and bounce there
    const fr, const other = if (hfl.isHf(ba)) .{ hfl.partMat(ba, pa), bb } else if (hfl.isHf(bb)) .{ hfl.partMat(bb, pb), ba } else return;
    m.fric = @sqrt(fr[0] * other.fric);
    m.rest = rc.maxss(fr[1], other.rest);
}

// ---- the broad phase -------------------------------------------------------------------

/// cvttps2dq of a floored lane: out of range or NaN gives the minimum.
fn cvtt(x: f32) i32 {
    if (x >= -2147483648.0 and x < 2147483648.0) return @intFromFloat(x);
    return std.math.minInt(i32);
}
fn cellOf(p: V4) [3]i32 {
    const x = p * rc.splat(rc.ginv);
    return .{ cvtt(@floor(x[0])), cvtt(@floor(x[1])), cvtt(@floor(x[2])) };
}

/// gr_ext: the largest of x y z.
fn grExt(v: V4) f32 {
    var a = rc.maxss(v[0], v[1]);
    a = rc.maxss(a, v[2]);
    return a;
}

/// gr_key: the cell packed, its bucket.
fn grKey(c: [3]i32) struct { key: u64, b: u32 } {
    const f = struct {
        fn f(x: i32) u64 {
            return @as(u32, @bitCast(x +% 0x100000)) & 0x1FFFFF;
        }
    }.f;
    const kk = f(c[0]) | f(c[1]) << 21 | f(c[2]) << 42;
    const hsh = kk *% 0x9E3779B97F4A7C15;
    return .{ .key = kk, .b = @truncate(hsh >> @intCast(rc.gsh)) };
}

fn boundsMeet(a: *const Body, b: *const Body) bool {
    const x = a.min <= b.max;
    const y = b.min <= a.max;
    return x[0] and y[0] and x[1] and y[1] and x[2] and y[2];
}

/// The groups: either ignoring the other's group, no contact.
fn groupsMeet(a: *const Body, b: *const Body) bool {
    if (@as(u16, @truncate((a.grp >> 16) & b.grp)) != 0) return false;
    if (@as(u16, @truncate((b.grp >> 16) & a.grp)) != 0) return false;
    return true;
}

/// gr_test: their bounds meet, at least one moves and no joint ties them.
fn grTest(ia: u32, ibb: u32) bool {
    const a = &rc.bd[ia];
    const b = &rc.bd[ibb];
    if (!boundsMeet(a, b)) return false;
    if (a.typ != 1 and b.typ != 1) return false;
    if (!groupsMeet(a, b)) return false;
    if (a.joint == 0 or b.joint == 0) return true;
    return !jointed(ia, ibb);
}

/// gr_pair: when they may meet, on the list (the lower first; the list full: now).
fn grPair(ia: u32, ibb: u32) void {
    if (!grTest(ia, ibb)) return;
    const lo = @min(ia, ibb);
    const hi = @max(ia, ibb);
    if (rc.npair < rc.cappair) {
        pairs[rc.npair] = .{ .a = lo, .b = hi };
        rc.npair += 1;
        return;
    }
    pairParts(lo, hi);
}

const jointed = shape.jointed;

/// gr_scan: chunk's 256 buckets: two entries of one cell where their bounds'
/// overlap begins, passing gr_test. out: null counts, .now pairs at once.
const ScanOut = union(enum) { count, now, at: u32 };
fn grScan(chunk: u32, out: ScanOut) u32 {
    var bk = chunk << 8;
    const end = @min(bk + 256, rc.gmask + 1);
    var start: u32 = if (bk == 0) 0 else rc.gtab[bk - 1];
    var found: u32 = 0;
    var w: u32 = switch (out) {
        .at => |x| x,
        else => 0,
    };
    while (bk < end) : (bk += 1) {
        const e = rc.gtab[bk];
        defer start = e;
        if (start + 1 >= e) continue;
        var i = start;
        while (i + 1 < e) : (i += 1) {
            var j = i + 1;
            while (j < e) : (j += 1) {
                const gi = gsrt[i];
                const gj = gsrt[j];
                if (gi.key != gj.key) continue;
                const a = &rc.bd[gi.body];
                const b = &rc.bd[gj.body];
                // where the overlap begins: this cell?
                const c = cellOf(rc.maxps(a.min, b.min));
                if (grKey(c).key != gi.key) continue;
                if (!grTest(gi.body, gj.body)) continue;
                const lo = @min(gi.body, gj.body);
                const hi = @max(gi.body, gj.body);
                switch (out) {
                    .count => {},
                    .now => pairParts(lo, hi),
                    .at => {
                        pairs[w] = .{ .a = lo, .b = hi };
                        w += 1;
                    },
                }
                found += 1;
            }
        }
    }
    return found;
}

/// broad: pairs of bodies whose bounds meet, through a hash grid: the cell
/// about the size of a moving body (their average); each body in the cells
/// its bounds cover (bodies more than twice that size go in a list and are
/// tested against every body); the entries counting-sorted by bucket; in a
/// bucket, two entries of the same cell are a pair when that cell is where
/// their bounds' overlap begins (each pair once). The order is the bodies'
/// own (the same every run).
pub fn broad() void {
    var sum: f32 = 0;
    var nm: u32 = 0;
    for (rc.bd[0..rc.nb]) |*x| {
        if (x.typ != 1) continue;
        sum += grExt(x.max - x.min);
        nm += 1;
    }
    if (nm == 0) return; // nothing moves: no pairs
    var cs = sum / @as(f32, @floatFromInt(nm));
    cs = rc.maxss(cs, rx_gmin);
    rc.gcs = cs;
    rc.ginv = 1.0 / cs;
    @memset(rc.gtab[0 .. rc.gmask + 2], 0);
    rc.gn = 0;
    rc.gnbig = 0;
    rc.npair = 0;
    for (0..rc.nb) |k| {
        const x = &rc.bd[k];
        const ext = grExt(x.max - x.min);
        if (ext > rc.gcs + rc.gcs) {
            rc.gbig[rc.gnbig] = @intCast(k);
            rc.gnbig += 1;
            continue;
        }
        const c0 = cellOf(x.min);
        const c1 = cellOf(x.max);
        var i = c0[0];
        while (i <= c1[0]) : (i += 1) {
            var j = c0[1];
            while (j <= c1[1]) : (j += 1) {
                var kk = c0[2];
                while (kk <= c1[2]) : (kk += 1) {
                    const g = grKey(.{ i, j, kk });
                    gent[rc.gn] = .{ .key = g.key, .body = @intCast(k), .b = g.b };
                    rc.gtab[g.b + 1] += 1;
                    rc.gn += 1;
                    if (kk == std.math.maxInt(i32)) break;
                }
                if (j == std.math.maxInt(i32)) break;
            }
            if (i == std.math.maxInt(i32)) break;
        }
    }
    // starts; then a stable counting sort (tab[b] the cursor; afterwards
    // tab[b] = b's end = b+1's start)
    var acc: u32 = 0;
    for (rc.gtab[0 .. rc.gmask + 2]) |*t| {
        acc += t.*;
        t.* = acc;
    }
    for (gent[0..rc.gn]) |e| {
        const p = rc.gtab[e.b];
        rc.gtab[e.b] += 1;
        gsrt[p] = e;
    }
    // the buckets' pairs: counted in chunks of 256 buckets, then written where
    // each chunk's count puts them (bucket order)
    const chunks = (rc.gmask >> 8) + 1;
    for (0..chunks) |c| rc.gcc[c] = grScan(@intCast(c), .count);
    var tot: u32 = 0;
    for (rc.gcc[0..chunks]) |*c| {
        const x = c.*;
        c.* = tot;
        tot += x;
    }
    if (tot > rc.cappair) {
        // no room: the list stays empty and the pairs go one by one
        rc.npair = 0;
        for (0..chunks) |c| _ = grScan(@intCast(c), .now);
    } else {
        rc.npair = tot;
        for (0..chunks) |c| _ = grScan(@intCast(c), .{ .at = rc.gcc[c] });
    }
    // the big ones: against every body (two big ones once)
    for (rc.gbig[0..rc.gnbig]) |bi| {
        for (0..rc.nb) |k0| {
            const k: u32 = @intCast(k0);
            if (k == bi) continue;
            const o = &rc.bd[k];
            if (grExt(o.max - o.min) > rc.gcs + rc.gcs and k < bi) continue;
            grPair(bi, k);
        }
    }
    // the pairs' manifolds looked up (kept); the new ones (and bodies of
    // several parts) made after, in the list's order
    for (pairs[0..rc.npair]) |*p| pairJob(p);
    for (pairs[0..rc.npair]) |p| {
        if (p.b & 0x80000000 == 0) continue;
        pairParts(p.a, p.b & 0x7fffffff);
    }
}

/// pair_job: a pair of one part each whose manifold exists: seen this step;
/// the rest marked (B | 1 << 31).
fn pairJob(p: *Pair) void {
    const a = &rc.bd[p.a];
    const b = &rc.bd[p.b];
    if (a.bvh != 0 or b.bvh != 0) {
        // a mesh: its triangles in reach looked up (new ones: after)
        if (ppTree(p.a, p.b, true) != 0) p.b |= 0x80000000;
        return;
    }
    if (a.np != 1 or b.np != 1) {
        p.b |= 0x80000000;
        return;
    }
    if (mfFind(a.p0, b.p0)) |x| {
        x.keep = rc.stepno;
    } else p.b |= 0x80000000;
}

/// pair_parts: their parts whose bounds meet: manifolds.
pub fn pairParts(ia0: u32, ib0: u32) void {
    const ia = @min(ia0, ib0);
    const ibb = @max(ia0, ib0);
    const a = &rc.bd[ia];
    const b = &rc.bd[ibb];
    if (a.bvh != 0 or b.bvh != 0) {
        _ = ppTree(ia, ibb, false);
        return;
    }
    var pa = a.p0;
    while (pa < a.p0 + a.np) : (pa += 1) {
        var pb = b.p0;
        while (pb < b.p0 + b.np) : (pb += 1) {
            if (a.np + b.np != 2) {
                // one part each: the bodies' test did
                var ba: [2]V4 = undefined;
                var bb: [2]V4 = undefined;
                narrow.partBounds(a, pa, &ba);
                narrow.partBounds(b, pb, &bb);
                const x = ba[0] <= bb[1];
                const y = bb[0] <= ba[1];
                if (!(x[0] and y[0] and x[1] and y[1] and x[2] and y[2])) continue;
            }
            mfGet(ia, ibb, pa, pb);
        }
    }
}

/// pp_tree: one of them is a mesh: each part of the other against the
/// triangles under its bounds, within its reach. look: only look; the count
/// of triangles in reach with no manifold (those found are kept).
fn ppTree(ia: u32, ibb: u32, look: bool) u32 {
    const a = &rc.bd[ia];
    const b = &rc.bd[ibb];
    var missing: u32 = 0;
    // the mesh M and the other O
    const m_first = b.bvh == 0;
    const mb = if (m_first) a else b;
    const ob = if (m_first) b else a;
    var op = ob.p0;
    while (op < ob.p0 + ob.np) : (op += 1) {
        var bnd: [2]V4 = undefined;
        narrow.partBounds(ob, op, &bnd);
        // its centre and reach: the bounds' half diagonal and its radius, the
        // margin, how far it goes in a step
        const part = &rc.pt[op];
        var cen = rc.mv3(&ob.r, part.off);
        cen += ob.pos;
        cen = rc.andXyz(cen);
        const hh = rc.andXyz(part.half);
        var reach = @sqrt(rc.dot3(hh, hh));
        reach += part.rad;
        var sp = @sqrt(rc.dot3(ob.v, ob.v));
        sp *= rc.dt;
        reach += sp;
        reach += rx_keep;
        reach *= reach;
        const root = @as(i32, @bitCast(mb.bvh));
        if (root < 0) {
            // a heightfield: the cells under the part, their triangles'
            // slots (made before)
            const h = hfl.of(mb);
            const c = hfl.cells(h, hfl.box(ob, op)) orelse continue;
            var j = c.j0;
            while (j <= c.j1) : (j += 1) {
                var i = c.i0;
                while (i <= c.i1) : (i += 1) {
                    var t: u32 = 0;
                    while (t < 2) : (t += 1) {
                        const slot = hfl.get(h, hfl.triOf(h, i, j) +% t, false) orelse continue;
                        const tp = slot + h.slot0;
                        if (!narrow.ppReach(tp, cen, reach)) continue;
                        const p0 = if (m_first) tp else op;
                        const p1 = if (m_first) op else tp;
                        if (look) {
                            if (mfFind(p0, p1)) |x| {
                                x.keep = rc.stepno;
                            } else missing += 1;
                        } else mfGet(ia, ibb, p0, p1);
                    }
                }
            }
            continue;
        }
        var stack: [48]u32 = undefined;
        stack[0] = @as(u32, @bitCast(root)) - 1;
        var depth: u32 = 1;
        while (depth > 0) {
            depth -= 1;
            const nd = &rc.bvh[stack[depth]];
            if (!nodeMeets(nd, bnd)) continue;
            if (nd.left & 0x80000000 == 0) {
                // inner: both children (the stack holds 48)
                if (depth >= 46) continue;
                stack[depth] = nd.left;
                stack[depth + 1] = nd.right;
                depth += 2;
                continue;
            }
            const first = nd.left & 0x7fffffff;
            const last = first + nd.right;
            var t = first;
            while (t < last) : (t += 1) {
                if (!nodeMeets(&rc.bvb[t], bnd)) continue;
                const tp = rc.bvi[t];
                if (!narrow.ppReach(tp, cen, reach)) continue;
                // (parts in the bodies' order)
                const p0 = if (m_first) tp else op;
                const p1 = if (m_first) op else tp;
                if (look) {
                    if (mfFind(p0, p1)) |x| {
                        x.keep = rc.stepno;
                    } else missing += 1;
                } else mfGet(ia, ibb, p0, p1);
            }
        }
    }
    return missing;
}

/// A tree node's box meets the bounds (cmpleps lo <= max, min <= hi).
fn nodeMeets(nd: *const rc.BvNode, bnd: [2]V4) bool {
    inline for (0..3) |k| {
        if (!(nd.min[k] <= bnd[1][k])) return false;
        if (!(bnd[0][k] <= nd.max[k])) return false;
    }
    return true;
}

// ---- the step --------------------------------------------------------------------------

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000000000 + @as(u64, @intCast(ts.nsec));
}
fn nowMs() i64 {
    return @intCast(nowNs() / 1000000);
}

var lap_t: u64 = 0;
/// rb_lap: the time since the last lap into part k.
fn lap(k: usize) void {
    const t = nowNs();
    rc.tns[k] +%= t -% lap_t;
    lap_t = t;
}

/// rb_step: one fixed step.
fn step() void {
    rc.stepno += 1;
    // the force fields now
    fields.prep(@as(f32, @floatFromInt(rc.stepno)) * rc.dt, .{ rc.g[0], rc.g[1], rc.g[2] });
    // bodies that attract (nbody): G (the world's, 1), half a kick the first step
    var gk: f32 = 1.0;
    if (anim.cur) |b| {
        const gg = rdF(&b.h.rw, rc.RW_G);
        if (gg != 0) gk = gg;
    }
    if (rc.stepno == 1) gk *= 0.5;
    nbody.step(gk);
    lap_t = nowNs();
    narrow.ccdMark(); // where the moving bodies begin
    hfl.prepare(); // heightfields: triangles under them
    hfl.water(); // water planes: what is in them floats
    broad(); // pairs of parts: manifolds kept / made
    lap(0);
    narrow.compact(); // the rest go
    lap(5);
    var ctx: u8 = 0;
    jobs.parallelFor(rc.nmf, 16, &ctx, narrow.narrowJob); // contacts, in parallel
    if (rbimp.nimp != 0 and rbimp.check(fnow)) {
        // shatter on impact: this step's blows, before they are solved;
        // broken: the pieces in, the original out, from the pairs on
        narrow.ccdMark();
        hfl.prepare();
        broad();
        narrow.compact();
        jobs.parallelFor(rc.nmf, 16, &ctx, narrow.narrowJob);
    }
    lap(1);
    solve.islands();
    lap(2);
    solve.solveAll(); // each island; the big ones across the workers
    solve.jrBreaks(); // joints pulled too hard: broken
    narrow.ccdPass(); // fast ones: stopped short of statics
    lap(3);
}

// ---- the key ------------------------------------------------------------------------------

fn uidOf(oid: u32) u32 {
    if (oid == 0) return 0;
    return scene.uidOfOid(oid) orelse 0;
}

/// rb_sethash: the records (as the original holds them: uids) and the world.
fn setHash() u64 {
    const K: u64 = 0x9E3779B97F4A7C15;
    const b = anim.cur orelse return K;
    var h: u64 = K;
    h ^= @as(u64, b.h.nrb) | @as(u64, b.h.njt) << 32;
    h *%= K;
    var i: usize = 0;
    while (i < 32) : (i += 8) {
        h ^= std.mem.readInt(u64, b.h.rw[i..][0..8], .little);
        h *%= K;
    }
    for (0..nrb(b)) |k| {
        var r: [RB_SZ]u8 = rec(b, k)[0..RB_SZ].*;
        wrU(&r, rc.RB_UID, uidOf(rdU(&r, rc.RB_UID)));
        i = 0;
        while (i < 32) : (i += 8) {
            var q = std.mem.readInt(u64, r[i..][0..8], .little);
            if (i == 24) q &= ~(@as(u64, 1) << 32); // (not RB_FLAGS bit 0: the start kept)
            h ^= q;
            h *%= K;
        }
        // its velocity too (not the start before it: play keeps that)
        h ^= std.mem.readInt(u64, r[rc.RB_VEL..][0..8], .little);
        h *%= K;
        h ^= rdU(&r, rc.RB_VEL + 8);
        h *%= K;
    }
    for (0..njt(b)) |k| {
        var r: [JT_SZ]u8 = b.jt[k * JT_SZ ..][0..JT_SZ].*;
        wrU(&r, rc.JT_A, uidOf(rdU(&r, rc.JT_A)));
        wrU(&r, rc.JT_B, uidOf(rdU(&r, rc.JT_B)));
        i = 0;
        while (i < JT_SZ) : (i += 8) {
            h ^= std.mem.readInt(u64, r[i..][0..8], .little);
            h *%= K;
        }
    }
    return h;
}

/// rb_key: the settings, the frame range, each body's start and mesh (what
/// the cache belongs to).
fn key() u64 {
    noinst = true;
    defer noinst = false;
    var h = setHash() ^ RB_CVER;
    const b = anim.cur orelse return h;
    const fr = @import("frange.zig").r;
    var se: [3]u32 = .{ @bitCast(fr.start), @bitCast(fr.end), @bitCast(fr.fps) };
    h = sc.mix(h, std.mem.asBytes(&se));
    for (0..nrb(b)) |k| {
        const r = rec(b, k);
        const i = entryObj(r) orelse continue;
        if (rdU(r, rc.RB_FLAGS) & 1 != 0) {
            h = sc.mix(h, r[rc.RB_INIT..][0..36]);
        } else {
            const p = placeBytes(i);
            h = sc.mix(h, &p);
        }
        // instances: what makes them (the evaluated mesh's instances)
        if (rdU(r, rc.RB_FLAGS) & 2 != 0) {
            if (mods.instancesOf(i)) |ib| h = sc.mix(h, std.mem.sliceAsBytes(ib.mats[0..ib.n]));
        }
        const o = &scene.objects[i];
        h = sc.meshHash(h, if (o.mesh) |mi| (if (scene.meshes[mi]) |*me| me else null) else null);
    }
    return fields.mix(h); // (the force fields)
}

// ---- frames -------------------------------------------------------------------------------

/// rb_frame: the simulation at that frame: none at or before the start
/// (objects back where they began); a cached frame played back; else stepped
/// on (or begun again when going back or when the key changed), each whole
/// frame reached kept in the cache, bodies into objects.
pub fn frame(f: f32) void {
    if (busy) return;
    busy = true;
    defer busy = false;
    const b = anim.cur orelse return gone();
    if (b.h.nrb == 0) return gone();
    const fr = @import("frange.zig").r;
    const start: f32 = @floatFromInt(fr.start);
    const k = key();
    const baked = sc.check(0, k, fr.start);
    if (!(f > start)) return none();
    var fi = cvtt(f);
    const fx: f32 = @floatFromInt(fi);
    var play = false;
    if (baked) {
        // baked: the frame (or the last)
        fi = @min(fi, sc.last(0));
        play = true;
    } else if (!rc.islive and f == fx) play = true;
    if (play) {
        if (sc.get(0, fi)) |r| {
            pbf = fi; // (rbinfo: this frame's counts)
            pbkey = k;
            capture();
            playRec(r);
            return;
        }
    }
    if (baked) return; // (baked, nothing there: as it is)
    var fresh = true;
    if (rc.on) {
        if (k == hash and f >= fnow) fresh = false else {
            // changed / going back: again
            free();
            restore();
        }
    }
    if (fresh) {
        build();
        if (!rc.on) return;
        hash = k;
        rc.time = 0;
        pendApply();
    }
    const t0 = nowMs();
    const fps: f32 = if (fr.fps > 0) fr.fps else 24.0;
    const target = (f - start) / fps;
    while (true) {
        if (!rc.islive) {
            // a whole frame reached: kept
            const nx = sc.last(0) +% 1;
            const xf: f32 = @floatFromInt(nx);
            if (!(xf > f)) {
                const t = (xf - start) / fps;
                var x1 = rc.dt * 0.5;
                x1 += rc.time;
                if (x1 >= t) {
                    if (record(nx)) continue;
                }
            }
        }
        var x = rc.dt * 0.5;
        x += rc.time;
        if (x >= target) break;
        step();
        rc.time += rc.dt;
    }
    ms = @floatFromInt(nowMs() - t0);
    fnow = f;
    pbf = -1; // (rbinfo: live)
    writeback();
    app.dirty = true;
}

/// No bodies: nothing cached.
fn gone() void {
    sc.clear(0);
    none();
}
/// No simulation: objects as they began.
fn none() void {
    pbf = -1;
    free();
    restore();
}

/// rb_live: play mode: the simulation runs live (no cached frames played or
/// kept); either way it is made again from the start at the next frame.
pub fn live(on: bool) void {
    rc.islive = on;
    hash = 0;
    npend = 0;
}

/// rb_pend_apply: the impulses waiting for the bodies.
fn pendApply() void {
    for (pend[0..npend]) |p| {
        if (p.shatter) {
            _ = shatterObj(p.oid);
        } else _ = impulseNow(p.oid, p.imp);
    }
    npend = 0;
}

/// rb_shatter_obj: its pieces take its place at the next step (an original
/// shattering on impact; a logic graph's Shatter); true when it will (before
/// the bodies are made: when they are).
pub fn shatterObj(oid: u32) bool {
    if (rc.on) return rbimp.shatterNow(oid);
    if (npend >= 16) return false;
    pend[npend] = .{ .oid = oid, .imp = rc.qid, .shatter = true };
    npend += 1;
    return true;
}

/// rb_impulse: true when it is a moving body: its velocity changes by
/// impulse / mass, and it wakes (before the bodies are made: when they are).
pub fn impulse(oid: u32, imp: V4) bool {
    if (rc.on) return impulseNow(oid, imp);
    if (npend >= 16) return false;
    pend[npend] = .{ .oid = oid, .imp = imp, .shatter = false };
    npend += 1;
    return true;
}
fn impulseNow(oid: u32, imp: V4) bool {
    if (!rc.on) return false;
    for (rc.bd[0..rc.nb]) |*x| {
        if (x.obj != oid) continue;
        if (x.typ != 1) return false;
        x.v = rc.andXyz(rc.splat(x.im) * imp) + x.v;
        x.asleep = 0;
        x.sleep = 0;
        return true;
    }
    return false;
}

const atan2f = @import("mech.zig").atan2f;

/// body_pose: its object's place: loc = P - R com, the rotation as Euler
/// angles (pose_from_mat of [R | loc]).
fn bodyPose(x: *const Body) [6]f32 {
    const loc: [4]f32 = x.pos - rc.mv3(&x.r, x.com);
    var a: [12]f32 = undefined;
    for (0..3) |r| {
        a[r * 4] = x.r[r][0];
        a[r * 4 + 1] = x.r[r][1];
        a[r * 4 + 2] = x.r[r][2];
        a[r * 4 + 3] = loc[r];
    }
    var m: [9]f32 = undefined;
    for (0..3) |c| {
        var l = a[c] * a[c];
        l += a[4 + c] * a[4 + c];
        l += a[8 + c] * a[8 + c];
        l = @sqrt(l);
        l = rc.maxss(l, 1.0e-8);
        m[c] = a[c] / l;
        m[3 + c] = a[4 + c] / l;
        m[6 + c] = a[8 + c] / l;
    }
    var o: [6]f32 = undefined;
    o[0] = a[3];
    o[1] = a[7];
    o[2] = a[11];
    var hy = m[0] * m[0];
    hy += m[3] * m[3];
    o[4] = atan2f(0.0 - m[6], @sqrt(hy));
    o[3] = atan2f(m[7], m[8]);
    o[5] = atan2f(m[3], m[0]);
    return o;
}

/// writeback: each moving body's place into its object.
fn writeback() void {
    if (rc.nb == 0) return;
    for (rc.bd[0 .. rc.nb - 1]) |*x| {
        if (x.typ != 1 or x.obj == 0) continue;
        if (x.inst != 0) { // an instance: its matrix
            instWriteback(x);
            continue;
        }
        const i = scene.findOid(x.obj) orelse continue;
        const p = bodyPose(x);
        putPlace(i, p[0..3].*, p[3..6].*, null);
    }
    rbiTouch();
}

/// rb_record: the moving bodies' places into the cache: the objects' count,
/// the instances' count, then uid, loc, rot each object; uid, index, matrix
/// each instance; the shattering ones' count, then uid, broken each.
/// False when not kept.
fn record(f: i32) bool {
    var no: u32 = 0;
    var ni: u32 = 0;
    for (rc.bd[0 .. rc.nb - 1]) |*x| {
        if (x.typ == 1 and x.obj != 0) {
            if (x.inst == 0) no += 1 else ni += 1;
        }
    }
    const nimp: u32 = rbimp.nimp;
    const r = sc.add(0, f, no * 28 + ni * 56 + nimp * 8 + 12) orelse return false;
    wrU(r, 0, no);
    wrU(r, 4, ni);
    var p: usize = 8;
    var pi: usize = 8 + @as(usize, no) * 28; // (where the instances go)
    for (rc.bd[0 .. rc.nb - 1]) |*x| {
        if (x.typ != 1 or x.obj == 0) continue;
        if (x.inst != 0) { // an instance: uid, index, matrix
            wrU(r, pi, uidOf(x.obj));
            wrU(r, pi + 4, x.inst - 1);
            const mt = instMatrix(x);
            @memcpy(r[pi + 8 ..][0..48], std.mem.asBytes(&mt));
            pi += 56;
            continue;
        }
        wrU(r, p, uidOf(x.obj));
        const q = bodyPose(x);
        for (0..6) |k| wrF(r, p + 4 + k * 4, q[k]);
        p += 28;
    }
    wrU(r, pi, nimp); // the shattering ones: original, broken - each
    pi += 4;
    for (rbimp.imp[0..nimp]) |*g| {
        wrU(r, pi, uidOf(rc.bd[g.body].obj));
        wrU(r, pi + 4, g.on);
        pi += 8;
    }
    statKeep(f);
    return true;
}

/// rb_play: a cached frame's places into the objects. (A record from a
/// damaged file is read only as far as it goes: the original reads past it.)
fn playRec(r: []const u8) void {
    if (r.len < 8) return;
    const no = rdU(r, 0);
    const ni = rdU(r, 4);
    var p: usize = 8;
    var k: u32 = 0;
    while (k < no) : (k += 1) {
        if (p + 28 > r.len) return;
        const u = rdU(r, p);
        if (scene.findUid(u)) |i| {
            putPlace(i, rc.rd3(r, p + 4), rc.rd3(r, p + 16), null);
        }
        p += 28;
    }
    k = 0; // instances: into their object's mesh
    while (k < ni) : (k += 1) {
        if (p + 56 > r.len) return;
        if (scene.findUid(rdU(r, p))) |i| {
            if (rbiMake(i)) |e| {
                const idx = rdU(r, p + 4);
                if (idx < e.blk.n) @memcpy(std.mem.asBytes(&e.blk.mats[idx]), r[p + 8 ..][0..48]);
            }
        }
        p += 56;
    }
    // the shattering ones: whole or broken
    if (p + 4 <= r.len) {
        var n = rdU(r, p);
        p += 4;
        if (n <= rbimp.IMP_MAX) {
            while (n > 0) : (n -= 1) {
                if (p + 8 > r.len) break;
                if (scene.findUid(rdU(r, p))) |i| rbimp.show(i, rdU(r, p + 4) != 0);
                p += 8;
            }
        }
    }
    rbiTouch();
    app.dirty = true;
}

// ---- instances as bodies -------------------------------------------------------------------

const ib_ = @import("inst.zig");

/// An object whose instances are bodies: the block shown while they move (its
/// own: the same instances), the object's inverse matrix.
const Rbi = struct { oid: u32, blk: *ib_.Block, winv: [12]f32 };
var rbi_tab: [64]Rbi = undefined;
var rbi_n: u32 = 0;

/// rb_inst_mesh: the instances object oid shows while they move (null:
/// none, or the evaluation asked without them).
pub fn movingInstances(oid: u32) ?*ib_.Block {
    if (noinst) return null;
    for (rbi_tab[0..rbi_n]) |*e| {
        if (e.oid == oid) return e.blk;
    }
    return null;
}

fn rbiFind(oid: u32) ?*Rbi {
    for (rbi_tab[0..rbi_n]) |*e| {
        if (e.oid == oid) return e;
    }
    return null;
}

/// obj_matrix: rotation rows (x87), the columns scaled, the place.
fn objMatrix(i: usize) [12]f32 {
    const o = &scene.objects[i];
    var rows: [3]V4 = undefined;
    shape.rotRows(o.radians(), &rows);
    var m: [12]f32 = undefined;
    for (0..3) |r| {
        const a: [4]f32 = rows[r];
        m[r * 4] = o.scl[0] * a[0];
        m[r * 4 + 1] = o.scl[1] * a[1];
        m[r * 4 + 2] = o.scl[2] * a[2];
        m[r * 4 + 3] = o.loc[r];
    }
    return m;
}

/// m34_inv_obj: the inverse of the object's matrix (the adjugate over the
/// determinant; a singular one over 1e-9).
fn invObj(i: usize) [12]f32 {
    const w = objMatrix(i);
    const a: V4 = .{ w[0], w[1], w[2], 0 };
    const b: V4 = .{ w[4], w[5], w[6], 0 };
    const c: V4 = .{ w[8], w[9], w[10], 0 };
    var c0 = rc.cross(b, c);
    var c1 = rc.cross(c, a);
    var c2 = rc.cross(a, b);
    var det = rc.dot3(a, c0);
    if (!(@abs(det) > 1.0e-9)) det = 1.0e-9;
    const k: V4 = @splat(1.0 / det);
    c0 *= k;
    c1 *= k;
    c2 *= k;
    const ca: [4]f32 = c0;
    const cb: [4]f32 = c1;
    const cc: [4]f32 = c2;
    var o: [12]f32 = undefined;
    for (0..3) |r| {
        o[r * 4] = ca[r];
        o[r * 4 + 1] = cb[r];
        o[r * 4 + 2] = cc[r];
        var t = o[r * 4] * w[3];
        t += o[r * 4 + 1] * w[7];
        t += o[r * 4 + 2] * w[11];
        o[r * 4 + 3] = -t;
    }
    return o;
}

/// rbi_make: object i's entry (made when new: its evaluated instances in a
/// block of its own), or null.
fn rbiMake(i: usize) ?*Rbi {
    const oid = scene.objects[i].oid;
    if (rbiFind(oid)) |e| return e;
    if (rbi_n >= rbi_tab.len) return null;
    const was = noinst;
    noinst = true;
    const src = mods.instancesOf(i);
    noinst = was;
    const b = src orelse return null;
    const ident: [12]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    const nb = ib_.xform(b, &ident) orelse return null;
    rbi_tab[rbi_n] = .{ .oid = oid, .blk = nb, .winv = invObj(i) };
    rbi_n += 1;
    return &rbi_tab[rbi_n - 1];
}

/// rbi_drop: no moving instances (their objects show their meshes again).
fn rbiDrop() void {
    for (rbi_tab[0..rbi_n]) |*e| ib_.unref(e.blk);
    if (rbi_n != 0) {
        rbi_n = 0;
        ib_.ver +%= 1;
        app.dirty = true;
    }
}

/// rbi_touch: the moving instances changed.
fn rbiTouch() void {
    if (rbi_n != 0) ib_.ver +%= 1;
}

/// inst_bodies: one body per instance of object i's mesh (from body index
/// `first`, at most `room`), its prototype placed by the object's matrix times
/// the instance's (rotation and scale split: the columns' lengths).
fn instBodies(first: u32, room: u32, r: []u8, i: usize) u32 {
    const e = rbiMake(i) orelse return 0;
    const b = e.blk;
    const w = objMatrix(i);
    var made: u32 = 0;
    for (0..b.n) |k| {
        if (first + made >= room) break;
        const cm = ib_.mul(&w, &b.mats[k]);
        var scl: [4]f32 = .{ 0, 0, 0, 0 };
        for (0..3) |c| {
            var x = cm[c] * cm[c];
            x += cm[4 + c] * cm[4 + c];
            x += cm[8 + c] * cm[8 + c];
            if (!(x > 1e-12)) x = 1e-12;
            scl[c] = @sqrt(x);
        }
        var rows: [3]V4 = undefined;
        var loc: [4]f32 = .{ 0, 0, 0, 0 };
        for (0..3) |row| {
            rows[row] = .{ cm[row * 4] / scl[0], cm[row * 4 + 1] / scl[1], cm[row * 4 + 2] / scl[2], 0 };
            loc[row] = cm[row * 4 + 3];
        }
        const g = b.proto[b.pids[k] & 7] orelse continue;
        const b0 = @import("fmesh.zig").bbox(g.verts);
        const mv = shape.MeshView{ .verts = g.verts, .tris = @import("geonodes.zig").trisOf(g), .lo = b0[0], .hi = b0[1] };
        shape.makeBodyEx(first + made, r, scene.objects[i].oid, &mv, &rows, loc, scl);
        rc.bd[first + made].inst = @intCast(k + 1);
        made += 1;
    }
    return made;
}

/// inst_matrix: a body's instance matrix: W^-1 [R diag(s) | P - R com].
fn instMatrix(x: *const Body) [12]f32 {
    const rcm: [4]f32 = .{ rc.dot3(x.r[0], x.com), rc.dot3(x.r[1], x.com), rc.dot3(x.r[2], x.com), 0 };
    const loc: [4]f32 = x.pos - @as(V4, rcm);
    var m: [12]f32 = undefined;
    for (0..3) |row| {
        const a: [4]f32 = x.r[row] * x.scl;
        m[row * 4] = a[0];
        m[row * 4 + 1] = a[1];
        m[row * 4 + 2] = a[2];
        m[row * 4 + 3] = loc[row];
    }
    const e = rbiFind(x.obj) orelse return m;
    return ib_.mul(&e.winv, &m);
}

/// inst_writeback: its matrix into the moving block.
fn instWriteback(x: *const Body) void {
    const e = rbiFind(x.obj) orelse return;
    if (x.inst == 0 or x.inst > e.blk.n) return;
    e.blk.mats[x.inst - 1] = instMatrix(x);
}

// ---- rbinfo -----------------------------------------------------------------------------

/// rb_info: 0 bodies, 1 contact points, 2 awake, 3 islands, 4 the last
/// frame's simulation (ms), 5 manifolds, 6 steps, 7 parts, 8-13 ms in the
/// broad phase, narrow, islands, solving, the hash, compacting, 14 pairs that
/// found no manifold, 15 joints broken, 16 every body's place, turn and
/// speeds hashed, 17 the fastest awake body's speed, 18 its object's uid, 19
/// joints, 20-21 shattering, 22-24 attractors (nbody), 25: 1 when the frame
/// shown was played from the cache (the counts then are those kept with it);
/// 1000 + 4 i + c: contact point i's place on A (c 0-2), gap (3).
pub fn info(what: u32) f32 {
    if (what == 25) return if (pbf >= 0) 1 else 0;
    if (pbf < 0) return infoLive(what);
    const f: u32 = @bitCast(pbf);
    if (f >= RBS_N or !st_init) return 0;
    const s = &st[f];
    if (s.key != pbkey) return 0;
    for (rbs_keys, 0..) |kk, i| {
        if (kk == what) return s.v[i];
    }
    return 0;
}

/// rb_stat_keep: the simulation's counts now, kept with the frame.
fn statKeep(f: i32) void {
    if (f < 0 or f >= RBS_N) return;
    if (!st_init) {
        st = std.mem.zeroes(@TypeOf(st));
        st_init = true;
    }
    const s = &st[@intCast(f)];
    s.key = hash;
    for (rbs_keys, 0..) |kk, i| s.v[i] = infoLive(kk);
}

fn infoLive(what: u32) f32 {
    if (!rc.on) return 0;
    if (what >= 1000) {
        var i = (what - 1000) >> 2;
        const c = (what - 1000) & 3;
        for (rc.mf[0..rc.nmf]) |*m| {
            if (i < m.n) {
                const p = &m.pts[i];
                const wa: [4]f32 = p.wa;
                return if (c == 3) p.sep else wa[c];
            }
            i -= m.n;
        }
        return 0;
    }
    const n: u32 = switch (what) {
        0 => rc.nb - 1,
        1 => blk: {
            var t: u32 = 0;
            for (rc.mf[0..rc.nmf]) |*m| t +%= m.n;
            break :blk t;
        },
        2 => blk: {
            var t: u32 = 0;
            for (rc.bd[0..rc.nb]) |*x| {
                if (x.typ == 1 and x.asleep == 0) t += 1;
            }
            break :blk t;
        },
        3 => rc.nisl,
        4 => return ms,
        5 => rc.nmf,
        7 => rc.npt,
        14 => rc.mffull,
        15 => rc.nbroken,
        19 => rc.njr,
        20 => rbimp.nimp, // shattering on impact,
        21 => rbimp.broken(), // of them broken
        22, 23, 24 => return nbody.info(what - 22),
        16 => blk: {
            // FNV-1a over each body's place, turn and speeds (24 bits: exact)
            var hh: u32 = 0x811c9dc5;
            for (rc.bd[0..rc.nb]) |*x| {
                const v: [4]V4 = .{ x.pos, x.q, x.v, x.w };
                const bytes: *const [64]u8 = @ptrCast(&v);
                for (bytes) |c| {
                    hh ^= c;
                    hh *%= 0x01000193;
                }
            }
            break :blk (hh ^ (hh >> 24)) & 0xffffff;
        },
        17, 18 => {
            // the most: v^2 + (w r)^2
            var best: f32 = 0;
            var uid: u32 = 0;
            for (rc.bd[0..rc.nb]) |*x| {
                if (x.typ != 1 or x.asleep != 0) continue;
                var e = rc.dot3(x.v, x.v);
                const d = x.max - x.min;
                var r2 = rc.dot3(d, d);
                r2 *= 0.25;
                r2 *= rc.dot3(x.w, x.w);
                e += r2;
                if (e > best) {
                    best = e;
                    uid = uidOf(x.obj);
                }
            }
            if (what == 18) return @floatFromInt(uid);
            return @sqrt(best);
        },
        8...13 => {
            const t: f64 = @floatFromInt(@as(i64, @bitCast(rc.tns[what - 8])));
            return @floatCast(t / 1000000.0);
        },
        else => rc.stepno,
    };
    return @floatFromInt(@as(i32, @bitCast(n)));
}

/// What the Physics tab's status shows (physui.zig).
pub fn isOn() bool {
    return rc.on;
}

// ---- the operators ------------------------------------------------------------------------

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
    /// im_next_word: the next word (spaces part them): its length.
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
    /// rb_num: the next word, a number.
    fn num(c: *Cur) ?f32 {
        if (c.next() == 0) return null;
        return @import("mech.zig").parseFloat(word());
    }
    /// rb_vec3: three numbers.
    fn vec3(c: *Cur, out: *[3]f32) bool {
        for (0..3) |k| out[k] = c.num() orelse return false;
        return true;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn wordIndex(w: []const u8, names: []const []const u8) ?usize {
    for (names, 0..) |n, k| if (eq(w, n)) return k;
    return null;
}

/// cvttss2si.
fn cvtts(x: f32) i32 {
    return cvtt(x);
}

const shape_names = [_][]const u8{ "box", "sphere", "capsule", "hull", "compound", "mesh", "plane" };
const rb_keys = [_][]const u8{ "mass", "friction", "bounce", "damping" };
const pm_names = [_][]const u8{ "default", "rubber", "ice", "wood", "metal", "stone" };
const pm_vals = [_][2]f32{ .{ 0.5, 0.0 }, .{ 0.9, 0.8 }, .{ 0.02, 0.05 }, .{ 0.5, 0.3 }, .{ 0.35, 0.15 }, .{ 0.7, 0.1 } };
const jt_names = [_][]const u8{ "-", "fixed", "hinge", "point", "slider" };
pub const s_rb_bad = "  rigid.add [active|passive] [box|sphere|capsule|hull|compound] [mass m] [friction f] [bounce b] [damping d] - not understood: ";
const s_rb_none = "  select mesh objects to make rigid bodies";
const s_rb_full = "  no room for more rigid bodies / joints";
const s_jt_bad = "  rigid.joint <fixed|hinge|point|slider> <object> <object|world> [pivot x y z] [axis x y z] [break force] [limits lo hi] [motor speed force] - not understood: ";
const s_rw_bad = "  rigid.world [gravity x y z] [rate n] [iterations n] [substeps n] - not understood: ";

fn drop(parts: []const []const u8) void {
    say(parts);
    undo.replaceCurrent();
}

/// rb_find: the record of this object, or null.
fn find(b: *anim.Block, oid: u32) ?usize {
    for (0..nrb(b)) |k| {
        if (rdU(rec(b, k), rc.RB_UID) == oid) return k;
    }
    return null;
}

/// The records' bytes to this many (anim.zig writes them all: exactly
/// those in use).
fn resize(slice: *[]u8, bytes: usize) bool {
    if (slice.len == bytes) return true;
    if (bytes == 0) {
        if (slice.len > 0) AL.free(slice.*);
        slice.* = &.{};
        return true;
    }
    const nw = AL.alloc(u8, bytes) catch return false;
    const keep = @min(bytes, slice.len);
    @memcpy(nw[0..keep], slice.*[0..keep]);
    @memset(nw[keep..], 0);
    if (slice.len > 0) AL.free(slice.*);
    slice.* = nw;
    return true;
}

/// A record more (zeroed); null when there is no room.
fn grow(slice: *[]u8, n: u32, sz: usize, max: u32) ?[]u8 {
    if (n >= max) return null;
    if (!resize(slice, (@as(usize, n) + 1) * sz)) return null;
    const r = slice.*[@as(usize, n) * sz ..][0..sz];
    @memset(r, 0);
    return r;
}

/// rigid.add [active|passive] [shape] [instances|object] [key value ...]
fn opAdd() void {
    var typ: u32 = 1;
    var shp: u32 = 0;
    var vals: [4]f32 = .{ 1.0, rx_fric, 0, 0 }; // mass friction bounce damping
    var given: u32 = 0;
    var inst: u32 = 0;
    var vel: [3]f32 = .{ 0, 0, 0 };
    var grp: u32 = 0;
    var ign: u32 = 0;
    var attr: u32 = 0;
    var c = Cur{ .s = ops.arg };
    while (c.next() != 0) {
        const w = word();
        if (eq(w, "active")) {
            typ = 1;
            given |= 1;
        } else if (eq(w, "passive")) {
            typ = 2;
            given |= 1;
        } else if (eq(w, "instances")) {
            inst = 2;
            given |= 64;
        } else if (eq(w, "object")) {
            inst = 0;
            given |= 64;
        } else if (eq(w, "velocity")) {
            if (!c.vec3(&vel)) return drop(&.{ s_rb_bad, word() });
            given |= 128;
        } else if (eq(w, "group")) {
            const x = c.num() orelse return drop(&.{ s_rb_bad, word() });
            grp = @as(u32, @bitCast(cvtts(x))) & 15;
            given |= 256;
        } else if (eq(w, "collide")) {
            const x = c.num() orelse return drop(&.{ s_rb_bad, word() });
            ign = ~@as(u32, @bitCast(cvtts(x))) & 0xffff;
            given |= 512;
        } else if (eq(w, "material")) {
            if (c.next() == 0) return drop(&.{ s_rb_bad, word() });
            const k = wordIndex(word(), &pm_names) orelse return drop(&.{ s_rb_bad, word() });
            vals[1] = pm_vals[k][0];
            vals[2] = pm_vals[k][1];
            given |= 8 | 16;
        } else if (eq(w, "fit")) {
            given |= 2048;
        } else if (eq(w, "attracts")) {
            attr = rc.RBF_ATTR;
            given |= 1024;
        } else if (eq(w, "noattract")) {
            attr = 0;
            given |= 1024;
        } else if (wordIndex(w, &shape_names)) |k| {
            shp = @intCast(k);
            given |= 2;
        } else {
            const k = wordIndex(w, &rb_keys) orelse return drop(&.{ s_rb_bad, word() });
            const x = c.num() orelse return drop(&.{ s_rb_bad, word() });
            vals[k] = rc.maxss(x, 0);
            given |= @as(u32, 1) << @intCast(k + 2);
        }
    }
    const b = anim.own(0) orelse return drop(&.{s_rb_full});
    var done: u32 = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (!o.selected or !isMeshType(o.kind)) continue;
        const r = if (find(b, o.oid)) |k| rec(b, k) else blk: {
            // a new entry: the defaults
            const r = grow(&b.rb, nrb(b), RB_SZ, rc.RB_MAX) orelse return drop(&.{s_rb_full});
            b.h.nrb = nrb(b) + 1;
            wrU(r, rc.RB_UID, o.oid);
            wrU(r, rc.RB_TYPE, 1);
            wrF(r, rc.RB_MASS, 1.0);
            wrF(r, rc.RB_FRIC, rx_fric);
            if (given & 2048 != 0) wrU(r, rc.RB_SHAPE, 3); // (fit: a convex hull)
            break :blk r;
        };
        if (given & 1 != 0) wrU(r, rc.RB_TYPE, typ);
        if (given & 2 != 0) wrU(r, rc.RB_SHAPE, shp);
        for (0..4) |k| {
            if (given >> @intCast(k + 2) & 1 != 0) wrF(r, rc.RB_MASS + k * 4, vals[k]);
        }
        var fl = rdU(r, rc.RB_FLAGS);
        if (given & 64 != 0) fl = (fl & ~@as(u32, 2)) | inst;
        if (given & 128 != 0) {
            for (0..3) |k| wrF(r, rc.RB_VEL + k * 4, vel[k]);
        }
        if (given & 256 != 0) fl = (fl & ~@as(u32, 15 << rc.RBF_GRP)) | grp << rc.RBF_GRP;
        if (given & 512 != 0) fl = (fl & 0xffff) | ign << rc.RBF_IGN;
        if (given & 1024 != 0) fl = (fl & ~@as(u32, rc.RBF_ATTR)) | attr;
        fl &= ~@as(u32, 1); // (its start: from where it is)
        wrU(r, rc.RB_FLAGS, fl);
        done += 1;
    }
    if (done == 0) return drop(&.{s_rb_none});
    var nb: [16]u8 = undefined;
    say(&.{ "  rigid bodies: ", std.fmt.bufPrint(&nb, "{d}", .{b.h.nrb}) catch "" });
}

/// rigid.remove: the selected objects' entries (and their joints) go.
fn opRemove() void {
    const b = anim.own(0) orelse return;
    free(); // (back to the start first)
    restore();
    for (scene.objects[0..scene.count]) |*o| {
        if (!o.selected) continue;
        const oid = o.oid;
        if (find(b, oid)) |k| {
            // the entry: the last into its place
            const n = nrb(b) - 1;
            b.h.nrb = n;
            std.mem.copyForwards(u8, rec(b, k), b.rb[n * RB_SZ ..][0..RB_SZ]);
            _ = resize(&b.rb, n * RB_SZ);
        }
        var j: u32 = 0;
        while (j < njt(b)) {
            const r = b.jt[j * JT_SZ ..][0..JT_SZ];
            if (rdU(r, rc.JT_A) == oid or rdU(r, rc.JT_B) == oid) {
                const n = njt(b) - 1;
                b.h.njt = n;
                std.mem.copyForwards(u8, r, b.jt[n * JT_SZ ..][0..JT_SZ]);
                _ = resize(&b.jt, n * JT_SZ);
                continue;
            }
            j += 1;
        }
    }
}

/// rigid.joint <type> <a> <b|world> [pivot x y z] [axis x y z] [break f]
/// [limits lo hi] [motor speed force]
fn opJoint() void {
    var r: [JT_SZ]u8 = @splat(0);
    wrF(&r, rc.JT_AXIS + 4, 1.0);
    var c = Cur{ .s = ops.arg };
    _ = c.next();
    const t = wordIndex(word(), &jt_names) orelse 0;
    if (t == 0) return drop(&.{ s_jt_bad, word() });
    wrU(&r, rc.JT_TYPE, @intCast(t));
    _ = c.next();
    const ai = objNamed(word()) orelse return drop(&.{ s_jt_bad, word() });
    const a = &scene.objects[ai];
    wrU(&r, rc.JT_A, a.oid);
    for (0..3) |k| wrF(&r, rc.JT_PIV + k * 4, a.loc[k]); // pivot: A's place
    _ = c.next();
    if (!eq(word(), "world")) {
        const bi = objNamed(word()) orelse return drop(&.{ s_jt_bad, word() });
        if (scene.objects[bi].oid == a.oid) return drop(&.{ s_jt_bad, word() });
        wrU(&r, rc.JT_B, scene.objects[bi].oid);
    }
    while (c.next() != 0) {
        const w = word();
        if (eq(w, "pivot") or eq(w, "axis")) {
            const o: usize = if (eq(w, "pivot")) rc.JT_PIV else rc.JT_AXIS;
            // (rb_vec3 writes each number as it reads it)
            for (0..3) |k| {
                const x = c.num() orelse return drop(&.{ s_jt_bad, word() });
                wrF(&r, o + k * 4, x);
            }
            continue;
        }
        if (eq(w, "break")) {
            const x = c.num() orelse return drop(&.{ s_jt_bad, word() });
            wrF(&r, rc.JT_BRK, x);
            continue;
        }
        const lim = eq(w, "limits");
        if (!lim and !eq(w, "motor")) return drop(&.{ s_jt_bad, word() });
        const o: usize = if (lim) rc.JT_LO else rc.JT_MSPD;
        wrU(&r, rc.JT_FLG, rdU(&r, rc.JT_FLG) | @as(u32, if (lim) 1 else 2));
        const hinge = rdU(&r, rc.JT_TYPE) == 2; // (a hinge's in degrees)
        var x = c.num() orelse return drop(&.{ s_jt_bad, word() });
        if (hinge) x *= rx_deg;
        wrF(&r, o, x);
        var y = c.num() orelse return drop(&.{ s_jt_bad, word() });
        if (lim and hinge) y *= rx_deg; // (a limit's second: an angle too; a motor's force: as it is)
        wrF(&r, o + 4, y);
    }
    const b = anim.own(0) orelse return drop(&.{s_rb_full});
    const nr = grow(&b.jt, njt(b), JT_SZ, rc.JT_MAX) orelse return drop(&.{s_rb_full});
    @memcpy(nr, &r);
    b.h.njt = njt(b) + 1;
}

/// obj_find: the object with exactly this name.
fn objNamed(nm: []const u8) ?usize {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (eq(o.name(), nm)) return i;
    }
    return null;
}

/// rigid.world [gravity x y z] [g n] [rate n] [iterations n] [substeps n]
fn opWorld() void {
    const b = anim.own(0) orelse return;
    const w = &b.h.rw;
    var c = Cur{ .s = ops.arg };
    while (c.next() != 0) {
        const x = word();
        if (eq(x, "gravity")) {
            for (0..3) |k| {
                const v = c.num() orelse return drop(&.{ s_rw_bad, word() });
                wrF(w, rc.RW_GRAV + k * 4, v);
            }
            wrU(w, rc.RW_SET, 1);
            continue;
        }
        if (eq(x, "g")) {
            const v = c.num() orelse return drop(&.{ s_rw_bad, word() });
            wrF(w, rc.RW_G, v);
            continue;
        }
        const o: usize = if (eq(x, "rate")) rc.RW_RATE else if (eq(x, "iterations")) rc.RW_ITER else if (eq(x, "substeps")) rc.RW_SUB else return drop(&.{ s_rw_bad, word() });
        const v = c.num() orelse return drop(&.{ s_rw_bad, word() });
        var n = cvtts(v);
        if (n < 1) n = 1;
        const hi: i32 = if (o == rc.RW_SUB) 64 else 1000;
        if (n > hi) n = hi;
        wrU(w, o, @bitCast(n));
    }
}

pub const list = .{
    .{ "rigid.add", ops.Impl{ .run = opAdd } },
    .{ "rigid.remove", ops.Impl{ .run = opRemove } },
    .{ "rigid.joint", ops.Impl{ .run = opJoint } },
    .{ "rigid.world", ops.Impl{ .run = opWorld } },
};

test "grid key and hash" {
    rc.gsh = 50;
    const g = grKey(.{ 0, 0, 0 });
    try std.testing.expectEqual(@as(u64, 0x100000 | 0x100000 << 21 | 0x100000 << 42), g.key);
    try std.testing.expectEqual(shape.jhKey(3, 1), shape.jhKey(1, 3));
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), cvtt(@floor(@as(f32, 1e30))));
}
