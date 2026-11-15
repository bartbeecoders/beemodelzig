#!/usr/bin/env python3
"""Each guard of tests/feature.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/feature_mutants.py WORKDIR [jobs=4] [name...]

The window mutants (s_ui, s_look, s_template, s_window, s_errors, s_undo) run
one at a time at the end, on BEE_CPU. (The guards that compared meshes with the
original's went with it, and their mutants too.)
"""
import concurrent.futures, os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
WINDOW = {'s_ui', 's_look', 's_template', 's_window', 's_errors', 's_undo'}
M = [  # name, file, old, new, the sections that must fail
    ('statuses not kept in the document', 'src/feature.zig', '        set(r, FT_STAT, st); // (in the document as it is: undo has it)', '', 's_fail'),
    ('suppressed features built', 'src/feature.zig', '        if (get(r, FT_FLAGS) & FF_OFF == 0) {', '        if (true) {', 's_fail'),
    ('patterns of fillets allowed', 'src/feature.zig', '    if (pt < T_PAD or pt > T_SHELL) return S_REF;', '    if (pt < T_PAD or pt > T_CHAMFER) return S_REF;', 's_fail'),
    ('a sketch edit does not rebuild', 'src/skobj.zig', '    if (rebuild_depth == 0 and @import("feature.zig").uses(scene.objects[i].oid)) @import("feature.zig").rebuild();', '', 's_window,s_files'),
    ('a parameter change does not rebuild', 'src/skobj.zig', '    @import("feature.zig").rebuild(); // then the solids made from them', '', 's_fail'),
    ('files: uids not read back', 'src/bee.zig', '        @import("feature.zig").afterRead(look); // (the records\' uids: our objects)', '', 's_files'),
    ('the template without its fillet', 'src/welcome.zig', '    _ = feature.fillet("Part", "3mm", "vertical");', '', 's_template'),
    ('the value field toggles On', 'src/cadui.zig', '            _ = feature.feature(@intCast(k), 0, tc[0..n], 0);', '            _ = feature.feature(@intCast(k), 3, null, 1);', 's_ui'),
    ('up and down swapped', 'src/cadui.zig', '"cad.feature.up", "Move the feature up: it runs earlier when the part rebuilds")) moved = "up";', '"cad.feature.up", "Move the feature up: it runs earlier when the part rebuilds")) moved = "down";', 's_ui'),
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
        shutil.copy(f'{ROOT}/build.zig.zon', d)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run([ZIG, 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, FT_ONLY=scen)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/feature.py', f'{d}/out/bin/beemodel', '40', '4242'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, 'caught' if fails else 'SURVIVED', (fails[0].strip()[:150] if fails else scen)
    finally:
        shutil.rmtree(d, ignore_errors=True)


quick = [k for k in range(len(M)) if not (set(M[k][4].split(',')) & WINDOW)]
slow = [k for k in range(len(M)) if k not in quick]
res = {}
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    for k, r in zip(quick, ex.map(one, quick)):
        res[k] = r
        print(f'{r[1]:9} {r[0]}: {r[2]}', flush=True)
for k in slow:
    res[k] = one(k)
    print(f'{res[k][1]:9} {res[k][0]}: {res[k][2]}', flush=True)
caught = sum(1 for r in res.values() if r[1] == 'caught')
print(f'feature mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[1] == "SURVIVED")} survived')
