//! stepread.s: STEP (ISO 10303-21) import, the Part 21 parser and the B-rep
//! builder. The DATA section is parsed into entity instances (#n = TYPE(...)
//! or a complex (A(...) B(...))) whose parameters are nodes: integers, reals,
//! strings, enumerations, references, lists, $, *, typed values. Every
//! MANIFOLD_SOLID_BREP becomes a kernel body: its faces (planes, cylinders,
//! cones, spheres, tori, B-spline surfaces, rational or not) bounded by loops
//! of edges (lines, circles, ellipses, B-splines; surface and seam curves
//! through their 3D curve), in the file's length unit converted to the
//! scene's. Faces that wrap round get pcurves that continue round; poles
//! (which STEP leaves out) get degenerate edges, and a face bounded by
//! meridians alone takes the side of the turn its loop's direction says.
//! Assemblies place each solid by the transforms of its occurrences; colours
//! come from styled items. Each solid instance becomes a mesh object (its
//! tessellation) whose B-rep step.zig sees; the file's text is kept so the
//! solids are built again after the kernel's next reset (stRebuild).
//!
//! Reals are read as the original reads them (the mantissa times 10^e on the
//! x87), so values agree to the bit. Damaged input never crashes or hangs
//! here (deliberate differences from the original, which recursed without a
//! bound on cycles and deep nesting, wrote past its maps on huge ids and
//! looped for ever on NaN angles): nesting deeper than MAXDEPTH, reference
//! chains longer than MAXCHAIN, ids beyond the map's room and runaway loops
//! are cut short instead.
const std = @import("std");
const builtin = @import("builtin");
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const bt = @import("btess.zig");
const V3 = nb.V3;
const jb = nb.jb;
const ja = nb.ja;
const jae = nb.jae;
const jbe = nb.jbe;
const maxsd = nb.maxsd;
const minsd = nb.minsd;
const fabs = nb.fabs;
const fneg = nb.fneg;
const fl = nb.fl;
const NONE = br.NONE;

// node kinds
const K_INT = 1;
const K_REAL = 2;
const K_STR = 3;
const K_ENUM = 4;
const K_REF = 5;
const K_LIST = 6;
const K_NULL = 7;
const K_DERIV = 8;
const K_TYPED = 9;

const Node = extern struct { kind: u32, n: u32, v: u64 };
const Ent = extern struct { id: u32, code: u32, node: u32, aux: u32 };

// type codes
const T_POINT = 1;
const T_DIR = 2;
const T_VECTOR = 3;
const T_AXIS = 4;
const T_LINE = 5;
const T_CIRCLE = 6;
const T_ELLIPSE = 7;
const T_BSC = 8;
const T_SCURVE = 9;
const T_SEAM = 10;
const T_PLANE = 11;
const T_CYL = 12;
const T_CONE = 13;
const T_SPHERE = 14;
const T_TORUS = 15;
const T_BSS = 16;
const T_VERTEX = 17;
const T_EDGE = 18;
const T_OEDGE = 19;
const T_ELOOP = 20;
const T_FBOUND = 21;
const T_FOBOUND = 22;
const T_AFACE = 23;
const T_CSHELL = 24;
const T_MSB = 25;
const T_ABSR = 26;
const T_SR = 27;
const T_SDR = 28;
const T_PDS = 29;
const T_PD = 30;
const T_PDF = 31;
const T_PRODUCT = 32;
const T_NAUO = 33;
const T_CDSR = 34;
const T_IDT = 35;
const T_SRR = 36;
const T_STYLED = 37;
const T_PSA = 38;
const T_SSU = 39;
const T_SSS = 40;
const T_SSFA = 41;
const T_FAS = 42;
const T_FASC = 43;
const T_RGB = 44;
const T_TRIM = 45;
const T_POLY = 46;
const T_VLOOP = 47;
const T_BWV = 48;
const T_FSURF = 49;
const T_ORSI = 50;
const T_MSSR = 51;
const T_MDGPR = 52;
const T_LENU = 60;
const T_SIU = 61;
const T_CBU = 62;
const T_PAU = 63;
const T_BSC0 = 64;
const T_RBSC = 65;
const T_BSS0 = 66;
const T_RBSS = 67;
const T_RR = 68;
const T_RRWT = 69;
const T_LMWU = 70;
const T_LM = 71;
const T_PAM = 72;
const T_PAMWU = 73;
const T_GUAC = 74;
const T_COMPLEX = 99;

const tn_table = [_]?[]const u8{
    "CARTESIAN_POINT",                    "DIRECTION",                         "VECTOR",                 "AXIS2_PLACEMENT_3D",
    "LINE",                               "CIRCLE",                            "ELLIPSE",                "B_SPLINE_CURVE_WITH_KNOTS",
    "SURFACE_CURVE",                      "SEAM_CURVE",                        "PLANE",                  "CYLINDRICAL_SURFACE",
    "CONICAL_SURFACE",                    "SPHERICAL_SURFACE",                 "TOROIDAL_SURFACE",       "B_SPLINE_SURFACE_WITH_KNOTS",
    "VERTEX_POINT",                       "EDGE_CURVE",                        "ORIENTED_EDGE",          "EDGE_LOOP",
    "FACE_BOUND",                         "FACE_OUTER_BOUND",                  "ADVANCED_FACE",          "CLOSED_SHELL",
    "MANIFOLD_SOLID_BREP",                "ADVANCED_BREP_SHAPE_REPRESENTATION", "SHAPE_REPRESENTATION",  "SHAPE_DEFINITION_REPRESENTATION",
    "PRODUCT_DEFINITION_SHAPE",           "PRODUCT_DEFINITION",                "PRODUCT_DEFINITION_FORMATION", "PRODUCT",
    "NEXT_ASSEMBLY_USAGE_OCCURRENCE",     "CONTEXT_DEPENDENT_SHAPE_REPRESENTATION", "ITEM_DEFINED_TRANSFORMATION", "SHAPE_REPRESENTATION_RELATIONSHIP",
    "STYLED_ITEM",                        "PRESENTATION_STYLE_ASSIGNMENT",     "SURFACE_STYLE_USAGE",    "SURFACE_SIDE_STYLE",
    "SURFACE_STYLE_FILL_AREA",            "FILL_AREA_STYLE",                   "FILL_AREA_STYLE_COLOUR", "COLOUR_RGB",
    "TRIMMED_CURVE",                      "POLYLINE",                          "VERTEX_LOOP",            "BREP_WITH_VOIDS",
    "FACE_SURFACE",                       "OVER_RIDING_STYLED_ITEM",           "MANIFOLD_SURFACE_SHAPE_REPRESENTATION", "MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION",
    null,                                 null,                                null,                     null,
    null,                                 null,                                null,                     "LENGTH_UNIT",
    "SI_UNIT",                            "CONVERSION_BASED_UNIT",             "PLANE_ANGLE_UNIT",       "B_SPLINE_CURVE",
    "RATIONAL_B_SPLINE_CURVE",            "B_SPLINE_SURFACE",                  "RATIONAL_B_SPLINE_SURFACE", "REPRESENTATION_RELATIONSHIP",
    "REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION", "LENGTH_MEASURE_WITH_UNIT", "LENGTH_MEASURE", "PLANE_ANGLE_MEASURE",
    "PLANE_ANGLE_MEASURE_WITH_UNIT",      "GLOBAL_UNIT_ASSIGNED_CONTEXT",
};

const PSTACK = 1048576; // children waiting for their list
pub const MAXIMP = 16; // imported files kept
pub const MAXIS = 1024; // their solid instances
/// (port) nesting of lists and typed values beyond this is skipped
const MAXDEPTH = 256;
/// (port) chains of references followed (vectors, surface curves)
const MAXCHAIN = 64;
/// (port) the id map's room (larger ids: a sorted search instead)
const MAXMAP = 1 << 26;

const sr_2pi: f64 = 6.28318530717958647692;
const sr_tiny: f64 = 1.0e-12;
const fw_iso: f64 = 1.0e-9;
const fw_neg: f64 = -1.0e-9;
const pe_tol: f64 = 1.0e-16;
const sr_z: V3 = .{ 0, 0, 1 };
const sr_x: V3 = .{ 1, 0, 0 };
const sr_y: V3 = .{ 0, 1, 0 };

// ---- the parse --------------------------------------------------------------------------
var sp_text: []const u8 = "";
var sp_cur: usize = 0;
var sp_nodes: [*]Node = undefined;
var sp_nn: u32 = 0;
var sp_ncap: u32 = 0;
var sp_kids: [*]u32 = undefined;
var sp_nk: u32 = 0;
var sp_kcap: u32 = 0;
var sp_ents: [*]Ent = undefined;
var sp_ne: u32 = 0;
var sp_ecap: u32 = 0;
var sp_map: ?[*]u32 = null; // id -> entity index + 1
var sp_sorted: [*]u64 = undefined; // (port) (id << 32 | index) when the ids are too large for the map
var sp_maxid: u32 = 0;
var sp_stack: [*]u32 = undefined;
var sp_sn: u32 = 0;
var sp_bad: bool = false;
var sp_depth: u32 = 0;

// the build
var sb_len: f64 = 1; // scene units per file length unit
var sb_ang: f64 = 1; // radians per file angle unit

// imports kept (rebuilt after the kernel's resets)
pub var st_nimp: u32 = 0;
var st_text: [MAXIMP][]u8 = undefined;
pub var st_nis: u32 = 0; // solid instances
pub var st_uid: [MAXIS]u32 = undefined; // object, import, solid entity, body
var st_imp: [MAXIS]u32 = undefined;
var st_msb: [MAXIS]u32 = undefined;
pub var st_bd: [MAXIS]u32 = undefined;

/// The text past its end reads as zeros (the original's mapping does).
inline fn ch(i: usize) u8 {
    return if (i < sp_text.len) sp_text[i] else 0;
}

/// p_ws: blanks and comments skipped
fn pWs() void {
    var i = sp_cur;
    const end = sp_text.len;
    while (i < end) {
        const c = sp_text[i];
        if (c <= ' ') {
            i += 1;
            continue;
        }
        if (c != '/' or ch(i + 1) != '*') break;
        i += 2; // /* ... */
        while (true) {
            if (i >= end) break;
            if (sp_text[i] == '*' and ch(i + 1) == '/') {
                i += 2;
                break;
            }
            i += 1;
        }
    }
    sp_cur = i;
}

/// p_peek -> the next character (blanks skipped), or -1
fn pPeek() i32 {
    pWs();
    if (sp_cur >= sp_text.len) return -1;
    return sp_text[sp_cur];
}

/// node_new(kind) -> a new node (full: the last again)
fn nodeNew(kind: u32) u32 {
    var i = sp_nn;
    if (i >= sp_ncap) {
        sp_bad = true;
        i -%= 1;
    } else sp_nn += 1;
    const n = &sp_nodes[i];
    n.kind = kind;
    n.n = 0;
    n.v = 0;
    return i;
}

/// p_word -> start and length of a keyword (A-Z, 0-9, _, a-z)
fn pWord() []const u8 {
    pWs();
    const a = sp_cur;
    var i = a;
    while (i < sp_text.len) : (i += 1) {
        const c = sp_text[i];
        const ok = c == '_' or (c >= '0' and c <= '9') or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
        if (!ok) break;
    }
    sp_cur = i;
    return sp_text[a..i];
}

/// type_code(word) -> its code (0: unknown)
fn typeCode(w: []const u8) u32 {
    for (tn_table, 0..) |t, k| {
        const s = t orelse continue;
        if (std.mem.eql(u8, s, w)) return @intCast(k + 1);
    }
    return 0;
}

/// p_value -> a node: the next parameter
fn pValue() u32 {
    const c = pPeek();
    if (c == -1) return nodeNew(K_NULL);
    const at = sp_cur;
    switch (c) {
        '(' => return pList(),
        '#' => {
            var i = at + 1;
            var id: u32 = 0;
            while (true) : (i += 1) {
                const d = ch(i) -% '0';
                if (d > 9) break;
                id = id *% 10 +% d;
            }
            sp_cur = i;
            const n = nodeNew(K_REF);
            sp_nodes[n].v = id;
            return n;
        },
        0x27 => {
            // '...' with '' inside
            var i = at + 1;
            const s = i;
            while (i < sp_text.len) {
                if (sp_text[i] == 0x27) {
                    if (ch(i + 1) != 0x27) break;
                    i += 1;
                }
                i += 1;
            }
            sp_cur = i + 1;
            const n = nodeNew(K_STR);
            sp_nodes[n].v = s;
            sp_nodes[n].n = @truncate(i - s);
            return n;
        },
        '.' => {
            var i = at + 1;
            const s = i;
            while (i < sp_text.len and sp_text[i] != '.') i += 1;
            sp_cur = i + 1;
            const n = nodeNew(K_ENUM);
            sp_nodes[n].v = s;
            sp_nodes[n].n = @truncate(i - s);
            return n;
        },
        '$' => {
            sp_cur = at + 1;
            return nodeNew(K_NULL);
        },
        '*' => {
            sp_cur = at + 1;
            return nodeNew(K_DERIV);
        },
        '-', '+', '0'...'9' => return pNumber(),
        else => {},
    }
    // a typed value: NAME(params)
    const w = pWord();
    if (w.len == 0) {
        sp_cur += 1; // (an unexpected character)
        return nodeNew(K_NULL);
    }
    const code = typeCode(w);
    if (pPeek() != '(') return nodeNew(K_NULL);
    const l = pList();
    const n = nodeNew(K_TYPED);
    sp_nodes[n].n = code;
    sp_nodes[n].v = l;
    return n;
}

/// p_list -> a list node: "(" values separated by "," ")"
fn pList() u32 {
    sp_cur += 1; // "("
    const first = sp_sn;
    sp_depth += 1;
    defer sp_depth -= 1;
    if (sp_depth > MAXDEPTH) {
        // (port) too deep: skipped to its ")", an empty list
        sp_bad = true;
        var depth: usize = 1;
        while (sp_cur < sp_text.len) : (sp_cur += 1) {
            const c = sp_text[sp_cur];
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth == 0) {
                    sp_cur += 1;
                    break;
                }
            }
            if (c == ';') break;
        }
        const n = nodeNew(K_LIST);
        sp_nodes[n].n = 0;
        sp_nodes[n].v = sp_nk;
        return n;
    }
    var c = pPeek();
    if (c != ')') {
        while (true) {
            const v = pValue();
            if (sp_sn < PSTACK) {
                sp_stack[sp_sn] = v;
                sp_sn += 1;
            }
            c = pPeek();
            if (c == ',') {
                sp_cur += 1;
                continue;
            }
            if (c == ')') break;
            if (c == -1 or c == ';') break; // (the end of the text: stop)
            // a complex's parts: blank-separated
        }
    }
    if (c == ')') sp_cur += 1;
    // children: into the kids array
    var k = sp_sn - first;
    const at = sp_nk;
    if (@as(u64, at) + k > sp_kcap) {
        sp_bad = true;
        k = 0;
    }
    @memcpy(sp_kids[at .. at + k], sp_stack[first .. first + k]);
    sp_nk += k;
    sp_sn = first;
    const n = nodeNew(K_LIST);
    sp_nodes[n].n = k;
    sp_nodes[n].v = at;
    return n;
}

// fild m64; fild m32 [rdi+8]; 10^k as the original's pow10x; fmulp; fstp [rdi]
// (machine code in .text: the x87 in extended precision, as the original)
export const bee_st_x87_pow10: [32]u8 linksection(".text") = .{
    0xdf, 0x2f, // fild qword [rdi]
    0xdb, 0x47, 0x08, // fild dword [rdi+8]
    0xd9, 0xe9, // fldl2t
    0xde, 0xc9, // fmulp st(1), st
    0xd9, 0xc0, // fld st(0)
    0xd9, 0xfc, // frndint
    0xdc, 0xe9, // fsub st(1), st
    0xd9, 0xc9, // fxch st(1)
    0xd9, 0xf0, // f2xm1
    0xd9, 0xe8, // fld1
    0xde, 0xc1, // faddp st(1), st
    0xd9, 0xfd, // fscale
    0xdd, 0xd9, // fstp st(1)
    0xde, 0xc9, // fmulp st(1), st
    0xdd, 0x1f, // fstp qword [rdi]
    0xc3, // ret
};
const use_x87 = builtin.cpu.arch == .x86_64;

/// m 10^e through the x87 (fild m; pow10x(e); fmulp; fstp qword)
pub fn x87Real(m: i64, e: i32) f64 {
    if (!use_x87) return @as(f64, @floatFromInt(m)) * std.math.pow(f64, 10, @floatFromInt(e));
    return run87(&bee_st_x87_pow10, m, e);
}
// (the code through a slice: a function pointer cast straight from the
// constant's address calls 0 in Debug builds)
fn run87(code: []const u8, m: i64, e: i32) f64 {
    var buf: extern struct { m: i64, e: i32, pad: i32 } = .{ .m = m, .e = e, .pad = 0 };
    const f: *const fn (*anyopaque) callconv(.c) void = @ptrCast(code.ptr);
    f(@ptrCast(&buf));
    return @bitCast(buf.m);
}

/// p_number -> an integer or real node (x87 for the decimal exponent)
fn pNumber() u32 {
    var i = sp_cur;
    var neg = false;
    if (ch(i) == '-') {
        neg = true;
        i += 1;
    } else if (ch(i) == '+') i += 1;
    var m: u64 = 0; // mantissa digits (18 at most)
    var e: i32 = 0; // decimal exponent
    var real = false; // has "." or "E"
    var digits: u32 = 0;
    while (true) : (i += 1) {
        const d = ch(i) -% '0';
        if (d > 9) break;
        if (digits < 18) {
            m = m *% 10 +% d;
            digits += 1;
        } else e +%= 1; // (beyond 18 digits: scale only)
    }
    if (ch(i) == '.') {
        real = true;
        i += 1;
        while (true) : (i += 1) {
            const d = ch(i) -% '0';
            if (d > 9) break;
            if (digits < 18) {
                m = m *% 10 +% d;
                digits += 1;
                e -%= 1;
            }
        }
    }
    if (ch(i) | 0x20 == 'e') {
        real = true;
        i += 1;
        var eneg = false;
        if (ch(i) == '-') {
            eneg = true;
            i += 1;
        } else if (ch(i) == '+') i += 1;
        var x: i32 = 0;
        while (true) : (i += 1) {
            const d = ch(i) -% '0';
            if (d > 9) break;
            x = x *% 10 +% @as(i32, d);
        }
        if (eneg) x = 0 -% x;
        e +%= x;
    }
    sp_cur = i;
    if (!real) {
        const n = nodeNew(K_INT);
        sp_nodes[n].v = if (neg) 0 -% m else m;
        return sp_nn -% 1;
    }
    var bits: u64 = @bitCast(x87Real(@bitCast(m), e));
    if (neg) bits ^= 0x8000000000000000;
    const n = nodeNew(K_REAL);
    sp_nodes[n].v = bits;
    return sp_nn -% 1;
}

/// p_entity -> true if an instance was read (false: the end of the data)
fn pEntity() bool {
    if (pPeek() != '#') return false;
    var i = sp_cur + 1;
    var id: u32 = 0;
    while (true) : (i += 1) {
        const d = ch(i) -% '0';
        if (d > 9) break;
        id = id *% 10 +% d;
    }
    sp_cur = i;
    read: {
        if (pPeek() != '=') break :read;
        sp_cur += 1;
        var code: u32 = undefined;
        var node: u32 = undefined;
        if (pPeek() == '(') {
            node = pList(); // a complex instance: its parts as typed values in a list
            code = T_COMPLEX;
        } else {
            code = typeCode(pWord());
            if (pPeek() != '(') break :read;
            node = pList();
        }
        if (sp_ne < sp_ecap) {
            sp_ents[sp_ne] = .{ .id = id, .code = code, .node = node, .aux = 0 };
            sp_ne += 1;
            if (id > sp_maxid) sp_maxid = id;
        }
    }
    // to the ";"
    while (true) {
        const c = pPeek();
        if (c == -1) return false;
        sp_cur += 1;
        if (c == ';') return true;
    }
}

/// sp_parse(text) -> entities (0: no DATA section, or no memory)
fn spParse(text: []const u8) u32 {
    sp_text = text;
    sp_nn = 0;
    sp_nk = 0;
    sp_ne = 0;
    sp_sn = 0;
    sp_maxid = 0;
    sp_bad = false;
    sp_depth = 0;
    sp_map = null;
    // room: nodes ~ bytes / 2, kids, entities ~ bytes / 8
    const cap: u64 = (text.len >> 1) + 1024;
    if (cap > 0xffffffff) return 0;
    sp_ncap = @intCast(cap);
    sp_kcap = @intCast(cap);
    sp_nodes = @ptrCast(nb.data(cap * 16) orelse return 0);
    sp_kids = @ptrCast(nb.data(cap * 4) orelse return 0);
    const ecap: u64 = (text.len >> 3) + 1024;
    sp_ecap = @intCast(ecap);
    sp_ents = @ptrCast(nb.data(ecap * 16) orelse return 0);
    sp_stack = @ptrCast(nb.data(PSTACK * 4) orelse return 0);
    // to "DATA;"
    var i: usize = 0;
    while (true) : (i += 1) {
        if (text.len < 5 or i > text.len - 5) return 0;
        if (std.mem.eql(u8, text[i .. i + 4], "DATA") and text[i + 4] == ';') break;
    }
    sp_cur = i + 5;
    while (pEntity()) {}
    // id -> entity
    if (sp_maxid < MAXMAP) {
        const m: [*]u32 = @ptrCast(nb.data((@as(usize, sp_maxid) + 1) * 4) orelse return 0);
        @memset(m[0 .. @as(usize, sp_maxid) + 1], 0);
        for (0..sp_ne) |k| m[sp_ents[k].id] = @intCast(k + 1);
        sp_map = m;
    } else {
        // (port) ids beyond the map's room: a sorted list (the last of equal ids wins, as the map)
        sp_sorted = @ptrCast(nb.data(@as(usize, sp_ne) * 8 + 8) orelse return 0);
        for (0..sp_ne) |k| sp_sorted[k] = (@as(u64, sp_ents[k].id) << 32) | k;
        std.sort.pdq(u64, sp_sorted[0..sp_ne], {}, std.sort.asc(u64));
    }
    return sp_ne;
}

// ---- reading the entities ---------------------------------------------------------------
/// e_get(id) -> its entity record, or null
fn eGet(id: u32) ?*Ent {
    if (id > sp_maxid) return null;
    if (sp_map) |m| {
        const k = m[id];
        if (k == 0) return null;
        return &sp_ents[k - 1];
    }
    // (port) the sorted list: the last entity with this id
    var lo: usize = 0;
    var hi: usize = sp_ne;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if ((sp_sorted[mid] >> 32) <= id) lo = mid + 1 else hi = mid;
    }
    if (lo == 0 or (sp_sorted[lo - 1] >> 32) != id) return null;
    return &sp_ents[@as(u32, @truncate(sp_sorted[lo - 1]))];
}

inline fn nGet(i: u32) *Node {
    return &sp_nodes[i];
}

/// n_item(list node, i) -> its i-th child node (NONE: none)
fn nItem(l: u32, i: u32) u32 {
    if (l == NONE) return NONE; // (the original reads node -1's record: a wrong kind there)
    const n = nGet(l);
    if (n.kind != K_LIST) return NONE;
    if (i >= n.n) return NONE;
    return sp_kids[@as(usize, @truncate(n.v)) + i];
}
/// e_arg(entity, i) -> the i-th parameter's node
fn eArg(e: *const Ent, i: u32) u32 {
    return nItem(e.node, i);
}
const pArg = nItem;

/// e_part(entity, type code) -> that part's parameter list of a complex
/// entity (or the entity's own list when it is that type), NONE: none
fn ePart(e: *const Ent, code: u32) u32 {
    if (e.code == code) return e.node;
    if (e.code != T_COMPLEX) return NONE;
    var k: u32 = 0;
    while (true) : (k += 1) {
        const it = nItem(e.node, k);
        if (it == NONE) return NONE;
        const n = nGet(it);
        if (n.kind == K_TYPED and n.n == code) return @truncate(n.v);
    }
}

/// n_ref(node) -> the id it refers to (0: not a reference)
fn nRef(i: u32) u32 {
    if (i == NONE) return 0;
    const n = nGet(i);
    if (n.kind != K_REF) return 0;
    return @truncate(n.v);
}

/// n_real(node) -> its number (typed values: their first; 0 else)
fn nReal(start: u32) f64 {
    var i = start;
    var hops: u32 = 0;
    while (true) {
        if (i == NONE) return 0;
        const n = nGet(i);
        switch (n.kind) {
            K_REAL => return @bitCast(n.v),
            K_INT => return @floatFromInt(@as(i64, @bitCast(n.v))),
            K_TYPED => {
                hops += 1;
                if (hops > MAXDEPTH) return 0;
                i = nItem(@truncate(n.v), 0);
            },
            else => return 0,
        }
    }
}

/// n_int(node) -> its integer (reals: truncated)
fn nInt(i: u32) i32 {
    if (i == NONE) return 0;
    const n = nGet(i);
    if (n.kind == K_INT) return @truncate(@as(i64, @bitCast(n.v)));
    if (n.kind == K_REAL) return nb.cvtt(@bitCast(n.v));
    return 0;
}

fn nStr(n: *const Node) []const u8 {
    const s: usize = @truncate(n.v);
    const end = @min(s + n.n, sp_text.len);
    return sp_text[@min(s, end)..end];
}

/// n_is(node, word): that enumeration
fn nIs(i: u32, w: []const u8) bool {
    if (i == NONE) return false;
    const n = nGet(i);
    if (n.kind != K_ENUM) return false;
    return std.mem.eql(u8, nStr(n), w);
}
fn nTrue(i: u32) bool {
    return nIs(i, "T");
}

/// n_count(list node) -> its length
fn nCount(i: u32) u32 {
    if (i == NONE) return 0;
    const n = nGet(i);
    if (n.kind != K_LIST) return 0;
    return n.n;
}

// ---- units --------------------------------------------------------------------------------
/// mm_of_unit(unit id) -> millimetres (or radians) per unit, null if unknown
fn mmOfUnit(id: u32, depth: u32) ?f64 {
    if (depth > MAXCHAIN) return null;
    const e = eGet(id) orelse return null;
    const cbu = ePart(e, T_CBU);
    if (cbu != NONE) {
        // a conversion: its factor's unit (name, factor)
        const f = eGet(nRef(pArg(cbu, 1))) orelse return null;
        const v = nReal(eArg(f, 0));
        const u = mmOfUnit(nRef(eArg(f, 1)), depth + 1) orelse return null;
        return u * v;
    }
    // an SI unit: prefix, name
    const siu = ePart(e, T_SIU);
    if (siu == NONE) return null;
    if (nIs(pArg(siu, 1), "RADIAN")) return 1.0;
    const pre = pArg(siu, 0);
    if (nIs(pre, "MILLI")) return 1.0;
    if (nIs(pre, "CENTI")) return 10.0;
    if (nIs(pre, "MICRO")) return 0.001;
    if (nIs(pre, "KILO")) return 1000000.0;
    return 1000.0; // a metre: 1000 mm
}

/// sb_units: sb_len (scene units per file length unit), sb_ang (radians per
/// file angle unit): the first length / plane angle units in the file
fn sbUnits() void {
    const mm = @import("cad.zig").unitMm();
    sb_len = 1.0 / mm; // (default: millimetres)
    sb_ang = 1.0;
    var found: u32 = 0;
    var k: u32 = 0;
    while (k < sp_ne) {
        const e = &sp_ents[k];
        k += 1;
        if (e.code != T_COMPLEX) continue;
        const g = ePart(e, T_GUAC);
        if (g == NONE) continue;
        const units = pArg(g, 0);
        var j: u32 = 0;
        while (true) : (j += 1) {
            const it = nItem(units, j);
            if (it == NONE) return;
            const id = nRef(it);
            const u = eGet(id) orelse continue;
            if (found & 1 == 0 and ePart(u, T_LENU) != NONE) {
                if (mmOfUnit(id, 0)) |v| {
                    sb_len = v / mm;
                    found |= 1;
                }
            }
            if (found & 2 == 0 and ePart(u, T_PAU) != NONE) {
                if (mmOfUnit(id, 0)) |v| {
                    sb_ang = v;
                    found |= 2;
                }
            }
        }
    }
}

// ---- geometry -----------------------------------------------------------------------------
/// g_xyz(list node, scale): up to 3 numbers (z 0 if 2)
fn gXyz(l: u32, s: f64) V3 {
    var o: V3 = undefined;
    for (0..3) |k| o[k] = nReal(pArg(l, @intCast(k))) * s;
    return o;
}

/// g_point(id): a CARTESIAN_POINT in scene units
fn gPoint(id: u32) V3 {
    const e = eGet(id) orelse return .{ 0, 0, 0 };
    return gXyz(eArg(e, 1), sb_len);
}

/// g_dir(id): a DIRECTION (made unit; VECTOR: its direction)
fn gDir(id: u32, depth: u32) V3 {
    const e = eGet(id) orelse return nb.v3scale(sr_z, 1.0);
    if (e.code == T_VECTOR) {
        if (depth > MAXCHAIN) return nb.v3scale(sr_z, 1.0);
        return gDir(nRef(eArg(e, 1)), depth + 1);
    }
    var d = gXyz(eArg(e, 1), 1.0);
    _ = nb.v3norm(&d);
    return d;
}

/// g_axis(id) -> O X Y Z: an AXIS2_PLACEMENT_3D (axis default Z, reference
/// default X, made perpendicular)
fn gAxis(id: u32) [4]V3 {
    var f: [4]V3 = undefined;
    f[3] = nb.v3scale(sr_z, 1.0);
    f[1] = nb.v3scale(sr_x, 1.0);
    f[0] = .{ 0, 0, 0 };
    if (eGet(id)) |e| {
        const loc = nRef(eArg(e, 1));
        if (loc != 0) f[0] = gPoint(loc);
        const ax = nRef(eArg(e, 2));
        if (ax != 0) f[3] = gDir(ax, 0);
        const rf = nRef(eArg(e, 3));
        if (rf != 0) {
            f[1] = gDir(rf, 0);
        } else {
            // no reference: any perpendicular
            if (!jb(fabs(nb.v3dot(f[3], sr_x)), 0.9)) f[1] = nb.v3scale(sr_y, 1.0);
        }
        // X := X - (X.Z) Z, unit
        const d = fneg(nb.v3dot(f[3], f[1]));
        nb.v3axpy(&f[1], f[3], d);
        _ = nb.v3norm(&f[1]);
    }
    f[2] = nb.v3cross(f[3], f[1]);
    return f;
}

/// knots_expand(mults list node, knots list node, count wanted) -> the full
/// knot vector, null if they do not add up
fn knotsExpand(mults: u32, knots: u32, want: u32) ?[*]f64 {
    const k = nb.doubles(@as(usize, want) + 2) orelse return null;
    var w: u32 = 0;
    var i: u32 = 0;
    while (true) : (i += 1) {
        const mi = pArg(mults, i);
        if (mi == NONE) break;
        var m = nInt(mi);
        const x = nReal(pArg(knots, i));
        while (m > 0 and w < want) {
            k[w] = x;
            w += 1;
            m -= 1;
        }
    }
    if (w != want) return null;
    return k;
}

/// hscale: (w x, w y, w z, w)
fn hscale(p: [*]f64, q: V3, w: f64) void {
    p[3] = w;
    p[0] = q[0] * w;
    p[1] = q[1] * w;
    p[2] = q[2] * w;
}

/// (port) degrees the kernel's basis functions take
fn degOk(d: i32, n: u32) bool {
    return d >= 0 and d <= nb.MAXP and @as(u32, @intCast(d)) + 1 <= n;
}

/// g_bsc(entity) -> a NURBS curve (B_SPLINE_CURVE_WITH_KNOTS or the rational
/// complex), NONE on failure
fn gBsc(e: *const Ent) u32 {
    var head: u32 = undefined;
    var kn: u32 = undefined;
    var wl: u32 = NONE;
    var off: u32 = 0;
    if (e.code == T_BSC) {
        // simple: (name, deg, pts, form, closed, si, mults, knots, spec)
        head = e.node;
        kn = NONE;
        off = 1;
    } else {
        // complex: B_SPLINE_CURVE(deg, pts, ...), _WITH_KNOTS(mults, knots, ...), RATIONAL_..((w))
        head = ePart(e, T_BSC0);
        if (head == NONE) return NONE;
        kn = ePart(e, T_BSC);
        if (kn == NONE) return NONE;
        wl = ePart(e, T_RBSC);
    }
    const deg = nInt(pArg(head, off));
    const pts = pArg(head, off + 1);
    const n = nCount(pts);
    if (n < 2 or @as(i32, @bitCast(n)) < 2) return NONE;
    if (!degOk(deg, n)) return NONE; // (port: the original's basis overruns its arrays)
    const c = br.nbNewExt(@intCast(deg), n) orelse return NONE;
    var mults: u32 = undefined;
    var knots: u32 = undefined;
    if (kn == NONE) {
        mults = pArg(head, 6);
        knots = pArg(head, 7);
    } else {
        mults = pArg(kn, 0);
        knots = pArg(kn, 1);
    }
    c.kn = knotsExpand(mults, knots, n + @as(u32, @intCast(deg)) + 1) orelse return NONE;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const p = gPoint(nRef(pArg(pts, i)));
        var w: f64 = 1.0;
        if (wl != NONE) w = nReal(pArg(pArg(wl, 0), i));
        hscale(c.cp.? + i * 4, p, w);
    }
    return nb.cvIndex(c);
}

/// g_curve(id) -> the kernel curve (built once), NONE if unknown
fn gCurve(id: u32, depth: u32) u32 {
    const e = eGet(id) orelse return NONE;
    if (e.aux != 0) return e.aux - 1;
    var r: u32 = NONE;
    switch (e.code) {
        T_SCURVE, T_SEAM, T_TRIM => {
            // its 3D / basis curve (field 1)
            if (depth > MAXCHAIN) return NONE;
            r = gCurve(nRef(eArg(e, 1)), depth + 1);
        },
        T_LINE => {
            // LINE('', point, vector)
            const a = gPoint(nRef(eArg(e, 1)));
            var d = gDir(nRef(eArg(e, 2)), 0);
            d = nb.v3add(a, d); // b = a + d
            r = br.mkLine(a, d).i;
        },
        T_CIRCLE, T_ELLIPSE => {
            // (name, axis, r1 [, r2])
            const f = gAxis(nRef(eArg(e, 1)));
            const r1 = nReal(eArg(e, 2)) * sb_len;
            var r2 = r1;
            var typ: u32 = nb.CT_CIRCLE;
            if (e.code != T_CIRCLE) {
                typ = nb.CT_ELLIPSE;
                r2 = nReal(eArg(e, 3)) * sb_len;
            }
            const fr: [3]V3 = .{ f[0], f[1], f[2] };
            r = br.mkConic(typ, &fr, r1, r2);
        },
        T_BSC, T_COMPLEX => r = gBsc(e),
        else => return NONE,
    }
    if (r != NONE) e.aux = r + 1;
    return r;
}

/// g_bss(entity) -> a NURBS surface (the simple entity or the rational
/// complex), NONE on failure
fn gBss(e: *const Ent) u32 {
    var head: u32 = undefined;
    var kn: u32 = undefined;
    var wl: u32 = NONE;
    var off: u32 = undefined;
    if (e.code == T_BSS) {
        head = e.node;
        kn = e.node;
        off = 1;
    } else {
        head = ePart(e, T_BSS0);
        if (head == NONE) return NONE;
        kn = ePart(e, T_BSS);
        if (kn == NONE) return NONE;
        wl = ePart(e, T_RBSS);
        off = 0;
    }
    const s = nb.ksNew() orelse return NONE;
    s.typ = nb.ST_NURBS;
    const du = nInt(pArg(head, off));
    const dv = nInt(pArg(head, off + 1));
    s.du = @bitCast(du);
    s.dv = @bitCast(dv);
    const rows = pArg(head, off + 2);
    s.nu = nCount(rows);
    s.nv = nCount(pArg(rows, 0));
    if (@as(i32, @bitCast(s.nu)) < 2) return NONE;
    if (@as(i32, @bitCast(s.nv)) < 2) return NONE;
    if (!degOk(du, s.nu) or !degOk(dv, s.nv)) return NONE; // (port)
    // knots: simple fields 8 .. 11, complex 0 .. 3
    const ko = off * 8;
    s.ku = knotsExpand(pArg(kn, ko), pArg(kn, ko + 2), s.nu + s.du + 1) orelse return NONE;
    s.kv = knotsExpand(pArg(kn, ko + 1), pArg(kn, ko + 3), s.nv + s.dv + 1) orelse return NONE;
    const cnt = @as(u64, s.nu) * s.nv;
    if (cnt > (1 << 26)) return NONE; // (port)
    const cp = nb.doubles(cnt * 4) orelse return NONE;
    s.cp = cp;
    var i: u32 = 0;
    while (i < s.nu) : (i += 1) {
        const row = pArg(rows, i);
        var j: u32 = 0;
        while (j < s.nv) : (j += 1) {
            const p = gPoint(nRef(pArg(row, j)));
            var w: f64 = 1.0;
            if (wl != NONE) w = nReal(pArg(pArg(pArg(wl, 0), i), j));
            hscale(cp + (i * s.nv + j) * 4, p, w);
        }
    }
    return nb.sfIndex(s);
}

/// g_surface(id) -> the kernel surface (once), NONE if unknown
fn gSurface(id: u32) u32 {
    const e = eGet(id) orelse return NONE;
    if (e.aux != 0) return e.aux - 1;
    var r: u32 = undefined;
    switch (e.code) {
        T_BSS, T_COMPLEX => r = gBss(e),
        T_PLANE, T_CYL, T_CONE, T_SPHERE, T_TORUS => {
            const typ: u32 = switch (e.code) {
                T_PLANE => nb.ST_PLANE,
                T_CYL => nb.ST_CYL,
                T_CONE => nb.ST_CONE,
                T_SPHERE => nb.ST_SPHERE,
                else => nb.ST_TORUS,
            };
            // (name, axis, r1, r2 / angle)
            const f = gAxis(nRef(eArg(e, 1)));
            const r1 = nReal(eArg(e, 2)) * sb_len;
            var r2: f64 = 0;
            if (typ == nb.ST_TORUS) r2 = nReal(eArg(e, 3)) * sb_len; // minor radius
            if (typ == nb.ST_CONE) r2 = nReal(eArg(e, 3)) * sb_ang; // half angle
            const fr: [3]V3 = .{ f[0], f[1], f[2] };
            r = br.mkSurf(typ, &fr, r1, r2);
        },
        else => return NONE,
    }
    if (r != NONE) e.aux = r + 1;
    return r;
}

// ---- topology -----------------------------------------------------------------------------
/// g_vertex(VERTEX_POINT id) -> the kernel vertex (once)
fn gVertex(id: u32) u32 {
    const e = eGet(id) orelse return NONE;
    if (e.aux != 0) return e.aux - 1;
    const v = br.newVx(gPoint(nRef(eArg(e, 1))));
    e.aux = v +% 1;
    return v;
}

var cp_best: f64 = 0;

/// c_param(curve, point) -> the curve's parameter there
fn cParam(c: *const nb.Curve, p: V3) f64 {
    if (c.typ != nb.CT_NURBS) {
        const d = nb.v3sub(p, c.o);
        var x = nb.v3dot(d, c.x);
        if (c.typ == nb.CT_LINE) return x;
        // conic: atan2(y / b, x / a)
        var y = nb.v3dot(d, c.y);
        if (c.typ == nb.CT_ELLIPSE) {
            y = y / c.r2;
            x = x / c.r1;
        }
        return nb.datan2(y, x);
    }
    // the nearest of 64 samples over the knots, then Newton
    const a = c.kn.?[c.deg];
    const b = c.kn.?[c.n];
    var best: f64 = @bitCast(@as(u64, 0x7fefffffffffffff));
    var i: u32 = 0;
    while (i <= 64) : (i += 1) {
        var t = fl(i) / 64.0;
        t = t * (b - a);
        t = t + a;
        const d = nb.v3dist(nb.crvEval(c, t)[0], p);
        if (jae(d, best)) continue;
        best = d;
        cp_best = t;
    }
    // Newton on (C - P) . C' = 0
    i = 0;
    while (i < 20) : (i += 1) {
        const ev = nb.crvEval(c, cp_best);
        const r = nb.v3sub(ev[0], p);
        const num = nb.v3dot(r, ev[1]);
        const den = nb.v3dot(ev[1], ev[1]);
        if (jbe(den, sr_tiny)) break;
        var t = cp_best - num / den;
        t = maxsd(t, a);
        t = minsd(t, b);
        cp_best = t;
    }
    return cp_best;
}

/// g_edge(EDGE_CURVE id) -> the kernel edge (once), NONE on failure
fn gEdge(id: u32) u32 {
    const e = eGet(id) orelse return NONE;
    if (e.aux != 0) return e.aux - 1;
    // (name, v1, v2, curve, same sense)
    const va = gVertex(nRef(eArg(e, 1)));
    const vb = gVertex(nRef(eArg(e, 2)));
    if (@as(i32, @bitCast(va)) < 0) return NONE;
    const p0 = br.vx(va).p;
    if (@as(i32, @bitCast(vb)) < 0) return NONE;
    const p1 = br.vx(vb).p;
    const ci = gCurve(nRef(eArg(e, 3)), 0);
    if (@as(i32, @bitCast(ci)) < 0) return NONE;
    const ss = nTrue(eArg(e, 4));
    const c = nb.cv(ci);
    var t0 = cParam(c, p0);
    var t1 = cParam(c, p1);
    if (c.typ == nb.CT_NURBS) {
        // closed (one vertex): the whole range
        if (va == vb) {
            t0 = c.kn.?[c.deg];
            t1 = c.kn.?[c.n];
            if (!ss) {
                const t = t0;
                t0 = t1;
                t1 = t;
            }
        }
    } else if (c.typ != nb.CT_LINE) {
        // a conic: going its way (same sense: t1 > t0) once round at most; a
        // closed one (the same vertex) all the way
        if (va == vb) {
            t1 = t0 + (if (ss) sr_2pi else fneg(sr_2pi));
        } else if (ss) {
            var k: u32 = 0;
            while (!ja(t1, t0) and k < 64) : (k += 1) t1 += sr_2pi; // (port: bounded)
        } else {
            var k: u32 = 0;
            while (!jb(t1, t0) and k < 64) : (k += 1) t1 -= sr_2pi;
        }
    }
    const r = br.newEd(ci, va, vb, t0, t1);
    e.aux = r +% 1;
    return r;
}

/// g_face(ADVANCED_FACE id) -> the kernel face, NONE on failure
fn gFace(id: u32) u32 {
    const e = eGet(id) orelse return NONE;
    // (name, bounds, surface, same sense)
    const surf = gSurface(nRef(eArg(e, 2)));
    if (@as(i32, @bitCast(surf)) < 0) return NONE;
    const ss = nTrue(eArg(e, 3));
    // hints: the first bound's first vertex on the surface
    const bounds = eArg(e, 1);
    const hint = faceHint(bounds, surf);
    const fi = br.fbFace(surf, hint[0], hint[1]);
    if (fi == NONE) return NONE;
    br.fc(fi).sense = @intFromBool(ss) ^ 1;
    const bn = nCount(bounds);
    var b: u32 = 0;
    while (b < bn) : (b += 1) {
        const be = eGet(nRef(pArg(bounds, b))) orelse continue;
        // (name, loop, orientation)
        const bo = nTrue(eArg(be, 2));
        const le = eGet(nRef(eArg(be, 1))) orelse continue;
        if (le.code != T_ELOOP) continue; // (vertex loops: nothing)
        const list = eArg(le, 1);
        const kn = nCount(list);
        if (kn == 0) continue;
        _ = br.fbLoop();
        var sv: u32 = NONE;
        var k: u32 = 0;
        while (k < kn) : (k += 1) {
            const at = if (bo) k else kn - 1 - k; // a reversed bound: walked back
            const oe = eGet(nRef(pArg(list, at))) orelse continue;
            // ORIENTED_EDGE(name, *, *, edge, o)
            const o = nTrue(eArg(oe, 4));
            const ed = gEdge(nRef(eArg(oe, 3)));
            if (@as(i32, @bitCast(ed)) < 0) return NONE;
            const rv: u32 = @intFromBool(o) ^ @intFromBool(bo);
            // its start: a pole (STEP leaves the degenerate edge there out) gets one
            const r = br.ed(ed);
            const v = if (rv != 0) r.v1 else r.v0;
            if (sv == NONE) {
                sv = v; // (the loop's first: at its end)
            } else poleEdge(v, surf);
            _ = br.fbCe(ed, rv);
        }
        if (sv != NONE) poleEdge(sv, surf);
    }
    br.fcPcurves(fi);
    br.fcBox(fi);
    outerFirst(fi);
    fixWrap(fi);
    return fi;
}

/// pole_edge(vertex, surface): a degenerate edge's coedge there when the
/// vertex is a pole of a sphere or the apex of a cone
fn poleEdge(v: u32, si: u32) void {
    const s = nb.sf(si);
    if (s.typ != nb.ST_CONE and s.typ != nb.ST_SPHERE) return;
    // d = P - O, off the axis by |d - (d . Z) Z|
    const d = nb.v3sub(br.vx(v).p, s.o);
    var z = nb.v3dot(d, s.z);
    const dd = nb.v3dot(d, d);
    z = z * z;
    var tol = s.r1 * s.r1;
    tol = dd + tol;
    tol = tol * pe_tol;
    if (ja(dd - z, tol)) return;
    const e = br.newEd(0, v, v, 0, 0);
    br.ed(e).flags |= br.EF_DEGEN;
    _ = br.fbCe(e, 0);
}

/// fix_wrap(face): a face on a surface periodic in u whose outer loop turns
/// the wrong way took the wrong side of the turn: its bounds are meridians
/// through poles. The meridians on the lower half of its u range move on by
/// a turn. Then u from 0 (a face below it: on by turns).
fn fixWrap(fi: u32) void {
    const f = br.fc(fi);
    const typ = nb.sf(f.surf).typ;
    const periodic = typ >= nb.ST_CYL and typ <= nb.ST_TORUS;
    if (periodic) {
        const a = lpShoelace(f.loop);
        const pos: u32 = @intFromBool(a > 0);
        if (pos ^ f.sense == 0) {
            const first = br.lp(f.loop).first;
            const end = first + br.lp(f.loop).n;
            var lo: f64 = @bitCast(@as(u64, 0x7fefffffffffffff));
            var hi: f64 = @bitCast(@as(u64, 0xffefffffffffffff));
            var c = first;
            while (c < end) : (c += 1) {
                const u = br.ceUv(c, 0)[0];
                lo = minsd(u, lo);
                hi = maxsd(u, hi);
            }
            const mid = (lo + hi) * 0.5;
            c = first;
            while (c < end) : (c += 1) {
                // a meridian: u the same at both ends
                const ua = br.ceUv(c, 0)[0];
                const ub = br.ceUv(c, 1.0)[0];
                if (ja(fabs(ub - ua), fw_iso)) continue;
                if (jae(ua, mid)) continue;
                shiftPc(c, sr_2pi);
            }
            br.fcBox(fi);
        }
    }
    if (jae(br.fc(fi).u0, fw_neg)) return;
    if (!periodic) return;
    var k = fneg(br.fc(fi).u0) / sr_2pi;
    k = @ceil(k); // (roundsd up)
    k = k * sr_2pi;
    var l = f.loop;
    const l1 = l + f.nloop;
    while (l < l1) : (l += 1) {
        var c = br.lp(l).first;
        const end = c + br.lp(l).n;
        while (c < end) : (c += 1) shiftPc(c, k);
    }
    br.fcBox(fi);
}

/// lp_shoelace(loop): the signed area of its pcurves' points (polylines:
/// twice their own points; others: 64 each) (bdebug.s)
fn lpShoelace(l: u32) f64 {
    var sum: f64 = 0;
    var c = br.lp(l).first;
    const end = c + br.lp(l).n;
    while (c < end) : (c += 1) {
        const pc = br.ce(c).pc;
        if (pc == NONE) continue;
        const p = nb.cv(pc);
        const n: u32 = if (p.typ == nb.CT_NURBS) p.n << 1 else 64;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const a = br.ceUv(c, fl(k) / fl(n));
            const b = br.ceUv(c, fl(k + 1) / fl(n));
            var x = a[0] * b[1];
            x = x - a[1] * b[0];
            x = x * 0.5;
            sum = x + sum;
        }
    }
    return sum;
}

/// shift_pc(coedge, du): moves its pcurve along u
fn shiftPc(c: u32, du: f64) void {
    const pc = br.ce(c).pc;
    if (pc == NONE) return; // (the original reads past its arena)
    const p = nb.cv(pc);
    if (p.typ == nb.CT_LINE) {
        p.o[0] = p.o[0] + du;
    } else if (p.typ == nb.CT_NURBS) {
        const cp = p.cp.?;
        var i: u32 = 0;
        while (i < p.n) : (i += 1) {
            // w u += w du
            var x = cp[i * 4 + 3] * du;
            x = x + cp[i * 4];
            cp[i * 4] = x;
        }
    }
}

/// face_hint(bounds list node, surface) -> the (u, v) of the first bound's
/// first vertex on the surface
fn faceHint(bounds: u32, si: u32) [2]f64 {
    const b = eGet(nRef(pArg(bounds, 0))) orelse return .{ 0, 0 };
    const l = eGet(nRef(eArg(b, 1))) orelse return .{ 0, 0 };
    if (l.code != T_ELOOP) return .{ 0, 0 };
    const oe = eGet(nRef(pArg(eArg(l, 1), 0))) orelse return .{ 0, 0 };
    const ec = eGet(nRef(eArg(oe, 3))) orelse return .{ 0, 0 };
    const vp = eGet(nRef(eArg(ec, 1))) orelse return .{ 0, 0 };
    const p = gPoint(nRef(eArg(vp, 1)));
    const r = br.sfInvert(nb.sf(si), p, 0, 0);
    return .{ r.u, r.v };
}

/// outer_first(face): the loop with the largest (u, v) area first
fn outerFirst(fi: u32) void {
    br.fcSample(fi, 24);
    var best: f64 = 0;
    var out: u32 = 0;
    var k: u32 = 0;
    while (k < br.fs_nl) : (k += 1) {
        const a = fabs(fsLoopArea(k));
        if (jbe(a, best)) continue;
        best = a;
        out = k;
    }
    if (out == 0) return;
    const f = br.fc(fi);
    const a = br.lp(f.loop);
    const b = br.lp(f.loop + out);
    const t = a.*;
    a.* = b.*;
    b.* = t;
}
/// fs_loop_area: twice its signed area (no halving, as the original's)
fn fsLoopArea(k: u32) f64 {
    const s = br.fs_ls[k];
    const n = br.fs_ln[k];
    var a: f64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const p = br.fs_pts[s + i];
        const q = br.fs_pts[s + (if (i + 1 < n) i + 1 else 0)];
        const x = p[0] * q[1] - q[0] * p[1];
        a += x;
    }
    return a;
}

/// g_solid(MANIFOLD_SOLID_BREP id) -> a kernel body (once), NONE
fn gSolid(id: u32) u32 {
    const e = eGet(id) orelse return NONE;
    if (e.aux != 0) return e.aux - 1;
    // (name, shell) / (name, outer, voids)
    const sh = eGet(nRef(eArg(e, 1))) orelse return NONE;
    // CLOSED_SHELL(name, (faces))
    const faces = eArg(sh, 1);
    const n = nCount(faces);
    br.bbBegin();
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const f = gFace(nRef(pArg(faces, k)));
        if (@as(i32, @bitCast(f)) < 0) return NONE;
    }
    const b = br.bbEnd();
    e.aux = b +% 1;
    return b;
}

// ---- products, placements, colours -------------------------------------------------------
const MAXREL = 4096;
const Frame = [4]V3; // O X Y Z
var rl_child: [MAXREL]u32 = undefined; // assembly relations: child rep,
var rl_parent: [MAXREL]u32 = undefined; //  parent rep, the transform
var rl_t: [MAXREL]Frame = undefined;
var rl_n: u32 = 0;
var sr_a: [MAXREL]u32 = undefined; // rep links without a transform
var sr_b: [MAXREL]u32 = undefined;
var sr_n: u32 = 0;
var in_t: [256]Frame = undefined; // instance transforms found
var in_n: u32 = 0;
var in_budget: u32 = 0; // (port) instances() calls left: a cyclic or branching assembly ends
var sx_name: [32]u8 = undefined;
var sx_len: usize = 0;

/// t_compose: out = A after B (x -> A(B(x))): O = A(B.O), axes = A's rotation of B's
fn tCompose(A: *const Frame, B: *const Frame) Frame {
    var o: Frame = undefined;
    o[0] = nb.lin3(&A[0], &A[1], B[0][0], &A[2], B[0][1], &A[3], B[0][2]);
    for (0..3) |k| o[k + 1] = nb.lin3(null, &A[1], B[k + 1][0], &A[2], B[k + 1][1], &A[3], B[k + 1][2]);
    return o;
}

/// t_inverse: the rigid inverse: axes transposed, O = -R^T O
fn tInverse(f: *const Frame) Frame {
    var o: Frame = undefined;
    for (0..3) |c| o[1 + c] = .{ f[1][c], f[2][c], f[3][c] };
    for (0..3) |c| o[0][c] = fneg(nb.v3dot(f[0], f[1 + c]));
    return o;
}

fn tIdentity() Frame {
    return .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
}

/// relations: rl_*: every CONTEXT_DEPENDENT_SHAPE_REPRESENTATION's (child
/// rep, parent rep, transform item2 after item1 inverted); sr_*: every
/// SHAPE_REPRESENTATION_RELATIONSHIP's two reps
fn relations() void {
    rl_n = 0;
    sr_n = 0;
    var k: u32 = 0;
    while (k < sp_ne) : (k += 1) {
        const e = &sp_ents[k];
        if (e.code == T_SRR) {
            if (sr_n >= MAXREL) continue;
            sr_a[sr_n] = nRef(eArg(e, 2));
            sr_b[sr_n] = nRef(eArg(e, 3));
            sr_n += 1;
            continue;
        }
        if (e.code != T_CDSR) continue;
        if (rl_n >= MAXREL) continue;
        // (relationship, its occurrence)
        const r = eGet(nRef(eArg(e, 0))) orelse continue;
        // REPRESENTATION_RELATIONSHIP(name, desc, rep 1, rep 2)
        const rr = ePart(r, T_RR);
        if (rr == NONE) continue;
        rl_child[rl_n] = nRef(pArg(rr, 2));
        rl_parent[rl_n] = nRef(pArg(rr, 3));
        // the transformation: ITEM_DEFINED_TRANSFORMATION(name, desc, item1, item2)
        rl_t[rl_n] = tIdentity();
        const wt = ePart(r, T_RRWT);
        if (wt != NONE) {
            if (eGet(nRef(pArg(wt, 0)))) |t| {
                const f1 = gAxis(nRef(eArg(t, 2)));
                const f2 = gAxis(nRef(eArg(t, 3)));
                const inv = tInverse(&f1); // item2 after item1 inverted
                rl_t[rl_n] = tCompose(&f2, &inv);
            }
        }
        rl_n += 1;
    }
}

/// rep_of(solid id) -> the representation listing it (0: none)
fn repOf(solid: u32) u32 {
    var k: u32 = 0;
    while (k < sp_ne) : (k += 1) {
        const e = &sp_ents[k];
        if (e.code != T_ABSR and e.code != T_SR and e.code != T_MSSR) continue;
        // (name, items, context)
        const items = eArg(e, 1);
        var i: u32 = 0;
        while (true) : (i += 1) {
            const it = pArg(items, i);
            if (it == NONE) break;
            if (nRef(it) == solid) return e.id;
        }
    }
    return 0;
}

/// instances(rep, transform so far, depth): every way the rep is placed: up
/// through the assembly relations (reps linked without a transform count as
/// one) to the roots; each root's transform into in_t
fn instances(rep: u32, t: *const Frame, depth: u32) void {
    if (in_budget == 0) return;
    in_budget -= 1;
    var parents: u32 = 0;
    if (depth < 16) {
        var k: u32 = 0;
        while (k < rl_n) : (k += 1) {
            if (!repLinked(rl_child[k], rep)) continue;
            parents += 1;
            const pt = tCompose(&rl_t[k], t); // parent's: rel after ours
            instances(rl_parent[k], &pt, depth + 1);
        }
        if (parents != 0) return;
    }
    if (in_n >= 256) return;
    in_t[in_n] = t.*;
    in_n += 1;
}

/// rep_linked: the same or linked without a transform (directly)
fn repLinked(a: u32, b: u32) bool {
    if (a == b) return true;
    var k: u32 = 0;
    while (k < sr_n) : (k += 1) {
        if (sr_a[k] == a and sr_b[k] == b) return true;
        if (sr_b[k] == a and sr_a[k] == b) return true;
    }
    return false;
}

fn follow(n: u32) ?*Ent {
    return eGet(nRef(n));
}

/// copy_name(string node): sx_name, up to 31 printable characters
fn copyName(i: u32) void {
    sx_len = 0;
    if (i == NONE) return;
    const n = nGet(i);
    if (n.kind != K_STR) return;
    const s = nStr(n);
    const k = @min(s.len, 31);
    for (s[0..k]) |c| {
        if (c < ' ' or c == 0x27) continue;
        sx_name[sx_len] = c;
        sx_len += 1;
    }
}

/// solid_name(solid id, its rep): sx_name: its product's name, else its own, else "Part"
fn solidName(solid: u32, rep: u32) void {
    sx_len = 0;
    var k: u32 = 0;
    while (k < sp_ne) : (k += 1) {
        const e = &sp_ents[k];
        if (e.code != T_SDR) continue;
        // (definition, rep)
        if (!repLinked(nRef(eArg(e, 1)), rep)) continue;
        // PDS -> PD -> PDF -> PRODUCT name
        const pds = follow(eArg(e, 0)) orelse continue;
        const pd = follow(eArg(pds, 2)) orelse continue;
        if (pd.code != T_PD) continue;
        const pdf = follow(eArg(pd, 2)) orelse continue;
        const prod = follow(eArg(pdf, 2)) orelse continue;
        if (prod.code != T_PRODUCT) continue;
        copyName(eArg(prod, 1));
        if (sx_len != 0) return;
    }
    if (eGet(solid)) |e| {
        copyName(eArg(e, 0));
        if (sx_len != 0) return;
    }
    @memcpy(sx_name[0..4], "Part");
    sx_len = 4;
}

/// solid_colour(solid id) -> 0xRRGGBB from a styled item, or null
fn solidColour(solid: u32) ?u32 {
    var k: u32 = 0;
    while (k < sp_ne) : (k += 1) {
        const e = &sp_ents[k];
        if (e.code != T_STYLED and e.code != T_ORSI) continue;
        // (name, styles, item)
        if (nRef(eArg(e, 2)) != solid) continue;
        const psa = follow(pArg(eArg(e, 1), 0)) orelse continue; // styles[0] -> PSA((styles))
        const ssu = follow(pArg(eArg(psa, 0), 0)) orelse continue; // PSA -> styles[0] (SSU)
        const sss = follow(eArg(ssu, 1)) orelse continue; // SSU(side, SSS)
        const ssfa = follow(pArg(eArg(sss, 1), 0)) orelse continue; // SSS(name, (SSFA))
        const fas = follow(eArg(ssfa, 0)) orelse continue; // SSFA(FAS)
        const fasc = follow(pArg(eArg(fas, 1), 0)) orelse continue; // FAS(name, (FASC))
        const rgb = follow(eArg(fasc, 1)) orelse continue; // FASC(name, colour)
        if (rgb.code != T_RGB) continue;
        // COLOUR_RGB(name, r, g, b)
        var c: u32 = 0;
        var i: u32 = 1;
        while (i <= 3) : (i += 1) {
            var x: u32 = @bitCast(nb.cvtr(nReal(eArg(rgb, i)) * 255.0));
            if (x > 255) x = 255;
            c = (c << 8) | x;
        }
        return c;
    }
    return null;
}

/// euler(frame) -> X, Y, Z angles with R = Rz Ry Rx (floats)
fn euler(f: *const Frame) [3]f32 {
    const s = fneg(f[1][2]); // R20 = X.z: b = asin(-R20)
    var c = s * s;
    c = 1.0 - c;
    c = maxsd(c, 0);
    const b = nb.datan2(s, @sqrt(c)); // asin = atan2(s, sqrt(1 - s^2))
    const a = nb.datan2(f[2][2], f[3][2]); // a = atan2(R21, R22) = (Y.z, Z.z)
    const cc = nb.datan2(f[1][1], f[1][0]); // c = atan2(R10, R00) = (X.y, X.x)
    return .{ @floatCast(a), @floatCast(b), @floatCast(cc) };
}

// ---- import ---------------------------------------------------------------------------------
/// The objects made: their scene side (stepobj.zig) gives each instance an object.
pub const Made = struct {
    pub var hook: ?*const fn (name: []const u8, body: u32, loc: [3]f32, rot: [3]f32, color: ?u32) ?u32 = null;
    /// Between solids (how far, 0..1): true stops the import there (Esc in
    /// the window). Not the original's: it shows no progress and takes no Esc.
    pub var between: ?*const fn (frac: f32) bool = null;
};

/// step_build(import index, make objects) -> solids built (the parse is current)
fn stepBuild(imp: u32, make: bool) u32 {
    var n: u32 = 0;
    sbUnits();
    if (make) relations();
    var k: u32 = 0;
    while (k < sp_ne) : (k += 1) {
        const e = &sp_ents[k];
        if (e.code != T_MSB and e.code != T_BWV) continue;
        if (make) {
            if (Made.between) |bw| {
                if (bw(@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(sp_ne)))) break;
            }
        }
        if (!make) {
            // rebuilding: only the solids instances still use
            var i: u32 = 0;
            while (i < st_nis) : (i += 1) {
                if (st_imp[i] != imp or st_msb[i] != e.id) continue;
                st_bd[i] = gSolid(e.id);
            }
            continue;
        }
        const b = gSolid(e.id);
        if (@as(i32, @bitCast(b)) < 0) continue;
        n += 1;
        // where it is placed
        const rep = repOf(e.id);
        in_n = 0;
        in_budget = 1 << 16;
        const id = tIdentity();
        instances(rep, &id, 0);
        solidName(e.id, rep);
        const col = solidColour(e.id);
        // its tessellation
        bt.bt_tol = 0;
        bt.bdTess(b);
        // an object per instance
        var j: u32 = 0;
        while (j < in_n) : (j += 1) {
            const t = &in_t[j];
            const loc: [3]f32 = .{ @floatCast(t[0][0]), @floatCast(t[0][1]), @floatCast(t[0][2]) };
            const h = Made.hook orelse break;
            const uid = h(sx_name[0..sx_len], b, loc, euler(t), col) orelse break;
            // kept for brep() and re-building
            if (st_nis < MAXIS) {
                st_uid[st_nis] = uid;
                st_imp[st_nis] = imp;
                st_msb[st_nis] = e.id;
                st_bd[st_nis] = b;
                st_nis += 1;
            }
        }
    }
    return n;
}

/// step_import(file text, owned by us from now on) -> solids imported (-1: unreadable)
pub fn stepImport(text: []u8) i32 {
    const k = st_nimp;
    if (k >= MAXIMP) return -1;
    br.init();
    if (spParse(text) == 0) return -1;
    st_text[k] = text; // kept
    st_nimp += 1;
    return @intCast(stepBuild(k, true));
}

/// st_rebuild: the imported solids made again (after the kernel's reset)
pub fn stRebuild() void {
    var k: u32 = 0;
    while (k < st_nimp) : (k += 1) {
        if (spParse(st_text[k]) == 0) continue;
        _ = stepBuild(k, false);
    }
}

/// st_body(object uid) -> its imported solid, or NONE
pub fn stBody(uid: u32) u32 {
    var i: u32 = 0;
    while (i < st_nis) : (i += 1) {
        if (st_uid[i] == uid) return st_bd[i];
    }
    return NONE;
}

// ---- tests -----------------------------------------------------------------------------------
test "reals: the x87's m 10^e" {
    const T = std.testing;
    try T.expectEqual(@as(f64, 1.5), x87Real(15, -1));
    try T.expectEqual(@as(f64, 0.1), x87Real(1, -1));
    try T.expectEqual(@as(f64, 1.0e-300), x87Real(1, -300));
}

// A box with a round hole, 2 x 1 x 0.5 mm, as the original exports it
// (cad.kernel on, a pad; scene in millimetres).
const box_step =
    \\ISO-10303-21;
    \\HEADER;
    \\FILE_DESCRIPTION(('BeeModel B-rep'),'2;1');
    \\FILE_NAME('box.step','2026-10-14T00:00:00',(''),(''),'BeeModel','BeeModel','');
    \\FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));
    \\ENDSEC;
    \\DATA;
    \\#1=APPLICATION_CONTEXT('automotive design');
    \\#2=APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,#1);
    \\#3=PRODUCT_CONTEXT('',#1,'mechanical');
    \\#4=PRODUCT_DEFINITION_CONTEXT('part definition',#1,'design');
    \\#5=(LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.));
    \\#6=(NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.));
    \\#7=(NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT());
    \\#8=UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),#5,'distance_accuracy_value','confusion accuracy');
    \\#9=(GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#8)) GLOBAL_UNIT_ASSIGNED_CONTEXT((#5,#6,#7)) REPRESENTATION_CONTEXT('Context3D','3D Context with UNIT and UNCERTAINTY'));
    \\#10=CARTESIAN_POINT('',(1.2500000000000000E+00,4.9999999999999994E-01,0.));
    \\#11=VERTEX_POINT('',#10);
    \\#12=CARTESIAN_POINT('',(7.5000000000000000E-01,5.0000000000000000E-01,0.));
    \\#13=VERTEX_POINT('',#12);
    \\#14=CARTESIAN_POINT('',(1.0000000000000000E+00,5.0000000000000000E-01,0.));
    \\#15=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#16=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#17=AXIS2_PLACEMENT_3D('',#14,#15,#16);
    \\#18=CIRCLE('',#17,2.5000000000000000E-01);
    \\#19=EDGE_CURVE('',#11,#13,#18,.F.);
    \\#20=ORIENTED_EDGE('',*,*,#19,.T.);
    \\#21=CARTESIAN_POINT('',(7.5000000000000000E-01,5.0000000000000000E-01,5.0000000000000000E-01));
    \\#22=VERTEX_POINT('',#21);
    \\#23=CARTESIAN_POINT('',(7.5000000000000000E-01,5.0000000000000000E-01,0.));
    \\#24=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#25=VECTOR('',#24,1.0000000000000000E+00);
    \\#26=LINE('',#23,#25);
    \\#27=EDGE_CURVE('',#13,#22,#26,.T.);
    \\#28=ORIENTED_EDGE('',*,*,#27,.T.);
    \\#29=CARTESIAN_POINT('',(1.2500000000000000E+00,4.9999999999999994E-01,5.0000000000000000E-01));
    \\#30=VERTEX_POINT('',#29);
    \\#31=CARTESIAN_POINT('',(1.0000000000000000E+00,5.0000000000000000E-01,5.0000000000000000E-01));
    \\#32=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#33=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#34=AXIS2_PLACEMENT_3D('',#31,#32,#33);
    \\#35=CIRCLE('',#34,2.5000000000000000E-01);
    \\#36=EDGE_CURVE('',#30,#22,#35,.F.);
    \\#37=ORIENTED_EDGE('',*,*,#36,.F.);
    \\#38=CARTESIAN_POINT('',(1.2500000000000000E+00,4.9999999999999994E-01,0.));
    \\#39=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#40=VECTOR('',#39,1.0000000000000000E+00);
    \\#41=LINE('',#38,#40);
    \\#42=EDGE_CURVE('',#11,#30,#41,.T.);
    \\#43=ORIENTED_EDGE('',*,*,#42,.F.);
    \\#44=EDGE_LOOP('',(#20,#28,#37,#43));
    \\#45=FACE_OUTER_BOUND('',#44,.T.);
    \\#46=CARTESIAN_POINT('',(1.0000000000000000E+00,5.0000000000000000E-01,0.));
    \\#47=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#48=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#49=AXIS2_PLACEMENT_3D('',#46,#47,#48);
    \\#50=CYLINDRICAL_SURFACE('',#49,2.5000000000000000E-01);
    \\#51=ADVANCED_FACE('',(#45),#50,.F.);
    \\#52=CARTESIAN_POINT('',(1.0000000000000000E+00,5.0000000000000000E-01,0.));
    \\#53=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#54=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#55=AXIS2_PLACEMENT_3D('',#52,#53,#54);
    \\#56=CIRCLE('',#55,2.5000000000000000E-01);
    \\#57=EDGE_CURVE('',#13,#11,#56,.F.);
    \\#58=ORIENTED_EDGE('',*,*,#57,.T.);
    \\#59=ORIENTED_EDGE('',*,*,#42,.T.);
    \\#60=CARTESIAN_POINT('',(1.0000000000000000E+00,5.0000000000000000E-01,5.0000000000000000E-01));
    \\#61=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#62=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#63=AXIS2_PLACEMENT_3D('',#60,#61,#62);
    \\#64=CIRCLE('',#63,2.5000000000000000E-01);
    \\#65=EDGE_CURVE('',#22,#30,#64,.F.);
    \\#66=ORIENTED_EDGE('',*,*,#65,.F.);
    \\#67=ORIENTED_EDGE('',*,*,#27,.F.);
    \\#68=EDGE_LOOP('',(#58,#59,#66,#67));
    \\#69=FACE_OUTER_BOUND('',#68,.T.);
    \\#70=CARTESIAN_POINT('',(1.0000000000000000E+00,5.0000000000000000E-01,0.));
    \\#71=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#72=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#73=AXIS2_PLACEMENT_3D('',#70,#71,#72);
    \\#74=CYLINDRICAL_SURFACE('',#73,2.5000000000000000E-01);
    \\#75=ADVANCED_FACE('',(#69),#74,.F.);
    \\#76=CARTESIAN_POINT('',(0.,0.,0.));
    \\#77=VERTEX_POINT('',#76);
    \\#78=CARTESIAN_POINT('',(2.0000000000000000E+00,0.,0.));
    \\#79=VERTEX_POINT('',#78);
    \\#80=CARTESIAN_POINT('',(0.,0.,0.));
    \\#81=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#82=VECTOR('',#81,1.0000000000000000E+00);
    \\#83=LINE('',#80,#82);
    \\#84=EDGE_CURVE('',#77,#79,#83,.T.);
    \\#85=ORIENTED_EDGE('',*,*,#84,.T.);
    \\#86=CARTESIAN_POINT('',(2.0000000000000000E+00,0.,5.0000000000000000E-01));
    \\#87=VERTEX_POINT('',#86);
    \\#88=CARTESIAN_POINT('',(2.0000000000000000E+00,0.,0.));
    \\#89=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#90=VECTOR('',#89,1.0000000000000000E+00);
    \\#91=LINE('',#88,#90);
    \\#92=EDGE_CURVE('',#79,#87,#91,.T.);
    \\#93=ORIENTED_EDGE('',*,*,#92,.T.);
    \\#94=CARTESIAN_POINT('',(0.,0.,5.0000000000000000E-01));
    \\#95=VERTEX_POINT('',#94);
    \\#96=CARTESIAN_POINT('',(0.,0.,5.0000000000000000E-01));
    \\#97=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#98=VECTOR('',#97,1.0000000000000000E+00);
    \\#99=LINE('',#96,#98);
    \\#100=EDGE_CURVE('',#95,#87,#99,.T.);
    \\#101=ORIENTED_EDGE('',*,*,#100,.F.);
    \\#102=CARTESIAN_POINT('',(0.,0.,0.));
    \\#103=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#104=VECTOR('',#103,1.0000000000000000E+00);
    \\#105=LINE('',#102,#104);
    \\#106=EDGE_CURVE('',#77,#95,#105,.T.);
    \\#107=ORIENTED_EDGE('',*,*,#106,.F.);
    \\#108=EDGE_LOOP('',(#85,#93,#101,#107));
    \\#109=FACE_OUTER_BOUND('',#108,.T.);
    \\#110=CARTESIAN_POINT('',(0.,0.,0.));
    \\#111=DIRECTION('',(0.,-1.0000000000000000E+00,0.));
    \\#112=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#113=AXIS2_PLACEMENT_3D('',#110,#111,#112);
    \\#114=PLANE('',#113);
    \\#115=ADVANCED_FACE('',(#109),#114,.T.);
    \\#116=CARTESIAN_POINT('',(2.0000000000000000E+00,1.0000000000000000E+00,0.));
    \\#117=VERTEX_POINT('',#116);
    \\#118=CARTESIAN_POINT('',(2.0000000000000000E+00,0.,0.));
    \\#119=DIRECTION('',(0.,1.0000000000000000E+00,0.));
    \\#120=VECTOR('',#119,1.0000000000000000E+00);
    \\#121=LINE('',#118,#120);
    \\#122=EDGE_CURVE('',#79,#117,#121,.T.);
    \\#123=ORIENTED_EDGE('',*,*,#122,.T.);
    \\#124=CARTESIAN_POINT('',(2.0000000000000000E+00,1.0000000000000000E+00,5.0000000000000000E-01));
    \\#125=VERTEX_POINT('',#124);
    \\#126=CARTESIAN_POINT('',(2.0000000000000000E+00,1.0000000000000000E+00,0.));
    \\#127=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#128=VECTOR('',#127,1.0000000000000000E+00);
    \\#129=LINE('',#126,#128);
    \\#130=EDGE_CURVE('',#117,#125,#129,.T.);
    \\#131=ORIENTED_EDGE('',*,*,#130,.T.);
    \\#132=CARTESIAN_POINT('',(2.0000000000000000E+00,0.,5.0000000000000000E-01));
    \\#133=DIRECTION('',(0.,1.0000000000000000E+00,0.));
    \\#134=VECTOR('',#133,1.0000000000000000E+00);
    \\#135=LINE('',#132,#134);
    \\#136=EDGE_CURVE('',#87,#125,#135,.T.);
    \\#137=ORIENTED_EDGE('',*,*,#136,.F.);
    \\#138=ORIENTED_EDGE('',*,*,#92,.F.);
    \\#139=EDGE_LOOP('',(#123,#131,#137,#138));
    \\#140=FACE_OUTER_BOUND('',#139,.T.);
    \\#141=CARTESIAN_POINT('',(2.0000000000000000E+00,0.,0.));
    \\#142=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#143=DIRECTION('',(0.,1.0000000000000000E+00,0.));
    \\#144=AXIS2_PLACEMENT_3D('',#141,#142,#143);
    \\#145=PLANE('',#144);
    \\#146=ADVANCED_FACE('',(#140),#145,.T.);
    \\#147=CARTESIAN_POINT('',(0.,1.0000000000000000E+00,0.));
    \\#148=VERTEX_POINT('',#147);
    \\#149=CARTESIAN_POINT('',(2.0000000000000000E+00,1.0000000000000000E+00,0.));
    \\#150=DIRECTION('',(-1.0000000000000000E+00,0.,0.));
    \\#151=VECTOR('',#150,1.0000000000000000E+00);
    \\#152=LINE('',#149,#151);
    \\#153=EDGE_CURVE('',#117,#148,#152,.T.);
    \\#154=ORIENTED_EDGE('',*,*,#153,.T.);
    \\#155=CARTESIAN_POINT('',(0.,1.0000000000000000E+00,5.0000000000000000E-01));
    \\#156=VERTEX_POINT('',#155);
    \\#157=CARTESIAN_POINT('',(0.,1.0000000000000000E+00,0.));
    \\#158=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#159=VECTOR('',#158,1.0000000000000000E+00);
    \\#160=LINE('',#157,#159);
    \\#161=EDGE_CURVE('',#148,#156,#160,.T.);
    \\#162=ORIENTED_EDGE('',*,*,#161,.T.);
    \\#163=CARTESIAN_POINT('',(2.0000000000000000E+00,1.0000000000000000E+00,5.0000000000000000E-01));
    \\#164=DIRECTION('',(-1.0000000000000000E+00,0.,0.));
    \\#165=VECTOR('',#164,1.0000000000000000E+00);
    \\#166=LINE('',#163,#165);
    \\#167=EDGE_CURVE('',#125,#156,#166,.T.);
    \\#168=ORIENTED_EDGE('',*,*,#167,.F.);
    \\#169=ORIENTED_EDGE('',*,*,#130,.F.);
    \\#170=EDGE_LOOP('',(#154,#162,#168,#169));
    \\#171=FACE_OUTER_BOUND('',#170,.T.);
    \\#172=CARTESIAN_POINT('',(2.0000000000000000E+00,1.0000000000000000E+00,0.));
    \\#173=DIRECTION('',(0.,1.0000000000000000E+00,0.));
    \\#174=DIRECTION('',(-1.0000000000000000E+00,0.,0.));
    \\#175=AXIS2_PLACEMENT_3D('',#172,#173,#174);
    \\#176=PLANE('',#175);
    \\#177=ADVANCED_FACE('',(#171),#176,.T.);
    \\#178=CARTESIAN_POINT('',(0.,1.0000000000000000E+00,0.));
    \\#179=DIRECTION('',(0.,-1.0000000000000000E+00,0.));
    \\#180=VECTOR('',#179,1.0000000000000000E+00);
    \\#181=LINE('',#178,#180);
    \\#182=EDGE_CURVE('',#148,#77,#181,.T.);
    \\#183=ORIENTED_EDGE('',*,*,#182,.T.);
    \\#184=ORIENTED_EDGE('',*,*,#106,.T.);
    \\#185=CARTESIAN_POINT('',(0.,1.0000000000000000E+00,5.0000000000000000E-01));
    \\#186=DIRECTION('',(0.,-1.0000000000000000E+00,0.));
    \\#187=VECTOR('',#186,1.0000000000000000E+00);
    \\#188=LINE('',#185,#187);
    \\#189=EDGE_CURVE('',#156,#95,#188,.T.);
    \\#190=ORIENTED_EDGE('',*,*,#189,.F.);
    \\#191=ORIENTED_EDGE('',*,*,#161,.F.);
    \\#192=EDGE_LOOP('',(#183,#184,#190,#191));
    \\#193=FACE_OUTER_BOUND('',#192,.T.);
    \\#194=CARTESIAN_POINT('',(0.,1.0000000000000000E+00,0.));
    \\#195=DIRECTION('',(-1.0000000000000000E+00,0.,0.));
    \\#196=DIRECTION('',(0.,-1.0000000000000000E+00,0.));
    \\#197=AXIS2_PLACEMENT_3D('',#194,#195,#196);
    \\#198=PLANE('',#197);
    \\#199=ADVANCED_FACE('',(#193),#198,.T.);
    \\#200=ORIENTED_EDGE('',*,*,#182,.F.);
    \\#201=ORIENTED_EDGE('',*,*,#153,.F.);
    \\#202=ORIENTED_EDGE('',*,*,#122,.F.);
    \\#203=ORIENTED_EDGE('',*,*,#84,.F.);
    \\#204=EDGE_LOOP('',(#200,#201,#202,#203));
    \\#205=FACE_OUTER_BOUND('',#204,.T.);
    \\#206=ORIENTED_EDGE('',*,*,#57,.F.);
    \\#207=ORIENTED_EDGE('',*,*,#19,.F.);
    \\#208=EDGE_LOOP('',(#206,#207));
    \\#209=FACE_BOUND('',#208,.T.);
    \\#210=CARTESIAN_POINT('',(0.,0.,0.));
    \\#211=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#212=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#213=AXIS2_PLACEMENT_3D('',#210,#211,#212);
    \\#214=PLANE('',#213);
    \\#215=ADVANCED_FACE('',(#205,#209),#214,.F.);
    \\#216=ORIENTED_EDGE('',*,*,#100,.T.);
    \\#217=ORIENTED_EDGE('',*,*,#136,.T.);
    \\#218=ORIENTED_EDGE('',*,*,#167,.T.);
    \\#219=ORIENTED_EDGE('',*,*,#189,.T.);
    \\#220=EDGE_LOOP('',(#216,#217,#218,#219));
    \\#221=FACE_OUTER_BOUND('',#220,.T.);
    \\#222=ORIENTED_EDGE('',*,*,#36,.T.);
    \\#223=ORIENTED_EDGE('',*,*,#65,.T.);
    \\#224=EDGE_LOOP('',(#222,#223));
    \\#225=FACE_BOUND('',#224,.T.);
    \\#226=CARTESIAN_POINT('',(0.,0.,5.0000000000000000E-01));
    \\#227=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#228=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#229=AXIS2_PLACEMENT_3D('',#226,#227,#228);
    \\#230=PLANE('',#229);
    \\#231=ADVANCED_FACE('',(#221,#225),#230,.T.);
    \\#232=CLOSED_SHELL('',(#51,#75,#115,#146,#177,#199,#215,#231));
    \\#233=MANIFOLD_SOLID_BREP('Box',#232);
    \\#234=CARTESIAN_POINT('',(0.,0.,0.));
    \\#235=DIRECTION('',(0.,0.,1.0000000000000000E+00));
    \\#236=DIRECTION('',(1.0000000000000000E+00,0.,0.));
    \\#237=AXIS2_PLACEMENT_3D('',#234,#235,#236);
    \\#238=ADVANCED_BREP_SHAPE_REPRESENTATION('',(#233,#237),#9);
    \\#239=PRODUCT('Box','Box','',(#3));
    \\#240=PRODUCT_RELATED_PRODUCT_CATEGORY('part',$,(#239));
    \\#241=PRODUCT_DEFINITION_FORMATION('','',#239);
    \\#242=PRODUCT_DEFINITION('design','',#241,#4);
    \\#243=PRODUCT_DEFINITION_SHAPE('','',#242);
    \\#244=SHAPE_DEFINITION_REPRESENTATION(#243,#238);
    \\#245=COLOUR_RGB('',7.0588235294117652E-01,7.2156862745098038E-01,7.5294117647058822E-01);
    \\#246=FILL_AREA_STYLE_COLOUR('',#245);
    \\#247=FILL_AREA_STYLE('',(#246));
    \\#248=SURFACE_STYLE_FILL_AREA(#247);
    \\#249=SURFACE_SIDE_STYLE('',(#248));
    \\#250=SURFACE_STYLE_USAGE(.BOTH.,#249);
    \\#251=PRESENTATION_STYLE_ASSIGNMENT((#250));
    \\#252=STYLED_ITEM('color',(#251),#233);
    \\#253=MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION('',(#252),#9);
    \\ENDSEC;
    \\END-ISO-10303-21;
;

var test_bodies: [4]u32 = undefined;
var test_n: usize = 0;
fn testHook(name: []const u8, body: u32, loc: [3]f32, rot: [3]f32, color: ?u32) ?u32 {
    _ = name;
    _ = loc;
    _ = rot;
    _ = color;
    test_bodies[test_n] = body;
    test_n += 1;
    return @intCast(test_n);
}

test "a box with a hole: the body the original builds (its brep() values)" {
    const T = std.testing;
    const text = try std.testing.allocator.dupe(u8, box_step ++ "\n");
    defer std.testing.allocator.free(text);
    Made.hook = testHook;
    test_n = 0;
    st_nimp = 0;
    st_nis = 0;
    const n = stepImport(text);
    try T.expectEqual(@as(i32, 1), n);
    try T.expectEqual(@as(usize, 1), test_n);
    const b = test_bodies[0];
    // the original: volume 0.901825, area 7.392699, 8 faces, 1016 triangles,
    // 18 edges, 12 vertices (scene in metres here: the file's mm as 0.001)
    const v = br.bdVolume(b) * 1e9;
    const a = br.bdArea(b) * 1e6;
    try T.expect(@abs(v - 0.901825) < 5e-7);
    try T.expect(@abs(a - 7.392699) < 5e-7);
    try T.expectEqual(@as(u32, 0), br.bdCheck(b));
    try T.expectEqual(@as(u32, 8), br.bs_f);
    try T.expectEqual(@as(u32, 18), br.bs_e);
    try T.expectEqual(@as(u32, 12), br.bs_v);
    const ts = bt.bdTri(b).?;
    try T.expectEqual(@as(u32, 1016), ts.nt);
    st_nimp = 0;
    st_nis = 0;
}

const deep_parens = blk: {
    var b: [1000]u8 = undefined;
    @memset(&b, '(');
    break :blk b;
};

test "damaged text: no crash, no solid" {
    const T = std.testing;
    Made.hook = testHook;
    const cases = [_][]const u8{
        "",
        "DATA;",
        "ISO-10303-21;\nDATA;\n#1=X(" ++ &deep_parens,
        "ISO-10303-21;\nDATA;\n#1=VECTOR('',#1,1.);\n#2=LINE('',#3,#1);\n#3=CARTESIAN_POINT('',(0.,0.,0.));\n",
        "ISO-10303-21;\nDATA;\n#4294967295=CARTESIAN_POINT('',(1.E999,0.,0.));\n",
    };
    for (cases) |c| {
        st_nimp = 0;
        st_nis = 0;
        test_n = 0;
        const text = try std.testing.allocator.dupe(u8, c);
        defer std.testing.allocator.free(text);
        const r = stepImport(text);
        try T.expect(r <= 0);
        try T.expectEqual(@as(usize, 0), test_n);
    }
    st_nimp = 0;
}

test "stepread compiles" {
    std.testing.refAllDecls(@This());
}
