// BeeScript's CAD builtins (script.s b_param, b_pad .. b_infill's feature
// part, b_feature, b_features, b_fstatus, b_brep, b_nurbscheck, b_area,
// b_mass, b_centroid, b_measurement, b_fangle): parameters, the feature
// tree (feature.zig), the B-rep queries (bquery.zig), the kernel's NURBS
// checks (nurbs.zig), mass properties and the measure tool (measure.zig).
// Values may be numbers or expression texts with units ("10mm", "wall * 2"):
// a feature keeps the text, so parameters drive it. What they change is part
// of the run's one undo step (bscript.zig).
const std = @import("std");
const bs = @import("bscript.zig");
const scn = @import("bs_scene.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const cad = @import("cad.zig");
const ft = @import("feature.zig");
const measure = @import("measure.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "param", .f = param },
    .{ .name = "pad", .f = pad },
    .{ .name = "pocket", .f = pocket },
    .{ .name = "revolve", .f = revolve },
    .{ .name = "hole", .f = hole },
    .{ .name = "shell", .f = shell },
    .{ .name = "fillet", .f = fillet },
    .{ .name = "chamfer", .f = chamfer },
    .{ .name = "pattern", .f = pattern },
    .{ .name = "infill", .f = infill },
    .{ .name = "feature", .f = feature },
    .{ .name = "features", .f = features },
    .{ .name = "fstatus", .f = fstatus },
    .{ .name = "brep", .f = brep },
    .{ .name = "nurbscheck", .f = nurbscheck },
    .{ .name = "area", .f = area },
    .{ .name = "mass", .f = mass },
    .{ .name = "centroid", .f = centroid },
    .{ .name = "measurement", .f = measurement },
    .{ .name = "fangle", .f = fangle },
};

pub const e_param = "parameter: ";
const e_noparam = "no parameter named ";
const e_no_sketch = "no sketch called ";
const e_ft_long = "a feature value is 31 characters at most: ";
const e_ft_word = "not understood here: ";
pub const e_ft_full = "the scene holds 64 features";
const e_ft_ref = "no such feature";
const e_ft_body = "the body is not a mesh: ";
const e_no_face = "no such face";
const e_axis = "axis must be 0, 1 or 2 (or \"x\", \"y\", \"z\")";

// ---- shared helpers (the other area files use them too) ---------------------------------

/// a_val: a number, or an expression text (units, parameters) that works.
pub fn aVal(v: V) Err!f64 {
    if (v.t != .str) return bs.argNum(v);
    return cad.eval(std.mem.span(v.u.s)) orelse bs.fail(e_param, cad.expr.err orelse "");
}

/// a_int: a number, truncated to 32 bits (cvttsd2si).
pub fn aInt(v: V) Err!i32 {
    return bs.ci32(try bs.argNum(v));
}

/// a_sketch: the sketch object called exactly this.
pub fn aSketch(v: V) Err!usize {
    const nm = try bs.argStr(v);
    if (scn.find(nm)) |i| {
        if (scene.objects[i].kind == .sketch and scene.objects[i].sk != null) return i;
    }
    return bs.fail(e_no_sketch, nm);
}

/// obj_new: an object at the end of the outliner, its name made unique
/// (26 bytes, then ".001" ...), the type's colour, not selected. Null: full.
pub fn objNew(kind: scene.Kind, nm: []const u8, mi: ?u16, colour: u32) ?usize {
    if (scene.count >= scene.max_objects) return null;
    scene.objects[scene.count] = scene.Object{ .kind = kind, .mesh = mi, .color = colour };
    scene.stamp(scene.count);
    scene.count += 1;
    const i = scene.count - 1;
    uniqueName(i, nm);
    app.dirty = true;
    return i;
}

/// unique_name for object i (not yet among the others: it is not compared
/// with itself, so "" stays ""): the base's first 26 bytes, then ".001" ..
/// ".999" (the last tried stays). (bs_scene.zig's objRename compares with the
/// object itself and so names an empty name ".001".)
pub fn uniqueName(i: usize, want: []const u8) void {
    const o = &scene.objects[i];
    const b = want[0..@min(want.len, 26)];
    var buf: [32]u8 = undefined;
    var n: usize = b.len;
    var k: u32 = 0;
    while (true) {
        @memcpy(buf[0..b.len], b);
        n = b.len;
        if (k > 0) {
            buf[n] = '.';
            buf[n + 1] = @intCast('0' + k / 100);
            buf[n + 2] = @intCast('0' + k % 100 / 10);
            buf[n + 3] = @intCast('0' + k % 10);
            n += 4;
        }
        var taken = false;
        for (scene.objects[0..scene.count], 0..) |*x, j| {
            if (j != i and std.mem.eql(u8, x.name(), buf[0..n])) taken = true;
        }
        if (!taken or k >= 999) break;
        k += 1;
    }
    o.name_buf = @splat(0);
    @memcpy(o.name_buf[0..n], buf[0..n]);
    o.name_len = @intCast(n);
}

/// type_colors[OT_MESH]
pub const mesh_colour: u32 = 0xb4b8c0;

// ---- parameters ------------------------------------------------------------------------

/// param(name [, expression]) -> its value in scene units (set it first)
fn param(a: []const V) Err!V {
    const nm = try bs.argStr(a[0]);
    if (a.len >= 2) {
        var buf: [64]u8 = undefined;
        const t = if (a[1].t == .num) cad.fmtVal3(&buf, bs.f32of(a[1].u.n)) else try bs.argStr(a[1]);
        if (!cad.paramSet(nm, t)) return bs.fail(e_param, cad.expr.err orelse "");
        cad.rebuild(); // sketches follow
        app.dirty = true;
    }
    const i = cad.paramFind(nm) orelse return bs.fail(e_noparam, nm);
    const x = cad.paramValue(i) orelse return bs.fail(e_param, cad.expr.err orelse "");
    return bs.num(x);
}

// ---- features ------------------------------------------------------------------------

var ft_tmp: [ft.FT_SZ]u8 = @splat(0);

fn fbNew(t: u32) void {
    ft_tmp = @splat(0);
    ft.set(&ft_tmp, ft.FT_TYPE, t);
}

fn setI(off: usize, v: i32) void {
    ft.set(&ft_tmp, off, @bitCast(v));
}

/// fb_slot: a number, or an expression text that works (31 bytes at most).
fn fbSlot(v: V, k: usize) Err!void {
    const sp = ft_tmp[ft.FT_X + 32 * k ..][0..32];
    if (v.t != .str) {
        const x = try bs.argNum(v);
        sp[0] = 1;
        std.mem.writeInt(u64, sp[8..16], @bitCast(x), .little);
        return;
    }
    _ = try aVal(v);
    const s = std.mem.span(v.u.s);
    if (s.len >= 32) {
        @memcpy(sp[0..32], s[0..32]);
        return bs.fail(e_ft_long, s);
    }
    @memcpy(sp[0..s.len], s);
    sp[s.len] = 0;
}

const Word = struct { w: []const u8, v: u32 };
const fw_modes = [_]Word{ .{ .w = "symmetric", .v = 1 }, .{ .w = "normal", .v = 0 }, .{ .w = "reverse", .v = 2 }, .{ .w = "through", .v = 4 }, .{ .w = "bottom", .v = 2 } };
const fw_axes = [_]Word{ .{ .w = "x", .v = 0 }, .{ .w = "y", .v = 1 }, .{ .w = "z", .v = 2 }, .{ .w = "u", .v = 0 }, .{ .w = "v", .v = 1 } };
const fw_sels = [_]Word{ .{ .w = "all", .v = 0 }, .{ .w = "vertical", .v = 1 }, .{ .w = "horizontal", .v = 2 }, .{ .w = "top", .v = 3 }, .{ .w = "bottom", .v = 4 } };
const fw_circ = [_]Word{ .{ .w = "circular", .v = 1 }, .{ .w = "linear", .v = 0 } };
const fw_lat = [_]Word{ .{ .w = "gyroid", .v = 0 }, .{ .w = "grid", .v = 1 } };

/// fb_word: the word's number in the table.
fn fbWord(v: V, tab: []const Word) Err!u32 {
    const s = try bs.argStr(v);
    for (tab) |x| {
        if (std.mem.eql(u8, x.w, s)) return x.v;
    }
    return bs.fail(e_ft_word, s);
}

/// fb_finish: the body (a new empty mesh object when there is none), the
/// feature -> the new feature's index.
fn fbFinish(body: V) Err!V {
    const nm = try bs.argStr(body);
    var oi = scn.find(nm);
    if (oi) |i| {
        if (!scene.objects[i].kind.isMesh()) return bs.fail(e_ft_body, nm);
    } else {
        // an empty mesh until it is built
        const mi = scene.addEmptyMesh() orelse return bs.fail(e_ft_full, "");
        oi = objNew(.mesh, nm, mi, mesh_colour) orelse return bs.fail(e_ft_full, "");
    }
    ft.set(&ft_tmp, ft.FT_BODY, scene.objects[oi.?].oid);
    const k = ft.add(&ft_tmp) orelse return bs.fail(e_ft_full, "");
    app.dirty = true;
    return bs.num(@floatFromInt(k));
}

/// pad / pocket(body, sketch, distance [, "symmetric" | "reverse" | "through"]),
/// revolve(body, sketch, angle [, "u" | "v"]), hole(body, sketch, diameter
/// [, depth]) -> the feature's index
fn fbExtrude(a: []const V, t: u32) Err!V {
    fbNew(t);
    const so = try aSketch(a[1]);
    ft.set(&ft_tmp, ft.FT_SKETCH, scene.objects[so].oid);
    try fbSlot(a[2], 0);
    if (a.len >= 4) switch (t) {
        ft.T_REVOLVE => ft.set(&ft_tmp, ft.FT_AXIS, (try fbWord(a[3], &fw_axes)) & 1),
        ft.T_HOLE => try fbSlot(a[3], 1),
        else => ft.set(&ft_tmp, ft.FT_FLAGS, try fbWord(a[3], &fw_modes)),
    };
    return fbFinish(a[0]);
}
fn pad(a: []const V) Err!V {
    return fbExtrude(a, ft.T_PAD);
}
fn pocket(a: []const V) Err!V {
    return fbExtrude(a, ft.T_POCKET);
}
fn revolve(a: []const V) Err!V {
    return fbExtrude(a, ft.T_REVOLVE);
}
fn hole(a: []const V) Err!V {
    return fbExtrude(a, ft.T_HOLE);
}

/// shell(body, pad feature, wall [, "bottom": open below instead of above])
fn shell(a: []const V) Err!V {
    fbNew(ft.T_SHELL);
    setI(ft.FT_REF, try aInt(a[1]));
    try fbSlot(a[2], 0);
    if (a.len >= 4) ft.set(&ft_tmp, ft.FT_FLAGS, (try fbWord(a[3], &fw_modes)) & 2);
    return fbFinish(a[0]);
}

/// fillet / chamfer(body, size [, "all" | "vertical" | "horizontal" | "top" | "bottom"])
fn fbEdges(a: []const V, t: u32) Err!V {
    fbNew(t);
    try fbSlot(a[1], 0);
    if (a.len >= 3) ft.set(&ft_tmp, ft.FT_REF, try fbWord(a[2], &fw_sels));
    return fbFinish(a[0]);
}
fn fillet(a: []const V) Err!V {
    return fbEdges(a, ft.T_FILLET);
}
fn chamfer(a: []const V) Err!V {
    return fbEdges(a, ft.T_CHAMFER);
}

/// pattern(body, feature, count, spacing | angle, "x" | "y" | "z" [, "circular"])
fn pattern(a: []const V) Err!V {
    fbNew(ft.T_LPAT);
    setI(ft.FT_REF, try aInt(a[1]));
    setI(ft.FT_COUNT, try aInt(a[2]));
    try fbSlot(a[3], 0);
    ft.set(&ft_tmp, ft.FT_AXIS, try fbWord(a[4], &fw_axes));
    if (a.len >= 6) ft.set(&ft_tmp, ft.FT_TYPE, ft.T_LPAT + try fbWord(a[5], &fw_circ));
    return fbFinish(a[0]);
}

/// infill(body, shell feature, "gyroid" | "grid", cell, wall): a lattice in
/// the shell's cavity (the table files it with the modelling builtins)
fn infill(a: []const V) Err!V {
    fbNew(ft.T_INFILL);
    setI(ft.FT_REF, try aInt(a[1]));
    ft.set(&ft_tmp, ft.FT_AXIS, try fbWord(a[2], &fw_lat));
    try fbSlot(a[3], 0);
    try fbSlot(a[4], 1);
    return fbFinish(a[0]);
}

/// feature(index, slot 0..2 | 3 = suppressed, value) -> its status afterwards
fn feature(a: []const V) Err!V {
    const i = try aInt(a[0]);
    const k = try aInt(a[1]);
    var text: ?[]const u8 = null;
    var x: f64 = 0;
    if (a[2].t == .str) {
        text = std.mem.span(a[2].u.s);
        _ = try aVal(a[2]); // (it has to work)
    } else x = try bs.argNum(a[2]);
    // (feat_slot_set: unsigned; suppressed unless the number is 0 - or NaN,
    // which ucomisd finds equal. A text there: the original reads a stack
    // slot b_feature never sets, which is not 0 - suppressed.)
    const iu: u32 = @bitCast(i);
    const ku: u32 = @bitCast(k);
    if (ku == 3 and text != null) x = 1;
    if (ku == 3 and std.math.isNan(x)) x = 0;
    if (ku > 3 or !ft.slotSet(iu, ku, text, x)) return bs.fail(e_ft_ref, "");
    app.dirty = true;
    return bs.num(@floatFromInt(ft.status(iu)));
}

fn features(_: []const V) Err!V {
    return bs.num(@floatFromInt(ft.count()));
}

/// fstatus(index): 0 ok, 1 sketch missing, 2 no closed profile, 3 geometry
/// failed, 4 bad value, 5 nothing to work on, 6 bad reference, 7 suppressed,
/// 8 body missing
fn fstatus(a: []const V) Err!V {
    const i: u32 = @bitCast(try aInt(a[0]));
    return bs.num(@floatFromInt(ft.status(i)));
}

// ---- the B-rep kernel -------------------------------------------------------------------

/// brep(name, what): the object's B-rep solid; nil when it has none
fn brep(a: []const V) Err!V {
    const i = try scn.argObj(a[0]);
    const what = try bs.argStr(a[1]);
    const x = @import("bquery.zig").query(scene.objects[i].oid, what);
    if (std.math.isNan(x)) return bs.nil;
    return bs.num(x);
}

/// nurbscheck(k): the largest error of the kernel's check k
fn nurbscheck(a: []const V) Err!V {
    const k = try aInt(a[0]);
    return bs.num(@import("nurbs.zig").nbCheck(k));
}

// ---- mass properties, measuring ---------------------------------------------------------

/// mp_area, mp_mass, mp_cen: the last mass_props (kept, as the original's globals)
var mp: measure.Props = .{};

fn massOf(v: V) Err!void {
    const i = try scn.argMesh(v);
    if (measure.massProps(i)) |p| mp = p;
}

fn area(a: []const V) Err!V {
    try massOf(a[0]);
    return bs.num(mp.area);
}
fn mass(a: []const V) Err!V {
    try massOf(a[0]);
    return bs.num(mp.mass);
}

/// centroid(object, axis): "x" / "y" / "z" or 0..2
fn centroid(a: []const V) Err!V {
    try massOf(a[0]);
    const ax: i32 = if (a[1].t == .str) @as(i32, a[1].u.s[0]) - 'x' else try aInt(a[1]);
    if (ax < 0 or ax > 2) return bs.fail(e_axis, "");
    return bs.num(mp.cen[@intCast(ax)]);
}

/// measurement(): the measure tool's distance, angle (radians), or nil
fn measurement(_: []const V) Err!V {
    return switch (measure.value()) {
        .none => bs.nil,
        .dist => |d| bs.num(d),
        .angle => |r| bs.num(r),
    };
}

/// fangle(object, face a, face b): the angle between their normals (radians)
fn fangle(a: []const V) Err!V {
    const oi = try scn.argMesh(a[0]);
    const fa: u32 = @bitCast(try aInt(a[1]));
    const fb: u32 = @bitCast(try aInt(a[2]));
    const me = &scene.meshes[scene.objects[oi].mesh.?].?;
    const np = me.faces();
    if (fa >= np or fb >= np) return bs.fail(e_no_face, "");
    const fm = @import("fmesh.zig");
    const na = fm.newell(me.verts, me.loops[me.poff[fa]..me.poff[fa + 1]]);
    const nb = fm.newell(me.verts, me.loops[me.poff[fb]..me.poff[fb + 1]]);
    const u = [3]f64{ na[0], na[1], na[2] };
    const w = [3]f64{ nb[0], nb[1], nb[2] };
    return bs.num(measure.vangle(u, w));
}

test "fb_slot: a number as 1 and a double, a text as it is" {
    const T = std.testing;
    fbNew(ft.T_PAD);
    try fbSlot(bs.num(2.5), 0);
    try T.expectEqual(@as(u8, 1), ft_tmp[ft.FT_X]);
    try T.expectEqual(@as(u64, @bitCast(@as(f64, 2.5))), std.mem.readInt(u64, ft_tmp[ft.FT_X + 8 ..][0..8], .little));
    try T.expectEqual(ft.T_PAD, ft.get(&ft_tmp, ft.FT_TYPE));
}

test "a_int: cvttsd2si" {
    const T = std.testing;
    try T.expectEqual(@as(i32, -1), try aInt(bs.num(-1.9)));
    try T.expectEqual(@as(i32, std.math.minInt(i32)), try aInt(bs.num(std.math.nan(f64))));
    try T.expectEqual(@as(i32, std.math.minInt(i32)), try aInt(bs.num(3e9)));
}
