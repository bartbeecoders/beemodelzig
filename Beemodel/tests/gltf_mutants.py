#!/usr/bin/env python3
"""Each guard of tests/gltf.py shown failing: the glTF code broken, one thing at
a time, in a copy of the sources; the section of tests/gltf.py that guards it
must then fail. A mutant that survives is a test that passes on nothing.

    python3 tests/gltf_mutants.py [jobs=2] [name...]

The copies and their builds go on the project disk: .gltf-scratch/mut/m<k>
(sources) and zig-out-gltf-mut<k> (the build, with the shared .zig-cache),
each removed once its mutant is judged; GLTF_MUT_DIR puts all of it (the
copies, the builds, the cache) in a folder of its own instead. Builds and runs
stay on CPUs 18-31 (GLTF_MUT_CPUS). (Mutants only a byte-for-byte match with
the original caught are gone.)
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
MUTDIR = os.environ.get('GLTF_MUT_DIR')
W = os.path.join(os.path.abspath(MUTDIR), 'mut') if MUTDIR else os.path.join(ROOT, '.gltf-scratch', 'mut')
JOBS = int(sys.argv[1]) if len(sys.argv) > 1 else 2
CPUS = os.environ.get('GLTF_MUT_CPUS', '18-31')
G = 'src/gltf.zig'
M = [  # name, file, old, new, the sections that must fail
    # --- import
    ('%20 not decoded', G, "if (c == '%') {", "if (c == '~') {", 's_import'),
    ('a buffer view\'s JPEG not kept', G, 'return adopt(d, d); // (its bytes kept: saved as they are)', 'return adopt(d, null);', 's_import'),
    ('roots in their order (not the last first)', G, 'sp -= 1;\n        const en = stack[sp];', 'sp -= 1;\n        const en = stack[0];\n        std.mem.copyForwards(@TypeOf(stack[0]), stack[0..sp], stack[1 .. sp + 1]);', 's_import'),
    ('no cycle guard', G, 'if (d < en.depth and d < path.items.len and path.items[d] == ni) continue;', '_ = d;', 's_damage'),
    ('an offset past its view read', G, 'if (off32 > end32) return null; // (the original: out of bounds)', '', 's_damage'),
    ('a failed import makes an undo step', G, 'if (!undo.grouped()) undo.replaceCurrent();', '_ = undo;', 's_undo'),
    # --- export
    ('GLB: JSON padded with zeros', G, "@memset(o[20 + jlen .. 20 + jpad], ' ');", '@memset(o[20 + jlen .. 20 + jpad], 0);', 's_export'),
    ('.gltf: the buffer one byte short', G, 'w.base64(ex.bin);', 'w.base64(ex.bin[0 .. ex.bin.len - 1]);', 's_export'),
    ('a plain Texture Coordinate not plain', G, 'if (ginfo(ma, u, 1, 0) != 10) return null;', 'if (true) return null;', 's_export'),
    ('ORM: occlusion only', G, 's.s[1] = r; // (ORM: both slots)', '', 's_export'),
    ('normal map: no scale', G, 's.scale = gval(ma, pn.node, 1); // (its strength: the scale)', '', 's_export'),
    ('PNG: Adler-32 by 65519', 'src/pngenc.zig', 's1 %= 65521;', 's1 %= 65519;', 's_export'),
    # --- the window
    ('a dropped .glb not imported', 'src/drop.zig', 'if (is(e, ".glb") or is(e, ".gltf")) return .gltf;', '', 's_window'),
    ('selected objects only ignored', 'src/objmtl.zig', 'return !opts.sel_only or o.selected;', 'return true;', 's_window'),
]
want = sys.argv[2:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
CACHE = os.path.join(os.path.abspath(MUTDIR), 'zc') if MUTDIR else os.path.join(ROOT, '.zig-cache')
ENV = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.path.join(CACHE, 'global'))


def one(k):
    name, fn, old, new, scen = M[k]
    d = os.path.join(W, 'm%d' % k)
    out = os.path.join(os.path.abspath(MUTDIR), 'out%d' % k) if MUTDIR else os.path.join(ROOT, 'zig-out-gltf-mut%d' % k)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(os.path.join(ROOT, 'src'), os.path.join(d, 'src'))
        shutil.copy(os.path.join(ROOT, 'build.zig'), d)
        if os.path.exists(os.path.join(ROOT, 'build.zig.zon')):
            shutil.copy(os.path.join(ROOT, 'build.zig.zon'), d)
        p = os.path.join(d, fn)
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        t = t.replace(old, new, 1)
        if 'ownPlace(o)' in new:   # (a helper for that mutant)
            t += '\nfn ownPlace(o: *const scene.Object) [9]f32 {\n    const r = o.radians();\n    return .{ o.loc[0], o.loc[1], o.loc[2], r[0], r[1], r[2], o.scl[0], o.scl[1], o.scl[2] };\n}\n'
        open(p, 'w').write(t)
        ui_link(d)
        r = subprocess.run(['taskset', '-c', CPUS, 'zig', 'build', '-p', out, '--cache-dir', CACHE, '-Dgpu=false'],
                           cwd=d, capture_output=True, text=True, env=ENV)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, GLTF_ONLY=scen, GLTF_RANDOM='3')
        r = subprocess.run(['taskset', '-c', CPUS, sys.executable, '-u', os.path.join(HERE, 'gltf.py'), os.path.join(out, 'bin', 'beemodel'),
                            '40', '4242'], env=e, capture_output=True, text=True, timeout=5400)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = ['it stopped (%d) %s' % (r.returncode, r.stderr[-160:])]
        return name, ('ok' if fails else 'LIVE'), ('%d failed in %s: %s' % (len(fails), scen, fails[0].strip()[:90]) if fails else 'nothing in %s failed' % scen)
    finally:
        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(out, ignore_errors=True)


bad = []
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    for name, st, msg in ex.map(one, range(len(M))):
        print('  %-4s %s: %s' % (st, name, msg), flush=True)
        if st != 'ok':
            bad.append(name)
shutil.rmtree(W, ignore_errors=True)
try:
    os.rmdir(os.path.dirname(W))
except OSError:
    pass
print('survivors', len(bad), bad)
sys.exit(1 if bad else 0)
