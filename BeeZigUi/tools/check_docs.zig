//! Fails if a public declaration has no doc comment.
//!
//!     zig build check-docs
//!
//! Every `pub fn`, `pub const` and `pub var` in the given directories needs a
//! `///` comment directly above it. Plain re-exports such as
//! `pub const Vec2 = draw.Vec2;` are exempt: their docs live at the original.
//! Declarations inside `test` blocks and in `//!`-less test files don't
//! count, since nothing in a test is public API.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var missing: usize = 0;
    var checked: usize = 0;
    for (args[1..]) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const source = try dir.readFileAlloc(io, entry.path, arena, .limited(16 * 1024 * 1024));
            const found = check(root, entry.path, source, &checked);
            missing += found;
        }
    }

    if (missing > 0) {
        std.debug.print("{d} of {d} public declarations have no doc comment.\n", .{ missing, checked });
        std.process.exit(1);
    }
    std.debug.print("All {d} public declarations are documented.\n", .{checked});
}

/// Prints each undocumented declaration in `source` and returns how many.
fn check(root: []const u8, path: []const u8, source: []const u8, checked: *usize) usize {
    var missing: usize = 0;
    var previous: []const u8 = "";
    var line_number: usize = 0;
    var test_depth: ?usize = null;
    var depth: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        defer previous = line;

        if (test_depth == null and std.mem.startsWith(u8, line, "test ")) test_depth = depth;
        defer {
            depth = updateDepth(depth, line);
            if (test_depth) |d| {
                if (depth <= d and !std.mem.startsWith(u8, line, "test ")) test_depth = null;
            }
        }
        if (test_depth != null) continue;
        if (!isPublicDecl(line) or isReexport(line)) continue;

        checked.* += 1;
        if (!std.mem.startsWith(u8, previous, "///")) {
            missing += 1;
            std.debug.print("{s}/{s}:{d}: {s}\n", .{ root, path, line_number, line });
        }
    }
    return missing;
}

fn isPublicDecl(line: []const u8) bool {
    const prefixes = [_][]const u8{ "pub fn ", "pub const ", "pub var ", "pub inline fn ", "pub extern " };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line, p)) return true;
    }
    return false;
}

/// `pub const name = some.path;` or `pub const name = @import("...");`
fn isReexport(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "pub const ")) return false;
    const eq = std.mem.indexOf(u8, line, " = ") orelse return false;
    const value = std.mem.trimEnd(u8, line[eq + 3 ..], " ");
    if (!std.mem.endsWith(u8, value, ";")) return false;
    const expr = value[0 .. value.len - 1];
    if (std.mem.startsWith(u8, expr, "@import(")) return true;
    for (expr) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return false;
    }
    return std.mem.indexOfScalar(u8, expr, '.') != null;
}

/// Tracks brace nesting, ignoring braces in strings and comments.
fn updateDepth(depth: usize, line: []const u8) usize {
    var d = depth;
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '\'' => i += if (i + 2 < line.len and line[i + 1] == '\\') 3 else 2,
            '/' => if (i + 1 < line.len and line[i + 1] == '/') break,
            '{' => d += 1,
            '}' => d -|= 1,
            else => {},
        }
    }
    return d;
}

test "re-exports are recognised" {
    try std.testing.expect(isReexport("pub const Vec2 = draw.Vec2;"));
    try std.testing.expect(isReexport("pub const zui = @import(\"zui\");"));
    try std.testing.expect(!isReexport("pub const max = 64;"));
    try std.testing.expect(!isReexport("pub const Options = struct {"));
}
