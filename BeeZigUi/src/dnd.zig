//! Drag and drop inside the UI: drag rows onto rows, tiles onto a viewport,
//! palette entries onto a canvas. And files dropped onto the window.
//!
//!     // The source, right after its widget:
//!     _ = ui.dragSource(row, .{ .kind = "object", .data = index, .label = name });
//!
//!     // A target:
//!     if (ui.dropZone(other_row.rect, "object")) |drop| {
//!         if (makesLoop(drop.data, other)) {
//!             ui.refuseDrop("It would be its own parent");
//!         } else {
//!             ui.dropHint("Child of Cube");
//!             if (drop.released) reparent(drop.data, other);
//!         }
//!     }
//!
//! While dragging, a label at the pointer shows what is dragged and what
//! letting go there would do; the zone under the pointer lights up. Escape
//! cancels.

const std = @import("std");
const draw = @import("draw.zig");
const ui_mod = @import("ui.zig");
const record = @import("record.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;

/// What is being dragged.
pub const Payload = struct {
    /// What sort of thing, matched by `dropZone`: "object", "asset".
    kind: []const u8,
    /// The app's handle for it: an index, an id.
    data: u64 = 0,
    /// Shown at the pointer, such as the object's name or "3 objects".
    label: []const u8 = "",
};

/// A drag over a drop zone, from `dropZone`.
pub const Drop = struct {
    data: u64,
    /// The button went up over the zone this frame: do it now (unless the
    /// drop was refused).
    released: bool,
};

/// Drag state kept in the `Ui`.
pub const State = struct {
    phase: enum { none, pending, active } = .none,
    source: Id = .none,
    start: Vec2 = .{},
    kind: [64]u8 = undefined,
    kind_len: usize = 0,
    /// The whole kind, hashed: kinds longer than `kind` are told apart too.
    kind_hash: u64 = 0,
    data: u64 = 0,
    label: [96]u8 = undefined,
    label_len: usize = 0,
    hint: [96]u8 = undefined,
    hint_len: usize = 0,
    refused: bool = false,
    over_zone: bool = false,
    released: bool = false,
};

/// How far the pointer must move before a press becomes a drag.
const threshold = 6;

/// Called by `Ui.beginFrame`.
pub fn beginFrame(ui: *Ui) void {
    const st = &ui.drag_state;
    if (st.released) st.* = .{};
    st.hint_len = 0;
    st.refused = false;
    st.over_zone = false;
    if (st.phase != .none) {
        const in = &ui.input;
        if (in.keys_pressed.contains(.escape)) {
            st.* = .{};
            in.keys_pressed.remove(.escape);
        } else if (in.mouse_released.contains(.left) or !in.mouse_down.contains(.left)) {
            if (st.phase == .active) st.released = true else st.* = .{};
        }
    }
}

/// Makes the widget `item` a drag source: a press on it, then a move of a
/// few units, starts dragging `payload`. Returns true while this source's
/// drag goes on. Call it right after the widget.
pub fn dragSource(ui: *Ui, item: Interaction, payload: Payload) bool {
    const st = &ui.drag_state;
    const widget = item.id;
    if (item.pressed and !item.disabled) {
        st.* = .{ .phase = .pending, .source = widget, .start = ui.input.press_pos.get(.left) };
        setPayload(st, payload);
    }
    if (st.source != widget) return false;
    if (st.phase == .pending and item.held and ui.input.mouse_pos.sub(st.start).length() > threshold) {
        st.phase = .active;
        setPayload(st, payload);
    }
    return st.phase == .active;
}

fn setPayload(st: *State, payload: Payload) void {
    st.kind_len = @min(payload.kind.len, st.kind.len);
    @memcpy(st.kind[0..st.kind_len], payload.kind[0..st.kind_len]);
    st.kind_hash = std.hash.Wyhash.hash(0, payload.kind);
    st.data = payload.data;
    st.label_len = @import("font.zig").fitUtf8(payload.label, st.label.len);
    @memcpy(st.label[0..st.label_len], payload.label[0..st.label_len]);
}

/// What is being dragged, if a drag is going on.
pub fn dragging(ui: *const Ui) ?Payload {
    const st = &ui.drag_state;
    if (st.phase != .active) return null;
    return .{ .kind = st.kind[0..st.kind_len], .data = st.data, .label = st.label[0..st.label_len] };
}

/// A place things of `kind` can be dropped. Returns the drag while it is
/// over `rect` (and not clipped away or behind a window); lights the zone
/// up. Check `released` to act on the drop.
pub fn dropZone(ui: *Ui, rect: Rect, kind: []const u8) ?Drop {
    const st = &ui.drag_state;
    if (st.phase != .active or st.kind_hash != std.hash.Wyhash.hash(0, kind)) return null;
    const p = ui.input.mouse_pos;
    const clip = ui.clipRect();
    if (!rect.contains(p) or !clip.contains(p) or ui.hovered_window != ui.current_window) return null;
    st.over_zone = true;
    ui.drawRect(.{ .rect = rect.intersect(clip), .fill = ui.style.colors.accent.withAlpha(50), .border = ui.style.colors.accent, .border_width = 1, .radius = ui.style.rounding });
    return .{ .data = st.data, .released = st.released };
}

/// Says what letting go over the current zone would do, shown under the
/// dragged label: "Child of Cube", "Into Props".
pub fn dropHint(ui: *Ui, text: []const u8) void {
    const st = &ui.drag_state;
    st.hint_len = @import("font.zig").fitUtf8(text, st.hint.len);
    @memcpy(st.hint[0..st.hint_len], text[0..st.hint_len]);
}

/// Refuses a drop over the current zone, saying why; the pointer shows
/// that it can't go there. Don't act on `released` after this.
pub fn refuseDrop(ui: *Ui, reason: []const u8) void {
    dropHint(ui, reason);
    ui.drag_state.refused = true;
}

/// Draws the dragged label at the pointer. Called by `Ui.endFrame`.
pub fn endFrame(ui: *Ui) void {
    const st = &ui.drag_state;
    if (st.phase != .active or st.released) return;
    ui.cursor = if (st.refused) .not_allowed else .move;
    const style = &ui.style;
    const colors = &style.colors;
    const line = ui.font.lineMetrics(style.font_size);
    const label = st.label[0..st.label_len];
    const hint = st.hint[0..st.hint_len];
    const w = @max(ui.textSize(label).x, ui.textSize(hint).x) + 16;
    const lines: f32 = if (hint.len > 0) 2 else 1;
    const h = line.height * lines + 8;
    const m = ui.input.mouse_pos;
    const rect: Rect = .{ .x = m.x + 16, .y = m.y + 12, .w = w, .h = h };
    const list = &ui.overlay;
    list.setClip(null) catch {};
    list.addRect(.{ .rect = rect, .fill = colors.popup.withAlpha(235), .border = if (st.refused) colors.warning else colors.accent, .border_width = 1, .radius = style.rounding }) catch {};
    list.addText(.{ .font = ui.font, .pos = .{ .x = rect.x + 8, .y = rect.y + 4 + line.ascent }, .size = style.font_size, .color = colors.text, .text = label }) catch {};
    if (hint.len > 0) list.addText(.{ .font = ui.font, .pos = .{ .x = rect.x + 8, .y = rect.y + 4 + line.ascent + line.height }, .size = style.font_size, .color = if (st.refused) colors.warning else colors.text_muted, .text = hint }) catch {};
    record.recordOverlay(ui, .drag, .none, label, rect);
    ui.requestRedraw();
}

/// Files dropped onto the window this frame, if they landed in `rect`
/// (not clipped away or behind a window). Iterate with `next`.
pub fn fileDrop(ui: *const Ui, rect: Rect) ?FileDrop {
    const in = &ui.input;
    if (in.drop_count == 0) return null;
    const p = in.drop_pos;
    if (!rect.contains(p) or !ui.clipRect().contains(p) or ui.hovered_window != ui.current_window) return null;
    return .{ .input = in };
}

/// The paths of a file drop.
pub const FileDrop = struct {
    input: *const @import("input.zig").Input,
    index: usize = 0,

    /// How many files.
    pub fn count(self: FileDrop) usize {
        return self.input.drop_count;
    }

    /// The next path, or null after the last.
    pub fn next(self: *FileDrop) ?[]const u8 {
        if (self.index >= self.input.drop_count) return null;
        defer self.index += 1;
        return self.input.droppedFile(self.index);
    }
};
