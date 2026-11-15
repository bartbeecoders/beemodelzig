//! Phase 13 demo: lines, arcs, curves, gradients, images and icons, a canvas
//! with its own mouse handling, pointer shapes, and more fonts.
//!
//! In the canvas: drag the round handles to bend the curve, hover the pie
//! wedges, drag with the middle button to pan, and use the wheel to zoom.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const Vec2 = zui.Vec2;
const Color = zui.Color;

/// A 16 x 16 alpha icon atlas drawn in code, as an app would load one.
const icon_cells = 6;
const IconAtlas = struct {
    pixels: [16 * icon_cells * 16]u8 = @splat(0),
    image: zui.Image = undefined,
    set: zui.IconSet = undefined,

    fn build(self: *IconAtlas) void {
        for (0..icon_cells) |cell| {
            for (0..16) |y| for (0..16) |x| {
                const fx: f32 = @as(f32, @floatFromInt(x)) - 7.5;
                const fy: f32 = @as(f32, @floatFromInt(y)) - 7.5;
                const on = switch (cell) {
                    0 => fx * fx + fy * fy < 42, // disc
                    1 => @abs(fx) < 6 and @abs(fy) < 6 and !(@abs(fx) < 4 and @abs(fy) < 4), // frame
                    2 => fy > -6 and @abs(fx) * 2 < fy + 7, // triangle
                    3 => @abs(fx - fy) < 1.6 or @abs(fx + fy) < 1.6, // cross
                    4 => (x / 4 + y / 4) % 2 == 0, // checker
                    else => @abs(fy) < 1.5 or (@abs(fx) < 1.5 and fy < 0), // T
                };
                self.pixels[y * 16 * icon_cells + cell * 16 + x] = if (on) 255 else 0;
            };
        }
        self.image = .initAlpha(&self.pixels, 16 * icon_cells, 16);
        self.set = .grid(&self.image, 16, 16);
    }
};

/// A picture that the app redraws every frame, like a 3D viewport.
const Plasma = struct {
    pixels: [size * size]u32 = @splat(0),
    image: zui.Image = undefined,
    const size = 160;

    fn init(self: *Plasma) void {
        self.image = .initArgb(&self.pixels, size, size);
        self.image.is_opaque = true;
    }

    fn update(self: *Plasma, t: f32) void {
        for (0..size) |y| for (0..size) |x| {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            const v = @sin(fx / 13 + t) + @sin(fy / 9 - t * 1.3) + @sin((fx + fy) / 17 + t * 0.7);
            const r: u32 = @intFromFloat(127 + 127 * @sin(v));
            const g: u32 = @intFromFloat(127 + 127 * @sin(v + 2.1));
            const b: u32 = @intFromFloat(127 + 127 * @sin(v + 4.2));
            self.pixels[y * size + x] = 0xFF000000 | (r << 16) | (g << 8) | b;
        };
        self.image.touch();
    }
};

const App = struct {
    atlas: IconAtlas = .{},
    plasma: Plasma = .{},
    mono: *zui.Font,
    symbols: ?*zui.Font,
    animate: bool = true,
    time: f32 = 0,
    handles: [2]Vec2 = .{ .{ .x = 100, .y = 40 }, .{ .x = 70, .y = 160 } },
    dragged: ?usize = null,
    pan: Vec2 = .{},
    zoom: f32 = 1,
    wedge_clicked: ?usize = null,

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        if (app.symbols) |s| ui.font.fallback = s;
        if (app.animate) {
            app.time += ui.dt;
            app.plasma.update(app.time);
            ui.requestRedraw();
        }

        ui.beginHorizontal(.{ .alignment = .start, .height = .fill, .spacing = 16 });
        app.sidebar(ui);
        app.canvas(ui);
        ui.endHorizontal();
    }

    fn sidebar(app: *App, ui: *zui.Ui) void {
        ui.beginVertical(.{ .width = .px(340) });
        ui.label("Built-in icons (vector, sharp at any scale)", .{});
        const names = comptime std.meta.fieldNames(zui.BuiltinIcon);
        inline for (0..(names.len + 5) / 6) |row| {
            ui.beginHorizontal(.{ .spacing = 4 });
            inline for (names[row * 6 .. @min(names.len, row * 6 + 6)]) |name| {
                const r = ui.button("##" ++ name, .{ .icon = .{ .builtin = @field(zui.BuiltinIcon, name) } });
                ui.tooltip(r, name);
            }
            ui.endHorizontal();
        }
        ui.beginHorizontal(.{});
        _ = ui.button("Search", .{ .icon = .{ .builtin = .search } });
        _ = ui.button("Add", .{ .icon = .{ .builtin = .plus } });
        _ = ui.checkbox("Animate", &app.animate, .{});
        ui.endHorizontal();

        ui.separator();
        ui.label("Bitmap icons at 16, 24 and 32 units", .{});
        for ([_]f32{ 16, 24, 32 }) |size| {
            ui.beginHorizontal(.{ .spacing = 6 });
            for (0..icon_cells) |i| ui.icon(app.atlas.set.icon(@intCast(i)), .{ .size = size, .color = ui.style.colors.accent });
            ui.endHorizontal();
        }
        _ = ui.selectable("A row with an icon", false, .{ .icon = app.atlas.set.icon(0) });

        ui.separator();
        ui.label("Pointer shapes: hover these", .{});
        const cursors = comptime std.meta.fieldNames(zui.Cursor);
        inline for (.{ cursors[0..4], cursors[4..7], cursors[7..] }) |row| {
            ui.beginHorizontal(.{ .spacing = 4 });
            inline for (row) |name| {
                const r = ui.button(name, .{});
                if (r.hovered) ui.cursor = @field(zui.Cursor, name);
            }
            ui.endHorizontal();
        }

        ui.separator();
        ui.label("Fonts", .{});
        ui.pushFont(app.mono);
        ui.label("Liberation Mono: fn main() !void {}", .{});
        ui.label("0O 1lI |{}[]  iiii WWWW", .{});
        ui.popFont();
        if (app.symbols != null) {
            ui.label("Fallback for missing letters: ★ ☂ ♞ ☀", .{});
        } else {
            ui.label("(no Noto Sans Symbols 2 here for the fallback)", .{ .color = ui.style.colors.text_muted });
        }
        if (app.wedge_clicked) |w| ui.labelf("Clicked wedge {d}", .{w + 1}, .{});
        ui.endVertical();
    }

    fn canvas(app: *App, ui: *zui.Ui) void {
        const colors = ui.style.colors;
        const c = ui.beginCanvas("canvas", .{
            .width = .fill,
            .height = .fill,
            .background = colors.window,
            .cursor = if (app.dragged != null) .move else .crosshair,
        });
        defer ui.endCanvas();
        const p = c.painter;

        // Middle drag pans, the wheel zooms about the pointer.
        if (c.dragging == .middle) app.pan = app.pan.add(c.delta);
        if (c.wheel.y != 0) {
            const old = app.zoom;
            app.zoom = std.math.clamp(app.zoom * std.math.pow(f32, 1.15, c.wheel.y), 0.4, 4);
            const at = c.mouse.sub(app.pan);
            app.pan = app.pan.add(at.scale(1 - app.zoom / old));
        }
        const z = app.zoom;
        const o = c.toScreen(app.pan);
        const at = struct {
            fn f(origin: Vec2, zoom: f32, x: f32, y: f32) Vec2 {
                return .{ .x = origin.x + x * zoom, .y = origin.y + y * zoom };
            }
        }.f;

        // A grid of crisp one-pixel lines.
        var gx: f32 = @mod(app.pan.x, 40 * z);
        while (gx < c.rect.w) : (gx += 40 * z) p.line(.{ .x = c.rect.x + gx, .y = c.rect.y }, .{ .x = c.rect.x + gx, .y = c.rect.bottom() }, colors.separator, 1);
        var gy: f32 = @mod(app.pan.y, 40 * z);
        while (gy < c.rect.h) : (gy += 40 * z) p.line(.{ .x = c.rect.x, .y = c.rect.y + gy }, .{ .x = c.rect.right(), .y = c.rect.y + gy }, colors.separator, 1);

        // Lines of several widths, fanning out.
        for ([_]f32{ 0.5, 1, 1.5, 2, 4, 8 }, 0..) |w, i| {
            const a = @as(f32, @floatFromInt(i)) * 0.18;
            p.line(at(o, z, 20, 20 + @as(f32, @floatFromInt(i)) * 4), at(o, z, 20 + 160 * @cos(a), 20 + @as(f32, @floatFromInt(i)) * 4 + 160 * @sin(a)), colors.text, w * z);
        }
        p.dashedLine(at(o, z, 20, 230), at(o, z, 200, 230), colors.accent, 2 * z, 8 * z, 5 * z);

        // The Bézier "node wire" between two draggable handles.
        const h0 = at(o, z, app.handles[0].x + 120, app.handles[0].y);
        const h1 = at(o, z, app.handles[1].x + 120, app.handles[1].y + 50);
        const bend = 80 * z;
        p.bezier(h0, h0.add(.{ .x = bend }), h1.sub(.{ .x = bend }), h1, Color.hex(0xE8A317), 3 * z);
        for ([_]Vec2{ h0, h1 }, 0..) |h, i| {
            const near = c.toScreen(c.mouse).sub(h).length() < 10 * z;
            // Test the press where it happened: the pointer may have moved
            // on since, within the same frame.
            const pressed_on = ui.input.press_pos.get(.left).sub(h).length() < 10 * z;
            if (c.interaction.pressed and pressed_on) app.dragged = i;
            p.circle(h, 7 * z, if (near or app.dragged == i) colors.accent else colors.text_muted);
            p.circleOutline(h, 7 * z, colors.window, 1.5);
        }
        if (app.dragged) |i| {
            if (c.interaction.held) {
                app.handles[i] = app.handles[i].add(c.delta.scale(1 / z));
            } else app.dragged = null;
        }

        // A pie menu: eight wedges of a ring; the one under the pointer lights up.
        const center = at(o, z, 420, 130);
        const inner = 40 * z;
        const outer = 100 * z;
        const gap = 0.04;
        const d = c.toScreen(c.mouse).sub(center);
        const r = d.length();
        var hot: ?usize = null;
        if (c.hovered and r > inner and r < outer) {
            const ang = std.math.atan2(d.y, d.x) + std.math.pi / 8.0;
            hot = @as(usize, @intFromFloat(@floor(@mod(ang, 2 * std.math.pi) / (std.math.pi / 4.0)))) % 8;
        }
        for (0..8) |i| {
            const a0 = (@as(f32, @floatFromInt(i)) - 0.5) * std.math.pi / 4.0 + gap;
            const a1 = a0 + std.math.pi / 4.0 - 2 * gap;
            p.ringSegment(center, inner, outer, a0, a1, if (hot == i) colors.accent else colors.button);
            const mid = (a0 + a1) / 2;
            const ic = center.add(.{ .x = @cos(mid) * (inner + outer) / 2, .y = @sin(mid) * (inner + outer) / 2 });
            const names = [_]zui.BuiltinIcon{ .arrow_right, .check, .arrow_down, .plus, .arrow_left, .close, .arrow_up, .search };
            const s = 18 * z;
            p.icon(.{ .builtin = names[i] }, .{ .x = ic.x - s / 2, .y = ic.y - s / 2, .w = s, .h = s }, colors.text);
        }
        if (hot != null and c.interaction.clicked) app.wedge_clicked = hot;
        p.circleOutline(center, inner - 6 * z, colors.text_muted, 1.5);
        p.arc(center, outer + 10 * z, -2.4, -0.7, colors.accent, 4 * z);
        p.pie(at(o, z, 600, 60), 34 * z, -1.2, 1.4, colors.accent.withAlpha(160));
        p.polygon(&hexagon(at(o, z, 600, 160), 34 * z), Color.hex(0x3C9A5F));

        // A color picker's gradients: saturation / value square and hue strip.
        const sq: zui.Rect = .{ .x = o.x + 260 * z, .y = o.y + 260 * z, .w = 150 * z, .h = 150 * z };
        p.gradient(sq, .white, Color.hex(0xFF2A00), .white, Color.hex(0xFF2A00));
        p.gradient(sq, .transparent, .transparent, .black, .black);
        const hues = [_]u24{ 0xFF0000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0000FF, 0xFF00FF, 0xFF0000 };
        for (0..6) |i| {
            const h = sq.h / 6;
            const band: zui.Rect = .{ .x = sq.right() + 10 * z, .y = sq.y + h * @as(f32, @floatFromInt(i)), .w = 18 * z, .h = h };
            p.gradient(band, Color.hex(hues[i]), Color.hex(hues[i]), Color.hex(hues[i + 1]), Color.hex(hues[i + 1]));
        }

        // An image redrawn every frame, at its size and scaled up.
        const img = &app.plasma.image;
        p.image(img, .{ .x = o.x + 20 * z, .y = o.y + 260 * z, .w = 160 * z, .h = 160 * z }, .{ .filter = .nearest });
        p.image(img, .{ .x = o.x + 470 * z, .y = o.y + 260 * z, .w = 150 * z, .h = 150 * z }, .{ .uv = .{ .x = 0.25, .y = 0.25, .w = 0.3, .h = 0.3 }, .filter = .linear, .tint = Color.white.withAlpha(220) });
        p.text(.{ .x = c.rect.x + 8, .y = c.rect.bottom() - 26 }, colors.text_muted, "Middle drag: pan   Wheel: zoom   Drag the handles");
    }
};

fn hexagon(center: Vec2, radius: f32) [6]Vec2 {
    var pts: [6]Vec2 = undefined;
    for (&pts, 0..) |*pt, i| {
        const a = @as(f32, @floatFromInt(i)) * std.math.pi / 3.0;
        pt.* = .{ .x = center.x + @cos(a) * radius, .y = center.y + @sin(a) * radius };
    }
    return pts;
}

pub fn main(init: std.process.Init) !void {
    var mono: zui.Font = try .initMono(init.gpa);
    defer mono.deinit();
    // A system font as fallback for symbols the default font lacks.
    var symbols: ?zui.Font = zui.Font.loadFile(init.gpa, init.io, "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf") catch null;
    defer if (symbols) |*s| s.deinit();

    var app: App = .{ .mono = &mono, .symbols = if (symbols) |*s| s else null };
    app.atlas.build();
    app.plasma.init();
    app.plasma.update(0);
    try harness.runUi(init, .{ .title = "Zui 13: drawing", .width = 1080, .height = 680 }, &app);
}
