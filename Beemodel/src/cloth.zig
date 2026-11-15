// Cloth and soft bodies (cloth.s): XPBD.
//
// A cloth object's vertices become particles: stretch constraints on its
// triangles' edges, bend constraints between the far corners of each pair of
// triangles sharing an edge; a soft body adds one volume constraint (its
// closed mesh keeps its volume). Pinned vertices (the mesh's pin group,
// Mesh.pin) have no mass and follow the object. Colliders are other objects'
// triangles (and the Ground's); cloth keeps its thickness from them (a
// spatial hash), and from itself (a particle hash, neighbours in the rest
// shape left out). Gravity, force fields, and wind as drag on each triangle.
//
// Each frame's steps (60 a second) are cut into substeps (10), each
// predicting positions, then one pass over the constraints (XPBD: compliance,
// so stiffness does not depend on the step), then the collisions, then
// velocities from the motion. Constraints are coloured so no two in a batch
// share a particle; big batches run in parallel (the result is the same on
// any number of threads: nothing a worker writes is read by another).
//
// Like rigid bodies it runs on the timeline from the scene's start; what an
// object shows (mods.of) is its simulated mesh while it runs. Each whole frame
// reached is kept in the simulation cache (simcache.zig, channel 1: the shown
// vertices quantized to 16 bits within their bounds) and played back from it.
//
// The settings live in the animation block's rest (anim.zig: the cloth world
// at REST_CW, the objects' records at REST_CL), so undo and files carry them;
// the pins are the mesh's (the MPIN chunk). Every number goes through the
// original's single-precision operations in its order (rbcore.zig's helpers),
// so the vertices match it to the bit.
//
// A landscape collider (la_of) collides by its heights, not its triangles
// (cx_hf, pt_hf: up to four, placed by location and scale). Play mode's
// particle test (pt_tri) is here for play.zig to use.
const std = @import("std");
const rc = @import("rbcore.zig");
const app = @import("app.zig");
const anim = @import("anim.zig");
const scene = @import("scene.zig");
const mods = @import("mods.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const sc = @import("simcache.zig");
const jobs = @import("jobs.zig");
const fields = @import("fields.zig");
const collide = @import("collide.zig");
const frange = @import("frange.zig");
const preview = @import("preview.zig");
const landscape = @import("landscape.zig");
const A = @import("alloc.zig").A;

const V4 = rc.V4;
const dot3 = rc.dot3;
const cross = rc.cross;
const andXyz = rc.andXyz;
const splat = rc.splat;
const minps = rc.minps;
const maxps = rc.maxps;
const minss = rc.minss;
const maxss = rc.maxss;

// ---- the records (the block's rest) ------------------------------------------------

pub const REST_CW = 13312;
pub const CW_WIND = 0; // wind (3 floats)
pub const CW_SUB = 12; // substeps (0: 10)
pub const CW_RATE = 16; // steps a second (0: 60)
pub const CW_N = 20; // objects
pub const CW_SZ = 32;
pub const REST_CL = 13344;
pub const CL_SZ = 64;
pub const CL_MAX = 32;
pub const CL_UID = 0; // (an oid in memory, a uid in files: anim.zig)
pub const CL_TYPE = 4; // 1 cloth, 2 soft body, 3 collider
pub const CL_STRETCH = 8; // compliances (m/N)
pub const CL_BEND = 12;
pub const CL_VOL = 16;
pub const CL_MASS = 20; // its mass (all of it)
pub const CL_DAMP = 24;
pub const CL_THICK = 28;
pub const CL_FRIC = 32;
pub const CL_FLAGS = 36; // 1: collides with itself

const NCOL = 65; // colours (the last: the rest, serial)
const CR_MAX = 32;

// ---- constants (rodata) ---------------------------------------------------------------

const q16: V4 = .{ 65535, 65535, 65535, 0 };
const inv16: V4 = .{ 1.5259022e-5, 1.5259022e-5, 1.5259022e-5, 0 };
const tiny4: V4 = .{ 1e-12, 1e-12, 1e-12, 1e-12 };
const third4: V4 = .{ 0.33333334, 0.33333334, 0.33333334, 0 };
const pad4: V4 = .{ 0.05, 0.05, 0.05, 0 };
const cq_one: f32 = 1.0;
const cq_tiny: f32 = 1.0e-9;
const cq_cross: f32 = 1.0e-8; // (1e-4 m)^2: s on the triangle
const cq_inside: f32 = 0.999;
const cq_smooth: f32 = 0.9; // an edge, not a corner
const cq_ecap: f32 = 0.01; // cl_edges: a push a substep at most
const cq_emarg: f32 = 0.01; //  and the boxes' margin
const cq_eps: f32 = 1.0e-12;
const cq_third: f32 = 0.33333334;
const cq_sixth: f32 = 0.16666667;
const cq_half: f32 = 0.5;
const cq_drag: f32 = 0.6; // wind: drag x area x the speed into it
const cq_cell: f32 = 0.05;
const cq_neigh: f32 = 1.5;
const HX: u32 = 92837111;
const HY: u32 = 689287499;
const HZ: u32 = 283923481;

// ---- runtime ------------------------------------------------------------------------------

/// A cloth (CR_*).
const Cr = struct {
    oid: u32 = 0, // its object (the original: a pointer)
    typ: u32 = 0,
    p0: u32 = 0, // its particles
    np: u32 = 0,
    t0: u32 = 0, // its triangles
    nt: u32 = 0,
    out: scene.Mesh = undefined, // what it shows (ours)
    has_out: bool = false,
    kept: preview.Kept = .{}, // its corner normals
    v0: f32 = 0, // rest volume
    volc: f32 = 0,
    thick: f32 = 0,
    fric: f32 = 0,
    damp: f32 = 0,
    self: u32 = 0,
    mat: [12]f32 = @splat(0), // its object's matrix this step
};

/// A distance constraint: i, j, rest, compliance.
const Dc = extern struct { i: u32, j: u32, rest: f32, comp: f32 };
/// A collider triangle: corners, unit normal (w 0), its corner edges (bit k: k, k+1).
const Ct = struct { p: [3]V4, n: V4, edges: u32 };

var on = false;
var nc: u32 = 0; // cloths
var np: u32 = 0; // particles
var nd: u32 = 0; // distance constraints
var nt: u32 = 0; // triangles
var nct: u32 = 0; // collider triangles
var capct: u32 = 0;
var self_any: u32 = 0; // any cloth colliding with itself
var nsub: u32 = 0;
var hmask: u32 = 0; // the hashes' sizes - 1
var smask: u32 = 0;
var nbig: u32 = 0;
/// A landscape collider (cx_hf): its block, location, scale (w 0).
const Hf = struct { b: *landscape.Block, loc: V4, scl: V4 };
var nhf: u32 = 0;
var hf: [4]Hf = undefined;

var x: []V4 = &.{}; // positions (w: inverse mass)
var xp: []V4 = &.{}; // before the substep
var vel: []V4 = &.{};
var rest: []V4 = &.{}; // rest (object space; w: pinned)
var own: []u32 = &.{}; // its cloth
var dc: []Dc = &.{}; // constraints (by colour)
var bs: [NCOL + 2]u32 = @splat(0); // colour starts
var tr: [][3]u32 = &.{}; // triangles
var ct: []Ct = &.{}; // collider triangles
var cell: []u32 = &.{}; // a hash: starts (size + 1),
var ent: []u32 = &.{}; //  entries
var scell: []u32 = &.{}; // self: starts,
var sent: []u32 = &.{}; //  particles
var gr: []V4 = &.{}; // volume gradients / self pushes
var big: []u32 = &.{}; // collider triangles too big to hash

var hash: u64 = 0; // the settings simulated
var fnow: f32 = 0;
var time: f32 = 0;
var dt: f32 = 0;
var hs: f32 = 0; // a substep
var icell: V4 = @splat(0);
var sinv: V4 = @splat(0);
var ms: f32 = 0;
var hits = std.atomic.Value(u32).init(0);
var busy = false;
var bat: u32 = 0; // the batch being solved
var g: V4 = @splat(0);
var wind_w: V4 = @splat(0);
var cr: [CR_MAX]Cr = @splat(.{});
var shown_n: u32 = 0; // (the viewport's key: moves when a cloth's shown mesh does)
var out_serials: u32 = 0;

// ---- small helpers --------------------------------------------------------------------------

/// cvttss2si: out of range or NaN is the minimum.
fn cvtt(v: f32) i32 {
    if (v >= -2147483648.0 and v < 2147483648.0) return @intFromFloat(v);
    return std.math.minInt(i32);
}

/// cvtps2dq: to the nearest, ties to even (out of range: the minimum).
fn cvtn(v: f32) i32 {
    if (!(v >= -2147483648.0 and v < 2147483648.0)) return std.math.minInt(i32);
    const f = @floor(v);
    const d = v - f;
    var r: i32 = @intFromFloat(f);
    if (d > 0.5 or (d == 0.5 and r & 1 != 0)) r += 1;
    return r;
}

/// CELL: the cell of p (floor of p / size).
fn cellOf(p: V4, inv: V4) [3]i32 {
    const q = p * inv;
    return .{ cvtt(@floor(q[0])), cvtt(@floor(q[1])), cvtt(@floor(q[2])) };
}

/// cell_slot.
fn slotOf(c: [3]i32, mask: u32) u32 {
    const a: u32 = @bitCast(c[0]);
    const b: u32 = @bitCast(c[1]);
    const d: u32 = @bitCast(c[2]);
    return ((a *% HX) ^ (b *% HY) ^ (d *% HZ)) & mask;
}

fn ld3(p: [3]f32) V4 {
    return .{ p[0], p[1], p[2], 0 };
}

fn wOf(v: V4) f32 {
    return v[3];
}

fn rd(r: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, r[o..][0..4], .little);
}
fn wr(r: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, r[o..][0..4], v, .little);
}
fn rdf(r: []const u8, o: usize) f32 {
    return @bitCast(rd(r, o));
}
fn wrf(r: []u8, o: usize, v: f32) void {
    wr(r, o, @bitCast(v));
}

/// The block's cloth objects (CW_N, at most CL_MAX: a damaged file's count
/// past it is not read past the records).
fn ncl(b: *const anim.Block) u32 {
    return @min(rd(&b.rest, REST_CW + CW_N), CL_MAX);
}
fn entry(b: *anim.Block, k: usize) []u8 {
    return b.rest[REST_CL + k * CL_SZ ..][0..CL_SZ];
}

/// The file's OT_MESH.
fn isMeshType(k: scene.Kind) bool {
    return k.isMesh();
}

/// cl_entry_obj: its mesh object (by index), or null.
fn entryObj(r: []const u8) ?usize {
    if (rd(r, CL_TYPE) == 0) return null;
    const i = scene.findOid(rd(r, CL_UID)) orelse return null;
    const o = &scene.objects[i];
    if (!isMeshType(o.kind)) return null;
    if (o.mesh == null or scene.meshes[o.mesh.?] == null) return null;
    return i;
}

/// obj_matrix: T Rz Ry Rx S from its own place (as the original's: not its parent's).
fn objMatrix(i: usize) [12]f32 {
    const o = &scene.objects[i];
    const sc32 = @import("animexpr.zig").sincos32;
    const rad = o.radians();
    const xa = sc32(rad[0]);
    const ya = sc32(rad[1]);
    const za = sc32(rad[2]);
    const sx = xa[0];
    const cx = xa[1];
    const sy = ya[0];
    const cy = ya[1];
    const sz = za[0];
    const cz = za[1];
    var r: [12]f32 = .{
        cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx, 0,
        sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx, 0,
        0 - sy,  cy * sx,                cy * cx,                0,
    };
    for (0..3) |row| {
        for (0..3) |c| r[row * 4 + c] = o.scl[c] * r[row * 4 + c];
        r[row * 4 + 3] = o.loc[row];
    }
    return r;
}

/// xform_point.
fn xform(m: *const [12]f32, p: [3]f32) [3]f32 {
    var o: [3]f32 = undefined;
    for (0..3) |r| {
        var a = m[r * 4] * p[0];
        a += m[r * 4 + 1] * p[1];
        a += m[r * 4 + 2] * p[2];
        a += m[r * 4 + 3];
        o[r] = a;
    }
    return o;
}

/// m_inv (arm.s): the inverse of an affine 3x4; singular: identity.
fn mInv(a: *const [12]f32) [12]f32 {
    return @import("arm.zig").mInv(a);
}

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

// ---- the shown meshes --------------------------------------------------------------------

/// mesh_copy: a mesh of our own (what the cloth shows).
fn copyMesh(s: *const scene.Mesh) ?scene.Mesh {
    var me = s.*;
    me.vsel = &.{};
    me.sk = null;
    me.arm = null;
    me.wgt = &.{};
    me.pin = &.{};
    me.land = null; // (its landscape stays with the scene's mesh)
    me.text = null; // (and its text)
    me.curve = null; // (and its curve: freeing the copy would unref it twice)
    me.uv = &.{};
    me.seam = &.{};
    me.vcol = &.{};
    me.edge_list = &.{};
    me.verts = A.dupe(@TypeOf(s.verts[0]), s.verts) catch return null;
    me.poff = A.dupe(u32, s.poff) catch return freeHalf(&me, 1);
    me.loops = A.dupe(u32, s.loops) catch return freeHalf(&me, 2);
    me.tris = A.dupe([3]u32, s.tris) catch return freeHalf(&me, 3);
    me.tri_poly = A.dupe(u32, s.tri_poly) catch return freeHalf(&me, 4);
    if (s.edge_list.len > 0) me.edge_list = A.dupe([2]u32, s.edge_list) catch &.{};
    if (s.uv.len > 0) me.uv = A.dupe([2]f32, s.uv) catch &.{};
    if (s.seam.len > 0) me.seam = A.dupe(u8, s.seam) catch &.{};
    if (s.vcol.len > 0) me.vcol = A.dupe(u32, s.vcol) catch &.{};
    out_serials +%= 1;
    me.serial = (out_serials & 0x3fffffff) | 0x40000000;
    me.shape = 0;
    return me;
}
fn freeHalf(me: *scene.Mesh, k: u32) ?scene.Mesh {
    A.free(me.verts);
    if (k > 1) A.free(me.poff);
    if (k > 2) A.free(me.loops);
    if (k > 3) A.free(me.tris);
    return null;
}

/// mesh_bbox, ME_VER: its bounds and a new shape (what shows it follows).
fn touched(me: *scene.Mesh) void {
    me.lo = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    me.hi = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (me.verts) |p| {
        for (0..3) |k| {
            me.lo[k] = @min(me.lo[k], p[k]);
            me.hi[k] = @max(me.hi[k], p[k]);
        }
    }
    me.shape +%= 1;
    shown_n +%= 1;
}

/// cl_mesh: the mesh object i shows while simulated, or null.
pub fn meshOf(i: usize) ?*const scene.Mesh {
    if (!on) return null;
    const oid = scene.objects[i].oid;
    for (cr[0..nc]) |*c| {
        if (c.oid == oid and c.has_out) return &c.out;
    }
    return null;
}

/// Its corner normals (mods.normals: a shown cloth's own).
pub fn normals(me: *const scene.Mesh) ?[][3]@import("math.zig").V3 {
    for (cr[0..nc]) |*c| {
        if (c.has_out and &c.out == me) return preview.cornerNormalsIn(&c.kept, me);
    }
    return null;
}

/// What the viewport keys on: moves when a shown cloth does.
pub fn stateWord() u32 {
    return shown_n;
}

// ---- making it ------------------------------------------------------------------------------

/// cl_free: no simulation (its meshes go).
pub fn free() void {
    if (!on) return;
    on = false;
    for (cr[0..nc]) |*c| {
        if (c.has_out) scene.freeMesh(&c.out);
        c.has_out = false;
        preview.freeKept(&c.kept);
    }
    nc = 0;
    freeArrays();
    shown_n +%= 1;
    app.dirty = true;
}

fn freeArrays() void {
    inline for (.{ &x, &xp, &vel, &rest, &gr }) |p| {
        if (p.*.len > 0) A.free(p.*);
        p.* = &.{};
    }
    inline for (.{ &own, &cell, &ent, &scell, &sent, &big }) |p| {
        if (p.*.len > 0) A.free(p.*);
        p.* = &.{};
    }
    if (dc.len > 0) A.free(dc);
    dc = &.{};
    if (tr.len > 0) A.free(tr);
    tr = &.{};
    if (ct.len > 0) A.free(ct);
    ct = &.{};
}

/// cl_reset (simcache, a new scene).
pub fn reset() void {
    free();
}

/// The cloth objects there are (sim.bake: something to bake).
pub fn count() u32 {
    const b = anim.cur orelse return 0;
    return rd(&b.rest, REST_CW + CW_N);
}

fn zeroed(comptime T: type, n: usize) ![]T {
    const s = try A.alloc(T, n);
    @memset(std.mem.sliceAsBytes(s), 0);
    return s;
}

/// The Ground, when visible (ground_any).
fn groundAny() ?usize {
    const gi = @import("prims.zig").find() orelse return null;
    if (!scene.objects[gi].visible) return null;
    return gi;
}

/// cl_build: particles, constraints, colours, triangles from the settings.
fn build() void {
    free();
    const b = anim.cur orelse return;
    var npart: u32 = 0;
    var ntri: u32 = 0;
    var ncol: u32 = 0;
    for (0..ncl(b)) |k| {
        const r = entry(b, k);
        const i = entryObj(r) orelse continue;
        const me = mods.of(i) orelse continue;
        if (rd(r, CL_TYPE) == 3) {
            // (a landscape: its heights, not triangles)
            if (landscape.ofIndex(i) == null) ncol +%= @intCast(me.tris.len);
            continue;
        }
        ntri +%= @intCast(me.tris.len);
        npart +%= @intCast(me.verts.len);
    }
    if (npart == 0) return;
    if (groundAny()) |gi| {
        if (mods.of(gi)) |me| ncol +%= @intCast(me.tris.len);
    }
    capct = ncol +% 16;
    // a hash size: a power of two >= 2 x (collider entries guess, particles)
    var e: u32 = ncol << 3;
    if (e < npart) e = npart;
    e +%= 1024;
    const sh: u5 = @truncate(std.math.log2_int(u32, e) + 2);
    hmask = (@as(u32, 1) << sh) -% 1;
    const se: u32 = (npart << 1) | 1023;
    const ss: u5 = @truncate(std.math.log2_int(u32, se) + 1);
    smask = (@as(u32, 1) << ss) -% 1;
    allocAll(npart, ntri) catch {
        freeArrays();
        return;
    };
    nc = 0;
    np = 0;
    nd = 0;
    nt = 0;
    self_any = 0;
    for (0..ncl(b)) |k| {
        const r = entry(b, k);
        if (rd(r, CL_TYPE) >= 3) continue;
        const i = entryObj(r) orelse continue;
        make(r, i);
    }
    colour();
    settings();
    on = true;
}

fn allocAll(npart: u32, ntri: u32) !void {
    const n: usize = npart;
    x = try A.alloc(V4, n);
    xp = try A.alloc(V4, n);
    vel = try A.alloc(V4, n);
    rest = try A.alloc(V4, n);
    own = try A.alloc(u32, n);
    dc = try A.alloc(Dc, @as(usize, ntri) * 6);
    tr = try A.alloc([3]u32, ntri);
    ct = try A.alloc(Ct, capct);
    cell = try zeroed(u32, @as(usize, hmask) + 2);
    ent = try A.alloc(u32, @as(usize, capct) * 64);
    scell = try zeroed(u32, @as(usize, smask) + 2);
    sent = try A.alloc(u32, n);
    gr = try zeroed(V4, n);
    big = try A.alloc(u32, capct);
}

/// cl_settings: gravity (the physics world's), wind, steps. (A damaged file's
/// substeps or rate out of 1 .. 500 are taken as 1 or 500: the original's
/// loops would run for hours.)
fn settings() void {
    const b = anim.cur orelse return;
    const gv = fields.worldGravity();
    g = .{ gv[0], gv[1], gv[2], 0 };
    const w = rc.rd3(&b.rest, REST_CW + CW_WIND);
    wind_w = andXyz(.{ w[0], w[1], w[2], 0 });
    var s: i32 = @bitCast(rd(&b.rest, REST_CW + CW_SUB));
    if (s == 0) s = 10;
    s = std.math.clamp(s, 1, 500);
    nsub = @intCast(s);
    var rt: i32 = @bitCast(rd(&b.rest, REST_CW + CW_RATE));
    if (rt == 0) rt = 60;
    rt = std.math.clamp(rt, 1, 500);
    const rf: f32 = @floatFromInt(rt);
    dt = cq_one / rf;
    const sf: f32 = @floatFromInt(s);
    hs = dt / sf;
}

/// Edges (each once) and their triangles: a hash on the two ends; entries
/// lo + 1, hi, t1 + 1, t2 + 1.
const Edge = [4]u32;

fn edgePut(tab: []Edge, mask: u32, a0: u32, b0: u32, t: u32) void {
    var a = a0;
    var b = b0;
    if (!(a < b)) std.mem.swap(u32, &a, &b);
    var h = (a *% 73856093) ^ (b *% 19349663);
    while (true) {
        h &= mask;
        const en = &tab[h];
        if (en[0] == 0) {
            en.* = .{ a + 1, b, t + 1, 0 };
            return;
        }
        if (en[0] - 1 == a and en[1] == b) {
            if (en[3] == 0) en[3] = t + 1;
            return;
        }
        h +%= 1;
    }
}

/// far_corner: the corner of triangle t (local) off the edge a, b.
fn farCorner(c: *const Cr, t: u32, a: u32, b: u32) u32 {
    const tri = tr[c.t0 + t];
    for (tri) |q| {
        if (q != a and q != b) return q;
    }
    return a;
}

/// dc_add: a distance constraint at the rest distance (from the places now).
fn dcAdd(a: u32, b: u32, comp: f32) void {
    const d = andXyz(x[a] - x[b]);
    dc[nd] = .{ .i = a, .j = b, .rest = @sqrt(dot3(d, d)), .comp = comp };
    nd += 1;
}

/// cl_make: its particles, triangles, constraints.
fn make(r: []const u8, oi: usize) void {
    if (nc >= CR_MAX) return;
    const me0 = mods.of(oi) orelse return;
    const c = &cr[nc];
    const cnum = nc;
    nc += 1;
    c.* = .{};
    c.oid = scene.objects[oi].oid;
    c.typ = rd(r, CL_TYPE);
    c.volc = rdf(r, CL_VOL);
    c.thick = rdf(r, CL_THICK);
    c.fric = rdf(r, CL_FRIC);
    c.damp = rdf(r, CL_DAMP);
    c.self = rd(r, CL_FLAGS) & 1;
    self_any |= c.self;
    if (copyMesh(me0)) |o| {
        c.out = o;
        c.has_out = true;
    }
    const me = me0; // (its rest: the mesh now)
    c.mat = objMatrix(oi);
    // particles: world places, rest places, masses (pinned: none)
    c.p0 = np;
    const nv: u32 = @intCast(me.verts.len);
    c.np = nv;
    np += nv;
    var mass = rdf(r, CL_MASS);
    if (!(mass > 0)) mass = cq_one;
    const fnv: f32 = @floatFromInt(nv);
    const im = fnv / mass;
    for (0..nv) |k| {
        const p = c.p0 + @as(u32, @intCast(k));
        const pos = me.verts[k];
        rest[p] = .{ pos[0], pos[1], pos[2], 0 };
        const wp = xform(&c.mat, pos);
        var w = im;
        if (k < me.pin.len and me.pin[k] != 0) {
            w = 0;
            rest[p][3] = 1.0;
        }
        x[p] = .{ wp[0], wp[1], wp[2], w };
        xp[p] = x[p];
        vel[p] = @splat(0);
        own[p] = cnum;
    }
    // triangles (particle numbers)
    c.t0 = nt;
    c.nt = @intCast(me.tris.len);
    nt += c.nt;
    for (me.tris, 0..) |t, k| tr[c.t0 + k] = .{ t[0] + c.p0, t[1] + c.p0, t[2] + c.p0 };
    // edges (each once) and their triangles
    const sz = (c.nt *% 6) | 15;
    const mask: u32 = (@as(u32, 1) << @truncate(std.math.log2_int(u32, sz) + 1)) -% 1;
    const tab = A.alloc(Edge, @as(usize, mask) + 1) catch return;
    defer A.free(tab);
    @memset(tab, .{ 0, 0, 0, 0 });
    for (0..c.nt) |t| {
        const tri = tr[c.t0 + t];
        for (0..3) |k| edgePut(tab, mask, tri[k], tri[(k + 1) % 3], @intCast(t));
    }
    // stretch for every edge; bend across every shared one
    const stretch = rdf(r, CL_STRETCH);
    const bend = rdf(r, CL_BEND);
    for (tab) |en| {
        if (en[0] == 0) continue;
        const a = en[0] - 1;
        dcAdd(a, en[1], stretch);
        if (en[3] == 0) continue;
        const f1 = farCorner(c, en[2] - 1, a, en[1]);
        const f2 = farCorner(c, en[3] - 1, a, en[1]);
        if (f1 == f2) continue;
        dcAdd(f1, f2, bend);
    }
    if (c.typ == 2) c.v0 = volume(c);
}

/// cl_volume: the volume its triangles enclose.
fn volume(c: *const Cr) f32 {
    var s: f32 = 0;
    for (tr[c.t0 .. c.t0 + c.nt]) |t| {
        const a = andXyz(x[t[1]]);
        const b = andXyz(x[t[2]]);
        const d = cross(a, b);
        s += dot3(d, andXyz(x[t[0]]));
    }
    return s * cq_sixth;
}

/// cl_colour: constraints coloured (no two of a colour share a particle),
/// then sorted by colour (stable); bs the starts.
fn colour() void {
    const mask = A.alloc(u64, np) catch return;
    defer A.free(mask);
    @memset(mask, 0);
    const col = A.alloc(u8, nd) catch return;
    defer A.free(col);
    bs = @splat(0);
    for (dc[0..nd], 0..) |d, k| {
        const free_bits = ~(mask[d.i] | mask[d.j]);
        var cc: u32 = 64; // (all used: the last, serial one)
        if (free_bits != 0) {
            cc = @ctz(free_bits);
            mask[d.i] |= @as(u64, 1) << @intCast(cc);
            mask[d.j] |= @as(u64, 1) << @intCast(cc);
        }
        col[k] = @intCast(cc);
        bs[cc + 1] += 1;
    }
    var s: u32 = 0;
    for (0..NCOL + 1) |k| {
        s += bs[k];
        bs[k] = s;
    }
    var cur: [NCOL]u32 = bs[0..NCOL].*;
    const tmp = A.alloc(Dc, nd) catch return;
    defer A.free(tmp);
    for (dc[0..nd], 0..) |d, k| {
        tmp[cur[col[k]]] = d;
        cur[col[k]] += 1;
    }
    @memcpy(dc[0..nd], tmp);
}

// ---- a step ----------------------------------------------------------------------------------

var dummy: u8 = 0;
fn ctx() *anyopaque {
    return @ptrCast(&dummy);
}

fn step() void {
    fields.prep(fields.time(), .{ g[0], g[1], g[2] });
    for (cr[0..nc]) |*c| {
        if (scene.findOid(c.oid)) |i| c.mat = objMatrix(i); // (pins follow)
    }
    colliders();
    hits.store(0, .monotonic);
    var s: u32 = 0;
    while (s < nsub) : (s += 1) {
        windStep();
        jobs.parallelFor(np, 2048, ctx(), predJob);
        for (0..NCOL) |k| {
            const lo = bs[k];
            const n = bs[k + 1] -% lo;
            if (n == 0) continue;
            bat = lo;
            if (k != NCOL - 1 and n >= 512) {
                jobs.parallelFor(n, 256, ctx(), dcJob);
            } else dcJob(ctx(), 0, n, 0);
        }
        volumes();
        if (nct | nhf != 0) {
            jobs.parallelFor(np, 1024, ctx(), colJob);
            if (nct != 0) edges();
        }
        if (self_any != 0) selfCol();
        jobs.parallelFor(np, 2048, ctx(), velJob);
    }
}

/// pred_job: gravity (the fields' pull), the prediction; pins to their places
/// on the object.
fn predJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const h = splat(hs);
    const gh = g * h;
    for (lo..hi) |p| {
        const x0 = x[p];
        xp[p] = x0;
        const w = wOf(x0);
        if (w > 0) {
            var v2: V4 = undefined;
            if (fields.n != 0) {
                const v0 = vel[p];
                const a3 = fields.accel(.{ x0[0], x0[1], x0[2] }, .{ v0[0], v0[1], v0[2] }, 1, true);
                const a = V4{ a3[0], a3[1], a3[2], 0 } * h;
                v2 = vel[p] + a;
            } else v2 = vel[p] + gh;
            v2 = andXyz(v2);
            vel[p] = v2;
            x[p] = x0 + v2 * h;
        } else if (@as(u32, @bitCast(rest[p][3])) != 0) {
            const c = &cr[own[p]];
            const q = xform(&c.mat, .{ rest[p][0], rest[p][1], rest[p][2] });
            x[p] = .{ q[0], q[1], q[2], x0[3] };
        }
    }
}

/// dc_job: distance constraints, XPBD: dl = -(len - rest) / (w1 + w2 + compliance / h^2).
fn dcJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const h2 = hs * hs;
    for (lo..hi) |k| {
        const d = dc[bat + k];
        const x1 = x[d.i];
        const x2 = x[d.j];
        const w1 = splat(x1[3]);
        const w2 = splat(x2[3]);
        var den = x1[3] + x2[3];
        den += d.comp / h2;
        if (!(den > cq_tiny)) continue;
        const dv = andXyz(x1 - x2);
        const len = @sqrt(dot3(dv, dv));
        if (!(len > cq_tiny)) continue;
        var dl = len - d.rest;
        dl = dl / den;
        dl = dl / len;
        const dd = dv * splat(dl);
        x[d.i] = x1 - w1 * dd;
        x[d.j] = x2 + w2 * dd;
    }
}

/// cl_volumes: each soft body back to its volume (one global constraint).
fn volumes() void {
    for (cr[0..nc]) |*c| {
        if (c.typ != 2) continue;
        const g0 = gr[c.p0 .. c.p0 + c.np];
        @memset(g0, @splat(0));
        for (tr[c.t0 .. c.t0 + c.nt]) |t| {
            for (0..3) |k| {
                const i = t[k];
                const j = t[(k + 1) % 3];
                const l = t[(k + 2) % 3];
                gr[i] = cross(andXyz(x[j]), andXyz(x[l])) + gr[i];
            }
        }
        const cv = volume(c) - c.v0;
        var sum: f32 = 0;
        const s6 = splat(cq_sixth);
        for (c.p0..c.p0 + c.np) |p| {
            const gg = gr[p] * s6;
            gr[p] = gg;
            sum += dot3(gg, gg) * x[p][3];
        }
        const alpha = c.volc / (hs * hs);
        sum += alpha;
        if (!(sum > cq_tiny)) continue;
        const dl = (0.0 - cv) / sum;
        for (c.p0..c.p0 + c.np) |p| {
            const s = x[p][3] * dl;
            x[p] = andXyz(splat(s) * gr[p]) + x[p];
        }
    }
}

/// cl_wind: wind as drag on each triangle: f = c area (n . (w - v)) n, a third
/// to each corner (as velocity: h w f / 3). Wind fields: the air at its centre.
fn windStep() void {
    var air = wind_w;
    if (fields.nw == 0) {
        if (!(dot3(air, air) > 0)) return;
    }
    for (0..nt) |b| {
        const t = tr[b];
        if (fields.nw != 0) {
            const cen = ((x[t[0]] + x[t[1]]) + x[t[2]]) * third4;
            const fw = fields.wind(.{ cen[0], cen[1], cen[2] });
            air = andXyz(V4{ fw[0], fw[1], fw[2], 0 } + wind_w);
        }
        const e1 = andXyz(x[t[1]] - x[t[0]]);
        const e2 = andXyz(x[t[2]] - x[t[0]]);
        const n2 = cross(e1, e2); // (length: 2 area)
        const av = ((vel[t[0]] + vel[t[1]]) + vel[t[2]]) * third4;
        const rel = air - av;
        const len = @sqrt(dot3(n2, n2));
        if (!(len > cq_tiny)) continue;
        var s = dot3(rel, n2);
        s = s / len;
        s = s * cq_drag;
        s = s * cq_half;
        s = s * cq_third;
        s = s * hs;
        const dv = andXyz(splat(s) * n2);
        for (t) |p| vel[p] = splat(x[p][3]) * dv + vel[p];
    }
}

/// vel_job: v = (x - xp) / h, damped.
fn velJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const inv = splat(cq_one / hs);
    for (lo..hi) |p| {
        var v = andXyz(x[p] - xp[p]) * inv;
        const dm = cr[own[p]].damp * hs;
        const f = maxss(cq_one - dm, 0);
        v = v * splat(f);
        vel[p] = v;
    }
}

// ---- collisions -------------------------------------------------------------------------------

/// cl_colliders: the colliders' triangles in the world, hashed (too big: a
/// list every particle sees).
fn colliders() void {
    nct = 0;
    nbig = 0;
    nhf = 0;
    const b = anim.cur orelse return;
    var size_sum: f32 = 0;
    var k: u32 = 0;
    const n = ncl(b);
    var ground_turn = false;
    while (true) {
        var oi: usize = undefined;
        if (k < n) {
            const r = entry(b, k);
            k += 1;
            if (rd(r, CL_TYPE) != 3) continue;
            oi = entryObj(r) orelse continue;
            if (landscape.ofIndex(oi)) |lb| { // a landscape: by its heights
                if (nhf >= 4) continue;
                const o = &scene.objects[oi];
                hf[nhf] = .{
                    .b = lb,
                    .loc = .{ o.loc[0], o.loc[1], o.loc[2], 0 },
                    .scl = .{ o.scl[0], o.scl[1], o.scl[2], 0 },
                };
                nhf += 1;
                continue;
            }
        } else {
            if (ground_turn) break;
            ground_turn = true; // then the Ground, a collider always
            oi = groundAny() orelse break;
        }
        const mt = objMatrix(oi);
        const me = mods.of(oi) orelse continue;
        const first = nct;
        for (me.tris) |t| {
            if (nct >= capct) break;
            const q = &ct[nct];
            for (0..3) |c| q.p[c] = ld3(xform(&mt, me.verts[t[c]]));
            // its unit normal
            const n3 = cross(q.p[1] - q.p[0], q.p[2] - q.p[0]);
            const l = maxss(@sqrt(dot3(n3, n3)), cq_tiny);
            q.n = andXyz(n3 / splat(l));
            q.edges = 0;
            // its size (the bounds' largest side)
            const lo = minps(minps(q.p[0], q.p[1]), q.p[2]);
            const hi = maxps(maxps(q.p[0], q.p[1]), q.p[2]);
            const ext = hi - lo;
            const sz = maxss(maxss(ext[0], ext[1]), ext[2]);
            if (!ground_turn) size_sum += sz;
            nct += 1;
        }
        // its edges: a corner unless the triangle across it faces the same
        // way (a flat face's diagonal, a smooth surface's). Big meshes: none
        if (me.tris.len > 2048) continue;
        var q = first;
        while (q < nct) : (q += 1) {
            const li = q - first;
            const tri = me.tris[li];
            var bits: u32 = 0;
            for (0..3) |e| {
                const a = tri[e];
                const bb = tri[(e + 1) % 3];
                var corner = true;
                for (me.tris, 0..) |o, r8| {
                    if (r8 == li) continue;
                    const has_a = o[0] == a or o[1] == a or o[2] == a;
                    const has_b = o[0] == bb or o[1] == bb or o[2] == bb;
                    if (!(has_a and has_b)) continue;
                    const gi = first + @as(u32, @intCast(r8));
                    if (gi < nct and dot3(ct[q].n, ct[gi].n) >= cq_smooth) corner = false;
                    break;
                }
                if (corner) bits |= @as(u32, 1) << @intCast(e);
            }
            ct[q].edges = bits;
        }
    }
    if (nct == 0) return;
    // the cell: the average triangle size, at least 5 cm
    const fc: f32 = @floatFromInt(nct);
    const csz = maxss(size_sum / fc, cq_cell);
    icell = splat(cq_one / csz);
    @memset(cell, 0);
    for (0..2) |pass| {
        for (0..nct) |t| {
            const q = &ct[t];
            const lo = minps(minps(q.p[0], q.p[1]), q.p[2]) - pad4;
            const hi = maxps(maxps(q.p[0], q.p[1]), q.p[2]) + pad4;
            const c0 = cellOf(lo, icell);
            const c1 = cellOf(hi, icell);
            var cnt: u32 = 1;
            inline for (0..3) |a| cnt *%= @as(u32, @bitCast(c1[a] -% c0[a] +% 1));
            if (cnt > 64) {
                if (pass == 0) {
                    big[nbig] = @intCast(t);
                    nbig += 1;
                }
                continue;
            }
            var z = c0[2];
            while (z <= c1[2]) : (z += 1) {
                var y = c0[1];
                while (y <= c1[1]) : (y += 1) {
                    var xx = c0[0];
                    while (xx <= c1[0]) : (xx += 1) {
                        const s = slotOf(.{ xx, y, z }, hmask);
                        if (pass == 0) {
                            cell[s + 1] += 1;
                        } else {
                            ent[cell[s]] = @intCast(t);
                            cell[s] += 1;
                        }
                    }
                }
            }
        }
        if (pass == 0) {
            var s: u32 = 0;
            for (cell[0 .. hmask + 2]) |*c| {
                s += c.*;
                c.* = s;
            }
        }
    }
    // (filling moved each start up: back)
    var r8 = hmask;
    while (r8 != 0) : (r8 -= 1) cell[r8] = cell[r8 - 1];
    cell[0] = 0;
}

/// What a particle's collision pass keeps: the nearest triangle so far.
const Near = struct {
    thick: f32,
    fric: f32,
    best: f32, // |v|^2, from the thickness squared
    v: V4 = @splat(0), // to the nearest point
    tri: i32 = -1,
};

/// pt_tri: the nearer triangle kept; one gone through this step (from xp to x)
/// puts the particle back on the side it came from at once.
fn ptTri(p: usize, t: u32, nr: *Near) void {
    const q = &ct[t];
    const xx = andXyz(x[p]);
    var cl: collide.Closest = .{};
    collide.triClosest(q.p[0] - xx, q.p[1] - xx, q.p[2] - xx, &cl);
    const d2 = dot3(cl.v, cl.v);
    if (!(d2 >= nr.best)) {
        nr.v = andXyz(cl.v);
        nr.best = d2;
        nr.tri = @intCast(t);
        return;
    }
    // farther: did it go through it this step?
    const x4 = andXyz(xp[p]);
    const dp = dot3(x4 - q.p[0], q.n);
    const x6 = andXyz(x[p]);
    const dx = dot3(x6 - q.p[0], q.n);
    if (dp * dx >= 0) return;
    const f = dp / (dp - dx);
    const s = andXyz((x6 - x4) * splat(f) + x4);
    var c2: collide.Closest = .{};
    collide.triClosest(q.p[0] - s, q.p[1] - s, q.p[2] - s, &c2);
    if (dot3(c2.v, c2.v) >= cq_cross) return;
    var n = q.n; // towards where it came from
    if (0 > dp) n = rc.neg3(n);
    const nx = andXyz(splat(nr.thick) * n + s);
    x[p] = .{ nx[0], nx[1], nx[2], x[p][3] };
    _ = hits.fetchAdd(1, .monotonic);
}

/// pt_resolve: the particle out of the nearest triangle to its thickness.
/// The face's inside: along its normal, to the side the particle came from.
/// An edge or a corner, the particle not through the face's plane: straight
/// away from that point. Friction: less of the sliding.
fn ptResolve(p: usize, nr: *const Near) void {
    const q = &ct[@intCast(nr.tri)];
    const v = nr.v;
    const qq = andXyz(x[p]) + v;
    const x4 = andXyz(xp[p]);
    var n6 = q.n;
    if (!(dot3(x4 - qq, q.n) >= 0)) n6 = rc.neg3(n6);
    var vn = dot3(v, q.n);
    vn = vn * vn;
    const vv = dot3(v, v);
    var np2: V4 = undefined;
    var along = true;
    if (vv > cq_tiny and !(vn >= vv * cq_inside) and !(dot3(v, n6) >= 0)) along = false;
    if (!along) {
        n6 = andXyz(rc.neg3(v) / splat(@sqrt(vv)));
        np2 = splat(nr.thick) * n6 + qq;
    } else {
        const x7 = andXyz(x[p]);
        const s5 = nr.thick - dot3(x7 - qq, n6);
        np2 = x7 + splat(s5) * n6;
    }
    var d1 = np2 - x4;
    const d5 = dot3(d1, n6);
    d1 = d1 - splat(d5) * n6;
    d1 = d1 * splat(nr.fric);
    const nx = andXyz(np2 - d1);
    x[p] = .{ nx[0], nx[1], nx[2], x[p][3] };
    _ = hits.fetchAdd(1, .monotonic);
}

/// pt_hf: a particle under the ground (and its thickness) put back on it,
/// straight up; its sliding there slowed by the friction.
fn ptHf(p: usize, k: usize, thick: f32, fric: f32) void {
    const h = &hf[k];
    const l = (x[p] - h.loc) / V4{ h.scl[0], h.scl[1], h.scl[2], 1 };
    var y = landscape.height(h.b, l[0], l[2]) orelse return;
    y = y * h.scl[1] + h.loc[1]; // (in the world)
    y = y + thick;
    if (x[p][1] >= y) return;
    x[p][1] = y; // up onto it
    const q = xp[p]; // friction: less of the sliding
    x[p][0] = x[p][0] - (x[p][0] - q[0]) * fric;
    x[p][2] = x[p][2] - (x[p][2] - q[2]) * fric;
    _ = hits.fetchAdd(1, .monotonic);
}

/// col_job: each particle out of the colliders' triangles near it (to its
/// thickness, on the side it came from; friction).
fn colJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |p| {
        if (!(x[p][3] > 0)) continue; // (pinned: no)
        const c = &cr[own[p]];
        for (0..nhf) |k| ptHf(p, k, c.thick, c.fric); // landscapes
        if (nct == 0) continue;
        var nr = Near{ .thick = c.thick, .fric = c.fric, .best = c.thick * c.thick };
        for (big[0..nbig]) |t| ptTri(p, t, &nr);
        const s = slotOf(cellOf(x[p], icell), hmask);
        var e = cell[s];
        const end = cell[s + 1];
        while (e < end) : (e += 1) ptTri(p, ent[e], &nr);
        if (nr.tri >= 0) ptResolve(p, &nr);
    }
}

fn clamp01(v: f32) f32 {
    return minss(maxss(v, 0), cq_one);
}

/// cl_edges: the colliders' edges against the edges of the cloths'
/// triangles: closer than the thickness, the cloth's edge is pushed off,
/// along the line between their nearest points as it was before the substep
/// (a centimetre a substep at most).
fn edges() void {
    for (cr[0..nc]) |*c| {
        if (c.typ == 3 or c.nt == 0) continue;
        const th = maxss(c.thick, cq_emarg);
        const th2 = th * th;
        var blo = x[c.p0];
        var bhi = blo;
        var k: u32 = 1;
        while (k < c.np) : (k += 1) {
            blo = minps(blo, x[c.p0 + k]);
            bhi = maxps(bhi, x[c.p0 + k]);
        }
        const m = splat(th + cq_emarg);
        blo = blo - m;
        bhi = bhi + m;
        for (ct[0..nct]) |*q| {
            for (0..3) |e| {
                if (q.edges >> @intCast(e) & 1 == 0) continue;
                const p1 = andXyz(q.p[e]);
                const q1 = andXyz(q.p[(e + 1) % 3]);
                const d1 = q1 - p1;
                const a = dot3(d1, d1);
                if (!(a > cq_eps)) continue;
                const elo = minps(p1, q1) - splat(th);
                const ehi = maxps(q1, p1) + splat(th);
                if (anyLe(bhi, elo) or anyLe(ehi, blo)) continue;
                for (tr[c.t0 .. c.t0 + c.nt]) |t| {
                    const x0 = x[t[0]];
                    const x1 = x[t[1]];
                    const x2 = x[t[2]];
                    const tmin = minps(minps(x0, x1), x2);
                    const tmax = maxps(maxps(x0, x1), x2);
                    if (anyLe(tmax, elo) or anyLe(ehi, tmin)) continue;
                    for (0..3) |ce| {
                        const ii = t[ce];
                        const jj = t[(ce + 1) % 3];
                        if (ii >= jj) continue;
                        edgePair(c, p1, d1, a, th, th2, ii, jj);
                    }
                }
            }
        }
    }
}

/// cmpleps a, b in any of x y z.
fn anyLe(a: V4, b: V4) bool {
    return a[0] <= b[0] or a[1] <= b[1] or a[2] <= b[2];
}

fn edgePair(c: *const Cr, p1: V4, d1: V4, a: f32, th: f32, th2: f32, ii: u32, jj: u32) void {
    _ = c;
    const p2 = andXyz(x[ii]);
    const d2 = andXyz(x[jj]) - p2;
    const e = dot3(d2, d2);
    if (!(e > cq_eps)) return;
    const r = p1 - p2;
    const f = dot3(d2, r);
    const cc = dot3(d1, r);
    const b = dot3(d1, d2);
    var den = a * e;
    den = den - b * b;
    var s: f32 = 0;
    if (den > cq_eps) {
        var s1 = b * f;
        s1 = s1 - cc * e;
        s = clamp01(s1 / den);
    }
    var t = b * s;
    t = t + f;
    t = t / e;
    if (!(t >= 0)) {
        t = 0;
        s = clamp01((0.0 - cc) / a);
    } else if (t > cq_one) {
        t = cq_one;
        s = clamp01((b - cc) / a);
    }
    const c1 = splat(s) * d1 + p1;
    const c2 = splat(t) * d2 + p2;
    const delta = c2 - c1;
    if (dot3(delta, delta) >= th2) return;
    // the same before the substep: the side it came from
    const b0 = andXyz(xp[ii]);
    const b1 = andXyz(xp[jj]);
    var nv = ((b1 - b0) * splat(t) + b0) - c1;
    var l2 = dot3(nv, nv);
    if (!(l2 > cq_eps)) {
        nv = delta; // (no telling: delta now)
        l2 = dot3(nv, nv);
        if (!(l2 > cq_eps)) return;
    }
    const n = andXyz(nv / splat(@sqrt(l2)));
    var corr = th - dot3(delta, n);
    corr = minss(corr, cq_ecap);
    if (!(corr > cq_tiny)) return;
    const w0 = cq_one - t;
    const w1 = t;
    const m0 = x[ii][3] * w0;
    const m1 = x[jj][3] * w1;
    var sum = m0 * w0;
    sum += m1 * w1;
    if (!(sum > cq_tiny)) return;
    const lam = corr / sum;
    const a0 = splat(m0 * lam) * n;
    const a1 = splat(m1 * lam) * n;
    x[ii] = x[ii] + a0;
    x[jj] = x[jj] + a1;
    xp[ii] = xp[ii] + a0; // (moved off, not sent off)
    xp[jj] = xp[jj] + a1;
    _ = hits.fetchAdd(1, .monotonic);
}

/// cl_selfcol: particles of cloths that collide with themselves kept two
/// thicknesses apart (not neighbours in the rest shape).
fn selfCol() void {
    var csz = cq_cell; // the cell: twice the thickness
    for (cr[0..nc]) |*c| {
        if (c.self == 0) continue;
        csz = maxss(csz, c.thick + c.thick);
    }
    sinv = splat(cq_one / csz);
    @memset(scell[0 .. smask + 2], 0);
    for (0..np) |p| {
        if (selfSlot(p)) |s| scell[s + 1] += 1;
    }
    var s: u32 = 0;
    for (scell[0 .. smask + 2]) |*q| {
        s += q.*;
        q.* = s;
    }
    for (0..np) |p| {
        if (selfSlot(p)) |sl| {
            sent[scell[sl]] = @intCast(p);
            scell[sl] += 1;
        }
    }
    var r8 = smask;
    while (r8 != 0) : (r8 -= 1) scell[r8] = scell[r8 - 1];
    scell[0] = 0;
    jobs.parallelFor(np, 512, ctx(), selfqJob); // each particle's push
    jobs.parallelFor(np, 2048, ctx(), selfaJob); // then all of them
}

fn selfSlot(p: usize) ?u32 {
    if (cr[own[p]].self == 0) return null;
    return slotOf(cellOf(x[p], sinv), smask);
}

fn selfqJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |p| {
        var push: V4 = @splat(0);
        if (cr[own[p]].self != 0) {
            const c0 = cellOf(x[p], sinv);
            var dz: i32 = -1;
            while (dz <= 1) : (dz += 1) {
                var dy: i32 = -1;
                while (dy <= 1) : (dy += 1) {
                    var dx: i32 = -1;
                    while (dx <= 1) : (dx += 1) {
                        const s = slotOf(.{ c0[0] +% dx, c0[1] +% dy, c0[2] +% dz }, smask);
                        var e = scell[s];
                        const end = scell[s + 1];
                        while (e < end) : (e += 1) {
                            const o = sent[e];
                            if (o != p) selfPush(p, o, &push);
                        }
                    }
                }
            }
        }
        gr[p] = push;
    }
}

fn selfaJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |p| x[p] = gr[p] + x[p];
}

/// self_push: its share of keeping two thicknesses apart (the same cloth: not
/// rest neighbours).
fn selfPush(p: usize, o: usize, push: *V4) void {
    const ci = own[p];
    const cj = own[o];
    if (cr[cj].self == 0) return;
    var keep = cr[ci].thick;
    keep = keep + keep;
    if (ci == cj) {
        const d = andXyz(rest[p] - rest[o]);
        const rl = @sqrt(dot3(d, d));
        if (!(rl > keep * cq_neigh)) return;
    }
    const x0 = x[p];
    const x1 = x[o];
    const d = andXyz(x0 - x1);
    const len = @sqrt(dot3(d, d));
    if (len >= keep) return;
    if (!(len > cq_tiny)) return;
    const w1 = x0[3];
    const sw = x1[3] + w1;
    if (!(sw > cq_tiny)) return;
    const f = w1 / sw;
    var s = keep - len;
    s = s / len;
    s = s * f;
    push.* = d * splat(s) + push.*;
}

// ---- frames -----------------------------------------------------------------------------------

/// cl_key: the settings and pins, the animation, the rigid bodies' key, the
/// meshes, where the objects nothing moves are (what the cache belongs to).
/// (The original's mixes in its meshes' addresses: here the slot, the mesh
/// made there and its shape, and the pins themselves.)
fn key() u64 {
    const K: u64 = 0x9E3779B97F4A7C15;
    const b = anim.cur orelse return K;
    var h: u64 = 0;
    var i: usize = 0;
    while (i < CW_SZ) : (i += 8) {
        h ^= std.mem.readInt(u64, b.rest[REST_CW + i ..][0..8], .little);
        h *%= K;
    }
    for (0..ncl(b)) |k| {
        const r = entry(b, k);
        i = 0;
        while (i < 40) : (i += 8) {
            h ^= std.mem.readInt(u64, r[i..][0..8], .little);
            h *%= K;
        }
        const oi = entryObj(r) orelse continue;
        const mi = scene.objects[oi].mesh.?;
        const me = &scene.meshes[mi].?;
        h ^= @as(u64, mi) | @as(u64, me.serial) << 32;
        h *%= K;
        h ^= me.shape;
        h *%= K;
        h = sc.mix(h ^ me.pin.len, me.pin);
    }
    h = fields.animHash(h);
    const fr = frange.r;
    var se: [3]u32 = .{ @bitCast(fr.start), @bitCast(fr.end), @bitCast(fr.fps) };
    h = sc.mix(h, std.mem.asBytes(&se));
    if (b.h.nrb != 0) {
        h ^= sc.keyOf(0);
        h *%= K;
    }
    for (0..ncl(b)) |k| {
        const oi = entryObj(entry(b, k)) orelse continue;
        const o = &scene.objects[oi];
        if (!anim.moves(o.oid)) {
            const rad = o.radians();
            const p = [9]f32{ o.loc[0], o.loc[1], o.loc[2], rad[0], rad[1], rad[2], o.scl[0], o.scl[1], o.scl[2] };
            h = sc.mix(h, std.mem.asBytes(&p));
        }
        h = sc.meshHash(h, scene.meshOfObj(oi));
    }
    return fields.mix(h);
}

fn nowMs() i64 {
    return @intCast(rc.nowNs() / 1000000);
}

/// cl_frame: the simulation at that frame: none at or before the start; a
/// cached frame played back; else stepped on (begun again when going back or
/// the key changed), each whole frame reached kept.
pub fn frame(f: f32) void {
    if (busy) return;
    busy = true;
    defer busy = false;
    const b = anim.cur orelse return gone();
    if (rd(&b.rest, REST_CW + CW_N) == 0) return gone();
    const fr = frange.r;
    const start: f32 = @floatFromInt(fr.start);
    const k = key();
    const baked = sc.check(1, k, fr.start);
    if (!(f > start)) return free();
    var fi = cvtt(f);
    const fx: f32 = @floatFromInt(fi);
    var look = baked;
    if (baked) {
        fi = @min(fi, sc.last(1));
    } else if (f == fx or std.math.isNan(f)) look = true;
    if (look) {
        if (sc.get(1, fi)) |r| {
            play(r, k);
            return;
        }
    }
    if (baked) return;
    var fresh = true;
    if (on) {
        if (k == hash and f >= fnow) fresh = false else free();
    }
    if (fresh) {
        build();
        if (!on) return;
        hash = k;
        time = 0;
    }
    const t0 = nowMs();
    const fps: f32 = if (fr.fps > 0) fr.fps else 24.0;
    const target = (f - start) / fps;
    while (true) {
        // a whole frame reached: kept
        const nx = sc.last(1) +% 1;
        const xf: f32 = @floatFromInt(nx);
        if (!(xf > f)) {
            var t = xf - start;
            t = t / fps;
            var x1 = dt * cq_half;
            x1 += time;
            if (x1 >= t) {
                if (record(nx)) continue;
            }
        }
        var x2 = dt * cq_half;
        x2 += time;
        if (x2 >= target) break;
        step();
        time += dt;
    }
    ms = @floatFromInt(nowMs() - t0);
    fnow = f;
    output();
    app.dirty = true;
}

fn gone() void {
    sc.clear(1);
    free();
}

/// rec_size: a cloth's part of a cached frame.
fn recSize(n: u32) usize {
    return (@as(usize, n) * 6 + 32 + 3) & ~@as(usize, 3);
}

/// cl_record: each cloth's shown vertices into the cache: count, then uid,
/// vertices, the low corner, the step, three u16 a vertex. False: not kept.
fn record(f: i32) bool {
    output();
    var size: usize = 4;
    for (cr[0..nc]) |*c| size += recSize(c.np);
    const r = sc.add(1, f, size) orelse return false;
    wr(r, 0, nc);
    var o: usize = 4;
    for (cr[0..nc]) |*c| {
        wr(r, o, scene.uidOfOid(c.oid) orelse 0);
        wr(r, o + 4, c.np);
        var lo: V4 = .{ 1e30, 1e30, 1e30, 0 };
        var hi: V4 = .{ -1e30, -1e30, -1e30, 0 };
        const vs = if (c.has_out) c.out.verts else &.{};
        for (0..c.np) |k| {
            const v = if (k < vs.len) ld3(vs[k]) else V4{ 0, 0, 0, 0 };
            lo = minps(lo, v);
            hi = maxps(hi, v);
        }
        lo = andXyz(lo);
        hi = andXyz(hi);
        const ext = hi - lo;
        const stp = ext * inv16;
        const ok = tiny4 < ext;
        const scl0 = q16 / maxps(ext, tiny4);
        const scl: V4 = @select(f32, ok, scl0, @as(V4, @splat(0)));
        inline for (0..3) |q| {
            wrf(r, o + 8 + q * 4, lo[q]);
            wrf(r, o + 20 + q * 4, stp[q]);
        }
        var w = o + 32;
        for (0..c.np) |k| {
            const v = if (k < vs.len) ld3(vs[k]) else V4{ 0, 0, 0, 0 };
            const qv = (v - lo) * scl;
            inline for (0..3) |q| {
                var iv = cvtn(qv[q]);
                if (iv > 65535) iv = 65535;
                if (iv < 0) iv = 0;
                std.mem.writeInt(u16, r[w + q * 2 ..][0..2], @intCast(iv), .little);
            }
            w += 6;
        }
        o += recSize(c.np);
    }
    return true;
}

/// cl_play: a cached frame into the cloths' shown meshes (the simulation
/// made, at its start, when there is none). (A record from a damaged file is
/// read only as far as it goes.)
fn play(r: []const u8, k: u64) void {
    defer app.dirty = true;
    if (!on) {
        build();
        if (!on) return;
        hash = k;
        time = 0;
        fnow = @floatFromInt(frange.r.start);
    }
    if (r.len < 4) return;
    var n = rd(r, 0);
    var o: usize = 4;
    while (n != 0) : (n -= 1) {
        if (o + 32 > r.len) return;
        const u = rd(r, o);
        const cnt = rd(r, o + 4);
        defer o += recSize(cnt);
        const oi = scene.findUid(u) orelse continue;
        const oid = scene.objects[oi].oid;
        var c: ?*Cr = null;
        for (cr[0..nc]) |*q| {
            if (q.oid == oid) {
                c = q;
                break;
            }
        }
        const cl = c orelse continue;
        if (cnt != cl.np or !cl.has_out or cnt != cl.out.verts.len) continue;
        if (o + 32 + @as(usize, cnt) * 6 > r.len) return;
        const lo = V4{ rdf(r, o + 8), rdf(r, o + 12), rdf(r, o + 16), 0 };
        const stp = V4{ rdf(r, o + 20), rdf(r, o + 24), rdf(r, o + 28), 0 };
        var p = o + 32;
        for (cl.out.verts) |*v| {
            const qv = V4{
                @floatFromInt(std.mem.readInt(u16, r[p..][0..2], .little)),
                @floatFromInt(std.mem.readInt(u16, r[p + 2 ..][0..2], .little)),
                @floatFromInt(std.mem.readInt(u16, r[p + 4 ..][0..2], .little)),
                0,
            };
            const w = qv * stp + lo;
            v.* = .{ w[0], w[1], w[2] };
            p += 6;
        }
        touched(&cl.out);
    }
}

/// cl_output: each cloth's particles into its shown mesh (object space).
fn output() void {
    for (cr[0..nc]) |*c| {
        if (!c.has_out) continue;
        const inv = mInv(&c.mat);
        for (0..c.np) |k| {
            const p = x[c.p0 + k];
            if (k < c.out.verts.len) c.out.verts[k] = xform(&inv, .{ p[0], p[1], p[2] });
        }
        touched(&c.out);
    }
}

/// cl_info: 0 cloths, 1 particles, 2 constraints, 3 colours in use, 4 the
/// last frame's time (ms), 5 collisions in the last step, 6 collider triangles.
pub fn info(what: i32) f32 {
    if (!on) return 0;
    const v: u32 = switch (what) {
        0 => nc,
        1 => np,
        2 => nd,
        3 => blk: {
            var n: u32 = 0;
            for (0..NCOL) |k| {
                if (bs[k + 1] != bs[k]) n += 1;
            }
            break :blk n;
        },
        4 => return ms,
        5 => hits.load(.monotonic),
        else => nct,
    };
    return @floatFromInt(v);
}

// ---- the operators ------------------------------------------------------------------------

const Cur = struct {
    s: []const u8,
    i: usize = 0,
    w: [256]u8 = undefined,
    n: usize = 0,
    fn at(c: *const Cur, k: usize) u8 {
        return if (k < c.s.len) c.s[k] else 0;
    }
    /// im_next_word: the next word (spaces part them): its length.
    fn next(c: *Cur) usize {
        c.n = 0;
        while (c.at(c.i) == ' ') c.i += 1;
        while (true) : (c.i += 1) {
            const ch = c.at(c.i);
            if (ch == 0 or ch == ' ') break;
            if (c.n < 255) {
                c.w[c.n] = ch;
                c.n += 1;
            }
        }
        return c.n;
    }
    fn word(c: *const Cur) []const u8 {
        return c.w[0..c.n];
    }
    /// cw_num: the next word, a number.
    fn num(c: *Cur) ?f32 {
        if (c.next() == 0) return null;
        return @import("mech.zig").parseFloat(c.word());
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const cl_keys = [_][]const u8{ "stretch", "bend", "volume", "mass", "damping", "thickness", "friction" };
/// (stretch 0, bend 0.01, volume 0, mass 1, damping 0.1, thickness 0.02, friction 0.3)
const cl_defaults = [10]u32{ 0, 1, 0, 0x3c23d70a, 0, 0x3f800000, 0x3dcccccd, 0x3ca3d70a, 0x3e99999a, 0 };
const s_cl_bad = "  cloth.add [cloth|soft|collider] [stretch c] [bend c] [volume c] [mass m] [damping d] [thickness t] [friction f] [self] - not understood: ";
const s_pin_bad = "  cloth.pin selected | all | none | above <x|y|z> <value> | below <x|y|z> <value>";
const s_cw_bad = "  cloth.world [wind x y z] [substeps n] [rate n] - not understood: ";

fn drop(parts: []const []const u8) void {
    say(parts);
    undo.replaceCurrent();
}

/// cloth.add [cloth|soft|collider] [key value ...] [self]
fn opAdd() void {
    addText(ops.arg, false);
}

/// The fields of the Physics tab: their values on the selection (no step of
/// its own: the field's). `noself`: the self toggle turned off (the
/// original's cl_cb cannot: cloth.add has no word for it).
pub fn addFromPanel(arg: []const u8, noself: bool) void {
    addText(arg, noself);
}

fn addText(arg: []const u8, noself: bool) void {
    var vals = cl_defaults;
    var given: u32 = 0;
    var c = Cur{ .s = arg };
    while (c.next() != 0) {
        const w = c.word();
        const t: u32 = if (eq(w, "cloth")) 1 else if (eq(w, "soft")) 2 else if (eq(w, "collider")) 3 else 0;
        if (t != 0) {
            vals[1] = t;
            given |= 1 << 1;
            continue;
        }
        if (eq(w, "self")) {
            vals[9] |= 1;
            given |= 1 << 9;
            continue;
        }
        var k: ?usize = null;
        for (cl_keys, 0..) |kk, q| {
            if (eq(w, kk)) k = q;
        }
        const kx = k orelse return drop(&.{ s_cl_bad, c.word() });
        const v = c.num() orelse return drop(&.{ s_cl_bad, c.word() });
        vals[2 + kx] = @bitCast(maxss(v, 0));
        given |= @as(u32, 1) << @intCast(kx + 2);
    }
    const b = anim.own(0) orelse return drop(&.{"  no room for more cloth objects"});
    var done: u32 = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (!o.selected or !isMeshType(o.kind)) continue;
        const n = rd(&b.rest, REST_CW + CW_N);
        var r: ?[]u8 = null;
        for (0..@min(n, CL_MAX)) |k| {
            if (rd(entry(b, k), CL_UID) == o.oid) {
                r = entry(b, k);
                break;
            }
        }
        if (r == null) {
            if (n >= CL_MAX) return drop(&.{"  no room for more cloth objects"});
            wr(&b.rest, REST_CW + CW_N, n + 1);
            const e = entry(b, n);
            @memset(e, 0);
            for (0..10) |q| wr(e, q * 4, cl_defaults[q]);
            wr(e, CL_UID, o.oid);
            r = e;
        }
        const e = r.?;
        for (0..10) |q| {
            if (given >> @intCast(q) & 1 != 0) wr(e, q * 4, vals[q]);
        }
        if (noself) wr(e, CL_FLAGS, rd(e, CL_FLAGS) & ~@as(u32, 1));
        done += 1;
    }
    if (done == 0) return drop(&.{"  select mesh objects first"});
    var nb: [16]u8 = undefined;
    say(&.{ "  cloth objects: ", std.fmt.bufPrint(&nb, "{d}", .{rd(&b.rest, REST_CW + CW_N)}) catch "" });
}

/// cloth.remove: the selected objects' entries go (the last into its place).
fn opRemove() void {
    const b = anim.own(0) orelse return;
    for (scene.objects[0..scene.count]) |*o| {
        if (!o.selected) continue;
        const n = @min(rd(&b.rest, REST_CW + CW_N), CL_MAX);
        for (0..n) |k| {
            if (rd(entry(b, k), CL_UID) != o.oid) continue;
            wr(&b.rest, REST_CW + CW_N, n - 1);
            if (k != n - 1) @memcpy(entry(b, k), entry(b, n - 1));
            break;
        }
    }
}

/// cloth.pin selected | all | none | above / below <axis> <value>: the pin
/// group of the selected meshes (a copy of the mesh: undo keeps the old one).
fn opPin() void {
    var c = Cur{ .s = ops.arg };
    _ = c.next();
    const w = c.word();
    const mode: u32 = if (eq(w, "selected")) 0 else if (eq(w, "all")) 1 else if (eq(w, "none")) 2 else if (eq(w, "above")) 3 else if (eq(w, "below")) 4 else return drop(&.{s_pin_bad});
    var axis: usize = 0;
    var val: f32 = 0;
    if (mode >= 3) {
        _ = c.next();
        const ch: u32 = if (c.n > 0) c.w[0] else 0;
        const ax = ch -% 'x';
        if (ax > 2) return drop(&.{s_pin_bad});
        axis = ax;
        val = c.num() orelse return drop(&.{s_pin_bad});
    }
    const em = @import("editmesh.zig");
    var pinned: u32 = 0;
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.selected or !isMeshType(o.kind)) continue;
        const mi0 = o.mesh orelse continue;
        if (scene.meshes[mi0] == null) continue;
        const mi = scene.cloneMesh(mi0) orelse continue;
        const me = &scene.meshes[mi].?;
        if (me.pin.len != me.verts.len) {
            const p = A.alloc(u8, me.verts.len) catch {
                scene.freeMeshSlot(mi);
                continue;
            };
            @memset(p, 0);
            const keep = @min(p.len, me.pin.len);
            @memcpy(p[0..keep], me.pin[0..keep]);
            if (me.pin.len > 0) A.free(me.pin);
            me.pin = p;
        }
        o.mesh = mi;
        // the selected vertices: edit mode's own while it is on this object
        const sel: []const bool = if (em.active and em.obj == oi) em.sel else me.vsel;
        for (me.pin, 0..) |*p, v| {
            const on_ = switch (mode) {
                1 => true,
                2 => false,
                0 => v < sel.len and sel[v],
                3 => me.verts[v][axis] >= val,
                else => !(me.verts[v][axis] > val),
            };
            p.* = @intFromBool(on_);
            if (on_) pinned += 1;
        }
    }
    var nb: [16]u8 = undefined;
    say(&.{ "  pinned: ", std.fmt.bufPrint(&nb, "{d}", .{pinned}) catch "" });
    app.dirty = true;
}

/// cloth.world [wind x y z] [substeps n] [rate n]
fn opWorld() void {
    worldText(ops.arg);
}

/// The Cloth World fields (no step of their own: the field's).
pub fn worldFromPanel(arg: []const u8) void {
    worldText(arg);
}

fn worldText(arg: []const u8) void {
    const b = anim.own(0) orelse return;
    var c = Cur{ .s = arg };
    while (c.next() != 0) {
        const w = c.word();
        if (eq(w, "wind")) {
            for (0..3) |k| {
                const v = c.num() orelse return drop(&.{ s_cw_bad, c.word() });
                wrf(&b.rest, REST_CW + CW_WIND + k * 4, v);
            }
            continue;
        }
        const o: usize = if (eq(w, "substeps")) CW_SUB else if (eq(w, "rate")) CW_RATE else return drop(&.{ s_cw_bad, c.word() });
        const v = c.num() orelse return drop(&.{ s_cw_bad, c.word() });
        var n = cvtt(v);
        if (n < 1) n = 1;
        if (n > 500) n = 500;
        wr(&b.rest, REST_CW + o, @bitCast(n));
    }
}

pub const list = .{
    .{ "cloth.add", ops.Impl{ .run = opAdd } },
    .{ "cloth.remove", ops.Impl{ .run = opRemove } },
    .{ "cloth.pin", ops.Impl{ .run = opPin } },
    .{ "cloth.world", ops.Impl{ .run = opWorld } },
};

// ---- the MPIN chunk: per mesh with pins (by its place among the MESH chunks):
// index, vertices, a byte each ----------------------------------------------------------------

pub fn writePins(out: anytype, mesh_ix: []const u32) void {
    // (in the order of the MESH chunks, as the original's mesh table)
    var n: u32 = 0;
    for (mesh_ix) |ix| {
        if (ix != 0xffffffff and ix + 1 > n) n = ix + 1;
    }
    var ix: u32 = 0;
    while (ix < n) : (ix += 1) {
        for (mesh_ix, 0..) |q, mi| {
            if (q != ix) continue;
            const me = &(scene.meshes[mi] orelse break);
            if (me.pin.len == 0) break;
            out.u32_(ix);
            out.u32_(@intCast(me.verts.len));
            for (0..me.verts.len) |v| out.bytes(&.{if (v < me.pin.len) me.pin[v] else 0});
            break;
        }
    }
}

/// mpin_read: a record that runs past the end ends it; one that does not
/// fit its mesh is left out.
pub fn readPins(c: []const u8, map: []const ?u16) void {
    var o: usize = 0;
    while (c.len - o >= 8) {
        const ix = rd(c, o);
        const n = rd(c, o + 4);
        if (n > 0x8000000) return;
        if (@as(usize, n) + 8 > c.len - o) return;
        defer o += @as(usize, n) + 8;
        if (ix >= map.len) continue;
        const mi = map[ix] orelse continue;
        const me = &(scene.meshes[mi] orelse continue);
        if (n != me.verts.len) continue;
        if (me.pin.len != n) {
            if (me.pin.len > 0) A.free(me.pin);
            me.pin = A.alloc(u8, n) catch &.{};
            if (me.pin.len != n) continue;
        }
        @memcpy(me.pin, c[o + 8 ..][0..n]);
    }
}

// ---- tests ---------------------------------------------------------------------------------

test "cell slots and rounding as the original's" {
    try std.testing.expectEqual(@as(u32, 0), slotOf(.{ 0, 0, 0 }, 1023));
    try std.testing.expectEqual(@as(u32, (HX ^ HY ^ HZ) & 1023), slotOf(.{ 1, 1, 1 }, 1023));
    try std.testing.expectEqual(@as(u32, (0 -% HX) & 4095), slotOf(.{ -1, 0, 0 }, 4095));
    try std.testing.expectEqual(@as(i32, 2), cvtn(2.5));
    try std.testing.expectEqual(@as(i32, 4), cvtn(3.5));
    try std.testing.expectEqual(@as(i32, -2), cvtn(-2.5));
    try std.testing.expectEqual(@as(i32, 3), cvtn(2.5000002));
    try std.testing.expectEqual(std.math.minInt(i32), cvtn(std.math.nan(f32)));
    try std.testing.expectEqual(std.math.minInt(i32), cvtt(3e9));
    try std.testing.expectEqual(@as(usize, 40), recSize(1)); // (6 + 32, to 4)
    try std.testing.expectEqual(@as(usize, 32 + 24), recSize(4));
}

test "edges once, their triangles; far corners" {
    var tab: [32]Edge = @splat(.{ 0, 0, 0, 0 });
    // two triangles sharing 1-2
    edgePut(&tab, 31, 0, 1, 0);
    edgePut(&tab, 31, 1, 2, 0);
    edgePut(&tab, 31, 2, 0, 0);
    edgePut(&tab, 31, 2, 1, 1);
    edgePut(&tab, 31, 1, 3, 1);
    edgePut(&tab, 31, 3, 2, 1);
    var n: u32 = 0;
    var shared: u32 = 0;
    for (tab) |e| {
        if (e[0] == 0) continue;
        n += 1;
        if (e[3] != 0) {
            shared += 1;
            try std.testing.expectEqual(@as(u32, 1 + 1), e[0]);
            try std.testing.expectEqual(@as(u32, 2), e[1]);
        }
    }
    try std.testing.expectEqual(@as(u32, 5), n);
    try std.testing.expectEqual(@as(u32, 1), shared);
}
