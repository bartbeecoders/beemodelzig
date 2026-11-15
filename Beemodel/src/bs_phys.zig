// BeeScript's physics builtins (script.s b_rbinfo, b_field .. b_cainfo): the
// rigid body simulation's counts and settings, force fields (made, sampled,
// counted), particle systems, shattering, mechanism joints, cloth and the
// simulation cache. Each reads the subsystem's port (rbody, fields,
// particles, shatterop, mech, cloth, simcache) as the original's reads its
// assembly; numbers go through the VM's formatting as the original's do.
// Arguments are read in the original's order (so the same bad one errs first).
const std = @import("std");
const bs = @import("bscript.zig");
const bsc = @import("bs_scene.zig");
const scene = @import("scene.zig");
const ops = @import("ops.zig");
const anim = @import("anim.zig");
const app = @import("app.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "rbinfo", .f = rbinfo },
    .{ .name = "field", .f = field },
    .{ .name = "force", .f = force },
    .{ .name = "fieldinfo", .f = fieldinfo },
    .{ .name = "emit", .f = emit },
    .{ .name = "particles", .f = particles },
    .{ .name = "shatter", .f = shatter },
    .{ .name = "rigid", .f = rigid },
    .{ .name = "joint", .f = joint },
    .{ .name = "collisions", .f = collisions },
    .{ .name = "clothinfo", .f = clothinfo },
    .{ .name = "cacheinfo", .f = cacheinfo },
};

/// cvttsd2si r32 of a number argument, as the unsigned word the callee compares.
fn argU(v: V) Err!u32 {
    return @bitCast(bs.ci32(try bs.argNum(v)));
}

/// rbinfo(k): the simulation's counts (rb_info)
fn rbinfo(a: []const V) Err!V {
    return bs.num(@import("rbody.zig").info(try argU(a[0])));
}

/// clothinfo(k) (cl_info)
fn clothinfo(a: []const V) Err!V {
    return bs.num(@import("cloth.zig").info(bs.ci32(try bs.argNum(a[0]))));
}

/// cacheinfo(k) (sc_info)
fn cacheinfo(a: []const V) Err!V {
    return bs.num(@import("simcache.zig").info(try argU(a[0])));
}

/// fieldinfo(k) (fl_info)
fn fieldinfo(a: []const V) Err!V {
    return bs.num(@import("fields.zig").info(try argU(a[0])));
}

/// particles(k [, i]) (pt_info)
fn particles(a: []const V) Err!V {
    const k = bs.ci32(try bs.argNum(a[0]));
    var i: i32 = 0;
    if (a.len >= 2) i = bs.ci32(try bs.argNum(a[1]));
    return bs.num(@import("particles.zig").info(k, i));
}

/// collisions(): pairs of a mechanism's parts colliding now (mech_hits)
fn collisions(_: []const V) Err!V {
    return bs.num(@floatFromInt(@import("mech.zig").hits));
}

/// fl_ops: the operator each of fl_kwtypes' words runs.
const fl_ops = [_][]const u8{
    "field.add_attractor", "field.add_zone",    "field.add_wind",      "field.add_vortex", "field.add_turbulence",
    "field.add_drag",      "field.add_planet",  "field.add_blackhole", "field.add_tornado", "field.add_breeze",
};

/// field(type [, name [, settings]]) -> the new force field's name; nil: no such type
fn field(a: []const V) Err!V {
    const t = @import("fields.zig").typeOf(try bs.argStr(a[0]));
    if (t < 0) return bs.nil;
    var set: []const u8 = "";
    if (a.len >= 3) set = try bs.argStr(a[2]);
    if (ops.byId(fl_ops[@intCast(t)])) |oi| {
        if (!ops.implemented(oi)) return bs.fail(bs.e_not_ported, fl_ops[@intCast(t)]);
        bsc.runOp(oi, set);
    }
    if (a.len >= 2) {
        const nm = try bs.argStr(a[1]);
        if (scene.active) |i| {
            bsc.objRename(i, nm);
            app.dirty = true;
        }
    }
    const i = scene.active orelse return bs.nil; // (the original's ret_name of no object would crash)
    return bsc.retName(i);
}

/// force(x, y, z [, axis]): the fields' and gravity's pull at a point (fl_sample):
/// its size, or one axis ("x".."z" or 0-2)
fn force(a: []const V) Err!V {
    var p: [3]f32 = undefined;
    for (0..3) |k| p[k] = bs.f32of(try bs.argNum(a[k]));
    const g = @import("fields.zig").sample(p);
    if (a.len >= 4) {
        const ax: u32 = if (a[3].t == .str)
            @as(u32, (try bs.argStr(a[3])).ptr[0]) -% 'x'
        else
            try argU(a[3]);
        if (ax <= 2) return bs.num(g[ax]);
    }
    var s = g[0] * g[0];
    s = g[1] * g[1] + s;
    s = g[2] * g[2] + s;
    const r: f32 = @sqrt(s); // (sqrtss: bs.num's f64 would make @sqrt a double's)
    return bs.num(r);
}

/// emit(object [, preset or settings [, settings]]) -> the new system's number; nil: no room
fn emit(a: []const V) Err!V {
    const pt = @import("particles.zig");
    const i = try bsc.argObj(a[0]);
    var text: []const u8 = "";
    if (a.len >= 2) text = try bs.argStr(a[1]);
    const n = pt.add(i, text);
    if (n != 0 and a.len >= 3) {
        const more = try bs.argStr(a[2]);
        if (pt.nthOwn(scene.objects[i].uid, n - 1)) |r| _ = pt.parse(r, more);
    }
    if (n == 0) return bs.nil;
    return bs.num(@floatFromInt(n));
}

/// shatter(name, pattern, count [, options]) -> the pieces made (object.shatter's
/// argument "<pattern> count <n> <options>", in a 126-byte buffer as fmt_*)
fn shatter(a: []const V) Err!V {
    const i = try bsc.argObj(a[0]);
    scene.active = i;
    var f = Fmt{};
    f.str(try bs.argStr(a[1]));
    f.str(" count ");
    f.int(bs.ci32(try bs.argNum(a[2])));
    if (a.len >= 4) {
        f.char(' ');
        f.str(try bs.argStr(a[3]));
    }
    const oi = ops.byId("object.shatter") orelse return bs.nil;
    if (!ops.implemented(oi)) return bs.fail(bs.e_not_ported, "object.shatter");
    bsc.runOp(oi, f.buf[0..f.n]);
    return bs.num(@import("shatterop.zig").stat[0]);
}

/// log.s fmt_*: at most 126 characters.
const Fmt = struct {
    buf: [128]u8 = undefined,
    n: usize = 0,
    fn char(f: *Fmt, c: u8) void {
        if (f.n >= 126) return;
        f.buf[f.n] = c;
        f.n += 1;
    }
    fn str(f: *Fmt, s: []const u8) void {
        for (s) |c| {
            if (c == 0) break;
            f.char(c);
        }
    }
    fn int(f: *Fmt, x: i32) void {
        var u: u32 = @bitCast(x);
        if (x < 0) {
            f.char('-');
            u = 0 -% u;
        }
        var d: [10]u8 = undefined;
        var k: usize = 0;
        while (true) {
            d[k] = @intCast('0' + u % 10);
            k += 1;
            u /= 10;
            if (u == 0) break;
        }
        while (k > 0) {
            k -= 1;
            f.char(d[k]);
        }
    }
};

/// rb_get's names: type shape mass friction bounce damping group, x0 y0 z0
const get_names = [_][]const u8{ "type", "shape", "mass", "friction", "bounce", "damping", "group", "x0", "y0", "z0" };

/// rigid(name, prop) -> an object's rigid body setting; nil: not a body
fn rigid(a: []const V) Err!V {
    const rc = @import("rbcore.zig");
    const i = try bsc.argObj(a[0]);
    const oid = scene.objects[i].oid;
    const nm = try bs.argStr(a[1]);
    const b = anim.cur orelse return bs.nil;
    var r: ?[]const u8 = null;
    var k: usize = 0;
    while (k < b.h.nrb and (k + 1) * rc.RB_SZ <= b.rb.len) : (k += 1) {
        const e = b.rb[k * rc.RB_SZ ..][0..rc.RB_SZ];
        if (rc.rdU(e, rc.RB_UID) == oid) {
            r = e;
            break;
        }
    }
    const e = r orelse return bs.nil;
    const w = for (get_names, 0..) |g, q| {
        if (std.mem.eql(u8, g, nm)) break q;
    } else return bs.nil;
    const flags = rc.rdU(e, rc.RB_FLAGS);
    const x: f32 = switch (w) {
        7, 8, 9 => if (flags & 1 == 0) return bs.nil else @bitCast(rc.rdU(e, rc.RB_INIT + (w - 7) * 4)),
        6 => @floatFromInt((flags >> 4) & 15),
        0, 1 => @floatFromInt(@as(i32, @bitCast(rc.rdU(e, rc.RB_TYPE + w * 4)))),
        else => @bitCast(rc.rdU(e, rc.RB_MASS + (w - 2) * 4)),
    };
    return bs.num(x);
}

/// joint(n [, 1]) -> mechanism joint n's value (1..); with a second argument
/// whether a limit holds it; nil: no such joint
fn joint(a: []const V) Err!V {
    const mech = @import("mech.zig");
    const n = bs.ci32(try bs.argNum(a[0]));
    const k: u32 = @bitCast(n -% 1);
    const v = mech.value(k) orelse return bs.nil;
    const lim = mech.limWord(k) orelse return bs.nil;
    const r = lim +% 1; // (mech_value's eax: 0 is "none")
    if (r == 0) return bs.nil;
    if (a.len >= 2) return bs.num(@floatFromInt(@as(i32, @bitCast(lim))));
    return bs.num(v.v);
}

test "shatter's argument: fmt_int's digits and sign, 126 characters at most" {
    var f = Fmt{};
    f.str("shards");
    f.str(" count ");
    f.int(-2147483648);
    try std.testing.expectEqualStrings("shards count -2147483648", f.buf[0..f.n]);
    var g = Fmt{};
    for (0..200) |_| g.char('x');
    try std.testing.expectEqual(@as(usize, 126), g.n);
    var h = Fmt{};
    h.int(0);
    try std.testing.expectEqualStrings("0", h.buf[0..h.n]);
}

test "force's size: sqrtss of a float sum, not a double's" {
    const g = [3]f32{ -10992.649414, -11009.266602, -11025.203125 };
    var s = g[0] * g[0];
    s = g[1] * g[1] + s;
    s = g[2] * g[2] + s;
    const r: f32 = @sqrt(s);
    try std.testing.expectEqual(@as(f64, 19068.23046875), @as(f64, r));
}
