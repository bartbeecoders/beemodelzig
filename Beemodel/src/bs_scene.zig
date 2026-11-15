// BeeScript's scene builtins (script.s b_add .. b_vselect, b_prop, b_frame,
// b_view, b_world ...): objects by name (exactly, case and all, as obj_find),
// their transform and properties (the original's `props:` table), the
// selection, operators, edit mode's vertices, the frame, the viewport camera.
// What they change is part of the run's one undo step (bscript.zig).
const std = @import("std");
const bs = @import("bscript.zig");
const scene = @import("scene.zig");
const ops = @import("ops.zig");
const cat = @import("catalog.zig");
const app = @import("app.zig");
const em = @import("editmesh.zig");
const lcam = @import("lcam.zig");
const anim = @import("anim.zig");
const undo = @import("undo.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "add", .f = add },
    .{ .name = "move", .f = move },
    .{ .name = "rotate", .f = rotate },
    .{ .name = "scale", .f = scale },
    .{ .name = "get", .f = get },
    .{ .name = "set", .f = set },
    .{ .name = "prop", .f = prop },
    .{ .name = "select", .f = select },
    .{ .name = "delete", .f = delete },
    .{ .name = "rename", .f = rename },
    .{ .name = "exists", .f = exists },
    .{ .name = "count", .f = count },
    .{ .name = "name", .f = name },
    .{ .name = "active", .f = active },
    .{ .name = "issel", .f = issel },
    .{ .name = "parent", .f = parent },
    .{ .name = "objtype", .f = objtype },
    .{ .name = "op", .f = op },
    .{ .name = "edit", .f = edit },
    .{ .name = "verts", .f = verts },
    .{ .name = "edges", .f = edges },
    .{ .name = "faces", .f = faces },
    .{ .name = "selected", .f = selected },
    .{ .name = "vpos", .f = vpos },
    .{ .name = "vselect", .f = vselect },
    .{ .name = "vsel", .f = vsel },
    .{ .name = "vmove", .f = vmove },
    .{ .name = "everts", .f = everts },
    .{ .name = "efaces", .f = efaces },
    .{ .name = "volume", .f = volume },
    .{ .name = "frame", .f = frame },
    .{ .name = "frames", .f = frames },
    .{ .name = "frametime", .f = frametime },
    .{ .name = "view", .f = view },
    .{ .name = "viewinfo", .f = viewinfo },
    .{ .name = "world", .f = world },
};

const e_bad_type = "unknown object type (cube sphere cylinder cone torus plane grid light camera): ";
const e_add_args = "add(type, [name], [x, y, z])";
const e_scale_args = "scale(name, s) or scale(name, x, y, z)";
const e_prop = "unknown property (x y z rx ry rz sx sy sz): ";
const e_no_op = "unknown operator: ";
const e_op_script = "scripts can't start scripts: ";
const e_op_modal = "interactive operators can't run from scripts: ";
const e_op_undo = "undo / redo can't run inside a script (the script is one undo step): ";
const e_op_agent = "operator not allowed for agents: ";
const e_not_mesh = "not a mesh: ";
const e_axis = "axis must be 0, 1 or 2 (or \"x\", \"y\", \"z\")";

// ---- objects by name ------------------------------------------------------------------

/// obj_find: the object with exactly this name.
pub fn find(nm: []const u8) ?usize {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (std.mem.eql(u8, o.name(), nm)) return i;
    }
    return null;
}

/// a_obj
pub fn argObj(v: V) Err!usize {
    const nm = try bs.argStr(v);
    return find(nm) orelse bs.fail(bs.e_no_obj, nm);
}

fn isMeshObj(i: usize) bool {
    const o = &scene.objects[i];
    return o.kind.isMesh() and o.mesh != null;
}

/// a_mesh: the named object, which must be a mesh.
pub fn argMesh(v: V) Err!usize {
    const i = try argObj(v);
    if (!isMeshObj(i)) return bs.fail(e_not_mesh, std.mem.span(v.u.s));
    return i;
}

fn meshOf(i: usize) *scene.Mesh {
    return &scene.meshes[scene.objects[i].mesh.?].?;
}

/// ret_name
pub fn retName(i: usize) Err!V {
    return bs.text(scene.objects[i].name());
}

fn nameTaken(nm: []const u8) bool {
    for (scene.objects[0..scene.count]) |*o| {
        if (std.mem.eql(u8, o.name(), nm)) return true;
    }
    return false;
}

/// obj_rename: unique like Blender ("Name.001"); the base keeps 26 bytes.
pub fn objRename(i: usize, want: []const u8) void {
    const o = &scene.objects[i];
    // (its old name is free while checking; an empty name is then its own,
    // taken, so "" comes out ".001" as in the original: checked against it)
    var nm: [32]u8 = undefined;
    const w = want[0..@min(want.len, 26)];
    @memcpy(nm[0..w.len], w); // (`want` may be its own name)
    o.name_len = 0;
    o.name_buf = @splat(0);
    var buf: [32]u8 = undefined;
    const b = nm[0..w.len];
    var k: u32 = 0;
    var cand: []const u8 = b;
    while (true) {
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
        if (!nameTaken(cand)) break;
        k += 1;
        if (k > 999) break;
    }
    o.name_buf = @splat(0);
    @memcpy(o.name_buf[0..cand.len], cand);
    o.name_len = @intCast(cand.len);
}

// ---- operators ---------------------------------------------------------------------

/// run_op from a script: no form, the argument as its text. The port's
/// console reads some operators' arguments itself (file paths, mesh tools'
/// numbers): the same words work here.
pub fn runOp(i: usize, arg: []const u8) void {
    // (inside a request's or a run's one step: the step keeps the selection
    // as it is now, as the original's first undo_push records the scene)
    @import("undo.zig").keepSelection();
    const keep_s = ops.scripted;
    ops.scripted = true;
    defer ops.scripted = keep_s;
    if (@import("editors.zig").runOpLine(cat.entries[i].id, arg)) return;
    ops.arg = arg;
    defer ops.arg = "";
    ops.run(i);
}

fn opByName(id: []const u8) Err!?usize {
    const i = ops.byId(id) orelse return null;
    if (!ops.implemented(i)) return bs.fail(bs.e_not_ported, id);
    return i;
}

/// add(type, [name], [x, y, z]) -> the new object's name
fn add(a: []const V) Err!V {
    if (a.len == 3) return bs.fail(e_add_args, "");
    const ty = try bs.argStr(a[0]);
    var ob: [64]u8 = undefined;
    @memcpy(ob[0..7], "create.");
    const tn = @min(ty.len, 53);
    @memcpy(ob[7 .. 7 + tn], ty[0..tn]);
    const id = ob[0 .. 7 + tn];
    const oi = ops.byId(id) orelse return bs.fail(e_bad_type, ty);
    if (!ops.implemented(oi)) return bs.fail(bs.e_not_ported, id);
    var at: [3]f32 = undefined;
    if (a.len >= 4) {
        for (0..3) |k| at[k] = bs.f32of(try bs.argNum(a[a.len - 3 + k]));
    }
    var nm: ?[]const u8 = null;
    if ((a.len == 2 or a.len == 5) and a[1].t != .nil) nm = try bs.argStr(a[1]);
    runOp(oi, "");
    const i = scene.active orelse return bs.nil;
    if (nm) |n| objRename(i, n);
    if (a.len >= 4) scene.objects[i].loc = at;
    return retName(i);
}

const Which = enum { loc, rot, scl };

/// move / rotate / scale(name, x, y, z); scale(name, s) is uniform
fn set3(a: []const V, w: Which) Err!V {
    if (a.len == 3) return bs.fail(e_scale_args, "");
    const s = bs.f32of(try bs.argNum(a[1]));
    var v: [3]f32 = .{ s, s, s };
    if (a.len != 2) {
        v[1] = bs.f32of(try bs.argNum(a[2]));
        v[2] = bs.f32of(try bs.argNum(a[3]));
    }
    const i = try argObj(a[0]);
    const o = &scene.objects[i];
    switch (w) {
        .loc => o.loc = v,
        .rot => o.setRadians(v),
        .scl => o.scl = v,
    }
    app.dirty = true;
    return bs.nil;
}
fn move(a: []const V) Err!V {
    return set3(a, .loc);
}
fn rotate(a: []const V) Err!V {
    return set3(a, .rot);
}
fn scale(a: []const V) Err!V {
    return set3(a, .scl);
}

// ---- properties (the original's `props:` table) -----------------------------------------

const Prop = enum { x, y, z, rx, ry, rz, sx, sy, sz, color, hidden, select, lens, power, lr, lg, lb };

/// prop_off: the property a name means (7 characters at most, exactly).
fn propOf(v: V) Err!Prop {
    const s = try bs.argStr(v);
    if (s.len <= 7) {
        inline for (@typeInfo(Prop).@"enum".field_names) |f| {
            if (std.mem.eql(u8, f, s)) return @field(Prop, f);
        }
    }
    return bs.fail(e_prop, s);
}

fn lcField(r: *const lcam.Rec, p: Prop) f32 {
    return switch (p) {
        .power => r.power,
        .lr => r.col[0],
        .lg => r.col[1],
        .lb => r.col[2],
        else => @bitCast(r.lens),
    };
}

/// get(name, prop)
fn get(a: []const V) Err!V {
    const p = try propOf(a[1]);
    const i = try argObj(a[0]);
    const o = &scene.objects[i];
    const x: f64 = switch (p) {
        .x, .y, .z => o.loc[@backingInt(p)],
        .rx, .ry, .rz => o.radians()[@backingInt(p) - 3],
        .sx, .sy, .sz => o.scl[@backingInt(p) - 6],
        .color => @floatFromInt(o.color & 0xffffff),
        .hidden => if (o.visible) 0 else 1,
        .select => if (o.selected) 1 else 0,
        else => lcField(lcam.get(o.uid) orelse &lcam.Rec{ .uid = 0 }, p),
    };
    return bs.num(x);
}

/// set(name, prop, value)
fn set(a: []const V) Err!V {
    const p = try propOf(a[1]);
    const x = try bs.argNum(a[2]);
    const i = try argObj(a[0]);
    const o = &scene.objects[i];
    const f = bs.f32of(x);
    switch (p) {
        .x, .y, .z => o.loc[@backingInt(p)] = f,
        .rx, .ry, .rz => {
            var r = o.radians();
            r[@backingInt(p) - 3] = f;
            o.setRadians(r);
        },
        .sx, .sy, .sz => o.scl[@backingInt(p) - 6] = f,
        .color => o.color = @as(u32, @bitCast(bs.ci32(x))) & 0xffffff,
        .hidden => o.visible = bs.ci32(x) == 0,
        .select => o.selected = bs.ci32(x) != 0,
        else => if (lcam.recOwn(o.uid)) |r| {
            switch (p) {
                .power => r.power = f,
                .lr => r.col[0] = f,
                .lg => r.col[1] = f,
                .lb => r.col[2] = f,
                else => r.lens = @bitCast(f),
            }
            lcam.apply(i);
        },
    }
    app.dirty = true;
    return bs.nil;
}

/// prop(path): any animatable property now ("Cube:x", "material:M:roughness"), nil if none
fn prop(a: []const V) Err!V {
    const s = try bs.argStr(a[0]);
    const v = anim.pathValue(s) orelse return bs.nil;
    return bs.num(v);
}

// ---- the selection, names ------------------------------------------------------------

/// select(names...): exactly these, the last one active; select() = none
fn select(a: []const V) Err!V {
    for (a) |v| _ = try argObj(v); // (every name first)
    for (scene.objects[0..scene.count]) |*o| o.selected = false;
    scene.active = null;
    for (a) |v| {
        const i = try argObj(v);
        scene.active = i;
        scene.objects[i].selected = true;
    }
    app.dirty = true;
    return bs.nil;
}

/// delete(names...)
fn delete(a: []const V) Err!V {
    _ = try select(a);
    if (ops.byId("object.delete")) |i| runOp(i, "");
    return bs.nil;
}

/// rename(old, new) -> the name it got
fn rename(a: []const V) Err!V {
    const nm = try bs.argStr(a[1]);
    const i = try argObj(a[0]);
    objRename(i, nm);
    app.dirty = true;
    return retName(i);
}

fn exists(a: []const V) Err!V {
    return bs.num(if (find(try bs.argStr(a[0])) != null) 1 else 0);
}

fn issel(a: []const V) Err!V {
    const i = find(try bs.argStr(a[0])) orelse return bs.num(0);
    return bs.num(if (scene.objects[i].selected) 1 else 0);
}

/// parent(name): the name of the object it follows, or nil
fn parent(a: []const V) Err!V {
    const i = find(try bs.argStr(a[0])) orelse return bs.nil;
    const p = scene.objects[i].parent orelse return bs.nil;
    return retName(p);
}

fn count(_: []const V) Err!V {
    return bs.num(@floatFromInt(scene.count));
}

/// name(i): the i-th object in the outliner (0-based)
fn name(a: []const V) Err!V {
    const k = bs.ci64(try bs.argNum(a[0]));
    if (k < 0 or k >= scene.count) return bs.fail(bs.e_range, "");
    return retName(@intCast(k));
}

fn active(_: []const V) Err!V {
    const i = scene.active orelse return bs.nil;
    return retName(i);
}

/// objtype(object): 0 mesh, 1 light, 2 camera, 3 sketch, 4 armature, 5 force field
fn objtype(a: []const V) Err!V {
    const i = try argObj(a[0]);
    const t: f64 = switch (scene.objects[i].kind) {
        .light => 1,
        .camera => 2,
        .sketch => 3,
        .armature => 4,
        .field => 5,
        else => 0,
    };
    return bs.num(t);
}

/// op(id, [argument]): run an operator
fn op(a: []const V) Err!V {
    const id = try bs.argStr(a[0]);
    const i = ops.byId(id) orelse return bs.fail(e_no_op, id);
    if (std.mem.startsWith(u8, id, "script.")) return bs.fail(e_op_script, id);
    if (std.mem.startsWith(u8, id, "transform.")) return bs.fail(e_op_modal, id);
    if (std.mem.eql(u8, id, "edit.undo") or std.mem.eql(u8, id, "edit.redo")) return bs.fail(e_op_undo, id);
    if (bs.byAgent()) {
        if (!aiSafe(id)) return bs.fail(e_op_agent, id);
        if (bs.agent_gate) |g| {
            if (g(i)) |why| return bs.fail(why, id);
        }
    }
    if (!ops.implemented(i)) return bs.fail(bs.e_not_ported, id);
    var ab: [520]u8 = undefined;
    const arg = if (a.len >= 2) bs.valText(a[1], ab[0..512]) else "";
    runOp(i, arg);
    return bs.nil;
}

fn aiSafe(id: []const u8) bool {
    const as = @import("aisafe.zig");
    for (as.ids) |s| {
        if (std.mem.eql(u8, s, id)) return true;
    }
    return false;
}

// ---- edit mode's vertices ---------------------------------------------------------------

/// The vertex selection of mesh object i: edit mode's when it edits i, else
/// the mesh's own (none yet: none selected, as a new mesh's ME_VSEL).
fn selOf(i: usize) []bool {
    em.validate();
    const me = meshOf(i);
    if (em.active and em.obj == i and em.sel.len == me.verts.len) return em.sel;
    if (me.vsel.len != me.verts.len) {
        const z = @import("alloc.zig").A.alloc(bool, me.verts.len) catch return &.{};
        defer @import("alloc.zig").A.free(z);
        @memset(z, false);
        scene.setMeshSel(scene.objects[i].mesh.?, z);
    }
    return meshOf(i).vsel;
}

/// edit(name): edit mode on that mesh (it becomes active); edit() leaves it
fn edit(a: []const V) Err!V {
    if (a.len == 0) {
        em.exit();
        app.dirty = true;
        return bs.nil;
    }
    const i = try argMesh(a[0]);
    if (em.active) em.exit();
    _ = selOf(i); // (its selection as it is)
    scene.active = i;
    _ = em.enter();
    app.dirty = true;
    return bs.nil;
}

fn verts(a: []const V) Err!V {
    return bs.num(@floatFromInt(meshOf(try argMesh(a[0])).verts.len));
}
fn edges(a: []const V) Err!V {
    return bs.num(@floatFromInt(meshOf(try argMesh(a[0])).edges));
}
fn faces(a: []const V) Err!V {
    return bs.num(@floatFromInt(meshOf(try argMesh(a[0])).faces()));
}

/// selected(name): how many vertices are selected
fn selected(a: []const V) Err!V {
    const i = try argMesh(a[0]);
    var n: usize = 0;
    for (selOf(i)) |s| n += @intFromBool(s);
    return bs.num(@floatFromInt(n));
}

/// vidx: a vertex index, checked
fn vidx(v: V, i: usize) Err!usize {
    const k = bs.ci64(try bs.argNum(v));
    if (k < 0 or k >= meshOf(i).verts.len) return bs.fail(bs.e_range, "");
    return @intCast(k);
}

/// vpos(name, i, axis): a vertex coordinate (object space); axis 0-2 or "x"..
fn vpos(a: []const V) Err!V {
    const i = try argMesh(a[0]);
    const k = try vidx(a[1], i);
    const ax: i64 = if (a[2].t == .str) @as(i64, a[2].u.s[0]) - 'x' else bs.ci32(try bs.argNum(a[2]));
    if (ax < 0 or ax > 2) return bs.fail(e_axis, "");
    return bs.num(meshOf(i).verts[k][@intCast(ax)]);
}

/// vsel(name, i): 1 if that vertex is selected; vsel(name, i, flag) sets it
fn vsel(a: []const V) Err!V {
    const i = try argMesh(a[0]);
    const k = try vidx(a[1], i);
    const s = selOf(i);
    if (a.len >= 3) {
        if (k < s.len) s[k] = bs.truthy(a[2]);
        em.version +%= 1;
        app.dirty = true;
    }
    return bs.num(if (k < s.len and s[k]) 1 else 0);
}

/// vselect(name, i...): exactly these vertices selected; vselect(name) = none
fn vselect(a: []const V) Err!V {
    const i = try argMesh(a[0]);
    for (a[1..]) |v| _ = try vidx(v, i);
    const s = selOf(i);
    @memset(s, false);
    for (a[1..]) |v| {
        const k = try vidx(v, i);
        if (k < s.len) s[k] = true;
    }
    em.version +%= 1;
    app.dirty = true;
    return bs.nil;
}

/// The mesh of object i, to change in place: a copy first when an undo step,
/// another object or the primitives hold it (edit_cow / mesh_copy).
fn ownMesh(i: usize) ?u16 {
    const o = &scene.objects[i];
    const mi = o.mesh.?;
    if (!scene.isPrim(mi) and !undo.holdsMesh(mi) and !undo.anyStepHolds(mi) and !sharedByOthers(i, mi)) return mi;
    const c = scene.cloneMesh(mi) orelse return null;
    if (scene.meshes[mi].?.vsel.len > 0) scene.setMeshSel(c, scene.meshes[mi].?.vsel);
    o.mesh = c;
    return c;
}

fn sharedByOthers(i: usize, mi: u16) bool {
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (k != i and (o.mesh != null and o.mesh.? == mi)) return true;
    }
    return false;
}

/// vmove(name, i, x, y, z): a vertex moved (object space); a copy of the mesh
/// first when an undo step or another object holds it.
fn vmove(a: []const V) Err!V {
    var p: [3]f32 = undefined;
    for (0..3) |k| p[k] = bs.f32of(try bs.argNum(a[2 + k]));
    const i = try argMesh(a[0]);
    const k = try vidx(a[1], i);
    const mi = ownMesh(i) orelse return bs.nil;
    const me = &scene.meshes[mi].?;
    me.verts[k] = p;
    scene.refreshMesh(mi);
    em.version +%= 1;
    app.dirty = true;
    return bs.nil;
}

/// everts / efaces(name): after the modifiers
fn everts(a: []const V) Err!V {
    const i = try argMesh(a[0]);
    const me = @import("mods.zig").of(i) orelse meshOf(i);
    return bs.num(@floatFromInt(me.verts.len));
}
fn efaces(a: []const V) Err!V {
    const i = try argMesh(a[0]);
    const me = @import("mods.zig").of(i) orelse meshOf(i);
    return bs.num(@floatFromInt(me.faces()));
}

/// volume(name): signed, object space (negative: inside out); the triangles
/// summed last to first in doubles, as the original.
fn volume(a: []const V) Err!V {
    const me = meshOf(try argMesh(a[0]));
    var s: f64 = 0;
    var t = me.tris.len;
    while (t > 0) {
        t -= 1;
        const tr = me.tris[t];
        const v0 = me.verts[tr[0]];
        const v1 = me.verts[tr[1]];
        const v2 = me.verts[tr[2]];
        const d = struct {
            fn f(x: f32) f64 {
                return x;
            }
        }.f;
        var x = d(v1[1]) * d(v2[2]) - d(v1[2]) * d(v2[1]);
        x *= d(v0[0]);
        var y = d(v1[2]) * d(v2[0]) - d(v1[0]) * d(v2[2]);
        y *= d(v0[1]);
        x += y;
        var z = d(v1[0]) * d(v2[1]) - d(v1[1]) * d(v2[0]);
        z *= d(v0[2]);
        x += z;
        s += x;
    }
    return bs.num(s * 0.16666666666666666);
}

// ---- the frame, the view, the world ------------------------------------------------------

/// frame([f]): go to frame f; the frame now
fn frame(a: []const V) Err!V {
    if (a.len > 0) anim.apply(bs.f32of(try bs.argNum(a[0])));
    return bs.num(anim.frame);
}

/// frames(): how many frames the window drew
fn frames(_: []const V) Err!V {
    return bs.num(@floatFromInt(bs.frame_count));
}

/// frametime(k [, 1]): the k-th last frame's drawing time in ms (1: its
/// input work instead)
fn frametime(a: []const V) Err!V {
    const k = bs.ci32(try bs.argNum(a[0]));
    const c: u32 = bs.frame_count -% @as(u32, @bitCast(k)) -% 1;
    const slot = c & 255;
    var work = false;
    if (a.len >= 2) work = bs.ci32(try bs.argNum(a[1])) != 0;
    const ns = if (work) bs.frame_work[slot] else bs.frame_ns[slot];
    return bs.num(@as(f64, @floatFromInt(@as(i64, @bitCast(ns)))) / 1000000.0);
}

const f_rad2deg: f32 = 57.29578;

fn theView() ?*@import("viewport.zig").View {
    const k = app.viewportArea();
    if (k < 0) return null;
    return &app.N(k).view;
}

/// view(yaw, pitch, distance, x, y, z): the viewport camera (degrees round
/// and above its target, metres from it)
fn view(a: []const V) Err!V {
    var c: [6]f32 = undefined;
    for (0..6) |k| {
        c[k] = bs.f32of(try bs.argNum(a[k]));
        if (k < 2) c[k] = c[k] / f_rad2deg; // (radians, as the original keeps them)
    }
    const m = @import("math.zig");
    if (theView()) |v| {
        v.cam_view = false;
        v.gliding = false;
        v.yaw = c[0] / m.deg;
        v.pitch = c[1] / m.deg;
        v.dist = c[2];
        v.target = .{ c[3], c[4], c[5] };
        v.setRadians(c[0], c[1]); // (the radians as given: world partition's eye)
    }
    app.dirty = true;
    return bs.nil;
}

/// viewinfo(k): 0 yaw, 1 pitch (degrees), 2 distance, 3..5 the target
fn viewinfo(a: []const V) Err!V {
    const k = bs.ci32(try bs.argNum(a[0]));
    if (k < 0 or k >= 6) return bs.num(0);
    const m = @import("math.zig");
    const v = theView() orelse &@import("viewport.zig").View{};
    const c = [6]f32{ v.yaw * m.deg, v.pitch * m.deg, v.dist, v.target[0], v.target[1], v.target[2] };
    var x = c[@intCast(k)];
    if (k < 2) x *= f_rad2deg;
    return bs.num(x);
}

/// world(k): the world partition (world.zig stat, the original's wp_stat).
fn world(a: []const V) Err!V {
    const k = bs.ci32(try bs.argNum(a[0]));
    return bs.num(@import("world.zig").stat(k));
}
