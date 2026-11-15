// The scene: a flat list of objects and the meshes they use.
const std = @import("std");
const m = @import("math.zig");
const material = @import("material.zig");
const probe = @import("probe.zig");

pub const Kind = enum(u8) {
    mesh, // any mesh (opened from a file)
    cube,
    sphere,
    cylinder,
    plane,
    light,
    camera,
    armature, // its mesh shows the bones (arm.zig); not rendered, not exported
    sketch, // 2D geometry and constraints (sketch.zig); its mesh: the lines, for bounds
    field, // a force field (fields.zig: its settings by uid); drawn as a light's octahedron

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .mesh => "Mesh",
            .cube => "Cube",
            .sphere => "Sphere",
            .cylinder => "Cylinder",
            .plane => "Plane",
            .light => "Light",
            .camera => "Camera",
            .armature => "Armature",
            .sketch => "Sketch",
            .field => "Field",
        };
    }
    pub fn isMesh(k: Kind) bool {
        return switch (k) {
            .light, .camera, .armature, .sketch, .field => false,
            else => true,
        };
    }
};

pub const LightType = enum(u8) {
    point,
    sun,
    spot,
    area,
    pub fn label(t: LightType) []const u8 {
        return switch (t) {
            .point => "Point",
            .sun => "Sun",
            .spot => "Spot",
            .area => "Area",
        };
    }
};

/// A modifier, as in the file (mods.zig): type, bit 0 on, ten values (float
/// bits; an object: its oid).
pub const Mod = extern struct { kind: u32 = 0, flags: u32 = 0, p: [10]u32 = @splat(0) };
pub const MOD_MAX = 8;
pub const Stack = struct { n: u8 = 0, m: [MOD_MAX]Mod = @splat(.{}) };

pub const Object = struct {
    /// Who it is, whatever its index (undo, deletes): never reused in a session.
    oid: u32 = 0,
    /// The persistent id the files carry (the original's OB_UID): taken from
    /// uid_next when made, kept by undo, read back from UIDS.
    uid: u32 = 0,
    name_buf: [32]u8 = @splat(0),
    name_len: u8 = 0,
    kind: Kind,
    loc: m.V3 = .{ 0, 0, 0 },
    rot: m.V3 = .{ 0, 0, 0 },
    scl: m.V3 = .{ 1, 1, 1 },
    color: u32 = 0xb8bcc4,
    visible: bool = true,
    selected: bool = false,
    /// Locked: clicks in the viewport pass through it.
    locked: bool = false,
    /// Off: renders leave it out.
    render: bool = true,
    // a light
    light_type: LightType = .point,
    power: f32 = 1000, // watts
    light_color: u32 = 0xffffff,
    size: f32 = 0, // radius m (point, spot), angle deg (sun), edge m (area); no record in lcam.s: 0
    cone: f32 = 45, // spot: degrees
    // a camera
    lens: f32 = 50, // mm on a 36 mm sensor
    /// Its mesh (an index into `meshes`), or none (lights, cameras).
    mesh: ?u16 = null,
    /// The object it follows (index), or none.
    parent: ?u16 = null,
    /// No parent here, but the file's PRNT names one: the uid of a parent that
    /// was deleted (the original keeps OB_PARENT so) or that the file does not
    /// have; written back as it is. 0: none.
    parent_gone: u32 = 0,
    /// Outliner: its children folded away.
    folded: bool = false,
    /// Its material: index + 1 into material.list (0: none, the colour shows).
    mat: u16 = 0,
    /// Its modifiers.
    mods: Stack = .{},
    /// Multires displacements (OB_MRES): a mesh slot used only for its positions,
    /// never changed once made, shared with the undo steps as a mesh is.
    mres: ?u16 = null,
    /// A reference image: the original's OBF_REF* bits (refimg.zig), else 0.
    ref: u32 = 0,
    /// The outliner folder it is in (folders.zig uid, 0: none).
    folder: u32 = 0,
    /// The original's OBF_GROUND, OBF_CATCH (prims.zig), else 0.
    gflags: u32 = 0,
    /// The radians its rotation came as (a file's, a mechanism's: the
    /// original keeps radians, `rot` is degrees and a few radians have no
    /// degrees that give them back): valid while `rot` is still `rad_deg`.
    rad: m.V3 = .{ 0, 0, 0 },
    rad_deg: m.V3 = .{ 0, 0, 0 },
    /// A child's world place as the original holds it (OB_LOC, OB_ROT radians,
    /// OB_SCALE: a file's, a simulation's), not as its parent's matrix times its
    /// own gives it back (a few ulps off): valid while its own values and its
    /// parent's world matrix are those it was kept with (worldPlace).
    wp: [9]f32 = @splat(0),
    wp_own: [9]f32 = @splat(0),
    wp_par: m.M4 = @splat(0),
    wp_ok: bool = false,
    /// An armature whose pose changed: its display mesh is made again (OBF_ARM_DIRTY).
    arm_dirty: bool = false,
    /// A sketch's block (OB_SKETCH; sketch.zig), shared copy-on-write with the
    /// undo steps and duplicates, or null.
    sk: ?*@import("sketch.zig").Block = null,

    /// Its rotation in radians, as the original holds it (OB_ROT).
    pub fn radians(o: *const Object) m.V3 {
        const x: [3]u32 = @bitCast(o.rot);
        const y: [3]u32 = @bitCast(o.rad_deg);
        if (x[0] == y[0] and x[1] == y[1] and x[2] == y[2]) return o.rad;
        const d: f32 = m.deg;
        return .{ o.rot[0] * d, o.rot[1] * d, o.rot[2] * d };
    }

    /// Its rotation from radians: the degrees that give them back, and the
    /// radians kept for the few that none do.
    pub fn setRadians(o: *Object, r: m.V3) void {
        o.rot = .{ degOf(r[0]), degOf(r[1]), degOf(r[2]) };
        o.rad = r;
        o.rad_deg = o.rot;
    }

    /// The scene's Ground: drawn as a fading grid, not as a mesh.
    pub fn isGround(o: *const Object) bool {
        return o.gflags & 0x2000 != 0;
    }

    pub fn name(o: *const Object) []const u8 {
        return o.name_buf[0..o.name_len];
    }
    pub fn setName(o: *Object, s: []const u8) void {
        var n = @min(s.len, o.name_buf.len);
        // not inside a UTF-8 character
        if (n < s.len) {
            while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
        }
        o.name_buf = @splat(0);
        @memcpy(o.name_buf[0..n], s[0..n]);
        o.name_len = @intCast(n);
    }
    pub fn matrix(o: *const Object) m.M4 {
        return m.trs(o.loc, o.rot, o.scl);
    }
};

/// A mesh as the original keeps it: vertices, polygons as runs of loop
/// vertex indices (poff[p] .. poff[p+1]), counter-clockwise from outside.
/// Triangles (a fan per polygon) are derived for drawing.
pub const Mesh = struct {
    verts: []m.V3,
    poff: []u32,
    loops: []u32,
    tris: [][3]u32,
    /// the polygon each triangle came from
    tri_poly: []u32,
    edges: u32,
    /// each edge once (vertex pairs), for wireframe
    edge_list: [][2]u32 = &.{},
    /// every edge has two polygons: back faces can be culled
    closed: bool = true,
    /// object-space bounds
    lo: m.V3 = .{ 0, 0, 0 },
    hi: m.V3 = .{ 0, 0, 0 },
    /// the edit-mode selection, kept when edit mode is left (empty: none yet)
    vsel: []bool = &.{},
    /// unique per mesh made (caches key on it: slots and memory get reused)
    serial: u32 = 0,
    /// moves when its vertices move in place (the serial stays): what hangs
    /// on the shape keys on both
    shape: u32 = 0,
    /// u, v per loop (empty: no UVs, textures box-project); seams: a byte per loop
    uv: [][2]f32 = &.{},
    seam: []u8 = &.{},
    /// its shape keys (shape.zig): the mesh's own, copied with it
    sk: ?*@import("shape.zig").Block = null,
    /// an armature's bones (arm.zig), on its display mesh, copied with it
    arm: ?*@import("arm.zig").Block = null,
    /// skin weights, a record a vertex (empty: none), copied with it
    wgt: []@import("arm.zig").Wgt = &.{},
    /// a block of multires displacements: its base's vertices, polygons, loops
    db: [3]u32 = .{ 0, 0, 0 },
    /// vertex colours, one a vertex, 0xAARRGGBB, sRGB (empty: none), copied with it
    vcol: []u32 = &.{},
    /// moves when its vertex colours or weights change in place (paint strokes):
    /// what shows them follows, the vertices and their normals stay
    paints: u32 = 0,
    /// cloth pins (ME_PIN), a byte a vertex, 1: pinned (empty: none made yet),
    /// copied with it (cloth.zig, the MPIN chunk)
    pin: []u8 = &.{},
    /// the landscape it shows (ME_LAND; landscape.zig: shared, reference
    /// counted), or null; not copied with the mesh (mesh_copy)
    land: ?*@import("landscape.zig").Block = null,
    /// the curve it was made from (ME_CURVE; curve.zig: shared, reference
    /// counted), or null; not copied with the mesh (mesh_copy: a plain mesh)
    curve: ?*@import("curve.zig").Curve = null,
    /// the text it was made from (ME_TEXT; text3d.zig: shared, reference
    /// counted), or null; not copied with the mesh (mesh_copy: a plain mesh)
    text: ?*@import("text3d.zig").Block = null,
    /// a cluster DAG was attached to it (ME_VGEO set: vgeo.zig), copied with
    /// it; one that no longer matches its shape is out of date (vgeo(name, 0) 3)
    vg_had: bool = false,

    pub fn faces(me: *const Mesh) u32 {
        return @intCast(me.poff.len - 1);
    }
};

pub const max_objects = 8192; // object ids in the viewport are u16 (0: none)

pub var objects: [max_objects]Object = undefined;
pub var count: usize = 0;
/// The active object (drawn gold); the others with .selected are orange.
pub var active: ?usize = null;
pub var show_grid: bool = true;
/// The camera that renders (Render from This Camera); null: the first one.
pub var render_camera: ?usize = null;
/// The 3D cursor: where new objects go and what the cursor pivot turns around.
pub var cursor: m.V3 = .{ 0, 0, 0 };

pub const max_meshes = 8192;
pub var meshes: [max_meshes]?Mesh = @splat(null);
pub var n_meshes: usize = 0;

/// The built-in primitives' meshes (shared by every object of the kind).
pub var prim: [4]u16 = undefined;

const alloc_ = @import("alloc.zig").A;

/// Add a mesh (copied). Returns its index, or null when it is not valid.
/// Bumped when a mesh is made (undo frees the unused ones after a change).
pub var meshes_made: u32 = 0;

pub fn addMesh(verts: []const m.V3, poff: []const u32, loops: []const u32) ?u16 {
    meshes_made +%= 1;
    if (verts.len == 0) return null;
    const slot = freeSlot() orelse return null;
    const me = buildMesh(verts, poff, loops) orelse return null;
    meshes[slot] = me;
    if (slot == n_meshes) n_meshes += 1;
    return @intCast(slot);
}

/// An empty mesh (no vertices, no polygons) in a slot of its own: a CAD body
/// before its first feature builds (feature.zig). Null: no room.
pub fn addEmptyMesh() ?u16 {
    meshes_made +%= 1;
    const slot = freeSlot() orelse return null;
    const po = [1]u32{0};
    const me = buildMesh(&.{}, &po, &.{}) orelse return null;
    meshes[slot] = me;
    if (slot == n_meshes) n_meshes += 1;
    return @intCast(slot);
}

/// Is mesh slot mi one of the built-in primitives' (shared, never freed)?
pub fn isPrim(mi: u16) bool {
    for (prim) |p| {
        if (p == mi) return true;
    }
    return false;
}

/// A block of n displacements, zero, for a base of these counts (a mesh with
/// positions and nothing else, as the original's). Null: no memory.
pub fn addDisp(n: usize, db: [3]u32) ?u16 {
    meshes_made +%= 1;
    const slot = freeSlot() orelse return null;
    const v = alloc_.alloc(m.V3, n) catch return null;
    @memset(std.mem.sliceAsBytes(v), 0);
    const po = alloc_.alloc(u32, 1) catch {
        alloc_.free(v);
        return null;
    };
    po[0] = 0;
    meshes[slot] = .{ .verts = v, .poff = po, .loops = &.{}, .tris = &.{}, .tri_poly = &.{}, .edges = 0, .serial = meshes_made, .db = db };
    if (slot == n_meshes) n_meshes += 1;
    return @intCast(slot);
}

/// flat3 (mesh.s): three corners (nearly) in a line.
fn flat3(v: []const m.V3, ai: u32, bi: u32, ci: u32) bool {
    const a = v[ai];
    const b = v[bi];
    const c = v[ci];
    const u = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const w = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    var x = u[1] * w[2] - u[2] * w[1];
    x *= x;
    var y = u[2] * w[0] - u[0] * w[2];
    y *= y;
    var z = u[0] * w[1] - u[1] * w[0];
    z *= z;
    const l = x + y + z;
    const uu = u[0] * u[0] + u[1] * u[1] + u[2] * u[2];
    const ww = w[0] * w[0] + w[1] * w[1] + w[2] * w[2];
    return !(l > uu * ww * 1.0e-10);
}

/// mesh_finish's triangles of a polygon: the fan, except that a polygon of 4
/// to 256 corners has its flat ears (three corners in a line: cuts leave
/// them) wait until they are not flat (ear_tris). Its n - 2 triangles from t.
fn earTris(v: []const m.V3, idx: []const u32, poly: u32, tr: [][3]u32, tp: []u32, t0: usize) usize {
    var t = t0;
    if (idx.len < 4 or idx.len > 256) {
        var i: usize = 1;
        while (i + 1 < idx.len) : (i += 1) {
            tr[t] = .{ idx[0], idx[i], idx[i + 1] };
            tp[t] = poly;
            t += 1;
        }
        return t;
    }
    var c: [256]u32 = undefined;
    var n = idx.len;
    @memcpy(c[0..n], idx);
    var tip: usize = 1;
    var flats: usize = 0;
    while (n > 3 and flats < n) {
        if (tip >= n) tip = 0;
        const pv = (tip + n - 1) % n;
        const nx = (tip + 1) % n;
        if (flat3(v, c[pv], c[tip], c[nx])) {
            tip += 1;
            flats += 1;
            continue;
        }
        tr[t] = .{ c[pv], c[tip], c[nx] };
        tp[t] = poly;
        t += 1;
        std.mem.copyForwards(u32, c[tip .. n - 1], c[tip + 1 .. n]);
        n -= 1;
        flats = 0;
    }
    var i: usize = 1;
    while (i + 1 < n) : (i += 1) {
        tr[t] = .{ c[0], c[i], c[i + 1] };
        tp[t] = poly;
        t += 1;
    }
    return t;
}

/// A mesh of its own (copied), in no slot. Null when it is not valid.
pub fn buildMesh(verts: []const m.V3, poff: []const u32, loops: []const u32) ?Mesh {
    if (poff.len < 1) return null;
    // valid: offsets rise, loops index vertices
    if (poff[0] != 0 or poff[poff.len - 1] != loops.len) return null;
    var ntri: usize = 0;
    for (0..poff.len - 1) |p| {
        if (poff[p + 1] < poff[p] or poff[p + 1] > loops.len) return null;
        const n = poff[p + 1] - poff[p];
        if (n >= 3) ntri += n - 2;
    }
    for (loops) |l| {
        if (l >= verts.len) return null;
    }
    const v = alloc_.dupe(m.V3, verts) catch return null;
    const po = alloc_.dupe(u32, poff) catch return null;
    const lo = alloc_.dupe(u32, loops) catch return null;
    const tr = alloc_.alloc([3]u32, ntri) catch return null;
    const tp = alloc_.alloc(u32, ntri) catch return null;
    var t: usize = 0;
    for (0..po.len - 1) |p| {
        const s0 = po[p];
        const n = po[p + 1] - s0;
        if (n < 3) continue;
        t = earTris(v, lo[s0..po[p + 1]], @intCast(p), tr, tp, t);
    }
    var me = Mesh{ .verts = v, .poff = po, .loops = lo, .tris = tr, .tri_poly = tp, .edges = 0, .serial = meshes_made };
    buildEdges(&me);
    me.lo = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    me.hi = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (v) |p| {
        for (0..3) |k| {
            me.lo[k] = @min(me.lo[k], p[k]);
            me.hi[k] = @max(me.hi[k], p[k]);
        }
    }
    if (v.len == 0) {
        // (a modifier can leave nothing: A - A)
        me.lo = .{ 0, 0, 0 };
        me.hi = .{ 0, 0, 0 };
    }
    return me;
}

/// Ascending, as std.sort would: big lists by radix (16 bits a pass, the passes
/// the keys need), the same order (equal keys are equal values).
fn sortKeys(k: []u64) void {
    if (k.len < 4096) return std.sort.pdq(u64, k, {}, std.sort.asc(u64));
    const tmp = alloc_.alloc(u64, k.len) catch return std.sort.pdq(u64, k, {}, std.sort.asc(u64));
    defer alloc_.free(tmp);
    var hi: u64 = 0;
    for (k) |x| hi |= x;
    var src = k;
    var dst = tmp;
    var shift: u6 = 0;
    while (true) {
        var cnt: [65536]u32 = @splat(0);
        for (src) |x| cnt[@as(u16, @truncate(x >> shift))] += 1;
        var sum: u32 = 0;
        for (&cnt) |*c| {
            const t = c.*;
            c.* = sum;
            sum += t;
        }
        for (src) |x| {
            const b = @as(u16, @truncate(x >> shift));
            dst[cnt[b]] = x;
            cnt[b] += 1;
        }
        std.mem.swap([]u64, &src, &dst);
        if (shift == 48 or hi >> (shift + 16) == 0) break;
        shift += 16;
    }
    if (src.ptr != k.ptr) @memcpy(k, src);
}

/// Edge keys (a << 32 | b, a <= b < nv) ascending, as sortKeys sorts them: with
/// fewer than 65536 vertices each as a << 16 .. through a u32 (a * nv + b,
/// the same order) by bytes, the passes its size needs (a mesh import builds
/// thousands of these; a comparison sort of each took most of the time).
fn sortEdges(k: []u64, nv: usize) void {
    if (k.len < 64 or nv > 65536 or nv == 0) return sortKeys(k);
    const a = alloc_.alloc(u32, k.len * 2) catch return sortKeys(k);
    defer alloc_.free(a);
    var src = a[0..k.len];
    var dst = a[k.len..];
    const n32: u32 = @intCast(nv);
    var top: u32 = 0;
    for (k, src) |x, *o| {
        o.* = @as(u32, @intCast(x >> 32)) * n32 + @as(u32, @truncate(x));
        top |= o.*;
    }
    var shift: u5 = 0;
    while (true) {
        var cnt: [256]u32 = @splat(0);
        for (src) |x| cnt[@as(u8, @truncate(x >> shift))] += 1;
        var sum: u32 = 0;
        for (&cnt) |*c| {
            const t = c.*;
            c.* = sum;
            sum += t;
        }
        for (src) |x| {
            const b = @as(u8, @truncate(x >> shift));
            dst[cnt[b]] = x;
            cnt[b] += 1;
        }
        std.mem.swap([]u32, &src, &dst);
        if (shift == 24 or top >> (shift + 8) == 0) break;
        shift += 8;
    }
    for (src, k) |x, *o| o.* = @as(u64, x / n32) << 32 | (x % n32);
}

/// The edge list (each undirected edge once) and whether the mesh is closed
/// (every edge used by exactly two polygons).
fn buildEdges(me: *Mesh) void {
    const poff = me.poff;
    const loops = me.loops;
    const pairs = alloc_.alloc(u64, loops.len) catch return;
    defer alloc_.free(pairs);
    var n: usize = 0;
    for (0..poff.len - 1) |p| {
        const s0 = poff[p];
        const e0 = poff[p + 1];
        var k = s0;
        while (k < e0) : (k += 1) {
            const a: u64 = loops[k];
            const b: u64 = loops[if (k + 1 == e0) s0 else k + 1];
            pairs[n] = (@min(a, b) << 32) | @max(a, b);
            n += 1;
        }
    }
    sortEdges(pairs[0..n], me.verts.len);
    var c: usize = 0;
    var closed = true;
    var i: usize = 0;
    while (i < n) {
        var j = i + 1;
        while (j < n and pairs[j] == pairs[i]) j += 1;
        if (j - i != 2) closed = false;
        pairs[c] = pairs[i];
        c += 1;
        i = j;
    }
    const el = alloc_.alloc([2]u32, c) catch return;
    for (el, 0..) |*e, k| e.* = .{ @intCast(pairs[k] >> 32), @truncate(pairs[k]) };
    me.edge_list = el;
    me.edges = @intCast(c);
    me.closed = closed;
}

test "sortEdges: the order sortKeys gives" {
    var r = std.Random.DefaultPrng.init(7);
    for ([_]usize{ 70, 300, 5000 }) |n| {
        for ([_]usize{ 3, 200, 65536 }) |nv| {
            const a = try std.testing.allocator.alloc(u64, n);
            defer std.testing.allocator.free(a);
            const b = try std.testing.allocator.alloc(u64, n);
            defer std.testing.allocator.free(b);
            for (a) |*x| {
                const p = r.random().uintLessThan(u64, nv);
                const q = r.random().uintLessThan(u64, nv);
                x.* = @min(p, q) << 32 | @max(p, q);
            }
            @memcpy(b, a);
            sortEdges(a, nv);
            std.sort.pdq(u64, b, {}, std.sort.asc(u64));
            try std.testing.expectEqualSlices(u64, b, a);
        }
    }
}

pub fn freeMesh(me: *Mesh) void {
    alloc_.free(me.verts);
    alloc_.free(me.poff);
    alloc_.free(me.loops);
    alloc_.free(me.tris);
    alloc_.free(me.tri_poly);
    if (me.edge_list.len > 0) alloc_.free(me.edge_list);
    if (me.vsel.len > 0) alloc_.free(me.vsel);
    if (me.uv.len > 0) alloc_.free(me.uv);
    if (me.seam.len > 0) alloc_.free(me.seam);
    if (me.sk) |b| @import("shape.zig").free(b);
    me.sk = null;
    if (me.arm) |b| alloc_.destroy(b);
    me.arm = null;
    if (me.wgt.len > 0) alloc_.free(me.wgt);
    me.wgt = &.{};
    if (me.vcol.len > 0) alloc_.free(me.vcol);
    me.vcol = &.{};
    if (me.pin.len > 0) alloc_.free(me.pin);
    me.pin = &.{};
    @import("landscape.zig").unref(me.land);
    me.land = null;
    @import("curve.zig").cvUnref(me.curve);
    me.curve = null;
    @import("text3d.zig").txUnref(me.text);
    me.text = null;
}

/// Give mesh `to` the UVs and seams of `from` when their polygons are the same
/// (an edit that moved vertices): the original keeps them on the mesh.
pub fn keepUvs(to: u16, from: *const Mesh) void {
    const me = &(meshes[to] orelse return);
    if (me.sk == null) {
        // (shape keys stay with the mesh: when its vertices no longer fit they rest)
        if (from.sk) |b| me.sk = @import("shape.zig").dup(b);
    }
    @import("arm.zig").keepWeights(me, from);
    // (cloth pins: a byte a vertex, kept while the vertices are as many)
    if (me.pin.len == 0 and from.pin.len > 0 and from.pin.len == me.verts.len) me.pin = alloc_.dupe(u8, from.pin) catch &.{};
    if (me.uv.len > 0 or me.seam.len > 0) return;
    if (!std.mem.eql(u32, me.loops, from.loops) or !std.mem.eql(u32, me.poff, from.poff)) return;
    if (from.uv.len > 0) me.uv = alloc_.dupe([2]f32, from.uv) catch &.{};
    if (from.seam.len > 0) me.seam = alloc_.dupe(u8, from.seam) catch &.{};
}

/// The memory a mesh holds.
pub fn meshBytes(mi: u16) usize {
    const me = meshes[mi] orelse return 0;
    const sk: usize = if (me.sk) |b| b.pos.len * 12 else 0;
    const rig: usize = me.wgt.len * 20 + (if (me.arm != null) @as(usize, 16448) else 0);
    return me.verts.len * 12 + me.poff.len * 4 + me.loops.len * 4 + me.tris.len * 12 + me.tri_poly.len * 4 + me.edge_list.len * 8 + me.vsel.len + me.uv.len * 8 + me.seam.len + sk + rig + me.vcol.len * 4;
}

/// Free one mesh slot (a working copy that was cancelled).
pub fn freeMeshSlot(mi: u16) void {
    for (prim) |p| if (p == mi) return;
    if (meshes[mi]) |*me| {
        freeMesh(me);
        meshes[mi] = null;
    }
    while (n_meshes > 0 and meshes[n_meshes - 1] == null) n_meshes -= 1;
}

pub fn setMeshSel(mi: u16, s: []const bool) void {
    const me = &(meshes[mi] orelse return);
    if (s.len != me.verts.len) return;
    if (me.vsel.len != s.len) {
        if (me.vsel.len > 0) alloc_.free(me.vsel);
        me.vsel = alloc_.alloc(bool, s.len) catch &.{};
        if (me.vsel.len != s.len) return;
    }
    @memcpy(me.vsel, s);
}

/// A copy of a mesh with its topology as is (no rebuild): for moving vertices.
pub fn cloneMesh(src: u16) ?u16 {
    meshes_made +%= 1;
    const s = meshes[src] orelse return null;
    const slot = freeSlot() orelse return null;
    var me = s;
    me.vsel = &.{};
    me.land = null; // (mesh_copy: not the landscape)
    me.curve = null; // (nor the curve)
    me.text = null; // (nor the text)
    me.serial = meshes_made;
    me.verts = alloc_.dupe(m.V3, s.verts) catch return null;
    me.poff = alloc_.dupe(u32, s.poff) catch {
        alloc_.free(me.verts);
        return null;
    };
    me.loops = alloc_.dupe(u32, s.loops) catch {
        alloc_.free(me.verts);
        alloc_.free(me.poff);
        return null;
    };
    me.tris = alloc_.dupe([3]u32, s.tris) catch {
        alloc_.free(me.verts);
        alloc_.free(me.poff);
        alloc_.free(me.loops);
        return null;
    };
    me.tri_poly = alloc_.dupe(u32, s.tri_poly) catch {
        alloc_.free(me.verts);
        alloc_.free(me.poff);
        alloc_.free(me.loops);
        alloc_.free(me.tris);
        return null;
    };
    me.edge_list = if (s.edge_list.len > 0) (alloc_.dupe([2]u32, s.edge_list) catch {
        alloc_.free(me.verts);
        alloc_.free(me.poff);
        alloc_.free(me.loops);
        alloc_.free(me.tris);
        alloc_.free(me.tri_poly);
        return null;
    }) else &.{};
    me.uv = if (s.uv.len > 0) (alloc_.dupe([2]f32, s.uv) catch &.{}) else &.{};
    me.seam = if (s.seam.len > 0) (alloc_.dupe(u8, s.seam) catch &.{}) else &.{};
    me.sk = if (s.sk) |b| @import("shape.zig").dup(b) else null;
    me.arm = null;
    if (s.arm) |b| {
        me.arm = alloc_.create(@import("arm.zig").Block) catch null;
        if (me.arm) |c| c.* = b.*;
    }
    me.wgt = if (s.wgt.len > 0) (alloc_.dupe(@import("arm.zig").Wgt, s.wgt) catch &.{}) else &.{};
    me.vcol = if (s.vcol.len > 0) (alloc_.dupe(u32, s.vcol) catch &.{}) else &.{};
    me.pin = if (s.pin.len > 0) (alloc_.dupe(u8, s.pin) catch &.{}) else &.{};
    meshes[slot] = me;
    if (slot == n_meshes) n_meshes += 1;
    return @intCast(slot);
}

/// Free the meshes nothing uses: neither the scene nor `keep` (the undo
/// history marks its own). The primitives always stay.
pub fn collectMeshes(keep: []const bool) void {
    var used: [max_meshes]bool = @splat(false);
    for (prim) |p| used[p] = true;
    for (objects[0..count]) |*o| {
        if (o.mesh) |mi| used[mi] = true;
        if (o.mres) |mi| used[mi] = true;
    }
    for (keep, 0..) |k, i| {
        if (k) used[i] = true;
    }
    for (&meshes, 0..) |*slot, i| {
        if (slot.* != null and !used[i]) {
            freeMesh(&slot.*.?);
            slot.* = null;
        }
    }
    while (n_meshes > 0 and meshes[n_meshes - 1] == null) n_meshes -= 1;
}

/// Free slots are reused before the table grows.
fn freeSlot() ?usize {
    for (meshes[0..n_meshes], 0..) |slot, i| {
        if (slot == null) return i;
    }
    if (n_meshes < max_meshes) return n_meshes;
    return null;
}

/// After a mesh's vertices changed in place (a working copy): its bounds again.
var shapes: u32 = 0;

/// What it shows changed with its vertices as they are (a shape key's value).
pub fn bumpShape(mi: u16) void {
    const me = &(meshes[mi] orelse return);
    shapes +%= 1;
    me.shape = shapes;
}

pub fn refreshMesh(mi: u16) void {
    const me = &(meshes[mi] orelse return);
    shapes +%= 1;
    me.shape = shapes;
    me.lo = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
    me.hi = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (me.verts) |p| {
        for (0..3) |k| {
            me.lo[k] = @min(me.lo[k], p[k]);
            me.hi[k] = @max(me.hi[k], p[k]);
        }
    }
}

pub fn meshOfObj(i: usize) ?*const Mesh {
    const mi = objects[i].mesh orelse return null;
    if (meshes[mi]) |*me| return me;
    return null;
}

// --- primitives ------------------------------------------------------------

// as the original's primitives (scene.s): 32 segments, 16 rings
const seg = 32;
const rings = 16;

fn buildMeshes() void {
    // cube: six quads, outward (the original's vertex and face order)
    const cv = [_]m.V3{
        .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, -1, 1 }, .{ -1, -1, 1 },
        .{ -1, 1, -1 },  .{ 1, 1, -1 },  .{ 1, 1, 1 },  .{ -1, 1, 1 },
    };
    const cl = [_]u32{ 0, 1, 2, 3, 7, 6, 5, 4, 0, 4, 5, 1, 1, 5, 6, 2, 2, 6, 7, 3, 3, 7, 4, 0 };
    const co = [_]u32{ 0, 4, 8, 12, 16, 20, 24 };
    prim[0] = addMesh(&cv, &co, &cl).?;

    // UV sphere: quads, triangles at the poles
    var sv: [(rings - 1) * seg + 2]m.V3 = undefined;
    sv[0] = .{ 0, 1, 0 };
    for (1..rings) |r| {
        const phi = std.math.pi * @as(f32, @floatFromInt(r)) / rings;
        for (0..seg) |k| {
            const th = 2 * std.math.pi * @as(f32, @floatFromInt(k)) / seg;
            sv[1 + (r - 1) * seg + k] = .{ @sin(phi) * @cos(th), @cos(phi), @sin(phi) * @sin(th) };
        }
    }
    const south: u32 = (rings - 1) * seg + 1;
    sv[south] = .{ 0, -1, 0 };
    var sl: [seg * 3 * 2 + (rings - 2) * seg * 4]u32 = undefined;
    var so: [seg * rings + 1]u32 = undefined;
    var nl: usize = 0;
    var np: usize = 0;
    so[0] = 0;
    const ring = struct {
        fn at(r: usize, k: usize) u32 {
            return @intCast(1 + (r - 1) * seg + k % seg);
        }
    }.at;
    for (0..seg) |k| { // the north cap
        sl[nl] = 0;
        sl[nl + 1] = ring(1, k + 1);
        sl[nl + 2] = ring(1, k);
        nl += 3;
        np += 1;
        so[np] = @intCast(nl);
    }
    for (1..rings - 1) |r| {
        for (0..seg) |k| {
            sl[nl] = ring(r, k);
            sl[nl + 1] = ring(r, k + 1);
            sl[nl + 2] = ring(r + 1, k + 1);
            sl[nl + 3] = ring(r + 1, k);
            nl += 4;
            np += 1;
            so[np] = @intCast(nl);
        }
    }
    for (0..seg) |k| { // the south cap
        sl[nl] = ring(rings - 1, k);
        sl[nl + 1] = ring(rings - 1, k + 1);
        sl[nl + 2] = south;
        nl += 3;
        np += 1;
        so[np] = @intCast(nl);
    }
    // (the ring order above winds counter-clockwise seen from outside)
    prim[1] = addMesh(&sv, so[0 .. np + 1], sl[0..nl]).?;

    // cylinder: quads round the side, an n-gon cap at each end
    var yv: [seg * 2]m.V3 = undefined;
    for (0..seg) |k| {
        const th = 2 * std.math.pi * @as(f32, @floatFromInt(k)) / seg;
        yv[k] = .{ @cos(th), -1, @sin(th) };
        yv[seg + k] = .{ @cos(th), 1, @sin(th) };
    }
    var yl: [seg * 4 + seg * 2]u32 = undefined;
    var yo: [seg + 3]u32 = undefined;
    nl = 0;
    np = 0;
    yo[0] = 0;
    for (0..seg) |k| {
        const a: u32 = @intCast(k);
        const b: u32 = @intCast((k + 1) % seg);
        yl[nl] = a;
        yl[nl + 1] = seg + a;
        yl[nl + 2] = seg + b;
        yl[nl + 3] = b;
        nl += 4;
        np += 1;
        yo[np] = @intCast(nl);
    }
    for (0..seg) |k| yl[nl + k] = @intCast(k); // bottom (seen from below: counter-clockwise)
    nl += seg;
    np += 1;
    yo[np] = @intCast(nl);
    for (0..seg) |k| yl[nl + k] = @intCast(seg + seg - 1 - k); // top
    nl += seg;
    np += 1;
    yo[np] = @intCast(nl);
    prim[2] = addMesh(&yv, yo[0 .. np + 1], yl[0..nl]).?;

    // plane: one quad facing up
    const pv = [_]m.V3{ .{ -1, 0, -1 }, .{ 1, 0, -1 }, .{ -1, 0, 1 }, .{ 1, 0, 1 } };
    const pl = [_]u32{ 0, 2, 3, 1 };
    const po = [_]u32{ 0, 4 };
    prim[3] = addMesh(&pv, &po, &pl).?;
}

fn flip(poff: []const u32, loops: []u32) void {
    for (0..poff.len - 1) |p| std.mem.reverse(u32, loops[poff[p] + 1 .. poff[p + 1]]);
}

pub fn primMesh(k: Kind) ?u16 {
    return switch (k) {
        .cube => prim[0],
        .sphere => prim[1],
        .cylinder => prim[2],
        .plane => prim[3],
        else => null,
    };
}

// --- editing ------------------------------------------------------------

pub fn init() void {
    buildMeshes();
    reset();
}

pub fn reset() void {
    count = 0;
    material.reset();
    @import("folders.zig").reset();
    @import("frange.zig").reset();
    @import("anim.zig").reset();
    @import("cad.zig").reset();
    @import("lcam.zig").reset();
    @import("fields.zig").reset();
    @import("ntree.zig").reset();
    @import("particles.zig").resetSettings(); // (particle systems' settings)
    @import("particles.zig").reset(); //  (and their particles)
    @import("rbody.zig").reset();
    @import("cloth.zig").reset();
    @import("simcache.zig").reset();
    probe.reset();
    @import("lightmap.zig").reset();
    active = null;
    render_camera = null;
    cursor = .{ 0, 0, 0 };
    uid_next = 1;
    // the original's default scene
    _ = add(.camera);
    objects[0].loc = .{ 7.4, 5.3, 6.9 };
    objects[0].setRadians(.{ -0.483, 0.82, 0 }); // (the original's cam_rot, radians)
    _ = add(.light);
    objects[1].loc = .{ 4, 6, 1 };
    _ = add(.cube);
    objects[2].loc = .{ 0, 1, 0 };
}

/// Degrees for radians: those (near r / deg) that give r back, when one does.
pub fn degOf(r: f32) f32 {
    const d1: f32 = m.deg;
    const d = r / d1;
    if (!std.math.isFinite(d) or d * d1 == r) return d;
    var up = d;
    var dn = d;
    for (0..3) |_| {
        up = std.math.nextAfter(f32, up, std.math.inf(f32));
        dn = std.math.nextAfter(f32, dn, -std.math.inf(f32));
        if (up * d1 == r) return up;
        if (dn * d1 == r) return dn;
    }
    return d;
}

// --- parents -------------------------------------------------------------

/// The object's matrix in the world: its parents' times its own.
pub fn world(i: usize) m.M4 {
    var mtx = objects[i].matrix();
    var p = objects[i].parent;
    var guard: usize = 0;
    while (p) |pi| : (guard += 1) {
        if (pi >= count or guard > max_objects) break;
        mtx = m.mul(objects[pi].matrix(), mtx);
        p = objects[pi].parent;
    }
    return mtx;
}

pub fn worldLoc(i: usize) m.V3 {
    const w = world(i);
    return .{ w[3], w[7], w[11] };
}

pub fn worldTRS(i: usize) m.TRS {
    return m.decompose(world(i));
}

fn parentWorld(i: usize) m.M4 {
    return if (objects[i].parent) |p| world(p) else m.identity();
}

/// Give object i this world matrix (its local values follow from its parent's).
pub fn setWorld(i: usize, w: m.M4) void {
    const pw = parentWorld(i);
    if (singular(pw)) return; // a parent scaled to nothing: keep the values
    const local = m.mul(m.inverseAffine(pw), w);
    const t = m.decompose(local);
    for ([_]m.V3{ t.loc, t.rot, t.scl }) |v| {
        for (v) |x| {
            if (!std.math.isFinite(x) or @abs(x) > 1e9) return;
        }
    }
    objects[i].loc = t.loc;
    objects[i].rot = t.rot;
    objects[i].scl = t.scl;
}

fn ownPlace(o: *const Object) [9]f32 {
    return .{ o.loc[0], o.loc[1], o.loc[2], o.rot[0], o.rot[1], o.rot[2], o.scl[0], o.scl[1], o.scl[2] };
}

/// The object's world place as the original holds it (OB_LOC, OB_ROT in
/// radians, OB_SCALE): its own values without a parent; a child's kept world
/// place while still valid (keepWorldPlace), else its matrix decomposed.
pub fn worldPlace(i: usize) [9]f32 {
    const o = &objects[i];
    if (o.parent == null) {
        const r = o.radians();
        return .{ o.loc[0], o.loc[1], o.loc[2], r[0], r[1], r[2], o.scl[0], o.scl[1], o.scl[2] };
    }
    if (o.wp_ok and std.mem.eql(u32, &@as([9]u32, @bitCast(ownPlace(o))), &@as([9]u32, @bitCast(o.wp_own))) and
        std.mem.eql(u32, &@as([16]u32, @bitCast(parentWorld(i))), &@as([16]u32, @bitCast(o.wp_par)))) return o.wp;
    const t = worldTRS(i);
    return .{ t.loc[0], t.loc[1], t.loc[2], t.rot[0] * m.deg, t.rot[1] * m.deg, t.rot[2] * m.deg, t.scl[0], t.scl[1], t.scl[2] };
}

/// Remember a child's world place as the original holds it (its own values
/// already set from it).
pub fn keepWorldPlace(i: usize, p: [9]f32) void {
    const o = &objects[i];
    o.wp = p;
    o.wp_own = ownPlace(o);
    o.wp_par = parentWorld(i);
    o.wp_ok = true;
}

/// Put the object at a world place (as the original's OB_LOC, OB_ROT radians,
/// OB_SCALE); a child's own values follow from its parent's, the place kept.
pub fn setWorldPlace(i: usize, p: [9]f32) void {
    const o = &objects[i];
    if (o.parent == null) {
        o.loc = .{ p[0], p[1], p[2] };
        o.setRadians(.{ p[3], p[4], p[5] });
        o.scl = .{ p[6], p[7], p[8] };
        return;
    }
    const d: f32 = m.deg;
    setWorld(i, m.trs(.{ p[0], p[1], p[2] }, .{ p[3] / d, p[4] / d, p[5] / d }, .{ p[6], p[7], p[8] }));
    keepWorldPlace(i, p);
}

pub fn setWorldLoc(i: usize, p: m.V3) void {
    var w = world(i);
    w[3] = p[0];
    w[7] = p[1];
    w[11] = p[2];
    setWorld(i, w);
}

/// Whether a is b or one of b's parents.
pub fn isAncestor(a: usize, b: usize) bool {
    var p: ?usize = b;
    var guard: usize = 0;
    while (p) |pi| : (guard += 1) {
        if (pi == a) return true;
        if (pi >= count or guard > max_objects) return false;
        p = if (objects[pi].parent) |q| q else null;
    }
    return false;
}

fn singular(a: m.M4) bool {
    const det = a[0] * (a[5] * a[10] - a[6] * a[9]) - a[1] * (a[4] * a[10] - a[6] * a[8]) + a[2] * (a[4] * a[9] - a[5] * a[8]);
    return !std.math.isFinite(det) or @abs(det) < 1e-12;
}

/// Make `child` follow `par`, keeping where it is. False when that would loop
/// (or when the parent is scaled to nothing on an axis).
pub fn setParent(child: usize, par: ?usize) bool {
    if (par) |p| {
        if (isAncestor(child, p)) return false;
        if (singular(world(p))) return false;
    }
    // (its place stays what it was, as the original's OB_LOC, OB_ROT, OB_SCALE)
    const wp = worldPlace(child);
    const w = world(child);
    objects[child].parent = if (par) |p| @intCast(p) else null;
    objects[child].parent_gone = 0;
    setWorld(child, w);
    if (par == null) setWorldPlace(child, wp) else keepWorldPlace(child, wp);
    return true;
}

/// A selected object whose parent (or further up) is selected too: it moves with it.
pub fn followsSelected(i: usize) bool {
    var p = objects[i].parent;
    var guard: usize = 0;
    while (p) |pi| : (guard += 1) {
        if (pi >= count or guard > max_objects) return false;
        if (objects[pi].selected) return true;
        p = objects[pi].parent;
    }
    return false;
}

/// How deep in the hierarchy (0: no parent).
pub fn depth(i: usize) usize {
    var d: usize = 0;
    var p = objects[i].parent;
    while (p) |pi| : (d += 1) {
        if (pi >= count or d > max_objects) break;
        p = objects[pi].parent;
    }
    return d;
}

// --- selection ----------------------------------------------------------

pub fn isSel(i: usize) bool {
    return i < count and objects[i].selected;
}

pub fn deselectAll() void {
    for (objects[0..count]) |*o| o.selected = false;
    active = null;
}

/// Select only object i and make it the active one.
pub fn selectOnly(i: usize) void {
    deselectAll();
    objects[i].selected = true;
    active = i;
}

/// Shift+click: select and activate; clicking the active one again deselects it.
pub fn toggleSel(i: usize) void {
    if (objects[i].selected and active != null and active.? == i) {
        objects[i].selected = false;
        active = null;
    } else {
        objects[i].selected = true;
        active = i;
    }
}

pub fn selectAll() void {
    for (objects[0..count], 0..) |*o, i| {
        o.selected = o.visible;
        if (o.visible and (active == null or !objects[active.?].visible)) active = i;
    }
}

pub fn nSelected() usize {
    var n: usize = 0;
    for (objects[0..count]) |*o| {
        if (o.selected) n += 1;
    }
    return n;
}

/// The middle of the selected objects' origins.
pub fn selCenter() ?m.V3 {
    var c: m.V3 = .{ 0, 0, 0 };
    var n: f32 = 0;
    for (objects[0..count], 0..) |*o, i| {
        if (!o.selected) continue;
        c = m.add(c, worldLoc(i));
        n += 1;
    }
    if (n == 0) return null;
    return m.scale(c, 1 / n);
}

// --- snapshots (undo) ---------------------------------------------------

pub const State = struct {
    objects: []Object = &.{},
    mats: []material.Material = &.{},
    count: usize,
    active: ?usize,
    cursor: m.V3,
    render_camera: ?usize,
    /// the light probes it saw (a reference)
    probes: ?*probe.Block = null,
    folders: @import("folders.zig").Snap = .{},
    range: @import("frange.zig").Range = .{},
    /// the curves it saw (a reference)
    anim: ?*@import("anim.zig").Block = null,
    /// the CAD document it saw (a reference)
    cad: ?*@import("cad.zig").Block = null,
    /// the light and camera records it saw (a reference)
    lcam: ?*@import("lcam.zig").Block = null,
    /// the force fields' records it saw (a reference)
    flds: ?*@import("fields.zig").Block = null,
    /// the particle systems' records it saw (a reference)
    psys: ?*@import("particles.zig").Block = null,
    /// the node trees it saw (a reference)
    ntre: ?*@import("ntree.zig").Block = null,
};

pub fn save(st: *State) void {
    if (st.objects.len != count) {
        if (st.objects.len > 0) alloc_.free(st.objects);
        st.objects = alloc_.alloc(Object, count) catch &.{};
    }
    const n = @min(count, st.objects.len);
    @memcpy(st.objects[0..n], objects[0..n]);
    st.count = n;
    st.active = active;
    st.cursor = cursor;
    st.render_camera = render_camera;
    probe.keep(&st.probes);
    @import("folders.zig").save(&st.folders);
    st.range = @import("frange.zig").r;
    @import("anim.zig").keep(&st.anim);
    @import("cad.zig").keep(&st.cad);
    @import("lcam.zig").keep(&st.lcam);
    @import("fields.zig").keep(&st.flds);
    @import("particles.zig").keep(&st.psys);
    @import("ntree.zig").keep(&st.ntre);
    if (st.mats.len != material.count) {
        if (st.mats.len > 0) alloc_.free(st.mats);
        st.mats = alloc_.alloc(material.Material, material.count) catch &.{};
    }
    if (st.mats.len == material.count) @memcpy(st.mats, material.list[0..material.count]);
}

pub fn load(st: *const State) void {
    for (objects[0..count]) |*o| bury(o);
    @memcpy(objects[0..st.count], st.objects[0..st.count]);
    count = st.count;
    active = st.active;
    cursor = st.cursor;
    render_camera = st.render_camera;
    probe.restore(st.probes);
    @import("folders.zig").load(&st.folders);
    @import("frange.zig").r = st.range;
    @import("anim.zig").restore(st.anim);
    @import("cad.zig").restore(st.cad);
    @import("lcam.zig").restore(st.lcam);
    @import("fields.zig").restore(st.flds);
    @import("particles.zig").restore(st.psys);
    @import("ntree.zig").restore(st.ntre);
    if (!material.same(st.mats)) {
        @memcpy(material.list[0..st.mats.len], st.mats);
        material.count = st.mats.len;
        material.version +%= 1;
    }
}

fn sameObject(a: *const Object, b: *const Object) bool {
    return a.kind == b.kind and std.mem.eql(u8, a.name(), b.name()) and
        std.mem.eql(f32, &a.loc, &b.loc) and std.mem.eql(f32, &a.rot, &b.rot) and
        a.mods.n == b.mods.n and std.mem.eql(u8, std.mem.sliceAsBytes(a.mods.m[0..a.mods.n]), std.mem.sliceAsBytes(b.mods.m[0..b.mods.n])) and
        std.mem.eql(f32, &a.scl, &b.scl) and a.color == b.color and a.visible == b.visible and
        a.locked == b.locked and a.render == b.render and a.light_type == b.light_type and
        a.power == b.power and a.light_color == b.light_color and a.size == b.size and
        a.cone == b.cone and a.lens == b.lens and a.parent == b.parent and a.parent_gone == b.parent_gone and a.mesh == b.mesh and a.mres == b.mres and a.mat == b.mat and
        a.ref == b.ref and a.folder == b.folder and a.sk == b.sk;
}

/// Whether the scene differs from a snapshot in anything but the selection.
pub fn differs(st: *const State) bool {
    if (st.count != count or st.render_camera != render_camera) return true;
    if (st.probes != probe.cur) return true;
    if (!material.same(st.mats)) return true;
    if (!@import("folders.zig").same(&st.folders)) return true;
    if (!std.meta.eql(st.range, @import("frange.zig").r)) return true;
    if (st.anim != @import("anim.zig").cur) return true;
    if (!@import("cad.zig").same(st.cad)) return true;
    if (st.lcam != @import("lcam.zig").cur) return true;
    if (st.flds != @import("fields.zig").cur) return true;
    if (st.psys != @import("particles.zig").cur) return true;
    if (!@import("ntree.zig").same(st.ntre)) return true;
    for (objects[0..count], st.objects[0..count]) |*a, *b| {
        if (!sameObject(a, b)) return true;
    }
    return false;
}

fn nameTaken(s: []const u8) bool {
    for (objects[0..count]) |*o| if (std.mem.eql(u8, o.name(), s)) return true;
    return false;
}

// no orange or gold: those are the selection outline's colours
const palette = [_]u32{ 0xb8bcc4, 0xe06c75, 0x98c379, 0x61afef, 0xc678dd, 0x56b6c2, 0x8fa3bf, 0xa7c080 };

var next_oid: u32 = 1;
/// The next new object's persistent id (the original's uid_next): 1 for a
/// new scene, after a file's ids when one is read; undo leaves it.
pub var uid_next: u32 = 1;

/// Objects no longer here (deleted, or dropped by undo): oid -> the uid they
/// had, and back. A reference to one (an animation channel) is written as the
/// original keeps it: that uid. A file's reference to a uid it has no object
/// for gets an oid of its own here too (foreignOid).
var gone: std.AutoHashMapUnmanaged(u32, u32) = .empty;
var gone_uid: std.AutoHashMapUnmanaged(u32, u32) = .empty;

fn bury(o: *const Object) void {
    if (o.oid == 0) return;
    gone.put(alloc_, o.oid, o.uid) catch {};
    gone_uid.put(alloc_, o.uid, o.oid) catch {};
}

/// The uid an oid stands for: the object's, or the one it had.
pub fn uidOfOid(oid: u32) ?u32 {
    if (findOid(oid)) |i| return objects[i].uid;
    return gone.get(oid);
}

/// An oid for a uid no object here has (a file's reference to a deleted object):
/// the same one for the same uid, never an object's.
pub fn foreignOid(uid: u32) u32 {
    if (gone_uid.get(uid)) |o| {
        if (findOid(o) == null and gone.get(o) == uid) return o;
    }
    const o = next_oid;
    next_oid +%= 1;
    if (next_oid == 0) next_oid = 1;
    gone.put(alloc_, o, uid) catch {};
    gone_uid.put(alloc_, uid, o) catch {};
    return o;
}

/// Give object i a new identity (every new object gets one) and a new
/// persistent id.
pub fn stamp(i: usize) void {
    objects[i].oid = next_oid;
    next_oid +%= 1;
    if (next_oid == 0) next_oid = 1;
    objects[i].uid = uid_next;
    uid_next +%= 1;
}

/// The index of the object with this persistent id.
pub fn findUid(uid: u32) ?usize {
    if (uid == 0) return null;
    for (objects[0..count], 0..) |*o, i| {
        if (o.uid == uid) return i;
    }
    return null;
}

/// The index of the object with this identity.
pub fn findOid(oid: u32) ?usize {
    if (oid == 0) return null;
    for (objects[0..count], 0..) |*o, i| {
        if (o.oid == oid) return i;
    }
    return null;
}

/// Adds an object of `kind`, selects it, and returns its index (null when full).
pub fn add(kind: Kind) ?usize {
    if (count >= max_objects) return null;
    var o = Object{ .kind = kind, .mesh = primMesh(kind) };
    if (kind == .light) o.color = 0xe5c07b;
    if (kind == .camera) o.color = 0x61afef;
    if (kind == .field) o.color = 0x9ad0a0;
    if (kind == .armature) o.color = 0xb4b8c0; // (type_colors: an armature's)
    var buf: [32]u8 = undefined;
    var nm: []const u8 = kind.label();
    var i: u32 = 1;
    while (nameTaken(nm)) : (i += 1) {
        nm = std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ kind.label(), i }) catch kind.label();
    }
    o.setName(nm);
    if (kind.isMesh()) {
        // new objects go to the 3D cursor, as in the original
        o.loc = cursor;
        o.color = 0xb4b8c0; // (obj_new: the original's type_colors, a mesh's)
    }
    objects[count] = o;
    stamp(count);
    count += 1;
    selectOnly(count - 1);
    return count - 1;
}

pub fn remove(idx: usize) void {
    if (idx >= count) return;
    bury(&objects[idx]);
    // its children stay where they are and follow nothing, as in the original:
    // their OB_PARENT keeps the deleted one's uid (PRNT), which no object has
    for (objects[0..count], 0..) |*o, k| {
        if (o.parent != null and o.parent.? == idx) {
            const w = world(k);
            o.parent = null;
            o.parent_gone = objects[idx].uid;
            setWorld(k, w);
        }
    }
    for (objects[0..count]) |*o| {
        if (o.parent) |p| {
            if (p > idx) o.parent = p - 1;
        }
    }
    var i = idx;
    while (i + 1 < count) : (i += 1) objects[i] = objects[i + 1];
    count -= 1;
    if (render_camera) |c| {
        if (c == idx) render_camera = null else if (c > idx) render_camera = c - 1;
    }
    if (active) |s| {
        if (s == idx) active = null else if (s > idx) active = s - 1;
    }
}

pub fn find(nm: []const u8) ?usize {
    for (objects[0..count], 0..) |*o, i| if (std.ascii.eqlIgnoreCase(o.name(), nm)) return i;
    return null;
}

pub fn faceCount() u32 {
    var f: u32 = 0;
    for (0..count) |i| {
        if (objects[i].kind == .sketch) continue; // (its lines: no faces)
        if (@import("mods.zig").of(i)) |me| f += me.faces();
    }
    return f;
}
