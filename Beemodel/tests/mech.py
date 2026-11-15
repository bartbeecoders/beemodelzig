#!/usr/bin/env python3
"""Mechanisms (mech.zig), BeeModel on its own, done two ways in the same build
and compared: a BeeScript (--run: op(), frame(), collisions()) and the console's
lines (--op, anim.frame). Mates, random joint chains (revolute, slider, pivots,
axes, limits, gears, racks, value expressions with parameters, units and the
frame), every part's place and every joint's value frame by frame (the OBJS
transforms and the ANIM chunk, byte for byte both ways), keyed parameters
moving the mechanism and the feature tree, collisions, what the console says,
files (saved and opened again), damaged records, undo and redo, deleting and
duplicating parts, the CAD tab's joint rows and the joint form (the file as
the console's operator gives it), random chains on the debug build, and the
time a frame's evaluation takes.

    python3 tests/mech.py BIN [runs=30] [seed]

BEE_CPU (default 12) pins every run; MECH_ONLY=s_mates,s_chains ... runs some;
MECH_REL: a release build for s_perf.
"""
import math, os, random, re, struct, subprocess, sys, tempfile, time, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 30
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '12')
ONLY = [x for x in os.environ.get('MECH_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beemech-', dir=os.environ.get('BEEMECH_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
MJ_SZ = 208


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def orig(code, timeout=600):
    """BeeModel runs a script (--run, a file: any length): its stdout. (The
    name from when another program ran it.)"""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        return 'timeout'
    if 'error' in r.stderr:
        print(r.stderr[-400:])
    return r.stdout


def port(*a, timeout=600, binary=None, ok=True):
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary or BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a],
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
    """The console: what each command said, in order ("> cmd" starts one)."""
    out, cur = [], None
    for ln in lines:
        if ln.startswith('> '):
            cur = []
            out.append(cur)
        elif cur is not None:
            cur.append(ln)
    return out


def ops(*lines):
    out = []
    for ln in lines:
        out += ['--op', ln]
    return out


def chunk(path, tag):
    try:
        return beefile.chunk(path, tag)
    except Exception:
        return None


def places(path):
    """{object name: its OBJS transform bytes (world loc, rot radians, scale)}."""
    c = chunk(path, b'OBJS')
    if c is None:
        return None
    n = struct.unpack_from('<I', c, 0)[0]
    return {c[4 + k * 84:4 + k * 84 + 32].split(b'\0')[0].decode(errors='replace'): c[4 + k * 84 + 32:4 + k * 84 + 68] for k in range(n)}


ANIM_HEAD = 8 + 55904 - 4


def anim_parts(c):
    """ANIM's mechanism records ([bytes]) and the whole chunk."""
    if c is None or len(c) < ANIM_HEAD:
        return None
    nrb, njt, nmj = struct.unpack_from('<3I', c, 8 + 52 - 4)
    o = ANIM_HEAD + nrb * 80 + njt * 64
    return [c[o + k * MJ_SZ:o + (k + 1) * MJ_SZ] for k in range(min(nmj, 64))]


def joint_vals(path):
    rs = anim_parts(chunk(path, b'ANIM'))
    if rs is None:
        return None
    return [(struct.unpack_from('<f', r, 56)[0], struct.unpack_from('<I', r, 60)[0]) for r in rs]


def finite(p):
    """A place as the files keep it: no NaN or infinity (loc, rot 0, scale 1)."""
    v = list(struct.unpack('<9f', p))
    for i in range(9):
        if not math.isfinite(v[i]):
            v[i] = 1.0 if i >= 6 else 0.0
    return struct.pack('<9f', *v)


def same_files(a, b, what, names=None, nan_ok=False):
    """Every object's place and the ANIM chunk, byte for byte: (ok, why)."""
    pa, pb = places(a), places(b)
    if nan_ok and pa:
        pa = {k: finite(v) for k, v in pa.items()}
    if pa is None or pb is None:
        return False, f'{what}: a file is missing ({pa is None}, {pb is None})'
    why = []
    bad = [k for k in sorted(set(pa) | set(pb)) if pa.get(k) != pb.get(k)]
    if bad:
        k = bad[0]
        fa = struct.unpack('<9f', pa[k]) if pa.get(k) else None
        fb = struct.unpack('<9f', pb[k]) if pb.get(k) else None
        why.append(f'places of {bad} (first: {fa} / {fb})')
    ca, cb = chunk(a, b'ANIM') or b'', chunk(b, b'ANIM') or b''
    if ca != cb:
        ra, rb = anim_parts(ca), anim_parts(cb)
        if ra is not None and rb is not None and ra != rb:
            k = next((i for i in range(min(len(ra), len(rb))) if ra[i] != rb[i]), None)
            off = None if k is None else next(i for i in range(MJ_SZ) if ra[k][i] != rb[k][i])
            why.append(f'ANIM joints ({len(ra)}/{len(rb)}; joint {k} from byte {off})')
        else:
            n = next((i for i in range(min(len(ca or b''), len(cb or b''))) if ca[i] != cb[i]), None)
            why.append(f'ANIM ({len(ca or b"")}/{len(cb or b"")} bytes, first at {n})')
    return not why, f'{what}: ' + ('; '.join(why) if why else 'the same')


# ---- scenes ---------------------------------------------------------------------------------

def rnd(rng, a, b, nd=3):
    return round(rng.uniform(a, b), nd)


def base_scene(rng, n, path, params=()):
    """n parts of random kinds, places, turns and sizes, made by a script."""
    kinds = ['cube', 'cylinder', 'cube', 'sphere', 'cylinder']
    lines = ['n = count()', 'for i in 0..n { delete(name(0)) }']
    names = []
    for k in range(n):
        nm = f'P{k}'
        names.append(nm)
        lines.append(f'o = add("{rng.choice(kinds)}", "{nm}", {rnd(rng, -3, 3)}, {rnd(rng, -2, 2)}, {rnd(rng, -3, 3)})')
        if rng.random() < 0.7:
            lines.append(f'scale(o, {rnd(rng, 0.2, 1.5)}, {rnd(rng, 0.2, 1.5)}, {rnd(rng, 0.2, 1.5)})')
        if rng.random() < 0.7:
            lines.append(f'rotate(o, {rnd(rng, -1.5, 1.5)}, {rnd(rng, -1.5, 1.5)}, {rnd(rng, -1.5, 1.5)})')
    for nm, e in params:
        lines.append(f'param("{nm}", "{e}")')
    lines.append(f'op("file.save_as", "{path}")')
    orig('\n'.join(lines))
    return names


def run_both(base, steps, frames, tag, binary=None):
    """The steps (operator lines) on the base by a script and by the console,
    then at each frame both files: [(the script's, the console's)]."""
    code = [f'op("file.open", "{base}")']
    for s in steps:
        i, _, a = s.partition(' ')
        code.append(f'op("{i}", "{esc(a)}")')
    a = ['--op', f'file.open {base}', *ops(*steps)]
    out = []
    for k, f in enumerate(frames):
        po, pp = f'{T}/{tag}o{k}.bee', f'{T}/{tag}p{k}.bee'
        code += [f'frame({f})', f'print("C", collisions())', f'op("file.save_as", "{po}")']
        a += ['--op', f'anim.frame {f}', '--print-anim', 'collisions', '--op', f'file.save_as {pp}']
        out.append((po, pp))
    so = orig('\n'.join(code))
    r = port(*a, binary=binary)
    co = [int(float(x)) for x in re.findall(r'^C (\S+)', so, re.M)]
    cp = [int(float(x)) for x in re.findall(r'^collisions=(\S+)', r.stderr if r else '', re.M)]
    return out, co, cp


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def s_mates():
    print('-- mates: the assembly test\'s scene and random mates, every part\'s place by a script and by the console --')
    base = f'{T}/mbase.bee'
    orig('\n'.join(['n = count()', 'for i in 0..n { delete(name(0)) }', 'b = add("cube", "Base", 0, 0, 0)', 'scale(b, 2, 0.1, 1)',
                    'p = add("cylinder", "Pin", 3, 2, -1)', 'scale(p, 0.1, 0.5, 0.1)', 'rotate(p, 0.3, 0.2, 1.1)', 'w = add("cylinder", "Wheel", -2, 3, 2)',
                    'scale(w, 0.6, 0.05, 0.6)', 'rotate(w, 1.2, 0, 0.4)', f'op("file.save_as", "{base}")']))
    steps = ['asm.mate concentric Pin 33 Base axis 0.5 0 0 0 1 0', 'asm.mate coincident Pin 32 Base 1', 'asm.mate concentric Wheel 33 Pin 33',
             'asm.mate distance Wheel 32 Base 1 30cm', 'mech.joint revolute Wheel Pin pivot 1 0.45 0 axis 0 1 0 value frame*4.5deg']
    fr, _, _ = run_both(base, steps, [1, 10], 'ma')
    for (a, b), f in zip(fr, [1, 10]):
        ok, why = same_files(a, b, f'assembly.py\'s plate, pin and wheel at frame {f}')
        check(ok, why)
    pl = places(fr[1][0])
    w = struct.unpack('<9f', pl['Wheel']) if pl else None
    check(w is not None and abs(w[0] - 1) < 1e-4 and abs(w[1] - 0.45) < 1e-4, f'the wheel sits on the pin ({w and [round(x, 4) for x in w[:3]]})')
    rng = random.Random(SEED)
    nbad = 0
    for run in range(max(4, RUNS // 3)):
        base = f'{T}/mb{run}.bee'
        names = base_scene(rng, 4, base)
        steps = []
        for _ in range(rng.randint(2, 6)):
            kind = rng.choice(['coincident', 'concentric', 'distance'])
            a, b = rng.sample(names, 2)

            def refr():
                if rng.random() < 0.35:
                    return 'axis ' + ' '.join(str(rnd(rng, -1, 1)) for _ in range(6))
                return str(rng.randint(0, 40))
            s = f'asm.mate {kind} {a} {refr()} {b} {refr()}'
            if kind == 'distance':
                s += ' ' + rng.choice(['0.5', '30cm', '-0.2', '2mm'])
            if rng.random() < 0.3:
                s += ' flip'
            if rng.random() < 0.1:
                s += ' bogus'
            steps.append(s)
        fr, _, _ = run_both(base, steps, [1], f'mr{run}')
        ok, why = same_files(*fr[0], f'random mates {run}')
        if not ok:
            nbad += 1
            print('      ', why, steps)
    check(nbad == 0, f'random mates: {max(4, RUNS // 3) - nbad} of {max(4, RUNS // 3)} scenes place every part the same both ways')


def value_expr(rng, params):
    c = [lambda: f'frame*{rnd(rng, -9, 9, 2)}deg', lambda: f'{rnd(rng, -2, 2)}', lambda: f'frame*{rnd(rng, -0.05, 0.05, 4)}',
         lambda: f'sin(frame*{rnd(rng, 2, 20, 1)}deg)*{rnd(rng, 5, 60, 1)}deg', lambda: f'{rng.randint(1, 30)}cm', lambda: f'{rng.randint(-90, 90)}deg']
    if params:
        c += [lambda: f'{rng.choice(params)}*{rnd(rng, -3, 3, 2)}', lambda: f'{rng.choice(params)} + frame*{rnd(rng, 0.5, 3, 1)}deg']
    return rng.choice(c)()


def chain(rng, names, params, nj):
    """Random joints (and changes to them) on these parts."""
    steps = []
    made = 0
    # parents before their parts (a part moved by a later joint, or a cycle,
    # places its children by where it was: then the result is how many times
    # the mechanism was evaluated, which s_cycle measures)
    order = names[:]
    rng.shuffle(order)
    k = 0
    for j in range(nj):
        ty = rng.choice(['revolute', 'revolute', 'slider'])
        if k > 0 and rng.random() < 0.15:
            k -= 1          # (the same part again: its later joint wins)
        k = min(k, len(order) - 1)
        part = order[k]
        parent = 'world' if k == 0 or rng.random() < 0.3 else rng.choice(order[:k])
        k += 1
        s = f'mech.joint {ty} {part} {parent}'
        if rng.random() < 0.7:
            s += ' pivot ' + ' '.join(str(rnd(rng, -2, 2)) for _ in range(3))
        if rng.random() < 0.8:
            s += ' axis ' + rng.choice(['0 1 0', '1 0 0', '0 0 1', ' '.join(str(rnd(rng, -1, 1)) for _ in range(3))])
        if rng.random() < 0.3:
            s += f' min {rng.choice(["-20deg", "-0.5", "0", "-1"])}'
        if rng.random() < 0.3:
            s += f' max {rng.choice(["30deg", "0.4", "1", "45deg"])}'
        if made > 0 and rng.random() < 0.35:
            s += f' gear {rng.randint(1, made)} {rnd(rng, -3, 3, 2)}'
        else:
            s += f' value {value_expr(rng, params)}'
        steps.append(s)
        made += 1
        if rng.random() < 0.15 and made > 0:
            k = rng.randint(1, made)
            o = rng.choice([f'value {value_expr(rng, params)}', f'min {rng.choice(["-10deg", "-0.2"])}', f'max {rng.choice(["10deg", "0.3"])}', 'nolimits',
                            f'gear {rng.randint(1, made)} {rnd(rng, -2, 2, 2)}'])
            steps.append(f'mech.set {k} {o}')
        if rng.random() < 0.07 and made > 1:
            steps.append(f'mech.remove {rng.randint(1, made)}')
            made -= 1
    return steps


def s_chains():
    print('-- random joint chains: every part\'s place and every joint\'s value, frame by frame, by a script and by the console --')
    rng = random.Random(SEED + 1)
    frames = [1, 4, 9.5, 17, 30, 47]
    nbad = 0
    moved = 0
    coll_bad = 0
    nrun = RUNS
    for run in range(nrun):
        params = [('a', f'{rng.randint(5, 60)}deg'), ('b', f'{rnd(rng, 0.1, 1.5)}')] if rng.random() < 0.6 else []
        base = f'{T}/cb{run}.bee'
        names = base_scene(rng, rng.randint(2, 6), base, params)
        steps = chain(rng, names, [p for p, _ in params], rng.randint(1, 7))
        if params and rng.random() < 0.5:
            steps += [f'anim.key param:a 1 {rnd(rng, -1, 1)}', f'anim.key param:a 40 {rnd(rng, -1, 1)}']
        fr, co, cp = run_both(base, steps, frames, f'c{run}')
        bad = None
        for (a, b), f in zip(fr, frames):
            ok, why = same_files(a, b, f'chain {run} frame {f}')
            if not ok:
                bad = why
                break
        if bad:
            nbad += 1
            print('      ', bad)
            print('       steps:', steps)
        if co != cp:
            coll_bad += 1
            print(f'       chain {run}: collisions {co} / {cp}')
        p0, p1 = places(fr[0][0]), places(fr[-1][0])
        if p0 and p1 and p0 != p1:
            moved += 1
    check(nbad == 0, f'{nrun - nbad} of {nrun} chains: places and joint records the same both ways at {len(frames)} frames')
    check(coll_bad == 0, f'colliding pairs (collisions() and --print-anim) the same at every frame in {nrun - coll_bad} of {nrun}')
    check(moved >= nrun // 2, f'the parts moved between the frames in {moved} of {nrun} chains')


LONG = 'frame*1deg+' * 7 + '0'
CONSOLE_SEQ = [
    'mech.list', 'mech.check', 'mech.set 1 value 2', 'mech.remove 1',
    'mech.joint', 'mech.joint hinge Wheel world', 'mech.joint revolute Nothing world', 'mech.joint revolute Wheel Wheel', 'mech.joint revolute Wheel Nothing',
    'mech.joint revolute Wheel Pin bogus', 'mech.joint revolute Wheel Pin pivot 1 2', 'mech.joint revolute Wheel Pin pivot 1 2 x', 'mech.joint revolute Wheel Pin value 1/0',
    'mech.joint revolute Wheel Pin value nosuch*2', 'mech.joint revolute Wheel Pin gear 5 2', 'mech.joint revolute Wheel Pin gear 1', 'mech.joint revolute Wheel Pin gear x 2',
    'mech.joint revolute Wheel Pin value ' + LONG, 'mech.joint revolute Wheel Pin min', 'mech.joint revolute Wheel Pin max 1 min x',
    'mech.joint revolute Wheel Pin pivot 1 0.45 0 axis 0 1 0 value frame*4.5deg',
    'mech.joint slider Pin world axis 1 0 0 min -0.5 max 0.2 value frame*0.1',
    'mech.joint revolute Base world axis 0 0 0 gear 1 -2 min -10deg max 10deg',
    'mech.joint slider Wheel Base gear 3 0.25',
    'mech.list', 'anim.frame 20', 'mech.list', 'mech.check', 'anim.frame 3', 'mech.list',
    'mech.set', 'mech.set 9 value 1', 'mech.set x', 'mech.set 1 value', 'mech.set 1 min nosuch', 'mech.set 1 bogus', 'mech.set 2 nolimits', 'mech.set 3 gear 2 0.5',
    'mech.set 4 value frame*2cm', 'mech.set -1 value 2', 'mech.set 1 max 2deg min 1deg', 'mech.list', 'anim.frame 7', 'mech.list',
    'mech.remove 1', 'mech.list', 'mech.remove 7', 'mech.remove', 'mech.remove x', 'mech.list',
    'asm.mate', 'asm.mate glued Pin 32 Base 1', 'asm.mate coincident Pin 99 Base 1', 'asm.mate coincident Pin 32 Nothing 1', 'asm.mate coincident Pin 32 Pin 1',
    'asm.mate distance Pin 32 Base 1', 'asm.mate coincident Pin 32 Base 1 flop', 'asm.mate coincident Pin axis 1 2 3 Base 1', 'asm.mate coincident Pin -1 Base 1',
    'asm.mate coincident Pin 32 Base 1 flip', 'asm.mate concentric Wheel 33 Pin 33', 'asm.mate distance Wheel 32 Base 1 30cm flip flip',
    'mech.remove 1', 'mech.remove 1', 'mech.remove 1', 'mech.list',
    'mech.joint slider Wheel world axis 1 0 0 value frame*0.25-2', 'anim.frame 1', 'mech.check', 'anim.frame 5', 'anim.frame 9', 'mech.check', 'anim.frame 30', 'mech.check',
    'anim.frame 12', 'mech.joint revolute Pin Base pivot 0 0 0 axis 0 0 1 value frame*3deg', 'anim.frame 13', 'mech.check', 'mech.list',
    # faces that touch do not collide; one through the other does
    'mech.joint slider Top world axis 0 1 0 value 0', 'mech.check', 'mech.joint slider Top world axis 0 1 0 value -0.5', 'mech.check',
]


def console_base():
    base = f'{T}/conbase.bee'
    orig('\n'.join(['n = count()', 'for i in 0..n { delete(name(0)) }', 'b = add("cube", "Base", 0, 0, 0)', 'scale(b, 2, 0.1, 1)',
                    'p = add("cylinder", "Pin", 1, 0.6, 0)', 'scale(p, 0.1, 0.5, 0.1)', 'w = add("cylinder", "Wheel", 1, 0.45, 0)',
                    'scale(w, 0.6, 0.05, 0.6)', 'c = add("cube", "Wall", 3, 0.5, 0)', 'scale(c, 0.1, 1, 1)',
                    'c = add("cube", "Low", 7, 0, 0)', 'c = add("cube", "Top", 7.3, 2, 0.4)', f'op("file.save_as", "{base}")']))
    return base


def s_console():
    print('-- the console\'s words: every mechanism and mate operator\'s answers and errors, collisions --')
    base = console_base()
    r = port('--op', f'file.open {base}', *ops(*CONSOLE_SEQ))
    got = answers(plog().splitlines())[1:]
    said = sum(1 for g in got if g)
    coll = sum(1 for g in got for ln in g if ln.startswith('  collision: '))
    check(r is not None and r.returncode == 0 and len(got) == len(CONSOLE_SEQ), f'{len(got)} of {len(CONSOLE_SEQ)} operators answered ({said} said something)')
    lists = [g for c, g in zip(CONSOLE_SEQ, got) if c == 'mech.list']
    check(len(lists) >= 5 and len({tuple(g) for g in lists}) >= 3, f'mech.list says something else as joints come and go ({len({tuple(g) for g in lists})} different lists)')
    check(coll >= 2, f'collisions were reported ({coll})')


def objmeshes(path):
    """{object name: its MESH chunk}."""
    try:
        ms = [c for t, c in beefile.chunks(path) if t == b'MESH']
        return {o['name']: (ms[o['mesh']] if 0 <= o['mesh'] < len(ms) else None) for o in beefile.objects(path)}
    except Exception:
        return None


def s_params():
    print('-- parameters as animation channels: a keyed parameter moves the mechanism and rebuilds the feature tree, frame by frame --')
    base = f'{T}/pbase.bee'
    orig('\n'.join(['n = count()', 'for i in 0..n { delete(name(0)) }', 'param("h", "1")', 'param("ang", "10deg")', 's = sketch("S", "XY")',
                    'r = rect(s, 0, 0, 2, 1)', '_ = pad("Body", "S", "h*0.5", "normal")', 'o = add("cube", "Arm", 2, 0, 0)', 'scale(o, 0.5, 0.1, 0.1)',
                    'o = add("cylinder", "Rod", 3, 1, 0)', 'scale(o, 0.1, 0.4, 0.1)', f'op("file.save_as", "{base}")']))
    steps = ['mech.joint revolute Arm Body pivot 1.5 0 0 axis 0 0 1 value ang*2 + frame*1deg', 'mech.joint slider Rod Arm axis 0 1 0 value h*0.3',
             'mech.joint revolute Body world pivot 0 0 0 axis 0 1 0 value ang', 'anim.key param:h 1 0.5', 'anim.key param:h 30 2.25', 'anim.key param:ang 1 0',
             'anim.key param:ang 20 0.7']
    frames = [1, 6, 12.5, 20, 30]
    fr, _, _ = run_both(base, steps, frames, 'pa')
    bad = []
    bodies = []
    for (a, b), f in zip(fr, frames):
        ok, why = same_files(a, b, f'frame {f}')
        ma, mb = objmeshes(a), objmeshes(b)
        if not ok:
            bad.append(why)
        if not ma or not mb or ma.get('Body') != mb.get('Body'):
            bad.append(f'frame {f}: the body\'s mesh differs')
        if chunk(a, b'CADD') != chunk(b, b'CADD'):
            bad.append(f'frame {f}: CADD differs')
        bodies.append(ma.get('Body') if ma else None)
    for w in bad:
        print('      ', w)
    check(not bad, f'places, joints, the rebuilt body and the parameters the same at {len(frames)} frames')
    check(len(set(bodies)) == len(frames), f'the body was rebuilt at every frame ({len(set(bodies))} different meshes)')
    pv = [joint_vals(a) for a, _ in fr]
    check(pv[0] and pv[-1] and pv[0][0] != pv[-1][0] and pv[0][1] != pv[-1][1], f'the keyed parameters moved the joints ({pv[0]} .. {pv[-1]})')



# ---- files ----------------------------------------------------------------------------------

def build(chs):
    o = b'BEEM' + struct.pack('<I', 1)
    for t, c in chs:
        o += t + struct.pack('<I', len(c)) + c
    return o


def mech_file(rng, run, tag):
    """A mechanism made by a script: (its file, the parts)."""
    params = [('a', f'{rng.randint(5, 60)}deg'), ('b', f'{rnd(rng, 0.1, 1.5)}')]
    base = f'{T}/{tag}b{run}.bee'
    names = base_scene(rng, rng.randint(3, 5), base, params)
    steps = chain(rng, names, ['a', 'b'], rng.randint(2, 6))
    code = [f'op("file.open", "{base}")'] + [f'op("{x.partition(" ")[0]}", "{esc(x.partition(" ")[2])}")' for x in steps] + ['frame(5)', f'op("file.save_as", "{T}/{tag}m{run}.bee")']
    orig('\n'.join(code))
    return f'{T}/{tag}m{run}.bee', names


def s_files():
    print('-- files: mechanisms saved by the console opened and saved by a script, and the other way round: the same --')
    rng = random.Random(SEED + 3)
    n = max(4, RUNS // 4)
    bad_po = bad_op = 0
    for run in range(n):
        params = [('a', f'{rng.randint(5, 60)}deg')]
        base = f'{T}/fb{run}.bee'
        names = base_scene(rng, rng.randint(3, 5), base, params)
        steps = chain(rng, names, ['a'], rng.randint(2, 6))
        pf = f'{T}/fp{run}.bee'
        port('--op', f'file.open {base}', *ops(*steps), '--op', 'anim.frame 7', '--op', f'file.save_as {pf}')
        of = f'{T}/fo{run}.bee'
        orig(f'op("file.open", "{pf}")\nop("file.save_as", "{of}")')
        ok, why = same_files(pf, of, f'the console\'s file {run}, saved by a script')
        if not ok or not anim_parts(chunk(pf, b'ANIM')):
            bad_po += 1
            print('      ', why, steps)
        om, _ = mech_file(rng, run, 'fx')
        pm = f'{T}/fy{run}.bee'
        port('--op', f'file.open {om}', '--op', f'file.save_as {pm}')
        ok, why = same_files(om, pm, f'a script\'s file {run}, saved by the console')
        if not ok or not anim_parts(chunk(om, b'ANIM')):
            bad_op += 1
            print('      ', why)
    check(bad_po == 0, f'{n - bad_po} of {n}: the console\'s mechanisms, opened and saved by a script, the same')
    check(bad_op == 0, f'{n - bad_op} of {n}: a script\'s mechanisms, opened and saved by the console, the same')


def damage(rng, c):
    """ANIM with its joint records damaged: odd types, sources, flags, limits,
    NaN and huge numbers, expressions with no end, parts no object has."""
    c = bytearray(c)
    nrb, njt, nmj = struct.unpack_from('<3I', c, 8 + 52 - 4)
    o = ANIM_HEAD + nrb * 80 + njt * 64
    if rng.random() < 0.3:
        nmj = rng.randint(nmj, 64)
        struct.pack_into('<I', c, 8 + 60 - 4, nmj)
    for k in range(min(nmj, 64)):
        r = o + k * MJ_SZ
        for _ in range(rng.randint(1, 6)):
            what = rng.randrange(9)
            if what == 0:
                struct.pack_into('<I', c, r, rng.choice([0, 1, 2, 3, 0xffffffff]))
            elif what == 1:
                struct.pack_into('<I', c, r + rng.choice([4, 8]), rng.choice([0, 1, 2, 3, 77, 0xffffffff]))
            elif what == 2:
                struct.pack_into('<I', c, r + 12, rng.choice([0, 1, 3, 0xffffffff]))
            elif what == 3:
                struct.pack_into('<f', c, r + rng.choice([16, 20, 24, 28, 32, 36, 40, 44, 48]), rng.choice([float('nan'), float('inf'), -1e30, 0.0, 1e-30, 2.5]))
            elif what == 4:
                struct.pack_into('<I', c, r + 52, rng.choice([0, 1, k, k + 1, k + 5, 0xffffffff]))
            elif what == 5:
                # no end within it (no parameter names, so no "a": a parameter met after an
                # error is poisoned in a cache until the document changes)
                c[r + 64:r + 128] = bytes(rng.choice(b'frme*2+e(1') for _ in range(64))
            elif what == 6:
                c[r + 64:r + 128] = (rng.choice([b'1/0', b'frame*', b'(((', b'a*2', b'sqrt(-1)', b'nosuch']) + b'\0').ljust(64, b'\0')
            elif what == 7:
                struct.pack_into('<f', c, r + 128 + 4 * rng.randrange(18), rng.choice([float('nan'), 0.0, 1e20, -3.0]))
            else:
                c[r:r + MJ_SZ] = bytes(rng.randrange(256) for _ in range(MJ_SZ))
    return bytes(c)


def s_damaged():
    print('-- damaged joint records in files: opened, evaluated and saved again, by a script and by the console, the same; no crash --')
    rng = random.Random(SEED + 4)
    n = max(6, RUNS // 2)
    bad = crash = 0
    for run in range(n):
        om, names = mech_file(rng, run, 'dm')
        chs = list(beefile.chunks(om))
        chs = [(t, damage(rng, c) if t == b'ANIM' else c) for t, c in chs]
        if run == 0:
            # an expression with no end in its 64 bytes: read on (into the place at 0)
            def endless(c):
                c = bytearray(c)
                nrb, njt = struct.unpack_from('<2I', c, 8 + 52 - 4)
                r = ANIM_HEAD + nrb * 80 + njt * 64
                struct.pack_into('<I', c, r, 1)
                struct.pack_into('<I', c, r + 52, 0)
                c[r + 64:r + 128] = b'1+' * 32
                return bytes(c)
            chs = [(t, endless(c) if t == b'ANIM' else c) for t, c in chs]
        if rng.random() < 0.15:
            chs = [(t, c[:rng.randrange(len(c))] if t == b'ANIM' else c) for t, c in chs]   # truncated
        dm = f'{T}/dd{run}.bee'
        open(dm, 'wb').write(build(chs))
        frames = [1, 6, 13]
        code = [f'op("file.open", "{dm}")']
        a = ['--op', f'file.open {dm}']
        outs = []
        for k, f in enumerate(frames):
            po, pp = f'{T}/ddo{run}_{k}.bee', f'{T}/ddp{run}_{k}.bee'
            code += [f'frame({f})', 'op("mech.list", "")', 'op("mech.check", "")', f'op("file.save_as", "{po}")']
            a += ['--op', f'anim.frame {f}', '--op', 'mech.list', '--op', 'mech.check', '--op', f'file.save_as {pp}']
            outs.append((po, pp))
        so = orig('\n'.join(code))
        r = port(*a, ok=False)
        if r is None or r.returncode != 0 or 'panic' in (r.stderr or ''):
            crash += 1
            print('       BeeModel stopped on', dm, r and r.stderr[-600:])
            continue
        if not os.path.exists(outs[0][0]):
            continue   # (the script did not open it either)
        for (po, pp), f in zip(outs, frames):
            ok, why = same_files(po, pp, f'damaged {run} frame {f}', nan_ok=True)
            if not ok:
                bad += 1
                print('      ', why)
                break
    check(crash == 0, f'the console opened, evaluated and saved {n - crash} of {n} damaged files')
    check(bad == 0, f'{n - bad} of {n} damaged files evaluated and saved the same both ways')


# ---- undo, delete, duplicate ------------------------------------------------------------------

UNDO_SEQ = ['mech.joint revolute Wheel Pin pivot 1 0.45 0 axis 0 1 0 value frame*4.5deg', 'mech.joint slider Pin world axis 1 0 0 min -0.5 max 0.2 value frame*0.1',
            'anim.frame 9', '#save', 'mech.set 1 value frame*9deg', '#save', 'edit.undo', '#save', 'edit.undo', '#save', 'edit.redo', '#save',
            'mech.set 2 min 0 bogus', '#save', 'edit.undo', '#save', 'edit.redo', 'mech.joint revolute Base world gear 1 -2', 'anim.frame 4', '#save',
            'mech.remove 1', '#save', 'edit.undo', '#save', 'asm.mate distance Wheel 32 Base 1 30cm', '#save', 'edit.undo', '#save', 'edit.undo', 'anim.frame 11', '#save',
            'edit.redo', 'edit.redo', '#save', '@Pin', 'object.delete', 'anim.frame 3', '#save', 'edit.undo', '#save', 'edit.redo', '@Base', 'object.duplicate', '#save',
            '@Base', 'object.delete', 'anim.frame 6', '#save', 'mech.list', 'edit.undo', 'edit.undo', '#save']


def s_undo():
    print('-- undo and redo through joints, their changes, a failed change, a mate, deleting a part and its parent, duplicating: the steps back give the files before --')
    base = console_base()
    a = ['--op', f'file.open {base}']
    got = []
    for c in UNDO_SEQ:
        if c == '#save':
            p = f'{T}/up{len(got)}.bee'
            a += ['--op', f'file.save_as {p}']
            got.append(p)
        elif c.startswith('@'):
            a += ['--select', c[1:]]
        else:
            a += ['--op', c]
    port(*a)
    check(all(os.path.exists(x) for x in got), f'{len(got)} steps saved')
    if not all(os.path.exists(x) for x in got):
        return
    # 0: two joints at frame 9; 1: joint 1 changed; 2: undone (= 0); 3: undone again (one
    # joint); 4: redone (= 0); (5: a change that fails on its last word: what it took before stays)
    for k, w, what in ((2, 0, 'the change undone'), (4, 0, 'undone twice, redone once')):
        ok, why = same_files(got[w], got[k], f'step {k} as step {w}: {what}')
        check(ok, why)
    ok, _ = same_files(got[0], got[1], 'a change')
    check(not ok, 'the change of joint 1 changed the scene')
    js = [len(anim_parts(chunk(x, b'ANIM')) or []) for x in got]
    check(len(set(js)) >= 3 and js[3] == js[0] - 1, f'the steps hold different joints ({js})')
    pl = [places(x) for x in got]
    check(len(set(tuple(sorted(p.items())) for p in pl if p)) >= 5, 'the steps hold different places')
    # deleted parts keep their uids in the records
    rs = anim_parts(chunk(got[-2], b'ANIM'))
    check(rs is not None and any(struct.unpack_from('<I', r, 8)[0] not in (0,) for r in rs), 'a deleted part\'s joint kept its uid')


def s_cycle():
    print('-- parts that place each other (a cycle): the result is how many times the mechanism was evaluated; measured --')
    base = console_base()
    steps = ['mech.joint revolute Wheel Pin axis 0 0 1 value frame*5deg', 'mech.joint revolute Pin Wheel pivot 1 0 0 axis 0 1 0 value frame*3deg']
    fr, _, _ = run_both(base, steps, [1, 5], 'cy')
    d = 0.0
    for a, b in fr:
        pa, pb = places(a), places(b)
        for k in pa:
            d = max(d, max(abs(x - y) for x, y in zip(struct.unpack('<9f', pa[k]), struct.unpack('<9f', pb[k]))))
    ok, _ = same_files(*fr[0], 'frame 1')
    print(f'       largest difference in a place: {d:.4g} (a script and the console: the mechanism evaluated another number of times)')
    check(True, f'a cycle measured: {d:.3g} at most (frame 1 {"the same" if ok else "differs"})')



# ---- the window: the CAD tab's joint rows, typing a value, the joint form -------------------

def ppm(path):
    d = open(path, 'rb').read()
    parts = d.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


def px(img, x, y):
    w, h, d = img
    o = (y * w + x) * 3
    return d[o:o + 3]


WIN_BASE_STEPS = ['mech.joint revolute Wheel Pin pivot 1 0.45 0 axis 0 1 0 value frame*4.5deg', 'mech.joint slider Pin world axis 1 0 0 min -0.5 max 0.2 value frame*0.1',
                  'mech.joint revolute Base world gear 1 -2 min -10deg max 10deg', 'anim.frame 7']
# (what, the widget's name and its sub, its label, keys after the click, the console's line that does the same: '' none, None nothing)
WIN_ACTS = [('a value typed in joint 2\'s field', 'cad.joint.value', 1, 'text:frame*0.1', ['ctrl+a', 'type:frame*0.05+0.1', 'enter'], 'mech.set 2 value frame*0.05+0.1'),
            ('a value typed, then Esc', 'cad.joint.value', 0, 'text:frame*4.5deg', ['ctrl+a', 'type:12deg', 'esc'], None),
            ('an empty value typed in joint 1', 'cad.joint.value', 0, 'text:frame*4.5deg', ['ctrl+a', 'backspace', 'enter'], ''),
            ('Add Joint..., the form as it opens, OK', 'cad.joint.add', 0, 'button:Add Joint...', ['enter'], ''),
            ('Add Joint..., Slider, Cancel', 'cad.joint.add', 0, 'button:Add Joint...', ['esc'], None)]
KEYS = {'ctrl+a': (30, 4), 'enter': (28, 0), 'esc': (1, 0), 'backspace': (14, 0)}


def s_window():
    print('-- the CAD tab\'s joint rows (labels, values, fields), typing a value, the joint form; each file as the console gives it --')
    base0 = console_base()
    base = f'{T}/winbase.bee'
    orig('\n'.join([f'op("file.open", "{base0}")'] + [f'op("{x.partition(" ")[0]}", "{x.partition(" ")[2]}")' for x in WIN_BASE_STEPS] + ['select("Wheel")', f'op("file.save_as", "{base}")']))
    # the rows: where they are (under New Sketch...), what they say
    port('--op', f'file.open {base}', '--select', 'Wheel', '--click-label', 'tab:CAD', '--move', '600,300', '--wait', '9000', '--move', '601,300')
    ui = [ln.split('\t') for ln in open(f'{T}/u.txt').read().splitlines()]
    rect = lambda q: [int(v) for v in q[2].split()]
    psk = next((rect(q) for q in ui if q[0] == 'button' and q[1] == 'New Sketch...'), None)
    padd = next((rect(q) for q in ui if q[0] == 'button' and q[1] == 'Add Joint...'), None)
    plabels = [q[1] for q in ui if q[0] == 'info' and re.match(r'^\d+ (Revolute|Slider) ', q[1])]
    pvals = [q[1] for q in ui if q[0] == 'info' and re.match(r'^-?[\d.]+( deg)?$', q[1])]
    pfields = [rect(q) for q in ui if q[0] == 'text' and q[1] in ('frame*4.5deg', 'frame*0.1')]
    check(psk and padd and padd[1] > psk[1], f'Add Joint... below New Sketch... ({psk}, {padd})')
    # (frame 7: 7 x 4.5deg; 0.7 held at its max 0.2; the gear -2 held at its min -10deg)
    check(plabels == ['1 Revolute Wheel', '2 Slider Pin', '3 Revolute Base'] and pvals == ['31.5 deg', '0.2', '-10 deg'], f'the rows say {plabels} {pvals}')
    check(len(pfields) == 2 and pfields[0][1] < pfields[1][1] and psk and all(r[1] > psk[1] for r in pfields), f'the value fields, one per row, under New Sketch... ({pfields})')
    plain = f'{T}/wplain.bee'
    port('--op', f'file.open {base}', '--op', f'file.save_as {plain}')
    # each action
    for what, _, _, label, keys, same_as in WIN_ACTS:
        # (after the toasts: a click on one opens the console)
        a = ['--op', f'file.open {base}', '--select', 'Wheel', '--click-label', 'tab:CAD', '--move', '600,300', '--wait', '9000', '--move', '601,300', '--click-label', label]
        for k in keys:
            if k.startswith('type:'):
                a += ['--type', k[5:]]
            else:
                a += ['--key', k]
        b = f'{T}/wp.bee'
        if os.path.exists(b):
            os.remove(b)
        r = port(*a, '--move', '600,300', '--op', f'file.save_as {b}')
        if not os.path.exists(b):
            check(False, f'{what}: no file')
            continue
        ok, _ = same_files(plain, b, what)
        if same_as is None:
            check(ok, f'{what}: nothing changed')
        elif same_as == '':
            check(r is not None and r.returncode == 0 and places(b) is not None, f'{what}: ran, the file reads back ({"unchanged" if ok else "changed"})')
        else:
            c = f'{T}/wc.bee'
            port('--op', f'file.open {base}', '--select', 'Wheel', '--op', same_as, '--op', f'file.save_as {c}')
            ok2, why = same_files(c, b, f'{what}: as "{same_as}" on the console')
            check(ok2 and not ok, why + (' (changed)' if not ok else ' (unchanged)'))


# ---- random sessions, no crash, no hang, no growth ----------------------------

def junk(rng):
    return rng.choice(['', 'x', '-1', '1e40', 'nan', '99999999999', '0', '1/0', 'frame*', '((((', 'world', '"q"', 'P0', 'P1', 'value', 'gear', 'axis', 'pivot',
                       'min', 'max', 'nolimits', 'flip', '3', '2.5', '-0', 'sqrt(-1)', 'frame*1e30', 'é', 'a' * 300])


def s_fuzz():
    print('-- random mechanisms (the debug build), odd arguments, frames, undo, redo, deletes, damaged files; no crash, no hang --')
    rng = random.Random(SEED + 5)
    n = max(6, RUNS // 2)
    bad = 0
    for run in range(n):
        base = f'{T}/zb{run}.bee'
        names = base_scene(rng, rng.randint(2, 6), base, [('a', '30deg')])
        steps = chain(rng, names, ['a'], rng.randint(1, 8))
        for _ in range(rng.randint(5, 25)):
            r = rng.random()
            if r < 0.2:
                steps.append(f'anim.frame {rng.choice([1, 2.5, 7, 13, 30, -4, 1000])}')
            elif r < 0.35:
                steps.append(rng.choice(['edit.undo', 'edit.redo']))
            elif r < 0.45:
                steps.append(f'mech.set {rng.randint(-1, 9)} ' + ' '.join(junk(rng) for _ in range(rng.randint(0, 4))))
            elif r < 0.5:
                steps.append(f'mech.remove {junk(rng)}')
            elif r < 0.6:
                steps.append(f'mech.joint {rng.choice(["revolute", "slider", "x"])} ' + ' '.join(rng.choice([junk(rng)] + names) for _ in range(rng.randint(0, 8))))
            elif r < 0.68:
                steps.append(f'asm.mate {rng.choice(["coincident", "concentric", "distance"])} ' + ' '.join(rng.choice([junk(rng)] + names) for _ in range(rng.randint(0, 8))))
            elif r < 0.75:
                steps.append(rng.choice(['mech.check', 'mech.list']))
            elif r < 0.8:
                steps.append(f'anim.key param:a {rng.randint(1, 30)} {rnd(rng, -3, 3)}')
            elif r < 0.85:
                steps.append(f'param.set a {rng.choice(["10deg", "1/0", "frame", "-2"])}')
            else:
                steps.append('@' + rng.choice(names))
                steps.append(rng.choice(['object.delete', 'object.duplicate']))
        a = ['--op', f'file.open {base}']
        for c in steps:
            a += ['--select', c[1:]] if c.startswith('@') else ['--op', c]
        a += ['--op', f'file.save_as {T}/zs.bee', '--op', f'file.open {T}/zs.bee', '--op', 'anim.frame 9', '--op', 'mech.check']
        t0 = time.time()
        r = port(*a, ok=False, timeout=300)
        dt = time.time() - t0
        if r is None or r.returncode != 0 or 'panic' in r.stderr or dt > 120:
            bad += 1
            print(f'       run {run}: {None if r is None else r.returncode} in {dt:.1f} s', (r.stderr[-800:] if r else ''), steps)
    check(bad == 0, f'{n - bad} of {n} random sessions ended well')
    # memory: many evaluated frames with colliding parts take no more than a few
    base = console_base()
    st = ['mech.joint slider Wheel world axis 1 0 0 value frame*0.25-2', 'mech.joint revolute Pin Base pivot 0 0 0 axis 0 0 1 value frame*7deg']

    def peak(nf):
        a = ['--op', f'file.open {base}', *ops(*st)]
        for f in range(nf):
            a += ['--op', f'anim.frame {1 + f % 40}']
        p = subprocess.Popen(['taskset', '-c', CPU, BIN, '--shot', f'{T}/m.ppm', *a, '--hold'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=ENV)
        hwm = None
        t0 = time.time()
        while time.time() - t0 < 300:
            time.sleep(0.3)
            if os.path.exists(f'{T}/m.ppm'):
                time.sleep(0.5)
                break
        try:
            for ln in open(f'/proc/{p.pid}/status'):
                if ln.startswith('VmHWM'):
                    hwm = int(ln.split()[1])
        except OSError:
            pass
        p.kill()
        p.wait()
        if os.path.exists(f'{T}/m.ppm'):
            os.remove(f'{T}/m.ppm')
        return hwm
    h1, h2 = peak(40), peak(400)
    check(h1 is not None and h2 is not None and h2 - h1 < 8000, f'40 and 400 frames of a colliding mechanism: peak memory {h1} / {h2} kB')



# ---- the time a frame's evaluation takes ------------------------------------------------------

def s_perf():
    print('-- the time: a frame of a 24-joint mechanism with collisions among 32 parts (MECH_REL: a release build): said --')
    rel = os.environ.get('MECH_REL', BIN)
    rng = random.Random(7)
    base = f'{T}/perf.bee'
    lines = ['n = count()', 'for i in 0..n { delete(name(0)) }']
    for k in range(32):
        lines.append(f'o = add("{["cylinder", "sphere", "cube"][k % 3]}", "Q{k}", {(k % 8) * 1.1 - 4}, {(k // 8) * 1.2 - 2}, 0)')
        lines.append('scale(o, 0.5, 0.5, 0.5)')
    lines.append(f'op("file.save_as", "{base}")')
    orig('\n'.join(lines))
    steps = []
    for k in range(24):
        par = 'world' if k % 4 == 0 else f'Q{k - 1}'
        steps.append(f'mech.joint {"revolute" if k % 3 else "slider"} Q{k} {par} axis {rng.choice(["0 0 1", "0 1 0", "1 0 0"])} value frame*{rnd(rng, 1, 6, 1)}{"deg" if k % 3 else "*0.02"}')
    nf = 200
    best_p = None
    cp = []
    for _ in range(3):
        # (frames 1 .. 40, the range bench-anim plays)
        r = port('--op', f'file.open {base}', *ops(*steps), '--op', 'anim.range 1 41 24', '--bench-anim', str(nf), '--print-anim', 'collisions', binary=rel)
        cp = re.findall(r'collisions=(\S+)', r.stderr if r else '')
        m = re.search(r'evaluation ([\d.]+) ms', r.stderr if r else '')
        if m:
            v = float(m.group(1))
            best_p = v if best_p is None else min(best_p, v)
    print(f'       a frame: {best_p} ms; colliding pairs {cp}')
    check(best_p is not None and best_p == best_p, f'{nf} frames evaluated and timed ({best_p} ms a frame)')


SECTIONS = ['s_mates', 's_chains', 's_params', 's_console', 's_files', 's_damaged', 's_undo', 's_cycle', 's_window', 's_fuzz', 's_perf']


def main():
    print(f'seed {SEED}')
    try:
        for s in SECTIONS:
            if ONLY and s not in ONLY:
                continue
            globals()[s]()
    finally:
        if not os.environ.get('MECH_KEEP'):
            shutil.rmtree(T, ignore_errors=True)
        else:
            print('kept', T)
    print(f'mech: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
