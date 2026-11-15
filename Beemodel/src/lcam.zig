// Light and camera settings as the original keeps them (lcam.s): one block,
// reference counted and shared with the undo steps (a change copies it), with
// the uid of the camera that renders and a 32-byte record per object uid whose
// settings were set (light.set, camera.set, a properties field), in the order
// they were first set. An object without a record has the defaults. Records
// outlive their objects (a delete leaves them, as in the original); a new
// object or a duplicate starts without one. .bee files keep the block as LCAM.
//
// The objects' own fields (power in W, an sRGB colour ...) are what draws and
// renders. light.set and camera.set write the record and the fields follow
// (apply); a field changed in the port's properties panel reaches its record
// through sync (each undo step and each save), which writes only the setting
// that differs, so a record keeps the bytes of the settings no one touched.
const std = @import("std");
const scene = @import("scene.zig");
const A = @import("alloc.zig").A;

pub const MAX = 256;

/// A record (LR_*): a light's type and a camera's lens share a field.
pub const Rec = extern struct {
    uid: u32,
    power: f32 = 1, // x the default light (1000 W here)
    col: [3]f32 = .{ 1, 1, 1 }, // linear
    lens: u32 = @bitCast(@as(f32, 50)), // a camera: mm (float); a light: its type (0..3, else point)
    size: f32 = 0,
    angle: f32 = 0, // a spot's cone (deg, 0: 45)
};

pub const Block = struct {
    refs: u32 = 1,
    cam: u32 = 0,
    n: u32 = 0,
    r: [MAX]Rec = undefined,
};

/// The block now (null: none, as in a new scene).
pub var cur: ?*Block = null;

fn unref(b: ?*Block) void {
    const x = b orelse return;
    x.refs -= 1;
    if (x.refs == 0) A.destroy(x);
}

/// lc_reset: no block (a new scene).
pub fn reset() void {
    unref(cur);
    cur = null;
}

/// The undo steps: a snapshot holds a reference to the block it saw.
pub fn keep(slot: *?*Block) void {
    if (cur) |b| b.refs += 1;
    unref(slot.*);
    slot.* = cur;
}
pub fn restore(b: ?*Block) void {
    if (b) |x| x.refs += 1;
    unref(cur);
    cur = b;
}

/// lc_own: cur, unshared (made if none); null without memory.
fn own() ?*Block {
    if (cur) |b| {
        if (b.refs == 1) return b;
    }
    const nb = A.create(Block) catch return null;
    nb.* = .{};
    if (cur) |b| {
        nb.cam = b.cam;
        nb.n = b.n;
        @memcpy(nb.r[0..b.n], b.r[0..b.n]);
    }
    unref(cur);
    cur = nb;
    return nb;
}

/// lc_get: its record, or null.
pub fn get(uid: u32) ?*const Rec {
    const b = cur orelse return null;
    for (b.r[0..b.n]) |*r| {
        if (r.uid == uid) return r;
    }
    return null;
}

/// lc_rec_own: its record, writable (made with the defaults); null when full.
pub fn recOwn(uid: u32) ?*Rec {
    const b = own() orelse return null;
    for (b.r[0..b.n]) |*r| {
        if (r.uid == uid) return r;
    }
    if (b.n >= MAX) return null;
    b.r[b.n] = .{ .uid = uid };
    b.n += 1;
    return &b.r[b.n - 1];
}

/// lc_active: the uid of the camera chosen to render (0: the first one).
pub fn active() u32 {
    return if (cur) |b| b.cam else 0;
}

fn setCam(uid: u32) void {
    if (active() == uid) return;
    if (own()) |b| b.cam = uid;
}

// --- the objects' fields -----------------------------------------------------------

pub const Fields = struct {
    power: f32 = 1000,
    color: u32 = 0xffffff,
    light_type: scene.LightType = .point,
    lens: f32 = 50,
    size: f32 = 0,
    cone: f32 = 45,
};

/// What an object with this record (or none) shows.
pub fn fieldsOf(kind: scene.Kind, rec: ?*const Rec) Fields {
    const r = rec orelse return .{};
    var f = Fields{};
    f.power = if (std.math.isFinite(r.power)) std.math.clamp(r.power * 1000.0, 0, 1e9) else 1000;
    f.color = linearToSrgb(r.col);
    if (kind == .camera) {
        const lens: f32 = @bitCast(r.lens);
        f.lens = if (std.math.isFinite(lens) and lens > 0) lens else 50;
    } else {
        f.light_type = if (r.lens <= 3) @enumFromInt(r.lens) else .point;
    }
    f.size = if (std.math.isFinite(r.size)) std.math.clamp(r.size, 0, 1e6) else 0.1;
    f.cone = if (std.math.isFinite(r.angle) and r.angle > 0) @min(r.angle, 180) else 45;
    return f;
}

/// Object i's fields as its record says.
pub fn apply(i: usize) void {
    const o = &scene.objects[i];
    const f = fieldsOf(o.kind, get(o.uid));
    o.power = f.power;
    o.light_color = f.color;
    if (o.kind == .camera) o.lens = f.lens else o.light_type = f.light_type;
    o.size = f.size;
    o.cone = f.cone;
}

fn setF(uid: u32, comptime field: []const u8, v: anytype) void {
    if (get(uid)) |r| {
        if (std.meta.eql(@field(r.*, field), v)) return;
    }
    const r = recOwn(uid) orelse return;
    @field(r.*, field) = v;
}

/// The objects' fields into their records: each setting that differs from what
/// the record (or the defaults) gives, and the camera that renders.
pub fn sync() void {
    for (scene.objects[0..scene.count]) |*o| {
        if (o.kind != .light and o.kind != .camera) continue;
        const f = fieldsOf(o.kind, get(o.uid));
        if (o.kind == .camera) {
            if (o.lens != f.lens) setF(o.uid, "lens", @as(u32, @bitCast(o.lens)));
            continue;
        }
        if (o.power != f.power) setF(o.uid, "power", o.power / 1000.0);
        if (o.light_color != f.color) setF(o.uid, "col", srgbToLinear(o.light_color));
        if (o.light_type != f.light_type) setF(o.uid, "lens", @as(u32, @intFromEnum(o.light_type)));
        if (o.size != f.size) setF(o.uid, "size", o.size);
        if (o.cone != f.cone) setF(o.uid, "angle", o.cone);
    }
    if (scene.render_camera) |c| {
        if (c < scene.count) setCam(scene.objects[c].uid);
    }
}

pub fn srgbToLinear(c: u32) [3]f32 {
    var out: [3]f32 = undefined;
    for (0..3) |k| {
        const v: f32 = @as(f32, @floatFromInt((c >> @intCast(16 - k * 8)) & 255)) / 255.0;
        out[k] = if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }
    return out;
}

pub fn linearToSrgb(c: [3]f32) u32 {
    var out: u32 = 0;
    for (c) |v0| {
        const v = if (std.math.isFinite(v0)) std.math.clamp(v0, 0, 1) else 1;
        const s = if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
        out = (out << 8) | @as(u32, @intFromFloat(@round(s * 255)));
    }
    return out;
}

// --- LCAM ---------------------------------------------------------------------------

/// lc_write: the camera, the count, the records.
pub fn write(b: anytype) void {
    b.u32_(active());
    const bl = cur orelse return b.u32_(0);
    b.u32_(bl.n);
    b.bytes(std.mem.sliceAsBytes(bl.r[0..bl.n]));
}

/// lc_read: the block as the chunk has it (records past 256 dropped; a chunk
/// too short for its count leaves none). Then every object's fields from its
/// record, and the camera that renders (`look`: uid -> our index).
pub fn read(c: []const u8, look: anytype) void {
    reset();
    blk: {
        if (c.len < 8) break :blk;
        const n = @min(rd(c, 4), MAX);
        if (8 + @as(usize, n) * 32 > c.len) break :blk;
        const b = own() orelse break :blk;
        b.cam = rd(c, 0);
        b.n = n;
        @memcpy(std.mem.sliceAsBytes(b.r[0..n]), c[8..][0 .. @as(usize, n) * 32]);
    }
    scene.render_camera = if (look.get(active())) |x| x else null;
    for (0..scene.count) |i| {
        const k = scene.objects[i].kind;
        if (k == .light or k == .camera) apply(i);
    }
}

fn rd(c: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, c[o..][0..4], .little);
}

// --- light.set, camera.set ----------------------------------------------------------

const Target = struct { i: usize, r: *Rec };

/// lc_target: the active object's record when it is that kind.
fn target(kind: scene.Kind) ?Target {
    if (scene.active) |i| {
        if (i < scene.count and scene.objects[i].kind == kind) {
            const r = recOwn(scene.objects[i].uid) orelse return null;
            return .{ .i = i, .r = r };
        }
    }
    @import("app.zig").log("  select a light (or a camera) first", .{});
    return null;
}

/// lc_num: the next word as a number, max with lo.
fn num(it: anytype, lo: f32) ?f32 {
    const w = it.next() orelse return null;
    const v = @import("print.zig").parseFloat(w) orelse return null;
    return @max(v, lo);
}

/// light.set power <p> | color <r> <g> <b> | type point|sun|spot|area | size <v> | angle <deg>
pub fn opLight() void {
    const ops = @import("ops.zig");
    const t = target(.light) orelse return;
    var it = std.mem.tokenizeAny(u8, ops.arg, " \t");
    const w = it.next() orelse "";
    if (std.mem.eql(u8, w, "power")) {
        t.r.power = num(&it, 0) orelse return bad(t.i, "  light.set power <p> | color <r> <g> <b> (0..1; the active light)");
    } else if (std.mem.eql(u8, w, "type")) {
        const v = it.next() orelse "";
        const words = [_][]const u8{ "point", "sun", "spot", "area" };
        for (words, 0..) |x, k| {
            if (std.mem.eql(u8, v, x)) {
                t.r.lens = @intCast(k);
                break;
            }
        } else return bad(t.i, "  light.set power <p> | color <r> <g> <b> (0..1; the active light)");
    } else if (std.mem.eql(u8, w, "size") or std.mem.eql(u8, w, "angle")) {
        const v = num(&it, 0) orelse return bad(t.i, "  light.set power <p> | color <r> <g> <b> (0..1; the active light)");
        if (w[0] == 's') t.r.size = v else t.r.angle = v;
    } else if (std.mem.eql(u8, w, "color")) {
        // (a colour stops at the first word that is no number, the ones before it set)
        for (0..3) |k| t.r.col[k] = num(&it, 0) orelse return bad(t.i, "  light.set power <p> | color <r> <g> <b> (0..1; the active light)");
    } else return bad(t.i, "  light.set power <p> | color <r> <g> <b> (0..1; the active light)");
    apply(t.i);
    @import("undo.zig").label("Light Settings");
}

/// camera.set lens <mm> | active
pub fn opCamera() void {
    const ops = @import("ops.zig");
    const t = target(.camera) orelse return;
    var it = std.mem.tokenizeAny(u8, ops.arg, " \t");
    const w = it.next() orelse "";
    if (std.mem.eql(u8, w, "lens")) {
        const v = num(&it, 1) orelse return bad(t.i, "  camera.set lens <mm> | active (the active camera)");
        t.r.lens = @bitCast(v);
    } else if (std.mem.eql(u8, w, "active")) {
        renderFrom(t.i);
    } else return bad(t.i, "  camera.set lens <mm> | active (the active camera)");
    apply(t.i);
    @import("undo.zig").label("Camera Settings");
}

/// camera.set active for camera i (the properties' button).
pub fn renderFrom(i: usize) void {
    const r = recOwn(scene.objects[i].uid) orelse return;
    if (cur) |b| b.cam = r.uid;
    scene.render_camera = i;
}

/// undo_drop_last: no step of its own (what it did - a record made - goes with
/// the step the scene is at, as the original keeps it without one).
fn bad(i: usize, msg: []const u8) void {
    @import("app.zig").log("{s}", .{msg});
    apply(i);
    @import("undo.zig").replaceCurrent();
}

test "a record's defaults are lc_rec_own's" {
    const r = Rec{ .uid = 2 };
    const b = std.mem.asBytes(&r);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 0, 0, 0, 0, 0, 0x80, 0x3f, 0, 0, 0x80, 0x3f, 0, 0, 0x80, 0x3f, 0, 0, 0x80, 0x3f, 0, 0, 0x48, 0x42, 0, 0, 0, 0, 0, 0, 0, 0 }, b);
    // no record: the defaults; a light's record keeps the lens bits as "point"
    const f = fieldsOf(.light, &r);
    try std.testing.expectEqual(scene.LightType.point, f.light_type);
    try std.testing.expectEqual(@as(f32, 1000), f.power);
    try std.testing.expectEqual(@as(u32, 0xffffff), f.color);
    try std.testing.expectEqual(@as(f32, 45), f.cone);
    try std.testing.expectEqual(@as(f32, 50), fieldsOf(.camera, &r).lens);
    for ([_]u32{ 0, 0x123456, 0xffffff, 0x808080, 0x010203 }) |c| try std.testing.expectEqual(c, linearToSrgb(srgbToLinear(c)));
}

test "records: copy on write, sync writes only what differs, delete keeps them" {
    defer reset();
    reset();
    scene.count = 2;
    defer scene.count = 0;
    scene.objects[0] = .{ .kind = .light, .uid = 5 };
    scene.objects[1] = .{ .kind = .camera, .uid = 6 };
    sync();
    try std.testing.expect(cur == null); // (the defaults: no record)
    scene.objects[0].power = 2000;
    sync();
    const r = get(5).?;
    try std.testing.expectEqual(@as(f32, 2), r.power);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 50))), r.lens); // (the type: never set)
    try std.testing.expect(get(6) == null);
    // an undo step holds the block: a change copies it
    var slot: ?*Block = null;
    keep(&slot);
    const before = cur;
    sync(); // (nothing differs: no copy)
    try std.testing.expect(cur == before);
    scene.objects[1].lens = 85;
    sync();
    try std.testing.expect(cur != before and cur.?.n == 2 and slot.?.n == 1);
    restore(slot);
    try std.testing.expect(get(6) == null);
    apply(1);
    try std.testing.expectEqual(@as(f32, 50), scene.objects[1].lens);
    // gone from the scene: the record stays
    scene.count = 1;
    scene.objects[0] = .{ .kind = .camera, .uid = 6 };
    sync();
    try std.testing.expect(get(5) != null and get(6) == null);
    var s2: ?*Block = null;
    keep(&s2);
    unref(slot);
    unref(s2);
}
