const std = @import("std");
const zui = @import("zui");
test "shift+click after the list shrank" {
    var big: [10]bool = @splat(false);
    var st: zui.ListState = .{};
    st.click(&big, 9, .{});
    var small: [5]bool = @splat(false);
    st.click(&small, 2, .{ .shift = true });
}
