//! Areas that split, dock, float and switch with the workspace, as in
//! BeeModel's window.
//!
//! The layout is a `Dock`: plain data the app owns, one per workspace, that
//! it can save in its own files (`Dock.write` / `Dock.read`). Each area shows
//! one of the app's editors, by index.
//!
//!     var dock: zui.Dock = .init(viewport_editor);
//!     _ = dock.split(dock.root, .right, outliner_editor);
//!
//!     // each frame:
//!     ui.beginDockSpace("main", &dock, .{ .editors = &editor_choices });
//!     var areas: [zui.Dock.max_areas]zui.AreaId = undefined;
//!     for (dock.areas(&areas)) |id| {
//!         if (ui.beginArea(id)) |area| {
//!             defer ui.endArea();
//!             // header widgets here, then:
//!             ui.areaBody();
//!             drawEditor(area.editor, area.id);
//!         }
//!     }
//!     const changes = ui.endDockSpace();
//!
//! Drag a splitter to resize. Drag an area's header onto another area: near
//! an edge (the outer 30 %) it goes on that side, in the middle the two swap;
//! a tint shows where. Drag an area's top-left corner into its neighbour to
//! join them. The header's buttons split, maximize (Ctrl+Space) and close;
//! right-click it to float the area as a panel. Drag a panel by its title:
//! five guides show over the area under the pointer; let go on one to dock
//! there. F6 and Shift+F6 make the next or previous area the active one.

const std = @import("std");
const draw = @import("draw.zig");
const ui_mod = @import("ui.zig");
const choice = @import("choice.zig");
const window = @import("window.zig");
const icons = @import("icons.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;
const Color = draw.Color;

/// An area of a `Dock`: stable while the area exists.
pub const AreaId = u16;

/// Where something docks relative to an area.
pub const Side = enum { left, right, top, bottom, center };

const none: u16 = std.math.maxInt(u16);

/// A layout of areas: a binary tree of splits whose leaves are areas, plus
/// floating panels. Fixed size, so it never allocates and copies freely.
pub const Dock = struct {
    /// Nodes: areas and splits.
    pub const max_nodes = 63;
    /// Areas at most, docked and floating.
    pub const max_areas = 32;

    nodes: [max_nodes]Node = @splat(.{}),
    root: u16 = 0,
    /// The area shown alone, if any.
    maximized: ?AreaId = null,
    /// The area keys and F6 go to.
    active: ?AreaId = null,
    /// Floating areas, back to front.
    floating: [max_areas]AreaId = undefined,
    floating_count: u8 = 0,

    /// One node of the tree.
    pub const Node = struct {
        kind: Kind = .free,
        parent: u16 = none,
        /// Split: the two children, left/top first.
        a: u16 = none,
        b: u16 = none,
        /// Split: side by side (false) or stacked (true).
        stacked: bool = false,
        /// Split: the share of the first child.
        ratio: f32 = 0.5,
        /// Area: which of the app's editors it shows.
        editor: u32 = 0,
        /// Area: floats as a panel, at `float_rect`.
        floats: bool = false,
        float_rect: Rect = .{},
        /// Where it was laid out last frame.
        rect: Rect = .{},

        /// What a node is.
        pub const Kind = enum { free, area, split };
    };

    /// A dock with a single area showing `editor`.
    pub fn init(editor: u32) Dock {
        var d: Dock = .{};
        d.nodes[0] = .{ .kind = .area, .editor = editor };
        d.root = 0;
        return d;
    }

    fn alloc(d: *Dock) ?u16 {
        for (&d.nodes, 0..) |*n, i| {
            if (n.kind == .free) {
                n.* = .{};
                return @intCast(i);
            }
        }
        return null;
    }

    /// True if `id` names an area.
    pub fn isArea(d: *const Dock, id: AreaId) bool {
        return id < max_nodes and d.nodes[id].kind == .area;
    }

    /// The editor area `id` shows.
    pub fn editorOf(d: *const Dock, id: AreaId) u32 {
        return d.nodes[id].editor;
    }

    /// Shows `editor` in area `id`.
    pub fn setEditor(d: *Dock, id: AreaId, editor: u32) void {
        if (d.isArea(id)) d.nodes[id].editor = editor;
    }

    /// The areas, docked ones in reading order, then floating ones back to
    /// front, written to `buffer`.
    pub fn areas(d: *const Dock, buffer: *[max_areas]AreaId) []AreaId {
        var n: usize = 0;
        if (d.maximized) |m| {
            if (d.isArea(m)) {
                buffer[0] = m;
                n = 1;
            }
        } else d.collect(d.root, buffer, &n);
        for (d.floating[0..d.floating_count]) |f| {
            if (n < buffer.len) {
                buffer[n] = f;
                n += 1;
            }
        }
        return buffer[0..n];
    }

    fn collect(d: *const Dock, i: u16, buffer: *[max_areas]AreaId, n: *usize) void {
        if (i == none) return;
        switch (d.nodes[i].kind) {
            .area => if (n.* < buffer.len) {
                buffer[n.*] = i;
                n.* += 1;
            },
            .split => {
                d.collect(d.nodes[i].a, buffer, n);
                d.collect(d.nodes[i].b, buffer, n);
            },
            .free => {},
        }
    }

    /// How many areas are docked (not floating).
    pub fn dockedCount(d: *const Dock) usize {
        var buffer: [max_areas]AreaId = undefined;
        var n: usize = 0;
        d.collect(d.root, &buffer, &n);
        return n;
    }

    /// Puts `node` where `old` was in the tree.
    fn replace(d: *Dock, old: u16, node: u16) void {
        const parent = d.nodes[old].parent;
        d.nodes[node].parent = parent;
        if (parent == none) {
            d.root = node;
        } else if (d.nodes[parent].a == old) {
            d.nodes[parent].a = node;
        } else {
            d.nodes[parent].b = node;
        }
    }

    /// Splits `target` and puts the area `node` on `side` of it.
    fn insertAt(d: *Dock, target: u16, side: Side, node: u16) bool {
        const s = d.alloc() orelse return false;
        d.replace(target, s);
        const first = side == .left or side == .top;
        d.nodes[s] = .{
            .kind = .split,
            .parent = d.nodes[s].parent,
            .stacked = side == .top or side == .bottom,
            .a = if (first) node else target,
            .b = if (first) target else node,
        };
        d.nodes[target].parent = s;
        d.nodes[node].parent = s;
        d.nodes[node].floats = false;
        return true;
    }

    /// Takes the docked area `id` out of the tree, its sibling taking the
    /// space. Fails for the last docked area.
    fn detach(d: *Dock, id: u16) bool {
        const parent = d.nodes[id].parent;
        if (parent == none) return false;
        const p = d.nodes[parent];
        const sibling = if (p.a == id) p.b else p.a;
        d.replace(parent, sibling);
        d.nodes[parent] = .{};
        d.nodes[id].parent = none;
        return true;
    }

    /// Adds an area showing `editor` on `side` of `target` (not `.center`).
    /// Returns its id, or null if the dock is full.
    pub fn split(d: *Dock, target: AreaId, side: Side, editor: u32) ?AreaId {
        if (!d.isArea(target) or d.nodes[target].floats or side == .center) return null;
        // No more areas than `areas()` can list (and a layout can be read back).
        if (d.areaCount() >= max_areas) return null;
        const node = d.alloc() orelse return null;
        d.nodes[node] = .{ .kind = .area, .editor = editor };
        if (!d.insertAt(target, side, node)) {
            d.nodes[node] = .{};
            return null;
        }
        return node;
    }

    /// Removes area `id`. The last docked area stays.
    pub fn close(d: *Dock, id: AreaId) bool {
        if (!d.isArea(id)) return false;
        if (d.nodes[id].floats) {
            d.removeFloating(id);
        } else if (!d.detach(id)) return false;
        d.nodes[id] = .{};
        if (d.maximized == id) d.maximized = null;
        if (d.active == id) d.active = null;
        return true;
    }

    /// Moves area `id` to `side` of `target`; `.center` swaps the two.
    pub fn move(d: *Dock, id: AreaId, target: AreaId, side: Side) bool {
        if (id == target or !d.isArea(id) or !d.isArea(target) or d.nodes[target].floats) return false;
        if (side == .center) return d.swap(id, target);
        if (d.nodes[id].floats) {
            // Docking it takes a split node: make sure there is one before
            // the panel leaves the floating list, so a full dock can't lose it.
            if (!d.hasFree()) return false;
            d.removeFloating(id);
        } else if (!d.detach(id)) return false;
        return d.insertAt(target, side, id);
    }

    /// How many areas there are, docked and floating.
    pub fn areaCount(d: *const Dock) usize {
        var n: usize = 0;
        for (&d.nodes) |*node| n += @intFromBool(node.kind == .area);
        return n;
    }

    fn hasFree(d: *const Dock) bool {
        for (&d.nodes) |*node| if (node.kind == .free) return true;
        return false;
    }

    /// Swaps the places of two areas; each keeps its editor.
    pub fn swap(d: *Dock, a: AreaId, b: AreaId) bool {
        if (a == b or !d.isArea(a) or !d.isArea(b)) return false;
        const na = &d.nodes[a];
        const nb = &d.nodes[b];
        if (na.floats or nb.floats) {
            // A panel dropped in the middle of an area: they trade places.
            const panel = if (na.floats) a else b;
            const docked = if (na.floats) b else a;
            const rect = d.nodes[panel].float_rect;
            d.removeFloating(panel);
            d.replace(docked, panel);
            d.nodes[panel].floats = false;
            d.nodes[docked].parent = none;
            d.addFloating(docked, rect);
            return true;
        }
        const pa = na.parent;
        const pb = nb.parent;
        if (pa == pb) {
            const p = &d.nodes[pa];
            std.mem.swap(u16, &p.a, &p.b);
            return true;
        }
        // Different parents: point each parent at the other area.
        d.replace(a, b);
        if (pb == none) d.root = a else if (d.nodes[pb].a == b) d.nodes[pb].a = a else d.nodes[pb].b = a;
        d.nodes[a].parent = pb;
        d.nodes[b].parent = pa;
        return true;
    }

    /// Makes the docked area `id` a floating panel at `rect`. The last
    /// docked area stays.
    pub fn float(d: *Dock, id: AreaId, rect: Rect) bool {
        if (!d.isArea(id) or d.nodes[id].floats or d.floating_count == max_areas) return false;
        if (!d.detach(id)) return false;
        if (d.maximized == id) d.maximized = null;
        d.addFloating(id, rect);
        return true;
    }

    fn addFloating(d: *Dock, id: AreaId, rect: Rect) void {
        d.nodes[id].floats = true;
        d.nodes[id].float_rect = rect;
        d.floating[d.floating_count] = id;
        d.floating_count += 1;
    }

    fn removeFloating(d: *Dock, id: AreaId) void {
        const list = d.floating[0..d.floating_count];
        const i = std.mem.indexOfScalar(AreaId, list, id) orelse return;
        std.mem.copyForwards(AreaId, list[i .. list.len - 1], list[i + 1 ..]);
        d.floating_count -= 1;
        d.nodes[id].floats = false;
    }

    /// Joins `into` with its neighbour `gone`, which must share a split
    /// with it: `gone` closes and `into` takes its space.
    pub fn join(d: *Dock, into: AreaId, gone: AreaId) bool {
        if (!d.isArea(into) or !d.isArea(gone) or d.nodes[into].floats) return false;
        if (d.nodes[into].parent == none or d.nodes[into].parent != d.nodes[gone].parent) return false;
        return d.close(gone);
    }

    /// The area whose rect contains `p`, among docked ones.
    pub fn areaAt(d: *const Dock, p: Vec2) ?AreaId {
        var buffer: [max_areas]AreaId = undefined;
        var n: usize = 0;
        if (d.maximized) |m| {
            if (d.isArea(m) and d.nodes[m].rect.contains(p)) return m;
            return null;
        }
        d.collect(d.root, &buffer, &n);
        for (buffer[0..n]) |id| if (d.nodes[id].rect.contains(p)) return id;
        return null;
    }

    /// Writes the layout as text, one node per line, for the app's files.
    pub fn write(d: *const Dock, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("zuidock 1 {d} {d} {d}\n", .{ d.root, if (d.maximized) |m| m else none, if (d.active) |a| a else none });
        for (d.nodes, 0..) |n, i| {
            if (n.kind == .free) continue;
            try writer.print("{d} {s} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
                i,                @tagName(n.kind),  n.parent,          n.a,               n.b,
                @intFromBool(n.stacked), n.ratio,           n.editor,          @intFromBool(n.floats), n.float_rect.x,
                n.float_rect.y,   n.float_rect.w,    n.float_rect.h,
            });
        }
        for (d.floating[0..d.floating_count]) |f| try writer.print("float {d}\n", .{f});
    }

    /// Reads what `write` wrote. Checks that it forms a valid tree, and
    /// changes nothing on failure.
    pub fn read(text: []const u8) error{InvalidDock}!Dock {
        var d: Dock = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        const head = lines.next() orelse return error.InvalidDock;
        var hs = std.mem.tokenizeScalar(u8, head, ' ');
        if (!std.mem.eql(u8, hs.next() orelse "", "zuidock")) return error.InvalidDock;
        if (!std.mem.eql(u8, hs.next() orelse "", "1")) return error.InvalidDock;
        d.root = try num(u16, hs.next());
        const max = try num(u16, hs.next());
        const act = try num(u16, hs.next());
        d.maximized = if (max == none) null else max;
        d.active = if (act == none) null else act;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var t = std.mem.tokenizeScalar(u8, line, ' ');
            const first = t.next() orelse continue;
            if (std.mem.eql(u8, first, "float")) {
                if (d.floating_count == max_areas) return error.InvalidDock;
                d.floating[d.floating_count] = try num(u16, t.next());
                d.floating_count += 1;
                continue;
            }
            const i = try num(u16, first);
            if (i >= max_nodes) return error.InvalidDock;
            const kind = std.meta.stringToEnum(Node.Kind, t.next() orelse "") orelse return error.InvalidDock;
            d.nodes[i] = .{
                .kind = kind,
                .parent = try num(u16, t.next()),
                .a = try num(u16, t.next()),
                .b = try num(u16, t.next()),
                .stacked = (try num(u8, t.next())) != 0,
                .ratio = std.math.clamp(try num(f32, t.next()), 0.05, 0.95),
                .editor = try num(u32, t.next()),
                .floats = (try num(u8, t.next())) != 0,
                .float_rect = .{ .x = try num(f32, t.next()), .y = try num(f32, t.next()), .w = try num(f32, t.next()), .h = try num(f32, t.next()) },
            };
        }
        try d.validate();
        return d;
    }

    fn num(comptime T: type, text: ?[]const u8) error{InvalidDock}!T {
        const t = text orelse return error.InvalidDock;
        return switch (@typeInfo(T)) {
            .float => std.fmt.parseFloat(T, t) catch error.InvalidDock,
            else => std.fmt.parseInt(T, t, 10) catch error.InvalidDock,
        };
    }

    /// Every node reachable once from the root, parents matching, floating
    /// areas real: a dock that can be laid out without surprises.
    fn validate(d: *const Dock) error{InvalidDock}!void {
        if (d.root >= max_nodes) return error.InvalidDock;
        var seen: [max_nodes]bool = @splat(false);
        try d.check(d.root, none, &seen, 0);
        for (d.floating[0..d.floating_count]) |f| {
            if (!d.isArea(f) or !d.nodes[f].floats or seen[f]) return error.InvalidDock;
            seen[f] = true;
        }
        for (d.nodes, 0..) |n, i| if (n.kind != .free and !seen[i]) return error.InvalidDock;
        if (d.maximized) |m| if (!d.isArea(m)) return error.InvalidDock;
        if (d.active) |a| if (!d.isArea(a)) return error.InvalidDock;
    }

    fn check(d: *const Dock, i: u16, parent: u16, seen: *[max_nodes]bool, depth: u32) error{InvalidDock}!void {
        if (i >= max_nodes or seen[i] or depth > max_nodes) return error.InvalidDock;
        seen[i] = true;
        const n = d.nodes[i];
        if (n.parent != parent) return error.InvalidDock;
        switch (n.kind) {
            .free => return error.InvalidDock,
            .area => if (n.floats) return error.InvalidDock,
            .split => {
                try d.check(n.a, i, seen, depth + 1);
                try d.check(n.b, i, seen, depth + 1);
            },
        }
    }
};

// ---- the UI -----------------------------------------------------------------

/// Options for `beginDockSpace`.
pub const DockOptions = struct {
    /// The editors an area can show, for the header's editor list.
    editors: []const choice.Choice = &.{},
    /// An area is never made smaller than this.
    min_size: f32 = 80,
    /// The gap between areas, which is also the splitter.
    gap: f32 = 4,
};

/// What `beginArea` says about an area.
pub const AreaInfo = struct {
    id: AreaId,
    editor: u32,
    /// The whole area, header included.
    rect: Rect,
    /// Keys and F6 go here.
    active: bool,
    floating: bool,
};

/// What changed during the frame, from `endDockSpace`.
pub const DockChanges = struct {
    /// The layout changed: save it if you keep it.
    changed: bool = false,
    /// A new area appeared (a split); set up its state.
    created: ?AreaId = null,
    /// An area went away; drop its state.
    closed: ?AreaId = null,
};

const Drag = struct {
    kind: enum { none, header, corner, panel } = .none,
    area: AreaId = 0,
    moved: bool = false,
};

/// Dock state kept in the `Ui` while a dock space is described.
pub const State = struct {
    dock: ?*Dock = null,
    id: Id = .none,
    options: DockOptions = .{},
    rect: Rect = .{},
    drag: Drag = .{},
    changes: DockChanges = .{},
    /// The area being described.
    area: ?AreaId = null,
    in_header: bool = false,
    saved_record: ?u32 = null,
    corner_hot: bool = false,
    /// The empty part of the header, between its widgets.
    header_free: Rect = .{},
    /// The described area's header and body.
    header: Rect = .{},
    body: Rect = .{},
    saved_scope: Id = .none,
    header_h: f32 = 0,
    /// The active area ring shows after F6.
    ring: bool = false,
    /// A command chosen from a header's menu, applied at the end.
    pending: ?struct { area: AreaId, action: Action } = null,
};

const Action = enum { split_right, split_below, maximize, close, float, dock };

fn state(ui: *Ui) *State {
    return &ui.dock_state;
}

/// Starts a dock space filling the rest of the current layout, and lays out
/// `dock` in it. Describe its areas with `beginArea`, then `endDockSpace`.
pub fn beginDockSpace(ui: *Ui, name: []const u8, dock: *Dock, options: DockOptions) void {
    const st = state(ui);
    std.debug.assert(st.dock == null); // dock spaces don't nest
    const rect = ui.placeSized(.fill, .fill, .{ .x = 200, .y = 200 });
    st.* = .{ .dock = dock, .id = ui.id(name), .options = options, .rect = rect, .drag = st.drag, .ring = st.ring };
    st.header_h = ui.textSize("").y + ui.style.frame_padding.y * 2;

    if (dock.active) |a| if (!dock.isArea(a)) {
        dock.active = null;
    };
    if (dock.maximized) |m| {
        if (dock.isArea(m)) dock.nodes[m].rect = rect else dock.maximized = null;
    }
    if (dock.maximized == null) layoutNode(ui, dock, dock.root, rect, options);

    // F6 / Shift+F6 cycle the active area; Ctrl+Space maximizes it.
    if (!ui.wantsKeyboard()) for (ui.input.keyEvents()) |event| {
        if (event.key == .f6) {
            var buffer: [Dock.max_areas]AreaId = undefined;
            const list = dock.areas(&buffer);
            if (list.len == 0) continue;
            const at = if (dock.active) |a| std.mem.indexOfScalar(AreaId, list, a) orelse 0 else list.len - 1;
            const next = if (event.modifiers.shift) (at + list.len - 1) % list.len else (at + 1) % list.len;
            dock.active = list[next];
            st.ring = true;
        } else if (event.key == .space and event.modifiers.ctrl) {
            if (dock.active) |a| st.pending = .{ .area = a, .action = .maximize };
        }
    };
    if (ui.input.mouse_pressed.contains(.left)) st.ring = false;
    // Tab stays in the active area, unless a dialog keeps it to itself.
    if (!ui.feedback_state.shown) {
        const scope = if (dock.active) |a| areaScope(st, a) else Id.none;
        ui.nav_scope = scope;
        ui.nav_scope_next = scope;
    }
}

fn areaScope(st: *const State, area: AreaId) Id {
    return @enumFromInt(std.hash.Wyhash.hash(@intFromEnum(st.id), std.mem.asBytes(&area)));
}

/// Lays out node `i` in `rect`, and handles the splitter of a split.
fn layoutNode(ui: *Ui, dock: *Dock, i: u16, rect: Rect, options: DockOptions) void {
    const n = &dock.nodes[i];
    n.rect = rect;
    if (n.kind != .split) return;
    const gap = options.gap;
    const total = if (n.stacked) rect.h else rect.w;
    const avail = @max(0, total - gap);
    // Keep both sides at least min_size where there is room for it.
    const lo = if (avail >= 2 * options.min_size) options.min_size / avail else 0.5;
    const t = std.math.clamp(n.ratio, lo, 1 - lo);
    const first = avail * t;
    var ra = rect;
    var rb = rect;
    var bar = rect;
    if (n.stacked) {
        ra.h = first;
        bar.y = rect.y + first;
        bar.h = gap;
        rb.y = bar.bottom();
        rb.h = rect.bottom() - rb.y;
    } else {
        ra.w = first;
        bar.x = rect.x + first;
        bar.w = gap;
        rb.x = bar.right();
        rb.w = rect.right() - rb.x;
    }
    // The splitter: a little wider than the gap, so it is easy to grab.
    const grab = bar.inset(-2);
    ui.pushIdInt(i);
    const r = ui.interact(ui.id("##splitter"), grab);
    ui.popId();
    if (r.hovered or r.held) ui.cursor = if (n.stacked) .resize_ns else .resize_ew;
    if (r.held and avail > 0) {
        const m = ui.input.mouse_pos;
        const pos = if (n.stacked) m.y - rect.y else m.x - rect.x;
        const new = std.math.clamp((pos - gap / 2) / avail, lo, 1 - lo);
        if (new != n.ratio) {
            n.ratio = new;
            state(ui).changes.changed = true;
        }
    }
    if (r.held or r.hovered) ui.drawRect(.{ .rect = bar, .fill = ui.style.colors.accent.withAlpha(120) });
    layoutNode(ui, dock, n.a, ra, options);
    layoutNode(ui, dock, n.b, rb, options);
}

/// Starts describing area `area`: its header row is open, so header widgets
/// can follow. Call `areaBody` before the area's content, and `endArea`
/// after it. Returns null if the area isn't shown.
pub fn beginArea(ui: *Ui, area: AreaId) ?AreaInfo {
    const st = state(ui);
    const dock = st.dock orelse return null;
    if (!dock.isArea(area)) return null;
    const node = &dock.nodes[area];
    if (!node.floats and dock.maximized != null and dock.maximized != area) return null;
    st.area = area;
    st.saved_scope = ui.pushFocusScope(areaScope(st, area));
    ui.pushIdValue(areaScope(st, area));
    const editor_label = if (node.editor < st.options.editors.len) st.options.editors[node.editor].label else "area";

    var rect = node.rect;
    if (node.floats) {
        // A panel: a window whose title moves it, kept in the dock.
        var buffer: [96]u8 = undefined;
        const editor_name = if (node.editor < st.options.editors.len) st.options.editors[node.editor].label else "Panel";
        const title = std.fmt.bufPrint(&buffer, "{s}##panel", .{editor_name}) catch "Panel";
        const fr = node.float_rect;
        if (!ui.beginWindow(title, .{ .position = .{ .x = fr.x, .y = fr.y }, .size = .{ .x = @max(fr.w, 160), .y = @max(fr.h, 100) }, .collapsible = false })) {
            ui.popId();
            ui.popFocusScope(st.saved_scope);
            st.area = null;
            return null;
        }
        if (ui.current_window) |w| {
            if (!std.meta.eql(w.rect, node.float_rect)) st.changes.changed = true;
            node.float_rect = w.rect;
            node.rect = w.rect;
            // Follow the panel's title drag, for the dock guides.
            ui.pushIdValue(w.id);
            const title_id = ui.id("#title");
            ui.popId();
            if (ui.active == title_id and st.drag.kind == .none) st.drag = .{ .kind = .panel, .area = area };
        }
        // The window's content region holds the header and the body.
        rect = ui.clipRect();
    } else {
        ui.drawRect(.{ .rect = rect, .fill = ui.style.colors.window, .radius = 2 });
        // A press anywhere in the area makes it the active one.
        if (ui.input.mouse_pressed.contains(.left) and rect.contains(ui.input.press_pos.get(.left)) and ui.pressed_window == null) {
            dock.active = area;
        }
    }

    const header: Rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = st.header_h };
    // In the record, the area holds what is in it: "Outliner > button:close".
    st.saved_record = @import("record.zig").enterContainer(ui, .area, areaScope(st, area), editor_label, if (node.floats) rect else node.rect, .{
        .value = if (dock.active == area) "active" else null,
    });
    st.header = header;
    st.body = .{ .x = rect.x, .y = header.bottom(), .w = rect.w, .h = @max(0, rect.bottom() - header.bottom()) };
    ui.drawRect(.{ .rect = header, .fill = ui.style.colors.title, .radius = 2 });
    if (!node.floats) {
        // The corner to drag into a neighbour, joining the two. Described
        // before the header's widgets, so it gets the press first.
        const corner: Rect = .{ .x = rect.x, .y = rect.y, .w = 10, .h = 10 };
        const cr = ui.interact(ui.id("##corner"), corner);
        if (cr.pressed) st.drag = .{ .kind = .corner, .area = area };
        st.corner_hot = cr.hovered or cr.held;
        ui.recordWidget(.custom, ui.id("##corner"), "corner", corner, .{ .hovered = cr.hovered });
    }
    ui.beginRegion(@enumFromInt(@intFromEnum(areaScope(st, area)) +% 1), header, .horizontal, 2, .center);
    st.in_header = true;
    // The editor this area shows.
    if (st.options.editors.len > 0) {
        var editor: usize = node.editor;
        // Narrow areas get a narrower list, so the header keeps a part to
        // grab for dragging.
        const width = std.math.clamp((header.w - 4 * st.header_h) * 0.5, 40, 150);
        const r = ui.dropdown("##editor", &editor, st.options.editors, .{ .width = .{ .fixed = width } });
        if (r.changed) {
            node.editor = @intCast(editor);
            st.changes.changed = true;
        }
    }
    return .{ .id = area, .editor = node.editor, .rect = node.rect, .active = dock.active == area, .floating = node.floats };
}

/// Ends the area's header and starts its body: a column below the header
/// in which `.fill` fills the area. An editor with long content puts it in
/// `ui.beginScrollArea(name, .{ .height = .fill })`.
pub fn areaBody(ui: *Ui) void {
    const st = state(ui);
    if (!st.in_header) return;
    const dock = st.dock.?;
    const area = st.area.?;
    const node = &dock.nodes[area];
    const style = &ui.style;
    const colors = &style.colors;

    // Buttons at the right of the header.
    ui.spacer(.fill);
    st.header_free = ui.lastRect();
    const small: @import("widgets.zig").ButtonOptions = .{ .height = .{ .fixed = st.header_h - 4 } };
    if (node.floats) {
        var b = small;
        b.icon = .{ .builtin = .arrow_down };
        const r = ui.button("##dock", b);
        ui.tooltipRich(r, .{ .title = "Dock", .body = "Put the panel back beside the area under it." });
        if (r.clicked) st.pending = .{ .area = area, .action = .dock };
    } else {
        var b = small;
        b.icon = .{ .builtin = .chevron_right };
        const sr = ui.button("##split", b);
        ui.tooltipRich(sr, .{ .title = "Split", .body = "Split side by side. Right-click the header for more." });
        if (sr.clicked) st.pending = .{ .area = area, .action = .split_right };
        b.icon = .{ .builtin = if (dock.maximized == area) .minus else .plus };
        const mr = ui.button("##maximize", b);
        ui.tooltipRich(mr, .{ .title = if (dock.maximized == area) "Restore" else "Maximize", .shortcut = "Ctrl+Space" });
        if (mr.clicked) st.pending = .{ .area = area, .action = .maximize };
        ui.pushDisabled(if (dock.dockedCount() <= 1) "The last area stays" else null);
        b.icon = .{ .builtin = .close };
        const cr = ui.button("##close", b);
        ui.tooltipRich(cr, .{ .title = "Close area" });
        if (cr.clicked) st.pending = .{ .area = area, .action = .close };
        ui.popDisabled();
    }
    ui.endRegion();
    st.in_header = false;

    const rect = node.rect;
    const header = st.header;
    if (!node.floats) {
        // The empty part of the header: press and drag to move the area,
        // right-click for its menu. Described after the header's widgets,
        // so they get their clicks first.
        const hr = ui.interact(ui.id("##header"), header);
        if (hr.pressed) st.drag = .{ .kind = .header, .area = area };
        if (ui.beginContextMenu(hr, "Area")) {
            defer ui.endMenu();
            if (ui.menuItem("Split Side by Side", .{})) st.pending = .{ .area = area, .action = .split_right };
            if (ui.menuItem("Split Top and Bottom", .{})) st.pending = .{ .area = area, .action = .split_below };
            if (ui.menuItem(if (dock.maximized == area) "Restore" else "Maximize", .{ .shortcut = "Ctrl+Space" })) st.pending = .{ .area = area, .action = .maximize };
            if (ui.menuItem("Float Area", .{ .disabled = if (dock.dockedCount() <= 1) "The last area stays" else null })) st.pending = .{ .area = area, .action = .float };
            ui.menuSeparator();
            if (ui.menuItem("Close Area", .{ .disabled = if (dock.dockedCount() <= 1) "The last area stays" else null })) st.pending = .{ .area = area, .action = .close };
        }
        if (st.corner_hot) {
            const corner: Rect = .{ .x = rect.x, .y = rect.y, .w = 10, .h = 10 };
            ui.cursor = .crosshair;
            ui.painter().polygon(&.{ .{ .x = corner.x, .y = corner.y }, .{ .x = corner.right(), .y = corner.y }, .{ .x = corner.x, .y = corner.bottom() } }, colors.accent);
        }
        // Recorded as the header's empty part, where a drag can start.
        const free = st.header_free.intersect(header);
        ui.recordWidget(.custom, ui.id("##header"), "header", if (free.isEmpty()) header else free, .{ .hovered = hr.hovered });
    }

    ui.beginRegion(ui.id("##body"), st.body, .vertical, style.window_padding * 0.75, .start);
}

/// Ends the area started by `beginArea`.
pub fn endArea(ui: *Ui) void {
    const st = state(ui);
    if (st.in_header) areaBody(ui);
    ui.endRegion();
    const dock = st.dock.?;
    const area = st.area.?;
    const node = &dock.nodes[area];
    if (node.floats) ui.endWindow();
    // The active area's ring, after F6.
    if (st.ring and dock.active == area and !node.floats) {
        ui.drawRect(.{ .rect = node.rect, .border = ui.style.colors.focus_ring, .border_width = 2, .radius = 2 });
    }
    ui.popId();
    ui.popFocusScope(st.saved_scope);
    @import("record.zig").leaveContainer(ui, st.saved_record);
    st.area = null;
}

/// The side of `rect` that a drop at `p` means: near an edge (its outer
/// 30 %), that side; otherwise the middle.
pub fn dropSide(rect: Rect, p: Vec2) Side {
    const fx = (p.x - rect.x) / @max(1, rect.w);
    const fy = (p.y - rect.y) / @max(1, rect.h);
    const edge = 0.3;
    // The nearest edge wins where two zones overlap.
    const dists = [_]f32{ fx, 1 - fx, fy, 1 - fy };
    const sides = [_]Side{ .left, .right, .top, .bottom };
    var best: ?usize = null;
    for (dists, 0..) |d, i| {
        if (d < edge and (best == null or d < dists[best.?])) best = i;
    }
    return if (best) |b| sides[b] else .center;
}

/// The edge of `rect` closest to `p`.
fn nearestEdge(rect: Rect, p: Vec2) Side {
    const fx = (p.x - rect.x) / @max(1, rect.w);
    const fy = (p.y - rect.y) / @max(1, rect.h);
    const dists = [_]f32{ fx, 1 - fx, fy, 1 - fy };
    const sides = [_]Side{ .left, .right, .top, .bottom };
    var best: usize = 0;
    for (dists, 0..) |d, i| if (d < dists[best]) {
        best = i;
    };
    return sides[best];
}

fn zoneRect(rect: Rect, side: Side) Rect {
    return switch (side) {
        .left => .{ .x = rect.x, .y = rect.y, .w = rect.w / 2, .h = rect.h },
        .right => .{ .x = rect.x + rect.w / 2, .y = rect.y, .w = rect.w / 2, .h = rect.h },
        .top => .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h / 2 },
        .bottom => .{ .x = rect.x, .y = rect.y + rect.h / 2, .w = rect.w, .h = rect.h / 2 },
        .center => rect,
    };
}

/// The five dock guides shown in the middle of `rect` while a panel is
/// dragged over it.
fn guides(rect: Rect) [5]struct { side: Side, rect: Rect } {
    const s: f32 = 28;
    const g: f32 = 4;
    const c: Vec2 = .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 };
    const at = struct {
        fn f(x: f32, y: f32, size: f32) Rect {
            return .{ .x = x - size / 2, .y = y - size / 2, .w = size, .h = size };
        }
    }.f;
    return .{
        .{ .side = .center, .rect = at(c.x, c.y, s) },
        .{ .side = .left, .rect = at(c.x - s - g, c.y, s) },
        .{ .side = .right, .rect = at(c.x + s + g, c.y, s) },
        .{ .side = .top, .rect = at(c.x, c.y - s - g, s) },
        .{ .side = .bottom, .rect = at(c.x, c.y + s + g, s) },
    };
}

/// Ends the dock space: shows where a dragged area or panel would go,
/// carries out drops and header commands, and says what changed.
pub fn endDockSpace(ui: *Ui) DockChanges {
    const st = state(ui);
    const dock = st.dock orelse return .{};
    defer st.dock = null;
    const in = &ui.input;
    const colors = &ui.style.colors;
    const m = in.mouse_pos;
    const released = !in.mouse_down.contains(.left);
    const tint = colors.accent.withAlpha(70);

    switch (st.drag.kind) {
        .none => {},
        .header => {
            if (!st.drag.moved and m.sub(in.press_pos.get(.left)).length() > 6) st.drag.moved = true;
            const target = dock.areaAt(m);
            if (st.drag.moved) {
                ui.cursor = .move;
                if (target) |t| if (t != st.drag.area) {
                    const side = dropSide(dock.nodes[t].rect, m);
                    ui.overlayRect(zoneRect(dock.nodes[t].rect, side), tint);
                };
            }
            if (released) {
                if (st.drag.moved) if (target) |t| if (t != st.drag.area) {
                    if (dock.move(st.drag.area, t, dropSide(dock.nodes[t].rect, in.release_pos.get(.left)))) st.changes.changed = true;
                };
                st.drag = .{};
            }
        },
        .corner => {
            const target = dock.areaAt(m);
            const src = st.drag.area;
            const can = if (target) |t| t != src and dock.nodes[t].parent == dock.nodes[src].parent and dock.nodes[src].parent != none else false;
            if (can) {
                ui.overlayRect(dock.nodes[target.?].rect, Color.black.withAlpha(90));
                ui.cursor = .crosshair;
            } else if (target != null and target != src) ui.cursor = .not_allowed;
            if (released) {
                if (can) {
                    const gone = target.?;
                    if (dock.join(src, gone)) {
                        st.changes.changed = true;
                        st.changes.closed = gone;
                    }
                }
                st.drag = .{};
            }
        },
        .panel => {
            const target = dock.areaAt(m);
            if (target) |t| {
                for (guides(dock.nodes[t].rect)) |g| {
                    const hot = g.rect.contains(m);
                    ui.overlayRect(g.rect, if (hot) colors.accent else colors.popup);
                    ui.overlayBorder(g.rect, colors.accent);
                    if (hot) ui.overlayRect(zoneRect(dock.nodes[t].rect, g.side), tint);
                }
            }
            if (released) {
                const at = in.release_pos.get(.left);
                if (dock.areaAt(at)) |t| for (guides(dock.nodes[t].rect)) |g| {
                    if (g.rect.contains(at) and dock.move(st.drag.area, t, g.side)) st.changes.changed = true;
                };
                st.drag = .{};
            }
        },
    }
    if (st.pending) |p| {
        st.pending = null;
        switch (p.action) {
            .split_right, .split_below => if (dock.split(p.area, if (p.action == .split_right) .right else .bottom, dock.nodes[p.area].editor)) |new| {
                st.changes.created = new;
                st.changes.changed = true;
            },
            .maximize => {
                dock.maximized = if (dock.maximized == p.area) null else p.area;
                st.changes.changed = true;
            },
            .close => if (dock.close(p.area)) {
                st.changes.closed = p.area;
                st.changes.changed = true;
            },
            .float => {
                const r = dock.nodes[p.area].rect;
                if (dock.float(p.area, .{ .x = r.x + 30, .y = r.y + 30, .w = @max(240, r.w * 0.6), .h = @max(160, r.h * 0.6) })) st.changes.changed = true;
            },
            .dock => {
                const r = dock.nodes[p.area].float_rect;
                const c: Vec2 = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
                const target = dock.areaAt(c) orelse dock.areaAt(.{ .x = st.rect.x + 1, .y = st.rect.y + 1 });
                if (target) |t| {
                    // Beside, never in the middle (which would swap them).
                    if (dock.move(p.area, t, nearestEdge(dock.nodes[t].rect, c))) st.changes.changed = true;
                }
            },
        }
        ui.requestRedraw();
    }
    if (st.drag.kind != .none) ui.requestRedraw();
    return st.changes;
}

test "split, close, move, swap and float keep a valid tree" {
    var d: Dock = .init(0);
    const right = d.split(d.root, .right, 1).?;
    const bottom = d.split(right, .bottom, 2).?;
    try d.validate();
    try std.testing.expectEqual(@as(usize, 3), d.dockedCount());
    try std.testing.expect(d.move(bottom, 0, .left));
    try d.validate();
    var buffer: [Dock.max_areas]AreaId = undefined;
    try std.testing.expectEqual(bottom, d.areas(&buffer)[0]);
    try std.testing.expect(d.swap(bottom, right));
    try d.validate();
    try std.testing.expect(d.float(right, .{ .w = 200, .h = 100 }));
    try d.validate();
    try std.testing.expectEqual(@as(usize, 2), d.dockedCount());
    try std.testing.expect(d.move(right, 0, .center));
    try d.validate();
    try std.testing.expect(d.nodes[0].floats);
    try std.testing.expect(d.close(0));
    try d.validate();
    try std.testing.expect(d.close(right));
    try std.testing.expect(!d.close(bottom)); // the last one stays
    try d.validate();
}

test "join removes the neighbour; a non-neighbour can't be joined" {
    var d: Dock = .init(0);
    const b = d.split(0, .right, 1).?;
    const c = d.split(b, .bottom, 2).?;
    try std.testing.expect(!d.join(0, c));
    try std.testing.expect(d.join(b, c));
    try d.validate();
    try std.testing.expectEqual(@as(usize, 2), d.dockedCount());
}

test "write and read give the same dock; damage is refused" {
    var d: Dock = .init(3);
    _ = d.split(0, .right, 4).?;
    const f = d.split(0, .bottom, 5).?;
    try std.testing.expect(d.float(f, .{ .x = 10, .y = 20, .w = 300, .h = 200 }));
    d.active = 0;
    var buffer: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try d.write(&w);
    const back = try Dock.read(w.buffered());
    try std.testing.expectEqual(d.root, back.root);
    try std.testing.expectEqual(d.floating_count, back.floating_count);
    try std.testing.expectEqual(@as(?AreaId, 0), back.active);
    try std.testing.expectEqual(@as(f32, 300), back.nodes[f].float_rect.w);
    var bad: [2048]u8 = undefined;
    @memcpy(bad[0..w.end], buffer[0..w.end]);
    // Point the root at a free node.
    const text = bad[0..w.end];
    text[10] = '9';
    try std.testing.expectError(error.InvalidDock, Dock.read(text));
    try std.testing.expectError(error.InvalidDock, Dock.read("zuidock 2 0 0 0\n"));
}

test "drop zones: edges, then the middle" {
    const r: Rect = .{ .w = 100, .h = 100 };
    try std.testing.expectEqual(Side.left, dropSide(r, .{ .x = 10, .y = 50 }));
    try std.testing.expectEqual(Side.bottom, dropSide(r, .{ .x = 50, .y = 90 }));
    try std.testing.expectEqual(Side.top, dropSide(r, .{ .x = 25, .y = 5 }));
    try std.testing.expectEqual(Side.center, dropSide(r, .{ .x = 50, .y = 50 }));
}
