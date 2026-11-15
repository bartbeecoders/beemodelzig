//! Phase 19 demo: BeeModel's outliner and asset browser.
//!
//! Try: click, Ctrl+click and Shift+click rows; arrows, Shift+arrows,
//! Ctrl+A; double-click or F2 to rename; the arrows fold; drag a row onto
//! another to parent it (onto its own child is refused), or below the rows
//! to free it; drag an asset tile into the viewport; drop a file from your
//! file manager on the viewport; Shift+wheel over the strip at the bottom.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const max = 2048;

const Obj = struct {
    name: [32]u8 = undefined,
    len: usize = 0,
    parent: ?u32 = null,
    open: bool = false,
    visible: bool = true,
    locked: bool = false,
    folder: bool = false,

    fn label(o: *const Obj) []const u8 {
        return o.name[0..o.len];
    }
};

const Thumbs = struct {
    pixels: [24][48 * 48]u32 = undefined,
    images: [24]zui.Image = undefined,

    fn build(t: *Thumbs) void {
        for (0..24) |k| {
            const hue: f32 = @as(f32, @floatFromInt(k)) / 24;
            for (0..48) |y| for (0..48) |x| {
                const fx: f32 = @as(f32, @floatFromInt(x)) / 47;
                const fy: f32 = @as(f32, @floatFromInt(y)) / 47;
                const v = 0.5 + 0.5 * @sin((fx + hue) * 9 + fy * 5);
                const r: u32 = @intFromFloat(255 * (0.3 + 0.7 * hue) * v);
                const g: u32 = @intFromFloat(255 * (1 - hue) * (0.4 + 0.6 * fy));
                const b: u32 = @intFromFloat(200 * fx + 40);
                t.pixels[k][y * 48 + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
            };
            t.images[k] = .initArgb(&t.pixels[k], 48, 48);
            t.images[k].is_opaque = true;
        }
    }
};

const App = struct {
    objs: [max]Obj = undefined,
    count: usize = 0,
    order: [max]u32 = undefined,
    depth: [max]u32 = undefined,
    shown: usize = 0,
    selected: [max]bool = @splat(false),
    state: zui.ListState = .{},
    asset_selected: [24]bool = @splat(false),
    asset_state: zui.ListState = .{},
    thumbs: Thumbs = .{},
    placed: [16][24]u8 = undefined,
    placed_len: [16]usize = @splat(0),
    placed_count: usize = 0,
    message: [160]u8 = undefined,
    message_len: usize = 0,

    fn add(app: *App, name: []const u8, parent: ?u32, folder: bool) u32 {
        const i: u32 = @intCast(app.count);
        app.objs[i] = .{ .parent = parent, .folder = folder, .open = folder and parent == null };
        app.objs[i].len = @min(name.len, 32);
        @memcpy(app.objs[i].name[0..app.objs[i].len], name[0..app.objs[i].len]);
        app.count += 1;
        return i;
    }

    fn build(app: *App) void {
        _ = app.add("Camera", null, false);
        _ = app.add("Sun", null, false);
        const props = app.add("Props", null, true);
        const chair = app.add("Chair", props, false);
        for (1..5) |k| {
            var b: [16]u8 = undefined;
            _ = app.add(std.fmt.bufPrint(&b, "Leg {d}", .{k}) catch "Leg", chair, false);
        }
        _ = app.add("Table", props, false);
        const scatter = app.add("Scattered rocks", null, true);
        while (app.count < max) {
            var b: [24]u8 = undefined;
            _ = app.add(std.fmt.bufPrint(&b, "Rock.{d:0>4}", .{app.count}) catch "Rock", scatter, false);
        }
        app.objs[scatter].open = false;
    }

    fn say(app: *App, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&app.message, fmt, args) catch "";
        app.message_len = text.len;
    }

    fn flatten(app: *App, parent: ?u32, d: u32) void {
        for (app.objs[0..app.count], 0..) |o, i| {
            if (o.parent != parent) continue;
            app.order[app.shown] = @intCast(i);
            app.depth[app.shown] = d;
            app.shown += 1;
            if (o.open) app.flatten(@intCast(i), d + 1);
        }
    }

    fn children(app: *const App, i: u32) bool {
        for (app.objs[0..app.count]) |o| if (o.parent == i) return true;
        return false;
    }

    fn isAncestor(app: *const App, a: u32, of: u32) bool {
        var p = app.objs[of].parent;
        while (p) |x| : (p = app.objs[x].parent) if (x == a) return true;
        return false;
    }

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const colors = ui.style.colors;
        app.shown = 0;
        app.flatten(null, 0);

        ui.beginHorizontal(.{ .height = .fill, .alignment = .start, .spacing = 12 });
        // The outliner.
        ui.beginVertical(.{ .width = .px(330), .height = .fill });
        ui.labelf("Outliner: {d} objects", .{app.count}, .{ .color = colors.text_muted });
        var list = ui.beginList("outliner", app.selected[0..app.shown], &app.state, .{});
        for (list.first..list.end) |row| {
            const i = app.order[row];
            const o = &app.objs[i];
            ui.beginRow(&list, row, .{
                .label = o.label(),
                .depth = app.depth[row],
                .fold = if (app.children(i)) o.open else null,
                .icon = .{ .builtin = if (o.folder) .menu else .dot },
                .renamable = true,
            });
            var b: [48]u8 = undefined;
            _ = ui.iconToggle(std.fmt.bufPrint(&b, "{s} locked", .{o.label()}) catch "lock", &o.locked, .{ .on = .{ .builtin = .lock }, .off = .{ .builtin = .unlock }, .size = list.row_h });
            _ = ui.iconToggle(std.fmt.bufPrint(&b, "{s} visible", .{o.label()}) catch "eye", &o.visible, .{ .on = .{ .builtin = .eye }, .off = .{ .builtin = .eye_off }, .size = list.row_h });
            const r = ui.endRow(&list);
            if (r.fold_clicked) o.open = !o.open;
            if (r.renamed) |name| {
                o.len = @min(name.len, 32);
                @memcpy(o.name[0..o.len], name[0..o.len]);
            }
            _ = ui.dragSource(r.interaction, .{ .kind = "object", .data = i, .label = o.label() });
            if (ui.dropZone(r.rect, "object")) |drop| {
                const dragged: u32 = @intCast(drop.data);
                if (dragged == i or app.isAncestor(dragged, i)) {
                    ui.refuseDrop("It would be its own parent");
                } else {
                    var hb: [48]u8 = undefined;
                    ui.dropHint(std.fmt.bufPrint(&hb, "{s} {s}", .{ if (o.folder) "Into" else "Child of", o.label() }) catch "");
                    if (drop.released) {
                        app.objs[dragged].parent = i;
                        o.open = true;
                    }
                }
            }
        }
        const lr = ui.endList(&list);
        if (ui.dropZone(lr.empty, "object")) |drop| {
            ui.dropHint("No parent");
            if (drop.released) app.objs[@intCast(drop.data)].parent = null;
        }
        if (lr.delete) app.say("Delete pressed (the demo keeps them)", .{});
        ui.endVertical();

        // The viewport and the assets.
        ui.beginVertical(.{ .width = .fill, .height = .fill });
        const view = ui.beginCanvas("viewport", .{ .height = .px(250), .background = colors.background });
        var y = view.rect.y + 10;
        view.painter.text(.{ .x = view.rect.x + 10, .y = y }, colors.text_muted, "Viewport: drop assets or files here");
        for (0..app.placed_count) |k| {
            y += 22;
            view.painter.text(.{ .x = view.rect.x + 24, .y = y }, colors.text, app.placed[k][0..app.placed_len[k]]);
        }
        ui.endCanvas();
        if (ui.dropZone(view.rect, "asset")) |drop| {
            ui.dropHint("Place it in the scene");
            if (drop.released and app.placed_count < 16) {
                const t = std.fmt.bufPrint(&app.placed[app.placed_count], "Asset {d}", .{drop.data}) catch "Asset";
                app.placed_len[app.placed_count] = t.len;
                app.placed_count += 1;
            }
        }
        if (ui.fileDrop(view.rect)) |d| {
            var files = d;
            while (files.next()) |path| app.say("Dropped {s}", .{std.fs.path.basename(path)});
        }
        ui.label("Assets", .{ .color = colors.text_muted });
        var tiles = ui.beginTiles("assets", &app.asset_selected, &app.asset_state, .{ .height = .fill, .tile_width = 104, .tile_height = 96 });
        for (tiles.list.first..tiles.list.end) |t| {
            var b: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&b, "Asset {d}", .{t}) catch "Asset";
            const r = ui.tile(&tiles, t, .{ .label = name, .image = &app.thumbs.images[t] });
            _ = ui.dragSource(r.interaction, .{ .kind = "asset", .data = t, .label = name });
            if (r.activated) app.say("Opened {s}", .{name});
        }
        _ = ui.endTiles(&tiles);
        ui.beginScrollArea("strip", .{ .height = .px(54), .horizontal = true });
        ui.beginHorizontal(.{});
        for (0..60) |f| ui.labelf("{d:0>3}", .{f * 10}, .{ .color = if (f % 5 == 0) colors.text else colors.text_muted });
        ui.endHorizontal();
        ui.endScrollArea();
        if (app.message_len > 0) ui.label(app.message[0..app.message_len], .{ .color = colors.accent });
        ui.endVertical();
        ui.endHorizontal();
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try init.gpa.create(App);
    defer init.gpa.destroy(app);
    app.* = .{};
    app.build();
    app.thumbs.build();
    try harness.runUi(init, .{ .title = "Zui 19: outliner", .width = 1000, .height = 700 }, app);
}
