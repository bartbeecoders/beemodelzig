// Bodies that attract each other (nbody.s): N-body gravity.
//
// A rigid body marked Attracts (rigid.add attracts) pulls every other moving
// body by its mass: a = G m d / (|d|^2 + eps^2)^1.5, with G the world's
// (rigid.world g n; 1 by default). Once a step (rbody.zig's step, after the
// fields) the attracting bodies go into an octree of masses (Barnes-Hut: a
// cell far enough away - its size under half its distance - pulls as one
// mass at its centre), and each moving body's pull is summed from it across
// the workers into its `nba`; body_force adds it each substep.
//
// The original's operation order throughout (the walk's stack order too), so
// the pulls match it to the bit.
const std = @import("std");
const rc = @import("rbcore.zig");
const jobs = @import("jobs.zig");

const V4 = rc.V4;
const splat = rc.splat;
const andXyz = rc.andXyz;

/// A cell of the tree (NC_*).
const Cell = struct {
    com: V4 align(16), // centre of mass (x y z), mass (w)
    cen: V4, // the cube's centre (x y z), half size (w)
    kid: [8]i32, // children (-1: none)
    body: i32, // a leaf: its body (-1: inner, -2: a heap)
};

const MAXDEPTH = 32;
const STACK = 512;
const PAD: f32 = 1.001;
const MINH: f32 = 0.01;
const EPS2: f32 = 0.01; // softening (0.1 m)
const THETA2: f32 = 0.25; // (size / distance)^2 under this: one mass

var cells: []Cell = &.{}; // nb_cells, nb_cap
/// A pull this step (nb_on).
pub var on: bool = false;
var nc: u32 = 0; // cells in use
var na: u32 = 0; // bodies that attract
var gG: f32 = 0; // G
var ms: u32 = 0; // the last step's time (ms x 1000)

/// nb_new_cell: a new empty cell, or -1 when there is no room.
fn newCell(cen: V4) i32 {
    if (nc >= cells.len) return -1;
    const k = nc;
    nc += 1;
    cells[k] = .{ .com = @splat(0), .cen = cen, .kid = @splat(-1), .body = -1 };
    return @intCast(k);
}

/// nb_child_box: the child's centre and half size: bit k of the octant set, + h/2 along axis k.
fn childBox(c: *const Cell, oct: u32) V4 {
    var o: [4]f32 = c.cen;
    const hh = o[3] * 0.5;
    o[3] = hh;
    for (0..3) |k| {
        const s = if (oct & (@as(u32, 1) << @intCast(k)) != 0) hh else -hh;
        o[k] = s + o[k];
    }
    return o;
}

/// nb_octant: cmpnltps (x y z >= the centre's, or unordered).
fn octant(p: V4, c: *const Cell) u32 {
    var m: u32 = 0;
    inline for (0..3) |k| {
        if (!(p[k] < c.cen[k])) m |= 1 << k;
    }
    return m;
}

/// nb_add: a point and its mass into a cell's centre of mass.
fn add(c: *Cell, p: V4, m: f32) void {
    const mm = splat(c.com[3]);
    const ms_ = splat(m);
    const tot = mm + ms_;
    var x = c.com * mm;
    x += p * ms_;
    x = x / tot;
    c.com = rc.setW(andXyz(x), tot[0]);
}

/// nb_insert: a body into the tree.
fn insert(bi: u32) void {
    const b = &rc.bd[bi];
    const p = andXyz(b.pos);
    const m = b.am;
    var cell: u32 = 0;
    var depth: u32 = 0;
    while (true) {
        var c = &cells[cell];
        const body = c.body;
        if (!(c.com[3] > 0) and body == -1 and c.kid[0] == -1) { // empty: the body goes here
            c.body = @intCast(bi);
            add(c, p, m);
            return;
        }
        if (body != -1) {
            if (depth >= MAXDEPTH or body == -2) {
                c.body = -2; // a heap
                add(c, p, m);
                return;
            }
            // a leaf: the body there goes a level down
            c.body = -1;
            const q = andXyz(rc.bd[@intCast(body)].pos);
            const oc = octant(q, c);
            const k = newCell(childBox(c, oc));
            c = &cells[cell];
            if (k < 0) { // no room to split: a heap
                c.body = -2;
                add(c, p, m);
                return;
            }
            c.kid[oc] = k;
            const ch = &cells[@intCast(k)];
            ch.body = body;
            ch.com = c.com; // (it held just that body)
        }
        // inner: count it, go down
        add(c, p, m);
        const oc = octant(p, c);
        const kid = c.kid[oc];
        if (kid < 0) { // a new leaf for it
            const k = newCell(childBox(c, oc));
            if (k < 0) return; // (no room: counted above)
            cells[cell].kid[oc] = k;
            const ch = &cells[@intCast(k)];
            ch.body = @intCast(bi);
            ch.com = rc.setW(andXyz(p), m);
            return;
        }
        cell = @intCast(kid);
        depth += 1;
    }
}

/// nb_job: each moving body's pull from the tree, bodies [lo, hi).
fn job(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const G = splat(gG);
    var stack: [STACK]u32 = undefined;
    var i = lo;
    while (i < hi) : (i += 1) {
        const b = &rc.bd[i];
        var sum: V4 = @splat(0);
        if (b.typ == 1) {
            const p = andXyz(b.pos);
            stack[0] = 0;
            var n: u32 = 1;
            while (n > 0) {
                n -= 1;
                const c = &cells[stack[n]];
                const mass = c.com[3];
                if (!(mass > 0)) continue;
                const d = andXyz(c.com) - p;
                var d2 = rc.dot3(d, d);
                if (c.body == -1) { // inner: far enough? (2h)^2 < t2 d2
                    var s = c.cen[3];
                    s += s;
                    s *= s;
                    if (s >= d2 * THETA2) { // no: its children
                        for (c.kid) |k| {
                            if (k < 0) continue;
                            if (n >= STACK) continue;
                            stack[n] = @intCast(k);
                            n += 1;
                        }
                        continue;
                    }
                } else if (c.body == @as(i32, @intCast(i))) continue; // (not itself)
                // G M d / (d2 + e2)^1.5
                d2 += EPS2;
                const r = @sqrt(d2);
                d2 *= r;
                const k = mass / d2;
                sum += d * splat(k);
            }
        }
        b.nba = andXyz(sum * G);
    }
}

/// nb_step: the attracting bodies' tree, every moving body's pull (nba);
/// `on` false when no body attracts. G: the world's (halved on the first step).
pub fn step(G: f32) void {
    gG = G;
    const t0 = rc.nowNs();
    defer ms = @intCast((rc.nowNs() - t0) / 1000);
    on = false;
    var lo = rc.big4;
    var hi = rc.nbig4;
    var n: u32 = 0;
    for (rc.bd[0..rc.nb]) |*b| {
        if (b.typ == 3) continue; // (dormant pieces: not yet)
        if (!(b.am > 0)) continue;
        n += 1;
        const p = andXyz(b.pos);
        lo = rc.minps(lo, p);
        hi = rc.maxps(hi, p);
    }
    na = n;
    if (n == 0) return;
    // the root: a cube round them
    const cen = andXyz((lo + hi) * rc.half4);
    const half = (hi - lo) * rc.half4;
    var hm = rc.maxss(half[0], half[1]);
    hm = rc.maxss(hm, half[2]);
    hm *= PAD;
    hm = rc.maxss(hm, MINH);
    const want: usize = @as(usize, n) * 8 + 64; // room: 8 cells a body
    if (want > cells.len) {
        const A = std.heap.page_allocator;
        if (cells.len > 0) A.free(cells);
        cells = A.alloc(Cell, want) catch {
            cells = &.{};
            return;
        };
    }
    nc = 0;
    _ = newCell(rc.setW(cen, hm));
    for (rc.bd[0..rc.nb], 0..) |*b, i| {
        if (b.typ == 3) continue;
        if (!(b.am > 0)) continue;
        insert(@intCast(i));
    }
    var dummy: u8 = 0;
    jobs.parallelFor(rc.nb, 64, &dummy, job);
    on = true;
}

/// nb_info: 0 bodies that attract, 1 cells, 2 the last step's tree and pulls (ms).
pub fn info(what: u32) f32 {
    if (what == 0) return @floatFromInt(na);
    if (what == 1) return @floatFromInt(nc);
    const x: f32 = @floatFromInt(ms);
    return x / 1000.0;
}

test "two bodies pull each other; the far cell as one mass" {
    var bodies: [4]rc.Body = @splat(.{});
    bodies[0] = .{ .pos = .{ 0, 0, 0, 0 }, .typ = 1, .am = 2 };
    bodies[1] = .{ .pos = .{ 3, 0, 0, 0 }, .typ = 1, .am = 1 };
    bodies[2] = .{ .pos = .{ 0, 4, 0, 0 }, .typ = 1 }; // pulled, not pulling
    bodies[3] = .{ .typ = 2 }; // the world
    rc.bd = &bodies;
    rc.nb = 4;
    step(1.0);
    try std.testing.expect(on);
    try std.testing.expectEqual(@as(f32, 2), info(0));
    // body 1 pulled by body 0: 2 * 3 / (9.01)^1.5 toward -x
    const want: f32 = -(2.0 * 3.0) / (9.01 * @sqrt(@as(f32, 9.01)));
    try std.testing.expectApproxEqRel(want, bodies[1].nba[0], 1e-6);
    try std.testing.expectEqual(@as(f32, 0), bodies[1].nba[1]);
    // body 0 by body 1
    try std.testing.expect(bodies[0].nba[0] > 0);
    // body 2 by both
    try std.testing.expect(bodies[2].nba[1] < 0 and bodies[2].nba[0] > 0);
    try std.testing.expectEqual(@as(f32, 0), bodies[3].nba[0]);
    rc.bd = &.{};
    rc.nb = 0;
}
