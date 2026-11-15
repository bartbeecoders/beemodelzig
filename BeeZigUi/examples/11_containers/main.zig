//! Phase 12 demo: tree nodes, collapsing headers, a list view and a sortable
//! table. Windows and popups now cast shadows, and text is kerned.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const File = struct { name: []const u8, kb: u32, kind: []const u8 };

const files = [_]File{
    .{ .name = "AVATAR.png", .kb = 412, .kind = "Image" },
    .{ .name = "build.zig", .kb = 4, .kind = "Zig source" },
    .{ .name = "README.md", .kb = 9, .kind = "Markdown" },
    .{ .name = "Typography.ttf", .kb = 410, .kind = "Font" },
    .{ .name = "main.zig", .kb = 12, .kind = "Zig source" },
    .{ .name = "notes.txt", .kb = 1, .kind = "Text" },
    .{ .name = "WAVE.wav", .kb = 2048, .kind = "Audio" },
    .{ .name = "layout.zig", .kb = 11, .kind = "Zig source" },
    .{ .name = "icon.svg", .kb = 3, .kind = "Image" },
    .{ .name = "data.json", .kb = 77, .kind = "JSON" },
    .{ .name = "LICENSE", .kb = 2, .kind = "Text" },
    .{ .name = "video.mp4", .kb = 90210, .kind = "Video" },
    .{ .name = "style.zig", .kb = 6, .kind = "Zig source" },
    .{ .name = "Yacht.jpg", .kb = 880, .kind = "Image" },
    .{ .name = "todo.md", .kb = 1, .kind = "Markdown" },
};

const SortKey = enum { name, size, kind };

const App = struct {
    order: [files.len]usize = blk: {
        var o: [files.len]usize = undefined;
        for (&o, 0..) |*v, i| v.* = i;
        break :blk o;
    },
    sort_key: SortKey = .name,
    descending: bool = false,
    selected: ?usize = null,
    picked_color: usize = 2,
    show_hidden: bool = false,

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start, .spacing = 24 });

        ui.beginVertical(.{ .width = .px(260) });
        ui.label("Tree", muted);
        if (ui.treeNode("project", .{ .default_open = true })) {
            defer ui.treePop();
            if (ui.treeNode("src", .{ .default_open = true })) {
                defer ui.treePop();
                for ([_][]const u8{ "main.zig", "layout.zig", "style.zig" }) |name| {
                    ui.pushId(name);
                    defer ui.popId();
                    if (ui.selectable(name, app.isSelected(name), .{}).clicked) app.select(name);
                }
            }
            if (ui.treeNode("assets", .{})) {
                defer ui.treePop();
                for ([_][]const u8{ "AVATAR.png", "Yacht.jpg", "icon.svg" }) |name| {
                    ui.pushId(name);
                    defer ui.popId();
                    if (ui.selectable(name, app.isSelected(name), .{}).clicked) app.select(name);
                }
            }
            if (ui.selectable("build.zig", app.isSelected("build.zig"), .{}).clicked) app.select("build.zig");
        }

        ui.spacer(.px(8));
        ui.label("List view", muted);
        ui.beginScrollArea("colors", .{ .height = .px(150), .spacing = 2 });
        const names = [_][]const u8{ "Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Indigo", "Violet", "Pink", "Brown", "Gray", "Black" };
        for (names, 0..) |name, i| {
            ui.pushIdInt(i);
            defer ui.popId();
            if (ui.selectable(name, i == app.picked_color, .{}).clicked) app.picked_color = i;
        }
        ui.endScrollArea();
        ui.labelf("Picked: {s}", .{names[app.picked_color]}, muted);
        ui.endVertical();

        ui.beginVertical(.{ .width = .fill, .height = .fill });
        ui.label("Table (click a header to sort; AVATAR and WAVE show kerning)", muted);
        const columns = [_]zui.TableColumn{
            .{ .name = "Name", .sort = app.arrow(.name) },
            .{ .name = "Size", .width = .px(110), .sort = app.arrow(.size) },
            .{ .name = "Kind", .width = .px(130), .sort = app.arrow(.kind) },
        };
        const table = ui.beginTable("files", &columns, .{ .height = .px(260) });
        if (table.header_clicked) |c| app.sortBy(@enumFromInt(c));
        for (app.order) |i| {
            const f = files[i];
            ui.tableRow();
            if (ui.selectable(f.name, app.isSelected(f.name), .{}).clicked) app.select(f.name);
            ui.tableNextColumn();
            ui.labelf("{d} KB", .{f.kb}, .{});
            ui.tableNextColumn();
            ui.label(f.kind, muted);
        }
        ui.endTable();

        ui.spacer(.px(4));
        if (ui.collapsingHeader("Details", .{ .default_open = true })) {
            if (app.selected) |i| {
                const f = files[i];
                ui.labelf("{s}: {d} KB, {s}", .{ f.name, f.kb, f.kind }, .{});
            } else ui.label("Select a file in the tree or the table.", muted);
        }
        if (ui.collapsingHeader("Advanced", .{})) {
            _ = ui.checkbox("Show hidden files", &app.show_hidden, .{});
            ui.label("Headers remember whether they are open.", muted);
        }
        ui.endVertical();
        ui.endHorizontal();

        if (ui.beginWindow("Shadows", .{ .position = .{ .x = 560, .y = 430 }, .size = .{ .x = 240, .y = 110 } })) {
            defer ui.endWindow();
            ui.label("Windows and popups", .{});
            ui.label("cast a soft shadow.", .{});
        }
    }

    fn isSelected(app: *const App, name: []const u8) bool {
        const i = app.selected orelse return false;
        return std.mem.eql(u8, files[i].name, name);
    }

    fn select(app: *App, name: []const u8) void {
        for (files, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) app.selected = i;
        }
    }

    fn arrow(app: *const App, key: SortKey) zui.SortOrder {
        if (app.sort_key != key) return .none;
        return if (app.descending) .descending else .ascending;
    }

    /// Sorts by `key`; clicking the same column again reverses the order.
    fn sortBy(app: *App, key: SortKey) void {
        app.descending = if (app.sort_key == key) !app.descending else false;
        app.sort_key = key;
        app.applySort();
    }

    /// Puts `order` in the current sort order.
    fn applySort(app: *App) void {
        const key = app.sort_key;
        const Context = struct {
            key: SortKey,
            descending: bool,
            fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const fa = files[a];
                const fb = files[b];
                const less = switch (ctx.key) {
                    .name => std.ascii.lessThanIgnoreCase(fa.name, fb.name),
                    .size => fa.kb < fb.kb,
                    .kind => std.mem.lessThan(u8, fa.kind, fb.kind),
                };
                const greater = switch (ctx.key) {
                    .name => std.ascii.lessThanIgnoreCase(fb.name, fa.name),
                    .size => fb.kb < fa.kb,
                    .kind => std.mem.lessThan(u8, fb.kind, fa.kind),
                };
                return if (ctx.descending) greater else less;
            }
        };
        std.mem.sort(usize, &app.order, Context{ .key = key, .descending = app.descending }, Context.lessThan);
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    app.applySort();
    try harness.runUi(init, .{ .title = "Zui 11: containers", .width = 840, .height = 580 }, &app);
}
