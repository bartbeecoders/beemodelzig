// BeeScript's play mode and logic builtins (script.s b_playstep .. b_logicvar):
// play on for a time with keys held (pl_script_step), where the player looks,
// play mode's numbers (pl_stat), a key as from the keyboard (play_key), and
// the logic graphs' numbers and variables (lg_stat, lg_var).
const bs = @import("bscript.zig");
const bsc = @import("bs_scene.zig");
const scene = @import("scene.zig");
const play = @import("play.zig");
const logic = @import("logic.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "playstep", .f = playstep },
    .{ .name = "playlook", .f = playlook },
    .{ .name = "playinfo", .f = playinfo },
    .{ .name = "playkey", .f = playkey },
    .{ .name = "logic", .f = logicStat },
    .{ .name = "logicvar", .f = logicvar },
};

/// cvttss2si: toward zero; NaN or out of range: the minimum.
fn cvtt(x: f32) i32 {
    if (!(x > -2147483904.0 and x < 2147483648.0)) return @import("std").math.minInt(i32);
    return @intFromFloat(x);
}

/// playstep(seconds [, forward, right, up, run]): play mode goes on for that
/// time (fixed steps) with those keys held
fn playstep(a: []const V) Err!V {
    var k: [4]f32 = @splat(0); // forward right up run (read first, as the original)
    for (1..a.len) |j| k[j - 1] = bs.f32of(try bs.argNum(a[j]));
    const s = bs.f32of(try bs.argNum(a[0]));
    play.scriptStep(s, k[0], k[1], k[2], cvtt(k[3]) != 0);
    return bs.nil;
}

/// playlook(yaw, pitch): where the player looks (degrees)
fn playlook(a: []const V) Err!V {
    const y = bs.f32of(try bs.argNum(a[0]));
    const p = bs.f32of(try bs.argNum(a[1]));
    play.scriptLook(y, p);
    return bs.nil;
}

/// playinfo(k) (pl_stat)
fn playinfo(a: []const V) Err!V {
    return bs.num(play.stat(@bitCast(bs.ci32(try bs.argNum(a[0])))));
}

/// playkey(code, down): a key (evdev code) down (1) or up (0) in play mode
fn playkey(a: []const V) Err!V {
    const code = bs.ci32(try bs.argNum(a[0]));
    const down = bs.ci32(try bs.argNum(a[1]));
    _ = play.key(@bitCast(code), down != 0);
    return bs.nil;
}

/// logic(k) (lg_stat)
fn logicStat(a: []const V) Err!V {
    return bs.num(logic.stat(@bitCast(bs.ci32(try bs.argNum(a[0])))));
}

/// logicvar(object, k [, component]) -> variable k (0..7) of the object's logic
/// graph (x, or component 0..2); nil when none runs on it
fn logicvar(a: []const V) Err!V {
    const k = bs.ci32(try bs.argNum(a[1]));
    var c: i32 = 0;
    if (a.len >= 3) c = bs.ci32(try bs.argNum(a[2]));
    const i = try bsc.argObj(a[0]);
    const v = logic.variable(scene.objects[i].oid, @bitCast(k), @bitCast(c)) orelse return bs.nil;
    return bs.num(v);
}

test "cvttss2si: toward zero, NaN and out of range the minimum" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 0), cvtt(0.5));
    try std.testing.expectEqual(@as(i32, -1), cvtt(-1.9));
    try std.testing.expectEqual(std.math.minInt(i32), cvtt(std.math.nan(f32)));
    try std.testing.expectEqual(std.math.minInt(i32), cvtt(3.0e9));
}
