//! The keyboard layout, from the XKB text keymap the compositor sends: no
//! libxkbcommon. Keys to text with Shift, Caps Lock, AltGr and dead keys;
//! keys to Zui keys by the letter printed on them, so Ctrl+Z is the key
//! labelled Z on AZERTY and QWERTZ too. Without a keymap, US.
//!
//! The parser reads the two parts that matter for typing:
//!   xkb_keycodes  <NAME> = code;
//!   xkb_symbols   key <NAME> { [ level1, level2, level3, level4 ] };

const std = @import("std");
const zui = @import("zui");
const keysyms = @import("keysyms.zig");

/// XKB modifier bits as compositors send them: Shift.
pub const mod_shift = 1;
/// Caps Lock.
pub const mod_caps = 2;
/// Control.
pub const mod_ctrl = 4;
/// Mod1: Alt.
pub const mod_alt = 8;
/// Mod4: the Super (Windows) key.
pub const mod_super = 0x40;
/// Mod5: ISO_Level3_Shift (AltGr) on most layouts.
pub const mod_altgr = 0x80;

const count = 256;
/// Layouts kept per keymap (XKB allows four groups).
const max_groups = 4;

/// The levels of one key from the symbols in "[ q, Q, at, Greek_omega ]".
fn fillLevels(levels: *[4]u32, list: []const u8) void {
    var it = std.mem.tokenizeAny(u8, list, ", \t\n");
    var level: usize = 0;
    while (it.next()) |tok| : (level += 1) {
        if (level >= 4) break;
        levels[level] = lookup(tok);
    }
}

/// Keys that type nothing, by keysym name, kept as `named | key`.
const named: u32 = 0x7F000000;
const key_names = std.StaticStringMap(zui.Key).initComptime(.{
    .{ "Tab", .tab },            .{ "ISO_Left_Tab", .tab },   .{ "Return", .enter },   .{ "KP_Enter", .enter },
    .{ "Escape", .escape },      .{ "BackSpace", .backspace }, .{ "Delete", .delete }, .{ "KP_Delete", .delete },
    .{ "Insert", .insert },      .{ "Home", .home },          .{ "End", .end },        .{ "Prior", .page_up },
    .{ "Page_Up", .page_up },    .{ "Next", .page_down },     .{ "Page_Down", .page_down },
    .{ "Left", .left },          .{ "Right", .right },        .{ "Up", .up },          .{ "Down", .down },
    .{ "F1", .f1 },              .{ "F2", .f2 },              .{ "F3", .f3 },          .{ "F4", .f4 },
    .{ "F5", .f5 },              .{ "F6", .f6 },              .{ "F7", .f7 },          .{ "F8", .f8 },
    .{ "F9", .f9 },              .{ "F10", .f10 },            .{ "F11", .f11 },        .{ "F12", .f12 },
});
const sym_map = std.StaticStringMap(u32).initComptime(keysyms.table);

const us_lower = "\x00\x001234567890-=\x00\x00qwertyuiop[]\x00\x00asdfghjkl;'`\x00\\zxcvbnm,./";
const us_upper = "\x00\x00!@#$%^&*()_+\x00\x00QWERTYUIOP{}\x00\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?";

fn usChar(code: u32, shifted: bool) u32 {
    if (code == 57) return ' ';
    if (code >= us_lower.len) return 0;
    return if (shifted) us_upper[code] else us_lower[code];
}

/// A keyboard layout: evdev code by level to code point.
pub const Keymap = struct {
    /// The levels of each key, per layout (group).
    groups: [max_groups][count][4]u32 = @splat(@splat(.{ 0, 0, 0, 0 })),
    /// How many layouts the keymap has.
    group_count: u8 = 1,
    /// The layout in use, from the compositor's modifiers event.
    group: u8 = 0,
    loaded: bool = false,
    /// A dead key waiting for the next character (its kind; 0: none).
    dead: u32 = 0,

    /// Uses layout `g` (the group in the compositor's modifiers event); past
    /// the keymap's layouts, wraps as XKB does.
    pub fn setGroup(self: *Keymap, g: u32) void {
        self.group = @intCast(g % @max(1, self.group_count));
    }

    /// Reads an XKB text keymap. Returns false, keeping US, when it holds
    /// too little to use.
    pub fn parse(self: *Keymap, text: []const u8) bool {
        var names: [count][8]u8 = undefined;
        var name_len: [count]u8 = @splat(0);
        const kc = std.mem.indexOf(u8, text, "xkb_keycodes") orelse return false;
        const ks = std.mem.indexOf(u8, text, "xkb_symbols") orelse return false;
        var table: [max_groups][count][4]u32 = @splat(@splat(.{ 0, 0, 0, 0 }));
        var groups_seen: u8 = 1;
        var i = kc;
        const kc_end = std.mem.indexOfPos(u8, text, kc, "};") orelse return false;
        while (i < kc_end) {
            const lt = std.mem.indexOfScalarPos(u8, text, i, '<') orelse break;
            if (lt >= kc_end) break;
            const gt = std.mem.indexOfScalarPos(u8, text, lt, '>') orelse break;
            const nm = text[lt + 1 .. gt];
            var j = gt + 1;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
            const line_start = std.mem.lastIndexOfScalar(u8, text[0..lt], '\n') orelse 0;
            const is_alias = std.mem.indexOf(u8, text[line_start..lt], "alias") != null;
            if (!is_alias and j < text.len and text[j] == '=') {
                j += 1;
                while (j < text.len and text[j] == ' ') j += 1;
                var e = j;
                while (e < text.len and std.ascii.isDigit(text[e])) e += 1;
                const code = std.fmt.parseInt(u32, text[j..e], 10) catch 0;
                if (code >= 8 and code - 8 < count and nm.len <= 8) {
                    @memcpy(names[code - 8][0..nm.len], nm);
                    name_len[code - 8] = @intCast(nm.len);
                }
                i = e;
            } else i = gt + 1;
        }
        i = ks;
        var found: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, "key <")) |k| {
            const gt = std.mem.indexOfScalarPos(u8, text, k + 5, '>') orelse break;
            const nm = text[k + 5 .. gt];
            const open = std.mem.indexOfScalarPos(u8, text, gt, '{') orelse break;
            const close = std.mem.indexOfPos(u8, text, open, "};") orelse break;
            i = close;
            var code: ?usize = null;
            for (0..count) |c| {
                if (name_len[c] == nm.len and std.mem.eql(u8, names[c][0..name_len[c]], nm)) {
                    code = c;
                    break;
                }
            }
            const c = code orelse continue;
            const body = text[open..close];
            // Several layouts: "symbols[N]= [ ... ]" each. One: a plain
            // "[ ... ]" (after a "type[...]" there may be, skipped).
            var any = false;
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, body, at, "symbols[")) |sp| {
                const num_end = std.mem.indexOfScalarPos(u8, body, sp + 8, ']') orelse break;
                const name = std.mem.trimStart(u8, body[sp + 8 .. num_end], "Group");
                const g = (std.fmt.parseInt(usize, name, 10) catch 1) -| 1;
                const eq = std.mem.indexOfScalarPos(u8, body, num_end, '=') orelse break;
                const lb = std.mem.indexOfScalarPos(u8, body, eq, '[') orelse break;
                const rb = std.mem.indexOfScalarPos(u8, body, lb, ']') orelse break;
                if (g < max_groups) {
                    fillLevels(&table[g][c], body[lb + 1 .. rb]);
                    groups_seen = @max(groups_seen, @as(u8, @intCast(g + 1)));
                }
                at = rb;
                any = true;
            }
            if (!any) {
                var from: usize = 0;
                const lb = while (std.mem.indexOfScalarPos(u8, body, from, '[')) |b| {
                    // "type[Group1]=" is not the symbols
                    if (std.mem.endsWith(u8, std.mem.trimEnd(u8, body[0..b], " \t"), "type")) {
                        from = (std.mem.indexOfScalarPos(u8, body, b, ']') orelse break null) + 1;
                        continue;
                    }
                    break b;
                } else null;
                const l = lb orelse continue;
                const rb = std.mem.indexOfScalarPos(u8, body, l, ']') orelse continue;
                fillLevels(&table[0][c], body[l + 1 .. rb]);
            }
            found += 1;
        }
        // Even a tiny keymap is the layout now (a virtual keyboard sends
        // one with just the keys it types).
        if (found == 0) return false;
        self.groups = table;
        self.group_count = groups_seen;
        self.group = 0;
        self.loaded = true;
        return true;
    }

    /// The code point a key types with `mods`, or 0. A dead key waits for
    /// the next key (Space gives the accent itself).
    pub fn char(self: *Keymap, code: u32, mods: u32) u32 {
        switch (code) {
            71, 72, 73 => return '7' + code - 71,
            75, 76, 77 => return '4' + code - 75,
            79, 80, 81 => return '1' + code - 79,
            82 => return '0',
            83 => return '.',
            74 => return '-',
            78 => return '+',
            98 => return '/',
            55 => return '*',
            else => {},
        }
        const shift = mods & mod_shift != 0;
        const caps = mods & mod_caps != 0;
        var cp: u32 = 0;
        if (!self.loaded or code >= count) {
            cp = usChar(code, shift);
        } else {
            const altgr = mods & mod_altgr != 0;
            const lvl: usize = (if (altgr) @as(usize, 2) else 0) + (if (shift) @as(usize, 1) else 0);
            const syms = &self.groups[self.group][code];
            cp = syms[lvl];
            if (cp == 0 and lvl > 0) cp = syms[lvl & 2];
            if (code == 57 and cp == 0) cp = ' ';
        }
        if (cp & 0xFF000000 == named) return 0;
        if (caps and cp < 0x80000000) cp = flipCase(cp);
        if (cp & 0x80000000 != 0) {
            self.dead = cp & 0xff;
            return 0;
        }
        if (self.dead != 0) {
            const d = self.dead;
            self.dead = 0;
            if (cp == ' ') return spacing[@min(d, spacing.len - 1)];
            if (compose(d, cp)) |r| return r;
        }
        return cp;
    }

    /// The Zui key for evdev `code`: letters by the label on the key in
    /// this layout, the rest by position.
    pub fn key(self: *const Keymap, code: u32) ?zui.Key {
        const c = code;
        if (self.loaded and code < count) {
            // A key that types a character is the key for that character,
            // wherever it is. Escape, Enter and the like type nothing, and
            // go by position.
            const s = self.groups[self.group][code][0];
            if (s & 0xFF000000 == named) return @enumFromInt(s & 0xFF);
            if (s != 0 and s < 0x80000000) return charKey(s);
        }
        return switch (c) {
            1 => .escape,
            2...10 => @enumFromInt(@intFromEnum(zui.Key.@"1") + (c - 2)),
            11 => .@"0",
            12 => .minus,
            13 => .equal,
            14 => .backspace,
            15 => .tab,
            28, 96 => .enter,
            51 => .comma,
            52 => .period,
            53 => .slash,
            57 => .space,
            59...68 => @enumFromInt(@intFromEnum(zui.Key.f1) + (c - 59)),
            87 => .f11,
            88 => .f12,
            102 => .home,
            103 => .up,
            104 => .page_up,
            105 => .left,
            106 => .right,
            107 => .end,
            108 => .down,
            109 => .page_down,
            110 => .insert,
            111 => .delete,
            else => if (letterAt(c)) |l| l else null,
        };
    }
};

/// Keys that type nothing, by raw keysym (virtual keyboards write them
/// this way).
fn rawKey(v: u32) ?zui.Key {
    return switch (v) {
        0xff08 => .backspace,
        0xff09, 0xfe20 => .tab,
        0xff0d, 0xff8d => .enter,
        0xff1b => .escape,
        0xffff, 0xff9f => .delete,
        0xff50 => .home,
        0xff51 => .left,
        0xff52 => .up,
        0xff53 => .right,
        0xff54 => .down,
        0xff55 => .page_up,
        0xff56 => .page_down,
        0xff57 => .end,
        0xff63 => .insert,
        0xffbe...0xffc9 => @enumFromInt(@intFromEnum(zui.Key.f1) + (v - 0xffbe)),
        else => null,
    };
}

/// The Zui key for a key that types `cp`, if Zui has one.
fn charKey(cp: u32) ?zui.Key {
    const lower: u32 = if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
    if (lower >= 'a' and lower <= 'z') return @enumFromInt(@intFromEnum(zui.Key.a) + (lower - 'a'));
    if (cp >= '0' and cp <= '9') return @enumFromInt(@intFromEnum(zui.Key.@"0") + (cp - '0'));
    return switch (cp) {
        ' ' => .space,
        '-' => .minus,
        '=' => .equal,
        ',' => .comma,
        '.' => .period,
        '/' => .slash,
        else => null,
    };
}

/// The letter key at a US position, for when no keymap says otherwise.
fn letterAt(code: u32) ?zui.Key {
    if (code >= us_lower.len) return null;
    const ch = us_lower[code];
    if (ch < 'a' or ch > 'z') return null;
    return @enumFromInt(@intFromEnum(zui.Key.a) + (ch - 'a'));
}

fn lookup(name: []const u8) u32 {
    if (name.len == 1) return name[0];
    if (key_names.get(name)) |k| return named | @intFromEnum(k);
    if (sym_map.get(name)) |v| return v;
    if (name.len >= 5 and name[0] == 'U') return std.fmt.parseInt(u32, name[1..], 16) catch 0;
    if (name.len > 2 and name[0] == '0' and name[1] == 'x') {
        const v = std.fmt.parseInt(u32, name[2..], 16) catch return 0;
        if (rawKey(v)) |k| return named | @intFromEnum(k);
        if (v == 0x20ac) return 0x20ac; // EuroSign
        if (v >= 0x01000100) return v - 0x01000000;
        if (v < 0x100) return v;
    }
    return 0;
}

fn flipCase(cp: u32) u32 {
    if (cp >= 'a' and cp <= 'z') return cp - 32;
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if (cp >= 0xe0 and cp <= 0xfe and cp != 0xf7) return cp - 32;
    if (cp >= 0xc0 and cp <= 0xde and cp != 0xd7) return cp + 32;
    return cp;
}

// Dead key kinds: 1 grave, 2 acute, 3 circumflex, 4 tilde, 5 diaeresis,
// 6 ring, 7 caron, 8 cedilla.
const spacing = [_]u32{ 0, '`', 0xb4, '^', '~', 0xa8, 0xb0, 0x2c7, 0xb8 };
const compose_table = [_][3]u32{
    .{ 1, 'a', 0xe0 }, .{ 1, 'e', 0xe8 }, .{ 1, 'i', 0xec }, .{ 1, 'o', 0xf2 }, .{ 1, 'u', 0xf9 },
    .{ 1, 'A', 0xc0 }, .{ 1, 'E', 0xc8 }, .{ 1, 'I', 0xcc }, .{ 1, 'O', 0xd2 }, .{ 1, 'U', 0xd9 },
    .{ 2, 'a', 0xe1 }, .{ 2, 'e', 0xe9 }, .{ 2, 'i', 0xed }, .{ 2, 'o', 0xf3 }, .{ 2, 'u', 0xfa },
    .{ 2, 'y', 0xfd }, .{ 2, 'A', 0xc1 }, .{ 2, 'E', 0xc9 }, .{ 2, 'I', 0xcd }, .{ 2, 'O', 0xd3 },
    .{ 2, 'U', 0xda }, .{ 2, 'Y', 0xdd }, .{ 3, 'a', 0xe2 }, .{ 3, 'e', 0xea }, .{ 3, 'i', 0xee },
    .{ 3, 'o', 0xf4 }, .{ 3, 'u', 0xfb }, .{ 3, 'A', 0xc2 }, .{ 3, 'E', 0xca }, .{ 3, 'I', 0xce },
    .{ 3, 'O', 0xd4 }, .{ 3, 'U', 0xdb }, .{ 4, 'a', 0xe3 }, .{ 4, 'o', 0xf5 }, .{ 4, 'n', 0xf1 },
    .{ 4, 'A', 0xc3 }, .{ 4, 'O', 0xd5 }, .{ 4, 'N', 0xd1 }, .{ 5, 'a', 0xe4 }, .{ 5, 'e', 0xeb },
    .{ 5, 'i', 0xef }, .{ 5, 'o', 0xf6 }, .{ 5, 'u', 0xfc }, .{ 5, 'y', 0xff }, .{ 5, 'A', 0xc4 },
    .{ 5, 'E', 0xcb }, .{ 5, 'I', 0xcf }, .{ 5, 'O', 0xd6 }, .{ 5, 'U', 0xdc }, .{ 6, 'a', 0xe5 },
    .{ 6, 'A', 0xc5 }, .{ 8, 'c', 0xe7 }, .{ 8, 'C', 0xc7 },
};

fn compose(d: u32, base: u32) ?u32 {
    for (compose_table) |e| if (e[0] == d and e[1] == base) return e[2];
    return null;
}

const testing = std.testing;

test "US without a keymap; an AZERTY keymap moves the letters" {
    var km: Keymap = .{};
    try testing.expectEqual(@as(u32, 'q'), km.char(16, 0));
    try testing.expectEqual(@as(u32, 'Q'), km.char(16, mod_shift));
    try testing.expectEqual(zui.Key.q, km.key(16).?);
    try testing.expectEqual(zui.Key.escape, km.key(1).?);
    // A tiny AZERTY-like map: <AD01> (code 24-8=16) carries 'a'.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "xkb_keycodes {\n");
    for (0..24) |n| try text.print(testing.allocator, "  <K{d}> = {d};\n", .{ n, n + 16 });
    try text.appendSlice(testing.allocator, "};\nxkb_symbols {\n");
    for (0..24) |n| {
        const letter: u8 = if (n == 8) 'a' else 'b';
        try text.print(testing.allocator, "  key <K{d}> {{ [ {c}, {c}, eacute, dead_acute ] }};\n", .{ n, letter, std.ascii.toUpper(letter) });
    }
    try text.appendSlice(testing.allocator, "};\n");
    try testing.expect(km.parse(text.items));
    // <K8> = code 24 - 8 = 16, where Q is on QWERTY: now it is A.
    try testing.expectEqual(zui.Key.a, km.key(16).?);
    try testing.expectEqual(@as(u32, 'a'), km.char(16, 0));
    try testing.expectEqual(@as(u32, 0xe9), km.char(16, mod_altgr));
    // A key in another key's place (the 7 key here) that types a letter
    // is that letter.
    try testing.expectEqual(zui.Key.b, km.key(8).?);
    // A dead acute, then e: é.
    try testing.expectEqual(@as(u32, 0), km.char(17, mod_altgr | mod_shift));
}

test "a keymap with two layouts: each layout's symbols, and the one in use (improvements H1)" {
    const text =
        \\xkb_keymap {
        \\xkb_keycodes "evdev" {
        \\    <AD01> = 24;
        \\    <AC01> = 38;
        \\    <AE01> = 10;
        \\};
        \\xkb_symbols "pc+us+fr:2" {
        \\    key <AD01> {
        \\        type[Group1]= "ALPHABETIC",
        \\        type[Group2]= "ALPHABETIC",
        \\        symbols[1]= [ q, Q ],
        \\        symbols[2]= [ a, A ]
        \\    };
        \\    key <AC01> {
        \\        symbols[1]= [ a, A ],
        \\        symbols[2]= [ q, Q ]
        \\    };
        \\    key <AE01> { type= "FOUR_LEVEL", [ 1, exclam ] };
        \\};
        \\};
    ;
    var km: Keymap = .{};
    try std.testing.expect(km.parse(text));
    try std.testing.expectEqual(@as(u8, 2), km.group_count);
    try std.testing.expectEqual(@as(u32, 'q'), km.char(16, 0));
    try std.testing.expectEqual(@as(u32, 'a'), km.char(30, 0));
    try std.testing.expectEqual(@as(?zui.Key, .q), km.key(16));
    try std.testing.expectEqual(@as(u32, '1'), km.char(2, 0));
    km.setGroup(1);
    try std.testing.expectEqual(@as(u32, 'a'), km.char(16, 0));
    try std.testing.expectEqual(@as(u32, 'Q'), km.char(30, mod_shift));
    try std.testing.expectEqual(@as(?zui.Key, .a), km.key(16));
    // Past the keymap's layouts it wraps, as XKB does.
    km.setGroup(2);
    try std.testing.expectEqual(@as(u32, 'q'), km.char(16, 0));
}
