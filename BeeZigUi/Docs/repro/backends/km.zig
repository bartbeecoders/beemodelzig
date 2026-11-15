const std = @import("std");
const zui = @import("zui");
const km_mod = @import("km");
test "keymaps" {
    inline for (.{ "us.xkb", "us_de.xkb", "fr.xkb" }) |name| {
        const text = @embedFile(name);
        var km: km_mod.Keymap = .{};
        const ok = km.parse(text);
        // evdev 16 = Q (us) / A (fr), 30 = A (us) / Q (fr)
        std.debug.print("{s}: ok={} char16={u} char30={u} key16={?} key30={?} char2={u}\n", .{ name, ok, @as(u21, @intCast(km.char(16, 0))), @as(u21, @intCast(km.char(30, 0))), km.key(16), km.key(30), @as(u21, @intCast(km.char(2,0))) });
    }
}
