// Scene thumbnails, as the original's thumb.s: a small picture of the 3D
// viewport, kept in .bee files so that a scene can be recognised without
// opening it.
//     THMB  u32 width, u32 height, BGRX u32 pixels
// It is the first chunk, so a reader needs only the start of the file. Saving
// draws the viewport off screen (no dialog or menu over it), crops it to 16:10
// from the middle and box-filters it to 192 x 120. A viewport smaller than
// that, or no viewport, gives no chunk. Rendered shading is drawn as Material
// Preview: a thumbnail does not wait for samples.
const std = @import("std");
const gfx = @import("gfx.zig");
const app = @import("app.zig");
const ui = @import("ui.zig");
const vp = @import("viewport.zig");
const editors = @import("editors.zig");

pub const TW = 192;
pub const TH = 120;
const BEE_MAGIC: u32 = 0x4d454542;
const TAG_THMB: u32 = 0x424d4854;
const A = std.heap.page_allocator;

var px: [TW * TH]u32 = undefined;

/// src (sw x sh pixels, whole) to TW x TH: 16:10 from the middle, each target
/// pixel the average of its block. False: too small.
pub fn filter(src: []const u32, sw0: u32, sh0: u32, out: *[TW * TH]u32) bool {
    var sx: u32 = 0;
    var sy: u32 = 0;
    var sw = sw0;
    var sh = sh0;
    if (sw * TH > sh * TW) {
        const n = sh * TW / TH; // too wide: narrower
        sx = (sw - n) / 2;
        sw = n;
    } else {
        const n = sw * TH / TW; // too tall: shorter
        sy = (sh - n) / 2;
        sh = n;
    }
    if (sw < TW or sh < TH) return false;
    for (0..TH) |ty| {
        const y0 = ty * sh / TH + sy;
        const y1 = (ty + 1) * sh / TH + sy;
        for (0..TW) |tx| {
            const x0 = tx * sw / TW + sx;
            const x1 = (tx + 1) * sw / TW + sx;
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var n: u32 = 0;
            for (y0..y1) |y| {
                for (x0..x1) |x| {
                    const p = src[y * sw0 + x];
                    b += p & 255;
                    g += (p >> 8) & 255;
                    r += (p >> 16) & 255;
                    n += 1;
                }
            }
            if (n > 0) out[ty * TW + tx] = 0xff000000 | (r / n) << 16 | (g / n) << 8 | (b / n);
        }
    }
    return true;
}

/// The picture from the active 3D viewport, or false.
fn make() bool {
    if (app.winW() == 0) return false;
    const a = app.viewportArea();
    if (a < 0) return false;
    const n = app.N(a);
    const r = editors.bodyRect(n.rect);
    if (r.w < TW or r.h < TH) return false;
    const w: usize = @intCast(r.w);
    const h: usize = @intCast(r.h);
    const buf = A.alloc(u32, w * h) catch return false;
    defer A.free(buf);
    const z = A.alloc(f32, w * h) catch return false;
    defer A.free(z);
    const ids = A.alloc(u16, w * h) catch return false;
    defer A.free(ids);
    @memset(ids, 0);
    var cv = gfx.Canvas{ .px = buf.ptr, .w = r.w, .h = r.h, .clip = .{ .w = r.w, .h = r.h }, .zbuf = z.ptr, .ids = ids.ptr, .uw = r.w, .uh = r.h };
    var v = n.view;
    if (v.rendered) {
        v.rendered = false;
        v.material = true;
    }
    // (the viewports' cache and the live view belong to the window)
    const was = vp.cache_enabled;
    const area = vp.draw_area;
    vp.cache_enabled = false;
    vp.draw_area = -1;
    vp.render(&cv, .{ .w = r.w, .h = r.h }, &v, ui.th);
    vp.cache_enabled = was;
    vp.draw_area = area;
    return filter(buf, @intCast(w), @intCast(h), &px);
}

/// bee.zig, right after the header: the chunk, when there is a picture.
pub fn writeChunk(b: anytype) void {
    if (!make()) return;
    b.u32_(TAG_THMB);
    b.u32_(8 + TW * TH * 4);
    b.u32_(TW);
    b.u32_(TH);
    b.bytes(std.mem.sliceAsBytes(&px));
}

/// A file's picture (its first bytes alone), as thumb_read; anything else: false.
pub fn read(path: []const u8, out: *[TW * TH]u32) bool {
    const linux = std.os.linux;
    var pb: [600]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pb, "{s}", .{path}, 0) catch return false;
    const rc = linux.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var h: [6]u32 = undefined;
    if (!readAll(fd, std.mem.sliceAsBytes(&h))) return false;
    if (!headerOk(&h)) return false;
    return readAll(fd, std.mem.sliceAsBytes(out));
}

fn headerOk(h: *const [6]u32) bool {
    return h[0] == BEE_MAGIC and h[2] == TAG_THMB and h[3] == 8 + TW * TH * 4 and h[4] == TW and h[5] == TH;
}

fn readAll(fd: i32, b: []u8) bool {
    const linux = std.os.linux;
    var o: usize = 0;
    while (o < b.len) {
        const n = linux.read(fd, b[o..].ptr, b.len - o);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        o += n;
    }
    return true;
}

test "a flat picture stays flat, a split one stays split" {
    const w = 640;
    const h = 400;
    const src = try std.testing.allocator.alloc(u32, w * h);
    defer std.testing.allocator.free(src);
    for (src, 0..) |*p, i| p.* = if (i % w < w / 2) 0x204060 else 0xa0c0e0;
    var out: [TW * TH]u32 = undefined;
    try std.testing.expect(filter(src, w, h, &out));
    try std.testing.expectEqual(@as(u32, 0xff204060), out[0]);
    try std.testing.expectEqual(@as(u32, 0xffa0c0e0), out[TW - 1]);
    try std.testing.expectEqual(@as(u32, 0xff204060), out[TW * TH - TW]);
}

test "the middle of a wide picture, and none from a small one" {
    const w = 1000;
    const h = 200;
    const src = try std.testing.allocator.alloc(u32, w * h);
    defer std.testing.allocator.free(src);
    // (black at the sides that go, the crop is the white middle 320)
    for (src, 0..) |*p, i| p.* = if (i % w >= 340 and i % w < 660) 0xffffff else 0;
    var out: [TW * TH]u32 = undefined;
    try std.testing.expect(filter(src, w, h, &out));
    try std.testing.expectEqual(@as(u32, 0xffffffff), out[0]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), out[TW * TH - 1]);
    try std.testing.expect(!filter(src, 100, 100, &out));
    try std.testing.expect(!filter(src, 1000, 60, &out));
}

test "a header that is not one" {
    var h = [6]u32{ BEE_MAGIC, 1, TAG_THMB, 8 + TW * TH * 4, TW, TH };
    try std.testing.expect(headerOk(&h));
    h[4] = 1000000;
    try std.testing.expect(!headerOk(&h));
    h[4] = TW;
    h[3] = 8;
    try std.testing.expect(!headerOk(&h));
}
