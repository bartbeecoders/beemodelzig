// BeeScript's curve, procedural, folder and text builtins (script.s b_curve,
// b_cpoints, b_clength, b_cpos, b_lsystem, b_wfc, b_instances, b_instpos,
// b_folder, b_infolder, b_folders, b_refimage, b_text, b_text_set): the
// curve objects (curve.zig), the L-system and wave function collapse
// (procgen.zig), geometry nodes' instances (inst.zig, mods.zig), the
// outliner's folders (folders.zig), reference images (refimg.zig) and text
// objects (text3d.zig). What they change is part of the run's one undo step.
const std = @import("std");
const bs = @import("bscript.zig");
const bsc = @import("bs_scene.zig");
const scene = @import("scene.zig");
const ops = @import("ops.zig");
const app = @import("app.zig");
const curve = @import("curve.zig");
const procgen = @import("procgen.zig");
const folders = @import("folders.zig");
const text3d = @import("text3d.zig");
const mods = @import("mods.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "curve", .f = curveB },
    .{ .name = "cpoints", .f = cpoints },
    .{ .name = "clength", .f = clength },
    .{ .name = "cpos", .f = cpos },
    .{ .name = "lsystem", .f = lsystem },
    .{ .name = "wfc", .f = wfc },
    .{ .name = "instances", .f = instances },
    .{ .name = "instpos", .f = instpos },
    .{ .name = "folder", .f = folder },
    .{ .name = "infolder", .f = infolder },
    .{ .name = "folders", .f = foldersB },
    .{ .name = "refimage", .f = refimage },
    .{ .name = "text", .f = text },
    .{ .name = "text_set", .f = textSet },
};

const e_curve_kind = "curve(kind [, name]): bezier, circle, path or empty";
const e_lsystem = "lsystem: nothing drawn (no F in the result?)";
const e_wfc_tile = "wfc: no tile object named ";
const e_wfc_tiles = "wfc: 1 to 16 tile objects, as one text: \"Road Grass Corner\"";

/// a_int
fn argInt(v: V) Err!i32 {
    return bs.ci32(try bs.argNum(v));
}

/// obj_new(OT_MESH, name, mesh) as scene.s makes it: a unique name (the base
/// keeps 26 bytes), at the origin, a mesh's colour (type_colors). Null when
/// the scene is full (the mesh is dropped).
pub fn newMeshObject(mi: u16, nm: []const u8) ?usize {
    if (scene.count >= scene.max_objects) {
        scene.freeMeshSlot(mi);
        return null;
    }
    const k = scene.count;
    scene.objects[k] = scene.Object{ .kind = .mesh, .mesh = mi, .color = 0xb4b8c0 };
    scene.stamp(k);
    scene.count += 1;
    uniqueName(k, nm);
    return k;
}

/// unique_name as obj_new uses it: "Base", "Base.001" ... (the base keeps 26
/// bytes), checked against every other object.
pub fn uniqueName(i: usize, want: []const u8) void {
    var buf: [32]u8 = undefined;
    const b = want[0..@min(want.len, 26)];
    var k: u32 = 0;
    var cand: []const u8 = b;
    while (true) : (k += 1) {
        @memcpy(buf[0..b.len], b);
        var n = b.len;
        if (k > 0) {
            buf[n] = '.';
            buf[n + 1] = @intCast('0' + k / 100);
            buf[n + 2] = @intCast('0' + k % 100 / 10);
            buf[n + 3] = @intCast('0' + k % 10);
            n += 4;
        }
        cand = buf[0..n];
        if (!takenByOther(i, cand) or k >= 999) break;
    }
    const o = &scene.objects[i];
    o.name_buf = @splat(0);
    @memcpy(o.name_buf[0..cand.len], cand);
    o.name_len = @intCast(cand.len);
}

fn takenByOther(i: usize, nm: []const u8) bool {
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (k != i and std.mem.eql(u8, o.name(), nm)) return true;
    }
    return false;
}

/// The new object selected and active (obj_click_select), its name returned.
fn selRet(i: usize) Err!V {
    scene.selectOnly(i);
    app.dirty = true;
    return bsc.retName(i);
}

// ---- curves ----------------------------------------------------------------------------

const cv_kinds = [_][]const u8{ "bezier", "circle", "path", "empty" };

/// curve(kind [, name]) -> the name of a new curve object at the origin
fn curveB(a: []const V) Err!V {
    const ks = try bs.argStr(a[0]);
    var kind: ?u32 = null;
    for (cv_kinds, 0..) |x, k| {
        if (std.mem.eql(u8, x, ks)) kind = @intCast(k);
    }
    const kd = kind orelse return bs.fail(e_curve_kind, "");
    var nm: ?[]const u8 = null;
    if (a.len >= 2) nm = try bs.argStr(a[1]);
    const i = curve.cvCreate(kd, nm) orelse return bs.fail(e_curve_kind, "");
    // (unique_name: the base keeps 26 bytes)
    var keep: [32]u8 = undefined;
    const base = nm orelse blk: {
        const n0 = scene.objects[i].name();
        @memcpy(keep[0..n0.len], n0);
        break :blk keep[0..n0.len];
    };
    uniqueName(i, base);
    scene.objects[i].color = 0xb4b8c0;
    return selRet(i);
}

/// cpoints(name) -> its control points (-1: not a curve)
fn cpoints(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    const n: f64 = if (curve.cvCount(i)) |c| @floatFromInt(c) else -1;
    return bs.num(n);
}

/// clength(name) -> the length of what it makes (object space; -1: not a curve)
fn clength(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    return bs.num(curve.cvLength(i));
}

/// cpos(name, i, axis) -> control point i's "x", "y" or "z"; nil: no such point
fn cpos(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    const k = try argInt(a[1]);
    const ax = try bs.argStr(a[2]);
    const axis: u32 = @as(u32, if (ax.len > 0) ax[0] else 0) -% 'x';
    const c = curve.cvOf(i) orelse return bs.nil;
    if (@as(u32, @bitCast(k)) >= c.h.npts or axis >= 3) return bs.nil;
    return bs.num(c.pts[@intCast(k)].co[axis]);
}

// ---- procedural ------------------------------------------------------------------------

/// A PMesh into a mesh slot (none for no vertices), freed.
fn slotOf(p: @import("pmesh.zig").PMesh) ?u16 {
    defer p.deinit(curve.A);
    if (p.verts.len == 0) return null;
    return scene.addMesh(p.verts, p.poff, p.loops);
}

/// lsystem(name, axiom, rules, iterations, angle [, step [, radius]]) -> the
/// name of a new object: the turtle's lines, or tubes with a radius
fn lsystem(a: []const V) Err!V {
    const axiom = try bs.argStr(a[1]);
    const rules = try bs.argStr(a[2]);
    const iters = try argInt(a[3]);
    const angle = bs.f32of(try bs.argNum(a[4]));
    var step: f32 = 1.0;
    var radius: f32 = 0;
    if (a.len >= 6) {
        step = bs.f32of(try bs.argNum(a[5]));
        if (a.len >= 7) radius = bs.f32of(try bs.argNum(a[6]));
    }
    const p = procgen.lsBuild(curve.A, axiom, rules, iters, angle, step, radius) orelse return bs.fail(e_lsystem, "");
    if (p.verts.len == 0) {
        p.deinit(curve.A);
        return bs.fail(e_lsystem, "");
    }
    const nm = bs.argStr(a[0]) catch |e| {
        p.deinit(curve.A);
        return e;
    };
    const mi = slotOf(p) orelse return bs.fail(e_lsystem, "");
    const i = newMeshObject(mi, nm) orelse return bs.fail(e_lsystem, "");
    return selRet(i);
}

/// wfc(name, nx, nz, layers, seed, "tile tile ...") -> the name of a new
/// object: the tiles placed by wave function collapse; nil when it cannot be
/// solved
fn wfc(a: []const V) Err!V {
    const nx = try argInt(a[1]);
    const nz = try argInt(a[2]);
    const ny = try argInt(a[3]);
    const sd = try argInt(a[4]);
    const ts = try bs.argStr(a[5]);
    var tiles: [16]usize = undefined;
    var nt: usize = 0;
    var i: usize = 0;
    while (true) {
        // im_next_word: spaces skipped, a word of 255 bytes at most
        while (i < ts.len and ts[i] == ' ') i += 1;
        const st = i;
        while (i < ts.len and ts[i] != ' ') i += 1;
        if (i == st) break;
        const w = ts[st..@min(i, st + 255)];
        if (nt >= 16) return bs.fail(e_wfc_tiles, "");
        tiles[nt] = bsc.find(w) orelse return bs.fail(e_wfc_tile, w);
        nt += 1;
    }
    if (nt == 0) return bs.fail(e_wfc_tiles, "");
    const nm = try bs.argStr(a[0]);
    const mi = @import("wfc.zig").run(tiles[0..nt], nx, nz, ny, sd) orelse return bs.nil;
    const k = newMeshObject(mi, nm) orelse return bs.nil;
    return selRet(k);
}

// ---- instances -------------------------------------------------------------------------

/// instances(name) -> the instances on the evaluated mesh (geometry nodes)
fn instances(a: []const V) Err!V {
    const i = try bsc.argMesh(a[0]);
    const b = mods.instancesOf(i) orelse return bs.num(0);
    return bs.num(@floatFromInt(b.n));
}

/// instpos(name, i, k) -> instance i's place (world): k 0 x, 1 y, 2 z; nil
/// when there is no such instance
fn instpos(a: []const V) Err!V {
    const oi = try bsc.argMesh(a[0]);
    const k = try argInt(a[1]);
    const ax = try argInt(a[2]);
    const b = mods.instancesOf(oi) orelse return bs.nil;
    if (@as(u32, @bitCast(k)) >= b.n) return bs.nil;
    const mt = b.mats[@intCast(k)];
    const t = [3]f32{ mt[3], mt[7], mt[11] };
    if (@as(u32, @bitCast(ax)) > 2) return bs.nil;
    const w = @import("wfc.zig").objMatrix(oi);
    const r: usize = @as(usize, @intCast(ax)) * 4;
    var x = w[r] * t[0];
    x += w[r + 1] * t[1];
    x += w[r + 2] * t[2];
    x += w[r + 3];
    return bs.num(x);
}

// ---- folders ---------------------------------------------------------------------------

/// fd_ensure(name, parent): the uid of the folder of that name (made inside
/// the parent when there is none, the name 31 bytes at most); 0: no room.
pub fn fdEnsure(nm: []const u8, parent: u32) u32 {
    for (folders.list[0..folders.count]) |*r| {
        if (std.mem.eql(u8, folders.nameOf(r), nm)) return r.uid;
    }
    if (folders.count >= folders.MAX) {
        app.log("  folders: 256 at most", .{});
        return 0;
    }
    const uid = folders.make("", parent); // (a record, the next uid)
    const r = folders.get(uid) orelse return 0;
    r.name = @splat(0);
    const l = @min(nm.len, 31);
    @memcpy(r.name[0..l], nm[0..l]);
    app.dirty = true;
    return uid;
}

fn retFolder(uid: u32) Err!V {
    const r = folders.get(uid) orelse return bs.nil;
    return bs.text(folders.nameOf(r));
}

/// folder(name [, parent]) -> its name: the outliner folder of that name, made
/// (inside the parent folder, itself made when missing) when there is none
fn folder(a: []const V) Err!V {
    var par: u32 = 0;
    if (a.len >= 2) par = fdEnsure(try bs.argStr(a[1]), 0);
    return retFolder(fdEnsure(try bs.argStr(a[0]), par));
}

/// infolder(object [, folder]) -> the name of the folder it is in (nil: none);
/// with a folder: it goes there ("": out of any; a new name: made)
fn infolder(a: []const V) Err!V {
    const i = try bsc.argObj(a[0]);
    const o = &scene.objects[i];
    if (a.len >= 2) {
        const s = try bs.argStr(a[1]);
        const uid: u32 = if (s.len == 0) 0 else fdEnsure(s, 0);
        folders.setObject(o, uid);
    }
    return retFolder(o.folder);
}

/// folders() -> how many folders the outliner has
fn foldersB(_: []const V) Err!V {
    return bs.num(@floatFromInt(folders.count));
}

// ---- reference images, text ------------------------------------------------------------

/// refimage(path [, name]) -> the name of a new reference image (Add >
/// Reference Image), nil when the file does not load
fn refimage(a: []const V) Err!V {
    const path = try bs.argStr(a[0]);
    const before = scene.active;
    if (ops.byId("object.add_reference")) |k| bsc.runOp(k, path);
    const now = scene.active orelse return bs.nil;
    if (before != null and before.? == now) return bs.nil;
    if (a.len >= 2) bsc.objRename(now, try bs.argStr(a[1]));
    return bsc.retName(now);
}

/// text(name) -> what a text object says (its body, as typed), nil when it is not text
fn text(a: []const V) Err!V {
    const i = try bsc.argObj(a[0]);
    const b = text3d.txOf(i) orelse return bs.nil;
    return bs.text(b.bodyText());
}

/// text_set(name, body) -> 1: the text object says that now (nil: not text)
fn textSet(a: []const V) Err!V {
    const i = try bsc.argObj(a[0]);
    const body = try bs.argStr(a[1]);
    if (!text3d.bodySet(i, body)) return bs.nil;
    app.dirty = true;
    return bs.num(1);
}
