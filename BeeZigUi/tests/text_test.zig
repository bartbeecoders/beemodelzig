//! Wrapped text, the log view, the console line and the text area.

const std = @import("std");
const zui = @import("zui");
const testing = std.testing;

const App = struct {
    log: zui.LogBuffer,
    view: zui.TextViewState = .{},
    line: [128]u8 = undefined,
    line_len: usize = 0,
    history: zui.History = .{},
    ran: [128]u8 = undefined,
    ran_len: usize = 0,
    prompt: [512]u8 = undefined,
    prompt_len: usize = 0,
    sent: [512]u8 = undefined,
    sent_len: usize = 0,

    fn frame(app: *App, ui: *zui.Ui) void {
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start });
        ui.beginVertical(.{ .width = .px(260) });
        ui.wrappedText("A paragraph long enough to need more than one line in a narrow column.", .{});
        ui.richText(&.{ .{ .text = "Press " }, .{ .text = "Ctrl+S", .key = true }, .{ .text = " to save." } }, .{});
        const r = ui.textArea("prompt", &app.prompt, &app.prompt_len, .{ .enter_sends = true, .hint = "Ask something" });
        if (r.submitted) {
            @memcpy(app.sent[0..app.prompt_len], app.prompt[0..app.prompt_len]);
            app.sent_len = app.prompt_len;
            app.prompt_len = 0;
        }
        ui.endVertical();
        ui.beginVertical(.{ .width = .fill, .height = .fill });
        _ = ui.textView("log", &app.log, &app.view, .{ .height = .fill });
        const c = ui.consoleInput("command", &app.line, &app.line_len, &app.history, .{ .complete = .{ .complete = complete } });
        if (c.submitted) {
            @memcpy(app.ran[0..app.line_len], app.line[0..app.line_len]);
            app.ran_len = app.line_len;
            app.log.print(null, "> {s}", .{app.line[0..app.line_len]});
            app.line_len = 0;
        }
        ui.endVertical();
        ui.endHorizontal();
    }

    fn complete(_: ?*anyopaque, text: []const u8, out: []u8) ?usize {
        const words = [_][]const u8{ "view.frame_selected", "view.camera", "object.delete" };
        for (words) |w| if (std.mem.startsWith(u8, w, text) and text.len > 0) {
            @memcpy(out[0..w.len], w);
            return w.len;
        };
        return null;
    }
};

const Fixture = struct {
    font: zui.Font,
    ui: zui.Ui,
    app: App,

    fn create(lines: usize) !*Fixture {
        const f = try testing.allocator.create(Fixture);
        f.* = .{ .font = try .initDefault(testing.allocator), .ui = undefined, .app = .{ .log = try .init(testing.allocator, 120_000, 4 << 20) } };
        f.ui = .init(testing.allocator, .{ .font = &f.font });
        for (0..lines) |i| f.app.log.print(null, "line {d}", .{i});
        f.app.log.add(zui.Color.hex(0xE8B04A), "Warning: a block\nof three\nlines");
        return f;
    }

    fn destroy(f: *Fixture) void {
        f.app.log.deinit();
        f.ui.deinit();
        f.font.deinit();
        testing.allocator.destroy(f);
    }

    fn frame(f: *Fixture, dt: f32) !void {
        f.ui.beginFrame(.{ .width = 800, .height = 500, .dt = dt });
        f.app.frame(&f.ui);
        _ = try f.ui.endFrame();
    }

    fn play(f: *Fixture, script: []const u8) !void {
        var player: zui.ScriptPlayer = try .init(testing.allocator, script);
        defer player.deinit();
        while (player.next(&f.ui) catch |err| {
            std.debug.print("{s}\n", .{player.message()});
            return err;
        }) |step| switch (step) {
            .frame => |dt| try f.frame(dt),
            .shot => {},
        };
    }
};

test "wrapped text takes several lines in a narrow column" {
    const f = try Fixture.create(10);
    defer f.destroy();
    try f.play("frames 2");
    const para = f.ui.findWidget("label:A paragraph long enough to need more than one line in a narrow column.").?;
    try testing.expect(para.rect.h > 1.5 * f.ui.textSize("").y);
    try testing.expect(para.rect.w <= 260);
    try testing.expect(f.ui.findWidget("label:Press Ctrl+S to save.") != null);
}

test "100,000 log lines: the view follows the bottom and draws a screenful" {
    const f = try Fixture.create(100_000);
    defer f.destroy();
    try f.play(
        \\expect text_line:lines exists
        \\expect text_line:line 0 missing
    );
    var shown: usize = 0;
    for (f.ui.widgets()) |w| {
        if (w.kind == .text_line) shown += 1;
    }
    try testing.expect(shown < 40);
    // New lines while at the bottom: still at the bottom.
    f.app.log.print(null, "fresh", .{});
    try f.play("expect text_line:fresh exists");
    // Scrolled up, it stays put.
    try f.play("scroll text_view:log 20");
    f.app.log.print(null, "fresher", .{});
    try f.play("expect text_line:fresher missing");
}

test "drag selects across lines; Ctrl+C copies; a double-click takes the block" {
    const f = try Fixture.create(5);
    defer f.destroy();
    try f.play("drag text_line:line 1 to text_line:line 3");
    try f.play("key ctrl+c");
    const copied = f.ui.getClipboard();
    try testing.expect(std.mem.indexOf(u8, copied, "\nline 2\n") != null);
    try f.play(
        \\double-click text_line:of three
        \\key ctrl+c
    );
    try testing.expectEqualStrings("Warning: a block\nof three\nlines", f.ui.getClipboard());
}

test "the console: history, completion, and focus kept after Enter" {
    const f = try Fixture.create(3);
    defer f.destroy();
    try f.play(
        \\click text_input:command
        \\type view.cam
        \\key tab
        \\expect text_input:command = view.camera
        \\key enter
        \\expect text_input:command focused
        \\type object.delete
        \\key enter
        \\type half
        \\key up
        \\expect text_input:command = object.delete
        \\key up
        \\expect text_input:command = view.camera
        \\key down
        \\key down
        \\expect text_input:command = half
        \\expect text_line:> view.camera exists
    );
    try testing.expectEqualStrings("object.delete", f.app.ran[0..f.app.ran_len]);
}

test "the text area: new lines, sending, editing keys" {
    const f = try Fixture.create(3);
    defer f.destroy();
    try f.play(
        \\click text_area:prompt
        \\type hello
        \\key shift+enter
        \\type world
        \\key ctrl+a
        \\key ctrl+x
        \\expect text_area:prompt =
        \\key ctrl+v
        \\key up
        \\key end
        \\type , there
        \\key enter
    );
    try testing.expectEqualStrings("hello, there\nworld", f.app.sent[0..f.app.sent_len]);
}

test "the text area: undo takes a word of typing at a time, redo puts it back" {
    const f = try Fixture.create(3);
    defer f.destroy();
    const a = &f.app;
    try f.play(
        \\click text_area:prompt
        \\type one two
        \\key shift+enter
        \\type three
        \\key ctrl+z
    );
    try testing.expectEqualStrings("one two\n", a.prompt[0..a.prompt_len]);
    try f.play("key ctrl+z");
    try testing.expectEqualStrings("one two", a.prompt[0..a.prompt_len]);
    try f.play("key ctrl+z");
    try testing.expectEqualStrings("one", a.prompt[0..a.prompt_len]);
    try f.play("key ctrl+y");
    try testing.expectEqualStrings("one two", a.prompt[0..a.prompt_len]);
    try f.play("key ctrl+shift+z");
    try testing.expectEqualStrings("one two\n", a.prompt[0..a.prompt_len]);
    try f.play(
        \\key backspace
        \\key backspace
        \\key backspace
    );
    try testing.expectEqualStrings("one t", a.prompt[0..a.prompt_len]);
    try f.play("key ctrl+z");
    try testing.expectEqualStrings("one two\n", a.prompt[0..a.prompt_len]);
    try f.play(
        \\key ctrl+a
        \\key ctrl+x
    );
    try testing.expectEqualStrings("", a.prompt[0..a.prompt_len]);
    try f.play("key ctrl+z");
    try testing.expectEqualStrings("one two\n", a.prompt[0..a.prompt_len]);
}

test "the text area's height for its text grows by lines and stops at the most" {
    const f = try Fixture.create(1);
    defer f.destroy();
    try f.play("frames 1");
    const one = f.ui.textAreaHeight("", 200, 1, 4);
    const two = f.ui.textAreaHeight("a\nb", 200, 1, 4);
    const many = f.ui.textAreaHeight("a\nb\nc\nd\ne\nf", 200, 1, 4);
    const line = f.ui.font.lineMetrics(f.ui.style.font_size).height;
    try testing.expectApproxEqAbs(line, two - one, 0.01);
    try testing.expectApproxEqAbs(3 * line, many - one, 0.01);
    // Long text wraps into more lines at a narrow width.
    const words = "lots of words that will need to wrap at a narrow width";
    try testing.expect(f.ui.textAreaHeight(words, 80, 1, 10) > f.ui.textAreaHeight(words, 600, 1, 10));
}

const Wrapped = struct {
    const lines = [_]zui.TextLine{
        .{ .text = "first part ", .block = 1 },
        .{ .text = "goes on", .block = 1, .soft = true },
        .{ .text = "next", .block = 2 },
    };
    pub fn len(_: *const Wrapped) usize {
        return lines.len;
    }
    pub fn line(_: *const Wrapped, i: usize) zui.TextLine {
        return lines[i];
    }
};

test "a text view's soft lines copy without a line break" {
    var font: zui.Font = try .initDefault(testing.allocator);
    defer font.deinit();
    var ui: zui.Ui = .init(testing.allocator, .{ .font = &font });
    defer ui.deinit();
    var src: Wrapped = .{};
    var st: zui.TextViewState = .{ .anchor = .{}, .caret = .{ .line = 2, .byte = 4 } };
    ui.beginFrame(.{ .width = 400, .height = 300 });
    _ = ui.textView("v", &src, &st, .{});
    _ = try ui.endFrame();
    try testing.expect(zui.copySelection(&ui, &src, &st));
    try testing.expectEqualStrings("first part goes on\nnext", ui.getClipboard());
}

test "the text area: typing in the middle keeps the text after the caret" {
    const f = try Fixture.create(1);
    defer f.destroy();
    try f.play(
        \\click text_area:prompt
        \\type abcdefghij
        \\key home
        \\type x
    );
    try testing.expectEqualStrings("xabcdefghij", f.app.prompt[0..f.app.prompt_len]);
}

test "a focused text area wants the keyboard" {
    const f = try Fixture.create(1);
    defer f.destroy();
    try f.play("click text_area:prompt");
    try testing.expect(f.ui.wantsKeyboard());
    try f.play("key esc");
    try testing.expect(!f.ui.wantsKeyboard());
}

test "a long burst typed between two frames arrives whole" {
    const f = try Fixture.create(1);
    defer f.destroy();
    try f.play("click text_area:prompt");
    const burst = "build a tall tower of stacked cubes with a red roof and a garden around it, then light it like a sunset";
    for (burst) |c| {
        if (c != ' ') f.ui.input.onKeyPress(@enumFromInt(@intFromEnum(zui.Key.a) + (c -| 'a') % 26));
        f.ui.input.onText(&.{c});
    }
    try f.frame(0.016);
    try testing.expectEqualStrings(burst, f.app.prompt[0..f.app.prompt_len]);
}

test "the console keeps the keys between Enter and the next frame" {
    const f = try Fixture.create(1);
    defer f.destroy();
    try f.play(
        \\click text_input:command
        \\type view.camera
    );
    // Enter, one frame: it runs.
    f.ui.input.onKeyPress(.enter);
    try f.frame(0.016);
    try testing.expectEqualStrings("view.camera", f.app.ran[0..f.app.ran_len]);
    // (a host routes the keys that come before Zui's next frame by this)
    try testing.expect(f.ui.wantsKeyboard());
}
