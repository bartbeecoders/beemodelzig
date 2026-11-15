#!/usr/bin/env python3
"""Each guard of tests/review10.py shown failing: one of the review's fixes
undone (or broken) in a copy of the sources; that section must then fail.
A mutant that survives is a check that passes on nothing.

    python3 tests/review10_mutants.py WORKDIR [jobs=2] [name...]

The copies build in parallel; the sections run one at a time on BEE_CPU
(default 14). (Gone since BeeModel stopped being a port: the mutants of the
parents, a moved feature's uids, a new scene's count, a copy's uid, selection,
parent, place and flags, and the form's pixels - only a comparison with the
original's files and window caught them.)
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
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
M = [  # name, file, old, new, the sections that must fail
    # --- persistent uids
    ('UIDS written as index + 1', 'src/bee.zig', '    for (scene.objects[0..scene.count]) |*o| b.u32_(o.uid);', '    for (0..scene.count) |i| b.u32_(@intCast(i + 1));', 's_uids'),
    ('the next id written as count + 1', 'src/bee.zig', '    b.u32_(scene.uid_next);', '    b.u32_(@intCast(scene.count + 1));', 's_uids'),
    ('uids not read back (renumbered)', 'src/bee.zig', '    for (0..scene.count) |i| scene.objects[i].uid = uid_of[file_index[i]];', '    for (0..scene.count) |i| scene.objects[i].uid = @intCast(i + 1);', 's_uids'),
    ('the file\'s next id ignored', 'src/bee.zig', '        if (nx > scene.uid_next and nx <= 1 << 30) scene.uid_next = nx;', '        _ = nx;', 's_uids'),
    ('the next id not past every id', 'src/bee.zig', '            if (u >= scene.uid_next and u < 1 << 30) scene.uid_next = u + 1;', '            _ = u;', 's_uids'),
    ('a feature\'s dangling uid handed to a new object', 'src/feature.zig', '                if (u >= scene.uid_next and u < 1 << 30) scene.uid_next = u + 1;\n', '', 's_uids'),
    ('a deleted object\'s uid written as 0', 'src/feature.zig', 'scene.objects[k].uid else b.fuid[i][j]);', 'scene.objects[k].uid else b.fuid[i][j] * 0);', 's_uids'),
    # --- object.duplicate
    ('copies named after their kind', 'src/ops.zig', '        dupName(&o, nb[0..nl]);', '        dupName(&o, o.kind.label());', 's_dup'),
    ('copies keep the ".001"', 'src/ops.zig', '        if (nl >= 4 and nb[nl - 4] == \'.\') nl -= 4;', '        if (nl >= 4 and nb[nl - 4] == \'+\') nl -= 4;', 's_dup'),
    ('copies not moved', 'src/ops.zig', '        o.loc[0] += 2.5;', '', 's_dup_window'),
    ('a grab after the copies', 'src/ops.zig', '    app.log("  duplicated: {d}", .{made});', '    app.log("  duplicated: {d}", .{made});\n    _ = app.beginTransform(.move);', 's_dup_window'),
    ('the console says it differently', 'src/ops.zig', '    app.log("  duplicated: {d}", .{made});', '    app.log("Duplicated {d}", .{made});', 's_dup'),
    ('duplicate in edit mode', 'src/ops.zig', '    if (em.active) return app.log("  not available in edit mode yet (Tab returns to object mode)", .{});\n    const first_new', '    const first_new', 's_dup'),
    # --- STEP
    ('a solid without triangles makes no object', 'src/stepops.zig', '(if (ts.nv == 0) scene.addEmptyMesh() else scene.addMesh(verts, poff, ts.pt[0 .. @as(usize, ts.nt) * 3]))',
     'scene.addMesh(verts, poff, ts.pt[0 .. @as(usize, ts.nt) * 3])', 's_step'),
    ('Esc not looked at', 'src/stepread.zig', '                if (bw(@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(sp_ne)))) break;', '                _ = bw(@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(sp_ne)));', 's_esc'),
    # --- the form
    ('the colour field after a caption', 'src/forms.zig', '                colourField(wid, fr, fd.label);',
     '                _ = cv.text(r.x + 18, y + 3, fd.label, th.text_dim);\n                @import("colorpick.zig").field(wid, .{ .x = r.x + 150, .y = y, .w = W - 168, .h = 22 }, &form_rgb, fd.label, colourSet);', 's_form'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# (build.zig.zon takes the UI library from ../BeeZigUi: beside each copy too)
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.realpath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def build(k):
    name, fn, old, new, scen = M[k]
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
    p = f'{d}/{fn}'
    t = open(p).read()
    if old not in t:
        return 'the code is not there'
    open(p, 'w').write(t.replace(old, new, 1))
    r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{W}/zc{k % JOBS}', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        return 'it does not build: ' + r.stderr[-300:]
    shutil.rmtree(f'{d}/src', ignore_errors=True)
    return None


def run(k):
    name, fn, old, new, scen = M[k]
    d = f'{W}/m{k}'
    e = dict(os.environ, RV_ONLY=scen)
    r = subprocess.run([sys.executable, '-u', f'{HERE}/review10.py', f'{d}/out/bin/beemodel', '8', '4242'],
                       env=e, capture_output=True, text=True)
    fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
    if r.returncode != 0 and not fails:
        fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
    return 'caught' if fails else 'SURVIVED', (fails[0].strip()[:160] if fails else scen)


res = {}
try:
    for lo in range(0, len(M), JOBS):
        ks = list(range(lo, min(lo + JOBS, len(M))))
        with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
            built = list(ex.map(build, ks))
        for k, b in zip(ks, built):
            res[k] = ('?', b) if b else run(k)
            shutil.rmtree(f'{W}/m{k}', ignore_errors=True)
            print(f'{res[k][0]:9} {M[k][0]}: {res[k][1]}', flush=True)
        for j in range(JOBS):   # (the caches are big: /tmp is shared)
            shutil.rmtree(f'{W}/zc{j}', ignore_errors=True)
finally:
    shutil.rmtree(W, ignore_errors=True)
caught = sum(1 for r in res.values() if r[0] == 'caught')
print(f'review10 mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[0] == "SURVIVED")} survived')
