//! Per-frame input state. A backend feeds events in through the `on*` methods
//! between frames; widgets read the result during the frame. `Ui.endFrame`
//! clears the edge-triggered parts.

const std = @import("std");
const Vec2 = @import("draw.zig").Vec2;
const Color = @import("draw.zig").Color;

/// A mouse button.
pub const MouseButton = enum { left, right, middle };

/// Keys that the library itself reacts to. Backends map their native codes to
/// these and report anything else as text input only.
pub const Key = enum {
    tab,
    enter,
    escape,
    backspace,
    delete,
    insert,
    space,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    minus,
    equal,
    comma,
    period,
    slash,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    @"0",
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// Keyboard modifier state.
pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

/// One key press, with what was held and how much text had been typed at that
/// moment, so that an editor can replay typing and keys in their real order.
pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers,
    /// The length of `Input.text()` when the key went down.
    text_offset: usize,
};

/// One pointer event, in the order it came: what a canvas that paints
/// strokes or counts gestures exactly needs, where `Input`'s per-frame
/// state keeps only the last position and each button's edges.
pub const PointerEvent = struct {
    kind: Kind,
    /// The button that went down or up (`press` and `release` only).
    button: MouseButton = .left,
    /// Where the pointer was, in logical units.
    pos: Vec2,
    /// Wheel lines (`scroll` only); positive `y` scrolls up.
    scroll: Vec2 = .{},
    /// 2 for the second press of a double click (`press` only).
    clicks: u8 = 1,
    modifiers: Modifiers = .{},
    /// A pen's pressure, 0 to 1, as `Input.onPressure` last set it (1 for a mouse).
    pressure: f32 = 1,

    /// What happened: the pointer moved, a button went down or up, the wheel turned.
    pub const Kind = enum { move, press, release, scroll };
};

/// Everything the UI knows about the user's input for one frame.
pub const Input = struct {
    /// Mouse position in logical units.
    mouse_pos: Vec2 = .{},
    /// Buttons currently held.
    mouse_down: std.EnumSet(MouseButton) = .empty,
    /// Buttons that went down this frame.
    mouse_pressed: std.EnumSet(MouseButton) = .empty,
    /// Buttons that went up this frame. A press and release inside one frame
    /// set both this and `mouse_pressed`, so a fast click is never lost.
    mouse_released: std.EnumSet(MouseButton) = .empty,
    /// Buttons pressed again after a release in this same frame (release on
    /// one widget, press on another; or a fast double click and hold): the
    /// release belongs to the earlier hold, the press starts a new one.
    pressed_after_release: std.EnumSet(MouseButton) = .empty,
    /// Where each button last went down. Several events can arrive between
    /// frames, so by the time a frame runs the mouse may already have left
    /// the spot where it was pressed; widgets test presses against this.
    press_pos: std.EnumArray(MouseButton, Vec2) = .initFill(.{}),
    /// 1 for a single click, 2 for a double click, and so on, as of each
    /// button's last press.
    press_clicks: std.EnumArray(MouseButton, u8) = .initFill(1),
    /// Where each button last went up.
    release_pos: std.EnumArray(MouseButton, Vec2) = .initFill(.{}),
    /// Scroll since the last frame, in lines. Positive `y` scrolls up.
    scroll: Vec2 = .{},
    /// Keys pressed this frame, including auto-repeat.
    keys_pressed: std.EnumSet(Key) = .empty,
    /// Keys held down now. Backends that report key releases keep it.
    keys_down: std.EnumSet(Key) = .empty,
    /// Keys that went up this frame: a pie menu closes when the key that
    /// opened it is let go.
    keys_released: std.EnumSet(Key) = .empty,
    /// Current modifiers.
    modifiers: Modifiers = .{},
    /// Text typed since the last frame (a burst between two slow frames,
    /// an input method's phrase: room for a paragraph).
    text_buffer: [1024]u8 = undefined,
    text_len: usize = 0,
    /// Files dropped onto the window since the last frame: their paths,
    /// end to end in `drop_buffer`, and where they landed.
    drop_buffer: [8192]u8 = undefined,
    drop_len: usize = 0,
    drop_ends: [32]u16 = undefined,
    drop_count: usize = 0,
    drop_pos: Vec2 = .{},
    key_event_buffer: [256]KeyEvent = undefined,
    key_event_len: usize = 0,
    /// The pointer's events since the last frame, in order (`pointerEvents`).
    /// When it is full, a move replaces the move before it, so the latest
    /// position and every button change are kept.
    pointer_event_buffer: [256]PointerEvent = undefined,
    pointer_event_len: usize = 0,
    /// A pen's pressure for the events that follow (`onPressure`).
    pressure: f32 = 1,
    /// The colour of the pixel at `Ui.sample_request`, read back by the
    /// backend after rendering, for the eyedropper. Kept until replaced.
    sampled: ?Color = null,
    /// Which OS window the pointer is in: `.none` for the main one, or a
    /// `Ui.Viewport`'s ID. Positions are in that window's own units.
    viewport: @import("ui.zig").Id = .none,
    /// Which OS window has the keyboard, like `viewport` for the pointer.
    /// Tab stays among its widgets.
    keyboard_viewport: @import("ui.zig").Id = .none,
    /// Window units per UI unit: positions given to `onMouseMove` and
    /// `onFileDrop` are divided by it. `Ui.setScale` sets it.
    unit_scale: f32 = 1,

    /// Reports a new mouse position.
    pub fn onMouseMove(self: *Input, pos: Vec2) void {
        self.mouse_pos = pos.scale(1 / self.unit_scale);
        self.pushPointer(.{ .kind = .move, .pos = self.mouse_pos });
    }

    /// Reports a pen's pressure (0 to 1) for the pointer events after it;
    /// a backend sets it back to 1 when the pen leaves.
    pub fn onPressure(self: *Input, pressure: f32) void {
        self.pressure = std.math.clamp(pressure, 0, 1);
    }

    /// This frame's pointer events (moves, presses, releases, wheel) in the
    /// order they happened.
    pub fn pointerEvents(self: *const Input) []const PointerEvent {
        return self.pointer_event_buffer[0..self.pointer_event_len];
    }

    fn pushPointer(self: *Input, ev0: PointerEvent) void {
        var ev = ev0;
        ev.modifiers = self.modifiers;
        ev.pressure = self.pressure;
        const n = self.pointer_event_len;
        // (nearly full: a move takes the place of the move before it, and
        // the last places are left for presses, releases and the wheel)
        if (ev.kind == .move and n >= self.pointer_event_buffer.len - 16) {
            if (self.pointer_event_buffer[n - 1].kind == .move) {
                self.pointer_event_buffer[n - 1] = ev;
                return;
            }
        }
        if (n == self.pointer_event_buffer.len) return;
        self.pointer_event_buffer[n] = ev;
        self.pointer_event_len = n + 1;
    }

    /// Reports a key going up.
    pub fn onKeyRelease(self: *Input, key: Key) void {
        self.keys_down.remove(key);
        self.keys_released.insert(key);
    }

    /// Reports the colour read back at `Ui.sample_request`. Returns true if
    /// it differs from the last one, so another frame is worth drawing.
    pub fn onColorSample(self: *Input, c: Color) bool {
        const changed = if (self.sampled) |old| !old.eql(c) else true;
        self.sampled = c;
        return changed;
    }

    /// Reports a mouse button change.
    pub fn onMouseButton(self: *Input, button: MouseButton, down: bool) void {
        self.onMouseButtonClicks(button, down, 1);
    }

    /// Like `onMouseButton`, for backends that count multiple clicks: `clicks`
    /// is 2 for the second press of a double click, and so on.
    pub fn onMouseButtonClicks(self: *Input, button: MouseButton, down: bool, clicks: u8) void {
        if (down) {
            if (self.mouse_released.contains(button)) self.pressed_after_release.insert(button);
            self.mouse_down.insert(button);
            self.mouse_pressed.insert(button);
            self.press_pos.set(button, self.mouse_pos);
            self.press_clicks.set(button, @max(1, clicks));
            self.pushPointer(.{ .kind = .press, .button = button, .pos = self.mouse_pos, .clicks = @max(1, clicks) });
        } else {
            self.mouse_down.remove(button);
            self.mouse_released.insert(button);
            self.release_pos.set(button, self.mouse_pos);
            self.pushPointer(.{ .kind = .release, .button = button, .pos = self.mouse_pos });
        }
    }

    /// Adds scroll wheel movement, in lines.
    pub fn onScroll(self: *Input, delta: Vec2) void {
        self.scroll = self.scroll.add(delta);
        self.pushPointer(.{ .kind = .scroll, .pos = self.mouse_pos, .scroll = delta });
    }

    /// Reports a key press or auto-repeat. Set `modifiers` first. Presses past
    /// the per-frame limit still count in `keys_pressed`.
    pub fn onKeyPress(self: *Input, key: Key) void {
        self.keys_pressed.insert(key);
        self.keys_down.insert(key);
        if (self.key_event_len == self.key_event_buffer.len) return;
        self.key_event_buffer[self.key_event_len] = .{
            .key = key,
            .modifiers = self.modifiers,
            .text_offset = self.text_len,
        };
        self.key_event_len += 1;
    }

    /// Returns this frame's key presses in the order they happened.
    pub fn keyEvents(self: *const Input) []const KeyEvent {
        return self.key_event_buffer[0..self.key_event_len];
    }

    /// Appends UTF-8 text typed by the user. Text that does not fit is dropped
    /// at a codepoint boundary, so `text()` always returns valid UTF-8.
    pub fn onText(self: *Input, utf8: []const u8) void {
        var i: usize = 0;
        while (i < utf8.len) {
            const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch return;
            if (i + len > utf8.len or self.text_len + len > self.text_buffer.len) return;
            @memcpy(self.text_buffer[self.text_len..][0..len], utf8[i..][0..len]);
            self.text_len += len;
            i += len;
        }
    }

    /// Returns the text typed this frame.
    pub fn text(self: *const Input) []const u8 {
        return self.text_buffer[0..self.text_len];
    }

    /// Removes the presses of `key` from this frame, for a widget that
    /// used them, so the widgets after it don't see them. Returns how many.
    pub fn takeKey(self: *Input, key: Key) usize {
        var n: usize = 0;
        var kept: usize = 0;
        for (self.key_event_buffer[0..self.key_event_len]) |event| {
            if (event.key == key) {
                n += 1;
            } else {
                self.key_event_buffer[kept] = event;
                kept += 1;
            }
        }
        self.key_event_len = kept;
        self.keys_pressed.remove(key);
        return n;
    }

    /// A file was dropped onto the window at `pos` (logical units). The
    /// path is copied; paths that don't fit are left out.
    pub fn onFileDrop(self: *Input, path: []const u8, pos: Vec2) void {
        if (self.drop_count == self.drop_ends.len or self.drop_len + path.len > self.drop_buffer.len) return;
        @memcpy(self.drop_buffer[self.drop_len..][0..path.len], path);
        self.drop_len += path.len;
        self.drop_ends[self.drop_count] = @intCast(self.drop_len);
        self.drop_count += 1;
        self.drop_pos = pos.scale(1 / self.unit_scale);
    }

    /// The `i`th file dropped since the last frame.
    pub fn droppedFile(self: *const Input, i: usize) []const u8 {
        const start: usize = if (i == 0) 0 else self.drop_ends[i - 1];
        return self.drop_buffer[start..self.drop_ends[i]];
    }

    /// Clears all edge-triggered state. Called by `Ui.endFrame`.
    pub fn clearEdges(self: *Input) void {
        self.drop_count = 0;
        self.drop_len = 0;
        self.mouse_pressed = .empty;
        self.mouse_released = .empty;
        self.pressed_after_release = .empty;
        self.scroll = .{};
        self.keys_pressed = .empty;
        self.keys_released = .empty;
        self.key_event_len = 0;
        self.pointer_event_len = 0;
        self.text_len = 0;
    }
};

test "pointer events keep their order, positions and pressure" {
    var input: Input = .{};
    input.onMouseMove(.{ .x = 1, .y = 1 });
    input.onMouseButton(.left, true);
    input.onPressure(0.5);
    input.onMouseMove(.{ .x = 2, .y = 3 });
    input.onMouseButton(.left, false);
    input.onScroll(.{ .y = -1 });
    const evs = input.pointerEvents();
    try std.testing.expectEqual(@as(usize, 5), evs.len);
    try std.testing.expectEqual(PointerEvent.Kind.press, evs[1].kind);
    try std.testing.expectEqual(@as(f32, 1), evs[1].pressure);
    try std.testing.expectEqual(@as(f32, 3), evs[2].pos.y);
    try std.testing.expectEqual(@as(f32, 0.5), evs[2].pressure);
    try std.testing.expectEqual(PointerEvent.Kind.release, evs[3].kind);
    try std.testing.expectEqual(@as(f32, -1), evs[4].scroll.y);
    input.clearEdges();
    try std.testing.expectEqual(@as(usize, 0), input.pointerEvents().len);
}

test "a full pointer log keeps the last move and every button change" {
    var input: Input = .{};
    for (0..300) |k| input.onMouseMove(.{ .x = @floatFromInt(k), .y = 0 });
    input.onMouseButton(.left, true);
    for (0..300) |k| input.onMouseMove(.{ .x = @floatFromInt(k), .y = 1 });
    input.onMouseButton(.left, false);
    const evs = input.pointerEvents();
    try std.testing.expect(evs.len <= input.pointer_event_buffer.len);
    try std.testing.expectEqual(PointerEvent.Kind.release, evs[evs.len - 1].kind);
    try std.testing.expectEqual(PointerEvent.Kind.press, evs[evs.len - 3].kind);
    // (the moves before each change end where the pointer was)
    try std.testing.expectEqual(@as(f32, 299), evs[evs.len - 4].pos.x);
    try std.testing.expectEqual(@as(f32, 299), evs[evs.len - 2].pos.x);
}

test "press and release in one frame keep both edges" {
    var input: Input = .{};
    input.onMouseButton(.left, true);
    input.onMouseButton(.left, false);
    try std.testing.expect(input.mouse_pressed.contains(.left));
    try std.testing.expect(input.mouse_released.contains(.left));
    try std.testing.expect(!input.mouse_down.contains(.left));
}

test "overflowing text is cut at a codepoint boundary" {
    var input: Input = .{};
    var filler: [input.text_buffer.len - 1]u8 = @splat('a');
    input.onText(&filler);
    input.onText("é");
    try std.testing.expectEqual(filler.len, input.text().len);
}

test "key events remember their place in the typed text" {
    var input: Input = .{};
    input.onText("ab");
    input.modifiers.shift = true;
    input.onKeyPress(.left);
    input.onText("c");
    const events = input.keyEvents();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(usize, 2), events[0].text_offset);
    try std.testing.expect(events[0].modifiers.shift);
    input.clearEdges();
    try std.testing.expectEqual(@as(usize, 0), input.keyEvents().len);
}

/// A key with modifiers, such as Ctrl+Shift+Z: for an app's keymap, shown in
/// menus and edited with `Ui.shortcutField`.
pub const Shortcut = struct {
    key: Key,
    modifiers: Modifiers = .{},

    /// True if this exact combination was pressed this frame.
    pub fn pressed(self: Shortcut, input: *const Input) bool {
        for (input.keyEvents()) |event| {
            if (event.key == self.key and @as(u4, @bitCast(event.modifiers)) == @as(u4, @bitCast(self.modifiers))) return true;
        }
        return false;
    }

    /// Writes it the way menus show it: "Ctrl+Shift+Z", "F5", "Page Up".
    pub fn format(self: Shortcut, buffer: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buffer);
        if (self.modifiers.ctrl) w.writeAll("Ctrl+") catch {};
        if (self.modifiers.alt) w.writeAll("Alt+") catch {};
        if (self.modifiers.shift) w.writeAll("Shift+") catch {};
        if (self.modifiers.super) w.writeAll("Super+") catch {};
        w.writeAll(keyName(self.key)) catch {};
        return w.buffered();
    }

    /// Reads "ctrl+shift+z", "F5", "alt+page_up". Case doesn't matter.
    pub fn parse(text: []const u8) ?Shortcut {
        @setEvalBranchQuota(20_000);
        var result: Shortcut = .{ .key = .escape };
        var have_key = false;
        var parts = std.mem.splitScalar(u8, text, '+');
        while (parts.next()) |raw| {
            var lower: [16]u8 = undefined;
            if (raw.len == 0 or raw.len > lower.len) return null;
            const part = std.ascii.lowerString(&lower, std.mem.trim(u8, raw, " "));
            if (std.mem.eql(u8, part, "ctrl")) {
                result.modifiers.ctrl = true;
            } else if (std.mem.eql(u8, part, "shift")) {
                result.modifiers.shift = true;
            } else if (std.mem.eql(u8, part, "alt")) {
                result.modifiers.alt = true;
            } else if (std.mem.eql(u8, part, "super")) {
                result.modifiers.super = true;
            } else {
                result.key = keyFromName(part) orelse return null;
                have_key = true;
            }
        }
        return if (have_key) result else null;
    }
};

/// The key named by its tag, such as "page_up". A plain loop rather than
/// `std.meta.stringToEnum`, so that parsing also works at compile time.
fn keyFromName(name: []const u8) ?Key {
    @setEvalBranchQuota(20_000);
    inline for (comptime std.meta.fieldNames(Key)) |n| {
        if (std.mem.eql(u8, n, name)) return @field(Key, n);
    }
    return null;
}

/// How a key is written for people: "A", "F5", "Enter", "Page Up".
pub fn keyName(key: Key) []const u8 {
    return switch (key) {
        .tab => "Tab",
        .enter => "Enter",
        .escape => "Esc",
        .backspace => "Backspace",
        .delete => "Delete",
        .insert => "Insert",
        .space => "Space",
        .left => "Left",
        .right => "Right",
        .up => "Up",
        .down => "Down",
        .home => "Home",
        .end => "End",
        .page_up => "Page Up",
        .page_down => "Page Down",
        .minus => "-",
        .equal => "=",
        .comma => ",",
        .period => ".",
        .slash => "/",
        inline else => |k| comptime blk: {
            const name = @tagName(k);
            var upper: [name.len]u8 = undefined;
            for (name, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
            const final = upper;
            break :blk &final;
        },
    };
}

test "shortcuts read, write and match" {
    const s = Shortcut.parse("ctrl+Shift+z").?;
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+Z", s.format(&b));
    try std.testing.expectEqualStrings("F5", (Shortcut{ .key = .f5 }).format(&b));
    try std.testing.expectEqualStrings("Alt+Page Up", Shortcut.parse("alt+page_up").?.format(&b));
    try std.testing.expect(Shortcut.parse("ctrl+") == null);
    try std.testing.expect(Shortcut.parse("hyper+x") == null);
    var input: Input = .{};
    input.modifiers = .{ .ctrl = true, .shift = true };
    input.onKeyPress(.z);
    try std.testing.expect(s.pressed(&input));
    try std.testing.expect(!(Shortcut{ .key = .z, .modifiers = .{ .ctrl = true } }).pressed(&input));
}
