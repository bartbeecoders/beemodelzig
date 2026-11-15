#!/usr/bin/env python3
"""The Particles tab of the Properties editor (partui.zig) and particles in the
viewport (partdraw.zig), BeeModel on its own (--shot / --dump-ui, the widgets
found by their kind and label):

  * the page: the system's line, the six sections in order, every widget
    inside the window; no systems: the hint; sections folded and opened (their
    widgets go and come);
  * clicks (Collide on, Liquid opened and on): the PSYS chunk changed, one
    undo, then the second (the records as they were);
  * the particles drawn: points and sprites (a ramp, an end size) at a frame,
    the pixels they change (the window against itself without them).

The scene is made by BeeModel (--run).

    python3 tests/particles_wl.py BIN [runs=1]

BEE_CPU (default 14) pins BeeModel; PW_ONLY=a,b,... runs some cases.
"""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
from PIL import Image

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
CPU = os.environ.get('BEE_CPU', '14')
ONLY = [x for x in os.environ.get('PW_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beepartwl-', dir='/tmp')
os.environ['BEEMODEL_GPU'] = 'off'  # (the CPU's pictures)
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)

# the page: right of the tab strip, below the Properties header, above the toasts
PAGE = (1051, 205, 1272, 778)
SECTIONS = ['Emission', 'Motion', 'Look', 'Collisions', 'Liquid', 'Cache']


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def port(*a, shot, ui, timeout=300):
    args = ['taskset', '-c', CPU, BIN, '--shot', shot, '--dump-ui', ui]
    try:
        r = subprocess.run(args + list(a), capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.returncode
    except subprocess.TimeoutExpired:
        return None


def dump_rows(path):
    rows = []
    for ln in open(path, errors='replace') if os.path.exists(path) else []:
        p = ln.rstrip('\n').split('\t')
        if len(p) >= 4:
            try:
                x, y, w, h = map(int, p[2].split())
            except ValueError:
                continue
            rows.append((p[0], p[1], x, y, w, h, p[3] == 'on'))
    return rows


def page(rows):
    return sorted((r for r in rows if PAGE[0] <= r[2] < PAGE[2] and PAGE[1] <= r[3] < PAGE[3] and r[0] not in ('toast', 'chip', 'scrollbar', 'tooltip')),
                  key=lambda r: (r[3], r[2]))


def find(rows, kind, label):
    c = [r for r in page(rows) if r[0] == kind and r[1] == label]
    return c[0] if c else None


def centre(r):
    return f'{r[2] + r[4] // 2},{r[3] + r[5] // 2}'


# (name, kind and label of each widget to click, in order: found in the page as it is then)
NAMES = {'particles.section.emission': ('section', 'Emission'), 'particles.section.motion': ('section', 'Motion'),
         'particles.section.look': ('section', 'Look'), 'particles.section.collisions': ('section', 'Collisions'),
         'particles.section.liquid': ('section', 'Liquid'), 'particles.section.cache': ('section', 'Cache'),
         'particles.collide': ('checkbox', 'Collide'), 'particles.liquid': ('checkbox', 'Liquid')}


def walk(f, name, obj, widgets, tag='w', extra=()):
    D = f'{T}/{name}'
    os.makedirs(D, exist_ok=True)
    clicks = ['--op', f'file.open {f}', '--select', obj, '--click-label', 'tab:Particles']
    rc = port(*clicks, '--move', '600,300', shot=f'{D}/{tag}.ppm', ui=f'{D}/{tag}.txt')
    rows = dump_rows(f'{D}/{tag}.txt')
    for w in widgets:
        r = find(rows, *NAMES[w])
        check(r is not None and r[3] < 778, f'{name}: {w} in the window ({r and r[2:4]})')
        if r is None:
            return rc, rows, clicks
        clicks += ['--click', centre(r)]
        rc = port(*clicks, '--move', '600,300', shot=f'{D}/{tag}.ppm', ui=f'{D}/{tag}.txt')
        rows = dump_rows(f'{D}/{tag}.txt')
    if extra:
        rc = port(*clicks, '--move', '600,300', *extra, shot=f'{D}/{tag}.ppm', ui=f'{D}/{tag}.txt')
        rows = dump_rows(f'{D}/{tag}.txt')
    return rc, rows, clicks


def look(name, rows):
    pg = page(rows)
    out = [r[:6] for r in pg if r[2] + r[4] > 1280 or r[3] + r[5] > 800]
    check(not out, f'{name}: every widget inside the window ({out[:3]})')


def below(rows, label):
    """the widgets under a section, down to the next one"""
    pg = page(rows)
    ys = [r[3] for r in pg if r[0] == 'section']
    s = find(rows, 'section', label)
    if s is None:
        return None
    nxt = min([y for y in ys if y > s[3]], default=10 ** 6)
    return [r for r in pg if s[3] < r[3] < nxt and r[0] != 'section']


SCENE = ('add("sphere", "Emit", 0, 0.5, 0)\nscale("Emit", 0.3, 0.3, 0.3)\n'
         'select("Emit")\nemit("Emit", "fountain")\nemit("Emit", "tank")\nemit("Emit", "from faces rate 300 draw points point_px 3 color ff8000 color_end 0080ff collide on name Dots")\n'
         'select("Cube")\n'
         'op("file.save_as", "{f}")')

# name, object, sections to open / fold (in order)
CASES = [
    ('none', 'Cube', []),
    ('fountain', 'Emit', []),
    ('folded', 'Emit', ['particles.section.emission', 'particles.section.motion', 'particles.section.collisions', 'particles.section.liquid', 'particles.section.cache']),
    ('look', 'Emit', ['particles.section.emission', 'particles.section.motion', 'particles.section.look', 'particles.section.collisions', 'particles.section.cache']),
]


def run_case(f, name, obj, opens):
    rc, rows, _ = walk(f, name, obj, opens)
    check(rc == 0, f'{name}: BeeModel ran ({rc})')
    if rc != 0:
        return
    look(name, rows)
    info = [r[1] for r in page(rows) if r[0] == 'info']
    secs = [r[1] for r in page(rows) if r[0] == 'section']
    if name == 'none':
        check(not secs and any('No particle systems' in i for i in info), f'{name}: no systems: no sections, the hint ({info})')
        return
    check(any(i.startswith('System 1 of 3') for i in info), f'{name}: the system\'s line ({info})')
    check(secs == SECTIONS[:len(secs)] and len(secs) >= 3, f'{name}: the sections in order ({secs})')
    if name == 'fountain':
        check(below(rows, 'Emission') and below(rows, 'Motion') and not below(rows, 'Collisions'), f'{name}: Emission, Motion open, Collisions folded at first')
    if name == 'folded':
        check(secs == SECTIONS and not below(rows, 'Emission') and not below(rows, 'Motion'), f'{name}: Emission and Motion folded')
        check(find(rows, 'checkbox', 'Collide') is not None, f'{name}: Collisions opened: Collide')
    if name == 'look':
        check(not below(rows, 'Look') and find(rows, 'checkbox', 'Collide') is not None, f'{name}: Look folded, Collisions opened')


def s_edit(f):
    """Clicks, saved; then undone, saved again."""
    import beefile
    name = 'edit'
    D = f'{T}/{name}'
    os.makedirs(D, exist_ok=True)
    ws = ('particles.section.emission', 'particles.section.motion', 'particles.section.collisions', 'particles.collide', 'particles.section.liquid', 'particles.liquid')
    rc, rows, clicks = walk(f, name, 'Emit', ws, extra=('--op', f'file.save_as {D}/p1.bee', '--op', 'edit.undo', '--op', f'file.save_as {D}/p2.bee',
                                                        '--op', 'edit.undo', '--op', f'file.save_as {D}/p3.bee'))
    check(rc == 0, f'{name}: BeeModel ran ({rc})')
    base = beefile.chunk(f, b'PSYS')
    got = [beefile.chunk(f'{D}/p{k}.bee', b'PSYS') if os.path.exists(f'{D}/p{k}.bee') else None for k in '123']
    check(got[0] is not None and got[0] != base, f'{name}: the clicks changed the records')
    check(got[1] is not None and got[1] not in (got[0], base), f'{name}: one undo: Liquid off again, Collide still on')
    check(got[2] == base, f'{name}: two undos: the records as they were')


def drawn(f, frame):
    """The window at the frame with its particles, and without them (the
    systems switched off: the same frame): the pixels the particles change."""
    D = f'{T}/draw'
    os.makedirs(D, exist_ok=True)
    VIEW = (212, 86, 1026, 628)
    # (the tank's surface left out)
    a = ['--op', f'file.open {f}', '--select', 'Emit', '--op', 'particles.set system 2 off', '--op', f'anim.frame {frame}', '--move', '1200,780']
    rc1 = port(*a, shot=f'{D}/p1.ppm', ui=f'{D}/p1.txt')
    rc0 = port(*a, '--op', 'particles.set system 1 off', '--op', 'particles.set system 3 off', '--op', f'anim.frame {frame}', shot=f'{D}/p0.ppm', ui=f'{D}/p0.txt')
    check(rc1 == 0 and rc0 == 0, f'drawn: BeeModel ran ({rc1}, {rc0})')
    if rc1 != 0 or rc0 != 0:
        return
    A, B = Image.open(f'{D}/p1.ppm').convert('RGB').crop(VIEW), Image.open(f'{D}/p0.ppm').convert('RGB').crop(VIEW)
    pa, pb = A.load(), B.load()
    mp = {(x, y): pa[x, y] for y in range(A.size[1]) for x in range(A.size[0]) if max(abs(pa[x, y][c] - pb[x, y][c]) for c in range(3)) > 12}
    warm = sum(1 for c in mp.values() if c[0] > c[2] + 40)
    cool = sum(1 for c in mp.values() if c[2] > c[0] + 40)
    print(f'    the particles change {len(mp)} pixels ({warm} warm, {cool} cool)')
    check(len(mp) > 300, f'drawn at frame {frame}: the particles change {len(mp)} pixels')
    check(warm > 0 and cool > 0, f'the points\' colour ramp, orange to blue, shows ({warm}, {cool} pixels)')
    if os.environ.get('PW_KEEP'):
        shutil.copytree(D, os.path.join(os.environ['PW_KEEP'], 'draw'), dirs_exist_ok=True)


def main():
    f = f'{T}/parts.bee'
    open(f'{T}/scene.bees', 'w').write(SCENE.replace("{f}", f) + '\n')
    r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', f'{T}/scene.bees'], capture_output=True, text=True, timeout=300, env=ENV)
    check(os.path.exists(f), f'BeeModel made the scene (--run: {r.returncode} {r.stderr.strip()[-120:]})')
    if not os.path.exists(f):
        return
    for _ in range(RUNS):
        for name, obj, opens in CASES:
            if ONLY and name not in ONLY:
                continue
            run_case(f, name, obj, opens)
        if not ONLY or 'edit' in ONLY:
            s_edit(f)
        if not ONLY or 'draw' in ONLY:
            drawn(f, 18)


if __name__ == '__main__':
    print(f'particles_wl: runs {RUNS}, binary {BIN}')
    try:
        main()
    finally:
        shutil.rmtree(T, ignore_errors=True)
    print(f'particles_wl fails {len(FAILS)}')
    print(f'... fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)
