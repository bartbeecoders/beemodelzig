#!/usr/bin/env python3
"""Each guard of tests/livelink.py shown failing: link.zig (and its hooks)
broken one thing at a time in a copy of the sources; the section of the suite
named must then fail. A mutant that survives is a check that passes on nothing.

    python3 tests/livelink_mutants.py WORKDIR [jobs=2] [name...]   (WORKDIR under /tmp)

Each mutant is a copy of the sources in WORKDIR/m<N> (removed when done; one
zig cache under WORKDIR); builds run `jobs` at a time, the suite's windows one
at a time (BEE_CPU). (Gone since BeeModel stopped being a port: the table's
hash, a console word, livelink(4) while connecting and the chip's width - only
a comparison with the original's bytes, words and pixels caught them.)
"""
import concurrent.futures, os, shutil, subprocess, sys, threading
import temphome  # noqa: F401 (a HOME of its own)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# (zig through mise works only where mise.toml is: the copies take the real one)
_ZIG = os.path.join(__import__('pwd').getpwuid(os.getuid()).pw_dir, '.local/share/mise/installs/zig/0.17.1/bin')
if os.path.isdir(_ZIG):
    os.environ['PATH'] = _ZIG + os.pathsep + os.environ.get('PATH', '')
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
CACHE = f'{W}/zc'
L = 'src/link.zig'
M = [  # name, file, old, new, the section that must fail
    ('no TICK', L, 'ticked = true;\n        sendTick();', 'ticked = true;', 'wire'),
    ('a TICK only once', L, '        ticked = false;\n        if (anySynced()) diff();', '        if (anySynced()) diff();', 'wire'),
    ('no MESH_DELTA: the whole mesh', L, 'if (sameTopo(e, mm)) {', 'if (false) {', 'wire'),
    ('a mesh with UVs as a delta', L, 'if (@intFromBool(hasUv(me)) != e.uv or e.uv != 0) return false;', 'if (@intFromBool(hasUv(me)) != e.uv) return false;', 'wire'),
    ('hidden: the wrong bit', L, 'return if (o.visible) 0 else OBF_HIDDEN;', 'return if (o.visible) 0 else 0x100;', 'mirror'),
    ('a material compared by its name', L, 'if (std.mem.eql(u8, rec, &mats[i])) continue;', 'if (std.mem.eql(u8, rec[0..32], mats[i][0..32])) continue;', 'wire'),
    ('no meshes in the snapshot', L, 'if (e.nv != 0) {\n                mkMesh(e);', 'if (false) {\n                mkMesh(e);', 'wire'),
    ('the snapshot from a stale table', L, 'ticked = true; // (no TICK: nobody to tell)\n            diff();', 'ticked = true; // (no TICK: nobody to tell)', 'wire'),
    ('a removed material still in the snapshot', L, 'nmats = @min(nmats, @as(u32, @intCast(@min(material.count, MATS_MAX))));', '', 'wire'),
    ('the property keys swapped', L, 'mkProp(e, 3, &val32(fl));', 'mkProp(e, 4, &val32(fl));', 'wire'),
    ('transforms never held back', L, 'if (xf and c.pending() >= LAG) {', 'if (xf and c.pending() >= LAG << 12) {', 'back'),
    ('held-back transforms never sent', L, 'mkXf(&tab[k]);\n            sendOp(c, false, 0);', '_ = &tab[k];', 'back'),
    ('nine peers', L, 'pub const MAXC = 8;', 'pub const MAXC = 9;', 'limits'),
    ('any HELLO version', L, "return std.mem.readInt(u16, b[9..11], .little) == 1;", 'return true;', 'limits'),
    # (an address parser that lets more through is caught by the unit tests:
    # the suite never connects to what it might make of it, only to loopback)
    ('connect: a bad address parsed', L, 'if (digits == 0 or v > 255) return null;', 'if (digits == 0) return null;', 'unit'),
    ('serve: a bad port taken', L, 'const f = @import("mech.zig").parseFloat(w) orelse return .bad;', 'const f = @import("mech.zig").parseFloat(w) orelse 7461;', 'unit'),
    ('mirror: transforms not applied', L, '    for (0..9) |k| xf[k] = rdf(p, 4 + k * 4);\n    setPlace(i, xf);', '    for (0..9) |k| xf[k] = rdf(p, 4 + k * 4);\n    _ = i;', 'mirror'),
    ('mirror: deletes not applied', L, 'scene.remove(i);', '_ = i;', 'mirror'),
    ('mirror: deltas not applied', L, '@memcpy(std.mem.sliceAsBytes(me.verts[@intCast(first)..@intCast(first + count)]), p[at .. at + bytes]);', '', 'mirror'),
    ('mirror: remote changes are undo steps', L, '@import("undo.zig").replaceCurrent();', '', 'mirror'),
    ('mirror: a snapshot keeps the scene', L, '    scene.reset();\n    scene.count = 0;', '    scene.count = 0;', 'mirror'),
    ('mirror: colours not applied', L, '4 => o.color = v,', '4 => {},', 'mirror'),
    ('fuzz: meshes not checked', L, 'if (need > p.len) return false;', 'if (need > p.len + (1 << 60)) return false;', 'fuzz'),
    ('fuzz: a zero length read past', L, 'if (msg.len < 5) return;', 'if (msg.len < 4) return;', 'fuzz'),
    ('fuzz: delta ranges not checked', L, 'if (first + count > me.verts.len) break;', '', 'fuzz'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
RUN = threading.Lock()
os.makedirs(W, exist_ok=True)
# (build.zig.zon takes the UI library from ../BeeZigUi: beside each copy too)
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.realpath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, sec = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', d)
        if os.path.exists(f'{ROOT}/zig-pkg'):
            os.symlink(f'{ROOT}/zig-pkg', f'{d}/zig-pkg')
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        if sec == 'unit':
            r = subprocess.run(['zig', 'test', 'src/link.zig', '--cache-dir', CACHE], cwd=d, capture_output=True, text=True)
            ok = r.returncode != 0
            return name, ('ok' if ok else 'LIVE'), ('the unit tests fail: ' + r.stderr.strip().splitlines()[-1][:90] if ok else 'the unit tests pass')
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', CACHE, '-Dgpu=false'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        with RUN:
            e = dict(os.environ, LL_ONLY=sec, LL_FUZZ='60')
            r = subprocess.run([sys.executable, '-u', f'{HERE}/livelink.py', f'{d}/out/bin/beemodel'],
                               env=e, capture_output=True, text=True, timeout=1800)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {sec}: {fails[0].strip()[:100]}' if fails else f'nothing in {sec} failed')
    finally:
        shutil.rmtree(d, ignore_errors=True)


bad = []
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    for name, st, msg in ex.map(one, range(len(M))):
        print(f'  {st:4} {name}: {msg}', flush=True)
        if st != 'ok':
            bad.append(name)
shutil.rmtree(CACHE, ignore_errors=True)
print('survivors', len(bad), bad)
print('... fails %d' % len(bad))
sys.exit(1 if bad else 0)
