#!/usr/bin/env python3
"""Landscapes (landscape.zig, lsculpt.zig, procgen.zig erosion), BeeModel on
its own (--op lines, the scene saved and read back with tests/beefile.py):

  * every preset (flat, hills, mountains, canyon, dunes, island) at several
    sizes, samples and seeds: a LAND block, its display mesh there with
    finite vertices, the file opened and saved again giving the same blocks
    (all but the reference count and the evaluation's milliseconds) and the
    same display mesh; the island's sea (a Water plane flagged OBF_WATER, its
    ripples);
  * the layer stack: add (each type, each key), set, hide, show, up, down,
    remove, words it does not take (the console's lines), random sequences;
    landscape.set (size, res: every array resampled, detail);
  * brushes by script (raise, lower, smooth, flatten, noise, erode, ramp, the
    eight paints), paint layers (add with keys, rule, remove), auto paint:
    the block and the display's vertex colours (MVCL) there;
  * the files (opened and saved again: the same blocks), damaged LAND chunks
    (truncated, garbage: read without a crash, the file saved again reads
    back);
  * undo and redo of each kind of change (the block of the step before, the
    block again); a stroke in sculpt mode is one step; the terrain and
    L-system tree templates;
  * random layer, brush and paint sequences on the debug build (no crash, no
    hang), and a 1025 / 2049 / 4097 landscape evaluated by a release build
    (one CPU: LA_REL), a layer above the erosion from the cache.

    python3 tests/landscape.py BIN [runs=6] [seed]

BEE_CPU (default 20) pins every run; LA_ONLY=presets,layers ... runs some;
LA_REL=path: a release build for the timing (else BIN).
"""
import os, random, re, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 6
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '20')
ONLY = [x for x in os.environ.get('LA_ONLY', '').split(',') if x]
REL = os.environ.get('LA_REL', BIN)
FAILS = []
T = tempfile.mkdtemp(prefix='beeland-', dir=os.environ.get('BEELAND_TMP', '/tmp'))
import atexit
if not os.environ.get('LA_KEEP'):
    atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, XDG_CACHE_HOME='', BEEMODEL_GPU='off')
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
rng = random.Random(SEED)

# ---- the user's own settings must not move (read only: the real home, by uid) ----
import pwd as _pwd


def _real_config():
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


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def bees(code, timeout=1200):
    """BeeScript run by BeeModel (--run): its output."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        return 'timeout'
    return r.stdout


def port(*a, binary=None, ok=True, timeout=1200):
    if os.path.exists(f'{T}/log.txt'):
        os.remove(f'{T}/log.txt')
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


def one(steps, name, extra_port=()):
    """The steps run by BeeModel, the scene saved: the file."""
    pp = f'{T}/{name}_p.bee'
    if os.path.exists(pp):
        os.remove(pp)
    a = []
    for s in steps:
        a += ['--op', s]
    port(*a, *extra_port, '--op', f'file.save_as {pp}')
    return pp


def again(path, name):
    """The file opened and saved again by BeeModel."""
    p2 = f'{T}/{name}_p2.bee'
    if os.path.exists(p2):
        os.remove(p2)
    port('--op', f'file.open {path}', '--op', f'file.save_as {p2}')
    return p2


def lands(path):
    """[(mesh index, block with refs and ms zeroed)]."""
    if not os.path.exists(path):
        return None
    c = beefile.chunk(path, b'LAND') or b''
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


def meshes_of(path):
    return beefile.meshes(path) if os.path.exists(path) else []


def vcols(path):
    """{vertex count: colour bytes} of the MVCL chunk."""
    c = beefile.chunk(path, b'MVCL') or b''
    out, o = {}, 0
    while len(c) - o >= 8:
        ix, n = struct.unpack_from('<II', c, o)
        out.setdefault(n, []).append(c[o + 8:o + 8 + n * 4])
        o += 8 + n * 4
    return out


def objs(path):
    """[(name, type, flags)] of the OBJS chunk."""
    c = beefile.chunk(path, b'OBJS')
    n = struct.unpack_from('<I', c)[0]
    out = []
    for k in range(n):
        r = c[4 + k * 84:4 + k * 84 + 84]
        out.append((r[:32].split(b'\0')[0].decode(), struct.unpack_from('<I', r, 72)[0], struct.unpack_from('<I', r, 76)[0]))
    return out


def blocks_diff(a, b):
    if a is None or b is None:
        return 'a file is missing'
    if len(a) != len(b):
        return f'{len(a)} blocks against {len(b)}'
    for (_, x), (_, y) in zip(a, b):
        if x != y:
            if len(x) != len(y):
                return f'{len(x)} bytes against {len(y)}'
            d = [i for i in range(len(x)) if x[i] != y[i]]
            return f'{len(d)} bytes differ, first at {d[0]}'
    return None


def finite(vs):
    return all(x == x and abs(x) < 1e30 for v in vs for x in v)


def display(pp, tag):
    """The landscape meshes (the ones the LAND chunk names): there, finite."""
    mp, lp = meshes_of(pp), lands(pp) or []
    for ip, _ in lp:
        if ip >= len(mp):
            check(False, f'{tag}: the LAND chunk names a mesh that is not there')
            return
        m = mp[ip]
        check(len(m[0]) > 0 and len(m[1]) > 0 and finite(m[0]), f'{tag}: the display mesh there, its {len(m[0])} vertices finite')


def compare(steps, tag, display_=True, colours=False, extra_port=()):
    """The steps run, saved; the blocks there; opened and saved again: the same."""
    pp = one(steps, tag.replace(' ', '_').replace('/', '_'), extra_port)
    lp = lands(pp)
    check(lp is not None and len(lp) > 0, f'{tag}: the scene saved with its LAND blocks ({len(lp or [])})')
    if not lp:
        return pp, None
    p2 = again(pp, tag.replace(' ', '_').replace('/', '_'))
    d = blocks_diff(lp, lands(p2))
    check(d is None, f'{tag}: opened and saved again, the LAND blocks byte for byte' + (f' ({d})' if d else ''))
    if display_:
        display(pp, tag)
        if d is None:
            ma = [meshes_of(pp)[i] for i, _ in lp if i < len(meshes_of(pp))]
            mb = [meshes_of(p2)[i] for i, _ in lands(p2) if i < len(meshes_of(p2))]
            check(ma == mb, f'{tag}: and the same display mesh')
    if colours:
        vp_ = vcols(pp)
        big = [n for n in vp_ if n > 1000]
        check(big != [], f'{tag}: the display has vertex colours ({len(big)} meshes)')
        check(vcols(p2) == vp_, f'{tag}: and the same ones opened and saved again')
    return pp, p2


def wanted(name):
    return not ONLY or name in ONLY


# ---- presets ---------------------------------------------------------------------------------

def s_presets():
    print('== presets')
    for pre in ['flat', 'hills', 'mountains', 'canyon', 'dunes', 'island']:
        res = rng.choice([65, 129, 257])
        size = rng.choice([40, 120, 200, 333.5])
        seed = rng.randrange(0, 50)
        compare([f'landscape.add {pre} res {res} size {size} seed {seed}'], f'{pre} res {res} size {size} seed {seed}')
    # the defaults (hills, 513 x 513, 200 m) and the island's sea
    compare(['landscape.add'], 'landscape.add (hills, 513)')
    for steps, tag, side in ((['landscape.add flat res 1025 size 50', 'landscape.brush raise 0 0 radius 9'], 'flat 1025: every 2nd sample shown (513 a side)', 513),
                             (['landscape.add canyon res 129 size 50', 'landscape.set detail 65'], 'detail 65: every 2nd sample of 129 shown', 65)):
        pp, _ = compare(steps, tag)
        ms, ls = meshes_of(pp), lands(pp) or []
        n = len(ms[ls[0][0]][0]) if ls and ls[0][0] < len(ms) else 0
        check(n == side * side, f'{tag}: the display mesh {side} x {side} ({n} vertices)')
    pp = one(['landscape.add island res 129 size 80'], 'island')
    wp = [o for o in objs(pp) if o[0] == 'Water'] if os.path.exists(pp) else []
    check(len(wp) == 1 and wp[0][2] & 0x8000, 'island: a Water plane flagged OBF_WATER')
    mats = beefile.chunk(pp, b'MATS') if os.path.exists(pp) else None
    check(mats is not None and b'water\0' in mats, 'island: the sea has the water material (MATS)')
    mp = [m for m in meshes_of(pp) if len(m[0]) == 193 * 193]
    check(len(mp) == 1 and finite(mp[0][0]) and len({round(v[1], 4) for v in mp[0][0]}) > 1, 'island: the sea\'s ripples (192 x 192, not flat)')
    p2 = again(pp, 'island')
    check(os.path.exists(p2) and objs(p2) == objs(pp) and beefile.chunk(p2, b'MATS') == beefile.chunk(pp, b'MATS') and beefile.chunk(p2, b'OMAT') == beefile.chunk(pp, b'OMAT'),
          'island: opened and saved again, the same objects and water material (MATS, OMAT)')
    pp = one(['landscape.add hills res 65 size 30', 'landscape.sea', 'landscape.add_water 50'], 'water')
    wp = [m for m in meshes_of(pp) if len(m[0]) == 193 * 193]
    check(len(wp) == 2, f'landscape.sea and landscape.add_water: two water planes ({len(wp)})')
    # the console's lines
    port('--op', 'landscape.add canyon res 65', '--op', 'landscape.add bogus', '--op', 'landscape.add size', '--op', 'object.delete', '--op', 'landscape.sea')
    lg = plog()
    check('  added Landscape' in lg and re.search(r'  landscape evaluated in \d+ ms', lg) is not None, 'the console: "added Landscape", "landscape evaluated in N ms"')
    check(lg.count('  landscape: not understood: ') == 2, 'the console: two words it does not take')


# ---- layers ----------------------------------------------------------------------------------

LAYER_KEYS = {
    'generate': ['noise fbm', 'noise ridged', 'noise billow', 'noise cells', 'seed {i}', 'scale {f}', 'height {f}', 'octaves {i}', 'island 1', 'offset {s}', 'strength {u}'],
    'erode': ['droplets {d}', 'rate {u}', 'seed {i}', 'thermal {t}', 'talus {a}', 'strength {u}'],
    'terrace': ['steps {i}', 'smooth {u}', 'strength {u}'],
    'sculpted': ['strength {u}'],
    'flatten': ['height {s}', 'at {s} {s} {r}', 'strength {u}'],
}


def rnd_key(k):
    return k.format(i=rng.randrange(0, 12), f=round(rng.uniform(0.3, 9), 2), s=round(rng.uniform(-20, 20), 2),
                    u=round(rng.uniform(0, 1), 2), d=rng.randrange(0, 20000), t=rng.randrange(0, 8),
                    a=rng.randrange(10, 60), r=round(rng.uniform(2, 25), 1))


def rnd_layer_op(nl):
    v = rng.random()
    if nl < 8 and (nl == 0 or v < 0.45):
        t = rng.choice(list(LAYER_KEYS))
        keys = ' '.join(rnd_key(rng.choice(LAYER_KEYS[t])) for _ in range(rng.randrange(0, 3)))
        return f'landscape.layer add {t} {keys}'.rstrip(), nl + 1
    i = rng.randrange(0, nl)
    w = rng.choice(['set', 'set', 'hide', 'show', 'up', 'down', 'remove'])
    if w == 'set':
        return f'landscape.layer set {i} strength {round(rng.uniform(0, 1.2), 2)}', nl
    return f'landscape.layer {w} {i}', nl - (w == 'remove')


def s_layers():
    print('== layers')
    base = ['landscape.add hills res 129 size 60 seed 2']
    compare(base + ['landscape.layer add terrace steps 5 smooth 0.3', 'landscape.layer add flatten height 3 at 5 5 10',
                    'landscape.layer add generate noise cells scale 6 height 4 seed 9', 'landscape.layer hide 0', 'landscape.layer up 1',
                    'landscape.layer remove 2', 'landscape.layer set 0 strength 0.5', 'landscape.layer down 1', 'landscape.layer show 0'], 'layers: each verb')
    compare(base + ['landscape.layer add terrace steps 3', 'landscape.layer down 2'], 'layers: a terrace moved below the erosion (evaluated from the lower one, not the cache)')
    compare(['landscape.add flat res 65 size 50'] + [f'landscape.layer add generate noise {n} seed {k} octaves {k + 2} island {k % 2} offset {k - 1}' for k, n in enumerate(['fbm', 'ridged', 'billow', 'cells'])]
            + ['landscape.layer add erode droplets 3000 thermal 4 talus 25 rate 0.6 seed 5', 'landscape.layer add terrace steps 3 smooth 0'], 'layers: every noise, thermal erosion, a sharp terrace')
    for r in range(RUNS):
        steps, nl = list(base), 2
        for _ in range(rng.randrange(3, 9)):
            s, nl = rnd_layer_op(nl)
            steps.append(s)
        compare(steps, f'layers: random sequence {r} ({len(steps) - 1} changes)', display_=(r % 2 == 0))
    # landscape.set: size, samples (every array resampled), detail; bad words
    compare(base + ['landscape.layer add flatten at 0 0 8', 'landscape.set res 257 detail 100 size 90'], 'landscape.set res 257 detail 100 size 90')
    compare(base + ['landscape.layer add sculpted', 'landscape.brush raise 1 1 radius 9', 'landscape.set res 65'], 'landscape.set res 65 (a sculpted layer resampled)')
    port('--op', base[0], '--op', 'landscape.layer add mountains', '--op', 'landscape.layer set 7', '--op', 'landscape.layer add terrace bogus 1',
         '--op', 'landscape.set nonsense 3', '--op', 'landscape.layer remove -1')
    lg = plog()
    check(lg.count('  landscape: not understood: ') == 5, f'the console: each word it does not take said ({lg.count("not understood")} of 5)')
    port('--op', base[0], *sum((['--op', 'landscape.layer add sculpted'] for _ in range(7)), []))
    check('  landscape: 8 layers at most' in plog(), 'the console: "8 layers at most"')
    port('--op', 'landscape.layer add erode')
    check('  landscape: the active object is not a landscape' in plog(), 'the console: "the active object is not a landscape"')


# ---- brushes and paint -----------------------------------------------------------------------

TOOLS = ['raise', 'lower', 'smooth', 'flatten', 'noise', 'erode']
MATS = ['rock', 'grass', 'sand', 'snow', 'dirt', 'gravel', 'moss', 'mud']


def rnd_brush():
    t = rng.choice(TOOLS + MATS + ['ramp'])
    x, z = round(rng.uniform(-35, 35), 2), round(rng.uniform(-35, 35), 2)
    s = f'landscape.brush {t} {x} {z}'
    if t == 'ramp':
        s += f' to {round(rng.uniform(-35, 35), 2)} {round(rng.uniform(-35, 35), 2)}'
    if rng.random() < 0.7:
        s += f' radius {round(rng.uniform(1, 20), 2)}'
    if rng.random() < 0.6:
        s += f' strength {round(rng.uniform(0.05, 1), 2)}'
    return s


def s_brushes():
    print('== brushes and paint')
    base = ['landscape.add hills res 129 size 60 seed 2']
    for t in TOOLS:
        compare(base + [f'landscape.brush {t} 3 4 radius 8', f'landscape.brush {t} -6 2 radius 5 strength 1'], f'brush {t}')
    compare(base + ['landscape.brush ramp -20 -20 to 20 15 radius 4', 'landscape.brush ramp 0 0 to 0 0'], 'brush ramp')
    compare(base + ['landscape.layer add sculpted strength 0.5', 'landscape.brush raise 2 2 radius 7', 'landscape.brush ramp -9 0 to 9 4 radius 3', 'landscape.brush erode 0 0 radius 6', 'landscape.layer set 2 strength 0.25'], 'brushes on a sculpted layer at half strength (its offsets / the strength)')
    compare(base + [f'landscape.brush {m} {k * 3 - 10} {k} radius 9' for k, m in enumerate(MATS)], 'brush: the eight paints', colours=True)
    compare(base + [f'landscape.brush {m} 1 1 radius 8 strength 1' for m in ['rock', 'grass', 'rock', 'sand', 'snow', 'grass']], 'paints over each other: the others give way (255 at most together)', colours=True)
    compare(base + ['landscape.paint add grass', 'landscape.paint add rock colour 0.5 0.4 0.3 friction 0.9 bounce 0.2', 'landscape.paint add snow',
                    'landscape.paint auto', 'landscape.brush sand 3 3 radius 9', 'landscape.paint rule 0 height 0 0.5 slope 0 20', 'landscape.paint remove 1',
                    'landscape.paint_auto'], 'paint layers: add, rule, remove, auto', colours=True)
    compare(['landscape.add mountains res 65 seed 3', 'landscape.set res 129', 'landscape.paint add moss', 'landscape.brush moss 0 0 radius 40',
             'landscape.set res 65'], 'the splat map resampled (nearest)', colours=True)
    for r in range(RUNS):
        steps = list(base)
        if rng.random() < 0.5:
            steps.append(f'landscape.paint add {rng.choice(MATS)}')
        for _ in range(rng.randrange(2, 7)):
            steps.append(rnd_brush())
        if rng.random() < 0.4:
            steps.append('landscape.paint auto')
        compare(steps, f'brushes: random sequence {r} ({len(steps) - 1})', colours=any(s.startswith('landscape.paint add') or s.split()[1] in MATS for s in steps[1:]))  # (paint auto with no paint layer lays no colours)
    port('--op', base[0], '--op', 'landscape.brush ramp 1 1', '--op', 'landscape.brush hop 1 1', '--op', 'landscape.brush raise 1',
         '--op', 'landscape.paint rule 0', '--op', 'landscape.paint add lava')
    check(plog().count('  landscape: not understood: ') == 5, 'the console: the brush and paint words it does not take')
    port('--op', base[0], *sum((['--op', f'landscape.paint add {m}'] for m in MATS), []), '--op', 'landscape.paint add rock')
    check('  landscape: 8 paint layers at most' in plog(), 'the console: "8 paint layers at most"')


# ---- files -----------------------------------------------------------------------------------

def s_files():
    print('== files')
    steps = ['landscape.add canyon res 129 size 70 seed 5', 'landscape.paint add grass', 'landscape.brush grass 0 0 radius 20',
             'landscape.layer add flatten at 3 3 9', 'landscape.add island res 65 size 30']
    pp, p2 = compare(steps, 'files: two landscapes, paint, a flatten layer')
    check(len(lands(pp) or []) == 2, 'files: both landscapes in the file')
    po = pp
    # damaged LAND chunks
    # (a version-1 file of the same chunks, inflated, the LAND chunk replaced)
    chs = beefile.chunks(po)
    body = [c for t, c in chs if t == b'LAND'][0]

    def with_land(nb):
        out = bytearray(b'BEEM' + struct.pack('<I', 1))
        for t, c in chs:
            c = nb if t == b'LAND' else c
            out += t + struct.pack('<I', len(c)) + c
        return bytes(out)
    cases = {
        'truncated block': struct.pack('<II', *struct.unpack_from('<II', body)) + body[8:8 + 3000],
        'the bytes it says too many': body[:4] + struct.pack('<I', 0xfffffff0) + body[8:],
        'garbage': bytes(rng.randrange(256) for _ in range(5000)),
        'samples 9999': body[:8 + 4] + struct.pack('<I', 9999) + body[16:],
        'an offset past the end': body[:8 + 32] + struct.pack('<Q', 1 << 40) + body[48:],
        'a mesh index past the meshes': struct.pack('<I', 999) + body[4:],
    }
    # (9 paint layers in a block: one too many, left out)
    nb = body[:8 + 60] + struct.pack('<I', 9) + body[8 + 64:]
    f = f'{T}/dmg.bee'
    open(f, 'wb').write(with_land(nb))
    a = f'{T}/dmg_p.bee'
    r = port('--op', f'file.open {f}', '--op', 'landscape.paint auto', '--op', 'landscape.paint rule 7 height 0 1', '--op', f'file.save_as {a}', ok=False)
    check(r is not None and r.returncode == 0 and len(lands(a) or []) == 1, 'damaged LAND (9 paint layers): left out, the other kept, no crash')
    for name, nb in cases.items():
        d = with_land(nb)
        f = f'{T}/dmg.bee'
        open(f, 'wb').write(d)
        a = f'{T}/dmg_p.bee'
        if os.path.exists(a):
            os.remove(a)
        r = port('--op', f'file.open {f}', '--op', f'file.save_as {a}', ok=False)
        crashed = r is None or r.returncode != 0
        check(not crashed and os.path.exists(a), f'damaged LAND ({name}): BeeModel reads it, no crash')
        if os.path.exists(a):
            try:
                n = len(lands(a))
                ok = all(len(b) >= 76 for _, b in lands(a))
            except Exception as e:  # noqa: BLE001
                n, ok = repr(e), False
            check(ok, f'damaged LAND ({name}): the file saved again reads back ({n} blocks kept)')


# ---- undo, templates ---------------------------------------------------------------------------

def s_undo():
    print('== undo and redo, templates')
    base = 'landscape.add hills res 65 size 40 seed 1'
    kinds = ['landscape.layer add terrace steps 4', 'landscape.layer remove 1', 'landscape.set res 129', 'landscape.brush raise 0 0 radius 6',
             'landscape.paint add grass', 'landscape.brush rock 1 1 radius 8', 'landscape.paint_auto']
    for k in kinds:
        prior = [base] + (['landscape.paint add rock'] if 'auto' in k else [])
        po = one(prior, 'undo_before')
        pk = one(prior + [k], 'undo_after')
        pp, pr = f'{T}/undo_p.bee', f'{T}/undo_r.bee'
        a = []
        for s in prior:
            a += ['--op', s]
        port(*a, '--op', k, '--key', 'ctrl+z', '--op', f'file.save_as {pp}', '--key', 'ctrl+shift+z', '--op', f'file.save_as {pr}')
        check(blocks_diff(lands(po), lands(pp)) is None, f'undo of "{k}": the block of the step before')
        check(blocks_diff(lands(pk), lands(pr)) is None, f'redo of "{k}": the block again')
    # a stroke in sculpt mode is one step, labelled
    pp = f'{T}/stroke.bee'
    port('--op', 'landscape.add flat res 65 size 20', '--op', 'object.sculpt_mode', '--op', 'landscape.tool_raise',
         '--drag', '600,400,700,420', '--op', f'file.save_as {pp}', '--key', 'ctrl+z', '--op', f'file.save_as {T}/stroke_u.bee')
    lg = plog()
    hm = struct.unpack_from('<f', lands(pp)[0][1], 68)[0] if lands(pp) else 0
    hu = struct.unpack_from('<f', lands(f'{T}/stroke_u.bee')[0][1], 68)[0] if lands(f'{T}/stroke_u.bee') else -1
    check('sculpt mode: landscape (brushes and paint)' in lg, 'sculpt mode on a landscape says so')
    check(hm > 0.05 and 'Undo: Landscape Stroke' in lg and hu == 0, f'a stroke raises the ground (to {hm:.3f}) and undoes as one step "Landscape Stroke"')
    # templates
    pp = f'{T}/tpl_p.bee'
    port('--op', 'help.template terrain', '--op', f'file.save_as {pp}')
    check(len(lands(pp) or []) == 1, 'the terrain template: one landscape')
    names = [o[0] for o in objs(pp)] if os.path.exists(pp) else []
    check(len(names) >= 3, f'the terrain template: the landscape, a light and a camera ({names})')
    display(pp, 'the terrain template')
    port('--op', 'help.template tree', '--op', f'file.save_as {pp}')
    mp = [m for m in meshes_of(pp) if len(m[0]) > 100]
    check(len(mp) == 1 and finite(mp[0][0]), f'the L-system tree template: its tubes ({len(mp[0][0]) if mp else 0} vertices)')


# ---- fuzz, time ------------------------------------------------------------------------------

def s_fuzz():
    print('== fuzz (debug build)')
    for r in range(RUNS):
        a = ['--op', f'landscape.add {rng.choice(["flat", "hills", "canyon", "dunes"])} res {rng.choice([65, 129])} size {rng.choice([5, 60, 1e4])}']
        nl = 2
        for _ in range(12):
            v = rng.random()
            if v < 0.35:
                s, nl = rnd_layer_op(nl)
            elif v < 0.7:
                s = rnd_brush()
            elif v < 0.8:
                s = rng.choice(['landscape.paint auto', f'landscape.paint add {rng.choice(MATS)}', f'landscape.paint remove {rng.randrange(-1, 3)}',
                                f'landscape.set res {rng.choice([65, 129, 200])}', f'landscape.set detail {rng.choice([2, 33, 65])}'])
            elif v < 0.9:
                s = 'landscape.' + rng.choice(['layer', 'brush', 'paint', 'set']) + ' ' + ' '.join(rng.choice(['1e30', '-1e30', 'nan', '-3', 'at', 'to', 'x', '0']) for _ in range(rng.randrange(0, 5)))
            else:
                a += ['--key', rng.choice(['ctrl+z', 'ctrl+shift+z'])]
                continue
            a += ['--op', s]
        r_ = port(*a, ok=False, timeout=600)
        check(r_ is not None and r_.returncode == 0, f'fuzz run {r}: no crash, no hang')


def s_hfuzz():
    """Blocks with odd headers (sizes, counts, layers' types and numbers: NaN,
    infinities, huge) opened and worked on by the debug build: no crash."""
    print('== damaged headers (debug build)')
    po = one(['landscape.add hills res 65 size 30', 'landscape.layer add flatten at 0 0 5', 'landscape.paint add grass'], 'hf')
    chs = beefile.chunks(po)
    land = [c for t, c in chs if t == b'LAND'][0]
    odd = [float('nan'), float('inf'), -float('inf'), 0.0, -1.0, 1e30, 1e-30, 3.0, 1e9]
    for r in range(RUNS * 2):
        b = bytearray(land)
        hdr = 8  # (index, bytes)
        struct.pack_into('<f', b, hdr + 8, rng.choice(odd))                    # size
        struct.pack_into('<I', b, hdr + 20, rng.choice([0, 1, 2, 7, 0xffffffff, 600]))  # display
        struct.pack_into('<i', b, hdr + 56, rng.choice([-1, 0, 1, 7, 100]))    # the cache's layer
        struct.pack_into('<I', b, hdr + 60, rng.randrange(0, 9))               # paint layers
        for k in range(rng.randrange(1, 4)):
            ly = hdr + 128 + rng.randrange(0, 8) * 64
            struct.pack_into('<I', b, ly, rng.randrange(0, 9))
            struct.pack_into('<f', b, ly + 8 + 4 * rng.randrange(0, 11), rng.choice(odd))
        out = bytearray(b'BEEM' + struct.pack('<I', 1))
        for t, c in chs:
            c = bytes(b) if t == b'LAND' else c
            out += t + struct.pack('<I', len(c)) + c
        f = f'{T}/hf.bee'
        open(f, 'wb').write(bytes(out))
        a = ['--op', f'file.open {f}']
        for _ in range(6):
            a += ['--op', rng.choice([rnd_brush(), 'landscape.paint auto', 'landscape.layer set 0 strength 0.5', 'landscape.set res 65', 'landscape.layer add erode thermal 2', 'landscape.set detail 3', 'landscape.sea'])]
        r_ = port(*a, '--op', 'object.sculpt_mode', '--drag', '600,400,640,410', ok=False, timeout=600)
        check(r_ is not None and r_.returncode == 0, f'odd header {r}: no crash, no hang')


def eval_ms(out):
    m = re.findall(r'landscape evaluated in (\d+) ms', out)
    return [int(x) for x in m]


def s_time():
    print('== time (release build, one CPU)')
    for pre, res in [('hills', 1025), ('mountains', 2049), ('hills', 4097)]:
        port('--op', f'landscape.add {pre} res {res}', '--op', 'landscape.layer add terrace', binary=REL, timeout=1800)
        mp = eval_ms(plog())
        check(len(mp) == 2, f'{pre} {res}: evaluated, and again with a terrace on top ({mp})')
        if len(mp) == 2:
            print(f'       {pre} {res}: {mp[0]} ms, a layer above the erosion {mp[1]} ms')
            check(mp[1] <= mp[0] + 20, f'{pre} {res}: a layer above the erosion from the cache, no slower than the whole stack')


for name, f in [('presets', s_presets), ('layers', s_layers), ('brushes', s_brushes), ('files', s_files), ('undo', s_undo), ('fuzz', s_fuzz), ('hfuzz', s_hfuzz), ('time', s_time)]:
    if wanted(name):
        f()

_moved = [k for k in set(_REAL0) | set(_real_config()) if _REAL0.get(k) != _real_config().get(k)]
check(not _moved, f'the user\'s ~/.config untouched by the run ({", ".join(_moved) or "nothing moved"})')
print(f'landscape: seed {SEED}, fails {len(FAILS)}')
for x in FAILS:
    print('  -', x)
sys.exit(1 if FAILS else 0)
