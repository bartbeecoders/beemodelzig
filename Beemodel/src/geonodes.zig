// Geometry nodes (geonodes.s): node trees that make or change meshes.
//
// A Geometry Nodes modifier runs a tree (ntree.zig) on the mesh below it in the
// stack. Geometry flows from the Group Input (that mesh) through primitives,
// transforms, joins, set position, extrusion, subdivision, booleans and merging
// to the Group Output; each node's mesh is made once per evaluation. Fields - a
// value or vector per point - come from position, normal, index, value,
// combine / separate, math, vector math, noise and random nodes: the subgraph
// feeding an input compiles to a program for the field VM (fieldvm.zig), which
// runs it over the points in blocks.
//
// The types (1..39): group input, group output, grid, cube, UV sphere,
// cylinder, mesh line, transform, join geometry, set position, extrude mesh,
// subdivision surface, mesh boolean, merge by distance, realize instances;
// position, normal, index, value, combine XYZ, separate XYZ, math, vector math,
// noise texture, random value; group (another tree run as one node: its Group
// Input gives the group node's geometry, value and vector - fields cross the
// boundary - and its Group Output the result; groups nest 8 deep); distribute
// points on faces (by area and density, a seed, an optional minimum distance;
// the points keep their faces' normals), instance on points (another geometry
// placed at every point: aligned to the point's normal or up, a fixed or
// random turn about it, a scale field - instances stay instances, inst.zig,
// until realized); curve line, curve circle, curve to mesh, resample, trim,
// fillet and curve to points (curve.zig: a curve is a chain of 2-point
// polygons); terrain, terrace, erosion and L-system (procgen.zig).
//
// A mesh here is a Geo: the original's mesh with what geometry nodes read of it
// (positions, polygons, the edit selection, point normals, instances),
// reference counted as the original's meshes are (a node's result is kept for
// the evaluation and may be another node's input as it is).
//
// Deliberate differences from the original:
//   * Extrude Mesh's result is a finished mesh: the original returns it without
//     its triangles (build_extrude_ind does not call mesh_finish), so it shows
//     nothing, exports no triangles and scatters no points.
//   * Mesh Boolean is the Boolean modifier's (boolean.run: the original's faults
//     fixed, as the port's modifier has them).
const std = @import("std");
const m = @import("math.zig");
const nt = @import("ntree.zig");
const fv = @import("fieldvm.zig");
const inst = @import("inst.zig");
const jobs = @import("jobs.zig");
const pmesh = @import("pmesh.zig");
const A = @import("alloc.zig").A;

pub const V3 = m.V3;
pub const PMesh = pmesh.PMesh;
const Rec = nt.Rec;

pub const NTYPES = 39;
pub const LEVELS = 8;
pub const NT_MAXN = nt.NT_MAXN;
const NODE_SZ = nt.NODE_SZ;
const ND_TYPE = nt.ND_TYPE;
const ND_IN = nt.ND_IN;
const ND_P = nt.ND_P;
const ND_POS = nt.ND_POS;
const GR_N = nt.GR_N;
const GR_NODES = nt.GR_NODES;

pub const T_GIN = 1;
pub const T_GOUT = 2;
pub const T_GRID = 3;
pub const T_CUBE = 4;
pub const T_SPHERE = 5;
pub const T_CYL = 6;
pub const T_LINE = 7;
pub const T_XFORM = 8;
pub const T_JOIN = 9;
pub const T_SETPOS = 10;
pub const T_EXTRUDE = 11;
pub const T_SUBD = 12;
pub const T_BOOL = 13;
pub const T_MERGE = 14;
pub const T_REALIZE = 15;
pub const T_POS = 16;
pub const T_NORMAL = 17;
pub const T_INDEX = 18;
pub const T_VALUE = 19;
pub const T_COMBINE = 20;
pub const T_SEP = 21;
pub const T_MATH = 22;
pub const T_VMATH = 23;
pub const T_NOISE = 24;
pub const T_RANDOM = 25;
pub const T_GROUP = 26;
pub const T_DIST = 27;
pub const T_INST = 28;
pub const T_CLINE = 29;
pub const T_CCIRCLE = 30;
pub const T_C2MESH = 31;
pub const T_RESAMPLE = 32;
pub const T_TRIM = 33;
pub const T_FILLET = 34;
pub const T_C2PTS = 35;
pub const T_TERRAIN = 36;
pub const T_TERRACE = 37;
pub const T_ERODE = 38;
pub const T_LSYS = 39;

const GC_MAXI = 512;
const GC_MAXR = 64;

// --- the node types (gn_type_names, gn_titles, gn_meta, gn_defaults) ------------------------

/// The words tree.node takes (gn_type_names), type k + 1 at k.
pub const type_names = [NTYPES][]const u8{
    "input",        "output",       "grid",        "cube",          "sphere",    "cylinder",      "line",
    "transform",    "join",         "set_position", "extrude",      "subdivide", "boolean",       "merge",
    "realize",      "position",     "normal",      "index",         "value",     "combine_xyz",   "separate_xyz",
    "math",         "vector_math",  "noise",       "random",        "group",     "distribute",    "instance",
    "curve_line",   "curve_circle", "curve_to_mesh", "resample",    "trim",      "fillet",        "curve_to_points",
    "terrain",      "terrace",      "erode",       "lsystem",
};

/// gn_titles: as the node editor heads them.
pub const titles = [NTYPES][]const u8{
    "Group Input",    "Group Output",   "Grid",          "Cube",           "UV Sphere",     "Cylinder",
    "Mesh Line",      "Transform",      "Join Geometry", "Set Position",   "Extrude Mesh",  "Subdivision Surface",
    "Mesh Boolean",   "Merge by Distance", "Realize Instances", "Position", "Normal",        "Index",
    "Value",          "Combine XYZ",    "Separate XYZ",  "Math",           "Vector Math",   "Noise Texture",
    "Random Value",   "Group",          "Distribute Points on Faces", "Instance on Points", "Curve Line", "Curve Circle",
    "Curve to Mesh",  "Resample Curve", "Trim Curve",    "Fillet Curve",   "Curve to Points", "Terrain",
    "Terrace",        "Erosion",        "L-System",
};

/// gn_meta: what the node editor reads of a type: input names and kinds (0
/// geometry, 1 value, 2 vector), value names and kinds (0 number, 1 choice, 3
/// whole, 4 a tree), the choices, output names and kinds.
pub const Meta = struct {
    in: [3]?[]const u8 = .{ null, null, null },
    in_k: [4]u8 = .{ 0, 0, 0, 0 },
    val: [4]?[]const u8 = .{ null, null, null, null },
    val_k: [4]u8 = .{ 0, 0, 0, 0 },
    choices: []const []const u8 = &.{},
    out: [3]?[]const u8 = .{ null, null, null },
    out_k: [4]u8 = .{ 0, 0, 0, 0 },
};

const ch_bool = [_][]const u8{ "Union", "Difference", "Intersect" };
const ch_math = [_][]const u8{ "Add", "Subtract", "Multiply", "Divide", "Power", "Minimum", "Maximum", "Less Than", "Greater Than", "Sine", "Cosine", "Absolute", "Square Root", "Floor", "Modulo" };
const ch_vmath = [_][]const u8{ "Add", "Subtract", "Multiply", "Scale", "Cross Product", "Dot Product", "Length", "Normalize", "Distance", "Mix" };
const ch_rot = [_][]const u8{ "Fixed", "Random" };
const ch_lsys = [_][]const u8{ "Plant", "Bush", "Tree", "Koch Island" };

const geo3 = [3]?[]const u8{ "Geometry", null, null };
const mesh3 = [3]?[]const u8{ "Mesh", null, null };
const curve3 = [3]?[]const u8{ "Curve", null, null };

pub const meta = [NTYPES]Meta{
    .{ .out = .{ "Geometry", "Value", "Vector" }, .out_k = .{ 0, 1, 2, 0 } }, // group input
    .{ .in = geo3 }, // group output
    .{ .val = .{ "Size", "Subdivisions", null, null }, .val_k = .{ 0, 3, 0, 0 }, .out = mesh3 }, // grid
    .{ .val = .{ "Size", null, null, null }, .out = mesh3 }, // cube
    .{ .val = .{ "Radius", null, null, null }, .out = mesh3 }, // sphere
    .{ .val = .{ "Radius", "Depth", null, null }, .out = mesh3 }, // cylinder
    .{ .val = .{ "Count", "Offset X", "Offset Y", "Offset Z" }, .val_k = .{ 3, 0, 0, 0 }, .out = mesh3 }, // line
    .{ .in = .{ "Geometry", "Translation", "Scale" }, .in_k = .{ 0, 2, 2, 0 }, .val = .{ "Rotate X", "Rotate Y", "Rotate Z", null }, .out = geo3 }, // transform
    .{ .in = .{ "Geometry", "Geometry", "Geometry" }, .out = geo3 }, // join
    .{ .in = .{ "Geometry", "Selection", "Offset" }, .in_k = .{ 0, 1, 2, 0 }, .out = geo3 }, // set position
    .{ .in = .{ "Mesh", "Selection", null }, .in_k = .{ 0, 1, 0, 0 }, .val = .{ "Distance", null, null, null }, .out = mesh3 }, // extrude
    .{ .in = mesh3, .val = .{ "Level", null, null, null }, .val_k = .{ 3, 0, 0, 0 }, .out = mesh3 }, // subdivide
    .{ .in = .{ "Mesh A", "Mesh B", null }, .val = .{ "Operation", null, null, null }, .val_k = .{ 1, 0, 0, 0 }, .choices = &ch_bool, .out = mesh3 }, // boolean
    .{ .in = geo3, .val = .{ "Distance", null, null, null }, .out = geo3 }, // merge
    .{ .in = geo3, .out = geo3 }, // realize
    .{ .out = .{ "Position", null, null }, .out_k = .{ 2, 2, 2, 0 } }, // position
    .{ .out = .{ "Normal", null, null }, .out_k = .{ 2, 2, 2, 0 } }, // normal
    .{ .out = .{ "Index", null, null }, .out_k = .{ 1, 1, 1, 0 } }, // index
    .{ .val = .{ "Value", null, null, null }, .out = .{ "Value", null, null }, .out_k = .{ 1, 1, 1, 0 } }, // value
    .{ .in = .{ "X", "Y", "Z" }, .in_k = .{ 1, 1, 1, 0 }, .out = .{ "Vector", null, null }, .out_k = .{ 2, 2, 2, 0 } }, // combine
    .{ .in = .{ "Vector", null, null }, .in_k = .{ 2, 2, 2, 0 }, .out = .{ "X", "Y", "Z" }, .out_k = .{ 1, 1, 1, 0 } }, // separate
    .{ .in = .{ "A", "B", null }, .in_k = .{ 1, 1, 1, 0 }, .val = .{ "Operation", null, null, null }, .val_k = .{ 1, 0, 0, 0 }, .choices = &ch_math, .out = .{ "Value", null, null }, .out_k = .{ 1, 1, 1, 0 } }, // math
    .{ .in = .{ "A", "B", "Factor" }, .in_k = .{ 2, 2, 1, 0 }, .val = .{ "Operation", null, null, null }, .val_k = .{ 1, 0, 0, 0 }, .choices = &ch_vmath, .out = .{ "Vector", "Value", null }, .out_k = .{ 2, 1, 0, 0 } }, // vector math
    .{ .in = .{ "Vector", null, null }, .in_k = .{ 2, 2, 2, 0 }, .val = .{ "Scale", "Detail", "Roughness", null }, .out = .{ "Fac", "Color", null }, .out_k = .{ 1, 2, 0, 0 } }, // noise
    .{ .val = .{ "Min", "Max", "Seed", null }, .out = .{ "Value", null, null }, .out_k = .{ 1, 1, 1, 0 } }, // random
    .{ .in = .{ "Geometry", "Value", "Vector" }, .in_k = .{ 0, 1, 2, 0 }, .val = .{ "Tree", null, null, null }, .val_k = .{ 4, 0, 0, 0 }, .out = geo3 }, // group
    .{ .in = mesh3, .val = .{ "Density", "Seed", "Distance Min", null }, .val_k = .{ 0, 3, 0, 0 }, .out = .{ "Points", null, null } }, // distribute
    .{ .in = .{ "Points", "Instance", "Scale" }, .in_k = .{ 0, 0, 1, 0 }, .val = .{ "Rotation", "Align", "Seed", null }, .val_k = .{ 1, 1, 3, 0 }, .choices = &ch_rot, .out = .{ "Instances", null, null } }, // instance
    .{ .in = .{ "Start", "End", null }, .in_k = .{ 2, 2, 0, 0 }, .out = curve3 }, // curve line
    .{ .val = .{ "Resolution", "Radius", null, null }, .val_k = .{ 3, 0, 0, 0 }, .out = curve3 }, // curve circle
    .{ .in = .{ "Curve", "Profile Curve", null }, .val = .{ "Radius", "Sides", "Fill Caps", null }, .val_k = .{ 0, 3, 3, 0 }, .out = mesh3 }, // curve to mesh
    .{ .in = curve3, .val = .{ "Count", "Length", null, null }, .val_k = .{ 3, 0, 0, 0 }, .out = curve3 }, // resample
    .{ .in = curve3, .val = .{ "Start", "End", null, null }, .out = curve3 }, // trim
    .{ .in = curve3, .val = .{ "Radius", "Count", null, null }, .val_k = .{ 0, 3, 0, 0 }, .out = curve3 }, // fillet
    .{ .in = curve3, .val = .{ "Count", null, null, null }, .val_k = .{ 3, 0, 0, 0 }, .out = .{ "Points", null, null } }, // curve to points
    .{ .in = .{ "Noise (scale, detail, ridged)", null, null }, .in_k = .{ 2, 0, 0, 0 }, .val = .{ "Size", "Resolution", "Height", "Seed" }, .val_k = .{ 0, 3, 0, 3 }, .out = mesh3 }, // terrain
    .{ .in = mesh3, .val = .{ "Steps", "Smooth", null, null }, .val_k = .{ 3, 0, 0, 0 }, .out = mesh3 }, // terrace
    .{ .in = mesh3, .val = .{ "Droplets", "Strength", "Seed", null }, .val_k = .{ 3, 0, 3, 0 }, .out = mesh3 }, // erode
    .{ .val = .{ "Preset", "Iterations", "Radius", "Step" }, .val_k = .{ 1, 3, 0, 0 }, .choices = &ch_lsys, .out = curve3 }, // l-system
};

/// gn_defaults: per type 4 values, then the 3 inputs' x y z.
pub const defaults = [NTYPES][13]f32{
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // input
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // output
    .{ 2, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // grid
    .{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // cube
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // sphere
    .{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // cylinder
    .{ 10, 0, 0.5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // line
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1 }, // transform
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // join
    .{ 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0 }, // set position
    .{ 0.2, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0 }, // extrude
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // subdivide
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // boolean
    .{ 0.001, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // merge
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // realize
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // position
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // normal
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // index
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // value
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // combine
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // separate
    .{ 0, 0, 0, 0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0, 0, 0 }, // math
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1 }, // vector math
    .{ 5, 2, 0.5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // noise
    .{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // random
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // group
    .{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // distribute
    .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1 }, // instance
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 }, // curve line
    .{ 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // curve circle
    .{ 0.1, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // curve to mesh
    .{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // resample
    .{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // trim
    .{ 0.25, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // fillet
    .{ 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // curve to points
    .{ 10, 64, 2, 0, 2, 6, 0, 0, 0, 0, 0, 0, 0 }, // terrain
    .{ 6, 0.3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // terrace
    .{ 20000, 0.3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // erode
    .{ 0, 4, 0, 0.1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // l-system
};

/// gn_type_index: the type (1..) a word names, or null.
pub fn typeIndex(w: []const u8) ?u32 {
    for (type_names, 0..) |n, k| {
        if (std.mem.eql(u8, n, w)) return @intCast(k + 1);
    }
    return null;
}

/// gn_meta_row: a type's row, or null.
pub fn metaOf(t: u32) ?*const Meta {
    if (t == 0 or t > NTYPES) return null;
    return &meta[t - 1];
}

// --- a mesh (the original's, as geometry nodes see it) ------------------------------------

pub const Geo = struct {
    refs: u32 = 1,
    verts: []V3 = &.{},
    /// faces + 1 offsets (poff[0] == 0)
    poff: []u32 = &.{},
    loops: []u32 = &.{},
    /// ME_VSEL: a byte a vertex (empty: none selected)
    vsel: []u8 = &.{},
    /// ME_PNRM: point normals (empty: none)
    pnrm: []V3 = &.{},
    /// ME_INST: instances (a reference)
    inst: ?*inst.Block = null,
    /// ME_TRIS: the triangles (ear_tris) as mesh_finish made them - where the
    /// corners were when it was finished; a copy keeps them (made when asked)
    tris: ?[][3]u32 = null,

    pub fn faces(g: *const Geo) u32 {
        return if (g.poff.len == 0) 0 else @intCast(g.poff.len - 1);
    }
    pub fn view(g: *const Geo) PMesh {
        return .{ .verts = g.verts, .poff = g.poff, .loops = g.loops };
    }
};

/// A new mesh of these arrays (taken over); null when out of memory (they go).
pub fn geoOf(verts: []V3, poff: []u32, loops: []u32) ?*Geo {
    const g = A.create(Geo) catch {
        A.free(verts);
        A.free(poff);
        A.free(loops);
        return null;
    };
    g.* = .{ .verts = verts, .poff = poff, .loops = loops };
    return g;
}

/// A mesh made from a PMesh (taken over).
pub fn geoFromP(p: PMesh) ?*Geo {
    if (p.poff.len == 0) {
        const o = A.alloc(u32, 1) catch {
            p.deinit(A);
            return null;
        };
        o[0] = 0;
        A.free(p.poff);
        return geoOf(p.verts, o, p.loops);
    }
    return geoOf(p.verts, p.poff, p.loops);
}

/// A copy of a PMesh's arrays as a mesh.
pub fn geoCopyP(p: PMesh) ?*Geo {
    const c = p.clone(A) catch return null;
    return geoFromP(c);
}

pub fn ref(g: ?*Geo) void {
    if (g) |x| x.refs += 1;
}

/// mesh_unref: the last reference frees it (and its instances).
pub fn unref(g: ?*Geo) void {
    const x = g orelse return;
    x.refs -= 1;
    if (x.refs != 0) return;
    A.free(x.verts);
    A.free(x.poff);
    A.free(x.loops);
    if (x.vsel.len > 0) A.free(x.vsel);
    if (x.pnrm.len > 0) A.free(x.pnrm);
    if (x.tris) |t| A.free(t);
    inst.unref(x.inst);
    A.destroy(x);
}

/// mesh_copy: an independent copy (selection, point normals; instances shared).
/// (the triangles come along as they are: mesh_copy copies ME_TRIS, made where
/// the corners were when the source was finished)
pub fn copy(g: *Geo) ?*Geo {
    const st = trisOf(g);
    const v = A.dupe(V3, g.verts) catch return null;
    const o = A.dupe(u32, g.poff) catch {
        A.free(v);
        return null;
    };
    const l = A.dupe(u32, g.loops) catch {
        A.free(v);
        A.free(o);
        return null;
    };
    const c = geoOf(v, o, l) orelse return null;
    if (g.vsel.len > 0) c.vsel = A.dupe(u8, g.vsel) catch &.{};
    if (g.pnrm.len > 0) c.pnrm = A.dupe(V3, g.pnrm) catch &.{};
    c.inst = g.inst;
    inst.ref(c.inst);
    if (st.len > 0) c.tris = A.dupe([3]u32, st) catch null;
    return c;
}

/// An empty mesh (no vertices, no polygons).
pub fn empty() ?*Geo {
    const o = A.alloc(u32, 1) catch return null;
    o[0] = 0;
    return geoOf(A.alloc(V3, 0) catch unreachable, o, A.alloc(u32, 0) catch unreachable);
}

// --- mesh_finish's triangles (ear_tris) -----------------------------------------------------

/// flat3: three vertices (nearly) in a line.
fn flat3(verts: []const V3, ai: u32, bi: u32, ci: u32) bool {
    const a = verts[ai];
    const u = m.sub(verts[bi], a);
    const w = m.sub(verts[ci], a);
    var x = u[1] * w[2] - u[2] * w[1];
    x *= x;
    var y = u[2] * w[0] - u[0] * w[2];
    y *= y;
    var z = u[0] * w[1] - u[1] * w[0];
    z *= z;
    const l = x + y + z;
    const uu = u[0] * u[0] + u[1] * u[1] + u[2] * u[2];
    const ww = w[0] * w[0] + w[1] * w[1] + w[2] * w[2];
    const r = uu * ww * 1.0e-10;
    return !(l > r);
}

/// The mesh's triangles as mesh_finish makes them: the fan of each polygon,
/// except that a flat ear (three corners in a line) waits until it is not flat.
pub fn trisOf(g: *Geo) []const [3]u32 {
    if (g.tris) |t| return t;
    var n: usize = 0;
    for (0..g.faces()) |p| {
        const k = g.poff[p + 1] - g.poff[p];
        if (k >= 3) n += k - 2;
    }
    const out = A.alloc([3]u32, n) catch return &.{};
    var t: usize = 0;
    var c: [256]u32 = undefined;
    for (0..g.faces()) |p| {
        const idx = g.loops[g.poff[p]..g.poff[p + 1]];
        if (idx.len < 4 or idx.len > 256) {
            var i: usize = 1;
            while (i + 1 < idx.len) : (i += 1) {
                out[t] = .{ idx[0], idx[i], idx[i + 1] };
                t += 1;
            }
            continue;
        }
        var k = idx.len;
        @memcpy(c[0..k], idx);
        var tip: usize = 1;
        var flats: usize = 0;
        while (k > 3 and flats < k) {
            if (tip >= k) tip = 0;
            const pv = (tip + k - 1) % k;
            const nx = (tip + 1) % k;
            if (flat3(g.verts, c[pv], c[tip], c[nx])) {
                tip += 1;
                flats += 1;
                continue;
            }
            out[t] = .{ c[pv], c[tip], c[nx] };
            t += 1;
            std.mem.copyForwards(u32, c[tip .. k - 1], c[tip + 1 .. k]);
            k -= 1;
            flats = 0;
        }
        var i: usize = 1;
        while (i + 1 < k) : (i += 1) {
            out[t] = .{ c[0], c[i], c[i + 1] };
            t += 1;
        }
    }
    g.tris = out[0..t];
    return g.tris.?;
}

// --- primitives (mesh.s), as the original makes them --------------------------------------

const Build = struct {
    v: std.ArrayList(V3) = .empty,
    o: std.ArrayList(u32) = .empty,
    l: std.ArrayList(u32) = .empty,

    fn init() !Build {
        var b = Build{};
        try b.o.append(A, 0);
        return b;
    }
    fn vert(b: *Build, p: V3) !void {
        try b.v.append(A, p);
    }
    fn poly(b: *Build, idx: []const u32) !void {
        try b.l.appendSlice(A, idx);
        try b.o.append(A, @intCast(b.l.items.len));
    }
    fn deinit(b: *Build) void {
        b.v.deinit(A);
        b.o.deinit(A);
        b.l.deinit(A);
    }
    fn done(b: *Build) ?*Geo {
        const v = b.v.toOwnedSlice(A) catch return fail(b);
        const o = b.o.toOwnedSlice(A) catch {
            A.free(v);
            return fail(b);
        };
        const l = b.l.toOwnedSlice(A) catch {
            A.free(v);
            A.free(o);
            return fail(b);
        };
        return geoOf(v, o, l);
    }
    fn fail(b: *Build) ?*Geo {
        b.deinit();
        return null;
    }
};

fn fi(x: anytype) f32 {
    return @floatFromInt(x);
}

/// prim_grid_n: 2 x 2 m on the XZ plane, n x n quads facing up.
fn primGrid(n: u32) ?*Geo {
    var b = Build.init() catch return null;
    errdefer b.deinit();
    var r: u32 = 0;
    while (r <= n) : (r += 1) {
        var c: u32 = 0;
        while (c <= n) : (c += 1) {
            var x = fi(c);
            x += x;
            x /= fi(n);
            x -= 1;
            var z = fi(r);
            z += z;
            z /= fi(n);
            z -= 1;
            b.vert(.{ x, 0, z }) catch return b.fail();
        }
    }
    r = 0;
    while (r < n) : (r += 1) {
        var c: u32 = 0;
        while (c < n) : (c += 1) {
            const a = r * (n + 1) + c;
            b.poly(&.{ a, a + n + 1, a + n + 2, a + 1 }) catch return b.fail();
        }
    }
    return b.done();
}

/// prim_cube: 2 m, six quads.
fn primCube() ?*Geo {
    const cv = [_]V3{ .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, -1, 1 }, .{ -1, -1, 1 }, .{ -1, 1, -1 }, .{ 1, 1, -1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } };
    const cf = [_]u32{ 0, 1, 2, 3, 7, 6, 5, 4, 0, 4, 5, 1, 1, 5, 6, 2, 2, 6, 7, 3, 3, 7, 4, 0 };
    var b = Build.init() catch return null;
    b.v.appendSlice(A, &cv) catch return b.fail();
    var k: usize = 0;
    while (k < 6) : (k += 1) b.poly(cf[k * 4 ..][0..4]) catch return b.fail();
    return b.done();
}

const mf_2pi: f32 = 6.2831853;
const mf_pi: f32 = 3.1415927;

/// ring_vert: a vertex on a circle (i of n, radius r, at height y).
fn ringVert(b: *Build, i: u32, n: u32, r: f32, y: f32) !void {
    var a = fi(i);
    a /= fi(n);
    a *= mf_2pi;
    const sc = fv.x87sincos(a);
    try b.vert(.{ sc[1] * r, y, sc[0] * r });
}

/// prim_cylinder: 32 segments, radius 1, height 2.
fn primCylinder() ?*Geo {
    var b = Build.init() catch return null;
    for (0..32) |k| ringVert(&b, @intCast(k), 32, 1, -1) catch return b.fail();
    for (0..32) |k| ringVert(&b, @intCast(k), 32, 1, 1) catch return b.fail();
    for (0..32) |k| {
        const a: u32 = @intCast(k);
        const nx: u32 = (a + 1) % 32;
        b.poly(&.{ a, a + 32, nx + 32, nx }) catch return b.fail();
    }
    var cap: [32]u32 = undefined;
    for (0..32) |c| cap[c] = @intCast(c);
    b.poly(&cap) catch return b.fail();
    for (0..32) |c| cap[c] = @intCast(63 - c);
    b.poly(&cap) catch return b.fail();
    return b.done();
}

/// prim_uvsphere: 32 segments x 16 rings, radius 1.
fn primSphere() ?*Geo {
    var b = Build.init() catch return null;
    b.vert(.{ 0, 1, 0 }) catch return b.fail();
    var r: u32 = 1;
    while (r < 16) : (r += 1) {
        var a = fi(r);
        a *= mf_pi;
        a /= 16.0;
        const sc = fv.x87sincos(a);
        for (0..32) |k| ringVert(&b, @intCast(k), 32, sc[0], sc[1]) catch return b.fail();
    }
    b.vert(.{ 0, -1, 0 }) catch return b.fail();
    for (0..32) |k| {
        const a: u32 = @intCast(k);
        b.poly(&.{ 0, ((a + 1) & 31) + 1, a + 1 }) catch return b.fail();
    }
    for (0..14) |rr| {
        const base: u32 = @as(u32, @intCast(rr)) * 32 + 1;
        for (0..32) |k| {
            const a: u32 = @intCast(k);
            const c = (a + 1) & 31;
            b.poly(&.{ base + a, base + c, base + c + 32, base + a + 32 }) catch return b.fail();
        }
    }
    for (0..32) |k| {
        const a: u32 = @intCast(k);
        const c = (a + 1) & 31;
        b.poly(&.{ 14 * 32 + 1 + a, 14 * 32 + 1 + c, 15 * 32 + 1 }) catch return b.fail();
    }
    return b.done();
}

// --- the evaluation (gn_eval) ---------------------------------------------------------------

const Save = struct {
    res: [NT_MAXN]?*Geo,
    rec: *const Rec,
    inmesh: ?*Geo,
};

/// The evaluation's state (the original's globals).
var g_rec: *const Rec = undefined;
var g_inmesh: ?*Geo = null;
var g_res: [NT_MAXN]?*Geo = @splat(null);
var g_depth: u32 = 0;
var g_level: u32 = 0;
var g_save: [LEVELS]Save = undefined;
var g_ctx_rec: [LEVELS]*const Rec = undefined;
var g_ctx_node: [LEVELS]u32 = @splat(0);

fn rd32(r: *const Rec, o: usize) u32 {
    return nt.rd32(r, o);
}
fn rdf(r: *const Rec, o: usize) f32 {
    return nt.rdf(r, o);
}
fn nodeOff(k: u32) usize {
    return GR_NODES + @as(usize, k - 1) * NODE_SZ;
}
fn nodeCount(r: *const Rec) u32 {
    return rd32(r, GR_N);
}
/// Value k (0..3) of node `nd` (its offset).
fn val(nd: usize, k: usize) f32 {
    return rdf(g_rec, nd + ND_P + k * 4);
}
/// Input i's constant, component c.
fn inConst(r: *const Rec, nd: usize, i: usize, c: usize) f32 {
    return rdf(r, nd + ND_IN + i * 16 + 4 + c * 4);
}

/// The last evaluation's time (BEEMODEL_GN_TIME=1 logs each).
pub var last_ns: u64 = 0;
var timing: ?bool = null;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// gn_eval: the tree's result on `in` (borrowed), a new reference, or null: no
/// tree, no output, or the result is the mesh itself.
pub fn eval(in: *Geo, tree: u32) ?*Geo {
    const t0 = nowNs();
    defer {
        last_ns = nowNs() - t0;
        if (timing == null) timing = @import("spawn.zig").getenv("BEEMODEL_GN_TIME") != null;
        if (timing.?) app.log("  geometry nodes: {d:.3} ms", .{@as(f64, @floatFromInt(last_ns)) / 1e6});
    }
    g_inmesh = in;
    if (tree == 0) return null;
    const r = nt.get(tree - 1) orelse return null;
    g_rec = r;
    g_res = @splat(null);
    g_level = 0;
    var k: u32 = 0;
    const n = nodeCount(r);
    var out: ?*Geo = null;
    while (k < n and k < NT_MAXN) : (k += 1) {
        if (rd32(r, nodeOff(k + 1) + ND_TYPE) == T_GOUT) break;
    } else return null;
    out = inputGeo(k + 1, 0);
    for (&g_res) |*x| {
        unref(x.*);
        x.* = null;
    }
    if (out == g_inmesh) {
        unref(out);
        return null;
    }
    return out;
}

/// gn_input_geo: the mesh fed to input i (0..2) of node k (1..), a new
/// reference, or null.
fn inputGeo(k: u32, i: u32) ?*Geo {
    const w = std.mem.readInt(u16, g_rec[nodeOff(k) + ND_IN + i * 16 ..][0..2], .little);
    if (w == 0 or w > nodeCount(g_rec)) return null;
    return geoOfNode(w);
}

/// gn_geo: node k's mesh (a new reference), or null.
fn geoOfNode(k: u32) ?*Geo {
    if (g_res[k - 1]) |have| {
        ref(have);
        return have;
    }
    if (g_depth >= 64) return null;
    g_depth += 1;
    const r = make(k);
    g_depth -= 1;
    g_res[k - 1] = r; // (remembered: its own reference)
    if (r) |x| ref(x);
    return r;
}

fn keep(g: ?*Geo) ?*Geo {
    ref(g);
    return g;
}

/// A mesh scaled by x y z (mesh_bbox after).
fn scaled(g: ?*Geo, s: V3) ?*Geo {
    const x = g orelse return null;
    _ = trisOf(x); // (finished before it is scaled: its triangles where it was made)
    for (x.verts) |*p| {
        p[0] *= s[0];
        p[1] *= s[1];
        p[2] *= s[2];
    }
    return x;
}

/// What node k makes (a new reference) - .Lgg_* in geonodes.s.
fn make(k: u32) ?*Geo {
    const nd = nodeOff(k);
    const t = rd32(g_rec, nd + ND_TYPE);
    switch (t) {
        T_GIN => return keep(g_inmesh),
        T_GRID => {
            const n: u32 = @intCast(std.math.clamp(fv.cvtt(val(nd, 1)), 1, 1000));
            const h = val(nd, 0) * 0.5;
            return scaled(primGrid(n), .{ h, 1, h });
        },
        T_CUBE => {
            const h = val(nd, 0) * 0.5;
            return scaled(primCube(), .{ h, h, h });
        },
        T_SPHERE => {
            const r = val(nd, 0);
            return scaled(primSphere(), .{ r, r, r });
        },
        T_CYL => {
            const r = val(nd, 0);
            return scaled(primCylinder(), .{ r, val(nd, 1) * 0.5, r });
        },
        T_LINE => return line(nd),
        T_XFORM => return transform(k, nd),
        T_JOIN => return join(k),
        T_SETPOS => return setPosition(k),
        T_EXTRUDE => return extrude(k, nd),
        T_SUBD => {
            const in = inputGeo(k, 0) orelse return null;
            const lv = fv.cvtt(val(nd, 0));
            if (lv <= 0) return in;
            const r = @import("subsurf.zig").subdivide(A, in.view(), @intCast(@min(lv, 6))) catch return in;
            const g = geoFromP(r) orelse return in;
            unref(in);
            return g;
        },
        T_BOOL => return booleanNode(k, nd),
        T_MERGE => {
            const in = inputGeo(k, 0) orelse return null;
            const g = mergeDist(in, val(nd, 0)) orelse return in;
            unref(in);
            return g;
        },
        T_REALIZE => {
            const in = inputGeo(k, 0) orelse return null;
            if (in.inst == null) return in;
            const g = inst.realize(in);
            unref(in);
            return g;
        },
        T_GROUP => {
            const in = inputGeo(k, 0);
            const g = groupEval(nt.cvtt(val(nd, 0)), k, in) orelse return in; // (no such tree, too deep: through)
            unref(in);
            return g;
        },
        T_DIST => {
            const in = inputGeo(k, 0) orelse return null;
            const g = distribute(in, nd);
            unref(in);
            return g;
        },
        T_INST => {
            const pts = inputGeo(k, 0) orelse return null;
            const proto = inputGeo(k, 1) orelse return pts;
            const g = instance(pts, proto, k, nd);
            unref(pts);
            unref(proto);
            return g;
        },
        T_CLINE, T_CCIRCLE, T_C2MESH, T_RESAMPLE, T_TRIM, T_FILLET, T_C2PTS => return curveNode(k, nd, t),
        T_TERRAIN, T_TERRACE, T_ERODE, T_LSYS => return procNode(k, nd, t),
        else => return null,
    }
}

fn line(nd: usize) ?*Geo {
    const n: u32 = @intCast(std.math.clamp(fv.cvtt(val(nd, 0)), 1, 1000000));
    const v = A.alloc(V3, n) catch return null;
    for (v, 0..) |*p, i| {
        const f = fi(i);
        p.* = .{ val(nd, 1) * f, val(nd, 2) * f, val(nd, 3) * f };
    }
    const o = A.alloc(u32, 1) catch {
        A.free(v);
        return null;
    };
    o[0] = 0;
    return geoOf(v, o, A.alloc(u32, 0) catch unreachable);
}

/// gn_matrix: R(z) R(y) R(x) S, then T (inputs: translation 2, scale 3; values:
/// degrees), 3 rows of 4.
pub fn matrixOf(r: *const Rec, nd: usize) [12]f32 {
    var s: [3]f32 = undefined;
    var c: [3]f32 = undefined;
    for (0..3) |i| {
        const a = rdf(r, nd + ND_P + i * 4) * 0.017453292;
        const sc = fv.x87sincos(a);
        s[i] = sc[0];
        c[i] = sc[1];
    }
    const sx = s[0];
    const cx = c[0];
    const sy = s[1];
    const cy = c[1];
    const sz = s[2];
    const cz = c[2];
    var o: [12]f32 = undefined;
    o[0] = cy * cz;
    o[1] = sx * sy * cz - cx * sz;
    o[2] = cx * sy * cz + sx * sz;
    o[4] = cy * sz;
    o[5] = sx * sy * sz + cx * cz;
    o[6] = cx * sy * sz - sx * cz;
    o[8] = 0 - sy;
    o[9] = sx * cy;
    o[10] = cx * cy;
    for (0..3) |row| {
        o[row * 4] = inConst(r, nd, 2, 0) * o[row * 4];
        o[row * 4 + 1] = inConst(r, nd, 2, 1) * o[row * 4 + 1];
        o[row * 4 + 2] = inConst(r, nd, 2, 2) * o[row * 4 + 2];
        o[row * 4 + 3] = inConst(r, nd, 1, row);
    }
    return o;
}

/// p by a 3x4 (row . p + t).
pub fn xf(mt: *const [12]f32, p: V3) V3 {
    var o: V3 = undefined;
    for (0..3) |row| {
        var x = mt[row * 4] * p[0];
        x += mt[row * 4 + 1] * p[1];
        x += mt[row * 4 + 2] * p[2];
        x += mt[row * 4 + 3];
        o[row] = x;
    }
    return o;
}

fn transform(k: u32, nd: usize) ?*Geo {
    const in = inputGeo(k, 0) orelse return null;
    const g = copy(in);
    unref(in);
    const x = g orelse return null;
    const mt = matrixOf(g_rec, nd);
    for (x.verts) |*p| p.* = xf(&mt, p.*);
    if (x.inst) |b| { // (instances: placed by it too)
        const nb = inst.xform(b, &mt);
        inst.unref(b);
        x.inst = nb;
    }
    return x;
}

/// mesh_append: one mesh holding both (b's vertices after a's; polygons of
/// more than 8192 corners left out).
pub fn append(a: *const Geo, b: *const Geo) ?*Geo {
    var bl = Build.init() catch return null;
    for ([2]*const Geo{ a, b }, 0..) |s, w| {
        const off: u32 = if (w == 0) 0 else @intCast(a.verts.len);
        bl.v.appendSlice(A, s.verts) catch return bl.fail();
        for (0..s.faces()) |p| {
            const idx = s.loops[s.poff[p]..s.poff[p + 1]];
            if (idx.len > 8192) continue;
            for (idx) |x| bl.l.append(A, x + off) catch return bl.fail();
            bl.o.append(A, @intCast(bl.l.items.len)) catch return bl.fail();
        }
    }
    return bl.done();
}

fn join(k: u32) ?*Geo {
    var r: ?*Geo = null;
    for (0..3) |i| {
        const g = inputGeo(k, @intCast(i)) orelse continue;
        if (r == null) {
            r = g;
            continue;
        }
        const a = r.?;
        const nx = append(a, g);
        if (nx) |x| x.inst = inst.merge(a.inst, g.inst); // (instances: both lists)
        unref(a);
        unref(g);
        r = nx;
    }
    return r;
}

fn setPosition(k: u32) ?*Geo {
    const in = inputGeo(k, 0) orelse return null;
    const g = copy(in);
    unref(in);
    const x = g orelse return null;
    var f: Fields = undefined;
    if (!fields(x, k, 1, 2, &f)) return x;
    defer f.deinit();
    for (x.verts, 0..) |*p, i| {
        if (!(f.v[0][i] > 0.5)) continue;
        p[0] = f.v[1][i] + p[0];
        p[1] = f.v[2][i] + p[1];
        p[2] = f.v[3][i] + p[2];
    }
    return x;
}

fn extrude(k: u32, nd: usize) ?*Geo {
    const in = inputGeo(k, 0) orelse return null;
    const g = copy(in);
    unref(in);
    const x = g orelse return null;
    var f: Fields = undefined;
    if (!fields(x, k, 1, -1, &f)) return x;
    defer f.deinit();
    if (x.vsel.len != x.verts.len) {
        if (x.vsel.len > 0) A.free(x.vsel);
        x.vsel = A.alloc(u8, x.verts.len) catch return x;
    }
    for (x.vsel, 0..) |*s, i| s.* = @intFromBool(f.v[0][i] > 0.5);
    const r = extrudeInd(x, val(nd, 0)) orelse return x;
    unref(x);
    return r;
}

/// build_extrude_ind: every selected face (all its corners selected) moves
/// out along its own normal, with side walls.
fn extrudeInd(g: *const Geo, dist: f32) ?*Geo {
    var b = Build.init() catch return null;
    b.v.appendSlice(A, g.verts) catch return b.fail();
    var sel: std.ArrayList(u8) = .empty;
    defer sel.deinit(A);
    sel.appendNTimes(A, 0, g.verts.len) catch return b.fail();
    var scr: std.ArrayList(u32) = .empty;
    defer scr.deinit(A);
    for (0..g.faces()) |p| {
        const idx = g.loops[g.poff[p]..g.poff[p + 1]];
        var all = true;
        for (idx) |v| {
            if (g.vsel[v] == 0) all = false;
        }
        if (!all) {
            b.poly(idx) catch return b.fail();
            continue;
        }
        // poly_normal (Newell), normalize (unchanged when ~0)
        var nrm: V3 = .{ 0, 0, 0 };
        for (idx, 0..) |a, q| {
            const c = g.verts[a];
            const nx = g.verts[idx[if (q + 1 < idx.len) q + 1 else 0]];
            nrm[0] += (c[1] - nx[1]) * (c[2] + nx[2]);
            nrm[1] += (c[2] - nx[2]) * (c[0] + nx[0]);
            nrm[2] += (c[0] - nx[0]) * (c[1] + nx[1]);
        }
        var l2 = nrm[0] * nrm[0];
        l2 += nrm[1] * nrm[1];
        l2 += nrm[2] * nrm[2];
        if (l2 > 1.0e-12) {
            const inv = 1.0 / @sqrt(l2);
            nrm = .{ nrm[0] * inv, nrm[1] * inv, nrm[2] * inv };
        }
        const n = idx.len;
        if (n > 65536 / 2) continue;
        scr.resize(A, 2 * n) catch return b.fail();
        for (idx, 0..) |a, q| {
            const c = g.verts[a];
            const np: V3 = .{ nrm[0] * dist + c[0], nrm[1] * dist + c[1], nrm[2] * dist + c[2] };
            b.vert(np) catch return b.fail();
            sel.append(A, 1) catch return b.fail();
            scr.items[n + q] = @intCast(b.v.items.len - 1);
        }
        for (0..n) |q| {
            const q1 = if (q + 1 < n) q + 1 else 0;
            b.poly(&.{ idx[q], idx[q1], scr.items[n + q1], scr.items[n + q] }) catch return b.fail();
        }
        b.poly(scr.items[n .. 2 * n]) catch return b.fail();
    }
    const r = b.done() orelse return null;
    r.vsel = sel.toOwnedSlice(A) catch &.{};
    return r;
}

fn booleanNode(k: u32, nd: usize) ?*Geo {
    const a = inputGeo(k, 0);
    const b = inputGeo(k, 1);
    const x = a orelse return b;
    const y = b orelse return x;
    const opi = fv.cvtt(val(nd, 0));
    const op: @import("boolean.zig").Op = if (opi == 0) .union_ else if (opi == 2) .intersect else .difference;
    const r = @import("boolean.zig").run(A, x.view(), y.view(), op) catch {
        unref(y); // (failed: A as it was)
        return x;
    };
    const g = geoFromP(r) orelse {
        unref(y);
        return x;
    };
    unref(x);
    unref(y);
    return g;
}

/// mesh_merge_dist: vertices within `dist` welded (the first one within it),
/// corners that repeat and faces without area dropped, duplicates dropped,
/// unused vertices gone (repair.s).
pub fn mergeDist(g: *const Geo, dist: f32) ?*Geo {
    const fm = @import("fmesh.zig");
    const r = fm.mergeDist(A, g.verts, g.poff, g.loops, dist) catch return null;
    const x = r orelse return null;
    return geoOf(x.verts, x.poff, x.loops);
}

fn curveNode(k: u32, nd: usize, t: u32) ?*Geo {
    const cv = @import("curve.zig");
    const node = g_rec[nd..][0..NODE_SZ];
    switch (t) {
        T_CLINE => return geoFromP(cv.cnLine(A, node) orelse return null),
        T_CCIRCLE => return geoFromP(cv.cnCircle(A, node) orelse return null),
        T_C2MESH => {
            const c = inputGeo(k, 0) orelse return null;
            const p = inputGeo(k, 1);
            const r = cv.cnToMesh(A, c.view(), if (p) |x| x.view() else null, node);
            unref(c);
            unref(p);
            return geoFromP(r orelse return null);
        },
        T_C2PTS => {
            const c = inputGeo(k, 0) orelse return null;
            defer unref(c);
            const pts = cv.cnPoints(A, c.view(), node) orelse return null;
            const o = A.alloc(u32, 1) catch {
                pts.deinit(A);
                return null;
            };
            o[0] = 0;
            const g = geoOf(pts.verts, o, A.alloc(u32, 0) catch unreachable) orelse {
                A.free(pts.nrm);
                return null;
            };
            g.pnrm = pts.nrm;
            return g;
        },
        else => {
            const c = inputGeo(k, 0) orelse return null;
            defer unref(c);
            const r = switch (t) {
                T_RESAMPLE => cv.cnResample(A, c.view(), node),
                T_TRIM => cv.cnTrim(A, c.view(), node),
                else => cv.cnFillet(A, c.view(), node),
            };
            return geoFromP(r orelse return null);
        },
    }
}

/// The generators (procgen.zig: tg_terrain, tg_terrace, tg_erode, tg_lsystem):
/// the node's values, Terrain its first input's constant too (scale, detail,
/// ridged; a link there is not read, as the original).
fn procNode(k: u32, nd: usize, t: u32) ?*Geo {
    const pg = @import("procgen.zig");
    var p: [4]f32 = undefined;
    var in: [4]f32 = undefined;
    for (0..4) |q| {
        p[q] = rdf(g_rec, nd + ND_P + q * 4);
        in[q] = rdf(g_rec, nd + ND_IN + q * 4);
    }
    switch (t) {
        T_TERRAIN => {
            const r = pg.terrainNode(A, &p, &in) catch return null;
            return geoOf(r.verts, r.poff, r.loops);
        },
        T_LSYS => return geoFromP(pg.lsystemNode(A, &p) orelse return null),
        else => {
            const src = inputGeo(k, 0) orelse return null;
            defer unref(src);
            const b = @import("fmesh.zig").bbox(src.verts);
            const sm = pg.M{ .verts = src.verts, .poff = src.poff, .loops = src.loops, .bmin = b[0], .bmax = b[1] };
            const r = (if (t == T_TERRACE) pg.terraceNode(A, &sm, &p) else pg.erodeNode(A, &sm, &p)) catch return null;
            return geoOf(r.verts, r.poff, r.loops);
        },
    }
}

/// gn_group_eval: tree `tree1` (its place + 1) run as group node `node`, with
/// `in` its input mesh: the inner tree's result (a new reference) or null.
fn groupEval(tree1: i32, node: u32, in: ?*Geo) ?*Geo {
    if (tree1 <= 0) return null;
    if (g_level >= LEVELS - 1) return null;
    const r = nt.get(@intCast(tree1 - 1)) orelse return null;
    if (r == g_rec) return null; // (itself: never)
    g_save[g_level] = .{ .res = g_res, .rec = g_rec, .inmesh = g_inmesh };
    g_ctx_rec[g_level + 1] = g_rec;
    g_ctx_node[g_level + 1] = node;
    g_level += 1;
    g_rec = r;
    g_inmesh = in;
    g_res = @splat(null);
    var out: ?*Geo = null;
    const n = nodeCount(r);
    var k: u32 = 0;
    while (k < n and k < NT_MAXN) : (k += 1) {
        if (rd32(r, nodeOff(k + 1) + ND_TYPE) == T_GOUT) {
            out = inputGeo(k + 1, 0);
            break;
        }
    }
    for (&g_res) |*x| unref(x.*);
    g_level -= 1;
    const s = &g_save[g_level];
    g_res = s.res;
    g_rec = s.rec;
    g_inmesh = s.inmesh;
    return out;
}

// --- scattering ---------------------------------------------------------------------------

/// gn_hash: 32 mixed bits of three numbers.
pub fn hash(a: u32, b: u32, c: u32) u32 {
    var e = a *% 0x27d4eb2d;
    e ^= b *% 0x165667b1;
    e ^= c *% 0x9e3779b1;
    var x = e ^ (e >> 15);
    x *%= 0x2c1b3c6d;
    x ^= x >> 12;
    x *%= 0x297a2d39;
    x ^= x >> 15;
    return x;
}
/// gn_u01: in [0, 1).
pub fn unit01(a: u32, b: u32, c: u32) f32 {
    return fi(hash(a, b, c) >> 8) * 5.9604645e-8;
}

/// gd_tri: a triangle's corners, its unit normal, its area.
fn tri(g: *const Geo, t: [3]u32, c: *[3]V3, n: *V3) f32 {
    for (0..3) |q| c[q] = g.verts[t[q]];
    const e1: V3 = .{ c[1][0] - c[0][0], c[1][1] - c[0][1], c[1][2] - c[0][2] };
    const e2: V3 = .{ c[2][0] - c[0][0], c[2][1] - c[0][1], c[2][2] - c[0][2] };
    const nx = e1[1] * e2[2] - e1[2] * e2[1];
    const ny = e1[2] * e2[0] - e2[2] * e1[0];
    const nz = e1[0] * e2[1] - e1[1] * e2[0];
    var l = nx * nx;
    l += ny * ny;
    l += nz * nz;
    l = @sqrt(l);
    if (!(l > 1.0e-12)) l = 1.0e-12;
    const inv = 1.0 / l;
    n.* = .{ nx * inv, ny * inv, nz * inv };
    return l * 0.5;
}

const DistJob = struct {
    g: *const Geo,
    tris: []const [3]u32,
    density: f32,
    seed: u32,
    off: []u32,
    pos: []V3 = &.{},
    nrm: []V3 = &.{},
};

/// gd_count: each triangle's points: area x density, rounded by chance.
fn distCount(p: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *DistJob = @ptrCast(@alignCast(p));
    for (lo..hi) |t| {
        var c: [3]V3 = undefined;
        var n: V3 = undefined;
        const a = tri(j.g, j.tris[t], &c, &n) * j.density;
        const x = unit01(@intCast(t), j.seed, 0x51ed) + a;
        const k = fv.cvtt(x);
        j.off[t] = if (k < 0) 0 else @intCast(k);
    }
}

/// gd_job_place: each triangle's points, uniform on it, with its normal.
fn distPlace(p: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *DistJob = @ptrCast(@alignCast(p));
    for (lo..hi) |t| {
        const first = j.off[t];
        const cnt = j.off[t + 1] - first;
        if (cnt == 0) continue;
        var c: [3]V3 = undefined;
        var n: V3 = undefined;
        _ = tri(j.g, j.tris[t], &c, &n);
        const tt: u32 = @intCast(t);
        var q: u32 = 0;
        while (q < cnt) : (q += 1) {
            const r1 = unit01(tt, q, j.seed);
            const r2 = unit01(tt +% 0x3779, q, j.seed);
            const s = @sqrt(r1);
            const b1 = (1 - r2) * s;
            const b2 = r2 * s;
            const b0 = 1 - s;
            var o: V3 = undefined;
            for (0..3) |k| {
                var x = c[0][k] * b0;
                x += c[1][k] * b1;
                x += c[2][k] * b2;
                o[k] = x;
            }
            j.pos[first + q] = o;
            j.nrm[first + q] = n;
        }
    }
}

/// gn_distribute: points on the mesh's faces (no faces, point normals), or null.
fn distribute(g: *Geo, nd: usize) ?*Geo {
    const tris = trisOf(g);
    var d = val(nd, 0);
    if (!(d > 0)) d = 0;
    var j = DistJob{ .g = g, .tris = tris, .density = d, .seed = @bitCast(fv.cvtt(val(nd, 1))), .off = A.alloc(u32, tris.len + 1) catch return null };
    defer A.free(j.off);
    jobs.parallelFor(tris.len, 256, &j, distCount);
    var total: u32 = 0;
    for (0..tris.len) |t| {
        const c = j.off[t];
        j.off[t] = total;
        const s = @addWithOverflow(total, c);
        if (s[1] != 0 or s[0] > 50000000) return null; // (a bound: 50 million points)
        total = s[0];
    }
    j.off[tris.len] = total;
    j.pos = A.alloc(V3, total) catch return null;
    j.nrm = A.alloc(V3, total) catch {
        A.free(j.pos);
        return null;
    };
    jobs.parallelFor(tris.len, 64, &j, distPlace);
    var kept: usize = total;
    const md = val(nd, 2);
    if (md > 0) kept = thin(j.pos, j.nrm, md) catch total;
    const o = A.alloc(u32, 1) catch return null;
    o[0] = 0;
    const pos = A.realloc(j.pos, kept) catch j.pos[0..kept];
    const nrm = A.realloc(j.nrm, kept) catch j.nrm[0..kept];
    const out = geoOf(pos, o, A.alloc(u32, 0) catch unreachable) orelse {
        A.free(nrm);
        return null;
    };
    out.pnrm = nrm;
    return out;
}

fn bucket(x: i32, y: i32, z: i32, nb: u32) u32 {
    var h = @as(u32, @bitCast(x)) *% 0x8da6b343;
    h ^= @as(u32, @bitCast(y)) *% 0xd8163841;
    h ^= @as(u32, @bitCast(z)) *% 0xcb1ab31f;
    return h & (nb - 1);
}

/// gd_thin: points closer than d to one kept earlier dropped (a grid of cells
/// that size in a hash table); the kept ones move down. Returns how many.
fn thin(pos: []V3, nrm: []V3, d: f32) !usize {
    const n = pos.len;
    const d2 = d * d;
    const inv = 1.0 / d;
    var nb: u32 = 1;
    const want: u64 = @as(u64, n) * 2 + 16;
    while (nb < want) nb <<= 1;
    const heads = try A.alloc(i32, nb);
    defer A.free(heads);
    @memset(heads, -1);
    const next = try A.alloc(i32, n + 1);
    defer A.free(next);
    var kept: usize = 0;
    for (0..n) |i| {
        const p = pos[i];
        var cell: [3]i32 = undefined;
        for (0..3) |k| cell[k] = fv.cvtt(@floor(p[k] * inv));
        var near = false;
        cells: for (0..27) |kk| {
            const q: u32 = @intCast(kk);
            const dx: i32 = @as(i32, @intCast(q % 3)) - 1;
            const dy: i32 = @as(i32, @intCast((q / 3) % 3)) - 1;
            const dz: i32 = @as(i32, @intCast(q / 9)) - 1;
            var e = heads[bucket(cell[0] +% dx, cell[1] +% dy, cell[2] +% dz, nb)];
            while (e >= 0) {
                const o = pos[@intCast(e)];
                var dd = (o[0] - p[0]) * (o[0] - p[0]);
                dd += (o[1] - p[1]) * (o[1] - p[1]);
                dd += (o[2] - p[2]) * (o[2] - p[2]);
                if (dd < d2) {
                    near = true;
                    break :cells;
                }
                e = next[@intCast(e)];
            }
        }
        if (near) continue;
        pos[kept] = p;
        nrm[kept] = nrm[i];
        const b = bucket(cell[0], cell[1], cell[2], nb);
        next[kept] = heads[b];
        heads[b] = @intCast(kept);
        kept += 1;
    }
    return kept;
}

const InstJob = struct {
    pts: *const Geo,
    b: *inst.Block,
    scale: []const f32,
    rot: i32,
    alignn: i32,
    seed: u32,
};

/// gz_unit: normalized.
fn unit(v: V3) V3 {
    var l = v[0] * v[0];
    l += v[1] * v[1];
    l += v[2] * v[2];
    l = @sqrt(l);
    if (!(l > 1.0e-12)) l = 1.0e-12;
    const inv = 1.0 / l;
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}

/// gi_job: each point's matrix: an up axis (the point's normal, or Y), turned
/// about it (random: by the seed), scaled, at the point.
fn instJob(p: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const j: *InstJob = @ptrCast(@alignCast(p));
    const mats = j.b.mats;
    for (lo..hi) |i| {
        var up: V3 = .{ 0, 1, 0 };
        if (j.alignn != 0 and j.pts.pnrm.len > i) {
            const n = j.pts.pnrm[i];
            var l = n[0] * n[0];
            l += n[1] * n[1];
            l += n[2] * n[2];
            if (l > 1.0e-12) up = n;
        }
        var s: V3 = undefined;
        if (@abs(up[0]) >= 0.5) {
            s = .{ 0 - up[1], up[0], 0 }; // (0 0 1) x up
        } else {
            s = .{ 0, 0 - up[2], up[1] }; // (1 0 0) x up
        }
        s = unit(s);
        var t: V3 = .{ up[1] * s[2] - up[2] * s[1], up[2] * s[0] - up[0] * s[2], up[0] * s[1] - up[1] * s[0] };
        up = unit(up);
        t = unit(t);
        var ang: f32 = 0;
        if (j.rot != 0) ang = unit01(@intCast(i), j.seed, 0x7a11) * 6.2831853;
        const sc = fv.x87sincos(ang);
        var xa: V3 = undefined;
        var za: V3 = undefined;
        for (0..3) |c| {
            xa[c] = s[c] * sc[1] + t[c] * sc[0];
            za[c] = t[c] * sc[1] - s[c] * sc[0];
        }
        const f = j.scale[i];
        const pt = j.pts.verts[i];
        const mt = &mats[i];
        for (0..3) |r| {
            mt[r * 4] = xa[r] * f;
            mt[r * 4 + 1] = up[r] * f;
            mt[r * 4 + 2] = za[r] * f;
            mt[r * 4 + 3] = pt[r];
        }
    }
}

/// gn_instance: a mesh with no geometry of its own and an instance of `proto`
/// at every point, or null.
fn instance(pts: *Geo, proto: *Geo, k: u32, nd: usize) ?*Geo {
    var f: Fields = undefined;
    if (!fields(pts, k, 2, -1, &f)) return null;
    defer f.deinit();
    const n: u32 = @intCast(pts.verts.len);
    const b = inst.new(n) orelse return null;
    b.n = n;
    _ = inst.proto(b, proto);
    @memset(b.pids[0..n], 0);
    var j = InstJob{ .pts = pts, .b = b, .scale = f.v[0], .rot = fv.cvtt(val(nd, 0)), .alignn = fv.cvtt(val(nd, 1)), .seed = @bitCast(fv.cvtt(val(nd, 2))) };
    jobs.parallelFor(n, 4096, &j, instJob);
    const g = empty() orelse {
        inst.unref(b);
        return null;
    };
    g.inst = b;
    return g;
}

// --- fields --------------------------------------------------------------------------------

/// The arrays a field gives: the value per point, then x y z.
pub const Fields = struct {
    buf: []f32,
    v: [4][]f32,
    fn deinit(f: *Fields) void {
        A.free(f.buf);
    }
};

const Comp = struct {
    regs: [LEVELS * NT_MAXN * 9]u8 = @splat(0),
    prog: [GC_MAXI]fv.Ins = undefined,
    n: u32 = 0,
    r: u32 = 0,
    bad: bool = false,
    depth: u32 = 0,
    uses: u32 = 0,
    out: [3]u32 = .{ 0, 0, 0 },
    outs: [8]fv.Out = undefined,
    nout: u32 = 0,
};
var gc: Comp = .{};

/// gn_fields: the value input `vin` (0..2, or -1) and the vector input `vecin`
/// of node k compiled and run over g's points. False: it could not.
fn fields(g: *Geo, k: u32, vin: i32, vecin: i32, out: *Fields) bool {
    gc.regs = @splat(0);
    gc.n = 0;
    gc.r = 0;
    gc.bad = false;
    gc.uses = 0;
    gc.nout = 0;
    gc.depth = 0;
    const n = g.verts.len;
    const buf = A.alloc(f32, n * 4) catch return false;
    out.* = .{ .buf = buf, .v = .{ buf[0..n], buf[n .. 2 * n], buf[2 * n .. 3 * n], buf[3 * n .. 4 * n] } };
    if (vin >= 0) {
        gcInput(k, @intCast(vin), 1);
        emitOut(gc.out[0], out.v[0].ptr);
    }
    if (vecin >= 0) {
        gcInput(k, @intCast(vecin), 2);
        const o = gc.out;
        emitOut(o[0], out.v[1].ptr);
        emitOut(o[1], out.v[2].ptr);
        emitOut(o[2], out.v[3].ptr);
    }
    if (gc.bad) {
        out.deinit();
        return false;
    }
    const ok = runProgram(g, n);
    if (!ok) out.deinit();
    return ok;
}

fn runProgram(g: *Geo, n: usize) bool {
    // gn_inputs: positions, index; normals when read (points: their own)
    const in = A.alloc(f32, n * 7) catch return false;
    defer A.free(in);
    var ctx = fv.Ctx{ .n = @intCast(n), .prog = gc.prog[0..gc.n], .outs = gc.outs[0..gc.nout] };
    for (0..7) |q| ctx.in[q] = in[q * n ..].ptr;
    for (g.verts, 0..) |p, i| {
        in[i] = p[0];
        in[n + i] = p[1];
        in[2 * n + i] = p[2];
        in[6 * n + i] = fi(i);
    }
    if (gc.uses & 2 != 0) {
        const nx = in[3 * n .. 4 * n];
        const ny = in[4 * n .. 5 * n];
        const nz = in[5 * n .. 6 * n];
        if (g.pnrm.len == n and n > 0) {
            for (g.pnrm, 0..) |p, i| {
                nx[i] = p[0];
                ny[i] = p[1];
                nz[i] = p[2];
            }
        } else vnormals(g, nx, ny, nz);
    }
    return fv.run(&ctx);
}

/// gn_vnormals: each point's polygons' (Newell) normals summed, unit.
fn vnormals(g: *const Geo, nx: []f32, ny: []f32, nz: []f32) void {
    @memset(nx, 0);
    @memset(ny, 0);
    @memset(nz, 0);
    for (0..g.faces()) |p| {
        const s = g.poff[p];
        const e = g.poff[p + 1];
        var x: f32 = 0;
        var y: f32 = 0;
        var z: f32 = 0;
        var c = s;
        while (c < e) : (c += 1) {
            const a = g.verts[g.loops[c]];
            const b = g.verts[g.loops[if (c + 1 < e) c + 1 else s]];
            x += (a[1] - b[1]) * (a[2] + b[2]);
            y += (a[2] - b[2]) * (a[0] + b[0]);
            z += (a[0] - b[0]) * (a[1] + b[1]);
        }
        c = s;
        while (c < e) : (c += 1) {
            const v = g.loops[c];
            nx[v] = nx[v] + x;
            ny[v] = ny[v] + y;
            nz[v] = nz[v] + z;
        }
    }
    for (0..g.verts.len) |i| {
        var l = nx[i] * nx[i];
        l += ny[i] * ny[i];
        l += nz[i] * nz[i];
        l = @sqrt(l);
        if (!(l > 1.0e-12)) l = 1.0e-12;
        const inv = 1.0 / l;
        nx[i] *= inv;
        ny[i] *= inv;
        nz[i] *= inv;
    }
}

fn emitOut(reg: u32, dst: [*]f32) void {
    if (gc.nout >= 8) return;
    gc.outs[gc.nout] = .{ .reg = reg, .dst = dst };
    gc.nout += 1;
}

/// gc_reg: a new register (bad when out of them).
fn gcReg() u32 {
    if (gc.r >= GC_MAXR) {
        gc.bad = true;
        return 0;
    }
    gc.r += 1;
    return gc.r - 1;
}

fn gcIns(op: u8, dst: u32, a: u32, b: u32, c: u32, imm: [4]f32) void {
    if (gc.n >= GC_MAXI) {
        gc.bad = true;
        return;
    }
    gc.prog[gc.n] = .{ .op = op, .dst = @truncate(dst), .a = @truncate(a), .b = @truncate(b), .c = @truncate(c), .imm = imm };
    gc.n += 1;
}

fn gcOp(op: u8, a: u32, b: u32) u32 {
    const d = gcReg();
    gcIns(op, d, a, b, 0, .{ 0, 0, 0, 0 });
    return d;
}

fn gcConst(x: f32) u32 {
    const d = gcReg();
    gcIns(fv.OP_CONST, d, 0, 0, 0, .{ x, 0, 0, 0 });
    return d;
}

fn gcLoad(op: u8) u32 {
    const d = gcReg();
    gcIns(op, d, 0, 0, 0, .{ 0, 0, 0, 0 });
    return d;
}

/// gc_input: input i (0..2) of node k as `kind` (1 value, 2 vector): gc.out.
fn gcInput(k: u32, i: u32, kind: u32) void {
    const r = g_rec;
    const nd = nodeOff(k);
    const w = rd32(r, nd + ND_IN + i * 16);
    const from = w & 0xffff;
    if (from != 0 and from <= nodeCount(r) and gc.depth < 64) {
        gc.depth += 1;
        const got = gcOutOf(from, (w >> 16) & 0xff);
        gc.depth -= 1;
        if (got == kind) return;
        if (kind == 2) { // value -> vector: (v, v, v)
            gc.out[1] = gc.out[0];
            gc.out[2] = gc.out[0];
            return;
        }
        // vector -> value: the mean
        const s = gcOp(fv.OP_ADD, gc.out[0], gc.out[1]);
        const s2 = gcOp(fv.OP_ADD, s, gc.out[2]);
        const third = gcConst(0.33333334);
        gc.out[0] = gcOp(fv.OP_MUL, s2, third);
        return;
    }
    // unlinked: the constant (noise and its vector: the position)
    if (rd32(r, nd + ND_TYPE) == T_NOISE and i == 0) {
        gc.uses |= 1;
        gc.out[0] = gcLoad(fv.OP_PX);
        gc.out[1] = gcLoad(fv.OP_PY);
        gc.out[2] = gcLoad(fv.OP_PZ);
        return;
    }
    gc.out[0] = gcConst(inConst(r, nd, i, 0));
    if (kind != 2) return;
    gc.out[1] = gcConst(inConst(r, nd, i, 1));
    gc.out[2] = gcConst(inConst(r, nd, i, 2));
}

const mathops = [15]u8{ fv.OP_ADD, fv.OP_SUB, fv.OP_MUL, fv.OP_DIV, fv.OP_POW, fv.OP_MIN, fv.OP_MAX, fv.OP_LT, fv.OP_GT, fv.OP_SIN, fv.OP_COS, fv.OP_ABS, fv.OP_SQRT, fv.OP_FLOOR, fv.OP_MOD };

/// gc_out_of: output `o` of node k: gc.out, its kind (1 value, 2 vector);
/// compiled once per evaluation and level.
fn gcOutOf(k: u32, o0: u32) u32 {
    const o = if (o0 > 2) 0 else o0;
    const slot = g_level * NT_MAXN * 9 + (k - 1) * 9 + o * 3;
    const sl = gc.regs[slot..][0..3];
    if (sl[0] != 0) {
        gc.out[0] = sl[0] - 1;
        if (sl[1] == 0) return 1;
        gc.out[1] = sl[1] - 1;
        gc.out[2] = sl[2] - 1;
        return 2;
    }
    const r = g_rec;
    const nd = nodeOff(k);
    var res: [4]u32 = .{ 0, 0, 0, 0 };
    var vec = false;
    switch (rd32(r, nd + ND_TYPE)) {
        T_POS, T_NORMAL => |t| {
            gc.uses |= if (t == T_POS) 1 else 2;
            const base: u8 = if (t == T_POS) fv.OP_PX else fv.OP_NX;
            res[0] = gcLoad(base);
            res[1] = gcLoad(base + 1);
            res[2] = gcLoad(base + 2);
            vec = true;
        },
        T_INDEX => res[0] = gcLoad(fv.OP_INDEX),
        T_VALUE => res[0] = gcConst(rdf(r, nd + ND_P)),
        T_COMBINE => {
            for (0..3) |q| {
                gcInput(k, @intCast(q), 1);
                res[q] = gc.out[0];
            }
            vec = true;
        },
        T_SEP => {
            gcInput(k, 0, 2);
            res[0] = gc.out[o];
        },
        T_MATH => {
            gcInput(k, 0, 1);
            const a = gc.out[0];
            gcInput(k, 1, 1);
            const b = gc.out[0];
            var op: u32 = @bitCast(fv.cvtt(rdf(r, nd + ND_P)));
            if (op > 14) op = 0;
            res[0] = gcOp(mathops[op], a, b);
        },
        T_VMATH => {
            gcInput(k, 0, 2);
            const a = gc.out;
            gcInput(k, 1, 2);
            const b = gc.out;
            gcInput(k, 2, 1);
            const f = gc.out[0];
            var op: u32 = @bitCast(fv.cvtt(rdf(r, nd + ND_P)));
            if (op > 9) op = 0;
            res = vmath(op, a, b, f);
            vec = o != 1;
            if (!vec) res[0] = res[3];
        },
        T_NOISE => {
            gcInput(k, 0, 2);
            const v = gc.out;
            var q: u32 = 0;
            while (true) : (q += 1) {
                const d = gcReg();
                res[q] = d;
                gcIns(fv.OP_NOISE, d, v[0], v[1], v[2], .{ rdf(r, nd + ND_P), rdf(r, nd + ND_P + 4), rdf(r, nd + ND_P + 8), fi(q) });
                if (o == 0) break; // (fac: the first only)
                if (q == 2) {
                    vec = true;
                    break;
                }
            }
        },
        T_RANDOM => {
            const idx = gcLoad(fv.OP_INDEX);
            const d = gcReg();
            res[0] = d;
            gcIns(fv.OP_RAND, d, idx, 0, 0, .{ rdf(r, nd + ND_P + 8), rdf(r, nd + ND_P), rdf(r, nd + ND_P + 4), 0 });
        },
        T_GIN => {
            // a group's value / vector: the group node's input, in the outer tree
            if (g_level == 0 or o == 0) {
                const z = gcConst(0);
                res = .{ z, z, z, 0 };
                vec = o == 2;
            } else {
                const lv = g_level;
                const save = g_rec;
                g_rec = g_ctx_rec[lv];
                g_level -= 1;
                gc.depth += 1;
                gcInput(g_ctx_node[lv], o, o);
                gc.depth -= 1;
                g_level += 1;
                g_rec = save;
                res[0] = gc.out[0];
                if (o != 1) {
                    res[1] = gc.out[1];
                    res[2] = gc.out[2];
                    vec = true;
                }
            }
        },
        else => {
            gc.out[0] = gcConst(0); // (not a field: 0, not remembered)
            return 1;
        },
    }
    gc.out[0] = res[0];
    sl[0] = @truncate(res[0] + 1);
    if (!vec) return 1;
    gc.out[1] = res[1];
    gc.out[2] = res[2];
    sl[1] = @truncate(res[1] + 1);
    sl[2] = @truncate(res[2] + 1);
    return 2;
}

fn gcDot(u: [3]u32, v: [3]u32) u32 {
    const m0 = gcOp(fv.OP_MUL, u[0], v[0]);
    const m1 = gcOp(fv.OP_MUL, u[1], v[1]);
    const s = gcOp(fv.OP_ADD, m0, m1);
    const m2 = gcOp(fv.OP_MUL, u[2], v[2]);
    return gcOp(fv.OP_ADD, s, m2);
}

fn gcCross1(a: [3]u32, b: [3]u32, i: usize, j: usize) u32 {
    const x = gcOp(fv.OP_MUL, a[i], b[j]);
    const y = gcOp(fv.OP_MUL, a[j], b[i]);
    return gcOp(fv.OP_SUB, x, y);
}

/// gc_vmath: the vector (0..2) and the value (3).
fn vmath(op: u32, a: [3]u32, b: [3]u32, f: u32) [4]u32 {
    var r: [4]u32 = .{ 0, 0, 0, 0 };
    switch (op) {
        0, 1, 2 => {
            const code: u8 = switch (op) {
                0 => fv.OP_ADD,
                1 => fv.OP_SUB,
                else => fv.OP_MUL,
            };
            for (0..3) |c| r[c] = gcOp(code, a[c], b[c]);
        },
        3 => for (0..3) |c| {
            r[c] = gcOp(fv.OP_MUL, a[c], f);
        },
        4 => {
            r[0] = gcCross1(a, b, 1, 2);
            r[1] = gcCross1(a, b, 2, 0);
            r[2] = gcCross1(a, b, 0, 1);
        },
        5 => {
            r[3] = gcDot(a, b);
            r[0] = a[0];
            r[1] = a[1];
            r[2] = a[2];
            return r;
        },
        6 => {
            r[3] = gcOp(fv.OP_SQRT, gcDot(a, a), 0);
            r[0] = a[0];
            r[1] = a[1];
            r[2] = a[2];
            return r;
        },
        7 => {
            r[3] = gcOp(fv.OP_SQRT, gcDot(a, a), 0);
            for (0..3) |c| r[c] = gcOp(fv.OP_DIV, a[c], r[3]);
            return r;
        },
        8 => {
            for (0..3) |c| r[c] = gcOp(fv.OP_SUB, a[c], b[c]);
            r[3] = gcOp(fv.OP_SQRT, gcDot(.{ r[0], r[1], r[2] }, .{ r[0], r[1], r[2] }), 0);
            return r;
        },
        else => for (0..3) |c| { // mix: a + (b - a) factor
            const d = gcOp(fv.OP_SUB, b[c], a[c]);
            const e = gcOp(fv.OP_MUL, d, f);
            r[c] = gcOp(fv.OP_ADD, a[c], e);
        },
    }
    // the value: the result's length
    r[3] = gcOp(fv.OP_SQRT, gcDot(.{ r[0], r[1], r[2] }, .{ r[0], r[1], r[2] }), 0);
    return r;
}

// --- making a group (gn_make_group) ---------------------------------------------------------

/// The selected nodes (bit n = node n) go into a new tree between a Group
/// Input and a Group Output; links into them from outside come through the
/// Group Input (its geometry, value and vector: the first of each kind), the
/// first geometry output used outside becomes the group's output. The group
/// node made in the tree (0: nothing to group).
pub fn makeGroup(t: u32, mask0: u64) u32 {
    var mask = mask0;
    const r0 = nt.get(t) orelse return 0;
    const n = nodeCount(r0);
    mask &= ~@as(u64, 1);
    var k: u32 = 1;
    while (k <= n) : (k += 1) {
        if (k > 63 or mask & (@as(u64, 1) << @intCast(k)) == 0) continue;
        const ty = rd32(r0, nodeOff(k) + ND_TYPE);
        if (ty == T_GIN or ty == T_GOUT) mask &= ~(@as(u64, 1) << @intCast(k));
    }
    if (n + 1 <= 63) mask &= ~(~@as(u64, 0) << @intCast(n + 1)); // (bits above n)
    if (mask == 0) return 0;
    const inner = nt.new("Group") orelse return 0;
    _ = nt.add(inner, T_GIN, &defaults[T_GIN - 1]);
    _ = nt.add(inner, T_GOUT, &defaults[T_GOUT - 1]);
    var map: [NT_MAXN]u32 = @splat(0);
    k = 1;
    while (k <= n) : (k += 1) {
        if (!bit(mask, k)) continue;
        const ir = nt.own(inner).?;
        const src = nt.get(t).?;
        const c = nodeCount(ir);
        @memcpy(ir[GR_NODES + c * NODE_SZ ..][0..NODE_SZ], src[nodeOff(k)..][0..NODE_SZ]);
        nt.wr32(ir, GR_N, c + 1);
        map[k - 1] = c + 1;
    }
    // inner links: inside kept, outside through the group input
    const ir = nt.own(inner).?;
    var ext: [3]u32 = .{ 0, 0, 0 };
    var q: u32 = 3;
    while (q <= nodeCount(ir)) : (q += 1) {
        const o = nodeOff(q);
        const row = metaOf(rd32(ir, o + ND_TYPE));
        for (0..3) |i| {
            const p = o + ND_IN + i * 16;
            const w = rd32(ir, p);
            const from = w & 0xffff;
            if (from == 0) continue;
            if (from > n) {
                nt.wr32(ir, p, 0);
                continue;
            }
            if (bit(mask, from)) {
                nt.wr32(ir, p, (w & 0xffff0000) | map[from - 1]); // inside: renumbered
                continue;
            }
            var kind: u32 = 0; // outside: by the input's kind
            if (row) |rw| {
                kind = rw.in_k[i];
                if (kind > 2) kind = 0;
            }
            if (ext[kind] == 0) ext[kind] = w;
            nt.wr32(ir, p, (kind << 16) | 1); // group input (node 1), output kind
        }
    }
    // the output: a selected node's geometry used outside
    var gout: u32 = 0;
    const r1 = nt.get(t).?;
    k = 1;
    outer: while (k <= n) : (k += 1) {
        if (bit(mask, k)) continue;
        const o = nodeOff(k);
        for (0..3) |i| {
            const w = rd32(r1, o + ND_IN + i * 16);
            const from = w & 0xffff;
            if (from == 0 or from > n or !bit(mask, from)) continue;
            const ty = rd32(r1, nodeOff(from) + ND_TYPE);
            if (ty == 0 or ty > NTYPES) continue;
            if (outKind(ty, (w >> 16) & 0xff) != 0) continue;
            gout = w;
            break :outer;
        }
    }
    if (gout != 0) {
        const w = (gout & 0xffff0000) | map[(gout & 0xffff) - 1];
        const ir2 = nt.own(inner).?;
        nt.wr32(ir2, GR_NODES + NODE_SZ + ND_IN, w); // (node 2: the output)
    }
    // the outer tree: the others kept, a group node after them
    const rb = nt.own(t).?;
    var map2: [NT_MAXN]u32 = @splat(0);
    var tmp: [(NT_MAXN + 1) * NODE_SZ]u8 = undefined;
    var kept: u32 = 0;
    var sx: i32 = 0;
    var sy: i32 = 0;
    k = 1;
    while (k <= n) : (k += 1) {
        const o = nodeOff(k);
        if (bit(mask, k)) {
            sx += std.mem.readInt(i16, rb[o + ND_POS ..][0..2], .little);
            sy += std.mem.readInt(i16, rb[o + ND_POS + 2 ..][0..2], .little);
            continue;
        }
        @memcpy(tmp[kept * NODE_SZ ..][0..NODE_SZ], rb[o..][0..NODE_SZ]);
        kept += 1;
        map2[k - 1] = kept;
    }
    kept += 1; // the group node
    const gnode = kept;
    const go = (gnode - 1) * NODE_SZ;
    @memset(tmp[go..][0..NODE_SZ], 0);
    std.mem.writeInt(u32, tmp[go + ND_TYPE ..][0..4], T_GROUP, .little);
    std.mem.writeInt(u32, tmp[go + ND_P ..][0..4], @bitCast(fi(inner + 1)), .little);
    for (0..3) |i| { // its inputs: the outside links
        var w = ext[i];
        const from = w & 0xffff;
        if (from != 0) {
            const nf = map2[from - 1];
            w = if (nf != 0) (w & 0xffff0000) | nf else 0;
        } else w = 0;
        std.mem.writeInt(u32, tmp[go + ND_IN + i * 16 ..][0..4], w, .little);
    }
    const cnt: i32 = @intCast(@popCount(mask));
    std.mem.writeInt(i16, tmp[go + ND_POS ..][0..2], @truncate(@divTrunc(sx, cnt)), .little);
    std.mem.writeInt(i16, tmp[go + ND_POS + 2 ..][0..2], @truncate(@divTrunc(sy, cnt)), .little);
    // the kept nodes' links renumbered
    var j: u32 = 0;
    while (j < kept) : (j += 1) {
        if (j + 1 == gnode) continue;
        for (0..3) |i| {
            const p = j * NODE_SZ + ND_IN + i * 16;
            const w = std.mem.readInt(u32, tmp[p..][0..4], .little);
            const from = w & 0xffff;
            if (from == 0) continue;
            var nw: u32 = 0;
            if (from <= n) {
                if (!bit(mask, from)) {
                    nw = (w & 0xffff0000) | map2[from - 1];
                } else if (w == gout) nw = gnode; // (the group's output: the group node)
            }
            std.mem.writeInt(u32, tmp[p..][0..4], nw, .little);
        }
    }
    @memcpy(rb[GR_NODES..][0 .. kept * NODE_SZ], tmp[0 .. kept * NODE_SZ]);
    if (n > kept) @memset(rb[GR_NODES + kept * NODE_SZ ..][0 .. (n - kept) * NODE_SZ], 0);
    nt.wr32(rb, GR_N, kept);
    return gnode;
}

fn bit(mask: u64, k: u32) bool {
    return k < 64 and mask & (@as(u64, 1) << @intCast(k)) != 0;
}

/// The original's kind bytes as they lie in its rodata (k200 .. k120, then
/// the alignment): an output kind is read at its row's bytes + the output, so
/// an output past 3 reads its neighbours.
const kb_a = [_]u8{ 2, 0, 0, 0, 0, 3, 0, 3, 3, 0, 3, 0, 1, 3, 0, 0, 2, 2, 0, 0, 0, 3, 3, 0, 0, 0, 1, 0, 0, 3, 0, 0, 1, 1, 3, 0, 4, 0, 0, 0 }; // k200 .. k4000
const kb_nil: [56]u8 = @splat(0); // nil3, nil4
const kb_b = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 0, 2, 2, 0, 0, 1, 2, 0, 0, 1, 0, 0 }; // k000 .. k010
const kb_c = [_]u8{ 2, 2, 2, 0, 1, 1, 1, 0, 2, 2, 1, 0, 2, 1, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0 }; // k222 .. k120, the alignment
const kblob = kb_a ++ kb_nil ++ kb_b ++ kb_c;

/// Output o's kind for type t (0 geometry), as gn_make_group reads it.
fn outKind(t: u32, o: u32) u8 {
    const base: usize = switch (t) {
        T_GIN => 120, // k012
        T_POS, T_NORMAL, T_COMBINE => 128, // k222
        T_INDEX, T_VALUE, T_SEP, T_MATH, T_RANDOM => 132, // k111
        T_VMATH => 140, // k210
        T_NOISE => 144, // k120
        else => 96, // k000
    };
    const at = base + o;
    if (at < kblob.len) return kblob[at];
    return 1; // (past them: the pointers that follow; not geometry)
}

// --- the operators: tree.node, tree.group ---------------------------------------------------

const ops = @import("ops.zig");
const app = @import("app.zig");

/// gn_add: a node of this type with its defaults, or null.
pub fn addNode(t: u32, typ: u32) ?u32 {
    if (typ == 0 or typ > NTYPES) return null;
    return nt.add(t, typ, &defaults[typ - 1]);
}

const need_node = "  tree.node <tree> <type> [values]: input output grid cube sphere cylinder line transform join set_position extrude subdivide boolean merge realize position normal index value combine_xyz separate_xyz math vector_math noise random group distribute instance curve_line curve_circle curve_to_mesh resample trim fillet curve_to_points terrain terrace erode lsystem";

/// tree.node <tree> <type> [values p0..p3]
fn opNode() void {
    nt.begin();
    var w = nt.Words{ .s = ops.arg };
    const t = nt.argTree(&w) orelse return nt.fail();
    const tw = w.next();
    if (tw.len == 0) return nt.needed(need_node);
    const typ = typeIndex(tw) orelse return nt.needed(need_node);
    const k = addNode(t, typ) orelse return nt.needed(need_node);
    var slot: i32 = 4;
    while (slot < 8) : (slot += 1) {
        const v = w.num() orelse break;
        _ = nt.set(t, @intCast(k), slot, &.{v});
    }
    nt.done();
    nt.sayNode(k);
}

/// tree.group <tree> <node> [node ...]
fn opGroup() void {
    nt.begin();
    var w = nt.Words{ .s = ops.arg };
    const t = nt.argTree(&w) orelse return nt.fail();
    var mask: u64 = 0;
    while (true) {
        const s = w.next();
        if (s.len == 0) break;
        const x = nt.parseFloat(s, null) orelse break;
        const k = nt.cvtt(x);
        if (k < 1 or k > NT_MAXN) continue;
        mask |= @as(u64, 1) << @intCast(k);
    }
    const g = makeGroup(t, mask);
    if (g == 0) return nt.needed("  tree.group <tree> <node> [node ...] (not the group input / output)");
    nt.done();
    nt.sayNode(g);
}

const Impl = ops.Impl;
pub const list = .{
    .{ "tree.node", Impl{ .run = opNode } },
    .{ "tree.group", Impl{ .run = opGroup } },
};

// --- tests ---------------------------------------------------------------------------------

test "primitives as the original makes them" {
    const s = primSphere().?;
    defer unref(s);
    try std.testing.expectEqual(@as(usize, 482), s.verts.len);
    try std.testing.expectEqual(@as(u32, 32 * 16), s.faces());
    const c = primCylinder().?;
    defer unref(c);
    try std.testing.expectEqual(@as(usize, 64), c.verts.len);
    try std.testing.expectEqual(@as(u32, 34), c.faces());
    const g = primGrid(2).?;
    defer unref(g);
    try std.testing.expectEqual(@as(usize, 9), g.verts.len);
    try std.testing.expectEqual(V3{ -1, 0, -1 }, g.verts[0]);
    try std.testing.expectEqual(V3{ 0, 0, -1 }, g.verts[1]);
    const t = trisOf(g);
    try std.testing.expectEqual(@as(usize, 8), t.len);
}

test "hash and u01" {
    try std.testing.expect(unit01(1, 2, 3) >= 0 and unit01(1, 2, 3) < 1);
    try std.testing.expect(hash(1, 2, 3) != hash(1, 2, 4));
}

test "the evaluation compiles" {
    _ = &makeGroup;
}
