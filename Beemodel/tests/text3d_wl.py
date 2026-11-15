#!/usr/bin/env python3
"""Properties > Object > Text (textui.zig), headless with --dump-ui:

  * the section's widgets: the body, the font list, the values, the lists,
    the slider, the button, one under another; the font list open: Default,
    then the system's fonts by name;
  * clicks and typing (Size typed, Align and Appear picked, a font picked from
    the list, Reveal typed, Slant typed, the body typed on, Convert to Mesh):
    the text as a script's text.set of the same values makes it; then one
    undo, two, and a redo;
  * I over a value keys it: the frame between the keys as a script's keys
    make it;
  * undo after frames: the slant goes.

    python3 tests/text3d_wl.py BIN

BEE_CPU (default 10) pins BeeModel.
"""
import os, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile
from PIL import Image, ImageChops

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
CPU = os.environ.get('BEE_CPU', '10')
FAILS = []
T = tempfile.mkdtemp(prefix='beetxwl-', dir='/tmp')
import atexit
atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, BEEMODEL_GPU='off')
ENV.pop('BEEMODEL_TEXT_FONT', None)
os.environ.pop('BEEMODEL_TEXT_FONT', None)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
HELD = []
W, H = 1280, 1000
KEEP = os.environ.get('TXWL_KEEP')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def kill_held():
    for p in HELD:
        try:
            p.kill()
            p.wait()
        except Exception:
            pass


atexit.register(kill_held)


def port(*a, shot, ui, timeout=300):
    args = ['taskset', '-c', CPU, BIN, '--size', f'{W}x{H}', '--shot', shot, '--dump-ui', ui]
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


# the section's widgets: (kind, label); None: any label (the enums: font, align, mode)
WIDGETS = [('text', None), ('enum', None), ('number', 'Size (m)'), ('number', 'Depth (m)'), ('number', 'Bevel (m)'), ('enum', None),
           ('number', 'Letter spacing (em)'), ('number', 'Line height (em)'), ('number', 'Slant'), ('number', 'Quality'), ('slider', 'Reveal'),
           ('enum', None), ('number', 'Over letters'), ('number', 'Wave (em)'), ('number', 'Wavelength (letters)'), ('number', 'Phase (turns)'),
           ('button', 'Convert to Mesh')]


def section(rows):
    """The section's widgets in WIDGETS' order: [row or None]."""
    pr = [r for r in rows if r[2] >= 1060]
    head = [r for r in pr if r[0] == 'heading' and r[1] == 'Text']
    if not head:
        return None
    below = [r for r in pr if r[3] > head[0][3]]
    out, used = [], set()
    for kind, label in WIDGETS:
        r = next((r for r in below if r[0] == kind and (label is None or r[1] == label) and id(r) not in used), None)
        if r is not None:
            used.add(id(r))
        out.append(r)
    return out


def make_scene(path, body='Hello\\nWorld', extra=' size 0.5 depth 0.1 bevel 0.01'):
    open(f'{T}/mk.bees', 'w').write('n = count()\nfor i in 0..n { delete(name(0)) }\n'
                                     f'op("text.add", "\\"{body}\\"{extra}")\nop("file.save", "{path}")\n')
    subprocess.run(['taskset', '-c', CPU, BIN, '--run', f'{T}/mk.bees'], capture_output=True, env=ENV, timeout=300)
    return os.path.exists(path)


def script(code):
    open(f'{T}/sc.bees', 'w').write(code)
    r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', f'{T}/sc.bees'], capture_output=True, text=True, env=ENV, timeout=300)
    return r.stdout


def font_names():
    """The fonts the panel lists, in its order (tf_scan, tf_before), for a HOME without fonts."""
    names = []

    def walk(d, depth):
        try:
            ents = list(os.scandir(d))
        except OSError:
            return
        for e in ents:
            if e.name.startswith('.'):
                continue
            if e.is_dir(follow_symlinks=False):
                if depth < 4:
                    walk(e.path, depth + 1)
                continue
            if len(e.name) > 4 and e.name[-4:].lower() == '.ttf':
                names.append(e.name[:-4][:63])
    for r in ('/usr/share/fonts', '/usr/local/share/fonts'):
        walk(r, 0)
    key = lambda s: bytes(c | 0x20 for c in s.encode())
    out = []
    for nm in names:   # (stable insertion)
        k = len(out)
        while k > 0 and key(nm) < key(out[k - 1]):
            k -= 1
        out.insert(k, nm)
    return out


def s_look():
    print('-- the section: its widgets, the font list')
    scene = f'{T}/look.bee'
    if not make_scene(scene):
        check(False, 'a script made the scene')
        return
    for state, setup, port_extra in (
            ('a new text', [], []),
            ('right, a named font, Scale', [('text.set', 'align right mode scale reveal 0.4 font LiberationSerif-Bold')], []),
            ('the font list open', [], [('--click-label', 'enum:Default')])):
        D = f'{T}/{state.replace(" ", "_").replace(",", "")}'
        os.makedirs(D, exist_ok=True)
        args = ['--op', f'file.open {scene}', '--select', 'Text']
        for op, a in setup:
            args += ['--op', f'{op} {a}']
        for c in port_extra:
            args += list(c)
        args += ['--move', '600,300']
        rc = port(*args, shot=f'{D}/p.ppm', ui=f'{D}/p.txt')
        check(rc == 0, f'{state}: it ran ({rc})')
        if rc != 0:
            continue
        rows = dump_rows(f'{D}/p.txt')
        if KEEP:
            shutil.copytree(D, os.path.join(KEEP, os.path.basename(D)), dirs_exist_ok=True)
        if state == 'the font list open':
            # the list: its rows' labels against the font folders' names in order
            items = [r[1] for r in rows if r[0] == 'menuitem']
            want = ['Default'] + font_names()
            check(len(items) >= 8 and items == want[:len(items)], f'the font list: Default, then the fonts by name ({items[:4]} ... {len(items)} shown)')
            continue
        sec = section(rows)
        found = [w for w, r in zip(WIDGETS, sec or []) if r]
        check(sec is not None and len(found) == len(WIDGETS), f'{state}: the section\'s {len(WIDGETS)} widgets ({len(found)} found; missing {[w for w, r in zip(WIDGETS, sec or []) if not r][:4]})')
        if sec and all(sec):
            ys = [r[3] for r in sec]
            check(ys == sorted(ys) and all(r[4] > 20 and r[5] > 10 for r in sec), f'{state}: one under another, each of a size ({ys[:6]}...)')


def records(path):
    c = beefile.chunk(path, b'TEXT') or b''
    out, o = [], 0
    while len(c) - o >= 8:
        ix, n = struct.unpack_from('<II', c, o)
        out.append(c[o + 8:o + 8 + n])
        o += 8 + n
    return out


def meshes(path):
    ms = beefile.meshes(path)
    out = {}
    for o in beefile.objects(path):
        if o['mesh'] < len(ms):
            v, p = ms[o['mesh']]
            out[o['name']] = (b''.join(struct.pack('<3f', *x) for x in v), p)
    return out


# (the widget's label, typed text | ('pick', row label) | None: the body typed on)
EDITS = [('number:Size (m)', '0.75'), ('enum:Center', ('pick', 'Right')), ('enum:Pop', ('pick', 'Scale')), ('slider:Reveal', '0.6'),
         ('enum:Default', ('pick', 3)), ('number:Slant', '0.25'), ('text:Hello\\nWorld', None)]


def s_edit():
    print('-- clicks and typing: the text as a script makes it; then undo and redo')
    scene = f'{T}/edit.bee'
    if not make_scene(scene):
        check(False, 'a script made the scene')
        return
    D = f'{T}/edit'
    os.makedirs(D, exist_ok=True)
    fonts = ['Default'] + font_names()
    clicks = []
    for w, what in EDITS:
        clicks.append(('--click-label', w))
        if isinstance(what, tuple):
            clicks.append(('--click-label', f'menuitem:{what[1] if isinstance(what[1], str) else fonts[what[1]]}'))
        elif what is not None:
            clicks += [('--key', 'backspace')] * 9 + [('--type', what), ('--key', 'enter')]
        else:   # the body: the end of it typed on
            clicks += [('--key', 'end'), ('--type', ' and more\\nthree'), ('--key', 'enter')]
    args = ['--op', f'file.open {scene}', '--select', 'Text', '--move', '600,300']
    for c in clicks:
        args += list(c)
    args += ['--move', '600,300', '--op', f'file.save_as {D}/p1.bee', '--click-label', 'button:Convert to Mesh', '--move', '600,300',
             '--op', f'file.save_as {D}/p2.bee', '--op', 'edit.undo', '--op', f'file.save_as {D}/p3.bee',
             '--op', 'edit.undo', '--op', f'file.save_as {D}/p4.bee', '--op', 'edit.redo', '--op', f'file.save_as {D}/p5.bee']
    rc = port(*args, shot=f'{D}/p.ppm', ui=f'{D}/p.txt')
    check(rc == 0, f'it ran ({rc})')
    # the same by a script: the values set, the body typed on
    script(f'op("file.open", "{scene}")\nselect("Text")\n'
           f'op("text.set", "size 0.75")\nop("text.set", "align right")\nop("text.set", "mode scale")\nop("text.set", "reveal 0.6")\n'
           f'op("text.set", "font {fonts[3]}")\nop("text.set", "slant 0.25")\nop("text.set", "\\"Hello\\\\nWorld and more\\\\nthree\\"")\n'
           f'op("file.save", "{D}/s1.bee")\n')
    have = {k: os.path.exists(f'{D}/p{k}.bee') for k in '12345'}
    r = {k: records(f'{D}/p{k}.bee') if have[k] else None for k in '12345'}
    m = {k: meshes(f'{D}/p{k}.bee') if have[k] else None for k in '12345'}
    base = records(scene)
    check(have['1'] and r['1'] and r['1'] != base, 'the clicks changed the text')
    if have['1'] and r['1']:
        body = r['1'][0][380:380 + 64].split(b'\0')[0]
        check(body == b'Hello\nWorld and more\nthree', f'the body typed on ({body})')
    ok = os.path.exists(f'{D}/s1.bee')
    rs = records(f'{D}/s1.bee') if ok else None
    d = [[i for i in range(min(len(x), len(y))) if x[i] != y[i]][:6] for x, y in zip(rs or [], r['1'] or [])]
    check(ok and rs == r['1'] and meshes(f'{D}/s1.bee') == m['1'], f'the clicks and typing: the TEXT block and mesh a script\'s text.set of the same makes ({d})')
    check(have['2'] and r['2'] == [], 'Convert to Mesh: no text left')
    check(have['3'] and r['3'] == r['1'] and m['3'] == m['1'], 'one undo: the text as before Convert to Mesh')
    b4 = r['4'][0][380:380 + 64].split(b'\0')[0] if have['4'] and r['4'] else None
    check(have['4'] and b4 == b'Hello\nWorld', f'two undos: the body as before it was typed on ({b4})')
    check(have['5'] and r['5'] == r['1'] and m['5'] == m['1'], 'a redo: the typed body again')


def s_key():
    print('-- I over a value keys it (text:<name>:<value>): the frames between as a script\'s keys make them')
    scene = f'{T}/key.bee'
    if not make_scene(scene, 'Typed on, letter by letter', ' size 0.4 mode rise soft 3'):
        check(False, 'a script made the scene')
        return
    D = f'{T}/key'
    os.makedirs(D, exist_ok=True)
    steps = [('frame', '1'), ('set', 'reveal 0'), ('key', 'text.reveal'), ('key', 'text.slant'), ('frame', '21'), ('set', 'reveal 1 slant 0.4'),
             ('key', 'text.reveal'), ('key', 'text.slant'), ('frame', '9')]
    lab = {'text.reveal': 'slider:Reveal', 'text.slant': 'number:Slant'}
    args = ['--op', f'file.open {scene}', '--select', 'Text']
    for k, a in steps:
        if k == 'frame':
            args += ['--op', f'anim.frame {a}']
        elif k == 'set':
            args += ['--op', f'text.set {a}']
        else:
            args += ['--move-label', lab[a], '--key', 'i']
    args += ['--move', '600,300', '--op', f'file.save_as {D}/p.bee']
    rc = port(*args, shot=f'{D}/p.ppm', ui=f'{D}/p.txt')
    check(rc == 0, f'it ran ({rc})')
    script(f'op("file.open", "{scene}")\nselect("Text")\nop("anim.frame", "1")\nop("text.set", "reveal 0")\n'
           'op("anim.key", "text:Text:reveal 1 0")\nop("anim.key", "text:Text:slant 1 0")\nop("anim.frame", "21")\nop("text.set", "reveal 1 slant 0.4")\n'
           'op("anim.key", "text:Text:reveal 21 1")\nop("anim.key", "text:Text:slant 21 0.4")\nop("anim.frame", "9")\n' + f'op("file.save", "{D}/s.bee")\n')
    a, b = f'{D}/s.bee', f'{D}/p.bee'
    ok = os.path.exists(a) and os.path.exists(b)
    ra, rb = (records(a), records(b)) if ok else ([], [])
    check(ok and rb and ra == rb and meshes(a) == meshes(b), 'two values keyed twice by I: frame 9\'s text as a script\'s keys make it')
    if ok and rb:
        rev, sl = struct.unpack_from('<f', rb[0], 36)[0], struct.unpack_from('<f', rb[0], 56)[0]
        check(0 < rev < 1 and 0 < sl < 0.4, f'and it is between the keys (reveal {rev:.3f}, slant {sl:.3f})')


def s_undo_frames():
    print('-- undo after frames: the slant goes; counting and keyed texts built')
    D = f'{T}/uf'
    os.makedirs(D, exist_ok=True)
    empty = f'{T}/empty.bee'
    script('n = count()\nfor i in 0..n { delete(name(0)) }\n' + f'op("file.save", "{empty}")\n')
    seq = [('text.add', '"Count {frame}" size 0.3'), ('text.add', '"Keyed" size 0.5'), ('anim.key', 'text:Text.001:reveal 1 0'),
           ('anim.key', 'text:Text.001:reveal 11 1'), ('anim.frame', '6'), ('text.set', 'slant 0.3'), ('anim.frame', '8')]
    args = ['--op', f'file.open {empty}']
    for op, a in seq:
        args += ['--op', f'{op} {a}'.strip()]
    rc = port(*args, '--op', f'file.save_as {D}/p0.bee', '--op', 'edit.undo', '--op', f'file.save_as {D}/p.bee', shot=f'{D}/p.ppm', ui=f'{D}/p.txt')
    b, b0 = f'{D}/p.bee', f'{D}/p0.bee'
    ok = rc == 0 and os.path.exists(b) and os.path.exists(b0)
    rb, r0 = (records(b), records(b0)) if ok else ([], [])
    slants = [struct.unpack_from('<f', x, 56)[0] for x in rb]
    check(ok and len(rb) == 2 and any(abs(struct.unpack_from('<f', x, 56)[0] - 0.3) < 1e-6 for x in r0) and slants == [0.0, 0.0],
          f'the slant there before the undo, gone after it ({slants})')


def main():
    s_look()
    s_edit()
    s_key()
    s_undo_frames()


main()
print(f'text3d_wl: fails {len(FAILS)}')
