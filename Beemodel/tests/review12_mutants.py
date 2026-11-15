#!/usr/bin/env python3
"""Each guard of tests/review12.py shown failing: one of the review's fixes
undone (or broken) in a copy of the sources; that section must then fail.
A mutant that survives is a check that passes on nothing. The first of each
group is the control: the current sources minus that fix.

    python3 tests/review12_mutants.py WORKDIR [jobs=1] [name...]

The copies build one after another (taskset BEE_CPU, default 12) and their
sections run on BEE_CPU. (Gone since BeeModel stopped being a port: the mutants
only the original's pixels and places caught - line ends, the near cut, culling
with the eye inside, the Y axis, the light's colour and icon, the rows' widths,
the units' list, a heading's gap - and SKCH's reference counts, which only the
original's counts pinned.)
"""
import concurrent.futures, os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# (zig through mise works only where mise.toml is: the copies take the real one)
_ZIG = os.path.join(__import__('pwd').getpwuid(os.getuid()).pw_dir, '.local/share/mise/installs/zig/0.17.1/bin')
if os.path.isdir(_ZIG):
    os.environ['PATH'] = _ZIG + os.pathsep + os.environ.get('PATH', '')
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
CPU = os.environ.get('BEE_CPU', '12')

SCR_NEW = '''    const s = c.screen(p);
    return .{ s[0], s[1], 1.0 / p[2] };
}'''
SCR_OLD = '''    const s = c.screen(p);
    return .{ std.math.clamp(s[0], -30000, 30000), std.math.clamp(s[1], -30000, 30000), 1.0 / p[2] };
}'''
SEG_NEW = '''    const t = clipSeg(cv.clip, a[0], a[1], b[0], b[1]) orelse return;'''
SEG_OLD = '''    const t = [2]f32{ 0, 1 };'''
RNE_NEW = '''fn rne(x: f32) i32 {
    var r = @round(x);'''
RNE_OLD = '''fn rne(x: f32) i32 {
    if (x == x) return @intFromFloat(std.math.clamp(x, -20000, 20000));
    var r = @round(x);'''
CUT_NEW = '''            poly[n] = if (ain) cutNear(a, b).p else cutNear(b, a).p;'''
CUT_OLD = '''            poly[n] = cutNear(a, b).p;'''
CULL_NEW = '''pub fn boxInFront(c: *const Cam, mtx: m.M4, lo: m.V3, hi: m.V3) bool {
'''
CULL_OLD = '''pub fn boxInFront(c: *const Cam, mtx: m.M4, lo: m.V3, hi: m.V3) bool {
    if (lo[0] <= hi[0] or !(lo[0] <= hi[0])) return true;
'''
YAXIS = '''        line3(cv, &c, .{ 0, 0, 0 }, .{ 0, 3, 0 }, th.axis_y);
'''
VPR_NEW = '''    for (poly[0..k], 0..) |p, j| sp[j] = vp.scr(c, p);'''
VPR_OLD = '''    for (poly[0..k], 0..) |p, j| {
        const s = c.screen(p);
        sp[j] = .{ std.math.clamp(s[0], -30000, 30000), std.math.clamp(s[1], -30000, 30000), 1.0 / p[2] };
    }'''
CAD_COL = '''            var sb = Rect{ .x = bd.x + 9, .y = r.y + 8, .w = r.right() - 14 - (bd.x + 9), .h = bd.h };'''

M = [  # name, [(file, old, new)], the sections that must fail
    # --- 1. the near plane
    ('CONTROL view: screen corners clamped per axis, lines clamped and truncated, cut from either end, closed meshes culled', [
        ('src/viewport.zig', SCR_NEW, SCR_OLD), ('src/viewport.zig', SEG_NEW, SEG_OLD), ('src/viewport.zig', RNE_NEW, RNE_OLD),
        ('src/viewport.zig', CUT_NEW, CUT_OLD), ('src/viewport.zig', CULL_NEW, CULL_OLD), ('src/vpraster.zig', VPR_NEW, VPR_OLD)], 's_view'),
    ('screen corners clamped per axis (triangles and lines)', [('src/viewport.zig', SCR_NEW, SCR_OLD)], 's_view'),
    # --- 3. the Light and Camera rows, the light's icon
    ('the camera field called Lens', [('src/editors.zig', '&o.lens, "Lens (mm)"', '&o.lens, "Lens"')], 's_panels'),
    ('the heading a folding section', [('src/editors.zig', '        ui.record("heading", title, .{ .x = x, .y = y, .w = w, .h = 22 }, true);\n        y += 24;', '        ui.record("section", title, .{ .x = x, .y = y, .w = w, .h = 22 }, true);\n        y += 24;')], 's_panels'),
    # --- 4. the CAD tab
    ('CONTROL cad: the port\'s column, folding sections', [
        ('src/editors.zig', CAD_COL, '            var sb = bd;'),
        ('src/cadui.zig', '    ui.record("heading", title, .{ .x = bd.x, .y = y.*, .w = bd.w, .h = 22 }, true);\n    y.* += 24;', '    ui.record("section", title, .{ .x = bd.x, .y = y.*, .w = bd.w, .h = 22 }, true);\n    y.* += 26;')], 's_cad'),
    ('no scroll bar', [('src/editors.zig', '            pageBar(ui.id(@src(), salt), r, &n.scroll, cad_h + 20);', '')], 's_cad'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# (build.zig.zon takes the UI library from ../BeeZigUi: beside each copy too)
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.realpath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def build(k):
    name, edits, scen = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    shutil.copytree(f'{ROOT}/src', f'{d}/src')
    shutil.copy(f'{ROOT}/build.zig', d)
    for extra in ('build.zig.zon',):
        if os.path.exists(f'{ROOT}/{extra}'):
            shutil.copy(f'{ROOT}/{extra}', d)
    if os.path.exists(f'{ROOT}/zig-pkg'):
        os.symlink(f'{ROOT}/zig-pkg', f'{d}/zig-pkg')
    for fn, old, new in edits:
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return f'the code is not there ({fn}: {old[:50]!r})'
        open(p, 'w').write(t.replace(old, new, 1))
    r = subprocess.run(['taskset', '-c', CPU, 'zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{W}/zc{k % JOBS}', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        return 'it does not build: ' + r.stderr[-300:]
    shutil.rmtree(f'{d}/src', ignore_errors=True)
    return None


def run(k):
    name, edits, scen = M[k]
    d = f'{W}/m{k}'
    e = dict(os.environ, RV_ONLY=scen, BEE_CPU=CPU)
    r = subprocess.run([sys.executable, '-u', f'{HERE}/review12.py', f'{d}/out/bin/beemodel', '1'],
                       env=e, capture_output=True, text=True)
    fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
    if r.returncode != 0 and not fails:
        fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
    return 'caught' if fails else 'SURVIVED', (f'{len(fails)} fail(s), first: ' + fails[0].strip()[:200] if fails else scen)


res = {}
try:
    for lo in range(0, len(M), JOBS):
        ks = list(range(lo, min(lo + JOBS, len(M))))
        with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
            built = list(ex.map(build, ks))
        for k, b in zip(ks, built):
            res[k] = ('?', b) if b else run(k)
            shutil.rmtree(f'{W}/m{k}', ignore_errors=True)
            # (each build adds hundreds of MB to its cache, and only a whole cache can go: /tmp is shared)
            shutil.rmtree(f'{W}/zc{k % JOBS}', ignore_errors=True)
            print(f'{res[k][0]:9} {M[k][0]}: {res[k][1]}', flush=True)
finally:
    shutil.rmtree(W, ignore_errors=True)
caught = sum(1 for r in res.values() if r[0] == 'caught')
print(f'review12 mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[0] == "SURVIVED")} survived')
