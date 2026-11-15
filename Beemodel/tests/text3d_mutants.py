#!/usr/bin/env python3
"""Each guard of tests/text3d.py and tests/text3d_wl.py shown failing: the code
it guards broken, one thing at a time, in a copy of the sources; that part of a
suite must then fail. A mutant that survives is a test that passes on nothing.

    python3 tests/text3d_mutants.py WORKDIR [jobs=1] [name...]   (WORKDIR under /tmp)

BEE_CPU (default 10) pins the builds and the runs. Each mutant's tree and
cache go as soon as it is done. (Gone since BeeModel stopped being a port: the
mutants of the outline walk, the solid, the lines, the pen, the animation, the
words, the counting bodies and the damaged blocks - only the original's meshes
and blocks caught them; a script and the console share that code - and of the
panel's pixels.)
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
X = 'src/text3d.zig'
F = 'src/ttfol.zig'
U = 'src/textui.zig'
M = [  # name, file, old, new, suite (text3d / wl), the scenarios that must fail
    # --- the outline walk (ttfol.zig)
    # --- loops and the solid (text3d.zig)
    # (crossings at shared points: not a mutant - two edges sharing a point give a zero side and no crossing either way)
    # --- lines, pen, animation
    # --- words and blocks
    # --- bodies that count, keys
    ('frames: the text\'s new mesh an undo step', X, '        if (txApply(i, b)) undo.absorb(i);\n    }\n}', '        _ = txApply(i, b);\n    }\n}', 'text3d', 's_undo'),
    # --- files
    ('TEXT: the hash not kept', X, '    b.hash = txHash(exp);', '    _ = txHash(exp);', 'text3d', 's_files'),
    ('TEXT: not read', 'src/bee.zig', '    if (text) |c| @import("text3d.zig").readChunk(c, mesh_map); // (texts)\n', '', 'text3d', 's_files'),
    ('to_mesh keeps the text', 'src/scene.zig', '    me.text = null; // (nor the text)\n', '', 'text3d', 's_files'),
    # --- the window
    ('panel: new lines shown as they are', U, '        if (c == 10) {\n            tu_body[tu_body_n] = \'\\\\\';', '        if (false) {\n            tu_body[tu_body_n] = \'\\\\\';', 'wl', ''),
    ('panel: a picked font not used', U, '            tx.setValues(obj, tu_flt, tu_align, tu_rmode, null, tx.tfLabel(@intCast(k)) orelse "");', '            tx.setValues(obj, tu_flt, tu_align, tu_rmode, null, null);', 'wl', ''),
    ('panel: I over a value keys nothing', U, '    @import("wg.zig").info(label, std.math.nan(f32), .{ .text = @intCast(k) }); // (I over it: text:<name>:<value>)\n', '', 'wl', ''),
    ('font list: case counts', X, '        const ca = x[k] | 0x20;\n        const cb = y[k] | 0x20;', '        const ca = x[k];\n        const cb = y[k];', 'wl', ''),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# (build.zig.zon takes the UI library from ../BeeZigUi: beside each copy too)
if os.path.isdir(f'{ROOT}/../BeeZigUi') and not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.realpath(f'{ROOT}/../BeeZigUi'), f'{W}/BeeZigUi')
CPU = os.environ.get('BEE_CPU', '10')


def one(k):
    name, fn, old, new, suite, scen = M[k]
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
        # (a release build: a debug one is 300 MB, too much for /tmp twice over)
        r = subprocess.run(['taskset', '-c', CPU, 'zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false', '--release=fast'], cwd=d, capture_output=True, text=True)
        shutil.rmtree(f'{d}/zc', ignore_errors=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, TX_ONLY=scen, BEE_CPU=CPU)
        if suite == 'text3d':
            cmd = [sys.executable, '-u', f'{HERE}/text3d.py', f'{d}/out/bin/beemodel', '2', '4242']
        else:
            cmd = [sys.executable, '-u', f'{HERE}/text3d_wl.py', f'{d}/out/bin/beemodel']
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
