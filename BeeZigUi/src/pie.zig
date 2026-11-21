//! Menus around the pointer: pies and the radial wheel.
//!
//! A pie has up to eight choices, one per direction. Hold its key, flick
//! towards a choice and let go; or tap the key and click. A quick tap
//! without moving reports `.tapped`, so the key can still do its own job:
//!
//!     if (key_z_pressed) ui.openPie("Shading", .z);
//!     switch (ui.pie("Shading", &.{ .{ .label = "Wireframe" }, .{ .label = "Solid" } }, .{})) {
//!         .chosen => |i| shading = i,
//!         .tapped => toggleXray(),
//!         .none, .cancelled => {},
//!     }
//!
//! The wheel is a ring of coloured entries with icons; entries with
//! children open an outer arc. Click, or press, drag and let go; the number
//! keys 1 to 9, 0 and - pick; Backspace goes back to the ring; Esc, the
//! centre or a click outside closes:
//!
//!     if (canvas.right_pressed) ui.openWheel("Context", .right);
//!     switch (ui.wheel("Context", &entries, .{})) {
//!         .chosen => |c| run(c.item, c.child),
//!         .none, .cancelled => {},
//!     }
//!
//! While one is open it owns the pointer and these keys; nothing behind
//! it reacts.

const std = @import("std");
const draw = @import("draw.zig");
const ui_mod = @import("ui.zig");
const input = @import("input.zig");
const icons = @import("icons.zig");
const record = @import("record.zig");
const color = @import("color.zig");
const Ui = ui_mod.Ui;
const Id = ui_mod.Id;
const Rect = draw.Rect;
const Vec2 = draw.Vec2;
const Color = draw.Color;
const Key = input.Key;
const MouseButton = input.MouseButton;

/// A choice of a pie.
pub const PieItem = struct {
    label: []const u8,
    icon: ?icons.Icon = null,
    /// Why it can't be chosen now; it shows greyed, saying why.
    disabled: ?[]const u8 = null,
    /// What is on now (the shading in use): its name in the accent colour.
    checked: bool = false,
};

/// What a pie did this frame.
pub const PieResult = union(enum) {
    none,
    /// The choice with this index.
    chosen: usize,
    /// The key was tapped, not held: do the key's own action.
    tapped,
    /// Closed without a choice.
    cancelled,
};

/// An entry of the wheel.
pub const WheelItem = struct {
    label: []const u8,
    icon: ?icons.Icon = null,
    /// The entry's colour on the ring; the theme's button colour if null.
    color: ?Color = null,
    /// Why it can't be chosen now; it shows greyed, saying why above the
    /// wheel.
    disabled: ?[]const u8 = null,
    /// Entries of the outer arc this one opens.
    children: []const WheelItem = &.{},
};

/// What was chosen on the wheel: an entry, and the entry of its arc.
pub const WheelChoice = struct {
    item: usize,
    child: ?usize = null,
};

/// What the wheel did this frame.
pub const WheelResult = union(enum) {
    none,
    chosen: WheelChoice,
    cancelled,
};

/// Options for `pie`.
pub const PieOptions = struct {
    /// Shown in the middle.
    title: ?[]const u8 = null,
    /// How far choices sit from the centre.
    radius: f32 = 110,
};

/// Options for `wheel`.
pub const WheelOptions = struct {
    /// The ring's inner and outer radius.
    inner: f32 = 44,
    outer: f32 = 112,
    /// Each entry's name under its icon on the ring (else only the one the
    /// pointer is on, in the middle, or above the wheel if it is too long
    /// for there).
    labels: bool = false,
};

/// Pie and wheel state kept in the `Ui`. One is open at a time.
pub const State = struct {
    kind: enum { none, pie, wheel } = .none,
    id: Id = .none,
    center: Vec2 = .{},
    /// The key that opened a pie, if any.
    key: ?Key = null,
    /// The button held when the wheel opened, for press, drag and release.
    button: ?MouseButton = null,
    /// Seconds open.
    age: f32 = 0,
    /// The pointer left the middle at some point.
    moved: bool = false,
    /// The wheel's open arc.
    group: ?usize = null,
    /// The entry Backspace closed, which hovering doesn't reopen until the
    /// pointer goes to another one.
    closed_group: ?usize = null,
    seen: bool = false,
    // Input taken this frame.
    click: bool = false,
    other_click: bool = false,
    button_up: bool = false,
    key_up: bool = false,
    escape: bool = false,
    backspace: bool = false,
    number: ?usize = null,
};

/// A quick tap is shorter than this, in seconds.
pub const tap_time = 0.25;
/// The middle of a pie, where no choice is highlighted.
const dead_zone = 18;

/// The keys that pick by number, in order: 1 to 9, 0, -.
const number_keys = [_]Key{ .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9", .@"0", .minus };

/// Opens the pie `name` around the pointer. `key` is the key that opened
/// it: letting it go after a hold picks; a tap reports `.tapped`.
pub fn openPie(ui: *Ui, name: []const u8, key: ?Key) void {
    const widget = ui.id(name);
    const st = &ui.pie_state;
    if (st.kind == .pie and st.id == widget) return;
    st.* = .{ .kind = .pie, .id = widget, .center = ui.input.mouse_pos, .key = key };
    ui.requestRedraw();
}

/// Opens the pie `name` around `at`, for a key the app has already seen
/// held (`held`: its release picks, it is no tap). For an app that waits
/// for a hold before showing a pie, so a tap shows nothing.
pub fn openPieAt(ui: *Ui, name: []const u8, key: ?Key, at: Vec2, held: bool) void {
    openPie(ui, name, key);
    const st = &ui.pie_state;
    st.center = at;
    if (held) st.age = tap_time;
}

/// Opens the wheel `name` around `at` (see `openWheel`).
pub fn openWheelAt(ui: *Ui, name: []const u8, button: ?MouseButton, at: Vec2) void {
    openWheel(ui, name, button);
    ui.pie_state.center = at;
}

/// Opens the wheel `name` around the pointer. `button` is the button held
/// down to open it, if any: letting it go over an entry picks it.
pub fn openWheel(ui: *Ui, name: []const u8, button: ?MouseButton) void {
    const widget = ui.id(name);
    const st = &ui.pie_state;
    st.* = .{ .kind = .wheel, .id = widget, .center = ui.input.mouse_pos, .button = button };
    ui.requestRedraw();
}

/// True while a pie or the wheel is open.
pub fn radialOpen(ui: *const Ui) bool {
    return ui.pie_state.kind != .none;
}

/// Called by `Ui.beginFrame`: takes the pointer and keys while open.
pub fn beginFrame(ui: *Ui) void {
    const st = &ui.pie_state;
    if (st.kind == .none) return;
    const in = &ui.input;
    st.seen = false;
    st.age += ui.dt;
    st.click = in.mouse_pressed.contains(.left);
    st.other_click = in.mouse_pressed.contains(.right) and st.button != .right or in.mouse_pressed.contains(.middle);
    st.button_up = if (st.button) |b| in.mouse_released.contains(b) else false;
    st.key_up = if (st.key) |k| in.keys_released.contains(k) else false;
    st.escape = in.keys_pressed.contains(.escape);
    st.backspace = in.keys_pressed.contains(.backspace);
    st.number = null;
    for (number_keys, 0..) |k, i| if (in.keys_pressed.contains(k)) {
        st.number = i;
    };
    // Every press is the menu's: nothing behind it sees one.
    in.mouse_pressed = .empty;
    in.mouse_released = .empty;
    in.keys_pressed = .empty;
    in.key_event_len = 0;
    in.text_len = 0;
    in.scroll = .{};
    // Nothing behind reacts to the pointer.
    ui.dead_press = true;
}

/// Called by `Ui.endFrame`: one that wasn't described is gone.
pub fn endFrame(ui: *Ui) void {
    const st = &ui.pie_state;
    if (st.kind != .none and !st.seen) st.* = .{};
}

/// Draws into the overlay, above everything, for the rest of the scope.
const OverlayScope = struct {
    saved: *draw.DrawList,
    fn begin(ui: *Ui) OverlayScope {
        const s: OverlayScope = .{ .saved = ui.list };
        ui.list = &ui.overlay;
        ui.pushClipAbsolute(.{ .w = ui.width, .h = ui.height });
        return s;
    }
    fn end(s: OverlayScope, ui: *Ui) void {
        ui.popClip();
        ui.overlay.setClip(null) catch {};
        ui.list = s.saved;
    }
};

/// Directions of a pie's choices, in order: left, right, down, up, then
/// the diagonals. Angles in radians, y down.
const pie_angles = [8]f32{
    std.math.pi,             0,
    std.math.pi / 2.0,       -std.math.pi / 2.0,
    -3 * std.math.pi / 4.0,  -std.math.pi / 4.0,
    3 * std.math.pi / 4.0,   std.math.pi / 4.0,
};

fn angleDistance(a: f32, b: f32) f32 {
    const d = @mod(a - b + std.math.pi, 2 * std.math.pi) - std.math.pi;
    return @abs(d);
}

/// The pie `name`, if open: up to eight `items`, by direction.
pub fn pie(ui: *Ui, name: []const u8, items: []const PieItem, options: PieOptions) PieResult {
    const st = &ui.pie_state;
    const widget = ui.id(name);
    if (st.kind != .pie or st.id != widget) return .none;
    st.seen = true;
    const n = @min(items.len, 8);
    const style = &ui.style;
    const colors = &style.colors;

    // Keep the whole pie on screen.
    const reach = options.radius + 90;
    st.center = .{
        .x = std.math.clamp(st.center.x, @min(reach, ui.width / 2), @max(ui.width / 2, ui.width - reach)),
        .y = std.math.clamp(st.center.y, @min(options.radius + 30, ui.height / 2), @max(ui.height / 2, ui.height - options.radius - 30)),
    };
    const c = st.center;
    const d = ui.input.mouse_pos.sub(c);
    const dist = d.length();
    if (dist > dead_zone) st.moved = true;
    const angle = std.math.atan2(d.y, d.x);
    var highlight: ?usize = null;
    if (dist > dead_zone) {
        var best: f32 = std.math.inf(f32);
        for (0..n) |i| {
            const ad = angleDistance(angle, pie_angles[i]);
            if (ad < best) {
                best = ad;
                highlight = i;
            }
        }
    }

    // The boxes: their rects decide clicks as much as the direction does.
    var rects: [8]Rect = undefined;
    const line_h = ui.textSize("").y;
    const h = line_h + 2 * style.frame_padding.y;
    for (items[0..n], 0..) |item, i| {
        const icon_w: f32 = if (item.icon != null) line_h + 6 else 0;
        const w = ui.textSize(item.label).x + icon_w + 2 * style.frame_padding.x;
        const a = pie_angles[i];
        const p: Vec2 = .{ .x = c.x + @cos(a) * options.radius, .y = c.y + @sin(a) * options.radius * 0.8 };
        // Left and right boxes hang off the circle; the others centre on it.
        const ax: f32 = if (@cos(a) < -0.3) 1 else if (@cos(a) > 0.3) 0 else 0.5;
        rects[i] = .{ .x = p.x - w * ax, .y = p.y - h / 2, .w = w, .h = h };
    }
    // A box under the pointer wins over the direction.
    for (rects[0..n], 0..) |r, i| if (r.contains(ui.input.mouse_pos)) {
        highlight = i;
    };

    var result: PieResult = .none;
    const usable = if (highlight) |i| items[i].disabled == null else false;
    if (st.escape or st.other_click) {
        // (the pie's Escape: a dialog under it stays open)
        if (st.escape) ui.input.keys_pressed.remove(.escape);
        result = .cancelled;
    } else if (st.number) |k| {
        if (k < n and items[k].disabled == null) result = .{ .chosen = k };
    } else if (st.click) {
        result = if (highlight != null and usable) .{ .chosen = highlight.? } else if (highlight == null) .cancelled else .none;
    } else if (st.key_up) {
        if (st.age < tap_time and !st.moved) {
            result = .tapped;
        } else if (highlight != null and usable) {
            result = .{ .chosen = highlight.? };
        }
        // Let go in the middle after a hold: stays open for a click.
        st.key = null;
    }

    const scope = OverlayScope.begin(ui);
    defer scope.end(ui);
    const parent = record.enterContainer(ui, .pie, widget, Ui.visibleLabel(name), .{ .x = c.x - reach, .y = c.y - options.radius - h, .w = 2 * reach, .h = 2 * options.radius + 2 * h }, .{});
    defer record.leaveContainer(ui, parent);

    // The middle: a ring with a notch towards the pointer.
    const p = ui.painter();
    p.circle(c, dead_zone, colors.popup.withAlpha(230));
    p.circleOutline(c, dead_zone, colors.border, 1.5);
    if (dist > dead_zone) p.arc(c, dead_zone, angle - 0.5, angle + 0.5, colors.accent, 3);
    if (options.title) |t| {
        const tw = ui.textSize(t).x;
        ui.drawText(.{ .x = c.x - tw / 2, .y = c.y - dead_zone - line_h - 6 }, colors.text_muted, t);
    }
    for (items[0..n], 0..) |item, i| {
        const r = rects[i];
        const lit = highlight == i;
        const disabled = item.disabled != null;
        const fill = if (lit and !disabled) colors.button_active else colors.popup;
        ui.drawShadow(r, style.rounding, fill);
        ui.drawRect(.{ .rect = r, .fill = fill, .border = if (lit or item.checked) colors.accent else colors.border, .border_width = 1, .radius = style.rounding });
        const text_color = if (disabled) colors.text_muted.withAlpha(140) else if (lit) color.textOn(fill) else if (item.checked) colors.accent else colors.text;
        var x = r.x + style.frame_padding.x;
        if (item.icon) |ic| {
            p.icon(ic, .{ .x = x, .y = r.y + (r.h - line_h) / 2, .w = line_h, .h = line_h }, text_color);
            x += line_h + 6;
        }
        ui.drawText(.{ .x = x, .y = r.y + style.frame_padding.y }, text_color, item.label);
        ui.recordWidget(.pie_item, .none, item.label, r, .{ .hovered = lit, .enabled = !disabled, .value = item.disabled });
        if (lit) if (item.disabled) |why| {
            const ww = ui.textSize(why).x;
            ui.drawText(.{ .x = r.x + r.w / 2 - ww / 2, .y = r.bottom() + 4 }, colors.warning, why);
        };
    }
    if (result != .none) st.* = .{};
    return result;
}

/// The wheel `name`, if open.
pub fn wheel(ui: *Ui, name: []const u8, items: []const WheelItem, options: WheelOptions) WheelResult {
    const st = &ui.pie_state;
    const widget = ui.id(name);
    if (st.kind != .wheel or st.id != widget) return .none;
    st.seen = true;
    const n = @min(items.len, number_keys.len);
    if (n == 0) {
        st.* = .{};
        return .cancelled;
    }
    const style = &ui.style;
    const colors = &style.colors;
    const inner = options.inner;
    const outer = options.outer;
    const arc_in = outer + 8;
    const arc_out = outer + 72;
    const reach = arc_out + 70;
    st.center = .{
        .x = std.math.clamp(st.center.x, @min(reach, ui.width / 2), @max(ui.width / 2, ui.width - reach)),
        .y = std.math.clamp(st.center.y, @min(reach, ui.height / 2), @max(ui.height / 2, ui.height - reach)),
    };
    const c = st.center;
    const d = ui.input.mouse_pos.sub(c);
    const dist = d.length();
    if (dist > inner) st.moved = true;
    const angle = std.math.atan2(d.y, d.x);
    const nf: f32 = @floatFromInt(n);
    const span = 2 * std.math.pi / nf;
    const start = -std.math.pi / 2.0;

    // Which entry the direction points at.
    // (beyond the rim only the direction of a drag with the button down
    // counts: a click out there closes)
    const dragging = st.button != null;
    var hovered: ?usize = null;
    if (dist > inner and (dist <= outer + 2 or dragging)) {
        const t = @mod(angle - start + span / 2, 2 * std.math.pi);
        hovered = @min(n - 1, @as(usize, @intFromFloat(@floor(t / span))));
    }
    // The open arc, if any, and the child under the pointer.
    var child_hovered: ?usize = null;
    const child_span: f32 = 0.42;
    // (the app's entries changed since the arc opened)
    if (st.group) |g| if (g >= n or items[g].children.len == 0) {
        st.group = null;
    };
    if (st.group) |g| {
        const kids = items[g].children;
        const mid = start + @as(f32, @floatFromInt(g)) * span;
        const total = child_span * @as(f32, @floatFromInt(kids.len));
        if (dist > outer + 2 and (dist <= arc_out + 2 or dragging)) {
            const rel = @mod(angle - (mid - total / 2) + std.math.pi, 2 * std.math.pi) - std.math.pi;
            if (rel >= 0 and rel < total) {
                child_hovered = @min(kids.len - 1, @as(usize, @intFromFloat(@floor(rel / child_span))));
                hovered = g;
            }
        }
    }
    // Hovering an entry with children opens its arc; another entry closes
    // it.
    if (child_hovered == null and dist <= outer + 2) if (hovered) |hv| {
        if (st.closed_group != hv) st.closed_group = null;
        if (items[hv].children.len > 0 and items[hv].disabled == null and st.closed_group == null) {
            st.group = hv;
        } else if (st.group != null and st.group.? != hv) {
            st.group = null;
        }
    };

    var result: WheelResult = .none;
    if (st.escape or st.other_click) {
        // (the pie's Escape: a dialog under it stays open)
        if (st.escape) ui.input.keys_pressed.remove(.escape);
        result = .cancelled;
    } else if (st.backspace) {
        if (st.group) |g| st.closed_group = g;
        st.group = null;
        child_hovered = null; // (its arc went)
    } else if (st.number) |k| {
        if (st.group) |g| {
            const kids = items[g].children;
            if (k < kids.len and kids[k].disabled == null) result = .{ .chosen = .{ .item = g, .child = k } };
        } else if (k < n and items[k].disabled == null) {
            if (items[k].children.len > 0) {
                st.group = k;
                st.closed_group = null;
            } else result = .{ .chosen = .{ .item = k } };
        }
    } else if (st.click or (st.button_up and st.moved)) {
        if (child_hovered) |ch| {
            if (items[st.group.?].children[ch].disabled == null) result = .{ .chosen = .{ .item = st.group.?, .child = ch } };
        } else if (hovered) |hv| {
            if (items[hv].disabled == null) {
                if (items[hv].children.len > 0) {
                    st.group = hv;
                    st.closed_group = null;
                } else result = .{ .chosen = .{ .item = hv } };
            }
        } else if (st.click) {
            // A click in the middle or outside closes.
            result = .cancelled;
        }
    }
    if (st.button_up) st.button = null;

    const scope = OverlayScope.begin(ui);
    defer scope.end(ui);
    const parent = record.enterContainer(ui, .pie, widget, Ui.visibleLabel(name), .{ .x = c.x - arc_out, .y = c.y - arc_out, .w = 2 * arc_out, .h = 2 * arc_out }, .{});
    defer record.leaveContainer(ui, parent);

    const p = ui.painter();
    const bounds: Rect = .{ .x = c.x - outer, .y = c.y - outer, .w = 2 * outer, .h = 2 * outer };
    // The disc under the entries: what shows between them.
    const disc = color.mix(colors.popup, Color.black, 0.35);
    const hub = inner - 3;
    ui.drawShadow(bounds, outer, disc);
    p.circle(c, outer + 1.5, colors.border);
    p.circle(c, outer, disc);
    for (items[0..n], 0..) |item, i| {
        const mid = start + @as(f32, @floatFromInt(i)) * span;
        drawEntry(ui, item, i, c, inner, outer - 1.5, mid - span / 2, mid + span / 2, hovered == i and child_hovered == null, st.group == i, options.labels);
    }
    // Between the entries: lines as wide at the hub as at the rim.
    if (n > 1) for (0..n) |i| {
        const a = start + (@as(f32, @floatFromInt(i)) - 0.5) * span;
        p.line(.{ .x = c.x + @cos(a) * hub, .y = c.y + @sin(a) * hub }, .{ .x = c.x + @cos(a) * outer, .y = c.y + @sin(a) * outer }, disc, 2);
    };
    // The middle: closes on click; names what the pointer is on.
    p.circle(c, inner, disc);
    p.circle(c, hub, colors.popup);
    p.circleOutline(c, hub, colors.border, 1);
    if (dist > inner and (hovered != null or dist <= arc_out + 2)) p.arc(c, hub - 1, angle - 0.3, angle + 0.3, colors.accent, 2.5);
    const line_h = ui.textSize("").y;
    const pointed: ?WheelItem = if (child_hovered) |ch| items[st.group.?].children[ch] else if (hovered) |hv| items[hv] else null;
    const named = if (pointed) |item| blk: {
        const tw = ui.textSize(item.label).x;
        if (tw > 2 * hub - 12) break :blk false;
        ui.drawText(.{ .x = c.x - tw / 2, .y = c.y - line_h / 2 }, if (item.disabled != null) colors.text_muted else colors.text, item.label);
        break :blk true;
    } else false;
    if (!named) {
        const s: f32 = @min(16, hub);
        p.icon(.{ .builtin = .close }, .{ .x = c.x - s / 2, .y = c.y - s / 2, .w = s, .h = s }, colors.text_muted.withAlpha(if (dist <= inner) 255 else 120));
    }

    // The open arc.
    if (st.group) |g| {
        const kids = items[g].children;
        const mid = start + @as(f32, @floatFromInt(g)) * span;
        const total = child_span * @as(f32, @floatFromInt(kids.len));
        const from = mid - total / 2;
        const pad = 2 / arc_in;
        p.ringSegment(c, arc_in - 3.5, arc_out + 3.5, from - pad * 1.75, from + total + pad * 1.75, colors.border);
        p.ringSegment(c, arc_in - 2, arc_out + 2, from - pad, from + total + pad, disc);
        ui.pushId(items[g].label);
        for (kids, 0..) |kid, k| {
            const a0 = from + @as(f32, @floatFromInt(k)) * child_span;
            drawEntry(ui, kid, k, c, arc_in, arc_out, a0, a0 + child_span, child_hovered == k, false, true);
        }
        for (1..kids.len) |k| {
            const a = from + @as(f32, @floatFromInt(k)) * child_span;
            p.line(.{ .x = c.x + @cos(a) * arc_in, .y = c.y + @sin(a) * arc_in }, .{ .x = c.x + @cos(a) * arc_out, .y = c.y + @sin(a) * arc_out }, disc, 2);
        }
        ui.popId();
    }

    // What the pointer is on, above the wheel; why it is greyed.
    if (pointed) |item| {
        const top = c.y - (if (st.group != null) arc_out else outer) - 2 * line_h - 14;
        const tw = ui.textSize(item.label).x;
        const chip: Rect = .{ .x = c.x - tw / 2 - 10, .y = top, .w = tw + 20, .h = line_h + 8 };
        if (!named) {
            ui.drawShadow(chip, style.rounding, colors.popup);
            ui.drawRect(.{ .rect = chip, .fill = colors.popup, .border = colors.border, .border_width = 1, .radius = style.rounding });
            ui.drawText(.{ .x = chip.x + 10, .y = chip.y + 4 }, colors.text, item.label);
        }
        if (item.disabled) |why| {
            const ww = ui.textSize(why).x;
            const r: Rect = .{ .x = c.x - ww / 2 - 10, .y = chip.bottom() + 2, .w = ww + 20, .h = line_h + 8 };
            ui.drawShadow(r, style.rounding, colors.popup);
            ui.drawRect(.{ .rect = r, .fill = colors.popup, .border = colors.warning, .border_width = 1, .radius = style.rounding });
            ui.drawText(.{ .x = r.x + 10, .y = r.y + 4 }, colors.warning, why);
        }
    }
    if (result != .none) st.* = .{};
    return result;
}

/// True if `pt` is on the ring segment.
fn onSegment(c: Vec2, pt: Vec2, r0: f32, r1: f32, a0: f32, a1: f32) bool {
    const d = pt.sub(c);
    const r = d.length();
    if (r < r0 or r > r1) return false;
    const rel = @mod(std.math.atan2(d.y, d.x) - (a0 + a1) / 2 + std.math.pi, 2 * std.math.pi) - std.math.pi;
    return @abs(rel) <= (a1 - a0) / 2;
}

/// How far the segment goes on from `pt` along x, towards `sign`.
fn roomAt(c: Vec2, pt: Vec2, sign: f32, r0: f32, r1: f32, a0: f32, a1: f32) f32 {
    var far: f32 = 0;
    while (far < 120 and onSegment(c, .{ .x = pt.x + sign * far, .y = pt.y }, r0, r1, a0, a1)) far += 1;
    return far;
}

/// `label`, or its start and an ellipsis, to fit `room` at the current font
/// size; empty if not even that fits.
fn fitLabel(ui: *Ui, label: []const u8, room: f32, buffer: *[64]u8) []const u8 {
    if (ui.textSize(label).x <= room) return label;
    const dots = "\u{2026}";
    var len = @min(label.len, buffer.len - dots.len);
    while (len > 0) {
        len -= 1;
        // (never in the middle of a character)
        while (len > 0 and label[len] & 0xc0 == 0x80) len -= 1;
        if (len < 2) break;
        @memcpy(buffer[0..len], label[0..len]);
        @memcpy(buffer[len..][0..dots.len], dots);
        const s = buffer[0 .. len + dots.len];
        if (ui.textSize(s).x <= room) return s;
    }
    return "";
}

/// One entry: a quiet ring segment with its colour on the rim, on the icon
/// and, under the pointer, all over; its name and number key.
fn drawEntry(ui: *Ui, item: WheelItem, index: usize, c: Vec2, r0: f32, r1: f32, a0: f32, a1: f32, lit: bool, open: bool, named: bool) void {
    const style = &ui.style;
    const colors = &style.colors;
    const p = ui.painter();
    const base = item.color orelse colors.button_active;
    const disabled = item.disabled != null;
    const fill = if (disabled)
        colors.popup
    else if (lit)
        base
    else
        color.mix(colors.popup, base, if (open) 0.4 else 0.12);
    p.ringSegment(c, r0, r1, a0, a1, fill);
    // Its colour along the rim.
    const rim: f32 = 3;
    if (!lit or disabled) p.ringSegment(c, r1 - rim, r1, a0, a1, if (disabled) color.mix(colors.popup, base, 0.3) else base);

    const on = color.textOn(fill);
    const text_ink = if (disabled) colors.text_muted.withAlpha(120) else if (lit) on else colors.text;
    const icon_ink = if (disabled or lit) text_ink else color.ensureContrast(base, fill, colors.text, 3.5);
    const quiet_ink = if (disabled) text_ink else if (lit) on.withAlpha(170) else colors.text_muted;

    // The icon with the name under it, as one block in the middle.
    const mid = (a0 + a1) / 2;
    const depth = r1 - r0;
    const rm = r0 + depth * 0.54;
    const at: Vec2 = .{ .x = c.x + @cos(mid) * rm, .y = c.y + @sin(mid) * rm };
    const size: f32 = std.math.clamp(depth * 0.24, 16, 24);
    ui.pushMetric(.font_size, style.font_size * 0.82);
    const small_h = ui.textSize("").y;
    var buffer: [64]u8 = undefined;
    var label: []const u8 = "";
    var shift: f32 = 0;
    if (named) {
        // (the line's top and bottom both stay on the segment; where the
        // segment slants, the name moves a little towards the roomy side)
        const ly = at.y + (size + 2 - small_h) / 2;
        const top: Vec2 = .{ .x = at.x, .y = ly + 2 };
        const bottom: Vec2 = .{ .x = at.x, .y = ly + small_h - 2 };
        const left = @min(roomAt(c, top, -1, r0, r1 - rim, a0, a1), roomAt(c, bottom, -1, r0, r1 - rim, a0, a1));
        const right = @min(roomAt(c, top, 1, r0, r1 - rim, a0, a1), roomAt(c, bottom, 1, r0, r1 - rim, a0, a1));
        shift = std.math.clamp((right - left) / 2, -10, 10);
        label = fitLabel(ui, item.label, 2 * @min(left + shift, right - shift) - 6, &buffer);
    }
    const block = if (label.len > 0) size + 2 + small_h else size;
    const box: Rect = .{ .x = at.x - size / 2, .y = at.y - block / 2, .w = size, .h = size };
    if (label.len > 0) ui.drawText(.{ .x = at.x + shift - ui.textSize(label).x / 2, .y = box.bottom() + 2 }, text_ink, label);
    ui.popStyle();
    if (item.icon) |ic| {
        p.icon(ic, box, icon_ink);
    } else {
        // No icon: the first letter.
        const letter = item.label[0..@min(item.label.len, std.unicode.utf8ByteSequenceLength(if (item.label.len > 0) item.label[0] else 0) catch 1)];
        const tw = ui.textSize(letter).x;
        ui.drawText(.{ .x = at.x - tw / 2, .y = box.y + (size - ui.textSize("").y) / 2 }, icon_ink, letter);
    }
    if (item.children.len > 0) {
        // An arrowhead outwards: there is more.
        const dir: Vec2 = .{ .x = @cos(mid), .y = @sin(mid) };
        const side: Vec2 = .{ .x = -dir.y, .y = dir.x };
        const tip_r = r1 - rim - 3;
        const back_r = tip_r - 4.5;
        p.polygon(&.{
            .{ .x = c.x + dir.x * back_r + side.x * 4.5, .y = c.y + dir.y * back_r + side.y * 4.5 },
            .{ .x = c.x + dir.x * tip_r, .y = c.y + dir.y * tip_r },
            .{ .x = c.x + dir.x * back_r - side.x * 4.5, .y = c.y + dir.y * back_r - side.y * 4.5 },
        }, quiet_ink);
    }
    // The number key, near the inner edge.
    const keys = "1234567890-";
    if (index < keys.len) {
        // (a shallow segment has it in the corner, clear of the name)
        // (a shallow segment has it in the upper inner corner, clear of the
        // name)
        const inset = 11 / (r0 + 10);
        const ka = if (depth >= 72) mid else if (@sin(a0 + inset) <= @sin(a1 - inset)) a0 + inset else a1 - inset;
        const kp: Vec2 = .{ .x = c.x + @cos(ka) * (r0 + 10), .y = c.y + @sin(ka) * (r0 + 10) };
        const k = keys[index..][0..1];
        ui.pushMetric(.font_size, style.font_size * 0.72);
        const ks = ui.textSize(k);
        ui.drawText(.{ .x = kp.x - ks.x / 2, .y = kp.y - ks.y / 2 }, quiet_ink.withAlpha(@min(quiet_ink.a, 170)), k);
        ui.popStyle();
    }
    ui.recordWidget(.pie_item, .none, item.label, box.inset(-4), .{ .hovered = lit, .enabled = !disabled, .value = if (open) "open" else item.disabled });
}
