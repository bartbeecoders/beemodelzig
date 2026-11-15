// What a page of a plan set is (refset.s): its kind, level, state, title and
// scale, from the words of its file name and of the text pdftotext read from
// it. Belgian / Dutch sets: "P_N Gelijkvloers", "G_B Voorgevel". No file or
// scene here: text in, words out. The text is untrusted.
const std = @import("std");

pub const Kind = enum(u8) { none, front, back, left, right, elev, plan, section, site, terrain, legend, other };
pub const LV_ROOF = 9;
pub const LV_NONE = 99;
pub const TXT_CAP = 122880;

pub const names = [_][]const u8{ "?", "front", "back", "left", "right", "elevation", "plan", "section", "site", "terrain", "legend", "other" };

pub fn kindName(k: Kind) []const u8 {
    return names[@intFromEnum(k)];
}

const W = struct { []const u8, Kind };
// the first that matches; specific ones before general ones
const kind_words = [_]W{
    .{ "legende", .legend },            .{ "legend", .legend },
    .{ "terreinprofiel", .terrain },    .{ "terrein profiel", .terrain },  .{ "terrain profile", .terrain }, .{ "terreinsnede", .terrain },
    .{ "inplanting", .site },           .{ "situatie", .site },            .{ "situering", .site },           .{ "siteplan", .site },
    .{ "site plan", .site },            .{ "plan masse", .site },          .{ "ligging", .site },             .{ "omgevingsplan", .site },
    .{ "doorsnede", .section },         .{ "dwarssnede", .section },       .{ "langssnede", .section },       .{ "snede", .section },
    .{ "section", .section },           .{ "coupe", .section },            .{ "voorgevel", .front },          .{ "vooraanzicht", .front },
    .{ "front elevation", .front },     .{ "achtergevel", .back },         .{ "achteraanzicht", .back },      .{ "back elevation", .back },
    .{ "linkergevel", .left },          .{ "gevel links", .left },         .{ "linker zijgevel", .left },     .{ "rechtergevel", .right },
    .{ "gevel rechts", .right },        .{ "rechter zijgevel", .right },   .{ "zijgevel", .elev },            .{ "gevel", .elev },
    .{ "elevation", .elev },            .{ "facade", .elev },              .{ "aanzicht", .elev },            .{ " 3d ", .other },
    .{ "perspectief", .other },         .{ "perspective", .other },        .{ "totaalbeeld", .other },        .{ "render", .other },
    .{ "detail", .other },              .{ "grondplan", .plan },           .{ "plattegrond", .plan },         .{ "gelijkvloers", .plan },
    .{ "verdieping", .plan },           .{ "kelder", .plan },              .{ "fundering", .plan },           .{ "dakenplan", .plan },
    .{ "zolder", .plan },               .{ "begane grond", .plan },        .{ "roof plan", .plan },           .{ "floor", .plan },
    .{ "plan", .plan },                 .{ "front", .front },              .{ "rear", .back },                .{ "left", .left },
    .{ "right", .right },
};
const side_words = [_]W{ .{ "front", .front }, .{ "voor", .front }, .{ "rear", .back }, .{ "back", .back }, .{ "achter", .back }, .{ "left", .left }, .{ "links", .left }, .{ "right", .right }, .{ "rechts", .right } };
const label_words = [_][]const u8{ "drawing ", "titel ", "title ", "tekening " };
const L = struct { []const u8, i32 };
const level_words = [_]L{
    .{ "kelder", -1 },          .{ "souterrain", -1 },       .{ "basement", -1 },        .{ "fundering", -2 },       .{ "foundation", -2 },
    .{ "gelijkvloers", 0 },     .{ "begane grond", 0 },      .{ "ground floor", 0 },     .{ "benedenverdieping", 0 }, .{ " plan -1 ", -1 },
    .{ " plan 0 ", 0 },         .{ " plan 1 ", 1 },          .{ " plan 2 ", 2 },         .{ "verdieping +2", 2 },    .{ "verdieping 2", 2 },
    .{ "2e verdieping", 2 },    .{ "tweede verdieping", 2 }, .{ "second floor", 2 },     .{ " +2 ", 2 },             .{ "verdieping +1", 1 },
    .{ "verdieping 1", 1 },     .{ "1e verdieping", 1 },     .{ "eerste verdieping", 1 }, .{ "first floor", 1 },     .{ " +1 ", 1 },
    .{ "verdieping", 1 },       .{ "zolder", LV_ROOF },      .{ "dak", LV_ROOF },        .{ "roof", LV_ROOF },
};
const scales = [_]u32{ 10, 20, 25, 50, 75, 100, 125, 150, 200, 250, 300, 400, 500, 1000, 1250, 2000, 2500, 5000, 10000 };
const code_kinds = [_]struct { u8, Kind }{ .{ 'g', .elev }, .{ 'p', .plan }, .{ 's', .section }, .{ 'i', .site }, .{ 'l', .legend }, .{ 't', .terrain }, .{ 'd', .other } };
const scale_words = [_][]const u8{ "schaal", "scale", "chelle", "stab" };

fn has(t: []const u8, w: []const u8) bool {
    return std.mem.indexOf(u8, t, w) != null;
}

/// The kind a lowered text's words say (.none: none).
pub fn words(t: []const u8) Kind {
    for (kind_words) |w| {
        if (has(t, w[0])) return w[1];
    }
    return .none;
}

pub fn level(t: []const u8) i32 {
    for (level_words) |w| {
        if (has(t, w[0])) return w[1];
    }
    return LV_NONE;
}

pub fn side(t: []const u8) Kind {
    for (side_words) |w| {
        if (has(t, w[0])) return w[1];
    }
    return .none;
}

/// Lowered (ASCII) into dst, 0 bytes as spaces: its length.
fn lowerInto(dst: []u8, s: []const u8) usize {
    const n = @min(s.len, dst.len);
    for (s[0..n], 0..) |c, i| dst[i] = if (c == 0) ' ' else std.ascii.toLower(c);
    return n;
}

/// "_ . , ( ) : ; /" and tabs become spaces, and a space goes before and after
/// it all (words match " plan "). In place: buf holds text in [0..n], room for two more.
fn spaced(buf: []u8, n0: usize) []u8 {
    const n = @min(n0, buf.len - 2);
    std.mem.copyBackwards(u8, buf[1 .. n + 1], buf[0..n]);
    buf[0] = ' ';
    buf[n + 1] = ' ';
    for (buf[0 .. n + 2]) |*c| {
        switch (c.*) {
            '_', '.', ',', '(', ')', ':', ';', '/', 9, 13 => c.* = ' ',
            else => {},
        }
    }
    return buf[0 .. n + 2];
}

fn at(t: []const u8, i: usize) u8 {
    return if (i < t.len) t[i] else 0;
}

pub const Code = struct { kind: Kind = .none, old: bool = false, title: ?usize = null };

/// The plan-set code in a lowered, spaced text (" g n ", " p b " ...). mode 1:
/// only at a line's start; 2: a file name, the letter alone too ("_L_legende").
pub fn code(t: []const u8, mode0: u32) Code {
    var mode = mode0;
    while (true) {
        var i: usize = 0;
        while (i < t.len) : (i += 1) {
            const c = t[i];
            if (c == 0) break;
            if (c != 10 and (mode == 1 or c != ' ')) continue;
            if (at(t, i + 2) != ' ') continue;
            var d: u8 = 'n';
            var tl: usize = undefined;
            if (mode == 3) {
                const l = at(t, i + 3);
                if (l < 'a' or l > 'z') continue;
                tl = i + 3;
            } else {
                if (at(t, i + 4) != ' ' and at(t, i + 4) != 10) continue;
                d = at(t, i + 3);
                if (d != 'b' and d != 'n') continue;
                tl = i + 5;
            }
            const letter = at(t, i + 1);
            var k: Kind = .none;
            for (code_kinds) |ck| {
                if (ck[0] == letter) k = ck[1];
            }
            if (k == .none) continue;
            // its number: 01, -1, 2-; not the 1 of "1e verdieping"
            var s = tl;
            while (true) : (s += 1) {
                const ch = at(t, s);
                if (ch == '-' or ch == '+' or (ch >= '0' and ch <= '9')) continue;
                break;
            }
            if (s != tl) {
                const e = at(t, s);
                if (at(t, s - 1) == '-' or e == ' ' or e == 10) tl = s;
            }
            return .{ .kind = k, .old = d == 'b', .title = tl };
        }
        if (mode != 2) return .{};
        mode = 3;
    }
}

/// Where the title after a label ("drawing:", "titel:", "title:") starts.
pub fn label(t: []const u8) ?usize {
    for (label_words) |w| {
        if (std.mem.indexOf(u8, t, w)) |o| return o + w.len;
    }
    return null;
}

/// A title: the first words, to a line's end or a wide gap, 27 bytes at most, trimmed.
pub fn title(dst: *[32]u8, t: []const u8) []const u8 {
    var i: usize = 0;
    while (at(t, i) == ' ') i += 1;
    var n: usize = 0;
    while (true) : (n += 1) {
        const c = at(t, i + n);
        if (c == 0 or c == 10) break;
        if (c == ' ' and at(t, i + n + 1) == ' ') break;
        if (n >= 27) break;
        dst[n] = c;
    }
    while (n > 0 and dst[n - 1] == ' ') n -= 1;
    dst[n] = 0;
    return dst[0..n];
}

fn digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn scaleWord(t: []const u8, off: usize) bool {
    const s = off -| 40;
    var b: [40]u8 = undefined;
    const n = lowerInto(&b, t[s..off]);
    for (scale_words) |w| {
        if (has(b[0..n], w)) return true;
    }
    return false;
}

/// n of the text's scale 1:n (1/n), the one after "schaal" / "scale" first (0: none).
pub fn scale(t: []const u8) u32 {
    var first: u32 = 0;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '1') continue;
        if (i > 0 and digit(t[i - 1])) continue; // not inside a number
        var c = i + 1;
        while (c < t.len and t[c] == ' ') c += 1;
        if (c >= t.len or (t[c] != ':' and t[c] != '/')) continue;
        c += 1;
        while (c < t.len and t[c] == ' ') c += 1;
        if (c >= t.len) continue;
        var v: u32 = 0;
        var nd: u32 = 0;
        var long = false;
        while (c < t.len and digit(t[c])) {
            v = v * 10 + (t[c] - '0');
            c += 1;
            nd += 1;
            if (nd > 6) {
                long = true;
                break;
            }
        }
        if (long or nd == 0) continue;
        if (c < t.len and (t[c] == '/' or t[c] == '.')) continue; // not a date: 1/10/2026
        if (std.mem.indexOfScalar(u32, &scales, v) == null) continue;
        if (first == 0) first = v;
        if (scaleWord(t, i)) return v;
    }
    return first;
}

pub const Page = struct {
    kind: Kind = .none,
    level: i32 = LV_NONE,
    old: bool = false,
    scale: u32 = 0,
    title: [32]u8 = @splat(0),
    title_len: u8 = 0,
    pub fn titleS(p: *const Page) []const u8 {
        return p.title[0..p.title_len];
    }
};

var norm: [TXT_CAP + 16]u8 = undefined;

fn setTitle(p: *Page, t: []const u8) void {
    var d: [32]u8 = undefined;
    const s = title(&d, t);
    @memcpy(p.title[0..s.len], s);
    p.title_len = @intCast(s.len);
}

fn titleLevel(p: *Page) void {
    var b: [40]u8 = undefined;
    const n = p.title_len;
    @memcpy(b[0..n], p.title[0..n]);
    p.level = level(spaced(&b, n));
}

/// Sort one page out. name: the file's name, with its extension. text: its
/// page's text, null for an image file. pages: the pages of its PDF.
pub fn classify(name: []const u8, text: ?[]const u8, pages: u32) Page {
    var p = Page{};
    var n = lowerInto(norm[0..300], name);
    // without the last ".xxx"
    if (std.mem.lastIndexOfScalar(u8, norm[0..n], '.')) |d| {
        if (d > 0) n = d;
    }
    var t = spaced(&norm, n);
    const c = code(t, 2);
    if (c.old) p.old = true;
    if (has(t, "bestaand")) p.old = true;
    if (has(t, "existing")) p.old = true;
    p.kind = words(t);
    p.level = level(t);
    setTitle(&p, t[c.title orelse 1..]);
    if (p.kind == .none) p.kind = c.kind;
    if (text) |raw| {
        p.scale = scale(raw);
        n = lowerInto(norm[0 .. TXT_CAP - 8], raw);
        t = spaced(&norm, n);
        if (has(t, "toestand bestaand")) p.old = true;
        if (has(t, "nieuwe toestand")) p.old = false;
        if (pages > 1 or p.kind == .none) fromText(&p, t);
    }
    if (p.kind == .elev) {
        const s = side(p.titleS());
        if (s != .none) p.kind = s;
    }
    if (p.kind == .none) p.kind = .other;
    if (p.title_len == 0) {
        var base: [300]u8 = undefined;
        const b = @min(name.len, base.len);
        @memcpy(base[0..b], name[0..b]);
        setTitle(&p, base[0..b]);
    }
    return p;
}

fn fromText(p: *Page, t: []const u8) void {
    // the code in its title block (at a line's start), else a label
    // ("Drawing: Plan 1"), else a code anywhere
    var c = code(t, 1);
    if (c.kind == .none) {
        if (label(t)) |l| {
            setTitle(p, t[l..]);
            const w = words(p.titleS());
            if (w == .none) return;
            p.kind = w;
            titleLevel(p);
            return;
        }
        c = code(t, 0);
        if (c.kind == .none) return;
    }
    p.old = c.old;
    setTitle(p, t[c.title.?..]);
    const w = words(p.titleS());
    p.kind = if (w != .none) w else c.kind;
    titleLevel(p);
}

const T = std.testing;

test "names of a plan set" {
    const c = struct {
        fn k(nm: []const u8) Page {
            return classify(nm, null, 0);
        }
    };
    try T.expectEqual(Kind.front, c.k("G_N_01_voorgevel.pdf").kind);
    try T.expectEqual(false, c.k("G_N_01_voorgevel.pdf").old);
    try T.expectEqual(true, c.k("G_B_01_voorgevel.pdf").old);
    try T.expectEqual(Kind.back, c.k("achtergevel.png").kind);
    try T.expectEqual(Kind.left, c.k("gevel links.jpg").kind);
    try T.expectEqual(Kind.right, c.k("Gevel_Rechts.jpg").kind);
    try T.expectEqual(Kind.legend, c.k("X_L_legende.pdf").kind);
    try T.expectEqual(Kind.section, c.k("S_N_01_snede.pdf").kind);
    try T.expectEqual(Kind.site, c.k("inplanting.pdf").kind);
    try T.expectEqual(Kind.other, c.k("foto.png").kind);
    const p = c.k("P_N_00_gelijkvloers.pdf");
    try T.expectEqual(Kind.plan, p.kind);
    try T.expectEqual(@as(i32, 0), p.level);
    try T.expectEqual(@as(i32, -1), c.k("plan kelder.pdf").level);
    try T.expectEqual(@as(i32, 2), c.k("tweede verdieping.pdf").level);
    try T.expectEqual(@as(i32, LV_ROOF), c.k("dakenplan.pdf").level);
}

test "the scale in a text" {
    try T.expectEqual(@as(u32, 50), scale("Schaal: 1:50"));
    try T.expectEqual(@as(u32, 100), scale("1:50 detail ... schaal 1/100"));
    try T.expectEqual(@as(u32, 50), scale("1 : 50"));
    try T.expectEqual(@as(u32, 0), scale("1/10/2026"));
    try T.expectEqual(@as(u32, 0), scale("11:50"));
    try T.expectEqual(@as(u32, 0), scale("1:51"));
    try T.expectEqual(@as(u32, 0), scale("1:12345678"));
    try T.expectEqual(@as(u32, 0), scale("1:"));
    try T.expectEqual(@as(u32, 0), scale(""));
}

test "a page of many: the title block" {
    const p = classify("set.pdf", "   \nP_N 01 Eerste verdieping      Schaal 1:100\n", 4);
    try T.expectEqual(Kind.plan, p.kind);
    try T.expectEqual(@as(i32, 1), p.level);
    try T.expectEqual(@as(u32, 100), p.scale);
    try T.expectEqualStrings("eerste verdieping", p.titleS());
    const q = classify("set.pdf", "Drawing: Front Elevation\nscale 1:50", 4);
    try T.expectEqual(Kind.front, q.kind);
    const r = classify("set.pdf", "\nG_B 2-Zijgevel links\n", 4);
    try T.expectEqual(Kind.left, r.kind);
    try T.expectEqual(true, r.old);
    try T.expectEqual(Kind.other, classify("set.pdf", "nothing to see", 2).kind);
    try T.expectEqualStrings("set", classify("set.pdf", "nothing to see", 2).titleS());
}

test "any bytes: no crash, titles in bounds" {
    var pr = std.Random.DefaultPrng.init(0x62656531);
    const r = pr.random();
    var b: [4096]u8 = undefined;
    const alpha = "gpsiltdbn \n_:/.,0123456789-+ schaal1:verdieping";
    for (0..4000) |it| {
        const n = r.uintLessThan(usize, b.len);
        for (b[0..n]) |*c| c.* = if (it % 2 == 0) r.int(u8) else alpha[r.uintLessThan(usize, alpha.len)];
        const nm = b[0..@min(n, 200)];
        const p = classify(nm, if (it % 3 == 0) null else b[0..n], @intCast(it % 5));
        try T.expect(p.title_len <= 31);
        _ = code(b[0..n], @intCast(it % 3));
        _ = scale(b[0..n]);
    }
    // the cap: a text longer than the buffer
    const big = try std.heap.page_allocator.alloc(u8, TXT_CAP * 2);
    defer std.heap.page_allocator.free(big);
    @memset(big, 'a');
    _ = classify("a.pdf", big, 2);
}
