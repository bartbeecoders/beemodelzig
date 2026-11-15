//! Phase 18 demo: BeeModel's welcome screen as cards, "Save changes?" and a
//! form as modal dialogs, a status bar with key hints and a render job, and
//! toasts.
//!
//! Try: pick a template (it asks to save first), Export... (Tab, Enter,
//! Escape), Render (watch the chip; click it to stop), the toast buttons.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const Axis = enum { y_up, z_up };

const App = struct {
    scene: []const u8 = "Untitled",
    dirty: bool = true,
    asking: bool = false,
    pending: []const u8 = "",
    exporting: bool = false,
    scale: f32 = 1,
    axis: Axis = .y_up,
    selected_only: bool = false,
    file: [64]u8 = "scene.obj".* ++ @as([55]u8, @splat(0)),
    file_len: usize = 9,
    rendering: bool = false,
    render_time: f32 = 0,
    loading: bool = false,
    load_time: f32 = 0,

    fn open(app: *App, ui: *zui.Ui, what: []const u8) void {
        app.scene = what;
        app.dirty = false;
        var b: [96]u8 = undefined;
        _ = ui.toast(std.fmt.bufPrint(&b, "Opened {s}", .{what}) catch "Opened", .success, .{});
    }

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const colors = ui.style.colors;
        if (app.rendering) {
            app.render_time += ui.dt;
            if (app.render_time >= 8) {
                app.rendering = false;
                _ = ui.toast("Render finished in 8 s", .success, .{});
            }
            ui.requestRedraw();
        }
        if (app.loading) {
            app.load_time += ui.dt;
            if (app.load_time > 3) app.loading = false;
        }

        ui.labelf("BeeModel   {s}{s}", .{ app.scene, if (app.dirty) " (changed)" else "" }, .{});
        ui.separator();
        ui.label("Start", .{ .color = colors.text_muted });
        ui.beginHorizontal(.{ .spacing = 12 });
        const templates = [_]struct { name: []const u8, sub: []const u8, icon: zui.BuiltinIcon, why: ?[]const u8 }{
            .{ .name = "Default scene", .sub = "Cube, light, camera", .icon = .plus, .why = null },
            .{ .name = "Empty scene", .sub = "Nothing at all", .icon = .minus, .why = null },
            .{ .name = "Character", .sub = "A rigged figure", .icon = .dot, .why = null },
            .{ .name = "Terrain", .sub = "Layers and erosion", .icon = .warning, .why = "Comes with the landscape tools" },
        };
        for (templates) |t| {
            if (ui.card(t.name, .{ .icon = .{ .builtin = t.icon }, .subtitle = t.sub, .disabled = t.why }).clicked) {
                if (app.dirty) {
                    app.asking = true;
                    app.pending = t.name;
                } else app.open(ui, t.name);
            }
        }
        ui.endHorizontal();
        ui.label("Recent", .{ .color = colors.text_muted });
        ui.beginHorizontal(.{ .spacing = 12 });
        for ([_][]const u8{ "chair.bee", "house.bee", "robot.bee" }) |r| {
            if (ui.card(r, .{ .icon = .{ .builtin = .menu }, .picture_height = 60, .width = 150 }).clicked) {
                if (app.dirty) {
                    app.asking = true;
                    app.pending = r;
                } else app.open(ui, r);
            }
        }
        ui.endHorizontal();
        ui.separator();
        ui.beginHorizontal(.{});
        if (ui.button("Export...", .{}).clicked) app.exporting = true;
        ui.pushDisabled(if (app.rendering) "A render is running" else null);
        if (ui.button("Render", .{ .icon = .{ .builtin = .arrow_right } }).clicked) {
            app.rendering = true;
            app.render_time = 0;
        }
        ui.popDisabled();
        if (ui.button("Load textures", .{}).clicked) {
            app.loading = true;
            app.load_time = 0;
        }
        if (ui.button("Toast: result", .{}).clicked) _ = ui.toast("Applied the modifier", .success, .{});
        if (ui.button("Toast: problem", .{}).clicked) _ = ui.toast("3 faces could not be filled", .warning, .{});
        ui.endHorizontal();
        if (app.loading) ui.progressBar(null, .{ .width = .px(300) });

        if (ui.beginDialog("Export OBJ", &app.exporting, .{ .min_width = 380 })) {
            defer ui.endDialog();
            _ = ui.textInput("File", &app.file, &app.file_len, .{ .width = .fill });
            _ = ui.numberField("Scale", &app.scale, .{ .min = 0.001, .label = .outside });
            _ = ui.dropdownEnum("Up axis", &app.axis, .{});
            _ = ui.checkbox("Selected objects only", &app.selected_only, .{});
            const empty: ?[]const u8 = if (app.file_len == 0) "Give the file a name" else null;
            if (ui.dialogButtons(&.{ "Export", "Cancel" }, .{ .default = 0, .cancel = 1, .disabled = &.{ empty, null } })) |i| {
                app.exporting = false;
                if (i == 0) {
                    var b: [128]u8 = undefined;
                    _ = ui.toast(std.fmt.bufPrint(&b, "Exported {s}", .{app.file[0..app.file_len]}) catch "Exported", .success, .{});
                }
            }
        }
        ui.spacer(.fill);

        ui.beginStatusBar();
        ui.keyHint("G", "Move");
        ui.keyHint("R", "Rotate");
        ui.keyHint("Shift Click", "Add to selection");
        ui.spacer(.fill);
        if (app.loading) _ = ui.jobChip("Loading textures", null, app.load_time, .{});
        if (app.rendering) {
            const chip = ui.jobChip("Rendering", app.render_time / 8, app.render_time, .{ .action = "Stop" });
            if (chip.clicked) {
                app.rendering = false;
                _ = ui.toast("Render stopped; the samples so far are kept", .warning, .{});
            }
        }
        ui.endStatusBar();

        if (ui.beginDialog("Save changes?", &app.asking, .{})) {
            defer ui.endDialog();
            ui.labelf("\"{s}\" has changes that aren't saved.", .{app.scene}, .{});
            ui.label("Save them before opening another scene?", .{ .color = colors.text_muted });
            if (ui.dialogButtons(&.{ "Save", "Don't Save", "Cancel" }, .{ .default = 0, .cancel = 2 })) |i| {
                app.asking = false;
                switch (i) {
                    0 => {
                        _ = ui.toast("Saved", .success, .{});
                        app.open(ui, app.pending);
                    },
                    1 => app.open(ui, app.pending),
                    else => {},
                }
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 18: feedback", .width = 900, .height = 620 }, &app);
}
