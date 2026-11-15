#!/usr/bin/env python3
"""Cloth and soft bodies (cloth.zig, the Physics tab's sections), BeeModel on
its own: random scenes (cloth, soft bodies, colliders, the Ground, pins above /
below a plane, self collision, wind, substeps and rate, force fields, every
setting) played to several frames: every run ends cleanly, every vertex shown
is a finite number (evsum: --print-anim evsum:NAME), clothinfo / cacheinfo are
sane, the cloth moves and collides, a scene played twice gives the same
vertices, and one CPU and many (the workers) give the same. Landscapes as
colliders, by their heights (hills moved and scaled, a raised brush, two
landscapes, a landscape and a box, a pinned cloth over a ridge, five: four at
most; keyed): each landscape makes a difference. Then the cache: going back
plays cached frames, an edit drops it (stretch, a collider moved, pins), bake,
sim.free; the SIMC and MPIN chunks read back and save -> open -> save gives the
same chunks; a baked file plays the frames it was baked with; damaged SIMC /
MPIN / cloth records are opened without a crash; the console's answers (one
for each command); undo and redo with the timeline (an undo shows the cloth as
before the step, a redo as after it); the Physics tab's cloth sections (the
widgets in the window, clicks change the records, an undo takes them back); a
fuzz on the debug build; the time a frame takes (an 81 x 81 cloth over a
sphere, release build, one CPU: the same vertices twice) and the memory over a
long run.

    python3 tests/cloth.py BIN [runs=8] [seed]

BEE_CPU (default 12) pins every run; CL_ONLY=s_sims,s_land,s_cache ... runs some;
CL_REL=release build for the timing (default: BIN); CL_THREADS=cpus for the
threaded runs (default 0-7).
"""
import math, os, pwd as _pwd, random, re, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 8
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '12')
THREADS = os.environ.get('CL_THREADS', '0-7')
REL = os.path.abspath(os.environ.get('CL_REL', BIN))
ONLY = [x for x in os.environ.get('CL_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beecl-', dir=os.environ.get('BEECL_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
ANIM_HEAD = 8 + 55904 - 4
REST_CW = 13312
REST_CL = 13344


def _real_config():
    h = _pwd.getpwuid(os.getuid()).pw_dir
    out = {}
    for d in ('.config/beemodel-zig', '.config/beemodel'):
        p = os.path.join(h, d)
        if os.path.isdir(p):
            for n in sorted(os.listdir(p)):
                st = os.stat(os.path.join(p, n))
                out[f'{d}/{n}'] = (st.st_size, st.st_mtime_ns)
    return out


_REAL0 = _real_config()


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def make(code, timeout=900, cpu=None):
    """A BeeScript run by BeeModel (--run): the scenes are made this way. Its output."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', cpu or CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        check(False, f'a scene script hung: {code[-120:]!r}')
        return ''
    if r.returncode != 0 or 'panic' in r.stderr:
        print(r.stderr[-600:])
        check(False, f'a scene script stopped ({r.returncode}): {code[-120:]!r}')
    return r.stdout


def port(*a, timeout=900, binary=None, ok=True, cpu=None):
    try:
        r = subprocess.run(['taskset', '-c', cpu or CPU, binary or BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *a],
                           capture_output=True, text=True, timeout=timeout, env=ENV)
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
    return s.replace('\\', '\\\\').replace('"', '\\"')


def rnd(rng, a, b, nd=3):
    return round(rng.uniform(a, b), nd)


def clear_lines():
    return ['n = count()', 'for i in 0..n { delete(name(0)) }']


def chunk(path, tag):
    try:
        return beefile.chunk(path, tag)
    except Exception:
        return None


def num(v):
    try:
        return float(v)
    except ValueError:
        return None


INFO = [0, 1, 2, 3, 5, 6]


def script_steps(steps):
    """Steps -> BeeModel's arguments. '@a,b' selects."""
    a = []
    for s in steps:
        if s.startswith('@'):
            a += ['--select', s[1:]]   # (--select A,B: exactly these, B active)
            continue
        a += ['--op', s]
    return a


def anim_vals(r):
    return re.findall(r'^(?:clothinfo|cacheinfo|evsum):\S+?=(\S+)$', r.stderr if r else '', re.M)


def run_port(base, steps, frames, cpu=None, binary=None, info=INFO, names=('Cloth',)):
    """The steps on the base, then at each frame every vertex the named objects
    show (evsum), clothinfo and cacheinfo(1): [rows]."""
    a = ['--op', f'file.open {base}', *script_steps(steps)]
    for f in frames:
        a += ['--op', f'anim.frame {f}']
        for x in info:
            a += ['--print-anim', f'clothinfo:{x}']
        a += ['--print-anim', 'cacheinfo:1']
        for n in names:
            a += ['--print-anim', f'evsum:{n}']
    r = port(*a, binary=binary, cpu=cpu)
    vals = anim_vals(r)
    m = len(info) + 1 + len(names)
    return [[num(v) for v in vals[k:k + m]] for k in range(0, len(vals), m)]


def rows_bad(rows, n, what, info=INFO, show=3):
    """Rows (clothinfo..., cacheinfo(1), evsum...) at n frames: all there, every
    value a finite number, the counts whole and not negative, a cloth and particles."""
    bad = []
    if len(rows) != n:
        bad.append(f'{what}: {len(rows)} rows of {n}')
    for k, r in enumerate(rows):
        if any(v is None or not math.isfinite(v) for v in r):
            bad.append(f'{what} frame #{k}: not a number in {r}')
            continue
        cnt = r[:len(info) + 1]
        if any(v < 0 or v != int(v) for v in cnt):
            bad.append(f'{what} frame #{k}: a count not whole: {r}')
        if info[:2] == [0, 1] and (r[0] < 1 or r[1] < 1):
            bad.append(f'{what} frame #{k}: no cloth: {r}')
    for w in bad[:show]:
        print('      ', w)
    return bad


# ---- scenes -----------------------------------------------------------------------------------

KINDS = ['sphere', 'cube', 'cylinder', 'cone', 'torus']


def random_scene(rng, path, run):
    """A cloth (a grid, maybe finer), maybe a soft body, colliders, maybe the
    Ground and a field, saved by a script: (the file, the steps)."""
    lines = clear_lines()
    steps = []
    lv = rng.choice([0, 0, 1, 1, 2])
    lines += [f'add("grid", "Cloth", {rnd(rng, -0.3, 0.3)}, {rnd(rng, 1.2, 2.2)}, {rnd(rng, -0.3, 0.3)})']
    if lv:
        lines += ['modifier("Cloth", "subsurf")', f'modset("Cloth", 0, "levels", {lv})', 'modapply("Cloth", 0)']
    if rng.random() < 0.5:
        lines.append(f'scale("Cloth", {rnd(rng, 0.6, 1.6)})')
    if rng.random() < 0.3:
        lines.append(f'rotate("Cloth", {rnd(rng, -0.4, 0.4)}, {rnd(rng, -0.4, 0.4)}, {rnd(rng, -0.4, 0.4)})')
    o = ['cloth']
    for k, lo, hi in (('stretch', 0, 0.001), ('bend', 0, 0.5), ('mass', 0.2, 4), ('damping', 0, 1), ('thickness', 0.005, 0.06), ('friction', 0, 1)):
        if rng.random() < 0.4:
            o += [k, str(rnd(rng, lo, hi, 5))]
    if rng.random() < 0.3:
        o.append('self')
    steps += ['@Cloth', 'cloth.add ' + ' '.join(o)]
    pin = rng.random()
    if pin < 0.3:
        steps.append(f'cloth.pin above {rng.choice("xz")} {rnd(rng, 0.5, 0.9)}')
    elif pin < 0.4:
        steps.append(f'cloth.pin below x {rnd(rng, -0.9, -0.5)}')
    if pin < 0.4 and rng.random() < 0.6:   # (the object moves: its pins follow)
        steps += [f'anim.key Cloth:x 1 0', f'anim.key Cloth:x 30 {rnd(rng, -1.5, 1.5)}', f'anim.key Cloth:ry 1 0', f'anim.key Cloth:ry 30 {rnd(rng, -40, 40)}']
    nc = rng.randint(1, 2)
    for k in range(nc):
        nm = f'C{k}'
        lines.append(f'add("{rng.choice(KINDS)}", "{nm}", {rnd(rng, -0.8, 0.8)}, {rnd(rng, -0.2, 0.6)}, {rnd(rng, -0.8, 0.8)})')
        lines.append(f'scale("{nm}", {rnd(rng, 0.3, 0.8)})')
        if rng.random() < 0.5:
            lines.append(f'rotate("{nm}", {rnd(rng, -1, 1)}, {rnd(rng, -1, 1)}, {rnd(rng, -1, 1)})')
        steps += [f'@{nm}', 'cloth.add collider' + (f' thickness {rnd(rng, 0, 0.05)}' if rng.random() < 0.3 else '')]
    if run % 4 == 1 or rng.random() < 0.35:
        lines += ['add("sphere", "Soft", 1.8, 2.5, 0)', 'scale("Soft", 0.4)']
        s = ['soft', 'volume', str(rnd(rng, 0.00005, 0.001, 6))]
        if rng.random() < 0.5:
            s += ['stretch', str(rnd(rng, 0, 0.0005, 6))]
        steps += ['@Soft', 'cloth.add ' + ' '.join(s)]
        lines += ['add("cube", "Step", 1.8, 0.3, 0)', 'scale("Step", 0.6, 0.3, 0.6)']
        steps += ['@Step', 'cloth.add collider']
    if run % 4 == 3:
        lines.append('op("create.ground", "height -0.5")')
    w = []
    if rng.random() < 0.35:
        w += ['wind', str(rnd(rng, -4, 4)), str(rnd(rng, -1, 1)), str(rnd(rng, -4, 4))]
    if rng.random() < 0.3:
        w += ['substeps', str(rng.choice([3, 6, 12, 15]))]
    if rng.random() < 0.2:
        w += ['rate', str(rng.choice([30, 48, 90]))]
    if w:
        steps.append('cloth.world ' + ' '.join(w))
    if rng.random() < 0.25:
        lines.append(rng.choice(['op("field.add_wind", "strength 3 gust 0.5")', 'op("field.add_attractor", "strength 2")',
                                 'op("field.add_turbulence", "strength 2")', 'op("field.add_vortex", "strength 2")']))
    if rng.random() < 0.2:
        steps.append('rigid.world gravity 0 -4 0.5')
    lines.append(f'op("file.save_as", "{path}")')
    make('\n'.join(lines))
    return steps


FRAMES = [2, 6, 13, 24, 40]


def s_sims():
    print(f'-- random scenes ({RUNS}): cloth, soft bodies, colliders, the Ground, pins, self collision, wind, fields, settings; every vertex at {len(FRAMES)} frames, one CPU --')
    rng = random.Random(SEED)
    nbad = moved = hit = soft = 0
    first = None
    for run in range(RUNS):
        base = f'{T}/sm{run}.bee'
        steps = random_scene(rng, base, run)
        names = ('Cloth', 'Soft') if any('soft' in s for s in steps) else ('Cloth',)
        ip = run_port(base, steps, FRAMES, names=names)
        if rows_bad(ip, len(FRAMES), f'scene {run}'):
            nbad += 1
            print('       steps:', steps)
        if run == 0:
            print("       (scene 0 rows:", ip[:2], ")")
            first = (base, steps, names, ip)
        if ip and ip[0][7] != ip[-1][7]:
            moved += 1
        if ip and max((r[4] or 0) for r in ip) > 0:
            hit += 1
        if len(names) > 1:
            soft += 1
    check(nbad == 0, f'{RUNS - nbad} of {RUNS} random scenes: every vertex shown a number, clothinfo sane at {len(FRAMES)} frames')
    check(moved == RUNS and hit >= RUNS // 2, f'the cloth moved in {moved}, collided in {hit} of {RUNS} ({soft} with a soft body)')
    if first:
        base, steps, names, ip = first
        check(run_port(base, steps, FRAMES, names=names) == ip, 'scene 0 played again: the same vertices and counts')


def s_threads():
    print(f'-- many CPUs ({THREADS}): the workers solve big colour batches, collisions, self collision in parallel; the same as one --')
    lines = clear_lines() + ['add("grid", "Cloth", 0, 1.6, 0)', 'modifier("Cloth", "subsurf")', 'modset("Cloth", 0, "levels", 2)', 'modapply("Cloth", 0)',
                             'scale("Cloth", 1.3)', 'add("sphere", "Ball", 0.1, 0, 0)', 'scale("Ball", 0.7)', 'add("cube", "Box", -0.6, 0.6, 0.3)', 'scale("Box", 0.3)',
                             f'op("file.save_as", "{T}/th.bee")']
    make('\n'.join(lines))
    steps = ['@Cloth', 'cloth.add cloth self thickness 0.04 bend 0.05', '@Ball', 'cloth.add collider', '@Box', 'cloth.add collider', 'cloth.world wind 1 0 0.5']
    frames = [3, 12, 30]
    ip = run_port(f'{T}/th.bee', steps, frames, cpu=THREADS)
    bad = rows_bad(ip, len(frames), 'threaded')
    check(not bad and ip[0][1] == 1681 and max(r[4] for r in ip) > 0, f'1681 particles, self collision, two colliders, wind on {THREADS}: every vertex a number, collisions')
    ip1 = run_port(f'{T}/th.bee', steps, frames)
    check(ip1 == ip, 'one CPU and many give the same vertices and counts')


# ---- landscapes as colliders (cx_hf, pt_hf) -----------------------------------------------------

def ridge(nm, x, z0, z1, k=3):
    """A ridge along z at x: raise brushes on the landscape nm."""
    out = [f'select("{nm}")']
    for _ in range(k):
        z = z0
        while z <= z1 + 1e-9:
            out.append(f'op("landscape.brush", "raise {x} {round(z, 2)} radius 0.5 strength 1")')
            z += 0.4
    return out


def grid(nm, x, y, z, lv=1, s=1.6):
    return [f'add("grid", "{nm}", {x}, {y}, {z})', f'modifier("{nm}", "subsurf")', f'modset("{nm}", 0, "levels", {lv})', f'modapply("{nm}", 0)', f'scale("{nm}", {s})']


# name, the base (made by a script), the steps, the objects shown
LAND = [
    ('hills, moved, scaled and turned (the turn ignored)',
     ['op("landscape.add", "hills res 65 size 6 seed 3")', 'scale("Landscape", 1.3, 0.12, 1.1)', 'move("Landscape", 0.3, -1.6, -0.2)', 'rotate("Landscape", 0, 25, 0)']
     + grid('Cloth', 0, 1.2, 0),
     ['@Cloth', 'cloth.add cloth friction 0.5 thickness 0.03 mass 3', '@Landscape', 'cloth.add collider'], ('Cloth',)),
    ('flat with a raised brush; a soft body, self collision',
     ['op("landscape.add", "flat res 65 size 5")'] + ridge('Landscape', 0, 0, 0, 4) + ridge('Landscape', 0.8, 0.4, 0.4, 2)
     + grid('Cloth', 0, 0.8, 0, 1, 1.2) + ['add("sphere", "Soft", 1.6, 0.8, 1.2)', 'scale("Soft", 0.3)'],
     ['@Cloth', 'cloth.add cloth self bend 0.1', '@Soft', 'cloth.add soft volume 0.0002', '@Landscape', 'cloth.add collider'], ('Cloth', 'Soft')),
    ('two landscapes side by side, at other heights',
     ['op("landscape.add", "flat res 65 size 3")', 'move("Landscape", -1.5, -0.2, 0)', 'op("landscape.add", "hills res 129 size 3 seed 5")',
      'scale("Landscape.001", 1, 0.04, 1)', 'move("Landscape.001", 1.5, -0.9, 0)'] + grid('Cloth', 0, 0.9, 0, 1, 2.0),
     ['@Cloth', 'cloth.add cloth friction 0.2', '@Landscape.001', 'cloth.add collider', '@Landscape', 'cloth.add collider'], ('Cloth',)),
    ('a landscape and a box together, the Ground below',
     ['op("landscape.add", "hills res 65 size 6 seed 7")', 'scale("Landscape", 1, 0.1, 1)', 'move("Landscape", 0, -1.8, 0)', 'add("cube", "Box", 0.4, 0.3, 0)', 'scale("Box", 0.3)',
      'op("create.ground", "height -3")'] + grid('Cloth', 0.2, 1.3, 0.1, 1, 1.4),
     ['@Box', 'cloth.add collider', '@Cloth', 'cloth.add cloth thickness 0.02 friction 0.3', '@Landscape', 'cloth.add collider'], ('Cloth',)),
    ('pinned cloth draped over a ridge',
     ['op("landscape.add", "flat res 65 size 4")'] + ridge('Landscape', 0, -1.6, 1.6, 4) + grid('Cloth', 0, 0.6, 0, 2, 1.5),
     ['@Cloth', 'cloth.add cloth friction 0.9 bend 0.02', 'cloth.pin above x 0.8', '@Landscape', 'cloth.add collider'], ('Cloth',)),
    ('a tilted plane crossing a landscape: the cloth slides into the crease',
     ['op("landscape.add", "flat res 65 size 5")'] + ridge('Landscape', -0.6, -0.8, 0.8, 2) + ['add("grid", "Ramp", 0.3, 0, 0)', 'scale("Ramp", 1.5)', 'rotate("Ramp", 0, 0, 30)']
     + grid('Cloth', -0.1, 0.7, 0, 2, 1.0),
     ['@Ramp', 'cloth.add collider', '@Cloth', 'cloth.add cloth friction 0.6 thickness 0.04', '@Landscape', 'cloth.add collider'], ('Cloth',)),
    ('a cloth over a box standing in a landscape: its sides slide down the walls onto the ground',
     ['op("landscape.add", "flat res 65 size 4")'] + ridge('Landscape', 0.6, -0.4, 0.4, 1) + ['add("cube", "Box", 0, 0.25, 0)', 'scale("Box", 0.3)']
     + grid('Cloth', 0.05, 0.8, 0, 2, 0.9),
     ['@Box', 'cloth.add collider', '@Cloth', 'cloth.add cloth friction 0.8 thickness 0.03', '@Landscape', 'cloth.add collider'], ('Cloth',)),
    ('a box sunk half a millimetre under a flat landscape: the cloth lands on both in a wind (the landscape first)',
     ['op("landscape.add", "flat res 65 size 4")', 'add("cube", "Slab", 0.3, -0.2005, 0)', 'scale("Slab", 0.5, 0.2, 0.5)'] + grid('Cloth', 0, 0.6, 0, 1, 1.0),
     ['@Slab', 'cloth.add collider', '@Cloth', 'cloth.add cloth friction 0.5 thickness 0.03 mass 3', '@Landscape', 'cloth.add collider', 'cloth.world wind 3 0 1'], ('Cloth',)),
    ('five landscapes: the fifth left out (four at most)',
     [x for k in range(5) for x in (f'op("landscape.add", "flat res 65 size 1.4")', f'move("{"Landscape" + (f".{k:03d}" if k else "")}", {[-1.5, 1.5, -1.5, 1.5, 0][k]}, {[-0.1, -0.2, -0.3, -0.4, 0.3][k]}, {[-1.5, -1.5, 1.5, 1.5, 0][k]})')]
     + grid('Cloth', 0, 1.0, 0, 1, 2.2),
     ['@Cloth', 'cloth.add cloth'] + [x for k in range(5) for x in ('@Landscape' + (f'.{k:03d}' if k else ''), 'cloth.add collider')], ('Cloth',)),
]
LFRAMES = [2, 8, 16, 30, 50]


def land_base(k):
    path = f'{T}/la{k}.bee'
    make('\n'.join(clear_lines() + LAND[k][1] + [f'op("file.save_as", "{path}")']))
    return path


def s_land():
    print(f'-- landscapes as colliders (by their heights): {len(LAND)} scenes, every vertex at {len(LFRAMES)} frames, one CPU and many --')
    for k, (what, _, steps, names) in enumerate(LAND):
        base = land_base(k)
        ip = run_port(base, steps, LFRAMES, names=names)
        bad = rows_bad(ip, len(LFRAMES), what)
        # the same steps without the landscapes as colliders: other vertices
        bare = [s for j, s in enumerate(steps) if not (s.startswith('@Landscape') or (j and steps[j - 1].startswith('@Landscape')))]
        jp = run_port(base, bare, LFRAMES[-1:], names=names)
        hit = bool(ip) and max((r[4] or 0) for r in ip) > 0
        differ = bool(ip) and bool(jp) and jp[-1][7:] != ip[-1][7:]
        check(not bad and hit and differ, f'{what}: every vertex a number at {len(LFRAMES)} frames (collided: {hit}, the landscape made a difference: {differ})')
        if k == 1:
            ip2 = run_port(base, steps, LFRAMES[1:4], names=names, cpu=THREADS)
            check(ip2 == ip[1:4], f'{what} on {THREADS}: the same as on one CPU')
    # moving a landscape: keyed, it moves under the cloth
    base = land_base(0)
    still = run_port(base, LAND[0][2], LFRAMES[-1:], names=('Cloth',))
    steps = LAND[0][2] + ['anim.key Landscape:y 1 -1.6', 'anim.key Landscape:y 40 -0.6', 'anim.key Landscape:sx 1 1.3', 'anim.key Landscape:sx 40 0.7']
    ip = run_port(base, steps, LFRAMES, names=('Cloth',))
    check(not rows_bad(ip, len(LFRAMES), 'keyed') and bool(still) and ip[-1][7] != still[-1][7],
          'a keyed landscape (rising, narrowing): every vertex a number, the cloth not as over a still one')


LAND_CACHE = ['@Cloth', 'cloth.add cloth friction 0.5', '@Landscape', 'cloth.add collider', 'anim.frame 20', '#', 'anim.frame 7', '#', 'anim.frame 20', '#',
              '@Landscape', 'landscape.brush raise 0 0 radius 1.5 strength 1', 'anim.frame 22', '#', 'anim.key Landscape:y 1 -1.2', 'anim.frame 24', '#',
              'sim.bake cloth', 'anim.frame 35', '#', 'anim.frame 3', '#', '!save']

# undo points: (a, b) the '#' points that must show the same cloth (an undo: as
# before the step; a redo: as after it); differ: the steps that change it
LAND_UNDO = ['@Cloth', 'cloth.add cloth', '@Landscape', 'cloth.add collider', '#',                              # 0
             '@Landscape', 'landscape.brush raise 0.5 0 radius 1.2 strength 1', '#',                            # 1
             'edit.undo', '#', 'edit.redo', '#',                                                                 # 2 3
             '@Landscape', 'object.delete', '#', 'edit.undo', '#',                                               # 4 5
             '@Landscape', 'cloth.remove', '#', 'edit.undo', '#']                                                # 6 7
LAND_SAME = [(2, 0), (3, 1), (5, 3), (7, 5)]
LAND_DIFF = [(1, 0), (4, 3), (6, 5)]


def points(base, seq, save=None):
    """The steps on the base; at each '#' clothinfo 0, 1, 5, cacheinfo 1, 4 and
    evsum("Cloth"); '!save' saves to save. (the points, how many asked for)"""
    a = ['--op', f'file.open {base}']
    npt = 0
    for s in seq:
        if s == '#':
            for w in ('clothinfo:0', 'clothinfo:1', 'clothinfo:5', 'cacheinfo:1', 'cacheinfo:4', 'evsum:Cloth'):
                a += ['--print-anim', w]
            npt += 1
        elif s == '!save':
            a += ['--op', f'file.save_as {save}']
        else:
            a += script_steps([s])
    r = port(*a)
    vals = anim_vals(r)
    return [[num(v) for v in vals[k:k + 6]] for k in range(0, len(vals), 6)], npt


def finite(q):
    return all(v is not None and math.isfinite(v) for v in q)


def roundtrip(src, what, tags=(b'SIMC', b'MPIN')):
    """src opened and saved, that opened and saved again: the chunks the same."""
    a, b = f'{T}/rt1.bee', f'{T}/rt2.bee'
    for f in (a, b):
        if os.path.exists(f):
            os.remove(f)
    port('--op', f'file.open {src}', '--op', f'file.save_as {a}')
    port('--op', f'file.open {a}', '--op', f'file.save_as {b}')
    same = all(chunk(src, t) == chunk(a, t) == chunk(b, t) for t in tags) and cl_part(src) == cl_part(a) == cl_part(b)
    check(os.path.exists(b) and same, f'{what}: opened and saved twice, {", ".join(t.decode() for t in tags)} and the cloth records the same')


def s_land_cache():
    print('-- landscapes: the cache (back, an edit of the landscape, a key), bake, SIMC saved and read back; undo with the timeline --')
    base = land_base(0)
    qp, npt = points(base, LAND_CACHE, f'{T}/lap.bee')
    check(len(qp) == npt and all(finite(q) for q in qp), f'{npt} points (played back, the landscape brushed, keyed, baked): every vertex and count a number')
    check(len(set(q[5] for q in qp)) >= 5, f'the points show different cloth ({len(set(q[5] for q in qp))} kinds)')
    sp_ = chunk(f'{T}/lap.bee', b'SIMC')
    check(sp_ is not None and len(sp_) > 1000, f'the baked SIMC chunk saved ({len(sp_ or b"")} bytes)')
    roundtrip(f'{T}/lap.bee', 'the baked file', (b'SIMC',))
    ip = run_port(f'{T}/lap.bee', [], [3, 17, 33])
    check(not rows_bad(ip, 3, 'the baked file') and len(qp) == npt and ip[0][7] == qp[-1][5],
          f'the baked file played: frame 3 as it was baked ({ip[0][7] if ip else None} / {qp[-1][5] if qp else None})')
    ip = run_port(f'{T}/lap.bee', ['sim.free cloth'], [6, 28])
    check(not rows_bad(ip, 2, 'freed'), 'the baked file, its bake freed: simulated again')
    undo_check(base, LAND_UNDO, LAND_SAME, LAND_DIFF, 'Cloth', 'a landscape collider (brushed, deleted, removed)', 14)


def s_cache():
    print('-- the cache: going back plays cached frames, edits drop it (stretch, a collider moved, pins, the world), bake, sim.free, SIMC and MPIN read back --')
    base = f'{T}/ca.bee'
    make('\n'.join(clear_lines() + ['add("grid", "Cloth", 0, 1.5, 0)', 'add("sphere", "Ball", 0, 0, 0)', 'scale("Ball", 0.8)', f'op("file.save_as", "{base}")']))
    seq = ['@Cloth', 'cloth.add cloth', 'cloth.pin above x 0.8', '@Ball', 'cloth.add collider',
           'anim.frame 20', '#', 'anim.frame 7', '#', 'anim.frame 20', '#', 'anim.frame 13.5', '#',
           '@Cloth', 'cloth.add stretch 0.0005', 'anim.frame 9', '#', 'anim.key Ball:x 1 0.2', 'anim.frame 11', '#',
           '@Cloth', 'cloth.pin below z -0.5', 'anim.frame 12', '#', 'cloth.world substeps 4', 'anim.frame 14', '#',
           'sim.bake cloth', 'anim.frame 30', '#', '@Ball', 'cloth.add thickness 0.05', 'anim.frame 31', '#', 'anim.frame 400', '#',
           'sim.free cloth', 'anim.frame 18', '#', 'sim.bake', 'anim.frame 5', '#', '!save']
    qp, npt = points(base, seq, f'{T}/cap.bee')
    check(len(qp) == npt and all(finite(q) for q in qp), f'{npt} points (played, stale, baked): every vertex and count a number')
    check(len(set(q[5] for q in qp)) >= 6, f'the points show different cloth ({len(set(q[5] for q in qp))} kinds)')
    fo = [q[3] for q in qp]
    check(len(fo) > 12 and fo[1] == fo[0] and fo[4] < fo[3] and fo[5] < 13 and fo[8] > 20 and fo[9] == fo[8] and fo[10] == fo[8],
          f'the cache: kept going back, dropped by each edit, baked and kept ({fo})')
    # the files: SIMC, MPIN, the records; saved again the same
    sp_ = chunk(f'{T}/cap.bee', b'SIMC')
    check(sp_ is not None and len(sp_) > 1000, f'the SIMC chunk saved ({len(sp_ or b"")} bytes)')
    mp = chunk(f'{T}/cap.bee', b'MPIN')
    check(mp is not None and len(mp) > 8, f'the MPIN chunk saved ({len(mp or b"")} bytes)')
    check(bool(cl_part(f'{T}/cap.bee')), 'the cloth world and records in ANIM')
    roundtrip(f'{T}/cap.bee', 'the baked file with pins')
    ip = run_port(f'{T}/cap.bee', [], [3, 5, 9, 22, 60])
    check(not rows_bad(ip, 5, 'the baked file') and len(qp) == npt and ip[1][7] == qp[-1][5],
          f'the baked file played at frames 3, 5, 9, 22, 60: frame 5 as it was baked ({ip[1][7] if len(ip) > 1 else None} / {qp[-1][5] if qp else None})')
    # a file saved with pins: the pins round trip (no bake: simulated again from them)
    port('--op', f'file.open {base}', '--select', 'Cloth', '--op', 'cloth.add cloth', '--op', 'cloth.pin above z 0.5', '--select', 'Ball',
         '--op', 'cloth.add collider', '--op', f'file.save_as {T}/pinp.bee')
    pm = chunk(f'{T}/pinp.bee', b'MPIN')
    check(pm is not None and len(pm) > 8, f'pins saved with no bake ({len(pm or b"")} bytes of MPIN)')
    roundtrip(f'{T}/pinp.bee', 'the file with pins', (b'MPIN',))
    ip = run_port(f'{T}/pinp.bee', [], [4, 15])
    check(not rows_bad(ip, 2, 'pins'), 'the file with pins simulated: every vertex a number')


def cl_part(path):
    a = chunk(path, b'ANIM')
    if a is None or len(a) < ANIM_HEAD:
        return None
    nrb, njt = struct.unpack_from('<2I', a, 8 + 52 - 4)
    r = ANIM_HEAD + nrb * 80 + njt * 64
    n = min(struct.unpack_from('<I', a, r + REST_CW + 20)[0], 32)
    return a[r + REST_CW:r + REST_CW + 32] + a[r + REST_CL:r + REST_CL + n * 64]


def build(chs):
    o = b'BEEM' + struct.pack('<I', 1)
    for t, c in chs:
        o += t + struct.pack('<I', len(c)) + c
    return o


def damage(rng, c):
    c = bytearray(c)
    for _ in range(rng.randint(1, 6)):
        if c:
            c[rng.randrange(len(c))] = rng.randrange(256)
    return bytes(c)


def s_damaged():
    print('-- damaged SIMC (cloth frames), MPIN and cloth records: opened and played, no crash --')
    rng = random.Random(SEED + 6)
    base = f'{T}/dmb.bee'
    make('\n'.join(clear_lines() + ['add("grid", "Cloth", 0, 1.5, 0)', 'add("sphere", "Ball", 0, 0, 0)', 'scale("Ball", 0.8)',
                                    'select("Cloth")', 'op("cloth.add", "cloth")', 'op("cloth.pin", "above x 0.8")', 'select("Ball")', 'op("cloth.add", "collider")',
                                    'op("sim.bake", "cloth")', f'op("file.save_as", "{base}")']))
    chs = list(beefile.chunks(base))
    n = max(10, RUNS)
    crash = 0
    for run in range(n):
        how = run % 5

        def hurt(t, c):
            if t == b'SIMC':
                if how == 0:
                    return c[:rng.randrange(len(c))]
                if how == 1:
                    return damage(rng, c)
                if how == 2:   # a frame's record: its counts
                    c = bytearray(c)
                    nf = struct.unpack_from('<I', c, 16)[0]
                    o = 20 + 4 * nf + sum(struct.unpack_from(f'<{nf}I', c, 20)[:rng.randrange(nf)])
                    struct.pack_into('<I', c, o + rng.choice([0, 4, 8]), rng.choice([0xffffffff, 1 << 20, 7, 0, 121]))
                    return bytes(c)
            if t == b'SIMC' and how == 3:   # (no bake: simulated from the pins)
                return b''
            if t == b'MPIN' and how == 3:   # (a count that does not fit the mesh: left out)
                return [struct.pack('<II', 0, 120) + c[8:], c[:rng.randrange(len(c))], damage(rng, c),
                        struct.pack('<II', 0, 0x7ffffff0) + c[8:]][(run // 5) % 4]
            if t == b'ANIM' and how == 4:   # the cloth world and records
                c = bytearray(c)
                nrb, njt = struct.unpack_from('<2I', c, 8 + 52 - 4)
                r = ANIM_HEAD + nrb * 80 + njt * 64
                for _ in range(rng.randint(1, 6)):
                    o = r + REST_CW + rng.choice([rng.randrange(20), 24 + rng.randrange(8), 32 + rng.randrange(128)])
                    c[o] = rng.randrange(256)
                return bytes(c)
            return c
        dm = f'{T}/dd{run}.bee'
        open(dm, 'wb').write(build([(t, hurt(t, c)) for t, c in chs]))
        r = port('--op', f'file.open {dm}', '--op', 'anim.frame 17', '--print-anim', 'evsum:Cloth', '--print-anim', 'clothinfo:1', '--op', 'anim.frame 5',
                 '--print-anim', 'evsum:Cloth', '--print-anim', 'clothinfo:1', ok=False, timeout=300)
        if r is None or r.returncode != 0 or 'panic' in (r.stderr or ''):
            crash += 1
            print('       BeeModel stopped on', dm, r and r.stderr[-600:])
    check(crash == 0, f'BeeModel opened and played {n - crash} of {n} damaged files')


# ---- the console, undo ------------------------------------------------------------------------

def answers(lines):
    out, cur = [], None
    for ln in lines:
        if ln.startswith('> '):
            cur = []
            out.append(cur)
        elif cur is not None:
            cur.append(ln)
    return out


CONSOLE_SEQ = [
    'cloth.add', 'cloth.add bogus', 'cloth.add mass', 'cloth.add mass x', 'cloth.add soft self', 'cloth.pin', 'cloth.pin bogus', 'cloth.pin above', 'cloth.pin above w 1',
    'cloth.pin above y', 'cloth.pin below y nan', 'cloth.world bogus', 'cloth.world wind 1 2', 'cloth.world substeps', 'cloth.world rate x', 'cloth.world substeps 0 rate 99999',
    'cloth.remove', '@A', 'cloth.add cloth mass 2 damping 0.2 thickness 0.03 friction 0.4 bend 0.1 stretch 0.0001 volume 0.5 self', 'cloth.add collider', 'cloth.add soft',
    'cloth.pin all', 'cloth.pin none', 'cloth.pin above y 0', 'cloth.pin below x -0.2', 'cloth.pin below y 0', 'cloth.pin selected', '@A,B', 'cloth.add', 'cloth.pin above z 0.5',
    '@Light', 'cloth.add', 'cloth.pin all', '@A,B', 'cloth.remove', 'cloth.world wind 1 0 -1 substeps 3 rate 30', 'sim.cache', 'sim.bake cloth', 'sim.bake', 'sim.cache',
    '@A', 'cloth.add cloth', '@B', 'cloth.add collider', 'anim.frame 6', 'sim.cache', 'sim.bake cloth', 'sim.cache', 'sim.free cloth', 'sim.cache',
]


def console_base():
    base = f'{T}/conbase.bee'
    make('\n'.join(clear_lines() + ['add("grid", "A", 0, 2, 0)', 'add("sphere", "B", 0.3, 0, 0)', 'add("light", "Light", 3, 3, 3)', f'op("file.save_as", "{base}")']))
    return base


def s_console():
    print('-- the console\'s words: every cloth operator answers, the records after them read back --')
    base = console_base()
    r = port('--op', f'file.open {base}', *script_steps(CONSOLE_SEQ), '--op', f'file.save_as {T}/conp.bee')
    got = answers(plog().splitlines())[1:-1]
    cmds = [c for c in CONSOLE_SEQ if not c.startswith('@')]
    said = sum(1 for g in got if g)
    check(r is not None and r.returncode == 0 and len(got) == len(cmds), f'{len(got)} answers for {len(cmds)} commands ({said} said something)')
    check(bool(cl_part(f'{T}/conp.bee')) and chunk(f'{T}/conp.bee', b'MPIN') is not None, 'after them: the cloth world, records and pins saved')
    roundtrip(f'{T}/conp.bee', 'after them', (b'MPIN', b'SIMC'))


UNDO_SEQ = ['@A', 'cloth.add cloth', '@B', 'cloth.add collider', '#',                            # 0
            '@A', 'cloth.add stretch 0.001 bend 0.2', '#',                                     # 1
            'edit.undo', '#', 'edit.redo', '#',                                                # 2 3
            'cloth.pin above x 0.6', '#', 'edit.undo', '#', 'edit.redo', '#',                  # 4 5 6
            'cloth.world wind 2 0 0', '#', 'edit.undo', '#',                                   # 7 8
            '@B', 'anim.key B:x 1 0.9', '#', 'edit.undo', '#',                                 # 9 10
            '@A', 'object.delete', '#', 'edit.undo', '#',                                      # 11 12
            '@A', 'cloth.add mass 3 damping 0.8', '#', 'edit.undo', '#']                       # 13 14
UNDO_SAME = [(2, 0), (3, 1), (5, 3), (6, 4), (8, 6), (10, 8), (12, 10), (14, 12)]
UNDO_DIFF = [(1, 0), (4, 3), (7, 6), (9, 8), (13, 12)]


def undo_seq(seq):
    """The selection made again after each undo / redo: --select is no input
    event, so its steps keep the selection of the step before (in the window a
    click is one, and the step takes it)."""
    out, last = [], None
    for c in seq:
        out.append(c)
        if c.startswith('@'):
            last = c
        elif c in ('edit.undo', 'edit.redo') and last:
            out.append(last)
    return out


def undo_points(base, seq, nm):
    """At each '#' the object's vertices (evsum), clothinfo(1), cacheinfo(1), (4)."""
    a = ['--op', f'file.open {base}']
    for c in seq:
        if c == '#':
            a += ['--print-anim', f'evsum:{nm}', '--print-anim', 'clothinfo:1', '--print-anim', 'cacheinfo:1', '--print-anim', 'cacheinfo:4']
        elif c.startswith('@'):
            a += ['--select', c[1:]]
        else:
            a += ['--op', c]
    r = port(*a)
    vals = anim_vals(r)
    return [[num(v) for v in vals[k:k + 4]] for k in range(0, len(vals), 4)]


def undo_check(base, seq, same, differ, nm, what, frame):
    """Each '#': back at frame 1, the cache freed, then the frame (a point
    simulated, never one played from the cache: those are 16-bit), the point."""
    marked = []
    for c in seq:
        marked += ['anim.frame 1', 'sim.free', f'anim.frame {frame}', '#'] if c == '#' else [c]
    got = undo_points(base, undo_seq(marked), nm)
    npt = seq.count('#')
    bad = [(a, b) for a, b in same if a >= len(got) or got[a][:2] != got[b][:2]]
    for a, b in bad[:6]:
        print(f'       point {a}: {got[a] if a < len(got) else None}, point {b}: {got[b] if b < len(got) else None}')
    check(len(got) == npt and not bad, f'undo / redo with {what}: {len(same) - len(bad)} of {len(same)} undos and redos show the cloth as before / after the step')
    nd = [(a, b) for a, b in differ if a >= len(got) or got[a][0] == got[b][0]]
    check(len(got) == npt and not nd, f'and the steps changed the cloth ({len(differ) - len(nd)} of {len(differ)})')


def s_undo():
    print('-- undo and redo with the timeline: cloth made, changed, pinned, wind, a collider moved, the cloth deleted --')
    undo_check(console_base(), UNDO_SEQ, UNDO_SAME, UNDO_DIFF, 'A', 'cloth (changed, pinned, wind, a collider moved, deleted)', 20)


# ---- the Physics tab ----------------------------------------------------------------------------

def ui_rows(path):
    rows = []
    try:
        lines = open(path, errors='replace').read().splitlines()
    except OSError:
        return rows
    for ln in lines:
        p = ln.split('\t')
        if len(p) >= 4:
            try:
                x, y, w, h = map(int, p[2].split())
            except ValueError:
                continue
            rows.append((p[0], p[1], x, y, w, h))
    return rows


def uirun(*a, d, tag):
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{d}/{tag}.ppm', '--dump-ui', f'{d}/{tag}.txt', *a],
                           capture_output=True, text=True, timeout=300, env=ENV)
        return r.returncode, ui_rows(f'{d}/{tag}.txt')
    except subprocess.TimeoutExpired:
        return None, []


def s_window():
    print('-- the Physics tab\'s Cloth and Soft Body / Cloth World sections: the widgets in the window; clicks change the records, an undo takes them back --')
    D = f'{T}/win'
    os.makedirs(D, exist_ok=True)
    f = f'{D}/cl.bee'
    make('\n'.join(clear_lines() + ['add("grid", "Cloth", 0, 2, 0)', 'add("sphere", "Soft", 3, 1, 0)', 'add("cube", "Box", 0, 0, 0)', 'add("cube", "Plain", -3, 0, 0)',
                                    'select("Cloth")', 'op("cloth.add", "cloth stretch 0.000123 bend 0.0456 mass 2.5 thickness 0.031")',
                                    'select("Soft")', 'op("cloth.add", "soft volume 0.00002 self friction 0.75")', 'select("Box")', 'op("cloth.add", "collider")',
                                    'op("cloth.world", "wind 1.5 0 -2.25 substeps 7")', f'op("file.save_as", "{f}")']))
    check(os.path.exists(f), 'the scene made')
    if not os.path.exists(f):
        return
    # name, the object, sections folded / opened by their titles, a section title that must show
    cases = [('cloth', 'Cloth', [], 'Cloth and Soft Body'), ('soft', 'Soft', [], 'Cloth and Soft Body'), ('collider', 'Box', [], 'Cloth and Soft Body'),
             ('plain', 'Plain', [], 'Cloth and Soft Body'), ('cworld', 'Cloth', ['Rigid Body', 'Joints', 'Cloth World'], 'Cloth World')]
    for name, obj, opens, title in cases:
        args = ['--op', f'file.open {f}', '--select', obj, '--click-label', 'Physics']
        for s in opens:
            args += ['--click-label', s]
        args += ['--move', '600,300']
        rc, rows = uirun(*args, d=D, tag=name)
        page = [r for r in rows if r[2] >= 1060 and r[0] in ('section', 'number', 'enum', 'checkbox', 'button', 'caption', 'info')]
        out = [r for r in page if r[2] + r[4] > 1280 or r[3] + r[5] > 800]
        sec = any(r[0] == 'section' and r[1] == title for r in page)
        check(rc == 0 and sec and not out, f'{name}: BeeModel ran ({rc}), the {title} section shows, every widget in the window ({len(page)} on the page)')
        if name in ('cloth', 'soft'):
            check(any(r[0] == 'number' for r in page) and any(r[0] == 'checkbox' and 'itself' in r[1] for r in page), f'{name}: its fields and Collides with itself')
    # clicks: Rigid Body and Joints folded, Collides with itself, Unpin All; saved, and after one undo
    rc0, rows = uirun('--op', f'file.open {f}', '--select', 'Cloth', '--click-label', 'Physics', '--click-label', 'Rigid Body', '--click-label', 'Joints', d=D, tag='pre')
    for lab in ('Collides with itself', 'Unpin All'):
        r = [x for x in rows if x[1] == lab]
        check(rc0 == 0 and bool(r) and 0 < r[0][3] < 778, f'clicks: {lab} in the window ({r[0][2:4] if r else None})')
    rc, _ = uirun('--op', f'file.open {f}', '--select', 'Cloth', '--click-label', 'Physics', '--click-label', 'Rigid Body', '--click-label', 'Joints',
                  '--click-label', 'Collides with itself', '--click-label', 'Unpin All',
                  '--op', f'file.save_as {D}/p1.bee', '--op', 'edit.undo', '--op', f'file.save_as {D}/p2.bee', d=D, tag='clk')
    check(rc == 0, f'clicks: BeeModel ran ({rc})')
    m1 = chunk(f'{D}/p1.bee', b'MPIN')
    n1 = struct.unpack_from('<I', m1, 4)[0] if m1 and len(m1) >= 8 else 0
    check(cl_part(f'{D}/p1.bee') is not None and cl_part(f'{D}/p1.bee') != cl_part(f) and n1 > 0 and not any(m1[8:8 + n1]),
          f'clicks: they changed the records (self) and made the pins (Unpin All: none of {n1} pinned)')
    check(chunk(f'{D}/p2.bee', b'MPIN') != chunk(f'{D}/p1.bee', b'MPIN') and cl_part(f'{D}/p2.bee') == cl_part(f'{D}/p1.bee'),
          'clicks: the undo took the pins back, the self toggle stays')


# ---- stability, time, memory ------------------------------------------------------------------

def s_fuzz():
    print('-- fuzz: random cloth operators and settings, frames back and forth, undo, bakes: no panic, no hang, no leak --')
    rng = random.Random(SEED + 7)
    words = ['cloth', 'soft', 'collider', 'self', 'stretch', 'bend', 'volume', 'mass', 'damping', 'thickness', 'friction', '-1', '0', '1e30', 'nan', '3',
             '0.5', '-7', '1e-30', 'inf', '0.02', '1e-6']
    bad = 0
    n = max(4, RUNS // 2)
    for run in range(n):
        base = f'{T}/fz{run}.bee'
        steps = random_scene(rng, base, run)
        a = ['--op', f'file.open {base}', *script_steps(steps)]
        for _ in range(40):
            k = rng.random()
            sel = rng.choice(['Cloth', 'C0', 'C1', 'Soft', 'Step'])
            if k < 0.22:
                a += ['--select', sel, '--op', 'cloth.add ' + ' '.join(rng.choice(words) for _ in range(rng.randint(0, 6)))]
            elif k < 0.32:
                a += ['--select', sel, '--op', 'cloth.pin ' + ' '.join(rng.choice(['all', 'none', 'selected', 'above', 'below', 'x', 'y', 'z'] + words[-10:]) for _ in range(rng.randint(0, 3)))]
            elif k < 0.4:
                a += ['--op', 'cloth.world ' + ' '.join(rng.choice(['wind', 'substeps', 'rate'] + words[-10:]) for _ in range(rng.randint(0, 6)))]
            elif k < 0.68:
                a += ['--op', f'anim.frame {rng.choice([1, 2, 5, 13, 30, 7, 0, -3, 2.5, 22])}']
            elif k < 0.76:
                a += ['--op', rng.choice(['edit.undo', 'edit.redo'])]
            elif k < 0.83:
                a += ['--op', rng.choice(['sim.bake', 'sim.free', 'sim.bake cloth', 'sim.free cloth', 'sim.cache budget 16'])]
            elif k < 0.9:
                a += ['--select', sel, '--op', rng.choice(['cloth.remove', 'object.delete', 'object.duplicate', 'object.move 0.1 0 0'])]
            else:
                a += ['--op', f'anim.key {sel}:{rng.choice(["x", "y", "rz", "sx"])} {rng.choice([1, 5, 20])} {rnd(rng, -2, 2)}']
        a += ['--op', f'file.save_as {T}/fz.bee', '--op', f'file.open {T}/fz.bee', '--op', 'anim.frame 9']
        r = port(*a, ok=False, timeout=900)
        if r is None or r.returncode != 0 or 'panic' in (r.stderr or '') or 'leak' in (r.stderr or '').lower():
            bad += 1
            print('       BeeModel failed:', r and r.stderr[-800:])
            open(f'{T}/fuzz_args_{run}.txt', 'w').write('\n'.join(a))
    check(bad == 0, f'{n - bad} of {n} fuzz runs ended cleanly')


def perf_base():
    path = f'{T}/perf.bee'
    make('\n'.join(clear_lines() + ['add("grid", "Cloth", 0, 1.6, 0)', 'modifier("Cloth", "subsurf")', 'modset("Cloth", 0, "levels", 3)', 'modapply("Cloth", 0)',
                                    'scale("Cloth", 1.5)', 'add("sphere", "Ball", 0, 0, 0)', 'scale("Ball", 0.8)', 'select("Cloth")', 'op("cloth.add", "cloth")',
                                    'select("Ball")', 'op("cloth.add", "collider")', f'op("file.save_as", "{path}")']))
    return path


def s_perf():
    print('-- time: an 81 x 81 cloth (6561 particles) over a sphere, frames 1..25, pinned to one CPU (release build) --')
    path = perf_base()
    best_p = None
    hs = []
    for _ in range(2):
        r = port('--op', f'file.open {path}', '--op', 'anim.frame 1', '--op', 'anim.frame 25', '--print-anim', 'clothinfo:4', '--print-anim', 'evsum:Cloth', binary=REL)
        m = re.search(r'clothinfo:4=(\S+)', r.stderr if r else '')
        if m:
            v = float(m.group(1)) / 24
            best_p = v if best_p is None else min(best_p, v)
        m = re.search(r'evsum:Cloth=(\S+)', r.stderr if r else '')
        hs.append(num(m.group(1)) if m else None)
    print(f'       a frame: {best_p} ms')
    check(best_p is not None and math.isfinite(best_p) and best_p > 0, f'a frame\'s time measured ({best_p} ms)')
    check(len(hs) == 2 and hs[0] is not None and math.isfinite(hs[0]) and hs[0] == hs[1], f'the same vertices at frame 25 both times ({hs})')


def s_memory():
    print('-- memory over a long run: the 81 x 81 cloth played to frame 80, back, again, 6 times (release build): no growth --')
    path = perf_base()
    a = ['--op', f'file.open {path}', '--op', 'sim.cache budget 16']
    for k in range(6):
        a += ['--op', 'anim.frame 1', '--op', 'anim.frame 80', '--print-anim', 'meshes', '--op', 'sim.free']
    p = subprocess.Popen(['taskset', '-c', CPU, REL, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *a], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=ENV)
    rss = []
    while p.poll() is None:
        try:
            for ln in open(f'/proc/{p.pid}/status'):
                if ln.startswith('VmRSS:'):
                    rss.append(int(ln.split()[1]))
        except OSError:
            break
        time.sleep(0.2)
    _, err = p.communicate()
    rss = [x for x in rss if x > 0]
    if len(rss) < 10:
        check(p.returncode == 0, f'the long run ended cleanly (too quick to sample: {len(rss)} samples)')
        return
    q = len(rss) // 4
    early, late = max(rss[q:2 * q]), max(rss[3 * q:])
    print(f'       RSS: peak in the second quarter {early} kB, in the last {late} kB ({len(rss)} samples)')
    check(p.returncode == 0 and late <= early * 1.1 + 4096, f'no growth over six runs to frame 80 ({early} -> {late} kB)')


SECTIONS = ['s_sims', 's_threads', 's_land', 's_land_cache', 's_cache', 's_damaged', 's_console', 's_undo', 's_window', 's_fuzz', 's_perf', 's_memory']


def main():
    print(f'cloth: seed {SEED}, runs {RUNS}, binary {BIN}')
    try:
        for s in SECTIONS:
            if ONLY and s not in ONLY:
                continue
            globals()[s]()
    finally:
        if not os.environ.get('CL_KEEP'):
            shutil.rmtree(T, ignore_errors=True)
        else:
            print('kept', T)
    _moved = [k for k in set(_REAL0) | set(_real_config()) if _REAL0.get(k) != _real_config().get(k)]
    check(not _moved, f'the user\'s ~/.config untouched by the run ({", ".join(_moved) or "nothing moved"})')
    print(f'cloth: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
