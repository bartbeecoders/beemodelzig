//! Icons: a small built-in set drawn as vector strokes, sharp at any scale,
//! and bitmap icon sets an app brings along (an atlas of equal cells).
//!
//!     const set: zui.IconSet = .grid(&atlas_image, 16, 16);
//!     _ = ui.button("Save", .{ .icon = set.icon(3) });
//!     _ = ui.button("##close", .{ .icon = .{ .builtin = .close } });

const std = @import("std");
const gfx = @import("draw.zig");
const Vec2 = gfx.Vec2;
const Rect = gfx.Rect;
const Color = gfx.Color;
const Allocator = std.mem.Allocator;

/// Icons drawn from strokes, part of Zui.
pub const Builtin = enum {
    check,
    close,
    plus,
    minus,
    chevron_down,
    chevron_up,
    chevron_left,
    chevron_right,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    search,
    menu,
    more,
    dot,
    info,
    warning,
    eye,
    eye_off,
    lock,
    unlock,
    eyedropper,
    folder,
    file,
    image,
    star,
    home,
    drive,
    refresh,
    play,
    pause,
    link,
    unlink,
};

/// An atlas of equally sized icons, left to right, then top to bottom.
pub const IconSet = struct {
    /// `alpha8` icons take the color they are drawn in; `argb32` icons keep
    /// their own colors.
    image: *const gfx.Image,
    cell_width: u32,
    cell_height: u32,
    columns: u32,
    count: u32,
    /// Pixel art: drawn at a whole multiple of the cell size (the largest
    /// that fits, centred), never stretched in between, so it stays crisp
    /// (and a renderer copies it rather than filtering it).
    whole_pixels: bool = false,

    /// A set filling `image` with `cell_width` x `cell_height` icons.
    pub fn grid(image: *const gfx.Image, cell_width: u32, cell_height: u32) IconSet {
        const columns = @max(1, image.width / @max(1, cell_width));
        const rows = image.height / @max(1, cell_height);
        return .{ .image = image, .cell_width = cell_width, .cell_height = cell_height, .columns = columns, .count = columns * rows };
    }

    /// The icon at `index`.
    pub fn icon(self: *const IconSet, index: u32) Icon {
        return .{ .bitmap = .{ .set = self, .index = index } };
    }

    /// Where icon `index` is in the image, in 0..1 units.
    pub fn uv(self: *const IconSet, index: u32) Rect {
        const w: f32 = @floatFromInt(self.image.width);
        const h: f32 = @floatFromInt(self.image.height);
        const col = index % self.columns;
        const row = index / self.columns;
        return .{
            .x = @as(f32, @floatFromInt(col * self.cell_width)) / w,
            .y = @as(f32, @floatFromInt(row * self.cell_height)) / h,
            .w = @as(f32, @floatFromInt(self.cell_width)) / w,
            .h = @as(f32, @floatFromInt(self.cell_height)) / h,
        };
    }
};

/// An icon from either source.
pub const Icon = union(enum) {
    builtin: Builtin,
    bitmap: struct { set: *const IconSet, index: u32 },
};

/// Records `icon` fitted into `r` (centered, square) in `color`.
pub fn draw(list: *gfx.DrawList, icon: Icon, r: Rect, color: Color) Allocator.Error!void {
    const size = @min(r.w, r.h);
    const box: Rect = .{ .x = r.x + (r.w - size) / 2, .y = r.y + (r.h - size) / 2, .w = size, .h = size };
    switch (icon) {
        .builtin => |b| try drawBuiltin(list, b, box, color),
        .bitmap => |bm| {
            if (bm.index >= bm.set.count) return;
            const set = bm.set;
            // Keep the cell's aspect ratio inside the square.
            const cw: f32 = @floatFromInt(set.cell_width);
            const ch: f32 = @floatFromInt(set.cell_height);
            const fit = @min(size / cw, size / ch);
            const k = if (set.whole_pixels and fit >= 1) @floor(fit) else fit;
            const target: Rect = .{ .x = box.x + (size - cw * k) / 2, .y = box.y + (size - ch * k) / 2, .w = cw * k, .h = ch * k };
            try list.addImage(.{
                .image = set.image,
                .rect = target,
                .uv = set.uv(bm.index),
                .tint = if (set.image.format == .alpha8) color else Color.white.withAlpha(color.a),
                .filter = .auto,
            });
        },
    }
}

fn drawBuiltin(list: *gfx.DrawList, which: Builtin, box: Rect, color: Color) Allocator.Error!void {
    const s = box.w;
    // About 1.5 units at 16, thicker for big icons.
    const w = @max(1.25, s / 10);
    const P = struct {
        b: Rect,
        fn at(p: @This(), x: f32, y: f32) Vec2 {
            return .{ .x = p.b.x + x * p.b.w, .y = p.b.y + y * p.b.h };
        }
    };
    const p: P = .{ .b = box };
    switch (which) {
        .check => try list.addPath(.{ .points = &.{ p.at(0.2, 0.53), p.at(0.42, 0.74), p.at(0.8, 0.3) }, .color = color, .width = w * 1.15 }),
        .close => {
            try list.addLine(p.at(0.27, 0.27), p.at(0.73, 0.73), color, w);
            try list.addLine(p.at(0.73, 0.27), p.at(0.27, 0.73), color, w);
        },
        .plus => {
            try list.addLine(p.at(0.5, 0.2), p.at(0.5, 0.8), color, w);
            try list.addLine(p.at(0.2, 0.5), p.at(0.8, 0.5), color, w);
        },
        .minus => try list.addLine(p.at(0.2, 0.5), p.at(0.8, 0.5), color, w),
        .chevron_down => try chevron(list, p.at(0.5, 0.5), .{ .x = 0, .y = 1 }, s, color, w),
        .chevron_up => try chevron(list, p.at(0.5, 0.5), .{ .x = 0, .y = -1 }, s, color, w),
        .chevron_left => try chevron(list, p.at(0.5, 0.5), .{ .x = -1, .y = 0 }, s, color, w),
        .chevron_right => try chevron(list, p.at(0.5, 0.5), .{ .x = 1, .y = 0 }, s, color, w),
        .arrow_left, .arrow_right, .arrow_up, .arrow_down => {
            const d: Vec2 = switch (which) {
                .arrow_left => .{ .x = -1, .y = 0 },
                .arrow_right => .{ .x = 1, .y = 0 },
                .arrow_up => .{ .x = 0, .y = -1 },
                else => .{ .x = 0, .y = 1 },
            };
            const c = p.at(0.5, 0.5);
            const tip = c.add(d.scale(s * 0.3));
            try list.addLine(c.sub(d.scale(s * 0.3)), tip, color, w);
            try chevron(list, tip.sub(d.scale(s * 0.13)), d, s, color, w);
        },
        .search => {
            try list.addCircle(p.at(0.44, 0.44), s * 0.22, color, w);
            try list.addLine(p.at(0.6, 0.6), p.at(0.8, 0.8), color, w * 1.2);
        },
        .menu => for ([_]f32{ 0.28, 0.5, 0.72 }) |y| try list.addLine(p.at(0.2, y), p.at(0.8, y), color, w),
        .more => for ([_]f32{ 0.25, 0.5, 0.75 }) |x| try list.addCircle(p.at(x, 0.5), s * 0.08, color, 0),
        .dot => try list.addCircle(p.at(0.5, 0.5), s * 0.18, color, 0),
        .info => {
            try list.addCircle(p.at(0.5, 0.5), s * 0.38, color, w);
            try list.addCircle(p.at(0.5, 0.31), s * 0.055, color, 0);
            try list.addLine(p.at(0.5, 0.44), p.at(0.5, 0.71), color, w);
        },
        .eye, .eye_off => {
            // An almond: two shallow curves meeting at the corners.
            var pts: [26]Vec2 = undefined;
            for (0..13) |i| {
                const t = @as(f32, @floatFromInt(i)) / 12;
                const x = 0.1 + 0.8 * t;
                const bulge = 0.27 * (1 - (2 * t - 1) * (2 * t - 1));
                pts[i] = p.at(x, 0.5 - bulge);
                pts[25 - i] = p.at(x, 0.5 + bulge);
            }
            try list.addPath(.{ .points = &pts, .color = color, .width = w, .closed = true });
            try list.addCircle(p.at(0.5, 0.5), s * 0.11, color, 0);
            if (which == .eye_off) try list.addLine(p.at(0.18, 0.85), p.at(0.82, 0.15), color, w);
        },
        .lock, .unlock => {
            try list.addPath(.{ .points = &.{ p.at(0.24, 0.46), p.at(0.76, 0.46), p.at(0.76, 0.86), p.at(0.24, 0.86) }, .color = color, .width = w, .closed = true });
            // The shackle; open, it swings up on the right.
            const top = p.at(0.5, 0.34);
            const r = s * 0.17;
            if (which == .lock) {
                try list.addArc(top, r, std.math.pi, 2 * std.math.pi, color, w);
                try list.addLine(.{ .x = top.x - r, .y = top.y }, .{ .x = top.x - r, .y = p.at(0, 0.46).y }, color, w);
                try list.addLine(.{ .x = top.x + r, .y = top.y }, .{ .x = top.x + r, .y = p.at(0, 0.46).y }, color, w);
            } else {
                const t2: Vec2 = .{ .x = top.x + r * 0.9, .y = top.y - s * 0.06 };
                try list.addArc(t2, r, std.math.pi, 2 * std.math.pi, color, w);
                try list.addLine(.{ .x = t2.x - r, .y = t2.y }, .{ .x = t2.x - r, .y = p.at(0, 0.46).y }, color, w);
            }
        },
        .eyedropper => {
            // A pipette: a slim tube pointing down-left and a bulb.
            try list.addLine(p.at(0.2, 0.8), p.at(0.58, 0.42), color, w * 1.4);
            try list.addLine(p.at(0.48, 0.36), p.at(0.66, 0.54), color, w);
            try list.addCircle(p.at(0.68, 0.32), s * 0.13, color, 0);
        },
        .folder => try list.addPath(.{ .points = &.{ p.at(0.12, 0.26), p.at(0.4, 0.26), p.at(0.48, 0.34), p.at(0.88, 0.34), p.at(0.88, 0.78), p.at(0.12, 0.78) }, .color = color, .width = w, .closed = true }),
        .file => {
            try list.addPath(.{ .points = &.{ p.at(0.24, 0.12), p.at(0.58, 0.12), p.at(0.76, 0.3), p.at(0.76, 0.88), p.at(0.24, 0.88) }, .color = color, .width = w, .closed = true });
            try list.addPath(.{ .points = &.{ p.at(0.58, 0.12), p.at(0.58, 0.3), p.at(0.76, 0.3) }, .color = color, .width = w });
        },
        .image => {
            try list.addPath(.{ .points = &.{ p.at(0.14, 0.2), p.at(0.86, 0.2), p.at(0.86, 0.8), p.at(0.14, 0.8) }, .color = color, .width = w, .closed = true });
            try list.addPath(.{ .points = &.{ p.at(0.2, 0.74), p.at(0.42, 0.48), p.at(0.58, 0.64), p.at(0.68, 0.54), p.at(0.8, 0.74) }, .color = color, .width = w });
            try list.addCircle(p.at(0.66, 0.36), s * 0.06, color, 0);
        },
        .star => {
            var pts: [10]Vec2 = undefined;
            for (&pts, 0..) |*q, i| {
                const a = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * std.math.pi / 5.0;
                const r: f32 = if (i % 2 == 0) 0.4 else 0.17;
                q.* = p.at(0.5 + r * @cos(a), 0.54 + r * @sin(a));
            }
            try list.addPath(.{ .points = &pts, .color = color, .width = w, .closed = true });
        },
        .home => try list.addPath(.{ .points = &.{ p.at(0.14, 0.5), p.at(0.5, 0.16), p.at(0.86, 0.5), p.at(0.76, 0.5), p.at(0.76, 0.84), p.at(0.24, 0.84), p.at(0.24, 0.5) }, .color = color, .width = w, .closed = true }),
        .drive => {
            try list.addPath(.{ .points = &.{ p.at(0.12, 0.32), p.at(0.88, 0.32), p.at(0.88, 0.7), p.at(0.12, 0.7) }, .color = color, .width = w, .closed = true });
            try list.addCircle(p.at(0.74, 0.51), s * 0.05, color, 0);
        },
        .refresh => {
            try list.addArc(p.at(0.5, 0.5), s * 0.3, -std.math.pi * 0.35, std.math.pi * 1.45, color, w);
            const tip = p.at(0.5 + 0.3 * @cos(-std.math.pi * 0.35), 0.5 + 0.3 * @sin(-std.math.pi * 0.35));
            try list.addPath(.{ .points = &.{ tip.add(.{ .x = -s * 0.2, .y = -s * 0.04 }), tip, tip.add(.{ .x = -s * 0.02, .y = s * 0.19 }) }, .color = color, .width = w });
        },
        .play => try list.addPath(.{ .points = &.{ p.at(0.3, 0.2), p.at(0.8, 0.5), p.at(0.3, 0.8) }, .color = color, .width = 0, .closed = true }),
        .pause => {
            try list.addRect(.{ .rect = .{ .x = box.x + s * 0.26, .y = box.y + s * 0.22, .w = s * 0.16, .h = s * 0.56 }, .fill = color });
            try list.addRect(.{ .rect = .{ .x = box.x + s * 0.58, .y = box.y + s * 0.22, .w = s * 0.16, .h = s * 0.56 }, .fill = color });
        },
        .link, .unlink => {
            try list.addPath(.{ .points = &.{ p.at(0.44, 0.3), p.at(0.3, 0.3), p.at(0.16, 0.44), p.at(0.16, 0.56), p.at(0.3, 0.7), p.at(0.44, 0.7) }, .color = color, .width = w });
            try list.addPath(.{ .points = &.{ p.at(0.56, 0.3), p.at(0.7, 0.3), p.at(0.84, 0.44), p.at(0.84, 0.56), p.at(0.7, 0.7), p.at(0.56, 0.7) }, .color = color, .width = w });
            if (which == .link) try list.addLine(p.at(0.34, 0.5), p.at(0.66, 0.5), color, w) else try list.addLine(p.at(0.4, 0.84), p.at(0.6, 0.16), color, w);
        },
        .warning => {
            try list.addPath(.{ .points = &.{ p.at(0.5, 0.14), p.at(0.88, 0.82), p.at(0.12, 0.82) }, .color = color, .width = w, .closed = true });
            try list.addLine(p.at(0.5, 0.38), p.at(0.5, 0.6), color, w);
            try list.addCircle(p.at(0.5, 0.7), s * 0.05, color, 0);
        },
    }
}

/// A V pointing along `d` (a unit axis), centered on `c`.
fn chevron(list: *gfx.DrawList, c: Vec2, d: Vec2, s: f32, color: Color, w: f32) Allocator.Error!void {
    const side: Vec2 = .{ .x = -d.y, .y = d.x };
    const tip = c.add(d.scale(s * 0.12));
    const back = c.sub(d.scale(s * 0.12));
    try list.addPath(.{
        .points = &.{ back.add(side.scale(s * 0.24)), tip, back.sub(side.scale(s * 0.24)) },
        .color = color,
        .width = w,
    });
}

test "an icon set finds its cells" {
    const pixels: [48 * 32]u8 = @splat(0);
    const img: gfx.Image = .initAlpha(&pixels, 48, 32);
    const set: IconSet = .grid(&img, 16, 16);
    try std.testing.expectEqual(@as(u32, 6), set.count);
    const r = set.uv(4);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 48.0), r.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.y, 1e-6);
}

test "every built-in icon draws something" {
    var list: gfx.DrawList = .init(std.testing.allocator);
    defer list.deinit();
    inline for (comptime std.meta.fieldNames(Builtin)) |name| {
        list.clear();
        try draw(&list, .{ .builtin = @field(Builtin, name) }, .{ .w = 16, .h = 16 }, .white);
        try std.testing.expect(list.commands.items.len > 0);
    }
}
