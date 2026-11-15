// Weight paint (vcol.s: wp_*, arm.s: arm_paint_bone): vertex paint's mode with the
// brush working on the skin weights of the armature's active bone. The bone takes its
// slot in the vertex's four, a free one, else the lightest one's. The painted object
// shows the weights as heat (blue 0 .. red 1) in the solid viewport.
const std = @import("std");
const scene = @import("scene.zig");
const arm = @import("arm.zig");
const stroke = @import("stroke.zig");
const A = @import("alloc.zig").A;
const Mesh = scene.Mesh;

/// The weight the brush paints towards.
pub var value: f32 = 1;
/// The bone a stroke paints (-1: none).
pub var bone: i32 = -1;

/// arm_paint_bone: its armature's active one; -1: it has no armature.
pub fn paintBone(oi: usize) i32 {
    const b = blockOf(oi) orelse return -1;
    return @intCast(b.act);
}

/// The bones of the armature its first Armature modifier names.
pub fn blockOf(oi: usize) ?*arm.Block {
    const t = @import("armedit.zig").modTarget(oi) orelse return null;
    return arm.of(t);
}

/// mesh_wgt_alloc: its weights, made with no bones when it has none.
pub fn alloc(me: *Mesh) bool {
    if (me.wgt.len == me.verts.len and me.wgt.len != 0) return true;
    if (me.wgt.len != 0) A.free(me.wgt);
    me.wgt = A.alloc(arm.Wgt, me.verts.len) catch {
        me.wgt = &.{};
        return false;
    };
    @memset(me.wgt, .{ .bone = .{ 0xff, 0xff, 0xff, 0xff }, .w = .{ 0, 0, 0, 0 } });
    return true;
}

/// wp_blend: the stroke's bone's weight towards the value.
pub inline fn blend(g: *arm.Wgt, amount: f32) void {
    const b: i32 = bone;
    var s: usize = 4;
    for (g.bone, 0..) |x, k| {
        if (@as(i32, x) == b) {
            s = k;
            break;
        }
    }
    if (s == 4) {
        // a free slot, else the lightest
        for (g.bone, 0..) |x, k| {
            if (x == 0xff) {
                s = k;
                break;
            }
        }
        if (s == 4) {
            s = 0;
            var low = g.w[0];
            for (1..4) |k| {
                if (low > g.w[k]) {
                    low = g.w[k];
                    s = k;
                }
            }
        }
        g.bone[s] = @truncate(@as(u32, @bitCast(b)));
        g.w[s] = 0;
    }
    g.w[s] = (value - g.w[s]) * amount + g.w[s];
}

/// wp_tint: the corners' weights for the bone, averaged, as a heat colour.
pub fn tint(wgt: []const arm.Wgt, me: *const Mesh, ti: usize) u32 {
    var w: f32 = 0;
    if (wgt.len == me.verts.len and wgt.len != 0) {
        for (me.tris[ti]) |v| {
            const g = &wgt[v];
            for (g.bone, 0..) |x, k| {
                if (@as(i32, x) == bone) w = g.w[k] + w;
            }
        }
        w = w * 0.33333334;
    }
    return jet(w);
}

/// Each channel 1.5 - |4w - c|.
pub fn jet(w: f32) u32 {
    var out: u32 = 0;
    for ([3]f32{ 3, 2, 1 }) |c| {
        var x = 1.5 - @abs(w * 4.0 - c);
        x = stroke.maxss(x, 0);
        x = stroke.minss(x, 1);
        out = out << 8 | @as(u32, @bitCast(stroke.trunc32(x * 255.0)));
    }
    return out;
}

const t_ = std.testing;

test "the heat" {
    try t_.expectEqual(@as(u32, 0x00007f), jet(0));
    try t_.expectEqual(@as(u32, 0x7fff7f), jet(0.5));
    try t_.expectEqual(@as(u32, 0x7f0000), jet(1));
}

test "the bone takes its slot, a free one, else the lightest" {
    value = 1;
    bone = 3;
    defer bone = -1;
    var g = arm.Wgt{ .bone = .{ 1, 0xff, 0xff, 0xff }, .w = .{ 0.5, 0, 0, 0 } };
    blend(&g, 0.5);
    try t_.expectEqual([4]u8{ 1, 3, 0xff, 0xff }, g.bone);
    try t_.expectEqual(@as(f32, 0.5), g.w[1]);
    blend(&g, 0.5);
    try t_.expectEqual(@as(f32, 0.75), g.w[1]);
    var h = arm.Wgt{ .bone = .{ 1, 2, 4, 5 }, .w = .{ 0.4, 0.1, 0.3, 0.2 } };
    blend(&h, 1);
    try t_.expectEqual([4]u8{ 1, 3, 4, 5 }, h.bone);
    try t_.expectEqual(@as(f32, 1), h.w[1]);
}
