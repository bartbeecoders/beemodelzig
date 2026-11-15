#!/usr/bin/env python3
"""Rigid bodies on landscapes and in water (rbland.zig): boxes, spheres,
capsules, hulls and compounds dropped and slid on hills, mountains, canyons
and dunes (the landscape moved, scaled, turned); a painted landscape (rock
against snow: a box slides further on one, bounces higher on the other);
bodies on five landscapes (four heightfields, the fifth a plain mesh); boxes
floating and sinking in an island's sea and in a water plane, a hidden water
ignored; glued and impact shatters on landscapes; the cache, bake and undo
with landscapes; a fuzz; the time a frame takes.

Standalone: every run ends cleanly, every saved file reads back with finite
places, rbinfo is finite, the same run twice gives the same bodies, undo puts
the scene back, and the physics does what it should (bodies rest on the
ground, float or sink, slide by the paint, break where they hit).

    python3 tests/rbland.py BIN [runs=8] [seed]

BEE_CPU (default 12) pins every run; RL_ONLY=s_drop,s_water ... runs some;
RB_REL=release build for the timing (default: BIN).
"""
import math, os, sys, random, re, struct, shutil, subprocess, tempfile, pwd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile


def _real_config():
    h = pwd.getpwuid(os.getuid()).pw_dir
    out = {}
    for d in ('.config/beemodel-zig', '.config/beemodel'):
        p = os.path.join(h, d)
        if os.path.isdir(p):
            for n in sorted(os.listdir(p)):
                try:
                    st = os.stat(os.path.join(p, n))
                    out[f'{d}/{n}'] = (st.st_size, st.st_mtime_ns)
                except OSError:
                    pass
    return out


_REAL0 = _real_config()

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 8
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '12')
REL = os.path.abspath(os.environ.get('RB_REL', BIN))
ONLY = [x for x in os.environ.get('RL_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beerb-', dir=os.environ.get('BEERB_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)
ANIM_HEAD = 8 + 55904 - 4
INFO = [16, 1, 2, 5, 3, 7, 14, 15, 19]
FRAMES = [2, 7, 15, 31, 60, 97]
LKINDS = ['hills', 'mountains', 'canyon', 'dunes']
SHAPES = ['box', 'sphere', 'capsule', 'hull', 'compound']
KINDS = ['cube', 'sphere', 'cylinder', 'cube', 'cone', 'torus']


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def make(code, timeout=900):
    """A BeeScript run by BeeModel (--run): its output."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        check(False, 'a scene script hung')
        return 'timeout'
    if r.returncode != 0 or 'rror' in r.stderr:
        print('      the scene script:', (r.stdout + r.stderr)[-400:])
    return r.stdout + r.stderr


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


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def rnd(rng, a, b, nd=3):
    return round(rng.uniform(a, b), nd)


def clear_lines():
    return ['n = count()', 'for i in 0..n { delete(name(0)) }']


def run(base, steps, frames, tag, binary=None, info=INFO, extra=()):
    """The steps on the base, then at each frame a file and the rbinfo values:
    ([file], [infos])."""
    a = ['--op', f'file.open {base}', *extra]
    for s in steps:
        if s.startswith('@'):
            for x in s[1:].split(','):
                a += ['--select', x]
            continue
        a += ['--op', s]
    out = []
    for k, f in enumerate(frames):
        pp = f'{T}/{tag}p{k}.bee'
        a += ['--op', f'anim.frame {f}']
        for x in info:
            a += ['--print-anim', f'rbinfo:{x}']
        a += ['--op', f'file.save_as {pp}']
        out.append(pp)
    r = port(*a, binary=binary)
    vals = re.findall(r'^rbinfo:(\d+)=(\S+)', r.stderr if r else '', re.M)
    ip = []
    for k in range(0, len(vals), len(info)):
        ip.append([float(v) for _, v in vals[k:k + len(info)]])
    return out, ip


def sane(fr, ip, what, show=3):
    """Every frame's file reads back with finite places, every rbinfo is
    there and finite: the bad ones' reasons."""
    bad = []
    for k, f in enumerate(fr):
        p = places(f)
        if p is None:
            bad.append(f'{what} frame {k}: no file')
            continue
        nf = [n for n, b in p.items() if not all(math.isfinite(v) for v in struct.unpack('<9f', b))]
        if nf:
            bad.append(f'{what} frame {k}: places not finite: {nf[:4]}')
        if rb_part(chunk(f, b'ANIM')) is None:
            bad.append(f'{what} frame {k}: no rigid-body records')
        if k >= len(ip):
            bad.append(f'{what} frame {k}: no rbinfo ({len(ip)})')
        elif not all(math.isfinite(v) for v in ip[k]):
            bad.append(f'{what} frame {k}: rbinfo {ip[k]}')
    for w in bad[:show]:
        print('      ', w)
    return bad


def ys(nm, x, z, lift):
    """The script's y over landscape nm at (x, z) (its highest when not over it)."""
    return (f'h = height("{nm}", {x}, {z})\nif h == nil {{ h = landscape("{nm}", 4) }}\n'
            f'add_y = h + {lift}')


def body(rng, lines, steps, nm, x, z, land='Landscape', lift=None, kind=None, shape=None, extra=''):
    lift = lift if lift is not None else rnd(rng, 0.4, 2.5)
    lines.append(ys(land, x, z, lift))
    lines.append(f'add("{kind or rng.choice(KINDS)}", "{nm}", {x}, add_y, {z})')
    if rng.random() < 0.8:
        lines.append(f'scale("{nm}", {rnd(rng, 0.15, 0.5)}, {rnd(rng, 0.15, 0.5)}, {rnd(rng, 0.15, 0.5)})')
    else:
        lines.append(f'scale("{nm}", 0.3)')
    if rng.random() < 0.7:
        lines.append(f'rotate("{nm}", {rnd(rng, -1.5, 1.5)}, {rnd(rng, -1.5, 1.5)}, {rnd(rng, -1.5, 1.5)})')
    o = ['active', shape or rng.choice(SHAPES)]
    if rng.random() < 0.3:
        o += ['mass', str(rnd(rng, 0.2, 5, 2))]
    if rng.random() < 0.3:
        o += ['friction', str(rnd(rng, 0, 1, 2))]
    if rng.random() < 0.25:
        o += ['bounce', str(rnd(rng, 0, 0.9, 2))]
    if rng.random() < 0.35:  # sliding
        o += ['velocity', str(rnd(rng, -4, 4)), str(rnd(rng, -1, 1)), str(rnd(rng, -4, 4))]
    steps += [f'@{nm}', 'rigid.add ' + ' '.join(o) + extra]


def land_scene(rng, path, kind, n, res, size, place=True, ground_extra=()):
    lines = clear_lines() + [f'op("landscape.add", "{kind} res {res} size {size} seed {rng.randint(0, 99)}")']
    steps = ['@Landscape', 'rigid.add passive mesh' + (' friction ' + str(rnd(rng, 0.1, 1, 2)) if rng.random() < 0.3 else '')]
    if place:
        if rng.random() < 0.6:
            lines.append(f'move("Landscape", {rnd(rng, -5, 5)}, {rnd(rng, -4, 4)}, {rnd(rng, -5, 5)})')
        if rng.random() < 0.5:
            lines.append(f'scale("Landscape", {rnd(rng, 0.5, 2)}, {rnd(rng, 0.3, 2)}, {rnd(rng, 0.5, 2)})')
        if rng.random() < 0.3:
            lines.append(f'rotate("Landscape", {rnd(rng, -0.25, 0.25)}, {rnd(rng, -1, 1)}, {rnd(rng, -0.25, 0.25)})')
    lines += list(ground_extra)
    # the bodies near its middle (its place and scale from the script)
    lines += ['lx = get("Landscape", "x")', 'lz = get("Landscape", "z")', 'sx = get("Landscape", "sx")', 'sz = get("Landscape", "sz")']
    for k in range(n):
        fx, fz = rnd(rng, -0.3, 0.3), rnd(rng, -0.3, 0.3)
        nm = f'B{k}'
        lines.append(f'bx = lx + {fx * size} * sx\nbz = lz + {fz * size} * sz')
        lift = rnd(rng, 0.4, 2.5)
        lines.append(ys('Landscape', 'bx', 'bz', lift + 1.5))  # (turned: higher)
        lines.append(f'add("{rng.choice(KINDS)}", "{nm}", bx, add_y, bz)')
        lines.append(f'scale("{nm}", {rnd(rng, 0.15, 0.5)}, {rnd(rng, 0.15, 0.5)}, {rnd(rng, 0.15, 0.5)})')
        if rng.random() < 0.7:
            lines.append(f'rotate("{nm}", {rnd(rng, -1.5, 1.5)}, {rnd(rng, -1.5, 1.5)}, {rnd(rng, -1.5, 1.5)})')
        o = ['active', rng.choice(SHAPES)]
        if rng.random() < 0.3:
            o += ['mass', str(rnd(rng, 0.2, 5, 2))]
        if rng.random() < 0.3:
            o += ['friction', str(rnd(rng, 0, 1, 2))]
        if rng.random() < 0.25:
            o += ['bounce', str(rnd(rng, 0, 0.9, 2))]
        if rng.random() < 0.35:
            o += ['velocity', str(rnd(rng, -4, 4)), str(rnd(rng, -1, 1)), str(rnd(rng, -4, 4))]
        steps += [f'@{nm}', 'rigid.add ' + ' '.join(o)]
    lines.append(f'op("file.save_as", "{path}")')
    make('\n'.join(lines))
    return steps


def lands(path):
    """[(mesh index, block with refs and ms zeroed)] of the LAND chunk."""
    c = chunk(path, b'LAND') or b''
    out, o = [], 0
    while len(c) - o >= 8:
        ix, nb = struct.unpack_from('<II', c, o)
        b = bytearray(c[o + 8:o + 8 + nb])
        if len(b) >= 76:
            b[0:4] = b'\0' * 4
            b[72:76] = b'\0' * 4
        out.append((ix, bytes(b)))
        o += 8 + nb
    return out


def ypos(path, nm):
    p = places(path)
    return struct.unpack('<9f', p[nm])[1] if p and nm in p else None


def pos(path, nm):
    p = places(path)
    return struct.unpack('<9f', p[nm])[:3] if p and nm in p else None


def state(path):
    """Places, records and landscapes of a file: what undo must put back."""
    return places(path), rb_part(chunk(path, b'ANIM')), lands(path)


# ---- on landscapes -----------------------------------------------------------------------------

def s_drop():
    print('-- bodies of every shape dropped and slid on hills, mountains, canyons, dunes (moved, scaled, turned): places and rbinfo at 6 frames --')
    rng = random.Random(SEED)
    nbad = touched = moved = 0
    for run_ in range(RUNS):
        kind = LKINDS[run_ % 4]
        res = rng.choice([65, 129, 257])
        size = rng.choice([15, 20, 30, 50])
        base = f'{T}/ld{run_}.bee'
        steps = land_scene(rng, base, kind, rng.randint(2, 7), res, size)
        fr, ip = run(base, steps, FRAMES, f'ld{run_}_')
        if sane(fr, ip, f'landscape {run_} ({kind} {res} size {size})'):
            nbad += 1
        if ip and max(r[1] for r in ip) > 0:
            touched += 1
        p0, p1 = places(fr[1]), places(fr[-1])
        if p0 and p1 and p0 != p1:
            moved += 1
        if run_ == 0:
            # the same run again: the same bodies (the step is deterministic)
            fr2, ip2 = run(base, steps, FRAMES, f'ld{run_}b_')
            check(ip2 == ip and [places(f) for f in fr2] == [places(f) for f in fr], 'the same landscape scene run twice: the same places and rbinfo')
    check(nbad == 0, f'{RUNS - nbad} of {RUNS} landscape scenes: every file reads back, places and rbinfo finite at {len(FRAMES)} frames')
    check(touched >= RUNS * 3 // 4 and moved == RUNS, f'bodies touched the landscape in {touched}, moved in {moved} of {RUNS}')
    # resting: a box set down flat stays on the surface (does not fall through)
    lines = clear_lines() + ['op("landscape.add", "hills res 129 size 30 seed 4")', ys('Landscape', 1, 2, 0.6), 'add("cube", "R", 1, add_y, 2)', 'scale("R", 0.3)',
                             'y0 = add_y', f'op("file.save_as", "{T}/rest.bee")', 'print("Y", y0 - 0.6)']
    so = make('\n'.join(lines))
    m = re.search(r'^Y (\S+)', so, re.M)
    fr, ip = run(f'{T}/rest.bee', ['@Landscape', 'rigid.add passive mesh', '@R', 'rigid.add active box'], [30, 120, 240], 'rest')
    bad = sane(fr, ip, 'resting box')
    y = ypos(fr[-1], 'R')
    h = float(m.group(1)) if m else None
    check(not bad and y is not None and h is not None and h - 1.0 < y < h + 1.0, f'a box on the hills comes to rest on them (y {y}, the ground {h})')


def s_paint():
    print('-- a painted landscape: rock (friction 0.9, bounce 0.6) and snow (friction 0.02): sliding and bouncing by the paint under the body --')
    lines = clear_lines() + ['op("landscape.add", "flat res 129 size 40")',
                             'op("landscape.paint", "add rock friction 0.9 bounce 0.6")', 'op("landscape.paint", "add snow friction 0.02 bounce 0")',
                             'op("landscape.brush", "rock -8 0 radius 7 strength 1")', 'op("landscape.brush", "rock -8 0 radius 7 strength 1")',
                             'op("landscape.brush", "snow 8 0 radius 7 strength 1")', 'op("landscape.brush", "snow 8 0 radius 7 strength 1")',
                             'op("landscape.brush", "snow 0 -9 radius 5 strength 0.4")']
    for nm, x, z, y in (('Rk', -10, 0, 0.31), ('Sn', 5, 0, 0.31), ('Mx', -3, -9, 0.31), ('Br', -8, 4, 3), ('Bs', 8, 4, 3)):
        lines += [f'add("{"sphere" if nm in ("Br", "Bs") else "cube"}", "{nm}", {x}, {y}, {z})', f'scale("{nm}", 0.3)']
    lines.append(f'op("file.save_as", "{T}/pa.bee")')
    make('\n'.join(lines))
    steps = ['@Landscape', 'rigid.add passive mesh', '@Rk', 'rigid.add active box velocity 4 0 0', '@Sn', 'rigid.add active box velocity 4 0 0',
             '@Mx', 'rigid.add active box velocity 4 0 0', '@Br', 'rigid.add active sphere bounce 0', '@Bs', 'rigid.add active sphere bounce 0']
    fr, ip = run(f'{T}/pa.bee', steps, [10, 30, 60, 90], 'pa')
    bad = sane(fr, ip, 'painted')
    check(not bad, 'bodies on rock and snow: every file reads back, places and rbinfo finite at 4 frames')
    a = pos(fr[-1], 'Rk')
    b = pos(fr[-1], 'Sn')
    c = pos(fr[-1], 'Mx')
    da, db, dc = (a[0] + 10) if a else 0, (b[0] - 5) if b else 0, (c[0] + 3) if c else 0
    print(f'       slid: on rock {da:.3f} m, on snow {db:.3f} m, on half snow {dc:.3f} m')
    check(a and b and c and db > da * 1.5 and da < dc < db, 'a box slides further on snow than on rock, between them on a thin coat')
    yb = [ypos(fr[k], 'Br') for k in range(len(fr))]
    ys_ = [ypos(fr[k], 'Bs') for k in range(len(fr))]
    check(None not in yb + ys_ and yb != ys_, f'a ball bounces otherwise on rock than on snow ({[round(x, 3) for x in yb if x is not None]} / {[round(x, 3) for x in ys_ if x is not None]})')


def s_many():
    print('-- five landscapes: four heightfields, the fifth a plain mesh (HF_MAX 4); bodies on each --')
    rng = random.Random(SEED + 3)
    lines = clear_lines()
    names = []
    for k in range(5):
        lines.append(f'op("landscape.add", "{LKINDS[k % 4]} res 65 size 12 seed {k}")')
        lines.append(f'nm = name(count() - 1)\nrename(nm, "L{k}")\nmove("L{k}", {k * 14 - 28}, 0, 0)')
        names.append(f'L{k}')
    steps = []
    for k in range(5):
        steps += [f'@L{k}', 'rigid.add passive mesh']
    for k in range(10):
        body(rng, lines, steps, f'B{k}', (k % 5) * 14 - 28 + rnd(rng, -2, 2), rnd(rng, -2, 2), land=f'L{k % 5}')
    lines.append(f'op("file.save_as", "{T}/many.bee")')
    so = make('\n'.join(lines))
    fr, ip = run(f'{T}/many.bee', steps, [5, 20, 45, 90], 'many', info=INFO + [6, 7])
    bad = sane(fr, ip, 'five landscapes')
    check(not bad, 'bodies on five landscapes: every file reads back, places and rbinfo finite at 4 frames')
    p = places(fr[0]) or {}
    check(all(n in p for n in names), f'five landscapes made ({sorted(x for x in p if x.startswith("L"))}) {so[-200:] if not p else ""}')
    # no body fell through the fifth, a mesh (a fast body can tunnel through a
    # heightfield at some seeds: those are only listed)
    low = [k for k in range(10) if (ypos(fr[-1], f'B{k}') or -1e9) < -20]
    check(not [k for k in low if k % 5 == 4], f'no body fell through the fifth, a mesh (fell: {low})')


def s_water():
    print('-- water: an island\'s sea and a water plane; light boxes float, heavy ones sink; a hidden water ignored --')
    for tag, setup, at in (
            ('island', ['op("landscape.add", "island res 129 size 60 seed 2")'], (-27, -27)),
            ('plane', ['add("cube", "G", 0, -6, 0)', 'scale("G", 10, 0.5, 10)', 'op("landscape.add_water", "30")', 'scale("Water", 0.4, 1, 0.4)'], (-5, 0)),
            ('sea', ['op("landscape.add", "dunes res 65 size 40 seed 1")', 'move("Landscape", 0, -3, 0)', 'select("Landscape")', 'op("landscape.sea", "")', 'move("Water", 0, 0.5, 0)'], (5, 5))):
        for hidden in (False, True):
            lines = clear_lines() + setup + ['wy = get("Water", "y")', 'print("W", wy)']
            if hidden:
                lines.append('set("Water", "hidden", 1)')
            boxes = [('Wd', 0, 'box mass 2'), ('St', 2, 'box mass 2000'), ('Hv', 3, 'box mass 400'), ('Sp', 4, 'sphere mass 1'), ('Hu', 6, 'hull mass 3 velocity 1 0 0'), ('Cp', 8, 'capsule mass 2'), ('Ou', -4, 'box mass 2')]
            for nm, dx, _ in boxes:
                lines += [f'add("{"sphere" if nm == "Sp" else "cube"}", "{nm}", {at[0] + dx}, wy + 2, {at[1] + dx * 0.3})', f'scale("{nm}", 0.4)', f'rotate("{nm}", 0.2, 0.3, 0.1)']
            lines.append(f'op("file.save_as", "{T}/w{tag}{int(hidden)}.bee")')
            so = make('\n'.join(lines))
            m = re.search(r'^W (\S+)', so, re.M)
            steps = ['@Landscape', 'rigid.add passive mesh'] if tag != 'plane' else ['@G', 'rigid.add passive box']
            for nm, _, a in boxes:
                steps += [f'@{nm}', f'rigid.add active {a}']
            fr, ip = run(f'{T}/w{tag}{int(hidden)}.bee', steps, [10, 40, 90, 160], f'w{tag}{int(hidden)}')
            bad = sane(fr, ip, f'water {tag}{" hidden" if hidden else ""}')
            wy = float(m.group(1)) if m else None
            y = {nm: ypos(fr[-1], nm) for nm, _, _ in boxes}
            print(f'       {tag}{" (hidden)" if hidden else ""}: the water at {wy}; at the end {y}')
            check(not bad, f'{tag}{" (the water hidden)" if hidden else ""}: every file reads back, places and rbinfo finite at 4 frames')
            if wy is None or None in y.values():
                check(False, f'{tag}: the water and bodies are there ({so[-300:]})')
                continue
            if not hidden:
                check(all(wy - 0.1 < y[k] < wy + 1.2 for k in ('Wd', 'Sp', 'Cp')) and y['Hv'] < y['Wd'] - 0.3 and y['St'] < wy - 1,
                      f'{tag}: the light bodies float at the level, a heavier box lower in it, the stone sinks')
                if tag == 'plane':
                    check(y['Ou'] < wy - 1, f'plane: a light box past the (scaled) water\'s edge falls past its level ({y["Ou"]})')
            else:
                check(y['Wd'] < wy - 0.5, f'{tag}: a hidden water does not hold the light box up')


def s_shatter():
    print('-- glued pieces (object.shatter ... glue) falling on landscapes: the glue breaking where they hit, places and rbinfo at 5 frames --')
    nbad = broke = 0
    cases = [('hills res 65 size 20 seed 1', 'cube', 'shards count 14 seed 3 glue 60'),
             ('mountains res 129 size 30 seed 2', 'cube', 'bricks size 0.5 0.4 0.4 glue 40'),
             ('dunes res 65 size 16 seed 5', 'sphere', 'shards count 20 seed 9 glue 400')]
    for k, (land, kind, arg) in enumerate(cases):
        base = f'{T}/lsh{k}.bee'
        make('\n'.join(clear_lines() + [f'op("landscape.add", "{land}")', ys('Landscape', 0.5, -0.3, 4), f'add("{kind}", "C", 0.5, add_y, -0.3)',
                                           'scale("C", 0.7)', 'rotate("C", 0.3, 0.5, 0.2)', f'op("file.save_as", "{base}")']))
        steps = ['@Landscape', 'rigid.add passive mesh', '@C', f'object.shatter {arg}']
        fr, ip = run(base, steps, [8, 30, 50, 80, 120], f'lsh{k}_')
        if sane(fr, ip, f'glued pieces {k} ({arg})'):
            nbad += 1
        if ip and ip[-1][7] > 0 and ip[-1][1] > 0:
            broke += 1
    check(nbad == 0, f'{len(cases) - nbad} of {len(cases)} glued shatters on landscapes: every file reads back, places and rbinfo finite at 5 frames')
    check(broke == len(cases), f'the glue broke where the pieces hit the landscape in {broke} of {len(cases)}')


def s_impact():
    print('-- shatter on impact on landscapes: the objects dropped on hills and mountains break when they hit (the pieces on the landscape at once) --')
    nbad = broke = 0
    cases = [('hills res 65 size 20 seed 1', 'cube', 'shards count 12 seed 3 impact 3'),
             ('mountains res 129 size 30 seed 2', 'sphere', 'preset glass count 16 seed 4'),
             ('dunes res 65 size 16 seed 5', 'cube', 'bricks size 0.5 0.4 0.4 glue 30 impact 2')]
    info = [16, 1, 20, 21, 2, 7]
    for k, (land, kind, arg) in enumerate(cases):
        base = f'{T}/lim{k}.bee'
        make('\n'.join(clear_lines() + [f'op("landscape.add", "{land}")', ys('Landscape', 0.5, -0.3, 3), f'add("{kind}", "C", 0.5, add_y, -0.3)',
                                           'scale("C", 0.7)', 'rotate("C", 0.3, 0.5, 0.2)', f'op("file.save_as", "{base}")']))
        steps = ['@Landscape', 'rigid.add passive mesh', '@C', f'object.shatter {arg}']
        fr, ip = run(base, steps, [5, 10, 15, 20, 30, 60], f'lim{k}_', info=info)
        bad = sane(fr, ip, f'impact {k} ({arg})')
        if ip and ip[-1][3] > 0 and ip[-1][1] > 0:
            broke += 1
        if bad:
            nbad += 1
    check(nbad == 0, f'{len(cases) - nbad} of {len(cases)} shatters on impact on landscapes: every file reads back, places and rbinfo finite at 6 frames')
    check(broke == len(cases), f'broken where they hit the landscape, the pieces on it, in {broke} of {len(cases)}')
    # undo and redo with the timeline
    base = f'{T}/lim0.bee'
    seq = ['@Landscape', 'rigid.add passive mesh', '@C', f'object.shatter {cases[0][2]}', 'edit.undo', '#save', 'edit.redo', '#save', 'anim.frame 25', '#save',
           'anim.frame 8', '#save', 'edit.undo', '#save', 'anim.frame 30', '#save']
    a = ['--op', f'file.open {base}']
    got = []
    for c in seq:
        if c == '#save':
            p = f'{T}/limp{len(got)}.bee'
            a += ['--op', f'file.save_as {p}']
            got.append(p)
        elif c.startswith('@'):
            a += ['--select', c[1:]]
        else:
            a += ['--op', c]
    r = port(*a)
    ok = r is not None and r.returncode == 0 and all(os.path.exists(x) for x in got)
    hid = [sum(1 for ob in beefile.objects(x) if ob['name'].startswith('C_') and not ob['flags'] & 0x200) for x in got] if ok else []
    npc = [sum(1 for ob in beefile.objects(x) if ob['name'].startswith('C_')) for x in got] if ok else []
    check(len(hid) == 6 and npc[0] == 0 and npc[1] > 0 and hid[2] > 0 and hid[3] == 0 and npc[4] == 0 and npc[5] == 0,
          f'undone: no pieces; redone: there; broken at 25, whole at 8; undone at 8: gone (pieces {npc}, shown {hid})')


# ---- the cache, undo ------------------------------------------------------------------------

def cache_base():
    rng = random.Random(SEED + 5)
    base = f'{T}/lca.bee'
    steps = land_scene(rng, base, 'hills', 4, 65, 20, place=False)
    return base, steps


def s_cache():
    print('-- the cache with a landscape: back plays cached frames, an edit drops them, a brush, bake, sim.free, the baked file played again --')
    base, steps = cache_base()
    seq = steps + ['anim.frame 30', '#save', '?', 'anim.frame 12', '#save', '?', 'anim.frame 30', '#save', '?',
                   '@Landscape', 'landscape.brush raise 0 0 radius 6 strength 1', 'anim.frame 35', '#save', '?', 'anim.frame 1', '#save',
                   'anim.key B1:y 1 9', 'anim.frame 12', '#save', '?', 'sim.bake rigid', '#save', '?', 'anim.frame 40', '#save', '?',
                   '@Landscape', 'rigid.add passive mesh friction 0.1', 'anim.frame 41', '#save', '?', 'sim.free rigid', 'anim.frame 20', '#save', '?']
    a = ['--op', f'file.open {base}']
    saves = []
    for s in seq:
        if s == '#save':
            pp = f'{T}/lcap{len(saves)}.bee'
            a += ['--op', f'file.save_as {pp}']
            saves.append(pp)
        elif s == '?':
            for x in ('rbinfo:25', 'rbinfo:16', 'rbinfo:0', 'rbinfo:1', 'cacheinfo:0', 'cacheinfo:3'):
                a += ['--print-anim', x]
        elif s.startswith('@'):
            a += ['--select', s[1:]]
        else:
            a += ['--op', s]
    r = port(*a)
    vals = re.findall(r'^(rbinfo|cacheinfo):\d+=(\S+)', r.stderr if r else '', re.M)
    qp = [[str(float(v)) for _, v in vals[k:k + 6]] for k in range(0, len(vals), 6)]
    bad = [f for f in saves if places(f) is None or rb_part(chunk(f, b'ANIM')) is None or not lands(f)]
    check(not bad, f'{len(saves) - len(bad)} of {len(saves)} steps\' files read back with places, records and the landscape')
    check(len(qp) == 9 and all(math.isfinite(float(x)) for q in qp for x in q), f'played, the hash, bodies, contacts, the cache at {len(qp)} points, all finite')
    check(len(qp) >= 2 and qp[1][0] == '1.0' and float(qp[0][3]) > 0, f'going back played a cached frame; the bodies touched the landscape ({qp[:2]})')
    check(len(saves) > 6 and chunk(saves[6], b'SIMC') is not None, 'the baked file has its cache (SIMC)')
    # the baked file played at frames 33 and 9, twice: the same
    pp = saves[6]
    outs = []
    for k in range(2):
        port('--op', f'file.open {pp}', '--op', 'anim.frame 33', '--op', f'file.save_as {T}/lb{k}a.bee', '--op', 'anim.frame 9', '--op', f'file.save_as {T}/lb{k}b.bee')
        outs.append((places(f'{T}/lb{k}a.bee'), places(f'{T}/lb{k}b.bee')))
    check(outs[0][0] and outs[0][1] and outs[0] == outs[1], 'the baked landscape file played at frames 33 and 9, twice: the same places')
    # save, open, save: the same landscape and records
    port('--op', f'file.open {pp}', '--op', f'file.save_as {T}/lbr.bee')
    check(state(f'{T}/lbr.bee') == state(pp) and chunk(f'{T}/lbr.bee', b'SIMC') == chunk(pp, b'SIMC'), 'the baked file saved again: the same places, records, landscape and cache')


UNDO_SEQ = ['@Landscape', 'rigid.add passive mesh', '@B0', 'rigid.add active box', '@B1', 'rigid.add active sphere', 'anim.frame 25', '#save',
            'edit.undo', '#save', 'edit.redo', '#save', 'anim.frame 40', '#save', 'anim.frame 1', '#save',
            '@Landscape', 'landscape.brush raise 0 0 radius 5 strength 1', 'anim.frame 30', '#save', 'edit.undo', 'anim.frame 31', '#save',
            '@Landscape', 'rigid.remove', 'anim.frame 33', '#save', 'edit.undo', 'anim.frame 34', '#save', 'sim.bake', 'anim.frame 22', '#save',
            '@Landscape', 'object.delete', 'anim.frame 5', '#save', 'edit.undo', 'anim.frame 50', '#save', 'edit.undo', 'edit.undo', '#save']


def s_undo():
    print('-- undo and redo with a landscape: bodies added, a brush stroke mid-simulation, the landscape removed and deleted, a bake --')
    base = f'{T}/lun.bee'
    lines = clear_lines() + ['op("landscape.add", "hills res 65 size 20 seed 1")']
    for k, (x, z) in enumerate(((0.5, 0.3), (-1, 1.2))):
        lines += [ys('Landscape', x, z, 1.5), f'add("{["cube", "sphere"][k]}", "B{k}", {x}, add_y, {z})', f'scale("B{k}", 0.35)']
    lines.append(f'op("file.save_as", "{base}")')
    make('\n'.join(lines))
    a = ['--op', f'file.open {base}']
    got = []
    for c in UNDO_SEQ:
        if c == '#save':
            p = f'{T}/lup{len(got)}.bee'
            a += ['--op', f'file.save_as {p}']
            got.append(p)
        elif c.startswith('@'):
            a += ['--select', c[1:]]
        else:
            a += ['--op', c]
    r = port(*a)
    check(r is not None and r.returncode == 0 and len(got) == UNDO_SEQ.count('#save') and all(places(x) is not None for x in got),
          f'{len(got)} steps\' files read back')
    if not all(places(x) is not None for x in got):
        return
    bad = [k for k, x in enumerate(got) if not all(math.isfinite(v) for b in places(x).values() for v in struct.unpack('<9f', b))]
    check(not bad, f'every place finite in every step ({bad})')
    pl = [places(x) for x in got]
    check(len(set(tuple(sorted(p.items())) for p in pl if p)) >= 5, 'the steps hold different places')
    ls = [tuple(lands(x)) for x in got]
    check(len(set(ls)) >= 3 and any(not x for x in ls), f'the steps hold different landscapes (the brushed, the deleted): {len(set(ls))}')
    # the brush undone: the landscape as before it; the delete undone: it is back
    check(ls[6] == ls[4] and ls[5] != ls[4], 'a brush stroke undone: the landscape as it was')
    check(not ls[10] and ls[11] == ls[9], 'the landscape deleted, then undone: back as it was')
    check(rb_part(chunk(got[8], b'ANIM')) == rb_part(chunk(got[6], b'ANIM')) and rb_part(chunk(got[7], b'ANIM')) != rb_part(chunk(got[6], b'ANIM')),
          'its body removed, then undone: the records as they were')


# ---- stability, time --------------------------------------------------------------------------

def s_fuzz():
    print('-- fuzz: landscapes, water, bodies, brushes, frames back and forth, undo (debug build): no panic, no hang --')
    rng = random.Random(SEED + 7)
    bad = 0
    n = max(3, RUNS // 2)
    for run in range(n):
        base = f'{T}/lfz{run}.bee'
        steps = land_scene(rng, base, rng.choice(LKINDS + ['island', 'flat']), rng.randint(1, 6), rng.choice([65, 129]), rng.choice([10, 30, 80]))
        a = ['--op', f'file.open {base}']
        for s in steps:
            a += ['--select', s[1:]] if s.startswith('@') else ['--op', s]
        for _ in range(30):
            k = rng.random()
            if k < 0.15:
                a += ['--op', f'landscape.add {rng.choice(LKINDS + ["island", "flat"])} res 65 size {rng.choice([5, 20, 100])}', '--op', f'rigid.add passive {rng.choice(["mesh", "mesh", "box", "hull"])}']
            elif k < 0.25:
                a += ['--select', 'Landscape', '--op', f'landscape.brush {rng.choice(["raise", "lower", "rock", "snow", "smooth"])} {rnd(rng, -5, 5)} {rnd(rng, -5, 5)} radius {rnd(rng, 1, 9)}']
            elif k < 0.32:
                a += ['--op', rng.choice(['landscape.sea', 'landscape.add_water 40', 'landscape.paint add rock friction 2 bounce 3', 'landscape.paint auto'])]
            elif k < 0.6:
                a += ['--op', f'anim.frame {rng.choice([1, 2, 5, 13, 40, 7, 0, 60])}']
            elif k < 0.7:
                a += ['--op', rng.choice(['edit.undo', 'edit.redo'])]
            elif k < 0.78:
                a += ['--op', rng.choice(['sim.bake', 'sim.free', 'sim.bake rigid'])]
            elif k < 0.88:
                a += ['--select', rng.choice(['Landscape', 'Water', 'B0', 'B1']), '--op', rng.choice(['rigid.remove', 'object.delete', 'object.duplicate', 'object.hide', 'rigid.add passive mesh'])]
            else:
                a += ['--select', f'B{rng.randrange(6)}', '--op', f'rigid.add active {rng.choice(SHAPES)} velocity {rnd(rng, -9, 9)} 0 {rnd(rng, -9, 9)}']
        a += ['--op', f'file.save_as {T}/lfz.bee']
        r = port(*a, ok=False, timeout=900)
        if r is None or r.returncode != 0 or 'panic' in (r.stderr or '') or 'leak' in (r.stderr or '').lower():
            bad += 1
            print('       BeeModel failed:', r and r.stderr[-800:])
    check(bad == 0, f'{n - bad} of {n} fuzz runs ended cleanly')


def s_perf():
    print('-- time: 100 boxes and spheres on a 257 landscape, frames 1..61, pinned to one CPU (release build) --')
    lines = clear_lines() + ['op("landscape.add", "hills res 257 size 40 seed 3")', 'k = 0', 'for i in 0..5 {', ' for j in 0..20 {', '  n = "P" + str(k)',
                             '  x = (j % 5) * 1.6 - 3.2 + i * 0.05', '  z = floor(j / 5) * 1.6 - 3.2', '  h = height("Landscape", x, z)',
                             '  if (k % 3) == 0 { add("sphere", n, x, h + 0.5 + i * 0.8, z) } else { add("cube", n, x, h + 0.5 + i * 0.8, z) }',
                             '  scale(n, 0.3)', '  k += 1', ' }', '}', f'op("file.save_as", "{T}/lperf.bee")']
    make('\n'.join(lines))
    a = ['--op', f'file.open {T}/lperf.bee', '--select', 'Landscape', '--op', 'object.select_all', '--op', 'object.select_all', '--op', 'rigid.add active box',
         '--select', 'Landscape', '--op', 'rigid.add passive mesh', '--op', 'anim.frame 1', '--op', 'anim.frame 61', '--print-anim', 'rbinfo:4', '--print-anim', 'rbinfo:16']
    best = None
    hs = []
    for _ in range(2):
        r = port(*a, binary=REL)
        m = re.search(r'rbinfo:4=(\S+)', r.stderr if r else '')
        if m:
            v = float(m.group(1)) / 60
            best = v if best is None else min(best, v)
        mh = re.search(r'rbinfo:16=(\S+)', r.stderr if r else '')
        hs.append(float(mh.group(1)) if mh else None)
    print(f'       a frame: {best} ms (hash {hs})')
    check(best is not None and math.isfinite(best) and best >= 0, f'the step on a landscape timed ({best} ms a frame)')
    check(None not in hs and math.isfinite(hs[0]) and hs[0] == hs[1], 'the same bodies after 60 frames, run twice (rbinfo(16))')


SECTIONS = ['s_drop', 's_paint', 's_many', 's_water', 's_shatter', 's_impact', 's_cache', 's_undo', 's_fuzz', 's_perf']


def main():
    print(f'seed {SEED}')
    try:
        for s in (ONLY or SECTIONS):
            if s not in SECTIONS:
                continue
            globals()[s]()
    finally:
        if not os.environ.get('RB_KEEP'):
            shutil.rmtree(T, ignore_errors=True)
        else:
            print('kept', T)
    moved = [k for k in set(_REAL0) | set(_real_config()) if _REAL0.get(k) != _real_config().get(k)]
    check(not moved, f'the user\'s ~/.config untouched by the run ({", ".join(moved) or "nothing moved"})')
    print(f'rbland: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
