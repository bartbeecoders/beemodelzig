// Outliner folders (folder.s), the model only: named groups of objects that
// never move anything, with their own eye, camera and lock, kept in files as
// the original's FOLD chunk: the records, then (object uid, folder uid) pairs.
// An object's folder is Object.folder (a uid, 0: none). The outliner does not
// show them yet (row "Folders" of the tracker); reference drawings go in them.
const std = @import("std");
const scene = @import("scene.zig");

pub const FOLDED = 1;
pub const HIDDEN = 2;
pub const NORENDER = 4;
pub const LOCKED = 8;

pub const MAX = 256;
pub const REC = 48;
/// A record, as in the file (folder.s FR_*).
pub const Rec = extern struct { uid: u32 = 0, parent: u32 = 0, flags: u32 = 0, colour: u32 = 0, name: [32]u8 = @splat(0) };
comptime {
    std.debug.assert(@sizeOf(Rec) == REC);
}

pub var list: [MAX]Rec = @splat(.{});
pub var count: usize = 0;
var next: u32 = 1;

pub fn nameOf(r: *const Rec) []const u8 {
    return std.mem.sliceTo(&r.name, 0);
}

pub fn reset() void {
    count = 0;
    next = 1;
}

/// Its index, or null.
pub fn index(uid: u32) ?usize {
    if (uid == 0) return null;
    for (list[0..count], 0..) |*r, i| {
        if (r.uid == uid) return i;
    }
    return null;
}

pub fn get(uid: u32) ?*Rec {
    return &list[index(uid) orelse return null];
}

pub fn name(uid: u32) []const u8 {
    return nameOf(get(uid) orelse return "");
}

fn taken(s: []const u8) bool {
    for (list[0..count]) |*r| {
        if (std.mem.eql(u8, nameOf(r), s)) return true;
    }
    return false;
}

/// A new folder (the name made unique with .001 ...): its uid, 0: no room.
pub fn make(want: []const u8, parent: u32) u32 {
    if (count >= MAX) return 0;
    var n = @min(want.len, 27);
    while (n > 0 and n < want.len and want[n] & 0xc0 == 0x80) n -= 1;
    const base = want[0..n];
    var r = Rec{ .uid = next, .parent = parent };
    var k: u32 = 0;
    while (k < 1000) : (k += 1) {
        var buf: [32]u8 = @splat(0);
        const s = if (k == 0) std.fmt.bufPrint(buf[0..31], "{s}", .{base}) catch base else std.fmt.bufPrint(buf[0..31], "{s}.{d:0>3}", .{ base, k }) catch base;
        if (!taken(s)) {
            r.name = buf;
            break;
        }
    }
    list[count] = r;
    count += 1;
    next += 1;
    return r.uid;
}

/// fd_find: the folder with exactly this name (any parent): its uid, 0 none.
pub fn find(nm: []const u8) u32 {
    for (list[0..count]) |*r| {
        if (std.mem.eql(u8, nameOf(r), nm)) return r.uid;
    }
    return 0;
}

/// fd_ensure: the folder of that name, made inside `parent` when there is
/// none (its name as given, 31 bytes at most): its uid, 0 no room.
pub fn ensure(nm: []const u8, parent: u32) u32 {
    const have = find(nm);
    if (have != 0) return have;
    if (count >= MAX) {
        @import("app.zig").log("  folders: 256 at most", .{});
        return 0;
    }
    var r = Rec{ .uid = next, .parent = parent };
    const n = @min(nm.len, 31);
    @memcpy(r.name[0..n], nm[0..n]);
    list[count] = r;
    count += 1;
    next += 1;
    return r.uid;
}

/// Whether folder `uid` is `of` or inside it, at any depth.
pub fn inside(uid0: u32, of: u32) bool {
    var uid = uid0;
    var k: usize = 0;
    while (uid != 0 and k <= MAX) : (k += 1) {
        if (uid == of) return true;
        uid = (get(uid) orelse return false).parent;
    }
    return false;
}

/// The flags it has with those of the folders around it (hidden, render, lock).
pub fn effective(uid0: u32) u32 {
    var uid = uid0;
    var f: u32 = 0;
    var k: usize = 0;
    while (uid != 0 and k <= MAX) : (k += 1) {
        const r = get(uid) orelse break;
        f |= r.flags;
        uid = r.parent;
    }
    return f & (HIDDEN | NORENDER | LOCKED);
}

fn apply(o: *scene.Object, flag: u32, on: bool) void {
    switch (flag) {
        HIDDEN => {
            o.visible = !on;
            if (on) o.selected = false;
        },
        NORENDER => o.render = !on,
        LOCKED => o.locked = on,
        else => {},
    }
}

/// An object into a folder: it takes on what the folder has off.
pub fn setObject(o: *scene.Object, uid: u32) void {
    o.folder = uid;
    const f = effective(uid);
    if (f & HIDDEN != 0) {
        o.visible = false;
    }
    if (f & NORENDER != 0) o.render = false;
    if (f & LOCKED != 0) o.locked = true;
}

/// A folder's flag turned; its objects (at any depth) follow, but for folded.
pub fn toggle(uid: u32, flag: u32) void {
    const r = get(uid) orelse return;
    r.flags ^= flag;
    if (flag == FOLDED) return;
    const on = r.flags & flag != 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (inside(o.folder, uid)) apply(o, flag, on);
    }
}

/// A folder of that name (or that name.001 ...) in a parent: its uid, 0 none.
pub fn child(nm: []const u8, parent: u32) u32 {
    for (list[0..count]) |*r| {
        if (r.parent != parent) continue;
        if (sameBase(nameOf(r), nm)) return r.uid;
    }
    return 0;
}

/// It is that name, or that name with a ".001" after it (rs_prefix_eq).
pub fn sameBase(s: []const u8, nm: []const u8) bool {
    return std.mem.startsWith(u8, s, nm) and (s.len == nm.len or s[nm.len] == '.');
}

// --- files -----------------------------------------------------------------------

pub fn writeChunk(out: anytype) void {
    out.u32_(@intCast(count));
    if (count > 0) out.bytes(std.mem.sliceAsBytes(list[0..count]));
    var n: u32 = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (o.folder != 0) n += 1;
    }
    out.u32_(n);
    for (scene.objects[0..scene.count]) |*o| {
        if (o.folder == 0) continue;
        out.u32_(o.uid); // (the file's uid)
        out.u32_(o.folder);
    }
}

fn rd32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .little);
}

/// Back from a file, after the objects: uid_to(the file's uid) is the object.
/// False: damaged (nothing kept).
pub fn readChunk(d: []const u8, ctx: anytype, uid_to: fn (@TypeOf(ctx), u32) ?u16) bool {
    reset();
    if (d.len == 0) return true;
    if (d.len < 8) return false;
    const n = rd32(d, 0);
    if (n > MAX or 4 + @as(u64, n) * REC + 4 > d.len) return false;
    @memcpy(std.mem.sliceAsBytes(list[0..n]), d[4..][0 .. @as(usize, n) * REC]);
    for (list[0..n]) |*r| {
        r.name[31] = 0;
        next = @max(next, r.uid +| 1);
    }
    count = n;
    var o: usize = 4 + @as(usize, n) * REC;
    const pairs = rd32(d, o);
    o += 4;
    if (@as(u64, pairs) * 8 > d.len - o) return false;
    for (0..pairs) |_| {
        const uid = rd32(d, o);
        const fd = rd32(d, o + 4);
        o += 8;
        if (index(fd) == null) continue;
        if (uid_to(ctx, uid)) |i| scene.objects[i].folder = fd;
    }
    return true;
}

// --- undo -------------------------------------------------------------------------

pub const Snap = struct { recs: []Rec = &.{}, next: u32 = 1 };
const alloc_ = @import("alloc.zig").A;

pub fn save(s: *Snap) void {
    if (s.recs.len != count) {
        if (s.recs.len > 0) alloc_.free(s.recs);
        s.recs = alloc_.alloc(Rec, count) catch &.{};
    }
    if (s.recs.len == count) @memcpy(s.recs, list[0..count]);
    s.next = next;
}

pub fn load(s: *const Snap) void {
    @memcpy(list[0..s.recs.len], s.recs);
    count = s.recs.len;
    next = s.next;
}

pub fn same(s: *const Snap) bool {
    return s.recs.len == count and std.mem.eql(u8, std.mem.sliceAsBytes(s.recs), std.mem.sliceAsBytes(list[0..count]));
}
