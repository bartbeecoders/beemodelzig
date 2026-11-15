//! The reloadable part: the UI description, built as a shared library.
//!
//! With the host running (`./run.sh 12_hot_reload`), edit this file and run
//! `zig build hot-app` in another terminal. The host picks up the new library
//! within half a second. Windows stay where you left them, open nodes stay
//! open, and the values below keep their state.

const zui = @import("zui");
const State = @import("state.zig").State;

export fn hotFrame(ui: *zui.Ui, state: *State) callconv(.c) void {
    const muted: zui.LabelOptions = .{ .color = ui.style.colors.text_muted };
    ui.label("Hot reload", .{});
    ui.labelf("Library loaded {d} times. Edit app.zig, then run: zig build hot-app", .{state.reloads + 1}, muted);
    ui.separator();

    ui.beginHorizontal(.{});
    if (ui.button("Count up", .{}).clicked) state.count += 1;
    ui.labelf("count = {d}", .{state.count}, .{});
    ui.endHorizontal();
    _ = ui.slider("Speed", &state.speed, 0, 1, .{});
    _ = ui.checkbox("Enabled", &state.enabled, .{});
    _ = ui.textInput("Note", &state.note_buffer, &state.note_len, .{ .hint = "Survives reloads" });

    if (ui.collapsingHeader("Move the window, open this, then reload", .{})) {
        ui.label("Open headers and tree nodes are restored after a reload.", muted);
    }
    _ = ui.checkbox("Show window", &state.show_window, .{});

    if (ui.beginWindow("Persistent window", .{ .position = .{ .x = 380, .y = 220 }, .open = &state.show_window })) {
        defer ui.endWindow();
        ui.label("Drag or resize me.", .{});
        ui.label("My position survives the reload.", muted);
    }
}
