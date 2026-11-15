//! Integration tests that exercise the public API.

test {
    _ = @import("ui_test.zig");
    _ = @import("script_test.zig");
    _ = @import("values_test.zig");
    _ = @import("menus_test.zig");
    _ = @import("dock_test.zig");
    _ = @import("feedback_test.zig");
    _ = @import("lists_test.zig");
    _ = @import("text_test.zig");
    _ = @import("colour_test.zig");
    _ = @import("pie_test.zig");
    _ = @import("views_test.zig");
    _ = @import("nodes_test.zig");
    _ = @import("files_test.zig");
    _ = @import("native_test.zig");
    _ = @import("regress_test.zig");
}
