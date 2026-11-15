//! Phase 24 demo: a material node editor with zui_nodes.
//!
//! Try: drag from a pin to another to link (yellow colour, grey float,
//! purple vector, green shader); drop a wire in empty space for the add
//! menu; drag a linked input off; double-click a wire for a knot;
//! Alt+click or Alt+drag cuts wires. Click and box-select nodes, drag them
//! (all selected move); X deletes, Shift+D duplicates, Ctrl+C / Ctrl+V,
//! Shift+A adds; drag palette entries in. Drag the frame's title or
//! corner; double-click its title to rename. Zoom 25 to 200 %; Home fits.

const std = @import("std");
const zui = @import("zui");
const nodes = @import("zui_nodes");
const harness = @import("harness");

const PinType = enum {
    float,
    color,
    vector,
    shader,

    fn tint(t: PinType) zui.Color {
        return switch (t) {
            .float => zui.Color.hex(0xA1A1A1),
            .color => zui.Color.hex(0xC7C729),
            .vector => zui.Color.hex(0x6363C7),
            .shader => zui.Color.hex(0x4DBF6A),
        };
    }

    /// Whether a wire from `a` may end on `b`: shaders only to shaders,
    /// the rest convert.
    fn fits(a: PinType, b: PinType) bool {
        return (a == .shader) == (b == .shader);
    }
};

const PinDef = struct { label: []const u8, type: PinType, value: bool = false };

const Kind = struct {
    name: []const u8,
    category: usize,
    inputs: []const PinDef = &.{},
    outputs: []const PinDef = &.{},
    preview: bool = false,
};

const category_names = [_][]const u8{ "Input", "Shader", "Texture", "Color", "Vector", "Output" };
const category_colors = [_]zui.Color{ zui.Color.hex(0x8B3A3A), zui.Color.hex(0x2F7A4B), zui.Color.hex(0x8A6A2E), zui.Color.hex(0x6E4A8F), zui.Color.hex(0x3D5F99), zui.Color.hex(0x7A3F3F) };

const kinds = [_]Kind{
    .{ .name = "Texture Coordinate", .category = 0, .outputs = &.{ .{ .label = "UV", .type = .vector }, .{ .label = "Object", .type = .vector } } },
    .{ .name = "Principled BSDF", .category = 1, .inputs = &.{ .{ .label = "Base Color", .type = .color, .value = true }, .{ .label = "Roughness", .type = .float, .value = true }, .{ .label = "Metallic", .type = .float, .value = true }, .{ .label = "Normal", .type = .vector } }, .outputs = &.{.{ .label = "BSDF", .type = .shader }} },
    .{ .name = "Emission", .category = 1, .inputs = &.{ .{ .label = "Color", .type = .color, .value = true }, .{ .label = "Strength", .type = .float, .value = true } }, .outputs = &.{.{ .label = "Emission", .type = .shader }} },
    .{ .name = "Image Texture", .category = 2, .inputs = &.{.{ .label = "Vector", .type = .vector }}, .outputs = &.{ .{ .label = "Color", .type = .color }, .{ .label = "Alpha", .type = .float } } },
    .{ .name = "Noise Texture", .category = 2, .inputs = &.{ .{ .label = "Scale", .type = .float, .value = true }, .{ .label = "Detail", .type = .float, .value = true } }, .outputs = &.{ .{ .label = "Fac", .type = .float }, .{ .label = "Color", .type = .color } }, .preview = true },
    .{ .name = "Mix Color", .category = 3, .inputs = &.{ .{ .label = "Factor", .type = .float, .value = true }, .{ .label = "A", .type = .color, .value = true }, .{ .label = "B", .type = .color, .value = true } }, .outputs = &.{.{ .label = "Result", .type = .color }} },
    .{ .name = "Normal Map", .category = 4, .inputs = &.{ .{ .label = "Strength", .type = .float, .value = true }, .{ .label = "Color", .type = .color } }, .outputs = &.{.{ .label = "Normal", .type = .vector }} },
    .{ .name = "Material Output", .category = 5, .inputs = &.{ .{ .label = "Surface", .type = .shader }, .{ .label = "Displacement", .type = .vector } } },
};

/// Reroute knots are nodes of this kind.
const reroute_kind = kinds.len;

const Node = struct {
    id: u64,
    kind: usize,
    pos: zui.Vec2,
    selected: bool = false,
    collapsed: bool = false,
    floats: [4]f64 = .{ 0.5, 0.5, 0, 1 },
    colors: [3]zui.Color = .{ zui.Color.hex(0xCCCCCC), zui.Color.hex(0x3366CC), zui.Color.hex(0xE0873A) },
    /// A reroute's wire type.
    knot_type: PinType = .color,

    fn inPin(n: Node, i: usize) u64 {
        return n.id * 16 + i;
    }
    fn outPin(n: Node, i: usize) u64 {
        return n.id * 16 + 8 + i;
    }
};

const Link = struct { id: u64, from: u64, to: u64 };

const Frame = struct {
    id: u64,
    rect: zui.Rect,
    title: [48]u8 = undefined,
    len: usize = 0,
};

const App = struct {
    gpa: std.mem.Allocator,
    editor: nodes.Editor,
    nodes: std.ArrayList(Node) = .empty,
    links: std.ArrayList(Link) = .empty,
    frames: [1]Frame = undefined,
    next_id: u64 = 1,
    clipboard: std.ArrayList(Node) = .empty,
    commits: u32 = 0,
    add_menu: nodes.AddMenuState = .{},
    add_at: zui.Vec2 = .{},
    add_from: ?u64 = null,
    note: [96]u8 = undefined,
    note_len: usize = 0,
    align_request: ?nodes.Align = null,
    distribute_request: bool = false,

    fn init(gpa: std.mem.Allocator) !App {
        var app: App = .{ .gpa = gpa, .editor = .init(gpa) };
        const tex = try app.add(0, .{ .x = 0, .y = 60 });
        const noise = try app.add(4, .{ .x = 0, .y = 200 });
        const img = try app.add(3, .{ .x = 220, .y = 40 });
        const mix = try app.add(5, .{ .x = 440, .y = 120 });
        const bsdf = try app.add(1, .{ .x = 660, .y = 60 });
        const out = try app.add(7, .{ .x = 900, .y = 100 });
        try app.connect(tex, 0, img, 0);
        try app.connect(img, 0, mix, 1);
        try app.connect(noise, 1, mix, 2);
        try app.connect(mix, 0, bsdf, 0);
        try app.connect(bsdf, 0, out, 0);
        app.frames[0] = .{ .id = 1000, .rect = .{ .x = -20, .y = 0, .w = 420, .h = 380 } };
        const title = "Textures";
        @memcpy(app.frames[0].title[0..title.len], title);
        app.frames[0].len = title.len;
        return app;
    }

    fn deinit(app: *App) void {
        app.editor.deinit();
        app.nodes.deinit(app.gpa);
        app.links.deinit(app.gpa);
        app.clipboard.deinit(app.gpa);
    }

    fn say(app: *App, comptime fmt: []const u8, args: anytype) void {
        const text: []const u8 = std.fmt.bufPrint(&app.note, fmt, args) catch "";
        app.note_len = text.len;
    }

    fn add(app: *App, kind: usize, pos: zui.Vec2) !usize {
        try app.nodes.append(app.gpa, .{ .id = app.next_id, .kind = kind, .pos = pos });
        app.next_id += 1;
        return app.nodes.items.len - 1;
    }

    fn connect(app: *App, from_node: usize, out: usize, to_node: usize, in: usize) !void {
        try app.links.append(app.gpa, .{ .id = app.next_id, .from = app.nodes.items[from_node].outPin(out), .to = app.nodes.items[to_node].inPin(in) });
        app.next_id += 1;
    }

    fn nodeOf(app: *App, id: u64) ?*Node {
        for (app.nodes.items) |*n| if (n.id == id) return n;
        return null;
    }

    fn pinType(app: *App, pin: u64) ?PinType {
        const n = app.nodeOf(pin / 16) orelse return null;
        if (n.kind == reroute_kind) return n.knot_type;
        const i = pin % 16;
        const k = kinds[n.kind];
        return if (i >= 8) (if (i - 8 < k.outputs.len) k.outputs[i - 8].type else null) else (if (i < k.inputs.len) k.inputs[i].type else null);
    }

    fn unlinkInput(app: *App, to: u64) void {
        var i: usize = 0;
        while (i < app.links.items.len) {
            if (app.links.items[i].to == to) _ = app.links.orderedRemove(i) else i += 1;
        }
    }

    fn link(app: *App, from: u64, to: u64) void {
        const a = app.pinType(from) orelse return;
        const b = app.pinType(to) orelse return;
        if (!a.fits(b)) {
            app.say("Can't link {s} to {s}", .{ @tagName(a), @tagName(b) });
            return;
        }
        app.unlinkInput(to);
        app.links.append(app.gpa, .{ .id = app.next_id, .from = from, .to = to }) catch return;
        app.next_id += 1;
    }

    fn apply(app: *App, ui: *zui.Ui, edit: nodes.Edit) void {
        switch (edit) {
            .move => |m| if (app.nodeOf(m.node)) |n| {
                n.pos = n.pos.add(m.delta);
            },
            .select => |s| if (app.nodeOf(s.node)) |n| {
                n.selected = s.selected;
            },
            .link => |l| app.link(l.from, l.to),
            .unlink => |id| for (app.links.items, 0..) |l, i| if (l.id == id) {
                _ = app.links.orderedRemove(i);
                break;
            },
            .add => |a| {
                if (a.data) |kind| {
                    const i = app.add(@intCast(kind), a.pos) catch return;
                    app.say("Added {s}", .{kinds[app.nodes.items[i].kind].name});
                } else {
                    app.add_at = a.pos;
                    app.add_from = a.from;
                    nodes.openAddMenu(ui, "Add", &app.add_menu);
                }
            },
            .reroute => |r| {
                for (app.links.items, 0..) |l, i| if (l.id == r.link) {
                    const t = app.pinType(l.from) orelse .color;
                    const k = app.add(reroute_kind, r.pos) catch return;
                    app.nodes.items[k].knot_type = t;
                    const knot = app.nodes.items[k];
                    _ = app.links.orderedRemove(i);
                    app.links.append(app.gpa, .{ .id = app.next_id, .from = l.from, .to = knot.inPin(0) }) catch return;
                    app.links.append(app.gpa, .{ .id = app.next_id + 1, .from = knot.outPin(0), .to = l.to }) catch return;
                    app.next_id += 2;
                    break;
                };
            },
            .collapse => |id| if (app.nodeOf(id)) |n| {
                n.collapsed = !n.collapsed;
            },
            .delete => {
                var i: usize = 0;
                while (i < app.nodes.items.len) {
                    const n = app.nodes.items[i];
                    if (n.selected) {
                        var j: usize = 0;
                        while (j < app.links.items.len) {
                            const l = app.links.items[j];
                            if (l.from / 16 == n.id or l.to / 16 == n.id) _ = app.links.orderedRemove(j) else j += 1;
                        }
                        _ = app.nodes.orderedRemove(i);
                    } else i += 1;
                }
                app.commits += 1;
            },
            .duplicate, .copy => {
                app.clipboard.clearRetainingCapacity();
                for (app.nodes.items) |n| if (n.selected) app.clipboard.append(app.gpa, n) catch {};
                if (edit == .duplicate) app.paste(.{ .x = 30, .y = 30 }, true);
                if (edit == .copy) app.say("Copied {d} nodes", .{app.clipboard.items.len});
            },
            .paste => |at| {
                if (app.clipboard.items.len == 0) return;
                const first = app.clipboard.items[0].pos;
                app.paste(at.sub(first), false);
            },
            .move_frame => |m| app.frames[0].rect = .{ .x = app.frames[0].rect.x + m.delta.x, .y = app.frames[0].rect.y + m.delta.y, .w = app.frames[0].rect.w, .h = app.frames[0].rect.h },
            .resize_frame => |r| app.frames[0].rect = r.rect,
            .renamed_frame => app.say("Frame renamed", .{}),
            .commit => app.commits += 1,
        }
    }

    fn paste(app: *App, offset: zui.Vec2, _: bool) void {
        for (app.nodes.items) |*n| n.selected = false;
        for (app.clipboard.items) |c| {
            var n = c;
            n.id = app.next_id;
            app.next_id += 1;
            n.pos = c.pos.add(offset);
            n.selected = true;
            app.nodes.append(app.gpa, n) catch return;
        }
        app.commits += 1;
    }

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const colors = ui.style.colors;
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start });

        // The palette: drag an entry onto the editor.
        ui.beginVertical(.{ .width = .px(170), .height = .fill });
        ui.label("Palette", .{ .color = colors.text_muted });
        for (kinds, 0..) |k, i| _ = nodes.paletteItem(ui, k.name, i);
        ui.separator();
        if (ui.button("Align Tops", .{ .width = .fill }).clicked) app.align_request = .top;
        if (ui.button("Align Lefts", .{ .width = .fill }).clicked) app.align_request = .left;
        if (ui.button("Distribute Across", .{ .width = .fill }).clicked) app.distribute_request = true;
        if (ui.button("Add 200 Nodes", .{ .width = .fill }).clicked) {
            for (0..200) |i| _ = app.add(i % kinds.len, .{ .x = 1200 + @as(f32, @floatFromInt(i % 20)) * 200, .y = @as(f32, @floatFromInt(i / 20)) * 260 }) catch break;
        }
        ui.labelf("{d} nodes, {d} links", .{ app.nodes.items.len, app.links.items.len }, .{ .color = colors.text_muted });
        ui.labelf("Undo steps: {d}", .{app.commits}, .{ .color = colors.text_muted });
        ui.wrappedText(app.note[0..app.note_len], .{ .color = colors.warning });
        ui.endVertical();

        var g = nodes.begin(ui, "material", &app.editor, .{});
        for (&app.frames) |*f| g.frame(f.id, f.rect, .{ .title = f.title[0..f.len], .rename = .{ .buffer = &f.title, .len = &f.len } });
        for (app.nodes.items) |*n| {
            if (n.kind == reroute_kind) {
                g.reroute(n.id, n.pos, n.inPin(0), n.outPin(0), .{ .color = n.knot_type.tint() });
                continue;
            }
            const k = kinds[n.kind];
            var node = g.beginNode(n.id, n.pos, .{ .title = k.name, .color = category_colors[k.category], .selected = n.selected, .collapsed = n.collapsed, .width = if (n.kind == 1) 200 else 170 });
            for (k.outputs, 0..) |o, i| g.output(&node, n.outPin(i), o.label, .{ .color = o.type.tint() });
            if (k.preview) if (g.preview(&node, 70)) |r| {
                // A stand-in noise: stripes of grey.
                const cells: usize = 16;
                const w = r.w / @as(f32, @floatFromInt(cells));
                for (0..cells) |c| {
                    const v: u8 = @intCast(60 + (c * 97 + @as(usize, @intFromFloat(n.floats[0] * 40))) % 160);
                    ui.drawRect(.{ .rect = .{ .x = r.x + w * @as(f32, @floatFromInt(c)), .y = r.y, .w = w + 0.5, .h = r.h }, .fill = .{ .r = v, .g = v, .b = v } });
                }
            };
            var float_i: usize = 0;
            var color_i: usize = 0;
            for (k.inputs, 0..) |in, i| {
                if (g.beginInput(&node, n.inPin(i), in.label, .{ .color = in.type.tint(), .value = in.value })) {
                    switch (in.type) {
                        .float => _ = ui.numberField(in.label, &n.floats[@min(float_i, 3)], .{ .width = .fill, .min = 0, .max = 1, .slider = true, .decimals = 2 }),
                        .color => {
                            _ = ui.colorEdit(in.label, &n.colors[@min(color_i, 2)], .{ .alpha = false, .compact = true });
                        },
                        else => {},
                    }
                }
                if (in.type == .float) float_i += 1;
                if (in.type == .color) color_i += 1;
                g.endInput(&node);
            }
            g.endNode(&node);
        }
        for (app.links.items) |l| g.link(l.id, l.from, l.to);
        if (app.align_request) |how| g.alignSelected(how);
        if (app.distribute_request) g.distributeSelected(.horizontal);
        app.align_request = null;
        app.distribute_request = false;
        const edits = g.end();
        // Apply after describing: the lists may grow.
        var buffer: [512]nodes.Edit = undefined;
        const n = @min(edits.len, buffer.len);
        @memcpy(buffer[0..n], edits[0..n]);
        for (buffer[0..n]) |e| app.apply(ui, e);
        ui.endHorizontal();

        // The add menu, for Shift+A and wires dropped in empty space.
        var cats: [category_names.len]nodes.Category = undefined;
        var names: [category_names.len][kinds.len][]const u8 = undefined;
        var map: [category_names.len][kinds.len]usize = undefined;
        for (&cats, 0..) |*c, ci| {
            var count: usize = 0;
            for (kinds, 0..) |k, ki| if (k.category == ci) {
                names[ci][count] = k.name;
                map[ci][count] = ki;
                count += 1;
            };
            c.* = .{ .name = category_names[ci], .items = names[ci][0..count], .color = category_colors[ci] };
        }
        if (nodes.addMenu(ui, "Add", &cats, &app.add_menu)) |choice| {
            const kind = map[choice.category][choice.item];
            const i = app.add(kind, app.add_at) catch return;
            // A wire dropped here links to the first pin that fits.
            if (app.add_from) |from| {
                const t = app.pinType(from).?;
                const node = app.nodes.items[i];
                const from_output = from % 16 >= 8;
                const list = if (from_output) kinds[kind].inputs else kinds[kind].outputs;
                for (list, 0..) |p, pi| if (p.type.fits(t)) {
                    if (from_output) app.link(from, node.inPin(pi)) else app.link(node.outPin(pi), from);
                    break;
                };
            }
            app.say("Added {s}", .{kinds[kind].name});
            app.commits += 1;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = try .init(init.gpa);
    defer app.deinit();
    try harness.runUi(init, .{ .title = "Zui 24: nodes", .width = 1280, .height = 780 }, &app);
}
