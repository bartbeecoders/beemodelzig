#!/usr/bin/env python3
"""Particle systems and liquid (particles.zig, liquid.zig, partui.zig), BeeModel
on its own, done two ways in the same build and compared: a BeeScript (--run:
emit(), frame(), particles()) and the console's lines (--op, --dump-particles):

  * particles bit for bit at several frames (place, velocity, age, lifetime,
    size, id, colour of each: the first ones exactly, all of them by weighted
    sums in doubles): every source (faces, volume, vertices, point, fill,
    events), rates and bursts, start / end / max, spread and directions,
    random seeds, drag, gravity factors, force fields and groups, collisions
    with the Ground and rigid bodies (passive, moving: bounce, friction, die,
    stick, split) and landscapes (their heights: moved, scaled, hidden, with
    the Ground, a box, water planes; a liquid poured on them), events (hits,
    deaths, births, a liquid's spray), liquids (domains, the Ground as a
    wall, viscosity presets, vorticity, tension, substeps, iterations, moving
    bodies pushed and pushing back: their places after), on 1 and 8 threads;
  * the presets (Add > Particles) and their emitters; the words particles.add
    / set / remove take and the ones they do not (the console's lines);
  * the PSYS chunk byte for byte both ways, damaged chunks read alike; the
    cache: frames recorded, played back (going back on the timeline),
    sim.bake / sim.free, the SIMC chunk (all but its keys), a baked file
    played the same both ways; staleness (a change drops the cache); undo and
    redo with the timeline; the liquid's surface (file.export_liquid OBJ files
    byte for byte both ways);
  * random settings on the debug build (no crash, no hang), the time a step
    takes with 10k particles and with a liquid of a few thousand (a release
    build, one CPU: said), and memory over a long run.

    python3 tests/particles.py BIN [runs=6] [seed]

BEE_CPU (default 14) pins every run; PT_ONLY=s_emit,s_files ... runs some;
PT_REL=path: a release build for the timing (else BIN).
"""
import math, os, random, re, struct, subprocess, sys, tempfile, shutil, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile
import pwd as _pwd


def _real_config():
    """The user's real ~/.config/beemodel*: what must not change under a run."""
    h = _pwd.getpwuid(os.getuid()).pw_dir
    out = {}
    for d in ('.config/beemodel-zig', '.config/beemodel'):
        p = os.path.join(h, d)
        if os.path.isdir(p):
            for n in sorted(os.listdir(p)):
                st = os.stat(os.path.join(p, n))
                out[f'{d}/{n}'] = (st.st_size, st.st_mtime_ns)
    return out


_REAL0 = _real_config()

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 6
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '14')
ONLY = [x for x in os.environ.get('PT_ONLY', '').split(',') if x]
REL = os.environ.get('PT_REL', BIN)
FULL = 40  # particles compared exactly a frame (the rest by sums)
FAILS = []
T = tempfile.mkdtemp(prefix='beeparts-', dir=os.environ.get('BEEPARTS_TMP', '/tmp'))
import atexit
if not os.environ.get('PT_KEEP'):
    atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, XDG_CACHE_HOME='', BEEMODEL_GPU='off')
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]


def bits(x):
    return struct.unpack('<I', struct.pack('<f', f32(x)))[0]


def fb(u):
    return struct.unpack('<f', struct.pack('<I', u))[0]


# ---- the two routes: a script, the console --------------------------------------------------

def orig(code, threads=None, timeout=1200):
    """BeeModel runs a script (--run): its stdout. (The name from when another
    program ran it.)"""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    set_threads(threads)
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        return 'timeout'
    finally:
        set_threads(None)
    return r.stdout


def set_threads(n):
    d = f'{T}/.config/beemodel-zig'
    os.makedirs(d, exist_ok=True)
    open(f'{d}/prefs', 'w').write(f'threads {n}\n' if n else '')


def port(*a, binary=None, ok=True, timeout=1200, threads=None):
    set_threads(threads)
    for f in ('log.txt',):
        if os.path.exists(f'{T}/{f}'):
            os.remove(f'{T}/{f}')
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary or BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *a],
                           capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        check(False, f'BeeModel hung: {a[:6]}')
        return None
    finally:
        set_threads(None)
    if ok and r.returncode != 0:
        print(r.stderr[-1500:])
        check(False, f'BeeModel stopped ({r.returncode}): {a[:6]}')
    return r


def plog():
    return open(f'{T}/log.txt', errors='replace').read() if os.path.exists(f'{T}/log.txt') else ''


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def pops(steps):
    """Steps for the console: '--flag value' as they are, the rest console lines."""
    a = []
    for s in steps:
        if s.startswith('--'):
            a += s.split(' ', 1)
        elif s:
            a += ['--op', s]
    return a


# ---- every particle, both routes ------------------------------------------------------------

# a float's exact value through print (6 decimals): its mantissa and exponent as one integer
PRE = """fn enc(v) {
 if v == 0 { return 0 }
 a = abs(v)
 e = 0
 while a >= 16777216 { a = a / 2
  e = e + 1 }
 while a < 8388608 { a = a * 2
  e = e - 1 }
 n = (e + 200) * 16777216 + a
 if v < 0 { n = 0 - n }
 return n
}
"""


def dec(t):
    n = int(round(float(t)))
    if n == 0:
        return 0
    sg = -1 if n < 0 else 1
    n = abs(n)
    return bits(sg * (n % 16777216) * 2.0 ** (n // 16777216 - 200))


def code_frame(f, full=FULL):
    c = f'frame({f})\nprint("N", particles(0), particles(19), particles(4))\nn = particles(0)\n'
    for k in range(6, 17):
        c += f'a = 0\nb = 0\nfor i in 0..n {{\n v = particles({k}, i)\n a = a + v\n b = b + v * (i + 1)\n}}\nprint("S", {k}, a*1000, b)\n'
    c += f'm = n\nif m > {full} {{ m = {full} }}\nfor i in 0..m {{\n print("P"'
    for k in range(6, 15):
        c += f', enc(particles({k}, i))'
    c += ', particles(15, i), particles(16, i))\n}\n'
    return c


def parse_orig(out):
    res, cur = [], None
    for ln in out.splitlines():
        w = ln.split()
        if not w:
            continue
        if w[0] == 'N':
            cur = {'n': [float(x) for x in w[1:]], 's': {}, 'p': []}
            res.append(cur)
        elif w[0] == 'S' and cur is not None and len(w) == 4:
            cur['s'][int(w[1])] = (float(w[2]), float(w[3]))
        elif w[0] == 'P' and cur is not None and len(w) == 12:
            cur['p'].append([dec(x) for x in w[1:10]] + [int(float(w[10])), int(float(w[11]))])
    return res


def port_frames(steps, frames, binary=None, threads=None, extra=()):
    d = f'{T}/d.txt'
    if os.path.exists(d):
        os.remove(d)
    a = pops(steps)
    for f in frames:
        a += ['--op', f'anim.frame {f}', '--dump-particles', d]
    r = port(*a, *extra, binary=binary, threads=threads)
    res, cur = [], []
    for ln in (open(d).read().splitlines() if os.path.exists(d) else []):
        w = ln.split()
        if w[0] == 'info':
            res.append({'info': w[1:], 'rows': cur})
            cur = []
        else:
            cur.append([int(x, 16) for x in w])
    return res


def sums(rows, k):
    a = b = 0.0
    for i, r in enumerate(rows):
        v = fb(r[k - 6]) if k < 15 else f32(float(r[k - 6]))  # (particles() gives ids and colours as floats)
        a = a + v
        b = b + v * (i + 1)
    return a * 1000, b


def close(a, b):
    return abs(a - b) <= 1e-6 + abs(a) * (2e-6 if abs(a) >= 1e15 else 2e-15)


def z0(r):
    return [0 if x == 0x80000000 else x for x in r]  # (print shows -0 as 0)


def compare(o, p, frames):
    bad = []
    if len(o) != len(frames):
        return [f'the script gave {len(o)} of {len(frames)} frames']
    if len(p) != len(frames):
        return [f'the console gave {len(p)} of {len(frames)} frames']
    for k, f in enumerate(frames):
        oo, rows = o[k], p[k]['rows']
        if int(oo['n'][0]) != len(rows):
            bad.append(f'frame {f}: {int(oo["n"][0])} / {len(rows)} particles')
            continue
        if float(p[k]['info'][3]) != oo['n'][1]:
            bad.append(f'frame {f}: hits {oo["n"][1]} / {p[k]["info"][3]}')
        for j, (a, b) in enumerate(zip(oo['p'], rows)):
            b = b[:9] + [int(f32(float(b[9])))] + b[10:]  # (particles() gives ids as floats: 2^30 + k rounded)
            if z0(a) != z0(b):
                bad.append(f'frame {f}: particle {j}: {[hex(x) for x in a]} / {[hex(x) for x in b]}')
                break
        for kk in range(6, 17):
            if kk not in oo['s']:
                bad.append(f'frame {f}: no sum {kk}')
                break
            so, sp = oo['s'][kk], sums(rows, kk)
            if not (close(so[0], sp[0]) and close(so[1], sp[1])):
                bad.append(f'frame {f}: the sums of {kk}: {so} / {sp}')
                break
    return bad


def base(lines, name='base'):
    """A scene made by a script, saved: (its path)."""
    p = f'{T}/{name}.bee'
    orig('\n'.join(lines) + f'\nop("file.save_as", "{p}")\n')
    return p


def run_both(base_path, emits, frames, sel='Cube', extra_o=(), extra_p=(), binary=None, threads=None, tag=''):
    """emit() / particles.add of each settings on sel, then the frames both ways:
    (problems, [(the script's counts, the console's)])."""
    code = PRE + (f'op("file.open", "{base_path}")\n' if base_path else '') + f'select("{sel}")\n'
    code += ''.join(x + '\n' for x in extra_o)
    code += ''.join(f'emit("{sel}", "{esc(e)}")\n' for e in emits)
    code += ''.join(code_frame(f) for f in frames)
    o = parse_orig(orig(code, threads=threads))
    steps = ([f'file.open {base_path}'] if base_path else []) + [f'--select {sel}', *extra_p] + [f'particles.add {e}' for e in emits]
    p = port_frames(steps, frames, binary=binary, threads=threads)
    bad = compare(o, p, frames)
    info = [(o[k]['n'] if k < len(o) else None, p[k]['info'][:4] if k < len(p) else None) for k in range(len(frames))]
    return bad, info


def same(name, base_path, emits, frames, any_ok=False, **kw):
    bad, info = run_both(base_path, emits, frames, **kw)
    last = info[-1] if info else None
    n = int(last[0][0]) if last and last[0] else -1
    # (with any_ok an empty last frame passes when an earlier one had particles:
    # a short-lived burst is gone by then both ways)
    seen = max((int(i[0][0]) for i in info if i and i[0]), default=-1)
    check(not bad and (n > 0 or (any_ok and seen > 0)) or (not bad and kw.get('empty_ok')), f'{name}: {len(frames)} frames bit for bit both ways ({n} particles at the last' +
          (f', {int(last[0][1])} hits' if last and last[0] and last[0][1] else '') + ')' + ('' if not bad else ': ' + '; '.join(bad[:2])))
    return not bad


# ---- emission, motion -----------------------------------------------------------------------------

def s_emit():
    print('-- emission and motion: every source, rates, bursts, the random numbers', flush=True)
    b = base(['scale("Cube", 0.6, 1, 0.8)', 'rotate("Cube", 0.3, 0.5, 0.1)', 'move("Cube", 0.5, 1, -0.3)'])
    same('a burst from the origin, spread 30', b, ['from point burst 50 speed 5 spread 30 life 100'], [2, 5, 20])
    same('a rate (240 a second, half a second each)', b, ['rate 240 life 0.5 speed 1'], [3, 8, 30])
    same('the volume (gravity 0, speed 0)', b, ['from volume rate 2000 speed 0 gravity 0 life 10'], [3, 8, 30])
    same('faces: spread, drag, random size / life / speed', b, ['from faces rate 500 speed 3 spread 20 drag 2 size_random 0.5 life_random 0.5 speed_random 0.3'], [3, 8, 30])
    same('vertices, along a direction, a seed', b, ['from verts rate 300 speed 2 direction 1 0 0 spread 45 seed 7'], [3, 8, 30])
    same('a fill (its lattice)', b, ['from fill size 0.2 life 100 speed 0'], [3, 8])
    same('start, end, at most 300', b, ['rate 1000 max 300 life 2 start 3 end 10'], [3, 8, 30])
    same('emitting since before the scene\'s start (frame -20)', b, ['rate 120 start -20 life 3 speed 2'], [2, 10])
    same('two systems, a colour ramp, gravity 0.3, spread 180', b, ['from faces rate 200 color ff0000 color_end 00ff00 gravity 0.3 spread 180 name A', 'from point burst 300 start 5 speed 2 size_end 3 group 3 name B'], [4, 12, 25])
    rng = random.Random(SEED)
    for k in range(RUNS):
        src = rng.choice(['faces', 'volume', 'verts', 'point'])
        start = None
        if rng.random() < 0.7:
            em = f'rate {rng.choice([50, 400, 1500])}'
        else:
            nb, start = rng.randint(1, 900), rng.randint(0, 6)
            em = f'burst {nb} start {start}'
        s = (f'from {src} ' + em +
             f' speed {round(rng.uniform(-2, 8), 3)} spread {round(rng.uniform(0, 180), 2)} life {round(rng.uniform(0.2, 4), 3)}'
             f' life_random {round(rng.random(), 2)} speed_random {round(rng.random(), 2)} size {round(rng.uniform(0.01, 0.3), 3)}'
             f' size_random {round(rng.random(), 2)} drag {round(rng.uniform(0, 3), 2)} gravity {round(rng.uniform(-1, 2), 2)} seed {rng.randint(0, 99999)}')
        if rng.random() < 0.5:
            s += f' direction {round(rng.uniform(-1, 1), 3)} {round(rng.uniform(-1, 1), 3)} {round(rng.uniform(-1, 1), 3)}'
        if rng.random() < 0.3:
            s += f' max {rng.randint(10, 500)}'
        f1, f2 = rng.randint(1, 6), rng.randint(10, 30)
        if start is not None:
            f1 = max(f1, start + 1)  # (a burst: one frame after it)
        same(f'random {k + 1} ({s[:60]}...)', b, [s], [f1, f2], any_ok=True)


def s_fields():
    print('-- force fields', flush=True)
    b = base(['op("field.add_wind", "strength 3 gust 0.5")', 'op("field.add_turbulence", "strength 4 scale 1.5")',
              'op("field.add_vortex", "strength 2 lift 1")', 'op("field.add_attractor", "strength 5 groups 2")', 'move("Attractor", 2, 1, 0)'])
    same('wind, turbulence, a vortex, an attractor (group 2 only)', b, ['from faces rate 300 speed 1 life 3 drag 0.5 group 2 gravity 0.5', 'from point rate 200 life 2 group 0'], [5, 20, 50])


def s_collide():
    print('-- collisions: the Ground, rigid bodies; events', flush=True)
    g = base(['op("create.ground", "")'], 'ground')
    same('the Ground: bounce 0.5, friction 0.2', g, ['from point rate 200 speed 4 spread 40 collide on bounce 0.5 friction 0.2 life 5'], [10, 40, 80])
    b = base(['add("cube", "Box", 0, -2, 0)', 'scale("Box", 3, 0.5, 3)', 'rotate("Box", 0.2, 0, 0.1)', 'select("Box")', 'op("rigid.add", "passive box")'], 'box')
    for hit in ['on_hit die', 'on_hit stick', 'split 3', 'bounce 0.9 friction 0']:
        same(f'a passive box, {hit}', b, [f'from point rate 400 speed 3 spread 50 collide on life 4 {hit}'], [5, 20, 40])
    b2 = base(['add("sphere", "Ball", 0, 4, 0)', 'select("Ball")', 'op("rigid.add", "active sphere")', 'add("cube", "Floor", 0, -1, 0)',
               'scale("Floor", 5, 0.2, 5)', 'select("Floor")', 'op("rigid.add", "passive box")'], 'ball')
    same('a falling ball and a floor', b2, ['from point rate 600 speed 5 spread 25 collide on life 3 bounce 0.3'], [5, 15, 30, 45])
    same('hits and deaths born of (Rain -> Splash -> drops)', b2, ['from point rate 300 speed 5 spread 25 collide on life 3 name Rain on_hit die',
                                                                 'events hit Rain per 2 speed 1 spread 60 life 0.5 inherit 0.3 name Splash',
                                                                 'events died Splash per 1 speed 0.5 life 0.3'], [5, 15, 30])
    same('births born of (inherit 0.5)', b2, ['from point rate 300 speed 5 spread 25 life 0.5 name A', 'events born A per 2 speed 1 spread 60 life 0.5 inherit 0.5'], [5, 15])


def s_liquid():
    print('-- liquid', flush=True)
    b = base(['scale("Cube", 0.3, 0.3, 0.3)'], 'tank')
    same('water in a box', b, ['from fill size 0.1 life 1000 speed 0 liquid on domain -0.6 0 -0.6 0.6 2 0.6'], [3, 10, 25])
    same('honey, vorticity, tension, 4 substeps, 3 iterations', b, ['from fill size 0.1 life 1000 speed 0 liquid on viscosity honey vorticity 0.5 tension 0.2 domain -0.6 0 -0.6 0.6 2 0.6 substeps 4 iterations 3'], [3, 10, 25])
    same('a stream of oil (no box)', b, ['from point rate 400 speed 3 life 1000 size 0.05 liquid on viscosity oil'], [3, 10, 25])
    w = base(['op("create.ground", "")', 'scale("Cube", 0.4, 0.4, 0.4)', 'move("Cube", 0, 0.5, 0)', 'add("cube", "Box", 0.1, 1.6, 0)',
              'scale("Box", 0.15, 0.15, 0.15)', 'select("Box")', 'op("rigid.add", "active box mass 0.5")', 'add("cube", "Wall", 0.8, 0.5, 0)',
              'scale("Wall", 0.1, 1, 1)', 'select("Wall")', 'op("rigid.add", "passive box")'], 'pool')
    same('the Ground, a wall, a falling box', w, ['from fill size 0.08 life 1000 speed 0 liquid on domain -1 0 -1 1 3 1 collide on'], [2, 10, 30])
    same('spray from where it breaks', w, ['from fill size 0.08 life 1000 speed 0 liquid on collide on name W spray_speed 0.6 spray_neighbours 30',
                                         'events spray W per 1 speed 0.2 life 0.4 size 0.02'], [2, 10, 20])
    # the box the liquid pushes: its place after, both files
    po, pp = f'{T}/lo.bee', f'{T}/lp.bee'
    s = 'from fill size 0.08 life 1000 speed 0 liquid on domain -1 0 -1 1 3 1 collide on'
    orig(f'op("file.open", "{w}")\nselect("Cube")\nemit("Cube", "{s}")\nframe(30)\nop("file.save_as", "{po}")\n')
    port('--op', f'file.open {w}', '--select', 'Cube', '--op', f'particles.add {s}', '--op', 'anim.frame 30', '--op', f'file.save_as {pp}')
    oo, pp_ = beefile.objects(po) if os.path.exists(po) else None, beefile.objects(pp) if os.path.exists(pp) else None
    ob = [(o['loc'], o['rot']) for o in (oo or []) if o['name'] == 'Box']
    pb = [(o['loc'], o['rot']) for o in (pp_ or []) if o['name'] == 'Box']
    check(bool(ob) and bool(pb) and ob[0] == pb[0], f'the box the liquid pushes ends at the same place ({ob[0][0] if ob else None} / {pb[0][0] if pb else None})')


def s_threads():
    print('-- threads: 1 and 8', flush=True)
    b = base(['op("create.ground", "")', 'scale("Cube", 0.5, 0.5, 0.5)', 'move("Cube", 0, 1, 0)'], 'thr')
    em = ['from faces rate 20000 speed 2 spread 30 life 1.5 collide on bounce 0.4 name A', 'events hit A per 1 speed 1 life 0.3']
    same('20k a second hitting the Ground, its hits born of: 8 threads both', b, em, [6, 20], threads=8)
    p1 = port_frames([f'file.open {b}', '--select Cube'] + [f'particles.add {e}' for e in em], [6, 20], threads=1)
    p8 = port_frames([f'file.open {b}', '--select Cube'] + [f'particles.add {e}' for e in em], [6, 20], threads=8)
    check(len(p1) == 2 and p1 == p8 and len(p1[1]['rows']) > 10000, f'the same on 1 and 8 threads ({len(p1[1]["rows"]) if len(p1) == 2 else None} particles)')
    lq = ['from fill size 0.06 life 1000 speed 0 liquid on domain -0.6 0 -0.6 0.6 3 0.6']
    same('a liquid of 2000: 8 threads both', b, lq, [3, 12], threads=8)


# ---- landscapes as colliders ------------------------------------------------------------------------

HILLS = ['op("landscape.add", "hills res 65 size 20 seed 3")', 'move("Landscape", 1.5, -12, 0.5)', 'scale("Landscape", 1.2, 0.8, 1.1)',
         'move("Cube", 0, 8, 0)']  # (its heights 9.4 .. 21: -4.5 .. 4.8 here)


def s_landliq():
    print('-- a liquid poured onto a landscape', flush=True)
    b = base(HILLS, 'hills')
    same('a liquid poured onto the hills', b, ['from point rate 300 speed 6 direction 0 -1 0 spread 10 life 1000 size 0.08 liquid on collide on'], [20, 45, 70])
    same('a liquid in a domain over the hills', b, ['from point rate 300 speed 6 direction 0 -1 0 life 1000 size 0.1 liquid on collide on domain -3 -6 -3 3 9 3'], [30, 60])
    same('a liquid on the hills: 8 threads both', b, ['from point rate 600 speed 6 direction 0 -1 0 life 1000 size 0.08 liquid on collide on'], [20, 45], threads=8)


def s_land():
    print('-- landscapes as colliders: rain, a fountain, a burst on hills; with the Ground, boxes, water', flush=True)
    hills = HILLS
    b = base(hills, 'hills')
    cloud = base(hills + ['scale("Cube", 6, 0.1, 6)'], 'cloud')
    same('rain on moved, scaled hills (bounce 0.3, friction 0.2)', cloud, ['from faces rate 2000 speed 0 life 4 collide on bounce 0.3 friction 0.2'], [12, 30, 60])
    same('a fountain on the hills (bounce 0.6)', b, ['from point rate 400 speed 7 spread 25 collide on bounce 0.6 life 6'], [10, 40, 80])
    for hit in ['on_hit die', 'on_hit stick', 'split 3', 'bounce 0.9 friction 0']:
        same(f'a burst on the hills, {hit}', b, [f'from point burst 600 speed 5 spread 180 collide on life 5 {hit}'], [5, 25, 50], any_ok=True)
    same('hits on the hills born of (Rain -> Splash)', cloud, ['from faces rate 800 speed 6 direction 0 -1 0 life 4 collide on name Rain on_hit die',
                                                             'events hit Rain per 2 speed 1 spread 60 life 0.5 inherit 0.3 collide on'], [20, 40])
    # the Ground and a landscape together: half the rain over the hills, half over the Ground
    gl = base(['op("create.ground", "")', 'op("landscape.add", "hills res 65 size 12 seed 5")', 'move("Landscape", 4, -16, 0)',
               'move("Cube", 0, 8, 0)', 'scale("Cube", 9, 0.1, 4)'], 'groundland')  # (-6 .. 5: in and out of the Ground)
    same('the Ground and a landscape together', gl, ['from faces rate 2000 speed 0 life 4 collide on bounce 0.4'], [12, 30, 60])
    # two landscapes, one hidden; the sea and a water plane are not colliders, nor a landscape's own mesh
    two = base(['op("landscape.add", "canyon res 65 size 10 seed 2")', 'move("Landscape", -5, -10, 0)', 'scale("Landscape", 1, 0.3, 1)',
                'op("landscape.add", "dunes res 129 size 10 seed 4")', 'move("Landscape.001", 5, -1.5, 0)', 'scale("Landscape.001", 1, 1.5, 0.7)',
                'op("landscape.sea", "")', 'op("landscape.add_water", "30")', 'move("Cube", 0, 8, 0)', 'scale("Cube", 11, 0.1, 5)'], 'two')
    same('two landscapes (canyon, dunes), the sea, a water plane', two, ['from faces rate 2000 speed 0 life 4 collide on bounce 0.2 friction 0.5'], [12, 30, 60])
    hid = base(['op("landscape.add", "canyon res 65 size 10 seed 2")', 'move("Landscape", -5, -10, 0)', 'scale("Landscape", 1, 0.3, 1)',
                'op("landscape.add", "dunes res 65 size 10 seed 4")', 'move("Landscape.001", 5, -1.5, 0)', 'select("Landscape.001")', 'op("object.hide", "")',
                'move("Cube", 0, 8, 0)', 'scale("Cube", 11, 0.1, 5)'], 'hidden')
    same('a hidden landscape is not hit', hid, ['from faces rate 1500 speed 6 direction 0 -1 0 life 4 collide on bounce 0.2'], [30, 60])
    # a landscape and a rigid body's triangles: the first hit of both
    rb = base(hills + ['add("cube", "Box", 1, 5, 0.5)', 'scale("Box", 1.5, 0.3, 1.5)', 'rotate("Box", 0.3, 0, 0.2)', 'select("Box")', 'op("rigid.add", "passive box")'], 'landbox')
    same('a landscape and a passive box', rb, ['from point rate 600 speed 3 spread 40 collide on bounce 0.5 life 5'], [10, 30, 60])
    # a box half in the hills: paths that cross both in one step (the box's hit the nearer)
    rb2 = base(hills + ['add("cube", "Slab", 0, 1, 0)', 'scale("Slab", 4, 0.2, 4)', 'rotate("Slab", 0.35, 0, 0.25)', 'select("Slab")', 'op("rigid.add", "passive box")',
                        'scale("Cube", 5, 0.1, 5)'], 'landslab')
    same('a slab half in the hills', rb2, ['from faces rate 6000 speed 9 direction 0 -1 0 collide on bounce 0.3 life 3'], [20, 40])
    # the hills and a water plane as passive rigid bodies: particles hit the heights, not their triangles, nor the water's
    rw = base(hills + ['select("Landscape")', 'op("rigid.add", "passive")', 'op("landscape.add_water", "20")', 'move("Water", 0, -1, 0)', 'select("Water")', 'op("rigid.add", "passive")',
                       'scale("Cube", 5, 0.1, 5)'], 'landrigid')
    same('the hills and a water plane as passive bodies', rw, ['from faces rate 2000 speed 6 direction 0 -1 0 collide on bounce 0.3 life 3'], [20, 40])
    # threads: 1 and 8
    em = ['from faces rate 20000 speed 6 direction 0 -1 0 life 2 collide on bounce 0.4 name A', 'events hit A per 1 speed 1 life 0.3']
    same('20k a second on the hills: 8 threads both', cloud, em, [20, 45], threads=8)
    p1 = port_frames([f'file.open {cloud}', '--select Cube'] + [f'particles.add {e}' for e in em], [20, 45], threads=1)
    p8 = port_frames([f'file.open {cloud}', '--select Cube'] + [f'particles.add {e}' for e in em], [20, 45], threads=8)
    check(len(p1) == 2 and p1 == p8 and len(p1[1]['rows']) > 10000, f'on the hills: the same on 1 and 8 threads ({len(p1[1]["rows"]) if len(p1) == 2 else None} particles)')


# ---- the words, the presets ------------------------------------------------------------------------

def console_lines(out):
    return [ln.rstrip() for ln in out.splitlines() if ln.startswith('  particles') or ln.startswith('  file.export_liquid')]


def s_words():
    print('-- the words: particles.add / set / remove, presets', flush=True)
    steps = ['particles.add rate 20 life 2 bogus 3', 'particles.add from nowhere', 'particles.set system 2 life 3', 'particles.set system 1 colour #12ab9F color_end 0xff00ff',
             'particles.set objects Light,Camera align velocity render off', 'particles.set events hit Rain', 'particles.set domain Cube', 'particles.set domain off',
             'particles.set split 99 viscosity honey liquid on surface on', 'particles.set system 2 name ABCDEFGHIJKLMNOPQRS events died XY', 'particles.set burst -4 seed 2.9 group 17',
             'particles.set direction 1 2', 'particles.set objects Nobody', 'particles.set color zz', 'particles.add', 'particles.remove system 1', 'particles.remove system 5',
             'particles.set system x size 2', 'particles.add sparks speed 3']
    po, pp = f'{T}/wo.bee', f'{T}/wp.bee'
    out = orig('select("Cube")\n' + ''.join(f'op("{s.split(" ", 1)[0]}", "{esc(s.split(" ", 1)[1] if " " in s else "")}")\n' for s in steps) + f'op("file.save_as", "{po}")\n')
    port('--select', 'Cube', *pops(steps), '--op', f'file.save_as {pp}')
    # (what each line says: not understood, added, no such system, removed)
    want = ['  particles: not understood: bogus', '  particles on Cube', '  particles: not understood: nowhere', '  particles on Cube',
            '  particles: not understood: Nobody', '  particles: not understood: zz', '  particles on Cube', '  particles removed from Cube',
            '  particles: no such system on Cube', '  particles on Cube']
    cp = [x for x in console_lines(plog()) if not x.endswith('understood:')]
    check(cp == want, f'the console says what each line did ({len(cp)} lines)' + ('' if cp == want else f': {cp}'))
    a, c = beefile.chunk(po, b'PSYS'), beefile.chunk(pp, b'PSYS')
    check(a is not None and a == c, f'their records the same both ways, byte for byte ({len(a or b"")} bytes)')
    # the presets: the emitters and their records, and particles at a frame
    for k, pr in enumerate(['rain', 'snow', 'sparks', 'confetti', 'fountain', 'tank']):
        po, pp = f'{T}/pr{k}o.bee', f'{T}/pr{k}p.bee'
        orig(f'op("particles.add_{pr}", "")\nop("file.save_as", "{po}")\n')
        port('--op', f'particles.add_{pr}', '--op', f'file.save_as {pp}')
        so, sp = [beefile.chunk(x, b'PSYS') for x in (po, pp)]
        oo, op_ = [sorted((o['name'], o['loc'], o['scl'], o['type']) for o in beefile.objects(x)) for x in (po, pp)]
        mo, mp = [beefile.chunk(x, b'MATS') for x in (po, pp)]
        check(so is not None and so == sp and oo == op_ and (k < 5 or mo == mp), f'Add > Particles > {pr}: the emitter, its record' + (', its water material' if k == 5 else '') + ' the same both ways')
        same(f'{pr}: the particles at frames 4 and 12', po, [], [4, 12], sel=['Rain Cloud', 'Snow Cloud', 'Sparks', 'Confetti', 'Fountain', 'Water'][k])


# ---- files, the cache, undo ------------------------------------------------------------------------

def rebuild(path, out, change):
    """The file again, its chunks plain, `change` {tag: bytes or None} applied."""
    d = open(path, 'rb').read()
    res = bytearray(d[:8])
    done = set()
    for tag, body in beefile.chunks(path):
        if tag in change:
            done.add(tag)
            if change[tag] is None:
                continue
            body = change[tag]
        res += tag + struct.pack('<I', len(body)) + body
    for tag, body in change.items():
        if tag not in done and body is not None:
            res += tag + struct.pack('<I', len(body)) + body
    open(out, 'wb').write(res)


def mask_simc(c):
    """SIMC without its keys (made from the meshes: not compared)."""
    x = bytearray(c or b'')
    p = 0
    while p + 20 <= len(x):
        n = struct.unpack_from('<I', x, p + 16)[0]
        x[p + 8:p + 16] = b'\0' * 8
        sz = struct.unpack_from(f'<{n}I', x, p + 20)
        p += 20 + 4 * n + sum(sz)
    return bytes(x)


def s_files():
    print('-- files: PSYS by a script and by the console, damaged chunks; the cache, bake, SIMC, undo', flush=True)
    b = base(['op("create.ground", "")', 'op("anim.range", "1 30")'], 'files')
    em = ['from point rate 300 speed 4 spread 30 collide on life 2 bounce 0.5 name Sp', 'from fill size 0.2 liquid on life 100 speed 0', 'events hit Sp per 1 life 0.2']
    po, pp = f'{T}/fo.bee', f'{T}/fp.bee'
    orig(f'op("file.open", "{b}")\nselect("Cube")\n' + ''.join(f'emit("Cube", "{e}")\n' for e in em) + f'op("file.save_as", "{po}")\n')
    port('--op', f'file.open {b}', '--select', 'Cube', *[x for e in em for x in ('--op', f'particles.add {e}')], '--op', f'file.save_as {pp}')
    a, c = beefile.chunk(po, b'PSYS'), beefile.chunk(pp, b'PSYS')
    check(a is not None and a == c, f'PSYS the same ({len(a or b"")} bytes)')
    # each route's file opened and saved by the other
    p2, o2 = f'{T}/fp2.bee', f'{T}/fo2.bee'
    port('--op', f'file.open {po}', '--op', f'file.save_as {p2}')
    orig(f'op("file.open", "{pp}")\nop("file.save_as", "{o2}")\n')
    check(beefile.chunk(p2, b'PSYS') == a and beefile.chunk(o2, b'PSYS') == a, 'the script\'s file saved again by the console, and the console\'s by a script: PSYS the same')
    same('the console\'s file: the same particles both ways', pp, [], [6, 20])
    # bake: SIMC the same but for its keys; a baked file plays the same both ways
    bo, bp = f'{T}/bo.bee', f'{T}/bp.bee'
    out = orig(f'op("file.open", "{po}")\nop("sim.bake", "particles liquid")\nprint("C", cacheinfo(7), cacheinfo(8), cacheinfo(9), cacheinfo(10))\nop("file.save_as", "{bo}")\n')
    r = port('--op', f'file.open {pp}', '--op', 'sim.bake particles liquid', *[x for k in (7, 8, 9, 10) for x in ('--print-anim', f'cacheinfo:{k}')], '--op', f'file.save_as {bp}')
    co = re.findall(r'^C (.*)$', out, re.M)
    cp = [float(v) for v in re.findall(r'^cacheinfo:\d+=(\S+)', r.stderr if r else '', re.M)]
    check(co and [float(x) for x in co[0].split()] == cp and cp[0] > 0, f'sim.bake: frames cached and baked the same ({co[0] if co else None} / {cp})')
    sa, sb = beefile.chunk(bo, b'SIMC'), beefile.chunk(bp, b'SIMC')
    check(sa is not None and len(sa) > 1000 and mask_simc(sa) == mask_simc(sb), f'SIMC the same but for its keys ({len(sa or b"")} bytes)')
    same('the script\'s baked file played back (frames 1 .. 40: past the end, the last)', bo, [], [3, 17, 30, 40])
    same('the console\'s baked file: played the same', bp, [], [5, 25])
    # damaged PSYS: what each route makes of it, records and particles
    good = beefile.chunk(po, b'PSYS')
    n, rs = struct.unpack_from('<2I', good)
    cases = {'truncated': good[:len(good) // 2], 'short': good[:6], 'empty': b'', 'record size 0': struct.pack('<2I', n, 0) + good[8:],
             'record size 200': struct.pack('<2I', n, 200) + good[8:], 'record size 500': struct.pack('<2I', 2, 500) + good[8:8 + 1000],
             'count 1000': struct.pack('<2I', 1000, rs) + good[8:], 'garbage': bytes(random.Random(SEED).randrange(256) for _ in range(900)),
             'huge count and size': struct.pack('<2I', 0x10000000, 0x10000010) + good[8:]}
    for name, body in cases.items():
        dmg = f'{T}/dmg.bee'
        rebuild(po, dmg, {b'PSYS': body})
        o3, p3 = f'{T}/do.bee', f'{T}/dp.bee'
        out = orig(f'op("file.open", "{dmg}")\nframe(6)\nprint("D", particles(0), particles(1))\nop("file.save_as", "{o3}")\n')
        r = port('--op', f'file.open {dmg}', '--op', 'anim.frame 6', '--print-anim', 'particles:0', '--print-anim', 'particles:1', '--op', f'file.save_as {p3}')
        do = re.findall(r'^D (.*)$', out, re.M)
        dp = [float(v) for v in re.findall(r'^particles:\d+=(\S+)', r.stderr if r else '', re.M)]
        sa_, sb_ = beefile.chunk(o3, b'PSYS') if os.path.exists(o3) else None, beefile.chunk(p3, b'PSYS') if os.path.exists(p3) else None
        if name == 'huge count and size':
            # (the whole size checked: no systems)
            check(dp == [0.0, 0.0] and sb_ == struct.pack('<2I', 0, 384), f'a damaged PSYS ({name}): no systems read ({dp}; the script {"stopped" if not do else "read " + do[0]})')
            continue
        check(bool(do) and [float(x) for x in do[0].split()] == dp and sa_ == sb_, f'a damaged PSYS ({name}): read alike both ways ({do[0] if do else None} / {dp})')
    # the cache: going back plays the recorded frames; a change drops them
    steps = [f'file.open {po}', 'anim.frame 20', 'anim.frame 8']
    out = orig(PRE + f'op("file.open", "{po}")\nframe(20)\n' + code_frame(8) + 'print("C", cacheinfo(7), cacheinfo(8))\nselect("Cube")\nop("particles.set", "system 1 speed 5")\n' + code_frame(9) + 'print("C", cacheinfo(7), cacheinfo(8))\n')
    o = parse_orig(out)
    d = f'{T}/d.txt'
    if os.path.exists(d):
        os.remove(d)
    r = port(*pops(steps), '--dump-particles', d, *[x for k in (7, 8) for x in ('--print-anim', f'cacheinfo:{k}')], '--select', 'Cube', '--op', 'particles.set system 1 speed 5',
             '--op', 'anim.frame 9', '--dump-particles', d, *[x for k in (7, 8) for x in ('--print-anim', f'cacheinfo:{k}')])
    res, cur = [], []
    for ln in open(d).read().splitlines() if os.path.exists(d) else []:
        w = ln.split()
        if w[0] == 'info':
            res.append({'info': w[1:], 'rows': cur})
            cur = []
        else:
            cur.append([int(x, 16) for x in w])
    bad = compare(o, res, [8, 9])
    co = [[float(v) for v in x.split()] for x in re.findall(r'^C (.*)$', out, re.M)]
    cp = [float(v) for v in re.findall(r'^cacheinfo:\d+=(\S+)', r.stderr if r else '', re.M)]
    check(not bad and co == [cp[0:2], cp[2:4]] and co[0][0] == 19 and co[1][0] == 8, f'back to frame 8 from 20: played from the cache the same; a change drops it, frame 9 simulated again ({co} / {cp})' + ('' if not bad else ': ' + bad[0]))
    # undo and redo with the timeline (the script without the undo: its counts)
    out = orig(f'op("file.open", "{b}")\nselect("Cube")\nframe(10)\nop("particles.add", "rate 100 life 5")\nframe(12)\nprint("U", particles(0))\nframe(15)\nprint("U", particles(0))\n')
    r = port('--op', f'file.open {b}', '--select', 'Cube', '--op', 'anim.frame 10', '--op', 'particles.add rate 100 life 5', '--op', 'anim.frame 12', '--print-anim', 'particles:0',
             '--op', 'edit.undo', '--op', 'anim.frame 14', '--print-anim', 'particles:0', '--print-anim', 'particles:1', '--op', 'edit.redo', '--op', 'anim.frame 15', '--print-anim', 'particles:0')
    uo = [float(x) for x in re.findall(r'^U (\S+)', out, re.M)]
    up = [float(v) for v in re.findall(r'^particles:\d+=(\S+)', r.stderr if r else '', re.M)]
    check(len(uo) == 2 and up == [uo[0], 0.0, 0.0, uo[1]], f'undo and redo with the timeline: the system goes (no particles, none running) and comes back ({up}; without the undo {uo})')


def s_surface():
    print('-- the liquid\'s surface', flush=True)
    os.makedirs(f'{T}/xo', exist_ok=True)
    os.makedirs(f'{T}/xp', exist_ok=True)
    orig(f'op("particles.add_tank", "size 0.1")\nop("file.export_liquid", "{T}/xo/w 3 6")\n')
    port('--op', 'particles.add_tank size 0.1', '--op', f'file.export_liquid {T}/xp/w 3 6')
    fs = sorted(x for x in os.listdir(f'{T}/xo') if x.endswith('.obj'))
    eq = [open(f'{T}/xo/{x}', 'rb').read() == open(f'{T}/xp/{x}', 'rb').read() if os.path.exists(f'{T}/xp/{x}') else False for x in fs]
    sz = sum(os.path.getsize(f'{T}/xo/{x}') for x in fs)
    check(len(fs) == 4 and all(eq) and sz > 100000, f'file.export_liquid: {len(fs)} OBJ frames of the surface byte for byte both ways ({sz} bytes)')
    check('exported 4 frames (OBJ)' in plog(), 'it says "exported 4 frames (OBJ)"')


# ---- stability, time, memory ------------------------------------------------------------------------

def s_fuzz():
    print('-- random settings on the debug build: no crash, no hang', flush=True)
    rng = random.Random(SEED + 1)
    words = ['from faces', 'from volume', 'from verts', 'from point', 'from fill', 'from events', 'rate', 'burst', 'start', 'end', 'life', 'life_random', 'speed', 'spread',
             'size', 'size_random', 'drag', 'gravity', 'max', 'collide on', 'collide off', 'on_hit split', 'on_hit stick', 'split', 'liquid on', 'liquid off', 'surface on',
             'substeps', 'iterations', 'viscosity', 'vorticity', 'tension', 'domain', 'events hit A', 'events died A', 'events born A', 'events spray A', 'per', 'name A',
             'draw points', 'draw sprites', 'point_px', 'size_end', 'color_end ff0000', 'seed', 'group', 'resolution', 'density']
    vals = ['0', '-1', '1e30', '-1e30', 'nan', '3', '0.0001', '100000', '2.5', '7']
    bad = 0
    for k in range(RUNS * 2):
        steps = ['create.ground'] if rng.random() < 0.5 else []
        for _ in range(rng.choice([0, 0, 1, 2])):  # landscapes to hit (even tiny ones)
            steps.append(f'landscape.add {rng.choice(["flat", "hills", "canyon", "island"])} res 65 size {rng.choice(["0.001", "3", "40", "1e30"])}')
        steps += ['--select Cube']
        for _ in range(rng.randint(1, 3)):
            s = ' '.join(rng.choice(words) + ('' if rng.random() < 0.3 else ' ' + rng.choice(vals)) for _ in range(rng.randint(1, 6)))
            steps.append(f'particles.add {s}'[:250])
        frames = [rng.randint(-2, 15) for _ in range(3)]
        a = pops(steps) + [x for f in frames for x in ('--op', f'anim.frame {f}')] + ['--op', 'sim.bake particles liquid', '--op', 'anim.frame 5', '--op', 'edit.undo']
        # (900 s: a random scene can bake ~1 GB of particles; the debug build with alloc
        # safety takes ~420 s where release takes 83 s)
        r = port(*a, ok=False, timeout=900)
        if r is None or r.returncode != 0:
            bad += 1
            print('   ', steps, frames, (r.stderr[-600:] if r else 'hung'))
    check(bad == 0, f'{RUNS * 2} random scenes stepped, baked, undone: {bad} crashed or hung')
    # damaged SIMC frames (inside): no crash
    po = f'{T}/fo.bee'
    if os.path.exists(f'{T}/bo.bee'):
        good = beefile.chunk(f'{T}/bo.bee', b'SIMC')
        rngd = random.Random(SEED + 2)
        bad = 0
        for k in range(RUNS):
            x = bytearray(good)
            for _ in range(20):
                x[rngd.randrange(24, len(x))] = rngd.randrange(256)
            rebuild(f'{T}/bo.bee', f'{T}/ds.bee', {b'SIMC': bytes(x)})
            r = port('--op', f'file.open {T}/ds.bee', '--op', 'anim.frame 7', '--op', 'anim.frame 2', ok=False, timeout=900)
            bad += r is None or r.returncode != 0
        check(bad == 0, f'{RUNS} SIMC chunks with garbage inside their frames: {bad} crashed')


def info_frames(binary, steps, frames, keys):
    a = pops(steps)
    for f in frames:
        a += ['--op', f'anim.frame {f}'] + [x for k in keys for x in ('--print-anim', f'particles:{k}')]
    r = port(*a, binary=binary, timeout=1800)
    v = [float(x) for x in re.findall(r'^particles:\S+=(\S+)', r.stderr if r else '', re.M)]
    return [v[i:i + len(keys)] for i in range(0, len(v), len(keys))]


def s_time():
    print('-- time (a release build, one CPU) and memory', flush=True)
    b = b0 = base(['op("create.ground", "")', 'scale("Cube", 0.5, 0.5, 0.5)', 'move("Cube", 0, 2, 0)'], 'time')
    cases = [('10k particles bouncing on the Ground', 'from volume burst 10000 speed 2 spread 180 life 1000 collide on bounce 0.5'),
             ('10k particles bouncing on hills (257) and the Ground', 'from volume burst 10000 speed 2 spread 180 life 1000 collide on bounce 0.5'),
             ('10k particles, wind and turbulence', 'from volume burst 10000 speed 2 spread 180 life 1000'),
             ('a liquid of 4000', 'from fill size 0.06 life 1000 speed 0 liquid on domain -0.6 0 -0.6 0.6 3 0.6')]
    bh = base(['op("create.ground", "")', 'op("landscape.add", "hills res 257 size 6 seed 3")', 'move("Landscape", 0, -20.5, 0)',
               'scale("Cube", 0.5, 0.5, 0.5)', 'move("Cube", 0, 2, 0)'], 'timeland')
    for name, s in cases:
        b = bh if 'hills' in name else b0
        pre_o = ['op("field.add_wind", "strength 2")', 'op("field.add_turbulence", "strength 3")'] if 'wind' in name else []
        pre_p = ['field.add_wind strength 2', 'field.add_turbulence strength 3'] if 'wind' in name else []
        frames = list(range(2, 26))
        code = f'op("file.open", "{b}")\n' + ''.join(x + '\n' for x in pre_o) + f'select("Cube")\nemit("Cube", "{s}")\n'
        code += ''.join(f'frame({f})\nprint("T", particles(0), particles(3), particles(23))\n' for f in frames)
        set_threads(1)
        tp = info_frames(REL, [f'file.open {b}', *pre_p, '--select Cube', f'particles.add {s}'], frames, [0, 3, 23])
        set_threads(None)
        if len(tp) != len(frames):
            check(False, f'{name}: timing ({len(tp)} frames)')
            continue
        mp = sorted(x[1] for x in tp[2:])[len(tp[2:]) // 2]
        print(f'    {name}: {int(tp[-1][0])} particles, a step {mp:.2f} ms, median of {len(tp) - 2}')
        check(tp[-1][0] > 0 and mp == mp, f'{name}: stepped and timed ({int(tp[-1][0])} particles)')
    # memory over a long run: 600 frames of births and deaths against 150 (the cache keeps
    # every frame: it grows by that)
    b = b0
    em = ['from faces rate 4000 speed 3 spread 60 life 0.6 collide on name A', 'events hit A per 1 life 0.2']

    def rss(frames):
        a = pops([f'file.open {b}', '--select Cube'] + [f'particles.add {e}' for e in em]) + ['--op', f'anim.frame {frames}']
        set_threads(1)
        pr = subprocess.Popen(['taskset', '-c', CPU, REL, '--shot', f'{T}/u.ppm', *a], env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _, st, ru = os.wait4(pr.pid, 0)
        set_threads(None)
        return ru.ru_maxrss, st
    (p1, s1), (p2, s2) = rss(150), rss(600)
    print(f'    peak memory: {p1 // 1024} MB at 150 frames, {p2 // 1024} MB at 600')
    check(s1 == 0 and s2 == 0 and p2 >= p1 > 0, f'150 and 600 frames run cleanly ({p1 // 1024} / {p2 // 1024} MB)')


ALL = [s_emit, s_fields, s_collide, s_land, s_landliq, s_liquid, s_threads, s_words, s_files, s_surface, s_fuzz, s_time]
if __name__ == '__main__':
    print(f'particles: seed {SEED}', flush=True)
    for f in ALL:
        if ONLY and f.__name__ not in ONLY:
            continue
        f()
    _moved = [k for k in set(_REAL0) | set(_real_config()) if _REAL0.get(k) != _real_config().get(k)]
    check(not _moved, f'the user\'s ~/.config untouched by the run ({", ".join(_moved) or "nothing moved"})')
    print(f'particles: {len(FAILS)} fails' if FAILS else 'particles: all ok')
    for x in FAILS:
        print('   ', x)
    print(f'... fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)
