// BeeScript's landscape builtins (script.s b_landscape, b_shinfo, b_height):
// a landscape's numbers (la_info), its height under a world point
// (la_wheight) and the last shatter's numbers (sh_info, kept as doubles).
const bs = @import("bscript.zig");
const bsc = @import("bs_scene.zig");
const land = @import("landscape.zig");

const V = bs.Value;
const Err = bs.Err;

pub const builtins = [_]bs.Builtin{
    .{ .name = "landscape", .f = landscape },
    .{ .name = "shinfo", .f = shinfo },
    .{ .name = "height", .f = height },
};

/// landscape(name, k): 0 samples a side, 1 size, 2 layers, 3 lowest, 4 highest,
/// 5 display samples a side, 6 the last evaluation (ms), 7 paint layers, 8
/// version; nil: not a landscape
fn landscape(a: []const V) Err!V {
    const i = try bsc.argObj(a[0]);
    const k = bs.ci32(try bs.argNum(a[1]));
    const v = land.info(i, k) orelse return bs.nil;
    return bs.num(v);
}

/// shinfo(k): the last shatter's numbers (a double each)
fn shinfo(a: []const V) Err!V {
    const st = &@import("shatterop.zig").stat;
    const k: u32 = @bitCast(bs.ci32(try bs.argNum(a[0])));
    return bs.num(if (k < st.len) st[k] else 0);
}

/// height(name, x, z): the landscape's height at world x, z; nil: not over it
fn height(a: []const V) Err!V {
    const i = try bsc.argObj(a[0]);
    const x = bs.f32of(try bs.argNum(a[1]));
    const z = bs.f32of(try bs.argNum(a[2]));
    const h = land.wheight(i, x, z) orelse return bs.nil;
    return bs.num(h);
}
