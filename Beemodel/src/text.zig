// Text faces: the UI face (15 px), mono (14 px, the console), small (13 px,
// hints) and head (16 px, synthetic bold), all from a system TrueType font
// like the original (Noto Sans, else DejaVu or Liberation; BEEMODEL_FONT /
// BEEMODEL_MONO_FONT override, "none" keeps the 8x16 bitmap font). Glyphs
// are rasterized once into a cache of alpha bitmaps.
const std = @import("std");
const ttf = @import("ttf.zig");

pub const Face = enum(u8) { ui, mono, small, head, node };
const N_FACES = 5;

const sans_paths = [_][]const u8{
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
};
pub const mono_paths = [_][]const u8{
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
};

const Slot = struct {
    font: ?ttf.Font = null,
    px: f32 = 15,
    scale: f32 = 0, // px per font unit
    baseline: i32 = 12, // from the top of a 16 px row
    bold: bool = false,
};

var slots: [N_FACES]Slot = .{ .{ .px = 15 }, .{ .px = 14 }, .{ .px = 13 }, .{ .px = 16, .bold = true }, .{ .px = 15 } };
pub var loaded: bool = false;
/// The UI's scale (1.0 = 100 %), applied to the font sizes.
pub var ui_scale: f32 = 1.0;

fn tryLoad(env: ?[]const u8, paths: []const []const u8) ?ttf.Font {
    if (env) |p| {
        if (std.mem.eql(u8, p, "none")) return null;
        if (ttf.mapFile(p)) |d| return ttf.Font.parse(d);
    }
    for (paths) |p| {
        if (ttf.mapFile(p)) |d| {
            if (ttf.Font.parse(d)) |f| return f;
        }
    }
    return null;
}

pub fn init(sans_env: ?[]const u8, mono_env: ?[]const u8) void {
    const sans = tryLoad(sans_env, &sans_paths);
    const mono = tryLoad(mono_env, &mono_paths) orelse sans;
    if (sans == null) return;
    for (&slots, 0..) |*s, i| {
        s.font = if (i == @intFromEnum(Face.mono)) mono else sans;
        const f = s.font.?;
        s.scale = s.px / f.units;
        const asc = f.ascent * s.scale;
        const line = (f.ascent - f.descent) * s.scale;
        s.baseline = @intFromFloat(@round((16.0 - line) / 2.0 + asc));
    }
    loaded = true;
}

// --- glyph cache ---------------------------------------------------------------

pub const Glyph = struct {
    w: u16 = 0,
    h: u16 = 0,
    x: i16 = 0, // left of the bitmap from the pen
    y: i16 = 0, // top of the bitmap from the baseline (negative: above)
    adv: f32 = 0, // advance in px
    off: u32 = 0, // into `pixels`
};

const CACHE = 4096;
var keys: [CACHE]u32 = @splat(0);
var glyphs: [CACHE]Glyph = undefined;
var pixels: [4 << 20]u8 = undefined;
var used: usize = 0;
var acc: [128 * 128]f32 = undefined;

const Sink = struct {
    r: *ttf.Raster,
    pub fn line(s: Sink, x0: f32, y0: f32, x1: f32, y1: f32) void {
        s.r.line(x0, y0, x1, y1);
    }
};

pub fn glyph(face: Face, cp: u32) *const Glyph {
    const key: u32 = (@as(u32, @intFromEnum(face)) << 24 | (cp & 0xffffff)) + 1;
    var h: usize = (key *% 2654435761) % CACHE;
    var probes: usize = 0;
    while (keys[h] != 0 and keys[h] != key and probes < CACHE) : (probes += 1) h = (h + 1) % CACHE;
    if (keys[h] == key) return &glyphs[h];
    if (probes >= CACHE or used > pixels.len - 128 * 128) {
        // full: start over (rare: thousands of different glyphs)
        keys = @splat(0);
        used = 0;
        h = (key *% 2654435761) % CACHE;
    }
    keys[h] = key;
    glyphs[h] = render(face, cp);
    return &glyphs[h];
}

fn render(face: Face, cp: u32) Glyph {
    const s = &slots[@intFromEnum(face)];
    const f = &(s.font.?);
    var gi = f.glyphIndex(cp);
    if (gi == 0 and cp != ' ') gi = f.glyphIndex('?');
    const sc = s.scale * ui_scale;
    var g = Glyph{ .adv = f.advance(gi) * sc + (if (s.bold) @as(f32, 1) else 0) };
    // bounds from the glyph header
    const bb = glyphBox(f, gi) orelse return g;
    const x0: i32 = @as(i32, @intFromFloat(@floor(bb[0] * sc))) - 1;
    const x1: i32 = @as(i32, @intFromFloat(@ceil(bb[2] * sc))) + 1 + (if (s.bold) @as(i32, 1) else 0);
    const y0: i32 = @as(i32, @intFromFloat(@floor(-bb[3] * sc))) - 1;
    const y1: i32 = @as(i32, @intFromFloat(@ceil(-bb[1] * sc))) + 1;
    const w: usize = @intCast(@max(1, x1 - x0));
    const hh: usize = @intCast(@max(1, y1 - y0));
    if ((w + 2) * hh > acc.len) return g;
    const aw = w + 2;
    @memset(acc[0 .. aw * hh], 0);
    var r = ttf.Raster{ .acc = acc[0 .. aw * hh], .w = aw, .h = hh };
    // font units (y up) -> bitmap pixels (y down), origin at (x0, y0)
    const m = [6]f32{ sc, 0, 0, -sc, -@as(f32, @floatFromInt(x0)), -@as(f32, @floatFromInt(y0)) };
    f.outline(gi, m, Sink{ .r = &r }, 0);
    g.w = @intCast(w);
    g.h = @intCast(hh);
    g.x = @intCast(x0);
    g.y = @intCast(y0);
    g.off = @intCast(used);
    var sum: f32 = 0;
    const lut = gamma();
    for (0..hh) |yy| {
        for (0..aw) |xx| {
            sum += acc[yy * aw + xx];
            if (xx < w) {
                const a = @min(1.0, @abs(sum));
                pixels[used + yy * w + xx] = lut[@intFromFloat(a * 255.0 + 0.5)];
            }
        }
    }
    if (s.bold) {
        // synthetic bold: widen by a pixel
        var yy: usize = 0;
        while (yy < hh) : (yy += 1) {
            var xx: usize = w - 1;
            while (xx > 0) : (xx -= 1) {
                const p = used + yy * w + xx;
                pixels[p] = @max(pixels[p], pixels[p - 1]);
            }
        }
    }
    used += w * hh;
    return g;
}

/// The original's coverage boost, so light text on dark does not look thin:
/// a' = (a + sqrt(a * 255)) / 2.
fn gamma() *const [256]u8 {
    const S = struct {
        var lut: [256]u8 = undefined;
        var done = false;
    };
    if (!S.done) {
        for (&S.lut, 0..) |*v, a| v.* = @intCast((a + @as(usize, @intFromFloat(@sqrt(@as(f32, @floatFromInt(a * 255)))))) / 2);
        S.done = true;
    }
    return &S.lut;
}

fn glyphBox(f: *const ttf.Font, gi: u16) ?[4]f32 {
    if (gi >= f.num_glyphs) return null;
    const a: usize = if (f.loca_long) std.mem.readInt(u32, f.data[f.loca + @as(usize, gi) * 4 ..][0..4], .big) else @as(usize, std.mem.readInt(u16, f.data[f.loca + @as(usize, gi) * 2 ..][0..2], .big)) * 2;
    const b: usize = if (f.loca_long) std.mem.readInt(u32, f.data[f.loca + @as(usize, gi) * 4 + 4 ..][0..4], .big) else @as(usize, std.mem.readInt(u16, f.data[f.loca + @as(usize, gi) * 2 + 2 ..][0..2], .big)) * 2;
    if (b <= a) return null;
    const o = f.glyf + a;
    if (o + 10 > f.data.len) return null;
    const rd = struct {
        fn v(d: []const u8, at: usize) f32 {
            return @floatFromInt(@as(i16, @bitCast(std.mem.readInt(u16, d[at..][0..2], .big))));
        }
    }.v;
    return .{ rd(f.data, o + 2), rd(f.data, o + 4), rd(f.data, o + 6), rd(f.data, o + 8) };
}

/// The node editor's face (FONT_NODE): the UI's, at its zoom's size (font_set_size:
/// the baseline in the middle of a 16 px row again; every cached glyph goes).
pub fn setNodePx(px: f32) void {
    const s = &slots[@intFromEnum(Face.node)];
    if (s.px == px) return;
    s.px = px;
    const f = s.font orelse return;
    s.scale = s.px / f.units;
    const asc = f.ascent * s.scale;
    const line = (f.ascent - f.descent) * s.scale;
    s.baseline = @intFromFloat(@round((16.0 - line) / 2.0 + asc));
    keys = @splat(0);
    used = 0;
}

pub fn baseline(face: Face) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(slots[@intFromEnum(face)].baseline)) * ui_scale));
}

/// Another scale: the cache's glyphs were for the old one.
pub fn setScale(s: f32) void {
    ui_scale = s;
    keys = @splat(0);
    used = 0;
}

/// Next code point of UTF-8 text at i (advances i); bad bytes read as '?'.
pub fn nextCp(s: []const u8, i: *usize) u32 {
    const c = s[i.*];
    i.* += 1;
    if (c < 0x80) return c;
    const n: usize = if (c >= 0xf0) 3 else if (c >= 0xe0) 2 else if (c >= 0xc0) 1 else return '?';
    if (i.* + n > s.len) {
        i.* = s.len;
        return '?';
    }
    var cp: u32 = c & (@as(u8, 0x3f) >> @intCast(n));
    for (0..n) |_| {
        cp = (cp << 6) | (s[i.*] & 0x3f);
        i.* += 1;
    }
    return cp;
}

/// In UI units (the glyphs are rasterized, and advance, at the real size).
pub fn width(face: Face, s: []const u8) i32 {
    var pen: f32 = 0;
    var i: usize = 0;
    while (i < s.len) pen += glyph(face, nextCp(s, &i)).adv;
    return @intFromFloat(@ceil(pen / ui_scale));
}

pub fn pixelsOf(g: *const Glyph) []const u8 {
    return pixels[g.off .. g.off + @as(usize, g.w) * g.h];
}
