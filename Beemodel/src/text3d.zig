//! 3D text (text3d.s): titles, labels and logos as real geometry.
//!
//! text.add "Hello" size 0.5 depth 0.1 makes a text object: an ordinary mesh
//! object whose mesh carries a text block (scene.Mesh.text, the original's
//! ME_TEXT: one 4096-byte page, reference counted, as curves carry theirs), so
//! drawing, materials, modifiers, rendering, export and physics see a mesh, and
//! undo needs nothing more (a change builds a new mesh, and a new block when a
//! value changes). Converting copies the mesh without the block: a plain mesh.
//!
//! The text stands in the XY plane, read from the front (+Z), its origin on the
//! last line's baseline (lines stack upwards), aligned left, centred or right.
//! Each glyph's outline comes from the TrueType walk (ttfol.zig: the original's
//! ttf.s walk with its hooks, quadratic curves flattened at the quality); its
//! loops are nested (proftri.zig), the holes bridged and ear-clipped, and the
//! whole extruded to the depth, centred on z = 0; a bevel insets the caps
//! (prof.zig's offset, halved up to five times while inset loops cross).
//! Without a TrueType font (BEEMODEL_TEXT_FONT=none, or none found), and for a
//! character the font lacks, the built-in 8x16 bitmap font is extruded pixel
//! by pixel.
//!
//! Per character, reveal (0..1 of them shown: pop, scale, rise or drop over a
//! soft width) and a wave move and scale the glyph about its middle; the
//! values are keyable as text:<object>:<value> (anim.zig K_TEXT; set values
//! wait in a new block until frame() builds it). {expression} in the body is
//! worked out when it is built (frame, time, fps).
//!
//! Files: a TEXT chunk, per mesh carrying a block (in the MESH chunks' order):
//! its index, 4092, the block from its version on, byte for byte (the hash of
//! what it was built from and the bytes after the strings' ends included).
//!
//! The arithmetic is the original's, f32 and f64 as it has them, in its order.
const std = @import("std");
const scene = @import("scene.zig");
const app = @import("app.zig");
const ttf = @import("ttfol.zig");
const T = @import("proftri.zig");
const font8 = @import("font.zig");

pub const A = @import("alloc.zig").A;

// ---- the block ----------------------------------------------------------------------------

pub const TX_SZ = 4096;
pub const NFLOAT = 12;
pub const FONT_MAX = 256;
pub const BODY_MAX = 2048;
// the floats, in TX_FLOATS order
pub const F_SIZE = 0;
pub const F_DEPTH = 1;
pub const F_BEVEL = 2;
pub const F_SPACING = 3;
pub const F_LINE = 4;
pub const F_QUALITY = 5;
pub const F_REVEAL = 6;
pub const F_SOFT = 7;
pub const F_WAVE = 8;
pub const F_WLEN = 9;
pub const F_PHASE = 10;
pub const F_SHEAR = 11;

pub const Block = extern struct {
    refs: u32 = 1,
    ver: u32 = 1,
    alignment: u32 = 1, // 0 left, 1 centre, 2 right
    rmode: u32 = 0, // reveal: 0 pop, 1 scale, 2 rise, 3 drop
    f: [NFLOAT]f32 = defs,
    hash: u64 = 0, // FNV-1a of the expanded body it was last built from
    pad: [56]u8 = @splat(0),
    font: [FONT_MAX]u8 = @splat(0), // a .ttf path or a font's name; empty: the default
    body: [BODY_MAX]u8 = body0, // UTF-8, 0-ended; \n starts a line
    tail: [TX_SZ - 384 - BODY_MAX]u8 = @splat(0),

    pub fn bytes(b: *const Block) *const [TX_SZ]u8 {
        return @ptrCast(b);
    }
    pub fn fontName(b: *const Block) []const u8 {
        return std.mem.sliceTo(&b.font, 0);
    }
    pub fn bodyText(b: *const Block) []const u8 {
        return std.mem.sliceTo(&b.body, 0);
    }
};

comptime {
    std.debug.assert(@sizeOf(Block) == TX_SZ);
    std.debug.assert(@offsetOf(Block, "f") == 16);
    std.debug.assert(@offsetOf(Block, "hash") == 64);
    std.debug.assert(@offsetOf(Block, "font") == 128);
    std.debug.assert(@offsetOf(Block, "body") == 384);
}

const defs = [NFLOAT]f32{ 1.0, 0.2, 0.0, 0.0, 1.2, 1.0, 1.0, 1.0, 0.0, 8.0, 0.0, 0.0 };
const body0 = blk: {
    var b: [BODY_MAX]u8 = @splat(0);
    @memcpy(b[0..4], "Text");
    break :blk b;
};

/// tx_new: a block with the defaults (one reference), or null.
pub fn txNew() ?*Block {
    const b = A.create(Block) catch return null;
    b.* = .{};
    return b;
}

/// tx_copy: a copy (one reference), or null.
pub fn txCopy(s: *const Block) ?*Block {
    const b = txNew() orelse return null;
    const d: *[TX_SZ]u8 = @ptrCast(b);
    @memcpy(d[4..], s.bytes()[4..]);
    return b;
}

pub fn txRef(b: ?*Block) void {
    if (b) |x| x.refs += 1;
}

pub fn txUnref(b: ?*Block) void {
    const x = b orelse return;
    x.refs -= 1;
    if (x.refs == 0) A.destroy(x);
}

/// tx_of(object): its text block, or null.
pub fn txOf(i: ?usize) ?*Block {
    const k = i orelse return null;
    if (k >= scene.count) return null;
    const o = &scene.objects[k];
    if (o.kind != .mesh) return null;
    const mi = o.mesh orelse return null;
    const me = &(scene.meshes[mi] orelse return null);
    return me.text;
}

/// tx_active: the active object when it is text.
pub fn txActive() ?usize {
    const a = scene.active orelse return null;
    return if (txOf(a) != null) a else null;
}

// the original's maxss / minss: the second operand when either is NaN
inline fn maxss(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
inline fn minss(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

/// tx_sane: values kept in range.
pub fn txSane(b: *Block) void {
    b.f[F_SIZE] = maxss(b.f[F_SIZE], 0.0001);
    b.f[F_DEPTH] = maxss(b.f[F_DEPTH], 0);
    b.f[F_BEVEL] = maxss(b.f[F_BEVEL], 0);
    b.f[F_SOFT] = maxss(b.f[F_SOFT], 0);
    b.f[F_QUALITY] = minss(maxss(b.f[F_QUALITY], 0.25), 8.0);
    b.f[F_WLEN] = maxss(b.f[F_WLEN], 0.1);
    b.f[F_REVEAL] = minss(maxss(b.f[F_REVEAL], 0), 1.0);
}

/// tx_apply(object, block): the object shows that text (a new mesh; the old
/// one released). The caller keeps its reference to the block.
pub fn txApply(i: usize, b: *Block) bool {
    const mi = txBuild(b) orelse return false;
    scene.objects[i].mesh = mi;
    app.dirty = true;
    return true;
}

// ---- fonts --------------------------------------------------------------------------------

const TXF_N = 8; // fonts kept loaded
var tf_path: [TXF_N][FONT_MAX]u8 = undefined;
var tf_fnt: [TXF_N]ttf.Font = @splat(.{});
var tf_n: u32 = 0;
var tf_next: u32 = 0;
var tf_def: ?*ttf.Font = null; // the default font (null: the block font)
var tf_def_done = false;
var tf_deff: ttf.Font = .{};

const sans_paths = [_][]const u8{
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
};

fn quiet() bool {
    if (@import("builtin").is_test) return true; // (the unit tests: no operators)
    return @import("ops.zig").quiet;
}

/// tx_font(block): the font to build with, null: the block font.
fn txFont(b: *const Block) ?*const ttf.Font {
    const name = b.fontName();
    if (name.len > 0 and !std.mem.eql(u8, name, "default")) {
        var k: u32 = 0;
        while (k < tf_n) : (k += 1) {
            if (std.mem.eql(u8, std.mem.sliceTo(&tf_path[k], 0), name)) break;
        }
        if (k == tf_n) {
            // load it into a free (or the oldest) slot; failures are kept too
            if (tf_n < TXF_N) {
                tf_n += 1;
            } else {
                k = tf_next;
                tf_next = (k + 1) % TXF_N;
                if (tf_fnt[k].loaded) ttf.unload(&tf_fnt[k]);
            }
            const n = @min(name.len, FONT_MAX - 1);
            @memcpy(tf_path[k][0..n], name[0..n]);
            tf_path[k][n] = 0;
            var pb: [1024]u8 = undefined;
            const loaded = if (tfResolve(name, &pb)) |p| ttf.load(&tf_fnt[k], p) else false;
            if (!loaded) {
                tf_fnt[k].loaded = false;
                if (!quiet()) app.log("  text: no such font (the default is used): {s}", .{name});
            }
        }
        if (tf_fnt[k].loaded) return &tf_fnt[k];
    }
    // the default: $BEEMODEL_TEXT_FONT, else the UI's sans list
    if (!tf_def_done) {
        tf_def_done = true;
        const env = @import("spawn.zig").getenv("BEEMODEL_TEXT_FONT");
        if (env != null and env.?.len > 0) {
            if (!std.mem.eql(u8, env.?, "none") and ttf.load(&tf_deff, env.?)) tf_def = &tf_deff;
        } else {
            for (sans_paths) |p| {
                if (ttf.load(&tf_deff, p)) {
                    tf_def = &tf_deff;
                    break;
                }
            }
        }
    }
    return tf_def;
}

// ---- the fonts on the system ---------------------------------------------------------------

const TFL_N = 4096;
const TFL_NAME = 64;
var tfl_n: u32 = 0;
var tfl_done = false;
var tfl_ord: [TFL_N]u32 = undefined;
var tfl_name: [TFL_N][TFL_NAME]u8 = undefined;
var tfl_path: [TFL_N][FONT_MAX]u8 = undefined;
var tfl_pb: [1024]u8 = undefined;

fn tflName(k: u32) []const u8 {
    return std.mem.sliceTo(&tfl_name[k], 0);
}

/// tf_scan: the .ttf files under the usual font folders (once), by name.
fn tfScan() void {
    if (tfl_done) return;
    tfl_done = true;
    tfRoot(null, "/usr/share/fonts");
    tfRoot(null, "/usr/local/share/fonts");
    tfRoot(null, "C:/Windows/Fonts");
    if (@import("spawn.zig").getenv("HOME")) |h| {
        tfRoot(h, "/.local/share/fonts");
        tfRoot(h, "/.fonts");
    }
    // in name order (insertion sort: letters' case ignored, as the original's
    // or 0x20 on every byte)
    var i: u32 = 0;
    while (i < tfl_n) : (i += 1) {
        tfl_ord[i] = i;
        var j = i;
        while (j > 0 and tfBefore(tfl_ord[j - 1], tfl_ord[j])) : (j -= 1) {
            std.mem.swap(u32, &tfl_ord[j - 1], &tfl_ord[j]);
        }
    }
}

/// tf_before(a, b): b's name sorts before a's.
fn tfBefore(a: u32, b: u32) bool {
    const x = &tfl_name[a];
    const y = &tfl_name[b];
    var k: usize = 0;
    while (true) : (k += 1) {
        if (y[k] == 0 or x[k] == 0) return false;
        const ca = x[k] | 0x20;
        const cb = y[k] | 0x20;
        if (cb < ca) return true;
        if (cb > ca) return false;
    }
}

fn tfRoot(prefix: ?[]const u8, folder: []const u8) void {
    var n: usize = 0;
    if (prefix) |p| {
        for (p) |c| {
            tfl_pb[n] = c;
            n += 1;
            if (n >= 512) return;
        }
    }
    if (n + folder.len >= tfl_pb.len) return;
    @memcpy(tfl_pb[n..][0..folder.len], folder);
    n += folder.len;
    tfl_pb[n] = 0;
    tfWalk(n, 0);
}

/// tf_walk(the end of tfl_pb's path, depth): its .ttf files into the list, its
/// folders walked (4 deep at most).
fn tfWalk(end: usize, depth: u32) void {
    const linux = std.os.linux;
    defer tfl_pb[end] = 0;
    const p: [*:0]const u8 = @ptrCast(&tfl_pb);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const got = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(got) != .SUCCESS or got == 0) return;
        var o: usize = 0;
        while (o < got) {
            const reclen = std.mem.readInt(u16, buf[o + 16 ..][0..2], .little);
            const dtype = buf[o + 18];
            const nm = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[o + 19])), 0);
            o += reclen;
            if (nm.len == 0 or nm[0] == '.') continue; // (., .., hidden)
            if (end + nm.len + 2 >= 1000) continue;
            tfl_pb[end] = '/';
            @memcpy(tfl_pb[end + 1 ..][0..nm.len], nm);
            const e2 = end + 1 + nm.len;
            tfl_pb[e2] = 0;
            defer tfl_pb[end] = 0;
            if (dtype == 4) { // a folder
                if (depth < 4) tfWalk(e2, depth + 1);
                continue;
            }
            if (nm.len <= 4) continue;
            var suf: [4]u8 = nm[nm.len - 4 ..][0..4].*;
            suf[1] |= 0x20;
            suf[2] |= 0x20;
            suf[3] |= 0x20;
            if (!std.mem.eql(u8, &suf, ".ttf")) continue;
            if (tfl_n >= TFL_N) continue;
            const c = tfl_n;
            tfl_n += 1;
            const pl = @min(e2, FONT_MAX - 1);
            @memcpy(tfl_path[c][0..pl], tfl_pb[0..pl]);
            tfl_path[c][pl] = 0;
            const ln = @min(nm.len - 4, TFL_NAME - 1);
            @memcpy(tfl_name[c][0..ln], nm[0..ln]);
            tfl_name[c][ln] = 0;
        }
    }
}

/// tf_same: the names match, case, spaces, hyphens and underscores aside.
fn tfSame(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        while (i < a.len and (a[i] == ' ' or a[i] == '-' or a[i] == '_')) i += 1;
        while (j < b.len and (b[j] == ' ' or b[j] == '-' or b[j] == '_')) j += 1;
        if (i >= a.len) return j >= b.len;
        if (j >= b.len) return false;
        if (a[i] | 0x20 != b[j] | 0x20) return false;
        i += 1;
        j += 1;
    }
}

/// tf_find(name): its index in the list.
fn tfFind(name: []const u8) ?u32 {
    tfScan();
    var k: u32 = 0;
    while (k < tfl_n) : (k += 1) if (tfSame(name, tflName(k))) return k;
    return null;
}

/// tf_resolve: the path to load: a path as it is (~ expanded), a name through the list.
fn tfResolve(name: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return @import("files.zig").expandHome(buf, name);
    const k = tfFind(name) orelse return null;
    return std.mem.sliceTo(&tfl_path[k], 0);
}

/// tf_names: the panel's list length ("Default", then the fonts).
pub fn tfCount() u32 {
    tfScan();
    return tfl_n + 1;
}

/// tf_label(row): its name ("Default" for row 0).
pub fn tfLabel(row: u32) ?[]const u8 {
    if (row == 0) return null;
    if (row - 1 >= tfl_n) return null;
    return tflName(tfl_ord[row - 1]);
}

pub fn tfRowLabel(row: usize) []const u8 {
    return tfLabel(@intCast(row)) orelse "Default";
}

/// tf_index(a block's font): its row in the list (0: Default, or a path that is not in it).
pub fn tfIndex(name: []const u8) u32 {
    if (name.len == 0) return 0;
    const f = tfFind(name) orelse return 0;
    var r: u32 = 0;
    while (r < tfl_n) : (r += 1) if (tfl_ord[r] == f) return r + 1;
    return 0;
}

// ---- collecting outlines (the walk's hooks) ------------------------------------------------

var tl_open = false;
var tl_skip = false;
var tl_start: u32 = 0;
var tg_inv: f32 = 0;
const td_eps: f64 = 1.0e-9;

/// tl_point: appended to the open loop (a repeat of the last point left out).
fn tlPoint(x0: f32, y0: f32) void {
    if (tl_skip) return;
    const n = T.pf_np;
    if (n >= T.MAXP) return;
    const x: f64 = x0 * tg_inv;
    const yy: f64 = y0 * tg_inv;
    const y = 0.0 - yy;
    if (n > tl_start) {
        const l = T.pf_pt[n - 1];
        var dx = l[0] - x;
        var dy = l[1] - y;
        dx *= dx;
        dy *= dy;
        dx += dy;
        if (!(dx >= td_eps)) return; // (comisd jb: NaN is the same too)
    }
    T.pf_pt[n] = .{ x, y };
    T.pf_np = n + 1;
}

/// tl_close: the open loop ends: kept when it has 3 points or more (its last
/// point dropped when it came back to the first).
fn tlClose() void {
    if (!tl_open) return;
    tl_open = false;
    if (tl_skip) return;
    var np = T.pf_np;
    const s = tl_start;
    var cnt = np - s;
    if (cnt < 2) {
        T.pf_np = s;
        return;
    }
    const a = T.pf_pt[np - 1];
    const b = T.pf_pt[s];
    var dx = a[0] - b[0];
    var dy = a[1] - b[1];
    dx *= dx;
    dy *= dy;
    dx += dy;
    if (!(dx >= td_eps)) {
        np -= 1;
        cnt -= 1;
        T.pf_np = np;
    }
    if (cnt < 3) {
        T.pf_np = s;
        return;
    }
    const l = T.pf_nl;
    T.pf_ls[l] = s;
    T.pf_ln[l] = cnt;
    T.pf_nl = l + 1;
}

fn tlBegin(x: f32, y: f32) void {
    tlClose();
    tl_skip = true;
    if (T.pf_nl >= T.MAXL) return;
    tl_skip = false;
    tl_open = true;
    tl_start = T.pf_np;
    tlPoint(x, y);
}

fn tlLine(x: f32, y: f32) void {
    if (tl_open) tlPoint(x, y);
}

/// tl_part: a simple glyph, or one part of a composite one, made solid on its own.
fn tlPart() void {
    tlClose();
    if (T.pf_nl != 0) {
        T.pf_scale = 1.0;
        T.nest();
        tgSolid();
    }
    T.pf_nl = 0;
    T.pf_np = 0;
    tl_open = false;
}

// ---- building -----------------------------------------------------------------------------

const VMAX = 2097152;
const LMAX = 8388608;
const PMAX = 2097152;
const MAXLINES = 256;

var tb_v: std.ArrayList([3]f32) = .empty;
var tb_l: std.ArrayList(u32) = .empty;
var tb_p: std.ArrayList(u32) = .empty; // corners per polygon
var tb_full = false;
var tb_oom = false;

var tg_font: ?*const ttf.Font = null;
var tg_blk: *const Block = undefined;
var tg_size: f32 = 0;
var tg_h: f32 = 0;
var tg_px: f32 = 0;
var tg_py: f32 = 0;
var tg_gs: f32 = 0;
var tg_cx: f32 = 0;
var tg_cy: f32 = 0;
var tg_dy: f32 = 0;
var tg_shear: f32 = 0;
var tg_bev: f64 = 0;
var tg_n: u32 = 0;
var tg_z: [4]f32 = .{ 0, 0, 0, 0 };
var tl_w: [MAXLINES]f32 = undefined;
var tb_outer: [T.MAXP][2]f64 = undefined;
var tb_bm: [9 * 17 * 2 * 2]i32 = undefined;
var bo_r: u32 = 0;

/// tb_room(vertices, corners, polygons): they fit (else the build is full).
fn tbRoom(v: u64, l: u64, p: u64) bool {
    if (v + tb_v.items.len > VMAX or l + tb_l.items.len > LMAX or p + tb_p.items.len > PMAX) {
        tb_full = true;
        return false;
    }
    tb_v.ensureUnusedCapacity(A, @intCast(v)) catch return oom();
    tb_l.ensureUnusedCapacity(A, @intCast(l)) catch return oom();
    tb_p.ensureUnusedCapacity(A, @intCast(p)) catch return oom();
    return true;
}

fn oom() bool {
    tb_full = true;
    tb_oom = true;
    return false;
}

/// tb_vert(u, v: the glyph's own em, layer 0..3): its index - through the
/// glyph's scale, raise and slant to the pen, times the size.
fn tbVert(u: f64, v: f64, layer: u32) u32 {
    var x: f32 = @floatCast(u);
    var y: f32 = @floatCast(v);
    x -= tg_cx;
    x *= tg_gs;
    x += tg_cx;
    y -= tg_cy;
    y *= tg_gs;
    y += tg_cy;
    y += tg_dy;
    const s = y * tg_shear;
    x += s;
    x += tg_px;
    y += tg_py;
    x *= tg_size;
    y *= tg_size;
    const k: u32 = @intCast(tb_v.items.len);
    tb_v.appendAssumeCapacity(.{ x, y, tg_z[layer] });
    return k;
}

fn tbPoly(vs: []const u32) void {
    tb_p.appendAssumeCapacity(@intCast(vs.len));
    tb_l.appendSliceAssumeCapacity(vs);
}

fn tbQuad(a: u32, b: u32, c: u32, d: u32) void {
    tbPoly(&.{ a, b, c, d });
}

fn tbTri(a: u32, b: u32, c: u32) void {
    tbPoly(&.{ a, b, c });
}

/// tg_outline(glyph): its outline, made solid part by part (tl_part).
fn tgOutline(g: u32) void {
    T.pf_nl = 0;
    T.pf_np = 0;
    tl_open = false;
    tl_skip = false;
    const f = tg_font.?;
    ttf.r_font = f;
    var q = maxss(tg_blk.f[F_QUALITY], 0.25);
    q = minss(q, 8.0);
    q *= 256.0;
    tg_inv = 1.0 / q;
    const upem: f32 = @floatFromInt(f.upem);
    ttf.r_scale = q / upem;
    ttf.r_ox = 0;
    ttf.r_oy = 0;
    ttf.walk(g, .{ .begin = tlBegin, .line = tlLine, .end = tlPart });
}

/// tc_edge(loop, edge): its points.
fn tcEdge(l: u32, e: u32) [2]u32 {
    const n = T.pf_ln[l];
    const s = T.pf_ls[l];
    return .{ s + e, s + (e + 1) % n };
}

/// tc_side(a, b, c): (b - a) x (c - a)
fn tcSide(a: u32, b: u32, c: u32) f64 {
    const pa = T.pf_pt[a];
    const pb = T.pf_pt[b];
    const pc = T.pf_pt[c];
    var x = pb[0] - pa[0];
    x *= pc[1] - pa[1];
    var y = pb[1] - pa[1];
    y *= pc[0] - pa[0];
    return x - y;
}

/// tg_crossed: two edges of the loops cross (edges that share a point aside).
fn tgCrossed() bool {
    var l1: u32 = 0;
    while (l1 < T.pf_nl) : (l1 += 1) {
        var e1: u32 = 0;
        while (e1 < T.pf_ln[l1]) : (e1 += 1) {
            const ab = tcEdge(l1, e1);
            var l2 = l1;
            var e2 = e1 + 1;
            while (l2 < T.pf_nl) : ({
                l2 += 1;
                e2 = 0;
            }) {
                while (e2 < T.pf_ln[l2]) : (e2 += 1) {
                    const cd = tcEdge(l2, e2);
                    if (cd[0] == ab[0] or cd[0] == ab[1] or cd[1] == ab[0] or cd[1] == ab[1]) continue;
                    var s = tcSide(ab[0], ab[1], cd[0]);
                    s = tcSide(ab[0], ab[1], cd[1]) * s;
                    if (s >= 0) continue; // (comisd jae: NaN goes on)
                    var t = tcSide(cd[0], cd[1], ab[0]);
                    t = tcSide(cd[0], cd[1], ab[1]) * t;
                    if (!(t >= 0)) return true; // (jb: NaN is a crossing)
                }
            }
        }
    }
    return false;
}

/// tg_solid: the loops in pf_* extruded: walls, then front and back caps. Each
/// point: a front and a back vertex; bevelled, four: the inset front, the
/// outline at the front and at the back, the inset back (layers 0..3), with
/// chamfers between them and the caps on the inset.
fn tgSolid() void {
    const np: u64 = T.pf_np;
    const nl: u64 = T.pf_nl;
    const polys = (np + nl * 2) * 2 + np + np * 2;
    if (!tbRoom(np * 4, polys * 4, polys)) return;
    var vpp: u32 = 2;
    if (!(0 >= tg_bev)) {
        // bevelled: keep the outline, inset the loops; where the inset loops
        // cross, half as much, up to 5 times
        @memcpy(tb_outer[0..T.pf_np], T.pf_pt[0..T.pf_np]);
        var bev = tg_bev;
        var tries: u32 = 5;
        while (true) {
            @import("prof.zig").offset(bev);
            if (!tgCrossed()) {
                vpp = 4;
                const b32: f32 = @floatCast(bev);
                var z1 = tg_z[0];
                z1 -= b32 * tg_size;
                tg_z[1] = z1;
                tg_z[2] = 0 - z1;
                break;
            }
            @memcpy(T.pf_pt[0..T.pf_np], tb_outer[0..T.pf_np]);
            tries -= 1;
            if (tries == 0) break; // (no bevel on this glyph)
            bev *= 0.5;
        }
    }
    const base: u32 = @intCast(tb_v.items.len);
    var i: u32 = 0;
    while (i < T.pf_np) : (i += 1) {
        const p = T.pf_pt[i];
        _ = tbVert(p[0], p[1], 0);
        if (vpp == 4) {
            const q = tb_outer[i];
            _ = tbVert(q[0], q[1], 1);
            _ = tbVert(q[0], q[1], 2);
        }
        _ = tbVert(p[0], p[1], 3);
    }
    // walls: edge a -> b
    var l: u32 = 0;
    while (l < T.pf_nl) : (l += 1) {
        const s = T.pf_ls[l];
        const n = T.pf_ln[l];
        var e: u32 = 0;
        while (e < n) : (e += 1) {
            const b = (s + (e + 1) % n) * vpp + base;
            const a = (s + e) * vpp + base;
            if (vpp != 4) {
                tbQuad(a + 1, b + 1, b, a); // back a, back b, front b, front a
            } else {
                tbQuad(a + 2, b + 2, b + 1, a + 1); // the outline's wall,
                tbQuad(a + 1, b + 1, b, a); // the front chamfer,
                tbQuad(a + 3, b + 3, b + 2, a + 2); // the back chamfer
            }
        }
    }
    // caps: each material loop with its holes
    l = 0;
    while (l < T.pf_nl) : (l += 1) {
        if (T.pf_dep[l] & 1 != 0) continue;
        T.merge(l);
        T.earclip();
        var t: u32 = 0;
        while (t < T.pf_ntri) : (t += 1) {
            const tr = T.pf_tri[t];
            const a = tr[0] * vpp + base;
            const b = tr[1] * vpp + base;
            const c = tr[2] * vpp + base;
            tbTri(a, b, c); // front: counter-clockwise
            const k = vpp - 1;
            tbTri(a + k, c + k, b + k); // back (the last layer): reversed
        }
    }
}

// ---- the block font ----------------------------------------------------------------------

/// bm_lit(column, row; the glyph's rows): lit.
fn bmLit(g: *const [16]u8, c: i32, r: i32) bool {
    if (c < 0 or c >= 8 or r < 0 or r >= 16) return false;
    const sh: u3 = @intCast(7 - c);
    return (g[@intCast(r)] >> sh) & 1 != 0;
}

/// bm_v(corner column, corner row, back): its vertex. Where two pixels touch
/// only at this corner, the one below it (row bo_r = the corner's) gets a
/// vertex of its own: each stays closed.
fn bmV(g: *const [16]u8, c: i32, r: i32, back: u32) u32 {
    var slot: usize = @intCast((r * 9 + c) * 2 + @as(i32, @intCast(back)));
    const al = bmLit(g, c - 1, r - 1);
    const ar = bmLit(g, c, r - 1);
    const bl = bmLit(g, c - 1, r);
    const br = bmLit(g, c, r);
    const diag = (al and br and !ar and !bl) or (ar and bl and !al and !br);
    if (diag and bo_r == @as(u32, @intCast(r))) slot += 9 * 17 * 2;
    if (tb_bm[slot] >= 0) return @intCast(tb_bm[slot]);
    const px: f64 = @as(f32, 0.07);
    const u = @as(f64, @floatFromInt(c)) * px;
    const v = @as(f64, @floatFromInt(12 - r)) * px;
    const k = tbVert(u, v, back * 3);
    tb_bm[slot] = @intCast(k);
    return k;
}

/// bm_wall(a, b): (a back, b back, b front, a front)
fn bmWall(g: *const [16]u8, ac: i32, ar: i32, bc: i32, br: i32) void {
    const v0 = bmV(g, ac, ar, 1);
    const v1 = bmV(g, bc, br, 1);
    const v2 = bmV(g, bc, br, 0);
    const v3 = bmV(g, ac, ar, 0);
    tbQuad(v0, v1, v2, v3);
}

/// tg_block(code point): the bitmap font's glyph, extruded pixel by pixel.
fn tgBlock(cp0: u32) void {
    const cp = if (cp0 < 32 or cp0 > 126) '?' else cp0;
    const g = &font8.glyphs[cp - 32];
    if (!tbRoom(9 * 17 * 2 * 2 + 8, 128 * 6 * 4, 128 * 6)) return;
    @memset(&tb_bm, -1);
    var r: i32 = 0;
    while (r < 16) : (r += 1) {
        var c: i32 = 0;
        while (c < 8) : (c += 1) {
            if (!bmLit(g, c, r)) continue;
            const c1 = c + 1;
            const r1 = r + 1;
            bo_r = @intCast(r);
            {
                const a = bmV(g, c, r1, 0); // front: BL, BR, TR, TL
                const b = bmV(g, c1, r1, 0);
                const d = bmV(g, c1, r, 0);
                const e = bmV(g, c, r, 0);
                tbQuad(a, b, d, e);
            }
            {
                const a = bmV(g, c, r, 1); // back: TL, TR, BR, BL
                const b = bmV(g, c1, r, 1);
                const d = bmV(g, c1, r1, 1);
                const e = bmV(g, c, r1, 1);
                tbQuad(a, b, d, e);
            }
            // walls where the neighbour is empty
            if (!bmLit(g, c, r1)) bmWall(g, c, r1, c1, r1); // below: BL -> BR
            if (!bmLit(g, c1, r)) bmWall(g, c1, r1, c1, r); // right: BR -> TR
            if (!bmLit(g, c, r - 1)) bmWall(g, c1, r, c, r); // above: TR -> TL
            if (!bmLit(g, c - 1, r)) bmWall(g, c, r, c, r1); // left: TL -> BL
        }
    }
}

// ---- characters ---------------------------------------------------------------------------

/// tg_adv(code point): its advance (em) and glyph (0: the block font draws it).
fn tgAdv(cp: u32) struct { adv: f32, g: u32 } {
    const f = tg_font orelse return .{ .adv = 0.56, .g = 0 };
    const g = f.glyphIndex(cp);
    if (g == 0 and cp != ' ') return .{ .adv = 0.56, .g = 0 }; // (a missing space is just space)
    const w: f32 = @floatFromInt(f.advanceUnits(g));
    const u: f32 = @floatFromInt(f.upem);
    return .{ .adv = w / u, .g = g };
}

/// floor(x) as roundss mode 9.
fn floorss(x: f32) f32 {
    return @floor(x);
}

/// tg_anim(character index, its advance): it shows; tg_gs / cx / cy / dy set.
fn tgAnim(i: u32, adv: f32) bool {
    tg_cx = adv * 0.5;
    tg_cy = 0.35;
    tg_gs = 1.0;
    tg_dy = 0;
    const b = tg_blk;
    var r = b.f[F_REVEAL];
    if (!(r >= 1.0)) {
        const n: f32 = @floatFromInt(tg_n);
        const fi: f32 = @floatFromInt(i);
        const s = maxss(b.f[F_SOFT], 0);
        if (b.rmode == 0 or !(s >= 0.001)) {
            // pop: shown while i < round(r N)
            r *= n;
            r += 0.5;
            r = floorss(r);
            if (!(fi < r) and !std.math.isNan(r)) return false; // (comiss jb: NaN shows)
        } else {
            // t = clamp((r (N + s) - i) / s, 0, 1)
            var w = n + s;
            w = r * w;
            w -= fi;
            w /= s;
            w = minss(w, 1.0);
            if (!(w > 0.001)) return false;
            tg_gs = w;
            const k = 1.0 - w;
            if (b.rmode == 2) {
                tg_dy = 0 - k * 0.8; // rise: from below
            } else if (b.rmode == 3) {
                tg_dy = k * 1.2; // drop: from above
            }
        }
    }
    const wave = b.f[F_WAVE];
    if (wave != 0 and !std.math.isNan(wave)) {
        // sin(2 pi (phase + i / wavelength))
        var x: f32 = @floatFromInt(i);
        x /= maxss(b.f[F_WLEN], 0.1);
        x += b.f[F_PHASE];
        x *= 6.28318531;
        const sc = @import("curve.zig").sincos(x);
        tg_dy = sc[0] * wave + tg_dy;
    }
    return true;
}

/// utf8_next: the code point at s[i.*] (0 at the end), i advanced.
pub fn utf8Next(s: []const u8, i: *usize) u32 {
    if (i.* >= s.len or s[i.*] == 0) return 0;
    const c0 = s[i.*];
    i.* += 1;
    if (c0 < 0x80) return c0;
    if (c0 < 0xc0) return 0xfffd;
    var n: u32 = 1;
    var v: u32 = c0 & 0x1f;
    if (c0 >= 0xe0) {
        n = 2;
        v = c0 & 0x0f;
        if (c0 >= 0xf0) {
            n = 3;
            v = c0 & 0x07;
            if (c0 >= 0xf8) return 0xfffd;
        }
    }
    while (n > 0) : (n -= 1) {
        const d: u32 = if (i.* < s.len) s[i.*] else 0;
        if (d & 0xc0 != 0x80) return 0xfffd;
        v = (v << 6) | (d & 0x3f);
        i.* += 1;
    }
    return v;
}

// ---- the body as built --------------------------------------------------------------------

var tx_exp: [BODY_MAX]u8 = undefined;
var tx_exp_n: usize = 0;

fn txName(w: []const u8) ?f64 {
    const an = @import("anim.zig");
    if (std.mem.eql(u8, w, "frame")) return an.frame;
    const fps: f32 = if (an.cur != null) @import("frange.zig").r.fps else 24.0;
    if (std.mem.eql(u8, w, "fps")) return fps;
    if (std.mem.eql(u8, w, "time")) return an.frame / fps;
    return null;
}

/// round to nearest, ties to even (roundsd mode 0)
fn rintd(x: f64) f64 {
    if (!(@abs(x) < 4503599627370496.0)) return x;
    const t = @trunc(x);
    const d = x - t;
    if (@abs(d) == 0.5) return if (@mod(t, 2.0) == 0) t else t + std.math.sign(d);
    return @round(x);
}

/// tx_num: a number as text: whole numbers as such, else up to three decimals.
fn txNum(v: f64, buf: []u8) []const u8 {
    const r = rintd(v);
    if (@abs(v - r) < 0.0005 and @abs(r) < 2.0e9) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i32, @intFromFloat(r))}) catch "";
    }
    if (std.math.isNan(v - r) or std.math.isNan(r)) return std.fmt.bufPrint(buf, "{d}", .{std.math.minInt(i32)}) catch "";
    const s = @import("cad.zig").fmtVal3(buf, @floatCast(v));
    return s[0..@min(s.len, 63)];
}

/// tx_expand(block): tx_exp = the body as it is built: {expression} becomes
/// its value now; {{ and }} are braces; one not understood stays.
pub fn txExpand(b: *const Block) []const u8 {
    const body = &b.body;
    var i: usize = 0;
    var o: usize = 0;
    const end = BODY_MAX - 1;
    while (o < end) {
        if (i >= BODY_MAX) break;
        var c = body[i];
        if (c == 0) break;
        i += 1;
        if (c == '{') {
            if (i < BODY_MAX and body[i] == '{') {
                i += 1;
            } else {
                // its end
                var e = i;
                while (e < BODY_MAX and body[e] != 0 and body[e] != '}') e += 1;
                if (e < BODY_MAX and body[e] == '}' and e - i < BODY_MAX - 1) {
                    const xp = @import("animexpr.zig");
                    const old = xp.name_hook;
                    xp.name_hook = txName;
                    const v = @import("cad.zig").eval(body[i..e]);
                    xp.name_hook = old;
                    if (v) |val| {
                        var nb: [64]u8 = undefined;
                        for (txNum(val, &nb)) |ch| {
                            if (o >= end) break;
                            tx_exp[o] = ch;
                            o += 1;
                        }
                        i = e + 1;
                        continue;
                    }
                    c = '{'; // (not understood: as it is)
                }
            }
        } else if (c == '}') {
            if (i < BODY_MAX and body[i] == '}') i += 1;
        }
        tx_exp[o] = c;
        o += 1;
    }
    tx_exp[o] = 0;
    tx_exp_n = o;
    return tx_exp[0..o];
}

/// tx_hash: FNV-1a.
fn txHash(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return h;
}

/// tx_build(block): the mesh slot it makes (holding a reference to the block), or null.
pub fn txBuild(b: *Block) ?u16 {
    const t0 = nowNs();
    defer if (timing.?) app.log("  text built in {d:.3} ms", .{@as(f64, @floatFromInt(nowNs() - t0)) / 1e6});
    if (timing == null) timing = @import("spawn.zig").getenv("BEEMODEL_TEXT_TIME") != null;
    tg_blk = b;
    tb_v.clearRetainingCapacity();
    tb_l.clearRetainingCapacity();
    tb_p.clearRetainingCapacity();
    tb_full = false;
    tb_oom = false;
    const exp = txExpand(b);
    b.hash = txHash(exp);
    tg_font = txFont(b);
    tg_size = maxss(b.f[F_SIZE], 0.0001);
    // the layers: front at +depth / 2, back at -depth / 2, the bevel's in between
    var h = maxss(b.f[F_DEPTH], 0);
    h *= 0.5;
    tg_h = h;
    var bev = maxss(b.f[F_BEVEL], 0);
    bev = minss(bev, h);
    tg_z[0] = h;
    tg_z[1] = h - bev;
    tg_z[2] = 0 - tg_z[1];
    tg_z[3] = 0 - h;
    tg_bev = bev / tg_size;
    tg_shear = b.f[F_SHEAR];
    const sp = b.f[F_SPACING];
    // pass 1: each line's width, the characters
    @memset(&tl_w, 0);
    var line: u32 = 0;
    var chars: u32 = 0;
    var pen: f32 = 0;
    var on_line: u32 = 0;
    var k: usize = 0;
    while (true) {
        const cp = utf8Next(exp, &k);
        if (cp == 0) break;
        if (cp == 10) {
            lineEnd(line, &pen, &on_line, sp);
            line += 1;
            continue;
        }
        if (cp < 32) continue;
        chars += 1;
        var a = tgAdv(cp).adv;
        a += sp;
        a += pen;
        pen = a;
        on_line += 1;
    }
    lineEnd(line, &pen, &on_line, sp);
    tg_n = chars;
    // pass 2: the glyphs, the first line on top: the last one's baseline at the origin
    tg_py = @as(f32, @floatFromInt(line)) * b.f[F_LINE];
    line = 0;
    var ci: u32 = 0;
    lineStart(line, b);
    k = 0;
    while (!tb_full) {
        const cp = utf8Next(exp, &k);
        if (cp == 0) break;
        if (cp == 10) {
            line += 1;
            tg_py -= b.f[F_LINE];
            lineStart(line, b);
            continue;
        }
        if (cp < 32) continue;
        const ag = tgAdv(cp);
        if (tgAnim(ci, ag.adv) and cp != 32) {
            if (ag.g != 0) tgOutline(ag.g) else tgBlock(cp);
        }
        var x = tg_px + ag.adv;
        x += sp;
        tg_px = x;
        ci += 1;
    }
    if (tb_oom) return null;
    // (an empty text: one vertex, no faces)
    if (tb_v.items.len == 0) tb_v.append(A, .{ 0, 0, 0 }) catch return null;
    const poff = A.alloc(u32, tb_p.items.len + 1) catch return null;
    defer A.free(poff);
    var at: u32 = 0;
    for (tb_p.items, 0..) |n, q| {
        poff[q] = at;
        at += n;
    }
    poff[tb_p.items.len] = at;
    const mi = scene.addMesh(tb_v.items, poff, tb_l.items) orelse return null;
    scene.meshes[mi].?.text = b;
    txRef(b);
    // (the scratch is kept for the next build, as the original's mappings)
    if (tb_v.capacity > 1 << 20) {
        tb_v.clearAndFree(A);
        tb_l.clearAndFree(A);
        tb_p.clearAndFree(A);
    }
    return mi;
}

/// BEEMODEL_TEXT_TIME: each build's time in the console (the tests' timing).
var timing: ?bool = null;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// A line ends: its width (the pen less one spacing).
fn lineEnd(line: u32, pen: *f32, on_line: *u32, sp: f32) void {
    if (line < MAXLINES) {
        var w = pen.*;
        if (on_line.* != 0) w -= sp;
        tl_w[line] = w;
    }
    pen.* = 0;
    on_line.* = 0;
}

/// The pen at the start of a line: left, centred or right of the origin.
fn lineStart(line: u32, b: *const Block) void {
    var x: f32 = 0;
    if (line < MAXLINES and b.alignment != 0) {
        x = 0 - tl_w[line];
        if (b.alignment != 2) x *= 0.5;
    }
    tg_px = x;
}

// ---- words ---------------------------------------------------------------------------------

var tk_buf: [BODY_MAX]u8 = undefined;
var tk_len: usize = 0;
var tk_q = false;

fn tkWord() []const u8 {
    return tk_buf[0..tk_len];
}

/// tk_next: the next word into tk_buf (null: no more); quoted ("..." or
/// '...'; \n a new line, \x an x).
fn tkNext(s: []const u8, i: *usize) ?usize {
    tk_q = false;
    tk_len = 0;
    const at = struct {
        fn f(t: []const u8, k: usize) u8 {
            return if (k < t.len) t[k] else 0;
        }
    }.f;
    while (at(s, i.*) == ' ' or at(s, i.*) == 9) i.* += 1;
    if (at(s, i.*) == 0) return null;
    var q: u8 = 0;
    if (at(s, i.*) == '"' or at(s, i.*) == '\'') {
        q = at(s, i.*);
        tk_q = true;
        i.* += 1;
    }
    while (true) {
        var c = at(s, i.*);
        if (c == 0) break;
        if (q == 0) {
            if (c == ' ' or c == 9) break;
        } else if (c == q) {
            i.* += 1;
            break;
        }
        i.* += 1;
        if (c == '\\') {
            c = at(s, i.*);
            if (c == 0) break;
            i.* += 1;
            if (c == 'n') c = 10;
        }
        if (tk_len < BODY_MAX - 1) {
            tk_buf[tk_len] = c;
            tk_len += 1;
        }
    }
    return tk_len;
}

/// tx_setstr(dest, append after a space): tk_buf into it (what follows the
/// end stays as it was).
fn txSetStr(dest: []u8, append: bool) void {
    var room: isize = @as(isize, @intCast(dest.len)) - 1;
    var o: usize = 0;
    if (append) {
        while (dest[o] != 0) o += 1;
        room -= @intCast(o);
        if (room <= 0) return;
        dest[o] = ' ';
        o += 1;
        room -= 1;
    }
    var k: usize = 0;
    while (room > 0 and k < tk_len and tk_buf[k] != 0) : (k += 1) {
        dest[o] = tk_buf[k];
        o += 1;
        room -= 1;
    }
    dest[o] = 0;
}

const Key = struct { name: []const u8, kind: u8, f: u8 = 0 };
const tx_keys = [_]Key{
    .{ .name = "size", .kind = 0, .f = F_SIZE },
    .{ .name = "depth", .kind = 0, .f = F_DEPTH },
    .{ .name = "extrude", .kind = 0, .f = F_DEPTH },
    .{ .name = "bevel", .kind = 0, .f = F_BEVEL },
    .{ .name = "spacing", .kind = 0, .f = F_SPACING },
    .{ .name = "line", .kind = 0, .f = F_LINE },
    .{ .name = "quality", .kind = 0, .f = F_QUALITY },
    .{ .name = "reveal", .kind = 0, .f = F_REVEAL },
    .{ .name = "soft", .kind = 0, .f = F_SOFT },
    .{ .name = "wave", .kind = 0, .f = F_WAVE },
    .{ .name = "wavelength", .kind = 0, .f = F_WLEN },
    .{ .name = "phase", .kind = 0, .f = F_PHASE },
    .{ .name = "slant", .kind = 0, .f = F_SHEAR },
    .{ .name = "body", .kind = 1 },
    .{ .name = "text", .kind = 1 },
    .{ .name = "font", .kind = 2 },
    .{ .name = "align", .kind = 3 },
    .{ .name = "mode", .kind = 4 },
};
const tx_aligns = [_][]const u8{ "left", "center", "right", "centre" };
pub const tx_fkeys = [NFLOAT][]const u8{ "size", "depth", "bevel", "spacing", "line", "quality", "reveal", "soft", "wave", "wavelength", "phase", "slant" };
const tx_modes = [_][]const u8{ "pop", "scale", "rise", "drop", "typewriter" };

fn tkIndex(names: []const []const u8) ?u32 {
    for (names, 0..) |x, k| if (std.mem.eql(u8, tkWord(), x)) return @intCast(k);
    return null;
}

/// tx_parse(block, text, bare words are body text): all of it understood (the
/// block changed as it says).
pub fn txParse(b: *Block, s: []const u8, bare_body: bool) bool {
    var i: usize = 0;
    var body_set = false;
    var last_body = false;
    while (true) {
        _ = tkNext(s, &i) orelse {
            txSane(b);
            return true;
        };
        var is_body = tk_q;
        if (!tk_q) {
            var kk: ?Key = null;
            for (tx_keys) |k| {
                if (std.mem.eql(u8, tkWord(), k.name)) {
                    kk = k;
                    break;
                }
            }
            if (kk) |k| {
                last_body = false;
                switch (k.kind) {
                    0 => {
                        const n = tkNext(s, &i) orelse return bad();
                        if (n == 0) return bad();
                        const v = @import("ntree.zig").parseFloat(tkWord(), null) orelse return bad();
                        b.f[k.f] = v;
                        continue;
                    },
                    1 => {
                        _ = tkNext(s, &i) orelse return bad();
                        tk_q = true; // (the body, whatever it says)
                        is_body = true;
                    },
                    2 => {
                        _ = tkNext(s, &i) orelse return bad();
                        txSetStr(&b.font, false);
                        continue;
                    },
                    3 => {
                        _ = tkNext(s, &i);
                        var a = tkIndex(&tx_aligns) orelse return bad();
                        if (a == 3) a = 1;
                        b.alignment = a;
                        continue;
                    },
                    else => {
                        _ = tkNext(s, &i);
                        var m = tkIndex(&tx_modes) orelse return bad();
                        if (m == 4) m = 0;
                        b.rmode = m;
                        continue;
                    },
                }
            } else {
                if (!bare_body) return bad();
                is_body = true;
            }
        }
        if (is_body) {
            // body text: the first replaces it, bare words after it are added
            txSetStr(&b.body, body_set and last_body and !tk_q);
            body_set = true;
            last_body = !tk_q;
        }
    }
}

fn bad() bool {
    if (!quiet()) app.log("  text: not understood: {s}", .{tkWord()});
    return false;
}

// ---- operators -----------------------------------------------------------------------------

fn uniqueName(o: *scene.Object, base: []const u8) void {
    o.setName(base);
    var buf: [32]u8 = undefined;
    var k: u32 = 1;
    while (nameTaken(o.name())) : (k += 1) {
        o.setName(std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ base, k }) catch return);
    }
}

fn nameTaken(s: []const u8) bool {
    for (scene.objects[0..scene.count]) |*o| if (std.mem.eql(u8, o.name(), s)) return true;
    return false;
}

/// text.add ["body"] [key value ...]
fn opAdd() void {
    const b = txNew() orelse return;
    if (!txParse(b, @import("ops.zig").arg, true)) return txUnref(b);
    const mi = txBuild(b);
    txUnref(b); // (the mesh holds it now)
    const m_ = mi orelse return;
    if (scene.count >= scene.max_objects) return scene.freeMeshSlot(m_);
    var o = scene.Object{ .kind = .mesh, .mesh = m_, .color = 0xb4b8c0 }; // (type_colors: a mesh)
    uniqueName(&o, "Text");
    scene.objects[scene.count] = o;
    scene.stamp(scene.count);
    scene.count += 1;
    const i = scene.count - 1;
    scene.selectOnly(i);
    scene.objects[i].loc = scene.cursor;
    app.dirty = true;
    if (!quiet()) app.log("  added {s}", .{scene.objects[i].name()});
}

/// text.set [key value ...]: the active text object.
fn opSet() void {
    const i = txActive() orelse return app.log("  select a text object first (Add > Text)", .{});
    const n = txCopy(txOf(i).?) orelse return;
    defer txUnref(n);
    if (txParse(n, @import("ops.zig").arg, false)) _ = txApply(i, n);
}

fn pollTx() ?[]const u8 {
    return if (txActive() == null) "Select a text object" else null;
}

/// text.to_mesh: the active text object becomes a plain mesh (a copy without the text).
fn opMesh() void {
    const i = txActive() orelse return app.log("  select a text object first (Add > Text)", .{});
    const mi = scene.objects[i].mesh orelse return;
    const n = scene.cloneMesh(mi) orelse return; // (a copy carries no text)
    scene.objects[i].mesh = n;
    app.dirty = true;
    if (!quiet()) app.log("  now a plain mesh: {s}", .{scene.objects[i].name()});
}

const Impl = @import("ops.zig").Impl;
pub const list = .{
    .{ "text.add", Impl{ .run = opAdd } },
    .{ "text.set", Impl{ .run = opSet } },
    .{ "text.to_mesh", Impl{ .run = opMesh, .poll = pollTx } },
};

/// The panel's change (textui.zig tu_new / tu_done): a copy of the block with
/// these values, made sane and shown.
pub fn setValues(i: usize, f: [NFLOAT]f32, alignment: u32, rmode: u32, body: ?[]const u8, font: ?[]const u8) void {
    const b = txOf(i) orelse return;
    const n = txCopy(b) orelse return;
    defer txUnref(n);
    n.f = f;
    n.alignment = alignment;
    n.rmode = rmode;
    if (body) |s| {
        // the typed text: \n -> a new line
        var o: usize = 0;
        var k: usize = 0;
        while (k < s.len and s[k] != 0 and o < BODY_MAX - 1) {
            var c = s[k];
            k += 1;
            if (c == '\\' and k < s.len and s[k] == 'n') {
                k += 1;
                c = 10;
            }
            n.body[o] = c;
            o += 1;
        }
        n.body[o] = 0;
    }
    if (font) |s| {
        n.font[0] = 0;
        const l = @min(s.len, FONT_MAX - 1);
        @memcpy(n.font[0..l], s[0..l]);
        n.font[l] = 0;
    }
    txSane(n);
    _ = txApply(i, n);
}

/// tx_body_set(object, body): the text says that now (false: not a text).
pub fn bodySet(i: usize, body: []const u8) bool {
    const b = txOf(i) orelse return false;
    const n = txCopy(b) orelse return false;
    defer txUnref(n);
    const l = @min(body.len, BODY_MAX - 1);
    @memcpy(n.body[0..l], body[0..l]);
    n.body[l] = 0;
    _ = txApply(i, n);
    return true;
}

// ---- animation -----------------------------------------------------------------------------

/// tx_keyidx(word): its value's index, or null.
pub fn keyIdx(w: []const u8) ?u32 {
    for (tx_fkeys, 0..) |k, q| if (std.mem.eql(u8, k, w)) return @intCast(q);
    return null;
}

/// tx_keyname(index): its name ("?" past the end).
pub fn keyName(k: u32) []const u8 {
    return if (k < NFLOAT) tx_fkeys[k] else "?";
}

const TP_MAX = 64;
var tp_n: u32 = 0;
var tp_oid: [TP_MAX]u32 = undefined;
var tp_blk: [TP_MAX]*Block = undefined;

/// tx_chan(object oid, value index, set, value): the value (null: not a text).
/// Set values wait in a new block until frame() builds it.
pub fn chan(oid: u32, k: u32, set: bool, v: f32) ?f32 {
    if (k >= NFLOAT) return null;
    const i = scene.findOid(oid) orelse return null;
    var b = txOf(i) orelse return null;
    var w: ?u32 = null;
    for (0..tp_n) |q| {
        if (tp_oid[q] == oid) {
            w = @intCast(q);
            b = tp_blk[q];
            break;
        }
    }
    if (!set) return b.f[k];
    if (v == b.f[k]) return b.f[k]; // (unchanged)
    if (w == null) {
        const n = txCopy(b) orelse return null;
        if (tp_n >= TP_MAX) { // (no room: built now)
            n.f[k] = v;
            txSane(n);
            if (txApply(i, n)) @import("undo.zig").absorb(i);
            txUnref(n);
            return v;
        }
        tp_oid[tp_n] = oid;
        tp_blk[tp_n] = n;
        tp_n += 1;
        b = n;
    }
    b.f[k] = v;
    return v;
}

/// tx_frame: after the channels are set: texts whose keyed values changed, and
/// texts whose body counts ({frame} ...) and now reads otherwise, built anew.
pub fn frame() void {
    const undo = @import("undo.zig");
    for (0..tp_n) |q| {
        const b = tp_blk[q];
        if (scene.findOid(tp_oid[q])) |i| {
            if (txOf(i) != null) {
                txSane(b);
                undo.evalWrite();
                if (txApply(i, b)) undo.absorb(i);
            }
        }
        txUnref(b);
    }
    tp_n = 0;
    // bodies with placeholders
    for (0..scene.count) |i| {
        const b = txOf(i) orelse continue;
        if (std.mem.indexOfScalar(u8, b.bodyText(), '{') == null) continue;
        if (txHash(txExpand(b)) == b.hash) continue;
        undo.evalWrite();
        if (txApply(i, b)) undo.absorb(i);
    }
}

/// Pending keyed values go (a file opens, the scene is cleared).
pub fn reset() void {
    for (tp_blk[0..tp_n]) |b| txUnref(b);
    tp_n = 0;
}

// ---- files ---------------------------------------------------------------------------------

/// tx_write: the TEXT chunk: per mesh (in the MESH chunks' order) carrying a
/// block: its index, 4092, the block from its version on.
pub fn writeChunk(out: *std.ArrayList(u8), a: std.mem.Allocator, mesh_ix: []const u32) !void {
    var recs: std.ArrayList([2]u32) = .empty;
    defer recs.deinit(a);
    for (mesh_ix, 0..) |ix, mi| {
        if (ix == 0xffffffff) continue;
        const me = scene.meshes[mi] orelse continue;
        if (me.text == null) continue;
        try recs.append(a, .{ ix, @intCast(mi) });
    }
    std.mem.sortUnstable([2]u32, recs.items, {}, struct {
        fn lt(_: void, x: [2]u32, y: [2]u32) bool {
            return x[0] < y[0];
        }
    }.lt);
    for (recs.items) |r| {
        const b = scene.meshes[r[1]].?.text.?;
        var w: [8]u8 = undefined;
        std.mem.writeInt(u32, w[0..4], r[0], .little);
        std.mem.writeInt(u32, w[4..8], TX_SZ - 4, .little);
        try out.appendSlice(a, &w);
        try out.appendSlice(a, b.bytes()[4..]);
    }
}

/// tx_read: the blocks back on the loaded meshes (the slot of each MESH chunk's index).
pub fn readChunk(d: []const u8, slots: []const ?u16) void {
    var o: usize = 0;
    while (d.len - o >= 8) {
        const n: usize = std.mem.readInt(u32, d[o + 4 ..][0..4], .little);
        if (n > d.len - o - 8) return;
        const ix = std.mem.readInt(u32, d[o..][0..4], .little);
        if (ix < slots.len) {
            if (slots[ix]) |mi| {
                if (txNew()) |b| {
                    // (a later version's longer block: cut)
                    const c = @min(n, TX_SZ - 4);
                    const bb: *[TX_SZ]u8 = @ptrCast(b);
                    @memcpy(bb[4..][0..c], d[o + 8 ..][0..c]);
                    b.refs = 1;
                    b.font[FONT_MAX - 1] = 0;
                    b.body[BODY_MAX - 1] = 0;
                    txSane(b);
                    if (scene.meshes[mi]) |*me| {
                        txUnref(me.text);
                        me.text = b;
                    } else txUnref(b);
                }
            }
        }
        o += n + 8;
    }
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "the block's layout and defaults" {
    const b = txNew().?;
    defer txUnref(b);
    const by = b.bytes();
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, by[4..8], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, by[8..12], .little));
    try testing.expectEqual(@as(f32, 0.2), @as(f32, @bitCast(std.mem.readInt(u32, by[20..24], .little))));
    try testing.expectEqualStrings("Text", b.bodyText());
    const c = txCopy(b).?;
    defer txUnref(c);
    try testing.expectEqualSlices(u8, by[4..], c.bytes()[4..]);
}

test "tx_parse: bodies, keys, appending bare words, what stays after the end" {
    const b = txNew().?;
    defer txUnref(b);
    try testing.expect(txParse(b, "Hello World size 0.5 align right 'two\\nlines' x", true));
    // (a quoted body replaces; a bare word after it replaces it again)
    try testing.expectEqualStrings("x", b.bodyText());
    try testing.expect(txParse(b, "'two\\nlines' size 0.5", true));
    try testing.expectEqualStrings("two\nlines", b.bodyText());
    try testing.expectEqual(@as(f32, 0.5), b.f[F_SIZE]);
    try testing.expectEqual(@as(u32, 2), b.alignment);
    try testing.expect(txParse(b, "body hi", false));
    // "two\nlines" overwritten by "hi": "hi\0\nlines" (what was after) stays
    try testing.expectEqualStrings("hi", b.bodyText());
    try testing.expectEqual(@as(u8, 10), b.body[3]);
    try testing.expectEqual(@as(u8, 'l'), b.body[4]);
    try testing.expect(!txParse(b, "bare", false));
    try testing.expect(!txParse(b, "size", true));
    try testing.expect(txParse(b, "quality 99 reveal -1 mode typewriter align centre", false));
    try testing.expectEqual(@as(f32, 8.0), b.f[F_QUALITY]);
    try testing.expectEqual(@as(f32, 0), b.f[F_REVEAL]);
    try testing.expectEqual(@as(u32, 1), b.alignment);
}

test "utf8_next as the original's" {
    var i: usize = 0;
    const s = "a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80\xff\xc3x";
    try testing.expectEqual(@as(u32, 'a'), utf8Next(s, &i));
    try testing.expectEqual(@as(u32, 0xe9), utf8Next(s, &i));
    try testing.expectEqual(@as(u32, 0x20ac), utf8Next(s, &i));
    try testing.expectEqual(@as(u32, 0x1f600), utf8Next(s, &i));
    try testing.expectEqual(@as(u32, 0xfffd), utf8Next(s, &i));
    try testing.expectEqual(@as(u32, 0xfffd), utf8Next(s, &i)); // (a lead without its continuation)
    try testing.expectEqual(@as(u32, 'x'), utf8Next(s, &i));
    try testing.expectEqual(@as(u32, 0), utf8Next(s, &i));
}

test "tf_same and the names' order" {
    try testing.expect(tfSame("DejaVu Sans Bold", "DejaVuSans-Bold"));
    try testing.expect(!tfSame("DejaVuSans", "DejaVuSans-Bold"));
    try testing.expect(tfSame("dejavu_sans", "DejaVuSans"));
}

test "tx_num" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("12", txNum(12.0002, &b));
    try testing.expectEqualStrings("2.5", txNum(2.5, &b));
    try testing.expectEqualStrings("3", txNum(2.9999, &b));
    try testing.expectEqualStrings("-3", txNum(-3.0, &b));
    try testing.expectEqualStrings("1.25", txNum(1.25, &b));
}
