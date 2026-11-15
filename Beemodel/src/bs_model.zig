// BeeScript's modelling builtins (script.s b_modifier .. b_modcount, b_boolean,
// b_manifold, b_analyze, b_thinnest): the modifier stack (mods.zig), the
// boolean operator, the mesh checks (fmesh.zig's mesh_manifold, analysis.zig's
// mesh_analyze) and the thinnest wall (print.zig's th_faces). infill is in
// bs_cad.zig with the other features. What they change is part of the run's
// one undo step (bscript.zig).
const std = @import("std");
const bs = @import("bscript.zig");
const bc = @import("bs_cad.zig");
const scn = @import("bs_scene.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const mods = @import("mods.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "modifier", .f = modifier },
    .{ .name = "modset", .f = modset },
    .{ .name = "modapply", .f = modapply },
    .{ .name = "modremove", .f = modremove },
    .{ .name = "modcount", .f = modcount },
    .{ .name = "boolean", .f = boolean },
    .{ .name = "manifold", .f = manifold },
    .{ .name = "analyze", .f = analyze },
    .{ .name = "thinnest", .f = thinnest },
};

const e_modtype = "modifier types: mirror array solidify subsurf bevel decimate remesh; got ";
const e_modidx = "no modifier with that index / parameter";
const e_an_kind = "analyze: boundary, nonmanifold, degenerate, loose or overhang, not ";
const e_op_perm = "permission denied (the user has not given agents file access): ";
const s_full = "  the stack holds 8 modifiers";
const s_bool_op = "object.boolean";

/// word_eq: the text (up to a space or its end, any case) is the word.
fn wordEq(text: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (i < word.len) : (i += 1) {
        const c: u8 = if (i < text.len) text[i] | 0x20 else 0;
        if (c != word[i]) return false;
    }
    return i >= text.len or text[i] == ' ';
}

const keys = [_][]const u8{ "", "mirror", "array", "solidify", "subsurf", "bevel", "decimate", "remesh", "boolean", "multires", "geometry", "armature", "logic" };

/// modifier(name, type) -> the new modifier's index
fn modifier(a: []const V) Err!V {
    const tn = try bs.argStr(a[1]);
    var t: u32 = 0;
    for (keys[1..], 1..) |k, j| {
        if (wordEq(tn, k)) {
            t = @intCast(j);
            break;
        }
    }
    if (t == 0) return bs.fail(e_modtype, tn);
    const oi = try scn.argMesh(a[0]);
    const k = mods.add(oi, t) orelse {
        app.log(s_full, .{});
        return bs.fail(e_modidx, "");
    };
    app.dirty = true;
    return bs.num(@floatFromInt(k));
}

/// stack_index: entry k of object i's stack (signed: negative is none)
fn entry(oi: usize, k: i32) ?*scene.Mod {
    const o = &scene.objects[oi];
    if (k < 0 or k >= o.mods.n) return null;
    return &o.mods.m[@intCast(k)];
}

/// modset(name, index, parameter, value): parameter by name or number; a
/// name as the value: that object (an object parameter's)
fn modset(a: []const V) Err!V {
    var bits: u32 = undefined;
    if (a[3].t == .str) {
        bits = scene.objects[try scn.argObj(a[3])].oid;
    } else bits = @bitCast(bs.f32of(try bs.argNum(a[3])));
    const k = bs.ci32(try bs.argNum(a[1]));
    const oi = try scn.argMesh(a[0]);
    const d = entry(oi, k) orelse return bs.fail(e_modidx, "");
    // mod_param_index: a leading digit is the number, else by name
    var pi: i32 = -1;
    if (a[2].t == .str) {
        const s = std.mem.span(a[2].u.s);
        if (s.len > 0 and s[0] -% '0' <= 9) {
            pi = s[0] - '0';
        } else for (mods.params(d.kind), 0..) |p, q| {
            if (wordEq(s, p.name)) {
                pi = @intCast(q);
                break;
            }
        }
    } else pi = bs.ci32(try bs.argNum(a[2]));
    if (pi < 0) return bs.fail(e_modidx, "");
    // mod_param_set: clamped to its range, integers rounded to even; an
    // object's bits are its reference
    const ps = mods.params(d.kind);
    if (pi >= ps.len) return bs.fail(e_modidx, "");
    const p = ps[@intCast(pi)];
    if (!p.object) {
        var x: f32 = @bitCast(bits);
        x = if (x > p.lo) x else p.lo; // maxss
        x = if (x < p.hi) x else p.hi; // minss
        if (p.int) x = roundEven(x);
        bits = @bitCast(x);
    }
    d.p[@intCast(pi)] = bits;
    app.dirty = true;
    return bs.nil;
}

/// roundss, to nearest: a half goes to the even neighbour.
fn roundEven(x: f32) f32 {
    if (!std.math.isFinite(x)) return x;
    const r = @round(x);
    if (@abs(x - @trunc(x)) != 0.5) return r;
    return 2 * @round(x / 2);
}

/// modapply(name, index): modifiers 0..index become part of the mesh
fn modapply(a: []const V) Err!V {
    const k = bs.ci32(try bs.argNum(a[1]));
    const oi = try scn.argMesh(a[0]);
    if (entry(oi, k) == null) return bs.fail(e_modidx, "");
    // (.failed / .emptied: the port leaves the stack as it was; see the report)
    _ = mods.apply(oi, @intCast(k));
    app.dirty = true;
    return bs.nil;
}

/// modremove(name, index)
fn modremove(a: []const V) Err!V {
    const k = bs.ci32(try bs.argNum(a[1]));
    const oi = try scn.argMesh(a[0]);
    if (entry(oi, k) == null or !mods.remove(oi, @intCast(k))) return bs.fail(e_modidx, "");
    app.dirty = true;
    return bs.nil;
}

fn modcount(a: []const V) Err!V {
    const oi = try scn.argMesh(a[0]);
    return bs.num(@floatFromInt(scene.objects[oi].mods.n));
}

/// boolean(a, b, kind): a becomes a (kind) b, b is deleted (object.boolean)
fn boolean(a: []const V) Err!V {
    // select(b, a): a is active
    const bi = try scn.argObj(a[1]);
    const ai = try scn.argObj(a[0]);
    for (scene.objects[0..scene.count]) |*o| o.selected = false;
    scene.objects[bi].selected = true;
    scene.objects[ai].selected = true;
    scene.active = ai;
    app.dirty = true;
    const i = ops.byId(s_bool_op) orelse return bs.nil;
    if (bs.byAgent()) {
        if (bs.agent_gate) |g| {
            if (g(i) != null) return bs.fail(e_op_perm, s_bool_op);
        }
    }
    var ab: [520]u8 = undefined;
    scn.runOp(i, bs.valText(a[2], ab[0..512]));
    return bs.nil;
}

/// manifold(name) -> 1 if the mesh is closed and consistently oriented
fn manifold(a: []const V) Err!V {
    const oi = try scn.argMesh(a[0]);
    const me = &scene.meshes[scene.objects[oi].mesh.?].?;
    const fm = @import("fmesh.zig");
    const x = fm.M{ .verts = @constCast(me.verts), .poff = @constCast(me.poff), .loops = @constCast(me.loops), .bmin = .{ 0, 0, 0 }, .bmax = .{ 0, 0, 0 } };
    const ok = fm.manifold(@import("alloc.zig").A, &x) catch false;
    return bs.num(if (ok) 1 else 0);
}

/// analyze(name, what) -> how many boundary edges / non-manifold edges /
/// degenerate faces / loose vertices / overhanging faces (-1: no memory)
fn analyze(a: []const V) Err!V {
    const w = try bs.argStr(a[1]);
    const kinds = [_][]const u8{ "boundary", "nonmanifold", "degenerate", "loose", "overhang" };
    var k: ?usize = null;
    for (kinds, 0..) |s, j| {
        if (k == null and std.mem.eql(u8, s, w)) k = j;
    }
    if (k == null) return bs.fail(e_an_kind, w);
    const oi = try scn.argMesh(a[0]);
    const c = @import("analysis.zig").of(oi) orelse return bs.num(-1);
    const n = c.counts;
    const v = [_]u32{ n.boundary, n.nonmanifold, n.degenerate, n.loose, n.overhang };
    return bs.num(@floatFromInt(v[k.?]));
}

/// thinnest(object) -> its thinnest wall (scene units; nil when no ray meets
/// another face)
fn thinnest(a: []const V) Err!V {
    const oi = try scn.argMesh(a[0]);
    const th = @import("print.zig").thFaces(oi) orelse return bs.nil;
    const big: f32 = 1.0e29;
    var x: f32 = big;
    for (th) |t| x = if (x < t) x else t; // minss
    if (x >= big) return bs.nil;
    return bs.num(x);
}

test "word_eq: any case, up to a space" {
    const T = std.testing;
    try T.expect(wordEq("mirror", "mirror"));
    try T.expect(wordEq("MIRROR", "mirror"));
    try T.expect(wordEq("Array x", "array"));
    try T.expect(!wordEq("mirrors", "mirror"));
    try T.expect(!wordEq("mirro", "mirror"));
    try T.expect(!wordEq("", "mirror"));
}

test "roundss: halves to even" {
    const T = std.testing;
    try T.expectEqual(@as(f32, 2), roundEven(2.5));
    try T.expectEqual(@as(f32, 2), roundEven(1.5));
    try T.expectEqual(@as(f32, -2), roundEven(-2.5));
    try T.expectEqual(@as(f32, 3), roundEven(2.6));
    try T.expect(std.math.isInf(roundEven(std.math.inf(f32))));
}
