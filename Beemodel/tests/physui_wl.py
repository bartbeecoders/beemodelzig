#!/usr/bin/env python3
"""The Physics tab of the Properties editor (physui.s, simui.s), headless
(--shot, --dump-ui):

  * the page in every case: BeeModel runs it cleanly, the widgets sit inside
    the page and the window, the sections are all there by their titles, the
    info line says what the object is, and the page is drawn (text on it);
  * what a click opens shows: a joint's Limits and Motor with Rigid Body
    folded, World's Gravity and steps, Cloth World's fields, the Simulation
    Cache's "Rigid bodies: n frames" and "Cloth: n frames";
  * clicks that edit (Attracts, a joint's Limits, World's Gravity off) change
    the saved records; one undo puts World back; undo to the start puts the
    bodies, joints and world back as they were; the saved file, opened again,
    shows the hinge's limits on.

Scene (made by BeeModel with --run): a mesh that is not a body, an active box
with a hinge to a passive floor, the passive floor, a rod on a slider with
limits and a motor and an arm on a hinge with them (degrees).

    python3 tests/physui_wl.py BIN [runs=1]

BEE_CPU (default 12) pins the program; PU_ONLY=a,b,... runs some cases.
"""
import os, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile
from PIL import Image

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
CPU = os.environ.get('BEE_CPU', '12')
ONLY = [x for x in os.environ.get('PU_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beephys-', dir='/tmp')
ENV = dict(os.environ, HOME=T)

# the page: right of the tab strip, below the Properties header, above the toasts
PAGE = (1051, 205, 1272, 730)
WIN = (1280, 800)
SECTIONS = ['Rigid Body', 'Joints', 'Shatter', 'World', 'Cloth and Soft Body', 'Cloth World', 'Simulation Cache']


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def port(*a, shot, ui, timeout=300):
    args = ['taskset', '-c', CPU, BIN, '--shot', shot, '--dump-ui', ui]
    try:
        r = subprocess.run(args + list(a), capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return None, 'timeout'


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


KINDS = ('number', 'checkbox', 'enum', 'button', 'row', 'section', 'info', 'caption')


SCENE = ('n = count()\nfor i in 0..n { delete(name(0)) }\n'
         'add("cube", "Box", 0, 1, 0)\nadd("cube", "Floor", 0, -1, 0)\nadd("cube", "Rod", 3, 1, 0)\nadd("cube", "Plain", -3, 1, 0)\nadd("cube", "Arm", 0, 4, 0)\n'
         'select("Box")\nop("rigid.add", "active box mass 2")\n'
         'select("Floor")\nop("rigid.add", "passive box")\n'
         'select("Rod")\nop("rigid.add", "active capsule friction 0.9")\n'
         'op("rigid.joint", "hinge Box Floor axis 0 0 1")\n'
         'op("rigid.joint", "slider Rod world axis 1 0 0 limits -1 2 motor 0.5 10 break 300")\n'
         'select("Arm")\nop("rigid.add", "active hull")\n'
         'op("rigid.joint", "hinge Arm world axis 0 1 0 limits -45 90 motor 30 5")\n'
         'op("file.save_as", "{f}")')

# name, object, sections to click (by title), the info line starts with, what must show then
CASES = [
    ('plain', 'Plain', [], 'Not a rigid body', [('button', 'Add Rigid Body')]),
    ('active', 'Box', [], 'Active Box', [('checkbox', 'Attracts the others'), ('row', 'Hinge to Floor')]),
    ('passive', 'Floor', [], 'Passive', []),
    ('slider', 'Rod', [], 'Active Capsule', [('row', 'Slider to world')]),
    # (Rigid Body folded: the joint's limits and motor come into sight)
    ('slider2', 'Rod', ['Rigid Body'], 'Active Capsule', [('checkbox', 'Limits'), ('checkbox', 'Motor'), ('number', 'Speed (m/s)')]),
    ('hinge', 'Arm', ['Rigid Body'], 'Active Convex Hull', [('checkbox', 'Limits'), ('checkbox', 'Motor'), ('number', 'Speed (deg/s)')]),
    ('world', 'Box', ['Rigid Body', 'World'], 'Active Box', [('checkbox', 'Gravity'), ('number', 'Steps a second')]),
    ('cache', 'Plain', ['Cloth and Soft Body', 'Cloth World', 'Simulation Cache'], 'Not a rigid body',
     [('button', 'Soft Body'), ('number', 'Substeps'), ('info', 'Rigid bodies: 0 frames'), ('info', 'Cloth: 0 frames')]),
]


def run_case(f, name, obj, opens, info, want):
    D = f'{T}/{name}'
    os.makedirs(D, exist_ok=True)
    args = ['--op', f'file.open {f}', '--select', obj, '--click-label', 'Physics']
    for s in opens:
        args += ['--click-label', f'section:{s}']
    args += ['--move', '600,300']
    rc, out = port(*args, shot=f'{D}/p.ppm', ui=f'{D}/p.txt')
    check(rc == 0, f'{name}: BeeModel ran it ({rc}{" " + out.strip()[-100:] if rc else ""})')
    if rc != 0:
        return
    rows = dump_rows(f'{D}/p.txt')
    page = [r for r in rows if r[0] in KINDS and r[2] >= PAGE[0] and r[3] >= PAGE[1] and r[3] < WIN[1] - 22]
    out_of = [r[:6] for r in page if r[4] <= 0 or r[5] <= 0 or r[2] + r[4] > WIN[0] or r[3] + r[5] > WIN[1]]
    check(len(page) >= 8 and not out_of, f'{name}: {len(page)} widgets on the page, all inside the window ({out_of[:3]})')
    secs = [r[1] for r in page if r[0] == 'section']
    shown = [s for s in SECTIONS if s in secs]
    # (a section may go out at the window's bottom when the ones above are open)
    check(shown == [s for s in secs if s in SECTIONS] and secs[:1] == ['Rigid Body'] and len(shown) >= 2 and all(s in secs for s in opens),
          f'{name}: the sections in order ({", ".join(secs)})')
    il = [r[1] for r in page if r[0] == 'info']
    check(il and il[0].startswith(info), f'{name}: the info line says {info!r} ({il[:1]})')
    miss = [w for w in want if not any(r[0] == w[0] and r[1] == w[1] for r in page)]
    check(not miss, f'{name}: shows {", ".join(w[1] for w in want) or "the page"} (missing: {miss})')
    # the page is drawn: light text on it, more than a few colours
    im = Image.open(f'{D}/p.ppm').convert('RGB').crop(PAGE)
    px = im.load()
    lit = sum(1 for y in range(im.height) for x in range(im.width) if sum(px[x, y]) > 450)
    cols = len(im.getcolors(1 << 16) or [])
    check(lit > 150 and cols > 4, f'{name}: the page is drawn ({lit} text pixels, {cols} colours)')
    if os.environ.get('PU_KEEP'):
        shutil.copytree(D, os.path.join(os.environ['PU_KEEP'], name), dirs_exist_ok=True)


def anim_recs(path):
    """ANIM's bodies, joints and world, as bytes (references as uids)."""
    a = beefile.chunk(path, b'ANIM')
    if a is None:
        return None
    nrb, njt = struct.unpack_from('<II', a, 56)  # (the head less its first word, after frame and keys)
    rb = a[55908:55908 + nrb * 80]
    jt = a[55908 + nrb * 80:55908 + nrb * 80 + njt * 64]
    return rb, jt, a[55876:55908]


def s_edit(f):
    """Clicks (Attracts, a joint's Limits, Rigid Body folded, World opened,
    its Gravity off), saved: the records changed; one undo puts World back;
    undo to the start puts everything back."""
    name = 'edit'
    D = f'{T}/{name}'
    os.makedirs(D, exist_ok=True)
    args = ['--op', f'file.open {f}', '--select', 'Box', '--click-label', 'Physics',
            '--click-label', 'checkbox:Attracts the others', '--click-label', 'checkbox:Limits',
            '--click-label', 'section:Rigid Body', '--click-label', 'section:World', '--click-label', 'checkbox:Gravity',
            '--op', f'file.save_as {D}/p1.bee', '--op', 'edit.undo', '--op', f'file.save_as {D}/p2.bee']
    args += ['--op', 'edit.undo'] * 8 + ['--op', f'file.save_as {D}/p3.bee']
    rc, out = port(*args, shot=f'{D}/p.ppm', ui=f'{D}/p.txt')
    check(rc == 0, f'{name}: BeeModel ran it ({rc}{" " + out.strip()[-100:] if rc else ""})')
    if rc != 0:
        return
    base = anim_recs(f)
    p1, p2, p3 = (anim_recs(f'{D}/p{k}.bee') for k in '123')
    check(base and p1 and len(p1[0]) == len(base[0]) and len(p1[1]) == len(base[1]), f'{name}: the same bodies and joints after the clicks')
    check(p1 and base and p1[0] != base[0] and p1[1] != base[1] and p1[2] != base[2],
          f'{name}: the clicks changed a body, a joint and the world ({p1 and base and [i for i in range(3) if p1[i] == base[i]]} unchanged)')
    check(p2 and base and p2[2] == base[2] and p2[0] == p1[0] and p2[1] == p1[1], f'{name}: one undo puts the world back and nothing else')
    check(p3 == base, f'{name}: undo to the start: the bodies, joints and world as they were')
    # the saved file opened again: the hinge's limits are on (From and To show), as they were not
    def has_from(bee, tag):
        rc, out = port('--op', f'file.open {bee}', '--select', 'Box', '--click-label', 'Physics', '--click-label', 'section:Rigid Body',
                       shot=f'{D}/{tag}.ppm', ui=f'{D}/{tag}.txt')
        return rc == 0 and any(r[0] == 'number' and r[1].startswith('From') for r in dump_rows(f'{D}/{tag}.txt'))
    check(has_from(f'{D}/p1.bee', 'q1') and not has_from(f, 'q0'),
          f'{name}: opened again, the hinge has its limits on (From and To show)')


def main():
    f = f'{T}/phys.bee'
    p = f'{T}/s.bees'
    open(p, 'w').write(SCENE.replace('{f}', f) + '\n')
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=300, env=ENV)
        out = r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        out = 'timeout'
    check(os.path.exists(f), f'BeeModel made the scene ({out.strip()[-120:]})')
    if not os.path.exists(f):
        return
    for _ in range(RUNS):
        for name, obj, opens, info, want in CASES:
            if ONLY and name not in ONLY:
                continue
            run_case(f, name, obj, opens, info, want)
        if not ONLY or 'edit' in ONLY:
            s_edit(f)


if __name__ == '__main__':
    print(f'physui_wl: runs {RUNS}, binary {BIN}')
    try:
        main()
    finally:
        shutil.rmtree(T, ignore_errors=True)
    print(f'physui_wl fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)
