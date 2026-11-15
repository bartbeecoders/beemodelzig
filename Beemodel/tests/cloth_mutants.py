#!/usr/bin/env python3
"""Each guard of tests/cloth.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/cloth_mutants.py WORKDIR [runs=4] [name...]

(The mutants the suite once caught only by comparing with the assembly
original, a constant or an order a little off, are gone with that comparison.)

One at a time (every run is pinned to BEE_CPU, default 12); each build's cache
is removed after it (/tmp is small).
"""
import os, shutil, subprocess, sys
BUILD_ENV = dict(os.environ)  # (the builds: the user's own HOME and XDG folders, where mise keeps zig)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
RUNS = sys.argv[2] if len(sys.argv) > 2 else '4'
M = [  # name, file, old, new, the sections that must fail
    # --- landscapes as colliders (cx_hf, pt_hf)
    ('landscapes not collided', 'src/cloth.zig', '        for (0..nhf) |k| ptHf(p, k, c.thick, c.fric); // landscapes\n', '\n', 's_land'),
    ('no collisions when only landscapes collide', 'src/cloth.zig', '        if (nct | nhf != 0) {', '        if (nct != 0) {', 's_land'),
    ('the landscape placed once (not each frame)', 'src/cloth.zig', '                    .loc = .{ o.loc[0], o.loc[1], o.loc[2], 0 },', '                    .loc = if (nhf == 0 and hf[0].loc[3] == 7) hf[0].loc else .{ o.loc[0], o.loc[1], o.loc[2], 7 },', 's_land'),
    ('the landscapes not gathered again each step', 'src/cloth.zig', '    nbig = 0;\n    nhf = 0;', '    nbig = 0;', 's_land_cache'),
    # --- the cache, files
    ('the key ignores the mesh made and the pins', 'src/cloth.zig', '        h ^= @as(u64, mi) | @as(u64, me.serial) << 32;\n        h *%= K;\n        h ^= me.shape;\n        h *%= K;\n        h = sc.mix(h ^ me.pin.len, me.pin);', '        _ = me;', 's_cache'),
    ('MPIN not read', 'src/cloth.zig', '        @memcpy(me.pin, c[o + 8 ..][0..n]);', '', 's_cache'),
    ('a damaged MPIN record read past its count', 'src/cloth.zig', '        if (n != me.verts.len) continue;', '', 's_damaged'),
    # --- operators, undo, the window
    ('cloth.pin in place (undo cannot take it back)', 'src/cloth.zig', '        const mi = scene.cloneMesh(mi0) orelse continue;', '        const mi = mi0;', 's_undo'),
    ('the Unpin All button pins all', 'src/physui.zig', 'exec("cloth.pin", "none");', 'exec("cloth.pin", "all");', 's_window'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# (the build's cache: MUT_ZC, off /tmp when /tmp is short)
ZC = os.environ.get('MUT_ZC', f'{W}/zc')
# build.zig.zon takes BeeZigUi from ../BeeZigUi: next to the copies too
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, scen = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        if os.path.isdir(f'{ROOT}/zig-pkg'):  # (the fetched packages)
            os.symlink(f'{ROOT}/zig-pkg', f'{d}/zig-pkg')
        for x in ('build.zig.zon', 'mise.toml'):  # (mise.toml: the zig version mise's shim runs)
            if os.path.exists(f'{ROOT}/{x}'):
                shutil.copy(f'{ROOT}/{x}', d)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        cpu = os.environ.get('BEE_CPU', '12')
        r = subprocess.run(['taskset', '-c', cpu, 'zig', 'build', '--release=fast', '-p', f'{d}/out', '--cache-dir', ZC], cwd=d, capture_output=True, text=True, env=BUILD_ENV)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, CL_ONLY=scen, BEECL_TMP=W)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/cloth.py', f'{d}/out/bin/beemodel', RUNS, '4242'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, 'caught' if fails else 'SURVIVED', (fails[0].strip()[:150] if fails else scen)
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(ZC, ignore_errors=True)


res = {}
for k in range(len(M)):
    res[k] = one(k)
    print(f'{res[k][1]:9} {res[k][0]}: {res[k][2]}', flush=True)
caught = sum(1 for r in res.values() if r[1] == 'caught')
print(f'cloth mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[1] == "SURVIVED")} survived')
