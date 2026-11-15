// What the headless tests read of the animation: every scenario asserts the
// effect, not that nothing crashed (main.zig: --dump-chan, --dump-verts, --expect-anim).
const std = @import("std");
const linux = std.os.linux;
const anim = @import("anim.zig");
const scene = @import("scene.zig");
const mods = @import("mods.zig");
const motion = @import("motion.zig");
const aops = @import("animops.zig");
const undo = @import("undo.zig");
const shape = @import("shape.zig");
const arm = @import("arm.zig");
const armedit = @import("armedit.zig");

fn out(path: []const u8) ?i32 {
    var b: [512]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&b, "{s}", .{path}, 0) catch return null;
    const rc = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn put(fd: i32, s: []const u8) void {
    _ = linux.write(fd, s.ptr, s.len);
}

pub fn dumpChannels(spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ';');
    const fd = out(it.next() orelse return) orelse return;
    defer _ = linux.close(fd);
    const a = std.fmt.parseFloat(f32, it.next() orelse return) catch return;
    const e = std.fmt.parseFloat(f32, it.next() orelse return) catch return;
    const st = std.fmt.parseFloat(f32, it.next() orelse return) catch return;
    const rest = it.rest();
    var f = a;
    var b: [64]u8 = undefined;
    while (f <= e) : (f += st) {
        anim.apply(f);
        put(fd, std.fmt.bufPrint(&b, "{d}", .{f}) catch "");
        var p = std.mem.splitScalar(u8, rest, ';');
        while (p.next()) |path| {
            if (anim.pathValue(path)) |v| {
                put(fd, std.fmt.bufPrint(&b, " {x}", .{v}) catch "");
            } else put(fd, " nil");
        }
        put(fd, "\n");
    }
}

pub fn dumpVerts(spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ';');
    const fd = out(it.next() orelse return) orelse return;
    defer _ = linux.close(fd);
    const i = scene.find(it.next() orelse return) orelse return;
    const me = mods.of(i) orelse return;
    var b: [96]u8 = undefined;
    for (me.verts) |v| put(fd, std.fmt.bufPrint(&b, "{x} {x} {x}\n", .{ v[0], v[1], v[2] }) catch "");
}

/// --dump-rig OUT;ARMATURE: each bone's pose matrix (IK too), a line.
pub fn dumpRig(spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ';');
    const fd = out(it.next() orelse return) orelse return;
    defer _ = linux.close(fd);
    const i = scene.find(it.next() orelse return) orelse return;
    const b = arm.of(i) orelse return;
    arm.poseMats(b, i);
    var t: [64]u8 = undefined;
    for (0..b.n) |k| {
        put(fd, b.bones[k].nameOf());
        for (arm.am_m[k]) |x| put(fd, std.fmt.bufPrint(&t, " {x}", .{x}) catch "");
        put(fd, "\n");
    }
}

/// --dump-paths OUT: the motion paths' points, a line a frame.
pub fn dumpPaths(spec: []const u8) void {
    const fd = out(spec) orelse return;
    defer _ = linux.close(fd);
    var t: [96]u8 = undefined;
    for (0..motion.n_paths) |p| {
        for (motion.points(p)) |v| put(fd, std.fmt.bufPrint(&t, "{x} {x} {x}\n", .{ v[0], v[1], v[2] }) catch "");
    }
}

/// --select NAME: it alone, active (select() in a script).
pub fn selectObject(name: []const u8) void {
    // "A,B,C": exactly these, the last one active (as BeeScript's select(a, b, c))
    if (std.mem.indexOfScalar(u8, name, ',') != null and scene.find(name) == null) {
        scene.deselectAll();
        var it = std.mem.splitScalar(u8, name, ',');
        while (it.next()) |nm| {
            const i = scene.find(nm) orelse continue;
            scene.objects[i].selected = true;
            scene.active = i;
        }
        return;
    }
    if (scene.find(name)) |i| scene.selectOnly(i);
}

fn value(what: []const u8) ?f64 {
    const b = anim.cur;
    if (std.mem.eql(u8, what, "curves")) return if (b) |x| x.h.ncur else 0;
    if (std.mem.eql(u8, what, "keys")) return if (b) |x| x.h.nkey else 0;
    if (std.mem.eql(u8, what, "actions")) return if (b) |x| x.h.nact else 0;
    if (std.mem.eql(u8, what, "layers")) return if (b) |x| x.h.nlay else 0;
    if (std.mem.eql(u8, what, "drivers")) return if (b) |x| x.h.ndrv else 0;
    if (std.mem.eql(u8, what, "selected")) return @floatFromInt(aops.selCount());
    if (std.mem.eql(u8, what, "frame")) return anim.frame;
    if (std.mem.eql(u8, what, "playing")) return @intFromBool(anim.playing);
    if (std.mem.eql(u8, what, "autokey")) return @intFromBool(anim.autokey);
    if (std.mem.eql(u8, what, "paths")) return @floatFromInt(motion.n_paths);
    if (std.mem.eql(u8, what, "ghosts")) return @floatFromInt(motion.on_n);
    if (std.mem.eql(u8, what, "live_samples")) return @floatFromInt(@import("live.zig").samples());
    if (std.mem.eql(u8, what, "undo")) return @floatFromInt(undo.current());
    if (std.mem.eql(u8, what, "meshes")) return @floatFromInt(scene.meshes_made);
    if (std.mem.eql(u8, what, "arm_mode")) return armedit.mode;
    if (std.mem.eql(u8, what, "skin_parallel")) return @intFromBool(@popCount(arm.skin_threads.load(.monotonic)) > 1);
    if (std.mem.eql(u8, what, "constraints")) return if (b) |x| x.h.ncon else 0;
    // mechanisms (mech.zig): joints, colliding pairs (collisions()), joint:N's value
    if (std.mem.eql(u8, what, "joints")) return @floatFromInt(@import("mech.zig").count());
    if (std.mem.eql(u8, what, "collisions")) return @floatFromInt(@import("mech.zig").hits);
    if (std.mem.startsWith(u8, what, "joint:")) {
        const n = std.fmt.parseInt(usize, what[6..], 10) catch return null;
        if (n == 0) return null;
        return if (@import("mech.zig").value(n - 1)) |v| v.v else null;
    }
    // rigid bodies (rbody.zig): rbinfo:N, cacheinfo:N as the original's BeeScript
    if (std.mem.startsWith(u8, what, "rbinfo:")) {
        const n = std.fmt.parseInt(u32, what[7..], 10) catch return null;
        return @import("rbody.zig").info(n);
    }
    if (std.mem.startsWith(u8, what, "evsum:")) {
        // every vertex the object shows, exactly: each coordinate as m / 2^e (m
        // whole, e the least), h = (h 31 + m + e) mod 1000000007 in doubles (the
        // tests' BeeScript computes the same from evpos)
        const i = scene.find(what[6..]) orelse return -1; // (no such object: -1)
        const me = mods.of(i) orelse return null;
        var h: f64 = 0;
        for (me.verts) |v| {
            for (v) |c| {
                var m: f64 = c;
                var e: f64 = 0;
                while (@floor(m) != m and e < 200) {
                    m = m * 2;
                    e += 1;
                }
                h = h * 31 + m + e;
                h = h - @floor(h / 1000000007.0) * 1000000007.0;
            }
        }
        return h;
    }
    if (std.mem.startsWith(u8, what, "clothinfo:")) {
        const n = std.fmt.parseInt(i32, what[10..], 10) catch return null;
        return @import("cloth.zig").info(n);
    }
    if (std.mem.startsWith(u8, what, "particles:")) {
        // particles:k[:i] as the original's BeeScript particles(k, i)
        var it = std.mem.splitScalar(u8, what[10..], ':');
        const k = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
        const i = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch return null;
        return @import("particles.zig").info(k, i);
    }
    if (std.mem.startsWith(u8, what, "cacheinfo:")) {
        const n = std.fmt.parseInt(u32, what[10..], 10) catch return null;
        return @import("simcache.zig").info(n);
    }
    if (std.mem.startsWith(u8, what, "bones:")) {
        const i = scene.find(what[6..]) orelse return null;
        return if (arm.of(i)) |x| x.n else null;
    }
    if (std.mem.startsWith(u8, what, "bonesel:")) {
        const i = scene.find(what[8..]) orelse return null;
        const x = arm.of(i) orelse return null;
        var n: f64 = 0;
        for (x.bones[0..x.n]) |*q| n += @as(f64, @floatFromInt(@intFromBool(q.sel != 0)));
        return n;
    }
    if (std.mem.startsWith(u8, what, "weights:")) {
        const i = scene.find(what[8..]) orelse return null;
        return if (scene.meshOfObj(i)) |me| @floatFromInt(me.wgt.len) else null;
    }
    if (std.mem.startsWith(u8, what, "shapes:")) {
        const i = scene.find(what[7..]) orelse return null;
        return shape.count(i);
    }
    if (std.mem.startsWith(u8, what, "int:")) {
        // int:path:frame's interpolation
        const c = std.mem.lastIndexOfScalar(u8, what, ':') orelse return null;
        const f = std.fmt.parseFloat(f32, what[c + 1..]) catch return null;
        const ch = anim.parsePath(what[4..c]) orelse return null;
        const ci = anim.find(ch, 0) orelse return null;
        const x = b.?;
        for (x.keysOf(&x.h.cur[ci])) |*k| {
            if (@abs(k.f - f) < 1e-3) return @floatFromInt(k.int);
        }
        return null;
    }
    // handle:path:frame (the right handle's frames), handleL, handleLy, ht, value
    const fields = [_][]const u8{ "handle:", "handleL:", "handleLy:", "ht:", "value:" };
    for (fields, 0..) |w, q| {
        if (!std.mem.startsWith(u8, what, w)) continue;
        const c = std.mem.lastIndexOfScalar(u8, what, ':') orelse return null;
        const f = std.fmt.parseFloat(f32, what[c + 1..]) catch return null;
        const ch = anim.parsePath(what[w.len..c]) orelse return null;
        const ci = anim.find(ch, 0) orelse return null;
        const x = b.?;
        for (x.keysOf(&x.h.cur[ci])) |*k| {
            if (@abs(k.f - f) < 1e-3) return switch (q) {
                0 => k.hrx,
                1 => k.hlx,
                2 => k.hly,
                3 => @floatFromInt(k.ht),
                else => k.v,
            };
        }
        return null;
    }
    if (anim.pathValue(what)) |v| return v;
    return null;
}

/// --print-anim WHAT: on stderr, WHAT=VALUE (a value to compare between two moments).
pub fn print(what: []const u8) void {
    std.debug.print("{s}={?d}\n", .{ what, value(what) });
}

/// WHAT=VALUE (to 0.001), "WHAT=nil" when it must not be there.
pub fn expect(spec: []const u8) bool {
    const eq = std.mem.lastIndexOfScalar(u8, spec, '=') orelse return false;
    const got = value(spec[0..eq]);
    const want = spec[eq + 1..];
    var ok = false;
    if (std.mem.eql(u8, want, "nil")) ok = got == null else if (got) |g| {
        const w = std.fmt.parseFloat(f64, want) catch return false;
        ok = @abs(g - w) < 1e-3;
    }
    if (!ok) std.debug.print("beemodel --shot: expected {s}, it is {?d}\n", .{ spec, got });
    return ok;
}
