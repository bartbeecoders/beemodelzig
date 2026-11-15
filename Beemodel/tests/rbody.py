#!/usr/bin/env python3
"""Rigid bodies (rbody.zig, collide.zig, nbody.zig) and the simulation cache
(simcache.zig): random scenes of every shape (box, sphere, capsule, hull,
compound, passive mesh and plane), materials, velocities, groups, damping and
world settings; joints (fixed, hinge, point, slider, limits, motors,
breaking); a pile big enough for the staged solver; bodies that attract;
force fields. Each scene is played twice by BeeModel: as a BeeScript (--run:
op, frame, rbinfo) and from the command line (--op, --print-anim); every
object's place at several frames (the OBJS transforms, byte for byte) and the
hash of every body's state (rbinfo(16)) must be the same both ways, and every
number finite. Then the cache: frames played back when going back, a cached
frame the same as one simulated, the key (an edit at the start drops it),
bake, sim.free, a baked file opened again plays from its SIMC; damaged SIMC
and rigid-body records; undo and redo with the timeline (undo puts the bodies,
joints and places back); the console's answers; a fuzz on the debug build;
and the time a frame takes at 200 bodies.

    python3 tests/rbody.py BIN [runs=12] [seed]

BEE_CPU (default 12) pins every run; RB_ONLY=s_shapes,s_cache ... runs some;
RB_REL=release build for the timing (default: BIN).
"""
import math, os, random, re, struct, subprocess, sys, tempfile, time, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 12
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '12')
REL = os.path.abspath(os.environ.get('RB_REL', BIN))
ONLY = [x for x in os.environ.get('RB_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beerb-', dir=os.environ.get('BEERB_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
ANIM_HEAD = 8 + 55904 - 4


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def script(code, timeout=900, binary=None):
    """A BeeScript run by BeeModel (--run): its output ('timeout' when it hangs)."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary or BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        check(False, 'the BeeScript hung')
        return 'timeout'
    if 'error' in r.stderr or r.returncode not in (0, 1) or 'panic' in r.stderr:
        print(r.stderr[-400:])
    if r.returncode not in (0, 1) or 'panic' in r.stderr:
        check(False, f'the BeeScript run stopped ({r.returncode})')
    return r.stdout


def port(*a, timeout=900, binary=None, ok=True):
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary or BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *a],
                           capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        check(False, f'BeeModel hung: {a[:6]}')
        return None
    if ok and r.returncode != 0:
        print(r.stderr[-1500:])
        check(False, f'BeeModel stopped ({r.returncode}): {a[:6]}')
    return r


def plog():
    return open(f'{T}/log.txt', errors='replace').read() if os.path.exists(f'{T}/log.txt') else ''


def answers(lines):
    out, cur = [], None
    for ln in lines:
        if ln.startswith('> '):
            cur = []
            out.append(cur)
        elif cur is not None:
            cur.append(ln)
    return out


def chunk(path, tag):
    try:
        return beefile.chunk(path, tag)
    except Exception:
        return None


def places(path):
    c = chunk(path, b'OBJS')
    if c is None:
        return None
    n = struct.unpack_from('<I', c, 0)[0]
    return {c[4 + k * 84:4 + k * 84 + 32].split(b'\0')[0].decode(errors='replace'): c[4 + k * 84 + 32:4 + k * 84 + 68] for k in range(n)}


def rb_part(c):
    """ANIM's rigid-body and joint records and world settings."""
    if c is None or len(c) < ANIM_HEAD:
        return None
    nrb, njt = struct.unpack_from('<2I', c, 8 + 52 - 4)
    rw = c[ANIM_HEAD - 32:ANIM_HEAD]
    return rw, c[ANIM_HEAD:ANIM_HEAD + nrb * 80], c[ANIM_HEAD + nrb * 80:ANIM_HEAD + nrb * 80 + njt * 64]


def same_files(a, b, what, simc=True):
    pa, pb = places(a), places(b)
    if pa is None or pb is None:
        return False, f'{what}: a file is missing ({pa is None}, {pb is None})'
    why = []
    bad = [k for k in sorted(set(pa) | set(pb)) if pa.get(k) != pb.get(k)]
    if bad:
        k = bad[0]
        fa = struct.unpack('<9f', pa[k]) if pa.get(k) else None
        fb = struct.unpack('<9f', pb[k]) if pb.get(k) else None
        why.append(f'{len(bad)} places differ: {bad[:4]} (first: {fa} / {fb})')
    ca, cb = chunk(a, b'ANIM'), chunk(b, b'ANIM')
    if (ca is None) != (cb is None) or (ca is not None and rb_part(ca) != rb_part(cb)):
        why.append('ANIM rigid bodies / joints / world differ')
    if simc and chunk(a, b'SIMC') != chunk(b, b'SIMC'):
        sa, sb = chunk(a, b'SIMC'), chunk(b, b'SIMC')
        why.append(f'SIMC differs ({len(sa or b"")} / {len(sb or b"")} bytes)')
    return not why, f'{what}: ' + ('; '.join(why) if why else 'the same')


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def rnd(rng, a, b, nd=3):
    return round(rng.uniform(a, b), nd)


def clear_lines():
    return ['n = count()', 'for i in 0..n { delete(name(0)) }']


INFO = [16, 1, 2, 5, 3, 7, 14, 15, 19]


def run_both(base, steps, frames, tag, binary=None, info=INFO, extra_o=(), extra_p=()):
    """The steps on the base both ways (a BeeScript, the command line), then at
    each frame both files and the rbinfo values: [(script's file, command
    line's file)], [script's infos], [command line's infos]."""
    code = [f'op("file.open", "{base}")', *extra_o]
    a = ['--op', f'file.open {base}', *extra_p]
    for s in steps:
        if s.startswith('@'):
            code.append(f'select({", ".join(chr(34) + x + chr(34) for x in s[1:].split(","))})')
            for x in s[1:].split(','):
                a += ['--select', x]
            continue
        i, _, r = s.partition(' ')
        code.append(f'op("{i}", "{esc(r)}")')
        a += ['--op', s]
    out = []
    for k, f in enumerate(frames):
        po, pp = f'{T}/{tag}o{k}.bee', f'{T}/{tag}p{k}.bee'
        code += [f'frame({f})', 'print("I" + ' + ' + " " + '.join(f'str(rbinfo({x}))' for x in info) + ')', f'op("file.save_as", "{po}")']
        a += ['--op', f'anim.frame {f}']
        for x in info:
            a += ['--print-anim', f'rbinfo:{x}']
        a += ['--op', f'file.save_as {pp}']
        out.append((po, pp))
    so = script('\n'.join(code))
    r = port(*a, binary=binary)
    io = [[float(v) for v in ln.split()] for ln in re.findall(r'^I ?(.*)$', so, re.M)]
    vals = re.findall(r'^rbinfo:(\d+)=(\S+)', r.stderr if r else '', re.M)
    ip = []
    for k in range(0, len(vals), len(info)):
        ip.append([float(v) for _, v in vals[k:k + len(info)]])
    return out, io, ip


SHAPES = ['box', 'sphere', 'capsule', 'hull', 'compound']
KINDS = ['cube', 'sphere', 'cylinder', 'cube', 'cone', 'torus']


def random_scene(rng, n, path, ground='box'):
    """A ground and n bodies of random kinds and places, made by a
    BeeScript: (the file, the steps that make them bodies)."""
    lines = clear_lines()
    steps = []
    if ground == 'plane':
        lines += ['add("plane", "Ground", 0, 0, 0)', 'scale("Ground", 8)']
        steps += ['@Ground', 'rigid.add passive plane']
    elif ground == 'mesh':
        lines += ['add("sphere", "Ground", 0, 2.5, 0)', 'scale("Ground", 3)']
        steps += ['@Ground', 'rigid.add passive mesh']
    else:
        lines += ['add("cube", "Ground", 0, -0.5, 0)', f'scale("Ground", 6, 0.5, 6)', f'rotate("Ground", {rnd(rng, -0.1, 0.1)}, 0, {rnd(rng, -0.1, 0.1)})']
        steps += ['@Ground', 'rigid.add passive box' + (' material ' + rng.choice(['ice', 'rubber', 'stone']) if rng.random() < 0.4 else '')]
    for k in range(n):
        nm = f'B{k}'
        lines.append(f'add("{rng.choice(KINDS)}", "{nm}", {rnd(rng, -1.5, 1.5)}, {rnd(rng, 0.6, 3 + k * 0.6)}, {rnd(rng, -1.5, 1.5)})')
        if rng.random() < 0.8:
            lines.append(f'scale("{nm}", {rnd(rng, 0.15, 0.6)}, {rnd(rng, 0.15, 0.6)}, {rnd(rng, 0.15, 0.6)})')
        if rng.random() < 0.7:
            lines.append(f'rotate("{nm}", {rnd(rng, -1.5, 1.5)}, {rnd(rng, -1.5, 1.5)}, {rnd(rng, -1.5, 1.5)})')
        o = ['active', rng.choice(SHAPES)]
        if rng.random() < 0.4:
            o += ['mass', str(rnd(rng, 0.2, 5, 2))]
        if rng.random() < 0.3:
            o += ['friction', str(rnd(rng, 0, 1, 2))]
        if rng.random() < 0.3:
            o += ['bounce', str(rnd(rng, 0, 0.9, 2))]
        if rng.random() < 0.2:
            o += ['damping', str(rnd(rng, 0, 0.5, 2))]
        if rng.random() < 0.2:
            o += ['material', rng.choice(['default', 'rubber', 'ice', 'wood', 'metal', 'stone'])]
        if rng.random() < 0.25:
            o += ['velocity', str(rnd(rng, -3, 3)), str(rnd(rng, -2, 4)), str(rnd(rng, -3, 3))]
        if rng.random() < 0.15:
            o += ['group', str(rng.randint(0, 3)), 'collide', str(rng.choice([1, 3, 7, 65535]))]
        steps += [f'@{nm}', 'rigid.add ' + ' '.join(o)]
    lines.append(f'op("file.save_as", "{path}")')
    script('\n'.join(lines))
    return steps


def compare(fr, io, ip, what, show=3):
    """Files and rbinfo at each frame: the bad ones' reasons."""
    bad = []
    for k, (a, b) in enumerate(fr):
        ok, why = same_files(a, b, f'{what} frame {k}', simc=False)
        if not ok:
            bad.append(why)
        if k < len(io) and k < len(ip) and io[k] != ip[k]:
            bad.append(f'{what} frame {k}: rbinfo {io[k]} / {ip[k]}')
        elif k >= len(io) or k >= len(ip):
            bad.append(f'{what} frame {k}: no rbinfo ({len(io)}, {len(ip)})')
        elif not all(math.isfinite(v) for v in io[k] + ip[k]):
            bad.append(f'{what} frame {k}: rbinfo not finite {ip[k]}')
        pb = places(b) or {}
        if not all(math.isfinite(v) for t in pb.values() for v in struct.unpack('<9f', t)):
            bad.append(f'{what} frame {k}: a place not finite')
    for w in bad[:show]:
        print('      ', w)
    return bad


FRAMES = [2, 7, 15, 31, 60, 97]


# ---- the simulation, frame by frame ---------------------------------------------------------

def s_shapes():
    print('-- random scenes: every shape, materials, velocities, groups, damping, a box / plane / mesh ground; places and rbinfo at 6 frames --')
    rng = random.Random(SEED)
    nbad = 0
    moved = 0
    contacts = 0
    for run in range(RUNS):
        ground = ['box', 'plane', 'mesh', 'box'][run % 4]
        base = f'{T}/sh{run}.bee'
        steps = random_scene(rng, rng.randint(2, 7), base, ground)
        if rng.random() < 0.4:
            w = ['rigid.world']
            if rng.random() < 0.5:
                w += ['gravity', str(rnd(rng, -2, 2)), str(rnd(rng, -14, -3)), str(rnd(rng, -2, 2))]
            if rng.random() < 0.4:
                w += ['rate', str(rng.choice([30, 60, 90, 240]))]
            if rng.random() < 0.4:
                w += ['iterations', str(rng.randint(2, 30))]
            if rng.random() < 0.4:
                w += ['substeps', str(rng.randint(1, 8))]
            steps.append(' '.join(w))
        fr, io, ip = run_both(base, steps, FRAMES, f'sh{run}_')
        bad = compare(fr, io, ip, f'scene {run} ({ground})')
        if bad:
            nbad += 1
        p0, p1 = places(fr[0][0]), places(fr[-1][0])
        if p0 and p1 and p0 != p1:
            moved += 1
        if io and max(r[1] for r in io) > 0:
            contacts += 1
    check(nbad == 0, f'{RUNS - nbad} of {RUNS} random scenes: every place and rbinfo the same both ways and finite at {len(FRAMES)} frames')
    check(moved >= RUNS * 3 // 4 and contacts >= RUNS // 2, f'bodies moved in {moved}, touched in {contacts} of {RUNS}')


JTYPES = ['fixed', 'hinge', 'point', 'slider']


def s_joints():
    print('-- joints: fixed, hinge, point, slider, to a body or the world, pivots, axes, limits, motors, breaking --')
    rng = random.Random(SEED + 1)
    nbad = 0
    broke = 0
    for run in range(RUNS):
        base = f'{T}/jt{run}.bee'
        n = rng.randint(2, 5)
        steps = random_scene(rng, n, base, 'box')
        for k in range(rng.randint(1, n + 1)):
            t = rng.choice(JTYPES)
            a = f'B{rng.randrange(n)}'
            b = rng.choice(['world'] + [f'B{i}' for i in range(n) if f'B{i}' != a])
            j = ['rigid.joint', t, a, b]
            if rng.random() < 0.6:
                j += ['pivot', str(rnd(rng, -1, 1)), str(rnd(rng, 0.5, 4)), str(rnd(rng, -1, 1))]
            if rng.random() < 0.6:
                j += ['axis', str(rnd(rng, -1, 1)), str(rnd(rng, -1, 1)), str(rnd(rng, -1, 1))]
            if t in ('hinge', 'slider') and rng.random() < 0.5:
                lo = rnd(rng, -60, 0, 1) if t == 'hinge' else rnd(rng, -1, 0)
                j += ['limits', str(lo), str(-lo / 2)]
            if t in ('hinge', 'slider') and rng.random() < 0.4:
                j += ['motor', str(rnd(rng, -90, 90, 1) if t == 'hinge' else rnd(rng, -1, 1)), str(rnd(rng, 1, 50, 1))]
            if rng.random() < 0.25:
                j += ['break', str(rnd(rng, 1, 40, 1))]
            steps.append(' '.join(j))
        fr, io, ip = run_both(base, steps, FRAMES, f'jt{run}_')
        if compare(fr, io, ip, f'joints {run}'):
            nbad += 1
        if io and io[-1][7] > 0:
            broke += 1
    check(nbad == 0, f'{RUNS - nbad} of {RUNS} jointed scenes: every place and rbinfo the same both ways and finite at {len(FRAMES)} frames')
    check(broke >= 1 or RUNS < 6, f'joints broke in {broke} scenes')


def s_pile():
    print('-- a pile of 160 boxes and spheres on a plane (big islands: the staged solver), and the stairs: a passive mesh --')
    lines = clear_lines() + ['add("plane", "Ground", 0, 0, 0)', 'scale("Ground", 20)', 'k = 0',
                             'for i in 0..8 {', ' for j in 0..20 {', '  n = "P" + str(k)',
                             '  if (k % 3) == 0 { add("sphere", n, (j % 4) * 0.42 - 0.6 + i * 0.01, 0.25 + i * 0.45, (j / 4) * 0.42 - 0.9) } else { add("cube", n, (j % 4) * 0.42 - 0.6 + i * 0.01, 0.25 + i * 0.45, floor(j / 4) * 0.42 - 0.9) }',
                             '  scale(n, 0.2)', '  k += 1', ' }', '}', f'op("file.save_as", "{T}/pile.bee")']
    so = script('\n'.join(lines))
    steps = ['@Ground', 'object.select_all', 'object.select_all', 'rigid.add active box', '@Ground', 'rigid.add passive plane']
    fr, io, ip = run_both(f'{T}/pile.bee', steps, [3, 20, 45, 90], 'pl')
    bad = compare(fr, io, ip, 'pile')
    check(not bad, f'the pile: every place and rbinfo the same both ways at 4 frames ({io[-1] if io else so[-300:]})')
    check(io and io[-1][4] >= 1 and io[-1][1] > 300, f'the pile touches ({io[-1][1] if io else 0} contact points, {io[-1][4] if io else 0} islands)')
    lines = clear_lines() + ['add("cube", "St", 0, 0, 0)', 'scale("St", 2, 1, 2)', 'rotate("St", 0, 0.3, 0.2)', 'add("plane", "Floor", 0, -1, 0)', 'scale("Floor", 10)']
    for k in range(10):
        lines += [f'add("{["cube", "sphere"][k % 2]}", "S{k}", {(k % 4) * 0.5 - 0.8}, {2 + k * 0.4}, {(k // 4) * 0.5 - 0.5})', f'scale("S{k}", 0.2)']
    lines += [f'op("file.save_as", "{T}/st.bee")']
    script('\n'.join(lines))
    steps = ['@St', 'rigid.add passive mesh', '@Floor', 'rigid.add passive plane'] + [x for k in range(10) for x in (f'@S{k}', f'rigid.add active {["box", "sphere"][k % 2]}')]
    fr, io, ip = run_both(f'{T}/st.bee', steps, [5, 30, 70], 'st')
    bad = compare(fr, io, ip, 'mesh collider')
    check(not bad, 'bodies on a passive mesh: every place and rbinfo the same both ways at 3 frames')


def s_attract():
    print('-- bodies that attract (nbody): G, no gravity, velocities; and force fields pulling bodies --')
    rng = random.Random(SEED + 2)
    nbad = 0
    for run in range(max(2, RUNS // 3)):
        lines = clear_lines()
        steps = ['rigid.world gravity 0 0 0 g ' + str(rnd(rng, 0.5, 30, 2))]
        for k in range(rng.randint(3, 9)):
            lines += [f'add("sphere", "N{k}", {rnd(rng, -4, 4)}, {rnd(rng, -4, 4)}, {rnd(rng, -4, 4)})', f'scale("N{k}", {rnd(rng, 0.1, 0.6)})']
            steps += [f'@N{k}', f'rigid.add active sphere mass {rnd(rng, 0.5, 30, 1)} ' + rng.choice(['attracts', 'attracts', 'noattract']) +
                      (f' velocity {rnd(rng, -1, 1)} {rnd(rng, -1, 1)} {rnd(rng, -1, 1)}' if rng.random() < 0.5 else '')]
        lines.append(f'op("file.save_as", "{T}/nb{run}.bee")')
        script('\n'.join(lines))
        fr, io, ip = run_both(f'{T}/nb{run}.bee', steps, [4, 20, 50], f'nb{run}_', info=INFO + [22, 23])
        if compare(fr, io, ip, f'attracting {run}'):
            nbad += 1
    check(nbad == 0, f'attracting bodies: every place and rbinfo the same both ways ({nbad} bad)')
    # force fields (fields.zig): a wind and an attractor on falling bodies
    base = f'{T}/ff.bee'
    steps = random_scene(random.Random(SEED + 9), 5, base, 'plane')
    lines = [f'op("file.open", "{base}")', 'op("field.add_attractor", "")', 'move("Attractor", 1, 2, 0)', 'op("field.add_wind", "")', 'move("Wind", -2, 1, 1)',
             'rotate("Wind", 0.3, 0, 1.2)', f'op("file.save_as", "{base}")']
    script('\n'.join(lines))
    fr, io, ip = run_both(base, steps, [5, 25, 60], 'ff')
    bad = compare(fr, io, ip, 'fields')
    check(not bad, 'bodies in force fields: every place and rbinfo the same both ways at 3 frames')
    pf = places(fr[-1][0])
    check(pf is not None and any(k.lower().startswith(('attr', 'wind', 'field')) for k in pf), f'the fields are there ({sorted(pf or {})[:8]})')


# ---- the cache ---------------------------------------------------------------------------------

def simc_frames(c):
    """SIMC: [(channel, start, key, [frames])]."""
    out = []
    o = 0
    while c and o + 20 <= len(c):
        ch, st, key, n = struct.unpack_from('<IIQI', c, o)
        sz = struct.unpack_from(f'<{n}I', c, o + 20)
        o += 20 + 4 * n
        fs = []
        for s in sz:
            fs.append(c[o:o + s])
            o += s
        out.append((ch, st, key, fs))
    return out


def s_cache():
    print('-- the cache: going back plays cached frames, the same as simulated, an edit at the start drops them, bake, sim.free, a baked file opened again --')
    base = f'{T}/ca.bee'
    steps = random_scene(random.Random(SEED + 5), 5, base, 'box')
    # forward, back (played: rbinfo(25)), forward again, an edit at the start (stale), bake
    seq = steps + ['anim.frame 30', '#save', '?', 'anim.frame 12', '#save', '?', 'anim.frame 30', '#save', '?', 'anim.frame 1', '#save',
                   'anim.key B1:y 1 3.3', 'anim.frame 12', '#save', '?', 'sim.bake rigid', '#save', '?', 'anim.frame 40', '#save', '?',
                   '@B2', 'rigid.add mass 3', 'anim.frame 41', '#save', '?', 'sim.free rigid', 'anim.frame 20', '#save', '?', 'sim.bake', 'anim.frame 7', '#save']
    code = [f'op("file.open", "{base}")']
    a = ['--op', f'file.open {base}']
    saves = []
    for s in seq:
        if s == '#save':
            po, pp = f'{T}/cao{len(saves)}.bee', f'{T}/cap{len(saves)}.bee'
            code.append(f'op("file.save_as", "{po}")')
            a += ['--op', f'file.save_as {pp}']
            saves.append((po, pp))
        elif s == '?':
            code.append('print("Q", rbinfo(25), rbinfo(16), rbinfo(0), cacheinfo(0), cacheinfo(3), cacheinfo(5))')
            a += ['--print-anim', 'rbinfo:25', '--print-anim', 'rbinfo:16', '--print-anim', 'rbinfo:0', '--print-anim', 'cacheinfo:0', '--print-anim', 'cacheinfo:3', '--print-anim', 'cacheinfo:5']
        elif s.startswith('@'):
            code.append(f'select("{s[1:]}")')
            a += ['--select', s[1:]]
        else:
            i, _, r = s.partition(' ')
            code.append(f'op("{i}", "{esc(r)}")')
            a += ['--op', s]
    so = script('\n'.join(code))
    r = port(*a)
    qo = [ln.split()[1:] for ln in so.splitlines() if ln.startswith('Q ')]
    vals = re.findall(r'^(rbinfo|cacheinfo):\d+=(\S+)', r.stderr if r else '', re.M)
    qp = [[v for _, v in vals[k:k + 6]] for k in range(0, len(vals), 6)]
    qo = [[str(float(x)) for x in q] for q in qo]
    qp = [[str(float(x)) for x in q] for q in qp]
    bad = []
    for k, (x, y) in enumerate(saves):
        ok, why = same_files(x, y, f'cache step {k}')
        if not ok:
            bad.append(why)
    for w in bad[:4]:
        print('      ', w)
    if qo != qp:
        print('       rbinfo / cacheinfo:', qo, qp)
    check(not bad, f'{len(saves) - len(bad)} of {len(saves)} steps\' files (places, records, SIMC) the same both ways')
    check(qo == qp and len(qo) == 8, f'played from the cache, the hash, the cache\'s frames, baked, full the same both ways at {len(qo)} points')
    check(len(qo) >= 3 and qo[1][0] == '1.0' and qo[0][0] == '0.0', f'going back played a cached frame ({[q[0] for q in qo]})')
    check(len(qo) >= 4 and qo[3][3] != qo[2][3], f'an edit at the start dropped the cache ({[q[3] for q in qo]})')
    sc = chunk(saves[5][0], b'SIMC')
    sf = simc_frames(sc)
    check(sf and sf[0][0] == 0 and len(sf[0][3]) > 30, f'the bake is in the file ({len(sc or b"")} bytes, {[len(x[3]) for x in sf]} frames)')
    # a frame played back from the cache is the frame simulated (step 1: frame 12, gone back to)
    a2 = ['--op', f'file.open {base}']
    for s_ in steps:
        a2 += ['--select', s_[1:]] if s_.startswith('@') else ['--op', s_]
    port(*a2, '--op', 'anim.frame 12', '--op', f'file.save_as {T}/cafresh.bee')
    pc, pf = places(saves[1][1]), places(f'{T}/cafresh.bee')
    check(pc is not None and pc == pf, 'frame 12 played from the cache: the places of frame 12 simulated')
    # baked files both ways: each route's baked file played by both routes, opened again from its SIMC
    po, pp = saves[5]
    for src, who in ((po, 'the BeeScript'), (pp, 'the command line')):
        code = [f'op("file.open", "{src}")', 'frame(33)', f'op("file.save_as", "{T}/bo.bee")', 'frame(9)', f'op("file.save_as", "{T}/bo2.bee")']
        script('\n'.join(code))
        r = port('--op', f'file.open {src}', '--op', 'anim.frame 33', '--print-anim', 'rbinfo:25', '--op', f'file.save_as {T}/bp.bee', '--op', 'anim.frame 9', '--op', f'file.save_as {T}/bp2.bee')
        ok1, w1 = same_files(f'{T}/bo.bee', f'{T}/bp.bee', 'frame 33')
        ok2, w2 = same_files(f'{T}/bo2.bee', f'{T}/bp2.bee', 'frame 9')
        if not (ok1 and ok2):
            print('      ', w1, w2)
        check(ok1 and ok2, f'{who}\'s baked file played at frames 33 and 9 both ways: the same')
        m = re.search(r'rbinfo:25=(\S+)', r.stderr if r else '')
        check(m is not None and float(m.group(1)) == 1, f'{who}\'s baked file opened again: frame 33 played from its SIMC ({m and m.group(1)})')


def damage(rng, c):
    c = bytearray(c)
    for _ in range(rng.randint(1, 6)):
        k = rng.randrange(max(1, len(c)))
        if k < len(c):
            c[k] = rng.randrange(256)
    return bytes(c)


def build(chs):
    o = b'BEEM' + struct.pack('<I', 1)
    for t, c in chs:
        o += t + struct.pack('<I', len(c)) + c
    return o


def s_damaged():
    print('-- damaged SIMC chunks and rigid-body records: no crash, and the same result both ways --')
    rng = random.Random(SEED + 6)
    base = f'{T}/dmb.bee'
    steps = random_scene(rng, 4, base, 'box')
    a = ['--op', f'file.open {base}']
    for s in steps:
        a += ['--select', s[1:]] if s.startswith('@') else ['--op', s]
    port(*a, '--op', 'sim.bake', '--op', f'file.save_as {T}/dm0.bee')
    chs = list(beefile.chunks(f'{T}/dm0.bee'))
    n = max(8, RUNS)
    crash = bad = same = 0
    for run in range(n):
        how = run % 4
        def hurt(t, c):
            if t == b'SIMC':
                if how == 0:
                    return c[:rng.randrange(len(c))]
                if how == 1:
                    return damage(rng, c)
                if how == 2:   # a frame record's counts
                    c = bytearray(c)
                    o = 20 + 4 * struct.unpack_from('<I', c, 16)[0]
                    struct.pack_into('<I', c, o + 16 * rng.randrange(3), rng.choice([0xffffffff, 1 << 20, 7, 0]))
                    return bytes(c)
            if t == b'ANIM' and how == 3:
                c = bytearray(c)
                nrb = struct.unpack_from('<I', c, 8 + 52 - 4)[0]
                for _ in range(rng.randint(1, 8)):
                    o = ANIM_HEAD + rng.randrange(nrb * 80)
                    c[o] = rng.randrange(256)
                return bytes(c)
            return c
        dm = f'{T}/dd{run}.bee'
        open(dm, 'wb').write(build([(t, hurt(t, c)) for t, c in chs]))
        code = [f'op("file.open", "{dm}")', 'frame(17)', f'op("file.save_as", "{T}/ddo.bee")', 'frame(5)', f'op("file.save_as", "{T}/ddo2.bee")']
        for f in ('ddo.bee', 'ddo2.bee'):
            if os.path.exists(f'{T}/{f}'):
                os.remove(f'{T}/{f}')
        so = script('\n'.join(code))
        r = port('--op', f'file.open {dm}', '--op', 'anim.frame 17', '--op', f'file.save_as {T}/ddp.bee', '--op', 'anim.frame 5', '--op', f'file.save_as {T}/ddp2.bee', ok=False)
        if r is None or r.returncode != 0 or 'panic' in (r.stderr or ''):
            crash += 1
            print('       BeeModel stopped on', dm, r and r.stderr[-600:])
            continue
        if not os.path.exists(f'{T}/ddo2.bee'):
            crash += 1
            print('       the BeeScript did not get through', dm, so[-300:])
            continue
        ok, why = same_files(f'{T}/ddo.bee', f'{T}/ddp.bee', f'damaged {run}')
        ok2, why2 = same_files(f'{T}/ddo2.bee', f'{T}/ddp2.bee', f'damaged {run}')
        if ok and ok2:
            same += 1
        else:
            bad += 1
            print('      ', how, why, why2)
    check(crash == 0, f'BeeModel opened and played {n - crash} of {n} damaged files')
    check(bad == 0, f'{same} of {same + bad} damaged files: the same result both ways')


# ---- undo, the console ------------------------------------------------------------------------

CONSOLE_SEQ = [
    'rigid.add', 'rigid.add active bogus', 'rigid.add mass', 'rigid.add mass x', 'rigid.add velocity 1 2', 'rigid.add material plastic', 'rigid.add group',
    'rigid.joint', 'rigid.joint glue A B', 'rigid.joint hinge Nothing world', 'rigid.joint hinge A A', 'rigid.joint hinge A Nothing', 'rigid.joint hinge A B bogus',
    'rigid.joint hinge A B pivot 1 2', 'rigid.joint hinge A B limits 1', 'rigid.joint hinge A B motor 1 x', 'rigid.joint point A world break',
    'rigid.world bogus', 'rigid.world gravity 0 -1', 'rigid.world rate', 'rigid.world substeps 0', 'rigid.world rate 99999 iterations -4',
    'sim.cache', 'sim.cache budget', 'sim.cache budget x', 'sim.cache bogus', 'sim.cache budget 2', 'sim.cache budget 99999', 'sim.cache budget 512',
    'sim.free bogus', 'sim.free', 'sim.bake nothing', 'sim.bake',
    '@A', 'rigid.add active box mass 2', '@A,B', 'rigid.add passive sphere friction 0.1', 'rigid.joint hinge A B axis 0 0 1 limits -30 30 motor 45 10',
    'rigid.joint slider B world', 'rigid.world gravity 0 -5 0 rate 60 substeps 2', 'anim.frame 20', 'sim.cache', 'sim.bake rigid', 'sim.cache', 'sim.free cloth',
    'sim.free rigid', 'sim.cache', '@B', 'rigid.remove', 'rigid.add', '@Light', 'rigid.add', 'sim.bake', 'sim.cache',
]


def console_base():
    base = f'{T}/conbase.bee'
    script('\n'.join(clear_lines() + ['add("cube", "A", 0, 2, 0)', 'add("cube", "B", 0.3, 4, 0)', 'scale("B", 0.5)', 'add("cube", "G", 0, -1, 0)', 'scale("G", 4, 0.5, 4)',
                                    'add("light", "Light", 3, 3, 3)', f'op("file.save_as", "{base}")']))
    return base


BAD_WORDS = ('bogus', 'Nothing', ' x', 'glue', 'A A')


def s_console():
    print('-- the console\'s words: every rigid-body and cache operator answers, the wrong ones say what is wrong --')
    base = console_base()
    a = ['--op', f'file.open {base}']
    for c in CONSOLE_SEQ:
        if c.startswith('@'):
            for x in c[1:].split(','):
                a += ['--select', x]
        else:
            a += ['--op', c]
    port(*a)
    got = answers(plog().splitlines())[1:]
    cmds = [c for c in CONSOLE_SEQ if not c.startswith('@')]
    check(len(got) == len(cmds), f'{len(got)} answers to {len(cmds)} commands')
    wrong = [(c, g) for c, g in zip(cmds, got) if any(w in c for w in BAD_WORDS)]
    quiet = [c for c, g in wrong if not any(ln.strip() for ln in g)]
    for c in quiet[:8]:
        print(f'       {c!r}: nothing said')
    check(len(wrong) >= 10 and not quiet, f'{len(wrong) - len(quiet)} of {len(wrong)} wrong commands say so')
    said = sum(1 for g in got if g)
    check(said >= len(cmds) // 2, f'{said} of {len(cmds)} commands said something')


UNDO_SEQ = ['@A', 'rigid.add active box', '@G', 'rigid.add passive box', '@B', 'rigid.add active sphere', 'anim.frame 25', '#save',
            'edit.undo', '#save', 'edit.redo', '#save', 'anim.frame 40', '#save', 'rigid.joint point A B', 'anim.frame 30', '#save', 'edit.undo', '#save',
            'anim.frame 1', '#save', 'rigid.joint hinge A B axis 0 0 1', 'anim.frame 33', '#save', '@B', 'rigid.remove', '#save', 'edit.undo', '#save', 'anim.frame 12', '#save', 'edit.redo', '#save',
            'rigid.world gravity 0 -2 0', 'anim.frame 18', '#save', 'edit.undo', 'anim.frame 19', '#save', 'sim.bake', 'anim.frame 22', '#save', 'edit.undo', '#save',
            '@A', 'object.delete', 'anim.frame 5', '#save', 'edit.undo', 'anim.frame 50', '#save', 'edit.undo', 'edit.undo', '#save']


def undo_run(seq, base, tag):
    a = ['--op', f'file.open {base}']
    got = []
    for c in seq:
        if c == '#save':
            p = f'{T}/{tag}{len(got)}.bee'
            a += ['--op', f'file.save_as {p}']
            got.append(p)
        elif c.startswith('@'):
            a += ['--select', c[1:]]
        else:
            a += ['--op', c]
    port(*a)
    return got


def counts(p):
    rb = rb_part(chunk(p, b'ANIM')) or (b'', b'', b'')
    return len(rb[1]) // 80, len(rb[2]) // 64


def s_undo():
    print('-- undo and redo with the timeline: bodies added, a joint, removed, the world, a bake, deleting a body: undo puts each back --')
    base = console_base()
    got = undo_run(UNDO_SEQ, base, 'up')
    check(len(got) == UNDO_SEQ.count('#save') and all(os.path.exists(p) for p in got), f'{len(got)} steps saved')
    pl = [places(x) for x in got]
    check(len(set(tuple(sorted(p.items())) for p in pl if p)) >= 5, 'the steps hold different places')
    nb = [counts(x)[0] for x in got]
    nj = [counts(x)[1] for x in got]
    check(len(set(nb)) >= 2 and len(set(nj)) >= 2 and any(chunk(x, b'SIMC') for x in got), f'the steps hold different bodies {nb}, joints {nj} and a bake')
    # at frame 1 (nothing simulated): each edit, undone, gives back the file before it; redone, the one after
    seq = ['@A', 'rigid.add active box', '@G', 'rigid.add passive box', '@B', 'rigid.add active sphere', 'anim.frame 1', '#save']
    edits = [('@A', 'rigid.add mass 3'), ('', 'rigid.joint hinge A B axis 0 0 1'), ('', 'rigid.world gravity 0 -2 0'), ('', 'rigid.joint point A world'),
             ('@B', 'rigid.remove'), ('@A', 'object.delete')]
    for sel, e in edits:
        seq += ([sel] if sel else []) + [e, '#save', 'edit.undo', '#save', 'edit.redo', '#save']
    got = undo_run(seq, base, 'uu')
    bad = []
    for k, (sel, e) in enumerate(edits):
        before, after, undone, redone = got[3 * k], got[3 * k + 1], got[3 * k + 2], got[3 * k + 3]
        ok1, w1 = same_files(before, undone, f'{e} undone', simc=False)
        ok2, w2 = same_files(after, redone, f'{e} redone', simc=False)
        if not ok1:
            bad.append(w1)
        if not ok2:
            bad.append(w2)
    for w in bad[:6]:
        print('      ', w)
    check(not bad, f'{len(edits)} edits undone and redone: the files before and after them')
    # a body removed takes its joints with it, to it or from it (B is the joint's second body)
    k = [e for _, e in edits].index('rigid.remove')
    nb0, nj0 = counts(got[3 * k])
    nb1, nj1 = counts(got[3 * k + 1])
    check(nj0 >= 2 and nb1 == nb0 - 1 and nj1 == nj0 - 1, f'B removed: bodies {nb0} -> {nb1}, joints {nj0} -> {nj1} (its hinge goes, A\'s point stays)')
    # undone after playing on: the bodies, not the simulated places, come back
    got = undo_run(['@A', 'rigid.add active box', '@B', 'rigid.add active sphere', 'anim.frame 1', '#save', '@A', 'rigid.add mass 4', '#save',
                    'anim.frame 30', 'edit.undo', 'anim.frame 1', '#save'], base, 'ut')
    ok, why = same_files(got[0], got[2], 'played on, undone, back at frame 1', simc=False)
    if not ok:
        print('      ', why)
    check(ok, 'an edit undone after playing to frame 30: back at frame 1 the file before the edit')


# ---- stability, time ------------------------------------------------------------------------------

def s_fuzz():
    print('-- fuzz: random rigid-body, joint, world and cache operators, frames back and forth, undo, on the debug build: no panic, no hang --')
    rng = random.Random(SEED + 7)
    words = ['active', 'passive', 'box', 'sphere', 'capsule', 'hull', 'compound', 'mesh', 'plane', 'mass', 'friction', 'bounce', 'damping', 'velocity', 'group',
             'collide', 'material', 'rubber', 'attracts', 'noattract', 'fit', 'instances', 'object', '-1', '0', '1e30', 'nan', '3', '0.5', '-7', '1e-30', 'inf']
    bad = 0
    n = max(4, RUNS // 2)
    for run in range(n):
        base = f'{T}/fz{run}.bee'
        steps = random_scene(rng, rng.randint(1, 6), base, rng.choice(['box', 'plane', 'mesh']))
        a = ['--op', f'file.open {base}']
        for s in steps:
            a += ['--select', s[1:]] if s.startswith('@') else ['--op', s]
        for _ in range(40):
            k = rng.random()
            if k < 0.25:
                a += ['--select', f'B{rng.randrange(6)}', '--op', 'rigid.add ' + ' '.join(rng.choice(words) for _ in range(rng.randint(0, 6)))]
            elif k < 0.35:
                a += ['--op', f'rigid.joint {rng.choice(JTYPES + ["x"])} B{rng.randrange(6)} {rng.choice(["world", "B1", "B2", "Ground"])} ' + ' '.join(rng.choice(words + ['pivot', 'axis', 'limits', 'motor', 'break']) for _ in range(rng.randint(0, 8)))]
            elif k < 0.42:
                a += ['--op', 'rigid.world ' + ' '.join(rng.choice(['gravity', 'rate', 'iterations', 'substeps', 'g'] + words[-9:]) for _ in range(rng.randint(0, 6)))]
            elif k < 0.7:
                a += ['--op', f'anim.frame {rng.choice([1, 2, 5, 13, 40, 7, 0, -3, 2.5, 60])}']
            elif k < 0.78:
                a += ['--op', rng.choice(['edit.undo', 'edit.redo'])]
            elif k < 0.85:
                a += ['--op', rng.choice(['sim.bake', 'sim.free', 'sim.bake rigid', 'sim.cache', 'sim.cache budget 16'])]
            elif k < 0.9:
                a += ['--select', f'B{rng.randrange(6)}', '--op', rng.choice(['rigid.remove', 'object.delete', 'object.duplicate'])]
            else:
                a += ['--op', f'anim.key B{rng.randrange(6)}:{rng.choice(["x", "y", "rz", "sx"])} {rng.choice([1, 5, 20])} {rnd(rng, -2, 2)}']
        a += ['--op', f'file.save_as {T}/fz.bee']
        r = port(*a, ok=False, timeout=600)
        if r is None or r.returncode != 0 or 'panic' in (r.stderr or '') or 'leak' in (r.stderr or '').lower():
            bad += 1
            print('       BeeModel failed:', r and r.stderr[-800:])
            open(f'{T}/fuzz_args_{run}.txt', 'w').write('\n'.join(a))
    check(bad == 0, f'{n - bad} of {n} fuzz runs ended cleanly')


def s_perf():
    print('-- time: 200 boxes and spheres falling on a plane, frames 2..60, pinned to one CPU (release build), both ways --')
    lines = clear_lines() + ['add("plane", "Ground", 0, 0, 0)', 'scale("Ground", 30)', 'k = 0', 'for i in 0..10 {', ' for j in 0..20 {', '  n = "P" + str(k)',
                             '  add("cube", n, (j % 5) * 0.6 - 1.2 + i * 0.03, 0.3 + i * 0.7, floor(j / 5) * 0.6 - 0.9)', '  scale(n, 0.25)', '  k += 1', ' }', '}',
                             f'op("file.save_as", "{T}/perf.bee")']
    script('\n'.join(lines))
    steps_o = ['select("Ground")', 'op("object.select_all", "")', 'op("object.select_all", "")', 'op("rigid.add", "active box")', 'select("Ground")', 'op("rigid.add", "passive plane")']
    # one frame 1 -> 61: the simulation's 60 frames in one go (rbinfo(4): its ms)
    code = [f'op("file.open", "{T}/perf.bee")', *steps_o, 'frame(1)', 'frame(61)', 'print("T", rbinfo(4) / 60, rbinfo(16), rbinfo(1))']
    best_o = ho = None
    so = script('\n'.join(code), binary=REL)
    m = re.search(r'^T (\S+) (\S+) (\S+)', so, re.M)
    if m:
        best_o, ho = float(m.group(1)), m.group(2)
    a = ['--op', f'file.open {T}/perf.bee', '--select', 'Ground', '--op', 'object.select_all', '--op', 'object.select_all', '--op', 'rigid.add active box',
         '--select', 'Ground', '--op', 'rigid.add passive plane', '--op', 'anim.frame 1', '--op', 'anim.frame 61', '--print-anim', 'rbinfo:4', '--print-anim', 'rbinfo:16']
    best_p = None
    hp = None
    for _ in range(2):
        r = port(*a, binary=REL)
        m = re.search(r'rbinfo:4=(\S+)', r.stderr if r else '')
        if m:
            v = float(m.group(1)) / 60
            best_p = v if best_p is None else min(best_p, v)
        mh = re.search(r'rbinfo:16=(\S+)', r.stderr if r else '')
        hp = mh.group(1) if mh else None
    print(f'       a frame: {best_p} ms (the BeeScript\'s run {best_o} ms; hash {ho} / {hp})')
    check(best_p is not None and math.isfinite(best_p) and best_p > 0, f'a frame of 200 bodies timed: {best_p} ms')
    check(ho is not None and hp is not None and float(ho) == float(hp), 'the same bodies after 60 frames both ways (rbinfo(16))')


SECTIONS = ['s_shapes', 's_joints', 's_pile', 's_attract', 's_cache', 's_damaged', 's_console', 's_undo', 's_fuzz', 's_perf']


def main():
    print(f'seed {SEED}')
    try:
        for s in SECTIONS:
            if ONLY and s not in ONLY:
                continue
            globals()[s]()
    finally:
        if not os.environ.get('RB_KEEP'):
            shutil.rmtree(T, ignore_errors=True)
        else:
            print('kept', T)
    print(f'rbody: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
