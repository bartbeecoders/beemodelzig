#!/usr/bin/env python3
"""Each guard of tests/landio.py shown failing: landio.zig broken, one thing at a
time, in a copy of the sources; the suite must then fail. A mutant that
survives is a test that passes on nothing.

    python3 tests/landio_mutants.py WORKDIR [name...]   (WORKDIR under /tmp)

One at a time (the suite pins BEE_CPU, default 20). LANDIO_MUT_CACHE: a zig cache to
share (else one in WORKDIR).
"""
import os, shutil, subprocess, sys
import temphome  # (a HOME of its own, given to every child)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
F = 'src/landio.zig'
# the project's zig by its full path (a mise shim finds no version in the copies: no mise.toml there;
# mise asked with the user's real HOME: temphome gave this process another)
try:
    import pwd
    _z = subprocess.run(['mise', 'which', 'zig'], capture_output=True, text=True, cwd=ROOT,
                        env=dict(os.environ, HOME=pwd.getpwuid(os.getuid()).pw_dir)).stdout.strip()
except OSError:
    _z = ''
ZIG = [_z if _z else 'zig']
M = [  # name, old, new, the sections that must fail
    # (a tie of a and b is never decided by the order: pa == pb with a != b means pc = 0)
    ('paeth: ties to c', 'else if (pb <= pc) b', 'else if (pb < pc) b', 'damaged'),
    ('average filter rounds up', 'v += (a + b) >> 1', 'v += (a + b + 1) >> 1', 'damaged'),
    ('EXR predictor off by one', 'tmp[k] -% 128', 'tmp[k] -% 127', 'damaged'),
    ('EXR halves swapped', 'tmp[if (q & 1 == 0) q / 2 else half + q / 2]', 'tmp[if (q & 1 == 1) q / 2 else half + q / 2]', 'damaged'),
    ('EXR: R before Y', "if (v[n0] == 'Y') {", "if (v[n0] == 'Q') {", 'damaged'),
    ('half subnormals', '0x33800000', '0x34000000', 'damaged'),
    ('half exponent bias', '(e + 112) << 23', '(e + 111) << 23', 'damaged'),
    ('resample: by n, not n - 1', 'const nm1: f32 = @floatFromInt(n - 1);', 'const nm1: f32 = @floatFromInt(n);', 'damaged'),
    ('side: one size more', 'while (c < s and c < 4097)', 'while (c <= s and c < 4097)', 'damaged'),
    ('PNG default height 10', 'else if (is_png) 100 else 1', 'else if (is_png) 10 else 1', 'damaged'),
    ('size not a metre a sample', '@floatFromInt(n - 1);\n    b.nl = 1;', '@floatFromInt(n);\n    b.nl = 1;', 'damaged'),
    ('base not added', 'dst[k] = dst[k] * height + args[2];', 'dst[k] = dst[k] * height;', 'damaged'),
    ('export: no rounding', '* 65535.0 + 0.5', '* 65535.0', 'damaged'),
    ('EXR export: line sizes', 'try put32(&out, n * 4);', 'try put32(&out, n * 4 + 1);', 'damaged'),
    ('to_mesh full: z from the column', '@as(f32, @floatFromInt(r)) * cell - half };', '@as(f32, @floatFromInt(c)) * cell - half };', 'to_mesh'),
    ('to_mesh full: no colours', '        la.vcolOf(b, me);\n    } else {', '    } else {', 'to_mesh'),
    ('tiles: not centred', '((@as(f32, @floatFromInt(ax)) + 0.5) * tsize', '((@as(f32, @floatFromInt(ax)) + 0.0) * tsize', 'tiles'),
    ('tiles: display not copied', 'b.disp = src.disp;', 'b.disp = 0;', 'tiles'),
    ('tiles: no paint', 'if (src.splat != 0) dsp[r * ts + c] = sp_src[s];', 'if (src.splat == 1) dsp[r * ts + c] = sp_src[s];', 'tiles'),
    ('tiles: 32 samples enough', '(src.n - 1) / uk < 64', '(src.n - 1) / uk < 32', 'tiles'),
    ('tiles: the landscape stays', '    scene.remove(a.i);\n', '', 'tiles'),
    ('import: not made active', 'scene.selectOnly(i);\n    app.log("  imported', '_ = i;\n    app.log("  imported', 'damaged'),
    ('to_mesh: nothing changes', '    scene.objects[a.i].mesh = mi;\n    app.dirty = true;\n}\n\n/// do_la_tiles', '    if (mi == 0xffff) scene.objects[a.i].mesh = mi;\n    app.dirty = true;\n}\n\n/// do_la_tiles', 'undo'),
]
want = sys.argv[2:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
bad = []
for k, (name, old, new, sec) in enumerate(M):
    d = f'{W}/m'
    shutil.rmtree(f'{d}/src', ignore_errors=True)
    os.makedirs(d, exist_ok=True)
    shutil.copytree(f'{ROOT}/src', f'{d}/src')
    shutil.copy(f'{ROOT}/build.zig', d)
    # (the UI library sits next to the project: the copy names it by a path relative to itself; zig wants no absolute one)
    zon = open(f'{ROOT}/build.zig.zon').read().replace('"../BeeZigUi"', '"' + os.path.relpath(os.path.join(os.path.dirname(ROOT), 'BeeZigUi'), d) + '"')
    open(f'{d}/build.zig.zon', 'w').write(zon)
    if os.path.isdir(f'{ROOT}/zig-pkg') and not os.path.exists(f'{d}/zig-pkg'):
        os.symlink(f'{ROOT}/zig-pkg', f'{d}/zig-pkg')
    p = f'{d}/{F}'
    t = open(p).read()
    if old not in t:
        print(f'  ?    {name}: the code is not there', flush=True)
        bad.append(name)
        continue
    open(p, 'w').write(t.replace(old, new, 1))
    r = subprocess.run([*ZIG, 'build', '-p', f'{d}/out', '--cache-dir', os.environ.get('LANDIO_MUT_CACHE', f'{W}/zc')], cwd=d, capture_output=True, text=True, env=dict(os.environ, HOME=temphome.HOME))
    if r.returncode != 0:
        shutil.rmtree(f'{W}/zc', ignore_errors=True)
        print(f'  ?    {name}: it does not build: {r.stderr[-300:]}', flush=True)
        bad.append(name)
        continue
    e = dict(os.environ, LANDIO_ONLY=sec, HOME=temphome.HOME)
    r = subprocess.run([sys.executable, '-u', f'{HERE}/landio.py', f'{d}/out/bin/beemodel', '4', '4242'], env=e, capture_output=True, text=True)
    fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
    if r.returncode != 0 and not fails:
        fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
    shutil.rmtree(f'{d}/out', ignore_errors=True)  # (tmpfs quota: each build's cache goes too)
    if not os.environ.get('LANDIO_MUT_CACHE'):
        shutil.rmtree(f'{W}/zc', ignore_errors=True)
    print(f"  {'ok' if fails else 'LIVE':4} {name}: " + (f'{len(fails)} failed: {fails[0].strip()[:90]}' if fails else f'nothing in {sec} failed'), flush=True)
    if not fails:
        bad.append(name)
shutil.rmtree(W, ignore_errors=True)
print('survivors', len(bad), bad)
sys.exit(1 if bad else 0)
