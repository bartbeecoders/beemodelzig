#!/usr/bin/env python3
"""Each guard of tests/rbody.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

(Since 2026-11-14 rbody.py plays each scene twice in BeeModel itself, so a
changed constant of the simulation moves both ways alike: those mutants, and
the ones only the original's words caught, are gone.)

    python3 tests/rbody_mutants.py WORKDIR [runs=4] [name...]

One at a time (every run is pinned to BEE_CPU, default 12); each build's cache
is removed after it (/tmp is small).
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
RUNS = sys.argv[2] if len(sys.argv) > 2 else '4'
M = [  # name, file, old, new, the sections that must fail
    # --- the cache
    ('the key ignores where the bodies start', 'src/rbody.zig', '            const p = placeBytes(i);\n            h = sc.mix(h, &p);', '            const p = placeBytes(i);\n            _ = p;', 's_cache'),
    ('a whole frame not played from the cache', 'src/rbody.zig', '    } else if (!rc.islive and f == fx) play = true;', '    } else if (!rc.islive and f == fx) play = false;', 's_cache'),
    ('cached frames without their turn', 'src/rbody.zig', '        for (0..6) |k| wrF(r, p + 4 + k * 4, q[k]);', '        for (0..3) |k| wrF(r, p + 4 + k * 4, q[k]);', 's_cache'),
    ('SIMC without its key', 'src/simcache.zig', '        out.u32_(@truncate(x.key));', '        out.u32_(0);', 's_cache'),
    # --- operators, undo
    ('a removed body keeps its joints to B', 'src/rbody.zig', '            if (rdU(r, rc.JT_A) == oid or rdU(r, rc.JT_B) == oid) {', '            if (rdU(r, rc.JT_A) == oid) {', 's_undo'),
    ('a simulated place is an edit', 'src/rbody.zig', '    if (scl) |s| o.scl = s;\n    undo.absorb(i);', '    if (scl) |s| o.scl = s;', 's_undo'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
if not os.path.lexists(f'{W}/BeeZigUi'):   # (build.zig.zon's zui: ../BeeZigUi from each copy)
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, scen = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', d)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        cpu = os.environ.get('BEE_CPU', '12')
        r = subprocess.run(['taskset', '-c', cpu, 'zig', 'build', '--release=fast', '-p', f'{d}/out', '--cache-dir', f'{W}/zc'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, RB_ONLY=scen)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/rbody.py', f'{d}/out/bin/beemodel', RUNS, '4242'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, 'caught' if fails else 'SURVIVED', (fails[0].strip()[:150] if fails else scen)
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(f'{W}/zc', ignore_errors=True)


res = {}
for k in range(len(M)):
    res[k] = one(k)
    print(f'{res[k][1]:9} {res[k][0]}: {res[k][2]}', flush=True)
caught = sum(1 for r in res.values() if r[1] == 'caught')
print(f'rbody mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[1] == "SURVIVED")} survived')
