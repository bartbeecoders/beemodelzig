#!/usr/bin/env python3
"""Each guard of tests/curves.py and tests/curves_wl.py shown failing: the code
it guards broken, one thing at a time, in a copy of the sources; that part of a
suite must then fail. A mutant that survives is a test that passes on nothing.

    python3 tests/curves_mutants.py WORKDIR [jobs=1] [name...]   (WORKDIR under /tmp)

BEE_CPU (default 10) pins the runs.
"""
import concurrent.futures, os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
C = 'src/curve.zig'
U = 'src/curveui.zig'
M = [  # name, file, old, new, suite (curves / wl), the scenarios that must fail
    # (the mutants of exact values, the evaluation, frames, sweep, chains and most
    # operators went with the comparisons dropped on 2026-11-14: no guard of them left)
    ('resolution not clamped', C, 'return @intCast(std.math.clamp(r, 1, 64));', 'return @intCast(std.math.clamp(r, 1, 640));', 'curves', 's_files'),
    # --- operators
    ('radius: negative kept', C, '_ = forSel(fsRadius, maxss(v, 0));', '_ = forSel(fsRadius, v);', 'curves', 's_ops,s_fixed'),
    ('set: bevel below 0 taken', C, 'if (v < 0 or std.math.isNan(v)) return app.log(s_cv_bad, .{});', 'if (std.math.isNan(v)) return app.log(s_cv_bad, .{});', 'curves', 's_ops'),
    # --- files and undo
    ('CURV: the capacity not kept from a load', C, '    c.h.refs = 1;\n    c.h.cap = cap;', '    c.h.refs = 1;\n    _ = cap;', 'curves', 's_files'),
    ('CURV: splines need not tile', C, '            if (sp.first != at) break :ok;', '', 'curves', 's_files'),
    ('CURV: in slot order', C, '        if (ix != 0xffffffff and ix < by_ix.len) by_ix[ix] = @intCast(mi);', '        if (ix != 0xffffffff and ix < by_ix.len) by_ix[mi] = @intCast(mi);', 'curves', 's_order'),
    ('cloth: its copy keeps the curve', 'src/cloth.zig', '    me.curve = null; // (and its curve: freeing the copy would unref it twice)\n', '', 'curves', 's_order', 'debug'),
    ('CURV: not read', 'src/bee.zig', '    if (curv) |c| @import("curve.zig").readChunk(c, mesh_map); // (curves)\n', '', 'curves', 's_files'),
    ('an empty curve\'s mesh not read', 'src/bee.zig', '    if (nv == 0 and np == 0) return scene.addEmptyMesh();\n', '', 'curves', 's_files'),
    ('edit: in place under an undo step', C, '    if (meshAlone(i, mi) and c.h.refs == 1', '    _ = meshAlone(i, mi);\n    if (c.h.refs == 1', 'curves', 's_undo'),
    ('edit: the copy\'s room without 16', C, '    const n = cvCopy(c, room +% 16) orelse return null;', '    const n = cvCopy(c, room) orelse return null;', 'wl', ''),
    # --- the window
    ('rotate: about another axis', 'src/xform.zig', 'const ai: u32 = if (axis == .free) 2 else @intFromEnum(axis);', 'const ai: u32 = if (axis == .free) 2 else @intFromEnum(axis) % 3 + 1;', 'wl', ''),
    ('a lone handle\'s partner not turned', U, '        cv.cpAlign(&c.pts[e.pt], e.part);', '', 'wl', ''),
    ('click: a handle takes its point', U, 'bits = if (part == 0) 7 else @as(u8, 1) << @intCast(part);', 'bits = 7;', 'wl', ''),
    ('overlay: handles in one colour', U, 'const hc = ht_col[p.ht & 3];', 'const hc = ht_col[0];', 'wl', ''),
    ('overlay: the view keeps the old points', 'src/viewport.zig', '    h.update(std.mem.asBytes(&@import("curve.zig").stateWord())); // (curve edit mode: its points)\n', '', 'wl', ''),
    ('Tab: no curve edit mode', 'src/ops.zig', '    if (@import("curveui.zig").tab()) return; // (curve edit mode)\n', '', 'wl', ''),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
if not os.path.exists(f'{W}/BeeZigUi'):   # (build.zig.zon's zui: ../BeeZigUi from each copy)
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')
CPU = os.environ.get('BEE_CPU', '10')


def one(k):
    name, fn, old, new, suite, scen = M[k][:6]
    debug = len(M[k]) > 6   # (a use after free the release build does not show: the debug one, 300 MB, gone after)
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
        # (a release build: a debug one is 300 MB, too much for /tmp twice over)
        r = subprocess.run(['taskset', '-c', CPU, 'zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'] + ([] if debug else ['--release=fast']), cwd=d, capture_output=True, text=True)
        shutil.rmtree(f'{d}/zc', ignore_errors=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, CV_ONLY=scen, CV_SRC=f'{d}/src', BEE_CPU=CPU)
        if suite == 'curves':
            cmd = [sys.executable, '-u', f'{HERE}/curves.py', f'{d}/out/bin/beemodel', '6', '4242']
        else:
            cmd = [sys.executable, '-u', f'{HERE}/curves_wl.py', f'{d}/out/bin/beemodel']
        r = subprocess.run(cmd, env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {scen or suite}: {fails[0].strip()[:90]}' if fails else f'nothing in {scen or suite} failed')
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
