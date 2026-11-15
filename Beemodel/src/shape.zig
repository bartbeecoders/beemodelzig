// Shape keys (shape.s): a mesh's stored poses to blend. Key 0 is the Basis, then
// up to 31 more, each a name, a value and a position for every vertex. What
// shows is the mesh plus each key's offset from the Basis times its value,
// before the modifiers (mods.of). Values are animation channels
// ("shape:Cube:Smile"). A block lives on its mesh (as ME_SHAPE) and is copied
// with it, so an undo step that holds the old mesh holds the old keys.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const A = @import("alloc.zig").A;

pub const MAX = 32;
pub const Rec = extern struct { name: [24]u8, val: f32, pad: u32 = 0 };
/// The block's start, as saved.
pub const Head = extern struct { n: u32, nv: u32, bytes: u64, act: u32, pad: [3]u32 = .{ 0, 0, 0 }, keys: [MAX]Rec };
const POS = @sizeOf(Head);
comptime {
    std.debug.assert(POS == 1056 and @sizeOf(Rec) == 32);
}

pub const Block = struct {
    h: Head,
    pos: []m.V3, // n * nv

    pub fn at(b: *const Block, k: usize) []m.V3 {
        return b.pos[k * b.h.nv..][0..b.h.nv];
    }
    pub fn used(b: *const Block) usize {
        return POS + @as(usize, b.h.n) * b.h.nv * 12;
    }
};

fn pages(n: u32, nv: u32) u64 {
    return (@as(u64, n) * nv * 12 + POS + 4095) & ~@as(u64, 4095);
}

fn alloc(n: u32, nv: u32) ?*Block {
    const b = A.create(Block) catch return null;
    b.* = .{ .h = std.mem.zeroes(Head), .pos = A.alloc(m.V3, @as(usize, n) * nv) catch {
        A.destroy(b);
        return null;
    } };
    @memset(std.mem.sliceAsBytes(b.pos), 0);
    b.h.n = n;
    b.h.nv = nv;
    b.h.bytes = pages(n, nv);
    return b;
}

pub fn free(b: *Block) void {
    A.free(b.pos);
    A.destroy(b);
}

pub fn dup(b: *const Block) ?*Block {
    const c = alloc(b.h.n, b.h.nv) orelse return null;
    c.h = b.h;
    @memcpy(c.pos, b.pos);
    return c;
}

/// Its mesh's keys when they fit it.
pub fn of(i: usize) ?*Block {
    const o = &scene.objects[i];
    if (!o.kind.isMesh()) return null;
    const mi = o.mesh orelse return null;
    const me = &(scene.meshes[mi] orelse return null);
    return fits(me);
}

fn fits(me: *const scene.Mesh) ?*Block {
    const b = me.sk orelse return null;
    return if (b.h.nv == me.verts.len) b else null;
}

pub fn count(i: usize) u32 {
    return if (of(i)) |b| b.h.n else 0;
}

pub fn name(r: *const Rec) []const u8 {
    return std.mem.sliceTo(&r.name, 0);
}

/// The key's number (0 the Basis).
pub fn find(i: usize, nm: []const u8) ?u32 {
    const b = of(i) orelse return null;
    for (b.h.keys[0..b.h.n], 0..) |*r, k| {
        if (std.mem.eql(u8, name(r), nm)) return @intCast(k);
    }
    return null;
}

/// Do the keys move this mesh? (a value set, its vertices as when they were made)
pub fn active(me: *const scene.Mesh) bool {
    const b = fits(me) orelse return false;
    for (b.h.keys[1..b.h.n]) |*r| {
        if (r.val != 0) return true;
    }
    return false;
}

/// What the result hangs on: the values.
pub fn hashValues(h: *std.hash.Wyhash, me: *const scene.Mesh) void {
    const b = fits(me) orelse return;
    for (b.h.keys[1..b.h.n]) |*r| h.update(std.mem.asBytes(&r.val));
}

/// Into `out` (the mesh's own positions are in it already): + v (key - basis).
pub fn mix(me: *const scene.Mesh, out: []m.V3) void {
    const b = fits(me) orelse return;
    const basis = b.at(0);
    for (1..b.h.n) |k| {
        const v = b.h.keys[k].val;
        if (v == 0) continue;
        const ks = b.at(k);
        for (out, ks, basis) |*o, p, q| {
            for (0..3) |c| o[c] = (p[c] - q[c]) * v + o[c];
        }
    }
}

pub fn chanGet(i: usize, k: u32) ?f32 {
    const b = of(i) orelse return null;
    if (k == 0 or k >= b.h.n) return null;
    return b.h.keys[k].val;
}

/// The object's own mesh: shared with another object, it gets a copy.
fn unshare(i: usize) ?u16 {
    const mi = scene.objects[i].mesh orelse return null;
    for (scene.objects[0..scene.count], 0..) |*o, q| {
        if (q != i and o.mesh == mi) {
            const c = scene.cloneMesh(mi) orelse return null;
            scene.objects[i].mesh = c;
            return c;
        }
    }
    return mi;
}

/// A value as an evaluation sets it (no undo step).
pub fn chanSet(i: usize, k: u32, v: f32) bool {
    const b0 = of(i) orelse return false;
    if (k == 0 or k >= b0.h.n) return false;
    if (b0.h.keys[k].val == v) return true;
    // (a step keeps the mesh it saw: sk_mesh_own copies on ME_REFS, snapshots too)
    const undo = @import("undo.zig");
    const m0 = scene.objects[i].mesh.?;
    var mi = unshare(i) orelse return false;
    if (mi == m0 and undo.evalHolds(m0)) {
        mi = scene.cloneMesh(m0) orelse return false;
        scene.objects[i].mesh = mi;
    }
    undo.absorb(i);
    const b = of(i) orelse return false;
    b.h.keys[k].val = v;
    scene.bumpShape(mi);
    app.dirty = true;
    return true;
}

/// Its mesh, a copy the current undo step does not hold.
pub fn ownForEdit(i: usize) ?u16 {
    const mi = scene.objects[i].mesh orelse return null;
    if (!@import("undo.zig").holdsMesh(mi)) return unshare(i);
    const c = scene.cloneMesh(mi) orelse return null;
    scene.objects[i].mesh = c;
    return c;
}

// --- operators ----------------------------------------------------------------------

const need_obj = "  shape keys: select a mesh object (or name it after the key)";

fn target(obj: ?[]const u8) ?usize {
    const i: ?usize = if (obj) |nm| blk: {
        for (scene.objects[0..scene.count], 0..) |*o, q| {
            if (std.mem.eql(u8, o.name(), nm)) break :blk q;
        }
        break :blk null;
    } else scene.active;
    if (i) |x| {
        if (scene.objects[x].kind.isMesh() and scene.objects[x].mesh != null) return x;
    }
    app.log(need_obj, .{});
    return null;
}

fn nameArg(s: []const u8) [24]u8 {
    var b: [24]u8 = @splat(0);
    const n = @min(s.len, 23);
    @memcpy(b[0..n], s[0..n]);
    return b;
}

fn words() std.mem.TokenIterator(u8, .any) {
    return std.mem.tokenizeAny(u8, ops.arg, " \"");
}

/// shape.add <name> [object]
pub fn opAdd() void {
    var it = words();
    const nm = it.next() orelse return app.log("  no shape key named ", .{});
    const i = target(it.next()) orelse return;
    const mi0 = scene.objects[i].mesh.?;
    const m0 = &scene.meshes[mi0].?;
    if (m0.sk) |b| {
        if (b.h.nv != m0.verts.len) return app.log("  its vertices changed since the shape keys were made (shape.clear first)", .{});
    }
    const kn = nameArg(nm);
    const mi = ownForEdit(i) orelse return;
    const me = &scene.meshes[mi].?;
    var b = me.sk orelse blk: {
        const f = alloc(1, @intCast(me.verts.len)) orelse return app.log("  no room for more shape keys", .{});
        f.h.keys[0].name = nameArg("Basis");
        @memcpy(f.at(0), me.verts);
        me.sk = f;
        break :blk f;
    };
    var k: u32 = 0;
    while (k < b.h.n and !std.mem.eql(u8, name(&b.h.keys[k]), std.mem.sliceTo(&kn, 0))) k += 1;
    if (k == b.h.n) {
        if (k >= MAX) return app.log("  no room for more shape keys", .{});
        const c = alloc(k + 1, b.h.nv) orelse return app.log("  no room for more shape keys", .{});
        const bytes = c.h.bytes;
        c.h = b.h;
        c.h.bytes = bytes;
        c.h.n = k + 1;
        @memcpy(c.pos[0..b.pos.len], b.pos);
        c.h.keys[k].name = kn;
        free(b);
        b = c;
        me.sk = c;
    }
    // the mesh as it is -> the key, then the Basis back
    b.h.act = k;
    @memcpy(b.at(k), me.verts);
    if (k != 0) {
        @memcpy(me.verts, b.at(0));
        scene.refreshMesh(mi);
    } else scene.bumpShape(mi);
    app.log("  shape key {s} ({d} of {d})", .{ nm, k, b.h.n - 1 });
    app.dirty = true;
}

const Named = struct { i: usize, k: u32 };

fn named(nm: ?[]const u8, obj: ?[]const u8) ?Named {
    const w = nm orelse "";
    const i = target(obj) orelse return null;
    const k = find(i, w) orelse {
        app.log("  no shape key named {s}", .{w});
        return null;
    };
    return .{ .i = i, .k = k };
}

/// shape.edit <name> [object]
pub fn opEdit() void {
    var it = words();
    const nm = it.next();
    const t = named(nm, it.next()) orelse return;
    const mi = ownForEdit(t.i) orelse return;
    const me = &scene.meshes[mi].?;
    const b = me.sk.?;
    @memcpy(me.verts, b.at(t.k));
    b.h.act = t.k;
    scene.refreshMesh(mi);
    app.dirty = true;
}

/// shape.set <name> <value> [object]
pub fn opSet() void {
    var it = words();
    const bad = "  shape.set <key> <value> [object]";
    const nm = it.next() orelse return app.log(bad, .{});
    const vs = it.next() orelse return app.log(bad, .{});
    const v = std.fmt.parseFloat(f32, vs) catch return app.log(bad, .{});
    if (!std.math.isFinite(v)) return app.log(bad, .{});
    const i = target(it.next()) orelse return;
    const k = find(i, nm) orelse 0;
    if (k == 0) return app.log("  no shape key named {s}", .{nm});
    setValue(i, k, v);
}

/// A value by hand: one undo step.
pub fn setValue(i: usize, k: u32, v: f32) void {
    const was = chanGet(i, k) orelse return;
    if (was == v) return;
    const mi = ownForEdit(i) orelse return;
    scene.meshes[mi].?.sk.?.h.keys[k].val = v;
    scene.bumpShape(mi);
    app.dirty = true;
}

/// shape.remove <name> [object] (the Basis: all of them)
pub fn opRemove() void {
    var it = words();
    const nm = it.next();
    const t = named(nm, it.next()) orelse return;
    if (t.k == 0) return clearObject(t.i);
    const mi = ownForEdit(t.i) orelse return;
    const me = &scene.meshes[mi].?;
    const b = me.sk.?;
    const c = alloc(b.h.n - 1, b.h.nv) orelse return;
    const bytes = c.h.bytes;
    const n = b.h.n;
    c.h = b.h;
    c.h.bytes = bytes;
    c.h.n = n - 1;
    c.h.act = 0;
    const k: usize = t.k;
    std.mem.copyForwards(Rec, c.h.keys[k .. n - 1], b.h.keys[k + 1 .. n]);
    c.h.keys[n - 1] = std.mem.zeroes(Rec);
    for (0..k) |q| @memcpy(c.at(q), b.at(q));
    for (k + 1..n) |q| @memcpy(c.at(q - 1), b.at(q));
    me.sk = c;
    free(b);
    scene.bumpShape(mi);
    app.dirty = true;
}

fn clearObject(i: usize) void {
    const mi = ownForEdit(i) orelse return;
    const me = &scene.meshes[mi].?;
    if (me.sk) |b| free(b);
    me.sk = null;
    scene.bumpShape(mi);
    app.dirty = true;
}

/// shape.clear [object]
pub fn opClear() void {
    var it = words();
    const i = target(it.next()) orelse return;
    clearObject(i);
}

// --- the MSHK chunk: per mesh with shape keys: its index, its bytes, the block ---------

/// A key block of mesh `ix` (its place among the MESH chunks).
pub fn writeMesh(out: anytype, ix: u32, b: *const Block) void {
    out.u32_(ix);
    out.u32_(@intCast(b.used()));
    out.bytes(std.mem.asBytes(&b.h));
    out.bytes(std.mem.sliceAsBytes(b.pos));
}

/// The chunk back: what does not fit its mesh is left out. False: damaged.
pub fn readChunk(c: []const u8, mesh_map: []const ?u16) bool {
    var o: usize = 0;
    var ok = true;
    while (c.len - o >= 8 + POS) {
        const ix = std.mem.readInt(u32, c[o..][0..4], .little);
        const size = std.mem.readInt(u32, c[o + 4 ..][0..4], .little);
        if (size < POS or size > c.len - o - 8) return false;
        const d = c[o + 8..][0..size];
        o += 8 + @as(usize, size);
        const mi = if (ix < mesh_map.len) mesh_map[ix] else null;
        const slot = mi orelse continue;
        const me = &(scene.meshes[slot] orelse continue);
        const n = std.mem.readInt(u32, d[0..4], .little);
        const nv = std.mem.readInt(u32, d[4..8], .little);
        if (n == 0 or n > MAX or nv != me.verts.len or @as(u64, n) * nv * 12 + POS != size) {
            ok = false;
            continue;
        }
        const b = alloc(n, nv) orelse return false;
        const bytes = b.h.bytes;
        @memcpy(std.mem.asBytes(&b.h), d[0..POS]);
        b.h.bytes = bytes;
        if (b.h.act >= n) b.h.act = 0;
        for (&b.h.keys) |*r| {
            r.name[23] = 0;
            if (!std.math.isFinite(r.val)) r.val = 0;
        }
        @memcpy(std.mem.sliceAsBytes(b.pos), d[POS..]);
        for (b.pos) |*p| {
            for (p) |*x| {
                if (!std.math.isFinite(x.*)) x.* = 0;
            }
        }
        if (me.sk) |old| free(old);
        me.sk = b;
    }
    return ok and o == c.len;
}
