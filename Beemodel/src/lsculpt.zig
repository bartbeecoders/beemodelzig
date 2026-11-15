//! Sculpting and painting landscapes (lsculpt.s).
//!
//! Sculpt mode on a landscape (sculpt.zig hands it here: sculpt.land) works on
//! the heightfield itself, at its full resolution, through the topmost Sculpted
//! layer (one is added when there is none): each dab changes that layer's
//! offsets and, so the stroke shows at once, the heights and the display
//! mesh's vertices under it; when the stroke ends the stack is evaluated again
//! from that layer. A stroke works on its own copy of the block and the mesh,
//! so it is one undo step.
//!
//! Brushes: raise, lower, smooth (towards the neighbours), flatten (to the
//! height where the stroke began), ramp (from where the stroke began to where
//! it ends: a straight slope a brush wide), noise, erode (droplet erosion in a
//! window around the dab).
//!
//! Paint: up to 8 paint layers, each a material (rock, grass, sand, snow, dirt,
//! gravel, moss, mud) with a colour, friction and bounce, and a rule (the
//! heights and slopes it covers) for auto paint. The splat map keeps 8 weights
//! a sample (0..255, together at most 255; the rest is unpainted). A paint dab
//! adds the layer's weight and lowers the others. The display mesh's vertex
//! colours show the blend.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const la = @import("landscape.zig");
const procgen = @import("procgen.zig");
const shgraph = @import("shgraph.zig");

const Block = la.Block;
const Impl = ops.Impl;
const cvtt = procgen.cvtt;
const cvt = procgen.cvt;
const minss = procgen.minss;
const maxss = procgen.maxss;
const TINY: f32 = 1.0e-6;

pub const T_RAISE = 0;
pub const T_LOWER = 1;
pub const T_SMOOTH = 2;
pub const T_FLAT = 3;
pub const T_RAMP = 4;
pub const T_NOISE = 5;
pub const T_ERODE = 6;
/// + the material
pub const T_PAINT = 8;

pub const tool_names = [_][]const u8{ "raise", "lower", "smooth", "flatten", "ramp", "noise", "erode" };
pub const mat_names = [_][]const u8{ "rock", "grass", "sand", "snow", "dirt", "gravel", "moss", "mud" };

/// The materials: a paint layer's defaults (ls_mats).
pub const mats = [8]la.Paint{
    .{ .mat = 0, .col = 0x7a736b, .fric = 0.7, .bounce = 0.1, .hlo = 0, .hhi = 0, .slo = 30, .shi = 90 },
    .{ .mat = 1, .col = 0x5b7f32, .fric = 0.6, .bounce = 0.05, .hlo = 0, .hhi = 0, .slo = 0, .shi = 30 },
    .{ .mat = 2, .col = 0xd8c08a, .fric = 0.5, .bounce = 0.0, .hlo = 0, .hhi = 0.15, .slo = 0, .shi = 20 },
    .{ .mat = 3, .col = 0xf2f4f7, .fric = 0.15, .bounce = 0.0, .hlo = 0.8, .hhi = 1.0, .slo = 0, .shi = 0 },
    .{ .mat = 4, .col = 0x6e5137, .fric = 0.6, .bounce = 0.0, .hlo = 0, .hhi = 0, .slo = 15, .shi = 35 },
    .{ .mat = 5, .col = 0x8d8a83, .fric = 0.7, .bounce = 0.1, .hlo = 0, .hhi = 0, .slo = 0, .shi = 0 },
    .{ .mat = 6, .col = 0x4a5f2a, .fric = 0.6, .bounce = 0.0, .hlo = 0, .hhi = 0, .slo = 0, .shi = 0 },
    .{ .mat = 7, .col = 0x4a3b2b, .fric = 0.8, .bounce = 0.0, .hlo = 0, .hhi = 0.1, .slo = 0, .shi = 0 },
};

/// The active tool (ls_tool).
pub var tool: u32 = T_RAISE;
/// A stroke is on (ls_on).
pub var stroking: bool = false;

// the stroke's state
var s_paint: u32 = 0; // painting: the layer
var s_obj: usize = 0;
var s_blk: *Block = undefined;
var s_sl: u32 = 0; // the Sculpted layer
var s_d: u32 = 0; // the display mesh: samples a side,
var s_step: u32 = 0; //  every step-th sample
/// The stroke's start and last dab (x, z in its space, height).
pub var s_a: [3]f32 = .{ 0, 0, 0 };
pub var s_b: [3]f32 = .{ 0, 0, 0 };
pub var s_r: f32 = 0; // radius (its space)
pub var s_s: f32 = 0; // strength
var rng: u32 = 0; // (ls_rng: each erode dab its own seed)

/// ls_tool_name: the active tool's name.
pub fn toolName() []const u8 {
    if (tool < T_PAINT) return tool_names[tool];
    return mat_names[(tool - T_PAINT) & 7];
}

fn display(i: usize) ?*scene.Mesh {
    const mi = scene.objects[i].mesh orelse return null;
    return if (scene.meshes[mi]) |*me| me else null;
}

/// ls_add_paint: a paint layer of material k; its index.
pub fn addPaint(k: u32, b: *Block) u32 {
    const i = b.np;
    b.paint[i] = mats[k & 7];
    b.np += 1;
    return i;
}

/// ls_begin: the stroke's own block (a Sculpted layer, or the paint layer,
/// made when missing) and display mesh, on object i. False: none (8 layers).
pub fn begin(i: usize, t: u32) bool {
    s_obj = i;
    const src = la.ofIndex(i) orelse return false;
    var want: u32 = 0;
    var newl: u32 = 0; // 1 sculpted, 2 paint
    var mat: u32 = 0;
    if (t < T_PAINT) {
        var k: i32 = @as(i32, @intCast(src.nl)) - 1;
        while (k >= 0) : (k -= 1) {
            // (one without its array - a damaged file's - is not one: the original
            // wrote into the block's header through it)
            if (src.lay[@intCast(k)].typ == 4 and src.lay[@intCast(k)].data != 0) break;
        }
        if (k >= 0) {
            s_sl = @intCast(k);
        } else {
            if (src.nl >= la.LA_MAXL) return false;
            want = la.WANT_EXTRA;
            newl = 1;
            s_sl = src.nl;
        }
    } else {
        mat = t - T_PAINT;
        if (src.splat == 0) want |= la.WANT_SPLAT;
        var k: u32 = 0;
        while (k < src.np) : (k += 1) {
            if (src.paint[k].mat == mat) break;
        }
        if (k == src.np) {
            if (src.np >= la.LA_MAXP) return false;
            newl = 2;
        }
        s_paint = k;
    }
    const b = la.make(src, src.n, want) orelse return false;
    if (newl == 1) {
        const l = &b.lay[b.nl];
        l.typ = 4;
        l.flg = 0;
        l.str = 1.0;
        l.data = la.extra;
        b.nl += 1;
    }
    if (newl == 2) _ = addPaint(mat, b);
    la.objSet(i, b);
    s_blk = b;
    la.unref(b); // (the mesh holds it)
    const me = display(i) orelse return false;
    s_d = @intCast(cvt(@sqrt(@as(f32, @floatFromInt(me.verts.len)))));
    s_step = if (s_d > 1) (b.n - 1) / (s_d - 1) else 0;
    if (b.splat != 0) _ = la.vcolAlloc(me);
    return true;
}

/// ls_end: the stroke done: the stack again from the Sculpted layer (a height
/// brush), a new display.
pub fn end() void {
    if (tool < T_PAINT) {
        la.eval(s_blk, s_sl);
        la.objSet(s_obj, s_blk);
    }
    app.dirty = true;
}

const Region = struct { i0: i32, i1: i32, j0: i32, j1: i32, cell: f32, half: f32 };

/// ls_region: the samples (x, z) +- reach covers (inclusive; i0 > i1: none).
fn region(x0: f32, z0: f32, reach: f32) Region {
    const b = s_blk;
    const nm1: i32 = @intCast(b.n - 1);
    const cell = b.size / @as(f32, @floatFromInt(nm1));
    const half = b.size * 0.5;
    const x = x0 + half;
    const z = z0 + half;
    var r = Region{
        .i0 = cvtt(@floor((x - reach) / cell)),
        .i1 = cvtt(@ceil((x + reach) / cell)),
        .j0 = cvtt(@floor((z - reach) / cell)),
        .j1 = cvtt(@ceil((z + reach) / cell)),
        .cell = cell,
        .half = half,
    };
    if (r.i0 < 0) r.i0 = 0;
    if (r.j0 < 0) r.j0 = 0;
    if (r.i1 > nm1) r.i1 = nm1;
    if (r.j1 > nm1) r.j1 = nm1;
    return r;
}

/// ls_dab: the tool at (x, z) (its space), radius r, strength s.
pub fn dab(x: f32, z: f32, r: f32, s: f32) void {
    if (tool == T_ERODE) {
        erodeLocal(x, z, r, s);
    } else {
        const g = region(x, z, r);
        const b = s_blk;
        const n = b.n;
        const h = la.heights(b);
        var off: []f32 = &.{};
        var inv: f32 = 0;
        if (tool < T_PAINT) {
            const l = &b.lay[s_sl];
            off = la.arrF(b, l.data);
            inv = 1.0 / maxss(l.str, TINY);
        }
        const sp = la.splat(b);
        var j = g.j0;
        while (j <= g.j1) : (j += 1) {
            var i = g.i0;
            while (i <= g.i1) : (i += 1) {
                var dx = @as(f32, @floatFromInt(i)) * g.cell - g.half - x;
                var dz = @as(f32, @floatFromInt(j)) * g.cell - g.half - z;
                dx = dx * dx;
                dz = dz * dz;
                const q = (dx + dz) / (r * r);
                var w = 1.0 - q;
                if (!(w > 0)) continue;
                w = w * w * s;
                const k: usize = @intCast(j * @as(i32, @intCast(n)) + i);
                if (tool >= T_PAINT) {
                    splatAdd(&sp[k], s_paint, w);
                    continue;
                }
                const hv = h[k];
                const d: f32 = switch (tool) {
                    T_RAISE => r * 0.1 * w,
                    T_LOWER => 0 - r * 0.1 * w,
                    T_SMOOTH => blk: {
                        const ui: usize = @intCast(i);
                        const uj: usize = @intCast(j);
                        const row = uj * n;
                        var sum = h[row + (if (ui == 0) 0 else ui - 1)];
                        sum = sum + h[row + (if (ui + 1 < n) ui + 1 else ui)];
                        sum = sum + h[(if (uj == 0) 0 else uj - 1) * n + ui];
                        sum = sum + h[(if (uj + 1 < n) uj + 1 else uj) * n + ui];
                        break :blk (sum * 0.25 - hv) * w;
                    },
                    T_FLAT => (s_a[2] - hv) * w * 0.5,
                    T_NOISE => blk: {
                        const p = m.V3{
                            @as(f32, @floatFromInt(i)) * g.cell / r * 2.0,
                            0.37,
                            @as(f32, @floatFromInt(j)) * g.cell / r * 2.0,
                        };
                        break :blk shgraph.perlin(p) * w * r * 0.05;
                    },
                    else => continue,
                };
                h[k] = h[k] + d;
                off[k] = d * inv + off[k];
            }
        }
    }
    const g2 = region(x, z, r * 2.0); // (erode reaches a little further)
    show(g2);
}

/// ls_splat: the layer gains w x 128, the others give way so they stay at
/// most 255 together.
pub fn splatAdd(w8: *[8]u8, layer: u32, w: f32) void {
    var a: i64 = cvt(w * 128.0);
    a += w8[layer];
    if (a < 0 or a > 255) a = 255; // (unsigned: jbe)
    w8[layer] = @intCast(a);
    const room: u32 = 255 - @as(u32, @intCast(a));
    var theirs: u32 = 0;
    for (0..8) |c| {
        if (c != layer) theirs += w8[c];
    }
    if (theirs <= room) return;
    for (0..8) |c| {
        if (c != layer) w8[c] = @truncate(@as(u32, w8[c]) * room / theirs);
    }
}

/// ls_erode_local: droplets in a square window around the dab, mixed back by
/// the falloff.
fn erodeLocal(x: f32, z: f32, r: f32, s: f32) void {
    const b = s_blk;
    const n: i32 = @intCast(b.n);
    const cell = b.size / @as(f32, @floatFromInt(n - 1));
    const half = b.size * 0.5;
    const ci = cvt((x + half) / cell);
    const cj = cvt((z + half) / cell);
    const rad = std.math.clamp(cvtt(@ceil(r / cell)), 3, 255);
    const ww: u32 = @intCast(rad * 2 + 1);
    const win = std.heap.page_allocator.alloc(f32, ww * ww) catch return;
    defer std.heap.page_allocator.free(win);
    const h = la.heights(b);
    var lo: f32 = 1.0e30;
    var hi: f32 = -1.0e30;
    for (0..ww) |row| {
        for (0..ww) |col| {
            const si = std.math.clamp(@as(i32, @intCast(col)) -% rad +% ci, 0, n - 1);
            const sj = std.math.clamp(@as(i32, @intCast(row)) -% rad +% cj, 0, n - 1);
            const v = h[@intCast(sj * n + si)];
            win[row * ww + col] = v;
            lo = minss(lo, v);
            hi = maxss(hi, v);
        }
    }
    const rg = maxss(hi - lo, TINY);
    var k = ww * ww;
    while (k > 0) {
        k -= 1;
        win[k] = (win[k] - lo) / rg;
    }
    rng +%= 1;
    var e = procgen.Eroder{ .h = win, .n = ww, .rng = (rng *% 0x9E3779B1) | 1 };
    const drops = cvtt(@as(f32, @floatFromInt(@as(i32, @bitCast(ww * ww)))) * s * 0.5) +% 1;
    e.run(0.3, @bitCast(drops));
    const l = &b.lay[s_sl];
    const off = la.arrF(b, l.data);
    const frad: f32 = @floatFromInt(rad);
    for (0..ww) |row| {
        for (0..ww) |col| {
            const si = @as(i32, @intCast(col)) -% rad +% ci;
            const sj = @as(i32, @intCast(row)) -% rad +% cj;
            if (si < 0 or si >= n or sj < 0 or sj >= n) continue;
            const smp: usize = @intCast(sj * n + si);
            var dx: f32 = @floatFromInt(@as(i32, @intCast(col)) - rad);
            var dz: f32 = @floatFromInt(@as(i32, @intCast(row)) - rad);
            dx = dx * dx;
            dz = dz * dz;
            var w = 1.0 - (dx + dz) / (frad * frad);
            if (!(w > 0)) continue;
            w = w * w * s;
            var d = win[row * ww + col] * rg + lo;
            d = (d - h[smp]) * w;
            h[smp] = h[smp] + d;
            off[smp] = d / maxss(l.str, TINY) + off[smp];
        }
    }
}

/// ls_ramp: a straight slope from s_a to s_b, half width `hw`, strength s.
pub fn ramp(hw: f32, s: f32) void {
    const dx0 = s_b[0] - s_a[0];
    const dz0 = s_b[1] - s_a[1];
    const dd = maxss(dx0 * dx0 + dz0 * dz0, TINY);
    const cx = (s_a[0] + s_b[0]) * 0.5;
    const cz = (s_a[1] + s_b[1]) * 0.5;
    const reach = @sqrt(dd) * 0.5 + hw;
    const g = region(cx, cz, reach);
    const b = s_blk;
    const n = b.n;
    const h = la.heights(b);
    const l = &b.lay[s_sl];
    const off = la.arrF(b, l.data);
    const inv = 1.0 / maxss(l.str, TINY);
    var j = g.j0;
    while (j <= g.j1) : (j += 1) {
        var i = g.i0;
        while (i <= g.i1) : (i += 1) {
            var px = @as(f32, @floatFromInt(i)) * g.cell - g.half - s_a[0];
            var pz = @as(f32, @floatFromInt(j)) * g.cell - g.half - s_a[1];
            var t = (px * dx0 + pz * dz0) / dd;
            t = minss(maxss(t, 0), 1);
            px = px - dx0 * t;
            pz = pz - dz0 * t;
            const q = (px * px + pz * pz) / (hw * hw);
            var w = 1.0 - q;
            if (!(w > 0)) continue;
            w = w * w * 2.0 * 2.0;
            w = minss(w, 1) * s;
            const k: usize = @intCast(j * @as(i32, @intCast(n)) + i);
            var d = (s_b[2] - s_a[2]) * t + s_a[2];
            d = (d - h[k]) * w;
            h[k] = h[k] + d;
            off[k] = d * inv + off[k];
        }
    }
    show(region(cx, cz, reach));
}

/// ls_show: the display mesh's vertices on those samples follow (heights;
/// colours when painted).
fn show(g: Region) void {
    const st = s_step;
    if (st == 0) return;
    const me = display(s_obj) orelse return;
    const b = s_blk;
    const h = la.heights(b);
    if (g.i1 < 0 or g.j1 < 0) return;
    const c0 = (@as(u32, @bitCast(g.i0)) + st - 1) / st;
    const c1 = @as(u32, @intCast(g.i1)) / st;
    var r = (@as(u32, @bitCast(g.j0)) + st - 1) / st;
    const r1 = @as(u32, @intCast(g.j1)) / st;
    const painted = b.splat != 0 and me.vcol.len == me.verts.len;
    while (r <= r1) : (r += 1) {
        var c = c0;
        while (c <= c1) : (c += 1) {
            const smp = r * st * b.n + c * st;
            const v = r * s_d + c;
            if (v >= me.verts.len) continue;
            me.verts[v][1] = h[smp];
            if (painted) me.vcol[v] = la.colour(b, smp);
        }
    }
    la.bounds(me);
    scene.bumpShape(scene.objects[s_obj].mesh.?);
    if (painted) me.paints +%= 1;
    app.dirty = true;
}

// ---- operators ------------------------------------------------------------------------

fn setTool(comptime k: u32) *const fn () void {
    return &struct {
        fn f() void {
            tool = k;
            app.dirty = true;
        }
    }.f;
}
fn isTool(comptime k: u32) *const fn () bool {
    return &struct {
        fn f() bool {
            return tool == k;
        }
    }.f;
}

/// ls_tool_word: the tool a word names.
fn toolWord(w: []const u8) ?u32 {
    if (la.wordIn(&tool_names, w)) |k| return k;
    if (la.wordIn(&mat_names, w)) |k| return k + T_PAINT;
    return null;
}

/// ls_local: world (x, z) into object i's space.
fn local(i: usize, x: f32, z: f32) [2]f32 {
    const o = &scene.objects[i];
    return .{ (x - o.loc[0]) / o.scl[0], (z - o.loc[2]) / o.scl[2] };
}

/// do_ls_brush: landscape.brush <tool> x z [to x2 z2] [radius r] [strength s].
fn opBrush() void {
    const a = la.active() orelse return;
    var it = la.Words{ .s = ops.arg };
    var r: f32 = 10;
    var s: f32 = 0.5;
    var to = false;
    var p = [4]f32{ 0, 0, 0, 0 };
    const w = it.next() orelse return la.bad();
    const t = toolWord(w) orelse return la.bad();
    p[0] = it.num() orelse return la.bad();
    p[1] = it.num() orelse return la.bad();
    while (it.next()) |k| {
        if (std.mem.eql(u8, k, "to")) {
            p[2] = it.num() orelse return la.bad();
            p[3] = it.num() orelse return la.bad();
            to = true;
            continue;
        }
        if (std.mem.eql(u8, k, "radius")) {
            r = it.num() orelse return la.bad();
        } else if (std.mem.eql(u8, k, "strength")) {
            s = it.num() orelse return la.bad();
        } else return la.bad();
    }
    if (t == T_RAMP and !to) return la.bad();
    const keep = tool; // (the UI's tool, kept)
    tool = t;
    defer tool = keep;
    if (!begin(a.i, t)) return app.log("  landscape: out of memory", .{});
    const la_ = local(a.i, p[0], p[1]);
    s_a = .{ la_[0], la_[1], la.height(s_blk, la_[0], la_[1]) orelse 0 };
    const lb = local(a.i, p[2], p[3]);
    s_b = .{ lb[0], lb[1], la.height(s_blk, lb[0], lb[1]) orelse 0 };
    const rr = r / scene.objects[a.i].scl[0];
    if (t == T_RAMP) ramp(rr, 1.0) else dab(s_a[0], s_a[1], rr, s);
    end();
}

/// do_ls_paint: add <material> [colour r g b] [friction f] [bounce b] | rule
/// <i> [height lo hi] [slope lo hi] | remove <i> | auto.
fn opPaint() void {
    const a = la.active() orelse return;
    const src = a.b;
    var it = la.Words{ .s = ops.arg };
    const w = it.next() orelse return la.bad();
    if (std.mem.eql(u8, w, "auto")) return autoPaint();
    var b: *Block = undefined;
    var k: u32 = 0;
    if (std.mem.eql(u8, w, "add")) {
        const mw = it.next() orelse return la.bad();
        const mat = la.wordIn(&mat_names, mw) orelse return la.bad();
        if (src.np >= la.LA_MAXP) return app.log("  landscape: 8 paint layers at most", .{});
        b = la.make(src, src.n, la.WANT_SPLAT) orelse return la.outOfMemory();
        k = addPaint(mat, b);
    } else {
        const verb: u32 = if (std.mem.eql(u8, w, "rule")) 0 else if (std.mem.eql(u8, w, "remove")) 1 else return la.bad();
        const x = it.num() orelse return la.bad();
        const ix = cvtt(x);
        if (ix < 0 or ix >= @as(i64, src.np)) return la.bad();
        k = @intCast(ix);
        b = la.make(src, src.n, 0) orelse return la.outOfMemory();
        if (verb == 1) {
            // the ones after move down, and so do their weights
            var q = k;
            while (q + 1 < b.np) : (q += 1) b.paint[q] = b.paint[q + 1];
            b.np -= 1;
            for (la.splat(b)) |*s8| {
                var c = k;
                while (c < 7) : (c += 1) s8[c] = s8[c + 1];
                s8[7] = 0;
            }
            return done(b);
        }
    }
    const p = &b.paint[k];
    while (it.next()) |key| {
        if (std.mem.eql(u8, key, "height")) {
            p.hlo = it.num() orelse return badb(b);
            p.hhi = it.num() orelse return badb(b);
        } else if (std.mem.eql(u8, key, "slope")) {
            p.slo = it.num() orelse return badb(b);
            p.shi = it.num() orelse return badb(b);
        } else if (std.mem.eql(u8, key, "friction")) {
            p.fric = it.num() orelse return badb(b);
        } else if (std.mem.eql(u8, key, "bounce")) {
            p.bounce = it.num() orelse return badb(b);
        } else if (std.mem.eql(u8, key, "colour")) {
            var col: u32 = 0;
            for (0..3) |_| {
                const v = it.num() orelse return badb(b);
                col = (col << 8) | @as(u32, @bitCast(cvt(minss(maxss(v, 0), 1) * 255.0)));
            }
            p.col = col;
        } else return badb(b);
    }
    done(b);
}
fn badb(b: *Block) void {
    la.unref(b);
    la.bad();
}
fn done(b: *Block) void {
    if (scene.active) |i| la.objSet(i, b);
    la.unref(b);
}

/// ls_fit: 1 inside lo..hi, fading over soft outside; lo >= hi: 1.
fn fit(v: f32, lo: f32, hi: f32, soft: f32) f32 {
    if (lo >= hi) return 1; // (comiss, jae: NaN goes on)
    var t = minss(v - lo, hi - v);
    t = t / soft + 0.5;
    return minss(maxss(t, 0), 1);
}

/// atan as fpatan of a single, rounded to single.
fn atanf(x: f32) f32 {
    return @floatCast(std.math.atan(@as(f64, x)));
}

/// do_lp_auto: every sample's weights by the paint layers' rules (a soft
/// edge: 5% of the range, 5 degrees); none fits: the first layer.
fn autoPaint() void {
    const a = la.active() orelse return;
    if (a.b.np == 0) return;
    const b = la.make(a.b, a.b.n, la.WANT_SPLAT) orelse return;
    const n = b.n;
    const cell = b.size / @as(f32, @floatFromInt(n - 1));
    const lo = b.hmin;
    const rg = maxss(b.hmax - lo, TINY);
    const h = la.heights(b);
    const sp = la.splat(b);
    const np = @min(b.np, la.LA_MAXP);
    for (0..n) |j| {
        for (0..n) |i| {
            const hh = (h[j * n + i] - lo) / rg;
            const ia = if (i == 0) i else i - 1;
            const ib = if (i + 1 < n) i + 1 else i;
            var gx = h[j * n + ib] - h[j * n + ia];
            gx = gx / (@as(f32, @floatFromInt(ib - ia)) * cell);
            const ja = if (j == 0) j else j - 1;
            const jb = if (j + 1 < n) j + 1 else j;
            var gz = h[jb * n + i] - h[ja * n + i];
            gz = gz / (@as(f32, @floatFromInt(jb - ja)) * cell);
            const slope = atanf(@sqrt(gx * gx + gz * gz)) * 57.29578;
            var fits: [8]f32 = undefined;
            var sum: f32 = 0;
            for (0..np) |c| {
                const p = &b.paint[c];
                var f = fit(hh, p.hlo, p.hhi, 0.05);
                f = fit(slope, p.slo, p.shi, 5.0) * f;
                if (p.hlo >= p.hhi and p.slo >= p.shi) f = 0; // (a layer without a rule: none)
                fits[c] = f;
                sum = sum + f;
            }
            const s8 = &sp[j * n + i];
            s8.* = @splat(0);
            if (!(sum > TINY)) {
                s8[0] = 255;
                continue;
            }
            for (0..np) |c| s8[c] = @truncate(@as(u32, @bitCast(cvtt(fits[c] / sum * 255.0))));
        }
    }
    la.objSet(a.i, b);
    la.unref(b);
}

fn opAuto() void {
    autoPaint();
}

pub const list = .{
    .{ "landscape.tool_raise", Impl{ .run = setTool(T_RAISE), .check = isTool(T_RAISE) } },
    .{ "landscape.tool_lower", Impl{ .run = setTool(T_LOWER), .check = isTool(T_LOWER) } },
    .{ "landscape.tool_smooth", Impl{ .run = setTool(T_SMOOTH), .check = isTool(T_SMOOTH) } },
    .{ "landscape.tool_flatten", Impl{ .run = setTool(T_FLAT), .check = isTool(T_FLAT) } },
    .{ "landscape.tool_ramp", Impl{ .run = setTool(T_RAMP), .check = isTool(T_RAMP) } },
    .{ "landscape.tool_noise", Impl{ .run = setTool(T_NOISE), .check = isTool(T_NOISE) } },
    .{ "landscape.tool_erode", Impl{ .run = setTool(T_ERODE), .check = isTool(T_ERODE) } },
    .{ "landscape.paint_rock", Impl{ .run = setTool(T_PAINT + 0), .check = isTool(T_PAINT + 0) } },
    .{ "landscape.paint_grass", Impl{ .run = setTool(T_PAINT + 1), .check = isTool(T_PAINT + 1) } },
    .{ "landscape.paint_sand", Impl{ .run = setTool(T_PAINT + 2), .check = isTool(T_PAINT + 2) } },
    .{ "landscape.paint_snow", Impl{ .run = setTool(T_PAINT + 3), .check = isTool(T_PAINT + 3) } },
    .{ "landscape.paint_dirt", Impl{ .run = setTool(T_PAINT + 4), .check = isTool(T_PAINT + 4) } },
    .{ "landscape.paint_gravel", Impl{ .run = setTool(T_PAINT + 5), .check = isTool(T_PAINT + 5) } },
    .{ "landscape.paint_moss", Impl{ .run = setTool(T_PAINT + 6), .check = isTool(T_PAINT + 6) } },
    .{ "landscape.paint_mud", Impl{ .run = setTool(T_PAINT + 7), .check = isTool(T_PAINT + 7) } },
    .{ "landscape.paint_auto", Impl{ .run = opAuto } },
    .{ "landscape.brush", Impl{ .run = opBrush } },
    .{ "landscape.paint", Impl{ .run = opPaint } },
};

test "splat: weights stay at most 255 together" {
    var w = [8]u8{ 200, 50, 0, 0, 0, 0, 0, 5 };
    splatAdd(&w, 1, 1.0);
    var t: u32 = 0;
    for (w) |x| t += x;
    try std.testing.expect(t <= 255);
    try std.testing.expectEqual(@as(u8, 178), w[1]);
}

test "fit: inside 1, soft edge, no rule 1" {
    try std.testing.expectEqual(@as(f32, 1), fit(0.5, 0, 1, 0.05));
    try std.testing.expectEqual(@as(f32, 0.5), fit(0, 0, 1, 0.05));
    try std.testing.expectEqual(@as(f32, 1), fit(3, 0, 0, 5));
}

// ---- the stroke under the pointer (sculpt.zig hands it here) ---------------------------

const vp = @import("viewport.zig");

/// ls_enter: object i is a landscape (sculpting it): true.
pub fn enter(i: usize) bool {
    if (la.ofIndex(i) == null) return false;
    stroking = false;
    app.log("  sculpt mode: landscape (brushes and paint)", .{});
    return true;
}

var hit: [3]f32 = .{ 0, 0, 0 };
var depth: f32 = 0;

/// ls_pick: the ray under (px, py) (pixels) meets the sculpted landscape
/// (object i): hit (its space), depth.
fn pick(i: usize, c: *const vp.Cam, px: f32, py: f32) bool {
    const o = &scene.objects[i];
    const b = la.of(o) orelse return false;
    const u = (px - c.cx) / c.f;
    const v = (c.cy - py) / c.f;
    var wd: [3]f32 = undefined;
    for (0..3) |k| wd[k] = c.right[k] * u + c.up[k] * v + c.fwd[k];
    var org: [3]f32 = undefined;
    var dir: [3]f32 = undefined;
    for (0..3) |k| {
        org[k] = (c.eye[k] - o.loc[k]) / o.scl[k];
        dir[k] = wd[k] / o.scl[k];
    }
    // the box: x, z within the size, y within the heights (+- 1)
    const half = b.size * 0.5;
    var t0: f32 = 0;
    var t1: f32 = 1.0e30;
    for (0..3) |k| {
        var hi = half;
        var lo = 0 - half;
        if (k == 1) {
            lo = b.hmin - 1.0;
            hi = b.hmax + 1.0;
        }
        const d = dir[k];
        if (!(@abs(d) > TINY)) {
            if (org[k] < lo or org[k] > hi) return false; // (parallel: inside or never)
            continue;
        }
        const a = (lo - org[k]) / d;
        const e = (hi - org[k]) / d;
        t0 = maxss(t0, minss(a, e));
        t1 = minss(t1, maxss(a, e));
    }
    if (t0 >= t1) return false;
    const F = struct {
        fn f(bb: *Block, og: [3]f32, dr: [3]f32, t: f32) f32 {
            const x = dr[0] * t + og[0];
            const z = dr[2] * t + og[2];
            const y = dr[1] * t + og[1];
            return y - (la.height(bb, x, z) orelse 0);
        }
    };
    const len = @sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
    const dt = b.size / @as(f32, @floatFromInt(b.n - 1)) * 0.5 / len;
    var t = t0;
    var steps: u32 = 200000;
    _ = F.f(b, org, dir, t);
    while (true) {
        steps -= 1;
        if (steps == 0) return false;
        const nt = t + dt;
        if (nt > t1) return false;
        t = nt;
        if (!(F.f(b, org, dir, t) > 0)) break;
    }
    // crossed: halve 16 times
    var hi_t = t;
    var lo_t = t - dt;
    for (0..16) |_| {
        const mid = (hi_t + lo_t) * 0.5;
        if (F.f(b, org, dir, mid) > 0) lo_t = mid else hi_t = mid;
    }
    hit[0] = dir[0] * hi_t + org[0];
    hit[1] = dir[2] * hi_t + org[2];
    hit[2] = la.height(b, hit[0], hit[1]) orelse 0;
    depth = hi_t * (wd[0] * c.fwd[0] + wd[1] * c.fwd[1] + wd[2] * c.fwd[2]);
    return true;
}

/// ls_dab_hit: a dab at the hit.
fn dabHit() void {
    dab(hit[0], hit[1], s_r, s_s);
    s_b = hit;
}

/// ls_press: (px, py) the pointer in pixels, `rad_px` the brush's radius in
/// pixels, `str` its strength: true if a stroke began (on object i).
pub fn press(first: usize, c: *const vp.Cam, px: f32, py: f32, rad_px: f32, str: f32) bool {
    // (undo made the objects anew: the active one is the landscape)
    var i = first;
    if (la.ofIndex(i) == null) i = scene.active orelse return false;
    if (!pick(i, c, px, py)) return false;
    @import("undo.zig").label("Landscape Stroke");
    if (!begin(i, tool)) return false;
    s_r = rad_px * depth / c.f / scene.objects[i].scl[0];
    s_s = str;
    s_a = hit;
    s_b = hit;
    stroking = true;
    if (tool != T_RAMP) dabHit();
    return true;
}

/// ls_drag: dabs a fifth of the radius apart (the ramp: where it ends).
pub fn drag(c: *const vp.Cam, px: f32, py: f32) void {
    if (!stroking) return;
    if (s_obj >= scene.count or la.ofIndex(s_obj) != s_blk) return;
    if (!pick(s_obj, c, px, py)) return;
    if (tool == T_RAMP) {
        s_b = hit;
        return;
    }
    const dx = hit[0] - s_b[0];
    const dz = hit[1] - s_b[1];
    if (@sqrt(dx * dx + dz * dz) < s_r * 0.2) return;
    dabHit();
}

/// ls_release: the stroke ends (a ramp is laid now).
pub fn release() void {
    if (!stroking) return;
    stroking = false;
    if (s_obj >= scene.count or la.ofIndex(s_obj) != s_blk) return; // (undone under it)
    if (tool == T_RAMP) ramp(s_r, 1.0);
    end();
}
