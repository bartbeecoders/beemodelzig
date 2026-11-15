// The liquid's surface (particles.s stage P5).
//
// Each frame, a system with surface on is meshed: a density field on a grid
// over its particles' bounds (each particle adds (1 - r^2/R^2)^3 out to R = 2
// spacings, scaled so the lattice's sum is 1; the field is 0.5 - that),
// splatted by z slab in parallel (each slab its own, in order) into the
// system's own field. sdf.fmesh (marching tetrahedra: closed, manifold)
// meshes it at half the density when the mesh is first asked for (mesh): the
// mesh goes into its emitter's space, and the emitter shows it (mods.of ->
// shown) while the particles run. file.export_liquid writes it frame by frame.
const std = @import("std");
const linux = std.os.linux;
const scene = @import("scene.zig");
const pt = @import("particles.zig");
const rc = @import("rbcore.zig");
const jobs = @import("jobs.zig");
const app = @import("app.zig");
const A = @import("alloc.zig").A;

const V4 = rc.V4;
const minps = rc.minps;
const maxps = rc.maxps;
const maxss = rc.maxss;
const splat = rc.splat;

const SF_MAXP = 24000000; // grid points at most
const SF_MAXZ = 65536; //  slabs
const MAXN = 4194304;

var u: [*]V4 = undefined; // positions as gathered
var p: [*]V4 = undefined; //  by slab
var k_: [*]u32 = undefined; // each particle's slab
var slabs: [*]u32 = undefined; // each slab's first (slabs + 2)
var have_room = false;
var f: [*]f32 = undefined; // the field being made
var org: V4 = @splat(0); // the grid: origin, spacing
var ix: f32 = 0;
var nx: u32 = 0;
var ny: u32 = 0;
var nz: u32 = 0;
var R: f32 = 0;
var ir2: f32 = 0;
var is0: f32 = 0;
var rk: i32 = 0;
pub var nsurf: u32 = 0; // surfaces made

fn map(bytes: usize) ?[*]u8 {
    const r = linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    if (linux.errno(r) != .SUCCESS) return null;
    return @ptrFromInt(r);
}

/// sf_room: the lists have their room.
fn room() bool {
    if (have_room) return true;
    u = @ptrCast(@alignCast(map(MAXN * 16) orelse return false));
    p = @ptrCast(@alignCast(map(MAXN * 16) orelse return false));
    k_ = @ptrCast(@alignCast(map(MAXN * 4) orelse return false));
    slabs = @ptrCast(@alignCast(map(4 * (SF_MAXZ + 4)) orelse return false));
    have_room = true;
    return true;
}

fn dropMesh(s: *pt.Sys) void {
    if (s.surf.mesh) |me| {
        scene.freeMesh(me);
        A.destroy(me);
        s.surf.mesh = null;
    }
}

/// sf_free: its surface goes (the field stays mapped).
fn drop(s: *pt.Sys) void {
    if (s.surf.has) {
        s.surf.has = false;
        nsurf -= 1;
    }
    s.surf.dirty = false;
    dropMesh(s);
}

/// The system goes (pt_stop): its surface and its field.
pub fn free(s: *pt.Sys) void {
    drop(s);
    if (s.surf.field.len > 0) {
        _ = linux.munmap(@ptrCast(s.surf.field.ptr), SF_MAXP * 4);
        s.surf.field = &.{};
    }
}

/// sf_lattice: 1 / the lattice's sum of (1 - r^2/R^2)^3.
fn lattice() void {
    var sum: f32 = 0;
    var a: i32 = -2;
    while (a <= 2) : (a += 1) {
        var b: i32 = -2;
        while (b <= 2) : (b += 1) {
            var c: i32 = -2;
            while (c <= 2) : (c += 1) {
                const q: f32 = @floatFromInt(a * a + b * b + c * c);
                const t = 1.0 - q * 0.25;
                if (!(t > 0)) continue;
                sum += t * t * t;
            }
        }
    }
    is0 = 1.0 / sum;
}

/// sf_build: its surface this frame (or none).
pub fn build(s: *pt.Sys) void {
    const t_0 = rc.nowNs();
    const r = pt.nth(s.uid, s.k) orelse return drop(s);
    if (r.surf & 1 == 0 or s.n == 0) return drop(s);
    if (!room()) return drop(s);
    const d = maxss(r.size, 0.001);
    R = d * 2.0;
    ir2 = 1.0 / (R * R);
    var sp = maxss(r.sres, 0.25) * d;
    lattice();
    // the particles, their bounds
    var lo: V4 = .{ 1e30, 1e30, 1e30, 0 };
    var hi: V4 = .{ -1e30, -1e30, -1e30, -0.0 };
    var n: u32 = 0;
    for (pt.sblk[s.si][0..s.nb]) |bk| {
        for (0..pt.bn[bk]) |j| {
            const q: V4 = .{ pt.arr(bk, pt.A_X)[j], pt.arr(bk, pt.A_Y)[j], pt.arr(bk, pt.A_Z)[j], 0 };
            lo = minps(lo, q);
            hi = maxps(hi, q);
            u[n] = q;
            n += 1;
        }
    }
    // the grid: the bounds, padded; points a side (the spacing grows until they fit)
    var pad = R + sp;
    pad += sp;
    lo = rc.andXyz(lo - splat(pad));
    hi = hi + splat(pad);
    while (true) {
        const q: [4]f32 = @as(V4, @ceil((hi - lo) / splat(sp)));
        nx = @bitCast(pt.cvtn(q[0]) +% 1);
        ny = @bitCast(pt.cvtn(q[1]) +% 1);
        nz = @bitCast(pt.cvtn(q[2]) +% 1);
        if (nz <= SF_MAXZ and @as(u64, nx) * ny * nz <= SF_MAXP) break;
        sp = sp * 1.25;
    }
    // its own field
    if (s.surf.field.len == 0) {
        const fp: [*]f32 = @ptrCast(@alignCast(map(SF_MAXP * 4) orelse return drop(s)));
        s.surf.field = fp[0..SF_MAXP];
    }
    f = s.surf.field.ptr;
    org = lo;
    org[3] = sp;
    ix = 1.0 / sp;
    rk = pt.cvtt(@ceil(R / sp));
    // the particles by slab (counting sort, in order)
    @memset(slabs[0 .. nz + 2], 0);
    for (0..n) |i| {
        var kk = pt.cvtt((u[i][2] - org[2]) * ix);
        if (kk < 0) kk = 0;
        var k: u32 = @bitCast(kk);
        if (k > nz - 1) k = nz - 1;
        k_[i] = k;
        slabs[k + 1] += 1;
    }
    var acc: u32 = 0;
    for (0..nz) |z| {
        acc +%= slabs[z + 1];
        slabs[z + 1] = acc;
    }
    for (0..n) |i| {
        const k = k_[i];
        p[slabs[k]] = u[i];
        slabs[k] += 1;
    }
    var c = nz;
    while (c > 0) : (c -= 1) slabs[c] = slabs[c - 1];
    slabs[0] = 0;
    var dummy: u8 = 0;
    jobs.parallelFor(nz, 1, &dummy, sfJob);
    // the field is its surface now (the mesh: when asked for)
    drop(s);
    s.surf.org = org;
    s.surf.nx = nx;
    s.surf.ny = ny;
    s.surf.nz = nz;
    s.surf.has = true;
    s.surf.dirty = true;
    nsurf += 1;
    s.surf.ms = @as(f32, @floatFromInt(@as(i64, @intCast(rc.nowNs() - t_0)))) * 0.001 * 0.001;
}

/// sf_job: each slab's field: 0.5 less the particles near it (from the slabs
/// within R).
fn sfJob(_: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const nxy = nx * ny;
    for (lo..hi) |kz| {
        const slab = f + kz * nxy;
        @memset(slab[0..nxy], 0.5);
        const z = @as(f32, @floatFromInt(kz)) * org[3] + org[2];
        var s0: i32 = @as(i32, @intCast(kz)) - rk;
        if (s0 < 0) s0 = 0;
        var s1: u32 = @bitCast(@as(i32, @intCast(kz)) + rk + 1);
        if (s1 > nz) s1 = nz;
        const R2 = R * R;
        for (slabs[@intCast(s0)]..slabs[s1]) |pi| {
            const q = p[pi];
            var dz = q[2] - z;
            dz = dz * dz;
            if (dz >= R2) continue;
            var j0 = pt.cvtt(@ceil((q[1] - R - org[1]) * ix));
            var j1 = pt.cvtt((q[1] + R - org[1]) * ix);
            var xi0 = pt.cvtt(@ceil((q[0] - R - org[0]) * ix));
            var xi1 = pt.cvtt((q[0] + R - org[0]) * ix);
            if (j0 < 0) j0 = 0;
            if (xi0 < 0) xi0 = 0;
            if (j1 > @as(i32, @bitCast(ny)) - 1) j1 = @as(i32, @bitCast(ny)) - 1;
            if (xi1 > @as(i32, @bitCast(nx)) - 1) xi1 = @as(i32, @bitCast(nx)) - 1;
            var j = j0;
            while (j <= j1) : (j += 1) {
                var dy = @as(f32, @floatFromInt(j)) * org[3] + org[1];
                dy = dy - q[1];
                const dyz = dy * dy + dz;
                const row = slab + @as(usize, @intCast(j)) * nx;
                var i = xi0;
                while (i <= xi1) : (i += 1) {
                    var dx = @as(f32, @floatFromInt(i)) * org[3] + org[0];
                    dx = dx - q[0];
                    const rr = (dx * dx + dyz) * ir2;
                    const t = 1.0 - rr;
                    if (!(t > 0)) continue;
                    const w = t * t * t * is0;
                    row[@intCast(i)] = row[@intCast(i)] - w;
                }
            }
        }
    }
}

/// sdf_invert: the inverse of a 3x4 affine matrix (cofactors; a singular one
/// gives the identity).
pub fn invert(a: *const [12]f32) [12]f32 {
    var c: [9]f32 = undefined;
    c[0] = a[5] * a[10] - a[6] * a[9];
    c[1] = a[2] * a[9] - a[1] * a[10];
    c[2] = a[1] * a[6] - a[2] * a[5];
    c[3] = a[6] * a[8] - a[4] * a[10];
    c[4] = a[0] * a[10] - a[2] * a[8];
    c[5] = a[2] * a[4] - a[0] * a[6];
    c[6] = a[4] * a[9] - a[5] * a[8];
    c[7] = a[1] * a[8] - a[0] * a[9];
    c[8] = a[0] * a[5] - a[1] * a[4];
    var det = a[0] * c[0] + a[1] * c[3];
    det += a[2] * c[6];
    var o: [12]f32 = @splat(0);
    if (!(@abs(det) > 1.0e-20)) {
        o[0] = 1;
        o[5] = 1;
        o[10] = 1;
        return o;
    }
    const id = 1.0 / det;
    for (0..3) |r| {
        const x = c[r * 3] * id;
        const y = c[r * 3 + 1] * id;
        const z = c[r * 3 + 2] * id;
        o[r * 4] = x;
        o[r * 4 + 1] = y;
        o[r * 4 + 2] = z;
        var t = x * a[3] + y * a[7];
        t += z * a[11];
        o[r * 4 + 3] = 0.0 - t;
    }
    return o;
}

/// sf_mesh: its surface's mesh: meshed from its field now if not yet (then
/// into its emitter's space), or null.
pub fn mesh(s: *pt.Sys) ?*const scene.Mesh {
    if (!s.surf.dirty) return s.surf.mesh;
    s.surf.dirty = false;
    const t_0 = rc.nowNs();
    const o4 = s.surf.org;
    const cnt = @as(usize, s.surf.nx) * s.surf.ny * s.surf.nz;
    var out = @import("sdf.zig").fmesh(.{ o4[0], o4[1], o4[2] }, o4[3], s.surf.field[0..cnt], s.surf.nx, s.surf.ny, s.surf.nz) orelse return null;
    defer out.deinit();
    const i = scene.findUid(s.uid) orelse return null;
    const inv = invert(&@import("fields.zig").objMatrix(i));
    const mr: [3]V4 = .{ .{ inv[0], inv[1], inv[2], inv[3] }, .{ inv[4], inv[5], inv[6], inv[7] }, .{ inv[8], inv[9], inv[10], inv[11] } };
    for (out.verts.items) |*v| {
        const q = pt.mPt(&mr, .{ v[0], v[1], v[2], 0 });
        v.* = .{ q[0], q[1], q[2] };
    }
    const nt = out.loops.items.len / 3;
    const poff = A.alloc(u32, nt + 1) catch return null;
    defer A.free(poff);
    for (0..nt + 1) |t| poff[t] = @intCast(t * 3);
    const me = scene.buildMesh(out.verts.items, poff, out.loops.items) orelse return null;
    const mp = A.create(scene.Mesh) catch {
        var x = me;
        scene.freeMesh(&x);
        return null;
    };
    mp.* = me;
    mp.serial = 0xfffffffe; // (none of the scene's: caches key on it)
    s.surf.mesh = mp;
    s.surf.ms += @as(f32, @floatFromInt(@as(i64, @intCast(rc.nowNs() - t_0)))) * 0.001 * 0.001;
    return mp;
}

/// pt_field: the system whose surface object i shows, or null.
pub fn fieldOf(i: usize) ?*pt.Sys {
    if (nsurf == 0 or pt.raw) return null;
    const uid = scene.objects[i].uid;
    for (pt.sr[0..pt.ns]) |*s| {
        if (s.uid == uid and s.surf.has) return s;
    }
    return null;
}

/// pt_mesh (obj_eval): the surface object i shows now (meshed now if not yet), or null.
pub fn shown(i: usize) ?*const scene.Mesh {
    const s = fieldOf(i) orelse return null;
    return mesh(s);
}

// ---- file.export_liquid <prefix> [first last] ----------------------------------------------------

fn opExport() void {
    const ops = @import("ops.zig");
    const anim = @import("anim.zig");
    const bad = "  file.export_liquid <prefix> [first last]: the files' path and name before _0001.obj";
    const i = scene.active orelse return app.log("  particles: select the object to emit from first", .{});
    var it = std.mem.tokenizeScalar(u8, ops.arg, ' ');
    const w = it.next() orelse return app.log(bad, .{});
    var pb: [512]u8 = undefined;
    const prefix0 = @import("files.zig").expandHome(&pb, w[0..@min(w.len, 255)]) orelse w;
    var prefix: [256]u8 = undefined;
    const pl = @min(prefix0.len, 255);
    @memcpy(prefix[0..pl], prefix0[0..pl]);
    const fr = @import("frange.zig").r;
    var first: i32 = fr.start;
    var last: i32 = fr.end;
    if (it.next()) |a| {
        first = pt.cvtt(@import("print.zig").parseFloat(a) orelse return app.log(bad, .{}));
        if (it.next()) |b| last = pt.cvtt(@import("print.zig").parseFloat(b) orelse return app.log(bad, .{}));
    }
    const keep = anim.frame;
    const ob = @import("objmtl.zig");
    const keep_opts = ob.opts;
    var nf: u32 = 0;
    var f0 = first;
    while (f0 <= last) : (f0 += 1) {
        anim.apply(@floatFromInt(f0));
        var path: [300]u8 = undefined;
        const nm = std.fmt.bufPrint(&path, "{s}_{d:0>4}.obj", .{ prefix[0..pl], @as(u32, @intCast(@max(f0, 0))) % 10000 }) catch continue;
        for (scene.objects[0..scene.count]) |*o| o.selected = false;
        scene.objects[i].selected = true;
        ob.opts.sel_only = true;
        _ = ob.exportObj(nm) catch {};
        ob.opts = keep_opts;
        nf += 1;
    }
    // (this object alone stays selected, as the original leaves it)
    anim.apply(keep);
    app.log("  exported {d} frames (OBJ)", .{nf});
}

pub const list = .{
    .{ "file.export_liquid", @import("ops.zig").Impl{ .run = opExport } },
};
