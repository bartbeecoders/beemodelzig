#!/usr/bin/env python3
"""Each guard of tests/world.py shown failing: world partition's code broken, one
thing at a time, in a copy of the sources; the named sections of the suite must
then fail. A mutant that survives is a test that passes on nothing.

    python3 tests/world_mutants.py WORKDIR [jobs=4] [name...]   (WORKDIR under /tmp)

The mutants are built side by side (jobs at once; the sources' copies, their
binaries and the build cache in WORKDIR); their tests run one after another
(the window tests are pinned to BEE_CPU, default 14). Each mutant's folders go
when it is done. (Mutants only a byte-for-byte match with the original caught
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
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
WZ = 'src/world.zig'
M = [  # name, file, old, new, the sections that must fail
    # --- the cells and their files
    ('a cell under a point: truncated, not floored', WZ, 'return .{ nt.cvtt(@floor(a)), nt.cvtt(@floor(b)) };', 'return .{ nt.cvtt(@trunc(a)), nt.cvtt(@trunc(b)) };', 'bees'),
    ('LAND not written', WZ, '        @import("landscape.zig").writeChunk(&b, ix);\n', '', 'land'),
    # --- streaming
    ('no budget', WZ, '        while (loaded_bytes > budget) {', '        while (false) {', 'stream'),
    ('a changed cell not written', WZ, '    return if (c.disk) s.fp != c.fp else s.n != 0;', '    _ = s;\n    return !c.disk and false;', 'stream'),
    ('a crossed-in object: the cell not marked changed', WZ, 'c.fp = if (extra != 0) s.fp ^ 1 else s.fp;', 'c.fp = s.fp;', 'stream'),
    ('world(3) in KiB', WZ, 'const mb: f32 = 9.5367432e-7;', 'const mb: f32 = 9.765625e-4;', 'stream'),
    ('damaged meshes not checked', WZ, '            if (!meshOk(ch)) break; // (a damaged file: what came so far)', '', 'damaged'),
    ('WRLP: its count not checked', WZ, '    if (20 + n * REC > d.len) return;', '', 'damaged'),
    ('streaming keeps the undo history', WZ, '    @import("undo.zig").restart();\n    files.historyRestarted(was);', '    _ = was;', 'window'),
    # --- drawing
    ('minimap: a changed cell green', WZ, 'col = if (ch) 0xe5a33b else 0x3e9b52;', 'col = if (ch) 0x3e9b52 else 0x3e9b52;', 'window'),
    ('no boxes', WZ, '            line(cv, c, a, b, 0x555b66);', '            if (false) line(cv, c, a, b, 0x555b66);', 'window'),
    ('world.minimap does nothing', WZ, '    minimap = !minimap;\n', '', 'window'),
    ('the panel\'s toggle runs nothing', WZ, '"Partition the world", &want)) partitionFromPanel(want);', '"Partition the world", &want)) {}', 'panel'),
    # --- the scene file
    ('WRLP not read', 'src/bee.zig', '    if (wrlp) |c| @import("world.zig").chunkRead(c);', '    if (wrlp) |c| _ = c;', 'stream'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
CACHE = os.path.join(W, 'zc')
OUT = lambda k: os.path.join(W, f'out{k}')


def build(k):
    name, fn, old, new, sec = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    shutil.copytree(f'{ROOT}/src', f'{d}/src')
    shutil.copy(f'{ROOT}/build.zig', d)
    if os.path.exists(f'{ROOT}/build.zig.zon'):
        shutil.copy(f'{ROOT}/build.zig.zon', d)
    p = f'{d}/{fn}'
    t = open(p).read()
    if old not in t:
        return 'the code is not there'
    open(p, 'w').write(t.replace(old, new, 1))
    ui_link(d)
    r = subprocess.run(['zig', 'build', '-p', OUT(k), '--cache-dir', CACHE], cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        return 'it does not build: ' + r.stderr[-300:]
    shutil.rmtree(f'{d}/src', True)
    return None


def test(k):
    name, fn, old, new, sec = M[k]
    d = f'{W}/m{k}'
    e = dict(os.environ, WORLD_ONLY=sec)
    r = subprocess.run([sys.executable, '-u', f'{HERE}/world.py', f'{OUT(k)}/bin/beemodel', '6', '4242'],
                       env=e, capture_output=True, text=True)
    fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
    if r.returncode != 0 and not fails:
        fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
    return fails


errs = {}
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    for k, err in zip(range(len(M)), ex.map(build, range(len(M)))):
        errs[k] = err
bad = []
for k in range(len(M)):
    name, sec = M[k][0], M[k][4]
    if errs[k]:
        print(f'  ?    {name}: {errs[k]}', flush=True)
        bad.append(name)
    else:
        fails = test(k)
        st = 'ok' if fails else 'LIVE'
        print(f'  {st:4} {name}: ' + (f'{len(fails)} failed in {sec}: {fails[0].strip()[:110]}' if fails else f'nothing in {sec} failed'), flush=True)
        if not fails:
            bad.append(name)
    shutil.rmtree(f'{W}/m{k}', True)
    shutil.rmtree(OUT(k), True)
print(f'{len(M) - len(bad)} of {len(M)} mutants caught; survivors', len(bad), bad)
sys.exit(1 if bad else 0)
