// OBJ's materials and the export options, as the original's mtl.s, export.s and
// the OBJ half of formats.s:
//   MTL import: newmtl, Kd, Ke, Ni, d / Tr, Ns, Tf, the PBR extension Pr Pm Pc Pcr;
//     map_Kd alone makes the image the base colour; with more maps (map_Pr, map_Pm,
//     map_Ke, norm / map_Bump / bump, map_d) the material gets a texture set's
//     graph; map_Pr and map_Pm reading the G and B of one file (-imfchan) make a
//     packed ORM map. A material that exists by name is updated.
//   MTL export: every material with its maps as gltf.zig plans them (gltf.s
//     gx_tex_plan: images used directly, else the graph baked at 512 x 512):
//     the image's file, or a PNG beside the MTL (the original's PNG bytes).
//   Options: only the selected objects; Z up instead of Y up; a scale. The file
//     browser sets them for one export; scripts export with the defaults.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const images = @import("images.zig");
const gops = @import("graphops.zig");
const sg = @import("shgraph.zig");
const bee = @import("bee.zig");
const app = @import("app.zig");

const A = std.heap.page_allocator;

// --- options -----------------------------------------------------------------

pub const Options = struct { sel_only: bool = false, zup: bool = false, scale: f32 = 1 };
pub var opts = Options{};

pub fn defaults() void {
    opts = .{};
}

/// A mesh; selected when only the selection goes.
pub fn wants(o: *const scene.Object) bool {
    if (!o.kind.isMesh()) return false;
    return !opts.sel_only or o.selected;
}

/// A world position, scaled and turned Z up when the options say so.
pub fn exported(p0: m.V3) m.V3 {
    const p = m.scale(p0, opts.scale);
    return if (opts.zup) .{ p[0], -p[2], p[1] } else p;
}

// --- text as the original writes it ---------------------------------------------

/// Six decimals: a value rounded to millionths, half to even (wb_float).
pub fn fmtFloat(b: []u8, v: f32) []const u8 {
    const d0: f64 = if (std.math.isFinite(v)) v else 0;
    const x = @abs(d0) * 1e6;
    var r = @floor(x);
    const diff = x - r;
    if (diff > 0.5 or (diff == 0.5 and @mod(r, 2) == 1)) r += 1;
    const q: u64 = @intFromFloat(@min(r, 9.0e18));
    return std.fmt.bufPrint(b, "{s}{d}.{d:0>6}", .{ if (d0 < 0) "-" else "", q / 1000000, q % 1000000 }) catch "0.000000";
}

fn putf(out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    var b: [640]u8 = undefined;
    try out.appendSlice(A, std.fmt.bufPrint(&b, fmt, args) catch return);
}

fn putFloat(out: *std.ArrayList(u8), v: f32) !void {
    var b: [40]u8 = undefined;
    try out.appendSlice(A, fmtFloat(&b, v));
}

fn vec(out: *std.ArrayList(u8), key: []const u8, v: [3]f32, k: f32) !void {
    try out.appendSlice(A, key);
    for (v, 0..) |x, i| {
        if (i > 0) try out.append(A, ' ');
        try putFloat(out, x * k);
    }
    try out.append(A, '\n');
}

fn val(out: *std.ArrayList(u8), key: []const u8, v: f32) !void {
    try out.appendSlice(A, key);
    try putFloat(out, v);
    try out.append(A, '\n');
}

// --- OBJ export --------------------------------------------------------------

/// name.mtl next to it (.obj -> .mtl, else + .mtl).
fn mtlPath(b: []u8, path: []const u8) []const u8 {
    const base = if (std.mem.endsWith(u8, path, ".obj")) path[0 .. path.len - 4] else path;
    return std.fmt.bufPrint(b, "{s}.mtl", .{base}) catch "";
}

fn baseName(p: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |s| p[s + 1 ..] else p;
}

pub fn exportObj(path: []const u8) !usize {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(A);
    var mb: [640]u8 = undefined;
    const mtl_path = mtlPath(&mb, path);
    try out.appendSlice(A, "# BeeModel OBJ export\n");
    if (material.count > 0) try putf(&out, "mtllib {s}\n", .{baseName(mtl_path)});
    var base_v: u64 = 1;
    var base_vt: u64 = 1;
    var n: usize = 0;
    const job = @import("jobui.zig");
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (!wants(o)) continue;
        const me = @import("mods.zig").of(i) orelse continue;
        job.set(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(scene.count)));
        const w = scene.world(i);
        try putf(&out, "o {s}\n", .{o.name()});
        if (material.of(o)) |ma| try putf(&out, "usemtl {s}\n", .{ma.nameOf()});
        for (me.verts, 0..) |v, vi| {
            const p = exported(m.xform(w, v));
            try out.appendSlice(A, "v ");
            try putFloat(&out, p[0]);
            try out.append(A, ' ');
            try putFloat(&out, p[1]);
            try out.append(A, ' ');
            try putFloat(&out, p[2]);
            if (me.vcol.len == me.verts.len) {
                // vertex colours: r g b (0..1)
                const c = me.vcol[vi];
                for ([3]u5{ 16, 8, 0 }) |sh| {
                    try out.append(A, ' ');
                    try putFloat(&out, @as(f32, @floatFromInt(c >> sh & 255)) * 0.003921569);
                }
            }
            try out.append(A, '\n');
        }
        // UVs: a vt per loop, faces v/vt
        const has_uv = me.uv.len == me.loops.len and me.uv.len > 0;
        if (has_uv) {
            for (me.uv) |t| {
                try out.appendSlice(A, "vt ");
                try putFloat(&out, t[0]);
                try out.append(A, ' ');
                try putFloat(&out, t[1]);
                try out.append(A, '\n');
            }
        }
        for (0..me.poff.len - 1) |p| {
            const lo = me.poff[p];
            const hi = me.poff[p + 1];
            if (hi - lo == 2) { // (two corners, a curve: a line)
                try putf(&out, "l {d} {d}\n", .{ me.loops[lo] + base_v, me.loops[lo + 1] + base_v });
                continue;
            }
            try out.append(A, 'f');
            for (lo..hi) |lp| {
                if (has_uv) {
                    try putf(&out, " {d}/{d}", .{ me.loops[lp] + base_v, lp + base_vt });
                } else try putf(&out, " {d}", .{me.loops[lp] + base_v});
            }
            try out.append(A, '\n');
        }
        base_v += me.verts.len;
        if (has_uv) base_vt += me.uv.len;
        n += 1;
    }
    if (n == 0) return error.NothingToExport;
    try bee.writeAtomic(path, out.items);
    if (material.count > 0) try writeMtl(mtl_path);
    return n;
}

// --- MTL export --------------------------------------------------------------

/// mtl_map: "<key><file>": a scene image's file, else a PNG beside the MTL
/// (its name without spaces), written.
fn writeMap(out: *std.ArrayList(u8), key: []const u8, map: ?@import("gltf.zig").MapImg, mtl_path: []const u8) !void {
    const mp = map orelse return;
    try out.appendSlice(A, key);
    const e: ?*images.Entry = if (mp.idx >= 0 and mp.idx < images.count) &images.list[@intCast(mp.idx)] else null;
    if (e != null and e.?.path.len > 0 and !e.?.inside) {
        try out.appendSlice(A, e.?.path);
    } else {
        var nb: [80]u8 = undefined;
        const nm = std.fmt.bufPrint(&nb, "{s}.png", .{mp.name}) catch "image.png";
        for (nb[0..nm.len]) |*c| {
            if (c.* == ' ') c.* = '_';
        }
        try out.appendSlice(A, nm);
        var pb: [720]u8 = undefined;
        const dir = mtl_path[0 .. mtl_path.len - baseName(mtl_path).len];
        if (std.fmt.bufPrint(&pb, "{s}{s}", .{ dir, nm })) |full| {
            if (mp.png.len > 0) bee.writeAtomic(full, mp.png) catch {};
        } else |_| {}
    }
    try out.append(A, '\n');
}

fn writeMtl(path: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(A);
    try out.appendSlice(A, "# BeeModel MTL export (PBR extension: Pr Pm Pc Pcr)\n");
    const gltf = @import("gltf.zig");
    gltf.mapsPlan(); // (maps used directly, else baked)
    defer gltf.mapsFree();
    for (material.list[0..material.count], 0..) |*ma, k| {
        try putf(&out, "\nnewmtl {s}\n", .{ma.nameOf()});
        try vec(&out, "Kd ", ma.base, 1);
        try vec(&out, "Ke ", ma.emission, ma.strength);
        try val(&out, "Ni ", ma.ior);
        try val(&out, "d ", ma.alpha);
        try val(&out, "Pr ", ma.roughness);
        try val(&out, "Pm ", ma.metallic);
        try val(&out, "Pc ", ma.coat);
        try val(&out, "Pcr ", ma.coat_rough);
        try vec(&out, "Tf ", .{ ma.transmission, ma.transmission, ma.transmission }, 1);
        try writeMap(&out, "map_Kd ", gltf.mapOf(k, 0), path);
        try writeMap(&out, "map_Pr -imfchan g ", gltf.mapOf(k, 1), path);
        try writeMap(&out, "map_Pm -imfchan b ", gltf.mapOf(k, 1), path);
        try writeMap(&out, "norm ", gltf.mapOf(k, 2), path);
        try writeMap(&out, "map_Ke ", gltf.mapOf(k, 4), path);
        try out.appendSlice(A, "illum 2\n");
    }
    try bee.writeAtomic(path, out.items);
}

// --- MTL import --------------------------------------------------------------

const P_BASE = 0;
const NMAPS = gops.NKINDS;

const Reader = struct {
    cur: ?usize = null,
    has_pr: bool = false,
    found: [NMAPS]u32 = @splat(0),
    chan: [NMAPS]u8 = @splat(0),
    dir: []const u8,
};

/// By the name params has, as material.set clamps it (not a parameter: nothing).
fn set1(r: *const Reader, name: []const u8, v: f32) void {
    const i = r.cur orelse return;
    _ = material.set(i, material.paramIndex(name) orelse return, 0, v);
}

fn set3(r: *const Reader, name: []const u8, v: [3]f32) void {
    const i = r.cur orelse return;
    const p = material.paramIndex(name) orelse return;
    for (v, 0..) |x, c| _ = material.set(i, p, c, x);
}

fn num(t: []const u8) ?f32 {
    const v = std.fmt.parseFloat(f32, t) catch return null;
    return if (std.math.isFinite(v)) v else null;
}

/// Up to three numbers; a single one fills all.
fn nums3(rest: []const u8, out: *[3]f32) usize {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        out[n] = num(it.next() orelse break) orelse break;
    }
    if (n == 1) {
        out[1] = out[0];
        out[2] = out[0];
    }
    return n;
}

/// The material's maps, gathered, into its graph: map_Kd alone: the image as the
/// base; else a texture set; a packed ORM when G and B come from one image.
fn flush(r: *Reader) void {
    const mi = r.cur orelse return;
    defer {
        r.found = @splat(0);
        r.chan = @splat(0);
    }
    var no_ao = false;
    if (r.found[gops.K_ROUGH] != 0 and r.found[gops.K_ROUGH] == r.found[gops.K_METAL] and r.chan[gops.K_ROUGH] == 'g' and r.chan[gops.K_METAL] == 'b') {
        r.found[gops.K_ORM] = r.found[gops.K_ROUGH];
        r.found[gops.K_ROUGH] = 0;
        r.found[gops.K_METAL] = 0;
        no_ao = true; // (its red: not known to be AO)
    }
    var n: usize = 0;
    for (r.found) |f| n += @intFromBool(f != 0);
    if (n == 0) return;
    gops.clear(mi);
    if (n == 1 and r.found[gops.K_BASE] != 0) {
        const k = gops.add(mi, sg.T_IMAGE) orelse return;
        _ = gops.setSlot(mi, k, 4, &.{@floatFromInt(r.found[gops.K_BASE])});
        _ = gops.socket(mi, sg.PIN_BASE, k, 0);
        return;
    }
    gops.buildMaps(mi, &r.found, false, no_ao);
}

fn mapKind(key: []const u8) ?usize {
    const e = std.mem.eql;
    if (e(u8, key, "map_Kd")) return gops.K_BASE;
    if (e(u8, key, "map_Pr")) return gops.K_ROUGH;
    if (e(u8, key, "map_Pm")) return gops.K_METAL;
    if (e(u8, key, "map_Ke")) return gops.K_EMIT;
    if (e(u8, key, "norm") or e(u8, key, "map_Bump") or e(u8, key, "map_bump") or e(u8, key, "bump")) return gops.K_NORMAL;
    if (e(u8, key, "map_d")) return gops.K_ALPHA;
    return null;
}

/// The first of each kind; the file is the line's last word, options before it.
fn loadMap(r: *Reader, kind: usize, rest: []const u8) void {
    if (r.cur == null or r.found[kind] != 0) return;
    const sp = std.mem.lastIndexOfAny(u8, rest, " \t");
    const file = if (sp) |s| rest[s + 1 ..] else rest;
    if (file.len == 0) return;
    if (std.mem.indexOf(u8, rest, "-imfchan ")) |c| {
        if (c + 9 < rest.len) r.chan[kind] = rest[c + 9];
    }
    var pb: [1024]u8 = undefined;
    // (a path of its own stays one; beside the MTL else)
    const full = if (file[0] == '/') file else std.fmt.bufPrint(&pb, "{s}{s}", .{ r.dir, file }) catch return;
    const i = images.load(full) catch |e| {
        app.log("  mtl: {s}: {s}", .{ full, @errorName(e) });
        return;
    };
    r.found[kind] = @intCast(i + 1);
}

/// Read an MTL. False: it cannot be read.
pub fn importMtl(path: []const u8) bool {
    const d = @import("ttf.zig").mapFile(path) orelse return false;
    defer _ = std.os.linux.munmap(d.ptr, d.len);
    const sl = std.mem.lastIndexOfScalar(u8, path, '/');
    var r = Reader{ .dir = if (sl) |s| path[0 .. s + 1] else "" };
    var lines = std.mem.splitScalar(u8, d, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const key = line[0..sp];
        const rest = std.mem.trim(u8, line[sp + 1 ..], " \t");
        const e = std.mem.eql;
        var v: [3]f32 = undefined;
        if (e(u8, key, "newmtl")) {
            flush(&r);
            const nm = rest[0..@min(rest.len, 31)];
            r.cur = material.find(nm) orelse material.new(nm);
            r.has_pr = false;
        } else if (e(u8, key, "Kd")) {
            if (nums3(rest, &v) > 0) set3(&r, "base", v);
        } else if (e(u8, key, "Ke")) {
            if (nums3(rest, &v) > 0) {
                set3(&r, "emission", v);
                if (@max(v[0], @max(v[1], v[2])) > 0) set1(&r, "strength", 1);
            }
        } else if (e(u8, key, "Tf")) {
            if (nums3(rest, &v) > 0) set1(&r, "transmission", (v[0] + v[1] + v[2]) * 0.33333333);
        } else if (e(u8, key, "Ni")) {
            set1(&r, "ior", num(rest) orelse continue);
        } else if (e(u8, key, "d")) {
            set1(&r, "alpha", num(rest) orelse continue);
        } else if (e(u8, key, "Tr")) {
            set1(&r, "alpha", 1 - (num(rest) orelse continue));
        } else if (e(u8, key, "Pm")) {
            set1(&r, "metallic", num(rest) orelse continue);
        } else if (e(u8, key, "Pc")) {
            set1(&r, "clearcoat", num(rest) orelse continue);
        } else if (e(u8, key, "Pcr")) {
            set1(&r, "coat_roughness", num(rest) orelse continue);
        } else if (e(u8, key, "Pr")) {
            r.has_pr = true;
            set1(&r, "roughness", num(rest) orelse continue);
        } else if (e(u8, key, "Ns")) {
            const x = num(rest) orelse continue;
            if (!r.has_pr) set1(&r, "roughness", @sqrt(2 / (@max(x, 0) + 2)));
        } else if (mapKind(key)) |k| loadMap(&r, k, rest);
    }
    flush(&r);
    return true;
}

/// After an OBJ came in: the MTL beside it, its first usemtl on the new object.
pub fn importMaterials(obj_path: []const u8, mtllib: []const u8, usemtl: []const u8, oi: usize) void {
    if (mtllib.len == 0) return;
    var pb: [1024]u8 = undefined;
    const sl = std.mem.lastIndexOfScalar(u8, obj_path, '/');
    const full = std.fmt.bufPrint(&pb, "{s}{s}", .{ if (sl) |s| obj_path[0 .. s + 1] else "", mtllib }) catch return;
    if (!importMtl(full)) return;
    if (usemtl.len == 0) return;
    const i = material.find(usemtl[0..@min(usemtl.len, 31)]) orelse return;
    scene.objects[oi].mat = @intCast(i + 1);
}

const testing = std.testing;

test "floats as the original writes them" {
    var b: [40]u8 = undefined;
    try testing.expectEqualStrings("0.000000", fmtFloat(&b, 0));
    try testing.expectEqualStrings("-1.500000", fmtFloat(&b, -1.5));
    try testing.expectEqualStrings("0.100000", fmtFloat(&b, 0.1));
    try testing.expectEqualStrings("12345.678711", fmtFloat(&b, 12345.6787));
    try testing.expectEqualStrings("0.000000", fmtFloat(&b, std.math.nan(f32)));
}

test "up axis and scale" {
    opts = .{ .zup = true, .scale = 1000 };
    defer defaults();
    try testing.expectEqual(m.V3{ 1000, -3000, 2000 }, exported(.{ 1, 2, 3 }));
}

test "the map keys" {
    try testing.expectEqual(gops.K_BASE, mapKind("map_Kd").?);
    try testing.expectEqual(gops.K_NORMAL, mapKind("bump").?);
    try testing.expectEqual(null, mapKind("map_Ks"));
}

test "numbers from a file" {
    var v: [3]f32 = undefined;
    try testing.expectEqual(3, nums3("0.1 0.2 0.3 0.4", &v));
    try testing.expectEqual(1, nums3("0.5", &v));
    try testing.expectEqual(@as(f32, 0.5), v[2]);
    try testing.expectEqual(0, nums3("nan 1", &v));
    try testing.expectEqual(0, nums3("", &v));
}
