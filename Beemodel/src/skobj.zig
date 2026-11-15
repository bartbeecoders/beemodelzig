// Sketch objects (sketchobj.s): creation, editing helpers, the display mesh,
// drawing, the file's SKCH chunk.
//
// A sketch object (.sketch) carries its sketch block (Object.sk) and a display
// mesh of 2-point polygons (Object.mesh, made again after each solve) so
// bounds, picking and the outliner treat it like any object. The viewport
// draws the entities themselves, coloured by their constraint status when the
// sketch is selected: fully constrained light, under-constrained blue,
// conflicts red.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const sk = @import("sketch.zig");
const undo = @import("undo.zig");

pub const Block = sk.Block;
pub const COL_FULLY: u32 = 0xe8eaee;
pub const COL_UNDER: u32 = 0x5aa9ff;
pub const COL_CONFL: u32 = 0xff5a5a;
pub const COL_IDLE: u32 = 0x8a9bb0; // a sketch object's colour
const SEGS = 48; // segments in a full circle

const A = std.heap.page_allocator;

// --- blocks: who holds them -----------------------------------------------------

fn sceneHolds(b: *const Block) usize {
    var n: usize = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (o.sk) |p| {
            if (p == b) n += 1;
        }
    }
    return n;
}

fn markAll(f: *const fn (*Block) void) void {
    for (scene.objects[0..scene.count]) |*o| {
        if (o.sk) |p| f(p);
    }
    undo.markSketches(f);
}

var collected_at: [3]usize = .{ 0, 0, 0 };

/// Free the blocks neither the scene nor a step holds (undo's collect calls it).
pub fn collect() void {
    if (sk.liveCount() == 0) return;
    const sig = [3]usize{ sk.made, undo.count(), undo.current() };
    if (std.mem.eql(usize, &sig, &collected_at)) return;
    collected_at = sig;
    sk.collect(markAll);
}

/// What the original's block would count in SK_REFS: the objects holding it
/// and the snapshots taken while it was there.
pub fn refsOf(b: *const Block) u32 {
    const n = sceneHolds(b) + undo.sketchHolds(b, true);
    return @intCast(@max(n, 1));
}

// --- objects -----------------------------------------------------------------------

/// The object i's sketch block, if it is a sketch with one.
pub fn of(i: usize) ?*Block {
    if (i >= scene.count) return null;
    const o = &scene.objects[i];
    if (o.kind != .sketch) return null;
    return o.sk;
}

/// The sketch object called name (skx_get), or null.
pub fn get(name: []const u8) ?usize {
    const i = scene.find(name) orelse return null;
    return if (of(i) != null) i else null;
}

/// As the original's unique_name: the name (26 bytes at most), then ".001" ...
fn uniqueName(o: *scene.Object, base0: []const u8) void {
    var base = base0[0..@min(base0.len, 26)];
    while (base.len > 0 and base[base.len - 1] & 0xc0 == 0x80) base = base[0 .. base.len - 1];
    o.setName(base);
    var buf: [32]u8 = undefined;
    var k: u32 = 1;
    while (scene.find(o.name()) != null and k <= 999) : (k += 1) {
        o.setName(std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ base, k }) catch return);
    }
}

/// skx_create: a new sketch object on a plane (0 XY, 1 XZ, 2 YZ) at an offset
/// along its normal; it is not selected. Null: no room.
pub fn create(name: ?[]const u8, plane: u32, offset: f64) ?usize {
    if (scene.count >= scene.max_objects) return null;
    const b = sk.new(plane) orelse return null;
    b.offset = offset;
    const mi = displayMesh(b) orelse return null;
    var o = scene.Object{ .kind = .sketch, .mesh = mi, .sk = b, .color = COL_IDLE };
    uniqueName(&o, name orelse "Sketch");
    scene.objects[scene.count] = o;
    scene.stamp(scene.count);
    scene.count += 1;
    return scene.count - 1;
}

/// skx_begin (sk_own): object i's sketch, ours to change (a copy when anything
/// else - a step, a duplicate - still holds it).
pub fn begin(i: usize) ?*Block {
    const b = of(i) orelse return null;
    if (sceneHolds(b) + undo.sketchHolds(b, false) <= 1) return b;
    const c = sk.copy(b) orelse return null;
    scene.objects[i].sk = c;
    return c;
}

/// skx_end: solve, show it anew -> the degrees of freedom left (-1: none).
pub fn end(i: usize) i32 {
    hook();
    const b = begin(i) orelse return -1;
    _ = sk.solve(b);
    if (displayMesh(b)) |mi| {
        const old = scene.objects[i].mesh;
        scene.objects[i].mesh = mi;
        if (old) |om| release(om);
    }
    @import("app.zig").dirty = true;
    // features built on this sketch follow (not while every sketch solves again)
    if (rebuild_depth == 0 and @import("feature.zig").uses(scene.objects[i].oid)) @import("feature.zig").rebuild();
    return b.dof;
}

/// cad_rebuild's cr_depth: every sketch solves before the features rebuild once.
var rebuild_depth: u32 = 0;

/// The display mesh a sketch showed before: freed at once when no object and
/// no undo step holds it (the original unrefs it), so a drag that shows the
/// sketch anew at every motion does not fill the mesh slots.
fn release(mi: u16) void {
    for (scene.objects[0..scene.count]) |*o| {
        if (o.mesh == mi or o.mres == mi) return;
    }
    if (undo.anyStepHolds(mi)) return;
    scene.freeMeshSlot(mi);
}

/// Dimensions with expressions evaluate through the CAD document (its
/// parameters, its units); a change of those solves every sketch again.
fn hook() void {
    sk.evalExpr = @import("cad.zig").eval;
    @import("cad.zig").rebuild_hook = rebuildAll;
}

/// cad_rebuild: after parameters or units changed, every sketch solves again
/// (its dimensions may be expressions).
pub fn rebuildAll() void {
    rebuild_depth += 1;
    for (0..scene.count) |i| {
        if (of(i) != null) _ = end(i);
    }
    rebuild_depth -= 1;
    @import("feature.zig").rebuild(); // then the solids made from them
}

// --- adding geometry -----------------------------------------------------------------

pub fn lineXY(b: *Block, x1: f64, y1: f64, x2: f64, y2: f64) i32 {
    const a = sk.addPoint(b, x1, y1);
    const c = sk.addPoint(b, x2, y2);
    if (a < 0 or c < 0) return -1;
    return sk.addLine(b, a, c);
}

pub fn circleXY(b: *Block, cx: f64, cy: f64, r: f64) i32 {
    const c = sk.addPoint(b, cx, cy);
    if (c < 0) return -1;
    return sk.addCircle(b, c, r);
}

/// An arc counter-clockwise from angle a0 to a1 (radians).
pub fn arcXY(b: *Block, cx: f64, cy: f64, r: f64, a0: f64, a1: f64) i32 {
    const c = sk.addPoint(b, cx, cy);
    const s0 = sk.fsincos(a0);
    const p = sk.addPoint(b, s0[1] * r + cx, s0[0] * r + cy);
    const s1 = sk.fsincos(a1);
    const q = sk.addPoint(b, s1[1] * r + cx, s1[0] * r + cy);
    if (c < 0 or p < 0 or q < 0) return -1;
    return sk.addArc(b, c, p, q, r);
}

/// skx_rect: four lines (bottom, right, top, left) joined at the corners,
/// horizontal and vertical -> the first line, or -1.
pub fn rect(b: *Block, x: f64, y: f64, w: f64, h: f64) i32 {
    const x0 = x;
    const y0 = y;
    const x1 = x + w;
    const y1 = y + h;
    const first: i32 = @intCast(b.nent);
    if (lineXY(b, x0, y0, x1, y0) < 0) return -1;
    if (lineXY(b, x1, y0, x1, y1) < 0) return -1;
    if (lineXY(b, x1, y1, x0, y1) < 0) return -1;
    if (lineXY(b, x0, y1, x0, y0) < 0) return -1;
    var k: i32 = 0;
    while (k < 4) : (k += 1) {
        const p = sk.entPoint(b, first + k, 1);
        const q = sk.entPoint(b, first + @mod(k + 1, 4), 0);
        _ = sk.addCon(b, sk.C_COINCIDENT, p, q, -1, 0, null);
    }
    k = 0;
    while (k < 4) : (k += 1) {
        _ = sk.addCon(b, if (k & 1 == 0) sk.C_HORIZONTAL else sk.C_VERTICAL, first + k, -1, -1, 0, null);
    }
    return first;
}

// --- display -----------------------------------------------------------------------

fn v3(p: [3]f32) m.V3 {
    return .{ p[0], p[1], p[2] };
}

/// A mesh of 2-point polygons (plane coordinates) for every entity, then a
/// small origin cross (the original's display_mesh, in its order).
pub fn displayMesh(b: *const Block) ?u16 {
    var nv: usize = 0;
    const ne = @min(b.nent, sk.MAX_ENT);
    for (b.ents[0..ne]) |*e| nv += sk.entSegs(e) + 1;
    const verts = A.alloc(m.V3, nv + 4) catch return null;
    defer A.free(verts);
    const poff = A.alloc(u32, nv + 2 + 1) catch return null;
    defer A.free(poff);
    const loops = A.alloc(u32, (nv + 2) * 2) catch return null;
    defer A.free(loops);
    var v: u32 = 0;
    var np: usize = 0;
    var nl: u32 = 0;
    poff[0] = 0;
    for (b.ents[0..ne]) |*e| {
        const n = sk.entSegs(e);
        const first = v;
        var i: u32 = 0;
        while (i <= n) : (i += 1) {
            const uv = sk.entAt(b, e, i, n);
            verts[v] = v3(sk.planeXyz(b, uv[0], uv[1]));
            v += 1;
            if (i > 0) {
                loops[nl] = first + i - 1;
                loops[nl + 1] = first + i;
                nl += 2;
                np += 1;
                poff[np] = nl;
            }
        }
    }
    // the origin cross (u, v)
    var k: u32 = 0;
    while (k < 2) : (k += 1) {
        verts[v] = v3(sk.planeXyz(b, 0, 0));
        const mark: f64 = 0.25;
        verts[v + 1] = v3(if (k == 0) sk.planeXyz(b, mark, 0) else sk.planeXyz(b, 0, mark));
        loops[nl] = v;
        loops[nl + 1] = v + 1;
        nl += 2;
        np += 1;
        poff[np] = nl;
        v += 2;
    }
    return scene.addMesh(verts[0..v], poff[0 .. np + 1], loops[0..nl]);
}

/// The colour of entity e drawn by its status.
pub fn statusColor(e: *const sk.Ent) u32 {
    var c: u32 = COL_UNDER;
    if (e.flags & sk.F_FULL != 0) c = COL_FULLY;
    if (e.flags & sk.F_BAD != 0) c = COL_CONFL;
    return c;
}

/// skx_draw: object i's entities as world-space segments through `line`
/// (colour 0: by their status).
pub fn draw(i: usize, colour: u32, ctx: anytype, comptime line: fn (@TypeOf(ctx), m.V3, m.V3, u32) void) void {
    const b = of(i) orelse return;
    const mtx = scene.world(i);
    const ne = @min(b.nent, sk.MAX_ENT);
    for (b.ents[0..ne]) |*e| {
        const col = if (colour != 0) colour else statusColor(e);
        const n = sk.entSegs(e);
        var uv = sk.entAt(b, e, 0, n);
        var p0 = m.xform(mtx, v3(sk.planeXyz(b, uv[0], uv[1])));
        var k: u32 = 1;
        while (k <= n) : (k += 1) {
            uv = sk.entAt(b, e, k, n);
            const p1 = m.xform(mtx, v3(sk.planeXyz(b, uv[0], uv[1])));
            line(ctx, p0, p1, col);
            p0 = p1;
        }
    }
}

// --- the file: SKCH = count, then (object index, block) per sketch -------------------

/// The SKCH chunk's data (bee.zig's buffer).
pub fn writeChunk(buf: anytype) void {
    var n: u32 = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (o.sk != null) n += 1;
    }
    buf.u32_(n);
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        const b = o.sk orelse continue;
        buf.u32_(@intCast(i));
        var head: [8]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], refsOf(b), .little);
        std.mem.writeInt(u32, head[4..8], b.bytes, .little);
        buf.bytes(&head);
        buf.bytes(sk.bytesOf(b)[8..]);
    }
}

/// Read SKCH after the objects are back (ours: the file's object -> ours).
/// Returns false when some of it could not be used.
pub fn readChunk(c: []const u8, ours: []const ?u16) bool {
    if (c.len < 4) return c.len == 0;
    var n = std.mem.readInt(u32, c[0..4], .little);
    var o: usize = 4;
    var ok = true;
    while (n > 0) : (n -= 1) {
        if (c.len - o < 4 + sk.SK_SZ) return false;
        const fi = std.mem.readInt(u32, c[o..][0..4], .little);
        const data = c[o + 4 ..][0..sk.SK_SZ];
        o += 4 + sk.SK_SZ;
        const i = if (fi < ours.len) ours[fi] orelse {
            ok = false;
            continue;
        } else {
            ok = false;
            continue;
        };
        if (scene.objects[i].kind != .sketch) {
            ok = false;
            continue;
        }
        const plane = std.mem.readInt(u32, data[8..12], .little);
        const b = sk.new(plane) orelse return false;
        // its content (refs and size its own; the counts checked)
        @memcpy(@as([*]u8, @ptrCast(b))[8..sk.SK_SZ], data[8..]);
        if (b.npt > sk.MAX_PT or b.nent > sk.MAX_ENT or b.ncon > sk.MAX_CON) {
            ok = false;
            continue; // (the block goes with the next collect)
        }
        scene.objects[i].sk = b;
        _ = end(i); // solved and shown again
    }
    return ok;
}

test "rectangle and display mesh order" {
    // (no scene: the block and the mesh's vertex count only)
    const b = sk.new(0).?;
    const first = rect(b, 0, 0, 4, 2);
    try std.testing.expectEqual(@as(i32, 0), first);
    try std.testing.expectEqual(@as(u32, 8), b.npt);
    try std.testing.expectEqual(@as(u32, 8), b.ncon);
    _ = sk.solve(b);
    try std.testing.expectEqual(@as(i32, 4), b.dof);
}
