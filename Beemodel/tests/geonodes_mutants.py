#!/usr/bin/env python3
"""Each guard of tests/geonodes.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/geonodes_mutants.py WORKDIR [jobs=4] [name...]

BEE_CPU pins the suite's runs (one at a time per CPU: give jobs=1 with one CPU).
GN_SNAPSHOT=dir: copy the sources from there (a frozen copy that builds),
not from this tree (others may be editing it). (Mutants only a triangle-for-
triangle match with the original caught are gone.)
"""
import concurrent.futures, os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


# (a copy builds outside the repo: build.zig.zon's ../BeeZigUi must be beside
# it, and zig itself on PATH: mise's shim needs the repo's mise.toml)
def ui_link(build_root):
    """BeeZigUi beside a copy's build root, as build.zig.zon wants it."""
    link = os.path.join(os.path.dirname(os.path.abspath(build_root)), 'BeeZigUi')
    if not os.path.exists(link):
        os.symlink(os.path.join(os.path.dirname(ROOT), 'BeeZigUi'), link)


import pwd as _pwd  # noqa: E402
_ZIG = os.path.join(_pwd.getpwuid(os.getuid()).pw_dir, '.local/share/mise/installs/zig/0.17.1/bin')
if os.path.isdir(_ZIG) and _ZIG not in os.environ.get('PATH', ''):
    os.environ['PATH'] = _ZIG + os.pathsep + os.environ.get('PATH', '')
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
SRC = os.environ.get('GN_SNAPSHOT', ROOT)
M = [  # name, file, old, new, the sections that must fail
    # --- the field VM
    ('vm: a zero divisor divides', 'src/fieldvm.zig', 'st(d + i, @select(f32, y != zero, x / y, zero));', 'st(d + i, x / y);', 's_nodes'),
    ('vm: sqrt of negatives', 'src/fieldvm.zig', 'st(d + i, @sqrt(@select(f32, x > zero, x, zero)));', 'st(d + i, @sqrt(x));', 's_nodes'),
    ('vm: the fused path reads one chunk', 'src/fieldvm.zig', 'for (ctx.prog) |*ins| L.op(ins, frame, CH, CH, ctx, first + off, CH);', 'for (ctx.prog) |*ins| L.op(ins, frame, CH, CH, ctx, first, CH);', 's_vm'),
    # --- compiling fields
    # --- nodes
    # --- instances
    ('draw: not COL_SOLID', 'src/inst.zig', 'else 0xbfc3ca;', 'else mat.displayColor(o);', 's_window'),
    ('draw: splats bigger', 'src/inst.zig', 'var side = fv.cvtt(rp * 1.4);', 'var side = fv.cvtt(rp * 2.0);', 's_unit'),
    ('draw: none', 'src/viewport.zig', '    if (!v.wire) @import("inst.zig").draw(cv, r, &c, near); // instances: splats and triangles (inst_draw)\n', '', 's_window'),
    ('render: no instances', 'src/hive.zig', '        k += instTris(oi, &ibud2, .{ .k = k, .mtx = mtx, .mi = mi });', '        _ = &ibud2;', 's_render'),
    # --- instances as rigid bodies, particles as objects
    ('rigid instances: not written back', 'src/rbody.zig', '    e.blk.mats[x.inst - 1] = instMatrix(x);', '    if (false) e.blk.mats[x.inst - 1] = instMatrix(x);', 's_rbody'),
    ('particles: not drawn', 'src/partdraw.zig', '            @import("inst.zig").drawParticles(cv, r, cam, near_plane, @intCast(si), rec.color);', '', 's_particles'),
    # --- operators, files, the stack
    ('stack: the trees\' changes not seen', 'src/mods.zig', '            h.update(std.mem.asBytes(&nt.ver));', '', 's_undo'),
    ('stack: geometry nodes greyed', 'src/mods.zig', 'or t == GEONODES or t == ARMATURE', 'or t == ARMATURE', 's_nodes'),
    ('panel: no tree row', 'src/editors.zig', 'if ((d.kind == mods.GEONODES or d.kind == mods.LOGIC) and q == 0) {', 'if (false) {', 's_window'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)


def one(k):
    name, fn, old, new, scen = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{SRC}/src', f'{d}/src')
        for f in ('build.zig', 'build.zig.zon'):
            if os.path.exists(f'{SRC}/{f}'):
                shutil.copy(f'{SRC}/{f}', d)
        for extra in ('zui', 'deps', 'vendor'):
            if os.path.isdir(f'{ROOT}/{extra}'):
                os.symlink(f'{ROOT}/{extra}', f'{d}/{extra}')
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        ui_link(d)
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, GN_ONLY=scen, BEEGN_TMP=d, GN_SRC=d)
        if scen == 's_vm' and os.path.exists(f'{d}/out/bin/beemodel'):
            e['GN_REL'] = f'{d}/out/bin/beemodel'
        r = subprocess.run([sys.executable, '-u', f'{HERE}/geonodes.py', f'{d}/out/bin/beemodel', '6', '4242'], env=e, capture_output=True, text=True)
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
print(f'geonodes_mutants fails {len(bad)}')
sys.exit(1 if bad else 0)
