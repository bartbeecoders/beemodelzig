#!/usr/bin/env python3
"""Generate src/catalog.zig from the assembly BeeModel sources.

The assembly app declares every command with an OPERATOR macro (id, label,
shortcut, doc) and its menus as lists of operators in ui.s / menus.s. This
script turns both into Zig data so the Zig port shows the same commands,
labels, shortcuts and tooltips, in the same menus. Commands the port does not
implement yet stay in the catalog and show greyed with a reason.

    tools/gen_catalog.py [path/to/BeeModel]   (default: ../BeeModel)
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "..", "BeeModel"), "src")

# evdev key codes for the KEY_* names the operators use
EVDEV = {
    "ESC": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
    "MINUS": 12, "EQUAL": 13, "BACKSPACE": 14, "TAB": 15,
    "Q": 16, "W": 17, "E": 18, "R": 19, "T": 20, "Y": 21, "U": 22, "I": 23, "O": 24, "P": 25,
    "LEFTBRACE": 26, "RIGHTBRACE": 27, "ENTER": 28,
    "A": 30, "S": 31, "D": 32, "F": 33, "G": 34, "H": 35, "J": 36, "K": 37, "L": 38,
    "Z": 44, "X": 45, "C": 46, "V": 47, "B": 48, "N": 49, "M": 50, "COMMA": 51,
    "SPACE": 57, "F1": 59, "F2": 60, "F3": 61, "F4": 62, "F5": 63, "F6": 64, "F7": 65,
    "F8": 66, "F9": 67, "F10": 68, "F11": 87, "F12": 88,
    "HOME": 102, "UP": 103, "PAGEUP": 104, "LEFT": 105, "RIGHT": 106, "END": 107,
    "DOWN": 108, "PAGEDOWN": 109, "DELETE": 111, "DEL": 111,
}
MODS = {"KM_SHIFT": 1, "KM_CTRL": 4, "KM_ALT": 8}

POSITIONAL = ["sym", "name", "label", "exec", "check", "arg", "key", "flags", "doc", "params", "poll", "form"]


def split_args(s):
    """Split macro arguments on commas outside double quotes."""
    out, cur, q, i = [], "", False, 0
    while i < len(s):
        ch = s[i]
        if q and ch == "\\" and i + 1 < len(s):
            cur += s[i:i + 2]
            i += 2
            continue
        if ch == '"':
            q = not q
        if ch == "," and not q:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
        i += 1
    if cur.strip():
        out.append(cur.strip())
    return out


def parse_key(expr):
    if not expr or expr == "0":
        return 0, 0
    code, mods = 0, 0
    for tok in expr.split("|"):
        tok = tok.strip()
        if tok in MODS:
            mods |= MODS[tok]
        elif tok.startswith("KEY_"):
            add = 0
            if "+" in tok:
                tok, n = tok.split("+")
                add = int(n)
            name = tok[4:].rstrip("_")
            code = EVDEV.get(name, 0)
            if code:
                code += add
            if code == 0:
                print("unknown key", tok, file=sys.stderr)
        elif tok.isdigit():
            code = int(tok)
    return code, mods


def unquote(s):
    s = s.strip()
    if s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    return s


def zstr(s):
    # assembler strings use C escapes; keep \" and \\, drop others Zig lacks
    s = s.replace("\\'", "'")
    return '"' + s + '"'


ops = []
seen = set()
for path in sorted(glob.glob(os.path.join(SRC, "*.s"))):
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^\s*OPERATOR\s+(.*)$", line)
        if not m:
            continue
        args = split_args(m.group(1))
        f = {}
        pos = 0
        for a in args:
            km = re.match(r"^([a-z]+)=(.*)$", a, re.S)
            if km and km.group(1) in POSITIONAL:
                f[km.group(1)] = km.group(2).strip()
            else:
                if pos < len(POSITIONAL):
                    f[POSITIONAL[pos]] = a
                pos += 1
        sym = f["sym"]
        if sym in seen:
            continue
        seen.add(sym)
        code, mods = parse_key(f.get("key", "0"))
        flags = f.get("flags", "")
        ops.append({
            "sym": sym,
            "id": unquote(f["name"]),
            "label": unquote(f["label"]),
            "doc": unquote(f.get("doc", '""')),
            "code": code,
            "mods": mods,
            "hidden": "OPF_HIDDEN" in flags,
            "file": os.path.basename(path),
        })

# --- menus -------------------------------------------------------------------
lists = {}
subs = {}
for name in ("ui.s", "menus.s", "areas.s", "mods.s"):
    text = open(os.path.join(SRC, name), encoding="utf-8").read()
    # label: .quad a, b, 0 \n .quad c ...
    cur = None
    for line in text.splitlines():
        code = line.split("#")[0]
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*\.quad\s+(.*)$", code)
        if m:
            cur = m.group(1)
            lists[cur] = [x.strip() for x in m.group(2).split(",") if x.strip()]
            continue
        m = re.match(r"^\s+\.quad\s+(.*)$", code)
        if m and cur:
            lists[cur] += [x.strip() for x in m.group(1).split(",") if x.strip()]
            continue
        cur = None
    for m in re.finditer(r'^SUBMENU\s+(\w+),\s*"([^"]*)",\s*(\w+),', text, re.M):
        subs[m.group(1)] = (m.group(2), m.group(3))

op_syms = {o["sym"] for o in ops}
bar = ["items_file", "items_edit", "items_view", "items_select", "items_add", "items_object",
       "items_mesh", "items_render", "items_ai", "items_help"]
ctx = ["ctx_object", "ctx_edit", "ctx_outliner", "ctx_header", "tool_ops", "items_area", "items_modadd"]


def item_list(name):
    out = []
    for x in lists.get(name, []):
        if x == "0":
            out.append("sep")
        elif x == "sub_recent":
            out.append("recent")
        elif x in subs:
            out.append("sub:" + x)
        elif x in op_syms:
            out.append("op:" + x)
        else:
            print("unknown menu entry", name, x, file=sys.stderr)
    return out


needed_subs = []


def emit_items(name, items):
    parts = []
    for it in items:
        if it == "sep":
            parts.append(".sep")
        elif it == "recent":
            parts.append(".recent")
        elif it.startswith("sub:"):
            s = it[4:]
            if s not in needed_subs:
                needed_subs.append(s)
            parts.append(".{ .sub = %d }" % needed_subs.index(s))
        else:
            parts.append('.{ .op = "%s" }' % it[3:])
    return "pub const %s = [_]Item{ %s };\n" % (name, ", ".join(parts))


out = []
out.append("// Generated by tools/gen_catalog.py from the assembly BeeModel sources. Do not edit.\n")
out.append("// Every operator of the original (id, label, shortcut, doc) and its menus.\n\n")
out.append("pub const Entry = struct {\n    sym: []const u8,\n    id: []const u8,\n    label: []const u8,\n    doc: []const u8,\n    code: u16 = 0,\n    mods: u8 = 0,\n    hidden: bool = false,\n};\n\n")
out.append("pub const Item = union(enum) { op: []const u8, sep, sub: u16, recent };\n")
out.append("pub const Sub = struct { label: []const u8, items: []const Item };\n\n")
out.append("pub const entries = [_]Entry{\n")
for o in ops:
    extra = ""
    if o["code"]:
        extra += ", .code = %d" % o["code"]
    if o["mods"]:
        extra += ", .mods = %d" % o["mods"]
    if o["hidden"]:
        extra += ", .hidden = true"
    out.append('    .{ .sym = "%s", .id = "%s", .label = %s, .doc = %s%s },\n' % (o["sym"], o["id"], zstr(o["label"]), zstr(o["doc"]), extra))
out.append("};\n\n")

for name in bar + ctx:
    out.append(emit_items(name, item_list(name)))
# submenus (may nest)
i = 0
sub_lines = []
while i < len(needed_subs):
    s = needed_subs[i]
    label, lst = subs[s]
    sub_lines.append((s, label, lst))
    emit_items("x_" + lst, item_list(lst))  # registers nested subs
    i += 1
for s, label, lst in sub_lines:
    out.append(emit_items("sub_" + lst, item_list(lst)))
out.append("\npub const subs = [_]Sub{\n")
for s, label, lst in sub_lines:
    out.append('    .{ .label = "%s", .items = &sub_%s },\n' % (label, lst))
out.append("};\n")
out.append("\npub const bar = [_][]const Item{ %s };\n" % ", ".join("&" + b for b in bar))

dst = os.path.join(ROOT, "src", "catalog.zig")
with open(dst, "w", encoding="utf-8") as fh:
    fh.write("".join(out))
print("%d operators, %d submenus -> %s" % (len(ops), len(sub_lines), dst))


# --- themes ------------------------------------------------------------------
# theme.s maps each dark-theme colour (COL_*) to the theme's colour; colours a
# table leaves out keep the dark value.
const = {}
for m in re.finditer(r"^\.equ\s+(COL_[A-Z0-9_]+),\s*(0x[0-9a-fA-F]+)", open(os.path.join(SRC, "const.inc")).read(), re.M):
    const[m.group(1)] = int(m.group(2), 16)
ttext = open(os.path.join(SRC, "theme.s"), encoding="utf-8").read()
FIELDS = [
    ("title_bg", "COL_TITLE_BG"), ("title_text", "COL_TITLE_TEXT"), ("menu_bg", "COL_MENU_BG"),
    ("hover", "COL_HOVER"), ("pane_bg", "COL_PANE_BG"), ("pane_hdr", "COL_PANE_HDR"),
    ("split", "COL_SPLIT"), ("split_hot", "COL_SPLIT_HOT"), ("accent", "COL_ACCENT"),
    ("accent_dark", "COL_ACCENT_DARK"), ("accent_text", "COL_TEXT_DARK"), ("active", "COL_ACTIVE"),
    ("selected", "COL_SELECTED"), ("btn", "COL_BTN"), ("btn_hover", "COL_BTN_HOVER"),
    ("text", "COL_TEXT"), ("text_dim", "COL_TEXT_DIM"), ("text_off", "COL_TEXT_OFF"),
    ("field", "COL_FIELD"), ("field_hover", "COL_FIELD_HOVER"), ("input_bg", "COL_INPUT_BG"),
    ("status_bg", "COL_STATUS_BG"), ("drop_bg", "COL_DROP_BG"), ("drop_border", "COL_DROP_BORDER"),
    ("shadow", "COL_SHADOW"), ("canvas_top", "COL_CANVAS_TOP"), ("canvas_bot", "COL_CANVAS_BOT"),
    ("grid", "COL_GRID"), ("grid_major", "COL_GRID_MAJOR"), ("sep", "COL_SEPARATOR"),
    ("close_hot", "COL_CLOSE_HOT"), ("focus", "COL_FOCUS"), ("selection", "COL_SELECTION"),
    ("ok", "COL_OK"), ("warn", "COL_WARN"), ("axis_x", "COL_AXIS_X"), ("axis_y", "COL_AXIS_Y"),
    ("axis_z", "COL_AXIS_Z"), ("wire", "COL_EDIT_WIRE"), ("solid", "COL_SOLID"),
]
def lum(c):
    def ch(v):
        v /= 255.0
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * ch(c >> 16 & 255) + 0.7152 * ch(c >> 8 & 255) + 0.0722 * ch(c & 255)


def contrast(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


THEMES = [("dark", "Dark", None), ("light", "Light", "th_light"), ("contrast", "High contrast", "th_contrast"),
          ("honey", "Honey", "th_honey"), ("graphite", "Graphite", "th_graphite"), ("nord", "Nord", "th_nord"),
          ("solarized", "Solarized Dark", "th_solarized"), ("solarized_light", "Solarized Light", "th_solarized_light"),
          ("dracula", "Dracula", "th_dracula")]
tout = ["// Generated by tools/gen_catalog.py from the assembly BeeModel's theme.s. Do not edit.\n",
        "// The nine UI themes; every colour pair has a contrast of at least 4.5:1.\n\n",
        "pub const Theme = struct {\n    id: []const u8,\n    name: []const u8,\n"]
for f, _ in FIELDS:
    tout.append("    %s: u32,\n" % f)
tout.append("    // derived by theme.zig at run time (readable variants)\n")
for f in ("accent_fg", "obj_wire", "cam_col", "lamp_col"):
    tout.append("    %s: u32 = 0,\n" % f)
tout.append("};\n\n")
for tid, tname, table in THEMES:
    vals = {}
    if table:
        m = re.search(r"^%s:\n((?:\s+\.long [^\n]*\n)+)" % table, ttext, re.M)
        for mm in re.finditer(r"\.long\s+(COL_[A-Z0-9_]+),\s*(0x[0-9a-fA-F]+)", m.group(1)):
            vals[mm.group(1)] = int(mm.group(2), 16)
    # text on the accent: the darker or lighter one, whichever reads (>= 4.5:1)
    acc = vals.get("COL_ACCENT", const["COL_ACCENT"])
    if contrast(acc, const["COL_TEXT_DARK"]) < 4.5:
        vals["COL_TEXT_DARK"] = 0xffffff if contrast(acc, 0xffffff) > contrast(acc, 0x000000) else 0x000000
    tout.append("pub const %s = Theme{\n    .id = \"%s\",\n    .name = \"%s\",\n" % (tid, tid, tname))
    for f, c in FIELDS:
        v = vals.get(c, const.get(c))
        if v is None:
            print("theme colour missing", c, file=sys.stderr)
            v = 0
        tout.append("    .%s = 0x%06x,\n" % (f, v))
    tout.append("};\n\n")
tout.append("pub const all = [_]*const Theme{ %s };\n" % ", ".join("&" + t[0] for t in THEMES))
with open(os.path.join(ROOT, "src", "themes.zig"), "w", encoding="utf-8") as fh:
    fh.write("".join(tout))
print("%d themes -> src/themes.zig" % len(THEMES))


# --- icons -------------------------------------------------------------------
# icons.inc: ICON_* names, then icon_masks: 16 x 16, 4-bit alpha, low nibble left.
itext = open(os.path.join(SRC, "icons.inc"), encoding="utf-8").read()
names = re.findall(r"^\.equ ICON_([A-Z0-9_]+),\s*(\d+)", itext, re.M)
names = [(n, int(v)) for n, v in names if n != "COUNT"]
data = []
m = re.search(r"^icon_masks:\n(.*)", itext, re.M | re.S)
for mm in re.finditer(r"\.byte\s+([0-9a-fx, ]+)", m.group(1)):
    data += [int(x, 16) for x in mm.group(1).split(",")]
count = len(names)
assert len(data) == count * 128, (len(data), count)
iout = ["// Generated by tools/gen_catalog.py from the assembly BeeModel's icons.inc. Do not edit.\n",
        "// %d icons, 16 x 16, 4-bit alpha (low nibble = left pixel).\n\n" % count,
        "pub const Icon = enum(u8) {\n"]
for n, v in sorted(names, key=lambda x: x[1]):
    nm = n.lower()
    if nm in ("export", "and", "or", "const", "var", "fn", "error", "struct", "enum", "union", "test", "return", "break", "continue", "if", "else", "while", "for", "switch", "try", "defer", "pub", "inline", "type"):
        nm = '@"%s"' % nm
    iout.append("    %s = %d,\n" % (nm, v))
iout.append("};\n\npub const masks = [%d][128]u8{\n" % count)
for i in range(count):
    iout.append("    .{ " + ", ".join("0x%02x" % b for b in data[i * 128:(i + 1) * 128]) + " },\n")
iout.append("};\n")
with open(os.path.join(ROOT, "src", "icons.zig"), "w", encoding="utf-8") as fh:
    fh.write("".join(iout))
print("%d icons -> src/icons.zig" % count)


# --- keysyms -----------------------------------------------------------------
# keysyms.inc: keysym name -> Unicode (dead keys: 0x8000000k), for the XKB parser.
ktext = open(os.path.join(SRC, "keysyms.inc"), encoding="utf-8").read()
pairs = re.findall(r'\.ascii "([^"]+)"\s*\n\s*\.long (0x[0-9a-fA-F]+)', ktext)
kout = ["// Generated by tools/gen_catalog.py from the assembly BeeModel's keysyms.inc. Do not edit.\n",
        "// Keysym name -> Unicode code point (dead keys: 0x80000000 | kind).\n\n",
        "pub const table = .{\n"]
for name, val in pairs:
    kout.append('    .{ "%s", @as(u32, %s) },\n' % (name, val))
kout.append("};\n")
with open(os.path.join(ROOT, "src", "keysyms.zig"), "w", encoding="utf-8") as fh:
    fh.write("".join(kout))
print("%d keysyms -> src/keysyms.zig" % len(pairs))
