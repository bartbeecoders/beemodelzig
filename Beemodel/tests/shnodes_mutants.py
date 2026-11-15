#!/usr/bin/env python3
"""Each guard of tests/shnodes.py (and of shgraph.zig's folding test) shown
failing: the code it guards broken, one thing at a time, in a copy of the
sources; that part of the suite must then fail. A mutant that survives is a
test that passes on nothing.

(Since 2026-11-14 shnodes.py runs each session twice in BeeModel itself, so a
change both ways share - a node's value, a place, the tracer, the preview - is
seen by no guard there: those mutants are gone.)

    python3 tests/shnodes_mutants.py WORKDIR [jobs=2] [name...]   (WORKDIR under /tmp)

A scenario "unit:FILE" runs zig test on that file instead of the suite.
"""
import concurrent.futures, os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
M = [  # name, file, old, new, the scenarios that must fail
    # --- make_function
    ('make_function: not sorted after', 'src/graphops.zig', '    _ = sortNodes(&material.list[mi]);\n    material.version +%= 1;\n    return .{ .made = f };', '    material.version +%= 1;\n    return .{ .made = f };', 's_makefn'),
    ('make_function: no room checked', 'src/graphops.zig', 'or n >= sg.MAX_NODES or material.count', 'or material.count', 's_makefn'),
    ('make_function: a loop left in the graph', 'src/graphops.zig', '    if (!sortNodes(&material.list[mi])) {', '    if (!sortNodes(&material.list[mi]) and false) {', 's_makefn'),
    # --- files
    ('graph_check: an unknown type kept', 'src/material.zig', 'if (rd32(g, at) -% 1 >= GR_NTYPES) break :blk true;', '', 's_damage'),
    # --- folding (matcache)
    ('fold: noise counted pure', 'src/shgraph.zig', '    0, 0, 0, 0, 0, 1, 1, 1, 0, 0, // 0 .. 9: mix, ramp, math', '    0, 0, 1, 0, 0, 1, 1, 1, 0, 0, // 0 .. 9: mix, ramp, math', 'unit:src/shgraph.zig'),
    ('fold: a stale entry used', 'src/shgraph.zig', 'or @atomicLoad(u32, &e.ver, .monotonic) != material.version or', 'or false or', 'unit:src/shgraph.zig'),
    ('fold: a constant linked from a varying node', 'src/shgraph.zig', 'if (lo != 0 and (lo - 1 >= 64 or konst & (@as(u64, 1) << @intCast(lo - 1)) == 0)) ok = false;', 'if (lo != 0 and lo - 1 >= 64) ok = false;', 'unit:src/shgraph.zig'),
    ('fold: nothing folded', 'src/shgraph.zig', '    if (!fold_on) return 0;\n', '    if (true) return 0;\n', 'unit:src/shgraph.zig'),
    # --- the Material tab of an instance
    ('instance: the material\'s own rows shown', 'src/editors.zig', '        _ = graphcmds.instanceRows(salt, bd, y, ma_i.?);\n        return;', '        y += graphcmds.instanceRows(salt, bd, y, ma_i.?);', 's_window'),
    ('instance: a vector as numbers', 'src/graphcmds.zig', '        } else if (nd.type == 38) {', '        } else if (nd.type == 99) {', 's_window'),
    ('instance: the toggle overrides nothing', 'src/graphcmds.zig', 'if (on) gops.setParam(ma_i, @intCast(n), &nd.p) else gops.resetParam(ma_i, @intCast(n));', '_ = &on;', 's_window'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
if not os.path.lexists(f'{W}/BeeZigUi'):   # (build.zig.zon's zui: ../BeeZigUi from each copy)
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, scen = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        for x in ('build.zig.zon',):
            if os.path.exists(f'{ROOT}/{x}'):
                shutil.copy(f'{ROOT}/{x}', d)
        if os.path.exists(f'{ROOT}/tests/files'):
            os.makedirs(f'{d}/tests', exist_ok=True)
            os.symlink(f'{ROOT}/tests/files', f'{d}/tests/files')
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        if scen.startswith('unit:'):
            r = subprocess.run(['zig', 'test', '--cache-dir', f'{d}/zc', scen[5:]], cwd=d, capture_output=True, text=True)
            import re
            m = re.search(r'(\d+) failed', r.stderr + r.stdout)
            if r.returncode != 0 and not m:
                return name, '?', 'it does not build: ' + r.stderr[-300:]
            return name, ('ok' if m and int(m.group(1)) > 0 else 'LIVE'), f'{scen}: ' + ((m.group(0)) if m else 'all passed')
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        shutil.rmtree(f'{d}/zc', ignore_errors=True)  # (room: the tmpfs is shared)
        e = dict(os.environ, SH_ONLY=scen)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/shnodes.py', f'{d}/out/bin/beemodel', '4', '4242'], env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {scen}: {fails[0].strip()[:90]}' if fails else f'nothing in {scen} failed')
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
