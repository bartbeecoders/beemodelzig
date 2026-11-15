//! Phase 20 demo: BeeModel's Console, an AI Assistant style chat, and the
//! Help editor's wrapped text.
//!
//! Try: type "view." and Tab, Enter, Up and Down; "Add 100,000 lines", then
//! scroll; drag over the log and Ctrl+C; double-click a message; write in
//! the prompt (Shift+Enter for a new line, Enter to send).

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

const commands = [_][]const u8{ "view.frame_selected", "view.camera", "view.orthographic", "object.delete", "object.duplicate", "mesh.subdivide", "render.image", "help" };

const App = struct {
    mono: *zui.Font,
    log: zui.LogBuffer,
    chat: zui.LogBuffer,
    log_view: zui.TextViewState = .{},
    chat_view: zui.TextViewState = .{},
    line: [256]u8 = undefined,
    line_len: usize = 0,
    history: zui.History = .{},
    prompt: [1024]u8 = undefined,
    prompt_len: usize = 0,

    fn complete(_: ?*anyopaque, text: []const u8, out: []u8) ?usize {
        if (text.len == 0) return null;
        // The longest prefix all matching commands share.
        var match: ?[]const u8 = null;
        var common: usize = 0;
        for (commands) |c| {
            if (!std.mem.startsWith(u8, c, text)) continue;
            if (match) |m| {
                var n: usize = 0;
                while (n < @min(common, c.len) and m[n] == c[n]) n += 1;
                common = n;
            } else {
                match = c;
                common = c.len;
            }
        }
        const m = match orelse return null;
        @memcpy(out[0..common], m[0..common]);
        return common;
    }

    fn run(app: *App, cmd: []const u8, ui: *zui.Ui) void {
        const colors = ui.style.colors;
        app.log.print(colors.text_muted, "> {s}", .{cmd});
        for (commands) |c| if (std.mem.eql(u8, c, cmd)) {
            if (std.mem.eql(u8, cmd, "help")) {
                app.log.add(null, "Commands:");
                for (commands) |h| app.log.print(null, "  {s}", .{h});
            } else app.log.print(zui.Color.hex(0x3C9A5F), "Done: {s}", .{cmd});
            return;
        };
        app.log.print(colors.warning, "Unknown command \"{s}\". Try help, or Tab to complete.", .{cmd});
    }

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const colors = ui.style.colors;
        ui.beginHorizontal(.{ .height = .fill, .alignment = .start, .spacing = 14 });

        ui.beginVertical(.{ .width = .px(300), .height = .fill });
        ui.label("Help", .{ .color = colors.text_muted });
        ui.richText(&.{
            .{ .text = "Loop Cut and Slide", .color = colors.accent },
            .{ .text = "  " },
            .{ .text = "Ctrl+R", .key = true },
            .{ .text = "\nAdds an edge loop across the faces under the pointer. Turn the wheel for more cuts, then slide the loop and click to place it. " },
            .{ .text = "Esc", .key = true },
            .{ .text = " cancels; the cut stays where it was." },
        }, .{});
        ui.separator();
        ui.wrappedText("Every text in this panel wraps to the width it gets: resize the window and watch the lines change.", .{ .color = colors.text_muted });
        ui.endVertical();

        ui.beginVertical(.{ .width = .fill, .height = .fill });
        ui.beginHorizontal(.{});
        ui.label("Console", .{ .color = colors.text_muted });
        ui.spacer(.fill);
        if (ui.button("Add 100,000 lines", .{}).clicked) {
            for (0..100_000) |i| app.log.print(if (i % 50 == 0) colors.warning else null, "Frame {d}: {d} samples, {d:.2} ms", .{ i, (i * 37) % 4096, @as(f32, @floatFromInt(i % 97)) / 7 });
        }
        if (ui.button("Clear", .{}).clicked) app.log.clear();
        ui.endHorizontal();
        _ = ui.textView("log", &app.log, &app.log_view, .{ .height = .fill, .font = app.mono });
        const c = ui.consoleInput("command", &app.line, &app.line_len, &app.history, .{ .hint = "Type a command; Tab completes", .complete = .{ .complete = complete } });
        if (c.submitted) {
            app.run(app.line[0..app.line_len], ui);
            app.line_len = 0;
        }

        ui.label("AI Assistant", .{ .color = colors.text_muted });
        const chat = ui.textView("chat", &app.chat, &app.chat_view, .{ .height = .px(150) });
        _ = chat;
        ui.beginHorizontal(.{ .alignment = .end });
        const p = ui.textArea("prompt", &app.prompt, &app.prompt_len, .{ .height = .px(64), .enter_sends = true, .hint = "Ask about the scene (Shift+Enter for a new line)" });
        const send = ui.button("Send", .{});
        ui.endHorizontal();
        if ((p.submitted or send.clicked) and app.prompt_len > 0) {
            app.chat.add(colors.accent, "You:");
            app.chat.add(null, app.prompt[0..app.prompt_len]);
            app.chat.add(colors.text_muted, "Assistant:\nThe scene has 3 objects. The chair has four legs, which share one material.");
            app.prompt_len = 0;
        }
        ui.endVertical();
        ui.endHorizontal();
    }
};

pub fn main(init: std.process.Init) !void {
    var mono: zui.Font = try .initMono(init.gpa);
    defer mono.deinit();
    var app: App = .{ .mono = &mono, .log = try .init(init.gpa, 200_000, 16 << 20), .chat = try .init(init.gpa, 2000, 256 << 10) };
    defer app.log.deinit();
    defer app.chat.deinit();
    app.log.add(null, "BeeModel console. Type help.");
    try harness.runUi(init, .{ .title = "Zui 20: console", .width = 1000, .height = 700 }, &app);
}
