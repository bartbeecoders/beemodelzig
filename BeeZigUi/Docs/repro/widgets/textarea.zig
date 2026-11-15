const std = @import("std");
const zui = @import("zui");
const testing = std.testing;
const Fixture = @import("fixture.zig").Fixture;
const App = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,
    pub fn frame(app: *App, ui: *zui.Ui) void {
        _ = ui.textArea("Notes", &app.buf, &app.len, .{});
    }
};
test "textarea paste cuts a multi-byte char at 4096 bytes" {
    const f = try Fixture(App).create();
    defer f.destroy();
    try f.frame(0.016);
    var clip: [4097]u8 = undefined;
    @memset(clip[0..4095], 'a');
    clip[4095] = 0xC3;
    clip[4096] = 0xA9; // "é" straddling the 4096 limit
    f.ui.setClipboard(&clip);
    f.ui.setFocus(f.ui.id("Notes"));
    try f.play("key ctrl+v");
    std.debug.print("len={d} valid utf8={}\n", .{ f.app.len, std.unicode.utf8ValidateSlice(f.app.buf[0..f.app.len]) });
    try testing.expect(std.unicode.utf8ValidateSlice(f.app.buf[0..f.app.len]));
}
