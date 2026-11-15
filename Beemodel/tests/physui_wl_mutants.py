#!/usr/bin/env python3
"""Each guard of tests/physui_wl.py shown failing: the Physics tab's code broken,
one thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/physui_wl_mutants.py WORKDIR [jobs=1] [name...]

(Builds are release builds without the GPU helper: small, and /tmp is shared.
The cases pin to BEE_CPU, 12 by default.)
"""
import concurrent.futures, os, shutil, subprocess, sys
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
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
F = 'src/physui.zig'
M = [  # name, file, old, new, the cases that must fail
    ('the cache lines left out', F, '        cacheLine(&y, "Rigid bodies: ", 0);\n        cacheLine(&y, "Cloth: ", 1);\n', '', 'cache'),
    ('gravity on again when switched off', F, 'rp_grav = .{ 0, if (rp_gon) -9.81 else 0, 0 };', 'rp_grav = .{ 0, -9.81, 0 };', 'edit'),
    ('the limits flag as the motor\'s', F, '| @as(u32, @intFromBool(rp_jlim)) | @as(u32', '| @as(u32, @intFromBool(rp_jlim)) << 1 | @as(u32', 'edit'),
    ('no status line', F, '    status(&y, o, b, e, orig);\n', '    if (false) status(&y, o, b, e, orig);\n', 'active'),
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
        ui_link(d)
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '--release=fast', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
        shutil.rmtree(f'{d}/zc', ignore_errors=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, PU_ONLY=scen)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/physui_wl.py', f'{d}/out/bin/beemodel'], env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {scen}: {fails[0].strip()[:110]}' if fails else f'nothing in {scen} failed')
    finally:
        shutil.rmtree(d, ignore_errors=True)


bad = []
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    for name, st, msg in ex.map(one, range(len(M))):
        print(f'  {st:4} {name}: {msg}', flush=True)
        if st != 'ok':
            bad.append(name)
print('survivors', len(bad), bad)
sys.exit(1 if bad else 0)
