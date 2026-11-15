// The commands on shader graphs (graph.s, matinst.s, matlib.s, matfunc.s, bake.s,
// matui.s's buttons). The node editor is not ported: these are what the console,
// scripts and the Material tab use. Numbers as the operators' texts say.
const std = @import("std");
const scene = @import("scene.zig");
const material = @import("material.zig");
const images = @import("images.zig");
const sg = @import("shgraph.zig");
const gops = @import("graphops.zig");
const bake = @import("bake.zig");
const ops = @import("ops.zig");
const app = @import("app.zig");
const matops = @import("matops.zig");
const undo = @import("undo.zig");
const expr = @import("expr.zig");
const ui = @import("ui.zig");
const zui = @import("zui");
const bkit = @import("bkit.zig");
const host = @import("zuihost.zig");

const Words = struct {
    s: []const u8,
    i: usize = 0,
    fn next(w: *Words) ?[]const u8 {
        while (w.i < w.s.len and (w.s[w.i] == ' ' or w.s[w.i] == '\t')) w.i += 1;
        if (w.i >= w.s.len) return null;
        if (w.s[w.i] == '"') {
            const st = w.i + 1;
            const e = std.mem.indexOfScalarPos(u8, w.s, st, '"') orelse w.s.len;
            w.i = @min(e + 1, w.s.len);
            return w.s[st..e];
        }
        const st = w.i;
        while (w.i < w.s.len and w.s[w.i] != ' ' and w.s[w.i] != '\t') w.i += 1;
        return w.s[st..w.i];
    }
    fn mat(w: *Words) ?usize {
        const nm = w.next() orelse return null;
        return material.find(nm) orelse {
            app.log("  no material named {s}", .{nm});
            return null;
        };
    }
    fn num(w: *Words) ?f32 {
        const sv = w.i;
        const t = w.next() orelse return null;
        const v = expr.eval(t) orelse {
            w.i = sv;
            return null;
        };
        if (!std.math.isFinite(v)) return null;
        return v;
    }
    fn int(w: *Words) ?u32 {
        const v = w.num() orelse return null;
        if (v < 0 or v > 1e9) return null;
        return @intFromFloat(v);
    }
};

pub fn opNode() void {
    var w = Words{ .s = ops.arg };
    const need = "  material.node <material> image|noise|checker|gradient|mix|ramp|math|bump [values]";
    const mi = w.mat() orelse return app.log(need, .{});
    const tn = w.next() orelse return app.log(need, .{});
    const t = gops.typeIndex(tn) orelse return app.log(need, .{});
    const node = gops.add(mi, t) orelse return app.log("  a material holds 48 nodes", .{});
    if (t >= 37 and t <= 39) {
        const nm = w.next();
        if (nm) |n| gops.setParamName(&sg.nodesMut(&material.list[mi])[node - 1], n);
    }
    var slot: u32 = 4;
    if (t == 1 or t == 39 or t == 42) {
        if (w.next()) |nm| {
            const k: ?usize = if (t == 42) material.find(nm) else images.find(nm);
            const x = k orelse {
                _ = gops.delete(mi, node);
                return app.log("  no {s} named {s}", .{ if (t == 42) @as([]const u8, "material function") else "image", nm });
            };
            _ = gops.setSlot(mi, node, 4, &.{@floatFromInt(x + 1)});
            slot = 5;
        }
    }
    while (slot < 8) : (slot += 1) {
        const v = w.num() orelse break;
        _ = gops.setSlot(mi, node, slot, &.{v});
    }
    app.log("  graph: node {d}", .{node});
}

pub fn opLink() void {
    var w = Words{ .s = ops.arg };
    const need = "  material.link <material> <from node> <to node> <input 1-3> [output 0-3] (no loops)";
    const mi = w.mat() orelse return app.log(need, .{});
    const a = w.int() orelse return app.log(need, .{});
    const b = w.int() orelse return app.log(need, .{});
    const c = w.int() orelse return app.log(need, .{});
    const out = w.int() orelse 0;
    const n = gops.link(mi, a, b, c, out) orelse return app.log(need, .{});
    app.log("  graph: node {d}", .{n});
}

pub fn opNodeSet() void {
    var w = Words{ .s = ops.arg };
    const need = "  material.node_set <material> <node> <slot: 1-3 inputs, 4-7 values> <x> [y z]";
    const mi = w.mat() orelse return app.log(need, .{});
    const n = w.int() orelse return app.log(need, .{});
    const s = w.int() orelse return app.log(need, .{});
    var v: [3]f32 = undefined;
    var c: usize = 0;
    while (c < 3) : (c += 1) v[c] = w.num() orelse break;
    if (c == 0 or !gops.setSlot(mi, n, s, v[0..c])) return app.log(need, .{});
    app.log("  graph: node {d}", .{n});
}

pub fn opSocket() void {
    var w = Words{ .s = ops.arg };
    const need = "  material.socket <material> base|metallic|specular|roughness|emission|opacity|normal|ao|clearcoat|coat_roughness|transmission|ior|mask <node|none> [output 0-3]";
    const mi = w.mat() orelse return app.log(need, .{});
    const sn = w.next() orelse return app.log(need, .{});
    var pin: ?usize = null;
    for (gops.socket_names, 0..) |x, k| {
        if (std.mem.eql(u8, x, sn)) pin = k;
    }
    const p = pin orelse return app.log(need, .{});
    const t = w.next() orelse return app.log(need, .{});
    var node: u32 = 0;
    if (!std.mem.eql(u8, t, "none")) {
        const x = expr.eval(t) orelse return app.log(need, .{});
        if (!(x >= 0 and x <= 48)) return app.log(need, .{});
        node = @intFromFloat(x);
    }
    const out = w.int() orelse 0;
    if (!gops.socket(mi, p, node, out)) return app.log(need, .{});
    app.log("  graph: {s}", .{sn});
}

pub fn opNodeDelete() void {
    var w = Words{ .s = ops.arg };
    const need = "  material.node_delete <material> <node>";
    const mi = w.mat() orelse return app.log(need, .{});
    const n = w.int() orelse return app.log(need, .{});
    if (!gops.delete(mi, n)) app.log(need, .{});
}

pub fn opNodeMove() void {
    var w = Words{ .s = ops.arg };
    const need = "  material.node_move <material> <node (0: the output)> <x> <y>";
    const mi = w.mat() orelse return app.log(need, .{});
    const n = w.int() orelse return app.log(need, .{});
    const x = w.num() orelse return app.log(need, .{});
    const y = w.num() orelse return app.log(need, .{});
    if (@abs(x) > 30000 or @abs(y) > 30000 or !gops.place(mi, n, @intFromFloat(x), @intFromFloat(y))) app.log(need, .{});
}

pub fn opNodesClear() void {
    var w = Words{ .s = ops.arg };
    const mi = w.mat() orelse return;
    gops.clear(mi);
    app.log("  graph: none", .{});
}

pub fn opNodeName() void {
    var w = Words{ .s = ops.arg };
    const need = "  material.node_name <material> <parameter node> <name>";
    const mi = w.mat() orelse return app.log(need, .{});
    const n = w.int() orelse return app.log(need, .{});
    const nm = w.next() orelse return app.log(need, .{});
    const ma = &material.list[mi];
    if (n == 0 or n > sg.count(ma)) return app.log(need, .{});
    const nd = &sg.nodesMut(ma)[n - 1];
    if (nd.type < 37 or nd.type > 39) return app.log(need, .{});
    gops.setParamName(nd, nm);
    material.version +%= 1;
}

/// New instance `name` (empty: "<parent>_Inst"); the active mesh gets it.
fn instance(parent: usize, name: []const u8) void {
    var b: [40]u8 = undefined;
    const nm = if (name.len > 0) name else std.fmt.bufPrint(&b, "{s}_Inst", .{material.list[parent].nameOf()}) catch "Inst";
    const i = gops.instanceNew(parent, nm) orelse return;
    if (matops.activeMesh()) |a| scene.objects[a].mat = @intCast(i + 1);
    app.log("  material instance: {s}", .{material.list[i].nameOf()});
}

pub fn opInstance() void {
    var w = Words{ .s = ops.arg };
    const mi = w.mat() orelse return app.log("  material.instance <parent> [name]", .{});
    instance(mi, w.next() orelse "");
}

/// The Material tab's New Instance.
pub fn opNewInstance() void {
    const a = matops.activeMesh() orelse return;
    if (scene.objects[a].mat == 0 or material.of(&scene.objects[a]) == null) return;
    instance(scene.objects[a].mat - 1, "");
    undo.label("Material Instance");
}

pub fn pollNewInstance() ?[]const u8 {
    const a = matops.activeMesh() orelse return "Materials go on meshes: select a mesh object";
    return if (material.of(&scene.objects[a]) == null) "The object has no material" else null;
}

fn paramOf(w: *Words, mi: *usize) ?u32 {
    mi.* = w.mat() orelse return null;
    const nm = w.next() orelse return null;
    const n = gops.paramNode(&material.list[mi.*], nm);
    if (n == 0) {
        app.log("  no parameter named {s}", .{nm});
        return null;
    }
    return n;
}

pub fn opParam() void {
    var w = Words{ .s = ops.arg };
    var mi: usize = 0;
    const n = paramOf(&w, &mi) orelse return app.log("  material.param <material> <parameter> <x> [y z w]", .{});
    var v: [4]f32 = undefined;
    var c: usize = 0;
    while (c < 4) : (c += 1) v[c] = w.num() orelse break;
    if (c == 0) return app.log("  material.param <material> <parameter> <x> [y z w]", .{});
    gops.setParam(mi, n, v[0..c]);
}

pub fn opParamReset() void {
    var w = Words{ .s = ops.arg };
    var mi: usize = 0;
    const n = paramOf(&w, &mi) orelse return app.log("  material.param_reset <material> <parameter>", .{});
    gops.resetParam(mi, n);
}

pub fn opFunctionNew() void {
    var w = Words{ .s = ops.arg };
    const i = material.new(w.next() orelse "Function") orelse return;
    material.list[i].func = 1;
    const a = gops.add(i, sg.T_FNIN).?;
    const b = gops.add(i, sg.T_FNOUT).?;
    _ = gops.link(i, a, b, 1, 0);
    _ = gops.place(i, a, 40, 60);
    _ = gops.place(i, b, 360, 60);
    app.log("  material function: {s}", .{material.list[i].nameOf()});
}

/// The leading digits of a word (im_int: "3x" is 3, "x" 0).
fn leadInt(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        v = v *% 10 +% (c - '0');
    }
    return v;
}

/// material.make_function <material> <node>... (the node editor's Ctrl+G).
pub fn opMakeFunction() void {
    var w = Words{ .s = ops.arg };
    const need = "  material.make_function <material> <node> [node...]";
    const nm = w.next() orelse return app.log(need, .{});
    const mi = material.find(nm) orelse return app.log(need, .{});
    var sel: u64 = 0;
    while (w.next()) |t| {
        const k = leadInt(t);
        if (k >= 1 and k <= sg.MAX_NODES) sel |= @as(u64, 1) << @intCast(k);
    }
    if (sel == 0) return app.log(need, .{});
    switch (gops.makeFunction(mi, nm, sel)) {
        .need => app.log(need, .{}),
        .fail => app.log("  make_function: up to 3 inputs and 3 outputs from outside, and nodes of that material", .{}),
        .loop => app.log("  make_function {s}: those nodes would make a loop with the rest (the graph could not be saved): nothing changed", .{std.mem.trim(u8, ops.arg, " ")}),
        .made => |f| app.log("  material function: {s}", .{material.list[f].nameOf()}),
    }
}

/// A one-node graph: the image, box-projected, drives the base colour.
pub fn setTexture(mi: usize, im: ?usize, size: f32) void {
    gops.clear(mi);
    const i = im orelse return;
    const k = gops.add(mi, 1) orelse return;
    _ = gops.setSlot(mi, k, 4, &.{@floatFromInt(i + 1)});
    _ = gops.setSlot(mi, k, 5, &.{size});
    _ = gops.socket(mi, sg.PIN_BASE, k, 0);
}

pub fn opTexture() void {
    var w = Words{ .s = ops.arg };
    const need = "  material.texture <name> <image|none> [size]";
    const mi = w.mat() orelse return app.log(need, .{});
    const nm = w.next() orelse return app.log(need, .{});
    const size = w.num() orelse 1;
    var im: ?usize = null;
    if (!std.mem.eql(u8, nm, "none")) im = images.find(nm) orelse return app.log("  no image named {s}", .{nm});
    setTexture(mi, im, size);
    app.log("  material texture: {s}", .{nm});
}

// --- texture sets ------------------------------------------------------------------------

fn hasImageExt(p: []const u8) bool {
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".hdr" }) |e| {
        if (p.len > e.len and std.ascii.endsWithIgnoreCase(p, e)) return true;
    }
    return false;
}

/// The material made from the set `path` belongs to; `name0` empty: after the prefix.
fn importSet(path: []const u8, name0: []const u8) void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return app.log("  material.import_textures <one image of the set> [name]", .{});
    const dir = path[0 .. slash + 1];
    const pre = gops.prefixOf(path[slash + 1 ..]);
    var found: [gops.NKINDS]u32 = @splat(0);
    var dx = false;
    var nmaps: u32 = 0;
    const linux = std.os.linux;
    var zb: [600]u8 = undefined;
    const dz = std.fmt.bufPrintSentinel(&zb, "{s}", .{dir}, 0) catch return;
    const rc = linux.open(dz, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return app.log("  texture set: no maps found beside {s}", .{path});
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var o: usize = 0;
        while (o < n) {
            const reclen = std.mem.readInt(u16, buf[o + 16 ..][0..2], .little);
            const nm = std.mem.sliceTo(buf[o + 19 .. o + reclen], 0);
            o += reclen;
            if (!std.mem.startsWith(u8, nm, pre) or nm.len >= 300) continue;
            const rest = nm[pre.len..];
            var low: [127]u8 = undefined;
            const lr = std.ascii.lowerString(low[0..@min(rest.len, 126)], rest[0..@min(rest.len, 126)]);
            if (!hasImageExt(lr)) continue;
            const dot = std.mem.lastIndexOfScalar(u8, lr, '.') orelse continue;
            const kind = gops.kindOf(lr[0..dot]) orelse continue;
            if (found[kind] != 0) continue; // (the first of each kind)
            if (kind == gops.K_NORMAL) dx = std.mem.indexOf(u8, lr[0..dot], "dx") != null;
            var pb: [1024]u8 = undefined;
            const full = std.fmt.bufPrint(&pb, "{s}{s}", .{ dir, nm }) catch continue;
            const i = images.load(full) catch continue;
            found[kind] = @intCast(i + 1);
            nmaps += 1;
        }
    }
    if (nmaps == 0) return app.log("  texture set: no maps found beside {s}", .{path});
    // the material: named, else after the prefix (separators at its end off)
    const nm2 = if (name0.len > 0) name0 else std.mem.trimEnd(u8, pre, "_- ");
    const mi = material.new(nm2) orelse return;
    gops.buildMaps(mi, &found, dx, false);
    if (matops.activeMesh()) |a| scene.objects[a].mat = @intCast(mi + 1);
    app.log("  texture set: {d} maps -> {s}", .{ nmaps, material.list[mi].nameOf() });
}

fn picked(p: []const u8) void {
    importSet(p, "");
    undo.label("Import Texture Set");
}

pub fn opImportTextures() void {
    const a = std.mem.trim(u8, ops.arg, " ");
    if (a.len == 0) {
        @import("filebrowser.zig").show(.open, "Texture Set", ".png", "", picked);
        return;
    }
    // the text is the path when it ends in an image's extension, else its last word is the name
    var eb: [1024]u8 = undefined;
    if (hasImageExt(a)) {
        const p = @import("files.zig").expandHome(&eb, a) orelse return;
        return importSet(p, "");
    }
    const sp = std.mem.lastIndexOfScalar(u8, a, ' ') orelse return app.log("  material.import_textures <one image of the set> [name]", .{});
    const p = @import("files.zig").expandHome(&eb, a[0..sp]) orelse return;
    importSet(p, a[sp + 1 ..]);
}

// --- baking ------------------------------------------------------------------------------

const bake_kinds = [_][]const u8{ "normal", "ao", "curvature" };

fn bakeJob(arg: []const u8, _: usize, _: usize) void {
    var w = Words{ .s = arg };
    const need = "  object.bake <low> <high> <normal|ao|curvature> <image> [distance]";
    const ln = w.next() orelse return app.log(need, .{});
    const hn = w.next() orelse return app.log(need, .{});
    const low = scene.find(ln) orelse return app.log("  bake: not found: {s}", .{ln});
    const high = scene.find(hn) orelse return app.log("  bake: not found: {s}", .{hn});
    const kn = w.next() orelse return app.log(need, .{});
    var kind: ?u32 = null;
    for (bake_kinds, 0..) |k, i| {
        if (std.mem.eql(u8, k, kn)) kind = @intCast(i);
    }
    const kk = kind orelse return app.log(need, .{});
    const inm = w.next() orelse return app.log(need, .{});
    const im = images.find(inm) orelse return app.log("  bake: not found: {s}", .{inm});
    const dist = w.num() orelse 0;
    const n = bake.bake(low, high, @fromBackingInt(@intCast(kk)), im, dist, null) orelse return app.log("  bake: the low mesh needs UVs and the image 8 bits", .{});
    material.version +%= 1;
    app.log("  baked texels: {d}", .{n});
}

pub fn opBake() void {
    @import("jobui.zig").later(bakeJob, "Baking maps", ops.arg, 0, 0);
}

const map_kinds = [_]struct { s: []const u8, k: usize }{
    .{ .s = "_base", .k = gops.K_BASE },
    .{ .s = "_orm", .k = gops.K_ORM },
    .{ .s = "_normal", .k = gops.K_NORMAL },
    .{ .s = "_emissive", .k = gops.K_EMIT },
};

fn matBakeJob(arg: []const u8, _: usize, _: usize) void {
    var w = Words{ .s = arg };
    const onm = w.next() orelse return app.log("  material.bake <object> [size] [apply]", .{});
    const bad = "  material.bake: the object needs a material and UVs: {s}";
    const ob = scene.find(onm) orelse return app.log(bad, .{onm});
    var size: u32 = 1024;
    var apply = false;
    while (w.next()) |t| {
        if (std.mem.eql(u8, t, "apply")) {
            apply = true;
            continue;
        }
        const v = expr.eval(t) orelse continue;
        if (v >= 1 and v <= 8192) size = @intFromFloat(v);
    }
    const ma = material.of(&scene.objects[ob]) orelse return app.log(bad, .{onm});
    const mi = scene.objects[ob].mat - 1;
    var found: [gops.NKINDS]u32 = @splat(0);
    for (map_kinds, 0..) |mk, k| {
        var b: [80]u8 = undefined;
        const nm = std.fmt.bufPrint(&b, "{s}{s}", .{ ma.nameOf(), mk.s }) catch return;
        var im = images.find(nm);
        if (im) |i| {
            // (one of that name and size: again)
            const e = &images.list[i];
            if (e.img.w != size or e.img.h != size or e.b8.len == 0) im = null;
        }
        const i = im orelse (images.new(nm, size, size, .{ 0.2158605, 0.2158605, 0.2158605, 1 }) catch return app.log(bad, .{onm}));
        _ = bake.bakeMaterial(ob, @intCast(k), i) orelse return app.log(bad, .{onm});
        found[mk.k] = @intCast(i + 1);
    }
    if (apply) {
        gops.clear(mi);
        gops.buildMaps(mi, &found, false, false);
    }
    material.version +%= 1;
    app.log("  baked: {s}", .{material.list[mi].nameOf()});
}

pub fn opMatBake() void {
    @import("jobui.zig").later(matBakeJob, "Baking the material", ops.arg, 0, 0);
}

/// The Material tab's Bake to Maps: material.bake <the object> 1024 apply.
pub fn opBakeActive() void {
    const a = matops.activeMesh() orelse return;
    var b: [80]u8 = undefined;
    const t = std.fmt.bufPrint(&b, "\"{s}\" 1024 apply", .{scene.objects[a].name()}) catch return;
    @import("jobui.zig").later(matBakeJob, "Baking the material", t, 0, 0);
    undo.label("Bake Material");
}

pub fn pollBake() ?[]const u8 {
    const a = matops.activeMesh() orelse return "Materials go on meshes: select a mesh object";
    if (material.of(&scene.objects[a]) == null) return "The object has no material";
    const me = @import("mods.zig").of(a) orelse return "The object has no mesh";
    return if (me.uv.len == 0) "The object has no UVs" else null;
}

// --- the Material tab -----------------------------------------------------------------------

/// An instance's parameters (matui.s inst_props): "Instance of <parent>", then
/// per parameter its name on the left, an override toggle at the right half and
/// the value after it (a number, a colour for a vector, an image for a
/// texture). Returns how high they are; an instance shows nothing else (its
/// values are the parent's).
pub fn instanceRows(salt: usize, bd: @import("gfx.zig").Rect, y0: i32, ma_i: usize) i32 {
    const ma = &material.list[ma_i];
    if (ma.parent == 0 or ma.parent > material.count) return 0;
    var f = bkit.Flow.begin("material.instance", salt, bd, y0);
    if (f.z) |z| describeInstance(z, bd, ma_i);
    return f.end() - y0;
}

fn describeInstance(z: *zui.Ui, bd: @import("gfx.zig").Rect, ma_i: usize) void {
    const ma = &material.list[ma_i];
    var b: [64]u8 = undefined;
    bkit.info(z, std.fmt.bufPrint(&b, "Instance of {s}", .{material.list[ma.parent - 1].nameOf()}) catch "Instance");
    var shown: u32 = 0;
    const half: f32 = @floatFromInt(@divTrunc(bd.w, 2));
    for (sg.nodesOf(ma)[0..sg.count(ma)], 1..) |*nd, n| {
        if (nd.type < 37 or nd.type > 39 or shown >= 16) continue;
        const row = shown;
        shown += 1;
        z.pushIdInt(n);
        defer z.popId();
        var nb: [24]u8 = undefined;
        const nm = gops.paramName(nd, &nb);
        bkit.beginCaptioned(z, nm, half - 3);
        defer bkit.endCaptioned(z);
        var on = gops.overridden(ma, @intCast(n));
        const c = bkit.checkRow(z, "##Override", &on, "Override: this instance keeps its own value (off: the parent's)");
        ui.record("override", nm, host.rectOf(c.rect), true); // (found by its parameter's name)
        if (c.changed) {
            if (on) gops.setParam(ma_i, @intCast(n), &nd.p) else gops.resetParam(ma_i, @intCast(n));
            undo.label("Material Parameter");
        }
        if (nd.type == 39) {
            // a texture parameter: its image
            var k: usize = if (nd.p[0] >= 1 and nd.p[0] <= @as(f32, @floatFromInt(images.count))) @intFromFloat(nd.p[0]) else 0;
            if (bkit.choice(z, "##Image", &k, images.count + 1, texLabel, "The parameter's image in this instance (overrides the parent's)")) {
                gops.setParam(ma_i, @intCast(n), &.{@floatFromInt(k)});
                undo.label("Material Parameter");
            }
        } else if (nd.type == 38) {
            // a vector parameter: a colour (BeeModel's picker, its changes in parColChanged)
            const cp = @import("colorpick.zig");
            if (!cp.open or cp_mat != ma_i or cp_row != row) par_col[row] = material.toSrgb(nd.p[0..3].*);
            const it = bkit.colourRow(z, nm, &par_col[row], parColChanged, "The parameter's colour in this instance (overrides the parent's)");
            if (it.clicked or (it.hovered and !cp.open)) { // (the row the picker opens for, or Ctrl+V pastes into)
                cp_mat = ma_i;
                cp_row = row;
                cp_node = @intCast(n);
            }
        } else {
            var v = nd.p[0];
            if (bkit.numberRow(z, "##Value", &v, .{ .step = 0.01, .min = -1000000, .max = 1000000, .decimals = 3, .tip = "The parameter's value in this instance (overrides the parent's)" }).changed) {
                var nv = nd.p;
                nv[0] = v;
                gops.setParam(ma_i, @intCast(n), &nv);
                undo.label("Material Parameter");
            }
        }
    }
}

var par_col: [16]u32 = @splat(0);
var cp_mat: usize = 0;
var cp_row: u32 = 0;
var cp_node: u32 = 0;
fn parColChanged() void {
    if (cp_mat >= material.count) return;
    const c = material.toLinear(par_col[cp_row]);
    var nv = sg.nodesOf(&material.list[cp_mat])[cp_node - 1].p;
    nv[0..3].* = c;
    gops.setParam(cp_mat, cp_node, &nv);
    undo.label("Material Parameter");
}

// the Texture row: a base colour image, box-projected

/// The image a material's base colour pin samples directly (+ 1), 0: none.
fn baseImage(ma: *const material.Material) u32 {
    const pin = sg.pinsOf(ma)[sg.PIN_BASE] & 0xffff;
    if (ma.nodes() == 0 or pin == 0 or pin > sg.count(ma)) return 0;
    const nd = &sg.nodesOf(ma)[pin - 1];
    if (nd.type != 1) return 0;
    const v = nd.p[0];
    return if (v >= 1 and v <= @as(f32, @floatFromInt(images.count))) @intFromFloat(v) else 0;
}
fn texLabel(k: usize) []const u8 {
    return if (k == 0) "None" else images.nameOf(k - 1);
}
/// The Material tab's Texture row, in `r` (BeeModel's layout places it): a
/// drop-down of the images. `id` is unused (the part is keyed by the material).
pub fn textureRow(id: u32, r: @import("gfx.zig").Rect, ma_i: usize) void {
    _ = id;
    const z = host.beginPart("material.texture", ma_i, r) orelse return;
    defer host.endPart(z);
    var k: usize = baseImage(&material.list[ma_i]);
    if (bkit.choice(z, "##Texture", &k, images.count + 1, texLabel, "An image as the base colour, projected from the sides of a box")) {
        setTexture(ma_i, if (k == 0) null else k - 1, 1);
        undo.label("Material Texture");
    }
}
