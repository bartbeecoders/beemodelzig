#!/usr/bin/env python3
"""The B-rep kernel (nurbs, brep, bbuild, bssi, btess, bbool) on its own:
features replayed by src/breptest.zig (a driver that replays bfeat.s's
sequence), each result checked for what holds without anything to compare to:

  * NURBS checks (nurbscheck 0..6): each error finite and below 1e-6;
  * solids from sketches (boxes, cylinders, cones, tori, part revolutions,
    plates with holes, spheres): valid, watertight, the exact volume and area
    where a formula gives them, the surface kinds; for every body the numbers
    finite, the faces the sum of their surface kinds, V - E + 2F - L even,
    and the tessellation reads back (indices in range, coordinates finite,
    its triangles as many as said, its volume the tessvolume said);
  * booleans (a pocket, holes, a boss on a face, a hole drilled across a rod,
    four holes, a shell): the volumes to 1e-9, the same sane results;
  * random parts: boxes and cylinders padded, pocketed and drilled at random
    places (coplanar faces, crossings, touching): every body sane or failed
    with an error (brep(..., "error")), and a second run the same to the byte;
  * damaged and degenerate input (zero sizes, open profiles, NaN-free junk,
    huge counts) on the debug build: no crash, no hang.

    python3 tests/brep.py BIN [random-runs=40] [seed]

BIN is the app (unused by the kernel sections; kept for the common shape);
the driver is built from src/breptest.zig with zig into a temp dir
(BREP_DRIVER=path uses a built one). BREP_ONLY=s_solids,... runs some sections.
"""
import math, os, random, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
BUILD_ENV = dict(os.environ)  # (the driver's build: the user's own HOME, where mise keeps zig)
import temphome  # (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 40
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '10')
PIN = [] if CPU == 'none' else ['taskset', '-c', CPU]   # (none: unpinned, for the mutants)
FAILS = []
T = tempfile.mkdtemp(prefix='beebrep-')
P = 3.14159265358979


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def zig():
    if shutil.which('zig'):
        return ['zig']
    return ['mise', 'exec', '--', 'zig']


def build_driver(mode):
    out = os.path.join(T, 'breptest-' + mode)
    src = os.environ.get('BREP_DEBUG_SRC') if mode == 'Debug' else None
    r = subprocess.run(zig() + ['build-exe', src or os.path.join(ROOT, 'src/breptest.zig'), '-O' + mode,
                                '--cache-dir', os.path.join(T, 'zcache'), '-femit-bin=' + out],
                       capture_output=True, text=True, cwd=ROOT, env=BUILD_ENV)
    if r.returncode != 0:
        print(r.stderr[-3000:])
        return None
    return out


DRIVER = os.environ.get('BREP_DRIVER')
DEBUG_DRIVER = None


def num(x):
    """a literal the driver reads to the same double (<= 15 digits)"""
    if isinstance(x, str):
        return x
    return repr(float('%.15g' % x))


def driver_script(ops):
    out = []
    for o in ops:
        k = o[0]
        if k == 'sketch':
            out.append('sketch %s %s %s' % (o[1], o[2], num(o[3])))
        elif k in ('pad', 'pocket', 'revolve'):
            out.append('%s %s %s %s%s' % (k, o[1], o[2], num(o[3]), ' ' + o[5] if len(o) > 5 else ''))
        elif k == 'hole':
            out.append('hole %s %s %s%s' % (o[1], o[2], num(o[3]), ' ' + num(o[4]) if len(o) > 4 else ''))
        elif k == 'shell':
            out.append('shell %s %d %s%s' % (o[1], o[2], num(o[3]), ' bottom' if len(o) > 4 else ''))
        elif k == 'line':
            out.append('line %s %d %d' % (o[1], o[2], o[3]))
        else:
            out.append('%s %s %s' % (k, o[1], ' '.join(num(v) for v in o[2:])))
    return '\n'.join(out) + '\n'


EXTRA_ENV = {}


def run_port(ops, tag, driver=None, timeout=300):
    d = os.path.join(T, tag)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, 'p.txt')
    open(path, 'w').write(driver_script(ops))
    r = subprocess.run(PIN + [driver or DRIVER, path, d], capture_output=True, text=True, timeout=timeout,
                       env=dict(os.environ, **EXTRA_ENV))
    return d, rows(r.stdout), r


def rows(text):
    out = {}
    for line in text.splitlines():
        f = line.split()
        if len(f) >= 2 and f[0] == 'C' and f[1] in out:
            for x in f[2:]:
                try:
                    out[f[1]].append(float(x))
                except ValueError:
                    out[f[1]].append(x)
            continue
        if len(f) >= 2 and f[0] in ('B', 'n0', 'n1', 'n2', 'n3', 'n4', 'n5', 'n6'):
            key = f[1] if f[0] == 'B' else f[0]
            vals = []
            for x in (f[2:] if f[0] == 'B' else f[1:]):
                try:
                    vals.append(float(x))
                except ValueError:
                    vals.append(x)
            out[key] = vals
    return out


def tri(d, name):
    """A body's tessellation as the driver wrote it: (vertices, triangles) or an error text."""
    try:
        t = open(os.path.join(d, name + '.tri'), 'rb').read()
        nv, nt = struct.unpack_from('<II', t)
        v = struct.unpack_from(f'<{nv * 3}f', t, 8)
        tr = struct.unpack_from(f'<{nt * 3}I', t, 8 + nv * 12)
        if len(t) != 8 + nv * 12 + nt * 12:
            return f'{len(t)} bytes for {nv} vertices, {nt} triangles'
    except (OSError, struct.error) as e:
        return f'no mesh ({e})'
    return [v[i:i + 3] for i in range(0, len(v), 3)], [tr[i:i + 3] for i in range(0, len(tr), 3)]


def tri_volume(vs, ts):
    s = 0.0
    for a, b, c in ts:
        (ax, ay, az), (bx, by, bz), (cx, cy, cz) = vs[a], vs[b], vs[c]
        s += ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx)
    return s / 6


def sane(name, f, d):
    """What is wrong with a body's row and mesh, or None."""
    if f[:1] == ['none']:
        return None if len(f) >= 2 and isinstance(f[-1], float) and f[-1] == int(f[-1]) else f'failed without an error code: {f}'
    # (an invalid body kept, BEEMODEL_BREP_KEEP, may have no volume or area: NaN)
    if len(f) != 17 or not all(isinstance(x, float) and (math.isfinite(x) or (k < 2 and f[6] == 0 and x != x)) for k, x in enumerate(f)):
        return f'not 17 finite numbers: {f}'
    vol, area, nf, ne, nv, nl, valid, tight, nt, tv = f[:10]
    counts = f[2:9] + f[10:16]
    if any(x < 0 or x != int(x) for x in counts) or valid not in (0, 1) or tight not in (0, 1):
        return f'counts not whole, not 0 or more: {f}'
    if nf != sum(f[10:16]):
        return f'{nf:.0f} faces, {sum(f[10:16]):.0f} by their surface kinds'
    if valid and tight:
        if vol <= 0 or area <= 0:
            return f'valid and watertight with volume {vol}, area {area}'
        if int(nv - ne + 2 * nf - nl) % 2:
            return f'V - E + 2F - L odd ({nv:.0f} {ne:.0f} {nf:.0f} {nl:.0f})'
    m = tri(d, name)
    if isinstance(m, str):
        return m if nt else None
    vs, ts = m
    if len(ts) != nt:
        return f'{len(ts)} triangles in the mesh, {nt:.0f} said'
    if any(i >= len(vs) for t in ts for i in t) or not all(math.isfinite(c) for v in vs for c in v):
        return 'a triangle past the vertices or a coordinate not finite'
    if valid and tight and nt:
        mv = tri_volume(vs, ts)
        if abs(mv - tv) > 1e-4 * max(abs(tv), 1e-3):
            return f'the mesh holds volume {mv:.7g}, tessvolume says {tv:.7g}'
    return None


def ops_bodies(ops):
    out = []
    for o in ops:
        if o[0] in ('pad', 'pocket', 'revolve', 'hole', 'shell') and o[1] not in out:
            out.append(o[1])
    return out


def compare(ops, tag, what, bodies=None, quiet=False, silent=False, driver=None):
    """the driver; per body: a sane row and mesh, or a failure with its error"""
    d, po, r = run_port(ops, tag, driver)
    names = bodies or ops_bodies(ops)
    good = r.returncode == 0
    notes = [] if good else [f'exit {r.returncode} {r.stderr[-300:]}']
    for n in names:
        a = po.get(n)
        why = 'no row' if a is None else sane(n, a, d)
        if why:
            good = False
            notes.append(f'{n}: {why}')
    if not silent and (not quiet or not good):
        check(good, f'{what}: ' + ('; '.join(notes[:4]) if notes else f'{len(names)} bodies: sane rows, meshes that read back'))
    return good, po, d


# ---- sections -----------------------------------------------------------------------------

def s_nurbs():
    print('  -- NURBS --')
    d, po, _ = run_port([], 'nurbs0')
    open(os.path.join(d, 'p.txt'), 'w').write('nurbscheck\n')
    r = subprocess.run([DRIVER, os.path.join(d, 'p.txt'), d], capture_output=True, text=True, timeout=60)
    po = rows(r.stdout)
    names = ['arcs on their circles', 'knot insertion', 'degree elevation', 'curve derivatives',
             'a NURBS cylinder, knots and degrees added', 'surface derivatives', 'a NURBS torus']
    for k in range(7):
        a = po.get('n%d' % k, ['?'])[0]
        check(isinstance(a, float) and 0 <= a < 1e-6, f'nurbscheck({k}) {names[k]}: error {a}')


SOLIDS = [
    ('sketch', 'SBox', 'XY', 0), ('rect', 'SBox', 0, 0, 2, 1), ('pad', 'Box', 'SBox', 0.5),
    ('sketch', 'SCyl', 'XZ', 0), ('circle', 'SCyl', 10, 0, 1), ('pad', 'Cyl', 'SCyl', 2),
    ('sketch', 'SCone', 'XY', 0), ('point', 'SCone', 0, 0), ('point', 'SCone', 1, 0), ('point', 'SCone', 0, 2),
    ('line', 'SCone', 0, 1), ('line', 'SCone', 1, 2), ('line', 'SCone', 2, 0), ('revolve', 'Cone', 'SCone', 2 * P, None, 'v'),
    ('sketch', 'STor', 'XY', 0), ('circle', 'STor', 3, 0, 1), ('revolve', 'Torus', 'STor', 2 * P, None, 'v'),
    ('sketch', 'SPart', 'XY', 0), ('circle', 'SPart', 3, 0, 1), ('revolve', 'Quarter', 'SPart', P / 2, None, 'v'),
    ('sketch', 'SRing', 'XY', 0), ('rect', 'SRing', -2, -1, 4, 2), ('circle', 'SRing', 0, 0, 0.5), ('pad', 'Plate', 'SRing', 0.3),
    ('sketch', 'SBall', 'XY', 0), ('arc', 'SBall', 0, 0, 1, -1.5707963267948, 1.5707963267948), ('linexy', 'SBall', 0, 1, 0, -1),
    ('revolve', 'Ball', 'SBall', 2 * P, None, 'v'),
    ('sketch', 'SPie', 'XY', 0), ('arc', 'SPie', 20, 0, 1, 0, 4.71238898038469), ('linexy', 'SPie', 20, -1, 20, 0),
    ('linexy', 'SPie', 20, 0, 21, 0), ('pad', 'Pie', 'SPie', 0.5),
    ('sketch', 'S3Q', 'XY', 0), ('circle', 'S3Q', 3, 0, 1), ('revolve', 'ThreeQ', 'S3Q', 4.5, None, 'v'),
]


def fix(ops):
    """(None placeholders: a feature's optional word)"""
    out = []
    for o in ops:
        if o[0] in ('pad', 'pocket', 'revolve') and len(o) > 4:
            o = o[:4] + (None, o[5]) if o[5] else o[:4]
        out.append(o)
    return out


def s_solids():
    print('  -- solids from sketches --')
    ok, po, _ = compare(fix(SOLIDS), 'solids', 'pads and revolves: box, cylinder, cone, torus, quarter torus, plate with a hole, sphere, a 3/4 pie, a 3/4 torus')
    want = {'Box': (1.0, 7.0), 'Cyl': (2 * P, 6 * P), 'Cone': (2 * P / 3, None), 'Torus': (6 * P * P, 12 * P * P),
            'Quarter': (6 * P * P / 4, None), 'Plate': (2.4 - P * 0.25 * 0.3, None), 'Ball': (4 * P / 3, 4 * P)}
    for n, (v, a) in want.items():
        f = po.get(n, [0] * 20)
        e = abs(f[0] - v) / v if isinstance(f[0], float) else 1
        ea = abs(f[1] - a) / a if a and isinstance(f[1], float) else 0
        check(e < 1e-9 and ea < 1e-9 and f[6] == 1 and f[7] == 1,
              f'{n}: valid, watertight, the exact volume{" and area" if a else ""} (relative errors {e:.1e}, {ea:.1e})')
    kinds = [po.get('Cyl', [0] * 20)[11], po.get('Cyl', [0] * 20)[10], po.get('Cone', [0] * 20)[12],
             po.get('Ball', [0] * 20)[13], po.get('Torus', [0] * 20)[14], po.get('Plate', [0] * 20)[11]]
    check(kinds == [2, 2, 2, 2, 4, 2], f'the surfaces: cylinders, planes, cones, spheres, tori ({kinds})')


BOOLS = [
    ('sketch', 'S1', 'XY', 0), ('rect', 'S1', 0, 0, 4, 2), ('pad', 'Box', 'S1', 1),
    ('sketch', 'Cut', 'XY', 1), ('rect', 'Cut', 1, 0.5, 2, 1), ('pocket', 'Box', 'Cut', 0.4),
    ('sketch', 'S2', 'XY', 0), ('rect', 'S2', 10, 0, 4, 2), ('pad', 'Plate', 'S2', 0.5),
    ('sketch', 'Drill', 'XY', 0.5), ('point', 'Drill', 12, 1), ('hole', 'Plate', 'Drill', 1),
    ('sketch', 'S3', 'XY', 0), ('rect', 'S3', 20, 0, 4, 2), ('pad', 'Step', 'S3', 1),
    ('sketch', 'Top', 'XY', 1), ('rect', 'Top', 21, 0.5, 1, 1), ('pad', 'Step', 'Top', 0.5),
    ('sketch', 'RodS', 'XY', 0), ('circle', 'RodS', 30, 0, 1), ('pad', 'Rod', 'RodS', 4),
    ('sketch', 'Cross', 'XZ', 0), ('point', 'Cross', 30, -2), ('hole', 'Rod', 'Cross', 0.6),
    ('sketch', 'S4', 'XY', 0), ('rect', 'S4', 40, -2, 4, 4), ('pad', 'Holes', 'S4', 0.5),
    ('sketch', 'Hs', 'XY', 0.5), ('point', 'Hs', 41, -1), ('point', 'Hs', 43, -1), ('point', 'Hs', 41, 1),
    ('point', 'Hs', 43, 1), ('hole', 'Holes', 'Hs', 0.5),
    ('sketch', 'S5', 'XY', 0), ('rect', 'S5', 50, 0, 3, 2), ('pad', 'Cup', 'S5', 2), ('shell', 'Cup', 10, 0.2),
]


CURVED = [   # sections off the surfaces' iso lines: refined pcurves, traced curves on spheres, tori, cones
    ('sketch', 'SB', 'XY', 0), ('arc', 'SB', 0, 0, 1, -1.5707963267948, 1.5707963267948), ('linexy', 'SB', 0, 1, 0, -1),
    ('revolve', 'Sph', 'SB', 6.28318530717959, None, 'v'),
    ('sketch', 'SBc', 'XY', 0.5), ('rect', 'SBc', -0.4, -2, 0.8, 4), ('pocket', 'Sph', 'SBc', 0.6),
    ('sketch', 'ST', 'XY', 0), ('circle', 'ST', 3, 0, 1), ('revolve', 'Tor', 'ST', 6.28318530717959, None, 'v'),
    ('sketch', 'STc', 'XY', 1), ('rect', 'STc', 2.5, -0.5, 1, 1), ('pocket', 'Tor', 'STc', 1.5),
    ('sketch', 'SC', 'XY', 0), ('point', 'SC', 0, 0), ('point', 'SC', 1, 0), ('point', 'SC', 0, 2),
    ('line', 'SC', 0, 1), ('line', 'SC', 1, 2), ('line', 'SC', 2, 0), ('revolve', 'Con', 'SC', 6.28318530717959, None, 'v'),
    ('sketch', 'SCh', 'XY', 1.5), ('point', 'SCh', 0.3, 0.5), ('hole', 'Con', 'SCh', 0.3),
    ('sketch', 'SD', 'XY', 0), ('arc', 'SD', 0, 0, 1, -1.5707963267948, 1.5707963267948), ('linexy', 'SD', 0, 1, 0, -1),
    ('revolve', 'Sph2', 'SD', 6.28318530717959, None, 'v'),
    ('sketch', 'SDh', 'XY', 2), ('point', 'SDh', 0.2, 0.1), ('hole', 'Sph2', 'SDh', 0.5),
]


def s_bool():
    print('  -- booleans --')
    ok, po, _ = compare(BOOLS, 'bools', 'a pocket, a hole, a boss on a face, a hole across a rod, four holes, a shell')
    want = {'Box': 8 - 2 * 0.4, 'Plate': 4 - P * 0.25 * 0.5, 'Step': 8.5, 'Holes': 8 - 4 * P * 0.0625 * 0.5,
            'Cup': 12 - 2.6 * 1.6 * 1.8}
    for n, v in want.items():
        f = po.get(n, [0] * 20)
        e = abs(f[0] - v) / v if isinstance(f[0], float) else 1
        check(e < 1e-9 and f[6] == 1 and f[7] == 1, f'{n}: valid, watertight, the volume to 1e-9 ({e:.1e})')
    f = po.get('Rod', [0] * 20)
    check(f[6] == 1 and f[7] == 1 and f[8] > 100, f'Rod: a traced cylinder-cylinder hole, valid and watertight ({f[8]} triangles)')
    ok, po, _ = compare(fix(CURVED), 'curved', 'a sphere slotted, a torus and a cone cut, a sphere drilled (refined pcurves, traced sections)')
    EXTRA_ENV['BEEMODEL_BREP_KEEP'] = '1'
    compare(fix(CURVED), 'curvedk', '... the same kept when invalid (BEEMODEL_BREP_KEEP)')
    EXTRA_ENV.clear()
    built = [n for n in ('Sph', 'Tor', 'Con', 'Sph2') if po.get(n, ['none'])[0] != 'none']
    print(f'  info  built: {built}; the rest failed ({[(n, po.get(n, ["?"])[:3]) for n in ("Sph", "Tor", "Con", "Sph2") if n not in built]})')


def rnd_case(rng, i):
    """a body padded from a rect, then 1-3 random features on it"""
    if i % 2:   # general position: three decimals
        q = lambda lo, hi: round(rng.uniform(lo, hi), 3)
    else:       # coincidences: eighths
        q = lambda lo, hi: rng.randint(int(lo * 8), int(hi * 8)) / 8.0
    ops = []
    b = 'R%d' % i
    w, h, d = q(1, 4), q(1, 4), q(0.5, 2)
    ops += [('sketch', b + 's0', 'XY', 0), ('rect', b + 's0', 0, 0, w, h), ('pad', b, b + 's0', d)]
    for k in range(1, rng.randint(2, 4)):
        s = b + 's%d' % k
        kind = rng.choice(['padrect', 'pocketrect', 'padcircle', 'pocketcircle', 'hole', 'xhole', 'padside',
                           'torus', 'cone', 'ball', 'tube'])
        if kind in ('padrect', 'pocketrect'):
            ops += [('sketch', s, 'XY', d), ('rect', s, q(-0.5, w), q(-0.5, h), q(0.25, 2), q(0.25, 2))]
            ops.append(('pad', b, s, q(0.25, 1)) if kind == 'padrect' else ('pocket', b, s, q(0.25, d + 0.5)))
        elif kind in ('padcircle', 'pocketcircle'):
            ops += [('sketch', s, 'XY', d), ('circle', s, q(0, w), q(0, h), q(0.125, 1))]
            ops.append(('pad', b, s, q(0.25, 1)) if kind == 'padcircle' else ('pocket', b, s, q(0.25, d)))
        elif kind == 'hole':
            ops += [('sketch', s, 'XY', d), ('point', s, q(0.25, w - 0.25), q(0.25, h - 0.25)), ('hole', b, s, q(0.125, 0.5))]
        elif kind == 'xhole':
            ops += [('sketch', s, 'XZ', 0), ('point', s, q(0.25, w - 0.25), -q(0.125, d - 0.125)), ('hole', b, s, q(0.125, 0.5))]
        elif kind == 'padside':
            ops += [('sketch', s, 'XZ', 0), ('rect', s, q(-0.5, w), -q(0, d), q(0.25, 2), q(0.25, 2)), ('pad', b, s, q(0.25, 1), None, 'reverse')]
        elif kind == 'torus':   # a ring about the sketch's v (the world y) through the block
            ops += [('sketch', s, 'XY', 0), ('circle', s, q(0.5, w + 0.5), q(0, d), q(0.125, 0.5)),
                    ('revolve', b, s, rng.choice([6.28318530717959, 3.14159265358979, 1.5]), None, 'v')]
        elif kind == 'cone':
            r0, z0, hz = q(0.25, w), q(0, d), q(0.25, 1.5)
            ops += [('sketch', s, 'XY', 0), ('point', s, 0, z0), ('point', s, r0, z0), ('point', s, 0, z0 + hz),
                    ('line', s, 0, 1), ('line', s, 1, 2), ('line', s, 2, 0), ('revolve', b, s, 6.28318530717959, None, 'v')]
        elif kind == 'ball':
            r, cy = q(0.25, 1), q(0, d)
            ops += [('sketch', s, 'XY', 0), ('arc', s, 0, cy, r, -1.5707963267948, 1.5707963267948),
                    ('linexy', s, 0, cy + r, 0, cy - r), ('revolve', b, s, 6.28318530717959, None, 'v')]
        else:   # a tube: a rect off the axis turned
            ops += [('sketch', s, 'XY', 0), ('rect', s, q(0.25, w), q(-0.5, d), q(0.125, 1), q(0.25, 1.5)),
                    ('revolve', b, s, rng.choice([6.28318530717959, 2.0]), None, 'v')]
    return fix(ops)


def s_fuzz():
    print(f'  -- random parts ({RUNS}, seed {SEED}) --')
    rng = random.Random(SEED)
    bad = 0
    n = 0
    t0 = time.time()
    batch = 10
    for first in range(0, RUNS, batch):
        ops = []
        for i in range(first, min(RUNS, first + batch)):
            ops += rnd_case(rng, i)
        # every other batch keeps invalid results (BEEMODEL_BREP_KEEP): their triangles checked too
        EXTRA_ENV.clear()
        if (first // batch) % 2:
            EXTRA_ENV['BEEMODEL_BREP_KEEP'] = '1'
        good, po, d = compare(ops, 'fuzz%d' % first, f'random parts {first}..{min(RUNS, first + batch) - 1}', quiet=True)
        # and again: the same rows, the same meshes to the byte
        d2, po2, _ = run_port(ops, 'fuzz%db' % first)
        EXTRA_ENV.clear()
        tris = lambda dd: {f: open(os.path.join(dd, f), 'rb').read() for f in os.listdir(dd) if f.endswith('.tri')}
        if repr(po2) != repr(po) or tris(d) != tris(d2):
            good = False
            print(f'    a second run differs: {[k for k in set(po) | set(po2) if repr(po.get(k)) != repr(po2.get(k))][:5]}')
        n += 1
        if not good:
            bad += 1
            print('    case:', ops)
    check(bad == 0, f'random parts: {RUNS} of them in {n} batches, every body sane or failed with an error, '
                    f'a second run the same to the byte ({time.time() - t0:.1f} s)')


def s_damaged():
    print('  -- degenerate and damaged input (debug driver) --')
    dbg = DEBUG_DRIVER
    rng = random.Random(SEED + 1)
    cases = [
        [('sketch', 'Z', 'XY', 0), ('rect', 'Z', 0, 0, 0, 0), ('pad', 'Z0', 'Z', 1)],
        [('sketch', 'Z', 'XY', 0), ('rect', 'Z', 0, 0, 1, 1), ('pad', 'Z0', 'Z', 0)],
        [('sketch', 'Z', 'XY', 0), ('linexy', 'Z', 0, 0, 1, 0), ('linexy', 'Z', 1, 0, 1, 1), ('pad', 'Z0', 'Z', 1)],
        [('sketch', 'Z', 'XY', 0), ('circle', 'Z', 0, 0, 0), ('pad', 'Z0', 'Z', 1)],
        [('sketch', 'Z', 'XY', 0), ('rect', 'Z', 0, 0, 1, 1), ('rect', 'Z', 0, 0, 1, 1), ('pad', 'Z0', 'Z', 1)],
        [('sketch', 'Z', 'XY', 0), ('rect', 'Z', 0, 0, 1, 1), ('pad', 'Z0', 'Z', 1), ('pocket', 'Z0', 'Z', 5)],
        [('sketch', 'Z', 'XY', 0), ('rect', 'Z', 0, 0, 1, 1), ('pad', 'Z0', 'Z', 1), ('pad', 'Z0', 'Z', 1)],
        [('sketch', 'Z', 'XY', 0), ('circle', 'Z', 0, 0, 1), ('revolve', 'Z0', 'Z', 2 * P, None, 'v')],
        [('sketch', 'Z', 'XY', 0), ('rect', 'Z', 0, 0, 1e-9, 1), ('pad', 'Z0', 'Z', 1)],
        [('sketch', 'Z', 'XY', 0), ('rect', 'Z', 0, 0, 1e9, 1e9), ('pad', 'Z0', 'Z', 1e-6)],
        [('sketch', 'Z', 'XY', 0), ('rect', 'Z', 0, 0, 1, 1), ('pad', 'Z0', 'Z', 1), ('shell', 'Z0', 0, 5)],
        [('sketch', 'Z', 'XY', 0), ('arc', 'Z', 0, 0, 1, 0, 6.2), ('pad', 'Z0', 'Z', 1)],
    ]
    for k in range(20):
        ops = [('sketch', 'Q', rng.choice(['XY', 'XZ', 'YZ']), rng.choice([0, 1, -3]))]
        for _ in range(rng.randint(1, 8)):
            c = rng.choice(['rect', 'circle', 'point', 'linexy', 'arc'])
            v = lambda: rng.choice([0, 1, -1, 0.5, 2, 1e-7, 1e6, rng.uniform(-3, 3)])
            ops.append({'rect': ('rect', 'Q', v(), v(), v(), v()), 'circle': ('circle', 'Q', v(), v(), v()),
                        'point': ('point', 'Q', v(), v()), 'linexy': ('linexy', 'Q', v(), v(), v(), v()),
                        'arc': ('arc', 'Q', v(), v(), v(), v(), v())}[c])
        for _ in range(rng.randint(1, 4)):
            f = rng.choice(['pad', 'pocket', 'hole', 'revolve', 'shell'])
            ops.append({'pad': ('pad', 'Q0', 'Q', rng.choice([1, -1, 0.5, 1e-8])),
                        'pocket': ('pocket', 'Q0', 'Q', rng.choice([1, 0, 0.3])),
                        'hole': ('hole', 'Q0', 'Q', rng.choice([0.1, 0, 1])),
                        'revolve': ('revolve', 'Q0', 'Q', rng.choice([1, 6.3, -2, 0.001])),
                        'shell': ('shell', 'Q0', rng.randint(0, 3), rng.choice([0.1, 0.5, 10]))}[f])
        cases.append(ops)
    crashes = []
    t0 = time.time()
    for i, ops in enumerate(cases):
        try:
            d, po, r = run_port(ops, 'dmg%d' % i, driver=dbg, timeout=120)
            if r.returncode != 0:
                crashes.append(f'{i}: exit {r.returncode} {r.stderr[-300:]}')
        except subprocess.TimeoutExpired:
            # a slow case is not a hang: the debug build runs some junk lists for minutes (seed 720873993,
            # case 18: debug 127 s, ReleaseSafe 23 s, the original 89 s). ReleaseSafe keeps the safety checks.
            try:
                d, po, r = run_port(ops, 'dmg%dr' % i, timeout=300)
                if r.returncode != 0:
                    crashes.append(f'{i}: exit {r.returncode} {r.stderr[-300:]}')
            except subprocess.TimeoutExpired:
                crashes.append(f'{i}: hang')
    check(not crashes, f'{len(cases)} degenerate / random-junk feature lists on the debug driver: no panic, no hang '
                       f'({time.time() - t0:.1f} s) {crashes[:3]}')
    # the first dozen: each body sane or failed with an error (case 0, a zero-size
    # rectangle padded, makes an invalid body and goes on: deliberate)
    good_n = 0
    for i, ops in enumerate(cases[:12]):
        good, po, _ = compare(ops, 'dmgs%d' % i, f'degenerate case {i}', quiet=True, driver=dbg)
        if i == 0:
            check(good and po.get('Z0', ['?'] * 7)[6] == 0, f'a zero-size rectangle padded: an invalid body, and on it goes ({po.get("Z0")})')
            continue
        good_n += good
    check(good_n == 11, f'eleven degenerate cases end cleanly (built and sane, or failed with an error): {good_n} of 11')


def s_speed():
    """the kernel's time: the driver replaying the kernel after every feature
    added (BREP_PREFIX), best of three, one CPU (printed, not checked)"""
    print('  -- speed (CPU %s) --' % CPU)
    fast = build_driver('ReleaseFast') or DRIVER
    for name, ops in (('solids', fix(SOLIDS)), ('booleans', BOOLS)):
        tp = []
        for k in range(3):
            EXTRA_ENV['BREP_PREFIX'] = '1'
            t0 = time.time()
            run_port(ops, 'speedp', driver=fast)
            tp.append(time.time() - t0)
            EXTRA_ENV.clear()
        print(f'  info  {name}: the kernel (replayed after every feature) {min(tp) * 1000:.0f} ms')


SECTIONS = ['s_nurbs', 's_solids', 's_bool', 's_fuzz', 's_damaged', 's_speed']


def main():
    global DRIVER, DEBUG_DRIVER
    print(f'  B-rep kernel (seed {SEED})')
    if not DRIVER:
        DRIVER = build_driver('ReleaseSafe')
    only = os.environ.get('BREP_ONLY')
    if not only or 's_damaged' in only:
        DEBUG_DRIVER = build_driver('Debug')
    if not DRIVER or (DEBUG_DRIVER is None and (not only or 's_damaged' in only)):
        check(False, 'the driver builds (src/breptest.zig)')
    else:
        for s in SECTIONS:
            if only and s not in only.split(','):
                continue
            globals()[s]()
    shutil.rmtree(T, True)
    print(f'\nB-rep kernel ... fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
