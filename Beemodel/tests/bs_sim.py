#!/usr/bin/env python3
"""BeeScript's simulation, animation, rigging, play and phase 13 builtins
(src/bs_phys.zig, bs_land.zig, bs_anim.zig, bs_play.zig, bs_net.zig) run by
BeeModel through --run (a temp HOME, XDG_RUNTIME_DIR and working folder
each): every script ends cleanly (a result or a script error, no crash,
panic, leak or timeout), a wrong call is refused with an error, and the
scenes they save read back and come back the same through open and save.

  physics    rbinfo field force fieldinfo emit particles shatter height rigid
             joint collisions clothinfo cacheinfo
  landscape  landscape shinfo
  animation  key unkey keyed
  rigging    armature evpos bones shapes bonepos wpaint weight
  play       playstep playlook playinfo playkey logic logicvar
  phase 13   livelink vcinfo vctext costat cohash (no link, no repository,
             no session)

Each builtin: normal calls, every argument count, wrong types and bad names,
edge values (NaN, huge, negative, empty text), random calls; scenes simulated
over frames; undo after a run; damaged files; garbage.

    python3 tests/bs_sim.py BIN [random-runs=60] [seed]

BS_ONLY=net,phys,land,anim,rig,play,args,random,files,garbage,leak,window runs some
sections (window: the window under the fake compositor, pinned to BEE_CPU,
default 8; BS_KEEP=1 keeps the screenshots);
BS_ONLY=perf times the builtins that do real work (release builds, BEE_CPU).
"""
import ast, os, random, re, shutil, struct, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 60
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
ONLY = [x for x in os.environ.get('BS_ONLY', '').split(',') if x]
SHOW = os.environ.get('BS_SHOW')
JOBS = int(os.environ.get('BS_JOBS', '4'))
FAILS = []
T = tempfile.mkdtemp(prefix='beebsim-', dir='/tmp')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def want(s):
    return not ONLY or s in ONLY


def expand(code):
    """`for v in [a, b, [c, d]] { body }` (the tests' shorthand; BeeScript has no
    lists) written out: the body once per item, v[k] its k-th part."""
    out, i = [], 0
    pat = re.compile(r'for (\w+) in \[')
    while True:
        m = pat.search(code, i)
        if not m:
            out.append(code[i:])
            return ''.join(out)
        out.append(code[i:m.start()])
        j, depth = m.end() - 1, 0
        while True:
            depth += {'[': 1, ']': -1}.get(code[j], 0)
            if depth == 0:
                break
            j += 1
        items = ast.literal_eval(code[m.end() - 1:j + 1].replace('sqrt(-1)', '"sqrt(-1)"'))
        k = code.index('{', j)
        e, depth = k, 0
        while True:
            depth += {'{': 1, '}': -1}.get(code[e], 0)
            if depth == 0:
                break
            e += 1
        body = expand(code[k + 1:e])
        v = m.group(1)

        def lit(x):
            return f'"{x}"' if isinstance(x, str) and x != 'sqrt(-1)' else str(x)
        for it in items:
            b = body
            if isinstance(it, list):
                for q, x in enumerate(it):
                    b = b.replace(f'{v}[{q}]', lit(x))
            b = re.sub(r'(?<![\w"])' + v + r'(?![\w"])', lit(it), b) if not isinstance(it, list) else b
            out.append(b.strip(' ') + '\n')
        i = e + 1


def envOf(h):
    """A run's own HOME and XDG folders (the user's shell sets them to the real ones)."""
    e = dict(os.environ, HOME=h)
    for v, sub in (('XDG_CACHE_HOME', 'cache'), ('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data'), ('XDG_STATE_HOME', 'state'), ('XDG_RUNTIME_DIR', '')):
        e[v] = os.path.join(h, sub) if sub else h
    return e


def run(binary, code, timeout=300, files=None, pre=None):
    """A script through --run with a HOME, XDG_RUNTIME_DIR and working folder of
    its own: (rc, stdout, the files asked for as bytes, the folder's names)."""
    h = tempfile.mkdtemp(dir=T)
    if pre:
        pre(h)
    open(f'{h}/s.bees', 'w').write(expand(code).replace('@H', h))
    env = envOf(h)
    try:
        r = subprocess.run([binary, '--run', f'{h}/s.bees'], capture_output=True, timeout=timeout, env=env, cwd=h)
        out = (r.returncode, r.stdout.decode('utf-8', 'replace'))
        err = r.stderr.decode('utf-8', 'replace')
    except subprocess.TimeoutExpired:
        out, err = (None, 'timeout'), ''
    got = {}
    for f in files or []:
        p = f'{h}/{f}'
        got[f] = open(p, 'rb').read() if os.path.exists(p) else None
    shutil.rmtree(h, True)
    return out, got, err


def bad_run(b, eb):
    """Why a run did not end as a program should ('' when it did): a result or a
    script error, no crash (a signal), panic, leak or timeout."""
    if b[0] is None:
        return 'timeout'
    if b[0] not in (0, 1):
        return f'exit {b[0]}'
    if 'panic' in eb or 'panic' in b[1] or 'leak' in eb.lower():
        return 'stderr: ' + eb[-300:]
    return ''


def same(code, what, fails=False, **kw):
    """BeeModel runs the script cleanly: (ok, its output, the files asked for).
    fails: refused with a script error (exit 1, "error:")."""
    b, fb, eb = run(BIN, code, **kw)
    why = bad_run(b, eb)
    if not why and fails and not (b[0] == 1 and 'error:' in b[1]):
        why = 'no error'
    check(not why, what + ('' if not why else f' ({why})\n         {b!r}'))
    if SHOW:
        print('       > ' + b[1][-1500:].replace('\n', '\n       > '))
    return not why, b, fb


def many(cases):
    """(code, what) pairs, a few at a time: each run must end cleanly."""
    with ThreadPoolExecutor(JOBS) as ex:
        res = list(ex.map(lambda c: (c, run(BIN, c[0])), cases))
    nbad = 0
    for (code, what), (b, _, eb) in res:
        why = bad_run(b, eb)
        if why:
            nbad += 1
            check(False, f'{what} ({why})\n         {code[-(1600 if SHOW else 160):]!r}\n         {b!r}')
    return nbad


# ---- the .bee files: read back, the same scene saved again (as tests/bscript.py reads them) ----

def scene(data):
    cs = beefile.chunks(data)
    meshes = [b for t, b in cs if t == b'MESH']
    objs = beefile.chunk(data, b'OBJS')
    n = struct.unpack_from('<I', objs)[0]
    recs = []
    for k in range(n):
        r = objs[4 + k * 84:4 + (k + 1) * 84]
        typ, mi = struct.unpack_from('<I', r, 72)[0], struct.unpack_from('<I', r, 80)[0]
        me = meshes[mi] if typ == 0 and mi < len(meshes) else None
        name = r[:32].split(b'\0')[0]
        recs.append((name.ljust(32, b'\0') + r[32:80], me))
    rest = {}
    for t, b in cs:
        if t in (b'MESH', b'OBJS', b'THMB', b'WSPC', b'VIEW', b'MUVS', b'MVCL') or not b:
            continue
        if t == b'ANIM' and len(b) >= 20:
            b = b[:16] + bytes(4) + b[20:]  # (the key list's capacity, anim.zig Head.capk: room, not the scene)
        rest.setdefault(t, []).append(b)
    return recs, rest


def scene_why(da, db):
    """'' when the two files hold the same scene, else why not."""
    (ra, xa), (rb, xb) = scene(da), scene(db)
    why = []
    if len(ra) != len(rb):
        why.append(f'{len(ra)} / {len(rb)} objects')
    for k, (a, b) in enumerate(zip(ra, rb)):
        if a[0] != b[0]:
            why.append(f'object {k} {a[0][:32].rstrip(bytes(1))!r}')
        elif a[1] != b[1]:
            why.append(f'object {k}: its mesh ({len(a[1] or b"")} / {len(b[1] or b"")} bytes)')
    for t in sorted(set(xa) | set(xb)):
        if xa.get(t) != xb.get(t):
            why.append(f'{t.decode()} chunk')
    return '; '.join(why[:4])


def reads_back(data, what):
    """A saved scene that reads back, and opened and saved again is the same."""
    if data is None:
        check(False, f'{what}: no file saved')
        return False
    try:
        scene(data)
    except Exception as e:  # noqa: BLE001 (any parse failure is the finding)
        check(False, f'{what}: it does not read back ({e})')
        return False
    b, fb, eb = run(BIN, 'op("file.open", "@H/i.bee")\nop("file.save_as", "@H/o.bee")\n', files=['o.bee'], pre=lambda h: open(f'{h}/i.bee', 'wb').write(data))
    if b[0] != 0 or fb['o.bee'] is None:
        check(False, f'{what}: opened and saved again ({b!r} {bad_run(b, eb)})')
        return False
    why = scene_why(data, fb['o.bee'])
    check(not why, f'{what}: read back, opened and saved again the same scene' + ('' if not why else ': ' + why))
    return not why


def same_files(code, what, **kw):
    """The script ends saving @H/o.bee: a clean run, a file that reads back."""
    ok, b, fb = same(code + '\nop("file.save_as", "@H/o.bee")\n', what, files=['o.bee'], **kw)
    return reads_back(fb['o.bee'], what) and ok


# ---- scenes ------------------------------------------------------------------------------------

BODIES = '''
delete("Cube")
add("plane", "Ground", 0, 0, 0)
scale("Ground", 10)
select("Ground")
op("rigid.add", "passive box")
for i in [[0, "box"], [1, "sphere"], [2, "capsule"], [3, "hull"], [4, "box"], [5, "sphere"]] {
 n = "B" + str(i[0])
 add("cube", n, (i[0] % 3) * 0.7 - 0.7, 1 + i[0] * 0.6, (i[0] % 2) * 0.3)
 rotate(n, 0.2 * i[0], 0.3, 0.1 * i[0])
 scale(n, 0.25)
 select(n)
 op("rigid.add", "active " + i[1])
}
add("sphere", "S", 3, 2, 0)
scale("S", 0.3)
select("S")
op("rigid.add", "active sphere mass 4 friction 0.2 bounce 0.7 damping 0.3 group 5")
select()
'''

MECH = '''
param("angle", "0deg")
add("cylinder", "Gear", -4, 0.15, -3)
scale("Gear", 0.8, 0.15, 0.8)
add("cylinder", "Pinion", -2.8, 0.15, -3)
scale("Pinion", 0.4, 0.15, 0.4)
add("cube", "Crank", -4, 0.45, -2.6)
scale("Crank", 0.08, 0.08, 0.5)
op("mech.joint", "revolute Gear world pivot -4 0 -3 axis 0 1 0 value angle")
op("mech.joint", "revolute Pinion world pivot -2.8 0 -3 axis 0 1 0 gear 1 -2")
op("mech.joint", "revolute Crank Gear pivot -4 0 -3 axis 0 1 0 limits -30deg 30deg")
op("mech.joint", "slider Pinion Gear axis 1 0 0 limits 0 0.5")
key("param:angle", 1, 0, "linear")
key("param:angle", 241, 12.566, "linear")
'''

RIG = '''
delete("Cube")
add("sphere", "Body", 0, 1, 0)
scale("Body", 0.3, 1, 0.3)
a = armature("Rig")
op("arm.bone", "Hips Bone 0 1 0 0 1.5 0")
op("arm.bone", "Head Hips 0 1.5 0 0 2 0")
op("arm.bone", "Leg Bone 0 1 0 0.1 0 0")
op("arm.parent", "Body Rig")
'''

GEO_LOGIC = '''
delete("Cube")
add("plane", "Floor", 0, 0, 0)
scale("Floor", 20)
add("cube", "Coin", 3, 0.5, 0)
scale("Coin", 0.2)
add("cube", "Score", 0, 5, 5)
scale("Score", 0.2)
add("cube", "Ball", -3, 0.5, 3)
scale("Ball", 0.5)
select("Ball")
op("rigid.add", "active box")
select("Floor")
op("rigid.add", "passive box")
select()
'''
LOGIC_OPS = [
    ('logic.new', 'CoinLogic'), ('logic.node', 'CoinLogic overlap 0 0 0.2'), ('logic.node', 'CoinLogic destroy'), ('logic.node', 'CoinLogic send'),
    ('logic.name', 'CoinLogic 3 4 picked'), ('tree.link', 'CoinLogic 1 2 1'), ('tree.link', 'CoinLogic 2 3 1'), ('logic.node', 'CoinLogic tick'),
    ('logic.node', 'CoinLogic rotate'), ('tree.node_set', 'CoinLogic 5 2 0 1 0'), ('tree.link', 'CoinLogic 4 5 1'), ('logic.attach', 'CoinLogic Coin'),
    ('logic.new', 'ScoreLogic'), ('logic.node', 'ScoreLogic message'), ('logic.name', 'ScoreLogic 1 4 picked'), ('logic.node', 'ScoreLogic set_variable 0 1'),
    ('tree.link', 'ScoreLogic 1 2 1'), ('tree.link', 'ScoreLogic 1:1 2 2'), ('logic.node', 'ScoreLogic timer 0.5 0'), ('logic.node', 'ScoreLogic set_variable 1'),
    ('tree.node_set', 'ScoreLogic 4 2 7 7 7'), ('tree.link', 'ScoreLogic 3 4 1'), ('logic.node', 'ScoreLogic key 18 0'), ('logic.node', 'ScoreLogic spawn'),
    ('logic.name', 'ScoreLogic 6 4 Coin'), ('tree.node_set', 'ScoreLogic 6 2 3 -5 -2'), ('tree.link', 'ScoreLogic 5 6 1'),
    ('logic.attach', 'ScoreLogic Score'),
    ('logic.new', 'BallLogic'), ('logic.node', 'BallLogic begin'), ('logic.node', 'BallLogic impulse'), ('tree.node_set', 'BallLogic 2 2 0 0 -4'),
    ('tree.link', 'BallLogic 1 2 1'), ('logic.attach', 'BallLogic Ball'),
]
LOGIC = GEO_LOGIC + '\n'.join(f'op("{o}", "{a}")' for o, a in LOGIC_OPS) + '\n'

# every builtin of the five files, (min, max) arguments as the table
SPEC = {
    'rbinfo': (1, 1), 'field': (1, 3), 'force': (3, 4), 'fieldinfo': (1, 1), 'emit': (1, 3), 'particles': (1, 2),
    'shatter': (3, 4), 'height': (3, 3), 'rigid': (2, 2), 'joint': (1, 2), 'collisions': (0, 0), 'clothinfo': (1, 1),
    'cacheinfo': (1, 1), 'landscape': (2, 2), 'shinfo': (1, 1), 'key': (2, 4), 'unkey': (2, 2), 'keyed': (2, 2),
    'armature': (0, 1), 'evpos': (3, 3), 'bones': (1, 1), 'shapes': (1, 1), 'bonepos': (3, 3), 'wpaint': (7, 7),
    'weight': (3, 3), 'playstep': (1, 5), 'playlook': (2, 2), 'playinfo': (1, 1), 'playkey': (2, 2), 'logic': (1, 1),
    'logicvar': (2, 3), 'livelink': (1, 1), 'vcinfo': (1, 1), 'vctext': (1, 2), 'costat': (1, 1), 'cohash': (0, 0),
}
# what each argument should be: o an object, n a number, s a text, p a path, a an axis (text or number)
KINDS = {
    'rbinfo': 'n', 'field': 'sss', 'force': 'nnna', 'fieldinfo': 'n', 'emit': 'oss', 'particles': 'nn', 'shatter': 'osns',
    'height': 'onn', 'rigid': 'os', 'joint': 'nn', 'collisions': '', 'clothinfo': 'n', 'cacheinfo': 'n', 'landscape': 'on',
    'shinfo': 'n', 'key': 'pnns', 'unkey': 'pn', 'keyed': 'pn', 'armature': 's', 'evpos': 'ons', 'bones': 'o', 'shapes': 'o',
    'bonepos': 'oss', 'wpaint': 'onnnnnn', 'weight': 'onn', 'playstep': 'nnnnn', 'playlook': 'nn', 'playinfo': 'n',
    'playkey': 'nn', 'logic': 'n', 'logicvar': 'onn', 'livelink': 'n', 'vcinfo': 'n', 'vctext': 'nn', 'costat': 'n', 'cohash': '',
}

# numbers that are times (ms), not the same run to run: (argument, the k's)
TIMING = {'rbinfo': (0, {4, 8, 9, 10, 11, 12, 13, 20, 21}), 'clothinfo': (0, {4}), 'particles': (0, {2, 3, 17, 23, 32}), 'landscape': (1, {6}),
          'shinfo': (0, {6, 11, 12, 13, 14, 15, 16, 17})}


def pass_args(name):
    """Plausible arguments for a call, as texts of BeeScript."""
    out = []
    for k in KINDS[name]:
        out.append({'o': '"C"', 'n': '1', 's': '"x"', 'p': '"C:x"', 'a': '"y"'}[k])
    return out


# ---- sections ------------------------------------------------------------------------------------

def s_net():
    print('-- the phase 13 builtins: no live link, no repository, no session --')
    calls = 'print(livelink(0), livelink(1), livelink(2), livelink(7), livelink(8), livelink(-1), livelink(1e30), livelink(sqrt(-1)))\n' \
            'print(vcinfo(0), vcinfo(1), vcinfo(2), vcinfo(5), vcinfo(8), vcinfo(9), vcinfo(10), vcinfo(-3), vcinfo(1e30))\n' \
            'print(vctext(0), vctext(1), vctext(1, 0), vctext(2, 3), vctext(3), vctext(4), vctext(-1), vctext(0, -1), vctext(sqrt(-1)))\n' \
            'print(costat(0), costat(1), costat(2), costat(3), costat(4), costat(6), costat(7), costat(8), costat(9), costat(10), costat(-1))\n' \
            'print(cohash(), len(cohash()))\n'
    # (vctext(0): nil with no file, "main" with one; cohash(): the FNV-1a offset basis, an empty document's)
    empty = 'cbf29ce484222325'

    def lines(b):
        return b[1].splitlines()
    ok, b, _ = same(calls, 'no file open', fails=False)
    check(ok and len(lines(b)) == 5 and lines(b)[2].split()[0] == 'nil' and lines(b)[4].split() == [empty, '16'], f'  no file open: vctext(0) nil, cohash() the empty document\'s ({lines(b)[2:]})')
    ok, b, _ = same('add("cube", "X")\nop("file.save_as", "@H/a.bee")\n' + calls, 'a file saved')
    check(ok and len(lines(b)) == 5 and lines(b)[2].split()[0] == 'main', f'  a file saved: vctext(0) is "main" ({lines(b)[2:3]})')
    ok, b, _ = same('op("file.save_as", "@H/a.bee")\nop("file.new")\n' + calls, 'saved, then file.new')
    check(ok and len(lines(b)) == 5 and lines(b)[2].split()[0] == 'nil', f'  saved, then file.new: no file again, vctext(0) nil ({lines(b)[2:3]})')
    ok, b, _ = same('op("file.save_as", "@H/a.bee")\nop("file.open", "@H/a.bee")\n' + calls + 'material("M")\nadd("sphere")\nprint(cohash())\n', 'a file opened, objects and a material made')
    check(ok and lines(b)[-1:] == [empty], f'  cohash still the empty document\'s ({lines(b)[-1:]})')
    for c in ['livelink("0")', 'vcinfo(nil)', 'vctext("a")', 'vctext(0, "b")', 'costat("x")', 'cohash(1)', 'livelink()', 'vctext(1, 2, 3)']:
        same(f'print(1)\nprint({c})\n', f'{c}: refused with an error', fails=True)


def s_phys():
    print('-- physics: bodies, fields, particles, shatter, mechanisms, cloth, the cache --')
    same(BODIES + 'print(rbinfo(0), rbinfo(7), rbinfo(25), cacheinfo(0), cacheinfo(6))\n'
         'for b in ["Ground", "B0", "B1", "B2", "B3", "S", "Camera"] { print(b, rigid(b, "type"), rigid(b, "shape"), rigid(b, "mass"), rigid(b, "friction"), rigid(b, "bounce"), rigid(b, "damping"), rigid(b, "group"))\n print(rigid(b, "x0"), rigid(b, "nope"), rigid(b, "")) }\n'
         'for f in [2, 10, 30, 60] { frame(f)\n print(f, rbinfo(0), rbinfo(1), rbinfo(2), rbinfo(3), rbinfo(5), rbinfo(6), rbinfo(7), rbinfo(15), rbinfo(16), rbinfo(17))\n print(rbinfo(19), rbinfo(25), rbinfo(1000), rbinfo(1003), rbinfo(1004), rbinfo(-1), rbinfo(99999))\n'
         ' print(rigid("B0", "x0"), rigid("B0", "y0"), rigid("B0", "z0"), get("B0", "y"), get("S", "x"), cacheinfo(0), cacheinfo(2) > 0, cacheinfo(3), cacheinfo(5), cacheinfo(7), cacheinfo(9), cacheinfo(-1), cacheinfo(11)) }\n'
         'frame(30)\nprint(rbinfo(25), rbinfo(16), rbinfo(0))\nop("sim.bake")\nprint(cacheinfo(0), cacheinfo(3), cacheinfo(5))\nframe(12)\nprint(rbinfo(25), rbinfo(16), get("B3", "y"))\n',
         'six bodies of every shape on a passive ground: rigid() and rbinfo / cacheinfo at four frames, played back, baked', timeout=600)
    same('print(fieldinfo(0), force(0, 0, 0), force(0, 1, 0, "y"), force(0, 1, 0, 1))\n'
         'print(field("attractor"), field("zone", "Z"), field("wind", "W", "strength 3 gust 0"), field("vortex", "V", "strength 5 radius 2 falloff smooth"))\n'
         'print(field("turbulence", "T", "strength 2 scale 0.5 seed 7"), field("drag", "D", "strength 0.5"), field("planet"), field("blackhole", "H"), field("tornado"), field("breeze", "B", "gust 0.1"))\n'
         'print(field("Attractor"), field(""), field("wind ", "x"), field("vortex", "V"), field("wind", "", "strength nope"))\n'
         'print(fieldinfo(0), fieldinfo(1), fieldinfo(2), fieldinfo(3), fieldinfo(4), fieldinfo(-1), count())\n'
         'for p in [[0, 0, 0], [1, 2, 3], [-4, 0.5, 2], [10, -3, 7], [0.1, 0.1, 0.1], [1e6, 0, 0]] {\n'
         ' print(force(p[0], p[1], p[2]), force(p[0], p[1], p[2], "x"), force(p[0], p[1], p[2], "y"), force(p[0], p[1], p[2], "z"), force(p[0], p[1], p[2], 2), force(p[0], p[1], p[2], 3), force(p[0], p[1], p[2], -1), force(p[0], p[1], p[2], ""), force(p[0], p[1], p[2], "zz"), force(p[0], p[1], p[2], "w")) }\n'
         'print(force(sqrt(-1), 0, 0), force(1e300, 0, 0), force(0, 0, 0, sqrt(-1)))\n'
         'for k in 0..count() { print(name(k), objtype(name(k)), get(name(k), "x")) }\n',
         'every field type and preset, named and set, words it cannot use; force() at six points, every axis; fieldinfo')
    same_files('field("wind", "W", "strength 3")\nfield("planet", "P")\nfield("vortex", "V", "radius 2 lift 1")\n', 'force fields: the file')
    same('add("plane", "E", 0, 3, 0)\n'
         'print(emit("E"), emit("E", "rain"), emit("E", "snow", "rate 50 life 2"), emit("E", "sparks"), emit("E", "rate 30 speed 4"), emit("E", "confetti", "rate 5"), emit("E", "fountain"), emit("E", "nonsense words"))\n'
         'print(particles(0), particles(1), particles(4), particles(5), particles(20, 0), particles(22, 1), particles(-1), particles(99))\n'
         'for f in [2, 6, 12] { frame(f)\n print(f, particles(0), particles(1), particles(5), particles(19), particles(6, 0), particles(7, 0), particles(8, 0), particles(12, 3), particles(13, 3), particles(15, 0), particles(22, 2), particles(6, 99999)) }\n',
         'emit(): presets, settings, words it cannot use; particles() as they fall over frames', timeout=600)
    same('for k in 0..70 { r = emit("Cube", "rate 1")\n if r == nil or k > 62 { print(k, r) } }\nprint(particles(1))\n', '64 systems at most: then nil')
    same_files('add("plane", "E", 0, 3, 0)\nemit("E", "rain")\nemit("E", "rate 20 life 3", "speed 2")\n', 'particle systems: the file')
    same('print(shinfo(0), shinfo(6) >= 0)\n'
         'print(shatter("Cube", "shards", 12), shinfo(0), shinfo(1), shinfo(2), shinfo(3), shinfo(5), shinfo(7), shinfo(8), shinfo(22), shinfo(23), shinfo(24), shinfo(-1), count())\n'
         'print(shinfo(4) * 1000000000, shinfo(9) * 1000000000000000, shinfo(10) * 1000000000)\n'
         'add("cube", "K", 4, 0, 0)\nprint(shatter("K", "bricks", 6, "seed 3 nobodies"), shinfo(0), shinfo(1), shinfo(21), shinfo(22), count(), active())\n'
         'add("sphere", "Q", -4, 0, 0)\nprint(shatter("Q", "balls", 5, "seed 2"), shinfo(0), shinfo(18), count())\n'
         'add("cube", "N", 0, 0, 6)\nprint(shatter("N", "nope", 4), shatter("N", "shards", -3), shatter("N", "shards", 0), shinfo(0), count())\n'
         'print(shatter("Camera", "shards", 3), shinfo(0), count())\n',
         'shatter(): shards, bricks, balls, options, a bad pattern and counts, a camera; shinfo', timeout=600)
    long = 'x' * 200
    same(f'print(shatter("Cube", "shards", 8, "seed 4 {long}"), shinfo(0), count())\n', 'shatter(): a 200-character option (126 kept, as fmt_buf)', timeout=600)
    opts = 'seed 1 ' * 16 + 'seed 9'  # (the last seed past the 126th character)
    same(f'print(shatter("Cube", "shards", 8, "{opts}"), shinfo(0), shinfo(4), shinfo(2))\nadd("cube", "K")\nprint(shatter("K", "shards", 8, "seed 9"), shinfo(4))\n', 'shatter(): words past the 126th character not seen', timeout=600)
    same_files('print(shatter("Cube", "shards", 7, "seed 5"))\n', 'shatter: the file', timeout=600)
    same(MECH + 'print(joint(1), joint(2), joint(3), joint(4), joint(5), joint(0), joint(-1), collisions())\n'
         'for f in [1, 20, 61, 120, 200] { frame(f)\n print(f, joint(1), joint(2), joint(3), joint(3, 1), joint(4), joint(4, 0), joint(1, "x"), collisions(), get("Crank", "x")) }\n'
         'print(joint(1e30), joint(sqrt(-1)), joint(2.9))\n',
         'a mechanism: joint() and its limits at five frames, collisions()')
    same('print(clothinfo(0), clothinfo(1), clothinfo(6))\n'
         'add("cube", "Table", 0, 0.5, 0)\nscale("Table", 0.8, 0.5, 0.5)\nadd("grid", "Cloth", 0, 1.4, 0)\nscale("Cloth", 1.4)\n'
         'select("Cloth")\nop("cloth.add", "cloth thickness 0.015")\nselect("Table")\nop("cloth.add", "collider")\nselect()\n'
         'for f in [1, 2, 8, 20] { frame(f)\n print(f, clothinfo(0), clothinfo(1), clothinfo(2), clothinfo(3), clothinfo(5), clothinfo(6), clothinfo(7), clothinfo(-1), cacheinfo(1), cacheinfo(4)) }\n',
         'cloth over a table: clothinfo and cacheinfo at four frames', timeout=600)


def s_land():
    print('-- landscapes: landscape(), height() --')
    same('print(landscape("Cube", 0), height("Cube", 0, 0))\n'
         'op("landscape.add", "hills res 65 size 30")\nl = active()\nprint(l)\n'
         'for k in [0, 1, 2, 3, 4, 5, 7, 8, 9, -1, 1e30] { print(k, landscape(l, k)) }\n'
         'for p in [[0, 0], [3, -4], [14.9, 14.9], [15.1, 0], [-15, -15], [100, 0], [0.5, 0.25]] { print(height(l, p[0], p[1])) }\n'
         'move(l, 2, 1, 3)\nscale(l, 2, 0.5, 2)\nprint(height(l, 0, 0), height(l, 31, 0), height(l, 33, 3), height(l, -27, 3))\n'
         'op("landscape.layer", "add terrace")\nprint(landscape(l, 2), landscape(l, 8), height(l, 1, 1))\n'
         'print(height(l, sqrt(-1), 0), height(l, 1e30, 0))\n',
         'a landscape: every k, heights over it and off it, moved and scaled, a layer more')
    same('op("landscape.add", "mountains res 33 size 10")\nop("landscape.add_island")\nfor k in 0..count() { n = name(k)\n print(n, landscape(n, 0), landscape(n, 1), height(n, 0, 0)) }\n',
         'mountains and an island (and its water): landscape() of each object')


def s_anim():
    print('-- keys: key, unkey, keyed --')
    same('add("cube", "C", 1, 2, 3)\n'
         'print(key("C:x", 1), key("C:x", 10, 5), key("C:x", 20, 7, "constant"), key("C:x", 30, -1, "linear"), key("C:x", 40, 2, "bezier"), key("C:x", 10, 6))\n'
         'for f in [0, 1, 5, 10, 15, 20, 25, 30, 35, 40, 50] { print(f, keyed("C:x", f), keyed("C:y", f)) }\n'
         'print(key("C:rz", 5), key("C:sx", 5, 2), key("C:y", 1, sqrt(-1)), keyed("C:y", 1), key("C:z", 1e30, 1), key("C:z", -5, 1e30), keyed("C:z", 0))\n'
         'print(unkey("C:x", 10), unkey("C:x", 10), unkey("C:x", 10.0001), unkey("C:q", 1), unkey("Nope:x", 1), unkey("", 1), keyed("C:x", 10))\n'
         'print(keyed("Nope:x", 1), keyed("C:nope", 1), keyed("", 1), keyed("C:x", sqrt(-1)), keyed("C:x", 1e30))\n'
         'material("M")\nprint(key("material:M:roughness", 1, 0.2), key("material:M:roughness", 9, 0.9, "linear"), keyed("material:M:roughness", 5))\n'
         'param("w", "2cm")\nprint(key("param:w", 1, 0), key("param:w", 11, 1, "linear"), keyed("param:w", 6))\n'
         'modifier("C", "subsurf")\nprint(key("modifier:C:0:levels", 1, 1), key("modifier:C:0:levels", 5, 3), keyed("modifier:C:0:levels", 3))\n'
         'frame(15)\nprint(get("C", "x"), prop("C:x"))\n',
         'keys on objects, materials, parameters and modifiers: every interpolation, NaN, huge frames; unkey and keyed')
    for c in ['key("Nope:x", 1)', 'key("C:q", 1, 2)', 'key("C:x", 1, 2, "smooth")', 'key("C:x", 1, 2, "")', 'key("C:x", 1, 2, 3)',
              'key("C:x", "1")', 'key(1, 1)', 'key("", 1)', 'unkey("C:x", nil)', 'keyed(nil, 1)', 'key("C:x")', 'key("C:x", 1, 2, "linear", 5)',
              'key("Nope:x", 1, 2, "smooth")', 'key("Nope:x", 1, 2, 3)']:
        same(f'add("cube", "C")\nprint(1)\nprint({c})\nprint(2)\n', f'{c}: refused with an error', fails=True)
    ok, b, _ = same('add("cube", "C")\nkey("C:x", 10, 5)\nprint(unkey("C:x", 10), unkey("C:x", 10))\n', 'unkey: a key taken off, then none there')
    check(b[1].split() == ['1', '0'], f'  unkey: 1 when a key went, 0 when there was none ({b[1].strip()!r})')
    same_files('add("cube", "C")\nkey("C:x", 1, 0, "linear")\nkey("C:x", 24, 4)\nkey("C:ry", 12, 1.5, "constant")\nunkey("C:x", 24)\nkey("C:x", 30, 3)\n', 'keys: the file')


def s_rig():
    print('-- rigging: armatures, bones, weights, shape keys --')
    same('print(armature(), armature(), armature("Rig"), armature("Rig"), armature(""), armature("abcdefghijklmnopqrstuvwxyz0123456789"), active(), count())\n'
         'for k in 0..count() { n = name(k)\n print(n, objtype(n), bones(n), issel(n), get(n, "x"), bonepos(n, "Bone", "y"), bonepos(n, "Bone", "x"), bonepos(n, "Bone", "z"), bonepos(n, "Bone", "w"), bonepos(n, "Bone", ""), bonepos(n, "Nope", "x")) }\n'
         'print(bones("Cube"), bonepos("Cube", 1, 2), bonepos("Camera", "Bone", "y"), shapes("Cube"), shapes("Rig"))\n',
         'armature(): names (unique, cut), selected and active; bones, bonepos of each')
    same(RIG + 'print(bones("Rig"), verts("Body"), everts("Body"))\n'
         'print(weight("Body", 0, 0), weight("Body", 10, 1), weight("Body", -1, 0), weight("Body", 1e9, 0), weight("Body", 0, -1), weight("Body", 0, 255))\n'
         'op("arm.auto_weights")\n'
         'n = verts("Body")\nfor i in 0..n { if i % 7 == 0 { print(i, weight("Body", i, 0), weight("Body", i, 1), weight("Body", i, 2), weight("Body", i, 3), evpos("Body", i, "x"), evpos("Body", i, "y"), evpos("Body", i, "z")) } }\n'
         'select("Rig")\nop("arm.pose", "Hips rot 0 0 40")\n'
         'for b in ["Bone", "Hips", "Head", "Leg"] { print(b, bonepos("Rig", b, "x"), bonepos("Rig", b, "y"), bonepos("Rig", b, "z")) }\n'
         'for i in 0..n { if i % 9 == 0 { print(i, evpos("Body", i, "x"), evpos("Body", i, "y"), evpos("Body", i, "z"), vpos("Body", i, "x")) } }\n'
         'print(evpos("Body", n, "x"), evpos("Body", -1, "x"), evpos("Body", 0, "q"), evpos("Body", 0, ""), evpos("Body", sqrt(-1), "x"))\n'
         'print(wpaint("Body", 0, 1.8, 0, 0.5, 1, 0.75), wpaint("Body", 0, 1.8, 0, 0.5, 3, 1), wpaint("Body", 0, 1.8, 0, 0.5, -1, 1), wpaint("Body", 0, 1.8, 0, 0.5, 4, 1), wpaint("Body", 0, 1.8, 0, 0.5, 5, 1), wpaint("Body", 0, 0.2, 0, 0.6, 2, 0.3))\n'
         'for i in 0..n { if i % 5 == 0 { print(i, weight("Body", i, 0), weight("Body", i, 1), weight("Body", i, 2)) } }\n'
         'add("cube", "Plain")\nprint(wpaint("Rig", 0, 0, 0, 1, 0, 1), wpaint("Plain", 0, 0, 0, 1, 0, 1), wpaint("Camera", 0, 0, 0, 1, 0, 1), wpaint("Body", 0, 0, 0, 0, 1, 1), wpaint("Body", 0, 1, 0, 9, 1, sqrt(-1)))\n'
         'print(weight("Body", 3, 1), weight("Body", 30, 1))\n',
         'a skinned body: weights (automatic, then painted), the posed bones and skin, wpaint\'s refusals', timeout=600)
    same_files(RIG + 'op("arm.auto_weights")\nwpaint("Body", 0, 1.8, 0, 0.5, 1, 0.75)\nwpaint("Body", 0, 0.2, 0, 0.6, 2, 0.3)\n',
               'armature, automatic weights and painted ones: the file', timeout=600)
    same('add("cube", "C")\nselect("C")\nprint(shapes("C"))\nop("shape.add")\nprint(shapes("C"))\nop("shape.add", "Smile")\nop("shape.add")\nprint(shapes("C"), shapes("Camera"), shapes("Cube"))\n',
         'shapes(): none, the Basis, three keys')
    for c in ['bones(1)', 'bones("Nope")', 'shapes(nil)', 'bonepos("Nope", "Bone", "x")', 'evpos("Camera", 0, "x")', 'evpos("Nope", 0, "x")',
              'evpos("Cube", "0", "x")', 'evpos("Cube", 0, 1)', 'weight("Camera", 0, 0)', 'weight("Cube", "a", 0)', 'weight("Cube", 0, nil)',
              'wpaint("Nope", 0, 0, 0, 1, 0, 1)', 'wpaint("Cube", 0, 0, 0, 1, 0, "a")', 'wpaint("Cube", "x", 0, 0, 1, 0, 1)', 'wpaint(1, 0, 0, 0, 1, nil, 1)',
              'armature(1)', 'armature(nil)', 'bonepos("Rig", 1, "x")', 'bonepos("Rig", "Bone", 1)', 'evpos("Cube", 99, 1)']:
        same(f'armature("Rig")\nprint(1)\nprint({c})\nprint(2)\n', f'{c}: an answer or an error')


def s_play():
    print('-- play mode and logic graphs --')
    same('print(playinfo(0), playinfo(8), playinfo(9), playinfo(10), logic(0), logic(1), logic(8), logicvar("Cube", 0))\n'
         'view(30, 20, 5, 0, 0, 0)\nprint(playinfo(9), playinfo(10))\nplaylook(50, 200)\nprint(playinfo(9), playinfo(10), viewinfo(0), viewinfo(1))\n'
         'playlook(-10, -200)\nprint(playinfo(10))\nplaylook(sqrt(-1), sqrt(-1))\nprint(playinfo(9), playinfo(10))\nplaylook(1e30, 0)\nprint(playinfo(9))\n'
         'playstep(1, 1, 1, 1, 1)\nplaykey(17, 1)\nprint(playinfo(0), playinfo(1), playinfo(11), playinfo(14))\n'
         'op("play.mode", "fly")\nprint(playinfo(8))\n',
         'not playing: the camera\'s yaw and pitch, looks clamped, steps and keys do nothing')
    same('add("plane", "G")\nscale("G", 20)\nop("play.start")\nprint(playinfo(0), playinfo(8), playinfo(4))\n'
         'playlook(10, -30)\nplaystep(0.5, 1, 0, 0, 1)\n'
         'print(playinfo(1), playinfo(2), playinfo(3), playinfo(4), playinfo(5), playinfo(7), playinfo(9), playinfo(10), playinfo(11), playinfo(14), viewinfo(0), viewinfo(2))\n'
         'playstep(0.25, sqrt(-1), sqrt(-1), sqrt(-1), sqrt(-1))\nprint(playinfo(1), playinfo(2), playinfo(3), playinfo(5), playinfo(6), playinfo(7))\n'
         'playstep(0.3, -1, 1, 0, 0.5)\nprint(playinfo(1), playinfo(3), playinfo(14))\n'
         'playstep(0.2, 0, 0, 1)\nprint(playinfo(2), playinfo(4), playinfo(6))\nplaystep(1)\nprint(playinfo(2), playinfo(4))\n'
         'playkey(33, 1)\nplaystep(0.1)\nprint(playinfo(8))\nplaykey(33, 0)\nplaystep(0.4, 0, 0, 1)\nprint(playinfo(2), playinfo(8))\n'
         'playstep(-1)\nplaystep(0)\nprint(playinfo(14), playinfo(12), playinfo(13), playinfo(15), playinfo(16), playinfo(17), playinfo(18), playinfo(19), playinfo(-1))\n'
         'playkey(1, 1)\nprint(playinfo(0))\nplaykey(32, 1)\nprint(playinfo(0), count())\n',
         'playing: walk, run, jump, keys held as NaN (back, left, down), fly by F, Esc then D')
    same('add("plane", "G")\nscale("G", 20)\nop("play.start", "fly 0 3 0")\nplaystep(0.5, 0, 0, 1)\nprint(playinfo(2), playinfo(8))\nplaykey(1, 1)\nplaykey(37, 1)\nprint(playinfo(0))\n',
         'fly from a point; Esc then K keeps')
    same(LOGIC + 'print(logic(0), logic(1), logicvar("Score", 0))\nop("play.start", "walk -3 1.6 6")\n'
         'print(logic(0), logic(1), logic(8), logicvar("Score", 0), logicvar("Coin", 0), logicvar("Floor", 0))\n'
         'for k in 0..8 { playstep(0.25)\n print(k, logic(2), logic(3), logic(4), logic(5), logic(6), logic(7), logic(8), logic(9), logic(-1))\n print(logicvar("Score", 0), logicvar("Score", 1), logicvar("Score", 1, 1), logicvar("Score", 1, 2), logicvar("Score", 1, 3), logicvar("Score", 8), logicvar("Score", -1), count()) }\n'
         'playkey(18, 0.5)\nplaystep(0.1)\nprint(logic(3), logic(5), count())\n'
         'playkey(18, 1)\nplaystep(0.1)\nplaykey(18, 0)\nplaystep(0.1)\nprint(logic(3), logic(5), count(), get("Ball", "z"))\n'
         'playkey(1, 1)\nplaykey(32, 1)\nprint(logic(0), logicvar("Score", 0), count())\n',
         'logic graphs played: lg_stat and the variables step by step, a key (E) spawns, stopped', timeout=600)
    for c in ['playstep("a")', 'playstep(1, "a")', 'playstep(nil, 1, 1, 1, "x")', 'playlook(1)', 'playlook("a", 1)', 'playinfo(nil)', 'playkey(1, "a")',
              'playkey("a", nil)', 'logic("x")', 'logicvar("Nope", 0)', 'logicvar("Cube", "a")', 'logicvar("Nope", 0, "a")', 'logicvar(1, 0)', 'playstep()', 'playstep(1, 2, 3, 4, 5, 6)']:
        same(f'print(1)\nprint({c})\nprint(2)\n', f'{c}: an answer or an error')


def s_args():
    print('-- every builtin: each argument count, wrong types, bad names, edge values --')
    cases = []
    setup = 'add("cube", "C")\narmature("R")\n'
    vals = ['nil', '"x"', '""', '0', '-1', '1e30', '-1e30', 'sqrt(-1)', '2.7', '"Nope"', '"C"', '"R"', '"Camera"', '"C:x"', '255', '1000', '"y"']
    for name, (lo, hi) in SPEC.items():
        good = pass_args(name)
        for n in range(max(0, lo - 1), hi + 2):
            a = (good + ['1'] * 8)[:n]
            cases.append((f'{setup}print(1)\nprint({name}({", ".join(a)}))\n', f'{name} with {n} arguments'))
        for k in range(len(KINDS[name])):
            for v in vals:
                a = good[:]
                a[k] = v
                if name in ('playstep',) and k == 0 and v in ('1e30', '-1e30'):
                    continue  # (1e30 seconds of play: it would play on for ever)
                cases.append((f'{setup}print(1)\nprint({name}({", ".join(a[:max(lo, k + 1)])}))\n', f'{name} argument {k + 1} = {v}'))
    nbad = many(cases)
    check(nbad == 0, f'{len(cases) - nbad} of {len(cases)} calls: answered cleanly (a result or an error)')


def s_random():
    print(f'-- random calls ({RUNS} scripts, seed {SEED}) --')
    rnd = random.Random(SEED)
    names = list(SPEC)
    vals = ['nil', '"x"', '""', '"C"', '"R"', '"Body"', '"Camera"', '"Nope"', '"C:x"', '"C:ry"', '"bone:R:Bone:rz"', '"y"', '"z"', '"shards"', '"bricks"',
            '"rain"', '"wind"', '"attractor"', '"type"', '"mass"', '"Bone"', '"linear"', '"constant"', 'sqrt(-1)', '1e30', '-1e30', '0.5', '-0.5', '2.5']
    cases = []
    for r in range(RUNS):
        lines = ['add("cube", "C")', 'armature("R")', 'add("plane", "Body", 0, 1, 0)', 'op("rigid.add", "active box")', 'frame(2)']
        for _ in range(rnd.randrange(4, 14)):
            nm = rnd.choice(names)
            if nm in ('playstep',):
                continue
            lo, hi = SPEC[nm]
            n = rnd.randint(lo, hi)
            args = []
            for k in range(n):
                kind = KINDS[nm][k] if k < len(KINDS[nm]) else 'n'
                if rnd.random() < 0.7:
                    args.append({'o': rnd.choice(['"C"', '"R"', '"Body"', '"Camera"']), 'n': str(rnd.choice([0, 1, 2, 3, 5, 7, 8, 16, 25, -1, 1000, 1003, 22])),
                                 's': rnd.choice(['"x"', '"y"', '"shards"', '"rain"', '"wind"', '"Bone"', '"mass"', '"linear"', '"seed 2"']),
                                 'p': rnd.choice(['"C:x"', '"C:sy"', '"Body:z"', '"bone:R:Bone:rx"', '"R:x"']), 'a': rnd.choice(['"x"', '1', '"q"'])}[kind])
                else:
                    args.append(rnd.choice(vals))
            tk = TIMING.get(nm)
            if tk and len(args) > tk[0] and args[tk[0]].lstrip('-').isdigit() and int(args[tk[0]]) in tk[1]:
                continue  # (a time in ms: not the same twice)
            lines.append(f'print("{nm}", {nm}({", ".join(args)}))')
        lines.append('print(count(), active(), frame())')
        if nm != 'shatter' and rnd.random() < 0.5:
            lines.append('frame(4)\nprint(rbinfo(0), particles(0), get("C", "x"))')
        cases.append(('\n'.join(lines) + '\n', f'random script {r}'))
    nbad = many(cases)
    check(nbad == 0, f'{len(cases) - nbad} of {len(cases)} random scripts: each ends cleanly')


def s_files():
    print('-- undo after a run; damaged files read back --')
    # one undo step: the run (a failed one too): the script run as script.run
    # through --op, undone and redone; what it made is what --run of the same
    # script saves.
    for body, what in [(RIG + 'op("arm.auto_weights")\nwpaint("Body", 0, 1.8, 0, 0.5, 1, 0.75)\n', 'a rigging script'),
                       ('add("cube", "C")\nkey("C:x", 1, 0)\nkey("C:x", 9, 4)\nfield("wind", "W")\nemit("C", "rain")\narmature("A")\n', 'keys, a field, particles, an armature'),
                       ('add("cube", "C")\nshatter("C", "shards", 6, "seed 2")\n', 'a shatter'),
                       ('field("wind", "W")\nkey("W:x", 1, 3)\nprint(key("Nope:x", 1))\n', 'a script that fails part way')]:
        h = tempfile.mkdtemp(dir=T)
        open(f'{h}/inner.bees', 'w').write(body)
        (a, fa, _) = run(BIN, body + 'op("file.save_as", "@H/after.bee")\n', files=['after.bee'], timeout=600)
        env = envOf(h)
        args = [BIN, '--shot', f'{h}/u.ppm', '--op', f'file.save_as {h}/before.bee', '--op', f'script.run {h}/inner.bees', '--op', f'file.save_as {h}/ran.bee',
                '--op', 'edit.undo', '--op', f'file.save_as {h}/undone.bee', '--op', 'edit.redo', '--op', f'file.save_as {h}/redone.bee']
        r = subprocess.run(args, capture_output=True, timeout=600, env=env, cwd=h)
        rd = {k: (open(f'{h}/{k}.bee', 'rb').read() if os.path.exists(f'{h}/{k}.bee') else None) for k in ('before', 'ran', 'undone', 'redone')}
        if 'panic' in r.stderr.decode(errors='replace'):
            check(False, f'{what}: it panicked')
        if 'fails' not in what:
            why = scene_why(fa['after.bee'], rd['ran']) if fa['after.bee'] and rd['ran'] else 'a file is missing'
            check(a[0] == 0 and not why, f'{what}: script.run makes what --run makes' + ('' if not why else ': ' + why))
        else:
            check(a[0] == 1 and a[1].startswith('error: line 3: key: no such property'), f'{what}: --run stops at line 3 ({a[1][:60]!r})')
        if rd['undone'] and rd['before'] and rd['redone'] and rd['ran']:
            def nouid(d):  # (the next uid: undo does not take it back, as uid_next)
                r, x = scene(d)
                x.pop(b'UIDS', None)
                return r, x
            check(nouid(rd['undone']) == nouid(rd['before']), f'{what}: one undo step takes it all back')
            check(scene(rd['redone']) == scene(rd['ran']), f'{what}: redo brings it all again')
        else:
            check(False, f'{what}: the files ({[k for k in rd if rd[k] is None]} missing)')
        shutil.rmtree(h, True)
    # damaged files: the builtins over what each reads
    (a, fa, _) = run(BIN, RIG + MECH + 'op("arm.auto_weights")\nfield("wind")\nemit("Body", "rain")\nkey("Body:x", 3, 1)\nop("file.save_as", "@H/d.bee")\n', files=['d.bee'], timeout=600)
    src = fa['d.bee']
    if not src:
        check(False, 'the damaged-file source was not made')
        return
    rnd = random.Random(SEED + 1)
    cs = beefile.chunks(src)
    cases = []
    probe = ('print(bones("Rig"), bonepos("Rig", "Hips", "y"), weight("Body", 3, 1), evpos("Body", 2, "y"), joint(1), joint(3, 1), joint(9), collisions(), '
             'fieldinfo(0), force(1, 1, 1), particles(1), keyed("Body:x", 3), rigid("Body", "type"), shapes("Body"))\nframe(5)\nprint(joint(1), particles(0), keyed("Body:x", 3))\n')
    for k in range(min(RUNS, 40)):
        d = bytearray(src)
        # a chunk's body hit: truncated, or bytes made garbage
        off, tag = 8, None
        pos = []
        p = 8
        while p + 8 <= len(src):
            t, n = src[p:p + 4], struct.unpack_from('<I', src, p + 4)[0]
            pos.append((p, t, n))
            p += 8 + n
        if not pos:
            break
        # (the chunks these builtins read; OBJS damage is the loader's: see the report)
        p, tag, n = rnd.choice([x for x in pos if x[1] in (b'ANIM', b'ARMT', b'MWGT', b'MODS', b'PSYS', b'FLDS')] or pos)
        if rnd.random() < 0.4:
            d = d[:p + 8 + rnd.randrange(max(1, n))]
        else:
            for _ in range(rnd.randrange(1, 12)):
                q = p + 8 + rnd.randrange(max(1, n))
                if q < len(d):
                    d[q] = rnd.randrange(256)
        fn = f'{T}/dmg{k}.bee'
        open(fn, 'wb').write(bytes(d))
        cases.append((f'op("file.open", "{fn}")\n' + probe, f'damaged file {k} ({tag.decode(errors="replace")})'))
    del off, cs
    nbad = many(cases)
    check(nbad == 0, f'{len(cases) - nbad} of {len(cases)} damaged files: opened or refused, the builtins answer cleanly')


def s_garbage():
    print('-- garbage: no panic, no hang --')
    rnd = random.Random(SEED + 2)
    names = list(SPEC)
    toks = ['nil', '"x"', '""', '0', '-1', '1e308', '-1e308', 'sqrt(-1)', '"' + 'A' * 300 + '"', '"C"', '"R"', '"Body"', '"bone:R:Bone:rz"', '1/3', '2^31', '-2147483649', '4294967296']
    bad = 0
    for r in range(RUNS):
        lines = ['add("cube", "C")', 'armature("R")']
        for _ in range(20):
            nm = rnd.choice(names)
            if nm == 'playstep':
                lines.append(f'playstep({rnd.choice(["0.01", "-1", "sqrt(-1)", "0"])}, {rnd.choice(toks)})')
                continue
            if nm == 'shatter' and rnd.random() < 0.8:
                continue
            lo, hi = SPEC[nm]
            a = [rnd.choice(toks) for _ in range(rnd.randint(lo, hi))]
            lines.append(f'x = {nm}({", ".join(a)})' if rnd.random() < 0.5 else f'{nm}({", ".join(a)})')
        code = '\n'.join(f'{ln}' for ln in lines)
        # each line alone, so an error does not end the run early
        for ln in lines[2:]:
            (b, _, eb) = run(BIN, 'add("cube", "C")\narmature("R")\nop("play.start")\n' + ln + '\n', timeout=60)
            if b[0] is None or b[0] not in (0, 1) or 'panic' in eb or 'leak' in eb.lower():
                bad += 1
                print(f'     {ln!r}: {b!r} {eb[-300:]!r}')
        del code
    check(bad == 0, f'{RUNS} scripts of garbage calls, line by line: no panic, no leak, no hang ({bad} bad)')


def s_leak():
    print('-- memory: console runs that make and drop what these builtins make, again and again --')
    # Objects made and deleted run by run: each undo step keeps what it deleted,
    # so memory grows until the history's 128 steps are full; 150 runs against
    # 300 then (within one run a deleted object's mesh is kept till the step
    # ends). Keys: in one run (run by run each step keeps its animation block).
    made = ('for i in 0..5 { a = armature("A" + i); f = field("wind", "F" + i, "strength 2"); add("plane", "P" + i, i, 0, 0); emit("P" + i, "rain")\n'
            ' x = force(i, 1, 0) + bonepos(a, "Bone", "y") + evpos("P" + i, 0, "x") + weight("P" + i, 0, 0) + rbinfo(0) + particles(0) + shinfo(0)\n'
            ' x = playinfo(1) + logic(0) + costat(0) + len(cohash()) + wpaint("P" + i, 0, 0, 0, 1, 0, 1)\n y = landscape("P" + i, 0) }\n'
            'frame(3)\nframe(1)\nfor i in 0..5 { delete("A" + i, "F" + i, "P" + i) }')
    keys = ('for r in 0..@K {\n for i in 0..20 { key("Cube:x", i, r); key("Cube:y", i, 2, "linear"); x = keyed("Cube:x", i / 2) }\n'
            ' for i in 0..20 { unkey("Cube:x", i); unkey("Cube:y", i) } }')

    def rss(ops):
        h = tempfile.mkdtemp(dir=T)
        a = ['--shot', f'{h}/x.ppm', '--dump-log', f'{h}/log.txt']
        for o in ops:
            a += ['--op', o]
        a += ['--op', 'print("objects", count())']
        p = subprocess.Popen([BIN, *a], env=envOf(h), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        _, st, ru = os.wait4(p.pid, 0)
        err = p.stderr.read().decode(errors='replace')
        log = open(f'{h}/log.txt', errors='replace').read() if os.path.exists(f'{h}/log.txt') else ''
        if 'error' in log or '  objects 3' not in log:  # (each run took all it made away)
            err += ' log: ' + log[-300:]
        shutil.rmtree(h, True)
        return st, ru.ru_maxrss, err
    for what, a, b in [('made and deleted, run by run', [made] * 150, [made] * 300), ('keys made and taken off in one run', [keys.replace('@K', '4')], [keys.replace('@K', '40')])]:
        (s4, r4, e4), (s40, r40, e40) = rss(a), rss(b)
        bad = 'error' in e4 + e40 or 'panic' in e4 + e40 or 'log:' in e4 + e40
        check(not bad and s4 == 0 and s40 == 0 and r40 - r4 < 2048, f'{what}: {len(a)} / {len(b)}: {r4} KiB, {r40} KiB at most: no growth past 2 MiB' + (f' ({(e4 + e40)[-200:]!r})' if bad else ''))

def s_window():
    print('-- the console in the window (the fake compositor, BEE_CPU): these builtins typed, one undo step a run --')
    os.environ.setdefault('BEE_CPU', '8')
    import bscript as W  # (its window: tests/bscript.py PortWin)
    W.CPU = int(os.environ['BEE_CPU'])
    K_ESC = 1
    try:
        p = W.PortWin()
    except Exception as e:
        check(False, f'the window did not start: {e}')
        return
    try:
        steps = [('line', 'a = armature("Rig")'), ('line', 'key("Cube:x", 1, 0); key("Cube:x", 20, 4, "linear"); frame(10)'),
                 ('line', 'field("wind", "W", "strength 3"); emit("Cube", "rain"); print(bones(a), keyed("Cube:x", 10), force(0, 1, 0), vctext(0), cohash())'),
                 ('save', 'w1'), ('esc',), ('undo',), ('save', 'w2'), ('redo',), ('save', 'w3'),
                 ('line', 'print(unkey("Cube:x", 20), playinfo(0), costat(0), rigid("Cube", "type"), key("Nope:x", 1))'), ('save', 'w4'), ('shot', 'console')]
        for st in steps:
            if st[0] == 'line':
                p.line(st[1])
            elif st[0] == 'esc':
                p.key(K_ESC)
            elif st[0] == 'undo':
                p.key(44, 4)
                p.f.pump(0.3)
            elif st[0] == 'redo':
                p.key(44, 5)
                p.f.pump(0.3)
            elif st[0] == 'save':
                p.line(f'file.save_as {T}/{st[1]}.bee')
                p.key(K_ESC)
            elif st[0] == 'shot':
                p.image().save(f'{T}/{st[1]}.png')
        rd = {k: (open(f'{T}/{k}.bee', 'rb').read() if os.path.exists(f'{T}/{k}.bee') else None) for k in ('w1', 'w2', 'w3', 'w4')}
        check(p.f.proc.poll() is None, 'the window still running after the runs, undo, redo and a failing run')
        for k, what in (('w1', 'an armature, keys, a field, particles typed'), ('w2', 'Ctrl+Z: the last run undone, one step'), ('w3', 'Ctrl+Shift+Z: redone')):
            reads_back(rd[k], f'the window: {what}')
        n1 = [x['name'] for x in beefile.objects(rd['w1'])] if rd['w1'] else []
        n2 = [x['name'] for x in beefile.objects(rd['w2'])] if rd['w2'] else []
        check('Rig' in n1 and 'W' in n1 and 'W' not in n2 and 'Rig' in n2, f'the field made, then undone; the armature kept ({n1} / {n2})')
        why = scene_why(rd['w1'], rd['w3']) if rd['w1'] and rd['w3'] else 'a file is missing'
        check(not why, 'Ctrl+Shift+Z: the scene as before the undo' + ('' if not why else ': ' + why))
        from PIL import Image
        A = Image.open(f'{T}/console.png')
        check(A.size[0] > 0 and A.size[1] > 0 and len(set(A.convert('L').getextrema())) > 1, f'the console drawn: {A.size}, not one colour')
        if os.environ.get('BS_KEEP'):
            print(f'     (screenshot: {T}/console.png)')
    finally:
        p.close()
        shutil.rmtree(getattr(W, 'T', ''), True)


PERF = [  # what, setup, the timed part (between two clock()s)
    ('key / keyed / unkey: 3000 keys', 'add("cube", "C")\n', 'for i in 0..1000 { key("C:x", i, i); key("C:y", i, 1, "linear"); key("C:rz", i * 0.5, 2, "constant") }\nfor i in 0..1000 { x = keyed("C:x", i + 0.5) }\nfor i in 0..1000 { unkey("C:y", i) }'),
    ('force(): 20000 samples in 12 fields', 'for k in ["attractor", "wind", "vortex", "turbulence", "drag", "zone"] { field(k)\n field(k) }\n', 'for i in 0..20000 { x = force(i % 17, i % 5, i % 3) }'),
    ('armature(): 200 made', '', 'for i in 0..200 { a = armature("R") }'),
    ('wpaint / weight: 300 dabs on a skinned sphere', RIG + 'op("arm.auto_weights")\n', 'for i in 0..300 { x = wpaint("Body", 0, 1 + (i % 10) * 0.1, 0, 0.4, i % 4, 0.5) + weight("Body", i % 400, 1) }'),
    ('evpos / bonepos: 20000 reads of a posed rig', RIG + 'op("arm.auto_weights")\nselect("Rig")\nop("arm.pose", "Hips rot 0 0 30")\n', 'for i in 0..20000 { x = evpos("Body", i % 400, "y") + bonepos("Rig", "Head", "x") }'),
    ('shatter(): 200 shards', '', 'x = shatter("Cube", "shards", 200, "seed 3")'),
    ('emit + particles(): 40 systems, 30 frames', 'add("plane", "E", 0, 3, 0)\nfor i in 0..40 { emit("E", "rate 100") }\n', 'for f in 1..31 { frame(f)\n x = particles(0) }'),
    ('playstep(): 10 s walked', 'add("plane", "G")\nscale("G", 50)\nop("play.start")\n', 'playstep(10, 1, 0.3, 0, 1)'),
]


def s_perf():
    print('-- performance: release builds, pinned to one CPU (BEE_CPU, default 8) --')
    cpu = os.environ.get('BEE_CPU', '8')
    for what, setup, body in PERF:
        code = setup + 't0 = clock()\n' + body + '\nprint("ms", clock() - t0)\n'
        ts = []
        for b in (BIN,):
            best = None
            for _ in range(3):
                h = tempfile.mkdtemp(dir=T)
                open(f'{h}/s.bees', 'w').write(expand(code))
                env = envOf(h)
                r = subprocess.run(['taskset', '-c', cpu, b, '--run', f'{h}/s.bees'], capture_output=True, text=True, timeout=600, env=env, cwd=h)
                shutil.rmtree(h, True)
                m = re.search(r'^ms (\S+)', r.stdout, re.M)
                if m:
                    best = float(m.group(1)) if best is None else min(best, float(m.group(1)))
            ts.append(best)
        ok = None not in ts
        check(ok, f'{what}: timed, {ts[0]} ms')


if __name__ == '__main__':
    print(f'bs_sim: {BIN}, runs {RUNS}, seed {SEED}')
    try:
        for nm, f in [('net', s_net), ('phys', s_phys), ('land', s_land), ('anim', s_anim), ('rig', s_rig), ('play', s_play),
                      ('args', s_args), ('random', s_random), ('files', s_files), ('garbage', s_garbage), ('leak', s_leak), ('window', s_window)]:
            if want(nm):
                f()
        if 'perf' in ONLY:
            s_perf()
    finally:
        if not os.environ.get('BS_KEEP'):
            shutil.rmtree(T, True)
    print(f'bs_sim: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)
