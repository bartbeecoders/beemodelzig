#!/usr/bin/env python3
"""Each guard of tests/shatter.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/shatter_mutants.py WORKDIR [runs=6] [name...]

One at a time (every run is pinned to BEE_CPU, default 10); each build has its
own cache in WORKDIR, removed after it. While the Physics tab does not call
shatterui.props yet (physui.zig's HOOK(shatter)), the copies call it there.
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# (zig through mise works only where mise.toml is: the copies take the real one)
_ZIG = os.path.join(__import__('pwd').getpwuid(os.getuid()).pw_dir, '.local/share/mise/installs/zig/0.17.1/bin')
if os.path.isdir(_ZIG):
    os.environ['PATH'] = _ZIG + os.pathsep + os.environ.get('PATH', '')
W = os.path.abspath(sys.argv[1])
RUNS = sys.argv[2] if len(sys.argv) > 2 else '6'
S = 'src/shatter.zig'
O = 'src/shatterop.zig'
U = 'src/shatterui.zig'
M = [  # name, file, old, new, the sections that must fail
    ('the source not hidden', 'src/shatterop.zig', '                src.visible = false;\n                src.selected = false;\n            }\n            made = build();', '                src.selected = false;\n            }\n            made = build();', 's_undo'),
    ('played frames not whole or broken', 'src/rbody.zig', '                if (scene.findUid(rdU(r, p))) |i| rbimp.show(i, rdU(r, p + 4) != 0);', '                _ = scene.findUid(rdU(r, p));', 's_impact'),
    ('back at the start: children first', 'src/rbody.zig', '            if ((pass == 0) == child) continue;', '            if ((pass == 0) != child) continue;', 's_impact'),
    ('again leaves the pieces made before', 'src/shatterop.zig', '        if (scene.objects[p].oid == orig_oid) scene.remove(k);', '        if (scene.objects[p].oid == orig_oid + 99999) scene.remove(k);', 's_undo'),
    ("the form's preset without its keyword", 'src/forms.zig', '.words = &.{ "none", "brickwall", "glass", "stone", "gravel" }, .prefix = "preset" },', '.words = &.{ "none", "brickwall", "glass", "stone", "gravel" } },', 's_window'),
]
# (gone since BeeModel stopped being a port: the mutants of the cut, the patterns,
# the places, the bodies and the blow - only the original's pieces, places and
# rbinfo caught them; a script and the console share that code)
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# (build.zig.zon takes the UI library from ../BeeZigUi: beside each copy too)
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.realpath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def hook(d):
    """physui.zig calls shatterui.props in its Shatter section (rp_shatter)."""
    p = f'{d}/src/physui.zig'
    t = open(p).read()
    if 'shatterui' in t:
        return
    a = '        // HOOK(shatter): rp_shatter (pattern, preset, count, seed, glue,'
    if a in t:
        open(p, 'w').write(t.replace(a, '        y = @import("shatterui.zig").props(@intCast(salt), col, y);\n' + a, 1))


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
        if os.path.exists(f'{ROOT}/zig-pkg'):
            os.symlink(f'{ROOT}/zig-pkg', f'{d}/zig-pkg')
        hook(d)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        cpu = os.environ.get('BEE_CPU', '10')
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{W}/zc'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, SHATTER_ONLY=scen, BEE_CPU=cpu, SHATTER_TIMEOUT='60')
        r = subprocess.run([sys.executable, '-u', f'{HERE}/shatter.py', f'{d}/out/bin/beemodel', RUNS, '4242'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, 'caught' if fails else 'SURVIVED', (fails[0].strip()[:150] if fails else scen)
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(f'{W}/zc', ignore_errors=True)   # (a cache a mutant: /tmp is small)


res = []
for k in range(len(M)):
    r = one(k)
    print(f'  {r[1]:8} {r[0]}: {r[2]}', flush=True)
    res.append(r)
shutil.rmtree(f'{W}/zc', ignore_errors=True)
bad = [r for r in res if r[1] != 'caught']
print(f'shatter mutants: {len(res) - len(bad)} of {len(res)} caught; fails {len(bad)}')
sys.exit(1 if bad else 0)
