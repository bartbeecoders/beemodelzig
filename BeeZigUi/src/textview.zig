//! Text to read, select and type at length: wrapped and rich text, a log
//! view that holds 100,000 lines with ease, and a console line with history.
//!
//!     ui.wrappedText("A long paragraph that wraps to the width it gets.", .{});
//!     ui.richText(&.{ .{ .text = "Press " }, .{ .text = "Ctrl+S", .key = true }, .{ .text = " to save." } }, .{});
//!
//!     var log: zui.LogBuffer = try .init(gpa, 100_000, 8 << 20);
//!     log.print(null, "Rendered frame {d}", .{n});
//!     _ = ui.textView("log", &log, &view_state, .{ .height = .fill });
//!
//!     if (ui.consoleInput("command", &line, &line_len, &history, .{}).submitted) run(line[0..line_len]);

const std = @import("std");
const draw = @import("draw.zig");
const layout = @import("layout.zig");
const ui_mod = @import("ui.zig");
const font_mod = @import("font.zig");
const overlay = @import("overlay.zig");
const containers = @import("containers.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Interaction = ui_mod.Interaction;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;
const Color = draw.Color;
const Allocator = std.mem.Allocator;

// ---- wrapped and rich text ---------------------------------------------------

/// Options for `wrappedText` and `richText`.
pub const WrapOptions = struct {
    color: ?Color = null,
    /// Lines wrap at this width; by default the width the layout offers.
    width: ?f32 = null,
};

fn availableWidth(ui: *Ui, options: WrapOptions) f32 {
    if (options.width) |w| return w;
    const frame = ui.current();
    const cross = frame.layout.options.cross_extent;
    if (frame.layout.options.axis == .vertical) if (cross) |c| return @max(40, c);
    return ui.style.widget_width * 2;
}

/// A paragraph that wraps between words to the width it gets. `\n` starts
/// a new line.
pub fn wrappedText(ui: *Ui, text: []const u8, options: WrapOptions) void {
    const width = availableWidth(ui, options);
    const Count = struct {
        ui: *const Ui,
        n: f32 = 0,
        widest: f32 = 0,
        fn add(c: *@This(), s: []const u8) void {
            c.n += 1;
            c.widest = @max(c.widest, c.ui.textSize(s).x);
        }
    };
    var count: Count = .{ .ui = ui };
    overlay.wrapText(ui, text, width, &count, Count.add);
    const line = ui.font.lineMetrics(ui.style.font_size);
    const rect = ui.place(.{ .x = count.widest, .y = @max(1, count.n) * line.height - line.height + line.ascent + line.descent });
    const Draw = struct {
        ui: *Ui,
        x: f32,
        y: f32,
        step: f32,
        color: Color,
        fn add(d: *@This(), s: []const u8) void {
            d.ui.drawText(.{ .x = d.x, .y = d.y }, d.color, s);
            d.y += d.step;
        }
    };
    var pen: Draw = .{ .ui = ui, .x = rect.x, .y = rect.y, .step = line.height, .color = options.color orelse ui.style.colors.text };
    overlay.wrapText(ui, text, width, &pen, Draw.add);
    ui.recordWidget(.label, .none, text, rect, .{});
}

/// A run of rich text.
pub const Span = struct {
    text: []const u8,
    /// Overrides the text color.
    color: ?Color = null,
    /// Drawn as a key chip, like the status bar's hints; never broken.
    key: bool = false,
};

/// Text in several colors and with key chips, wrapping between words like
/// `wrappedText`.
pub fn richText(ui: *Ui, spans: []const Span, options: WrapOptions) void {
    const width = availableWidth(ui, options);
    const line = ui.font.lineMetrics(ui.style.font_size);
    const size = flow(ui, spans, width, null, options);
    const rect = ui.place(.{ .x = size.x, .y = size.y * line.height - line.height + line.ascent + line.descent });
    _ = flow(ui, spans, width, .{ .x = rect.x, .y = rect.y }, options);
    var b: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&b);
    for (spans) |sp| w.writeAll(sp.text) catch {};
    ui.recordWidget(.label, .none, w.buffered(), rect, .{});
}

/// Lays out (and with an origin, draws) `spans`; returns the widest line
/// and the number of lines.
fn flow(ui: *Ui, spans: []const Span, width: f32, origin: ?Vec2, options: WrapOptions) Vec2 {
    const colors = &ui.style.colors;
    const line = ui.font.lineMetrics(ui.style.font_size);
    const chip_pad: f32 = 5;
    var x: f32 = 0;
    var lines: f32 = 1;
    var widest: f32 = 0;
    for (spans) |sp| {
        if (sp.key) {
            const w = ui.textSize(sp.text).x + 2 * chip_pad;
            if (x > 0 and x + w > width) {
                x = 0;
                lines += 1;
            }
            if (origin) |o| {
                const r: Rect = .{ .x = o.x + x, .y = o.y + (lines - 1) * line.height, .w = w, .h = line.ascent + line.descent };
                ui.drawRect(.{ .rect = r, .fill = colors.button, .border = colors.border, .border_width = 1, .radius = 3 });
                ui.drawText(.{ .x = r.x + chip_pad, .y = r.y }, sp.color orelse colors.text, sp.text);
            }
            x += w + 3;
            widest = @max(widest, x);
            continue;
        }
        // Word by word, keeping the spaces with the word before them.
        var i: usize = 0;
        while (i < sp.text.len) {
            if (sp.text[i] == '\n') {
                x = 0;
                lines += 1;
                i += 1;
                continue;
            }
            var j = i;
            while (j < sp.text.len and sp.text[j] != ' ' and sp.text[j] != '\n') j += 1;
            while (j < sp.text.len and sp.text[j] == ' ') j += 1;
            const word = sp.text[i..j];
            const w = ui.textSize(word).x;
            const bare = ui.textSize(std.mem.trimEnd(u8, word, " ")).x;
            if (x > 0 and x + bare > width) {
                x = 0;
                lines += 1;
            }
            if (origin) |o| ui.drawText(.{ .x = o.x + x, .y = o.y + (lines - 1) * line.height }, sp.color orelse options.color orelse colors.text, word);
            x += w;
            widest = @max(widest, x);
            i = j;
        }
    }
    return .{ .x = widest, .y = lines };
}

// ---- the log buffer ------------------------------------------------------------

/// One line of a text view.
pub const TextLine = struct {
    text: []const u8,
    color: ?Color = null,
    /// Lines with the same block number belong together: a double-click
    /// selects the whole block (a multi-line message).
    block: u32 = 0,
    /// Continues the line before it, wrapped there by the app: copying
    /// joins the two without a line break.
    soft: bool = false,
};

/// Lines of text in fixed memory, oldest dropped first: a console's log.
/// It allocates once, in `init`.
pub const LogBuffer = struct {
    allocator: Allocator,
    bytes: []u8,
    entries: []Entry,
    /// Index of the oldest line in `entries`.
    head: usize = 0,
    count: usize = 0,
    write_pos: usize = 0,
    /// Lines ever added, so a view can tell new ones arrived.
    total: u64 = 0,
    next_block: u32 = 1,

    const Entry = struct { start: u32, len: u32, color: ?Color, block: u32 };

    /// Room for `max_lines` lines and `max_bytes` bytes of text.
    pub fn init(allocator: Allocator, max_lines: usize, max_bytes: usize) Allocator.Error!LogBuffer {
        const bytes = try allocator.alloc(u8, max_bytes);
        errdefer allocator.free(bytes);
        const entries = try allocator.alloc(Entry, max_lines);
        return .{ .allocator = allocator, .bytes = bytes, .entries = entries };
    }

    /// Frees the memory.
    pub fn deinit(self: *LogBuffer) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.entries);
    }

    /// The number of lines.
    pub fn len(self: *const LogBuffer) usize {
        return self.count;
    }

    /// Line `i`, from the oldest.
    pub fn line(self: *const LogBuffer, i: usize) TextLine {
        const e = self.entries[(self.head + i) % self.entries.len];
        return .{ .text = self.bytes[e.start..][0..e.len], .color = e.color, .block = e.block };
    }

    /// Removes every line.
    pub fn clear(self: *LogBuffer) void {
        self.head = 0;
        self.count = 0;
        self.write_pos = 0;
    }

    fn dropOldest(self: *LogBuffer) void {
        self.head = (self.head + 1) % self.entries.len;
        self.count -= 1;
    }

    /// Adds `text` as one block: each `\n` starts another line of it.
    pub fn add(self: *LogBuffer, color: ?Color, text: []const u8) void {
        if (self.entries.len == 0 or self.bytes.len == 0) return;
        const block = self.next_block;
        self.next_block +%= 1;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |part| self.addLine(color, part, block);
    }

    fn addLine(self: *LogBuffer, color: ?Color, text_in: []const u8, block: u32) void {
        const text = text_in[0..@import("font.zig").fitUtf8(text_in, self.bytes.len)];
        if (self.write_pos + text.len > self.bytes.len) self.write_pos = 0;
        const lo = self.write_pos;
        const hi = lo + text.len;
        // Drop the oldest lines while they are in the way, or there are too many.
        while (self.count > 0) {
            const old = self.entries[self.head];
            const overlaps = old.start < hi and old.start + old.len > lo or (text.len == 0 and old.start == lo and old.len > 0);
            if (!overlaps and self.count < self.entries.len) break;
            self.dropOldest();
        }
        @memcpy(self.bytes[lo..hi], text);
        self.entries[(self.head + self.count) % self.entries.len] = .{ .start = @intCast(lo), .len = @intCast(text.len), .color = color, .block = block };
        self.count += 1;
        self.write_pos = hi;
        self.total += 1;
    }

    /// Adds a formatted block, up to 4 KB.
    pub fn print(self: *LogBuffer, color: ?Color, comptime fmt: []const u8, args: anytype) void {
        var b: [4096]u8 = undefined;
        self.add(color, std.fmt.bufPrint(&b, fmt, args) catch b[0..]);
    }
};

// ---- the text view ---------------------------------------------------------------

/// A place in a text view: a line and a byte offset in it.
pub const TextPos = struct {
    line: usize = 0,
    byte: usize = 0,

    fn before(a: TextPos, b: TextPos) bool {
        return a.line < b.line or (a.line == b.line and a.byte < b.byte);
    }
};

/// Selection and scrolling of a text view; the app keeps one per view.
pub const TextViewState = struct {
    anchor: ?TextPos = null,
    caret: TextPos = .{},
    dragging: bool = false,
    /// Was at the bottom: keep following new lines.
    at_bottom: bool = true,
    seen_total: u64 = 0,
    /// The absolute number of the oldest line last frame (lines a log has
    /// dropped since moved the selection; it is moved back onto its text).
    first_line: u64 = 0,

    /// The selection, start first, or null.
    pub fn selection(self: *const TextViewState) ?[2]TextPos {
        const a = self.anchor orelse return null;
        if (a.line == self.caret.line and a.byte == self.caret.byte) return null;
        return if (a.before(self.caret)) .{ a, self.caret } else .{ self.caret, a };
    }
};

/// Options for `textView`.
pub const TextViewOptions = struct {
    width: layout.Size = .fill,
    height: layout.Size = .fill,
    /// Draw in this font, a monospace one for code and logs.
    font: ?*font_mod.Font = null,
    /// Stay at the bottom as lines arrive, while scrolled to the bottom.
    follow: bool = true,
};

/// What a text view did.
pub const TextViewResult = struct {
    interaction: Interaction = .{},
    /// The selection was copied (Ctrl+C).
    copied: bool = false,
};

/// Read-only lines from `source`, which has `len() usize` and
/// `line(i) TextLine` (a `LogBuffer` does). Drag to select (across lines),
/// double-click selects a block, Ctrl+A everything, Ctrl+C copies. Only the
/// lines in view are drawn, so the length doesn't matter.
pub fn textView(ui: *Ui, name: []const u8, source: anytype, state: *TextViewState, options: TextViewOptions) TextViewResult {
    const style = &ui.style;
    const colors = &style.colors;
    if (options.font) |f| ui.pushFont(f);
    defer if (options.font != null) ui.popFont();
    const rect = ui.placeSized(options.width, options.height, .{ .x = style.widget_width * 2, .y = 200 });
    const widget = ui.id(name);
    var result: TextViewResult = .{};
    var focus = ui.interact(widget, .{});
    focus.rect = rect;
    ui.focusable(widget, &focus);
    const focused = ui.focused == widget;
    ui.drawRect(.{ .rect = rect, .fill = colors.input, .border = colors.border, .border_width = style.border_width, .radius = style.rounding });

    const count = source.len();
    const line = ui.font.lineMetrics(style.font_size);
    const row_h = @round(line.height + 1);
    const pad: f32 = 6;

    // New lines while at the bottom: stay at the bottom.
    const total: u64 = if (@hasField(@TypeOf(source.*), "total")) source.total else count;
    const grew = total != state.seen_total;
    state.seen_total = total;
    // Oldest lines dropped since last frame (a full log): line numbers
    // shifted down by that many; the selection follows its text, and
    // whatever of it was dropped is gone.
    const first_line: u64 = total -| count;
    if (first_line > state.first_line) {
        const d: usize = @intCast(first_line - state.first_line);
        if (state.anchor) |*a| {
            if (a.line < d) a.* = .{} else a.line -= d;
        }
        if (state.caret.line < d) state.caret = .{} else state.caret.line -= d;
        if (state.anchor) |a| if (a.line == state.caret.line and a.byte == state.caret.byte) {
            state.anchor = null;
        };
    }
    state.first_line = first_line;
    // The content's height is known exactly, so the scroll range is right
    // from the first frame, and following can go straight to the bottom.
    const known_h = @as(f32, @floatFromInt(count)) * row_h + 2 * pad;
    if (ui.scroll_states.getOrPut(ui.allocator, widget)) |entry| {
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.content_height = known_h;
        if (grew and options.follow and state.at_bottom) entry.value_ptr.scroll = @max(0, known_h - rect.h);
    } else |err| ui.fail(err);
    containers.beginScrollRegion(ui, widget, rect, pad, 0);
    const frame = ui.scroll_stack[ui.scroll_depth - 1];
    const scroll = if (ui.scroll_states.get(widget)) |s| s.scroll else 0;
    const content_h = @as(f32, @floatFromInt(count)) * row_h + 2 * pad;
    state.at_bottom = scroll + frame.view.h >= content_h - row_h * 0.5 or content_h <= frame.view.h;
    const first: usize = @min(count, @as(usize, @intFromFloat(@max(0, @floor((scroll) / row_h)))));
    const end: usize = @min(count, first + @as(usize, @intFromFloat(@ceil(frame.view.h / row_h) + 1)));
    const top = frame.view.y + pad - scroll;

    // The pointer: press, drag, double-click.
    const body = ui.interact(ui.id("##text"), frame.view);
    result.interaction = body;
    if (body.hovered or body.held) ui.cursor = .text;
    const in = &ui.input;
    if (body.pressed and count > 0) {
        ui.setFocus(widget);
        const at = hit(ui, source, frame.view, top, row_h, in.press_pos.get(.left), count);
        const clicks = in.press_clicks.get(.left);
        if (clicks >= 3) {
            state.anchor = .{};
            state.caret = .{ .line = count - 1, .byte = source.line(count - 1).text.len };
        } else if (clicks == 2) {
            // The whole block the line belongs to.
            const block = source.line(at.line).block;
            var a = at.line;
            while (a > 0 and source.line(a - 1).block == block and block != 0) a -= 1;
            var b = at.line;
            while (b + 1 < count and source.line(b + 1).block == block and block != 0) b += 1;
            state.anchor = .{ .line = a };
            state.caret = .{ .line = b, .byte = source.line(b).text.len };
        } else {
            if (!(in.modifiers.shift and state.anchor != null)) state.anchor = at;
            state.caret = at;
            state.dragging = true;
        }
    }
    if (body.held and state.dragging and count > 0) {
        state.caret = hit(ui, source, frame.view, top, row_h, in.mouse_pos, count);
        // Past the edges, scroll along.
        if (ui.scroll_states.getPtr(widget)) |s| {
            if (in.mouse_pos.y < frame.view.y) s.scroll -= row_h;
            if (in.mouse_pos.y > frame.view.bottom()) s.scroll += row_h;
            ui.requestRedraw();
        }
    }
    if (!body.held) state.dragging = false;

    // Keys, focused.
    if (focused) for (in.keyEvents()) |event| {
        const m = event.modifiers;
        if (!(m.ctrl or m.super)) {
            if (event.key == .escape) state.anchor = null;
            continue;
        }
        switch (event.key) {
            .a => if (count > 0) {
                state.anchor = .{};
                state.caret = .{ .line = count - 1, .byte = source.line(count - 1).text.len };
            },
            .c => result.copied = copySelection(ui, source, state),
            else => {},
        }
    };

    // Rows above the view take space, so the scroll range is right.
    if (first > 0) _ = ui.placeSized(.fill, .{ .fixed = @as(f32, @floatFromInt(first)) * row_h }, .{});
    const sel = state.selection();
    for (first..end) |i| {
        const ln = source.line(i);
        const r = ui.placeSized(.{ .fixed = @max(frame.view.w - 2 * pad, ui.textSize(ln.text).x) }, .{ .fixed = row_h }, .{});
        if (sel) |s| if (i >= s[0].line and i <= s[1].line) {
            const x0 = if (i == s[0].line) ui.textSize(ln.text[0..@min(s[0].byte, ln.text.len)]).x else 0;
            const x1 = if (i == s[1].line) ui.textSize(ln.text[0..@min(s[1].byte, ln.text.len)]).x else ui.textSize(ln.text).x + 6;
            if (x1 > x0) ui.drawRect(.{ .rect = .{ .x = r.x + x0, .y = r.y, .w = x1 - x0, .h = row_h }, .fill = colors.selection });
        };
        ui.drawText(.{ .x = r.x, .y = r.y }, ln.color orelse colors.text, ln.text);
        ui.recordWidget(.text_line, .none, ln.text, r, .{});
    }
    const below = count - end;
    if (below > 0) _ = ui.placeSized(.fill, .{ .fixed = @as(f32, @floatFromInt(below)) * row_h }, .{});
    containers.endScrollRegion(ui);
    ui.drawFocusRing(widget, rect);
    var vb: [32]u8 = undefined;
    ui.recordWidget(.text_view, widget, name, rect, .{ .value = std.fmt.bufPrint(&vb, "{d} lines", .{count}) catch "", .focused = focused });
    return result;
}

/// The place under `p`.
fn hit(ui: *Ui, source: anytype, view: Rect, top: f32, row_h: f32, p: Vec2, count: usize) TextPos {
    const fy = (p.y - top) / row_h;
    if (fy < 0) return .{};
    const i: usize = @min(count - 1, @as(usize, @intFromFloat(fy)));
    const text = source.line(i).text;
    const x = p.x - (view.x + 6);
    // The nearest boundary between characters.
    var it: font_mod.Utf8Iterator = .{ .bytes = text };
    var pen: f32 = 0;
    while (true) {
        const start = it.index;
        const cp = it.next() orelse break;
        const adv = ui.font.advance(cp, ui.style.font_size);
        if (x < pen + adv / 2) return .{ .line = i, .byte = start };
        pen += adv;
    }
    return .{ .line = i, .byte = text.len };
}

/// Copies the selected text to the clipboard, lines joined by `\n` (soft
/// lines without one).
/// Returns false if nothing is selected.
pub fn copySelection(ui: *Ui, source: anytype, state: *const TextViewState) bool {
    const s = state.selection() orelse return false;
    var out: std.ArrayList(u8) = .empty;
    const gpa = ui.frameAllocator();
    var i = s[0].line;
    while (i <= s[1].line and i < source.len()) : (i += 1) {
        const text = source.line(i).text;
        const a = if (i == s[0].line) @min(s[0].byte, text.len) else 0;
        const b = if (i == s[1].line) @min(s[1].byte, text.len) else text.len;
        out.appendSlice(gpa, text[a..b]) catch return false;
        if (i != s[1].line and !(i + 1 < source.len() and source.line(i + 1).soft)) out.append(gpa, '\n') catch return false;
    }
    ui.setClipboard(out.items);
    return true;
}

// ---- the console line -------------------------------------------------------

/// Earlier commands, for Up and Down in a console line.
pub const History = struct {
    entries: [max][limit]u8 = undefined,
    lens: [max]usize = @splat(0),
    count: usize = 0,
    /// Being browsed: how far back, 1 is the newest.
    back: usize = 0,
    /// What was typed before browsing, for Down past the newest.
    draft: [limit]u8 = undefined,
    draft_len: usize = 0,

    const max = 64;
    const limit = 256;

    /// Remembers `text`, unless it repeats the newest entry.
    pub fn push(self: *History, text: []const u8) void {
        self.back = 0;
        if (text.len == 0) return;
        if (self.count > 0 and std.mem.eql(u8, self.get(1), text)) return;
        if (self.count == max) {
            std.mem.copyForwards([limit]u8, self.entries[0 .. max - 1], self.entries[1..]);
            std.mem.copyForwards(usize, self.lens[0 .. max - 1], self.lens[1..]);
            self.count -= 1;
        }
        const n = @import("font.zig").fitUtf8(text, limit);
        @memcpy(self.entries[self.count][0..n], text[0..n]);
        self.lens[self.count] = n;
        self.count += 1;
    }

    /// The entry `back` steps from the newest (1 is the newest).
    pub fn get(self: *const History, back: usize) []const u8 {
        const i = self.count - back;
        return self.entries[i][0..self.lens[i]];
    }
};

/// Turns what was typed into a completion, for Tab in a console line.
pub const Completer = struct {
    context: ?*anyopaque = null,
    /// Writes the completed text into `out` and returns its length, or
    /// null if there is nothing to complete.
    complete: *const fn (context: ?*anyopaque, text: []const u8, out: []u8) ?usize,
};

/// Options for `consoleInput`.
pub const ConsoleOptions = struct {
    width: layout.Size = .fill,
    hint: []const u8 = "",
    complete: ?Completer = null,
};

/// A command line: Enter submits (and remembers it; the line keeps focus),
/// Up and Down go through the history, Tab completes. Clear the buffer
/// after running the command.
pub fn consoleInput(ui: *Ui, name: []const u8, buffer: []u8, len: *usize, history: *History, options: ConsoleOptions) Interaction {
    const widget = ui.id(name);
    const in = &ui.input;
    if (ui.focused == widget) {
        // Tab completes here, rather than moving the focus.
        ui.tab_owner = widget;
        const ups = in.takeKey(.up);
        const downs = in.takeKey(.down);
        var moved = false;
        for (0..ups) |_| {
            if (history.back == 0) {
                history.draft_len = @import("font.zig").fitUtf8(buffer[0..len.*], History.limit);
                @memcpy(history.draft[0..history.draft_len], buffer[0..history.draft_len]);
            }
            if (history.back < history.count) {
                history.back += 1;
                moved = true;
            }
        }
        for (0..downs) |_| if (history.back > 0) {
            history.back -= 1;
            moved = true;
        };
        if (moved) {
            const text = if (history.back == 0) history.draft[0..history.draft_len] else history.get(history.back);
            setText(ui, buffer, len, text);
        }
        if (in.takeKey(.tab) > 0) if (options.complete) |c| {
            var out: [256]u8 = undefined;
            if (c.complete(c.context, buffer[0..len.*], &out)) |n| setText(ui, buffer, len, out[0..@min(n, out.len)]);
        };
    }
    var result = ui.textInput(name, buffer, len, .{ .width = options.width, .hint = options.hint });
    if (result.submitted) {
        history.push(buffer[0..len.*]);
        // Ready for the next command.
        ui.setFocus(widget);
        // (a new session from the next frame; the keys typed before it
        // are still this line's)
        ui.text_edit.restart = true;
        result.focused = true;
    }
    return result;
}

fn setText(ui: *Ui, buffer: []u8, len: *usize, text: []const u8) void {
    const n = @import("font.zig").fitUtf8(text, buffer.len);
    @memcpy(buffer[0..n], text[0..n]);
    len.* = n;
    // The caret goes to the end.
    ui.text_edit.caret = n;
    ui.text_edit.anchor = n;
}

test "the log buffer drops its oldest lines and keeps the rest whole" {
    var log: LogBuffer = try .init(std.testing.allocator, 4, 32);
    defer log.deinit();
    log.add(null, "one");
    log.add(null, "two\nthree");
    try std.testing.expectEqual(@as(usize, 3), log.len());
    try std.testing.expectEqual(log.line(1).block, log.line(2).block);
    log.add(null, "four");
    log.add(null, "five");
    try std.testing.expectEqual(@as(usize, 4), log.len());
    try std.testing.expectEqualStrings("two", log.line(0).text);
    // Long lines push out more of the old ones.
    log.add(null, "a line of twenty-five ch");
    try std.testing.expectEqualStrings("a line of twenty-five ch", log.line(log.len() - 1).text);
    for (0..log.len()) |i| try std.testing.expect(log.line(i).text.len <= 32);
    try std.testing.expectEqual(@as(u64, 6), log.total);
}

test "history keeps entries, skips repeats" {
    var h: History = .{};
    h.push("ls");
    h.push("ls");
    h.push("cd ..");
    try std.testing.expectEqual(@as(usize, 2), h.count);
    try std.testing.expectEqualStrings("cd ..", h.get(1));
    try std.testing.expectEqualStrings("ls", h.get(2));
}
