#!/usr/bin/env python3
"""Each guard of tests/bs_mat.py shown failing: the material and node builtins
(src/bs_mat.zig, src/bs_nodes.zig, the file) broken one thing at a time in a copy of the
sources; that part of the suite must then fail. A mutant that survives is a
test that passes on nothing.

    python3 tests/bs_mat_mutants.py WORKDIR [jobs=1] [name...]

(Release builds: about 80 MB and 95 s a mutant; a debug build is 430 MB.)
"""
import concurrent.futures, os, shutil, subprocess, sys
BUILD_ENV = dict(os.environ)  # (the builds: the user's own HOME and XDG folders, where mise keeps zig)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
# (BeeModel stands alone now: every mutant here was caught only by the
# comparison with the original - values printed or saved a little off - and
# is gone. The last one, "the file: instances not synced", lived through
# bs_mat.py's open -> save checks too (2026-11-14). A mutant that breaks what
# bs_mat.py still checks on its own (clean runs, files that read back and
# survive open -> save, undo) belongs here.)
M = [  # name, file, old, new, the sections that must fail
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# build.zig.zon takes BeeZigUi from ../BeeZigUi: next to the copies too
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, sec = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        for x in ('build.zig.zon', 'mise.toml'):  # (mise.toml: the zig version mise's shim runs)
            if os.path.exists(f'{ROOT}/{x}'):
                shutil.copy(f'{ROOT}/{x}', d)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false', '--release=fast'], cwd=d, capture_output=True, text=True, env=BUILD_ENV)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, BS_ONLY=sec, BS_TMP=W)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/bs_mat.py', f'{d}/out/bin/beemodel', '20', '4242'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {sec}: {fails[0].strip()[:90]}' if fails else f'nothing in {sec} failed')
    finally:
        shutil.rmtree(d, ignore_errors=True)


bad = []
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    for name, st, msg in ex.map(one, range(len(M))):
        print(f'  {st:4} {name}: {msg}', flush=True)
        if st != 'ok':
            bad.append(name)
print('survivors', len(bad), bad)
print(f'... fails {len(bad)}')
sys.exit(1 if bad else 0)
