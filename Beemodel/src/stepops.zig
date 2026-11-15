//! The STEP commands (stepread.s do_istep, step.s do_estep): file.import_step
//! and file.export_step from the console (a path), from the menus and the
//! file browser (.step / .stp), and files dropped on the window. Each
//! imported solid instance becomes a mesh object (its tessellation) as
//! obj_new makes one: named after its product ("Part" ...) made unique as
//! unique_name does, placed and turned as the assembly says, coloured by its
//! styled item. The console says what the original's says.
const std = @import("std");
const app = @import("app.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const m = @import("math.zig");
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const bt = @import("btess.zig");
const sr = @import("stepread.zig");
const step = @import("step.zig");
const Impl = ops.Impl;

const A = std.heap.page_allocator;

pub const list = .{
    .{ "file.import_step", Impl{ .run = opImportStep } },
    .{ "file.export_step", Impl{ .run = opExportStep } },
};

/// type_colors[OT_MESH] (scene.s): obj_new's colour for a mesh object.
const mesh_color: u32 = 0xb4b8c0;

/// unique_name: "Base", "Base.001" ... (the base cut to 26 characters)
fn uniqueName(o: *scene.Object, base0: []const u8) void {
    const base = base0[0..@min(base0.len, 26)];
    var buf: [32]u8 = undefined;
    var k: u32 = 0;
    while (true) : (k += 1) {
        const nm = if (k == 0) base else std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ base, k }) catch base;
        o.setName(nm);
        if (scene.find(o.name()) == null) return;
        if (k >= 999) return;
    }
}

/// An imported solid instance's object (obj_new, then its place and colour):
/// its uid, or null when the scene is full.
fn makeObject(name: []const u8, body: u32, loc: [3]f32, rot: [3]f32, color: ?u32) ?u32 {
    if (scene.count >= scene.max_objects) return null;
    const ts = bt.bdTri(body) orelse return null;
    // bd_tomesh: the vertices (as floats), a triangle per polygon
    const verts = A.alloc(m.V3, ts.nv) catch return null;
    defer A.free(verts);
    for (verts, 0..) |*v, i| v.* = .{ @floatCast(ts.pv[i * 3]), @floatCast(ts.pv[i * 3 + 1]), @floatCast(ts.pv[i * 3 + 2]) };
    const poff = A.alloc(u32, @as(usize, ts.nt) + 1) catch return null;
    defer A.free(poff);
    for (poff, 0..) |*p, i| p.* = @intCast(i * 3);
    // (a solid that tessellates to nothing still makes its object, with an empty mesh)
    const mi = (if (ts.nv == 0) scene.addEmptyMesh() else scene.addMesh(verts, poff, ts.pt[0 .. @as(usize, ts.nt) * 3])) orelse return null;
    var o = scene.Object{ .kind = .mesh, .mesh = mi };
    uniqueName(&o, name);
    o.color = color orelse mesh_color;
    o.loc = loc;
    // (the port keeps degrees)
    for (0..3) |c| o.rot[c] = rot[c] / @as(f32, m.deg);
    scene.objects[scene.count] = o;
    scene.stamp(scene.count);
    scene.count += 1;
    return scene.objects[scene.count - 1].oid;
}

var stopped = false;

/// Between solids: the job's progress, a frame now and then, Esc (a big file
/// would freeze the window, as it does the original's).
fn between(frac: f32) bool {
    const jobui = @import("jobui.zig");
    jobui.set(frac); // (a frame when the last is 100 ms old: Esc is read there)
    if (jobui.stop) stopped = true;
    return jobui.stop;
}

fn expand(buf: []u8, p: []const u8) []const u8 {
    return @import("files.zig").expandHome(buf, p) orelse p;
}

/// do_istep: the file's solids imported; the console says how it went.
pub fn importNow(p0: []const u8) void {
    var eb: [600]u8 = undefined;
    const p = expand(&eb, p0);
    const text = readAll(p);
    var r: i32 = -1;
    if (text) |t| {
        sr.Made.hook = makeObject;
        sr.Made.between = between;
        stopped = false;
        r = sr.stepImport(t);
        if (r < 0) A.free(t);
    }
    if (stopped) app.log("  stopped (Esc): {d} solids imported", .{@max(r, 0)});
    if (r > 0) {
        app.log("  imported {s}", .{p});
    } else if (r == 0) {
        app.log("  no solids in {s}", .{p});
    } else app.log("  could not read {s}", .{p});
    app.dirty = true;
}

/// The whole file, copied (file_read: null when it cannot be read or is empty).
fn readAll(p: []const u8) ?[]u8 {
    const d = @import("ttf.zig").mapFile(p) orelse return null;
    defer _ = std.os.linux.munmap(d.ptr, d.len);
    return A.dupe(u8, d) catch null;
}

fn importLater(p: []const u8) void {
    @import("jobui.zig").later(importJob, "Importing STEP", p, 0, 0);
}
fn importJob(p: []const u8, _: usize, _: usize) void {
    importNow(p);
}

/// file.import_step <path>: from the UI with none, the file browser; from the
/// console with none, the command half typed.
pub fn opImportStep() void {
    const arg = std.mem.trim(u8, ops.arg, " ");
    if (arg.len == 0) {
        if (ops.scripted) return @import("editors.zig").prefillConsole("file.import_step ~/BeeModel/part.step");
        @import("filebrowser.zig").show(.open, "Import STEP", ".step .stp", "", importLater);
        return;
    }
    importLater(arg);
}

/// do_estep: the solids written; the console says how it went.
pub fn exportNow(p0: []const u8) void {
    var eb: [600]u8 = undefined;
    const p = expand(&eb, p0);
    if (!@import("files.zig").mayWrite(p)) return app.toast(.warn, "Headless: not writing outside /tmp ({s})", .{p});
    switch (step.stepExport(p)) {
        .ok => app.log("  exported {s}", .{p}),
        .none => app.log("  no B-rep solids to export (cad.kernel on): {s}", .{p}),
        .cannot_write => app.log("  could not write {s}", .{p}),
    }
}

fn exportLater(p: []const u8) void {
    @import("jobui.zig").later(exportJob, "Exporting STEP", p, 0, 0);
}
fn exportJob(p: []const u8, _: usize, _: usize) void {
    exportNow(p);
}

/// file.export_step <path>
pub fn opExportStep() void {
    const arg = std.mem.trim(u8, ops.arg, " ");
    if (arg.len == 0) {
        if (ops.scripted) return @import("editors.zig").prefillConsole("file.export_step ~/BeeModel/part.step");
        @import("filebrowser.zig").show(.save, "Export STEP", ".step .stp", "part.step", exportLater);
        return;
    }
    exportNow(arg);
}
