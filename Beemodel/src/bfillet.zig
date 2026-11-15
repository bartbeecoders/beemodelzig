//! B-rep fillets and chamfers on straight edges between planes (bfillet.s).
//!
//! The edges the selector picks (all sharp ones, vertical, horizontal, top,
//! bottom - as for meshes) must be lines between two planar faces, no two of
//! them meeting at a vertex (corners where rounded edges meet would need
//! blends: the feature then falls back to the mesh). Each edge's corner is
//! cut off by a boolean: a prism along the edge whose section is the corner
//! between the faces' planes and the rolling ball's arc (a cylinder tangent
//! to both planes) - or the chamfer's line - set back from the edge by
//! r / tan(half the angle between the faces). A convex edge loses that
//! material (difference, the prism reaching past the edge's ends), a concave
//! one gains it (union, the prism exactly as long as the edge). In the
//! original's order of operations, bit for bit.
//!
//! Deliberate difference: an arc whose sweep is NaN (a degenerate corner)
//! makes the original loop for ever folding it into (-pi, pi]; here the
//! feature fails.
const std = @import("std");
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const bt = @import("btess.zig");
const bb = @import("bbuild.zig");
const bo = @import("bbool.zig");
const V3 = nb.V3;
const NONE = br.NONE;

const MAXFE = 64; // picked edges
const fl_pi: f64 = 3.14159265358979323846;
const fl_2pi: f64 = 6.28318530717958647692;
const fl_sharp: f64 = 0.9; // faces' normals closer: not an edge
const fl_vtol: f64 = 0.98; // vertical: dy^2 > 0.98 len^2
const fl_htol: f64 = 1.0e-4; // horizontal: dy^2 < 1e-4 len^2
const fl_ytol: f64 = 1.0e-4; // top / bottom: of the height
const fl_weld: f64 = 1.0e-7;
const fl_margin: f64 = 0.25;

/// A picked edge: its ends (P0 -> P1 as its first coedge walks it), its
/// faces' outward normals (face 1: that coedge's).
const Fe = struct { p0: V3, p1: V3, n1: V3, n2: V3 };

var fe_rec: [MAXFE]Fe = undefined;
var fe_n: u32 = 0;
var fl_body: u32 = 0;
var fl_sel: u32 = 0;
var fl_cham: bool = false;
var fl_r: f64 = 0;
var fl_ymin: f64 = 0;
var fl_ymax: f64 = 0;
var fl_size: f64 = 0;

/// bk_fillet(body, selector, chamfer, radius / distance) -> the new body, or NONE
pub fn fillet(body: u32, sel: u32, cham: bool, r: f64) u32 {
    fl_body = body;
    fl_sel = sel;
    fl_cham = cham;
    fl_r = r;
    fe_n = 0;
    fl_size = bt.bdSize(body);
    yRange();
    // the edges: each once (marks cleared, then set)
    eachCoedge(markClear);
    eachCoedge(pick);
    if (fe_n == 0) return fl_body;
    if (fe_n >= MAXFE) return NONE;
    if (sharedEnds()) return NONE; // rounded edges meeting: not simple
    var i: u32 = 0;
    while (i < fe_n) : (i += 1) {
        const t = cornerTool(i);
        if (t.body == NONE) return NONE;
        const nbd = bo.bool_(fl_body, t.body, t.op);
        if (nbd == NONE) return NONE;
        fl_body = nbd;
    }
    return fl_body;
}

/// body_coedges: every coedge of every face of fl_body (coedge, face)
fn eachCoedge(comptime f: fn (c: u32, face: u32) void) void {
    const b = br.bd(fl_body);
    var fi = b.first;
    const f1 = fi + b.nf;
    while (fi < f1) : (fi += 1) {
        var l = br.fc(fi).loop;
        const l1 = l + br.fc(fi).nloop;
        while (l < l1) : (l += 1) {
            var c = br.lp(l).first;
            const c1 = c + br.lp(l).n;
            while (c < c1) : (c += 1) f(c, fi);
        }
    }
}

fn markClear(c: u32, _: u32) void {
    br.ed(br.ce(c).edge).mark = 0;
}

/// y_range: fl_ymin / fl_ymax over the body's vertices
fn yRange() void {
    var big = fl_size * fl_size;
    big = big * fl_size;
    big = big + 1.0;
    fl_ymin = big;
    fl_ymax = nb.fneg(big);
    eachCoedge(yAdd);
}
fn yAdd(c: u32, _: u32) void {
    const y = br.vx(br.ed(br.ce(c).edge).v0).p[1];
    fl_ymin = nb.minsd(fl_ymin, y);
    fl_ymax = nb.maxsd(fl_ymax, y);
}

/// pick: the coedge's edge recorded when the selector takes it (once, from
/// its first coedge)
fn pick(c: u32, face: u32) void {
    const ei = br.ce(c).edge;
    const e = br.ed(ei);
    if (e.mark != 0) return;
    e.mark = 1;
    if (e.flags & br.EF_DEGEN != 0) return;
    if (br.cv(e.curve).typ != nb.CT_LINE) return;
    const p0 = br.vx(e.v0).p;
    const p1 = br.vx(e.v1).p;
    // the selector
    const d = nb.v3sub(p1, p0);
    const len2 = nb.v3dot(d, d);
    const sel = fl_sel;
    if (sel != 0) {
        if (sel < 3) {
            const dy2 = d[1] * d[1];
            if (sel == 1) {
                if (nb.jbe(dy2, len2 * fl_vtol)) return; // vertical
            } else if (nb.jae(dy2, len2 * fl_htol)) return; // horizontal
        } else {
            var tol = fl_ymax - fl_ymin;
            tol = tol * fl_ytol;
            if (sel == 3) {
                const y = nb.minsd(p0[1], p1[1]) + tol; // top: both ends at the top
                if (nb.jb(y, fl_ymax)) return;
            } else {
                const y = nb.maxsd(p0[1], p1[1]) - tol; // bottom
                if (nb.ja(y, fl_ymin)) return;
            }
        }
    }
    // its two faces: this coedge's and the other coedge's; both planes
    const n1 = faceNormal(face) orelse return;
    const of = otherFace(ei, face);
    if (of == NONE) return;
    const n2 = faceNormal(of) orelse return;
    if (nb.jae(nb.fabs(nb.v3dot(n1, n2)), fl_sharp)) return; // sharp enough
    if (fe_n < MAXFE) {
        // recorded: P0 -> P1 as this coedge walks it (its face is face 1)
        const rv = br.ce(c).rev != 0;
        fe_rec[fe_n] = .{ .p0 = if (rv) p1 else p0, .p1 = if (rv) p0 else p1, .n1 = n1, .n2 = n2 };
    }
    fe_n += 1;
}

/// face_normal: a plane's outward normal (null: not a plane)
fn faceNormal(fi: u32) ?V3 {
    const f = br.fc(fi);
    const s = br.sf(f.surf);
    if (s.typ != nb.ST_PLANE) return null;
    var n = s.z;
    if (f.sense != 0) n = .{ nb.fneg(n[0]), nb.fneg(n[1]), nb.fneg(n[2]) };
    return n;
}

var of_e: u32 = 0;
var of_f: u32 = 0;
var of_r: u32 = NONE;
/// other_face(edge, a face using it) -> the other face (the last met), or NONE
fn otherFace(e: u32, f: u32) u32 {
    of_e = e;
    of_f = f;
    of_r = NONE;
    eachCoedge(ofLook);
    return of_r;
}
fn ofLook(c: u32, face: u32) void {
    if (br.ce(c).edge != of_e) return;
    if (face == of_f) return;
    of_r = face;
}

/// shared_ends: two picked edges meet at a point
fn sharedEnds() bool {
    const tol = fl_size * fl_weld;
    var i: u32 = 0;
    while (i < fe_n) : (i += 1) {
        var j = i + 1;
        while (j < fe_n) : (j += 1) {
            // ends (a of i, b of j) all four ways
            for (0..4) |k| {
                const a = if (k & 1 != 0) fe_rec[i].p1 else fe_rec[i].p0;
                const b = if (k & 2 != 0) fe_rec[j].p1 else fe_rec[j].p0;
                if (nb.jbe(nb.v3dist(a, b), tol)) return true;
            }
        }
    }
    return false;
}

const Tool = struct { body: u32, op: u32 };

/// corner_tool(picked edge) -> the prism cutting (or filling) its corner,
/// and the boolean (difference: convex, union: concave)
fn cornerTool(i: u32) Tool {
    const r = &fe_rec[i];
    var w = nb.v3sub(r.p1, r.p0); // W = P1 - P0, L
    const len = nb.v3norm(&w);
    // into face 1: d1 = n1 x W (the face lies left of its coedge, which walks
    // P0 -> P1); into face 2: d2 = W x n2 (its coedge walks the other way)
    const d1 = nb.v3cross(r.n1, w);
    const d2 = nb.v3cross(w, r.n2);
    // convex: d1 . n2 < 0
    const cvx = nb.jb(nb.v3dot(d1, r.n2), 0);
    // setback s = r / tan(phi / 2), cos phi = d1 . d2
    const c = nb.v3dot(d1, d2);
    var t = 1.0 - c;
    t = t / (1.0 + c);
    t = @sqrt(t);
    const s = if (fl_cham) fl_r else fl_r / t;
    // the section's frame: O = P0, U = d1, V = W x U, W
    const v = nb.v3cross(w, d1);
    bb.bmSet(&.{ r.p0, d1, v, w });
    // the section: E (0, 0), T1 = s (1, 0), T2 = s (d2.U, d2.V)
    const t2: [2]f64 = .{ nb.v3dot(d2, d1) * s, nb.v3dot(d2, v) * s };
    var els: [3]bb.El = .{
        .{ .typ = bb.E_LINE, .a = .{ 0, 0 }, .b = .{ s, 0 } }, // E -> T1
        .{ .typ = bb.E_LINE, .a = .{ s, 0 }, .b = t2 }, // T1 -> T2: the arc or the chamfer
        .{ .typ = bb.E_LINE, .a = t2, .b = .{ 0, 0 } }, // T2 -> E
    };
    if (!fl_cham) {
        if (!arc(&els[1], r, v, cvx)) return .{ .body = NONE, .op = 0 };
    }
    bb.bpCustom(&els, s);
    // along the edge: convex past both ends, concave exactly its length
    var w0: f64 = 0;
    var w1 = len;
    if (cvx) {
        var mg = len * fl_margin;
        mg = mg + s;
        w0 = w0 - mg;
        w1 = w1 + mg;
    }
    return .{ .body = bb.bpPrism(w0, w1), .op = if (cvx) bo.OP_DIFF else bo.OP_UNION };
}

/// ct_arc: the rolling ball's arc from T1 to T2: centre (s, -r n1.V convex /
/// +r n1.V concave), the short way (false: its sweep is NaN)
fn arc(e: *bb.El, r: *const Fe, v: V3, cvx: bool) bool {
    e.typ = bb.E_ARC;
    var cy = nb.v3dot(r.n1, v) * fl_r;
    if (cvx) cy = nb.fneg(cy);
    e.c = .{ e.a[0], cy }; // (T1's u is the setback)
    e.r = fl_r;
    // angles of T1, T2 about the centre
    e.t0 = nb.datan2(e.a[1] - e.c[1], e.a[0] - e.c[0]);
    var sw = nb.datan2(e.b[1] - e.c[1], e.b[0] - e.c[0]);
    sw = sw - e.t0;
    if (std.math.isNan(sw)) return false;
    // the sweep into (-pi, pi]
    while (nb.ja(sw, fl_pi)) sw = sw - fl_2pi;
    while (!nb.ja(sw, nb.fneg(fl_pi))) sw = sw + fl_2pi;
    e.sw = sw;
    return true;
}

// ---- tests -------------------------------------------------------------------------------------
test "a box's vertical edges rounded: four cylinders, a smaller volume" {
    const T = std.testing;
    const sk = @import("sketch.zig");
    br.reset();
    @import("bssi.zig").reset();
    const b = sk.new(1).?; // XZ: the pad goes up (Y)
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 1 }, .{ 0, 1 } };
    var ids: [4]i32 = undefined;
    for (pts, 0..) |q, k| ids[k] = sk.addPoint(b, q[0], q[1]);
    for (0..4) |k| _ = sk.addLine(b, ids[k], ids[(k + 1) % 4]);
    const ident = [12]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };
    bb.bpPlace(b, &ident, null);
    try T.expect(bb.bpBuild(b) == 1);
    const box = bb.bpPrism(0, 0.5);
    try T.expect(box != NONE);
    const v0 = br.bdVolume(box);
    const out = fillet(box, 1, false, 0.1);
    try T.expect(out != NONE);
    var cyl: u32 = 0;
    var f = br.bd(out).first;
    while (f < br.bd(out).first + br.bd(out).nf) : (f += 1) {
        if (br.sf(br.fc(f).surf).typ == nb.ST_CYL) cyl += 1;
    }
    try T.expectEqual(@as(u32, 4), cyl);
    // each corner loses (1 - pi / 4) r^2 of its section
    const lost = 4.0 * (1.0 - std.math.pi / 4.0) * 0.01 * 0.5;
    try T.expectApproxEqAbs(v0 - lost, br.bdVolume(out), 1e-6);
    // every edge: rounded edges meet at the corners
    try T.expectEqual(NONE, fillet(box, 0, false, 0.1));
}
