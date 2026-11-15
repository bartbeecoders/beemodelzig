// BeeScript's sketch builtins (script.s b_sketch .. b_skinfo): sketch objects
// (skobj.zig) and their points, entities and constraints (sketch.zig). Numbers
// may be expression texts ("10mm", "90deg", parameters); a dimension given as
// a text keeps it, so parameters drive it. Each change solves the sketch and
// shows it anew; features built on it follow. What they change is part of
// the run's one undo step (bscript.zig).
const std = @import("std");
const bs = @import("bscript.zig");
const bc = @import("bs_cad.zig");
const scene = @import("scene.zig");
const sk = @import("sketch.zig");
const skobj = @import("skobj.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "sketch", .f = sketch },
    .{ .name = "point", .f = point },
    .{ .name = "line", .f = line },
    .{ .name = "circle", .f = circle },
    .{ .name = "arc", .f = arc },
    .{ .name = "rect", .f = rect },
    .{ .name = "pt", .f = pt },
    .{ .name = "con", .f = con },
    .{ .name = "dof", .f = dof },
    .{ .name = "conflicts", .f = conflicts },
    .{ .name = "sx", .f = sx },
    .{ .name = "sy", .f = sy },
    .{ .name = "sr", .f = sr },
    .{ .name = "skinfo", .f = skinfo },
};

const e_sk_plane = "sketch plane: XY, XZ or YZ, not ";
const e_sk_full = "the sketch is full";
const e_sk_ctype = "unknown constraint (coincident horizontal vertical parallel perpendicular equal tangent fixed distance hdistance vdistance radius diameter angle length online oncircle midpoint symmetric): ";
const e_sk_ref = "no such point or entity";

/// The sketch as it is (no copy): to read.
fn blockOf(v: V) Err!*sk.Block {
    return scene.objects[try bc.aSketch(v)].sk.?;
}

/// sk_edit: the object and its sketch, ours to change (copy-on-write).
const Edit = struct { i: usize, b: *sk.Block };
fn edit(v: V) Err!Edit {
    const i = try bc.aSketch(v);
    const b = skobj.begin(i) orelse return bs.fail(e_sk_full, "");
    return .{ .i = i, .b = b };
}

/// sk_done: solve, show, return the index (or the full error).
fn done(e: Edit, k: i32) Err!V {
    if (k < 0) return bs.fail(e_sk_full, "");
    _ = skobj.end(e.i);
    return bs.num(@floatFromInt(k));
}

/// sketch(name, "XY" | "XZ" | "YZ" [, offset]) -> the new sketch's name
fn sketch(a: []const V) Err!V {
    const nm = try bs.argStr(a[0]);
    const pl = try bs.argStr(a[1]);
    const planes = [_][]const u8{ "XY", "XZ", "YZ" };
    var plane: ?u32 = null;
    for (planes, 0..) |p, k| {
        if (plane == null and std.mem.eql(u8, p, pl)) plane = @intCast(k);
    }
    if (plane == null) return bs.fail(e_sk_plane, pl);
    var off: f64 = 0;
    if (a.len >= 3) off = try bc.aVal(a[2]);
    const i = skobj.create(nm, plane.?, off) orelse return bs.fail(e_sk_full, "");
    // (obj_new's unique_name: names compared exactly, 26 bytes of the base)
    bc.uniqueName(i, nm);
    @import("app.zig").dirty = true;
    return bs.text(scene.objects[i].name());
}

/// point(sketch, x, y) -> its index
fn point(a: []const V) Err!V {
    const x = try bc.aVal(a[1]);
    const y = try bc.aVal(a[2]);
    const e = try edit(a[0]);
    return done(e, sk.addPoint(e.b, x, y));
}

/// line(sketch, x1, y1, x2, y2) or line(sketch, point a, point b) -> entity
fn line(a: []const V) Err!V {
    var n: [4]f64 = undefined;
    for (a[1..], 0..) |v, k| n[k] = try bc.aVal(v);
    const e = try edit(a[0]);
    if (a.len == 3) {
        const p: u32 = @bitCast(bs.ci32(n[0]));
        const q: u32 = @bitCast(bs.ci32(n[1]));
        if (p >= e.b.npt or q >= e.b.npt) return bs.fail(e_sk_ref, "");
        return done(e, sk.addLine(e.b, @bitCast(p), @bitCast(q)));
    }
    if (a.len != 5) return bs.fail(e_sk_ref, "");
    return done(e, skobj.lineXY(e.b, n[0], n[1], n[2], n[3]));
}

/// circle(sketch, cx, cy, r) -> entity
fn circle(a: []const V) Err!V {
    var n: [3]f64 = undefined;
    for (a[1..4], 0..) |v, k| n[k] = try bc.aVal(v);
    const e = try edit(a[0]);
    return done(e, skobj.circleXY(e.b, n[0], n[1], n[2]));
}

/// arc(sketch, cx, cy, r, from angle, to angle) -> entity (radians or
/// "90deg"; counter-clockwise)
fn arc(a: []const V) Err!V {
    var n: [5]f64 = undefined;
    for (a[1..6], 0..) |v, k| n[k] = try bc.aVal(v);
    const e = try edit(a[0]);
    return done(e, skobj.arcXY(e.b, n[0], n[1], n[2], n[3], n[4]));
}

/// rect(sketch, x, y, width, height) -> the first of its four lines
fn rect(a: []const V) Err!V {
    var n: [4]f64 = undefined;
    for (a[1..5], 0..) |v, k| n[k] = try bc.aVal(v);
    const e = try edit(a[0]);
    return done(e, skobj.rect(e.b, n[0], n[1], n[2], n[3]));
}

/// pt(sketch, entity, which) -> its point: line 0 start 1 end; circle 0
/// centre; arc 0 centre 1 start 2 end
fn pt(a: []const V) Err!V {
    const b = try blockOf(a[0]);
    const ent = bs.ci32(try bs.argNum(a[1]));
    const which = bs.ci32(try bs.argNum(a[2]));
    const p = sk.entPoint(b, ent, which);
    if (p < 0) return bs.fail(e_sk_ref, "");
    return bs.num(@floatFromInt(p));
}

/// distance hdistance vdistance radius angle (9..13), length diameter (18, 19)
fn takesValue(t: i32) usize {
    return if ((t >= 9 and t <= 13) or t >= 18) 1 else 0;
}

/// con(sketch, type, a [, b [, c]] [, value]) -> constraint index. Point
/// constraints take point indices, the others entities; distance, hdistance,
/// vdistance, radius, angle, length and diameter end with a value (a number,
/// or an expression text kept so parameters drive it).
fn con(a: []const V) Err!V {
    const tn = try bs.argStr(a[1]);
    const t = sk.conType(tn);
    if (t < 0) return bs.fail(e_sk_ctype, tn);
    const has_val: usize = takesValue(t);
    const nref = @as(i64, @intCast(a.len)) - 2 - @as(i64, @intCast(has_val));
    if (nref < 1 or nref > 3) return bs.fail(e_sk_ref, "");
    var r = [3]i32{ -1, -1, -1 };
    for (0..@intCast(nref)) |k| r[k] = bs.ci32(try bs.argNum(a[2 + k]));
    var x: f64 = 0;
    var text: ?[]const u8 = null;
    if (has_val == 1) {
        const v = a[a.len - 1];
        if (v.t == .str) text = std.mem.span(v.u.s);
        x = try bc.aVal(v);
    }
    const e = try edit(a[0]);
    return done(e, sk.addCon(e.b, @intCast(t), r[0], r[1], r[2], x, text));
}

/// dof(sketch): degrees of freedom left; conflicts(sketch): how many
fn dof(a: []const V) Err!V {
    return bs.num(@floatFromInt((try blockOf(a[0])).dof));
}
fn conflicts(a: []const V) Err!V {
    return bs.num(@floatFromInt((try blockOf(a[0])).nbad));
}

/// sx / sy(sketch, point) -> its coordinate; sr(sketch, entity) -> radius
fn coord(a: []const V, w: u8) Err!V {
    const b = try blockOf(a[0]);
    const k = bs.ci32(try bs.argNum(a[1]));
    if (k < 0) return bs.fail(e_sk_ref, "");
    const u: u32 = @intCast(k);
    if (w == 2) {
        if (u >= b.nent) return bs.fail(e_sk_ref, "");
        return bs.num(b.ents[u].r);
    }
    if (u >= b.npt) return bs.fail(e_sk_ref, "");
    const p = sk.pointXY(b, k);
    return bs.num(p[w]);
}
fn sx(a: []const V) Err!V {
    return coord(a, 0);
}
fn sy(a: []const V) Err!V {
    return coord(a, 1);
}
fn sr(a: []const V) Err!V {
    return coord(a, 2);
}

/// skinfo(sketch, "points" | "entities" | "constraints") -> how many (any
/// other word: constraints)
fn skinfo(a: []const V) Err!V {
    const b = try blockOf(a[0]);
    const w = try bs.argStr(a[1]);
    const n = if (std.mem.eql(u8, w, "points")) b.npt else if (std.mem.eql(u8, w, "entities")) b.nent else b.ncon;
    return bs.num(@floatFromInt(n));
}

test "constraints that end with a value" {
    const T = std.testing;
    const with = [_][]const u8{ "distance", "hdistance", "vdistance", "radius", "angle", "length", "diameter" };
    for (sk.con_names[1..]) |n| {
        var want: usize = 0;
        for (with) |w| {
            if (std.mem.eql(u8, w, n)) want = 1;
        }
        try T.expectEqual(want, takesValue(sk.conType(n)));
    }
}
