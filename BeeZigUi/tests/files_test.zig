//! The file browser add-on, on a fake file tree.

const std = @import("std");
const zui = @import("zui");
const files = @import("zui_files");
const software = @import("zui_software");
const testing = std.testing;

/// A fixed tree: path, folder or not, size, time.
const Fake = struct {
    const Item = struct { path: []const u8, dir: bool = false, size: u64 = 100, mtime: i64 = 1_700_000_000 };
    items: []const Item,
    png: []const u8 = "",

    fn source(self: *Fake) files.Source {
        return .{ .context = self, .listFn = list, .readFn = read, .existsFn = exists };
    }

    fn list(context: *anyopaque, path: []const u8, out: files.Listing) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        var found = std.mem.eql(u8, path, "/");
        for (self.items) |it| {
            if (std.mem.eql(u8, it.path, path)) found = true;
            const parent = std.fs.path.dirname(it.path) orelse continue;
            if (std.mem.eql(u8, parent, path)) try out.add(std.fs.path.basename(it.path), it.dir, it.size, it.mtime);
        }
        if (!found) return error.FileNotFound;
    }

    fn read(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8, limit: usize) anyerror![]u8 {
        const self: *Fake = @ptrCast(@alignCast(context));
        _ = limit;
        if (std.mem.endsWith(u8, path, ".png")) return gpa.dupe(u8, self.png);
        return error.FileNotFound;
    }

    fn exists(context: *anyopaque, path: []const u8) bool {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, path, "/")) return true;
        for (self.items) |it| if (std.mem.eql(u8, it.path, path)) return true;
        return false;
    }
};

const tree = [_]Fake.Item{
    .{ .path = "/home", .dir = true },
    .{ .path = "/home/me", .dir = true },
    .{ .path = "/home/me/models", .dir = true },
    .{ .path = "/home/me/models/chair.bee", .size = 50_000 },
    .{ .path = "/home/me/models/table.bee", .size = 20_000 },
    .{ .path = "/home/me/textures", .dir = true },
    .{ .path = "/home/me/textures/brick2.png", .size = 300, .mtime = 1_600_000_000 },
    .{ .path = "/home/me/textures/brick10.png", .size = 100 },
    .{ .path = "/home/me/textures/notes.txt", .size = 10 },
    .{ .path = "/home/me/textures/.cache", .dir = true },
    .{ .path = "/home/me/scene.bee", .size = 900_000 },
};

const App = struct {
    browser: files.Browser,
    mode: files.Mode = .open,
    result: files.Result = .none,
    chosen: [2][256]u8 = undefined,
    chosen_len: [2]usize = .{ 0, 0 },
    count: usize = 0,
    cancelled: bool = false,

    fn frame(app: *App, ui: *zui.Ui) void {
        const r = files.fileBrowser(ui, "browser", &app.browser, .{
            .mode = app.mode,
            .multiple = true,
            .kinds = &.{ .{ .name = "Images", .extensions = &.{".png"} }, .{ .name = "Scenes", .extensions = &.{".bee"} } },
            .places = &.{ .{ .name = "Home", .path = "/home/me", .icon = .{ .builtin = .home } }, .{ .name = "Models", .path = "/home/me/models" } },
            .recent = &.{"/home/me/textures"},
        });
        switch (r) {
            .chosen => |paths| {
                app.count = paths.len;
                for (paths[0..@min(2, paths.len)], 0..) |p, i| {
                    @memcpy(app.chosen[i][0..p.len], p);
                    app.chosen_len[i] = p.len;
                }
            },
            .cancelled => app.cancelled = true,
            .none => {},
        }
    }

    fn first(app: *const App) []const u8 {
        return app.chosen[0][0..app.chosen_len[0]];
    }
};

const Fixture = struct {
    font: zui.Font,
    ui: zui.Ui,
    fake: Fake,
    app: App,

    fn create(mode: files.Mode, start: []const u8) !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .font = try .initDefault(testing.allocator), .ui = undefined, .fake = .{ .items = &tree }, .app = undefined };
        f.ui = .init(testing.allocator, .{ .font = &f.font });
        f.ui.recording = true;
        f.app = .{ .browser = try .init(testing.allocator, f.fake.source(), start), .mode = mode };
        return f;
    }

    fn destroy(f: *Fixture) void {
        f.app.browser.deinit();
        f.ui.deinit();
        f.font.deinit();
        testing.allocator.destroy(f);
    }

    fn frame(f: *Fixture) !void {
        f.ui.beginFrame(.{ .width = 1000, .height = 640, .dt = 0.016 });
        f.app.frame(&f.ui);
        _ = try f.ui.endFrame();
    }

    fn play(f: *Fixture, script: []const u8) !void {
        var player: zui.ScriptPlayer = try .init(testing.allocator, script);
        defer player.deinit();
        while (player.next(&f.ui) catch |err| {
            std.debug.print("{s}\n", .{player.message()});
            return err;
        }) |step| switch (step) {
            .frame => try f.frame(),
            .shot => {},
        };
    }

    fn rowNames(f: *Fixture, out: [][]const u8) [][]const u8 {
        const b = &f.app.browser;
        const n = @min(out.len, b.rows.items.len);
        for (0..n) |i| out[i] = b.nameOf(b.rowEntry(i));
        return out[0..n];
    }
};

test "folders first, natural order, only the kind asked for, hidden files" {
    const f = try Fixture.create(.open, "/home/me/textures");
    defer f.destroy();
    try f.play("frames 2");
    var names: [8][]const u8 = undefined;
    // Images only: the text file is left out, the hidden folder too.
    const shown = f.rowNames(&names);
    try testing.expectEqual(@as(usize, 2), shown.len);
    try testing.expectEqualStrings("brick2.png", shown[0]);
    try testing.expectEqualStrings("brick10.png", shown[1]);
    try f.play(
        \\key ctrl+h
        \\click dropdown:kind
        \\click choice:All files
    );
    const all = f.rowNames(&names);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqualStrings(".cache", all[0]);
    // Sort by size, then reverse it.
    try f.play("click button:Size");
    try testing.expectEqualStrings("notes.txt", f.rowNames(&names)[1]);
    try f.play("click button:Size \u{25B2}");
    try testing.expectEqualStrings("brick2.png", f.rowNames(&names)[1]);
    try f.play(
        \\click text_input:filter
        \\type brick1
    );
    try testing.expectEqual(@as(usize, 1), f.rowNames(&names).len);
}

test "crumbs, back, forward, up, places; Enter opens a folder" {
    const f = try Fixture.create(.open, "/home/me");
    defer f.destroy();
    try f.play(
        \\click dropdown:kind
        \\click choice:All files
        \\double-click row:models
        \\expect row:chair.bee exists
        \\click button:home
        \\expect row:me exists
        \\key alt+left
        \\expect row:chair.bee exists
        \\key alt+right
        \\expect row:me exists
        \\click selectable:Models
        \\expect row:table.bee exists
        \\key backspace
        \\expect row:scene.bee exists
        \\click selectable:textures
        \\expect row:brick2.png exists
    );
    try testing.expectEqualStrings("/home/me/textures", f.app.browser.dir.items);
}

test "the path field: Tab completes, Enter goes there" {
    const f = try Fixture.create(.open, "/home/me");
    defer f.destroy();
    try f.play(
        \\key ctrl+l
        \\key ctrl+a
        \\type /home/me/tex
        \\key tab
        \\expect text_input:Path = /home/me/textures/
        \\key enter
        \\expect row:brick2.png exists
    );
    try f.play(
        \\key ctrl+l
        \\key ctrl+a
        \\type /nowhere
        \\key enter
    );
    try testing.expect(std.mem.indexOf(u8, f.app.browser.message[0..f.app.browser.message_len], "No such folder") != null);
}

test "the path field: a path without a leading / goes from the folder shown (improvements L21)" {
    const f = try Fixture.create(.open, "/home/me");
    defer f.destroy();
    try f.play(
        \\key ctrl+l
        \\key ctrl+a
        \\type textures
        \\key enter
    );
    try testing.expectEqualStrings("/home/me/textures", f.app.browser.dir.items);
    try f.play(
        \\key ctrl+l
        \\key ctrl+a
        \\type ../models/./
        \\key enter
    );
    try testing.expectEqualStrings("/home/me/models", f.app.browser.dir.items);
}

test "open: double-click a file, or select several and Open" {
    const f = try Fixture.create(.open, "/home/me/models");
    defer f.destroy();
    try f.play(
        \\click dropdown:kind
        \\click choice:Scenes
        \\expect button:Open disabled
        \\double-click row:table.bee
    );
    try testing.expectEqualStrings("/home/me/models/table.bee", f.app.first());
    try f.play(
        \\click row:chair.bee
        \\key shift+down
        \\click button:Open
    );
    try testing.expectEqual(@as(usize, 2), f.app.count);
    try f.play("click button:Cancel");
    try testing.expect(f.app.cancelled);
}

test "save: a name gets the kind's extension; an existing file asks first" {
    const f = try Fixture.create(.save, "/home/me/models");
    defer f.destroy();
    try f.play(
        \\click dropdown:kind
        \\click choice:Scenes
        \\click text_input:File name
        \\type stool
        \\key enter
    );
    try testing.expectEqualStrings("/home/me/models/stool.bee", f.app.first());
    f.app.chosen_len[0] = 0;
    try f.play(
        \\click row:chair.bee
        \\expect text_input:File name = chair.bee
        \\click button:Save
        \\expect button:Replace exists
    );
    try testing.expectEqual(@as(usize, 0), f.app.chosen_len[0]);
    try f.play("click button:Replace");
    try testing.expectEqualStrings("/home/me/models/chair.bee", f.app.first());
}

test "a PNG written by Zui decodes back, and shows in the preview" {
    const w = 5;
    const h = 3;
    var pixels: [w * h]u32 = undefined;
    for (&pixels, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @intCast(i * 17)) << 16 | @as(u32, @intCast(255 - i * 9)) << 8 | @as(u32, @intCast(i * 3));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try software.png.write(&out.writer, &pixels, w, h);
    const img = try files.decodePng(testing.allocator, out.written());
    defer testing.allocator.free(img.pixels);
    try testing.expectEqual(@as(u32, w), img.width);
    try testing.expectEqualSlices(u32, &pixels, img.pixels);
    try testing.expectError(error.NotPng, files.decodePng(testing.allocator, "not a png at all, nope, not at all"));

    const f = try Fixture.create(.open, "/home/me/textures");
    defer f.destroy();
    f.fake.png = out.written();
    try f.play(
        \\click row:brick2.png
        \\expect custom:preview = brick2.png
        \\expect label:5 × 3 exists
    );
}
