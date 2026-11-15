//! Phase 17 demo: BeeModel's window layout. Workspaces are tabs, each with
//! its own dock of areas.
//!
//! Try: drag a splitter; drag an area's header onto another area (edges
//! split, the middle swaps); drag an area's top-left corner into its
//! neighbour; right-click a header and Float the area, then drag the panel
//! over an area and drop it on a guide; F6 and Ctrl+Space; double-click a
//! workspace tab to rename it, + to add one.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const Editor = enum(u32) { viewport, outliner, properties, console, timeline };

const editors = [_]zui.Choice{
    .{ .label = "3D Viewport" },
    .{ .label = "Outliner" },
    .{ .label = "Properties" },
    .{ .label = "Console" },
    .{ .label = "Timeline" },
};

const Workspace = struct {
    name: [32]u8 = undefined,
    name_len: usize = 0,
    dock: zui.Dock,

    fn init(name: []const u8, dock: zui.Dock) Workspace {
        var w: Workspace = .{ .dock = dock };
        w.setName(name);
        return w;
    }

    fn setName(w: *Workspace, name: []const u8) void {
        const n = @min(name.len, w.name.len);
        @memcpy(w.name[0..n], name[0..n]);
        w.name_len = n;
    }
};

fn modeling() zui.Dock {
    var d: zui.Dock = .init(@intFromEnum(Editor.viewport));
    const viewport = d.root;
    const right = d.split(viewport, .right, @intFromEnum(Editor.outliner)).?;
    _ = d.split(right, .bottom, @intFromEnum(Editor.properties)).?;
    _ = d.split(viewport, .bottom, @intFromEnum(Editor.console)).?;
    // The side column a third of the width, the console a quarter of the height.
    const side_column = d.nodes[d.nodes[right].parent].parent;
    d.nodes[side_column].ratio = 0.68;
    return d;
}

fn animation() zui.Dock {
    var d: zui.Dock = .init(@intFromEnum(Editor.viewport));
    const viewport = d.root;
    _ = d.split(viewport, .bottom, @intFromEnum(Editor.timeline)).?;
    _ = d.split(viewport, .right, @intFromEnum(Editor.properties)).?;
    return d;
}

const App = struct {
    workspaces: [8]Workspace = undefined,
    count: usize = 0,
    current: usize = 0,
    prop_tab: usize = 0,
    objects: [4]bool = .{ true, true, false, true },
    saved: [4096]u8 = undefined,
    saved_len: usize = 0,
    note: []const u8 = "",

    fn initAll(app: *App) void {
        app.workspaces[0] = .init("Modeling", modeling());
        app.workspaces[1] = .init("Animation", animation());
        app.workspaces[2] = .init("Shading", .init(@intFromEnum(Editor.viewport)));
        app.count = 3;
    }

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        // Workspace tabs, with the layout buttons on the same row.
        var tabs: [8]zui.Tab = undefined;
        for (app.workspaces[0..app.count], 0..) |*w, i| tabs[i] = .{ .label = w.name[0..w.name_len] };
        ui.beginHorizontal(.{});
        const r = ui.tabBar("workspaces", &app.current, tabs[0..app.count], .{ .addable = app.count < app.workspaces.len, .renamable = true, .closable = app.count > 1 });
        ui.spacer(.fill);
        if (ui.button("Save layout", .{}).clicked) {
            var w: std.Io.Writer = .fixed(&app.saved);
            app.workspaces[app.current].dock.write(&w) catch {};
            app.saved_len = w.end;
            app.note = "Saved";
        }
        ui.pushDisabled(if (app.saved_len == 0) "Save a layout first" else null);
        if (ui.button("Restore", .{}).clicked) {
            if (zui.Dock.read(app.saved[0..app.saved_len])) |d| {
                app.workspaces[app.current].dock = d;
                app.note = "Restored";
            } else |_| app.note = "That layout doesn't fit";
        }
        ui.popDisabled();
        ui.label(app.note, .{ .color = ui.style.colors.text_muted });
        ui.endHorizontal();
        if (r.add) {
            app.workspaces[app.count] = .init("New", .init(@intFromEnum(Editor.viewport)));
            app.current = app.count;
            app.count += 1;
        }
        if (r.close) |i| {
            std.mem.copyForwards(Workspace, app.workspaces[i .. app.count - 1], app.workspaces[i + 1 .. app.count]);
            app.count -= 1;
            app.current = @min(app.current, app.count - 1);
        }
        if (r.rename) |rn| app.workspaces[rn.index].setName(rn.text);

        const dock = &app.workspaces[app.current].dock;
        ui.beginDockSpace("dock", dock, .{ .editors = &editors });
        var buffer: [zui.Dock.max_areas]zui.AreaId = undefined;
        for (dock.areas(&buffer)) |id| {
            const area = ui.beginArea(id) orelse continue;
            defer ui.endArea();
            app.header(ui, area);
            ui.areaBody();
            app.body(ui, area);
        }
        _ = ui.endDockSpace();
    }

    fn header(_: *App, ui: *zui.Ui, area: zui.AreaInfo) void {
        switch (@as(Editor, @enumFromInt(area.editor))) {
            .viewport => {
                var shading: usize = 1;
                _ = ui.segmented("##shading", &shading, &.{ .{ .label = "Wire" }, .{ .label = "Solid" }, .{ .label = "Look" } }, .{});
            },
            .timeline => _ = ui.button("##play", .{ .icon = .{ .builtin = .arrow_right } }),
            else => {},
        }
    }

    fn body(app: *App, ui: *zui.Ui, area: zui.AreaInfo) void {
        const colors = ui.style.colors;
        switch (@as(Editor, @enumFromInt(area.editor))) {
            .viewport => {
                const c = ui.beginCanvas("view", .{ .height = .fill, .background = colors.background });
                defer ui.endCanvas();
                var x = c.rect.x;
                while (x < c.rect.right()) : (x += 32) c.painter.line(.{ .x = x, .y = c.rect.y }, .{ .x = x, .y = c.rect.bottom() }, colors.separator, 1);
                const center: zui.Vec2 = .{ .x = c.rect.x + c.rect.w / 2, .y = c.rect.y + c.rect.h / 2 };
                c.painter.polygon(&.{ center.add(.{ .y = -40 }), center.add(.{ .x = 40 }), center.add(.{ .y = 40 }), center.add(.{ .x = -40 }) }, colors.accent.withAlpha(150));
                var b: [32]u8 = undefined;
                c.painter.text(.{ .x = c.rect.x + 8, .y = c.rect.y + 6 }, colors.text_muted, std.fmt.bufPrint(&b, "Area {d}{s}", .{ area.id, if (area.active) ", active" else "" }) catch "");
            },
            .outliner => {
                ui.beginScrollArea("##rows", .{ .height = .fill, .width = .fill, .frame = false, .padding = 0 });
                defer ui.endScrollArea();
                const names = [_][]const u8{ "Camera", "Cube", "Light", "Sphere" };
                for (names, 0..) |n, i| {
                    ui.beginHorizontal(.{});
                    _ = ui.iconToggle(n, &app.objects[i], .{ .on = .{ .builtin = .eye }, .off = .{ .builtin = .eye_off } });
                    _ = ui.selectable(n, i == 1, .{});
                    ui.endHorizontal();
                }
            },
            .properties => {
                ui.beginHorizontal(.{ .alignment = .start });
                _ = ui.tabBar("##props", &app.prop_tab, &.{
                    .{ .label = "Object", .icon = .{ .builtin = .dot } },
                    .{ .label = "View", .icon = .{ .builtin = .eye } },
                    .{ .label = "Lock", .icon = .{ .builtin = .lock } },
                    .{ .label = "Info", .icon = .{ .builtin = .info } },
                }, .{ .vertical = true });
                ui.beginVertical(.{ .width = .fill });
                const titles = [_][]const u8{ "Object", "View", "Lock", "Info" };
                ui.label(titles[app.prop_tab], .{});
                var v: f32 = 1;
                _ = ui.numberField("Size", &v, .{ .width = .fill });
                ui.endVertical();
                ui.endHorizontal();
            },
            .console => {
                ui.label("> view.frame_selected", .{ .color = colors.text_muted });
                ui.label("Framed 1 object", .{});
            },
            .timeline => {
                const c = ui.beginCanvas("frames", .{ .height = .fill });
                defer ui.endCanvas();
                var f: f32 = 0;
                while (f < 250) : (f += 10) {
                    const x = c.rect.x + f * c.rect.w / 250;
                    c.painter.line(.{ .x = x, .y = c.rect.y }, .{ .x = x, .y = c.rect.y + 8 }, colors.text_muted, 1);
                }
                c.painter.line(.{ .x = c.rect.x + 60, .y = c.rect.y }, .{ .x = c.rect.x + 60, .y = c.rect.bottom() }, colors.accent, 2);
            },
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    app.initAll();
    try harness.runUi(init, .{ .title = "Zui 17: docking", .width = 1100, .height = 700 }, &app);
}
