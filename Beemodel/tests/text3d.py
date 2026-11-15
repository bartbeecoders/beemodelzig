#!/usr/bin/env python3
"""3D text (text3d.zig, ttfol.zig): the same steps as a BeeScript script (--run)
and as console operators give the same texts:

  * fixed cases and random sessions of text.add / text.set (bodies in ASCII,
    Latin, Greek, Cyrillic, CJK and emoji the fonts lack, control characters,
    several lines; size, depth, bevel, spacing, line, slant, quality, align,
    reveal and its modes, soft, wave, wavelength, phase; fonts by path and by
    name, a missing one, the default) in several fonts present here
    (FONTS below): every mesh vertex and polygon bit for bit, the TEXT
    chunk byte for byte (the block, the hash of what it was built from, the
    bytes left after the strings' ends);
  * the 8x16 block font (BEEMODEL_TEXT_FONT=none) and a font by
    BEEMODEL_TEXT_FONT;
  * bodies that count: {frame}, {time}, {fps}, expressions, {{ }}, ones not
    understood, through frames;
  * the keyed channels (text:<name>:<value>) through frames;
  * the TEXT chunk saved, opened and saved again, and damaged; text.to_mesh;
    undo and redo;
  * random sessions on the debug build (no crash, no hang), a text too big
    to build whole, and the time of a long text (TX_REL, one CPU).

    python3 tests/text3d.py BIN [runs=6] [seed]

BEE_CPU (default 10) pins every run; TX_ONLY=s_fixed,s_files ... runs some;
TX_REL=path: a release build for the timing (else BIN).
"""
import os, random, re, struct, subprocess, sys, tempfile, shutil, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 6
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '10')
ONLY = [x for x in os.environ.get('TX_ONLY', '').split(',') if x]
REL = os.environ.get('TX_REL', BIN)
FAILS = []
T = tempfile.mkdtemp(prefix='beetext-', dir='/tmp')
import atexit
atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, XDG_CACHE_HOME='', BEEMODEL_GPU='off')
ENV.pop('BEEMODEL_TEXT_FONT', None)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
print(f'seed {SEED}')

# the fonts read (files on this machine): by path, and by name
# through the font list (the folders' .ttf files)
FONTS = [p for p in ('/usr/share/fonts/noto/NotoSans-Regular.ttf',             # (the default: the UI's sans)
                     '/usr/share/fonts/liberation/LiberationSans-Regular.ttf',
                     '/usr/share/fonts/liberation/LiberationSerif-BoldItalic.ttf',
                     '/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf',
                     '/usr/share/fonts/noto/NotoSerif-Regular.ttf',
                     '/usr/share/fonts/omarchy/omarchy.ttf') if os.path.exists(p)]
NAMES = ['LiberationMono-Bold', '"Liberation Serif"', 'NotoSansMono-Regular', 'liberation_sans_italic', '"No Such Font"', 'default']
print('fonts:', ', '.join(FONTS))


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


# ---- a script, the console -------------------------------------------------------------------------

def bee(code, timeout=600, env=None):
    """A BeeScript script (--run): its stdout."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=env or ENV)
    except subprocess.TimeoutExpired:
        check(False, 'the script hung')
        return ''
    return r.stdout


def port(*a, binary=None, timeout=600, ok=True, env=None):
    if os.path.exists(f'{T}/log.txt'):
        os.remove(f'{T}/log.txt')
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary or BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *a],
                           capture_output=True, text=True, timeout=timeout, env=env or ENV)
    except subprocess.TimeoutExpired:
        check(False, f'BeeModel hung: {a[:6]}')
        return None
    if ok and r.returncode != 0:
        print(r.stderr[-1500:])
        check(False, f'BeeModel stopped ({r.returncode}): {a[:6]}')
    return r


def plog():
    return open(f'{T}/log.txt', errors='replace').read() if os.path.exists(f'{T}/log.txt') else ''


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')


EMPTY = f'{T}/empty.bee'


def make_empty():
    bee('n = count()\nfor i in 0..n { delete(name(0)) }\n' + f'op("file.save", "{EMPTY}")\n')
    return os.path.exists(EMPTY)


# ---- files ---------------------------------------------------------------------------------------

def text_records(path):
    """The TEXT chunk's records: (mesh index, bytes, block)."""
    c = beefile.chunk(path, b'TEXT') or b''
    out, o = [], 0
    while len(c) - o >= 8:
        ix, n = struct.unpack_from('<II', c, o)
        if n > len(c) - o - 8:
            break
        out.append((ix, n, c[o + 8:o + 8 + n]))
        o += 8 + n
    return out


def scene_of(path):
    """{name: (verts as bytes, polygons, text block or None, place)} of a saved file."""
    objs = beefile.objects(path)
    ms = beefile.meshes(path)
    tx = {ix: blk for ix, n, blk in text_records(path)}
    out = {}
    for o in objs:
        mi = o['mesh']
        if mi >= len(ms):
            continue
        v, p = ms[mi]
        out[o['name']] = (b''.join(struct.pack('<3f', *x) for x in v), p, tx.get(mi), o['loc'])
    return out


def compare(a, b, what, quiet=False):
    if not (os.path.exists(a) and os.path.exists(b)):
        check(False, f'{what}: the two saved ({os.path.exists(a)}, {os.path.exists(b)})')
        return False
    sa, sb = scene_of(a), scene_of(b)
    bad = []
    if sorted(sa) != sorted(sb):
        bad.append(f'objects {sorted(sa)} / {sorted(sb)}')
    nv = 0
    for k in sa:
        if k not in sb:
            continue
        x, y = sa[k], sb[k]
        nv += len(x[0]) // 12
        if x[0] != y[0]:
            d = next((i for i in range(0, min(len(x[0]), len(y[0])), 12) if x[0][i:i + 12] != y[0][i:i + 12]), None)
            bad.append(f'{k}: vertices ({len(x[0]) // 12} / {len(y[0]) // 12}, first difference at {None if d is None else d // 12})')
        if x[1] != y[1]:
            bad.append(f'{k}: polygons ({len(x[1])} / {len(y[1])})')
        if (x[2] is None) != (y[2] is None):
            bad.append(f'{k}: text {x[2] is not None} / {y[2] is not None}')
        elif x[2] is not None and x[2] != y[2]:
            d = [i for i in range(min(len(x[2]), len(y[2]))) if x[2][i] != y[2][i]]
            bad.append(f'{k}: text block ({len(x[2])} / {len(y[2])} bytes, first differences at {d[:6]})')
        if x[3] != y[3]:
            bad.append(f'{k}: place {x[3]} / {y[3]}')
    ok = not bad and len(sa) > 0
    if not quiet or not ok:
        check(ok, f'{what}: {len(sa)} objects, {nv} vertices, meshes and texts the same' + (f' -- {bad[:4]}' if bad else ''))
    return ok


def bees_of(steps, out):
    code = ''
    for s in steps:
        op, _, a = s.partition(' ')
        if op == 'select':
            code += f'select("{a}")\n'
            continue
        code += f'op("{op}", "{esc(a)}")\n' if a else f'op("{op}")\n'
    return code + f'op("file.save", "{out}")\n'


def run_session(steps, tag, env=None, port_extra=()):
    """The steps from the empty scene as a script and as console operators:
    (the script's file, the console's file, the script's output, the console's log)."""
    a = f'{T}/{tag}-o.bee'
    b = f'{T}/{tag}-p.bee'
    for f in (a, b):
        if os.path.exists(f):
            os.remove(f)
    out = bee(f'op("file.open", "{EMPTY}")\n' + bees_of(steps, a), env=env)
    args = ['--op', f'file.open {EMPTY}']
    for s in steps:
        args += ['--select', s[7:]] if s.startswith('select ') else ['--op', s]
    args += list(port_extra) + ['--op', f'file.save_as {b}']
    port(*args, env=env)
    return a, b, out, plog()


# ---- fixed cases ---------------------------------------------------------------------------------

BODIES = [
    'Hello', 'BeeModel 3D', 'Ünïcödé €ß ÅÆØ', 'Ελληνικά Кириллица', '你好 ☃ 🙂 x', 'a\tb\x01c', 'Line one\\nsecond\\n\\nfourth',
    'g@&%$#() {}[] .,;:!?', 'ffi fi fl 0123456789', '  spaced  ', 'iii WWW', 'O0oQ8B&', '',
]


def s_fixed():
    print('-- fixed cases: the bodies in each font, then the values')
    total = same = 0
    for fi, font in enumerate(FONTS):
        steps = []
        for k, body in enumerate(BODIES):
            steps.append(f'text.add "{body}" font {font} size {0.25 + k * 0.1:g} depth {0.05 * (k % 4):g}'
                         + [' bevel 0.01', '', ' bevel 0.03 depth 0.2', ' align left', ' align right slant 0.2', ' quality 0.25', ' quality 3 spacing 0.1 line 1.5'][k % 7])
        a, b, _, _ = run_session(steps, f'fixed{fi}')
        total += 1
        same += compare(a, b, f'{len(BODIES)} bodies in {os.path.basename(font)}')
    steps = [f'text.add "Hello" font {n}' for n in NAMES] + ['text.add Plain words make a body size 0.3', "text.add 'single' extrude 0.4 bevel 9"]
    # contours of off-curve points only (they start between the first and the last point):
    # U+2080 and U+2645 in Liberation Sans, private-use icons in JetBrains Mono Nerd Font
    # (and Liberation's glyph id array in its format 4 cmap: \u2122\u2126\u2202\u2206\u2039\u203a\u2116;
    # JetBrains Mono's plane-15 icons only in its format 12 table, the one taken)
    steps += ['text.add "x\u2080\u2645\u2080 \u2122\u2126\u2202\u2206\u2039\u203a\u2116" font /usr/share/fonts/liberation/LiberationSans-Regular.ttf bevel 0.01',
              'text.add "\ue211\ue215\ue219\ue22b\ue236 \U000f0001\U000f0002\U000f01a0" font JetBrainsMonoNerdFont-Regular depth 0.1']
    a, b, ao, pl = run_session(steps, 'names')
    compare(a, b, 'fonts by name (and one missing, the default), bare words, bevel past half the depth')
    # (a script's runs are quiet: the console's log has the words)
    nf = '  text: no such font (the default is used): No Such Font'
    check(pl.count(nf) == 1, f'a missing font says so, once ({pl.count(nf)})')
    # the values, one at a time, from text.set on one text
    vals = ['size 0', 'size -2', 'depth 0', 'depth 0.5 bevel 0.25', 'bevel 0.1', 'spacing -0.3', 'spacing 0.5', 'line 0', 'line -1',
            'slant -0.5', 'slant 1.5', 'quality 0.1', 'quality 2.5', 'quality 20', 'align left', 'align center', 'align centre', 'align right',
            'reveal 0.5', 'reveal 0.37 mode scale soft 3', 'mode rise soft 2 reveal 0.6', 'mode drop soft 0.5 reveal 0.2', 'mode typewriter reveal 0.9',
            'reveal 0 mode pop', 'reveal 1.5', 'reveal 0.5 mode scale soft 0', 'wave 0.2', 'wave 0.3 wavelength 3 phase 0.25', 'wavelength 0 wave -1',
            'phase 12.5 wave 0.1', '"new body\\nline two"', 'body size', 'text "{{brace}} }} {{"', 'font default', 'font Liberation Sans Bold',
            f'font {FONTS[1] if len(FONTS) > 1 else FONTS[0]}', 'align nowhere', 'mode fly', 'size', 'bare', 'size x']
    steps = ['text.add "Waves of text\\nfor everyone" size 0.5 depth 0.1']
    files = []
    for k, v in enumerate(vals):
        steps.append(f'text.set {v}')
    a, b, ao, pl = run_session(steps, 'vals')
    compare(a, b, f'{len(vals)} text.set steps on one text (values out of range, words not understood)')
    for w in ('nowhere', 'fly', 'bare', 'x'):
        m = f'  text: not understood: {w}\n'
        check(m in pl, f'"{m.strip()}" in the console')
    # every value at once, each a text of its own
    steps = []
    for k, v in enumerate(vals[:30]):
        steps += [f'text.add "Ab{k} Ég\\nQyz" size 0.4 depth 0.08 bevel 0.01', f'text.set {v}']
    a, b, _, _ = run_session(steps, 'vals2')
    compare(a, b, 'the values each on a text of its own')


def s_block():
    print('-- the block font (BEEMODEL_TEXT_FONT=none) and a font by BEEMODEL_TEXT_FONT')
    env = dict(ENV, BEEMODEL_TEXT_FONT='none')
    steps = [f'text.add "{b}" size {0.3 + k * 0.05:g} depth {0.1 * (k % 3):g}' for k, b in enumerate(BODIES)]
    steps += ['text.add "~!@#$%^&*()_+{}|:<>?`-=[]\\\\;\',./" align left', 'text.set reveal 0.5 mode scale soft 4 wave 0.2 slant 0.3 bevel 0.05']
    steps += ['text.add "Mixed" font ' + FONTS[-1]]
    a, b, _, _ = run_session(steps, 'block', env=env)
    compare(a, b, 'the block font: every printable character, diagonal corners, values')
    if len(FONTS) > 2:
        env = dict(ENV, BEEMODEL_TEXT_FONT=FONTS[2])
        a, b, _, _ = run_session(['text.add "Default by env"', 'text.add "x" font default', 'text.add "y" font NoSuch'], 'envf', env=env)
        compare(a, b, f'BEEMODEL_TEXT_FONT={os.path.basename(FONTS[2])}')
    env = dict(ENV, BEEMODEL_TEXT_FONT='/no/such/font.ttf')
    a, b, _, _ = run_session(['text.add "Missing env font"'], 'envm', env=env)
    compare(a, b, 'BEEMODEL_TEXT_FONT naming no font: the block font')


# ---- random sessions -----------------------------------------------------------------------------

POOL = ('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789      .,;:!?-_()&@#%'
        'éèàüöäßñçÅØæœ€£¥©®°±§¶αβγδΩЖЯ你好世界☃♥🙂') + '\n\n{}'


def rand_body(rnd):
    n = rnd.choice([0, 1, 3, 8, 15, 30])
    s = ''.join(rnd.choice(POOL) for _ in range(n))
    if rnd.random() < 0.2:
        s += rnd.choice(['{frame}', '{time}', '{fps}', '{floor(time * 2)}', '{frame / 7}', '{{x}}', '{nope}', '{1/0}', '{'])
    return s.replace('\\', '').replace('"', '').replace("'", '')


def q(rnd, lo, hi, den=16):
    return rnd.randint(int(lo * den), int(hi * den)) / den


def fmt(x):
    return ('%r' % x).rstrip('0').rstrip('.') if isinstance(x, float) else str(x)


def rand_vals(rnd):
    out = []
    for _ in range(rnd.randint(0, 5)):
        k = rnd.choice(['size', 'depth', 'bevel', 'spacing', 'line', 'quality', 'reveal', 'soft', 'wave', 'wavelength', 'phase', 'slant',
                        'align', 'mode', 'font', 'font'])
        if k == 'align':
            out.append(f'align {rnd.choice(["left", "center", "right", "centre"])}')
        elif k == 'mode':
            out.append(f'mode {rnd.choice(["pop", "scale", "rise", "drop", "typewriter"])}')
        elif k == 'font':
            out.append('font ' + rnd.choice(FONTS + NAMES[:4] + ['default']))
        else:
            lo, hi = {'size': (-0.5, 2), 'depth': (-0.1, 0.6), 'bevel': (-0.05, 0.2), 'spacing': (-0.5, 1), 'line': (-1, 3), 'quality': (0, 9),
                      'reveal': (-0.2, 1.2), 'soft': (-1, 6), 'wave': (-0.5, 0.5), 'wavelength': (-1, 12), 'phase': (-2, 2), 'slant': (-1, 1)}[k]
            out.append(f'{k} {fmt(q(rnd, lo, hi))}')
    return ' '.join(out)


def session(rnd, n):
    steps, names = [], []
    for _ in range(n):
        r = rnd.random()
        if not names or r < 0.4:
            steps.append(f'text.add "{rand_body(rnd)}" {rand_vals(rnd)}'.strip())
            names.append('Text' if not names else f'Text.{len(names):03d}')
        elif r < 0.9:
            if rnd.random() < 0.3:
                steps.append(f'select {rnd.choice(names)}')
            b = f'"{rand_body(rnd)}" ' if rnd.random() < 0.3 else ''
            steps.append(f'text.set {b}{rand_vals(rnd)}'.strip())
        elif r < 0.95:
            steps.append(f'anim.frame {rnd.randint(1, 60)}')
        else:
            steps.append('text.to_mesh')
    return steps


def s_ops(rnd):
    print('-- random sessions of text.add / text.set')
    for r in range(RUNS):
        steps = session(rnd, rnd.randint(6, 24))
        a, b, _, _ = run_session(steps, f'ops{r}')
        if not compare(a, b, f'session {r} ({len(steps)} steps)'):
            for s in steps:
                print('       ', s)


# ---- bodies that count, keyed values ----------------------------------------------------------------

def s_anim():
    print('-- {frame} bodies and keyed values (text:<name>:<value>) through frames')
    base = ['text.add "Frame {frame} at {time}s of {fps}: {floor(time)} {{x}} {frame*2+1} {bad name}" size 0.4',
            'text.add "Count {frame - 1} {frame * 1.002} {frame - 0.0004} {2.0001}" size 0.3 align left', 'text.add "Typed on" size 0.5',
            'text.add "Wavy line of text" size 0.5 wave 0.2 wavelength 4']
    keys = ['anim.key text:Text.002:reveal 1 0', 'anim.key text:Text.002:reveal 25 1', 'anim.key text:Text.003:phase 1 0',
            'anim.key text:Text.003:phase 41 1', 'anim.key text:Text.002:size 1 0.5', 'anim.key text:Text.002:size 30 0.75',
            'anim.key text:Text.001:slant 10 0.4', 'anim.key text:Text.001:quality 1 0.1', 'anim.key text:Text.001:quality 30 12',
            'anim.key text:Text.003:reveal 1 -0.5', 'anim.key text:Text.003:reveal 30 1.5']
    for fr in (1, 7, 13, 25, 33):
        steps = base + keys + [f'anim.frame {fr}']
        a, b, _, _ = run_session(steps, f'anim{fr}')
        compare(a, b, f'frame {fr}: counting bodies and keyed reveal / phase / size / slant')
    # a keyed value's mode and a range's fps; frames back and forth
    steps = base + keys + ['anim.range 1 100 30', 'select Text.002', 'text.set mode rise soft 3', 'anim.frame 9', 'anim.frame 3', 'anim.frame 18']
    a, b, _, _ = run_session(steps, 'anim-r')
    compare(a, b, 'fps 30, rise over 3 letters, frames back and forth')
    # a bad path is refused
    a, b, ao, pl = run_session(base + ['anim.key text:Text:nope 1 0', 'anim.key text:Cube:size 1 0', 'anim.key text:Text:size 1 2', 'anim.frame 1'], 'anim-bad')
    compare(a, b, 'keys on paths that name nothing are refused; one that does applies')


# ---- files -------------------------------------------------------------------------------------------

def write_bee(path, chs):
    """A version 1 file of these chunks (ZCHK inflated)."""
    out = [b'BEEM', struct.pack('<I', 1)]
    for t, b in chs:
        out += [t, struct.pack('<I', len(b)), b]
    open(path, 'wb').write(b''.join(out))


def resave_script(src, dst):
    if os.path.exists(dst):
        os.remove(dst)
    bee(f'op("file.open", "{src}")\nop("file.save", "{dst}")\n')


def resave_console(src, dst):
    if os.path.exists(dst):
        os.remove(dst)
    port('--op', f'file.open {src}', '--op', f'file.save_as {dst}')


def s_files(rnd):
    print('-- the TEXT chunk saved and opened again, and damaged; text.to_mesh')
    steps = ['text.add "First {frame}" size 0.5 bevel 0.02', 'text.add "Second line\\nthird" font ' + FONTS[-1] + ' align right',
             'text.add "Short"', 'text.set "Sh"', 'text.add "Plain soon"', 'text.to_mesh', 'text.add "Zz" font Liberation Mono',
             'select Text', 'text.set size 0.6', 'select Text.001', 'text.set size 0.7', 'select Text', 'text.set depth 0.3']   # (the first text's new mesh made last: records in the MESH chunks' order)
    a, b, _, _ = run_session(steps, 'files')
    compare(a, b, 'the files')
    ra = text_records(a)
    check(len(ra) == 4 and ra == text_records(b), f'TEXT records byte for byte ({len(ra)}, {len(text_records(b))})')
    check(beefile.chunk(a, b'TEXT') == beefile.chunk(b, b'TEXT'), 'the TEXT chunk byte for byte')
    # the script's file opened and saved from the console, the console's by a script
    ab = f'{T}/files-op.bee'
    resave_console(a, ab)
    check(text_records(ab) == ra, "the script's texts opened and saved from the console: TEXT records byte for byte")
    compare(a, ab, "the script's file resaved from the console", quiet=False)
    ba = f'{T}/files-po.bee'
    resave_script(b, ba)
    check(text_records(ba) == text_records(b), "the console's texts opened and saved by a script: TEXT records byte for byte")
    compare(b, ba, "the console's file resaved by a script")
    # a text from a file edits the same (the block's leftovers carried)
    c1, c2 = f'{T}/files-e1.bee', f'{T}/files-e2.bee'
    for f in (c1, c2):
        if os.path.exists(f):
            os.remove(f)
    bee(f'op("file.open", "{a}")\nselect("Text.002")\nop("text.set", "size 0.8 reveal 0.5")\nop("anim.frame", "5")\nop("file.save", "{c1}")\n')
    port('--op', f'file.open {a}', '--select', 'Text.002', '--op', 'text.set size 0.8 reveal 0.5', '--op', 'anim.frame 5', '--op', f'file.save_as {c2}')
    compare(c1, c2, 'texts read from a file, then edited and a frame later')

    base = list(beefile.chunks(a))
    tx = beefile.chunk(a, b'TEXT')
    rec = 8 + 4092
    cases = [('cut short', tx[:len(tx) // 2]), ('one byte', tx[:1]), ('empty', b''), ('index past the meshes', b'\xff\xff\x00\x00' + tx[4:]),
             ('a huge length', tx[:4] + struct.pack('<I', 0x7fffffff) + tx[8:]),
             ('a short block (defaults after it)', tx[:4] + struct.pack('<I', 60) + tx[8:8 + 60] + tx[rec:]),
             ('a longer block (cut)', tx[:4] + struct.pack('<I', 5000) + tx[8:rec] + b'\x55' * 908 + tx[rec:]),
             ('no terminators', tx[:8] + tx[8:8 + 124] + b'A' * 256 + b'B' * 2048 + tx[8 + 124 + 2304:]),
             ('values out of range', tx[:8 + 12] + struct.pack('<12f', -1, -1, -1, 0, 0, 99, 7, -3, 0, -5, 0, 0) + tx[8 + 60:]),
             ('NaN values', tx[:8 + 12] + struct.pack('<12f', *([float('nan')] * 12)) + tx[8 + 60:]),
             ('odd align and mode', tx[:8 + 4] + struct.pack('<II', 7, 9) + tx[8 + 12:]),
             ('two records for one mesh', tx[:rec] + tx[:rec] + tx[rec:])]
    for k in range(max(4, RUNS)):
        c = bytearray(tx)
        for _ in range(rnd.randint(1, 12)):
            c[rnd.randrange(len(c))] = rnd.randrange(256)
        cases.append((f'garbage {k}', bytes(c)))
    same = 0
    for what, c in cases:
        d = f'{T}/dmg.bee'
        write_bee(d, [(t, c if t == b'TEXT' else x) for t, x in base])
        o2, p2 = f'{T}/dmg-o.bee', f'{T}/dmg-p.bee'
        for f in (o2, p2):
            if os.path.exists(f):
                os.remove(f)
        # (read, then every text built again: text.set with nothing to change, a frame)
        code = f'op("file.open", "{d}")\n'
        args = ['--op', f'file.open {d}']
        for nm in ('Text', 'Text.001', 'Text.002', 'Text.004'):
            code += f'select("{nm}")\nop("text.set", "")\n'
            args += ['--select', nm, '--op', 'text.set']
        code += f'op("file.save", "{o2}")\n'
        bee(code)
        r = port(*args, '--op', f'file.save_as {p2}', ok=False)
        if r is None or r.returncode != 0 or not os.path.exists(p2):
            check(False, f'damaged TEXT ({what}): read and saved from the console')
            continue
        if not os.path.exists(o2):
            print(f'       (the script did not save after {what})')
            same += 1
            continue
        if compare(o2, p2, f'damaged TEXT ({what})', quiet=True) and text_records(o2) == text_records(p2):
            same += 1
        else:
            check(False, f'damaged TEXT ({what}): the same texts kept')
    check(same == len(cases), f'damaged TEXT chunks: {same} of {len(cases)} read (and built again) the same by a script and the console')


def s_undo():
    print('-- undo and redo')
    files = [f'{T}/u{k}.bee' for k in range(8)]
    for f in files:
        if os.path.exists(f):
            os.remove(f)
    seq = ['text.add "Undo me" size 0.5', 'text.set bevel 0.02 depth 0.1', 'text.set "Changed"', 'text.add "Another"', 'text.to_mesh']
    args = ['--op', f'file.open {EMPTY}']
    for k, s in enumerate(seq):
        args += ['--op', s, '--op', f'file.save_as {files[k]}']
    args += ['--key', 'ctrl+z', '--key', 'ctrl+z', '--key', 'ctrl+z', '--op', f'file.save_as {files[5]}']
    port(*args)
    ok = all(os.path.exists(files[k]) for k in (1, 5))
    check(ok and scene_of(files[5]) == scene_of(files[1]) and scene_of(files[5]) != scene_of(files[2]),
          'three undos bring back the text, its block and its mesh as they were three steps before')
    port(*(args + ['--key', 'ctrl+shift+z', '--key', 'ctrl+shift+z', '--op', f'file.save_as {files[6]}']))
    check(os.path.exists(files[6]) and scene_of(files[6]) == scene_of(files[3]), 'two redos: the second text again')
    # a keyed frame is no step: undo after frames goes back past the text.set, not a frame
    seq2 = ['text.add "Count {frame}" size 0.3', 'text.add "Keyed" size 0.5', 'anim.key text:Text.001:reveal 1 0', 'anim.key text:Text.001:reveal 11 1',
            'anim.frame 6', 'text.set slant 0.3', 'anim.frame 8']
    args = ['--op', f'file.open {EMPTY}']
    for s in seq2:
        args += ['--op', s]
    args += ['--key', 'ctrl+z', '--op', f'file.save_as {files[7]}']
    port(*args)
    o7 = f'{T}/u7-o.bee'
    if os.path.exists(o7):
        os.remove(o7)
    # (the reference: a script's scene before the slant. A counting text's block is shared with
    # the undo step and its hash moves with the frame (tests/text3d_wl.py s_undo_frames checks it
    # in the window): the hash left out here)
    bee(f'op("file.open", "{EMPTY}")\n' + bees_of(seq2[:5], o7))
    for f in (o7, files[7]):
        if os.path.exists(f):
            chs = list(beefile.chunks(f))
            tx = bytearray(beefile.chunk(f, b'TEXT'))
            o = 0
            while len(tx) - o >= 8:
                tx[o + 8 + 60:o + 8 + 68] = b'\0' * 8
                o += 8 + struct.unpack_from('<I', tx, o + 4)[0]
            write_bee(f, [(t, bytes(tx) if t == b'TEXT' else c) for t, c in chs])
    compare(o7, files[7], 'undo after frames: the slant goes, the frame keyed stays as it was (hashes left out)')


def s_fuzz(rnd):
    print('-- random operators, words and keys on the debug build: no crash, no hang')
    words = ['', 'nan', 'inf', '-inf', '1e30', '-1e30', '0', '-1', '3.5', '99999999', 'size', 'depth', 'bevel', 'quality', 'reveal', 'mode',
             'align', 'font', 'body', 'text', 'wave', 'wavelength', 'phase', 'slant', 'soft', 'spacing', 'line', '"', "'", '\\\\', '\\\\n',
             '"{frame}"', '"{', '}}', 'left', 'scale', 'drop', 'default', FONTS[0], 'Text', '/no/such.ttf', '"' + 'W' * 3000 + '"']
    ops = ['text.add', 'text.set', 'text.to_mesh', 'object.delete', 'object.duplicate', 'anim.frame', 'anim.key text:Text:reveal']
    keys = ['tab', 'g', 'r', 's', 'x', 'enter', 'esc', 'a', 'ctrl+z', 'ctrl+shift+z', 'delete', 'right', 'left']
    crashed = 0
    for run in range(max(2, RUNS)):
        args = ['--op', f'file.open {EMPTY}', '--op', 'text.add Fuzz', '--move', '600,400']
        for _ in range(rnd.randint(15, 45)):
            r = rnd.random()
            if r < 0.7:
                a = ' '.join(rnd.choice(words + [str(rnd.uniform(-5, 5))]) for _ in range(rnd.randint(0, 6)))
                args += ['--op', (rnd.choice(ops) + ' ' + a).strip()]
            elif r < 0.92:
                args += ['--key', rnd.choice(keys)]
            else:
                args += ['--click', f'{rnd.randint(300, 900)},{rnd.randint(150, 600)}']
        args += ['--op', f'file.save_as {T}/fz.bee']
        p = port(*args, ok=False, timeout=300)
        if p is None or p.returncode != 0:
            crashed += 1
            print('       ', (p.stderr[-600:] if p else 'hung'))
            print('       ', ' '.join(args)[:3000])
    check(crashed == 0, f'random text sessions: {max(2, RUNS) - crashed} of {max(2, RUNS)} ran to the end')


def s_perf(rnd):
    print('-- a long text: the same mesh from a script and the console, and its time (a release build, one CPU)')
    words = 'The quick brown fox jumps over the lazy dog while bees hum about sixty-seven glyphs, quality and bevels. '
    body = (words * 20)[:2000]
    lines = '\\n'.join(body[i:i + 80] for i in range(0, len(body), 80))
    first = 'text.add "x" size 0.2 depth 0.05 bevel 0.005 quality 2'
    # (op() takes 512 characters of argument: the body goes in through text_set)
    pre = f'op("file.open", "{EMPTY}")\nop("text.add", "{esc(first[9:])}")\n'
    oo = f'{T}/long-o.bee'
    if os.path.exists(oo):
        os.remove(oo)
    bee(pre + f'text_set("Text", "{lines}")\n' + f'op("file.save", "{oo}")\n')
    po = f'{T}/long-p.bee'
    port('--op', f'file.open {EMPTY}', '--op', first, '--op', f'text.set "{lines}"', '--op', f'file.save_as {po}')
    compare(oo, po, 'a text of 2000 characters on 25 lines, bevelled, quality 2')
    # past the build's room (2097152 vertices, 8388608 corners, 2097152 polygons): the
    # rest left out, glyph by glyph
    dense = '\\n'.join(('@&%$#WMBQ' * 9)[:80] for _ in range(25))
    big = 'text.add "x" size 0.1 depth 0.02 bevel 0.004 quality 8 font ' + FONTS[-2]
    for f in (oo, po):
        if os.path.exists(f):
            os.remove(f)
    bee(f'op("file.open", "{EMPTY}")\nop("text.add", "{esc(big[9:])}")\ntext_set("Text", "{dense}")\nop("file.save", "{oo}")\n')
    port('--op', f'file.open {EMPTY}', '--op', big, '--op', f'text.set "{dense}"', '--op', f'file.save_as {po}')
    if compare(oo, po, 'a text too big to build whole (2000 dense characters at quality 8)'):
        npl = len(beefile.meshes(oo)[0][1])
        # (half the body makes 1644484 polygons: the whole would pass 2097152)
        check(2000000 < npl <= 2097152, f'and it was cut short by the room ({npl} polygons of 2097152)')
    env = dict(ENV, BEEMODEL_TEXT_TIME='1')
    pt = []
    for _ in range(3):
        port('--op', f'file.open {EMPTY}', '--op', first, '--op', f'text.set "{lines}"', binary=REL, env=env)
        m = re.findall(r'text built in (\S+) ms', plog())
        if len(m) == 2:
            pt.append(float(m[1]))
    p = min(pt) if pt else None
    print(f'       the long text built in {p} ms ({os.path.basename(REL)})')
    check(p is not None, f'the long text built, and it says how long it took ({p} ms)')


def main():
    rnd = random.Random(SEED)
    if not make_empty():
        check(False, 'a script made an empty scene')
        return
    for name in ('s_fixed', 's_block', 's_ops', 's_anim', 's_files', 's_undo', 's_fuzz', 's_perf'):
        if ONLY and name not in ONLY:
            continue
        f = globals()[name]
        f(rnd) if name in ('s_ops', 's_files', 's_fuzz', 's_perf') else f()


main()
print(f'text3d: fails {len(FAILS)}')
