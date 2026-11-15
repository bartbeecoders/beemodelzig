// Mesh analysis and its overlays (View > Analysis, the viewport's Overlays), as
// the original's repair.s: edges by how many faces use them and in which
// direction, faces by area and by how far they face down, vertices no face uses.
// The overlays show the classes on the active mesh (or the one being edited),
// with a line of counts in the corner. The result stays until the mesh, its
// transform or the angle changes.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const gfx = @import("gfx.zig");
const app = @import("app.zig");
const em = @import("editmesh.zig");
const vp = @import("viewport.zig");
const ui = @import("ui.zig");

const A = std.heap.page_allocator;

pub const NORMALS: u32 = 1;
pub const NONMAN: u32 = 2;
pub const BOUND: u32 = 4;
pub const DEGEN: u32 = 8;
pub const OVER: u32 = 16;
/// Wall thickness (print.zig): faces under the minimum red, under twice it yellow.
pub const THIN: u32 = 32;

const COL_NORMAL = 0xa8e050;
const COL_BOUND = 0x40e0e0;
const COL_NONMAN = 0xf04848;
const COL_DEGEN = 0xe050e0;
const COL_OVER = 0xf08040;
const COL_THIN = 0xff3030;
const COL_THIN2 = 0xf0d040;

const FC_DEGEN = 1;
const FC_OVER = 2;

pub var flags: u32 = 0;
/// Overhangs: degrees from straight down (0: 45).
pub var angle: f32 = 0;

pub const Counts = struct { boundary: u32 = 0, nonmanifold: u32 = 0, degenerate: u32 = 0, loose: u32 = 0, overhang: u32 = 0 };

/// (not unit: |n| is twice the area)
fn newell(me: *const scene.Mesh, p: usize, n: *m.V3, centre: *m.V3) void {
    const l = me.loops[me.poff[p]..me.poff[p + 1]];
    n.* = .{ 0, 0, 0 };
    var c: m.V3 = .{ 0, 0, 0 };
    for (l, 0..) |a, k| {
        const i = me.verts[a];
        const j = me.verts[l[(k + 1) % l.len]];
        n[0] += (i[1] - j[1]) * (i[2] + j[2]);
        n[1] += (i[2] - j[2]) * (i[0] + j[0]);
        n[2] += (i[0] - j[0]) * (i[1] + j[1]);
        c = m.add(c, i);
    }
    centre.* = if (l.len > 0) m.scale(c, 1 / @as(f32, @floatFromInt(l.len))) else c;
}

fn faceClass(me: *const scene.Mesh, p: usize, w: *const m.M4, cos_a: f32) u8 {
    const l = me.loops[me.poff[p]..me.poff[p + 1]];
    if (l.len < 3) return FC_DEGEN;
    for (l, 0..) |a, i| {
        for (l[i + 1..]) |b| {
            if (a == b) return FC_DEGEN; // a corner repeated
        }
    }
    var n: m.V3 = undefined;
    var c: m.V3 = undefined;
    newell(me, p, &n, &c);
    const size = m.sub(me.hi, me.lo);
    const d2 = m.dot(size, size);
    if (m.dot(n, n) <= d2 * d2 * 1.0e-20) return FC_DEGEN;
    // the world normal: the matrix's rotation, enough for the direction with
    // uniform-ish scales
    const y = w[4] * n[0] + w[5] * n[1] + w[6] * n[2];
    var len2: f32 = 0;
    for (0..3) |r| {
        const q = w[r * 4] * n[0] + w[r * 4 + 1] * n[1] + w[r * 4 + 2] * n[2];
        len2 += q * q;
    }
    return if (-y / @sqrt(len2) > cos_a) FC_OVER else 0;
}

// --- the result ------------------------------------------------------------------

pub const Cache = struct {
    serial: u32 = 0,
    shape: u32 = 0,
    obj: usize = 0,
    mtx: m.M4 = undefined,
    ang: f32 = -1,
    valid: bool = false,
    counts: Counts = .{},
    fcls: []u8 = &.{},
    bound: std.ArrayList([2]u32) = .empty,
    nonman: std.ArrayList([2]u32) = .empty,
};
var cache = Cache{};

fn angleCos() f32 {
    const a = if (angle > 0) angle else 45;
    return @floatCast(@cos(@as(f64, a * 0.017453292)));
}

/// `keys`: per loop its edge, the smaller vertex in the high bits, then the
/// larger, then the direction.
fn analyse(me: *const scene.Mesh, w: *const m.M4) !void {
    const c = &cache;
    c.valid = false;
    c.counts = .{};
    c.bound.clearRetainingCapacity();
    c.nonman.clearRetainingCapacity();
    const np = me.poff.len - 1;
    if (c.fcls.len != np) {
        if (c.fcls.len > 0) A.free(c.fcls);
        c.fcls = &.{};
        c.fcls = try A.alloc(u8, np);
    }
    const keys = try A.alloc(u64, me.loops.len);
    defer A.free(keys);
    const used = try A.alloc(bool, me.verts.len);
    defer A.free(used);
    @memset(used, false);
    var n: usize = 0;
    const cos_a = angleCos();
    for (0..np) |p| {
        const l = me.loops[me.poff[p]..me.poff[p + 1]];
        for (l, 0..) |a, k| {
            const b = l[(k + 1) % l.len];
            used[a] = true;
            const lo = @min(a, b);
            const hi = @max(a, b);
            // (31 bits a vertex: no mesh has more)
            keys[n] = @as(u64, lo) << 33 | @as(u64, hi) << 1 | @intFromBool(a > b);
            n += 1;
        }
        c.fcls[p] = faceClass(me, p, w, cos_a);
        if (c.fcls[p] & FC_DEGEN != 0) c.counts.degenerate += 1;
        if (c.fcls[p] & FC_OVER != 0) c.counts.overhang += 1;
    }
    std.sort.pdq(u64, keys[0..n], {}, std.sort.asc(u64));
    var i: usize = 0;
    while (i < n) {
        const e = keys[i] >> 1;
        var uses: u32 = 0;
        var fwd: u32 = 0;
        while (i < n and keys[i] >> 1 == e) : (i += 1) {
            uses += 1;
            if (keys[i] & 1 == 0) fwd += 1;
        }
        const pair = [2]u32{ @intCast(e >> 32), @intCast(e & 0xffffffff) };
        if (uses == 1) {
            c.counts.boundary += 1;
            try c.bound.append(A, pair);
        } else if (uses > 2 or fwd != 1) {
            c.counts.nonmanifold += 1;
            try c.nonman.append(A, pair);
        }
    }
    for (used) |u| {
        if (!u) c.counts.loose += 1;
    }
    c.valid = true;
}

/// The mesh the overlays are about.
fn subject() ?usize {
    if (em.active and em.obj < scene.count) return em.obj;
    const a = scene.active orelse return null;
    if (a >= scene.count or !scene.objects[a].kind.isMesh()) return null;
    return a;
}

/// The result for this object, up to date. Null: no mesh, no memory.
fn result() ?*const Cache {
    return of(subject() orelse return null);
}

/// mesh_analyze for object i (the print check's): edges and faces by class.
pub fn of(i: usize) ?*const Cache {
    const me = scene.meshOfObj(i) orelse return null;
    const w = scene.world(i);
    const c = &cache;
    const a = if (angle > 0) angle else 45;
    if (c.valid and c.serial == me.serial and c.shape == me.shape and c.obj == i and c.ang == a and std.mem.eql(f32, &c.mtx, &w)) return c;
    analyse(me, &w) catch return null;
    c.serial = me.serial;
    c.shape = me.shape;
    c.obj = i;
    c.mtx = w;
    c.ang = a;
    return c;
}

/// What the overlays' picture depends on, besides the scene.
pub fn stateWord() [2]u64 {
    return .{ @as(u64, flags) << 32 | @as(u32, @bitCast(angle)), @as(u32, @bitCast(@import("print.zig").th_min)) };
}

// --- the commands ----------------------------------------------------------------

fn prepared(_: []const u8, _: usize, _: usize) void {
    _ = result();
    // (and the walls, for Show Thin Walls)
    if (flags & THIN != 0) {
        if (subject()) |i| _ = @import("print.zig").thFaces(i);
    }
    app.dirty = true;
}

/// (a big mesh takes a while the first time)
pub fn prepare() void {
    if (flags != 0) @import("jobui.zig").later(prepared, "Analysing the mesh", "", 0, 0);
}

pub fn toggle(f: u32) void {
    flags ^= f;
    prepare();
    app.dirty = true;
}

pub fn opNormals() void {
    toggle(NORMALS);
}
pub fn opNonman() void {
    toggle(NONMAN);
}
pub fn opBound() void {
    toggle(BOUND);
}
pub fn opDegen() void {
    toggle(DEGEN);
}
pub fn isNormals() bool {
    return flags & NORMALS != 0;
}
pub fn isNonman() bool {
    return flags & NONMAN != 0;
}
pub fn isBound() bool {
    return flags & BOUND != 0;
}
pub fn isDegen() bool {
    return flags & DEGEN != 0;
}
pub fn isOver() bool {
    return flags & OVER != 0;
}

/// view.show_overhangs [degrees]: an angle turns it on with it.
pub fn opOverhang(arg: []const u8) void {
    const t = std.mem.trim(u8, arg, " \"");
    if (t.len > 0) {
        if (std.fmt.parseFloat(f32, t)) |x| {
            if (std.math.isFinite(x)) {
                angle = x;
                flags |= OVER;
                prepare();
                app.dirty = true;
                return;
            }
        } else |_| {}
    }
    toggle(OVER);
}

// --- drawing ---------------------------------------------------------------------

const P = [3]f32; // screen x, y, 1 / depth

fn proj(c: *const vp.Cam, w: *const m.M4, p: m.V3) ?P {
    const v = c.toView(m.xform(w.*, p));
    if (v[2] < vp.near) return null;
    return vp.scr(c, v);
}

fn line(cv: *gfx.Canvas, wire: bool, a: P, b: P, col: u32) void {
    vp.segment(cv, a, b, col, !wire); // (cut to the view: a far end keeps the direction)
}

/// Depth tested, two pixels wide.
fn edge(cv: *gfx.Canvas, wire: bool, a: P, b: P, col: u32) void {
    line(cv, wire, a, b, col);
    line(cv, wire, .{ a[0], a[1] + 1, a[2] }, .{ b[0], b[1] + 1, b[2] }, col);
}

fn dot(cv: *gfx.Canvas, wire: bool, p: P, col: u32) void {
    if (!(@abs(p[0]) < 30000 and @abs(p[1]) < 30000)) return;
    const x: i32 = @intFromFloat(p[0]);
    const y: i32 = @intFromFloat(p[1]);
    if (!cv.clip.contains(x, y)) return;
    if (!wire) {
        if (cv.zbuf) |z| {
            if (p[2] * 1.01 + 1e-4 < z[@intCast(y * cv.w + x)]) return; // hidden
        }
    }
    cv.fill(.{ .x = x - 2, .y = y - 2, .w = 5, .h = 5 }, col);
}

/// In the viewport being drawn, its depth buffer filled.
pub fn draw(cv: *gfx.Canvas, c: *const vp.Cam, v: *const vp.View) void {
    if (flags == 0) return;
    const r = result() orelse return;
    const me = scene.meshOfObj(r.obj) orelse return;
    const w = &r.mtx;
    const wire = v.wire;
    if (flags & BOUND != 0) {
        for (r.bound.items) |e| {
            edge(cv, wire, proj(c, w, me.verts[e[0]]) orelse continue, proj(c, w, me.verts[e[1]]) orelse continue, COL_BOUND);
        }
    }
    if (flags & NONMAN != 0) {
        for (r.nonman.items) |e| {
            edge(cv, wire, proj(c, w, me.verts[e[0]]) orelse continue, proj(c, w, me.verts[e[1]]) orelse continue, COL_NONMAN);
        }
    }
    // wall thickness (print.s th_faces), by the minimum
    const th: ?[]const f32 = if (flags & THIN != 0) @import("print.zig").thFaces(r.obj) else null;
    const minw = @import("print.zig").minWorld();
    for (0..me.poff.len - 1) |p| {
        const fc = r.fcls[p];
        var col: u32 = 0;
        if (fc & FC_DEGEN != 0 and flags & DEGEN != 0) {
            col = COL_DEGEN;
        } else if (th != null and p < th.?.len and !(th.?[p] >= minw)) {
            col = COL_THIN;
        } else if (th != null and p < th.?.len and !(th.?[p] >= minw + minw)) {
            col = COL_THIN2;
        } else if (fc & FC_OVER != 0 and flags & OVER != 0) col = COL_OVER;
        if (col == 0 and flags & NORMALS == 0) continue;
        var n: m.V3 = undefined;
        var centre: m.V3 = undefined;
        newell(me, p, &n, &centre);
        if (col != 0) {
            const l = me.loops[me.poff[p]..me.poff[p + 1]];
            for (l, 0..) |a, k| {
                edge(cv, wire, proj(c, w, me.verts[a]) orelse continue, proj(c, w, me.verts[l[(k + 1) % l.len]]) orelse continue, col);
            }
            if (proj(c, w, centre)) |q| dot(cv, wire, q, col);
        }
        if (flags & NORMALS != 0) {
            // a line along the normal, as long as the face is wide: 0.4 sqrt(area)
            const nl = @sqrt(m.dot(n, n));
            if (nl <= 0) continue;
            const k = @sqrt(nl * 0.5) * 0.4 / nl;
            const a = proj(c, w, centre) orelse continue;
            const b = proj(c, w, m.add(centre, m.scale(n, k))) orelse continue;
            line(cv, wire, a, b, COL_NORMAL);
        }
    }
}

/// The counts, in the corner (UI units).
pub fn legend(rect: gfx.Rect) void {
    if (flags == 0) return;
    const r = result() orelse return;
    const c = r.counts;
    var b: [160]u8 = undefined;
    // the thin faces: under the minimum (when the overlay is on)
    var thin: u32 = 0;
    if (flags & THIN != 0) {
        if (@import("print.zig").thFaces(r.obj)) |th| {
            const minw = @import("print.zig").minWorld();
            for (th) |t| {
                if (!(t >= minw)) thin += 1;
            }
        }
    }
    const s = std.fmt.bufPrint(&b, "Analysis: {d} boundary  {d} non-manifold  {d} degenerate  {d} loose  {d} overhang  {d} thin", .{ c.boundary, c.nonmanifold, c.degenerate, c.loose, c.overhang, thin }) catch return;
    _ = ui.cv.text(rect.x + 10, rect.y + 64, s, ui.th.accent);
    // (the tests read the counts; records are short)
    var rb: [64]u8 = undefined;
    ui.record("analysis", std.fmt.bufPrint(&rb, "{d} {d} {d} {d} {d} {d}", .{ c.boundary, c.nonmanifold, c.degenerate, c.loose, c.overhang, thin }) catch "", .{ .x = rect.x + 10, .y = rect.y + 64, .w = 400, .h = 18 }, true);
}

// --- tests -----------------------------------------------------------------------

test "a repeated corner or no area is degenerate, a floor faces down" {
    var verts = [_]m.V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ 1, 1, 1 }, .{ 2, 0, 0 } };
    var poff = [_]u32{ 0, 3, 6, 9, 11 };
    var loops = [_]u32{ 0, 1, 2, 0, 2, 1, 0, 1, 0, 0, 1 };
    const me = scene.Mesh{ .verts = &verts, .poff = &poff, .loops = &loops, .tris = &.{}, .tri_poly = &.{}, .edges = 0, .lo = .{ 0, 0, 0 }, .hi = .{ 2, 1, 1 } };
    const id = m.identity();
    const cos_a = 0.70710677;
    // 0, 1, 2 winds up (-Y normal is the other way round)
    try std.testing.expectEqual(@as(u8, FC_OVER), faceClass(&me, 1, &id, cos_a) | faceClass(&me, 0, &id, cos_a));
    try std.testing.expectEqual(@as(u8, FC_DEGEN), faceClass(&me, 2, &id, cos_a));
    try std.testing.expectEqual(@as(u8, FC_DEGEN), faceClass(&me, 3, &id, cos_a));
}
