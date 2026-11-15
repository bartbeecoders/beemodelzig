//! Regression tests for Docs/improvements.html: one test (or more) per item
//! fixed, named by its id, so the list and the tests can be checked
//! against each other.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

/// A Ui with a font, driving an app type with `fn frame(app, ui)`.
fn Fixture(comptime App: type) type {
    return struct {
        const F = @This();
        font: zui.Font,
        ui: zui.Ui,
        app: App = .{},

        fn create() !*F {
            const f = try testing.allocator.create(F);
            f.* = .{ .font = try .initDefault(testing.allocator), .ui = undefined };
            f.ui = .init(testing.allocator, .{ .font = &f.font });
            return f;
        }

        fn destroy(f: *F) void {
            f.ui.deinit();
            f.font.deinit();
            testing.allocator.destroy(f);
        }

        fn frame(f: *F) !void {
            f.ui.beginFrame(.{ .width = 700, .height = 600, .dt = 0.016 });
            f.app.frame(&f.ui);
            _ = try f.ui.endFrame();
        }

        fn frames(f: *F, n: usize) !void {
            for (0..n) |_| try f.frame();
        }

        fn play(f: *F, script: []const u8) !void {
            var player: zui.ScriptPlayer = try .init(testing.allocator, script);
            defer player.deinit();
            while (player.next(&f.ui) catch |err| {
                std.debug.print("{s}\n", .{player.message()});
                return err;
            }) |step| switch (step) {
                .frame => try f.frame(),
                .shot => {},
            };
        }

        /// The rect of the widget recorded as `label` last frame.
        fn rectOf(f: *F, label: []const u8) !zui.Rect {
            const w = f.ui.findWidget(label) orelse return error.NoSuchWidget;
            return w.rect;
        }

        fn click(f: *F, label: []const u8) !void {
            const r = try f.rectOf(label);
            f.ui.input.onMouseMove(.{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 });
            f.ui.input.onMouseButton(.left, true);
            f.ui.input.onMouseButton(.left, false);
            try f.frame();
        }
    };
}

// ---- C1, B6: number fields -------------------------------------------------------

const Numbers = struct {
    big: i64 = 5,
    ubig: u64 = 5,
    small: f32 = 1.2345e-7,
    third: f64 = 1.0 / 3.0,
    committed: u32 = 0,

    fn frame(app: *Numbers, ui: *zui.Ui) void {
        ui.recording = true;
        _ = ui.numberField("Big", &app.big, .{});
        _ = ui.numberField("Unsigned", &app.ubig, .{});
        if (ui.numberField("Small", &app.small, .{}).committed) app.committed += 1;
        if (ui.numberField("Third", &app.third, .{}).committed) app.committed += 1;
    }
};

test "C1: a 64-bit field takes a typed value too big for it, and stops at its limit" {
    const f = try Fixture(Numbers).create();
    defer f.destroy();
    try f.play(
        \\click number:Big
        \\type 1e30
        \\key enter
        \\click number:Unsigned
        \\type 1e30
        \\key enter
    );
    try testing.expectEqual(std.math.maxInt(i64), f.app.big);
    try testing.expectEqual(std.math.maxInt(u64), f.app.ubig);
    try f.play(
        \\click number:Big
        \\type -1e30
        \\key enter
        \\click number:Unsigned
        \\type -5
        \\key enter
    );
    try testing.expectEqual(std.math.minInt(i64), f.app.big);
    try testing.expectEqual(@as(u64, 0), f.app.ubig);
}

test "B6: Enter in a number field without typing keeps the value exactly, with no undo step" {
    const f = try Fixture(Numbers).create();
    defer f.destroy();
    try f.play(
        \\click number:Small
        \\key enter
        \\click number:Third
        \\key enter
    );
    try testing.expectEqual(@as(f32, 1.2345e-7), f.app.small);
    try testing.expectEqual(@as(f64, 1.0 / 3.0), f.app.third);
    try testing.expectEqual(@as(u32, 0), f.app.committed);
    // Typing still sets it.
    try f.play(
        \\click number:Third
        \\type 0.25
        \\key enter
    );
    try testing.expectEqual(@as(f64, 0.25), f.app.third);
    try testing.expectEqual(@as(u32, 1), f.app.committed);
}

// ---- C2: lists ---------------------------------------------------------------------

test "C2: Shift+click after the list got shorter selects from the click, without a panic" {
    var big: [10]bool = @splat(false);
    var st: zui.ListState = .{};
    st.click(&big, 9, .{});
    var small: [5]bool = @splat(false);
    st.click(&small, 2, .{ .shift = true });
    try testing.expectEqualSlices(bool, &.{ false, false, true, false, false }, &small);
    // fit() (run by beginList and beginTiles) keeps everything inside the rows.
    st.anchor = 9;
    st.cursor = 9;
    st.rename = 7;
    st.fit(5);
    try testing.expectEqual(@as(?usize, null), st.anchor);
    try testing.expectEqual(@as(?usize, 4), st.cursor);
    try testing.expectEqual(@as(?usize, null), st.rename);
    st.fit(0);
    try testing.expectEqual(@as(?usize, null), st.cursor);
}

// ---- B1: windows that closed ---------------------------------------------------------

const Closing = struct {
    show_window: bool = true,
    asking: bool = true,
    clicks: u32 = 0,
    answered: ?usize = null,

    fn frame(app: *Closing, ui: *zui.Ui) void {
        ui.recording = true;
        if (ui.button("Behind", .{}).clicked) app.clicks += 1;
        if (app.show_window) {
            if (ui.beginWindow("W", .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 300, .y = 200 } })) ui.endWindow();
        }
        if (ui.beginDialog("Ask", &app.asking, .{})) {
            defer ui.endDialog();
            if (ui.dialogButtons(&.{ "Yes", "No" }, .{ .default = 0, .cancel = 1 })) |b| {
                app.answered = b;
                app.asking = false;
            }
        }
    }
};

test "B1: a press where a window was, after it stopped being described, still clicks what is there" {
    const f = try Fixture(Closing).create();
    defer f.destroy();
    f.app.asking = false;
    try f.frames(3);
    const r = try f.rectOf("button:Behind");
    f.app.show_window = false;
    // Press and release between two frames, as an app drawing on demand sees them.
    f.ui.input.onMouseMove(.{ .x = r.x + 4, .y = r.y + 4 });
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try f.frames(2);
    try testing.expectEqual(@as(u32, 1), f.app.clicks);
    try testing.expect(!f.ui.dead_press);
}

test "B1: the click right after a dialog was answered isn't lost, and isn't taken twice" {
    const f = try Fixture(Closing).create();
    defer f.destroy();
    f.app.show_window = false;
    try f.frames(3);
    try f.click("Ask > button:Yes");
    try testing.expectEqual(@as(?usize, 0), f.app.answered);
    // The dialog closed in that frame; the next click lands on what's behind.
    try f.click("button:Behind");
    try f.frame();
    try testing.expectEqual(@as(u32, 1), f.app.clicks);
}

// ---- B2, B3: Escape belongs to whatever acts on it first ---------------------------------

const EscapeDialog = struct {
    open: bool = true,
    popup: bool = true,
    amount: f32 = 0.5,
    size: f32 = 1,
    amount_rect: zui.Rect = .{},
    size_rect: zui.Rect = .{},
    name: [16]u8 = undefined,
    name_len: usize = 0,

    fn frame(app: *EscapeDialog, ui: *zui.Ui) void {
        ui.recording = true;
        if (ui.beginDialog("Settings", &app.open, .{})) {
            defer ui.endDialog();
            ui.label("hello", .{});
            if (app.popup) {
                ui.openPopupAt("pop", ui.lastRect());
                app.popup = false;
            }
            if (ui.beginPopup("pop", .{})) {
                ui.label("item", .{});
                ui.endPopup();
            }
            app.amount_rect = ui.slider("Amount", &app.amount, 0, 1, .{}).rect;
            app.size_rect = ui.numberField("Size", &app.size, .{}).rect;
            _ = ui.textInput("Name", &app.name, &app.name_len, .{});
        }
    }
};

test "B2: one Escape closes the popup in a dialog, the next closes the dialog" {
    const f = try Fixture(EscapeDialog).create();
    defer f.destroy();
    try f.frames(4);
    try testing.expectEqual(@as(usize, 1), f.ui.popup_count);
    f.ui.input.onKeyPress(.escape);
    try f.frame();
    try testing.expectEqual(@as(usize, 0), f.ui.popup_count);
    try testing.expect(f.app.open);
    f.ui.input.onKeyPress(.escape);
    try f.frame();
    try testing.expect(!f.app.open);
}

fn dragThenEscape(f: anytype, rect: zui.Rect) !void {
    const in = &f.ui.input;
    in.onMouseMove(.{ .x = rect.x + 20, .y = rect.y + rect.h / 2 });
    try f.frame();
    in.onMouseButton(.left, true);
    try f.frame();
    in.onMouseMove(.{ .x = rect.x + 80, .y = rect.y + rect.h / 2 });
    try f.frame();
    in.onKeyPress(.escape);
    try f.frame();
    in.onMouseButton(.left, false);
    try f.frame();
}

test "B3: Escape during a slider or number drag in a dialog puts the value back and keeps the dialog" {
    const f = try Fixture(EscapeDialog).create();
    defer f.destroy();
    f.app.popup = false;
    try f.frames(3);
    try dragThenEscape(f, f.app.amount_rect);
    try testing.expectEqual(@as(f32, 0.5), f.app.amount);
    try testing.expect(f.app.open);
    try dragThenEscape(f, f.app.size_rect);
    try testing.expectEqual(@as(f32, 1), f.app.size);
    try testing.expect(f.app.open);
}

test "B3: Escape in a dialog's field undoes the typing first, then closes the dialog" {
    const f = try Fixture(EscapeDialog).create();
    defer f.destroy();
    f.app.popup = false;
    try f.frames(3);
    try f.play(
        \\click Settings > text_input:Name
        \\type abc
        \\key escape
    );
    try testing.expectEqual(@as(usize, 0), f.app.name_len);
    try testing.expect(f.app.open);
    try f.play("key escape");
    try testing.expect(!f.app.open);
}

// ---- B4, B5: several mouse edges between two frames --------------------------------------

const TwoButtons = struct {
    b_first: bool = false,
    a: zui.Interaction = .{},
    b: zui.Interaction = .{},

    fn frame(app: *TwoButtons, ui: *zui.Ui) void {
        ui.beginHorizontal(.{});
        if (app.b_first) {
            app.b = ui.button("B", .{});
            app.a = ui.button("A", .{});
        } else {
            app.a = ui.button("A", .{});
            app.b = ui.button("B", .{});
        }
        ui.endHorizontal();
    }
};

test "B4: release on one button and press on another between frames: both are seen" {
    for ([_]bool{ false, true }) |b_first| {
        const f = try Fixture(TwoButtons).create();
        defer f.destroy();
        f.app.b_first = b_first;
        try f.frames(3);
        const in = &f.ui.input;
        in.onMouseMove(.{ .x = f.app.a.rect.x + 3, .y = f.app.a.rect.y + 3 });
        in.onMouseButton(.left, true);
        try f.frame();
        try testing.expect(f.app.a.held);
        in.onMouseButton(.left, false);
        in.onMouseMove(.{ .x = f.app.b.rect.x + 3, .y = f.app.b.rect.y + 3 });
        in.onMouseButton(.left, true);
        try f.frame();
        try testing.expect(f.app.a.clicked);
        try testing.expect(f.app.b.held);
        in.onMouseButton(.left, false);
        try f.frame();
        try testing.expect(f.app.b.clicked);
    }
}

test "B5: press, release, press in one frame keeps the hold; a whole double click still clicks" {
    const f = try Fixture(TwoButtons).create();
    defer f.destroy();
    try f.frames(3);
    const in = &f.ui.input;
    in.onMouseMove(.{ .x = f.app.a.rect.x + 3, .y = f.app.a.rect.y + 3 });
    in.onMouseButton(.left, true);
    in.onMouseButton(.left, false);
    in.onMouseButtonClicks(.left, true, 2);
    try f.frame();
    try testing.expect(f.app.a.held);
    try f.frame();
    try testing.expect(f.app.a.held);
    in.onMouseButton(.left, false);
    try f.frame();
    try testing.expect(f.app.a.clicked);
    // Press, release, press, release between two frames: a click.
    in.onMouseButton(.left, true);
    in.onMouseButton(.left, false);
    in.onMouseButtonClicks(.left, true, 2);
    in.onMouseButton(.left, false);
    try f.frame();
    try testing.expect(f.app.a.clicked);
    try testing.expect(!f.app.a.held);
}

// ---- B7: what fills can get narrower again ----------------------------------------------

const Shrinking = struct {
    long: bool = true,
    open: bool = true,
    fill: zui.Interaction = .{},

    fn frame(app: *Shrinking, ui: *zui.Ui) void {
        ui.recording = true;
        const text = if (app.long) "a long long long long long long long label" else "short";
        ui.beginVertical(.{});
        ui.label(text, .{});
        app.fill = ui.button("Fill", .{ .width = .fill });
        ui.endVertical();
        if (ui.beginDialog("Dlg", &app.open, .{})) {
            defer ui.endDialog();
            // (wider than a dialog's 320-unit minimum)
            ui.label(if (app.long) "a long long long long long long long long long long long long long label" else "short", .{});
            _ = ui.dialogButtons(&.{ "OK", "Cancel" }, .{ .default = 0, .cancel = 1 });
        }
    }
};

test "B7: a fill row and a dialog get narrower when their content does" {
    const f = try Fixture(Shrinking).create();
    defer f.destroy();
    try f.frames(4);
    const wide_fill = f.app.fill.rect.w;
    const wide_dialog = (try f.rectOf("dialog:Dlg")).w;
    f.app.long = false;
    try f.frames(6);
    try testing.expect(f.app.fill.rect.w < wide_fill / 2);
    try testing.expect((try f.rectOf("dialog:Dlg")).w < wide_dialog);
}

// ---- L1: a scroll area with both bars reaches its bottom ----------------------------------

const BothBars = struct {
    rect: zui.Rect = .{},

    fn frame(app: *BothBars, ui: *zui.Ui) void {
        // (narrower than its widest line, so the horizontal bar shows)
        ui.beginScrollArea("sa", .{ .width = .px(300), .height = .px(100), .horizontal = true });
        ui.label("a very very very very very very very very very very very very very very wide line", .{});
        for (0..20) |_| ui.label("row", .{});
        ui.endScrollArea();
        app.rect = ui.lastRect();
    }
};

test "L1: scrolling to the end of an area with a horizontal bar reaches the last row and stays" {
    const f = try Fixture(BothBars).create();
    defer f.destroy();
    try f.frames(3);
    for (0..6) |_| {
        f.ui.input.onMouseMove(.{ .x = 50, .y = 50 });
        f.ui.input.onScroll(.{ .y = -100 });
        try f.frame();
    }
    try f.frames(2);
    var it = f.ui.scroll_states.iterator();
    const s = it.next().?.value_ptr.*;
    const body_h = f.app.rect.h - f.ui.style.scrollbar_width - 4;
    try testing.expectApproxEqAbs(s.content_height - body_h, s.scroll, 0.5);
}

// ---- B8: the dock stays within max_areas ---------------------------------------------------

test "B8: a dock refuses areas past max_areas, every area stays listed, and the layout reads back" {
    const Dock = zui.Dock;
    var d: Dock = .init(0);
    const root: zui.AreaId = d.root;
    // Split and float until the dock is full.
    var made: u32 = 1;
    while (d.split(root, .right, made)) |a| {
        made += 1;
        if (made % 2 == 0) try testing.expect(d.float(a, .{ .x = 0, .y = 0, .w = 100, .h = 100 }));
    }
    try testing.expectEqual(@as(usize, Dock.max_areas), d.areaCount());
    var buf: [Dock.max_areas]zui.AreaId = undefined;
    try testing.expectEqual(@as(usize, Dock.max_areas), d.areas(&buf).len);
    // Docking every floating panel works, and none goes missing.
    while (d.floating_count > 0) {
        const panel = d.floating[0];
        try testing.expect(d.move(panel, root, .left));
        try testing.expect(!d.nodes[panel].floats and d.isArea(panel));
    }
    try testing.expectEqual(@as(usize, Dock.max_areas), d.areas(&buf).len);
    var out: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try d.write(&w);
    const back = try Dock.read(w.buffered());
    try testing.expectEqual(@as(usize, Dock.max_areas), back.areaCount());
}

// ---- C6: the script player and input it can't use -----------------------------------------

const OneButton = struct {
    fn frame(_: *OneButton, ui: *zui.Ui) void {
        _ = ui.button("B", .{});
    }
};

test "C6: a script asking for endless frames fails with a message instead of crashing" {
    const f = try Fixture(OneButton).create();
    defer f.destroy();
    for ([_][]const u8{ "frames inf", "frames nan", "wait 1e9", "frames 1e12" }) |line| {
        var player: zui.ScriptPlayer = try .init(testing.allocator, line);
        defer player.deinit();
        var failed: ?anyerror = null;
        for (0..20) |_| {
            const step = player.next(&f.ui) catch |err| {
                failed = err;
                break;
            };
            if (step == null) break;
            try f.frame();
        }
        try testing.expectEqual(@as(?anyerror, error.ScriptSyntax), failed);
        try testing.expect(std.mem.indexOf(u8, player.message(), "too many frames") != null);
    }
}

test "C6: typing bytes that aren't UTF-8 moves on" {
    const f = try Fixture(OneButton).create();
    defer f.destroy();
    const run: [60]u8 = @splat(0x80);
    try f.play("type " ++ run);
}

// ---- B12: the glyph cache stays within its budget ------------------------------------------

test "B12: zooming text through many sizes keeps the glyph cache within its budget" {
    var font: zui.Font = try .initDefault(testing.allocator);
    defer font.deinit();
    font.cache_limit = 256 << 10;
    var size: f32 = 8;
    var peak: usize = 0;
    while (size < 120) : (size += 0.05) {
        for ("Zoomed text: 0123") |c| {
            for (0..4) |sub| {
                const g = try font.glyph(c, size, @intCast(sub));
                _ = g;
            }
        }
        peak = @max(peak, font.cache_bytes);
    }
    // Over the budget by at most one glyph before it starts over.
    try testing.expect(peak < font.cache_limit + 64 << 10);
    // Big sizes share bitmaps: 100.3 and 100.4 px are one entry, any subpixel.
    font.clearCache();
    _ = try font.glyph('W', 100.3, 1);
    _ = try font.glyph('W', 100.4, 3);
    try testing.expectEqual(@as(u32, 1), font.cache.count());
    // A size that isn't a number draws something small instead of panicking.
    _ = try font.glyph('W', std.math.nan(f32), 0);
}

test "B13: every font has its own id, for renderers' glyph caches" {
    var a: zui.Font = try .initDefault(testing.allocator);
    defer a.deinit();
    var b: zui.Font = try .initDefault(testing.allocator);
    defer b.deinit();
    try testing.expect(a.id != 0 and b.id != 0 and a.id != b.id);
}

// ---- P10: the command palette describes only the rows in view ------------------------------

const ManyCommands = struct {
    open: bool = true,
    picked: ?usize = null,
    commands: [2000]zui.PaletteCommand = undefined,
    names: [2000][16]u8 = undefined,

    fn fill(app: *ManyCommands) void {
        for (&app.commands, &app.names, 0..) |*c, *n, i| {
            c.* = .{ .label = std.fmt.bufPrint(n, "Command {d}", .{i}) catch unreachable };
        }
    }

    fn frame(app: *ManyCommands, ui: *zui.Ui) void {
        ui.recording = true;
        if (ui.commandPalette("palette", &app.open, &app.commands, .{})) |i| app.picked = i;
    }
};

test "P10: a palette of 2000 commands describes a screenful; the arrows keep the pick in view" {
    const f = try Fixture(ManyCommands).create();
    defer f.destroy();
    f.app.fill();
    try f.frames(3);
    var shown: usize = 0;
    for (f.ui.widgets()) |w| shown += @intFromBool(w.kind == .command);
    try testing.expect(shown > 0 and shown <= 14);
    for (0..300) |_| {
        f.ui.input.onKeyPress(.down);
        try f.frame();
    }
    try f.frames(2);
    // The highlighted row is shown (recorded as focused).
    const lit = for (f.ui.widgets()) |w| {
        if (w.kind == .command and w.focused) break w.label;
    } else "";
    try testing.expectEqualStrings("Command 300", lit);
    f.ui.input.onKeyPress(.enter);
    try f.frames(2);
    try testing.expectEqual(@as(?usize, 300), f.app.picked);
}

// ---- P12: popups and dialogs that are gone are freed ---------------------------------------

const OneOffPopups = struct {
    row: usize = 0,
    rows: usize = 200,

    fn frame(app: *OneOffPopups, ui: *zui.Ui) void {
        if (app.row < app.rows) {
            ui.pushIdInt(app.row);
            ui.openPopupAt("ctx", .{ .x = 10, .y = 10 });
            if (ui.beginPopup("ctx", .{})) {
                ui.label("x", .{});
                ui.endPopup();
            }
            ui.popId();
            app.row += 1;
        }
    }
};

test "P12: a context menu per row doesn't leave a window per row behind" {
    const f = try Fixture(OneOffPopups).create();
    defer f.destroy();
    try f.frames(200);
    try testing.expect(f.ui.windows.count() >= 100);
    try f.frames(600);
    try testing.expect(f.ui.windows.count() < 10);
    try testing.expectEqual(f.ui.windows.count(), f.ui.window_order.items.len);
    // A popup that comes back after being freed still works.
    f.app.row = 0;
    f.app.rows = 1;
    try f.frames(3);
}

// ---- low ones: L4-L9, L12, L13 --------------------------------------------------------------

test "L4: text cut to fit a buffer is cut between characters" {
    const f = try Fixture(OneButton).create();
    defer f.destroy();
    // A toast keeps 160 bytes: 159 ASCII and then a two-byte character.
    const long = @as([159]u8, @splat('a')) ++ "\u{e9}tude";
    _ = f.ui.toast(long, .info, .{});
    try f.frame();
    for (f.ui.widgets()) |w| if (w.kind == .toast) try testing.expect(std.unicode.utf8ValidateSlice(w.label));
}

const LongKind = struct {
    const kind = "beemodel.outliner.object.reparent.into-folder";
    source: zui.Rect = .{},
    target: zui.Rect = .{},
    dropped: bool = false,
    hovering: bool = false,

    fn frame(app: *LongKind, ui: *zui.Ui) void {
        ui.recording = true;
        const a = ui.button("Source", .{});
        app.source = a.rect;
        _ = ui.dragSource(a, .{ .kind = kind, .data = 1, .label = "Cube" });
        const b = ui.button("Target", .{});
        app.target = b.rect;
        if (ui.dropZone(b.rect, kind)) |d| {
            app.hovering = true;
            if (d.released) app.dropped = true;
        }
    }
};

test "L5: a drag kind longer than 32 bytes still finds its drop zone" {
    try testing.expect(LongKind.kind.len > 32);
    const f = try Fixture(LongKind).create();
    defer f.destroy();
    try f.frames(2);
    const in = &f.ui.input;
    in.onMouseMove(.{ .x = f.app.source.x + 4, .y = f.app.source.y + 4 });
    in.onMouseButton(.left, true);
    try f.frame();
    for (0..4) |k| {
        in.onMouseMove(.{ .x = f.app.source.x + 4 + @as(f32, @floatFromInt(k)) * 2, .y = f.app.target.y + 4 });
        try f.frame();
    }
    try testing.expect(f.app.hovering);
    in.onMouseButton(.left, false);
    try f.frames(2);
    try testing.expect(f.app.dropped);
}

const Tabs3 = struct {
    sel: usize = 0,
    fn frame(app: *Tabs3, ui: *zui.Ui) void {
        ui.recording = true;
        _ = ui.tabBar("tabs", &app.sel, &.{ .{ .label = "One" }, .{ .label = "Two", .disabled = "Not now" }, .{ .label = "Three" } }, .{});
    }
};

test "L6: arrow keys in a tab bar skip disabled tabs" {
    const f = try Fixture(Tabs3).create();
    defer f.destroy();
    try f.frames(2);
    try f.click("tab:One");
    f.ui.input.onKeyPress(.right);
    try f.frames(2);
    try testing.expectEqual(@as(usize, 2), f.app.sel);
    f.ui.input.onKeyPress(.left);
    try f.frames(2);
    try testing.expectEqual(@as(usize, 0), f.app.sel);
}

test "L12, L13: endless dashes and a hue that isn't a number don't hang or panic" {
    var list: zui.DrawList = .init(testing.allocator);
    defer list.deinit();
    try list.addDashedLine(.{}, .{ .x = 1e9, .y = 0 }, zui.Color.white, 1, 4, 4);
    try list.addDashedLine(.{}, .{ .x = 100, .y = 0 }, zui.Color.white, 1, 4, -10);
    try list.addDashedLine(.{}, .{ .x = std.math.nan(f32), .y = 0 }, zui.Color.white, 1, 4, 4);
    // (100000 dashes at most for the long line, 25 for the one with a negative gap)
    try testing.expect(list.commands.items.len <= 100_000 + 25);
    _ = zui.color.fromHsv(.{ .h = std.math.nan(f32), .s = 1, .v = 1 }, 255);
    _ = zui.color.fromHsv(.{ .h = std.math.inf(f32), .s = 1, .v = 1 }, 255);
}

test "L8: a selection in a full log stays on its text as old lines go" {
    var log: zui.LogBuffer = try .init(testing.allocator, 16, 4096);
    defer log.deinit();
    for (0..16) |i| log.print(null, "line {d}", .{i});
    var st: zui.TextViewState = .{};
    const F = Fixture(struct {
        fn frame(_: *@This(), _: *zui.Ui) void {}
    });
    const f = try F.create();
    defer f.destroy();
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    _ = f.ui.textView("log", &log, &st, .{});
    _ = try f.ui.endFrame();
    st.anchor = .{ .line = 10, .byte = 0 };
    st.caret = .{ .line = 12, .byte = 4 };
    // Three more lines push the three oldest out.
    for (16..19) |i| log.print(null, "line {d}", .{i});
    f.ui.beginFrame(.{ .width = 400, .height = 300 });
    _ = f.ui.textView("log", &log, &st, .{});
    _ = try f.ui.endFrame();
    try testing.expectEqualStrings("line 10", log.line(st.anchor.?.line).text);
    try testing.expectEqualStrings("line 12", log.line(st.caret.line).text);
}

// ---- L2: a window made while a dialog is open stays behind it -------------------------------

const LateWindow = struct {
    asking: bool = true,
    window: bool = false,
    behind: u32 = 0,

    fn frame(app: *LateWindow, ui: *zui.Ui) void {
        ui.recording = true;
        if (ui.beginDialog("Ask", &app.asking, .{})) {
            defer ui.endDialog();
            ui.label("a dialog over everything", .{});
        }
        if (app.window) {
            if (ui.beginWindow("Late", .{ .position = .{ .x = 0, .y = 0 }, .size = .{ .x = 700, .y = 600 } })) {
                if (ui.button("Behind", .{}).clicked) app.behind += 1;
                ui.endWindow();
            }
        }
    }
};

test "L2: a window made while a modal dialog is open can't be clicked past the dialog" {
    const f = try Fixture(LateWindow).create();
    defer f.destroy();
    try f.frames(3);
    f.app.window = true;
    try f.frames(2);
    const r = try f.rectOf("Late > button:Behind");
    f.ui.input.onMouseMove(.{ .x = r.x + 3, .y = r.y + 3 });
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try f.frames(2);
    try testing.expectEqual(@as(u32, 0), f.app.behind);
}

// ---- A1, A2, A5, A10: embedding helpers ----------------------------------------------------

const Embedded = struct {
    asking: bool = false,
    panel: zui.Rect = .{ .x = 400, .y = 300, .w = 200, .h = 100 },
    taken: ?zui.Vec2 = null,

    fn frame(app: *Embedded, ui: *zui.Ui) void {
        ui.recording = true;
        _ = ui.button("Root", .{});
        ui.beginAt("panel", app.panel);
        _ = ui.button("In the panel", .{});
        ui.endAt();
        if (ui.takeScroll(.{ .x = 0, .y = 500, .w = 100, .h = 100 })) |s| app.taken = s;
        if (ui.beginDialog("Ask", &app.asking, .{})) {
            defer ui.endDialog();
            ui.label("?", .{});
        }
    }
};

test "A1, A5: wantsPointer is true over Zui's widgets, nowhere else, everywhere under a dialog" {
    const f = try Fixture(Embedded).create();
    defer f.destroy();
    try f.frames(2);
    const b = try f.rectOf("button:In the panel");
    try testing.expect(b.x >= 400 and b.y >= 300);
    f.ui.input.onMouseMove(.{ .x = b.x + 3, .y = b.y + 3 });
    try f.frame();
    try testing.expect(f.ui.wantsPointer());
    f.ui.input.onMouseMove(.{ .x = 690, .y = 590 });
    try f.frame();
    try testing.expect(!f.ui.wantsPointer());
    f.app.asking = true;
    try f.frames(3);
    try testing.expect(f.ui.wantsPointer());
}

test "A2: layoutSettling is true while a dialog sizes itself, then false" {
    const f = try Fixture(Embedded).create();
    defer f.destroy();
    try f.frames(3);
    try testing.expect(!f.ui.layoutSettling());
    f.app.asking = true;
    try f.frame();
    try testing.expect(f.ui.layoutSettling());
    var n: usize = 0;
    while (f.ui.layoutSettling() and n < 5) : (n += 1) try f.frame();
    try testing.expect(!f.ui.layoutSettling());
    try testing.expect(f.ui.findWidget("dialog:Ask") != null);
}

test "A10: takeScroll gets the wheel over its rect, and only there" {
    const f = try Fixture(Embedded).create();
    defer f.destroy();
    try f.frames(2);
    f.ui.input.onMouseMove(.{ .x = 50, .y = 550 });
    f.ui.input.onScroll(.{ .y = 2 });
    try f.frame();
    try testing.expectEqual(@as(f32, 2), f.app.taken.?.y);
    f.app.taken = null;
    f.ui.input.onMouseMove(.{ .x = 650, .y = 550 });
    f.ui.input.onScroll(.{ .y = 2 });
    try f.frame();
    try testing.expect(f.app.taken == null);
}

// ---- A6, A11: button variants, dialogs that close on a click outside ------------------------

const Variants = struct {
    showing: bool = true,

    fn frame(app: *Variants, ui: *zui.Ui) void {
        ui.recording = true;
        _ = ui.button("Plain", .{});
        _ = ui.button("Main", .{ .variant = .primary });
        _ = ui.button("Flat", .{ .variant = .flat });
        if (ui.beginDialog("Info", &app.showing, .{ .close_on_outside = true })) {
            defer ui.endDialog();
            ui.label("Click anywhere else to close", .{});
        }
    }
};

test "A11: a dialog with close_on_outside closes on a click outside it, not inside" {
    const f = try Fixture(Variants).create();
    defer f.destroy();
    try f.frames(3);
    const r = try f.rectOf("dialog:Info");
    f.ui.input.onMouseMove(.{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 });
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try f.frames(2);
    try testing.expect(f.app.showing);
    f.ui.input.onMouseMove(.{ .x = 5, .y = 590 });
    f.ui.input.onMouseButton(.left, true);
    f.ui.input.onMouseButton(.left, false);
    try f.frames(2);
    try testing.expect(!f.app.showing);
    try testing.expect(f.ui.findWidget("button:Main") != null);
}

// ---- wantsKeyboard while a number field is typed into ------------------------------------

const NumberTyping = struct {
    v: f64 = 1,

    fn frame(app: *NumberTyping, ui: *zui.Ui) void {
        ui.recording = true;
        _ = ui.numberField("Value", &app.v, .{ .width = .px(120) });
    }
};

test "wantsKeyboard: a number field being typed into takes the keys" {
    const f = try Fixture(NumberTyping).create();
    defer f.destroy();
    try f.frames(2);
    try testing.expect(!f.ui.wantsKeyboard());
    const w = f.ui.findWidget("number:Value") orelse return error.NoField;
    const c: zui.Vec2 = .{ .x = w.rect.x + w.rect.w / 2, .y = w.rect.y + w.rect.h / 2 };
    f.ui.input.onMouseMove(c);
    f.ui.input.onMouseButton(.left, true);
    try f.frame();
    f.ui.input.onMouseButton(.left, false);
    try f.frames(2);
    // a click without a drag: typing a value
    try testing.expect(f.ui.number_state.editing);
    try testing.expect(f.ui.wantsKeyboard());
}

// ---- copy_all: Ctrl+C with nothing selected copies the whole text -------------------------

const CopyAll = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,

    fn frame(app: *CopyAll, ui: *zui.Ui) void {
        ui.recording = true;
        _ = ui.textInput("Name", &app.buf, &app.len, .{ .width = .px(160), .copy_all = true });
    }
};

test "copy_all: Ctrl+C with nothing selected copies the whole text" {
    const f = try Fixture(CopyAll).create();
    defer f.destroy();
    @memcpy(f.app.buf[0..4], "Cube");
    f.app.len = 4;
    try f.frames(2);
    const w = f.ui.findWidget("text_input:Name") orelse f.ui.findWidget("Name") orelse return error.NoField;
    f.ui.input.onMouseMove(.{ .x = w.rect.x + 5, .y = w.rect.y + w.rect.h / 2 });
    f.ui.input.onMouseButton(.left, true);
    try f.frame();
    f.ui.input.onMouseButton(.left, false);
    try f.frame();
    f.ui.input.onKeyPress(.end);
    try f.frame();
    f.ui.input.modifiers = .{ .ctrl = true };
    f.ui.input.onKeyPress(.c);
    try f.frame();
    try testing.expectEqualStrings("Cube", f.ui.getClipboard());
}
