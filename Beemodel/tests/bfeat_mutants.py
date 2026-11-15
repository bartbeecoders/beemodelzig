#!/usr/bin/env python3
"""Each guard of tests/bfeat.py shown failing: bfeat.zig, bfillet.zig and the
shared profile code broken one thing at a time in a copy of the sources; the
named sections of the suite must then fail. A mutant that survives is a test
that passes on nothing.

  s_*        those sections of tests/bfeat.py (BF_ONLY), the app built from
             the mutated copy
  feature:s_*  those sections of tests/feature.py (the kernel off)
  unit:FILE  zig test src/FILE

    python3 tests/bfeat_mutants.py WORKDIR [jobs=2] [name...]   (WORKDIR under /tmp)

The mutants share one zig cache under WORKDIR (removed at the end).
"""
import concurrent.futures, os, re, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# (zig through mise works only where mise.toml is: the copies take the real one)
_ZIG = os.path.join(__import__('pwd').getpwuid(os.getuid()).pw_dir, '.local/share/mise/installs/zig/0.17.1/bin')
if os.path.isdir(_ZIG):
    os.environ['PATH'] = _ZIG + os.pathsep + os.environ.get('PATH', '')
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
M = [  # name, file, old, new, what must fail
    # --- bfeat.zig: the replay
    ('the kernel never runs', 'src/bfeat.zig', '    if (!cad.kernel()) return;\n    const t0', '    if (true) return;\n    const t0', 's_random'),
    ('the kernel runs with the switch off', 'src/bfeat.zig', '    if (!cad.kernel()) return;\n    const t0', '    const t0', 's_random'),
    ('bodies keep the mesh replay\'s mesh', 'src/bfeat.zig', '        const mi = toMesh(bf_bds[k]) orelse continue;', '        const mi: u16 = if (true) continue else 0;', 's_files'),
    ('undo: the solids not made again', 'src/bfeat.zig', '    if (made_at == undo.restores) return;', '    if (true) return;', 's_undo'),
    ('the meshes written into any object', 'src/bfeat.zig', '        if (!scene.objects[oi].kind.isMesh()) continue;\n', '', 's_files'),
    # --- bfillet.zig
    # (gone since BeeModel stopped being a port: the mutants of the replay's and the
    # fillets' geometry (overshoots, extents, patterns, radii, places, tolerances,
    # setbacks, arc centres, edge picks) that only a comparison with the original's
    # numbers caught; the script and the console share that code)
    ('chamfers rounded', 'src/bfillet.zig', '    if (!fl_cham) {\n        if (!arc', '    if (true) {\n        if (!arc', 's_fillet'),
    # --- the profiles (one copy for both): the kernel's and the feature tree's
    ('profiles: holes turned the wrong way', 'src/proftri.zig', 'if (!jbe(a, 0)) reverse(i); // hole: clockwise', 'if (!jae(a, 0)) reverse(i);', 'feature:s_ops'),
    ('profiles: ears clipped with a looser test', 'src/proftri.zig', 'lim = lim * pd_eps;', 'lim = lim * 1.0e-3;', 'feature:s_ops'),
    ('profiles: holes bridged from the wrong point', 'src/proftri.zig', 'if (!jae(a[0], bsave[0])) pslot = (ue + 1) % tr_n;', 'if (jae(a[0], bsave[0])) pslot = (ue + 1) % tr_n;', 'feature:s_ops'),
    # --- the hook, the switch
    ('the hook only with the kernel on (solids kept after off)', 'src/feature.zig', '    if (brep_hook) |h| h(); // (it forgets', '    if (cad.kernel()) if (brep_hook) |h| h(); // (it forgets', 's_undo'),
    ('the switch is not saved', 'src/cad.zig', '    b.u32_(@intFromBool(kernel()));', '    b.u32_(0);', 's_files'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
CACHE = f'{W}/zc'
# (build.zig.zon takes the UI library from ../BeeZigUi: beside each copy too)
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.realpath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, what = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        for x in ('build.zig', 'build.zig.zon'):
            if os.path.exists(f'{ROOT}/{x}'):
                shutil.copy(f'{ROOT}/{x}', d)
        for x in ('assets', 'fonts', 'data', 'zig-pkg'):
            if os.path.exists(f'{ROOT}/{x}') and not os.path.exists(f'{d}/{x}'):
                os.symlink(f'{ROOT}/{x}', f'{d}/{x}')
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        if what.startswith('unit:'):
            r = subprocess.run(['zig', 'test', f'src/{what[5:]}', '--cache-dir', CACHE], cwd=d, capture_output=True, text=True, timeout=1800)
            ok = r.returncode != 0
            return name, ('ok' if ok else 'LIVE'), (f'{what} failed' if ok else f'{what} passed')
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', CACHE], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        b = f'{d}/out/bin/beemodel'
        if what.startswith('feature:'):
            e = dict(os.environ, FT_ONLY=what[8:])
            cmd = [sys.executable, '-u', f'{HERE}/feature.py', b, '16', '4242']
        elif what.startswith('step:'):
            e = dict(os.environ, STEP_ONLY=what[5:], STEP_QUICK='1')
            cmd = [sys.executable, '-u', f'{HERE}/step.py', b, '12', '4242']
        else:
            e = dict(os.environ, BF_ONLY=what)
            cmd = [sys.executable, '-u', f'{HERE}/bfeat.py', b, '16', '4242']
        r = subprocess.run(cmd, env=e, capture_output=True, text=True, timeout=7200)
        # (a kill counts when a check failed: not the count of solids alone, which
        # a mutant can lower without changing anything else the suite checks)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln and not re.search(r'FAIL (\d+) of \1 (chains|fillet / chamfer cases) the same', ln)]
        if r.returncode != 0 and not fails and 'FAIL' not in r.stdout:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {what}: {fails[0].strip()[:90]}' if fails else f'nothing in {what} failed')
    finally:
        shutil.rmtree(d, ignore_errors=True)


bad = []
try:
    with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
        for name, st, msg in ex.map(one, range(len(M))):
            print(f'  {st:4} {name}: {msg}', flush=True)
            if st != 'ok':
                bad.append(name)
finally:
    shutil.rmtree(CACHE, ignore_errors=True)
print(f'bfeat mutants: {len(M) - len(bad)} of {len(M)} caught; survivors {len(bad)} {bad}')
sys.exit(1 if bad else 0)
