// The material operators (material.s, matlib.s): new, assign, set, remove,
// preset, apply_preset. They take their arguments from the console or a
// script (ops.arg), as the original's op_arg; the Material tab calls the
// same functions.
const std = @import("std");
const scene = @import("scene.zig");
const material = @import("material.zig");
const ops = @import("ops.zig");
const app = @import("app.zig");
const undo = @import("undo.zig");

/// The words of an argument; "quoted words" may hold spaces.
const Words = struct {
    s: []const u8,
    i: usize = 0,
    fn next(w: *Words) ?[]const u8 {
        while (w.i < w.s.len and w.s[w.i] == ' ') w.i += 1;
        if (w.i >= w.s.len) return null;
        if (w.s[w.i] == '"') {
            const st = w.i + 1;
            const e = std.mem.indexOfScalarPos(u8, w.s, st, '"') orelse w.s.len;
            w.i = @min(e + 1, w.s.len);
            return w.s[st..e];
        }
        const st = w.i;
        while (w.i < w.s.len and w.s[w.i] != ' ') w.i += 1;
        return w.s[st..w.i];
    }
};

/// The active object when it is a mesh, else null.
pub fn activeMesh() ?usize {
    const a = scene.active orelse return null;
    const o = &scene.objects[a];
    if (!o.kind.isMesh() or o.mesh == null) return null;
    return a;
}

pub fn pollActiveMesh() ?[]const u8 {
    return if (activeMesh() == null) "Materials go on meshes: select a mesh object" else null;
}

/// New material (named, else "Material"), given to the active mesh if there is one.
pub fn newMaterial(name: []const u8) ?usize {
    const i = material.new(name) orelse {
        app.log("  the scene holds 1024 materials", .{});
        return null;
    };
    if (activeMesh()) |a| scene.objects[a].mat = @intCast(i + 1);
    return i;
}

pub fn opNew() void {
    var w = Words{ .s = ops.arg };
    const i = newMaterial(w.next() orelse "") orelse return;
    app.log("  material created: {s}", .{material.list[i].nameOf()});
}

pub fn opAssign() void {
    const a = activeMesh() orelse return app.log("  materials go on an active mesh object", .{});
    var w = Words{ .s = ops.arg };
    const nm = w.next() orelse "";
    if (nm.len == 0 or std.mem.eql(u8, nm, "none")) {
        scene.objects[a].mat = 0;
        return;
    }
    const i = material.find(nm) orelse return app.log("  no material named {s}", .{nm});
    scene.objects[a].mat = @intCast(i + 1);
    app.log("  material assigned: {s}", .{nm});
}

pub fn opSet() void {
    var w = Words{ .s = ops.arg };
    const bad = "  material.set <name> <parameter> <values...> (blend: 0 opaque, 1 masked, 2 translucent)";
    const nm = w.next() orelse return app.log(bad, .{});
    const pn = w.next() orelse return app.log(bad, .{});
    const i = material.find(nm) orelse return app.log("  no material named {s}", .{nm});
    const p = material.paramIndex(pn) orelse return app.log(bad, .{});
    var c: usize = 0;
    while (w.next()) |t| : (c += 1) {
        const v = @import("expr.zig").eval(t) orelse break;
        if (!material.set(i, p, c, v)) break;
    }
    if (c == 0) app.log(bad, .{});
}

pub fn opRemove() void {
    var w = Words{ .s = ops.arg };
    const nm = w.next() orelse "";
    const i = material.find(nm) orelse return app.log("  no material named {s}", .{nm});
    material.delete(i);
    app.log("  material removed: {s}", .{nm});
}

const preset_list = "gold silver copper chrome aluminium plastic rubber glass frosted_glass water ceramic car_paint wood marble concrete fabric leather skin clay emissive";

/// material.preset <preset> [material]: the named material, else a new one
/// (called like the preset) for the active mesh.
pub fn opPreset() void {
    var w = Words{ .s = ops.arg };
    const pn = w.next() orelse return app.log("  material.preset <preset> [material] - presets: " ++ preset_list, .{});
    const k = material.presetIndex(pn) orelse return app.log("  no preset named {s}", .{pn});
    const i = blk: {
        if (w.next()) |nm| {
            if (material.find(nm)) |i| break :blk i;
        }
        break :blk newMaterial(material.presets[k].name) orelse return;
    };
    material.applyPreset(i, k);
    app.log("  preset: {s}", .{material.presets[k].name});
}

/// Give the selected meshes preset k: the material named like it, made the
/// first time and set to the preset again after.
pub fn applyToSelected(k: usize) bool {
    const nm = material.presets[k].name;
    const i = material.find(nm) orelse (material.new(nm) orelse return false);
    material.applyPreset(i, k);
    var any = false;
    for (scene.objects[0..scene.count]) |*o| {
        if (!o.selected or !o.kind.isMesh() or o.mesh == null) continue;
        o.mat = @intCast(i + 1);
        any = true;
    }
    return any;
}

pub fn pollSelected() ?[]const u8 {
    return if (scene.nSelected() == 0) "Select an object first" else null;
}

pub fn opApplyPreset() void {
    var w = Words{ .s = ops.arg };
    const pn = w.next() orelse return app.log("  material.apply_preset <preset> - presets: " ++ preset_list, .{});
    const k = material.presetIndex(pn) orelse return app.log("  no preset named {s}", .{pn});
    if (!applyToSelected(k)) app.log("  material.apply_preset: select mesh objects", .{});
}

/// The Material tab's preset menu: the active material, else a new one.
pub fn presetActive(k: usize) void {
    const a = activeMesh() orelse return;
    const i = if (material.of(&scene.objects[a])) |_| scene.objects[a].mat - 1 else (newMaterial(material.presets[k].name) orelse return);
    material.applyPreset(i, k);
    undo.label("Material Preset");
}
