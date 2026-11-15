// The host of BeeZigUi (Zui) in BeeModel: one zui.Ui for the main window,
// drawn by Zui's software renderer straight into BeeModel's canvas
// (ui.cv.px), from BeeModel's own events, theme, fonts and icons. See
// Docs/beezigui-migration.html.
//
// Two kinds of Zui parts share the one Ui and its frame:
//
//   dialogs  clients (`clients` below): shown over everything, described
//            at the dialog layer of app.frame. A modal one takes every event.
//   parts    panels inside BeeModel's own layout (the Preferences in an
//            area, the redo panel): described when BeeModel draws the place
//            they are in, between `beginPart` and `endPart`, and drawn on
//            the spot, so BeeModel's menus and pies still go over them.
//
// Zui's frame begins with the first of them in a draw pass and ends at the
// dialog layer, where Zui's windows, popups and tooltips are drawn, over
// BeeModel's. With no Zui part shown it costs nothing.
//
// Input order (app.onInput): the host first, for the rects the parts and
// dialogs covered last frame (`claim`), Zui's popups, a drag that started on
// Zui, and the keys while a Zui field has them; BeeModel's own UI gets the
// rest.
//
// Zui's widgets go into ui.rec under BeeModel's record kinds, so the --shot
// driver, the scenarios, the fuzzers and MCP ui_tree find them by the same
// names as before.
const std = @import("std");
const zui = @import("zui");
const software = @import("zui_software");
const gfx = @import("gfx.zig");
const ui = @import("ui.zig");
const app = @import("app.zig");
const wl = @import("wayland.zig");
const theme = @import("theme.zig");
const prefs = @import("prefs.zig");
const keyboard = @import("keyboard.zig");
const clipboard = @import("clipboard.zig");
const icons = @import("icons.zig");
const wg = @import("wg.zig");
const scale = @import("scale.zig");

const Rect = gfx.Rect;
const gpa = std.heap.smp_allocator;

/// A part of BeeModel's UI drawn by Zui.
pub const Client = struct {
    /// Shown now.
    visible: *const fn () bool,
    /// Its UI, in Zui's frame. Call `claim` for the rects it covers.
    describe: *const fn (z: *zui.Ui) void,
    /// Takes every event while shown, and covers the whole window (a modal
    /// dialog).
    modal: bool = false,
    /// Sees a pressed key (evdev code) before Zui does; true if it took it.
    key: ?*const fn (z: *zui.Ui, code: u32) bool = null,
    /// BeeModel's own pixels under Zui's, in the draw pass (a dialog's dim).
    under: ?*const fn () void = null,
};

/// Zui's dialogs, back to front.
const clients = [_]Client{
    @import("zuiprefs.zig").client,
    @import("dialogs.zig").client,
    @import("dialogs.zig").prompt_client,
    @import("menus.zig").client,
    @import("pies.zig").client,
    @import("filebrowser.zig").client,
    // (over a dialog it was opened from: described after it)
    @import("colorpick.zig").client,
};

const State = struct {
    font: zui.Font,
    head: zui.Font,
    mono: zui.Font,
    ui: zui.Ui,
    sw: software.SoftwareRenderer,
    icon_image: zui.Image,
    icon_set: zui.IconSet,
};

var state: ?*State = null;
var last_ms: i64 = 0;
var wake_at: ?i64 = null;
var last_press_ms: i64 = -10000;
var last_press: [2]f32 = .{ -1000, -1000 };

/// What Zui covered last frame, in units, and BeeModel's layer it was drawn
/// on: the pointer there is Zui's, unless BeeModel's own UI is above it.
/// A claim without `wheel` (a panel in BeeModel's own scrolling page)
/// leaves the wheel to the page.
const Claim = struct { r: Rect, layer: u8, wheel: bool = true };
var claims: [128]Claim = undefined;
var claims_n: usize = 0;

/// Zui's frame has begun in this draw pass.
var in_frame = false;

/// Zui is describing inside BeeModel's draw pass (not a unit test driving
/// a Ui of its own): the kit may write BeeModel's record and field list.
pub fn bridging() bool {
    return in_frame;
}
/// Zui's frame ran in the last draw pass.
var ran_last = false;
/// Root commands of this frame already drawn (by `endPart`).
var rendered_upto: usize = 0;
/// The last frame asked for another at once (its layout is settling, or it
/// acted on input).
var settle_wanted = false;
/// Zui took input since its last frame.
var had_input = false;
/// Input Zui took this frame that was not the pointer's (keys).
var had_other = false;
/// The viewport's canvas had every pointer event of this frame (viewTookAll).
var view_took_all = false;

/// The viewport handled all of this frame's pointer events itself, before
/// it rendered: no frame needs to follow to show them (unless something
/// else of Zui's acted or asked).
pub fn viewTookAll() void {
    view_took_all = true;
}
/// A Zui widget acted without input of Zui's (the field menu, Ctrl+V over
/// it, the focus ring): `noteActed`.
var acted = false;

/// The kit's widgets acted on a value or a click from BeeModel's field
/// menu or focus ring: an undo step at the end of the frame, and another
/// frame for what it changed.
pub fn noteActed() void {
    acted = true;
}
/// The modal Zui dialog's rect last frame, if one was shown.
var dialog_rect: ?zui.Rect = null;

// --- the Ui ----------------------------------------------------------------------

const sans_paths = [_][]const u8{
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
};
const bold_paths = [_][]const u8{
    "/usr/share/fonts/noto/NotoSans-Bold.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
};

/// BeeModel's font (the first that exists), else Zui's own.
fn loadFont(paths: []const []const u8) zui.Font {
    for (paths) |p| if (@import("ttf.zig").mapFile(p)) |d| {
        if (zui.Font.init(gpa, d)) |f| return f else |_| {}
    };
    return zui.Font.initDefault(gpa) catch @panic("zui: no font");
}

fn st() *State {
    if (state) |s| return s;
    const s = gpa.create(State) catch @panic("zui: out of memory");
    s.font = loadFont(&sans_paths);
    s.head = loadFont(&bold_paths);
    s.mono = loadFont(&@import("text.zig").mono_paths);
    s.ui = .init(gpa, .{ .font = &s.font });
    s.ui.recording = true;
    s.ui.clipboard = .{ .context = s, .getFn = clipGet, .setFn = clipSet };
    s.sw = .init(gpa);
    buildIcons();
    s.icon_image = .initAlpha(&icon_atlas, atlas_w, atlas_h);
    s.icon_set = .grid(&s.icon_image, 16, 16);
    s.icon_set.whole_pixels = true; // (BeeModel's 16-pixel icons, crisp as its own drawing had them)
    state = s;
    return s;
}

/// The allocator Zui's state lives in (the file browser's listing).
pub fn allocator() std.mem.Allocator {
    return gpa;
}

/// The one Zui of the main window.
pub fn get() *zui.Ui {
    return &st().ui;
}

/// BeeModel's heading face (Noto Sans Bold).
pub fn headFont() *zui.Font {
    return &st().head;
}

/// BeeModel's monospace face (the console's).
pub fn monoFont() *zui.Font {
    return &st().mono;
}

// --- look --------------------------------------------------------------------------

pub fn col(v: u32) zui.Color {
    return zui.Color.hex(@truncate(v & 0xffffff));
}

/// A Zui style from a BeeModel theme: borderless widgets on fields, the
/// accent for what is on, rows of 22 units, BeeModel's tooltip delay.
pub fn styleFrom(t: *const theme.Theme) zui.Style {
    var s: zui.Style = .dark;
    s.colors = .{
        .background = col(t.pane_bg),
        .text = col(t.text),
        .text_muted = col(t.text_dim),
        .button = col(t.btn),
        .button_hovered = col(t.btn_hover),
        .button_active = col(t.accent),
        .border = zui.Color.transparent,
        // A focused field's outline: BeeModel's focus colour.
        .accent = col(t.focus),
        .window = col(t.drop_bg),
        .title = col(t.pane_hdr),
        .title_active = col(t.pane_hdr),
        .title_text = col(t.text),
        .scrollbar = col(t.field_hover),
        .scrollbar_hovered = col(t.btn_hover),
        .check_mark = col(t.accent_text),
        .slider_fill = col(t.accent_dark),
        .slider_thumb = col(t.accent),
        .slider_thumb_active = col(t.accent_fg),
        .input = col(t.field),
        .selection = col(t.selection),
        .caret = col(t.focus),
        .focus_ring = col(t.focus),
        .separator = col(t.sep),
        .resize_grip = col(t.text_dim),
        .popup = col(t.menu_bg),
        .shadow = col(t.shadow).withAlpha(120),
        .warning = col(t.warn),
        .axis_x = col(t.axis_x),
        .axis_y = col(t.axis_y),
        .axis_z = col(t.axis_z),
        // BeeModel dims what is behind a dialog to half its brightness.
        .backdrop = zui.Color.black.withAlpha(128),
    };
    s.font_size = 15;
    s.frame_padding = .{ .x = 8, .y = 1 };
    s.item_spacing = .{ .x = 6, .y = 6 };
    s.rounding = 4;
    s.window_rounding = 8;
    s.popup_padding = 4;
    s.tooltip_delay = @as(f32, @floatFromInt(@max(0, prefs.tooltip_ms))) / 1000;
    return s;
}

// BeeModel's 114 icons (16 x 16, 4-bit alpha, low nibble the left pixel) as
// one alpha atlas, 16 a row.
const atlas_cols = 16;
const atlas_w = atlas_cols * 16;
const atlas_h = ((icons.masks.len + atlas_cols - 1) / atlas_cols) * 16;
var icon_atlas: [atlas_w * atlas_h]u8 = @splat(0);

fn buildIcons() void {
    for (&icons.masks, 0..) |*m, i| {
        const ox = (i % atlas_cols) * 16;
        const oy = (i / atlas_cols) * 16;
        for (0..16) |y| for (0..16) |x| {
            const b = m[y * 8 + x / 2];
            const a4: u8 = if (x % 2 == 0) b & 15 else b >> 4;
            icon_atlas[(oy + y) * atlas_w + ox + x] = a4 * 17;
        };
    }
}

/// A BeeModel icon for Zui's buttons, rows and tabs.
pub fn icon(which: icons.Icon) zui.Icon {
    return st().icon_set.icon(@intFromEnum(which));
}

// --- the clipboard -------------------------------------------------------------------

var paste_buf: [65536]u8 = undefined;

fn clipGet(_: *anyopaque) []const u8 {
    return paste_buf[0..clipboard.paste(&paste_buf)];
}

fn clipSet(_: *anyopaque, text: []const u8) void {
    clipboard.copy(text);
}

// --- layout helpers -------------------------------------------------------------------

/// A Zui rect (units) as BeeModel's, rounded: for ui.record.
pub fn rectOf(r: zui.Rect) Rect {
    return .{ .x = @intFromFloat(@round(r.x)), .y = @intFromFloat(@round(r.y)), .w = @intFromFloat(@round(r.w)), .h = @intFromFloat(@round(r.h)) };
}

pub fn zr(r: Rect) zui.Rect {
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
}

/// The rest of this frame's widgets go into `r` (a region named `name` and
/// `salt`), at the place BeeModel's own layout gives them. End with
/// `z.endRegion()`.
pub fn at(z: *zui.Ui, name: []const u8, salt: usize, r: Rect) void {
    z.pushIdInt(salt);
    const region = z.id(name);
    z.popId();
    z.beginRegion(region, zr(r), .horizontal, 0, .center);
}

/// A modal dialog's claim: above every layer of BeeModel's.
fn claimModal(r: Rect) void {
    if (claims_n < claims.len) {
        claims[claims_n] = .{ .r = r, .layer = 255 };
        claims_n += 1;
    }
}

/// The pointer over `r` (units) is Zui's, from the next event on, as long as
/// nothing of BeeModel's above the layer being drawn is there.
pub fn claim(r: Rect) void {
    if (claims_n < claims.len) {
        claims[claims_n] = .{ .r = r, .layer = ui.layer };
        claims_n += 1;
    }
}

// --- input ----------------------------------------------------------------------------

/// Whether Zui has anything on screen (so input may be its): a part or a
/// dialog it drew last frame and that is still there, or a dialog opened since.
/// Its state from a frame in which the last of them closed (a hovered window,
/// a held button) is stale.
fn shown() bool {
    if (ran_last and claims_n > 0) return true;
    return anyDialog();
}

fn anyDialog() bool {
    inline for (clients) |c| if (c.visible()) return true;
    return false;
}

fn modal() ?Client {
    inline for (clients) |c| if (c.modal and c.visible()) return c;
    return null;
}

/// Whether the pointer, at (x, y) units, is over Zui: a claimed rect, one of
/// its windows or popups, or a drag that started on it.
fn pointerOwned(s: *State, x: i32, y: i32) bool {
    const z = &s.ui;
    // A drag that started on Zui stays Zui's; one that started on BeeModel's
    // own UI stays BeeModel's.
    if (z.active != .none or z.canvas_capture != null) return true;
    if (ui.active != 0 or app.modalTool()) return false;
    // BeeModel's menus, pies and floating panels over a part take the pointer.
    const top = app.layerAt(x, y);
    // (where its windows and popups were shown: an event can come before
    // the frame that would know the pointer is over one)
    const p: zui.Vec2 = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    if (z.windowShownAt(p)) return true;
    // (a toast: a click on it opens the console)
    const fs = &z.feedback_state;
    for (fs.toast_rects[0..fs.toast_rect_count]) |t| if (t.rect.contains(p)) return true;
    for (claims[0..claims_n]) |c| if (c.r.contains(x, y) and top <= c.layer) return true;
    return false;
}

/// Whether a wheel notch at (x, y) is Zui's: as `pointerOwned`, but over a
/// flow part (in a page BeeModel scrolls) only while Zui holds something.
fn wheelOwned(s: *State, x: i32, y: i32) bool {
    const z = &s.ui;
    if (z.active != .none or z.canvas_capture != null) return true;
    if (ui.active != 0 or app.modalTool()) return false;
    const top = app.layerAt(x, y);
    // (where its windows and popups were shown: an event can come before
    // the frame that would know the pointer is over one)
    const p: zui.Vec2 = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    if (z.windowShownAt(p)) return true;
    // (a toast: a click on it opens the console)
    const fs = &z.feedback_state;
    for (fs.toast_rects[0..fs.toast_rect_count]) |t| if (t.rect.contains(p)) return true;
    for (claims[0..claims_n]) |c| if (c.wheel and c.r.contains(x, y) and top <= c.layer) return true;
    return false;
}

/// BeeModel's events, Zui's first: true if Zui took it, and BeeModel's own
/// UI should not see it.
pub fn input(ev: wl.Input) bool {
    const taken = inputInner(ev);
    if (taken) {
        had_input = true;
        switch (ev) {
            .motion, .button, .wheel, .leave => {},
            else => had_other = true, // (keys: a field's typing)
        }
    }
    return taken;
}

fn inputInner(ev: wl.Input) bool {
    if (!shown()) return false;
    const s = st();
    const in = &s.ui.input;
    const mod_client = modal();
    switch (ev) {
        .motion => |p| {
            const x = scale.ptr(p.x);
            const y = scale.ptr(p.y);
            // Zui always knows where the pointer is, so its hover ends when
            // the pointer leaves it.
            in.onMouseMove(.{ .x = x, .y = y });
            const owned = mod_client != null or pointerOwned(s, @intFromFloat(x), @intFromFloat(y));
            if (!owned) return false;
            app.dirty = true;
            ui.mx = @intFromFloat(x);
            ui.my = @intFromFloat(y);
            return true;
        },
        .leave => {
            in.onMouseMove(.{ .x = -1000, .y = -1000 });
            app.dirty = true;
            return mod_client != null;
        },
        .button => |b| {
            const which: zui.MouseButton = switch (b.button) {
                wl.BTN_LEFT => .left,
                wl.BTN_RIGHT => .right,
                wl.BTN_MIDDLE => .middle,
                else => return mod_client != null,
            };
            const m = in.mouse_pos;
            const owned = mod_client != null or pointerOwned(s, @intFromFloat(m.x), @intFromFloat(m.y));
            if (!owned) {
                // A press elsewhere lets go of a Zui field; a release always
                // reaches Zui, so nothing stays held.
                if (b.pressed) s.ui.focused = .none else in.onMouseButton(which, false);
                return false;
            }
            app.dirty = true;
            var clicks: u8 = 1;
            if (b.pressed and which == .left) {
                if (app.now_ms - last_press_ms < 400 and @abs(m.x - last_press[0]) < 4 and @abs(m.y - last_press[1]) < 4) clicks = 2;
                last_press_ms = app.now_ms;
                last_press = .{ m.x, m.y };
            }
            in.onMouseButtonClicks(which, b.pressed, clicks);
            return true;
        },
        .wheel => |v| {
            const m = in.mouse_pos;
            if (mod_client == null and !wheelOwned(s, @intFromFloat(m.x), @intFromFloat(m.y))) return false;
            app.dirty = true;
            in.onScroll(.{ .x = 0, .y = -v });
            return true;
        },
        .mods => |m| {
            in.modifiers = .{ .shift = m & wl.MOD_SHIFT != 0, .ctrl = m & wl.MOD_CTRL != 0, .alt = m & wl.MOD_ALT != 0 };
            if (mod_client == null) return false;
            ui.mods = m;
            app.dirty = true;
            return true;
        },
        .key => |k| {
            if (mod_client == null and !s.ui.wantsKeyboard()) {
                // A key up still reaches Zui (pies close on it).
                if (!k.pressed) if (keyFor(k.key)) |zk| in.onKeyRelease(zk);
                return false;
            }
            app.dirty = true;
            if (!k.pressed) {
                if (keyFor(k.key)) |zk| in.onKeyRelease(zk);
                return true;
            }
            inline for (clients) |c| {
                if (c.key) |hook| if (c.visible() and hook(&s.ui, k.key)) {
                    hold_keys = true;
                    return true;
                };
            }
            if (keyFor(k.key)) |zk| {
                in.onKeyPress(zk);
                // (Enter may submit and refocus, Tab and Esc move the focus,
                // Up / Down put a whole text in a field: the next keys wait
                // for the frame that does it)
                switch (zk) {
                    .enter, .tab, .escape, .up, .down => hold_keys = true,
                    else => {},
                }
            }
            if (ui.mods & (wl.MOD_CTRL | wl.MOD_ALT) == 0) {
                const cp = keyboard.char(k.key, ui.mods);
                if (cp >= 0x20 and cp != 0x7f) {
                    var buf: [4]u8 = undefined;
                    in.onText(keyboard.utf8(cp, &buf));
                }
            }
            return true;
        },
        else => return false,
    }
}

// --- toasts ----------------------------------------------------------------------------

/// BeeModel's toast (app.toast): one at a time, a newer one in its place.
pub fn toast(ok: bool, text: []const u8) void {
    const z = &st().ui;
    z.feedback_state.toast_count = 0;
    _ = z.toast(text, if (ok) .success else .warning, .{});
    app.dirty = true;
}

// --- keys held for Zui's next frame ---------------------------------------------------

var held: [512]wl.Input = undefined;
var held_n: usize = 0;
var hold_keys = false;

/// BeeModel asked for a Zui field's focus (taken in Zui's next frame):
/// the keys after this wait for that frame, so they are typed there.
pub fn focusSoon() void {
    hold_keys = true;
    app.dirty = true;
}

/// For app.onInput, first: a key (or a change of modifiers) after one whose
/// effect needs Zui's frame (a field submitted, a focus asked for) waits
/// for that frame, rather than reaching a field not focused yet or piling
/// up in one frame (a batch of input: a slow frame, a job). True: held.
pub fn hold(ev: wl.Input) bool {
    if (!hold_keys and held_n == 0) return false;
    switch (ev) {
        .key, .mods => {},
        else => return false,
    }
    if (held_n == held.len) return false; // (full: as it comes)
    held[held_n] = ev;
    held_n += 1;
    settle_wanted = true;
    app.dirty = true;
    return true;
}

/// After a frame (app.frame's end): the keys held, in order, until one needs
/// a frame again; none while a job runs or waits (input waits for it).
pub fn replayHeld(cv: *@import("gfx.zig").Canvas) void {
    hold_keys = false;
    if (held_n == 0) return;
    const jobs = @import("jobui.zig");
    if (jobs.on or jobs.queued()) {
        settle_wanted = true;
        return;
    }
    var local: [held.len]wl.Input = undefined;
    const n = held_n;
    @memcpy(local[0..n], held[0..n]);
    held_n = 0;
    for (local[0..n]) |ev| app.onInput(cv, ev);
    settle_wanted = true;
    app.dirty = true;
}

/// A key for Zui from BeeModel's own key handling (an open menu's keys):
/// Zui's input, with the frame after it that input asks for.
pub fn pressKey(k: zui.Key) void {
    st().ui.input.onKeyPress(k);
    had_input = true;
    app.dirty = true;
}

/// A key (evdev code) for Zui from BeeModel's own key handling, with the
/// text it types: for a Zui field that takes the focus in its next frame
/// (the F3 palette's search, typed into at once).
pub fn feedKey(code: u32) void {
    const in = &st().ui.input;
    if (keyFor(code)) |zk| in.onKeyPress(zk);
    if (ui.mods & (wl.MOD_CTRL | wl.MOD_ALT) == 0) {
        const cp = keyboard.char(code, ui.mods);
        if (cp >= 0x20 and cp != 0x7f) {
            var buf: [4]u8 = undefined;
            in.onText(keyboard.utf8(cp, &buf));
        }
    }
    had_input = true;
    app.dirty = true;
}

/// The Zui key of an evdev key: letters by the label on the key (Ctrl+Z
/// is the key labelled Z on AZERTY too), the rest by position.
pub fn keyFor(code0: u32) ?zui.Key {
    const code = keyboard.shortcutCode(code0);
    const letters = "qwertyuiop\x00\x00\x00\x00asdfghjkl\x00\x00\x00\x00\x00zxcvbnm";
    if (code >= 16 and code < 16 + letters.len and letters[code - 16] != 0) return @enumFromInt(@intFromEnum(zui.Key.a) + (letters[code - 16] - 'a'));
    return switch (code) {
        1 => .escape,
        2...10 => @enumFromInt(@intFromEnum(zui.Key.@"1") + (code - 2)),
        11 => .@"0",
        12 => .minus,
        13 => .equal,
        14 => .backspace,
        15 => .tab,
        28, 96 => .enter,
        51 => .comma,
        52 => .period,
        53 => .slash,
        57 => .space,
        59...68 => @enumFromInt(@intFromEnum(zui.Key.f1) + (code - 59)),
        87 => .f11,
        88 => .f12,
        102 => .home,
        103 => .up,
        104 => .page_up,
        105 => .left,
        106 => .right,
        107 => .end,
        108 => .down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        else => null,
    };
}

/// For app.tick: milliseconds until Zui wants a frame (a tooltip's delay,
/// the caret), or null.
pub fn tick(now: i64) ?i32 {
    if (!shown()) return null;
    // The last frame asked for another at once (it acted, or its layout is
    // settling): the window's loop clears app.dirty after drawing, so the
    // frame's own request is asked for again here.
    if (settle_wanted) {
        app.dirty = true;
        return 0;
    }
    const when = wake_at orelse return null;
    if (now >= when) {
        wake_at = null;
        app.dirty = true;
        return 0;
    }
    return @intCast(@min(when - now, 1000));
}

// --- the frame ---------------------------------------------------------------------------

/// The Ui with this draw pass's frame begun.
fn ensureFrame() *zui.Ui {
    const s = st();
    const z = &s.ui;
    if (in_frame) return z;
    const cv = ui.cv;
    in_frame = true;
    rendered_upto = 0;
    claims_n = 0;
    z.style = styleFrom(ui.th);
    const dt: f32 = if (last_ms == 0) 0.016 else @as(f32, @floatFromInt(@max(0, app.now_ms - last_ms))) / 1000;
    last_ms = app.now_ms;
    z.beginFrame(.{ .width = @floatFromInt(cv.uw), .height = @floatFromInt(cv.uh), .dt = dt });
    // (toasts at the bottom right, above the status bar)
    z.toast_align = .right;
    z.toast_margin = @floatFromInt(app.STATUS_H + 10);
    return z;
}

fn render(list: *const zui.DrawList) void {
    const cv = ui.cv;
    const s = st();
    const n: usize = @intCast(cv.w * cv.h);
    s.sw.useBuffer(cv.px[0..n], @intCast(cv.w), @intCast(cv.h));
    s.sw.clear = false;
    s.sw.renderer().render(list, .{ .width = @floatFromInt(cv.uw), .height = @floatFromInt(cv.uh), .scale = @as(f32, @floatFromInt(cv.s)) / 65536 });
}

/// A Zui part inside BeeModel's layout, over `r` (units): describe it with
/// the Ui returned, then call `endPart`. Null in the hit pass (Zui has the
/// input already): describe nothing then. `name` and `salt` keep two parts
/// apart.
pub fn beginPart(name: []const u8, salt: usize, r: Rect) ?*zui.Ui {
    if (!ui.cv.enabled) {
        hitPassPart(name, salt);
        return null;
    }
    const z = ensureFrame();
    if (part_depth < part_stack.len) part_stack[part_depth] = wg.zui_part;
    part_depth += 1;
    claim(r);
    z.pushIdInt(salt);
    const region = z.id(name);
    wg.zui_part = @intFromEnum(region);
    z.pushIdValue(region);
    z.beginRegion(region, zr(r), .vertical, 0, .start);
    z.pushClip(zr(r));
    return z;
}

/// Ends the part begun by `beginPart`, and draws it now, under whatever
/// BeeModel draws after it.
pub fn endPart(z: *zui.Ui) void {
    z.popClip();
    z.endRegion();
    z.popId();
    z.popId();
    part_depth -= 1;
    if (part_depth < part_stack.len) wg.zui_part = part_stack[part_depth];
    // (a part inside another is drawn with it: the viewport's panels, over
    // the view it renders after them)
    if (part_depth == 0) renderNow(z);
}

/// Parts begun and not ended: a part described inside another (the panels
/// over the 3D viewport) is drawn when the outer one ends.
var part_depth: usize = 0;
var part_stack: [8]u64 = undefined;

/// A mark in this frame's claims (`claimedSince`).
pub fn claimMark() usize {
    return claims_n;
}

/// Whether (x, y) is in a rect claimed since `mark`: a part described
/// inside another over a canvas (a panel over the viewport) that a press
/// there belongs to.
pub fn claimedSince(mark: usize, x: i32, y: i32) bool {
    for (claims[@min(mark, claims_n)..claims_n]) |c| if (c.r.contains(x, y)) return true;
    return false;
}

/// Pointer events Zui has not had a frame for yet (its log is not empty).
pub fn pointerPending() bool {
    const s = state orelse return false;
    // (moves alone count while a button is held: a drag's)
    const down = s.ui.input.mouse_down.count() > 0;
    for (s.ui.input.pointerEvents()) |e| if (e.kind != .move or down) return true;
    return false;
}

/// A modal client of Zui's is up (a dialog, the Ask AI box, a menu): the
/// parts under it take no input.
pub fn modalOpen() bool {
    return modal() != null;
}

/// Whether a press or the wheel at (x, y) units is for something of Zui's
/// in front of the parts: a modal client (a dialog, the Ask AI box, a menu
/// over everything), or a window or popup shown there. A canvas under
/// them (the viewport) leaves it to them.
pub fn inFront(x: i32, y: i32) bool {
    if (modal() != null) return true;
    const p: zui.Vec2 = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    return st().ui.windowShownAt(p);
}

/// Whether a button is down as Zui saw it last: a press over a part of
/// Zui's (the viewport) never reaches BeeModel's own `ui.down`.
pub fn buttonDown(b: zui.MouseButton) bool {
    return st().ui.input.mouse_down.contains(b);
}

/// A file dropped on the window at `pos` (units), for Zui's next frame.
pub fn fileDrop(path: []const u8, pos: [2]f32) void {
    st().ui.input.onFileDrop(path, .{ .x = pos[0], .y = pos[1] });
    had_input = true;
    settle_wanted = true;
    app.dirty = true;
}

/// The drop has been handled (drop.flush): no frame after sees it again.
pub fn clearDrops() void {
    const in = &st().ui.input;
    in.drop_count = 0;
    in.drop_len = 0;
}

/// A pen's pressure for the pointer events after it (Zui's event log).
pub fn pen(pressure: f32) void {
    st().ui.input.onPressure(pressure);
}

/// BeeModel's cursor as Zui's, for a part that owns the pointer and sets
/// its shape the old way (the viewport's tools).
pub fn cursorFrom(z: *zui.Ui, c: @TypeOf(ui.cursor)) void {
    z.cursor = switch (c) {
        .default => return,
        .pointer => .pointer,
        .crosshair => .crosshair,
        .text => .text,
        .move => .move,
        .not_allowed => .not_allowed,
        .grab => .grab,
        .grabbing => .grabbing,
        .ew_resize => .resize_ew,
        .ns_resize => .resize_ns,
        .nesw_resize => .resize_nesw,
        .nwse_resize => .resize_nwse,
    };
}

fn renderNow(z: *zui.Ui) void {
    const end = z.rootCommandCount();
    const v = z.rootView(rendered_upto, end);
    render(&v);
    rendered_upto = end;
}

/// A Zui part in the flow of BeeModel's own page: its top-left at (x, y),
/// `w` wide, as tall as what is described in it, shown inside `clip` (the
/// page's view). Null in the hit pass. End with `endFlowPart`, which says
/// how tall it was. The wheel over it stays the page's.
pub fn beginFlowPart(name: []const u8, salt: usize, x: i32, y: i32, w: i32, clip: Rect) ?*zui.Ui {
    if (!ui.cv.enabled) {
        hitPassPart(name, salt);
        return null;
    }
    const z = ensureFrame();
    z.pushIdInt(salt);
    const region = z.id(name);
    wg.zui_part = @intFromEnum(region);
    z.pushIdValue(region);
    flow_stack[flow_n] = .{ .x = x, .y = y, .w = w, .clip = clip };
    flow_n += 1;
    // (BeeModel's panels: a row each 26, 22 high)
    z.pushMetric(.item_spacing, .{ .x = 6, .y = 4 });
    // (a field's natural width fits a narrow column: .fill widens it)
    z.pushMetric(.widget_width, 60);
    // (as tall as the page can show below y: the content measures itself)
    z.beginRegion(region, zr(.{ .x = x, .y = y, .w = w, .h = @max(1, clip.bottom() - y) }), .vertical, 0, .start);
    z.pushClip(zr(clip));
    return z;
}

/// Ends `beginFlowPart` and draws it: the part's height, in units.
pub fn endFlowPart(z: *zui.Ui) i32 {
    z.popClip();
    const h: i32 = @intFromFloat(@ceil(z.current().layout.finish().content.y));
    z.endRegion();
    z.popStyles(2);
    z.popId();
    z.popId();
    flow_n -= 1;
    const f = flow_stack[flow_n];
    const r = (Rect{ .x = f.x, .y = f.y, .w = f.w, .h = h }).intersect(f.clip);
    if (r.w > 0 and r.h > 0 and claims_n < claims.len) {
        claims[claims_n] = .{ .r = r, .layer = ui.layer, .wheel = false };
        claims_n += 1;
    }
    renderNow(z);
    return h;
}

/// A part's place in BeeModel's hit pass: its fields and buttons of the
/// last draw pass go back in BeeModel's list of widgets there (wg), for the
/// focus ring and the field menu.
fn hitPassPart(name: []const u8, salt: usize) void {
    const z = &st().ui;
    z.pushIdInt(salt);
    const region = z.id(name);
    z.popId();
    wg.replayZui(@intFromEnum(region));
}

const Flow = struct { x: i32, y: i32, w: i32, clip: Rect };
var flow_stack: [4]Flow = undefined;
var flow_n: usize = 0;

/// Zui's frame ends here, in BeeModel's draw pass (app.frame, at the dialog
/// layer): the shown dialogs described, then what the parts left (Zui's
/// windows, popups, tooltips) and the dialogs drawn over the canvas, and
/// the widgets put in the record.
pub fn frame() void {
    const cv = ui.cv;
    if (!cv.enabled) return;
    if (!in_frame and !anyDialog()) {
        ran_last = false;
        claims_n = 0;
        wake_at = null;
        settle_wanted = false;
        dialog_rect = null;
        return;
    }
    const z = ensureFrame();
    const had_modal = modal() != null;
    inline for (clients) |c| {
        if (c.visible()) {
            c.describe(z);
            // (a dialog that closed in its own frame, on Escape or a button, claims nothing)
            if (c.modal and c.visible()) claimModal(.{ .x = 0, .y = 0, .w = cv.uw, .h = cv.uh });
        }
    }
    // A modal dialog that closed in this frame (OK, Esc) takes its focus
    // and its hold on the keys with it: Zui would count it as shown until
    // the next frame, and the next key is BeeModel's (another part of
    // Zui's stays on screen, the Properties, so the keys still go by it).
    if (had_modal and modal() == null) {
        z.focused = .none;
        z.feedback_state.shown_now = false;
        z.feedback_state.shown_id_now = .none;
    }
    in_frame = false;
    ran_last = true;
    const list = z.endFrame() catch return;

    inline for (clients) |c| {
        if (c.under) |f| if (c.visible()) f();
    }
    // The root commands the parts drew are first in the list, in the same places.
    const rest = list.view(@min(rendered_upto, list.commands.items.len), list.commands.items.len);
    render(&rest);

    // The eyedropper's pixel, from the window as drawn (Zui's colour picker).
    if (z.sample_request) |p| {
        const x = cv.toPx(@intFromFloat(p.x));
        const y = cv.toPx(@intFromFloat(p.y));
        if (x >= 0 and y >= 0 and x < cv.w and y < cv.h) {
            const c = cv.px[@intCast(y * cv.w + x)] & 0xffffff;
            if (z.input.onColorSample(col(c))) app.dirty = true;
        }
    }
    if (z.clickedToast() != null) app.toastClicked();
    bridgeRecord(z);
    // A tooltip of Zui's tells the Help area too, as BeeModel's own do
    // (one without a title: the hovered widget's label, a menu entry's).
    if (z.shown_tip) |t| {
        var title = t.title;
        if (title.len == 0) for (z.widgets()) |w| if (w.hovered and w.kind != .popup and w.kind != .window) {
            title = labelOf(w);
        };
        @import("helped.zig").note(title, t.body, t.warning);
    }
    // Zui's cursor where the pointer is Zui's; BeeModel's own elsewhere
    // (the brush's crosshair in the view beside a bar).
    {
        const mx: i32 = @intFromFloat(z.input.mouse_pos.x);
        const my: i32 = @intFromFloat(z.input.mouse_pos.y);
        if (modal() != null or pointerOwned(st(), mx, my)) ui.cursor = cursorOf(z.cursor);
    }
    // What Zui's widgets did (a button's operator, a value) happened in this
    // draw pass, after BeeModel drew the rest: one more frame shows it there.
    settle_wanted = z.redraw_requested or acted or had_other or (had_input and !view_took_all);
    // What Zui's widgets changed is a step of its own, as BeeModel's own
    // input is (app.afterInput, skipped for the events Zui took): once
    // nothing of Zui's is held, so a drag is one step.
    if ((had_input or acted) and z.active == .none and z.canvas_capture == null) app.afterInput();
    had_input = false;
    had_other = false;
    view_took_all = false;
    acted = false;
    if (settle_wanted) app.dirty = true;
    wake_at = if (z.redraw_in) |sec| app.now_ms + @as(i64, @intFromFloat(@ceil(sec * 1000))) else null;
}

/// The last frame asked for another at once: its layout is settling (a
/// dialog sizing itself to its content), or its widgets acted on input
/// after BeeModel drew the rest of the window. The headless driver draws
/// again, as Zui's own script player does, before looking a widget up.
pub fn settling() bool {
    return settle_wanted;
}

/// The value a Zui field (number, text, check box, drop-down) labelled
/// `label` showed in the last frame, for the headless driver's
/// --expect-field; null if Zui showed none.
pub fn fieldValue(label: []const u8) ?[]const u8 {
    if (!ran_last) return null;
    const z = &(state orelse return null).ui;
    for (z.widgets()) |w| {
        switch (w.kind) {
            .number, .slider, .text_input, .text_area, .checkbox, .dropdown => {},
            else => continue,
        }
        if (std.mem.eql(u8, zui.Ui.visibleLabel(w.label), label) or std.mem.eql(u8, w.label, label)) return w.value orelse "";
    }
    return null;
}

/// A left press this frame outside the modal Zui dialog shown last frame:
/// for dialogs that close on a click outside, as BeeModel's About.
pub fn pressedOutsideDialog(z: *const zui.Ui) bool {
    const r = dialog_rect orelse return false;
    if (!z.input.mouse_pressed.contains(.left)) return false;
    return !r.contains(z.input.press_pos.get(.left));
}

/// BeeModel's record kind for a Zui widget, or null to leave it out (Zui's
/// own furniture: labels, scroll areas, tooltips). Widgets BeeModel names
/// itself (keyrow, key, swatch...) go in with ui.record directly.
pub fn kindOf(k: zui.WidgetKind) ?[]const u8 {
    return switch (k) {
        .button, .selectable, .segment, .dropdown, .card => "button",
        .checkbox => "checkbox",
        .number, .slider => "number",
        .text_input, .text_area => "text",
        // (a submenu's row is an entry too: BeeModel's bar titles are its own)
        .choice, .menu_item, .menu => "menuitem",
        .command => "command",
        .color_edit => "colour",
        .swatch => "swatch",
        .toggle => "toggle",
        .tab => "tab",
        .row => "row",
        .tile => "tile",
        .header => "section",
        .tree_node => "fold",
        .dialog => "dialog",
        .popup => "popup",
        .toast => "toast",
        // (the wheel's entries as BeeModel's; a pie or the wheel itself, nothing)
        .pie_item => if (@import("pies.zig").wheel_open) "wheel" else "pie",
        .theme => "theme",
        else => null,
    };
}

/// The label BeeModel records a widget under: a drop-down by what it
/// shows, a text field by its text (its hint while empty), as BeeModel's.
pub fn labelOf(w: zui.Widget) []const u8 {
    return switch (w.kind) {
        .dropdown => w.value orelse w.label,
        // (a text area by its name: its text is often long, lines of it)
        .text_input => if (w.value) |v| (if (v.len > 0) v else w.label) else w.label,
        else => w.label,
    };
}

fn bridgeRecord(z: *zui.Ui) void {
    dialog_rect = null;
    for (z.widgets()) |w| {
        if (w.kind == .dialog and dialog_rect == null) dialog_rect = w.rect;
        const kind = kindOf(w.kind) orelse continue;
        const label = labelOf(w);
        ui.record(kind, label, rectOf(w.rect), w.enabled);
    }
}

fn cursorOf(c: zui.Cursor) @TypeOf(ui.cursor) {
    return switch (c) {
        .default => .default,
        .text => .text,
        .pointer => .pointer,
        .crosshair => .crosshair,
        .move => .move,
        .not_allowed => .not_allowed,
        .grab => .grab,
        .grabbing => .grabbing,
        .resize_ew => .ew_resize,
        .resize_ns => .ns_resize,
        .resize_nesw => .nesw_resize,
        .resize_nwse => .nwse_resize,
    };
}
