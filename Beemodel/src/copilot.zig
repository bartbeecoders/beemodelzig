// The procedural co-pilot (copilot.s): node graphs for AI agents.
//
// MCP tools and a resource let an agent read the geometry node catalogue (each
// type with its inputs, values, choices, defaults and outputs) and any tree
// (nodes, links, constants, values, places), then build and change trees with
// the tree.* operators. A proposal wraps that work: the agent opens it
// (propose_begin: everything until the user decides is one undo step), builds,
// closes it (propose_end); the viewport shows a banner and the user keeps it
// (Accept, Enter) or takes it all back (Revert, Esc) in one step.
// proposal_status tells the agent which. The MCP prompt "procedural" hands an
// agent this flow for a goal; bee://graphs is every tree and the proposal.
const std = @import("std");
const json = @import("json.zig");
const app = @import("app.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");
const undo = @import("undo.zig");
const nt = @import("ntree.zig");
const gn = @import("geonodes.zig");

const Rect = gfx.Rect;

pub const State = enum(u8) { none, building, waiting, accepted, reverted };
/// cp_state
pub var state: State = .none;
/// cp_title (what the agent said it does; 90 bytes at most, as mcp_arg_str takes it)
var title_buf: [96]u8 = undefined;
var title_len: usize = 0;

const CP_BTN_W = 130;
const CP_H = 30;
const COL_CP_BG = 0x2b3a55;
const COL_CP_TEXT = 0xe8eef8;
const COL_CP_ACCEPT = 0x3f8f5a;
const COL_CP_REVERT = 0x8f3f3f;
const COL_CP_BTEXT = 0xffffff;

const state_json = [_][]const u8{ "\"none\"", "\"building\"", "\"waiting for the user\"", "\"accepted\"", "\"reverted\"" };

pub fn title() []const u8 {
    return title_buf[0..title_len];
}

// ---- MCP --------------------------------------------------------------------------

const tools_json =
    ",{\"name\":\"node_types\",\"description\":\"The geometry node catalogue: every type with its inputs (slots 1-3, kinds, defaults), values (slots 4-7, kinds, choices, defaults) and outputs, and how the tree.* operators use them.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}" ++
    ",{\"name\":\"describe_graph\",\"description\":\"A geometry node tree as JSON: its nodes (type, links into each input as node + output, constants, values, place) - or every tree when no name is given; also the open proposal's state.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"tree\":{\"type\":\"string\"}}}}" ++
    ",{\"name\":\"propose_begin\",\"description\":\"Open a proposal: the changes until the user accepts or reverts are one undo step. Then build with the tree.* operators or script_eval, and call propose_end.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\",\"description\":\"what it does, shown to the user\"}},\"required\":[\"title\"]}}" ++
    ",{\"name\":\"propose_end\",\"description\":\"Show the open proposal to the user: a banner in the viewport to Accept (keep it) or Revert (take it all back).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}" ++
    ",{\"name\":\"proposal_status\",\"description\":\"The proposal's state: none, building, waiting for the user, accepted or reverted.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}";

const names = [_][]const u8{ "node_types", "describe_graph", "propose_begin", "propose_end", "proposal_status" };

/// cp_tier: every one of these only looks (opening a proposal changes nothing itself).
fn tier(tool: []const u8) ?u32 {
    for (names) |n| {
        if (std.mem.eql(u8, n, tool)) return 0;
    }
    return null;
}

pub const provider = @import("mcp.zig").Provider{ .tools_json = tools_json, .tier = tier, .dispatch = dispatch };

/// cp_dispatch: true when it was one of these (the result written).
fn dispatch(tool: []const u8) bool {
    const mcp = @import("mcp.zig");
    const w = &mcp.txt;
    const eq = std.mem.eql;
    if (eq(u8, tool, "node_types")) {
        typesJson(w);
    } else if (eq(u8, tool, "describe_graph")) {
        var b: [96]u8 = undefined;
        const t = mcp.argStr("tree", &b) orelse "";
        if (t.len == 0) {
            graphsJson(w);
        } else if (nt.find(t)) |k| {
            graphJson(w, k);
        } else mcp.fail("no node tree named ", t);
    } else if (eq(u8, tool, "propose_begin")) {
        if (state == .building or state == .waiting) {
            mcp.fail("a proposal is already open: call propose_end, then wait for the user", "");
            return true;
        }
        var b: [90]u8 = undefined;
        const t = mcp.argStr("title", &b) orelse "";
        @memcpy(title_buf[0..t.len], t);
        title_len = t.len;
        undo.groupBegin(); // everything from here: one step ("AI proposal")
        state = .building;
        app.dirty = true;
        w.raw("proposal open: build or change node trees (tree.* operators, script_eval); everything until the user decides is one undo step. Call propose_end when it is ready to look at.");
    } else if (eq(u8, tool, "propose_end")) {
        const ended = "proposal shown to the user in the viewport (Accept / Revert). Ask proposal_status for the answer; until then the scene shows it.";
        if (state == .building) {
            state = .waiting;
            app.dirty = true;
            w.raw(ended);
        } else if (state == .waiting) {
            w.raw(ended);
        } else mcp.fail("no proposal is open: call propose_begin first", "");
    } else if (eq(u8, tool, "proposal_status")) {
        w.raw(state_json[@intFromEnum(state)]);
    } else return false;
    return true;
}

// ---- JSON ---------------------------------------------------------------------------

const in_kinds = [_][]const u8{ "geometry", "value", "vector", "colour" };
const par_kinds = [_][]const u8{ "number", "choice", "image", "whole number", "tree number" };
const types_a = "{\"geometry_nodes\":[";
const types_b = "],\"how\":\"tree.new <name> makes a tree (its number is its place + 1 in describe_graph); tree.node <tree> <type> [values] adds a node (numbers never change); tree.link <tree> <from[:output]> <to> <input slot 1-3>; tree.node_set <tree> <node> <slot> <x> [y z] sets an input's constant (slots 1-3) or a value (slots 4-7); tree.group <tree> <node...>; tree.node_delete; a Geometry Nodes modifier runs a tree: script_eval m = modifier(obj, \\\"geometry\\\")  modset(obj, m, \\\"tree\\\", number). Every tree needs an output node fed into input 1.\"}";

/// cp_types_json: the geometry node catalogue.
pub fn typesJson(w: *json.W) void {
    w.raw(types_a);
    for (&gn.meta, 0..) |*me, ti| {
        if (ti > 0) w.char(',');
        w.raw("{\"type\":");
        w.q(gn.type_names[ti]);
        w.raw(",\"title\":");
        w.q(gn.titles[ti]);
        const d = &gn.defaults[ti];
        w.raw(",\"inputs\":[");
        var nw: u32 = 0;
        for (0..3) |c| {
            const nm = me.in[c] orelse continue;
            if (nw > 0) w.char(',');
            w.raw("{\"slot\":");
            w.int(@intCast(c + 1));
            w.raw(",\"name\":");
            w.q(nm);
            w.raw(",\"kind\":");
            w.q(in_kinds[me.in_k[c] & 3]);
            w.raw(",\"default\":[");
            w.float(d[4 + c * 3]);
            w.char(',');
            w.float(d[5 + c * 3]);
            w.char(',');
            w.float(d[6 + c * 3]);
            w.raw("]}");
            nw += 1;
        }
        w.raw("],\"values\":[");
        nw = 0;
        for (0..4) |c| {
            const nm = me.val[c] orelse continue;
            if (nw > 0) w.char(',');
            w.raw("{\"slot\":");
            w.int(@intCast(c + 4));
            w.raw(",\"name\":");
            w.q(nm);
            w.raw(",\"kind\":");
            const k: u8 = if (me.val_k[c] <= 4) me.val_k[c] else 0;
            w.q(par_kinds[k]);
            w.raw(",\"default\":");
            w.float(d[c]);
            if (k == 1 and me.choices.len > 0) {
                w.raw(",\"choices\":[");
                for (me.choices, 0..) |ch, j| {
                    if (j > 0) w.char(',');
                    w.q(ch);
                }
                w.char(']');
            }
            w.char('}');
            nw += 1;
        }
        w.raw("],\"outputs\":[");
        nw = 0;
        for (0..3) |c| {
            const nm = me.out[c] orelse continue;
            if (nw > 0) w.char(',');
            w.raw("{\"index\":");
            w.int(@intCast(c));
            w.raw(",\"name\":");
            w.q(nm);
            w.raw(",\"kind\":");
            w.q(in_kinds[me.out_k[c] & 3]);
            w.char('}');
            nw += 1;
        }
        w.raw("]}");
    }
    w.raw(types_b);
}

/// cp_graph_json: one tree.
fn graphJson(w: *json.W, k: u32) void {
    const r = nt.get(k) orelse return;
    w.raw("{\"tree\":");
    w.q(nt.name(r));
    w.raw(",\"number\":");
    w.int(@as(i64, k) + 1);
    w.raw(",\"nodes\":[");
    // (the count as the record has it, at most the 48 a record holds)
    const n = @min(nt.nodes(r), nt.NT_MAXN);
    var j: u32 = 1;
    while (j <= n) : (j += 1) {
        if (j > 1) w.char(',');
        const at = nt.nodeAt(j);
        w.raw("{\"node\":");
        w.int(j);
        w.raw(",\"type\":");
        const ty = nt.rd32(r, at + nt.ND_TYPE);
        w.q(if (ty >= 1 and ty <= gn.type_names.len) gn.type_names[ty - 1] else "?");
        w.raw(",\"inputs\":[");
        for (0..3) |s| {
            if (s > 0) w.char(',');
            w.raw("{\"slot\":");
            w.int(@intCast(s + 1));
            const io = at + nt.ND_IN + s * 16;
            const lk = nt.rd32(r, io);
            if (lk & 0xffff != 0) {
                w.raw(",\"from\":{\"node\":");
                w.int(lk & 0xffff);
                w.raw(",\"output\":");
                w.int((lk >> 16) & 0xff);
                w.raw("}}");
            } else {
                w.raw(",\"value\":[");
                w.float(nt.rdf(r, io + 4));
                w.char(',');
                w.float(nt.rdf(r, io + 8));
                w.char(',');
                w.float(nt.rdf(r, io + 12));
                w.raw("]}");
            }
        }
        w.raw("],\"values\":[");
        for (0..4) |s| {
            if (s > 0) w.char(',');
            w.float(nt.rdf(r, at + nt.ND_P + s * 4));
        }
        w.raw("],\"x\":");
        w.int(placeInt(r, at + nt.ND_POS));
        w.raw(",\"y\":");
        w.int(placeInt(r, at + nt.ND_POS + 2));
        w.char('}');
    }
    w.raw("],\"proposal\":");
    w.raw(state_json[@intFromEnum(state)]);
    w.char('}');
}

/// A node's place (an i16). (The original's wb_int prints a negative one as
/// its 32-bit pattern, -300 as 4294966996: a bug, not kept; mcpmat.zig's
/// "pos" does the same.)
fn placeInt(r: *const nt.Rec, o: usize) i64 {
    const v: i16 = @bitCast(std.mem.readInt(u16, r[o..][0..2], .little));
    return v;
}

/// cp_graphs_json: every tree, and the proposal's state (also bee://graphs).
pub fn graphsJson(w: *json.W) void {
    w.raw("{\"trees\":[");
    var k: u32 = 0;
    while (k < nt.count()) : (k += 1) {
        if (k > 0) w.char(',');
        graphJson(w, k);
    }
    w.raw("],\"proposal\":");
    w.raw(state_json[@intFromEnum(state)]);
    w.char('}');
}

// ---- prompts (MCP prompts/list, prompts/get) -------------------------------------------

const prompts_json = "{\"prompts\":[{\"name\":\"procedural\",\"description\":\"Build or change a geometry node setup for a goal, as a proposal the user previews and accepts or reverts.\",\"arguments\":[{\"name\":\"goal\",\"description\":\"what the node setup should make\",\"required\":true}]},{\"name\":\"build_world\",\"description\":\"Build a world, a model or a change from a description: BeeModel's own AI Assistant instructions (conventions, tools, the look-plan-build-check loop).\",\"arguments\":[{\"name\":\"goal\",\"description\":\"what to build\",\"required\":false}]}]}";
const prompt_1 = "You are BeeModel's procedural co-pilot. Goal: ";
const prompt_2 = "\n\n1. Call scene_summary and describe_graph to see what is there, and node_types for the catalogue.\n2. Call propose_begin with a short title.\n3. Build: tree.new, tree.node, tree.link, tree.node_set, tree.group (op_tree_* tools), and put the tree on an object with script_eval: m = modifier(name, \"geometry\") then modset(name, m, \"tree\", number). Check the result with viewport_capture and describe_graph; fix what is wrong.\n4. Call propose_end and tell the user what you made; they accept or revert it in the viewport.\n5. Call proposal_status to learn their answer before building on it.";

pub fn promptsList(w: *json.W) void {
    w.raw(prompts_json);
}

/// The AI Assistant's build_world prompt (ai_world_get), when it is there.
pub var world_get: ?*const fn (w: *json.W, goal: []const u8) void = null;

/// prompts/get: build_world is the AI Assistant's; anything else the
/// procedural prompt (as the original's handle_message picks).
pub fn promptGet(w: *json.W, name: []const u8, goal: []const u8) void {
    if (std.mem.eql(u8, name, "build_world")) {
        if (world_get) |f| return f(w, goal);
    }
    procedural(w, goal);
}

/// cp_prompt_get: the procedural prompt's messages (its text at most 4000
/// bytes, as cp_cat bounds it).
pub fn procedural(w: *json.W, goal: []const u8) void {
    var t: [4001]u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{ prompt_1, goal, prompt_2 }) |s| {
        for (s) |c| {
            if (n >= 4000 or c == 0) break;
            t[n] = c;
            n += 1;
        }
    }
    w.raw("{\"description\":\"Procedural co-pilot\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":");
    w.q(t[0..n]);
    w.raw("}}]}");
}

// ---- the user's side: the banner, Accept / Revert ---------------------------------------

/// cp_accept: the proposal kept as one undo step.
pub fn accept() void {
    if (state != .waiting) return;
    _ = undo.groupEnd("AI proposal");
    state = .accepted;
    app.dirty = true;
    app.log("  AI proposal accepted (one undo step)", .{});
}

/// cp_revert: the proposal taken back, all of it.
pub fn revert() void {
    if (state != .building and state != .waiting) return;
    if (undo.groupEnd("AI proposal")) {
        // the whole proposal in one undo (run_op op_edit_undo)
        if (@import("ops.zig").byId("edit.undo")) |i| @import("mcp.zig").runOp(i, "");
    }
    state = .reverted;
    app.dirty = true;
    app.log("  AI proposal reverted", .{});
}

pub fn waiting() bool {
    return state == .waiting;
}

/// cp_key: true when the proposal took the key (Enter accepts a finished one,
/// Esc reverts).
pub fn key(k: u32) bool {
    if (state != .building and state != .waiting) return false;
    if (k == ui.KEY.ESC) {
        revert();
        return true;
    }
    if (state == .waiting and (k == ui.KEY.ENTER or k == ui.KEY.KPENTER)) {
        accept();
        return true;
    }
    return false;
}

/// cp_draw, cp_click: the banner along the top of a viewport (r: its area)
/// while a proposal is built or waits, a Zui part: what it is, and Accept |
/// Revert once it waits. Over the view, so a click on it is the banner's.
pub fn banner(salt: usize, r: Rect) void {
    if (state != .building and state != .waiting) return;
    const br = Rect{ .x = r.x + 8, .y = r.y + 46, .w = r.w - 16, .h = CP_H };
    var tb: [128]u8 = undefined;
    ui.record("banner", std.fmt.bufPrint(&tb, "AI proposal: {s}", .{title()}) catch "", br, true);
    const z = host.beginPart("copilot", salt, br) orelse return;
    defer host.endPart(z);
    z.drawRect(.{ .rect = host.zr(br), .fill = host.col(COL_CP_BG) });
    z.beginHorizontal(.{ .width = .fill, .height = .px(CP_H), .padding = 4, .spacing = 8 });
    defer z.endHorizontal();
    var sb: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&sb, "AI proposal: {s}{s}", .{ title(), if (state == .building) "  (the agent is still working)" else "" }) catch "";
    z.spacer(.px(2));
    // (a long title: cut short of the buttons, ending in "…")
    z.label(s, .{ .color = host.col(COL_CP_TEXT), .width = .fill });
    if (state != .waiting) return;
    if (decisionButton(z, "Accept  Enter", COL_CP_ACCEPT)) {
        accept();
        app.afterInput();
    }
    if (decisionButton(z, "Revert  Esc", COL_CP_REVERT)) {
        revert();
        app.afterInput();
    }
}

fn decisionButton(z: *zui.Ui, label: []const u8, c: u32) bool {
    z.pushColor(.button, host.col(c));
    z.pushColor(.button_hovered, host.col(c));
    z.pushColor(.button_active, host.col(c));
    z.pushColor(.text, host.col(COL_CP_BTEXT));
    defer z.popStyles(4);
    return z.button(label, .{ .width = .px(CP_BTN_W), .height = .px(CP_H - 8) }).clicked;
}

/// The AI Activity header's Accept | Revert (teamui.s), at x: while a
/// proposal waits for the user. A Zui part.
pub fn headerButtons(salt: usize, x: i32, y: i32) void {
    const z = host.beginPart("copilot.head", salt, .{ .x = x, .y = y, .w = 146, .h = 22 }) orelse return;
    defer host.endPart(z);
    z.beginHorizontal(.{ .width = .fill, .spacing = 6 });
    defer z.endHorizontal();
    const a = z.button("Accept", .{ .width = .px(70), .height = .px(22), .variant = .selected });
    z.tooltipRich(a, .{ .title = "Accept", .body = "Keep the agent's proposal (Enter)" });
    if (a.clicked) {
        accept();
        app.afterInput();
    }
    const rv = z.button("Revert", .{ .width = .px(70), .height = .px(22) });
    z.tooltipRich(rv, .{ .title = "Revert", .body = "Take the whole proposal back (Esc)" });
    if (rv.clicked) {
        revert();
        app.afterInput();
    }
}

test "the catalogue and prompts are JSON" {
    var w: json.W = .{};
    typesJson(&w);
    try std.testing.expect(json.valid(w.items()));
    w.reset();
    procedural(&w, "a fence \"x\"");
    try std.testing.expect(json.valid(w.items()));
    w.reset();
    graphsJson(&w);
    try std.testing.expectEqualStrings("{\"trees\":[],\"proposal\":\"none\"}", w.items());
}
