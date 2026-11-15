//! The widget record: a list of every widget on screen, for tests, scripts
//! and AI agents, like BeeModel's `--dump-ui` and its MCP `ui_tree` tool.
//!
//! Off by default and free when off. Turn it on with `ui.recording = true`;
//! after `endFrame`, `ui.widgets()` lists what the frame showed:
//!
//!     for (ui.widgets()) |w| std.debug.print("{s} {s}\n", .{ @tagName(w.kind), w.label });
//!
//! Custom widgets join with `ui.recordWidget`.

const std = @import("std");
const draw = @import("draw.zig");
const ui_mod = @import("ui.zig");
const window = @import("window.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;
const Allocator = std.mem.Allocator;

/// What sort of widget a record is. Scripts name them as `kind:label`.
pub const Kind = enum {
    label,
    button,
    checkbox,
    slider,
    /// A number field; the value includes its suffix.
    number,
    text_input,
    /// A drop-down list; the value is the chosen item.
    dropdown,
    /// An item of an open drop-down list.
    choice,
    /// One button of a segmented control.
    segment,
    /// An icon that switches something on and off.
    toggle,
    /// A menu title in a menu bar, or an item that opens a submenu.
    menu,
    /// An item of a menu; the value is "true" / "false" if it has a check.
    menu_item,
    /// A row of the command palette.
    command,
    /// A shortcut field; the value is the shortcut as shown.
    shortcut,
    /// A dock area; the label is its editor, the value "active" for the
    /// active one.
    area,
    /// A tab of a tab bar.
    tab,
    /// A modal dialog; the label is its title.
    dialog,
    /// A key hint in a status bar; the value is the keys.
    key_hint,
    /// A toast message.
    toast,
    /// A progress bar; the value is the percentage, or "busy".
    progress,
    /// A job chip; the value is its text.
    job,
    /// A card.
    card,
    /// A row of a list or tree; the value is "true" when selected.
    row,
    /// A list or tile grid.
    list,
    /// A tile of a tile grid; the value is "true" when selected.
    tile,
    /// The label of something being dragged.
    drag,
    /// A text view (a log); the value is its line count.
    text_view,
    /// A line shown in a text view.
    text_line,
    /// A multi-line text field; the value is its text.
    text_area,
    color_edit,
    /// A colour swatch; the label is its hex code (or Old / New in a
    /// picker), the value the row it is in.
    swatch,
    /// A picker's saturation and value square, hue or alpha strip.
    color_area,
    /// A theme in a theme list; the value is "true" when chosen.
    theme,
    /// An open pie menu or wheel; the label is its name.
    pie,
    /// A 2D view; the value is its zoom.
    view,
    /// The current frame on a view's ruler; the value is the frame.
    playhead,
    /// A point dragged in a 2D view: a key, a curve handle, a range edge;
    /// the value is its position.
    handle,
    /// A view's minimap.
    minimap,
    /// A node of a node editor; the label is its title, the value
    /// "selected" when it is.
    node,
    /// A pin of a node, labelled `Node.Pin`; the value is "input" or
    /// "output".
    pin,
    /// A wire between two pins, labelled `From -> To`, at its middle.
    link,
    /// A comment frame of a node editor; the label is its title.
    node_frame,
    /// A choice of a pie or an entry of the wheel; the value says why it
    /// is greyed, or "open" for a wheel entry whose arc is open.
    pie_item,
    selectable,
    tree_node,
    header,
    table_header,
    /// A window's title bar; the label is the title.
    window,
    /// The close or collapse button of a window, labelled "Close" or
    /// "Collapse".
    window_button,
    popup,
    tooltip,
    canvas,
    icon,
    scroll_area,
    /// For widgets an app defines itself.
    custom,
};

/// One widget as the frame showed it. Strings stay valid until the next
/// `beginFrame`.
pub const Widget = struct {
    id: Id,
    kind: Kind,
    /// The visible label, without any `##` suffix. A widget with no visible
    /// text is known by what follows `##`: `"##notes"` is `notes`.
    label: []const u8,
    /// The current value as text: a number, "true" / "false", a hex color,
    /// the text of a field, "open" / "closed". Null if it has none.
    value: ?[]const u8 = null,
    /// The visible part, in logical units.
    rect: Rect,
    enabled: bool = true,
    /// Why it is disabled, from `Ui.pushDisabled`.
    disabled_reason: ?[]const u8 = null,
    focused: bool = false,
    hovered: bool = false,
    tooltip: ?[]const u8 = null,
    /// The title of the window or popup it is in; null at the root.
    window: ?[]const u8 = null,
    /// Stacking order: 0 for the root, higher is in front.
    layer: u32 = 0,
};

/// Optional details for `Ui.recordWidget`.
pub const Details = struct {
    /// Formatted only when recording; see `Ui.recordWidgetf`.
    value: ?[]const u8 = null,
    focused: bool = false,
    hovered: bool = false,
    enabled: bool = true,
};

/// The widget under the pointer, as of the last frame. Available even when
/// recording is off.
pub const Hovered = struct {
    id: Id,
    kind: Kind,
    rect: Rect,
};

const Span = struct { start: u32, len: u32 };

const Entry = struct {
    id: Id,
    kind: Kind,
    label: Span,
    value: ?Span,
    tooltip: ?Span = null,
    reason: ?Span = null,
    rect: Rect,
    enabled: bool,
    focused: bool,
    hovered: bool,
    state: ?*window.State,
    /// Index of the window or popup entry this one is in.
    parent: ?u32,
};

/// Recording state kept in the `Ui`.
pub const Recorder = struct {
    entries: std.ArrayList(Entry) = .empty,
    text: std.ArrayList(u8) = .empty,
    /// The finished list of the last frame.
    list: std.ArrayList(Widget) = .empty,
    /// The window or popup entry being described.
    parent: ?u32 = null,
    hovered: ?Hovered = null,
    hovered_next: ?Hovered = null,

    /// Frees the buffers.
    pub fn deinit(self: *Recorder, allocator: Allocator) void {
        self.entries.deinit(allocator);
        self.text.deinit(allocator);
        self.list.deinit(allocator);
    }
};

/// Called by `beginFrame`.
pub fn beginFrame(ui: *Ui) void {
    const r = &ui.record;
    r.entries.clearRetainingCapacity();
    r.text.clearRetainingCapacity();
    r.list.clearRetainingCapacity();
    r.parent = null;
    r.hovered_next = null;
}

fn span(ui: *Ui, s: []const u8) Allocator.Error!Span {
    const start: u32 = @intCast(ui.record.text.items.len);
    try ui.record.text.appendSlice(ui.allocator, s);
    return .{ .start = start, .len = @intCast(s.len) };
}

/// Records a widget. `rect` is clipped to what is visible; a widget that is
/// entirely clipped away is not recorded.
pub fn recordWidget(ui: *Ui, kind: Kind, widget: Id, label: []const u8, rect: Rect, details: Details) void {
    const visible = rect.intersect(ui.clipRect());
    if (visible.isEmpty()) return;
    if (details.hovered) ui.record.hovered_next = .{ .id = widget, .kind = kind, .rect = visible };
    if (!ui.recording) return;
    addEntry(ui, kind, widget, label, visible, details) catch |err| ui.fail(err);
}

fn addEntry(ui: *Ui, kind: Kind, widget: Id, label: []const u8, visible: Rect, details: Details) Allocator.Error!void {
    const r = &ui.record;
    const text_len = r.text.items.len;
    errdefer r.text.shrinkRetainingCapacity(text_len);
    // A widget with no visible text is known by its ID: "##notes" is "notes".
    const visible_label = Ui.visibleLabel(label);
    const name = if (visible_label.len > 0) visible_label else if (std.mem.indexOf(u8, label, "##")) |i| label[i + 2 ..] else label;
    const label_span = try span(ui, name);
    const value_span = if (details.value) |v| try span(ui, v) else null;
    const why = ui.disabledReason();
    const reason_span = if (why) |w| try span(ui, w) else null;
    try r.entries.append(ui.allocator, .{
        .id = widget,
        .kind = kind,
        .label = label_span,
        .value = value_span,
        .reason = reason_span,
        .rect = visible,
        .enabled = details.enabled and why == null,
        .focused = details.focused,
        .hovered = details.hovered,
        .state = ui.current_window,
        .parent = r.parent,
    });
}

/// Records something drawn above everything, outside any window: a
/// tooltip.
pub fn recordOverlay(ui: *Ui, kind: Kind, widget: Id, label: []const u8, rect: Rect) void {
    if (!ui.recording) return;
    const saved = ui.record.parent;
    const saved_window = ui.current_window;
    defer {
        ui.record.parent = saved;
        ui.current_window = saved_window;
    }
    ui.record.parent = null;
    ui.current_window = null;
    addEntry(ui, kind, widget, label, rect, .{}) catch |err| ui.fail(err);
}

/// Like `recordWidget`, formatting the value only when recording.
pub fn recordWidgetf(ui: *Ui, kind: Kind, widget: Id, label: []const u8, rect: Rect, details: Details, comptime fmt: []const u8, args: anytype) void {
    if (!ui.recording) return recordWidget(ui, kind, widget, label, rect, details);
    var buffer: [128]u8 = undefined;
    var d = details;
    d.value = std.fmt.bufPrint(&buffer, fmt, args) catch buffer[0..];
    recordWidget(ui, kind, widget, label, rect, d);
}

/// Records a window or popup and makes it the parent of what follows,
/// until `leaveContainer`. Returns the previous parent to restore.
pub fn enterContainer(ui: *Ui, kind: Kind, widget: Id, title: []const u8, rect: Rect, details: Details) ?u32 {
    const saved = ui.record.parent;
    if (!ui.recording) return saved;
    // Containers are recorded even when clipped, so their children have a
    // parent; finish() drops them if nothing of them shows.
    addEntry(ui, kind, widget, title, rect.intersect(.{ .w = ui.width, .h = ui.height }), details) catch |err| {
        ui.fail(err);
        return saved;
    };
    ui.record.parent = @intCast(ui.record.entries.items.len - 1);
    return saved;
}

/// Goes back to the parent `enterContainer` returned.
pub fn leaveContainer(ui: *Ui, saved: ?u32) void {
    ui.record.parent = saved;
}

/// Gives the most recent widget at `rect` a tooltip, so the record has it
/// even while the tooltip isn't showing.
pub fn attachTooltip(ui: *Ui, rect: Rect, text: []const u8) void {
    if (!ui.recording) return;
    const entries = ui.record.entries.items;
    var i = entries.len;
    var looked: usize = 0;
    while (i > 0 and looked < 8) : (looked += 1) {
        i -= 1;
        const e = &entries[i];
        if (!sameRect(e.rect, rect.intersect(ui.clipRect()))) continue;
        e.tooltip = span(ui, text) catch |err| return ui.fail(err);
        return;
    }
}

fn sameRect(a: Rect, b: Rect) bool {
    return @abs(a.x - b.x) < 0.01 and @abs(a.y - b.y) < 0.01 and @abs(a.w - b.w) < 0.01 and @abs(a.h - b.h) < 0.01;
}

/// The stacking layer of a window: root 0, then windows back to front, then
/// popups, then tooltips.
fn layerOf(ui: *const Ui, state: ?*window.State, kind: Kind) u32 {
    if (kind == .tooltip) return std.math.maxInt(u32);
    const w = state orelse return 0;
    var layer: u32 = 1;
    for ([_]bool{ false, true }) |popups| {
        for (ui.window_order.items) |o| {
            if (o.popup != popups) continue;
            if (o == w) return layer;
            layer += 1;
        }
    }
    return 0;
}

fn shown(ui: *const Ui, state: ?*window.State) bool {
    const w = state orelse return true;
    return w.last_frame == ui.frame_index and !w.hidden;
}

/// Called by `endFrame`: drops what wasn't shown and builds the list.
pub fn endFrame(ui: *Ui) void {
    const r = &ui.record;
    r.hovered = r.hovered_next;
    if (!ui.recording) return;
    finish(ui) catch |err| ui.fail(err);
}

fn finish(ui: *Ui) Allocator.Error!void {
    const r = &ui.record;
    const text = r.text.items;
    const get = struct {
        fn f(t: []const u8, s: Span) []const u8 {
            return t[s.start..][0..s.len];
        }
    }.f;
    try r.list.ensureTotalCapacity(ui.allocator, r.entries.items.len);
    for (r.entries.items) |e| {
        if (!shown(ui, e.state) or e.rect.isEmpty()) continue;
        r.list.appendAssumeCapacity(.{
            .id = e.id,
            .kind = e.kind,
            .label = get(text, e.label),
            .value = if (e.value) |v| get(text, v) else null,
            .rect = e.rect,
            .enabled = e.enabled,
            .disabled_reason = if (e.reason) |s| get(text, s) else null,
            .focused = e.focused,
            .hovered = e.hovered,
            .tooltip = if (e.tooltip) |t| get(text, t) else null,
            .window = if (e.parent) |p| get(text, r.entries.items[p].label) else null,
            .layer = layerOf(ui, e.state, e.kind),
        });
    }
}

/// Finds a widget by `target`, as scripts name them: `label`, or
/// `kind:label`, optionally after `Window > ` to look inside one window
/// or popup. The first match in drawing order wins.
pub fn find(widgets: []const Widget, target: []const u8) ?Widget {
    var rest = std.mem.trim(u8, target, " ");
    var in_window: ?[]const u8 = null;
    if (std.mem.indexOf(u8, rest, " > ")) |i| {
        in_window = std.mem.trim(u8, rest[0..i], " ");
        rest = std.mem.trim(u8, rest[i + 3 ..], " ");
    }
    var kind: ?Kind = null;
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        if (std.meta.stringToEnum(Kind, rest[0..i])) |k| {
            kind = k;
            rest = rest[i + 1 ..];
        }
    }
    for (widgets) |w| {
        if (kind) |k| if (w.kind != k) continue;
        if (in_window) |name| {
            const wn = w.window orelse continue;
            if (!std.mem.eql(u8, wn, name)) continue;
        }
        if (std.mem.eql(u8, w.label, rest)) return w;
    }
    return null;
}

/// A point inside `w` that no window in front of it covers, for clicking it.
/// Prefers the center. Null if it is entirely covered.
pub fn clickPoint(ui: *const Ui, w: Widget) ?Vec2 {
    const fractions = [_]f32{ 0.5, 0.25, 0.75, 0.1, 0.9 };
    for (fractions) |fy| for (fractions) |fx| {
        const p: Vec2 = .{ .x = w.rect.x + w.rect.w * fx, .y = w.rect.y + w.rect.h * fy };
        if (!covered(ui, w, p)) return p;
    };
    return null;
}

fn covered(ui: *const Ui, w: Widget, p: Vec2) bool {
    for (ui.record.list.items) |other| {
        if (other.layer <= w.layer) continue;
        if (other.kind != .window and other.kind != .popup) continue;
        // A window entry is its title bar; its whole rect covers.
        const state = ui.windows.get(other.id) orelse continue;
        if (state.visibleRect().contains(p)) return true;
    }
    return false;
}

/// How `write` formats the list.
pub const Format = enum { json, text };

/// Writes `widgets` as a JSON array of objects, or as one line per widget.
pub fn write(widgets: []const Widget, writer: *std.Io.Writer, format: Format) std.Io.Writer.Error!void {
    switch (format) {
        .json => {
            try writer.writeAll("[");
            for (widgets, 0..) |w, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\n  {{\"kind\": \"{s}\", \"label\": ", .{@tagName(w.kind)});
                try jsonString(writer, w.label);
                if (w.value) |v| {
                    try writer.writeAll(", \"value\": ");
                    try jsonString(writer, v);
                }
                try writer.print(", \"x\": {d:.1}, \"y\": {d:.1}, \"w\": {d:.1}, \"h\": {d:.1}", .{ w.rect.x, w.rect.y, w.rect.w, w.rect.h });
                try writer.print(", \"enabled\": {}, \"focused\": {}, \"hovered\": {}", .{ w.enabled, w.focused, w.hovered });
                if (w.tooltip) |t| {
                    try writer.writeAll(", \"tooltip\": ");
                    try jsonString(writer, t);
                }
                if (w.disabled_reason) |t| {
                    try writer.writeAll(", \"disabled_reason\": ");
                    try jsonString(writer, t);
                }
                if (w.window) |name| {
                    try writer.writeAll(", \"window\": ");
                    try jsonString(writer, name);
                }
                try writer.print(", \"layer\": {d}}}", .{w.layer});
            }
            try writer.writeAll(if (widgets.len > 0) "\n]\n" else "]\n");
        },
        .text => for (widgets) |w| {
            try writer.print("{s}:{s}", .{ @tagName(w.kind), w.label });
            if (w.value) |v| try writer.print(" = {s}", .{v});
            try writer.print("  @ {d:.0},{d:.0} {d:.0}x{d:.0}", .{ w.rect.x, w.rect.y, w.rect.w, w.rect.h });
            if (w.window) |name| try writer.print("  in {s}", .{name});
            if (w.focused) try writer.writeAll("  focused");
            if (!w.enabled) try writer.print("  disabled: {s}", .{w.disabled_reason orelse "yes"});
            if (w.tooltip) |t| try writer.print("  tip: {s}", .{t});
            try writer.writeAll("\n");
        },
    }
}

fn jsonString(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

test "find by label, kind and window" {
    const widgets = [_]Widget{
        .{ .id = @enumFromInt(1), .kind = .label, .label = "OK", .rect = .{} },
        .{ .id = @enumFromInt(2), .kind = .button, .label = "OK", .rect = .{}, .window = "Tools" },
        .{ .id = @enumFromInt(3), .kind = .button, .label = "OK", .rect = .{}, .window = "Other" },
    };
    try std.testing.expectEqual(@as(u64, 1), @intFromEnum(find(&widgets, "OK").?.id));
    try std.testing.expectEqual(@as(u64, 2), @intFromEnum(find(&widgets, "button:OK").?.id));
    try std.testing.expectEqual(@as(u64, 3), @intFromEnum(find(&widgets, "Other > button:OK").?.id));
    try std.testing.expect(find(&widgets, "checkbox:OK") == null);
    // An unknown kind is part of the label.
    try std.testing.expect(find(&widgets, "nope:OK") == null);
}

test "json escapes labels" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    const widgets = [_]Widget{.{ .id = @enumFromInt(1), .kind = .label, .label = "say \"hi\"\n", .rect = .{} }};
    try write(&widgets, &w, .json);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "say \\\"hi\\\"\\n") != null);
}
