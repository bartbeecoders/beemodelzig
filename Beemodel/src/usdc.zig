//! OpenUSD crate files (.usdc, binary .usd) read natively into a layer
//! (usdlayer.zig), as usdc.s reads them.
//!
//! The file: "PXR-USDC", a version (0.4 .. 0.x), the table of contents'
//! offset; the table names sections:
//!   TOKENS     every token, 0-separated, LZ4-compressed
//!   STRINGS    strings as token numbers
//!   FIELDS     each field's token and value (a 64-bit value rep)
//!   FIELDSETS  the fields of each spec, runs ended by -1
//!   PATHS      the path tree: path numbers, element tokens (negative: a
//!              property), jumps (-2 leaf, -1 child only, 0 sibling next,
//!              n: the sibling n further on, the child next)
//!   SPECS      each spec's path, field set and type
//! Integer runs are "compressed ints": LZ4 over 2-bit codes (common delta,
//! small, medium, large) and the deltas themselves. LZ4 is TfFastCompression:
//! a chunk count, then each chunk's size and its LZ4 block (0: one block).
//!
//! A value rep: 48 bits of payload, the type (8 bits), flags: array (63),
//! inlined (62: the payload is the value - small ints, floats, token numbers,
//! vectors of int8), compressed (61: int and float arrays). Others sit at the
//! payload's file offset. Kept: scalars, text, vectors and matrices, arrays
//! (float32 and int32 ones point into the file), token / string / path vectors
//! and list ops, references and payloads, variant selections. Dictionaries
//! and time samples are left out (UT_NONE).
const std = @import("std");
const ul = @import("usdlayer.zig");
const Layer = ul.Layer;
const Value = ul.Value;
const Str = ul.Str;

pub const MAGIC: u64 = 0x434453552d525850; // "PXR-USDC"

/// Why the last read failed.
pub var err: []const u8 = "";
pub const e_open = "cannot read the file";
pub const e_magic = "not a USD crate file";
pub const e_ver = "a crate version this reader does not know (0.4 .. 0.x)";
pub const e_dmg = "the crate file is damaged";
pub const e_mem = "out of memory";

const UE_NONE: u8 = 0;
const UE_I32: u8 = 1;
const UE_I64: u8 = 2;
const UE_U8: u8 = 3;
const UE_F16: u8 = 4;
const UE_F32: u8 = 5;
const UE_F64: u8 = 6;
const UE_TOK: u8 = 7;
const UE_STR: u8 = 8;

/// per crate type (0 .. 56): components, element kind
const types = blk: {
    var t: [57][2]u8 = @splat(.{ 0, UE_NONE });
    t[1] = .{ 1, UE_U8 }; // bool
    t[2] = .{ 1, UE_U8 }; // uchar
    t[3] = .{ 1, UE_I32 }; // int
    t[4] = .{ 1, UE_I32 }; // uint
    t[5] = .{ 1, UE_I64 }; // int64
    t[6] = .{ 1, UE_I64 }; // uint64
    t[7] = .{ 1, UE_F16 }; // half
    t[8] = .{ 1, UE_F32 }; // float
    t[9] = .{ 1, UE_F64 }; // double
    t[10] = .{ 1, UE_STR }; // string
    t[11] = .{ 1, UE_TOK }; // token
    t[12] = .{ 1, UE_TOK }; // asset path
    t[13] = .{ 4, UE_F64 }; // matrix2d
    t[14] = .{ 9, UE_F64 }; // matrix3d
    t[15] = .{ 16, UE_F64 }; // matrix4d
    t[16] = .{ 4, UE_F64 }; // quatd
    t[17] = .{ 4, UE_F32 }; // quatf
    t[18] = .{ 4, UE_F16 }; // quath
    t[19] = .{ 2, UE_F64 };
    t[20] = .{ 2, UE_F32 };
    t[21] = .{ 2, UE_F16 };
    t[22] = .{ 2, UE_I32 };
    t[23] = .{ 3, UE_F64 };
    t[24] = .{ 3, UE_F32 };
    t[25] = .{ 3, UE_F16 };
    t[26] = .{ 3, UE_I32 };
    t[27] = .{ 4, UE_F64 };
    t[28] = .{ 4, UE_F32 };
    t[29] = .{ 4, UE_F16 };
    t[30] = .{ 4, UE_I32 };
    break :blk t;
};
const NTYPES = 57;

const empty: [*:0]const u8 = "";

/// The reader's state (usdc.s's uc_*).
const C = struct {
    map: []const u8,
    ver: u32 = 0,
    bad: bool = false,
    cur: u64 = 0,
    lay: *Layer,
    toc: u64 = 0,
    nsec: u64 = 0,
    tok: [*][*:0]const u8 = undefined,
    ntok: u64 = 0,
    str: [*][*:0]const u8 = undefined,
    nstr: u64 = 0,
    ftok: [*]align(1) const u32 = undefined,
    reps: [*]align(1) const u64 = undefined,
    nf: u64 = 0,
    fset: [*]align(1) const u32 = undefined,
    nfset: u64 = 0,
    cpath: [*]i32 = undefined,
    npath: u64 = 0,
    pbuf: [4096]u8 = undefined,

    // ---- reading at the cursor, within the file ----
    /// `n` bytes at the cursor (moved on), null when past the end (bad set)
    fn ptr(c: *C, n: u64) ?[*]const u8 {
        const size: u64 = c.map.len;
        if (c.cur > size or n > size - c.cur) {
            c.bad = true;
            return null;
        }
        const p = c.map.ptr + c.cur;
        c.cur += n;
        return p;
    }
    fn u64_(c: *C) u64 {
        const p = c.ptr(8) orelse return 0;
        return std.mem.readInt(u64, p[0..8], .little);
    }
    fn u32_(c: *C) u32 {
        const p = c.ptr(4) orelse return 0;
        return std.mem.readInt(u32, p[0..4], .little);
    }
    fn u8_(c: *C) u32 {
        const p = c.ptr(1) orelse return 0;
        return p[0];
    }
    /// an array's element count (u64 from 0.7, u32 before)
    fn count(c: *C) u64 {
        return if (c.ver >= 0x000700) c.u64_() else c.u32_();
    }

    /// the cursor at a section's start: false, none
    fn sec(c: *C, name: []const u8) bool {
        var k: u64 = 0;
        while (k < c.nsec) : (k += 1) {
            const e = c.map[c.toc + k * 32 ..][0..32];
            if (nameEq(e[0..16], name)) {
                c.cur = std.mem.readInt(u64, e[16..24], .little);
                return true;
            }
        }
        return false;
    }

    fn tokn(c: *const C, i: u64) [*:0]const u8 {
        return if (i < c.ntok) c.tok[i] else empty;
    }
    fn strn(c: *const C, i: u64) [*:0]const u8 {
        return if (i < c.nstr) c.str[i] else empty;
    }
    /// a crate path number's text, null: none (the empty path)
    fn pathn(c: *const C, i: u64) Str {
        if (i >= c.npath) return null;
        const p = c.cpath[i];
        if (p < 0) return null;
        return c.lay.paths[@intCast(p)].str;
    }
};

fn nameEq(e: *const [16]u8, s: []const u8) bool {
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const a: u8 = if (i < s.len) s[i] else 0;
        if (a != e[i]) return false;
        if (a == 0) return true;
    }
    return true;
}

// ---- LZ4 ---------------------------------------------------------------------------------

/// An LZ4 block into dst: the bytes out, null when damaged.
pub fn lz4Block(src: []const u8, dst: []u8) ?usize {
    var si: usize = 0;
    var di: usize = 0;
    while (si < src.len) {
        const tok = src[si];
        si += 1;
        var lit: usize = tok >> 4;
        if (lit == 15) {
            while (true) {
                if (si >= src.len) return null;
                const b = src[si];
                si += 1;
                lit += b;
                if (b != 255) break;
            }
        }
        if (lit > src.len - si) return null;
        if (lit > dst.len - di) return null;
        @memcpy(dst[di..][0..lit], src[si..][0..lit]);
        si += lit;
        di += lit;
        if (si >= src.len) break; // (the last sequence: literals only)
        if (si + 2 > src.len) return null;
        const off: usize = @as(usize, src[si]) | @as(usize, src[si + 1]) << 8;
        si += 2;
        if (off == 0 or off > di) return null;
        var ml: usize = tok & 15;
        if (ml == 15) {
            while (true) {
                if (si >= src.len) return null;
                const b = src[si];
                si += 1;
                ml += b;
                if (b != 255) break;
            }
        }
        ml += 4;
        if (ml > dst.len - di) return null;
        var k: usize = 0;
        while (k < ml) : (k += 1) dst[di + k] = dst[di - off + k]; // (overlapping runs repeat, as wanted)
        di += ml;
    }
    return di;
}

/// TfFastCompression - a chunk count (0: one block), each chunk's size: the
/// bytes out, null.
pub fn fast(src: []const u8, dst: []u8) ?usize {
    if (src.len == 0) return null;
    const n = src[0];
    const s = src[1..];
    if (n == 0) return lz4Block(s, dst);
    var si: usize = 0;
    var di: usize = 0;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        if (si + 4 > s.len) return null;
        const sz: i32 = std.mem.readInt(i32, s[si..][0..4], .little);
        si += 4;
        if (sz < 0) return null;
        const z: usize = @intCast(sz);
        if (z > s.len - si) return null;
        const r = lz4Block(s[si..][0..z], dst[di..]) orelse return null;
        si += z;
        di += r;
    }
    return di;
}

// ---- compressed ints ----------------------------------------------------------------------

/// common value, then 2 bits a value (low bits first: 0 common, 1 small,
/// 2 medium, 3 large: 8/16/32 bits, or 16/32/64 when wide), then the deltas;
/// each value is the last one plus its delta. False: damaged.
fn decode(w: []const u8, n: u32, wide: bool, out: [*]u8) bool {
    const cs: usize = if (wide) 8 else 4;
    const codes = cs;
    var p: usize = codes + (@as(usize, n) * 2 + 7) / 8;
    if (p > w.len) return false;
    const common: i64 = if (wide) std.mem.readInt(i64, w[0..8], .little) else std.mem.readInt(i32, w[0..4], .little);
    var prev: i64 = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const code = (w[codes + k / 4] >> @intCast((k & 3) * 2)) & 3;
        var d: i64 = undefined;
        if (code == 0) {
            d = common;
        } else if (!wide) {
            const sz: usize = if (code == 1) 1 else if (code == 2) 2 else 4;
            if (p + sz > w.len) return false;
            d = switch (sz) {
                1 => @as(i8, @bitCast(w[p])),
                2 => std.mem.readInt(i16, w[p..][0..2], .little),
                else => std.mem.readInt(i32, w[p..][0..4], .little),
            };
            p += sz;
        } else {
            const sz: usize = if (code == 1) 2 else if (code == 2) 4 else 8;
            if (p + sz > w.len) return false;
            d = switch (sz) {
                2 => std.mem.readInt(i16, w[p..][0..2], .little),
                4 => std.mem.readInt(i32, w[p..][0..4], .little),
                else => std.mem.readInt(i64, w[p..][0..8], .little),
            };
            p += sz;
        }
        prev +%= d;
        if (!wide) {
            prev = @as(i32, @truncate(prev)); // (32-bit sums wrap)
            std.mem.writeInt(i32, out[k * 4 ..][0..4], @truncate(prev), .little);
        } else std.mem.writeInt(i64, out[k * 8 ..][0..8], prev, .little);
    }
    return true;
}

/// uc_ints: `n` compressed ints at the cursor (a u64 size, then that many
/// bytes) into the layer's arena (int32 or int64 each), null: damaged.
fn ints(c: *C, n: u32, wide: bool) ?[*]u8 {
    const comp = c.u64_();
    const src = c.ptr(comp) orelse {
        c.bad = true;
        return null;
    };
    const ib: usize = if (wide) 8 else 4;
    const room = (@as(usize, n) * 2 + 7) / 8 + @as(usize, n) * ib + ib + 16;
    const work = ul.vmap(room) orelse {
        c.bad = true;
        return null;
    };
    defer ul.vunmap(work, room);
    const wb = fast(src[0..@intCast(comp)], work[0..room]) orelse {
        c.bad = true;
        return null;
    };
    const out = c.lay.ar.alloc(@as(usize, n) * ib + 8) orelse {
        c.bad = true;
        return null;
    };
    if (!decode(work[0..wb], n, wide, out)) {
        c.bad = true;
        return null;
    }
    return out;
}

fn ints32(c: *C, n: u32) ?[*]align(1) const u32 {
    const p = ints(c, n, false) orelse return null;
    return @ptrCast(p);
}

// ---- the sections -----------------------------------------------------------------------

fn tokens(c: *C) bool {
    if (!c.sec("TOKENS")) return false;
    const n = c.u64_();
    const raw = c.u64_();
    const comp = c.u64_();
    if (n > 0x4000000 or raw > 0x40000000) return false;
    const src = c.ptr(comp) orelse return false;
    const text = c.lay.ar.alloc(@intCast(raw + 1)) orelse return false;
    const got = fast(src[0..@intCast(comp)], text[0..@intCast(raw)]) orelse return false;
    text[got] = 0;
    const tok = c.lay.ar.many([*:0]const u8, @intCast(n + 1)) orelse return false;
    c.tok = tok;
    c.ntok = n;
    var si: usize = 0;
    var k: u64 = 0;
    while (k < n) : (k += 1) {
        if (si >= got) {
            tok[k] = empty; // (past the text: empty)
            continue;
        }
        tok[k] = @ptrCast(text + si);
        while (si < got and text[si] != 0) si += 1;
        si += 1;
    }
    return true;
}

fn strings(c: *C) bool {
    if (!c.sec("STRINGS")) return false;
    const n = c.u64_();
    if (n > 0x4000000) return false;
    const p = c.ptr(n * 4) orelse return false;
    const s = c.lay.ar.many([*:0]const u8, @intCast(n + 1)) orelse return false;
    c.str = s;
    c.nstr = n;
    var k: usize = 0;
    while (k < n) : (k += 1) s[k] = c.tokn(std.mem.readInt(u32, p[k * 4 ..][0..4], .little));
    return true;
}

fn fields(c: *C) bool {
    if (!c.sec("FIELDS")) return false;
    const n = c.u64_();
    if (n > 0x4000000) return false;
    c.nf = n;
    c.ftok = ints32(c, @intCast(n)) orelse return false;
    const rs = c.u64_(); // the reps: LZ4 of n x 8 bytes
    const src = c.ptr(rs) orelse return false;
    const reps = c.lay.ar.alloc(@intCast(n * 8 + 8)) orelse return false;
    c.reps = @ptrCast(reps);
    const got = fast(src[0..@intCast(rs)], reps[0..@intCast(n * 8)]) orelse return false;
    return got == n * 8;
}

fn fieldsets(c: *C) bool {
    if (!c.sec("FIELDSETS")) return false;
    const n = c.u64_();
    if (n > 0x4000000) return false;
    c.nfset = n;
    c.fset = ints32(c, @intCast(n)) orelse return false;
    return true;
}

/// (A damaged PATHS section can send the walk back over nodes it has seen,
/// each time twice as often: the original then never ends. Past this many
/// steps it is damaged.)
fn walkBudget(n: u64) u64 {
    return n * 64 + 65536;
}

fn paths(c: *C) bool {
    if (!c.sec("PATHS")) return false;
    c.npath = c.u64_();
    if (c.npath > 0x4000000) return false;
    const n = c.u64_(); // encoded paths
    if (n > 0x4000000) return false;
    const nums = ints32(c, @intCast(n)) orelse return false;
    const elems = ints32(c, @intCast(n)) orelse return false;
    const jumps = ints32(c, @intCast(n)) orelse return false;
    const cp = c.lay.ar.many(i32, @intCast(c.npath + 2)) orelse return false;
    @memset(cp[0..@intCast(c.npath)], -1);
    c.cpath = cp;
    const ssz: usize = @intCast(n * 8 + 16); // a stack: (parent, index)
    const sm = ul.vmap(ssz) orelse return false;
    defer ul.vunmap(sm, ssz);
    const stack: [*][2]i32 = @ptrCast(sm);
    var depth: u64 = 0;
    stack[0] = .{ -2, 0 }; // (-2: no parent - the root)
    depth += 1;
    var steps: u64 = 0;
    const budget = walkBudget(n);
    while (depth > 0) {
        depth -= 1;
        var parent: i32 = stack[depth][0];
        var cur: u32 = @bitCast(stack[depth][1]);
        while (true) {
            if (cur >= n) return false;
            steps += 1;
            if (steps > budget) return false;
            const this = cur;
            cur +%= 1;
            var kind: u32 = ul.UK_ROOT;
            var pidx: i32 = -1;
            if (parent == -2) {
                c.pbuf[0] = '/';
                c.pbuf[1] = 0;
            } else {
                const e: i32 = @bitCast(elems[this]);
                var ei: i64 = e;
                kind = ul.UK_PRIM;
                if (ei < 0) {
                    ei = -ei;
                    kind = ul.UK_PROP;
                }
                const t = c.tokn(@bitCast(ei));
                const ps = c.lay.paths[@intCast(parent)].str; // the parent's text first
                var o: usize = 0;
                var i: usize = 0;
                while (ps[i] != 0) : (i += 1) {
                    c.pbuf[o] = ps[i];
                    o += 1;
                    if (o >= 4000) return false;
                }
                var sep: u8 = 0;
                if (kind == ul.UK_PROP) {
                    sep = '.';
                } else if (t[0] == '{') { // a variant selection: right after
                    kind = ul.UK_VARIANT;
                } else if (!(o > 0 and (c.pbuf[o - 1] == '/' or c.pbuf[o - 1] == '}'))) {
                    sep = '/'; // (under "/": no second slash; under a variant: none either)
                }
                if (sep != 0) {
                    c.pbuf[o] = sep;
                    o += 1;
                }
                i = 0;
                while (true) : (i += 1) {
                    const ch = t[i];
                    c.pbuf[o] = ch;
                    o += 1;
                    if (ch == 0) break;
                    if (o >= 4000) return false;
                }
                pidx = parent;
            }
            const lp = ul.path(c.lay, @ptrCast(&c.pbuf), pidx, kind) orelse return false;
            const pn = nums[this];
            if (pn >= c.npath) return false;
            c.cpath[pn] = @intCast(lp);
            const j: i32 = @bitCast(jumps[this]);
            const child = j > 0 or j == -1;
            if (child) {
                if (j > 0) { // a child and a sibling: the sibling later
                    if (depth >= n) return false;
                    stack[depth] = .{ parent, @bitCast(this +% @as(u32, @bitCast(j))) };
                    depth += 1;
                }
                parent = @intCast(lp); // down to the child, next
                continue;
            }
            if (j >= 0) continue; // no child: a sibling next, or done
            break;
        }
    }
    return true;
}

fn specs(c: *C) bool {
    if (!c.sec("SPECS")) return false;
    const n = c.u64_();
    if (n > 0x4000000) return false;
    const ps = ints32(c, @intCast(n)) orelse return false;
    const fs = ints32(c, @intCast(n)) orelse return false;
    const ts = ints32(c, @intCast(n)) orelse return false;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const pn = ps[k];
        if (pn >= c.npath) continue;
        const lp = c.cpath[pn];
        if (lp < 0) continue;
        const s = ul.spec(c.lay, @intCast(lp), ts[k]) orelse return false;
        var f: u64 = fs[k]; // its field set's first entry
        while (f < c.nfset) : (f += 1) {
            const fi = c.fset[f];
            if (fi == 0xffffffff) break;
            if (fi >= c.nf) continue;
            const name = c.tokn(c.ftok[fi]);
            const v = value(c, c.reps[fi]) orelse continue;
            ul.field(c.lay, s, name, v);
        }
    }
    return true;
}

// ---- values ---------------------------------------------------------------------------

fn elsize(kind: u8) u32 {
    return switch (kind) {
        UE_F16 => 2,
        UE_F64, UE_I64 => 8,
        UE_U8 => 1,
        else => 4,
    };
}

/// a half's bits as a float
pub fn h2f(h: u32) f32 {
    const sign: u32 = (h & 0x8000) << 16;
    const e = (h >> 10) & 31;
    const m = h & 0x3ff;
    if (e == 0) { // zero / subnormal: m x 2^-24
        const f: f32 = @as(f32, @floatFromInt(m)) * 5.9604645e-8;
        return @bitCast(@as(u32, @bitCast(f)) | sign);
    }
    if (e == 31) return @bitCast(sign | 0x7f800000 | m << 13); // inf / nan
    return @bitCast(sign | (e + 112) << 23 | m << 13);
}

fn todbl(out: [*]f64, in: [*]const u8, n: u32, kind: u8) void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        out[k] = switch (kind) {
            UE_F64 => @bitCast(std.mem.readInt(u64, in[k * 8 ..][0..8], .little)),
            UE_F32 => @as(f32, @bitCast(std.mem.readInt(u32, in[k * 4 ..][0..4], .little))),
            UE_F16 => h2f(std.mem.readInt(u16, in[k * 2 ..][0..2], .little)),
            else => @floatFromInt(std.mem.readInt(i32, in[k * 4 ..][0..4], .little)), // int32
        };
    }
}

fn tofloat(out: [*]f32, in: [*]const u8, n: u32, kind: u8) void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        out[k] = switch (kind) {
            UE_F64 => @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, in[k * 8 ..][0..8], .little)))),
            UE_F16 => h2f(std.mem.readInt(u16, in[k * 2 ..][0..2], .little)),
            else => @bitCast(std.mem.readInt(u32, in[k * 4 ..][0..4], .little)),
        };
    }
}

/// an uncompressed array of floats at the cursor into UT_FARR (float32 ones
/// point into the file; others are converted)
fn farr(c: *C, v: *Value, n: u64, comps: u32, kind: u8) void {
    const total = std.math.mul(u64, n, comps) catch {
        c.bad = true;
        return;
    };
    const bytes = std.math.mul(u64, total, elsize(kind)) catch {
        c.bad = true; // (the original's product wraps: it reads past what it has)
        return;
    };
    const p = c.ptr(bytes) orelse return;
    var data: usize = @intFromPtr(p);
    if (kind != UE_F32) {
        const o = c.lay.ar.alloc(@intCast(@min(total * 4 + 8, std.math.maxInt(usize)))) orelse return;
        tofloat(@ptrCast(@alignCast(o)), p, @truncate(total), kind);
        data = @intFromPtr(o);
    }
    v.p = data;
    v.n = n;
    v.x = comps;
    v.t = ul.UT_FARR;
}

/// an uncompressed int array into UT_IARR (int32 ones point into the file)
fn iarr(c: *C, v: *Value, n: u64, comps: u32, kind: u8) void {
    const total = n * comps;
    const p = c.ptr(total * elsize(kind)) orelse return;
    var data: usize = @intFromPtr(p);
    if (kind != UE_I32) {
        const o = c.lay.ar.alloc(@intCast(total * 4 + 8)) orelse return;
        var k: usize = 0;
        while (k < total) : (k += 1) {
            const x: u32 = if (kind == UE_U8) p[k] else @truncate(std.mem.readInt(u64, p[k * 8 ..][0..8], .little));
            std.mem.writeInt(u32, o[k * 4 ..][0..4], x, .little);
        }
        data = @intFromPtr(o);
    }
    v.p = data;
    v.n = n;
    v.x = comps;
    v.t = ul.UT_IARR;
}

/// that many u32 numbers at the cursor into a UT_SLIST (1 tokens, 2 strings,
/// 3 paths)
fn textlist(c: *C, v: *Value, n: u64, kind: u32) void {
    if (n > 0x10000000) return;
    const p = c.ptr(n * 4) orelse return;
    const l = c.lay.ar.many(Str, @intCast(n + 1)) orelse return;
    v.p = @intFromPtr(l);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const x = std.mem.readInt(u32, p[k * 4 ..][0..4], .little);
        l[k] = switch (kind) {
            1 => c.tokn(x),
            2 => c.strn(x),
            else => c.pathn(x),
        };
    }
    v.n = n;
    v.t = ul.UT_SLIST;
}

const lo_bits = [6]u8{ 2, 4, 32, 64, 8, 16 }; // explicit, added, prepended, appended, deleted, ordered

/// a list op at the cursor: its explicit, added, prepended and appended items
/// in one list (deleted and ordered ones read past). Text lists: UT_SLIST;
/// references and payloads: UT_RLIST.
fn listop(c: *C, v: *Value, typ: u32) void {
    const hdr = c.u8_();
    const start = c.cur;
    var out: ?[*]Str = null;
    var pass: u32 = 0;
    const refs = typ == 35 or typ == 55;
    while (true) {
        var kept: u64 = 0;
        for (lo_bits, 0..) |bit, li| {
            if (hdr & bit == 0) continue;
            var items = c.u64_();
            if (items > 0x1000000) {
                v.t = ul.UT_NONE;
                return;
            }
            while (items > 0) {
                items -= 1;
                if (refs) {
                    const a = c.u32_(); // asset (string), prim path, offset
                    const pp = c.u32_();
                    _ = c.ptr(16);
                    if (typ == 35) { // references: custom data (empty)
                        if (c.u64_() != 0) {
                            v.t = ul.UT_NONE;
                            return;
                        }
                    }
                    if (c.bad) {
                        v.t = ul.UT_NONE;
                        return;
                    }
                    if (li >= 4) continue;
                    if (out) |o| {
                        o[kept * 2 + 1] = c.pathn(pp);
                        o[kept * 2] = c.strn(a);
                    }
                    kept += 1;
                } else {
                    const x = c.u32_();
                    if (c.bad) {
                        v.t = ul.UT_NONE;
                        return;
                    }
                    if (li >= 4) continue; // (deleted, ordered: not kept)
                    if (out) |o| o[kept] = switch (typ) {
                        34 => c.pathn(x),
                        33 => c.strn(x),
                        else => c.tokn(x),
                    };
                    kept += 1;
                }
            }
        }
        if (pass == 0) {
            pass = 1; // the output, then again
            const o = c.lay.ar.alloc(@intCast(kept * 16 + 8)) orelse {
                v.t = ul.UT_NONE;
                return;
            };
            out = @ptrCast(@alignCast(o));
            c.cur = start;
            continue;
        }
        v.p = @intFromPtr(out.?);
        v.n = kept;
        v.t = if (refs) ul.UT_RLIST else ul.UT_SLIST;
        return;
    }
}

/// one payload at the cursor into a UT_RLIST
fn payload(c: *C, v: *Value) void {
    const a = c.u32_();
    const p = c.u32_();
    if (c.bad) return;
    const o = c.lay.ar.many(Str, 2) orelse return;
    v.p = @intFromPtr(o);
    o[0] = c.strn(a);
    o[1] = c.pathn(p);
    v.n = 1;
    v.t = ul.UT_RLIST;
}

/// uc_value: a value rep's value (UT_NONE when not kept), null: out of memory
fn value(c: *C, rep: u64) ?*Value {
    const pay: u64 = rep & 0xffffffffffff;
    const typ: u32 = @intCast((rep >> 48) & 0xff);
    const v = c.lay.ar.val() orelse return null;
    if (typ >= NTYPES) return v;
    const p32: u32 = @truncate(pay);
    if (rep & (1 << 62) != 0) { // ---- inlined in the payload
        switch (typ) {
            51 => {}, // a blocked value
            10 => {
                v.p = @intFromPtr(c.strn(p32));
                v.t = ul.UT_STR;
            },
            11, 12 => {
                v.p = @intFromPtr(c.tokn(p32));
                v.t = ul.UT_STR;
            },
            8, 9, 56 => {
                const f: f32 = @bitCast(p32);
                v.d = @bitCast(@as(f64, f));
                v.t = ul.UT_DBL;
            },
            7 => {
                v.d = @bitCast(@as(f64, h2f(p32)));
                v.t = ul.UT_DBL;
            },
            40, 41, 50 => v.t = ul.UT_SLIST, // empty vectors
            48 => {
                v.t = ul.UT_FARR;
                v.x = 1;
            },
            13...15 => { // the diagonal as int8s
                const rows = typ - 11;
                const o = c.lay.ar.many(f64, rows * rows) orelse return v;
                var i: u32 = 0;
                while (i < rows) : (i += 1) {
                    const b: i8 = @bitCast(@as(u8, @truncate(p32 >> @intCast((i * 8) & 31))));
                    o[i * rows + i] = @floatFromInt(b);
                }
                v.p = @intFromPtr(o);
                v.n = rows * rows;
                v.t = ul.UT_VEC;
            },
            16...30 => { // int8 components
                const comps = types[typ][0];
                const o = c.lay.ar.many(f64, comps) orelse return v;
                var i: u32 = 0;
                while (i < comps) : (i += 1) {
                    const b: i8 = @bitCast(@as(u8, @truncate(p32 >> @intCast((i * 8) & 31))));
                    o[i] = @floatFromInt(b);
                }
                v.p = @intFromPtr(o);
                v.n = comps;
                v.t = ul.UT_VEC;
            },
            0...6, 42...44 => { // bool, uchar, ints, enums
                const x: i64 = if (typ == 3 or typ == 5) @as(i32, @bitCast(p32)) else p32;
                v.d = @bitCast(x);
                v.t = ul.UT_INT;
            },
            else => {},
        }
        return v;
    }
    if (rep & (1 << 63) != 0) { // ---- arrays
        c.cur = pay;
        const n = c.count();
        if (n > 0x10000000) return v;
        const comps = types[typ][0];
        const kind = types[typ][1];
        if (kind == UE_NONE) return v;
        if (rep & (1 << 61) != 0) { // compressed: ints, or floats as ints or through a table
            if (kind == UE_I32) {
                const o = ints(c, @intCast(n), false) orelse return v;
                setInts(v, o, n);
            } else if (kind == UE_I64) {
                const o = ints(c, @intCast(n), true) orelse return v;
                var k: usize = 0;
                while (k < n) : (k += 1) { // (narrowed, in place)
                    const x = std.mem.readInt(u64, o[k * 8 ..][0..8], .little);
                    std.mem.writeInt(u32, o[k * 4 ..][0..4], @truncate(x), .little);
                }
                setInts(v, o, n);
            } else if (kind >= UE_F16 and kind <= UE_F64) {
                const code = c.u8_();
                if (code == 'i') {
                    const o = ints(c, @intCast(n), false) orelse return v;
                    var k: usize = 0;
                    while (k < n) : (k += 1) { // (to floats, in place)
                        const x = std.mem.readInt(i32, o[k * 4 ..][0..4], .little);
                        const f: f32 = @floatFromInt(x);
                        std.mem.writeInt(u32, o[k * 4 ..][0..4], @bitCast(f), .little);
                    }
                    setFloats(v, o, n);
                } else if (code == 't') {
                    const ln = c.u32_(); // the table
                    if (ln == 0 or ln > 0x1000000) return v;
                    const tp = c.ptr(@as(u64, ln) * elsize(kind)) orelse return v;
                    const tab = c.lay.ar.alloc(@as(usize, ln) * 4 + 8) orelse return v;
                    const tf: [*]f32 = @ptrCast(@alignCast(tab));
                    tofloat(tf, tp, ln, kind);
                    const o = ints(c, @intCast(n), false) orelse return v;
                    var k: usize = 0;
                    while (k < n) : (k += 1) {
                        var x = std.mem.readInt(u32, o[k * 4 ..][0..4], .little);
                        if (x >= ln) x = 0; // (outside the table: its first)
                        std.mem.writeInt(u32, o[k * 4 ..][0..4], @bitCast(tf[x]), .little);
                    }
                    setFloats(v, o, n);
                }
            }
            return v;
        }
        if (typ == 12) { // (asset path arrays: string numbers, not tokens as a lone one is)
            textlist(c, v, n, 2);
        } else switch (kind) {
            UE_TOK => textlist(c, v, n, 1),
            UE_STR => textlist(c, v, n, 2),
            UE_I32, UE_I64, UE_U8 => iarr(c, v, n, comps, kind),
            else => farr(c, v, n, comps, kind), // floats of any width
        }
        return v;
    }
    c.cur = pay;
    switch (typ) {
        9, 56 => {
            const p = c.ptr(8) orelse return v;
            v.d = std.mem.readInt(u64, p[0..8], .little);
            v.t = ul.UT_DBL;
        },
        5, 6 => {
            v.d = c.u64_();
            v.t = ul.UT_INT;
        },
        41 => textlist(c, v, c.u64_(), 1),
        50 => textlist(c, v, c.u64_(), 2),
        40 => textlist(c, v, c.u64_(), 3),
        48 => farr(c, v, c.u64_(), 1, UE_F64),
        32, 33, 34, 35, 55 => listop(c, v, typ),
        47 => payload(c, v),
        45 => {
            const n = c.u64_();
            if (n > 0x100000) return v;
            const o = c.lay.ar.many(Str, @intCast(n * 2 + 1)) orelse return v;
            v.p = @intFromPtr(o);
            var k: usize = 0;
            while (k < n) : (k += 1) {
                o[k * 2] = c.strn(c.u32_());
                o[k * 2 + 1] = c.strn(c.u32_());
            }
            v.n = n;
            v.t = ul.UT_VSEL;
        },
        13...30 => { // vectors, matrices, quaternions
            const comps = types[typ][0];
            const kind = types[typ][1];
            const o = c.lay.ar.many(f64, comps) orelse return v;
            const p = c.ptr(elsize(kind) * comps) orelse return v;
            todbl(o, p, comps, kind);
            v.t = ul.UT_VEC;
            v.n = comps;
            v.p = @intFromPtr(o);
        },
        else => {},
    }
    return v;
}

fn setInts(v: *Value, o: [*]u8, n: u64) void {
    v.p = @intFromPtr(o);
    v.n = n;
    v.x = 1;
    v.t = ul.UT_IARR;
}
fn setFloats(v: *Value, o: [*]u8, n: u64) void {
    v.p = @intFromPtr(o);
    v.n = n;
    v.x = 1;
    v.t = ul.UT_FARR;
}

/// usdc_read: the layer, null (err says why).
pub fn read(path: []const u8) ?*Layer {
    const map = ul.mapFile(path) orelse {
        err = e_open;
        return null;
    };
    const lay = ul.new() orelse {
        ul.unmapFile(map);
        err = e_mem;
        return null;
    };
    lay.map = map;
    lay.file = lay.ar.dup(path) orelse "";
    var c = C{ .map = map, .lay = lay };
    if (map.len < 88 or std.mem.readInt(u64, map[0..8], .little) != MAGIC) {
        ul.free(lay);
        err = e_magic;
        return null;
    }
    c.ver = @as(u32, map[8]) << 16 | @as(u32, map[9]) << 8 | map[10];
    if (c.ver < 0x000400 or c.ver >= 0x010000) {
        ul.free(lay);
        err = e_ver;
        return null;
    }
    c.cur = std.mem.readInt(u64, map[16..24], .little); // the table of contents
    c.nsec = c.u64_();
    var ok = c.nsec <= 64;
    if (ok) {
        if (c.ptr(c.nsec * 32)) |p| {
            c.toc = @intFromPtr(p) - @intFromPtr(map.ptr);
        } else ok = false;
    }
    ok = ok and tokens(&c) and strings(&c) and fields(&c) and fieldsets(&c) and paths(&c) and specs(&c);
    if (!ok) {
        ul.free(lay);
        err = e_dmg;
        return null;
    }
    return lay;
}

test "usdc: LZ4 blocks, TfFastCompression, compressed ints" {
    // "abcabcabcabc": 3 literals then a match of 9 at offset 3
    const blk = [_]u8{ 0x35, 'a', 'b', 'c', 3, 0 };
    var out: [32]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 12), lz4Block(&blk, &out));
    try std.testing.expectEqualStrings("abcabcabcabc", out[0..12]);
    try std.testing.expectEqual(@as(?usize, null), lz4Block(&blk, out[0..5])); // no room
    const bad = [_]u8{ 0x10, 'a', 9, 0 }; // offset past the output
    try std.testing.expectEqual(@as(?usize, null), lz4Block(&bad, &out));
    var f: [7]u8 = undefined;
    f[0] = 0;
    @memcpy(f[1..], &blk);
    try std.testing.expectEqual(@as(?usize, 12), fast(&f, &out));
    try std.testing.expectEqual(@as(?usize, null), fast(&.{}, &out));
    // ints 5, 6, 7, 1000: common 1; codes 1 (small), 0, 0, 3 (large)
    var w: [32]u8 = @splat(0);
    std.mem.writeInt(i32, w[0..4], 1, .little);
    w[4] = 1 | 0 << 2 | 0 << 4 | 3 << 6;
    w[5] = 5;
    std.mem.writeInt(i32, w[6..10], 1000 - 7, .little);
    var o: [16]u8 = undefined;
    try std.testing.expect(decode(w[0..10], 4, false, &o));
    try std.testing.expectEqual(@as(i32, 1000), std.mem.readInt(i32, o[12..16], .little));
    try std.testing.expectEqual(@as(i32, 7), std.mem.readInt(i32, o[8..12], .little));
    try std.testing.expect(!decode(w[0..9], 4, false, &o)); // cut short
    try std.testing.expectEqual(@as(f32, 1.0), h2f(0x3c00));
    try std.testing.expectEqual(@as(f32, -2.0), h2f(0xc000));
    try std.testing.expectEqual(@as(f32, 5.9604645e-8), h2f(1));
    try std.testing.expect(std.math.isInf(h2f(0x7c00)));
}
