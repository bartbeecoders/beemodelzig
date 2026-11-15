#!/usr/bin/env python3
"""Each guard of tests/landscape.py shown failing: the code it guards broken,
one thing at a time, in a copy of the sources; that part of the suite must
then fail. A mutant that survives is a test that passes on nothing. (The
guards that compared numbers with the original's - the noise, erosion,
brushes, the generators - went with it, and their mutants too.)

    python3 tests/landscape_mutants.py WORKDIR [runs=2] [name...]

One at a time (every run is pinned to BEE_CPU, default 20); each build's cache
is removed after it (/tmp is small).
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
RUNS = sys.argv[2] if len(sys.argv) > 2 else '2'
L = 'src/landscape.zig'
S = 'src/lsculpt.zig'
P = 'src/procgen.zig'
M = [  # name, file, old, new, the sections that must fail
    # --- evaluation
    ('the cache never used', L, '    if (b.cl >= 0 and b.cl < @as(i64, first) and b.cl < @as(i64, b.nl)) {', '    if (b.cl >= 0 and b.cl < @as(i64, first) and b.cl < -1) {', 'time'),
    ('the display\'s step one finer', L, '        if (@as(i64, d) <= cap) return .{ d, s };', '        if (@as(i64, d) <= cap * 2) return .{ d, s };', 'presets'),
    ('the sea without its water material', L, '    if (@import("material.zig").presetIndex("water")) |w| @import("matops.zig").presetActive(w);', '', 'presets'),
    ('water not flagged', L, '    o.gflags |= OBF_WATER;', '', 'presets'),
    # --- files
    ('a block past the end accepted', L, '            return off >= LB_DATA and off +% a <= total and off +% a >= off;', '            return off >= LB_DATA and a == a and total == total;', 'files'),
    ('no LAND chunk read', 'src/bee.zig', '    if (land) |c| @import("landscape.zig").readChunk(c, mesh_map); // (landscapes)', '', 'files'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# the copy builds as the sources do: the UI library next to it (build.zig.zon:
# ../BeeZigUi), and the project's zig (mise.toml) found from the project
_zui = os.path.join(os.path.dirname(ROOT), 'BeeZigUi')
if os.path.isdir(_zui) and not os.path.exists(os.path.join(W, 'BeeZigUi')):
    os.symlink(_zui, os.path.join(W, 'BeeZigUi'))
_mz = subprocess.run(['mise', 'which', 'zig'], cwd=ROOT, capture_output=True, text=True,  # (mise's own installs: the real home, read only)
                     env=dict(os.environ, HOME=__import__('pwd').getpwuid(os.getuid()).pw_dir)) if shutil.which('mise') else None
ZIG = _mz.stdout.strip() if _mz is not None and _mz.returncode == 0 and _mz.stdout.strip() else 'zig'


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
        cpu = os.environ.get('BEE_CPU', '20')
        # (a release build: the same numbers, a tenth of the room)
        r = subprocess.run(['taskset', '-c', cpu, ZIG, 'build', '-p', f'{d}/out', '--cache-dir', f'{W}/zc', '--release=fast', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + '; '.join(l for l in r.stderr.splitlines() if 'error' in l)[:400]
        shutil.rmtree(f'{W}/zc', ignore_errors=True)
        e = dict(os.environ, HOME=temphome.HOME, LA_ONLY=scen, LA_REL=f'{d}/out/bin/beemodel')
        if scen.startswith('wl:'):
            r = subprocess.run([sys.executable, '-u', f'{HERE}/landscape_wl.py', f'{d}/out/bin/beemodel', scen[3:]],
                               env=e, capture_output=True, text=True)
        else:
            suite = 'procgen.py' if scen == 'procgen' else 'landscape.py'
            r = subprocess.run([sys.executable, '-u', f'{HERE}/{suite}', f'{d}/out/bin/beemodel', RUNS, '4242'],
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
print(f'landscape mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[1] == "SURVIVED")} survived')
print(f'... fails {len(M) - caught}')
