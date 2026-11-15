// Motion paths and onion skins (rig.s): what motion looks like in the viewport.
// A path is where an object was over a run of frames, sampled when asked for.
// Onion skins are wire ghosts of the active object some frames before (red) and
// after (green), made again when the object, the frame or the keys change.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const anim = @import("anim.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const frange = @import("frange.zig");
const mods = @import("mods.zig");
const gfx = @import("gfx.zig");
const A = @import("alloc.zig").A;
const vp = @import("viewport.zig");

const MP_MAX = 4;
const MP_MAXF = 1024;
const ON_MAX = 8;
const COL_GHOST_A: u32 = 0x60d070; // after
const COL_GHOST_B: u32 = 0xf06060; // before
const COL_PATH: u32 = 0x7aa6ff;
const COL_PATH_KEY: u32 = 0xffd27a;

/// Pose mode's selected bones instead of objects (armatures): how many there
/// are in `who` as (armature oid, bone), and a bone's tail in the world.
pub var bones_selected: ?*const fn (who: *[MP_MAX][2]i64) usize = null;
pub var bone_tail: ?*const fn (oid: u32, bone: u32) ?m.V3 = null;

pub var n_paths: usize = 0;
var f0: i32 = 0;
pub var n_frames: usize = 0;
var who: [MP_MAX][2]i64 = undefined; // oid, bone (-1: the object)
var pts: [MP_MAX * MP_MAXF]m.V3 = undefined;
var has_key: [MP_MAX * MP_MAXF]bool = undefined;

pub var on_on = false;
pub var on_before: i32 = 2;
pub var on_after: i32 = 2;
pub var on_step: i32 = 2;
const Ghost = struct { verts: []m.V3, edges: [][2]u32, mat: m.M4, off: i32 };
var ghosts: [ON_MAX]Ghost = undefined;
pub var on_n: usize = 0;
var on_oid: u32 = 0;
var on_frame: f32 = 0;
var on_anim: ?*anim.Block = null;
var version: u32 = 0;
var making = false;

fn freeGhosts() void {
    for (ghosts[0..on_n]) |*g| {
        A.free(g.verts);
        A.free(g.edges);
    }
    on_n = 0;
    on_oid = 0;
}

pub fn reset() void {
    n_paths = 0;
    freeGhosts();
    version +%= 1;
}

/// What the viewport's image hangs on.
pub fn stateWord() u64 {
    return (@as(u64, version) << 8) | @as(u64, @intFromBool(on_on)) << 7 | n_paths | (@as(u64, on_n) << 3);
}

/// A path's points (the tests).
pub fn points(p: usize) []const m.V3 {
    return pts[p * MP_MAXF..][0..n_frames];
}

fn haskey(kind: u32, a: u32, bone: i64, f: f32) bool {
    const b = anim.cur orelse return false;
    for (b.curves()) |*c| {
        if (c.act != 0 or c.kind != kind or c.a != a) continue;
        if (bone >= 0 and c.b != @as(u32, @intCast(bone))) continue;
        for (b.keysOf(c)) |*k| {
            if (@abs(k.f - f) < 0.5) return true;
        }
    }
    return false;
}

fn point(p: usize) m.V3 {
    const oid: u32 = @intCast(who[p][0]);
    const bone = who[p][1];
    if (bone >= 0) {
        if (bone_tail) |f| {
            if (f(oid, @intCast(bone))) |v| return v;
        }
        return .{ 0, 0, 0 };
    }
    const i = scene.findOid(oid) orelse return .{ 0, 0, 0 };
    return scene.worldLoc(i);
}

fn num(s: ?[]const u8) ?f32 {
    const w = s orelse return null;
    const v = std.fmt.parseFloat(f32, w) catch return null;
    return if (std.math.isFinite(v) and @abs(v) < 1e9) v else null;
}

/// anim.motion_paths [start end] | clear
pub fn opPaths() void {
    n_paths = 0;
    version +%= 1;
    app.dirty = true;
    var it = std.mem.tokenizeAny(u8, ops.arg, " \"");
    const w0 = it.next();
    if (w0 != null and std.mem.eql(u8, w0.?, "clear")) return;
    var n: usize = 0;
    if (bones_selected) |f| n = f(&who);
    if (n == 0) {
        for (scene.objects[0..scene.count]) |*o| {
            if (!o.selected or n >= MP_MAX) continue;
            who[n] = .{ o.oid, -1 };
            n += 1;
        }
    }
    if (n == 0) return app.log("  select objects (or, in pose mode, bones) to show their paths", .{});
    var a = frange.r.start;
    var b = frange.r.end;
    if (num(w0)) |x| {
        a = @intFromFloat(x);
        if (num(it.next())) |y| b = @intFromFloat(y);
    }
    f0 = a;
    n_frames = @intCast(std.math.clamp(@as(i64, b) - a + 1, 2, MP_MAXF));
    n_paths = n;
    const back = anim.frame;
    for (0..n_frames) |k| {
        const f: f32 = @floatFromInt(@as(i64, f0) + @as(i64, @intCast(k)));
        anim.apply(f);
        for (0..n) |p| {
            const q = p * MP_MAXF + k;
            pts[q] = point(p);
            const bone = who[p][1];
            has_key[q] = haskey(if (bone >= 0) anim.K_BONE else anim.K_OBJ, @intCast(who[p][0]), bone, f);
        }
    }
    anim.apply(back);
    app.log("  motion paths: {d} over frames {d}-{d}", .{ n, f0, @as(i64, f0) + @as(i64, @intCast(n_frames)) - 1 });
}

/// anim.onion [before after step] | off
pub fn opOnion() void {
    var it = std.mem.tokenizeAny(u8, ops.arg, " \"");
    const w0 = it.next();
    app.dirty = true;
    version +%= 1;
    if (w0 != null and std.mem.eql(u8, w0.?, "off")) {
        on_on = false;
        freeGhosts();
        return app.log("  onion skins off", .{});
    }
    const half = ON_MAX / 2;
    if (num(w0)) |b| {
        const c: i32 = @intFromFloat(std.math.clamp(b, 0, half));
        on_before = c;
        on_after = c;
        if (num(it.next())) |x| {
            on_after = @intFromFloat(std.math.clamp(x, 0, half));
            if (num(it.next())) |s| on_step = @max(@as(i32, @intFromFloat(s)), 1);
        }
    }
    on_on = true;
    on_oid = 0;
    app.log("  onion skins: {d} {d} {d}", .{ on_before, on_after, on_step });
}

/// Once a drawn frame: the ghosts made again when something they show changed.
pub fn frameBegin() void {
    if (!on_on or making) return;
    const i = scene.active orelse {
        if (on_n > 0 or on_oid != 0) freeGhosts();
        return;
    };
    const o = &scene.objects[i];
    if (o.mesh == null) {
        if (on_n > 0 or on_oid != 0) freeGhosts();
        return;
    }
    if (o.oid == on_oid and frame_same() and anim.cur == on_anim) return;
    freeGhosts();
    on_oid = o.oid;
    on_frame = anim.frame;
    on_anim = anim.cur;
    version +%= 1;
    making = true;
    defer making = false;
    const here = anim.frame;
    const was_dirty = app.dirty;
    var k: i32 = -on_before;
    while (k <= on_after) : (k += 1) {
        if (k == 0) continue;
        if (on_n >= ON_MAX) break;
        anim.apply(here + @as(f32, @floatFromInt(k *| on_step)));
        const me = mods.of(i) orelse continue;
        const v = A.dupe(m.V3, me.verts) catch continue;
        const e = A.dupe([2]u32, me.edge_list) catch {
            A.free(v);
            continue;
        };
        ghosts[on_n] = .{ .verts = v, .edges = e, .mat = scene.world(i), .off = k };
        on_n += 1;
    }
    anim.apply(here);
    app.dirty = was_dirty;
}

fn frame_same() bool {
    return std.mem.eql(u8, std.mem.asBytes(&on_frame), std.mem.asBytes(&anim.frame));
}

/// In the viewport: the ghosts, the paths.
pub fn draw(cv: *gfx.Canvas, c: *const vp.Cam) void {
    for (ghosts[0..on_n]) |*g| {
        var col = if (g.off > 0) COL_GHOST_A else COL_GHOST_B;
        if (@abs(g.off) != 1) col = (col >> 1) & 0x7f7f7f;
        const step = g.edges.len / 20000 + 1;
        var e: usize = 0;
        while (e < g.edges.len) : (e += step) {
            const p = m.xform(g.mat, g.verts[g.edges[e][0]]);
            const q = m.xform(g.mat, g.verts[g.edges[e][1]]);
            vp.line3(cv, c, p, q, col);
        }
    }
    for (0..n_paths) |p| {
        const ps = pts[p * MP_MAXF..][0..n_frames];
        const ks = has_key[p * MP_MAXF..][0..n_frames];
        for (0..n_frames - 1) |k| vp.line3(cv, c, ps[k], ps[k + 1], COL_PATH);
        for (ps, ks, 0..) |pt, kd, k| {
            const s = c.project(pt) orelse continue;
            var col = COL_PATH;
            var r: i32 = 3;
            if (kd) {
                col = COL_PATH_KEY;
                r = 6;
            }
            if (@as(f32, @floatFromInt(@as(i64, f0) + @as(i64, @intCast(k)))) == anim.frame) {
                col = 0xffffff;
                r = 7;
            }
            cv.fill(.{ .x = s[0] - @divTrunc(r, 2), .y = s[1] - @divTrunc(r, 2), .w = r, .h = r }, col);
        }
    }
}

/// What the tests read: how many ghosts and points there are, a path's point.
pub fn pathPoint(p: usize, k: usize) ?m.V3 {
    if (p >= n_paths or k >= n_frames) return null;
    return pts[p * MP_MAXF + k];
}
