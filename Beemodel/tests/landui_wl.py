#!/usr/bin/env python3
"""The Landscape tab of the Properties editor (landui.zig), BeeModel on its
own (--shot / --dump-ui, the widgets found by their kind and label):

  * the page: the two info lines, the four sections, every widget inside the
    window; the picked layer's fields for each layer type (Generate's are not
    Erode's, Terrace's, Flatten's), a section folded and opened (its widgets
    go and come), the paint layer's rule, Sea and Files;
  * the clicks (a layer's eye, a row picked and Up, Down, the island toggle,
    a typed Seed and Strength, a typed rule value, a paint layer removed,
    lists picked, Add Sea): they change the LAND blocks or the objects (bytes
    0-3, the references, and 72-75, the evaluation's time, left out); one
    undo moves the scene back a step and redo gives the same blocks again;
    undo to the start gives the opened file's blocks; leaving the tab and
    coming back shows it as before;
  * no Landscape tab when the landscape is not active.

The scene is made by BeeModel (--run).

    python3 tests/landui_wl.py BIN [runs=1]

BEE_CPU (default 12) pins BeeModel; LU_ONLY=a,b,... runs some cases;
LU_TMP: where the temporary directory goes (default /tmp).
"""
import os, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
CPU = os.environ.get('BEE_CPU', '12')
ONLY = [x for x in os.environ.get('LU_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beeland-', dir=os.environ.get('LU_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)


def _real_config():
    """The user's real ~/.config/beemodel{,-zig} (size, mtime) - found by uid,
    temphome having moved HOME: read only, to show the run left them alone."""
    import pwd
    h = pwd.getpwuid(os.getuid()).pw_dir
    out = {}
    for d in ('.config/beemodel-zig', '.config/beemodel'):
        p = os.path.join(h, d)
        if os.path.isdir(p):
            for n in sorted(os.listdir(p)):
                st = os.stat(os.path.join(p, n))
                out[f'{d}/{n}'] = (st.st_size, st.st_mtime_ns)
    return out


_REAL0 = _real_config()

# the page: right of the tab strip, below the Properties header, above the toasts
PAGE = (1051, 205, 1272, 778)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def port(*a, shot, ui, timeout=300):
    args = ['taskset', '-c', CPU, BIN, '--shot', shot, '--dump-ui', ui]
    try:
        r = subprocess.run(args + list(a), capture_output=True, text=True, timeout=timeout, env=ENV)
        if r.returncode != 0:
            print(r.stderr[-1200:])
        return r.returncode
    except subprocess.TimeoutExpired:
        return None


def dump_rows(path):
    rows = []
    for ln in open(path, errors='replace'):
        p = ln.rstrip('\n').split('\t')
        if len(p) >= 4:
            try:
                x, y, w, h = map(int, p[2].split())
            except ValueError:
                continue
            rows.append((p[0], p[1], x, y, w, h, p[3] == 'on'))
    return rows


KIND = {'float': 'number', 'int': 'number', 'toggle': 'checkbox', 'enum': 'enum', 'button': 'button', 'row': 'row', 'section': 'section', 'color': 'colour'}


def page(rows):
    """the widgets on the page, top to bottom (the toasts and chips not)"""
    return sorted((r for r in rows if PAGE[0] <= r[2] < PAGE[2] and PAGE[1] <= r[3] < PAGE[3] and r[0] not in ('toast', 'chip', 'scrollbar', 'tooltip')),
                  key=lambda r: (r[3], r[2]))


def section_y(rows, label):
    s = [r for r in page(rows) if r[0] == 'section' and r[1] == label]
    return s[0][3] if s else None


def layer_rows(rows):
    """the layer rows, the bottom layer (0) first: each has its eye left of it"""
    pg = page(rows)
    out = [r for r in pg if r[0] == 'row' and any(c[0] == 'checkbox' and c[1] == '' and c[2] < r[2] and abs(c[3] - r[3]) <= 4 for c in pg)]
    return out[::-1]


def paint_rows(rows):
    lr = layer_rows(rows)
    return [r for r in page(rows) if r[0] == 'row' and r not in lr]


def after(rows, kind, label, below):
    """the first widget of kind (and label) under y below"""
    c = [r for r in page(rows) if r[0] == kind and (label is None or r[1] == label) and (below is None or r[3] > below)]
    return c[0] if c else None


def right_of(rows, caption, kind='enum'):
    cap = [r for r in page(rows) if r[0] == 'caption' and r[1] == caption]
    if not cap:
        return None
    c = [r for r in page(rows) if r[0] == kind and abs(r[3] - cap[0][3]) <= 2 and r[2] > cap[0][2]]
    return c[0] if c else None


SECTIONS = {'landscape': 'Size and Samples', 'layers': 'Layers', 'paint': 'Paint', 'more': 'Sea and Files'}


def locate(rows, w, sub):
    """a widget by the name it has in the tab (landui.zig), as the dump shows it: the row or None"""
    pg = page(rows)
    if w.startswith('landscape.section.'):
        return after(rows, 'section', SECTIONS[w.split('.')[-1]], None)
    if w == 'landscape.layer':
        lr = layer_rows(rows)
        return lr[sub] if sub < len(lr) else None
    if w == 'landscape.layer_visible':
        lr = layer_rows(rows)
        if sub >= len(lr):
            return None
        c = [x for x in pg if x[0] == 'checkbox' and x[1] == '' and abs(x[3] - lr[sub][3]) <= 4]
        return c[0] if c else None
    if w == 'landscape.paint_layer':
        pr = paint_rows(rows)
        return pr[sub] if sub < len(pr) else None
    paint = section_y(rows, 'Paint') or 10 ** 6
    simple = {'landscape.island': ('checkbox', 'Down to the edges (an island)'), 'landscape.seed': ('number', 'Seed'),
              'landscape.layer_strength': ('number', 'Strength'), 'landscape.layer_up': ('button', 'Up'),
              'landscape.layer_down': ('button', 'Down'), 'landscape.layer_add': ('enum', 'Add Layer...'),
              'landscape.size': ('number', 'Size (m)'), 'landscape.paint_add': ('enum', 'Add Paint Layer...'),
              'landscape.paint_bounce': ('number', 'Bounce')}
    if w in simple:
        return after(rows, *simple[w], None)
    if w == 'landscape.layer_remove':
        r = after(rows, 'button', 'Remove', None)
        return r if r and r[3] < paint else None
    if w == 'landscape.paint_remove':
        return after(rows, 'button', 'Remove', paint)
    if w == 'landscape.paint_auto_btn':   # Auto Paint: right of the paint layers' Remove
        rm = after(rows, 'button', 'Remove', paint)
        c = [x for x in pg if rm and x[0] == 'button' and abs(x[3] - rm[3]) <= 2 and x[2] > rm[2]]
        return c[0] if c else None
    if w == 'landscape.paint_hhi':        # the heights' To
        cap = [x for x in pg if x[0] == 'caption' and x[1] == 'Heights (0-1)']
        return after(rows, 'number', 'To', cap[0][3]) if cap else None
    if w == 'landscape.noise':
        return right_of(rows, 'Noise')
    if w == 'landscape.samples':
        return right_of(rows, 'Samples a side')
    if w == 'landscape.detail':
        return right_of(rows, 'Display detail')
    if w == 'landscape.add_sea':          # the first of Sea and Files' buttons
        y = section_y(rows, 'Sea and Files')
        return after(rows, 'button', None, y) if y is not None else None
    raise KeyError(w)


def centre(r):
    return r[2] + r[4] // 2, r[3] + r[5] // 2


def fields(rows):
    """the picked layer's fields: what is between the layer rows and Add Layer"""
    lr = layer_rows(rows)
    add = after(rows, 'enum', 'Add Layer...', None)
    if not lr or not add:
        return []
    top = max(r[3] for r in lr)
    return [(r[0], r[1]) for r in page(rows) if top < r[3] < add[3] and r[0] in ('number', 'enum', 'checkbox', 'caption')]


def steady(rows):
    """the page as compared before and after: the evaluation's time left out"""
    return [(r[0], r[1] if not r[1].endswith(' ms') else '', *r[2:]) for r in page(rows)]


BASE = []


def state(f, clicks, tag, extra=()):
    D = f'{T}/st'
    os.makedirs(D, exist_ok=True)
    args = ['--op', f'file.open {f}', '--select', 'Landscape', '--click-label', 'tab:Landscape']
    for c in clicks:
        args += list(c)
    args += ['--move', '600,300', *extra]
    rc = port(*args, shot=f'{D}/{tag}.ppm', ui=f'{D}/{tag}.txt')
    return rc, (dump_rows(f'{D}/{tag}.txt') if rc == 0 else [])


def walk(f, name, steps):
    """the clicks, each widget found in the page as it is then: (clicks, the last page)"""
    clicks = []
    rc, rows = state(f, clicks, 'w')
    for st in steps:
        w, sub = st[0], st[1]
        text = st[2] if len(st) > 2 else None
        r = locate(rows, w, sub)
        if r is None:
            continue
        x, y = centre(r)
        check(0 < y < 778, f'{name}: {w} {sub} in the window ({x}, {y})')
        clicks.append(('--click', f'{x},{y}'))
        if isinstance(text, tuple):
            clicks.append(('--click-label', f'menuitem:{text[2]}'))
        elif text is not None:
            clicks += [('--type', text), ('--key', '28')]
        rc, rows = state(f, clicks, 'w')
        check(rc == 0, f'{name}: BeeModel ran after {w} {sub} ({rc})')
        if rc != 0:
            break
    return clicks, rows


def look(name, rows):
    pg = page(rows)
    info = [r for r in pg if r[0] == 'info']
    check(len(info) >= 2, f'{name}: the two info lines are there')
    secs = [r[1] for r in pg if r[0] == 'section']
    # (the last may be below the window, the page scrolled)
    check(len(secs) >= 3 and secs == list(SECTIONS.values())[:len(secs)], f'{name}: the sections in order ({secs})')
    out = [r[:6] for r in pg if r[2] + r[4] > 1280 or r[3] + r[5] > 800]
    check(not out, f'{name}: every widget inside the window ({out[:3]})')


SCENE = ('n = count()\nfor i in 0..n { delete(name(0)) }\n'
         'op("landscape.add", "hills res 65 size 50 seed 3")\n'
         'op("landscape.layer", "add terrace steps 5")\n'
         'op("landscape.layer", "add flatten height 2 at 3 3 8")\n'
         'op("landscape.layer", "hide 2")\n'
         'op("landscape.paint", "add grass")\n'
         'op("landscape.paint", "add rock colour 0.5 0.4 0.3 friction 0.9")\n'
         'op("landscape.paint", "auto")\n'
         'op("file.save_as", "{f}")')

# name, the widgets to click after the tab (by name, sub), in order
CASES = [
    ('generate', []),                                           # (the first layer picked)
    ('erode', [('landscape.layer', 1)]),
    ('terrace', [('landscape.layer', 2)]),
    ('flatten', [('landscape.layer', 3)]),
    ('paint2', [('landscape.section.layers', 0), ('landscape.paint_layer', 1)]),
    ('sizes', [('landscape.section.landscape', 0), ('landscape.section.layers', 0)]),
    ('more', [('landscape.section.layers', 0), ('landscape.section.paint', 0), ('landscape.section.more', 0)]),
]


def run_case(f, name, steps):
    clicks, rows = walk(f, name, steps)
    check(bool(rows), f'{name}: BeeModel ran')
    if not rows:
        return
    look(name, rows)
    if name == 'generate':
        BASE[:] = fields(rows)
        check(('number', 'Seed') in BASE and ('caption', 'Noise') in BASE, f'{name}: Generate\'s fields ({BASE})')
    elif name in ('erode', 'terrace', 'flatten'):
        fl = fields(rows)
        check(fl and fl != BASE, f'{name}: the picked layer\'s own fields, not Generate\'s ({fl})')
    elif name == 'paint2':
        check(not layer_rows(rows), f'{name}: Layers folded: no layer rows')
        check(after(rows, 'number', 'Bounce', None) and locate(rows, 'landscape.paint_hhi', 0), f'{name}: the paint layer\'s colour, friction, bounce and rule')
    elif name == 'sizes':
        check(after(rows, 'number', 'Size (m)', None) and right_of(rows, 'Samples a side'), f'{name}: Size and Samples opened: the size, the samples')
        check(not layer_rows(rows), f'{name}: Layers folded: no layer rows')
        info = [r[1] for r in page(rows) if r[0] == 'info']
        sm = right_of(rows, 'Samples a side')
        n = info[0].split(' x ')[0] if info else '?'
        check(sm is not None and sm[1] == n, f'{name}: Samples a side shows the landscape\'s {n} ({sm[1] if sm else None})')
    elif name == 'more':
        y = section_y(rows, 'Sea and Files')
        n = len([r for r in page(rows) if r[0] == 'button' and y is not None and r[3] > y])
        check(n >= 3, f'{name}: Sea and Files opened: its buttons ({n})')


def lands(path):
    """The LAND blocks (references and evaluation time left out), and the
    objects' names."""
    c = beefile.chunk(path, b'LAND') or b''
    out, o = [], 0
    while len(c) - o >= 8:
        ix, nb = struct.unpack_from('<II', c, o)
        b = bytearray(c[o + 8:o + 8 + nb])
        b[0:4] = b'\0' * 4
        b[72:76] = b'\0' * 4
        out.append(bytes(b))
        o += 8 + nb
    ob = beefile.chunk(path, b'OBJS')
    n = struct.unpack_from('<I', ob, 0)[0]
    names = sorted(ob[4 + k * 84:4 + k * 84 + 32].split(b'\0')[0].decode() for k in range(n))
    return out, names


def diff_at(a, b):
    if len(a) != len(b):
        return f'{len(a)} vs {len(b)} blocks'
    for x, y in zip(a, b):
        if x != y:
            d = [i for i in range(min(len(x), len(y))) if x[i] != y[i]]
            return f'{len(x)} vs {len(y)} bytes, first apart at {d[:3]}'
    return 'same'


# the edits: (widget name, sub, text to type then Enter, or None: a click)
EDITS = {
    'layers': [('landscape.layer_visible', 1, None),        # the Erode layer hidden
               ('landscape.layer', 0, None),                 # Generate picked
               ('landscape.island', 0, None),                # an island
               ('landscape.seed', 0, '7'),                   # Seed typed
               ('landscape.layer_strength', 0, '0.75'),      # Strength typed
               ('landscape.layer_up', 0, None),              # up the stack
               ('landscape.layer_down', 0, None)],           # and down again
    'paint': [('landscape.section.layers', 0, None),
              ('landscape.paint_layer', 1, None),            # Rock picked
              ('landscape.paint_hhi', 0, '0.625'),           # its rule typed
              ('landscape.paint_bounce', 0, '0.3'),
              ('landscape.paint_layer', 0, None),            # Grass picked
              ('landscape.paint_remove', 0, None)],          # and removed
    # lists: (widget, sub, ('pick', item index, its label))
    'lists': [('landscape.layer_add', 0, ('pick', 3, 'Terrace')),       # a Terrace layer on top
              ('landscape.noise', 0, ('pick', 1, 'Ridged')),            # Generate's noise
              ('landscape.section.landscape', 0, None),
              ('landscape.samples', 0, ('pick', 1, '129')),             # resampled
              ('landscape.detail', 0, ('pick', 0, '65')),
              ('landscape.size', 0, '60'),
              ('landscape.section.layers', 0, None),
              ('landscape.paint_add', 0, ('pick', 3, 'Sand')),
              ('landscape.paint_auto_btn', 0, None)],
    'sea': [('landscape.section.layers', 0, None),
            ('landscape.section.paint', 0, None),
            ('landscape.section.more', 0, None),
            ('landscape.add_sea', 0, None),                  # (its own undo step)
            ('landscape.layer_remove', 0, None)],            # (folded: not there)
}


def s_edit(f, name):
    D = f'{T}/{name}'
    os.makedirs(D, exist_ok=True)
    clicks, rows = walk(f, name, EDITS[name])
    check(bool(rows), f'{name}: BeeModel ran the clicks')
    if not rows:
        return
    undo_all = []
    for _ in range(30):
        undo_all += ['--op', 'edit.undo']
    ops = ['--op', f'file.save_as {D}/p1.bee', '--op', 'edit.undo', '--op', f'file.save_as {D}/p2.bee',
           '--op', 'edit.redo', '--op', f'file.save_as {D}/p3.bee']
    rc, before = state(f, clicks, 'b', ops + ['--select', 'Landscape'])
    check(rc == 0, f'{name}: saved, undone, redone ({rc})')
    rc2, back = state(f, clicks, 'c', ops + ['--select', 'Landscape', '--click-label', 'tab:Object', '--click-label', 'tab:Landscape'])
    check(rc2 == 0, f'{name}: and to the Object tab and back ({rc2})')
    rc3, _ = state(f, clicks, 'd', undo_all + ['--op', f'file.save_as {D}/p4.bee'])
    if rc != 0 or not all(os.path.exists(f'{D}/p{k}.bee') for k in '1234'):
        check(False, f'{name}: the four files saved')
        return
    base = lands(f)
    a1, a2, a3, a4 = (lands(f'{D}/p{k}.bee') for k in '1234')
    check(a1 != base, f'{name}: the clicks changed the landscape ({diff_at(base[0], a1[0])}; {base[1]} / {a1[1]})')
    check(a2 != a1, f'{name}: one undo moves it back a step ({diff_at(a1[0], a2[0])})')
    check(a3 == a1, f'{name}: redo gives the same blocks and objects again ({diff_at(a1[0], a3[0])})')
    check(a4 == base, f'{name}: undo to the start gives the opened file\'s ({diff_at(base[0], a4[0])}; {base[1]} / {a4[1]})')
    check(steady(back) == steady(before), f'{name}: leaving the tab and coming back shows it as before')
    if name == 'paint':   # Grass picked and removed: Rock stays
        pr = [r[1] for r in paint_rows(before)]
        check('Grass' not in pr and 'Rock' in pr, f'{name}: the picked paint layer removed, the other kept ({pr})')
    look(f'{name} (back on the tab)', back)


def s_hidden(f):
    """Not a landscape active: no Landscape tab, the Object page."""
    D = f'{T}/hidden'
    os.makedirs(D, exist_ok=True)
    rc = port('--op', f'file.open {f}', '--op', 'create.cube', '--move', '600,300', shot=f'{D}/p.ppm', ui=f'{D}/p.txt')
    check(rc == 0, f'hidden: BeeModel ran ({rc})')
    rows = dump_rows(f'{D}/p.txt')
    check(not [r for r in rows if r[0] == 'tab' and r[1] == 'Landscape'], 'hidden: no Landscape tab when a cube is active')
    rc = port('--op', f'file.open {f}', '--select', 'Landscape', '--move', '600,300', shot=f'{D}/q.ppm', ui=f'{D}/q.txt')
    rows = dump_rows(f'{D}/q.txt')
    check([r for r in rows if r[0] == 'tab' and r[1] == 'Landscape'], 'hidden: the Landscape tab when the landscape is active')


def main():
    f = f'{T}/land.bee'
    open(f'{T}/scene.bees', 'w').write(SCENE.replace("{f}", f) + '\n')
    r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', f'{T}/scene.bees'], capture_output=True, text=True, timeout=300, env=ENV)
    check(os.path.exists(f), f'BeeModel made the scene (--run: {r.returncode}{r.stderr.strip()[-120:]})')
    if not os.path.exists(f):
        return
    for _ in range(RUNS):
        for name, cl in CASES:
            if ONLY and name not in ONLY:
                continue
            run_case(f, name, cl)
        for name in EDITS:
            if ONLY and name not in ONLY:
                continue
            s_edit(f, name)
        if not ONLY or 'hidden' in ONLY:
            s_hidden(f)


if __name__ == '__main__':
    print(f'landui_wl: runs {RUNS}, binary {BIN}')
    try:
        main()
    finally:
        if not os.environ.get('LU_KEEPTMP'):
            shutil.rmtree(T, ignore_errors=True)
        _now = _real_config()
        _moved = [k for k in set(_REAL0) | set(_now) if _REAL0.get(k) != _now.get(k)]
        check(not _moved, f'the user\'s ~/.config untouched by the run ({", ".join(_moved) or "nothing moved"})')
    print(f'landui_wl fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)
