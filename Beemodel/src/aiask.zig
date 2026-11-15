// Ask AI about the selection (the original's aiask.s): a small box at the
// pointer (Alt+right-click in the viewport, or Ask AI... in its right-click
// menu) with one prompt, sent to the AI Assistant's connection (ai.zig) about
// what is selected. The box is a dialog (dialogs.zig .ask), a Zui popup
// described here: its title says what it is about, Enter sends, Esc closes, Up / Down bring back
// the last prompts, quick buttons ask the common things, and Only the
// Selection (remembered) keeps the AI to the selected objects.
const std = @import("std");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const json = @import("json.zig");
const ops = @import("ops.zig");
const scene = @import("scene.zig");
const em = @import("editmesh.zig");
const ai = @import("ai.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");
const dialogs = @import("dialogs.zig");
const m = @import("math.zig");

const Rect = gfx.Rect;
const Impl = ops.Impl;

const ASK_W = 460;
const TEXT_SZ = 4096;
const ASK_LINES = 6; // the prompt grows to this many lines
const HIST_N = 8;
const SEND_W = 70;
const POPUP = "##ask";

/// Only the selection (prefs: ai_only_selection).
pub var scope: bool = true;

var ask_x: i32 = 0; // where it was opened
var ask_y: i32 = 0;
var focus = false; // type into the prompt next frame
var opening = false; // the popup opens next frame
var hn: usize = 0; // prompts kept
var hpos: i32 = -1; // Up / Down: the one shown (-1: new)
var text_buf: [TEXT_SZ]u8 = undefined;
var text_len: usize = 0;
var draft: [TEXT_SZ]u8 = undefined;
var draft_len: usize = 0;
var hist: [HIST_N][TEXT_SZ]u8 = undefined;
var hist_len: [HIST_N]usize = @splat(0);
var title_buf: [160]u8 = undefined;
var ctx: json.W = .{}; // the text sent
var pend = false; // a request is checked when it ends
var req = false; // an Ask AI request runs (its answer: a message)
var msg: [256]u8 = undefined;

const Snap = struct { uid: u32, sel: bool, hash: u64, name: [32]u8, name_len: u8 };
var sn: []Snap = &.{};
var sn_n: usize = 0;

const chips_obj = [4][]const u8{ "Make it 50% bigger.", "Make it 50% smaller.", "Change the material to ", "Duplicate it 8 times in a circle around where it is." };
const chips_edit = [4][]const u8{ "Extrude the selected faces outward by 20 cm.", "Inset the selected faces by 10 cm.", "Change the material to ", "Bevel the selected edges by 2 cm." };
const chip_labels = [4][]const u8{ "Bigger", "Smaller", "Material...", "Copy Around" };
const chip_tips = [4][]const u8{ "Make it 50% bigger (edit mode: extrude the faces 20 cm)", "Make it 50% smaller (edit mode: inset the faces 10 cm)", "Change the material to ... (type the rest)", "Eight copies in a circle around it (edit mode: bevel the edges 2 cm)" };

fn setText(s: []const u8) void {
    text_len = @min(s.len, TEXT_SZ - 1);
    @memcpy(text_buf[0..text_len], s[0..text_len]);
}

/// ai.ask: with a prompt, send it about the selection; without, the box.
fn opAsk() void {
    if (ops.arg.len > 0) return send(ops.arg);
    open(ui.mx, ui.my);
}

pub const list = .{
    .{ "ai.ask", Impl{ .run = opAsk } },
};

/// ask_open: the box at x, y.
pub fn open(x: i32, y: i32) void {
    ask_x = x;
    ask_y = y;
    @import("menus.zig").close();
    text_len = 0;
    hpos = -1;
    focus = true;
    opening = true;
    host.focusSoon();
    dialogs.open(.ask);
}

pub fn close() void {
    dialogs.close();
}

/// The box goes (Esc, a click outside, a send): the popup with it.
pub fn closing() void {
    const z = host.get();
    if (z.isPopupOpen(POPUP)) z.closeAllPopups();
}

/// ask_send_box: the box's prompt, sent (an empty one does nothing).
fn sendBox() void {
    var i: usize = 0;
    while (i < text_len and text_buf[i] == ' ') i += 1;
    if (i == text_len) return;
    remember();
    close();
    send(text_buf[0..text_len]);
}

/// ask_send: to the AI, about the selection: the prompt as typed in the
/// transcript (with a note of what it is about), and sent with what is
/// selected (context).
pub fn send(p0: []const u8) void {
    var pb: [TEXT_SZ]u8 = undefined;
    const p = pb[0..@min(p0.len, TEXT_SZ)];
    @memcpy(p, p0[0..p.len]);
    pend = false;
    if (!ai.busy and scope) pend = snap(); // Only the selection: how it all is
    const t = titleMake();
    const c = context(p);
    ai.sendAs(p, c, t[7..]); // "about Cube"
    req = ai.busy; // (it did not start: nothing to check)
    if (!req) pend = false;
}

// ---- Only the selection ---------------------------------------------------------

/// ask_snap: every object's uid, whether it is in the selection (edit mode:
/// the edited object) and fingerprint; true when something is selected.
fn snap() bool {
    const A = std.heap.page_allocator;
    if (sn.len < scene.count) {
        if (sn.len > 0) A.free(sn);
        sn = A.alloc(Snap, @max(scene.count, 64)) catch {
            sn = &.{};
            sn_n = 0;
            return false;
        };
    }
    var any = false;
    for (0..scene.count) |i| {
        const o = &scene.objects[i];
        const s = &sn[i];
        s.uid = o.uid;
        s.sel = if (em.active) em.obj == i else o.selected;
        any = any or s.sel;
        s.hash = hash(i);
        const nm = o.name();
        s.name_len = @intCast(@min(nm.len, 31));
        @memcpy(s.name[0..s.name_len], nm[0..s.name_len]);
    }
    sn_n = scene.count;
    return any;
}

/// ask_hash: a fingerprint of what the AI could change: its place, flags (not
/// its selection), mesh (its edits), modifiers (their settings), material
/// (its values: a shared one counts for every object that has it), a light's
/// colour and power.
fn hash(i: usize) u64 {
    const o = &scene.objects[i];
    var h = std.hash.Wyhash.init(0xcbf29ce484222325);
    const H = struct {
        fn v(hh: *std.hash.Wyhash, x: anytype) void {
            hh.update(std.mem.asBytes(&x));
        }
    }.v;
    H(&h, o.loc);
    H(&h, o.rot);
    H(&h, o.scl);
    H(&h, o.color);
    H(&h, @intFromEnum(o.kind));
    H(&h, [_]bool{ o.visible, o.locked, o.render });
    H(&h, o.parent orelse 0xffff);
    H(&h, o.mat);
    H(&h, o.mres orelse 0xffff);
    H(&h, o.ref);
    H(&h, o.gflags);
    H(&h, o.folder);
    H(&h, @intFromEnum(o.light_type));
    H(&h, o.power);
    H(&h, o.light_color);
    H(&h, o.size);
    H(&h, o.cone);
    H(&h, o.lens);
    H(&h, o.mesh orelse 0xffff);
    if (o.mesh) |mi| {
        if (scene.meshes[mi]) |*me| {
            H(&h, me.serial);
            H(&h, me.shape);
            H(&h, me.verts.len);
        }
    }
    h.update(std.mem.asBytes(&o.mods.n));
    for (o.mods.m[0..o.mods.n]) |md| h.update(std.mem.asBytes(&md));
    if (o.mat > 0) {
        if (@import("material.zig").get(o.mat - 1)) |ma| h.update(std.mem.asBytes(ma));
    }
    return h.final();
}

fn findUid(uid: u32, at: usize) ?usize {
    if (at < scene.count and scene.objects[at].uid == uid) return at;
    return scene.findUid(uid);
}

fn toastLine(warn: bool, s: []const u8) void {
    app.toastLine(if (warn) .warn else .ok, s[0..@min(s.len, 95)]);
}

/// ask_done: (ai.finish) a request is over: its answer as a message; when it
/// was kept to the selection, the other objects it changed or deleted anyway
/// are named (a warning, and a note in the transcript).
pub fn done() void {
    if (!req) return;
    req = false;
    if (ai.answer()) |a| {
        // the answer as a message: "AI: ..." (its first line; an error amber)
        const s = std.fmt.bufPrint(&msg, "AI: {s}", .{a.text[0..@min(a.text.len, 88)]}) catch "";
        toastLine(a.err, s);
    }
    if (!pend) return;
    pend = false;
    var changed: [3][]const u8 = undefined;
    var deleted: [3][]const u8 = undefined;
    var nc: usize = 0;
    var nd: usize = 0;
    for (sn[0..sn_n], 0..) |*s, k| {
        if (s.sel) continue;
        const nm = s.name[0..s.name_len];
        if (findUid(s.uid, k)) |i| {
            if (hash(i) == s.hash) continue;
            if (nc < 3) changed[nc] = nm;
            nc += 1;
        } else {
            if (nd < 3) deleted[nd] = nm;
            nd += 1;
        }
    }
    if (nc == 0 and nd == 0) return;
    // "The AI also changed A, B and 2 more, and deleted C (not selected). ..."
    var w: usize = 0;
    if (nc > 0) {
        w = put(&msg, w, "The AI also changed ");
        w = names(&msg, w, changed[0..@min(nc, 3)], nc);
        if (nd > 0) {
            w = put(&msg, w, ", and deleted ");
            w = names(&msg, w, deleted[0..@min(nd, 3)], nd);
        }
    } else {
        w = put(&msg, w, "The AI deleted ");
        w = names(&msg, w, deleted[0..@min(nd, 3)], nd);
    }
    w = put(&msg, w, " (not selected). Ctrl+Z undoes the request.");
    ai.note(msg[0..w]);
    toastLine(true, msg[0..w]);
}

fn put(b: []u8, at: usize, s: []const u8) usize {
    const n = @min(s.len, b.len - at);
    @memcpy(b[at .. at + n], s[0..n]);
    return at + n;
}

/// ask_names: "A", "A and B", "A, B and C", "A, B, C and 2 more".
fn names(b: []u8, at0: usize, l: []const []const u8, n: usize) usize {
    var at = at0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        if (k >= 3) {
            var nb: [16]u8 = undefined;
            at = put(b, at, " and ");
            at = put(b, at, std.fmt.bufPrint(&nb, "{d}", .{n - 3}) catch "");
            return put(b, at, " more");
        }
        if (k > 0) at = put(b, at, if (k + 1 == n) " and " else ", ");
        at = put(b, at, l[k]);
    }
    return at;
}

// ---- what it is about --------------------------------------------------------------

/// ask_esel: selected vertices, and faces (all their vertices selected).
pub fn esel() [2]usize {
    const me = em.mesh() orelse return .{ 0, 0 };
    var nv: usize = 0;
    for (em.sel[0..@min(em.sel.len, me.verts.len)]) |s| nv += @intFromBool(s);
    var nf: usize = 0;
    const np = me.poff.len -| 1;
    for (0..np) |p| {
        const a = me.poff[p];
        const e = me.poff[p + 1];
        if (a >= e) continue;
        var all = true;
        for (me.loops[a..e]) |v| {
            if (v >= em.sel.len or !em.sel[v]) {
                all = false;
                break;
            }
        }
        if (all) nf += 1;
    }
    return .{ nv, nf };
}

/// ask_nsel: how many objects are selected, and the active one when selected
/// (else the first).
fn nsel() struct { n: usize, one: ?usize } {
    var n: usize = 0;
    var one: ?usize = null;
    for (0..scene.count) |i| {
        if (!scene.objects[i].selected) continue;
        n += 1;
        if (one == null or scene.active == i) one = i;
    }
    return .{ .n = n, .one = one };
}

/// ask_title_make: "Ask AI about Cube" / "3 objects" / "4 faces of Cube" / "the scene".
pub fn titleMake() []const u8 {
    var w = put(&title_buf, 0, "Ask AI about ");
    if (em.active) {
        const o = &scene.objects[em.obj];
        const c = esel();
        var n = c[0];
        var what: []const u8 = if (n == 1) " vertex of " else " vertices of ";
        if (em.sel_mode == .face and c[1] > 0) {
            n = c[1];
            what = if (n == 1) " face of " else " faces of ";
        }
        if (n == 0) return title_buf[0..put(&title_buf, w, o.name())];
        var nb: [16]u8 = undefined;
        w = put(&title_buf, w, std.fmt.bufPrint(&nb, "{d}", .{n}) catch "");
        w = put(&title_buf, w, what);
        return title_buf[0..put(&title_buf, w, o.name())];
    }
    const s = nsel();
    if (s.n == 0) return title_buf[0..put(&title_buf, w, "the scene")];
    if (s.n == 1) return title_buf[0..put(&title_buf, w, scene.objects[s.one.?].name())];
    var nb: [16]u8 = undefined;
    w = put(&title_buf, w, std.fmt.bufPrint(&nb, "{d}", .{s.n}) catch "");
    return title_buf[0..put(&title_buf, w, " objects")];
}

/// edit_median: the selected vertices' centre (world).
fn median() [3]f32 {
    const me = em.mesh() orelse return .{ 0, 0, 0 };
    const wm = scene.world(em.obj);
    var s = [3]f32{ 0, 0, 0 };
    var n: f32 = 0;
    for (me.verts, 0..) |v, k| {
        if (k >= em.sel.len or !em.sel[k]) continue;
        const p = m.xform(wm, v);
        s[0] += p[0];
        s[1] += p[1];
        s[2] += p[2];
        n += 1;
    }
    if (n > 0) {
        for (&s) |*c| c.* /= n;
    }
    return s;
}

/// ask_context: the text sent: the prompt, then the selection - its objects
/// as scene_summary lists them (the active one first, 16 at most) or, in
/// edit mode, its selected elements - and what to keep to (scope).
fn context(p: []const u8) []const u8 {
    const mcp = @import("mcp.zig");
    ctx.reset();
    ctx.bytes(p);
    ctx.raw("\n\n--- What this request is about (the user asked through BeeModel's Ask AI box, about what they selected) ---\n");
    if (em.active) {
        const o = &scene.objects[em.obj];
        // "Cube is in edit mode (face select): 4 faces (8 vertices) selected,
        // their centre at [x,y,z] (world)."
        ctx.bytes(o.name());
        ctx.raw(" is in edit mode (");
        ctx.raw(switch (em.sel_mode) {
            .vertex => "vertex",
            .edge => "edge",
            .face => "face",
        });
        ctx.raw(" select): ");
        const c = esel();
        if (c[0] == 0) {
            ctx.raw("nothing is selected in it, so the request is about the whole mesh.");
        } else {
            ctx.int(@intCast(c[0]));
            ctx.raw(if (c[0] == 1) " vertex selected" else " vertices selected");
            if (c[1] > 0) {
                ctx.raw(" (");
                ctx.int(@intCast(c[1]));
                ctx.raw(if (c[1] == 1) " whole face)" else " whole faces)");
            }
            ctx.raw(", their centre at [");
            const md = median();
            for (md, 0..) |v, k| {
                if (k > 0) ctx.char(',');
                ctx.num(v);
            }
            ctx.raw("] (world).");
        }
        ctx.raw("\nMesh operators act on the selected elements and keep edit mode: op(\"mesh.extrude\", 0.2) extrudes them 20 cm along their normal, op(\"mesh.inset\", 0.1) insets faces, op(\"mesh.bevel\", \"0.02 2\") bevels edges; vpos and vmove read and move single vertices. Stay in edit mode.\n");
        ctx.raw("The object: ");
        mcp.objJson(&ctx, em.obj);
        ctx.char(10);
    } else {
        const s = nsel();
        if (s.n == 0) {
            ctx.raw("Nothing is selected: the request is about the scene.\n");
            ctx.raw("Answer in one short sentence: what you changed.\n");
            return ctx.items();
        }
        ctx.raw("Selected objects (");
        ctx.int(@intCast(s.n));
        ctx.raw("), the active one first (size: its box in meters, scale included):\n");
        const a = s.one.?;
        mcp.objJson(&ctx, a);
        ctx.char(10);
        var listed: usize = 1;
        for (0..scene.count) |i| {
            if (i == a or !scene.objects[i].selected) continue;
            if (listed >= 16) break;
            mcp.objJson(&ctx, i);
            ctx.char(10);
            listed += 1;
        }
        if (listed < s.n) {
            ctx.raw("... and ");
            ctx.int(@intCast(s.n - listed));
            ctx.raw(" more selected objects (scene_summary lists them all).\n");
        }
    }
    if (scope) ctx.raw("Change only the selection. Leave every other object as it is unless the request names it; new objects are fine when the request asks for them (a copy, a ring of copies). Words like it, them, this and these mean the selection.\n");
    ctx.raw("Answer in one short sentence: what you changed.\n");
    return ctx.items();
}

/// ask_remember: the prompt goes first in the list (once).
fn remember() void {
    const t = text_buf[0..text_len];
    var k: usize = 0;
    while (k < hn) : (k += 1) {
        if (std.mem.eql(u8, hist[k][0..hist_len[k]], t)) break;
    }
    if (k < hn) {
        // already there: taken out first
        var j = k + 1;
        while (j < hn) : (j += 1) {
            hist[j - 1] = hist[j];
            hist_len[j - 1] = hist_len[j];
        }
        hn -= 1;
    }
    var j: usize = @min(hn, HIST_N - 1);
    while (j > 0) : (j -= 1) {
        hist[j] = hist[j - 1];
        hist_len[j] = hist_len[j - 1];
    }
    const n = @min(t.len, TEXT_SZ - 1);
    @memcpy(hist[0][0..n], t[0..n]);
    hist_len[0] = n;
    hn = @min(hn + 1, HIST_N);
}

/// ask_retype: type into the prompt again at once, from the text, the caret
/// at its end (after Up / Down, or a quick button that is typed on).
fn retype() void {
    focus = true;
    caret_end = true;
    host.focusSoon();
}

var caret_end = false;

fn promptFocused(z: *zui.Ui) bool {
    return z.focused != .none and z.focused == prompt_zid;
}

/// ask_key: while the box is open, before Zui's keys: Esc closes it, Up /
/// Down on the prompt's first / last line step through the last prompts,
/// Enter elsewhere in the box sends. True: the key was used.
pub fn key(z: *zui.Ui, code: u32) bool {
    const K = ui.KEY;
    if (code == K.ESC) {
        close(); // (what is typed is dropped)
        return true;
    }
    if (code == K.UP or code == K.DOWN) {
        const ts = &z.textarea_state;
        if (promptFocused(z) and ts.id == prompt_zid) {
            // (inside the lines: the caret moves)
            const at_edge = (code == K.UP and ts.caret_line == 0) or (code == K.DOWN and ts.caret_line + 1 >= ts.line_count);
            if (!at_edge) return false;
        }
        if (code == K.UP) {
            const np = hpos + 1; // Up: older
            if (np >= @as(i32, @intCast(hn))) return true;
            if (hpos == -1) {
                draft_len = text_len; // (leaving the draft: kept)
                @memcpy(draft[0..draft_len], text_buf[0..text_len]);
            }
            hpos = np;
        } else {
            if (hpos < 0) return true; // Down: newer, then the draft
            hpos -= 1;
        }
        if (hpos < 0) setText(draft[0..draft_len]) else setText(hist[@intCast(hpos)][0..hist_len[@intCast(hpos)]]);
        retype();
        return true;
    }
    if ((code == K.ENTER or code == K.KPENTER) and !promptFocused(z)) {
        sendBox(); // (ask_enter)
        return true;
    }
    return false;
}

/// ask_pick is in editors.zig (the viewport's pick): the object under the
/// pointer selected first when it is not.

// ---- the box ---------------------------------------------------------------------------

fn scopeTip() []const u8 {
    return "Tell the AI to change only the selected objects, and name any other object it changed anyway";
}

var prompt_zid: zui.Id = .none;

/// ask_draw: the box, a Zui popup below and right of the pointer (above it
/// when there is no room below); a click outside closes it.
pub fn describe(z: *zui.Ui) void {
    const th = ui.th;
    if (opening) {
        opening = false;
        z.closeAllPopups();
        z.openPopupAt(POPUP, .{ .x = @floatFromInt(ask_x - 24), .y = @floatFromInt(ask_y), .w = 24, .h = 8 });
    }
    if (!z.beginPopup(POPUP, .{ .min_width = ASK_W })) {
        close(); // (a click outside, or Zui's Escape)
        return;
    }
    defer z.endPopup();
    z.pushMetric(.item_spacing, .{ .x = 6, .y = 8 });
    defer z.popStyle();
    const t = titleMake();
    z.pushFont(host.headFont());
    z.label(t, .{});
    z.popFont();
    // the prompt | Send (Stop)
    const pw: f32 = ASK_W - 2 * z.style.popup_padding - SEND_W - 6;
    {
        z.beginHorizontal(.{ .width = .fill, .spacing = 6, .alignment = .start });
        defer z.endHorizontal();
        prompt_zid = z.id("ask.prompt");
        const ts = &z.textarea_state;
        if (focus) {
            focus = false;
            z.setFocus(prompt_zid);
            z.requestRedraw();
        }
        if (caret_end) {
            caret_end = false;
            if (ts.id == prompt_zid) {
                ts.caret = text_len;
                ts.anchor = text_len;
            }
        }
        const ph = z.textAreaHeight(text_buf[0..text_len], pw, 1, ASK_LINES);
        const r = z.textArea("ask.prompt", &text_buf, &text_len, .{ .width = .px(pw), .height = .px(ph), .hint = "Make it bigger, give it a brushed steel material...", .enter_sends = true });
        if (r.submitted) {
            sendBox();
            return;
        }
        if (ai.busy) {
            const b = z.button("Stop", .{ .width = .px(SEND_W) });
            z.tooltipRich(b, .{ .title = "Stop", .body = "Stop the AI (what it did so far stays, as one undo step)" });
            if (b.clicked) ops.runId("ai.stop");
        } else {
            const b = z.button("Send", .{ .width = .px(SEND_W), .variant = .selected });
            z.tooltipRich(b, .{ .title = "Send", .body = "Send the prompt (Enter)" });
            if (b.clicked) {
                sendBox();
                return;
            }
        }
    }
    // the quick buttons
    {
        z.beginHorizontal(.{ .width = .fill, .spacing = 6 });
        defer z.endHorizontal();
        const bw = @floor((ASK_W - 2 * z.style.popup_padding - 18) / 4);
        for (0..4) |k| {
            const b = z.button(chip_labels[k], .{ .width = .px(bw) });
            z.tooltipRich(b, .{ .title = chip_labels[k], .body = chip_tips[k] });
            if (b.clicked) {
                setText((if (em.active) chips_edit else chips_obj)[k]); // a quick ask
                if (k == 2) {
                    retype(); // Material...: type the rest
                } else {
                    sendBox();
                    return;
                }
            }
        }
    }
    // Only the selection; the connection
    {
        z.beginHorizontal(.{ .width = .fill, .spacing = 6 });
        defer z.endHorizontal();
        const c = z.checkbox("Only the selection", &scope, .{});
        z.tooltipRich(c, .{ .title = "Only the selection", .body = scopeTip() });
        if (c.changed) {
            @import("prefs.zig").save(); // (remembered; typing goes on)
            retype();
        }
        var vb: [40]u8 = undefined;
        const p: usize = if (ai.prov >= 0 and ai.prov <= 3) @intCast(ai.prov) else 0;
        const v = std.fmt.bufPrint(&vb, "via {s}", .{([4][]const u8{ "Claude Code", "Grok", "OpenRouter", "Ollama" })[p]}) catch "";
        z.spacer(.fill);
        z.label(v, .{ .color = host.col(th.text_dim) });
    }
}

test "names: one, two, three, more" {
    var b: [128]u8 = undefined;
    const l = [_][]const u8{ "A", "B", "C" };
    try std.testing.expectEqualStrings("A", b[0..names(&b, 0, l[0..1], 1)]);
    try std.testing.expectEqualStrings("A and B", b[0..names(&b, 0, l[0..2], 2)]);
    try std.testing.expectEqualStrings("A, B and C", b[0..names(&b, 0, l[0..3], 3)]);
    try std.testing.expectEqualStrings("A, B, C and 2 more", b[0..names(&b, 0, l[0..3], 5)]);
}
