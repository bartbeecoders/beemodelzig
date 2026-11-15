//! Phase 4 demo: rows, columns, grow sizing, alignment, separators.
//! Resize the window: the toolbar, form and footer all follow.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const App = struct {
    clicks: u32 = 0,

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const colors = ui.style.colors;
        const muted: zui.LabelOptions = .{ .color = colors.text_muted };
        const card: zui.GroupOptions = .{
            .width = .fill,
            .height = .fill,
            .padding = 12,
            .fill = colors.button,
            .border = colors.border,
        };

        // A spacer pushes the right-hand buttons to the far edge.
        ui.beginHorizontal(.{});
        if (ui.button("New", .{}).clicked) app.clicks += 1;
        if (ui.button("Open", .{}).clicked) app.clicks += 1;
        ui.separator();
        if (ui.button("Build", .{}).clicked) app.clicks += 1;
        ui.spacer(.fill);
        ui.label("Search", muted); // short item first: the row still centers it
        _ = ui.button("Go", .{ .width = .px(60) });
        ui.endHorizontal();

        ui.separator();

        // The main row takes all the height the toolbar and footer leave.
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start });

        var sidebar = card;
        sidebar.width = .px(170);
        ui.beginVertical(sidebar);
        ui.label("Fill width", muted);
        _ = ui.button("Short", .{ .width = .fill });
        _ = ui.button("A longer label", .{ .width = .fill });
        ui.separator();
        ui.label("Natural width", muted);
        _ = ui.button("Short##2", .{});
        ui.spacer(.fill);
        ui.label("Pinned to bottom", muted);
        ui.endVertical();

        // Weights: 2 to 1.
        var wide = card;
        wide.width = .{ .grow = 2 };
        ui.beginVertical(wide);
        ui.label("grow = 2", .{});
        ui.beginHorizontal(.{});
        ui.spacer(.fill);
        _ = ui.button("Right", .{});
        ui.endHorizontal();
        ui.beginHorizontal(.{ .justify = .center });
        _ = ui.button("Centered", .{});
        _ = ui.button("Pair", .{});
        ui.endHorizontal();
        ui.beginHorizontal(.{});
        _ = ui.button("1 of 3", .{ .width = .fill });
        _ = ui.button("2 of 3", .{ .width = .fill });
        _ = ui.button("3 of 3", .{ .width = .fill });
        ui.endHorizontal();
        ui.endVertical();

        var narrow = card;
        narrow.width = .{ .grow = 1 };
        narrow.alignment = .center;
        ui.beginVertical(narrow);
        ui.label("grow = 1", .{});
        _ = ui.button("Centered", .{});
        ui.spacer(.px(20));
        ui.label("Taller items in a row:", muted);
        ui.beginHorizontal(.{});
        _ = ui.button("Tall", .{ .height = .px(50) });
        ui.label("centered", .{});
        ui.endHorizontal();
        ui.endVertical();

        ui.endHorizontal();

        ui.beginHorizontal(.{});
        ui.labelf("Toolbar clicks: {d}", .{app.clicks}, muted);
        ui.spacer(.fill);
        ui.labelf("{d:.0} x {d:.0}", .{ ui.width, ui.height }, muted);
        ui.endHorizontal();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 04: layout", .width = 860, .height = 480 }, &app);
}
