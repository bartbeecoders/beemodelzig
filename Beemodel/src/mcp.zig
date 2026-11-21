// The MCP server (Model Context Protocol) for AI agents: the original's mcp.s.
//
// The running app listens on a unix socket ($XDG_RUNTIME_DIR/beemodel.sock ->
// beemodel-<pid>.sock). Messages are newline-delimited JSON-RPC 2.0, the same
// framing as the MCP stdio transport, so `beemodel --mcp-bridge` only relays
// bytes between stdin/stdout and the socket. Requests run on the UI thread from
// the main poll loop: no locking, and every change goes through the operator
// spine and the undo history like a user action (one step per request).
//
// Tools: the curated scene tools, those other files register (Provider: the
// material tools of mcpmat.zig, the co-pilot's ...) and every operator the
// original flags OPF_AI_SAFE (aisafe.zig) as op_<id with dots as underscores>.
// Resources: bee://scene, bee://graphs. Prompts: from a registered provider.
const std = @import("std");
const linux = std.os.linux;
const json = @import("json.zig");
const app = @import("app.zig");
const scene = @import("scene.zig");
const ops = @import("ops.zig");
const cat = @import("catalog.zig");
const undo = @import("undo.zig");
const agent = @import("agent.zig");
const aisafe = @import("aisafe.zig");
const material = @import("material.zig");
const images = @import("images.zig");
const m = @import("math.zig");

pub const MAX_CLIENTS = 4;
const CIN_CAP = 0x40000; // 256 KiB per client request buffer
const VERSION = "1.3.1"; // the original's VERSION, as its serverInfo says
const LOG_LINE = 95; // the original's console lines (LOG_LINE_LEN - 1) ...
const LOG_RING = 32; // ... in a ring of 32 (what a tool's text copies)

// ---- registration: tools other files add ---------------------------------------------

/// Tools another file adds: its tools/list entries (",{...}" each), the
/// permission each needs (0 read, 1 edit, 2 files; null: not one of these) and
/// its dispatch (true: it was one of these, its text written into `txt`).
pub const Provider = struct {
    tools_json: []const u8,
    tier: *const fn (tool: []const u8) ?u32,
    dispatch: *const fn (tool: []const u8) bool,
};

/// In the original's order (tools/list, permissions, dispatch): the co-pilot's
/// (copilot.s), the material tools (mcpmat.s), reference images (refset.s),
/// then one more for later files.
pub const Slot = enum(u8) { copilot, material, refs, extra };
pub var providers: [4]?Provider = .{ @import("copilot.zig").provider, @import("mcpmat.zig").provider, @import("refset.zig").mcp_provider, null };

/// prompts/list's result (the co-pilot's: cp_prompts_list); null: none.
pub var prompts_list: ?*const fn (w: *json.W) void = @import("copilot.zig").promptsList;
/// prompts/get's result for a prompt and its goal (cp_prompt_get, and the AI
/// Assistant's build_world: ai_world_get); null: none.
pub var prompt_get: ?*const fn (w: *json.W, name: []const u8, goal: []const u8) void = @import("copilot.zig").promptGet;
/// prompts/get build_world: the AI Assistant's instructions and the goal
/// (ai_world_get); null: none.
pub var world_get: ?*const fn (w: *json.W, goal: []const u8) void = null;
/// bee://graphs (cp_graphs_json: the geometry node trees and the proposal).
pub var graphs_json: ?*const fn (w: *json.W) void = @import("copilot.zig").graphsJson;
/// The co-editing hook (co_mcp_touch), and anything else that wants to know.
pub var on_call: ?*const fn () void = null;

// ---- state ------------------------------------------------------------------------

var lsock: i32 = -1;
var cl_fd: [MAX_CLIENTS]i32 = @splat(-1);
var cl_len: [MAX_CLIENTS]usize = @splat(0);
var cl_buf: [MAX_CLIENTS][CIN_CAP]u8 = undefined;
var sock_path: [120]u8 = undefined;
var sock_len: usize = 0;
var link_path: [120]u8 = undefined;
var link_len: usize = 0;

/// The response being built.
pub var out: json.W = .{};
/// A tool's text.
pub var txt: json.W = .{};
/// A capture's PNG.
var img: []u8 = &.{};
var has_image = false;
var is_error = false;
/// The client the message came from (-1: mcp_local's caller).
var cur_client: i32 = -1;

/// The message being handled; positions below index into it.
pub var msg: []const u8 = "";
var params: ?usize = null;
var targs: ?usize = null;
var tool_buf: [96]u8 = undefined;
var tool: []const u8 = "";
/// The operator the tool runs (run_operator, op_<id>), for permissions.
var tool_op: ?usize = null;

// ---- setup -----------------------------------------------------------------------

fn runtimeDir(dst: []u8, xdg: ?[]const u8) usize {
    const d = if (xdg) |x| (if (x.len > 0) x else "/tmp") else "/tmp";
    const n = @min(d.len, dst.len);
    @memcpy(dst[0..n], d[0..n]);
    return n;
}

fn cat0(dst: []u8, at: usize, s: []const u8) usize {
    const n = @min(s.len, dst.len -| at);
    @memcpy(dst[at .. at + n], s[0..n]);
    return at + n;
}

fn zpath(buf: *[120]u8, len: usize, z: *[121]u8) [*:0]const u8 {
    @memcpy(z[0..len], buf[0..len]);
    z[len] = 0;
    return z[0..len :0].ptr;
}

/// The whole path is there (it ends ".sock", its file name came through) and
/// fits a sockaddr_un with its NUL.
fn pathFits(buf: []const u8, len: usize, name: []const u8) bool {
    if (len == 0 or len > 107 or len >= buf.len) return false;
    const p = buf[0..len];
    return std.mem.endsWith(u8, p, ".sock") and std.mem.indexOf(u8, p, name) != null;
}

fn sockaddr(path: []const u8) linux.sockaddr.un {
    var a = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = @splat(0) };
    const n = @min(path.len, a.path.len - 1);
    @memcpy(a.path[0..n], path[0..n]);
    return a;
}

/// mcp_init: start listening (the preference off, or BEEMODEL_NO_MCP=1: not).
pub fn init(xdg: ?[]const u8, no_mcp: ?[]const u8, perm: ?[]const u8) void {
    agent.init(perm);
    if (agent.pr_mcp == 0) return;
    if (no_mcp) |v| {
        if (v.len > 0 and v[0] == '1') return;
    }
    var n = runtimeDir(&sock_path, xdg);
    n = cat0(&sock_path, n, "/beemodel-");
    var pb: [16]u8 = undefined;
    n = cat0(&sock_path, n, std.fmt.bufPrint(&pb, "{d}", .{linux.getpid()}) catch "0");
    n = cat0(&sock_path, n, ".sock");
    sock_len = n;
    link_len = cat0(&link_path, runtimeDir(&link_path, xdg), "/beemodel.sock");
    // A path cut short (a sockaddr holds 107 bytes and a NUL) names some other
    // file: never unlink, bind or link it (the original cut it and went on).
    if (!pathFits(&sock_path, sock_len, "/beemodel-") or !pathFits(&link_path, link_len, "/beemodel.sock")) {
        sock_len = 0;
        link_len = 0;
        app.log("! MCP: the runtime folder's path is too long for a socket ($XDG_RUNTIME_DIR); agents can't connect", .{});
        return;
    }
    var z: [121]u8 = undefined;
    _ = linux.unlink(zpath(&sock_path, sock_len, &z)); // (a stale socket of a crashed run)
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    const a = sockaddr(sock_path[0..sock_len]);
    if (linux.errno(linux.bind(fd, @ptrCast(&a), 110)) != .SUCCESS or linux.errno(linux.listen(fd, MAX_CLIENTS)) != .SUCCESS) {
        _ = linux.close(fd);
        return;
    }
    lsock = fd;
    // the newest instance owns beemodel.sock
    var zl: [121]u8 = undefined;
    _ = linux.unlink(zpath(&link_path, link_len, &zl));
    _ = linux.symlink(zpath(&sock_path, sock_len, &z), zpath(&link_path, link_len, &zl));
    app.log("MCP server ready: connect agents with beemodel --mcp-bridge", .{});
}

/// mcp_shutdown: the sockets go (beemodel.sock only while it is still ours: a
/// newer instance's stays).
pub fn shutdown() void {
    if (lsock < 0) return;
    var z: [121]u8 = undefined;
    var zl: [121]u8 = undefined;
    const lp = zpath(&link_path, link_len, &zl);
    var tgt: [128]u8 = undefined;
    const r = linux.readlink(lp, &tgt, tgt.len);
    if (linux.errno(r) == .SUCCESS and std.mem.eql(u8, tgt[0..r], sock_path[0..sock_len])) _ = linux.unlink(lp);
    _ = linux.unlink(zpath(&sock_path, sock_len, &z));
    for (&cl_fd) |*f| {
        if (f.* >= 0) _ = linux.close(f.*);
        f.* = -1;
    }
    _ = linux.close(lsock);
    lsock = -1;
}

/// This instance's socket ($XDG_RUNTIME_DIR/beemodel-<pid>.sock): what the AI
/// Assistant's bridge connects to.
pub fn sockPath() []const u8 {
    return sock_path[0..sock_len];
}

/// mcp_listening: agents can connect.
pub fn listening() bool {
    return lsock >= 0;
}

/// mcp_clients: connected agents.
pub fn clients() u32 {
    var n: u32 = 0;
    for (cl_fd) |f| {
        if (f >= 0) n += 1;
    }
    return n;
}

/// mcp_pollfds: the listener and the clients (entries written).
pub fn pollfds(p: []linux.pollfd) usize {
    if (lsock < 0 or p.len < 1 + MAX_CLIENTS) return 0;
    p[0] = .{ .fd = lsock, .events = linux.POLL.IN, .revents = 0 };
    var n: usize = 1;
    for (cl_fd) |f| {
        if (f < 0) continue;
        p[n] = .{ .fd = f, .events = linux.POLL.IN, .revents = 0 };
        n += 1;
    }
    return n;
}

/// mcp_handle: as filled by pollfds and polled: a new connection, then every
/// client with something to read.
pub fn handle(p: []const linux.pollfd) void {
    if (lsock < 0 or p.len == 0) return;
    if (p[0].revents & linux.POLL.IN != 0) {
        const rc = linux.accept4(lsock, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) == .SUCCESS) {
            const fd: i32 = @intCast(rc);
            for (&cl_fd, 0..) |*f, k| {
                if (f.* < 0) {
                    f.* = fd;
                    cl_len[k] = 0;
                    break;
                }
            } else _ = linux.close(fd); // full
        }
    }
    var e: usize = 1; // client entries follow in slot order (those polled this round)
    for (0..MAX_CLIENTS) |k| {
        if (e >= p.len) break;
        if (cl_fd[k] < 0 or p[e].fd != cl_fd[k]) continue;
        if (p[e].revents & (linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP) != 0) clientRead(k);
        e += 1;
    }
}

fn dropClient(k: usize) void {
    if (cl_fd[k] >= 0) _ = linux.close(cl_fd[k]);
    cl_fd[k] = -1;
    cl_len[k] = 0;
    app.dirty = true;
}

/// client_read: read, then run every complete line. A line larger than the
/// buffer, an error or the end: the client goes.
fn clientRead(k: usize) void {
    const room = CIN_CAP - cl_len[k];
    if (room == 0) return dropClient(k);
    const rc = linux.read(cl_fd[k], cl_buf[k][cl_len[k]..].ptr, room);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return dropClient(k);
    cl_len[k] += rc;
    while (cl_fd[k] >= 0) {
        const nl = std.mem.indexOfScalar(u8, cl_buf[k][0..cl_len[k]], '\n') orelse break;
        cur_client = @intCast(k);
        handleMessage(cl_buf[k][0..nl]);
        cur_client = -1;
        if (cl_fd[k] < 0) break; // (it went while we answered)
        const rest = cl_len[k] - nl - 1;
        std.mem.copyForwards(u8, cl_buf[k][0..rest], cl_buf[k][nl + 1 .. cl_len[k]]);
        cl_len[k] = rest;
    }
}

/// mcp_local: the AI Assistant's tool calls, run as a client's would be (the
/// same permission, undo, activity): the response (valid until the next message).
pub fn local(request: []const u8) []const u8 {
    const was = cur_client;
    cur_client = -1;
    handleMessage(request);
    cur_client = was;
    return out.items();
}

/// send_out: the response to the current client. A client that reads nothing
/// for 5 s while we write goes (the original blocked the UI on it).
fn sendOut() void {
    if (cur_client < 0) return;
    const k: usize = @intCast(cur_client);
    const fd = cl_fd[k];
    if (fd < 0) return;
    var d = out.items();
    while (d.len > 0) {
        const rc = linux.sendto(fd, d.ptr, d.len, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => d = d[rc..],
            .INTR => {},
            .AGAIN => {
                var pf = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                const pr = linux.poll(&pf, 1, 5000);
                if (pr == 0 or pf[0].revents & (linux.POLL.ERR | linux.POLL.HUP) != 0) return dropClient(k);
            },
            else => return dropClient(k),
        }
    }
}

// ---- JSON-RPC ----------------------------------------------------------------------

const r_head = "{\"jsonrpc\":\"2.0\",\"id\":";
const r_init_b = ",\"capabilities\":{\"tools\":{},\"resources\":{},\"prompts\":{}},\"serverInfo\":{\"name\":\"beemodel\",\"version\":";
const r_init_c = "},\"instructions\":\"BeeModel is a 3D modeler. Units are meters, Y is up, rotations are Euler XYZ in degrees (rotation_deg). Every change is undoable (undo tool). Start with scene_summary; create objects with create_primitive, place them with set_transform; use script_eval (BeeScript) for loops and bulk edits; look at the result with viewport_capture. For node setups (procedural geometry) use the procedural prompt: node_types, describe_graph, propose_begin / propose_end around the tree.* operators, then proposal_status.\"}";
const r_res_list = "{\"resources\":[{\"uri\":\"bee://scene\",\"name\":\"Scene\",\"description\":\"Objects, transforms and mesh sizes as JSON\",\"mimeType\":\"application/json\"},{\"uri\":\"bee://graphs\",\"name\":\"Node graphs\",\"description\":\"Every geometry node tree (nodes, links, constants, values) and the co-pilot proposal's state as JSON\",\"mimeType\":\"application/json\"}]}";

fn str(v: usize, dst: []u8) ?[]u8 {
    return json.str(msg, v, dst);
}

/// handle_message: one JSON-RPC message (its line, without the newline).
pub fn handleMessage(text: []const u8) void {
    msg = text;
    params = null;
    targs = null;
    var id: ?[]const u8 = null;
    defer app.dirty = true;
    if (!json.valid(text)) return errorReply(id, ",\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}\n");
    const w0 = json.ws(text, 0);
    if (text[w0] != '{') return errorReply(id, ",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}\n");
    var mb: [64]u8 = undefined;
    var method: []const u8 = "";
    if (json.find(text, 0, "method")) |v| method = str(v, &mb) orelse "";
    if (json.find(text, 0, "id")) |v| id = text[v..json.skip(text, v)];
    params = json.find(text, 0, "params");
    const rid = id orelse return; // notifications get no answer
    if (method.len == 0) {
        // no method: a response to us is fine, anything else is an invalid request
        if (json.find(text, 0, "result") != null or json.find(text, 0, "error") != null) return;
        return errorReply(id, ",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}\n");
    }
    out.reset();
    out.raw(r_head);
    out.bytes(rid);
    const eq = std.mem.eql;
    if (eq(u8, method, "initialize")) {
        out.raw(",\"result\":{\"protocolVersion\":");
        var pv: []const u8 = "2025-06-18"; // (the client's, echoed)
        var pb: [64]u8 = undefined;
        if (params) |p| {
            if (json.find(text, p, "protocolVersion")) |v| {
                if (str(v, &pb)) |s| {
                    if (s.len > 0) pv = s;
                }
            }
        }
        out.q(pv);
        out.raw(r_init_b);
        out.q(VERSION);
        out.raw(r_init_c);
    } else if (eq(u8, method, "ping")) {
        out.raw(",\"result\":{}");
    } else if (eq(u8, method, "tools/list")) {
        out.raw(",\"result\":");
        toolsList(&out);
    } else if (eq(u8, method, "tools/call")) {
        out.raw(",\"result\":");
        toolsCall();
    } else if (eq(u8, method, "resources/list")) {
        out.raw(",\"result\":");
        out.raw(r_res_list);
    } else if (eq(u8, method, "resources/read")) {
        out.raw(",\"result\":");
        resourcesRead();
    } else if (eq(u8, method, "prompts/list")) {
        out.raw(",\"result\":");
        if (prompts_list) |f| f(&out) else out.raw("{\"prompts\":[]}");
    } else if (eq(u8, method, "prompts/get")) {
        out.raw(",\"result\":");
        var nb: [64]u8 = undefined;
        var gb: [500]u8 = undefined;
        var name: []const u8 = "";
        var goal: []const u8 = "";
        if (params) |p| {
            if (json.find(text, p, "name")) |v| name = str(v, &nb) orelse "";
            if (json.find(text, p, "arguments")) |a| {
                if (json.find(text, a, "goal")) |v| goal = str(v, &gb) orelse "";
            }
        }
        if (eq(u8, name, "build_world") and world_get != null) {
            world_get.?(&out, goal);
        } else if (prompt_get) |f| f(&out, name, goal) else out.raw("{\"messages\":[]}");
    } else {
        out.raw(",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n");
        return sendOut();
    }
    out.raw("}\n");
    sendOut();
}

/// -32700 (id null) and -32600 (with the id if there is one).
fn errorReply(id: ?[]const u8, tail: []const u8) void {
    out.reset();
    out.raw(r_head);
    if (id) |i| out.bytes(i) else out.raw("null");
    out.raw(tail);
    sendOut();
}

fn resourcesRead() void {
    var graphs = false;
    if (params) |p| {
        if (json.find(msg, p, "uri")) |v| {
            var b: [64]u8 = undefined;
            graphs = std.mem.eql(u8, str(v, &b) orelse "", "bee://graphs");
        }
    }
    txt.reset();
    if (!graphs) sceneJson(&txt) else if (graphs_json) |f| f(&txt) else txt.raw("{\"trees\":[],\"proposal\":\"none\"}");
    out.raw(if (graphs) "{\"contents\":[{\"uri\":\"bee://graphs\",\"mimeType\":\"application/json\",\"text\":" else "{\"contents\":[{\"uri\":\"bee://scene\",\"mimeType\":\"application/json\",\"text\":");
    out.q(txt.items());
    out.raw("}]}");
}

// ---- tools/list ---------------------------------------------------------------------

const curated_tools =
    "{\"name\":\"scene_summary\",\"description\":\"List every object (name, type, location, rotation_deg, scale, selection, mesh size, modifiers, material) and every material with its values.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"create_primitive\",\"description\":\"Add an object. type: cube, sphere, cylinder, cone, torus, plane, grid, light or camera. Default size: 2 m cube / 1 m radius. Optional name, location, rotation_deg, scale (3 numbers each).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"type\":{\"type\":\"string\",\"enum\":[\"cube\",\"sphere\",\"cylinder\",\"cone\",\"torus\",\"plane\",\"grid\",\"light\",\"camera\"]},\"name\":{\"type\":\"string\"},\"location\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}},\"rotation_deg\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}},\"scale\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}}},\"required\":[\"type\"]}}," ++
    "{\"name\":\"set_transform\",\"description\":\"Change an object's location, rotation_deg and/or scale (3 numbers each), or rename it with new_name.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"new_name\":{\"type\":\"string\"},\"location\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}},\"rotation_deg\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}},\"scale\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}}},\"required\":[\"name\"]}}," ++
    "{\"name\":\"select\",\"description\":\"Select objects by name (the last one becomes active). extend keeps the current selection.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"names\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"extend\":{\"type\":\"boolean\"}},\"required\":[\"names\"]}}," ++
    "{\"name\":\"delete\",\"description\":\"Delete objects by name.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"names\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"names\"]}}," ++
    "{\"name\":\"run_operator\",\"description\":\"Run any BeeModel operator by id (see console.list_ops), with an optional text argument such as a file path.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"arg\":{\"type\":\"string\"}},\"required\":[\"id\"]}}," ++
    "{\"name\":\"viewport_capture\",\"description\":\"Look at the scene: a PNG image of the 3D viewport as it is now (area: viewport or window).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"area\":{\"type\":\"string\",\"enum\":[\"viewport\",\"window\"]}}}}," ++
    "{\"name\":\"script_eval\",\"description\":\"Run BeeScript, BeeModel's scripting language, as one undo step; returns what it prints plus the last value. Best for bulk or procedural edits. Syntax: x = 2m; for i in 0..10 { add(\\\"cube\\\", \\\"C\\\" + i, i * 2, 0, 0) }; if a > 1 and b { } else { }; while c { }; fn f(a) { return a * 2 }. Units: m cm mm km deg rad (angles are radians, 45deg works). Scene: add(type, [name], [x, y, z]) -> name; move / rotate / scale(name, x, y, z); scale(name, s); get(name, prop) and set(name, prop, v) with prop x y z rx ry rz sx sy sz; select(names...); delete(names...); rename(old, new); exists(name); count(); name(i); active(); op(id, [arg]). Also print(...), str, num, len, sin, cos, tan, sqrt, abs, floor, round, min, max, pow, atan2, deg, rad, rand, seed, pi.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"string\",\"description\":\"BeeScript source\"}},\"required\":[\"code\"]}}," ++
    "{\"name\":\"ui_tree\",\"description\":\"List the widgets on screen this frame (buttons, fields, toggles, lists, sections) with their name, sub index, kind, rectangle in window pixels, label and value. Use it to find what the user sees and where to click.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"undo\",\"description\":\"Undo the last change.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"redo\",\"description\":\"Redo the last undone change.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}";

/// Operator i's tool name: "op_" + its id with '.' -> '_'.
fn toolName(i: usize, dst: *[128]u8) []const u8 {
    const id = cat.entries[i].id;
    @memcpy(dst[0..3], "op_");
    const n = @min(id.len, dst.len - 3);
    for (id[0..n], 0..) |c, k| dst[3 + k] = if (c == '.') '_' else c;
    return dst[0 .. 3 + n];
}

/// The original's OPF_AI_SAFE and OPF_QUIET, by catalogue index.
const flags = blk: {
    @setEvalBranchQuota(4_000_000);
    var safe: [cat.entries.len]bool = @splat(false);
    var quiet: [cat.entries.len]bool = @splat(false);
    for (aisafe.ids) |id| {
        for (cat.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.id, id)) safe[i] = true;
        }
    }
    for (aisafe.quiet) |id| {
        for (cat.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.id, id)) quiet[i] = true;
        }
    }
    break :blk .{ .safe = safe, .quiet = quiet };
};

pub fn aiSafe(i: usize) bool {
    return flags.safe[i];
}

fn toolsList(w: *json.W) void {
    w.raw("{\"tools\":[");
    w.raw(curated_tools);
    for (providers) |p| {
        if (p) |pv| w.raw(pv.tools_json);
    }
    var nb: [128]u8 = undefined;
    var db: [1024]u8 = undefined;
    for (cat.entries, 0..) |e, i| {
        if (!flags.safe[i] or e.hidden) continue;
        w.raw(",{\"name\":");
        w.q(toolName(i, &nb));
        w.raw(",\"description\":");
        w.q(std.fmt.bufPrint(&db, "{s} - {s}", .{ e.label, e.doc }) catch e.label);
        w.raw(",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"arg\":{\"type\":\"string\",\"description\":\"optional argument, e.g. a file path\"}}}}");
    }
    w.raw("]}");
}

// ---- tools/call ---------------------------------------------------------------------

/// mcp_fail: an error for the agent (message, then a detail).
pub fn fail(message: []const u8, detail: []const u8) void {
    is_error = true;
    txt.raw(message);
    txt.raw(detail);
}

/// A tool's picture (has_image, img_state): a PNG the reply carries after its
/// text (page_allocator memory, kept until the next one).
pub fn setImage(png: []u8) void {
    if (img.len > 0) std.heap.page_allocator.free(img);
    img = png;
    has_image = true;
}

/// mcp_arg_val: the JSON value of an argument (a position in msg), or null.
pub fn argVal(key: []const u8) ?usize {
    const a = targs orelse return null;
    return json.find(msg, a, key);
}

/// mcp_arg_str: an argument as text (at most dst.len - 1 bytes), null when it
/// is missing or not a string.
pub fn argStr(key: []const u8, dst: []u8) ?[]u8 {
    const v = argVal(key) orelse return null;
    return json.str(msg, v, dst);
}

/// arg_vec: three numbers (true when the list has exactly 3).
fn argVec(key: []const u8) ?[3]f32 {
    const v = argVal(key) orelse return null;
    var r: [3]f32 = .{ 0, 0, 0 };
    var n: usize = 0;
    var e = json.first(msg, v);
    while (e) |el| {
        if (n >= 3) break;
        r[n] = json.num(msg, el).v;
        n += 1;
        e = json.next(msg, el);
    }
    return if (n == 3) r else null;
}

fn toolsCall() void {
    if (on_call) |f| f();
    @import("cosync.zig").mcp_touch = true; // (co-editing: the agent's, maybe)
    txt.reset();
    is_error = false;
    has_image = false;
    tool = "";
    targs = null;
    if (params) |p| {
        if (json.find(msg, p, "name")) |v| {
            tool = str(v, &tool_buf) orelse "";
            targs = json.find(msg, p, "arguments");
        }
    }
    app.log("  mcp: {s}", .{tool}); // (visible in the console)
    var mark = app.log_count;
    var changed = false;
    var status: u8 = 0;
    const need = toolTier();
    if (need > agent.tier) {
        deny(need);
        status = 2;
    } else if (need == 0 or isUndoTool()) {
        dispatch(&mark);
    } else {
        // one undo step per request
        var lb: [112]u8 = undefined;
        const label = std.fmt.bufPrint(&lb, "Agent: {s}", .{tool}) catch "Agent:";
        undo.groupBegin();
        dispatch(&mark);
        changed = undo.groupEnd(label);
    }
    // what the tool printed to the console, as the original's 32-line ring holds it
    const head = app.log_count;
    var k = mark;
    while (k < head) : (k += 1) {
        const eff = k + LOG_RING * ((head - 1 - k) / LOG_RING);
        const l = app.logLine(eff);
        txt.char('\n');
        txt.raw(l[0..@min(l.len, LOG_LINE)]);
    }
    if (status == 0 and is_error) status = 1;
    agent.record(tool, status, changed, txt.items());
    out.raw("{\"content\":[{\"type\":\"text\",\"text\":");
    out.q(txt.items());
    out.char('}');
    if (has_image) {
        out.raw(",{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"");
        out.base64(img);
        out.raw("\"}");
    }
    out.raw("],\"isError\":");
    out.raw(if (is_error) "true" else "false");
    out.char('}');
}

/// tool_tier: the permission the requested tool needs; tool_op: the operator
/// it runs, if any.
fn toolTier() u32 {
    tool_op = null;
    for (providers) |p| {
        if (p) |pv| {
            if (pv.tier(tool)) |t| return t;
        }
    }
    const eq = std.mem.eql;
    if (eq(u8, tool, "scene_summary") or eq(u8, tool, "viewport_capture") or eq(u8, tool, "ui_tree")) return 0;
    if (eq(u8, tool, "run_operator")) {
        var b: [64]u8 = undefined;
        const id = argStr("id", &b) orelse "";
        tool_op = ops.byId(id);
        return if (tool_op) |i| agent.opTier(cat.entries[i].id) else 1;
    }
    var nb: [128]u8 = undefined;
    for (0..cat.entries.len) |i| {
        if (eq(u8, tool, toolName(i, &nb))) {
            tool_op = i;
            return agent.opTier(cat.entries[i].id);
        }
    }
    return 1;
}

/// is_undo_tool: undo / redo work on the steps themselves (tools or operators).
fn isUndoTool() bool {
    const eq = std.mem.eql;
    if (eq(u8, tool, "undo") or eq(u8, tool, "redo")) return true;
    const i = tool_op orelse return false;
    const id = cat.entries[i].id;
    // (adjusting the last operation re-runs it from its own undo step)
    return eq(u8, id, "edit.undo") or eq(u8, id, "edit.redo") or eq(u8, id, "agent.revert") or eq(u8, id, "edit.redo_last");
}

/// deny: the permission error for the agent.
fn deny(need: u32) void {
    is_error = true;
    txt.raw("permission denied: ");
    txt.raw(tool);
    txt.raw(" needs the '");
    txt.raw(agent.tierName(need));
    txt.raw("' permission and agents are set to '");
    txt.raw(agent.tierName(agent.tier));
    txt.raw("'. The user can change this in BeeModel's AI menu.");
}

/// run_op as the original runs an operator for an agent: "> Label" in the
/// console (unless it is quiet), then the operator with its argument. A port
/// operator that cannot run now says why (ops.run). Undo and redo say what
/// the original's do.
pub fn runOp(i: usize, arg: []const u8) void {
    const id = cat.entries[i].id;
    const eq = std.mem.eql;
    if (eq(u8, id, "edit.undo")) return stepBack(true);
    if (eq(u8, id, "edit.redo")) return stepBack(false);
    if (eq(u8, id, "agent.revert")) return agent.revert();
    if (!flags.quiet[i]) app.log("> {s}", .{cat.entries[i].label});
    undo.keepSelection();
    // a path for the file operators, as the console takes it (editors.runCommand)
    // (and never "Save changes?": the original's run_op does not ask)
    const files = @import("files.zig");
    if (eq(u8, id, "file.new")) return files.unguarded(.new, "");
    if (arg.len > 0) {
        if (eq(u8, id, "file.open")) return files.unguarded(.recent, arg);
        if (eq(u8, id, "file.save") or eq(u8, id, "file.save_as")) return files.saveTo(arg);
        if (eq(u8, id, "file.import_obj") or eq(u8, id, "file.import_stl")) return files.importPath(arg);
        if (eq(u8, id, "file.export_obj") or eq(u8, id, "file.export_stl")) return files.exportPath(arg);
    }
    const was_arg = ops.arg;
    const was_s = ops.scripted;
    ops.arg = arg;
    ops.scripted = true; // (no form asks)
    defer {
        ops.arg = was_arg;
        ops.scripted = was_s;
    }
    ops.run(i);
}

/// op_undo / op_redo: "  undo: <step>" or "  nothing to undo".
pub fn stepBack(back: bool) void {
    if (@import("cosync.zig").undoHook(!back)) return; // co-editing: the author's own (op_undo)
    // (an open group - the co-pilot's proposal - is one step still being made)
    if (undo.grouped()) return app.log("  undo / redo wait until the running script or agent request is done", .{});
    const l = if (back) undo.undo() else undo.redo();
    if (l) |s| app.log("  {s}: {s}", .{ if (back) "undo" else "redo", s }) else app.log("  nothing to {s}", .{if (back) "undo" else "redo"});
    app.dirty = true;
}

fn runNamed(id: []const u8, arg: []const u8) bool {
    const i = ops.byId(id) orelse return false;
    runOp(i, arg);
    return true;
}

fn dispatch(mark: *usize) void {
    const eq = std.mem.eql;
    if (eq(u8, tool, "scene_summary")) return sceneJson(&txt);
    if (eq(u8, tool, "create_primitive")) return toolCreate();
    if (eq(u8, tool, "set_transform")) return toolTransform();
    if (eq(u8, tool, "select")) return toolSelect();
    if (eq(u8, tool, "delete")) {
        scene.deselectAll();
        selectNames();
        _ = runNamed("object.delete", "");
        return txt.raw("ok");
    }
    if (eq(u8, tool, "run_operator")) return toolRun();
    if (eq(u8, tool, "undo")) {
        stepBack(true);
        return txt.raw("ok");
    }
    if (eq(u8, tool, "viewport_capture")) {
        var b: [16]u8 = undefined;
        const a = argStr("area", &b) orelse "";
        return capture(eq(u8, a, "window"));
    }
    if (eq(u8, tool, "script_eval")) return toolScript(mark);
    if (eq(u8, tool, "redo")) {
        stepBack(false);
        return txt.raw("ok");
    }
    if (eq(u8, tool, "ui_tree")) return uiTree(&txt);
    for (providers) |p| {
        if (p) |pv| {
            if (pv.dispatch(tool)) return;
        }
    }
    // op_<id>: every agent-safe operator's tool name
    var nb: [128]u8 = undefined;
    for (0..cat.entries.len) |i| {
        if (!flags.safe[i] or !eq(u8, tool, toolName(i, &nb))) continue;
        var ab: [512]u8 = undefined;
        runOp(i, argStr("arg", &ab) orelse "");
        txt.reset(); // (file writers use the text buffer too)
        return txt.raw("ok");
    }
    fail("unknown tool: ", tool);
}

fn missing() void {
    fail("missing argument", "");
}

fn toolCreate() void {
    var tb: [32]u8 = undefined;
    const ty = argStr("type", &tb) orelse "";
    if (ty.len == 0) return missing();
    var ib: [64]u8 = undefined;
    const id = std.fmt.bufPrint(&ib, "create.{s}", .{ty}) catch return missing();
    if (!runNamed(id, "")) return fail("unknown primitive type: ", ty);
    const a = scene.active orelse return; // the new object is the active one
    applyXform(a);
    var nb: [32]u8 = undefined;
    if (argStr("name", &nb)) |n| {
        if (n.len > 0) rename(a, n);
    }
    txt.raw(scene.objects[a].name()); // the object's final name
}

fn toolTransform() void {
    var nb: [32]u8 = undefined;
    const name = argStr("name", &nb) orelse "";
    if (name.len == 0) return missing();
    const i = objFind(name) orelse return fail("no object named ", name);
    applyXform(i);
    var rb: [32]u8 = undefined;
    if (argStr("new_name", &rb)) |n| {
        if (n.len > 0) rename(i, n);
    }
    txt.raw(scene.objects[i].name());
}

fn toolSelect() void {
    var extend = false;
    if (argVal("extend")) |v| extend = json.boolean(msg, v);
    if (!extend) scene.deselectAll();
    selectNames();
    txt.raw("ok");
}

fn toolRun() void {
    var b: [64]u8 = undefined;
    const id = argStr("id", &b) orelse "";
    if (id.len == 0) return missing();
    const i = ops.byId(id) orelse return fail("unknown or not agent-safe operator: ", id);
    if (!flags.safe[i]) return fail("unknown or not agent-safe operator: ", id);
    var ab: [512]u8 = undefined;
    runOp(i, argStr("arg", &ab) orelse "");
    txt.reset(); // (file writers use the text buffer too)
    txt.raw("ok");
}

fn toolScript(mark: *usize) void {
    const code = argStr("code", &script_buf) orelse "";
    if (code.len == 0) return missing();
    const bs = @import("bscript.zig");
    const failed = bs.eval(code, true) != 0; // (an agent: only agent-safe operators)
    txt.reset(); // (file writers use the text buffer too)
    const o = bs.output();
    txt.bytes(o); // its output, not the console copy
    mark.* = app.log_count;
    if (failed) {
        is_error = true;
        return;
    }
    if (o.len == 0) txt.raw("ok");
}
var script_buf: [65536]u8 = undefined;

/// obj_find: the object with exactly this name.
fn objFind(name: []const u8) ?usize {
    for (scene.objects[0..scene.count], 0..) |*o, i| {
        if (std.mem.eql(u8, o.name(), name)) return i;
    }
    return null;
}

/// obj_rename: unique as the original's unique_name ("Base" cut to 26
/// bytes, then "Base.001" ... up to .999).
pub fn rename(i: usize, want: []const u8) void {
    const o = &scene.objects[i];
    o.name_len = 0; // (its old name is free while checking)
    const base = want[0..@min(want.len, 26)];
    var buf: [32]u8 = undefined;
    var k: u32 = 0;
    var nm: []const u8 = base;
    while (k <= 999) : (k += 1) {
        nm = if (k == 0) base else std.fmt.bufPrint(&buf, "{s}.{d:0>3}", .{ base, k }) catch base;
        if (objFind(nm) == null) break;
    }
    var keep: [32]u8 = undefined;
    @memcpy(keep[0..nm.len], nm);
    o.name_buf = @splat(0);
    @memcpy(o.name_buf[0..nm.len], keep[0..nm.len]);
    o.name_len = @intCast(nm.len);
}

/// apply_xform: location / rotation_deg / scale arguments.
/// (The original's OB_LOC, OB_ROT, OB_SCALE are an object's world place, a
/// child's too: the port's place kept so, its own values following.)
fn applyXform(i: usize) void {
    var p = scene.worldPlace(i);
    const before = p;
    if (argVec("location")) |v| p[0..3].* = v;
    if (argVec("rotation_deg")) |v| {
        const k: f32 = 0.017453293;
        p[3..6].* = .{ v[0] * k, v[1] * k, v[2] * k };
    }
    if (argVec("scale")) |v| p[6..9].* = v;
    if (std.mem.eql(u32, &@as([9]u32, @bitCast(p)), &@as([9]u32, @bitCast(before)))) return;
    scene.setWorldPlace(i, p);
    app.dirty = true;
}

/// select_names: every object listed in arguments.names; the last found
/// becomes active.
fn selectNames() void {
    defer app.dirty = true;
    const v = argVal("names") orelse return;
    var e = json.first(msg, v);
    while (e) |el| : (e = json.next(msg, el)) {
        var b: [32]u8 = undefined;
        const n = json.str(msg, el, &b) orelse continue;
        const i = objFind(n) orelse continue;
        scene.objects[i].selected = true;
        scene.active = i;
    }
}

// ---- the scene as JSON (scene_json) -----------------------------------------------------

const rad2deg: f32 = 57.29578;

fn vecJson(w: *json.W, key: []const u8, v: [3]f32, k: f32) void {
    w.key(key);
    w.char('[');
    for (v, 0..) |x, c| {
        if (c > 0) w.char(',');
        w.num(if (k != 1) x * k else x);
    }
    w.char(']');
}

/// obj_type: the original's OB_TYPE names (a force field: "field", where the
/// original read past its table and crashed).
fn typeName(k: scene.Kind) []const u8 {
    return switch (k) {
        .light => "light",
        .camera => "camera",
        .sketch => "sketch",
        .armature => "armature",
        .field => "field",
        else => "mesh",
    };
}

/// The original keeps a small mesh on lights (an octahedron) and cameras (a
/// box): its counts.
fn meshCounts(i: usize) [2]u32 {
    const o = &scene.objects[i];
    if (scene.meshOfObj(i)) |me| return .{ @intCast(me.verts.len), me.faces() };
    return switch (o.kind) {
        .camera => .{ 8, 6 },
        .light, .field => .{ 6, 8 },
        else => .{ 0, 0 },
    };
}

/// obj_size: a mesh's size, its box as drawn (with its modifiers) times |scale|.
pub fn objSize(i: usize) ?[3]f32 {
    const o = &scene.objects[i];
    if (!o.kind.isMesh()) return null;
    const me = @import("mods.zig").of(i) orelse return null;
    if (me.verts.len == 0) return null;
    var lo = me.verts[0];
    var hi = me.verts[0];
    for (me.verts) |p| {
        for (0..3) |c| {
            lo[c] = @min(lo[c], p[c]);
            hi[c] = @max(hi[c], p[c]);
        }
    }
    const wp = scene.worldPlace(i);
    return .{ (hi[0] - lo[0]) * @abs(wp[6]), (hi[1] - lo[1]) * @abs(wp[7]), (hi[2] - lo[2]) * @abs(wp[8]) };
}

const mod_keys = [_][]const u8{ "", "mirror", "array", "solidify", "subsurf", "bevel", "decimate", "remesh", "boolean", "multires", "geometry", "armature", "logic" };
const tx_aligns = [_][]const u8{ "left", "center", "right" };
const tx_modes = [_][]const u8{ "pop", "scale", "rise", "drop" };
const plane_names = [_][]const u8{ "XY", "XZ", "YZ" };

/// obj_json: one object.
pub fn objJson(w: *json.W, i: usize) void {
    const o = &scene.objects[i];
    w.char('{');
    w.key("name");
    w.q(o.name());
    w.char(',');
    w.key("type");
    w.q(typeName(o.kind));
    const wp = scene.worldPlace(i); // (the original's OB_LOC, OB_ROT, OB_SCALE)
    w.char(',');
    vecJson(w, "location", wp[0..3].*, 1);
    w.char(',');
    vecJson(w, "rotation_deg", wp[3..6].*, rad2deg);
    w.char(',');
    vecJson(w, "scale", wp[6..9].*, 1);
    w.raw(",\"selected\":");
    w.raw(if (o.selected) "true" else "false");
    w.raw(",\"active\":");
    w.raw(if (scene.active != null and scene.active.? == i) "true" else "false");
    const mc = meshCounts(i);
    w.raw(",\"vertices\":");
    w.int(mc[0]);
    w.raw(",\"faces\":");
    w.int(mc[1]);
    if (objSize(i)) |s| {
        w.char(',');
        vecJson(w, "size", s, 1);
    }
    if (o.mods.n > 0) {
        w.raw(",\"modifiers\":[");
        for (o.mods.m[0..o.mods.n], 0..) |md, k| {
            if (k > 0) w.char(',');
            w.q(if (md.kind < mod_keys.len) mod_keys[md.kind] else "");
        }
        w.char(']');
    }
    if (o.sk) |sk| {
        w.raw(",\"sketch\":{\"plane\":");
        w.q(plane_names[@min(sk.plane, 2)]);
        w.raw(",\"points\":");
        w.int(sk.npt);
        w.raw(",\"entities\":");
        w.int(sk.nent);
        w.raw(",\"constraints\":");
        w.int(sk.ncon);
        w.raw(",\"dof\":");
        w.int(sk.dof);
        w.raw(",\"conflicts\":");
        w.int(sk.nbad);
        w.char('}');
    }
    if (o.kind.isMesh()) {
        if (@import("text3d.zig").txOf(i)) |tb| txJson(w, tb);
    }
    if (o.mat > 0 and o.mat - 1 < material.count) {
        w.raw(",\"material\":");
        w.q(material.list[o.mat - 1].nameOf());
    }
    w.char('}');
}

/// tx_json: ,"text":{...} (text3d.s).
fn txJson(w: *json.W, b: *const @import("text3d.zig").Block) void {
    const t3 = @import("text3d.zig");
    w.raw(",\"text\":{");
    w.key("body");
    w.q(b.bodyText());
    w.char(',');
    w.key("font");
    w.q(if (b.fontName().len > 0) b.fontName() else "default");
    w.char(',');
    w.key("align");
    w.q(tx_aligns[if (b.alignment < 3) b.alignment else 0]);
    w.char(',');
    w.key("mode");
    w.q(tx_modes[b.rmode & 3]);
    for (t3.tx_fkeys, 0..) |k, c| {
        w.char(',');
        w.key(k);
        w.num(b.f[c]);
    }
    w.char('}');
}

/// mats_json: closes the objects and writes the materials, images, the world,
/// the units, the parameters and the features.
fn matsJson(w: *json.W) void {
    const env = @import("env.zig");
    const cad = @import("cad.zig");
    const feature = @import("feature.zig");
    w.raw("],\"materials\":[");
    for (material.list[0..material.count], 0..) |*ma, mi| {
        if (mi > 0) w.char(',');
        w.char('{');
        w.key("name");
        w.q(ma.nameOf());
        for (material.params, 0..) |p, k| {
            w.char(',');
            w.key(p.name);
            if (p.comps == 3) {
                w.char('[');
                for (0..3) |c| {
                    if (c > 0) w.char(',');
                    w.num(material.ptr(ma, k, c).*);
                }
                w.char(']');
            } else w.num(material.ptr(ma, k, 0).*);
        }
        @import("mcpmat.zig").graphJson(w, ma);
        w.char('}');
    }
    w.raw("],\"images\":[");
    for (0..images.count) |k| {
        if (k > 0) w.char(',');
        w.q(images.nameOf(k));
    }
    w.raw("],\"world\":{\"hdri\":");
    if (env.idx -% 1 < images.count) w.q(images.nameOf(env.idx - 1)) else w.raw("null");
    w.char(',');
    w.key("strength");
    w.num(env.strength);
    w.char(',');
    w.key("rotation");
    w.num(env.rotation * rad2deg);
    w.char('}');
    w.raw(",\"units\":");
    w.q(cad.unitName() orelse "custom");
    w.raw(",\"parameters\":[");
    for (0..cad.paramCount()) |k| {
        if (k > 0) w.char(',');
        w.char('{');
        w.key("name");
        w.q(cad.paramName(k));
        w.char(',');
        w.key("expression");
        w.q(cad.paramExpr(k));
        w.char(',');
        w.key("value");
        w.num(@floatCast(cad.paramValue(k) orelse 0));
        w.char('}');
    }
    w.char(']');
    w.raw(",\"features\":[");
    for (0..feature.count()) |k| {
        if (k > 0) w.char(',');
        w.char('{');
        w.key("type");
        const r = feature.rec(k);
        w.q(feature.typeName(feature.get(r, feature.FT_TYPE)));
        if (featureBody(k)) |bi| {
            w.char(',');
            w.key("body");
            w.q(scene.objects[bi].name());
        }
        w.char(',');
        w.key("status");
        w.q(feature.statusName(feature.status(k)));
        w.char('}');
    }
    w.char(']');
}

/// A feature's body (its record holds the object's oid, or a raw uid none has).
fn featureBody(k: usize) ?usize {
    const cad = @import("cad.zig");
    const feature = @import("feature.zig");
    const b = cad.cur orelse return null;
    const v = feature.get(feature.rec(k), feature.FT_BODY);
    if (v == 0) return null;
    if (b.fraw[k] & 1 != 0) return scene.findUid(v);
    return scene.findOid(v);
}

/// scene_json: the scene as JSON.
pub fn sceneJson(w: *json.W) void {
    w.raw("{\"units\":\"meters, Y up, rotation_deg = Euler XYZ\",\"objects\":[");
    for (0..scene.count) |i| {
        if (i > 0) w.char(',');
        objJson(w, i);
    }
    matsJson(w);
    w.char('}');
}

// ---- ui_tree -------------------------------------------------------------------------

/// The widgets of the last frame (the port's records: kind, label, rectangle,
/// enabled), in the form the original's ui_tree has.
fn uiTree(w: *json.W) void {
    const ui = @import("ui.zig");
    w.raw("{\"widgets\":[");
    for (ui.rec[0..ui.rec_n], 0..) |*e, k| {
        if (k > 0) w.char(',');
        w.char('{');
        w.key("name");
        w.q(e.label[0..e.len]);
        w.raw(",\"sub\":0,\"kind\":");
        w.q(e.kind);
        w.raw(",\"x\":");
        w.int(e.r.x);
        w.raw(",\"y\":");
        w.int(e.r.y);
        w.raw(",\"w\":");
        w.int(e.r.w);
        w.raw(",\"h\":");
        w.int(e.r.h);
        w.raw(",\"label\":");
        w.q(e.label[0..e.len]);
        w.raw(",\"value\":null");
        if (!e.enabled) w.raw(",\"enabled\":false");
        w.char('}');
    }
    w.raw("]}");
}

// ---- viewport_capture ------------------------------------------------------------------

/// capture: the UI drawn off screen, cropped to the viewport (or the whole
/// window) and encoded as a PNG; described in the text.
fn capture(whole: bool) void {
    const gfx = @import("gfx.zig");
    const sc = @import("scale.zig");
    const A = std.heap.page_allocator;
    const win = app.win orelse return missing();
    _ = sc.apply();
    const pw = sc.px(win.width);
    const ph = sc.px(win.height);
    if (pw <= 0 or ph <= 0) return missing();
    const n: usize = @intCast(pw * ph);
    const px = A.alloc(u32, n) catch return missing();
    defer A.free(px);
    const zb = A.alloc(f32, n) catch return missing();
    defer A.free(zb);
    const ids = A.alloc(u16, n) catch return missing();
    defer A.free(ids);
    @memset(ids, 0);
    var cv = gfx.Canvas{ .px = px.ptr, .w = pw, .h = ph, .clip = .{ .w = sc.units(pw), .h = sc.units(ph) }, .zbuf = zb.ptr, .ids = ids.ptr, .s = sc.q16(), .uw = sc.units(pw), .uh = sc.units(ph) };
    app.frame(&cv);
    var x0: i32 = 0;
    var y0: i32 = 0;
    var x1: i32 = pw;
    var y1: i32 = ph;
    if (!whole) {
        const va = app.viewportArea();
        if (va >= 0) {
            const r = app.N(va).rect;
            x0 = sc.px(r.x);
            y0 = sc.px(r.y + app.HDR_H);
            x1 = sc.px(r.x + r.w);
            y1 = sc.px(r.y + r.h);
        }
    }
    x0 = std.math.clamp(x0, 0, pw);
    x1 = std.math.clamp(x1, 0, pw);
    y0 = std.math.clamp(y0, 0, ph);
    y1 = std.math.clamp(y1, 0, ph);
    const cw = x1 - x0;
    const ch = y1 - y0;
    if (cw <= 0 or ch <= 0) return missing();
    const crop = A.alloc(u32, @intCast(cw * ch)) catch return missing();
    defer A.free(crop);
    for (0..@intCast(ch)) |y| {
        const src: usize = @intCast((y0 + @as(i32, @intCast(y))) * pw + x0);
        @memcpy(crop[y * @as(usize, @intCast(cw)) ..][0..@intCast(cw)], px[src..][0..@intCast(cw)]);
    }
    const png = @import("png.zig").encode(A, @intCast(cw), @intCast(ch), crop) catch return missing();
    if (img.len > 0) A.free(img);
    img = png;
    has_image = true;
    var b: [64]u8 = undefined;
    txt.raw(std.fmt.bufPrint(&b, "PNG capture {d} x {d} px", .{ cw, ch }) catch "PNG capture");
}

// ---- beemodel --mcp-bridge ---------------------------------------------------------------

/// mcp_bridge: stdin/stdout <-> the app's socket ($BEEMODEL_SOCKET, or
/// $XDG_RUNTIME_DIR/beemodel.sock), waiting up to 5 s for the app. At the end
/// of stdin the socket's writing side closes and the answers still coming are
/// relayed to their end (the original stopped at once and dropped them).
pub fn bridge(xdg: ?[]const u8, sock_env: ?[]const u8) u8 {
    var path: [120]u8 = undefined;
    var n: usize = 0;
    if (sock_env != null and sock_env.?.len > 0) {
        n = cat0(&path, 0, sock_env.?);
    } else n = cat0(&path, runtimeDir(&path, xdg), "/beemodel.sock");
    if (n == 0 or n > 107 or n >= path.len or (sock_env == null or sock_env.?.len == 0) and !std.mem.endsWith(u8, path[0..n], "/beemodel.sock")) {
        const e = "beemodel: the socket path is too long ($XDG_RUNTIME_DIR or BEEMODEL_SOCKET)\n";
        _ = linux.write(2, e, e.len);
        return 1;
    }
    var fd: i32 = -1;
    var tries: u32 = 50;
    while (true) {
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) == .SUCCESS) {
            fd = @intCast(rc);
            const a = sockaddr(path[0..n]);
            if (linux.errno(linux.connect(fd, @ptrCast(&a), 110)) == .SUCCESS) break;
            _ = linux.close(fd);
            fd = -1;
        }
        tries -= 1;
        if (tries == 0) {
            const e = "beemodel: no running BeeModel to bridge to (start it first)\n";
            _ = linux.write(2, e, e.len);
            return 1;
        }
        const ts = linux.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = linux.nanosleep(&ts, null);
    }
    var stdin_open = true;
    var buf: [65536]u8 = undefined;
    while (true) {
        var pf = [2]linux.pollfd{
            .{ .fd = if (stdin_open) 0 else -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        };
        const pr = linux.poll(&pf, 2, -1);
        if (linux.errno(pr) == .INTR) continue;
        if (stdin_open and pf[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
            if (!relay(0, fd, &buf)) {
                stdin_open = false;
                _ = linux.shutdown(fd, linux.SHUT.WR);
            }
        }
        if (pf[1].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
            if (!relay(fd, 1, &buf)) return 0;
        }
    }
}

/// relay: false at the end of the stream (or an error).
fn relay(from: i32, to: i32, buf: []u8) bool {
    const rc = linux.read(from, buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
    var d = buf[0..rc];
    while (d.len > 0) {
        const w = linux.write(to, d.ptr, d.len);
        switch (linux.errno(w)) {
            .SUCCESS => d = d[w..],
            .INTR => {},
            else => return false,
        }
    }
    return true;
}

// ---- tests ---------------------------------------------------------------------------

fn catIndex(id: []const u8) usize {
    for (cat.entries, 0..) |e, i| {
        if (std.mem.eql(u8, e.id, id)) return i;
    }
    unreachable;
}

test "tool names and the agent-safe list" {
    var nb: [128]u8 = undefined;
    const i = catIndex("view.toggle_grid");
    try std.testing.expectEqualStrings("op_view_toggle_grid", toolName(i, &nb));
    try std.testing.expect(flags.safe[i]);
    try std.testing.expect(!flags.safe[catIndex("file.exit")]);
    try std.testing.expect(flags.quiet[catIndex("edit.undo")]);
    var n: usize = 0;
    for (cat.entries, 0..) |e, k| {
        if (flags.safe[k] and !e.hidden) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 557), n); // the original's tools/list, + view.camera_selected
}
