// JSON as the original's json.s: a lazy reader that walks the request text on
// demand (no tree is built) and a writer that appends to a growable buffer.
//
// Reader: positions are indices into the text `t`; every function stops at its
// end (the original's j_end). It is not a general parser: j_find walks the keys
// of one object and compares them unescaped, j_skip skips a value by bracket
// depth. A message is checked with valid() (strict RFC 8259) first, so the walk
// only ever sees well-formed text; out-of-range reads give 0 here (the
// original read the bytes after the line).
//
// Writer: W, with the original's number formats: float() is wb_float (six
// decimals, rounded half to even), num() is jb_num (the same, trailing zeros
// and a bare point cut), q() is jb_q (\" \\ \n and \u00XX escapes).
const std = @import("std");

// ---- reader ------------------------------------------------------------------

fn at(t: []const u8, i: usize) u8 {
    return if (i < t.len) t[i] else 0;
}

/// j_ws: past spaces, tabs, newlines and carriage returns.
pub fn ws(t: []const u8, from: usize) usize {
    var i = from;
    while (i < t.len and (t[i] == ' ' or t[i] == 9 or t[i] == 10 or t[i] == 13)) i += 1;
    return i;
}

/// j_skip: just past the value at i (strings, objects, arrays, numbers and
/// literals; nesting tracked with a depth counter).
pub fn skip(t: []const u8, from: usize) usize {
    var i = ws(t, from);
    var depth: usize = 0;
    while (i < t.len) {
        const c = t[i];
        switch (c) {
            '"' => {
                i += 1;
                while (true) {
                    if (i >= t.len) return i;
                    const s = t[i];
                    i += 1;
                    if (s == '\\') {
                        i += 1;
                        continue;
                    }
                    if (s == '"') break;
                }
                if (depth == 0) return i;
            },
            '{', '[' => {
                depth += 1;
                i += 1;
            },
            '}', ']' => {
                if (depth == 0) return i; // the closing bracket of an enclosing value
                depth -= 1;
                i += 1;
                if (depth == 0) return i;
            },
            else => {
                if (depth == 0 and (c == ',' or c == ' ' or c == 10 or c == 13 or c == 9)) return i;
                i += 1;
            },
        }
    }
    return i;
}

/// j_find: the value of `key` in the object at obj, or null.
pub fn find(t: []const u8, obj: usize, key: []const u8) ?usize {
    var i = ws(t, obj);
    if (i >= t.len or t[i] != '{') return null;
    i += 1;
    while (true) {
        i = ws(t, i);
        if (i >= t.len or t[i] != '"') return null;
        i += 1;
        var k: usize = 0;
        while (k < key.len and key[k] == at(t, i + k)) k += 1;
        if (k == key.len and at(t, i + k) == '"') {
            i = ws(t, i + k + 1);
            if (at(t, i) != ':') return null;
            return ws(t, i + 1);
        }
        // not this key: skip "key": value,
        i = ws(t, skip(t, i - 1));
        if (at(t, i) != ':') return null;
        i = ws(t, skip(t, i + 1));
        if (at(t, i) != ',') return null;
        i += 1;
    }
}

/// j_str: the string at v unescaped into dest (cap = dest.len, one byte kept
/// for the original's terminator: at most dest.len - 1 bytes; the rest is
/// dropped). null when it is not a string. \uXXXX becomes UTF-8 (BMP).
pub fn str(t: []const u8, v: usize, dest: []u8) ?[]u8 {
    var i = ws(t, v);
    if (i >= t.len or t[i] != '"') return null;
    i += 1;
    var n: usize = 0;
    const room: usize = dest.len -| 1;
    while (i < t.len) {
        var c = t[i];
        i += 1;
        if (c == '"') break;
        if (c == '\\') {
            c = at(t, i);
            i += 1;
            switch (c) {
                'n' => c = 10,
                't' => c = 9,
                'r' => c = 13,
                'b' => c = 8,
                'f' => c = 12,
                'u' => {
                    var code: u32 = 0;
                    for (0..4) |_| {
                        const h = at(t, i);
                        i += 1;
                        var d: u32 = @as(u32, h) -% '0';
                        if (d > 9) d = (@as(u32, h) | 0x20) -% ('a' - 10);
                        code = (code << 4) | d;
                    }
                    if (code < 0x80) {
                        c = @truncate(code);
                    } else if (code < 0x800) {
                        if (n + 2 > room) break;
                        dest[n] = @truncate((code >> 6) | 0xc0);
                        n += 1;
                        c = @truncate((code & 0x3f) | 0x80);
                    } else {
                        if (n + 3 > room) break;
                        dest[n] = @truncate((code >> 12) | 0xe0);
                        dest[n + 1] = @truncate(((code >> 6) & 0x3f) | 0x80);
                        n += 2;
                        c = @truncate((code & 0x3f) | 0x80);
                    }
                },
                else => {}, // \" \\ \/ -> the character itself
            }
        }
        if (n >= room) continue; // full: drop the rest
        dest[n] = c;
        n += 1;
    }
    return dest[0..n];
}

pub const Num = struct { v: f32, ok: bool };

/// j_num: the number at v (parse_float: "-1.5e3" style, the value 0 and ok
/// false when there are no digits).
pub fn num(t: []const u8, v: usize) Num {
    var i = ws(t, v);
    while (i < t.len and (t[i] == ' ' or t[i] == 9)) i += 1;
    var x: f64 = 0;
    var neg = false;
    var digits: u32 = 0;
    if (i < t.len and t[i] == '-') {
        neg = true;
        i += 1;
    } else if (i < t.len and t[i] == '+') i += 1;
    while (i < t.len and t[i] -% '0' <= 9) : (i += 1) {
        x = x * 10.0 + @as(f64, @floatFromInt(t[i] - '0'));
        digits += 1;
    }
    if (i < t.len and t[i] == '.') {
        i += 1;
        var u: f64 = 1;
        while (i < t.len and t[i] -% '0' <= 9) : (i += 1) {
            u /= 10.0;
            x += @as(f64, @floatFromInt(t[i] - '0')) * u;
            digits += 1;
        }
    }
    if (i < t.len and t[i] | 0x20 == 'e') {
        i += 1;
        var eneg = false;
        if (at(t, i) == '-') {
            eneg = true;
            i += 1;
        } else if (at(t, i) == '+') i += 1;
        var e: u32 = 0;
        while (i < t.len and t[i] -% '0' <= 9) : (i += 1) e = e *% 10 +% (t[i] - '0');
        if (e > 38) e = 38;
        while (e > 0) : (e -= 1) x = if (eneg) x / 10.0 else x * 10.0;
    }
    if (neg) x = 0.0 - x;
    return .{ .v = @floatCast(x), .ok = digits > 0 };
}

/// j_bool: true only for the literal true.
pub fn boolean(t: []const u8, v: usize) bool {
    const i = ws(t, v);
    return i + 4 <= t.len and std.mem.eql(u8, t[i .. i + 4], "true");
}

/// j_first: the first element of the array at a, or null (empty, not an array).
pub fn first(t: []const u8, a: usize) ?usize {
    var i = ws(t, a);
    if (at(t, i) != '[') return null;
    i = ws(t, i + 1);
    if (at(t, i) == ']') return null;
    return i;
}

/// j_next: the element after el in the same array, or null.
pub fn next(t: []const u8, el: usize) ?usize {
    const i = ws(t, skip(t, el));
    if (at(t, i) != ',') return null;
    return ws(t, i + 1);
}

// ---- strict validation (j_valid) -----------------------------------------------

const MAX_DEPTH = 64;

const V = struct {
    t: []const u8,
    i: usize = 0,
    depth: u32 = 0,

    fn wsp(v: *V) void {
        v.i = ws(v.t, v.i);
    }
    fn lit(v: *V, l: []const u8) bool {
        for (l) |c| {
            if (v.i >= v.t.len or v.t[v.i] != c) return false;
            v.i += 1;
        }
        return true;
    }
    fn value(v: *V) bool {
        if (v.i >= v.t.len) return false;
        const c = v.t[v.i];
        return switch (c) {
            '{' => v.object(),
            '[' => v.array(),
            '"' => v.string(),
            '-', '0'...'9' => v.number(),
            't' => v.lit("true"),
            'f' => v.lit("false"),
            'n' => v.lit("null"),
            else => false,
        };
    }
    fn object(v: *V) bool {
        v.depth += 1;
        if (v.depth > MAX_DEPTH) return false;
        v.i += 1;
        v.wsp();
        if (v.i >= v.t.len) return false;
        if (v.t[v.i] != '}') {
            while (true) {
                v.wsp();
                if (v.i >= v.t.len or v.t[v.i] != '"') return false;
                if (!v.string()) return false;
                v.wsp();
                if (v.i >= v.t.len or v.t[v.i] != ':') return false;
                v.i += 1;
                v.wsp();
                if (!v.value()) return false;
                v.wsp();
                if (v.i >= v.t.len) return false;
                if (v.t[v.i] == ',') {
                    v.i += 1;
                    continue;
                }
                if (v.t[v.i] != '}') return false;
                break;
            }
        }
        v.i += 1;
        v.depth -= 1;
        return true;
    }
    fn array(v: *V) bool {
        v.depth += 1;
        if (v.depth > MAX_DEPTH) return false;
        v.i += 1;
        v.wsp();
        if (v.i >= v.t.len) return false;
        if (v.t[v.i] != ']') {
            while (true) {
                v.wsp();
                if (!v.value()) return false;
                v.wsp();
                if (v.i >= v.t.len) return false;
                if (v.t[v.i] == ',') {
                    v.i += 1;
                    continue;
                }
                if (v.t[v.i] != ']') return false;
                break;
            }
        }
        v.i += 1;
        v.depth -= 1;
        return true;
    }
    fn string(v: *V) bool {
        v.i += 1;
        while (v.i < v.t.len) {
            const c = v.t[v.i];
            v.i += 1;
            if (c == '"') return true;
            if (c < 0x20) return false; // raw control characters are invalid
            if (c != '\\') continue;
            if (v.i >= v.t.len) return false;
            const e = v.t[v.i];
            v.i += 1;
            if (std.mem.indexOfScalar(u8, "\"\\/bfnrtu", e) == null) return false;
            if (e != 'u') continue;
            for (0..4) |_| {
                if (v.i >= v.t.len) return false;
                const h = v.t[v.i];
                v.i += 1;
                if (!std.ascii.isHex(h)) return false;
            }
        }
        return false;
    }
    fn digit(v: *V) bool {
        if (v.i < v.t.len and v.t[v.i] -% '0' <= 9) {
            v.i += 1;
            return true;
        }
        return false;
    }
    // -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?
    fn number(v: *V) bool {
        if (v.t[v.i] == '-') v.i += 1;
        if (!v.digit()) return false;
        if (v.t[v.i - 1] != '0') {
            while (v.digit()) {}
        }
        if (v.i >= v.t.len) return true;
        if (v.t[v.i] == '.') {
            v.i += 1;
            if (!v.digit()) return false;
            while (v.digit()) {}
        }
        if (v.i >= v.t.len) return true;
        if (v.t[v.i] | 0x20 != 'e') return true;
        v.i += 1;
        if (v.i >= v.t.len) return false;
        if (v.t[v.i] == '+' or v.t[v.i] == '-') v.i += 1;
        if (!v.digit()) return false;
        while (v.digit()) {}
        return true;
    }
};

/// j_valid: the text is exactly one JSON value (strict RFC 8259 syntax;
/// nesting limited to 64 levels).
pub fn valid(t: []const u8) bool {
    var v = V{ .t = t };
    v.wsp();
    if (!v.value()) return false;
    v.wsp();
    return v.i == t.len;
}

// ---- writer --------------------------------------------------------------------

const hex = "0123456789abcdef";

/// A growable text (the original's wb_* buffer). Out of memory: the rest is
/// dropped, as wb_reserve failing.
pub const W = struct {
    b: std.ArrayList(u8) = .empty,

    const A = std.heap.page_allocator;

    pub fn reset(w: *W) void {
        w.b.clearRetainingCapacity();
    }
    pub fn items(w: *const W) []const u8 {
        return w.b.items;
    }
    pub fn len(w: *const W) usize {
        return w.b.items.len;
    }
    /// wb_str / jb_raw: as it is (to a NUL, as the original's asciz).
    pub fn raw(w: *W, s: []const u8) void {
        const n = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
        w.b.appendSlice(A, s[0..n]) catch {};
    }
    /// wb_bytes: every byte.
    pub fn bytes(w: *W, s: []const u8) void {
        w.b.appendSlice(A, s) catch {};
    }
    pub fn char(w: *W, c: u8) void {
        w.b.append(A, c) catch {};
    }
    /// jb_q: a quoted string (to a NUL) with \" \\ \n and \u00XX escapes.
    pub fn q(w: *W, s: []const u8) void {
        w.char('"');
        for (s) |c| {
            if (c == 0) break;
            if (c == '"' or c == '\\') {
                w.char('\\');
                w.char(c);
            } else if (c == 10) {
                w.bytes("\\n");
            } else if (c < 0x20) {
                w.bytes("\\u00");
                w.char(hex[c >> 4]);
                w.char(hex[c & 15]);
            } else w.char(c);
        }
        w.char('"');
    }
    /// jb_key: "key":
    pub fn key(w: *W, s: []const u8) void {
        w.q(s);
        w.char(':');
    }
    /// wb_int
    pub fn int(w: *W, v: i64) void {
        var b: [24]u8 = undefined;
        w.bytes(std.fmt.bufPrint(&b, "{d}", .{v}) catch "0");
    }
    /// wb_float: "-12.345678" (six decimals, rounded half to even as
    /// cvtsd2si; NaN, infinities and |x| >= 9.2e12 give its overflow value).
    pub fn float(w: *W, v: f32) void {
        var b: [40]u8 = undefined;
        w.bytes(fmtFloat(&b, v));
    }
    /// jb_num: wb_float with the trailing zeros (and then a bare point) cut.
    pub fn num(w: *W, v: f32) void {
        const start = w.b.items.len;
        w.float(v);
        var n = w.b.items.len;
        while (n > start and w.b.items[n - 1] == '0') n -= 1;
        if (n > start and w.b.items[n - 1] == '.') n -= 1;
        w.b.items.len = n;
    }
    /// base64 of data (the image blocks).
    pub fn base64(w: *W, data: []const u8) void {
        const n = std.base64.standard.Encoder.calcSize(data.len);
        const dst = w.b.addManyAsSlice(A, n) catch return;
        _ = std.base64.standard.Encoder.encode(dst, data);
    }
};

/// wb_float's text.
pub fn fmtFloat(b: []u8, v: f32) []const u8 {
    const d: f64 = v;
    const neg = !(d >= 0); // (comisd: NaN takes the negative path)
    const x = @abs(d) * 1e6;
    if (!(x < 9.223372036854775808e18)) {
        // cvtsd2si's "integer indefinite", divided unsigned by a million
        return if (neg) "-9223372036854.775808" else "9223372036854.775808";
    }
    var r = @floor(x);
    const diff = x - r;
    if (diff > 0.5 or (diff == 0.5 and @mod(r, 2) == 1)) r += 1;
    const qv: u64 = @intFromFloat(r);
    return std.fmt.bufPrint(b, "{s}{d}.{d:0>6}", .{ if (neg) "-" else "", qv / 1000000, qv % 1000000 }) catch "0.000000";
}

// ---- tests -------------------------------------------------------------------------

const testing = std.testing;

test "valid: strict syntax, depth 64" {
    try testing.expect(valid("{}"));
    try testing.expect(valid(" {\"a\": [1, -2.5e+3, true, false, null, \"x\\u00e9\\n\"]} "));
    try testing.expect(!valid("{\"a\":1,}"));
    try testing.expect(!valid("[1,]"));
    try testing.expect(!valid("01"));
    try testing.expect(!valid("1."));
    try testing.expect(!valid("1e"));
    try testing.expect(!valid("\"a\tb\""));
    try testing.expect(!valid("\"\\x\""));
    try testing.expect(!valid("\"\\u12g4\""));
    try testing.expect(!valid("{} {}"));
    try testing.expect(!valid(""));
    try testing.expect(!valid("tru"));
    var deep: [130]u8 = undefined;
    @memset(deep[0..64], '[');
    @memset(deep[64..128], ']');
    try testing.expect(valid(deep[0..128]));
    @memset(deep[0..65], '[');
    @memset(deep[65..130], ']');
    try testing.expect(!valid(deep[0..130]));
}

test "find, str, num, first, next" {
    const t = "{\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"x\",\"arguments\":{\"v\":[1, 2.5,-3],\"s\":\"a\\\"b\\u00e9\\u20ac\"}}}";
    try testing.expectEqualStrings("7", t[find(t, 0, "id").?..skip(t, find(t, 0, "id").?)]);
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("tools/call", str(t, find(t, 0, "method").?, &b).?);
    const p = find(t, 0, "params").?;
    const a = find(t, p, "arguments").?;
    var e = first(t, find(t, a, "v").?).?;
    try testing.expectEqual(@as(f32, 1), num(t, e).v);
    e = next(t, e).?;
    try testing.expectEqual(@as(f32, 2.5), num(t, e).v);
    e = next(t, e).?;
    try testing.expectEqual(@as(f32, -3), num(t, e).v);
    try testing.expect(next(t, e) == null);
    try testing.expectEqualStrings("a\"b\xc3\xa9\xe2\x82\xac", str(t, find(t, a, "s").?, &b).?);
    try testing.expect(find(t, 0, "nope") == null);
    try testing.expect(str(t, find(t, 0, "id").?, &b) == null);
    // capacity: one byte kept for the terminator, the rest dropped
    var s4: [4]u8 = undefined;
    try testing.expectEqualStrings("too", str("\"toolong\"", 0, &s4).?);
}

test "writer: jb_num, wb_float, jb_q" {
    var w: W = .{};
    defer w.b.deinit(W.A);
    w.num(1);
    w.char(',');
    w.num(-27.673862);
    w.char(',');
    w.num(0.1);
    w.char(',');
    w.num(-0.0);
    w.char(',');
    w.num(-1e-9);
    w.char(',');
    w.num(std.math.nan(f32));
    w.char(',');
    w.float(2.5);
    w.char(',');
    w.q("a\"b\\c\nd\x01");
    try testing.expectEqualStrings("1,-27.673862,0.1,0,-0,-9223372036854.775808,2.500000,\"a\\\"b\\\\c\\nd\\u0001\"", w.items());
    w.reset();
    w.base64("hello");
    try testing.expectEqualStrings("aGVsbG8=", w.items());
}
