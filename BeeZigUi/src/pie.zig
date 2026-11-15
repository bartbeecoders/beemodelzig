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
//! keys 1 to 9, 0 and - pick; Backspace goes back to the ring; Esc or the
//! centre closes:
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
    /// pointer is on, above the wheel).
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
    var hovered: ?usize = null;
    if (dist > inner) {
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
        if (dist > outer + 2) {
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
            // A click in the middle closes.
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
    ui.drawShadow(bounds, outer, colors.popup);
    p.circle(c, outer + 1, colors.border);
    p.circle(c, outer, colors.popup);
    const line_h = ui.textSize("").y;
    const gap: f32 = 0.015;
    for (items[0..n], 0..) |item, i| {
        const mid = start + @as(f32, @floatFromInt(i)) * span;
        drawEntry(ui, item, i, c, inner + 2, outer - 2, mid - span / 2 + gap, mid + span / 2 - gap, hovered == i and child_hovered == null, st.group == i);
        if (options.labels) {
            // its name under the icon, smaller
            const rm = (inner + outer) / 2;
            const at: Vec2 = .{ .x = c.x + @cos(mid) * rm, .y = c.y + @sin(mid) * rm };
            ui.pushMetric(.font_size, style.font_size * 0.8);
            const tw = ui.textSize(item.label).x;
            const base = item.color orelse colors.button;
            const ink = color.textOn(if (item.disabled != null) color.mix(base, colors.popup, 0.6) else base);
            ui.drawText(.{ .x = at.x - tw / 2, .y = at.y + 11 }, if (item.disabled != null) ink.withAlpha(110) else ink, item.label);
            ui.popStyle();
        }
    }
    // The middle: closes on click.
    p.circle(c, inner - 2, colors.window);
    p.circleOutline(c, inner - 2, colors.border, 1);
    if (dist > inner) p.arc(c, inner - 2, angle - 0.35, angle + 0.35, colors.accent, 3);

    // The open arc.
    if (st.group) |g| {
        const kids = items[g].children;
        const mid = start + @as(f32, @floatFromInt(g)) * span;
        const total = child_span * @as(f32, @floatFromInt(kids.len));
        p.ringSegment(c, arc_in - 1, arc_out + 1, mid - total / 2 - 0.01, mid + total / 2 + 0.01, colors.border);
        p.ringSegment(c, arc_in, arc_out, mid - total / 2, mid + total / 2, colors.popup);
        ui.pushId(items[g].label);
        for (kids, 0..) |kid, k| {
            const a0 = mid - total / 2 + @as(f32, @floatFromInt(k)) * child_span;
            drawEntry(ui, kid, k, c, arc_in + 2, arc_out - 2, a0 + gap, a0 + child_span - gap, child_hovered == k, false);
            // Its name outside the arc, on the side it points to.
            const am = a0 + child_span / 2;
            const lp: Vec2 = .{ .x = c.x + @cos(am) * (arc_out + 10), .y = c.y + @sin(am) * (arc_out + 10) };
            const lw = ui.textSize(kid.label).x;
            const lx = if (@cos(am) < -0.2) lp.x - lw else if (@cos(am) > 0.2) lp.x else lp.x - lw / 2;
            const ly = lp.y - line_h / 2 + (if (@sin(am) < -0.6) -line_h / 2 else if (@sin(am) > 0.6) line_h / 2 else 0);
            ui.drawText(.{ .x = lx, .y = ly }, if (kid.disabled != null) colors.text_muted else colors.text, kid.label);
        }
        ui.popId();
    }

    // What the pointer is on, above the wheel; why it is greyed.
    const shown: ?WheelItem = if (child_hovered) |ch| items[st.group.?].children[ch] else if (hovered) |hv| items[hv] else null;
    if (shown) |item| {
        const top = c.y - (if (st.group != null) arc_out else outer) - 2 * line_h - 14;
        const tw = ui.textSize(item.label).x;
        const chip: Rect = .{ .x = c.x - tw / 2 - 10, .y = top, .w = tw + 20, .h = line_h + 8 };
        ui.drawRect(.{ .rect = chip, .fill = colors.popup, .border = colors.border, .border_width = 1, .radius = style.rounding });
        ui.drawText(.{ .x = chip.x + 10, .y = chip.y + 4 }, colors.text, item.label);
        if (item.disabled) |why| {
            const ww = ui.textSize(why).x;
            const r: Rect = .{ .x = c.x - ww / 2 - 10, .y = chip.bottom() + 2, .w = ww + 20, .h = line_h + 8 };
            ui.drawRect(.{ .rect = r, .fill = colors.popup, .border = colors.warning, .border_width = 1, .radius = style.rounding });
            ui.drawText(.{ .x = r.x + 10, .y = r.y + 4 }, colors.warning, why);
        }
    }
    if (result != .none) st.* = .{};
    return result;
}

/// One entry: a coloured ring segment with its icon and number key.
fn drawEntry(ui: *Ui, item: WheelItem, index: usize, c: Vec2, r0: f32, r1: f32, a0: f32, a1: f32, lit: bool, open: bool) void {
    const style = &ui.style;
    const colors = &style.colors;
    const p = ui.painter();
    const base = item.color orelse colors.button;
    const disabled = item.disabled != null;
    var fill = if (lit or open) color.mix(base, Color.white, 0.22) else base;
    if (disabled) fill = color.mix(base, colors.popup, 0.6);
    p.ringSegment(c, r0, r1, a0, a1, fill);
    if (lit and !disabled) p.arc(c, r1 - 1.5, a0, a1, colors.accent, 3);
    const mid = (a0 + a1) / 2;
    const rm = (r0 + r1) / 2;
    const at: Vec2 = .{ .x = c.x + @cos(mid) * rm, .y = c.y + @sin(mid) * rm };
    const ink = if (disabled) color.textOn(fill).withAlpha(110) else color.textOn(fill);
    const size: f32 = 20;
    const box: Rect = .{ .x = at.x - size / 2, .y = at.y - size / 2, .w = size, .h = size };
    if (item.icon) |ic| {
        p.icon(ic, box, ink);
    } else {
        // No icon: the first letter.
        const letter = item.label[0..@min(item.label.len, std.unicode.utf8ByteSequenceLength(if (item.label.len > 0) item.label[0] else 0) catch 1)];
        const tw = ui.textSize(letter).x;
        ui.drawText(.{ .x = at.x - tw / 2, .y = at.y - ui.textSize("").y / 2 }, ink, letter);
    }
    if (item.children.len > 0) {
        // An arrow outwards: there is more.
        const tip: Vec2 = .{ .x = c.x + @cos(mid) * (r1 - 6), .y = c.y + @sin(mid) * (r1 - 6) };
        p.circle(tip, 2.5, ink);
    }
    // The number key, near the inner edge.
    const keys = "1234567890-";
    if (index < keys.len) {
        const kp: Vec2 = .{ .x = c.x + @cos(mid) * (r0 + 9), .y = c.y + @sin(mid) * (r0 + 9) };
        const k = keys[index..][0..1];
        const kw = ui.textSize(k).x * 0.8;
        ui.pushMetric(.font_size, style.font_size * 0.8);
        ui.drawText(.{ .x = kp.x - kw / 2, .y = kp.y - ui.textSize(k).y / 2 }, ink.withAlpha(@min(ink.a, 150)), k);
        ui.popStyle();
    }
    ui.recordWidget(.pie_item, .none, item.label, box.inset(-4), .{ .hovered = lit, .enabled = !disabled, .value = if (open) "open" else item.disabled });
}
