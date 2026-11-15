#!/usr/bin/env python3
"""Each guard of tests/review11.py shown failing: one of the review's fixes
undone (or broken) in a copy of the sources; that section must then fail.
A mutant that survives is a check that passes on nothing. The first of each
group is the control: the current sources minus that fix.

    python3 tests/review11_mutants.py WORKDIR [jobs=2] [name...]

The copies build in parallel; the sections run one at a time on BEE_CPU
(default 14). (Mutants only a byte-for-byte match with the original caught
are gone.)
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
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2

OLD_WRITE = '''    b.u32_(if (scene.render_camera) |c| scene.objects[c].uid else 0);
    var nn: u32 = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (o.kind == .light or o.kind == .camera) nn += 1;
    }
    b.u32_(nn);
    for (scene.objects[0..scene.count]) |*o| {
        if (o.kind != .light and o.kind != .camera) continue;
        b.u32_(o.uid);
        b.u32_(@bitCast(o.power / 1000.0));
        for (srgbToLinear(o.light_color)) |c| b.u32_(@bitCast(c));
        if (o.kind == .camera) b.u32_(@bitCast(o.lens)) else b.u32_(@intFromEnum(o.light_type));
        b.u32_(@bitCast(o.size));
        b.u32_(@bitCast(o.cone));
    }
}
fn unusedWrite(b: anytype) void {
'''

M = [  # name, [(file, old, new)], the sections that must fail
    # --- 1. ANIM: a deleted object's channels
    ('CONTROL anim: toFile / fromFile as before (0x80000000 | oid)', [
        ('src/anim.zig', '    if (a == 0) return 0;\n    return map.get(a) orelse scene.uidOfOid(a) orelse 0;', '    if (a == 0 or a & 0x80000000 != 0) return a;\n    return map.get(a) orelse (a | 0x80000000);'),
        ('src/anim.zig', '    return scene.foreignOid(u);', '    return u | 0x80000000;')], 's_anim'),
    ('a deleted object\'s uid not kept', [('src/scene.zig', '    if (idx >= count) return;\n    bury(&objects[idx]);', '    if (idx >= count) return;')], 's_anim'),
    ('a file\'s unknown uid as 0x80000000 | uid', [('src/anim.zig', '    return scene.foreignOid(u);', '    return u | 0x80000000;')], 's_anim'),
    ('a deleted object\'s channel written as 0', [('src/anim.zig', 'map.get(a) orelse scene.uidOfOid(a) orelse 0;', 'map.get(a) orelse 0;')], 's_anim'),
    # --- 2. PRNT: a deleted parent
    ('CONTROL parent: children re-parented to the grandparent, PRNT 0', [
        ('src/scene.zig', '            o.parent = null;\n            o.parent_gone = objects[idx].uid;', '            o.parent = objects[idx].parent;'),
        ('src/bee.zig', 'scene.objects[p].uid else o.parent_gone);', 'scene.objects[p].uid else 0);')], 's_parent'),
    ('the uid kept, but the child follows the grandparent', [('src/scene.zig', '            o.parent = null;\n            o.parent_gone = objects[idx].uid;', '            o.parent = objects[idx].parent;\n            o.parent_gone = objects[idx].uid;')], 's_parent'),
    ('PRNT\'s missing uid not read back', [('src/bee.zig', '                scene.objects[i].parent_gone = pu;\n', '')], 's_parent'),
    ('parent_clear keeps a deleted parent\'s uid', [('src/ops.zig', '        if (scene.objects[i].selected) scene.objects[i].parent_gone = 0;\n', '')], 's_parent'),
    ('a duplicate keeps a deleted parent\'s uid', [('src/ops.zig', '        o.parent = null;\n        o.parent_gone = 0;', '        o.parent = null;')], 's_parent'),
    # --- 3. LCAM: records only for what was set
    ('CONTROL lcam: a record for every light and camera (as before)', [('src/lcam.zig', 'pub fn write(b: anytype) void {\n', 'pub fn write(b: anytype) void {\n' + OLD_WRITE)], 's_lcam'),
    ('a record set from all the fields', [('src/lcam.zig', '        if (o.cone != f.cone) setF(o.uid, "angle", o.cone);', '        if (o.cone != f.cone or get(o.uid) != null) setF(o.uid, "angle", o.cone);')], 's_lcam'),
    ('records of deleted objects dropped', [('src/lcam.zig', '    b.u32_(bl.n);\n    b.bytes(std.mem.sliceAsBytes(bl.r[0..bl.n]));',
                                            '    var nn: u32 = 0;\n    for (bl.r[0..bl.n]) |*r| {\n        if (scene.findUid(r.uid) != null) nn += 1;\n    }\n    b.u32_(nn);\n    for (bl.r[0..bl.n]) |*r| {\n        if (scene.findUid(r.uid) != null) b.bytes(std.mem.asBytes(r));\n    }')], 's_lcam'),
    ('the rendering camera 0 once deleted', [('src/lcam.zig', '    b.u32_(active());\n    const bl', '    b.u32_(if (scene.render_camera) |c| scene.objects[c].uid else 0);\n    const bl')], 's_lcam'),
    ('a failed light.set makes a step', [('src/lcam.zig', '    apply(i);\n    @import("undo.zig").replaceCurrent();', '    apply(i);')], 's_lcam'),
    ('records not kept by undo', [('src/scene.zig', '    if (st.lcam != @import("lcam.zig").cur) return true;\n', ''), ('src/scene.zig', '    @import("lcam.zig").restore(st.lcam);\n', '')], 's_lcam'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)


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
    for fn, old, new in edits:
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return f'the code is not there ({fn}: {old[:50]!r})'
        open(p, 'w').write(t.replace(old, new, 1))
    ui_link(d)
    r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{W}/zc{k % JOBS}', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        return 'it does not build: ' + r.stderr[-300:]
    shutil.rmtree(f'{d}/src', ignore_errors=True)
    return None


def run(k):
    name, edits, scen = M[k]
    d = f'{W}/m{k}'
    e = dict(os.environ, RV_ONLY=scen)
    r = subprocess.run([sys.executable, '-u', f'{HERE}/review11.py', f'{d}/out/bin/beemodel', '5', '4242'],
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
            print(f'{res[k][0]:9} {M[k][0]}: {res[k][1]}', flush=True)
        for j in range(JOBS):   # (the caches are big: /tmp is shared)
            shutil.rmtree(f'{W}/zc{j}', ignore_errors=True)
finally:
    shutil.rmtree(W, ignore_errors=True)
caught = sum(1 for r in res.values() if r[0] == 'caught')
print(f'review11 mutants: {caught} of {len(M)} caught, {sum(1 for r in res.values() if r[0] == "SURVIVED")} survived')
