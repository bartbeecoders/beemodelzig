#!/usr/bin/env python3
"""BeeScript's content library builtins (src/bs_lib.zig: lib libfind libinfo;
library.s lb_stat, lb_find_nth, lb_info) run by BeeModel through --eval,
offline (the libraries are folders under a temp HOME; nothing is fetched),
each script with a HOME of its own: a clean result or a clean script error
(no crash, panic or timeout). Assets saved by the scripts themselves
(objects, a scene, tags) read back with their kinds and tags, a library made
by one run and read by the next (a second folder through lib.add too),
thumbnails made and not, every word of libinfo, searches (case, several
words, kinds, tags, the browser's search they leave behind), edge values,
every argument count with junk values, a damaged index.txt, random searches,
random garbage.

    python3 tests/bs_lib.py BIN [random-runs=60] [seed]
"""
import os, random, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bsboth as B

A = sys.argv + [os.path.join(B.ROOT, 'zig-out-debug/bin/beemodel')] * (len(sys.argv) < 2)
B.setup(A[:2] + ['-'] + A[2:], 60)   # (bsboth: BIN ORIG RUNS SEED; no ORIG)
NAMES = {k: v for k, v in B.table({'libraries'}).items() if k in ('lib', 'libfind', 'libinfo')}


def runh(binary, code, lib=None, extra=None, timeout=300):
    """--eval with a HOME holding a copy of `lib` as ~/BeeModel/library (and
    `extra` as ~/more): (rc, stdout)."""
    h = tempfile.mkdtemp(dir=B.T)
    if lib:
        shutil.copytree(lib, os.path.join(h, 'BeeModel', 'library'))
    if extra:
        shutil.copytree(extra, os.path.join(h, 'more'))
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h, XDG_CACHE_HOME=os.path.join(h, 'cache'))
    env.pop('WAYLAND_DISPLAY', None)
    try:
        r = subprocess.run([binary, '--eval', code.replace('@HOME', h)], capture_output=True, timeout=timeout, env=env)
        out = (r.returncode, r.stdout.decode('utf-8', 'replace'))
    except subprocess.TimeoutExpired:
        out = (None, 'timeout')
    shutil.rmtree(h, True)
    return out


def same(code, what=None, lib=None, extra=None, quiet=False):
    """A clean run (bsboth.clean) with that library."""
    b = runh(B.BIN, code, lib, extra)
    ok = B.clean(b)
    if not quiet or not ok:
        B.check(ok, (what or repr(code[:90])) + ('' if ok else f'\n         {b!r}'))
    return ok


def make_lib(code, dst):
    """A library BeeModel makes: code run in a HOME, its ~/BeeModel/library kept."""
    h = tempfile.mkdtemp(dir=B.T)
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h)
    env.pop('WAYLAND_DISPLAY', None)
    subprocess.run([B.BIN, '--eval', code], capture_output=True, timeout=600, env=env)
    shutil.copytree(os.path.join(h, 'BeeModel', 'library'), dst)
    shutil.rmtree(h, True)
    return dst


SAVE = ('op("lib.save", "object Cube #box #red")\nadd("sphere", "Ball")\nop("lib.save", "object Ball #round #red")\n'
        'select("Cube", "Ball")\nop("lib.save", "object Pair #two")\nop("lib.save", "scene Whole #all")\n'
        'm = material("Gold")\nmatset(m, "metallic", 1)\nassign("Cube", m)\nselect("Cube")\nop("lib.save", "object GoldBox #box #shiny")\n')
LIB = make_lib(SAVE, os.path.join(B.T, 'lib1'))
LIB2 = make_lib('add("cone", "Spike")\nop("lib.save", "object Spike #sharp")\nop("lib.save", "object Cube #box")\nop("lib.thumbnails")', os.path.join(B.T, 'lib2'))
WORDS = ['kind', 'id', 'blob', 'tags', 'uses', 'users', 'thumb', 'x', '', 'k', 'iD', 'th', 't', 'b', 'u', 'usesX', 'users!', 'thumbnail', 'tagsss']

print('-- the libraries made --')
idx = [ln.split('\t') for ln in open(os.path.join(LIB, 'index.txt')).read().splitlines()]
B.check({('object', 'Cube', 'box,red'), ('object', 'Ball', 'round,red'), ('object', 'Pair', 'two'), ('scene', 'Whole', 'all'), ('object', 'GoldBox', 'box,shiny')}
        <= {(r[1], r[2], r[5]) for r in idx if len(r) == 6} and ['material', 'Gold'] in [r[1:3] for r in idx]
        and all(len(r) == 6 and os.path.exists(os.path.join(LIB, 'blobs', r[3] + '.bee')) for r in idx),
        f'the library made: the five assets with their kinds and tags in index.txt, the material GoldBox uses, each blob there ({[r[1:3] for r in idx]})')
r = runh(B.BIN, SAVE + 'print(libinfo("Cube", "kind"), libinfo("Whole", "kind"), libinfo("Cube", "tags"), libinfo("Pair", "tags"))\nprint(libfind("red", 0), libfind("red", 1), libfind("red", 2))')
B.check(r == (0, 'object scene box,red two\nCube Ball nil\n'), f'assets a script saves read back in the same run (kinds, tags, a search): {r!r}')
r = runh(B.BIN, 'print(libinfo("Cube", "kind"), libinfo("GoldBox", "tags"), libinfo("Whole", "kind"), libfind("shiny", 0))\n'
           'print(libinfo("GoldBox", "uses"), libinfo("GoldBox", "users"), libinfo("Gold", "uses"), libinfo("Gold", "users"))', LIB)
B.check(r == (0, 'object box,shiny scene GoldBox\nGold - - GoldBox\n'), f'the library made, read by the next run (GoldBox uses Gold, Gold\'s user is GoldBox): {r!r}')

print('-- an empty library --')
for code in ['for k in 0..6 { print(k, lib(k)) }', 'print(lib(-1), lib(99), lib(sqrt(-1)), lib(1e30), lib(-1e30))',
             'print(libfind("", 0), libfind("x", 0), libfind("", -1))', 'print(libinfo("Cube", "kind"), libinfo("", ""))']:
    same(code)

print('-- assets the scripts save --')
for code in ([SAVE + 'for k in 0..6 { print(k, lib(k)) }',
             SAVE + 'for i in 0..7 { print(i, libfind("", i)) }\nprint(lib(4))',
             SAVE + 'print(libfind("box", 0), libfind("box", 1), libfind("box", 2), libfind("BOX", 0), libfind("red box", 0), libfind("  red   box  ", 0), lib(4))',
             SAVE + 'print(libfind("object", 0), libfind("scene", 0), libfind("material", 0), libfind("obj", 3), libfind("o", 4), libfind("zz", 0), lib(4))',
             SAVE + 'print(libfind("box", sqrt(-1)), libfind("box", 1e30), libfind("box", -1e30), libfind("box", 0.9), libfind("box", -0.9))',
             SAVE + 'op("lib.thumbnails")\nfor k in 0..6 { print(k, lib(k)) }\nprint(libinfo("Cube", "thumb"), libinfo("Whole", "thumb"))',
             ] + [SAVE + f'for a in 0..1 {{ print("{w}", libinfo("Cube", "{w}"), libinfo("Pair", "{w}"), libinfo("Whole", "{w}"), libinfo("GoldBox", "{w}")) }}' for w in WORDS if w[0:1] not in 'ib']
             + [SAVE + f'print("{w}", libinfo("Cube", "{w}"), libinfo("GoldBox", "{w}"))' for w in WORDS if w[0:1] in 'ib']):
    same(code)

print('-- a library made by an earlier run --')
for code in ['for k in 0..6 { print(k, lib(k)) }', 'for i in 0..7 { print(i, libfind("", i), libinfo(libfind("", i), "kind")) }',
             'print(libinfo(libinfo("Cube", "id"), "kind"), libinfo(libinfo("Cube", "id"), "tags"), libinfo(libinfo("Whole", "blob"), "kind"))',
             'print(libinfo("0000000000000000", "kind"), libinfo("Cube.001", "kind"), libinfo("cube", "kind"))',
             'print(libinfo("GoldBox", "uses"), libinfo("Gold", "users"), libinfo("Gold", "kind"))',
             'op("lib.tag", "Cube #new -red")\nprint(libinfo("Cube", "tags"), libfind("new", 0), libfind("red", 1), lib(4))',
             'op("lib.remove", "Ball")\nprint(lib(0), libfind("round", 0), libinfo("Ball", "kind"))',
             'op("lib.add", "@HOME/more")\nfor k in 0..6 { print(k, lib(k)) }\nfor i in 0..9 { print(i, libfind("", i)) }\nprint(libinfo("Spike", "thumb"), libinfo("Cube", "thumb"), libfind("box", 1))',
             'op("lib.search", "red")\nprint(lib(4))\nprint(libfind("box", 0), lib(4))']:
    same(code, lib=LIB, extra=LIB2)

print('-- a damaged index.txt --')
DMG = os.path.join(B.T, 'dmg')
shutil.copytree(LIB, DMG)
good = open(os.path.join(DMG, 'index.txt')).read().splitlines()
rnd = random.Random(B.SEED)
lines = good + ['zz00000000000001\tobject\tBad\t0000000000000001\t-\t-', '0000000000000002\tthing\tBad\t0000000000000001\t-\t-',
                '0000000000000004\tobject\tNoTab', '0000000000000005\tmaterial\t' + 'L' * 80 + '\t0000000000000001\t-\t' + 't' * 120, '', '\t\t\t', 'X' * 700]
lines += [''.join(chr(rnd.randrange(1, 128)) for _ in range(rnd.randrange(0, 90))) for _ in range(20)]
open(os.path.join(DMG, 'index.txt'), 'w').write('\n'.join(lines))
for code in ['for k in 0..6 { print(k, lib(k)) }', 'for i in 0..12 { print(i, libfind("", i)) }',
             'for i in 0..12 { n = libfind("", i)\n if n != nil { print(libinfo(n, "kind"), libinfo(n, "id"), libinfo(n, "tags"), libinfo(n, "uses"), libinfo(n, "users")) } }',
             'print(libfind("L", 0), libfind("t", 0), libinfo("NoTab", "tags"))']:
    same(code, 'damaged: ' + code[:60], lib=DMG)

print('-- edge values, wrong types --')
for v in ['0', '-0', '1e30', '-1e30', 'sqrt(-1)', '1e308*10', '-1', '2147483648', '""', '"' + 'w' * 300 + '"', 'nil', '"box"']:
    same(f'x = {v}\nprint(lib(x))\nprint(libfind("box", x))\nprint(libfind(x, 0))\nprint(libinfo(x, "kind"))\nprint(libinfo("Cube", x))', f'edge value {v[:20]}', lib=LIB)

print('-- every argument count, junk values --')
B.check(len(NAMES) == 3, 'the table: 3 library builtins')
B.argcounts(NAMES)

print('-- random searches --')
rnd = random.Random(B.SEED + 1)
vocab = ['box', 'red', 'round', 'two', 'all', 'shiny', 'object', 'scene', 'Cube', 'cu', 'b', 'O', 'zz', '', 'RED', 'x']
bad = 0
for k in range(B.RUNS):
    L = []
    for _ in range(rnd.randint(1, 6)):
        w = ' '.join(rnd.choice(vocab) for _ in range(rnd.randint(0, 3)))
        L.append(f'n = libfind("{w}", {rnd.randint(-1, 4)})\nprint(n, lib(4), lib({rnd.randint(-1, 5)}))')
        L.append(f'if n != nil {{ print(libinfo(n, "{rnd.choice(WORDS)}")) }}')
    if not same('\n'.join(L), f'random {k}', lib=LIB, quiet=True):
        bad += 1
        if bad > 3:
            break
B.check(bad == 0, f'{B.RUNS} random searches: clean runs')

print('-- random garbage: no crash, no hang --')
vals = ['""', '"box"', '"Cube"', '0', '-1', '1e300', 'sqrt(-1)', 'nil', '"' + 'Q' * 400 + '"', '"0000000000000000"', '"ffffffffffffffff"', '"users"', '"t"']
bad = []
for k in range(B.RUNS * 3):
    L = []
    for _ in range(rnd.randint(1, 8)):
        nm = rnd.choice(list(NAMES))
        mn, mx = NAMES[nm]
        L.append(f'print({nm}({", ".join(rnd.choice(vals) for _ in range(rnd.randint(mn, mx)))}))')
    r = runh(B.BIN, '\n'.join(L), LIB)
    if not B.clean(r):
        bad.append(('\n'.join(L), r))
B.check(not bad, f'{B.RUNS * 3} garbage programs: clean runs' + (f': {bad[:2]}' if bad else ''))

B.finish('bs_lib')
