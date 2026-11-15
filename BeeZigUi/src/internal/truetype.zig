//! TrueType parsing and glyph outlines. Font files are treated as untrusted:
//! every read is bounds-checked, and a bad file produces `error.InvalidFont`
//! rather than a crash.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Why a font could not be used.
pub const Error = error{InvalidFont} || Allocator.Error;

/// A point in font units, y up.
pub const Point = struct { x: f32, y: f32 };

/// A straight outline segment in font units.
pub const Segment = struct { a: Point, b: Point };

/// Font-wide vertical metrics in font units.
pub const Metrics = struct { ascent: i16, descent: i16, line_gap: i16 };

/// A parsed TrueType file. Borrows `data`.
pub const TrueType = struct {
    data: []const u8,
    units_per_em: u16,
    metrics: Metrics,
    glyph_count: u16,
    long_loca: bool,
    h_metric_count: u16,
    cmap: Table,
    cmap_format: u16,
    glyf: Table,
    loca: Table,
    hmtx: Table,
    /// The horizontal pair list of the `kern` table, if the font has one.
    kern_pairs: ?KernPairs = null,

    const Table = struct { offset: u32, length: u32 };
    const KernPairs = struct { offset: u32, count: u16 };
    const max_composite_depth = 5;
    const max_file_size = 1 << 30;

    /// Parses the table directory and headers.
    pub fn init(data: []const u8) Error!TrueType {
        // Offsets below are u32 with small additions. This bound means none of
        // those sums can overflow.
        if (data.len > max_file_size) return error.InvalidFont;
        const head = try findTable(data, "head");
        const hhea = try findTable(data, "hhea");
        const maxp = try findTable(data, "maxp");
        const glyf = try findTable(data, "glyf");
        const loca = try findTable(data, "loca");
        const hmtx = try findTable(data, "hmtx");
        const cmap_table = try findTable(data, "cmap");

        const units_per_em = try readU16(data, head.offset + 18);
        if (units_per_em == 0) return error.InvalidFont;

        var font: TrueType = .{
            .data = data,
            .units_per_em = units_per_em,
            .metrics = .{
                .ascent = try readI16(data, hhea.offset + 4),
                .descent = try readI16(data, hhea.offset + 6),
                .line_gap = try readI16(data, hhea.offset + 8),
            },
            .glyph_count = try readU16(data, maxp.offset + 4),
            .long_loca = (try readI16(data, head.offset + 50)) != 0,
            .h_metric_count = try readU16(data, hhea.offset + 34),
            .cmap = undefined,
            .cmap_format = undefined,
            .glyf = glyf,
            .loca = loca,
            .hmtx = hmtx,
        };
        font.cmap = try chooseCmap(data, cmap_table);
        font.cmap_format = try readU16(data, font.cmap.offset);
        if (font.cmap_format != 4 and font.cmap_format != 12) return error.InvalidFont;
        // Kerning is optional; a missing or unusual table just means none.
        if (findTable(data, "kern")) |kern| {
            font.kern_pairs = findKernPairs(data, kern) catch null;
        } else |_| {}
        return font;
    }

    /// Finds the first horizontal format 0 subtable of a version 0 `kern`
    /// table, the classic kind that most TrueType fonts carry.
    fn findKernPairs(data: []const u8, table: Table) Error!?KernPairs {
        if (try readU16(data, table.offset) != 0) return null;
        const count = try readU16(data, table.offset + 2);
        var sub = table.offset + 4;
        for (0..count) |_| {
            const length = try readU16(data, sub + 2);
            const coverage = try readU16(data, sub + 4);
            const format = coverage >> 8;
            // Bit 0: horizontal. Bits 1 and 2: minimum values, cross-stream.
            if (format == 0 and coverage & 0b111 == 0b001) {
                const pairs = try readU16(data, sub + 6);
                const first = sub + 14;
                if (@as(u64, first) + @as(u64, pairs) * 6 > data.len) return error.InvalidFont;
                return .{ .offset = first, .count = pairs };
            }
            if (length == 0) return null;
            sub += length;
        }
        return null;
    }

    /// Returns the kerning adjustment between two glyphs in font units, 0 if
    /// the pair has none. Negative pulls them together.
    pub fn kerning(self: *const TrueType, left: u16, right: u16) i16 {
        const kern = self.kern_pairs orelse return 0;
        const key = (@as(u32, left) << 16) | right;
        var lo: u32 = 0;
        var hi: u32 = kern.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = kern.offset + mid * 6;
            const found = readU32(self.data, entry) catch return 0;
            if (found == key) return readI16(self.data, entry + 4) catch 0;
            if (found < key) lo = mid + 1 else hi = mid;
        }
        return 0;
    }

    /// Prefers a full-Unicode subtable, then a BMP one.
    fn chooseCmap(data: []const u8, table: Table) Error!Table {
        const count = try readU16(data, table.offset + 2);
        var best: ?Table = null;
        var best_rank: u8 = 0;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const record = table.offset + 4 + i * 8;
            const platform = try readU16(data, record);
            const encoding = try readU16(data, record + 2);
            const offset = try readU32(data, record + 4);
            const rank: u8 = switch (platform) {
                0 => if (encoding >= 3) 2 else 1,
                3 => if (encoding == 10) 2 else if (encoding == 1) 1 else 0,
                else => 0,
            };
            if (rank > best_rank) {
                const start = std.math.add(u32, table.offset, offset) catch return error.InvalidFont;
                if (start >= data.len) return error.InvalidFont;
                best = .{ .offset = start, .length = table.length -| offset };
                best_rank = rank;
            }
        }
        return best orelse error.InvalidFont;
    }

    /// Returns the glyph for a codepoint, or 0 (the "missing" glyph).
    pub fn glyphIndex(self: *const TrueType, codepoint: u21) u16 {
        const found = switch (self.cmap_format) {
            4 => self.lookupFormat4(codepoint),
            else => self.lookupFormat12(codepoint),
        };
        return found catch 0;
    }

    fn lookupFormat4(self: *const TrueType, cp: u21) Error!u16 {
        if (cp > 0xFFFF) return 0;
        const data = self.data;
        const base = self.cmap.offset;
        const seg_x2: u32 = try readU16(data, base + 6);
        const end_codes = base + 14;
        const start_codes = end_codes + seg_x2 + 2;
        const deltas = start_codes + seg_x2;
        const range_offsets = deltas + seg_x2;

        var low: u32 = 0;
        var high: u32 = seg_x2 / 2;
        while (low < high) {
            const mid = (low + high) / 2;
            if (try readU16(data, end_codes + mid * 2) < cp) low = mid + 1 else high = mid;
        }
        if (low >= seg_x2 / 2) return 0;

        const seg = low * 2;
        const start = try readU16(data, start_codes + seg);
        if (cp < start) return 0;
        const delta = try readU16(data, deltas + seg);
        const range_offset = try readU16(data, range_offsets + seg);
        if (range_offset == 0) return @truncate(@as(u32, cp) +% delta);

        const address = range_offsets + seg + range_offset + (@as(u32, cp) - start) * 2;
        const glyph = try readU16(data, address);
        return if (glyph == 0) 0 else glyph +% delta;
    }

    fn lookupFormat12(self: *const TrueType, cp: u21) Error!u16 {
        const data = self.data;
        const base = self.cmap.offset;
        const groups = try readU32(data, base + 12);
        if (groups > data.len / 12) return error.InvalidFont;
        var low: u32 = 0;
        var high: u32 = groups;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const group = base + 16 + mid * 12;
            const start = try readU32(data, group);
            const end = try readU32(data, group + 4);
            if (cp < start) {
                high = mid;
            } else if (cp > end) {
                low = mid + 1;
            } else {
                const first = try readU32(data, group + 8);
                return std.math.cast(u16, first +| (cp - start)) orelse 0;
            }
        }
        return 0;
    }

    /// Returns the horizontal advance in font units.
    pub fn advance(self: *const TrueType, glyph: u16) u16 {
        if (self.h_metric_count == 0) return 0;
        const index = @min(glyph, self.h_metric_count - 1);
        return readU16(self.data, self.hmtx.offset + @as(u32, index) * 4) catch 0;
    }

    /// Appends the flattened outline of `glyph` to `segments`, in font units.
    /// `tolerance` is the largest allowed curve error, also in font units.
    pub fn outline(
        self: *const TrueType,
        allocator: Allocator,
        glyph: u16,
        tolerance: f32,
        segments: *std.ArrayList(Segment),
    ) Error!void {
        try self.appendGlyph(allocator, glyph, .identity, tolerance, segments, 0);
    }

    const Transform = struct {
        xx: f32,
        xy: f32,
        yx: f32,
        yy: f32,
        dx: f32,
        dy: f32,

        const identity: Transform = .{ .xx = 1, .xy = 0, .yx = 0, .yy = 1, .dx = 0, .dy = 0 };

        fn apply(t: Transform, p: Point) Point {
            return .{
                .x = t.xx * p.x + t.yx * p.y + t.dx,
                .y = t.xy * p.x + t.yy * p.y + t.dy,
            };
        }

        /// Returns the transform that applies `inner`, then `t`.
        fn compose(t: Transform, inner: Transform) Transform {
            const origin = t.apply(.{ .x = inner.dx, .y = inner.dy });
            return .{
                .xx = t.xx * inner.xx + t.yx * inner.xy,
                .xy = t.xy * inner.xx + t.yy * inner.xy,
                .yx = t.xx * inner.yx + t.yx * inner.yy,
                .yy = t.xy * inner.yx + t.yy * inner.yy,
                .dx = origin.x,
                .dy = origin.y,
            };
        }
    };

    /// Returns the byte range of a glyph inside `glyf`, or null if it is empty.
    fn glyphRange(self: *const TrueType, glyph: u16) Error!?Table {
        if (glyph >= self.glyph_count) return error.InvalidFont;
        const i: u32 = glyph;
        const start: u32, const end: u32 = if (self.long_loca) .{
            try readU32(self.data, self.loca.offset + i * 4),
            try readU32(self.data, self.loca.offset + i * 4 + 4),
        } else .{
            @as(u32, try readU16(self.data, self.loca.offset + i * 2)) * 2,
            @as(u32, try readU16(self.data, self.loca.offset + i * 2 + 2)) * 2,
        };
        if (end <= start) return null;
        if (end > self.glyf.length) return error.InvalidFont;
        return .{ .offset = self.glyf.offset + start, .length = end - start };
    }

    fn appendGlyph(
        self: *const TrueType,
        allocator: Allocator,
        glyph: u16,
        transform: Transform,
        tolerance: f32,
        segments: *std.ArrayList(Segment),
        depth: u8,
    ) Error!void {
        if (depth > max_composite_depth) return error.InvalidFont;
        const range = try self.glyphRange(glyph) orelse return;
        const contours = try readI16(self.data, range.offset);
        if (contours >= 0) {
            try self.appendSimple(allocator, range, @intCast(contours), transform, tolerance, segments);
        } else {
            try self.appendComposite(allocator, range, transform, tolerance, segments, depth);
        }
    }

    fn appendComposite(
        self: *const TrueType,
        allocator: Allocator,
        range: Table,
        transform: Transform,
        tolerance: f32,
        segments: *std.ArrayList(Segment),
        depth: u8,
    ) Error!void {
        const data = self.data;
        const limit = range.offset + range.length;
        var p = range.offset + 10;
        while (true) {
            if (p + 4 > limit) return error.InvalidFont;
            const flags = try readU16(data, p);
            const component = try readU16(data, p + 2);
            p += 4;

            var local: Transform = .identity;
            if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
                if (flags & 0x0002 != 0) { // ARGS_ARE_XY_VALUES
                    local.dx = @floatFromInt(try readI16(data, p));
                    local.dy = @floatFromInt(try readI16(data, p + 2));
                }
                p += 4;
            } else {
                if (flags & 0x0002 != 0) {
                    local.dx = @floatFromInt(@as(i8, @bitCast(try readU8(data, p))));
                    local.dy = @floatFromInt(@as(i8, @bitCast(try readU8(data, p + 1))));
                }
                p += 2;
            }
            if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE
                local.xx = try readF2Dot14(data, p);
                local.yy = local.xx;
                p += 2;
            } else if (flags & 0x0040 != 0) { // WE_HAVE_AN_X_AND_Y_SCALE
                local.xx = try readF2Dot14(data, p);
                local.yy = try readF2Dot14(data, p + 2);
                p += 4;
            } else if (flags & 0x0080 != 0) { // WE_HAVE_A_TWO_BY_TWO
                local.xx = try readF2Dot14(data, p);
                local.xy = try readF2Dot14(data, p + 2);
                local.yx = try readF2Dot14(data, p + 4);
                local.yy = try readF2Dot14(data, p + 6);
                p += 8;
            }
            try self.appendGlyph(allocator, component, transform.compose(local), tolerance, segments, depth + 1);
            if (flags & 0x0020 == 0) break; // MORE_COMPONENTS
        }
    }

    const OutlinePoint = struct { p: Point, on_curve: bool };

    fn appendSimple(
        self: *const TrueType,
        allocator: Allocator,
        range: Table,
        contour_count: u32,
        transform: Transform,
        tolerance: f32,
        segments: *std.ArrayList(Segment),
    ) Error!void {
        if (contour_count == 0) return;
        const data = self.data;
        const limit = range.offset + range.length;
        const ends_at = range.offset + 10;
        const point_count: u32 = @as(u32, try readU16(data, ends_at + (contour_count - 1) * 2)) + 1;
        const instruction_len = try readU16(data, ends_at + contour_count * 2);
        var p = ends_at + contour_count * 2 + 2 + instruction_len;

        // Every point needs at least one flag byte, or a repeat of one, so an
        // absurd count from a corrupt file is rejected before allocating.
        if (point_count > @as(u64, limit -| p) * 256) return error.InvalidFont;

        const points = try allocator.alloc(OutlinePoint, point_count);
        defer allocator.free(points);
        const flags = try allocator.alloc(u8, point_count);
        defer allocator.free(flags);

        var i: u32 = 0;
        while (i < point_count) {
            if (p >= limit) return error.InvalidFont;
            const flag = try readU8(data, p);
            p += 1;
            flags[i] = flag;
            i += 1;
            if (flag & 0x08 != 0) { // REPEAT_FLAG
                if (p >= limit) return error.InvalidFont;
                var repeat = try readU8(data, p);
                p += 1;
                while (repeat > 0 and i < point_count) : (repeat -= 1) {
                    flags[i] = flag;
                    i += 1;
                }
            }
        }

        // Coordinates are deltas. X and Y use the same encoding with different bits.
        // i64: 65536 points of 16-bit deltas can overflow i32 in a corrupt file.
        var x: i64 = 0;
        for (flags, points) |flag, *point| {
            if (flag & 0x02 != 0) { // X_SHORT
                const d: i64 = try readU8(data, p);
                p += 1;
                x += if (flag & 0x10 != 0) d else -d;
            } else if (flag & 0x10 == 0) {
                x += try readI16(data, p);
                p += 2;
            }
            point.p.x = @floatFromInt(x);
            point.on_curve = flag & 0x01 != 0;
        }
        var y: i64 = 0;
        for (flags, points) |flag, *point| {
            if (flag & 0x04 != 0) { // Y_SHORT
                const d: i64 = try readU8(data, p);
                p += 1;
                y += if (flag & 0x20 != 0) d else -d;
            } else if (flag & 0x20 == 0) {
                y += try readI16(data, p);
                p += 2;
            }
            point.p.y = @floatFromInt(y);
        }
        if (p > limit) return error.InvalidFont;

        for (points) |*point| point.p = transform.apply(point.p);

        var first: u32 = 0;
        var c: u32 = 0;
        while (c < contour_count) : (c += 1) {
            const last: u32 = try readU16(data, ends_at + c * 2);
            if (last < first or last >= point_count) return error.InvalidFont;
            try appendContour(allocator, points[first .. last + 1], tolerance, segments);
            first = last + 1;
        }
    }

    /// Walks one closed contour. Between two off-curve points there is an
    /// implied on-curve point at their midpoint.
    fn appendContour(
        allocator: Allocator,
        points: []const OutlinePoint,
        tolerance: f32,
        segments: *std.ArrayList(Segment),
    ) Error!void {
        if (points.len < 2) return;

        const n = points.len;
        var begin: usize = 0;
        var start: Point = undefined;
        if (points[0].on_curve) {
            start = points[0].p;
            begin = 1;
        } else if (points[n - 1].on_curve) {
            start = points[n - 1].p;
        } else {
            start = midpoint(points[0].p, points[n - 1].p);
        }

        var current = start;
        var control: ?Point = null;
        for (0..n) |offset| {
            const point = points[(begin + offset) % n];
            if (point.on_curve) {
                if (control) |ctrl| {
                    try appendQuad(allocator, current, ctrl, point.p, tolerance, segments);
                    control = null;
                } else {
                    try segments.append(allocator, .{ .a = current, .b = point.p });
                }
                current = point.p;
            } else {
                if (control) |ctrl| {
                    const mid = midpoint(ctrl, point.p);
                    try appendQuad(allocator, current, ctrl, mid, tolerance, segments);
                    current = mid;
                }
                control = point.p;
            }
        }
        if (control) |ctrl| {
            try appendQuad(allocator, current, ctrl, start, tolerance, segments);
        } else if (current.x != start.x or current.y != start.y) {
            try segments.append(allocator, .{ .a = current, .b = start });
        }
    }

    fn midpoint(a: Point, b: Point) Point {
        return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
    }

    fn appendQuad(
        allocator: Allocator,
        a: Point,
        ctrl: Point,
        b: Point,
        tolerance: f32,
        segments: *std.ArrayList(Segment),
    ) Error!void {
        // The largest deviation of a quadratic from its chord is a quarter of
        // the distance from the control point to the chord's midpoint.
        const dx = (a.x + b.x) / 2 - ctrl.x;
        const dy = (a.y + b.y) / 2 - ctrl.y;
        const deviation = @sqrt(dx * dx + dy * dy) / 2;
        const steps: u32 = @intFromFloat(std.math.clamp(@ceil(@sqrt(deviation / tolerance)), 1, 16));

        var previous = a;
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const u = 1 - t;
            const point: Point = .{
                .x = u * u * a.x + 2 * u * t * ctrl.x + t * t * b.x,
                .y = u * u * a.y + 2 * u * t * ctrl.y + t * t * b.y,
            };
            try segments.append(allocator, .{ .a = previous, .b = point });
            previous = point;
        }
    }
};

fn findTable(data: []const u8, tag: *const [4]u8) Error!TrueType.Table {
    const count = try readU16(data, 4);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const record = 12 + i * 16;
        if (record + 16 > data.len) return error.InvalidFont;
        if (std.mem.eql(u8, data[record..][0..4], tag)) {
            const offset = try readU32(data, record + 8);
            const length = try readU32(data, record + 12);
            if (@as(u64, offset) + length > data.len) return error.InvalidFont;
            return .{ .offset = offset, .length = length };
        }
    }
    return error.InvalidFont;
}

fn readU8(data: []const u8, offset: u32) Error!u8 {
    if (offset >= data.len) return error.InvalidFont;
    return data[offset];
}

fn readU16(data: []const u8, offset: u32) Error!u16 {
    if (@as(u64, offset) + 2 > data.len) return error.InvalidFont;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

fn readI16(data: []const u8, offset: u32) Error!i16 {
    return @bitCast(try readU16(data, offset));
}

fn readU32(data: []const u8, offset: u32) Error!u32 {
    if (@as(u64, offset) + 4 > data.len) return error.InvalidFont;
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

fn readF2Dot14(data: []const u8, offset: u32) Error!f32 {
    return @as(f32, @floatFromInt(try readI16(data, offset))) / 16384;
}
