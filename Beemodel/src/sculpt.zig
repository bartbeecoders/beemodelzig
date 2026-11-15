// Sculpt mode (sculpt.s). The mesh is split into leaves of a bounding-volume
// hierarchy - about a thousand triangles each, by spatial median splits - with
// each leaf's triangles, its vertices (each listed once per leaf, its own ones
// first) and its box. Vertex normals are kept per vertex. A brush dab finds the
// leaves its sphere touches and changes only their vertices; their boxes and the
// normals around them follow. Strokes record the first old position of every
// vertex they move: the undo step carries those deltas (undo.Delta), not a copy
// of the mesh, which is changed in place: all the steps that hold it see it through
// the deltas between them.
//
// Each pass over the leaves in reach runs in parallel: a vertex belongs to one
// leaf, so no two threads meet; sums over vertices of other leaves are atomic.
// That makes the last bits of a float depend on the threads' order, as in the
// original: with one thread (taskset) both give the same bytes.
//
// Drawing is sculptdraw.zig; the stroke's pressure, stabilizer, dab spacing and
// brush cursor stroke.zig; the bar, the tools and the operators sculptui.zig.
//
// What comes next hangs on `ext`: dynamic topology (dyntopo.s) gives the arrays
// room and a mesh of its own (capv, capt, pos, tris), multires (multires.s) sculpts
// a copy of a level, a landscape (lsculpt.s, phase 11) takes the mode whole (land).
const std = @import("std");
const linux = std.os.linux;
const m = @import("math.zig");
const scene = @import("scene.zig");
const jobs = @import("jobs.zig");
const arm = @import("arm.zig");
const app = @import("app.zig");
const undo = @import("undo.zig");
const stroke = @import("stroke.zig");
const draw = @import("sculptdraw.zig");
const vp = @import("viewport.zig");
const gfx = @import("gfx.zig");
const dyntopo = @import("dyntopo.zig");
const multires = @import("multires.zig");

const V3 = m.V3;
pub const trunc32 = stroke.trunc32;
pub const minss = stroke.minss;
pub const maxss = stroke.maxss;

// sculpt.inc --------------------------------------------------------------------
pub const LEAF = 1024; // triangles per leaf (at most)
pub const Node = extern struct {
    min: V3,
    max: V3,
    toff: u32,
    tn: u32,
    voff: u32,
    vn: u32,
    flags: u32,
    /// the first ones in its list: its own
    vown: u32,
    /// room for triangles / vertices in the pools (dyntopo grows the lists)
    tcap: u32,
    vcap: u32,
};
comptime {
    std.debug.assert(@sizeOf(Node) == 56);
}

pub const DRAW = 0;
pub const CLAY = 1;
pub const CREASE = 2;
pub const INFLATE = 3;
pub const GRAB = 4;
pub const SNAKE = 5;
pub const SMOOTH = 6;
pub const FLATTEN = 7;
pub const PINCH = 8;
pub const LAYER = 9;
pub const MASK = 10;
pub const NBRUSH = 11;

pub const brush_names = [NBRUSH][]const u8{ "draw", "clay strips", "crease", "inflate", "grab", "snake hook", "smooth", "flatten", "pinch", "layer", "mask" };
pub const fall_names = [6][]const u8{ "smooth", "sphere", "root", "sharp", "linear", "constant" };

const sf_big: f32 = 3.0e38;
const sf_nbig: f32 = -3.0e38;
const sf_tenth: f32 = 0.1;
const sf_tiny: f32 = 1.0e-20;
pub const sf_mask: f32 = 0.003921569; // 1/255

// the settings (kept while the program runs, as the original's) ------------------
pub var radius: f32 = 50; // pixels
pub var strength: f32 = 0.5;
pub var brush: u32 = DRAW;
pub var sym: u32 = 0; // mirrors: bit 0 X, 1 Y, 2 Z
pub var falloff_kind: u32 = 0; // 0 smooth, 1 sphere, 2 root, 3 sharp, 4 linear, 5 constant

// what dyntopo, multires and landscapes hook into --------------------------------
pub const Ext = struct {
    /// dyn_alloc: `pos`, `tris`, `capv`, `capt` its own copies with room. False: no memory.
    alloc: ?*const fn () bool = null,
    /// dyn_tail: pool room and owners, once the lists are made.
    tail: ?*const fn () void = null,
    /// dyn_free, with the mode's arrays.
    free: ?*const fn () void = null,
    /// dyn_reset, as a stroke begins.
    reset: ?*const fn () void = null,
    /// dyn_after_dab(radius, mirror).
    after_dab: ?*const fn (f32, u32) void = null,
    /// sc_dyn: dynamic topology is on: a stroke's end commits instead of recording deltas.
    dyn: ?*const fn () bool = null,
    /// dyn_commit, at a stroke's end.
    commit: ?*const fn () void = null,
    /// mr_target: what object i sculpts, when not its mesh.
    target: ?*const fn (usize) ?*scene.Mesh = null,
    /// mr_owns: multires holds this mesh.
    owns: ?*const fn () bool = null,
    /// mr_stroke_end: the deltas (d_idx, d_old) go to the displacements.
    stroke_end: ?*const fn () void = null,
    /// mr_drop, leaving the mode.
    drop: ?*const fn () void = null,
    /// ls_enter: a landscape takes the mode (`land`).
    land_enter: ?*const fn (usize) bool = null,
};
pub var ext: Ext = .{
    .alloc = dyntopo.alloc,
    .tail = dyntopo.tail,
    .free = dyntopo.free,
    .reset = dyntopo.reset,
    .after_dab = dyntopo.afterDab,
    .dyn = dyntopo.dyn,
    .commit = dyntopo.commit,
    .target = multires.target,
    .owns = multires.owns,
    .stroke_end = multires.strokeEnd,
    .drop = multires.drop,
    .land_enter = @import("lsculpt.zig").enter,
};
/// sc_land: a landscape's own brushes have the mode (lsculpt.zig, phase 11):
/// press, drag, release and drawing go there, none of what is below.
pub var land: bool = false;

// the mode -----------------------------------------------------------------------
pub var on: bool = false;
/// The object's identity (an index moves with undo and deletes), and its index now.
pub var oid: u32 = 0;
pub var obj: usize = 0;
pub var mesh: ?*scene.Mesh = null;
var mesh_mi: ?u16 = null; // its slot (null: multires' copy)
var mesh_serial: u32 = 0;
/// Moves whenever what the viewport shows of the sculpted mesh does.
pub var version: u32 = 0;

pub var nv: u32 = 0;
pub var nt: u32 = 0;
/// Room in the per-vertex and per-triangle arrays (dyntopo: more than nv, nt).
pub var capv: u32 = 0;
pub var capt: u32 = 0;
/// The positions and triangles dabs work on: the mesh's (dyntopo: its copy).
pub var pos: [*]V3 = undefined;
pub var tris: [*][3]u32 = undefined;

pub var nodes: []Node = &.{};
pub var nnodes: u32 = 0;
pub var tri: []u32 = &.{}; // triangle ids, by leaf
pub var vl: []u32 = &.{}; // vertex lists, by leaf
pub var nvl: u32 = 0;
pub var vn: []V3 = &.{}; // vertex normals
pub var mask: []u8 = &.{}; // a byte a vertex
pub var masked: bool = false; // false: no vertex is masked (not read)
pub var stamp: []u32 = &.{};
pub var rec: []u8 = &.{}; // recorded this stroke
pub var acc: [][4]f32 = &.{}; // smoothing: sum of neighbours, count
var serial: u32 = 0;
pub var hits: []u32 = &.{}; // leaves in reach: 3 lists of nnodes
pub var nh: [3]u32 = .{ 0, 0, 0 };
pub var maxedge: f32 = 0;
pub var sc_m: arm.M = undefined; // the matrix and its inverse
pub var sc_mi: arm.M = undefined;

/// per leaf: 1 = changed since drawn (sculptdraw.zig reads and clears it)
pub var lchg: []u8 = &.{};
/// 1: project every leaf again
pub var full: bool = true;

/// Its positions changed under us (undo): boxes and normals again before they are used.
var refresh_due = false;

// a stroke -----------------------------------------------------------------------
pub var stroking: bool = false;
var invert: bool = false;
pub var brush_now: u32 = DRAW;
var last: V3 = undefined; // the last dab (local)
var lastr: f32 = 0; // local radius
var gplane: f32 = 0; // grab: depth of its plane (camera z)
var gstart: V3 = undefined;
var base_s: f32 = 0; // the stroke's strength (signed)
var penon: bool = false; // a stroke by hand (pressure counts)
pub var way: stroke.Way = .{};

pub var d_idx: []u32 = &.{}; // the stroke's deltas: index, old xyz
pub var d_old: []V3 = &.{};
pub var d_n = std.atomic.Value(u32).init(0);
var d_cap: u32 = 0;
var g_idx: []u32 = &.{}; // grab: captured vertices, weights
var g_w: []f32 = &.{};
var g_n: u32 = 0;

// a dab's working values
pub var dab_p: V3 = undefined;
pub var dab_n: V3 = undefined; // the area normal
var dab_c: V3 = undefined; // the area centre
pub var dab_r: f32 = 0;
var dab_s: f32 = 0; // strength (signed)
var dab_move: V3 = .{ 0, 0, 0 }; // grab / snake: the move
var pk_o: V3 = undefined; // picking ray (local)
var pk_d: V3 = undefined;
var pk_p: V3 = undefined;
var pk_t: f32 = 0;
var pk_tleaf: []f32 = &.{}; // per leaf: where the ray enters
var nn_r1: f32 = 0;
var nd_on = false; // normals due in a sphere
var nd_c: V3 = undefined;
var nd_r: f32 = 0;

const Slot = extern struct { s: [7]f32 align(64) };
var slots: [130]Slot = undefined;
var dummy: u8 = 0;

// memory: zero pages, mapped and given back whole ----------------------------------

pub fn smap(comptime T: type, n: usize) ?[]T {
    if (n == 0) return &[_]T{};
    const bytes = n * @sizeOf(T);
    const rc = linux.mmap(null, std.mem.alignForward(usize, bytes, 4096), .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const p: [*]T = @ptrFromInt(rc);
    return p[0..n];
}

pub fn sfree(s: anytype) void {
    const T = @typeInfo(@TypeOf(s.*)).pointer.child;
    if (s.len > 0) _ = linux.munmap(@ptrCast(s.ptr), std.mem.alignForward(usize, s.len * @sizeOf(T), 4096));
    s.* = &.{};
}

fn alloc2(comptime T: type, s: *[]T, n: usize) bool {
    sfree(s);
    s.* = smap(T, n) orelse return false;
    return true;
}

// entering, leaving -----------------------------------------------------------------

/// Another object shows this mesh, or a new one would (the primitives).
fn sharedMesh(i: usize, mi: u16) bool {
    for (scene.prim) |p| {
        if (p == mi) return true;
    }
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (k != i and o.mesh == mi) return true;
    }
    return false;
}

/// Its own mesh: copied when another object shows it. Steps may keep the mesh
/// (they see it through the deltas); what the scene shares with itself they cannot.
fn ownMesh(i: usize) bool {
    const o = &scene.objects[i];
    const mi = o.mesh orelse return false;
    if (!sharedMesh(i, mi)) return true;
    const c = scene.cloneMesh(mi) orelse return false;
    o.mesh = c;
    undo.absorbMesh(i); // (the copy is what the step the scene is at shows)
    return true;
}

fn activeMeshOf(i: usize) ?*scene.Mesh {
    if (ext.target) |t| {
        if (t(i)) |me| return me;
    }
    const mi = scene.objects[i].mesh orelse return null;
    if (scene.meshes[mi]) |*me| return me;
    return null;
}

/// sculpt_enter(object) -> false: it says why.
pub fn enter(i: usize) bool {
    if (i >= scene.count) return need();
    const o = &scene.objects[i];
    if (!o.kind.isMesh() or o.mesh == null) return need();
    const me0 = scene.meshOfObj(i) orelse return need();
    if (me0.tris.len == 0) return need();
    const em = @import("editmesh.zig");
    if (em.active) em.exit(); // (not with edit mode)
    @import("paint.zig").exit(); // (nor a paint mode)
    if (on) exit();
    if (ext.land_enter) |le| { // a landscape: its own brushes (lsculpt.zig)
        if (le(i)) {
            land = true;
            on = true;
            oid = o.oid;
            obj = i;
            return true;
        }
    }
    if (!ownMesh(i)) return noMem();
    on = true;
    oid = o.oid;
    obj = i;
    if (!build(i)) {
        on = false;
        return noMem();
    }
    version +%= 1;
    app.dirty = true;
    app.toast(.ok, "sculpt mode: {d} triangles in {d} leaves", .{ nt, nnodes });
    return true;
}

fn need() bool {
    app.toast(.warn, "sculpt mode: select a mesh", .{});
    app.dirty = true;
    return false;
}

fn noMem() bool {
    app.toast(.warn, "sculpt mode: out of memory", .{});
    app.dirty = true;
    return false;
}

/// sculpt_exit - the arrays go; the mesh stays as sculpted.
pub fn exit() void {
    if (!on) return;
    if (land) {
        @import("lsculpt.zig").release(); // (a stroke left half way ends)
        land = false;
    } else {
        finishStroke();
        if (mesh_mi) |mi| {
            // edited in place: a new version (caches keyed by it)
            if (scene.meshes[mi] != null and scene.meshes[mi].?.serial == mesh_serial) scene.bumpShape(mi);
        }
        freeAll();
        draw.free();
        if (ext.drop) |d| d();
    }
    on = false;
    oid = 0;
    mesh = null;
    mesh_mi = null;
    stroking = false;
    version +%= 1;
    app.dirty = true;
}

/// A new scene: nothing here points at it (no stroke to close: its mesh is gone).
pub fn sceneReplaced() void {
    if (!on) return;
    stroking = false;
    mesh = null;
    mesh_mi = null;
    exit();
}

fn freeAll() void {
    if (ext.free) |f| f();
    sfree(&nodes);
    sfree(&tri);
    sfree(&vl);
    sfree(&vn);
    sfree(&mask);
    sfree(&stamp);
    sfree(&rec);
    sfree(&acc);
    sfree(&hits);
    sfree(&lchg);
    sfree(&pk_tleaf);
    draw.freeLeaves();
    nnodes = 0;
    masked = false;
}

fn sameMesh(me: *const scene.Mesh) bool {
    if (mesh != me or me.serial != mesh_serial) return false;
    // (dyntopo works on its copy: the mesh is the same while it stays)
    if (ext.dyn == null or !ext.dyn.?()) {
        if (me.verts.ptr != pos or me.verts.len != nv or me.tris.len != nt) return false;
    }
    return true;
}

/// What the arrays were made from is still the object's.
fn stillOurs() bool {
    const i = scene.findOid(oid) orelse return false;
    const me = activeMeshOf(i) orelse return false;
    return sameMesh(me);
}

/// sculpt_valid -> the sculpt object is there: rebuilt when its mesh changed under
/// us (undo of another kind), or the mode ends.
pub fn valid() bool {
    if (!on) return false;
    if (land) return true;
    const i = scene.findOid(oid) orelse {
        exit();
        return false;
    };
    obj = i;
    const o = &scene.objects[i];
    if (!o.kind.isMesh() or o.mesh == null) {
        exit();
        return false;
    }
    const me = activeMeshOf(i) orelse {
        exit();
        return false;
    };
    if (me.tris.len == 0) {
        exit();
        return false;
    }
    if (!sameMesh(me)) {
        stroking = false; // (undo took what it worked on)
        if (!build(i)) {
            exit();
            return false;
        }
        version +%= 1;
    }
    sc_m = arm.objMat(i); // (it may have moved)
    sc_mi = arm.mInv(&sc_m);
    if (refresh_due) refreshAll();
    return true;
}

/// Every frame: the object or the mesh can go at any time.
pub fn validate() void {
    if (!on) return;
    // (a stroke by hand whose button went up where its viewport no longer is)
    // (BeeModel's or Zui's: the viewport is Zui's)
    if (stroking and penon and @import("ui.zig").down & @import("ui.zig").LMB == 0 and !@import("zuihost.zig").buttonDown(.left)) finishStroke();
    _ = valid();
}

// the hierarchy ------------------------------------------------------------------

/// sculpt_build(object): leaves, vertex lists, normals.
fn build(i: usize) bool {
    freeAll();
    const me = activeMeshOf(i) orelse return false;
    mesh = me;
    mesh_serial = me.serial;
    mesh_mi = null;
    if (scene.objects[i].mesh) |mi| {
        if (scene.meshes[mi]) |*x| {
            if (x == me) mesh_mi = mi;
        }
    }
    nv = @intCast(me.verts.len);
    nt = @intCast(me.tris.len);
    capv = nv;
    capt = nt;
    pos = me.verts.ptr;
    tris = me.tris.ptr;
    if (ext.alloc) |f| {
        if (!f()) return fail();
    }
    sc_m = arm.objMat(i);
    sc_mi = arm.mInv(&sc_m);
    // per-vertex arrays (with dyntopo's room)
    if (!alloc2(V3, &vn, capv) or !alloc2(u8, &mask, capv) or !alloc2(u32, &stamp, capv) or !alloc2(u8, &rec, capv)) return fail();
    masked = false;
    // triangle ids 0 .. n, then partitioned into leaves
    if (!alloc2(u32, &tri, capt)) return fail();
    for (0..nt) |k| tri[k] = @intCast(k);
    if (!alloc2(Node, &nodes, nt / (LEAF / 2) + 4)) return fail();
    nnodes = 0;
    if (!split(0, nt)) return fail();
    // vertex lists (each leaf lists its vertices once): first count with stamps,
    // then fill
    serial = 0;
    var pass: u32 = 0;
    while (pass < 2) : (pass += 1) {
        var total: u32 = 0;
        for (nodes[0..nnodes]) |*n| {
            serial += 1;
            const s = serial;
            n.voff = total;
            var sub: u32 = 0; // 0: vertices no leaf took yet (its own), 1: the rest
            while (sub < 2) : (sub += 1) {
                const t0 = n.toff;
                const t1 = t0 + n.tn;
                for (tri[t0..t1]) |t| {
                    for (tris[t]) |v| {
                        if (stamp[v] == s) continue;
                        if (sub == 0) {
                            if (rec[v] != 0) continue;
                            rec[v] = 1;
                        }
                        stamp[v] = s;
                        if (pass == 1) vl[total] = v;
                        total += 1;
                    }
                }
                if (sub == 0) n.vown = total - n.voff;
            }
            n.vn = total - n.voff;
        }
        @memset(rec[0..nv], 0); // (taken marks off for each pass)
        if (pass == 0) {
            nvl = total;
            // (dyntopo: room for the lists to move as they grow)
            const room_ = if (ext.dyn != null and ext.dyn.?()) 2 * @as(usize, total) + 65536 else total;
            if (!alloc2(u32, &vl, room_)) return fail();
        }
    }
    if (ext.tail) |f| f();
    // boxes, the longest edge, all normals; drawing records
    for (0..nnodes) |k| nodeBox(@intCast(k));
    maxEdge();
    normalsAll();
    if (!alloc2(u8, &lchg, nnodes) or !alloc2(u32, &hits, @as(usize, nnodes) * 3) or !alloc2(f32, &pk_tleaf, nnodes)) return fail();
    if (!draw.allocLeaves()) return fail();
    full = true;
    refresh_due = false;
    nd_on = false;
    return true;
}

fn fail() bool {
    freeAll();
    return false;
}

/// sculpt_build again (dyntopo: on or off, a stroke's mesh).
pub fn rebuild() bool {
    const i = scene.findOid(oid) orelse return false;
    obj = i;
    version +%= 1;
    return build(i);
}

/// 3 x a triangle's centroid's coordinate.
inline fn cent(t: u32, axis: usize) f32 {
    const q = tris[t];
    return pos[q[0]][axis] + pos[q[1]][axis] + pos[q[2]][axis];
}

fn addLeaf(lo: u32, hi: u32) bool {
    if (nnodes == nodes.len) {
        // (the original's room can run out on lopsided meshes: more)
        const bigger = smap(Node, nodes.len * 2) orelse return false;
        @memcpy(bigger[0..nnodes], nodes[0..nnodes]);
        sfree(&nodes);
        nodes = bigger;
    }
    nodes[nnodes] = std.mem.zeroes(Node);
    nodes[nnodes].toff = lo;
    nodes[nnodes].tn = hi - lo;
    nnodes += 1;
    return true;
}

/// Leaves of at most LEAF triangles: halves by the middle of the centroids' box
/// on its longest side (by count when they all sit together). An explicit stack.
fn split(first: u32, end: u32) bool {
    var stack: [64][2]u32 = undefined;
    stack[0] = .{ first, end };
    var sp: usize = 1;
    while (sp > 0) {
        sp -= 1;
        const lo = stack[sp][0];
        const hi = stack[sp][1];
        if (hi - lo <= LEAF) {
            if (!addLeaf(lo, hi)) return false;
            continue;
        }
        var bmin: V3 = .{ sf_big, sf_big, sf_big };
        var bmax: V3 = .{ sf_nbig, sf_nbig, sf_nbig };
        for (tri[lo..hi]) |t| {
            for (0..3) |c| {
                const x = cent(t, c);
                bmin[c] = minss(bmin[c], x);
                bmax[c] = maxss(bmax[c], x);
            }
        }
        var axis: usize = 0;
        var ext0 = bmax[0] - bmin[0];
        for (1..3) |c| {
            const e = bmax[c] - bmin[c];
            if (e > ext0) {
                ext0 = e;
                axis = c;
            }
        }
        const mid = (bmax[axis] + bmin[axis]) * 0.5;
        var i = lo; // partition: [lo, i) below the middle
        var j = hi;
        while (i < j) {
            if (!(cent(tri[i], axis) >= mid)) {
                i += 1;
                continue;
            }
            j -= 1;
            const t = tri[i];
            tri[i] = tri[j];
            tri[j] = t;
        }
        if (i == lo or i == hi) i = (hi - lo) / 2 + lo; // one side empty: by count
        if (sp >= 60) {
            // (the stack is deep enough for any mesh this side of 2^60 triangles)
            if (!addLeaf(lo, hi)) return false;
            continue;
        }
        stack[sp] = .{ lo, i };
        sp += 1;
        stack[sp] = .{ i, hi };
        sp += 1;
    }
    return true;
}

/// A leaf's box from its vertices.
pub fn nodeBox(k: u32) void {
    const n = &nodes[k];
    var a: V3 = .{ sf_big, sf_big, sf_big };
    var b: V3 = .{ sf_nbig, sf_nbig, sf_nbig };
    const p = pos;
    for (vl[n.voff .. n.voff + n.vn]) |v| {
        const q = p[v];
        for (0..3) |c| {
            a[c] = minss(a[c], q[c]);
            b[c] = maxss(b[c], q[c]);
        }
    }
    n.min = a;
    n.max = b;
}

inline fn edge2(a: u32, b: u32) f32 {
    const p = pos[a];
    const q = pos[b];
    const x = p[0] - q[0];
    const y = p[1] - q[1];
    const z = p[2] - q[2];
    return x * x + y * y + z * z;
}

/// The longest triangle edge.
fn maxEdge() void {
    var e: f32 = 0;
    for (tris[0..nt]) |t| {
        e = maxss(e, edge2(t[0], t[1]));
        e = maxss(e, edge2(t[1], t[2]));
        e = maxss(e, edge2(t[2], t[0]));
    }
    maxedge = @sqrt(e);
}

/// (b - a) x (c - a): twice the area.
pub inline fn faceN(t: u32) V3 {
    const q = tris[t];
    const a = pos[q[0]];
    const b = pos[q[1]];
    const c = pos[q[2]];
    const e1x = b[0] - a[0];
    const e1y = b[1] - a[1];
    const e1z = b[2] - a[2];
    const e2x = c[0] - a[0];
    const e2y = c[1] - a[1];
    const e2z = c[2] - a[2];
    return .{ e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x };
}

inline fn vnUnit(n: *V3) void {
    const l = maxss(@sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]), sf_tiny);
    const s = 1.0 / l;
    n[0] = n[0] * s;
    n[1] = n[1] * s;
    n[2] = n[2] * s;
}

/// Every vertex normal (area-weighted, unit).
fn normalsAll() void {
    full = true;
    @memset(std.mem.sliceAsBytes(vn[0..nv]), 0);
    for (0..nt) |t| {
        const f = faceN(@intCast(t));
        for (tris[t]) |v| {
            vn[v][0] = vn[v][0] + f[0];
            vn[v][1] = vn[v][1] + f[1];
            vn[v][2] = vn[v][2] + f[2];
        }
    }
    for (vn[0..nv]) |*n| vnUnit(n);
}

// picking: the pointer's ray against the leaves' triangles (local space) ---------------

/// pixels x, y through camera c: the point in pk_p, pk_t.
fn pick(c: *const vp.Cam, x: i32, y: i32) bool {
    const u = (@as(f32, @floatFromInt(x)) - c.cx) / c.f;
    const w = (c.cy - @as(f32, @floatFromInt(y))) / c.f;
    var dw: V3 = undefined;
    for (0..3) |k| dw[k] = c.right[k] * u + c.up[k] * w + c.fwd[k];
    pk_o = arm.xformPoint(&sc_mi, c.eye);
    pk_d = xformVec(&sc_mi, dw);
    pk_t = sf_big;
    var hit = false;
    // the leaves the ray enters, then nearest first until the best hit is nearer
    // than the next one's entry
    var count: usize = 0;
    const list = hits;
    for (nodes[0..nnodes], 0..) |*n, l| {
        const t = slab(n);
        if (t >= sf_big) continue;
        list[count] = @intCast(l);
        pk_tleaf[l] = t;
        count += 1;
    }
    while (count > 0) {
        var best: f32 = sf_big;
        var at: usize = 0;
        var found = false;
        for (list[0..count], 0..) |l, k| {
            const t = pk_tleaf[l];
            if (t < best) {
                best = t;
                at = k;
                found = true;
            }
        }
        if (!found or !(best < pk_t)) break; // nothing nearer can come
        const leaf = list[at];
        count -= 1;
        list[at] = list[count];
        const n = &nodes[leaf];
        for (tri[n.toff .. n.toff + n.tn]) |t| {
            const r = rayTri(t);
            if (!(r > 0)) continue;
            if (r >= pk_t) continue;
            pk_t = r;
            hit = true;
        }
    }
    if (!hit) return false;
    for (0..3) |k| pk_p[k] = pk_d[k] * pk_t + pk_o[k];
    return true;
}

fn xformVec(a: *const arm.M, v: V3) V3 {
    var o: V3 = undefined;
    for (0..3) |r| o[r] = a[r * 4] * v[0] + a[r * 4 + 1] * v[1] + a[r * 4 + 2] * v[2];
    return o;
}

/// Where the ray enters a leaf's box (sf_big: it misses).
inline fn slab(n: *const Node) f32 {
    var t0: f32 = 0;
    var t1: f32 = sf_big;
    for (0..3) |c| {
        const d = pk_d[c];
        const o = pk_o[c];
        if (@abs(d) > sf_tiny) {
            const a = (n.min[c] - o) / d;
            const b = (n.max[c] - o) / d;
            t0 = maxss(t0, minss(a, b));
            t1 = minss(t1, maxss(a, b));
        } else {
            if (!(o >= n.min[c])) return sf_big;
            if (o > n.max[c]) return sf_big;
        }
    }
    if (t0 > t1) return sf_big;
    return t0;
}

inline fn crs(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
inline fn dt(a: V3, b: V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// Moller-Trumbore: t, or -1.
inline fn rayTri(t: u32) f32 {
    const q = tris[t];
    const a = pos[q[0]];
    const b = pos[q[1]];
    const c = pos[q[2]];
    const e1: V3 = .{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const e2: V3 = .{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    const s: V3 = .{ pk_o[0] - a[0], pk_o[1] - a[1], pk_o[2] - a[2] };
    const p = crs(pk_d, e2);
    const det = dt(e1, p);
    if (!(@abs(det) > sf_tiny)) return -1;
    const u = dt(s, p) / det;
    if (!(u >= 0) or u > 1) return -1;
    const k = crs(s, e1);
    const v = dt(pk_d, k) / det;
    if (!(v >= 0) or v + u > 1) return -1;
    return dt(e2, k) / det;
}

/// radius pixels at a local point, in local units (camera depth / focal, through
/// the object's scale). sd_c: local -> camera.
fn localRadius(p: V3) f32 {
    var z = tocam(p)[2];
    z = maxss(z, vp.near);
    return radius * px_scale * z / draw.focal / objScale();
}

fn objScale() f32 {
    return maxss(@sqrt(sc_m[0] * sc_m[0] + sc_m[4] * sc_m[4] + sc_m[8] * sc_m[8]), sf_tiny);
}

/// Pixels a UI unit (the brush's radius is in the UI's units, as its circle).
var px_scale: f32 = 1;

pub inline fn tocam(p: V3) V3 {
    const c = &draw.sd_c;
    return .{
        c[0] * p[0] + c[1] * p[1] + c[2] * p[2] + c[3],
        c[4] * p[0] + c[5] * p[1] + c[6] * p[2] + c[7],
        c[8] * p[0] + c[9] * p[1] + c[10] * p[2] + c[11],
    };
}

// dabs -----------------------------------------------------------------------------

/// A leaf's box touches a sphere around dab_p.
inline fn hitsLeaf(n: *const Node, r: f32) bool {
    var d: f32 = 0;
    for (0..3) |c| {
        const v = dab_p[c];
        const a = maxss(n.min[c] - v, 0);
        const b = maxss(v - n.max[c], 0);
        const s = a + b;
        d += s * s;
    }
    return !(d > r * r);
}

/// The leaves a radius around dab_p touches, into a list.
pub fn reach(list: u32, r: f32) u32 {
    const out = hits[list * nnodes..];
    var n: u32 = 0;
    for (nodes[0..nnodes], 0..) |*node, l| {
        if (hitsLeaf(node, r)) {
            out[n] = @intCast(l);
            n += 1;
        }
    }
    nh[list] = n;
    return n;
}

/// What a vertex's weight needs of a dab, kept in registers by its passes.
const Fall = struct {
    px: f32,
    py: f32,
    pz: f32,
    r2: f32,
    kind: u32,
    use_mask: bool,
};

fn fallNow() Fall {
    return .{ .px = dab_p[0], .py = dab_p[1], .pz = dab_p[2], .r2 = dab_r * dab_r, .kind = falloff_kind, .use_mask = brush_now != MASK and masked };
}

/// A vertex's weight in the dab (0 outside): smooth (1 - t^2)^2 with t = distance /
/// radius, or the curve falloff_kind picks, less where masked (the mask brush
/// itself ignores the mask).
inline fn falloff(f: *const Fall, p: [*]const V3, v: u32) f32 {
    const q = p[v];
    const dx = q[0] - f.px;
    const dy = q[1] - f.py;
    const dz = q[2] - f.pz;
    const d2 = dx * dx + dy * dy + dz * dz;
    if (d2 >= f.r2) return 0;
    const t2 = d2 / f.r2;
    var w: f32 = undefined;
    switch (f.kind) {
        0 => {
            const a = 1.0 - t2;
            w = a * a;
        },
        1 => w = @sqrt(1.0 - t2),
        5 => w = 1,
        else => {
            const a = 1.0 - @sqrt(t2);
            w = switch (f.kind) {
                2 => @sqrt(a),
                3 => a * a,
                else => a,
            };
        },
    }
    if (f.use_mask) {
        const k = mask[v];
        if (k != 0) w = w * (1.0 - @as(f32, @floatFromInt(k)) * sf_mask);
    }
    return w;
}

/// Weights, centre, normal sums, per thread.
fn jobArea(_: *anyopaque, lo: usize, hi: usize, thread: usize) void {
    const f = fallNow();
    const p = pos;
    const nrm = vn.ptr;
    var s = slots[(thread + 1) & 127].s;
    for (lo..hi) |i| {
        const n = &nodes[hits[i]];
        for (vl[n.voff .. n.voff + n.vown]) |v| {
            const w = falloff(&f, p, v);
            if (!(w > 0)) continue;
            s[0] = s[0] + w;
            const q = p[v];
            const b = nrm[v];
            for (0..3) |k| {
                s[1 + k] = q[k] * w + s[1 + k];
                s[4 + k] = b[k] * w + s[4 + k];
            }
        }
    }
    slots[(thread + 1) & 127].s = s;
}

/// The brush on each own vertex in reach; the old positions of the leaf's
/// first-touched vertices go to slots taken with one atomic add per leaf.
fn jobApply(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    switch (brush_now) {
        inline 0...NBRUSH - 1 => |b| applyLeaves(b, lo, hi),
        else => {},
    }
}

const Move = struct {
    r10: f32, // r / 10
    s: f32,
    s_abs: f32,
    s_01: f32, // |s| up to 1
    n: V3,
    c: V3,
    p: V3,
    mv: V3,
    height: f32,
    inv: bool,
};

fn applyLeaves(comptime b: u32, lo: usize, hi: usize) void {
    const f = fallNow();
    const p = pos;
    const nrm = vn.ptr;
    const mv = Move{
        .r10 = dab_r * sf_tenth,
        .s = dab_s,
        .s_abs = @abs(dab_s),
        .s_01 = minss(@abs(dab_s), 1),
        .n = dab_n,
        .c = dab_c,
        .p = dab_p,
        .mv = dab_move,
        .height = dab_r * sf_tenth * dab_s,
        .inv = invert,
    };
    const ac = acc.ptr;
    const did = d_idx.ptr;
    const dol = d_old.ptr;
    const cap = d_cap;
    const rc = rec.ptr;
    for (lo..hi) |i| {
        const n = &nodes[hits[i]];
        const own = vl[n.voff .. n.voff + n.vown];
        var slot: u32 = 0;
        if (b != MASK) {
            var fresh: u32 = 0; // first: how many are new
            for (own) |v| {
                if (rc[v] != 0) continue;
                if (falloff(&f, p, v) > 0) fresh += 1;
            }
            slot = d_n.fetchAdd(fresh, .monotonic); // their slots
        }
        for (own) |v| {
            const w = falloff(&f, p, v);
            if (!(w > 0)) continue;
            if (b != MASK and rc[v] == 0) { // first touch: its old position
                rc[v] = 1;
                if (slot < cap) {
                    did[slot] = v;
                    dol[slot] = p[v];
                }
                slot += 1;
            }
            moveVertex(b, &mv, &p[v], nrm, ac, v, w);
        }
    }
}

inline fn addDir(q: *V3, d: V3, a: f32) void {
    q[0] = d[0] * a + q[0];
    q[1] = d[1] * a + q[1];
    q[2] = d[2] * a + q[2];
}

/// Towards the dab point, in the plane.
inline fn pinch2(q: *V3, mv: *const Move, s7: f32) void {
    const k = s7 * 0.5;
    const d: V3 = .{ mv.p[0] - q[0], mv.p[1] - q[1], mv.p[2] - q[2] };
    const x = dt(d, mv.n);
    for (0..3) |c| q[c] = (d[c] - mv.n[c] * x) * k + q[c];
}

/// The brush's change.
inline fn moveVertex(comptime b: u32, mv: *const Move, q: *V3, nrm: [*]const V3, ac: [*]const [4]f32, v: u32, w: f32) void {
    const s7 = mv.s * w; // strength x weight
    switch (b) {
        DRAW, LAYER => addDir(q, mv.n, mv.r10 * s7), // along the area normal, r / 10
        INFLATE => addDir(q, nrm[v], mv.r10 * s7), // along its own normal
        CREASE => { // in along the normal, and pinched
            addDir(q, mv.n, 0.0 - mv.r10 * s7);
            pinch2(q, mv, @abs(w * 0.5));
        },
        PINCH => { // (towards the centre; Ctrl: away)
            const a = @abs(s7);
            pinch2(q, mv, if (mv.inv) 0.0 - a else a);
        },
        CLAY, FLATTEN => {
            // up to a plane above the centre (flatten: through it): d = (v - c) . n - h
            const h: f32 = if (b == CLAY) mv.height else 0;
            const e: V3 = .{ q[0] - mv.c[0], q[1] - mv.c[1], q[2] - mv.c[2] };
            var x = dt(e, mv.n) - h;
            if (b == CLAY) {
                // only what is below the plane (above, for a negative height)
                if (x >= 0) {
                    if (mv.s >= 0) return;
                } else if (!(mv.s >= 0)) return;
            }
            x = x * @abs(w);
            x = x * mv.s_01;
            addDir(q, mv.n, 0.0 - x); // v -= d n w
        },
        SMOOTH => { // towards its neighbours' average
            const k = minss(@abs(s7), 1);
            const a = &ac[v];
            const count = a[3];
            if (!(count > sf_tiny)) return;
            for (0..3) |c| q[c] = (a[c] / count - q[c]) * k + q[c];
        },
        SNAKE => { // with the pointer's move
            for (0..3) |c| q[c] = mv.mv[c] * w + q[c];
        },
        MASK => {
            const old: f32 = @floatFromInt(mask[v]);
            const x = old + s7 * 255.0;
            mask[v] = @intCast(trunc32(minss(maxss(x, 0), 255)));
        },
        else => {},
    }
}

fn jobBox(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    for (lo..hi) |i| nodeBox(hits[i]);
}

/// The room for this many more deltas. False: no memory (the dab must not run:
/// a move no step records could never be undone).
fn room(more: u32) bool {
    const want = @as(u64, d_n.load(.monotonic)) + more;
    if (want <= d_cap) return true;
    var c: u64 = @max(@as(u64, d_cap) * 2, 65536);
    while (c < want) c *= 2;
    const a = smap(u32, c) orelse return false;
    const b = smap(V3, c) orelse {
        sfree2(a);
        return false;
    };
    const n = d_n.load(.monotonic);
    if (d_cap > 0) {
        @memcpy(a[0..n], d_idx[0..n]);
        @memcpy(b[0..n], d_old[0..n]);
        sfree(&d_idx);
        sfree(&d_old);
    }
    d_idx = a;
    d_old = b;
    d_cap = @intCast(c);
    return true;
}

fn sfree2(a: []u32) void {
    var x = a;
    sfree(&x);
}

fn ownInReach() u32 {
    var total: u32 = 0;
    for (hits[0..nh[0]]) |l| total += nodes[l].vown;
    return total;
}

/// One dab (radius local; dab_p, dab_s, brush_now, dab_move): the area's normal and
/// centre, then each vertex in reach, then the leaves' boxes. The normals around
/// follow once a frame (normalsDue).
fn dab(r: f32) void {
    dab_r = r;
    if (reach(0, r) == 0) return;
    @memset(std.mem.asBytes(&slots), 0); // the area: per-thread sums
    jobs.parallelFor(nh[0], 2, &dummy, jobArea);
    var s: [7]f32 = @splat(0); // reduce: w, centre, normal
    for (&slots) |*t| {
        for (0..7) |k| s[k] = t.s[k] + s[k];
    }
    if (!(s[0] > sf_tiny)) return; // nothing in reach
    for (0..3) |k| dab_c[k] = s[1 + k] / s[0];
    dab_n = s[4..7].*;
    unit3(&dab_n);
    if (brush_now == SMOOTH) {
        if (!smoothGather()) return;
    }
    if (brush_now != MASK) {
        if (!room(ownInReach())) return;
    }
    jobs.parallelFor(nh[0], 2, &dummy, jobApply); // each vertex in reach
    jobs.parallelFor(nh[0], 2, &dummy, jobBox); // the boxes
    if (brush_now == MASK) {
        masked = true;
        full = true;
    }
    dirtyGrow(); // normals: once a frame, before drawing
    version +%= 1;
    app.dirty = true;
}

fn unit3(a: *V3) void {
    const l = @sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    if (!(l > sf_tiny)) return;
    const s = 1.0 / l;
    a[0] = a[0] * s;
    a[1] = a[1] * s;
    a[2] = a[2] * s;
}

/// The sphere whose normals are due takes in this dab's: the smallest around both.
fn dirtyGrow() void {
    const r = dab_r;
    if (!nd_on) {
        nd_c = dab_p;
        nd_r = r;
        nd_on = true;
        return;
    }
    var d2: f32 = 0;
    for (0..3) |c| {
        const x = dab_p[c] - nd_c[c];
        d2 += x * x;
    }
    const d = @sqrt(d2);
    if (d + r <= nd_r) return; // inside the old one: as it is
    if (!(d + nd_r > r)) { // the old inside the new: the new
        nd_c = dab_p;
        nd_r = r;
        return;
    }
    const big = (d + nd_r + r) * 0.5; // the centre moves (R - r1) / d towards p
    const k = (big - nd_r) / d;
    nd_r = big;
    for (0..3) |c| nd_c[c] = (dab_p[c] - nd_c[c]) * k + nd_c[c];
}

/// The normals in the dirty sphere again (before drawing, at a stroke's end).
pub fn normalsDue() void {
    if (!nd_on) return;
    nd_on = false;
    const keep = dab_p;
    dab_p = nd_c;
    normalsNear(nd_r);
    dab_p = keep;
}

inline fn fadd(p: *f32, x: f32) void {
    const a: *std.atomic.Value(u32) = @ptrCast(p);
    var o = a.load(.monotonic);
    while (true) {
        const f: f32 = @bitCast(o);
        const n: u32 = @bitCast(f + x);
        o = a.cmpxchgWeak(o, n, .monotonic, .monotonic) orelse return;
    }
}

/// sc_acc (sum of neighbours, count) for the vertices in reach, from the
/// triangles of the leaves around them.
fn smoothGather() bool {
    if (acc.len == 0) {
        acc = smap([4]f32, capv) orelse return false;
    }
    _ = reach(1, dab_r + maxedge); // leaves within r + L: their own vertices
    jobs.parallelFor(nh[1], 2, &dummy, jobAccClear); //  cleared, their triangles
    jobs.parallelFor(nh[1], 2, &dummy, jobAccAdd); //  added up
    return true;
}

fn jobAccClear(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const l1 = hits[nnodes..];
    for (lo..hi) |i| {
        const n = &nodes[l1[i]];
        for (vl[n.voff .. n.voff + n.vown]) |v| acc[v] = .{ 0, 0, 0, 0 };
    }
}

fn jobAccAdd(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const l1 = hits[nnodes..];
    const p = pos;
    for (lo..hi) |i| {
        const n = &nodes[l1[i]];
        for (tri[n.toff .. n.toff + n.tn]) |t| {
            const q = tris[t];
            for (0..3) |c| { // corner: += the other two
                const a = p[q[(c + 1) % 3]];
                const b = p[q[(c + 2) % 3]];
                const out = &acc[q[c]];
                fadd(&out[0], a[0] + b[0]);
                fadd(&out[1], a[1] + b[1]);
                fadd(&out[2], a[2] + b[2]);
                fadd(&out[3], 2.0);
            }
        }
    }
}

/// Vertex normals again within radius + the longest edge of dab_p (list 1, cleared
/// and stamped), from every triangle within radius + 2 edges (list 2; atomic adds),
/// then unit.
fn normalsNear(r: f32) void {
    const r1 = r + maxedge;
    nn_r1 = r1;
    const r2 = r1 + maxedge;
    serial +%= 1;
    _ = reach(1, r1);
    _ = reach(2, r2);
    jobs.parallelFor(nh[1], 2, &dummy, jobNClear);
    jobs.parallelFor(nh[2], 2, &dummy, jobNAdd);
    jobs.parallelFor(nh[1], 2, &dummy, jobNUnit);
    for (hits[nnodes..][0..nh[1]]) |l| lchg[l] = 1; // their splats are drawn again
}

fn jobNClear(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const l1 = hits[nnodes..];
    const s = serial;
    const p = pos;
    const c = dab_p;
    const lim = nn_r1 * nn_r1;
    for (lo..hi) |i| {
        const n = &nodes[l1[i]];
        for (vl[n.voff .. n.voff + n.vown]) |v| {
            const q = p[v];
            const dx = q[0] - c[0];
            const dy = q[1] - c[1];
            const dz = q[2] - c[2];
            if (!(dx * dx + dy * dy + dz * dz < lim)) continue;
            stamp[v] = s;
            vn[v] = .{ 0, 0, 0 };
        }
    }
}

fn jobNAdd(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const l2 = hits[2 * @as(usize, nnodes)..];
    const s = serial;
    const st = stamp.ptr;
    const nrm = vn.ptr;
    for (lo..hi) |i| {
        const n = &nodes[l2[i]];
        for (tri[n.toff .. n.toff + n.tn]) |t| {
            const f = faceN(t);
            for (tris[t]) |v| {
                if (st[v] != s) continue;
                fadd(&nrm[v][0], f[0]);
                fadd(&nrm[v][1], f[1]);
                fadd(&nrm[v][2], f[2]);
            }
        }
    }
}

fn jobNUnit(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const l1 = hits[nnodes..];
    const s = serial;
    for (lo..hi) |i| {
        const n = &nodes[l1[i]];
        for (vl[n.voff .. n.voff + n.vown]) |v| {
            if (stamp[v] == s) vnUnit(&vn[v]);
        }
    }
}

// strokes -----------------------------------------------------------------------------

/// A dab at dab_p, and its mirrors (sym: X, Y, Z and their combinations, across
/// the object's planes through its origin).
fn doDab(r0: f32) void {
    var r = r0;
    const f = stroke.penFactor(penon); // pressure: strength and / or radius
    var s = base_s;
    if (stroke.pmap & 1 != 0) s = s * f;
    dab_s = s;
    if (stroke.pmap & 2 != 0) r = maxss(f, sf_tenth) * r;
    dab(r);
    if (ext.after_dab) |g| g(r, 0); // dyntopo: the detail there
    if (sym == 0) return;
    const keep_p = dab_p; // (the dab as it is: kept)
    const keep_m = dab_move;
    var k: u32 = 1;
    while (k < 8) : (k += 1) {
        if (~sym & k != 0) continue; // (a mirror outside the setting: skip)
        dab_p = mirror(k, keep_p);
        dab_move = mirror(k, keep_m);
        dab(r);
        if (ext.after_dab) |g| g(r, k);
    }
    dab_p = keep_p; // back as it was
    dab_move = keep_m;
}

/// Those components negated (mask: 1 X, 2 Y, 4 Z).
pub fn mirror(k: u32, v: V3) V3 {
    var o = v;
    for (0..3) |c| {
        if (k >> @intCast(c) & 1 != 0) o[c] = -o[c];
    }
    return o;
}

/// The brush (Shift: smooth), its sign (Ctrl: inverted), empty deltas.
fn strokeBegin(shift: bool, ctrl: bool) void {
    brush_now = if (shift) SMOOTH else brush;
    invert = ctrl or stroke.eraser; // (a pen's eraser end inverts too)
    penon = false;
    const s = if (invert) 0.0 - strength else strength;
    dab_s = s;
    base_s = s;
    dab_move = .{ 0, 0, 0 };
    d_n.store(0, .monotonic);
    g_n = 0;
    stroking = true;
    if (ext.reset) |f| f();
    undo.sync(); // (the scene as it is now is the step before this one)
}

/// The deltas to an undo step (old and new positions), the mesh's box and caches.
fn strokeEnd() void {
    if (!stroking) return;
    normalsDue();
    stroking = false;
    const dyn = ext.dyn != null and ext.dyn.?();
    const n = d_n.load(.monotonic);
    var delta: ?undo.Delta = null;
    if (n > 0 and !dyn) {
        if (ext.owns != null and ext.owns.?()) {
            if (ext.stroke_end) |f| f(); // multires: the moves go to the displacements
        } else delta = makeDelta(n);
    }
    // recorded flags off
    for (d_idx[0..@min(n, d_cap)]) |v| rec[v] = 0;
    d_n.store(0, .monotonic);
    if (dyn) {
        if (ext.commit) |f| f();
    } else meshBoxLeaves();
    undo.strokeStep("Sculpt", delta);
    if (mesh_mi) |mi| scene.bumpShape(mi); // (caches keyed by it)
    full = true; // (the splat strides for the view)
    version +%= 1;
    app.dirty = true;
}

/// A stroke by hand that is still going (the mode ends, a key undoes): it ends here,
/// one step, with what it did.
pub fn finishStroke() void {
    if (stroking and stillOurs()) strokeEnd();
    stroking = false;
    penon = false;
}

/// The block an undo step carries: indices, old positions, new.
const Block = extern struct { serial: u32, mi: u32, n: u32, pad: u32, bytes: u64 };

fn makeDelta(n: u32) ?undo.Delta {
    const mi = mesh_mi orelse return null;
    const bytes = @sizeOf(Block) + @as(usize, n) * 28;
    const mem = smap(u8, bytes) orelse return null;
    const h: *Block = @ptrCast(@alignCast(mem.ptr));
    h.* = .{ .serial = mesh_serial, .mi = mi, .n = n, .pad = 0, .bytes = bytes };
    const idx: [*]u32 = @ptrCast(@alignCast(mem.ptr + @sizeOf(Block)));
    const old: [*]align(4) V3 = @ptrCast(@alignCast(idx + n));
    const new = old + n;
    @memcpy(idx[0..n], d_idx[0..n]);
    @memcpy(old[0..n], d_old[0..n]);
    for (0..n) |k| new[k] = pos[idx[k]];
    return .{ .ctx = @ptrCast(h), .bytes = bytes, .apply = applyDelta, .free = freeDelta };
}

fn applyDelta(ctx: *anyopaque, back: bool) void {
    const h: *Block = @ptrCast(@alignCast(ctx));
    const mi: u16 = @intCast(h.mi);
    const me = &(scene.meshes[mi] orelse return);
    if (me.serial != h.serial) return;
    const base: [*]u8 = @ptrCast(ctx);
    const idx: [*]const u32 = @ptrCast(@alignCast(base + @sizeOf(Block)));
    const old: [*]align(4) const V3 = @ptrCast(@alignCast(idx + h.n));
    const src = if (back) old else old + h.n;
    const v = me.verts;
    for (0..h.n) |k| v[idx[k]] = src[k];
    // (dyntopo's working copy is that mesh too: a stale one would come back with the
    // next stroke)
    if (on and mesh_mi == mi and me.serial == mesh_serial and pos != v.ptr) {
        for (0..h.n) |k| pos[idx[k]] = src[k];
    }
    scene.refreshMesh(mi);
    if (on and mesh_mi == mi and me.serial == mesh_serial) {
        refresh_due = true;
        version +%= 1;
        app.dirty = true;
    }
}

fn freeDelta(ctx: *anyopaque) void {
    const h: *Block = @ptrCast(@alignCast(ctx));
    _ = linux.munmap(@ptrCast(@alignCast(ctx)), std.mem.alignForward(usize, h.bytes, 4096));
}

/// Every leaf box and normal again (undo).
fn refreshAll() void {
    refresh_due = false;
    nd_on = false;
    for (0..nnodes) |k| nodeBox(@intCast(k));
    normalsAll();
}

/// The mesh's box: the union of the leaves' (no pass over every vertex).
fn meshBoxLeaves() void {
    const me = mesh orelse return;
    var a: V3 = .{ sf_big, sf_big, sf_big };
    var b: V3 = .{ sf_nbig, sf_nbig, sf_nbig };
    for (nodes[0..nnodes]) |*n| {
        for (0..3) |c| {
            a[c] = minss(a[c], n.min[c]);
            b[c] = maxss(b[c], n.max[c]);
        }
    }
    me.lo = a;
    me.hi = b;
}

/// The camera (draw.setCam) for pointers given in the UI's units.
fn penCam(cv: *const gfx.Canvas, v: *const vp.View, r: gfx.Rect) vp.Cam {
    const c = vp.Cam.init(v, cv.pxRect(r));
    draw.setCam(&c);
    px_scale = @as(f32, @floatFromInt(cv.s)) / 65536.0;
    return c;
}

/// A press at (x, y) (UI units): true when the stroke started (on the mesh), false:
/// the click is the viewport's (orbit, select).
pub fn press(cv: *const gfx.Canvas, v: *const vp.View, r: gfx.Rect, x: i32, y: i32, shift: bool, ctrl: bool) bool {
    if (land and valid()) { // a landscape: lsculpt.zig
        const c = penCam(cv, v, r);
        const pf: f32 = @floatFromInt(cv.toPx(x));
        const qf: f32 = @floatFromInt(cv.toPx(y));
        return @import("lsculpt.zig").press(obj, &c, pf, qf, radius * px_scale, strength);
    }
    if (!valid() or land) return false;
    if (!ownMesh(obj)) return false; // (undo can bring back a mesh another object shares)
    if (!valid()) return false;
    const c = penCam(cv, v, r);
    if (!pick(&c, cv.toPx(x), cv.toPx(y))) return false;
    strokeBegin(shift, ctrl);
    penon = true;
    way.begin(x, y);
    dab_p = pk_p;
    lastr = localRadius(dab_p);
    gplane = tocam(dab_p)[2]; // the grab plane: camera depth there
    last = dab_p;
    if (brush_now == GRAB) {
        grabCapture();
    } else if (brush_now != SNAKE) {
        doDab(lastr);
    }
    return true;
}

/// The point under pixels (x, y) at the grab plane's depth (local).
fn planePoint(c: *const vp.Cam, x: i32, y: i32) V3 {
    var u = (@as(f32, @floatFromInt(x)) - c.cx) / c.f;
    var w = (c.cy - @as(f32, @floatFromInt(y))) / c.f;
    u = u * gplane;
    w = w * gplane;
    var q: V3 = undefined;
    for (0..3) |k| q[k] = c.right[k] * u + c.up[k] * w + c.fwd[k] * gplane + c.eye[k];
    return arm.xformPoint(&sc_mi, q);
}

/// The pointer moved during a stroke: dabs along the way (every 10% of the radius).
pub fn drag(cv: *const gfx.Canvas, v: *const vp.View, r: gfx.Rect, x0: i32, y0: i32) void {
    const t0 = nowNs();
    defer work_acc += nowNs() - t0;
    if (land) { // a landscape: lsculpt.zig
        const lc = penCam(cv, v, r);
        @import("lsculpt.zig").drag(&lc, @floatFromInt(cv.toPx(x0)), @floatFromInt(cv.toPx(y0)));
        return;
    }
    if (!stroking or !valid()) return;
    if (!stroking) return; // (valid() may have ended it: another mesh)
    const c = penCam(cv, v, r);
    if (brush_now == GRAB) { // the captured vertices follow
        pk_p = planePoint(&c, cv.toPx(x0), cv.toPx(y0));
        grabMove();
        return;
    }
    const q = way.follow(x0, y0) orelse return; // (within the string: nothing yet)
    const x = q[0];
    const y = q[1];
    if (brush_now == SNAKE) { // pull what is under the brush along
        pk_p = planePoint(&c, cv.toPx(x), cv.toPx(y));
        for (0..3) |k| dab_move[k] = pk_p[k] - last[k];
        dab_p = last;
        doDab(lastr);
        last = pk_p;
        return;
    }
    // spacing: a dab every 10% of the radius (in pixels) along the path
    const n = way.dabs(x, y, radius);
    if (n == 0) return;
    var k: i32 = 1;
    while (k <= n) : (k += 1) {
        const p = way.at(x, y, k, n);
        if (!pick(&c, cv.toPx(p[0]), cv.toPx(p[1]))) continue;
        dab_p = pk_p;
        doDab(localRadius(dab_p));
    }
    way.arrived(x, y);
}

pub fn release() void {
    if (land) return @import("lsculpt.zig").release();
    finishStroke();
}

/// The vertices in reach at the start, with their weights (and their mirrors').
fn grabCapture() void {
    dab_r = lastr;
    gstart = dab_p;
    grab_far = 0;
    var pass: u32 = 0;
    while (true) {
        _ = reach(0, dab_r); // room for every vertex in reach
        var total: u32 = 0;
        for (hits[0..nh[0]]) |l| total += nodes[l].vown;
        _ = room(total); // (no room: record() says so, vertex by vertex)
        serial +%= 1;
        const s = serial;
        const f = fallNow();
        for (nodes[0..nnodes]) |*n| {
            if (!hitsLeaf(n, dab_r)) continue;
            for (vl[n.voff .. n.voff + n.vn]) |v| {
                if (stamp[v] == s) continue;
                stamp[v] = s;
                const w = falloff(&f, pos, v);
                if (!(w > 0)) continue;
                if (!record(v)) continue;
                if (g_n == g_idx.len and !growGrab()) continue;
                g_idx[g_n] = v;
                // (mirrored: the mask rides on the weight, w + 2 x mask: grabMove)
                const pf: f32 = @floatFromInt(pass);
                g_w[g_n] = w + (pf + pf);
                g_n += 1;
            }
        }
        // the next mirror the setting allows
        pass += 1;
        while (pass < 8 and ~sym & pass != 0) pass += 1;
        if (pass >= 8) break;
        dab_p = mirror(pass, gstart); // dab_p: the start, mirrored so
    }
    dab_p = gstart; // (back where it started)
}

/// A vertex's old position into the stroke's deltas, once. False: no room, and the
/// vertex must stay where it is.
fn record(v: u32) bool {
    if (rec[v] != 0) return true;
    const k = d_n.load(.monotonic);
    if (k >= d_cap) return false;
    rec[v] = 1;
    d_n.store(k + 1, .monotonic);
    d_idx[k] = v;
    d_old[k] = pos[v];
    return true;
}

fn growGrab() bool {
    const c = @max(g_idx.len * 2, 65536);
    const a = smap(u32, c) orelse return false;
    const b = smap(f32, c) orelse {
        sfree2(a);
        return false;
    };
    if (g_n > 0) {
        @memcpy(a[0..g_n], g_idx[0..g_n]);
        @memcpy(b[0..g_n], g_w[0..g_n]);
    }
    sfree(&g_idx);
    sfree(&g_w);
    g_idx = a;
    g_w = b;
    return true;
}

var grab_mv: V3 = undefined;
var grab_far: f32 = 0;

fn jobGrab(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const p = pos;
    const mv = grab_mv;
    for (g_idx[lo..hi], g_w[lo..hi]) |v, w0| {
        // mirrored captures: w + 2 x mask
        const k: u32 = @bitCast(trunc32(w0 * 0.5)); // the mask: those axes flip
        const kf: f32 = @floatFromInt(@as(i32, @bitCast(k)));
        const w = w0 - (kf + kf); // the weight
        for (0..3) |c| {
            var x = mv[c];
            if (k >> @intCast(c) & 1 != 0) x = -x;
            p[v][c] = x * w + p[v][c];
        }
    }
}

/// pk_p = the pointer on the grab plane: the captured vertices move with it, by
/// their weights; boxes and normals follow.
fn grabMove() void {
    for (0..3) |c| grab_mv[c] = pk_p[c] - last[c]; // the move since the last
    // (a vertex in two mirrors' captures takes both moves: in their order)
    if (sym == 0) jobs.parallelFor(g_n, 4096, &dummy, jobGrab) else jobGrab(&dummy, 0, g_n, 0);
    last = pk_p;
    // the region: the start's sphere grown by how far it went (and its mirror):
    // boxes and normals again. As far as it ever went: the original takes how far it
    // is now, and a grab pulled out and brought back leaves the leaves out there with
    // stale boxes (a ghost on screen, vertices later dabs cannot find).
    var d2: f32 = 0;
    for (0..3) |c| {
        const x = pk_p[c] - gstart[c];
        d2 += x * x;
    }
    grab_far = maxss(grab_far, @sqrt(d2));
    const r = grab_far + lastr;
    dab_p = gstart;
    grabRegion(r);
    var k: u32 = 1;
    while (k < 8) : (k += 1) {
        if (~sym & k != 0) continue;
        dab_p = mirror(k, gstart);
        grabRegion(r);
    }
    version +%= 1;
    app.dirty = true;
}

fn grabRegion(r: f32) void {
    _ = reach(0, r);
    jobs.parallelFor(nh[0], 2, &dummy, jobBox);
    normalsNear(r);
}

/// sculpt_mask_op: 0 clear, 1 invert, 2 fill.
pub fn maskOp(k: u32) void {
    if (!on or mask.len == 0) return;
    masked = k != 0; // (anything masked from now on?)
    const mm = mask[0..nv];
    switch (k) {
        0 => @memset(mm, 0),
        1 => for (mm) |*x| {
            x.* ^= 255;
        },
        else => @memset(mm, 255),
    }
    full = true;
    version +%= 1;
    app.dirty = true;
}

/// sculpt_dab_world: a stroke of dabs from one world point to the other (scripts
/// and agents; the object in sculpt mode), one undo step.
pub fn strokeWorld(b: u32, from: V3, to: V3, rad: f32, str: f32) bool {
    if (!valid() or land) return false;
    if (!ownMesh(obj) or !valid()) return false;
    const keep_b = brush; // this brush, this strength
    const keep_s = strength;
    defer {
        brush = keep_b;
        strength = keep_s;
    }
    brush = b;
    // (negative: inverted; NaN too, as comiss / jae leaves it)
    const inv = !(str >= 0);
    strength = if (inv) @abs(str) else str;
    strokeBegin(false, inv);
    const p0 = arm.xformPoint(&sc_mi, from); // the ends, local
    const p1 = arm.xformPoint(&sc_mi, to);
    const r = rad / objScale(); // the radius, local
    var w: V3 = undefined; // the way
    var d2: f32 = 0;
    for (0..3) |c| {
        w[c] = p1[c] - p0[c];
        d2 += w[c] * w[c];
    }
    var n = trunc32(@sqrt(d2) / maxss(r * stroke.spacing, sf_tiny)); // length / (10% of the radius) dabs
    if (n > 4096) n = 4096;
    if (n == 0) n = 1;
    if (b == GRAB) { // grab: capture at the start, move to the end
        dab_p = p0;
        lastr = r;
        last = p0;
        grabCapture();
        pk_p = p1;
        grabMove();
    } else {
        var k: i32 = 0;
        while (k <= n) : (k += 1) {
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
            for (0..3) |c| dab_p[c] = w[c] * t + p0[c];
            if (b == SNAKE) {
                const fn_: f32 = @floatFromInt(n);
                for (0..3) |c| dab_move[c] = w[c] / fn_; // snake: each dab moves by a step
            }
            doDab(r);
        }
    }
    strokeEnd();
    return true;
}

pub fn brushByName(s: []const u8) ?u32 {
    for (brush_names, 0..) |n, k| {
        if (std.mem.eql(u8, n, s)) return @intCast(k);
    }
    return null;
}

/// The console's sculpt command, as BeeScript's sculpt(): object, brush, the two
/// world points, radius, strength (enters sculpt mode on the object).
///   sculpt Cube "clay strips" -1 2 1  1 2 1  0.5 0.5
pub fn console(line: []const u8) void {
    var it = Words{ .s = line };
    const name = it.next() orelse return usage();
    const bn = it.next() orelse return usage();
    var v: [8]f32 = undefined;
    for (&v) |*x| {
        const t = it.next() orelse return usage();
        const f = @import("expr.zig").eval(t) orelse return app.log("not a number: {s}", .{t});
        if (!std.math.isFinite(f)) return app.log("not a finite number: {s}", .{t});
        x.* = @floatCast(f);
    }
    const i = scene.find(name) orelse return app.log("no object called '{s}'", .{name});
    const b = brushByName(bn) orelse return app.log("no brush '{s}'", .{bn});
    if (!(on and scene.findOid(oid) == i)) {
        if (!enter(i)) return;
    }
    const t0 = nowNs();
    if (!strokeWorld(b, v[0..3].*, v[3..6].*, v[6], v[7])) app.log("sculpt: it failed", .{});
    script_ns += nowNs() - t0;
}

fn usage() void {
    app.log("sculpt object brush x1 y1 z1 x2 y2 z2 radius strength", .{});
}

/// Words, "a phrase" one word.
const Words = struct {
    s: []const u8,
    fn next(w: *Words) ?[]const u8 {
        var t = std.mem.trimStart(u8, w.s, " ");
        if (t.len == 0) return null;
        if (t[0] == '"') {
            t = t[1..];
            const e = std.mem.indexOfScalar(u8, t, '"') orelse t.len;
            w.s = if (e < t.len) t[e + 1..] else "";
            return t[0..e];
        }
        const e = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
        w.s = t[e..];
        return t[0..e];
    }
};

/// How long the input's work and the drawing of the last frames took, ns (the
/// original's frametime()).
pub var stat_work: [256]i64 = @splat(0);
pub var stat_draw: [256]i64 = @splat(0);
pub var stat_n: usize = 0;
pub var work_acc: i64 = 0;
var script_ns: i64 = 0; // the console's strokes

pub fn nowNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000000000 + @as(i64, ts.nsec);
}

/// A frame was drawn in `ns`.
pub fn noteFrame(ns: i64) void {
    if (work_acc == 0) return; // (a frame with a stroke's work in it)
    stat_work[stat_n % stat_work.len] = work_acc;
    stat_draw[stat_n % stat_work.len] = ns;
    stat_n += 1;
    work_acc = 0;
}

/// The console's sculpt.stats: medians and the 95th percentile, then afresh.
pub fn stats(path: []const u8) void {
    const n: usize = @min(stat_n, stat_work.len);
    if (n == 0) return app.log("  sculpt.stats: nothing yet", .{});
    std.mem.sort(i64, stat_work[0..n], {}, std.sort.asc(i64));
    std.mem.sort(i64, stat_draw[0..n], {}, std.sort.asc(i64));
    const ms = struct {
        fn f(x: i64) f64 {
            return @as(f64, @floatFromInt(x)) / 1e6;
        }
    }.f;
    var b: [120]u8 = undefined;
    const mid = n / 2;
    const hi = (n * 95) / 100;
    const t = std.fmt.bufPrint(&b, "  sculpt.stats {d} frames: work {d:.2} {d:.2} ms, frame {d:.2} {d:.2} ms", .{ n, ms(stat_work[mid]), ms(stat_work[hi]), ms(stat_draw[mid]), ms(stat_draw[hi]) }) catch "";
    app.log("{s}", .{t});
    if (path.len > 0) @import("bee.zig").writeAtomic(path, t) catch {};
    stat_n = 0;
}

/// The console's sculpt.info: what tests read.
pub fn info() void {
    if (!on) return app.log("  sculpt.info: off", .{});
    var m_sum: u64 = 0;
    for (mask[0..nv]) |x| m_sum += x;
    app.log("  sculpt.time {d} ms", .{@divTrunc(script_ns, 1000000)});
    app.log("  sculpt.info verts {d} tris {d} leaves {d} own {d} masked {d} mask {d} tiles {d}/{d} projected {d} brush {d} radius {d} strength {d} sym {d} falloff {d}", .{ nv, nt, nnodes, nvl, @intFromBool(masked), m_sum, draw.tiles_drawn.load(.monotonic), draw.tiles_total, draw.leaves_projected.load(.monotonic), brush, radius, strength, sym, falloff_kind });
}

/// The viewport's image hangs on this.
pub fn stateWord() u64 {
    return @as(u64, oid) << 32 | version;
}

/// Is this object drawn by sculptdraw.zig, not with the others?
pub inline fn drawnApart(oi: usize) bool {
    return on and !land and oi == obj;
}

test "the words of the console's command" {
    var w = Words{ .s = "Cube \"clay strips\"  -1 2" };
    try std.testing.expectEqualStrings("Cube", w.next().?);
    try std.testing.expectEqualStrings("clay strips", w.next().?);
    try std.testing.expectEqualStrings("-1", w.next().?);
    try std.testing.expectEqualStrings("2", w.next().?);
    try std.testing.expect(w.next() == null);
}
