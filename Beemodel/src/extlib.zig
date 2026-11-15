// Online model libraries ("sources", extlib.s) beside the local content
// library: browse, search and place their assets.
//
// A source has a kind, an id, a title, where it lives and its licence: NVIDIA
// SimReady (a Hugging Face dataset, CC-BY 4.0), SimReady Central (a GitHub
// index of other datasets), Poly Haven (its API, CC0); ~/BeeModel/sources.txt
// adds more, a line each ("simready <id> <owner/dataset> <title ...>",
// "central <id> <github owner/repo> <title ...>").
//
// Everything a source gives is kept under ~/BeeModel/cache/<id>/: catalog.tsv
// (name TAB root TAB category; central, Poly Haven: TAB dataset TAB commit TAB
// folder TAB licence TAB thumbnail TAB tags), thumbs/<name>.png, bom/<name>.json
// (Poly Haven: its /files/<id> answer), assets/<name>/... The catalog is made
// once (lib.refresh again); thumbnails come when the browser shows their
// tile, an asset's files when it is placed (lib.get).
//
// Work runs in up to four curl children, reaped by tick from the main loop;
// headless (tests) each operation runs to its end. BEEMODEL_HF_URL replaces
// https://huggingface.co, BEEMODEL_GH_URL GitHub's API and raw files,
// BEEMODEL_PH_URL https://api.polyhaven.com (tests serve fixtures).
//
// Not in the port yet: SimReady Central's catalog (its index, datasets and
// packages), and the last step of lib.get, the USD import (file.import_usd is
// not ported): the files are fetched and kept, then the console says so.
const std = @import("std");
const linux = std.os.linux;
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const lib = @import("library.zig");
const spawn = @import("spawn.zig");
const nt = @import("ntree.zig");
const Rect = gfx.Rect;
const A = std.heap.page_allocator;

const MAXSRC = 8;
const MAX = 8192;
const SLOTS = 4;
const FILES = 8192;
const BATCH = 250;
const TH = lib.TH;
const TILE_W = 112;
const TILE_H = 126;

pub const EK_SIMREADY = 1;
pub const EK_CENTRAL = 2;
pub const EK_POLYHAVEN = 3;

const Src = struct {
    id: [24]u8 = @splat(0),
    title: [64]u8 = @splat(0),
    repo: [96]u8 = @splat(0),
    kind: u32 = 0,
    lic: [48]u8 = @splat(0),
};

pub const Ex = struct {
    name: [64]u8 = @splat(0),
    root: [128]u8 = @splat(0),
    cat: [32]u8 = @splat(0),
    /// 0 not asked, 1 wanted, 2 coming, 3 here, 4 none
    thumb: u32 = 0,
    /// files: 0 not here, 1 coming, 2 here
    have: u32 = 0,
    px: ?[]u32 = null,
    hit: u32 = 1,
    /// its package's file list: 0 not asked, 1 coming, 2 here, 3 none
    bom: u32 = 0,
    repo: [64]u8 = @splat(0),
    rev: [48]u8 = @splat(0),
    lic: [24]u8 = @splat(0),
    folder: [64]u8 = @splat(0),
    thp: [128]u8 = @splat(0),
    tags: [128]u8 = @splat(0),
};

const SW = enum(u8) { none, tree, info, thumb, list, file, ghtree, dsinfo, dsidx, bom, phcat };

const Slot = struct {
    pid: i32 = 0,
    what: SW = .none,
    idx: u32 = 0,
    stat: i32 = 0,
    out: [1024]u8 = @splat(0),
    hdr: [1024]u8 = @splat(0),
    url: [2048]u8 = @splat(0),
};

const Ef = struct {
    path: [256]u8 = @splat(0),
    size: u64 = 0,
    /// 0 to get, 1 coming, 2 here, 3 failed
    state: u32 = 0,
    url: [256]u8 = @splat(0),
};

var src: [MAXSRC]Src = @splat(.{});
pub var nsrc: u32 = 0;
var inited = false;
/// The source the Asset Browser shows (-1: the local library).
pub var cur: i32 = -1;
/// The browser's rows scrolled (an online source's tiles).
pub var scroll: i32 = 0;
var tab: []Ex = &.{};
pub var n: u32 = 0;
var loaded: u32 = 0; // its source + 1
/// the catalog: 0 here / none, 1 pages, 2 roots, 3 failed
pub var state: u32 = 0;
var batch: u32 = 0;
var catbusy = false;
var lbusy = false;
var slots: [SLOTS]Slot = @splat(.{});
var files: []Ef = &.{};
var nf: u32 = 0;
var fasset: i32 = -1;
/// 0 none, 1 listing, 2 files, 3 failed, 4 its package's list
var fstate: u32 = 0;
var fdone: u64 = 0;
var fall: u64 = 0;
var place = false;
var ppos: [3]f32 = .{ 0, 0, 0 };
var static_ = false;
var nosave = false;
var base: [256]u8 = @splat(0);
var gh: [256]u8 = @splat(0);
var ghraw: [256]u8 = @splat(0);
var ph: [256]u8 = @splat(0);
const ua = "BeeModel/zig";
var curl: [512]u8 = @splat(0);
var nexturl: [2048]u8 = @splat(0);

fn cstr(b: []const u8) []const u8 {
    return std.mem.sliceTo(b, 0);
}
fn setN(dst: []u8, s: []const u8, most: usize) void {
    const k = @min(@min(s.len, most), dst.len - 1);
    @memcpy(dst[0..k], s[0..k]);
    dst[k] = 0;
}

/// Headless runs (tests): each operation runs to its end (ex_sync).
fn syncRun() bool {
    return @import("files.zig").headless;
}

// --- sources --------------------------------------------------------------------------------

fn srcSet(s: *Src, id: []const u8, title: []const u8, repo: []const u8) void {
    s.* = .{};
    setN(&s.id, id, 23);
    setN(&s.title, title, 63);
    setN(&s.repo, repo, 95);
    s.kind = EK_SIMREADY;
    setN(&s.lic, "CC-BY 4.0", 47);
}
fn srcCentral(s: *Src) void {
    s.kind = EK_CENTRAL;
    setN(&s.lic, "per dataset", 47);
}

fn envOr(dst: []u8, name: []const u8, def: []const u8) void {
    const v = spawn.getenv(name) orelse "";
    setN(dst, if (v.len > 0) v else def, dst.len - 1);
}

/// ex_init: the sources (SimReady, Central, Poly Haven, then sources.txt's), the URLs.
pub fn init() void {
    if (inited) return;
    inited = true;
    fasset = -1;
    srcSet(&src[0], "simready", "NVIDIA SimReady", "nvidia/simready-assets");
    srcSet(&src[1], "central", "SimReady Central", "NVIDIA-Omniverse/simready-central");
    srcCentral(&src[1]);
    srcSet(&src[2], "polyhaven", "Poly Haven", "api.polyhaven.com");
    src[2].kind = EK_POLYHAVEN;
    setN(&src[2].lic, "CC0", 47);
    nsrc = 3;
    envOr(&ph, "BEEMODEL_PH_URL", "https://api.polyhaven.com");
    envOr(&gh, "BEEMODEL_GH_URL", "https://api.github.com");
    envOr(&ghraw, "BEEMODEL_GH_URL", "https://raw.githubusercontent.com");
    envOr(&base, "BEEMODEL_HF_URL", "https://huggingface.co");
    var pb: [600]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/BeeModel/sources.txt", .{lib.home()}) catch return;
    const d = @import("ttf.zig").mapFile(p) orelse return;
    defer _ = linux.munmap(d.ptr, d.len);
    sourcesParse(d);
}

/// ex_lword: the next word of the line (spaces skipped; # starts a comment).
fn lword(d: []const u8, i: *usize, out: []u8, most: usize) void {
    var k: usize = 0;
    while (i.* < d.len and (d[i.*] == ' ' or d[i.*] == 9)) i.* += 1;
    if (i.* < d.len and d[i.*] != 10 and d[i.*] != '#') {
        while (i.* < d.len) : (i.* += 1) {
            const c = d[i.*];
            if (c == ' ' or c == 9 or c == 10) break;
            if (c == 13) continue;
            if (k < most) {
                out[k] = c;
                k += 1;
            }
        }
    }
    out[k] = 0;
}

fn sourcesParse(d: []const u8) void {
    var i: usize = 0;
    while (i < d.len and nsrc < MAXSRC) {
        var kw: [24]u8 = undefined;
        var id: [24]u8 = undefined;
        var repo: [96]u8 = undefined;
        lword(d, &i, &kw, 23);
        lword(d, &i, &id, 23);
        lword(d, &i, &repo, 95);
        const t0 = i;
        while (i < d.len and d[i] != 10) i += 1;
        const t1 = i;
        i += 1;
        const k = cstr(&kw);
        const kind: u32 = if (std.mem.eql(u8, k, "central")) EK_CENTRAL else if (std.mem.eql(u8, k, "simready")) EK_SIMREADY else continue;
        if (id[0] == 0 or repo[0] == 0) continue;
        var title: [40]u8 = undefined;
        var tl: usize = 0;
        for (d[t0..t1]) |c| {
            if (c == 13) continue;
            if (tl < 39) {
                title[tl] = c;
                tl += 1;
            }
        }
        const s = &src[nsrc];
        srcSet(s, cstr(&id), if (tl > 0) title[0..tl] else cstr(&id), cstr(&repo));
        if (kind == EK_CENTRAL) srcCentral(s);
        nsrc += 1;
    }
}

pub fn srcTitle(k: u32) []const u8 {
    return cstr(&src[k].title);
}
fn kindNow() u32 {
    return if (cur >= 0) src[@intCast(cur)].kind else 0;
}

var dir_buf: [1024]u8 = undefined;
/// ex_srcdir: ~/BeeModel/cache/<id> (made).
fn srcDir() []const u8 {
    const d = std.fmt.bufPrint(&dir_buf, "{s}/BeeModel/cache/{s}", .{ lib.home(), cstr(&src[@intCast(cur)].id) }) catch "";
    if (lib.mayWrite(d)) _ = spawn.ensureDir(d);
    return d;
}
fn inDir(out: []u8, more: []const u8) []const u8 {
    return std.fmt.bufPrint(out, "{s}{s}", .{ srcDir(), more }) catch "";
}
/// ex_fdirs: the folders a file is in, made.
fn fdirs(p: []const u8) void {
    const s = std.mem.lastIndexOfScalar(u8, p, '/') orelse return;
    if (lib.mayWrite(p[0..s])) _ = spawn.ensureDir(p[0..s]);
}

fn existsFile(p: []const u8) ?usize {
    var zb: [2049]u8 = undefined;
    if (p.len >= zb.len) return null;
    @memcpy(zb[0..p.len], p);
    zb[p.len] = 0;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, @ptrCast(&zb), 0, .{ .SIZE = true }, &st)) != .SUCCESS) return null;
    return st.size;
}

fn writeFile(p: []const u8, d: []const u8) bool {
    if (!lib.mayWrite(p)) return false;
    @import("bee.zig").writeAtomic(p, d) catch return false;
    return true;
}

fn rename(from: []const u8, to: []const u8) void {
    var a: [2049]u8 = undefined;
    var b: [2049]u8 = undefined;
    if (from.len >= a.len or to.len >= b.len or !lib.mayWrite(to)) return;
    @memcpy(a[0..from.len], from);
    a[from.len] = 0;
    @memcpy(b[0..to.len], to);
    b[to.len] = 0;
    _ = linux.rename(@ptrCast(&a), @ptrCast(&b));
}

// --- the catalog ---------------------------------------------------------------------------

pub fn rec(k: u32) *Ex {
    return &tab[k];
}
pub fn nameOf(k: u32) []const u8 {
    return if (k < n) cstr(&tab[k].name) else "";
}

fn alloc() bool {
    if (tab.len > 0) return true;
    tab = A.alloc(Ex, MAX) catch return false;
    return true;
}

fn freePx() void {
    for (tab[0..n]) |*r| {
        if (r.px) |p| A.free(p);
        r.px = null;
    }
}

/// ex_add: a new asset (null: full), its category from the name's first word.
fn add(name: []const u8) ?*Ex {
    if (n >= MAX) return null;
    const r = &tab[n];
    r.* = .{};
    setN(&r.name, name, 63);
    var k: usize = 0;
    while (k < 31 and r.name[k] != 0 and r.name[k] != '_') : (k += 1) r.cat[k] = r.name[k];
    r.cat[k] = 0;
    r.hit = 1;
    n += 1;
    return r;
}

fn find(name: []const u8) ?u32 {
    for (tab[0..n], 0..) |*r, k| {
        if (std.mem.eql(u8, cstr(&r.name), name)) return @intCast(k);
    }
    return null;
}

/// ex_field: up to a TAB or the line's end (CRs dropped).
fn field(d: []const u8, i: *usize, out: []u8, most: usize) void {
    var k: usize = 0;
    while (i.* < d.len) {
        const c = d[i.*];
        if (c == 10) break;
        i.* += 1;
        if (c == 9) break;
        if (c == 13) continue;
        if (k < most) {
            out[k] = c;
            k += 1;
        }
    }
    out[k] = 0;
}

/// ex_load: the current source's catalog.tsv read (false: there is none).
fn load() bool {
    if (!alloc()) return false;
    freePx();
    n = 0;
    var pb: [1100]u8 = undefined;
    const d = @import("ttf.zig").mapFile(inDir(&pb, "/catalog.tsv")) orelse return false;
    defer _ = linux.munmap(d.ptr, d.len);
    var i: usize = 0;
    while (i < d.len) {
        var w: [64]u8 = undefined;
        field(d, &i, &w, 63);
        if (w[0] != 0) {
            const r = add(cstr(&w)) orelse break;
            field(d, &i, &r.root, 127);
            var c: [32]u8 = undefined;
            field(d, &i, &c, 31);
            if (c[0] != 0) setN(&r.cat, cstr(&c), 31);
            field(d, &i, &r.repo, 63);
            field(d, &i, &r.rev, 47);
            field(d, &i, &r.folder, 63);
            field(d, &i, &r.lic, 23);
            field(d, &i, &r.thp, 127);
            field(d, &i, &r.tags, 127);
        }
        while (i < d.len) {
            const ch = d[i];
            i += 1;
            if (ch == 10) break;
        }
    }
    haveScan();
    return true;
}

/// ex_have_scan: each asset whose files are in the cache (its .complete
/// marker), each thumbnail there.
fn haveScan() void {
    var pb: [1100]u8 = undefined;
    for (tab[0..n]) |*r| {
        if (r.root[0] != 0) {
            const p = std.fmt.bufPrint(&pb, "{s}/assets/{s}/.complete", .{ srcDir(), cstr(&r.name) }) catch continue;
            if ((existsFile(p) orelse 0) > 0) r.have = 2;
        }
        const t = std.fmt.bufPrint(&pb, "{s}/thumbs/{s}.png", .{ srcDir(), cstr(&r.name) }) catch continue;
        if ((existsFile(t) orelse 0) > 0) r.thumb = 3;
    }
}

/// ex_save: catalog.tsv from the table.
fn save() void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(A);
    const more = kindNow() >= EK_CENTRAL;
    for (tab[0..n]) |*r| {
        out.appendSlice(A, cstr(&r.name)) catch return;
        out.append(A, 9) catch return;
        out.appendSlice(A, cstr(&r.root)) catch return;
        out.append(A, 9) catch return;
        out.appendSlice(A, cstr(&r.cat)) catch return;
        if (more) {
            for ([_][]const u8{ &r.repo, &r.rev, &r.folder, &r.lic, &r.thp, &r.tags }) |f| {
                out.append(A, 9) catch return;
                out.appendSlice(A, cstr(f)) catch return;
            }
        }
        out.append(A, 10) catch return;
    }
    var pb: [1100]u8 = undefined;
    _ = writeFile(inDir(&pb, "/catalog.tsv"), out.items);
}

/// ex_match: hit on the assets whose name, category, dataset and tags have
/// every word (any case); all when there are none.
pub fn match(s: []const u8) void {
    for (tab[0..n]) |*r| {
        r.hit = 1;
        if (s.len == 0) continue;
        var b: [400]u8 = undefined;
        const t = std.fmt.bufPrint(&b, "{s} {s} {s} {s}", .{ cstr(&r.name), cstr(&r.cat), cstr(&r.repo), cstr(&r.tags) }) catch continue;
        r.hit = @intFromBool(wordsIn(t, s));
    }
}

/// ex_words_in: each space-separated word is in the text, any case (|0x20).
fn wordsIn(text: []const u8, words: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, words, ' ');
    while (it.next()) |w| {
        var found = false;
        var t: usize = 0;
        while (t < text.len and !found) : (t += 1) {
            var c: usize = 0;
            while (c < w.len and t + c < text.len and (text[t + c] | 0x20) == (w[c] | 0x20)) c += 1;
            if (c == w.len) found = true;
        }
        if (!found) return false;
    }
    return true;
}

fn catReport() void {
    app.log("  catalog: {d} assets in {s}", .{ n, srcTitle(@intCast(cur)) });
}

// --- JSON (json.s: a scanner over the text, as the original reads it) -------------------------

const J = struct {
    d: []const u8,
    fn ws(j: *const J, p0: usize) usize {
        var i = p0;
        while (i < j.d.len and (j.d[i] == ' ' or j.d[i] == 9 or j.d[i] == 10 or j.d[i] == 13)) i += 1;
        return i;
    }
    fn at(j: *const J, i: usize) u8 {
        return if (i < j.d.len) j.d[i] else 0;
    }
    /// j_skip: just past the value.
    fn skip(j: *const J, p0: usize) usize {
        var i = j.ws(p0);
        var depth: u32 = 0;
        while (i < j.d.len) {
            const c = j.d[i];
            if (c == '"') {
                i += 1;
                while (i < j.d.len) {
                    const x = j.d[i];
                    i += 1;
                    if (x == '\\') {
                        i += 1;
                        continue;
                    }
                    if (x == '"') break;
                }
                if (depth == 0) return i;
                continue;
            }
            if (c == '{' or c == '[') {
                depth += 1;
                i += 1;
                continue;
            }
            if (c == '}' or c == ']') {
                if (depth == 0) return i;
                depth -= 1;
                i += 1;
                if (depth == 0) return i;
                continue;
            }
            if (depth == 0 and (c == ',' or c == ' ' or c == 10 or c == 13 or c == 9)) return i;
            i += 1;
        }
        return i;
    }
    /// j_find: the value of the key in the object at i, null.
    fn find(j: *const J, p0: usize, key: []const u8) ?usize {
        var i = j.ws(p0);
        if (j.at(i) != '{') return null;
        i += 1;
        while (true) {
            i = j.ws(i);
            if (j.at(i) != '"') return null;
            const k0 = i + 1;
            if (k0 + key.len < j.d.len and std.mem.eql(u8, j.d[k0..][0..key.len], key) and j.at(k0 + key.len) == '"') {
                i = j.ws(k0 + key.len + 1);
                if (j.at(i) != ':') return null;
                return j.ws(i + 1);
            }
            i = j.ws(j.skip(i));
            if (j.at(i) != ':') return null;
            i = j.ws(j.skip(i + 1));
            if (j.at(i) != ',') return null;
            i += 1;
        }
    }
    /// j_str: the string value unescaped into out (room - 1 bytes), its length, null.
    fn str(j: *const J, p0: usize, out: []u8) ?usize {
        var i = j.ws(p0);
        if (j.at(i) != '"') return null;
        i += 1;
        var k: usize = 0;
        const room = out.len - 1;
        while (i < j.d.len) {
            var c = j.d[i];
            i += 1;
            if (c == '"') break;
            if (c == '\\') {
                c = j.at(i);
                i += 1;
                switch (c) {
                    'n' => c = 10,
                    't' => c = 9,
                    'r' => c = 13,
                    'b' => c = 8,
                    'f' => c = 12,
                    'u' => {
                        var v: u32 = 0;
                        for (0..4) |_| {
                            const h = j.at(i);
                            i += 1;
                            const dg: u32 = if (h >= '0' and h <= '9') h - '0' else ((h | 0x20) -% ('a' - 10));
                            v = v << 4 | (dg & 0xff);
                        }
                        var u8b: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(@intCast(@min(v, 0xffff)), &u8b) catch 1;
                        if (k + len > room) break;
                        @memcpy(out[k..][0..len], u8b[0..len]);
                        k += len;
                        continue;
                    },
                    else => {},
                }
            }
            if (k < room) {
                out[k] = c;
                k += 1;
            }
        }
        out[k] = 0;
        return k;
    }
    fn num(j: *const J, i: usize) ?f64 {
        const s = j.d[j.ws(i)..];
        var e: usize = 0;
        while (e < s.len and (std.ascii.isDigit(s[e]) or s[e] == '.' or s[e] == '-' or s[e] == '+' or s[e] == 'e' or s[e] == 'E')) e += 1;
        return std.fmt.parseFloat(f64, s[0..e]) catch null;
    }
    fn first(j: *const J, p0: usize) ?usize {
        var i = j.ws(p0);
        if (j.at(i) != '[') return null;
        i = j.ws(i + 1);
        if (j.at(i) == ']' or i >= j.d.len) return null;
        return i;
    }
    fn next(j: *const J, p0: usize) ?usize {
        var i = j.ws(j.skip(p0));
        if (j.at(i) != ',') return null;
        i = j.ws(i + 1);
        return i;
    }
    /// ex_jo_first: an object's first key.
    fn oFirst(j: *const J, p0: usize) ?usize {
        var i = j.ws(p0);
        if (j.at(i) != '{') return null;
        i = j.ws(i + 1);
        if (j.at(i) != '"') return null;
        return i;
    }
    fn oVal(j: *const J, key: usize) ?usize {
        var i = j.ws(j.skip(key));
        if (j.at(i) != ':') return null;
        i = j.ws(i + 1);
        return i;
    }
    fn oNext(j: *const J, key: usize) ?usize {
        const v = j.oVal(key) orelse return null;
        var i = j.ws(j.skip(v));
        if (j.at(i) != ',') return null;
        i = j.ws(i + 1);
        if (j.at(i) != '"') return null;
        return i;
    }
};

const Mapped = struct {
    d: []const u8,
    fn deinit(x: Mapped) void {
        _ = linux.munmap(@constCast(x.d.ptr), x.d.len);
    }
};
fn jread(p: []const u8) ?Mapped {
    const d = @import("ttf.zig").mapFile(p) orelse return null;
    return .{ .d = d };
}

// --- children (curl) --------------------------------------------------------------------------

fn freeSlot() ?u32 {
    for (slots, 0..) |s, k| {
        if (s.pid == 0) return @intCast(k);
    }
    return null;
}

pub fn busy() u32 {
    var c: u32 = 0;
    for (slots) |s| c += @intFromBool(s.pid != 0);
    return c;
}

const How = enum { plain, headers, post };

/// ex_spawn: curl -sSfL -m 600 --retry 2 -o out -A ua [-D hdr | -H form --data-binary @file] url.
fn spawnCurl(k: u32, how: How) bool {
    const s = &slots[k];
    if (curl[0] == 0) {
        var wb: [512]u8 = undefined;
        const w = spawn.which(&wb, "curl") orelse return false;
        setN(&curl, w, 511);
    }
    var argv: [20:null]?[*:0]const u8 = @splat(null);
    const fixed = [_][*:0]const u8{ @ptrCast(&curl), "-sSfL", "-m", "600", "--retry", "2", "-o", @ptrCast(&s.out), "-A", ua };
    for (fixed, 0..) |a, j| argv[j] = a;
    var at: usize = fixed.len;
    switch (how) {
        .headers => {
            argv[at] = "-D";
            argv[at + 1] = @ptrCast(&s.hdr);
            at += 2;
        },
        .post => {
            argv[at] = "-H";
            argv[at + 1] = "Content-Type: application/x-www-form-urlencoded";
            argv[at + 2] = "--data-binary";
            argv[at + 3] = @ptrCast(&s.hdr);
            at += 4;
        },
        .plain => {},
    }
    argv[at] = @ptrCast(&s.url);
    const pid = spawn.spawn(@ptrCast(&curl), &argv, spawn.NULL, spawn.NULL, spawn.NULL) orelse return false;
    if (pid <= 0) return false;
    s.pid = pid;
    return true;
}

/// ex_tick: children reaped, the next work started (the main loop's turn).
pub fn tick() void {
    if (!inited) return;
    for (&slots) |*s| {
        if (s.pid == 0) continue;
        var st: i32 = 0;
        const r = linux.wait4(s.pid, &st, 1, null);
        if (linux.errno(r) == .SUCCESS and r == 0) continue;
        s.pid = 0;
        const u: u32 = @bitCast(st);
        s.stat = if (u & 0x7f == 0) @intCast((u >> 8) & 0xff) else -1;
        done(s);
        app.dirty = true;
    }
    start();
}

/// ex_kill: every child stopped.
pub fn kill() void {
    for (&slots) |*s| {
        if (s.pid == 0) continue;
        _ = linux.kill(s.pid, .KILL);
        var st: i32 = 0;
        _ = linux.wait4(s.pid, &st, 0, null);
        s.pid = 0;
    }
}

/// ex_run: (headless) the tick until nothing is running or waiting.
fn run() void {
    while (true) {
        tick();
        if (busy() == 0) return;
        var ts = linux.timespec{ .sec = 0, .nsec = 20_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
}

/// ex_start: free slots get work: the catalog's next step first, then the
/// asset's files, then thumbnails asked for.
fn start() void {
    while (freeSlot()) |k| {
        if (catNext(k)) continue;
        if (fileNext(k)) continue;
        if (thumbNext(k)) continue;
        return;
    }
}

fn done(s: *Slot) void {
    switch (s.what) {
        .tree => treeDone(s),
        .info => infoDone(s),
        .thumb => thumbDone(s),
        .list => listDone(s),
        .file => fileDone(s),
        .bom => bomDone(s),
        .phcat => phcatDone(s),
        else => {},
    }
}

fn noCurl() void {
    app.log("  online libraries need curl (not found on the PATH)", .{});
}

// --- catalog building: SimReady (a Hugging Face dataset's folders) ---------------------------

/// ex_refresh: the current source's catalog made again.
fn refresh() void {
    if (!alloc()) return;
    freePx();
    n = 0;
    state = 1;
    batch = 0;
    _ = std.fmt.bufPrintSentinel(&nexturl, "{s}/api/datasets/{s}/tree/main", .{ cstr(&base), cstr(&src[@intCast(cur)].repo) }, 0) catch {};
}

fn catNext(k: u32) bool {
    if (state != 1 and state != 2) return false;
    switch (kindNow()) {
        EK_POLYHAVEN => {
            if (state != 1 or catbusy) return false;
            return phcatStart(k);
        },
        EK_CENTRAL => {
            state = 3;
            app.log("  SimReady Central's catalog: not available yet", .{});
            return false;
        },
        else => {
            if (catbusy) return false;
            return if (state == 1) treeStart(k) else infoStart(k);
        },
    }
}

fn treeStart(k: u32) bool {
    const s = &slots[k];
    s.what = .tree;
    setN(&s.url, cstr(&nexturl), 2047);
    var pb: [1100]u8 = undefined;
    setN(&s.out, inDir(&pb, "/page.json"), 1023);
    setN(&s.hdr, inDir(&pb, "/page.hdr"), 1023);
    if (!spawnCurl(k, .headers)) {
        state = 3;
        noCurl();
        return false;
    }
    catbusy = true;
    return true;
}

fn treeDone(s: *Slot) void {
    catbusy = false;
    const f = if (s.stat == 0) jread(cstr(&s.out)) else null;
    const m = f orelse {
        state = 3;
        app.log("  the catalog could not be fetched (offline?): {s}", .{cstr(&s.url)});
        return;
    };
    {
        defer m.deinit();
        const j = J{ .d = m.d };
        var el = j.first(0);
        while (el) |e| : (el = j.next(e)) {
            var w: [65]u8 = undefined;
            const tv = j.find(e, "type") orelse continue;
            _ = j.str(tv, &w);
            if (!std.mem.eql(u8, cstr(&w), "directory")) continue;
            const pv = j.find(e, "path") orelse continue;
            const len = j.str(pv, &w) orelse continue;
            if (len == 0 or w[0] == '.') continue;
            _ = add(cstr(&w));
        }
    }
    if (nextLink(cstr(&s.hdr))) return;
    state = 2;
    batch = 0;
}

/// ex_nextlink: nexturl = the <URL> before rel="next" in the headers file.
fn nextLink(p: []const u8) bool {
    const m = jread(p) orelse return false;
    defer m.deinit();
    const at = std.mem.indexOf(u8, m.d, "rel=\"next\"") orelse return false;
    const lt = std.mem.lastIndexOfScalar(u8, m.d[0..at], '<') orelse return false;
    const gt = std.mem.indexOfScalarPos(u8, m.d, lt + 1, '>') orelse return false;
    if (gt - lt - 1 > 2000) return false;
    setN(&nexturl, m.d[lt + 1 .. gt], 2000);
    return true;
}

/// ex_info_start: which root the next 250 assets have (paths-info for
/// simready_usd/sm_<name>_01.usd and .usda).
fn infoStart(k: u32) bool {
    const first = batch * BATCH;
    if (first >= n) {
        state = 0;
        save();
        haveScan();
        catReport();
        return false;
    }
    const s = &slots[k];
    s.what = .info;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(A);
    body.appendSlice(A, "expand=false") catch return false;
    var i = first;
    while (i < n and i < first + BATCH) : (i += 1) {
        const nm = cstr(&tab[i].name);
        for ([_][]const u8{ "_01.usd", "_01.usda" }) |sfx| {
            body.print(A, "&paths={s}/simready_usd/sm_{s}{s}", .{ nm, nm, sfx }) catch return false;
        }
    }
    var pb: [1100]u8 = undefined;
    const p2 = inDir(&pb, "/info.txt");
    _ = writeFile(p2, body.items);
    _ = std.fmt.bufPrintSentinel(&s.hdr, "@{s}", .{p2}, 0) catch return false;
    setN(&s.out, inDir(&pb, "/info.json"), 1023);
    _ = std.fmt.bufPrintSentinel(&s.url, "{s}/api/datasets/{s}/paths-info/main", .{ cstr(&base), cstr(&src[@intCast(cur)].repo) }, 0) catch return false;
    if (!spawnCurl(k, .post)) {
        state = 3;
        return false;
    }
    catbusy = true;
    return true;
}

fn infoDone(s: *Slot) void {
    catbusy = false;
    const m = (if (s.stat == 0) jread(cstr(&s.out)) else null) orelse {
        state = 3;
        app.log("  the catalog could not be fetched (offline?): {s}", .{cstr(&s.url)});
        return;
    };
    defer m.deinit();
    const j = J{ .d = m.d };
    var el = j.first(0);
    while (el) |e| : (el = j.next(e)) {
        var p: [256]u8 = undefined;
        const pv = j.find(e, "path") orelse continue;
        const len = j.str(pv, &p) orelse continue;
        if (len == 0) continue;
        const slash = std.mem.indexOfScalar(u8, p[0..len], '/') orelse continue;
        if (slash > 63) continue;
        const k = find(p[0..slash]) orelse continue;
        if (tab[k].root[0] != 0) continue; // (.usd first: kept)
        setN(&tab[k].root, p[0..len], 127);
    }
    batch += 1;
}

// --- catalog building: Poly Haven (its API) -----------------------------------------------------

fn phcatStart(k: u32) bool {
    const s = &slots[k];
    s.what = .phcat;
    _ = std.fmt.bufPrintSentinel(&s.url, "{s}/assets?t=models", .{cstr(&ph)}, 0) catch return false;
    var pb: [1100]u8 = undefined;
    setN(&s.out, inDir(&pb, "/assets.json"), 1023);
    if (!spawnCurl(k, .plain)) {
        state = 3;
        noCurl();
        return false;
    }
    catbusy = true;
    return true;
}

/// ex_tag_add: a word appended to its tags (a space between; 127 bytes at most).
fn tagAdd(r: *Ex, j: *const J, v: usize) void {
    var w: [128]u8 = undefined;
    const len = j.str(v, &w) orelse return;
    if (len == 0) return;
    var l = cstr(&r.tags).len;
    if (l >= 125) return;
    if (l > 0) {
        r.tags[l] = ' ';
        l += 1;
    }
    for (w[0..len]) |c| {
        if (l >= 127) break;
        r.tags[l] = c;
        l += 1;
    }
    r.tags[l] = 0;
}

fn phcatDone(s: *Slot) void {
    catbusy = false;
    const m = (if (s.stat == 0) jread(cstr(&s.out)) else null) orelse {
        state = 3;
        app.log("  the catalog could not be fetched (offline?): {s}", .{cstr(&s.url)});
        return;
    };
    {
        defer m.deinit();
        const j = J{ .d = m.d };
        var key = j.oFirst(0);
        while (key) |ky| : (key = j.oNext(ky)) {
            var w: [65]u8 = undefined;
            const len = j.str(ky, &w) orelse continue;
            if (len == 0) continue;
            const r = add(cstr(&w)) orelse break;
            r.cat[0] = 0;
            const v = j.oVal(ky) orelse continue;
            if (j.find(v, "categories")) |cs| {
                if (j.first(cs)) |c0| {
                    _ = j.str(c0, &r.cat);
                    var c = j.next(c0);
                    while (c) |cc| : (c = j.next(cc)) tagAdd(r, &j, cc);
                }
            }
            if (j.find(v, "tags")) |ts| {
                var t = j.first(ts);
                while (t) |tt| : (t = j.next(tt)) tagAdd(r, &j, tt);
            }
            const tu = j.find(v, "thumbnail_url") orelse continue;
            var b: [512]u8 = undefined;
            const tl = j.str(tu, &b) orelse continue;
            if (tl == 0) continue;
            const q = std.mem.indexOfScalar(u8, b[0..tl], '?') orelse tl;
            if (q >= 127) r.thp[0] = 0 else setN(&r.thp, b[0..q], 127);
        }
    }
    state = 0;
    save();
    haveScan();
    catReport();
}

// --- thumbnails ----------------------------------------------------------------------------------

/// ex_thumb: its tile's pixels (null until here); asked for the first time.
pub fn thumb(k: u32) ?[]u32 {
    const r = &tab[k];
    if (r.px) |p| return p;
    if (r.thumb == 0) {
        r.thumb = 1;
        return null;
    }
    if (r.thumb != 3) return null;
    var pb: [1100]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/thumbs/{s}.png", .{ srcDir(), cstr(&r.name) }) catch return null;
    r.px = @import("libui.zig").thumbLoad(p);
    if (r.px == null) r.thumb = 4;
    return r.px;
}

fn basename(p: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |s| p[s + 1 ..] else p;
}

fn thumbNext(k: u32) bool {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const r = &tab[i];
        if (r.thumb != 1) continue;
        const kd = kindNow();
        if (kd == EK_CENTRAL) {
            r.thumb = 4;
            continue;
        }
        if (kd == EK_POLYHAVEN and r.thp[0] == 0 or kd != EK_POLYHAVEN and r.root[0] == 0) {
            r.thumb = 4;
            continue;
        }
        const s = &slots[k];
        s.what = .thumb;
        s.idx = i;
        if (kd == EK_POLYHAVEN) {
            _ = std.fmt.bufPrintSentinel(&s.url, "{s}?width=256&height=256&format=png", .{cstr(&r.thp)}, 0) catch continue;
        } else {
            _ = std.fmt.bufPrintSentinel(&s.url, "{s}/datasets/{s}/resolve/main/{s}/simready_usd/.thumbs/256x256/{s}.png", .{ cstr(&base), cstr(&src[@intCast(cur)].repo), cstr(&r.name), basename(cstr(&r.root)) }, 0) catch continue;
        }
        _ = std.fmt.bufPrintSentinel(&s.out, "{s}/thumbs/{s}.png.part", .{ srcDir(), cstr(&r.name) }, 0) catch continue;
        fdirs(cstr(&s.out));
        if (!spawnCurl(k, .plain)) {
            r.thumb = 4;
            return false;
        }
        r.thumb = 2;
        return true;
    }
    return false;
}

fn thumbDone(s: *Slot) void {
    if (s.idx >= n) return;
    const r = &tab[s.idx];
    r.thumb = 4;
    if (s.stat != 0) return;
    const o = cstr(&s.out);
    rename(o, o[0 .. o.len - 5]);
    r.thumb = 3;
}

// --- an asset's files -----------------------------------------------------------------------------

/// ex_get: its files fetched (those not here yet), then placed.
fn get(k: u32, place_it: bool) void {
    place = place_it;
    ppos = scene.cursor;
    const r = &tab[k];
    if (r.have == 2) {
        if (place_it) import(k);
        return;
    }
    if (fstate != 0 and fstate != 3) return; // (one asset at a time)
    fasset = @intCast(k);
    r.have = 1;
    fstate = 1;
    nf = 0;
    fdone = 0;
    fall = 0;
    if (files.len == 0) files = A.alloc(Ef, FILES) catch {
        fstate = 3;
        return;
    };
    if (kindNow() >= EK_CENTRAL) {
        fstate = 4;
        return;
    }
    _ = std.fmt.bufPrintSentinel(&nexturl, "{s}/api/datasets/{s}/tree/main/{s}?recursive=true", .{ cstr(&base), cstr(&src[@intCast(cur)].repo), cstr(&r.name) }, 0) catch {};
    lbusy = false;
}

fn fileNext(k: u32) bool {
    switch (fstate) {
        4 => {
            const r = &tab[@intCast(fasset)];
            if (kindNow() == EK_CENTRAL) {
                fstate = 3;
                fassetFail();
                return false;
            }
            switch (bomReady(r)) {
                2 => {
                    if (r.root[0] == 0) {
                        app.log("  no USD root in the asset's package: {s}", .{cstr(&r.name)});
                        r.have = 0;
                        fasset = -1;
                        fstate = 3;
                        return false;
                    }
                    if (!phFiles(r)) {
                        r.bom = 0;
                        fstate = 3;
                        fassetFail();
                        return false;
                    }
                    fstate = 2;
                    filesCheck();
                    if (fstate == 2) return fileOne(k);
                    return false;
                },
                1 => return false,
                3 => {
                    r.bom = 0;
                    fstate = 3;
                    fassetFail();
                    return false;
                },
                else => {
                    if (bomStart(k, r)) return true;
                    r.bom = 0;
                    fstate = 3;
                    fassetFail();
                    return false;
                },
            }
        },
        1 => {
            if (lbusy) return false;
            const s = &slots[k];
            s.what = .list;
            setN(&s.url, cstr(&nexturl), 2047);
            var pb: [1100]u8 = undefined;
            setN(&s.out, inDir(&pb, "/list.json"), 1023);
            setN(&s.hdr, inDir(&pb, "/list.hdr"), 1023);
            if (!spawnCurl(k, .headers)) {
                fstate = 3;
                return false;
            }
            lbusy = true;
            return true;
        },
        2 => return fileOne(k),
        else => return false,
    }
}

/// The next file not asked for.
fn fileOne(k: u32) bool {
    var i: u32 = 0;
    while (i < nf) : (i += 1) {
        const f = &files[i];
        if (f.state != 0) continue;
        f.state = 1;
        const s = &slots[k];
        s.what = .file;
        s.idx = i;
        if (kindNow() == EK_POLYHAVEN) {
            setN(&s.url, cstr(&f.url), 2047);
        } else {
            _ = std.fmt.bufPrintSentinel(&s.url, "{s}/datasets/{s}/resolve/main/{s}", .{ cstr(&base), cstr(&src[@intCast(cur)].repo), cstr(&f.path) }, 0) catch return false;
        }
        _ = std.fmt.bufPrintSentinel(&s.out, "{s}/assets/{s}.part", .{ srcDir(), cstr(&f.path) }, 0) catch return false;
        fdirs(cstr(&s.out));
        if (!spawnCurl(k, .plain)) {
            fstate = 3;
            return false;
        }
        return true;
    }
    return false;
}

/// ex_keep: an import needs it (under <name>/simready_usd/, not
/// source_assets/, .thumbs/ or an .mdl).
fn keep(p: []const u8) bool {
    if (std.mem.indexOf(u8, p, "/simready_usd/") == null) return false;
    for ([_][]const u8{ "/source_assets/", "/.thumbs/", ".mdl" }) |x| {
        if (std.mem.indexOf(u8, p, x) != null) return false;
    }
    return true;
}

/// ex_here: assets/<path> is there at that size.
fn here(p: []const u8, size: u64) bool {
    var pb: [1400]u8 = undefined;
    const q = std.fmt.bufPrint(&pb, "{s}/assets/{s}", .{ srcDir(), p }) catch return false;
    const got = existsFile(q) orelse return false;
    return got == size and size > 0;
}

fn addFile(path: []const u8, url: []const u8, size: u64) void {
    if (nf >= FILES) return;
    const f = &files[nf];
    f.* = .{};
    setN(&f.path, path, 255);
    setN(&f.url, url, 255);
    f.size = size;
    fall += size;
    if (here(cstr(&f.path), size)) {
        f.state = 2;
        fdone += size;
    }
    nf += 1;
}

fn listDone(s: *Slot) void {
    lbusy = false;
    const m = (if (s.stat == 0) jread(cstr(&s.out)) else null) orelse {
        fstate = 3;
        fassetFail();
        return;
    };
    {
        defer m.deinit();
        const j = J{ .d = m.d };
        var el = j.first(0);
        while (el) |e| : (el = j.next(e)) {
            var w: [65]u8 = undefined;
            const tv = j.find(e, "type") orelse continue;
            _ = j.str(tv, &w);
            if (!std.mem.eql(u8, cstr(&w), "file")) continue;
            var p: [256]u8 = undefined;
            const pv = j.find(e, "path") orelse continue;
            const len = j.str(pv, &p) orelse continue;
            if (len == 0 or !keep(p[0..len])) continue;
            const size: u64 = if (j.find(e, "size")) |sv| (if (j.num(sv)) |x| @intFromFloat(@max(x, 0)) else 0) else 0;
            addFile(p[0..len], "", size);
        }
    }
    if (nextLink(cstr(&s.hdr))) return;
    fstate = 2;
    filesCheck();
}

fn fileDone(s: *Slot) void {
    if (s.idx >= nf) return;
    const f = &files[s.idx];
    f.state = 3;
    if (s.stat == 0) {
        const o = cstr(&s.out);
        rename(o, o[0 .. o.len - 5]);
        f.state = 2;
        fdone += f.size;
    }
    filesCheck();
}

/// ex_files_check: every file here: the asset is (and placed when asked);
/// one failed and none coming: it is not.
fn filesCheck() void {
    var failed: u32 = 0;
    for (files[0..nf]) |*f| {
        if (f.state < 2) return;
        if (f.state == 3) failed += 1;
    }
    if (failed > 0) {
        fstate = 3;
        fassetFail();
        return;
    }
    fstate = 0;
    const k: u32 = @intCast(fasset);
    fasset = -1;
    const r = &tab[k];
    r.have = 2;
    var pb: [1100]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/assets/{s}/.complete", .{ srcDir(), cstr(&r.name) }) catch return;
    fdirs(p);
    _ = writeFile(p, "/"); // (the marker: the first byte of "/.complete", as the original writes it)
    if (place) import(k);
}

fn fassetFail() void {
    if (fasset < 0) return;
    const r = &tab[@intCast(fasset)];
    r.have = 0;
    app.log("  the asset's files could not all be fetched: {s}", .{cstr(&r.name)});
    fasset = -1;
}

/// ex_import: its USD imported, placed at ppos (static: no rigid bodies or
/// joints), saved into the local library (unless nosave), its credit.
fn import(k: u32) void {
    const r = &tab[k];
    const usd = @import("usd.zig");
    var pb: [1200]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/assets/{s}", .{ srcDir(), cstr(&r.root) }) catch return;
    usd.off = .{ ppos[0], ppos[1], ppos[2] }; // at the 3D cursor
    const before = scene.count; // (its objects: those after these)
    usd.nophys = static_;
    const jobui = @import("jobui.zig");
    jobui.begin("Placing the downloaded asset"); // the import: a job's chip while it reads
    _ = usd.import(p);
    jobui.end();
    usd.nophys = false;
    if (!nosave) toLibrary(before, r); // into the local library too
    usd.off = .{ 0, 0, 0 };
    // "  placed <name> - <title>, CC-BY 4.0" (central: " (<dataset>)")
    const lic = if (r.lic[0] != 0) cstr(&r.lic) else cstr(&src[@intCast(cur)].lic);
    if (r.repo[0] != 0) {
        app.log("  placed {s} - {s} ({s}), {s}", .{ cstr(&r.name), srcTitle(@intCast(cur)), cstr(&r.repo), lic });
    } else app.log("  placed {s} - {s}, {s}", .{ cstr(&r.name), srcTitle(@intCast(cur)), lic });
    app.dirty = true;
}

/// ex_to_library: the objects the import made, selected, saved as an object
/// asset: lib.save object <name> #<source> #<category> (the same content is
/// kept once)
fn toLibrary(before: usize, r: *const Ex) void {
    if (before >= scene.count) return;
    for (scene.objects[0..scene.count]) |*o| o.selected = false;
    for (scene.objects[before..scene.count]) |*o| o.selected = true;
    var b: [256]u8 = undefined;
    const w = std.fmt.bufPrint(&b, "object {s} #{s} #{s}", .{ cstr(&r.name), cstr(&src[@intCast(cur)].id), cstr(&r.cat) }) catch return;
    lib.runOp("lib.save", w);
}

// --- Poly Haven: an asset's /files/<id> --------------------------------------------------------

fn bomPath(r: *const Ex, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "{s}/bom/{s}.json", .{ srcDir(), cstr(&r.name) }) catch "";
}

fn bomStart(k: u32, r: *Ex) bool {
    const s = &slots[k];
    s.what = .bom;
    s.idx = @intCast((@intFromPtr(r) - @intFromPtr(tab.ptr)) / @sizeOf(Ex));
    _ = std.fmt.bufPrintSentinel(&s.url, "{s}/files/{s}", .{ cstr(&ph), cstr(&r.name) }, 0) catch return false;
    var pb: [1100]u8 = undefined;
    _ = std.fmt.bufPrintSentinel(&s.out, "{s}.part", .{bomPath(r, &pb)}, 0) catch return false;
    fdirs(cstr(&s.out));
    if (!spawnCurl(k, .plain)) {
        r.bom = 3;
        return false;
    }
    r.bom = 1;
    return true;
}

fn bomDone(s: *Slot) void {
    if (s.idx >= n) return;
    const r = &tab[s.idx];
    r.bom = 3;
    if (s.stat != 0) return;
    const o = cstr(&s.out);
    rename(o, o[0 .. o.len - 5]);
    if (!phParse(r)) return;
    r.bom = 2;
    if (state == 0) save();
}

fn bomReady(r: *Ex) u32 {
    if (r.bom != 0) return r.bom;
    var pb: [1100]u8 = undefined;
    if ((existsFile(bomPath(r, &pb)) orelse 0) == 0) return 0;
    r.bom = if (phParse(r)) 2 else 3;
    return r.bom;
}

var res: [4]u8 = @splat(0);

/// ex_ph_usd: usd.<res>.usd (1k first, else 2k, 4k, 8k): its object.
fn phUsd(j: *const J) ?usize {
    const u = j.find(0, "usd") orelse return null;
    for ([_][]const u8{ "1k", "2k", "4k", "8k" }) |rz| {
        const rv = j.find(u, rz) orelse continue;
        const o = j.find(rv, "usd") orelse continue;
        _ = j.find(o, "url") orelse continue;
        setN(&res, rz, 3);
        return o;
    }
    return null;
}

/// ex_ph_safe: it stays in the asset's folder.
fn phSafe(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, p, '\\') != null) return false;
    return std.mem.indexOf(u8, p, "..") == null;
}

fn phParse(r: *Ex) bool {
    var pb: [1100]u8 = undefined;
    const m = jread(bomPath(r, &pb)) orelse return false;
    defer m.deinit();
    r.root[0] = 0;
    const j = J{ .d = m.d };
    const o = phUsd(&j) orelse return true;
    const uv = j.find(o, "url") orelse return true;
    var b: [512]u8 = undefined;
    const len = j.str(uv, &b) orelse return true;
    if (len == 0) return true;
    const bn = basename(b[0..len]);
    if (!phSafe(bn)) return true;
    var rb: [200]u8 = undefined;
    setN(&r.root, std.fmt.bufPrint(&rb, "{s}/{s}", .{ cstr(&r.name), bn }) catch return true, 127);
    return true;
}

fn phSize(j: *const J, o: usize) u64 {
    const sv = j.find(o, "size") orelse return 0;
    const x = j.num(sv) orelse return 0;
    return @intFromFloat(@max(x, 0));
}

/// ex_ph_files: its .usdc and the include map's textures (an EXR: its map's JPEG).
fn phFiles(r: *Ex) bool {
    var pb: [1100]u8 = undefined;
    const m = jread(bomPath(r, &pb)) orelse return false;
    defer m.deinit();
    const j = J{ .d = m.d };
    const o = phUsd(&j) orelse return false;
    const uv = j.find(o, "url") orelse return false;
    var url: [256]u8 = undefined;
    const ul = j.str(uv, &url) orelse return false;
    if (ul == 0) return false;
    var path: [400]u8 = undefined;
    phAdd(r, basename(url[0..ul]), url[0..ul], phSize(&j, o), &path);
    const inc = j.find(o, "include") orelse return true;
    var key = j.oFirst(inc);
    while (key) |ky| : (key = j.oNext(ky)) {
        var p: [201]u8 = undefined;
        const pl = j.str(ky, &p) orelse continue;
        if (pl == 0) continue;
        const v = j.oVal(ky) orelse continue;
        const iu = j.find(v, "url") orelse continue;
        var u: [256]u8 = undefined;
        const il = j.str(iu, &u) orelse continue;
        if (il == 0) continue;
        var size = phSize(&j, v);
        var name = p[0..pl];
        var url2: []const u8 = u[0..il];
        var jb: [256]u8 = undefined;
        var nb: [204]u8 = undefined;
        if (std.mem.endsWith(u8, name, ".exr")) {
            if (phJpg(&j, u[0..il], &jb)) |x| {
                size = x.size;
                url2 = x.url;
                @memcpy(nb[0..name.len], name);
                @memcpy(nb[name.len - 4 ..][0..4], ".jpg");
                name = nb[0..name.len];
            }
        }
        phAdd(r, name, url2, size, &path);
    }
    return true;
}

const Jpg = struct { url: []const u8, size: u64 };

/// ex_ph_jpg: the JPEG of the same map and resolution as this EXR's URL.
fn phJpg(j: *const J, exr: []const u8, out: *[256]u8) ?Jpg {
    var key = j.oFirst(0);
    while (key) |ky| : (key = j.oNext(ky)) {
        const v = j.oVal(ky) orelse continue;
        const rv = j.find(v, cstr(&res)) orelse continue;
        const e = j.find(rv, "exr") orelse continue;
        const eu = j.find(e, "url") orelse continue;
        var b: [256]u8 = undefined;
        const bl = j.str(eu, &b) orelse continue;
        if (bl == 0 or !std.mem.eql(u8, b[0..bl], exr)) continue;
        const jp = j.find(rv, "jpg") orelse continue;
        const ju = j.find(jp, "url") orelse continue;
        const jl = j.str(ju, out) orelse continue;
        if (jl == 0) continue;
        return .{ .url = out[0..jl], .size = phSize(j, jp) };
    }
    return null;
}

/// ex_ph_addfile: <name>/<path>; a path that would leave the folder not taken.
fn phAdd(r: *const Ex, p: []const u8, url: []const u8, size: u64, buf: *[400]u8) void {
    if (!phSafe(p)) return;
    const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ cstr(&r.name), p[0..@min(p.len, 190)] }) catch return;
    addFile(full, url, size);
}

// --- the browser's online tiles (library.s ed_assets_draw) ---------------------------------------

pub fn wheel(w: f32) void {
    if (cur < 0) return;
    var s = scroll + (if (w > 0) @as(i32, 1) else -1);
    s = std.math.clamp(s, 0, @as(i32, @intCast(n)));
    scroll = s;
    app.dirty = true;
}

/// ex_progress: the download's progress, 0 .. 96.
fn progress() i32 {
    if (fall == 0) return 0;
    return @intCast(@min(fdone * 96 / fall, 96));
}

pub fn drawTiles(r: Rect, fit: u32, idx: []u32, shown: *u32, hover: ?u32, x0: i32, y0: i32, cols: i32, hdr_x: *i32) void {
    const cv = ui.cv;
    const th = ui.th;
    if (state == 1 or state == 2 or (state == 3 and n == 0)) {
        _ = cv.text(r.x + 8, y0 + 4, if (state == 3) "The catalog could not be fetched (offline?): lib.refresh tries again" else "Fetching the catalog...", th.text_dim);
        return;
    }
    const skip: u32 = @intCast(scroll * cols);
    var hits: u32 = 0;
    var t: u32 = 0;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const e = &tab[k];
        if (e.hit == 0) continue;
        hits += 1;
        if (hits <= skip or t >= fit) continue;
        idx[t] = k;
        const ti: i32 = @intCast(t);
        const tx = x0 + @mod(ti, cols) * TILE_W;
        const ty = y0 + @divTrunc(ti, cols) * TILE_H;
        if (@import("library.zig").sel == k) {
            cv.fill(.{ .x = tx - 3, .y = ty - 3, .w = TH + 6, .h = TH + 6 }, th.accent);
        } else if (hover != null and hover.? == t) {
            cv.fill(.{ .x = tx - 3, .y = ty - 3, .w = TH + 6, .h = TH + 6 }, th.hover);
        }
        if (thumb(k)) |px| {
            @import("libui.zig").blit(tx, ty, px);
        } else {
            cv.fill(.{ .x = tx, .y = ty, .w = TH, .h = TH }, 0x2a2e36);
            _ = cv.textFit(tx + 8, ty + TH / 2 - 8, TH - 16, cstr(&e.cat), th.text_dim);
        }
        if (e.have == 2) {
            cv.fill(.{ .x = tx + TH - 12, .y = ty + 4, .w = 8, .h = 8 }, 0x4caf50);
        } else if (e.have == 1) {
            cv.fill(.{ .x = tx, .y = ty + TH - 6, .w = TH, .h = 6 }, 0x1d2027);
            const p = progress();
            if (p > 0) cv.fill(.{ .x = tx, .y = ty + TH - 6, .w = p, .h = 6 }, th.accent);
        }
        // its name after the category ("bowl_c01" of bowl_c01... when its name starts "<category>_")
        var nm = cstr(&e.name);
        const c = cstr(&e.cat);
        if (c.len > 0 and nm.len > c.len + 1 and std.mem.startsWith(u8, nm, c) and nm[c.len] == '_') nm = nm[c.len + 1 ..];
        _ = cv.textFit(tx, ty + TH + 4, TILE_W - 8, nm, th.text);
        ui.record("tile", cstr(&e.name), .{ .x = tx, .y = ty, .w = TH, .h = TH }, true);
        t += 1;
    }
    shown.* = t;
    const more: i64 = @as(i64, hits) - skip - t;
    if (more > 0) {
        var b: [80]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "{d} more (scroll, or search to narrow)", .{more}) catch "";
        const room = r.x + r.w - 8 - hdr_x.*;
        if (room >= 24) hdr_x.* += cv.textFit(hdr_x.*, r.y + 4, room, s, th.text_dim) + 24;
    }
    // the selected one: name, category, here or not; its source, licence
    const sl = @import("library.zig").sel;
    if (sl < 0 or sl >= n) return;
    const e = &tab[@intCast(sl)];
    const y = r.y + r.h - 54;
    var b: [256]u8 = undefined;
    _ = cv.text(r.x + 8, y, std.fmt.bufPrint(&b, "{s}   {s}{s}", .{ cstr(&e.name), cstr(&e.cat), if (e.have == 2) "  - downloaded" else "  - not downloaded yet" }) catch "", th.text);
    const ttl = if (e.repo[0] != 0) cstr(&e.repo) else srcTitle(@intCast(cur));
    const lic = if (e.lic[0] != 0) cstr(&e.lic) else cstr(&src[@intCast(cur)].lic);
    _ = cv.text(r.x + 8, y + 18, std.fmt.bufPrint(&b, "{s}   {s}", .{ ttl, lic }) catch "", th.text_dim);
}

/// ex_chip: the status bar's text while a source is at work, null.
pub fn chip(out: []u8) ?[]const u8 {
    if (state == 1 or state == 2) return "Fetching the catalog...";
    if ((fstate == 1 or fstate == 2 or fstate == 4) and fasset >= 0) {
        const nm = cstr(&tab[@intCast(fasset)].name);
        if (fall == 0) return std.fmt.bufPrint(out, "Downloading {s} ", .{nm}) catch null;
        return std.fmt.bufPrint(out, "Downloading {s} {d}%", .{ nm, fdone * 100 / fall }) catch null;
    }
    return null;
}

// --- the operators ----------------------------------------------------------------------------------

/// lib.sources
fn opSources() void {
    init();
    app.log("  sources (lib.source <id>):", .{});
    app.log("    local", .{});
    for (src[0..nsrc]) |*s| app.log("    {s} - {s}", .{ cstr(&s.id), cstr(&s.title) });
}

/// lib.source <id | local>
fn opSource() void {
    init();
    var w = nt.Words{ .s = ops.arg };
    const word = w.next();
    if (word.len == 0) return opSources();
    sourceTo(word);
}

fn sourceTo(word: []const u8) void {
    defer app.dirty = true;
    if (std.mem.eql(u8, word, "local")) {
        cur = -1;
        return;
    }
    const k: u32 = for (src[0..nsrc], 0..) |*s, i| {
        if (std.mem.eql(u8, cstr(&s.id), word)) break @intCast(i);
    } else return app.log("  no such library source: {s}", .{word});
    if (loaded == k + 1 and cur == k) return;
    cur = @intCast(k);
    scroll = 0;
    loaded = k + 1;
    if (load()) return catReport();
    refresh();
    tick();
    if (syncRun()) run();
}

/// lib.source_next: the local library, then each online source, round.
fn opSourceNext() void {
    init();
    const nx = cur + 1;
    if (nx >= nsrc) {
        cur = -1;
        app.dirty = true;
        return;
    }
    sourceTo(cstr(&src[@intCast(nx)].id));
}

/// lib.refresh
fn opRefresh() void {
    init();
    if (cur < 0) return;
    refresh();
    tick();
    if (syncRun()) run();
}

/// lib.get <asset> [x y z] [static] [nosave]
fn opGet() void {
    init();
    if (cur < 0) return app.log("  lib.get <asset> (in the current source; lib.source <id> first)", .{});
    var w = nt.Words{ .s = ops.arg };
    const word = w.next();
    if (word.len == 0) return app.log("  lib.get <asset> (in the current source; lib.source <id> first)", .{});
    const k = find(word) orelse return app.log("  no such asset in this source: {s}", .{word});
    const rest = w.rest();
    // x y z (else the cursor)
    var xyz: [3]f32 = undefined;
    var wv = nt.Words{ .s = rest };
    var c: usize = 0;
    while (c < 3) : (c += 1) {
        const x = wv.next();
        if (x.len == 0) break;
        xyz[c] = nt.parseFloat(x, null) orelse break;
    }
    if (c == 3) scene.cursor = xyz;
    static_ = false;
    nosave = false;
    var wf = nt.Words{ .s = rest };
    while (true) {
        const x = wf.next();
        if (x.len == 0) break;
        if (std.mem.eql(u8, x, "static")) static_ = true;
        if (std.mem.eql(u8, x, "nosave")) nosave = true;
    }
    get(k, true);
    tick();
    if (syncRun()) run();
}

/// lib.stop: the downloads stopped (files fetched so far are kept).
fn opStop() void {
    kill();
    catbusy = false;
    lbusy = false;
    if (state != 0) state = 3;
    if (fstate != 0) {
        fstate = 3;
        fassetFail();
    }
    for (tab[0..n]) |*r| {
        if (r.bom == 1) r.bom = 0;
    }
    app.dirty = true;
}

const Impl = ops.Impl;
pub const list_ops = .{
    .{ "lib.sources", Impl{ .run = opSources } },
    .{ "lib.source", Impl{ .run = opSource } },
    .{ "lib.source_next", Impl{ .run = opSourceNext } },
    .{ "lib.refresh", Impl{ .run = opRefresh } },
    .{ "lib.get", Impl{ .run = opGet } },
    .{ "lib.stop", Impl{ .run = opStop } },
};

// --- tests --------------------------------------------------------------------------------------------

test "json scanner as json.s: objects, arrays, strings, skipping" {
    const j = J{ .d = "{\"a\": [1, {\"x\": \"y\"}, \"q\\\"\\u00e9\"], \"b\" : {\"c\": 2.5}, \"d\": \"e\"}" };
    const a = j.find(0, "a").?;
    var el = j.first(a);
    try std.testing.expect(el != null);
    el = j.next(el.?);
    var b: [32]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 1), j.str(j.find(el.?, "x").?, &b));
    el = j.next(el.?);
    const len = j.str(el.?, &b).?;
    try std.testing.expectEqualStrings("q\"\xc3\xa9", b[0..len]);
    try std.testing.expectEqual(@as(?f64, 2.5), j.num(j.find(j.find(0, "b").?, "c").?));
    _ = j.str(j.find(0, "d").?, &b);
    try std.testing.expectEqualStrings("e", std.mem.sliceTo(&b, 0));
    try std.testing.expectEqual(@as(?usize, null), j.find(0, "zz"));
    var key = j.oFirst(0);
    var keys: u32 = 0;
    while (key) |ky| : (key = j.oNext(ky)) keys += 1;
    try std.testing.expectEqual(@as(u32, 3), keys);
}

test "search words, the sources' file, safe paths" {
    try std.testing.expect(wordsIn("crate_a01 crate  wood box", "CRATE wo"));
    try std.testing.expect(!wordsIn("crate_a01 crate  ", "crate x"));
    try std.testing.expect(wordsIn("anything", "   "));
    nsrc = 3;
    sourcesParse("# a comment\nsimready mine acme/props My own props\r\ncentral c2 org/index\nbogus x y z\nsimready only\n");
    try std.testing.expectEqual(@as(u32, 5), nsrc);
    // (the original keeps the space before the title: its copy starts after the repo word)
    try std.testing.expectEqualStrings(" My own props", cstr(&src[3].title));
    try std.testing.expectEqual(@as(u32, EK_CENTRAL), src[4].kind);
    try std.testing.expectEqualStrings("c2", cstr(&src[4].title));
    try std.testing.expect(phSafe("a/b.usdc") and !phSafe("../x") and !phSafe("/etc/x") and !phSafe("a\\b") and !phSafe(""));
    try std.testing.expect(keep("crate/simready_usd/a.usd") and !keep("crate/simready_usd/.thumbs/a.png") and !keep("crate/x.usd"));
}
