//! Telling people what is going on: modal dialogs, a status bar with key
//! hints, toasts, progress bars and job chips, and cards.
//!
//!     if (ui.beginDialog("Save changes?", &asking, .{})) {
//!         defer ui.endDialog();
//!         ui.label("The scene has changes that aren't saved.", .{});
//!         switch (ui.dialogButtons(&.{ "Save", "Don't Save", "Cancel" }, .{ .default = 0, .cancel = 2 }) orelse 3) {
//!             0 => { save(); asking = false; },
//!             1 => { discard(); asking = false; },
//!             2 => asking = false,
//!             else => {},
//!         }
//!     }
//!
//!     ui.beginStatusBar();
//!     ui.keyHint("G", "Move");
//!     ui.spacer(.fill);
//!     _ = ui.jobChip("Rendering", 0.48, 4.2, .{});
//!     ui.endStatusBar();
//!
//!     ui.toast("Saved chair.bee", .success, .{});

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const icons = @import("icons.zig");
const ui_mod = @import("ui.zig");
const window = @import("window.zig");
const record = @import("record.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;
const Color = draw.Color;

// ---- dialogs -----------------------------------------------------------------

/// Options for `beginDialog`.
pub const DialogOptions = struct {
    /// The content is at least this wide.
    min_width: f32 = 320,
    /// A click outside the dialog closes it (sets `open` to false), like
    /// Escape: for dialogs that only show something (About, a list).
    close_on_outside: bool = false,
};

/// Options for `dialogButtons`.
pub const DialogButtonOptions = struct {
    /// The button Enter presses, drawn in the accent color.
    default: ?usize = null,
    /// The button Escape presses.
    cancel: ?usize = null,
    /// Why a button can't be pressed now, per button (shorter is fine).
    disabled: []const ?[]const u8 = &.{},
};

/// Dialog state kept in the `Ui`.
pub const State = struct {
    /// Escape was pressed for the dialog being described.
    escape: bool = false,
    escape_used: bool = false,
    enter: bool = false,
    open: ?*bool = null,
    saved_scope: Id = .none,
    /// The dialog shown last frame; it takes all the pointer input.
    shown: bool = false,
    shown_now: bool = false,
    /// The dialog shown last frame, whose scope Tab is kept to.
    shown_id: Id = .none,
    shown_id_now: Id = .none,
    focus_first: bool = false,
    toasts: [max_toasts]Toast = undefined,
    toast_count: usize = 0,
    next_toast: u32 = 1,
    clicked_toast: ?u32 = null,
    clicked_next: ?u32 = null,
    /// Where the toasts were drawn last frame, with their ids.
    toast_rects: [max_toasts]struct { id: u32, rect: Rect } = undefined,
    toast_rect_count: usize = 0,
};

/// Called by `Ui.beginFrame`.
pub fn beginFrame(ui: *Ui) void {
    const st = &ui.feedback_state;
    st.shown = st.shown_now;
    st.shown_now = false;
    st.shown_id = st.shown_id_now;
    st.shown_id_now = .none;

    st.clicked_toast = null;
    // A press on a toast is the toast's: nothing under it sees it.
    const in = &ui.input;
    if (in.mouse_pressed.contains(.left)) {
        for (st.toast_rects[0..st.toast_rect_count]) |t| {
            if (t.rect.contains(in.press_pos.get(.left))) {
                st.clicked_toast = t.id;
                in.mouse_pressed.remove(.left);
                in.mouse_down.remove(.left);
                break;
            }
        }
    }
}

/// True if a modal dialog was shown last frame: keys and the pointer belong
/// to it, so the app should leave its shortcuts alone.
pub fn dialogOpen(ui: *const Ui) bool {
    return ui.feedback_state.shown;
}

/// Starts a modal dialog titled `title` while `open.*` is true: centered,
/// sized to its content, over a dimmed window. Nothing behind it takes the
/// pointer or Tab. Escape closes it (or presses the cancel button). When it
/// returns true, describe the content and call `endDialog`.
pub fn beginDialog(ui: *Ui, title: []const u8, open: *bool, options: DialogOptions) bool {
    const st = &ui.feedback_state;
    if (!open.*) return false;
    std.debug.assert(ui.layout_depth < Ui.max_layout_depth);
    const dialog_id = ui.id(title);
    const w = window.getOrCreate(ui, dialog_id, .{}) catch |err| {
        ui.fail(err);
        return false;
    };
    // Just opened: new (never shown, as in the first frames of a Ui), or not
    // shown last frame.
    if (w.last_frame == 0 or w.last_frame + 1 < ui.frame_index) st.focus_first = true;
    // A click outside, on a dialog that was there last frame, closes it.
    if (options.close_on_outside and w.last_frame + 1 == ui.frame_index and ui.input.mouse_pressed.contains(.left) and
        !w.rect.contains(ui.input.press_pos.get(.left)))
    {
        open.* = false;
        w.last_frame = 0;
        return false;
    }
    w.dialog = true;
    w.popup = false;
    w.collapsed = false;
    w.scroll = 0;
    window.raise(ui, w);
    w.last_frame = ui.frame_index;
    w.described_frame = ui.frame_index;
    st.shown_now = true;
    st.shown_id_now = dialog_id;

    const style = &ui.style;
    const p = style.window_padding;
    const title_h = ui.textSize("").y + 2 * style.frame_padding.y;
    const measure = ui.measures.get(dialog_id);
    w.hidden = measure == null;
    // What the content needs, not what its fill rows were stretched to, so
    // it can get smaller again.
    const content = if (measure) |m| m.natural(.vertical, 0) else Vec2{};
    const size: Vec2 = .{
        .x = @min(@max(options.min_width, content.x) + 2 * p, ui.width - 16),
        .y = @min(content.y + 2 * p + title_h, ui.height - 16),
    };
    w.rect = .{ .x = @round((ui.width - size.x) / 2), .y = @round(@max(8, (ui.height - size.y) * 0.4)), .w = size.x, .h = size.y };
    w.title_height = title_h;

    w.saved_list = ui.list;
    w.saved_window = ui.current_window;
    w.saved_clip_depth = ui.clip_depth;
    w.grip = null;
    w.list.clear();
    ui.list = &w.list;
    ui.current_window = w;
    w.saved_record_parent = record.enterContainer(ui, .dialog, dialog_id, title, w.rect, .{});
    ui.pushIdValue(dialog_id);
    ui.pushClipAbsolute(.{ .w = ui.width, .h = ui.height });
    st.saved_scope = ui.pushFocusScope(dialog_id);
    // Tab is kept inside: from now, and all of next frame.
    ui.nav_scope = dialog_id;
    ui.nav_scope_next = dialog_id;

    const colors = &style.colors;
    ui.drawShadow(w.rect, style.window_rounding, colors.window);
    ui.drawRect(.{ .rect = w.rect, .fill = colors.window, .border = colors.border, .border_width = style.border_width, .radius = style.window_rounding });
    ui.drawText(.{ .x = w.rect.x + p, .y = w.rect.y + style.frame_padding.y }, colors.title_text, Ui.visibleLabel(title));
    ui.drawRect(.{ .rect = .{ .x = w.rect.x, .y = w.rect.y + title_h, .w = w.rect.w, .h = 1 }, .fill = colors.separator });

    // Escape is decided when it is needed (dialogButtons, endDialog), after
    // what is inside had its turn: a field undoing its edit, a drag, a popup
    // closing all take it (they remove it from keys_pressed).
    st.escape = false;
    st.escape_used = false;
    st.enter = ui.input.keys_pressed.contains(.enter) and ui.popup_count == 0;
    st.open = open;

    ui.pushClip(w.rect);
    ui.layouts[ui.layout_depth] = .{
        .id = dialog_id,
        .layout = .init(.{
            .origin = .{ .x = w.rect.x + p, .y = w.rect.y + title_h + p },
            .spacing = style.item_spacing,
            .cross_extent = @max(0, w.rect.w - 2 * p),
            .previous = measure orelse .{},
        }),
    };
    ui.layout_depth += 1;
    return true;
}

/// Escape for the dialog: pressed this frame and not taken by anything in it
/// (a field undoing its edit, a drag put back, a popup closing), with no
/// field being typed in and no popup open.
fn dialogEscape(ui: *const Ui) bool {
    return ui.input.keys_pressed.contains(.escape) and ui.popup_count == 0 and
        (ui.focused == .none or ui.focused != ui.text_edit.id);
}

/// Ends the dialog started by `beginDialog`.
pub fn endDialog(ui: *Ui) void {
    const st = &ui.feedback_state;
    const w = ui.current_window orelse unreachable; // endDialog without beginDialog
    std.debug.assert(w.dialog and ui.current().id == w.id); // a group inside the dialog was not ended
    const measure = ui.current().layout.finish();
    ui.layout_depth -= 1;
    ui.storeMeasure(w.id, measure);
    if (dialogEscape(ui) and !st.escape_used) {
        ui.input.keys_pressed.remove(.escape);
        if (st.open) |o| o.* = false;
    }
    // Answered or closed this frame: not there for next frame's hit test.
    if (st.open) |o| if (!o.*) {
        w.last_frame = 0;
    };
    ui.popFocusScope(st.saved_scope);
    window.restore(ui, w);
    st.open = null;
}

/// A row of buttons at the bottom right of a dialog. Returns the index of
/// the one pressed this frame: clicked, Enter for `default` (unless a
/// button has focus, which Enter then presses), Escape for `cancel`.
pub fn dialogButtons(ui: *Ui, labels: []const []const u8, options: DialogButtonOptions) ?usize {
    const st = &ui.feedback_state;
    var picked: ?usize = null;
    ui.spacer(.{ .fixed = 4 });
    ui.beginHorizontal(.{ .width = .fill, .justify = .end });
    var any_focused = false;
    for (labels) |label| {
        if (ui.focused == ui.id(label)) any_focused = true;
    }
    // On opening, the default button has the focus, so Tab starts there.
    if (st.focus_first) {
        st.focus_first = false;
        if (options.default) |d| if (d < labels.len) ui.setFocus(ui.id(labels[d]));
    }
    for (labels, 0..) |label, i| {
        const why = if (i < options.disabled.len) options.disabled[i] else null;
        ui.pushDisabled(why);
        const is_default = options.default == i;
        const r = ui.button(label, .{ .variant = if (is_default) .primary else .normal });
        ui.popDisabled();
        if (r.clicked) picked = i;
        // Enter that a text field took to end its typing is the field's.
        const field_has_enter = ui.enter_taken or (ui.focused != .none and ui.focused == ui.text_edit.id);
        if (why == null and is_default and st.enter and !any_focused and !field_has_enter) picked = i;
        if (why == null and options.cancel == i and dialogEscape(ui)) {
            picked = i;
            st.escape_used = true;
            ui.input.keys_pressed.remove(.escape);
        }
    }
    ui.endHorizontal();
    return picked;
}

// ---- status bar ------------------------------------------------------------------

/// Starts a status bar: a row across the layout, in the title color. Put it
/// last, below a `.fill` area. End it with `endStatusBar`.
pub fn beginStatusBar(ui: *Ui) void {
    ui.beginHorizontal(.{ .width = .fill, .fill = ui.style.colors.title, .padding = 3, .spacing = 10 });
}

/// Ends the status bar.
pub fn endStatusBar(ui: *Ui) void {
    ui.endHorizontal();
}

/// A key and what it does, as a chip and a word: "G Move". `keys` may hold
/// several keys separated by spaces ("Shift Click").
pub fn keyHint(ui: *Ui, keys: []const u8, action: []const u8) void {
    const style = &ui.style;
    const colors = &style.colors;
    const line_h = ui.textSize("").y;
    var it = std.mem.tokenizeScalar(u8, keys, ' ');
    var widths: f32 = 0;
    var count: f32 = 0;
    while (it.next()) |k| {
        widths += ui.textSize(k).x + 10;
        count += 1;
    }
    const action_w = ui.textSize(action).x;
    const rect = ui.place(.{ .x = widths + (count - 1) * 3 + 6 + action_w, .y = line_h + 2 });
    var x = rect.x;
    it = std.mem.tokenizeScalar(u8, keys, ' ');
    while (it.next()) |k| {
        const w = ui.textSize(k).x + 10;
        ui.drawRect(.{ .rect = .{ .x = x, .y = rect.y, .w = w, .h = rect.h }, .fill = colors.button, .border = colors.border, .border_width = 1, .radius = 3 });
        ui.drawText(.{ .x = x + 5, .y = rect.y + 1 }, colors.text, k);
        x += w + 3;
    }
    ui.drawText(.{ .x = x + 3, .y = rect.y + 1 }, colors.text_muted, action);
    ui.recordWidget(.key_hint, .none, action, rect, .{ .value = keys });
}

// ---- toasts ------------------------------------------------------------------

/// What a toast is about.
pub const ToastKind = enum { info, success, warning, failure };

/// Options for `toast`.
pub const ToastOptions = struct {
    /// How long it stays.
    seconds: f32 = 4,
};

const max_toasts = 6;

const Toast = struct {
    id: u32,
    kind: ToastKind,
    text: [160]u8,
    len: usize,
    left: f32,
    /// Not shown yet: its time starts in the frame that first shows it
    /// (not with the time since the frame before it was made).
    fresh: bool = true,
};

/// Shows a short message above the bottom of the window for a few seconds:
/// green for results, amber for problems. Returns its id, which
/// `clickedToast` reports when someone clicks it. The newest is at the
/// bottom; at most six show.
pub fn toast(ui: *Ui, text: []const u8, kind: ToastKind, options: ToastOptions) u32 {
    const st = &ui.feedback_state;
    if (st.toast_count == max_toasts) {
        std.mem.copyForwards(Toast, st.toasts[0 .. max_toasts - 1], st.toasts[1..max_toasts]);
        st.toast_count -= 1;
    }
    const t = &st.toasts[st.toast_count];
    t.* = .{ .id = st.next_toast, .kind = kind, .text = undefined, .len = @import("font.zig").fitUtf8(text, 160), .left = options.seconds };
    @memcpy(t.text[0..t.len], text[0..t.len]);
    st.toast_count += 1;
    st.next_toast += 1;
    ui.requestRedraw();
    return t.id;
}

/// The toast clicked this frame, by the id `toast` returned. A click on a
/// toast never reaches what is under it.
pub fn clickedToast(ui: *const Ui) ?u32 {
    return ui.feedback_state.clicked_toast;
}

/// Ages and draws the toasts. Called by `Ui.endFrame`.
pub fn endFrame(ui: *Ui) void {
    const st = &ui.feedback_state;
    // Age them, drop the expired ones.
    var n: usize = 0;
    for (st.toasts[0..st.toast_count]) |t| {
        var kept = t;
        if (kept.fresh) kept.fresh = false else kept.left -= ui.dt;
        if (kept.left > 0) {
            st.toasts[n] = kept;
            n += 1;
        }
    }
    st.toast_count = n;
    st.toast_rect_count = 0;
    if (n == 0) return;
    // Sleep until the next one expires; nothing moves in between.
    var soonest: f32 = std.math.inf(f32);
    for (st.toasts[0..n]) |t| soonest = @min(soonest, t.left);
    ui.requestRedrawIn(soonest);

    const style = &ui.style;
    const colors = &style.colors;
    const pad = style.frame_padding;
    const line_h = ui.textSize("").y;
    var y = ui.height - ui.toast_margin;
    var i = n;
    while (i > 0) {
        i -= 1;
        const t = st.toasts[i];
        const text = t.text[0..t.len];
        const icon_w = line_h + 6;
        const w = @min(ui.textSize(text).x + icon_w + 2 * pad.x, ui.width - 16);
        const h = line_h + 2 * pad.y;
        y -= h;
        const x = switch (ui.toast_align) {
            .center => @round((ui.width - w) / 2),
            .right => @round(@max(0, ui.width - w - 12)),
        };
        const rect: Rect = .{ .x = x, .y = y, .w = w, .h = h };
        y -= 6;
        const tint = switch (t.kind) {
            .success => Color.hex(0x3C9A5F),
            .warning => colors.warning,
            .failure => Color.hex(0xD0453B),
            .info => colors.accent,
        };
        if (st.toast_rect_count < max_toasts) {
            st.toast_rects[st.toast_rect_count] = .{ .id = t.id, .rect = rect };
            st.toast_rect_count += 1;
        }
        ui.overlay.setClip(null) catch {};
        ui.overlay.addShadow(.{ .rect = rect.inset(-1), .radius = style.rounding, .blur = style.shadow_blur / 2, .color = colors.shadow }) catch {};
        ui.overlay.addRect(.{ .rect = rect, .fill = colors.popup, .border = tint, .border_width = 1, .radius = style.rounding }) catch {};
        const icon: icons.Icon = .{ .builtin = switch (t.kind) {
            .success => .check,
            .warning => .warning,
            .failure => .close,
            .info => .info,
        } };
        icons.draw(&ui.overlay, icon, .{ .x = rect.x + pad.x, .y = rect.y + pad.y, .w = line_h, .h = line_h }, tint) catch {};
        const metrics = ui.font.lineMetrics(style.font_size);
        ui.overlay.addText(.{ .font = ui.font, .pos = .{ .x = rect.x + pad.x + icon_w, .y = rect.y + pad.y + metrics.ascent }, .size = style.font_size, .color = colors.text, .text = text }) catch {};
        record.recordOverlay(ui, .toast, @enumFromInt(t.id), text, rect);
    }
}

// ---- progress ----------------------------------------------------------------------

/// Options for `progressBar`.
pub const ProgressOptions = struct {
    width: layout.Size = .fill,
    height: f32 = 6,
};

/// A bar filled to `fraction` (0..1), or, when that is unknown (null), a
/// short bar gliding along, which asks for frames only while shown.
pub fn progressBar(ui: *Ui, fraction: ?f32, options: ProgressOptions) void {
    // Filling, it asks for little, so it fits narrow panels.
    const natural: f32 = if (options.width == .auto) ui.style.widget_width else 24;
    const rect = ui.placeSized(options.width, .{ .fixed = options.height }, .{ .x = natural, .y = options.height });
    drawBar(ui, rect, fraction);
    var b: [16]u8 = undefined;
    const value = if (fraction) |f| std.fmt.bufPrint(&b, "{d:.0}%", .{std.math.clamp(f, 0, 1) * 100}) catch "?" else "busy";
    ui.recordWidget(.progress, .none, "progress", rect, .{ .value = value });
}

fn drawBar(ui: *Ui, rect: Rect, fraction: ?f32) void {
    const colors = &ui.style.colors;
    ui.drawRect(.{ .rect = rect, .fill = colors.button, .radius = rect.h / 2 });
    if (fraction) |f| {
        const w = rect.w * std.math.clamp(f, 0, 1);
        if (w > 0) ui.drawRect(.{ .rect = .{ .x = rect.x, .y = rect.y, .w = w, .h = rect.h }, .fill = colors.accent, .radius = rect.h / 2 });
    } else {
        // A quarter of the width gliding across every 1.4 seconds.
        if (ui.glide_frame != ui.frame_index) {
            ui.glide_frame = ui.frame_index;
            ui.glide_time += ui.dt;
        }
        const t = @mod(ui.glide_time, 1.4) / 1.4;
        const w = rect.w * 0.25;
        const x = rect.x - w + (rect.w + w) * t;
        const seg = (Rect{ .x = x, .y = rect.y, .w = w, .h = rect.h }).intersect(rect);
        if (!seg.isEmpty()) ui.drawRect(.{ .rect = seg, .fill = colors.accent, .radius = rect.h / 2 });
        ui.requestRedrawIn(1.0 / 60.0);
    }
}

/// Options for `jobChip`.
pub const JobOptions = struct {
    /// Shown at the right, such as "Stop"; a click on the chip reports
    /// `clicked` either way.
    action: []const u8 = "",
};

/// A long job as BeeModel's status bar shows it: its name, the percentage,
/// how long it has taken and (once a twentieth is done and two seconds have
/// passed) about how long is left, with a bar along the bottom. `fraction`
/// null means unknown: the bar glides. `elapsed` is in seconds.
pub fn jobChip(ui: *Ui, name: []const u8, fraction: ?f32, elapsed: f32, options: JobOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    var buffer: [160]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    w.writeAll(name) catch {};
    if (fraction) |f| w.print(" {d:.0}%", .{std.math.clamp(f, 0, 1) * 100}) catch {};
    if (elapsed >= 1) w.print(", {d:.0} s", .{elapsed}) catch {};
    if (fraction) |f| if (f >= 0.05 and elapsed >= 2 and f < 1) {
        const left = elapsed * (1 - f) / f;
        w.print(", about {d:.0} s left", .{@max(1, left)}) catch {};
    };
    if (options.action.len > 0) w.print("   {s}", .{options.action}) catch {};
    const text = w.buffered();
    const line_h = ui.textSize("").y;
    const rect = ui.place(.{ .x = ui.textSize(text).x + 16, .y = line_h + 6 });
    const widget = ui.id(name);
    const r = ui.interact(widget, rect);
    ui.drawRect(.{ .rect = rect, .fill = if (r.hovered) colors.button_hovered else colors.button, .radius = 4 });
    ui.drawText(.{ .x = rect.x + 8, .y = rect.y + 2 }, colors.text, text);
    drawBar(ui, .{ .x = rect.x + 3, .y = rect.bottom() - 3, .w = rect.w - 6, .h = 2 }, fraction);
    ui.recordWidget(.job, widget, name, rect, .{ .value = text, .hovered = r.hovered });
    return r;
}

// ---- cards -------------------------------------------------------------------

/// Options for `card`.
pub const CardOptions = struct {
    width: f32 = 180,
    /// Height of the picture part.
    picture_height: f32 = 110,
    image: ?*const draw.Image = null,
    icon: ?icons.Icon = null,
    subtitle: []const u8 = "",
    disabled: ?[]const u8 = null,
};

/// A large button with a picture (an image or an icon) and a title and
/// subtitle below: templates, recent files, samples on a welcome screen.
pub fn card(ui: *Ui, title: []const u8, options: CardOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    const line_h = ui.textSize("").y;
    const text_h = line_h * (if (options.subtitle.len > 0) @as(f32, 2) else 1) + 12;
    ui.pushDisabled(options.disabled);
    defer ui.popDisabled();
    const rect = ui.place(.{ .x = options.width, .y = options.picture_height + text_h });
    const widget = ui.id(title);
    var r = ui.interact(widget, rect);
    ui.focusable(widget, &r);
    if (@import("widgets.zig").keyActivated(ui, r)) r.clicked = true;
    ui.drawRect(.{ .rect = rect, .fill = if (r.hovered) colors.button_hovered else colors.button, .border = if (r.hovered) colors.accent else colors.border, .border_width = 1, .radius = style.window_rounding });
    const pic: Rect = .{ .x = rect.x + 6, .y = rect.y + 6, .w = rect.w - 12, .h = options.picture_height - 6 };
    if (options.image) |img| {
        ui.painter().image(img, pic, .{});
    } else {
        ui.drawRect(.{ .rect = pic, .fill = colors.input, .radius = style.rounding });
        if (options.icon) |ic| {
            const s = @min(pic.w, pic.h) * 0.45;
            ui.painter().icon(ic, .{ .x = pic.x + (pic.w - s) / 2, .y = pic.y + (pic.h - s) / 2, .w = s, .h = s }, colors.text_muted);
        }
    }
    ui.pushClip(rect);
    ui.drawText(.{ .x = rect.x + 10, .y = rect.y + options.picture_height + 6 }, colors.text, title);
    if (options.subtitle.len > 0) ui.drawText(.{ .x = rect.x + 10, .y = rect.y + options.picture_height + 6 + line_h }, colors.text_muted, options.subtitle);
    ui.popClip();
    ui.drawFocusRing(widget, rect);
    ui.recordWidget(.card, widget, title, rect, .{ .hovered = r.hovered, .focused = r.focused });
    return r;
}
