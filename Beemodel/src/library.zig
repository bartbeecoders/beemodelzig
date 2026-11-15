// The content library (library.s): assets kept by their content.
//
// A library is a folder: blobs/<hash>.bee holds each asset's content, named by
// a 64-bit hash of its bytes (the same content is stored once, whoever saves
// it), thumbs/<id>.png its thumbnail, index.txt one line an asset:
//
//   id  kind  name  blob  deps (ids, or -)  tags (or -)      (tab-separated)
//
// An asset's id hashes its kind, name, blob and dependencies. Kinds:
//   object    mesh objects (their meshes as evaluated, UVs, colours), relative
//             to the first; their materials are assets it depends on
//   material  a material with its shader graph (asset.zig's record)
//   tree      a geometry node tree with the groups it runs (asset.zig)
//   rig       an armature with the meshes skinned to it (bones, weights; the
//             meshes bound again when placed)
//   action    an action's curves, played on the object it lands on
//   scene     a whole scene (a .bee file)
//
// ~/BeeModel/library is the first library; lib.add <folder> adds more (all
// are listed; assets are saved to the first). lib.place puts an asset at the
// 3D cursor (or where it is dropped from the browser), its dependencies first.
// lib.pack writes a .bee file with a manifest (LIBM), each blob once (LIBB, by
// hash) and the thumbnails (LIBT); lib.import merges one. The Asset Browser
// (libui.zig) shows the library as tiles; thumbnails are path-traced by a
// child process, one at a time, while the window goes on.
const std = @import("std");
const linux = std.os.linux;
const m = @import("math.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const nt = @import("ntree.zig");
const asset = @import("asset.zig");
const spawn = @import("spawn.zig");
const A = std.heap.page_allocator;

pub const MAX = 1024;
pub const ROOTS = 8;
pub const TH = 96; // thumbnail pixels a side
pub const K_OBJECT = 1;
pub const K_MATERIAL = 2;
pub const K_TREE = 3;
pub const K_RIG = 4;
pub const K_ACTION = 5;
pub const K_SCENE = 6;
pub const kinds = [_][]const u8{ "", "object", "material", "tree", "rig", "action", "scene" };

const LB_MAGIC: u32 = 0x4C454542; // "BEEL"
const BEE_MAGIC: u32 = 0x4d454542; // "BEEM"
fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}
const T_MESH = tag("MESH");
const T_MUVS = tag("MUVS");
const T_MVCL = tag("MVCL");
const T_VGEO = tag("VGEO");
const T_ARMT = tag("ARMT");
const T_MWGT = tag("MWGT");
const T_OBJA = tag("OBJA");
const T_LIBM = tag("LIBM");
const T_LIBB = tag("LIBB");
const T_LIBT = tag("LIBT");
const OA_SZ = 128;

pub const Rec = struct {
    id: u64 = 0,
    blob: u64 = 0,
    root: u32 = 0,
    kind: u32 = 0,
    ndep: u32 = 0,
    /// 0 to make, 1 being made, 2 made, 3 failed
    thumb: u32 = 0,
    /// its thumbnail's pixels (TH x TH, 0xRRGGBB), loaded on first use
    px: ?[]u32 = null,
    deps: [8]u64 = @splat(0),
    name: [48]u8 = @splat(0),
    tags: [96]u8 = @splat(0),
    hit: u32 = 0,
    dead: bool = false,

    pub fn nameOf(r: *const Rec) []const u8 {
        return std.mem.sliceTo(&r.name, 0);
    }
    pub fn tagsOf(r: *const Rec) []const u8 {
        return std.mem.sliceTo(&r.tags, 0);
    }
};

pub var tab: [MAX]Rec = undefined;
pub var n: u32 = 0;
var roots: [ROOTS][512]u8 = undefined;
var root_len: [ROOTS]usize = @splat(0);
pub var nroot: u32 = 0;
var ready = false;
/// The browser's selected asset (-1: none), its search and kind (0 all).
pub var sel: i32 = -1;
pub var search_buf: [128]u8 = @splat(0);
pub var search_len: usize = 0;
pub var kind_filter: u32 = 0;
pub var hits: u32 = 0;
/// Bumped by every change the browser shows.
pub var ver: u32 = 0;

// working buffers, as the original's (lb_name, lb_tags, lb_deps, lb_nmat)
var name_buf: [48]u8 = @splat(0);
var tags_buf: [512]u8 = @splat(0); // (words past 80 bytes are not added; a long one runs on)
var deps: [8]u64 = @splat(0);
var nmat: u32 = 0;
var place_at: m.V3 = .{ 0, 0, 0 };

fn cstr(b: []const u8) []const u8 {
    return std.mem.sliceTo(b, 0);
}
fn setC(dst: []u8, s: []const u8) void {
    const k = @min(s.len, dst.len - 1);
    @memcpy(dst[0..k], s[0..k]);
    dst[k] = 0;
}

// --- home, paths --------------------------------------------------------------------------

var home_buf: [512]u8 = undefined;
var home_len: usize = 0;

/// $HOME (the original's default_dir is $HOME/BeeModel). Headless runs (tests)
/// keep to /tmp: a HOME outside it is not used.
pub fn home() []const u8 {
    if (home_len == 0) {
        var h = spawn.getenv("HOME") orelse "/tmp/beemodel-headless";
        if (@import("files.zig").headless and !std.mem.startsWith(u8, h, "/tmp/")) h = "/tmp/beemodel-headless";
        home_len = @min(h.len, home_buf.len);
        @memcpy(home_buf[0..home_len], h[0..home_len]);
    }
    return home_buf[0..home_len];
}

/// Headless runs write only under /tmp.
pub fn mayWrite(p: []const u8) bool {
    return @import("files.zig").mayWrite(p);
}

/// path_expand: "~/x" -> "$HOME/x".
pub fn expand(p: []const u8, out: []u8) []const u8 {
    if (p.len > 0 and p[0] == '~' and (p.len == 1 or p[1] == '/')) return std.fmt.bufPrint(out, "{s}{s}", .{ home(), p[1..] }) catch p;
    return p;
}

pub fn hash(d: []const u8, seed: u64) u64 {
    var h: u64 = 0xcbf29ce484222325 ^ seed;
    const p: u64 = 0x100000001b3;
    var i: usize = 0;
    while (d.len - i >= 8) : (i += 8) {
        h ^= std.mem.readInt(u64, d[i..][0..8], .little);
        h *%= p;
        h ^= h >> 32;
    }
    while (i < d.len) : (i += 1) {
        h ^= d[i];
        h *%= p;
    }
    h ^= d.len;
    h *%= 0x9e3779b97f4a7c15;
    h ^= h >> 31;
    return h;
}

pub fn hex16(v: u64, out: *[16]u8) []const u8 {
    const digits = "0123456789abcdef";
    for (0..16) |k| out[k] = digits[@as(usize, @intCast((v >> @intCast(60 - 4 * k)) & 15))];
    return out;
}

/// unhex16: 16 hex digits at s[i.*] (i.* moves past those read), null when not.
fn unhex16(s: []const u8, i: *usize) ?u64 {
    var v: u64 = 0;
    for (0..16) |_| {
        const c: u8 = if (i.* < s.len) s[i.*] else 0;
        const d: u64 = if (c >= '0' and c <= '9') c - '0' else blk: {
            const l = c | 0x20;
            if (l < 'a' or l > 'f') return null;
            break :blk l - 'a' + 10;
        };
        v = v << 4 | d;
        i.* += 1;
    }
    return v;
}

var path_buf: [700]u8 = undefined;

/// lb_pathx: <root><sub>[/<hex><ext>]
fn pathx(root: u32, sub: []const u8, h: ?u64, ext: []const u8) []const u8 {
    var hx: [16]u8 = undefined;
    const r = roots[root][0..root_len[root]];
    if (h) |x| return std.fmt.bufPrint(&path_buf, "{s}{s}/{s}{s}", .{ r, sub, hex16(x, &hx), ext }) catch "";
    return std.fmt.bufPrint(&path_buf, "{s}{s}", .{ r, sub }) catch "";
}

fn exists(p: []const u8) bool {
    var zb: [701]u8 = undefined;
    if (p.len >= zb.len) return false;
    @memcpy(zb[0..p.len], p);
    zb[p.len] = 0;
    return linux.errno(linux.access(@ptrCast(&zb), 0)) == .SUCCESS;
}

fn unlink(p: []const u8) void {
    var zb: [701]u8 = undefined;
    if (p.len >= zb.len) return;
    @memcpy(zb[0..p.len], p);
    zb[p.len] = 0;
    _ = linux.unlink(@ptrCast(&zb));
}

fn writeFile(p: []const u8, d: []const u8) bool {
    if (!mayWrite(p)) return false;
    @import("bee.zig").writeAtomic(p, d) catch return false;
    return true;
}

const Mapped = struct {
    d: []const u8,
    fn deinit(x: Mapped) void {
        _ = linux.munmap(@constCast(x.d.ptr), x.d.len);
    }
};
fn readFile(p: []const u8) ?Mapped {
    const d = @import("ttf.zig").mapFile(p) orelse return null;
    return .{ .d = d };
}

// --- the index ----------------------------------------------------------------------------

/// lb_init: the libraries known (once): the first, those added, their indexes.
pub fn init() void {
    if (ready) return;
    ready = true;
    const r0 = std.fmt.bufPrint(&roots[0], "{s}/BeeModel/library", .{home()}) catch "";
    root_len[0] = r0.len;
    nroot = 1;
    if (mayWrite(r0)) _ = spawn.ensureDir(r0);
    if (readFile(pathx(0, "/libraries.txt", null, ""))) |f| {
        defer f.deinit();
        var o: usize = 0;
        while (o < f.d.len and nroot < ROOTS) {
            var k: usize = 0;
            while (o < f.d.len) {
                const c = f.d[o];
                o += 1;
                if (c == 10) break;
                if (k < 500) {
                    roots[nroot][k] = c;
                    k += 1;
                }
            }
            if (k == 0) continue;
            root_len[nroot] = k;
            nroot += 1;
        }
    }
    var r: u32 = 0;
    while (r < nroot) : (r += 1) readIndex(r);
    match();
}

/// For tests: forget everything (the next use reads the folders again).
pub fn reset() void {
    for (tab[0..n]) |*r| freePx(r);
    n = 0;
    nroot = 0;
    ready = false;
    home_len = 0;
    sel = -1;
    search_len = 0;
    kind_filter = 0;
    hits = 0;
}

fn freePx(r: *Rec) void {
    if (r.px) |p| A.free(p);
    r.px = null;
}

pub fn byId(id: u64) ?u32 {
    for (tab[0..n], 0..) |*r, i| {
        if (!r.dead and r.id == id) return @intCast(i);
    }
    return null;
}

fn readIndex(root: u32) void {
    const f = readFile(pathx(root, "/index.txt", null, "")) orelse return;
    defer f.deinit();
    var o: usize = 0;
    var line: [511]u8 = undefined;
    while (o < f.d.len) {
        var k: usize = 0;
        while (o < f.d.len) {
            const c = f.d[o];
            o += 1;
            if (c == 10) break;
            if (k < 510) {
                line[k] = c;
                k += 1;
            }
        }
        line[k] = 0;
        parseLine(root, line[0 .. k + 1]);
    }
}

/// field: the text up to a tab (room - 1 bytes kept), the cursor past the tab.
fn field(s: []const u8, i: *usize, out: []u8) void {
    var k: usize = 0;
    while (true) {
        const c = s[i.*];
        if (c == 0) break;
        i.* += 1;
        if (c == 9) break;
        if (k + 1 < out.len) {
            out[k] = c;
            k += 1;
        }
    }
    out[k] = 0;
}

fn kindOf(w: []const u8) u32 {
    for (kinds[1..], 1..) |k, i| {
        if (std.mem.eql(u8, k, w)) return @intCast(i);
    }
    return 0;
}

/// lb_parse_line: a line (NUL-terminated) as an asset (new ids only).
fn parseLine(root: u32, s: []const u8) void {
    var i: usize = 0;
    const id = unhex16(s, &i) orelse return;
    if (s[i] != 9) return;
    i += 1;
    var kw: [16]u8 = undefined;
    field(s, &i, &kw);
    const kd = kindOf(cstr(&kw));
    if (kd == 0 or n >= MAX or byId(id) != null) return;
    const r = &tab[n];
    r.* = .{ .id = id, .root = root, .kind = kd };
    field(s, &i, &r.name);
    r.blob = unhex16(s, &i) orelse return;
    if (s[i] != 9) return;
    i += 1;
    var nd: u32 = 0;
    if (s[i] == '-') {
        i += 1;
    } else while (unhex16(s, &i)) |d| {
        if (nd < 8) {
            r.deps[nd] = d;
            nd += 1;
        }
        if (s[i] != ',') break;
        i += 1;
    }
    r.ndep = nd;
    if (s[i] == 9) {
        i += 1;
        field(s, &i, &r.tags);
        if (r.tags[0] == '-' and r.tags[1] == 0) r.tags[0] = 0;
    }
    r.thumb = if (exists(pathx(root, "/thumbs", id, ".png"))) 2 else 0;
    n += 1;
}

/// lb_line_of: its index line (with the newline).
fn lineOf(r: *const Rec, out: *[512]u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    var hx: [16]u8 = undefined;
    w.print("{s}\t{s}\t{s}\t", .{ hex16(r.id, &hx), kinds[r.kind], r.nameOf() }) catch {};
    w.print("{s}\t", .{hex16(r.blob, &hx)}) catch {};
    if (r.ndep == 0) w.writeByte('-') catch {};
    for (r.deps[0..r.ndep], 0..) |d, k| {
        if (k > 0) w.writeByte(',') catch {};
        w.writeAll(hex16(d, &hx)) catch {};
    }
    w.writeByte(9) catch {};
    w.writeAll(if (r.tags[0] == 0) "-" else r.tagsOf()) catch {};
    w.writeByte(10) catch {};
    return w.buffered();
}

/// lb_write_index: index.txt again from the table.
fn writeIndex(root: u32) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(A);
    var lb: [512]u8 = undefined;
    for (tab[0..n]) |*r| {
        if (r.dead or r.root != root) continue;
        out.appendSlice(A, lineOf(r, &lb)) catch return;
    }
    _ = writeFile(pathx(root, "/index.txt", null, ""), out.items);
    ver +%= 1;
}

// --- blobs ------------------------------------------------------------------------------------

/// lb_put: its hash; stored in the first library's blobs unless there already.
fn put(d: []const u8) u64 {
    const h = hash(d, 0);
    if (exists(pathx(0, "/blobs", h, ".bee"))) return h;
    const dir = pathx(0, "/blobs", null, "");
    if (mayWrite(dir)) _ = spawn.ensureDir(dir);
    _ = writeFile(pathx(0, "/blobs", h, ".bee"), d);
    return h;
}

fn blobPath(r: *const Rec) []const u8 {
    return pathx(r.root, "/blobs", r.blob, ".bee");
}

const Added = struct { idx: ?u32, new: bool };

/// lb_add: the asset (deps / nmat its dependencies, tags_buf its tags).
fn add(kind: u32, name: []const u8, blob: u64) Added {
    var id = hash(name, blob ^ kind);
    id = hash(std.mem.sliceAsBytes(deps[0..nmat]), id);
    if (byId(id)) |i| {
        tagsMerge(&tab[i]);
        writeIndex(tab[i].root);
        return .{ .idx = i, .new = false };
    }
    if (n >= MAX) {
        app.log("  library: full", .{});
        return .{ .idx = null, .new = false };
    }
    const r = &tab[n];
    r.* = .{ .id = id, .blob = blob, .kind = kind, .ndep = nmat };
    @memcpy(r.deps[0..nmat], deps[0..nmat]);
    var k: usize = 0;
    while (k < 47 and k < name.len and name[k] != 0) : (k += 1) {
        r.name[k] = if (name[k] == 9 or name[k] == 10) '_' else name[k];
    }
    r.name[k] = 0;
    tagsMerge(r);
    n += 1;
    writeIndex(0);
    match();
    return .{ .idx = n - 1, .new = true };
}

/// tag_find: where the word is among the tags (and its length), null when not.
fn tagFind(tags: []const u8, word: []const u8) ?usize {
    var p: usize = 0;
    outer: while (true) {
        if (tags[p] == 0) return null;
        var c: usize = 0;
        while (true) : (c += 1) {
            const a: u8 = if (c < word.len) word[c] else 0;
            const d = tags[p + c];
            if (a == 0) {
                if (d == 0 or d == ',') return p;
                break;
            }
            if (a != d) break;
        }
        while (true) {
            const x = tags[p];
            p += 1;
            if (x == 0) return null;
            if (x == ',') continue :outer;
        }
    }
}

/// tags_merge: tags_buf's words (comma-separated) added to its tags, "-word"
/// ones taken away.
fn tagsMerge(r: *Rec) void {
    const src = cstr(&tags_buf);
    var i: usize = 0;
    while (i < src.len) {
        var wb: [41]u8 = undefined;
        var k: usize = 0;
        while (i < src.len) {
            const c = src[i];
            i += 1;
            if (c == ',') break;
            if (k < 40) {
                wb[k] = c;
                k += 1;
            }
        }
        if (k == 0) continue;
        const word = wb[0..k];
        const tl = cstr(&r.tags).len;
        if (word[0] != '-') {
            if (tagFind(&r.tags, word) != null) continue;
            if (tl + word.len + 2 > 95) continue;
            var at = tl;
            if (tl > 0) {
                r.tags[at] = ',';
                at += 1;
            }
            @memcpy(r.tags[at..][0..word.len], word);
            r.tags[at + word.len] = 0;
        } else {
            const w2 = word[1..];
            const p = tagFind(&r.tags, w2) orelse continue;
            const e = p + w2.len;
            if (r.tags[e] == ',') {
                const rest = cstr(r.tags[e + 1 ..]);
                std.mem.copyForwards(u8, r.tags[p..][0..rest.len], rest);
                r.tags[p + rest.len] = 0;
            } else {
                r.tags[if (p > 0) p - 1 else p] = 0;
            }
        }
    }
}

// --- search -----------------------------------------------------------------------------------

/// has_ci: the word is in the text (any case, as |0x20 folds).
fn hasCi(text: []const u8, word: []const u8) bool {
    var t: usize = 0;
    while (true) : (t += 1) {
        var c: usize = 0;
        while (true) : (c += 1) {
            if (c >= word.len) return true;
            if (t + c >= text.len) return false;
            if (word[c] | 0x20 != text[t + c] | 0x20) break;
        }
        if (t >= text.len) return false;
    }
}

pub fn search() []const u8 {
    return search_buf[0..search_len];
}

/// lb_match: hit when every word of the search is in the name, kind or tags.
pub fn match() void {
    hits = 0;
    ver +%= 1;
    const s = search();
    for (tab[0..n]) |*r| {
        r.hit = 0;
        if (r.dead) continue;
        var i: usize = 0;
        const all = blk: while (true) {
            var wb: [61]u8 = undefined;
            var k: usize = 0;
            while (i < s.len) {
                const c = s[i];
                i += 1;
                if (c == ' ') break;
                if (k < 60) {
                    wb[k] = c;
                    k += 1;
                }
            }
            if (k == 0) {
                if (i >= s.len) break :blk true;
                continue;
            }
            const w = wb[0..k];
            if (hasCi(r.nameOf(), w) or hasCi(r.tagsOf(), w) or hasCi(kinds[r.kind], w)) continue;
            break :blk false;
        };
        if (!all) continue;
        if (kind_filter != 0 and kind_filter != r.kind) continue;
        r.hit = 1;
        hits += 1;
    }
}

pub fn setSearch(s: []const u8) void {
    search_len = @min(s.len, 120);
    @memcpy(search_buf[0..search_len], s[0..search_len]);
}

/// lb_find: the asset with this id (16 hex digits), else the newest of this name.
pub fn find(w: []const u8) ?u32 {
    if (w.len == 16) {
        var i: usize = 0;
        if (unhex16(w, &i)) |id| {
            if (byId(id)) |k| return k;
        }
    }
    var k = n;
    while (k > 0) {
        k -= 1;
        if (!tab[k].dead and std.mem.eql(u8, tab[k].nameOf(), w)) return k;
    }
    return null;
}

// --- saving -----------------------------------------------------------------------------------

/// lb_words: name_buf = the first word not a #tag, tags_buf = the #tags.
fn words(w: *nt.Words) void {
    name_buf[0] = 0;
    tags_buf[0] = 0;
    while (true) {
        const x = w.next();
        if (x.len == 0) return;
        if (x[0] != '#') {
            if (name_buf[0] == 0) setC(&name_buf, x);
            continue;
        }
        const tl = cstr(&tags_buf).len;
        if (tl >= 80) continue;
        var at = tl;
        if (tl > 0) {
            tags_buf[at] = ',';
            at += 1;
        }
        const t = x[1..][0..@min(x.len - 1, tags_buf.len - 1 - at)];
        @memcpy(tags_buf[at..][0..t.len], t);
        tags_buf[at + t.len] = 0;
    }
}

/// lb_save_mat: the material's asset (tags_buf kept), null when none.
fn saveMat(mi: usize) Added {
    const h = put(asset.matBlob(mi));
    nmat = 0;
    return add(K_MATERIAL, material.list[mi].nameOf(), h);
}

var list: [256]usize = undefined;
var n_list: u32 = 0;
var mats: [64]usize = undefined;

/// lb_collect: the objects (list): the selected mesh objects (or the active
/// one); a rig: its armature first, then the selected meshes skinned (an
/// Armature modifier). mats: their materials.
fn collect(kind: u32) u32 {
    var c: u32 = 0;
    if (kind == K_RIG) {
        for (scene.objects[0..scene.count], 0..) |*o, i| {
            if (o.kind != .armature) continue;
            if (scene.active != i and !o.selected) continue;
            list[0] = i;
            c = 1;
            break;
        }
        if (c == 0) return 0;
    }
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (c >= 255) break;
        if (!o.kind.isMesh()) continue;
        if (!o.selected) {
            if (kind == K_RIG or scene.active != i) continue;
        }
        if (kind == K_RIG and armModIndex(o) == null) continue;
        list[c] = i;
        c += 1;
    }
    n_list = c;
    nmat = 0;
    for (list[0..c]) |oi| {
        const o = &scene.objects[oi];
        if (o.mat == 0 or o.mat - 1 >= material.count) continue;
        const mi: usize = o.mat - 1;
        if (std.mem.indexOfScalar(usize, mats[0..nmat], mi) != null) continue;
        if (nmat >= 64) continue;
        mats[nmat] = mi;
        nmat += 1;
    }
    return c;
}

fn armModIndex(o: *const scene.Object) ?usize {
    const mods = @import("mods.zig");
    for (o.mods.m[0..o.mods.n], 0..) |*d, k| {
        if (d.kind == mods.ARMATURE) return k;
    }
    return null;
}

/// The bytes being written (wb_*).
const Buf = struct {
    data: std.ArrayList(u8) = .empty,
    ok: bool = true,
    pub fn u32_(b: *Buf, v: u32) void {
        var x: [4]u8 = undefined;
        std.mem.writeInt(u32, &x, v, .little);
        b.bytes(&x);
    }
    pub fn bytes(b: *Buf, s: []const u8) void {
        b.data.appendSlice(A, s) catch {
            b.ok = false;
        };
    }
    fn begin(b: *Buf, t: u32) usize {
        b.u32_(t);
        b.u32_(0);
        return b.data.items.len;
    }
    fn end(b: *Buf, st: usize) void {
        if (!b.ok) return;
        std.mem.writeInt(u32, b.data.items[st - 4 ..][0..4], @intCast(b.data.items.len - st), .little);
    }
};

/// lb_obj_mesh: the mesh it is saved with (an object asset: as evaluated,
/// modifiers applied; a rig: its own).
fn objMesh(oi: usize, kind: u32) ?*const scene.Mesh {
    if (kind == K_RIG) return scene.meshOfObj(oi);
    return @import("mods.zig").of(oi);
}

/// lb_obj_blob: the listed objects - their meshes, UVs, colours, bones and
/// weights (rigs), then OBJA, placed relative to the first.
fn objBlob(b: *Buf, kind: u32) void {
    var tabm: [256]*const scene.Mesh = undefined;
    var nm: usize = 0;
    var ix: [256]u32 = undefined;
    for (list[0..n_list], 0..) |oi, k| {
        const me = objMesh(oi, kind) orelse {
            ix[k] = 0xffffffff;
            continue;
        };
        const at = for (tabm[0..nm], 0..) |x, j| {
            if (x == me) break j;
        } else blk: {
            tabm[nm] = me;
            nm += 1;
            break :blk nm - 1;
        };
        ix[k] = @intCast(at);
    }
    b.u32_(LB_MAGIC);
    b.u32_(1);
    b.u32_(kind);
    b.u32_(n_list);
    for (tabm[0..nm]) |me| {
        const st = b.begin(T_MESH);
        b.u32_(@intCast(me.verts.len));
        b.u32_(@intCast(me.poff.len - 1));
        b.u32_(@intCast(me.loops.len));
        b.bytes(std.mem.sliceAsBytes(me.verts));
        b.bytes(std.mem.sliceAsBytes(me.poff));
        b.bytes(std.mem.sliceAsBytes(me.loops));
        b.end(st);
    }
    var st = b.begin(T_MUVS);
    for (tabm[0..nm], 0..) |me, k| {
        const has_uv = me.uv.len == me.loops.len and me.uv.len > 0;
        const has_seam = me.seam.len == me.loops.len and me.seam.len > 0;
        if (!has_uv and !has_seam) continue;
        b.u32_(@intCast(k));
        b.u32_(@as(u32, @intFromBool(has_uv)) | @as(u32, @intFromBool(has_seam)) << 1);
        b.u32_(@intCast(me.loops.len));
        if (has_uv) b.bytes(std.mem.sliceAsBytes(me.uv));
        if (has_seam) {
            b.bytes(me.seam);
            const zero = [3]u8{ 0, 0, 0 };
            b.bytes(zero[0 .. (4 - me.seam.len % 4) % 4]);
        }
    }
    b.end(st);
    st = b.begin(T_MVCL);
    for (tabm[0..nm], 0..) |me, k| {
        if (me.vcol.len == 0 or me.vcol.len != me.verts.len) continue;
        b.u32_(@intCast(k));
        b.u32_(@intCast(me.vcol.len));
        b.bytes(std.mem.sliceAsBytes(me.vcol));
    }
    b.end(st);
    if (kind == K_RIG) {
        st = b.begin(T_ARMT);
        for (tabm[0..nm], 0..) |me, k| {
            const ab = me.arm orelse continue;
            b.u32_(@intCast(k));
            b.bytes(std.mem.asBytes(ab)[4..]);
        }
        b.end(st);
        st = b.begin(T_MWGT);
        for (tabm[0..nm], 0..) |me, k| {
            if (me.wgt.len != me.verts.len or me.wgt.len == 0) continue;
            b.u32_(@intCast(k));
            b.u32_(@intCast(me.wgt.len));
            b.bytes(std.mem.sliceAsBytes(me.wgt));
        }
        b.end(st);
    }
    st = b.begin(T_OBJA);
    const anchor = scene.worldPlace(list[0]);
    for (list[0..n_list], 0..) |oi, k| {
        const o = &scene.objects[oi];
        var r: [OA_SZ]u8 = @splat(0);
        @memcpy(r[0..o.name().len], o.name());
        var wp = scene.worldPlace(oi);
        for (0..3) |c| wp[c] -= anchor[c];
        for (wp, 0..) |v, c| std.mem.writeInt(u32, r[32 + c * 4 ..][0..4], @bitCast(v), .little);
        std.mem.writeInt(u32, r[68..72], o.color & 0xffffff, .little);
        std.mem.writeInt(u32, r[72..76], typeOf(o), .little);
        std.mem.writeInt(u32, r[76..80], flagsOf(o), .little);
        std.mem.writeInt(u32, r[80..84], ix[k], .little);
        if (o.mat != 0 and o.mat - 1 < material.count) {
            const mn = material.list[o.mat - 1].name;
            @memcpy(r[84..115], mn[0..31]);
        }
        std.mem.writeInt(i32, r[116..120], if (kind == K_RIG and k > 0) 0 else -1, .little);
        b.bytes(&r);
    }
    b.end(st);
}

fn typeOf(o: *const scene.Object) u32 {
    return switch (o.kind) {
        .light => 1,
        .camera => 2,
        .armature => 4,
        .sketch => 3,
        .field => 5,
        else => 0,
    };
}
fn flagsOf(o: *const scene.Object) u32 {
    var f: u32 = 0;
    if (o.selected) f |= 1;
    if (!o.visible) f |= 0x200;
    if (o.locked) f |= 0x400;
    if (!o.render) f |= 0x800;
    if (o.folded) f |= 0x1000;
    return f | o.ref | o.gflags;
}

/// an_action_blob: name (32), start, end, the curves (kind a b c, keys).
fn actionBlob(b: *Buf, nm: []const u8) bool {
    const anim = @import("anim.zig");
    const blk = anim.cur orelse return false;
    var act: u32 = 0;
    for (blk.actions(), 0..) |*a, k| {
        if (std.mem.eql(u8, std.mem.sliceTo(&a.name, 0), nm)) {
            act = @intCast(k + 1);
            break;
        }
    }
    if (act == 0) return false;
    b.bytes(std.mem.asBytes(&blk.h.act[act - 1])[0..40]);
    var c: u32 = 0;
    for (blk.curves()) |*cu| {
        if (cu.act == act) c += 1;
    }
    b.u32_(c);
    for (blk.curves()) |*cu| {
        if (cu.act != act) continue;
        b.u32_(cu.kind);
        b.u32_(if (anim.isObjectKind(cu.kind)) (if (cu.a == 0) 0 else scene.uidOfOid(cu.a) orelse 0) else cu.a);
        b.u32_(cu.b);
        b.u32_(cu.c);
        b.u32_(cu.n);
        b.bytes(std.mem.sliceAsBytes(blk.keysOf(cu)));
    }
    return true;
}

/// an_action_add: an action blob back as an action, its object channels on
/// the object (uid, 0: as they were). Its number (0: not one, or no room).
fn actionAdd(d: []const u8, oid: u32, uid: u32) u32 {
    const anim = @import("anim.zig");
    if (d.len < 44) return 0;
    var ncur = std.mem.readInt(u32, d[40..44], .little);
    var o: usize = 44;
    var keys: u64 = 0;
    while (ncur > 0) : (ncur -= 1) {
        if (o + 20 > d.len) return 0;
        const kn = std.mem.readInt(u32, d[o + 16 ..][0..4], .little);
        keys += kn;
        o += 20 + @as(usize, kn) * 32;
        if (o > d.len) return 0;
    }
    if (keys > 0x1000000) return 0;
    const b = anim.own(@intCast(keys)) orelse return 0;
    const nc = std.mem.readInt(u32, d[40..44], .little);
    if (b.h.nact >= anim.MAXA or b.h.ncur + nc > anim.MAXC) return 0;
    const ac = &b.h.act[b.h.nact];
    @memcpy(std.mem.asBytes(ac)[0..40], d[0..40]);
    ac.name[31] = 0;
    b.h.nact += 1;
    const act = b.h.nact;
    o = 44;
    var k: u32 = 0;
    while (k < nc) : (k += 1) {
        const cu = &b.h.cur[b.h.ncur];
        cu.kind = std.mem.readInt(u32, d[o..][0..4], .little);
        cu.a = std.mem.readInt(u32, d[o + 4 ..][0..4], .little);
        cu.b = std.mem.readInt(u32, d[o + 8 ..][0..4], .little);
        cu.c = std.mem.readInt(u32, d[o + 12 ..][0..4], .little);
        const kn = std.mem.readInt(u32, d[o + 16 ..][0..4], .little);
        if (anim.isObjectKind(cu.kind)) {
            // (the file's uid: our object with it, else a reference kept as it is)
            cu.a = if (uid != 0 and cu.kind != anim.K_MAT and cu.kind != anim.K_NODE) oid else if (cu.a == 0) 0 else if (scene.findUid(cu.a)) |i| scene.objects[i].oid else scene.foreignOid(cu.a);
        } else if (uid != 0 and cu.kind != anim.K_MAT and cu.kind != anim.K_NODE) cu.a = uid;
        cu.first = b.h.nkey;
        cu.n = kn;
        cu.act = act;
        cu.pad = 0;
        b.h.ncur += 1;
        @memcpy(std.mem.sliceAsBytes(b.keys[b.h.nkey..][0..kn]), d[o + 20 ..][0 .. @as(usize, kn) * 32]);
        b.h.nkey += kn;
        o += 20 + @as(usize, kn) * 32;
    }
    app.dirty = true;
    return act;
}

/// lib.save <kind> [name] [#tag ...]
fn opSave() void {
    init();
    var w = nt.Words{ .s = ops.arg };
    const need = "  lib.save object|rig|scene [name] [#tag ...] | material|tree|action <name> [#tag ...]";
    const kw = w.next();
    if (kw.len == 0) return app.log(need, .{});
    const kind = kindOf(kw);
    if (kind == 0) return app.log(need, .{});
    words(&w);
    nmat = 0;
    const nm = cstr(&name_buf);
    var got: Added = .{ .idx = null, .new = false };
    switch (kind) {
        K_MATERIAL => {
            const mi = material.find(nm) orelse return app.log("  library: no such material, tree or action: {s}", .{nm});
            got = saveMat(mi);
        },
        K_TREE => {
            const t = nt.find(nm) orelse return app.log("  library: no such material, tree or action: {s}", .{nm});
            got = add(K_TREE, nm, put(asset.treeBlob(t)));
        },
        K_ACTION => {
            var b = Buf{};
            defer b.data.deinit(A);
            if (!actionBlob(&b, nm)) return app.log("  library: no such material, tree or action: {s}", .{nm});
            got = add(K_ACTION, nm, put(b.data.items));
        },
        K_SCENE => {
            const dir = pathx(0, "/blobs", null, "");
            if (mayWrite(dir)) _ = spawn.ensureDir(dir);
            const d = @import("bee.zig").encode(@import("files.zig").viewForFile()) catch return app.log("  library: nothing to save (select mesh objects; a rig needs an armature)", .{});
            defer A.free(d);
            const h = put(d);
            if (name_buf[0] == 0) setC(&name_buf, "Scene");
            got = add(K_SCENE, cstr(&name_buf), h);
        },
        else => {
            // objects, rigs: their materials first, then the objects' blob
            if (collect(kind) == 0) return app.log("  library: nothing to save (select mesh objects; a rig needs an armature)", .{});
            const nm_mats = nmat;
            var saved_tags: [512]u8 = undefined;
            for (mats[0..nm_mats], 0..) |mi, k| {
                // (tags are the object's, not theirs)
                saved_tags = tags_buf;
                tags_buf[0] = 0;
                const a = saveMat(mi);
                tags_buf = saved_tags;
                if (a.idx) |i| {
                    if (k < 8) deps[k] = tab[i].id;
                }
            }
            nmat = @min(nm_mats, 8);
            var b = Buf{};
            defer b.data.deinit(A);
            objBlob(&b, kind);
            if (!b.ok) return;
            const h = put(b.data.items);
            if (name_buf[0] == 0) setC(&name_buf, scene.objects[list[0]].name());
            got = add(kind, cstr(&name_buf), h);
        },
    }
    const i = got.idx orelse return;
    const r = &tab[i];
    app.log("  library: {s}{s} {s}", .{ if (got.new) "saved " else "already there: ", kinds[r.kind], r.nameOf() });
    app.dirty = true;
}

// --- placing ------------------------------------------------------------------------------------

/// lib.place <asset> [x y z]
fn opPlace() void {
    init();
    var w = nt.Words{ .s = ops.arg };
    const word = w.next();
    setC(&name_buf, word);
    const i = (if (word.len > 0) find(word) else null) orelse return app.log("  library: no asset named {s}", .{cstr(&name_buf)});
    place_at = scene.cursor;
    for (0..3) |c| {
        const x = w.next();
        if (x.len == 0) break;
        place_at[c] = nt.parseFloat(x, null) orelse break;
    }
    if (!placeAsset(i)) return;
    app.log("  library: placed {s}", .{tab[i].nameOf()});
}

/// lb_place_asset: it comes into the scene at place_at (its dependencies first).
pub fn placeAsset(i: u32) bool {
    const r = tab[i];
    for (r.deps[0..r.ndep]) |d| {
        const k = byId(d) orelse continue;
        if (tab[k].kind == K_MATERIAL and material.find(tab[k].nameOf()) != null) continue;
        _ = load(k, false);
    }
    return load(i, true);
}

pub fn placeAt(i: u32, at: m.V3) bool {
    place_at = at;
    return placeAsset(i);
}

/// lb_load: true when it came in (as asked for: a material on the selected
/// meshes, an action on the active object).
fn load(i: u32, asked: bool) bool {
    const r = &tab[i];
    const p = blobPath(r);
    if (r.kind == K_SCENE) return @import("files.zig").openUntitled(p);
    const f = readFile(p) orelse return false;
    defer f.deinit();
    const d = f.d;
    switch (r.kind) {
        K_OBJECT, K_RIG => return objLoad(d),
        K_ACTION => {
            const a = scene.active;
            const oid: u32 = if (a) |x| scene.objects[x].oid else 0;
            const uid: u32 = if (a) |x| scene.objects[x].uid else 0;
            const act = actionAdd(d, oid, uid);
            if (act == 0) return false;
            if (asked) {
                if (a) |x| {
                    var lb: [80]u8 = undefined;
                    const arg = std.fmt.bufPrint(&lb, "{s} {s}", .{ std.mem.sliceTo(d[0..32], 0), scene.objects[x].name() }) catch return true;
                    runOp("anim.layer", arg);
                }
            }
            return true;
        },
        else => {},
    }
    var mi: ?usize = null;
    if (r.kind == K_MATERIAL) {
        if (d.len < 16 + 32) return false;
        mi = material.find(std.mem.sliceTo(d[16..][0..32], 0));
    }
    if (mi == null) {
        const got = asset.blobLoad(d);
        if (got.kind == 0) return false;
        if (got.kind != 2) return true;
        mi = got.idx;
    }
    if (!asked) return true;
    for (scene.objects[0..scene.count]) |*o| {
        if (o.kind.isMesh() and o.selected) o.mat = @intCast(mi.? + 1);
    }
    material.version +%= 1;
    return true;
}

/// lb_run_op: an operator with its argument (as the original's run, no step of its own).
pub fn runOp(id: []const u8, arg: []const u8) void {
    const k = ops.byId(id) orelse return;
    const im = ops.impl_of[k] orelse return;
    const was = ops.arg;
    ops.arg = arg;
    defer ops.arg = was;
    im.run();
}

/// lb_obj_load: its objects at place_at, selected (the first active); rig
/// meshes bound to the armature.
fn objLoad(d: []const u8) bool {
    const bee = @import("bee.zig");
    if (d.len < 16 or std.mem.readInt(u32, d[0..4], .little) != LB_MAGIC) return false;
    var map: [255]?u16 = undefined;
    var nm: usize = 0;
    var obja: ?[]const u8 = null;
    var muvs: ?[]const u8 = null;
    var mvcl: ?[]const u8 = null;
    var armt: ?[]const u8 = null;
    var mwgt: ?[]const u8 = null;
    var o: usize = 16;
    while (o + 8 <= d.len) {
        const t = std.mem.readInt(u32, d[o..][0..4], .little);
        const size = std.mem.readInt(u32, d[o + 4 ..][0..4], .little);
        if (o + 8 + size > d.len) break;
        const c = d[o + 8 ..][0..size];
        o += 8 + size;
        if (t == T_MESH) {
            if (nm >= 255) continue;
            map[nm] = bee.readMesh(c) orelse break;
            nm += 1;
        } else if (t == T_OBJA) {
            obja = c;
        } else if (t == T_MUVS) {
            muvs = c;
        } else if (t == T_MVCL) {
            mvcl = c;
        } else if (t == T_ARMT) {
            armt = c;
        } else if (t == T_MWGT) {
            mwgt = c;
        }
    }
    if (muvs) |c| _ = bee.readUvs(c, map[0..nm]);
    if (mvcl) |c| @import("vcol.zig").readChunk(c, map[0..nm]);
    if (armt) |c| _ = @import("arm.zig").readArmt(c, map[0..nm]);
    if (mwgt) |c| _ = @import("arm.zig").readMwgt(c, map[0..nm]);
    const recs = obja orelse return false;
    scene.deselectAll();
    var newh: [255]usize = undefined;
    var placed: usize = 0;
    var ro: usize = 0;
    while (recs.len - ro >= OA_SZ and placed < 255) : (ro += OA_SZ) {
        const r = recs[ro..][0..OA_SZ];
        const mix = std.mem.readInt(u32, r[80..84], .little);
        if (mix >= nm) continue;
        if (scene.count >= scene.max_objects) continue;
        const typ = std.mem.readInt(u32, r[72..76], .little);
        var obj = scene.Object{ .kind = switch (typ) {
            1 => .light,
            2 => .camera,
            4 => .armature,
            3 => .sketch,
            5 => .field,
            else => .mesh,
        } };
        obj.setName(uniqueName(std.mem.sliceTo(r[0..31], 0)));
        var f: [10]f32 = undefined;
        for (&f, 0..) |*x, k| x.* = @bitCast(std.mem.readInt(u32, r[32 + k * 4 ..][0..4], .little));
        obj.loc = .{ f[0] + place_at[0], f[1] + place_at[1], f[2] + place_at[2] };
        obj.setRadians(.{ f[3], f[4], f[5] });
        obj.scl = .{ f[6], f[7], f[8] };
        obj.color = @as(u32, @bitCast(f[9])) & 0xffffff;
        const flags = std.mem.readInt(u32, r[76..80], .little) | 1;
        obj.selected = true;
        obj.visible = flags & 0x200 == 0;
        obj.locked = flags & 0x400 != 0;
        obj.render = flags & 0x800 == 0;
        obj.folded = flags & 0x1000 != 0;
        if (typ == 0) {
            obj.ref = flags & @import("refimg.zig").MASK;
            obj.gflags = flags & 0xe000;
        }
        obj.mesh = map[mix];
        if (obj.mesh == null) continue;
        var mn: [32]u8 = @splat(0);
        @memcpy(mn[0..31], r[84..115]);
        if (mn[0] != 0) {
            if (material.find(std.mem.sliceTo(&mn, 0))) |mi| obj.mat = @intCast(mi + 1);
        }
        const oi = scene.count;
        scene.objects[oi] = obj;
        scene.stamp(oi);
        scene.count += 1;
        newh[placed] = oi;
        placed += 1;
        const bound = std.mem.readInt(i32, r[116..120], .little);
        if (bound >= 0 and bound < placed) {
            const mods = @import("mods.zig");
            if (mods.add(oi, mods.ARMATURE)) |k| scene.objects[oi].mods.m[k].p[0] = scene.objects[newh[@intCast(bound)]].oid;
        }
    }
    if (placed == 0) return false;
    scene.active = newh[0];
    app.dirty = true;
    return true;
}

/// unique_name: "Base" (26 bytes at most), "Base.001", ...
fn uniqueName(base0: []const u8) []const u8 {
    const S = struct {
        var b: [32]u8 = undefined;
    };
    const base = base0[0..@min(base0.len, 26)];
    var k: u32 = 0;
    while (true) : (k += 1) {
        const s = if (k == 0) std.fmt.bufPrint(&S.b, "{s}", .{base}) catch base else std.fmt.bufPrint(&S.b, "{s}.{d:0>3}", .{ base, k }) catch base;
        if (k >= 999 or !taken(s)) return s;
    }
}
fn taken(s: []const u8) bool {
    for (scene.objects[0..scene.count]) |*o| if (std.mem.eql(u8, o.name(), s)) return true;
    return false;
}

// --- tags, removing, searching, dependencies, listing ------------------------------------------

/// lib.tag <asset> <tag> [-tag ...]
fn opTag() void {
    init();
    var w = nt.Words{ .s = ops.arg };
    const word = w.next();
    if (word.len == 0) return;
    const i = find(word) orelse return app.log("  library: no asset named {s}", .{word});
    tags_buf[0] = 0;
    while (true) {
        const x = w.next();
        if (x.len == 0) break;
        const tl = cstr(&tags_buf).len;
        if (tl >= 80) break;
        var at = tl;
        if (tl > 0) {
            tags_buf[at] = ',';
            at += 1;
        }
        const t = if (x[0] == '#') x[1..] else x;
        const k = @min(t.len, tags_buf.len - 1 - at);
        @memcpy(tags_buf[at..][0..k], t[0..k]);
        tags_buf[at + k] = 0;
    }
    tagsMerge(&tab[i]);
    writeIndex(tab[i].root);
    match();
    app.log("  tags: {s}", .{tab[i].tagsOf()});
}

/// lib.remove <asset>
fn opRemove() void {
    init();
    var w = nt.Words{ .s = ops.arg };
    const word = w.next();
    if (word.len == 0) return;
    const i = find(word) orelse return app.log("  library: no asset named {s}", .{word});
    removeAsset(i);
}

pub fn removeAsset(i: u32) void {
    const r = &tab[i];
    r.dead = true;
    const used = for (tab[0..n]) |*x| {
        if (!x.dead and x.blob == r.blob) break true;
    } else false;
    if (!used and mayWrite(blobPath(r))) unlink(blobPath(r));
    writeIndex(r.root);
    match();
    sel = -1;
    app.log("  library: removed {s}", .{r.nameOf()});
}

/// lib.search [words]
fn opSearch() void {
    init();
    setSearch(ops.arg);
    match();
    @import("extlib.zig").match(search());
    @import("extlib.zig").scroll = 0;
    sel = -1;
    app.log("  {d} found", .{hits});
}

/// deps_line: what it uses (users false) or what uses it, names comma-separated.
pub fn depsLine(i: u32, users: bool, out: []u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    const r = &tab[i];
    var c: u32 = 0;
    if (!users) {
        for (r.deps[0..r.ndep]) |d| {
            const k = byId(d) orelse continue;
            if (c > 0) w.writeAll(", ") catch {};
            w.writeAll(tab[k].nameOf()) catch {};
            c += 1;
        }
    } else {
        for (tab[0..n]) |*x| {
            if (x.dead) continue;
            const uses = std.mem.indexOfScalar(u64, x.deps[0..x.ndep], r.id) != null;
            if (!uses) continue;
            if (c > 0) w.writeAll(", ") catch {};
            w.writeAll(x.nameOf()) catch {};
            c += 1;
        }
    }
    if (c == 0) w.writeAll("-") catch {};
    return w.buffered();
}

/// lib.deps <asset>
fn opDeps() void {
    init();
    var w = nt.Words{ .s = ops.arg };
    const word = w.next();
    if (word.len == 0) return;
    const i = find(word) orelse return;
    var b: [512]u8 = undefined;
    app.log("  uses: {s}", .{depsLine(i, false, &b)});
    app.log("  used by: {s}", .{depsLine(i, true, &b)});
}

/// lib.list
fn opList() void {
    init();
    var c: u32 = 0;
    var lb: [512]u8 = undefined;
    for (tab[0..n]) |*r| {
        if (r.dead) continue;
        const l = lineOf(r, &lb);
        var t: [512]u8 = undefined;
        var k: usize = 0;
        for (l) |ch| {
            if (ch == 10) break;
            t[k] = if (ch == 9) ' ' else ch;
            k += 1;
        }
        app.log(" {s}", .{t[17..k]});
        c += 1;
    }
    app.log("  {d} assets in {d} libraries", .{ c, nroot });
}

/// lib.add <folder>
fn opAddRoot() void {
    init();
    var w = nt.Words{ .s = ops.arg };
    const word = w.next();
    if (word.len == 0 or nroot >= ROOTS) return;
    var eb: [600]u8 = undefined;
    const p = expand(word, &eb);
    const k = @min(p.len, 511);
    @memcpy(roots[nroot][0..k], p[0..k]);
    root_len[nroot] = k;
    nroot += 1;
    readIndex(nroot - 1);
    match();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(A);
    for (1..nroot) |r| {
        out.appendSlice(A, roots[r][0..root_len[r]]) catch return;
        out.append(A, 10) catch return;
    }
    _ = writeFile(pathx(0, "/libraries.txt", null, ""), out.items);
    opList();
}

// --- packs ------------------------------------------------------------------------------------------

/// lib.pack <path> [search words]: the matching assets and what they use; each blob once.
fn opPack() void {
    init();
    var w = nt.Words{ .s = ops.arg };
    const word = w.next();
    if (word.len == 0) return;
    var eb: [600]u8 = undefined;
    var pb: [600]u8 = undefined;
    const ep = expand(word, &eb);
    const p = pb[0..ep.len];
    @memcpy(p, ep);
    setSearch(std.mem.trimStart(u8, w.rest(), " "));
    match();
    for (tab[0..n]) |*r| {
        if (r.hit != 1) continue;
        for (r.deps[0..r.ndep]) |d| {
            const k = byId(d) orelse continue;
            if (tab[k].hit == 0) tab[k].hit = 2;
        }
    }
    var b = Buf{};
    defer b.data.deinit(A);
    b.u32_(BEE_MAGIC);
    b.u32_(1);
    var st = b.begin(T_LIBM);
    var na: u32 = 0;
    var lb: [512]u8 = undefined;
    for (tab[0..n]) |*r| {
        if (r.hit == 0) continue;
        b.bytes(lineOf(r, &lb));
        na += 1;
    }
    b.end(st);
    var nb: u32 = 0;
    for (tab[0..n], 0..) |*r, i| {
        if (r.hit == 0) continue;
        const dup = for (tab[0..i]) |*x| {
            if (x.hit != 0 and x.blob == r.blob) break true;
        } else false;
        if (!dup) blob: {
            const f = readFile(blobPath(r)) orelse break :blob;
            defer f.deinit();
            st = b.begin(T_LIBB);
            b.u32_(@truncate(r.blob));
            b.u32_(@truncate(r.blob >> 32));
            b.bytes(f.d);
            b.end(st);
            nb += 1;
        }
        const f = readFile(pathx(r.root, "/thumbs", r.id, ".png")) orelse continue;
        defer f.deinit();
        st = b.begin(T_LIBT);
        b.u32_(@truncate(r.id));
        b.u32_(@truncate(r.id >> 32));
        b.bytes(f.d);
        b.end(st);
    }
    if (b.ok and writeFile(p, b.data.items)) {
        app.log("  pack written: {d} assets, {d} blobs", .{ na, nb });
    } else app.log("  library: could not write {s}", .{p});
    search_len = 0;
    match();
}

/// lib.import <path>: its blobs (checked against their hash) and thumbnails
/// into the first library, its manifest's new assets.
fn opImport() void {
    init();
    var w = nt.Words{ .s = ops.arg };
    const word = w.next();
    if (word.len == 0) return;
    var eb: [600]u8 = undefined;
    var pb: [600]u8 = undefined;
    const ep = expand(word, &eb);
    const p = pb[0..ep.len];
    @memcpy(p, ep);
    const f = readFile(p) orelse return app.log("  not an asset pack: {s}", .{p});
    defer f.deinit();
    const d = f.d;
    if (d.len < 8 or std.mem.readInt(u32, d[0..4], .little) != BEE_MAGIC) return app.log("  not an asset pack: {s}", .{p});
    var n_new: u32 = 0;
    var n_blobs: u32 = 0;
    var n_in: u32 = 0;
    var o: usize = 8;
    while (o + 8 <= d.len) {
        const t = std.mem.readInt(u32, d[o..][0..4], .little);
        const size = std.mem.readInt(u32, d[o + 4 ..][0..4], .little);
        if (o + 8 + size > d.len) break;
        const c = d[o + 8 ..][0..size];
        o += 8 + size;
        if (t == T_LIBB) {
            if (size < 8) continue;
            const h = hash(c[8..], 0);
            if (h != std.mem.readInt(u64, c[0..8], .little)) continue;
            if (exists(pathx(0, "/blobs", h, ".bee"))) continue;
            _ = put(c[8..]);
            n_blobs += 1;
        } else if (t == T_LIBT) {
            if (size < 8) continue;
            const id = std.mem.readInt(u64, c[0..8], .little);
            const dir = pathx(0, "/thumbs", null, "");
            if (mayWrite(dir)) _ = spawn.ensureDir(dir);
            const tp = pathx(0, "/thumbs", id, ".png");
            if (exists(tp)) continue;
            _ = writeFile(tp, c[8..]);
        } else if (t == T_LIBM) {
            var i: usize = 0;
            var line: [511]u8 = undefined;
            while (i < c.len) {
                var k: usize = 0;
                while (i < c.len) {
                    const ch = c[i];
                    i += 1;
                    if (ch == 10) break;
                    if (k < 510) {
                        line[k] = ch;
                        k += 1;
                    }
                }
                if (k == 0) continue;
                line[k] = 0;
                n_in += 1;
                const was = n;
                parseLine(0, line[0 .. k + 1]);
                if (n != was) n_new += 1;
            }
        }
    }
    writeIndex(0);
    for (tab[0..n]) |*r| {
        if (r.thumb != 0) continue;
        r.thumb = if (exists(pathx(r.root, "/thumbs", r.id, ".png"))) 2 else 0;
    }
    match();
    app.log("  pack imported: {d} assets, {d} new, {d} blobs", .{ n_in, n_new, n_blobs });
}

// --- thumbnails, browser: libui.zig ------------------------------------------------------------

pub fn thumbPath(r: *const Rec) []const u8 {
    return pathx(r.root, "/thumbs", r.id, ".png");
}
pub fn thumbDir(r: *const Rec) []const u8 {
    return pathx(r.root, "/thumbs", null, "");
}
pub fn rootOf(r: *const Rec) []const u8 {
    return roots[r.root][0..root_len[r.root]];
}

const Impl = ops.Impl;
pub const list_ops = .{
    .{ "lib.save", Impl{ .run = opSave } },
    .{ "lib.place", Impl{ .run = opPlace } },
    .{ "lib.tag", Impl{ .run = opTag } },
    .{ "lib.remove", Impl{ .run = opRemove } },
    .{ "lib.search", Impl{ .run = opSearch } },
    .{ "lib.deps", Impl{ .run = opDeps } },
    .{ "lib.pack", Impl{ .run = opPack } },
    .{ "lib.import", Impl{ .run = opImport } },
    .{ "lib.add", Impl{ .run = opAddRoot } },
    .{ "lib.list", Impl{ .run = opList } },
};

// --- tests ------------------------------------------------------------------------------------

test "lb_hash, hex, the index line both ways, tags" {
    try std.testing.expectEqual(hash("", 0), hash("", 0));
    // FNV-like 8 bytes a step (tests/library.py's lbhash)
    var hx: [16]u8 = undefined;
    try std.testing.expectEqualStrings("00000000000000ff", hex16(0xff, &hx));
    var i: usize = 0;
    try std.testing.expectEqual(@as(?u64, 0xABCDEF0123456789), unhex16("abcdef0123456789\t", &i));
    try std.testing.expectEqual(@as(usize, 16), i);
    i = 0;
    try std.testing.expectEqual(@as(?u64, null), unhex16("abcdefg123456789", &i));
    n = 0;
    nroot = 1;
    root_len[0] = 0;
    parseLine(0, "00000000000000a1\tobject\tGate\t00000000000000b2\t0000000000000001,0000000000000002\tstone,metal\x00");
    parseLine(0, "00000000000000a1\tobject\tDup\t00000000000000b2\t-\t-\x00"); // (the same id: once)
    parseLine(0, "00000000000000a3\tbogus\tX\t00000000000000b2\t-\t-\x00"); // (no such kind)
    parseLine(0, "00000000000000a4\tmaterial\tGold\t00000000000000b3\t-\t-\x00");
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expectEqual(@as(u32, 2), tab[0].ndep);
    try std.testing.expectEqualStrings("stone,metal", tab[0].tagsOf());
    try std.testing.expectEqualStrings("", tab[1].tagsOf());
    var lb: [512]u8 = undefined;
    try std.testing.expectEqualStrings("00000000000000a1\tobject\tGate\t00000000000000b2\t0000000000000001,0000000000000002\tstone,metal\n", lineOf(&tab[0], &lb));
    try std.testing.expectEqualStrings("00000000000000a4\tmaterial\tGold\t00000000000000b3\t-\t-\n", lineOf(&tab[1], &lb));
    setC(&tags_buf, "heavy,-stone,metal,-nope");
    tagsMerge(&tab[0]);
    try std.testing.expectEqualStrings("metal,heavy", tab[0].tagsOf());
    setC(&tags_buf, "-heavy");
    tagsMerge(&tab[0]);
    try std.testing.expectEqualStrings("metal", tab[0].tagsOf());
    setC(&tags_buf, "-metal");
    tagsMerge(&tab[0]);
    try std.testing.expectEqualStrings("", tab[0].tagsOf());
    // search: every word, any case, in the name, kind or tags
    setSearch("GA obj");
    match();
    try std.testing.expectEqual(@as(u32, 1), hits);
    setSearch("material gold ");
    match();
    try std.testing.expectEqual(@as(u32, 1), tab[1].hit);
    try std.testing.expectEqual(@as(?u32, 1), find("Gold"));
    try std.testing.expectEqual(@as(?u32, 0), find("00000000000000a1"));
    n = 0;
    nroot = 0;
    search_len = 0;
}

pub fn isReady() bool {
    return ready;
}
