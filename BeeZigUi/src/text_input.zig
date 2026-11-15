//! Single-line text input: the widget and the editing logic behind it.
//!
//! Text lives in a byte buffer the caller owns, so editing never allocates
//! for the text itself. Only undo history and pastes use memory.

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const input_mod = @import("input.zig");
const ui_mod = @import("ui.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Allocator = std.mem.Allocator;
const Rect = draw.Rect;

/// Options for `textInput`.
pub const TextInputOptions = struct {
    /// Width of the whole widget, label included. Defaults to a 200-unit field.
    width: layout.Size = .auto,
    /// Shown in a muted color while the field is empty.
    hint: []const u8 = "",
    /// A click into the field when it doesn't have focus selects all of its
    /// text, ready to be typed over (as BeeModel's fields do). Without it
    /// the click puts the caret where it landed. A click into the focused
    /// field always places the caret.
    select_on_click: bool = false,
    /// Ctrl+C and Ctrl+X with nothing selected copy (and cut) the whole
    /// text, as in BeeModel's fields. Without it they do nothing then.
    copy_all: bool = false,
};

/// Undo steps kept per focused input.
const max_undo = 64;
/// Seconds for one on-and-off cycle of the caret.
const blink_period: f32 = 1.0;

const Snapshot = struct { text: []u8, caret: usize, anchor: usize };

/// What the last edit was, so that a run of typing undoes as one step.
const EditKind = enum { none, typing, deleting };

/// Editing state of the focused text input. Only one input has focus at a
/// time, so `Ui` holds a single one of these.
pub const State = struct {
    /// The input this state belongs to.
    id: Id = .none,
    /// Byte offset of the caret, on a codepoint boundary.
    caret: usize = 0,
    /// The other end of the selection. Equal to `caret` when nothing is
    /// selected.
    anchor: usize = 0,
    /// How far the text is scrolled to the left, in logical units.
    scroll: f32 = 0,
    /// Seconds since the caret last moved, for blinking.
    blink: f32 = 0,
    /// A mouse drag is extending the selection.
    dragging: bool = false,
    last_edit: EditKind = .none,
    undo: std.ArrayList(Snapshot) = .empty,
    redo: std.ArrayList(Snapshot) = .empty,
    /// The text when focus arrived, for Escape to restore.
    original: std.ArrayList(u8) = .empty,
    /// An editing session is going on (the field had focus).
    open: bool = false,
    /// The text changed during this session.
    dirty: bool = false,
    /// Start a new session at the next frame (undo history, the text Escape
    /// restores), keeping the focus and the keys meanwhile: a console line
    /// after Enter.
    restart: bool = false,

    /// Frees the undo history.
    pub fn deinit(self: *State, allocator: Allocator) void {
        freeAll(&self.undo, allocator);
        freeAll(&self.redo, allocator);
        self.undo.deinit(allocator);
        self.redo.deinit(allocator);
        self.original.deinit(allocator);
    }

    /// Starts editing `text` in the input `id`.
    fn reset(self: *State, ui: *Ui, id: Id, text: []const u8) void {
        freeAll(&self.undo, ui.allocator);
        freeAll(&self.redo, ui.allocator);
        self.original.clearRetainingCapacity();
        self.original.appendSlice(ui.allocator, text) catch |err| ui.fail(err);
        self.* = .{ .id = id, .undo = self.undo, .redo = self.redo, .original = self.original };
    }

    /// The selected byte range, start first.
    pub fn selection(self: *const State) [2]usize {
        return .{ @min(self.caret, self.anchor), @max(self.caret, self.anchor) };
    }

    fn hasSelection(self: *const State) bool {
        return self.caret != self.anchor;
    }
};

fn freeAll(list: *std.ArrayList(Snapshot), allocator: Allocator) void {
    for (list.items) |s| allocator.free(s.text);
    list.clearRetainingCapacity();
}

/// A single-line text field editing the UTF-8 text in `buffer[0..len.*]`.
/// `buffer.len` is the capacity; typing stops when it is full. The label
/// (`name` before any `##`) is shown to the right of the field.
///
/// Click or Tab to focus. Enter or a click elsewhere ends editing; Escape
/// ends it and puts back the text from before.
/// `result.changed` is true on frames that edited the text, and
/// `result.submitted` on the frame Enter was pressed.
///
///     var buffer: [64]u8 = undefined;
///     var len: usize = 0;
///     if (ui.textInput("Name", &buffer, &len, .{}).submitted) save(buffer[0..len]);
pub fn textInput(ui: *Ui, name: []const u8, buffer: []u8, len: *usize, options: TextInputOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    const label_text = Ui.visibleLabel(name);
    const label_size = ui.textSize(label_text);
    const line_h = label_size.y;
    const gap: f32 = if (label_text.len > 0) style.item_spacing.x else 0;
    const height = line_h + style.frame_padding.y * 2;
    const rect = ui.placeSized(options.width, .auto, .{ .x = style.widget_width + gap + label_size.x, .y = height });
    const field: Rect = .{ .x = rect.x, .y = rect.y, .w = @max(0, rect.w - gap - label_size.x), .h = height };
    const widget = ui.id(name);
    var result = ui.interact(widget, field);
    const was_focused = ui.focused == widget;
    ui.focusable(widget, &result);
    editFieldCopy(ui, widget, field, buffer, len, &result, was_focused, options.hint, options.copy_all);
    if (options.select_on_click and result.pressed and !was_focused and ui.focused == widget) {
        ui.text_edit.anchor = 0;
        ui.text_edit.caret = len.*;
        ui.text_edit.dragging = false;
    }
    result.rect = rect;
    if (label_text.len > 0) {
        ui.drawText(.{ .x = field.right() + gap, .y = rect.y + style.frame_padding.y }, colors.text, label_text);
    }
    ui.recordWidget(.text_input, widget, name, field, .{ .value = buffer[0..len.*], .hovered = result.hovered, .focused = result.focused });
    return result;
}

/// The editing and drawing of a text field at `field`, shared with widgets
/// that edit text for a while, such as a number field being typed into.
/// The caller has run `interact` and `focusable` for `widget`, and says
/// whether it had focus before that.
pub fn editField(ui: *Ui, widget: Id, field: Rect, buffer: []u8, len: *usize, result_out: *Interaction, was_focused: bool, hint: []const u8) void {
    editFieldCopy(ui, widget, field, buffer, len, result_out, was_focused, hint, false);
}

/// `editField`, with `copy_all` as in `TextInputOptions`.
pub fn editFieldCopy(ui: *Ui, widget: Id, field: Rect, buffer: []u8, len: *usize, result_out: *Interaction, was_focused: bool, hint: []const u8, copy_all: bool) void {
    const style = &ui.style;
    const colors = &style.colors;
    const line_h = ui.textSize("").y;
    var result = result_out.*;
    defer result_out.* = result;
    len.* = @min(len.*, buffer.len);
    const pad = style.frame_padding.y + 2;
    const inner: Rect = .{ .x = field.x + pad, .y = field.y + style.frame_padding.y, .w = @max(0, field.w - 2 * pad), .h = line_h };
    const input = &ui.input;

    var caret_visible = false;
    const st = &ui.text_edit;
    // Focus moved away (a click elsewhere, Tab): the session ends, kept.
    if (st.open and st.id == widget and ui.focused != widget) {
        st.open = false;
        if (st.dirty) result.committed = true;
    }
    if (ui.focused == widget) {
        var e: Editor = .{ .ui = ui, .st = st, .buffer = buffer, .len = len.*, .copy_all = copy_all };
        if (!was_focused or st.id != widget or st.restart) {
            st.reset(ui, widget, e.text());
            st.open = true;
            // Arriving by keyboard selects everything, ready to retype.
            if (!result.pressed) e.select(0, e.len);
        }
        e.clamp();
        st.blink += ui.dt;

        if (result.pressed) {
            e.press(input.press_pos.get(.left).x - inner.x + st.scroll, input.press_clicks.get(.left), input.modifiers.shift and was_focused);
        } else if (result.held and st.dragging) {
            e.setCaret(e.hit(input.mouse_pos.x - inner.x + st.scroll, .nearest), true);
        }
        if (!result.held) st.dragging = false;

        const keep_focus = e.handleKeys(&result);
        len.* = e.len;
        result.changed = e.changed;
        if (e.changed and !st.dirty and !result.cancelled) {
            st.dirty = true;
            result.started = true;
        }
        if (!keep_focus) {
            ui.setFocus(.none);
            // Enter keeps the edit, Escape (which reverted it) cancels.
            if (st.dirty and !result.cancelled) result.committed = true;
            if (!st.dirty) result.cancelled = false;
            st.open = false;
        }

        // Keep the caret in view, and don't leave empty space on the right
        // once text is deleted.
        const text = buffer[0..len.*];
        const caret_x = ui.textSize(text[0..st.caret]).x;
        const total = ui.textSize(text).x;
        if (caret_x - st.scroll > inner.w - 1) st.scroll = caret_x - inner.w + 1;
        if (caret_x < st.scroll) st.scroll = caret_x;
        st.scroll = std.math.clamp(st.scroll, 0, @max(0, total - inner.w + 1));

        if (ui.focused == widget) {
            const phase = @mod(st.blink, blink_period);
            caret_visible = phase < blink_period / 2;
            ui.requestRedrawIn(if (caret_visible) blink_period / 2 - phase else blink_period - phase);
        }
    }
    const focused = ui.focused == widget;
    result.focused = focused;
    if (result.hovered or result.held) ui.cursor = .text;

    ui.drawRect(.{
        .rect = field,
        .fill = if (result.hovered or result.held) colors.button_hovered else colors.input,
        .border = if (focused) colors.accent else colors.border,
        .border_width = style.border_width,
        .radius = style.rounding,
    });

    const text = buffer[0..len.*];
    const scroll = if (focused) st.scroll else 0;
    const origin = inner.x - scroll;
    ui.pushClip(.{ .x = inner.x - 1, .y = field.y, .w = inner.w + 2, .h = field.h });
    if (focused and st.hasSelection()) {
        const sel = st.selection();
        const x0 = ui.textSize(text[0..sel[0]]).x;
        const x1 = ui.textSize(text[0..sel[1]]).x;
        ui.drawRect(.{
            .rect = .{ .x = origin + x0, .y = inner.y, .w = x1 - x0, .h = line_h },
            .fill = colors.selection,
        });
    }
    if (text.len == 0 and hint.len > 0) {
        ui.drawText(.{ .x = inner.x, .y = inner.y }, colors.text_muted, hint);
    } else {
        ui.drawText(.{ .x = origin, .y = inner.y }, colors.text, text);
    }
    if (caret_visible) {
        const x = @round(origin + ui.textSize(text[0..st.caret]).x);
        ui.drawRect(.{ .rect = .{ .x = x, .y = inner.y, .w = style.caret_width, .h = line_h }, .fill = colors.caret });
    }
    ui.popClip();
}

/// Edits one buffer through the focused input's state.
const Editor = struct {
    ui: *Ui,
    st: *State,
    buffer: []u8,
    len: usize,
    changed: bool = false,
    copy_all: bool = false,

    fn text(e: *const Editor) []const u8 {
        return e.buffer[0..e.len];
    }

    /// Puts the caret and anchor back inside the text and on codepoint
    /// boundaries, in case the app changed the text.
    fn clamp(e: *Editor) void {
        e.st.caret = snapBack(e.text(), @min(e.st.caret, e.len));
        e.st.anchor = snapBack(e.text(), @min(e.st.anchor, e.len));
    }

    /// Moves the caret. With `extend`, the anchor stays, growing the selection.
    fn setCaret(e: *Editor, pos: usize, extend: bool) void {
        e.st.caret = pos;
        if (!extend) e.st.anchor = pos;
        e.st.blink = 0;
        e.st.last_edit = .none;
    }

    fn select(e: *Editor, from: usize, to: usize) void {
        e.setCaret(to, false);
        e.st.anchor = from;
    }

    const HitMode = enum { nearest, containing };

    /// Maps an x offset from the text's start to a byte offset: the nearest
    /// boundary, or the start of the character under it.
    fn hit(e: *const Editor, x: f32, mode: HitMode) usize {
        const t = e.text();
        const size = e.ui.style.font_size;
        var pen: f32 = 0;
        var previous: ?u21 = null;
        var it: @import("font.zig").Utf8Iterator = .{ .bytes = t };
        while (true) {
            const start = it.index;
            const cp = it.next() orelse break;
            if (previous) |p| pen += e.ui.font.kerning(p, cp, size);
            previous = cp;
            const advance = e.ui.font.advance(cp, size);
            const edge = switch (mode) {
                .nearest => pen + advance / 2,
                .containing => pen + advance,
            };
            if (x < edge) return start;
            pen += advance;
        }
        return t.len;
    }

    /// Handles a press at `x` from the text's start.
    fn press(e: *Editor, x: f32, clicks: u8, extend: bool) void {
        e.st.dragging = false;
        if (clicks >= 3) {
            e.select(0, e.len);
        } else if (clicks == 2) {
            const word = wordAt(e.text(), e.hit(x, .containing));
            e.select(word[0], word[1]);
        } else {
            e.setCaret(e.hit(x, .nearest), extend);
            e.st.dragging = true;
        }
    }

    /// Replays this frame's typing and key presses in order. Returns false
    /// when a key ended editing.
    fn handleKeys(e: *Editor, result: *Interaction) bool {
        const input = &e.ui.input;
        var typed: usize = 0;
        for (input.keyEvents()) |event| {
            e.typeText(input.text()[typed..event.text_offset]);
            typed = event.text_offset;
            if (!e.handleKey(event, result)) return false;
        }
        e.typeText(input.text()[typed..]);
        return true;
    }

    fn handleKey(e: *Editor, event: input_mod.KeyEvent, result: *Interaction) bool {
        const m = event.modifiers;
        const shortcut = m.ctrl or m.super;
        const by_word = m.ctrl or m.alt;
        const t = e.text();
        const st = e.st;
        switch (event.key) {
            .left => if (st.hasSelection() and !m.shift)
                e.setCaret(st.selection()[0], false)
            else
                e.setCaret(if (by_word) prevWord(t, st.caret) else prevBoundary(t, st.caret), m.shift),
            .right => if (st.hasSelection() and !m.shift)
                e.setCaret(st.selection()[1], false)
            else
                e.setCaret(if (by_word) nextWord(t, st.caret) else nextBoundary(t, st.caret), m.shift),
            .home, .up => e.setCaret(0, m.shift),
            .end, .down => e.setCaret(e.len, m.shift),
            .backspace => if (st.hasSelection())
                e.replaceSelection("", .none)
            else if (by_word)
                e.deleteRange(prevWord(t, st.caret), st.caret, .none)
            else
                e.deleteRange(prevBoundary(t, st.caret), st.caret, .deleting),
            .delete => if (st.hasSelection())
                e.replaceSelection("", .none)
            else if (by_word)
                e.deleteRange(st.caret, nextWord(t, st.caret), .none)
            else
                e.deleteRange(st.caret, nextBoundary(t, st.caret), .deleting),
            .a => if (shortcut) e.select(0, e.len),
            .c => if (shortcut) e.copy(),
            .x => if (shortcut) {
                if (!st.hasSelection() and e.copy_all) e.select(0, e.len);
                e.copy();
                e.replaceSelection("", .none);
            },
            .v => if (shortcut) e.paste(),
            .z => if (shortcut) {
                if (m.shift) e.redo() else e.undo();
            },
            .y => if (shortcut) e.redo(),
            .enter => {
                result.submitted = true;
                e.ui.enter_taken = true;
                return false;
            },
            .escape => {
                e.revert();
                result.cancelled = true;
                // The field's: a dialog around it closes on the next Escape.
                e.ui.input.keys_pressed.remove(.escape);
                return false;
            },
            else => {},
        }
        return true;
    }

    fn typeText(e: *Editor, raw: []const u8) void {
        var clean: [@typeInfo(@FieldType(input_mod.Input, "text_buffer")).array.len]u8 = undefined;
        const n = sanitize(&clean, raw);
        if (n == 0) return;
        // A space starts a new undo step, so undo removes a word at a time.
        if (clean[0] == ' ') e.st.last_edit = .none;
        e.replaceSelection(clean[0..n], .typing);
    }

    fn paste(e: *Editor) void {
        const raw = e.ui.getClipboard();
        const clean = e.ui.frameAllocator().alloc(u8, raw.len) catch |err| return e.ui.fail(err);
        e.replaceSelection(clean[0..sanitize(clean, raw)], .none);
    }

    fn copy(e: *Editor) void {
        if (!e.st.hasSelection()) {
            if (e.copy_all) e.ui.setClipboard(e.text());
            return;
        }
        const sel = e.st.selection();
        e.ui.setClipboard(e.text()[sel[0]..sel[1]]);
    }

    fn deleteRange(e: *Editor, from: usize, to: usize, kind: EditKind) void {
        if (from == to) return;
        e.select(from, to);
        e.replaceSelection("", kind);
    }

    /// Replaces the selection with `new`, which must be clean UTF-8. Cuts
    /// `new` at a codepoint boundary if the buffer can't hold all of it.
    fn replaceSelection(e: *Editor, new: []const u8, kind: EditKind) void {
        const sel = e.st.selection();
        const start = sel[0];
        const end = sel[1];
        const room = e.buffer.len - (e.len - (end - start));
        const fitted = new[0..fitLength(new, room)];
        if (start == end and fitted.len == 0) return;

        e.remember(kind);
        const tail = e.len - end;
        const dest = start + fitted.len;
        if (dest > end) {
            std.mem.copyBackwards(u8, e.buffer[dest..][0..tail], e.buffer[end..][0..tail]);
        } else {
            std.mem.copyForwards(u8, e.buffer[dest..][0..tail], e.buffer[end..][0..tail]);
        }
        @memcpy(e.buffer[start..dest], fitted);
        e.len = dest + tail;
        e.setCaret(dest, false);
        e.st.last_edit = kind;
        e.changed = true;
    }

    /// Saves the text for undo, unless this edit continues a run of the same
    /// kind of edit.
    fn remember(e: *Editor, kind: EditKind) void {
        freeAll(&e.st.redo, e.ui.allocator);
        if (kind != .none and kind == e.st.last_edit) return;
        e.snapshotInto(&e.st.undo);
    }

    fn snapshotInto(e: *Editor, list: *std.ArrayList(Snapshot)) void {
        const allocator = e.ui.allocator;
        const copy_text = allocator.dupe(u8, e.text()) catch |err| return e.ui.fail(err);
        list.append(allocator, .{ .text = copy_text, .caret = e.st.caret, .anchor = e.st.anchor }) catch |err| {
            allocator.free(copy_text);
            return e.ui.fail(err);
        };
        if (list.items.len > max_undo) {
            allocator.free(list.items[0].text);
            _ = list.orderedRemove(0);
        }
    }

    fn undo(e: *Editor) void {
        const s = e.st.undo.pop() orelse return;
        e.snapshotInto(&e.st.redo);
        e.restore(s);
    }

    fn redo(e: *Editor) void {
        const s = e.st.redo.pop() orelse return;
        e.snapshotInto(&e.st.undo);
        e.restore(s);
    }

    /// Puts back the text from when focus arrived.
    fn revert(e: *Editor) void {
        const original = e.st.original.items;
        if (std.mem.eql(u8, original, e.text())) return;
        const n = fitLength(original, e.buffer.len);
        @memcpy(e.buffer[0..n], original[0..n]);
        e.len = n;
        e.setCaret(n, false);
        e.changed = true;
    }

    fn restore(e: *Editor, s: Snapshot) void {
        defer e.ui.allocator.free(s.text);
        const n = fitLength(s.text, e.buffer.len);
        @memcpy(e.buffer[0..n], s.text[0..n]);
        e.len = n;
        e.setCaret(s.caret, false);
        e.st.anchor = s.anchor;
        e.clamp();
        e.changed = true;
    }
};

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

/// Moves `i` back to the start of the codepoint it falls in.
fn snapBack(text: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and j < text.len and isContinuation(text[j])) j -= 1;
    return j;
}

fn prevBoundary(text: []const u8, i: usize) usize {
    if (i == 0) return 0;
    return snapBack(text, i - 1);
}

fn nextBoundary(text: []const u8, i: usize) usize {
    if (i >= text.len) return text.len;
    var j = i + 1;
    while (j < text.len and isContinuation(text[j])) j += 1;
    return j;
}

/// The longest prefix of `bytes` that fits in `room` without splitting a
/// codepoint.
fn fitLength(bytes: []const u8, room: usize) usize {
    if (bytes.len <= room) return bytes.len;
    return snapBack(bytes, room);
}

/// Copies `src` into `dst` as text fit for a single line: valid UTF-8 only,
/// tabs and line breaks become spaces, other control characters are dropped.
/// `dst` must be at least as long as `src`. Returns the length written.
fn sanitize(dst: []u8, src: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const len = std.unicode.utf8ByteSequenceLength(src[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > src.len) break;
        const bytes = src[i..][0..len];
        i += len;
        const cp = std.unicode.utf8Decode(bytes) catch continue;
        if (cp == '\t' or cp == '\n') {
            if (n > 0 and dst[n - 1] == ' ' and cp == '\n') continue; // "\r\n" or " \n"
            dst[n] = ' ';
            n += 1;
        } else if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) {
            continue;
        } else {
            @memcpy(dst[n..][0..len], bytes);
            n += len;
        }
    }
    return n;
}

const CharClass = enum { space, word, punct };

fn classAt(text: []const u8, i: usize) CharClass {
    const end = nextBoundary(text, i);
    const cp = std.unicode.utf8Decode(text[i..end]) catch return .word;
    if (cp == ' ' or cp == 0xA0 or cp == 0x3000 or (cp >= 0x2000 and cp <= 0x200A)) return .space;
    if (cp < 0x80) {
        const c: u8 = @intCast(cp);
        return if (std.ascii.isAlphanumeric(c) or c == '_') .word else .punct;
    }
    return .word;
}

/// Where Ctrl+Right goes: past the current word and the spaces after it.
fn nextWord(text: []const u8, i: usize) usize {
    var j = i;
    if (j >= text.len) return text.len;
    const class = classAt(text, j);
    if (class != .space) {
        while (j < text.len and classAt(text, j) == class) j = nextBoundary(text, j);
    }
    while (j < text.len and classAt(text, j) == .space) j = nextBoundary(text, j);
    return j;
}

/// Where Ctrl+Left goes: back over spaces, then to the start of the word.
fn prevWord(text: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and classAt(text, prevBoundary(text, j)) == .space) j = prevBoundary(text, j);
    if (j == 0) return 0;
    const class = classAt(text, prevBoundary(text, j));
    while (j > 0 and classAt(text, prevBoundary(text, j)) == class) j = prevBoundary(text, j);
    return j;
}

/// The run of same-class characters around byte `i`, for double-click.
fn wordAt(text: []const u8, i: usize) [2]usize {
    if (text.len == 0) return .{ 0, 0 };
    const at = if (i >= text.len) prevBoundary(text, text.len) else i;
    const class = classAt(text, at);
    var start = at;
    while (start > 0 and classAt(text, prevBoundary(text, start)) == class) start = prevBoundary(text, start);
    var end = at;
    while (end < text.len and classAt(text, end) == class) end = nextBoundary(text, end);
    return .{ start, end };
}

const testing = std.testing;

test "word movement" {
    const t = "foo bar, baz";
    try testing.expectEqual(@as(usize, 4), nextWord(t, 0));
    try testing.expectEqual(@as(usize, 7), nextWord(t, 4));
    try testing.expectEqual(@as(usize, 9), nextWord(t, 7));
    try testing.expectEqual(@as(usize, 12), nextWord(t, 9));
    try testing.expectEqual(@as(usize, 9), prevWord(t, 12));
    try testing.expectEqual(@as(usize, 7), prevWord(t, 9));
    try testing.expectEqual(@as(usize, 4), prevWord(t, 7));
    try testing.expectEqual(@as(usize, 0), prevWord(t, 3));
    try testing.expectEqual([2]usize{ 4, 7 }, wordAt(t, 5));
    try testing.expectEqual([2]usize{ 9, 12 }, wordAt(t, 12));
}

test "word movement treats accented letters as letters" {
    const t = "café olé";
    try testing.expectEqual(@as(usize, 6), nextWord(t, 0));
    try testing.expectEqual(@as(usize, 6), prevWord(t, t.len));
}

test "codepoint boundaries" {
    const t = "aé€";
    try testing.expectEqual(@as(usize, 1), nextBoundary(t, 0));
    try testing.expectEqual(@as(usize, 3), nextBoundary(t, 1));
    try testing.expectEqual(@as(usize, 6), nextBoundary(t, 3));
    try testing.expectEqual(@as(usize, 3), prevBoundary(t, 6));
    try testing.expectEqual(@as(usize, 1), prevBoundary(t, 3));
    try testing.expectEqual(@as(usize, 3), fitLength(t, 5));
    try testing.expectEqual(@as(usize, 1), fitLength(t, 2));
}

test "sanitize keeps a single line of valid text" {
    var out: [32]u8 = undefined;
    const n = sanitize(&out, "a\tb\r\nc\x01\xffé\x7f");
    try testing.expectEqualStrings("a b cé", out[0..n]);
}
