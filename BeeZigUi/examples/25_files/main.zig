//! Phase 25 demo: BeeModel's Open, Save As and Export with zui_files.
//!
//! Starts in examples/25_files/sample when run from the project root,
//! else in your home folder. Try: double-click folders, the crumbs, Back /
//! Forward / Up (Alt+Left, Alt+Right, Backspace); Ctrl+L and Tab to type a
//! path; click the column titles; type in the filter; Ctrl+H for hidden
//! files; pick a PNG for its preview or a .bee for the app's thumbnail.
//! Save over an existing file to be asked first; Export has its own
//! options.

const std = @import("std");
const zui = @import("zui");
const files = @import("zui_files");
const harness = @import("harness");

const scenes = files.Kind{ .name = "BeeModel scenes", .extensions = &.{".bee"} };
const images = files.Kind{ .name = "Images", .extensions = &.{ ".png", ".jpg" } };
const gltf = files.Kind{ .name = "glTF", .extensions = &.{ ".glb", ".gltf" } };

const Task = enum { open, save, export_, folder };

const App = struct {
    disk: files.DiskSource,
    browser: files.Browser = undefined,
    task: usize = 0,
    showing: bool = false,
    last: [512]u8 = undefined,
    last_len: usize = 0,
    recent: [4][]const u8 = undefined,
    recent_len: usize = 0,
    recent_store: [4][512]u8 = undefined,
    places: [5]files.Place = undefined,
    place_paths: [5][512]u8 = undefined,
    drives: [1]files.Place = undefined,
    start: [512]u8 = undefined,
    start_len: usize = 0,
    // Export options.
    apply_modifiers: bool = true,
    selected_only: bool = false,
    scale: f64 = 1,
    format: usize = 0,
    /// The app's thumbnail for .bee files: a little picture.
    thumb_pixels: [48 * 32]u32 = undefined,
    thumb: zui.Image = undefined,

    fn init(app: *App, init_: std.process.Init) !void {
        app.* = .{ .disk = .{ .io = init_.io } };
        const home = init_.environ_map.get("HOME") orelse "/";
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init_.io, ".", init_.gpa);
        defer init_.gpa.free(cwd);
        const sample = try std.fmt.bufPrint(&app.start, "{s}/examples/25_files/sample", .{cwd});
        app.start_len = if (app.disk.source().existsFn(&app.disk, sample)) sample.len else (try std.fmt.bufPrint(&app.start, "{s}", .{home})).len;
        const names = [_][]const u8{ "Home", "Desktop", "Documents", "Downloads", "Pictures" };
        const icons = [_]zui.Icon{ .{ .builtin = .home }, .{ .builtin = .folder }, .{ .builtin = .file }, .{ .builtin = .arrow_down }, .{ .builtin = .image } };
        for (names, 0..) |n, i| {
            const p = if (i == 0) try std.fmt.bufPrint(&app.place_paths[i], "{s}", .{home}) else try std.fmt.bufPrint(&app.place_paths[i], "{s}/{s}", .{ home, n });
            app.places[i] = .{ .name = n, .path = p, .icon = icons[i] };
        }
        const space = files.freeSpace("/");
        app.drives[0] = .{ .name = "System (/)", .path = "/", .icon = .{ .builtin = .drive }, .free = if (space) |s| s.free else null, .total = if (space) |s| s.total else null };
        app.browser = try .init(init_.gpa, app.disk.source(), app.start[0..app.start_len]);
        for (0..32) |y| for (0..48) |x| {
            const on = (x / 6 + y / 6) % 2 == 0;
            app.thumb_pixels[y * 48 + x] = if (on) 0xFFE0B040 else 0xFF2A2C31;
        };
        app.thumb = .initArgb(&app.thumb_pixels, 48, 32);
    }

    fn thumbnail(context: ?*anyopaque, path: []const u8) ?*const zui.Image {
        const app: *App = @ptrCast(@alignCast(context.?));
        return if (std.mem.endsWith(u8, path, ".bee")) &app.thumb else null;
    }

    fn exportPanel(context: ?*anyopaque, ui: *zui.Ui) void {
        const app: *App = @ptrCast(@alignCast(context.?));
        _ = ui.checkbox("Apply modifiers", &app.apply_modifiers, .{});
        _ = ui.checkbox("Selected only", &app.selected_only, .{});
        _ = ui.numberField("Scale", &app.scale, .{ .width = .fill, .min = 0.001, .step = 0.1 });
        _ = ui.dropdown("##Format", &app.format, &.{ .{ .label = "Binary (.glb)" }, .{ .label = "Separate (.gltf)" } }, .{ .width = .fill });
    }

    fn remember(app: *App, dir: []const u8) void {
        for (app.recent[0..app.recent_len]) |r| if (std.mem.eql(u8, r, dir)) return;
        const n = @min(app.recent_len, app.recent.len - 1);
        var i = n;
        while (i > 0) : (i -= 1) {
            app.recent_store[i] = app.recent_store[i - 1];
            app.recent[i] = app.recent_store[i][0..app.recent[i - 1].len];
        }
        const len = @min(dir.len, 512);
        @memcpy(app.recent_store[0][0..len], dir[0..len]);
        app.recent[0] = app.recent_store[0][0..len];
        app.recent_len = n + 1;
    }

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const colors = ui.style.colors;
        ui.beginHorizontal(.{});
        _ = ui.segmented("Task", &app.task, &.{ .{ .label = "Open" }, .{ .label = "Save As" }, .{ .label = "Export glTF" }, .{ .label = "Choose Folder" } }, .{});
        ui.spacer(.fill);
        ui.label(app.last[0..app.last_len], .{ .color = colors.text_muted });
        ui.endHorizontal();

        const task: Task = @enumFromInt(app.task);
        const options: files.Options = .{
            .mode = switch (task) {
                .open => .open,
                .save, .export_ => .save,
                .folder => .folder,
            },
            .kinds = switch (task) {
                .open => &.{ scenes, images },
                .save => &.{scenes},
                .export_ => &.{gltf},
                .folder => &.{},
            },
            .multiple = task == .open,
            .places = &app.places,
            .favourites = &.{.{ .name = "Sample files", .path = app.start[0..app.start_len], .icon = .{ .builtin = .star } }},
            .drives = &app.drives,
            .recent = app.recent[0..app.recent_len],
            .thumbnails = .{ .context = app, .get = thumbnail },
            .panel = if (task == .export_) .{ .title = "Export Settings", .context = app, .draw = exportPanel } else null,
            .confirm = if (task == .export_) "Export" else null,
        };
        switch (files.fileBrowser(ui, "browser", &app.browser, options)) {
            .chosen => |paths| {
                app.remember(app.browser.dir.items);
                const text: []const u8 = if (paths.len == 1)
                    std.fmt.bufPrint(&app.last, "Chose {s}", .{paths[0]}) catch ""
                else
                    std.fmt.bufPrint(&app.last, "Chose {d} files", .{paths.len}) catch "";
                app.last_len = text.len;
            },
            .cancelled => {
                const text: []const u8 = std.fmt.bufPrint(&app.last, "Cancelled", .{}) catch "";
                app.last_len = text.len;
            },
            .none => {},
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = undefined;
    try app.init(init);
    defer app.browser.deinit();
    try harness.runUi(init, .{ .title = "Zui 25: files", .width = 1100, .height = 700 }, &app);
}
