//! glTF 2.0 (gltf.s): export (.glb, or .gltf with its buffer in base64) and
//! import (.glb / .gltf with embedded, data: or external buffers), the
//! original's byte for byte.
//!
//! Export: a node per mesh object (its world place: translation, rotation as a
//! quaternion from the Rz Ry Rx Euler angles, scale), its evaluated mesh's
//! triangles (u32 indices) and positions (with min / max): a vertex a loop
//! when it has UVs (TEXCOORD_0, v down) or a lightmap; vertex colours as
//! COLOR_0 (linear); every material as metallic-roughness PBR with the
//! KHR_materials_ior / emissive_strength / transmission / clearcoat
//! extensions. Lights become KHR_lights_punctual point lights, cameras
//! perspective cameras. A baked lightmap goes along: the atlas as an embedded
//! PNG, each lightmapped object's second UVs as TEXCOORD_1 and a material of
//! its own whose MOZ_lightmap texture carries KHR_texture_transform (its
//! region in the atlas). Materials' maps go as embedded PNG textures: a pin
//! driven straight by a Texture Sample exports that image; a graph doing more
//! is baked (bake.zig, 512 x 512) through the UVs of an object using it into
//! base colour, ORM, normal and emissive maps. PNGs are written as the
//! original's encoder writes them (pngenc.zig).
//!
//! Import: the default scene's node tree (TRS or matrix) is walked (an
//! explicit stack of 32, last root first) and each triangle primitive becomes
//! an object with its world transform baked in; equal positions are welded;
//! TEXCOORD_0 (float, or normalized u8 / u16) becomes the mesh's UVs.
//! Materials map back to principled values, and their texture slots (base
//! colour, metallic-roughness, normal, occlusion, emissive; the first
//! KHR_texture_transform) to a graph of Texture Samples (graphops.gltf);
//! images come from data: URIs, files beside the .gltf or buffer views.
//!
//! Where the original reads out of bounds or loops (an accessor offset past
//! its view, a node tree that cycles) the port refuses that part instead.
const std = @import("std");
const json = @import("json.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const images = @import("images.zig");
const image = @import("image.zig");
const mods = @import("mods.zig");
const lightmap = @import("lightmap.zig");
const gops = @import("graphops.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const pngenc = @import("pngenc.zig");
const texture = @import("texture.zig");
const ax = @import("animexpr.zig");

const A = std.heap.page_allocator;

pub const list = .{
    .{ "file.import_gltf", ops.Impl{ .run = opImport } },
    .{ "file.export_gltf", ops.Impl{ .run = opExport } },
};

// ---- the original's float conversions ------------------------------------------------

/// cvttss2si: truncated; NaN and out of range give the "integer indefinite".
fn cvtt(x: f32) i32 {
    if (x >= -2147483648.0 and x < 2147483648.0) return @intFromFloat(x);
    return std.math.minInt(i32);
}

/// cvtss2si: rounded to nearest, ties to even.
fn cvtn(x: f32) i32 {
    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);
    const f = @floor(x);
    const d = x - f;
    var r = f;
    if (d > 0.5 or (d == 0.5 and @mod(f, 2) != 0)) r += 1;
    if (!(r < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(r);
}

/// minss / maxss: the second operand unless the first is smaller / larger
fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

/// mat_set: the value clamped by maxss / minss (a NaN: the lower bound),
/// written; false when there is no such parameter or material.
fn mset(mi: usize, p: usize, comp: usize, v: f32) void {
    const ma = material.get(mi) orelse return;
    if (p >= material.params.len or comp >= material.params[p].comps) return;
    const pr = material.params[p];
    material.ptr(ma, p, comp).* = minss(maxss(v, pr.lo), pr.hi);
    material.version +%= 1;
}

// =============================================================================
//  Export
// =============================================================================

const MAX_EXP = 4096;
const MAX_MATS = 256;
const MAX_XIMG = 64;
const XBAKE = 512;

const Exp = struct {
    obj: usize,
    ntri: u32,
    nv: u32,
    off: u64,
    uv: i32 = -1, // its UV accessor's number (-1: none)
    vc: i32 = -1, // its colour accessor's number
    lm: ?*const lightmap.Entry = null,
    lmk: u32 = 0,
    pl: bool = false, // a vertex a loop
};

/// a material's maps: image + 1 (0: none) for base, metallic-roughness,
/// normal, occlusion, emission; the normal map's scale
const Slots = struct { s: [5]u32 = @splat(0), scale: f32 = 1 };

const XImg = struct {
    px: []const [4]u8, // R G B A, top row first
    w: u32,
    h: u32,
    own: bool, // baked here: freed after
    idx: i32, // the scene's image (-1: made here)
    png: []u8 = &.{},
    off: u64 = 0,
    name: [32]u8 = @splat(0),
};

const X = struct {
    e: []Exp = &.{},
    n: usize = 0,
    nuv: u32 = 0,
    nvc: u32 = 0,
    nlm: u32 = 0,
    lt: [64]usize = undefined,
    nl: usize = 0,
    ct: [16]usize = undefined,
    nc: usize = 0,
    png: []u8 = &.{}, // the lightmap
    pngoff: u64 = 0,
    ms: [MAX_MATS]Slots = undefined,
    xi: [MAX_XIMG]XImg = undefined,
    nx: usize = 0,
    lmimg: u32 = 0,
    curm: i32 = -1,
    bin: []u8 = &.{},
    binlen: u64 = 0,
    own_bin: bool = false,
    glb: []u8 = &.{}, // a .glb: the file, the buffer inside it
    w: json.W = .{},
};

var ex: X = .{};

/// euler_quat: q = qz qy qx from the half angles' fsincos (each a float)
fn eulerQuat(r: [3]f32) [4]f32 {
    var s: [3]f32 = undefined;
    var c: [3]f32 = undefined;
    for (0..3) |k| {
        const sc = ax.sincos32(r[k] * 0.5);
        s[k] = sc[0];
        c[k] = sc[1];
    }
    return .{
        s[0] * c[1] * c[2] - c[0] * s[1] * s[2],
        c[0] * s[1] * c[2] + s[0] * c[1] * s[2],
        c[0] * c[1] * s[2] - s[0] * s[1] * c[2],
        c[0] * c[1] * c[2] + s[0] * s[1] * s[2],
    };
}

fn nums(v: []const f32) void {
    for (v, 0..) |f, k| {
        if (k > 0) ex.w.char(',');
        ex.w.num(f);
    }
}

fn int(v: i64) void {
    ex.w.int(v);
}

/// int_out: a 32-bit value, as the original's movsxd
fn int32(v: u64) void {
    ex.w.int(@as(i32, @bitCast(@as(u32, @truncate(v)))));
}

fn meshOf(e: *const Exp) ?*const scene.Mesh {
    const me = mods.of(e.obj) orelse return null;
    const nv: usize = if (e.pl) me.loops.len else me.verts.len;
    if (nv != e.nv or me.tris.len != e.ntri) return null; // (it changed under us)
    return me;
}

/// gltf_export: 0 written, < 0 an error, 2 nothing to export
pub fn exportFile(path: []const u8) i32 {
    @import("lcam.zig").sync();
    var es: std.ArrayList(Exp) = .empty;
    defer es.deinit(A);
    ex = .{};
    defer {
        texFree();
        if (ex.png.len > 0) A.free(ex.png);
        if (ex.own_bin) A.free(ex.bin);
        if (ex.glb.len > 0) A.free(ex.glb);
        ex.w.b.deinit(A);
        ex = .{};
    }
    const glb = path.len >= 4 and std.mem.eql(u8, path[path.len - 4 ..], ".glb");
    pngMake();
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.kind == .light and ex.nl < 64) {
            ex.lt[ex.nl] = i;
            ex.nl += 1;
        }
    }
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.kind == .camera and ex.nc < 16) {
            ex.ct[ex.nc] = i;
            ex.nc += 1;
        }
    }
    // the mesh objects and the buffer size
    var bytes: u64 = 0;
    const objmtl = @import("objmtl.zig");
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (!objmtl.wants(o)) continue;
        if (es.items.len >= MAX_EXP) break;
        const me = mods.of(i) orelse continue; // (the original reads a null mesh)
        var e = Exp{ .obj = i, .ntri = @intCast(me.tris.len), .nv = 0, .off = bytes };
        if (lightmap.find(o.oid)) |l| {
            if (me.loops.len == l.nloops and me.tris.len == l.ntris) {
                e.lm = l;
                e.lmk = ex.nlm;
                ex.nlm += 1;
            }
        }
        e.pl = e.lm != null;
        if (me.uv.len > 0) {
            e.uv = @intCast(ex.nuv);
            ex.nuv += 1;
            e.pl = true;
        }
        e.nv = @intCast(if (e.pl) me.loops.len else me.verts.len);
        bytes += @as(u64, e.nv) * 12 + @as(u64, e.ntri) * 12;
        if (e.uv >= 0) bytes += @as(u64, e.nv) * 8;
        if (me.vcol.len > 0 and me.vcol.len == me.verts.len) {
            e.vc = @intCast(ex.nvc);
            ex.nvc += 1;
            bytes += @as(u64, e.nv) * 12;
        }
        if (e.lm != null) bytes += @as(u64, e.nv) * 8;
        es.append(A, e) catch return -12;
    }
    ex.e = es.items;
    ex.n = es.items.len;
    if (ex.n == 0) return 2;
    bytes = (bytes + 3) & ~@as(u64, 3); // the PNG after it all (aligned)
    ex.pngoff = bytes;
    bytes += ex.png.len;
    texPlan(); // (materials' maps: their PNGs after)
    bytes = texPlace(bytes);
    ex.binlen = bytes;
    if (glb) { // the JSON first (it needs only the sizes), then the buffer in its place
        writeJson(true);
        glbStart() catch return -12;
    } else {
        ex.bin = A.alloc(u8, bytes) catch return -12;
        ex.own_bin = true;
    }
    @memset(ex.bin, 0);
    // fill the buffer
    for (ex.e) |*e| {
        const me = meshOf(e) orelse continue;
        const out = ex.bin[e.off..];
        if (e.pl) fillUv(out, me) else {
            @memcpy(out[0 .. me.verts.len * 12], std.mem.sliceAsBytes(me.verts));
            @memcpy(out[me.verts.len * 12 ..][0 .. me.tris.len * 12], std.mem.sliceAsBytes(me.tris));
        }
        if (e.vc >= 0) fillCol(ex.bin[colOff(e)..], me, e.pl);
        if (e.lm) |l| fillLm(ex.bin[lmOff(e)..], l);
    }
    if (ex.png.len > 0) @memcpy(ex.bin[ex.pngoff..][0..ex.png.len], ex.png);
    for (ex.xi[0..ex.nx]) |*im| {
        if (im.png.len > 0) @memcpy(ex.bin[im.off..][0..im.png.len], im.png);
    }
    if (!glb) writeJson(false);
    @import("bee.zig").writeAtomic(path, if (glb) ex.glb else ex.w.items()) catch return -5;
    return 0;
}

fn writeJson(glb: bool) void {
    const w = &ex.w;
    w.reset();
    w.raw("{\"asset\":{\"version\":\"2.0\",\"generator\":\"BeeModel\"},\"scene\":0,\"scenes\":[{\"nodes\":[");
    for (0..ex.n) |i| {
        if (i > 0) w.char(',');
        int(@intCast(i));
    }
    for (0..ex.nl) |k| {
        w.char(',');
        int(@intCast(ex.n + k));
    }
    for (0..ex.nc) |k| {
        w.char(',');
        int(@intCast(ex.n + ex.nl + k));
    }
    w.raw("]}],\"nodes\":[");
    for (ex.e, 0..) |*e, i| {
        if (i > 0) w.char(',');
        const o = &scene.objects[e.obj];
        const p = scene.worldPlace(e.obj);
        w.raw("{\"name\":");
        w.q(o.name());
        w.raw(",\"mesh\":");
        int(@intCast(i));
        w.raw(",\"translation\":[");
        nums(p[0..3]);
        w.raw("],\"rotation\":[");
        nums(&eulerQuat(p[3..6].*));
        w.raw("],\"scale\":[");
        nums(p[6..9]);
        w.raw("]}");
    }
    for (ex.lt[0..ex.nl], 0..) |oi, k| { // a node a light: its place, the light
        w.char(',');
        const p = scene.worldPlace(oi);
        w.raw("{\"name\":");
        w.q(scene.objects[oi].name());
        w.raw(",\"translation\":[");
        nums(p[0..3]);
        w.char(']');
        w.raw(",\"extensions\":{\"KHR_lights_punctual\":{\"light\":");
        int(@intCast(k));
        w.raw("}}}");
    }
    for (ex.ct[0..ex.nc], 0..) |oi, k| { // a node a camera: its place and turn
        w.char(',');
        const p = scene.worldPlace(oi);
        w.raw("{\"name\":");
        w.q(scene.objects[oi].name());
        w.raw(",\"camera\":");
        int(@intCast(k));
        w.raw(",\"translation\":[");
        nums(p[0..3]);
        w.raw("],\"rotation\":[");
        nums(&eulerQuat(p[3..6].*));
        w.raw("]}");
    }
    w.raw("],\"meshes\":[");
    const n: u32 = @intCast(ex.n);
    for (ex.e, 0..) |*e, i| {
        if (i > 0) w.char(',');
        const o = &scene.objects[e.obj];
        w.raw("{\"name\":");
        w.q(o.name());
        w.raw(",\"primitives\":[{\"attributes\":{\"POSITION\":");
        int32(i * 2);
        if (e.uv >= 0) {
            w.raw(",\"TEXCOORD_0\":");
            int32(@as(u64, @intCast(e.uv)) + n * 2);
        }
        if (e.vc >= 0) {
            w.raw(",\"COLOR_0\":");
            int32(@as(u64, @intCast(e.vc)) + n * 2 + ex.nuv);
        }
        if (e.lm != null) {
            if (e.uv < 0) { // (no UVs of its own: TEXCOORD_0 is them too)
                w.raw(",\"TEXCOORD_0\":");
                int32(lmAcc(e));
            }
            w.raw(",\"TEXCOORD_1\":");
            int32(lmAcc(e));
        }
        w.raw("},\"indices\":");
        int32(i * 2 + 1);
        if (e.lm != null) { // a lightmap: its own material
            w.raw(",\"material\":");
            int32(material.count + e.lmk);
        } else if (o.mat != 0) {
            w.raw(",\"material\":");
            int32(@as(u64, o.mat) -% 1);
        }
        w.raw("}]}");
    }
    if (material.count + ex.nlm > 0) {
        w.raw("],\"materials\":[");
        for (0..material.count) |k| {
            if (k > 0) w.char(',');
            ex.curm = @intCast(k);
            gxMat(&material.list[k], null);
        }
        var dm: material.Material = undefined;
        for (ex.e) |*e| { // the lightmapped objects' own
            const l = e.lm orelse continue;
            if (material.count + e.lmk != 0) w.char(',');
            const o = &scene.objects[e.obj];
            defaultMat(&dm);
            var rec: *const material.Material = &dm;
            ex.curm = -1;
            if (o.mat != 0) {
                ex.curm = @intCast(o.mat - 1);
                if (material.get(o.mat - 1)) |ma| rec = ma;
            }
            gxMat(rec, l);
        }
    }
    if (material.count + ex.nlm + ex.nl > 0) { // the extensions used
        w.raw("],\"extensionsUsed\":[");
        var k: u32 = 0;
        if (material.count + ex.nlm > 0) {
            w.raw("\"KHR_materials_ior\",\"KHR_materials_emissive_strength\",\"KHR_materials_transmission\",\"KHR_materials_clearcoat\"");
            k += 1;
        }
        if (ex.nl > 0) {
            if (k > 0) w.char(',');
            w.raw("\"KHR_lights_punctual\"");
            k += 1;
        }
        if (ex.nlm > 0) {
            if (k > 0) w.char(',');
            w.raw("\"KHR_texture_transform\",\"MOZ_lightmap\"");
        }
    }
    texJson(); // the lightmap, the maps: textures, samplers, images
    w.raw("],\"accessors\":[");
    for (ex.e, 0..) |*e, i| {
        if (i > 0) w.char(',');
        w.raw("{\"bufferView\":");
        int32(i * 2);
        w.raw(",\"componentType\":5126,\"type\":\"VEC3\",\"count\":");
        int32(e.nv);
        var lo: [3]f32 = @splat(@bitCast(@as(u32, 0x7f7fffff)));
        var hi: [3]f32 = @splat(@bitCast(@as(u32, 0xff7fffff)));
        var ntri: u64 = e.ntri;
        if (mods.of(e.obj)) |me| {
            for (me.verts) |v| {
                for (0..3) |c| {
                    lo[c] = minss(lo[c], v[c]);
                    hi[c] = maxss(hi[c], v[c]);
                }
            }
            ntri = me.tris.len;
        }
        w.raw(",\"min\":[");
        nums(&lo);
        w.raw("],\"max\":[");
        nums(&hi);
        w.raw("]}");
        w.char(',');
        w.raw("{\"bufferView\":");
        int32(i * 2 + 1);
        w.raw(",\"componentType\":5125,\"type\":\"SCALAR\",\"count\":");
        int32(ntri * 3);
        w.char('}');
    }
    for (ex.e) |*e| { // UV accessors (views 2n + k)
        if (e.uv < 0) continue;
        w.char(',');
        w.raw("{\"bufferView\":");
        int32(@as(u64, @intCast(e.uv)) + n * 2);
        w.raw(",\"componentType\":5126,\"type\":\"VEC2\",\"count\":");
        int32(e.nv);
        w.char('}');
    }
    for (ex.e) |*e| { // colour accessors
        if (e.vc < 0) continue;
        w.char(',');
        w.raw("{\"bufferView\":");
        int32(@as(u64, @intCast(e.vc)) + n * 2 + ex.nuv);
        w.raw(",\"componentType\":5126,\"type\":\"VEC3\",\"count\":");
        int32(e.nv);
        w.char('}');
    }
    for (ex.e) |*e| { // lightmap UV accessors
        if (e.lm == null) continue;
        w.char(',');
        w.raw("{\"bufferView\":");
        int32(lmAcc(e));
        w.raw(",\"componentType\":5126,\"type\":\"VEC2\",\"count\":");
        int32(e.nv);
        w.char('}');
    }
    w.raw("],\"bufferViews\":[");
    for (ex.e, 0..) |*e, i| {
        if (i > 0) w.char(',');
        const plen = @as(u64, e.nv) * 12;
        view(e.off, plen, 34962);
        w.char(',');
        view(e.off + @as(u32, @truncate(plen)), @as(u64, e.ntri) * 12, 34963);
    }
    for (ex.e) |*e| { // UV views: after the indices
        if (e.uv < 0) continue;
        w.char(',');
        view(e.off + @as(u64, e.nv) * 12 + @as(u64, e.ntri) * 12, @as(u64, e.nv) << 3, 34962);
    }
    for (ex.e) |*e| { // colour views: after the UVs
        if (e.vc < 0) continue;
        w.char(',');
        view(colOff(e), @as(u64, e.nv) * 12, 34962);
    }
    for (ex.e) |*e| { // lightmap UV views
        if (e.lm == null) continue;
        w.char(',');
        view(lmOff(e), @as(u64, e.nv) << 3, 34962);
    }
    if (ex.nlm > 0 and ex.png.len > 0) { // the PNG's view
        w.char(',');
        w.raw("{\"buffer\":0,\"byteOffset\":");
        int(@intCast(ex.pngoff));
        w.raw(",\"byteLength\":");
        int(@intCast(ex.png.len));
        w.char('}');
    }
    for (ex.xi[0..ex.nx]) |*im| { // the maps' views
        w.char(',');
        w.raw("{\"buffer\":0,\"byteOffset\":");
        int(@intCast(im.off));
        w.raw(",\"byteLength\":");
        int(@intCast(im.png.len));
        w.char('}');
    }
    w.raw("],\"buffers\":[{\"byteLength\":");
    int(@intCast(ex.binlen));
    if (!glb) {
        w.raw(",\"uri\":\"data:application/octet-stream;base64,");
        w.base64(ex.bin);
        w.char('"');
    }
    w.raw("}]");
    camJson();
    lightJson();
    w.char('}');
}

/// a buffer view: offset (64 bits), length (int_out: 32), target
fn view(off: u64, len: u64, target: u32) void {
    ex.w.raw("{\"buffer\":0,\"byteOffset\":");
    int(@intCast(off));
    ex.w.raw(",\"byteLength\":");
    int32(len);
    ex.w.raw(",\"target\":");
    int(target);
    ex.w.char('}');
}

/// gx_lm_acc: its lightmap UV accessor: 2n + UVs + colours + its number
fn lmAcc(e: *const Exp) u64 {
    return @as(u64, e.lmk) + ex.n * 2 + ex.nuv + ex.nvc;
}

/// gx_col_off: where its colours go: after positions, indices and UVs
fn colOff(e: *const Exp) u64 {
    var o = e.off + @as(u64, e.nv) * 12 + @as(u64, e.ntri) * 12;
    if (e.uv >= 0) o += @as(u64, e.nv) * 8;
    return o;
}

/// gx_lm_off: where its lightmap UVs go: after its colours
fn lmOff(e: *const Exp) u64 {
    var o = colOff(e);
    if (e.vc >= 0) o += @as(u64, e.nv) * 12;
    return o;
}

fn putF(out: []u8, k: usize, v: f32) void {
    std.mem.writeInt(u32, out[k * 4 ..][0..4], @bitCast(v), .little);
}
fn putU(out: []u8, k: usize, v: u32) void {
    std.mem.writeInt(u32, out[k * 4 ..][0..4], v, .little);
}

/// gx_fill_uv: a vertex a loop (its vertex's position), the triangles over
/// loops, then the loops' UVs (u, 1 - v)
fn fillUv(out: []u8, me: *const scene.Mesh) void {
    var k: usize = 0;
    for (me.loops) |v| {
        const p = me.verts[v];
        for (0..3) |c| putF(out, k + c, p[c]);
        k += 3;
    }
    for (me.tris, 0..) |t, ti| {
        const pi = me.tri_poly[ti];
        const s = me.poff[pi];
        const e = me.poff[pi + 1];
        for (0..3) |c| {
            var l = s;
            while (l < e and me.loops[l] != t[c]) l += 1;
            if (l >= e) l = s;
            putU(out, k, l);
            k += 1;
        }
    }
    if (me.uv.len == 0) return;
    for (me.uv) |t| {
        putF(out, k, t[0]);
        putF(out, k + 1, 1.0 - t[1]);
        k += 2;
    }
}

/// gx_fill_col: linear rgb floats, a vertex a vertex or a vertex a loop
fn fillCol(out: []u8, me: *const scene.Mesh, per_loop: bool) void {
    const nv = if (per_loop) me.loops.len else me.verts.len;
    for (0..nv) |i| {
        const v = if (per_loop) me.loops[i] else i;
        const c = me.vcol[v];
        for (0..3) |k| putF(out, i * 3 + k, texture.lut[@as(u8, @truncate(c >> @as(u5, @intCast(16 - 8 * k))))]);
    }
}

/// gx_fill_lm: its second UVs, (u, 1 - v)
fn fillLm(out: []u8, l: *const lightmap.Entry) void {
    for (l.uv[0..@min(l.uv.len, l.nloops)], 0..) |t, i| {
        putF(out, i * 2, t[0]);
        putF(out, i * 2 + 1, 1.0 - t[1]);
    }
}

/// gx_default_mat: what a mesh without a material shows, named "default"
fn defaultMat(d: *material.Material) void {
    const b: [*]u8 = @ptrCast(d);
    @memset(b[0..@sizeOf(material.Material)], 0);
    @memcpy(d.name[0..7], "default");
    d.base = .{ 0.8, 0.8, 0.8 };
    d.roughness = 0.5;
    d.ior = @bitCast(@as(u32, 0x3fb9999a));
    d.strength = 1;
    d.alpha = 1;
}

/// gx_mat: one material: metallic-roughness, emission, the extensions; with a
/// lightmap its MOZ_lightmap texture (texCoord 1), its region as
/// KHR_texture_transform
fn gxMat(ma: *const material.Material, lm: ?*const lightmap.Entry) void {
    const w = &ex.w;
    w.raw("{\"name\":");
    w.q(&ma.name);
    w.raw(",\"pbrMetallicRoughness\":{\"baseColorFactor\":[");
    if (slot(0) != 0) w.raw("1,1,1") else nums(&ma.base); // (a map: factor 1)
    w.char(',');
    w.num(ma.alpha);
    w.raw("],\"metallicFactor\":");
    w.num(if (slot(1) != 0) 1 else ma.metallic);
    w.raw(",\"roughnessFactor\":");
    w.num(if (slot(1) != 0) 1 else ma.roughness);
    tref(",\"baseColorTexture\":{\"index\":", 0);
    tref(",\"metallicRoughnessTexture\":{\"index\":", 1);
    w.raw("},\"emissiveFactor\":["); // colour x min(strength, 1)
    for (0..3) |c| {
        if (c > 0) w.char(',');
        const v: f32 = if (slot(4) != 0) 1 else ma.emission[c];
        w.num(v * minss(ma.strength, 1));
    }
    w.char(']');
    tref(",\"normalTexture\":{\"index\":", 2);
    tref(",\"occlusionTexture\":{\"index\":", 3);
    tref(",\"emissiveTexture\":{\"index\":", 4);
    const bm = cvtn(ma.blend); // alphaMode: masked, translucent (or opaque with alpha below 1)
    if (bm == 1) {
        w.raw(",\"alphaMode\":\"MASK\",\"alphaCutoff\":");
        w.num(if (ma.clip > 0) ma.clip else @bitCast(@as(u32, 0x3eaaaaab)));
    } else if (bm == 2 or !(ma.alpha >= 1)) w.raw(",\"alphaMode\":\"BLEND\"");
    if (!(ma.one_sided >= 0.5)) w.raw(",\"doubleSided\":true");
    w.raw(",\"extensions\":{\"KHR_materials_ior\":{\"ior\":");
    w.num(ma.ior);
    w.raw("},\"KHR_materials_emissive_strength\":{\"emissiveStrength\":");
    w.num(maxss(ma.strength, 1));
    w.raw("},\"KHR_materials_transmission\":{\"transmissionFactor\":");
    w.num(ma.transmission);
    w.raw("},\"KHR_materials_clearcoat\":{\"clearcoatFactor\":");
    w.num(ma.coat);
    w.raw(",\"clearcoatRoughnessFactor\":");
    w.num(ma.coat_rough);
    const l = lm orelse return w.raw("}}}");
    w.raw("},\"MOZ_lightmap\":{\"index\":0,\"texCoord\":1,\"intensity\":1,\"extensions\":{\"KHR_texture_transform\":{\"texCoord\":1,\"offset\":[");
    nums(l.rect[0..2]);
    w.raw("],\"scale\":[");
    nums(l.rect[2..4]);
    w.raw("]}}}}}");
}

/// gx_slot: the current material's texture in slot k + 1 (0: none)
fn slot(k: usize) u32 {
    if (ex.curm < 0 or ex.curm >= MAX_MATS) return 0;
    const s = ex.ms[@intCast(ex.curm)].s[k];
    return if (s == 0) 0 else s + ex.lmimg;
}

/// gx_tref: ,"<key>":{"index":t[,"scale":s]} when there is a map in the slot
fn tref(key: []const u8, k: usize) void {
    const s = slot(k);
    if (s == 0) return;
    ex.w.raw(key);
    int32(s - 1);
    if (k == 2) {
        ex.w.raw(",\"scale\":");
        ex.w.num(ex.ms[@intCast(ex.curm)].scale);
    }
    ex.w.char('}');
}

// ---- materials' maps --------------------------------------------------------------

// graph.s's layout of a material record
const GR_N = 128;
const GR_NODES = 160;
const NODE_SZ = 72;
const ND_IN = 4;
const ND_P = 52;
const GR_PINS = 3616;
const NPINS = 13;

fn rd(ma: *const material.Material, off: usize) u32 {
    const b: [*]const u8 = @ptrCast(ma);
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// graph_info for node > 0: what 1 its type, 2 the node feeding input k, 6 the
/// output feeding it; -1 when there is none
fn ginfo(ma: *const material.Material, node: u32, what: u32, k: u32) i64 {
    if (node == 0 or node > rd(ma, GR_N)) return -1;
    const nd = GR_NODES + (node - 1) * NODE_SZ;
    if (nd + NODE_SZ > @sizeOf(material.Material)) return -1;
    if (what == 1) return rd(ma, nd);
    if (k -% 1 >= 3) return -1;
    const l = rd(ma, nd + ND_IN + (k - 1) * 16);
    return if (what == 6) l >> 16 else l & 0xffff;
}

/// graph_value: value k (1..4) of a node (0: none)
fn gval(ma: *const material.Material, node: u32, k: u32) f32 {
    if (node == 0 or node > rd(ma, GR_N)) return 0;
    const nd = GR_NODES + (node - 1) * NODE_SZ;
    if (nd + NODE_SZ > @sizeOf(material.Material)) return 0;
    return @bitCast(rd(ma, nd + ND_P + (k - 1) * 4));
}

const Pin = struct { node: u32, out: u32 };

/// gx_pin: the node driving a pin (0: none) and which of its outputs
fn pinOf(ma: *const material.Material, p: u32) Pin {
    const v = rd(ma, GR_PINS + p * 4);
    if (v & 0xffff == 0) return .{ .node = 0, .out = 0 };
    return .{ .node = v & 0xffff, .out = v >> 16 };
}

/// ucomiss x, c then jne: equal, or unordered (NaN) as equal
fn eqish(v: f32, c: f32) bool {
    return !(v < c or v > c);
}

/// gx_direct: the 8-bit scene image a Texture Sample (or Texture Parameter)
/// node reads as glTF would: its UVs plain (unlinked, or a Texture Coordinate
/// node at 1 1 0 0), size 1
fn direct(ma: *const material.Material, node: u32) ?usize {
    const t = ginfo(ma, node, 1, 0);
    if (t != 1 and t != 39) return null;
    const uv = ginfo(ma, node, 2, 1);
    if (uv > 0) {
        const u: u32 = @intCast(uv);
        if (ginfo(ma, u, 1, 0) != 10) return null;
        if (!eqish(gval(ma, u, 1), 1) or !eqish(gval(ma, u, 2), 1) or !eqish(gval(ma, u, 3), 0) or !eqish(gval(ma, u, 4), 0)) return null;
    }
    const sz = gval(ma, node, 2);
    if (!eqish(sz, 0) and !eqish(sz, 1)) return null;
    const ix = cvtt(gval(ma, node, 1)) -% 1;
    if (ix < 0 or ix >= images.count) return null;
    const e = &images.list[@intCast(ix)];
    if (e.img.hdr or e.b8.len == 0) return null;
    return @intCast(ix);
}

/// gx_addimg: an image among the export's (once) -> its number + 1 (0: no
/// room; one made here is freed then)
fn addImg(im: XImg, name: []const u8) u32 {
    for (ex.xi[0..ex.nx], 0..) |*e, k| {
        if (!im.own and !e.own and e.idx == im.idx) return @intCast(k + 1);
    }
    if (ex.nx >= MAX_XIMG) {
        if (im.own) A.free(im.px);
        return 0;
    }
    var e = im;
    const n = @min(name.len, 31, std.mem.indexOfScalar(u8, name, 0) orelse name.len);
    @memcpy(e.name[0..n], name[0..n]);
    ex.xi[ex.nx] = e;
    ex.nx += 1;
    return @intCast(ex.nx);
}

fn sceneImg(ix: usize) XImg {
    const e = &images.list[ix];
    return .{ .px = e.b8, .w = e.img.w, .h = e.img.h, .own = false, .idx = @intCast(ix) };
}

/// gx_tex_plan: each material's slots, the images and their PNGs
fn texPlan() void {
    for (&ex.ms) |*q| q.* = .{};
    ex.nx = 0;
    for (0..@min(material.count, MAX_MATS)) |k| mplan(k);
    for (ex.xi[0..ex.nx]) |*im| {
        const px = A.alloc(u32, im.px.len) catch continue;
        defer A.free(px);
        for (im.px, px) |b, *p| p.* = @as(u32, b[3]) << 24 | @as(u32, b[0]) << 16 | @as(u32, b[1]) << 8 | b[2];
        im.png = pngenc.encode(A, im.w, im.h, px, true) catch &.{}; // (no PNG: an empty one, sadly)
    }
}

/// gx_mplan: a material's slots: maps used directly, else baked
fn mplan(k: usize) void {
    const ma = &material.list[k];
    const s = &ex.ms[k];
    s.scale = 1;
    if (@as(i32, @bitCast(rd(ma, GR_N))) <= 0) return; // a graph at all?
    var bake = false;
    const sg = @import("shgraph.zig");
    const pb = pinOf(ma, sg.PIN_BASE); // base colour: an image's colour
    if (pb.node > 0) {
        if (pb.out == 0) {
            if (direct(ma, pb.node)) |ix| s.s[0] = addImg(sceneImg(ix), images.nameOf(ix)) else bake = true;
        } else bake = true;
    }
    const pm = pinOf(ma, sg.PIN_METAL); // metallic B, roughness G: one image
    const pr = pinOf(ma, sg.PIN_ROUGH);
    if (pm.node | pr.node > 0) {
        const ok = blk: {
            if (pm.node == 0 or pr.node == 0 or pm.out != 3 or pr.out != 2) break :blk false;
            const a = direct(ma, pm.node) orelse break :blk false;
            const b = direct(ma, pr.node) orelse break :blk false;
            if (a != b) break :blk false;
            s.s[1] = addImg(sceneImg(a), images.nameOf(a));
            break :blk true;
        };
        if (!ok) bake = true;
    }
    const pa = pinOf(ma, sg.PIN_AO); // occlusion: an image's red
    if (pa.node > 0) {
        if (pa.out == 1) {
            if (direct(ma, pa.node)) |ix| s.s[3] = addImg(sceneImg(ix), images.nameOf(ix)) else bake = true;
        } else bake = true;
    }
    const pn = pinOf(ma, sg.PIN_NORMAL); // a Normal Map node (OpenGL) on an image's colour
    if (pn.node > 0) {
        const ok = blk: {
            if (ginfo(ma, pn.node, 1, 0) != 9) break :blk false;
            if (gval(ma, pn.node, 2) >= 0.5) break :blk false; // (comiss: a NaN passes)
            if (ginfo(ma, pn.node, 6, 1) != 0) break :blk false;
            const src = ginfo(ma, pn.node, 2, 1);
            if (src <= 0) break :blk false;
            const ix = direct(ma, @intCast(src)) orelse break :blk false;
            s.s[2] = addImg(sceneImg(ix), images.nameOf(ix));
            s.scale = gval(ma, pn.node, 1); // (its strength: the scale)
            break :blk true;
        };
        if (!ok) bake = true;
    }
    const pe = pinOf(ma, sg.PIN_EMIT); // emission: an image's colour
    if (pe.node > 0) {
        if (pe.out == 0) {
            if (direct(ma, pe.node)) |ix| s.s[4] = addImg(sceneImg(ix), images.nameOf(ix)) else bake = true;
        } else bake = true;
    }
    if (bake) mbake(k);
}

/// gx_mbake: its graph baked through the UVs of an object using it: base
/// colour, ORM (occlusion and both PBR maps), a normal map (when it drives the
/// normal), emission (when it drives it)
fn mbake(k: usize) void {
    const ob = for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (o.mat == 0 or o.mat - 1 != k) continue;
        const me = mods.of(i) orelse continue;
        if (me.uv.len > 0) break i;
    } else return;
    const ma = &material.list[k];
    const s = &ex.ms[k];
    s.* = .{}; // (nothing kept from the direct look)
    const sg = @import("shgraph.zig");
    const suffix = [_][]const u8{ "_base", "_orm", "_normal", "_emissive" };
    for (0..4) |kind| {
        if (kind == 2 and pinOf(ma, sg.PIN_NORMAL).node == 0) continue; // (normal, emission: only if driven)
        if (kind == 3 and pinOf(ma, sg.PIN_EMIT).node == 0) continue;
        const px = bakeOne(ob, @intCast(kind)) orelse continue;
        var nb: [64]u8 = undefined;
        const mn = ma.nameOf();
        const nm = std.fmt.bufPrint(&nb, "{s}{s}", .{ mn, suffix[kind] }) catch mn;
        const r = addImg(.{ .px = px, .w = XBAKE, .h = XBAKE, .own = true, .idx = -1 }, nm[0..@min(nm.len, 31)]);
        if (r == 0) continue;
        if (kind == 1) {
            s.s[1] = r; // (ORM: both slots)
            s.s[3] = r;
        } else s.s[if (kind == 3) 4 else kind] = r;
    }
}

/// One material bake (bake_material with bk_quiet: straight into a 512 x 512
/// image of no one's, no undo): its bytes, or null.
fn bakeOne(ob: usize, kind: u32) ?[][4]u8 {
    const bk = @import("bake.zig");
    const im = images.new("gltf bake", XBAKE, XBAKE, .{ 0, 0, 0, 0 }) catch return null;
    defer dropImage(im);
    @memset(images.list[im].b8, .{ 0, 0, 0, 0 });
    bk.quiet = true;
    defer bk.quiet = false;
    _ = bk.bakeMaterial(ob, kind, im) orelse return null;
    return A.dupe([4]u8, images.list[im].b8) catch null;
}

/// The bake's image goes again (the last one: nothing refers to it).
fn dropImage(im: usize) void {
    if (im + 1 != images.count) return;
    const e = &images.list[im];
    @import("layers.zig").free(e);
    e.img.deinit(std.heap.page_allocator);
    if (e.path.len > 0) A.free(e.path);
    if (e.b8.len > 0) A.free(e.b8);
    if (e.src.len > 0) A.free(e.src);
    images.count -= 1;
}

/// A material's map for another exporter (formats.s's MTL: gx_ms, gx_xidx,
/// gx_xname, gx_xpng after gx_tex_plan): the scene's image (-1: baked here),
/// its name, its PNG (the original's bytes; empty when it could not be made).
pub const MapImg = struct { idx: i32, name: []const u8, png: []const u8 };

/// gx_tex_plan for another exporter: every material's maps (bakes made now).
pub fn mapsPlan() void {
    ex = .{};
    texPlan();
}

/// The map in slot k (0 base, 1 metallic-roughness, 2 normal, 3 occlusion,
/// 4 emission) of material `mat`, after mapsPlan; null: none.
pub fn mapOf(mat: usize, k: usize) ?MapImg {
    if (mat >= MAX_MATS or k >= 5) return null;
    const sl = ex.ms[mat].s[k];
    if (sl == 0 or sl > ex.nx) return null;
    const im = &ex.xi[sl - 1];
    return .{ .idx = im.idx, .name = cstr(&im.name), .png = im.png };
}

/// gx_tex_free
pub fn mapsFree() void {
    texFree();
    ex = .{};
}

/// gx_tex_place: the maps' PNGs after the bytes so far (each aligned)
fn texPlace(b0: u64) u64 {
    ex.lmimg = if (ex.nlm != 0 and ex.png.len > 0) 1 else 0;
    var b = b0;
    for (ex.xi[0..ex.nx]) |*im| {
        b = (b + 3) & ~@as(u64, 3);
        im.off = b;
        b += im.png.len;
    }
    return b;
}

/// gx_tex_json: "textures", "samplers", "images" (the lightmap first)
fn texJson() void {
    const w = &ex.w;
    if (ex.lmimg == 0 and ex.nx == 0) return;
    w.raw("],\"textures\":[");
    var k: u32 = 0;
    if (ex.lmimg != 0) {
        w.raw("{\"sampler\":0,\"source\":0}");
        k += 1;
    }
    for (0..ex.nx) |i| {
        if (k > 0) w.char(',');
        k += 1;
        w.raw("{\"sampler\":1,\"source\":");
        int32(i + ex.lmimg);
        w.char('}');
    }
    w.raw("],\"samplers\":[{\"magFilter\":9729,\"minFilter\":9729,\"wrapS\":33071,\"wrapT\":33071},{\"magFilter\":9729,\"minFilter\":9987,\"wrapS\":10497,\"wrapT\":10497}],\"images\":[");
    k = 0;
    var v: u64 = ex.n * 2 + ex.nuv + ex.nvc + ex.nlm; // (views: the lightmap's, then ours)
    if (ex.lmimg != 0) {
        w.raw("{\"name\":\"lightmap\",\"mimeType\":\"image/png\",\"bufferView\":");
        int32(v);
        w.char('}');
        v += 1;
        k += 1;
    }
    for (ex.xi[0..ex.nx], 0..) |*im, i| {
        if (k > 0) w.char(',');
        k += 1;
        w.raw("{\"name\":");
        w.q(&im.name);
        w.raw(",\"mimeType\":\"image/png\",\"bufferView\":");
        int32(v + i);
        w.char('}');
    }
}

/// gx_tex_free: the PNGs and the baked images
fn texFree() void {
    for (ex.xi[0..ex.nx]) |*im| {
        if (im.png.len > 0) A.free(im.png);
        im.png = &.{};
        if (im.own) A.free(im.px);
        im.own = false;
    }
    ex.nx = 0;
}

/// gx_cam_json: perspective cameras: the vertical angle from the lens and the
/// render's aspect
fn camJson() void {
    if (ex.nc == 0) return;
    const w = &ex.w;
    w.raw(",\"cameras\":[");
    const rn = @import("render.zig");
    for (ex.ct[0..ex.nc], 0..) |oi, k| {
        if (k > 0) w.char(',');
        w.raw("{\"type\":\"perspective\",\"perspective\":{\"znear\":0.05,\"yfov\":");
        var lens: f32 = 50;
        if (@import("lcam.zig").get(scene.objects[oi].uid)) |r| lens = @bitCast(r.lens);
        const t: f32 = @as(f32, 18.0) / maxss(lens, 1.0); // tan(half the horizontal angle)
        const asp: f64 = @as(f64, @floatFromInt(@as(i32, @bitCast(rn.width)))) / @as(f64, @floatFromInt(@as(i32, @bitCast(rn.height))));
        const a = ax.atan2x87(t, asp);
        w.num(@floatCast(a + a));
        w.raw(",\"aspectRatio\":");
        w.num(@floatCast(asp));
        w.raw("}}");
    }
    w.char(']');
}

/// gx_light_list_json: KHR_lights_punctual: a white point light each
fn lightJson() void {
    if (ex.nl == 0) return;
    const w = &ex.w;
    w.raw(",\"extensions\":{\"KHR_lights_punctual\":{\"lights\":[");
    for (ex.lt[0..ex.nl], 0..) |oi, k| {
        if (k > 0) w.char(',');
        w.raw("{\"type\":\"point\",\"color\":[1,1,1],\"intensity\":");
        w.num(80);
        w.raw(",\"name\":");
        w.q(scene.objects[oi].name());
        w.char('}');
    }
    w.raw("]}}");
}

/// gx_png_make: a baked lightmap's atlas as PNG bytes (lm_png's sRGB bytes)
fn pngMake() void {
    if (lightmap.rgb.len == 0 or lightmap.rgb.len != @as(usize, lightmap.w) * lightmap.h) return;
    const px = A.alloc(u32, lightmap.rgb.len) catch return;
    defer A.free(px);
    for (lightmap.rgb, px) |c, *o| {
        var v: u32 = 0;
        for (c) |c0| {
            const s = linToSrgb(minss(maxss(c0, 0), 1));
            v = v << 8 | @as(u32, @bitCast(cvtt(s * 255.0 + 0.5)));
        }
        o.* = v | 0xff000000;
    }
    ex.png = pngenc.encode(A, lightmap.w, lightmap.h, px, false) catch &.{};
}

// fld dword [rdi+4]; fld dword [rdi]; fyl2x; fld st0; frndint; fsub st1, st0;
// fxch st1; f2xm1; fld1; faddp st1, st0; fscale; fstp st1; fstp dword [rdi]
export const bee_x87_powf: [28]u8 linksection(".text") = .{
    0xd9, 0x47, 0x04, 0xd9, 0x07, 0xd9, 0xf1, 0xd9, 0xc0, 0xd9, 0xfc, 0xdc, 0xe9, 0xd9,
    0xc9, 0xd9, 0xf0, 0xd9, 0xe8, 0xde, 0xc1, 0xd9, 0xfd, 0xdd, 0xd9, 0xd9, 0x1f, 0xc3,
};

/// a^b on the x87, the result rounded to a float once (lightmap.s lin_to_srgb)
fn powf87(a: f32, b: f32) f32 {
    if (@import("builtin").cpu.arch != .x86_64) return std.math.pow(f32, a, b);
    return run87(&bee_x87_powf, a, b);
}

fn run87(code: []const u8, a: f32, b: f32) f32 {
    var m: [2]f32 = .{ a, b };
    const f: *const fn (*[2]f32) callconv(.c) void = @ptrCast(code.ptr);
    f(&m);
    return m[0];
}

/// lin_to_srgb: 1.055 x^(1/2.4) - 0.055 (x87), x 12.92 at the dark end
fn linToSrgb(v: f32) f32 {
    if (!(v > 0.0031308)) return v * 12.92;
    return powf87(v, 0.41666666) * 1.055 - 0.055;
}

/// glb_wrap: the file made around the JSON (space padded) and a place for the
/// buffer (zero padded), which is filled there.
fn glbStart() !void {
    const jlen = ex.w.len();
    const jpad = (jlen + 3) & ~@as(usize, 3);
    const blen: usize = @intCast(ex.binlen);
    const bpad = (blen + 3) & ~@as(usize, 3);
    const o = try A.alloc(u8, 28 + jpad + bpad);
    ex.glb = o;
    const put = struct {
        fn f(b: []u8, pos: usize, v: u32) void {
            std.mem.writeInt(u32, b[pos..][0..4], v, .little);
        }
    }.f;
    put(o, 0, 0x46546c67); // "glTF"
    put(o, 4, 2);
    put(o, 8, @truncate(bpad + jpad + 28));
    put(o, 12, @truncate(jpad));
    put(o, 16, 0x4e4f534a); // "JSON"
    @memcpy(o[20..][0..jlen], ex.w.items());
    @memset(o[20 + jlen .. 20 + jpad], ' ');
    put(o, 20 + jpad, @truncate(bpad));
    put(o, 24 + jpad, 0x004e4942); // "BIN\0"
    ex.bin = o[28 + jpad ..][0..blen];
    @memset(o[28 + jpad + blen ..], 0);
}

// =============================================================================
//  Import
// =============================================================================

const MAX_BUF = 8;
const MAX_DEPTH = 32;
const MAX_GIMG = 64;

const I = struct {
    t: []const u8 = "", // the JSON text (its end: j_end)
    bufs: [MAX_BUF][]const u8 = @splat(""),
    own: [MAX_BUF]?[]u8 = @splat(null), // decoded data: URIs
    maps: [MAX_BUF]?[]const u8 = @splat(null), // files beside it (mapped)
    nbuf: u32 = 0,
    mats: [MAX_MATS]u32 = @splat(0), // glTF material -> ours + 1
    imgs: [MAX_GIMG]i32 = @splat(0), // glTF image -> ours + 1 (-1: failed)
    gt: gops.Gt = .{},
    tt: bool = false, // a texture transform was read
    nobj: u32 = 0,
    glb_bin: bool = false, // a GLB's BIN chunk is buffer 0
    dir: [512]u8 = @splat(0),
    dirlen: usize = 0,
    // the top arrays' elements, by index (jidx, without walking them again)
    acc: []usize = &.{},
    views: []usize = &.{},
    nodes: []usize = &.{},
    meshes: []usize = &.{},
};

var g: I = .{};
/// gi_name: the shared name buffer (C string; what j_str last wrote stays)
var gi_name: [64]u8 = @splat(0);

fn cstr(b: []const u8) []const u8 {
    return b[0 .. std.mem.indexOfScalar(u8, b, 0) orelse b.len];
}

/// j_str into dest with this capacity: the length (> 0 ok), -1 not a string;
/// the text NUL-terminated, as the original's
fn jstr(v: usize, dest: []u8, cap: usize) i32 {
    const s = json.str(g.t, v, dest[0..cap]) orelse return -1;
    dest[s.len] = 0;
    return @intCast(s.len);
}

/// jint: the integer value (cvttss2si of its float), -1 when none
fn jint(v: ?usize) i32 {
    const p = v orelse return -1;
    const n = json.num(g.t, p);
    if (!n.ok) return -1;
    return cvtt(n.v);
}

fn find(obj: ?usize, key: []const u8) ?usize {
    return json.find(g.t, obj orelse return null, key);
}

fn top(key: []const u8) ?usize {
    return json.find(g.t, 0, key);
}

/// jidx: that element of the array, or null (an index as unsigned)
fn jidx(arr: ?usize, idx: i32) ?usize {
    var e = json.first(g.t, arr orelse return null);
    var k: u32 = @bitCast(idx);
    while (e) |p| {
        if (k == 0) return p;
        e = json.next(g.t, p);
        k -= 1;
    }
    return null;
}

/// the elements of a top array, listed once
fn listOf(key: []const u8) []usize {
    var l: std.ArrayList(usize) = .empty;
    var e = json.first(g.t, top(key) orelse return &.{});
    while (e) |p| {
        l.append(A, p) catch break;
        e = json.next(g.t, p);
    }
    return l.toOwnedSlice(A) catch &.{};
}

fn at(l: []const usize, idx: i32) ?usize {
    if (idx < 0 or idx >= l.len) return null;
    return l[@intCast(idx)];
}

/// jfloats: up to out.len numbers (j_num each, not-numbers as theirs) -> how many
fn jfloats(v: ?usize, out: []f32) usize {
    var e = json.first(g.t, v orelse return 0);
    var n: usize = 0;
    while (e) |p| {
        if (n >= out.len) break;
        out[n] = json.num(g.t, p).v;
        n += 1;
        e = json.next(g.t, p);
    }
    return n;
}

const M = [12]f32; // 3 x 4 affine, rows
const ident: M = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };

/// mat_mul: out = a b
fn matMul(a: *const M, b: *const M) M {
    var o: M = undefined;
    for (0..3) |r| {
        for (0..4) |c| {
            var s = a[r * 4] * b[c] + a[r * 4 + 1] * b[4 + c];
            s = s + a[r * 4 + 2] * b[8 + c];
            if (c == 3) s = s + a[r * 4 + 3];
            o[r * 4 + c] = s;
        }
    }
    return o;
}

/// node_local: its matrix (column major 4 x 4), or T R S
fn nodeLocal(nd: usize) M {
    var o = ident;
    var mm: [16]f32 = undefined;
    if (find(nd, "matrix")) |mv| {
        if (jfloats(mv, &mm) >= 16) {
            for (0..3) |r| {
                for (0..4) |c| o[r * 4 + c] = mm[c * 4 + r];
            }
            return o;
        }
    }
    var t: [3]f32 = .{ 0, 0, 0 };
    var q: [4]f32 = .{ 0, 0, 0, 1 };
    var s: [3]f32 = .{ 1, 1, 1 };
    _ = jfloats(find(nd, "translation"), &t);
    _ = jfloats(find(nd, "rotation"), &q);
    _ = jfloats(find(nd, "scale"), &s);
    const qx = q[0];
    const qy = q[1];
    const qz = q[2];
    const qw = q[3];
    o[0] = 1.0 - dbl(qy * qy + qz * qz);
    o[1] = dbl(qx * qy - qz * qw);
    o[2] = dbl(qx * qz + qy * qw);
    o[4] = dbl(qx * qy + qz * qw);
    o[5] = 1.0 - dbl(qx * qx + qz * qz);
    o[6] = dbl(qy * qz - qx * qw);
    o[8] = dbl(qx * qz - qy * qw);
    o[9] = dbl(qy * qz + qx * qw);
    o[10] = 1.0 - dbl(qx * qx + qy * qy);
    for (0..3) |r| {
        for (0..3) |c| o[r * 4 + c] *= s[c];
        o[r * 4 + 3] = t[r];
    }
    return o;
}

fn dbl(v: f32) f32 {
    return v + v;
}

/// xform_point
fn xpt(mt: *const M, p: [3]f32) [3]f32 {
    var o: [3]f32 = undefined;
    for (0..3) |r| {
        var s = mt[r * 4] * p[0] + mt[r * 4 + 1] * p[1];
        s = s + mt[r * 4 + 2] * p[2];
        o[r] = s + mt[r * 4 + 3];
    }
    return o;
}

const Acc = struct { ptr: []const u8 = "", stride: u32 = 0, count: u32 = 0, ctype: i32 = 0 };

/// accessor: its data (from its offset to its view's end), stride, count,
/// component type; null when it cannot be had. (The original's 32-bit sums;
/// an offset past the view's end, which it reads out of bounds, is refused.)
fn accessor(idx: i32) ?Acc {
    const a = at(g.acc, idx) orelse return null;
    var r = Acc{};
    const cnt = jint(find(a, "count"));
    if (cnt < 0) return null;
    r.count = @intCast(cnt);
    r.ctype = jint(find(a, "componentType"));
    const aoff: i32 = if (find(a, "byteOffset")) |v| jint(v) else 0;
    const bv = jint(find(a, "bufferView"));
    if (bv < 0) return null;
    const v = at(g.views, bv) orelse return null;
    const b: u32 = @bitCast(jint(find(v, "buffer")));
    if (b >= g.nbuf) return null;
    const voff: i32 = if (find(v, "byteOffset")) |p| jint(p) else 0;
    const off32: u32 = @bitCast(aoff +% voff);
    const vlen = jint(find(v, "byteLength"));
    if (vlen < 0) return null;
    r.stride = @bitCast(if (find(v, "byteStride")) |p| jint(p) else 0);
    const end32: u32 = @bitCast(voff +% vlen);
    const buf = g.bufs[b];
    if (end32 > buf.len) return null;
    if (@as(i32, @bitCast(end32 -% off32)) < 0) return null;
    if (off32 > end32) return null; // (the original: out of bounds)
    r.ptr = buf[off32..end32];
    return r;
}

fn f32at(d: []const u8, o: usize) f32 {
    return @bitCast(std.mem.readInt(u32, d[o..][0..4], .little));
}

/// read_index
fn readIndex(a: *const Acc, i: usize) u32 {
    return switch (a.ctype) {
        5125 => std.mem.readInt(u32, a.ptr[i * 4 ..][0..4], .little),
        5123 => std.mem.readInt(u16, a.ptr[i * 2 ..][0..2], .little),
        else => a.ptr[i],
    };
}

const Scratch = struct {
    verts: std.ArrayList([3]f32) = .empty,
    map: std.ArrayList(u32) = .empty,
    slots: std.ArrayList(u32) = .empty,
    loops: std.ArrayList(u32) = .empty,
    poff: std.ArrayList(u32) = .empty,
    corner: std.ArrayList(u32) = .empty,
    fn deinit(s: *Scratch) void {
        s.verts.deinit(A);
        s.map.deinit(A);
        s.slots.deinit(A);
        s.loops.deinit(A);
        s.poff.deinit(A);
        s.corner.deinit(A);
    }
};
var scr: Scratch = .{};

/// primitive: one triangle primitive as an object (its world matrix baked in)
fn primitive(pr: usize, wm: *const M) void {
    if (find(pr, "mode")) |mv| { // triangles only
        if (jint(mv) != 4) return;
    }
    const attrs = find(pr, "attributes") orelse return;
    const pi = jint(find(attrs, "POSITION"));
    if (pi < 0) return;
    var pos = accessor(pi) orelse return;
    if (pos.ctype != 5126) return;
    if (pos.stride == 0) pos.stride = 12;
    if (pos.count == 0) return;
    if (@as(u64, pos.count - 1) * pos.stride + 12 > pos.ptr.len) return;
    var ind: ?Acc = null;
    if (find(pr, "indices")) |iv| {
        const ii = jint(iv);
        if (ii < 0) return;
        const a = accessor(ii) orelse return;
        const es: u64 = switch (a.ctype) {
            5121 => 1,
            5123 => 2,
            5125 => 4,
            else => return,
        };
        if (@as(u64, a.count) * es > a.ptr.len) return;
        ind = a;
    }
    const uva = primUvs(attrs, pos.count);
    const corners: u32 = if (ind) |a| a.count else pos.count;
    const ntri = corners / 3;
    if (ntri == 0) return;
    // the positions welded (equal bits after the transform)
    scr.verts.clearRetainingCapacity();
    scr.map.resize(A, pos.count) catch return;
    // (2^k > 2 count: bsr of 2 count, + 1)
    const hsize: usize = @as(usize, 1) << @intCast(std.math.log2_int(u64, @as(u64, pos.count) * 2) + 1);
    scr.slots.resize(A, hsize) catch return;
    @memset(scr.slots.items, 0);
    const mask: u32 = @intCast(hsize - 1);
    for (0..pos.count) |i| {
        const o = i * pos.stride;
        const p = xpt(wm, .{ f32at(pos.ptr, o), f32at(pos.ptr, o + 4), f32at(pos.ptr, o + 8) });
        const b: [3]u32 = @bitCast(p);
        var h = b[0] *% 0x2545f491;
        h ^= b[1];
        h *%= 0x2545f491;
        h ^= b[2];
        h *%= 0x2545f491;
        h = (h >> 7) & mask;
        while (true) {
            const sv = scr.slots.items[h];
            if (sv == 0) {
                scr.verts.append(A, p) catch return;
                const nv: u32 = @intCast(scr.verts.items.len);
                scr.slots.items[h] = nv;
                scr.map.items[i] = nv - 1;
                break;
            }
            const q: [3]u32 = @bitCast(scr.verts.items[sv - 1]);
            if (q[0] == b[0] and q[1] == b[1] and q[2] == b[2]) {
                scr.map.items[i] = sv - 1;
                break;
            }
            h = (h + 1) & mask;
        }
    }
    // the triangles (degenerate ones dropped)
    scr.loops.clearRetainingCapacity();
    scr.poff.clearRetainingCapacity();
    scr.corner.clearRetainingCapacity();
    scr.poff.append(A, 0) catch return;
    for (0..ntri) |t| {
        var cv: [3]u32 = undefined; // glTF vertices
        var mv: [3]u32 = undefined; // ours
        var ok = true;
        for (0..3) |k| {
            const ci = t * 3 + k;
            const vi: u32 = if (ind) |*a| readIndex(a, ci) else @intCast(ci);
            if (vi >= pos.count) {
                ok = false;
                break;
            }
            cv[k] = vi;
            mv[k] = scr.map.items[vi];
        }
        if (!ok) continue;
        if (mv[0] == mv[1] or mv[0] == mv[2] or mv[1] == mv[2]) continue;
        scr.loops.appendSlice(A, &mv) catch return;
        scr.poff.append(A, @intCast(scr.loops.items.len)) catch return;
        if (uva != null) scr.corner.appendSlice(A, &cv) catch return;
    }
    if (scr.poff.items.len < 2) return;
    const mi = scene.addMesh(scr.verts.items, scr.poff.items, scr.loops.items) orelse return;
    if (uva) |*ua| { // its UVs: (u, 1 - v) a loop
        if (scene.meshes[mi]) |*me| {
            if (@import("alloc.zig").A.alloc([2]f32, scr.corner.items.len)) |uv| {
                fillUvs(uv, ua, scr.corner.items);
                me.uv = uv;
            } else |_| {}
        }
    }
    const oi = @import("bs_cad.zig").objNew(.mesh, cstr(&gi_name), mi, 0xb4b8c0) orelse {
        if (scene.meshes[mi]) |*me| scene.freeMesh(me);
        scene.freeMeshSlot(mi);
        return;
    };
    g.nobj += 1;
    const m = jint(find(pr, "material")); // its material
    if (m < 0 or m >= MAX_MATS) return;
    const k = g.mats[@intCast(m)];
    if (k == 0) return;
    scene.objects[oi].mat = @intCast(k);
}

/// prim_uvs: TEXCOORD_0, if usable: floats, or normalized u8 / u16, at least
/// as many as positions
fn primUvs(attrs: usize, npos: u32) ?Acc {
    const v = find(attrs, "TEXCOORD_0") orelse return null;
    const ti = jint(v);
    if (ti < 0) return null;
    var a = accessor(ti) orelse return null;
    const es: u32 = switch (a.ctype) {
        5126 => 8,
        5123 => 4,
        5121 => 2,
        else => return null,
    };
    if (a.stride == 0) a.stride = es;
    if (a.count < npos or a.count == 0) return null;
    if (@as(u64, a.count - 1) * a.stride + es > a.ptr.len) return null;
    return a;
}

/// fill_uvs: (u, 1 - v) for each loop's glTF vertex
fn fillUvs(out: [][2]f32, a: *const Acc, corner: []const u32) void {
    for (corner, out) |vi, *o| {
        const p = @as(usize, vi) * a.stride;
        var u: f32 = undefined;
        var v: f32 = undefined;
        switch (a.ctype) {
            5126 => {
                u = f32at(a.ptr, p);
                v = f32at(a.ptr, p + 4);
            },
            5123 => {
                u = @as(f32, @floatFromInt(std.mem.readInt(u16, a.ptr[p..][0..2], .little))) / 65535.0;
                v = @as(f32, @floatFromInt(std.mem.readInt(u16, a.ptr[p + 2 ..][0..2], .little))) / 65535.0;
            },
            else => {
                u = @as(f32, @floatFromInt(a.ptr[p])) / 255.0;
                v = @as(f32, @floatFromInt(a.ptr[p + 1])) / 255.0;
            },
        }
        o.* = .{ u, 1.0 - v };
    }
}

// ---- materials ---------------------------------------------------------------------

/// materials: ours for each glTF material (gi_mats: index + 1)
fn materials() void {
    g.mats = @splat(0);
    g.imgs = @splat(0);
    var e = json.first(g.t, top("materials") orelse return);
    var k: usize = 0;
    while (e) |gm| : (e = json.next(g.t, gm)) {
        if (k >= MAX_MATS) return;
        var nm: []const u8 = "glTF material";
        if (find(gm, "name")) |v| {
            if (jstr(v, &gi_name, 27) > 0) nm = cstr(&gi_name);
        }
        const mi = material.new(nm) orelse return;
        g.mats[k] = @intCast(mi + 1);
        if (find(gm, "pbrMetallicRoughness")) |pbr| {
            var c: [4]f32 = .{ 0, 0, 0, 1 };
            if (jfloats(find(pbr, "baseColorFactor"), &c) >= 3) {
                for (0..3) |i| mset(mi, 0, i, c[i]);
                mset(mi, 10, 0, c[3]); // alpha
            }
            factor(mi, pbr, 1, "metallicFactor"); // (glTF's default 1)
            factor(mi, pbr, 2, "roughnessFactor");
        }
        if (find(gm, "alphaMode")) |v| { // MASK (its cutoff), BLEND
            _ = jstr(v, &gi_name, 27);
            const s = cstr(&gi_name);
            if (std.mem.eql(u8, s, "MASK")) {
                mset(mi, 12, 0, 1);
                var cut: f32 = 0.5; // (glTF's default cutoff)
                if (find(gm, "alphaCutoff")) |cv| cut = json.num(g.t, cv).v;
                mset(mi, 14, 0, cut);
            } else if (std.mem.eql(u8, s, "BLEND")) mset(mi, 12, 0, 2);
        }
        var em: [3]f32 = undefined;
        if (jfloats(find(gm, "emissiveFactor"), &em) >= 3) { // emission
            for (0..3) |i| mset(mi, 6, i, em[i]);
            const mx = maxss(maxss(em[0], em[1]), em[2]);
            if (mx > 0) mset(mi, 7, 0, 1); // (strength 1 when any colour)
        }
        if (find(gm, "extensions")) |ext| {
            extFactor(mi, ext, "KHR_materials_emissive_strength", "emissiveStrength", 7);
            extFactor(mi, ext, "KHR_materials_transmission", "transmissionFactor", 5);
            extFactor(mi, ext, "KHR_materials_ior", "ior", 4);
            extFactor(mi, ext, "KHR_materials_clearcoat", "clearcoatFactor", 8);
            extFactor(mi, ext, "KHR_materials_clearcoat", "clearcoatRoughnessFactor", 9);
        }
        matTex(gm, mi);
        k += 1;
    }
}

/// factor: a number (1 when absent)
fn factor(mi: usize, pbr: usize, p: usize, key: []const u8) void {
    const v: f32 = if (find(pbr, key)) |n| json.num(g.t, n).v else 1;
    mset(mi, p, 0, v);
}

fn extFactor(mi: usize, ext: usize, xname: []const u8, key: []const u8, p: usize) void {
    const e = find(ext, xname) orelse return;
    const v = find(e, key) orelse return;
    const n = json.num(g.t, v);
    if (!n.ok) return;
    mset(mi, p, 0, n.v);
}

/// gt_num: a number, when there is one
fn gtNum(obj: usize, key: []const u8, out: *f32) void {
    const v = find(obj, key) orelse return;
    const n = json.num(g.t, v);
    if (n.ok) out.* = n.v;
}

/// gmat_tex: its texture maps as a graph
fn matTex(gm: usize, mi: usize) void {
    g.gt = .{};
    g.tt = false;
    if (find(gm, "pbrMetallicRoughness")) |pbr| {
        g.gt.base = gtex(find(pbr, "baseColorTexture"));
        if (find(pbr, "baseColorFactor")) |v| _ = jfloats(v, &g.gt.basef);
        gtNum(pbr, "metallicFactor", &g.gt.metalf);
        gtNum(pbr, "roughnessFactor", &g.gt.roughf);
        g.gt.mr = gtex(find(pbr, "metallicRoughnessTexture"));
    }
    const nt = find(gm, "normalTexture");
    g.gt.nrm = gtex(nt);
    if (g.gt.nrm != 0) gtNum(nt.?, "scale", &g.gt.nscale);
    g.gt.occ = gtex(find(gm, "occlusionTexture"));
    g.gt.emi = gtex(find(gm, "emissiveTexture"));
    if (find(gm, "emissiveFactor")) |v| _ = jfloats(v, &g.gt.emif);
    g.gt.alpha = @bitCast(cvtt(material.list[mi].blend));
    if (g.gt.base | g.gt.mr | g.gt.nrm | g.gt.occ | g.gt.emi != 0) gops.gltf(mi, &g.gt);
}

/// gtex: a textureInfo's image + 1 (0: none); the first KHR_texture_transform
/// met sets the tiling and offset (glTF's v runs down: offset v = 1 - oy - sy)
fn gtex(info: ?usize) u32 {
    const ti = info orelse return 0;
    const idx = jint(find(ti, "index") orelse return 0);
    if (idx < 0) return 0;
    const tex = jidx(top("textures"), idx) orelse return 0;
    const sv = find(tex, "source") orelse return 0;
    const src = jint(sv);
    if (src < 0) return 0;
    const im = gimage(src);
    if (im < 0) return 0;
    const r: u32 = @intCast(im + 1);
    if (!g.tt) {
        const tt = find(find(ti, "extensions"), "KHR_texture_transform") orelse return r;
        g.tt = true;
        if (find(tt, "scale")) |s| _ = jfloats(s, &g.gt.tile);
        var o: [2]f32 = undefined;
        if (find(tt, "offset")) |ov| {
            if (jfloats(ov, &o) >= 2) {
                g.gt.off[0] = o[0];
                g.gt.off[1] = (1.0 - o[1]) - g.gt.tile[1];
                return r;
            }
        }
        g.gt.off[1] = 1.0 - g.gt.tile[1]; // (no offset: still 1 - sy)
    }
    return r;
}

fn hexval(c: u8) i32 {
    if (c < '0') return -1;
    if (c <= '9') return c - '0';
    const l = c | 0x20;
    if (l < 'a' or l > 'f') return -1;
    return l - 'a' + 10;
}

/// The text after ";base64," from v on (to the text's end), or null.
fn b64After(v: usize) ?usize {
    const k = std.mem.indexOfPos(u8, g.t, v, ";base64,") orelse return null;
    return k + 8;
}

/// b64_in: bytes until the first character that is not base64
fn b64In(from: usize, out: *std.ArrayList(u8)) !void {
    var bits: u5 = 0;
    var acc: u32 = 0;
    for (g.t[from..]) |c| {
        const d: u32 = switch (c) {
            'A'...'Z' => c - 'A',
            'a'...'z' => c - 'a' + 26,
            '0'...'9' => c - '0' + 52,
            '+' => 62,
            '/' => 63,
            else => break,
        };
        acc = acc << 6 | d;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            try out.append(A, @truncate(acc >> bits));
        }
    }
}

fn isData(v: usize) bool {
    return v + 1 <= g.t.len and std.mem.startsWith(u8, g.t[v + 1 ..], "data:");
}

/// gimage: a glTF image as ours (loaded once) or -1: a data: URI, a file
/// beside the .gltf, or a buffer view
fn gimage(idx: i32) i32 {
    if (idx >= MAX_GIMG) return -1;
    const u: usize = @intCast(idx);
    if (g.imgs[u] != 0) return g.imgs[u] - 1;
    const r = gimage1(idx);
    g.imgs[u] = if (r < 0) -1 else r + 1;
    return r;
}

fn gimage1(idx: i32) i32 {
    const im = jidx(top("images"), idx) orelse return -1;
    @memcpy(gi_name[0..11], "glTF image\x00"); // its name (else "glTF image")
    if (find(im, "name")) |v| {
        if (jstr(v, &gi_name, 27) <= 0) @memcpy(gi_name[0..11], "glTF image\x00");
    }
    if (find(im, "uri")) |uv| {
        if (isData(uv)) {
            const from = b64After(uv) orelse return -1;
            var d: std.ArrayList(u8) = .empty;
            defer d.deinit(A);
            b64In(from, &d) catch return -1;
            return adopt(d.items, null);
        }
        var nb: [256]u8 = undefined; // a file beside the .gltf (%20 and the like decoded)
        if (jstr(uv, &nb, 250) <= 0) return -1;
        var pb: [800]u8 = undefined;
        @memcpy(pb[0..g.dirlen], g.dir[0..g.dirlen]);
        var o = g.dirlen;
        var i: usize = 0;
        while (true) : (i += 1) {
            var c = nb[i];
            if (c == '%') {
                const h1 = hexval(nb[i + 1]);
                const h2 = if (h1 >= 0) hexval(nb[i + 2]) else -1;
                if (h1 >= 0 and h2 >= 0) {
                    c = @intCast(h1 << 4 | h2);
                    i += 2;
                }
            }
            pb[o] = c;
            o += 1;
            if (c == 0) break;
        }
        const path = cstr(pb[0..o]);
        const k = @import("usdmat.zig").load(path) orelse return -1;
        return @intCast(k);
    }
    const bv = jint(find(im, "bufferView") orelse return -1); // a buffer view
    if (bv < 0) return -1;
    const d = bufview(bv) orelse return -1;
    return adopt(d, d); // (its bytes kept: saved as they are)
}

/// img_decode then image_adopt_src: an image of the scene made of these bytes
fn adopt(d: []const u8, src: ?[]const u8) i32 {
    const img = image.decodeData(A, d) catch return -1;
    const i = images.adoptDecoded(cstr(&gi_name), img, src) catch return -1;
    return @intCast(i);
}

/// bufview: a view's bytes, or null
fn bufview(idx: i32) ?[]const u8 {
    const v = at(g.views, idx) orelse return null;
    const b = jint(find(v, "buffer"));
    if (b < 0 or b >= g.nbuf) return null;
    var off: u64 = 0;
    if (find(v, "byteOffset")) |p| {
        const o = jint(p);
        if (o < 0) return null;
        off = @intCast(o);
    }
    const len = jint(find(v, "byteLength"));
    if (len <= 0) return null;
    const buf = g.bufs[@intCast(b)];
    if (@as(u64, @intCast(len)) + off > buf.len) return null;
    return buf[off..][0..@intCast(len)];
}

// ---- the file -------------------------------------------------------------------------

/// buffers: false when one cannot be had
fn buffers() bool {
    var e = json.first(g.t, top("buffers") orelse return true);
    while (e) |b| : (e = json.next(g.t, b)) {
        const k = g.nbuf;
        if (k >= MAX_BUF) return true;
        if (jint(find(b, "byteLength")) < 0) return false;
        if (find(b, "uri")) |uv| {
            if (isData(uv)) {
                const from = b64After(uv) orelse return false;
                var d: std.ArrayList(u8) = .empty;
                b64In(from, &d) catch {
                    d.deinit(A);
                    return false;
                };
                const own = d.toOwnedSlice(A) catch return false;
                g.own[k] = own;
                g.bufs[k] = own;
            } else { // a file next to the .gltf
                if (jstr(uv, &gi_name, 60) <= 0) return false;
                var pb: [600]u8 = undefined;
                const path = std.fmt.bufPrint(&pb, "{s}{s}", .{ g.dir[0..g.dirlen], cstr(&gi_name) }) catch return false;
                const f = readFile(path) orelse return false;
                g.maps[k] = f;
                g.bufs[k] = f;
            }
        } else if (k != 0 or !g.glb_bin) return false; // (no uri: the GLB's BIN chunk)
        g.nbuf += 1;
    }
    return true;
}

fn readFile(path: []const u8) ?[]const u8 {
    return @import("ttf.zig").mapFile(path);
}

fn unmap(d: []const u8) void {
    _ = std.os.linux.munmap(@ptrCast(@constCast(d.ptr)), d.len);
}

/// walk: every node from the scene's roots, with world matrices (an explicit
/// stack of 32: the last root first). A node that is its own ancestor (a
/// cycle: the original walks it forever) is left out.
fn walk(roots: usize) void {
    const Ent = struct { node: i32, par: M, depth: u32 };
    var stack: [MAX_DEPTH]Ent = undefined;
    var sp: usize = 0;
    var e = json.first(g.t, roots);
    while (e) |r| : (e = json.next(g.t, r)) {
        if (sp >= MAX_DEPTH) break;
        stack[sp] = .{ .node = jint(r), .par = ident, .depth = 0 };
        sp += 1;
    }
    // the path to the node now: path[d] its ancestor at depth d; on_path[n] where it is
    var path: std.ArrayList(u32) = .empty;
    defer path.deinit(A);
    const on = A.alloc(u32, g.nodes.len) catch return;
    defer A.free(on);
    @memset(on, std.math.maxInt(u32));
    const visits = A.alloc(u16, g.nodes.len) catch return;
    defer A.free(visits);
    @memset(visits, 0);
    while (sp > 0) {
        sp -= 1;
        const en = stack[sp];
        if (en.node < 0) continue;
        const nd = at(g.nodes, en.node) orelse continue;
        const ni: u32 = @intCast(en.node);
        // a cycle? (an ancestor of its own)
        const d = on[ni];
        if (d < en.depth and d < path.items.len and path.items[d] == ni) continue;
        if (visits[ni] >= 64) continue; // (a tree shared more than this: no more)
        visits[ni] += 1;
        path.resize(A, en.depth + 1) catch return;
        path.items[en.depth] = ni;
        on[ni] = en.depth;
        const local = nodeLocal(nd);
        const world = matMul(&en.par, &local);
        blk: { // a mesh: its primitives
            const mv = find(nd, "mesh") orelse break :blk;
            const mi = jint(mv);
            if (mi < 0) break :blk;
            const msh = at(g.meshes, mi) orelse break :blk;
            setName(nd, msh);
            var p = json.first(g.t, find(msh, "primitives") orelse break :blk);
            while (p) |q| : (p = json.next(g.t, q)) primitive(q, &world);
        }
        var c = json.first(g.t, find(nd, "children") orelse continue);
        while (c) |ch| : (c = json.next(g.t, ch)) { // children: with this world matrix
            if (sp >= MAX_DEPTH) break;
            stack[sp] = .{ .node = jint(ch), .par = world, .depth = en.depth + 1 };
            sp += 1;
        }
    }
}

/// set_name: gi_name = the node's name or the mesh's, else "glTF"
fn setName(nd: usize, msh: usize) void {
    const v = find(nd, "name") orelse find(msh, "name");
    if (v) |p| {
        if (jstr(p, &gi_name, 27) > 0) return;
    }
    @memcpy(gi_name[0..5], "glTF\x00");
}

/// gltf_import: 0 imported, 1 unreadable, 2 not valid (or nothing in it)
pub fn importFile(path: []const u8) u32 {
    g = .{};
    var n: usize = 0; // the folder (with its slash)
    for (path, 0..) |c, i| {
        if (c == 0 or i >= 500) break;
        g.dir[i] = c;
        if (c == '/') n = i + 1;
    }
    g.dirlen = n;
    const data = readFile(path) orelse return 1;
    defer unmap(data);
    defer {
        for (g.own) |o| if (o) |d| A.free(d);
        for (g.maps) |o| if (o) |d| unmap(d);
        A.free(g.acc);
        A.free(g.views);
        A.free(g.nodes);
        A.free(g.meshes);
        scr.deinit();
        scr = .{};
        g = .{};
    }
    return if (parse(data)) 0 else 2;
}

fn parse(data: []const u8) bool {
    if (data.len < 20) return false;
    const rd32 = struct {
        fn f(d: []const u8, o: usize) u32 {
            return std.mem.readInt(u32, d[o..][0..4], .little);
        }
    }.f;
    if (rd32(data, 0) == 0x46546c67) { // "glTF": binary
        const jl: u64 = rd32(data, 12);
        if (jl + 20 > data.len) return false;
        if (rd32(data, 16) != 0x4e4f534a) return false;
        const je: usize = @intCast(20 + jl);
        g.t = data[20..je];
        if (je + 8 <= data.len and rd32(data, je + 4) == 0x004e4942) { // a BIN chunk after it
            const bl: u64 = rd32(data, je);
            if (je + 8 + bl > data.len) return false;
            g.bufs[0] = data[je + 8 ..][0..@intCast(bl)];
            g.glb_bin = true;
        }
    } else g.t = data; // text glTF
    if (!json.valid(g.t)) return false;
    if (!buffers()) return false;
    g.acc = listOf("accessors");
    g.views = listOf("bufferViews");
    g.nodes = listOf("nodes");
    g.meshes = listOf("meshes");
    materials();
    var sc: i32 = 0; // the default scene's nodes
    if (top("scene")) |v| sc = @max(jint(v), 0);
    const s = jidx(top("scenes"), sc) orelse return false;
    const roots = find(s, "nodes") orelse return false;
    walk(roots);
    return g.nobj > 0;
}

// =============================================================================
//  The operators
// =============================================================================

/// file.import_gltf <path>: from the UI with none, the file browser; from the
/// console with none, the command half typed.
fn opImport() void {
    const arg = std.mem.trim(u8, ops.arg, " ");
    if (arg.len == 0) {
        if (ops.scripted) return @import("editors.zig").prefillConsole("file.import_gltf ~/");
        @import("filebrowser.zig").show(.open, "Import glTF", ".glb .gltf", "", importLater);
        return;
    }
    importLater(arg);
}

fn importLater(p: []const u8) void {
    @import("jobui.zig").later(importJob, "Importing glTF", p, 0, 0);
}
fn importJob(p: []const u8, _: usize, _: usize) void {
    importNow(p);
}

/// op_igltf: the import, and "imported <path>" or why not
pub fn importNow(p0: []const u8) void {
    var eb: [600]u8 = undefined;
    const p = @import("files.zig").expandHome(&eb, p0) orelse p0;
    const r = importFile(p);
    switch (r) {
        0 => app.log("  imported {s}", .{p}),
        1 => app.log("  could not read {s}", .{p}),
        else => app.log("  not a valid file: {s}", .{p}),
    }
    if (r != 0) { // (undo_drop_last: no step, what it made stays)
        const undo = @import("undo.zig");
        if (!undo.grouped()) undo.replaceCurrent();
    }
    app.dirty = true;
}

/// file.export_gltf <path>: from the UI with none, the file browser (its
/// "Selected objects only"); from the console with none, the command half typed.
fn opExport() void {
    const arg = std.mem.trim(u8, ops.arg, " ");
    if (arg.len == 0) {
        if (ops.scripted) return @import("editors.zig").prefillConsole("file.export_gltf ~/BeeModel/scene.glb");
        const fb = @import("filebrowser.zig");
        fb.show(.save, "Export glTF", ".glb .gltf", "scene.glb", exportLater);
        fb.export_options = true;
        fb.export_axis = false;
        return;
    }
    exportNow(arg);
}

fn exportLater(p: []const u8) void {
    @import("jobui.zig").later(exportJob, "Exporting glTF", p, 0, 0);
}
fn exportJob(p: []const u8, _: usize, _: usize) void {
    exportNow(p);
}

/// op_egltf: ~/BeeModel made if missing, the export, "exported <path>" or why not
pub fn exportNow(p0: []const u8) void {
    const files = @import("files.zig");
    var eb: [600]u8 = undefined;
    const p = files.expandHome(&eb, p0) orelse p0;
    defer @import("objmtl.zig").defaults();
    if (!files.mayWrite(p)) return app.toast(.warn, "Headless: not writing outside /tmp ({s})", .{p});
    {
        var db: [600]u8 = undefined;
        if (files.expandHome(&db, "~/BeeModel")) |d| {
            if (files.mayWrite(d)) _ = @import("spawn.zig").ensureDir(d);
        }
    }
    const r = exportFile(p);
    if (r == 0) return app.log("  exported {s}", .{p});
    if (r == 2) return app.log("  not a valid file: {s}", .{p}); // (result: 2 says so)
    app.log("  could not write {s}", .{p});
}

// =============================================================================

const testing = std.testing;

test "euler angles to a quaternion (qz qy qx)" {
    const q = eulerQuat(.{ 0, 0, 0 });
    try testing.expectEqual([4]f32{ 0, 0, 0, 1 }, q);
    const r = eulerQuat(.{ 0, std.math.pi / 2.0, 0 });
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), r[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.70710677), r[3], 1e-6);
}

test "cvtss2si rounds to even, the x87 pow" {
    try testing.expectEqual(@as(i32, 2), cvtn(1.5));
    try testing.expectEqual(@as(i32, 2), cvtn(2.5));
    try testing.expectEqual(@as(i32, -2), cvtn(-1.5));
    try testing.expectEqual(std.math.minInt(i32), cvtn(std.math.nan(f32)));
    try testing.expectEqual(std.math.minInt(i32), cvtt(3e9));
    try testing.expectApproxEqAbs(@as(f32, 0.735356), linToSrgb(0.5), 1e-5);
    var d: f32 = 0.001;
    _ = &d;
    try testing.expectEqual(d * @as(f32, 12.92), linToSrgb(d));
}

test "a node's TRS: a quarter turn about Y, scaled, moved" {
    g = .{};
    defer g = .{};
    g.t = "{\"translation\":[1,2,3],\"rotation\":[0,0.70710677,0,0.70710677],\"scale\":[2,2,2]}";
    const m = nodeLocal(0);
    try testing.expectApproxEqAbs(@as(f32, 0), m[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), m[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -2), m[8], 1e-6);
    try testing.expectEqual(@as(f32, 1), m[3]);
    try testing.expectEqual(@as(f32, 3), m[11]);
    g.t = "{\"matrix\":[1,0,0,0, 0,1,0,0, 0,0,1,0, 5,6,7,1]}";
    const n = nodeLocal(0);
    try testing.expectEqual(@as(f32, 5), n[3]);
    try testing.expectEqual(@as(f32, 7), n[11]);
}

test "base64 in stops at the first other character" {
    g = .{};
    defer g = .{};
    g.t = "aGVsbG8=\"";
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(A);
    try b64In(0, &d);
    try testing.expectEqualStrings("hello", d.items);
}

test "accessors: an offset past its view is refused, 32-bit sums" {
    g = .{};
    defer {
        A.free(g.acc);
        A.free(g.views);
        g = .{};
    }
    const buf: [64]u8 = @splat(0);
    g.bufs[0] = &buf;
    g.nbuf = 1;
    g.t = "{\"accessors\":[{\"count\":2,\"componentType\":5126,\"bufferView\":0,\"byteOffset\":8}," ++
        "{\"count\":1,\"bufferView\":0,\"byteOffset\":100},{\"count\":1,\"bufferView\":1}]," ++
        "\"bufferViews\":[{\"buffer\":0,\"byteOffset\":4,\"byteLength\":40},{\"buffer\":0,\"byteLength\":65}]}";
    g.acc = listOf("accessors");
    g.views = listOf("bufferViews");
    const a = accessor(0).?;
    try testing.expectEqual(@as(usize, 32), a.ptr.len);
    try testing.expectEqual(@as(i32, 5126), a.ctype);
    try testing.expect(accessor(1) == null);
    try testing.expect(accessor(2) == null); // (past the buffer)
    try testing.expect(accessor(3) == null);
}
