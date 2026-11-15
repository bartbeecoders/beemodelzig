// The document: which file the scene is, whether it changed since it was
// saved, the file commands (New, Open, Save, Save As, Open Recent, Exit) and
// "Save changes?" before New, Open and Exit when the scene has changes.
const std = @import("std");
const app = @import("app.zig");
const scene = @import("scene.zig");
const undo = @import("undo.zig");
const bee = @import("bee.zig");
const fb = @import("filebrowser.zig");
const prefs = @import("prefs.zig");
const vp = @import("viewport.zig");
const autosave = @import("autosave.zig");

var path_buf: [512]u8 = undefined;
var path_len: usize = 0;
/// Before the last Open: the file the scene was, and the undo step of the
/// Open (undoing past it gives the old scene back, and its name).
var prev_buf: [512]u8 = undefined;
var prev_len: usize = 0;
var prev_saved_at: usize = 0;
var open_step: ?usize = null;
/// The file has parts the port does not keep: saving over it loses them.
pub var lossy: bool = false;
var prev_lossy = false;
/// The undo step the file was saved (or opened) at.
var saved_at: usize = 0;
var saved_count_ok = true;

/// Undo went back past the last Open: the document is the one before it.
fn beforeOpen() bool {
    return if (open_step) |s| undo.current() < s else false;
}

pub fn path() ?[]const u8 {
    if (beforeOpen()) return if (prev_len > 0) prev_buf[0..prev_len] else null;
    return if (path_len > 0) path_buf[0..path_len] else null;
}

fn isLossy() bool {
    return if (beforeOpen()) prev_lossy else lossy;
}

/// The file's name for the title bar ("untitled scene" before a save).
pub fn name() []const u8 {
    const p = path() orelse return if (recovered_len > 0 and !beforeOpen()) recovered_buf[0..recovered_len] else "untitled scene";
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |s| p[s + 1 ..] else p;
}

pub fn changed() bool {
    if (beforeOpen()) return undo.current() != prev_saved_at;
    return undo.current() != saved_at or !saved_count_ok or images_changed;
}

/// A texture stroke or a bake: images are in no scene step, the file still differs.
var images_changed = false;
pub fn noteChange() void {
    images_changed = true;
}

fn setPath(p: []const u8) void {
    path_len = @min(p.len, path_buf.len);
    @memcpy(path_buf[0..path_len], p[0..path_len]);
}

fn markSaved() void {
    saved_at = undo.current();
    saved_count_ok = true;
    images_changed = false;
    recovered_len = 0;
    autosave.retire();
}

/// Saving makes this the document (whatever was opened before).
fn becomeSaved(p: []const u8) void {
    if (beforeOpen()) open_step = null;
    setPath(p);
    undo.sync();
    markSaved();
}

pub fn viewForFile() ?*vp.View {
    const v = app.viewportArea();
    return if (v < 0) null else &app.N(v).view;
}

/// "~/x" -> "$HOME/x" (and trimmed), as the original's path_expand.
fn expand(p0: []const u8, buf: []u8) []const u8 {
    const p = std.mem.trim(u8, p0, " ");
    if (p.len > 0 and p[0] == '~' and (p.len == 1 or p[1] == '/')) return std.fmt.bufPrint(buf, "{s}{s}", .{ fb.homeDir(), p[1..] }) catch p;
    return p;
}

/// Headless runs (tests, fuzzing) write only under /tmp.
pub var headless = false;

/// The undo history started again without the scene being another one (world
/// partition streaming its cells): the document is as changed as it was.
pub fn historyRestarted(was_changed: bool) void {
    open_step = null;
    if (was_changed) {
        saved_count_ok = false;
    } else saved_at = undo.current();
}

/// ~ expanded (the buffer holds the result).
pub fn expandHome(buf: []u8, p0: []const u8) ?[]const u8 {
    if (buf.len < 600) return null;
    return expand(p0, buf[0..600]);
}

/// Headless runs (tests, fuzzing) write only under /tmp.
pub fn mayWrite(p: []const u8) bool {
    return !headless or std.mem.startsWith(u8, p, "/tmp/");
}

pub fn saveTo(p0: []const u8) void {
    var eb: [600]u8 = undefined;
    const p = expand(p0, &eb);
    if (headless and !std.mem.startsWith(u8, p, "/tmp/")) {
        app.toast(.warn, "Headless: not saving outside /tmp ({s})", .{p});
        return;
    }
    { // op_save: default_dir first (~/BeeModel made if missing; headless only under /tmp)
        var db: [600]u8 = undefined;
        const d = expand("~/BeeModel", &db);
        if (!headless or std.mem.startsWith(u8, d, "/tmp/")) _ = @import("spawn.zig").ensureDir(d);
    }
    bee.save(p, viewForFile()) catch |e| {
        app.toast(.warn, "Could not save {s}: {s}", .{ p, errText(e) });
        return;
    };
    becomeSaved(p);
    lossy = false; // (a file the port wrote has nothing else in it)
    prefs.pushRecentFile(p);
    app.toast(.ok, "Saved {s}", .{name()});
}

/// As a job, with its chip. "Save changes?" uses saveTo: what it was asked to do comes after.
fn saveLater(p: []const u8) void {
    @import("jobui.zig").later(saveJob, "Saving", p, 0, 0);
}
fn saveJob(p: []const u8, _: usize, _: usize) void {
    saveTo(p);
}

pub fn openFrom(p0: []const u8) void {
    @import("jobui.zig").later(openJob, "Opening", p0, 0, 0);
}
fn openJob(p: []const u8, _: usize, _: usize) void {
    openNow(p);
}
fn openNow(p0: []const u8) void {
    var eb: [600]u8 = undefined;
    const p = expand(p0, &eb);
    const rep = bee.load(p, viewForFile()) catch |e| {
        app.toast(.warn, "Could not open {s}: {s}", .{ p, switch (e) {
            error.CannotOpen => "it cannot be read",
            error.NotABeeFile => "it is not a .bee scene",
            error.Damaged => "it is damaged",
            else => @errorName(e),
        } });
        return;
    };
    // remember the document before (undo past the Open gives it back)
    if (path()) |old| {
        prev_len = @min(old.len, prev_buf.len);
        @memcpy(prev_buf[0..prev_len], old[0..prev_len]);
    } else prev_len = 0;
    prev_saved_at = saved_at;
    prev_lossy = isLossy();
    setPath(p);
    undo.restart();
    open_step = null;
    markSaved();
    lossy = rep.lossy;
    prefs.pushRecentFile(p);
    if (rep.parents_dropped > 0) {
        app.toast(.warn, "Opened {s}: {d} objects; {d} kept their place but not their parent (sheared or flattened parent)", .{ name(), rep.objects, rep.parents_dropped });
    } else if (rep.mesh_errors > 0) {
        app.toast(.warn, "Opened {s}: {d} objects; {d} meshes could not be read", .{ name(), rep.objects, rep.mesh_errors });
    } else if (rep.skipped > 0 or rep.truncated) {
        app.toast(.warn, "Opened {s}: {d} objects; {d} of kinds BeeModel doesn't read yet{s}", .{ name(), rep.objects, rep.skipped, if (rep.truncated) " (and more than 8192)" else "" });
    } else app.toast(.ok, "Opened {s}: {d} objects", .{ name(), rep.objects });
}

/// A scene asset of the content library (library.zig): it opens untitled
/// (cur_path cleared, as the original's lb_load). False: it would not load.
pub fn openUntitled(p: []const u8) bool {
    const rep = bee.load(p, viewForFile()) catch return false;
    if (path()) |old| {
        prev_len = @min(old.len, prev_buf.len);
        @memcpy(prev_buf[0..prev_len], old[0..prev_len]);
    } else prev_len = 0;
    prev_saved_at = saved_at;
    prev_lossy = isLossy();
    path_len = 0;
    undo.restart();
    open_step = null;
    markSaved();
    lossy = rep.lossy;
    return true;
}

fn recoverJob(_: []const u8, _: usize, _: usize) void {
    autosave.recoverLatest();
}

/// A recovered scene has no file: Save asks where, so it cannot replace a file
/// that may be newer. The title and Save As keep what it was.
var recovered_buf: [300]u8 = undefined;
var recovered_len: usize = 0;
var recovered_file_len: usize = 0;
var recovered_dir: [512]u8 = undefined;
var recovered_dir_len: usize = 0;

/// Open an autosave as an unsaved scene (undoing goes back to what was here).
/// `file` and `doc`: the name and the path of the scene it was, if any.
pub fn recoverNow(p: []const u8, file: []const u8, doc: []const u8) bool {
    const rep = bee.load(p, viewForFile()) catch |e| {
        app.toast(.warn, "Could not recover {s}: {s}", .{ p, errText(e) });
        return false;
    };
    if (path()) |old| {
        prev_len = @min(old.len, prev_buf.len);
        @memcpy(prev_buf[0..prev_len], old[0..prev_len]);
    } else prev_len = 0;
    prev_saved_at = saved_at;
    prev_lossy = isLossy();
    path_len = 0;
    lossy = false;
    undo.restart();
    open_step = null;
    saved_at = undo.current();
    saved_count_ok = false; // (it is in no file of the user's)
    images_changed = false;
    const shown = std.fmt.bufPrint(&recovered_buf, "{s} (recovered)", .{if (file.len > 0) file else "untitled scene"}) catch "";
    recovered_len = shown.len;
    // (Save As suggests the file's own name: the buffer starts with it)
    recovered_file_len = @min(file.len, shown.len);
    const dl = std.mem.lastIndexOfScalar(u8, doc, '/') orelse 0;
    recovered_dir_len = @min(dl, recovered_dir.len);
    @memcpy(recovered_dir[0..recovered_dir_len], doc[0..recovered_dir_len]);
    app.toast(.ok, "Recovered {d} objects: Save asks where they go", .{rep.objects});
    return true;
}

// --- the commands ------------------------------------------------------------

pub fn save() void {
    if (path()) |p| {
        if (isLossy()) {
            // the file has parts the port did not load: saving over it loses them
            asking_lossy = true;
            app.dirty = true;
            return;
        }
        var copy: [512]u8 = undefined;
        @memcpy(copy[0..p.len], p);
        saveLater(copy[0..p.len]);
    } else saveAs();
}

pub var asking_lossy = false;

pub fn answerLossy(a: enum { save_as, overwrite, cancel }) void {
    asking_lossy = false;
    switch (a) {
        .cancel => {},
        .save_as => saveAs(),
        .overwrite => if (path()) |p| {
            var copy: [512]u8 = undefined;
            @memcpy(copy[0..p.len], p);
            saveLater(copy[0..p.len]);
        },
    }
}

pub fn saveAs() void {
    var nb: [256]u8 = undefined;
    const n = name();
    const rc = recovered_len > 0 and !beforeOpen();
    const suggested = if (rc and recovered_file_len > 0) recovered_buf[0..recovered_file_len] else if (path() == null) "untitled.bee" else (std.fmt.bufPrint(&nb, "{s}", .{n}) catch "untitled.bee");
    if (path()) |p| {
        if (std.mem.lastIndexOfScalar(u8, p, '/')) |sl| fb.goTo(if (sl == 0) "/" else p[0..sl]);
    } else if (rc and recovered_dir_len > 0) fb.goTo(recovered_dir[0..recovered_dir_len]);
    fb.show(.save, "Save As...", ".bee", suggested, saveLater);
}

pub const Pending = enum { new, open, exit, recent, recover };
var pending: Pending = .new;
var pending_path: [512]u8 = undefined;
var pending_len: usize = 0;
pub var asking: bool = false;

/// Run `what`, asking "Save changes?" first when the scene has changes.
pub fn guarded(what: Pending, p: []const u8) void {
    pending = what;
    pending_len = @min(p.len, pending_path.len);
    @memcpy(pending_path[0..pending_len], p[0..pending_len]);
    if (changed()) {
        asking = true;
        app.dirty = true;
        return;
    }
    proceed();
}

/// Run `what` without asking (the console and scripts: the original's run_op,
/// which never confirms; its menus and keys do, run_op_ui).
pub fn unguarded(what: Pending, p: []const u8) void {
    pending = what;
    pending_len = @min(p.len, pending_path.len);
    @memcpy(pending_path[0..pending_len], p[0..pending_len]);
    proceed();
}

fn proceed() void {
    asking = false;
    switch (pending) {
        .new => {
            open_step = null;
            lossy = false;
            @import("world.zig").reset(); // (no world partition)
            scene.reset();
            @import("render.zig").resetSettings();
            @import("env.zig").reset();
            @import("images.zig").clear();
            @import("vgeo.zig").sweep();
            var used: [scene.max_meshes]bool = @splat(false);
            undo.markMeshes(&used);
            scene.collectMeshes(&used);
            path_len = 0;
            undo.restart();
            markSaved();
            app.toast(.ok, "New scene", .{});
        },
        .open => fb.show(.open, "Open...", ".bee", "", openFrom),
        .exit => app.quit = true,
        .recent => openFrom(pending_path[0..pending_len]),
        .recover => @import("jobui.zig").later(recoverJob, "Recovering the autosave", "", 0, 0),
    }
}

/// The answer to "Save changes?": save first, throw them away, or stay.
pub fn answer(a: enum { save, discard, cancel }) void {
    switch (a) {
        .cancel => asking = false,
        .discard => proceed(),
        .save => {
            if (isLossy()) {
                asking = false;
                after_save_as = true;
                saveAs();
                return;
            }
            if (path()) |p| {
                var copy: [512]u8 = undefined;
                @memcpy(copy[0..p.len], p);
                saveTo(copy[0..p.len]);
                if (!changed()) proceed() else asking = false;
            } else {
                // a name first; then go on
                asking = false;
                after_save_as = true;
                saveAs();
            }
        },
    }
}

var after_save_as = false;

/// Called every frame: a Save As started by "Save changes?" that finished goes on.
pub fn poll() void {
    // (a Save As waiting to run, or running: changed() can't tell yet)
    const jobui = @import("jobui.zig");
    if (jobui.on or jobui.queued()) return;
    if (after_save_as and !fb.open_) {
        after_save_as = false;
        if (!changed()) proceed();
    }
}

// --- import / export ----------------------------------------------------------

const formats = @import("formats.zig");

fn errText(e: anyerror) []const u8 {
    return switch (e) {
        error.CannotOpen => "it cannot be read",
        error.Empty => "it has no geometry",
        error.Damaged => "it is damaged",
        error.TooMany => "the scene is full",
        error.NothingToExport => "there is no visible mesh",
        error.CannotWrite => "it cannot be written (a folder? no permission?)",
        error.TooBig => "it is too big",
        error.OutOfMemory => "there is not enough memory",
        else => @errorName(e),
    };
}

pub fn importPath(p0: []const u8) void {
    @import("jobui.zig").later(importJob, "Importing", p0, 0, 0);
}
fn importJob(p: []const u8, _: usize, _: usize) void {
    importNow(p);
}
fn importNow(p0: []const u8) void {
    var eb: [600]u8 = undefined;
    const p = expand(p0, &eb);
    const r = if (std.ascii.endsWithIgnoreCase(p, ".stl")) formats.importStl(p) else formats.importObj(p);
    const i = r catch |e| {
        app.toast(.warn, "Could not import {s}: {s}", .{ p, errText(e) });
        return;
    };
    undo.label("Import");
    const me = scene.meshOfObj(i);
    app.toast(.ok, "Imported {s}: {d} vertices, {d} faces", .{ scene.objects[i].name(), if (me) |x| x.verts.len else 0, if (me) |x| x.faces() else 0 });
}

pub fn exportPath(p0: []const u8) void {
    @import("jobui.zig").later(exportJob, "Exporting", p0, 0, 0);
}
fn exportJob(p: []const u8, _: usize, _: usize) void {
    exportNow(p);
}
fn exportNow(p0: []const u8) void {
    var eb: [600]u8 = undefined;
    const p = expand(p0, &eb);
    if (headless and !std.mem.startsWith(u8, p, "/tmp/")) {
        app.toast(.warn, "Headless: not writing outside /tmp ({s})", .{p});
        return;
    }
    // (the file browser's options hold for this one; scripts: the defaults)
    defer @import("objmtl.zig").defaults();
    const r = if (std.ascii.endsWithIgnoreCase(p, ".stl")) formats.exportStl(p) else formats.exportObj(p);
    const n = r catch |e| {
        app.toast(.warn, "Could not export {s}: {s}", .{ p, errText(e) });
        return;
    };
    app.toast(.ok, "Exported {d} object{s} to {s}", .{ n, if (n == 1) "" else "s", p });
}

pub fn importDialog(extension: []const u8, t: []const u8) void {
    fb.show(.open, t, extension, "", importPath);
}

pub fn exportDialog(extension: []const u8, t: []const u8, suggested: []const u8) void {
    fb.show(.save, t, extension, suggested, exportPath);
    fb.export_options = true;
}
