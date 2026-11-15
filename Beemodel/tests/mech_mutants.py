#!/usr/bin/env python3
"""Each guard of tests/mech.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/mech_mutants.py WORKDIR [runs=8] [name...]

One at a time (every run is pinned to BEE_CPU, default 12); the builds share
one cache in WORKDIR.
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
RUNS = sys.argv[2] if len(sys.argv) > 2 else '8'
M = [  # name, file, old, new, the sections that must fail
    ('min does not turn the limits on', 'src/mech.zig', '            wrU(r, MJ_FLAGS, rdU(r, MJ_FLAGS) | 1);', '', 's_window'),
    ('gears ignore their ratio', 'src/mech.zig', '            if (s < k) v = rdF(recOf(b, s), MJ_VAL) * rdF(r, MJ_RATIO);', '            if (s < k) v = rdF(recOf(b, s), MJ_VAL);', 's_window'),
    ('the value not kept in the record', 'src/mech.zig', '        wrF(r, MJ_VAL, v);\n', '', 's_params'),
    ('a keyed parameter does not rebuild the features', 'src/mech.zig', '    _ = cad.paramSet(name[0..nm.len], text);\n    cad.rebuild();', '    _ = cad.paramSet(name[0..nm.len], text);', 's_params'),
    ('a value typed goes to the next joint', 'src/cadui.zig', '"{d} value {s}", .{ k + 1, t }', '"{d} value {s}", .{ k + 2, t }', 's_window'),
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
        cpu = os.environ.get('BEE_CPU', '12')
        r = subprocess.run(['taskset', '-c', cpu, ZIG, 'build', '-p', f'{d}/out', '--cache-dir', f'{W}/zc'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, MECH_ONLY=scen)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/mech.py', f'{d}/out/bin/beemodel', RUNS, '4242'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, 'caught' if fails else 'SURVIVED', (fails[0].strip()[:150] if fails else scen)
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(f'{W}/zc', ignore_errors=True)   # (a cache a mutant: /tmp is small)


res = {}
for k in range(len(M)):
    res[k] = one(k)
    print(f'{res[k][1]:9} {res[k][0]}: {res[k][2]}', flush=True)
caught = sum(1 for r in res.values() if r[1] == 'caught')
print(f'mech mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[1] == "SURVIVED")} survived')
