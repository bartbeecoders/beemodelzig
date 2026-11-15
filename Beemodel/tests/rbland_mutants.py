#!/usr/bin/env python3
"""Each guard of tests/rbland.py shown failing: the heightfield and water code
broken, one thing at a time, in a copy of the sources; that part of the suite
must then fail. A mutant that survives is a test that passes on nothing.
(Only mutants a standalone check can see: ones that changed the places by a
little, caught only against the original, are gone.)

    python3 tests/rbland_mutants.py WORKDIR [runs=3] [name...]

One at a time (every run is pinned to BEE_CPU, default 12); each build's cache
is removed after it (/tmp is small).
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


# (a copy builds outside the repo: build.zig.zon's ../BeeZigUi must be beside
# it, and zig itself on PATH: mise's shim needs the repo's mise.toml)
def ui_link(build_root):
    """BeeZigUi beside a copy's build root, as build.zig.zon wants it."""
    link = os.path.join(os.path.dirname(os.path.abspath(build_root)), 'BeeZigUi')
    if not os.path.exists(link):
        os.symlink(os.path.join(os.path.dirname(ROOT), 'BeeZigUi'), link)


import pwd as _pwd  # noqa: E402
_ZIG = os.path.join(_pwd.getpwuid(os.getuid()).pw_dir, '.local/share/mise/installs/zig/0.17.1/bin')
if os.path.isdir(_ZIG) and _ZIG not in os.environ.get('PATH', ''):
    os.environ['PATH'] = _ZIG + os.pathsep + os.environ.get('PATH', '')
W = os.path.abspath(sys.argv[1])
RUNS = sys.argv[2] if len(sys.argv) > 2 else '3'
L = 'src/rbland.zig'
M = [  # name, file, old, new, the sections that must fail
    ('512 slots a landscape', L, 'pub const HF_SLOTS: u32 = 131072;', 'pub const HF_SLOTS: u32 = 512;', 's_drop'),
    ('the paint\'s friction not used', 'src/rbody.zig', '    m.fric = @sqrt(fr[0] * other.fric);\n', '', 's_paint'),
    ('the paint\'s bounce not used', 'src/rbody.zig', '    m.rest = rc.maxss(fr[1], other.rest);\n', '', 's_paint'),
    ('unpainted share not the body\'s', L, '        f = f * x + sf;', '        f = sf;', 's_paint'),
    ('hidden water not ignored', L, '        if (!o.visible) continue;\n', '', 's_water'),
    ('water without its scale', L, '            .x0 = me.lo[0] * o.scl[0] + o.loc[0],', '            .x0 = me.lo[0] + o.loc[0],', 's_water'),
    ('impact on a landscape never checked', 'src/rbody.zig', '    if (rbimp.nimp != 0 and rbimp.check(fnow)) {', '    if (rbimp.nimp == 12345 and rbimp.check(fnow)) {', 's_impact'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)


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
        ui_link(d)
        r = subprocess.run(['taskset', '-c', cpu, 'zig', 'build', '--release=fast', '-p', f'{d}/out', '--cache-dir', f'{W}/zc'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, RL_ONLY=scen)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/rbland.py', f'{d}/out/bin/beemodel', RUNS, '4242'],
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
print(f'rbland mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[1] == "SURVIVED")} survived')
