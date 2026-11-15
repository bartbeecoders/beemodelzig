// The signed-distance (F-rep) kernel (sdf.s).
//
// Shapes are small graphs of nodes: primitives (sphere, box, cylinder, torus),
// lattices (gyroid, grid of struts), smooth union / subtraction / intersection
// (polynomial smooth min with radius k), shells and rigid transforms. eval
// walks the graph for one point. mesh samples the field on a grid around the
// shape's bounds (z slices on every thread) and meshes it by marching
// tetrahedra: every cube splits into six tetrahedra around its main diagonal
// (the same split everywhere, so neighbours share their faces' edges), each
// crossing a vertex on its edge, one or two triangles per tetrahedron, facing
// out. No case is ambiguous, so the mesh is manifold; the field is positive at
// the padded border, so it is closed. All in f32 step for step as the
// original (its x87 sines included), so the meshes are the same to the bit.
//
// Lengths are scene units, angles radians. Node 0 is "none". The original
// reaches these through BeeScript (ssphere, sbox, ... smesh); the port, which
// has no BeeScript yet, through console lines of the same names and arguments
// (`console`): each shape prints its number, which later lines use.
const std = @import("std");
const app = @import("app.zig");
const scene = @import("scene.zig");
const m = @import("math.zig");
const ax = @import("animexpr.zig");

const A = std.heap.page_allocator;

pub const S_SPHERE = 1;
pub const S_BOX = 2;
pub const S_CYL = 3;
pub const S_TORUS = 4;
pub const S_GYROID = 5;
pub const S_GRID = 6;
pub const S_UNION = 10;
pub const S_SUB = 11;
pub const S_ISECT = 12;
pub const S_SHELL = 13;
pub const S_XFORM = 14;
pub const S_PRISM = 15; // prof.zig's loops extruded (feature.zig's infill)

const MAXN = 4096;
const MAXPTS: u64 = 40000000; // grid points (160 MB of floats)

const BIG: f32 = 1.0e30;
const INF: f32 = 1.0e9; // "unbounded"
const LIMIT: f32 = 1.0e5;
const TWOPI: f32 = 6.2831853;
const GYRO: f32 = 0.7;
const TINY: f32 = 1.0e-20;

pub const e_unbounded = "the shape is unbounded (intersect a lattice with a solid)";
pub const e_empty = "the shape is empty";
pub const e_large = "too fine: fewer cells, please";
pub const e_nomem = "out of memory";
pub const e_full = "too many shape nodes (sclear() starts again)";

pub const Node = struct {
    t: u32 = 0,
    a: u32 = 0,
    b: u32 = 0,
    p: [6]f32 = @splat(0),
    inv: [12]f32 = @splat(0), // world -> node
    fwd: [12]f32 = @splat(0), // node -> world (bounds)
    bb: [6]f32 = @splat(0), // min[3], max[3]
    seg: []const [4]f32 = &.{}, // a prism's segments (u0 v0 u1 v1)
};

var nodes: [MAXN]Node = undefined;
pub var n: u32 = 0;
pub var err: []const u8 = "";

fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
fn cvtt(x: f32) i32 {
    return if (x >= -2147483648.0 and x < 2147483648.0) @intFromFloat(x) else std.math.minInt(i32);
}

pub fn count() u32 {
    return n;
}
pub fn clear() void {
    n = 0;
}

fn xformPoint(mt: *const [12]f32, p: [3]f32) [3]f32 {
    var r: [3]f32 = undefined;
    for (0..3) |c| r[c] = mt[c * 4] * p[0] + mt[c * 4 + 1] * p[1] + mt[c * 4 + 2] * p[2] + mt[c * 4 + 3];
    return r;
}

fn symbb(nd: *Node, h: [3]f32) void {
    nd.bb = .{ 0 - h[0], 0 - h[1], 0 - h[2], h[0], h[1], h[2] };
}

/// bounds: a box around where the shape can be negative.
fn bounds(nd: *Node) void {
    switch (nd.t) {
        S_SPHERE => symbb(nd, .{ nd.p[0], nd.p[0], nd.p[0] }),
        S_BOX => symbb(nd, .{ nd.p[0], nd.p[1], nd.p[2] }),
        S_CYL => symbb(nd, .{ nd.p[0], nd.p[1] * 0.5, nd.p[0] }),
        S_TORUS => {
            const r = nd.p[0] + nd.p[1];
            symbb(nd, .{ r, nd.p[1], r });
        },
        S_UNION => { // both, grown by k / 4
            const a = &nodes[nd.a];
            const b = &nodes[nd.b];
            for (0..3) |c| {
                const g = nd.p[0] * 0.25;
                nd.bb[c] = minss(a.bb[c], b.bb[c]) - g;
                nd.bb[c + 3] = maxss(a.bb[c + 3], b.bb[c + 3]) + g;
            }
        },
        S_SUB => nd.bb = nodes[nd.a].bb,
        S_ISECT => {
            const a = &nodes[nd.a];
            const b = &nodes[nd.b];
            for (0..3) |c| {
                nd.bb[c] = maxss(a.bb[c], b.bb[c]);
                nd.bb[c + 3] = minss(a.bb[c + 3], b.bb[c + 3]);
            }
        },
        S_SHELL => {
            const a = &nodes[nd.a];
            const g = nd.p[0] * 0.5;
            for (0..3) |c| {
                nd.bb[c] = a.bb[c] - g;
                nd.bb[c + 3] = a.bb[c + 3] + g;
            }
        },
        S_XFORM => { // the child's 8 corners, moved forwards
            const a = &nodes[nd.a];
            nd.bb = .{ BIG, BIG, BIG, 0 - BIG, 0 - BIG, 0 - BIG };
            if (a.bb[3] >= LIMIT) return symbb(nd, .{ INF, INF, INF }); // unbounded children stay so
            for (0..8) |bits| {
                var p: [3]f32 = undefined;
                for (0..3) |c| p[c] = a.bb[(bits >> @intCast(c) & 1) * 3 + c];
                const q = xformPoint(&nd.fwd, p);
                for (0..3) |c| {
                    nd.bb[c] = minss(nd.bb[c], q[c]);
                    nd.bb[c + 3] = maxss(nd.bb[c + 3], q[c]);
                }
            }
        },
        S_PRISM => {}, // (prism sets them)
        else => symbb(nd, .{ INF, INF, INF }), // lattices: everywhere
    }
}

/// sdf_new: a node (0: full, `err` says so).
pub fn new(t: u32, a: u32, b: u32, p: ?*const [6]f32, inv: ?*const [12]f32, fwd: ?*const [12]f32) u32 {
    var id = n;
    if (id == 0) id = 1; // (id 0 = none)
    if (id >= MAXN) {
        err = e_full;
        return 0;
    }
    n = id + 1;
    const nd = &nodes[id];
    nd.* = .{ .t = t, .a = a, .b = b };
    if (p) |x| nd.p = x.*;
    if (inv) |x| {
        nd.inv = x.*;
        nd.fwd = fwd.?.*;
    }
    bounds(nd);
    return id;
}

pub fn boundsOf(id: u32) [6]f32 {
    return nodes[id].bb;
}

fn twoD(x0: f32, y0: f32) f32 {
    const inner = minss(maxss(x0, y0), 0);
    const x = maxss(x0, 0);
    const y = maxss(y0, 0);
    return @sqrt(x * x + y * y) + inner;
}

/// smin: min(a, b) - h^2 k / 4, h = max(k - |a - b|, 0) / k (the plain min when k <= 0).
fn smin(a: f32, b: f32, k: f32) f32 {
    if (!(k > 0)) return minss(a, b);
    var h = maxss(k - @abs(a - b), 0) / k;
    h = h * h * k * 0.25;
    return minss(a, b) - h;
}

/// sdf_eval: the signed distance at a point.
pub fn eval(id: u32, x: f32, y: f32, z: f32) f32 {
    const nd = &nodes[id];
    switch (nd.t) {
        S_SPHERE => return @sqrt(x * x + y * y + z * z) - nd.p[0],
        S_BOX => { // q = |p| - h + rr: |max(q, 0)| + min(max q, 0) - rr
            const rr = nd.p[3];
            const qx = @abs(x) - nd.p[0] + rr;
            const qy = @abs(y) - nd.p[1] + rr;
            const qz = @abs(z) - nd.p[2] + rr;
            const inner = minss(maxss(maxss(qx, qy), qz), 0);
            const a = maxss(qx, 0);
            const b = maxss(qy, 0);
            const c = maxss(qz, 0);
            return @sqrt(a * a + b * b + c * c) + inner - rr;
        },
        S_CYL => return twoD(@sqrt(x * x + z * z) - nd.p[0], @abs(y) - nd.p[1] * 0.5),
        S_TORUS => {
            const q = @sqrt(x * x + z * z) - nd.p[0];
            return @sqrt(q * q + y * y) - nd.p[1];
        },
        S_GYROID => {
            const s = TWOPI / nd.p[0];
            const sx = ax.sincos32(x * s);
            const sy = ax.sincos32(y * s);
            const sz = ax.sincos32(z * s);
            const g = sx[0] * sy[1] + sy[0] * sz[1] + sz[0] * sx[1];
            return @abs(g) * GYRO / s - nd.p[1] * 0.5;
        },
        S_GRID => { // struts along x, y, z: u = p - cell floor(p / cell + 1/2)
            const c = nd.p[0];
            var u: [3]f32 = undefined;
            for ([3]f32{ x, y, z }, 0..) |v, k| {
                const f = @floor(v / c + 0.5) * c;
                const d = v - f;
                u[k] = d * d;
            }
            var r = minss(u[1] + u[2], u[0] + u[2]);
            r = minss(r, u[0] + u[1]);
            return @sqrt(r) - nd.p[1];
        },
        S_XFORM => {
            const q = xformPoint(&nd.inv, .{ x, y, z });
            return eval(nd.a, q[0], q[1], q[2]);
        },
        S_SHELL => return @abs(eval(nd.a, x, y, z)) - nd.p[0] * 0.5,
        S_PRISM => return prismEval(nd, x, y, z),
        S_UNION, S_SUB, S_ISECT => {
            var a = eval(nd.a, x, y, z);
            var b = eval(nd.b, x, y, z);
            const k = nd.p[0];
            if (nd.t == S_UNION) return smin(a, b, k);
            // subtract: smax(a, -b); intersect: smax(a, b) = -smin(-a, -b)
            if (nd.t == S_SUB) b = 0 - b;
            a = 0 - a;
            b = 0 - b;
            return 0 - smin(a, b, k);
        },
        else => return BIG,
    }
}

// ---- profiles as shapes (sdf_prism) --------------------------------------------------------

/// The prism's distance: the 2D distance to its segments (negative inside,
/// even-odd), then |w| beyond w0 .. w1 (sketch-local p).
fn prismEval(nd: *const Node, x: f32, y: f32, z: f32) f32 {
    const plane: u32 = @bitCast(nd.p[0]);
    var u: f32 = x;
    var v: f32 = y;
    var w: f32 = z;
    if (plane == 1) {
        v = 0 - z;
        w = y;
    } else if (plane > 1) {
        u = 0 - z;
        w = x;
    }
    w -= nd.p[1];
    var best: f32 = BIG;
    var odd = false;
    for (nd.seg) |s| {
        const ex = s[2] - s[0];
        const ey = s[3] - s[1];
        const wx = u - s[0];
        const wy = v - s[1];
        var t = wx * ex;
        t += wy * ey;
        var ee = ex * ex;
        ee += ey * ey;
        t /= maxss(ee, TINY);
        t = minss(maxss(t, 0), 1);
        var dx = wx - ex * t;
        dx *= dx;
        var dy = wy - ey * t;
        dy *= dy;
        best = minss(best, dx + dy);
        const ca = s[1] > v;
        const cb = s[3] > v;
        if (ca != cb) {
            var c = v - s[1];
            c *= s[2] - s[0];
            c /= s[3] - s[1];
            c += s[0];
            if (c > u) odd = !odd;
        }
    }
    var d = @sqrt(best);
    if (odd) d = 0 - d;
    return twoD(d, maxss(nd.p[2] - w, w - nd.p[3]));
}

/// sdf_prism: a node of these segments (the caller's, kept until the node
/// goes) extruded w0 .. w1 along the plane's normal (0 XY, 1 XZ, 2 YZ) at an
/// offset; 0 when the nodes are full.
pub fn prism(seg: []const [4]f32, plane: u32, offset: f32, w0: f32, w1: f32) u32 {
    var lo: [2]f32 = .{ BIG, BIG };
    var hi: [2]f32 = .{ 0 - BIG, 0 - BIG };
    for (seg) |s| {
        lo[0] = minss(lo[0], s[0]);
        lo[1] = minss(lo[1], s[1]);
        hi[0] = maxss(hi[0], s[0]);
        hi[1] = maxss(hi[1], s[1]);
    }
    const p = [6]f32{ @bitCast(plane), offset, w0, w1, 0, 0 };
    const id = new(S_PRISM, 0, @intCast(seg.len), &p, null, null);
    if (id == 0) return 0;
    const nd = &nodes[id];
    nd.seg = seg;
    const a = w0 + offset;
    const b = w1 + offset;
    nd.bb = if (plane == 0)
        .{ lo[0], lo[1], a, hi[0], hi[1], b }
    else if (plane == 1)
        .{ lo[0], a, 0 - hi[1], hi[0], b, 0 - lo[1] }
    else
        .{ a, lo[1], 0 - hi[0], b, hi[1], 0 - lo[0] };
    return id;
}

// ---- meshing ------------------------------------------------------------------------------

const Grid = struct {
    root: u32,
    nx: u32,
    ny: u32,
    nz: u32,
    org: [3]f32,
    h: f32,
    f: []f32,
    cell: []i32 = &.{},

    fn at(g: *const Grid, i: u32, j: u32, k: u32) usize {
        return (@as(usize, k) * g.ny + j) * g.nx + i;
    }
};

fn evalSlices(ctx: *anyopaque, begin: usize, end: usize, _: usize) void {
    const g: *Grid = @ptrCast(@alignCast(ctx));
    for (begin..end) |k| {
        for (0..g.ny) |j| {
            for (0..g.nx) |i| {
                const x = @as(f32, @floatFromInt(i)) * g.h + g.org[0];
                const y = @as(f32, @floatFromInt(j)) * g.h + g.org[1];
                const z = @as(f32, @floatFromInt(k)) * g.h + g.org[2];
                g.f[g.at(@intCast(i), @intCast(j), @intCast(k))] = eval(g.root, x, y, z);
            }
        }
    }
}

fn inside(v: f32) bool {
    return !(v >= 0);
}

const tets = [6][2]u8{ .{ 1, 3 }, .{ 1, 5 }, .{ 2, 3 }, .{ 2, 6 }, .{ 4, 5 }, .{ 4, 6 } };
const lone_tri = [4][3]u8{ .{ 1, 2, 3 }, .{ 0, 3, 2 }, .{ 3, 0, 1 }, .{ 2, 1, 0 } };

pub const Out = struct {
    verts: std.ArrayList(m.V3) = .empty,
    loops: std.ArrayList(u32) = .empty,
    pub fn deinit(o: *Out) void {
        o.verts.deinit(A);
        o.loops.deinit(A);
    }
};

/// mt_verts: a vertex on every edge (point -> point + d, d = 1..7 as x y z bits)
/// whose ends differ in sign.
fn mtVerts(g: *Grid, out: *Out) !void {
    var nv: i32 = 0;
    for (0..g.nz) |k| {
        for (0..g.ny) |j| {
            for (0..g.nx) |i| {
                const pi = g.at(@intCast(i), @intCast(j), @intCast(k));
                const f0 = g.f[pi];
                for (1..8) |d| {
                    const oi = i + (d & 1);
                    const oj = j + (d >> 1 & 1);
                    const ok = k + (d >> 2);
                    var id: i32 = -1;
                    if (oi < g.nx and oj < g.ny and ok < g.nz) {
                        const f1 = g.f[g.at(@intCast(oi), @intCast(oj), @intCast(ok))];
                        if (inside(f1) != inside(f0)) {
                            id = nv;
                            nv += 1;
                            // t = f0 / (f0 - f1), kept off the ends (no two vertices meet)
                            const t = minss(maxss(f0 / (f0 - f1), 0.001), 0.999);
                            const p = [3]usize{ i, j, k };
                            var w: m.V3 = undefined;
                            for (0..3) |c| {
                                var v: f32 = @floatFromInt(p[c]);
                                if (d >> @intCast(c) & 1 != 0) v += t;
                                w[c] = v * g.h + g.org[c];
                            }
                            try out.verts.append(A, w);
                        }
                    }
                    g.cell[pi * 7 + d - 1] = id;
                }
            }
        }
    }
}

fn tsign(cu: u8, cv: u8) i32 {
    var a: [3]i32 = undefined;
    var b: [3]i32 = undefined;
    for (0..3) |c| {
        a[c] = @intCast(cu >> @intCast(c) & 1);
        b[c] = @intCast(cv >> @intCast(c) & 1);
    }
    const det = (b[1] - b[2]) * a[0] + (b[2] - b[0]) * a[1] + (b[0] - b[1]) * a[2];
    return if (det > 0) 1 else -1;
}

/// mt_tris: the six tetrahedra (0, a, b, 7) of every cell, facing out.
fn mtTris(g: *Grid, out: *Out) !void {
    if (g.nx < 2 or g.ny < 2 or g.nz < 2) return;
    for (0..g.nz - 1) |k| {
        for (0..g.ny - 1) |j| {
            for (0..g.nx - 1) |i| {
                var mask: u32 = 0;
                for (0..8) |c| {
                    if (inside(g.f[g.at(@intCast(i + (c & 1)), @intCast(j + (c >> 1 & 1)), @intCast(k + (c >> 2)))])) mask |= @as(u32, 1) << @intCast(c);
                }
                if (mask == 0 or mask == 255) continue;
                for (tets) |tt| {
                    const code = [4]u8{ 0, tt[0], tt[1], 7 };
                    var bits: u32 = 0;
                    for (code, 0..) |c, r| {
                        if (mask >> @intCast(c) & 1 != 0) bits |= @as(u32, 1) << @intCast(r);
                    }
                    if (bits == 0 or bits == 15) continue;
                    const Ctx = struct {
                        g: *Grid,
                        code: [4]u8,
                        i: usize,
                        j: usize,
                        k: usize,
                        fn ev(s: @This(), u: usize, v: usize) u32 {
                            const lo = @min(s.code[u], s.code[v]);
                            const dir = @max(s.code[u], s.code[v]) ^ lo;
                            const pi = s.g.at(@intCast(s.i + (lo & 1)), @intCast(s.j + (lo >> 1 & 1)), @intCast(s.k + (lo >> 2)));
                            return @bitCast(s.g.cell[pi * 7 + dir - 1]);
                        }
                    };
                    const cx = Ctx{ .g = g, .code = code, .i = i, .j = j, .k = k };
                    const sign = tsign(code[1], code[2]);
                    if (@popCount(bits) == 2) {
                        // the quad between i1 i2 (inside) and o1 o2: (i1o1, i1o2,
                        // i2o2, i2o1) faces out when (i1 i2 o1 o2) is positive
                        var ins: [2]usize = undefined;
                        var outs: [2]usize = undefined;
                        var ni: usize = 0;
                        var no: usize = 0;
                        for (0..4) |r| {
                            if (bits >> @intCast(r) & 1 != 0) {
                                ins[ni] = r;
                                ni += 1;
                            } else {
                                outs[no] = r;
                                no += 1;
                            }
                        }
                        const perm = [4]usize{ ins[0], ins[1], outs[0], outs[1] };
                        var par: u32 = 0;
                        for (0..3) |x| {
                            for (x + 1..4) |y| {
                                if (perm[x] > perm[y]) par ^= 1;
                            }
                        }
                        if (sign < 0) par ^= 1;
                        const q = [4]u32{ cx.ev(ins[0], outs[0]), cx.ev(ins[0], outs[1]), cx.ev(ins[1], outs[1]), cx.ev(ins[1], outs[0]) };
                        try tri(out, par != 0, .{ q[0], q[1], q[2] });
                        try tri(out, par != 0, .{ q[0], q[2], q[3] });
                    } else {
                        // the triangle around the lone corner
                        var flip = false;
                        var lb = bits;
                        if (@popCount(bits) != 1) {
                            lb = ~bits & 15;
                            flip = true;
                        }
                        const lone: usize = @ctz(lb);
                        if (sign < 0) flip = !flip;
                        const lt = lone_tri[lone];
                        try tri(out, flip, .{ cx.ev(lone, lt[0]), cx.ev(lone, lt[1]), cx.ev(lone, lt[2]) });
                    }
                }
            }
        }
    }
}

fn tri(out: *Out, rev: bool, v: [3]u32) !void {
    try out.loops.appendSlice(A, if (rev) &[3]u32{ v[0], v[2], v[1] } else &v);
}

/// sdf_mesh: a closed mesh of the shape (world coordinates); null with `err` set.
pub fn mesh(root: u32, cells0: i32) ?Out {
    const cells = @max(cells0, 4);
    const bb = nodes[root].bb;
    var side: f32 = 0;
    for (0..3) |c| {
        if (@abs(bb[c]) >= LIMIT or @abs(bb[c + 3]) >= LIMIT) {
            err = e_unbounded;
            return null;
        }
        const s = bb[c + 3] - bb[c];
        if (!(s > 0)) {
            err = e_empty;
            return null;
        }
        side = maxss(side, s);
    }
    const h = side / @as(f32, @floatFromInt(cells));
    var g = Grid{ .root = root, .nx = 0, .ny = 0, .nz = 0, .org = undefined, .h = h, .f = &.{} };
    var nn: [3]u32 = undefined;
    for (0..3) |c| {
        g.org[c] = bb[c] - (h + h);
        const v = cvtt((bb[c + 3] - bb[c]) / h) +% 5;
        if (v < 2) {
            err = e_large;
            return null;
        }
        nn[c] = @intCast(v);
    }
    g.nx = nn[0];
    g.ny = nn[1];
    g.nz = nn[2];
    const pts = @as(u64, g.nx) * g.ny * g.nz;
    if (pts > MAXPTS) {
        err = e_large;
        return null;
    }
    g.f = A.alloc(f32, pts) catch {
        err = e_nomem;
        return null;
    };
    defer A.free(g.f);
    @import("jobs.zig").parallelFor(g.nz, 1, &g, evalSlices);
    g.cell = A.alloc(i32, pts * 7) catch {
        err = e_nomem;
        return null;
    };
    defer A.free(g.cell);
    var out = Out{};
    mtVerts(&g, &out) catch {
        out.deinit();
        err = e_nomem;
        return null;
    };
    mtTris(&g, &out) catch {
        out.deinit();
        err = e_nomem;
        return null;
    };
    if (out.loops.items.len == 0) {
        out.deinit();
        err = e_empty;
        return null;
    }
    return out;
}

/// sdf_fmesh: the surface of a field the caller has (origin, spacing; (k ny +
/// j) nx + i; negative inside): a closed mesh, or null.
pub fn fmesh(org: [3]f32, h: f32, f: []f32, nx: u32, ny: u32, nz: u32) ?Out {
    var g = Grid{ .root = 0, .nx = nx, .ny = ny, .nz = nz, .org = org, .h = h, .f = f };
    const pts = @as(u64, nx) * ny * nz;
    if (pts == 0 or pts > f.len) return null;
    g.cell = A.alloc(i32, pts * 7) catch return null;
    defer A.free(g.cell);
    var out = Out{};
    mtVerts(&g, &out) catch {
        out.deinit();
        return null;
    };
    mtTris(&g, &out) catch {
        out.deinit();
        return null;
    };
    if (out.loops.items.len == 0) {
        out.deinit();
        return null;
    }
    return out;
}

// ---- the matrices of smove / srot ------------------------------------------------------------

/// obj_matrix of a stand-in object (location, rotation in radians, scale 1).
fn standIn(loc: [3]f32, rot: [3]f32) [12]f32 {
    const x = ax.sincos32(rot[0]);
    const y = ax.sincos32(rot[1]);
    const z = ax.sincos32(rot[2]);
    const sx = x[0];
    const cx = x[1];
    const sy = y[0];
    const cy = y[1];
    const sz = z[0];
    const cz = z[1];
    var r: [12]f32 = .{
        cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx, loc[0],
        sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx, loc[1],
        0 - sy,  cy * sx,                cy * cx,                loc[2],
    };
    for (0..3) |row| {
        for (0..3) |c| r[row * 4 + c] = 1.0 * r[row * 4 + c];
    }
    return r;
}

/// The node of a moved or turned shape: forwards and its inverse (R^T, -R^T t).
pub fn moved(a: u32, v: [3]f32, rotate: bool) u32 {
    const fwd = if (rotate) standIn(.{ 0, 0, 0 }, v) else standIn(v, .{ 0, 0, 0 });
    var inv: [12]f32 = undefined;
    for (0..3) |c| {
        for (0..3) |d| inv[c * 4 + d] = fwd[d * 4 + c];
    }
    for (0..3) |c| {
        const s = inv[c * 4] * fwd[3] + inv[c * 4 + 1] * fwd[7] + inv[c * 4 + 2] * fwd[11];
        inv[c * 4 + 3] = 0 - s;
    }
    const zero: [6]f32 = @splat(0);
    return new(S_XFORM, a, 0, &zero, &inv, &fwd);
}

// ---- the console: the original's BeeScript functions as lines ---------------------------------

fn argVals(args: []const []const u8, out: []f32) bool {
    for (args, 0..) |t, k| {
        const v = @import("cad.zig").eval(t) orelse {
            app.log("  error: shape: {s}: {s}", .{ t, ax.err orelse "not a number" });
            return false;
        };
        out[k] = @floatCast(v);
    }
    return true;
}

fn idOf(t: []const u8) ?u32 {
    const v = std.fmt.parseInt(u32, t, 10) catch 0;
    if (v == 0 or v >= n) {
        app.log("  error: no such shape", .{});
        return null;
    }
    return v;
}

fn made(id: u32) void {
    if (id == 0) return app.log("  error: shape: {s}", .{err});
    app.log("  shape {d}", .{id});
}

/// A console line naming a shape function: ssphere r | sbox x y z [round] (full
/// sizes) | scyl r height | storus R r | sgyroid cell wall | sgrid cell diameter |
/// sunion / ssub / sisect a b [k] | sshell a t | smove a x y z | srot a rx ry rz |
/// sdist a x y z | smesh name a [cells, default 64] | sclear. False: not one.
pub fn console(verb: []const u8, arg: []const u8) bool {
    const names = [_][]const u8{ "ssphere", "sbox", "scyl", "storus", "sgyroid", "sgrid", "sunion", "ssub", "sisect", "sshell", "smove", "srot", "sdist", "smesh", "sclear" };
    var which: ?usize = null;
    for (names, 0..) |nm, k| {
        if (std.mem.eql(u8, verb, nm)) which = k;
    }
    const w = which orelse return false;
    var toks: [8][]const u8 = undefined;
    var nt: usize = 0;
    var it = std.mem.tokenizeAny(u8, arg, " ,");
    while (it.next()) |t| {
        if (nt == toks.len) break;
        toks[nt] = t;
        nt += 1;
    }
    var p: [6]f32 = @splat(0);
    switch (w) {
        0...5 => {
            const want: usize = switch (w) {
                0 => 1,
                1 => if (nt >= 4) 4 else 3,
                else => 2,
            };
            if (nt < want) {
                app.log("  error: {s}: {d} values", .{ verb, want });
                return true;
            }
            if (!argVals(toks[0..want], p[0..want])) return true;
            const t: u32 = switch (w) {
                0 => S_SPHERE,
                1 => S_BOX,
                2 => S_CYL,
                3 => S_TORUS,
                4 => S_GYROID,
                else => S_GRID,
            };
            if (t == S_BOX) {
                for (0..3) |c| p[c] = p[c] * 0.5;
            }
            if (t == S_GRID) p[1] = p[1] * 0.5; // a diameter -> radius
            made(new(t, 0, 0, &p, null, null));
        },
        6, 7, 8 => {
            if (nt < 2) {
                app.log("  error: {s} a b [k]", .{verb});
                return true;
            }
            const a = idOf(toks[0]) orelse return true;
            const b = idOf(toks[1]) orelse return true;
            if (nt >= 3 and !argVals(toks[2..3], p[0..1])) return true;
            made(new(@intCast(S_UNION + (w - 6)), a, b, &p, null, null));
        },
        9 => {
            if (nt < 2) {
                app.log("  error: sshell a thickness", .{});
                return true;
            }
            const a = idOf(toks[0]) orelse return true;
            if (!argVals(toks[1..2], p[0..1])) return true;
            made(new(S_SHELL, a, 0, &p, null, null));
        },
        10, 11, 12 => {
            if (nt < 4) {
                app.log("  error: {s} a x y z", .{verb});
                return true;
            }
            const a = idOf(toks[0]) orelse return true;
            if (!argVals(toks[1..4], p[0..3])) return true;
            if (w == 12) {
                const d = eval(a, p[0], p[1], p[2]);
                app.log("  sdist {e}", .{d});
                return true;
            }
            made(moved(a, .{ p[0], p[1], p[2] }, w == 11));
        },
        13 => {
            if (nt < 2) {
                app.log("  error: smesh name a [cells]", .{});
                return true;
            }
            const a = idOf(toks[1]) orelse return true;
            var cells: i32 = 64;
            if (nt >= 3) {
                cells = std.fmt.parseInt(i32, toks[2], 10) catch 64;
                if (cells > 512) cells = 512;
            }
            var out = mesh(a, cells) orelse {
                app.log("  error: shape: {s}", .{err});
                return true;
            };
            defer out.deinit();
            addObject(toks[0], &out) catch return true;
        },
        else => {
            clear();
            app.log("  shapes cleared", .{});
        },
    }
    return true;
}

fn addObject(name: []const u8, out: *Out) !void {
    const nq = out.loops.items.len / 3;
    const poff = try A.alloc(u32, nq + 1);
    defer A.free(poff);
    for (poff, 0..) |*q, k| q.* = @intCast(k * 3);
    const mi = scene.addMesh(out.verts.items, poff, out.loops.items) orelse return error.OutOfMemory;
    if (scene.count >= scene.max_objects) return error.OutOfMemory;
    var o = scene.Object{ .kind = .mesh, .mesh = mi, .color = 0xb4b8c0 };
    o.setName(if (name.len > 0) name else "Shape");
    var buf: [40]u8 = undefined;
    var k: u32 = 1;
    while (scene.find(o.name()) != null) : (k += 1) {
        const nm = std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ name[0..@min(name.len, 27)], k }) catch break;
        o.setName(nm);
    }
    scene.objects[scene.count] = o;
    scene.stamp(scene.count);
    scene.count += 1;
    @import("undo.zig").label("Shape");
    app.log("  mesh {s}: {d} vertices, {d} triangles", .{ o.name(), out.verts.items.len, nq });
}

test "a sphere's field and mesh" {
    const T = std.testing;
    clear();
    const s = new(S_SPHERE, 0, 0, &.{ 1, 0, 0, 0, 0, 0 }, null, null);
    try T.expectEqual(@as(u32, 1), s);
    try T.expectApproxEqAbs(@as(f32, -1), eval(s, 0, 0, 0), 1e-6);
    try T.expectApproxEqAbs(@as(f32, 1), eval(s, 2, 0, 0), 1e-6);
    var out = mesh(s, 8).?;
    defer out.deinit();
    try T.expect(out.verts.items.len > 50 and out.loops.items.len % 3 == 0);
    // closed: every directed edge once, its twin once
    var map: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer map.deinit(A);
    const l = out.loops.items;
    var t: usize = 0;
    while (t < l.len) : (t += 3) {
        for (0..3) |c| {
            const key = @as(u64, l[t + c]) << 32 | l[t + (c + 1) % 3];
            const g = try map.getOrPut(A, key);
            if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
        }
    }
    var it = map.iterator();
    while (it.next()) |e| {
        try T.expectEqual(@as(u32, 1), e.value_ptr.*);
        try T.expect(map.contains(e.key_ptr.* >> 32 | e.key_ptr.* << 32));
    }
}
