//! Scripted input: drive a `Ui` by widget name, for headless tests,
//! screenshots and demos, like BeeModel's `--shot` scenarios.
//!
//! A script is one command per line; a line starting with `#` is a comment.
//! Widgets are named `label`, `kind:label` or `Window > kind:label`.
//!
//!     click button:Save
//!     double-click selectable:notes.txt
//!     right-click canvas:view
//!     hover button:Save
//!     # Seconds; long enough for a tooltip to appear.
//!     wait 0.8
//!     type hello world
//!     key ctrl+a
//!     key shift+tab
//!     # Held across lines, as for a pie menu, then let go.
//!     hold z
//!     release z
//!     # Along the widget, by an offset, or onto another widget.
//!     drag slider:Volume to 75%
//!     # Across and down a 2D area, such as a colour square.
//!     drag color_area:Saturation and value to 80% 10%
//!     drag window:Tools by 120 40
//!     drag selectable:a.txt to button:Trash
//!     # Lines; negative scrolls down.
//!     scroll scroll_area:files -3
//!     move 300 200
//!     expect checkbox:Snap = true
//!     expect text_input:Name focused
//!     expect button:Delete missing
//!     expect button:Paste disabled
//!     expect Tools > button:Apply exists
//!     frames 5
//!     shot after-save.png
//!
//! The player turns each command into input and frames. Run it like this:
//!
//!     var player: zui.ScriptPlayer = try .init(gpa, script_text);
//!     defer player.deinit();
//!     while (try player.next(&ui)) |step| switch (step) {
//!         .frame => |dt| { ui.beginFrame(.{ .width = w, .height = h, .dt = dt }); app(&ui); _ = try ui.endFrame(); },
//!         .shot => |path| savePng(path),
//!     };
//!
//! A failed step returns an error; `player.message()` says which line and
//! why. Targets are looked up in the frame before the step, so the player
//! turns `ui.recording` on, and waits up to a second of frames for a widget
//! that isn't there yet, such as one in a popup that is still opening.

const std = @import("std");
const draw = @import("draw.zig");
const input = @import("input.zig");
const record = @import("record.zig");
const Ui = @import("ui.zig").Ui;
const Vec2 = draw.Vec2;
const Allocator = std.mem.Allocator;

/// What the caller should do next.
pub const Step = union(enum) {
    /// Run one frame that lasts this many seconds. Input is already in
    /// `ui.input`.
    frame: f32,
    /// Render the last frame and save it to this path.
    shot: []const u8,
};

/// Why a script stopped.
pub const Error = error{ ScriptSyntax, WidgetNotFound, WidgetCovered, ExpectationFailed } || Allocator.Error;

const Action = union(enum) {
    move: Vec2,
    press: struct { button: input.MouseButton, clicks: u8 },
    release: struct { button: input.MouseButton, clicks: u8 },
    scroll: f32,
    key: struct { key: input.Key, modifiers: input.Modifiers },
    key_up: input.Key,
    modifiers: input.Modifiers,
    text: []const u8,
    frame: f32,
    shot: []const u8,
};

/// Plays a script against a `Ui`, one step at a time.
pub const Player = struct {
    allocator: Allocator,
    text: []u8,
    lines: std.mem.SplitIterator(u8, .scalar),
    line_number: u32 = 0,
    line: []const u8 = "",
    queue: std.ArrayList(Action) = .empty,
    queue_head: usize = 0,
    /// Frames spent waiting for the current line's widget to appear.
    retries: u32 = 0,
    started: bool = false,
    /// Seconds per frame.
    dt: f32 = 1.0 / 60.0,
    message_buffer: [256]u8 = undefined,
    message_len: usize = 0,

    /// Frames to wait for a widget that isn't shown yet.
    pub const max_retries = 60;

    /// Copies `script` and prepares to play it.
    pub fn init(allocator: Allocator, script: []const u8) Allocator.Error!Player {
        const text = try allocator.dupe(u8, script);
        return .{ .allocator = allocator, .text = text, .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    /// Frees the copy.
    pub fn deinit(self: *Player) void {
        self.queue.deinit(self.allocator);
        self.allocator.free(self.text);
    }

    /// Why the last error happened, with the line it came from.
    pub fn message(self: *const Player) []const u8 {
        return self.message_buffer[0..self.message_len];
    }

    fn fail(self: *Player, err: Error, comptime fmt: []const u8, args: anytype) Error {
        var w: std.Io.Writer = .fixed(&self.message_buffer);
        w.print("line {d}: ", .{self.line_number}) catch {};
        w.print(fmt, args) catch {};
        w.print("\n  {s}", .{std.mem.trim(u8, self.line, " \t\r")}) catch {};
        self.message_len = w.end;
        return err;
    }

    /// Returns the next step, or null when the script is done. The first
    /// call returns a frame so that there is something to look at.
    pub fn next(self: *Player, ui: *Ui) Error!?Step {
        ui.recording = true;
        if (!self.started) {
            // Two frames first, so the layout has settled before any lookup.
            self.started = true;
            try self.frames(2);
        }
        while (true) {
            while (self.queue_head < self.queue.items.len) {
                const action = self.queue.items[self.queue_head];
                self.queue_head += 1;
                switch (action) {
                    .move => |p| ui.input.onMouseMove(p.scale(ui.input.unit_scale)),
                    .press => |b| ui.input.onMouseButtonClicks(b.button, true, b.clicks),
                    .release => |b| ui.input.onMouseButtonClicks(b.button, false, b.clicks),
                    .scroll => |dy| ui.input.onScroll(.{ .y = dy }),
                    .key => |k| {
                        // Held for the frame, as a widget may look.
                        ui.input.modifiers = k.modifiers;
                        ui.input.onKeyPress(k.key);
                    },
                    .key_up => |k| ui.input.onKeyRelease(k),
                    .modifiers => |m| ui.input.modifiers = m,
                    .text => |t| ui.input.onText(t),
                    .frame => |dt| return .{ .frame = dt },
                    .shot => |path| return .{ .shot = path },
                }
            }
            self.queue.clearRetainingCapacity();
            self.queue_head = 0;
            if (self.retries == 0) {
                const raw = self.lines.next() orelse return null;
                self.line_number += 1;
                self.line = raw;
            }
            try self.expand(ui);
        }
    }

    fn push(self: *Player, action: Action) Allocator.Error!void {
        try self.queue.append(self.allocator, action);
    }

    fn frames(self: *Player, n: usize) Allocator.Error!void {
        for (0..n) |_| try self.push(.{ .frame = self.dt });
    }

    /// Looks a widget up. Null means "not yet": a frame is queued to wait.
    fn target(self: *Player, ui: *const Ui, name: []const u8) Error!?record.Widget {
        // A layout still settling (it asked for another frame) may move the
        // widget; look it up once it is still, as the window loop would draw.
        if (ui.redraw_requested and ui.redraw_in == null and self.retries < max_retries) {
            self.retries += 1;
            try self.push(.{ .frame = self.dt });
            return null;
        }
        if (ui.findWidget(name)) |w| return w;
        if (self.retries < max_retries) {
            self.retries += 1;
            try self.push(.{ .frame = self.dt });
            return null;
        }
        return self.fail(error.WidgetNotFound, "no widget \"{s}\" is shown", .{name});
    }

    /// Where a script would click `w`: a point no window in front of it
    /// covers, or null.
    pub fn clickPointOf(ui: *const Ui, w: record.Widget) ?Vec2 {
        return record.clickPoint(ui, w);
    }

    fn pointOf(self: *Player, ui: *const Ui, w: record.Widget) Error!Vec2 {
        return record.clickPoint(ui, w) orelse self.fail(error.WidgetCovered, "\"{s}\" is covered by a window in front of it", .{w.label});
    }

    /// Turns the current line into actions.
    fn expand(self: *Player, ui: *Ui) Error!void {
        const line = std.mem.trim(u8, self.line, " \t\r");
        if (line.len == 0 or line[0] == '#') return;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const command = line[0..space];
        const rest = std.mem.trim(u8, line[space..], " ");

        const Command = enum { click, @"double-click", @"right-click", @"middle-click", hover, move, drag, scroll, type, key, hold, release, wait, frames, expect, shot };
        const cmd = std.meta.stringToEnum(Command, command) orelse
            return self.fail(error.ScriptSyntax, "unknown command \"{s}\"", .{command});

        switch (cmd) {
            .click, .@"double-click", .@"right-click", .@"middle-click", .hover => {
                const w = try self.target(ui, rest) orelse return;
                self.retries = 0;
                const p = try self.pointOf(ui, w);
                try self.push(.{ .move = p });
                try self.frames(1);
                if (cmd == .hover) return self.frames(1);
                const button: input.MouseButton = switch (cmd) {
                    .@"right-click" => .right,
                    .@"middle-click" => .middle,
                    else => .left,
                };
                const count: u8 = if (cmd == .@"double-click") 2 else 1;
                for (1..count + 1) |clicks| {
                    try self.push(.{ .press = .{ .button = button, .clicks = @intCast(clicks) } });
                    try self.frames(1);
                    try self.push(.{ .release = .{ .button = button, .clicks = @intCast(clicks) } });
                    try self.frames(1);
                }
                try self.frames(1);
            },
            .move => {
                var it = std.mem.tokenizeScalar(u8, rest, ' ');
                const x = try self.number(it.next());
                const y = try self.number(it.next());
                try self.push(.{ .move = .{ .x = x, .y = y } });
                try self.frames(1);
            },
            .drag => try self.drag(ui, rest),
            .scroll => {
                const cut = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse
                    return self.fail(error.ScriptSyntax, "scroll needs a widget and a number of lines", .{});
                const lines = try self.number(rest[cut + 1 ..]);
                const w = try self.target(ui, rest[0..cut]) orelse return;
                self.retries = 0;
                try self.push(.{ .move = try self.pointOf(ui, w) });
                try self.frames(1);
                try self.push(.{ .scroll = lines });
                try self.frames(2);
            },
            .type => {
                // Everything after "type ", spaces included.
                const raw = std.mem.trimStart(u8, self.line, " \t");
                var typed = std.mem.trimEnd(u8, raw[@min(raw.len, 5)..], "\r");
                // Input holds a limited amount of text per frame; send long
                // text in pieces, cut between characters.
                while (typed.len > 0) {
                    var n = @min(typed.len, 48);
                    while (n < typed.len and n > 0 and typed[n] & 0xC0 == 0x80) n -= 1;
                    // Nothing but continuation bytes (not UTF-8): send them as
                    // they are rather than never moving on.
                    if (n == 0) n = @min(typed.len, 48);
                    try self.push(.{ .text = typed[0..n] });
                    try self.frames(1);
                    typed = typed[n..];
                }
                try self.frames(1);
            },
            .key => {
                const k = try self.chord(rest);
                try self.push(.{ .key = .{ .key = k.key, .modifiers = k.modifiers } });
                try self.frames(1);
                try self.push(.{ .key_up = k.key });
                try self.push(.{ .modifiers = .{} });
                try self.frames(1);
            },
            .hold => {
                const k = try self.chord(rest);
                try self.push(.{ .key = .{ .key = k.key, .modifiers = k.modifiers } });
                try self.frames(1);
            },
            .release => {
                const k = try self.chord(rest);
                try self.push(.{ .key_up = k.key });
                try self.push(.{ .modifiers = .{} });
                try self.frames(2);
            },
            .wait => {
                const seconds = try self.number(rest);
                try self.frames(try self.frameCount(@ceil(@max(0, seconds) / self.dt)));
            },
            .frames => try self.frames(try self.frameCount(try self.number(rest))),
            .expect => try self.expect(ui, rest),
            .shot => {
                if (rest.len == 0) return self.fail(error.ScriptSyntax, "shot needs a file name", .{});
                try self.push(.{ .shot = rest });
            },
        }
    }

    /// A key with modifiers, such as "ctrl+shift+z".
    fn chord(self: *Player, text: []const u8) Error!struct { key: input.Key, modifiers: input.Modifiers } {
        var modifiers: input.Modifiers = .{};
        var key: ?input.Key = null;
        var parts = std.mem.splitScalar(u8, text, '+');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "ctrl")) {
                modifiers.ctrl = true;
            } else if (std.mem.eql(u8, part, "shift")) {
                modifiers.shift = true;
            } else if (std.mem.eql(u8, part, "alt")) {
                modifiers.alt = true;
            } else if (std.mem.eql(u8, part, "super")) {
                modifiers.super = true;
            } else {
                key = keyNamed(part) orelse return self.fail(error.ScriptSyntax, "unknown key \"{s}\"", .{part});
            }
        }
        return .{ .key = key orelse return self.fail(error.ScriptSyntax, "no key given", .{}), .modifiers = modifiers };
    }

    /// Most frames one line may ask for: half an hour at 60 per second.
    const max_frames = 108_000;

    /// A count of frames from a number in a script: at least one, and no
    /// more than `max_frames` ("frames inf" or "wait 1e9" is a mistake).
    fn frameCount(self: *Player, n: f32) Error!usize {
        if (!std.math.isFinite(n) or n > max_frames) return self.fail(error.ScriptSyntax, "too many frames: {d} (at most {d})", .{ n, max_frames });
        return @max(1, @as(usize, @intFromFloat(@max(0, n))));
    }

    fn number(self: *Player, text: ?[]const u8) Error!f32 {
        const t = text orelse return self.fail(error.ScriptSyntax, "a number is missing", .{});
        return std.fmt.parseFloat(f32, t) catch self.fail(error.ScriptSyntax, "\"{s}\" is not a number", .{t});
    }

    fn drag(self: *Player, ui: *Ui, rest: []const u8) Error!void {
        var from_name = rest;
        var to: union(enum) { by: Vec2, percent: f32, point: Vec2, widget: []const u8 } = undefined;
        if (std.mem.lastIndexOf(u8, rest, " by ")) |i| {
            from_name = rest[0..i];
            var it = std.mem.tokenizeScalar(u8, rest[i + 4 ..], ' ');
            to = .{ .by = .{ .x = try self.number(it.next()), .y = try self.number(it.next()) } };
        } else if (std.mem.lastIndexOf(u8, rest, " to ")) |i| {
            from_name = rest[0..i];
            const where = std.mem.trim(u8, rest[i + 4 ..], " ");
            var parts = std.mem.tokenizeScalar(u8, where, ' ');
            const first = parts.next() orelse "";
            const second = parts.next();
            const percent = struct {
                fn f(t: []const u8) bool {
                    return t.len > 1 and t[t.len - 1] == '%';
                }
            }.f;
            if (second != null and percent(first) and percent(second.?) and parts.next() == null) {
                to = .{ .point = .{
                    .x = try self.number(first[0 .. first.len - 1]) / 100,
                    .y = try self.number(second.?[0 .. second.?.len - 1]) / 100,
                } };
            } else if (percent(where)) {
                to = .{ .percent = try self.number(where[0 .. where.len - 1]) / 100 };
            } else to = .{ .widget = where };
        } else return self.fail(error.ScriptSyntax, "drag needs \"by DX DY\", \"to N%\" or \"to <widget>\"", .{});

        const w = try self.target(ui, from_name) orelse return;
        if (to == .widget) {
            if (try self.target(ui, to.widget) == null) return;
        }
        self.retries = 0;
        const start = switch (to) {
            // Along a slider: start on the thumb's side doesn't matter, the
            // press jumps there anyway.
            .percent => Vec2{ .x = w.rect.x + 1, .y = w.rect.y + w.rect.h / 2 },
            else => try self.pointOf(ui, w),
        };
        const end: Vec2 = switch (to) {
            .by => |d| start.add(d),
            .percent => |f| .{ .x = w.rect.x + w.rect.w * std.math.clamp(f, 0, 1), .y = start.y },
            .point => |f| .{ .x = w.rect.x + w.rect.w * std.math.clamp(f.x, 0, 1), .y = w.rect.y + w.rect.h * std.math.clamp(f.y, 0, 1) },
            .widget => |name| try self.pointOf(ui, ui.findWidget(name).?),
        };
        try self.push(.{ .move = start });
        try self.frames(1);
        try self.push(.{ .press = .{ .button = .left, .clicks = 1 } });
        try self.frames(1);
        const steps = 8;
        for (1..steps + 1) |i| {
            try self.push(.{ .move = start.lerp(end, @as(f32, @floatFromInt(i)) / steps) });
            try self.frames(1);
        }
        try self.push(.{ .release = .{ .button = .left, .clicks = 1 } });
        try self.frames(2);
    }

    fn expect(self: *Player, ui: *const Ui, rest: []const u8) Error!void {
        // expect <target> = <value> | focused | missing | exists
        // A line ending in " =" expects an empty value.
        const eq = std.mem.indexOf(u8, rest, " = ") orelse if (std.mem.endsWith(u8, rest, " =")) rest.len - 2 else null;
        if (eq) |i| {
            const want = std.mem.trim(u8, rest[@min(rest.len, i + 3)..], " ");
            const w = try self.target(ui, rest[0..i]) orelse return;
            self.retries = 0;
            const have = w.value orelse "(none)";
            if (!std.mem.eql(u8, have, want)) return self.fail(error.ExpectationFailed, "\"{s}\" is {s}, expected {s}", .{ w.label, have, want });
            return;
        }
        const cut = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse
            return self.fail(error.ScriptSyntax, "expect needs \"= value\", focused, missing or exists", .{});
        const what = rest[cut + 1 ..];
        const name = rest[0..cut];
        if (std.mem.eql(u8, what, "missing")) {
            // Like a lookup, judge a settled layout.
            if (ui.redraw_requested and ui.redraw_in == null and self.retries < max_retries) {
                self.retries += 1;
                try self.push(.{ .frame = self.dt });
                return;
            }
            self.retries = 0;
            if (ui.findWidget(name) != null) return self.fail(error.ExpectationFailed, "\"{s}\" is shown", .{name});
            return;
        }
        const w = try self.target(ui, name) orelse return;
        self.retries = 0;
        if (std.mem.eql(u8, what, "exists")) return;
        if (std.mem.eql(u8, what, "focused")) {
            if (!w.focused) return self.fail(error.ExpectationFailed, "\"{s}\" is not focused", .{name});
            return;
        }
        if (std.mem.eql(u8, what, "enabled")) {
            if (!w.enabled) return self.fail(error.ExpectationFailed, "\"{s}\" is disabled: {s}", .{ name, w.disabled_reason orelse "" });
            return;
        }
        if (std.mem.eql(u8, what, "disabled")) {
            if (w.enabled) return self.fail(error.ExpectationFailed, "\"{s}\" is enabled", .{name});
            return;
        }
        return self.fail(error.ScriptSyntax, "expect what? \"{s}\"", .{what});
    }
};

fn keyNamed(name: []const u8) ?input.Key {
    if (std.meta.stringToEnum(input.Key, name)) |k| return k;
    const aliases = [_]struct { []const u8, input.Key }{
        .{ "esc", .escape },     .{ "return", .enter },  .{ "del", .delete },
        .{ "pageup", .page_up }, .{ "pagedown", .page_down }, .{ "bs", .backspace },
    };
    for (aliases) |a| if (std.mem.eql(u8, a[0], name)) return a[1];
    return null;
}

test "key names and aliases" {
    try std.testing.expectEqual(input.Key.escape, keyNamed("esc").?);
    try std.testing.expectEqual(input.Key.tab, keyNamed("tab").?);
    try std.testing.expectEqual(@as(?input.Key, null), keyNamed("hyper"));
}
