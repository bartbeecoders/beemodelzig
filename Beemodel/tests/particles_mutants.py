#!/usr/bin/env python3
"""Each guard of tests/particles.py shown failing: the code it guards broken,
one thing at a time, in a copy of the sources; that part of the suite must
then fail. A mutant that survives is a test that passes on nothing. (The
guards that compared numbers and pixels with the original's went with it, and
their mutants too.)

    python3 tests/particles_mutants.py WORKDIR [runs=2] [name...]

One at a time (every run is pinned to BEE_CPU, default 14); each build's cache
is removed after it (/tmp is small).
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
RUNS = sys.argv[2] if len(sys.argv) > 2 else '2'
P = 'src/particles.zig'
L = 'src/liquid.zig'
M = [  # name, file, old, new, the sections that must fail
    ('a record\'s size 388 in the file', P, '    out.u32_(PS_SZ);', '    out.u32_(PS_SZ + 4);', 's_files'),
    ('undo keeps no systems', 'src/scene.zig', '    @import("particles.zig").restore(st.psys);\n', '', 's_files'),
    ('Collisions open at first', 'src/partui.zig', 'var sec_open = [6]bool{ true, true, true, false, false, false };', 'var sec_open = [6]bool{ true, true, true, true, false, false };', 'wl:folded'),
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
        cpu = os.environ.get('BEE_CPU', '14')
        # (a release build: the same numbers, a tenth of the room)
        r = subprocess.run(['taskset', '-c', cpu, ZIG, 'build', '-p', f'{d}/out', '--cache-dir', f'{W}/zc', '--release=fast'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        shutil.rmtree(f'{W}/zc', ignore_errors=True)
        if scen.startswith('wl:'):
            e = dict(os.environ, PW_ONLY=scen[3:])
            r = subprocess.run([sys.executable, '-u', f'{HERE}/particles_wl.py', f'{d}/out/bin/beemodel', '1'],
                               env=e, capture_output=True, text=True)
        else:
            e = dict(os.environ, PT_ONLY=scen)
            r = subprocess.run([sys.executable, '-u', f'{HERE}/particles.py', f'{d}/out/bin/beemodel', RUNS, '4242'],
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
print(f'particles mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[1] == "SURVIVED")} survived')
print(f'... fails {len(M) - caught}')
