//! A test driver for the B-rep kernel (tests/brep.py builds it on its own
//! with `zig build-exe src/breptest.zig`; it is not part of the app): it
//! replays what bfeat.s does with a feature list - sketches made as
//! BeeScript makes them, pads, pockets, holes, revolves, shells united with
//! or cut from their bodies, each body tessellated - and prints what
//! brep(name, ...) would, plus each body's triangles (as the object's mesh
//! would hold them: vertices in floats) for comparing with the original.
//!
//!   breptest SCRIPT OUTDIR
//!
//! SCRIPT lines (numbers as BeeScript takes them):
//!   sketch NAME XY|XZ|YZ [offset]      point S x y     line S a b
//!   linexy S x1 y1 x2 y2   circle S cx cy r   arc S cx cy r a0 a1
//!   rect S x y w h
//!   pad BODY S d [symmetric|reverse]   pocket BODY S d [symmetric|reverse|through]
//!   hole BODY S diameter [depth]       revolve BODY S angle [u|v]
//!   shell BODY padfeature wall [bottom]
//!   nurbscheck
//! Output (stdout): per body "B name volume area faces edges vertices loops
//! valid watertight triangles tessvolume planes cylinders cones spheres tori
//! nurbs err", and OUTDIR/name.tri: nv, nt (u32), vertices (3 f32 each),
//! triangles (3 u32 each).
const std = @import("std");
const linux = std.os.linux;
const nb = @import("nurbs.zig");
const br = @import("brep.zig");
const bt = @import("btess.zig");
const ss = @import("bssi.zig");
const bb = @import("bbuild.zig");
const bo = @import("bbool.zig");
const sk = @import("sketch.zig");

const T_PAD = 1;
const T_POCKET = 2;
const T_REVOLVE = 3;
const T_HOLE = 4;
const T_SHELL = 5;
const FF_SYM = 1;
const FF_REV = 2;
const FF_THRU = 4;

const Feat = struct { typ: u32, body: u32, sketch: u32, d: f64, d2: f64, flags: u32, axis: u32, ref: u32 };

var sketches: [64]*sk.Block = undefined;
var sk_names: [64][32]u8 = undefined;
var nsk: u32 = 0;
var bodies: [16][32]u8 = undefined;
var nbody: u32 = 0;
var feats: [256]Feat = undefined;
var nfeat: u32 = 0;
var bds: [16]u32 = undefined;
var ok: [16]bool = undefined;
var used: [16]bool = undefined;
var cur: u32 = 0;
var out_buf: [1 << 16]u8 = undefined;
var out_n: usize = 0;

const ident = [12]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };

fn put(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(out_buf[out_n..], fmt, args) catch return;
    out_n += s.len;
}

fn num(s: []const u8) f64 {
    return std.fmt.parseFloat(f64, s) catch 0;
}

fn findName(list: anytype, n: u32, name: []const u8) ?u32 {
    for (0..n) |i| {
        const s = std.mem.sliceTo(&list[i], 0);
        if (std.mem.eql(u8, s, name)) return @intCast(i);
    }
    return null;
}

fn setName(dst: *[32]u8, s: []const u8) void {
    dst.* = @splat(0);
    const n = @min(s.len, 31);
    @memcpy(dst[0..n], s[0..n]);
}

fn bodyOf(name: []const u8) u32 {
    if (findName(&bodies, nbody, name)) |i| return i;
    setName(&bodies[nbody], name);
    nbody += 1;
    return nbody - 1;
}

fn sketchOf(name: []const u8) ?*sk.Block {
    const i = findName(&sk_names, nsk, name) orelse return null;
    return sketches[i];
}

/// skx_rect: four lines joined at the corners, horizontal and vertical
fn rect(b: *sk.Block, x: f64, y: f64, w: f64, h: f64) void {
    const x1 = x + w;
    const y1 = y + h;
    const first: i32 = @intCast(b.nent);
    lineXY(b, x, y, x1, y);
    lineXY(b, x1, y, x1, y1);
    lineXY(b, x1, y1, x, y1);
    lineXY(b, x, y1, x, y);
    var k: i32 = 0;
    while (k < 4) : (k += 1) {
        const p = sk.entPoint(b, first + k, 1);
        const q = sk.entPoint(b, first + @mod(k + 1, 4), 0);
        _ = sk.addCon(b, sk.C_COINCIDENT, p, q, -1, 0, null);
    }
    k = 0;
    while (k < 4) : (k += 1) _ = sk.addCon(b, if (k & 1 == 0) sk.C_HORIZONTAL else sk.C_VERTICAL, first + k, -1, -1, 0, null);
}
fn lineXY(b: *sk.Block, x1: f64, y1: f64, x2: f64, y2: f64) void {
    const a = sk.addPoint(b, x1, y1);
    const c = sk.addPoint(b, x2, y2);
    if (a >= 0 and c >= 0) _ = sk.addLine(b, a, c);
}

fn command(line: []const u8) void {
    var w: [12][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    while (it.next()) |t| {
        if (n < w.len) w[n] = t;
        n += 1;
    }
    if (n == 0 or w[0][0] == '#') return;
    const c = w[0];
    if (std.mem.eql(u8, c, "nurbscheck")) {
        for (0..7) |k| put("n{d} {e}\n", .{ k, nb.nbCheck(@intCast(k)) });
        return;
    }
    if (n < 2) return;
    if (std.mem.eql(u8, c, "sketch")) {
        const pl: u32 = if (n > 2 and std.mem.eql(u8, w[2], "XZ")) 1 else if (n > 2 and std.mem.eql(u8, w[2], "YZ")) 2 else 0;
        const b = sk.new(pl) orelse return;
        if (n > 3) b.offset = num(w[3]);
        sketches[nsk] = b;
        setName(&sk_names[nsk], w[1]);
        nsk += 1;
        return;
    }
    if (std.mem.eql(u8, c, "point") or std.mem.eql(u8, c, "line") or std.mem.eql(u8, c, "linexy") or
        std.mem.eql(u8, c, "circle") or std.mem.eql(u8, c, "arc") or std.mem.eql(u8, c, "rect"))
    {
        const b = sketchOf(w[1]) orelse return;
        if (std.mem.eql(u8, c, "point") and n >= 4) _ = sk.addPoint(b, num(w[2]), num(w[3]));
        if (std.mem.eql(u8, c, "line") and n >= 4) _ = sk.addLine(b, @intFromFloat(num(w[2])), @intFromFloat(num(w[3])));
        if (std.mem.eql(u8, c, "linexy") and n >= 6) lineXY(b, num(w[2]), num(w[3]), num(w[4]), num(w[5]));
        if (std.mem.eql(u8, c, "circle") and n >= 5) {
            const p = sk.addPoint(b, num(w[2]), num(w[3]));
            if (p >= 0) _ = sk.addCircle(b, p, num(w[4]));
        }
        if (std.mem.eql(u8, c, "arc") and n >= 7) {
            const cx = num(w[2]);
            const cy = num(w[3]);
            const r = num(w[4]);
            const p = sk.addPoint(b, cx, cy);
            const s0 = sk.fsincos(num(w[5]));
            const q0 = sk.addPoint(b, s0[1] * r + cx, s0[0] * r + cy);
            const s1 = sk.fsincos(num(w[6]));
            const q1 = sk.addPoint(b, s1[1] * r + cx, s1[0] * r + cy);
            if (p >= 0 and q0 >= 0 and q1 >= 0) _ = sk.addArc(b, p, q0, q1, r);
        }
        if (std.mem.eql(u8, c, "rect") and n >= 6) rect(b, num(w[2]), num(w[3]), num(w[4]), num(w[5]));
        return;
    }
    var f: Feat = .{ .typ = 0, .body = bodyOf(w[1]), .sketch = 0, .d = 0, .d2 = 0, .flags = 0, .axis = 0, .ref = 0 };
    if (std.mem.eql(u8, c, "shell")) {
        if (n < 4) return;
        f.typ = T_SHELL;
        f.ref = @intFromFloat(num(w[2]));
        f.d = num(w[3]);
        if (n > 4 and std.mem.eql(u8, w[4], "bottom")) f.flags = FF_REV;
    } else {
        if (n < 4) return;
        f.sketch = findName(&sk_names, nsk, w[2]) orelse return;
        f.d = num(w[3]);
        if (std.mem.eql(u8, c, "pad")) f.typ = T_PAD;
        if (std.mem.eql(u8, c, "pocket")) f.typ = T_POCKET;
        if (std.mem.eql(u8, c, "hole")) f.typ = T_HOLE;
        if (std.mem.eql(u8, c, "revolve")) f.typ = T_REVOLVE;
        if (n > 4) {
            if (f.typ == T_HOLE) f.d2 = num(w[4]);
            if (f.typ == T_REVOLVE and (std.mem.eql(u8, w[4], "v") or std.mem.eql(u8, w[4], "y"))) f.axis = 1;
            if (f.typ == T_PAD or f.typ == T_POCKET) {
                if (std.mem.eql(u8, w[4], "symmetric")) f.flags = FF_SYM;
                if (std.mem.eql(u8, w[4], "reverse")) f.flags = FF_REV;
                if (std.mem.eql(u8, w[4], "through")) f.flags = FF_THRU;
            }
        }
    }
    if (f.typ == 0) return;
    feats[nfeat] = f;
    nfeat += 1;
}

// ---- bfeat.s -------------------------------------------------------------------------------
fn padRange(f: *const Feat, d: f64) [2]f64 {
    var w0: f64 = 0;
    var w1 = d;
    if (f.flags & FF_SYM != 0) {
        w1 = d * 0.5;
        w0 = 0 - w1;
    } else if (f.flags & FF_REV != 0) {
        w0 = 0 - d;
        w1 = 0;
    }
    if (!nb.jbe(w0, w1)) return .{ w1, w0 };
    return .{ w0, w1 };
}

fn through(slot: u32) f64 {
    if (bds[slot] == br.NONE) return 1.0;
    return bt.bdSize(bds[slot]) * 3.0 + 1.0;
}

fn tool(f: *const Feat, slot: u32) u32 {
    var src = f;
    if (f.typ == T_SHELL) {
        if (f.ref >= cur) return br.NONE;
        src = &feats[f.ref];
        if (src.typ != T_PAD) return br.NONE;
    }
    const s = sketches[src.sketch];
    bb.bpPlace(s, &ident, null);
    const d = f.d;
    const d2 = f.d2;
    if (f.typ == T_HOLE) {
        const r = d * 0.5;
        if (nb.jbe(r, 0)) return br.NONE;
        if (bb.bpPoints(s, r) == 0) return br.NONE;
    } else if (bb.bpBuild(s) == 0) return br.NONE;
    switch (f.typ) {
        T_REVOLVE => {
            if (nb.je(d, 0)) return br.NONE;
            return bb.bpRevolve(f.axis, d);
        },
        T_SHELL => {
            if (nb.jbe(d, 0)) return br.NONE;
            const w = padRange(src, src.d);
            if (!bb.bpOffset(d)) return br.NONE;
            var x = w[1] - w[0];
            x = x * 0.02;
            x = x + d;
            if (f.flags & FF_REV == 0) return bb.bpPrism(w[0] + d, w[1] + x); // open at the top
            return bb.bpPrism(w[0] - x, w[1] - d);
        },
        T_PAD => {
            const w = padRange(f, d);
            if (nb.je(w[0], w[1])) return br.NONE;
            return bb.bpPrism(w[0], w[1]);
        },
        else => {
            // pocket / hole: down from the sketch, a little past it
            var x = nb.fabs(if (f.typ == T_HOLE) d2 else d);
            if (f.flags & FF_THRU != 0 or !nb.ja(x, 0)) {
                if (f.flags & FF_THRU == 0 and f.typ != T_HOLE) return br.NONE;
                x = through(slot);
            }
            const ov = x * 0.02;
            var w0 = 0 - x;
            var w1 = ov;
            if (f.flags & FF_REV != 0) {
                w0 = 0 - ov;
                w1 = x;
            } else if (f.flags & FF_SYM != 0) {
                x = x * 0.5;
                w0 = 0 - x;
                w1 = x;
            }
            return bb.bpPrism(w0, w1);
        },
    }
}

fn apply(f: *const Feat, slot: u32) bool {
    const t = tool(f, slot);
    if (t == br.NONE) return false;
    const op: u32 = if (f.typ == T_PAD or f.typ == T_REVOLVE) bo.OP_UNION else bo.OP_DIFF;
    if (bds[slot] == br.NONE) {
        if (op != bo.OP_UNION) return false;
        bds[slot] = t;
        return true;
    }
    const r = bo.bool_(bds[slot], t, op);
    if (r == br.NONE) return false;
    bds[slot] = r;
    return true;
}

fn tessTight(ts: *const bt.Tess) bool {
    var map = std.AutoHashMap(u64, void).init(std.heap.page_allocator);
    defer map.deinit();
    var i: u32 = 0;
    while (i < ts.nt) : (i += 1) {
        for (0..3) |k| {
            const a: u64 = ts.pt[i * 3 + k];
            const b: u64 = ts.pt[i * 3 + (k + 1) % 3];
            const g = map.getOrPut((a << 32) | b) catch return false;
            if (g.found_existing) return false;
        }
    }
    i = 0;
    while (i < ts.nt) : (i += 1) {
        for (0..3) |k| {
            const a: u64 = ts.pt[i * 3 + k];
            const b: u64 = ts.pt[i * 3 + (k + 1) % 3];
            if (!map.contains((b << 32) | a)) return false;
        }
    }
    return true;
}

fn tessVolume(ts: *const bt.Tess) f64 {
    var s: f64 = 0;
    var i: u32 = 0;
    while (i < ts.nt) : (i += 1) {
        const a = ts.pv + ts.pt[i * 3] * 3;
        const b = ts.pv + ts.pt[i * 3 + 1] * 3;
        const c = ts.pv + ts.pt[i * 3 + 2] * 3;
        var x = b[1] * c[2];
        x = x - b[2] * c[1];
        x = x * a[0];
        var y = b[2] * c[0];
        y = y - b[0] * c[2];
        y = y * a[1];
        x = x + y;
        y = b[0] * c[1];
        y = y - b[1] * c[0];
        y = y * a[2];
        x = x + y;
        s += x;
    }
    return s / 6.0;
}

fn writeFile(path: [:0]const u8, data: []const u8) void {
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(fd) != .SUCCESS) return;
    var o: usize = 0;
    while (o < data.len) {
        const r = linux.write(@intCast(fd), data.ptr + o, data.len - o);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        o += r;
    }
    _ = linux.close(@intCast(fd));
}

fn rebuild(outdir: []const u8, upto: u32, report: bool) void {
    br.reset();
    ss.reset();
    bt.bt_tol = 0;
    for (0..16) |i| {
        bds[i] = br.NONE;
        ok[i] = true;
        used[i] = false;
    }
    var order: [16]u32 = undefined;
    var no: u32 = 0;
    cur = 0;
    while (cur < upto) : (cur += 1) {
        const f = &feats[cur];
        const s = f.body;
        if (!used[s]) {
            used[s] = true;
            order[no] = s;
            no += 1;
        }
        if (!ok[s]) continue;
        if (!apply(f, s)) ok[s] = false;
    }
    for (order[0..no]) |s| {
        if (!report) {
            if (ok[s] and bds[s] != br.NONE) {
                bt.bt_tol = 0;
                bt.bdTess(bds[s]);
            }
            continue;
        }
        const name = std.mem.sliceTo(&bodies[s], 0);
        if (!ok[s] or bds[s] == br.NONE) {
            put("B {s} none err {d}\n", .{ name, bo.bk_err });
            continue;
        }
        bt.bt_tol = 0;
        bt.bdTess(bds[s]);
        const b = bds[s];
        const vol = br.bdVolume(b);
        const area = br.bdArea(b);
        const bad = br.bdCheck(b);
        br.bdStats(b);
        var kinds: [6]u32 = .{ 0, 0, 0, 0, 0, 0 };
        var fi = br.bd(b).first;
        while (fi < br.bd(b).first + br.bd(b).nf) : (fi += 1) {
            const t = br.sf(br.fc(fi).surf).typ;
            if (t >= 1 and t <= 6) kinds[t - 1] += 1;
        }
        const ts: *bt.Tess = @ptrCast(@alignCast(br.bd(b).tri.?));
        put("B {s} {e} {e} {d} {d} {d} {d} {d} {d} {d} {e} {d} {d} {d} {d} {d} {d} {d}\n", .{
            name,                         vol,                          area,     br.bs_f,   br.bs_e,  br.bs_v,  br.bs_l,
            @intFromBool(bad == 0),       @intFromBool(tessTight(ts)), ts.nt,    tessVolume(ts), kinds[0], kinds[1], kinds[2],
            kinds[3],                     kinds[4],                     kinds[5], bo.bk_err,
        });
        // the mesh: vertices as floats, the triangles
        const sz = 8 + @as(usize, ts.nv) * 12 + @as(usize, ts.nt) * 12;
        const mem = std.heap.page_allocator.alloc(u8, sz) catch continue;
        defer std.heap.page_allocator.free(mem);
        std.mem.writeInt(u32, mem[0..4], ts.nv, .little);
        std.mem.writeInt(u32, mem[4..8], ts.nt, .little);
        var o: usize = 8;
        for (0..@as(usize, ts.nv) * 3) |k| {
            const x: f32 = @floatCast(ts.pv[k]);
            std.mem.writeInt(u32, mem[o..][0..4], @bitCast(x), .little);
            o += 4;
        }
        for (0..@as(usize, ts.nt) * 3) |k| {
            std.mem.writeInt(u32, mem[o..][0..4], ts.pt[k], .little);
            o += 4;
        }
        var pb: [512]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&pb, "{s}/{s}.tri", .{ outdir, name }, 0) catch continue;
        writeFile(p, mem);
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return;
    const path = args[1];
    var pb: [512]u8 = undefined;
    const pz = std.fmt.bufPrintSentinel(&pb, "{s}", .{path}, 0) catch return;
    const fd = linux.open(pz, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    var buf: [1 << 16]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const r = linux.read(@intCast(fd), buf[len..].ptr, buf.len - len);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        len += r;
    }
    _ = linux.close(@intCast(fd));
    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    while (lines.next()) |ln| command(ln);
    for (sketches[0..nsk]) |b| _ = sk.solve(b);
    // BREP_PREFIX: as the original does, the kernel replayed after every
    // feature added (for timings), then once more for the report
    if (@import("spawn.zig").getenv("BREP_PREFIX") != null) {
        var k: u32 = 1;
        while (k < nfeat) : (k += 1) rebuild(args[2], k, false);
    }
    rebuild(args[2], nfeat, true);
    _ = linux.write(1, &out_buf, out_n);
}
