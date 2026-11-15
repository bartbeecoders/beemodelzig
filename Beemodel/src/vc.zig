//! Versioned scenes (the original's vc.s): commits, branches, a visual diff,
//! merging. A saved scene keeps its history beside it, in "<file>.vc/":
//!   blobs/<hash>     content-addressed: whole scenes (.bee bytes), each
//!                    object's mesh (counts, positions, polygons, loops, UVs),
//!                    manifests; written once, named by the 64-bit hash of
//!                    their bytes (vcHash), so unchanged content costs nothing
//!   commits/<hash>   a commit: text lines "scene", "manifest", "parent" (two
//!                    for a merge), "time", "message"; named by their hash
//!   refs             "head <branch>", "branch <name> <commit>", while merging
//!                    "merge <commit>"
//! A manifest ("VCM1", objects, chunks, 0, then 128-byte object entries and
//! 16-byte chunk entries) lists the scene by object (uid, type, hidden,
//! colour, the mesh's hash, transform, name, material name, vertices) and by
//! chunk (the hash of the materials, their graphs, node trees, animation,
//! light probes as saved).
//!
//! The two programs read each other's repositories: the hash, the file names,
//! the commit and refs text, the manifest and mesh blob layouts are the
//! original's. The scene blobs are each program's own .bee bytes (the port
//! writes version 1, the original version 2 with its chunks in another order),
//! and the original's manifest names carry the bytes after the name's NUL
//! from its stack (unique_name's buffer), so their hashes differ across the
//! programs; "nothing changed" compares manifests by value (see sameManifest).
//!
//! What differs on purpose (bugs of the original not copied):
//!   * a damaged repository (a manifest whose counts pass its end, a mesh
//!     blob whose loops index past its vertices, a commit or refs file without
//!     its last newline at a page's end) is "damaged", not read past;
//!   * the merge keeps its own manifests and the scene as it was before it:
//!     vc.diff or a refused vc.switch during a merge do not change what
//!     "ours" / "theirs" settle to, and "ours" on a chunk gives ours back
//!     (the original re-read it from a blob it never wrote);
//!   * the commit and the conflicts are compared by value, so the original's
//!     repositories (their stack bytes after a name) are "unchanged" here too.
const std = @import("std");
const zui = @import("zui");
const linux = std.os.linux;
const app = @import("app.zig");
const scene = @import("scene.zig");
const files = @import("files.zig");
const bee = @import("bee.zig");
const material = @import("material.zig");
const ops = @import("ops.zig");
const m = @import("math.zig");

const A = std.heap.page_allocator;

pub const MF_HDR = 16;
pub const MF_UID = 0;
pub const MF_TYPE = 4;
pub const MF_FLAGS = 8;
pub const MF_COLOR = 12;
pub const MF_MESH = 16;
pub const MF_XF = 24;
pub const MF_NAME = 60;
pub const MF_MAT = 92;
pub const MF_NV = 124;
pub const MF_SZ = 128;
pub const MF_MAXO = 4096;
pub const MF_MAXC = 8;
pub const MF_BYTES = MF_HDR + MF_MAXO * MF_SZ + MF_MAXC * 16;
pub const BR_MAX = 32;
pub const VD_MAX = 4096;
pub const CF_MAX = 512;

pub const P_XF = 1;
pub const P_NAME = 2;
pub const P_MAT = 4;
pub const P_FLAGS = 8;
pub const P_COLOR = 16;
pub const P_MESH = 32;
pub const P_DEL = 64;
pub const P_CHUNK = 128;

const OBF_HIDDEN: u32 = 0x200;
const MF_MAGIC: u32 = 0x314d4356; // "VCM1"

fn tag4(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}
/// s_tags: the chunks that merge as a whole, in the original's order.
pub const tags = [_]u32{ tag4("MATS"), tag4("MGRF"), tag4("NTRE"), tag4("ANIM"), tag4("PRBE") };
const T_MATS = tags[0];
const T_MGRF = tags[1];
const T_NTRE = tags[2];
const T_ANIM = tags[3];
const T_PRBE = tags[4];

pub const prop_names = [_][]const u8{ "transform", "name", "material", "hidden", "colour", "mesh", "deleted", "chunk" };

const s_nosave = "  versions: save the scene first (its history lives beside the file)";
const s_nochange = "  versions: nothing changed since the last commit";
const s_nobranch = "  versions: no such branch or commit: ";
const s_branched = "  branch made: ";
const s_nocommit = "  versions: commit first";
const s_switched = "  switched to ";
const s_dirty = "  versions: the scene has changes - commit them, or vc.switch <branch> force";
const s_conflicts = "  versions: resolve the conflicts first (the merge panel, vc.resolve)";
const s_uptodate = "  versions: already up to date";
const s_mem = "  versions: out of memory";
const s_bad = "  versions: the history is damaged: ";

// =============================================================================
// Hashes, hex
// =============================================================================

/// vc_hash: 64 bits of the content (FNV-like over 8-byte words, a
/// finalizer; never 0, which means none).
pub fn vcHash(d: []const u8) u64 {
    const p: u64 = 0x100000001b3;
    var h: u64 = 0xcbf29ce484222325;
    var i: usize = 0;
    while (d.len - i >= 8) : (i += 8) {
        h ^= std.mem.readInt(u64, d[i..][0..8], .little);
        h *%= p;
        h = std.math.rotl(u64, h, 23);
    }
    while (i < d.len) : (i += 1) {
        h ^= d[i];
        h *%= p;
    }
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    return if (h == 0) 1 else h;
}

/// hexq: 16 lower-case hex digits.
pub fn hexq(v: u64, out: *[16]u8) []const u8 {
    const dig = "0123456789abcdef";
    for (0..16) |k| out[k] = dig[@intCast((v >> @intCast(60 - 4 * k)) & 15)];
    return out[0..];
}

/// unhex: the value of up to 16 hex digits (lower case) at s[i.*]; i moves
/// past them; the digits read.
fn unhex(s: []const u8, i: *usize) struct { v: u64, n: u32 } {
    var v: u64 = 0;
    var n: u32 = 0;
    while (i.* < s.len and n < 16) {
        const c = s[i.*];
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => break,
        };
        v = (v << 4) | d;
        i.* += 1;
        n += 1;
    }
    return .{ .v = v, .n = n };
}

// =============================================================================
// Paths, files
// =============================================================================

var root_buf: [520]u8 = undefined;
var root_len: usize = 0;
var pbuf: [1100]u8 = undefined;

/// im_word: the last word read (line_word, next_word share it, as the original's).
var word: [264]u8 = @splat(0);
var word_len: usize = 0;
fn wordS() []const u8 {
    return word[0..word_len];
}

fn cstr(b: []const u8) []const u8 {
    return std.mem.sliceTo(b, 0);
}

/// vc_open: the scene has a file; the root set, the refs read.
fn open() bool {
    const p = files.path() orelse return false;
    if (p.len == 0) return false;
    const n = @min(p.len, 500);
    @memcpy(root_buf[0..n], p[0..n]);
    @memcpy(root_buf[n .. n + 3], ".vc");
    root_len = n + 3;
    loadRefs();
    return true;
}

/// vc_fpath: root / folder / name (the folder made).
fn fpath(folder: ?[]const u8, name: ?[]const u8) []const u8 {
    var n: usize = root_len;
    @memcpy(pbuf[0..n], root_buf[0..n]);
    if (folder) |f| {
        pbuf[n] = '/';
        @memcpy(pbuf[n + 1 .. n + 1 + f.len], f);
        n += 1 + f.len;
    }
    _ = @import("spawn.zig").ensureDir(pbuf[0..n]);
    if (name) |nm| {
        pbuf[n] = '/';
        @memcpy(pbuf[n + 1 .. n + 1 + nm.len], nm);
        n += 1 + nm.len;
    }
    return pbuf[0..n];
}

fn blobPath(h: u64) []const u8 {
    var hx: [16]u8 = undefined;
    return fpath("blobs", hexq(h, &hx));
}

/// A whole file read (null: not there, empty, or too big).
fn readFile(path: []const u8, max: usize) ?[]u8 {
    var z: [1100]u8 = undefined;
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const rc = linux.open(@ptrCast(&z), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true, .TYPE = true }, &st)) != .SUCCESS) return null;
    if (st.mode & linux.S.IFMT != linux.S.IFREG) return null;
    if (st.size == 0 or st.size > max) return null;
    const buf = A.alloc(u8, @intCast(st.size)) catch return null;
    var got: usize = 0;
    while (got < buf.len) {
        const r = linux.read(fd, buf[got..].ptr, buf.len - got);
        if (linux.errno(r) != .SUCCESS or r == 0) {
            A.free(buf);
            return null;
        }
        got += r;
    }
    return buf;
}

fn exists(path: []const u8) bool {
    var z: [1100]u8 = undefined;
    if (path.len >= z.len) return false;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const rc = linux.open(@ptrCast(&z), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

fn writeFile(path: []const u8, data: []const u8) void {
    if (!files.mayWrite(path)) return;
    @import("atomicfile.zig").write(path, data) catch {};
}

/// vc_put: the blob written unless it is there; its hash.
fn put(d: []const u8) u64 {
    const h = vcHash(d);
    const p = blobPath(h);
    if (!exists(p)) writeFile(p, d);
    return h;
}

/// vc_get: a blob's bytes (the caller frees), or null.
fn get(h: u64) ?[]u8 {
    return readFile(blobPath(h), 4 << 30);
}

// =============================================================================
// Refs
// =============================================================================

pub var head: [32]u8 = initName("main");
pub var nbr: u32 = 0;
pub var brn: [BR_MAX][32]u8 = undefined;
var brid: [BR_MAX]u64 = @splat(0);
var mergeid: u64 = 0;

fn initName(s: []const u8) [32]u8 {
    var b: [32]u8 = @splat(0);
    @memcpy(b[0..s.len], s);
    return b;
}

pub fn headName() []const u8 {
    return cstr(&head);
}
pub fn branchName(k: usize) []const u8 {
    return cstr(&brn[k]);
}

/// line_word: the next word on this line into `word` (up to 200 bytes kept),
/// i after it.
fn lineWord(s: []const u8, i: *usize) usize {
    while (i.* < s.len and s[i.*] == ' ') i.* += 1;
    var n: usize = 0;
    while (i.* < s.len) : (i.* += 1) {
        const c = s[i.*];
        if (c == ' ' or c == 10 or c == 0) break;
        if (n < 200) {
            word[n] = c;
            n += 1;
        }
    }
    word[n] = 0;
    word_len = n;
    return n;
}

/// im_next_word: the next space-separated word of an argument (255 kept).
fn nextWord(s: []const u8, i: *usize) usize {
    while (i.* < s.len and s[i.*] == ' ') i.* += 1;
    var n: usize = 0;
    while (i.* < s.len) : (i.* += 1) {
        const c = s[i.*];
        if (c == ' ' or c == 0) break;
        if (n < 255) {
            word[n] = c;
            n += 1;
        }
    }
    word[n] = 0;
    word_len = n;
    return n;
}

fn skipSp(s: []const u8, i: *usize) void {
    while (i.* < s.len and s[i.*] == ' ') i.* += 1;
}

fn toEol(s: []const u8, i: *usize) void {
    while (i.* < s.len and s[i.*] != 10) i.* += 1;
    if (i.* < s.len) i.* += 1;
}

/// The first 31 bytes of a word as a 32-byte name (rep movsb 31, then a 0).
fn name31(src: []const u8) [32]u8 {
    var b: [32]u8 = @splat(0);
    const n = @min(src.len, 31);
    @memcpy(b[0..n], src[0..n]);
    return b;
}

/// vc_load_refs: head, branches, merge from the refs file (none: "main").
fn loadRefs() void {
    nbr = 0;
    mergeid = 0;
    head = initName("main");
    const t = readFile(fpath(null, "refs"), 1 << 20) orelse return;
    defer A.free(t);
    parseRefs(t);
}

fn parseRefs(t: []const u8) void {
    var i: usize = 0;
    while (i < t.len) {
        _ = lineWord(t, &i);
        if (std.mem.eql(u8, wordS(), "head")) {
            _ = lineWord(t, &i);
            head = name31(wordS());
        } else if (std.mem.eql(u8, wordS(), "branch")) {
            if (nbr < BR_MAX) {
                _ = lineWord(t, &i);
                brn[nbr] = name31(wordS());
                skipSp(t, &i);
                brid[nbr] = unhex(t, &i).v;
                nbr += 1;
            }
        } else if (std.mem.eql(u8, wordS(), "merge")) {
            skipSp(t, &i);
            mergeid = unhex(t, &i).v;
        }
        toEol(t, &i);
    }
}

fn refsText(out: *std.ArrayList(u8)) !void {
    var hx: [16]u8 = undefined;
    try out.appendSlice(A, "head ");
    try out.appendSlice(A, headName());
    try out.append(A, 10);
    for (0..nbr) |k| {
        try out.appendSlice(A, "branch ");
        try out.appendSlice(A, branchName(k));
        try out.append(A, ' ');
        try out.appendSlice(A, hexq(brid[k], &hx));
        try out.append(A, 10);
    }
    if (mergeid != 0) {
        try out.appendSlice(A, "merge ");
        try out.appendSlice(A, hexq(mergeid, &hx));
        try out.append(A, 10);
    }
}

/// vc_save_refs.
fn saveRefs() void {
    ver +%= 1; // (what the viewport shows may follow: the merge, its panel)
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(A);
    refsText(&out) catch return;
    writeFile(fpath(null, "refs"), out.items);
}

/// br_find.
fn brFind(nm: []const u8) ?usize {
    for (0..nbr) |k| {
        if (std.mem.eql(u8, branchName(k), nm)) return k;
    }
    return null;
}

/// head_id: the checked-out branch's commit (0: none yet).
fn headId() u64 {
    return if (brFind(headName())) |k| brid[k] else 0;
}

/// set_head: the checked-out branch points there (made).
fn setHead(id: u64) void {
    const k = brFind(headName()) orelse blk: {
        if (nbr >= BR_MAX) return;
        brn[nbr] = head;
        nbr += 1;
        break :blk nbr - 1;
    };
    brid[k] = id;
}

/// arg_ref: the commit a branch name or a commit hash (16 hex digits) names, or 0.
fn argRef(w: []const u8) u64 {
    if (brFind(w)) |k| return brid[k];
    var i: usize = 0;
    const r = unhex(w, &i);
    if (r.n != 16 or i != w.len) return 0;
    return r.v;
}

// =============================================================================
// Commits
// =============================================================================

pub const Commit = struct {
    scene: u64 = 0,
    manifest: u64 = 0,
    parent: u64 = 0,
    parent2: u64 = 0,
    time: u64 = 0,
};
var cm: Commit = .{};
/// vc_txt: the message of the commit read last.
var txt: [204]u8 = @splat(0);
var txt_len: usize = 0;

fn parseCommit(t: []const u8) void {
    cm = .{};
    txt_len = 0;
    var i: usize = 0;
    while (i < t.len) {
        _ = lineWord(t, &i);
        const w = wordS();
        const field: ?*u64 = if (std.mem.eql(u8, w, "scene"))
            &cm.scene
        else if (std.mem.eql(u8, w, "manifest"))
            &cm.manifest
        else if (std.mem.eql(u8, w, "parent"))
            (if (cm.parent == 0) &cm.parent else &cm.parent2)
        else if (std.mem.eql(u8, w, "time"))
            &cm.time
        else
            null;
        if (field) |f| {
            skipSp(t, &i);
            f.* = unhex(t, &i).v;
        } else if (std.mem.eql(u8, w, "message")) {
            skipSp(t, &i);
            var n: usize = 0;
            while (i < t.len and t[i] != 10 and n < 200) : (i += 1) {
                txt[n] = t[i];
                n += 1;
            }
            txt_len = n;
        }
        toEol(t, &i);
    }
}

/// commit_read: cm and the message (txt) of commit id; false: not there.
fn commitRead(id: u64) bool {
    var hx: [16]u8 = undefined;
    const t = readFile(fpath("commits", hexq(id, &hx)), 1 << 20) orelse return false;
    defer A.free(t);
    parseCommit(t);
    return true;
}

pub fn message() []const u8 {
    return txt[0..txt_len];
}

/// merge_base: the nearest common ancestor of ours and theirs (0: none):
/// ours' ancestors marked, then theirs walked breadth first (4095 each).
fn mergeBase(ours: u64, theirs: u64) u64 {
    const L = 4095;
    const mine = A.alloc(u64, 4096) catch return 0;
    defer A.free(mine);
    const walk = A.alloc(u64, 4096) catch return 0;
    defer A.free(walk);
    mine[0] = ours;
    var n: usize = 1;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        if (!commitRead(mine[k])) continue;
        for ([2]u64{ cm.parent, cm.parent2 }) |p| {
            if (p == 0) continue;
            if (std.mem.indexOfScalar(u64, mine[0..n], p) != null) continue;
            if (n >= L) continue;
            mine[n] = p;
            n += 1;
        }
    }
    walk[0] = theirs;
    var w: usize = 1;
    k = 0;
    while (k < w) : (k += 1) {
        const c = walk[k];
        if (std.mem.indexOfScalar(u64, mine[0..n], c) != null) return c;
        if (!commitRead(c)) continue;
        for ([2]u64{ cm.parent, cm.parent2 }) |p| {
            if (p == 0 or w >= L) continue;
            walk[w] = p;
            w += 1;
        }
    }
    return 0;
}

// =============================================================================
// Manifests
// =============================================================================

/// A manifest's bytes (MF_BYTES), as the original keeps it.
pub const Manifest = struct {
    b: []u8 = &.{},

    fn ok(mf: *Manifest) bool {
        if (mf.b.len == 0) mf.b = A.alloc(u8, MF_BYTES) catch return false;
        return true;
    }
    pub fn nobj(mf: *const Manifest) u32 {
        return rd32(mf.b, 4);
    }
    pub fn nchunk(mf: *const Manifest) u32 {
        return rd32(mf.b, 8);
    }
    pub fn entry(mf: *const Manifest, k: usize) []u8 {
        return mf.b[MF_HDR + k * MF_SZ ..][0..MF_SZ];
    }
    fn chunkAt(mf: *const Manifest, k: usize) []u8 {
        return mf.b[MF_HDR + @as(usize, mf.nobj()) * MF_SZ + k * 16 ..][0..16];
    }
    pub fn size(mf: *const Manifest) usize {
        return MF_HDR + @as(usize, mf.nobj()) * MF_SZ + @as(usize, mf.nchunk()) * 16;
    }
    pub fn bytes(mf: *const Manifest) []const u8 {
        return mf.b[0..mf.size()];
    }
    /// mf_find.
    pub fn find(mf: *const Manifest, uid: u32) ?usize {
        for (0..mf.nobj()) |k| {
            if (rd32(mf.entry(k), MF_UID) == uid) return k;
        }
        return null;
    }
    /// mf_chunk: the chunk's hash (0: none).
    fn chunk(mf: *const Manifest, t: u32) u64 {
        for (0..mf.nchunk()) |k| {
            const c = mf.chunkAt(k);
            if (rd32(c, 0) == t) return rd64(c, 8);
        }
        return 0;
    }
    fn empty(mf: *Manifest) void {
        @memset(mf.b[0..MF_HDR], 0);
        wr32(mf.b, 0, MF_MAGIC);
    }
};

fn rd32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
fn rd64(b: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, b[o..][0..8], .little);
}
fn wr32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}
fn wr64(b: []u8, o: usize, v: u64) void {
    std.mem.writeInt(u64, b[o..][0..8], v, .little);
}

/// The object's type as the files carry it (OB_TYPE).
fn typeCode(k: scene.Kind) u32 {
    return switch (k) {
        .light => 1,
        .camera => 2,
        .armature => 4,
        .sketch => 3,
        .field => 5,
        else => 0,
    };
}

/// mesh_blob: the mesh's blob (the live link's MESH layout: 0, vertices,
/// polygons, loops, UVs?, then positions, offsets, loops, UVs); its hash.
fn meshBlob(me: *const scene.Mesh, write: bool) u64 {
    const np = me.poff.len - 1;
    const has_uv = me.uv.len > 0 and me.uv.len == me.loops.len;
    var sz: usize = 20 + me.verts.len * 12 + (np + 1) * 4 + me.loops.len * 4;
    if (has_uv) sz += me.loops.len * 8;
    const b = A.alloc(u8, sz) catch return 0;
    defer A.free(b);
    wr32(b, 0, 0);
    wr32(b, 4, @intCast(me.verts.len));
    wr32(b, 8, @intCast(np));
    wr32(b, 12, @intCast(me.loops.len));
    wr32(b, 16, @intFromBool(has_uv));
    var o: usize = 20;
    const vb = std.mem.sliceAsBytes(me.verts);
    @memcpy(b[o..][0..vb.len], vb);
    o += vb.len;
    const pb = std.mem.sliceAsBytes(me.poff);
    @memcpy(b[o..][0..pb.len], pb);
    o += pb.len;
    const lb = std.mem.sliceAsBytes(me.loops);
    @memcpy(b[o..][0..lb.len], lb);
    o += lb.len;
    if (has_uv) {
        const ub = std.mem.sliceAsBytes(me.uv);
        @memcpy(b[o..][0..ub.len], ub);
    }
    return if (write) put(b) else vcHash(b);
}

/// The scene's .bee bytes (the caller frees), as a save would write them.
fn sceneBytes() ?[]u8 {
    return bee.encode(files.viewForFile()) catch null;
}

/// build_manifest: the scene's manifest in mf; the scene's .bee bytes (kept
/// as a blob when write); returns its hash (0: no memory).
fn buildManifest(mf: *Manifest, write: bool, keep: ?*?[]u8) u64 {
    if (!mf.ok()) return 0;
    const sb = sceneBytes() orelse return 0;
    defer if (keep) |k| {
        if (k.*) |old| A.free(old);
        k.* = sb;
    } else A.free(sb);
    const sh = if (write) put(sb) else vcHash(sb);
    mf.empty();
    var n: u32 = 0;
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (n >= MF_MAXO) break;
        const e = mf.entry(n);
        @memset(e, 0);
        wr32(e, MF_UID, o.uid);
        const t = typeCode(o.kind);
        wr32(e, MF_TYPE, t);
        wr32(e, MF_FLAGS, if (o.visible) 0 else OBF_HIDDEN);
        wr32(e, MF_COLOR, o.color & 0xffffff);
        const wp = scene.worldPlace(i);
        @memcpy(e[MF_XF..][0..36], std.mem.sliceAsBytes(&wp));
        @memcpy(e[MF_NAME..][0..31], o.name_buf[0..31]);
        if (material.of(o)) |ma| @memcpy(e[MF_MAT..][0..31], ma.name[0..31]);
        if (t == 0) {
            if (o.mesh) |mi| {
                if (scene.meshes[mi]) |*me| {
                    wr64(e, MF_MESH, meshBlob(me, write));
                    wr32(e, MF_NV, @intCast(me.verts.len));
                }
            }
        }
        n += 1;
    }
    wr32(mf.b, 4, n);
    // the chunks that merge as a whole, as saved
    var nc: u32 = 0;
    var have_anim = false;
    var o: usize = 8;
    while (sb.len - o >= 8) {
        const t = rd32(sb, o);
        const s = rd32(sb, o + 4);
        if (s > sb.len - o - 8) break;
        if (std.mem.indexOfScalar(u32, &tags, t) != null and nc < MF_MAXC) {
            const c = mf.b[MF_HDR + @as(usize, n) * MF_SZ + nc * 16 ..][0..16];
            @memset(c, 0);
            wr32(c, 0, t);
            wr64(c, 8, vcHash(sb[o + 8 ..][0..s]));
            if (t == T_ANIM) have_anim = true;
            nc += 1;
        }
        o += 8 + s;
    }
    // (the original always saves ANIM, empty without animation; the port
    // only with some: the same entry as the original's then)
    if (!have_anim and nc < MF_MAXC) {
        const c = mf.b[MF_HDR + @as(usize, n) * MF_SZ + nc * 16 ..][0..16];
        @memset(c, 0);
        wr32(c, 0, T_ANIM);
        wr64(c, 8, vcHash(""));
        nc += 1;
    }
    wr32(mf.b, 8, nc);
    return sh;
}

/// mf_load: a manifest blob into mf; false: not there or damaged.
fn mfLoad(h: u64, mf: *Manifest) bool {
    if (!mf.ok()) return false;
    const d = get(h) orelse return false;
    defer A.free(d);
    if (d.len < MF_HDR or d.len > MF_BYTES) return false;
    const no = rd32(d, 4);
    const nc = rd32(d, 8);
    if (no > MF_MAXO or nc > MF_MAXC) return false;
    if (MF_HDR + @as(usize, no) * MF_SZ + @as(usize, nc) * 16 > d.len) return false;
    @memcpy(mf.b[0..d.len], d);
    return true;
}

/// mf_diff: the properties that differ between two entries.
fn mfDiff(a: []const u8, b: []const u8) u32 {
    var r: u32 = 0;
    if (!std.mem.eql(u8, a[MF_XF..][0..36], b[MF_XF..][0..36])) r |= P_XF;
    if (!std.mem.eql(u8, cstr(a[MF_NAME..][0..32]), cstr(b[MF_NAME..][0..32]))) r |= P_NAME;
    if (!std.mem.eql(u8, cstr(a[MF_MAT..][0..32]), cstr(b[MF_MAT..][0..32]))) r |= P_MAT;
    if (rd32(a, MF_FLAGS) != rd32(b, MF_FLAGS)) r |= P_FLAGS;
    if (rd32(a, MF_COLOR) != rd32(b, MF_COLOR)) r |= P_COLOR;
    if (rd64(a, MF_MESH) != rd64(b, MF_MESH)) r |= P_MESH;
    return r;
}

/// Two manifests the same in everything they say (the bytes after a name's
/// NUL aside): what "nothing changed" means.
fn sameManifest(a: *const Manifest, b: *const Manifest) bool {
    if (a.nobj() != b.nobj() or a.nchunk() != b.nchunk()) return false;
    for (0..a.nobj()) |k| {
        const x = a.entry(k);
        const y = b.entry(k);
        if (rd32(x, MF_UID) != rd32(y, MF_UID) or rd32(x, MF_TYPE) != rd32(y, MF_TYPE) or rd32(x, MF_NV) != rd32(y, MF_NV)) return false;
        if (mfDiff(x, y) != 0) return false;
    }
    for (0..a.nchunk()) |k| {
        const x = a.chunkAt(k);
        const y = b.chunkAt(k);
        if (rd32(x, 0) != rd32(y, 0) or rd64(x, 8) != rd64(y, 8)) return false;
    }
    return true;
}

/// The manifests: the scene now (scratch), the diff's other version, and the
/// merge's base, ours (the scene before it) and theirs.
var mf_now: Manifest = .{};
var d_mt: Manifest = .{};
var d_mo: Manifest = .{};
var m_mb: Manifest = .{};
var m_mo: Manifest = .{};
var m_mt: Manifest = .{};
/// The scene before the merge (.bee bytes: "ours" for a chunk).
var m_ours: ?[]u8 = null;
/// The merge's their scene blob (chunks).
var m_theirs_scene: u64 = 0;

/// The scene's manifest the same as commit id's (by hash, else by value).
fn unchangedSince(id: u64, h: u64) bool {
    if (!commitRead(id)) return false;
    if (cm.manifest == h) return true;
    var other: Manifest = .{};
    defer if (other.b.len > 0) A.free(other.b);
    if (!mfLoad(cm.manifest, &other)) return false;
    return sameManifest(&mf_now, &other);
}

// =============================================================================
// Meshes from blobs
// =============================================================================

/// mesh_load (build_mesh): the mesh a blob holds, in a new slot (null: none
/// or damaged; polygons of no loops are left out, as the original's).
fn meshLoad(h: u64) ?u16 {
    if (h == 0) return null;
    const d = get(h) orelse return null;
    defer A.free(d);
    return meshFromBlob(d);
}

pub fn meshFromBlob(d: []const u8) ?u16 {
    if (d.len < 20) return null;
    const nv: usize = rd32(d, 4);
    const np: usize = rd32(d, 8);
    const nl: usize = rd32(d, 12);
    const has_uv = rd32(d, 16) != 0;
    if (nv > 50_000_000 or np > 50_000_000 or nl > 200_000_000) return null;
    const need: usize = 20 + nv * 12 + (np + 1) * 4 + nl * 4 + (if (has_uv) nl * 8 else 0);
    if (need > d.len) return null;
    const verts = A.alloc(m.V3, nv) catch return null;
    defer A.free(verts);
    @memcpy(std.mem.sliceAsBytes(verts), d[20..][0 .. nv * 12]);
    const so = 20 + nv * 12;
    const lo = so + (np + 1) * 4;
    const poff = A.alloc(u32, np + 1) catch return null;
    defer A.free(poff);
    const loops = A.alloc(u32, nl) catch return null;
    defer A.free(loops);
    var q: usize = 0;
    var nlp: usize = 0;
    poff[0] = 0;
    for (0..np) |p| {
        const s = rd32(d, so + p * 4);
        const e = rd32(d, so + p * 4 + 4);
        if (e <= s) continue;
        if (e > nl) return null;
        for (s..e) |k| {
            const l = rd32(d, lo + k * 4);
            if (l >= nv) return null;
            loops[nlp] = l;
            nlp += 1;
            if (nlp > nl) return null;
        }
        q += 1;
        poff[q] = @intCast(nlp);
    }
    const mi = scene.addMesh(verts, poff[0 .. q + 1], loops[0..nlp]) orelse return null;
    if (has_uv and nlp == nl and nl > 0) {
        if (scene.meshes[mi]) |*me| {
            const uv = @import("alloc.zig").A.alloc([2]f32, nl) catch return mi;
            @memcpy(std.mem.sliceAsBytes(uv), d[lo + nl * 4 ..][0 .. nl * 8]);
            me.uv = uv;
        }
    }
    return mi;
}

/// A version's mesh for drawing only (no scene slot: undo's sweep never sees it).
pub const Ghost = struct {
    verts: []m.V3,
    poff: []u32,
    loops: []u32,

    pub fn free(g: *Ghost) void {
        A.free(g.verts);
        A.free(g.poff);
        A.free(g.loops);
        A.destroy(g);
    }
};

/// A mesh blob's polygons for ghost_draw (null: none or damaged).
pub fn ghostLoad(h: u64) ?*Ghost {
    if (h == 0) return null;
    const d = get(h) orelse return null;
    defer A.free(d);
    if (d.len < 20) return null;
    const nv: usize = rd32(d, 4);
    const np: usize = rd32(d, 8);
    const nl: usize = rd32(d, 12);
    if (nv > 50_000_000 or np > 50_000_000 or nl > 200_000_000) return null;
    if (20 + nv * 12 + (np + 1) * 4 + nl * 4 > d.len) return null;
    const g = A.create(Ghost) catch return null;
    g.verts = A.alloc(m.V3, nv) catch {
        A.destroy(g);
        return null;
    };
    g.poff = A.alloc(u32, np + 1) catch {
        A.free(g.verts);
        A.destroy(g);
        return null;
    };
    g.loops = A.alloc(u32, nl) catch {
        A.free(g.verts);
        A.free(g.poff);
        A.destroy(g);
        return null;
    };
    @memcpy(std.mem.sliceAsBytes(g.verts), d[20..][0 .. nv * 12]);
    @memcpy(std.mem.sliceAsBytes(g.poff), d[20 + nv * 12 ..][0 .. (np + 1) * 4]);
    @memcpy(std.mem.sliceAsBytes(g.loops), d[20 + nv * 12 + (np + 1) * 4 ..][0 .. nl * 4]);
    // (what would index past them: no drawing)
    for (g.poff) |p| {
        if (p > nl) {
            g.free();
            return null;
        }
    }
    for (g.loops) |l| {
        if (l >= nv) {
            g.free();
            return null;
        }
    }
    return g;
}

// =============================================================================
// The scene from entries
// =============================================================================

/// name_taken (str_eq: exact).
fn nameTaken(nm: []const u8, skip: ?usize) bool {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (skip != null and skip.? == i) continue;
        if (std.mem.eql(u8, o.name(), nm)) return true;
    }
    return false;
}

/// unique_name: the base (26 bytes at most), then ".001" ... ".999".
fn uniqueName(base0: []const u8, skip: ?usize, out: *[32]u8) []const u8 {
    const base = base0[0..@min(base0.len, 26)];
    var k: u32 = 0;
    while (true) : (k += 1) {
        const s = if (k == 0)
            std.fmt.bufPrint(out, "{s}", .{base}) catch base
        else
            std.fmt.bufPrint(out, "{s}.{d:0>3}", .{ base, k }) catch base;
        if (!nameTaken(s, skip) or k >= 999) return s;
    }
}

fn entryName(e: []const u8) []const u8 {
    return cstr(e[MF_NAME..][0..31]);
}
fn entryMat(e: []const u8) []const u8 {
    return cstr(e[MF_MAT..][0..31]);
}
fn entryXf(e: []const u8) [9]f32 {
    var p: [9]f32 = undefined;
    @memcpy(std.mem.sliceAsBytes(&p), e[MF_XF..][0..36]);
    return p;
}

/// mat_by_name: its index + 1, 0 for "" or none.
fn matByName(nm: []const u8) u16 {
    if (nm.len == 0) return 0;
    return if (material.find(nm)) |i| @intCast(i + 1) else 0;
}

/// obj_from_entry: a new object as they have it (their uid kept when it is
/// free here).
fn objFromEntry(e: []const u8) void {
    const t = rd32(e, MF_TYPE);
    var o: scene.Object = switch (t) {
        0 => blk: {
            const mi = meshLoad(rd64(e, MF_MESH)) orelse return;
            break :blk .{ .kind = .mesh, .mesh = mi };
        },
        1 => .{ .kind = .light },
        2 => .{ .kind = .camera },
        else => return,
    };
    if (scene.count >= scene.max_objects) return;
    var nb: [32]u8 = undefined;
    o.setName(uniqueName(entryName(e), null, &nb));
    const p = entryXf(e);
    o.loc = .{ p[0], p[1], p[2] };
    o.setRadians(.{ p[3], p[4], p[5] });
    o.scl = .{ p[6], p[7], p[8] };
    if (rd32(e, MF_FLAGS) & OBF_HIDDEN != 0) o.visible = false;
    o.color = rd32(e, MF_COLOR);
    o.mat = matByName(entryMat(e));
    const i = scene.count;
    scene.objects[i] = o;
    scene.stamp(i);
    scene.count += 1;
    const uid = rd32(e, MF_UID);
    if (uid != 0 and scene.findUid(uid) == null) {
        scene.objects[i].uid = uid;
        if (uid >= scene.uid_next) scene.uid_next = uid + 1;
    }
    app.dirty = true;
}

fn objRemoveUid(uid: u32) void {
    if (scene.findUid(uid)) |i| scene.remove(i);
}

/// prop_apply: the scene's object takes their value.
fn propApply(e: []const u8, prop: u32) void {
    const i = scene.findUid(rd32(e, MF_UID)) orelse return;
    const o = &scene.objects[i];
    switch (prop) {
        P_XF => scene.setWorldPlace(i, entryXf(e)),
        P_NAME => {
            var nb: [32]u8 = undefined;
            o.setName(uniqueName(entryName(e), i, &nb));
        },
        P_MAT => o.mat = matByName(entryMat(e)),
        P_FLAGS => o.visible = rd32(e, MF_FLAGS) & OBF_HIDDEN == 0,
        P_COLOR => o.color = rd32(e, MF_COLOR),
        P_MESH => {
            const mi = meshLoad(rd64(e, MF_MESH)) orelse return;
            o.mesh = mi;
        },
        else => {},
    }
    app.dirty = true;
}

/// uid -> our index, for the animation's reader.
const Look = struct {
    pub fn get(_: Look, u: u32) ?u16 {
        return if (scene.findUid(u)) |i| @intCast(i) else null;
    }
};

/// Find chunk t in .bee bytes (version 2's compressed chunks unpacked first).
fn findChunk(sb: []const u8, t: u32) ?[]const u8 {
    if (sb.len < 8) return null;
    var o: usize = 8;
    while (sb.len - o >= 8) {
        const ct = rd32(sb, o);
        const s = rd32(sb, o + 4);
        if (s > sb.len - o - 8) return null;
        if (ct == t) return sb[o + 8 ..][0..s];
        o += 8 + s;
    }
    return null;
}

fn chunkRead(t: u32, c: []const u8) void {
    if (t == T_MATS) {
        _ = material.readMats(c);
    } else if (t == T_MGRF) {
        _ = material.readGraphs(c);
    } else if (t == T_NTRE) {
        @import("ntree.zig").read(c);
    } else if (t == T_ANIM) {
        @import("anim.zig").reset();
        if (c.len > 0) _ = @import("anim.zig").readChunk(c, Look{});
    } else if (t == T_PRBE) {
        @import("probe.zig").reset();
        _ = @import("probe.zig").read(c);
    }
}

/// chunk_apply: chunk t read in from a scene's .bee bytes (materials: their
/// graphs too); then every object's material again by the name its entry in
/// ours gives.
fn chunkApplyBytes(sb0: []const u8, t: u32, ours: *const Manifest) void {
    var unpacked: ?[]u8 = null;
    defer if (unpacked) |u| A.free(u);
    var sb = sb0;
    if (sb.len >= 8 and rd32(sb, 4) == 2) {
        unpacked = bee.unpack(sb) catch return;
        sb = unpacked.?;
    }
    if (findChunk(sb, t)) |c| {
        chunkRead(t, c);
    } else if (t == T_ANIM) chunkRead(t, ""); // (no animation saved: none)
    if (t == T_MATS) {
        if (findChunk(sb, T_MGRF)) |c| chunkRead(T_MGRF, c);
    }
    // mats_by_name
    if (ours.b.len > 0) {
        for (scene.objects[0..scene.count]) |*o| {
            const k = ours.find(o.uid) orelse continue;
            o.mat = matByName(entryMat(ours.entry(k)));
        }
    }
    app.dirty = true;
}

fn chunkApply(scene_hash: u64, t: u32, ours: *const Manifest) void {
    const d = get(scene_hash) orelse return;
    defer A.free(d);
    chunkApplyBytes(d, t, ours);
}

// =============================================================================
// The diff
// =============================================================================

pub const Row = struct {
    uid: u32 = 0,
    kind: u32 = 0, // 1 added, 2 removed, 3 changed
    mask: u32 = 0,
    nv: u32 = 0, // the other version's vertices
    mesh: u64 = 0, // the other version's mesh
    xf: [9]f32 = @splat(0),
    name: [32]u8 = @splat(0),
    ghost: ?*Ghost = null, // the other version's mesh, built (drawing)
    nvnow: u32 = 0,
};
pub var vd: []Row = &.{};
pub var nvd: usize = 0;
/// 0 off, 1 overlay, 2 side
pub var view: u32 = 0;
/// What the scene is compared with (and the merge's branch).
pub var label: [40]u8 = @splat(0);

fn vdClear() void {
    for (vd[0..nvd]) |*r| {
        if (r.ghost) |g| g.free();
        r.ghost = null;
    }
    nvd = 0;
    view = 0;
    ver +%= 1;
}

fn vdAdd(e: []const u8, kind: u32, mask: u32, other: ?[]const u8) void {
    if (vd.len == 0) vd = A.alloc(Row, VD_MAX) catch return;
    if (nvd >= VD_MAX) return;
    const r = &vd[nvd];
    nvd += 1;
    r.uid = rd32(e, MF_UID);
    r.kind = kind;
    r.mask = mask;
    r.ghost = null;
    r.nvnow = rd32(e, MF_NV);
    @memcpy(&r.name, e[MF_NAME..][0..32]);
    r.mesh = 0;
    r.nv = 0;
    if (other) |x| {
        r.mesh = rd64(x, MF_MESH);
        r.nv = rd32(x, MF_NV);
        r.xf = entryXf(x);
    }
}

/// vd_build: the scene (mo) against the other version (mt).
fn vdBuild(mo: *const Manifest, mt: *const Manifest) void {
    nvd = 0;
    for (0..mo.nobj()) |k| {
        const e = mo.entry(k);
        if (mt.find(rd32(e, MF_UID))) |t| {
            const x = mt.entry(t);
            const d = mfDiff(e, x);
            if (d != 0) vdAdd(e, 3, d, x);
        } else vdAdd(e, 1, 0, null);
    }
    for (0..mt.nobj()) |k| {
        const e = mt.entry(k);
        if (mo.find(rd32(e, MF_UID)) == null) vdAdd(e, 2, 0, e);
    }
}

/// vd_row_text: "+ Name", "- Name", "~ Name: transform mesh 482 v > 7938 v ".
pub fn rowText(k: usize, buf: []u8) []const u8 {
    const r = &vd[k];
    var w = std.Io.Writer.fixed(buf);
    w.writeAll(switch (r.kind) {
        1 => "+ ",
        2 => "- ",
        else => "~ ",
    }) catch {};
    w.writeAll(cstr(&r.name)) catch {};
    if (r.kind == 3) {
        w.writeAll(": ") catch {};
        for (0..6) |b| {
            if (r.mask & (@as(u32, 1) << @intCast(b)) == 0) continue;
            w.writeAll(prop_names[b]) catch {};
            if (b == 5) w.print(" {d} v > {d} v", .{ r.nv, r.nvnow }) catch {};
            w.writeAll(" ") catch {};
        }
    }
    return w.buffered();
}

// =============================================================================
// Conflicts
// =============================================================================

pub const Conflict = struct {
    uid: u32 = 0,
    prop: u32 = 0,
    state: u32 = 0, // 0 open, 1 ours, 2 theirs
    tag: u32 = 0,
    t: i32 = -1, // their manifest entry (-1 none)
    name: [32]u8 = @splat(0),
};
pub var cf: [CF_MAX]Conflict = undefined;
pub var ncf: usize = 0;

fn cfAdd(uid: u32, prop: u32, t: i32) ?*Conflict {
    if (ncf >= CF_MAX) return null;
    const c = &cf[ncf];
    ncf += 1;
    c.* = .{ .uid = uid, .prop = prop, .t = t };
    return c;
}

fn cfAddE(prop: u32, k: usize) void {
    const e = m_mt.entry(k);
    const c = cfAdd(rd32(e, MF_UID), prop, @intCast(k)) orelse return;
    @memcpy(c.name[0..31], e[MF_NAME..][0..31]);
}

/// cf_open: the conflicts not settled.
pub fn cfOpen() usize {
    var n: usize = 0;
    for (cf[0..ncf]) |c| {
        if (c.state == 0) n += 1;
    }
    return n;
}

/// cf_row_text: "n. Name: property" (" (ours)" / " (theirs)" once settled;
/// the original's always says "(theirs)": the state it tests is clobbered by
/// the fmt_char calls before it).
pub fn cfRowText(k: usize, buf: []u8) []const u8 {
    const c = &cf[k];
    var w = std.Io.Writer.fixed(buf);
    const bit: usize = if (c.prop == 0) 0 else @ctz(c.prop);
    w.print("{d}. {s}: {s}", .{ k + 1, cstr(&c.name), prop_names[@min(bit, 7)] }) catch {};
    if (c.state != 0) w.print(" ({s})", .{if (c.state == 1) "ours" else "theirs"}) catch {};
    return w.buffered();
}

/// mg_chunks: per tracked chunk, changed by them only -> theirs read in; by
/// both, differently -> a conflict.
fn mgChunks(their_scene: u64) void {
    for (tags) |t| {
        const b = m_mb.chunk(t);
        const o = m_mo.chunk(t);
        const th = m_mt.chunk(t);
        if (o == th) continue;
        if (th == b) continue;
        if (o == b) {
            chunkApply(their_scene, t, &m_mo);
            continue;
        }
        const c = cfAdd(0, P_CHUNK, -1) orelse continue;
        c.tag = t;
        std.mem.writeInt(u32, c.name[0..4], t, .little);
        c.name[4] = 0;
    }
}

/// mg_objects: three-way per object and property.
fn mgObjects() void {
    for (0..m_mt.nobj()) |k| {
        const te = m_mt.entry(k);
        const uid = rd32(te, MF_UID);
        const ok_ = m_mo.find(uid);
        const bk = m_mb.find(uid);
        if (ok_ == null) {
            if (bk == null) {
                objFromEntry(te); // added by them
            } else if (mfDiff(te, m_mb.entry(bk.?)) != 0) {
                cfAddE(P_DEL, k); // we deleted, they changed
            }
            continue;
        }
        const oe = m_mo.entry(ok_.?);
        for (0..6) |b| {
            const bit: u32 = @as(u32, 1) << @intCast(b);
            if (mfDiff(oe, te) & bit == 0) continue;
            if (bk) |bi| {
                const be = m_mb.entry(bi);
                if (mfDiff(oe, be) & bit == 0) {
                    propApply(te, bit); // only theirs changed
                    continue;
                }
                if (mfDiff(te, be) & bit == 0) continue; // only ours
            }
            cfAddE(bit, k);
        }
    }
    for (0..m_mo.nobj()) |k| {
        const oe = m_mo.entry(k);
        const uid = rd32(oe, MF_UID);
        if (m_mt.find(uid) != null) continue;
        const bk = m_mb.find(uid) orelse continue; // added by us: kept
        if (mfDiff(oe, m_mb.entry(bk)) == 0) {
            objRemoveUid(uid); // they deleted it, we did not touch it
        } else {
            const c = cfAdd(uid, P_DEL, -1) orelse continue;
            @memcpy(c.name[0..31], oe[MF_NAME..][0..31]);
        }
    }
}

/// cf_settle: theirs -> their value into the scene (deleted: the object goes /
/// comes back as theirs); ours -> our value back.
pub fn cfSettle(k: usize, side: u32) void {
    if (k >= ncf) return;
    ver +%= 1;
    const c = &cf[k];
    c.state = side;
    if (side == 2) {
        if (c.prop == P_CHUNK) {
            chunkApply(m_theirs_scene, c.tag, &m_mo);
            return;
        }
        if (c.t < 0) return objRemoveUid(c.uid); // they deleted it: it goes
        const te = m_mt.entry(@intCast(c.t));
        if (c.prop == P_DEL) {
            if (scene.findUid(c.uid) == null) objFromEntry(te); // we deleted it: theirs back
            return;
        }
        return propApply(te, c.prop);
    }
    if (c.prop == P_CHUNK) {
        if (m_ours) |sb| chunkApplyBytes(sb, c.tag, &m_mo);
        return;
    }
    const ok_ = m_mo.find(c.uid) orelse return objRemoveUid(c.uid); // we had deleted it
    const oe = m_mo.entry(ok_);
    if (scene.findUid(c.uid) == null) return objFromEntry(oe); // we had it: back
    if (c.prop == P_DEL) return;
    propApply(oe, c.prop);
}

// =============================================================================
// Operators
// =============================================================================

fn say(s: []const u8) void {
    app.toastLine(.ok, s);
}
fn sayPair(a: []const u8, b: []const u8) void {
    var buf: [400]u8 = undefined;
    say(std.fmt.bufPrint(&buf, "{s}{s}", .{ a, b }) catch a);
}

fn nowSecs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return if (ts.sec > 0) @intCast(ts.sec) else 0;
}

fn opCommit() void {
    if (!open()) return say(s_nosave);
    if (mergeid != 0 and cfOpen() > 0) return say(s_conflicts);
    const sh = buildManifest(&mf_now, true, null);
    if (sh == 0) return say(s_mem);
    const mh = put(mf_now.bytes());
    const parent = headId();
    if (parent != 0 and mergeid == 0 and unchangedSince(parent, mh)) return say(s_nochange);
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(A);
    commitText(&t, sh, mh, parent) catch return say(s_mem);
    const id = vcHash(t.items);
    var hx: [16]u8 = undefined;
    writeFile(fpath("commits", hexq(id, &hx)), t.items);
    setHead(id);
    mergeid = 0;
    ncf = 0;
    saveRefs();
    var b: [120]u8 = undefined;
    say(std.fmt.bufPrint(&b, "  committed {s} on {s}", .{ hx[0..8], headName() }) catch "");
}

fn commitText(t: *std.ArrayList(u8), sh: u64, mh: u64, parent: u64) !void {
    const kv = struct {
        fn f(tt: *std.ArrayList(u8), k: []const u8, v: u64) !void {
            var h2: [16]u8 = undefined;
            try tt.appendSlice(A, k);
            try tt.append(A, ' ');
            try tt.appendSlice(A, hexq(v, &h2));
            try tt.append(A, 10);
        }
    }.f;
    try kv(t, "scene", sh);
    try kv(t, "manifest", mh);
    if (parent != 0) try kv(t, "parent", parent);
    if (mergeid != 0) try kv(t, "parent", mergeid);
    try kv(t, "time", nowSecs());
    try t.appendSlice(A, "message ");
    // (op_arg 0 - the menus, the palette - and merging: "merge ")
    const given = ops.scripted or ops.arg.len > 0;
    if (given) {
        const a = ops.arg;
        const e = std.mem.indexOfAny(u8, a, "\n\x00") orelse a.len;
        try t.appendSlice(A, a[0..e]);
    } else if (mergeid != 0) try t.appendSlice(A, "merge ");
    try t.append(A, 10);
}

fn opLog() void {
    if (!open()) return;
    var id = headId();
    var n: usize = 0;
    while (id != 0 and n < 100) : (n += 1) {
        if (!commitRead(id)) return;
        var hx: [16]u8 = undefined;
        var b: [260]u8 = undefined;
        say(std.fmt.bufPrint(&b, "  {s} {s}", .{ hexq(id, &hx)[0..8], message() }) catch "");
        id = cm.parent;
    }
}

/// vc_log_rows: "1a2b3c4d  message" rows (newest first, 32 at most), read
/// again when the branch's head moves.
pub var lrow: [32][64]u8 = undefined;
var nlrow: usize = 0;
var lhead: u64 = std.math.maxInt(u64);
pub fn logRows() usize {
    if (!open()) {
        lhead = std.math.maxInt(u64);
        return 0;
    }
    const h = headId();
    if (h == lhead) return nlrow;
    lhead = h;
    var id = h;
    var n: usize = 0;
    while (id != 0 and n < 32) : (n += 1) {
        if (!commitRead(id)) break;
        const r = &lrow[n];
        var hx: [16]u8 = undefined;
        _ = hexq(id, &hx);
        @memcpy(r[0..8], hx[0..8]);
        r[8] = ' ';
        r[9] = ' ';
        var k: usize = 0;
        const msg = message();
        while (k < msg.len and k < 53 and msg[k] != 10 and msg[k] != 0) : (k += 1) r[10 + k] = msg[k];
        r[10 + k] = 0;
        id = cm.parent;
    }
    nlrow = n;
    return n;
}
pub fn logRow(k: usize) []const u8 {
    return cstr(&lrow[k]);
}

fn opBranch() void {
    if (!open()) return say(s_nosave);
    const h = headId();
    if (h == 0) return say(s_nocommit);
    var i: usize = 0;
    if (nextWord(ops.arg, &i) == 0) return;
    const k = brFind(wordS()) orelse blk: {
        if (nbr >= BR_MAX) return;
        brn[nbr] = name31(wordS());
        nbr += 1;
        break :blk nbr - 1;
    };
    brid[k] = h;
    saveRefs();
    sayPair(s_branched, wordS());
}

/// vc_dirty: the scene differs from its branch's last commit.
fn isDirty() bool {
    const h = headId();
    if (h == 0) return false;
    if (!commitRead(h)) return false;
    if (buildManifest(&mf_now, false, null) == 0) return false;
    return !unchangedSince(h, vcHash(mf_now.bytes()));
}

/// Replace the scene with a scene blob's (the file's name stays). False: damaged.
fn loadBlob(h: u64) bool {
    const p = blobPath(h);
    var pb: [1100]u8 = undefined;
    @memcpy(pb[0..p.len], p);
    _ = bee.load(pb[0..p.len], files.viewForFile()) catch return false;
    return true;
}

fn opSwitch() void {
    if (!open()) return say(s_nosave);
    var i: usize = 0;
    if (nextWord(ops.arg, &i) == 0) return;
    const nm = name31(wordS());
    _ = nextWord(ops.arg, &i);
    const force = std.mem.eql(u8, wordS(), "force");
    const k = brFind(cstr(&nm)) orelse return sayPair(s_nobranch, cstr(&nm));
    const id = brid[k];
    if (!force and isDirty()) return say(s_dirty);
    if (!commitRead(id) or !loadBlob(cm.scene)) return sayPair(s_bad, cstr(&nm));
    head = nm;
    mergeid = 0;
    ncf = 0;
    saveRefs();
    vdClear();
    sayPair(s_switched, cstr(&nm));
    app.dirty = true;
}

fn opDiff() void {
    vdClear();
    defer app.dirty = true;
    if (!open()) return say(s_nosave);
    var id = headId();
    @memcpy(label[0..32], &head);
    var mode: u32 = 1;
    var i: usize = 0;
    if (nextWord(ops.arg, &i) > 0) {
        if (std.mem.eql(u8, wordS(), "off")) return;
        if (std.mem.eql(u8, wordS(), "side")) {
            mode = 2;
        } else if (!std.mem.eql(u8, wordS(), "overlay")) {
            id = argRef(wordS());
            if (id == 0) return sayPair(s_nobranch, wordS());
            @memcpy(label[0..31], word[0..31]);
            if (nextWord(ops.arg, &i) > 0 and std.mem.eql(u8, wordS(), "side")) mode = 2;
        }
    }
    if (id == 0 or !commitRead(id) or !mfLoad(cm.manifest, &d_mt) or buildManifest(&d_mo, false, null) == 0)
        return sayPair(s_nobranch, wordS());
    vdBuild(&d_mo, &d_mt);
    view = mode;
    ver +%= 1;
    var b: [64]u8 = undefined;
    say(std.fmt.bufPrint(&b, "  differences: {d}", .{nvd}) catch "");
    for (0..nvd) |k| {
        if (k >= 40) {
            say("  ...");
            break;
        }
        var rb: [200]u8 = undefined;
        say(rowText(k, &rb));
    }
}

fn opMerge() void {
    if (!open()) return say(s_nosave);
    var i: usize = 0;
    if (nextWord(ops.arg, &i) == 0) return;
    const theirs = argRef(wordS());
    if (theirs == 0) return sayPair(s_nobranch, wordS());
    @memcpy(label[0..31], word[0..31]);
    const ours = headId();
    if (ours == 0) return say(s_nocommit);
    if (ours == theirs) return say(s_uptodate);
    const base = mergeBase(ours, theirs);
    if (base == theirs) return say(s_uptodate);
    if (!m_mb.ok() or !m_mo.ok() or !m_mt.ok()) return sayPair(s_bad, cstr(&label));
    m_mb.empty();
    if (base != 0) {
        if (!commitRead(base)) return sayPair(s_bad, cstr(&label));
        if (!mfLoad(cm.manifest, &m_mb)) m_mb.empty();
    }
    if (!commitRead(theirs)) return sayPair(s_bad, cstr(&label));
    const their_scene = cm.scene;
    if (!mfLoad(cm.manifest, &m_mt)) return sayPair(s_bad, cstr(&label));
    if (buildManifest(&m_mo, false, &m_ours) == 0) return sayPair(s_bad, cstr(&label));
    m_theirs_scene = their_scene;
    vdClear();
    ncf = 0;
    mgChunks(their_scene);
    mgObjects();
    mergeid = theirs;
    saveRefs();
    var b: [64]u8 = undefined;
    say(std.fmt.bufPrint(&b, "  merged; conflicts: {d}", .{ncf}) catch "");
    for (0..ncf) |k| {
        var rb: [120]u8 = undefined;
        say(cfRowText(k, &rb));
    }
    app.dirty = true;
}

fn opResolve() void {
    defer app.dirty = true;
    var i: usize = 0;
    if (nextWord(ops.arg, &i) == 0) return;
    var which: ?usize = null; // null: all
    if (!std.mem.eql(u8, wordS(), "all")) {
        const v = std.fmt.parseFloat(f64, wordS()) catch return;
        if (!std.math.isFinite(v) or v < -2147483648.0 or v >= 2147483648.0) return;
        const n: i64 = @as(i64, @intFromFloat(v)) - 1;
        if (n < 0 or n >= ncf) return;
        which = @intCast(n);
    }
    _ = nextWord(ops.arg, &i);
    const side: u32 = if (std.mem.eql(u8, wordS(), "ours")) 1 else if (std.mem.eql(u8, wordS(), "theirs")) 2 else return;
    if (which) |k| return cfSettle(k, side);
    var k: usize = 0;
    while (k < ncf) : (k += 1) cfSettle(k, side);
}

fn opAbort() void {
    if (!open()) return;
    if (mergeid == 0) return;
    const h = headId();
    if (h == 0 or !commitRead(h)) return;
    if (!loadBlob(cm.scene)) return;
    mergeid = 0;
    ncf = 0;
    saveRefs();
    app.dirty = true;
}

// =============================================================================
// Scripts (vcinfo, vctext)
// =============================================================================

/// vc_stat: 0 has a history, 1 commits on the branch, 2 branches, 3 diff
/// rows, 4 added, 5 removed, 6 changed, 7 conflicts, 8 open, 9 merging.
pub fn stat(k: i64) f64 {
    if (!open()) return 0;
    return switch (k) {
        0 => @floatFromInt(@intFromBool(nbr != 0)),
        1 => blk: {
            var id = headId();
            var n: u32 = 0;
            while (id != 0 and n < 10000) {
                if (!commitRead(id)) break;
                n += 1;
                id = cm.parent;
            }
            break :blk @floatFromInt(n);
        },
        2 => @floatFromInt(nbr),
        3 => @floatFromInt(nvd),
        4, 5, 6 => blk: {
            var n: u32 = 0;
            for (vd[0..nvd]) |r| {
                if (r.kind == k - 3) n += 1;
            }
            break :blk @floatFromInt(n);
        },
        7 => @floatFromInt(ncf),
        8 => @floatFromInt(cfOpen()),
        9 => @floatFromInt(@intFromBool(mergeid != 0)),
        else => 0,
    };
}

var text_buf: [260]u8 = undefined;
/// vc_text: 0 the branch, 1 a diff row, 2 a conflict row, 3 the newest
/// commit's message; null when none.
pub fn text(what: i64, row: i64) ?[]const u8 {
    if (!open()) return null;
    switch (what) {
        0 => return headName(),
        1 => {
            if (row < 0 or row >= nvd) return null;
            return rowText(@intCast(row), &text_buf);
        },
        2 => {
            if (row < 0 or row >= ncf) return null;
            return cfRowText(@intCast(row), &text_buf);
        },
        3 => {
            const h = headId();
            if (h == 0 or !commitRead(h)) return null;
            return message();
        },
        else => return null,
    }
}

/// Merging (the refs say so): for the editor.
pub fn merging() bool {
    return mergeid != 0;
}

/// A file is open (the history can live beside it).
pub fn hasFile() bool {
    return open();
}

// =============================================================================
// The viewport: ghosts, the change list, the merge panel (vc_draw, vc_press)
// =============================================================================

/// Moves whenever what vc_draw shows changes (the viewport's cache key).
pub var ver: u32 = 0;
pub fn stateWord() u32 {
    return ver ^ @as(u32, @intCast(nvd)) << 16 ^ @as(u32, @intCast(ncf)) << 4 ^ view;
}

const COL_RED: u32 = 0xe05050;
const COL_YEL_OLD: u32 = 0xe0c040;
const COL_GREY: u32 = 0x8a8f99;
const COL_GREEN: u32 = 0x50d070;
const COL_YEL_NEW: u32 = 0xf0d050;
const COL_PANEL: u32 = 0x1d2027;
const COL_BTN: u32 = 0x3a3f48;
const COL_BTN_ON: u32 = 0x6a5420;

const vpm = @import("viewport.zig");
const gfx = @import("gfx.zig");
const Rect = gfx.Rect;

/// ghost_draw: a mesh's polygons' edges at a transform (loc, rot radians,
/// scale), moved by dx in x; 20000 edges at most.
fn ghostDraw(cv: *gfx.Canvas, c: *const vpm.Cam, verts: []const m.V3, poff: []const u32, loops: []const u32, xf: [9]f32, dx: f32, col: u32) void {
    const d: f32 = m.deg;
    const mtx = m.trs(.{ xf[0] + dx, xf[1], xf[2] }, .{ xf[3] / d, xf[4] / d, xf[5] / d }, .{ xf[6], xf[7], xf[8] });
    var n: usize = 0;
    if (poff.len == 0) return;
    for (0..poff.len - 1) |p| {
        const s0 = poff[p];
        const e0 = poff[p + 1];
        var k = s0;
        while (k < e0) : (k += 1) {
            if (n >= 20000) return;
            const nx = if (k + 1 < e0) k + 1 else s0;
            if (k >= loops.len or nx >= loops.len) return;
            const a = loops[k];
            const b = loops[nx];
            if (a >= verts.len or b >= verts.len) return;
            vpm.line3(cv, c, m.xform(mtx, verts[a]), m.xform(mtx, verts[b]), col);
            n += 1;
        }
    }
}

/// side_offset: past the scene's right side (twice its furthest x + scale, and 1.5).
fn sideOffset() f32 {
    var mx: f32 = -1.0e30;
    for (0..scene.count) |i| {
        const wp = scene.worldPlace(i);
        mx = @max(mx, wp[0] + wp[6]);
    }
    return mx + mx + 1.5;
}

/// vc_draw (the 3D part, in the viewport's pixels): the diff's ghosts.
pub fn draw(cv: *gfx.Canvas, c: *const vpm.Cam) void {
    if (ncf != 0 or view == 0) return;
    const dx: f32 = if (view == 2) sideOffset() else 0;
    for (vd[0..nvd]) |*r| {
        const col: u32 = switch (r.kind) {
            2 => COL_RED,
            3 => COL_YEL_OLD,
            else => continue,
        };
        if (r.ghost == null) r.ghost = ghostLoad(r.mesh);
        const g = r.ghost orelse continue;
        ghostDraw(cv, c, g.verts, g.poff, g.loops, r.xf, dx, col);
    }
    if (view == 2) { // side_rest: the other version's other objects, grey
        for (0..d_mt.nobj()) |k| {
            const e = d_mt.entry(k);
            const uid = rd32(e, MF_UID);
            var in_diff = false;
            for (vd[0..nvd]) |r| {
                if (r.uid == uid) in_diff = true;
            }
            if (in_diff) continue;
            const g = ghostLoad(rd64(e, MF_MESH)) orelse continue;
            defer g.free();
            ghostDraw(cv, c, g.verts, g.poff, g.loops, entryXf(e), dx, COL_GREY);
        }
    }
    // vd_highlight: added (green) and changed (yellow) objects of the scene, in place
    for (vd[0..nvd]) |r| {
        const col: u32 = switch (r.kind) {
            1 => COL_GREEN,
            3 => COL_YEL_NEW,
            else => continue,
        };
        const i = scene.findUid(r.uid) orelse continue;
        const o = &scene.objects[i];
        if (typeCode(o.kind) != 0) continue;
        const mi = o.mesh orelse continue;
        const me = &(scene.meshes[mi] orelse continue);
        ghostDraw(cv, c, me.verts, me.poff, me.loops, scene.worldPlace(i), 0, col);
    }
}

/// The panel's place: vc_px, vc_pw (panel_box).
var px: i32 = 0;
var pw: i32 = 370;
var rows_y: [16]i32 = undefined;
var nrows: usize = 0;

/// vc_draw (the 2D part, Zui's, over the viewport before it takes the
/// pointer): the change list, or the merge panel with its ours / theirs
/// buttons (a press on one settles that conflict).
pub fn panel(z: *zui.Ui, salt: usize, r: Rect) void {
    if (ncf == 0 and view == 0) return;
    const host = @import("zuihost.zig");
    const ui = @import("ui.zig");
    const th = ui.th;
    px = r.x + r.w - 380;
    pw = 370;
    const n: i32 = @intCast(@min(if (ncf != 0) ncf else nvd, 16));
    z.drawRect(.{ .rect = host.zr(.{ .x = px, .y = r.y + 40, .w = pw, .h = n * 18 + 30 }), .fill = host.col(COL_PANEL) });
    var y = r.y + 44;
    var buf: [200]u8 = undefined;
    const panelText = struct {
        fn f(zz: *zui.Ui, x: i32, yy: i32, t: []const u8, c: u32) void {
            zz.drawText(.{ .x = @floatFromInt(x), .y = @floatFromInt(yy) }, host.col(c), t);
        }
    }.f;
    if (ncf != 0) {
        panelText(z, px + 8, y, std.fmt.bufPrint(&buf, "Merge conflicts: {s} ({d} open)", .{ cstr(&label), cfOpen() }) catch "", th.accent);
        y += 20;
        nrows = 0;
        z.pushIdInt(salt);
        defer z.popId();
        for (0..@min(ncf, 16)) |k| {
            rows_y[k] = y;
            nrows = k + 1;
            panelText(z, px + 8, y, cfRowText(k, &buf), th.text);
            const st = cf[k].state;
            const sides = [_]struct { x: i32, l: []const u8, side: u32 }{ .{ .x = px + pw - 110, .l = "ours", .side = 1 }, .{ .x = px + pw - 55, .l = "theirs", .side = 2 } };
            for (sides) |sd| {
                const br = Rect{ .x = sd.x, .y = y, .w = 50, .h = 16 };
                z.pushIdInt(k * 2 + sd.side);
                const it = z.interact(z.id("##side"), host.zr(.{ .x = sd.x, .y = y, .w = 55, .h = 18 }));
                z.popId();
                z.drawRect(.{ .rect = host.zr(br), .fill = host.col(if (st == sd.side) COL_BTN_ON else if (it.hovered) COL_BTN + 0x101010 else COL_BTN) });
                panelText(z, sd.x + 6, y, sd.l, th.text);
                ui.record("button", sd.l, .{ .x = sd.x, .y = y, .w = 55, .h = 18 }, true);
                if (it.pressed) {
                    cfSettle(k, sd.side);
                    @import("undo.zig").label("Resolve Conflict");
                    ver +%= 1;
                    app.dirty = true;
                }
            }
            y += 18;
        }
        return;
    }
    panelText(z, px + 8, y, std.fmt.bufPrint(&buf, "Changes against {s}", .{cstr(&label)}) catch "", th.accent);
    y += 20;
    for (0..@min(nvd, 16)) |k| {
        const col: u32 = switch (vd[k].kind) {
            1 => 0x60d080,
            2 => 0xf07070,
            else => 0xf0d060,
        };
        panelText(z, px + 8, y, rowText(k, &buf), col);
        y += 18;
    }
}

/// vc_press: a press on the merge panel's buttons (true: taken). "ours" is
/// the last 110 px but 55 of a row, "theirs" from there on.
pub fn press(x: i32, y: i32) bool {
    if (ncf == 0) return false;
    for (rows_y[0..nrows], 0..) |ry, k| {
        if (y < ry or y >= ry + 18) continue;
        const bx = px + pw - 110;
        if (x < bx) continue;
        cfSettle(k, if (x < bx + 55) 1 else 2);
        @import("undo.zig").label("Resolve Conflict");
        ver +%= 1;
        app.dirty = true;
        return true;
    }
    return false;
}

const Impl = ops.Impl;
pub const list = .{
    .{ "vc.commit", Impl{ .run = opCommit } },
    .{ "vc.log", Impl{ .run = opLog } },
    .{ "vc.branch", Impl{ .run = opBranch } },
    .{ "vc.switch", Impl{ .run = opSwitch } },
    .{ "vc.diff", Impl{ .run = opDiff } },
    .{ "vc.merge", Impl{ .run = opMerge } },
    .{ "vc.resolve", Impl{ .run = opResolve } },
    .{ "vc.abort", Impl{ .run = opAbort } },
};

// =============================================================================
// Tests
// =============================================================================

test "vc_hash: the original's names (an empty chunk, a commit of its)" {
    try std.testing.expectEqual(@as(u64, 0xecba3df2c3383c52), vcHash(""));
    try std.testing.expectEqual(@as(u64, 0xf120aee01df30dab), vcHash("abc"));
    const c = "scene 67eaec315a049f0e\nmanifest c6131e829a0ae0f3\ntime 000000006af6c254\nmessage first\n";
    try std.testing.expectEqual(@as(u64, 0x0eed9e3a48e91496), vcHash(c));
    var hx: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0eed9e3a48e91496", hexq(0x0eed9e3a48e91496, &hx));
}

test "a commit's text read as the original reads it" {
    parseCommit("scene 67eaec315a049f0e\nmanifest c6131e829a0ae0f3\nparent 0000000000000001\nparent 00000000000000ff\nparent 0000000000000abc\ntime 000000006af6c254\nmessage first line\nmessage  second");
    try std.testing.expectEqual(@as(u64, 0x67eaec315a049f0e), cm.scene);
    try std.testing.expectEqual(@as(u64, 0xc6131e829a0ae0f3), cm.manifest);
    try std.testing.expectEqual(@as(u64, 1), cm.parent);
    try std.testing.expectEqual(@as(u64, 0xabc), cm.parent2); // (a third overwrites the second)
    try std.testing.expectEqual(@as(u64, 0x6af6c254), cm.time);
    try std.testing.expectEqualStrings("second", message()); // (the last, leading spaces skipped)
}

test "refs: read, written back the same; names cut to 31" {
    parseRefs("head idea\nbranch main e16be2ca28ddf0ca\nbranch idea cc496ffda12fbccd\nmerge 0000000000000007\njunk line\n");
    try std.testing.expectEqualStrings("idea", headName());
    try std.testing.expectEqual(@as(u32, 2), nbr);
    try std.testing.expectEqual(@as(u64, 0xcc496ffda12fbccd), brid[1]);
    try std.testing.expectEqual(@as(u64, 7), mergeid);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(A);
    try refsText(&out);
    try std.testing.expectEqualStrings("head idea\nbranch main e16be2ca28ddf0ca\nbranch idea cc496ffda12fbccd\nmerge 0000000000000007\n", out.items);
    nbr = 0;
    mergeid = 0;
    parseRefs("head abcdefghijklmnopqrstuvwxyz0123456789\n");
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz01234", headName());
    head = initName("main");
}

test "a damaged mesh blob is no mesh" {
    var b: [20 + 12 * 3 + 8 + 12]u8 = @splat(0);
    wr32(&b, 4, 3);
    wr32(&b, 8, 1);
    wr32(&b, 12, 3);
    wr32(&b, 20 + 36, 0);
    wr32(&b, 20 + 40, 3);
    wr32(&b, 20 + 44, 0);
    wr32(&b, 20 + 48, 1);
    wr32(&b, 20 + 52, 7); // (past the vertices)
    try std.testing.expect(meshFromBlob(&b) == null);
    try std.testing.expect(meshFromBlob(b[0..30]) == null);
}
