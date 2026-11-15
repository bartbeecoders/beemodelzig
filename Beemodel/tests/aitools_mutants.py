#!/usr/bin/env python3
"""Each guard of tests/aitools.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that section of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/aitools_mutants.py WORKDIR [name...]   (WORKDIR under /tmp)


The builds (release: small, the quota of /tmp) run one after the other and so do
the tests: they pin BeeModel to BEE_CPU (default 14). (The guards that only
compared values with the original's are gone with it: the key's digits, single
objects, children, empty folders, folder colours, a folder there, the lightest
pixel, x1 at least x0 + 1, the hidden note.)
"""
import os, shutil, subprocess, sys
BUILD_ENV = dict(os.environ)  # (the builds: the user's own HOME and XDG folders, where mise keeps zig)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
M = [  # name, file, old, new, the sections that must fail
    ('reference_view: 2048 px at most', 'src/refset.zig', '(@max(sw, sh) + 1023) / 1024', '(@max(sw, sh) + 2047) / 2048', 'refview'),
    ('hi3d: the detail not read', 'src/hi3d.zig', '                res = r;', '                res = "512";', 'hi3d'),
    ('hi3d: a new model not at the cursor', 'src/hi3d.zig', '    } else o.loc = scene.cursor;', '    }', 'hi3d'),
    ('hi3d: the rough one stays shown', 'src/hi3d.zig', '                q.visible = false;', '', 'hi3d'),
    ('hi3d: no KILL after a stop', 'src/hi3d.zig', '        if (kill_at == 0) _ = linux.kill(pid, .KILL);', '', 'hi3d'),
    ('hi3d: a done path keeps its faces', 'src/hi3d.zig', '        if (std.mem.lastIndexOfScalar(u8, result[0..result_len], \' \')) |sp| result_len = sp;', '', 'hi3d'),
    ('hi3d: the chip without progress', 'src/hi3d.zig', '        if (p.ok) frac = p.v;', '', 'hi3d'),
]
want = sys.argv[2:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# build.zig.zon takes BeeZigUi from ../BeeZigUi: next to the copies too
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')
bad = []
for k, (name, fn, old, new, sec) in enumerate(M):
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copytree(f'{ROOT}/tests', f'{d}/tests')
        shutil.copy(f'{ROOT}/build.zig', d)
        for x in ('build.zig.zon', 'mise.toml'):  # (mise.toml: the zig version mise's shim runs)
            if os.path.exists(f'{ROOT}/{x}'):
                shutil.copy(f'{ROOT}/{x}', d)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            print(f'  ?    {name}: the code is not there', flush=True)
            bad.append(name)
            continue
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '--release=fast'], cwd=d, capture_output=True, text=True, env=BUILD_ENV)
        if r.returncode != 0:
            print(f'  ?    {name}: it does not build: {r.stderr[-300:]}', flush=True)
            bad.append(name)
            continue
        e = dict(os.environ, AIT_ONLY=sec, BEE_CPU=os.environ.get('BEE_CPU', '14'))
        r = subprocess.run([sys.executable, '-u', f'{d}/tests/aitools.py', f'{d}/out/bin/beemodel'],
                           env=e, capture_output=True, text=True, timeout=3600)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        st = 'ok' if fails else 'LIVE'
        print(f'  {st:4} {name}: ' + (f'{len(fails)} failed in {sec}: {fails[0].strip()[:100]}' if fails else f'nothing in {sec} failed'), flush=True)
        if not fails:
            bad.append(name)
    finally:
        shutil.rmtree(d, ignore_errors=True)
print('survivors', len(bad), bad)
sys.exit(1 if bad else 0)
