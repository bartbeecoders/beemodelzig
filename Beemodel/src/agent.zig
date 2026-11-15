// Safe agent edits (the original's agent.s): what AI agents may do (permission
// tiers), what they did (the AI Activity editor) and taking it back (one undo
// step per request, reverted with one click).
const std = @import("std");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const undo = @import("undo.zig");
const ops = @import("ops.zig");
const menus = @import("menus.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");
const bkit = @import("bkit.zig");

const Rect = gfx.Rect;
const Impl = ops.Impl;

const ACT_N = 64; // ring of recent tool calls
const COL_REC: u32 = 0xe5484d;
const COL_OK: u32 = 0x4cb86a;
const COL_WARN: u32 = 0xe0a030;

/// 0 read-only, 1 edit, 2 files.
pub var tier: u32 = 1;
/// The preferences (prefs.s pr_tier, pr_mcp): the agents' permission at
/// start (-1: the environment's / edit), and whether the MCP server runs.
pub var pr_tier: i32 = -1;
pub var pr_mcp: i32 = 1;

const tier_names = [3][]const u8{ "read-only", "edit", "files" };
const tier_desc = [3][]const u8{ "Agents may look at the scene", "Agents may look at and edit the scene", "Agents may edit the scene and read / write files" };

/// agent_init: the preference, then BEEMODEL_AGENT_PERMISSION (read / edit /
/// files, by prefix) wins.
pub fn init(env: ?[]const u8) void {
    @import("bscript.zig").agent_gate = scriptGate;
    tier = 1;
    if (pr_tier >= 0 and pr_tier <= 2) tier = @intCast(pr_tier);
    const e = env orelse return;
    if (std.mem.startsWith(u8, e, "read")) {
        tier = 0;
    } else if (std.mem.startsWith(u8, e, "files")) tier = 2;
}

/// An agent's script: an operator past the permission (script.s e_op_perm).
fn scriptGate(i: usize) ?[]const u8 {
    const id = @import("catalog.zig").entries[i].id;
    return if (opTier(id) > tier) "permission denied (the user has not given agents file access): " else null;
}

pub fn tierName(t: u32) []const u8 {
    return tier_names[@min(t, 2)];
}

/// op_tier: files for file.*, screenshots, renders written, library packs and
/// folders, references read and images from / to files; edit for the rest.
pub fn opTier(id: []const u8) u32 {
    const eq = std.mem.eql;
    if (std.mem.startsWith(u8, id, "file.")) return 2;
    for ([_][]const u8{ "view.screenshot", "render.image", "render.save", "lib.pack", "lib.import", "lib.add", "object.add_references" }) |s| {
        if (eq(u8, id, s)) return 2;
    }
    if (eq(u8, id, "image.new")) return 1; // (a new image is no file)
    if (std.mem.startsWith(u8, id, "image.")) return 2;
    return 1;
}

// ---- the operators ------------------------------------------------------------------

fn setTier(t: u32) void {
    tier = t;
    app.log("  {s}", .{tier_desc[t]});
    app.dirty = true;
}
fn tierFn(comptime t: u32) *const fn () void {
    return struct {
        fn f() void {
            setTier(t);
        }
    }.f;
}
fn tierIs(comptime t: u32) *const fn () bool {
    return struct {
        fn f() bool {
            return tier == t;
        }
    }.f;
}

/// revertable: the newest undo step is an agent's.
pub fn revertable() bool {
    if (undo.current() == 0) return false;
    return std.mem.startsWith(u8, undo.nameOf(undo.current()), "Agent:");
}

fn pollRevert() ?[]const u8 {
    return if (revertable()) null else "the last change was not an agent's";
}

/// agent.revert: undo, but only an agent's change.
pub fn revert() void {
    if (!revertable()) return app.log("  nothing to revert: the last change was not made by an agent", .{});
    @import("mcp.zig").stepBack(true);
}

fn opRevert() void {
    revert();
}

fn opTogglePane() void {
    app.toggleActivity();
}
fn hasPane() bool {
    return app.hasEditor(.activity);
}
fn opAreaType() void {
    app.setActiveEditor(.activity);
}
fn isAreaType() bool {
    return app.activeEditor() == .activity;
}

pub const list = .{
    .{ "agent.permission_read", Impl{ .run = tierFn(0), .check = tierIs(0) } },
    .{ "agent.permission_edit", Impl{ .run = tierFn(1), .check = tierIs(1) } },
    .{ "agent.permission_files", Impl{ .run = tierFn(2), .check = tierIs(2) } },
    // (poll_revert greys it in menus and the palette; scripts, the console and
    // agents never ask a poll, so they still get its own "nothing to revert")
    .{ "agent.revert", Impl{ .run = opRevert, .poll = pollRevert } },
    .{ "view.toggle_activity", Impl{ .run = opTogglePane, .check = hasPane } },
    .{ "area.type_activity", Impl{ .run = opAreaType, .check = isAreaType } },
};

// ---- the activity ring ----------------------------------------------------------------

const Act = struct {
    status: u8 = 0, // 0 ok, 1 error, 2 denied
    changed: bool = false,
    tool: [40]u8 = @splat(0),
    tool_len: u8 = 0,
    text: [80]u8 = @splat(0),
    text_len: u8 = 0,
};
var acts: [ACT_N]Act = @splat(.{});
pub var head: u32 = 0;

/// act_record: a tool call (its name, 39 bytes; the first line of its result, 79).
pub fn record(tool: []const u8, status: u8, changed: bool, text: []const u8) void {
    const a = &acts[head % ACT_N];
    a.status = status;
    a.changed = changed;
    const tn = @min(std.mem.indexOfScalar(u8, tool, 0) orelse tool.len, 39);
    @memcpy(a.tool[0..tn], tool[0..tn]);
    a.tool_len = @intCast(tn);
    var ln = std.mem.indexOfAny(u8, text, "\x00\n") orelse text.len;
    ln = @min(ln, 79);
    @memcpy(a.text[0..ln], text[0..ln]);
    a.text_len = @intCast(ln);
    head +%= 1;
    app.dirty = true;
}

// ---- the AI Activity editor -------------------------------------------------------------

/// The picked call (its place in the ring, head - 1 the newest), so the pick
/// stays on it as calls come in.
var pick: ?u32 = null;
var picks: [ACT_N]bool = @splat(false);
var list_state: zui.ListState = .{};

/// ed_activity_draw: the permission, the revert button, the recent calls
/// (newest first; an accent name: the call made an undo step), one Zui part.
pub fn body(i: i16, r: Rect) void {
    const th = ui.th;
    ui.cv.fill(r, th.pane_bg);
    const z = host.beginPart("activity", @intCast(i), .{ .x = r.x + 12, .y = r.y, .w = r.w - 24, .h = r.h }) orelse return;
    defer host.endPart(z);
    z.pushMetric(.item_spacing, .{ .x = 6, .y = 6 });
    defer z.popStyle();
    z.spacer(.px(0)); // (6 down: the spacing)
    // Permission: <tier> | Revert last agent change (red, while there is one)
    z.beginHorizontal(.{ .spacing = 6, .alignment = .center, .height = .px(24) });
    z.label(std.fmt.allocPrint(z.frameAllocator(), "Permission: {s}", .{tierName(tier)}) catch "", .{ .color = host.col(th.accent) });
    if (revertable()) {
        z.spacer(.fill);
        z.pushColor(.button, host.col(COL_REC));
        z.pushColor(.button_hovered, host.col(COL_REC));
        z.pushColor(.button_active, host.col(COL_REC));
        z.pushColor(.text, host.col(0xffffff));
        const label = "Revert last agent change";
        const b = z.button(label, .{ .height = .px(24) });
        z.popStyles(4);
        z.tooltipRich(b, .{ .title = label, .body = "Undo the AI's last request (one step)" });
        if (b.clicked or bkit.ring(b, label)) {
            app.setActiveArea(i);
            revert(); // (agent.revert: quiet)
        }
    }
    z.endHorizontal();
    if (head == 0) {
        bkit.info(z, "No agent activity yet.");
        bkit.info(z, "Connect one with: beemodel --mcp-bridge");
        return;
    }
    // the calls, newest first: a dot (ok, error, denied), the tool, its answer
    const n: usize = @min(head, ACT_N);
    for (0..n) |k| picks[k] = pick != null and pick.? == head - 1 - @as(u32, @intCast(k));
    z.pushMetric(.frame_padding, .{ .x = 8, .y = 0 });
    var l = z.beginList("calls", picks[0..n], &list_state, .{ .height = .fill, .frame = false });
    z.popStyle();
    // (a name in the accent: the call made an undo step; the picked row on
    // the dark accent, as BeeModel's)
    z.pushColor(.accent, host.col(th.accent));
    z.pushColor(.button_active, host.col(th.accent_dark));
    for (l.first..l.end) |k| {
        const a = &acts[(head - @as(u32, @intCast(k)) - 1) % ACT_N];
        const tool = a.tool[0..a.tool_len];
        const answer = a.text[0..a.text_len];
        z.beginRow(&l, k, .{ .label = tool, .active = a.changed, .tooltip = answer });
        const rr = l.row_rect;
        const p = z.painter();
        const dot: u32 = switch (a.status) {
            0 => COL_OK,
            1 => COL_REC,
            else => COL_WARN,
        };
        // (in the row's gutter, where a fold arrow would be)
        p.rect(.{ .rect = .{ .x = rr.x + 4, .y = rr.y + rr.h / 2 - 3.5, .w = 7, .h = 7 }, .fill = host.col(dot) });
        z.pushClip(.{ .x = rr.x + 180, .y = rr.y, .w = @max(0, rr.w - 180), .h = rr.h });
        p.text(.{ .x = rr.x + 180, .y = rr.y + (rr.h - z.textSize("").y) / 2 }, host.col(th.text_dim), answer);
        z.popClip();
        _ = z.endRow(&l);
    }
    z.popStyles(2);
    if (z.endList(&l).changed) {
        pick = null;
        for (picks[0..n], 0..) |s, k| if (s) {
            pick = head - 1 - @as(u32, @intCast(k));
            break;
        };
    }
}

/// teamui.s l_tiers: the header's list.
const perm_labels = [3][]const u8{ "Agents: read only", "Agents: may edit", "Agents: edit and files" };

fn pickLabel(k: usize) []const u8 {
    return perm_labels[k];
}
fn pickSet(k: usize) void {
    // (the permission operators: their console line, their undo-free change)
    ops.runId2(([3][]const u8{ "agent.permission_read", "agent.permission_edit", "agent.permission_files" })[k]);
}
fn pickOn(k: usize) bool {
    return tier == k;
}

/// act_header_tools: the permission (who may do what), the MCP clients.
/// (At the original's place: after its 130-wide type button and 6, up to its
/// four 22-wide header buttons and 10.)
pub fn header(i: i16, r: Rect) void {
    const salt: usize = @intCast(i);
    const ar = app.N(i).rect;
    var x = ar.x + 130 + 6;
    const right = ar.x + ar.w - (4 * 22 + 10);
    const y = r.y + 1;
    if (x + 190 > right) return;
    const b = Rect{ .x = x, .y = y, .w = 180, .h = 22 };
    const wid = ui.id(@src(), salt);
    // (a WK_ENUM: the option, cut short of the chevron)
    if (ui.button(wid, b, "", .{ .center = false, .tip = "What AI agents (MCP clients, the co-pilot) may do" })) {
        ui.active = 0;
        menus.openList(.{ .n = 3, .label = pickLabel, .pick = pickSet, .checked = pickOn, .x = b.x, .y = b.bottom() + 2 });
    }
    const lb = perm_labels[@min(tier, 2)];
    _ = ui.cv.textFit(b.x + 8, b.y + @divTrunc(b.h - gfx.glyph_h, 2), b.w - 28, lb, ui.th.text);
    ui.record("enum", lb, b, true);
    ui.cv.line(b.right() - 16, b.y + 9, b.right() - 12, b.y + 13, ui.th.text_dim);
    ui.cv.line(b.right() - 12, b.y + 13, b.right() - 8, b.y + 9, ui.th.text_dim);
    x += 190;
    if (@import("copilot.zig").waiting()) {
        // the co-pilot's proposal waiting: Accept | Revert (teamui.s)
        if (x + 150 > right) return;
        @import("copilot.zig").headerButtons(salt, x, y);
        x += 156;
    }
    if (x + 120 > right) return;
    var nb: [32]u8 = undefined;
    const old = gfx.useFace(.small); // (draw_small)
    _ = ui.cv.text(x, y + 4, std.fmt.bufPrint(&nb, "MCP clients: {d}", .{@import("mcp.zig").clients()}) catch "", ui.th.text_dim);
    _ = gfx.useFace(old);
}


/// The status bar's chip (status.s: "AI: <permission>", the rightmost): drawn
/// with its right edge at `right`; the next chip's right edge.
pub fn statusChip(b: []u8) ?app.Chip {
    const s = std.fmt.bufPrint(b, "AI: {s}", .{tierName(tier)}) catch "AI:";
    return .{ .text = s, .label = s, .title = "AI agents", .tip = "What AI agents (MCP clients, the co-pilot) may do: set it in the AI Activity editor" };
}
// ---- preferences ----------------------------------------------------------------------

pub fn loadPref(k: []const u8, v: []const u8) bool {
    const int = std.fmt.parseInt(i32, v, 10) catch 0;
    if (std.mem.eql(u8, k, "agent_permission")) {
        pr_tier = std.math.clamp(int, -1, 2);
    } else if (std.mem.eql(u8, k, "mcp")) {
        pr_mcp = if (int != 0) 1 else 0;
    } else return false;
    return true;
}

test "permission tiers" {
    try std.testing.expectEqual(@as(u32, 2), opTier("file.save"));
    try std.testing.expectEqual(@as(u32, 2), opTier("image.load"));
    try std.testing.expectEqual(@as(u32, 1), opTier("image.new"));
    try std.testing.expectEqual(@as(u32, 2), opTier("view.screenshot"));
    try std.testing.expectEqual(@as(u32, 1), opTier("view.toggle_grid"));
    init("read-only");
    try std.testing.expectEqual(@as(u32, 0), tier);
    init("files");
    try std.testing.expectEqual(@as(u32, 2), tier);
    init("bogus");
    try std.testing.expectEqual(@as(u32, 1), tier);
    init(null);
    try std.testing.expectEqual(@as(u32, 1), tier);
}
