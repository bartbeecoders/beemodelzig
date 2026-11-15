#!/usr/bin/env python3
"""Each guard of tests/nodeed.py shown failing: the node editor's code broken, one
thing at a time, in a copy of the sources; the cases named must then fail. A
mutant that survives is a check that passes on nothing.

    python3 tests/nodeed_mutants.py WORKDIR [jobs=1] [name...]   (WORKDIR under /tmp)

BEE_CPU as tests/nodeed.py's. Each mutant's tree, build and cache are removed as it ends
(a debug build is about 300 MB, its cache as much); the scenes are kept in
WORKDIR/scenes (made by the first mutant's build).
"""
import concurrent.futures, os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
F = 'src/nodeed.zig'
M = [  # name, file, old, new, the cases that must fail (NE_ONLY)
    # (the mutants of exact bytes and pixels went with the comparisons dropped on 2026-11-14: no guard of them left)
    ('the selection does not move along', F, 'if (bit(selm, k) or k == dn) place(', 'if (k == dn) place(', 'box_select_move'),
    ('reroute: not on a double click', F, 'if (dt <= 400) {\n        const a = x - clkx;', 'if (dt <= 0) {\n        const a = x - clkx;', 'reroute'),
    ('the quick keys do nothing', F, 'armq = v;\n            arm = true;', 'armq = v;\n            arm = false;', 'quick_key'),
    ('New Tree: not run by the object', F, '    pathn = 0;\n    useTree(nt.count());', '    pathn = 0;', 'new_tree'),
    ('logic: delete keeps the first', F, '            if (k == 0) break;\n            const r = rec() orelse break;', '            if (k <= 1) break;\n            const r = rec() orelse break;', 'logic_delete'),
    ('the add menu: categories not shown', F, 'ecat_on = kind == 0 and fnl == 0;', 'ecat_on = false;', 'add_menu,add_click'),
    ('damaged: any float to an int', F, 'pub fn cvt(x: f32) i32 {\n    if (!(x >= -2147483648.0 and x < 2147483648.0)) return std.math.minInt(i32);', 'pub fn cvt(x: f32) i32 {', 'damaged'),
    ('the window: no key for the menu', 'src/app.zig', '    if (@import("nodeed.zig").menu) {\n        @import("nodeed.zig").key(raw_key);\n        return;\n    }', '', 'window'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
if not os.path.exists(f'{W}/BeeZigUi'):   # (build.zig.zon's zui: ../BeeZigUi from each copy)
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')
os.makedirs(f'{W}/scenes', exist_ok=True)


def one(k):
    name, fn, old, new, cases = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        shutil.copy(f'{ROOT}/build.zig.zon', d)   # (its zui dependency)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run(['taskset', '-c', os.environ.get('BUILD_CPUS', '0-9'), 'zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, NE_ONLY=cases, NE_SCENES=f'{W}/scenes')
        r = subprocess.run([sys.executable, '-u', f'{HERE}/nodeed.py', f'{d}/out/bin/beemodel'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {cases}: {fails[0].strip()[:90]}' if fails else f'nothing in {cases} failed')
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
