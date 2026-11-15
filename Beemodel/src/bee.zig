// .bee files, the original's native format: chunked little-endian binary.
//   "BEEM" u32 version, then chunks: tag u32, size u32, data
//     MESH  nverts, npolys, nloops, positions f32[3n], offsets u32[p+1], loops u32[l]
//     OBJS  count, records: name[32], loc / rot (radians) / scale f32[9],
//           colour 0xrrggbb, type (0 mesh, 1 light, 2 camera), flags, mesh index
//     LCAM  the camera that renders (uid), count, 32-byte records by uid
//     UIDS  count, a persistent id per object, the next id
//     PRNT  count, the parent's uid per object (0: none)
//     VIEW  active index, grid, shading, camera yaw / pitch / distance / target
// Version 2 files deflate big chunks into ZCHK (tag, raw size, raw deflate).
// The Zig port writes version 1 (every reader takes it) with the chunks it
// has; chunks it does not know are skipped when reading.
const std = @import("std");
const linux = std.os.linux;
const m = @import("math.zig");
const scene = @import("scene.zig");
const vp = @import("viewport.zig");
const icons = @import("bee_icons.zig");

const MAGIC: u32 = 0x4d454542; // "BEEM"
fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}
const T_MESH = tag("MESH");
const T_OBJS = tag("OBJS");
const T_VIEW = tag("VIEW");
const T_LCAM = tag("LCAM");
const T_UIDS = tag("UIDS");
const T_PRNT = tag("PRNT");
const T_ZCHK = tag("ZCHK");
const T_MATS = tag("MATS");
const T_NTRE = tag("NTRE");
const T_OMAT = tag("OMAT");
const T_MGRF = tag("MGRF");
const T_RNDR = tag("RNDR");
const T_WRLD = tag("WRLD");
const T_MODS = tag("MODS");
const T_IMGS = tag("IMGS");
const T_IMGD = tag("IMGD");
const T_FOLD = tag("FOLD");
const T_ANIM = tag("ANIM");
const T_MSHK = tag("MSHK");
const T_SIMC = tag("SIMC");
const T_MPIN = tag("MPIN");
const T_MUVS = tag("MUVS");
const T_MVCL = tag("MVCL");
const T_ILAY = tag("ILAY");
const T_PRBE = tag("PRBE");
const T_LMAP = tag("LMAP");
const T_VGEO = tag("VGEO");
const T_WSPC = tag("WSPC");
const T_THMB = tag("THMB");
const T_ARMT = tag("ARMT");
const T_MWGT = tag("MWGT");
const T_MRES = tag("MRES");
const T_CADD = tag("CADD");
const T_SKCH = tag("SKCH");
const T_FLDS = tag("FLDS");
const T_PSYS = tag("PSYS");
const T_LAND = tag("LAND");
const T_TEXT = tag("TEXT");
const T_CURV = tag("CURV");
const T_WRLP = tag("WRLP");
const material = @import("material.zig");

const OBF_SELECTED = 1;
const OBF_HIDDEN = 0x200;
const OBF_LOCKED = 0x400;
const OBF_NORENDER = 0x800;
const OBF_COLLAPSED = 0x1000;

pub const Error = error{ CannotOpen, NotABeeFile, Damaged, TooBig, CannotWrite };

// --- writing ---------------------------------------------------------------------

/// A part of the file could not be written in memory (the chunk writers that
/// take the list itself say so here): that file must not replace anything.
pub var encode_failed = false;

pub const Buf = struct {
    data: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator = std.heap.page_allocator,

    pub fn u32_(b: *Buf, v: u32) void {
        var x: [4]u8 = undefined;
        std.mem.writeInt(u32, &x, v, .little);
        b.data.appendSlice(b.a, &x) catch {
            encode_failed = true;
        };
    }
    fn f32_(b: *Buf, v: f32) void {
        b.u32_(@bitCast(v));
    }
    pub fn bytes(b: *Buf, s: []const u8) void {
        b.data.appendSlice(b.a, s) catch {
            encode_failed = true;
        };
    }
    pub fn begin(b: *Buf, t: u32) usize {
        b.u32_(t);
        b.u32_(0);
        return b.data.items.len;
    }
    pub fn end(b: *Buf, start: usize) void {
        if (encode_failed or b.data.items.len < start or b.data.items.len - start > 0xffffffff) {
            encode_failed = true; // (a chunk's size is 32 bits)
            return;
        }
        const size: u32 = @intCast(b.data.items.len - start);
        std.mem.writeInt(u32, b.data.items[start - 4 ..][0..4], size, .little);
    }
};

/// The scene as a .bee file (version 1).
pub fn encode(view: ?*const vp.View) ![]u8 {
    var b = Buf{};
    errdefer b.data.deinit(b.a);
    encode_failed = false;
    b.u32_(MAGIC);
    b.u32_(1);
    // THMB first: the file browser reads only the start of the file
    @import("thumb.zig").writeChunk(&b);
    @import("world.zig").compact(); // (a partitioned world: its cells' objects out of this file)
    // MESH: each mesh used once, then the cameras' and lights' icon meshes
    var mesh_ix: [scene.max_meshes]u32 = @splat(0xffffffff);
    var n_mesh: u32 = 0;
    for (scene.objects[0..scene.count]) |*o| {
        const mi = o.mesh orelse continue;
        if (o.kind == .light or o.kind == .camera) continue;
        if (mesh_ix[mi] != 0xffffffff) continue;
        const me = scene.meshes[mi] orelse continue;
        const st = b.begin(T_MESH);
        b.u32_(@intCast(me.verts.len));
        b.u32_(@intCast(me.poff.len - 1));
        b.u32_(@intCast(me.loops.len));
        for (me.verts) |v| {
            for (v) |c| b.f32_(c);
        }
        for (me.poff) |p| b.u32_(p);
        for (me.loops) |l| b.u32_(l);
        b.end(st);
        mesh_ix[mi] = n_mesh;
        n_mesh += 1;
    }
    const cam_mesh = n_mesh;
    var st = b.begin(T_MESH);
    b.bytes(&icons.camera);
    b.end(st);
    const light_mesh = n_mesh + 1;
    st = b.begin(T_MESH);
    b.bytes(&icons.light);
    b.end(st);
    // MUVS: per mesh with UVs or seams, by its place among the MESH chunks
    st = b.begin(T_MUVS);
    for (mesh_ix, 0..) |ix, mi| {
        if (ix != 0xffffffff) writeUvs(&b, ix, &scene.meshes[mi].?);
    }
    b.end(st);
    // MVCL: their vertex colours
    st = b.begin(T_MVCL);
    @import("vcol.zig").writeChunk(&b, &mesh_ix);
    b.end(st);

    // OBJS
    st = b.begin(T_OBJS);
    b.u32_(@intCast(scene.count));
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        var name: [32]u8 = @splat(0);
        @memcpy(name[0..o.name().len], o.name());
        b.bytes(&name);
        // the original keeps world transforms (children follow by deltas)
        // (a child: its kept world place, as the original holds it, while valid)
        const wp = scene.worldPlace(oi);
        for (wp[0..3]) |c| b.f32_(if (std.math.isFinite(c)) c else 0);
        for (wp[3..6]) |c| b.f32_(if (std.math.isFinite(c)) c else 0);
        for (wp[6..9]) |c| b.f32_(if (std.math.isFinite(c)) c else 1);
        b.u32_(o.color & 0xffffff);
        const t: u32 = switch (o.kind) {
            .light => 1,
            .camera => 2,
            .armature => 4,
            .sketch => 3,
            .field => 5,
            else => 0,
        };
        b.u32_(t);
        b.u32_(objFlags(o));
        b.u32_(switch (o.kind) {
            .light, .field => light_mesh,
            .camera => cam_mesh,
            else => if (o.mesh) |mi| mesh_ix[mi] else 0xffffffff,
        });
    }
    b.end(st);

    // MATS, OMAT, MGRF (the original writes them after the objects)
    st = b.begin(T_MATS);
    @import("graphops.zig").syncCheck(); // (instances as they are: a script's or an agent's change has had no sync)
    material.writeMats(&b.data, b.a) catch {
        encode_failed = true;
    };
    b.end(st);
    st = b.begin(T_OMAT);
    b.u32_(@intCast(scene.count));
    for (scene.objects[0..scene.count]) |*o| b.u32_(o.mat);
    b.end(st);
    st = b.begin(T_MGRF);
    material.writeGraphs(&b.data, b.a) catch {
        encode_failed = true;
    };
    b.end(st);

    // NTRE: the node trees (ntree.zig; the original's reader, formats.s
    // bee_load, only goes on to the workspaces and LCAM when there is one)
    st = b.begin(T_NTRE);
    @import("ntree.zig").write(&b);
    b.end(st);

    // PRBE: the light probes
    st = b.begin(T_PRBE);
    @import("probe.zig").write(&b.data, b.a);
    b.end(st);

    // LCAM: the lights' and cameras' records (those set; lcam.zig)
    st = b.begin(T_LCAM);
    @import("lcam.zig").sync();
    @import("lcam.zig").write(&b);
    b.end(st);
    // FLDS: the force fields' records (fields.zig)
    st = b.begin(T_FLDS);
    @import("fields.zig").write(&b);
    b.end(st);
    // PSYS: the particle systems' records (particles.zig)
    st = b.begin(T_PSYS);
    @import("particles.zig").write(&b);
    b.end(st);

    // RNDR, WRLD
    {
        const rn = @import("render.zig");
        st = b.begin(T_RNDR);
        rn.writeSettings(&b.data, b.a);
        b.end(st);
        st = b.begin(T_MODS);
        @import("mods.zig").writeChunk(&b);
        b.end(st);
        st = b.begin(T_WRLD);
        const env = @import("env.zig");
        b.u32_(env.idx); // image + 1, 0: the studio sky
        b.f32_(env.strength);
        b.f32_(env.rotation);
        b.end(st);
        st = b.begin(T_IMGS);
        @import("images.zig").writeChunk(&b);
        b.end(st);
        st = b.begin(T_IMGD);
        @import("images.zig").writeData(&b);
        b.end(st);
        st = b.begin(T_ILAY); // (paint layers)
        @import("layers.zig").writeChunk(&b);
        b.end(st);
        st = b.begin(T_FOLD);
        @import("folders.zig").writeChunk(&b);
        b.end(st);
        const anim = @import("anim.zig");
        if (anim.wanted()) {
            st = b.begin(T_ANIM);
            anim.writeChunk(&b);
            b.end(st);
        }
        // ARMT, MWGT: bones and skin weights, by the mesh's place among the MESH chunks
        st = b.begin(T_ARMT);
        @import("arm.zig").writeArmt(&b, &mesh_ix);
        b.end(st);
        st = b.begin(T_MWGT);
        @import("arm.zig").writeMwgt(&b, &mesh_ix);
        b.end(st);
        // MSHK: shape keys, by the mesh's place among the MESH chunks
        st = b.begin(T_MSHK);
        for (mesh_ix, 0..) |ix, mi| {
            if (ix == 0xffffffff) continue;
            if (scene.meshes[mi].?.sk) |sk| @import("shape.zig").writeMesh(&b, ix, sk);
        }
        b.end(st);
        // MPIN: cloth pins (cloth.zig), by the mesh's place among the MESH chunks
        st = b.begin(T_MPIN);
        @import("cloth.zig").writePins(&b, &mesh_ix);
        b.end(st);
    }
    // SIMC: baked simulations (simcache.zig)
    st = b.begin(T_SIMC);
    @import("simcache.zig").writeChunk(&b);
    b.end(st);

    // WSPC: the workspaces
    st = b.begin(T_WSPC);
    @import("wsfile.zig").writeChunk(&b);
    b.end(st);

    // CADD: the CAD document (units, parameters)
    st = b.begin(T_CADD);
    @import("cad.zig").writeChunk(&b);
    b.end(st);
    // SKCH: the sketches (skobj.zig)
    st = b.begin(T_SKCH);
    @import("skobj.zig").writeChunk(&b);
    b.end(st);

    // UIDS, PRNT
    st = b.begin(T_UIDS);
    b.u32_(@intCast(scene.count));
    for (scene.objects[0..scene.count]) |*o| b.u32_(o.uid);
    b.u32_(scene.uid_next);
    b.end(st);
    st = b.begin(T_PRNT);
    b.u32_(@intCast(scene.count));
    for (scene.objects[0..scene.count]) |*o| b.u32_(if (o.parent) |p| scene.objects[p].uid else o.parent_gone);
    b.end(st);
    st = b.begin(T_MRES); // (multires displacements)
    @import("multires.zig").writeChunk(&b);
    b.end(st);

    // LMAP: the lightmap
    st = b.begin(T_LMAP);
    @import("lightmap.zig").write(&b.data, b.a);
    b.end(st);

    // CURV: the curves meshes come from (curve.zig), by the mesh's place among the MESH chunks
    st = b.begin(T_CURV);
    @import("curve.zig").writeChunk(&b.data, b.a, &mesh_ix) catch {
        encode_failed = true;
    };
    b.end(st);

    // LAND: the landscapes meshes show (landscape.zig), by the mesh's place among the MESH chunks
    st = b.begin(T_LAND);
    @import("landscape.zig").writeChunk(&b, &mesh_ix);
    b.end(st);
    // TEXT: the texts meshes were made from (text3d.zig), by the mesh's place among the MESH chunks
    st = b.begin(T_TEXT);
    @import("text3d.zig").writeChunk(&b.data, b.a, &mesh_ix) catch {
        encode_failed = true;
    };
    b.end(st);

    // VGEO: the cluster DAGs, each block on a page of the file
    @import("vgeo.zig").writeChunks(&b, &mesh_ix);
    // WRLP: the world's partition (world.zig)
    if (@import("world.zig").wanted()) {
        st = b.begin(T_WRLP);
        @import("world.zig").chunkWrite(&b);
        b.end(st);
    }

    // VIEW
    st = b.begin(T_VIEW);
    b.u32_(if (scene.active) |a| @intCast(a) else 0xffffffff);
    b.u32_(@intFromBool(scene.show_grid));
    if (view) |v| {
        b.u32_(if (v.wire) 1 else if (v.rendered) 3 else if (v.material) 2 else 0);
        const rad = v.radians(); // (as they came: a script's view(), a file's)
        b.f32_(rad[0]);
        b.f32_(rad[1]);
        b.f32_(v.dist);
        for (v.target) |c| b.f32_(c);
    } else {
        b.u32_(0);
        for ([_]f32{ 0.785398, 0.5, 18, 0, 0, 0 }) |c| b.f32_(c);
    }
    b.end(st);
    if (encode_failed or !wellFormed(b.data.items)) return error.OutOfMemory;
    return b.data.toOwnedSlice(b.a);
}

/// The chunks walk from the header to the last byte, exactly, and there are
/// objects: what a save checks before it touches the file on disk, and a crash
/// recovery before it offers one.
pub fn wellFormed(d: []const u8) bool {
    if (d.len < 8 or rd32(d, 0) != MAGIC) return false;
    const ver = rd32(d, 4);
    if (ver == 0 or ver > 2) return false;
    var o: usize = 8;
    var objs = false;
    while (d.len - o >= 8) {
        const t = rd32(d, o);
        const size: usize = rd32(d, o + 4);
        if (size > d.len - o - 8) return false;
        if (t == T_OBJS or (t == T_ZCHK and size >= 8 and rd32(d, o + 8) == T_OBJS)) objs = true;
        o += 8 + size;
    }
    return o == d.len and objs;
}

/// Write the scene to path (a temporary file, then renamed over it).
pub fn save(path: []const u8, view: ?*const vp.View) !void {
    const world = @import("world.zig");
    world.saveBegin(path); // (a partitioned world: its cells first)
    defer world.saveEnd(); // (the world's objects back in)
    const data = try encode(view);
    defer std.heap.page_allocator.free(data);
    return writeAtomic(path, data);
}

/// Write bytes to path atomically (atomicfile.zig).
pub fn writeAtomic(path: []const u8, data: []const u8) !void {
    @import("atomicfile.zig").write(path, data) catch return Error.CannotWrite;
}

// --- reading ---------------------------------------------------------------------

fn rd32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .little);
}
fn rdf(d: []const u8, o: usize) f32 {
    return @bitCast(rd32(d, o));
}

pub const Report = struct {
    objects: usize = 0,
    meshes: usize = 0,
    skipped: usize = 0,
    truncated: bool = false,
    mesh_errors: usize = 0,
    parents_dropped: usize = 0,
    /// parts of the file the port does not keep (saving over it loses them)
    lossy: bool = false,
};

/// Inflate a version-2 file's ZCHK chunks into a plain copy.
pub fn unpack(d: []const u8) ![]u8 {
    const a = std.heap.page_allocator;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, d[0..4]);
    var v: [4]u8 = undefined;
    std.mem.writeInt(u32, &v, 1, .little);
    try out.appendSlice(a, &v);
    var o: usize = 8;
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(window);
    while (o + 8 <= d.len) {
        const t = rd32(d, o);
        const size = rd32(d, o + 4);
        if (o + 8 + size > d.len) {
            out.deinit(a);
            return Error.Damaged;
        }
        if (t == T_ZCHK and size >= 8) {
            const inner_tag = rd32(d, o + 8);
            const raw = rd32(d, o + 12);
            if (raw > 3 << 30) { // (a mesh of tens of millions of vertices is one chunk)
                out.deinit(a);
                return Error.TooBig;
            }
            var hdr: [8]u8 = undefined;
            std.mem.writeInt(u32, hdr[0..4], inner_tag, .little);
            std.mem.writeInt(u32, hdr[4..8], raw, .little);
            try out.appendSlice(a, &hdr);
            var in = std.Io.Reader.fixed(d[o + 16 .. o + 8 + size]);
            var dec = std.compress.flate.Decompress.init(&in, .raw, window);
            const dst = try out.addManyAsSlice(a, raw);
            dec.reader.readSliceAll(dst) catch {
                out.deinit(a);
                return Error.Damaged;
            };
        } else try out.appendSlice(a, d[o .. o + 8 + size]);
        o += 8 + size;
    }
    return out.items;
}

/// Replace the scene with the file's. On an error the scene is unchanged.
pub fn load(path: []const u8, view: ?*vp.View) !Report {
    @import("world.zig").notePath(path); // (a partitioned world's cells: beside it)
    const raw = @import("ttf.zig").mapFile(path) orelse return Error.CannotOpen;
    defer _ = linux.munmap(raw.ptr, raw.len);
    if (raw.len < 8 or rd32(raw, 0) != MAGIC) return Error.NotABeeFile;
    const ver = rd32(raw, 4);
    if (ver == 0 or ver > 2) return Error.NotABeeFile;
    const d: []const u8 = if (ver == 2) try unpack(raw) else raw;
    defer if (ver == 2) std.heap.page_allocator.free(@constCast(d.ptr)[0..d.len]);

    var rep = Report{};
    const A = std.heap.page_allocator;
    // first pass: where the chunks are
    var objs: ?[]const u8 = null;
    var lcam: ?[]const u8 = null;
    var flds: ?[]const u8 = null;
    var psys: ?[]const u8 = null;
    var ntre: ?[]const u8 = null;
    var uids: ?[]const u8 = null;
    var prnt: ?[]const u8 = null;
    var viewc: ?[]const u8 = null;
    var mats: ?[]const u8 = null;
    var omat: ?[]const u8 = null;
    var mgrf: ?[]const u8 = null;
    var rndr: ?[]const u8 = null;
    var wrld: ?[]const u8 = null;
    var modc: ?[]const u8 = null;
    var imgc: ?[]const u8 = null;
    var imgd: ?[]const u8 = null;
    var foldc: ?[]const u8 = null;
    var animc: ?[]const u8 = null;
    var mshk: ?[]const u8 = null;
    var simc: ?[]const u8 = null;
    var mpin: ?[]const u8 = null;
    var armt: ?[]const u8 = null;
    var mwgt: ?[]const u8 = null;
    var mres: ?[]const u8 = null;
    var muvs: ?[]const u8 = null;
    var mvcl: ?[]const u8 = null;
    var ilay: ?[]const u8 = null;
    var prbe: ?[]const u8 = null;
    var lmap: ?[]const u8 = null;
    var wspc: ?[]const u8 = null;
    var cadd: ?[]const u8 = null;
    var skch: ?[]const u8 = null;
    var land: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var curv: ?[]const u8 = null;
    var wrlp: ?[]const u8 = null;
    var mesh_chunks: std.ArrayList([]const u8) = .empty;
    defer mesh_chunks.deinit(A);
    var vgeo_chunks: std.ArrayList([]const u8) = .empty;
    defer vgeo_chunks.deinit(A);
    var o: usize = 8;
    while (o + 8 <= d.len) {
        const t = rd32(d, o);
        const size = rd32(d, o + 4);
        if (o + 8 + size > d.len) return Error.Damaged;
        const c = d[o + 8 .. o + 8 + size];
        if (t == T_MESH) {
            try mesh_chunks.append(A, c);
        } else if (t == T_OBJS) {
            objs = c;
        } else if (t == T_LCAM) {
            lcam = c;
        } else if (t == T_FLDS) {
            flds = c;
        } else if (t == T_PSYS) {
            psys = c;
        } else if (t == T_NTRE) {
            ntre = c;
        } else if (t == T_UIDS) {
            uids = c;
        } else if (t == T_PRNT) {
            prnt = c;
        } else if (t == T_VIEW) {
            viewc = c;
        } else if (t == T_MATS) {
            mats = c;
        } else if (t == T_OMAT) {
            omat = c;
        } else if (t == T_MGRF) {
            mgrf = c;
        } else if (t == T_MODS) {
            modc = c;
        } else if (t == T_IMGS) {
            imgc = c;
        } else if (t == T_IMGD) {
            imgd = c;
        } else if (t == T_FOLD) {
            foldc = c;
        } else if (t == T_ANIM) {
            animc = c;
        } else if (t == T_MSHK) {
            mshk = c;
        } else if (t == T_SIMC) {
            simc = c;
        } else if (t == T_MPIN) {
            mpin = c;
        } else if (t == T_ARMT) {
            armt = c;
        } else if (t == T_MWGT) {
            mwgt = c;
        } else if (t == T_MRES) {
            mres = c;
        } else if (t == T_MUVS) {
            muvs = c;
        } else if (t == T_MVCL) {
            mvcl = c;
        } else if (t == T_ILAY) {
            ilay = c;
        } else if (t == T_PRBE) {
            prbe = c;
        } else if (t == T_LMAP) {
            lmap = c;
        } else if (t == T_VGEO) {
            try vgeo_chunks.append(A, c);
        } else if (t == T_RNDR) {
            rndr = c;
        } else if (t == T_WRLD) {
            wrld = c;
        } else if (t == T_WSPC) {
            wspc = c;
        } else if (t == T_CADD) {
            cadd = c;
        } else if (t == T_SKCH) {
            skch = c;
        } else if (t == T_CURV) {
            curv = c;
        } else if (t == T_LAND) {
            land = c;
        } else if (t == T_TEXT) {
            text = c;
        } else if (t == T_WRLP) {
            wrlp = c;
        } else if (t != T_NTRE and t != T_THMB and size > 8) {
            rep.lossy = true; // modifiers, folders, animation ... (not empty)
        }
        o += 8 + size;
    }
    const ob = objs orelse return Error.Damaged;
    if (ob.len < 4) return Error.Damaged;
    const n = rd32(ob, 0);
    if (4 + @as(usize, n) * 84 > ob.len) return Error.Damaged;
    rep.meshes = mesh_chunks.items.len;

    // which objects come in (the kinds the port has, up to the limit) and the meshes they need
    const keep = try A.alloc(bool, n);
    defer A.free(keep);
    const need = try A.alloc(bool, mesh_chunks.items.len);
    defer A.free(need);
    @memset(need, false);
    var kept: usize = 0;
    for (0..n) |k| {
        const r = ob[4 + k * 84 ..][0..84];
        const typ = rd32(r, 72);
        const mi = rd32(r, 80);
        keep[k] = false;
        const meshy = typ == 0 or typ == 4 or typ == 3;
        if (typ > 2 and !meshy and typ != 5) { // (5: a force field, no mesh of its own)
            rep.skipped += 1;
            continue;
        }
        if (meshy and mi >= mesh_chunks.items.len) {
            rep.skipped += 1;
            continue;
        }
        if (kept >= scene.max_objects) {
            rep.truncated = true;
            continue;
        }
        keep[k] = true;
        kept += 1;
        if (meshy) need[mi] = true;
    }

    @import("world.zig").reset(); // (no world partition)
    // the old scene's meshes go (unless undo still needs them)
    {
        var used: [scene.max_meshes]bool = @splat(false);
        @import("undo.zig").markMeshes(&used);
        const save_count = scene.count;
        scene.count = 0; // (the scene is replaced: only undo keeps its meshes)
        scene.collectMeshes(&used);
        scene.count = save_count;
    }
    const mesh_map = try A.alloc(?u16, mesh_chunks.items.len);
    defer A.free(mesh_map);
    for (mesh_chunks.items, 0..) |c, k| {
        mesh_map[k] = if (need[k]) readMesh(c) else null;
        if (need[k] and mesh_map[k] == null) rep.mesh_errors += 1;
    }
    if (muvs) |c| {
        if (!readUvs(c, mesh_map)) rep.lossy = true;
    }
    if (mvcl) |c| @import("vcol.zig").readChunk(c, mesh_map);

    // the objects
    scene.count = 0;
    scene.active = null;
    scene.render_camera = null;
    const file_index = try A.alloc(u32, kept); // ours -> the file's
    defer A.free(file_index);
    const ours = try A.alloc(?u16, n); // the file's -> ours
    defer A.free(ours);
    @memset(ours, null);
    for (0..n) |k| {
        if (!keep[k]) continue;
        const r = ob[4 + k * 84 ..][0..84];
        const typ = rd32(r, 72);
        const mi = rd32(r, 80);
        var obj = scene.Object{ .kind = switch (typ) {
            1 => .light,
            2 => .camera,
            4 => .armature,
            3 => .sketch,
            5 => .field,
            else => .mesh,
        } };
        const nm = std.mem.sliceTo(r[0..32], 0);
        obj.setName(if (nm.len > 0) nm else obj.kind.label());
        for (0..3) |c| {
            obj.loc[c] = rdf(r, 32 + c * 4);
            obj.scl[c] = rdf(r, 56 + c * 4);
        }
        obj.setRadians(.{ rdf(r, 44), rdf(r, 48), rdf(r, 52) }); // (the radians kept: saved again, the same)
        for (&obj.loc) |*x| {
            if (!std.math.isFinite(x.*)) x.* = 0;
        }
        for (&obj.rot) |*x| {
            if (!std.math.isFinite(x.*)) x.* = 0;
        }
        for (&obj.scl) |*x| {
            if (!std.math.isFinite(x.*)) x.* = 1;
        }
        obj.color = rd32(r, 68) & 0xffffff;
        const flags = rd32(r, 76);
        obj.selected = flags & OBF_SELECTED != 0;
        obj.visible = flags & OBF_HIDDEN == 0;
        obj.locked = flags & OBF_LOCKED != 0;
        obj.render = flags & OBF_NORENDER == 0;
        obj.folded = flags & OBF_COLLAPSED != 0;
        if (typ == 0 or typ == 4 or typ == 3) {
            if (typ == 0) {
                obj.ref = flags & @import("refimg.zig").MASK;
                obj.gflags = flags & 0xe000; // (Ground, catch shadows, water)
            }
            obj.mesh = mesh_map[mi];
            if (obj.mesh == null) {
                rep.skipped += 1;
                continue;
            }
        }
        ours[k] = @intCast(scene.count);
        file_index[scene.count] = @intCast(k);
        scene.objects[scene.count] = obj;
        scene.stamp(scene.count);
        scene.count += 1;
    }
    rep.objects = scene.count;
    if (rep.skipped > 0 or rep.truncated) rep.lossy = true;

    // uids: the file's object k has uid[k]
    const uid_of = try A.alloc(u32, n);
    defer A.free(uid_of);
    // (uids_read: the count matches and the next id is there, else uids_fresh's 1..n)
    const have_uids = if (uids) |u| u.len >= 8 and rd32(u, 0) == n and u.len >= 8 + n * 4 else false;
    for (0..n) |k| uid_of[k] = if (have_uids) rd32(uids.?, 4 + k * 4) else @intCast(k + 1);
    // the objects keep them, and new ones get the ids after (the file's next
    // id; past every id it has, so a damaged chunk can't hand out one again)
    for (0..scene.count) |i| scene.objects[i].uid = uid_of[file_index[i]];
    scene.uid_next = @intCast(n + 1);
    if (have_uids) {
        const nx = rd32(uids.?, 4 + n * 4);
        if (nx > scene.uid_next and nx <= 1 << 30) scene.uid_next = nx;
        for (uid_of) |u| {
            if (u >= scene.uid_next and u < 1 << 30) scene.uid_next = u + 1;
        }
    }
    // uid -> ours, through a sorted table
    const pairs = try A.alloc(u64, n);
    defer A.free(pairs);
    for (0..n) |k| pairs[k] = (@as(u64, uid_of[k]) << 32) | k;
    std.sort.pdq(u64, pairs, {}, std.sort.asc(u64));
    const Look = struct {
        p: []const u64,
        ou: []const ?u16,
        pub fn get(l: @This(), u: u32) ?u16 {
            if (u == 0) return null;
            var lo: usize = 0;
            var hi: usize = l.p.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const mu: u32 = @intCast(l.p[mid] >> 32);
                if (mu < u) lo = mid + 1 else hi = mid;
            }
            if (lo < l.p.len and @as(u32, @intCast(l.p[lo] >> 32)) == u) return l.ou[@as(u32, @truncate(l.p[lo]))];
            return null;
        }
    };
    const look = Look{ .p = pairs, .ou = ours };

    // parents
    if (prnt) |p| {
        if (p.len >= 4 and rd32(p, 0) == n and p.len >= 4 + n * 4) {
            for (0..scene.count) |i| {
                const k = file_index[i];
                const pu = rd32(p, 4 + k * 4);
                scene.objects[i].parent = look.get(pu);
                // (a parent not here, or one dropped below: kept as the file says,
                // as the original's OB_PARENT; no new object takes its uid)
                scene.objects[i].parent_gone = pu;
                if (scene.objects[i].parent == null and pu >= scene.uid_next and pu < 1 << 30) scene.uid_next = pu + 1;
            }
            // the file's transforms are world ones: children relative to their parent
            const world = try A.alloc(m.M4, scene.count);
            defer A.free(world);
            const file_wp = try A.alloc([9]f32, scene.count);
            defer A.free(file_wp);
            for (0..scene.count) |i| world[i] = scene.objects[i].matrix();
            // no loops (a damaged file)
            for (0..scene.count) |i| {
                if (scene.objects[i].parent) |par| {
                    if (par == i or scene.isAncestor(i, par)) scene.objects[i].parent = null;
                }
            }
            for (0..scene.count) |i| {
                const par = scene.objects[i].parent orelse continue;
                const fo = &scene.objects[i];
                const fr = fo.radians(); // (its values still the file's: world ones)
                const filep: [9]f32 = .{ fo.loc[0], fo.loc[1], fo.loc[2], fr[0], fr[1], fr[2], fo.scl[0], fo.scl[1], fo.scl[2] };
                const t = m.decompose(m.mul(m.inverseAffine(world[par]), world[i]));
                var ok = true;
                for ([_]m.V3{ t.loc, t.rot, t.scl }) |v| {
                    for (v) |x| {
                        if (!std.math.isFinite(x) or @abs(x) > 1e9) ok = false;
                    }
                }
                if (ok) {
                    // does parent * TRS give the file's world back? (not with shear)
                    const back = m.mul(world[par], m.trs(t.loc, t.rot, t.scl));
                    for (0..12) |q| {
                        if (@abs(back[q] - world[i][q]) > 1e-3 * (1 + @abs(world[i][q]))) ok = false;
                    }
                }
                if (!ok) {
                    // it keeps its place, but not the parent (shear, a flattened parent)
                    scene.objects[i].parent = null;
                    rep.parents_dropped += 1;
                    continue;
                }
                scene.objects[i].loc = t.loc;
                scene.objects[i].rot = t.rot;
                scene.objects[i].scl = t.scl;
                file_wp[i] = filep;
            }
            // the file's world places kept (the parents' own values all set first)
            for (0..scene.count) |i| {
                if (scene.objects[i].parent != null) scene.keepWorldPlace(i, file_wp[i]);
            }
            for (scene.objects[0..scene.count]) |*pob| {
                if (pob.parent != null) pob.parent_gone = 0;
            }
        }
    }

    if (mres) |c| @import("multires.zig").readChunk(c, ours);
    if (modc) |c| {
        if (!@import("mods.zig").readChunk(c, file_index[0..scene.count])) rep.lossy = true;
    }

    // materials (MATS: count, 128-byte records; MGRF: their graphs, kept as
    // they are; OMAT: count, material + 1 per object)
    if (mats) |mt| {
        if (!material.readMats(mt)) rep.lossy = true;
    } else material.reset();
    if (mgrf) |g| {
        if (!material.readGraphs(g)) rep.lossy = true;
    }
    if (omat) |om| {
        if (om.len >= 4 and rd32(om, 0) == n and om.len >= 4 + n * 4) {
            for (0..scene.count) |i| {
                const mi1 = rd32(om, 4 + file_index[i] * 4);
                scene.objects[i].mat = if (mi1 <= material.count) @intCast(mi1) else 0;
            }
        } else if (om.len > 4) rep.lossy = true;
    }

    // shape keys, the animation (ANIM: every object reference a uid); after
    // the objects and the meshes
    if (mshk) |c| {
        if (!@import("shape.zig").readChunk(c, mesh_map)) rep.lossy = true;
    }
    if (armt) |c| {
        if (!@import("arm.zig").readArmt(c, mesh_map)) rep.lossy = true;
    }
    if (mwgt) |c| {
        if (!@import("arm.zig").readMwgt(c, mesh_map)) rep.lossy = true;
    }
    if (mpin) |c| @import("cloth.zig").readPins(c, mesh_map); // (cloth pins)
    if (curv) |c| @import("curve.zig").readChunk(c, mesh_map); // (curves)
    if (land) |c| @import("landscape.zig").readChunk(c, mesh_map); // (landscapes)
    if (text) |c| @import("text3d.zig").readChunk(c, mesh_map); // (texts)
    // folders (FOLD: records, then object uid, folder uid)
    const folders = @import("folders.zig");
    folders.reset();
    if (foldc) |c| {
        if (!folders.readChunk(c, look, @TypeOf(look).get)) rep.lossy = true;
    }
    // the CAD document (units, parameters)
    const cad = @import("cad.zig");
    cad.reset();
    if (cadd) |c| {
        if (!cad.readChunk(c)) rep.lossy = true;
        @import("feature.zig").afterRead(look); // (the records' uids: our objects)
    }
    // the sketches (after the parameters their dimensions use)
    if (skch) |c| {
        if (!@import("skobj.zig").readChunk(c, ours)) rep.lossy = true;
    }
    const frange = @import("frange.zig");
    frange.reset();
    const anim = @import("anim.zig");
    anim.reset();
    if (animc) |c| {
        if (c.len > 0 and !anim.readChunk(c, look)) rep.lossy = true;
    }
    // the simulation: none yet; baked frames (SIMC) after the animation
    @import("rbody.zig").reset();
    @import("cloth.zig").reset();
    @import("particles.zig").reset();
    @import("simcache.zig").reset();
    if (simc) |c| {
        if (!@import("simcache.zig").readChunk(c)) rep.lossy = true;
    }

    // render settings (RNDR: width, height, samples, the pass shown, denoise,
    // motion blur, sample reuse) and the world (WRLD, kept as it came)
    const rn = @import("render.zig");
    rn.resetSettings();
    if (rndr) |r| rn.readSettings(r);
    const env = @import("env.zig");
    const images = @import("images.zig");
    env.reset();
    images.clear();
    if (imgc) |c| {
        if (!images.readChunk(c)) rep.lossy = true;
    }
    if (imgd) |c| {
        if (!images.readData(c)) rep.lossy = true;
    }
    if (ilay) |c| @import("layers.zig").readChunk(c);
    if (wrld) |wd| {
        if (wd.len >= 12) {
            const ix = rd32(wd, 0);
            const st = rdf(wd, 4);
            const ro = rdf(wd, 8);
            env.idx = if (ix <= images.count) ix else 0;
            if (ix > images.count) rep.lossy = true;
            env.strength = if (std.math.isFinite(st)) @max(st, 0) else 1;
            env.rotation = if (std.math.isFinite(ro)) ro else 0;
        }
    }

    // light probes, the lightmap (by object uid)
    const probe = @import("probe.zig");
    const lightmap = @import("lightmap.zig");
    probe.reset();
    lightmap.reset();
    if (prbe) |c| {
        if (!probe.read(c)) rep.lossy = true;
    }
    if (lmap) |c| {
        if (!lightmap.read(c, look)) rep.lossy = true;
    }

    // the cluster DAGs: those of the old scene go, these stay mapped from the file
    const vgeo = @import("vgeo.zig");
    for (vgeo_chunks.items) |c| {
        if (!vgeo.readChunk(c, mesh_chunks.items.len, if (ver == 1) raw else null, path)) {
            rep.lossy = true;
        } else if (std.mem.readInt(u32, c[0..4], .little) < mesh_map.len) { // (vg_attach: the mesh has had one)
            if (mesh_map[std.mem.readInt(u32, c[0..4], .little)]) |mi| {
                if (scene.meshes[mi]) |*me| me.vg_had = true;
            }
        }
    }
    vgeo.sweep();

    // lights' and cameras' settings (no chunk: none set)
    @import("lcam.zig").read(lcam orelse "", look);
    // force fields' settings (fl_read; no chunk: none)
    @import("fields.zig").read(flds orelse "");
    // particle systems' settings (ps_read; no chunk: none)
    @import("particles.zig").read(psys orelse "");
    // node trees and logic graphs (nt_read; no chunk: none)
    @import("ntree.zig").read(ntre orelse "");

    // the workspaces (a damaged chunk leaves the areas as they are); the view
    // then goes on the viewport they have
    var the_view = view;
    if (wspc) |c| {
        const wsfile = @import("wsfile.zig");
        if (wsfile.valid(c)) {
            wsfile.read(c, false);
            const app = @import("app.zig");
            const va = app.viewportArea();
            the_view = if (va < 0) null else &app.N(va).view;
        } else if (!wsfile.empty(c)) rep.lossy = true;
    }
    if (viewc) |v| {
        if (v.len >= 36) {
            const a = rd32(v, 0);
            if (a < n) scene.active = if (ours[a]) |x| x else null;
            scene.show_grid = rd32(v, 4) != 0;
            if (the_view) |vw| {
                vw.wire = rd32(v, 8) == 1;
                vw.material = rd32(v, 8) == 2 or rd32(v, 8) == 3;
                vw.rendered = rd32(v, 8) == 3;
                const yaw = rdf(v, 12) / m.deg;
                vw.yaw = if (std.math.isFinite(yaw)) @mod(yaw, 360) else 45;
                const pitch = rdf(v, 16) / m.deg;
                vw.pitch = if (std.math.isFinite(pitch)) std.math.clamp(pitch, -89.9, 89.9) else 28.64789;
                if (std.math.isFinite(rdf(v, 12)) and std.math.isFinite(rdf(v, 16))) vw.setRadians(rdf(v, 12), rdf(v, 16)); // (the file's radians, as the original keeps them)
                const dist = rdf(v, 20);
                vw.dist = if (std.math.isFinite(dist)) std.math.clamp(dist, 0.5, 500) else 18;
                vw.target = .{ rdf(v, 24), rdf(v, 28), rdf(v, 32) };
                for (&vw.target) |*x| {
                    if (!std.math.isFinite(x.*)) x.* = 0;
                }
                vw.cam_view = false;
                vw.gliding = false;
            }
        }
    }
    if (scene.active == null) {
        for (scene.objects[0..scene.count], 0..) |*ob2, i| {
            if (ob2.selected) scene.active = i;
        }
    }
    // a partitioned world: its cells stream in around the camera
    if (wrlp) |c| @import("world.zig").chunkRead(c);
    return rep;
}

/// OBJS / CELO flags of an object: the original's OB_FLAGS.
pub fn objFlags(o: *const scene.Object) u32 {
    var flags: u32 = 0;
    if (o.selected) flags |= OBF_SELECTED;
    if (!o.visible) flags |= OBF_HIDDEN;
    if (o.locked) flags |= OBF_LOCKED;
    if (!o.render) flags |= OBF_NORENDER;
    if (o.folded) flags |= OBF_COLLAPSED;
    flags |= o.ref; // (reference images: refimg.zig)
    flags |= o.gflags; // (the Ground: prims.zig)
    return flags;
}

/// An object's fields from OB_FLAGS (typ: the file's type).
pub fn applyFlags(obj: *scene.Object, flags: u32, typ: u32) void {
    obj.selected = flags & OBF_SELECTED != 0;
    obj.visible = flags & OBF_HIDDEN == 0;
    obj.locked = flags & OBF_LOCKED != 0;
    obj.render = flags & OBF_NORENDER == 0;
    obj.folded = flags & OBF_COLLAPSED != 0;
    if (typ == 0) {
        obj.ref = flags & @import("refimg.zig").MASK;
        obj.gflags = flags & 0xe000; // (Ground, catch shadows, water)
    }
}

/// One MUVS record: the mesh, flags (1 UVs, 2 seams), loops, the UVs, the
/// seams (a byte a loop, to a multiple of 4).
pub fn writeUvs(b: *Buf, ix: u32, me: *const scene.Mesh) void {
    const has_uv = me.uv.len == me.loops.len and me.uv.len > 0;
    const has_seam = me.seam.len == me.loops.len and me.seam.len > 0;
    if (!has_uv and !has_seam) return;
    b.u32_(ix);
    b.u32_(@as(u32, @intFromBool(has_uv)) | @as(u32, @intFromBool(has_seam)) << 1);
    b.u32_(@intCast(me.loops.len));
    if (has_uv) b.bytes(std.mem.sliceAsBytes(me.uv));
    if (has_seam) {
        b.bytes(me.seam);
        const zero = [3]u8{ 0, 0, 0 };
        b.bytes(zero[0 .. (4 - me.seam.len % 4) % 4]);
    }
}

/// The UVs and seams back on the loaded meshes when their loops match (a
/// record that does not is passed over, as the original). False: damaged.
pub fn readUvs(c: []const u8, map: []const ?u16) bool {
    var o: usize = 0;
    const al = @import("alloc.zig").A;
    while (c.len - o >= 12) {
        const ix = rd32(c, o);
        const flags = rd32(c, o + 4);
        const nl: usize = rd32(c, o + 8);
        if (nl >= 0x10000000) return false;
        var size: usize = 0;
        if (flags & 1 != 0) size += nl * 8;
        if (flags & 2 != 0) size += (nl + 3) & ~@as(usize, 3);
        if (size > c.len - o - 12) return false;
        const body = c[o + 12..][0..size];
        o += 12 + size;
        const mi = if (ix < map.len) map[ix] orelse continue else continue;
        const me = &(scene.meshes[mi] orelse continue);
        if (nl == 0 or nl != me.loops.len) continue;
        if (flags & 1 != 0 and me.uv.len == 0) {
            me.uv = al.alloc([2]f32, nl) catch &.{};
            if (me.uv.len == nl) {
                for (me.uv, 0..) |*u, k| {
                    u.* = .{ rdf(body, k * 8), rdf(body, k * 8 + 4) };
                    // (a file is not to be trusted)
                    for (u) |*x| {
                        if (!std.math.isFinite(x.*)) x.* = 0;
                    }
                }
            }
        }
        if (flags & 2 != 0 and me.seam.len == 0) {
            const s = body[if (flags & 1 != 0) nl * 8 else 0..][0..nl];
            me.seam = al.dupe(u8, s) catch &.{};
        }
    }
    return o == c.len;
}

pub fn readMesh(c: []const u8) ?u16 {
    if (c.len < 12) return null;
    const nv = rd32(c, 0);
    const np = rd32(c, 4);
    const nl = rd32(c, 8);
    const need = 12 + @as(u64, nv) * 12 + (@as(u64, np) + 1) * 4 + @as(u64, nl) * 4;
    if (need > c.len or nv > 50_000_000) return null;
    // (no vertices and no polygons: an empty curve's mesh, kept as the original keeps it)
    if (nv == 0 and np == 0) return scene.addEmptyMesh();
    const a = std.heap.page_allocator;
    const verts = a.alloc(m.V3, nv) catch return null;
    defer a.free(verts);
    const poff = a.alloc(u32, np + 1) catch return null;
    defer a.free(poff);
    const loops = a.alloc(u32, nl) catch return null;
    defer a.free(loops);
    var o: usize = 12;
    for (verts) |*v| {
        v.* = .{ rdf(c, o), rdf(c, o + 4), rdf(c, o + 8) };
        o += 12;
    }
    for (poff) |*p| {
        p.* = rd32(c, o);
        o += 4;
    }
    for (loops) |*l| {
        l.* = rd32(c, o);
        o += 4;
    }
    return scene.addMesh(verts, poff, loops);
}
