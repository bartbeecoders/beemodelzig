//! The Versions editor (teamui.s ed_versions_draw): the scene's history and
//! working with others, one column (pnl_begin's: the editor less 14 a side)
//! of sections, each a heading and its rows:
//!
//!   Versions         "On branch <name>", the message and Commit, the diff toggle
//!   Branches         a row a branch (a click switches to it), New Branch | Merge
//!   Merge Conflicts  (while merging) a row a conflict with Ours | Theirs,
//!                    All Ours | All Theirs, Abort
//!   History          the branch's commits, newest first
//!   Collaboration    <- the co-editing agent's section (cosync.zig): host /
//!                       join, the peers to follow, the agent peer. Replace
//!                       collabSection below (its contract: draw from y, return
//!                       the y below it; the original's rows are listed there).
//!   Live Link        <- the live link agent's section (link.zig): serve,
//!                       connect, stop, disconnect. Replace linkSection below
//!                       (same contract).
//!
//! Without a file the history sections are a hint and the column goes on at
//! Collaboration. Buttons do not run their operator while the editor is
//! drawn: it waits for the editor's next pass (run_t / team_pending), so a
//! commit or a merge never changes the scene in the middle of a frame.
const std = @import("std");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");
const ops = @import("ops.zig");
const cat = @import("catalog.zig");
const vc = @import("vc.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");
const bkit = @import("bkit.zig");
const Rect = gfx.Rect;

// ---- a deferred operator (run_t, team_pending) ----------------------------------------

var pend_op: ?usize = null;
var pend_arg: [192]u8 = undefined;
var pend_len: usize = 0;

/// run_t: the operator `id` with `arg`, at the editor's next pass.
pub fn runLater(id: []const u8, arg: []const u8) void {
    pend_op = ops.byId(id) orelse return;
    pend_len = @min(arg.len, pend_arg.len);
    @memcpy(pend_arg[0..pend_len], arg[0..pend_len]);
    app.dirty = true;
}

/// team_pending: the operator a button asked for, now (with its argument, as
/// the console runs one: no form asks).
fn runPending() void {
    const i = pend_op orelse return;
    pend_op = null;
    const was_arg = ops.arg;
    const was_s = ops.scripted;
    ops.arg = pend_arg[0..pend_len];
    ops.scripted = true;
    defer {
        ops.arg = was_arg;
        ops.scripted = was_s;
    }
    // (run_op's echo, unless the operator is quiet)
    const quiet = for (@import("aisafe.zig").quiet) |q| {
        if (std.mem.eql(u8, q, cat.entries[i].id)) break true;
    } else false;
    if (!quiet) app.log("> {s}", .{cat.entries[i].label});
    ops.run(i);
    app.afterInput();
}

// ---- the column's widgets (panel.s, on Zui) ---------------------------------------------

/// BeeModel's record (ui.record), while Zui describes in BeeModel's frame.
fn rec(kind: []const u8, label: []const u8, r: zui.Rect) void {
    if (host.bridging()) ui.record(kind, label, host.rectOf(r), true);
}

/// Text that lives until the frame is drawn and recorded (Zui keeps slices).
fn fmt(z: *zui.Ui, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(z.frameAllocator(), f, args) catch "";
}

/// pnl_hint / pnl_text: small, wrapped at spaces to the column; recorded as
/// `info` (whole).
fn para(z: *zui.Ui, s: []const u8, c: u32) void {
    z.pushMetric(.font_size, 12); // (BeeModel's small face)
    z.wrappedText(s, .{ .color = host.col(c) });
    z.popStyle();
    rec("info", s, z.lastRect());
}
fn hint(z: *zui.Ui, s: []const u8) void {
    para(z, s, ui.th.text_dim);
}
fn text(z: *zui.Ui, s: []const u8) void {
    para(z, s, ui.th.text);
}

/// A plain button, `width` wide, with its tooltip; joins the focus ring.
/// True when clicked (the caller runs its operator later: runLater).
fn button(z: *zui.Ui, label: []const u8, tip: []const u8, width: zui.Size) bool {
    const b = z.button(label, .{ .width = width });
    if (tip.len > 0) z.tooltipRich(b, .{ .title = zui.Ui.visibleLabel(label), .body = tip });
    const by_ring = bkit.ring(b, label);
    return b.clicked or by_ring;
}

/// A button with an operator (WK_BUTTON's aux): its doc as the tip.
fn opButton(z: *zui.Ui, label: []const u8, id: []const u8) bool {
    const tip = if (ops.byId(id)) |i| cat.entries[i].doc else "";
    return button(z, label, tip, .fill);
}

/// pnl_left / pnl_right: two widgets side by side, each half the column.
fn beginPair(z: *zui.Ui) void {
    z.beginHorizontal(.{ .spacing = 6 });
}

/// A list's rows 24 apart, as the column's rows were (row_h of Zui's list:
/// the line and frame_padding.y).
const ROW_PAD: f32 = 4;
fn rowH(z: *zui.Ui) f32 {
    return z.textSize("").y + ROW_PAD;
}

/// A frameless list as tall as `shown` rows (2 of padding above and below).
fn beginList(z: *zui.Ui, name: []const u8, sel: []bool, st: *zui.ListState, shown: usize) zui.List {
    z.pushMetric(.frame_padding, .{ .x = 8, .y = ROW_PAD });
    const h = @as(f32, @floatFromInt(shown)) * rowH(z) + 4;
    const l = z.beginList(name, sel, st, .{ .height = .px(h), .frame = false });
    z.popStyle();
    // (the picked row on the dark accent, as BeeModel's: until endList)
    z.pushColor(.button_active, host.col(ui.th.accent_dark));
    return l;
}

fn endList(z: *zui.Ui, l: *zui.List) zui.ListResult {
    z.popStyle();
    return z.endList(l);
}

/// A list's selection, kept by the app: one bool a row.
fn Picks(comptime n: usize) type {
    return struct { sel: [n]bool = @splat(false), st: zui.ListState = .{} };
}

// ---- the editor ----------------------------------------------------------------------

/// tm_msg: the commit message being typed (the field edits it live).
var msg: [64]u8 = undefined;
var msg_len: usize = 0;
var msg_id: zui.Id = .none;

fn commitNow(z: *zui.Ui) void {
    runLater("vc.commit", msg[0..msg_len]);
    msg_len = 0;
    if (z.focused == msg_id) z.focused = .none;
}

var branches: Picks(32) = .{};
var conflicts: Picks(24) = .{};
var history: Picks(32) = .{};
var peers: Picks(16) = .{};
/// The picked commit (its hash's 8 digits), so the pick stays on it when a
/// commit comes on top.
var hist_pick: [8]u8 = @splat(0);

/// ed_versions_draw: the editor's body, one Zui part over the column
/// (the editor less 14 a side), scrolling when taller than the area.
pub fn body(i: i16, r: Rect) void {
    runPending();
    ui.cv.fill(r, ui.th.pane_bg);
    const salt: usize = @intCast(i);
    const z = host.beginPart("versions", salt, .{ .x = r.x + 14, .y = r.y, .w = r.w - 28, .h = r.h }) orelse return;
    defer host.endPart(z);
    z.pushMetric(.item_spacing, .{ .x = 6, .y = 4 });
    defer z.popStyle();
    z.beginScrollArea("##column", .{ .height = .fill, .padding = 0, .frame = false });
    defer z.endScrollArea();
    z.spacer(.px(4)); // (8 down: the spacer and the spacing)
    versions(z);
    z.spacer(.px(6));
    collabSection(z);
    z.spacer(.px(6));
    linkSection(z);
    z.spacer(.px(4));
}

fn versions(z: *zui.Ui) void {
    const th = ui.th;
    bkit.heading(z, "Versions");
    const nlog = vc.logRows(); // (opens the history: 0 without a file)
    if (!vc.hasFile()) return hint(z, "Save the scene to a file first: its versions are kept beside it.");
    text(z, fmt(z, "On branch {s}", .{vc.headName()}));
    // message | Commit
    z.beginHorizontal(.{ .spacing = 6 });
    z.pushId("message");
    msg_id = z.id("");
    const f = z.textInput("", msg[0 .. msg.len - 1], &msg_len, .{ .width = .fill, .copy_all = true });
    z.popId();
    if (z.focused != msg_id) z.tooltipRich(f, .{ .title = "Message", .body = "What changed, for the history" });
    z.pushColor(.button, host.col(th.accent));
    z.pushColor(.button_hovered, host.col(th.accent));
    z.pushColor(.text, host.col(th.accent_text));
    const commit = button(z, "Commit", "Keep this state of the scene in its history", .px(84));
    z.popStyles(3);
    z.endHorizontal();
    if (commit) commitNow(z);
    // the diff since the last commit, over the scene
    var on = vc.view != 0;
    if (bkit.checkRow(z, "Show what changed since the last commit", &on, "").changed)
        runLater("vc.diff", if (vc.view == 0) "overlay" else "off");

    // ---- branches: a row a branch, the current one picked; a click switches ----
    z.spacer(.px(2));
    bkit.heading(z, "Branches");
    {
        const n = @min(vc.nbr, 32);
        const b = &branches;
        for (0..n) |k| b.sel[k] = std.mem.eql(u8, vc.branchName(k), vc.headName());
        var l = beginList(z, "branches", b.sel[0..n], &b.st, n);
        for (l.first..l.end) |k| {
            const nm = vc.branchName(k);
            z.beginRow(&l, k, .{ .label = nm, .tooltip = "Switch to this branch" });
            const rr = z.endRow(&l);
            if (rr.interaction.clicked or rr.activated or bkit.ring(rr.interaction, nm)) runLater("vc.switch", nm);
        }
        _ = endList(z, &l);
    }
    beginPair(z);
    if (opButton(z, "New Branch...", "vc.branch")) formLater("vc.branch");
    if (opButton(z, "Merge...", "vc.merge")) formLater("vc.merge");
    z.endHorizontal();

    if (vc.merging()) { // ---- merging: the conflicts, each Ours | Theirs ----
        z.spacer(.px(2));
        bkit.heading(z, "Merge Conflicts");
        const n = @min(vc.ncf, 24);
        const c = &conflicts;
        @memset(c.sel[0..n], false);
        var l = beginList(z, "conflicts", c.sel[0..n], &c.st, @min(n, 8));
        const bh = rowH(z) - 6;
        for (l.first..l.end) |k| {
            var rb: [120]u8 = undefined;
            z.beginRow(&l, k, .{ .label = fmt(z, "{s}", .{vc.cfRowText(k, &rb)}) });
            const ours = z.button("Ours", .{ .width = .px(56), .height = .px(bh) });
            const theirs = z.button("Theirs", .{ .width = .px(60), .height = .px(bh) });
            _ = z.endRow(&l);
            if (ours.clicked or bkit.ring(ours, "Ours")) runLater("vc.resolve", fmt(z, "{d} ours", .{k + 1}));
            if (theirs.clicked or bkit.ring(theirs, "Theirs")) runLater("vc.resolve", fmt(z, "{d} theirs", .{k + 1}));
        }
        _ = endList(z, &l);
        beginPair(z);
        if (button(z, "All Ours", "", .fill)) runLater("vc.resolve", "all ours");
        if (button(z, "All Theirs", "", .fill)) runLater("vc.resolve", "all theirs");
        z.endHorizontal();
        if (opButton(z, "Abort", "vc.abort")) runLater("vc.abort", "");
    }

    // ---- the history: the branch's commits, newest first, beside its graph ----
    z.spacer(.px(2));
    bkit.heading(z, "History");
    if (nlog == 0) return hint(z, "No commits yet: type a message and Commit.");
    const n = @min(nlog, 32);
    const h = &history;
    for (0..n) |k| h.sel[k] = std.mem.eql(u8, vc.logRow(k)[0..@min(8, vc.logRow(k).len)], &hist_pick);
    z.beginHorizontal(.{ .spacing = 0 });
    // (the list's scroll, last frame's: the graph's rows follow it)
    const lid = z.id("history");
    const scroll: f32 = if (z.scroll_states.get(lid)) |s| s.scroll else 0;
    const shown = @min(n, 12);
    const rh = rowH(z);
    graph(z, n, shown, rh, scroll);
    var l = beginList(z, "history", h.sel[0..n], &h.st, shown);
    for (l.first..l.end) |k| {
        const row = vc.logRow(k);
        z.beginRow(&l, k, .{ .label = row, .tooltip = if (k == 0) "The branch's newest commit" else "" });
        _ = z.endRow(&l);
    }
    const lr = endList(z, &l);
    z.endHorizontal();
    if (lr.changed) pickCommit(n);
}

/// The commit picked in the list (or the graph) is the one remembered.
fn pickCommit(n: usize) void {
    hist_pick = @splat(0);
    for (history.sel[0..n], 0..) |s, k| if (s) {
        const row = vc.logRow(k);
        @memcpy(hist_pick[0..@min(8, row.len)], row[0..@min(8, row.len)]);
        break;
    };
}

/// The history's graph, on a canvas beside the list: the branch's line, a
/// dot a commit (the newest a ring in the accent, the picked one filled in
/// it), the rows where the list has scrolled them. A click picks a commit.
fn graph(z: *zui.Ui, n: usize, shown: usize, rh: f32, scroll: f32) void {
    const th = ui.th;
    const c = z.beginCanvas("history graph", .{ .width = .px(22), .height = .px(@as(f32, @floatFromInt(shown)) * rh + 4), .take_wheel = false });
    defer z.endCanvas();
    const p = c.painter;
    const cx = c.rect.x + 11;
    const top = c.rect.y + 2 - scroll;
    const yOf = struct {
        fn f(t: f32, h: f32, k: usize) f32 {
            return t + (@as(f32, @floatFromInt(k)) + 0.5) * h;
        }
    }.f;
    if (n > 1) p.line(.{ .x = cx, .y = @max(c.rect.y, yOf(top, rh, 0)) }, .{ .x = cx, .y = @min(c.rect.bottom(), yOf(top, rh, n - 1)) }, host.col(th.text_dim), 2);
    for (0..n) |k| {
        const y = yOf(top, rh, k);
        if (y < c.rect.y - rh or y > c.rect.bottom() + rh) continue;
        const ctr: zui.Vec2 = .{ .x = cx, .y = y };
        if (k == 0) {
            p.circle(ctr, 5.5, host.col(th.pane_bg));
            p.circleOutline(ctr, 5, host.col(th.accent), 2);
        }
        if (history.sel[k]) {
            p.circle(ctr, if (k == 0) 3 else 4.5, host.col(th.accent));
        } else if (k > 0) {
            p.circle(ctr, 4, host.col(th.pane_bg));
            p.circle(ctr, 3.5, host.col(th.text_dim));
        }
    }
    if (c.interaction.clicked) {
        const at = (c.mouse.y - 2 + scroll) / rh;
        if (at >= 0 and at < @as(f32, @floatFromInt(n))) {
            const k: usize = @intFromFloat(at);
            @memset(history.sel[0..n], false);
            history.sel[k] = true;
            pickCommit(n);
        }
    }
}

/// A form's operator from a button (New Branch..., Merge...): its form asks
/// for the name, as the menus' do.
fn formLater(id: []const u8) void {
    const i = ops.byId(id) orelse return;
    const was = ops.arg;
    ops.arg = "";
    defer ops.arg = was;
    ops.run(i); // (no argument, not scripted: the form opens)
}

// =============================================================================
// Collaboration (teamui.s .Lvs_collab; the session is cosync.zig's). Not in a
// session: the hint, Host | Host on LAN, Join..., Session Key... In one: "In a
// session. Peers: n", a row a peer (its colour, its name, Follow - "off" when
// it is the one followed; the followed one picked), "No other peers yet.",
// Let the AI Agent Join, Leave.
// =============================================================================
fn collabSection(z: *zui.Ui) void {
    const co = @import("cosync.zig");
    bkit.heading(z, "Collaboration");
    if (!co.on) {
        hint(z, "Not in a session: host one, or join one by address.");
        beginPair(z);
        if (opButton(z, "Host", "co.host")) runLater("co.host", "");
        if (button(z, "Host on LAN", "Others on the network can join", .fill)) runLater("co.host", "lan");
        z.endHorizontal();
        if (opButton(z, "Join...", "co.join")) formLater("co.join");
        if (opButton(z, "Session Key...", "co.key")) formLater("co.key");
        return;
    }
    text(z, fmt(z, "In a session. Peers: {d}", .{co.npr}));
    const n = @min(co.npr, 16);
    if (n > 0) {
        const pk = &peers;
        for (co.pr[0..n], 0..) |*p, k| pk.sel[k] = co.follow != 0 and p.peer == co.follow;
        var l = beginList(z, "peers", pk.sel[0..n], &pk.st, @min(n, 8));
        const bh = rowH(z) - 6;
        for (l.first..l.end) |k| {
            const p = &co.pr[k];
            const name = fmt(z, "{s}", .{std.mem.sliceTo(&p.name, 0)});
            z.beginRow(&l, k, .{ .label = name });
            // its colour, in the row's gutter
            const rr = l.row_rect;
            z.painter().circle(.{ .x = rr.x + 9, .y = rr.y + rr.h / 2 }, 4, host.col(p.color));
            const f = z.button("Follow", .{ .width = .px(70), .height = .px(bh) });
            z.tooltipRich(f, .{ .title = "Follow", .body = "Watch through this peer's view" });
            _ = z.endRow(&l);
            if (f.clicked or bkit.ring(f, "Follow"))
                runLater("co.follow", if (p.peer == co.follow) "off" else fmt(z, "{d}", .{k + 1}));
        }
        _ = endList(z, &l);
    } else hint(z, "No other peers yet.");
    if (button(z, "Let the AI Agent Join", "The agent edits as a peer: its changes show live and undo on their own", .fill)) runLater("co.agent", "on");
    if (opButton(z, "Leave", "co.leave")) runLater("co.leave", "");
}

// =============================================================================
// Live Link (teamui.s .Lvs_link; the link is link.zig's): "Serving the
// scene." / "Connected." / the hint, Serve | Connect..., Stop | Disconnect.
// =============================================================================
fn linkSection(z: *zui.Ui) void {
    bkit.heading(z, "Live Link");
    const lk = @import("link.zig");
    hint(z, if (lk.serving) "Serving the scene." else if (lk.mirroring()) "Connected." else "Not linked: serve this scene, or connect to another BeeModel.");
    beginPair(z);
    if (button(z, "Serve", "Other programs (an engine, another BeeModel) get this scene live", .fill)) runLater("link.serve", "");
    if (opButton(z, "Connect...", "link.connect")) formLater("link.connect");
    z.endHorizontal();
    beginPair(z);
    if (opButton(z, "Stop", "link.stop")) runLater("link.stop", "");
    if (opButton(z, "Disconnect", "link.disconnect")) runLater("link.disconnect", "");
    z.endHorizontal();
}

fn opAreaType() void {
    app.setActiveEditor(.versions);
}
fn isAreaType() bool {
    return app.activeEditor() == .versions;
}

pub const list = .{
    .{ "area.type_versions", ops.Impl{ .run = opAreaType, .check = isAreaType } },
};
