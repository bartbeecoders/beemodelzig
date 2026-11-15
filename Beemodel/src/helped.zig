// The Help area (help.s): everything about whatever the pointer last rested
// on: the tooltip's content, kept unless the pointer is over the Help area.
// A Zui part: the text wraps to the area, the shortcut a key chip.
const std = @import("std");
const gfx = @import("gfx.zig");
const host = @import("zuihost.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const cat = @import("catalog.zig");
const ops = @import("ops.zig");

const Rect = gfx.Rect;

var title: [64]u8 = undefined;
var title_len: usize = 0;
var doc: [256]u8 = undefined;
var doc_len: usize = 0;
var why: [96]u8 = undefined;
var why_len: usize = 0;
var key: [40]u8 = undefined;
var key_len: usize = 0;

/// A tooltip shows: keep what it says.
pub fn note(t: []const u8, d: []const u8, w: []const u8) void {
    if (app.hoverEditor() == .help) return;
    title_len = @min(t.len, title.len);
    @memcpy(title[0..title_len], t[0..title_len]);
    doc_len = @min(d.len, doc.len);
    @memcpy(doc[0..doc_len], d[0..doc_len]);
    why_len = @min(w.len, why.len);
    @memcpy(why[0..why_len], w[0..why_len]);
    key_len = 0;
    for (cat.entries, 0..) |e, i| {
        if (!std.mem.eql(u8, e.label, title[0..title_len])) continue;
        const k = ops.keyLabel(i, &key);
        key_len = k.len;
        break;
    }
}

pub fn body(r: Rect) void {
    const th = ui.th;
    const z = host.beginPart("help", 0, r) orelse return;
    defer host.endPart(z);
    z.drawRect(.{ .rect = host.zr(r), .fill = host.col(th.pane_bg) });
    const w: f32 = @floatFromInt(@max(20, r.w - 24));
    z.beginVertical(.{ .padding = 12, .spacing = 6 });
    defer z.endVertical();
    z.pushFont(host.headFont());
    z.label("Help", .{ .color = host.col(th.accent) });
    z.popFont();
    if (title_len == 0) {
        z.wrappedText("Rest the pointer on a button, menu item or field: what it does shows here.", .{ .color = host.col(th.text_dim), .width = w });
        return;
    }
    const tt = title[0..title_len];
    if (key_len > 0) {
        z.richText(&.{ .{ .text = tt }, .{ .text = "  " }, .{ .text = key[0..key_len], .key = true } }, .{ .width = w });
    } else z.label(tt, .{});
    ui.record("help", tt, host.rectOf(z.lastRect()), true);
    if (doc_len > 0) z.wrappedText(doc[0..doc_len], .{ .color = host.col(th.text_dim), .width = w });
    if (why_len > 0) {
        var b: [120]u8 = undefined;
        z.wrappedText(std.fmt.bufPrint(&b, "Not now: {s}", .{why[0..why_len]}) catch "", .{ .color = host.col(th.warn), .width = w });
    }
}
