// A smart projection, packed (uv.s: uv_topo, smart_islands, ut_islands by equal
// UVs, pack_islands): what lightmap.bake gives every mesh as its second UV set.
// Polygons whose normals lie within 66 degrees of a seed go flat together; the
// islands that makes are scaled to one texel density, turned to their smallest
// box and placed on a skyline (tallest first, lowest place, then leftmost)
// inside the unit square. It works on a mesh it does not change, into a UV array
// per loop of the caller's, on the UI thread.
//
// uv.zig's unwrap and pack are built on this: the topology, the smart projection,
// the islands by equal UVs and the packing live here, LSCM and the rest there.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const A = std.heap.page_allocator;

pub const NONE: u32 = 0xffffffff;
const cos66: f32 = 0.4067366;
const tiny: f32 = 1e-20;
const big: f32 = 3.0e38;
const step: f32 = 0.03490659; // 2 degrees
const margin_k: f32 = 0.01; // the packing gap, of the size
const widen: f32 = 1.08;
const fit: f32 = 1.0001; // (rounding at the right edge)

pub const Topo = struct {
    me: *const scene.Mesh,
    uv: [][2]f32,
    lpoly: []u32,
    next: []u32,
    twin: []u32,
    pnrm: []m.V3,
    parea: []f32,
    puf: []u32,
    pisl: []u32,
    nisl: u32 = 0,
    ioff: []u32 = &.{},
    ipoly: []u32 = &.{},

    pub fn nl(t: *const Topo) usize {
        return t.me.loops.len;
    }
    pub fn np(t: *const Topo) usize {
        return t.me.poff.len - 1;
    }
    pub fn freeIslands(t: *Topo) void {
        if (t.ioff.len > 0) A.free(t.ioff);
        if (t.ipoly.len > 0) A.free(t.ipoly);
        t.ioff = &.{};
        t.ipoly = &.{};
    }
    /// The loops of island i (a polygon's are a run).
    fn each(t: *const Topo, i: usize, ctx: anytype, f: anytype) void {
        for (t.ipoly[t.ioff[i]..t.ioff[i + 1]]) |p| {
            for (t.me.poff[p]..t.me.poff[p + 1]) |l| f(ctx, &t.uv[l]);
        }
    }
};

fn key(a: u32, b: u32) u64 {
    return @as(u64, a) << 32 | b;
}

/// Every loop's polygon, next and twin (the loop on its edge back); polygons'
/// unit Newell normals and areas. The first loop of a directed edge wins, as in
/// the original (a non-manifold mesh keeps one).
pub fn topo(t: *Topo) bool {
    const me = t.me;
    const np = t.np();
    for (0..np) |p| {
        const a = me.poff[p];
        const b = me.poff[p + 1];
        for (a..b) |l| {
            t.lpoly[l] = @intCast(p);
            t.next[l] = if (l + 1 < b) @intCast(l + 1) else a;
        }
    }
    var hm: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer hm.deinit(A);
    hm.ensureTotalCapacity(A, @intCast(t.nl())) catch return false;
    for (0..t.nl()) |l| {
        const k = key(me.loops[l], me.loops[t.next[l]]);
        hm.putAssumeCapacity(k, hm.get(k) orelse @intCast(l));
    }
    for (0..t.nl()) |l| t.twin[l] = hm.get(key(me.loops[t.next[l]], me.loops[l])) orelse NONE;
    for (0..np) |p| {
        var n: m.V3 = .{ 0, 0, 0 };
        for (me.poff[p]..me.poff[p + 1]) |l| {
            const v1 = me.verts[me.loops[l]];
            const v2 = me.verts[me.loops[t.next[l]]];
            n[0] += (v1[1] - v2[1]) * (v1[2] + v2[2]);
            n[1] += (v1[2] - v2[2]) * (v1[0] + v2[0]);
            n[2] += (v1[0] - v2[0]) * (v1[1] + v2[1]);
        }
        const l = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        t.parea[p] = l * 0.5;
        const k = 1 / @max(l, tiny);
        t.pnrm[p] = .{ n[0] * k, n[1] * k, n[2] * k };
    }
    return true;
}

/// A projection's axes: u = (the smallest component's axis) x n, v = n x u.
pub fn axes(n0: m.V3) [2]m.V3 {
    var n = n0;
    var l = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    if (!(l > tiny)) {
        n = .{ 0, 0, 1 };
        l = 1;
    }
    const k = 1 / l;
    n = .{ n[0] * k, n[1] * k, n[2] * k };
    const ax = @abs(n[0]);
    const ay = @abs(n[1]);
    const az = @abs(n[2]);
    var a: m.V3 = .{ 0, 0, 0 };
    if (ax > ay) {
        if (ay > az) a[2] = 1 else a[1] = 1;
    } else if (ax > az) {
        a[2] = 1;
    } else a[0] = 1;
    return finishAxes(n, a);
}

fn finishAxes(n: m.V3, a: m.V3) [2]m.V3 {
    var u: m.V3 = .{ a[1] * n[2] - a[2] * n[1], a[2] * n[0] - a[0] * n[2], a[0] * n[1] - a[1] * n[0] };
    const k = 1 / @max(@sqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2]), tiny);
    u = .{ u[0] * k, u[1] * k, u[2] * k };
    return .{ u, .{ n[1] * u[2] - n[2] * u[1], n[2] * u[0] - n[0] * u[2], n[0] * u[1] - n[1] * u[0] } };
}

/// Groups of polygons within 66 degrees of a seed, each projected flat.
pub fn smartIslands(t: *Topo, queue: []u32) void {
    const me = t.me;
    @memset(t.pisl, NONE);
    var isl: u32 = 0;
    for (0..t.np()) |seed| {
        if (t.pisl[seed] != NONE) continue;
        t.pisl[seed] = isl;
        const sn = t.pnrm[seed];
        queue[0] = @intCast(seed);
        var head: usize = 0;
        var tail: usize = 1;
        while (head < tail) : (head += 1) {
            const p = queue[head];
            for (me.poff[p]..me.poff[p + 1]) |l| {
                const tw = t.twin[l];
                if (tw == NONE) continue;
                const nb = t.lpoly[tw];
                if (t.pisl[nb] != NONE) continue;
                const nn = t.pnrm[nb];
                if (nn[0] * sn[0] + nn[1] * sn[1] + nn[2] * sn[2] > cos66) {
                    t.pisl[nb] = isl;
                    queue[tail] = nb;
                    tail += 1;
                }
            }
        }
        const ax = axes(sn);
        for (queue[0..tail]) |p| {
            for (me.poff[p]..me.poff[p + 1]) |l| {
                const q = me.verts[me.loops[l]];
                t.uv[l] = .{
                    q[0] * ax[0][0] + q[1] * ax[0][1] + q[2] * ax[0][2],
                    q[0] * ax[1][0] + q[1] * ax[1][1] + q[2] * ax[1][2],
                };
            }
        }
        isl += 1;
    }
}

pub fn find(u: []u32, x0: u32) u32 {
    var x = x0;
    while (u[x] != x) {
        u[x] = u[u[x]];
        x = u[x];
    }
    return x;
}

fn eqUv(a: [2]f32, b: [2]f32) bool {
    return @as(u32, @bitCast(a[0])) == @as(u32, @bitCast(b[0])) and @as(u32, @bitCast(a[1])) == @as(u32, @bitCast(b[1]));
}

/// Polygon islands by equal UVs across their edges, numbered as the lowest
/// polygon comes up; a list per island.
pub fn islandsByUv(t: *Topo) bool {
    for (0..t.np()) |i| t.puf[i] = @intCast(i);
    for (0..t.nl()) |l| {
        const tw = t.twin[l];
        if (tw == NONE) continue;
        if (!eqUv(t.uv[l], t.uv[t.next[tw]]) or !eqUv(t.uv[t.next[l]], t.uv[tw])) continue;
        join(t.puf, t.lpoly[l], t.lpoly[tw]);
    }
    return number(t);
}

/// The smaller root becomes the root.
pub fn join(u: []u32, x: u32, y: u32) void {
    const a = find(u, x);
    const b = find(u, y);
    if (a < b) u[b] = a else if (b < a) u[a] = b;
}

/// The joined polygons numbered as the lowest of each comes up; a list per island.
pub fn number(t: *Topo) bool {
    const np = t.np();
    @memset(t.pisl, NONE);
    var n: u32 = 0;
    for (0..np) |p| {
        const r = find(t.puf, @intCast(p));
        if (t.pisl[r] == NONE) {
            t.pisl[r] = n;
            n += 1;
        }
        t.pisl[p] = t.pisl[r];
    }
    t.nisl = n;
    t.freeIslands();
    t.ioff = A.alloc(u32, n + 2) catch return false;
    t.ipoly = A.alloc(u32, np) catch return false;
    @memset(t.ioff, 0);
    for (0..np) |p| t.ioff[t.pisl[p] + 2] += 1;
    for (0..n) |i| t.ioff[i + 2] += t.ioff[i + 1];
    for (0..np) |p| {
        const i = t.pisl[p];
        t.ipoly[t.ioff[i + 1]] = @intCast(p);
        t.ioff[i + 1] += 1;
    }
    return true;
}

const Box = struct {
    c: f32,
    s: f32,
    lo: [2]f32 = .{ big, big },
    hi: [2]f32 = .{ -big, -big },

    fn add(b: *Box, uv: *[2]f32) void {
        const u = uv[0] * b.c - uv[1] * b.s;
        const v = uv[0] * b.s + uv[1] * b.c;
        b.lo = .{ @min(b.lo[0], u), @min(b.lo[1], v) };
        b.hi = .{ @max(b.hi[0], u), @max(b.hi[1], v) };
    }
    fn w(b: *const Box) f32 {
        return b.hi[0] - b.lo[0];
    }
    fn h(b: *const Box) f32 {
        return b.hi[1] - b.lo[1];
    }
};

fn box(t: *const Topo, i: usize, c: f32, s: f32) Box {
    var b = Box{ .c = c, .s = s };
    t.each(i, &b, Box.add);
    return b;
}

const Turn = struct {
    c: f32,
    s: f32,
    k: f32,
    fn run(x: Turn, uv: *[2]f32) void {
        const u = uv[0] * x.k;
        const v = uv[1] * x.k;
        uv.* = .{ u * x.c - v * x.s, u * x.s + v * x.c };
    }
};
const Shift = struct {
    du: f32,
    dv: f32,
    k: f32,
    fn run(x: Shift, uv: *[2]f32) void {
        uv.* = .{ (uv[0] + x.du) * x.k, (uv[1] + x.dv) * x.k };
    }
};

/// The surface it covers, and in UV.
fn areas(t: *const Topo, i: usize) [2]f32 {
    var sa: f32 = 0;
    var ua: f32 = 0;
    for (t.ipoly[t.ioff[i]..t.ioff[i + 1]]) |p| {
        sa += t.parea[p];
        var s: f32 = 0;
        for (t.me.poff[p]..t.me.poff[p + 1]) |l| {
            const a = t.uv[l];
            const b = t.uv[t.next[l]];
            s += a[0] * b[1] - b[0] * a[1];
        }
        ua += @abs(s * 0.5);
    }
    return .{ sa, ua };
}

const Sky = struct {
    x: []f32,
    y: []f32,
    w: []f32,
    x2: []f32,
    y2: []f32,
    w2: []f32,
    n: usize,
    width: f32,

    /// The lowest place (then leftmost) where a box w x h fits: the skyline rises.
    fn place(s: *Sky, w: f32, h: f32) [2]f32 {
        var by = big;
        var bx = big;
        var found = false;
        for (0..s.n) |i| {
            const x = s.x[i];
            const right = x + w;
            if (right > s.width * fit) continue;
            var y: f32 = 0;
            for (i..s.n) |j| {
                if (s.x[j] >= right) break;
                y = @max(y, s.y[j]);
            }
            if (y < by or (y == by and x < bx)) {
                by = y;
                bx = x;
                found = true;
            }
        }
        if (!found) {
            bx = 0;
            by = 0;
            for (s.y[0..s.n]) |y| by = @max(by, y);
        }
        const x1 = bx + w;
        const top = by + h;
        const old = s.n;
        @memcpy(s.x2[0..old], s.x[0..old]);
        @memcpy(s.y2[0..old], s.y[0..old]);
        @memcpy(s.w2[0..old], s.w[0..old]);
        var o: usize = 0;
        var boxed = false;
        const emit = struct {
            fn f(q: *Sky, at: *usize, x: f32, y: f32, wd: f32) void {
                q.x[at.*] = x;
                q.y[at.*] = y;
                q.w[at.*] = wd;
                at.* += 1;
            }
        }.f;
        for (0..old) |i| {
            const s0 = s.x2[i];
            const s1 = s0 + s.w2[i];
            const sy = s.y2[i];
            if (s0 < bx) {
                emit(s, &o, s0, sy, @min(s1, bx) - s0);
                if (s1 > x1) {
                    if (!boxed) emit(s, &o, bx, top, w);
                    boxed = true;
                    emit(s, &o, x1, sy, s1 - x1);
                }
            } else if (s0 >= x1) {
                if (!boxed) emit(s, &o, bx, top, w);
                boxed = true;
                emit(s, &o, s0, sy, s.w2[i]);
            } else if (s1 > x1) {
                if (!boxed) emit(s, &o, bx, top, w);
                boxed = true;
                emit(s, &o, x1, sy, s1 - x1);
            }
        }
        if (!boxed) emit(s, &o, bx, top, w);
        s.n = o;
        return .{ bx, by };
    }
};

pub fn pack(t: *Topo) bool {
    const n: usize = t.nisl;
    if (n == 0) return true;
    const floats = A.alloc(f32, n * 4 + (2 * n + 2) * 6) catch return false;
    defer A.free(floats);
    const ord = A.alloc(u32, n) catch return false;
    defer A.free(ord);
    const pw = floats[0..n];
    const ph = floats[n..][0..n];
    const px = floats[2 * n..][0..n];
    const py = floats[3 * n..][0..n];
    var sum: f32 = 0;
    for (0..n) |i| {
        const ar = areas(t, i);
        const scale = if (ar[1] > tiny) @sqrt(ar[0] / ar[1]) else 1;
        // the smallest box: turns of 2 degrees up to 90
        var best = big;
        var ang: f32 = 0;
        for (0..45) |k| {
            const a = @as(f32, @floatFromInt(k)) * step;
            const b = box(t, i, cos(a), sin(a));
            const area = b.w() * b.h();
            if (area < best) {
                best = area;
                ang = a;
            }
        }
        t.each(i, Turn{ .c = cos(ang), .s = sin(ang), .k = scale }, Turn.run);
        var b = box(t, i, 1, 0);
        if (b.h() > b.w()) { // taller than wide: a quarter turn
            t.each(i, Turn{ .c = 0, .s = 1, .k = 1 }, Turn.run);
            b = box(t, i, 1, 0);
        }
        pw[i] = b.w();
        ph[i] = b.h();
        sum += ph[i] * pw[i];
        t.each(i, Shift{ .du = -b.lo[0], .dv = -b.lo[1], .k = 1 }, Shift.run);
        ord[i] = @intCast(i);
    }
    const mg = @sqrt(sum) * margin_k;
    var s2: f32 = 0;
    var widest: f32 = 0;
    for (0..n) |i| {
        widest = @max(widest, pw[i] + mg);
        s2 += (pw[i] + mg) * (ph[i] + mg);
    }
    const width = @max(@sqrt(s2) * widen, widest);
    // tallest first (stable)
    std.sort.block(u32, ord, ph, struct {
        fn f(h: []f32, a: u32, b: u32) bool {
            return h[a] > h[b];
        }
    }.f);
    const rest = floats[4 * n..];
    const seg = 2 * n + 2;
    var sky = Sky{ .x = rest[0..seg], .y = rest[seg..][0..seg], .w = rest[2 * seg..][0..seg], .x2 = rest[3 * seg..][0..seg], .y2 = rest[4 * seg..][0..seg], .w2 = rest[5 * seg..][0..seg], .n = 1, .width = width };
    sky.x[0] = 0;
    sky.y[0] = 0;
    sky.w[0] = width;
    var used: f32 = 0;
    for (ord) |i| {
        const h = ph[i] + mg;
        const at = sky.place(pw[i] + mg, h);
        px[i] = at[0];
        py[i] = at[1];
        used = @max(used, at[1] + h);
    }
    // into the unit square
    const k = 1 / @max(@max(width, used), tiny);
    for (0..n) |i| t.each(i, Shift{ .du = px[i] + mg * 0.5, .dv = py[i] + mg * 0.5, .k = k }, Shift.run);
    return true;
}

fn sin(a: f32) f32 {
    return @floatCast(@sin(@as(f64, a)));
}
fn cos(a: f32) f32 {
    return @floatCast(@cos(@as(f64, a)));
}

/// The mesh's smart projection, packed, into uv (one per loop). False: no memory.
pub fn unwrap(me: *const scene.Mesh, uv: [][2]f32) bool {
    @memset(uv, .{ 0, 0 });
    var w = Work.init(me, uv) orelse return false;
    defer w.deinit();
    w.smart();
    return islandsByUv(&w.t) and pack(&w.t);
}

/// The topology of a mesh with its memory.
pub const Work = struct {
    t: Topo,
    ints: []u32,
    nrm: []m.V3,
    ar: []f32,

    /// Null: no memory.
    pub fn init(me: *const scene.Mesh, uv: [][2]f32) ?Work {
        const nl = me.loops.len;
        const np = me.poff.len - 1;
        const ints = A.alloc(u32, nl * 3 + np * 3) catch return null;
        const nrm = A.alloc(m.V3, np) catch {
            A.free(ints);
            return null;
        };
        const ar = A.alloc(f32, np) catch {
            A.free(ints);
            A.free(nrm);
            return null;
        };
        var w = Work{ .ints = ints, .nrm = nrm, .ar = ar, .t = .{
            .me = me,
            .uv = uv,
            .lpoly = ints[0..nl],
            .next = ints[nl..][0..nl],
            .twin = ints[2 * nl..][0..nl],
            .puf = ints[3 * nl..][0..np],
            .pisl = ints[3 * nl + np..][0..np],
            .pnrm = nrm,
            .parea = ar,
        } };
        if (!topo(&w.t)) {
            w.deinit();
            return null;
        }
        return w;
    }

    pub fn deinit(w: *Work) void {
        w.t.freeIslands();
        A.free(w.ints);
        A.free(w.nrm);
        A.free(w.ar);
    }

    pub fn smart(w: *Work) void {
        const np = w.t.np();
        smartIslands(&w.t, w.ints[3 * w.t.nl() + 2 * np..][0..np]);
    }
};

const testing = std.testing;

test "a cube: six islands, every one inside the square, none overlapping" {
    scene.init();
    defer scene.reset();
    const o = scene.add(.cube).?;
    const me = scene.meshOfObj(o).?;
    const uv = try A.alloc([2]f32, me.loops.len);
    defer A.free(uv);
    try testing.expect(unwrap(me, uv));
    var boxes: [6][4]f32 = undefined;
    for (0..6) |p| {
        var b = [4]f32{ 2, 2, -2, -2 };
        for (me.poff[p]..me.poff[p + 1]) |l| {
            b[0] = @min(b[0], uv[l][0]);
            b[1] = @min(b[1], uv[l][1]);
            b[2] = @max(b[2], uv[l][0]);
            b[3] = @max(b[3], uv[l][1]);
        }
        try testing.expect(b[0] >= 0 and b[1] >= 0 and b[2] <= 1 and b[3] <= 1);
        // squares of one size: the same density
        try testing.expectApproxEqAbs(b[2] - b[0], b[3] - b[1], 1e-5);
        boxes[p] = b;
    }
    for (0..6) |a| {
        for (a + 1..6) |b| {
            const x = boxes[a];
            const y = boxes[b];
            try testing.expect(x[2] <= y[0] or y[2] <= x[0] or x[3] <= y[1] or y[3] <= x[1]);
            try testing.expectApproxEqAbs(x[2] - x[0], y[2] - y[0], 1e-5);
        }
    }
}

test "the skyline: boxes never overlap" {
    var f: [12 * 6]f32 = undefined;
    const seg = 12;
    var s = Sky{ .x = f[0..seg], .y = f[seg..][0..seg], .w = f[2 * seg..][0..seg], .x2 = f[3 * seg..][0..seg], .y2 = f[4 * seg..][0..seg], .w2 = f[5 * seg..][0..seg], .n = 1, .width = 4 };
    s.x[0] = 0;
    s.y[0] = 0;
    s.w[0] = 4;
    const bs = [_][2]f32{ .{ 3, 2 }, .{ 1, 1 }, .{ 2, 1 }, .{ 2, 1 }, .{ 1, 3 } };
    var at: [bs.len][2]f32 = undefined;
    for (bs, 0..) |b, i| at[i] = s.place(b[0], b[1]);
    try testing.expectEqual([2]f32{ 0, 0 }, at[0]);
    try testing.expectEqual([2]f32{ 3, 0 }, at[1]); // the gap beside it
    for (0..bs.len) |a| {
        for (a + 1..bs.len) |b| {
            const apart = at[a][0] + bs[a][0] <= at[b][0] or at[b][0] + bs[b][0] <= at[a][0] or at[a][1] + bs[a][1] <= at[b][1] or at[b][1] + bs[b][1] <= at[a][1];
            try testing.expect(apart);
        }
    }
}
