//! OpenUSD text files (.usda) read into a layer (usdlayer.zig), with the same
//! specs and fields the crate format keeps (a .usda and the .usdc usdcat
//! makes of it read alike: tests/usd.py), as usda.s reads them.
//!
//!   #usda 1.0
//!   ( layer metadata )
//!   def|over|class [Type] "Name" ( metadata ) {
//!       [custom] [uniform] type[] name[.connect|.timeSamples] = value ( metadata )
//!       [custom] rel name = </target> | [</a>, </b>]
//!       variantSet "set" = { "sel" ( metadata ) { body } ... }
//!       def ... (children)
//!   }
//!
//! Metadata kept: references and payload (list ops merged: prepended,
//! appended, added, explicit), inherits, specializes, variants (selections),
//! variantSets, apiSchemas, kind, instanceable, active, subLayers,
//! defaultPrim, upAxis, metersPerUnit, kilogramsPerUnit, interpolation,
//! elementSize, colorSpace, doc. Dictionaries and the rest are read past.
//! Values are turned by the declared type: ints, floats, text, tuples
//! (quaternions written w x y z kept x y z w as in the crate), matrices,
//! arrays. A prim's primChildren / properties lists come from its paths once
//! all is read.
const std = @import("std");
const ul = @import("usdlayer.zig");
const usdc = @import("usdc.zig");
const Layer = ul.Layer;
const Value = ul.Value;
const Str = ul.Str;

const T_EOF: u32 = 0;
const T_ID: u32 = 1;
const T_NUM: u32 = 2;
const T_STR: u32 = 3;
const T_ASSET: u32 = 4;
const T_PATH: u32 = 5;
const T_P: u32 = 6; // punctuation (tc)

const VK_INT: u32 = 1;
const VK_FLT: u32 = 2;
const VK_TXT: u32 = 3;
const VK_QUAT: u32 = 4; // 4 floats, reordered
const VK_MAT: u32 = 5; // nested rows

pub const e_bad = "not a USD text file (#usda)";
const e_syn = "the USD text has a syntax error near line ";
var ebuf: [96]u8 = undefined;

const p10 = [23]f64{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 };
const inf: f64 = @bitCast(@as(u64, 0x7ff0000000000000));
const qnan: f64 = @bitCast(@as(u64, 0x7ff8000000000000));
const empty: [*:0]const u8 = "";
const A = std.heap.page_allocator;

// metadata keys (ua_keys): their rows 1 .. 20
const keys = [_][]const u8{ "references", "payload", "inherits", "specializes", "variants", "variantSets", "apiSchemas", "kind", "instanceable", "active", "hidden", "subLayers", "defaultPrim", "upAxis", "metersPerUnit", "kilogramsPerUnit", "interpolation", "elementSize", "doc", "colorSpace" };
const K_REFS = 1;
const K_PAY = 2;
const K_INH = 3;
const K_SPEC = 4;
const K_VARS = 5;
const K_VSETS = 6;
const K_API = 7;
const K_KIND = 8;
const K_INST = 9;
const K_ACTIVE = 10;
const K_HIDDEN = 11;
const K_SUBL = 12;
const K_DEFP = 13;
const K_UP = 14;
const K_MPU = 15;
const K_KPU = 16;
const K_INTERP = 17;
const K_ESIZE = 18;
const K_DOC = 19;
const K_CSPACE = 20;

/// The reader's state (usda.s's ua_*).
const R = struct {
    lay: *Layer,
    m: []const u8,
    p: usize = 0,
    end: usize = 0,
    line: u32 = 1,
    ty: u32 = T_EOF,
    tp: usize = 0,
    tl: usize = 0,
    tc: u32 = 0,
    err: bool = false,
    depth: u32 = 0,
    nums: std.ArrayList(f64) = .empty,
    list: std.ArrayList(Str) = .empty,
    lop: bool = false,
    pbuf: [4096]u8 = undefined,

    /// After bad() the start is new but the length is the last token's (the
    /// original's stale text); past the end the original reads its mapping's
    /// zero padding, which ends the text there: the same as stopping at the end.
    fn tok(r: *const R) []const u8 {
        const tp = @min(r.tp, r.m.len);
        return r.m[tp..][0..@min(r.tl, r.m.len - tp)];
    }

    // ---- the scanner ----
    fn adv(r: *R) void {
        var i = r.p;
        const e = r.end;
        const m = r.m;
        while (true) {
            if (i >= e) return r.eof(i);
            const c = m[i];
            if (c == '\n') {
                r.line +%= 1;
                i += 1;
                continue;
            }
            if (c == ' ' or c == 9 or c == 13) {
                i += 1;
                continue;
            }
            if (c == '#') { // a comment: to the line's end
                while (true) {
                    i += 1;
                    if (i >= e) return r.eof(i);
                    if (m[i] == '\n') break;
                }
                continue;
            }
            break;
        }
        const c = m[i];
        r.tc = c;
        if (c == '"' or c == '\'') return r.str(i, c);
        if (c == '@') return r.asset(i);
        if (c == '<') return r.path(i);
        if (c >= '0' and c <= '9') return r.num(i);
        if (c == '-' or c == '+') {
            if (i + 1 < e) {
                const c1 = m[i + 1];
                if (c1 == 'i' or c1 == 'n' or c1 == '.' or (c1 >= '0' and c1 <= '9')) return r.num(i);
            }
            return r.punct(i);
        }
        if (c == '.') {
            if (i + 1 < e and m[i + 1] >= '0' and m[i + 1] <= '9') return r.num(i);
            return r.punct(i);
        }
        if (idstart(c)) {
            r.tp = i;
            i += 1;
            while (i < e) : (i += 1) {
                const d = m[i];
                if (!(idstart(d) or (d >= '0' and d <= '9') or d == ':' or d == '.')) break;
            }
            r.ty = T_ID;
            r.tl = i - r.tp;
            r.p = i;
            return;
        }
        r.punct(i);
    }
    fn eof(r: *R, i: usize) void {
        r.ty = T_EOF;
        r.p = i;
    }
    fn punct(r: *R, i: usize) void {
        r.ty = T_P;
        r.p = i + 1;
    }
    fn bad(r: *R) void {
        r.err = true;
        r.eof(r.end);
    }
    fn num(r: *R, start: usize) void {
        r.tp = start;
        var i = start + 1;
        while (i < r.end) : (i += 1) {
            const c = r.m[i];
            if ((c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+') continue;
            const l = c | 0x20;
            if (l == 'e' or l == 'i' or l == 'n' or l == 'f' or l == 'a') continue;
            break;
        }
        r.ty = T_NUM;
        r.tl = i - r.tp;
        r.p = i;
    }
    fn str(r: *R, at: usize, q: u8) void {
        var i = at;
        const e = r.end;
        const m = r.m;
        if (i + 2 < e and m[i + 1] == q and m[i + 2] == q) { // triple
            i += 3;
            r.tp = i;
            while (true) {
                if (i + 2 >= e) return r.bad();
                if (m[i] == '\n') r.line +%= 1;
                if (m[i] == q and m[i + 1] == q and m[i + 2] == q) {
                    r.tl = i - r.tp;
                    i += 3;
                    break;
                }
                i += 1;
            }
        } else { // single
            i += 1;
            r.tp = i;
            while (true) {
                if (i >= e) return r.bad();
                const c = m[i];
                if (c == '\\') {
                    i += 2;
                    continue;
                }
                if (c == '\n') return r.bad();
                if (c == q) {
                    r.tl = i - r.tp;
                    i += 1;
                    break;
                }
                i += 1;
            }
        }
        r.ty = T_STR;
        r.p = i;
    }
    fn asset(r: *R, at: usize) void {
        var i = at;
        const e = r.end;
        const m = r.m;
        if (i + 2 < e and m[i + 1] == '@' and m[i + 2] == '@') { // @@@..@@@
            i += 3;
            r.tp = i;
            while (true) {
                if (i + 2 >= e) return r.bad();
                if (m[i] == '@' and m[i + 1] == '@' and m[i + 2] == '@') {
                    r.tl = i - r.tp;
                    i += 3;
                    break;
                }
                i += 1;
            }
        } else {
            i += 1;
            r.tp = i;
            while (true) {
                if (i >= e) return r.bad();
                if (m[i] == '@') break;
                if (m[i] == '\n') return r.bad();
                i += 1;
            }
            r.tl = i - r.tp;
            i += 1;
        }
        r.ty = T_ASSET;
        r.p = i;
    }
    fn path(r: *R, at: usize) void {
        var i = at + 1;
        r.tp = i;
        while (true) {
            if (i >= r.end) return r.bad();
            if (r.m[i] == '>') break;
            if (r.m[i] == '\n') return r.bad();
            i += 1;
        }
        r.tl = i - r.tp;
        r.ty = T_PATH;
        r.p = i + 1;
    }

    fn isp(r: *const R, c: u8) bool {
        return r.ty == T_P and r.tc == c;
    }
    /// the token was that punctuation (moved past it); else a syntax error
    fn want(r: *R, c: u8) bool {
        if (r.isp(c)) {
            r.adv();
            return true;
        }
        r.err = true;
        return false;
    }
    fn is(r: *const R, w: []const u8) bool {
        return r.ty == T_ID and std.mem.eql(u8, r.tok(), w);
    }

    /// the token's text copied into the layer (unescaped: \n, \t)
    fn text(r: *R, unesc: bool) Str {
        const o = r.lay.ar.alloc(r.tl + 1) orelse return null;
        const s = r.tok();
        var i: usize = 0;
        var k: usize = 0;
        while (i < s.len) {
            var c = s[i];
            i += 1;
            if (unesc and c == '\\' and i < s.len) {
                c = s[i];
                i += 1;
                if (c == 'n') c = 10 else if (c == 't') c = 9;
            }
            o[k] = c;
            k += 1;
        }
        o[k] = 0;
        return @ptrCast(o);
    }

    /// the number token as a double (inf, nan too), and its integer part
    fn number(r: *const R) f64 {
        const s = r.tok();
        var i: usize = 0;
        var neg = false;
        var f: f64 = 0;
        blk: {
            if (i >= s.len) break :blk;
            if (s[i] == '-') {
                neg = true;
                i += 1;
            } else if (s[i] == '+') i += 1;
            if (i >= s.len) break :blk;
            const l = s[i] | 0x20;
            if (l == 'i') {
                f = inf;
                break :blk;
            }
            if (l == 'n') return qnan;
            var mant: i64 = 0; // mantissa digits
            var e: i32 = 0; // decimal exponent
            var kept: u32 = 0;
            var after = false;
            while (i < s.len) {
                const c = s[i];
                if (c == '.') {
                    after = true;
                    i += 1;
                    continue;
                }
                if (c >= '0' and c <= '9') {
                    i += 1;
                    if (kept >= 18) { // digits past 18: only the scale
                        if (!after) e += 1;
                        continue;
                    }
                    mant = mant * 10 + (c - '0');
                    if (mant != 0) kept += 1; // (leading zeros do not count)
                    if (after) e -= 1;
                    continue;
                }
                if (c | 0x20 == 'e') { // an exponent
                    i += 1;
                    if (i < s.len) {
                        var sg = false;
                        var x: i32 = 0;
                        if (s[i] == '-') {
                            sg = true;
                            i += 1;
                        } else if (s[i] == '+') i += 1;
                        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                            x = x * 10 + (s[i] - '0');
                            if (x >= 10000) x = 10000;
                        }
                        if (sg) x = -x;
                        e += x;
                    }
                }
                break;
            }
            f = @floatFromInt(mant); // m x 10^e: one rounding while |e| <= 22
            if (e > 0) {
                while (e > 22) : (e -= 22) f *= p10[22];
                f *= p10[@intCast(e)];
            } else if (e < 0) {
                e = -e;
                while (e > 22) : (e -= 22) f /= p10[22];
                f /= p10[@intCast(e)];
            }
        }
        if (neg) f = 0.0 - f;
        return f;
    }

    fn pushNum(r: *R, x: f64) void {
        r.nums.append(A, x) catch {
            r.err = true;
        };
    }
    fn pushText(r: *R, t: Str) void {
        r.list.append(A, t) catch {
            r.err = true;
        };
    }

    /// a value of the texts gathered since the list was emptied (pairs: two
    /// texts an item)
    fn takeList(r: *R, t: u32) ?*Value {
        defer r.list.clearRetainingCapacity();
        const v = r.lay.ar.val() orelse return null;
        v.t = t;
        const n = r.list.items.len;
        const o = r.lay.ar.many(Str, n + 1) orelse return v;
        v.p = @intFromPtr(o);
        @memcpy(o[0..n], r.list.items);
        v.n = if (t == ul.UT_SLIST) n else n / 2;
        return v;
    }

    /// set, or added to the field's list already there (prepend + append
    /// ...); delete / reorder statements are not kept
    fn setlist(r: *R, s: u32, name: [*:0]const u8, v: *Value) void {
        if (r.lop) return;
        if (ul.get(r.lay, s, name)) |old| {
            if (old.t == v.t) { // both: old items, then the new
                const per: usize = if (old.t == ul.UT_SLIST) 1 else 2;
                const a = old.texts();
                const b = v.texts();
                const tot = (old.n + v.n) * per;
                if (r.lay.ar.many(Str, tot + 1)) |o| {
                    @memcpy(o[0..a.len], a);
                    @memcpy(o[a.len..][0..b.len], b);
                    v.p = @intFromPtr(o);
                    v.n += old.n;
                }
            }
        }
        ul.field(r.lay, s, name, v);
    }

    // ---- skipping ----
    /// one value: a token, or a ( ), [ ], { } group with all inside
    fn skip(r: *R) void {
        var d: i32 = 0;
        while (true) {
            if (r.ty == T_EOF) {
                r.err = true;
                return;
            }
            if (r.ty == T_P) {
                switch (r.tc) {
                    '(', '[', '{' => d += 1,
                    ')', ']', '}' => {
                        d -= 1;
                        if (d < 0) return; // (a closer not ours: left for the caller)
                    },
                    else => {},
                }
            }
            r.adv();
            if (d == 0) return;
        }
    }

    // ---- values ----
    /// the numbers of a value (a number, or nested tuples of them) onto
    /// nums; true / false count as 1 / 0
    fn numbers(r: *R) void {
        if (r.isp('(')) {
            r.depth += 1; // (nesting kept within reason)
            if (r.depth > 400) {
                r.err = true;
                return;
            }
            r.adv();
            while (true) {
                if (r.isp(')')) {
                    r.adv();
                    r.depth -= 1;
                    return;
                }
                if (r.ty == T_EOF) {
                    r.err = true;
                    return;
                }
                if (r.err) return;
                r.numbers();
                if (r.isp(',')) r.adv();
            }
        }
        if (r.ty == T_NUM) {
            r.pushNum(r.number());
            r.adv();
            return;
        }
        var x: f64 = 0;
        if (r.is("true")) {
            x = 1;
        } else if (r.is("false")) {
            x = 0;
        } else if (r.is("inf")) {
            x = inf;
        } else if (r.is("nan")) {
            x = qnan;
        } else {
            r.err = true;
            return;
        }
        r.pushNum(x);
        r.adv();
    }

    /// ua_value: a value of the declared type (null: none made)
    fn value(r: *R, ty: []const u8, arr: bool) ?*Value {
        const k = tkind(ty);
        const kind = k[0];
        const comps = k[1];
        const single = singleOf(ty);
        const v = r.lay.ar.val() orelse return null;
        if (r.is("None")) { // blocked
            r.adv();
            return v;
        }
        if (!arr) {
            if (kind == VK_TXT) {
                if (r.ty == T_STR or r.ty == T_ASSET or r.ty == T_ID) { // (a bare token)
                    v.p = @intFromPtr(r.text(r.ty == T_STR));
                    v.t = ul.UT_STR;
                    r.adv();
                } else r.err = true;
                return v;
            }
            r.nums.clearRetainingCapacity();
            r.numbers();
            const nn = r.nums.items.len;
            if (nn == 0) return v;
            if (comps == 1) { // a scalar
                const x = r.nums.items[0];
                if (kind == VK_INT) {
                    v.d = @bitCast(ul.cvtt(x));
                    v.t = ul.UT_INT;
                    return v;
                }
                v.d = @bitCast(if (single != 0) round(x, single) else x);
                v.t = ul.UT_DBL;
                return v;
            }
            // (a quaternion: room for its four even when fewer were given)
            const o = r.lay.ar.many(f64, @max(nn, 4)) orelse return v;
            v.p = @intFromPtr(o);
            @memcpy(o[0..nn], r.nums.items);
            v.n = nn;
            v.t = ul.UT_VEC;
            if (single != 0) {
                for (o[0..nn]) |*x| x.* = round(x.*, single);
            }
            if (kind == VK_QUAT) { // w x y z -> x y z w
                const w = o[0];
                o[0] = o[1];
                o[1] = o[2];
                o[2] = o[3];
                o[3] = w;
            }
            return v;
        }
        // [ elements ]
        r.nums.clearRetainingCapacity();
        r.list.clearRetainingCapacity();
        if (!r.want('[')) return v;
        while (true) {
            if (r.isp(']')) break;
            if (r.ty == T_EOF) {
                r.err = true;
                return v;
            }
            if (r.err) return v;
            if (kind == VK_TXT) {
                r.pushText(r.text(r.ty == T_STR));
                r.adv();
            } else r.numbers();
            if (r.isp(',')) r.adv();
        }
        r.adv();
        if (kind == VK_TXT) return r.takeList(ul.UT_SLIST) orelse v;
        const nn = r.nums.items.len;
        v.n = nn / comps; // elements = numbers / components
        v.x = comps;
        const o = r.lay.ar.alloc(nn * 4 + 8) orelse return v;
        v.p = @intFromPtr(o);
        if (kind == VK_INT) {
            for (r.nums.items, 0..) |x, i| std.mem.writeInt(i32, o[i * 4 ..][0..4], @truncate(ul.cvtt(x)), .little);
            v.t = ul.UT_IARR;
            return v;
        }
        const fo: [*]f32 = @ptrCast(@alignCast(o));
        for (r.nums.items, 0..) |x, i| fo[i] = @floatCast(x);
        v.t = ul.UT_FARR;
        if (kind == VK_QUAT) {
            var q: usize = 0;
            while (q < v.n) : (q += 1) {
                const b = fo + q * 4;
                const w = b[0];
                b[0] = b[1];
                b[1] = b[2];
                b[2] = b[3];
                b[3] = w;
            }
        }
        return v;
    }

    /// a UT_SLIST value: None, </a>, or [</a>, </b>]
    fn paths(r: *R) ?*Value {
        r.list.clearRetainingCapacity();
        if (r.is("None")) {
            r.adv();
        } else if (r.isp('[')) {
            r.adv();
            while (r.ty == T_PATH) {
                r.pushText(r.text(false));
                r.adv();
                if (!r.isp(',')) break;
                r.adv();
            }
            _ = r.want(']');
        } else if (r.ty == T_PATH) {
            r.pushText(r.text(false));
            r.adv();
        } else r.err = true;
        return r.takeList(ul.UT_SLIST);
    }

    /// a UT_SLIST of strings / tokens / assets: "a", or ["a", "b"] (an item's
    /// own ( ... ) read past: subLayers' offsets)
    fn texts(r: *R) ?*Value {
        r.list.clearRetainingCapacity();
        if (r.isp('[')) {
            r.adv();
            while (true) {
                if (r.isp(']')) {
                    r.adv();
                    break;
                }
                if (!r.oneText()) {
                    r.err = true;
                    break;
                }
                if (r.isp('(')) r.skip();
                if (r.isp(',')) r.adv();
            }
        } else if (r.is("None")) {
            r.adv();
        } else if (!r.oneText()) r.err = true;
        return r.takeList(ul.UT_SLIST);
    }

    fn oneText(r: *R) bool {
        if (r.ty != T_STR and r.ty != T_ASSET and r.ty != T_ID) return false;
        r.pushText(r.text(r.ty == T_STR));
        r.adv();
        return true;
    }

    /// a UT_RLIST: None, a reference, or [ ... ]. A reference: @asset@
    /// [</prim>] [( layer offset )], or </prim> alone
    fn refs(r: *R) ?*Value {
        r.list.clearRetainingCapacity();
        if (r.is("None")) {
            r.adv();
        } else if (r.isp('[')) {
            r.adv();
            while (true) {
                if (r.isp(']')) {
                    r.adv();
                    break;
                }
                if (!r.oneRef()) {
                    r.err = true;
                    break;
                }
                if (r.isp(',')) r.adv();
            }
        } else if (!r.oneRef()) r.err = true;
        return r.takeList(ul.UT_RLIST);
    }

    /// an (asset, path) pair pushed (asset "" when internal, path none when
    /// none)
    fn oneRef(r: *R) bool {
        if (r.ty == T_ASSET) {
            r.pushText(r.text(false));
            r.adv();
            if (r.ty == T_PATH) {
                r.pushText(r.text(false));
                r.adv();
            } else r.pushText(null);
        } else if (r.ty == T_PATH) {
            r.pushText(empty); // internal: </path>
            r.pushText(r.text(false));
            r.adv();
        } else return false;
        if (r.isp('(')) r.skip(); // a layer offset: not kept
        return true;
    }

    /// a UT_VSEL of { string set = "sel" ... }, sorted by set
    fn vsel(r: *R) ?*Value {
        r.list.clearRetainingCapacity();
        if (r.want('{')) {
            while (true) {
                if (r.isp('}')) {
                    r.adv();
                    r.sortPairs();
                    break;
                }
                if (r.ty == T_EOF) {
                    r.err = true;
                    break;
                }
                r.adv(); // "string"
                if (r.ty != T_ID) {
                    r.err = true;
                    break;
                }
                r.pushText(r.text(false));
                r.adv();
                if (!r.want('=')) break;
                if (r.ty != T_STR) {
                    r.err = true;
                    break;
                }
                r.pushText(r.text(true));
                r.adv();
            }
        }
        return r.takeList(ul.UT_VSEL);
    }

    /// the list's (key, value) pairs sorted by key (insertion)
    fn sortPairs(r: *R) void {
        const l = r.list.items;
        const n = l.len / 2;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            var j = k;
            while (j > 0) : (j -= 1) {
                if (strcmp(l[j * 2 - 2], l[j * 2]) <= 0) break;
                std.mem.swap(Str, &l[j * 2 - 2], &l[j * 2]);
                std.mem.swap(Str, &l[j * 2 - 1], &l[j * 2 + 1]);
            }
        }
    }

    /// a UT_INT value of true / false / 1 / 0
    fn flag(r: *R) ?*Value {
        const v = r.lay.ar.val() orelse return null;
        v.t = ul.UT_INT;
        if (r.is("true")) {
            v.d = 1;
        } else if (r.ty == T_NUM) {
            v.d = if (ul.cvtt(r.number()) != 0) 1 else 0;
        }
        r.adv();
        return v;
    }

    /// a value of the token (UT_INT / UT_DBL / UT_STR)
    fn scalar(r: *R, t: u32) ?*Value {
        const v = r.lay.ar.val() orelse return null;
        v.t = t;
        if (t == ul.UT_STR) {
            v.p = @intFromPtr(r.text(r.ty == T_STR));
        } else {
            const x = r.number();
            v.d = if (t == ul.UT_INT) @bitCast(ul.cvtt(x)) else @bitCast(x);
        }
        r.adv();
        return v;
    }

    // ---- metadata ----
    /// ( ... ) after its "(": the entries kept as fields
    fn meta(r: *R, s: u32) void {
        while (true) {
            if (r.err) return;
            if (r.isp(')')) {
                r.adv();
                return;
            }
            if (r.ty == T_EOF) {
                r.err = true;
                return;
            }
            if (r.isp(';')) {
                r.adv();
                continue;
            }
            if (r.ty == T_STR) { // a lone string: the doc
                const t = r.text(true);
                r.adv();
                if (t) |tx| {
                    // (the original files the text itself as the value: the
                    // dump reads a kind from its first bytes - "none" for an
                    // empty one, else "?")
                    const v = r.lay.ar.val() orelse continue;
                    const b = ul.cstr(tx);
                    v.t = if (b.len == 0) ul.UT_NONE else ul.UT_ODD;
                    ul.field(r.lay, s, "documentation", v);
                }
                continue;
            }
            r.lop = false;
            r.listop();
            if (r.ty != T_ID) {
                r.err = true;
                return;
            }
            const key = r.tok();
            r.adv();
            if (!r.isp('=')) continue; // (a key alone)
            r.adv();
            const row = keyRow(key);
            switch (row) {
                K_REFS, K_PAY => if (r.refs()) |v| r.setlist(s, if (row == K_REFS) "references" else "payload", v),
                K_INH, K_SPEC => if (r.paths()) |v| r.setlist(s, if (row == K_INH) "inheritPaths" else "specializes", v),
                K_VARS => if (r.vsel()) |v| ul.field(r.lay, s, "variantSelection", v),
                K_VSETS, K_API, K_SUBL => if (r.texts()) |v| r.setlist(s, switch (row) {
                    K_VSETS => "variantSetNames",
                    K_API => "apiSchemas",
                    else => "subLayers",
                }, v),
                K_KIND, K_DEFP, K_UP, K_INTERP, K_DOC, K_CSPACE => if (r.scalar(ul.UT_STR)) |v| ul.field(r.lay, s, switch (row) {
                    K_KIND => "kind",
                    K_DEFP => "defaultPrim",
                    K_UP => "upAxis",
                    K_INTERP => "interpolation",
                    K_DOC => "documentation",
                    else => "colorSpace",
                }, v),
                K_INST, K_ACTIVE, K_HIDDEN => if (r.flag()) |v| ul.field(r.lay, s, switch (row) {
                    K_INST => "instanceable",
                    K_ACTIVE => "active",
                    else => "hidden",
                }, v),
                K_MPU, K_KPU => if (r.scalar(ul.UT_DBL)) |v| ul.field(r.lay, s, if (row == K_MPU) "metersPerUnit" else "kilogramsPerUnit", v),
                K_ESIZE => if (r.scalar(ul.UT_INT)) |v| ul.field(r.lay, s, "elementSize", v),
                else => r.skip(),
            }
        }
    }

    /// a prepend / append / add / delete / reorder keyword read past; lop for
    /// delete and reorder (their items are not kept)
    fn listop(r: *R) void {
        if (r.is("prepend") or r.is("append") or r.is("add")) {
            r.adv();
        } else if (r.is("delete") or r.is("reorder")) {
            r.lop = true;
            r.adv();
        }
    }

    // ---- prims and their bodies ----
    /// the parent's text, the separator (0: none; a "/" is left out after "/"
    /// and after "}"), the name: in pbuf, null when too long
    fn join(r: *R, parent: u32, name: []const u8, sep: u8) ?[*:0]const u8 {
        const ps = r.lay.paths[parent].str;
        var o: usize = 0;
        var i: usize = 0;
        while (ps[i] != 0) : (i += 1) {
            r.pbuf[o] = ps[i];
            o += 1;
            if (o >= 4000) return null;
        }
        if (sep != 0) {
            if (!(sep == '/' and o > 0 and (r.pbuf[o - 1] == '/' or r.pbuf[o - 1] == '}'))) {
                r.pbuf[o] = sep;
                o += 1;
            }
        }
        if (name.len >= 4000 - o) return null;
        @memcpy(r.pbuf[o..][0..name.len], name);
        r.pbuf[o + name.len] = 0;
        return @ptrCast(&r.pbuf);
    }

    /// prims, variant sets and properties, to the end of the file (top) or
    /// to its "}"
    fn body(r: *R, at: u32, top: bool) void {
        r.depth += 1;
        defer r.depth -= 1;
        if (r.depth > 200) {
            r.err = true;
            return;
        }
        while (true) {
            if (r.err) return;
            if (r.ty == T_EOF) {
                if (!top) r.err = true;
                return;
            }
            if (r.isp('}')) {
                if (top) {
                    r.err = true;
                    return;
                }
                r.adv();
                return;
            }
            if (r.isp(';')) {
                r.adv();
                continue;
            }
            const sp: ?u32 = if (r.is("def")) 0 else if (r.is("over")) 1 else if (r.is("class")) 2 else null;
            if (sp) |x| {
                r.adv();
                r.prim(at, x);
                continue;
            }
            if (r.is("reorder")) { // reorder nameChildren / rootPrims
                r.adv();
                r.adv();
                _ = r.want('=');
                r.skip();
                continue;
            }
            if (top) { // (top level: prims only)
                r.err = true;
                return;
            }
            if (r.is("variantSet")) {
                r.adv();
                r.varset(at);
                continue;
            }
            r.prop(at);
        }
    }

    fn intField(r: *R, s: u32, x: i64, name: [*:0]const u8) void {
        const v = r.lay.ar.val() orelse return;
        v.t = ul.UT_INT;
        v.d = @bitCast(x);
        ul.field(r.lay, s, name, v);
    }

    /// after def / over / class
    fn prim(r: *R, parent: u32, specifier: u32) void {
        var tname: Str = null;
        if (r.ty == T_ID) {
            tname = r.text(false);
            r.adv();
        }
        if (r.ty != T_STR) {
            r.err = true;
            return;
        }
        const pt = r.join(parent, r.tok(), '/') orelse {
            r.err = true;
            return;
        };
        const p = ul.path(r.lay, pt, @intCast(parent), ul.UK_PRIM) orelse {
            r.err = true;
            return;
        };
        r.adv();
        const s = ul.spec(r.lay, p, ul.SPEC_PRIM) orelse {
            r.err = true;
            return;
        };
        r.intField(s, specifier, "specifier");
        if (tname != null) {
            const v = r.lay.ar.val() orelse {
                r.err = true;
                return;
            };
            v.t = ul.UT_STR;
            v.p = @intFromPtr(tname.?);
            ul.field(r.lay, s, "typeName", v);
        }
        if (r.isp('(')) {
            r.adv();
            r.meta(s);
        }
        if (!r.want('{')) return;
        r.body(p, false);
    }

    /// prim{set=} or prim{set=sel} (with the string token's selection): the
    /// path, null when too long
    fn vpath(r: *R, at: u32, set: []const u8, sel: bool, parent: u32) ?u32 {
        const ps = r.lay.paths[at].str;
        var o: usize = 0;
        var i: usize = 0;
        while (ps[i] != 0) : (i += 1) {
            r.pbuf[o] = ps[i];
            o += 1;
            if (o >= 3000) return null;
        }
        r.pbuf[o] = '{';
        o += 1;
        @memcpy(r.pbuf[o..][0..set.len], set);
        o += set.len;
        r.pbuf[o] = '=';
        o += 1;
        if (sel) {
            if (r.tl > 900) return null;
            @memcpy(r.pbuf[o..][0..r.tl], r.tok());
            o += r.tl;
        }
        r.pbuf[o] = '}';
        r.pbuf[o + 1] = 0;
        return ul.path(r.lay, @ptrCast(&r.pbuf), @intCast(parent), ul.UK_VARIANT);
    }

    /// after variantSet: "set" = { "sel" (..) { .. } }
    fn varset(r: *R, at: u32) void {
        if (r.ty != T_STR or r.tl > 1000) {
            r.err = true;
            return;
        }
        const set = r.tok();
        r.adv();
        if (!r.want('=')) return;
        if (!r.want('{')) return;
        const sp = r.vpath(at, set, false, at) orelse {
            r.err = true;
            return;
        };
        _ = ul.spec(r.lay, sp, ul.SPEC_VARSET);
        while (true) {
            if (r.err) return;
            if (r.isp('}')) {
                r.adv();
                return;
            }
            if (r.ty != T_STR) {
                r.err = true;
                return;
            }
            const vp = r.vpath(at, set, true, sp) orelse {
                r.err = true;
                return;
            };
            r.adv();
            const s = ul.spec(r.lay, vp, ul.SPEC_VARIANT) orelse 0xffffffff;
            if (r.isp('(')) {
                r.adv();
                if (s != 0xffffffff) r.meta(s) else r.skipMeta();
            }
            if (!r.want('{')) return;
            r.body(vp, false);
        }
    }

    fn skipMeta(r: *R) void {
        while (!r.err and !r.isp(')') and r.ty != T_EOF) r.adv();
        if (r.isp(')')) r.adv();
    }

    /// an attribute or relationship
    fn prop(r: *R, at: u32) void {
        var custom: i64 = 0;
        var uniform: i64 = 0;
        r.lop = false;
        while (true) {
            if (r.is("custom")) {
                custom = 1;
                r.adv();
            } else if (r.is("uniform")) {
                uniform = 1;
                r.adv();
            } else if (r.is("varying") or r.is("config")) {
                r.adv();
            } else break;
        }
        r.listop(); // prepend / append / delete ...
        if (r.ty != T_ID) {
            r.err = true;
            return;
        }
        if (r.is("rel")) return r.rel(at, custom);
        // an attribute: type [ [] ] name[.connect | .timeSamples]
        const ty = r.tok();
        r.adv();
        var arr = false;
        if (r.isp('[')) {
            r.adv();
            if (!r.want(']')) return;
            arr = true;
        }
        if (r.ty != T_ID) {
            r.err = true;
            return;
        }
        var nl = r.tl;
        var sfx: u32 = 0; // 1 .connect, 2 .timeSamples
        if (suffix(r.tok(), ".connect")) {
            nl -= 8;
            sfx = 1;
        } else if (suffix(r.tok(), ".timeSamples")) {
            nl -= 12;
            sfx = 2;
        }
        const pt = r.join(at, r.tok()[0..nl], '.') orelse {
            r.err = true;
            return;
        };
        const p = ul.path(r.lay, pt, @intCast(at), ul.UK_PROP) orelse {
            r.err = true;
            return;
        };
        const s = ul.spec(r.lay, p, ul.SPEC_ATTR) orelse {
            r.err = true;
            return;
        };
        r.adv();
        r.intField(s, custom, "custom"); // custom, type name, variability
        r.intField(s, uniform, "variability");
        const tn = r.lay.ar.alloc(ty.len + 3) orelse {
            r.err = true;
            return;
        };
        @memcpy(tn[0..ty.len], ty);
        if (arr) {
            tn[ty.len] = '[';
            tn[ty.len + 1] = ']';
        }
        const tv = r.lay.ar.val() orelse {
            r.err = true;
            return;
        };
        tv.t = ul.UT_STR;
        tv.p = @intFromPtr(tn);
        ul.field(r.lay, s, "typeName", tv);
        if (r.isp('=')) {
            r.adv();
            switch (sfx) {
                1 => {
                    const v = r.paths() orelse {
                        r.err = true;
                        return;
                    };
                    ul.field(r.lay, s, "connectionPaths", v);
                },
                2 => {
                    r.skip();
                    const v = r.lay.ar.val() orelse {
                        r.err = true;
                        return;
                    };
                    ul.field(r.lay, s, "timeSamples", v);
                },
                else => {
                    const v = r.value(ty, arr) orelse {
                        r.err = true;
                        return;
                    };
                    ul.field(r.lay, s, "default", v);
                },
            }
        }
        if (r.isp('(')) {
            r.adv();
            r.meta(s);
        }
    }

    /// rel name [= targets] [( .. )]
    fn rel(r: *R, at: u32, custom: i64) void {
        r.adv();
        if (r.ty != T_ID) {
            r.err = true;
            return;
        }
        const pt = r.join(at, r.tok(), '.') orelse {
            r.err = true;
            return;
        };
        const p = ul.path(r.lay, pt, @intCast(at), ul.UK_PROP) orelse {
            r.err = true;
            return;
        };
        const s = ul.spec(r.lay, p, ul.SPEC_REL) orelse {
            r.err = true;
            return;
        };
        r.adv();
        if (custom != 0) r.intField(s, custom, "custom"); // custom only when it is; uniform always
        r.intField(s, 1, "variability");
        if (r.isp('=')) {
            r.adv();
            const v = r.paths() orelse {
                r.err = true;
                return;
            };
            r.setlist(s, "targetPaths", v);
        }
        if (r.isp('(')) {
            r.adv();
            r.meta(s);
        }
    }

    /// each spec's primChildren and properties (and a prim's
    /// variantSetChildren, a variant set's variantChildren) from its paths, in
    /// the order they were met
    fn children(r: *R) void {
        const l = r.lay;
        const np: usize = l.npath;
        const cnt = A.alloc(u32, np * 4 + 4) catch return;
        defer A.free(cnt);
        @memset(cnt, 0);
        const lists = A.alloc(?[*]Str, np * 4 + 4) catch return;
        defer A.free(lists);
        @memset(lists, null);
        var pass: u32 = 1;
        while (pass <= 2) : (pass += 1) {
            for (l.paths[0..np]) |*p| {
                if (p.parent < 0) continue;
                const li: usize = switch (p.kind) {
                    ul.UK_PRIM => 0,
                    ul.UK_PROP => 1,
                    ul.UK_VARIANT => 2,
                    else => continue,
                };
                const slot = @as(usize, @intCast(p.parent)) * 4 + li;
                if (pass == 1) {
                    cnt[slot] += 1;
                    continue;
                }
                const o = lists[slot] orelse continue;
                o[cnt[slot]] = lastName(l, p.str);
                cnt[slot] += 1;
            }
            if (pass == 1) {
                for (0..np * 4) |c| {
                    if (cnt[c] != 0) lists[c] = l.ar.many(Str, @as(usize, cnt[c]) + 1);
                    cnt[c] = 0;
                }
            }
        }
        for (l.paths[0..np], 0..) |*p, i| {
            if (p.spec < 0) continue;
            for (0..3) |li| {
                const slot = i * 4 + li;
                if (cnt[slot] == 0) continue;
                const v = l.ar.val() orelse continue;
                v.t = ul.UT_SLIST;
                v.n = cnt[slot];
                v.p = if (lists[slot]) |o| @intFromPtr(o) else 0;
                const name: [*:0]const u8 = switch (li) {
                    0 => "primChildren",
                    1 => "properties",
                    else => if (p.kind == ul.UK_VARIANT) "variantChildren" else "variantSetChildren", // a prim's sets; a set's variants
                };
                ul.field(l, @intCast(p.spec), name, v);
            }
        }
    }
};

fn idstart(c: u8) bool {
    const l = c | 0x20;
    return (l >= 'a' and l <= 'z') or c == '_';
}

fn suffix(t: []const u8, s: []const u8) bool {
    return t.len > s.len and std.mem.eql(u8, t[t.len - s.len ..], s);
}

fn keyRow(k: []const u8) u32 {
    for (keys, 1..) |x, i| {
        if (std.mem.eql(u8, x, k)) return @intCast(i);
    }
    return 0;
}

fn strcmp(a: Str, b: Str) i32 {
    const x = a orelse empty;
    const y = b orelse empty;
    var i: usize = 0;
    while (true) : (i += 1) {
        const d = @as(i32, x[i]) - @as(i32, y[i]);
        if (d != 0 or y[i] == 0) return d;
    }
}

/// (kind, components) of a declared type: 1 scalar, 2 .. 4, 16 matrix4, 9
/// matrix3, 4 matrix2
pub fn tkind(t: []const u8) [2]u32 {
    var comps: u32 = 1;
    const n = t.len;
    digits: {
        if (n >= 4 and t[n - 2] == '6' and t[n - 1] == '4') break :digits; // (int64 / uint64: one)
        if (n > 0) {
            const d = t[n - 1] -% '0';
            if (d >= 2 and d <= 4) {
                comps = d;
                break :digits;
            }
        }
        if (n >= 2) { // point3f, texCoord2h ...: a digit before the last letter
            const d = t[n - 2] -% '0';
            if (d >= 2 and d <= 4) comps = d;
        }
    }
    const c0: u8 = if (n > 0) t[0] else 0;
    const c1: u8 = if (n > 1) t[1] else 0;
    return switch (c0) {
        'q' => .{ VK_QUAT, 4 },
        'm' => .{ VK_MAT, comps * comps },
        'f' => if (c1 == 'r') .{ VK_MAT, 16 } else .{ VK_FLT, comps },
        's', 'a' => .{ VK_TXT, 1 },
        't' => if (c1 == 'o') .{ VK_TXT, 1 } else .{ VK_FLT, comps },
        'b', 'i', 'u' => .{ VK_INT, comps },
        else => .{ VK_FLT, comps },
    };
}

/// 1 when its numbers are float32, 2 when half (not double, timecode or an
/// int): float*, *f; half*, *h
pub fn singleOf(t: []const u8) u32 {
    if (t.len == 0) return 0;
    if (std.mem.startsWith(u8, t, "half") or t[t.len - 1] == 'h') return 2;
    if (std.mem.startsWith(u8, t, "floa") or t[t.len - 1] == 'f') return 1;
    return 0;
}

/// rounded to float32 (1) or half (2) precision (to the nearest, ties to
/// even), as the crate keeps it
pub fn round(x: f64, mode: u32) f64 {
    var f: f32 = @floatCast(x);
    if (mode == 2) {
        var b: u32 = @bitCast(f); // a half's 10 mantissa bits
        b = (b +% ((b >> 13) & 1) +% 0x0fff) & 0xffffe000;
        f = @bitCast(b);
    }
    return f;
}

/// its last element as a new text: a prim's or property's name; for
/// prim{set=}: "set"; for prim{set=sel}: "sel"
fn lastName(l: *Layer, s0: [*:0]const u8) Str {
    const s = ul.cstr(s0);
    const e = s.len;
    if (e > 0 and s[e - 1] == '}') { // a variant path
        var c = e - 1; // back to its '{'
        while (c > 0 and s[c] != '{') c -= 1;
        if (c == 0) return empty;
        var q = c + 1;
        // (the original looks for the '=' with no end: a name holding "{"
        // and "}" but no "=" sends it past the text)
        while (q < e and s[q] != '=') q += 1;
        if (q >= e) return empty;
        if (q + 1 < e and s[q + 1] == '}') return l.ar.dup(s[c + 1 .. q]) orelse empty; // set
        return l.ar.dup(s[q + 1 .. e - 1]) orelse empty;
    }
    var c = e; // after the last / or . (or })
    while (c > 0) : (c -= 1) {
        const x = s[c - 1];
        if (x == '/' or x == '.' or x == '}') break;
    }
    if (c == 0) return empty;
    return l.ar.dup(s[c..e]) orelse empty;
}

/// usda_read: the layer, null (usdc.err says why).
pub fn read(path: []const u8) ?*Layer {
    const map = ul.mapFile(path) orelse {
        usdc.err = usdc.e_open;
        return null;
    };
    const lay = ul.new() orelse {
        ul.unmapFile(map);
        usdc.err = usdc.e_mem;
        return null;
    };
    lay.map = map;
    lay.file = lay.ar.dup(path) orelse "";
    if (map.len < 5 or !std.mem.eql(u8, map[0..4], "#usd") or map[4] != 'a') {
        ul.free(lay);
        usdc.err = e_bad;
        return null;
    }
    var r = R{ .lay = lay, .m = map, .end = map.len };
    defer r.nums.deinit(A);
    defer r.list.deinit(A);
    r.adv(); // (the "#usda 1.0" line is a comment)
    const root = ul.path(lay, "/", -1, ul.UK_ROOT) orelse 0;
    const s = ul.spec(lay, root, ul.SPEC_ROOT) orelse 0;
    if (r.isp('(')) {
        r.adv();
        r.meta(s);
    }
    r.body(0, true);
    if (r.err) {
        const t = std.fmt.bufPrint(&ebuf, "{s}{d}", .{ e_syn, r.line }) catch e_syn;
        ul.free(lay);
        usdc.err = t;
        return null;
    }
    r.children();
    return lay;
}

test "usda: numbers as the original parses them, kinds, rounding" {
    const T = struct {
        fn n(s: []const u8) f64 {
            var r = R{ .lay = undefined, .m = s, .tl = s.len };
            return r.number();
        }
    };
    try std.testing.expectEqual(@as(f64, 1.5), T.n("1.5"));
    try std.testing.expectEqual(@as(f64, -0.25), T.n("-.25"));
    try std.testing.expectEqual(@as(f64, 0.0), T.n("-0")); // (0 - 0: plus zero)
    try std.testing.expect(!std.math.signbit(T.n("-0")));
    try std.testing.expectEqual(@as(f64, 1e30), T.n("1e30"));
    try std.testing.expectEqual(@as(f64, 120), T.n("1.2E2"));
    try std.testing.expect(std.math.isNan(T.n("-nan")));
    try std.testing.expect(std.math.isInf(T.n("-inf")) and T.n("-inf") < 0);
    try std.testing.expectEqual(@as(f64, 123456789012345678e3), T.n("123456789012345678999"));
    try std.testing.expectEqual([2]u32{ VK_FLT, 3 }, tkind("point3f"));
    try std.testing.expectEqual([2]u32{ VK_MAT, 16 }, tkind("matrix4d"));
    try std.testing.expectEqual([2]u32{ VK_INT, 1 }, tkind("int64"));
    try std.testing.expectEqual([2]u32{ VK_TXT, 1 }, tkind("token"));
    try std.testing.expectEqual([2]u32{ VK_FLT, 2 }, tkind("texCoord2f"));
    try std.testing.expectEqual([2]u32{ VK_QUAT, 4 }, tkind("quath"));
    try std.testing.expectEqual([2]u32{ VK_MAT, 16 }, tkind("frame4d"));
    try std.testing.expectEqual(@as(u32, 2), singleOf("color3h"));
    try std.testing.expectEqual(@as(u32, 1), singleOf("float"));
    try std.testing.expectEqual(@as(u32, 0), singleOf("double3"));
    try std.testing.expectEqual(@as(f64, 0.0999755859375), round(0.1, 2));
    try std.testing.expectEqual(@as(f64, @as(f32, 0.1)), round(0.1, 1));
}

test "usda: a stale token length past the file's end stops at the end (gate28's abort)" {
    const s = "kind = \"abc";
    var r = R{ .lay = undefined, .m = s, .end = s.len, .tp = s.len - 2, .tl = 4581 };
    try std.testing.expectEqualStrings("bc", r.tok());
    r.tp = s.len + 10;
    try std.testing.expectEqual(@as(usize, 0), r.tok().len);
}
