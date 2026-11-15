//! CAD features as B-rep solids (bfeat.s), while cad.kernel is on.
//!
//! After the feature tree's mesh replay (feature.zig), rebuild replays it
//! again in the kernel: pads and revolves are extruded / revolved from their
//! sketches' exact profiles (bbuild.zig) and united with their body,
//! pockets, holes and shells cut away (bbool.zig), fillets and chamfers
//! round straight edges between planes (bfillet.zig), patterns repeat a
//! feature with a transform. A body whose features all work this way gets
//! its tessellated B-rep as its mesh; a feature the kernel cannot do
//! (infill lattices, a fillet where rounded edges meet ...) leaves that body
//! with the mesh replay's result from there on. The statuses are the mesh
//! replay's. body() finds an object's solid for STEP export and brep()
//! (bquery.zig); the kernel switch off, there are none but imported parts.
//!
//! feature.brep_hook runs rebuild after every feature rebuild; it installs
//! body() as step.bodyOf and bbool's bk_err as bquery.bk_err.
//!
//! Deliberate differences from the original:
//!   * Undo and redo restore the meshes and the document but leave the
//!     original's solids as the last rebuild made them (STEP export and
//!     brep() then describe a state that is no longer shown); here the
//!     solids are made again from what undo restored, the first time they
//!     are asked for (the meshes are left as undo restored them).
//!   * A feature body that is not a mesh object: the original writes the
//!     solid's triangles into whatever object it is (a sketch's or a lamp's
//!     display); here its solid is kept (brep(), STEP) but its mesh is not
//!     touched.
//!   * Body slots: a body reference a file named but no object has is kept
//!     apart from the objects (the port's object ids could equal it).
const std = @import("std");
const app = @import("app.zig");
const m = @import("math.zig");
const scene = @import("scene.zig");
const cad = @import("cad.zig");
const ft = @import("feature.zig");
const undo = @import("undo.zig");
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const bt = @import("btess.zig");
const ss = @import("bssi.zig");
const bb = @import("bbuild.zig");
const bo = @import("bbool.zig");
const fl = @import("bfillet.zig");
const sr = @import("stepread.zig");
const NONE = br.NONE;

const A = std.heap.page_allocator;
const MAXB = 16;

const bf_ov: f64 = 0.02;
const bf_2pi: f64 = 6.28318530717958647692;
const bf_2pim: f64 = 6.2831;

pub var bf_count: u32 = 0; // bodies
var bf_uids: [MAXB]u32 = undefined; // their objects (oids)
var bf_raw: [MAXB]bool = undefined; //  (or a file's uid no object has)
pub var bf_bds: [MAXB]u32 = undefined; // their solids (NONE: none yet)
var bf_ok: [MAXB]bool = undefined; // all features in the kernel so far
var bf_cur: u32 = 0; // the feature being replayed
/// undo.restores when the solids were made (they follow undo lazily)
var made_at: u32 = 0;

/// How long the last kernel replay took (ns), for the bench.
pub var last_ns: u64 = 0;

fn install() void {
    @import("step.zig").bodyOf = body;
    @import("bquery.zig").bk_err = bkErr;
}

fn bkErr() i32 {
    return @bitCast(bo.bk_err);
}

/// bf_slot(record i) -> its body's slot (null: too many)
fn slotOf(i: u32) ?u32 {
    const r = ft.rec(i);
    const uid = ft.get(r, ft.FT_BODY);
    const raw = cad.cur.?.fraw[i] & 1 != 0;
    var k: u32 = 0;
    while (k < bf_count) : (k += 1) {
        if (bf_uids[k] == uid and bf_raw[k] == raw) return k;
    }
    if (k >= MAXB) return null;
    bf_uids[k] = uid;
    bf_raw[k] = raw;
    bf_bds[k] = NONE;
    bf_ok[k] = true;
    bf_count += 1;
    return k;
}

/// bf_body(object id) -> its solid, or NONE (an imported STEP part's when no
/// feature body has it)
pub fn body(oid: u32) u32 {
    fresh();
    var k: u32 = 0;
    while (k < bf_count) : (k += 1) {
        if (bf_uids[k] != oid or bf_raw[k]) continue;
        if (!bf_ok[k]) break;
        return bf_bds[k];
    }
    return sr.stBody(oid);
}

/// The solids made again when undo moved since (not the meshes).
fn fresh() void {
    if (made_at == undo.restores) return;
    replay(false);
}

/// bf_rebuild: the feature tree replayed in the kernel (when it is on); each
/// solid body takes its tessellation as its mesh.
pub fn rebuild() void {
    install();
    replay(true);
}

fn replay(commit: bool) void {
    made_at = undo.restores;
    bf_count = 0;
    if (!cad.kernel()) return;
    const t0 = monoNs();
    defer last_ns = monoNs() -% t0;
    br.reset();
    ss.reset();
    bt.bt_tol = 0;
    const n: u32 = @intCast(ft.count());
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        bf_cur = i;
        const r = ft.rec(i);
        if (ft.get(r, ft.FT_FLAGS) & ft.FF_OFF != 0) continue;
        const s = slotOf(i) orelse continue;
        if (!bf_ok[s]) continue;
        if (!apply(r, s, null)) bf_ok[s] = false;
    }
    sr.stRebuild(); // imported solids after the reset
    // each solid body: its tessellation
    var k: u32 = 0;
    while (k < bf_count) : (k += 1) {
        if (!bf_ok[k] or bf_bds[k] == NONE) continue;
        bt.bt_tol = 0; // (a tolerance for each body's size)
        bt.bdTess(bf_bds[k]);
        if (!commit or bf_raw[k]) continue;
        const oi = scene.findOid(bf_uids[k]) orelse continue;
        if (!scene.objects[oi].kind.isMesh()) continue;
        const mi = toMesh(bf_bds[k]) orelse continue;
        const old = scene.objects[oi].mesh;
        scene.objects[oi].mesh = mi;
        if (old) |om| release(om);
        app.dirty = true;
    }
}

fn monoNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// bd_tomesh: the vertices (as floats), a triangle per polygon
fn toMesh(b: u32) ?u16 {
    const ts = bt.bdTri(b) orelse return null;
    if (ts.nv == 0 or ts.nt == 0) return scene.addEmptyMesh();
    const verts = A.alloc(m.V3, ts.nv) catch return null;
    defer A.free(verts);
    for (verts, 0..) |*v, i| v.* = .{ @floatCast(ts.pv[i * 3]), @floatCast(ts.pv[i * 3 + 1]), @floatCast(ts.pv[i * 3 + 2]) };
    const poff = A.alloc(u32, @as(usize, ts.nt) + 1) catch return null;
    defer A.free(poff);
    for (poff, 0..) |*p, i| p.* = @intCast(i * 3);
    return scene.addMesh(verts, poff, ts.pt[0 .. @as(usize, ts.nt) * 3]);
}

/// The mesh a body showed before: freed at once when no object and no undo
/// step holds it (as feature.zig's).
fn release(mi: u16) void {
    for (scene.objects[0..scene.count]) |*o| {
        if (o.mesh == mi or o.mres == mi) return;
    }
    if (undo.anyStepHolds(mi)) return;
    if (scene.isPrim(mi)) return;
    scene.freeMeshSlot(mi);
}

// ---- the features ----------------------------------------------------------------------

/// bf_apply(feature, slot, extra transform) -> it worked
fn apply(r: *const [ft.FT_SZ]u8, s: u32, x: ?*const [12]f32) bool {
    const t = ft.get(r, ft.FT_TYPE);
    switch (t) {
        ft.T_FILLET, ft.T_CHAMFER => {
            const b = bf_bds[s];
            if (b == NONE) return false;
            const v = ft.slotVal(ft.slot(r, 0)) orelse return false;
            if (nb.jbe(v, 0)) return false;
            const res = fl.fillet(b, ft.get(r, ft.FT_REF), t == ft.T_CHAMFER, v);
            if (res == NONE) return false;
            bf_bds[s] = res;
            return true;
        },
        ft.T_LPAT, ft.T_CPAT => return pattern(r, s, x),
        ft.T_PAD...ft.T_SHELL => {
            const tl = tool(r, s, x);
            if (tl == NONE) return false;
            return combine(tl, s, if (t == ft.T_PAD or t == ft.T_REVOLVE) bo.OP_UNION else bo.OP_DIFF);
        },
        else => return false,
    }
}

/// Patterns: an earlier pad .. shell of this body again, moved or turned.
fn pattern(r: *const [ft.FT_SZ]u8, s: u32, x: ?*const [12]f32) bool {
    if (x != null) return false; // (no patterns of patterns)
    const ref = ft.get(r, ft.FT_REF);
    if (ref >= bf_cur) return false;
    const pr = ft.rec(ref);
    const pt = ft.get(pr, ft.FT_TYPE);
    if (pt < ft.T_PAD or pt > ft.T_SHELL) return false;
    if (ft.get(pr, ft.FT_BODY) != ft.get(r, ft.FT_BODY)) return false;
    var step = ft.slotVal(ft.slot(r, 0)) orelse return false; // spacing / angle
    var n: i32 = @bitCast(ft.get(r, ft.FT_COUNT));
    if (n < 2) n = 2;
    const circ = ft.get(r, ft.FT_TYPE) == ft.T_CPAT;
    if (circ) {
        // a circle: a full turn by default, and a full turn shares its ends
        if (nb.je(step, 0)) step = bf_2pi;
        var k = n;
        if (!nb.jae(nb.fabs(step), bf_2pim)) k -= 1;
        step = step / @as(f64, @floatFromInt(k));
    }
    var c: i32 = 1;
    while (c < n) : (c += 1) {
        const d = @as(f64, @floatFromInt(c)) * step;
        const mt = if (circ) ft.mTurn(ft.get(r, ft.FT_AXIS), d) else ft.mMove(ft.get(r, ft.FT_AXIS), d);
        if (!apply(pr, s, &mt)) return false;
    }
    return true;
}

/// bf_combine: the tool united with or cut from the body
fn combine(t: u32, s: u32, op: u32) bool {
    if (bf_bds[s] == NONE) {
        if (op != bo.OP_UNION) return false; // (the first solid of the body)
        bf_bds[s] = t;
        return true;
    }
    const r = bo.bool_(bf_bds[s], t, op);
    if (r == NONE) return false;
    bf_bds[s] = r;
    return true;
}

/// through: a depth that goes through the body
fn through(s: u32) f64 {
    const b = bf_bds[s];
    if (b == NONE) return 1.0;
    return bt.bdSize(b) * 3.0 + 1.0;
}

/// pad_range: w0 <= w1 of a pad's extent
fn padRange(r: *const [ft.FT_SZ]u8, d: f64) [2]f64 {
    var w0: f64 = 0;
    var w1 = d;
    const f = ft.get(r, ft.FT_FLAGS);
    if (f & ft.FF_SYM != 0) {
        w1 = d * 0.5;
        w0 = 0 - w1;
    } else if (f & ft.FF_REV != 0) {
        w0 = 0 - d;
        w1 = 0;
    }
    if (!nb.jbe(w0, w1)) return .{ w1, w0 };
    return .{ w0, w1 };
}

/// The sketch object a record names (an object of the scene that is a
/// sketch with its block), or null.
fn sketchObj(r: *const [ft.FT_SZ]u8) ?usize {
    const b = cad.cur.?;
    const i = (@intFromPtr(r) - @intFromPtr(&b.feats[0])) / ft.FT_SZ;
    if (b.fraw[i] & 2 != 0) return null;
    const oi = scene.findOid(ft.get(r, ft.FT_SKETCH)) orelse return null;
    if (scene.objects[oi].kind != .sketch or scene.objects[oi].sk == null) return null;
    return oi;
}

/// bf_tool(feature, slot, extra transform) -> the solid it adds or removes, or NONE
fn tool(r: *const [ft.FT_SZ]u8, s: u32, x: ?*const [12]f32) u32 {
    const t = ft.get(r, ft.FT_TYPE);
    var src = r; // the feature with the sketch
    if (t == ft.T_SHELL) {
        const ref = ft.get(r, ft.FT_REF); // shell: an earlier pad
        if (ref >= bf_cur) return NONE;
        src = ft.rec(ref);
        if (ft.get(src, ft.FT_TYPE) != ft.T_PAD) return NONE;
    }
    const so = sketchObj(src) orelse return NONE;
    const d = ft.slotVal(ft.slot(r, 0)) orelse return NONE;
    const d2 = ft.slotVal(ft.slot(r, 1)) orelse return NONE;
    const sk = scene.objects[so].sk.?;
    const mt = @import("measure.zig").objMatrix(so);
    bb.bpPlace(sk, mt[0..12], x);
    if (t == ft.T_HOLE) {
        const rad = d * 0.5; // hole: circles at loose points
        if (nb.jbe(rad, 0)) return NONE;
        if (bb.bpPoints(sk, rad) == 0) return NONE;
    } else if (bb.bpBuild(sk) == 0) return NONE;
    switch (t) {
        ft.T_REVOLVE => {
            if (nb.je(d, 0)) return NONE;
            return bb.bpRevolve(ft.get(r, ft.FT_AXIS), d);
        },
        ft.T_SHELL => {
            if (nb.jbe(d, 0)) return NONE; // the wall
            const ext = ft.slotVal(ft.slot(src, 0)) orelse return NONE; // the pad's extent
            const w = padRange(src, ext);
            if (!bb.bpOffset(d)) return NONE;
            var ov = w[1] - w[0]; // overshoot: 2% + the wall
            ov = ov * bf_ov;
            ov = ov + d;
            if (ft.get(r, ft.FT_FLAGS) & ft.FF_REV == 0) return bb.bpPrism(w[0] + d, w[1] + ov); // open at the top
            return bb.bpPrism(w[0] - ov, w[1] - d); // open at the bottom
        },
        ft.T_PAD => {
            const w = padRange(r, d);
            if (nb.je(w[0], w[1])) return NONE;
            return bb.bpPrism(w[0], w[1]);
        },
        else => {
            // pocket / hole: down from the sketch, a little past it
            const f = ft.get(r, ft.FT_FLAGS);
            var e = nb.fabs(if (t == ft.T_HOLE) d2 else d);
            if (f & ft.FF_THRU != 0 or !nb.ja(e, 0)) {
                if (f & ft.FF_THRU == 0 and t != ft.T_HOLE) return NONE;
                e = through(s);
            }
            const ov = e * bf_ov;
            var w0 = 0 - e; // -d .. ov
            var w1 = ov;
            if (f & ft.FF_REV != 0) {
                w0 = 0 - ov; // -ov .. d
                w1 = e;
            } else if (f & ft.FF_SYM != 0) {
                e = e * 0.5;
                w0 = 0 - e;
                w1 = e;
            }
            return bb.bpPrism(w0, w1);
        },
    }
}

test "bfeat compiles" {
    std.testing.refAllDecls(@This());
}
