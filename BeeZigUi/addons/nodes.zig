//! zui_nodes: a node-graph editor, for material and geometry nodes.
//!
//! Built only on Zui's public API. The graph stays the app's: describe its
//! nodes, pins and links each frame; the editor draws them, handles the
//! mouse and keys, and reports what the user did as a list of edits for the
//! app to apply (and to make undo steps of).
//!
//!     var editor: nodes.Editor = .init(gpa);
//!     defer editor.deinit();
//!
//!     var g = nodes.begin(ui, "material", &editor, .{});
//!     for (graph.frames) |*f| g.frame(f.id, f.rect, .{ .title = f.name });
//!     for (graph.nodes) |*n| {
//!         var node = g.beginNode(n.id, n.pos, .{ .title = n.name, .color = n.color, .selected = n.selected, .collapsed = n.collapsed });
//!         if (g.beginInput(&node, n.pin_roughness, "Roughness", .{ .color = float_color, .value = true }))
//!             _ = ui.numberField("Roughness", &n.roughness, .{ .width = .fill, .slider = true, .min = 0, .max = 1 });
//!         g.endInput(&node);
//!         g.output(&node, n.pin_bsdf, "BSDF", .{ .color = shader_color });
//!         g.endNode(&node);
//!     }
//!     for (graph.links) |l| g.link(l.id, l.from, l.to);
//!     for (g.end()) |edit| apply(edit);
//!
//! Drag from a pin to link (dropping in empty space reports `add`, to ask
//! what to add there); drag a linked input to take its link off. Double-
//! click a wire for a reroute knot; Alt+click cuts a wire, Alt+drag cuts
//! every wire crossed. Click or box-select nodes (Shift adds, Ctrl
//! removes); moving one selected node moves all. X or Delete deletes,
//! Shift+D duplicates, Ctrl+C and Ctrl+V copy and paste, Shift+A asks for
//! the add menu, Home fits; zoom from 25 to 200 % with sharp text.

const std = @import("std");
const zui = @import("zui");
const Ui = zui.Ui;
const Id = zui.Id;
const Rect = zui.Rect;
const Vec2 = zui.Vec2;
const Color = zui.Color;
const Allocator = std.mem.Allocator;

/// Something the user did, for the app to apply to its graph.
pub const Edit = union(enum) {
    /// Move this node by `delta` (world units).
    move: struct { node: u64, delta: Vec2 },
    /// Select or deselect this node.
    select: struct { node: u64, selected: bool },
    /// Link an output pin to an input pin. The app decides whether the
    /// types fit; an input has one link, so replace any old one.
    link: struct { from: u64, to: u64 },
    /// Remove this link.
    unlink: u64,
    /// A link dropped in empty space, or Shift+A, or a palette entry
    /// dropped on the canvas: offer to add a node at `pos`. `from` is the
    /// pin the wire came from; `data` the palette entry's.
    add: struct { pos: Vec2, from: ?u64 = null, data: ?u64 = null },
    /// Split this link with a reroute knot at `pos`.
    reroute: struct { link: u64, pos: Vec2 },
    /// Fold or unfold this node to its header.
    collapse: u64,
    /// Delete the selected nodes.
    delete,
    /// Duplicate the selected nodes.
    duplicate,
    /// Copy the selected nodes.
    copy,
    /// Paste at `pos`.
    paste: Vec2,
    /// Move this comment frame by `delta` (its nodes get `move` edits).
    move_frame: struct { frame: u64, delta: Vec2 },
    /// The comment frame's new rect, after a resize.
    resize_frame: struct { frame: u64, rect: Rect },
    /// The frame's title was edited (in the app's buffer) and is done.
    renamed_frame: u64,
    /// A drag of nodes, a frame, or a cut ended: one undo step.
    commit,
};

/// Options for `begin`.
pub const Options = struct {
    width: zui.Size = .fill,
    height: zui.Size = .fill,
    /// Show a minimap in the corner.
    minimap: bool = true,
    background: ?Color = null,
};

/// Options for `beginNode`.
pub const NodeOptions = struct {
    title: []const u8,
    /// The header's colour: the node's category.
    color: Color = Color.hex(0x4A5060),
    /// Width in world units (screen units at 100 %).
    width: f32 = 170,
    selected: bool = false,
    /// Folded to its header: pins sit on its edges, rows aren't shown.
    collapsed: bool = false,
};

/// Options for a pin.
pub const PinOptions = struct {
    /// The pin's and its wires' colour: the socket type.
    color: Color = Color.hex(0xA1A1A1),
    /// For inputs: the app shows a value field when it isn't linked.
    value: bool = false,
};

/// Options for `frame`.
pub const FrameOptions = struct {
    title: []const u8 = "",
    color: Color = Color.hex(0x3D4A5C),
    /// While renaming: the title's buffer and length, edited in place.
    rename: ?struct { buffer: []u8, len: *usize } = null,
};

const Pin = struct {
    node: u64,
    pos: Vec2,
    color: Color,
    output: bool,
    label: []const u8,
};

const NodeInfo = struct {
    id: u64,
    rect: Rect,
    world: Rect,
    selected: bool,
};

const LinkInfo = struct { id: u64, from: u64 };

const FrameInfo = struct { id: u64, world: Rect, title_h: f32 };

const Drag = union(enum) {
    none,
    /// A wire from this pin, following the pointer.
    link: struct { from: u64, output: bool, detached: ?u64 },
    /// Nodes, by the one pressed.
    nodes: struct { node: u64, moved: bool },
    /// The knife's path, in world units.
    knife,
    frame_move: struct { frame: u64, moved: bool },
    frame_size: struct { frame: u64, start: Rect },
};

/// The editor's own state, kept by the app: one per editor area.
pub const Editor = struct {
    gpa: Allocator,
    view: zui.View2D = .{},
    pins: std.AutoHashMapUnmanaged(u64, Pin) = .empty,
    /// This frame's links, by input pin; and last frame's, for taking a
    /// link off an input while nodes are described.
    links: std.AutoHashMapUnmanaged(u64, LinkInfo) = .empty,
    last_links: std.AutoHashMapUnmanaged(u64, LinkInfo) = .empty,
    /// Wires as drawn, for hit testing: id and its curve's points.
    curves: std.ArrayList(Curve) = .empty,
    nodes: std.ArrayList(NodeInfo) = .empty,
    last_nodes: std.ArrayList(NodeInfo) = .empty,
    frames: std.ArrayList(FrameInfo) = .empty,
    heights: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    edits: std.ArrayList(Edit) = .empty,
    knife: std.ArrayList(Vec2) = .empty,
    drag: Drag = .none,
    /// The node a press landed on (topmost at the pointer last frame).
    under: ?u64 = null,
    /// A frame whose title is being edited.
    renaming: ?u64 = null,
    /// Give the title field focus on the next frame.
    rename_focus: bool = false,
    /// The world point where the last drag frame step was.
    last_world: Vec2 = .{},

    /// An editor that allocates from `gpa`. Pair with `deinit`.
    pub fn init(gpa: Allocator) Editor {
        return .{ .gpa = gpa };
    }

    /// Frees all memory.
    pub fn deinit(self: *Editor) void {
        self.pins.deinit(self.gpa);
        self.links.deinit(self.gpa);
        self.last_links.deinit(self.gpa);
        self.curves.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.last_nodes.deinit(self.gpa);
        self.frames.deinit(self.gpa);
        self.heights.deinit(self.gpa);
        self.edits.deinit(self.gpa);
        self.knife.deinit(self.gpa);
    }
};

const Curve = struct {
    id: u64,
    points: [curve_points]Vec2,
};

const curve_points = 17;
const min_zoom = 0.25;
const max_zoom = 2.0;
const drag_kind = "zui_nodes.add";

/// A node being described, from `beginNode`.
pub const Node = struct {
    id: u64,
    /// Where it is on screen.
    rect: Rect,
    header: Rect,
    collapsed: bool,
    region: Id,
    /// Pins placed on the folded header so far, per side.
    inputs: u32 = 0,
    outputs: u32 = 0,
    pending_pin: ?struct { id: u64, label: []const u8, options: PinOptions } = null,
    title: []const u8 = "",
};

/// The graph being described, from `begin`.
pub const Graph = struct {
    ui: *Ui,
    ed: *Editor,
    v: zui.ViewFrame,
    zoom: f32,
    options: Options,

    fn fail(g: *Graph, err: Allocator.Error) void {
        g.ui.fail(err);
    }

    fn emit(g: *Graph, e: Edit) void {
        g.ed.edits.append(g.ed.gpa, e) catch |err| g.fail(err);
    }

    /// A comment frame at `world` (world units), behind the nodes. Call
    /// before the nodes. Drag its title to move it with the nodes inside,
    /// its corner to resize; double-click the title to rename it.
    pub fn frame(g: *Graph, id: u64, world: Rect, options: FrameOptions) void {
        const ui = g.ui;
        const r = g.v.rectToScreen(world);
        const style = &ui.style;
        const title_h = ui.textSize("").y + style.frame_padding.y * 2;
        g.ed.frames.append(g.ed.gpa, .{ .id = id, .world = world, .title_h = title_h / g.zoom }) catch |err| return g.fail(err);
        ui.drawRect(.{ .rect = r, .fill = options.color.withAlpha(90), .border = options.color, .border_width = 1, .radius = style.rounding });
        const title: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = title_h };
        if (g.ed.renaming == id) if (options.rename) |rename| {
            ui.beginRegion(ui.id("##rename"), title.inset(2), .horizontal, 0, .center);
            ui.pushIdInt(id);
            const field = ui.id("Frame title");
            const first = g.ed.rename_focus;
            if (first) ui.setFocus(field);
            g.ed.rename_focus = false;
            const t = ui.textInput("Frame title", rename.buffer, rename.len, .{ .width = .fill });
            ui.popId();
            ui.endRegion();
            if (t.submitted or t.cancelled or (!first and !t.focused)) {
                g.ed.renaming = null;
                g.emit(.{ .renamed_frame = id });
            }
            return;
        };
        ui.pushClip(title);
        ui.drawText(.{ .x = r.x + style.frame_padding.x, .y = r.y + style.frame_padding.y }, style.colors.text, options.title);
        ui.popClip();
        const p = g.v.painter;
        const c: Vec2 = .{ .x = r.right() - 4, .y = r.bottom() - 4 };
        p.line(.{ .x = c.x - 10, .y = c.y }, .{ .x = c.x, .y = c.y - 10 }, style.colors.text_muted, 1);
        p.line(.{ .x = c.x - 5, .y = c.y }, .{ .x = c.x, .y = c.y - 5 }, style.colors.text_muted, 1);
        ui.recordWidget(.node_frame, .none, options.title, title, .{});
    }

    /// Starts a node with its top-left at `pos` (world units). Describe
    /// its pins and rows, then call `endNode`.
    pub fn beginNode(g: *Graph, id: u64, pos: Vec2, options: NodeOptions) Node {
        const ui = g.ui;
        const style = &ui.style;
        const colors = &style.colors;
        const tl = g.v.toScreen(pos);
        const w = options.width * g.zoom;
        const header_h = ui.textSize("").y + style.frame_padding.y * 2;
        const pad = style.frame_padding.y;
        const body_h: f32 = if (options.collapsed) 0 else (g.ed.heights.get(id) orelse 40 * g.zoom) + 2 * pad;
        const rect: Rect = .{ .x = tl.x, .y = tl.y, .w = w, .h = header_h + body_h };
        const header: Rect = .{ .x = tl.x, .y = tl.y, .w = w, .h = header_h };
        const world: Rect = .{ .x = pos.x, .y = pos.y, .w = options.width, .h = rect.h / g.zoom };
        g.ed.nodes.append(g.ed.gpa, .{ .id = id, .rect = rect, .world = world, .selected = options.selected }) catch |err| g.fail(err);

        const r = style.rounding;
        ui.drawShadow(rect, r, colors.window);
        ui.drawRect(.{ .rect = rect, .fill = colors.window, .radius = r });
        ui.drawRect(.{ .rect = header, .fill = options.color, .radius = r });
        if (!options.collapsed) ui.drawRect(.{ .rect = .{ .x = header.x, .y = header.bottom() - r, .w = header.w, .h = r }, .fill = options.color });
        ui.drawRect(.{ .rect = rect, .border = if (options.selected) colors.accent else colors.border, .border_width = if (options.selected) 2 else 1, .radius = r });
        // The fold arrow and the title.
        const line_h = ui.textSize("").y;
        const ink = zui.color.textOn(options.color);
        const arrow: Rect = .{ .x = header.x + 4, .y = header.y + (header_h - line_h) / 2, .w = line_h, .h = line_h };
        g.v.painter.icon(.{ .builtin = if (options.collapsed) .chevron_right else .chevron_down }, arrow, ink);
        ui.pushClip(header);
        ui.drawText(.{ .x = arrow.right() + 2, .y = header.y + style.frame_padding.y }, ink, options.title);
        ui.popClip();
        ui.pushIdInt(id);
        const region = ui.id("##body");
        const node: Node = .{ .id = id, .rect = rect, .header = header, .collapsed = options.collapsed, .region = region, .title = options.title };
        ui.recordWidget(.node, .none, options.title, header, .{ .value = if (options.selected) "selected" else "" });
        if (!options.collapsed) {
            ui.beginRegion(region, .{ .x = rect.x, .y = header.bottom(), .w = w, .h = @max(body_h, 600 * g.zoom) }, .vertical, pad, .start);
        }
        return node;
    }

    /// An input row: its pin on the left. Returns true when the app should
    /// show a value field for it (it has `value` and isn't linked); place
    /// the field, then call `endInput`. Otherwise the row shows the label.
    pub fn beginInput(g: *Graph, node: *Node, pin: u64, label: []const u8, options: PinOptions) bool {
        const ui = g.ui;
        node.pending_pin = .{ .id = pin, .label = label, .options = options };
        if (node.collapsed) return false;
        ui.beginHorizontal(.{ .id = label });
        const linked = g.ed.last_links.contains(pin);
        if (options.value and !linked) return true;
        ui.label(label, .{});
        return false;
    }

    /// Ends the row from `beginInput`.
    pub fn endInput(g: *Graph, node: *Node) void {
        const p = node.pending_pin orelse return;
        node.pending_pin = null;
        var y: f32 = undefined;
        if (node.collapsed) {
            y = node.header.y + node.header.h / 2;
            node.inputs += 1;
        } else {
            g.ui.endHorizontal();
            const row = g.ui.lastRect();
            y = row.y + row.h / 2;
        }
        g.pinWidget(node, p.id, p.label, .{ .x = node.rect.x, .y = y }, p.options.color, false);
    }

    /// An output row: label on the right, pin on the right edge.
    pub fn output(g: *Graph, node: *Node, pin: u64, label: []const u8, options: PinOptions) void {
        var y: f32 = undefined;
        if (node.collapsed) {
            y = node.header.y + node.header.h / 2;
            node.outputs += 1;
        } else {
            const ui = g.ui;
            ui.beginHorizontal(.{ .id = label, .justify = .end });
            ui.label(label, .{});
            ui.endHorizontal();
            const row = ui.lastRect();
            y = row.y + row.h / 2;
        }
        g.pinWidget(node, pin, label, .{ .x = node.rect.right(), .y = y }, options.color, true);
    }

    /// Space for a preview the app paints itself, `height` world units
    /// tall; null when the node is folded.
    pub fn preview(g: *Graph, node: *Node, height: f32) ?Rect {
        if (node.collapsed) return null;
        return g.ui.placeSized(.fill, .{ .fixed = height * g.zoom }, .{ .x = 10, .y = height * g.zoom });
    }

    fn pinWidget(g: *Graph, node: *Node, pin: u64, label: []const u8, pos: Vec2, color: Color, out: bool) void {
        const ui = g.ui;
        g.ed.pins.put(g.ed.gpa, pin, .{ .node = node.id, .pos = pos, .color = color, .output = out, .label = label }) catch |err| return g.fail(err);
        const r = 5 * g.zoom;
        const grab = r + 5;
        // Pins sit on the node's edge, outside its clip.
        ui.pushClipAbsolute(g.v.rect);
        defer ui.popClip();
        ui.pushIdInt(pin);
        const widget = ui.id("##pin");
        ui.popId();
        const item = ui.interact(widget, .{ .x = pos.x - grab, .y = pos.y - grab, .w = 2 * grab, .h = 2 * grab });
        if (item.pressed) {
            const in_link = if (!out) g.ed.last_links.get(pin) else null;
            if (in_link) |l| {
                // Take the link off the input and carry it from its output.
                g.ed.drag = .{ .link = .{ .from = l.from, .output = true, .detached = l.id } };
            } else {
                g.ed.drag = .{ .link = .{ .from = pin, .output = out, .detached = null } };
            }
        }
        // One rounded rect with a dark border: drawn as spans, much cheaper
        // than two anti-aliased circles.
        const pr = if (item.hovered) r + 1 else r;
        const ring = 1.5;
        ui.drawRect(.{
            .rect = .{ .x = pos.x - pr - ring, .y = pos.y - pr - ring, .w = 2 * (pr + ring), .h = 2 * (pr + ring) },
            .fill = color,
            .border = Color.black.withAlpha(170),
            .border_width = ring,
            .radius = pr + ring,
        });
        var buffer: [96]u8 = undefined;
        const name = std.fmt.bufPrint(&buffer, "{s}.{s}", .{ node.title, label }) catch label;
        ui.recordWidget(.pin, widget, name, .{ .x = pos.x - grab, .y = pos.y - grab, .w = 2 * grab, .h = 2 * grab }, .{ .hovered = item.hovered, .value = if (out) "output" else "input" });
    }

    /// Ends the node: measures its rows and makes it draggable by any
    /// part no row widget took.
    pub fn endNode(g: *Graph, node: *Node) void {
        const ui = g.ui;
        if (!node.collapsed) {
            ui.endRegion();
            if (ui.regionSize(node.region)) |size| {
                const h = size.y;
                const old = g.ed.heights.get(node.id);
                if (old == null or @abs(old.? - h) > 0.5) {
                    g.ed.heights.put(g.ed.gpa, node.id, h) catch |err| g.fail(err);
                    ui.requestRedraw();
                }
            }
        }
        // The fold arrow, then the node itself.
        const line_h = ui.textSize("").y;
        const arrow: Rect = .{ .x = node.header.x, .y = node.header.y, .w = line_h + 8, .h = node.header.h };
        const fold = ui.interact(ui.id("##fold"), arrow);
        if (fold.clicked) g.emit(.{ .collapse = node.id });
        const top = g.ed.under == null or g.ed.under.? == node.id;
        if (top) {
            const item = ui.interact(ui.id("##node"), node.rect);
            if (item.pressed) {
                g.ed.drag = .{ .nodes = .{ .node = node.id, .moved = false } };
                g.ed.last_world = g.v.toWorld(ui.input.press_pos.get(.left));
                pressSelect(g, node.id);
            }
            if (item.held) ui.cursor = .move;
        }
        ui.popId();
    }

    /// A reroute knot at `pos` (world units): one input and one output.
    pub fn reroute(g: *Graph, id: u64, pos: Vec2, in_pin: u64, out_pin: u64, options: PinOptions) void {
        const s = g.v.toScreen(pos);
        const r = 4 * g.zoom;
        var node: Node = .{ .id = id, .rect = .{ .x = s.x - r, .y = s.y - r, .w = 2 * r, .h = 2 * r }, .header = .{ .x = s.x - r, .y = s.y - r, .w = 2 * r, .h = 2 * r }, .collapsed = true, .region = .none, .title = "Reroute" };
        g.ed.nodes.append(g.ed.gpa, .{ .id = id, .rect = node.rect, .world = .{ .x = pos.x - r / g.zoom, .y = pos.y - r / g.zoom, .w = 2 * r / g.zoom, .h = 2 * r / g.zoom }, .selected = false }) catch |err| g.fail(err);
        g.ui.pushIdInt(id);
        defer g.ui.popId();
        g.pinWidget(&node, in_pin, "in", .{ .x = s.x - 0.01, .y = s.y }, options.color, false);
        g.pinWidget(&node, out_pin, "out", .{ .x = s.x + 0.01, .y = s.y }, options.color, true);
    }

    /// A link from output pin `from` to input pin `to`. Call after the
    /// nodes, so the pins are known. The graph is the app's: the editor
    /// draws and edits whatever links it is given, and doesn't refuse a link
    /// from a node to itself or one that closes a cycle. An app whose graphs
    /// must stay acyclic checks the `.link` edits it gets before applying them.
    pub fn link(g: *Graph, id: u64, from: u64, to: u64) void {
        const a = g.ed.pins.get(from) orelse return;
        const b = g.ed.pins.get(to) orelse return;
        g.ed.links.put(g.ed.gpa, to, .{ .id = id, .from = from }) catch |err| return g.fail(err);
        // Being carried off its input: not drawn where it was.
        if (g.ed.drag == .link) if (g.ed.drag.link.detached) |d| if (d == id) return;
        var curve: Curve = .{ .id = id, .points = undefined };
        bezierPoints(a.pos, b.pos, g.zoom, &curve.points);
        g.ed.curves.append(g.ed.gpa, curve) catch |err| return g.fail(err);
        const hovered = g.ui.input.modifiers.alt and hitCurve(&curve.points, g.ui.input.mouse_pos, 5);
        drawWire(g, a.pos, b.pos, a.color, b.color, hovered);
        const mid = curve.points[curve_points / 2];
        var buffer: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&buffer, "{s} -> {s}", .{ a.label, b.label }) catch "link";
        g.ui.recordWidget(.link, .none, name, .{ .x = mid.x - 4, .y = mid.y - 4, .w = 8, .h = 8 }, .{});
    }

    /// Moves the selected nodes so their edges or centres line up.
    pub fn alignSelected(g: *Graph, how: Align) void {
        var lo: f32 = std.math.inf(f32);
        var hi: f32 = -std.math.inf(f32);
        var n: usize = 0;
        for (g.ed.nodes.items) |info| if (info.selected) {
            const w = info.world;
            const v = switch (how) {
                .left => w.x,
                .right => w.right(),
                .top => w.y,
                .bottom => w.bottom(),
                .center_x => w.x + w.w / 2,
                .center_y => w.y + w.h / 2,
            };
            lo = @min(lo, v);
            hi = @max(hi, v);
            n += 1;
        };
        if (n < 2) return;
        const target = switch (how) {
            .left, .top => lo,
            .right, .bottom => hi,
            .center_x, .center_y => (lo + hi) / 2,
        };
        for (g.ed.nodes.items) |info| if (info.selected) {
            const w = info.world;
            const delta: Vec2 = switch (how) {
                .left => .{ .x = target - w.x },
                .right => .{ .x = target - w.right() },
                .center_x => .{ .x = target - (w.x + w.w / 2) },
                .top => .{ .y = target - w.y },
                .bottom => .{ .y = target - w.bottom() },
                .center_y => .{ .y = target - (w.y + w.h / 2) },
            };
            if (delta.x != 0 or delta.y != 0) g.emit(.{ .move = .{ .node = info.id, .delta = delta } });
        };
        g.emit(.commit);
    }

    /// Spaces the selected nodes evenly, across or down, keeping the
    /// outermost two where they are. Up to 256 nodes; with more selected,
    /// it spaces the first 256 it finds.
    pub fn distributeSelected(g: *Graph, axis: zui.Axis) void {
        var picked: [256]NodeInfo = undefined;
        var n: usize = 0;
        for (g.ed.nodes.items) |info| if (info.selected and n < picked.len) {
            picked[n] = info;
            n += 1;
        };
        if (n < 3) return;
        const horizontal = axis == .horizontal;
        std.mem.sort(NodeInfo, picked[0..n], horizontal, struct {
            fn less(h: bool, a: NodeInfo, b: NodeInfo) bool {
                return if (h) a.world.x < b.world.x else a.world.y < b.world.y;
            }
        }.less);
        var total: f32 = 0;
        for (picked[0..n]) |p| total += if (horizontal) p.world.w else p.world.h;
        const first = picked[0].world;
        const last = picked[n - 1].world;
        const span = if (horizontal) last.right() - first.x else last.bottom() - first.y;
        const gap = (span - total) / @as(f32, @floatFromInt(n - 1));
        var at = if (horizontal) first.x else first.y;
        for (picked[0..n]) |p| {
            const now = if (horizontal) p.world.x else p.world.y;
            const d = at - now;
            if (@abs(d) > 0.01) g.emit(.{ .move = .{ .node = p.id, .delta = if (horizontal) .{ .x = d } else .{ .y = d } } });
            at += (if (horizontal) p.world.w else p.world.h) + gap;
        }
        g.emit(.commit);
    }

    /// Ends the graph: wires being dragged, the knife, box selection,
    /// keys, frames and drops. Returns this frame's edits, valid until the
    /// next `begin`.
    pub fn end(g: *Graph) []const Edit {
        const ui = g.ui;
        const ed = g.ed;
        const in = &ui.input;
        const colors = &ui.style.colors;
        const mouse = in.mouse_pos;

        // A wire being dragged: to the pin under the pointer, or loose.
        if (ed.drag == .link) {
            const d = ed.drag.link;
            const from = ed.pins.get(d.from);
            // From an output, look for an input, and the other way round.
            const target = pinAt(g, mouse, d.output);
            if (from) |a| {
                const end_pos = if (target) |t| ed.pins.get(t).?.pos else mouse;
                if (d.output) drawWire(g, a.pos, end_pos, a.color, a.color, false) else drawWire(g, end_pos, a.pos, a.color, a.color, false);
            }
            if (!in.mouse_down.contains(.left) or in.mouse_released.contains(.left)) {
                if (d.detached) |l| g.emit(.{ .unlink = l });
                if (target) |t| {
                    if (d.output) g.emit(.{ .link = .{ .from = d.from, .to = t } }) else g.emit(.{ .link = .{ .from = t, .to = d.from } });
                } else if (d.detached == null) {
                    g.emit(.{ .add = .{ .pos = g.v.toWorld(mouse), .from = d.from } });
                }
                g.emit(.commit);
                ed.drag = .none;
            } else if (in.keys_pressed.contains(.escape)) {
                in.keys_pressed.remove(.escape);
                ed.drag = .none;
            }
            ui.cursor = .crosshair;
            ui.requestRedraw();
        }

        // Moving nodes: the pressed one, and all selected if it is.
        if (ed.drag == .nodes) {
            const d = ed.drag.nodes;
            const now = g.v.toWorld(mouse);
            const delta = now.sub(ed.last_world);
            ed.last_world = now;
            if (delta.x != 0 or delta.y != 0) {
                var pressed_selected = false;
                for (ed.nodes.items) |info| if (info.id == d.node) {
                    pressed_selected = info.selected;
                };
                for (ed.nodes.items) |info| {
                    if (info.id == d.node or (pressed_selected and info.selected)) g.emit(.{ .move = .{ .node = info.id, .delta = delta } });
                }
                ed.drag.nodes.moved = true;
                ui.requestRedraw();
            }
            if (!in.mouse_down.contains(.left)) {
                if (ed.drag.nodes.moved) g.emit(.commit);
                ed.drag = .none;
            }
        }

        g.frameInteractions();

        // Wires under a press: Alt cuts one, a double click adds a knot.
        if (in.mouse_pressed.contains(.left) and ed.drag == .none and g.v.rect.contains(in.press_pos.get(.left)) and ui.hovered_window == ui.current_window) {
            const at = in.press_pos.get(.left);
            const on_node = for (ed.nodes.items) |info| {
                if (info.rect.contains(at)) break true;
            } else false;
            if (!on_node) {
                var hit: ?Curve = null;
                for (ed.curves.items) |c| if (hitCurve(&c.points, at, 5)) {
                    hit = c;
                };
                if (in.modifiers.alt) {
                    in.mouse_pressed.remove(.left);
                    if (hit) |c| {
                        g.emit(.{ .unlink = c.id });
                        g.emit(.commit);
                    } else {
                        ed.drag = .knife;
                        ed.knife.clearRetainingCapacity();
                        ed.knife.append(ed.gpa, g.v.toWorld(at)) catch |err| g.fail(err);
                    }
                } else if (hit != null and in.press_clicks.get(.left) == 2) {
                    in.mouse_pressed.remove(.left);
                    g.emit(.{ .reroute = .{ .link = hit.?.id, .pos = g.v.toWorld(at) } });
                    g.emit(.commit);
                }
            }
        }
        if (ed.drag == .knife) {
            const w = g.v.toWorld(mouse);
            const last = ed.knife.items[ed.knife.items.len - 1];
            if (ed.knife.items.len < 256 and g.v.toScreen(last).sub(mouse).length() > 4) ed.knife.append(ed.gpa, w) catch |err| g.fail(err);
            var screen: [256]Vec2 = undefined;
            for (ed.knife.items, 0..) |p, i| screen[i] = g.v.toScreen(p);
            g.v.painter.polyline(screen[0..ed.knife.items.len], colors.warning, 1.5, false);
            ui.cursor = .crosshair;
            ui.requestRedraw();
            if (!in.mouse_down.contains(.left)) {
                var cut = false;
                for (ed.curves.items) |c| {
                    if (crosses(&c.points, screen[0..ed.knife.items.len])) {
                        g.emit(.{ .unlink = c.id });
                        cut = true;
                    }
                }
                if (cut) g.emit(.commit);
                ed.drag = .none;
            }
        }

        // Palette entries dropped on the canvas.
        if (ui.dropZone(g.v.rect, drag_kind)) |drop| {
            ui.dropHint("Add here");
            if (drop.released) g.emit(.{ .add = .{ .pos = g.v.toWorld(mouse), .data = drop.data } });
        }

        // Keys, over the editor.
        if (g.v.hovered or (ui.hovered_window == ui.current_window and g.v.rect.contains(mouse))) if (!ui.wantsKeyboard()) {
            const Shortcut = zui.Shortcut;
            if ((Shortcut{ .key = .x }).pressed(in) or (Shortcut{ .key = .delete }).pressed(in)) g.emit(.delete);
            if ((Shortcut{ .key = .d, .modifiers = .{ .shift = true } }).pressed(in)) g.emit(.duplicate);
            if ((Shortcut{ .key = .c, .modifiers = .{ .ctrl = true } }).pressed(in)) g.emit(.copy);
            if ((Shortcut{ .key = .v, .modifiers = .{ .ctrl = true } }).pressed(in)) g.emit(.{ .paste = g.v.toWorld(mouse) });
            if ((Shortcut{ .key = .a, .modifiers = .{ .shift = true } }).pressed(in)) g.emit(.{ .add = .{ .pos = g.v.toWorld(mouse) } });
        };

        if (g.options.minimap and ed.nodes.items.len > 0) {
            const bounds = contentBounds(ed);
            const m = ui.beginMinimap(g.v, bounds);
            for (ed.nodes.items) |info| ui.drawRect(.{ .rect = m.rectToMap(info.world), .fill = if (info.selected) colors.accent else colors.text_muted.withAlpha(140) });
            ui.endMinimap(g.v, m);
        }

        ui.popStyle();
        const result = ui.endView2D();
        // Box selection from the view; a click on empty space clears.
        if (result.box) |box| {
            for (ed.nodes.items) |info| {
                const inside = info.world.intersect(box.rect).w > 0 and info.world.intersect(box.rect).h > 0;
                const now = switch (box.mode) {
                    .set => inside,
                    .add => info.selected or inside,
                    .remove => info.selected and !inside,
                };
                if (now != info.selected) g.emit(.{ .select = .{ .node = info.id, .selected = now } });
            }
        } else if (result.clicked != null and !in.modifiers.shift) {
            for (ed.nodes.items) |info| if (info.selected) g.emit(.{ .select = .{ .node = info.id, .selected = false } });
        }
        // Inputs show their fields by last frame's links: when the links
        // changed, one more frame shows them right.
        if (ed.edits.items.len > 0 or !sameLinks(ed)) ui.requestRedraw();
        return ed.edits.items;
    }

    fn frameInteractions(g: *Graph) void {
        const ui = g.ui;
        const ed = g.ed;
        const in = &ui.input;
        for (ed.frames.items) |f| {
            const r = g.v.rectToScreen(f.world);
            ui.pushIdInt(f.id);
            defer ui.popId();
            const corner: Rect = .{ .x = r.right() - 14, .y = r.bottom() - 14, .w = 14, .h = 14 };
            const size = ui.interact(ui.id("##frame size"), corner);
            if (size.pressed) ed.drag = .{ .frame_size = .{ .frame = f.id, .start = f.world } };
            if (size.hovered or size.held) ui.cursor = .resize_nwse;
            const title = ui.interact(ui.id("##frame title"), .{ .x = r.x, .y = r.y, .w = r.w, .h = f.title_h * g.zoom });
            if (title.pressed) {
                if (in.press_clicks.get(.left) == 2) {
                    ed.renaming = f.id;
                    ed.rename_focus = true;
                    ui.active = .none;
                    ui.requestRedraw();
                } else {
                    ed.drag = .{ .frame_move = .{ .frame = f.id, .moved = false } };
                    ed.last_world = g.v.toWorld(in.press_pos.get(.left));
                }
            }
        }
        switch (ed.drag) {
            .frame_move => |d| {
                const now = g.v.toWorld(in.mouse_pos);
                const delta = now.sub(ed.last_world);
                ed.last_world = now;
                if (delta.x != 0 or delta.y != 0) {
                    for (ed.frames.items) |f| if (f.id == d.frame) {
                        g.emit(.{ .move_frame = .{ .frame = f.id, .delta = delta } });
                        for (ed.nodes.items) |info| {
                            const w = info.world;
                            if (w.x >= f.world.x and w.y >= f.world.y and w.right() <= f.world.right() and w.bottom() <= f.world.bottom()) {
                                g.emit(.{ .move = .{ .node = info.id, .delta = delta } });
                            }
                        }
                    };
                    ed.drag.frame_move.moved = true;
                }
                ui.cursor = .move;
                if (!in.mouse_down.contains(.left)) {
                    if (ed.drag.frame_move.moved) g.emit(.commit);
                    ed.drag = .none;
                }
            },
            .frame_size => |d| {
                const now = g.v.toWorld(in.mouse_pos);
                var r = d.start;
                r.w = @max(80, now.x - r.x);
                r.h = @max(60, now.y - r.y);
                g.emit(.{ .resize_frame = .{ .frame = d.frame, .rect = r } });
                ui.cursor = .resize_nwse;
                if (!in.mouse_down.contains(.left)) {
                    g.emit(.commit);
                    ed.drag = .none;
                }
            },
            else => {},
        }
    }
};

/// How `alignSelected` lines nodes up.
pub const Align = enum { left, right, top, bottom, center_x, center_y };

/// Starts the node editor `name`. Describe frames, then nodes, then links,
/// then call `Graph.end`.
pub fn begin(ui: *Ui, name: []const u8, ed: *Editor, options: Options) Graph {
    // Last frame's nodes decide which one a press lands on: the topmost.
    std.mem.swap(std.ArrayList(NodeInfo), &ed.nodes, &ed.last_nodes);
    ed.nodes.clearRetainingCapacity();
    std.mem.swap(std.AutoHashMapUnmanaged(u64, LinkInfo), &ed.links, &ed.last_links);
    ed.links.clearRetainingCapacity();
    ed.pins.clearRetainingCapacity();
    ed.curves.clearRetainingCapacity();
    ed.frames.clearRetainingCapacity();
    ed.edits.clearRetainingCapacity();
    ed.under = null;
    if (ui.input.mouse_pressed.contains(.left)) {
        const at = ui.input.press_pos.get(.left);
        var i = ed.last_nodes.items.len;
        while (i > 0) {
            i -= 1;
            if (ed.last_nodes.items[i].rect.contains(at)) {
                ed.under = ed.last_nodes.items[i].id;
                break;
            }
        }
    }

    const content = if (ed.last_nodes.items.len > 0) contentBounds(ed) else Rect{ .x = 0, .y = 0, .w = 800, .h = 500 };
    const v = ui.beginView2D(name, &ed.view, .{
        .width = options.width,
        .height = options.height,
        .min_zoom = .{ .x = min_zoom, .y = min_zoom },
        .max_zoom = .{ .x = max_zoom, .y = max_zoom },
        .keep_aspect = true,
        .content = content,
        .background = options.background,
    });
    if (ed.view.follow_fit and ed.view.zoom.x > 1) {
        // Fitting a small graph: no closer than 100 %.
        ed.view.zoom = .{ .x = 1, .y = 1 };
    }
    const zoom = ed.view.zoom.x;
    ui.pushStyle(ui.style.scaled(zoom));
    return .{ .ui = ui, .ed = ed, .v = v, .zoom = zoom, .options = options };
}

fn sameLinks(ed: *const Editor) bool {
    if (ed.links.count() != ed.last_links.count()) return false;
    var it = ed.links.iterator();
    while (it.next()) |e| {
        const old = ed.last_links.get(e.key_ptr.*) orelse return false;
        if (old.id != e.value_ptr.id) return false;
    }
    return true;
}

fn contentBounds(ed: *const Editor) Rect {
    const list = if (ed.nodes.items.len > 0) ed.nodes.items else ed.last_nodes.items;
    if (list.len == 0) return .{ .w = 800, .h = 500 };
    var lo: Vec2 = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) };
    var hi: Vec2 = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32) };
    for (list) |info| {
        lo = .{ .x = @min(lo.x, info.world.x), .y = @min(lo.y, info.world.y) };
        hi = .{ .x = @max(hi.x, info.world.right()), .y = @max(hi.y, info.world.bottom()) };
    }
    for (ed.frames.items) |f| {
        lo = .{ .x = @min(lo.x, f.world.x), .y = @min(lo.y, f.world.y) };
        hi = .{ .x = @max(hi.x, f.world.right()), .y = @max(hi.y, f.world.bottom()) };
    }
    return .{ .x = lo.x - 20, .y = lo.y - 20, .w = hi.x - lo.x + 40, .h = hi.y - lo.y + 40 };
}

fn pressSelect(g: *Graph, id: u64) void {
    const shift = g.ui.input.modifiers.shift;
    // This node's flag is known; others' come from last frame's list.
    var selected = false;
    for (g.ed.nodes.items) |info| if (info.id == id) {
        selected = info.selected;
    };
    if (shift) {
        g.emit(.{ .select = .{ .node = id, .selected = !selected } });
        return;
    }
    if (selected) return;
    for (g.ed.last_nodes.items) |info| if (info.selected and info.id != id) g.emit(.{ .select = .{ .node = info.id, .selected = false } });
    g.emit(.{ .select = .{ .node = id, .selected = true } });
}

/// The pin under `p` that a dragged wire can end on: an input pin if
/// `input`, else an output pin.
fn pinAt(g: *Graph, p: Vec2, input: bool) ?u64 {
    const reach = 5 * g.zoom + 8;
    var best: ?u64 = null;
    var best_d: f32 = reach;
    var it = g.ed.pins.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.output == input) continue;
        const d = e.value_ptr.pos.sub(p).length();
        if (d < best_d) {
            best_d = d;
            best = e.key_ptr.*;
        }
    }
    return best;
}

fn bezierPoints(a: Vec2, b: Vec2, zoom: f32, out: *[curve_points]Vec2) void {
    const dx = @max(40 * zoom, @abs(b.x - a.x) * 0.5);
    const c1: Vec2 = .{ .x = a.x + dx, .y = a.y };
    const c2: Vec2 = .{ .x = b.x - dx, .y = b.y };
    for (out, 0..) |*p, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, curve_points - 1);
        const u = 1 - t;
        p.* = a.scale(u * u * u).add(c1.scale(3 * u * u * t)).add(c2.scale(3 * u * t * t)).add(b.scale(t * t * t));
    }
}

fn drawWire(g: *Graph, a: Vec2, b: Vec2, ca: Color, cb: Color, hot: bool) void {
    const dx = @max(40 * g.zoom, @abs(b.x - a.x) * 0.5);
    const w = @max(1.5, 2.2 * g.zoom);
    const color = if (hot) g.ui.style.colors.warning else zui.color.mix(ca, cb, 0.5);
    // The dark edge only where it shows: zoomed out it costs a second wire
    // for nothing.
    if (g.zoom >= 0.75) g.v.painter.bezier(a, .{ .x = a.x + dx, .y = a.y }, .{ .x = b.x - dx, .y = b.y }, b, Color.black.withAlpha(120), w + 2);
    g.v.painter.bezier(a, .{ .x = a.x + dx, .y = a.y }, .{ .x = b.x - dx, .y = b.y }, b, color, w);
}

fn segmentDistance(p: Vec2, a: Vec2, b: Vec2) f32 {
    const ab = b.sub(a);
    const len2 = ab.x * ab.x + ab.y * ab.y;
    const t = if (len2 > 0) std.math.clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2, 0, 1) else 0;
    return p.sub(a.add(ab.scale(t))).length();
}

fn hitCurve(points: []const Vec2, p: Vec2, reach: f32) bool {
    for (points[0 .. points.len - 1], points[1..]) |a, b| if (segmentDistance(p, a, b) <= reach) return true;
    return false;
}

fn segmentsCross(a: Vec2, b: Vec2, c: Vec2, d: Vec2) bool {
    const cross = struct {
        fn f(o: Vec2, p: Vec2, q: Vec2) f32 {
            return (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x);
        }
    }.f;
    const d1 = cross(c, d, a);
    const d2 = cross(c, d, b);
    const d3 = cross(a, b, c);
    const d4 = cross(a, b, d);
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0));
}

fn crosses(curve: []const Vec2, knife: []const Vec2) bool {
    if (knife.len < 2) return false;
    for (curve[0 .. curve.len - 1], curve[1..]) |a, b| {
        for (knife[0 .. knife.len - 1], knife[1..]) |c, d| if (segmentsCross(a, b, c, d)) return true;
    }
    return false;
}

/// A category of the add menu: its name and its node types.
pub const Category = struct {
    name: []const u8,
    items: []const []const u8,
    color: ?Color = null,
};

/// What was picked in the add menu.
pub const AddChoice = struct { category: usize, item: usize };

/// The state of an add menu's search field, kept by the app.
pub const AddMenuState = struct {
    search: [64]u8 = undefined,
    len: usize = 0,
};

/// Opens the add menu `name` at the pointer (for Shift+A, or a wire
/// dropped in empty space).
pub fn openAddMenu(ui: *Ui, name: []const u8, state: *AddMenuState) void {
    state.len = 0;
    const p = ui.input.mouse_pos;
    ui.openPopupAt(name, .{ .x = p.x, .y = p.y });
}

/// The add menu: a search field over the categories in columns. Typing
/// filters to the matching node types, best first; Enter takes the first.
pub fn addMenu(ui: *Ui, name: []const u8, categories: []const Category, state: *AddMenuState) ?AddChoice {
    if (!ui.beginPopup(name, .{ .min_width = 420 })) return null;
    defer ui.endPopup();
    var picked: ?AddChoice = null;
    const search = ui.id("Search");
    if (ui.focused != search) ui.setFocus(search);
    const field = ui.textInput("Search", &state.search, &state.len, .{ .width = .fill, .hint = "Search node types" });
    const query = state.search[0..state.len];
    if (query.len > 0) {
        // Matches, best first.
        var best: [24]struct { score: f32, c: usize, i: usize } = undefined;
        var n: usize = 0;
        for (categories, 0..) |cat, c| for (cat.items, 0..) |item, i| {
            const s = zui.fuzzyScore(query, item, null) orelse continue;
            if (n < best.len) {
                best[n] = .{ .score = s, .c = c, .i = i };
                n += 1;
            }
        };
        std.mem.sort(@TypeOf(best[0]), best[0..n], {}, struct {
            fn less(_: void, a: @TypeOf(best[0]), b: @TypeOf(best[0])) bool {
                return a.score > b.score;
            }
        }.less);
        if (n == 0) ui.label("No node type matches", .{ .color = ui.style.colors.text_muted });
        for (best[0..n], 0..) |m, k| {
            var buffer: [96]u8 = undefined;
            const label = std.fmt.bufPrint(&buffer, "{s}  ({s})", .{ categories[m.c].items[m.i], categories[m.c].name }) catch categories[m.c].items[m.i];
            if (ui.menuItem(label, .{})) picked = .{ .category = m.c, .item = m.i };
            if (k == 0 and field.submitted) picked = .{ .category = m.c, .item = m.i };
        }
    } else {
        ui.beginHorizontal(.{ .alignment = .start, .spacing = 16 });
        for (categories, 0..) |cat, c| {
            ui.beginVertical(.{});
            ui.label(cat.name, .{ .color = cat.color orelse ui.style.colors.text_muted });
            ui.pushIdInt(c);
            for (cat.items, 0..) |item, i| {
                if (ui.menuItem(item, .{})) picked = .{ .category = c, .item = i };
            }
            ui.popId();
            ui.endVertical();
        }
        ui.endHorizontal();
    }
    if (picked != null) ui.closePopup();
    return picked;
}

/// A palette entry to drag onto the editor; dropping it reports `add`
/// with `data`. Returns true when clicked instead.
pub fn paletteItem(ui: *Ui, label: []const u8, data: u64) bool {
    const b = ui.button(label, .{ .width = .fill });
    _ = ui.dragSource(b, .{ .kind = drag_kind, .data = data, .label = label });
    return b.clicked;
}

comptime {
    // Compile everything, also when built as an object for other systems.
    if (@import("builtin").output_mode == .Obj) {
        _ = &begin;
        _ = &addMenu;
        _ = &paletteItem;
        _ = &openAddMenu;
    }
}

const testing = std.testing;

test "wires: hit testing and the knife" {
    var pts: [curve_points]Vec2 = undefined;
    bezierPoints(.{ .x = 0, .y = 0 }, .{ .x = 200, .y = 100 }, 1, &pts);
    try testing.expect(hitCurve(&pts, .{ .x = 100, .y = 50 }, 5));
    try testing.expect(!hitCurve(&pts, .{ .x = 100, .y = 0 }, 5));
    try testing.expect(crosses(&pts, &.{ .{ .x = 100, .y = -50 }, .{ .x = 100, .y = 150 } }));
    try testing.expect(!crosses(&pts, &.{ .{ .x = 300, .y = -50 }, .{ .x = 300, .y = 150 } }));
}
