// The BeeModel shell: title bar, menu bar with workspace tabs, a tree of
// areas (split, join, resize, maximize, close, dock, swap, float), the status
// bar, toasts and tooltips, and the routing of input to all of it. The
// editors live in editors.zig, menus and the F3 palette in menus.zig, the
// dialogs in dialogs.zig, the commands in ops.zig.
const std = @import("std");
const zui = @import("zui");
const host = @import("zuihost.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const wl = @import("wayland.zig");
const m = @import("math.zig");
const scene = @import("scene.zig");
const theme = @import("theme.zig");
const vp = @import("viewport.zig");
const ops = @import("ops.zig");
const cat = @import("catalog.zig");
const menus = @import("menus.zig");
const undo = @import("undo.zig");
const xform = @import("xform.zig");
const editors = @import("editors.zig");
const dialogs = @import("dialogs.zig");
const pies = @import("pies.zig");
const prefs = @import("prefs.zig");
const files = @import("files.zig");
const filebrowser = @import("filebrowser.zig");
const wg = @import("wg.zig");
const scale = @import("scale.zig");
const pw = @import("panelwin.zig");
const wsfile = @import("wsfile.zig");

const Rect = gfx.Rect;

pub const TITLE_H = 32;
pub const MENU_H = 24;
pub const STATUS_H = 22;
pub const HDR_H = 24;
pub const SPLIT = 5;

pub var win: ?*wl.Window = null;
pub var now_ms: i64 = 0;
pub var dirty: bool = true;
pub var quit: bool = false;

// --- editors and areas ----------------------------------------------------

pub const Editor = enum(u8) {
    viewport,
    tools,
    outliner,
    properties,
    console,
    timeline,
    dopesheet,
    graph,
    render,
    uved,
    nodes,
    help,
    prefs,
    /// The Asset Browser: the content library and the online sources (libui.zig).
    assets,
    /// AI Activity: the agents' permission, what they did, Revert (agent.zig).
    activity,
    /// The AI Assistant: a conversation that builds in the scene (ai.zig).
    ai,
    /// Versions: the scene's history, branches, merges; collaboration (versions.zig).
    versions,
    /// An editor of the original the port has not (from a file's workspaces):
    /// Node.raw_ed says which, and goes back into the file as it came.
    other,

    pub fn label(e: Editor) []const u8 {
        return switch (e) {
            .viewport => "3D Viewport",
            .tools => "Tools",
            .outliner => "Outliner",
            .properties => "Properties",
            .console => "Console",
            .timeline => "Timeline",
            .dopesheet => "Dope Sheet",
            .graph => "Graph Editor",
            .render => "Render",
            .uved => "UV Editor",
            .nodes => "Node Editor",
            .help => "Help",
            .prefs => "Preferences",
            .assets => "Asset Browser",
            .activity => "AI Activity",
            .ai => "AI Assistant",
            .versions => "Versions",
            .other => "Not ported",
        };
    }
};

pub const Node = struct {
    used: bool = false,
    leaf: bool = true,
    parent: i16 = -1,
    // split
    vertical: bool = true, // children side by side
    ratio: f32 = 0.5,
    a: i16 = -1,
    b: i16 = -1,
    // leaf
    editor: Editor = .viewport,
    raw_ed: u8 = 0, // (the original's ED_ number of an `other`)
    view: vp.View = .{},
    scroll: i32 = 0,
    tab: u8 = 0,
    rect: Rect = .{},
};

// (a file brings up to 12 workspaces of 32 nodes)
pub var nodes: [512]Node = @splat(.{});

pub const Float = struct { node: i16, rect: Rect };

pub const Workspace = struct {
    name_buf: [24]u8 = @splat(0),
    name_len: u8 = 0,
    root: i16 = -1,
    maximized: i16 = -1,
    floats: [8]Float = undefined,
    nfloats: usize = 0,

    pub fn name(w: *const Workspace) []const u8 {
        return w.name_buf[0..w.name_len];
    }
    pub fn setName(w: *Workspace, s: []const u8) void {
        const n = @min(s.len, w.name_buf.len);
        w.name_buf = @splat(0);
        @memcpy(w.name_buf[0..n], s[0..n]);
        w.name_len = @intCast(n);
    }
};

pub const MAX_WS = 12;
pub var workspaces: [MAX_WS]Workspace = @splat(.{});
pub var n_ws: usize = 0;
pub var cur_ws: usize = 0;

pub fn ws() *Workspace {
    return &workspaces[cur_ws];
}

pub fn N(i: i16) *Node {
    return &nodes[@intCast(i)];
}

pub fn alloc() i16 {
    for (&nodes, 0..) |*n, i| {
        if (!n.used) {
            n.* = .{ .used = true };
            return @intCast(i);
        }
    }
    return -1;
}

fn freeNodes() usize {
    var n: usize = 0;
    for (nodes) |nd| {
        if (!nd.used) n += 1;
    }
    return n;
}

fn leaf(e: Editor) i16 {
    const i = alloc();
    if (i >= 0) N(i).editor = e;
    return i;
}

fn split(a: i16, b: i16, vertical: bool, ratio: f32) i16 {
    const i = alloc();
    if (i < 0) return i;
    const n = N(i);
    n.leaf = false;
    n.vertical = vertical;
    n.ratio = ratio;
    n.a = a;
    n.b = b;
    N(a).parent = i;
    N(b).parent = i;
    return i;
}

fn addWorkspace(nm: []const u8, root: i16) void {
    if (n_ws >= MAX_WS) return;
    workspaces[n_ws] = .{};
    workspaces[n_ws].setName(nm);
    workspaces[n_ws].root = root;
    n_ws += 1;
}

fn buildLayouts() void {
    // Modeling: Tools | (Viewport / Console) | (Outliner / Properties)
    {
        const center = split(leaf(.viewport), leaf(.console), false, 0.80);
        const right = split(leaf(.outliner), leaf(.properties), false, 0.17);
        addWorkspace("Modeling", split(leaf(.tools), split(center, right, true, 0.765), true, 0.16));
    }
    // Sculpt: Tools | Viewport | Properties
    {
        addWorkspace("Sculpt", split(leaf(.tools), split(leaf(.viewport), leaf(.properties), true, 0.78), true, 0.14));
    }
    // CAD: Tools | (Viewport / Console) | Properties
    {
        const center = split(leaf(.viewport), leaf(.console), false, 0.74);
        addWorkspace("CAD", split(leaf(.tools), split(center, leaf(.properties), true, 0.72), true, 0.15));
    }
    // Shading: (Viewport / Node Editor) | Properties (on its Material tab)
    {
        const pr = leaf(.properties);
        N(pr).tab = 2;
        addWorkspace("Shading", split(split(leaf(.viewport), leaf(.nodes), false, 36000.0 / 65536.0), pr, true, 50000.0 / 65536.0));
    }
    // Animation: (Viewport / (Dope Sheet / Timeline)) | Properties
    {
        const keys = split(leaf(.dopesheet), leaf(.timeline), false, 45000.0 / 65536.0);
        const left = split(leaf(.viewport), keys, false, 40000.0 / 65536.0);
        const pr = leaf(.properties);
        N(pr).tab = 8; // (the Animation tab)
        addWorkspace("Animation", split(left, pr, true, 50000.0 / 65536.0));
    }
    // World: Viewport | (Outliner / Properties)
    {
        addWorkspace("World", split(leaf(.viewport), split(leaf(.outliner), leaf(.properties), false, 0.4), true, 0.75));
    }
}

fn layoutNode(i: i16, r: Rect) void {
    const n = N(i);
    n.rect = r;
    if (n.leaf) return;
    if (n.vertical) {
        const aw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(r.w - SPLIT)) * n.ratio));
        layoutNode(n.a, .{ .x = r.x, .y = r.y, .w = aw, .h = r.h });
        layoutNode(n.b, .{ .x = r.x + aw + SPLIT, .y = r.y, .w = r.w - aw - SPLIT, .h = r.h });
    } else {
        const ah: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(r.h - SPLIT)) * n.ratio));
        layoutNode(n.a, .{ .x = r.x, .y = r.y, .w = r.w, .h = ah });
        layoutNode(n.b, .{ .x = r.x, .y = r.y + ah + SPLIT, .w = r.w, .h = r.h - ah - SPLIT });
    }
}

fn splitterRect(n: *const Node) Rect {
    const a = N(n.a).rect;
    return if (n.vertical)
        .{ .x = a.right(), .y = n.rect.y, .w = SPLIT, .h = n.rect.h }
    else
        .{ .x = n.rect.x, .y = a.bottom(), .w = n.rect.w, .h = SPLIT };
}

fn leafAt(i: i16, x: i32, y: i32) ?i16 {
    const n = N(i);
    if (!n.rect.contains(x, y)) return null;
    if (n.leaf) return i;
    return leafAt(n.a, x, y) orelse leafAt(n.b, x, y);
}

fn countLeaves(i: i16) usize {
    const n = N(i);
    return if (n.leaf) 1 else countLeaves(n.a) + countLeaves(n.b);
}

pub fn freeTree(i: i16) void {
    const n = N(i);
    if (!n.leaf) {
        freeTree(n.a);
        freeTree(n.b);
    }
    n.used = false;
}

fn copyTree(i: i16) i16 {
    const n = N(i);
    const c = alloc();
    if (c < 0) return -1;
    N(c).* = n.*;
    N(c).parent = -1;
    if (!n.leaf) {
        const a = copyTree(n.a);
        const b = copyTree(n.b);
        if (a < 0 or b < 0) return -1;
        N(c).a = a;
        N(c).b = b;
        N(a).parent = c;
        N(b).parent = c;
    }
    return c;
}

fn inTree(root: i16, i: i16) bool {
    if (root < 0) return false;
    if (root == i) return true;
    const n = N(root);
    return !n.leaf and (inTree(n.a, i) or inTree(n.b, i));
}

/// Split leaf i in two, both showing the same editor.
fn splitArea(i: i16, vertical: bool) void {
    const a = alloc();
    if (a < 0) return;
    const b = alloc();
    if (b < 0) {
        N(a).used = false;
        return;
    }
    N(a).* = N(i).*;
    N(b).* = N(i).*;
    N(a).parent = i;
    N(b).parent = i;
    const n = N(i);
    n.leaf = false;
    n.vertical = vertical;
    n.ratio = 0.5;
    n.a = a;
    n.b = b;
    ws().maximized = -1;
    abort_frame = true;
    if (active_area == i) active_area = a;
}

/// Take leaf i out of the tree; its sibling takes the parent's place.
/// Returns where the sibling now lives (it moves into the parent's slot).
fn detach(i: i16) ?struct { old: i16, new: i16 } {
    const p = N(i).parent;
    if (p < 0) return null;
    const pn = N(p);
    const s = if (pn.a == i) pn.b else pn.a;
    const gp = pn.parent;
    pn.* = N(s).*;
    pn.parent = gp;
    if (!pn.leaf) {
        N(pn.a).parent = p;
        N(pn.b).parent = p;
    }
    N(s).used = false;
    N(i).parent = -1;
    ws().maximized = -1;
    abort_frame = true;
    if (active_area == s) active_area = p;
    return .{ .old = s, .new = p };
}

pub const Side = enum { left, right, top, bottom, center };

/// Put leaf f (out of the tree) next to leaf t.
fn dock(f: i16, t: i16, side: Side) void {
    if (side == .center) return;
    const c = alloc();
    if (c < 0) return;
    N(c).* = N(t).*;
    const n = N(t);
    n.leaf = false;
    n.vertical = side == .left or side == .right;
    const first = side == .left or side == .top;
    n.a = if (first) f else c;
    n.b = if (first) c else f;
    n.ratio = if (first) 0.35 else 0.65;
    N(f).parent = t;
    N(c).parent = t;
    ws().maximized = -1;
    abort_frame = true;
    if (active_area == t) active_area = c;
}

/// Swap what two leaves show (editors keep their views).
fn swapLeaves(a: i16, b: i16) void {
    const na = N(a);
    const nb = N(b);
    std.mem.swap(Editor, &na.editor, &nb.editor);
    std.mem.swap(vp.View, &na.view, &nb.view);
    std.mem.swap(i32, &na.scroll, &nb.scroll);
    std.mem.swap(u8, &na.tab, &nb.tab);
}

/// Move leaf i (in the tree) next to leaf t, or swap with it (center).
fn moveArea(i: i16, t0: i16, side: Side) void {
    if (i == t0) return;
    if (side == .center) {
        swapLeaves(i, t0);
        active_area = t0;
        return;
    }
    var t = t0;
    const d = detach(i) orelse return;
    if (t == d.old) t = d.new;
    dock(i, t, side);
    active_area = i;
}

fn floatIndex(node: i16) ?usize {
    const w = ws();
    for (w.floats[0..w.nfloats], 0..) |f, i| {
        if (f.node == node) return i;
    }
    return null;
}

fn removeFloat(i: usize) void {
    const w = ws();
    pw.closeNode(w.floats[i].node);
    var k = i;
    while (k + 1 < w.nfloats) : (k += 1) w.floats[k] = w.floats[k + 1];
    w.nfloats -= 1;
}

fn raiseFloat(i: usize) void {
    const w = ws();
    const f = w.floats[i];
    removeFloat(i);
    w.floats[w.nfloats] = f;
    w.nfloats += 1;
}

fn floatArea(i: i16, x: i32, y: i32) void {
    const w = ws();
    if (w.nfloats >= w.floats.len) {
        toast(.warn, "No room for more floating panels", .{});
        return;
    }
    const r = N(i).rect;
    if (detach(i) == null) {
        toast(.warn, "The last area cannot float", .{});
        return;
    }
    w.floats[w.nfloats] = .{ .node = i, .rect = .{ .x = x, .y = y, .w = std.math.clamp(r.w, 260, 520), .h = std.math.clamp(r.h, 200, 420) } };
    w.nfloats += 1;
    active_area = i;
}

fn firstViewport(i: i16) i16 {
    if (i < 0) return -1;
    const n = N(i);
    if (n.leaf) return if (n.editor == .viewport) i else -1;
    const a = firstViewport(n.a);
    return if (a >= 0) a else firstViewport(n.b);
}

fn firstEditor(i: i16, e: Editor) i16 {
    if (i < 0) return -1;
    const n = N(i);
    if (n.leaf) return if (n.editor == e) i else -1;
    const a = firstEditor(n.a, e);
    return if (a >= 0) a else firstEditor(n.b, e);
}

fn biggestLeaf(i: i16) i16 {
    const n = N(i);
    if (n.leaf) return i;
    const a = biggestLeaf(n.a);
    const b = biggestLeaf(n.b);
    return if (N(a).rect.w * N(a).rect.h >= N(b).rect.w * N(b).rect.h) a else b;
}

fn isFloating(i: i16) bool {
    return floatIndex(i) != null;
}

/// Whether area i belongs to the current workspace (tree or panel).
pub fn areaValid(i: i16) bool {
    if (i < 0 or !N(i).used or !N(i).leaf) return false;
    return inTree(ws().root, i) or isFloating(i);
}

// --- the active area (what area.* and view.* commands act on) ------------

var active_area: i16 = -1;
/// The leaf under the pointer this frame (-1: none).
var hover_area: i16 = -1;
/// The area under the pointer (-1: none).
pub fn hoverArea() i16 {
    return if (hover_area >= 0 and areaValid(hover_area)) hover_area else -1;
}
/// F6 draws a ring round the active area until the next click.
var area_ring: bool = false;

pub fn activeArea() i16 {
    if (!areaValid(active_area)) {
        active_area = firstViewport(ws().root);
        if (active_area < 0) active_area = biggestLeaf(ws().root);
    }
    return active_area;
}

pub fn setActiveArea(i: i16) void {
    if (areaValid(i)) active_area = i;
}

/// The viewport commands act on: the active area if it is one, else the first.
pub fn viewportArea() i16 {
    const a = activeArea();
    if (a >= 0 and N(a).editor == .viewport) return a;
    const w = ws();
    if (w.maximized >= 0 and N(w.maximized).leaf and N(w.maximized).editor == .viewport) return w.maximized;
    const v = firstViewport(w.root);
    if (v >= 0) return v;
    for (w.floats[0..w.nfloats]) |f| {
        if (N(f.node).editor == .viewport) return f.node;
    }
    return -1;
}

pub fn activeEditor() ?Editor {
    const a = activeArea();
    return if (a >= 0) N(a).editor else null;
}

pub fn setActiveEditor(e: Editor) void {
    const a = activeArea();
    if (a >= 0) N(a).editor = e;
}

pub fn canSplit() ?[]const u8 {
    const a = activeArea();
    if (a < 0) return "No area";
    if (isFloating(a)) return "A floating panel cannot be split";
    if (freeNodes() < 2) return "No room for more areas";
    return null;
}

pub fn canClose() ?[]const u8 {
    const a = activeArea();
    if (a < 0) return "No area";
    if (!isFloating(a) and countLeaves(ws().root) <= 1) return "The last area cannot be closed";
    return null;
}

pub fn canFloat() ?[]const u8 {
    const a = activeArea();
    if (a < 0) return "No area";
    if (isFloating(a)) return "The area already floats";
    if (countLeaves(ws().root) <= 1) return "The last area cannot float";
    if (ws().nfloats >= ws().floats.len) return "No room for more floating panels";
    return null;
}

pub fn canDock() ?[]const u8 {
    const a = activeArea();
    if (a < 0 or !isFloating(a)) return "Only a floating panel can be docked";
    return null;
}

pub fn splitActive(vertical: bool) void {
    splitArea(activeArea(), vertical);
}

pub fn maximizeActive() void {
    const a = activeArea();
    if (a < 0 or isFloating(a)) return;
    ws().maximized = if (ws().maximized == a) -1 else a;
    abort_frame = true;
}

/// The command line is about to be used: a maximized area that hides it steps back,
/// as a line typed into nothing would fire shortcuts (the original types there blind).
pub fn revealConsole() void {
    const w = ws();
    if (w.maximized < 0 or firstEditor(w.maximized, .console) >= 0) return;
    for (w.floats[0..w.nfloats]) |f| {
        if (N(f.node).editor == .console) return;
    }
    w.maximized = -1;
    abort_frame = true;
}

pub fn isMaximized() bool {
    return ws().maximized >= 0;
}

pub fn closeActive() void {
    closeArea(activeArea());
}

fn closeArea(i: i16) void {
    if (i < 0) return;
    if (floatIndex(i)) |fx| {
        removeFloat(fx);
        freeTree(i);
        abort_frame = true;
    } else if (detach(i) != null) {
        freeTree(i);
    } else {
        toast(.warn, "The last area cannot be closed", .{});
    }
}

pub fn floatActive() void {
    const a = activeArea();
    const r = N(a).rect;
    floatArea(a, r.x + 40, r.y + 40);
}

pub fn dockActive() void {
    const a = activeArea();
    const fx = floatIndex(a) orelse return;
    const r = ws().floats[fx].rect;
    removeFloat(fx);
    // beside the area under the panel's middle, else the biggest one
    const t = leafAt(ws().root, r.x + @divTrunc(r.w, 2), r.y + @divTrunc(r.h, 2)) orelse biggestLeaf(ws().root);
    const tr = N(t).rect;
    const side: Side = if (r.x + @divTrunc(r.w, 2) < tr.x + @divTrunc(tr.w, 2)) .left else .right;
    dock(a, t, side);
    toast(.ok, "Docked {s}", .{N(a).editor.label()});
}

/// A Render area: the first there is, else the 3D viewport split side by
/// side with the render on the right (render.s split_with). -1: no room.
pub fn ensureRenderArea() i16 {
    const w = ws();
    const f = firstEditor(w.root, .render);
    if (f >= 0) return f;
    for (w.floats[0..w.nfloats]) |fl| {
        if (N(fl.node).editor == .render) return fl.node;
    }
    const v = viewportArea();
    if (v < 0 or !N(v).leaf or freeNodes() < 2) return -1;
    var in_tree = false;
    var p = v;
    while (p >= 0) : (p = N(p).parent) {
        if (p == w.root) in_tree = true;
    }
    if (!in_tree) return -1;
    splitArea(v, true);
    const b = N(v).b;
    N(b).editor = .render;
    return b;
}

/// The Properties' Render tab (a Properties area opens when there is none).
pub fn showRenderSettings() void {
    var pa = firstEditor(ws().root, .properties);
    if (pa < 0) {
        togglePane(.outliner);
        pa = firstEditor(ws().root, .properties);
    }
    if (pa >= 0) N(pa).tab = 6;
    dirty = true;
}

pub fn hasEditor(e: Editor) bool {
    if (firstEditor(ws().root, e) >= 0) return true;
    for (ws().floats[0..ws().nfloats]) |f| {
        if (N(f.node).editor == e) return true;
    }
    return false;
}

/// View > Tools / Outliner / Console Pane: show or hide them.
pub fn togglePane(e: Editor) void {
    const w = ws();
    w.maximized = -1;
    abort_frame = true;
    if (hasEditor(e)) {
        // close every area of that kind (and Properties with the Outliner)
        var guard: usize = 0;
        while (guard < 16) : (guard += 1) {
            var t = firstEditor(w.root, e);
            if (t < 0 and e == .outliner) t = firstEditor(w.root, .properties);
            if (t < 0) break;
            if (countLeaves(w.root) <= 1) break;
            _ = detach(t);
            freeTree(t);
        }
        var k = w.nfloats;
        while (k > 0) {
            k -= 1;
            if (N(w.floats[k].node).editor == e) {
                freeTree(w.floats[k].node);
                removeFloat(k);
            }
        }
        return;
    }
    if (freeNodes() < 4) return;
    switch (e) {
        .tools => w.root = split(leaf(.tools), w.root, true, 0.15),
        .outliner => w.root = split(w.root, split(leaf(.outliner), leaf(.properties), false, 0.35), true, 0.78),
        else => w.root = split(w.root, leaf(e), false, 0.8),
    }
    N(w.root).parent = -1;
}

/// view.toggle_activity: the AI Activity area beside the console (when there
/// is none, where a console would come), or every one closed.
pub fn toggleActivity() void {
    if (hasEditor(.activity)) return togglePane(.activity);
    const c = firstEditor(ws().root, .console);
    if (c < 0) return togglePane(.activity);
    if (freeNodes() < 4) return;
    splitArea(c, true);
    if (!N(c).leaf) N(N(c).b).editor = .activity;
}

fn leavesInOrder(i: i16, out: []i16, n: *usize) void {
    const nd = N(i);
    if (nd.leaf) {
        if (n.* < out.len) {
            out[n.*] = i;
            n.* += 1;
        }
        return;
    }
    leavesInOrder(nd.a, out, n);
    leavesInOrder(nd.b, out, n);
}

/// F6 / Shift+F6: make the next / previous area the active one.
pub fn cycleArea(dir: i32) void {
    var list: [80]i16 = undefined;
    var n: usize = 0;
    leavesInOrder(if (ws().maximized >= 0) ws().maximized else ws().root, &list, &n);
    for (ws().floats[0..ws().nfloats]) |f| {
        if (n < list.len) {
            list[n] = f.node;
            n += 1;
        }
    }
    if (n == 0) return;
    const a = activeArea();
    var k: usize = 0;
    while (k < n and list[k] != a) k += 1;
    const ni: usize = if (k >= n) 0 else @intCast(@mod(@as(i64, @intCast(k)) + dir, @as(i64, @intCast(n))));
    active_area = list[ni];
    area_ring = true;
    toast(.ok, "Active area: {s}", .{N(active_area).editor.label()});
}

// --- workspaces -----------------------------------------------------------

pub fn workspaceCount() usize {
    return n_ws;
}

pub fn switchWorkspace(i: usize) void {
    if (i >= n_ws or i == cur_ws) return;
    pw.closeAll(); // (their windows come back in as floating panels)
    cur_ws = i;
    abort_frame = true;
    active_area = -1;
    renaming_ws = null;
    toast(.ok, "Workspace: {s}", .{ws().name()});
    wsfile.persist();
}

/// New workspaces came in (wsfile.zig): nothing may hold on to the old areas.
pub fn workspacesReplaced(active: i16) void {
    abort_frame = true;
    active_area = active;
    renaming_ws = null;
    hover_area = -1;
    hdrag = null;
    join_from = -1;
    join_preview = null;
    if (xform.active) xform.cancel();
    @import("uved.zig").end(true);
    // (the command line stays the one typed in, in the areas that came)
    if (editors.in_command or editors.consoleTyping()) {
        if (hasEditor(.console)) editors.focusConsole();
    }
    dirty = true;
}

pub fn workspaceStep(d: i32) void {
    const n: i32 = @intCast(n_ws);
    switchWorkspace(@intCast(@mod(@as(i32, @intCast(cur_ws)) + d + n, n)));
}

pub fn workspaceNew() void {
    if (n_ws >= MAX_WS) {
        toast(.warn, "No room for more workspaces", .{});
        return;
    }
    const root = copyTree(ws().root);
    if (root < 0) {
        toast(.warn, "No room for more areas", .{});
        return;
    }
    var buf: [24]u8 = undefined;
    const nm = std.fmt.bufPrint(&buf, "Custom {d}", .{@as(i64, @intCast(n_ws)) - 5}) catch "Custom";
    addWorkspace(nm, root);
    switchWorkspace(n_ws - 1);
}

/// wsp_ai: the AI workspace shown (made the first time: a viewport, the AI
/// Assistant above an outliner, the AI Assistant active).
pub fn workspaceAi() void {
    for (workspaces[0..n_ws], 0..) |*w, k| {
        if (std.mem.eql(u8, w.name(), "AI")) return switchWorkspace(k);
    }
    if (n_ws >= MAX_WS) return;
    const vpl = leaf(.viewport);
    const ail = leaf(.ai);
    const ol = leaf(.outliner);
    if (vpl < 0 or ail < 0 or ol < 0) return;
    // (the view this workspace's viewport has, as the original's copy of it)
    const v = viewportArea();
    if (v >= 0) N(vpl).view = N(v).view;
    const right = split(ail, ol, false, 47000.0 / 65536.0);
    if (right < 0) return;
    const root = split(vpl, right, true, 40000.0 / 65536.0);
    if (root < 0) return;
    addWorkspace("AI", root);
    switchWorkspace(n_ws - 1);
    active_area = ail;
}

pub fn workspaceDelete() void {
    if (n_ws < 2) return;
    pw.closeAll();
    const w = ws();
    freeTree(w.root);
    for (w.floats[0..w.nfloats]) |f| freeTree(f.node);
    var k = cur_ws;
    while (k + 1 < n_ws) : (k += 1) workspaces[k] = workspaces[k + 1];
    n_ws -= 1;
    cur_ws = @min(cur_ws, n_ws - 1);
    abort_frame = true;
    active_area = -1;
    toast(.ok, "Workspace: {s}", .{ws().name()});
    wsfile.persist();
}

var renaming_ws: ?usize = null;
const RENAME_ID: u32 = 0x5e7a3e;

pub fn workspaceRename() void {
    renaming_ws = cur_ws;
    ui.editSet(RENAME_ID, ws().name(), true);
}

// --- viewport commands --------------------------------------------------------

pub fn toggleWire() void {
    const v = viewportArea();
    if (v < 0) return;
    const vw = &N(v).view;
    // as the original: wireframe, or back to Solid
    if (vw.wire) vw.wire = false else {
        vw.wire = true;
        vw.material = false;
        vw.rendered = false;
    }
}

pub fn isWire() bool {
    const v = viewportArea();
    return v >= 0 and N(v).view.wire;
}

/// Views glide to where they go (Preferences > Reduce motion: jump).
const GLIDE_MS = 260;

fn glideTo(v: *vp.View, to: vp.Pose) void {
    vp.leaveCamView(v);
    if (prefs.reduce_motion) {
        v.setPose(to);
        v.gliding = false;
        return;
    }
    v.glide_from = v.pose();
    v.glide_to = to;
    // turn the short way round
    while (v.glide_to.yaw - v.glide_from.yaw > 180) v.glide_to.yaw -= 360;
    while (v.glide_to.yaw - v.glide_from.yaw < -180) v.glide_to.yaw += 360;
    v.glide_t0 = now_ms;
    v.gliding = true;
    dirty = true;
}

/// A job just ended: its change is one undo step.
pub fn afterJob() void {
    undo.sync();
    dirty = true;
}

/// Advance every gliding view; ms until the next step, or null.
fn tickGlides() ?i32 {
    var any = false;
    for (&nodes) |*nd| {
        if (!nd.used or !nd.leaf or !nd.view.gliding) continue;
        const v = &nd.view;
        const t = @min(1.0, @as(f32, @floatFromInt(now_ms - v.glide_t0)) / GLIDE_MS);
        const e = t * t * (3 - 2 * t); // ease in and out
        const a = v.glide_from;
        const b = v.glide_to;
        v.yaw = a.yaw + (b.yaw - a.yaw) * e;
        v.pitch = a.pitch + (b.pitch - a.pitch) * e;
        v.dist = a.dist + (b.dist - a.dist) * e;
        v.target = m.lerp(a.target, b.target, e);
        if (t >= 1) v.gliding = false else any = true;
        dirty = true;
    }
    return if (any) 16 else null;
}

pub fn resetView() void {
    const v = viewportArea();
    if (v < 0) return;
    N(v).view.ortho = false;
    glideTo(&N(v).view, .{});
}

pub fn alignView(yaw: f32, pitch: f32) void {
    const v = viewportArea();
    if (v < 0) return;
    var p = N(v).view.pose();
    p.yaw = yaw;
    p.pitch = pitch;
    glideTo(&N(v).view, p);
}

/// Numpad .: turn and zoom onto the selection (or everything).
pub fn frameSelected() void {
    const v = viewportArea();
    if (v < 0) return;
    var lo: m.V3 = .{ 1e9, 1e9, 1e9 };
    var hi: m.V3 = .{ -1e9, -1e9, -1e9 };
    var any = false;
    const use_sel = scene.nSelected() > 0;
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!o.visible or (use_sel and !o.selected)) continue;
        if (!use_sel and o.isGround()) continue; // (the whole scene: not the endless Ground)
        const w = scene.world(oi);
        if (@import("mods.zig").of(oi)) |me| {
            // the mesh's bounds, through its world matrix
            for (0..8) |k| {
                const p: m.V3 = .{ if (k & 1 != 0) me.hi[0] else me.lo[0], if (k & 2 != 0) me.hi[1] else me.lo[1], if (k & 4 != 0) me.hi[2] else me.lo[2] };
                const q = m.xform(w, p);
                for (0..3) |j| {
                    lo[j] = @min(lo[j], q[j]);
                    hi[j] = @max(hi[j], q[j]);
                }
            }
        } else {
            const p: m.V3 = .{ w[3], w[7], w[11] };
            for (0..3) |j| {
                lo[j] = @min(lo[j], p[j] - 0.5);
                hi[j] = @max(hi[j], p[j] + 0.5);
            }
        }
        any = true;
    }
    if (!any) return;
    const c = m.scale(m.add(lo, hi), 0.5);
    const rad = @max(0.5, m.len(m.sub(hi, lo)) * 0.5);
    var p = N(v).view.pose();
    p.target = c;
    p.dist = std.math.clamp(rad / @tan(vp.fov * 0.5 * m.deg) * 1.15, 1.0, 200.0);
    glideTo(&N(v).view, p);
}

/// Extrude: move the new faces along their normal (as G with that axis).
pub fn beginTransformAlong(dir: m.V3) bool {
    const v = viewportArea();
    if (v < 0) return false;
    const r = N(v).rect;
    var mx = ui.mx;
    var my = ui.my;
    if (!r.contains(mx, my)) {
        mx = r.x + @divTrunc(r.w, 2) + 80;
        my = r.y + @divTrunc(r.h, 2);
    }
    if (!xform.beginAlong(dir, v, mx, my)) return false;
    ui.active = 0;
    return true;
}

/// Inset / Extrude Individual: the mouse sets the value.
pub fn beginMeshTool(t: @import("meshops.zig").Tool) bool {
    const v = viewportArea();
    if (v < 0) return false;
    const n = N(v);
    const body = editors.bodyRect(n.rect);
    const c = vp.Cam.init(&n.view, body);
    const em = @import("editmesh.zig");
    const ps = if (em.active) c.pixelSize(scene.worldLoc(em.obj)) else 0.01;
    return @import("meshops.zig").start(t, ui.mx, ps);
}

pub fn beginTransform(md: xform.Mode) bool {
    const v = viewportArea();
    if (v < 0) return false;
    // the pointer must be over the viewport for the mouse to drive it
    const r = N(v).rect;
    var mx = ui.mx;
    var my = ui.my;
    if (!r.contains(mx, my)) {
        mx = r.x + @divTrunc(r.w, 2) + 80;
        my = r.y + @divTrunc(r.h, 2);
    }
    if (!xform.begin(md, v, mx, my)) return false;
    ui.active = 0;
    return true;
}

// --- tools ----------------------------------------------------------------------

pub const Tool = enum { select, move, rotate, scale };
pub var tool: Tool = .select;

pub fn setTheme(t: *const theme.Theme) void {
    theme.set(t);
    prefs.save();
    toast(.ok, "Theme: {s}", .{t.name});
}

// --- console log and toasts ------------------------------------------------------

const LOG_N = 400;
var log_lines: [LOG_N][160]u8 = undefined;
var log_len: [LOG_N]u8 = undefined;
pub var log_count: usize = 0;
var log_start: usize = 0; // after Clear

pub fn log(comptime fmt: []const u8, args: anytype) void {
    const slot = log_count % LOG_N;
    const s = std.fmt.bufPrint(&log_lines[slot], fmt, args) catch log_lines[slot][0..];
    log_len[slot] = @intCast(s.len);
    log_count += 1;
    dirty = true;
}

pub fn logLine(i: usize) []const u8 {
    const slot = i % LOG_N;
    return log_lines[slot][0..log_len[slot]];
}

/// The first line the console still shows.
pub fn logFirst() usize {
    return @max(log_start, log_count -| LOG_N);
}

pub fn clearLog() void {
    log_start = log_count;
}

pub const ToastKind = enum { ok, warn };

/// A message above the status bar for four seconds (a Zui toast, at the
/// bottom right): green for results, amber for problems. It goes to the
/// console too. A newer one takes the place of the last; a click on it
/// opens the console.
pub fn toast(kind: ToastKind, comptime fmt: []const u8, args: anytype) void {
    var b: [160]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch b[0..];
    @import("zuihost.zig").toast(kind == .ok, s);
    log("{s}{s}", .{ if (kind == .warn) "! " else "", s });
    dirty = true;
}

/// A message as the original's log_line shows it (a console line and a
/// toast, the amber one marked by colour only, not by "! ").
pub fn toastLine(kind: ToastKind, s: []const u8) void {
    var t = s;
    while (t.len > 0 and t[0] == ' ') t = t[1..];
    @import("zuihost.zig").toast(kind == .ok, t);
    log("{s}", .{s});
    dirty = true;
}

/// A toast was clicked: the console, typed in.
pub fn toastClicked() void {
    if (!hasEditor(.console)) togglePane(.console);
    editors.focusConsole();
}

pub fn focusConsole() void {
    editors.focusConsole();
}

pub fn openPalette() void {
    menus.openPalette();
}

pub fn openDialog(d: dialogs.Kind) void {
    menus.close();
    dialogs.open(d);
}

// --- frame ----------------------------------------------------------------------

var win_w: i32 = 0;
var win_h: i32 = 0;

pub fn winW() i32 {
    return win_w;
}
pub fn winH() i32 {
    return win_h;
}
pub fn contentTop() i32 {
    return TITLE_H + MENU_H;
}

fn contentRect() Rect {
    return .{ .x = 0, .y = TITLE_H + MENU_H, .w = win_w, .h = win_h - TITLE_H - MENU_H - STATUS_H };
}

fn computeHotLayer() u8 {
    if (ui.active != 0) return ui.active_layer;
    return layerAt(ui.mx, ui.my);
}

/// The layer of BeeModel's own UI that has the point (x, y): a dialog, the
/// palette, a menu or pie, a floating panel, else the base. Zui's parts drawn
/// on a lower layer don't get the pointer there (zuihost).
pub fn layerAt(x: i32, y: i32) u8 {
    if (menus.isOpen() and dialogs.isOpen()) return ui.L_POPUP + 130; // a menu over a dialog
    if (dialogs.isOpen() or filebrowser.open_ or files.asking or files.asking_lossy or @import("autosave.zig").asking) return ui.L_DIALOG;
    if (menus.palette) return ui.L_DIALOG;
    if (menus.isOpen() or pies.wheel_open or pies.pie_open) return ui.L_POPUP;
    const w = ws();
    var i = w.nfloats;
    while (i > 0) {
        i -= 1;
        if (pw.slotOf(w.floats[i].node) >= 0) continue; // (in a window of its own)
        if (w.floats[i].rect.contains(x, y)) return ui.L_FLOAT + @as(u8, @intCast(i));
    }
    return ui.L_BASE;
}

/// The whole UI. Runs as a hit pass (ui.hit) or a draw pass.
pub fn frame(cv: *gfx.Canvas) void {
    // (then the keys that waited for this frame: zuihost.hold)
    defer if (cv.enabled) @import("zuihost.zig").replayHeld(cv);
    const sculpt_t0 = if (cv.enabled) @import("sculpt.zig").nowNs() else 0;
    defer if (cv.enabled) @import("sculpt.zig").noteFrame(@import("sculpt.zig").nowNs() - sculpt_t0);
    // the pointer is in another window: not here
    const keep_mx = ui.mx;
    const keep_my = ui.my;
    defer if (pw.cur >= 0) {
        ui.mx = keep_mx;
        ui.my = keep_my;
    };
    if (pw.cur >= 0) {
        ui.mx = -1000;
        ui.my = -1000;
    }
    ui.cv = cv;
    ui.now_ms = now_ms;
    win_w = cv.full().w;
    win_h = cv.full().h;
    cv.clip = cv.full();
    ui.cursor = .default;
    ui.hot_layer = computeHotLayer();
    ui.layer = ui.L_BASE;
    ui.rec_n = 0;
    @import("anim.zig").frameBegin(); // drivers, onion skins
    wg.begin();
    ui.tipBegin();
    @import("editmesh.zig").validate();
    @import("sculpt.zig").validate();
    abort_frame = false;
    const th = ui.th;

    cv.fill(cv.full(), th.split);
    const content = contentRect();
    const w = ws();
    if (w.maximized >= 0 and !areaValid(w.maximized)) w.maximized = -1;
    if (w.maximized >= 0) layoutNode(w.maximized, content) else layoutNode(w.root, content);
    hover_area = -1;

    join_preview = null;
    drawTree(if (w.maximized >= 0) w.maximized else w.root);
    if (join_preview) |jp| {
        // the area that would go: dark with a cross when it can, red when not
        cv.blend(jp.rect, if (jp.ok) 0x000000 else th.close_hot, 90);
        const c = Rect{ .x = jp.rect.x + @divTrunc(jp.rect.w, 2) - 60, .y = jp.rect.y + @divTrunc(jp.rect.h, 2) - 12, .w = 120, .h = 24 };
        cv.fillRound(c, 4, th.drop_bg);
        cv.textCentered(c, if (jp.ok) "Join here" else "Cannot join", th.text);
    }
    drawStatus();
    drawTitle();
    drawMenuBar();
    if (!abort_frame) drawHeaderDrag();

    // floating panels
    var fi: usize = 0;
    while (!abort_frame and fi < ws().nfloats) : (fi += 1) {
        if (pw.slotOf(ws().floats[fi].node) >= 0) continue;
        ui.layer = ui.L_FLOAT + @as(u8, @intCast(fi));
        drawFloat(fi);
    }
    ui.layer = ui.L_BASE;
    if (area_ring and !abort_frame) {
        const a = activeArea();
        if (a >= 0) {
            const r = N(a).rect;
            cv.rectLine(r, th.focus);
            cv.rectLine(r.inset(1), th.focus);
        }
    }

    ui.layer = ui.L_POPUP;
    if (!abort_frame) {
        if (!dialogs.isOpen() and menus.owner < 0) menus.draw();
        if (menus.owner >= 0 and ui.hit and ui.pressed != 0) menus.close();
    }
    ui.layer = ui.L_DIALOG;
    // Zui's frame ends (zuihost.zig): its dialogs, windows and popups over BeeModel's.
    // Always, so a frame begun by a part in an area is closed even if this one stopped.
    @import("zuihost.zig").frame();
    if (cv.enabled) @import("drop.zig").flush(); // (files dropped: a zone of Zui's saw them)
    menus.afterZuiFrame();
    if (!abort_frame) {
        menus.drawPalette();
        files.poll();
    }
    if (!abort_frame and dialogs.isOpen() and menus.isOpen()) {
        ui.layer = ui.L_POPUP + 130;
        menus.draw();
    }
    if (!abort_frame and cv.enabled) wg.drawRing();
    drawTooltip();
    windowEdges();

    ui.tipEnd();
    if (ui.hit) {
        if (hover_area >= 0 and (ui.dx != 0 or ui.dy != 0 or ui.pressed != 0)) active_area = hover_area;
        if (ui.pressed != 0) area_ring = false;
        if (ui.released != 0 and ui.down == 0) ui.active = 0;
        if (raise_float) |r| {
            raiseFloat(r);
            raise_float = null;
        }
        if (win) |wn| wn.setCursor(ui.cursor);
    }
    if (cv.enabled and !abort_frame) @import("live.zig").frameEnd();
}

var raise_float: ?usize = null;
/// The area tree changed mid-frame (split, close, dock...): stop walking it.
var abort_frame: bool = false;

fn drawTree(i: i16) void {
    const n = N(i);
    if (n.leaf) {
        drawArea(i, n.rect, false);
        return;
    }
    drawTree(n.a);
    if (abort_frame) return;
    drawTree(n.b);
    if (abort_frame) return;
    // splitter
    const sr = splitterRect(n);
    const sid = ui.id(@src(), @intCast(i));
    const grab = Rect{ .x = sr.x - 2, .y = sr.y - 2, .w = sr.w + 4, .h = sr.h + 4 };
    const hv = ui.hover(sid, grab);
    if (hv or ui.isActive(sid)) {
        ui.cursor = if (n.vertical) .ew_resize else .ns_resize;
        ui.cv.fill(sr, ui.th.split_hot);
    }
    _ = ui.pressDrag(sid, grab, ui.LMB);
    if (ui.hit and ui.isActive(sid)) {
        if (n.vertical) {
            const span: f32 = @floatFromInt(n.rect.w - SPLIT);
            const lo = @min(0.5, 60.0 / span);
            n.ratio = std.math.clamp(@as(f32, @floatFromInt(ui.mx - n.rect.x)) / span, lo, 1.0 - lo);
        } else {
            const span: f32 = @floatFromInt(n.rect.h - SPLIT);
            const lo = @min(0.5, (HDR_H + 10.0) / span);
            n.ratio = std.math.clamp(@as(f32, @floatFromInt(ui.my - n.rect.y)) / span, lo, 1.0 - lo);
        }
    }
}

fn iconButton(wid: u32, r: Rect, kind: u8, tip_op: []const u8) bool {
    const th = ui.th;
    const hv = ui.hover(wid, r);
    if (hv) ui.cv.fillRound(r, 3, if (kind == 3) th.close_hot else th.btn_hover);
    if (ui.inside(r)) {
        if (ops.byId(tip_op)) |oi| ui.tip(wid, r, cat.entries[oi].label, cat.entries[oi].doc, null);
    }
    ui.record("icon", tip_op, r, true);
    const col = if (hv and kind == 3) 0xffffff else th.text_dim;
    const ic: gfx.Icon = switch (kind) {
        0 => .maximize,
        1 => .split_h,
        2 => .split_v,
        3 => .close,
        else => .dock,
    };
    ui.cv.icon(r.x + @divTrunc(r.w - 16, 2), r.y + @divTrunc(r.h - 16, 2), ic, col);
    return ui.press(wid, r, ui.LMB);
}

// --- header drag: dock beside another area, or swap with it ----------------------

const HeaderDrag = struct { node: i16 };
var hdrag: ?HeaderDrag = null;

const DropTarget = struct { node: i16, side: Side, rect: Rect };

/// Where an area dragged by its header would go: the outer 30% of another
/// area puts it on that side, the middle swaps the two.
fn dropTarget(self: i16) ?DropTarget {
    const t = leafAt(if (ws().maximized >= 0) ws().maximized else ws().root, ui.mx, ui.my) orelse return null;
    if (t == self) return null;
    const r = N(t).rect;
    const lx = ui.mx - r.x;
    const ly = ui.my - r.y;
    const fx = @as(f32, @floatFromInt(lx)) / @as(f32, @floatFromInt(@max(1, r.w)));
    const fy = @as(f32, @floatFromInt(ly)) / @as(f32, @floatFromInt(@max(1, r.h)));
    // the nearest edge within 30% wins
    var side: Side = .center;
    var best: f32 = 0.3;
    if (fx < best) {
        side = .left;
        best = fx;
    }
    if (1 - fx < best) {
        side = .right;
        best = 1 - fx;
    }
    if (fy < best) {
        side = .top;
        best = fy;
    }
    if (1 - fy < best) side = .bottom;
    return .{ .node = t, .side = side, .rect = sideRect(r, side) };
}

fn sideRect(r: Rect, side: Side) Rect {
    const hw = @divTrunc(r.w * 35, 100);
    const hh = @divTrunc(r.h * 35, 100);
    return switch (side) {
        .left => .{ .x = r.x, .y = r.y, .w = hw, .h = r.h },
        .right => .{ .x = r.right() - hw, .y = r.y, .w = hw, .h = r.h },
        .top => .{ .x = r.x, .y = r.y, .w = r.w, .h = hh },
        .bottom => .{ .x = r.x, .y = r.bottom() - hh, .w = r.w, .h = hh },
        .center => r.inset(6),
    };
}

fn sideLabel(side: Side) []const u8 {
    return switch (side) {
        .left => "Dock on the left",
        .right => "Dock on the right",
        .top => "Dock above",
        .bottom => "Dock below",
        .center => "Swap the two",
    };
}

/// While a header is dragged: the tint where it would go, and a label.
fn drawHeaderDrag() void {
    const d = hdrag orelse return;
    const hid = headerId(d.node);
    if (!ui.isActive(hid)) {
        hdrag = null;
        return;
    }
    if (!ui.moved) return;
    const th = ui.th;
    const cv = ui.cv;
    ui.cursor = .grabbing;
    const t = dropTarget(d.node);
    if (t) |tg| {
        cv.blend(tg.rect, th.accent, 80);
        cv.rectLine(tg.rect, th.accent);
    }
    const lbl = if (t) |tg| sideLabel(tg.side) else "Drop on another area";
    const lw = gfx.textWidth(lbl) + 16;
    const lr = Rect{ .x = ui.mx + 14, .y = ui.my + 16, .w = lw, .h = 22 };
    cv.fillRound(lr, 4, th.drop_bg);
    cv.rectLine(lr, th.drop_border);
    cv.textCentered(lr, lbl, th.text);
    if (ui.hit and ui.released & ui.LMB != 0) {
        hdrag = null;
        if (t) |tg| {
            moveArea(d.node, tg.node, tg.side);
            toast(.ok, "{s}: {s}", .{ N(d.node).editor.label(), sideLabel(tg.side) });
            abort_frame = true;
        }
    }
}

fn headerId(i: i16) u32 {
    return ui.id(@src(), @intCast(i));
}

// --- join: drag an area's top-left corner into its neighbour ----------------

var join_from: i16 = -1;

fn joinTarget(i: i16) ?i16 {
    const t = leafAt(if (ws().maximized >= 0) ws().maximized else ws().root, ui.mx, ui.my) orelse return null;
    if (t == i) return null;
    return t;
}

/// Leaf i takes leaf t's place when the two are the halves of one split.
fn canJoin(i: i16, t: i16) bool {
    const p = N(i).parent;
    return p >= 0 and p == N(t).parent and N(t).leaf;
}

fn join(i: i16, t: i16) void {
    const p = N(i).parent;
    const keep = N(i).*;
    N(t).used = false;
    N(i).used = false;
    const gp = N(p).parent;
    N(p).* = keep;
    N(p).parent = gp;
    ws().maximized = -1;
    active_area = p;
    abort_frame = true;
}

fn drawJoin(i: i16, r: Rect) void {
    const corner = Rect{ .x = r.x, .y = r.y, .w = 7, .h = 7 };
    const cid = ui.id(@src(), @intCast(i));
    const th = ui.th;
    const cv = ui.cv;
    if (ui.hover(cid, corner)) {
        ui.cursor = .crosshair;
        ui.tip(cid, corner, "Join Areas", "Drag this corner into the area beside it: this area takes its place", null);
    }
    cv.fill(.{ .x = r.x, .y = r.y, .w = 5, .h = 1 }, th.text_off);
    cv.fill(.{ .x = r.x, .y = r.y, .w = 1, .h = 5 }, th.text_off);
    if (ui.pressDrag(cid, corner, ui.LMB)) join_from = i;
    if (!ui.isActive(cid) or join_from != i or !ui.moved) return;
    ui.cursor = .crosshair;
    const t = joinTarget(i) orelse return;
    const ok = canJoin(i, t);
    const tr = N(t).rect;
    // drawn over everything: remember for the end of the tree walk
    join_preview = .{ .rect = tr, .ok = ok };
    if (ui.hit and ui.released & ui.LMB != 0) {
        join_from = -1;
        if (ok) {
            join(i, t);
            toast(.ok, "Joined the areas", .{});
        } else toast(.warn, "Join: only two halves of one split can be joined", .{});
    }
}

var join_preview: ?struct { rect: Rect, ok: bool } = null;

/// One area: header (editor menu, buttons) and the editor body.
fn drawArea(i: i16, r: Rect, floating: bool) void {
    const th = ui.th;
    const cv = ui.cv;
    const n = N(i);
    if (r.w < 20 or r.h < 20) return;
    if (ui.inside(r)) hover_area = i;
    const old = cv.setClip(r);
    defer cv.clip = old;

    const hdr = Rect{ .x = r.x, .y = r.y, .w = r.w, .h = HDR_H };
    cv.fill(hdr, th.pane_hdr);
    const salt: usize = @intCast(i);
    // the join corner takes its press before the header does
    if (!floating) drawJoin(i, r);

    // editor type menu
    const lbl = if (n.editor == .other) wsfile.otherLabel(n.raw_ed) else n.editor.label();
    const er = Rect{ .x = r.x + 4, .y = r.y + 2, .w = gfx.textWidth(lbl) + 24, .h = HDR_H - 4 };
    const eid = ui.id(@src(), salt);
    ui.record("editor", lbl, er, true);
    if (ui.hover(eid, er)) {
        cv.fillRound(er, 3, th.btn_hover);
        ui.tip(eid, er, "Editor Type", "What this area shows: click to pick another editor", null);
    }
    cv.textIn(er, 6, lbl, th.text_dim);
    cv.chevronDown(er.right() - 10, er.y + @divTrunc(er.h, 2), th.text_dim);
    // the active area: an accent stripe at the header's left edge
    if (i == active_area) cv.fill(.{ .x = r.x, .y = r.y, .w = 3, .h = HDR_H }, th.accent);
    if (ui.press(eid, er, ui.LMB)) {
        ui.active = 0;
        menus.openAt(&cat.items_area, r.x, r.y + HDR_H, i); // (under the header, at the area's left: MENU_AREA)
    }

    // header buttons (right side), dropped when the area is too narrow
    const room = r.right() - er.right();
    var bx = r.right() - 24;
    const by = r.y + 2;
    const bsz = HDR_H - 4;
    if (room > 30 and iconButton(ui.id(@src(), salt), .{ .x = bx, .y = by, .w = 20, .h = bsz }, 3, "area.close")) {
        ui.active = 0;
        closeArea(i);
        abort_frame = true;
        return;
    }
    bx -= 22;
    if (floating) {
        if (iconButton(ui.id(@src(), salt), .{ .x = bx, .y = by, .w = 20, .h = bsz }, 4, "area.dock")) {
            ui.active = 0;
            active_area = i;
            dockActive();
            return;
        }
    } else if (room < 110) {
        bx += 22; // only the close button fits
    } else {
        if (iconButton(ui.id(@src(), salt), .{ .x = bx, .y = by, .w = 20, .h = bsz }, 2, "area.split_stack")) {
            ui.active = 0;
            splitArea(i, false);
            return;
        }
        bx -= 22;
        if (iconButton(ui.id(@src(), salt), .{ .x = bx, .y = by, .w = 20, .h = bsz }, 1, "area.split_side")) {
            ui.active = 0;
            splitArea(i, true);
            return;
        }
        bx -= 22;
        if (iconButton(ui.id(@src(), salt), .{ .x = bx, .y = by, .w = 20, .h = bsz }, 0, "area.maximize")) {
            ui.active = 0;
            ws().maximized = if (ws().maximized == i) -1 else i;
            abort_frame = true;
            return;
        }
    }

    // editor-specific header widgets
    const hx = er.right() + 8;
    editors.header(i, .{ .x = hx, .y = r.y, .w = bx - hx, .h = HDR_H });
    if (abort_frame) return;

    // right-click on the header: the area menu
    if (ui.hit and ui.pressed & ui.RMB != 0 and ui.inside(hdr) and ui.active == 0) {
        active_area = i;
        menus.openAt(&cat.ctx_header, ui.mx, ui.my, i);
    }

    // header drag: dock elsewhere (tree), or move the panel (floating)
    const hid = if (floating) floatDragId(i) else headerId(i);
    if (ui.pressDrag(hid, hdr, ui.LMB)) {
        if (!floating) hdrag = .{ .node = i } else if (pw.moveWindow(i)) ui.active = 0;
    }
    if (ui.isActive(hid) and ui.moved) ui.cursor = .grabbing;
    if (floating and ui.hit and ui.isActive(hid)) {
        if (floatIndex(i)) |fx| {
            ws().floats[fx].rect.x += ui.dx;
            ws().floats[fx].rect.y += ui.dy;
        }
    }

    const body = Rect{ .x = r.x, .y = r.y + HDR_H, .w = r.w, .h = r.h - HDR_H };
    _ = cv.setClip(body.intersect(old));
    editors.body(i, body);
}

fn floatDragId(i: i16) u32 {
    return ui.id(@src(), @intCast(i));
}

const Guide = struct { side: Side, rect: Rect };

/// The five dock guides in the middle of area r.
fn guides(r: Rect) [5]Guide {
    const cx = r.x + @divTrunc(r.w, 2);
    const cy = r.y + @divTrunc(r.h, 2);
    const s = 28;
    const o = 34;
    return .{
        .{ .side = .center, .rect = .{ .x = cx - s / 2, .y = cy - s / 2, .w = s, .h = s } },
        .{ .side = .left, .rect = .{ .x = cx - s / 2 - o, .y = cy - s / 2, .w = s, .h = s } },
        .{ .side = .right, .rect = .{ .x = cx - s / 2 + o, .y = cy - s / 2, .w = s, .h = s } },
        .{ .side = .top, .rect = .{ .x = cx - s / 2, .y = cy - s / 2 - o, .w = s, .h = s } },
        .{ .side = .bottom, .rect = .{ .x = cx - s / 2, .y = cy - s / 2 + o, .w = s, .h = s } },
    };
}

fn drawFloat(fi: usize) void {
    const th = ui.th;
    const cv = ui.cv;
    // keep the header reachable
    const fr = &ws().floats[fi].rect;
    fr.x = std.math.clamp(fr.x, 60 - fr.w, @max(0, win_w - 60));
    fr.y = std.math.clamp(fr.y, TITLE_H + MENU_H, @max(TITLE_H + MENU_H, win_h - STATUS_H - HDR_H));
    const f = ws().floats[fi];
    const r = f.rect;
    const dragging = ui.isActive(floatDragId(f.node)) and ui.moved;

    // dock guides in the area under the pointer
    var target: ?DropTarget = null;
    if (dragging) {
        if (leafAt(if (ws().maximized >= 0) ws().maximized else ws().root, ui.mx, ui.my)) |t| {
            const tr = N(t).rect;
            for (guides(tr)) |g| {
                const over = g.rect.contains(ui.mx, ui.my);
                if (over) target = .{ .node = t, .side = g.side, .rect = sideRect(tr, g.side) };
            }
            if (target) |tg| {
                cv.blend(tg.rect, th.accent, 80);
                cv.rectLine(tg.rect, th.accent);
            }
            for (guides(tr)) |g| {
                const over = g.rect.contains(ui.mx, ui.my);
                cv.fillRound(g.rect, 4, if (over) th.accent else th.drop_bg);
                cv.rectLine(g.rect, th.drop_border);
                const ic = g.rect.inset(7);
                const col = if (over) th.accent_text else th.text;
                switch (g.side) {
                    .center => cv.rectLine(ic, col),
                    .left => cv.fill(.{ .x = ic.x, .y = ic.y, .w = 5, .h = ic.h }, col),
                    .right => cv.fill(.{ .x = ic.right() - 5, .y = ic.y, .w = 5, .h = ic.h }, col),
                    .top => cv.fill(.{ .x = ic.x, .y = ic.y, .w = ic.w, .h = 5 }, col),
                    .bottom => cv.fill(.{ .x = ic.x, .y = ic.bottom() - 5, .w = ic.w, .h = 5 }, col),
                }
            }
        }
    }

    // shadow + frame
    cv.blend(.{ .x = r.x + 4, .y = r.y + 6, .w = r.w, .h = r.h }, th.shadow, 120);
    cv.fill(r, th.pane_bg);
    drawArea(f.node, r, true);
    if (abort_frame) return;
    cv.rectLine(r, if (dragging) th.accent else th.drop_border);

    // the left, right and bottom edges resize it
    const edges = [_]struct { r: Rect, k: u8 }{
        .{ .r = .{ .x = r.x - 2, .y = r.y + HDR_H, .w = 5, .h = r.h - HDR_H - 14 }, .k = 0 },
        .{ .r = .{ .x = r.right() - 3, .y = r.y + HDR_H, .w = 5, .h = r.h - HDR_H - 14 }, .k = 1 },
        .{ .r = .{ .x = r.x + 4, .y = r.bottom() - 3, .w = r.w - 18, .h = 5 }, .k = 2 },
    };
    for (edges) |e| {
        const eid = ui.id(@src(), @as(usize, @intCast(f.node)) * 4 + e.k);
        if (ui.hover(eid, e.r) or ui.isActive(eid)) ui.cursor = if (e.k == 2) .ns_resize else .ew_resize;
        _ = ui.pressDrag(eid, e.r, ui.LMB);
        if (ui.hit and ui.isActive(eid)) {
            const fr2 = &ws().floats[fi].rect;
            switch (e.k) {
                0 => {
                    const right = fr2.right();
                    fr2.x = @min(ui.mx, right - 220);
                    fr2.w = right - fr2.x;
                },
                1 => fr2.w = @max(220, ui.mx - fr2.x + 1),
                else => fr2.h = @max(140, ui.my - fr2.y + 1),
            }
        }
    }

    // resize grip
    const grip = Rect{ .x = r.right() - 14, .y = r.bottom() - 14, .w = 14, .h = 14 };
    const gid = ui.id(@src(), @intCast(f.node));
    var k: i32 = 0;
    while (k < 3) : (k += 1) cv.line(grip.x + 4 + k * 3, grip.bottom() - 2, grip.right() - 2, grip.y + 4 + k * 3, th.text_dim);
    if (ui.hover(gid, grip)) ui.cursor = .nwse_resize;
    _ = ui.pressDrag(gid, grip, ui.LMB);
    if (ui.hit and ui.isActive(gid)) {
        ws().floats[fi].rect.w = @max(220, ui.mx - r.x + 7);
        ws().floats[fi].rect.h = @max(140, ui.my - r.y + 7);
    }

    if (ui.hit and ui.pressed != 0 and ui.layer == ui.hot_layer and r.contains(ui.mx, ui.my)) raise_float = fi;

    if (ui.hit and dragging and ui.released & ui.LMB != 0) {
        // dragged out of the window: a window of its own
        if (pw.supported() and (ui.mx < 0 or ui.my < 0 or ui.mx >= win_w or ui.my >= win_h)) {
            openWindow(f.node);
            abort_frame = true;
            return;
        }
        if (target) |t| {
            if (t.side == .center) {
                swapLeaves(f.node, t.node);
                toast(.ok, "Swapped {s} and {s}", .{ N(t.node).editor.label(), N(f.node).editor.label() });
            } else {
                removeFloat(fi);
                dock(f.node, t.node, t.side);
                toast(.ok, "Docked {s}", .{N(f.node).editor.label()});
            }
            abort_frame = true;
        }
    }
}

// --- title bar, menu bar, status bar --------------------------------------------

var last_title_click: i64 = 0;

fn drawLogo(x: i32, y: i32) void {
    const cv = ui.cv;
    const a = ui.th.accent;
    // a little honeycomb cell with a bee stripe
    cv.fillCircle(x + 8, y + 8, 8, a);
    cv.fill(.{ .x = x + 2, .y = y + 6, .w = 13, .h = 2 }, 0x1b1d22);
    cv.fill(.{ .x = x + 2, .y = y + 10, .w = 13, .h = 2 }, 0x1b1d22);
}

fn drawTitle() void {
    const th = ui.th;
    const cv = ui.cv;
    const r = Rect{ .w = win_w, .h = TITLE_H };
    cv.fill(r, th.title_bg);
    drawLogo(10, 8);
    const x = cv.text(34, 8, "BeeModel", th.accent);
    var tb: [300]u8 = undefined;
    const tx = 34 + x + cv.text(34 + x, 8, std.fmt.bufPrint(&tb, "  -  {s}", .{files.name()}) catch "", th.title_text);
    // unsaved changes: an accent dot, as the original
    if (files.changed()) cv.fillCircle(tx + 10, 16, 4, th.accent);
    _ = cv.text(tx + (if (files.changed()) @as(i32, 22) else 8), 8, "(Zig)", th.text_dim);

    const maxed = if (win) |wn| wn.maximized else false;
    var bx = win_w - 46;
    const bw = 46;
    // close, maximize, minimize
    inline for (.{ 3, 0, 5 }) |kind| {
        const br = Rect{ .x = bx, .y = 0, .w = bw, .h = TITLE_H };
        const bid = ui.id(@src(), kind);
        const hv = ui.hover(bid, br);
        ui.record("window", switch (kind) {
            3 => "Close",
            0 => "Maximize",
            else => "Minimize",
        }, br, true);
        if (hv) cv.fill(br, if (kind == 3) th.close_hot else th.hover);
        const col: u32 = if (hv and kind == 3) 0xffffff else th.title_text;
        const cx = br.x + 23;
        const cy = 16;
        switch (kind) {
            3 => {
                cv.line(cx - 5, cy - 5, cx + 5, cy + 5, col);
                cv.line(cx - 5, cy + 5, cx + 5, cy - 5, col);
            },
            0 => if (maxed) {
                cv.rectLine(.{ .x = cx - 3, .y = cy - 6, .w = 9, .h = 9 }, col);
                cv.fill(.{ .x = cx - 6, .y = cy - 3, .w = 9, .h = 9 }, if (hv) th.hover else th.title_bg);
                cv.rectLine(.{ .x = cx - 6, .y = cy - 3, .w = 9, .h = 9 }, col);
            } else cv.rectLine(.{ .x = cx - 5, .y = cy - 5, .w = 11, .h = 11 }, col),
            else => cv.fill(.{ .x = cx - 5, .y = cy, .w = 11, .h = 1 }, col),
        }
        if (ui.press(bid, br, ui.LMB)) {
            ui.active = 0;
            switch (kind) {
                3 => files.guarded(.exit, ""),
                0 => if (win) |wn| wn.setMaximized(!wn.maximized),
                else => if (win) |wn| wn.minimize(),
            }
        }
        bx -= bw;
    }

    // drag to move, double-click to maximize
    const drag = Rect{ .w = bx + bw, .h = TITLE_H };
    const did = ui.id(@src(), 0);
    if (ui.press(did, drag, ui.LMB)) {
        ui.active = 0;
        if (now_ms - last_title_click < 400) {
            if (win) |wn| wn.setMaximized(!wn.maximized);
        } else if (win) |wn| wn.move();
        last_title_click = now_ms;
    }
}

fn windowEdges() void {
    const wn = win orelse return;
    if (wn.maximized or wn.tiled) return;
    if (ui.hot_layer != ui.L_BASE or ui.active != 0) return;
    const e = 5;
    var edges: u32 = 0;
    if (ui.mx < e) edges |= wl.Edge.left;
    if (ui.mx >= win_w - e) edges |= wl.Edge.right;
    if (ui.my < e) edges |= wl.Edge.top;
    if (ui.my >= win_h - e) edges |= wl.Edge.bottom;
    if (edges == 0) return;
    ui.cursor = switch (edges) {
        wl.Edge.left, wl.Edge.right => .ew_resize,
        wl.Edge.top, wl.Edge.bottom => .ns_resize,
        wl.Edge.top | wl.Edge.left, wl.Edge.bottom | wl.Edge.right => .nwse_resize,
        else => .nesw_resize,
    };
    if (ui.hit and ui.pressed & ui.LMB != 0) wn.resize(edges);
}

var last_tab_click: i64 = 0;

fn drawMenuBar() void {
    const th = ui.th;
    const cv = ui.cv;
    const r = Rect{ .y = TITLE_H, .w = win_w, .h = MENU_H };
    cv.fill(r, th.menu_bg);
    var x: i32 = 4;
    for (menus.titles, 0..) |title, i| {
        // (as draw_menubar: the bar's height takes the pointer; the open
        // title on the menu's colour, a hovered one lit)
        const mr = Rect{ .x = x, .y = r.y, .w = menus.textW(title) + 20, .h = MENU_H };
        menus.bar_rects[i] = mr;
        ui.record("menu", title, mr, true);
        const open = if (menus.cur) |mn| mn.bar != null and mn.bar.? == i else false;
        const mid = ui.id(@src(), i);
        if (open) {
            cv.fill(.{ .x = mr.x, .y = r.y + 2, .w = mr.w, .h = MENU_H - 2 }, th.drop_bg);
        } else if (ui.hover(mid, mr)) cv.fill(.{ .x = mr.x, .y = r.y + 2, .w = mr.w, .h = MENU_H - 4 }, th.hover);
        _ = cv.text(mr.x + 10, r.y + 4, title, if (open) th.accent_fg else th.text);
        if (ui.press(mid, mr, ui.LMB)) {
            ui.active = 0;
            menus.openBar(i, false);
        }
        x = mr.right();
    }
    // workspace tabs (only the current one when they do not all fit)
    x += 18;
    var need: i32 = 0;
    for (workspaces[0..n_ws]) |*w| need += gfx.textWidth(w.name()) + 20;
    const all_fit = x + need + 30 < win_w;
    var i: usize = 0;
    while (i < n_ws) : (i += 1) {
        if (!all_fit and i != cur_ws) continue;
        const w = &workspaces[i];
        const tr = Rect{ .x = x, .y = r.y + 2, .w = @max(gfx.textWidth(w.name()) + 18, if (renaming_ws == i) @as(i32, 120) else 0), .h = MENU_H - 4 };
        if (tr.right() > win_w - 40) break;
        if (renaming_ws == i) {
            if (ui.textField(RENAME_ID, tr, w.name(), "Name")) |nm| {
                const t = std.mem.trim(u8, nm, " ");
                if (t.len > 0) w.setName(t);
                renaming_ws = null;
                wsfile.persist();
            } else if (ui.edit_id != RENAME_ID) renaming_ws = null;
        } else {
            const tid = ui.id(@src(), i);
            if (ui.inside(tr)) ui.tip(tid, tr, w.name(), "A workspace: a saved layout of areas. Double-click renames it; Ctrl+PageUp / PageDown switch", null);
            if (ui.button(tid, tr, w.name(), .{ .selected = i == cur_ws, .flat = true, .radius = 3, .soft = true })) {
                ui.active = 0;
                if (i == cur_ws and now_ms - last_tab_click < 400) {
                    workspaceRename();
                } else switchWorkspace(i);
                last_tab_click = now_ms;
            }
        }
        x = tr.right() + 2;
    }
    // + : a new workspace (a copy of this one)
    const pr = Rect{ .x = x + 2, .y = r.y + 3, .w = 22, .h = MENU_H - 6 };
    const pid = ui.id(@src(), 0);
    if (ui.inside(pr)) ui.tip(pid, pr, "New Workspace", "A new workspace: a copy of this one's layout", null);
    if (ui.button(pid, pr, "+", .{ .flat = true, .radius = 3 })) {
        ui.active = 0;
        workspaceNew();
    }
    // (draw_menubar: a line under the bar)
    cv.fill(.{ .x = 0, .y = r.y + MENU_H - 1, .w = win_w, .h = 1 }, th.split);
}

// --- status bar -----------------------------------------------------------

/// Frames drawn in the last second (while something moves).
var frame_times: [128]i64 = @splat(0);
var frame_head: usize = 0;

pub fn frameDrawn() void {
    frame_times[frame_head % frame_times.len] = now_ms;
    frame_head += 1;
}

fn fps() ?usize {
    var n: usize = 0;
    for (frame_times) |t| {
        if (t != 0 and now_ms - t < 1000) n += 1;
    }
    return if (n <= 1) null else n;
}

/// A chip at the right of the status bar (the AI at work, the agents'
/// permission, Image to 3D, co-editing, the live link): what it says, its
/// record's label, its tooltip and what a click on it does.
pub const Chip = struct {
    text: []const u8,
    label: []const u8,
    title: []const u8 = "",
    tip: []const u8 = "",
    action: ?*const fn () void = null,
};

// What the status bar's left shows: notes (what a modal tool does) and key
// hints, in order.
const Left = struct { keys: []const u8, what: []const u8, col: u32 = 0 };
var status_left: [12]Left = undefined;
var left_n: usize = 0;

fn hint(k: []const u8, what: []const u8) void {
    if (left_n == status_left.len) return;
    status_left[left_n] = .{ .keys = k, .what = what };
    left_n += 1;
}

fn note(s: []const u8, col: u32) void {
    if (left_n == status_left.len) return;
    status_left[left_n] = .{ .keys = "", .what = s, .col = col };
    left_n += 1;
}

/// A rounded chip at the right of the status bar, its right edge at
/// `right`: where the next one's right edge goes.
fn statusPill(z: *zui.Ui, c: Chip, right: f32, y: f32) f32 {
    const th = ui.th;
    const h: f32 = STATUS_H - 6;
    const w = z.textSize(c.text).x + 16;
    const r: zui.Rect = .{ .x = right - w, .y = y + 3, .w = w, .h = h };
    const it = z.interact(z.id(c.label), r);
    z.drawRect(.{ .rect = r, .fill = host.col(if (it.hovered and c.action != null) th.btn_hover else th.menu_bg), .radius = h / 2 });
    z.drawText(.{ .x = r.x + 8, .y = r.y + (h - z.textSize("").y) / 2 }, host.col(th.text_dim), c.text);
    if (c.title.len > 0) z.tooltipRich(it, .{ .title = c.title, .body = c.tip, .placement = .pointer });
    ui.record("chip", c.label, host.rectOf(r), true);
    if (it.clicked) if (c.action) |f| f();
    return r.x - 6;
}

fn drawStatus() void {
    const th = ui.th;
    const r = Rect{ .y = win_h - STATUS_H, .w = win_w, .h = STATUS_H };
    var buf: [128]u8 = undefined;
    var fb: [24]u8 = undefined;
    const fv = fps();
    if (ui.cv.enabled) fps_shown = fv != null;
    const f: []const u8 = if (!prefs.show_frame_rate) "" else if (fv) |v| (std.fmt.bufPrint(&fb, "{d} fps", .{v}) catch "") else "idle";
    const s = std.fmt.bufPrint(&buf, "{s}   |   {d} objects  {d} selected  {d} faces   |   {d}/{d} ops", .{
        f, scene.count, scene.nSelected(), scene.faceCount(), ops.implementedCount(), ops.N,
    }) catch "";
    // what the left says, as the original: the mode's keys
    left_n = 0;
    if (@import("bscript.zig").macro_on) note("Recording macro", 0xe5484d); // (said first, status.s)
    if (@import("meshops.zig").modal != null) {
        var b: [96]u8 = undefined;
        note(@import("meshops.zig").describe(&b), th.accent_fg);
        hint("Enter", "confirm");
        hint("Esc", "cancel");
        hint("0-9", "type a value");
    } else if (xform.active) {
        var b: [96]u8 = undefined;
        const d = xform.describe(&b);
        note(d, th.accent);
        hint("Enter", "confirm");
        hint("Esc", "cancel");
        hint("X Y Z", "axis");
        hint("Ctrl", "snap");
        hint("Shift", "fine");
        hint("0-9", "type a value");
    } else if (@import("play.zig").on != 0) {
        hint("WASD", "walk");
        hint("Space", "jump");
        hint("F", "fly");
        hint("Esc", "stop");
    } else if (menus.palette) {
        hint("Up/Down", "pick");
        hint("Enter", "run");
        hint("Esc", "close");
    } else if (menus.isOpen()) {
        hint("Up/Down", "move");
        hint("Left/Right", "menus");
        hint("Enter", "run");
        hint("Esc", "close");
    } else if (@import("sketchui.zig").on()) {
        hint("L O R", "line / circle / rect");
        hint("D", "dimension");
        hint("X", "delete");
        hint("Tab", "leave");
    } else if (@import("paint.zig").on) {
        hint("LMB", "paint");
        hint("[ ]", "radius");
        hint("Shift+[ ]", "strength");
        hint("Shift+Tab", "leave");
    } else if (@import("sculpt.zig").on) {
        hint("LMB", "stroke");
        hint("Ctrl", "invert");
        hint("Shift", "smooth");
        hint("[ ]", "radius");
        hint("Shift+[ ]", "strength");
        hint("Ctrl+Tab", "leave");
    } else if (hover_area >= 0 and N(hover_area).editor == .viewport and @import("editmesh.zig").active) {
        // as the original
        hint("LMB", "select");
        hint("B", "box");
        hint("Alt+LMB", "loop");
        hint("E", "extrude");
        hint("RMB", "menu");
        hint("Tab", "object mode");
    } else if (hover_area >= 0 and N(hover_area).editor == .viewport) {
        hint("LMB", "select");
        hint("Shift+LMB", "add");
        hint("Drag", "orbit");
        hint("MMB", "pan");
        hint("G R S", "move turn scale");
        hint("Shift+A", "add");
        hint("F3", "search");
    } else if (hover_area >= 0 and N(hover_area).editor == .outliner) {
        hint("LMB", "select");
        hint("Ctrl+LMB", "toggle");
        hint("Shift+LMB", "range");
        hint("F2", "rename");
    } else {
        hint("F3", "search every command");
        hint("F1", "shortcuts");
        hint("Ctrl+Z", "undo");
        hint("F6", "next area");
    }
    const z = host.beginPart("status", 0, r) orelse return;
    defer host.endPart(z);
    z.drawRect(.{ .rect = host.zr(r), .fill = host.col(th.status_bg) });
    z.pushMetric(.item_spacing, .{ .x = 6, .y = 0 });
    defer z.popStyle();
    // the right side first, right to left as status.s: its width says how
    // much the left may take
    var cb: [5][160]u8 = undefined;
    var chips: [5]Chip = undefined;
    var nc: usize = 0;
    const found = [5]?Chip{
        @import("ai.zig").statusChip(&cb[0]),
        @import("agent.zig").statusChip(&cb[1]),
        @import("hi3d.zig").chip(&cb[2]),
        @import("cosync.zig").statusChip(),
        @import("link.zig").chip(),
    };
    for (found) |c| if (c) |x| {
        chips[nc] = x;
        nc += 1;
    };
    var jb: [128]u8 = undefined;
    const job = @import("jobui.zig").progress();
    const job_text = if (job) |p| @import("jobui.zig").text(&jb, p) else "";
    // The right side at its places from the right edge (its text changes
    // each frame while the frame rate shows: no layout to settle again).
    const ry: f32 = @floatFromInt(r.y);
    var right: f32 = @as(f32, @floatFromInt(r.w)) - 10;
    {
        var k = nc;
        while (k > 0) {
            k -= 1;
            right = statusPill(z, chips[k], right, ry);
        }
    }
    const sw = z.textSize(s).x;
    const sx = right - 4 - sw;
    z.drawText(.{ .x = sx, .y = ry + (@as(f32, STATUS_H) - z.textSize("").y) / 2 }, host.col(th.text_dim), s);
    ui.record("status", s, r, true);
    const left_end = sx - 16;
    // the left: notes and key hints while they fit (none cut in half); the
    // job's chip after them
    z.beginHorizontal(.{ .width = .fill, .height = .px(STATUS_H), .alignment = .center });
    defer z.endHorizontal();
    z.spacer(.px(4));
    const room_left = left_end - 4 - (if (job != null) z.textSize(job_text).x + 16 + 14 else 0);
    var used: f32 = 0;
    for (status_left[0..left_n]) |l| {
        if (l.keys.len == 0) {
            const w = z.textSize(l.what).x + 10;
            if (used + w > room_left) break;
            z.label(l.what, .{ .color = host.col(l.col) });
            if (l.col == 0xe5484d) ui.record("status", l.what, host.rectOf(z.lastRect()), true);
            used += w + 6;
            continue;
        }
        var w: f32 = z.textSize(l.what).x + 6 + 10;
        var it = std.mem.tokenizeScalar(u8, l.keys, ' ');
        while (it.next()) |k| w += z.textSize(k).x + 10 + 3;
        if (used + w > room_left) break;
        z.keyHint(l.keys, l.what);
        used += w + 6;
    }
    if (job) |p| {
        z.spacer(.fill);
        _ = z.jobChip(p.label, if (p.frac >= 0) std.math.clamp(p.frac, 0, 1) else null, @as(f32, @floatFromInt(p.ms)) / 1000, .{});
        ui.record("chip", job_text, host.rectOf(z.lastRect()), true);
        z.spacer(.px(@max(0, @as(f32, @floatFromInt(r.w)) - left_end + 8)));
    }
}

/// Word-wrap `s` into lines of at most `cols` characters.
fn wrap(s: []const u8, cols: usize, out: [][]const u8) usize {
    var n: usize = 0;
    var rest = s;
    while (rest.len > 0 and n < out.len) {
        if (rest.len <= cols) {
            out[n] = rest;
            n += 1;
            break;
        }
        var cut = cols;
        while (cut > cols / 2 and rest[cut] != ' ') cut -= 1;
        if (rest[cut] != ' ') cut = cols;
        out[n] = rest[0..cut];
        n += 1;
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
    return n;
}

fn drawTooltip() void {
    if (!ui.tipVisible() or ui.tip_title_len == 0) return;
    const th = ui.th;
    const cv = ui.cv;
    const title = ui.tip_title[0..ui.tip_title_len];
    const body = ui.tip_body[0..ui.tip_body_len];
    const warn = ui.tip_warn[0..ui.tip_warn_len];
    @import("helped.zig").note(title, body, warn);
    var lines: [10][]const u8 = undefined;
    const nb = wrap(body, 56, &lines);
    var wlines: [3][]const u8 = undefined;
    var wb: [120]u8 = undefined;
    const warn_s = if (warn.len > 0) (std.fmt.bufPrint(&wb, "Not now: {s}", .{warn}) catch warn) else warn;
    const nw = wrap(warn_s, 56, &wlines);
    const of0 = gfx.useFace(.head);
    var w: i32 = gfx.textWidth(title);
    _ = gfx.useFace(of0);
    for (lines[0..nb]) |l| w = @max(w, gfx.textWidth(l));
    for (wlines[0..nw]) |l| w = @max(w, gfx.textWidth(l));
    w += 20;
    const h: i32 = 10 + 18 * @as(i32, @intCast(1 + nb + nw)) + (if (nb + nw > 0) @as(i32, 4) else 0);
    var x = ui.tip_rect.x;
    var y = ui.tip_rect.bottom() + 4;
    if (ui.tip_beside) {
        // beside the menu: right of it, else left of it, at the pointer's height
        x = ui.tip_rect.right() + 6;
        if (x + w > win_w - 4) x = ui.tip_rect.x - w - 6;
        y = ui.my - 10;
        if (y + h > win_h - 4) y = win_h - 4 - h;
    } else if (y + h > win_h - 4) y = ui.tip_rect.y - h - 4;
    if (x + w > win_w - 4) x = win_w - 4 - w;
    x = @max(4, x);
    y = @max(4, y);
    const r = Rect{ .x = x, .y = y, .w = w, .h = h };
    cv.clip = cv.full();
    cv.blend(.{ .x = r.x + 2, .y = r.y + 3, .w = r.w, .h = r.h }, th.shadow, 120);
    cv.fillRound(r, 5, th.drop_bg);
    cv.rectLine(r, th.drop_border);
    var ty = r.y + 6;
    const of = gfx.useFace(.head);
    _ = cv.text(r.x + 10, ty, title, th.text);
    _ = gfx.useFace(of);
    ty += 22;
    for (lines[0..nb]) |l| {
        _ = cv.text(r.x + 10, ty, l, th.text_dim);
        ty += 18;
    }
    for (wlines[0..nw]) |l| {
        _ = cv.text(r.x + 10, ty, l, th.warn);
        ty += 18;
    }
}

// --- input -----------------------------------------------------------------------

var hit_canvas: gfx.Canvas = undefined;
var emulated_down = false;
var last_press_ms: i64 = 0;

pub fn init() void {
    theme.init();
    scene.init();
    @import("arm.zig").init();
    buildLayouts();
    undo.init();
    log("BeeModel Zig - pure Zig, Wayland wire protocol, no libc", .{});
    log("Tip: F3 searches every command; Enter opens the console", .{});
}

/// Run the UI's hit pass for the current input state.
fn hitPass(cv: *gfx.Canvas) void {
    if (pw.curCanvas()) |wc| {
        // the pointer is in a panel's window: that window's widgets
        hit_canvas = wc.*;
        hit_canvas.enabled = false;
        ui.hit = true;
        frameWindow(&hit_canvas, pw.curNode(), pw.cur);
        ui.hit = false;
        return;
    }
    hit_canvas = cv.*;
    hit_canvas.enabled = false;
    ui.hit = true;
    frame(&hit_canvas);
    ui.hit = false;
    cv.clip = cv.full();
}

/// One panel's window: the area over all of it, with what opened in it.
pub fn frameWindow(cv: *gfx.Canvas, node: i16, slot: i32) void {
    if (!areaValid(node)) return;
    const keep_cv = ui.cv;
    const keep_w = win_w;
    const keep_h = win_h;
    const keep_mx = ui.mx;
    const keep_my = ui.my;
    defer {
        ui.cv = keep_cv;
        win_w = keep_w;
        win_h = keep_h;
        ui.mx = keep_mx;
        ui.my = keep_my;
    }
    if (pw.cur != slot) {
        ui.mx = -1000;
        ui.my = -1000;
    }
    ui.cv = cv;
    ui.now_ms = now_ms;
    win_w = cv.full().w;
    win_h = cv.full().h;
    cv.clip = cv.full();
    if (ui.hit) {
        ui.cursor = .default;
        ui.rec_n = 0;
        wg.begin();
    }
    ui.tipBegin();
    const here = menus.isOpen() and menus.owner == slot;
    ui.hot_layer = if (ui.active != 0) ui.active_layer else if (here) ui.L_POPUP else if (dialogs.isOpen() or menus.isOpen()) ui.L_DIALOG else ui.L_BASE;
    ui.layer = ui.L_BASE;
    abort_frame = false;
    hover_area = -1;
    const r = cv.full();
    N(node).rect = r;
    cv.fill(r, ui.th.pane_bg);
    drawArea(node, r, true);
    if (abort_frame) return;
    ui.layer = ui.L_POPUP;
    if (here) menus.draw();
    if (!abort_frame and pw.cur == slot) drawTooltip();
    // its edges: the compositor resizes it
    if (ui.hit and pw.cur == slot and ui.active == 0 and ui.hot_layer == ui.L_BASE) {
        const e = 4;
        var edges: u32 = 0;
        if (ui.mx < e) edges |= wl.Edge.left;
        if (ui.mx >= win_w - e) edges |= wl.Edge.right;
        if (ui.my < e) edges |= wl.Edge.top;
        if (ui.my >= win_h - e) edges |= wl.Edge.bottom;
        if (edges != 0 and ui.pressed & ui.LMB != 0) pw.resizeWindow(node, edges);
    }
    ui.tipEnd();
    if (ui.hit) {
        if (hover_area >= 0 and (ui.dx != 0 or ui.dy != 0 or ui.pressed != 0)) active_area = hover_area;
        if (ui.released != 0 and ui.down == 0) ui.active = 0;
        if (win) |wn| wn.setCursor(ui.cursor);
    }
}

/// An area into a window of its own (a tree's area floats first).
pub fn openWindow(i: i16) void {
    if (i < 0) return;
    if (!isFloating(i)) {
        const r = N(i).rect;
        floatArea(i, r.x + 40, r.y + 40);
        if (!isFloating(i)) return;
    }
    const fx = floatIndex(i) orelse return;
    const fr = ws().floats[fx].rect;
    if (!pw.open(i, fr.w, fr.h, N(i).editor.label())) toast(.warn, "No room for more windows", .{});
    active_area = i;
    dirty = true;
}

/// area.new_window: greyed why not.
pub fn pollWindow() ?[]const u8 {
    if (!pw.supported()) return "panels in windows of their own are not on this system yet";
    const a = activeArea();
    if (a < 0) return "No area";
    if (pw.slotOf(a) >= 0) return "the active area is already in a window of its own";
    if (pw.count() >= pw.MAX) return "No room for more windows";
    if (!isFloating(a)) return canFloat();
    return null;
}

pub fn windowActive() void {
    openWindow(activeArea());
}

/// The user closed a panel's window: its area docks back.
pub fn windowClosed(node: i16) void {
    if (!areaValid(node)) return pw.closeNode(node);
    active_area = node;
    dockActive();
    dirty = true;
}

fn overViewport() bool {
    return hover_area >= 0 and areaValid(hover_area) and N(hover_area).editor == .viewport;
}

fn xformInput(ev: wl.Input) void {
    const node = xform.node;
    if (!areaValid(node)) {
        xform.cancel();
        return;
    }
    const n = N(node);
    switch (ev) {
        .motion => xform.update(&n.view, editors.bodyRect(n.rect), ui.mx, ui.my),
        .button => |b| if (b.pressed) {
            if (b.button == wl.BTN_LEFT) {
                xform.confirm();
                undo.label(xform.modeLabel());
            } else if (b.button == wl.BTN_RIGHT) xform.cancel();
        },
        .mods => xform.update(&n.view, editors.bodyRect(n.rect), ui.mx, ui.my),
        else => {},
    }
}

pub fn onInput(cv: *gfx.Canvas, ev: wl.Input) void {
    dirty = true;
    ui.now_ms = now_ms;
    // (keys after one that needs Zui's frame first wait for it: zuihost.hold)
    if (@import("zuihost.zig").hold(ev)) return;
    // Zui's parts of the UI first (zuihost.zig): what it takes, BeeModel's own UI doesn't see.
    if (@import("zuihost.zig").input(ev)) {
        // (the area under the pointer is the active one, for the commands
        // that act on it, as a hit pass makes it: none runs for a motion
        // Zui took)
        if (ev == .motion) {
            if (leafAt(if (ws().maximized >= 0) ws().maximized else ws().root, ui.mx, ui.my)) |t| {
                hover_area = t;
                active_area = t;
            }
        }
        // (a release Zui took of a press BeeModel had: a menu's title
        // pressed, the entry let go on; BeeModel's button is up too)
        if (ev == .button and !ev.button.pressed) ui.down &= ~@as(u8, switch (ev.button.button) {
            wl.BTN_LEFT => ui.LMB,
            wl.BTN_MIDDLE => ui.MMB,
            wl.BTN_RIGHT => ui.RMB,
            else => 0,
        });
        return;
    }
    switch (ev) {
        .motion => |p| {
            const nx: i32 = @intFromFloat(scale.ptr(p.x));
            const ny: i32 = @intFromFloat(scale.ptr(p.y));
            ui.dx = nx - ui.mx;
            ui.dy = ny - ui.my;
            ui.mx = nx;
            ui.my = ny;
            if (@import("play.zig").motion(nx, ny)) return; // play mode: the mouse looks
            if (ui.active != 0 and !ui.moved and (@abs(nx - ui.press_x) > 3 or @abs(ny - ui.press_y) > 3)) {
                ui.moved = true;
                ui.dx = nx - ui.press_x;
                ui.dy = ny - ui.press_y;
            }
            if (xform.active) {
                xformInput(ev);
            } else if (@import("uved.zig").tm != 0) {
                @import("uved.zig").motion(ui.mx, ui.my);
            } else if (@import("meshops.zig").modal != null) {
                @import("meshops.zig").motion(ui.mx);
            } else hitPass(cv);
            ui.dx = 0;
            ui.dy = 0;
        },
        .leave => {
            if (ui.active == 0) {
                ui.mx = -1000;
                ui.my = -1000;
                ui.tip_id = 0;
            }
        },
        .button => |b0| {
            if (@import("play.zig").on != 0) return; // (play mode: buttons do nothing)
            var b = b0;
            // Preferences > Input: Alt + left button as the middle button
            if (prefs.emulate_middle and b.button == wl.BTN_LEFT and (ui.mods & wl.MOD_ALT != 0 or (!b.pressed and emulated_down))) {
                b.button = wl.BTN_MIDDLE;
                emulated_down = b.pressed;
            }
            const bit: u8 = switch (b.button) {
                wl.BTN_LEFT => ui.LMB,
                wl.BTN_MIDDLE => ui.MMB,
                wl.BTN_RIGHT => ui.RMB,
                else => return,
            };
            const mo = @import("meshops.zig");
            const ue = @import("uved.zig");
            if (ue.tm != 0) {
                // the press that ends a transform does nothing else
                if (b.pressed) {
                    ui.down |= bit;
                    ue.press(b.button);
                    ui.active = 0x7fffffff;
                }
            } else if (mo.modal != null) {
                if (b.pressed) {
                    if (b.button == wl.BTN_RIGHT) mo.cancel() else mo.confirm();
                    ui.active = 0x7fffffff;
                } else if (ui.down == 0) ui.active = 0;
            } else if (xform.active) {
                if (b.pressed) {
                    ui.down |= bit;
                } else ui.down &= ~bit;
                xformInput(ev);
                // the press that ends a transform does nothing else
                if (!xform.active) ui.active = 0x7fffffff;
                if (!b.pressed and ui.down == 0) ui.active = 0;
            } else {
                if (b.pressed) {
                    ui.down |= bit;
                    ui.pressed = bit;
                    wg.kfocus = 0; // (the mouse: the keyboard's ring goes)
                    ui.dbl = now_ms - last_press_ms < 400;
                    last_press_ms = now_ms;
                } else {
                    ui.down &= ~bit;
                    ui.released = bit;
                }
                hitPass(cv);
                if (menus.repass) {
                    // a press that closed a menu, on a widget: it takes it
                    // too (Zui's, if it is one of Zui's parts)
                    if (!@import("zuihost.zig").input(ev)) hitPass(cv);
                    menus.afterRepass();
                }
                ui.pressed = 0;
                ui.released = 0;
                if (ui.down == 0 and ui.active == 0x7fffffff) ui.active = 0;
            }
        },
        .wheel => |v| if (@import("meshops.zig").wheel(v)) {
            dirty = true;
        } else if (@import("uved.zig").tm != 0) {
            @import("uved.zig").wheelInTransform(v);
        } else if (!xform.active) {
            ui.wheel = v;
            hitPass(cv);
            ui.wheel = 0;
        },
        .key => |k| if (@import("play.zig").key(k.key, k.pressed)) {} else if (k.pressed) onKey(cv, k.key) else pies.keyUp(k.key),
        .mods => |md| {
            ui.mods = md;
            if (xform.active) xformInput(ev);
        },
        .close => files.guarded(.exit, ""),
        .resize, .focus => {},
        .pen => |p| {
            const st = @import("stroke.zig");
            st.pressure = p.pressure;
            st.eraser = p.eraser;
            st.pen_seen = true;
            @import("zuihost.zig").pen(p.pressure);
        },
        .pen_end => {
            @import("stroke.zig").mouseInput();
            @import("zuihost.zig").pen(1);
        },
    }
    if (wg.pending()) {
        // a value from a menu or the keyboard: its field takes it now
        hitPass(cv);
        wg.afterPass();
    }
    afterInput();
}

/// The editor under the pointer.
/// One of BeeModel's own modal tools holds the pointer (a transform, the
/// UV editor's G / S / R, a mesh tool): every event is BeeModel's while it
/// runs, over Zui's parts too.
pub fn modalTool() bool {
    return xform.active or @import("uved.zig").tm != 0 or @import("meshops.zig").modal != null or @import("play.zig").on != 0;
}

pub fn hoverEditor() ?Editor {
    return if (hover_area >= 0 and areaValid(hover_area)) N(hover_area).editor else null;
}

/// A hit pass on the current state (the keyboard's navigation).
pub fn hitNow(cv: *gfx.Canvas) void {
    hitPass(cv);
}

/// What Tab walks: the dialog or picker on top, else the area (the pointer's,
/// or the active one once F6 chose it), unless Tab is its own key there.
pub fn focusScope() ?wg.Scope {
    if (filebrowser.open_) return null; // (Zui's, with its own Tab order)
    if (menus.palette or menus.isOpen()) return null;
    if (ui.hot_layer >= ui.L_POPUP) return .{ .layer = ui.hot_layer };
    const a = if (area_ring or hover_area < 0 or !areaValid(hover_area)) activeArea() else hover_area;
    if (a < 0) return null;
    if (N(a).editor == .viewport or N(a).editor == .uved or N(a).editor == .nodes) return null; // (edit mode; Tab: the node editor's)
    return .{ .area = N(a).rect };
}

/// After every event: record an undo step when a change is complete.
pub fn afterInput() void {
    if (xform.active or ui.active != 0 or @import("meshops.zig").modal != null or @import("uved.zig").tm != 0) return;
    if (@import("lsculpt.zig").stroking) return; // (a landscape stroke is one step, at its end)
    undo.sync();
    if (@import("animops.zig").autokeyStep()) undo.sync();
    prefs.flush();
}

/// The character a key types in the layout (for typed transform values):
/// letters are keys (axes), the rest are characters.
fn typedChar(raw: u32) u32 {
    const kb = @import("keyboard.zig");
    if (!kb.loaded and !(raw >= 71 and raw <= 83)) return 0; // US: the codes do it
    const cp = kb.char(raw, ui.mods);
    return if ((cp >= '0' and cp <= '9') or cp == '.' or cp == ',' or cp == '-') cp else 0;
}

fn isModifier(key: u32) bool {
    const K = ui.KEY;
    return switch (key) {
        K.LEFTCTRL, K.RIGHTCTRL, K.LEFTSHIFT, K.RIGHTSHIFT, K.LEFTALT, K.RIGHTALT, 125, 126 => true,
        else => false,
    };
}

fn onKey(cv: *gfx.Canvas, raw_key: u32) void {
    const K = ui.KEY;
    if (isModifier(raw_key)) return;
    // text fields get the key as it is; shortcuts by the letter on the key
    const key = @import("keyboard.zig").shortcutCode(raw_key);
    ui.tip_id = 0;
    if (@import("keys.zig").captured(key)) return; // Preferences > Keymap: Set

    // the measure tool: Esc ends it (etool_key)
    if (@import("measure.zig").on and key == K.ESC) {
        @import("measure.zig").cancel();
        return;
    }
    // the knife: Enter cuts, Backspace takes the last point back, Esc stops
    const kn = @import("meshops2.zig");
    if (kn.kn_active) {
        if (key == K.ESC or !@import("editmesh.zig").active) {
            kn.kn_active = false;
            return;
        }
        if (key == K.BACKSPACE) {
            kn.kn_n -|= 1;
            return;
        }
        if (key == K.ENTER or key == K.KPENTER or key == K.SPACE) {
            kn.kn_active = false;
            const v = viewportArea();
            if (v >= 0) {
                const n = N(v);
                const c = vp.Cam.init(&n.view, editors.bodyRect(n.rect));
                if (kn.knifeCut(&c, kn.kn_pts[0..kn.kn_n]) catch "it failed") |why| toast(.warn, "Knife: {s}", .{why});
            }
            return;
        }
        return;
    }
    // the loop cut tool: Esc stops it
    if (@import("meshops2.zig").lc_active) {
        if (key == K.ESC or !@import("editmesh.zig").active) {
            @import("meshops2.zig").lc_active = false;
            return;
        }
    }
    // a mesh tool taking a value (inset, extrude individual)
    const mo = @import("meshops.zig");
    if (mo.modal != null) {
        switch (key) {
            K.ENTER, K.KPENTER, K.SPACE => mo.confirm(),
            K.ESC => mo.cancel(),
            else => _ = mo.key(@import("keyboard.zig").char(raw_key, ui.mods), raw_key),
        }
        return;
    }
    // 1. a transform takes every key
    if (@import("uved.zig").tm != 0) {
        @import("uved.zig").key(key);
        return;
    }
    if (xform.active) {
        switch (key) {
            K.ENTER, K.KPENTER, K.SPACE => {
                xform.confirm();
                undo.label(xform.modeLabel());
            },
            K.ESC => xform.cancel(),
            else => if (!ui.ctrl() and (xform.typeChar(typedChar(raw_key)) or xform.key(key))) {
                const n = N(xform.node);
                xform.update(&n.view, editors.bodyRect(n.rect), ui.mx, ui.my);
            },
        }
        return;
    }
    // (the node editor's add menu takes every key: Esc closes it)
    if (@import("nodeed.zig").menu) {
        @import("nodeed.zig").key(raw_key);
        return;
    }
    // 2. the pies (the wheel and an open pie are Zui's: they take every key)
    if (@import("kbnav.zig").key(cv, key)) return;
    if (ui.edit_id == 0 and wg.clipKey(key)) return;
    if (!menus.palette and !dialogs.isOpen() and ui.edit_id == 0 and !menus.isOpen()) {
        if (pies.keyDown(key, ui.mods, overViewport())) return;
    }
    // the palette
    if (menus.palette) {
        menus.paletteKey(raw_key);
        return;
    }
    // the prompts ("Save changes?" ...) are Zui's (dialogs.prompt_client); they take every key
    if (@import("autosave.zig").asking or files.asking_lossy or files.asking) return;
    // the file browser (Zui's: it took its keys before this)
    if (filebrowser.open_) return;
    // 3. a dialog (Zui's: it took its keys before this; none reach the app)
    if (dialogs.isOpen() and ui.edit_id == 0) return;
    // 4. a text field (the console's is Zui's: it took its keys before this)
    if (ui.edit_id != 0) {
        _ = ui.editKey(raw_key);
        if (ui.edit_submit) hitPass(cv);
        return;
    }
    // 5. an open menu: its keys (the rest go on, the menu staying open)
    if (menus.isOpen() and menus.key(key)) return;
    // an AI proposal: Enter accepts a finished one, Esc reverts (cp_key)
    if (@import("copilot.zig").key(key)) return;

    const sh = ui.shift();
    const ct = ui.ctrl();
    const alt = ui.mods & wl.MOD_ALT != 0;
    if (key == K.ESC) {
        area_ring = false;
        if (@import("sketchui.zig").escape()) return; // (sketch mode first)
        // a running render stops (its samples kept)
        const rn = @import("render.zig");
        if (rn.active) rn.stopNow();
        return;
    }
    if (key == K.F10 and !sh and !ct and !alt) {
        menus.openBar(0, true);
        return;
    }
    if (alt and !ct and !sh and ops.forKey(key, ui.mods, overViewport()) == null) {
        const ch = ui.keyChar(key, false);
        if (ch != 0 and menus.openByLetter(ch)) return;
    }
    if (key == K.F6 and !ct and !alt) {
        cycleArea(if (sh) -1 else 1);
        return;
    }
    if (key == K.F2 and !sh and !ct and !alt) {
        if (!editors.renameActive()) toast(.warn, "Rename: select an object first", .{});
        return;
    }
    if (key == K.A and sh and !ct and !alt and overViewport()) {
        menus.openAt(&cat.items_add, ui.mx, ui.my, hover_area);
        return;
    }
    // I over a field: a key on that value
    if (key == K.I and ui.mods & (wl.MOD_SHIFT | wl.MOD_CTRL | wl.MOD_ALT) == 0) {
        if (wg.hoveredField()) |e| {
            if (@import("animui.zig").fieldKey(e)) return;
        }
    }
    if (ops.forKey(key, ui.mods, overViewport())) |i| {
        ops.run(i);
        return;
    }
    // a key of a command the port does not have yet: say so
    const md = ui.mods & (wl.MOD_SHIFT | wl.MOD_CTRL | wl.MOD_ALT);
    if (!overViewport()) return; // (those keys are the viewport's)
    for (cat.entries, 0..) |e, i| {
        if (e.code == key and e.mods == md and !e.hidden and !ops.implemented(i)) {
            toast(.warn, "{s}: {s}", .{ e.label, ops.not_ported });
            return;
        }
    }
}

/// Timers: toast expiry, tooltips, playback, the frame rate going idle.
/// Returns ms until the next tick, or -1.
pub fn tick() i32 {
    var next: i32 = -1;
    ui.now_ms = now_ms;
    if (ui.tip_id != 0 and !ui.tipVisible()) {
        const t: i32 = @intCast(@max(1, ui.tip_since + ui.tip_delay - now_ms));
        next = if (next < 0) t else @min(next, t);
        if (now_ms >= ui.tip_since + ui.tip_delay) dirty = true;
    } else if (ui.tip_id != 0 and ui.tipVisible() and !tip_drawn) {
        dirty = true;
    }
    tip_drawn = ui.tipVisible();
    if (@import("anim.zig").tick()) |t| next = if (next < 0) t else @min(next, t);
    if (@import("play.zig").tick()) |t| next = if (next < 0) t else @min(next, t); // play mode: the player, the scene on
    if (@import("hi3d.zig").tick()) |t| next = if (next < 0) t else @min(next, t); // Image to 3D's helper: progress, the mesh
    if (tickGlides()) |t| next = if (next < 0) t else @min(next, t);
    if (pies.tick()) |t| next = if (next < 0) t else @min(next, t);
    // a render: a slice of samples each turn, and a frame to show them
    if (@import("render.zig").tick()) next = 0;
    // the library's thumbnails: a child process each, one at a time (lb_tick);
    // the online sources' downloads (ex_tick): looked at again soon while busy
    @import("libui.zig").tick();
    @import("extlib.zig").tick();
    if (@import("libui.zig").working()) next = if (next < 0) 100 else @min(next, 100);
    // the Rendered viewport's samples, or the time until they begin
    if (@import("live.zig").tick()) |t| next = if (next < 0) t else @min(next, t);
    // a cluster DAG built in the background (the chip moves), pages on their way
    _ = @import("vgeo.zig").tick();
    if (@import("vgeo.zig").building()) {
        dirty = true;
        next = if (next < 0) 100 else @min(next, 100);
    }
    if (@import("vgdraw.zig").poll()) |t| next = if (next < 0) t else @min(next, t);
    // an AI child running: looked at often (main.s); the status chip's time
    if (@import("ai.zig").tickMs()) |t| next = if (next < 0) t else @min(next, t);
    // the frame rate turns to "idle" a second after the last frame
    const last = frame_times[(frame_head + frame_times.len - 1) % frame_times.len];
    if (fps_shown and last != 0 and now_ms - last < 1100) {
        const t: i32 = @intCast(@max(1, last + 1100 - now_ms));
        next = if (next < 0) t else @min(next, t);
        if (now_ms - last >= 1000) dirty = true;
    }
    // a tooltip or caret in Zui's parts of the UI
    if (@import("zuihost.zig").tick(now_ms)) |t| next = if (next < 0) t else @min(next, t);
    return next;
}

var tip_drawn: bool = false;
var fps_shown: bool = false;
