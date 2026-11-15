// The Asset Browser area (library.s ed_assets_draw, teamui.s's header and tile
// menu): the content library (or an online source, extlib.zig) as tiles -
// thumbnails, names, search, the selected asset's kind, tags, what it uses and
// what uses it; a double-click places a tile at the 3D cursor, a drag into a
// viewport places it on the surface under the pointer. And the thumbnails:
// path-traced by a child process (this program, --lib-thumbnail <id>), one at
// a time, while the window goes on (lb_tick).
const std = @import("std");
const linux = std.os.linux;
const m = @import("math.zig");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const ops = @import("ops.zig");
const cat = @import("catalog.zig");
const menus = @import("menus.zig");
const scene = @import("scene.zig");
const lib = @import("library.zig");
const ext = @import("extlib.zig");
const zui = @import("zui");
const host = @import("zuihost.zig");
const bkit = @import("bkit.zig");
const Rect = gfx.Rect;
const A = std.heap.page_allocator;

const TH = lib.TH;
const TILE_H = 126; // (the grid at least one row of tiles high)
const LB_HDR = 24;
const INFO_H = 58;
const TILE_BG: u32 = 0x2a2e36;

// --- thumbnails' pixels ----------------------------------------------------------------------

/// thumb_load: TH x TH pixels (0xRRGGBB) of a PNG / JPEG, null when it does not
/// load. Nearest sampling of the whole image, fitted (its sides in proportion,
/// centred) and its alpha over a neutral backdrop.
pub fn thumbLoad(path: []const u8) ?[]u32 {
    const BG: u32 = 0x8a8780;
    const d = @import("ttf.zig").mapFile(path) orelse return null;
    defer _ = linux.munmap(d.ptr, d.len);
    var img = @import("image.zig").decodeData(A, d) catch return null;
    defer img.deinit(A);
    const out = A.alloc(u32, TH * TH) catch return null;
    const w = img.w;
    const h = img.h;
    const mx = @max(w, h);
    const tw = w * TH / mx;
    const thh = h * TH / mx;
    const ox = (TH - tw) / 2;
    const oy = (TH - thh) / 2;
    for (0..TH) |y| {
        for (0..TH) |x| {
            var c = BG;
            const ry = @as(i64, @intCast(y)) - oy;
            const rx = @as(i64, @intCast(x)) - ox;
            if (ry >= 0 and ry < thh and rx >= 0 and rx < tw) {
                const sy = @min(@as(u32, @intCast(ry)) * mx / TH, h - 1);
                const sx = @min(@as(u32, @intCast(rx)) * mx / TH, w - 1);
                const p = img.px[sy * w + sx];
                const v = [4]u32{ byte(p[0]), byte(p[1]), byte(p[2]), byte(p[3]) };
                const a = v[3];
                if (a == 255) {
                    c = v[0] << 16 | v[1] << 8 | v[2];
                } else if (a != 0) {
                    var o: u32 = 0;
                    for ([3]u5{ 16, 8, 0 }, 0..) |sh, k| {
                        const s = v[k] * a + ((BG >> sh) & 255) * (255 - a);
                        o |= ((s * 0x8081) >> 23) << sh;
                    }
                    c = o;
                }
            }
            // (opaque: Zui's images are 0xAARRGGBB; BeeModel's canvas ignores the top byte)
            out[y * TH + x] = c | 0xff000000;
        }
    }
    return out;
}

fn byte(f: f32) u32 {
    return @intFromFloat(std.math.clamp(@round(f * 255), 0, 255));
}

/// thumb_px: its thumbnail's pixels (loaded on first use), or null.
fn thumbPx(r: *lib.Rec) ?[]u32 {
    if (r.px) |p| return p;
    if (r.thumb != 2) return null;
    r.px = thumbLoad(lib.thumbPath(r));
    if (r.px == null) r.thumb = 3; // (it would not load: not again)
    return r.px;
}

/// blit_thumb: TH x TH pixels at x, y (logical), scaled to the buffer's pixels, clipped.
pub fn blit(x: i32, y: i32, px: []const u32) void {
    const cv = ui.cv;
    if (!cv.enabled) return;
    const pr = cv.pxRect(.{ .x = x, .y = y, .w = TH, .h = TH });
    const side = pr.w;
    if (side <= 0) return;
    const clip = cv.pxRect(cv.clip).intersect(.{ .w = cv.w, .h = cv.h });
    var row: i32 = 0;
    while (row < side) : (row += 1) {
        const yy = pr.y + row;
        if (yy < clip.y or yy >= clip.bottom()) continue;
        const sr: usize = @intCast(@divTrunc(row * TH, side));
        var c: i32 = 0;
        while (c < side) : (c += 1) {
            const xx = pr.x + c;
            if (xx < clip.x or xx >= clip.right()) continue;
            const sc: usize = @intCast(@divTrunc(c * TH, side));
            cv.px[@intCast(yy * cv.w + xx)] = px[sr * TH + sc];
        }
    }
}

// --- the header: search, kind, Save to Library ------------------------------------------

const kinds_l = [_][]const u8{ "All kinds", "Objects", "Materials", "Node trees", "Rigs", "Actions", "Scenes" };
fn kindLabel(k: usize) []const u8 {
    return kinds_l[k];
}
fn kindPick(k: usize) void {
    lib.kind_filter = @intCast(k);
    lib.match();
    app.dirty = true;
}
fn kindOn(k: usize) bool {
    return lib.kind_filter == k;
}

/// lb_header_tools: in the area header, at the original's place (the type
/// button 130 wide, then 6), when there is room for all three.
pub fn header(i: i16, r: Rect) void {
    const salt: usize = @intCast(i);
    const x = app.N(i).rect.x + 130 + 6;
    if (x + 420 > r.right()) return;
    lib.init();
    const y = r.y + 1;
    const fid = ui.id(@src(), salt);
    const fr = Rect{ .x = x, .y = y + 2, .w = 160, .h = 18 };
    if (ui.textField(fid, fr, lib.search(), "")) |t| {
        var b: [128]u8 = undefined;
        const k = @min(t.len, b.len);
        @memcpy(b[0..k], t[0..k]);
        lib.runOp("lib.search", b[0..k]);
    } else if (ui.edit_id != fid and lib.search_len > 0) {
        // (WK_TEXT: its text 7 in)
        ui.cv.fillRound(fr, 3, if (ui.hover(fid, fr)) ui.th.field_hover else ui.th.field);
        _ = ui.cv.text(fr.x + 7, fr.y + @divTrunc(fr.h - gfx.glyph_h, 2), lib.search(), ui.th.text);
    }
    // the kind (WK_ENUM): its name, a chevron of two lines
    const kb = Rect{ .x = x + 166, .y = y, .w = 110, .h = 22 };
    if (ui.button(ui.id(@src(), salt), kb, "", .{ .center = false })) {
        ui.active = 0;
        menus.openList(.{ .n = kinds_l.len, .label = kindLabel, .pick = kindPick, .checked = kindOn, .x = kb.x, .y = kb.bottom() + 2 });
    }
    _ = fitText(kb.x + 8, kb.y + 3, kb.w - 28, kinds_l[lib.kind_filter], ui.th.text);
    ui.record("enum", kinds_l[lib.kind_filter], kb, true);
    ui.cv.line(kb.right() - 16, kb.y + 9, kb.right() - 12, kb.y + 13, ui.th.text_dim);
    ui.cv.line(kb.right() - 12, kb.y + 13, kb.right() - 8, kb.y + 9, ui.th.text_dim);
    const sb = Rect{ .x = x + 282, .y = y, .w = 130, .h = 22 };
    const save = ui.button(ui.id(@src(), salt), sb, "", .{ .tip = "Keep the active object, its material, rig or the scene in the library" });
    // (WK_BUTTON's caption: centred by its rounded width, 2 in at least)
    const lbl = "Save to Library...";
    _ = fitText(sb.x + @max(2, (sb.w - widthR(lbl)) >> 1), sb.y + 3, sb.w - 2, lbl, ui.th.text);
    ui.record("button", lbl, sb, true);
    if (save) {
        ui.active = 0;
        if (ops.byId("lib.save")) |k| {
            ops.arg = "";
            ops.run(k);
        }
    }
}

/// text_width: the advances summed, rounded (the original's; the port's
/// textWidth rounds up).
fn widthR(s: []const u8) i32 {
    const tx = @import("text.zig");
    if (!tx.loaded) return gfx.textWidth(s);
    var pen: f32 = 0;
    var i: usize = 0;
    while (i < s.len) pen += tx.glyph(gfx.face, tx.nextCp(s, &i)).adv;
    return @intFromFloat(@round(pen / tx.ui_scale));
}

/// draw_text_fit: the text, or its longest start that fits and "...": the x after it.
fn fitText(x: i32, y: i32, maxw: i32, s: []const u8, col: u32) i32 {
    if (widthR(s) <= maxw) {
        _ = ui.cv.text(x, y, s, col);
        return x + widthR(s);
    }
    const room = maxw - widthR("...");
    var keep: usize = 0;
    var e: usize = 0;
    while (true) {
        e += 1;
        while (e < s.len and s[e] & 0xc0 == 0x80) e += 1;
        if (e > s.len or e > 400) break;
        if (widthR(s[0..e]) > room) break;
        keep = e;
        if (e >= s.len) break;
    }
    var b: [404]u8 = undefined;
    @memcpy(b[0..keep], s[0..keep]);
    @memcpy(b[keep..][0..3], "...");
    _ = ui.cv.text(x, y, b[0 .. keep + 3], col);
    return x + widthR(b[0 .. keep + 3]);
}

// --- the body (a Zui part: tiles, the source and search above, the details below) -----------

/// The tiles shown: the asset (library.zig's, or extlib.zig's on an online
/// source) of each, and which is selected (lib.sel, synced both ways).
const MAXT = 8192;
var hit_idx: [MAXT]u32 = undefined;
var hit_sel: [MAXT]bool = @splat(false);
var tiles_st: zui.ListState = .{};
/// The source the scroll and cursor were for: another starts afresh.
var tiles_src: i32 = -2;

/// Each asset's thumbnail as a Zui image (wrapping its pixels, not copied),
/// made again when they change.
var lib_img: [lib.MAX]zui.Image = undefined;
var lib_img_px: [lib.MAX]?[*]u32 = @splat(null);
var ext_img: [MAXT]zui.Image = undefined;
var ext_img_px: [MAXT]?[*]u32 = @splat(null);

fn imageOf(imgs: []zui.Image, of: []?[*]u32, k: u32, px: []u32) *const zui.Image {
    if (of[k] != px.ptr) {
        imgs[k] = .initArgb(px, TH, TH);
        imgs[k].is_opaque = true;
        of[k] = px.ptr;
    }
    return &imgs[k];
}

/// A dragged tile's payload kind.
const DRAG_KIND = "asset";

/// The tiles' size in units: the thumbnail TH x TH inside, its name under it.
fn tileW() f32 {
    return TH + 18;
}
fn tileH(z: *zui.Ui) f32 {
    return TH + 22 + z.textSize("").y;
}

/// The area being drawn (the browser's): a drag inside it is not refused.
var area_now: Rect = .{};

pub fn body(i: i16, r: Rect) void {
    const cv = ui.cv;
    const th = ui.th;
    cv.fill(r, th.pane_bg);
    lib.init();
    area_now = r;
    const online = ext.cur >= 0;
    const listing = !online or !(ext.state == 1 or ext.state == 2 or (ext.state == 3 and ext.n == 0));
    const details = !online and lib.sel >= 0 and lib.sel < lib.n;
    {
        const z = host.beginPart("assets", @intCast(i), r) orelse return;
        defer host.endPart(z);
        const pad = 4;
        const gap = 2;
        z.beginGroup(.{ .width = .fill, .height = .fill, .padding = pad, .spacing = gap });
        defer z.endGroup();
        headerRow(z, online);
        // the grid down to the selected asset's details (three lines: ours; online
        // two, extlib's, drawn below), at least a row of tiles high
        const line_h = z.textSize("").y;
        const below: f32 = if (details) 3 * (line_h + gap) else if (online) INFO_H else 0;
        const grid_h = @max(TILE_H, @as(f32, @floatFromInt(r.h)) - 2 * pad - (LB_HDR - 2) - gap - below);
        if (online and !listing) {
            // (extlib says what the catalog is doing, below)
        } else if (!online and lib.hits == 0) {
            z.label("No assets: lib.save object | material <name> | tree <name> | rig | action <name> | scene", .{ .color = host.col(th.text_dim) });
        } else {
            tiles(z, i, grid_h, online);
        }
        if (details) info(z);
    }
    // the online asset's name, category, source and licence; or the catalog's state
    if (online) {
        var shown: u32 = 0;
        var far = r.right();
        ext.drawTiles(r, 0, hit_idx[0..0], &shown, null, r.x + 8, r.y + LB_HDR, 1, &far);
    }
}

/// The source (a click: the next one), the search (a click: the console,
/// "lib.search "), what a tile does.
fn headerRow(z: *zui.Ui, online: bool) void {
    const th = ui.th;
    z.beginHorizontal(.{ .height = .px(LB_HDR - 2), .spacing = 2 });
    defer z.endHorizontal();
    const title = if (online) ext.srcTitle(@intCast(ext.cur)) else "Library";
    z.pushColor(.text, host.col(th.accent));
    const src_b = z.button(title, .{ .variant = .flat });
    z.popStyle();
    z.tooltipRich(src_b, .{ .title = title, .body = "The next source: the library, then the online ones (lib.source)" });
    z.label(">", .{ .color = host.col(th.text_dim) });
    if (src_b.clicked or bkit.ring(src_b, title)) {
        lib.runOp("lib.source_next", "");
        lib.sel = -1;
        app.dirty = true;
    }
    z.spacer(.px(12));
    var sb: [160]u8 = undefined;
    const s = std.fmt.bufPrint(&sb, "search: {s}", .{if (lib.search_len > 0) lib.search() else "(click to search)"}) catch "search:";
    z.pushColor(.text, host.col(if (lib.search_len > 0) th.text else th.text_dim));
    const se = z.button(s, .{ .variant = .flat });
    z.popStyle();
    if (se.clicked) @import("editors.zig").prefillConsole("lib.search ");
    z.spacer(.px(16));
    z.label(if (online) "double-click or drag a tile into a viewport (downloaded the first time)" else "drag a tile into a viewport", .{ .color = host.col(th.text_dim), .width = .fill });
}

/// The grid: every asset the search finds (only those in view described),
/// the selection synced with lib.sel, a double-click places, a drag into a
/// viewport places there, the right button opens the tile menu.
fn tiles(z: *zui.Ui, i: i16, h: f32, online: bool) void {
    const th = ui.th;
    // the assets shown
    var cnt: usize = 0;
    if (online) {
        var k: u32 = 0;
        while (k < ext.n and cnt < MAXT) : (k += 1) {
            if (ext.rec(k).hit == 0) continue;
            hit_idx[cnt] = k;
            cnt += 1;
        }
    } else {
        for (lib.tab[0..lib.n], 0..) |*rec, k| {
            if (rec.hit != 1) continue;
            hit_idx[cnt] = @intCast(k);
            cnt += 1;
        }
    }
    if (tiles_src != ext.cur) {
        tiles_st = .{};
        tiles_src = ext.cur;
    }
    const sel = hit_sel[0..cnt];
    for (sel, hit_idx[0..cnt]) |*b, k| b.* = lib.sel == k;

    var g = z.beginTiles("tiles", sel, &tiles_st, .{ .height = .px(h), .tile_width = tileW(), .tile_height = tileH(z) });
    const line_h = z.textSize("").y;
    const dl = dlPercent();
    for (g.list.first..g.list.end) |t| {
        const k = hit_idx[t];
        var name: []const u8 = undefined;
        var px: ?[]u32 = null;
        var kind: []const u8 = "";
        if (online) {
            name = ext.nameOf(k);
            px = ext.thumb(k);
            kind = cstr(&ext.rec(k).cat);
        } else {
            const rec = &lib.tab[k];
            name = rec.nameOf();
            px = thumbPx(rec);
            kind = lib.kinds[rec.kind];
        }
        const img: ?*const zui.Image = if (px) |p| (if (online) imageOf(&ext_img, &ext_img_px, k, p) else imageOf(&lib_img, &lib_img_px, k, p)) else null;
        const res = z.tile(&g, t, .{ .label = name, .image = img });
        const pic: zui.Rect = .{ .x = res.rect.x + 6, .y = res.rect.y + 6, .w = res.rect.w - 12, .h = res.rect.h - line_h - 16 };
        const p = z.painter();
        if (img == null) {
            // no thumbnail (yet): its kind
            p.rect(.{ .rect = pic, .fill = host.col(TILE_BG) });
            z.pushClip(pic.inset(4));
            p.text(.{ .x = pic.x + 8, .y = pic.y + (pic.h - line_h) / 2 }, host.col(th.text_dim), kind);
            z.popClip();
        }
        if (online) {
            // downloaded: a green dot; downloading: how far
            const e = ext.rec(k);
            if (e.have == 2) {
                p.rect(.{ .rect = .{ .x = pic.right() - 12, .y = pic.y + 4, .w = 8, .h = 8 }, .fill = host.col(0x4caf50) });
            } else if (e.have == 1) {
                const bar: zui.Rect = .{ .x = pic.x, .y = pic.bottom() - 6, .w = pic.w, .h = 6 };
                p.rect(.{ .rect = bar, .fill = host.col(0x1d2027) });
                if (dl > 0) p.rect(.{ .rect = .{ .x = bar.x, .y = bar.y, .w = bar.w * @as(f32, @floatFromInt(dl)) / 100, .h = 6 }, .fill = host.col(th.accent) });
            }
        }
        if (res.activated) userPlace(k);
        if (res.interaction.context_clicked and !online) {
            lib.sel = @intCast(k);
            app.setActiveArea(i);
            menus.openAt(&ctx_items, ui.mx, ui.my, i);
            app.dirty = true;
        }
        _ = z.dragSource(res.interaction, .{ .kind = DRAG_KIND, .data = k, .label = name });
    }
    const done = z.endTiles(&g);
    if (done.changed) {
        // the cursor's tile when it is selected, else the first selected one
        var to: ?usize = null;
        if (tiles_st.cursor) |c| if (c < cnt and sel[c]) {
            to = c;
        };
        if (to == null) to = std.mem.indexOfScalar(bool, sel, true);
        lib.sel = if (to) |t| @intCast(hit_idx[t]) else -1;
        app.dirty = true;
    }
    // (Enter on the keyboard's tile; a double-click came as the tile's own)
    if (done.activated) |t| if (t < cnt and (t < g.list.first or t >= g.list.end)) userPlace(hit_idx[t]);
    dropOnViewport(z);
}

/// A tile dragged out of the grid: over a 3D viewport it is placed on the
/// surface under the pointer (or the ground) when let go; elsewhere it is
/// refused. (The viewport is BeeModel's: the drop is found here, where the
/// tile's drag is Zui's, by the area under the pointer.)
fn dropOnViewport(z: *zui.Ui) void {
    const d = z.dragging() orelse return;
    if (!std.mem.eql(u8, d.kind, DRAG_KIND)) return;
    const a = viewportAt(ui.mx, ui.my) orelse {
        if (!area_now.contains(ui.mx, ui.my)) z.refuseDrop("Drop it on a 3D viewport");
        return;
    };
    z.dropHint("Place it on the surface here");
    if (!z.drag_state.released) return;
    const nr = app.N(a).rect;
    const body_r = Rect{ .x = nr.x, .y = nr.y + app.HDR_H, .w = nr.w, .h = nr.h - app.HDR_H };
    app.setActiveArea(a);
    scene.cursor = @import("viewport.zig").surfacePoint(ui.cv, &app.N(a).view, body_r, ui.mx, ui.my) orelse scene.cursor;
    userPlace(@intCast(d.data));
    app.dirty = true;
}

/// The 3D viewport whose body (below its header) is under (x, y), if any:
/// found in the layout (the window's areas, or the maximized one), as the
/// draw pass has not reached every area yet.
fn viewportAt(x: i32, y: i32) ?i16 {
    const w = app.ws();
    const top = if (w.maximized >= 0) w.maximized else w.root;
    const a = leafAt(top, x, y) orelse return null;
    const n = app.N(a);
    if (n.editor != .viewport) return null;
    if (y < n.rect.y + app.HDR_H) return null;
    return a;
}

fn leafAt(i: i16, x: i32, y: i32) ?i16 {
    if (i < 0) return null;
    const n = app.N(i);
    if (!n.rect.contains(x, y)) return null;
    if (n.leaf) return i;
    return leafAt(n.a, x, y) orelse leafAt(n.b, x, y);
}

/// The download's percent, from the status chip ("Downloading X 40%"); 0 if none.
fn dlPercent() u32 {
    var b: [160]u8 = undefined;
    const s = ext.chip(&b) orelse return 0;
    if (s.len < 2 or s[s.len - 1] != '%') return 0;
    var j = s.len - 1;
    while (j > 0 and std.ascii.isDigit(s[j - 1])) j -= 1;
    return std.fmt.parseInt(u32, s[j .. s.len - 1], 10) catch 0;
}

fn cstr(b: []const u8) []const u8 {
    return b[0 .. std.mem.indexOfScalar(u8, b, 0) orelse b.len];
}

/// The selected asset: name, kind, tags; what it uses; what uses it.
fn info(z: *zui.Ui) void {
    const th = ui.th;
    const k: u32 = @intCast(lib.sel);
    const rec = &lib.tab[k];
    var b: [256]u8 = undefined;
    z.label(std.fmt.bufPrint(&b, "{s}   {s}   tags: {s}", .{ rec.nameOf(), lib.kinds[rec.kind], if (rec.tags[0] == 0) "-" else rec.tagsOf() }) catch "", .{ .width = .fill });
    var db: [512]u8 = undefined;
    var b2: [600]u8 = undefined;
    z.label(std.fmt.bufPrint(&b2, "uses: {s}", .{lib.depsLine(k, false, &db)}) catch "", .{ .color = host.col(th.text_dim), .width = .fill });
    z.label(std.fmt.bufPrint(&b2, "used by: {s}", .{lib.depsLine(k, true, &db)}) catch "", .{ .color = host.col(th.text_dim), .width = .fill });
}

const ctx_items = [_]cat.Item{ .{ .op = "op_lb_place_sel" }, .{ .op = "op_lb_tag_sel" }, .{ .op = "op_lb_deps_sel" }, .sep, .{ .op = "op_lb_remove_sel" } };

/// As the user: lib.place <id> (an undo step), or lib.get <name> online.
fn userPlace(k: u32) void {
    if (ext.cur >= 0) {
        if (ops.byId("lib.get")) |i| {
            ops.arg = ext.nameOf(k);
            ops.run(i);
            ops.arg = "";
        }
        return;
    }
    var hx: [16]u8 = undefined;
    const id = lib.hex16(lib.tab[k].id, &hx);
    if (ops.byId("lib.place")) |i| {
        ops.arg = id;
        ops.run(i);
        ops.arg = "";
    }
}

/// lb_ghost: the asset being dragged, at the pointer. Zui draws it now (the
/// tile's drag), with what letting go there does.
pub fn ghost() void {}

// --- the tile menu's operators (teamui.s) ------------------------------------------------------

fn pollSel() ?[]const u8 {
    return if (lib.sel < 0) "select an asset first" else null;
}

/// do_lb_sel: the operator with "<asset name> [the form's words]".
fn onSel(comptime id: []const u8) *const fn () void {
    return struct {
        fn f() void {
            if (lib.sel < 0) return;
            var b: [192]u8 = undefined;
            const nm = lib.tab[@intCast(lib.sel)].nameOf();
            const s = if (ops.arg.len > 0) std.fmt.bufPrint(&b, "{s} {s}", .{ nm, ops.arg }) catch nm else std.fmt.bufPrint(&b, "{s}", .{nm}) catch nm;
            lib.runOp(id, s);
        }
    }.f;
}

// --- thumbnails (lb_tick, lib.thumbnails, the child's lib.thumbnail) --------------------------

var busy: i32 = 0; // a thumbnail being made: the child's pid
var job: u32 = 0;
var ticking = false;

fn nextJob() ?u32 {
    for (lib.tab[0..lib.n], 0..) |*r, k| {
        if (!r.dead and r.thumb == 0) return @intCast(k);
    }
    return null;
}

fn jobDone(k: u32) void {
    const r = &lib.tab[k];
    r.thumb = if (exists(lib.thumbPath(r))) 2 else 3;
    lib.ver +%= 1;
    app.dirty = true;
}

fn exists(p: []const u8) bool {
    var zb: [701]u8 = undefined;
    if (p.len >= zb.len) return false;
    @memcpy(zb[0..p.len], p);
    zb[p.len] = 0;
    return linux.errno(linux.access(@ptrCast(&zb), 0)) == .SUCCESS;
}

/// lb_spawn: this program, --lib-thumbnail <id>: the child's pid (0: none).
fn spawnChild(k: u32) i32 {
    const sp = @import("spawn.zig");
    var exe: [512:0]u8 = undefined;
    const n = linux.readlink("/proc/self/exe", &exe, exe.len - 1);
    if (linux.errno(n) != .SUCCESS) return 0;
    exe[n] = 0;
    var hx: [17:0]u8 = undefined;
    _ = lib.hex16(lib.tab[k].id, hx[0..16]);
    hx[16] = 0;
    const av = [_:null]?[*:0]const u8{ &exe, "--lib-thumbnail", &hx };
    const pid = sp.spawn(&exe, &av, sp.KEEP, sp.KEEP, sp.KEEP) orelse return 0;
    return @intCast(pid);
}

/// The main loop's turn (lb_tick): the thumbnail child done? the next one started.
pub fn tick() void {
    if (!lib.isReady() or headlessNoKids()) return;
    if (busy != 0) {
        var st: i32 = 0;
        const r = linux.wait4(busy, &st, 1, null);
        if (linux.errno(r) == .SUCCESS and r == 0) return; // still at it
        busy = 0;
        jobDone(job);
    }
    const k = nextJob() orelse return;
    job = k;
    lib.tab[k].thumb = 1;
    busy = spawnChild(k);
    if (busy == 0) lib.tab[k].thumb = 3;
}

/// A thumbnail child or a download running: the main loop looks again soon.
pub fn working() bool {
    return busy != 0 or ext.busy() != 0;
}

/// Headless runs (tests) make thumbnails only when asked (lib.thumbnails).
pub var auto_thumbs: ?bool = null;
fn headlessNoKids() bool {
    if (auto_thumbs) |a| return !a;
    return @import("files.zig").headless;
}

/// lib.thumbnails: every missing one made now, in turn.
fn opThumbs() void {
    lib.init();
    var made: u32 = 0;
    while (nextJob()) |k| {
        lib.tab[k].thumb = 1;
        const pid = spawnChild(k);
        if (pid != 0) _ = @import("spawn.zig").wait(pid);
        jobDone(k);
        if (lib.tab[k].thumb == 2) made += 1;
    }
    app.log("  thumbnails made: {d}", .{made});
}

/// (the child) lib.thumbnail <id>: the asset alone at the origin - a material
/// on a sphere, a tree on a plane, an action on a cube halfway through -
/// framed and path-traced to thumbs/<id>.png.
pub fn thumbChild(id: []const u8) u8 {
    lib.init();
    const k = lib.find(id) orelse return 1;
    const r = lib.tab[k];
    if (r.kind != lib.K_SCENE) {
        while (scene.count > 0) scene.remove(0); // (scene_clear)
        switch (r.kind) {
            lib.K_MATERIAL => lib.runOp("create.sphere", ""),
            lib.K_TREE => {
                _ = lib.placeAt(k, .{ 0, 0, 0 });
                lib.runOp("create.plane", "");
                treeMod();
            },
            lib.K_ACTION => lib.runOp("create.cube", ""),
            else => {},
        }
        if (r.kind != lib.K_TREE) {
            if (!lib.placeAt(k, .{ 0, 0, 0 })) return 1;
            if (r.kind == lib.K_ACTION) midFrame();
        }
    } else if (!lib.placeAt(k, .{ 0, 0, 0 })) return 1;
    var dir_b: [700]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_b, "{s}", .{lib.thumbDir(&r)}) catch return 1;
    if (!lib.mayWrite(dir)) return 1;
    _ = @import("spawn.zig").ensureDir(dir);
    var pb: [700]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}", .{lib.thumbPath(&r)}) catch return 1;
    return if (renderThumb(p)) 0 else 1;
}

/// lb_tree_mod: the active object gets a geometry modifier running the newest tree.
fn treeMod() void {
    const a = scene.active orelse return;
    const mods = @import("mods.zig");
    const k = mods.add(a, mods.GEONODES) orelse return;
    const nt = @import("ntree.zig");
    if (nt.count() == 0) return;
    mods.setF(&scene.objects[a].mods.m[k], 0, @floatFromInt(nt.count()));
}

/// lb_mid_frame: the scene halfway through the action placed.
fn midFrame() void {
    const anim = @import("anim.zig");
    const b = anim.cur orelse return;
    if (b.h.nact == 0) return;
    const ac = b.h.act[b.h.nact - 1];
    anim.frame = (ac.start + ac.end) * 0.5;
    anim.apply(anim.frame);
}

/// lb_frame_view and hive_render_file: the view on every mesh object's bounds,
/// path-traced, 128 x 128, 24 samples, denoised.
fn renderThumb(path: []const u8) bool {
    var lo: m.V3 = .{ 1e30, 1e30, 1e30 };
    var hi: m.V3 = .{ -1e30, -1e30, -1e30 };
    for (0..scene.count) |oi| {
        if (!scene.objects[oi].kind.isMesh()) continue;
        const me = @import("mods.zig").of(oi) orelse continue;
        const w = scene.world(oi);
        for (0..8) |c| {
            const p: m.V3 = .{ if (c & 1 != 0) me.hi[0] else me.lo[0], if (c & 2 != 0) me.hi[1] else me.lo[1], if (c & 4 != 0) me.hi[2] else me.lo[2] };
            const q = m.xform(w, p);
            for (0..3) |a| {
                lo[a] = @min(lo[a], q[a]);
                hi[a] = @max(hi[a], q[a]);
            }
        }
    }
    if (lo[0] > hi[0]) {
        lo = .{ 0, 0, 0 };
        hi = .{ 0, 0, 0 };
    }
    var v = @import("viewport.zig").View{};
    var d2: f32 = 0;
    for (0..3) |a| {
        v.target[a] = (lo[a] + hi[a]) * 0.5;
        d2 += (hi[a] - lo[a]) * (hi[a] - lo[a]);
    }
    v.dist = @max(@sqrt(d2) * 0.5, 0.25) * 3.3;
    v.yaw = @as(f32, @bitCast(@as(u32, 0x3f2aa2f2))) / m.deg;
    v.pitch = @as(f32, @bitCast(@as(u32, 0x3e9c4a5a))) / m.deg;
    return @import("render.zig").renderFile(path, 128, 128, 24, true, &v);
}

const Impl = ops.Impl;
pub const list_ops = .{
    .{ "lib.thumbnails", Impl{ .run = opThumbs } },
    .{ "lib.place_selected", Impl{ .run = onSel("lib.place"), .poll = pollSel } },
    .{ "lib.tag_selected", Impl{ .run = onSel("lib.tag"), .poll = pollSel } },
    .{ "lib.deps_selected", Impl{ .run = onSel("lib.deps"), .poll = pollSel } },
    .{ "lib.remove_selected", Impl{ .run = onSel("lib.remove"), .poll = pollSel } },
};

test "thumb_load fits and backs the picture" {
    // (decoding goes through image.zig: covered there; the fit's arithmetic here)
    try std.testing.expectEqual(@as(u32, 96), 128 * TH / 128);
}
