//! Cursor layout. A `Layout` places items one after another along its axis.
//!
//! Immediate mode describes items one at a time, so `grow` items and alignment
//! can't know about siblings that come later. Instead each layout reports a
//! `Measure` when it finishes, and the next frame uses that. Sizes therefore
//! settle one frame after they change. This file is pure math, so it is easy
//! to test.

const std = @import("std");
const draw = @import("draw.zig");
const Rect = draw.Rect;
const Vec2 = draw.Vec2;

/// How big an item wants to be along one axis.
pub const Size = union(enum) {
    /// Fit the content.
    auto,
    /// Exactly this many logical units.
    fixed: f32,
    /// A share of the free space, proportional to this weight.
    grow: f32,

    /// Takes all free space, shared equally with other `fill` items.
    pub const fill: Size = .{ .grow = 1 };

    /// Exactly `value` logical units.
    pub fn px(value: f32) Size {
        return .{ .fixed = value };
    }
};

/// The direction items flow in.
pub const Axis = enum { vertical, horizontal };

/// Position inside leftover space.
pub const Align = enum {
    start,
    center,
    end,

    /// Returns how much of the leftover space goes before the item.
    pub fn factor(a: Align) f32 {
        return switch (a) {
            .start => 0,
            .center => 0.5,
            .end => 1,
        };
    }
};

/// What a layout learned about its content. Fed back in the next frame.
pub const Measure = struct {
    /// Bounding size of everything placed.
    content: Vec2 = .{},
    /// Size along the main axis used by anything but `grow` items, including
    /// spacing.
    fixed_main: f32 = 0,
    /// Sum of the `grow` weights on the main axis.
    grow_total: f32 = 0,
    /// Size across the axis the content needs: like `content`'s, but
    /// counting items that fill across by their natural size, not the
    /// size they were stretched to.
    cross_natural: f32 = 0,

    /// The size a group with this content asks for, with `padding` on each
    /// side: what its content needs, not the space its `grow` items
    /// stretched into, so a filling group can shrink again.
    pub fn natural(m: Measure, axis: Axis, padding: f32) Vec2 {
        const main = if (m.grow_total > 0) m.fixed_main else if (axis == .horizontal) m.content.x else m.content.y;
        return switch (axis) {
            .horizontal => .{ .x = main + 2 * padding, .y = m.cross_natural + 2 * padding },
            .vertical => .{ .x = m.cross_natural + 2 * padding, .y = main + 2 * padding },
        };
    }

    /// True if `other` differs by a visible amount.
    pub fn differs(a: Measure, other: Measure) bool {
        const tolerance = 0.01;
        return @abs(a.content.x - other.content.x) > tolerance or
            @abs(a.content.y - other.content.y) > tolerance or
            @abs(a.fixed_main - other.fixed_main) > tolerance or
            @abs(a.grow_total - other.grow_total) > tolerance or
            @abs(a.cross_natural - other.cross_natural) > tolerance;
    }
};

/// Settings for `Layout.init`.
pub const Options = struct {
    /// Top-left of the content area. Only `x` and `y` matter unless the
    /// matching extent below is set.
    origin: Vec2 = .{},
    axis: Axis = .vertical,
    spacing: Vec2 = .{},
    /// Where items sit across the axis.
    alignment: Align = .start,
    /// Where the whole run of items sits along the axis. Needs `main_extent`.
    justify: Align = .start,
    /// Available size along the axis, or null to fit the content.
    main_extent: ?f32 = null,
    /// Available size across the axis, or null to fit the content.
    cross_extent: ?f32 = null,
    /// The measure from the previous frame.
    previous: Measure = .{},
};

/// Places items along an axis.
pub const Layout = struct {
    options: Options,
    /// Where the next item goes along the main axis.
    cursor: f32,
    /// Start of the first item along the main axis.
    start: f32,
    /// Top of the current line, for vertical layouts.
    line_y: f32,
    /// Tallest item on the current line, for vertical layouts.
    line_height: f32 = 0,
    /// Right edge of the previous item, for `sameLine`.
    previous_right: f32,
    same_line: bool = false,
    /// Largest cross size so far.
    cross_used: f32 = 0,
    /// Largest natural cross size so far (see `Measure.cross_natural`).
    cross_natural: f32 = 0,
    /// Main-axis size given to `grow` items.
    grown_main: f32 = 0,
    grow_total: f32 = 0,
    placed_any: bool = false,

    /// Starts a layout.
    pub fn init(options: Options) Layout {
        const horizontal = options.axis == .horizontal;
        const origin_main = if (horizontal) options.origin.x else options.origin.y;

        var start = origin_main;
        if (options.main_extent) |extent| {
            if (options.previous.grow_total == 0) {
                const used = if (horizontal) options.previous.content.x else options.previous.content.y;
                start += @max(0, extent - used) * options.justify.factor();
            }
        }
        return .{
            .options = options,
            .cursor = start,
            .start = start,
            .line_y = options.origin.y,
            .previous_right = options.origin.x,
        };
    }

    /// Makes the next item continue the current line. Vertical layouts only;
    /// horizontal ones do this for every item.
    pub fn sameLine(self: *Layout) void {
        self.same_line = self.options.axis == .vertical;
    }

    fn crossExtent(self: *const Layout) f32 {
        // What the content needs across, not what fill items were stretched
        // to last frame: otherwise a fill item could never get narrower.
        return self.options.cross_extent orelse self.options.previous.cross_natural;
    }

    fn resolveMain(self: *const Layout, size: Size, natural: f32) f32 {
        return switch (size) {
            .auto => natural,
            .fixed => |v| v,
            .grow => |weight| {
                const extent = self.options.main_extent orelse return natural;
                const previous = self.options.previous;
                if (previous.grow_total <= 0) return natural;
                return @max(0, extent - previous.fixed_main) * weight / previous.grow_total;
            },
        };
    }

    fn resolveCross(self: *const Layout, size: Size, natural: f32) f32 {
        return switch (size) {
            .auto => natural,
            .fixed => |v| v,
            .grow => @max(natural, self.crossExtent()),
        };
    }

    /// Reserves space and returns where the item goes. `natural` is the size
    /// that `.auto` means.
    pub fn place(self: *Layout, width: Size, height: Size, natural: Vec2) Rect {
        return switch (self.options.axis) {
            .vertical => self.placeVertical(width, height, natural),
            .horizontal => self.placeHorizontal(width, height, natural),
        };
    }

    fn placeVertical(self: *Layout, width: Size, height: Size, natural: Vec2) Rect {
        const w = self.resolveCross(width, natural.x);
        const h = self.resolveMain(height, natural.y);
        const o = &self.options;

        var rect: Rect = .{ .w = w, .h = h };
        const on_line = self.same_line;
        if (self.same_line) {
            rect.x = self.previous_right + o.spacing.x;
            self.line_height = @max(self.line_height, h);
            // Shorter than what came first on the line: center on it. The
            // reverse case needs a horizontal group, which measures first.
            rect.y = self.line_y + (self.line_height - h) / 2;
        } else {
            if (self.placed_any) self.cursor += o.spacing.y;
            self.line_y = self.cursor;
            self.line_height = h;
            rect.x = o.origin.x + @max(0, self.crossExtent() - w) * o.alignment.factor();
            rect.y = self.line_y;
        }
        self.same_line = false;
        self.placed_any = true;
        self.cursor = self.line_y + self.line_height;
        self.previous_right = rect.right();
        self.cross_used = @max(self.cross_used, rect.right() - o.origin.x);
        // An item on the same line starts where it was put; others would
        // start at the edge if the layout were only as wide as needed.
        const natural_w = if (width == .grow) natural.x else w;
        self.cross_natural = @max(self.cross_natural, (if (on_line) rect.x - o.origin.x else 0) + natural_w);
        // Without a known extent there is nothing to grow into: the item
        // was placed at its natural size, like `.auto`.
        if (height == .grow and o.main_extent != null) {
            self.grown_main += h;
            self.grow_total += height.grow;
        }
        return rect;
    }

    fn placeHorizontal(self: *Layout, width: Size, height: Size, natural: Vec2) Rect {
        const w = self.resolveMain(width, natural.x);
        const h = self.resolveCross(height, natural.y);
        const o = &self.options;

        if (self.placed_any) self.cursor += o.spacing.x;
        const line = @max(self.crossExtent(), h);
        const rect: Rect = .{
            .x = self.cursor,
            .y = o.origin.y + (line - h) * o.alignment.factor(),
            .w = w,
            .h = h,
        };
        self.placed_any = true;
        self.cursor += w;
        self.previous_right = rect.right();
        self.cross_used = @max(self.cross_used, h);
        self.cross_natural = @max(self.cross_natural, if (height == .grow) natural.y else h);
        if (width == .grow and o.main_extent != null) {
            self.grown_main += w;
            self.grow_total += width.grow;
        }
        return rect;
    }

    /// Returns what this layout measured, for the next frame.
    pub fn finish(self: *const Layout) Measure {
        const main = self.cursor - self.start;
        return .{
            .content = if (self.options.axis == .horizontal)
                .{ .x = main, .y = self.cross_used }
            else
                .{ .x = self.cross_used, .y = main },
            .fixed_main = main - self.grown_main,
            .grow_total = self.grow_total,
            .cross_natural = self.cross_natural,
        };
    }
};

const testing = std.testing;

fn vertical(spacing: Vec2) Layout {
    return .init(.{ .spacing = spacing });
}

test "items stack vertically with spacing" {
    var l: Layout = .init(.{ .origin = .{ .x = 10, .y = 20 }, .spacing = .{ .x = 4, .y = 5 } });
    const a = l.place(.auto, .auto, .{ .x = 30, .y = 10 });
    const b = l.place(.auto, .auto, .{ .x = 30, .y = 10 });
    try testing.expectEqual(@as(f32, 20), a.y);
    try testing.expectEqual(@as(f32, 35), b.y);
    try testing.expectEqual(@as(f32, 10), b.x);
}

test "sameLine continues to the right" {
    var l = vertical(.{ .x = 4, .y = 5 });
    const a = l.place(.auto, .auto, .{ .x = 30, .y = 10 });
    l.sameLine();
    const b = l.place(.auto, .auto, .{ .x = 20, .y = 10 });
    try testing.expectEqual(a.y, b.y);
    try testing.expectEqual(@as(f32, 34), b.x);
}

test "the next line clears the tallest item on the line" {
    var l = vertical(.{ .x = 4, .y = 5 });
    _ = l.place(.auto, .auto, .{ .x = 30, .y = 10 });
    l.sameLine();
    _ = l.place(.auto, .auto, .{ .x = 20, .y = 40 });
    const c = l.place(.auto, .auto, .{ .x = 20, .y = 10 });
    try testing.expectEqual(@as(f32, 45), c.y);
}

test "a shorter sameLine item centers on the line" {
    var l = vertical(.{});
    _ = l.place(.auto, .auto, .{ .x = 30, .y = 30 });
    l.sameLine();
    const b = l.place(.auto, .auto, .{ .x = 20, .y = 10 });
    try testing.expectEqual(@as(f32, 10), b.y);
}

test "measure counts spacing but not outer space" {
    var l = vertical(.{ .x = 4, .y = 5 });
    _ = l.place(.auto, .auto, .{ .x = 30, .y = 10 });
    _ = l.place(.auto, .auto, .{ .x = 50, .y = 10 });
    const m = l.finish();
    try testing.expectEqual(@as(f32, 50), m.content.x);
    try testing.expectEqual(@as(f32, 25), m.content.y);
}

test "grow shares free space by weight, using last frame's measure" {
    // Frame 1 has no memory, so growing items get their natural size.
    var first: Layout = .init(.{ .axis = .horizontal, .main_extent = 100, .spacing = .{ .x = 10 } });
    _ = first.place(.px(20), .auto, .{});
    _ = first.place(.{ .grow = 1 }, .auto, .{ .x = 5 });
    _ = first.place(.{ .grow = 3 }, .auto, .{ .x = 5 });
    const measure = first.finish();
    try testing.expectEqual(@as(f32, 40), measure.fixed_main); // 20 + two gaps
    try testing.expectEqual(@as(f32, 4), measure.grow_total);

    // Frame 2 knows 60 is free.
    var l: Layout = .init(.{ .axis = .horizontal, .main_extent = 100, .spacing = .{ .x = 10 }, .previous = measure });
    _ = l.place(.px(20), .auto, .{});
    const a = l.place(.{ .grow = 1 }, .auto, .{ .x = 5 });
    const b = l.place(.{ .grow = 3 }, .auto, .{ .x = 5 });
    try testing.expectEqual(@as(f32, 15), a.w);
    try testing.expectEqual(@as(f32, 45), b.w);
    try testing.expectEqual(@as(f32, 100), b.right());
    // What growth depends on is unchanged, so frame 3 lays out identically.
    const second = l.finish();
    try testing.expectEqual(measure.fixed_main, second.fixed_main);
    try testing.expectEqual(measure.grow_total, second.grow_total);
}

test "grow never goes negative when content overflows" {
    var l: Layout = .init(.{
        .axis = .horizontal,
        .main_extent = 10,
        .previous = .{ .fixed_main = 50, .grow_total = 1 },
    });
    try testing.expectEqual(@as(f32, 0), l.place(.fill, .auto, .{}).w);
}

test "a group's natural size doesn't count what its fill items stretched into" {
    // A column whose items fill across: its natural width is what they
    // need, not what they were given.
    var col: Layout = .init(.{ .cross_extent = 600 });
    _ = col.place(.fill, .auto, .{ .x = 120, .y = 20 });
    _ = col.place(.auto, .auto, .{ .x = 80, .y = 20 });
    const m = col.finish();
    try testing.expectEqual(@as(f32, 600), m.content.x);
    try testing.expectEqual(@as(f32, 120), m.natural(.vertical, 0).x);
    // A row with nothing to grow into places fill items at their natural
    // size, and asks for all of it.
    var row: Layout = .init(.{ .axis = .horizontal });
    _ = row.place(.fill, .auto, .{ .x = 50, .y = 10 });
    _ = row.place(.auto, .auto, .{ .x = 30, .y = 10 });
    try testing.expectEqual(@as(f32, 80), row.finish().natural(.horizontal, 0).x);
}

test "fill on the cross axis takes the known extent" {
    var l: Layout = .init(.{ .cross_extent = 200 });
    try testing.expectEqual(@as(f32, 200), l.place(.fill, .auto, .{ .x = 10, .y = 10 }).w);
}

test "fill without a known extent matches the widest sibling" {
    // (the widest sibling's natural width, not what fill items were stretched to)
    var l: Layout = .init(.{ .previous = .{ .content = .{ .x = 120 }, .cross_natural = 80 } });
    try testing.expectEqual(@as(f32, 80), l.place(.fill, .auto, .{ .x = 10, .y = 10 }).w);
}

test "alignment across the axis" {
    var l: Layout = .init(.{ .cross_extent = 100, .alignment = .end });
    try testing.expectEqual(@as(f32, 70), l.place(.auto, .auto, .{ .x = 30, .y = 10 }).x);

    var row: Layout = .init(.{ .axis = .horizontal, .alignment = .center, .cross_extent = 40 });
    try testing.expectEqual(@as(f32, 15), row.place(.auto, .auto, .{ .x = 30, .y = 10 }).y);
}

test "justify moves the run using last frame's width" {
    var l: Layout = .init(.{
        .axis = .horizontal,
        .main_extent = 100,
        .justify = .end,
        .previous = .{ .content = .{ .x = 30 } },
    });
    try testing.expectEqual(@as(f32, 70), l.place(.auto, .auto, .{ .x = 30 }).x);
}

test "an empty layout measures zero" {
    const l: Layout = .init(.{ .spacing = .{ .x = 9, .y = 9 } });
    try testing.expectEqual(Measure{}, l.finish());
}

