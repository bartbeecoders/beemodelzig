//! Phase 15 demo: a property panel in the style of BeeModel's Properties
//! editor. Number fields scrub and take expressions, choices come as lists,
//! segments and toggles, some things are disabled and say why, tooltips have
//! parts, and every edit goes into an undo history as one step.
//!
//! Try: drag a field sideways (Shift: finer, Ctrl: whole steps), click it
//! and type `2*pi` or `25cm`, right-click a field for its menu, pick an Area
//! light, then Undo.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const LightKind = enum { point, sun, spot, area };
const Shading = enum { wireframe, solid, material, rendered };

/// Everything the panel edits: what an app would snapshot for undo.
const Props = struct {
    name: [32]u8 = "Cube".* ++ @as([28]u8, @splat(0)),
    name_len: usize = 4,
    location: [3]f32 = .{ 0, 0, 1 },
    rotation: [3]f32 = .{ 0, 0, 0 },
    scale: [3]f32 = .{ 1, 1, 1 },
    visible: bool = true,
    locked: bool = false,
    light: LightKind = .point,
    power: f32 = 250,
    cone: f32 = std.math.pi / 4.0,
    color: zui.Color = .{ .r = 255, .g = 236, .b = 210 },
    shading: usize = 1,
    samples: i32 = 64,
    denoise: bool = true,
};

const Step = struct { before: Props, what: []const u8 };

/// A field the right-click menu can act on.
const FieldRef = struct { id: zui.Id, value: *f32, default: f32, label: []const u8 };

const meters: zui.Evaluator = .{ .units = &zui.expr.meters };
const degrees: zui.Evaluator = .{ .units = &zui.expr.degrees };

const App = struct {
    props: Props = .{},
    /// The state as of the last commit; pushed onto `history` by the next.
    committed: Props = .{},
    history: [64]Step = undefined,
    history_len: usize = 0,
    redo: [64]Step = undefined,
    redo_len: usize = 0,
    fields: [16]FieldRef = undefined,
    field_count: usize = 0,
    menu_target: ?zui.Id = null,
    clipboard: ?f32 = null,
    status: [160]u8 = undefined,
    status_len: usize = 0,

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        // A right-click on any field opens one shared menu for it.
        if (ui.contextRequest()) |req| {
            for (app.fields[0..app.field_count]) |f| if (f.id == req.widget) {
                app.menu_target = f.id;
                ui.openPopupAt("Field menu", .{ .x = req.pos.x, .y = req.pos.y });
            };
        }
        if (ui.disabledClick()) |why| app.say("Not now: {s}", .{why});
        app.field_count = 0;

        ui.beginHorizontal(.{ .alignment = .start, .height = .fill, .spacing = 24 });
        ui.beginVertical(.{ .width = .px(430) });
        app.objectPanel(ui);
        ui.separator();
        app.lightPanel(ui);
        ui.separator();
        app.renderPanel(ui);
        ui.endVertical();
        ui.beginVertical(.{ .width = .fill });
        app.historyPanel(ui);
        ui.endVertical();
        ui.endHorizontal();
        app.fieldMenu(ui);
    }

    fn say(app: *App, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&app.status, fmt, args) catch "";
        app.status_len = text.len;
    }

    /// The undo rule: keep a copy of the state as of the last commit. When
    /// a widget commits, that copy is the "before" of one step.
    fn track(app: *App, r: zui.Interaction, what: []const u8) void {
        if (!r.committed) return;
        if (app.history_len == app.history.len) {
            std.mem.copyForwards(Step, app.history[0 .. app.history.len - 1], app.history[1..]);
            app.history_len -= 1;
        }
        app.history[app.history_len] = .{ .before = app.committed, .what = what };
        app.history_len += 1;
        app.redo_len = 0;
        app.committed = app.props;
    }

    fn number(app: *App, ui: *zui.Ui, name: []const u8, value: *f32, default: f32, options: zui.NumberOptions) void {
        const r = ui.numberField(name, value, options);
        app.track(r, name);
        if (app.field_count < app.fields.len) {
            app.fields[app.field_count] = .{ .id = ui.id(name), .value = value, .default = default, .label = name };
            app.field_count += 1;
        }
    }

    fn objectPanel(app: *App, ui: *zui.Ui) void {
        const p = &app.props;
        if (!ui.collapsingHeader("Object", .{ .default_open = true })) return;
        ui.beginHorizontal(.{});
        app.track(ui.textInput("##name", &p.name, &p.name_len, .{ .width = .px(220) }), "Name");
        const eye = ui.iconToggle("Visible", &p.visible, .{ .on = .{ .builtin = .eye }, .off = .{ .builtin = .eye_off } });
        ui.tooltipRich(eye, .{ .title = "Visible", .shortcut = "H", .body = "Hidden objects stay in the scene but are not drawn or rendered." });
        app.track(eye, "Visibility");
        const lock = ui.iconToggle("Locked", &p.locked, .{ .on = .{ .builtin = .lock }, .off = .{ .builtin = .unlock } });
        ui.tooltipRich(lock, .{ .title = "Locked", .body = "Clicks in the viewport pass through a locked object." });
        app.track(lock, "Lock");
        ui.endHorizontal();

        ui.pushDisabled(if (p.locked) "The object is locked" else null);
        defer ui.popDisabled();
        const loc = ui.vectorField("Location", &p.location, .{ .number = .{ .suffix = " m", .evaluator = &meters } });
        ui.tooltipRich(loc, .{ .title = "Location", .shortcut = "G", .body = "Where the object's origin is, in meters. Type 25cm or width/2." });
        app.track(loc, "Location");
        app.track(ui.vectorField("Rotation", &p.rotation, .{ .number = .{
            .display_scale = 180.0 / std.math.pi,
            .suffix = "\u{00B0}",
            .step = 1,
            .decimals = 1,
            .evaluator = &degrees,
        } }), "Rotation");
        app.track(ui.vectorField("Scale", &p.scale, .{ .number = .{ .min = 0.001, .step = 0.1 } }), "Scale");
    }

    fn lightPanel(app: *App, ui: *zui.Ui) void {
        const p = &app.props;
        if (!ui.collapsingHeader("Light", .{ .default_open = true })) return;
        const kinds = [_]zui.Choice{
            .{ .label = "Point", .tooltip = "Light in every direction from one point." },
            .{ .label = "Sun", .tooltip = "Parallel light from far away." },
            .{ .label = "Spot", .tooltip = "A cone of light." },
            .{ .label = "Area", .disabled = "Area lights need the path tracer (Render tab)" },
        };
        var kind: usize = @intFromEnum(p.light);
        const r = ui.dropdown("Type", &kind, &kinds, .{});
        if (r.changed) p.light = @enumFromInt(kind);
        app.track(r, "Light type");
        app.number(ui, "Power", &p.power, 250, .{ .min = 0, .max = 1000, .step = 10, .suffix = " W", .slider = true, .decimals = 0 });
        app.track(ui.colorEdit("Color", &p.color, .{}), "Light color");
        ui.pushDisabled(if (p.light != .spot) "Only spot lights have a cone" else null);
        app.track(ui.angleField("Cone", &p.cone, .{ .min = 0.01, .max = std.math.pi }), "Cone");
        ui.popDisabled();
    }

    fn renderPanel(app: *App, ui: *zui.Ui) void {
        const p = &app.props;
        if (!ui.collapsingHeader("Viewport", .{ .default_open = true })) return;
        const modes = [_]zui.Choice{
            .{ .label = "Wire" },
            .{ .label = "Solid" },
            .{ .label = "Material" },
            .{ .label = "Rendered", .disabled = "No GPU helper found" },
        };
        app.track(ui.segmented("Shading", &p.shading, &modes, .{}), "Shading");
        app.track(ui.numberField("Samples", &p.samples, .{ .min = 1, .max = 4096, .label = .outside }), "Samples");
        app.track(ui.checkbox("Denoise", &p.denoise, .{}), "Denoise");
    }

    fn historyPanel(app: *App, ui: *zui.Ui) void {
        ui.label("Undo history: one step per drag, typed value or pick", .{ .color = ui.style.colors.text_muted });
        ui.beginHorizontal(.{});
        ui.pushDisabled(if (app.history_len == 0) "Nothing to undo" else null);
        if (ui.button("Undo", .{ .icon = .{ .builtin = .arrow_left } }).clicked) {
            app.history_len -= 1;
            app.redo[app.redo_len] = .{ .before = app.props, .what = app.history[app.history_len].what };
            app.redo_len += 1;
            app.props = app.history[app.history_len].before;
            app.committed = app.props;
        }
        ui.popDisabled();
        ui.pushDisabled(if (app.redo_len == 0) "Nothing to redo" else null);
        if (ui.button("Redo", .{ .icon = .{ .builtin = .arrow_right } }).clicked) {
            app.redo_len -= 1;
            app.history[app.history_len] = .{ .before = app.props, .what = app.redo[app.redo_len].what };
            app.history_len += 1;
            app.props = app.redo[app.redo_len].before;
            app.committed = app.props;
        }
        ui.popDisabled();
        ui.endHorizontal();
        ui.beginScrollArea("history", .{ .height = .px(300), .width = .fill });
        var i = app.history_len;
        while (i > 0) {
            i -= 1;
            ui.labelf("{d}. {s}", .{ i + 1, app.history[i].what }, .{});
        }
        if (app.history_len == 0) ui.label("(nothing yet)", .{ .color = ui.style.colors.text_muted });
        ui.endScrollArea();
        if (app.status_len > 0) ui.label(app.status[0..app.status_len], .{ .color = ui.style.colors.warning });
    }

    /// One menu for every field, opened by `contextRequest`.
    fn fieldMenu(app: *App, ui: *zui.Ui) void {
        if (!ui.beginPopup("Field menu", .{ .min_width = 180 })) return;
        defer ui.endPopup();
        const target = app.menu_target orelse return;
        const field = for (app.fields[0..app.field_count]) |f| {
            if (f.id == target) break f;
        } else return;
        ui.label(field.label, .{ .color = ui.style.colors.text_muted });
        if (ui.button("Reset to Default", .{ .width = .fill }).clicked) {
            field.value.* = field.default;
            app.track(.{ .committed = true }, "Reset to Default");
            ui.closePopup();
        }
        if (ui.button("Copy Value", .{ .width = .fill }).clicked) {
            app.clipboard = field.value.*;
            ui.closePopup();
        }
        ui.pushDisabled(if (app.clipboard == null) "Copy a value first" else null);
        if (ui.button("Paste Value", .{ .width = .fill }).clicked) {
            field.value.* = app.clipboard.?;
            app.track(.{ .committed = true }, "Paste Value");
            ui.closePopup();
        }
        ui.popDisabled();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 15: properties", .width = 900, .height = 720 }, &app);
}
