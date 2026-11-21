// Operators: every command of the original comes from catalog.zig (id, label,
// shortcut, doc). This file binds the ones the Zig port implements to code:
// run, an optional poll (why it cannot run now) and an optional check (shown
// as a tick in menus). Menus, the F3 palette, tooltips, the F1 list and the
// keyboard all go through here, so a command has one name, one shortcut and
// one reason everywhere. Commands without an implementation stay visible,
// greyed, with "Not available yet".
const std = @import("std");
const cat = @import("catalog.zig");
const app = @import("app.zig");
const scene = @import("scene.zig");
const theme = @import("theme.zig");
const undo = @import("undo.zig");
const xform = @import("xform.zig");
const em = @import("editmesh.zig");
const ui = @import("ui.zig");
const wl = @import("wayland.zig");

pub const Entry = cat.Entry;
pub const entries = &cat.entries;
pub const N = cat.entries.len;

pub const not_ported = "Not available yet";
/// The arguments of the operator being run (the console's words after its id;
/// empty from menus and keys), as the original's op_arg.
pub var arg: []const u8 = "";
/// Run by the console or a form: no dialog asks for values.
pub var scripted: bool = false;
/// The original's op_quiet: set while a BeeScript runs (script.s), which acts
/// silently (bscript.zig sets it while a script runs); not the console, a
/// form or MCP, which run with op_quiet 0 as from the UI.
pub var quiet: bool = false;
const matops = @import("matops.zig");
const uvmod = @import("uv.zig");
const paint = @import("paint.zig");
const uved = @import("uved.zig");
const aops = @import("animops.zig");
const graphcmds = @import("graphcmds.zig");
/// Light probes and the lightmap (probe.zig, lightmap.zig).
const bakeops = struct {
    const probe = @import("probe.zig");
    const lightmap = @import("lightmap.zig");
    fn add() void {
        probe.add(arg);
    }
    fn bake() void {
        probe.opBake(arg);
    }
    fn remove() void {
        probe.remove(arg);
    }
    fn lmBake() void {
        lightmap.opBake(arg);
    }
    fn lmSave() void {
        lightmap.opSave(arg);
    }
};
/// World partition (world.zig).
const wpops = struct {
    const w = @import("world.zig");
    fn part() void {
        w.opPartition(arg);
    }
    fn radius() void {
        w.opRadius(arg);
    }
    fn budget() void {
        w.opBudget(arg);
    }
};
/// Virtualized geometry (vgeo.zig, vgdraw.zig).
const vgops = struct {
    const g = @import("vgeo.zig");
    const d = @import("vgdraw.zig");
    fn build() void {
        g.opBuild(arg);
    }
    fn extract() void {
        g.opExtract(arg);
    }
    fn budget() void {
        d.opBudget(arg);
    }
    fn err() void {
        d.opError(arg);
    }
    fn view() void {
        d.opView(arg);
    }
};
const modstack = @import("mods.zig");

/// The modifier stack's commands (mods.s), on the active mesh.
const modops = struct {
    fn activeMesh() ?usize {
        const a = scene.active orelse return null;
        const o = &scene.objects[a];
        return if (o.mesh != null and o.kind.isMesh()) a else null;
    }
    fn poll() ?[]const u8 {
        return if (activeMesh() == null) "Select a mesh object first" else null;
    }
    fn pollHas() ?[]const u8 {
        const a = activeMesh() orelse return "Select a mesh object first";
        return if (scene.objects[a].mods.n == 0) "This object has no modifiers" else null;
    }
    fn addType(t: u32) void {
        const a = activeMesh() orelse return;
        if (modstack.add(a, t) == null) return app.toast(.warn, "Add Modifier: the stack is full ({d})", .{scene.MOD_MAX});
        app.log("  added {s}", .{modstack.names[t]});
    }
    fn addN(comptime t: u32) *const fn () void {
        return struct {
            fn f() void {
                addType(t);
            }
        }.f;
    }
    fn add() void {
        const nm = std.mem.trim(u8, arg, " \"");
        const t = modstack.typeByName(nm) orelse return app.log("  object.modifier_add mirror|array|solidify|subsurf|bevel|decimate|remesh|boolean|multires", .{});
        if (!modstack.ported(t)) return app.toast(.warn, "{s}: {s}", .{ modstack.names[t], not_ported });
        addType(t);
    }
    /// The first number in the argument, default 0.
    fn index() usize {
        const nm = std.mem.trim(u8, arg, " \"");
        if (nm.len == 0) return 0;
        const x = @import("expr.zig").eval(nm) orelse return 0;
        return if (std.math.isFinite(x) and x >= 0 and x < 8) @intFromFloat(x) else 0;
    }
    fn remove() void {
        const a = activeMesh() orelse return;
        if (!modstack.remove(a, index())) app.log("  object.modifier_remove [index]", .{});
    }
    /// As a job: the chip shows while a heavy stack is made part of the mesh.
    pub fn applyAt(a: usize, k: usize) void {
        @import("jobui.zig").later(applyJob, "Applying a modifier", "", a, k);
    }
    fn applyJob(_: []const u8, a: usize, k: usize) void {
        if (a >= scene.count) return;
        switch (modstack.apply(a, k)) {
            .ok => {},
            .none => app.log("  object.modifier_apply [index]", .{}),
            .failed => app.toast(.warn, "Apply Modifier: this modifier failed on the mesh", .{}),
            .emptied => app.toast(.warn, "Apply Modifier: nothing would be left of the mesh", .{}),
        }
    }
    fn apply() void {
        applyAt(activeMesh() orelse return, index());
    }
    fn up() void {
        _ = modstack.move(activeMesh() orelse return, index(), -1);
    }
    fn down() void {
        _ = modstack.move(activeMesh() orelse return, index(), 1);
    }
    fn toggle() void {
        const a = activeMesh() orelse return;
        const k = index();
        if (k < scene.objects[a].mods.n) scene.objects[a].mods.m[k].flags ^= 1;
    }
    /// object.modifier_set "index parameter value"
    fn set() void {
        const a = activeMesh() orelse return;
        const usage = "  object.modifier_set \"index parameter value\" (e.g. 0 levels 3)";
        var it = std.mem.tokenizeAny(u8, arg, " \"");
        const ks = it.next() orelse return app.log(usage, .{});
        const nm = it.next() orelse return app.log(usage, .{});
        const vs = it.next() orelse return app.log(usage, .{});
        const k = @import("expr.zig").eval(ks) orelse return app.log(usage, .{});
        const v = @import("expr.zig").eval(vs) orelse return app.log(usage, .{});
        if (!std.math.isFinite(k) or k < 0 or k >= 8 or !modstack.set(a, @intFromFloat(k), nm, v)) app.log(usage, .{});
    }
};
pub const applyModifier = modops.applyAt;

/// Edit > Boolean (bool.s): the active mesh with the first other selected one,
/// which is used up ("keep" leaves it).
const boolops = struct {
    fn other() ?usize {
        const a = scene.active orelse return null;
        for (scene.objects[0..scene.count], 0..) |*o, i| {
            if (i != a and o.selected and o.mesh != null and o.kind.isMesh()) return i;
        }
        return null;
    }
    fn poll() ?[]const u8 {
        const a = scene.active orelse return "Select two mesh objects first";
        if (scene.objects[a].mesh == null or !scene.objects[a].kind.isMesh()) return "Select two mesh objects first";
        return if (other() == null) "Select another mesh object too" else null;
    }
    fn job(_: []const u8, op: usize, keep: usize) void {
        const a = scene.active orelse return;
        const b = other() orelse return;
        switch (modstack.bakeBoolean(a, b, @enumFromInt(@as(u32, @intCast(op))))) {
            .ok => {
                if (keep == 0) scene.remove(b);
                undo.label("Boolean");
            },
            .failed => app.toast(.warn, "Boolean: the meshes could not be combined", .{}),
            .emptied => app.toast(.warn, "Boolean: nothing would be left", .{}),
        }
    }
    fn go(op: usize, keep: bool) void {
        @import("jobui.zig").later(job, "Boolean", "", op, @intFromBool(keep));
    }
    fn un() void {
        go(0, false);
    }
    fn diff() void {
        go(1, false);
    }
    fn isect() void {
        go(2, false);
    }
    /// object.boolean union|difference|intersect [keep]
    fn named() void {
        var it = std.mem.tokenizeAny(u8, arg, " \"");
        const k = it.next() orelse return app.log("  object.boolean union|difference|intersect [keep]", .{});
        // (do_boolean: the kind's first letter in any case; "keep" anywhere after it)
        const keep = std.mem.indexOf(u8, arg[@intFromPtr(k.ptr) - @intFromPtr(arg.ptr) ..], "keep") != null;
        const op: usize = switch (k[0] | 0x20) {
            'u' => 0,
            'd', 's' => 1,
            'i' => 2,
            else => return app.log("  object.boolean union|difference|intersect [keep]", .{}),
        };
        go(op, keep);
    }
};

/// The world (env.s) and the scene's images (image.s).
const worldops = struct {
    const env = @import("env.zig");
    const images = @import("images.zig");
    fn trimmed() []const u8 {
        return std.mem.trim(u8, arg, " \"");
    }
    fn number() ?f32 {
        const x = @import("expr.zig").eval(trimmed()) orelse return null;
        return if (std.math.isFinite(x)) x else null;
    }
    pub fn hdri() void {
        const nm = trimmed();
        if (nm.len == 0) return app.log("  world.hdri <image|none>", .{});
        if (std.mem.eql(u8, nm, "none")) {
            env.idx = 0;
            app.log("  world: the studio sky", .{});
        } else if (images.find(nm)) |i| {
            env.idx = @intCast(i + 1);
            app.log("  world: {s}", .{nm});
        } else return app.log("  no image named {s}", .{nm});
        app.dirty = true;
    }
    pub fn strength() void {
        const x = number() orelse return app.log("  world.strength <factor>", .{});
        env.strength = @max(x, 0);
        app.log("  world strength: {d:.3}", .{env.strength});
        app.dirty = true;
    }
    pub fn rotation() void {
        const x = number() orelse return app.log("  world.rotation <degrees>", .{});
        env.rotation = x * std.math.pi / 180;
        app.log("  world rotation: {d:.1}", .{x});
        app.dirty = true;
    }
    fn loaded(p: []const u8) void {
        var pb: [1024]u8 = undefined;
        const path = @import("files.zig").expandHome(&pb, p) orelse return;
        const i = images.load(path) catch |e| {
            app.toast(.warn, "Could not load {s}: {s}", .{ std.fs.path.basename(path), switch (e) {
                error.CannotRead => "cannot read it",
                error.BadImage => "not an image BeeModel reads",
                error.TooMany => "too many images",
            } });
            return;
        };
        app.log("  image {s}: {d} x {d}", .{ images.nameOf(i), images.list[i].img.w, images.list[i].img.h });
        app.dirty = true;
    }
    pub fn imageLoad() void {
        const p = trimmed();
        if (p.len > 0) return loaded(p);
        @import("filebrowser.zig").show(.open, "Load Image", ".png", "", loaded);
    }
    pub fn imageNew() void {
        var it = std.mem.tokenizeAny(u8, arg, " \"");
        const nm = it.next() orelse return app.log("  image.new <name> [width height]", .{});
        const dim = struct {
            fn f(s: ?[]const u8) u32 {
                const x = @import("expr.zig").eval(s orelse return 1024) orelse return 1024;
                return if (std.math.isFinite(x) and x >= 1 and x <= 16384) @intFromFloat(x) else 1024;
            }
        }.f;
        const w = dim(it.next());
        const h = dim(it.next());
        _ = images.new(nm, w, h, .{ 0.2158605, 0.2158605, 0.2158605, 1 }) catch return app.toast(.warn, "New Image: could not make it", .{});
        app.log("  image {s}: {d} x {d}", .{ nm, w, h });
    }
    pub fn imageSave() void {
        var it = std.mem.tokenizeAny(u8, arg, " \"");
        const nm = it.next() orelse return app.log("  image.save <name> <path.png|path.exr>", .{});
        const p0 = it.next() orelse return app.log("  image.save <name> <path.png|path.exr>", .{});
        const i = images.find(nm) orelse return app.log("  no image named {s}", .{nm});
        var pb: [1024]u8 = undefined;
        const path = files.expandHome(&pb, p0) orelse return;
        if (!files.mayWrite(path)) return app.log("  image: not written (tests write under /tmp only): {s}", .{path});
        const A = std.heap.page_allocator;
        const img = &images.list[i].img;
        const data = if (std.ascii.endsWithIgnoreCase(path, ".exr")) blk: {
            const rgb = A.alloc([3]f32, img.px.len) catch return;
            defer A.free(rgb);
            for (img.px, rgb) |p, *o| o.* = .{ p[0], p[1], p[2] };
            break :blk @import("exr.zig").encode(A, img.w, img.h, rgb) catch return;
        } else blk: {
            const px = A.alloc(u32, img.px.len) catch return;
            defer A.free(px);
            const sr = struct {
                fn f(c: f32) u32 {
                    const x = std.math.clamp(c, 0, 1);
                    const s = if (x <= 0.0031308) x * 12.92 else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
                    return @intFromFloat(s * 255 + 0.5);
                }
            }.f;
            for (img.px, px) |p, *o| o.* = (sr(p[0]) << 16) | (sr(p[1]) << 8) | sr(p[2]);
            break :blk @import("png.zig").encode(A, img.w, img.h, px) catch return;
        };
        defer A.free(data);
        @import("bee.zig").writeAtomic(path, data) catch return app.log("  image: could not write the file", .{});
        app.log("  image saved: {s}", .{path});
    }
};
const render = @import("render.zig");

/// Where a shortcut works: anywhere, or with the pointer over a 3D viewport.
pub const Ctx = enum { any, view3d, animed, uved, paint, node };

/// Which mode a shortcut works in (menus and the palette run it anywhere).
pub const Mode = enum { any, object, edit, arm, sculpt, sketch, curve };

pub const Impl = struct {
    run: *const fn () void,
    poll: ?*const fn () ?[]const u8 = null,
    check: ?*const fn () bool = null,
    ctx: Ctx = .any,
    mode: Mode = .any,
};

// --- polls ----------------------------------------------------------------

fn pollSel() ?[]const u8 {
    return if (scene.nSelected() == 0) "Select an object first" else null;
}
fn pollUndo() ?[]const u8 {
    if (@import("cosync.zig").on) return null; // (co-editing keeps its own history)
    return if (!undo.canUndo()) "Nothing to undo" else null;
}
fn pollRedo() ?[]const u8 {
    if (@import("cosync.zig").on) return null;
    return if (!undo.canRedo()) "Nothing to redo" else null;
}
fn pollViewport() ?[]const u8 {
    return if (app.viewportArea() < 0) "There is no 3D viewport in this workspace" else null;
}
fn pollTransform() ?[]const u8 {
    if (app.viewportArea() < 0) return "There is no 3D viewport in this workspace";
    if (em.active) return if (em.anySelected()) null else "Select vertices, edges or faces first";
    return pollSel();
}
fn pollSplit() ?[]const u8 {
    return app.canSplit();
}
fn pollClose() ?[]const u8 {
    return app.canClose();
}
fn pollFloat() ?[]const u8 {
    return app.canFloat();
}
fn pollDock() ?[]const u8 {
    return app.canDock();
}
fn pollHidden() ?[]const u8 {
    for (scene.objects[0..scene.count]) |*o| {
        if (!o.visible) return null;
    }
    return "Nothing is hidden";
}
fn pollTwo() ?[]const u8 {
    return if (app.workspaceCount() < 2) "There is only one workspace" else null;
}

// --- implementations ------------------------------------------------------

const files = @import("files.zig");
fn opNew() void {
    files.guarded(.new, "");
}
fn opExit() void {
    files.guarded(.exit, "");
}
fn opOverhang() void {
    @import("analysis.zig").opOverhang(arg);
}
fn opRedoLast() void {
    @import("redo.zig").opLast(arg);
}
fn opGround() void {
    @import("prims.zig").opGround(arg);
}
fn opRecover() void {
    files.guarded(.recover, "");
}
fn opShot() void {
    @import("screenshot.zig").run(arg);
}
fn opOpen() void {
    files.guarded(.open, "");
}
fn opSave() void {
    files.save();
}
fn opSaveAs() void {
    files.saveAs();
}
fn opImpObj() void {
    files.importDialog(".obj", "Import OBJ");
}
fn opImpStl() void {
    files.importDialog(".stl", "Import STL");
}
fn opExpObj() void {
    files.exportDialog(".obj", "Export OBJ", "scene.obj");
}
fn opExpStl() void {
    files.exportDialog(".stl", "Export STL", "scene.stl");
}
fn opUndo() void {
    if (@import("cosync.zig").undoHook(false)) return; // co-editing: your own last edit
    if (undo.grouped()) return app.log("  undo / redo wait until the running script or agent request is done", .{});
    if (undo.undo()) |l| app.toast(.ok, "Undo: {s}", .{l});
}
fn opRedo() void {
    if (@import("cosync.zig").undoHook(true)) return;
    if (undo.grouped()) return app.log("  undo / redo wait until the running script or agent request is done", .{});
    if (undo.redo()) |l| app.toast(.ok, "Redo: {s}", .{l});
}
fn opHistory() void {
    app.openDialog(.history);
}
fn opPalette() void {
    app.openPalette();
}
fn opShortcuts() void {
    app.openDialog(.shortcuts);
}
fn opAbout() void {
    app.openDialog(.about);
}
fn opListOps() void {
    var n: usize = 0;
    for (cat.entries, 0..) |e, i| {
        if (impl_of[i] != null) {
            app.log("  {s:<28} {s}", .{ e.id, e.label });
            n += 1;
        }
    }
    app.log("{d} of {d} operators are available (F3 lists them all)", .{ n, N });
}
fn opConsoleClear() void {
    app.clearLog();
}
fn opConsoleFocus() void {
    // (asked for: a command's own refocus leaves a maximized area alone)
    app.revealConsole();
    app.focusConsole();
}

fn opSelectAll() void {
    if (scene.nSelected() > 0) scene.deselectAll() else scene.selectAll();
}
fn opDelete() void {
    const n = scene.nSelected();
    if (n == 0) return;
    var i: usize = scene.count;
    while (i > 0) {
        i -= 1;
        if (!scene.objects[i].selected) continue;
        scene.remove(i);
    }
    undo.label("Delete");
    app.toast(.ok, "  objects deleted: {d}", .{n}); // (the original's console line)
}
/// op_duplicate_sel: each selected object copied (obj_copy: its name without
/// a ".NNN" made unique, its transform, colour, mesh, material, folder,
/// modifiers, sketch and multires shared) 2.5 along +X; the copies become the
/// selection, the last one active. As obj_new makes them, a copy has no
/// parent, default flags and default light / camera settings. No grab follows.
fn opDuplicate() void {
    // (edit_unsupported: object operators wait in mesh edit mode)
    if (em.active) return app.log("  not available in edit mode yet (Tab returns to object mode)", .{});
    const first_new = scene.count;
    var made: usize = 0;
    for (0..first_new) |i| {
        if (!scene.objects[i].selected) continue;
        scene.objects[i].selected = false;
        const d = objCopy(i) orelse continue;
        scene.objects[d].loc[0] += 2.5;
        scene.objects[d].selected = true;
        scene.active = d;
        made += 1;
    }
    if (made == 0) {
        app.log("  nothing selected", .{});
        return;
    }
    undo.label("Duplicate");
    app.log("  duplicated: {d}", .{made});
}

/// obj_copy: a new object like object i, at its end of the list (null: full):
/// its name without a ".NNN" made unique, its transform, colour, mesh,
/// material, folder, modifiers, sketch and multires shared; as obj_new makes
/// it, no parent, default flags (shown, not selected) and default light /
/// camera settings. The selection and the active object stay.
pub fn objCopy(i: usize) ?usize {
    if (scene.count >= scene.max_objects) return null;
    const src = &scene.objects[i];
    const fresh = scene.Object{ .kind = src.kind };
    var o = src.*;
    // (obj_new's: flags, the parent table, the light and camera records)
    o.visible = true;
    o.selected = false;
    o.locked = false;
    o.render = true;
    o.folded = false;
    o.ref = 0;
    o.gflags = 0;
    // (the original keeps world transforms: a child's copy stays where it is)
    if (src.parent != null) {
        const wt = scene.worldTRS(i);
        o.loc = wt.loc;
        o.rot = wt.rot;
        o.scl = wt.scl;
    }
    o.parent = null;
    o.parent_gone = 0;
    o.light_type = fresh.light_type;
    o.power = fresh.power;
    o.light_color = fresh.light_color;
    o.size = fresh.size;
    o.cone = fresh.cone;
    o.lens = fresh.lens;
    // base_name, then unique_name
    var nb: [32]u8 = undefined;
    const nm0 = src.name();
    var nl = nm0.len;
    @memcpy(nb[0..nl], nm0);
    if (nl >= 4 and nb[nl - 4] == '.') nl -= 4;
    dupName(&o, nb[0..nl]);
    const d = scene.count;
    scene.objects[d] = o;
    scene.stamp(d);
    if (o.kind == .field) @import("fields.zig").copy(src.uid, scene.objects[d].uid); // (fl_copy)
    @import("particles.zig").copy(src.uid, scene.objects[d].uid); // (ps_copy: its particle systems)
    scene.count += 1;
    return d;
}

/// unique_name: "Base", "Base.001" ... (the base cut to 26 characters)
fn dupName(o: *scene.Object, base0: []const u8) void {
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
fn opHide() void {
    var n: usize = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (o.selected) {
            o.visible = false;
            o.selected = false;
            n += 1;
        }
    }
    scene.active = null;
    undo.label("Hide");
    if (n > 0) app.toast(.ok, "Hid {d} object{s} (Alt+H shows them again)", .{ n, if (n == 1) "" else "s" });
}
fn opReveal() void {
    scene.deselectAll();
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (!o.visible) {
            o.visible = true;
            o.selected = true;
            scene.active = i;
        }
    }
    undo.label("Reveal Hidden");
}

fn addKind(k: scene.Kind) void {
    if (scene.add(k)) |i| {
        undo.label("Add");
        if (!quiet) app.toast(.ok, "  added {s}", .{scene.objects[i].name()}); // (the original's console line; quiet in scripts)
    } else app.toast(.warn, "The scene is full ({d} objects)", .{scene.max_objects});
}
fn opCube() void {
    addKind(.cube);
}
fn opSphere() void {
    addKind(.sphere);
}
fn opCylinder() void {
    addKind(.cylinder);
}
fn opPlane() void {
    addKind(.plane);
}
fn opLight() void {
    addKind(.light);
}
fn opCamera() void {
    addKind(.camera);
}

fn opGrab() void {
    _ = app.beginTransform(.move);
}
fn opRotate() void {
    _ = app.beginTransform(.rotate);
}
fn opScale() void {
    _ = app.beginTransform(.scale);
}
fn toolSel() void {
    app.tool = .select;
}
fn toolMove() void {
    app.tool = .move;
}
fn toolRot() void {
    app.tool = .rotate;
}
fn toolScl() void {
    app.tool = .scale;
}
fn isToolSel() bool {
    return app.tool == .select;
}
fn isToolMove() bool {
    return app.tool == .move;
}
fn isToolRot() bool {
    return app.tool == .rotate;
}
fn isToolScl() bool {
    return app.tool == .scale;
}

fn opWire() void {
    app.toggleWire();
}
fn isWire() bool {
    return app.isWire();
}
fn opGrid() void {
    scene.show_grid = !scene.show_grid;
}
fn isGrid() bool {
    return scene.show_grid;
}
fn opSnap() void {
    xform.snap_default = !xform.snap_default;
}
fn isSnap() bool {
    return xform.snap_default;
}
fn opResetCam() void {
    app.resetView();
}
fn opFrameSel() void {
    app.frameSelected();
}
fn opFront() void {
    app.alignView(0, 0);
}
fn opBack() void {
    app.alignView(180, 0);
}
fn opRight() void {
    app.alignView(90, 0);
}
fn opLeft() void {
    app.alignView(-90, 0);
}
fn opTop() void {
    app.alignView(0, 89.9);
}
fn opBottom() void {
    app.alignView(0, -89.9);
}
fn opCursorReset() void {
    scene.cursor = .{ 0, 0, 0 };
    undo.label("Reset 3D Cursor");
}
fn opCursorSel() void {
    if (scene.selCenter()) |c| scene.cursor = c;
    undo.label("Cursor to Selected");
}
fn opSelCursor() void {
    const mm = @import("math.zig");
    const c = scene.selCenter() orelse return;
    const d = mm.sub(scene.cursor, c);
    for (0..scene.count) |i| {
        if (scene.objects[i].selected and !scene.followsSelected(i)) scene.setWorldLoc(i, mm.add(scene.worldLoc(i), d));
    }
    undo.label("Selection to Cursor");
}
fn opSelGrid() void {
    for (0..scene.count) |i| {
        if (!scene.objects[i].selected or scene.followsSelected(i)) continue;
        var p = scene.worldLoc(i);
        for (&p) |*v| v.* = @round(v.*);
        scene.setWorldLoc(i, p);
    }
    undo.label("Selection to Grid");
}
fn pollTwo2() ?[]const u8 {
    if (arg.len > 0) return null; // (named: object.parent_set <child> <parent>)
    if (scene.active == null) return "Select the parent last (it is the active object)";
    return if (scene.nSelected() < 2) "Select the children, then the parent last" else null;
}
fn opParentSet() void {
    // object.parent_set <child> <parent>: named, as scripts say it
    var words = std.mem.tokenizeAny(u8, arg, " \"");
    if (words.next()) |cn| {
        const c = scene.find(cn) orelse return app.log("  object.parent_set <child> <parent>", .{});
        const pi = scene.find(words.next() orelse return app.log("  object.parent_set <child> <parent>", .{})) orelse return app.log("  object.parent_set <child> <parent>", .{});
        if (!scene.setParent(c, pi)) app.toast(.warn, "Parent: {s} is above {s}", .{ scene.objects[c].name(), scene.objects[pi].name() });
        undo.label("Parent");
        return;
    }
    const p = scene.active orelse return;
    var n: usize = 0;
    var loops: usize = 0;
    for (0..scene.count) |i| {
        if (i == p or !scene.objects[i].selected) continue;
        if (scene.setParent(i, p)) n += 1 else loops += 1;
    }
    undo.label("Parent");
    if (loops > 0) app.toast(.warn, "Parent: {d} object(s) skipped (they are above {s})", .{ loops, scene.objects[p].name() }) else app.toast(.ok, "{d} object{s} now follow{s} {s}", .{ n, if (n == 1) "" else "s", if (n == 1) "s" else "", scene.objects[p].name() });
}
fn pollHasParent() ?[]const u8 {
    for (scene.objects[0..scene.count]) |*o| {
        if (o.selected and (o.parent != null or o.parent_gone != 0)) return null;
    }
    return "No selected object has a parent";
}
fn opParentClear() void {
    for (0..scene.count) |i| {
        if (scene.objects[i].selected and scene.objects[i].parent != null) _ = scene.setParent(i, null);
        // (do_par_clear: OB_PARENT 0 for every selected one, a deleted parent's uid too)
        if (scene.objects[i].selected) scene.objects[i].parent_gone = 0;
    }
    undo.label("Clear Parent");
}

fn pivMed() void {
    xform.pivot_mode = .median;
}
fn pivCur() void {
    xform.pivot_mode = .cursor;
}
fn pivInd() void {
    xform.pivot_mode = .individual;
}
fn pivAct() void {
    xform.pivot_mode = .active;
}
fn isPivMed() bool {
    return xform.pivot_mode == .median;
}
fn isPivCur() bool {
    return xform.pivot_mode == .cursor;
}
fn isPivInd() bool {
    return xform.pivot_mode == .individual;
}
fn isPivAct() bool {
    return xform.pivot_mode == .active;
}

fn themeFn(comptime idx: usize) *const fn () void {
    return struct {
        fn f() void {
            app.setTheme(theme.all[idx]);
        }
    }.f;
}
fn themeIs(comptime idx: usize) *const fn () bool {
    return struct {
        fn f() bool {
            return theme.base == theme.all[idx];
        }
    }.f;
}
fn opAccentNone() void {
    theme.setAccent(null);
    app.toast(.ok, "Accent: the theme's own", .{});
}
fn pollAccent() ?[]const u8 {
    return if (theme.accent == null) "The theme's accent is in use" else null;
}

fn opSplitSide() void {
    app.splitActive(true);
}
fn opSplitStack() void {
    app.splitActive(false);
}
fn opMaximize() void {
    app.maximizeActive();
}
fn isMaximized() bool {
    return app.isMaximized();
}
fn opClose() void {
    app.closeActive();
}
fn opFloat() void {
    app.floatActive();
}
fn opDock() void {
    app.dockActive();
}

fn edFn(comptime e: app.Editor) *const fn () void {
    return struct {
        fn f() void {
            app.setActiveEditor(e);
        }
    }.f;
}
fn edIs(comptime e: app.Editor) *const fn () bool {
    return struct {
        fn f() bool {
            return app.activeEditor() == e;
        }
    }.f;
}

fn wsNext() void {
    app.workspaceStep(1);
}
fn wsPrev() void {
    app.workspaceStep(-1);
}
fn wsNew() void {
    app.workspaceNew();
    const nm = std.mem.trim(u8, arg, " \"");
    if (nm.len > 0) wsRename();
}
fn wsSet() void {
    @import("wsfile.zig").opSet(std.mem.trim(u8, arg, " \""));
}
fn wsRename() void {
    @import("wsfile.zig").opRename(std.mem.trim(u8, arg, " \""));
}
fn wsDelete() void {
    app.workspaceDelete();
}

fn opToolsPane() void {
    app.togglePane(.tools);
}
fn opConsolePane() void {
    app.togglePane(.console);
}
fn opOutlinerPane() void {
    app.togglePane(.outliner);
}
fn hasTools() bool {
    return app.hasEditor(.tools);
}
fn hasConsole() bool {
    return app.hasEditor(.console);
}
fn hasOutliner() bool {
    return app.hasEditor(.outliner);
}

fn vpView() ?*@import("viewport.zig").View {
    const v = app.viewportArea();
    return if (v < 0) null else &app.N(v).view;
}
fn shWire() void {
    if (vpView()) |v| {
        v.wire = true;
        v.material = false;
        v.rendered = false;
    }
}
fn shSolid() void {
    if (vpView()) |v| {
        v.wire = false;
        v.material = false;
        v.rendered = false;
    }
}
fn shMat() void {
    if (vpView()) |v| {
        v.wire = false;
        v.material = true;
        v.rendered = false;
    }
}
fn shRendered() void {
    if (vpView()) |v| {
        v.wire = false;
        v.material = true; // (the base under the samples)
        v.rendered = true;
    }
}
/// View > Rendered (op_shading_set): on, or back to Solid.
fn opRendered() void {
    if (isShRendered()) shSolid() else shRendered();
}
fn isShRendered() bool {
    return if (vpView()) |v| !v.wire and v.rendered else false;
}
fn isShWire() bool {
    return if (vpView()) |v| v.wire else false;
}
fn isShSolid() bool {
    return if (vpView()) |v| !v.wire and !v.material else false;
}
fn isShMat() bool {
    return if (vpView()) |v| !v.wire and v.material and !v.rendered else false;
}
/// Shift+Z: Material Preview, or back to Solid.
fn opMatPrev() void {
    if (vpView()) |v| {
        const was_rendered = v.rendered;
        v.rendered = false;
        if (!v.wire and v.material and !was_rendered) v.material = false else {
            v.wire = false;
            v.material = true;
        }
    }
}
fn opOrtho() void {
    if (vpView()) |v| {
        @import("viewport.zig").leaveCamView(v);
        v.ortho = !v.ortho;
        v.auto_ortho = false; // (chosen: orbiting keeps it)
    }
}
fn isOrtho() bool {
    return if (vpView()) |v| v.ortho else false;
}
fn pollCamera() ?[]const u8 {
    if (app.viewportArea() < 0) return "There is no 3D viewport in this workspace";
    return if (@import("viewport.zig").sceneCamera() == null) "There is no camera in the scene (Camera to View adds one)" else null;
}
fn opCamView() void {
    const v = vpView() orelse return;
    if (v.cam_view) {
        // back to the view from before
        v.cam_view = false;
        v.setPose(v.before_cam);
    } else {
        v.before_cam = v.pose();
        v.cam_view = true;
        v.gliding = false;
    }
}
fn pollCamSelected() ?[]const u8 {
    if (app.viewportArea() < 0) return "There is no 3D viewport in this workspace";
    const a = scene.active orelse return "Select a camera first";
    return if (scene.objects[a].kind != .camera) "The active object is not a camera" else null;
}
/// Ctrl+Numpad 0: the selected camera renders, and the viewport looks through it.
fn opCamSelected() void {
    const v = vpView() orelse return;
    const a = scene.active orelse return;
    if (scene.objects[a].kind != .camera) return;
    @import("lcam.zig").renderFrom(a);
    if (!v.cam_view) {
        v.before_cam = v.pose();
        v.cam_view = true;
    }
    v.gliding = false;
    undo.label("Look Through Camera");
}
fn isCamView() bool {
    return if (vpView()) |v| v.cam_view else false;
}
fn opCamToView() void {
    const vpm = @import("viewport.zig");
    const mm = @import("math.zig");
    const vi = app.viewportArea();
    if (vi < 0) return;
    const v = &app.N(vi).view;
    const ci = vpm.sceneCamera() orelse blk: {
        const k = scene.add(.camera) orelse return;
        break :blk k;
    };
    const was_cam = v.cam_view;
    if (!was_cam) v.before_cam = v.pose();
    v.cam_view = false;
    const c = vpm.Cam.init(v, app.N(vi).rect);
    v.cam_view = was_cam;
    // the camera looks along its -Z: rotation from the view's axes
    const R = mm.M3{ c.right[0], c.up[0], -c.fwd[0], c.right[1], c.up[1], -c.fwd[1], c.right[2], c.up[2], -c.fwd[2] };
    scene.objects[ci].loc = if (v.ortho) mm.add(v.target, mm.scale(c.fwd, -v.dist)) else c.eye;
    scene.objects[ci].rot = mm.matEuler(R);
    v.cam_view = true;
    v.ortho = false;
    v.gliding = false;
    undo.label("Camera to View");
}
fn ovText() void {
    if (vpView()) |v| v.show_text = !v.show_text;
}
fn ovStats() void {
    if (vpView()) |v| v.show_stats = !v.show_stats;
}
fn ovGizmo() void {
    if (vpView()) |v| v.show_gizmo = !v.show_gizmo;
}
fn isOvText() bool {
    return if (vpView()) |v| v.show_text else false;
}
fn isOvStats() bool {
    return if (vpView()) |v| v.show_stats else false;
}
fn isOvGizmo() bool {
    return if (vpView()) |v| v.show_gizmo else false;
}
const armedit = @import("armedit.zig");
const armops = struct {
    fn activeArmature() bool {
        return if (scene.active) |a| scene.objects[a].kind == .armature else false;
    }
};
const sculpt = @import("sculpt.zig");
fn modeObject() void {
    @import("curveui.zig").exit();
    paint.exit();
    sculpt.exit();
    if (em.active) em.exit();
    if (armedit.mode != 0) {
        armedit.mode = 0;
        app.dirty = true;
    }
}
fn modeEdit() void {
    if (armedit.mode != 1 and armops.activeArmature()) {
        _ = armedit.tab();
        return;
    }
    if (em.active) return;
    sculpt.exit(); // (one mode at a time)
    paint.exit();
    if (em.enter()) |why| app.toast(.warn, "Edit Mode: {s}", .{why});
}
fn modeToggle() void {
    if (@import("curveui.zig").tab()) return; // (curve edit mode)
    if (armedit.tab()) return; // (armature edit mode)
    if (@import("sketchui.zig").tab()) return; // (sketch mode)
    if (em.active) em.exit() else modeEdit();
}
fn isEdit() bool {
    return em.active or armedit.mode == 1;
}
fn isObjectMode() bool {
    return !em.active and armedit.mode == 0 and !sculpt.on and !paint.on;
}
fn pollEditable() ?[]const u8 {
    if (em.active or armedit.mode != 0 or @import("sketchui.zig").on()) return null;
    if (scene.active) |a| {
        if (scene.objects[a].kind == .sketch) return null;
    }
    const a = scene.active orelse return "Select a mesh object first";
    if (scene.objects[a].kind == .armature) return null;
    if (scene.objects[a].mesh == null or !scene.objects[a].kind.isMesh()) return "The active object has no mesh";
    return null;
}
fn pollEdit() ?[]const u8 {
    return if (em.active) null else "Only in edit mode (Tab)";
}
fn pollEditSel() ?[]const u8 {
    if (!em.active) return "Only in edit mode (Tab)";
    return if (em.anySelected()) null else "Select vertices, edges or faces first";
}
fn smVert() void {
    em.sel_mode = .vertex;
    em.version +%= 1;
}
fn smEdge() void {
    em.sel_mode = .edge;
    em.version +%= 1;
}
fn smFace() void {
    em.sel_mode = .face;
    em.version +%= 1;
}
fn isSmVert() bool {
    return em.active and em.sel_mode == .vertex;
}
fn isSmEdge() bool {
    return em.active and em.sel_mode == .edge;
}
fn isSmFace() bool {
    return em.active and em.sel_mode == .face;
}
fn meshSelAll() void {
    em.selectAll();
}
fn meshInvert() void {
    em.invert();
}
fn meshLinked() void {
    em.selectLinked();
}
fn meshBox() void {
    em.box_armed = true;
    app.toast(.ok, "Box Select: drag a rectangle (Ctrl subtracts)", .{});
}
fn meshDeleteBy(md: em.SelMode) void {
    const saved = em.sel_mode;
    em.sel_mode = md;
    if (em.delete()) |why| app.toast(.warn, "Delete: {s}", .{why});
    em.sel_mode = saved;
}
fn meshDelete() void {
    meshDeleteBy(em.sel_mode);
}
fn meshDelV() void {
    meshDeleteBy(.vertex);
}
fn meshDelE() void {
    meshDeleteBy(.edge);
}
fn meshDelF() void {
    meshDeleteBy(.face);
}
const mo = @import("meshops.zig");
fn needFaces() ?[]const u8 {
    if (!em.active) return "Only in edit mode (Tab)";
    const me = em.mesh() orelse return "No mesh";
    for (0..me.poff.len - 1) |p| {
        if (em.faceSelected(me, p)) return null;
    }
    return "Select faces first (face select: 3)";
}
/// A number after a mesh tool's id: no modal, as the original's scripts.
fn argValue() ?f32 {
    const t = std.mem.trim(u8, arg, " \"");
    if (t.len == 0) return null;
    const v = @import("expr.zig").eval(t) orelse return null;
    return if (std.math.isFinite(v)) v else null;
}
fn opExtrude() void {
    const rd = @import("redo.zig");
    rd.before();
    const dir = mo.extrude() catch null;
    if (dir) |d| {
        if (argValue()) |v| return rd.extrudeBy(d, v);
        if (!app.beginTransformAlong(d)) {}
    } else app.toast(.warn, "Extrude: select faces or edges first", .{});
}
fn opExtrudeInd() void {
    if (argValue()) |v| {
        const rd = @import("redo.zig");
        rd.before();
        if (mo.extrudeIndividual(v) catch false) rd.set(.extrude_individual, &.{v});
        return;
    }
    if (!app.beginMeshTool(.extrude_individual)) app.toast(.warn, "Extrude Individual: select faces first", .{});
}
fn opInset() void {
    if (argValue()) |v| {
        const rd = @import("redo.zig");
        rd.before();
        if (mo.inset(v) catch false) rd.set(.inset, &.{v});
        return;
    }
    if (!app.beginMeshTool(.inset)) app.toast(.warn, "Inset: select faces first", .{});
}
fn opMerge() void {
    if (!(mo.mergeCenter() catch false)) app.toast(.warn, "Merge: select two vertices or more", .{});
}
fn opFill() void {
    const v = app.viewportArea();
    mo.view_eye = if (v >= 0) @import("viewport.zig").Cam.init(&app.N(v).view, app.N(v).rect).eye else null;
    if (mo.fill() catch "it failed") |why| app.toast(.warn, "Fill: {s}", .{why});
}
fn opMeshDup() void {
    if (mo.duplicate() catch false) {
        _ = app.beginTransform(.move);
    } else app.toast(.warn, "Duplicate: select faces first", .{});
}
fn opFlip() void {
    if (!(mo.flipNormals() catch false)) app.toast(.warn, "Flip Normals: select faces first", .{});
}
fn opRecalc() void {
    if (!(mo.recalcNormals() catch false)) app.toast(.warn, "Recalculate Normals: nothing to do", .{});
}
fn opSubdiv() void {
    if (!(mo.subdivide() catch false)) app.toast(.warn, "Subdivide: select faces first", .{});
}
const mo2 = @import("meshops2.zig");
fn opCollapse() void {
    const n = mo2.mergeCollapse() catch null;
    if (n) |k| app.toast(.ok, "Merged {d} vertices", .{k}) else app.toast(.warn, "Merge Collapse failed", .{});
}
fn opMergeDist() void {
    const rd = @import("redo.zig");
    rd.before();
    const n = mo2.mergeDistance(0.0001) catch null;
    if (n != null) rd.set(.merge_distance, &.{0.0001});
    if (n) |k| app.toast(.ok, "Merged {d} vertices (closer than 0.0001)", .{k}) else app.toast(.warn, "Merge by Distance failed", .{});
}
fn opBridge() void {
    if (mo2.bridge() catch "it failed") |why| app.toast(.warn, "Bridge: {s}", .{why});
}
fn pollSepLoose() ?[]const u8 {
    if (em.active) return "Only in object mode (Tab)";
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.selected and scene.meshOfObj(i) != null) return null;
    }
    return "Select a mesh object first";
}
fn opSepLoose() void {
    const n = mo2.separateLoose() catch 0;
    undo.label("Separate By Loose Parts");
    if (n == 0) app.toast(.warn, "Separate: no selected mesh has loose parts", .{}) else app.toast(.ok, "{d} new object{s} from loose parts", .{ n, if (n == 1) "" else "s" });
}
fn pollRepair() ?[]const u8 {
    if (em.active) return null;
    return pollSepLoose() orelse null;
}
fn opRepair() void {
    var total = mo2.RepairReport{};
    var n: usize = 0;
    if (em.active) {
        total = mo2.repair(0.0001) catch return app.toast(.warn, "Repair failed", .{});
        n = 1;
    } else {
        // every selected mesh, through edit mode
        const act = scene.active;
        for (0..scene.count) |i| {
            if (!scene.objects[i].selected or scene.meshOfObj(i) == null) continue;
            scene.active = i;
            if (em.enter() != null) continue;
            const r = mo2.repair(0.0001) catch {
                em.exit();
                continue;
            };
            em.exit();
            total.merged += r.merged;
            total.degenerate += r.degenerate;
            total.duplicates += r.duplicates;
            total.holes += r.holes;
            total.loose += r.loose;
            n += 1;
        }
        scene.active = act;
    }
    undo.label("Repair Mesh");
    app.toast(.ok, "Repaired {d} mesh{s}: {d} merged, {d} degenerate and {d} duplicate faces, {d} holes filled, {d} vertices removed", .{ n, if (n == 1) "" else "es", total.merged, total.degenerate, total.duplicates, total.holes, total.loose });
}
fn opKnife() void {
    mo2.knStart();
}
fn opBevel() void {
    if (!app.beginMeshTool(.bevel)) app.toast(.warn, "Bevel: select edges first", .{});
}
fn opBisect() void {
    if (mo2.bisect(scene.cursor, .{ 0, 1, 0 }) catch "it failed") |why| app.toast(.warn, "Bisect: {s}", .{why});
}
fn opSpin() void {
    const rd = @import("redo.zig");
    rd.before();
    if (mo2.spin(12, 360, 1) catch "it failed") |why| app.toast(.warn, "Spin: {s}", .{why}) else rd.set(.spin, &.{ 12, 360, 1 });
}
fn opLoopCut() void {
    mo2.lcStart();
    app.toast(.ok, "Loop Cut: point at an edge, the wheel sets the cuts, click to cut (Esc stops)", .{});
}
fn opDissolve() void {
    if (mo.dissolve() catch "it failed") |why| app.toast(.warn, "Dissolve: {s}", .{why});
}
fn orGlob() void {
    xform.orient = .global;
}
fn orLoc() void {
    xform.orient = .local;
}
fn orView() void {
    xform.orient = .view;
}
fn orNrm() void {
    xform.orient = .normal;
}
fn isOrGlob() bool {
    return xform.orient == .global;
}
fn isOrLoc() bool {
    return xform.orient == .local;
}
fn isOrView() bool {
    return xform.orient == .view;
}
fn isOrNrm() bool {
    return xform.orient == .normal;
}

fn opPrefs() void {
    app.openDialog(.prefs);
}

fn opNextArea() void {
    app.cycleArea(1);
}
fn opPrevArea() void {
    app.cycleArea(-1);
}

const impl_list = .{
    .{ "file.new", Impl{ .run = opNew } },
    .{ "file.exit", Impl{ .run = opExit } },
    .{ "file.open", Impl{ .run = opOpen } },
    .{ "file.save", Impl{ .run = opSave } },
    .{ "file.save_as", Impl{ .run = opSaveAs } },
    .{ "file.import_obj", Impl{ .run = opImpObj } },
    .{ "file.import_stl", Impl{ .run = opImpStl } },
    .{ "file.export_obj", Impl{ .run = opExpObj } },
    .{ "file.export_stl", Impl{ .run = opExpStl } },
    .{ "file.recover", Impl{ .run = opRecover } },
    .{ "view.show_normals", Impl{ .run = @import("analysis.zig").opNormals, .check = @import("analysis.zig").isNormals } },
    .{ "view.show_nonmanifold", Impl{ .run = @import("analysis.zig").opNonman, .check = @import("analysis.zig").isNonman } },
    .{ "view.show_boundary", Impl{ .run = @import("analysis.zig").opBound, .check = @import("analysis.zig").isBound } },
    .{ "view.show_degenerate", Impl{ .run = @import("analysis.zig").opDegen, .check = @import("analysis.zig").isDegen } },
    .{ "view.show_overhangs", Impl{ .run = opOverhang, .check = @import("analysis.zig").isOver } },
    .{ "edit.redo_last", Impl{ .run = opRedoLast } },
    .{ "edit.redo_prompt", Impl{ .run = @import("redo.zig").opPrompt } },
    .{ "view.screenshot", Impl{ .run = opShot } },
    .{ "edit.undo", Impl{ .run = opUndo, .poll = pollUndo } },
    .{ "edit.redo", Impl{ .run = opRedo, .poll = pollRedo } },
    .{ "edit.undo_history", Impl{ .run = opHistory } },
    .{ "palette.open", Impl{ .run = opPalette } },
    .{ "edit.preferences", Impl{ .run = opPrefs } },
    .{ "help.shortcuts", Impl{ .run = opShortcuts } },
    .{ "help.about", Impl{ .run = opAbout } },
    .{ "console.list_ops", Impl{ .run = opListOps } },
    .{ "console.clear", Impl{ .run = opConsoleClear } },
    .{ "console.focus", Impl{ .run = opConsoleFocus } },

    .{ "object.select_all", Impl{ .run = opSelectAll, .ctx = .view3d, .mode = .object } },
    .{ "object.delete", Impl{ .run = opDelete, .poll = pollSel, .ctx = .view3d, .mode = .object } },
    .{ "object.delete_key", Impl{ .run = opDelete, .poll = pollSel, .ctx = .view3d, .mode = .object } },
    .{ "object.duplicate", Impl{ .run = opDuplicate, .poll = pollSel, .ctx = .view3d, .mode = .object } },
    .{ "object.hide", Impl{ .run = opHide, .poll = pollSel, .ctx = .view3d, .mode = .object } },
    .{ "object.reveal", Impl{ .run = opReveal, .poll = pollHidden, .ctx = .view3d, .mode = .object } },
    .{ "object.parent_set", Impl{ .run = opParentSet, .poll = pollTwo2, .ctx = .view3d, .mode = .object } },
    .{ "object.parent_clear", Impl{ .run = opParentClear, .poll = pollHasParent, .ctx = .view3d, .mode = .object } },
    .{ "object.to_cursor", Impl{ .run = opSelCursor, .poll = pollSel } },
    .{ "object.to_grid", Impl{ .run = opSelGrid, .poll = pollSel } },
    .{ "create.cube", Impl{ .run = opCube } },
    .{ "create.sphere", Impl{ .run = opSphere } },
    .{ "create.cylinder", Impl{ .run = opCylinder } },
    .{ "create.plane", Impl{ .run = opPlane } },
    .{ "create.cone", Impl{ .run = @import("prims.zig").opCone } },
    .{ "create.torus", Impl{ .run = @import("prims.zig").opTorus } },
    .{ "create.grid", Impl{ .run = @import("prims.zig").opGrid } },
    .{ "create.ground", Impl{ .run = opGround } },
    .{ "create.light", Impl{ .run = opLight } },
    .{ "create.camera", Impl{ .run = opCamera } },
    .{ "light.set", Impl{ .run = @import("lcam.zig").opLight } },
    .{ "camera.set", Impl{ .run = @import("lcam.zig").opCamera } },

    .{ "transform.grab", Impl{ .run = opGrab, .poll = pollTransform, .ctx = .view3d } },
    .{ "transform.rotate", Impl{ .run = opRotate, .poll = pollTransform, .ctx = .view3d } },
    .{ "transform.scale", Impl{ .run = opScale, .poll = pollTransform, .ctx = .view3d } },
    .{ "tool.select", Impl{ .run = toolSel, .check = isToolSel } },
    .{ "tool.move", Impl{ .run = toolMove, .check = isToolMove } },
    .{ "tool.rotate", Impl{ .run = toolRot, .check = isToolRot } },
    .{ "tool.scale", Impl{ .run = toolScl, .check = isToolScl } },

    .{ "view.shading_wireframe", Impl{ .run = shWire, .poll = pollViewport, .check = isShWire } },
    .{ "view.shading_solid", Impl{ .run = shSolid, .poll = pollViewport, .check = isShSolid } },
    .{ "view.shading_material", Impl{ .run = shMat, .poll = pollViewport, .check = isShMat } },
    .{ "object.modifier_add", Impl{ .run = modops.add, .poll = modops.poll } },
    .{ "object.modifier_add_mirror", Impl{ .run = modops.addN(modstack.MIRROR), .poll = modops.poll } },
    .{ "object.modifier_add_array", Impl{ .run = modops.addN(modstack.ARRAY), .poll = modops.poll } },
    .{ "object.modifier_add_solidify", Impl{ .run = modops.addN(modstack.SOLIDIFY), .poll = modops.poll } },
    .{ "object.modifier_add_subsurf", Impl{ .run = modops.addN(modstack.SUBSURF), .poll = modops.poll } },
    .{ "object.modifier_add_bevel", Impl{ .run = modops.addN(modstack.BEVEL), .poll = modops.poll } },
    .{ "object.modifier_add_decimate", Impl{ .run = modops.addN(modstack.DECIMATE), .poll = modops.poll } },
    .{ "object.modifier_add_remesh", Impl{ .run = modops.addN(modstack.REMESH), .poll = modops.poll } },
    .{ "object.modifier_add_boolean", Impl{ .run = modops.addN(modstack.BOOLEAN), .poll = modops.poll } },
    .{ "object.modifier_add_armature", Impl{ .run = modops.addN(modstack.ARMATURE), .poll = modops.poll } },
    .{ "object.modifier_add_multires", Impl{ .run = modops.addN(modstack.MULTIRES), .poll = modops.poll } },
    .{ "object.modifier_add_logic", Impl{ .run = modops.addN(modstack.LOGIC), .poll = modops.poll } },
    .{ "object.modifier_add_geometry", Impl{ .run = modops.addN(modstack.GEONODES), .poll = modops.poll } },
    .{ "multires.propagate_down", Impl{ .run = @import("multires.zig").opDown } },
    .{ "create.armature", Impl{ .run = armedit.opAdd } },
    .{ "arm.bone", Impl{ .run = armedit.opBone } },
    .{ "arm.pose", Impl{ .run = armedit.opPose } },
    .{ "arm.select_bone", Impl{ .run = armedit.opSelect } },
    .{ "arm.parent", Impl{ .run = armedit.opParent } },
    .{ "arm.auto_weights", Impl{ .run = armedit.opAutoWeights } },
    .{ "arm.clear_pose", Impl{ .run = armedit.opClear } },
    .{ "arm.extrude", Impl{ .run = armedit.opExtrude, .poll = armedit.pollMode, .mode = .arm } },
    .{ "arm.delete_bones", Impl{ .run = armedit.opDelete, .poll = armedit.pollMode, .mode = .arm } },
    .{ "arm.select_all", Impl{ .run = armedit.opSelectAll, .poll = armedit.pollMode, .mode = .arm } },
    .{ "arm.insert_key", Impl{ .run = armedit.opKey, .poll = armedit.pollMode, .mode = .arm } },
    .{ "arm.clear_pose_key", Impl{ .run = armedit.opClear, .poll = armedit.pollMode, .mode = .arm } },
    .{ "constraint.add", Impl{ .run = @import("rig.zig").opAdd } },
    .{ "constraint.remove", Impl{ .run = @import("rig.zig").opRemove } },
    .{ "constraint.set", Impl{ .run = @import("rig.zig").opSet } },
    .{ "constraint.list", Impl{ .run = @import("rig.zig").opList } },
    .{ "object.modifier_remove", Impl{ .run = modops.remove, .poll = modops.pollHas } },
    .{ "object.modifier_apply", Impl{ .run = modops.apply, .poll = modops.pollHas, .mode = .object } },
    .{ "object.modifier_set", Impl{ .run = modops.set, .poll = modops.pollHas } },
    .{ "object.modifier_move_up", Impl{ .run = modops.up, .poll = modops.pollHas } },
    .{ "object.modifier_move_down", Impl{ .run = modops.down, .poll = modops.pollHas } },
    .{ "object.modifier_toggle", Impl{ .run = modops.toggle, .poll = modops.pollHas } },
    .{ "probe.add", Impl{ .run = bakeops.add } },
    .{ "probe.bake", Impl{ .run = bakeops.bake, .poll = bakeops.probe.pollAny } },
    .{ "probe.remove", Impl{ .run = bakeops.remove, .poll = bakeops.probe.pollAny } },
    .{ "probe.clear", Impl{ .run = bakeops.probe.clear, .poll = bakeops.probe.pollAny } },
    .{ "lightmap.bake", Impl{ .run = bakeops.lmBake } },
    .{ "lightmap.save", Impl{ .run = bakeops.lmSave, .poll = bakeops.lightmap.pollBaked } },
    .{ "lightmap.clear", Impl{ .run = bakeops.lightmap.reset, .poll = bakeops.lightmap.pollBaked } },
    .{ "vgeo.build", Impl{ .run = vgops.build, .poll = vgops.g.pollMesh } },
    .{ "vgeo.clear", Impl{ .run = vgops.g.opClear, .poll = vgops.g.pollDag } },
    .{ "vgeo.proxy", Impl{ .run = vgops.g.opProxy, .poll = vgops.g.pollDag } },
    .{ "vgeo.extract", Impl{ .run = vgops.extract, .poll = vgops.g.pollDag } },
    .{ "vgeo.budget", Impl{ .run = vgops.budget } },
    .{ "vgeo.error", Impl{ .run = vgops.err } },
    .{ "vgeo.view", Impl{ .run = vgops.view } },
    .{ "world.partition", Impl{ .run = wpops.part } },
    .{ "world.radius", Impl{ .run = wpops.radius } },
    .{ "world.budget", Impl{ .run = wpops.budget } },
    .{ "world.update", Impl{ .run = wpops.w.opUpdate } },
    .{ "world.minimap", Impl{ .run = wpops.w.opMinimap } },
    .{ "world.hdri", Impl{ .run = worldops.hdri } },
    .{ "world.strength", Impl{ .run = worldops.strength } },
    .{ "world.rotation", Impl{ .run = worldops.rotation } },
    .{ "image.load", Impl{ .run = worldops.imageLoad } },
    .{ "image.new", Impl{ .run = worldops.imageNew } },
    .{ "image.save", Impl{ .run = worldops.imageSave } },
    .{ "object.boolean", Impl{ .run = boolops.named, .poll = boolops.poll, .mode = .object } },
    .{ "object.boolean_union", Impl{ .run = boolops.un, .poll = boolops.poll, .mode = .object } },
    .{ "object.boolean_difference", Impl{ .run = boolops.diff, .poll = boolops.poll, .mode = .object } },
    .{ "object.boolean_intersect", Impl{ .run = boolops.isect, .poll = boolops.poll, .mode = .object } },
    .{ "view.shading_rendered", Impl{ .run = shRendered, .poll = pollViewport, .check = isShRendered } },
    .{ "view.toggle_rendered", Impl{ .run = opRendered, .poll = pollViewport, .check = isShRendered, .ctx = .view3d } },
    .{ "view.rendered_samples", Impl{ .run = @import("live.zig").opSamples } },
    .{ "view.rendered_denoise", Impl{ .run = @import("live.zig").opDenoise, .check = @import("live.zig").isDenoise } },
    .{ "view.rendered_motion", Impl{ .run = @import("live.zig").opMotion } },
    .{ "view.rendered_playback", Impl{ .run = @import("live.zig").opPlayback } },
    .{ "view.toggle_material_preview", Impl{ .run = opMatPrev, .poll = pollViewport, .check = isShMat, .ctx = .view3d } },
    .{ "view.toggle_ortho", Impl{ .run = opOrtho, .poll = pollViewport, .check = isOrtho, .ctx = .view3d } },
    .{ "view.camera", Impl{ .run = opCamView, .poll = pollCamera, .check = isCamView, .ctx = .view3d } },
    .{ "view.camera_selected", Impl{ .run = opCamSelected, .poll = pollCamSelected, .ctx = .view3d } },
    .{ "view.camera_to_view", Impl{ .run = opCamToView, .poll = pollViewport, .ctx = .view3d } },
    .{ "view.overlay_text", Impl{ .run = ovText, .poll = pollViewport, .check = isOvText } },
    .{ "view.overlay_stats", Impl{ .run = ovStats, .poll = pollViewport, .check = isOvStats } },
    .{ "view.overlay_gizmo", Impl{ .run = ovGizmo, .poll = pollViewport, .check = isOvGizmo } },
    .{ "mode.object", Impl{ .run = modeObject, .check = isObjectMode } },
    .{ "mode.edit", Impl{ .run = modeEdit, .poll = pollEditable, .check = isEdit } },
    .{ "mode.toggle_edit", Impl{ .run = modeToggle, .poll = pollEditable, .check = isEdit, .ctx = .view3d } },
    .{ "mesh.select_mode_vertex", Impl{ .run = smVert, .poll = pollEdit, .check = isSmVert, .mode = .edit } },
    .{ "mesh.select_mode_edge", Impl{ .run = smEdge, .poll = pollEdit, .check = isSmEdge, .mode = .edit } },
    .{ "mesh.select_mode_face", Impl{ .run = smFace, .poll = pollEdit, .check = isSmFace, .mode = .edit } },
    .{ "mesh.select_all", Impl{ .run = meshSelAll, .poll = pollEdit, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.select_invert", Impl{ .run = meshInvert, .poll = pollEdit, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.select_linked", Impl{ .run = meshLinked, .poll = pollEditSel, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.select_box", Impl{ .run = meshBox, .poll = pollEdit, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.delete", Impl{ .run = meshDelete, .poll = pollEditSel, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.delete_key", Impl{ .run = meshDelete, .poll = pollEditSel, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.extrude", Impl{ .run = opExtrude, .poll = pollEditSel, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.extrude_individual", Impl{ .run = opExtrudeInd, .poll = needFaces, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.inset", Impl{ .run = opInset, .poll = needFaces, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.merge_center", Impl{ .run = opMerge, .poll = pollEditSel, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.fill", Impl{ .run = opFill, .poll = pollEditSel, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.duplicate", Impl{ .run = opMeshDup, .poll = needFaces, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.flip_normals", Impl{ .run = opFlip, .poll = needFaces } },
    .{ "mesh.recalc_normals", Impl{ .run = opRecalc, .poll = pollEdit, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.subdivide", Impl{ .run = opSubdiv, .poll = needFaces } },
    .{ "mesh.dissolve", Impl{ .run = opDissolve, .poll = pollEditSel, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.merge_collapse", Impl{ .run = opCollapse, .poll = pollEditSel } },
    .{ "mesh.merge_distance", Impl{ .run = opMergeDist, .poll = pollEditSel } },
    .{ "mesh.bridge", Impl{ .run = opBridge, .poll = pollEditSel } },
    .{ "mesh.separate_loose", Impl{ .run = @import("shatterop.zig").opSepLoose, .poll = pollSepLoose } }, // (shatterop.s do_sep_loose)
    .{ "mesh.repair", Impl{ .run = opRepair, .poll = pollRepair } },
    .{ "mesh.knife", Impl{ .run = opKnife, .poll = pollEdit } },
    .{ "mesh.bevel", Impl{ .run = opBevel, .poll = pollEditSel } },
    .{ "mesh.bisect", Impl{ .run = opBisect, .poll = pollEdit } },
    .{ "mesh.spin", Impl{ .run = opSpin, .poll = pollEditSel } },
    .{ "material.new", Impl{ .run = matops.opNew } },
    .{ "render.start", Impl{ .run = render.opStart } },
    .{ "render.stop", Impl{ .run = render.opStop, .poll = render.pollRendering } },
    .{ "render.save", Impl{ .run = render.opSave, .poll = render.pollRender } },
    .{ "render.pass", Impl{ .run = render.opPass, .poll = render.pollRender } },
    .{ "render.settings", Impl{ .run = render.opSettings } },
    .{ "render.denoise", Impl{ .run = render.opDenoise, .check = render.isDenoise } },
    .{ "render.device", Impl{ .run = render.opDevice } },
    .{ "render.view_fit", Impl{ .run = render.opFit } },
    .{ "render.view_settings", Impl{ .run = app.showRenderSettings } },
    .{ "render.animation", Impl{ .run = @import("video.zig").opAnimation } },
    .{ "anim.range", Impl{ .run = @import("frange.zig").opRange } },
    .{ "anim.insert_key", Impl{ .run = aops.insertKey, .mode = .object } },
    .{ "anim.delete_key", Impl{ .run = aops.deleteKey, .mode = .object } },
    .{ "anim.key", Impl{ .run = aops.keyPath } },
    .{ "anim.unkey", Impl{ .run = aops.unkeyPath } },
    .{ "anim.frame", Impl{ .run = aops.goFrame } },
    .{ "anim.play", Impl{ .run = aops.play, .check = aops.isPlaying } },
    .{ "anim.next_frame", Impl{ .run = aops.nextFrame } },
    .{ "anim.prev_frame", Impl{ .run = aops.prevFrame } },
    .{ "anim.first_frame", Impl{ .run = aops.firstFrame } },
    .{ "anim.last_frame", Impl{ .run = aops.lastFrame } },
    .{ "anim.interpolation", Impl{ .run = aops.interpolation } },
    .{ "anim.select_keys", Impl{ .run = aops.selectKeys } },
    .{ "anim.move_keys", Impl{ .run = aops.moveKeys } },
    .{ "anim.scale_keys", Impl{ .run = aops.scaleKeys } },
    .{ "anim.delete_keys", Impl{ .run = aops.deleteKeys } },
    .{ "anim.duplicate_keys", Impl{ .run = aops.duplicateKeys } },
    .{ "anim.handle_type", Impl{ .run = aops.handleType } },
    .{ "anim.handle", Impl{ .run = aops.handle } },
    .{ "anim.action", Impl{ .run = aops.action } },
    .{ "anim.layer", Impl{ .run = aops.layer } },
    .{ "anim.layer_set", Impl{ .run = aops.layerSet } },
    .{ "anim.layer_remove", Impl{ .run = aops.layerRemove } },
    .{ "anim.driver", Impl{ .run = aops.driver } },
    .{ "anim.driver_set", Impl{ .run = aops.driverSet } },
    .{ "anim.driver_remove", Impl{ .run = aops.driverRemove } },
    .{ "anim.motion_paths", Impl{ .run = @import("motion.zig").opPaths } },
    .{ "anim.onion", Impl{ .run = @import("motion.zig").opOnion } },
    .{ "anim.auto_key", Impl{ .run = aops.autoKeyToggle, .check = aops.autoKeyOn } },
    .{ "anim.delete_keys_key", Impl{ .run = aops.delKeysKey, .ctx = .animed } },
    .{ "anim.select_all_keys", Impl{ .run = aops.selAllKey, .ctx = .animed } },
    .{ "anim.duplicate_keys_key", Impl{ .run = aops.dupKeysKey, .ctx = .animed } },
    .{ "anim.keys_constant", Impl{ .run = aops.keysConstant } },
    .{ "anim.keys_linear", Impl{ .run = aops.keysLinear } },
    .{ "anim.keys_bezier", Impl{ .run = aops.keysBezier } },
    .{ "anim.keys_handles_auto", Impl{ .run = aops.keysAuto } },
    .{ "anim.keys_handles_free", Impl{ .run = aops.keysFree } },
    .{ "anim.start_here", Impl{ .run = aops.startHere } },
    .{ "anim.end_here", Impl{ .run = aops.endHere } },
    .{ "shape.add", Impl{ .run = @import("shape.zig").opAdd } },
    .{ "shape.edit", Impl{ .run = @import("shape.zig").opEdit } },
    .{ "shape.set", Impl{ .run = @import("shape.zig").opSet } },
    .{ "shape.remove", Impl{ .run = @import("shape.zig").opRemove } },
    .{ "shape.clear", Impl{ .run = @import("shape.zig").opClear } },
    .{ "object.add_reference", Impl{ .run = @import("refimg.zig").opAdd } },
    .{ "object.add_references", Impl{ .run = @import("refset.zig").opAdd } },
    .{ "object.reference_pin", Impl{ .run = @import("refset.zig").opPin } },
    .{ "object.reference_kind", Impl{ .run = @import("refset.zig").opKind } },
    .{ "object.references_ai", Impl{ .run = @import("refset.zig").opAi } },
    .{ "material.assign", Impl{ .run = matops.opAssign, .poll = matops.pollActiveMesh } },
    .{ "material.set", Impl{ .run = matops.opSet } },
    .{ "material.remove", Impl{ .run = matops.opRemove } },
    .{ "material.preset", Impl{ .run = matops.opPreset } },
    .{ "material.node", Impl{ .run = graphcmds.opNode } },
    .{ "material.link", Impl{ .run = graphcmds.opLink } },
    .{ "material.node_set", Impl{ .run = graphcmds.opNodeSet } },
    .{ "material.socket", Impl{ .run = graphcmds.opSocket } },
    .{ "material.node_delete", Impl{ .run = graphcmds.opNodeDelete } },
    .{ "material.node_move", Impl{ .run = graphcmds.opNodeMove } },
    .{ "material.nodes_clear", Impl{ .run = graphcmds.opNodesClear } },
    .{ "material.node_name", Impl{ .run = graphcmds.opNodeName } },
    .{ "material.instance", Impl{ .run = graphcmds.opInstance } },
    .{ "material.new_instance", Impl{ .run = graphcmds.opNewInstance, .poll = graphcmds.pollNewInstance } },
    .{ "material.param", Impl{ .run = graphcmds.opParam } },
    .{ "material.param_reset", Impl{ .run = graphcmds.opParamReset } },
    .{ "material.function_new", Impl{ .run = graphcmds.opFunctionNew } },
    .{ "material.make_function", Impl{ .run = graphcmds.opMakeFunction } },
    .{ "material.texture", Impl{ .run = graphcmds.opTexture } },
    .{ "material.import_textures", Impl{ .run = graphcmds.opImportTextures } },
    .{ "material.bake", Impl{ .run = graphcmds.opMatBake } },
    .{ "material.bake_active", Impl{ .run = graphcmds.opBakeActive, .poll = graphcmds.pollBake } },
    .{ "object.bake", Impl{ .run = graphcmds.opBake } },
    .{ "material.apply_preset", Impl{ .run = matops.opApplyPreset, .poll = matops.pollSelected } },
    .{ "mesh.loopcut", Impl{ .run = opLoopCut, .poll = pollEdit, .ctx = .view3d, .mode = .edit } },
    .{ "mesh.delete_vertices", Impl{ .run = meshDelV, .poll = pollEditSel } },
    .{ "mesh.delete_edges", Impl{ .run = meshDelE, .poll = pollEditSel } },
    .{ "mesh.delete_faces", Impl{ .run = meshDelF, .poll = pollEditSel } },
    .{ "view.orientation_global", Impl{ .run = orGlob, .check = isOrGlob } },
    .{ "view.orientation_local", Impl{ .run = orLoc, .check = isOrLoc } },
    .{ "view.orientation_view", Impl{ .run = orView, .check = isOrView } },
    .{ "view.orientation_normal", Impl{ .run = orNrm, .check = isOrNrm } },
    .{ "view.toggle_wireframe", Impl{ .run = opWire, .poll = pollViewport, .check = isWire, .ctx = .view3d } },
    .{ "view.toggle_grid", Impl{ .run = opGrid, .check = isGrid } },
    .{ "view.toggle_snap", Impl{ .run = opSnap, .check = isSnap } },
    .{ "view.reset_camera", Impl{ .run = opResetCam, .poll = pollViewport, .ctx = .view3d, .mode = .object } },
    .{ "view.reset_camera_home", Impl{ .run = opResetCam, .poll = pollViewport, .ctx = .view3d } },
    .{ "view.frame_selected", Impl{ .run = opFrameSel, .poll = pollViewport, .ctx = .view3d } },
    .{ "view.align_front", Impl{ .run = opFront, .poll = pollViewport, .ctx = .view3d } },
    .{ "view.align_back", Impl{ .run = opBack, .poll = pollViewport, .ctx = .view3d } },
    .{ "view.align_right", Impl{ .run = opRight, .poll = pollViewport, .ctx = .view3d } },
    .{ "view.align_left", Impl{ .run = opLeft, .poll = pollViewport, .ctx = .view3d } },
    .{ "view.align_top", Impl{ .run = opTop, .poll = pollViewport, .ctx = .view3d } },
    .{ "view.align_bottom", Impl{ .run = opBottom, .poll = pollViewport, .ctx = .view3d } },
    .{ "view.cursor_reset", Impl{ .run = opCursorReset } },
    .{ "view.cursor_to_selected", Impl{ .run = opCursorSel, .poll = pollSel } },
    .{ "view.pivot_median", Impl{ .run = pivMed, .check = isPivMed } },
    .{ "view.pivot_cursor", Impl{ .run = pivCur, .check = isPivCur } },
    .{ "view.pivot_individual", Impl{ .run = pivInd, .check = isPivInd } },
    .{ "view.pivot_active", Impl{ .run = pivAct, .check = isPivAct } },

    .{ "view.theme_dark", Impl{ .run = themeFn(0), .check = themeIs(0) } },
    .{ "view.theme_light", Impl{ .run = themeFn(1), .check = themeIs(1) } },
    .{ "view.theme_contrast", Impl{ .run = themeFn(2), .check = themeIs(2) } },
    .{ "view.theme_honey", Impl{ .run = themeFn(3), .check = themeIs(3) } },
    .{ "view.theme_graphite", Impl{ .run = themeFn(4), .check = themeIs(4) } },
    .{ "view.theme_nord", Impl{ .run = themeFn(5), .check = themeIs(5) } },
    .{ "view.theme_solarized", Impl{ .run = themeFn(6), .check = themeIs(6) } },
    .{ "view.theme_solarized_light", Impl{ .run = themeFn(7), .check = themeIs(7) } },
    .{ "view.theme_dracula", Impl{ .run = themeFn(8), .check = themeIs(8) } },
    .{ "view.accent_theme", Impl{ .run = opAccentNone, .poll = pollAccent } },
    .{ "view.toggle_tools", Impl{ .run = opToolsPane, .check = hasTools, .ctx = .view3d } },
    .{ "view.toggle_console", Impl{ .run = opConsolePane, .check = hasConsole } },
    .{ "view.toggle_outliner", Impl{ .run = opOutlinerPane, .check = hasOutliner, .ctx = .view3d } },

    .{ "area.split_side", Impl{ .run = opSplitSide, .poll = pollSplit } },
    .{ "area.split_stack", Impl{ .run = opSplitStack, .poll = pollSplit } },
    .{ "area.maximize", Impl{ .run = opMaximize, .check = isMaximized } },
    .{ "area.close", Impl{ .run = opClose, .poll = pollClose } },
    .{ "area.float", Impl{ .run = opFloat, .poll = pollFloat } },
    .{ "area.dock", Impl{ .run = opDock, .poll = pollDock } },
    .{ "area.type_viewport", Impl{ .run = edFn(.viewport), .check = edIs(.viewport) } },
    .{ "area.type_tools", Impl{ .run = edFn(.tools), .check = edIs(.tools) } },
    .{ "area.type_outliner", Impl{ .run = edFn(.outliner), .check = edIs(.outliner) } },
    .{ "area.type_properties", Impl{ .run = edFn(.properties), .check = edIs(.properties) } },
    .{ "area.type_console", Impl{ .run = edFn(.console), .check = edIs(.console) } },
    .{ "area.type_timeline", Impl{ .run = edFn(.timeline), .check = edIs(.timeline) } },
    .{ "area.type_dope_sheet", Impl{ .run = edFn(.dopesheet), .check = edIs(.dopesheet) } },
    .{ "area.type_graph_editor", Impl{ .run = edFn(.graph), .check = edIs(.graph) } },
    .{ "area.type_uv_editor", Impl{ .run = edFn(.uved), .check = edIs(.uved) } },
    .{ "area.type_node_editor", Impl{ .run = edFn(.nodes), .check = edIs(.nodes) } },
    .{ "area.type_asset_browser", Impl{ .run = edFn(.assets), .check = edIs(.assets) } },
    .{ "uv.unwrap", Impl{ .run = uvmod.opUnwrap, .poll = uvmod.pollEdit, .mode = .edit } },
    .{ "uv.smart_project", Impl{ .run = uvmod.opSmart, .poll = uvmod.pollEdit, .mode = .edit } },
    .{ "uv.pack", Impl{ .run = uvmod.opPack, .poll = uvmod.pollEdit, .mode = .edit } },
    .{ "uv.seam_mark", Impl{ .run = uvmod.opMark, .poll = uvmod.pollEdit, .mode = .edit } },
    .{ "uv.seam_clear", Impl{ .run = uvmod.opClear, .poll = uvmod.pollEdit, .mode = .edit } },
    .{ "uv.seams_from_sharp", Impl{ .run = uvmod.opSharp, .poll = uvmod.pollEdit, .mode = .edit } },
    .{ "uv.select_all", Impl{ .run = uved.opAll, .ctx = .uved } },
    .{ "uv.grab", Impl{ .run = uved.opGrab, .ctx = .uved } },
    .{ "uv.scale", Impl{ .run = uved.opScale, .ctx = .uved } },
    .{ "uv.rotate", Impl{ .run = uved.opRotate, .ctx = .uved } },
    .{ "uv.heat_map", Impl{ .run = uved.opHeat, .ctx = .uved } },
    .{ "uv.view_fit", Impl{ .run = uved.opFit, .ctx = .uved } },

    .{ "workspace.next", Impl{ .run = wsNext, .poll = pollTwo } },
    .{ "workspace.prev", Impl{ .run = wsPrev, .poll = pollTwo } },
    .{ "workspace.new", Impl{ .run = wsNew } },
    .{ "workspace.set", Impl{ .run = wsSet } },
    .{ "workspace.rename", Impl{ .run = wsRename } },
    .{ "workspace.delete", Impl{ .run = wsDelete, .poll = pollTwo } },
};

const impl_map = std.StaticStringMap(Impl).initComptime(impl_list ++ @import("uiops.zig").list ++ @import("sculptui.zig").list ++ @import("paintui.zig").list ++ @import("cadui.zig").list ++ @import("feature.zig").list ++ @import("sketchui.zig").list ++ @import("fab2d.zig").list ++ @import("stepops.zig").list ++ @import("usd.zig").list ++ @import("gltf.zig").list ++ @import("mech.zig").list ++ @import("fields.zig").list ++ @import("rbody.zig").list ++ @import("cloth.zig").list ++ @import("simcache.zig").list ++ @import("particles.zig").list ++ @import("partsurf.zig").list ++ @import("shatterop.zig").list ++ @import("ntree.zig").list ++ @import("logic.zig").list ++ @import("play.zig").list ++ @import("landscape.zig").list ++ @import("lsculpt.zig").list ++ @import("landio.zig").list ++ @import("curve.zig").list ++ @import("text3d.zig").list ++ @import("geonodes.zig").list ++ @import("library.zig").list_ops ++ @import("asset.zig").list_ops ++ @import("libui.zig").list_ops ++ @import("extlib.zig").list_ops ++ @import("nodeed.zig").list ++ @import("agent.zig").list ++ @import("ai.zig").list ++ @import("aiask.zig").list ++ @import("bscript.zig").list ++ @import("hi3d.zig").list ++ @import("vc.zig").list ++ @import("versions.zig").list ++ @import("link.zig").list ++ @import("cosync.zig").list);

/// The implementation of each catalog entry (null: not ported yet).
pub const impl_of: [N]?Impl = blk: {
    @setEvalBranchQuota(400000);
    var out: [N]?Impl = undefined;
    for (cat.entries, 0..) |e, i| out[i] = impl_map.get(e.id);
    break :blk out;
};

comptime {
    // every implementation must name a real operator of the original
    @setEvalBranchQuota(800000);
    for (impl_list) |pair| {
        var found = false;
        for (cat.entries) |e| {
            if (std.mem.eql(u8, e.id, pair[0])) found = true;
        }
        if (!found) @compileError("ops.zig: no operator called " ++ pair[0] ++ " in the catalog");
    }
}

const sym_map = blk: {
    @setEvalBranchQuota(400000);
    var kv: [N]struct { []const u8, u16 } = undefined;
    for (cat.entries, 0..) |e, i| kv[i] = .{ e.sym, @intCast(i) };
    break :blk std.StaticStringMap(u16).initComptime(kv);
};

const id_map = blk: {
    @setEvalBranchQuota(400000);
    var kv: [N]struct { []const u8, u16 } = undefined;
    for (cat.entries, 0..) |e, i| kv[i] = .{ e.id, @intCast(i) };
    break :blk std.StaticStringMap(u16).initComptime(kv);
};

pub fn bySym(sym: []const u8) ?usize {
    return if (sym_map.get(sym)) |v| v else null;
}

pub fn byId(id: []const u8) ?usize {
    return if (id_map.get(id)) |v| v else null;
}

pub fn implemented(i: usize) bool {
    return impl_of[i] != null;
}

/// Why operator i cannot run now, or null when it can.
pub fn reason(i: usize) ?[]const u8 {
    const im = impl_of[i] orelse return not_ported;
    if (im.poll) |p| return p();
    return null;
}

pub fn checked(i: usize) ?bool {
    const im = impl_of[i] orelse return null;
    const c = im.check orelse return null;
    return c();
}

/// Run operator i if it can run; otherwise say why in the status bar.
pub fn run(i: usize) void {
    if (reason(i)) |why| {
        app.toast(.warn, "{s}: {s}", .{ cat.entries[i].label, why });
        return;
    }
    // from the UI, with no values: its form first
    if (!scripted and arg.len == 0 and @import("forms.zig").offer(i)) return;
    undo.label(cat.entries[i].label);
    impl_of[i].?.run();
    @import("anim.zig").rigEval(); // (drivers and constraints follow)
    app.dirty = true;
    @import("bscript.zig").macroOp(i); // (recording a macro: op("id", "arg"))
}

/// Run the operator with this id (at run time); unknown ids say so.
pub fn runId2(id: []const u8) void {
    if (byId(id)) |i| run(i) else app.toast(.warn, "{s}: {s}", .{ id, not_ported });
}

pub fn runId(comptime id: []const u8) void {
    const i = comptime blk: {
        @setEvalBranchQuota(400000);
        for (cat.entries, 0..) |e, k| {
            if (std.mem.eql(u8, e.id, id)) break :blk k;
        }
        @compileError("no operator " ++ id);
    };
    run(i);
}

// --- keys -----------------------------------------------------------------

const MODMASK: u32 = wl.MOD_SHIFT | wl.MOD_CTRL | wl.MOD_ALT;

/// The implemented operator bound to (code, mods), if any.
pub fn forKey(code: u32, mods: u32, over_view3d: bool) ?usize {
    const md = mods & MODMASK;
    const editing = em.active;
    const keys = @import("keys.zig");
    // armature modes: their keys first (OPF_ARM)
    if (armedit.active()) {
        for (keys.code_of, keys.mods_of, 0..) |kc, km, i| {
            if (kc != code or km != md) continue;
            const im = impl_of[i] orelse continue;
            if (im.mode == .arm) return i;
        }
    }
    // curve edit mode: its keys first (OPF_CURVE)
    if (@import("curveui.zig").on()) {
        for (keys.code_of, keys.mods_of, 0..) |kc, km, i| {
            if (kc != code or km != md) continue;
            const im = impl_of[i] orelse continue;
            if (im.mode == .curve) return i;
        }
    }
    // sketch mode: its keys first (OPF_SKETCH)
    if (@import("sketchui.zig").on()) {
        for (keys.code_of, keys.mods_of, 0..) |kc, km, i| {
            if (kc != code or km != md) continue;
            const im = impl_of[i] orelse continue;
            if (im.mode == .sketch) return i;
        }
    }
    // sculpt mode: its keys first (OPF_SCULPT)
    if (sculpt.on) {
        for (keys.code_of, keys.mods_of, 0..) |kc, km, i| {
            if (kc != code or km != md) continue;
            const im = impl_of[i] orelse continue;
            if (im.mode == .sculpt) return i;
        }
    }
    // over a dope sheet / graph editor its keys win (OPF_ANIMED)
    const over_keys = if (app.hoverEditor()) |e| e == .dopesheet or e == .graph else false;
    // (and over a UV editor its own, OPF_UV; over a node editor, OPF_NODE)
    const over_uv = app.hoverEditor() == .uved;
    const over_node = app.hoverEditor() == .nodes;
    if (over_keys or over_uv or over_node) {
        for (keys.code_of, keys.mods_of, 0..) |kc, km, i| {
            if (kc != code or km != md) continue;
            const im = impl_of[i] orelse continue;
            if (im.ctx == (if (over_uv) Ctx.uved else if (over_node) Ctx.node else Ctx.animed)) return i;
        }
    }
    // the paint modes: their keys (OPF_PAINT; over those editors, theirs alone)
    if (paint.on and !over_keys and !over_uv) {
        for (keys.code_of, keys.mods_of, 0..) |kc, km, i| {
            if (kc != code or km != md) continue;
            const im = impl_of[i] orelse continue;
            if (im.ctx == .paint) return i;
        }
    }
    for (keys.code_of, keys.mods_of, 0..) |kc, km, i| {
        if (kc != code or km != md) continue;
        const im = impl_of[i] orelse continue;
        if (im.ctx == .animed or im.ctx == .uved or im.ctx == .paint or im.ctx == .node) continue;
        if (im.ctx == .view3d and !over_view3d and !over_uv) continue; // (Tab, X: the original's keys are global)
        if (im.mode == .arm or im.mode == .sculpt or im.mode == .sketch or im.mode == .curve) continue;
        if (im.mode == .object and editing) continue;
        if (im.mode == .edit and !editing) continue;
        return i;
    }
    return null;
}

pub fn keyName(code: u32) []const u8 {
    return switch (code) {
        1 => "Esc",
        12 => "-",
        13 => "=",
        14 => "Backspace",
        15 => "Tab",
        26 => "[",
        27 => "]",
        28 => "Enter",
        51 => ",",
        52 => ".",
        57 => "Space",
        59 => "F1",
        60 => "F2",
        61 => "F3",
        62 => "F4",
        63 => "F5",
        64 => "F6",
        65 => "F7",
        66 => "F8",
        67 => "F9",
        68 => "F10",
        87 => "F11",
        88 => "F12",
        71 => "Numpad 7",
        72 => "Numpad 8",
        73 => "Numpad 9",
        75 => "Numpad 4",
        76 => "Numpad 5",
        77 => "Numpad 6",
        79 => "Numpad 1",
        80 => "Numpad 2",
        81 => "Numpad 3",
        82 => "Numpad 0",
        83 => "Numpad .",
        102 => "Home",
        103 => "Up",
        104 => "PageUp",
        105 => "Left",
        106 => "Right",
        107 => "End",
        108 => "Down",
        109 => "PageDown",
        111 => "Delete",
        else => blk: {
            const ch = ui.keyChar(code, true);
            if (ch == 0) break :blk "?";
            break :blk letters[ch - ' ' ..][0..1];
        },
    };
}

const letters = blk: {
    var s: [96]u8 = undefined;
    for (&s, 0..) |*c, i| c.* = @intCast(' ' + i);
    break :blk s;
};

/// "Ctrl+Shift+Z" for operator i, or "" without a key.
pub fn keyLabel(i: usize, buf: []u8) []const u8 {
    const keys = @import("keys.zig");
    if (keys.code_of[i] == 0) return "";
    return comboLabel(keys.code_of[i], keys.mods_of[i], buf);
}

pub fn comboLabel(code: u32, mods: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{
        if (mods & wl.MOD_CTRL != 0) "Ctrl+" else "",
        if (mods & wl.MOD_ALT != 0) "Alt+" else "",
        if (mods & wl.MOD_SHIFT != 0) "Shift+" else "",
        keyName(code),
    }) catch "";
}

/// How many operators the port implements.
pub fn implementedCount() usize {
    var n: usize = 0;
    for (impl_of) |im| {
        if (im != null) n += 1;
    }
    return n;
}
