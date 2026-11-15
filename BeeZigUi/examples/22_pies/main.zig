//! Phase 22 demo: BeeModel's pies and the right-click wheel.
//!
//! Over the viewport: hold Z, flick towards a shading mode and let go (a
//! quick tap of Z toggles X-ray instead); Ctrl+Tab for the mode pie;
//! Shift+S for the snap pie. Right-click for the wheel: click an entry, or
//! hold the button, drag and let go; Add and Transform open an outer arc;
//! number keys pick, Backspace goes back, Esc closes.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const shading = [_]zui.PieItem{
    .{ .label = "Wireframe", .icon = .{ .builtin = .eye_off } },
    .{ .label = "Rendered", .icon = .{ .builtin = .star } },
    .{ .label = "Solid", .icon = .{ .builtin = .dot } },
    .{ .label = "Material", .icon = .{ .builtin = .image } },
};

const modes = [_]zui.PieItem{
    .{ .label = "Object Mode" },
    .{ .label = "Edit Mode" },
    .{ .label = "Sculpt Mode" },
    .{ .label = "Vertex Paint" },
    .{ .label = "Weight Paint" },
    .{ .label = "Texture Paint", .disabled = "The mesh has no UV map" },
};

const snaps = [_]zui.PieItem{
    .{ .label = "Selection to Cursor" },
    .{ .label = "Cursor to Selected" },
    .{ .label = "Cursor to World Origin" },
    .{ .label = "Selection to Grid" },
    .{ .label = "Cursor to Grid" },
    .{ .label = "Selection to Active" },
    .{ .label = "Cursor to Active" },
    .{ .label = "Selection to Cursor (Keep Offset)" },
};

const add_items = [_]zui.WheelItem{
    .{ .label = "Cube", .icon = .{ .builtin = .plus } },
    .{ .label = "Sphere", .icon = .{ .builtin = .dot } },
    .{ .label = "Cylinder" },
    .{ .label = "Plane" },
    .{ .label = "Light", .icon = .{ .builtin = .star } },
    .{ .label = "Camera", .icon = .{ .builtin = .eye } },
};

const transform_items = [_]zui.WheelItem{
    .{ .label = "Move", .icon = .{ .builtin = .arrow_right } },
    .{ .label = "Rotate", .icon = .{ .builtin = .refresh } },
    .{ .label = "Scale", .icon = .{ .builtin = .plus } },
};

const wheel_items = [_]zui.WheelItem{
    .{ .label = "Add", .icon = .{ .builtin = .plus }, .color = zui.Color.hex(0x3C7A4F), .children = &add_items },
    .{ .label = "Transform", .icon = .{ .builtin = .arrow_right }, .color = zui.Color.hex(0x3D5F99), .children = &transform_items },
    .{ .label = "Duplicate", .icon = .{ .builtin = .file }, .color = zui.Color.hex(0x5A4C8F) },
    .{ .label = "Delete", .icon = .{ .builtin = .close }, .color = zui.Color.hex(0x9A3B36) },
    .{ .label = "Hide", .icon = .{ .builtin = .eye_off }, .color = zui.Color.hex(0x5C5F66) },
    .{ .label = "Parent", .icon = .{ .builtin = .link }, .color = zui.Color.hex(0x8A6A2E), .disabled = "Select two objects first" },
    .{ .label = "Shade Smooth", .icon = .{ .builtin = .dot }, .color = zui.Color.hex(0x2F7D86) },
    .{ .label = "Snap", .icon = .{ .builtin = .lock }, .color = zui.Color.hex(0x7A3F6E) },
};

const App = struct {
    shading: usize = 2,
    xray: bool = false,
    mode: usize = 0,
    last: [96]u8 = undefined,
    last_len: usize = 0,

    fn say(app: *App, comptime fmt: []const u8, args: anytype) void {
        const text: []const u8 = std.fmt.bufPrint(&app.last, fmt, args) catch "";
        app.last_len = text.len;
    }

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const colors = ui.style.colors;
        ui.beginHorizontal(.{});
        ui.labelf("Shading: {s}{s}   Mode: {s}", .{ shading[app.shading].label, if (app.xray) " (X-ray)" else "", modes[app.mode].label }, .{});
        ui.spacer(.fill);
        ui.label(app.last[0..app.last_len], .{ .color = colors.text_muted });
        ui.endHorizontal();

        const view = ui.beginCanvas("viewport", .{ .height = .fill, .background = zui.Color.hex(0x2A2C31), .cursor = .crosshair });
        // A floor grid, and a cube in the shading mode.
        const p = view.painter;
        const r = view.rect;
        var x = r.x;
        while (x < r.right()) : (x += 40) p.line(.{ .x = x, .y = r.y }, .{ .x = x, .y = r.bottom() }, zui.Color.hex(0x34373D), 1);
        var y = r.y;
        while (y < r.bottom()) : (y += 40) p.line(.{ .x = r.x, .y = y }, .{ .x = r.right(), .y = y }, zui.Color.hex(0x34373D), 1);
        const c: zui.Vec2 = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
        const front = [_]zui.Vec2{ .{ .x = c.x - 70, .y = c.y - 40 }, .{ .x = c.x + 50, .y = c.y - 40 }, .{ .x = c.x + 50, .y = c.y + 80 }, .{ .x = c.x - 70, .y = c.y + 80 } };
        const top = [_]zui.Vec2{ .{ .x = c.x - 70, .y = c.y - 40 }, .{ .x = c.x - 20, .y = c.y - 90 }, .{ .x = c.x + 100, .y = c.y - 90 }, .{ .x = c.x + 50, .y = c.y - 40 } };
        const side = [_]zui.Vec2{ .{ .x = c.x + 50, .y = c.y - 40 }, .{ .x = c.x + 100, .y = c.y - 90 }, .{ .x = c.x + 100, .y = c.y + 30 }, .{ .x = c.x + 50, .y = c.y + 80 } };
        const alpha: u8 = if (app.xray) 110 else 255;
        const faces = [_]struct { []const zui.Vec2, zui.Color }{ .{ &front, zui.Color.hex(0x9A9DA3) }, .{ &top, zui.Color.hex(0xC4C7CC) }, .{ &side, zui.Color.hex(0x74777D) } };
        for (faces) |f| {
            const pts, const shade = f;
            switch (app.shading) {
                0 => p.polyline(pts, zui.Color.hex(0xE0E0E0), 1.5, true),
                1 => p.polygon(pts, zui.color.mix(shade, zui.Color.hex(0xE0873A), 0.45).withAlpha(alpha)),
                2 => p.polygon(pts, shade.withAlpha(alpha)),
                else => p.polygon(pts, zui.color.mix(shade, zui.Color.hex(0x4C8DF0), 0.35).withAlpha(alpha)),
            }
        }
        ui.endCanvas();

        // The keys only count over the viewport, as in BeeModel.
        if (view.hovered and !ui.radialOpen()) {
            const in = &ui.input;
            if ((zui.Shortcut{ .key = .z }).pressed(in)) ui.openPie("Shading", .z);
            if ((zui.Shortcut{ .key = .tab, .modifiers = .{ .ctrl = true } }).pressed(in)) ui.openPie("Mode", .tab);
            if ((zui.Shortcut{ .key = .s, .modifiers = .{ .shift = true } }).pressed(in)) ui.openPie("Snap", .s);
        }
        if (view.right_pressed) ui.openWheel("Context", .right);

        switch (ui.pie("Shading", &shading, .{ .title = "Shading" })) {
            .chosen => |i| {
                app.shading = i;
                app.say("Shading: {s}", .{shading[i].label});
            },
            .tapped => {
                app.xray = !app.xray;
                app.say("Z tapped: X-ray {s}", .{if (app.xray) "on" else "off"});
            },
            .cancelled => app.say("Shading pie closed", .{}),
            .none => {},
        }
        switch (ui.pie("Mode", &modes, .{ .title = "Mode" })) {
            .chosen => |i| {
                app.mode = i;
                app.say("{s}", .{modes[i].label});
            },
            .tapped => app.say("Ctrl+Tab tapped: back to the last mode", .{}),
            else => {},
        }
        switch (ui.pie("Snap", &snaps, .{ .title = "Snap", .radius = 130 })) {
            .chosen => |i| app.say("{s}", .{snaps[i].label}),
            else => {},
        }
        switch (ui.wheel("Context", &wheel_items, .{})) {
            .chosen => |choice| {
                const item = wheel_items[choice.item];
                if (choice.child) |k| app.say("{s}: {s}", .{ item.label, item.children[k].label }) else app.say("{s}", .{item.label});
            },
            .cancelled => app.say("Wheel closed", .{}),
            .none => {},
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 22: pies", .width = 1000, .height = 700 }, &app);
}
