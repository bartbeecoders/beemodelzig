// Menus: the menu bar's drop-downs, context menus (area headers, the
// viewport, the outliner), one level of submenus, and the F3 command palette.
//
// In the main window Zui draws the menus (`client`, a client of zuihost.zig):
// the entries, their submenus, the keys and the pointer over them. What
// happens outside them stays here: a press on a bar title, sliding over the
// titles, a press elsewhere that closes the menu (and that a widget under it
// takes too). A menu in a panel's window of its own is still drawn here, by
// the code below `drawList`, until that window is Zui's (M7).
//
// As the original's menus.s: the pointer highlights an entry and opens its
// submenu, an entry runs on the button's release (any button: press on a
// title, drag down and let go works), and the release of the right-click
// that opened a context menu picks nothing unless the pointer moved 4 px.
// The submenu is on top where it overlaps its menu. A press anywhere else
// closes the menu (a left press on a widget also presses it). A greyed entry
// closes the menu and says why. Keyboard: F10 opens the bar, Alt+letter a
// menu by its letter, Up / Down move, Right opens a submenu (or the next menu
// of the bar), Left goes back, Enter runs, Esc closes one level; other keys
// go on to the app.
const std = @import("std");
const zui = @import("zui");
const host = @import("zuihost.zig");
const cat = @import("catalog.zig");
const ops = @import("ops.zig");
const app = @import("app.zig");
const ui = @import("ui.zig");
const gfx = @import("gfx.zig");

const Rect = gfx.Rect;
const Item = cat.Item;

pub const ROW_H = 24; // MENU_ITEM_H
const SEP_H = 9; // MENU_SEP_H
const DROP_W = 230; // MENU_DROP_W: the narrowest a menu is
const PAD_L = 26; // (lists) room for a tick

pub const titles = [_][]const u8{ "File", "Edit", "View", "Select", "Add", "Object", "Mesh", "Render", "AI", "Help" };
/// Alt+letter for each bar menu (AI is Alt+I: Add has A).
const letters = [_]u8{ 'f', 'e', 'v', 's', 'a', 'o', 'm', 'r', 'i', 'h' };

const Level = struct {
    items: []const Item,
    /// where it was asked to open (level 0); laid out into rect
    x: i32,
    y: i32,
    /// the highlighted entry (-1 none)
    sel: i32 = -1,
    rect: Rect = .{},
    /// rows scrolled away at the top (a menu taller than the window)
    scroll: i32 = 0,
};

const Menu = struct {
    lv: [2]Level,
    /// the entry of level 0 whose submenu is open (-1 none)
    sub: i32 = -1,
    /// the keyboard's level (0 / 1)
    focus: u8 = 0,
    bar: ?usize = null,
    area: i16 = -1,
    /// a context menu: the release of the press that opened it picks
    /// nothing unless the pointer moved on (mn_fresh, md_x / md_y)
    fresh: bool = false,
    md_x: i32 = 0,
    md_y: i32 = 0,
    /// (Zui's) where it opens: under this rect; to be opened in Zui's next
    /// frame; from the keyboard (its first entry lit); held by the button
    /// that opened it (its release over an entry picks it).
    anchor: Rect = .{},
    open_req: bool = true,
    kb: bool = false,
    held: bool = false,
};

pub var cur: ?Menu = null;
/// The panel's window a menu or list opened in (-1: the main one).
pub var owner: i32 = -1;
/// Set by the keyboard: scroll the highlighted row into view.
var ensure_visible = false;
/// The menu-bar titles, as the app laid them out this frame.
pub var bar_rects: [titles.len]Rect = undefined;
/// A left press outside closed the menu over a widget: the app runs the
/// press again so the widget takes it (the original's HIT_WIDGET).
pub var repass = false;
var repass_items: ?[*]const Item = null;
var repass_area: i16 = -1;
/// The widgets drawn under the open menu last frame (ui.record's buttons,
/// fields, toggles ...: the original's HIT_WIDGET; not the viewport, the
/// outliner's rows or other canvases, which a press only closes the menu over).
var under: [256]Rect = undefined;
var n_under: usize = 0;
const widget_kinds = [_][]const u8{ "button", "checkbox", "number", "enum", "text", "toggle", "colour", "icon", "editor", "tab", "fold", "section", "swatch", "chip", "override", "key", "keyrow", "step" };

fn noteWidgets() void {
    n_under = 0;
    for (ui.rec[0..ui.rec_n]) |*e| {
        if (n_under == under.len) break;
        for (widget_kinds) |k| {
            if (std.mem.eql(u8, e.kind, k)) {
                under[n_under] = e.r;
                n_under += 1;
                break;
            }
        }
    }
}

pub fn isOpen() bool {
    return cur != null or list != null;
}

// --- a list made at run time (object pickers) ---------------------------------

pub const List = struct {
    n: usize,
    label: *const fn (usize) []const u8,
    pick: *const fn (usize) void,
    checked: ?*const fn (usize) bool = null,
    x: i32,
    y: i32,
    sel: i32 = -1,
    scroll: i32 = 0,
};
pub var list: ?List = null;
var list_fresh = false;
/// (Zui's) the list is to be opened in Zui's next frame.
var list_open_req = false;

pub fn openList(l: List) void {
    cur = null;
    list = l;
    owner = @import("panelwin.zig").cur;
    list_fresh = true;
    list_open_req = true;
    app.dirty = true;
}

fn drawList0() void {
    const l = &(list orelse return);
    const th = ui.th;
    const cv = ui.cv;
    var w: i32 = 180;
    for (0..l.n) |k| w = @max(w, gfx.textWidth(l.label(k)) + PAD_L + 20);
    var r = Rect{ .x = l.x, .y = l.y, .w = w, .h = @as(i32, @intCast(l.n)) * ROW_H + 8 };
    if (r.right() > app.winW() - 4) r.x = @max(4, app.winW() - 4 - r.w);
    if (r.h > app.winH() - 8) r.h = app.winH() - 8;
    if (r.bottom() > app.winH() - 4) r.y = @max(4, app.winH() - 4 - r.h);
    cv.blend(.{ .x = r.x + 3, .y = r.y + 5, .w = r.w, .h = r.h }, th.shadow, 140);
    cv.fillRound(r, 6, th.drop_bg);
    cv.rectLine(r, th.drop_border);
    const full: i32 = @as(i32, @intCast(l.n)) * ROW_H + 8;
    if (ui.hit and ui.wheel != 0 and r.contains(ui.mx, ui.my)) l.scroll += @as(i32, @intFromFloat(ui.wheel * ROW_H));
    l.scroll = std.math.clamp(l.scroll, 0, @max(0, full - r.h));
    const old = cv.setClip(r.inset(1).intersect(cv.clip));
    defer cv.clip = old;
    var y = r.y + 4 - l.scroll;
    for (0..l.n) |k| {
        const ir = Rect{ .x = r.x + 4, .y = y, .w = r.w - 8, .h = ROW_H };
        y += ROW_H;
        if (ir.bottom() <= r.y or ir.y >= r.bottom()) continue;
        const lbl = l.label(k);
        ui.record("menuitem", lbl, ir, true);
        if (ui.inside(ir) and r.contains(ui.mx, ui.my) and ui.hit) l.sel = @intCast(k);
        const lit = l.sel == @as(i32, @intCast(k));
        if (lit) cv.fillRound(ir, 4, th.accent);
        const fg = if (lit) th.accent_text else th.text;
        cv.textIn(ir, PAD_L, lbl, fg);
        if (l.checked) |ch| {
            if (ch(k)) {
                const bx = ir.x + 8;
                const by = ir.y + @divTrunc(ir.h, 2);
                cv.thickLine(bx, by, bx + 3, by + 3, fg);
                cv.thickLine(bx + 3, by + 3, bx + 9, by - 4, fg);
            }
        }
        if (ui.hit and ui.inside(ir) and r.contains(ui.mx, ui.my) and ui.pressed & ui.LMB != 0 and !list_fresh) {
            ui.active = 0;
            const pick = l.pick;
            list = null;
            pick(k);
            app.dirty = true;
            return;
        }
    }
    if (ui.hit and ui.pressed != 0 and !r.contains(ui.mx, ui.my) and !list_fresh) list = null;
    if (ui.hit) list_fresh = false;
}

/// A bar menu under its title (the keyboard: its first entry lit).
pub fn openBar(i: usize, keyboard: bool) void {
    const r = bar_rects[i];
    cur = .{ .lv = .{ .{ .items = cat.bar[i], .x = r.x, .y = r.bottom() }, undefined }, .bar = i, .anchor = r, .kb = keyboard, .held = !keyboard and buttonHeld(), .md_x = ui.mx, .md_y = ui.my };
    owner = -1;
    list = null;
    if (keyboard) cur.?.lv[0].sel = 0;
    app.dirty = true;
}

/// A context menu at (x, y) for area `area` (-1: none), opened at the
/// pointer: the release of the press that opened it picks nothing unless the
/// pointer moves on (ctx_open_list).
pub fn openAt(items: []const Item, x: i32, y: i32, area: i16) void {
    cur = .{ .lv = .{ .{ .items = items, .x = x, .y = y }, undefined }, .area = area, .fresh = true, .md_x = ui.mx, .md_y = ui.my, .anchor = .{ .x = x, .y = y }, .held = buttonHeld() };
    owner = @import("panelwin.zig").cur;
    list = null;
    app.dirty = true;
}

/// A button is down (BeeModel's or, for a menu a Zui widget opened, Zui's).
fn buttonHeld() bool {
    return ui.down != 0 or host.get().input.mouse_down.count() > 0;
}

pub fn close() void {
    cur = null;
    list = null;
    app.dirty = true;
}

/// Alt+letter: open the bar menu with that letter.
pub fn openByLetter(ch: u8) bool {
    for (letters, 0..) |l, i| {
        if (l == ch) {
            openBar(i, true);
            return true;
        }
    }
    return false;
}

// --- entries ----------------------------------------------------------------

/// File > Open Recent: a submenu of the recent scenes (recent.s), one greyed
/// blank entry while there is none.
const rec_items = [_]Item{ .{ .rec = 0 }, .{ .rec = 1 }, .{ .rec = 2 }, .{ .rec = 3 }, .{ .rec = 4 }, .{ .rec = 5 }, .{ .rec = 6 }, .{ .rec = 7 } };

fn subItems(it: Item) ?[]const Item {
    return switch (it) {
        .sub => |s| cat.subs[s].items,
        .recent => rec_items[0..@max(1, @import("prefs.zig").recentCount())],
        else => null,
    };
}

fn recentPath(k: usize) []const u8 {
    const pr = @import("prefs.zig");
    if (k >= pr.recentCount()) return "";
    return pr.recent_files[k][0..pr.recent_files_len[k]];
}

fn itemLabel(it: Item) []const u8 {
    return switch (it) {
        .op => |sym| if (ops.bySym(sym)) |i| cat.entries[i].label else sym,
        .sub => |s| cat.subs[s].label,
        .recent => "Open Recent",
        .rec => |k| blk: {
            // the file's name, at most 63 bytes (rec_lbl)
            const p = recentPath(k);
            const b = std.fs.path.basename(p);
            break :blk b[0..@min(b.len, 63)];
        },
        .sep => "",
    };
}

fn keyText(it: Item, kb: []u8) []const u8 {
    return switch (it) {
        .op => |sym| if (ops.bySym(sym)) |i| fmtKey(i, kb) else "",
        else => "",
    };
}

/// fmt_key: an operator's shortcut as the original's menus write it
/// ("Ctrl+Shift+Alt+" then the key: "Num0", "Del", "PgUp", "Key?").
fn fmtKey(i: usize, buf: []u8) []const u8 {
    const keys = @import("keys.zig");
    if (keys.code_of[i] == 0) return "";
    return comboText(keys.code_of[i], keys.mods_of[i], buf);
}

fn comboText(code: u32, mods: u32, buf: []u8) []const u8 {
    const wl = @import("wayland.zig");
    const chars = "\x00\x001234567890-=\x00\x00QWERTYUIOP[]\x00\x00ASDFGHJKL;'`\x00\\ZXCVBNM,./\x00*";
    var one: [1]u8 = undefined;
    const name: []const u8 = if (code < chars.len and chars[code] != 0) blk: {
        one[0] = chars[code];
        break :blk &one;
    } else switch (code) {
        59...68 => ([_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10" })[code - 59],
        1 => "Esc",
        14 => "Backspace",
        15 => "Tab",
        28 => "Enter",
        57 => "Space",
        87 => "F11",
        88 => "F12",
        102 => "Home",
        103 => "Up",
        104 => "PgUp",
        105 => "Left",
        106 => "Right",
        107 => "End",
        108 => "Down",
        109 => "PgDn",
        110 => "Ins",
        111 => "Del",
        74 => "Num-",
        78 => "Num+",
        79 => "Num1",
        80 => "Num2",
        81 => "Num3",
        75 => "Num4",
        76 => "Num5",
        77 => "Num6",
        71 => "Num7",
        72 => "Num8",
        73 => "Num9",
        82 => "Num0",
        83 => "Num.",
        96 => "NumEnter",
        98 => "Num/",
        else => "Key?",
    };
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{
        if (mods & wl.MOD_CTRL != 0) "Ctrl+" else "",
        if (mods & wl.MOD_SHIFT != 0) "Shift+" else "",
        if (mods & wl.MOD_ALT != 0) "Alt+" else "",
        name,
    }) catch "";
}

/// Why an entry cannot run now (null: it can; submenus always can).
fn why(it: Item) ?[]const u8 {
    return switch (it) {
        .op => |sym| if (ops.bySym(sym)) |i| ops.reason(i) else ops.not_ported,
        .rec => |k| if (k >= @import("prefs.zig").recentCount()) "no recent scenes yet" else null,
        else => null,
    };
}

// --- layout (mn_layout) ---------------------------------------------------------

/// text_width as the original measures: the advances rounded to the
/// nearest (gfx.textWidth rounds up, a pixel more for some labels).
pub fn textW(s: []const u8) i32 {
    const tx = @import("text.zig");
    if (!tx.loaded) return gfx.textWidth(s);
    var pen: f32 = 0;
    var i: usize = 0;
    while (i < s.len) pen += tx.glyph(gfx.face, tx.nextCp(s, &i)).adv;
    return @intFromFloat(@floor(pen / tx.ui_scale + 0.5));
}

/// list_w: MENU_DROP_W, or wider for the longest label with its shortcut.
fn listW(items: []const Item) i32 {
    var w: i32 = DROP_W;
    var kb: [40]u8 = undefined;
    for (items) |it| {
        if (it == .sep) continue;
        var e = textW(itemLabel(it)) + 28 + 34;
        const ks = keyText(it, &kb);
        if (ks.len > 0) e += textW(ks) - 34 + 24 + 12;
        w = @max(w, e);
    }
    return w;
}

/// list_h: the list's height with its padding.
fn listH(items: []const Item) i32 {
    var h: i32 = 8;
    for (items) |it| h += if (it == .sep) SEP_H else ROW_H;
    return h;
}

/// list_y: the entry's offset from the list's top.
fn listY(items: []const Item, idx: usize) i32 {
    var y: i32 = 4;
    for (items[0..idx]) |it| y += if (it == .sep) SEP_H else ROW_H;
    return y;
}

/// list_at: the entry at offset dy from the top (-1: the padding, a separator).
fn listAt(items: []const Item, dy: i32) i32 {
    if (dy < 4) return -1;
    var y: i32 = 4;
    for (items, 0..) |it, i| {
        y += if (it == .sep) SEP_H else ROW_H;
        if (dy < y) return if (it == .sep) -1 else @intCast(i);
    }
    return -1;
}

/// The box of a list of height h at y, kept above the window's bottom (and,
/// unlike the original, whose top then went off the window, scrolling when
/// it is taller than the window).
fn fitV(y0: i32, h: i32) [2]i32 {
    const wh = app.winH();
    var y = y0;
    if (y > wh - h - 2) y = wh - h - 2;
    if (y < 0) return .{ 0, @max(ROW_H + 8, wh - 2) };
    return .{ y, h };
}

/// Lay out the open menu (drop_*) and its submenu (l1_*).
fn layout(m: *Menu) void {
    const ww = app.winW();
    const l0 = &m.lv[0];
    const w = listW(l0.items);
    var x = @min(l0.x, ww - w);
    if (x < 0) x = 0;
    const v = fitV(l0.y, listH(l0.items));
    l0.rect = .{ .x = x, .y = v[0], .w = w, .h = v[1] };
    l0.scroll = std.math.clamp(l0.scroll, 0, listH(l0.items) - v[1]);
    if (m.sub < 0) return;
    const l1 = &m.lv[1];
    const w1 = listW(l1.items);
    const v1 = fitV(l0.rect.y + listY(l0.items, @intCast(m.sub)) - l0.scroll - 4, listH(l1.items));
    var x1 = x + w - 3; // right of the menu, or left of it
    if (x1 + w1 > ww) {
        x1 = x - w1 + 3;
        if (x1 < 0) x1 = 0;
    }
    l1.rect = .{ .x = x1, .y = v1[0], .w = w1, .h = v1[1] };
    l1.scroll = std.math.clamp(l1.scroll, 0, listH(l1.items) - v1[1]);
}

/// What is under the pointer (mn_hit): level 1 (the submenu, on top), 0, or
/// -1 (not the menu); the entry, -1 for the padding and separators.
const Hit = struct { level: i8 = -1, idx: i32 = -1 };

fn hitTest(m: *const Menu, px: i32, py: i32) Hit {
    if (m.sub >= 0) {
        const r = m.lv[1].rect;
        if (r.contains(px, py)) return .{ .level = 1, .idx = listAt(m.lv[1].items, py - r.y + m.lv[1].scroll) };
    }
    const r = m.lv[0].rect;
    if (r.contains(px, py)) return .{ .level = 0, .idx = listAt(m.lv[0].items, py - r.y + m.lv[0].scroll) };
    return .{};
}

// --- running ----------------------------------------------------------------

/// Open entry idx's submenu (mn_sub), nothing lit in it.
fn openSub(m: *Menu, idx: usize) void {
    m.sub = @intCast(idx);
    m.lv[1] = .{ .items = subItems(m.lv[0].items[idx]).?, .x = 0, .y = 0 };
    layout(m);
}

/// open_sub_kb: the highlighted entry's submenu, the keyboard in it on its first.
fn openSubKb(m: *Menu) void {
    openSub(m, @intCast(m.lv[0].sel));
    m.focus = 1;
    m.lv[1].sel = 0;
}

/// An entry chosen (mn_release without the fresh test): a submenu opens and
/// stays; anything else closes the menu and runs (or says why it cannot).
fn choose(level: u8, idx: usize) void {
    const m = &(cur orelse return);
    const it = m.lv[level].items[idx];
    if (it == .sep) return;
    if (level == 0 and subItems(it) != null) {
        openSub(m, idx);
        m.lv[0].sel = @intCast(idx);
        m.lv[1].sel = -1;
        app.dirty = true;
        return;
    }
    const area = m.area;
    close();
    runItem(it, area);
}

/// Run a chosen entry (the menu closed): its operator, or the recent scene;
/// a greyed one says why.
fn runItem(it: Item, area: i16) void {
    switch (it) {
        .op => |sym| {
            const i = ops.bySym(sym) orelse {
                app.toast(.warn, "{s}: {s}", .{ sym, ops.not_ported });
                return;
            };
            if (ops.reason(i)) |r| {
                app.toast(.warn, "{s}: {s}", .{ cat.entries[i].label, r });
                return;
            }
            if (area >= 0) app.setActiveArea(area);
            ops.run(i);
        },
        .rec => |k| {
            if (why(it)) |r| {
                app.toast(.warn, ": {s}", .{r});
                return;
            }
            @import("files.zig").guarded(.recent, recentPath(k));
        },
        else => {},
    }
}

/// The pointer moved (mn_hover): it highlights, a submenu entry opens its
/// submenu and any other entry of the menu closes the open one.
fn hover(m: *Menu, h: Hit) void {
    if (h.level == 1) {
        if (h.idx != m.lv[1].sel) {
            m.lv[1].sel = h.idx;
            m.focus = 1;
            app.dirty = true;
        }
    } else if (h.level == 0 and h.idx >= 0) {
        if (h.idx == m.lv[0].sel) return;
        m.lv[0].sel = h.idx;
        m.focus = 0;
        app.dirty = true;
        if (subItems(m.lv[0].items[@intCast(h.idx)]) != null) {
            openSub(m, @intCast(h.idx));
            m.lv[1].sel = -1;
        } else m.sub = -1;
    }
}

/// A button let go (mn_release).
fn release(m: *Menu, h: Hit) void {
    if (m.fresh) {
        m.fresh = false;
        if (@abs(ui.mx - m.md_x) + @abs(ui.my - m.md_y) < 4) return;
    }
    if (h.level >= 0 and h.idx >= 0) choose(@intCast(h.level), @intCast(h.idx));
}

/// A button pressed while the menu is open: in it nothing (entries act on
/// release); on a bar title that menu (its own: closes); elsewhere it closes.
fn press(m: *Menu, h: Hit) void {
    if (h.level >= 0) return;
    if (owner < 0) {
        for (bar_rects, 0..) |r, i| {
            if (!r.contains(ui.mx, ui.my)) continue;
            if (m.bar != null and m.bar.? == i) close() else openBar(i, false);
            return;
        }
    }
    const items = m.lv[0].items.ptr;
    const area = m.area;
    close();
    // a left press on a widget: it takes the press too (an area's editor
    // type: its own menu closes, another area's opens)
    if (ui.pressed & ui.LMB != 0) {
        for (under[0..n_under]) |r| {
            if (r.contains(ui.mx, ui.my)) {
                repass = true;
                repass_items = items;
                repass_area = area;
                break;
            }
        }
    }
}

/// After the app ran a press again (repass): the menu that press closed
/// does not open again (an area's editor type menu, clicked again).
pub fn afterRepass() void {
    repass = false;
    if (cur) |m| {
        if (m.lv[0].items.ptr == repass_items and m.area == repass_area and m.lv[0].items.ptr == &cat.items_area) close();
    }
}

// --- drawing (and the hit pass's input) -----------------------------------------

/// fill_rrect_a: the original's rounded rectangle, corner pixels by their
/// coverage of the quarter circles, alpha 1..256.
fn rrect(r0: Rect, col: u32, rad0: i32, alpha: u32) void {
    const cv0 = ui.cv;
    if (!cv0.enabled or r0.w <= 0 or r0.h <= 0) return;
    var p = cv0.pixels();
    const r = cv0.pxRect(r0);
    const clip = cv0.pxRect(cv0.clip).intersect(p.full());
    var rad = cv0.toPx(rad0);
    rad = @min(rad, @divTrunc(r.w, 2));
    rad = @min(rad, @divTrunc(r.h, 2));
    if (rad < 0) rad = 0;
    const x1 = r.x + r.w;
    const y1 = r.y + r.h;
    var y = @max(r.y, clip.y);
    while (y < @min(y1, clip.bottom())) : (y += 1) {
        const dy = @max(r.y + rad - y, y - (y1 - rad - 1));
        var x = @max(r.x, clip.x);
        while (x < @min(x1, clip.right())) : (x += 1) {
            var a: u32 = alpha;
            if (dy > 0) {
                const dx = @max(r.x + rad - x, x - (x1 - rad - 1));
                if (dx > 0) {
                    const fx = @as(f32, @floatFromInt(dx)) - 0.5;
                    const fy = @as(f32, @floatFromInt(dy)) - 0.5;
                    const d = @sqrt(fx * fx + fy * fy);
                    const cov = std.math.clamp(@as(f32, @floatFromInt(rad)) - d + 0.5, 0, 1);
                    a = @intFromFloat(cov * @as(f32, @floatFromInt(alpha)));
                    if (a == 0) continue;
                }
            }
            const o: usize = @intCast(y * p.w + x);
            p.px[o] = if (a >= 256) col else gfx.mix(p.px[o], col, a);
        }
    }
}

/// popup_frame: the shadow (draw_shadow, spread 6), the border, the inside.
fn frame(r: Rect) void {
    const th = ui.th;
    var i: i32 = 6;
    while (i > 0) : (i -= 1) rrect(.{ .x = r.x - i, .y = r.y + 2 - i, .w = r.w + 2 * i, .h = r.h + 2 * i }, th.shadow, i + 4, 23);
    rrect(r, th.drop_border, 6, 256);
    rrect(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h - 2 }, th.drop_bg, 5, 256);
}

/// draw_list: one level, `lit` highlighted and `open` lit as open.
fn drawList(m: *Menu, level: u8) void {
    const th = ui.th;
    const cv = ui.cv;
    const lv = &m.lv[level];
    const r = lv.rect;
    const lit = lv.sel;
    const open: i32 = if (level == 0) m.sub else -1;
    frame(r);
    const full = listH(lv.items);
    const old_clip = cv.setClip(r.intersect(cv.clip));
    defer cv.clip = old_clip;
    if (full > r.h) {
        // a scroll bar (a menu taller than the window)
        const bh = @max(20, @divTrunc(r.h * r.h, full));
        const by = r.y + @divTrunc((r.h - bh) * lv.scroll, full - r.h);
        cv.fillRound(.{ .x = r.right() - 5, .y = by, .w = 3, .h = bh }, 1, th.text_off);
    }
    var y = r.y + 4 - lv.scroll;
    var kb: [40]u8 = undefined;
    for (lv.items, 0..) |it, i| {
        if (it == .sep) {
            cv.fill(.{ .x = r.x + 8, .y = y + 4, .w = r.w - 16, .h = 1 }, th.sep);
            y += SEP_H;
            continue;
        }
        defer y += ROW_H;
        if (y + ROW_H <= r.y or y >= r.bottom()) continue;
        const ii: i32 = @intCast(i);
        const label = itemLabel(it);
        const w = why(it);
        ui.record("menuitem", label, .{ .x = r.x, .y = y, .w = r.w, .h = ROW_H }, w == null);
        if (ii == lit or ii == open) {
            rrect(.{ .x = r.x + 3, .y = y, .w = r.w - 6, .h = ROW_H }, th.hover, 4, 256);
            cv.fill(.{ .x = r.x + 3, .y = y + 5, .w = 3, .h = ROW_H - 10 }, th.accent);
        }
        const fg = if (w != null) th.text_off else th.text;
        if (it == .op) if (ops.bySym(it.op)) |oi| if (ops.checked(oi) orelse false) cv.icon(r.x + 9, y + 4, .check, th.accent);
        _ = cv.text(r.x + 28, y + 4, label, fg);
        if (subItems(it) != null) {
            cv.icon(r.x + r.w - 22, y + 4, .chevron_right, th.text_dim);
        } else {
            const ks = keyText(it, &kb);
            if (ks.len > 0) _ = cv.text(r.x + r.w - 12 - textW(ks), y + 4, ks, if (w != null) th.text_off else th.text_dim);
        }
        // the tooltip: what it does, or why it is greyed
        const ir = Rect{ .x = r.x, .y = y, .w = r.w, .h = ROW_H };
        if (ir.contains(ui.mx, ui.my) and hitTest(m, ui.mx, ui.my).level == @as(i8, @intCast(level))) {
            const iid = ui.id(@src(), @as(usize, level) * 1000 + i);
            switch (it) {
                .op => |sym| if (ops.bySym(sym)) |oi| ui.tipBeside(iid, r, label, cat.entries[oi].doc, ops.reason(oi)),
                .rec => ui.tipBeside(iid, r, label, "Open this recent scene", w),
                else => {},
            }
        }
    }
}

/// Draw the open menu; on the hit pass, also handle its mouse input.
pub fn draw() void {
    if (list != null) return if (owner < 0) listOutside() else drawList0();
    const m = &(cur orelse return);
    if (owner < 0) return outside(m);
    defer if (!ui.hit) {
        ensure_visible = false;
    };
    layout(m);
    if (ui.hit and ui.layer == ui.hot_layer) {
        const h = hitTest(m, ui.mx, ui.my);
        if (ui.wheel != 0 and h.level >= 0) {
            // (a menu taller than the window scrolls)
            const lv = &m.lv[@intCast(h.level)];
            lv.scroll += @as(i32, @intFromFloat(ui.wheel * ROW_H));
            layout(m);
        }
        if (ui.pressed != 0) {
            press(m, h);
            if (cur == null) return;
        } else if (ui.released != 0) {
            release(m, h);
            if (cur == null) return;
        } else if (ui.dx != 0 or ui.dy != 0) {
            // sliding onto another bar title while a menu is open switches
            if (h.level < 0 and owner < 0) {
                for (bar_rects, 0..) |r, i| {
                    if (r.contains(ui.mx, ui.my) and (m.bar == null or m.bar.? != i)) {
                        openBar(i, false);
                        return;
                    }
                }
            }
            hover(m, h);
        }
        layout(m);
    }
    if (ensure_visible) {
        for (0..2) |k| {
            if (k == 1 and m.sub < 0) break;
            const lv = &m.lv[k];
            if (lv.sel < 0) continue;
            const sy = listY(lv.items, @intCast(lv.sel));
            if (sy - lv.scroll < 0) lv.scroll = sy - 4;
            if (sy + ROW_H - lv.scroll > lv.rect.h) lv.scroll = sy + ROW_H + 4 - lv.rect.h;
        }
        layout(m);
    }
    if (ui.cv.enabled) {
        if (owner < 0) noteWidgets() else n_under = 0;
    }
    drawList(m, 0);
    if (m.sub >= 0) drawList(m, 1);
}

/// A key while a menu is open (mn_key) -> true if the menu used it; other
/// keys go on to the app (Tab, shortcuts) with the menu still open.
pub fn key(code: u32) bool {
    if (list != null and owner < 0) return zuiKey(code);
    if (list) |*l| {
        switch (code) {
            ui.KEY.ESC => list = null,
            ui.KEY.UP => l.sel = @max(0, l.sel - 1),
            ui.KEY.DOWN => l.sel = @min(@as(i32, @intCast(l.n)) - 1, l.sel + 1),
            ui.KEY.ENTER, ui.KEY.KPENTER => if (l.sel >= 0) {
                const pick = l.pick;
                const k: usize = @intCast(l.sel);
                list = null;
                pick(k);
            },
            else => {},
        }
        app.dirty = true;
        return true;
    }
    const m = &(cur orelse return false);
    const K = ui.KEY;
    if (owner < 0) return zuiKey(code);
    if (m.sub < 0) m.focus = 0;
    layout(m);
    switch (code) {
        K.ESC => {
            if (m.sub >= 0 and m.focus != 0) {
                m.sub = -1; // back to the menu
                m.focus = 0;
            } else close();
        },
        K.UP, K.DOWN => {
            const lv = &m.lv[m.focus];
            const n: i32 = @intCast(lv.items.len);
            var s = lv.sel;
            const dir: i32 = if (code == K.UP) -1 else 1;
            while (true) {
                s += dir;
                if (s <= -1) s = n - 1;
                if (s >= n) s = 0;
                if (lv.items[@intCast(s)] != .sep) break;
            }
            lv.sel = s;
        },
        K.RIGHT => if (m.focus == 0) {
            if (m.lv[0].sel >= 0 and subItems(m.lv[0].items[@intCast(m.lv[0].sel)]) != null) {
                openSubKb(m);
            } else if (m.bar) |b| openBar((b + 1) % titles.len, true);
        },
        K.LEFT => {
            if (m.focus != 0) {
                m.sub = -1;
                m.focus = 0;
            } else if (m.bar) |b| openBar((b + titles.len - 1) % titles.len, true);
        },
        K.ENTER, K.KPENTER => {
            const lv = &m.lv[m.focus];
            if (lv.sel >= 0) {
                if (m.focus == 0 and subItems(lv.items[@intCast(lv.sel)]) != null) {
                    openSubKb(m);
                } else {
                    // (the original's first Enter after a right-click did
                    // nothing - its release test - a bug not kept)
                    m.fresh = false;
                    choose(m.focus, @intCast(lv.sel));
                }
            }
        },
        else => return false,
    }
    ensure_visible = true;
    app.dirty = true;
    return true;
}

// --- Zui's menus (the main window) ------------------------------------------

/// The open menu of the main window, drawn by Zui over everything.
pub const client: host.Client = .{
    .visible = zuiShown,
    .describe = describe,
};

fn zuiShown() bool {
    return palette or ((cur != null or list != null) and owner < 0);
}

/// Zui's menu or list: its keys (Esc closes one level, Left / Right walk
/// the bar); the rest go on to the app.
fn zuiKey(code: u32) bool {
    const K = ui.KEY;
    const zk: zui.Key = switch (code) {
        K.ESC => .escape,
        K.UP => .up,
        K.DOWN => .down,
        K.LEFT => .left,
        K.RIGHT => .right,
        K.ENTER, K.KPENTER => .enter,
        else => return false,
    };
    host.pressKey(zk);
    return true;
}

/// A list's hit pass outside it (over it, the events are Zui's): a press
/// closes it, but for the one that opened it.
fn listOutside() void {
    if (!ui.hit) return;
    if (ui.pressed != 0 and !list_fresh) {
        list = null;
        app.dirty = true;
    }
    list_fresh = false;
}

/// After Zui's frame (its widgets in the record too): the widgets under the
/// open menu, which a left press that closes it also presses.
pub fn afterZuiFrame() void {
    if (zuiShown() and ui.cv.enabled) noteWidgets();
}

/// The hit pass's part: what the pointer does outside Zui's menu (over it,
/// the events are Zui's). A press: on a bar title, that menu (its own:
/// closed); elsewhere, closed (a left press on a widget takes it too).
/// Sliding over the bar's titles switches menus.
fn outside(m: *Menu) void {
    if (!ui.hit or ui.layer != ui.hot_layer) return;
    if (ui.pressed != 0) {
        press(m, .{});
    } else if ((ui.dx != 0 or ui.dy != 0) and m.bar != null) {
        for (bar_rects, 0..) |r, i| {
            if (r.contains(ui.mx, ui.my) and m.bar.? != i) {
                openBar(i, false);
                return;
            }
        }
    }
}

/// The menu's popup name: one per list of entries, so each sizes itself.
fn popupName(items: []const Item, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "##menu{x}", .{@intFromPtr(items.ptr)}) catch "##menu";
}

/// BeeModel's look for Zui's menus: its drop-down colours and border, rows
/// 24 high. Pops with `z.popStyles(6)`.
fn pushLook(z: *zui.Ui) void {
    const th = ui.th;
    z.pushColor(.popup, host.col(th.drop_bg));
    z.pushColor(.border, host.col(th.drop_border));
    z.pushColor(.button_hovered, host.col(th.hover));
    z.pushMetric(.border_width, 1);
    z.pushMetric(.item_spacing, .{ .x = 6, .y = 0 });
    z.pushMetric(.frame_padding, .{ .x = 14, .y = @max(0, (ROW_H - z.textSize("").y) / 1.2) });
}

fn describe(z: *zui.Ui) void {
    if (palette) describePalette(z);
    if (owner >= 0) return;
    if (list != null) return describeList(z);
    const m = &(cur orelse return);
    // A greyed entry picked: the menu closes and says why.
    if (z.disabledClick()) |r| {
        app.toast(.warn, "{s}: {s}", .{ grey[0..grey_len], r });
        z.closeAllPopups();
        close();
        return;
    }
    var nb: [32]u8 = undefined;
    const name = popupName(m.lv[0].items, &nb);
    if (m.open_req) {
        m.open_req = false;
        z.openPopupAt(name, host.zr(m.anchor));
        if (m.kb) z.highlightFirst(0);
        if (m.held) z.holdMenu(.{ .x = @floatFromInt(m.md_x), .y = @floatFromInt(m.md_y) });
    }
    if (m.bar) |b| z.externalBar(@intCast(b), titles.len);
    pushLook(z);
    defer z.popStyles(6);
    if (z.beginPopupMenuSized(name, DROP_W)) {
        entries(z, m.lv[0].items);
        z.endMenu();
    } else if (cur != null and cur.?.lv[0].items.ptr == m.lv[0].items.ptr) {
        // closed by Zui: Esc, a press outside it, an entry picked
        cur = null;
        app.dirty = true;
    }
    if (z.takeBarRequest()) |b| {
        openBar(b, true);
        z.requestRedraw(); // (opened in the next frame)
    }
}

/// A list made at run time (openList), as a Zui menu: an entry picked on a
/// click or Enter, a tick on the checked ones.
fn describeList(z: *zui.Ui) void {
    const l = list.?;
    const name = "##list";
    if (list_open_req) {
        list_open_req = false;
        z.openPopupAt(name, host.zr(.{ .x = l.x, .y = l.y }));
    }
    pushLook(z);
    defer z.popStyles(6);
    if (!z.beginPopupMenuSized(name, 180)) {
        // closed by Zui: Esc, a press outside it
        list = null;
        app.dirty = true;
        return;
    }
    defer z.endMenu();
    for (0..l.n) |k| {
        z.pushIdInt(k);
        defer z.popId();
        if (z.menuItem(l.label(k), .{ .checked = if (l.checked) |c| c(k) else null })) {
            list = null;
            l.pick(k);
            app.dirty = true;
            return;
        }
    }
}

/// The greyed entry lit (by the pointer or the keys): its name, for why it
/// is greyed if it is picked (Zui says so in the next frame).
var grey: [64]u8 = undefined;
var grey_len: usize = 0;

fn noteGrey(z: *zui.Ui, label: []const u8) void {
    const lvl = z.popup_nesting -| 1;
    const idx = z.menu_state.count[lvl] -| 1;
    if (z.menu_state.highlight[lvl] != idx) return;
    grey_len = @min(label.len, grey.len);
    @memcpy(grey[0..grey_len], label[0..grey_len]);
}

/// A list's entries as Zui's menu items; a submenu's in its own popup.
fn entries(z: *zui.Ui, items: []const Item) void {
    var kb: [40]u8 = undefined;
    for (items, 0..) |it, k| {
        z.pushIdInt(k);
        defer z.popId();
        if (it == .sep) {
            // (SEP_H: the line in the middle of 9)
            z.spacer(.px(4));
            z.menuSeparator();
            z.spacer(.px(4));
            continue;
        }
        const label = itemLabel(it);
        if (subItems(it)) |sub| {
            if (z.beginSubmenu(label, .{})) {
                entries(z, sub);
                z.endMenu();
            }
            continue;
        }
        const oi: ?usize = if (it == .op) ops.bySym(it.op) else null;
        const tip: []const u8 = if (oi) |i| cat.entries[i].doc else if (it == .rec) "Open this recent scene" else "";
        defer if (why(it) != null) noteGrey(z, label);
        if (z.menuItem(label, .{
            .shortcut = keyText(it, &kb),
            .checked = if (oi) |i| ops.checked(i) else null,
            .disabled = why(it),
            .tooltip = tip,
        })) {
            const area = (cur orelse return).area;
            close();
            runItem(it, area);
            return;
        }
    }
}

// --- F3: the command palette ---------------------------------------------
//
// Zui's command palette (part of `client`) over every operator in the
// catalog: BeeModel's ranking (every word of the query in the label, the
// id or the description; what can run first), the id muted after the
// label, the shortcut at the right; a greyed one says why.

pub var palette: bool = false;
/// The palette's commands: every shown operator, by label (`pal_idx`: its
/// catalog entry), their shortcuts' text.
var pal_cmds: [ops.N]zui.PaletteCommand = undefined;
var pal_idx: [ops.N]u16 = undefined;
var pal_keys: [ops.N][40]u8 = undefined;
var pal_n: usize = 0;


pub fn openPalette() void {
    palette = true;
    close();
    app.dirty = true;
}

pub fn closePalette() void {
    palette = false;
    app.dirty = true;
}

fn containsI(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// How well entry e matches every word of q (lower is better), or null.
fn score(e: *const cat.Entry, q: []const u8) ?u32 {
    var total: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, q, ' ');
    while (it.next()) |w| {
        if (containsI(e.label, w)) |pos| {
            total += if (pos == 0) 0 else if (e.label[pos - 1] == ' ') 1 else 2;
        } else if (containsI(e.id, w) != null) {
            total += 3;
        } else if (containsI(e.doc, w) != null) {
            total += 5;
        } else return null;
    }
    return total;
}

/// The palette's ranking (Zui's: higher is better).
fn palScore(q: []const u8, k: usize) ?f32 {
    const i = pal_idx[k];
    var sc = score(&cat.entries[i], q) orelse return null;
    if (ops.reason(i) != null) sc += 100; // what can run comes first
    return -@as(f32, @floatFromInt(sc));
}

/// The commands, by label (once); what can run and the keys, each frame.
fn palCommands() []const zui.PaletteCommand {
    if (pal_n == 0) {
        for (&cat.entries, 0..) |*e, i| {
            if (e.hidden) continue;
            pal_idx[pal_n] = @intCast(i);
            pal_n += 1;
        }
        std.sort.pdq(u16, pal_idx[0..pal_n], {}, struct {
            fn lt(_: void, a: u16, b: u16) bool {
                return std.mem.lessThan(u8, cat.entries[a].label, cat.entries[b].label);
            }
        }.lt);
    }
    for (pal_idx[0..pal_n], 0..) |i, k| {
        const e = &cat.entries[i];
        pal_cmds[k] = .{ .label = e.label, .detail = e.id, .shortcut = ops.keyLabel(i, &pal_keys[k]), .disabled = ops.reason(i), .tooltip = e.doc };
    }
    return pal_cmds[0..pal_n];
}

/// The palette's lit command: the one its keys or pointer are on, in the
/// order Zui ranks them (score, then the order given).
fn palLit(z: *const zui.Ui) []const u8 {
    const st = &z.menu_state.palette;
    const q = st.query[0..st.len];
    var best: [ops.N]u16 = undefined;
    var sc: [ops.N]f32 = undefined;
    var n: usize = 0;
    for (0..pal_n) |k| {
        sc[k] = palScore(q, k) orelse continue;
        best[n] = @intCast(k);
        n += 1;
    }
    std.sort.pdq(u16, best[0..n], &sc, struct {
        fn lt(s: *[ops.N]f32, a: u16, b: u16) bool {
            return if (s[a] != s[b]) s[a] > s[b] else a < b;
        }
    }.lt);
    if (st.highlight >= n) return "";
    return cat.entries[pal_idx[best[st.highlight]]].label;
}

fn describePalette(z: *zui.Ui) void {
    // a greyed command picked: why (the palette stays)
    if (z.disabledClick()) |r| app.toast(.warn, "{s}: {s}", .{ palLit(z), r });
    const th = ui.th;
    z.pushColor(.popup, host.col(th.drop_bg));
    z.pushColor(.border, host.col(th.accent));
    z.pushColor(.button_hovered, host.col(th.hover));
    z.pushMetric(.border_width, 1);
    defer z.popStyles(4);
    const w: f32 = @floatFromInt(@min(680, app.winW() - 40));
    if (z.commandPalette("##f3", &palette, palCommands(), .{ .width = w, .score = palScore, .hint = "Search every command..." })) |k| {
        const i = pal_idx[k];
        closePalette();
        ops.run(i);
    }

    if (!palette) app.dirty = true;
}

/// A key the app had while the palette is open (before Zui's search field
/// has the focus): Zui's.
pub fn paletteKey(code: u32) void {
    host.feedKey(code);
}

/// The hit pass, after Zui's frame: a press outside the palette closes it
/// (over it, the press is Zui's).
pub fn drawPalette() void {
    if (!palette) return;
    if (ui.hit and ui.pressed != 0) closePalette();
}

// --- tests ------------------------------------------------------------------------

test "list geometry as the original's (list_h, list_y, list_at)" {
    const t = std.testing;
    const items = &cat.items_file;
    try t.expectEqual(@as(i32, 275), listH(items));
    for (items, 0..) |it, i| {
        const y = listY(items, i);
        if (it == .sep) {
            try t.expectEqual(@as(i32, -1), listAt(items, y + 4));
            continue;
        }
        try t.expectEqual(@as(i32, @intCast(i)), listAt(items, y));
        try t.expectEqual(@as(i32, @intCast(i)), listAt(items, y + ROW_H - 1));
    }
    try t.expectEqual(@as(i32, -1), listAt(items, 3)); // (the top padding)
    try t.expectEqual(@as(i32, -1), listAt(items, 275 - 2)); // (the bottom's)
}

test "the submenu is on top where it overlaps its menu" {
    const t = std.testing;
    var m = Menu{ .lv = .{
        .{ .items = &cat.items_file, .x = 4, .y = 56, .rect = .{ .x = 4, .y = 56, .w = 230, .h = 275 } },
        .{ .items = cat.subs[0].items, .x = 0, .y = 0, .rect = .{ .x = 231, .y = 185, .w = 230, .h = 152 } },
    }, .sub = 6 };
    // the menu's Screenshot row, 3 px under the submenu's edge: Import glTF
    const h = hitTest(&m, 232, 260);
    try t.expectEqual(@as(i8, 1), h.level);
    try t.expectEqual(@as(i32, 2), h.idx);
    m.sub = -1;
    try t.expectEqual(@as(i8, 0), hitTest(&m, 232, 260).level);
    try t.expectEqual(@as(i8, -1), hitTest(&m, 300, 260).level);
}

test "shortcuts as the original's menus write them" {
    const t = std.testing;
    var kb: [40]u8 = undefined;
    // (Camera to View, Save As, Hide, Delete, Wireframe: the catalog's keys)
    try t.expectEqualStrings("Ctrl+Alt+Num0", comboText(82, 12, &kb));
    try t.expectEqualStrings("Ctrl+Shift+S", comboText(31, 5, &kb));
    try t.expectEqualStrings("Shift+Alt+H", comboText(35, 9, &kb));
    try t.expectEqualStrings("Del", comboText(111, 0, &kb));
    try t.expectEqualStrings("Z", comboText(44, 0, &kb));
}
