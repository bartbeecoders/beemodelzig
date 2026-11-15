//! What scripts ask of an object's B-rep solid (bfeat.s bf_query, BeeScript's
//! brep(name, what)): "volume", "area", "faces", "edges", "vertices",
//! "loops", "valid", "kernel" (1 when it has one), "triangles", "tessvolume",
//! "watertight", "error", or how many faces are "planes", "cylinders",
//! "cones", "spheres", "tori", "nurbs"; NaN when it has none. The port has no
//! BeeScript yet: the tests read these through --dump-brep (dump below).
const std = @import("std");
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const bt = @import("btess.zig");
const NONE = br.NONE;

/// bf_body: the object's solid (imported STEP parts; feature bodies through step.bodyOf).
pub fn bodyOf(oid: u32) u32 {
    return @import("step.zig").bodyOf(oid);
}
/// bk_err: why the last boolean failed (bbool.zig sets it once it is here).
pub var bk_err: *const fn () i32 = noErr;
fn noErr() i32 {
    return 0;
}

pub const kinds = [_][]const u8{ "volume", "area", "faces", "edges", "vertices", "loops", "valid", "kernel", "error", "triangles", "tessvolume", "watertight", "planes", "cylinders", "cones", "spheres", "tori", "nurbs" };

/// bf_query(object uid, what) -> the value (NaN: no solid)
pub fn query(oid: u32, what: []const u8) f64 {
    const b = bodyOf(oid);
    const eq = std.mem.eql;
    if (eq(u8, what, "error")) return @floatFromInt(bk_err());
    if (eq(u8, what, "kernel")) return if (b == NONE) 0 else 1;
    const nan = std.math.nan(f64);
    if (b == NONE) return nan;
    if (eq(u8, what, "volume")) return br.bdVolume(b);
    if (eq(u8, what, "area")) return br.bdArea(b);
    if (eq(u8, what, "valid")) return if (br.bdCheck(b) == 0) 1 else 0;
    br.bdStats(b); // counts
    if (eq(u8, what, "faces")) return @floatFromInt(br.bs_f);
    if (eq(u8, what, "edges")) return @floatFromInt(br.bs_e);
    if (eq(u8, what, "vertices")) return @floatFromInt(br.bs_v);
    if (eq(u8, what, "loops")) return @floatFromInt(br.bs_l);
    if (eq(u8, what, "triangles")) {
        const t: ?*bt.Tess = @ptrCast(@alignCast(br.bd(b).tri));
        return if (t) |x| @floatFromInt(x.nt) else 0;
    }
    if (eq(u8, what, "tessvolume")) return tessVolume(b);
    if (eq(u8, what, "watertight")) return if (tessTight(b)) 1 else 0;
    const names = [_][]const u8{ "planes", "cylinders", "cones", "spheres", "tori", "nurbs" };
    for (names, 0..) |n, k| {
        if (!eq(u8, what, n)) continue;
        const want: u32 = @intCast(k + nb.ST_PLANE);
        var c: u32 = 0;
        var f = br.bd(b).first;
        const end = f + br.bd(b).nf;
        while (f < end) : (f += 1) {
            if (nb.sf(br.fc(f).surf).typ == want) c += 1;
        }
        return @floatFromInt(c);
    }
    return nan;
}

/// tess_volume: the volume its triangles enclose
fn tessVolume(b: u32) f64 {
    var sum: f64 = 0;
    const t: *bt.Tess = @ptrCast(@alignCast(br.bd(b).tri orelse return 0));
    var i: u32 = 0;
    while (i < t.nt) : (i += 1) {
        const a = t.pv + t.pt[i * 3] * 3;
        const p = t.pv + t.pt[i * 3 + 1] * 3;
        const c = t.pv + t.pt[i * 3 + 2] * 3;
        // a . (b x c) / 6
        var x = p[1] * c[2] - p[2] * c[1];
        x = x * a[0];
        var y = p[2] * c[0] - p[0] * c[2];
        y = y * a[1];
        x = x + y;
        var z = p[0] * c[1] - p[1] * c[0];
        z = z * a[2];
        x = x + z;
        sum = sum + x;
    }
    return sum / 6.0;
}

/// tess_tight: every edge of its triangles is used exactly twice, once each way
fn tessTight(b: u32) bool {
    const t: *bt.Tess = @ptrCast(@alignCast(br.bd(b).tri orelse return false));
    const want = t.nt * 3 * 4;
    var cap: u32 = 64;
    while (cap < want) cap <<= 1;
    const mem: [*][2]u64 = @ptrCast(nb.data(@as(usize, cap) * 16) orelse return false);
    @memset(@as([*]u64, @ptrCast(mem))[0 .. @as(usize, cap) * 2], 0xffffffffffffffff);
    var i: u32 = 0;
    while (i < t.nt) : (i += 1) {
        for (0..3) |k| {
            const key = ttKey(t, i, @intCast(k));
            const s = slot(mem, cap, key);
            if (s[0] != 0xffffffffffffffff) return false; // (the same way twice)
            s[0] = key;
        }
    }
    i = 0;
    while (i < t.nt) : (i += 1) {
        for (0..3) |k| {
            const key = std.math.rotl(u64, ttKey(t, i, @intCast(k)), 32);
            if (slot(mem, cap, key)[0] != key) return false;
        }
    }
    return true;
}
fn ttKey(t: *const bt.Tess, i: u32, k: u32) u64 {
    const a = t.pt[i * 3 + k];
    const b = t.pt[i * 3 + (if (k + 1 < 3) k + 1 else 0)];
    return (@as(u64, a) << 32) | b;
}
fn slot(mem: [*][2]u64, cap: u32, key: u64) *[2]u64 {
    var i: u32 = @truncate((key *% 0x9e3779b97f4a7c15) >> 32);
    i &= cap - 1;
    while (true) {
        const s = &mem[i];
        if (s[0] == 0xffffffffffffffff or s[0] == key) return s;
        i = (i + 1) & (cap - 1);
    }
}

/// --dump-brep OUT;NAME: every query of the object's solid, one per line
/// ("what value", %.17g; NaN: nil), for the tests.
pub fn dump(arg: []const u8) void {
    const scene = @import("scene.zig");
    var it = std.mem.splitScalar(u8, arg, ';');
    const out = it.next() orelse return;
    const name = it.next() orelse return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    const A = std.heap.page_allocator;
    const oi = scene.find(name);
    for (kinds) |k| {
        const v = if (oi) |i| query(scene.objects[i].oid, k) else std.math.nan(f64);
        var b: [96]u8 = undefined;
        const s = if (std.math.isNan(v)) std.fmt.bufPrint(&b, "{s} nil\n", .{k}) catch continue else std.fmt.bufPrint(&b, "{s} {e}\n", .{ k, v }) catch continue;
        buf.appendSlice(A, s) catch return;
    }
    @import("bee.zig").writeAtomic(out, buf.items) catch {};
}
