//! Phase 7 demo: single-line text input.

const std = @import("std");
const zui = @import("zui");
const harness = @import("harness");

/// A text buffer with its length, the shape `textInput` edits.
fn Field(comptime capacity: usize) type {
    return struct {
        buffer: [capacity]u8 = undefined,
        len: usize = 0,

        fn init(initial: []const u8) @This() {
            var f: @This() = .{};
            @memcpy(f.buffer[0..initial.len], initial);
            f.len = initial.len;
            return f;
        }

        fn text(f: *const @This()) []const u8 {
            return f.buffer[0..f.len];
        }
    };
}

const App = struct {
    name: Field(64) = .init("Ada Lovelace"),
    city: Field(64) = .init("Zürich"),
    search: Field(64) = .{},
    tiny: Field(8) = .init("8 bytes"),
    narrow: Field(256) = .init("A long line that is much wider than its field, so it scrolls sideways as you move the caret."),
    wide: Field(256) = .{},
    note: Field(128) = .init("Inside a window"),
    submitted: Field(256) = .{},
    edits: u32 = 0,

    pub fn frame(app: *App, ui: *zui.Ui) !void {
        const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };

        ui.label("Click a field and type. Try Ctrl+A/C/X/V, Ctrl+Z/Y, Ctrl+arrows, Shift+arrows,", muted);
        ui.label("double click for a word, triple click for everything. Enter submits.", muted);
        ui.spacer(.px(4));

        app.track(ui.textInput("Name", &app.name.buffer, &app.name.len, .{}), app.name.text());
        app.track(ui.textInput("City", &app.city.buffer, &app.city.len, .{}), app.city.text());
        app.track(ui.textInput("Search", &app.search.buffer, &app.search.len, .{ .hint = "Type to search…" }), app.search.text());
        app.track(ui.textInput("Capacity 8 bytes", &app.tiny.buffer, &app.tiny.len, .{}), app.tiny.text());
        app.track(ui.textInput("Narrow, scrolls", &app.narrow.buffer, &app.narrow.len, .{ .width = .px(260) }), app.narrow.text());

        ui.beginHorizontal(.{});
        app.track(ui.textInput("##wide", &app.wide.buffer, &app.wide.len, .{ .width = .fill, .hint = "A field that fills the row" }), app.wide.text());
        if (ui.button("Clear", .{}).clicked) app.wide.len = 0;
        ui.endHorizontal();

        ui.separator();
        ui.labelf("Last submitted: {s}", .{app.submitted.text()}, .{});
        ui.labelf("Search is {d} of {d} bytes. {d} edits so far.", .{ app.search.len, app.search.buffer.len, app.edits }, muted);
        ui.labelf("Keyboard focus: {s}", .{if (ui.wantsKeyboard()) "a text field" else "none"}, muted);

        if (ui.beginWindow("Notes", .{ .position = .{ .x = 470, .y = 330 }, .size = .{ .x = 300, .y = 140 } })) {
            defer ui.endWindow();
            app.track(ui.textInput("##note", &app.note.buffer, &app.note.len, .{ .width = .fill }), app.note.text());
            ui.labelf("{d} characters", .{std.unicode.utf8CountCodepoints(app.note.text()) catch 0}, muted);
        }
    }

    /// Counts edits, and keeps a copy of whatever was submitted with Enter.
    fn track(app: *App, result: zui.Interaction, text: []const u8) void {
        if (result.changed) app.edits += 1;
        if (result.submitted) app.submitted = .init(text[0..@min(text.len, app.submitted.buffer.len)]);
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try harness.runUi(init, .{ .title = "Zui 07: text input", .width = 800, .height = 500 }, &app);
}
