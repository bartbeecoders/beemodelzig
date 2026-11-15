#!/usr/bin/env python3
"""Force fields (fields.zig, fieldui.zig) on BeeModel alone: every type
(attractor, gravity zone, wind, vortex, turbulence, drag), falloffs, laws,
gusts, seeds, groups, on / off, presets, random fields turned and scaled.
Their pull at random points from a script (force()) and from --dump-force
gives the same bits, and stays the same through a saved file; the field.set
words (and the ones it does not understand), the FLDS chunk through save,
open and save, damaged chunks refused cleanly, undo and redo, duplicates,
the keyed strength (field:Name:strength) following its keys, the overlay's
arrows and lines (fieldinfo), the gizmos, the Physics panel, random
sessions on the debug build, and the time a pull takes (shown, not checked).

    python3 tests/fields.py BIN [runs=30] [seed]

BEE_CPU (default 14) pins every run; FIELDS_ONLY=s_values,s_files ... runs some.
"""
import math, os, random, re, struct, subprocess, sys, tempfile, time, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 30
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '14')
ONLY = [x for x in os.environ.get('FIELDS_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beefields-', dir=os.environ.get('BEEFIELDS_TMP', '/tmp'))
import atexit
if not os.environ.get('FIELDS_KEEP'):
    atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, XDG_CACHE_HOME='')
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
TYPES = ['attractor', 'zone', 'wind', 'vortex', 'turbulence', 'drag']


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def script(code, timeout=600):
    """BeeModel runs a script (--run): its stdout. It must end cleanly."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        check(False, f'a script hung: {code[:120]!r}')
        return ''
    if r.returncode != 0 or 'panic' in r.stderr:
        check(False, f'a script stopped ({r.returncode}): {code[:120]!r} {(r.stdout + r.stderr)[-300:]!r}')
    return r.stdout


def port(*a, timeout=600, binary=None, ok=True, shot=None):
    for f in ('force.txt', 'log.txt'):
        if os.path.exists(f'{T}/{f}'):
            os.remove(f'{T}/{f}')
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary or BIN, '--shot', shot or f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a],
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


def ops(*lines):
    out = []
    for ln in lines:
        out += ['--op', ln]
    return out


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]


def bits(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def finite(a):
    return all(math.isfinite(x) for u in a for x in u)


# ---- the pulls ---------------------------------------------------------------------------

def force_code(pts, tag='F'):
    """BeeScript lines printing force() at each point, each axis at two scales
    (print keeps 6 decimals below 1e15: v * 1e9 and v * 1e14 between them give
    every bit down to 1e-12)."""
    out = []
    for p in pts:
        xs = ', '.join(f'force({p[0]}, {p[1]}, {p[2]}, {a}) * 1000000000, force({p[0]}, {p[1]}, {p[2]}, {a}) * 100000000000000' for a in range(3))
        out.append(f'print("{tag}", {xs})')
    return out


def script_forces(text, tag='F'):
    """[(x, y, z)] as f32 from a script's lines (force_code)."""
    res = []
    for ln in text.splitlines():
        w = ln.split()
        if not w or w[0] != tag:
            continue
        v = []
        for a in range(3):
            lo, hi = float(w[1 + 2 * a]), float(w[2 + 2 * a])
            x = lo / 1e9 if abs(lo) >= 1e3 else hi / 1e14
            v.append(f32(x))
        res.append(tuple(v))
    return res


def port_forces():
    res, inf = [], None
    if not os.path.exists(f'{T}/force.txt'):
        return res, inf
    for ln in open(f'{T}/force.txt'):
        w = ln.split()
        if w and w[0] == 'info':
            inf = w[1:]
            continue
        res.append(tuple(f32(float.fromhex(x)) for x in w))
    return res, inf


def dump_arg(pts):
    return f'{T}/force.txt;' + ';'.join(f'{p[0]},{p[1]},{p[2]}' for p in pts)


def same(a, b):
    """Bit for bit (+0 and -0 the same: print shows no sign of a zero)."""
    if len(a) != len(b):
        return False
    for u, v in zip(a, b):
        for x, y in zip(u, v):
            if x == 0 and y == 0:
                continue
            if bits(x) != bits(y) and not (math.isnan(x) and math.isnan(y)):
                return False
    return True


def first_diff(a, b):
    for k, (u, v) in enumerate(zip(a, b)):
        if not same([u], [v]):
            return f'point {k}: {u} / {v}'
    return f'{len(a)} / {len(b)} points'


def rnd(rng, a, b, nd=3):
    return round(rng.uniform(a, b), nd)


def settings(rng, ty):
    w = []
    if rng.random() < 0.8:
        w.append(f'strength {rnd(rng, -30, 30)}')
    if ty != 'zone' and rng.random() < 0.6:
        w.append('falloff ' + rng.choice(['none', 'radius', 'smooth']))
    if rng.random() < 0.6:
        w.append(f'radius {rnd(rng, 0.5, 8)}')
    if ty == 'attractor':
        if rng.random() < 0.5:
            w.append('law ' + rng.choice(['square', 'linear']))
        if rng.random() < 0.5:
            w.append(f'soft {rnd(rng, 0, 1.5)}')
    if ty == 'zone' and rng.random() < 0.6:
        w.append('shape ' + rng.choice(['box', 'sphere']))
    if ty == 'wind' and rng.random() < 0.7:
        w.append(f'gust {rnd(rng, 0, 1)}')
    if ty in ('wind', 'turbulence') and rng.random() < 0.5:
        w.append(f'seed {rng.randint(0, 40)}')
    if ty == 'turbulence' and rng.random() < 0.6:
        w.append(f'scale {rnd(rng, 0.3, 5)}')
    if ty == 'vortex':
        if rng.random() < 0.7:
            w.append(f'lift {rnd(rng, -5, 5)}')
        if rng.random() < 0.7:
            w.append(f'inflow {rnd(rng, -5, 5)}')
    if rng.random() < 0.12:
        w.append('groups ' + rng.choice(['all', '0', '1,2', '0,3,15']))
    if rng.random() < 0.08:
        w.append('off')
    rng.shuffle(w)
    return ' '.join(w)


def scene_code(rng, n, path):
    """n random fields, turned and scaled, saved: (BeeScript, the fields' names)."""
    lines = []
    for k in range(n):
        ty = rng.choice(TYPES)
        nm = f'F{k}'
        lines.append(f'field("{ty}", "{nm}", "{settings(rng, ty)}")')
        lines.append(f'move("{nm}", {rnd(rng, -4, 4)}, {rnd(rng, -3, 3)}, {rnd(rng, -4, 4)})')
        if rng.random() < 0.7:
            lines.append(f'rotate("{nm}", {rnd(rng, -3, 3)}, {rnd(rng, -3, 3)}, {rnd(rng, -3, 3)})')
        if rng.random() < 0.5:
            lines.append(f'scale("{nm}", {rnd(rng, 0.3, 2.5)}, {rnd(rng, 0.3, 2.5)}, {rnd(rng, 0.3, 2.5)})')
    lines.append(f'op("file.save_as", "{path}")')
    return lines


def points(rng, n):
    return [(rnd(rng, -6, 6), rnd(rng, -5, 5), rnd(rng, -6, 6)) for _ in range(n)]


# ---- the pull, bit for bit ------------------------------------------------------------------

def s_values():
    print('-- the pull of every type at random points: a script and --dump-force, bit for bit; through a file --')
    base = [('attractor', 'strength 20 soft 0.1', [(2, 0, 0), (0, 3, 0), (1, 1, 1)]),
            ('attractor', 'strength 20 soft 0.1 law linear', [(2, 0, 0)]),
            ('attractor', 'strength -20 falloff radius radius 3', [(2, 0, 0), (4, 0, 0)]),
            ('attractor', 'strength 20 falloff smooth radius 4', [(2, 0, 0)]),
            ('attractor', 'off', [(2, 0, 0)]),
            ('attractor', 'strength 20 groups 1,2', [(2, 0, 0)]),
            ('attractor', 'strength 20 groups 0,7', [(2, 0, 0)]),
            ('zone', 'strength 3 size 2', [(0, 1, 0), (0, 3, 0)]),
            ('zone', 'strength 3 size 2 shape sphere', [(1, 1, 1), (1.5, 1.5, 0)]),
            ('wind', 'strength 3 gust 0', [(5, 1, 2)]),
            ('wind', 'strength 3 gust 0.8 seed 4', [(5, 1, 2)]),
            ('vortex', 'strength 4 lift 1 inflow 2 falloff none', [(2, 0, 0), (0.5, 3, -1)]),
            ('turbulence', 'strength 5 scale 2', [(0.3, 0.7, 1.1), (4.3, -0.2, 2.9)]),
            ('turbulence', 'strength 5 scale 2 seed 7', [(0.3, 0.7, 1.1)]),
            ('drag', 'strength 0.5', [(1, 1, 1)])]
    bad = []
    for ty, st, pts in base:
        code = [f'field("{ty}", "X", "{st}")'] + force_code(pts)
        o = script_forces(script('\n'.join(code)))
        port('--op', f'field.add_{ty} {st}', '--dump-force', dump_arg(pts))
        p, _ = port_forces()
        if not same(o, p) or len(o) != len(pts) or not finite(p):
            bad.append(f'{ty} {st}: {first_diff(o, p)}')
    check(not bad, f'every type ({len(base)} cases): force() in a script and --dump-force the same bits, finite' + (f' ({bad})' if bad else ''))

    rng = random.Random(SEED)
    nbad = 0
    npts = 0
    for run in range(RUNS):
        path = f'{T}/v{run}.bee'
        pts = points(rng, 12)
        fr = rng.choice([1, 1, 7, 33.5])
        code = scene_code(rng, rng.randint(1, 5), path) + [f'frame({fr})'] + force_code(pts)
        o = script_forces(script('\n'.join(code)))
        port('--op', f'file.open {path}', '--op', f'anim.frame {fr}', '--dump-force', dump_arg(pts))
        p, _ = port_forces()
        npts += len(pts)
        if not same(o, p) or len(o) != len(pts) or not finite(p):
            nbad += 1
            print('      ', run, first_diff(o, p))
    check(nbad == 0, f'random fields turned and scaled ({RUNS} scenes, {npts} points, frames 1 to 33.5): {RUNS - nbad} pull the same bits once saved and opened')

    # time: frame / fps (anim.range sets the fps): gusts and turbulence move with it
    pts = [(1, 0.5, 2), (-2, 1, 0.3)]
    code = ['field("wind", "W", "gust 0.9 seed 2")', 'field("turbulence", "T", "scale 1.5")']
    pa = ['--op', 'field.add_wind gust 0.9 seed 2', '--op', 'field.add_turbulence scale 1.5']
    got = {}
    bad = []
    for rng_ in ([], ['1 250 24'], ['1 250 60'], ['1 200 30'], ['1 100 7.5', '1 200 30']):
        o = script_forces(script('\n'.join(code + [f'op("anim.range", "{r}")' for r in rng_] + ['frame(37)'] + force_code(pts))))
        port(*pa, *ops(*[f'anim.range {r}' for r in rng_]), '--op', 'anim.frame 37', '--dump-force', dump_arg(pts))
        p, _ = port_forces()
        got[' then '.join(rng_)] = p
        if not same(o, p) or len(p) != 2 or not finite(p):
            bad.append(f'{rng_}: {first_diff(o, p)}')
    check(not bad, 'gusts and turbulence at frame 37, no anim.range, then 24, 60, 30, 7.5 then 30 fps: a script and --dump-force the same bits' + (f' ({bad})' if bad else ''))
    g = got
    check(not same(g[''], g['1 250 24']) and not same(g['1 250 24'], g['1 250 60']) and same(g['1 200 30'], g['1 100 7.5 then 1 200 30']),
          'the fps moves them: anim.range 1 250 24 not as without it, 60 not as 24, 7.5 then 30 as 30 alone')
    # the block anim.range makes stays: through a file, and undo takes it away
    port(*pa, '--op', 'anim.range 1 250 24', '--op', f'file.save_as {T}/fpsp.bee',
         '--op', 'file.new', '--op', f'file.open {T}/fpsp.bee', '--op', 'anim.frame 37', '--dump-force', dump_arg(pts))
    p1, _ = port_forces()
    port(*pa, '--op', 'anim.range 1 250 24', '--op', 'edit.undo',
         '--op', 'anim.frame 37', '--dump-force', dump_arg(pts), '--op', 'edit.redo', '--dump-force', dump_arg(pts))
    p2, _ = port_forces()
    check(len(p1) == 2 and same(p1, g['1 250 24']) and len(p2) == 4 and same(p2[:2], g['']) and same(p2[2:], g['1 250 24']),
          f'anim.range 1 250 24 saved and opened: time is still frame / fps; undone: the frame again, redone: / fps ({first_diff(p1, g["1 250 24"])}; {first_diff(p2, g[""] + g["1 250 24"])})')


# ---- operators and the file ---------------------------------------------------------------

def chunk(path, tag):
    try:
        return beefile.chunk(path, tag)
    except Exception:
        return None


def write_bee(path, chs):
    """A version 1 file of these chunks (ZCHK inflated)."""
    out = [b'BEEM', struct.pack('<I', 1)]
    for t, b in chs:
        out += [t, struct.pack('<I', len(b)), b]
    open(path, 'wb').write(b''.join(out))


def objs(path):
    """The objects but the default scene's (whose camera the port turns otherwise)."""
    try:
        return [(o['name'], o['type'], o['loc'], o['rot'], o['scl'], o['color'] if o['type'] == 5 else None) for o in beefile.objects(path) if o['name'] not in ('Camera', 'Light', 'Cube')]
    except Exception:
        return None


BOGUS = ['bogus', 'strength', 'strength x', 'falloff far', 'groups 16', 'groups 1,,2', 'groups ,', 'groups 0x1', 'law cubic',
         'type nothing', 'seed 1e12', 'seed -3.7', 'type planet', 'type breeze', 'on', 'off', 'gust nan']


TNAMES = {'attractor': 'Attractor', 'zone': 'Gravity Zone', 'wind': 'Wind', 'vortex': 'Vortex', 'turbulence': 'Turbulence', 'drag': 'Drag',
          'blackhole': 'Black Hole', 'tornado': 'Tornado', 'breeze': 'Breeze', 'planet': 'Planet Core'}


def random_ops(rng, n):
    """Field operators, as a script and as arguments: [(BeeScript, --op args)]; names followed as
    unique_name gives them (base, base.001 ...)."""
    names = {'Camera', 'Light', 'Cube'}
    fields = []
    active = [None]

    def unique(base):
        nm, k = base, 0
        while nm in names:
            k += 1
            nm = f'{base}.{k:03d}'
        names.add(nm)
        return nm
    steps = []
    for k in range(n):
        r = rng.random()
        if r < 0.35 or not fields:
            ty = rng.choice(TYPES + ['blackhole', 'tornado', 'breeze'] + (['planet'] if 'Planet' not in names else []))
            st = settings(rng, ty) if ty in TYPES else ''
            if rng.random() < 0.2:
                st += ' ' + rng.choice(BOGUS)
            if ty == 'planet':
                names.add('Planet')
            nm = unique(TNAMES[ty])
            fields.append(nm)
            active[0] = nm
            steps.append((f'op("field.add_{ty}", "{esc(st)}")', ['--op', f'field.add_{ty} {st}']))
        elif r < 0.7:
            w = settings(rng, rng.choice(TYPES))
            if rng.random() < 0.4:
                w += ' type ' + rng.choice(TYPES)
            if rng.random() < 0.25:
                w += ' ' + rng.choice(BOGUS)
            steps.append((f'op("field.set", "{esc(w)}")', ['--op', f'field.set {w}']))
        elif r < 0.85:
            nm = rng.choice(fields)
            active[0] = nm
            steps.append((f'select("{nm}")', ['--select', nm]))
        else:
            base = re.sub(r'\.\d\d\d$', '', active[0])
            nm = unique(base)
            fields.append(nm)
            active[0] = nm
            steps.append(('op("object.duplicate")', ['--op', 'object.duplicate']))
    return steps


def s_ops():
    print('-- field.add_*, the presets, field.set (and words it does not understand), duplicates: as a script and as --op, FLDS through save, open, save --')
    rng = random.Random(SEED + 1)
    nbad = 0
    nrun = max(4, RUNS // 2)
    for run in range(nrun):
        steps = random_ops(rng, rng.randint(2, 9))
        pp, pq = f'{T}/op{run}.bee', f'{T}/oq{run}.bee'
        pts = points(rng, 4)
        o = script_forces(script('\n'.join([s[0] for s in steps] + force_code(pts))))
        a = []
        for s in steps:
            a += s[1]
        port(*a, '--dump-force', dump_arg(pts), '--op', f'file.save_as {pp}')
        p, _ = port_forces()
        port('--op', f'file.open {pp}', '--dump-force', dump_arg(pts), '--op', f'file.save_as {pq}')
        q, _ = port_forces()
        why = []
        if chunk(pp, b'FLDS') is None or chunk(pp, b'FLDS') != chunk(pq, b'FLDS'):
            why.append(f'FLDS {(chunk(pp, b"FLDS") or b"").hex()[:80]} / {(chunk(pq, b"FLDS") or b"").hex()[:80]}')
        if objs(pp) is None or objs(pp) != objs(pq):
            why.append(f'objects {objs(pp)} / {objs(pq)}')
        if not same(o, p) or len(p) != len(pts):
            why.append('script / --op pulls ' + first_diff(o, p))
        if not same(p, q) or not finite(p):
            why.append('pulls once opened ' + first_diff(p, q))
        if why:
            nbad += 1
            print('      ', run, '; '.join(why)[:600], [s[1] for s in steps])
    check(nbad == 0, f'random operator sequences ({nrun}): {nrun - nbad} pull the same bits as a script and as --op, and once saved and opened; FLDS and the objects the same after save, open, save')


def s_files():
    print('-- files through save, open, save; damaged FLDS chunks --')
    rng = random.Random(SEED + 2)
    nbad = 0
    nrun = max(3, RUNS // 4)
    for run in range(nrun):
        po, pp = f'{T}/fo{run}.bee', f'{T}/fp{run}.bee'
        pts = points(rng, 6)
        a = script_forces(script('\n'.join(scene_code(rng, rng.randint(1, 6), po) + force_code(pts))))
        port('--op', f'file.open {po}', '--op', f'file.save_as {pp}')
        port('--op', f'file.open {pp}', '--dump-force', dump_arg(pts))
        b, _ = port_forces()
        if chunk(po, b'FLDS') is None or chunk(po, b'FLDS') != chunk(pp, b'FLDS') or objs(po) != objs(pp) or not same(a, b) or len(a) != len(pts):
            nbad += 1
            print('      ', run, (chunk(po, b'FLDS') or b'').hex()[:64], (chunk(pp, b'FLDS') or b'').hex()[:64], first_diff(a, b))
    check(nbad == 0, f'scripts\' files ({nrun}) opened and saved again: FLDS and the objects byte for byte, the pulls the script printed')

    # damaged chunks: refused or read cleanly, the same pulls once saved and opened again
    po = f'{T}/dmg.bee'
    script('\n'.join(['field("attractor", "A", "strength 7 falloff smooth radius 5")', 'field("vortex", "V", "lift 2")', 'move("V", 1, 0, 1)',
                      'field("wind", "W", "gust 0.5 seed 3")', 'rotate("W", 0, 0.7, 0)', f'op("file.save_as", "{po}")']))
    chs = beefile.chunks(po)
    fl = next(b for t, b in chs if t == b'FLDS')
    n = struct.unpack_from('<I', fl)[0]
    check(n == 3 and len(fl) == 4 + 64 * n, f'three fields saved: FLDS of 3 records ({n}, {len(fl)} bytes)')

    def with_flds(b):
        return [(t, b if t == b'FLDS' else c) for t, c in chs]

    def rec_set(k, off, val, fmt='<I'):
        b = bytearray(fl)
        struct.pack_into(fmt, b, 4 + k * 64 + off, val)
        return bytes(b)
    cases = {
        'no FLDS': [(t, c) for t, c in chs if t != b'FLDS'],
        'empty': with_flds(b''),
        '2 bytes': with_flds(b'\x03\x00'),
        'a count past its records': with_flds(struct.pack('<I', n + 1) + fl[4:]),
        'a count of 300': with_flds(struct.pack('<I', 300) + fl[4:]),
        'cut in a record': with_flds(fl[:4 + 64 + 20]),
        'records past the count': with_flds(struct.pack('<I', 1) + fl[4:]),
        'type 9': with_flds(rec_set(0, 4, 9)),
        'type 0xffffffff, falloff 7': with_flds(rec_set(rec_set and 1, 4, 0xffffffff)),
        'falloff 7': with_flds(rec_set(0, 12, 7)),
        'law 5 on a vortex, seed -2^31': with_flds(rec_set(2, 52, 0x80000000)),
        'a NaN strength': with_flds(rec_set(0, 8, float('nan'), '<f')),
        'an infinite radius': with_flds(rec_set(1, 16, float('inf'), '<f')),
        'a zero scale, groups 0xffffffff': with_flds(rec_set(1, 32, 0xffffffff)),
        'a uid no object has': with_flds(rec_set(0, 0, 999)),
    }
    pts = [(0.5, 0.5, 0.5), (2, -1, 3), (1, 0, 1), (-4, 2, 0.3)]
    bad = []
    for k, (what, cc) in enumerate(cases.items()):
        path = f'{T}/d{k}.bee'
        write_bee(path, cc)
        r = port('--op', f'file.open {path}', '--dump-force', dump_arg(pts), '--op', f'file.save_as {T}/d{k}p.bee')
        a, _ = port_forces()
        r2 = port('--op', f'file.open {T}/d{k}p.bee', '--dump-force', dump_arg(pts))
        b, _ = port_forces()
        if r is None or r.returncode != 0 or r2 is None or r2.returncode != 0 or len(a) != len(pts) or not same(a, b):
            bad.append(f'{what}: {first_diff(a, b)}')
    check(not bad, f'damaged FLDS chunks ({len(cases)}: missing, short, counts past the records, types, falloffs, NaN, infinity): no crash, a pull at every point, the same once saved and opened' + (f' ({bad})' if bad else ''))


def s_keyed():
    print('-- the keyed strength (field:Name:strength), frame by frame --')
    pts = [(-1, 0, 0), (2, 1, -1)]
    # keys 10 at 1 and 50 at 101 (linear), -5 at 120: the strength each frame
    frames = [(1, 10), (20, 17.6), (51, 30), (77.5, 40.6), (130, -5)]
    keys = ['field:A:strength 1 10 linear', 'field:A:strength 101 50 linear', 'field:A:strength 120 -5']
    base = f'{T}/kb.bee'
    script('\n'.join(['field("attractor", "A", "strength 10 soft 0.1")', 'field("drag", "D")', 'op("object.duplicate")', 'move(active(), 5, 0, 0)', 'select("A")',
                      f'op("file.save_as", "{base}")']))
    a = ['--op', f'file.open {base}', '--select', 'A'] + ops(*[f'anim.key {k}' for k in keys])
    for f, _ in frames:
        a += ['--op', f'anim.frame {f}', '--dump-force', dump_arg(pts)]
    a += ['--op', 'edit.undo']
    port(*a)
    p, _ = port_forces()
    # the attractor's pull goes with its strength (the drag pulls nothing at rest, gravity is on y): x as the strength
    ok = len(p) == len(frames) * len(pts) and finite(p) and p[0][0] != 0
    if ok:
        for k, (f, s) in enumerate(frames):
            for j in range(len(pts)):
                ok = ok and abs(p[k * len(pts) + j][0] - p[j][0] * s / 10) <= 1e-4 * abs(p[j][0] * s / 10) + 1e-6
    check(ok, f'the strength keyed 10, 50 (linear), -5: the pull along x at frames {[f for f, _ in frames]} as strength {[s for _, s in frames]} ({[round(x[0], 5) for x in p]})')
    lg = plog()
    check('Undo: Insert Keyframe' in lg or re.search(r'Undo: .*[Kk]ey', lg) is not None,
          f'played frames are no undo step: Ctrl+Z after them undoes the last key ({re.findall(r"Undo: .*", lg)})')


def s_undo():
    print('-- undo and redo, duplicates, a hidden field --')
    pp = [f'{T}/u{k}.bee' for k in range(6)]
    port('--op', 'field.add_attractor', '--op', 'field.set strength 30 groups 2', '--op', f'file.save_as {pp[0]}',
         '--op', 'edit.undo', '--op', f'file.save_as {pp[1]}', '--op', 'edit.redo', '--op', f'file.save_as {pp[2]}',
         '--op', 'edit.undo', '--op', 'edit.undo', '--op', f'file.save_as {pp[3]}',
         '--op', 'edit.redo', '--op', 'object.duplicate', '--op', 'field.set strength 4', '--op', f'file.save_as {pp[4]}',
         '--op', 'edit.undo', '--op', 'edit.undo', '--op', f'file.save_as {pp[5]}')

    def recs(p):
        c = chunk(p, b'FLDS')
        if c is None:
            return None
        n = struct.unpack_from('<I', c)[0]
        return [(struct.unpack_from('<I', c, 4 + k * 64)[0], round(struct.unpack_from('<f', c, 4 + k * 64 + 8)[0], 3), struct.unpack_from('<I', c, 4 + k * 64 + 32)[0]) for k in range(n)]

    def kinds(p):
        o = objs(p)
        return None if o is None else [x[1] for x in o].count(5)
    r = [recs(p) for p in pp]
    k = [kinds(p) for p in pp]
    check(r[0] == [(4, 30.0, 0xfffb)] and r[1] == [(4, 10.0, 0)] and r[2] == r[0], f'field.set undone and redone: strength 30 groups 2, back to 10, again 30 ({r[:3]})')
    check(k[3] == 0 and r[3] in ([], None) and k[2] == 1, f'undo past Add: no field and no record ({k[3]}, {r[3]})')
    # (redo brings the Add back, not the field.set undone before it)
    check(k[4] == 2 and r[4] == [(4, 10.0, 0), (5, 4.0, 0)], f'a duplicate gets its own record (then strength 4: {r[4]})')
    check(k[5] == 1 and r[5] == [(4, 10.0, 0)], f'the strength and the duplicate undone: one field, its record ({k[5]}, {r[5]})')

    # the view after undo: what is drawn follows (viewport stateKey)
    port('--op', 'field.add_vortex', '--op', 'field.set radius 2 falloff radius', '--move', '600,300', '--op', 'edit.undo', '--move', '600,310', shot=f'{T}/ua.ppm')
    port('--op', 'field.add_vortex', '--move', '600,300', '--move', '600,310', shot=f'{T}/ub.ppm')
    port('--op', 'field.add_vortex', '--op', 'field.set radius 2 falloff radius', '--move', '600,300', '--move', '600,310', shot=f'{T}/uc.ppm')
    from PIL import Image
    ua, ub, uc = (Image.open(f'{T}/{x}.ppm').crop((215, 90, 1020, 620)).tobytes() if os.path.exists(f'{T}/{x}.ppm') else None for x in ('ua', 'ub', 'uc'))
    check(ua is not None and ua == ub and ua != uc, 'the view after undo: the vortex\'s reach drawn at its radius before (the same pixels as never changed)')

    # hidden and off: no pull
    pts = [(1, 0, 0)]
    port('--op', 'field.add_attractor', '--op', 'object.hide', '--op', 'field.add_wind off', '--dump-force', dump_arg(pts))
    p, _ = port_forces()
    check(len(p) == 1 and abs(p[0][1] + 9.81) < 1e-5 and p[0][0] == 0 and p[0][2] == 0, f'a hidden field and one switched off pull nothing (gravity only: {p})')
    # a field.set with nothing active, a field not active
    port('--op', 'field.set strength 3')
    check('select a force field first' in plog(), 'field.set without a field: "select a force field first (Add > Force Field)"')


def s_presets():
    print('-- the presets: Planet (a 10 m sphere, the world\'s gravity off), Black Hole, Tornado, Breeze --')
    pts = [(10, 0, 0), (0, -12, 3), (3, 1, 0.5)]
    o = script_forces(script('\n'.join(['op("field.add_planet")', 'op("field.add_blackhole")', 'op("field.add_tornado")', 'op("field.add_breeze")'] + force_code(pts))))
    port(*ops('field.add_planet', 'field.add_blackhole', 'field.add_tornado', 'field.add_breeze'), '--dump-force', dump_arg(pts), '--op', f'file.save_as {T}/pr_p.bee')
    p, _ = port_forces()
    port('--op', f'file.open {T}/pr_p.bee', '--dump-force', dump_arg(pts), '--op', f'file.save_as {T}/pr_q.bee')
    q, _ = port_forces()
    a, b = objs(f'{T}/pr_p.bee'), objs(f'{T}/pr_q.bee')
    names = [x[0] for x in (a or [])]
    fl = chunk(f'{T}/pr_p.bee', b'FLDS')
    check(same(o, p) and len(p) == 3 and finite(p) and same(p, q) and a == b and fl is not None and fl == chunk(f'{T}/pr_q.bee', b'FLDS')
          and all(x in names for x in ('Planet', 'Planet Core', 'Black Hole', 'Tornado', 'Breeze')) and struct.unpack_from('<I', fl)[0] == 4,
          f'every preset: its objects ({names}), 4 field records; the pulls as a script and as --op, and the same with FLDS once saved and opened ({first_diff(o, p)}; {first_diff(p, q)})')
    an = chunk(f'{T}/pr_p.bee', b'ANIM')
    check(an is not None and len(an) > 55920, f'the world\'s gravity off is kept in the file (ANIM {len(an or b"")} bytes)')


# ---- the overlay, the gizmos and the panel --------------------------------------------------

def s_overlay():
    print('-- View > Force Field Arrows and Lines: what they draw (fieldinfo), the gizmos --')
    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        check(False, 'PIL for the shots')
        return
    scenes = {
        'tornado': ['field("tornado")', 'select("Cube")'],
        'attract': ['field("attractor", "A", "strength 30 falloff smooth radius 6")', 'move("A", 2, 1, 0)', 'field("wind", "W", "gust 0.4")', 'select("Cube")'],
        'push': ['field("attractor", "P", "strength -5")', 'move("P", 0, 2, 0)', 'field("drag", "D")', 'move("D", -3, 0, 0)', 'field("vortex", "V", "strength -2")', 'move("V", 3, 0, -1)', 'select("Cube")'],
        'zone': ['field("zone", "Z", "strength 3 size 3")', 'rotate("Z", 0.5, 0, 0)', 'field("turbulence", "T")', 'move("T", -3, 0, 2)', 'select("Cube")'],
    }
    D = f'{T}/ov'
    os.makedirs(D, exist_ok=True)
    for nm, code in scenes.items():
        base = f'{D}/{nm}.bee'
        script('\n'.join(code + [f'op("file.save_as", "{base}")']))
        names = [fn or 'Tornado' for fn in re.findall(r'field\("\w+"(?:, "(\w+)")?', ' '.join(code))]
        port('--op', f'file.open {base}', '--op', 'view.field_arrows', '--op', 'view.field_lines', '--select', 'Cube', '--move', '600,300', '--dump-force', f'{T}/force.txt',
             '--op', 'area.maximize', '--move', '600,310', shot=f'{D}/p_ov_{nm}.ppm')
        _, pi = port_forces()
        try:
            iv = [int(float(x)) for x in pi[:3]] + [float.fromhex(pi[3])]
        except (TypeError, ValueError, IndexError):
            iv = None
        check(iv is not None and iv[0] > 0 and iv[1] > 0 and math.isfinite(iv[3]) and iv[3] > 0,
              f'{nm}: the overlay draws arrows and line segments, its largest pull finite ({pi})')
        port('--op', f'file.open {base}', '--select', 'Cube', '--move', '600,300', '--op', 'area.maximize', shot=f'{D}/p_{nm}.ppm')
        hide = []
        for fn in names:
            hide += ['--select', fn, '--op', 'object.hide']
        port('--op', f'file.open {base}', *hide, '--select', 'Cube', '--move', '600,300', '--op', 'area.maximize', shot=f'{D}/pc_{nm}.ppm')
        for what, b, bc in (('gizmos', 'p', 'pc'), ('overlay\'s arrows and lines', 'p_ov', 'p')):
            nb = added(f'{D}/{b}_{nm}.ppm', f'{D}/{bc}_{nm}.ppm')
            check(nb > 200, f'{nm}: the {what} drawn in the maximized viewport ({nb} pixels of lines more)')


def added(b, bc):
    """The pixels of lines a shot adds to its control (lines apart from the
    background round them, lighter or darker, not within a pixel of the control's)."""
    from PIL import Image, ImageFilter, ImageChops
    box = (300, 150, 980, 700)
    if not (os.path.exists(b) and os.path.exists(bc)):
        return 0

    def lines(p):
        im = Image.open(p).convert('L').crop(box)
        return ImageChops.difference(im, im.filter(ImageFilter.MedianFilter(9))).point(lambda v: 255 if v > 30 else 0)
    fb = ImageChops.subtract(lines(b), lines(bc).filter(ImageFilter.MaxFilter(3)))
    return sum(1 for v in fb.tobytes() if v)


def s_ui():
    print('-- Properties > Physics: the Force Field section\'s rows, Add > Force Field from the menu, typed values, undo --')
    port('--op', 'field.add_vortex', '--click-label', 'tab:Physics', '--move', '600,300')
    rows = [ln.rstrip('\n').split('\t') for ln in open(f'{T}/u.txt')] if os.path.exists(f'{T}/u.txt') else []

    def prow(kind, label):
        for r in rows:
            if len(r) >= 3 and r[0] == kind and r[1] == label:
                return [int(x) for x in r[2].split()]
        return None
    want = [('section', 'Force Field'), ('enum', 'Vortex'), ('checkbox', 'On'), ('number', 'Strength'), ('enum', 'Smooth'), ('number', 'Radius (m)'),
            ('number', 'Lift'), ('number', 'Inflow'), ('number', 'Only group (-1: all)')]
    got = [prow(k, lb) for k, lb in want]
    check(all(got), f'the rows: section, Type, On, Strength, Falloff, Radius, Lift, Inflow, Only group ({[bool(a) for a in got]})')
    if all(got):
        ys = [a[1] for a in got]
        check(all(x <= y for x, y in zip(ys, ys[1:])) and ys[0] < ys[-1], f'the rows top to bottom in that order, below the section ({ys})')
    check(prow('info', 'Turns things round its +Y.') is not None, 'the type\'s line: "Turns things round its +Y."')
    # an attractor: its pull and soft core; a zone: shape and half size, no falloff
    port('--op', 'field.add_attractor', '--click-label', 'tab:Physics')
    rows = [ln.rstrip('\n').split('\t') for ln in open(f'{T}/u.txt')]
    check(prow('enum', '1 / d^2') and prow('number', 'Soft core (m)') and not prow('number', 'Radius (m)'), 'an attractor: Pull 1 / d^2, Soft core, no Radius (falloff none)')
    port('--op', 'field.add_zone', '--click-label', 'tab:Physics')
    rows = [ln.rstrip('\n').split('\t') for ln in open(f'{T}/u.txt')]
    check(prow('enum', 'Box') and prow('number', 'Half size (m)') and not prow('caption', 'Falloff'), 'a gravity zone: Shape Box, Half size, no Falloff')
    # Add > Force Field > Vortex from the menu; Strength typed 9, Enter, Ctrl+Z
    pts = [(2, 0, 0)]
    port('--click-label', 'menu:Add', '--move-label', 'menuitem:Force Field', '--click-label', 'menuitem:Vortex', '--click-label', 'tab:Physics',
         '--click-label', 'number:Strength', '--type', '9', '--key', 'enter', '--dump-force', dump_arg(pts), '--key', 'ctrl+z', '--dump-force', dump_arg(pts))
    p, _ = port_forces()
    fall = (1 - (2 / 5) ** 2) ** 2
    check(len(p) == 2 and abs(p[0][2] + 9 * fall) < 1e-4 and abs(p[1][2] + 5 * fall) < 1e-4,
          f'Add > Force Field > Vortex from the menu, Strength typed 9 in the panel (the pull at 2 m: {p[:1]}); Ctrl+Z: back to 5 ({p[1:]})')
    # a value typed and then Esc: nothing changes, no undo step
    port('--op', 'field.add_vortex', '--click-label', 'tab:Physics', '--click-label', 'number:Strength', '--type', '9', '--key', 'esc',
         '--dump-force', dump_arg(pts), '--key', 'ctrl+z', '--dump-force', dump_arg(pts))
    p, _ = port_forces()
    check(len(p) == 2 and abs(p[0][2] + 5 * fall) < 1e-4 and p[1][2] == 0, f'Strength typed then Esc: still 5; Ctrl+Z then undoes the Add (no field: {p})')
    # the type picked in the panel: its defaults; the group: skip bits
    port('--op', 'field.add_vortex', '--click-label', 'tab:Physics', '--click-label', 'enum:Vortex', '--click-label', 'menuitem:Attractor',
         '--click-label', 'number:Only group (-1: all)', '--type', '3', '--key', 'enter', '--op', f'file.save_as {T}/ui.bee')
    c = chunk(f'{T}/ui.bee', b'FLDS')
    r = struct.unpack_from('<2I2fI', c, 4) if c and len(c) >= 24 else None
    sk = struct.unpack_from('<I', c, 4 + 32)[0] if c and len(c) >= 40 else None
    check(r is not None and r[1] == 0 and r[2] == 10.0 and sk == 0xfff7, f'Type Attractor picked: its defaults (strength 10); Only group 3: the others left alone ({r}, {sk and hex(sk)})')


# ---- stability, time ------------------------------------------------------------------------

def s_fuzz():
    print('-- random operators and words, damaged chunks on this build: no crash --')
    rng = random.Random(SEED + 9)
    bad = 0
    words = [w for t, _ in [(x, 0) for x in fp_words()] for w in [t]]
    for run in range(RUNS):
        a = []
        for _ in range(rng.randint(3, 25)):
            r = rng.random()
            if r < 0.3:
                a += ['--op', f'field.add_{rng.choice(TYPES + ["planet", "blackhole", "tornado", "breeze"])} ' + ' '.join(rng.choice(words) for _ in range(rng.randint(0, 6)))]
            elif r < 0.6:
                a += ['--op', 'field.set ' + ' '.join(rng.choice(words) for _ in range(rng.randint(0, 8)))]
            elif r < 0.7:
                a += ['--op', rng.choice(['edit.undo', 'edit.redo', 'object.duplicate', 'object.delete', 'view.field_arrows', 'view.field_lines', 'object.hide', 'object.select_all'])]
            elif r < 0.8:
                a += ['--op', f'anim.frame {rng.randint(-50, 500)}']
            elif r < 0.9:
                a += ['--op', f'anim.key field:{rng.choice(["Attractor", "Wind", "Vortex", "Drag"])}:strength {rng.randint(1, 100)} {rnd(rng, -1e4, 1e4)}']
            else:
                a += ['--dump-force', dump_arg(points(rng, 3))]
        a += ['--op', f'file.save_as {T}/fz.bee', '--op', f'file.open {T}/fz.bee', '--click-label', 'tab:Physics']
        r = port(*a, ok=False)
        if r is None or r.returncode != 0:
            bad += 1
            print('      ', run, r and r.stderr[-400:], a)
    check(bad == 0, f'{RUNS} random sessions: no panic, no hang')


def fp_words():
    return ['strength', '3', '-1e9', 'nan', 'inf', 'falloff', 'none', 'radius', 'smooth', 'size', 'law', 'linear', 'shape', 'sphere', 'gust', '0.5', 'scale',
            '0', 'seed', '99999999999', 'lift', 'inflow', 'soft', 'groups', 'all', '0,15', '16', 'type', 'vortex', 'planet', 'on', 'off', 'x', '']


def s_time():
    print('-- the time a pull takes (a release build, one CPU; shown, not checked) --')
    rel = os.environ.get('FIELDS_REL')
    if not rel:
        print('       (FIELDS_REL unset: the release build to time; skipped)')
        return
    rng = random.Random(5)
    base = f'{T}/tm.bee'
    script('\n'.join(scene_code(rng, 12, base)))
    N = 20000
    t0 = time.time()
    r1 = port('--op', f'file.open {base}', '--dump-force', f'{T}/force.txt;0,1,2', binary=rel)
    t1 = time.time()
    r2 = port('--op', f'file.open {base}', '--dump-force', f'{T}/force.txt;rep:{N};0,1,2', binary=rel)
    t2 = time.time()
    tp = ((t2 - t1) - (t1 - t0)) / N * 1e6
    print(f'       force() at a point, 12 fields: {round(tp, 2)} us (its argument parsing and output included)')
    p, _ = port_forces()
    check(r1 is not None and r2 is not None and r2.returncode == 0 and len(p) == 1 and finite(p), f'{N} pulls in a row: one answer, finite ({p})')


# ---- main -----------------------------------------------------------------------------------

def main():
    print(f'fields: {BIN}, runs {RUNS}, seed {SEED}')
    for f in [s_values, s_ops, s_files, s_keyed, s_undo, s_presets, s_overlay, s_ui, s_fuzz, s_time]:
        if ONLY and f.__name__ not in ONLY:
            continue
        f()
    print(f'fields: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
