//! Text measuring and glyph rendering, built on the pure-Zig TrueType reader.
//!
//! Glyph bitmaps are rasterized on first use and cached by glyph, size and
//! subpixel offset. Cached bitmaps stay valid until `deinit` or `clearCache`.

const std = @import("std");
const truetype = @import("internal/truetype.zig");
const Allocator = std.mem.Allocator;
const Vec2 = @import("draw.zig").Vec2;

/// The Liberation Sans font bundled with Zui (SIL Open Font License, see
/// `src/fonts/LICENSE-LiberationSans.txt`). Referencing this adds about 410 KB
/// to the binary; not referencing it adds nothing.
pub const default_font_data = @embedFile("fonts/LiberationSans-Regular.ttf");

/// Liberation Mono, a monospace companion to the default font, under the same
/// licence. About 320 KB, only linked if referenced (see `initMono`).
pub const mono_font_data = @embedFile("fonts/LiberationMono-Regular.ttf");

/// Why a font could not be loaded.
pub const Error = truetype.Error;

/// A rasterized glyph. `coverage` holds `width * height` bytes, row 0 at the top.
pub const Glyph = struct {
    width: u32,
    height: u32,
    /// Bitmap offset from the pen position, in pixels.
    left: i32,
    /// Bitmap offset from the baseline, in pixels. Usually negative (up).
    top: i32,
    coverage: []const u8,
};

/// Vertical metrics at a given size, in the same unit as the size.
pub const LineMetrics = struct {
    /// Baseline distance from the top of the line.
    ascent: f32,
    /// Distance from baseline to the bottom of the line. Positive.
    descent: f32,
    /// Recommended distance between baselines.
    height: f32,
};

/// A loaded font with its glyph cache.
pub const Font = struct {
    allocator: Allocator,
    ttf: truetype.TrueType,
    cache: std.AutoHashMapUnmanaged(Key, Glyph) = .empty,
    arena: std.heap.ArenaAllocator,
    ascii_glyphs: [128]u16,
    /// Height of a lowercase x in font units, or 0 if the font has none.
    x_height: f32,
    /// Apply the font's pair kerning. Turn off to measure and draw with plain
    /// advances.
    kerning_enabled: bool = true,
    /// Characters this font lacks are taken from here, for example a symbol
    /// or CJK font behind a Latin one. Borrowed; must outlive this font.
    fallback: ?*Font = null,
    /// File contents read by `loadFile`, freed by `deinit`.
    owned_data: ?[]u8 = null,
    /// Bytes of glyph bitmaps cached. Past `cache_limit` the cache starts
    /// over, so zooming text through many sizes can't grow it without end.
    cache_bytes: usize = 0,
    /// The glyph cache's budget in bytes. A UI at a few sizes uses well
    /// under a megabyte.
    cache_limit: usize = 16 << 20,
    /// Unique per font made with `init`: renderers key their own glyph
    /// caches by it (an address can be reused by a later font).
    id: u32 = 0,

    /// Horizontal glyph positions per pixel.
    pub const subpixel_steps = 4;

    const Key = struct { glyph: u16, size_q: u16, subpixel: u8 };

    var next_id = std.atomic.Value(u32).init(1);

    /// Loads a font. `data` is borrowed and must outlive the `Font`.
    pub fn init(allocator: Allocator, data: []const u8) Error!Font {
        const ttf = try truetype.TrueType.init(data);
        var ascii: [128]u16 = undefined;
        for (&ascii, 0..) |*slot, i| slot.* = ttf.glyphIndex(@intCast(i));

        var font: Font = .{
            .allocator = allocator,
            .ttf = ttf,
            .arena = .init(allocator),
            .ascii_glyphs = ascii,
            .x_height = 0,
            .id = next_id.fetchAdd(1, .monotonic),
        };
        font.x_height = try font.measureXHeight();
        return font;
    }

    /// Loads the bundled default font.
    pub fn initDefault(allocator: Allocator) Error!Font {
        return init(allocator, default_font_data);
    }

    /// Loads the bundled monospace font, for code, logs and consoles.
    pub fn initMono(allocator: Allocator) Error!Font {
        return init(allocator, mono_font_data);
    }

    /// Why `loadFile` failed.
    pub const LoadError = Error || std.Io.Dir.ReadFileAllocError;

    /// Reads a TrueType file, such as a system font, and loads it. The font
    /// keeps the file's bytes until `deinit`.
    pub fn loadFile(allocator: Allocator, io: std.Io, path: []const u8) LoadError!Font {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
        errdefer allocator.free(data);
        var font = try init(allocator, data);
        font.owned_data = data;
        return font;
    }

    /// Frees the font and its cache.
    pub fn deinit(self: *Font) void {
        self.cache.deinit(self.allocator);
        self.arena.deinit();
        if (self.owned_data) |d| self.allocator.free(d);
    }

    /// True if the font itself has a glyph for `codepoint`.
    pub fn hasGlyph(self: *const Font, codepoint: u21) bool {
        return self.glyphIndex(codepoint) != 0;
    }

    /// The font that draws `codepoint`: this one, or the first fallback that
    /// has it. If none has it, this one (its missing-glyph box).
    fn owner(self: *const Font, codepoint: u21) *const Font {
        if (self.fallback == null or self.hasGlyph(codepoint)) return self;
        var next = self.fallback;
        var depth: u8 = 0;
        while (next) |f| : (depth += 1) {
            if (depth > 8) break; // a fallback loop
            if (f.hasGlyph(codepoint)) return f;
            next = f.fallback;
        }
        return self;
    }

    /// Drops all cached glyphs, invalidating any `Glyph` handed out before.
    pub fn clearCache(self: *Font) void {
        self.cache.clearRetainingCapacity();
        _ = self.arena.reset(.{ .retain_with_limit = self.cache_limit });
        self.cache_bytes = 0;
    }

    fn measureXHeight(self: *const Font) Error!f32 {
        var segments: std.ArrayList(truetype.Segment) = .empty;
        defer segments.deinit(self.allocator);
        try self.ttf.outline(self.allocator, self.ascii_glyphs['x'], 1, &segments);
        var top: f32 = 0;
        for (segments.items) |s| top = @max(top, s.a.y, s.b.y);
        return top;
    }

    fn unitsToSize(self: *const Font, size: f32) f32 {
        return size / @as(f32, @floatFromInt(self.ttf.units_per_em));
    }

    /// Returns line metrics at `size`.
    pub fn lineMetrics(self: *const Font, size: f32) LineMetrics {
        const k = self.unitsToSize(size);
        const m = self.ttf.metrics;
        const ascent = @as(f32, @floatFromInt(m.ascent)) * k;
        const descent = @as(f32, @floatFromInt(-@as(i32, m.descent))) * k;
        const gap = @as(f32, @floatFromInt(m.line_gap)) * k;
        return .{ .ascent = ascent, .descent = descent, .height = ascent + descent + gap };
    }

    fn glyphIndex(self: *const Font, codepoint: u21) u16 {
        return if (codepoint < 128) self.ascii_glyphs[codepoint] else self.ttf.glyphIndex(codepoint);
    }

    /// Returns the pen advance of one codepoint at `size`.
    pub fn advance(self: *const Font, codepoint: u21, size: f32) f32 {
        const f = self.owner(codepoint);
        return @as(f32, @floatFromInt(f.ttf.advance(f.glyphIndex(codepoint)))) * f.unitsToSize(size);
    }

    /// Returns how far to move the pen between `left` and `right`, on top of
    /// `left`'s advance, at `size`. Usually 0; negative for pairs like "AV".
    pub fn kerning(self: *const Font, left: u21, right: u21, size: f32) f32 {
        if (!self.kerning_enabled or self.ttf.kern_pairs == null) return 0;
        // Pairs across two fonts have no kerning.
        if (self.fallback != null and (!self.hasGlyph(left) or !self.hasGlyph(right))) return 0;
        const k = self.ttf.kerning(self.glyphIndex(left), self.glyphIndex(right));
        return @as(f32, @floatFromInt(k)) * self.unitsToSize(size);
    }

    /// Returns the width of a single line of UTF-8 text at `size`, kerning
    /// included. Invalid bytes count as the replacement character, matching
    /// how they are drawn.
    pub fn textWidth(self: *const Font, text: []const u8, size: f32) f32 {
        var width: f32 = 0;
        var previous: ?u21 = null;
        var it: Utf8Iterator = .{ .bytes = text };
        while (it.next()) |cp| {
            if (previous) |p| width += self.kerning(p, cp, size);
            width += self.advance(cp, size);
            previous = cp;
        }
        return width;
    }

    /// Returns the rasterized glyph for `codepoint` at a pixel `size`.
    /// `subpixel` is the pen's fractional x position in `0..subpixel_steps`.
    pub fn glyph(self: *Font, codepoint: u21, size: f32, subpixel: u8) Allocator.Error!Glyph {
        const f = self.owner(codepoint);
        if (f != self) return @constCast(f).glyph(codepoint, size, subpixel);
        const index = self.glyphIndex(codepoint);
        const key = cacheKey(index, size, subpixel);
        if (self.cache.get(key)) |g| return g;
        // Over budget: start over (the renderers use each glyph at once, so
        // nothing still points into the old bitmaps).
        if (self.cache_bytes > self.cache_limit) self.clearCache();
        const entry = try self.cache.getOrPut(self.allocator, key);
        errdefer _ = self.cache.remove(key);
        const result = try self.rasterize(index, @as(f32, @floatFromInt(key.size_q)) / 4, key.subpixel);
        entry.value_ptr.* = result;
        self.cache_bytes += result.coverage.len;
        return result;
    }

    /// The cache key: sizes in quarter pixels up to 64 px, then in whole
    /// pixels, then in 4 px steps past 256 px; subpixel positions only up to
    /// 64 px, where a quarter pixel still shows. Zooming through sizes then
    /// makes a bounded number of bitmaps.
    fn cacheKey(index: u16, size: f32, subpixel: u8) Key {
        const sz = std.math.clamp(if (std.math.isFinite(size)) size else 1, 0.25, 15000);
        // (rounded once, to the step of its range, in quarter pixels)
        const step: f32 = if (sz > 256) 16 else if (sz > 64) 4 else 1;
        const q: u32 = @intFromFloat(@max(1, @round(sz * 4 / step) * step));
        return .{
            .glyph = index,
            .size_q = @intCast(@min(q, 60000)),
            .subpixel = if (sz > 64) 0 else subpixel,
        };
    }

    const empty_glyph: Glyph = .{ .width = 0, .height = 0, .left = 0, .top = 0, .coverage = &.{} };

    fn rasterize(self: *Font, index: u16, size: f32, subpixel: u8) Allocator.Error!Glyph {
        const gpa = self.allocator;
        var segments: std.ArrayList(truetype.Segment) = .empty;
        defer segments.deinit(gpa);

        const k = self.unitsToSize(size);
        // A quarter pixel of curve error is invisible after anti-aliasing.
        self.ttf.outline(gpa, index, 0.25 / k, &segments) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // One corrupt glyph shows as blank rather than failing the frame.
            error.InvalidFont => return empty_glyph,
        };
        if (segments.items.len == 0) return empty_glyph;

        // Land the x-height on a whole pixel. This keeps the tops of lowercase
        // letters sharp, which is most of what hinting achieves at UI sizes.
        const x_px = self.x_height * k;
        const y_k = if (x_px >= 6 and x_px < 40) k * @round(x_px) / x_px else k;
        const shift = @as(f32, @floatFromInt(subpixel)) / subpixel_steps;

        var min_x: f32 = std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);
        for (segments.items) |*s| {
            // To pixel space: y down, baseline at zero.
            s.a = .{ .x = s.a.x * k + shift, .y = -s.a.y * y_k };
            s.b = .{ .x = s.b.x * k + shift, .y = -s.b.y * y_k };
            min_x = @min(min_x, s.a.x, s.b.x);
            max_x = @max(max_x, s.a.x, s.b.x);
            min_y = @min(min_y, s.a.y, s.b.y);
            max_y = @max(max_y, s.a.y, s.b.y);
        }

        // A real glyph is a few ems across. Refuse anything bigger, so a corrupt
        // outline can't demand a gigabyte bitmap or overflow the casts below.
        const max_extent = size * 8 + 16;
        const in_range = @abs(min_x) < max_extent and @abs(max_x) < max_extent and
            @abs(min_y) < max_extent and @abs(max_y) < max_extent;
        if (!in_range) return empty_glyph;

        const left: i32 = @intFromFloat(@floor(min_x));
        const top: i32 = @intFromFloat(@floor(min_y));
        const width: u32 = @intCast(@as(i32, @intFromFloat(@ceil(max_x))) - left + 1);
        const height: u32 = @intCast(@as(i32, @intFromFloat(@ceil(max_y))) - top + 1);
        const stride = width + 2;

        const accumulation = try gpa.alloc(f32, stride * height);
        defer gpa.free(accumulation);
        @memset(accumulation, 0);

        const fx: f32 = @floatFromInt(left);
        const fy: f32 = @floatFromInt(top);
        for (segments.items) |s| {
            accumulateLine(
                accumulation,
                stride,
                height,
                .{ .x = s.a.x - fx, .y = s.a.y - fy },
                .{ .x = s.b.x - fx, .y = s.b.y - fy },
            );
        }

        const coverage = try self.arena.allocator().alloc(u8, @as(usize, width) * height);
        for (0..height) |row| {
            var sum: f32 = 0;
            const src = accumulation[row * stride..][0..width];
            const dst = coverage[row * width..][0..width];
            for (src, dst) |a, *d| {
                sum += a;
                d.* = @intFromFloat(@min(@abs(sum), 1) * 255 + 0.5);
            }
        }
        return .{ .width = width, .height = height, .left = left, .top = top, .coverage = coverage };
    }
};

/// Adds a line's signed area contribution to a coverage accumulation buffer.
/// A running sum along each row then gives the exact pixel coverage of the
/// outline, which is why glyphs need no supersampling.
fn accumulateLine(buffer: []f32, stride: u32, height: u32, from: truetype.Point, to: truetype.Point) void {
    if (from.y == to.y) return;
    const dir: f32 = if (from.y < to.y) 1 else -1;
    const p0 = if (from.y < to.y) from else to;
    const p1 = if (from.y < to.y) to else from;
    const dxdy = (p1.x - p0.x) / (p1.y - p0.y);

    var x = p0.x;
    const first_row: u32 = @intFromFloat(@max(0, @floor(p0.y)));
    const end_row: u32 = @min(height, @as(u32, @intFromFloat(@max(0, @ceil(p1.y)))));
    if (p0.y < 0) x -= p0.y * dxdy;

    var row = first_row;
    while (row < end_row) : (row += 1) {
        const line = buffer[row * stride..][0..stride];
        const fy: f32 = @floatFromInt(row);
        const dy = @min(fy + 1, p1.y) - @max(fy, p0.y);
        const x_next = x + dxdy * dy;
        const d = dy * dir;
        const x0 = @max(0, @min(x, x_next));
        const x1 = @max(0, @max(x, x_next));
        const x0_floor = @floor(x0);
        const x0i: u32 = @intFromFloat(x0_floor);
        const x1_ceil = @ceil(x1);
        const x1i: u32 = @intFromFloat(x1_ceil);

        if (x1i >= stride or x0i + 1 >= stride) {
            // Rounding pushed the edge past the slack column. Nothing to its
            // right is visible, so it contributes nothing.
        } else if (x1i <= x0i + 1) {
            const mid = 0.5 * (x + x_next) - x0_floor;
            line[x0i] += d - d * mid;
            line[x0i + 1] += d * mid;
        } else {
            const s = 1 / (x1 - x0);
            const x0f = x0 - x0_floor;
            const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
            const x1f = x1 - x1_ceil + 1;
            const am = 0.5 * s * x1f * x1f;
            line[x0i] += d * a0;
            if (x1i == x0i + 2) {
                line[x0i + 1] += d * (1 - a0 - am);
            } else {
                const a1 = s * (1.5 - x0f);
                line[x0i + 1] += d * (a1 - a0);
                var xi = x0i + 2;
                while (xi < x1i - 1) : (xi += 1) line[xi] += d * s;
                const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                line[x1i - 1] += d * (1 - a2 - am);
            }
            line[x1i] += d * am;
        }
        x = x_next;
    }
}

/// The length of the longest prefix of `bytes` that fits in `room` bytes
/// without cutting a character in half: for copying text into a fixed buffer.
pub fn fitUtf8(bytes: []const u8, room: usize) usize {
    if (bytes.len <= room) return bytes.len;
    var n = room;
    while (n > 0 and bytes[n] & 0xC0 == 0x80) n -= 1;
    return n;
}

test "a character cut short is one replacement character" {
    var it: Utf8Iterator = .{ .bytes = "a\xe2\x82b" };
    try std.testing.expectEqual(@as(?u21, 'a'), it.next());
    try std.testing.expectEqual(@as(?u21, std.unicode.replacement_character), it.next());
    try std.testing.expectEqual(@as(?u21, 'b'), it.next());
    try std.testing.expectEqual(@as(?u21, null), it.next());
    var bad: Utf8Iterator = .{ .bytes = "\xff\xfe" };
    try std.testing.expectEqual(@as(?u21, std.unicode.replacement_character), bad.next());
    try std.testing.expectEqual(@as(?u21, std.unicode.replacement_character), bad.next());
    try std.testing.expectEqual(@as(?u21, null), bad.next());
}

test "fitUtf8 cuts between characters" {
    try std.testing.expectEqual(@as(usize, 3), fitUtf8("abcdef", 3));
    try std.testing.expectEqual(@as(usize, 1), fitUtf8("a\u{e9}b", 2)); // é is two bytes
    try std.testing.expectEqual(@as(usize, 3), fitUtf8("a\u{e9}b", 3));
    try std.testing.expectEqual(@as(usize, 0), fitUtf8("\u{65e5}\u{672c}", 2));
    try std.testing.expectEqual(@as(usize, 2), fitUtf8("ab", 9));
}

/// Decodes UTF-8, yielding U+FFFD instead of failing (once per bad byte, or
/// once for a character cut short), so that text from any source can be
/// measured and drawn.
pub const Utf8Iterator = struct {
    bytes: []const u8,
    index: usize = 0,

    /// Returns the next codepoint, or null at the end.
    pub fn next(self: *Utf8Iterator) ?u21 {
        if (self.index >= self.bytes.len) return null;
        const first = self.bytes[self.index];
        if (first < 0x80) {
            self.index += 1;
            return first;
        }
        const len = std.unicode.utf8ByteSequenceLength(first) catch return self.invalid();
        if (self.index + len > self.bytes.len) return self.invalid();
        const cp = std.unicode.utf8Decode(self.bytes[self.index..][0..len]) catch return self.invalid();
        self.index += len;
        return cp;
    }

    /// One replacement character for the longest start of a sequence that
    /// could still have become valid (a character cut short shows as one
    /// box, as the Unicode rule has it), or for one bad byte.
    fn invalid(self: *Utf8Iterator) u21 {
        const first = self.bytes[self.index];
        const want = std.unicode.utf8ByteSequenceLength(first) catch 1;
        var k: usize = 1;
        while (k < want and self.index + k < self.bytes.len and self.bytes[self.index + k] & 0xC0 == 0x80) k += 1;
        // A sequence of the right length that still didn't decode (an
        // overlong form, a surrogate) is bad byte by byte.
        if (k == want) k = 1;
        self.index += k;
        return std.unicode.replacement_character;
    }
};

const testing = std.testing;

test "default font loads and has expected metrics" {
    var font: Font = try .initDefault(testing.allocator);
    defer font.deinit();
    const m = font.lineMetrics(16);
    try testing.expect(m.ascent > 10 and m.ascent < 18);
    try testing.expect(m.height > 16 and m.height < 22);
    try testing.expect(font.x_height > 800 and font.x_height < 1300);
}

test "text width is the sum of advances" {
    var font: Font = try .initDefault(testing.allocator);
    defer font.deinit();
    const a = font.advance('a', 16);
    const b = font.advance('b', 16);
    try testing.expectApproxEqAbs(a + b, font.textWidth("ab", 16), 0.001);
    try testing.expectEqual(@as(f32, 0), font.textWidth("", 16));
}

test "glyph cache returns the same bitmap" {
    var font: Font = try .initDefault(testing.allocator);
    defer font.deinit();
    const first = try font.glyph('A', 16, 0);
    const second = try font.glyph('A', 16, 0);
    try testing.expectEqual(first.coverage.ptr, second.coverage.ptr);
    try testing.expect(first.width > 0 and first.height > 0);
}

test "accented composite glyph is taller than its base letter" {
    var font: Font = try .initDefault(testing.allocator);
    defer font.deinit();
    const base = try font.glyph('e', 32, 0);
    const accented = try font.glyph(0xE9, 32, 0); // é
    try testing.expect(accented.top < base.top);
    try testing.expect(accented.height > base.height);
}

test "space has an advance but no pixels" {
    var font: Font = try .initDefault(testing.allocator);
    defer font.deinit();
    try testing.expect(font.advance(' ', 16) > 0);
    try testing.expectEqual(@as(u32, 0), (try font.glyph(' ', 16, 0)).width);
}

test "solid stems reach full coverage" {
    var font: Font = try .initDefault(testing.allocator);
    defer font.deinit();
    const g = try font.glyph('I', 64, 0);
    var max: u8 = 0;
    for (g.coverage) |c| max = @max(max, c);
    try testing.expectEqual(@as(u8, 255), max);
}

test "invalid utf-8 yields replacement characters and terminates" {
    var it: Utf8Iterator = .{ .bytes = "a\xFFb\xC3" };
    try testing.expectEqual(@as(?u21, 'a'), it.next());
    try testing.expectEqual(@as(?u21, 0xFFFD), it.next());
    try testing.expectEqual(@as(?u21, 'b'), it.next());
    try testing.expectEqual(@as(?u21, 0xFFFD), it.next());
    try testing.expectEqual(@as(?u21, null), it.next());
}

test "truncated font data is rejected" {
    try testing.expectError(error.InvalidFont, Font.init(testing.allocator, ""));
    try testing.expectError(error.InvalidFont, Font.init(testing.allocator, default_font_data[0..100]));
}

test "corrupted font data never crashes" {
    // Keep the table directory intact and corrupt the tables themselves, so
    // that the damage reaches the parsers. Any out-of-bounds read, overflow or
    // bad cast panics this test.
    var prng: std.Random.DefaultPrng = .init(0x5A1);
    const random = prng.random();
    const copy = try testing.allocator.dupe(u8, default_font_data);
    defer testing.allocator.free(copy);

    const table_count = std.mem.readInt(u16, default_font_data[4..6], .big);
    const body = @as(usize, 12) + @as(usize, table_count) * 16;

    var loaded: u32 = 0;
    for (0..150) |_| {
        @memcpy(copy, default_font_data);
        for (0..2000) |_| {
            copy[random.intRangeLessThan(usize, body, copy.len)] = random.int(u8);
        }
        var font = Font.init(testing.allocator, copy) catch continue;
        defer font.deinit();
        loaded += 1;
        _ = font.textWidth("Zui élève", 16);
        var cp: u21 = 0;
        while (cp < 0x500) : (cp += 7) _ = try font.glyph(cp, 16, 0);
    }
    // If nearly every mutation dies in `init`, this test has stopped testing.
    try testing.expect(loaded > 50);
}

test "kerning pulls classic pairs together and leaves others alone" {
    var font: Font = try .initDefault(testing.allocator);
    defer font.deinit();
    try testing.expect(font.ttf.kern_pairs != null);
    try testing.expect(font.kerning('A', 'V', 100) < -1);
    try testing.expect(font.kerning('T', 'o', 100) < -1);
    try testing.expectEqual(@as(f32, 0), font.kerning('a', 'b', 100));
    const plain = font.advance('A', 20) + font.advance('V', 20);
    try testing.expect(font.textWidth("AV", 20) < plain);
    font.kerning_enabled = false;
    try testing.expectEqual(plain, font.textWidth("AV", 20));
}
