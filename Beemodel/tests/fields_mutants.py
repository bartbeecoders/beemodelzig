#!/usr/bin/env python3
"""Each guard of tests/fields.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/fields_mutants.py WORKDIR [runs=8] [name...]

One at a time (every test run pinned to BEE_CPU, default 14; the builds on
every core, without the GPU helper); WORKDIR is removed at the end. While the Physics tab does not
call fieldui.props yet (physui.zig's HOOK(fields)), the copies call it there.
Mutants that only a comparison with the assembly original caught (the soft
core, the laws, the curl, gusts, a box zone's height, degrees, field.set
type, the overlay's and gizmos' sizes, the panel's row spacing) are gone
with it.
"""
import os, shutil, subprocess, sys
BUILD_ENV = dict(os.environ)  # (the builds: the user's own HOME and XDG folders, where mise keeps zig)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
RUNS = sys.argv[2] if len(sys.argv) > 2 else '8'
F = 'src/fields.zig'
M = [  # name, file, old, new, the sections that must fail
    # --- the pull (the checks with numbers of their own: the panel's typed strength at 2 m, the fps, the keys)
    ('smooth falloff not squared', F, '    const s = 1.0 - q;\n    return s * s;', '    const s = 1.0 - q;\n    return s;', 's_ui'),
    ('a vortex turns the other way', F, 'const cr = [3]f32{ ax[1] * r[2] - ax[2] * r[1],', 'const cr = [3]f32{ ax[2] * r[1] - ax[1] * r[2],', 's_ui'),
    ('the fps from the block\'s stale copy', F, '    return an.frame / maxss(fr.r.fps, 1.0);', '    return an.frame / maxss(an.cur.?.h.fps + fr.r.fps * 0, 1.0);', 's_values'),
    ('anim.range makes no block', 'src/frange.zig', '    _ = @import("anim.zig").own(0) orelse return;\n', '', 's_values'),
    # --- words, the file, undo
    ('groups: the named ones left alone', F, '                r.skip = ~mask & 0xffff;', '                r.skip = mask;', 's_undo'),
    ('a duplicate without its settings', 'src/ops.zig', '    if (o.kind == .field) @import("fields.zig").copy(src.uid, scene.objects[d].uid); // (fl_copy)\n', '', 's_undo'),
    ('a short chunk read anyway', F, '    if (k * 64 + 4 > c.len) return;', '    if (k * 64 + 4 > c.len + 64) return;', 's_files'),
    ('no FLDS written', 'src/bee.zig', '    @import("fields.zig").write(&b);', '    b.u32_(0);', 's_files,s_ops'),
    ('undo steps without the records', 'src/scene.zig', '    @import("fields.zig").keep(&st.flds);\n', '', 's_undo'),
    ('the view does not follow the records', 'src/viewport.zig', '    h.update(std.mem.asBytes(&@import("fields.zig").stateWord()));\n', '', 's_undo'),
    ('the keyed strength not set', 'src/anim.zig', '        K_FIELD => return @import("fields.zig").chan(ch.a, v, true) != null,', '        K_FIELD => return false,', 's_keyed'),
    ('a played frame is an undo step', F, '            @import("undo.zig").absorbFields();\n', '', 's_keyed'),
    # --- the panel
    ('Strength edits Lift', 'src/fieldui.zig', '&rec.str, "Strength"', '&rec.lift, "Strength"', 's_ui'),
    ('the group\'s other bits set too', 'src/fieldui.zig', '    r.skip = if (g < 0) 0 else 0xffff & ~(@as(u32, 1) << @intCast(g));', '    r.skip = if (g < 0) 0 else ~(@as(u32, 1) << @intCast(g));', 's_ui'),
    ('the panel\'s type keeps the old values', 'src/fieldui.zig', '    fl.setType(r, t);\n    r.flags = f;', '    r.typ = t;\n    r.flags = f;', 's_ui'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# build.zig.zon takes BeeZigUi from ../BeeZigUi: next to the copies too
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.abspath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def hook(d):
    """physui.zig calls fieldui.props (as the original's rb_props_draw)."""
    p = f'{d}/src/physui.zig'
    t = open(p).read()
    if 'fieldui.zig").props' in t:
        return
    a = '        // HOOK(fields): a force field object (fl_active): its section'
    if a in t:
        open(p, 'w').write(t.replace(a, '        if (@import("fields.zig").active() != null) y = @import("fieldui.zig").props(i, bd, y + 8);\n' + a, 1))


def one(k):
    name, fn, old, new, scen = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        for x in ('build.zig.zon', 'mise.toml'):  # (mise.toml: the zig version mise's shim runs)
            if os.path.exists(f'{ROOT}/{x}'):
                shutil.copy(f'{ROOT}/{x}', d)
        hook(d)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        cpu = os.environ.get('BEE_CPU', '14')
        # (the build on every core, no GPU helper; the runs pinned)
        r = subprocess.run(['zig', 'build', '-Dgpu=false', '-p', f'{d}/out', '--cache-dir', f'{W}/zc'], cwd=d, capture_output=True, text=True, env=BUILD_ENV)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, FIELDS_ONLY=scen, BEE_CPU=cpu)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/fields.py', f'{d}/out/bin/beemodel', RUNS, '4242'],
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
bad = [r for r in res if r[1] != 'caught']
shutil.rmtree(W, ignore_errors=True)
print(f'fields mutants: {len(res) - len(bad)} of {len(res)} caught; fails {len(bad)}')
sys.exit(1 if bad else 0)
