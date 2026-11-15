//! step.s: STEP (ISO 10303-21) export of B-rep solids. file.export_step
//! writes every object with a B-rep solid (imported STEP parts; feature
//! bodies with cad.kernel on once the feature tree's kernel side is here) as
//! AP214 (AUTOMOTIVE_DESIGN): its vertices, edges (lines, circles, ellipses,
//! B-splines) and faces (planes, cylinders, cones, spheres, tori, B-spline
//! surfaces) as an advanced B-rep, its colour, its product. One solid is
//! written in place (its object's transform applied); several make an
//! assembly whose components are placed by their objects' transforms.
//! Lengths are in the scene's units, angles in radians. Reals carry 17
//! significant digits from the x87 (the original's packed-decimal store), so
//! the bytes are the original's and values come back to the last bit.
const std = @import("std");
const builtin = @import("builtin");
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const V3 = nb.V3;
const NONE = br.NONE;

const A = std.heap.page_allocator;

// ---- the text -------------------------------------------------------------------------------
var wb: std.ArrayList(u8) = .empty;
var wb_fail = false;

fn wbChar(c: u8) void {
    wb.append(A, c) catch {
        wb_fail = true;
    };
}
fn wbStr(s: []const u8) void {
    wb.appendSlice(A, s) catch {
        wb_fail = true;
    };
}
fn wbInt(v: i64) void {
    var b: [24]u8 = undefined;
    wbStr(std.fmt.bufPrint(&b, "{d}", .{v}) catch "0");
}

// fldlg2; fld qword [rdi]; fyl2x; fstp qword [rdi]; ret
export const bee_sx_x87_log10: [9]u8 linksection(".text") = .{ 0xd9, 0xec, 0xdd, 0x07, 0xd9, 0xf1, 0xdd, 0x1f, 0xc3 };
// 10^k (as pow10) times a, frndint; the double to [rdi], the integer to [rdi+8]
export const bee_sx_x87_scale: [44]u8 linksection(".text") = .{
    0xdb, 0x47, 0x08, // fild dword [rdi+8]
    0xd9, 0xe9, // fldl2t
    0xde, 0xc9, // fmulp
    0xd9, 0xc0, // fld st(0)
    0xd9, 0xfc, // frndint
    0xdc, 0xe9, // fsub st(1), st
    0xd9, 0xc9, // fxch
    0xd9, 0xf0, // f2xm1
    0xd9, 0xe8, // fld1
    0xde, 0xc1, // faddp
    0xd9, 0xfd, // fscale
    0xdd, 0xd9, // fstp st(1)
    0xdd, 0x07, // fld qword [rdi]
    0xde, 0xc9, // fmulp
    0xd9, 0xfc, // frndint
    0xd9, 0xc0, // fld st(0)
    0xdd, 0x1f, // fstp qword [rdi]
    0xdf, 0x7f, 0x08, // fistp qword [rdi+8]
    0xc3, 0x90, 0x90, 0x90, 0x90, 0x90,
};
const use_x87 = builtin.cpu.arch == .x86_64;
const Io = extern struct { a: f64, k: i64 };
fn run87(code: []const u8, io: *Io) void {
    const f: *const fn (*Io) callconv(.c) void = @ptrCast(code.ptr);
    f(io);
}
fn log10x(a: f64) f64 {
    if (!use_x87) return std.math.log10(a);
    var io: Io = .{ .a = a, .k = 0 };
    run87(&bee_sx_x87_log10, &io);
    return io.a;
}
/// round(a 10^k) in extended precision: as a double, and exactly
fn scaled(a: f64, k: i32) struct { d: f64, m: i64 } {
    if (!use_x87) {
        const x = @round(a * std.math.pow(f64, 10, @floatFromInt(k)));
        return .{ .d = x, .m = @intFromFloat(@min(@max(x, -9.0e18), 9.0e18)) };
    }
    var io: Io = .{ .a = a, .k = k };
    run87(&bee_sx_x87_scale, &io);
    return .{ .d = io.a, .m = io.k };
}

/// wb_real: a STEP real with 17 significant digits ("-1.2345678901234567E+02").
/// (Port: NaN and infinities, which the original looped on for ever, are "0.".)
pub fn wbReal(x: f64) void {
    if (x == 0 or !std.math.isFinite(x)) {
        wbStr("0.");
        return;
    }
    if (!(x >= 0)) wbChar('-');
    const a = nb.fabs(x);
    var e: i32 = nb.cvtr(@floor(log10x(a)));
    var r: @TypeOf(scaled(0, 0)) = undefined;
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        r = scaled(a, 16 -% e);
        if (tries > 8) break; // (port: bounded)
        if (!nb.jb(r.d, 1.0e17)) {
            e += 1;
            continue;
        }
        if (!nb.jae(r.d, 1.0e16)) {
            e -= 1;
            continue;
        }
        break;
    }
    // 18 packed digits; the first (16) .. 0
    var dg: [18]u8 = undefined;
    var m: u64 = @bitCast(r.m);
    if (r.m < 0) m = 0;
    for (&dg) |*d| {
        d.* = @intCast(m % 10);
        m /= 10;
    }
    wbChar('0' + dg[16]);
    wbChar('.');
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        wbChar('0' + dg[i]);
    }
    wbChar('E');
    var ex: u32 = undefined;
    if (e < 0) {
        wbChar('-');
        ex = @intCast(-e);
    } else {
        wbChar('+');
        ex = @intCast(e);
    }
    // (two digits: exponents < 100; the original writes what the division gives)
    wbChar(@truncate('0' + ex / 10));
    wbChar(@truncate('0' + ex % 10));
}

var sx_id: u32 = 1; // the next entity number
var sx_ctx: u32 = 0; // the geometric context
var sx_app: u32 = 0;
var sx_pc: u32 = 0;
var sx_pdc: u32 = 0;
var sx_vmap: []u32 = &.{}; // kernel vertex / edge -> entity
var sx_emap: []u32 = &.{};
var sx_mat: [4]V3 = undefined; // the transform applied (O, X, Y, Z)
var sx_hasm = false;

fn wId(n: u32) void {
    wbChar('#');
    wbInt(n);
}
/// w_begin -> a new entity number, "#n=" written
fn wBegin() u32 {
    const n = sx_id;
    sx_id += 1;
    wId(n);
    wbChar('=');
    return n;
}
fn wEnd() void {
    wbStr(");\n");
}
fn wEndParen() void {
    wbStr(";\n");
}
fn wComma() void {
    wbChar(',');
}
fn wBool(b: bool) void {
    wbStr(if (b) ".T." else ".F.");
}
/// "(#a,#b,...)"
fn wList(l: []const u32) void {
    wbChar('(');
    wListInner(l);
}
/// "#a,#b)" (the caller wrote the "(")
fn wListInner(l: []const u32) void {
    for (l, 0..) |id, i| {
        if (i != 0) wComma();
        wId(id);
    }
    wbChar(')');
}

// ---- geometry ---------------------------------------------------------------------------------
fn xf(p: V3, point: bool) V3 {
    if (!sx_hasm) return p;
    return nb.lin3(if (point) &sx_mat[0] else null, &sx_mat[1], p[0], &sx_mat[2], p[1], &sx_mat[3], p[2]);
}
fn wXyz(p: V3) void {
    wbReal(p[0]);
    wComma();
    wbReal(p[1]);
    wComma();
    wbReal(p[2]);
}
/// w_point -> a CARTESIAN_POINT
fn wPoint(p0: V3) u32 {
    const p = xf(p0, true);
    const n = wBegin();
    wbStr("CARTESIAN_POINT('',(");
    wXyz(p);
    wbStr(")");
    wEnd();
    return n;
}
/// w_direction -> a DIRECTION
fn wDirection(v0: V3) u32 {
    var v = xf(v0, false);
    _ = nb.v3norm(&v);
    const n = wBegin();
    wbStr("DIRECTION('',(");
    wXyz(v);
    wbStr(")");
    wEnd();
    return n;
}
/// w_axis(O, Z, X) -> an AXIS2_PLACEMENT_3D
fn wAxis(o: V3, z: V3, x: V3) u32 {
    const p = wPoint(o);
    const dz = wDirection(z);
    const dx = wDirection(x);
    const n = wBegin();
    wbStr("AXIS2_PLACEMENT_3D('',");
    wId(p);
    wComma();
    wId(dz);
    wComma();
    wId(dx);
    wEnd();
    return n;
}
/// w_frame_axis(O X Y) -> AXIS2_PLACEMENT_3D(O, X x Y, X)
fn wFrameAxis(o: V3, x: V3, y: V3) u32 {
    var z = nb.v3cross(x, y);
    _ = nb.v3norm(&z);
    return wAxis(o, z, x);
}

/// w_curve -> its entity
fn wCurve(ci: u32) u32 {
    const c = nb.cv(ci);
    switch (c.typ) {
        nb.CT_LINE => {
            const p = wPoint(c.o);
            const d = wDirection(c.x);
            const v = wBegin(); // VECTOR('', dir, 1.)
            wbStr("VECTOR('',");
            wId(d);
            wComma();
            wbReal(1.0);
            wEnd();
            const l = wBegin();
            wbStr("LINE('',");
            wId(p);
            wComma();
            wId(v);
            wEnd();
            return l;
        },
        nb.CT_NURBS => return wBsplineCurve(c),
        else => {
            const ax = wFrameAxis(c.o, c.x, c.y);
            const n = wBegin();
            wbStr(if (c.typ == nb.CT_CIRCLE) "CIRCLE(''," else "ELLIPSE('',");
            wId(ax);
            wComma();
            wbReal(c.r1);
            if (c.typ != nb.CT_CIRCLE) {
                wComma();
                wbReal(c.r2);
            }
            wEnd();
            return n;
        },
    }
}

/// rational_w: any weight is not 1
fn rationalW(cp: [*]const f64, n: usize) bool {
    for (0..n) |i| {
        if (!(cp[i * 4 + 3] == 1.0)) return true;
    }
    return false;
}

/// w_hpoint: a CARTESIAN_POINT (x / w ...)
fn wHpoint(q: [*]const f64) u32 {
    const w = q[3];
    return wPoint(.{ q[0] / w, q[1] / w, q[2] / w });
}

/// w_bspline_curve -> B_SPLINE_CURVE_WITH_KNOTS (rational: the complex entity)
fn wBsplineCurve(c: *const nb.Curve) u32 {
    const cp = c.cp.?;
    const rat = rationalW(cp, c.n);
    const pts = A.alloc(u32, c.n) catch {
        wb_fail = true;
        return 0;
    };
    defer A.free(pts);
    for (0..c.n) |i| pts[i] = wHpoint(cp + i * 4);
    const id = wBegin();
    const nk = c.n + c.deg + 1;
    if (!rat) {
        wbStr("B_SPLINE_CURVE_WITH_KNOTS('',");
        // "p,(pts),.UNSPECIFIED.,.F.,.F.,(mults),(knots),.UNSPECIFIED."
        wbInt(c.deg);
        wComma();
        wList(pts);
        wComma();
        wbStr(".UNSPECIFIED.");
        wComma();
        wbStr(".F.,.F.");
        wComma();
        wKnots(c.kn.?, nk);
        wComma();
        wbStr(".UNSPECIFIED.");
        wEnd();
        return id;
    }
    wbStr("(BOUNDED_CURVE() B_SPLINE_CURVE(");
    wbInt(c.deg);
    wComma();
    wList(pts);
    wComma();
    wbStr(".UNSPECIFIED.");
    wComma();
    wbStr(".F.,.F.");
    wbStr(") B_SPLINE_CURVE_WITH_KNOTS(");
    wKnots(c.kn.?, nk);
    wComma();
    wbStr(".UNSPECIFIED.");
    wbStr(") CURVE() GEOMETRIC_REPRESENTATION_ITEM() RATIONAL_B_SPLINE_CURVE((");
    wWeights(cp, c.n);
    wbStr(")) REPRESENTATION_ITEM('')");
    wEnd();
    return id;
}

/// w_knots: "(m1,m2,...),(k1,k2,...)": multiplicities of the distinct values, then the values
fn wKnots(k: [*]const f64, n: u32) void {
    wbChar('(');
    var i: u32 = 0;
    while (i < n) {
        var m: u32 = 1;
        while (i + m < n and k[i + m] == k[i]) m += 1;
        if (i != 0) wComma();
        wbInt(m);
        i += m;
    }
    wbStr(")");
    wComma();
    wbChar('(');
    i = 0;
    while (i < n) {
        if (i != 0) wComma();
        wbReal(k[i]);
        var m: u32 = 1;
        while (i + m < n and k[i + m] == k[i]) m += 1;
        i += m;
    }
    wbStr(")");
}

/// w_weights: "w1,w2,..."
fn wWeights(cp: [*]const f64, n: usize) void {
    for (0..n) |i| {
        if (i != 0) wComma();
        wbReal(cp[i * 4 + 3]);
    }
}

/// w_surface -> its entity
fn wSurface(si: u32) u32 {
    const s = nb.sf(si);
    if (s.typ == nb.ST_NURBS) return wBsplineSurface(s);
    const ax = wAxis(s.o, s.z, s.x); // placement: O, Z, X
    const n = wBegin();
    wbStr(switch (s.typ) {
        nb.ST_PLANE => "PLANE('',",
        nb.ST_CYL => "CYLINDRICAL_SURFACE('',",
        nb.ST_CONE => "CONICAL_SURFACE('',",
        nb.ST_SPHERE => "SPHERICAL_SURFACE('',",
        else => "TOROIDAL_SURFACE('',",
    });
    wId(ax);
    if (s.typ != nb.ST_PLANE) {
        wComma(); // radius (and minor radius / angle)
        wbReal(s.r1);
        if (s.typ == nb.ST_CONE or s.typ == nb.ST_TORUS) {
            wComma();
            wbReal(s.r2);
        }
    }
    wEnd();
    return n;
}

/// w_bspline_surface -> B_SPLINE_SURFACE_WITH_KNOTS (or the rational complex
/// entity); control points as u rows of v lists
fn wBsplineSurface(s: *const nb.Surface) u32 {
    const cnt: usize = @as(usize, s.nu) * s.nv;
    const cp = s.cp.?;
    const rat = rationalW(cp, cnt);
    const pts = A.alloc(u32, cnt) catch {
        wb_fail = true;
        return 0;
    };
    defer A.free(pts);
    for (0..cnt) |i| pts[i] = wHpoint(cp + i * 4);
    const id = wBegin();
    if (!rat) {
        wbStr("B_SPLINE_SURFACE_WITH_KNOTS('',");
        bsHead(s, pts);
        wComma();
        bsKnots(s);
        wComma();
        wbStr(".UNSPECIFIED.");
        wEnd();
        return id;
    }
    wbStr("(BOUNDED_SURFACE() B_SPLINE_SURFACE(");
    bsHead(s, pts);
    wbStr(") B_SPLINE_SURFACE_WITH_KNOTS(");
    bsKnots(s);
    wComma();
    wbStr(".UNSPECIFIED.");
    wbStr(") GEOMETRIC_REPRESENTATION_ITEM() RATIONAL_B_SPLINE_SURFACE((");
    var i: u32 = 0;
    while (i < s.nu) : (i += 1) {
        if (i != 0) wComma();
        wbChar('(');
        wWeights(cp + i * s.nv * 4, s.nv);
        wbChar(')');
    }
    wbStr(")) REPRESENTATION_ITEM('') SURFACE()");
    wEnd();
    return id;
}
/// bs_head: "du,dv,((pts)...),.UNSPECIFIED.,.F.,.F.,.F."
fn bsHead(s: *const nb.Surface, pts: []const u32) void {
    wbInt(s.du);
    wComma();
    wbInt(s.dv);
    wComma();
    wbChar('(');
    var i: u32 = 0;
    while (i < s.nu) : (i += 1) {
        if (i != 0) wComma();
        wList(pts[i * s.nv .. (i + 1) * s.nv]);
    }
    wbChar(')');
    wComma();
    wbStr(".UNSPECIFIED.");
    wComma();
    wbStr(".F.,.F.,.F.");
}
/// bs_knots: "(umults),(vmults),(uknots),(vknots)" (written u then v, then
/// interleaved, as the original)
fn bsKnots(s: *const nb.Surface) void {
    const ub0 = wb.items.len;
    wKnots(s.ku.?, s.nu + s.du + 1);
    const ue = wb.items.len;
    wKnots(s.kv.?, s.nv + s.dv + 1);
    if (wb_fail) return;
    const t = wb.items;
    const us = (std.mem.indexOfScalarPos(u8, t, ub0, ')') orelse return) + 1;
    const vs = (std.mem.indexOfScalarPos(u8, t, ue, ')') orelse return) + 1;
    const all = A.dupe(u8, t[ub0..]) catch {
        wb_fail = true;
        return;
    };
    defer A.free(all);
    wb.shrinkRetainingCapacity(ub0);
    wbStr(all[0 .. us - ub0]); // um
    wbChar(',');
    wbStr(all[ue - ub0 .. vs - ub0]); // vm
    wbChar(',');
    wbStr(all[us + 1 - ub0 .. ue - ub0]); // uk
    wbChar(',');
    wbStr(all[vs + 1 - ub0 ..]); // vk
}

// ---- topology ---------------------------------------------------------------------------------
/// w_vertex -> its VERTEX_POINT (once)
fn wVertex(v: u32) u32 {
    if (v < sx_vmap.len and sx_vmap[v] != 0) return sx_vmap[v];
    const p = wPoint(br.vx(v).p);
    const n = wBegin();
    if (v < sx_vmap.len) sx_vmap[v] = n;
    wbStr("VERTEX_POINT('',");
    wId(p);
    wEnd();
    return n;
}

/// w_edge -> its EDGE_CURVE (once)
fn wEdge(ei: u32) u32 {
    if (ei < sx_emap.len and sx_emap[ei] != 0) return sx_emap[ei];
    const e = br.ed(ei);
    const a = wVertex(e.v0);
    const b = wVertex(e.v1);
    const c = wCurve(e.curve);
    const n = wBegin();
    if (ei < sx_emap.len) sx_emap[ei] = n;
    wbStr("EDGE_CURVE('',");
    wId(a);
    wComma();
    wId(b);
    wComma();
    wId(c);
    wComma();
    wBool(e.t1 > e.t0); // the curve's way: t1 > t0
    wEnd();
    return n;
}

/// w_face -> its ADVANCED_FACE
fn wFace(fi: u32) u32 {
    const f = br.fc(fi);
    var bounds: std.ArrayList(u32) = .empty;
    defer bounds.deinit(A);
    var oes: std.ArrayList(u32) = .empty;
    defer oes.deinit(A);
    var l = f.loop;
    const l1 = l + f.nloop;
    while (l < l1) : (l += 1) {
        oes.clearRetainingCapacity();
        var c = br.lp(l).first;
        const end = c + br.lp(l).n;
        while (c < end) : (c += 1) {
            const r = br.ce(c);
            if (br.ed(r.edge).flags & br.EF_DEGEN != 0) continue; // (poles: STEP has none)
            const e = wEdge(r.edge);
            const n = wBegin();
            oes.append(A, n) catch {
                wb_fail = true;
            };
            wbStr("ORIENTED_EDGE('',*,*,");
            wId(e);
            wComma();
            wBool(r.rev ^ 1 != 0);
            wEnd();
        }
        if (oes.items.len == 0) continue;
        const lid = wBegin(); // EDGE_LOOP
        wbStr("EDGE_LOOP('',(");
        wListInner(oes.items);
        wEnd();
        const b = wBegin(); // its bound (the first: outer)
        bounds.append(A, b) catch {
            wb_fail = true;
        };
        wbStr(if (l == f.loop) "FACE_OUTER_BOUND(''," else "FACE_BOUND('',");
        wId(lid);
        wComma();
        wBool(true);
        wEnd();
    }
    const s = wSurface(f.surf);
    const id = wBegin();
    wbStr("ADVANCED_FACE('',(");
    wListInner(bounds.items);
    wComma();
    wId(s);
    wComma();
    wBool(f.sense ^ 1 != 0);
    wEnd();
    return id;
}

/// w_name: the name in a STEP string (quotes doubled)
fn wName(s: []const u8) void {
    for (s) |c| {
        if (c == 0) break;
        if (c == 0x27) wbChar(0x27);
        wbChar(c);
    }
}

/// w_solid(body, name) -> its MANIFOLD_SOLID_BREP
fn wSolid(b: u32, name: []const u8) u32 {
    const body = br.bd(b);
    const faces = A.alloc(u32, body.nf) catch {
        wb_fail = true;
        return 0;
    };
    defer A.free(faces);
    for (0..body.nf) |k| faces[k] = wFace(body.first + @as(u32, @intCast(k)));
    const sh = wBegin();
    wbStr("CLOSED_SHELL('',(");
    wListInner(faces);
    wEnd();
    const n = wBegin();
    wbStr("MANIFOLD_SOLID_BREP('");
    wName(name);
    wbStr("',");
    wId(sh);
    wEnd();
    return n;
}

// ---- the file -------------------------------------------------------------------------------
/// w_context -> sx_ctx: units (the scene's length unit, radians, steradians) and the uncertainty
fn wContext() void {
    const mm = @import("cad.zig").unitMm();
    var len = wBegin(); // the length unit
    if (nb.je(mm, 25.4)) {
        // (the mm unit first, then the inch)
        wbStr("(LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(");
        wbStr(".MILLI.,.METRE.))");
        wEndParen();
        const dim = wBegin(); // dimensional exponents
        wbStr("DIMENSIONAL_EXPONENTS(1.,0.,0.,0.,0.,0.,0.)");
        wEndParen();
        const lm = wBegin(); // 25.4 mm
        wbStr("LENGTH_MEASURE_WITH_UNIT(LENGTH_MEASURE(25.4),");
        wId(len);
        wEnd();
        len = wBegin();
        wbStr("(CONVERSION_BASED_UNIT('INCH',");
        wId(lm);
        wbStr(") LENGTH_UNIT() NAMED_UNIT(");
        wId(dim);
        wbStr("))");
        wEndParen();
    } else {
        wbStr("(LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(");
        if (nb.je(mm, 1.0)) {
            wbStr(".MILLI.,.METRE.))");
        } else if (nb.je(mm, 10.0)) {
            wbStr(".CENTI.,.METRE.))");
        } else wbStr("$,.METRE.))");
        wEndParen();
    }
    const rad = wBegin();
    wbStr("(NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.))");
    wEndParen();
    const sr = wBegin();
    wbStr("(NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT())");
    wEndParen();
    const unc = wBegin(); // uncertainty
    wbStr("UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),");
    wId(len);
    wbStr(",'distance_accuracy_value','confusion accuracy')");
    wEndParen();
    sx_ctx = wBegin();
    wbStr("(GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#");
    wbInt(unc);
    wbStr(")) GLOBAL_UNIT_ASSIGNED_CONTEXT((#");
    wbInt(len);
    wComma();
    wId(rad);
    wComma();
    wId(sr);
    wbStr(")) REPRESENTATION_CONTEXT('Context3D','3D Context with UNIT and UNCERTAINTY'))");
    wEndParen();
}

/// w_product(name) -> the PRODUCT_DEFINITION and its PRODUCT_DEFINITION_SHAPE
fn wProduct(name: []const u8) [2]u32 {
    const prod = wBegin();
    wbStr("PRODUCT('");
    wName(name);
    wbStr("','");
    wName(name);
    wbStr("','',(");
    wId(sx_pc);
    wbChar(')');
    wEnd();
    _ = wBegin(); // its category
    wbStr("PRODUCT_RELATED_PRODUCT_CATEGORY('part',$,(");
    wId(prod);
    wbChar(')');
    wEnd();
    const pdf = wBegin(); // formation
    wbStr("PRODUCT_DEFINITION_FORMATION('','',");
    wId(prod);
    wEnd();
    const pd = wBegin(); // definition
    wbStr("PRODUCT_DEFINITION('design','',");
    wId(pdf);
    wComma();
    wId(sx_pdc);
    wEnd();
    const pds = wBegin(); // its shape
    wbStr("PRODUCT_DEFINITION_SHAPE('','',");
    wId(pd);
    wEnd();
    return .{ pd, pds };
}

/// w_colour(styled item, 0xRRGGBB) -> the STYLED_ITEM
fn wColour(item: u32, rgb: u32) u32 {
    const c = wBegin();
    wbStr("COLOUR_RGB('',");
    var sh: i32 = 16; // r, g, b in 0 .. 1
    while (true) {
        const v: f64 = @floatFromInt((rgb >> @intCast(sh)) & 255);
        wbReal(v / 255.0);
        sh -= 8;
        if (sh < 0) break;
        wComma();
    }
    wEnd();
    var r = wChain("FILL_AREA_STYLE_COLOUR('',", c, false);
    r = wChain("FILL_AREA_STYLE('',(", r, true);
    r = wChain("SURFACE_STYLE_FILL_AREA(", r, false);
    r = wChain("SURFACE_SIDE_STYLE('',(", r, true);
    r = wChain("SURFACE_STYLE_USAGE(.BOTH.,", r, false);
    r = wChain("PRESENTATION_STYLE_ASSIGNMENT((", r, true);
    const n = wBegin(); // STYLED_ITEM('color', (psa), item)
    wbStr("STYLED_ITEM('color',(");
    wId(r);
    wbChar(')');
    wComma();
    wId(item);
    wEnd();
    return n;
}
/// w_chain: "#n=text#ref);" (list: "#n=text#ref));")
fn wChain(text: []const u8, ref: u32, list: bool) u32 {
    const n = wBegin();
    wbStr(text);
    wId(ref);
    if (list) wbChar(')');
    wEnd();
    return n;
}

/// w_identity -> AXIS2_PLACEMENT_3D at the origin (untransformed)
fn wIdentity() u32 {
    const keep = sx_hasm;
    sx_hasm = false;
    const n = wAxis(.{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 0 });
    sx_hasm = keep;
    return n;
}

/// obj_frame(object index): sx_mat: its transform (O, X, Y, Z: the matrix's
/// translation and columns, as doubles)
fn objFrame(i: usize) void {
    const mt = @import("measure.zig").objMatrix(i);
    for (0..3) |r| {
        sx_mat[0][r] = mt[r * 4 + 3];
        for (0..3) |c| sx_mat[c + 1][r] = mt[r * 4 + c];
    }
}

/// The object's B-rep solid (bf_body): an imported STEP part's, or a feature body's.
pub var bodyOf: *const fn (oid: u32) u32 = defaultBodyOf;
fn defaultBodyOf(oid: u32) u32 {
    return @import("stepread.zig").stBody(oid);
}

const MAXSO = 256;
pub const Result = enum { ok, none, cannot_write };

/// step_export(path): the file's bytes written atomically
pub fn stepExport(path: []const u8) Result {
    const scene = @import("scene.zig");
    // the solids: objects with B-rep bodies
    var objs: [MAXSO]usize = undefined;
    var bodies: [MAXSO]u32 = undefined;
    var n: usize = 0;
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        const b = bodyOf(o.oid);
        if (b == NONE) continue;
        if (n >= MAXSO) continue;
        bodies[n] = b;
        objs[n] = i;
        n += 1;
    }
    if (n == 0) return .none;
    // maps: kernel vertex / edge -> entity
    const vm = A.alloc(u32, (br.bk_vx.used >> 5) + 4) catch return .cannot_write;
    defer A.free(vm);
    @memset(vm, 0);
    const em = A.alloc(u32, (br.bk_ed.used >> 6) + 4) catch return .cannot_write;
    defer A.free(em);
    @memset(em, 0);
    sx_vmap = vm;
    sx_emap = em;
    // header
    wb.clearRetainingCapacity();
    wb_fail = false;
    sx_id = 1;
    sx_hasm = false;
    wbStr("ISO-10303-21;\nHEADER;\nFILE_DESCRIPTION(('BeeModel B-rep'),'2;1');\nFILE_NAME('");
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
    wName(base);
    wbStr("','2026-10-14T00:00:00',(''),(''),'BeeModel','BeeModel','');\nFILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));\nENDSEC;\nDATA;\n");
    // contexts
    sx_app = wBegin();
    wbStr("APPLICATION_CONTEXT('automotive design')");
    wEndParen();
    _ = wBegin();
    wbStr("APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,");
    wId(sx_app);
    wEnd();
    sx_pc = wBegin();
    wbStr("PRODUCT_CONTEXT('',");
    wId(sx_app);
    wbStr(",'mechanical')");
    wEndParen();
    sx_pdc = wBegin();
    wbStr("PRODUCT_DEFINITION_CONTEXT('part definition',");
    wId(sx_app);
    wbStr(",'design')");
    wEndParen();
    wContext();
    // each solid: geometry (one alone: its object's transform applied), its
    // representation, product, colour
    var reps: [MAXSO]u32 = undefined;
    var pds: [MAXSO]u32 = undefined;
    for (0..n) |k| {
        const o = &scene.objects[objs[k]];
        sx_hasm = false;
        if (n == 1) {
            objFrame(objs[k]);
            sx_hasm = true;
        }
        const msb = wSolid(bodies[k], o.name());
        sx_hasm = false;
        const ax = wIdentity();
        const rep = wBegin(); // ABSR('', (solid, axis), context)
        reps[k] = rep;
        wbStr("ADVANCED_BREP_SHAPE_REPRESENTATION('',(");
        wId(msb);
        wComma();
        wId(ax);
        wbChar(')');
        wComma();
        wId(sx_ctx);
        wEnd();
        const pp = wProduct(o.name());
        pds[k] = pp[0];
        _ = wBegin(); // SHAPE_DEFINITION_REPRESENTATION
        wbStr("SHAPE_DEFINITION_REPRESENTATION(");
        wId(pp[1]);
        wComma();
        wId(rep);
        wEnd();
        const st = wColour(msb, o.color & 0xffffff); // its colour
        _ = wBegin(); // MDGPR('', (styled), context)
        wbStr("MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION('',(");
        wId(st);
        wbChar(')');
        wComma();
        wId(sx_ctx);
        wEnd();
    }
    if (n > 1) {
        // the assembly: its representation lists a placement per component
        const top = wProduct("Assembly");
        var pl: [MAXSO + 1]u32 = undefined; // placements: identity + one each
        pl[0] = wIdentity();
        for (0..n) |k| {
            objFrame(objs[k]);
            var z = nb.v3scale(sx_mat[3], 1.0); // its frame: O, Z, X (unit)
            _ = nb.v3norm(&z);
            var x = nb.v3scale(sx_mat[1], 1.0);
            _ = nb.v3norm(&x);
            pl[k + 1] = wAxis(sx_mat[0], z, x);
        }
        const topr = wBegin();
        wbStr("SHAPE_REPRESENTATION('',(");
        wListInner(pl[0 .. n + 1]);
        wComma();
        wId(sx_ctx);
        wEnd();
        _ = wBegin();
        wbStr("SHAPE_DEFINITION_REPRESENTATION(");
        wId(top[1]);
        wComma();
        wId(topr);
        wEnd();
        for (0..n) |k| {
            // each component's occurrence
            const nauo = wBegin();
            wbStr("NEXT_ASSEMBLY_USAGE_OCCURRENCE('");
            wbInt(@intCast(k + 1));
            wbStr("','','',");
            wId(top[0]);
            wComma();
            wId(pds[k]);
            wbStr(",$)");
            wEndParen();
            const shp = wBegin(); // its shape
            wbStr("PRODUCT_DEFINITION_SHAPE('','',");
            wId(nauo);
            wEnd();
            const idt = wBegin(); // ITEM_DEFINED_TRANSFORMATION
            wbStr("ITEM_DEFINED_TRANSFORMATION('','',");
            wId(pl[0]); // from the component's origin
            wComma();
            wId(pl[k + 1]); // to its placement
            wEnd();
            const rr = wBegin(); // the relationship (complex)
            wbStr("(REPRESENTATION_RELATIONSHIP('','',");
            wId(reps[k]);
            wComma();
            wId(topr);
            wbStr(") REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION(");
            wId(idt);
            wbStr(") SHAPE_REPRESENTATION_RELATIONSHIP())");
            wEndParen();
            _ = wBegin(); // CDSR
            wbStr("CONTEXT_DEPENDENT_SHAPE_REPRESENTATION(");
            wId(rr);
            wComma();
            wId(shp);
            wEnd();
        }
    }
    wbStr("ENDSEC;\nEND-ISO-10303-21;\n");
    sx_vmap = &.{};
    sx_emap = &.{};
    if (wb_fail) return .cannot_write;
    @import("bee.zig").writeAtomic(path, wb.items) catch return .cannot_write;
    return .ok;
}

test "reals: 17 digits as the original writes them" {
    const T = std.testing;
    wb.clearRetainingCapacity();
    wbReal(1.0);
    try T.expectEqualStrings("1.0000000000000000E+00", wb.items);
    wb.clearRetainingCapacity();
    wbReal(-0.5);
    try T.expectEqualStrings("-5.0000000000000000E-01", wb.items);
    wb.clearRetainingCapacity();
    wbReal(0);
    try T.expectEqualStrings("0.", wb.items);
    wb.clearRetainingCapacity();
    wbReal(0.1);
    try T.expectEqualStrings("1.0000000000000001E-01", wb.items);
}

test "step compiles" {
    std.testing.refAllDecls(@This());
}
