// Folders in the outliner (folder.s, areas.s): rows with a fold arrow, a
// coloured icon, a name, and an eye, camera and lock for everything in them.
// Click picks a folder and selects what is in it, twice renames it; objects
// dragged onto it move in. The model and the FOLD chunk are folders.zig's.
const std = @import("std");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const undo = @import("undo.zig");
const fd = @import("folders.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");

const Rect = gfx.Rect;

/// In the outliner's row list: BASE + a folder's index.
pub const BASE: u16 = 0x8000;
pub const ROWS_MAX = scene.max_objects + fd.MAX;
pub const ROW_H = 20;

/// FR_COL is an index: 0 none, 1-8 these (fd_colours).
pub const colours = [_]u32{ 0, 0xe5484d, 0xf97316, 0xeab308, 0x22a55b, 0x14b8a6, 0x3b82f6, 0x8b5cf6, 0xec4899 };
const col_names = [_][]const u8{ "none", "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink" };

/// The folder picked (uid, 0: none).
pub var picked: u32 = 0;
/// The folder row under a drag.

pub fn depthOf(uid0: u32) usize {
    var uid = uid0;
    var d: usize = 0;
    while (d < fd.MAX) : (d += 1) {
        const r = fd.get(uid) orelse return d;
        uid = r.parent;
    }
    return d;
}

/// How deep an object's row sits for its folder.
pub fn objDepth(o: *const scene.Object) usize {
    return depthOf(o.folder);
}

fn folderRows(uid: u32, order: []u16, n: *usize, tree: anytype) void {
    const i = fd.index(uid) orelse return;
    if (n.* >= order.len) return;
    order[n.*] = BASE + @as(u16, @intCast(i));
    n.* += 1;
    if (fd.list[i].flags & fd.FOLDED != 0) return;
    children(uid, order, n, tree);
}

fn children(uid: u32, order: []u16, n: *usize, tree: anytype) void {
    // the folders in it
    for (fd.list[0..fd.count]) |*r| {
        if (r.parent == uid) folderRows(r.uid, order, n, tree);
    }
    // its objects: each root with its tree
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (o.parent != null) continue;
        const of = if (fd.index(o.folder) == null) 0 else o.folder;
        if (of == uid) tree(k, order, n);
    }
}

/// Every row, as the original's order: folders nested, the loose objects after.
pub fn build(order: []u16, n: *usize, tree: anytype) void {
    children(0, order, n, tree);
}

fn selectIn(uid: u32) void {
    scene.deselectAll();
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (o.visible and fd.inside(o.folder, uid)) {
            o.selected = true;
            scene.active = k;
        }
    }
}

/// A folder's row clicked alone: it is picked, what is in it selected.
pub fn pick(idx: usize) void {
    picked = fd.list[idx].uid;
    selectIn(picked);
}

/// One folder's row in the Outliner's Zui list (editors.zig): fold, its
/// colour (the icon: a click takes the next), rename in place, lock /
/// render / eye for all it holds, and a drop of outliner rows into it.
pub fn describeRow(z: *zui.Ui, list: *zui.List, row_i: usize, idx: usize, wide: bool, dragged: ?usize) void {
    const th = ui.th;
    const f = &fd.list[idx];
    const uid = f.uid;
    const folded = f.flags & fd.FOLDED != 0;
    const col: u32 = if (f.colour >= 1 and f.colour <= 8) colours[f.colour] else 0;
    const name = fd.nameOf(f);
    z.beginRow(list, row_i, .{
        .label = name,
        .icon = host.icon(if (folded) .folder else .folder_open),
        .icon_color = host.col(if (col != 0) col else th.accent),
        .icon_button = true,
        .depth = @intCast(@min(8, depthOf(f.parent))),
        .fold = !folded,
        .renamable = true,
        .text_color = host.col(if (f.flags & fd.HIDDEN != 0) th.text_off else th.text),
    });
    const eff = fd.effective(uid);
    var locked = eff & fd.LOCKED != 0;
    var rend = eff & fd.NORENDER == 0;
    var vis = eff & fd.HIDDEN == 0;
    if (wide) {
        const lk = z.iconToggle("Folder Lock", &locked, .{ .on = host.icon(.lock), .off = host.icon(.unlock), .size = 20 });
        z.tooltipRich(lk, .{ .title = "Lock / Unlock", .body = "Lock everything in the folder" });
        if (lk.changed) {
            fd.toggle(uid, fd.LOCKED);
            undo.label("Folder Lock");
        }
        const rd = z.iconToggle("Folder Render", &rend, .{ .on = host.icon(.render_on), .size = 20 });
        z.tooltipRich(rd, .{ .title = "Render / Leave Out", .body = "Keep everything in the folder out of renders, or in" });
        if (rd.changed) {
            fd.toggle(uid, fd.NORENDER);
            undo.label("Folder Render");
        }
    }
    const ey = z.iconToggle("Folder Eye", &vis, .{ .on = host.icon(.eye), .off = host.icon(.eye_off), .size = 20 });
    z.tooltipRich(ey, .{ .title = "Show / Hide", .body = "Show or hide everything in the folder" });
    if (ey.changed) {
        fd.toggle(uid, fd.HIDDEN);
        undo.label("Folder Visibility");
    }
    const res = z.endRow(list);
    ui.record("folder", name, host.rectOf(res.rect), true);
    if (res.fold_rect.w > 0) ui.record("fold", name, host.rectOf(res.fold_rect), true);
    ui.record("colour", "Folder Colour", host.rectOf(res.icon_rect), true);
    if (res.fold_clicked) fd.toggle(uid, fd.FOLDED);
    if (res.icon_clicked) {
        nextColour(f);
        undo.label("Folder Colour");
    }
    if (res.renamed) |nm| {
        rename(f, nm);
        undo.label("Rename Folder");
    }
    // outliner rows dropped on it: into it
    if (dragged) |dk| if (z.dropZone(res.rect, "object")) |d| {
        z.dropHint("Into it");
        if (d.released) {
            if (moveSelection(uid, dk) > 0) app.toast(.ok, "Into {s}", .{fd.name(uid)});
            undo.label("Move to Folder");
        }
    };
}

fn rename(f: *fd.Rec, s: []const u8) void {
    if (s.len == 0) return;
    const n = @min(s.len, 31);
    f.name = @splat(0);
    @memcpy(f.name[0..n], s[0..n]);
}

/// next: 1 .. 8, then none.
fn nextColour(f: *fd.Rec) void {
    f.colour = if (f.colour + 1 < 9) f.colour + 1 else 0;
}

/// The selection (and the row dragged) into a folder.
pub fn moveSelection(uid: u32, extra: ?usize) usize {
    var n: usize = 0;
    for (scene.objects[0..scene.count], 0..) |*o, k| {
        if (!o.selected and (extra == null or extra.? != k)) continue;
        fd.setObject(o, uid);
        n += 1;
    }
    return n;
}

// --- operators -------------------------------------------------------------------------

fn word() []const u8 {
    return std.mem.trim(u8, ops.arg, " \"");
}

pub fn pollObjectMode() ?[]const u8 {
    return if (@import("editmesh.zig").active) "Only in object mode" else null;
}

pub fn opNew() void {
    const nm = word();
    if (fd.count >= fd.MAX) return app.log("  folders: 256 at most", .{});
    const uid = fd.make(if (nm.len > 0) nm else "Folder", if (fd.index(picked) != null) picked else 0);
    if (uid == 0) return;
    _ = moveSelection(uid, null);
    picked = uid;
    app.log("  folder: {s}", .{fd.name(uid)});
}

pub fn opMove() void {
    const nm = word();
    if (nm.len == 0) return app.log("  object.move_to_folder <name | none>", .{});
    if (std.mem.eql(u8, nm, "none")) {
        for (scene.objects[0..scene.count]) |*o| {
            if (o.selected) o.folder = 0;
        }
        return;
    }
    var uid: u32 = 0;
    for (fd.list[0..fd.count]) |*r| {
        if (std.mem.eql(u8, fd.nameOf(r), nm)) uid = r.uid;
    }
    if (uid == 0) uid = fd.make(nm, 0);
    if (uid != 0) _ = moveSelection(uid, null);
}

fn pollPicked() ?[]const u8 {
    return if (fd.index(picked) == null) "Pick a folder in the outliner first" else null;
}
pub const poll = pollPicked;

pub fn opRename() void {
    const r = fd.get(picked) orelse return;
    rename(r, word());
}

pub fn opSelect() void {
    selectIn(picked);
}

pub fn opDelete() void {
    const r = fd.get(picked) orelse return;
    const uid = picked;
    const up = r.parent;
    const contents = std.mem.eql(u8, word(), "contents");
    var i = scene.count;
    while (i > 0) {
        i -= 1;
        const o = &scene.objects[i];
        if (!fd.inside(o.folder, uid)) continue;
        if (contents) {
            scene.remove(i);
        } else if (o.folder == uid) o.folder = up;
    }
    for (fd.list[0..fd.count]) |*q| {
        if (q.parent == uid) q.parent = up;
    }
    const at = fd.index(uid).?;
    std.mem.copyForwards(fd.Rec, fd.list[at .. fd.count - 1], fd.list[at + 1 .. fd.count]);
    fd.count -= 1;
    picked = 0;
}

/// outliner.folder_color <colour | next> [name]: the folder named, else the one picked.
pub fn opColour() void {
    const bad = "  folder colours: none red orange yellow green teal blue purple pink next";
    var it = std.mem.tokenizeScalar(u8, ops.arg, ' ');
    const c = it.next() orelse return app.log(bad, .{});
    var want: ?u32 = null;
    if (!std.mem.eql(u8, c, "next")) {
        for (col_names, 0..) |cn, k| {
            if (std.mem.eql(u8, cn, c)) want = @intCast(k);
        }
        if (want == null) return app.log(bad, .{});
    }
    const nm = std.mem.trimStart(u8, it.rest(), " ");
    var uid = picked;
    if (nm.len > 0) {
        uid = fd.find(nm);
        if (uid == 0) return app.log("  no folder named {s}", .{nm});
    }
    const f = fd.get(uid) orelse return app.log("  pick a folder in the outliner first", .{});
    if (want) |k| f.colour = k else nextColour(f);
    app.dirty = true;
}

// --- Tidy (#441) -----------------------------------------------------------------------

const KEY = 32;
var keys: [scene.max_objects][KEY]u8 = undefined;
var key_len: [scene.max_objects]u8 = undefined;
const tidy_cols = [_]u32{ 6, 4, 2, 7, 5, 1, 3, 8 };

/// fd_key: an object's tidy group: Lights, Cameras, References, else its
/// name less a ".001" and trailing digits, _ - and spaces ("Chair.002",
/// "Chair_12" -> "Chair"; all of it when that is all there is); "" for what
/// stays where it is (a child, the Ground).
pub fn tidyKey(o: *const scene.Object, dst: *[KEY]u8) []const u8 {
    if (o.gflags & @import("prims.zig").OBF_GROUND != 0 or o.parent != null) return dst[0..0];
    const kind: ?[]const u8 = if (o.kind == .light) "Lights" else if (o.kind == .camera) "Cameras" else if (o.ref & @import("refimg.zig").REFIMG != 0) "References" else null;
    const src = kind orelse o.name();
    const n0 = @min(src.len, KEY - 1);
    @memcpy(dst[0..n0], src[0..n0]);
    if (kind != null) return dst[0..n0];
    var n = n0;
    while (n > 0) : (n -= 1) {
        const c = dst[n - 1];
        if (!((c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-' or c == ' ')) break;
    }
    return dst[0..(if (n == 0) n0 else n)]; // (only digits: kept whole)
}

/// fd_prune: the folders with no object and no folder in them go (again, till
/// none is left: a folder of empty folders goes too).
fn prune() void {
    var i: usize = 0;
    while (i < fd.count) {
        const uid = fd.list[i].uid;
        var used = false;
        for (fd.list[0..fd.count]) |*q| {
            if (q.parent == uid) used = true;
        }
        for (scene.objects[0..scene.count]) |*o| {
            if (o.folder == uid) used = true;
        }
        if (used) {
            i += 1;
            continue;
        }
        std.mem.copyForwards(fd.Rec, fd.list[i .. fd.count - 1], fd.list[i + 1 .. fd.count]);
        fd.count -= 1;
        if (picked == uid) picked = 0;
        i = 0;
    }
}

/// outliner.tidy: the objects in no folder, grouped by tidyKey into a folder
/// each (two or more of a kind), coloured; then the folders left empty go.
pub fn opTidy() void {
    const n = scene.count;
    for (scene.objects[0..n], 0..) |*o, k| {
        key_len[k] = 0;
        if (o.folder == 0) key_len[k] = @intCast(tidyKey(o, &keys[k]).len);
    }
    var moved: u32 = 0;
    var cycle: u32 = 0;
    var cur: [KEY]u8 = undefined;
    outer: for (0..n) |i| {
        if (key_len[i] == 0) continue;
        const kl = key_len[i];
        @memcpy(cur[0..kl], keys[i][0..kl]);
        const key = cur[0..kl];
        var same: u32 = 0;
        for (0..n) |j| {
            if (std.mem.eql(u8, keys[j][0..key_len[j]], key)) same += 1;
        }
        if (same < 2) continue; // one alone: stays where it is
        var uid = fd.find(key);
        if (uid == 0) {
            uid = fd.ensure(key, 0);
            if (uid == 0) break :outer; // (no room)
            const col: u32 = if (std.mem.eql(u8, key, "Lights")) 3 else if (std.mem.eql(u8, key, "Cameras")) 8 else if (std.mem.eql(u8, key, "References")) 5 else blk: {
                const cc = tidy_cols[cycle & 7];
                cycle += 1;
                break :blk cc;
            };
            fd.get(uid).?.colour = col;
        }
        for (0..n) |j| {
            if (!std.mem.eql(u8, keys[j][0..key_len[j]], key)) continue;
            key_len[j] = 0;
            fd.setObject(&scene.objects[j], uid);
            moved += 1;
        }
    }
    prune();
    app.dirty = true;
    app.log("  tidied: objects in folders {d}", .{moved});
}

/// outliner.tidy_ai: the AI Assistant asked to sort the scene into folders.
pub fn opTidyAi() void {
    const ai = @import("aihook.zig");
    if (ai.isBusy()) return app.log("  the AI is busy: try again when it is done", .{});
    _ = ai.send(tidy_prompt, "", "tidy the outliner");
}

const tidy_prompt = "Tidy the outliner: sort the scene's objects into folders by what they are (furniture, walls, lights, cameras, props ...). " ++
    "Use outliner.folder_new or object.move_to_folder <name> on selections, give each folder a short clear name, colour each with outliner.folder_color, " ++
    "keep children with their parents, and delete folders left empty (outliner.folder_delete). Do not move, rename or change the objects themselves. " ++
    "Answer in one short sentence: the folders you made.";

test "tidy keys" {
    var o = scene.Object{ .kind = .mesh };
    var b: [KEY]u8 = undefined;
    const set = struct {
        fn f(ob: *scene.Object, s: []const u8) void {
            @memcpy(ob.name_buf[0..s.len], s);
            ob.name_len = @intCast(s.len);
        }
    }.f;
    set(&o, "Chair.002");
    try std.testing.expectEqualStrings("Chair", tidyKey(&o, &b));
    set(&o, "Chair_12");
    try std.testing.expectEqualStrings("Chair", tidyKey(&o, &b));
    set(&o, "123");
    try std.testing.expectEqualStrings("123", tidyKey(&o, &b));
    set(&o, "Wall - 3 ");
    try std.testing.expectEqualStrings("Wall", tidyKey(&o, &b));
    o.kind = .light;
    try std.testing.expectEqualStrings("Lights", tidyKey(&o, &b));
    o.kind = .mesh;
    o.parent = 0;
    try std.testing.expectEqualStrings("", tidyKey(&o, &b));
}

test "row order" {
    fd.reset();
    const a = fd.make("A", 0);
    const b = fd.make("B", a);
    try std.testing.expectEqual(@as(usize, 0), depthOf(0));
    try std.testing.expectEqual(@as(usize, 1), depthOf(a));
    try std.testing.expectEqual(@as(usize, 2), depthOf(b));
}
