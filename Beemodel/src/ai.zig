// The AI Assistant (the original's ai.s): a conversation with an AI that
// builds in the scene through BeeModel's own tools.
//
// Connections (Preferences > AI):
//   - Claude Code and the Grok CLI run as a child process (aiproc.zig) with
//     an MCP configuration naming "beemodel --mcp-bridge" for this instance's
//     socket; their stream of JSON lines (the same shape for both) comes into
//     the transcript; the session id is kept for follow-ups.
//   - OpenRouter (or any OpenAI-compatible server, Ollama on this machine):
//     chat completions through curl, with the curated MCP tools as
//     functions; the tool calls are run here, in-process (mcp.local), and the
//     results sent back until the model answers or the step limit is reached.
//
// A request is one undo step ("Agent: ..."), revertable in one click. The AI
// Assistant area: the connection, New Conversation, Revert, the transcript,
// the prompt (Enter sends; Shift+Enter, or a paste, makes it several lines,
// and it grows to show them) with Send / Stop. Ctrl+Shift+Space (ai.mode)
// goes to the prompt, making the AI workspace when no AI Assistant is shown.
const std = @import("std");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const json = @import("json.zig");
const ops = @import("ops.zig");
const undo = @import("undo.zig");
const proc = @import("aiproc.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");
const menus = @import("menus.zig");

const Rect = gfx.Rect;
const Impl = ops.Impl;

const TX_CAP = 65536; // the transcript (entries: kind, text, 0)
const LINE_CAP = 262144; // a CLI's line being read
const REPLY_CAP = 4194304; // curl's reply
const TMP_CAP = 65536;
pub const K_YOU = 1;
pub const K_AI = 2;
pub const K_TOOL = 3;
pub const K_ERR = 4;
pub const K_RES = 5;
pub const K_NOTE = 6;
const LINE_H = 20;
const WRAP_H = 17; // (wrap_text's own line step: tooltip.s LINE_H)
const PROMPT_MAXL = 10;
const LOG_LINE = 95; // (the original's console lines)

// ---- the preferences (prefs.s) -----------------------------------------------------

pub const Str = struct {
    b: [256]u8 = @splat(0),
    n: usize = 0,
    pub fn s(x: *const Str) []const u8 {
        return x.b[0..x.n];
    }
    pub fn z(x: *const Str) [*:0]const u8 {
        return x.b[0..x.n :0].ptr;
    }
    pub fn set(x: *Str, v: []const u8) void {
        const k = @min(v.len, 255);
        @memcpy(x.b[0..k], v[0..k]);
        x.b[k] = 0;
        x.n = k;
    }
};

fn initStr(comptime v: []const u8) Str {
    var x = Str{};
    @memcpy(x.b[0..v.len], v);
    x.n = v.len;
    return x;
}

/// The connection: 0 Claude Code, 1 the Grok CLI, 2 OpenRouter, 3 Ollama.
pub var prov: i32 = 0;
pub var cl_turns: i32 = 100;
pub var gk_turns: i32 = 100;
pub var or_steps: i32 = 30;
pub var ol_steps: i32 = 30;
pub var or_url: Str = initStr("https://openrouter.ai/api/v1");
pub var or_model: Str = initStr("anthropic/claude-sonnet-4.5");
pub var ol_url: Str = initStr("http://localhost:11434/v1");
pub var ol_model: Str = initStr("qwen3.5:4b");
/// Programs (empty: on PATH), models (empty: the CLI's own), the key.
pub var cl_path: Str = .{};
pub var cl_model: Str = .{};
pub var gk_path: Str = .{};
pub var gk_model: Str = .{};
pub var or_key: Str = .{};
/// Added to the system prompt.
pub var extra: Str = .{};

const pref_ints = .{ .{ "ai_connection", &prov }, .{ "claude_turns", &cl_turns }, .{ "grok_turns", &gk_turns }, .{ "openrouter_steps", &or_steps }, .{ "ollama_steps", &ol_steps } };
const pref_strs = .{ .{ "claude_path", &cl_path }, .{ "claude_model", &cl_model }, .{ "grok_path", &gk_path }, .{ "grok_model", &gk_model }, .{ "openrouter_url", &or_url }, .{ "openrouter_model", &or_model }, .{ "ai_prompt", &extra }, .{ "ollama_url", &ol_url }, .{ "ollama_model", &ol_model } };

/// A preferences line of ours (the original's words): true when it was one.
pub fn loadPref(k: []const u8, v: []const u8) bool {
    inline for (pref_ints) |p| {
        if (std.mem.eql(u8, k, p[0])) {
            p[1].* = std.fmt.parseInt(i32, std.mem.trim(u8, v, " "), 10) catch 0;
            return true;
        }
    }
    inline for (pref_strs) |p| {
        if (std.mem.eql(u8, k, p[0])) {
            p[1].set(v);
            return true;
        }
    }
    if (std.mem.eql(u8, k, "ai_only_selection")) {
        @import("aiask.zig").scope = (std.fmt.parseInt(i32, std.mem.trim(u8, v, " "), 10) catch 0) != 0;
        return true;
    }
    return false;
}

pub fn writePrefs(out: []u8, w: *usize) void {
    // (and the agents' two, which Preferences > AI sets)
    const ag = @import("agent.zig");
    const s0 = std.fmt.bufPrint(out[w.*..], "agent_permission {d}\nmcp {d}\n", .{ ag.pr_tier, ag.pr_mcp }) catch return;
    w.* += s0.len;
    inline for (pref_ints) |p| {
        const s = std.fmt.bufPrint(out[w.*..], "{s} {d}\n", .{ p[0], p[1].* }) catch return;
        w.* += s.len;
    }
    const sc = std.fmt.bufPrint(out[w.*..], "ai_only_selection {d}\n", .{@intFromBool(@import("aiask.zig").scope)}) catch return;
    w.* += sc.len;
    inline for (pref_strs) |p| {
        const s = std.fmt.bufPrint(out[w.*..], "{s} {s}\n", .{ p[0], p[1].s() }) catch return;
        w.* += s.len;
    }
}

/// Preferences > AI > Reset to Defaults (pf_defs: the numbers).
pub fn resetPrefs() void {
    prov = 0;
    cl_turns = 100;
    gk_turns = 100;
    or_steps = 30;
    ol_steps = 30;
    @import("aiask.zig").scope = true;
}

// ---- the secrets: the key, in a file of its own (0600), never in prefs -------------

var sec_path: [300]u8 = undefined;
var sec_len: usize = 0;

/// sec_load: ~/.config/beemodel-zig/secrets ("openrouter_key <key>").
pub fn secretsInit(home: ?[]const u8) void {
    const h = home orelse return;
    const p = std.fmt.bufPrint(&sec_path, "{s}/.config/beemodel-zig/secrets", .{h}) catch return;
    sec_len = p.len;
    var b: [4096]u8 = undefined;
    const data = readFile(p, &b) orelse return;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const sp = std.mem.indexOfScalar(u8, ln, ' ') orelse continue;
        if (std.mem.eql(u8, ln[0..sp], "openrouter_key")) or_key.set(ln[sp + 1 ..]);
    }
}

fn readFile(path: []const u8, b: []u8) ?[]const u8 {
    const linux = std.os.linux;
    var pz: [320]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&pz, "{s}", .{path}, 0) catch return null;
    const o = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(o) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(o));
    var n: usize = 0;
    while (n < b.len) {
        const r = linux.read(@intCast(o), b[n..].ptr, b.len - n);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    return b[0..n];
}

/// sec_save: the key, to the secrets file only (owner only).
pub fn secretsSave() void {
    if (sec_len == 0) return;
    const p = sec_path[0..sec_len];
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |sl| _ = @import("spawn.zig").ensureDir(p[0..sl]);
    var b: [300]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "openrouter_key {s}\n", .{or_key.s()}) catch return;
    _ = proc.writePrivate(p, s);
}

// ---- state ---------------------------------------------------------------------------

pub var tx: [TX_CAP]u8 = undefined;
pub var tx_len: u32 = 0;
/// A request runs.
pub var busy = false;
/// Its connection (0 1 2; 3 a test).
var run: u32 = 0;
/// OpenRouter's way, to Ollama on this machine.
var local = false;
var test_which: u32 = 0;
var stopped = false;
var grouped = false;
/// Start typing in the prompt (ai.mode).
var focus = false;
var sid_prov: u32 = 0; // the connection sid is for, + 1
var or_n: i32 = 0;
var iserr = false;
var req_off: u32 = 0;
var line: [LINE_CAP]u8 = undefined;
var line_len: usize = 0;
var line_skip = false;
var reply: [REPLY_CAP]u8 = undefined;
var reply_len: usize = 0;
var tmp: [TMP_CAP]u8 = undefined;
var tmp_len: usize = 0;
var args: [TMP_CAP]u8 = undefined;
var args_len: usize = 0;
var sys: [16384]u8 = undefined;
var sys_len: usize = 0;
var sid: [128]u8 = @splat(0);
var sid_len: usize = 0;
/// "Agent: <the prompt>": the request's undo step.
pub var label: [112]u8 = @splat(0);
pub var label_len: usize = 0;
/// The prompt field's text.
pub var prompt: [4000]u8 = undefined;
pub var prompt_len: usize = 0;
var prog_path: [512]u8 = undefined;
var cfg: [600]u8 = undefined;
var hdr: [600]u8 = undefined;
var hdr_len: usize = 0;
var url: [600]u8 = undefined;
var url_len: usize = 0;
var turns: [16]u8 = undefined;
var name: [128]u8 = undefined;
var name_len: usize = 0;
var cid: [128]u8 = undefined;
var cid_len: usize = 0;
var hist: json.W = .{}; // OpenRouter: the messages
var rbody: json.W = .{}; //  a request's body
var tools: json.W = .{}; //  the tools as functions
var req: json.W = .{}; //  a tool call for mcp.local; the configuration files
var sent: json.W = .{}; // the text sent (0-ended, for the command line)
var argv: [48:null]?[*:0]const u8 = @splat(null);

const prov_names = [4][]const u8{ "Claude Code", "Grok", "OpenRouter", "Ollama" };

fn dirty() void {
    app.dirty = true;
}

/// log_line: a console line (95 bytes of it, as the original's) and a
/// toast of it (toast_note: without its leading spaces).
fn logLine(s: []const u8) void {
    app.toastLine(.ok, s[0..@min(s.len, LOG_LINE)]);
}

// ---- texts -----------------------------------------------------------------------------

const s_strip = "mcp__beemodel__";
const s_busy = "  the AI is still working (Stop ends it)";
const s_stopped = "Stopped.";
const s_not_found_a = " was not found: install it, or set its program in Preferences > AI.";
const s_no_start = "The program could not be started.";
const s_no_mcp = "BeeModel's MCP server is off (Preferences > AI): Claude Code and Grok reach the scene through it.";
const s_ended_a = " ended with exit code ";
const s_no_key = "No OpenRouter key: set it in Preferences > AI (or OPENROUTER_API_KEY).";
const s_no_curl = "OpenRouter needs the curl program (it is not on PATH).";
const s_or_fail = "The request to OpenRouter failed: ";
const s_or_bad = "OpenRouter's reply was not understood: ";
const s_or_none = "OpenRouter gave no answer.";
const s_or_err = "OpenRouter: ";
const s_ol_fail = "The request to Ollama failed (is it running? ollama serve): ";
const s_ol_bad = "Ollama's reply was not understood: ";
const s_ol_none = "Ollama gave no answer.";
const s_ol_err = "Ollama: ";
const s_hint = "Describe a world, a model or a change, and press Enter. The AI builds it in the scene; each request is one undo step.";
const s_prompt_hint = "Describe what to build...";
const s_too_long = "  (a message too long to show, such as an image, was left out)";
const s_nothing_rev = "  nothing of the AI's to revert";
const s_copied = "  the AI conversation is on the clipboard";
const s_nothing_copy = "  the AI conversation is empty";
const s_test_none = ": not found (install it, or set its program in Preferences > AI)";
const s_test_ok_key = "  OpenRouter: the key works";
const s_test_bad = "  OpenRouter: ";
const s_test_bad_ol = "  Ollama: ";
const s_test_ok_ol = "  Ollama: it answers and has the model";
const s_test_nomodel = "it answers, but has no model named ";
const s_test_noans = "no answer (check the address)";
const gk_deny = "run_terminal_command,search_replace,write,read_file,list_dir,grep,kill_command_or_subagent,spawn_subagent,scheduler_create,scheduler_delete,workflow,image_gen,monitor";

/// The world-building instructions (also MCP's prompt build_world).
pub const s_world = "You are the AI inside BeeModel, a 3D modeler, renderer and CAD program. You build what the user describes directly in the open scene with BeeModel's tools while they watch the viewport.\n" ++
    "Conventions: meters; Y is up; the ground is the XZ plane at y = 0; rotation_deg is Euler XYZ in degrees (BeeScript's rotate takes radians: write 45deg).\n" ++
    "Work like this:\n" ++
    "1. Look first: scene_summary (and viewport_capture when it matters).\n" ++
    "2. Plan briefly: the parts, their sizes and places. A new scene holds a placeholder Cube (2 m, at the origin): when you build something new and the request does not mention the cube, delete(\"Cube\") first and say so. Never build into objects that stay: put new things beside them.\n" ++
    "3. Build in batches with script_eval (BeeScript), many objects a call: add(type, name, x, y, z) with cube, sphere, cylinder, cone, torus, plane, grid, light or camera; scale(n, x, y, z); rotate(n, rx, ry, rz); move(n, x, y, z); for i in 0..10 { ... } loops; fn name(a, b) { ... } helpers. There are no lists or arrays ([...]): write each call, or loop over numbers. Materials: m = material(\"Stone\"); matset(m, \"base\", 0.5, 0.5, 0.48); matset(m, \"roughness\", 0.8); assign(object, m); a preset look: m = material(\"Planks\"); op(\"material.preset\", \"wood Planks\") (gold silver copper chrome aluminium plastic rubber glass frosted_glass water ceramic car_paint skin clay emissive wood marble concrete fabric leather). add returns the name it gave (Cube.001 when Cube is taken): keep it.\n" ++
    "4. Terrain and many copies with geometry nodes: t = gtree(\"Land\"); n = gnode(t, \"terrain\", 60, 128, 6, 1) (size, resolution, height, seed); o = gnode(t, \"output\"); glink(t, n, o, 1); add(\"plane\", \"Ground\"); k = modifier(\"Ground\", \"geometry\"); modset(\"Ground\", k, \"tree\", t). The distribute and instance nodes scatter objects; lsystem nodes grow plants (node_types lists them all).\n" ++
    "Text (titles, signs, labels, counters) is real geometry: op(\"text.add\", \"'Hello world' size 0.5 depth 0.1\"); t = active(); move(t, 0, 1, 0). It stands in the XY plane read from +Z, the last line's baseline at its origin, centred (\\n starts a line). Change it: text_set(t, \"New words\") or, on the active text, op(\"text.set\", \"'New words' font 'DejaVu Serif Bold' bevel 0.01 align left\"); text(t) reads it, scene_summary shows it. Type it on letter by letter: op(\"anim.key\", \"text:Name:reveal 1 0\") and (\"text:Name:reveal 48 1\") (mode pop, scale, rise or drop); {frame} or {floor(time)} in the body counts.\n" ++
    "5. Light and camera: add(\"light\", \"Sun\", 4, 8, 3) then op(\"light.set\", \"power 3\"); c = add(\"camera\", \"Shot\", 0, 2, 12), aim it with rotate(c, -10deg, 0, 0), then op(\"camera.set\", \"active\") (the new object is the active one). With an HDRI image loaded (image(path)), op(\"world.hdri\", name) and op(\"world.strength\", 1.5) light the world.\n" ++
    "6. Check: viewport_capture, then fix what is wrong. Keep to a few thousand objects; use instances and node trees for many copies.\n" ++
    "Each request of the user is one undo step they can revert in one click. Answer briefly: what you built and what they could ask for next.";
const s_world_extra = "\n\nThe user also asks: ";
const s_world_grok = "\nYour BeeModel tools come from the MCP server named beemodel. Always call them by their full names: beemodel__scene_summary, beemodel__script_eval, beemodel__viewport_capture, beemodel__run_operator and so on (the names above are short for these; with use_tool, pass the full name). " ++
    "A tool call that fails says why in its error: read it and correct the call. It does not mean BeeModel disconnected, so never stop or tell the user it is disconnected because of one; try again with the right name or values.\n";

// =============================================================================
// The transcript
// =============================================================================

const spaces = "               "; // (15)

fn cut0(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

/// ai_room: make room in the transcript (the oldest half goes).
fn room(n: usize) void {
    if (tx_len + n < TX_CAP) return;
    view_reset = true; // (the text moves: no selection)
    rev += 1;
    var c: u32 = TX_CAP / 2;
    while (c < tx_len and tx[c - 1] != 0) c += 1;
    if (tx_len > c) {
        const d = tx_len - c;
        req_off = if (req_off >= c) req_off - c else 0;
        std.mem.copyForwards(u8, tx[0..d], tx[c..tx_len]);
        tx_len = d;
    } else {
        tx_len = 0;
        req_off = 0;
    }
}

/// ai_add(kind, prefix or null, text, bytes at most): one entry a line (empty
/// lines skipped); the first line gets the prefix, the others as many spaces.
/// (The original read on past its limit when the limit fell on a line break:
/// here the limit holds.)
pub fn add(kind: u8, prefix0: ?[]const u8, text0: []const u8, max: usize) void {
    var prefix = prefix0;
    const indent: ?[]const u8 = if (prefix0) |p| spaces[15 - @min(p.len, 15) ..] else null;
    const t = cut0(text0);
    var at: usize = 0;
    var left = max;
    while (left > 0 and at < t.len) {
        var n: usize = 0;
        while (n < left and at + n < t.len and t[at + n] != 10) n += 1;
        if (n > 0 or prefix != null) {
            room(n + 40);
            var o: usize = tx_len;
            tx[o] = kind;
            o += 1;
            const pre = prefix orelse indent orelse "";
            @memcpy(tx[o .. o + pre.len], pre);
            o += pre.len;
            for (t[at .. at + @min(n, 2000)]) |c0| {
                tx[o] = if (c0 == 13 or c0 == 9) ' ' else c0;
                o += 1;
            }
            tx[o] = 0;
            tx_len = @intCast(o + 1);
            prefix = null;
        }
        at += n;
        left -= n;
        if (left > 0 and at < t.len and t[at] == 10) {
            at += 1;
            left -= 1;
        }
    }
    rev += 1;
    dirty();
}

/// ai_add_z: a short note, all of it.
fn addZ(kind: u8, s: []const u8) void {
    add(kind, null, s, std.math.maxInt(usize));
}

/// ai_note: a note in the transcript (Ask AI's).
pub fn note(s: []const u8) void {
    addZ(K_NOTE, s);
}

fn entryText(o: u32) []const u8 {
    return std.mem.sliceTo(tx[o + 1 .. tx_len], 0);
}

/// ai_answer: the last request's answer: the first line of the AI's last
/// message, or its last error (err), or null.
pub fn answer() ?struct { text: []const u8, err: bool } {
    var o = req_off;
    var a: ?[]const u8 = null;
    var err = false;
    var prev: u8 = 0;
    while (o < tx_len) {
        const k = tx[o];
        const t = entryText(o);
        if (k == K_ERR) {
            a = t;
            err = true;
        } else if (k == K_AI and prev != K_AI and !err) a = t;
        prev = k;
        o += @intCast(t.len + 2);
    }
    return if (a) |x| .{ .text = x, .err = err } else null;
}

/// ai_add_tool: "  name {arguments}", BeeModel's MCP prefix taken off the name
/// (200 bytes of the arguments, then ...).
fn addTool(nm0: []const u8, a: []const u8) void {
    var nm = nm0;
    if (std.mem.startsWith(u8, nm, s_strip)) nm = nm[s_strip.len..];
    var b: [400]u8 = undefined;
    var n: usize = 0;
    b[0] = ' ';
    b[1] = ' ';
    n = 2;
    const k = @min(nm.len, 120);
    @memcpy(b[n .. n + k], nm[0..k]);
    n += k;
    b[n] = ' ';
    n += 1;
    for (a[0..@min(a.len, 200)]) |c| {
        b[n] = if (c == 10) ' ' else c;
        n += 1;
    }
    if (a.len > 200) {
        @memcpy(b[n .. n + 3], "...");
        n += 3;
    }
    addZ(K_TOOL, b[0..n]);
}

// =============================================================================
// A request
// =============================================================================

fn trimLead(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] != 0 and s[i] <= ' ') i += 1;
    return cut0(s[i..]);
}

/// ai_send: a prompt, to the connection chosen.
pub fn send(p: []const u8) void {
    sendAs(p, p, null);
}

/// ai_send_as(prompt shown, text sent, a note after it or null): the same,
/// with more sent than the transcript shows (Ask AI: the selection).
pub fn sendAs(shown0: []const u8, sent0: []const u8, note_: ?[]const u8) void {
    const shown = trimLead(shown0);
    if (shown.len == 0) return;
    const st = trimLead(sent0);
    if (busy or proc.running()) return logLine(s_busy);
    add(K_YOU, "> ", shown, std.math.maxInt(usize));
    req_off = tx_len;
    if (note_) |n| addZ(K_NOTE, n);
    // one undo step: "Agent: <the prompt>" (one line, 60 bytes of it)
    @memcpy(label[0..7], "Agent: ");
    var n: usize = 0;
    while (n < shown.len and n < 60) : (n += 1) label[7 + n] = if (shown[n] < ' ') ' ' else shown[n];
    label_len = 7 + n;
    undo.groupBegin();
    grouped = true;
    busy = true;
    stopped = false;
    dirty();
    var p: u32 = if (prov >= 0 and prov <= 3) @intCast(prov) else 0;
    local = p == 3; // Ollama: OpenRouter's way, to the local server
    if (local) p = 2;
    run = p;
    sysFor(p);
    sent.reset();
    sent.bytes(st);
    sent.char(0);
    const ok = if (p != 2) cliStart(p, sent.items()[0 .. sent.len() - 1]) else orStart(st);
    if (!ok) finish(); // (it did not start)
}

/// ai_finish: the request is over: its undo step closed (and, from Ask AI,
/// checked for changes outside the selection).
fn finish() void {
    if (grouped) {
        grouped = false;
        _ = undo.groupEnd(label[0..label_len]);
    }
    busy = false;
    dirty();
    @import("aiask.zig").done();
}

fn sysCat(s: []const u8) void {
    const n = @min(s.len, sys.len - 1 - sys_len);
    @memcpy(sys[sys_len .. sys_len + n], s[0..n]);
    sys_len += n;
    sys[sys_len] = 0;
}

/// ai_sys_for: the instructions for that agent (Grok calls MCP tools by their
/// server-qualified names, and must not take a failed call for a lost
/// connection); ai_sys_make: the world instructions + the user's addition.
fn sysFor(p: u32) void {
    sys_len = 0;
    sysCat(s_world);
    if (p == 1) sysCat(s_world_grok);
    if (extra.n > 0) {
        sysCat(s_world_extra);
        sysCat(extra.s());
    }
}

/// ai_world_get: MCP's prompts/get build_world (the goal, if any, after the
/// instructions).
pub fn worldGet(w: *json.W, goal: []const u8) void {
    sysFor(0);
    if (goal.len > 0) {
        sysCat("\n\nWhat to build: ");
        sysCat(goal);
    }
    w.raw("{\"description\":\"Build a world\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":");
    w.q(sys[0..sys_len]);
    w.raw("}}]}");
}

fn mcpWorld(w: *json.W, goal: []const u8) void {
    worldGet(w, goal);
}

/// ai_prog(0 Claude Code / 1 Grok, to the transcript): the program's path, or
/// null (said in the transcript, or in the console for a test).
fn prog(which: u32, to_tx: bool) ?[:0]const u8 {
    const pref = if (which == 0) &cl_path else &gk_path;
    const nm: []const u8 = if (pref.n > 0) pref.s() else if (which == 0) "claude" else "grok";
    if (proc.which(nm)) |p| {
        @memcpy(prog_path[0..p.len], p);
        prog_path[p.len] = 0;
        return prog_path[0..p.len :0];
    }
    var b: [200]u8 = undefined;
    if (!to_tx) {
        testSay(std.fmt.bufPrint(&b, "  {s}{s}", .{ prov_names[which], s_test_none }) catch "");
    } else addZ(K_ERR, std.fmt.bufPrint(&b, "{s}{s}", .{ prov_names[which], s_not_found_a }) catch "");
    return null;
}

// =============================================================================
// Claude Code and the Grok CLI
// =============================================================================

/// ai_cli_start(0 Claude Code / 1 Grok, prompt): true when it started.
fn cliStart(which: u32, p: []const u8) bool {
    if (!@import("mcp.zig").listening()) {
        addZ(K_ERR, s_no_mcp);
        return false;
    }
    const pp = prog(which, true) orelse return false;
    proc.dirMake();
    cfgWrite(which);
    var k: usize = 0;
    const A = struct {
        fn arg(av: *[48:null]?[*:0]const u8, kk: *usize, s: [*:0]const u8) void {
            av[kk.*] = s;
            kk.* += 1;
        }
    }.arg;
    A(&argv, &k, pp.ptr);
    const t = std.fmt.bufPrintSentinel(&turns, "{d}", .{if (which == 0) cl_turns else gk_turns}, 0) catch "0";
    const pz: [*:0]const u8 = @ptrCast(p.ptr); // (sent: 0-ended)
    const sysz: [*:0]const u8 = sys[0..sys_len :0].ptr;
    var resume_flag: [*:0]const u8 = "--resume";
    if (which == 0) {
        // claude -p <prompt> --output-format stream-json --verbose --mcp-config
        // <file> --strict-mcp-config --allowedTools mcp__beemodel --max-turns N
        // --append-system-prompt <instructions> [--model M] [--resume <session>]
        for ([_][*:0]const u8{ "-p", pz, "--output-format", "stream-json", "--verbose", "--mcp-config", @ptrCast(&cfg), "--strict-mcp-config", "--allowedTools", "mcp__beemodel", "--max-turns", t.ptr, "--append-system-prompt", sysz }) |a| A(&argv, &k, a);
        if (cl_model.n > 0) {
            A(&argv, &k, "--model");
            A(&argv, &k, cl_model.z());
        }
    } else {
        // grok --cwd <dir> -p <prompt> --output-format streaming-messages-json
        // --always-approve --trust --disable-web-search --disallowed-tools ...
        // (no shell, no files) --max-turns N --rules <instructions> [-m M] [-r <session>]
        for ([_][*:0]const u8{ "--cwd", @ptrCast(&proc.dir), "-p", pz, "--output-format", "streaming-messages-json", "--always-approve", "--trust", "--disable-web-search", "--disallowed-tools", gk_deny, "--max-turns", t.ptr, "--rules", sysz }) |a| A(&argv, &k, a);
        if (gk_model.n > 0) {
            A(&argv, &k, "-m");
            A(&argv, &k, gk_model.z());
        }
        resume_flag = "-r";
    }
    // a follow-up: the same session
    if (sid_len > 0 and sid_prov == which + 1) {
        A(&argv, &k, resume_flag);
        A(&argv, &k, sid[0..sid_len :0].ptr);
    }
    argv[k] = null;
    line_len = 0;
    line_skip = false;
    proc.on_data = cliData;
    proc.on_exit = cliExit;
    if (proc.spawn(pp.ptr, &argv, @ptrCast(&proc.dir))) return true;
    addZ(K_ERR, s_no_start);
    return false;
}

/// ai_cfg_write: the CLI's MCP configuration: the bridge (this program) for
/// this instance's socket (cfg = the file).
fn cfgWrite(which: u32) void {
    const d = proc.dirPath();
    var f: []const u8 = undefined;
    if (which == 1) {
        const gd = std.fmt.bufPrint(&cfg, "{s}/.grok", .{d}) catch return;
        _ = @import("spawn.zig").ensureDir(gd);
        f = std.fmt.bufPrintSentinel(&cfg, "{s}/.grok/config.toml", .{d}, 0) catch return;
    } else f = std.fmt.bufPrintSentinel(&cfg, "{s}/mcp.json", .{d}, 0) catch return;
    req.reset();
    const sock = @import("mcp.zig").sockPath();
    if (which == 1) {
        req.raw("[mcp_servers.beemodel]\ncommand = ");
        req.q(proc.exePath());
        req.raw("\nargs = [\"--mcp-bridge\"]\nenabled = true\n\n[mcp_servers.beemodel.env]\nBEEMODEL_SOCKET = ");
        req.q(sock);
        req.char(10);
    } else {
        req.raw("{\"mcpServers\":{\"beemodel\":{\"command\":");
        req.q(proc.exePath());
        req.raw(",\"args\":[\"--mcp-bridge\"],\"env\":{\"BEEMODEL_SOCKET\":");
        req.q(sock);
        req.raw("}}}}\n");
    }
    _ = proc.writePrivate(f, req.items());
}

/// ai_cli_data: the child's output: each whole line (a line longer than the
/// buffer, such as an image's data, is skipped whole, with a note).
fn cliData(b0: []const u8) void {
    var b = b0;
    while (true) {
        const n = @min(b.len, LINE_CAP - 1 - line_len);
        @memcpy(line[line_len .. line_len + n], b[0..n]);
        line_len += n;
        b = b[n..];
        while (std.mem.indexOfScalar(u8, line[0..line_len], 10)) |nl| {
            if (line_skip) {
                line_skip = false; // (the end of a skipped one)
            } else cliLine(line[0..nl]);
            const rest = line_len - nl - 1;
            std.mem.copyForwards(u8, line[0..rest], line[nl + 1 .. line_len]);
            line_len = rest;
        }
        if (line_len >= LINE_CAP - 1) {
            line_len = 0;
            if (!line_skip) {
                line_skip = true;
                addZ(K_NOTE, s_too_long);
            }
        }
        if (b.len == 0) break;
    }
}

/// ai_cli_exit: the CLI is done.
fn cliExit(code: i32) void {
    if (line_len > 0) {
        // a last line without its newline (not the end of a skipped one)
        if (!line_skip) cliLine(line[0..line_len]);
        line_len = 0;
        line_skip = false;
    }
    if (run == 3) return testExit(code);
    if (stopped) {
        addZ(K_NOTE, s_stopped);
    } else if (code != 0) {
        var b: [80]u8 = undefined;
        addZ(K_ERR, std.fmt.bufPrint(&b, "{s}{s}{d}", .{ prov_names[run], s_ended_a, code }) catch "");
    }
    finish();
}

/// ai_field: a short string member (119 bytes), "" when missing or not a string.
fn field(t: []const u8, obj: usize, key: []const u8, dst: *[128]u8) []const u8 {
    const v = json.find(t, obj, key) orelse return "";
    const s = json.str(t, v, dst[0..120]) orelse return "";
    return s;
}

/// ai_text: that string member, unescaped, in tmp: its length (0: none).
fn text(t: []const u8, obj: usize, key: []const u8) usize {
    tmp_len = 0;
    const v = json.find(t, obj, key) orelse return 0;
    const s = json.str(t, v, tmp[0 .. TMP_CAP - 1]) orelse return 0;
    tmp_len = s.len;
    return s.len;
}

fn tmpS() []const u8 {
    return tmp[0..tmp_len];
}

/// ai_cli_line: one event of the stream: system (the session), assistant
/// (text, tool use), user (tool results), result (the end, errors); other
/// text is shown as it is.
fn cliLine(ln: []const u8) void {
    if (run == 3) return orData(ln); // (a test: the reply is kept whole)
    const i = json.ws(ln, 0);
    if (i >= ln.len or ln[i] != '{') return add(K_NOTE, null, ln, ln.len);
    const t = ln[i..];
    if (!json.valid(t)) return add(K_NOTE, null, t, t.len);
    var tb: [128]u8 = undefined;
    const ty = field(t, 0, "type", &tb);
    if (std.mem.eql(u8, ty, "system")) {
        takeSid(t);
    } else if (std.mem.eql(u8, ty, "assistant")) {
        const c = contentOf(t) orelse return;
        var e = json.first(t, c);
        while (e) |el| : (e = json.next(t, el)) {
            var kb: [128]u8 = undefined;
            const k = field(t, el, "type", &kb);
            if (std.mem.eql(u8, k, "text")) {
                if (text(t, el, "text") > 0) addZ(K_AI, tmpS());
            } else if (std.mem.eql(u8, k, "tool_use")) {
                var nb: [128]u8 = undefined;
                const nm = field(t, el, "name", &nb);
                const a: []const u8 = if (json.find(t, el, "input")) |v| t[v..json.skip(t, v)] else "{}";
                addTool(nm, a);
            }
        }
    } else if (std.mem.eql(u8, ty, "user")) {
        const c = contentOf(t) orelse return;
        var e = json.first(t, c);
        while (e) |el| : (e = json.next(t, el)) {
            var kb: [128]u8 = undefined;
            if (!std.mem.eql(u8, field(t, el, "type", &kb), "tool_result")) continue;
            const cv = json.find(t, el, "content") orelse continue;
            // its content: a text or [{text}]
            var n: usize = 0;
            if (t[cv] == '[') {
                const f = json.first(t, cv) orelse continue;
                n = text(t, f, "text");
            } else if (json.str(t, cv, tmp[0 .. TMP_CAP - 1])) |s| {
                tmp_len = s.len;
                n = s.len;
            }
            if (n == 0) continue;
            var kind: u8 = K_RES;
            if (json.find(t, el, "is_error")) |v| {
                if (json.boolean(t, v)) kind = K_ERR;
            }
            add(kind, "  = ", tmpS(), 160);
        }
    } else if (std.mem.eql(u8, ty, "result")) {
        // the end: the session; an error
        takeSid(t);
        var err = false;
        if (json.find(t, 0, "is_error")) |v| err = json.boolean(t, v);
        var sb: [128]u8 = undefined;
        const sub = field(t, 0, "subtype", &sb);
        if (sub.len > 0 and !std.mem.eql(u8, sub, "success")) err = true;
        if (!err) return;
        if (std.mem.eql(u8, sub, "error_max_turns")) {
            // the turn limit: a note, and how to go on (the session is kept:
            // "continue" resumes it)
            var b: [200]u8 = undefined;
            return addZ(K_NOTE, std.fmt.bufPrint(&b, "Stopped after {s} turns (Preferences > AI > Turns at most). Type continue to go on from where it stopped.", .{cut0(&turns)}) catch "");
        }
        if (text(t, 0, "result") == 0) {
            @memcpy(tmp[0..sub.len], sub);
            tmp_len = sub.len;
        }
        addZ(K_ERR, tmpS());
    }
}

fn contentOf(t: []const u8) ?usize {
    const m = json.find(t, 0, "message") orelse return null;
    const c = json.find(t, m, "content") orelse return null;
    if (t[c] != '[') return null;
    return c;
}

/// session_id -> sid (for --resume)
fn takeSid(t: []const u8) void {
    var b: [128]u8 = undefined;
    const s = field(t, 0, "session_id", &b);
    if (s.len == 0) return;
    @memcpy(sid[0..s.len], s);
    sid[s.len] = 0;
    sid_len = s.len;
    sid_prov = run + 1;
}

// =============================================================================
// OpenRouter
// =============================================================================

/// ai_key: the key (the setting, else OPENROUTER_API_KEY) or false; hdr = its header.
fn haveKey() bool {
    var k: []const u8 = or_key.s();
    if (k.len == 0) k = @import("spawn.zig").getenv("OPENROUTER_API_KEY") orelse return false;
    if (k.len == 0) return false;
    const pre = "Authorization: Bearer ";
    @memcpy(hdr[0..pre.len], pre);
    var n: usize = 0;
    while (n < k.len and n < 500 and k[n] >= 32) : (n += 1) hdr[pre.len + n] = k[n];
    hdr_len = pre.len + n;
    return true;
}

/// ai_url_make: url = the address setting (no trailing /) + path (Ollama's when local).
fn urlMake(p: []const u8) void {
    var u = (if (local) &ol_url else &or_url).s();
    while (u.len > 0 and u[u.len - 1] == '/') u = u[0 .. u.len - 1];
    const s = std.fmt.bufPrint(&url, "{s}{s}", .{ u, p }) catch "";
    url_len = s.len;
}

/// ai_or_start: true when the request is on its way.
fn orStart(p: []const u8) bool {
    if (!local and !haveKey()) {
        addZ(K_ERR, s_no_key);
        return false;
    }
    urlMake("/chat/completions");
    if (tools.len() == 0) orTools();
    // the messages: (the instructions,) the prompt
    if (hist.len() == 0) {
        hist.raw("{\"role\":\"system\",\"content\":");
        hist.q(sys[0..sys_len]);
        hist.char('}');
    }
    hist.char(',');
    hist.raw("{\"role\":\"user\",\"content\":");
    hist.q(p);
    hist.char('}');
    or_n = 0;
    return orPost();
}

/// ai_or_tools: the tools as functions: the curated MCP tools and
/// run_operator (not every operator's own tool).
fn orTools() void {
    const r = @import("mcp.zig").local("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}");
    const res = json.find(r, 0, "result") orelse return;
    const tl = json.find(r, res, "tools") orelse return;
    tools.reset();
    tools.char('[');
    var n: usize = 0;
    var e = json.first(r, tl);
    while (e) |el| : (e = json.next(r, el)) {
        var nb: [128]u8 = undefined;
        const nm = field(r, el, "name", &nb);
        if (std.mem.startsWith(u8, nm, "op_")) continue;
        if (n > 0) tools.char(',');
        n += 1;
        tools.raw("{\"type\":\"function\",\"function\":{\"name\":");
        tools.q(nm);
        tools.raw(",\"description\":");
        rawOf(r, el, "description");
        tools.raw(",\"parameters\":");
        rawOf(r, el, "inputSchema");
        tools.raw("}}");
    }
    tools.char(']');
}

fn rawOf(r: []const u8, el: usize, k: []const u8) void {
    if (json.find(r, el, k)) |v| tools.bytes(r[v..json.skip(r, v)]) else tools.raw("{}");
}

/// ai_or_post: the conversation so far, sent.
fn orPost() bool {
    rbody.reset();
    rbody.raw("{\"model\":");
    rbody.q((if (local) &ol_model else &or_model).s());
    rbody.raw(",\"messages\":[");
    rbody.bytes(hist.items());
    rbody.raw("],\"tools\":");
    rbody.bytes(if (tools.len() > 0) tools.items() else "[]");
    // Ollama: no thinking (the model would answer in it, which is not shown)
    if (local) rbody.raw(",\"reasoning_effort\":\"none\"");
    rbody.char('}');
    reply_len = 0;
    proc.on_data = orData;
    proc.on_exit = orExit;
    if (proc.curl(url[0..url_len], rbody.items(), if (local) null else hdr[0..hdr_len])) return true;
    addZ(K_ERR, s_no_curl);
    return false;
}

/// ai_or_data: curl's reply, kept whole.
fn orData(b: []const u8) void {
    const n = @min(b.len, REPLY_CAP - 1 - reply_len);
    @memcpy(reply[reply_len .. reply_len + n], b[0..n]);
    reply_len += n;
}

/// ai_or_exit: the reply: the model's text, its tool calls (run, answered,
/// the conversation sent again), or an error.
fn orExit(code: i32) void {
    if (run == 3) return testExit(code);
    if (stopped) {
        addZ(K_NOTE, s_stopped);
        return finish();
    }
    const t = reply[0..reply_len];
    if (code != 0) {
        add(K_ERR, if (local) s_ol_fail else s_or_fail, t, 400); // curl's own message
        return finish();
    }
    if (!json.valid(t)) return orBad(t);
    const o = json.ws(t, 0);
    if (o >= t.len or t[o] != '{') return orBad(t);
    if (json.find(t, o, "error")) |e| {
        tmp_len = 0;
        if (t[e] == '{') _ = text(t, e, "message");
        add(K_ERR, if (local) s_ol_err else s_or_err, tmpS(), 400);
        return finish();
    }
    // choices[0].message
    const ch = json.find(t, o, "choices") orelse return orNone();
    if (t[ch] != '[') return orNone();
    const c0 = json.first(t, ch) orelse return orNone();
    const msg = json.find(t, c0, "message") orelse return orNone();
    if (text(t, msg, "content") > 0) addZ(K_AI, tmpS());
    var calls: ?usize = null;
    var first_call: ?usize = null;
    if (json.find(t, msg, "tool_calls")) |tc| {
        if (t[tc] == '[') {
            first_call = json.first(t, tc);
            if (first_call != null) calls = tc;
        }
    }
    histAsst(t, calls);
    if (calls == null) return finish(); // an answer: kept, the request is done
    var e = first_call;
    while (e) |call| : (e = json.next(t, call)) {
        var cb: [128]u8 = undefined;
        const c = field(t, call, "id", &cb);
        @memcpy(cid[0..c.len], c);
        cid_len = c.len;
        const f = json.find(t, call, "function") orelse continue;
        var nb: [128]u8 = undefined;
        const nm = field(t, f, "name", &nb);
        @memcpy(name[0..nm.len], nm);
        name_len = nm.len;
        // the arguments: a JSON text (or an object); not one JSON value: {}
        args_len = 0;
        if (json.find(t, f, "arguments")) |av| {
            if (t[av] == '"') {
                if (json.str(t, av, args[0 .. TMP_CAP - 1])) |s| args_len = s.len;
            } else {
                const end = json.skip(t, av);
                if (end - av < TMP_CAP - 1) {
                    @memcpy(args[0 .. end - av], t[av..end]);
                    args_len = end - av;
                }
            }
        }
        args_len = std.mem.indexOfScalar(u8, args[0..args_len], 0) orelse args_len;
        if (args_len == 0 or !json.valid(args[0..args_len])) {
            @memcpy(args[0..2], "{}");
            args_len = 2;
        }
        addTool(name[0..name_len], args[0..args_len]);
        toolRun();
        add(if (iserr) K_ERR else K_RES, "  = ", tmpS(), 160);
        // {"role":"tool", ...}
        hist.char(',');
        hist.raw("{\"role\":\"tool\",\"tool_call_id\":");
        hist.q(cid[0..cid_len]);
        hist.raw(",\"content\":");
        hist.q(tmpS()[0..@min(tmp_len, 12000)]);
        hist.char('}');
    }
    // again, with the results
    or_n += 1;
    if (stopped) {
        addZ(K_NOTE, s_stopped);
        return finish();
    }
    if (or_n >= (if (local) ol_steps else or_steps)) {
        var b: [100]u8 = undefined;
        addZ(K_NOTE, std.fmt.bufPrint(&b, "Stopped after {d} steps (the limit is in Preferences > AI).", .{or_n}) catch "");
        return finish();
    }
    if (!orPost()) finish();
}

fn orBad(t: []const u8) void {
    add(K_ERR, if (local) s_ol_bad else s_or_bad, t, 300);
    finish();
}

fn orNone() void {
    addZ(K_ERR, if (local) s_ol_none else s_or_none);
    finish();
}

/// The model's message, into the conversation (calls: its tool calls).
fn histAsst(t: []const u8, calls: ?usize) void {
    hist.char(',');
    hist.raw("{\"role\":\"assistant\",\"content\":");
    hist.q(tmpS());
    if (calls) |c| {
        hist.raw(",\"tool_calls\":");
        hist.bytes(t[c..json.skip(t, c)]);
    }
    hist.char('}');
}

/// ai_tool_run: the tool name with the arguments args, through the MCP
/// server's own handler -> tmp = its text, iserr.
fn toolRun() void {
    iserr = true;
    tmp_len = 0;
    req.reset();
    req.raw("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":");
    req.q(name[0..name_len]);
    req.raw(",\"arguments\":");
    req.raw(args[0..args_len]);
    req.raw("}}");
    const r = @import("mcp.zig").local(req.items());
    if (json.find(r, 0, "result")) |res| {
        iserr = if (json.find(r, res, "isError")) |v| json.boolean(r, v) else false;
        const c = json.find(r, res, "content") orelse return;
        const f = json.first(r, c) orelse return;
        _ = text(r, f, "text");
    } else if (json.find(r, 0, "error")) |e| {
        _ = text(r, e, "message"); // a protocol error: its message
    }
}

// =============================================================================
// Test a connection (Preferences > AI)
// =============================================================================

/// ai_test(0 Claude Code / 1 Grok / 2 OpenRouter / 3 Ollama): its version,
/// the key's validity, or whether Ollama has the model, as a message.
pub fn testConn(which: u32) void {
    if (busy or proc.running()) return logLine(s_busy);
    test_which = which;
    reply_len = 0;
    proc.on_data = orData;
    local = which == 3;
    if (which < 2) {
        // <program> --version
        const pp = prog(which, false) orelse return;
        proc.on_exit = cliExit;
        argv[0] = pp.ptr;
        argv[1] = "--version";
        argv[2] = null;
        run = 3;
        _ = proc.spawn(pp.ptr, &argv, null);
        return;
    }
    if (which == 2) {
        // GET <address>/key with the key
        if (!haveKey()) return testPair(s_test_bad, s_no_key);
        urlMake("/key");
    } else urlMake("/models"); // GET <Ollama's address>/models
    proc.on_exit = orExit;
    run = 3;
    if (proc.curl(url[0..url_len], null, if (which == 2) hdr[0..hdr_len] else null)) return;
    testPair(if (local) s_test_bad_ol else s_test_bad, s_no_curl);
}

/// ai_test_exit: the test's answer, as a message.
fn testExit(code: i32) void {
    run = 0;
    var b: [200]u8 = undefined;
    const t = reply[0..reply_len];
    if (test_which < 2) {
        // the first line: "2.1.0 (Claude Code)"
        var n: usize = 0;
        while (n < t.len and t[n] != 0 and t[n] != 10 and n < 100) n += 1;
        return testSay(std.fmt.bufPrint(&b, "  {s}: {s}", .{ prov_names[test_which], t[0..n] }) catch "");
    }
    const pre = if (local) s_test_bad_ol else s_test_bad;
    if (code != 0 or !json.valid(t)) return testPair(pre, s_test_noans);
    const o = json.ws(t, 0);
    if (json.find(t, o, "data")) |d| {
        if (!local) return testSay(s_test_ok_key);
        // {"data": [{"id": <model>}, ...]}
        var e = json.first(t, d);
        while (e) |el| : (e = json.next(t, el)) {
            var nb: [128]u8 = undefined;
            if (std.mem.eql(u8, field(t, el, "id", &nb), ol_model.s())) return testSay(s_test_ok_ol);
        }
        return testSay(std.fmt.bufPrint(&b, "{s}{s}{s}", .{ s_test_bad_ol, s_test_nomodel, ol_model.s() }) catch "");
    }
    if (json.find(t, o, "error")) |e| {
        if (text(t, e, "message") > 0) return testPair(pre, tmpS());
    }
    testPair(pre, s_test_noans);
}

/// ai_test_pair / ai_test_say("  text"): a test's answer: a message, and a
/// note in the transcript.
fn testPair(pre: []const u8, s: []const u8) void {
    var b: [600]u8 = undefined;
    testSay(std.fmt.bufPrint(&b, "{s}{s}", .{ pre, s[0..@min(s.len, 500)] }) catch "");
}

fn testSay(s: []const u8) void {
    logLine(s);
    addZ(K_NOTE, if (s.len >= 2) s[2..] else "");
}

// =============================================================================
// Operators
// =============================================================================

fn opSend() void {
    const a = ops.arg;
    if (a.len > 0) send(a) else send(prompt[0..prompt_len]);
    if (busy) prompt_len = 0;
}

fn opStop() void {
    if (!busy) return;
    stopped = true;
    proc.stop();
}

pub fn opNew() void {
    if (busy) return;
    tx_len = 0;
    view_reset = true;
    rev += 1;
    sid_len = 0;
    sid[0] = 0;
    sid_prov = 0;
    hist.reset();
    dirty();
}

var copy_buf: [TX_CAP + 8]u8 = undefined;

/// ai.copy: the selection, else the transcript as shown (a line an entry, a
/// blank line before each prompt but the first), becomes the clipboard.
fn opCopy() void {
    if (selCopy()) return;
    if (tx_len == 0) return logLine(s_nothing_copy);
    var n: usize = 0;
    var o: u32 = 0;
    while (o < tx_len) {
        if (tx[o] == K_YOU and o != 0) {
            copy_buf[n] = 10;
            n += 1;
        }
        const t = entryText(o);
        @memcpy(copy_buf[n .. n + t.len], t);
        n += t.len;
        copy_buf[n] = 10;
        n += 1;
        o += @intCast(t.len + 2);
    }
    @import("clipboard.zig").copy(copy_buf[0..n]);
    logLine(s_copied);
}

fn opRevert() void {
    if (!busy and @import("agent.zig").revertable()) return ops.runId("edit.undo");
    logLine(s_nothing_rev);
}

fn opTest() void {
    const a = ops.arg;
    var w: u32 = 0;
    if (a.len > 0 and a[0] >= '0' and a[0] <= '2') w = a[0] - '0';
    testConn(w);
}

/// ai.transcript: "$ ai: idle|busy <entries>", then the last 24 entries as
/// "$ <kind letter> <text>" (80 bytes of it).
fn opTranscript() void {
    var n: u32 = 0;
    var o: u32 = 0;
    while (o < tx_len) {
        n += 1;
        o += @intCast(entryText(o).len + 2);
    }
    app.log("$ ai: {s}{d}", .{ if (busy) "busy " else "idle ", n });
    var skip: i64 = @as(i64, n) - 24;
    o = 0;
    const kinds = "?YATERN";
    while (o < tx_len) {
        const t = entryText(o);
        skip -= 1;
        if (skip < 0) app.log("$ {c} {s}", .{ kinds[@min(tx[o], 6)], t[0..@min(t.len, 80)] });
        o += @intCast(t.len + 2);
    }
}

/// ai.mode: to the prompt (the AI workspace when no AI Assistant is shown).
fn opMode() void {
    if (!app.hasEditor(.ai)) app.workspaceAi();
    focus = true;
    host.focusSoon();
    dirty();
}

pub const list = .{
    .{ "ai.send", Impl{ .run = opSend } },
    .{ "ai.stop", Impl{ .run = opStop } },
    .{ "ai.new", Impl{ .run = opNew } },
    .{ "ai.copy", Impl{ .run = opCopy } },
    .{ "ai.revert", Impl{ .run = opRevert } },
    .{ "ai.mode", Impl{ .run = opMode } },
    .{ "ai.transcript", Impl{ .run = opTranscript } },
    .{ "ai.test", Impl{ .run = opTest } },
    .{ "area.type_ai", Impl{ .run = opAreaType, .check = isAreaType } },
};

fn opAreaType() void {
    app.setActiveEditor(.ai);
}
fn isAreaType() bool {
    return app.activeEditor() == .ai;
}

// =============================================================================
// The main loop: the child, the MCP's build_world
// =============================================================================

/// Once, at start: the callbacks, MCP's build_world prompt.
pub fn init() void {
    proc.on_dirty = dirty;
    @import("mcp.zig").world_get = mcpWorld;
    @import("copilot.zig").world_get = mcpWorld;
    // Tidy with AI, the AI line-up of references: their prompts come here
    const h = @import("aihook.zig");
    h.send_as = sendAs;
    h.busy = isBusy;
    h.show = show;
}

fn isBusy() bool {
    return busy;
}

/// find_editor(ED_AI), else wsp_ai: the AI Assistant in view.
fn show() void {
    if (!app.hasEditor(.ai)) app.workspaceAi();
}

pub fn pollfds(p: []std.os.linux.pollfd) usize {
    return proc.pollfds(p);
}

/// ai_tick: the child's output, its end.
pub fn tick() void {
    proc.tick();
}

pub fn running() bool {
    return proc.running();
}

/// BeeModel is quitting: the child goes too.
pub fn kill() void {
    proc.kill();
}

// =============================================================================
// The AI Assistant area
// =============================================================================

fn kindCol(k: u8) u32 {
    const th = ui.th;
    return switch (k) {
        K_YOU => th.accent,
        K_TOOL, K_RES, K_NOTE => th.text_dim,
        K_ERR => th.warn,
        else => th.text,
    };
}

// The transcript as Zui's text view shows it: each entry wrapped at spaces
// to the view's width into lines (a word wider than the line broken where
// it fits), a blank line before each prompt but the first. Laid out again
// when the transcript or the width changes.
const AI_MAXL = 4096;
const LineRec = struct { off: u32, n: u32, kind: u8, block: u32, soft: bool };
var lines: [AI_MAXL]LineRec = undefined;
var nlines: usize = 0;
/// Bumped on each change of the transcript (for the layout and the view).
var rev: u64 = 1;
var laid_rev: u64 = 0;
var laid_w: f32 = 0;
var view_st: zui.TextViewState = .{};
/// The transcript moved or went: the view's selection with it (next frame).
var view_reset = false;

fn pushLine(l: LineRec) void {
    if (nlines == AI_MAXL) {
        // (the oldest half goes)
        std.mem.copyForwards(LineRec, lines[0 .. AI_MAXL / 2], lines[AI_MAXL / 2 ..]);
        nlines = AI_MAXL / 2;
    }
    lines[nlines] = l;
    nlines += 1;
}

fn layoutLines(z: *zui.Ui, width: f32) void {
    nlines = 0;
    var o: u32 = 0;
    while (o < tx_len) {
        const k = tx[o];
        const t = entryText(o);
        const base: u32 = o + 1;
        // (a gap before each prompt, not before its later lines)
        if (k == K_YOU and o != 0 and t.len > 0 and t[0] != ' ') pushLine(.{ .off = base, .n = 0, .kind = 0, .block = 0, .soft = false });
        var st: usize = 0;
        var first = true;
        while (st < t.len or first) {
            // as many words as fit (their spaces kept at the end of the line)
            var end = st;
            var fit: usize = st;
            while (end < t.len) {
                var we = end;
                while (we < t.len and t[we] == ' ') we += 1;
                while (we < t.len and t[we] != ' ') we += 1;
                if (z.textSize(t[st..we]).x > width and fit > st) break;
                fit = we;
                end = we;
                if (z.textSize(t[st..we]).x > width) break;
            }
            if (fit < t.len) while (fit < t.len and t[fit] == ' ') {
                fit += 1;
            };
            if (fit > st and z.textSize(std.mem.trimEnd(u8, t[st..fit], " ")).x > width) {
                // one long word: as much of it as fits (a character at least)
                var c = st;
                while (c < fit) {
                    var nx = c + 1;
                    while (nx < fit and t[nx] & 0xc0 == 0x80) nx += 1;
                    if (c > st and z.textSize(t[st..nx]).x > width) break;
                    c = nx;
                }
                fit = c;
            }
            pushLine(.{ .off = base + @as(u32, @intCast(st)), .n = @intCast(fit - st), .kind = k, .block = o + 1, .soft = !first });
            first = false;
            if (fit == st) break;
            st = fit;
        }
        o += @intCast(t.len + 2);
    }
}

const TxSource = struct {
    total: u64,

    pub fn len(_: *const TxSource) usize {
        return nlines;
    }

    pub fn line(_: *const TxSource, i: usize) zui.TextLine {
        const l = lines[i];
        return .{ .text = tx[l.off..][0..l.n], .color = if (l.kind == K_AI) null else host.col(kindCol(l.kind)), .block = l.block, .soft = l.soft };
    }
};

/// ai_sel_copy: the selection (if any) to the clipboard, its messages a line each.
fn selCopy() bool {
    var src: TxSource = .{ .total = rev };
    if (!zui.copySelection(host.get(), &src, &view_st)) return false;
    logLine(s_copied);
    return true;
}

fn sendPrompt() void {
    ops.arg = "";
    opSend();
}

fn connPick(k: usize) void {
    prov = @intCast(k);
    @import("prefs.zig").save();
}

const conn_items = [4]zui.Choice{
    .{ .label = "Claude Code" },
    .{ .label = "Grok" },
    .{ .label = "OpenRouter" },
    .{ .label = "Ollama" },
};

/// ed_ai_draw: the connection | New Copy Revert; the transcript (the newest
/// text kept in view); the status line; the prompt | Send (Stop). A Zui part.
pub fn body(i: i16, r: Rect) void {
    const th = ui.th;
    const z = host.beginPart("ai", @intCast(i), r) orelse return;
    defer host.endPart(z);
    z.drawRect(.{ .rect = host.zr(r), .fill = host.col(th.pane_bg) });
    const pad: f32 = 12;
    const pw = @max(60, @as(f32, @floatFromInt(r.w)) - 2 * pad);
    z.beginVertical(.{ .width = .fill, .height = .fill, .padding = pad, .spacing = 6 });
    defer z.endVertical();
    // the connection (a drop-down) | New Copy Revert
    {
        z.beginHorizontal(.{ .width = .fill, .spacing = 6 });
        defer z.endHorizontal();
        var sel: usize = if (prov >= 0 and prov <= 3) @intCast(prov) else 0;
        const d = z.dropdown("##connection", &sel, &conn_items, .{ .width = .px(@floor(pw / 2) - 3) });
        if (d.changed) connPick(sel);
        z.tooltipRich(d, .{ .title = "Connection", .body = "The connection this conversation uses (set them up in Preferences > AI)" });
        const bw: f32 = @floor((pw / 2 - 15) / 3);
        const nb = z.button("New", .{ .width = .px(bw) });
        z.tooltipRich(nb, .{ .title = "New", .body = "Start a new conversation (the scene stays as it is)" });
        if (nb.clicked) opNew();
        if (tx_len > 0) {
            const cb = z.button("Copy", .{ .width = .px(bw) });
            z.tooltipRich(cb, .{ .title = "Copy", .body = "Copy the text selected in the conversation (drag over it, double-click: a whole message), or all of it" });
            if (cb.clicked) opCopy();
        }
        if (!busy and @import("agent.zig").revertable()) {
            const rb = z.button("Revert", .{ .width = .px(bw) });
            z.tooltipRich(rb, .{ .title = "Revert", .body = "Undo the AI's last request (one step)" });
            if (rb.clicked) opRevert();
        }
    }
    // the prompt's height (as tall as its lines: 10 at most, fewer in a low area)
    const maxl: usize = @intCast(std.math.clamp(@divTrunc(r.h - 160, 18), 1, PROMPT_MAXL));
    const prompt_w = pw - 70 - 6;
    const ph = z.textAreaHeight(prompt[0..prompt_len], prompt_w, 1, maxl);
    // the transcript (the rest of the height)
    const line_h = z.textSize("").y;
    const used = 22 + 6 + line_h + 6 + ph + 6 + 2 * pad;
    const th_h = @as(f32, @floatFromInt(r.h)) - used;
    if (th_h >= line_h) {
        if (tx_len == 0) {
            z.beginVertical(.{ .width = .fill, .height = .px(th_h) });
            z.wrappedText(s_hint, .{ .color = host.col(th.text_dim), .width = pw });
            z.endVertical();
        } else {
            if (view_reset) {
                view_reset = false;
                view_st = .{};
            }
            const tw = pw - 12 - 14; // (the view's padding, its scrollbar)
            if (laid_rev != rev or laid_w != tw) {
                if (laid_w != tw) view_st.anchor = null; // (the lines moved)
                layoutLines(z, tw);
                laid_rev = rev;
                laid_w = tw;
            }
            var src: TxSource = .{ .total = rev };
            z.pushColor(.input, host.col(th.pane_bg));
            z.pushColor(.border, host.col(th.pane_bg));
            const v = z.textView("##conversation", &src, &view_st, .{ .height = .px(th_h) });
            z.popStyles(2);
            ui.record("pad", "ai.text", host.rectOf(z.lastRect()), true);
            z.tooltipRich(v.interaction, .{ .title = "Conversation", .body = "Drag to select text, double-click a message, Ctrl+C copies it" });
            if (v.copied) logLine(s_copied);
        }
    } else z.spacer(.{ .fixed = @max(0, th_h) });
    // the status line
    {
        var b: [80]u8 = undefined;
        var k: usize = run & 3;
        if (k == 2) k += @intFromBool(local) else if (k == 3) k = 0;
        const s = if (busy) std.fmt.bufPrint(&b, "Working with {s}...  (Stop ends it)", .{prov_names[k]}) catch "" else "";
        z.label(s, .{ .color = host.col(th.accent) });
    }
    // the prompt | Send (Stop)
    z.beginHorizontal(.{ .width = .fill, .spacing = 6, .alignment = .end });
    defer z.endHorizontal();
    const pid = z.id("ai.prompt");
    if (focus) {
        focus = false; // ai.mode: type here
        z.setFocus(pid);
        z.requestRedraw();
    }
    const pr = z.textArea("ai.prompt", &prompt, &prompt_len, .{ .width = .px(prompt_w), .height = .px(ph), .hint = s_prompt_hint, .enter_sends = true });
    if (pr.submitted) {
        send(prompt[0..prompt_len]);
        if (busy) prompt_len = 0;
    }
    if (busy) {
        const sb = z.button("Stop", .{ .width = .px(70) });
        z.tooltipRich(sb, .{ .title = "Stop", .body = "Stop the AI (what it did so far stays, as one undo step)" });
        if (sb.clicked) opStop();
    } else {
        const sb = z.button("Send", .{ .width = .px(70), .variant = .selected });
        z.tooltipRich(sb, .{ .title = "Send", .body = "Send the prompt (Enter)" });
        if (sb.clicked) sendPrompt();
    }
}

// ---- the status bar: the AI at work (status.s) ------------------------------------

var busy_since: i64 = 0;

/// The chip "AI: <prompt>..., N s   Stop" while a request runs (a click stops
/// it): drawn with its right edge at `right`; the next chip's right edge.
pub fn statusChip(b: []u8) ?app.Chip {
    if (!busy) {
        busy_since = 0;
        return null;
    }
    if (busy_since == 0) busy_since = app.now_ms;
    var w = std.Io.Writer.fixed(b);
    const p = label[7..label_len];
    w.print("AI: {s}...", .{p[0..@min(p.len, 36)]}) catch {};
    const secs = @divTrunc(app.now_ms - busy_since, 1000);
    chip_s = secs;
    if (secs >= 60) {
        w.print(", {d} min {d:0>2} s", .{ @divTrunc(secs, 60), @mod(secs, 60) }) catch {};
    } else if (secs >= 1) w.print(", {d} s", .{secs}) catch {};
    w.writeAll("   Stop") catch {};
    return .{ .text = w.buffered(), .label = "status.ai_working", .title = "AI at work", .tip = "The AI is working on this request (one undo step). Click to stop it", .action = opStop };
}
var chip_s: i64 = -1;

/// An AI child: looked at often; the time on the status chip moves.
pub fn tickMs() ?i32 {
    if (busy and busy_since != 0 and @divTrunc(app.now_ms - busy_since, 1000) != chip_s) app.dirty = true;
    if (proc.running()) return 50;
    if (busy) return 1000;
    return null;
}

test "the transcript: lines, prefixes, indents, room" {
    tx_len = 0;
    add(K_YOU, "> ", "build\na tower", std.math.maxInt(usize));
    try std.testing.expectEqualStrings("> build", entryText(0));
    try std.testing.expectEqualStrings("  a tower", entryText(9));
    add(K_RES, "  = ", "a\n\nb", 160);
    var o: u32 = 0;
    var n: usize = 0;
    while (o < tx_len) : (n += 1) o += @intCast(entryText(o).len + 2);
    try std.testing.expectEqual(@as(usize, 4), n);
    // a limit on a line break: the rest is not read on
    tx_len = 0;
    add(K_NOTE, null, "ab\ncd", 2);
    try std.testing.expectEqual(@as(u32, 4), tx_len);
    // the oldest half goes
    tx_len = 0;
    var big: [1000]u8 = @splat('x');
    for (0..200) |_| add(K_AI, null, &big, std.math.maxInt(usize));
    try std.testing.expect(tx_len < TX_CAP);
    try std.testing.expect(tx[0] == K_AI);
    tx_len = 0;
}
