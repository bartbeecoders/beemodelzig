//! OpenUSD layers in memory (usdlayer.s, usd.inc), filled by the crate reader
//! (usdc.zig) and the text reader (usda.zig), composed by usd.zig.
//!
//! A layer is its paths (full path text, interned: "/", "/Root/Mesh",
//! "/Root/Mesh.points", variant selections "/Root{set=sel}"), its specs (one
//! per path that has one: prim, attribute, relationship ...) and each spec's
//! fields, a list of (name, value). Values are kept in a few plain forms
//! whatever the file said: integers, doubles, text, small vectors of doubles,
//! float or int arrays, lists of text, reference lists and variant
//! selections. Everything lives in the layer's arena and goes with it (free).
//! file.usd_dump writes it all as text (tests/usd.py compares it with
//! OpenUSD's reading of the same file).
const std = @import("std");
const linux = std.os.linux;

pub const UK_ROOT: u32 = 0;
pub const UK_PRIM: u32 = 1;
pub const UK_PROP: u32 = 2;
pub const UK_VARIANT: u32 = 3;

pub const SPEC_ATTR: u32 = 1;
pub const SPEC_CONN: u32 = 2;
pub const SPEC_PRIM: u32 = 6;
pub const SPEC_ROOT: u32 = 7;
pub const SPEC_REL: u32 = 8;
pub const SPEC_RELTGT: u32 = 9;
pub const SPEC_VARIANT: u32 = 10;
pub const SPEC_VARSET: u32 = 11;

pub const UT_NONE: u32 = 0; // blocked, or a kind not kept (dictionaries ...)
pub const UT_INT: u32 = 1; // bool, ints, enums (specifier, variability)
pub const UT_DBL: u32 = 2; // half, float, double, time code
pub const UT_STR: u32 = 3; // token, string, asset path
pub const UT_VEC: u32 = 4; // N doubles: vectors, quaternions (x y z w), matrices
pub const UT_FARR: u32 = 5; // N elements of X floats (float32)
pub const UT_IARR: u32 = 6; // N elements of X int32s
pub const UT_SLIST: u32 = 7; // N texts: tokens, strings, paths, list ops of them
pub const UT_RLIST: u32 = 8; // N (asset, prim path) pairs: references, payloads
pub const UT_VSEL: u32 = 9; // N (variant set, selection) pairs
/// (the text reader's lone metadata string: a value whose kind is not one of
/// these; the dump says "?" as the original's does for it)
pub const UT_ODD: u32 = 0xffffffff;

/// A text in a layer, or none (a crate path number that names no path).
pub const Str = ?[*:0]const u8;

/// A value (UV_*): `p` is the data's address (text, doubles, floats, int32s,
/// text pointers), `d` a scalar's bits (int64 or double).
pub const Value = extern struct {
    t: u32 = UT_NONE,
    x: u32 = 0,
    n: u64 = 0,
    p: usize = 0,
    d: u64 = 0,

    pub fn int(v: *const Value) i64 {
        return @bitCast(v.d);
    }
    pub fn dbl(v: *const Value) f64 {
        return @bitCast(v.d);
    }
    pub fn str(v: *const Value) [*:0]const u8 {
        return if (v.p == 0) "" else @ptrFromInt(v.p);
    }
    pub fn vec(v: *const Value) []align(1) f64 {
        if (v.n == 0 or v.p == 0) return &.{};
        return @as([*]align(1) f64, @ptrFromInt(v.p))[0..v.n];
    }
    /// floats of a UT_FARR (n x x of them)
    pub fn farr(v: *const Value) []align(1) const f32 {
        const k = v.n * v.x;
        if (k == 0 or v.p == 0) return &.{};
        return @as([*]align(1) const f32, @ptrFromInt(v.p))[0..k];
    }
    /// ints of a UT_IARR (n x x of them)
    pub fn iarr(v: *const Value) []align(1) const i32 {
        const k = v.n * v.x;
        if (k == 0 or v.p == 0) return &.{};
        return @as([*]align(1) const i32, @ptrFromInt(v.p))[0..k];
    }
    /// texts of a list: n of them (UT_SLIST), 2n (pairs)
    pub fn texts(v: *const Value) []Str {
        const k = if (v.t == UT_SLIST) v.n else v.n * 2;
        if (k == 0 or v.p == 0) return &.{};
        return @as([*]Str, @ptrFromInt(v.p))[0..k];
    }
};

pub const Path = struct {
    str: [*:0]const u8,
    spec: i32 = -1,
    next: i32 = -1,
    parent: i32 = -1,
    kind: u32 = 0,
};

pub const Spec = struct {
    path: u32,
    typ: u32 = 0,
    first: i32 = -1,
    last: i32 = -1,
};

pub const Field = struct {
    name: [*:0]const u8,
    val: *Value,
    next: i32 = -1,
};

// ---- the arena (vmap'd chunks: zero, never touched until used) ---------------------------

const CHUNK: usize = 1048576; // (bigger asks: their own)
const HDR: usize = 16;

/// Fresh pages from the kernel (zero), or null.
pub fn vmap(n: usize) ?[*]align(4096) u8 {
    if (n == 0) return null;
    const r = linux.mmap(null, n, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(r) != .SUCCESS) return null;
    return @ptrFromInt(r);
}
pub fn vunmap(p: ?[*]align(4096) u8, n: usize) void {
    if (p) |q| {
        if (n > 0) _ = linux.munmap(q, n);
    }
}

pub const Arena = struct {
    cur: usize = 0,
    end: usize = 0,
    chunk: usize = 0, // the chunks: (next, bytes) at their start

    /// `n` bytes, zero, 8-aligned (null: no memory).
    pub fn alloc(ar: *Arena, n0: usize) ?[*]u8 {
        const n = std.math.add(usize, n0, 7) catch return null;
        const sz = n & ~@as(usize, 7);
        if (ar.cur != 0 and ar.end - ar.cur >= sz) {
            const r = ar.cur;
            ar.cur += sz;
            return @ptrFromInt(r);
        }
        const want = std.math.add(usize, sz, HDR) catch return null;
        const bytes = if (want > CHUNK / 4) want else CHUNK;
        const m = vmap(bytes) orelse return null;
        const h: [*]usize = @ptrCast(m);
        h[0] = ar.chunk;
        h[1] = bytes;
        ar.chunk = @intFromPtr(m);
        const d = @intFromPtr(m) + HDR;
        if (bytes == CHUNK) {
            ar.cur = d + sz;
            ar.end = @intFromPtr(m) + bytes;
        }
        return @ptrFromInt(d);
    }

    pub fn free(ar: *Arena) void {
        var c = ar.chunk;
        while (c != 0) {
            const h: [*]usize = @ptrFromInt(c);
            const nx = h[0];
            vunmap(@ptrFromInt(c), h[1]);
            c = nx;
        }
        ar.* = .{};
    }

    /// A copy of the bytes, 0-ended.
    pub fn dup(ar: *Arena, s: []const u8) ?[*:0]u8 {
        const p = ar.alloc(s.len + 1) orelse return null;
        @memcpy(p[0..s.len], s);
        p[s.len] = 0;
        return @ptrCast(p);
    }

    pub fn val(ar: *Arena) ?*Value {
        const p = ar.alloc(@sizeOf(Value)) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    /// n items of T, zero (8-aligned memory)
    pub fn many(ar: *Arena, comptime T: type, n: usize) ?[*]T {
        const b = std.math.mul(usize, n, @sizeOf(T)) catch return null;
        const p = ar.alloc(b) orelse return null;
        return @ptrCast(@alignCast(p));
    }
};

// ---- files ---------------------------------------------------------------------------

/// file_read: the file mapped (null: it cannot be read, or it is empty).
pub fn mapFile(fpath: []const u8) ?[]const u8 {
    var buf: [4097]u8 = undefined;
    if (fpath.len >= buf.len) return null;
    @memcpy(buf[0..fpath.len], fpath);
    buf[fpath.len] = 0;
    const p: [*:0]const u8 = @ptrCast(&buf);
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size) != .SUCCESS or size == 0) return null;
    const mp = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(mp) != .SUCCESS) return null;
    const ptr: [*]const u8 = @ptrFromInt(mp);
    return ptr[0..size];
}

pub fn unmapFile(d: []const u8) void {
    _ = linux.munmap(d.ptr, d.len);
}

pub fn cstr(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}

pub fn eq(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        if (a[i] != b[i]) return false;
        if (a[i] == 0) return true;
    }
}

// ---- the layer ---------------------------------------------------------------------

pub const Layer = struct {
    ar: Arena = .{},
    paths: []Path = &.{},
    npath: u32 = 0,
    hash: []i32 = &.{},
    hmask: u32 = 0,
    specs: []Spec = &.{},
    nspec: u32 = 0,
    flds: []Field = &.{},
    nfld: u32 = 0,
    map: ?[]const u8 = null, // the file's mapping (crate arrays point into it)
    file: [*:0]const u8 = "", // the file's path

    pub fn pathStr(l: *const Layer, i: u32) [*:0]const u8 {
        return l.paths[i].str;
    }
};

/// ul_new: an empty layer (null: no memory).
pub fn new() ?*Layer {
    const m = vmap(@sizeOf(Layer)) orelse return null;
    const l: *Layer = @ptrCast(@alignCast(m));
    l.* = .{};
    return l;
}

fn freeArr(comptime T: type, s: []T) void {
    if (s.len > 0) vunmap(@ptrCast(@alignCast(s.ptr)), std.mem.alignForward(usize, s.len * @sizeOf(T), 4096));
}

/// ul_free: the layer, its arena, arrays and file mapping.
pub fn free(l0: ?*Layer) void {
    const l = l0 orelse return;
    l.ar.free();
    freeArr(Path, l.paths);
    freeArr(i32, l.hash);
    freeArr(Spec, l.specs);
    freeArr(Field, l.flds);
    if (l.map) |d| unmapFile(d);
    vunmap(@ptrCast(@alignCast(l)), @sizeOf(Layer));
}

/// ul_room: one more element fits (the array doubled, at least 256).
fn room(comptime T: type, arr: *[]T, n: u32) bool {
    if (n < arr.len) return true;
    const cap = @max(arr.len * 2, 256);
    const bytes = std.mem.alignForward(usize, cap * @sizeOf(T), 4096);
    const m = vmap(bytes) orelse return false;
    const na: [*]T = @ptrCast(@alignCast(m));
    const cap2 = bytes / @sizeOf(T);
    if (n > 0) @memcpy(na[0..n], arr.*[0..n]);
    freeArr(T, arr.*);
    arr.* = na[0..cap2];
    return true;
}

/// FNV-1a of a text, and its length.
pub fn hashOf(s: [*:0]const u8) u32 {
    var h: u32 = 0x811c9dc5;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        h ^= s[i];
        h *%= 0x01000193;
    }
    return h;
}

fn rehash(l: *Layer) bool {
    const heads: usize = @max(@as(usize, l.hmask) * 2 + 2, 1024);
    const bytes = std.mem.alignForward(usize, heads * 4, 4096);
    const m = vmap(bytes) orelse return false;
    const h: [*]i32 = @ptrCast(@alignCast(m));
    @memset(h[0..heads], -1);
    freeArr(i32, l.hash);
    l.hash = h[0..heads];
    l.hmask = @intCast(heads - 1);
    for (l.paths[0..l.npath], 0..) |*p, i| {
        const k = hashOf(p.str) & l.hmask;
        p.next = h[k];
        h[k] = @intCast(i);
    }
    return true;
}

/// ul_find: a path's number, or null.
pub fn find(l: *const Layer, s: [*:0]const u8) ?u32 {
    if (l.hash.len == 0) return null;
    var i = l.hash[hashOf(s) & l.hmask];
    while (i >= 0) {
        const p = &l.paths[@intCast(i)];
        if (eq(p.str, s)) return @intCast(i);
        i = p.next;
    }
    return null;
}

/// ul_path: the path (an existing one, or added: its text copied), null when
/// out of memory.
pub fn path(l: *Layer, s: [*:0]const u8, parent: i32, kind: u32) ?u32 {
    if (find(l, s)) |i| return i;
    const want = @as(u64, l.npath) * 2 + 2;
    if (l.hash.len == 0 or want > l.hmask) {
        if (!rehash(l)) return null;
    }
    if (!room(Path, &l.paths, l.npath)) return null;
    const h = hashOf(s);
    const t = l.ar.dup(cstr(s)) orelse return null;
    const i = l.npath;
    const k = h & l.hmask;
    l.paths[i] = .{ .str = t, .spec = -1, .parent = parent, .kind = kind, .next = l.hash[k] };
    l.hash[k] = @intCast(i);
    l.npath += 1;
    return i;
}

/// ul_spec: the path's spec (made when it has none; the type set either way),
/// null: out of memory.
pub fn spec(l: *Layer, p: u32, typ: u32) ?u32 {
    var s = l.paths[p].spec;
    if (s < 0) {
        if (!room(Spec, &l.specs, l.nspec)) return null;
        s = @intCast(l.nspec);
        l.specs[l.nspec] = .{ .path = p };
        l.nspec += 1;
        l.paths[p].spec = s;
    }
    l.specs[@intCast(s)].typ = typ;
    return @intCast(s);
}

/// ul_spec_of: the spec at a path's text, or null.
pub fn specOf(l: *const Layer, s: [*:0]const u8) ?u32 {
    const p = find(l, s) orelse return null;
    const k = l.paths[p].spec;
    return if (k < 0) null else @intCast(k);
}

fn getRec(l: *const Layer, s: u32, name: [*:0]const u8) ?*Field {
    var f = l.specs[s].first;
    while (f >= 0) {
        const r = &l.flds[@intCast(f)];
        if (eq(r.name, name)) return r;
        f = r.next;
    }
    return null;
}

/// ul_field: added at the end of the spec's fields; a name already there is
/// replaced (the text format may say it twice).
pub fn field(l: *Layer, s: u32, name: [*:0]const u8, v: *Value) void {
    if (getRec(l, s, name)) |r| {
        r.val = v;
        return;
    }
    if (!room(Field, &l.flds, l.nfld)) return;
    const i = l.nfld;
    l.flds[i] = .{ .name = name, .val = v };
    l.nfld += 1;
    const sp = &l.specs[s];
    const last = sp.last;
    sp.last = @intCast(i);
    if (last < 0) sp.first = @intCast(i) else l.flds[@intCast(last)].next = @intCast(i);
}

/// ul_get: a spec's value of a field, or null.
pub fn get(l: *const Layer, s: u32, name: [*:0]const u8) ?*Value {
    const r = getRec(l, s, name) orelse return null;
    return r.val;
}

// ---- the dump ------------------------------------------------------------------------

/// cvtsd2si (64-bit): to the nearest, ties to even; out of range or NaN: the
/// minimum.
pub fn cvtsd2si(x: f64) i64 {
    if (!(x > -9223372036854775808.0 and x < 9223372036854775808.0)) return std.math.minInt(i64);
    var r = @floor(x);
    const diff = x - r;
    if (diff > 0.5 or (diff == 0.5 and @mod(r, 2.0) == 1.0)) r += 1;
    if (!(r < 9223372036854775808.0)) return std.math.minInt(i64);
    return @intFromFloat(r);
}

/// cvttsd2si (64-bit): truncated; out of range or NaN: the minimum.
pub fn cvtt(x: f64) i64 {
    if (!(x > -9223372036854777856.0 and x < 9223372036854775808.0)) return std.math.minInt(i64);
    return @intFromFloat(x);
}

const W = std.ArrayList(u8);
const A = std.heap.page_allocator;

fn wInt(o: *W, v: i64) void {
    o.print(A, "{d}", .{v}) catch {};
}
/// x 10000, rounded to the nearest (even), as an integer
fn wDbl(o: *W, x: f64) void {
    wInt(o, cvtsd2si(x * 10000.0));
}
fn wText(o: *W, s: Str) void {
    if (s) |t| o.appendSlice(A, cstr(t)) catch {};
}

fn dumpValue(o: *W, v0: ?*const Value) void {
    const v = v0 orelse return o.appendSlice(A, "none") catch {};
    switch (v.t) {
        UT_NONE => o.appendSlice(A, "none") catch {},
        UT_INT => {
            o.appendSlice(A, "i ") catch {};
            wInt(o, v.int());
        },
        UT_DBL => {
            o.appendSlice(A, "d ") catch {};
            wDbl(o, v.dbl());
        },
        UT_STR => {
            o.appendSlice(A, "s ") catch {};
            o.appendSlice(A, cstr(v.str())) catch {};
        },
        UT_VEC => {
            o.appendSlice(A, "v ") catch {};
            wInt(o, @bitCast(v.n));
            for (v.vec()) |x| {
                o.append(A, ' ') catch {};
                wDbl(o, x);
            }
        },
        UT_FARR, UT_IARR => {
            o.appendSlice(A, if (v.t == UT_FARR) "f " else "a ") catch {};
            wInt(o, @bitCast(v.n));
            o.append(A, ' ') catch {};
            wInt(o, v.x);
            if (v.t == UT_IARR) {
                var s: i64 = 0;
                var sa: i64 = 0;
                for (v.iarr()) |x| {
                    s +%= x;
                    sa +%= if (x < 0) -@as(i64, x) else x;
                }
                o.append(A, ' ') catch {};
                wInt(o, s);
                o.append(A, ' ') catch {};
                wInt(o, sa);
            } else {
                var s: f64 = 0;
                var sa: f64 = 0;
                for (v.farr()) |x| {
                    const d: f64 = x;
                    s += d;
                    sa += @abs(d);
                }
                o.append(A, ' ') catch {};
                wDbl(o, s);
                o.append(A, ' ') catch {};
                wDbl(o, sa);
            }
        },
        UT_SLIST, UT_RLIST, UT_VSEL => {
            const tag: u8 = if (v.t == UT_SLIST) 'l' else if (v.t == UT_RLIST) 'r' else 'm';
            o.append(A, tag) catch {};
            o.append(A, ' ') catch {};
            wInt(o, @bitCast(v.n));
            o.append(A, ' ') catch {};
            const t = v.texts();
            var k: usize = 0;
            while (k < v.n) : (k += 1) {
                if (k > 0) o.append(A, '|') catch {};
                if (tag == 'l') {
                    if (k < t.len) wText(o, t[k]);
                } else if (k * 2 + 1 < t.len) {
                    wText(o, t[k * 2]);
                    o.append(A, if (tag == 'r') '>' else '=') catch {};
                    wText(o, t[k * 2 + 1]);
                }
            }
        },
        else => o.appendSlice(A, "?") catch {},
    }
}

/// usd_dump: a line per field, "path TAB field TAB value"; values: "i n",
/// "d n" (x 10000, rounded), "s text", "v k n n ..", "f n x sum abs" (floats:
/// sums x 10000), "a n x sum abs" (ints), "l n a|b|..", "r n asset>path|..",
/// "m n set=sel|..", "none". The text (the caller frees it).
pub fn dumpText(l: *const Layer) W {
    var o: W = .empty;
    for (l.specs[0..l.nspec]) |*sp| {
        var f = sp.first;
        while (f >= 0) {
            const r = &l.flds[@intCast(f)];
            o.appendSlice(A, cstr(l.paths[sp.path].str)) catch {};
            o.append(A, 9) catch {};
            o.appendSlice(A, cstr(r.name)) catch {};
            o.append(A, 9) catch {};
            dumpValue(&o, r.val);
            o.append(A, 10) catch {};
            f = r.next;
        }
    }
    return o;
}

/// usd_dump(layer, out path): true written.
pub fn dump(l: *const Layer, out: []const u8) bool {
    var o = dumpText(l);
    defer o.deinit(A);
    @import("atomicfile.zig").write(out, o.items) catch return false;
    return true;
}

test "layer: paths interned, specs, fields replaced, the dump's forms" {
    const l = new() orelse return error.NoMem;
    defer free(l);
    const r = path(l, "/", -1, UK_ROOT).?;
    const a = path(l, "/A", @intCast(r), UK_PRIM).?;
    try std.testing.expectEqual(a, path(l, "/A", @intCast(r), UK_PRIM).?);
    try std.testing.expectEqual(@as(?u32, a), find(l, "/A"));
    try std.testing.expectEqual(@as(?u32, null), find(l, "/B"));
    const s = spec(l, a, SPEC_PRIM).?;
    const v = l.ar.val().?;
    v.t = UT_INT;
    v.d = @bitCast(@as(i64, -3));
    field(l, s, "specifier", v);
    const w = l.ar.val().?;
    w.t = UT_DBL;
    w.d = @bitCast(@as(f64, 1.25));
    field(l, s, "x", w);
    field(l, s, "specifier", w); // replaced in place
    var o = dumpText(l);
    defer o.deinit(A);
    try std.testing.expectEqualStrings("/A\tspecifier\td 12500\n/A\tx\td 12500\n", o.items);
    // many paths: the heads grow, every one still found
    var b: [32]u8 = undefined;
    for (0..5000) |i| _ = path(l, (std.fmt.bufPrintSentinel(&b, "/P{d}", .{i}, 0) catch unreachable).ptr, 0, UK_PRIM).?;
    for (0..5000) |i| try std.testing.expect(find(l, (std.fmt.bufPrintSentinel(&b, "/P{d}", .{i}, 0) catch unreachable).ptr) != null);
    try std.testing.expectEqual(@as(i64, 2), cvtsd2si(2.5));
    try std.testing.expectEqual(@as(i64, 4), cvtsd2si(3.5));
    try std.testing.expectEqual(@as(i64, -2), cvtsd2si(-2.5));
    try std.testing.expectEqual(std.math.minInt(i64), cvtsd2si(std.math.nan(f64)));
    try std.testing.expectEqual(std.math.minInt(i64), cvtsd2si(1e300));
}
