#!/usr/bin/env python3
"""Each guard of tests/bs_sim.py shown failing: the simulation, animation,
rigging, play and phase 13 builtins (src/bs_phys.zig, bs_land.zig, bs_anim.zig,
bs_play.zig, bs_net.zig, and what they needed of play.zig, anim.zig, arm.zig,
scene.zig, mech.zig) broken one thing at a time in a copy of the sources; that
part of the suite must then fail. A mutant that survives is a test that passes
on nothing.

    python3 tests/bs_sim_mutants.py WORKDIR [jobs=2] [name...]

(Release builds, about 80 MB a mutant; a debug build is 430 MB.)
"""
import concurrent.futures, os, shutil, subprocess, sys
BUILD_ENV = dict(os.environ)  # (the builds: the user's own HOME and XDG folders, where mise keeps zig)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
PH, LA, AN, PL, NE = 'src/bs_phys.zig', 'src/bs_land.zig', 'src/bs_anim.zig', 'src/bs_play.zig', 'src/bs_net.zig'
M = [  # name, file, old, new, the sections that must fail
    ('key: interpolation checked after the path', AN, 'else return bs.fail(e_key_interp, "");', 'else 9;', 'anim'),
    ('unkey: always 1', AN, 'return bs.num(if (gone) 1 else 0);', 'return bs.num(1);', 'anim'),
    ('vctext: "main" without a file', NE, 'if (@import("files.zig").path() == null) return bs.nil;', '', 'net'),
    ('vctext: the row not checked', NE, 'if (a.len >= 2) _ = try bs.argNum(a[1]);', '', 'net'),
    ('cohash: upper case', NE, 'return bs.text("cbf29ce484222325");', 'return bs.text("CBF29CE484222325");', 'net'),
    ('livelink: no type check', NE, 'fn livelink(a: []const V) Err!V {\n    _ = try bs.argNum(a[0]);', 'fn livelink(a: []const V) Err!V {\n    _ = a;', 'net'),
    # (the others went when BeeModel stopped being compared with the original: what
    # they broke changes only values only the original could tell, not a clean run,
    # an error, a file, unkey's 1 / 0, vctext's nil / "main" or the empty cohash)
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
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '--release=fast', '-Dgpu=false'], cwd=d, capture_output=True, text=True, env=BUILD_ENV)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        shutil.rmtree(f'{d}/zc', ignore_errors=True)
        e = dict(os.environ, BS_ONLY=sec, BS_JOBS='2')
        r = subprocess.run([sys.executable, '-u', f'{HERE}/bs_sim.py', f'{d}/out/bin/beemodel', '20', '4242'],
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
sys.exit(1 if bad else 0)
