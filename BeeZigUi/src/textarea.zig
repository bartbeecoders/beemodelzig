//! A multi-line text field that wraps: BeeModel's AI prompt, notes.
//!
//!     var r = ui.textArea("prompt", &buffer, &len, .{ .height = .px(90), .enter_sends = true });
//!     if (r.submitted) send(buffer[0..len]);
//!
//! With `enter_sends`, Enter submits and Shift+Enter starts a new line;
//! otherwise Enter starts a new line. Arrows move by character and by
//! visual line, Ctrl+arrows by word, Home / End to the line's ends, Ctrl+Home
//! / End to the text's. Selection with Shift or the mouse (a double-click
//! takes a word), Ctrl+A / C / X / V, Ctrl+Z undoes (a run of typing at a
//! time) and Ctrl+Shift+Z or Ctrl+Y redoes, Escape lets go.

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const ui_mod = @import("ui.zig");
const font_mod = @import("font.zig");
const input_mod = @import("input.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;
const Allocator = std.mem.Allocator;

/// Undo steps kept for the focused text area.
const max_undo = 64;

const Snapshot = struct { text: []u8, caret: usize, anchor: usize };

/// What the last edit was, so a run of typing undoes as one step.
const EditKind = enum { none, typing, deleting };

/// Options for `textArea`.
pub const TextAreaOptions = struct {
    width: layout.Size = .fill,
    height: layout.Size = .{ .fixed = 100 },
    hint: []const u8 = "",
    /// Enter submits, Shift+Enter breaks the line (a chat prompt).
    enter_sends: bool = false,
};

/// The focused text area's caret and selection.
pub const State = struct {
    id: Id = .none,
    caret: usize = 0,
    anchor: usize = 0,
    scroll: f32 = 0,
    /// Where Up and Down aim, so a column survives short lines.
    goal_x: ?f32 = null,
    blink: f32 = 0,
    dragging: bool = false,
    dirty: bool = false,
    /// The visual line the caret is on, and how many there are, as of the
    /// last frame: an app's Up on the first line or Down on the last can
    /// do something else (a history of prompts).
    caret_line: usize = 0,
    line_count: usize = 1,
    last_edit: EditKind = .none,
    undo: std.ArrayList(Snapshot) = .empty,
    redo: std.ArrayList(Snapshot) = .empty,

    /// Frees the undo history.
    pub fn deinit(self: *State, allocator: Allocator) void {
        freeAll(&self.undo, allocator);
        freeAll(&self.redo, allocator);
        self.undo.deinit(allocator);
        self.redo.deinit(allocator);
    }

    /// Starts on the area `id`: its caret at `at`, no history.
    fn reset(self: *State, allocator: Allocator, id: Id, at: usize) void {
        freeAll(&self.undo, allocator);
        freeAll(&self.redo, allocator);
        self.* = .{ .id = id, .caret = at, .anchor = at, .undo = self.undo, .redo = self.redo };
    }
};

fn freeAll(list: *std.ArrayList(Snapshot), allocator: Allocator) void {
    for (list.items) |s| allocator.free(s.text);
    list.clearRetainingCapacity();
}

const Line = struct { start: usize, end: usize };

/// Breaks `text` into visual lines no wider than `width`: at `\n`, else
/// after the last space that fits, else inside a word.
fn wrap(ui: *Ui, text: []const u8, width: f32, out: *std.ArrayList(Line)) void {
    const gpa = ui.frameAllocator();
    const size = ui.style.font_size;
    var start: usize = 0;
    var x: f32 = 0;
    var last_space: ?usize = null;
    var previous: ?u21 = null;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n') {
            out.append(gpa, .{ .start = start, .end = i }) catch return ui.fail(error.OutOfMemory);
            i += 1;
            start = i;
            x = 0;
            last_space = null;
            previous = null;
            continue;
        }
        var it: font_mod.Utf8Iterator = .{ .bytes = text[i..] };
        const cp = it.next() orelse break;
        const n = it.index;
        // Measured as textSize measures: advances plus kerning.
        const adv = ui.font.advance(cp, size) + (if (previous) |p| ui.font.kerning(p, cp, size) else 0);
        // Spaces may hang past the edge; a line breaks after them.
        if (c == ' ') {
            last_space = i;
            x += adv;
            previous = cp;
            i += n;
            continue;
        }
        if (x + adv > width and i > start) {
            // Break after the last space, or here.
            const cut = if (last_space) |sp| sp + 1 else i;
            out.append(gpa, .{ .start = start, .end = cut }) catch return ui.fail(error.OutOfMemory);
            start = cut;
            x = ui.textSize(text[start..i]).x;
            last_space = null;
            previous = null;
            continue;
        }
        if (c == ' ') last_space = i;
        x += adv;
        previous = cp;
        i += n;
    }
    out.append(gpa, .{ .start = start, .end = text.len }) catch ui.fail(error.OutOfMemory);
}

fn lineOf(lines: []const Line, pos: usize) usize {
    for (lines, 0..) |l, i| {
        if (pos < l.end or (pos == l.end and (i + 1 == lines.len or lines[i + 1].start > pos))) return i;
    }
    return lines.len - 1;
}

fn byteAtX(ui: *Ui, text: []const u8, l: Line, x: f32) usize {
    var it: font_mod.Utf8Iterator = .{ .bytes = text[l.start..l.end] };
    var pen: f32 = 0;
    while (true) {
        const s = it.index;
        const cp = it.next() orelse break;
        const adv = ui.font.advance(cp, ui.style.font_size);
        if (x < pen + adv / 2) return l.start + s;
        pen += adv;
    }
    // At a wrap, the end of the line is the start of the next: stay before the space.
    return if (l.end > l.start and l.end < text.len and text[l.end - 1] == ' ' and text[l.end] != '\n') l.end - 1 else l.end;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn prevChar(text: []const u8, i: usize) usize {
    var j = i -| 1;
    while (j > 0 and text[j] & 0xC0 == 0x80) j -= 1;
    return j;
}

fn nextChar(text: []const u8, i: usize) usize {
    if (i >= text.len) return text.len;
    var j = i + 1;
    while (j < text.len and text[j] & 0xC0 == 0x80) j += 1;
    return j;
}

fn prevWord(text: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and !isWord(text[j - 1])) j -= 1;
    while (j > 0 and isWord(text[j - 1])) j -= 1;
    return j;
}

fn nextWord(text: []const u8, i: usize) usize {
    var j = i;
    while (j < text.len and !isWord(text[j])) j += 1;
    while (j < text.len and isWord(text[j])) j += 1;
    return j;
}

/// Edits `buffer[0..len.*]` in place.
const Edit = struct {
    ui: *Ui,
    buffer: []u8,
    len: *usize,
    st: *State,
    changed: bool = false,

    fn text(e: *const Edit) []const u8 {
        return e.buffer[0..e.len.*];
    }

    fn selection(e: *const Edit) [2]usize {
        return .{ @min(e.st.caret, e.st.anchor), @max(e.st.caret, e.st.anchor) };
    }

    fn move(e: *Edit, to: usize, extend: bool) void {
        e.st.caret = to;
        if (!extend) e.st.anchor = to;
        e.st.blink = 0;
    }

    fn replace(e: *Edit, a: usize, b: usize, with: []const u8) void {
        e.replaceKind(a, b, with, .none);
    }

    fn replaceKind(e: *Edit, a: usize, b: usize, with: []const u8, kind: EditKind) void {
        if (a == b and with.len == 0) return;
        e.remember(kind);
        e.st.last_edit = kind;
        const room = e.buffer.len - (e.len.* - (b - a));
        var n = @min(with.len, room);
        while (n > 0 and n < with.len and with[n] & 0xC0 == 0x80) n -= 1;
        const tail = e.len.* - b;
        // (Overlapping when the text grows: copied from the end then.)
        if (a + n > b) {
            std.mem.copyBackwards(u8, e.buffer[a + n ..][0..tail], e.buffer[b..][0..tail]);
        } else {
            std.mem.copyForwards(u8, e.buffer[a + n ..][0..tail], e.buffer[b..][0..tail]);
        }
        @memcpy(e.buffer[a..][0..n], with[0..n]);
        e.len.* = a + n + tail;
        e.move(a + n, false);
        e.changed = true;
        e.st.dirty = true;
    }

    fn insert(e: *Edit, with: []const u8) void {
        const s = e.selection();
        e.replace(s[0], s[1], with);
    }

    fn deleteSelection(e: *Edit) bool {
        const s = e.selection();
        if (s[0] == s[1]) return false;
        e.replace(s[0], s[1], "");
        return true;
    }

    /// Saves the text for undo, unless this edit continues a run of the
    /// same kind.
    fn remember(e: *Edit, kind: EditKind) void {
        freeAll(&e.st.redo, e.ui.allocator);
        if (kind != .none and kind == e.st.last_edit) return;
        e.snapshotInto(&e.st.undo);
    }

    fn snapshotInto(e: *Edit, list: *std.ArrayList(Snapshot)) void {
        const allocator = e.ui.allocator;
        const copy = allocator.dupe(u8, e.text()) catch |err| return e.ui.fail(err);
        list.append(allocator, .{ .text = copy, .caret = e.st.caret, .anchor = e.st.anchor }) catch |err| {
            allocator.free(copy);
            return e.ui.fail(err);
        };
        if (list.items.len > max_undo) {
            allocator.free(list.items[0].text);
            _ = list.orderedRemove(0);
        }
    }

    fn undo(e: *Edit) void {
        const s = e.st.undo.pop() orelse return;
        e.snapshotInto(&e.st.redo);
        e.restore(s);
    }

    fn redo(e: *Edit) void {
        const s = e.st.redo.pop() orelse return;
        e.snapshotInto(&e.st.undo);
        e.restore(s);
    }

    fn restore(e: *Edit, s: Snapshot) void {
        defer e.ui.allocator.free(s.text);
        const n = @import("font.zig").fitUtf8(s.text, e.buffer.len);
        @memcpy(e.buffer[0..n], s.text[0..n]);
        e.len.* = n;
        e.st.caret = @min(s.caret, n);
        e.st.anchor = @min(s.anchor, n);
        e.st.blink = 0;
        e.st.last_edit = .none;
        e.changed = true;
        e.st.dirty = true;
    }
};

/// A field for several lines of text, in `buffer[0..len.*]`, that wraps.
/// `result.submitted` is set on Enter with `enter_sends`.
pub fn textArea(ui: *Ui, name: []const u8, buffer: []u8, len: *usize, options: TextAreaOptions) Interaction {
    const style = &ui.style;
    const colors = &style.colors;
    const rect = ui.placeSized(options.width, options.height, .{ .x = style.widget_width * 1.5, .y = 100 });
    const widget = ui.id(name);
    var result = ui.interact(widget, rect);
    ui.focusable(widget, &result);
    const st = &ui.textarea_state;
    const focused = ui.focused == widget;
    if (focused and st.id != widget) st.reset(ui.allocator, widget, len.*);
    if (result.hovered or result.held) ui.cursor = .text;
    len.* = @min(len.*, buffer.len);

    const pad = style.frame_padding.y + 2;
    const inner = rect.inset(pad);
    const line = ui.font.lineMetrics(style.font_size);
    const line_h = line.height;
    var lines: std.ArrayList(Line) = .empty;
    wrap(ui, buffer[0..len.*], @max(20, inner.w - 4), &lines);
    var e: Edit = .{ .ui = ui, .buffer = buffer, .len = len, .st = st };

    if (focused) {
        st.caret = @min(st.caret, len.*);
        st.anchor = @min(st.anchor, len.*);
        st.blink += ui.dt;
        const in = &ui.input;
        // The pointer.
        if (result.pressed or (result.held and st.dragging)) {
            const p = if (result.pressed) in.press_pos.get(.left) else in.mouse_pos;
            const li: usize = @intFromFloat(std.math.clamp(@floor((p.y - inner.y + st.scroll) / line_h), 0, @as(f32, @floatFromInt(lines.items.len - 1))));
            const at = byteAtX(ui, e.text(), lines.items[li], p.x - inner.x);
            if (result.pressed and in.press_clicks.get(.left) == 2) {
                var a = at;
                while (a > 0 and isWord(e.text()[a - 1])) a -= 1;
                st.anchor = a;
                st.caret = nextWord(e.text(), at);
            } else {
                e.move(at, !result.pressed or in.modifiers.shift);
                st.dragging = true;
            }
            st.goal_x = null;
        }
        if (!result.held) st.dragging = false;

        // Typing and keys, in the order they came.
        var typed: usize = 0;
        for (in.keyEvents()) |event| {
            typeText(&e, in.text()[typed..event.text_offset]);
            typed = event.text_offset;
            if (handleKey(ui, &e, event, lines.items, options, &result)) break;
        }
        typeText(&e, in.text()[typed..]);
        if (e.changed) {
            lines.clearRetainingCapacity();
            wrap(ui, buffer[0..len.*], @max(20, inner.w - 4), &lines);
            result.changed = true;
        }
        // Keep the caret in view.
        st.caret_line = lineOf(lines.items, st.caret);
        st.line_count = lines.items.len;
        const cl: f32 = @floatFromInt(st.caret_line);
        if (cl * line_h < st.scroll) st.scroll = cl * line_h;
        if ((cl + 1) * line_h > st.scroll + inner.h) st.scroll = (cl + 1) * line_h - inner.h;
        const blink: f32 = 1.0;
        ui.requestRedrawIn(blink / 2 - @mod(st.blink, blink / 2));
    }
    const total_h = @as(f32, @floatFromInt(lines.items.len)) * line_h;
    if (!focused) st.scroll = if (st.id == widget) std.math.clamp(st.scroll, 0, @max(0, total_h - inner.h)) else 0;
    if (result.hovered and !focused and ui.input.scroll.y != 0) {
        // Not focused, the wheel scrolls the page around it instead.
    }

    ui.drawRect(.{ .rect = rect, .fill = colors.input, .border = if (focused) colors.accent else colors.border, .border_width = style.border_width, .radius = style.rounding });
    ui.pushClip(inner.inset(-1));
    const scroll = if (st.id == widget) st.scroll else 0;
    const text = buffer[0..len.*];
    const sel = if (focused) e.selection() else [2]usize{ 0, 0 };
    if (text.len == 0 and options.hint.len > 0) ui.drawText(.{ .x = inner.x, .y = inner.y }, colors.text_muted, options.hint);
    for (lines.items, 0..) |l, i| {
        const y = inner.y + @as(f32, @floatFromInt(i)) * line_h - scroll;
        if (y + line_h < inner.y or y > inner.bottom()) continue;
        if (sel[1] > sel[0] and sel[0] <= l.end and sel[1] >= l.start) {
            const a = @max(sel[0], l.start);
            const b = @min(sel[1], l.end);
            const x0 = ui.textSize(text[l.start..a]).x;
            const x1 = ui.textSize(text[l.start..b]).x + (if (sel[1] > l.end) @as(f32, 4) else 0);
            ui.drawRect(.{ .rect = .{ .x = inner.x + x0, .y = y, .w = x1 - x0, .h = line_h }, .fill = colors.selection });
        }
        ui.drawText(.{ .x = inner.x, .y = y }, colors.text, text[l.start..l.end]);
    }
    if (focused and @mod(st.blink, 1.0) < 0.5) {
        const li = lineOf(lines.items, st.caret);
        const l = lines.items[li];
        const x = inner.x + ui.textSize(text[l.start..@max(l.start, @min(st.caret, l.end))]).x;
        const y = inner.y + @as(f32, @floatFromInt(li)) * line_h - scroll;
        ui.drawRect(.{ .rect = .{ .x = @round(x), .y = y, .w = style.caret_width, .h = line.ascent + line.descent }, .fill = colors.caret });
    }
    ui.popClip();
    ui.drawFocusRing(widget, rect);
    ui.recordWidget(.text_area, widget, name, rect, .{ .value = text, .hovered = result.hovered, .focused = focused });
    result.focused = focused;
    return result;
}

/// The height a text area `width` wide needs to show `text` whole:
/// between `min_lines` and `max_lines` lines of it (more scroll). For an
/// area that grows as it is typed into: pass it as `height`.
pub fn textAreaHeight(ui: *Ui, text: []const u8, width: f32, min_lines: usize, max_lines: usize) f32 {
    const pad = ui.style.frame_padding.y + 2;
    var lines: std.ArrayList(Line) = .empty;
    wrap(ui, text, @max(20, width - 2 * pad - 4), &lines);
    const n = std.math.clamp(lines.items.len, @max(1, min_lines), @max(1, min_lines, max_lines));
    return @as(f32, @floatFromInt(n)) * ui.font.lineMetrics(ui.style.font_size).height + 2 * pad;
}

fn typeText(e: *Edit, raw: []const u8) void {
    if (raw.len == 0) return;
    e.st.goal_x = null;
    // A space starts a new undo step, so undo takes a word at a time.
    var rest = raw;
    while (rest.len > 0) {
        const n = if (std.mem.indexOfScalarPos(u8, rest, 1, ' ')) |sp| sp else rest.len;
        if (rest[0] == ' ') e.st.last_edit = .none;
        const s = e.selection();
        e.replaceKind(s[0], s[1], rest[0..n], if (s[0] == s[1]) .typing else .none);
        rest = rest[n..];
    }
}

/// Returns true if the key ended editing.
fn handleKey(ui: *Ui, e: *Edit, event: input_mod.KeyEvent, lines: []const Line, options: TextAreaOptions, result: *Interaction) bool {
    const m = event.modifiers;
    const shortcut = m.ctrl or m.super;
    const t = e.text();
    const st = e.st;
    const size = ui.style.font_size;
    if (event.key != .up and event.key != .down) st.goal_x = null;
    // Moving the caret ends a run of typing.
    switch (event.key) {
        .left, .right, .up, .down, .home, .end => st.last_edit = .none,
        else => {},
    }
    switch (event.key) {
        .left => e.move(if (m.ctrl) prevWord(t, st.caret) else prevChar(t, st.caret), m.shift),
        .right => e.move(if (m.ctrl) nextWord(t, st.caret) else nextChar(t, st.caret), m.shift),
        .up, .down => {
            const li = lineOf(lines, st.caret);
            const l = lines[li];
            const goal = st.goal_x orelse ui.font.textWidth(t[l.start..@max(l.start, @min(st.caret, l.end))], size);
            if (event.key == .up and li == 0) {
                e.move(0, m.shift);
            } else if (event.key == .down and li + 1 == lines.len) {
                e.move(t.len, m.shift);
            } else {
                const to = lines[if (event.key == .up) li - 1 else li + 1];
                e.move(byteAtX(ui, t, to, goal), m.shift);
            }
            st.goal_x = goal;
        },
        .home => e.move(if (m.ctrl) 0 else lines[lineOf(lines, st.caret)].start, m.shift),
        .end => e.move(if (m.ctrl) t.len else lines[lineOf(lines, st.caret)].end, m.shift),
        .backspace => if (!e.deleteSelection()) {
            const from = if (m.ctrl) prevWord(t, st.caret) else prevChar(t, st.caret);
            if (from < st.caret) e.replaceKind(from, st.caret, "", if (m.ctrl) .none else .deleting);
        },
        .delete => if (!e.deleteSelection()) {
            const to = if (m.ctrl) nextWord(t, st.caret) else nextChar(t, st.caret);
            if (to > st.caret) e.replaceKind(st.caret, to, "", if (m.ctrl) .none else .deleting);
        },
        .z => if (shortcut) {
            if (m.shift) e.redo() else e.undo();
        },
        .y => if (shortcut) e.redo(),
        .enter => {
            if (options.enter_sends and !m.shift) {
                result.submitted = true;
                ui.enter_taken = true;
                if (st.dirty) result.committed = true;
                st.dirty = false;
                return true;
            }
            e.insert("\n");
        },
        .escape => {
            ui.input.keys_pressed.remove(.escape); // (the field's: a dialog around it stays)
            ui.setFocus(.none);
            ui.focus_pressed = false;
            if (st.dirty) result.committed = true;
            st.dirty = false;
            return true;
        },
        .a => if (shortcut) {
            st.anchor = 0;
            st.caret = t.len;
        },
        .c, .x => if (shortcut) {
            const s = e.selection();
            if (s[1] > s[0]) {
                ui.setClipboard(t[s[0]..s[1]]);
                if (event.key == .x) _ = e.deleteSelection();
            }
        },
        .v => if (shortcut) {
            // Paste keeps its lines; "\r" and other control characters go.
            // Whole characters only: bytes that aren't UTF-8 are dropped, so
            // the text stays valid; any length (the field cuts what doesn't
            // fit between characters).
            const pasted = ui.getClipboard();
            const clean = ui.frameAllocator().alloc(u8, pasted.len) catch |err| {
                ui.fail(err);
                return true;
            };
            var n: usize = 0;
            var i: usize = 0;
            while (i < pasted.len) {
                const c = pasted[i];
                const len = std.unicode.utf8ByteSequenceLength(c) catch {
                    i += 1;
                    continue;
                };
                if (i + len > pasted.len or !std.unicode.utf8ValidateSlice(pasted[i..][0..len])) {
                    i += 1;
                    continue;
                }
                if (len == 1 and (c == '\r' or (c < 0x20 and c != '\n' and c != '\t'))) {
                    i += 1;
                    continue;
                }
                if (len == 1 and c == '\t') clean[n] = ' ' else @memcpy(clean[n..][0..len], pasted[i..][0..len]);
                n += len;
                i += len;
            }
            e.insert(clean[0..n]);
        },
        else => {},
    }
    return false;
}

test "wrapping breaks at spaces and keeps hard breaks" {
    var font: font_mod.Font = try .initDefault(std.testing.allocator);
    defer font.deinit();
    var ui: Ui = .init(std.testing.allocator, .{ .font = &font });
    defer ui.deinit();
    ui.beginFrame(.{ .width = 400, .height = 300 });
    var lines: std.ArrayList(Line) = .empty;
    const text = "one two three four five\nsix";
    wrap(&ui, text, ui.textSize("one two three").x + 1, &lines);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("one two three ", text[lines.items[0].start..lines.items[0].end]);
    try std.testing.expectEqualStrings("four five", text[lines.items[1].start..lines.items[1].end]);
    try std.testing.expectEqualStrings("six", text[lines.items[2].start..lines.items[2].end]);
    _ = try ui.endFrame();
}
