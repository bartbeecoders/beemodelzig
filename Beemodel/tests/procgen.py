#!/usr/bin/env python3
"""The procedural generators geometry nodes call (procgen.zig: terrain,
erode, terrace, lsystem) through --dump-procgen, for random settings: sizes,
resolutions, heights, seeds, noise scale / detail / ridged, droplets,
strengths, steps, smooth; the four L-system presets as tubes at several
iterations, radii and steps (the curves' sweep: curve.zig). Each mesh must
come out cleanly: vertices and polygons, indices in range, coordinates
finite, a terrain no wider than its size (X and Z; Y is up), erode and terrace keeping the
terrain's grid, and the same settings giving the same mesh twice.

    python3 tests/procgen.py BIN [runs=6] [seed]

BEE_CPU (default 20) pins every run.
"""
import math, os, random, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 6
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '20')
FAILS = []
T = tempfile.mkdtemp(prefix='beeprocgen-', dir=os.environ.get('BEELAND_TMP', '/tmp'))
import atexit
atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, XDG_CACHE_HOME='', BEEMODEL_GPU='off')
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
rng = random.Random(SEED)

# ---- the user's own settings must not move (read only: the real home, by uid) ----
import pwd as _pwd


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


def port_mesh(spec):
    """BeeModel's mesh: dict(raw bytes, verts, polys, rc), or None with the exit code."""
    out = f'{T}/p.bin'
    if os.path.exists(out):
        os.remove(out)
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/u.ppm', '--dump-procgen', f'{spec};{out}'],
                           capture_output=True, text=True, timeout=600, env=ENV)
    except subprocess.TimeoutExpired:
        return None, 'timeout'
    if r.returncode != 0 or not os.path.exists(out):
        return None, f'exit {r.returncode}'
    d = open(out, 'rb').read()
    nv, npl = struct.unpack_from('<II', d)
    v = struct.unpack_from(f'<{nv * 3}f', d, 8)
    verts = [v[i * 3:i * 3 + 3] for i in range(nv)]
    o, polys = 8 + nv * 12, []
    for _ in range(npl):
        k = struct.unpack_from('<I', d, o)[0]
        polys.append(struct.unpack_from(f'<{k}I', d, o + 4))
        o += 4 + 4 * k
    return dict(raw=d, verts=verts, polys=polys, tail=len(d) - o), 'exit 0'


def sane(m, what, may_be_empty=False):
    """The mesh is whole: vertices, polygons of 3+ corners, indices in range, finite
    (no vertices at all only where nothing is drawn, as an axiom of no F)."""
    nv = len(m['verts'])
    bad_idx = sum(1 for p in m['polys'] if len(p) < 3 or any(i >= nv for i in p))
    bad_f = sum(1 for p in m['verts'] if not all(math.isfinite(x) for x in p))
    check((may_be_empty or (nv > 0 and m['polys'])) and not bad_idx and not bad_f and m['tail'] == 0,
          f'{what}: {nv} vertices, {len(m["polys"])} polygons, {bad_idx} bad polygons, {bad_f} vertices not finite')


def f2(x):
    return round(x, 2)


def s_terrain():
    print('== terrain, erode, terrace')
    cases = [((40, 64, 7, 3), (1, 1.6, 6, 0.6), (20000, 0.3, 3), (5, 0.2))]
    for _ in range(RUNS):
        cases.append(((f2(rng.uniform(2, 80)), rng.choice([8, 33, 64, 100]), f2(rng.uniform(0.5, 12)), rng.randrange(0, 40)),
                      (1, f2(rng.uniform(0.3, 5)), rng.randrange(1, 11), f2(rng.uniform(0, 1))),
                      (rng.choice([0, 500, 30000]), f2(rng.uniform(0, 1)), rng.randrange(0, 9)),
                      (rng.randrange(1, 9), f2(rng.uniform(0, 1)))))
    for tp, ti, ep, sp in cases:
        base = None
        for depth in (1, 2, 3):
            names = ['terrain'] + (['erode'] if depth > 1 else []) + (['terrace'] if depth > 2 else [])
            spec = f'terrain {" ".join(map(str, tp))} {" ".join(map(str, ti[1:]))}'
            if depth > 1:
                spec += f'|erode {" ".join(map(str, ep))}'
            if depth > 2:
                spec += f'|terrace {" ".join(map(str, sp))}'
            what = f'{" -> ".join(names)} {tp} {ti[1:]}'
            m, how = port_mesh(spec)
            check(m is not None, f'{what}: runs and writes its mesh ({how})')
            if m is None:
                continue
            sane(m, what)
            half = tp[0] / 2 * 1.0001 + 1e-4
            wide = sum(1 for x, _, z in m['verts'] if abs(x) > half or abs(z) > half)
            check(not wide, f'{what}: every vertex within the size {tp[0]} ({wide} outside)')
            if depth == 1:
                base = m
            elif base is not None:
                check(len(m['verts']) == len(base['verts']) and [tuple(p) for p in m['polys']] == [tuple(p) for p in base['polys']],
                      f'{what}: keeps the terrain\'s {len(base["verts"])} vertices and {len(base["polys"])} polygons')
            m2, _ = port_mesh(spec)
            check(m2 is not None and m2['raw'] == m['raw'], f'{what}: the same settings give the same mesh twice')


def s_lsystem():
    print('== L-systems')
    cases = [(0, 3, 0.03, 0.12), (1, 4, 0.05, 0.3), (2, 3, 0.02, 0.2), (3, 2, 0.1, 1)]
    for _ in range(RUNS // 2):
        cases.append((rng.randrange(0, 5), rng.randrange(0, 5), f2(rng.uniform(0.01, 0.2)), f2(rng.uniform(0.05, 2))))
    for p in cases:
        what = f'lsystem preset {p[0]} iterations {p[1]} radius {p[2]} step {p[3]}'
        spec = f'lsystem {" ".join(map(str, p))}'
        m, how = port_mesh(spec)
        check(m is not None, f'{what}: runs and writes its mesh ({how})')
        if m is None:
            continue
        # an axiom of no F (the plant's X, the bush's A) draws nothing before it is rewritten
        sane(m, what, may_be_empty=p[1] == 0 and p[0] in (0, 1, 4))
        m2, _ = port_mesh(spec)
        check(m2 is not None and m2['raw'] == m['raw'], f'{what}: the same settings give the same mesh twice')


s_terrain()
s_lsystem()
_moved = [k for k in set(_REAL0) | set(_real_config()) if _REAL0.get(k) != _real_config().get(k)]
check(not _moved, f'the user\'s ~/.config untouched by the run ({", ".join(_moved) or "nothing moved"})')
print(f'procgen: seed {SEED}, fails {len(FAILS)}')
for x in FAILS:
    print('  -', x)
sys.exit(1 if FAILS else 0)
