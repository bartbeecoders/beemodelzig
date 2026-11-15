#!/usr/bin/env python3
"""Each guard of tests/usd.py shown failing: the USD code broken, one thing at a
time, in a copy of the sources; the scenario of tests/usd.py that guards it
must then fail. A mutant that survives is a test that passes on nothing.

    python3 tests/usd_mutants.py [jobs=2] [name...]

The copies and their builds go on the project disk: .usd-scratch/mut/m<k>
(sources) and zig-out-usd-mut<k> (the build, with the shared .zig-cache), each
removed once its mutant is judged; USD_MUT_DIR puts all of it (the copies, the
builds, the cache) in a folder of its own instead. (Since 2026-11-14 the
readers' mutants are caught against OpenUSD (s_pxr) and the transforms'
against its composition (s_stage); the ones only the original's fixtures or a
match with the original caught are gone.)
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
MUTDIR = os.environ.get('USD_MUT_DIR')
W = os.path.join(os.path.abspath(MUTDIR), 'mut') if MUTDIR else os.path.join(ROOT, '.usd-scratch', 'mut')
CACHE = os.path.join(os.path.abspath(MUTDIR), 'zc') if MUTDIR else os.path.join(ROOT, '.zig-cache')
JOBS = int(sys.argv[1]) if len(sys.argv) > 1 else 2
M = [  # name, file, old, new, the scenarios that must fail
    # --- the crate reader
    ('lz4: matches one byte short', 'src/usdc.zig', 'ml += 4;', 'ml += 3;', 's_pxr'),
    ('ints: small deltas of two bytes', 'src/usdc.zig', 'const sz: usize = if (code == 1) 1 else if (code == 2) 2 else 4;', 'const sz: usize = if (code == 1) 2 else if (code == 2) 2 else 4;', 's_pxr'),
    ('halfs: subnormals off by two', 'src/usdc.zig', 'const f: f32 = @as(f32, @floatFromInt(m)) * 5.9604645e-8;', 'const f: f32 = @as(f32, @floatFromInt(m)) * 1.1920929e-7;', 's_pxr'),
    ('paths: a slash after a variant', 'src/usdc.zig', "} else if (!(o > 0 and (c.pbuf[o - 1] == '/' or c.pbuf[o - 1] == '}'))) {", "} else if (!(o > 0 and (c.pbuf[o - 1] == '/'))) {", 's_pxr'),
    ('list ops: payload lists as text', 'src/usdc.zig', 'const refs = typ == 35 or typ == 55;', 'const refs = typ == 35;', 's_pxr'),
    ('inlined int64: not sign-extended', 'src/usdc.zig', 'if (typ == 3 or typ == 5)', 'if (typ == 3)', 's_pxr'),
    ('paths: no step budget (a loop never ends)', 'src/usdc.zig', 'if (steps > budget) return false;', '_ = budget;', 's_damage'),
    # --- the text reader
    ('numbers: 15 digits kept', 'src/usda.zig', 'if (kept >= 18) { // digits past 18: only the scale', 'if (kept >= 15) { // digits past 18: only the scale', 's_pxr'),
    ('halfs: not rounded to 10 bits', 'src/usda.zig', 'b = (b +% ((b >> 13) & 1) +% 0x0fff) & 0xffffe000;', 'b = b & 0xffffe000;', 's_pxr'),
    ('quaternions: not turned x y z w', 'src/usda.zig', 'if (kind == VK_QUAT) { // w x y z -> x y z w', 'if (kind == VK_QUAT and false) { // w x y z -> x y z w', 's_pxr'),
    ('children: a set\'s variants as sets', 'src/usda.zig', 'else => if (p.kind == ul.UK_VARIANT) "variantChildren" else "variantSetChildren",', 'else => "variantSetChildren",', 's_pxr'),
    # --- the stage
    ('pivots: not inverted', 'src/usd.zig', 'for (0..3) |c| m[c * 4 + 3] = if (inv) 0.0 - d[c] else d[c];', 'for (0..3) |c| m[c * 4 + 3] = d[c];', 's_stage'),
    ('Z up turned the other way', 'src/usd.zig', 'cm = .{ 1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1 };', 'cm = .{ 1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1 };', 's_stage'),
    ('C^-1 not the transpose', 'src/usd.zig', 'for (0..16) |i| ci[i] = cm[(i & 3) * 4 + (i >> 2)];', 'for (0..16) |i| ci[i] = cm[i];', 's_stage'),
    ('a UV of 0, 0 counts', 'src/usd.zig', 'if (u == 0) every = false;', '_ = &every;', 's_edges'),
    ('rotateX left out', 'src/usd.zig', 'if (v.t == ul.UT_DBL) return m4.axisRot(ax, v.dbl() * deg);', 'if (v.t == ul.UT_DBL) return null;', 's_stage'),
    ('angles by the order\'s letters', 'src/usd.zig', 'for (0..3) |c| ang[c] = @floatCast(d[c] * deg);', 'for (0..3) |c| ang[r[c] - \'X\'] = @floatCast(d[c] * deg);', 's_stage'),
    # --- materials
    # --- physics
    # --- the window
    ('a dropped .usda not imported', 'src/drop.zig', 'if (is(e, ".usd") or is(e, ".usda") or is(e, ".usdc")) return .usd;', '', 's_window'),
]
want = sys.argv[2:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)


def one(k):
    name, fn, old, new, scen = M[k]
    d = os.path.join(W, 'm%d' % k)
    out = os.path.join(os.path.abspath(MUTDIR), 'out%d' % k) if MUTDIR else os.path.join(ROOT, 'zig-out-usd-mut%d' % k)
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
        open(p, 'w').write(t.replace(old, new, 1))
        ui_link(d)
        r = subprocess.run(['zig', 'build', '-p', out, '--cache-dir', CACHE, '-Dgpu=false'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, USD_ONLY=scen, USD_GEN='12')
        r = subprocess.run([sys.executable, '-u', os.path.join(HERE, 'usd.py'), os.path.join(out, 'bin', 'beemodel'),
                            '60', '4242'], env=e, capture_output=True, text=True, timeout=3600)
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
