//! Phase 10 demo: tooltips, popups and color edit.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const App = struct {
    status: []const u8 = "Nothing chosen yet",
    hovers: u32 = 0,
    fill: zui.Color = .{ .r = 70, .g = 130, .b = 220, .a = 200 },
    outline: zui.Color = zui.Color.hex(0xF2C14E),
    window_color: zui.Color = zui.Color.hex(0x5BB08A),
    show_outline: bool = true,

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };

        // Right-click on empty space opens a menu at the pointer. This must
        // run outside any popup, so that it replaces whatever is open.
        if (ui.input.mouse_pressed.contains(.right) and ui.hovered_window == null) ui.openPopup("context");

        ui.beginVertical(.{ .width = .fill, .height = .fill });
        ui.label("Tooltips", muted);
        ui.beginHorizontal(.{});
        ui.tooltip(ui.button("Hover me", .{}), "A tooltip appears after half a second.");
        ui.tooltip(ui.button("Two lines", .{}), "Tooltips can span\nseveral lines.");
        const counted = ui.button("Formatted", .{});
        if (counted.hovered and counted.pressed) app.hovers += 1;
        ui.tooltipf(counted, "You have pressed this {d} times.", .{app.hovers});
        ui.endHorizontal();

        ui.spacer(.px(6));
        ui.label("Popups (click away or press Escape to close)", muted);
        ui.beginHorizontal(.{});
        const actions = ui.button("Actions...", .{});
        if (actions.clicked) ui.openPopupAt("actions", actions.rect);
        ui.labelf("{s}", .{app.status}, .{});
        ui.endHorizontal();
        ui.label("Right-click empty space for a context menu.", muted);

        ui.spacer(.px(6));
        ui.label("Color edit (click a swatch)", muted);
        _ = ui.colorEdit("Fill, with alpha", &app.fill, .{});
        _ = ui.colorEdit("Outline, no alpha", &app.outline, .{ .alpha = false });
        _ = ui.checkbox("Show outline", &app.show_outline, .{});
        const preview = ui.place(.{ .x = 260, .y = 70 });
        ui.drawRect(.{
            .rect = preview,
            .fill = app.fill,
            .border = app.outline,
            .border_width = if (app.show_outline) 4 else 0,
            .radius = 10,
        });

        // Near the bottom-right corner: tooltips and popups move to stay on screen.
        ui.spacer(.fill);
        ui.beginHorizontal(.{});
        ui.spacer(.fill);
        const corner = ui.button("Near the corner", .{});
        ui.tooltip(corner, "This tooltip moves left and up\nso it stays on screen.");
        if (corner.clicked) ui.openPopupAt("corner", corner.rect);
        ui.endHorizontal();
        ui.endVertical();

        app.popups(ui);

        if (ui.beginWindow("Over a window", .{ .position = .{ .x = 400, .y = 60 }, .size = .{ .x = 300, .y = 150 } })) {
            defer ui.endWindow();
            ui.label("Popups from here draw above it:", muted);
            _ = ui.colorEdit("Window color", &app.window_color, .{});
            const rect = ui.place(.{ .x = 40, .y = 14 });
            ui.drawRect(.{ .rect = rect, .fill = app.window_color, .radius = 4 });
        }
    }

    fn popups(app: *App, ui: *zui.Ui) void {
        if (ui.beginPopup("actions", .{ .min_width = 170 })) {
            defer ui.endPopup();
            if (ui.button("Rename", .{ .width = .fill }).clicked) app.choose(ui, "Rename");
            if (ui.button("Duplicate", .{ .width = .fill }).clicked) app.choose(ui, "Duplicate");
            const more = ui.button("More...", .{ .width = .fill });
            if (more.clicked) ui.openPopupAt("more", .{ .x = more.rect.right(), .y = more.rect.y - 4, .w = 0, .h = 0 });
            if (ui.beginPopup("more", .{ .min_width = 150 })) {
                defer ui.endPopup();
                if (ui.button("Export", .{ .width = .fill }).clicked) app.choose(ui, "Export (nested)");
                if (ui.button("Archive", .{ .width = .fill }).clicked) app.choose(ui, "Archive (nested)");
            }
            ui.separator();
            ui.pushColor(.button, zui.Color.hex(0xB33A3A));
            ui.pushColor(.button_hovered, zui.Color.hex(0xC94B4B));
            ui.pushColor(.text, zui.Color.white);
            if (ui.button("Delete", .{ .width = .fill }).clicked) app.choose(ui, "Delete");
            ui.popStyles(3);
        }
        if (ui.beginPopup("context", .{ .min_width = 160 })) {
            defer ui.endPopup();
            ui.label("Context menu", .{ .color = ui.style.colors.text_muted });
            if (ui.button("Cut", .{ .width = .fill }).clicked) app.choose(ui, "Cut (context)");
            if (ui.button("Copy", .{ .width = .fill }).clicked) app.choose(ui, "Copy (context)");
            if (ui.button("Paste", .{ .width = .fill }).clicked) app.choose(ui, "Paste (context)");
        }
        if (ui.beginPopup("corner", .{ .min_width = 220 })) {
            defer ui.endPopup();
            ui.label("Opened above its button,", .{});
            ui.label("because there is no room below.", .{});
            if (ui.button("OK", .{}).clicked) ui.closePopup();
        }
    }

    /// Records a menu choice and closes the whole menu.
    fn choose(app: *App, ui: *zui.Ui, what: []const u8) void {
        app.status = what;
        ui.closeAllPopups();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 10: overlays", .width = 760, .height = 520 }, &app);
}
