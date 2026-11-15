#!/usr/bin/env python3
"""Each guard of tests/bs_cad.py, bs_sketch.py, bs_sdf.py and bs_model.py
shown failing: the builtins broken one thing at a time in a copy of the
sources; the suite that covers them must then fail. A mutant that survives
is a test that passes on nothing. (Since the suites stopped comparing with
the assembly original, only breakage they can see on their own is here: a
crash or safety panic, a hang, undo, the sketch's solved values.)

    python3 tests/bs_cad_mutants.py WORKDIR [jobs=4] [name...]
"""
import concurrent.futures, os, shutil, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
BUILD_ENV = dict(os.environ)  # (the builds: the user's own HOME and XDG folders, where mise keeps zig)
import temphome  # noqa: F401

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
M = [  # name, file, old, new, the suite that must fail
    # --- CAD
    ('fb_slot: 32 characters allowed', 'src/bs_cad.zig', 'if (s.len >= 32) {', 'if (s.len > 32) {', 'bs_cad'),
    ('centroid: axis 3 allowed', 'src/bs_cad.zig', 'if (ax < 0 or ax > 2) return bs.fail(e_axis, "");', 'if (ax < 0 or ax > 3) return bs.fail(e_axis, "");', 'bs_cad'),
    ('fangle: one face past the end', 'src/bs_cad.zig', 'if (fa >= np or fb >= np)', 'if (fa > np or fb > np)', 'bs_cad'),
    # --- sketches
    ('con: four references', 'src/bs_sketch.zig', 'if (nref < 1 or nref > 3)', 'if (nref < 1 or nref > 4)', 'bs_sketch'),
    ('line: points not checked', 'src/bs_sketch.zig', 'if (p >= e.b.npt or q >= e.b.npt) return bs.fail(e_sk_ref, "");', '', 'bs_sketch'),
    ('skinfo: another word is points', 'src/bs_sketch.zig', 'b.nent else b.ncon;', 'b.nent else b.npt;', 'bs_sketch'),
    ('sk_done: not solved', 'src/bs_sketch.zig', '_ = skobj.end(e.i);', '_ = &e;', 'bs_sketch'),
    ('sk_edit: no copy (undo sees the change)', 'src/bs_sketch.zig', 'const b = skobj.begin(i) orelse return bs.fail(e_sk_full, "");', 'const b = scene.objects[i].sk.?;', 'bs_sketch'),
    ('a script\'s boolean waits for the main loop', 'src/jobui.zig', ' or @import("bscript.zig").isRunning()) {', ') {', 'bs_cad:win'),
    # --- shapes
    ('smesh: negative cells signed', 'src/bs_sdf.zig', 'if (@as(u32, @bitCast(cells)) > 512) cells = 512;', 'if (cells > 512) cells = 512;', 'bs_sdf'),
    # --- modelling
    ('modset: not clamped', 'src/bs_model.zig', 'x = if (x < p.hi) x else p.hi; // minss', '', 'bs_model'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# build.zig.zon takes BeeZigUi from ../BeeZigUi: next to the copies too
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, suite = M[k]
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
        if t.count(old) != 1:
            return name, '?', f'the code is there {t.count(old)} times'
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'], cwd=d, capture_output=True, text=True, env=BUILD_ENV)
        shutil.rmtree(f'{d}/zc', ignore_errors=True)   # (a debug binary is large: one copy at a time)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        win = suite.endswith(':win')
        suite = suite.split(':')[0]
        e = dict(os.environ, BS_NOWIN='' if win else '1', BS_WINONLY='1' if win else '')
        r = subprocess.run([sys.executable, '-u', f'{HERE}/{suite}.py', f'{d}/out/bin/beemodel', '6', '4242'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {suite}: {fails[0].strip()[:100]}' if fails else f'nothing in {suite} failed')
    finally:
        shutil.rmtree(d, ignore_errors=True)


bad = []
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    for name, st, msg in ex.map(one, range(len(M))):
        print(f'  {st:4} {name}: {msg}', flush=True)
        if st != 'ok':
            bad.append(name)
shutil.rmtree(f'{W}/zc', ignore_errors=True)
print(f'mutants {len(M)}, caught {len(M) - len(bad)}, survivors {len(bad)} {bad}')
sys.exit(1 if bad else 0)
