// The keyboard, as in the original's keyboard.s: an XKB text-keymap parser
// (no libxkbcommon), key -> Unicode with shift / caps lock / AltGr levels and
// dead keys, and layout-aware shortcuts (Ctrl+Z is the key labelled Z on
// AZERTY and QWERTZ too).
//
// The compositor sends the keymap as XKB text through wl_keyboard.keymap.
// Two parts matter for an editor:
//   xkb_keycodes  <NAME> = code;   alias <A> = <B>;
//   xkb_symbols   key <NAME> { [ sym1, sym2, sym3, sym4 ] };
// kept as a table: evdev code x 4 levels -> code point. Without a keymap
// (headless runs) a US layout is used.
const std = @import("std");
const keysyms = @import("keysyms.zig");

pub const MOD_SHIFT = 1;
pub const MOD_CAPS = 2;
pub const MOD_CTRL = 4;
pub const MOD_ALT = 8;
pub const MOD_ALTGR = 0x80; // Mod5: ISO_Level3_Shift on most layouts

const N = 256;
var syms: [N][4]u32 = @splat(.{ 0, 0, 0, 0 });
pub var loaded = false;
/// A dead key waiting for the next character (its kind, 0: none).
var dead: u32 = 0;

const sym_map = std.StaticStringMap(u32).initComptime(keysyms.table);

// US layout, for when there is no keymap
const us_lower = "\x00\x001234567890-=\x00\x00qwertyuiop[]\x00\x00asdfghjkl;'`\x00\\zxcvbnm,./";
const us_upper = "\x00\x00!@#$%^&*()_+\x00\x00QWERTYUIOP{}\x00\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?";

fn usChar(code: u32, shifted: bool) u32 {
    if (code == 57) return ' ';
    if (code >= us_lower.len) return 0;
    return if (shifted) us_upper[code] else us_lower[code];
}

/// A keysym name from the keymap -> code point (0: none / not text).
fn lookup(name: []const u8) u32 {
    if (name.len == 1) return name[0];
    if (sym_map.get(name)) |v| return v;
    // U+hex: Uxxxx
    if (name.len >= 5 and name[0] == 'U') {
        return std.fmt.parseInt(u32, name[1..], 16) catch 0;
    }
    // a raw keysym: 0x100xxxx is Unicode, Latin-1 is itself
    if (name.len > 2 and name[0] == '0' and name[1] == 'x') {
        const v = std.fmt.parseInt(u32, name[2..], 16) catch return 0;
        if (v >= 0x01000100) return v - 0x01000000;
        if (v < 0x100) return v;
    }
    return 0;
}

/// Parse an XKB text keymap. Returns false (and keeps the US table) when it
/// has nothing usable.
pub fn parse(text: []const u8) bool {
    // keycodes: <NAME> = code;  aliases: alias <A> = <B>;
    var names: [N][8]u8 = undefined;
    var name_len: [N]u8 = @splat(0);
    const kc = std.mem.indexOf(u8, text, "xkb_keycodes") orelse return false;
    const ks = std.mem.indexOf(u8, text, "xkb_symbols") orelse return false;
    var table: [N][4]u32 = @splat(.{ 0, 0, 0, 0 });
    var i = kc;
    const kc_end = std.mem.indexOfPos(u8, text, kc, "};") orelse return false;
    while (i < kc_end) {
        const lt = std.mem.indexOfScalarPos(u8, text, i, '<') orelse break;
        if (lt >= kc_end) break;
        const gt = std.mem.indexOfScalarPos(u8, text, lt, '>') orelse break;
        const nm = text[lt + 1 .. gt];
        var j = gt + 1;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
        // the alias lines have "alias" before the name; skip them
        const line_start = std.mem.lastIndexOfScalar(u8, text[0..lt], '\n') orelse 0;
        const is_alias = std.mem.indexOf(u8, text[line_start..lt], "alias") != null;
        if (!is_alias and j < text.len and text[j] == '=') {
            j += 1;
            while (j < text.len and text[j] == ' ') j += 1;
            var e = j;
            while (e < text.len and std.ascii.isDigit(text[e])) e += 1;
            const code = std.fmt.parseInt(u32, text[j..e], 10) catch 0;
            if (code >= 8 and code - 8 < N and nm.len <= 8) {
                @memcpy(names[code - 8][0..nm.len], nm);
                name_len[code - 8] = @intCast(nm.len);
            }
            i = e;
        } else i = gt + 1;
    }
    // symbols: key <NAME> { ... [ s1, s2, s3, s4 ] ... };
    i = ks;
    var found: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "key <")) |k| {
        const gt = std.mem.indexOfScalarPos(u8, text, k + 5, '>') orelse break;
        const nm = text[k + 5 .. gt];
        const open = std.mem.indexOfScalarPos(u8, text, gt, '{') orelse break;
        const close = std.mem.indexOfPos(u8, text, open, "};") orelse break;
        i = close;
        const lb = std.mem.indexOfScalarPos(u8, text, open, '[') orelse continue;
        if (lb > close) continue;
        const rb = std.mem.indexOfScalarPos(u8, text, lb, ']') orelse continue;
        // which evdev code has this name
        var code: ?usize = null;
        for (0..N) |c| {
            if (name_len[c] == nm.len and std.mem.eql(u8, names[c][0..name_len[c]], nm)) {
                code = c;
                break;
            }
        }
        const c = code orelse continue;
        var it = std.mem.tokenizeAny(u8, text[lb + 1 .. rb], ", \t\n");
        var level: usize = 0;
        while (it.next()) |tok| : (level += 1) {
            if (level >= 4) break;
            table[c][level] = lookup(tok);
        }
        found += 1;
    }
    if (found < 20) return false;
    syms = table;
    loaded = true;
    return true;
}

/// The text a key types with these modifiers: a code point, 0 for none.
/// Dead keys wait for the next key (Space gives the accent itself).
pub fn char(code: u32, mods: u32) u32 {
    // the keypad types its digits and signs whatever the layout says
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
    const shift = mods & MOD_SHIFT != 0;
    const caps = mods & MOD_CAPS != 0;
    var cp: u32 = 0;
    if (!loaded or code >= N) {
        cp = usChar(code, shift);
    } else {
        const altgr = mods & MOD_ALTGR != 0;
        const lvl: usize = (if (altgr) @as(usize, 2) else 0) + (if (shift) @as(usize, 1) else 0);
        cp = syms[code][lvl];
        if (cp == 0 and lvl > 0) cp = syms[code][lvl & 2]; // a level the key lacks
        if (code == 57 and cp == 0) cp = ' ';
    }
    // caps lock flips letters
    if (caps and cp < 0x80000000) cp = flipCase(cp);
    if (cp & 0x80000000 != 0) {
        dead = cp & 0xff;
        return 0;
    }
    if (dead != 0) {
        const d = dead;
        dead = 0;
        if (cp == ' ') return spacing[@min(d, spacing.len - 1)];
        if (compose(d, cp)) |r| return r;
    }
    return cp;
}

fn flipCase(cp: u32) u32 {
    if (cp >= 'a' and cp <= 'z') return cp - 32;
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if (cp >= 0xe0 and cp <= 0xfe and cp != 0xf7) return cp - 32;
    if (cp >= 0xc0 and cp <= 0xde and cp != 0xd7) return cp + 32;
    return cp;
}

// dead key kinds: 1 grave, 2 acute, 3 circumflex, 4 tilde, 5 diaeresis,
// 6 ring, 7 caron, 8 cedilla
const spacing = [_]u32{ 0, '`', 0xb4, '^', '~', 0xa8, 0xb0, 0x2c7, 0xb8 };
const compose_tab = [_][3]u32{
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
    for (compose_tab) |e| {
        if (e[0] == d and e[1] == base) return e[2];
    }
    return null;
}

/// The QWERTY code of the letter this key carries, so shortcuts follow the
/// keyboard's labels (Ctrl+Z on AZERTY is the key labelled Z). Keys that
/// carry no letter keep their own code.
pub fn shortcutCode(code: u32) u32 {
    if (!loaded or code >= N) return code;
    const s = syms[code][0];
    const lower: u32 = if (s >= 'A' and s <= 'Z') s + 32 else s;
    if (lower < 'a' or lower > 'z') return code;
    for (0..us_lower.len) |c| {
        if (us_lower[c] == lower) return @intCast(c);
    }
    return code;
}

/// The letter printed on a key in this layout (for showing shortcuts).
pub fn label(code: u32) u32 {
    if (!loaded or code >= N) return usChar(code, true);
    const s = syms[code][1];
    return if (s != 0) s else syms[code][0];
}

/// Encode a code point as UTF-8 into buf; returns the bytes.
pub fn utf8(cp: u32, buf: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(@intCast(@min(cp, 0x10ffff)), buf) catch return "";
    return buf[0..n];
}

/// The key (and whether Shift is needed) that types code point cp in this
/// layout, for the headless driver's --type.
pub fn codeFor(cp: u32) ?struct { u32, bool } {
    if (!loaded) {
        var c: u32 = 0;
        while (c < 64) : (c += 1) {
            if (usChar(c, false) == cp) return .{ c, false };
            if (usChar(c, true) == cp) return .{ c, true };
        }
        return null;
    }
    for (0..N) |c| {
        if (syms[c][0] == cp) return .{ @intCast(c), false };
        if (syms[c][1] == cp) return .{ @intCast(c), true };
    }
    return null;
}
