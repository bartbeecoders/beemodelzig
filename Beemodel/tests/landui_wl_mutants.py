#!/usr/bin/env python3
"""Each guard of tests/landui_wl.py shown failing: the Landscape tab's code
broken, one thing at a time, in a copy of the sources; that part of the suite
must then fail. A mutant that survives is a test that passes on nothing.
(The guards that compared pixels and widget places with the original's went
with it: their mutants too.)

    python3 tests/landui_wl_mutants.py WORKDIR [jobs=1] [name...]

(Builds are release builds without the GPU helper. The window cases pin to
BEE_CPU, 12 by default: run them one at a time.)
"""
import concurrent.futures, os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
F = 'src/landui.zig'
M = [  # name, file, old, new, the cases that must fail
    ('Size and Samples open at first', F, 'var sec_open = [4]bool{ false, true, true, false };', 'var sec_open = [4]bool{ true, true, true, false };', 'sizes'),
    ('samples shown a step up', F, 'while (k + 1 < res_n.len and n >= res_n[k + 1]) k += 1;', 'while (k + 1 < res_n.len and n >= res_n[k]) k += 1;', 'sizes'),
    ('Remove takes the paint layer after', F, 'w.print("remove {d}", .{lp_sel}) catch {};', 'w.print("remove {d}", .{lp_sel + 1}) catch {};', 'paint'),
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
        r = subprocess.run([ZIG, 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '--release=fast', '-Dgpu=false'], cwd=d, capture_output=True, text=True, env=dict(os.environ, HOME=temphome.HOME))
        shutil.rmtree(f'{d}/zc', ignore_errors=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, LU_ONLY=scen, HOME=temphome.HOME)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/landui_wl.py', f'{d}/out/bin/beemodel'], env=e, capture_output=True, text=True)
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
