// Materials: the original's principled model (material.s). A record is the
// original's 4096-byte layout: the 128-byte file part (name, base colour,
// metallic ... clip), then its shader graph (kept and saved as it came; the
// graph editor is not ported yet). Colours are linear. An object points at a
// material by index + 1 (Object.mat, 0 = none). Undo snapshots copy the list.
const std = @import("std");
const scene = @import("scene.zig");

pub const Material = extern struct {
    name: [32]u8 = @splat(0),
    base: [3]f32 = .{ 0.8, 0.8, 0.8 },
    metallic: f32 = 0,
    roughness: f32 = 0.5,
    specular: f32 = 0.5,
    ior: f32 = 1.45,
    transmission: f32 = 0,
    emission: [3]f32 = .{ 1, 1, 1 },
    strength: f32 = 0,
    coat: f32 = 0,
    coat_rough: f32 = 0.03,
    alpha: f32 = 1,
    density: f32 = 1,
    blend: f32 = 0, // 0 opaque, 1 masked, 2 translucent
    one_sided: f32 = 0,
    clip: f32 = 0,
    parent: u32 = 0, // an instance: its parent + 1 (kept, not used yet)
    func: u32 = 0, // 1: a material function
    rt: [3]u32 = @splat(0), // shading copies only
    /// the shader graph: node count, sockets, nodes ... (graph.s layout)
    graph: [GRAPH_BYTES]u8 = @splat(0),

    pub fn nameOf(ma: *const Material) []const u8 {
        return std.mem.sliceTo(&ma.name, 0);
    }
    pub fn nodes(ma: *const Material) u32 {
        return std.mem.readInt(u32, ma.graph[0..4], .little);
    }
};

pub const REC = 4096;
pub const FILE_PART = 128;
const GRAPH_BYTES = REC - FILE_PART;
// graph.s: node count at 128, sockets to 160, 72-byte nodes, pins from 3616
const GR_NODES = 160 - FILE_PART;
const GR_PINS = 3616 - FILE_PART;
const NODE_SZ = 72;
const GR_MAXN = 48;
const GR_MAGIC: u32 = 0x3252474d; // "MGR2"

comptime {
    std.debug.assert(@sizeOf(Material) == REC);
    std.debug.assert(@offsetOf(Material, "base") == 32);
    std.debug.assert(@offsetOf(Material, "density") == 92);
    std.debug.assert(@offsetOf(Material, "clip") == 104);
    std.debug.assert(@offsetOf(Material, "graph") == FILE_PART);
}

pub const MAX = 1024;
pub var list: [MAX]Material = undefined;
pub var count: usize = 0;
/// Bumped on every change (previews and caches key on it).
pub var version: u32 = 0;

pub fn reset() void {
    count = 0;
    version +%= 1;
}

pub fn get(i: usize) ?*Material {
    return if (i < count) &list[i] else null;
}

/// The material of object i, or null.
pub fn of(o: *const scene.Object) ?*Material {
    if (o.mat == 0) return null;
    return get(o.mat - 1);
}

pub fn find(name: []const u8) ?usize {
    for (list[0..count], 0..) |*ma, i| {
        if (std.mem.eql(u8, ma.nameOf(), name)) return i;
    }
    return null;
}

/// A new material with the defaults, named `want` (or "Material"), made unique
/// with .001, .002 ... Null when the scene holds MAX already.
pub fn new(want: []const u8) ?usize {
    if (count >= MAX) return null;
    const i = count;
    list[i] = .{};
    count += 1;
    uniqueName(i, if (want.len > 0) want else "Material");
    version +%= 1;
    return i;
}

fn uniqueName(i: usize, want: []const u8) void {
    var n = @min(want.len, 26);
    while (n > 0 and n < want.len and want[n] & 0xc0 == 0x80) n -= 1;
    const base = want[0..n];
    var suffix: u32 = 0;
    while (suffix <= 999) : (suffix += 1) {
        var buf: [32]u8 = @splat(0);
        const s = if (suffix == 0)
            std.fmt.bufPrint(buf[0..31], "{s}", .{base}) catch base
        else
            std.fmt.bufPrint(buf[0..31], "{s}.{d:0>3}", .{ base, suffix }) catch base;
        var taken = false;
        for (list[0..count], 0..) |*o, k| {
            if (k != i and std.mem.eql(u8, o.nameOf(), s)) taken = true;
        }
        if (!taken or suffix == 999) {
            list[i].name = buf;
            return;
        }
    }
}

pub fn rename(i: usize, want: []const u8) void {
    if (i >= count or want.len == 0) return;
    uniqueName(i, want);
    version +%= 1;
}

/// Delete material i: the later ones move down, objects follow (theirs: none).
pub fn delete(i: usize) void {
    if (i >= count) return;
    std.mem.copyForwards(Material, list[i .. count - 1], list[i + 1 .. count]);
    count -= 1;
    for (list[0..count]) |*ma| {
        if (ma.parent == 0) continue;
        if (ma.parent - 1 == i) ma.parent = 0 else if (ma.parent - 1 > i) ma.parent -= 1;
    }
    for (scene.objects[0..scene.count]) |*o| {
        if (o.mat == 0) continue;
        if (o.mat - 1 == i) o.mat = 0 else if (o.mat - 1 > i) o.mat -= 1;
    }
    version +%= 1;
}

// --- parameters (the original's mat_params) ----------------------------------

pub const Param = struct { name: []const u8, label: []const u8, off: usize, comps: u8, step: f32, lo: f32, hi: f32 };
pub const params = [_]Param{
    .{ .name = "base", .label = "Base colour", .off = 32, .comps = 3, .step = 0.005, .lo = 0, .hi = 1 },
    .{ .name = "metallic", .label = "Metallic", .off = 44, .comps = 1, .step = 0.005, .lo = 0, .hi = 1 },
    .{ .name = "roughness", .label = "Roughness", .off = 48, .comps = 1, .step = 0.005, .lo = 0, .hi = 1 },
    .{ .name = "specular", .label = "Specular", .off = 52, .comps = 1, .step = 0.005, .lo = 0, .hi = 1 },
    .{ .name = "ior", .label = "IOR", .off = 56, .comps = 1, .step = 0.005, .lo = 1, .hi = 3 },
    .{ .name = "transmission", .label = "Transmission", .off = 60, .comps = 1, .step = 0.005, .lo = 0, .hi = 1 },
    .{ .name = "emission", .label = "Emission", .off = 64, .comps = 3, .step = 0.005, .lo = 0, .hi = 1 },
    .{ .name = "strength", .label = "Emission strength", .off = 76, .comps = 1, .step = 0.05, .lo = 0, .hi = 1000 },
    .{ .name = "clearcoat", .label = "Clear coat", .off = 80, .comps = 1, .step = 0.005, .lo = 0, .hi = 1 },
    .{ .name = "coat_roughness", .label = "Coat roughness", .off = 84, .comps = 1, .step = 0.005, .lo = 0, .hi = 1 },
    .{ .name = "alpha", .label = "Alpha", .off = 88, .comps = 1, .step = 0.005, .lo = 0, .hi = 1 },
    .{ .name = "density", .label = "Density (g/cm3)", .off = 92, .comps = 1, .step = 0.01, .lo = 0, .hi = 25 },
    .{ .name = "blend", .label = "Blend mode", .off = 96, .comps = 1, .step = 1, .lo = 0, .hi = 2 },
    .{ .name = "one_sided", .label = "One-sided", .off = 100, .comps = 1, .step = 1, .lo = 0, .hi = 1 },
    .{ .name = "clip", .label = "Mask clip", .off = 104, .comps = 1, .step = 0.005, .lo = 0, .hi = 1 },
};

pub fn paramIndex(name: []const u8) ?usize {
    for (params, 0..) |p, k| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return k;
    }
    return null;
}

/// The parameter a field of this label shows.
pub fn paramOfLabel(label: []const u8) ?usize {
    for (params, 0..) |p, k| {
        if (std.mem.eql(u8, p.label, label)) return k;
    }
    return null;
}

pub fn ptr(ma: *Material, p: usize, comp: usize) *f32 {
    const bytes: [*]u8 = @ptrCast(ma);
    return @ptrCast(@alignCast(bytes + params[p].off + comp * 4));
}

/// Set component `comp` of parameter p, clamped to its range. False: no such one.
pub fn set(i: usize, p: usize, comp: usize, v: f32) bool {
    const ma = get(i) orelse return false;
    if (p >= params.len or comp >= params[p].comps or !std.math.isFinite(v)) return false;
    ptr(ma, p, comp).* = std.math.clamp(v, params[p].lo, params[p].hi);
    version +%= 1;
    return true;
}

// --- colours ---------------------------------------------------------------------

pub fn toSrgb(c: [3]f32) u32 {
    var out: u32 = 0;
    for (c) |v0| {
        const v = if (std.math.isFinite(v0)) std.math.clamp(v0, 0, 1) else 1;
        const s = if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
        out = (out << 8) | @as(u32, @intFromFloat(@round(s * 255)));
    }
    return out;
}

pub fn toLinear(c: u32) [3]f32 {
    var out: [3]f32 = undefined;
    for (0..3) |k| {
        const v: f32 = @as(f32, @floatFromInt((c >> @intCast(16 - k * 8)) & 255)) / 255.0;
        out[k] = if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }
    return out;
}

/// The solid view's colour of an object: its material's base colour (the
/// original's mat_display_color: the square root as the sRGB curve, about),
/// else the object's own colour.
pub fn displayColor(o: *const scene.Object) u32 {
    const ma = of(o) orelse return o.color;
    var out: u32 = 0;
    for (ma.base) |v0| {
        const v = if (std.math.isFinite(v0)) std.math.clamp(v0, 0, 1) else 1;
        out = (out << 8) | @as(u32, @intFromFloat(@sqrt(v) * 255 + 0.5));
    }
    return out;
}

// --- presets (matlib.s) -----------------------------------------------------------

pub const Preset = struct {
    name: []const u8,
    v: [14]f32, // base rgb, metallic, roughness, specular, ior, transmission, emission rgb, strength, coat, coat roughness
    /// a procedural graph over the values (graphops.zig)
    procedural: bool = false,
};
pub const presets = [_]Preset{
    .{ .name = "gold", .v = .{ 1.0, 0.766, 0.336, 1, 0.22, 0.5, 1.5, 0, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "silver", .v = .{ 0.972, 0.960, 0.915, 1, 0.18, 0.5, 1.5, 0, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "copper", .v = .{ 0.955, 0.638, 0.538, 1, 0.25, 0.5, 1.5, 0, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "chrome", .v = .{ 0.55, 0.556, 0.554, 1, 0.04, 0.5, 1.5, 0, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "aluminium", .v = .{ 0.913, 0.922, 0.924, 1, 0.38, 0.5, 1.5, 0, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "plastic", .v = .{ 0.70, 0.06, 0.05, 0, 0.35, 0.5, 1.46, 0, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "rubber", .v = .{ 0.05, 0.05, 0.05, 0, 0.85, 0.35, 1.52, 0, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "glass", .v = .{ 1.0, 1.0, 1.0, 0, 0.0, 0.5, 1.5, 1, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "frosted_glass", .v = .{ 0.95, 0.97, 1.0, 0, 0.35, 0.5, 1.5, 1, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "water", .v = .{ 0.85, 0.95, 1.0, 0, 0.02, 0.5, 1.333, 1, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "ceramic", .v = .{ 0.92, 0.91, 0.88, 0, 0.12, 0.5, 1.5, 0, 1, 1, 1, 0, 0.6, 0.05 } },
    .{ .name = "car_paint", .v = .{ 0.55, 0.02, 0.03, 0.4, 0.4, 0.5, 1.5, 0, 1, 1, 1, 0, 1, 0.02 } },
    .{ .name = "wood", .v = .{ 0.45, 0.27, 0.13, 0, 0.55, 0.4, 1.5, 0, 1, 1, 1, 0, 0, 0.03 }, .procedural = true },
    .{ .name = "marble", .v = .{ 0.88, 0.87, 0.85, 0, 0.18, 0.5, 1.5, 0, 1, 1, 1, 0, 0.3, 0.05 }, .procedural = true },
    .{ .name = "concrete", .v = .{ 0.55, 0.55, 0.53, 0, 0.9, 0.4, 1.5, 0, 1, 1, 1, 0, 0, 0.03 }, .procedural = true },
    .{ .name = "fabric", .v = .{ 0.20, 0.30, 0.55, 0, 0.95, 0.3, 1.5, 0, 1, 1, 1, 0, 0, 0.03 }, .procedural = true },
    .{ .name = "leather", .v = .{ 0.30, 0.15, 0.08, 0, 0.6, 0.45, 1.5, 0, 1, 1, 1, 0, 0.2, 0.3 }, .procedural = true },
    .{ .name = "skin", .v = .{ 0.80, 0.56, 0.45, 0, 0.5, 0.4, 1.4, 0, 1, 1, 1, 0, 0.1, 0.4 } },
    .{ .name = "clay", .v = .{ 0.65, 0.42, 0.30, 0, 0.92, 0.3, 1.5, 0, 1, 1, 1, 0, 0, 0.03 } },
    .{ .name = "emissive", .v = .{ 0.05, 0.05, 0.05, 0, 0.5, 0.5, 1.5, 0, 1.0, 0.85, 0.6, 8, 0, 0.03 } },
};

pub fn presetIndex(name: []const u8) ?usize {
    for (presets, 0..) |p, k| {
        if (std.ascii.eqlIgnoreCase(p.name, name)) return k;
    }
    return null;
}

/// Give material i preset k's values (its graph goes, as in the original).
pub fn applyPreset(i: usize, k: usize) void {
    const ma = get(i) orelse return;
    const v = presets[k].v;
    ma.base = .{ v[0], v[1], v[2] };
    ma.metallic = v[3];
    ma.roughness = v[4];
    ma.specular = v[5];
    ma.ior = v[6];
    ma.transmission = v[7];
    ma.emission = .{ v[8], v[9], v[10] };
    ma.strength = v[11];
    ma.coat = v[12];
    ma.coat_rough = v[13];
    ma.graph = @splat(0);
    if (presets[k].procedural) @import("graphops.zig").buildPreset(i, presets[k].name);
    version +%= 1;
}

// --- files: MATS (count, 128-byte records), OMAT, MGRF ------------------------------

pub fn writeMats(out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    try appendU32(out, a, @intCast(count));
    for (list[0..count]) |*ma| {
        const bytes: [*]const u8 = @ptrCast(ma);
        try out.appendSlice(a, bytes[0..FILE_PART]);
    }
}

/// MGRF: 0 (v0.12 readers see no graphs), "MGR2", the count, then per material
/// its node count n, the graph header (32 bytes), n nodes and the pins onwards.
pub fn writeGraphs(out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    try appendU32(out, a, 0);
    try appendU32(out, a, GR_MAGIC);
    try appendU32(out, a, @intCast(count));
    for (list[0..count]) |*ma| {
        const n: usize = @min(ma.nodes(), @as(u32, GR_MAXN));
        try appendU32(out, a, @intCast(n));
        try out.appendSlice(a, ma.graph[0..GR_NODES]);
        try out.appendSlice(a, ma.graph[GR_NODES..][0 .. n * NODE_SZ]);
        try out.appendSlice(a, ma.graph[GR_PINS..]);
    }
}

fn appendU32(out: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    var x: [4]u8 = undefined;
    std.mem.writeInt(u32, &x, v, .little);
    try out.appendSlice(a, &x);
}

fn rd32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .little);
}

/// Replace the materials with a MATS chunk's. False: damaged (none kept).
pub fn readMats(d: []const u8) bool {
    count = 0;
    version +%= 1;
    if (d.len < 4) return d.len == 0;
    const n = rd32(d, 0);
    if (n > MAX or 4 + n * FILE_PART > d.len) return false;
    for (0..n) |k| {
        list[k] = .{};
        const dst: [*]u8 = @ptrCast(&list[k]);
        @memcpy(dst[0..FILE_PART], d[4 + k * FILE_PART ..][0..FILE_PART]);
        list[k].name[31] = 0;
        // bad numbers: the defaults (a file is not to be trusted)
        const def = Material{};
        for (params, 0..) |p, pi| {
            for (0..p.comps) |c| {
                const v = ptr(&list[k], pi, c);
                const dv = ptr(@constCast(&def), pi, c).*;
                if (!std.math.isFinite(v.*)) v.* = dv;
                v.* = std.math.clamp(v.*, p.lo, p.hi);
            }
        }
        if (list[k].density == 0) list[k].density = 1; // (older files: water)
        if (list[k].parent > n) list[k].parent = 0;
    }
    count = n;
    return true;
}

/// The graphs (after readMats). Returns false when a graph is there in a form
/// this port does not keep (v0.12 layout, damaged): those are dropped.
pub fn readGraphs(d: []const u8) bool {
    var ok = true;
    if (d.len < 12 or rd32(d, 0) != 0 or rd32(d, 4) != GR_MAGIC) {
        // v0.12 layout (count, then 896 bytes each: 12-node graphs, 5 sockets)
        if (d.len < 4) return true;
        const n = @min(rd32(d, 0), count);
        if (@as(usize, n) * GR_V1 + 4 > d.len) return n == 0;
        for (0..n) |k| {
            const g = &list[k].graph;
            @memcpy(g[0..GR_V1], d[4 + k * GR_V1 ..][0..GR_V1]);
            graphUpgrade(g);
            if (!graphCheck(g)) ok = false;
        }
        return ok;
    }
    const n = @min(rd32(d, 8), count);
    var o: usize = 12;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        if (o + 4 > d.len) return false;
        const nn = rd32(d, o);
        if (nn > GR_MAXN) return false;
        const need = 4 + GR_NODES + @as(usize, nn) * NODE_SZ + (GRAPH_BYTES - GR_PINS);
        if (o + need > d.len) return false;
        const g = &list[k].graph;
        g.* = @splat(0); // (all of it clear, then the parts)
        @memcpy(g[0..GR_NODES], d[o + 4 ..][0..GR_NODES]);
        @memcpy(g[GR_NODES..][0 .. nn * NODE_SZ], d[o + 4 + GR_NODES ..][0 .. nn * NODE_SZ]);
        @memcpy(g[GR_PINS..], d[o + 4 + GR_NODES + nn * NODE_SZ ..][0 .. GRAPH_BYTES - GR_PINS]);
        if (!graphCheck(g)) ok = false;
        o += need;
    }
    return ok;
}

const GR_V1 = 1024 - FILE_PART; // a v0.12 record's graph part
const GR_NTYPES = 42;

/// graph_upgrade: a v0.12 graph's 5 sockets (at graph byte 4) to pins.
pub fn graphUpgrade(g: *[GRAPH_BYTES]u8) void {
    const pin = [5]usize{ 0, 1, 3, 4, 6 }; // base, metallic, roughness, emission, normal
    for (pin, 0..) |p, c| {
        const v = rd32(g, 4 + c * 4);
        std.mem.writeInt(u32, g[GR_PINS + p * 4 ..][0..4], v, .little);
        std.mem.writeInt(u32, g[4 + c * 4 ..][0..4], 0, .little);
    }
}

/// graph_check: the graph cleared when it does not make sense (a node count
/// over 48, a pin to no node or an output past 7, a type not known, a link to
/// a later node). False: it was.
pub fn graphCheck(g: *[GRAPH_BYTES]u8) bool {
    const n = rd32(g, 0);
    const bad = blk: {
        if (n > GR_MAXN) break :blk true;
        for (0..16) |c| {
            const p = rd32(g, GR_PINS + c * 4);
            if (p & 0xff000000 != 0 or p & 0xf80000 != 0 or (p & 0xffff) > n) break :blk true;
        }
        for (0..n) |i| {
            const at = GR_NODES + i * NODE_SZ;
            if (rd32(g, at) -% 1 >= GR_NTYPES) break :blk true;
            for (0..3) |k| {
                const l = rd32(g, at + 4 + k * 16);
                if (l & 0xfff80000 != 0 or (l & 0xffff) > i) break :blk true;
            }
        }
        break :blk false;
    };
    if (bad) g.* = @splat(0);
    return !bad;
}

/// Whether any material has a graph (its look comes from nodes this port
/// keeps but does not evaluate yet).
pub fn anyGraph() bool {
    for (list[0..count]) |*ma| {
        if (ma.nodes() > 0) return true;
    }
    return false;
}

// --- undo snapshots ---------------------------------------------------------------

pub fn same(snap: []const Material) bool {
    if (snap.len != count) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(snap), std.mem.sliceAsBytes(list[0..count]));
}

// --- tests ------------------------------------------------------------------------

test "names, delete, file round trip" {
    reset();
    const a = new("").?;
    const b = new("").?;
    try std.testing.expectEqualStrings("Material", list[a].nameOf());
    try std.testing.expectEqualStrings("Material.001", list[b].nameOf());
    try std.testing.expect(set(b, paramIndex("ior").?, 0, 9));
    try std.testing.expectEqual(@as(f32, 3), list[b].ior);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try writeMats(&out, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4 + 2 * 128), out.items.len);
    delete(a);
    try std.testing.expectEqualStrings("Material.001", list[0].nameOf());
    try std.testing.expect(readMats(out.items));
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(f32, 3), list[1].ior);
}

test "graphs: v0.12 sockets become pins, nonsense is cleared (graph_check)" {
    reset();
    _ = new("a").?;
    _ = new("b").?;
    var d: [4 + 2 * GR_V1]u8 = @splat(0);
    std.mem.writeInt(u32, d[0..4], 2, .little);
    // a: one checker node, its socket 0 (base) and 4 (normal) to it
    std.mem.writeInt(u32, d[4..8], 1, .little);
    std.mem.writeInt(u32, d[4 + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u32, d[4 + 20 ..][0..4], 1, .little);
    std.mem.writeInt(u32, d[4 + GR_NODES ..][0..4], 3, .little);
    // b: a node linked to itself
    const b = 4 + GR_V1;
    std.mem.writeInt(u32, d[b..][0..4], 1, .little);
    std.mem.writeInt(u32, d[b + GR_NODES ..][0..4], 7, .little);
    std.mem.writeInt(u32, d[b + GR_NODES + 4 ..][0..4], 1, .little);
    try std.testing.expect(!readGraphs(&d));
    try std.testing.expectEqual(@as(u32, 1), list[0].nodes());
    try std.testing.expectEqual(@as(u32, 1), rd32(&list[0].graph, GR_PINS));
    try std.testing.expectEqual(@as(u32, 1), rd32(&list[0].graph, GR_PINS + 6 * 4));
    try std.testing.expectEqual(@as(u32, 0), rd32(&list[0].graph, 4));
    try std.testing.expectEqual(@as(u32, 0), list[1].nodes());
    try std.testing.expect(std.mem.allEqual(u8, &list[1].graph, 0));
}
