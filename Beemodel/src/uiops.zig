// The UI shell's operators: ops.zig's table takes these as well.
const std = @import("std");
const ops = @import("ops.zig");
const app = @import("app.zig");
const wg = @import("wg.zig");
const welcome = @import("welcome.zig");
const prefpages = @import("prefpages.zig");
const keys = @import("keys.zig");
const of = @import("outfolders.zig");
const Impl = ops.Impl;

fn help() void {
    app.openDialog(.welcome);
}
fn typeHelp() void {
    app.setActiveEditor(.help);
}
fn isHelp() bool {
    return app.activeEditor() == .help;
}
fn typePrefs() void {
    app.setActiveEditor(.prefs);
}
fn isPrefs() bool {
    return app.activeEditor() == .prefs;
}

/// view.ui_scale <75..200>
fn uiScale() void {
    const a = std.mem.trim(u8, ops.arg, " %");
    const v = std.fmt.parseFloat(f32, a) catch return app.log("  view.ui_scale <75..200>", .{});
    prefpages.setScale(@intFromFloat(std.math.clamp(v, 75, 200)));
}

/// prefs.keymap beemodel | blender
fn keymapOp() void {
    const a = std.mem.trim(u8, ops.arg, " ");
    if (std.mem.eql(u8, a, "blender")) {
        keys.usePreset(1);
    } else if (std.mem.eql(u8, a, "beemodel")) {
        keys.usePreset(0);
    } else return app.log("  prefs.keymap beemodel | blender", .{});
    @import("prefs.zig").save();
}

pub const list = .{
    .{ "field.reset", Impl{ .run = wg.opReset, .poll = wg.pollReset } },
    .{ "field.copy", Impl{ .run = wg.opCopy, .poll = wg.pollValue } },
    .{ "field.paste", Impl{ .run = wg.opPaste, .poll = wg.pollValue } },
    .{ "field.insert_key", Impl{ .run = wg.opKey, .poll = wg.pollKey } },
    .{ "field.copy_path", Impl{ .run = wg.opPath, .poll = wg.pollPath } },
    .{ "help.welcome", Impl{ .run = help } },
    .{ "help.template", Impl{ .run = welcome.opTemplate } },
    .{ "view.ui_scale", Impl{ .run = uiScale } },
    .{ "prefs.keymap", Impl{ .run = keymapOp } },
    .{ "area.new_window", Impl{ .run = app.windowActive, .poll = app.pollWindow } },
    .{ "area.type_help", Impl{ .run = typeHelp, .check = isHelp } },
    .{ "area.type_preferences", Impl{ .run = typePrefs, .check = isPrefs } },
    .{ "outliner.folder_new", Impl{ .run = of.opNew, .poll = of.pollObjectMode } },
    .{ "object.move_to_folder", Impl{ .run = of.opMove } },
    .{ "outliner.folder_rename", Impl{ .run = of.opRename, .poll = of.poll } },
    .{ "outliner.folder_delete", Impl{ .run = of.opDelete, .poll = of.poll } },
    .{ "outliner.folder_color", Impl{ .run = of.opColour } },
    .{ "outliner.folder_select", Impl{ .run = of.opSelect, .poll = of.poll } },
    .{ "outliner.tidy", Impl{ .run = of.opTidy } },
    .{ "outliner.tidy_ai", Impl{ .run = of.opTidyAi } },
};
