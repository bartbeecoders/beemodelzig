//! The feature tree (feature.s, the feature parts of script.s and cadui.s).
//!
//! Features live in the CAD document (cad.zig), so undo and files carry them.
//! Each one works on a body (a mesh object) and most take a sketch: pad and
//! revolve add material, pocket, hole and shell take it away, fillet and
//! chamfer round or cut the body's sharp edges, patterns repeat an earlier
//! feature, infill fills a shell's cavity with a lattice (sdf.zig). rebuild
//! replays the whole list in order (boolean.zig, modkern.zig's bevel) and
//! gives every body its new mesh; it runs after any feature, parameter, unit
//! or sketch change.
//!
//! A record is the original's 128 bytes: type, body, sketch, reference (a
//! feature, or the edge selector), flags, count, the last rebuild's status,
//! axis, then three value slots of 32 bytes: empty, a number (byte 1, the
//! double at +8) or an expression text, so dimensions follow parameters.
//!
//! Objects: the original keeps object uids in the records. Here the body and
//! sketch fields hold the port's object ids (oid) while the scene is open;
//! files carry the objects' persistent uids (scene.Object.uid, as bee.zig
//! writes UIDS), translated both ways. A reference a file names but no object
//! has is kept as it came (cad.Block.fraw) and written back the same; one
//! whose object is deleted here keeps its uid (cad.Block.fuid).
//!
//! The kernel switch (cad.kernel on): after the mesh replay, bfeat.zig
//! replays the list again as exact B-rep solids (`brep_hook`); the bodies it
//! can build take their tessellations as meshes, the statuses stay the mesh
//! replay's.
const std = @import("std");
const app = @import("app.zig");
const m = @import("math.zig");
const scene = @import("scene.zig");
const cad = @import("cad.zig");
const sk = @import("sketch.zig");
const prof = @import("prof.zig");
const fm = @import("fmesh.zig");
const boolean = @import("boolean.zig");
const kern = @import("modkern.zig");
const sdf = @import("sdf.zig");
const undo = @import("undo.zig");

const A = std.heap.page_allocator;

pub const FT_SZ = cad.FT_SZ;
pub const FT_TYPE = 0;
pub const FT_BODY = 4;
pub const FT_SKETCH = 8;
pub const FT_REF = 12;
pub const FT_FLAGS = 16;
pub const FT_COUNT = 20;
pub const FT_STAT = 24;
pub const FT_AXIS = 28;
pub const FT_X = 32;
pub const MAX_FEATS = cad.MAX_FEATS;
pub const FF_SYM: u32 = 1;
pub const FF_REV: u32 = 2;
pub const FF_THRU: u32 = 4;
pub const FF_OFF: u32 = 8;
pub const T_PAD: u32 = 1;
pub const T_POCKET: u32 = 2;
pub const T_REVOLVE: u32 = 3;
pub const T_HOLE: u32 = 4;
pub const T_SHELL: u32 = 5;
pub const T_FILLET: u32 = 6;
pub const T_CHAMFER: u32 = 7;
pub const T_LPAT: u32 = 8;
pub const T_CPAT: u32 = 9;
pub const T_INFILL: u32 = 10;
pub const S_OK: u32 = 0;
pub const S_SKETCH: u32 = 1;
pub const S_PROFILE: u32 = 2;
pub const S_GEOM: u32 = 3;
pub const S_VALUE: u32 = 4;
pub const S_EMPTY: u32 = 5;
pub const S_REF: u32 = 6;
pub const S_OFF: u32 = 7;
pub const S_BODY: u32 = 8;
const MAXB = 16;

const type_names = [_][]const u8{ "?", "Pad", "Pocket", "Revolve", "Hole", "Shell", "Fillet", "Chamfer", "Pattern", "Circular pattern", "Infill" };
const status_names = [_][]const u8{ "ok", "its sketch is missing", "the sketch has no closed profile", "the geometry failed", "a value does not evaluate", "nothing to work on yet", "it refers to a feature it cannot use", "suppressed", "its body is missing" };

/// feat_type_name
pub fn typeName(t: u32) []const u8 {
    return type_names[if (t <= T_INFILL) t else 0];
}
/// feat_status_name
pub fn statusName(s: u32) []const u8 {
    return status_names[if (s <= S_BODY) s else S_GEOM];
}

/// The B-rep layer's rebuild (bfeat.s's bf_rebuild), run after every feature
/// rebuild: with cad.kernel on, the bodies as exact solids.
pub var brep_hook: ?*const fn () void = &@import("bfeat.zig").rebuild;

// ---- records --------------------------------------------------------------------------

pub fn count() usize {
    return cad.featCount();
}

/// feat_rec: record i of the document now (no copy).
pub fn rec(i: usize) *[FT_SZ]u8 {
    return &cad.cur.?.feats[i];
}

pub fn get(r: *const [FT_SZ]u8, off: usize) u32 {
    return std.mem.readInt(u32, r[off..][0..4], .little);
}
pub fn set(r: *[FT_SZ]u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, r[off..][0..4], v, .little);
}
fn geti(r: *const [FT_SZ]u8, off: usize) i32 {
    return @bitCast(get(r, off));
}

/// The value slot k of a record.
pub fn slot(r: *const [FT_SZ]u8, k: usize) *const [32]u8 {
    return r[FT_X + 32 * k ..][0..32];
}

/// slot_val: an empty slot is 0, a number itself, a text its value (null:
/// it does not evaluate).
pub fn slotVal(s: *const [32]u8) ?f64 {
    if (s[0] == 0) return 0;
    if (s[0] == 1) return @bitCast(std.mem.readInt(u64, s[8..16], .little));
    return cad.eval(std.mem.sliceTo(s, 0));
}

/// feat_status: the status its record keeps from its last rebuild.
pub fn status(i: usize) u32 {
    if (i >= MAX_FEATS or i >= count()) return 0;
    return get(rec(i), FT_STAT);
}

fn rawBit(field: usize) u8 {
    return if (field == FT_BODY) 1 else 2;
}

/// feat_uses: does a feature take this object (its oid)?
pub fn uses(oid: u32) bool {
    if (oid == 0) return false;
    const b = cad.cur orelse return false;
    for (0..b.nf) |i| {
        const r = &b.feats[i];
        if (get(r, FT_SKETCH) == oid and b.fraw[i] & 2 == 0) return true;
        if (get(r, FT_BODY) == oid and b.fraw[i] & 1 == 0) return true;
    }
    return false;
}

// ---- files: oids <-> the file's uids --------------------------------------------------

/// Record i as a file keeps it: object references as the objects' persistent
/// uids; one whose object was deleted keeps the uid it had (as the original:
/// the file's next id is past it, so nothing takes it again).
pub fn fileRecord(i: usize, out: *[FT_SZ]u8) void {
    const b = cad.cur.?;
    out.* = b.feats[i];
    for ([2]usize{ FT_BODY, FT_SKETCH }, 0..) |f, j| {
        if (b.fraw[i] & rawBit(f) != 0) continue;
        const v = get(out, f);
        if (v == 0) continue;
        set(out, f, if (scene.findOid(v)) |k| scene.objects[k].uid else b.fuid[i][j]);
    }
}

/// The uids record i's body and sketch have now (when it is made).
fn noteUids(b: *cad.Block, i: usize) void {
    for ([2]usize{ FT_BODY, FT_SKETCH }, 0..) |f, j| {
        const v = get(&b.feats[i], f);
        b.fuid[i][j] = if (b.fraw[i] & rawBit(f) != 0) v else if (scene.findOid(v)) |k| scene.objects[k].uid else 0;
    }
}

/// After a file's CADD was read: its uids become our objects' ids, through
/// the file's uid table (look.get(uid) -> our index); unknown ones are kept.
pub fn afterRead(look: anytype) void {
    const b = cad.cur orelse return;
    for (0..b.nf) |i| {
        b.fraw[i] = 0;
        for ([2]usize{ FT_BODY, FT_SKETCH }, 0..) |f, j| {
            const u = get(&b.feats[i], f);
            b.fuid[i][j] = u;
            if (u == 0) continue;
            if (look.get(u)) |k| {
                set(&b.feats[i], f, scene.objects[k].oid);
            } else {
                b.fraw[i] |= rawBit(f);
                // (a damaged or hand-made file can name an id at or past its
                // next one: no new object may take it, here or once saved)
                if (u >= scene.uid_next and u < 1 << 30) scene.uid_next = u + 1;
            }
        }
    }
}

// ---- rebuild --------------------------------------------------------------------------

var busy = false;
var cur_feat: u32 = 0;
var sel: u32 = 0;
var nb: u32 = 0;
var bd_uid: [MAXB]u32 = undefined;
var bd_mesh: [MAXB]?fm.M = undefined;
var fr_w: [2]f64 = .{ 0, 0 };

/// How long the last rebuild took (ns), for the bench.
pub var last_ns: u64 = 0;
pub var rebuilds: u32 = 0;

/// feat_rebuild: replay the list in order; every body takes its new mesh.
pub fn rebuild() void {
    if (busy) return;
    const b = cad.cur orelse return;
    if (b.nf == 0) return;
    busy = true;
    defer busy = false;
    const t0 = monoNs();
    nb = 0;
    var i: u32 = 0;
    while (i < b.nf) : (i += 1) {
        cur_feat = i;
        const r = &b.feats[i];
        var st: u32 = S_OFF;
        if (get(r, FT_FLAGS) & FF_OFF == 0) {
            st = S_BODY;
            if (bodySlot(i)) |s| st = apply(r, s, null);
        }
        set(r, FT_STAT, st); // (in the document as it is: undo has it)
    }
    // commit: each body takes its new mesh
    for (0..nb) |k| {
        const nm = bd_mesh[k] orelse continue;
        defer nm.deinit(A);
        const oi = scene.findOid(bd_uid[k]) orelse continue;
        const mi = (if (nm.verts.len == 0) scene.addEmptyMesh() else scene.addMesh(nm.verts, nm.poff, nm.loops)) orelse continue;
        const old = scene.objects[oi].mesh;
        scene.objects[oi].mesh = mi;
        if (old) |om| release(om);
    }
    if (brep_hook) |h| h(); // (it forgets its solids when the kernel is off)
    app.dirty = true;
    rebuilds +%= 1;
    last_ns = monoNs() -% t0;
}

fn monoNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// The mesh a body showed before: freed at once when no object and no undo
/// step holds it (a sketch drag rebuilds at every motion).
fn release(mi: u16) void {
    for (scene.objects[0..scene.count]) |*o| {
        if (o.mesh == mi or o.mres == mi) return;
    }
    if (undo.anyStepHolds(mi)) return;
    if (scene.isPrim(mi)) return;
    scene.freeMeshSlot(mi);
}

/// body_slot: the working slot of feature i's body (null: none, not a mesh,
/// too many bodies).
fn bodySlot(i: u32) ?u32 {
    const b = cad.cur.?;
    const uid = get(&b.feats[i], FT_BODY);
    if (uid == 0) return null;
    if (b.fraw[i] & 1 != 0) return null;
    for (0..nb) |k| {
        if (bd_uid[k] == uid) return @intCast(k);
    }
    if (nb >= MAXB) return null;
    const oi = scene.findOid(uid) orelse return null;
    if (!scene.objects[oi].kind.isMesh()) return null;
    bd_uid[nb] = uid;
    bd_mesh[nb] = null;
    nb += 1;
    return nb - 1;
}

fn setBody(s: u32, x: ?fm.M) void {
    if (bd_mesh[s]) |o| o.deinit(A);
    bd_mesh[s] = x;
}

/// apply: one feature on a body slot (x: a pattern's extra transform) ->
/// its status.
fn apply(r: *const [FT_SZ]u8, s: u32, x: ?*const [12]f32) u32 {
    const t = get(r, FT_TYPE);
    switch (t) {
        T_FILLET, T_CHAMFER => return bevel(r, s),
        T_LPAT, T_CPAT => return pattern(r, s, x),
        T_INFILL => return infill(r, s),
        T_PAD...T_SHELL => {},
        else => return S_REF,
    }
    const tl = tool(r, s, x);
    switch (tl) {
        .st => |e| return e,
        .mesh => |mm| return combine(mm, s, if (t == T_PAD or t == T_REVOLVE) .union_ else .difference),
    }
}

const Tool = union(enum) { mesh: fm.M, st: u32 };

/// pad_range: w0 <= w1 of a pad's extent.
fn padRange(r: *const [FT_SZ]u8, d: f64) void {
    var lo: f64 = 0;
    var hi: f64 = d;
    const fl = get(r, FT_FLAGS);
    if (fl & FF_SYM != 0) {
        hi = d * 0.5;
        lo = 0.0 - hi;
    } else if (fl & FF_REV != 0) {
        lo = 0.0 - d;
        hi = 0;
    }
    if (lo > hi) std.mem.swap(f64, &lo, &hi);
    fr_w = .{ lo, hi };
}

/// through: a depth that goes through the body.
fn through(s: u32) f64 {
    const b = bd_mesh[s] orelse return 1.0;
    var mx: f32 = 0;
    for (0..3) |c| {
        mx = maxss(mx, @abs(b.bmin[c]));
        mx = maxss(mx, @abs(b.bmax[c]));
    }
    const k: f64 = @as(f64, mx) * 3.0;
    return 1.0 + k;
}

fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

/// The sketch object a record names (a sketch with its block), or null.
fn sketchOf(ri: ?usize, r: *const [FT_SZ]u8) ?usize {
    // (the record's own index tells whether its reference is a file's unknown one)
    if (ri) |k| {
        if (cad.cur.?.fraw[k] & 2 != 0) return null;
    }
    const oi = scene.findOid(get(r, FT_SKETCH)) orelse return null;
    if (scene.objects[oi].kind != .sketch or scene.objects[oi].sk == null) return null;
    return oi;
}

fn indexOf(r: *const [FT_SZ]u8) ?usize {
    const b = cad.cur orelse return null;
    const base = @intFromPtr(&b.feats[0]);
    const p = @intFromPtr(r);
    if (p < base or p >= base + MAX_FEATS * FT_SZ) return null;
    return (p - base) / FT_SZ;
}

fn place(oi: usize, x: ?*const [12]f32) prof.Place {
    const mt = @import("measure.zig").objMatrix(oi);
    var pl = prof.Place{ .b = scene.objects[oi].sk.?, .mtx = mt[0..12].* };
    if (x) |e| pl.x = e.*;
    return pl;
}

/// tool: the solid a feature adds or removes, or why not.
fn tool(r: *const [FT_SZ]u8, s: u32, x: ?*const [12]f32) Tool {
    const t = get(r, FT_TYPE);
    var sr = r; // the feature with the sketch
    if (t == T_SHELL) {
        const ref = get(r, FT_REF);
        if (ref >= cur_feat) return .{ .st = S_REF };
        sr = rec(ref);
        if (get(sr, FT_TYPE) != T_PAD) return .{ .st = S_REF };
    }
    const so = sketchOf(indexOf(sr), sr) orelse return .{ .st = S_SKETCH };
    const v0 = slotVal(slot(r, 0)) orelse return .{ .st = S_VALUE };
    const v1 = slotVal(slot(r, 1)) orelse return .{ .st = S_VALUE };
    const b = scene.objects[so].sk.?;
    if (t == T_HOLE) {
        const rad = v0 * 0.5;
        if (!(rad > 0)) return .{ .st = S_VALUE };
        if (prof.points(b, rad) == 0) return .{ .st = S_PROFILE };
    } else {
        _ = prof.build(b);
        if (prof.count() == 0) return .{ .st = S_PROFILE };
    }
    const pl = place(so, x);
    var w0: f64 = 0;
    var w1: f64 = 0;
    switch (t) {
        T_REVOLVE => {
            if (v0 == 0 or std.math.isNan(v0)) return .{ .st = S_VALUE };
            const got = prof.revolve(A, &pl, v0, get(r, FT_AXIS)) catch null;
            return if (got) |g| .{ .mesh = g } else .{ .st = S_GEOM };
        },
        T_SHELL => {
            const wall = v0;
            if (!(wall > 0)) return .{ .st = S_VALUE };
            const ext = slotVal(slot(sr, 0)) orelse return .{ .st = S_VALUE };
            padRange(sr, ext);
            prof.offset(wall);
            w0 = fr_w[0];
            w1 = fr_w[1];
            var ov = w1 - w0;
            ov *= 0.02;
            ov += wall;
            if (get(r, FT_FLAGS) & FF_REV == 0) {
                w0 += wall;
                w1 += ov;
            } else {
                w0 -= ov;
                w1 -= wall;
            }
        },
        T_PAD => {
            padRange(r, v0);
            w0 = fr_w[0];
            w1 = fr_w[1];
            if (w0 == w1 or std.math.isNan(w0) or std.math.isNan(w1)) return .{ .st = S_VALUE };
        },
        else => { // pocket / hole: down from the sketch, a little past it
            var d = @abs(if (t == T_HOLE) v1 else v0);
            const fl = get(r, FT_FLAGS);
            if (fl & FF_THRU != 0) {
                d = through(s);
            } else if (!(d > 0)) {
                if (t != T_HOLE) return .{ .st = S_VALUE };
                d = through(s);
            }
            const ov = d * 0.02;
            w0 = 0.0 - d;
            w1 = ov;
            if (fl & FF_REV != 0) {
                w0 = 0.0 - ov;
                w1 = d;
            } else if (fl & FF_SYM != 0) {
                d *= 0.5;
                w0 = 0.0 - d;
                w1 = d;
            }
        },
    }
    const got = prof.prism(A, &pl, w0, w1) catch null;
    return if (got) |g| .{ .mesh = g } else .{ .st = S_GEOM };
}

/// keep_closed: the cleaned copy replaces the mesh when it is closed.
fn keepClosed(x: *fm.M, c: ?fm.M) void {
    const y = c orelse return;
    if (fm.manifold(A, &y) catch false) {
        x.deinit(A);
        x.* = y;
    } else y.deinit(A);
}

/// combine: the tool joined to or cut from the body.
fn combine(tl: fm.M, s: u32, op: boolean.Op) u32 {
    const body = bd_mesh[s] orelse {
        if (op == .union_) {
            bd_mesh[s] = tl;
            return S_OK;
        }
        tl.deinit(A);
        return S_EMPTY;
    };
    const res = boolean.runExact(A, body.asP(), tl.asP(), op) catch null;
    tl.deinit(A);
    var r = fm.fromP(res orelse return S_GEOM);
    keepClosed(&r, fm.clean(A, &r) catch null);
    keepClosed(&r, fm.dropFlats(A, &r) catch null);
    setBody(s, r);
    return S_OK;
}

/// edge_pick: does the fillet / chamfer selector take edge (a, b)? 0 all,
/// 1 vertical, 2 horizontal, 3 top, 4 bottom (Y is up).
fn edgePick(a: u32, b: u32, x: *const kern.PredMesh) bool {
    const sv = sel;
    if (sv == 0) return true;
    const p = x.verts;
    if (sv >= 3) {
        var tol = x.bmax[1] - x.bmin[1];
        tol *= 1.0e-4;
        tol += 1.0e-4;
        const ya = p[a][1];
        const yb = p[b][1];
        if (sv == 3) return minss(ya, yb) + tol >= x.bmax[1];
        return !(maxss(ya, yb) - tol > x.bmin[1]);
    }
    var dx = p[b][0] - p[a][0];
    var dz = p[b][2] - p[a][2];
    var dy = p[b][1] - p[a][1];
    dx *= dx;
    dz *= dz;
    dy *= dy;
    var l2 = dx + dz;
    l2 += dy;
    if (sv == 1) {
        var t: f32 = 0.99;
        t *= t;
        t *= l2;
        return dy > t;
    }
    var t: f32 = 0.01;
    t *= t;
    t *= l2;
    return !(dy >= t); // (jb: NaN takes it)
}

/// Fillet / chamfer: the body's sharp edges (sharper than ~25 degrees, the
/// selector's) rounded or cut; a closed body stays closed or nothing changes.
fn bevel(r: *const [FT_SZ]u8, s: u32) u32 {
    const body = bd_mesh[s] orelse return S_EMPTY;
    const v = slotVal(slot(r, 0)) orelse return S_VALUE;
    if (!(v > 0)) return S_VALUE;
    const w: f32 = @floatCast(v);
    var seg: i32 = 1;
    if (get(r, FT_TYPE) != T_CHAMFER) {
        seg = geti(r, FT_COUNT);
        if (seg < 1) seg = 4;
    }
    sel = get(r, FT_REF);
    const merged = fm.flatMerge(A, &body) catch null;
    defer if (merged) |mm| mm.deinit(A);
    const src = if (merged) |*mm| mm else &body;
    const pm = kern.PredMesh{ .verts = src.verts, .bmin = src.bmin, .bmax = src.bmax };
    const out = kern.bevelPred(A, src.asP(), w, @intCast(seg), 0.9, edgePick, &pm) catch return S_GEOM;
    var res = fm.fromP(out);
    const k = fm.compact(A, &res) catch {
        res.deinit(A);
        return S_GEOM;
    };
    res.deinit(A);
    res = k;
    if ((fm.manifold(A, &body) catch false) and !(fm.manifold(A, &res) catch false)) {
        res.deinit(A);
        return S_GEOM;
    }
    setBody(s, res);
    return S_OK;
}

const ident = [12]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };

/// m_move: a translation along an axis.
pub fn mMove(axis: u32, d: f64) [12]f32 {
    var x = ident;
    const a = if (axis > 2) 2 else axis;
    x[a * 4 + 3] = @floatCast(d);
    return x;
}

/// m_turn: a turn about the origin.
pub fn mTurn(axis: u32, angle: f64) [12]f32 {
    const sc = @import("animexpr.zig").sincos32(@floatCast(angle));
    const s = sc[0];
    const c = sc[1];
    const ns = 0 - s;
    var x = ident;
    if (axis == 1) {
        x[0] = c;
        x[2] = s;
        x[8] = ns;
        x[10] = c;
    } else if (axis > 1) {
        x[0] = c;
        x[1] = ns;
        x[4] = s;
        x[5] = c;
    } else {
        x[5] = c;
        x[6] = ns;
        x[9] = s;
        x[10] = c;
    }
    return x;
}

/// Patterns: an earlier pad .. shell of this body again, moved or turned.
fn pattern(r: *const [FT_SZ]u8, s: u32, x: ?*const [12]f32) u32 {
    if (x != null) return S_REF; // (no patterns of patterns)
    const ref = get(r, FT_REF);
    if (ref >= cur_feat) return S_REF;
    const pr = rec(ref);
    const pt = get(pr, FT_TYPE);
    if (pt < T_PAD or pt > T_SHELL) return S_REF;
    if (get(pr, FT_BODY) != get(r, FT_BODY)) return S_REF;
    var step = slotVal(slot(r, 0)) orelse return S_VALUE;
    var n = geti(r, FT_COUNT);
    if (n < 2) n = 2;
    const circ = get(r, FT_TYPE) == T_CPAT;
    if (circ) {
        if (step == 0 or std.math.isNan(step)) step = 6.28318530717958647692;
        const a = @abs(step);
        var k = n;
        if (!(a >= 6.2831)) k -= 1;
        step /= @as(f64, @floatFromInt(k));
    }
    var c: i32 = 1;
    while (c < n) : (c += 1) {
        const d = @as(f64, @floatFromInt(c)) * step;
        const mt = if (circ) mTurn(get(r, FT_AXIS), d) else mMove(get(r, FT_AXIS), d);
        const st = apply(pr, s, &mt);
        if (st != S_OK) return st;
    }
    return S_OK;
}

/// sdf_invert: the inverse of a 3x4 affine matrix (cofactors; a singular one
/// gives the identity).
fn sdfInvert(a: *const [12]f32) [12]f32 {
    var c: [9]f32 = undefined;
    c[0] = a[5] * a[10] - a[6] * a[9];
    c[1] = a[2] * a[9] - a[1] * a[10];
    c[2] = a[1] * a[6] - a[2] * a[5];
    c[3] = a[6] * a[8] - a[4] * a[10];
    c[4] = a[0] * a[10] - a[2] * a[8];
    c[5] = a[2] * a[4] - a[0] * a[6];
    c[6] = a[4] * a[9] - a[5] * a[8];
    c[7] = a[1] * a[8] - a[0] * a[9];
    c[8] = a[0] * a[5] - a[1] * a[4];
    var det = a[0] * c[0];
    det += a[1] * c[3];
    det += a[2] * c[6];
    if (!(@abs(det) > 1.0e-20)) return ident;
    const inv = 1.0 / det;
    var o: [12]f32 = undefined;
    for (0..3) |row| {
        const x = c[row * 3] * inv;
        const y = c[row * 3 + 1] * inv;
        const z = c[row * 3 + 2] * inv;
        o[row * 4] = x;
        o[row * 4 + 1] = y;
        o[row * 4 + 2] = z;
        var t = x * a[3];
        t += y * a[7];
        t += z * a[11];
        o[row * 4 + 3] = 0 - t;
    }
    return o;
}

/// Infill: a lattice (FT_AXIS 0 gyroid, 1 grid of struts) filling the cavity
/// of an earlier shell, reaching into its walls, joined to the body as a
/// shell of its own.
fn infill(r: *const [FT_SZ]u8, s: u32) u32 {
    const ref = get(r, FT_REF);
    if (ref >= cur_feat) return S_REF;
    const sh = rec(ref);
    if (get(sh, FT_TYPE) != T_SHELL) return S_REF;
    if (get(sh, FT_BODY) != get(r, FT_BODY)) return S_REF;
    const pref = get(sh, FT_REF);
    if (pref >= cur_feat) return S_REF;
    const padr = rec(pref);
    if (get(padr, FT_TYPE) != T_PAD) return S_REF;
    const so = sketchOf(pref, padr) orelse return S_SKETCH;
    const wall = slotVal(slot(sh, 0)) orelse return S_VALUE;
    const cell = slotVal(slot(r, 0)) orelse return S_VALUE;
    const lw = slotVal(slot(r, 1)) orelse return S_VALUE;
    if (!(lw > 0)) return S_VALUE;
    if (!(cell > 0)) return S_VALUE;
    const ext = slotVal(slot(padr, 0)) orelse return S_VALUE;
    padRange(padr, ext);
    const b = scene.objects[so].sk.?;
    _ = prof.build(b);
    if (prof.count() == 0) return S_PROFILE;
    const t = wall * 0.75;
    prof.offset(t);
    var w0 = fr_w[0];
    var w1 = fr_w[1];
    if (get(sh, FT_FLAGS) & FF_REV == 0) w0 += t else w1 -= t;
    const saved = sdf.n;
    defer sdf.n = saved;
    // the segments, one per loop point
    const seg = A.alloc([4]f32, prof.T.pf_np) catch return S_GEOM;
    defer A.free(seg);
    var ns: usize = 0;
    for (0..prof.T.pf_nl) |l| {
        const st = prof.T.pf_ls[l];
        const n = prof.T.pf_ln[l];
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const p = prof.T.pf_pt[st + i];
            const q = prof.T.pf_pt[st + (i + 1) % n];
            seg[ns] = .{ @floatCast(p[0]), @floatCast(p[1]), @floatCast(q[0]), @floatCast(q[1]) };
            ns += 1;
        }
    }
    const pid = sdf.prism(seg[0..ns], b.plane, @floatCast(b.offset), @floatCast(w0), @floatCast(w1));
    if (pid == 0) return S_GEOM;
    const mt = @import("measure.zig").objMatrix(so);
    const fwd: [12]f32 = mt[0..12].*;
    const inv = sdfInvert(&fwd);
    const xf = sdf.new(sdf.S_XFORM, pid, 0, null, &inv, &fwd);
    var lp: [6]f32 = .{ @floatCast(cell), @floatCast(lw), 0, 0, 0, 0 };
    const kind = get(r, FT_AXIS);
    if (kind == 1) lp[1] *= 0.5;
    const lat = sdf.new(5 +% kind, 0, 0, &lp, null, null);
    if (lat == 0 or xf == 0) return S_GEOM;
    const root = sdf.new(sdf.S_ISECT, lat, xf, null, null, null);
    if (root == 0) return S_GEOM;
    const bb = sdf.boundsOf(root);
    var side: f32 = 0;
    for (0..3) |c| side = maxss(side, bb[c + 3] - bb[c]);
    var vox: f32 = @floatCast(cell);
    vox *= 0.16666667;
    var v2: f32 = @floatCast(lw);
    v2 *= 0.6666667;
    vox = minss(vox, v2);
    const q = side / vox;
    var cells: i32 = if (q >= -2147483648.0 and q < 2147483648.0) @intFromFloat(q) else std.math.minInt(i32);
    if (cells < 16) cells = 16;
    if (cells > 256) cells = 256;
    var out = sdf.mesh(root, cells) orelse return S_GEOM;
    defer out.deinit();
    const ntri = out.loops.items.len / 3;
    const poff = A.alloc(u32, ntri + 1) catch return S_GEOM;
    for (poff, 0..) |*o, k| o.* = @intCast(k * 3);
    const verts = A.dupe(m.V3, out.verts.items) catch {
        A.free(poff);
        return S_GEOM;
    };
    const loops = A.dupe(u32, out.loops.items[0 .. ntri * 3]) catch {
        A.free(poff);
        A.free(verts);
        return S_GEOM;
    };
    const lat_m = fm.finish(verts, poff, loops);
    if (bd_mesh[s]) |body| {
        const j = fm.append(A, &body, &lat_m) catch {
            lat_m.deinit(A);
            return S_GEOM;
        };
        lat_m.deinit(A);
        setBody(s, j);
    } else bd_mesh[s] = lat_m;
    return S_OK;
}

// ---- editing the list ------------------------------------------------------------------

/// feat_add: a record appended, the parts rebuilt -> its index (null: full).
pub fn add(r: *const [FT_SZ]u8) ?usize {
    const b = cad.own() orelse return null;
    if (b.nf >= MAX_FEATS) return null;
    const i = b.nf;
    b.feats[i] = r.*;
    b.fraw[i] = 0;
    noteUids(b, i);
    b.nf += 1;
    cad.sync();
    rebuild();
    return i;
}

/// feat_slot_set: slot 0..2 to a text (or a number); 3: suppressed when the
/// number is not 0. False: no such feature.
pub fn slotSet(i: usize, k: u32, text: ?[]const u8, v: f64) bool {
    if (i >= count() or k > 3) return false;
    const b = cad.own() orelse return false;
    const r = &b.feats[i];
    if (k == 3) {
        var f = get(r, FT_FLAGS) & ~FF_OFF;
        if (v != 0) f |= FF_OFF;
        set(r, FT_FLAGS, f);
    } else {
        const sp = r[FT_X + 32 * k ..][0..32];
        if (text) |t| {
            const n = @min(t.len, 31);
            @memcpy(sp[0..n], t[0..n]);
            if (n < 32) sp[n] = 0;
        } else {
            sp[0] = 1;
            std.mem.writeInt(u64, sp[8..16], @bitCast(v), .little);
        }
    }
    cad.sync();
    rebuild();
    return true;
}

/// cad.feature_move <n> up|down: a feature and its neighbour trade places;
/// what refers to either (shell -> pad, patterns, infill -> shell) keeps
/// referring to the same one; the parts rebuild.
pub fn move(i: u32, up: bool) bool {
    const n: u32 = @intCast(count());
    const j: i64 = if (up) @as(i64, i) - 1 else @as(i64, i) + 1;
    if (j < 0 or i >= n or j >= n) return false;
    const ju: u32 = @intCast(j);
    const b = cad.own() orelse return false;
    std.mem.swap([FT_SZ]u8, &b.feats[i], &b.feats[ju]);
    std.mem.swap(u8, &b.fraw[i], &b.fraw[ju]);
    std.mem.swap([2]u32, &b.fuid[i], &b.fuid[ju]);
    for (0..n) |k| {
        const r = &b.feats[k];
        const t = get(r, FT_TYPE);
        if (t != T_SHELL and t < T_LPAT) continue;
        const ref = get(r, FT_REF);
        if (ref == i) set(r, FT_REF, ju) else if (ref == ju) set(r, FT_REF, i);
    }
    cad.sync();
    rebuild();
    return true;
}

// ---- the script functions (pad, pocket ... feature) as the operators use them -----------

/// A script's runtime error: the console's line, as the original's.
fn scErr(comptime fmt: []const u8, args: anytype) void {
    app.log("  error: line 1: " ++ fmt, args);
}

/// The scene's object called exactly this (obj_find).
pub fn findExact(name: []const u8) ?usize {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (std.mem.eql(u8, o.name(), name)) return i;
    }
    return null;
}

var ft_tmp: [FT_SZ]u8 = @splat(0);

fn fbNew(t: u32) void {
    ft_tmp = @splat(0);
    set(&ft_tmp, FT_TYPE, t);
}

/// fb_slot: a value text that works into slot k; false when it said why not.
fn fbSlot(text: []const u8, k: usize) bool {
    _ = cad.eval(text) orelse {
        scErr("parameter: {s}", .{cad.expr.err orelse ""});
        return false;
    };
    if (text.len >= 32) {
        scErr("a feature value is 31 characters at most: {s}", .{text});
        return false;
    }
    const sp = ft_tmp[FT_X + 32 * k ..][0..32];
    @memset(sp, 0);
    @memcpy(sp[0..text.len], text);
    return true;
}

const Word = struct { w: []const u8, v: u32 };
const fw_modes = [_]Word{ .{ .w = "symmetric", .v = 1 }, .{ .w = "normal", .v = 0 }, .{ .w = "reverse", .v = 2 }, .{ .w = "through", .v = 4 }, .{ .w = "bottom", .v = 2 } };
const fw_axes = [_]Word{ .{ .w = "x", .v = 0 }, .{ .w = "y", .v = 1 }, .{ .w = "z", .v = 2 }, .{ .w = "u", .v = 0 }, .{ .w = "v", .v = 1 } };
const fw_sels = [_]Word{ .{ .w = "all", .v = 0 }, .{ .w = "vertical", .v = 1 }, .{ .w = "horizontal", .v = 2 }, .{ .w = "top", .v = 3 }, .{ .w = "bottom", .v = 4 } };
const fw_circ = [_]Word{ .{ .w = "circular", .v = 1 }, .{ .w = "linear", .v = 0 } };
const fw_lat = [_]Word{ .{ .w = "gyroid", .v = 0 }, .{ .w = "grid", .v = 1 } };

fn fbWord(w: []const u8, tab: []const Word) ?u32 {
    for (tab) |x| {
        if (std.mem.eql(u8, x.w, w)) return x.v;
    }
    scErr("not understood here: {s}", .{w});
    return null;
}

/// a_sketch: the sketch object called this, or it says so.
fn aSketch(name: []const u8) ?usize {
    if (findExact(name)) |i| {
        if (scene.objects[i].kind == .sketch and scene.objects[i].sk != null) return i;
    }
    scErr("no sketch called {s}", .{name});
    return null;
}

/// As unique_name: the name (26 bytes at most), then ".001" ...
fn uniqueName(o: *scene.Object, base0: []const u8) void {
    var base = base0[0..@min(base0.len, 26)];
    while (base.len > 0 and base[base.len - 1] & 0xc0 == 0x80) base = base[0 .. base.len - 1];
    o.setName(base);
    var buf: [32]u8 = undefined;
    var k: u32 = 1;
    while (findExact(o.name()) != null and k <= 999) : (k += 1) {
        o.setName(std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ base, k }) catch return);
    }
}

/// fb_finish: the body (a new empty mesh object when there is none), the
/// feature -> its index, or null when it said why not.
fn fbFinish(body: []const u8) ?usize {
    undo.label("Script");
    var oi = findExact(body);
    if (oi) |i| {
        if (!scene.objects[i].kind.isMesh()) {
            scErr("the body is not a mesh: {s}", .{body});
            return null;
        }
    } else {
        if (scene.count >= scene.max_objects) {
            scErr("the scene holds 64 features", .{});
            return null;
        }
        const mi = scene.addEmptyMesh() orelse {
            scErr("the scene holds 64 features", .{});
            return null;
        };
        var o = scene.Object{ .kind = .mesh, .mesh = mi, .color = 0xb4b8c0 }; // (type_colors[OT_MESH])
        uniqueName(&o, body);
        scene.objects[scene.count] = o;
        scene.stamp(scene.count);
        scene.count += 1;
        oi = scene.count - 1;
    }
    set(&ft_tmp, FT_BODY, scene.objects[oi.?].oid);
    return add(&ft_tmp) orelse {
        scErr("the scene holds 64 features", .{});
        return null;
    };
}

/// select(name) after a feature: the body selected and active.
fn selectBody(name: []const u8) void {
    if (findExact(name)) |i| scene.selectOnly(i);
}

/// pad / pocket / revolve / hole(body, sketch, value [, mode | axis | depth]).
fn fbExtrude(t: u32, body: []const u8, skn: []const u8, val: []const u8, opt: ?[]const u8) ?usize {
    fbNew(t);
    const so = aSketch(skn) orelse return null;
    set(&ft_tmp, FT_SKETCH, scene.objects[so].oid);
    if (!fbSlot(val, 0)) return null;
    if (opt) |o| switch (t) {
        T_REVOLVE => set(&ft_tmp, FT_AXIS, (fbWord(o, &fw_axes) orelse return null) & 1),
        T_HOLE => if (!fbSlot(o, 1)) return null,
        else => set(&ft_tmp, FT_FLAGS, fbWord(o, &fw_modes) orelse return null),
    };
    return fbFinish(body);
}

/// A BeeScript value as a template's bare %n makes it: a number (a_int:
/// truncated), or the compile / runtime error the original gives.
fn bareInt(w: []const u8) ?i32 {
    if (w.len == 0) {
        scErr("expected a value", .{});
        return null;
    }
    if (std.ascii.isAlphabetic(w[0]) or w[0] == '_') {
        var e: usize = 0;
        while (e < w.len and (std.ascii.isAlphanumeric(w[e]) or w[e] == '_')) e += 1;
        scErr("not defined: {s}", .{w[0..e]});
        return null;
    }
    const v = std.fmt.parseFloat(f64, w) catch {
        scErr("expected a value", .{});
        return null;
    };
    if (!(v > -2147483649.0 and v < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(v);
}

/// pad(body, sketch, value) as a template's script calls it (no mode).
pub fn pad(body: []const u8, skn: []const u8, val: []const u8) ?usize {
    return fbExtrude(T_PAD, body, skn, val, null);
}

/// fillet(body, size, edges).
pub fn fillet(body: []const u8, val: []const u8, edges: []const u8) ?usize {
    fbNew(T_FILLET);
    if (!fbSlot(val, 0)) return null;
    set(&ft_tmp, FT_REF, fbWord(edges, &fw_sels) orelse return null);
    return fbFinish(body);
}

// ---- the operators ---------------------------------------------------------------------

/// cad_script's split_args: the argument's words ("quoted words" are one), at most 9.
fn words(arg: []const u8, out: *[9][]const u8) void {
    for (out) |*w| w.* = "";
    var i: usize = 0;
    var n: usize = 0;
    while (n < 9) {
        while (i < arg.len and arg[i] == ' ') i += 1;
        if (i >= arg.len or arg[i] == 0) break;
        var end: u8 = ' ';
        if (arg[i] == '"') {
            end = '"';
            i += 1;
        }
        const s0 = i;
        while (i < arg.len and arg[i] != end and arg[i] != 0) i += 1;
        out[n] = arg[s0..i];
        n += 1;
        if (i < arg.len and arg[i] == end) i += 1;
    }
}

/// %a: the active object's name, or "select an object first" (and nothing runs).
fn activeName() ?[]const u8 {
    if (scene.active) |a| return scene.objects[a].name();
    app.log("  select an object first", .{});
    return null;
}

fn argWords(w: *[9][]const u8) void {
    words(std.mem.sliceTo(@import("ops.zig").arg, 0), w);
}

fn opExtrude(comptime t: u32) fn () void {
    return struct {
        fn f() void {
            var w: [9][]const u8 = undefined;
            argWords(&w);
            const a = activeName() orelse return;
            var opt: ?[]const u8 = w[2];
            // hole: %"3 (the depth only when it is there and not 0)
            if (t == T_HOLE and (w[2].len == 0 or std.mem.eql(u8, w[2], "0"))) opt = null;
            if (fbExtrude(t, w[0], a, w[1], opt) != null) selectBody(w[0]);
        }
    }.f;
}

/// cad.shell <pad feature> <wall> <normal|bottom>
fn opShell() void {
    var w: [9][]const u8 = undefined;
    argWords(&w);
    const a = activeName() orelse return;
    fbNew(T_SHELL);
    const ref = bareInt(w[0]) orelse return;
    set(&ft_tmp, FT_REF, @bitCast(ref));
    if (!fbSlot(w[1], 0)) return;
    set(&ft_tmp, FT_FLAGS, (fbWord(w[2], &fw_modes) orelse return) & FF_REV);
    _ = fbFinish(a);
}

/// cad.fillet / cad.chamfer <size> <all|vertical|horizontal|top|bottom>
fn opEdges(comptime t: u32) fn () void {
    return struct {
        fn f() void {
            var w: [9][]const u8 = undefined;
            argWords(&w);
            const a = activeName() orelse return;
            fbNew(t);
            if (!fbSlot(w[0], 0)) return;
            set(&ft_tmp, FT_REF, fbWord(w[1], &fw_sels) orelse return);
            _ = fbFinish(a);
        }
    }.f;
}

/// cad.pattern <feature> <count> <step or angle> <x|y|z> <linear|circular>
fn opPattern() void {
    var w: [9][]const u8 = undefined;
    argWords(&w);
    const a = activeName() orelse return;
    fbNew(T_LPAT);
    const ref = bareInt(w[0]) orelse return;
    const cnt = bareInt(w[1]) orelse return;
    set(&ft_tmp, FT_REF, @bitCast(ref));
    set(&ft_tmp, FT_COUNT, @bitCast(cnt));
    if (!fbSlot(w[2], 0)) return;
    set(&ft_tmp, FT_AXIS, fbWord(w[3], &fw_axes) orelse return);
    const c = fbWord(w[4], &fw_circ) orelse return;
    set(&ft_tmp, FT_TYPE, T_LPAT + c);
    _ = fbFinish(a);
}

/// cad.infill <shell feature> <gyroid|grid> <cell> <wall>
fn opInfill() void {
    var w: [9][]const u8 = undefined;
    argWords(&w);
    const a = activeName() orelse return;
    fbNew(T_INFILL);
    const ref = bareInt(w[0]) orelse return;
    set(&ft_tmp, FT_REF, @bitCast(ref));
    set(&ft_tmp, FT_AXIS, fbWord(w[1], &fw_lat) orelse return);
    if (!fbSlot(w[2], 0)) return;
    if (!fbSlot(w[3], 1)) return;
    _ = fbFinish(a);
}

/// feature(index, slot, value): the CAD tab's value field and On toggle.
/// False when it said why not.
pub fn feature(i: i64, k: i64, text: ?[]const u8, v: f64) bool {
    if (text) |t| {
        _ = cad.eval(t) orelse {
            scErr("parameter: {s}", .{cad.expr.err orelse ""});
            return false;
        };
    }
    undo.label("Script");
    if (i < 0 or k < 0 or !slotSet(@intCast(i), @intCast(@min(k, 4)), text, v)) {
        scErr("no such feature", .{});
        return false;
    }
    return true;
}

/// cad.feature_move <number> up|down
fn opMove() void {
    const arg = std.mem.sliceTo(@import("ops.zig").arg, 0);
    var it = std.mem.tokenizeScalar(u8, arg, ' ');
    const nw = it.next() orelse "";
    const dw = it.next() orelse "";
    var n: u32 = 0;
    var ok = nw.len > 0;
    for (nw) |c| {
        if (c < '0' or c > '9') ok = false else n = n *% 10 +% (c - '0');
    }
    const up = std.mem.eql(u8, dw, "up");
    if (!ok or (!up and !std.mem.eql(u8, dw, "down"))) {
        app.log("  cad.feature_move <number> up|down", .{});
        return;
    }
    _ = move(n, up);
}

/// poll_sketch / poll_part: menus, buttons and the palette ask (they say why
/// on the status line); the console, scripts and forms' OK do not (the
/// original's run_op does not ask either).
fn pollSketch() ?[]const u8 {
    if (@import("ops.zig").scripted) return null;
    if (scene.active) |a| {
        if (scene.objects[a].kind == .sketch) return null;
    }
    return "select a sketch first";
}
fn pollPart() ?[]const u8 {
    if (@import("ops.zig").scripted) return null;
    if (scene.active) |a| {
        if (scene.objects[a].kind.isMesh()) return null;
    }
    return "select a mesh (a part) first";
}

const Impl = @import("ops.zig").Impl;
pub const list = .{
    .{ "cad.pad", Impl{ .run = opExtrude(T_PAD), .poll = pollSketch } },
    .{ "cad.pocket", Impl{ .run = opExtrude(T_POCKET), .poll = pollSketch } },
    .{ "cad.revolve", Impl{ .run = opExtrude(T_REVOLVE), .poll = pollSketch } },
    .{ "cad.hole", Impl{ .run = opExtrude(T_HOLE), .poll = pollSketch } },
    .{ "cad.shell", Impl{ .run = opShell, .poll = pollPart } },
    .{ "cad.fillet", Impl{ .run = opEdges(T_FILLET), .poll = pollPart } },
    .{ "cad.chamfer", Impl{ .run = opEdges(T_CHAMFER), .poll = pollPart } },
    .{ "cad.pattern", Impl{ .run = opPattern, .poll = pollPart } },
    .{ "cad.infill", Impl{ .run = opInfill, .poll = pollPart } },
    .{ "cad.feature_move", Impl{ .run = opMove } },
};

/// Console lines naming the original's feature functions (the port has no
/// BeeScript yet): feature <index> <slot 0..2 | 3 suppressed> <"text" | number>
/// (as feature(); prints the status afterwards), fstatus <index>, features.
/// False: not one of them.
pub fn console(verb: []const u8, arg: []const u8) bool {
    if (std.mem.eql(u8, verb, "features")) {
        app.log("  {d}", .{count()});
        return true;
    }
    if (std.mem.eql(u8, verb, "fstatus")) {
        const i = std.fmt.parseInt(i64, std.mem.trim(u8, arg, " "), 10) catch -1;
        app.log("  {d}", .{if (i >= 0) status(@intCast(i)) else 0});
        return true;
    }
    if (!std.mem.eql(u8, verb, "feature")) return false;
    var w: [9][]const u8 = undefined;
    words(arg, &w);
    const i = bareInt(w[0]) orelse return true;
    const k = bareInt(w[1]) orelse return true;
    // a quoted value is a text, else a number
    const rest = std.mem.trim(u8, arg, " ");
    const quoted = std.mem.indexOfScalar(u8, rest, '"') != null;
    if (quoted) {
        if (!feature(i, k, w[2], 0)) return true;
    } else {
        const v = cad.eval(w[2]) orelse {
            scErr("expected a value", .{});
            return true;
        };
        if (!feature(i, k, null, v)) return true;
    }
    app.log("  {d}", .{status(@intCast(i))});
    return true;
}

/// wg_ftoa: a number with dec decimals at most, zeros and a bare point dropped.
pub fn ftoa(buf: []u8, v: f32, dec0: u32) []const u8 {
    const pow10 = [_]f64{ 1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0 };
    const dec = @min(dec0, 6);
    var x: f64 = @as(f64, v) * pow10[dec];
    var neg = false;
    if (!(x >= 0)) {
        x = 0.0 - x;
        neg = true;
    }
    x += 0.5;
    const r: u64 = if (x > -9.3e18 and x < 9.2e18) @bitCast(@as(i64, @intFromFloat(x))) else 0x8000000000000000;
    if (r == 0) neg = false;
    var w: usize = 0;
    if (neg) {
        buf[0] = '-';
        w = 1;
    }
    var dg: [32]u8 = undefined;
    var n: usize = 0;
    var q = r;
    while (true) {
        dg[n] = @intCast('0' + q % 10);
        n += 1;
        q /= 10;
        if (q == 0) break;
    }
    while (n <= dec) : (n += 1) dg[n] = '0';
    while (true) {
        n -= 1;
        buf[w] = dg[n];
        w += 1;
        if (n == 0) break;
        if (n == dec) {
            buf[w] = '.';
            w += 1;
        }
    }
    if (dec != 0) {
        while (buf[w - 1] == '0') w -= 1;
        if (buf[w - 1] == '.') w -= 1;
    }
    return buf[0..w];
}

test "ftoa as wg_ftoa" {
    var b: [40]u8 = undefined;
    const T = std.testing;
    try T.expectEqualStrings("1.5", ftoa(&b, 1.5, 3));
    try T.expectEqualStrings("10", ftoa(&b, 10, 3));
    try T.expectEqualStrings("0", ftoa(&b, -0.0001, 3));
    try T.expectEqualStrings("-0.25", ftoa(&b, -0.25, 3));
    try T.expectEqualStrings("0.002", ftoa(&b, 0.002, 3));
}

test "patterns' matrices and the inverse" {
    const T = std.testing;
    const x = mMove(7, 2.5);
    try T.expectEqual(@as(f32, 2.5), x[11]);
    const r = mTurn(2, 0.5);
    const inv = sdfInvert(&r);
    // R^-1 R = I
    for (0..3) |i| {
        for (0..3) |j| {
            var s: f32 = 0;
            for (0..3) |k| s += inv[i * 4 + k] * r[k * 4 + j];
            try T.expectApproxEqAbs(@as(f32, if (i == j) 1 else 0), s, 1e-6);
        }
    }
    try T.expectEqualStrings("Circular pattern", typeName(T_CPAT));
    try T.expectEqualStrings("the geometry failed", statusName(99));
}
