//! A window frame drawn by Zui, for backends without one from the system
//! (client-side decorations on Wayland): a title bar with minimize,
//! maximize and close, dragging to move, and edges to resize from.
//!
//!     ui.beginFrame(...);
//!     switch (ui.clientFrame("BeeModel", .{ .maximized = window.maximized })) {
//!         .move => window.move(),
//!         .resize => |edges| window.resize(edges),
//!         .minimize => window.minimize(),
//!         .maximize => window.setMaximized(!window.maximized),
//!         .close => running = false,
//!         .none => {},
//!     }
//!
//! Zui only reports what was asked; the backend asks the system, which
//! moves or resizes the window (it needs the press that started it).

const std = @import("std");
const draw = @import("draw.zig");
const ui_mod = @import("ui.zig");
const color = @import("color.zig");
const Ui = ui_mod.Ui;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;
const Color = draw.Color;

/// Which edges a resize moves.
pub const Edges = packed struct(u4) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    /// The edges as xdg_toplevel numbers them (1 top, 2 bottom, 4 left,
    /// 8 right; corners add up).
    pub fn xdg(e: Edges) u32 {
        return @as(u32, @intFromBool(e.top)) * 1 + @as(u32, @intFromBool(e.bottom)) * 2 + @as(u32, @intFromBool(e.left)) * 4 + @as(u32, @intFromBool(e.right)) * 8;
    }
};

/// What the user asked of the window this frame.
pub const FrameAction = union(enum) {
    none,
    /// The title bar was pressed: let the system move the window.
    move,
    /// An edge or corner was pressed: let the system resize the window.
    resize: Edges,
    minimize,
    /// Maximize, or restore if it is maximized (button or double click).
    maximize,
    close,
};

/// Options for `clientFrame`.
pub const ClientFrameOptions = struct {
    /// The window is maximized (or tiled): no resize edges, and the
    /// maximize button restores.
    maximized: bool = false,
    resizable: bool = true,
    /// The window has the keyboard: a stronger title bar.
    active: bool = true,
    /// How wide the resize edges are.
    edge: f32 = 6,
};

/// Draws the frame along the top of the window and moves the rest of the
/// UI below it. Call it first in the frame, before any widget.
pub fn clientFrame(ui: *Ui, title: []const u8, options: ClientFrameOptions) FrameAction {
    const style = &ui.style;
    const colors = &style.colors;
    const line_h = ui.textSize("").y;
    const bar_h = line_h + 2 * style.frame_padding.y + 4;
    var action: FrameAction = .none;
    ui.pushId("##client frame");
    defer ui.popId();

    // Edges first, so they win over the title bar at the top.
    if (options.resizable and !options.maximized) {
        const e = options.edge;
        const c = e * 2;
        const w = ui.width;
        const h = ui.height;
        const zones = [_]struct { Rect, Edges, ui_mod.Cursor }{
            .{ .{ .x = 0, .y = 0, .w = c, .h = c }, .{ .top = true, .left = true }, .resize_nwse },
            .{ .{ .x = w - c, .y = 0, .w = c, .h = c }, .{ .top = true, .right = true }, .resize_nesw },
            .{ .{ .x = 0, .y = h - c, .w = c, .h = c }, .{ .bottom = true, .left = true }, .resize_nesw },
            .{ .{ .x = w - c, .y = h - c, .w = c, .h = c }, .{ .bottom = true, .right = true }, .resize_nwse },
            .{ .{ .x = c, .y = 0, .w = w - 2 * c, .h = e }, .{ .top = true }, .resize_ns },
            .{ .{ .x = c, .y = h - e, .w = w - 2 * c, .h = e }, .{ .bottom = true }, .resize_ns },
            .{ .{ .x = 0, .y = c, .w = e, .h = h - 2 * c }, .{ .left = true }, .resize_ew },
            .{ .{ .x = w - e, .y = c, .w = e, .h = h - 2 * c }, .{ .right = true }, .resize_ew },
        };
        for (zones, 0..) |z, i| {
            const rect, const edges, const cursor = z;
            ui.pushIdInt(i);
            const item = ui.interact(ui.id("##edge"), rect);
            ui.popId();
            if (item.hovered or item.held) ui.cursor = cursor;
            if (item.pressed) action = .{ .resize = edges };
        }
    }

    const bar: Rect = .{ .w = ui.width, .h = bar_h };
    ui.drawRect(.{ .rect = bar, .fill = if (options.active) colors.title_active else colors.title });
    ui.drawRect(.{ .rect = .{ .y = bar_h - 1, .w = ui.width, .h = 1 }, .fill = colors.border });

    // Buttons, right to left: close, maximize, minimize.
    const bw = bar_h * 1.4;
    const names = [_][]const u8{ "Close", if (options.maximized) "Restore" else "Maximize", "Minimize" };
    var right = ui.width;
    for (names, 0..) |name, i| {
        const r: Rect = .{ .x = right - bw, .y = 0, .w = bw, .h = bar_h - 1 };
        right = r.x;
        const item = ui.interact(ui.id(name), r);
        const is_close = i == 0;
        if (item.hovered) ui.drawRect(.{ .rect = r, .fill = if (is_close) Color.hex(0xC42B1C) else colors.button_hovered });
        const ink = if (item.hovered and is_close) Color.white else colors.title_text;
        const s = line_h * 0.7;
        const g: Rect = .{ .x = r.x + (r.w - s) / 2, .y = r.y + (r.h - s) / 2, .w = s, .h = s };
        const p = ui.painter();
        switch (i) {
            0 => p.icon(.{ .builtin = .close }, g, ink),
            1 => if (options.maximized) {
                ui.drawRect(.{ .rect = .{ .x = g.x + s * 0.25, .y = g.y, .w = s * 0.75, .h = s * 0.75 }, .border = ink, .border_width = 1.2 });
                ui.drawRect(.{ .rect = .{ .x = g.x, .y = g.y + s * 0.25, .w = s * 0.75, .h = s * 0.75 }, .fill = if (options.active) colors.title_active else colors.title, .border = ink, .border_width = 1.2 });
            } else {
                ui.drawRect(.{ .rect = g.inset(1), .border = ink, .border_width = 1.2 });
            },
            else => p.line(.{ .x = g.x + 1, .y = g.y + s / 2 }, .{ .x = g.right() - 1, .y = g.y + s / 2 }, ink, 1.2),
        }
        ui.recordWidget(.window_button, item.id, name, r, .{ .hovered = item.hovered });
        if (item.clicked) action = switch (i) {
            0 => .close,
            1 => .maximize,
            else => .minimize,
        };
    }

    // The rest of the bar moves the window; a double click maximizes.
    const drag_area: Rect = .{ .w = right, .h = bar_h - 1 };
    const drag = ui.interact(ui.id("##title"), drag_area);
    if (drag.pressed) action = if (ui.input.press_clicks.get(.left) == 2) .maximize else .move;
    const tw = ui.textSize(title).x;
    ui.pushClip(drag_area);
    ui.drawText(.{ .x = @max(style.frame_padding.x, (ui.width - tw) / 2), .y = (bar_h - line_h) / 2 }, if (options.active) colors.title_text else colors.text_muted, title);
    ui.popClip();
    ui.recordWidget(.window, drag.id, title, drag_area, .{ .value = if (options.maximized) "maximized" else "normal", .hovered = drag.hovered });

    ui.moveRootBelow(bar_h);
    return action;
}

const testing = std.testing;

test "edges for xdg" {
    try testing.expectEqual(@as(u32, 10), (Edges{ .bottom = true, .right = true }).xdg());
    try testing.expectEqual(@as(u32, 5), (Edges{ .top = true, .left = true }).xdg());
}
