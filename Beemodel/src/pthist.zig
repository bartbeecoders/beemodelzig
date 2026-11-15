// The texture paint history (paint.s: pt_hist): images are not in the scene's
// undo, so what changes their pixels keeps its own steps; paint.undo and paint.redo
// walk them. A stroke is a step: the box it touched, its pixels before, in the
// buffer it painted (the image's, or a layer's). Baking is one step per bake
// (pt_record): the whole of it. The steps swap with the image, 32 at most, and a new
// one drops what was undone. Whatever changes the stack of layers forgets every
// step (they point at layers: pt_hist_clear).
const std = @import("std");
const images = @import("images.zig");
const layers = @import("layers.zig");
const app = @import("app.zig");
const A = std.heap.page_allocator;

const HIST_N = 32;
const Step = struct {
    im: usize,
    /// the buffer: -1 the image's, else a layer
    layer: i32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// the image's size when it was taken
    iw: u32,
    ih: u32,
    px: [][4]u8,
};
var hist: [HIST_N]Step = undefined;
var hn: usize = 0;
var hpos: usize = 0;

/// The buffer painted as it is, for commit; null: no memory, no step.
pub fn snap(im: usize) ?[][4]u8 {
    return A.dupe([4]u8, layers.target(&images.list[im])) catch null;
}

fn room() void {
    while (hn > hpos) {
        hn -= 1;
        A.free(hist[hn].px);
    }
    if (hn == HIST_N) {
        A.free(hist[0].px);
        std.mem.copyForwards(Step, hist[0 .. HIST_N - 1], hist[1..HIST_N]);
        hn -= 1;
    }
}

/// `before` (all of the buffer) as one step: it is the step's now.
pub fn commit(im: usize, before: [][4]u8) void {
    room();
    const e = &images.list[im];
    hist[hn] = .{ .im = im, .layer = layers.activeOf(e), .x = 0, .y = 0, .w = e.img.w, .h = e.img.h, .iw = e.img.w, .ih = e.img.h, .px = before };
    hn += 1;
    hpos = hn;
    changed();
}

/// A stroke's box (inclusive) out of `before`, all of the buffer before it.
pub fn commitBox(im: usize, layer: i32, before: []const [4]u8, x0: u32, y0: u32, x1: u32, y1: u32) void {
    const e = &images.list[im];
    const w = x1 - x0 + 1;
    const h = y1 - y0 + 1;
    const px = A.alloc([4]u8, @as(usize, w) * h) catch return;
    room();
    const iw: usize = e.img.w;
    for (0..h) |r| {
        const o = (y0 + r) * iw + x0;
        @memcpy(px[r * w..][0..w], before[o..][0..w]);
    }
    hist[hn] = .{ .im = im, .layer = layer, .x = x0, .y = y0, .w = w, .h = h, .iw = e.img.w, .ih = e.img.h, .px = px };
    hn += 1;
    hpos = hn;
    changed();
}

/// Texture strokes and bakes change the file with no scene step.
fn changed() void {
    @import("files.zig").noteChange();
    @import("autosave.zig").note();
}

/// pt_hist_clear: every step forgotten (the images went, the layers changed).
pub fn clear() void {
    while (hn > 0) {
        hn -= 1;
        A.free(hist[hn].px);
    }
    hpos = 0;
}

pub fn steps() usize {
    return hn;
}
pub fn position() usize {
    return hpos;
}
/// What the steps hold, bytes.
pub fn bytes() usize {
    var n: usize = 0;
    for (hist[0..hn]) |*s| n += s.px.len * 4;
    return n;
}

fn swap(s: *const Step) void {
    if (s.im >= images.count) return;
    const e = &images.list[s.im];
    if (e.img.w != s.iw or e.img.h != s.ih) return;
    const buf = layers.buffer(e, s.layer) orelse return;
    const iw: usize = s.iw;
    for (0..s.h) |r| {
        const o = (s.y + r) * iw + s.x;
        for (buf[o..][0..s.w], s.px[r * s.w..][0..s.w]) |*a, *b| std.mem.swap([4]u8, a, b);
    }
    const x1 = s.x + s.w - 1;
    const y1 = s.y + s.h - 1;
    layers.rect(e, s.x, s.y, x1, y1); // (layers: the composite there)
    images.rectChanged(s.im, s.x, s.y, x1, y1);
    @import("material.zig").version +%= 1;
    @import("files.zig").noteChange();
    app.dirty = true;
}

/// do_pt_undo.
pub fn opUndo() void {
    @import("paint.zig").finishStroke(); // (a stroke under way is a step first)
    if (hpos == 0) return app.toast(.warn, "texture paint: nothing to undo", .{});
    hpos -= 1;
    swap(&hist[hpos]);
}

pub fn opRedo() void {
    @import("paint.zig").finishStroke();
    if (hpos >= hn) return app.toast(.warn, "texture paint: nothing to redo", .{});
    swap(&hist[hpos]);
    hpos += 1;
}

const t_ = std.testing;

test "32 steps at most, a new one drops what was undone" {
    defer clear();
    for (0..40) |k| {
        room();
        const px = try A.alloc([4]u8, 1);
        hist[hn] = .{ .im = k, .layer = -1, .x = 0, .y = 0, .w = 1, .h = 1, .iw = 1, .ih = 1, .px = px };
        hn += 1;
        hpos = hn;
    }
    try t_.expectEqual(@as(usize, 32), hn);
    try t_.expectEqual(@as(usize, 8), hist[0].im);
    hpos = 30;
    room();
    try t_.expectEqual(@as(usize, 30), hn);
}
