const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

pub fn Fixture(comptime App: type) type {
    return struct {
        const F = @This();
        font: zui.Font,
        ui: zui.Ui,
        app: App = .{},

        pub fn create() !*F {
            const f = try testing.allocator.create(F);
            f.* = .{ .font = try .initDefault(testing.allocator), .ui = undefined };
            f.ui = .init(testing.allocator, .{ .font = &f.font });
            return f;
        }
        pub fn destroy(f: *F) void {
            f.ui.deinit();
            f.font.deinit();
            testing.allocator.destroy(f);
        }
        pub fn frame(f: *F, dt: f32) !void {
            f.ui.beginFrame(.{ .width = 700, .height = 600, .dt = dt });
            f.app.frame(&f.ui);
            _ = try f.ui.endFrame();
        }
        pub fn play(f: *F, script: []const u8) !void {
            var player: zui.ScriptPlayer = try .init(testing.allocator, script);
            defer player.deinit();
            while (player.next(&f.ui) catch |err| {
                std.debug.print("{s}\n", .{player.message()});
                return err;
            }) |step| switch (step) {
                .frame => |dt| try f.frame(dt),
                .shot => {},
            };
        }
    };
}
