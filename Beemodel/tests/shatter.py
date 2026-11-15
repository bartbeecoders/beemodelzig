#!/usr/bin/env python3
"""Shatter (shatter.zig, shatterop.zig): scenes a BeeScript script makes (a cube, a
sphere, a torus, a concave thin-walled vase, an open cube, turned and scaled)
shattered by a script (--run) and by console operators - shards (uniform, round a
point, near the surface), bricks (counts, sizes, offsets, gaps, jitter), balls,
inner colours, glue, impact, the presets, again - and every piece the same from
the two: its mesh (the MESH chunk) byte for byte, its name, colour, flags, parent,
its vertex colours, the rigid bodies and joints (the ANIM records) byte for
byte, its place byte for byte; the pieces simulated as rigid bodies over frames
(rbinfo(16), every place byte for byte), glued and loose, on a plane, and they
fall; on every thread as on one; words it does not understand, undo and redo
and the view after undo, a file opened and saved again, damaged meshes, the
form and the Physics tab's Shatter section, random runs, and the time a
shatter takes.

    python3 tests/shatter.py BIN [runs=20] [seed]

BEE_CPU (default 10) pins every run; SHATTER_ONLY=s_cases,s_random ... runs
some; SHATTER_REL=<release build> times it.
"""
import math, os, random, re, struct, subprocess, sys, tempfile, shutil, atexit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 20
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '10')
ONLY = [x for x in os.environ.get('SHATTER_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beeshat-', dir=os.environ.get('BEESHAT_TMP', '/tmp'))
if not os.environ.get('SHATTER_KEEP'):
    atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, XDG_CACHE_HOME='')
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
ANIM_HEAD = 8 + 55904 - 4


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def bee(code, timeout=900):
    """A BeeScript script (--run): what it printed."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        return 'timeout'
    return r.stdout


TIMEOUT = int(os.environ.get('SHATTER_TIMEOUT', '900'))


def port(*a, timeout=None, binary=None, ok=True, shot=None, cpus=None):
    timeout = timeout or TIMEOUT
    if os.path.exists(f'{T}/log.txt'):
        os.remove(f'{T}/log.txt')
    try:
        r = subprocess.run(['taskset', '-c', cpus or CPU, binary or BIN, '--shot', shot or f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a],
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


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def chunk(path, tag):
    try:
        return beefile.chunk(path, tag)
    except Exception:
        return None


# ---- comparing two files ----------------------------------------------------------------

def objmesh(p):
    ms = [c for t, c in beefile.chunks(p) if t == b'MESH']
    return {o['name']: (o, ms[o['mesh']] if o['mesh'] < len(ms) else None) for o in beefile.objects(p)}


def vcols(p):
    c = chunk(p, b'MVCL') or b''
    out, o = {}, 0
    while o + 8 <= len(c):
        ix, n = struct.unpack_from('<II', c, o)
        out[ix] = c[o + 8:o + 8 + 4 * n]
        o += 8 + 4 * n
    return {ob['name']: out.get(ob['mesh']) for ob in beefile.objects(p)}


def anim_recs(p):
    x = chunk(p, b'ANIM')
    if not x or len(x) < ANIM_HEAD:
        return [], [], b''
    nrb = struct.unpack_from('<I', x, 8 + 52 - 4)[0]
    njt = struct.unpack_from('<I', x, 8 + 56 - 4)[0]
    rb = x[ANIM_HEAD:ANIM_HEAD + nrb * 80]
    jt = x[ANIM_HEAD + nrb * 80:ANIM_HEAD + nrb * 80 + njt * 64]
    return [rb[k * 80:(k + 1) * 80] for k in range(nrb)], [jt[k * 64:(k + 1) * 64] for k in range(njt)], x[ANIM_HEAD - 36:ANIM_HEAD]


def ulps(a, b):
    """How far two floats are, in units of the larger's last place."""
    if a == b:
        return 0
    m = max(abs(a), abs(b), 1.0)
    return abs(a - b) / (m * 2 ** -23)


def matrix(o):
    """obj_matrix: T Rz Ry Rx S (3 rows of 4)."""
    (sx, cx), (sy, cy), (sz, cz) = [(math.sin(a), math.cos(a)) for a in o['rot']]
    r = [[cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx], [sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx], [-sy, cy * sx, cy * cx]]
    return [r[i][j] * o['scl'][j] for i in range(3) for j in range(3)] + list(o['loc'])


def compare(po, pp, place_ulps=0):
    """(ok, why, pieces, worst place ulps, worst place abs)."""
    try:
        a, b = objmesh(po), objmesh(pp)
    except Exception as e:
        return False, f'a file is missing ({e})', 0, 0, 0
    why = []
    if list(a) != list(b):
        why.append(f'objects {list(a)[:8]}... ({len(a)}) / {list(b)[:8]}... ({len(b)})')
    worst = 0
    worst_abs = 0
    for k in a:
        if k not in b:
            continue
        oa, ma = a[k]
        ob, mb = b[k]
        if ma != mb and oa['type'] == 0:
            why.append(f'{k}: mesh ({len(ma or b"")} / {len(mb or b"")} bytes)')
        if oa['color'] != ob['color'] or oa['type'] != ob['type'] or (oa['flags'] & 0x3ff) != (ob['flags'] & 0x3ff):
            why.append(f'{k}: colour, type or flags {hex(oa["color"])} {hex(oa["flags"])} / {hex(ob["color"])} {hex(ob["flags"])}')
        if oa['loc'] + oa['rot'] + oa['scl'] != ob['loc'] + ob['rot'] + ob['scl']:
            # (another Euler triple can turn the same way: the matrices compared)
            for x, y in zip(matrix(oa), matrix(ob)):
                worst = max(worst, ulps(x, y))
                worst_abs = max(worst_abs, abs(x - y))
    if worst > place_ulps:
        why.append(f'places {worst:.0f} ulps apart')
    if vcols(po) != vcols(pp):
        why.append('vertex colours')
    if chunk(po, b'PRNT') != chunk(pp, b'PRNT') or chunk(po, b'UIDS') != chunk(pp, b'UIDS'):
        why.append('parents or uids')
    ra, ja, wa = anim_recs(po)
    rb, jb, wb = anim_recs(pp)
    if ra != rb:
        why.append(f'bodies ({len(ra)} / {len(rb)})')
    if ja != jb:
        why.append(f'joints ({len(ja)} / {len(jb)})')
    if wa != wb:
        why.append('the physics world')
    va, vb = chunk(po, b'VIEW'), chunk(pp, b'VIEW')
    if (va or b'')[:4] != (vb or b'')[:4]:
        why.append('the active object')
    return not why, '; '.join(why)[:600], len(a), worst, worst_abs


def run_two(setup, sel, arg, tag, extra_o='', extra_p=()):
    """A script makes the scene (setup), saves it, shatters it (sel active) with
    arg; the console shatters the saved scene the same way: (script's file,
    console's file)."""
    base, po, pp = f'{T}/{tag}b.bee', f'{T}/{tag}o.bee', f'{T}/{tag}p.bee'
    bee(f'{setup}\nop("file.save_as", "{base}")\nselect("{sel}")\nop("object.shatter", "{esc(arg)}")\n{extra_o}\nop("file.save_as", "{po}")\n')
    port('--op', f'file.open {base}', '--select', sel, '--op', f'object.shatter {arg}', *extra_p, '--op', f'file.save_as {pp}')
    return po, pp


# ---- scenes -------------------------------------------------------------------------------

def vase_obj(path, n=48, split=1):
    """A vase: concave, thin walled."""
    prof = [(0, 0), (0.5, 0), (0.7, 0.3), (0.8, 0.8), (0.5, 1.4), (0.35, 1.7), (0.45, 2.0),
            (0.4, 2.0), (0.3, 1.7), (0.45, 1.4), (0.72, 0.8), (0.62, 0.3), (0.42, 0.1), (0, 0.1)]
    prof = [(p[0] + (q[0] - p[0]) * j / split, p[1] + (q[1] - p[1]) * j / split)
            for p, q in zip(prof, prof[1:]) for j in range(split)] + prof[-1:]
    vs, fs, idx = [], [], {}
    for i, (r, y) in enumerate(prof):
        if r == 0:
            idx[i, 0] = len(vs) + 1
            vs.append((0, y, 0))
            continue
        for k in range(n):
            a = 2 * math.pi * k / n
            idx[i, k] = len(vs) + 1
            vs.append((r * math.cos(a), y, -r * math.sin(a)))
    for i in range(len(prof) - 1):
        for k in range(n):
            k2 = (k + 1) % n
            a = idx[i, 0] if prof[i][0] == 0 else idx[i, k]
            b = idx[i, 0] if prof[i][0] == 0 else idx[i, k2]
            c = idx[i + 1, 0] if prof[i + 1][0] == 0 else idx[i + 1, k2]
            d = idx[i + 1, 0] if prof[i + 1][0] == 0 else idx[i + 1, k]
            f = [a, b, c, d]
            f = [x for j, x in enumerate(f) if x not in f[:j]]
            if len(f) >= 3:
                fs.append(f)
    with open(path, 'w') as o:
        for v in vs:
            o.write('v %.6f %.6f %.6f\n' % v)
        for f in fs:
            o.write('f ' + ' '.join(map(str, f)) + '\n')


def cube_obj(path, top=True, offsets=(0,)):
    faces = [(1, 2, 4, 3), (5, 7, 8, 6), (1, 5, 6, 2), (3, 4, 8, 7), (1, 3, 7, 5), (2, 6, 8, 4)]
    with open(path, 'w') as o:
        for n, dx in enumerate(offsets):
            for i in range(8):
                o.write('v %g %g %g\n' % (dx + (i & 1), (i >> 1) & 1, (i >> 2) & 1))
        for n in range(len(offsets)):
            for k, f in enumerate(faces):
                if not top and k == 3:
                    continue
                o.write('f ' + ' '.join(str(x + 8 * n) for x in f) + '\n')


def scenes():
    vase = f'{T}/vase.obj'
    vase_obj(vase)
    opn = f'{T}/open.obj'
    cube_obj(opn, top=False)
    pair = f'{T}/pair.obj'
    cube_obj(pair, offsets=(0, 1))
    return {
        'cube': ('', 'Cube'),
        'sphere': ('o = add("sphere", "S", 1, 2, 3)\nrotate(o, 0.3, 0.5, -0.2)\nscale(o, 1.5, 0.7, 1.2)', 'S'),
        'torus': ('delete("Cube")\nop("create.torus")', None),
        'vase': (f'delete("Cube")\nop("file.import_obj", "{vase}")', None),
        'ball': ('o = add("sphere", "S", 1, 2, 3)\nrotate(o, 0.3, 0.5, -0.2)\nscale(o, 1.3, 1.3, 1.3)', 'S'),
        'wall': ('o = add("cube", "Wall", 0, 0, 0)\nscale(o, 2, 1, 0.2)\nrotate(o, 0, 0.4, 0)\ndelete("Cube")', 'Wall'),
        'open': (f'delete("Cube")\nop("file.import_obj", "{opn}")', None),
        # (two cubes touching: vertices on the brick joint's plane)
        # (a piece: polygons with corners in a line, the source's triangles by ear_tris)
        'piece': ('o = add("sphere", "S", 0, 0, 0)\nselect("S")\nop("object.shatter", "shards count 60 seed 4 nobodies")', 'S_shard_7'),
        'pair': (f'delete("Cube")\nop("file.import_obj", "{pair}")', None),
    }


def active_name(setup):
    """The active object's name after the setup."""
    out = bee(setup + '\nprint("A", active())')
    m = re.search(r'^A (\S+)', out, re.M)
    return m.group(1) if m else 'Cube'


CASES = [
    ('cube', 'shards count 8'),
    ('cube', 'shards count 40 seed 7 nobodies'),
    ('sphere', 'shards count 30 seed 3'),
    ('torus', 'count 100 seed 7'),
    ('vase', 'count 100 seed 7'),
    ('vase', 'shards count 50 at 0.6 1 0 spread 0.4'),
    ('vase', 'shards count 40 surface seed 2'),
    ('vase', 'count 60 seed 3 glue 500'),
    ('sphere', 'shards count 25 cursor spread 0.3 inner 1 0.5 0'),
    ('torus', 'bricks counts 2 2 2'),
    ('vase', 'bricks counts 1 20 1'),
    ('pair', 'bricks counts 2 1 1'),
    ('piece', 'shards count 12 seed 2'),
    ('pair', 'bricks counts 4 2 2 inner 0 0 1'),
    ('wall', 'bricks counts 10 5 1 offset 0 inner 0.8 0.3 0.2'),
    ('wall', 'bricks counts 10 5 1'),
    ('wall', 'bricks size 0.5 0.4 2 offset random gap 0.02 jitter 0.4 glue 100'),
    ('wall', 'bricks count 9'),
    ('ball', 'balls count 40 spread 0.3'),
    ('ball', 'balls radius 0.3'),
    ('cube', 'balls count 30 density 500'),
    ('wall', 'preset brickwall'),
    ('wall', 'preset glass'),
    ('wall', 'preset stone at 0.5 0 0 glue 900 paint'),
    ('ball', 'preset gravel count 30'),
    ('cube', 'shards count 20 at 0.2 0.1 0 glue 500 impact 3'),
    ('open', 'shards count 10'),
]


def s_cases():
    print('-- every pattern and word: the pieces from a script and from the console --')
    sc = scenes()
    bad = 0
    worst = 0
    worst_abs = 0
    npieces = 0
    for k, (scn, arg) in enumerate(CASES):
        setup, sel = sc[scn]
        sel = sel or active_name(setup)
        po, pp = run_two(setup, sel, arg, f'c{k}')
        ok, why, n, w, wa = compare(po, pp)
        worst = max(worst, w)
        worst_abs = max(worst_abs, wa)
        npieces += n
        if not ok:
            bad += 1
            print('      ', scn, arg, '->', why)
    check(bad == 0, f'{len(CASES)} shatters of a cube, sphere, torus, vase, wall and an open cube ({npieces} objects): every piece\'s mesh, name, colour, '
                    f'flags, parent, vertex colours, bodies and joints byte for byte from a script and the console ({len(CASES) - bad} the same)')
    check(worst == 0, f'every piece\'s place byte for byte (at most {worst:.1f} ulps, {worst_abs:.3g} apart)')
    # (under a turned, unevenly scaled source a ball's place has a shear the
    # parent links cannot hold: its world place is kept)
    setup, sel = sc['sphere']
    po, pp = run_two(setup, sel, 'balls count 20', 'sk')
    ok, why, n, w, wa = compare(po, pp)
    check(ok, f'balls in a turned, unevenly scaled sphere: the same from a script and the console, places too ({why or n}; {wa:.3g} apart)')
    # the open cube was repaired; a plane has no inside
    po, pp = run_two('o = add("plane", "P", 0, 0, 0)', 'P', 'shards count 5', 'pl')
    lg = plog()
    ok, why, n, _, _ = compare(po, pp)
    check(ok and n == 4 and 'no room inside the mesh' in lg, f'a plane: no room for the cells, nothing made ({why or n} objects; "{lg.strip().splitlines()[-1] if lg.strip() else ""}")')


SIM_CASES = [  # (the source's turn and scale, the shatter), on a plane
    ('', 'shards count 14 seed 3'),
    ('', 'shards count 14 seed 3 glue 60'),
    ('rotate(sel_o, 0.3, 0.5, 0.2)\nscale(sel_o, 0.7)', 'shards count 20 seed 9 glue 400'),
    ('rotate(sel_o, -1.1, 2.2, 0.4)\nscale(sel_o, 1.3, 0.6, 0.9)', 'bricks size 0.5 0.4 0.4 glue 40'),
    ('rotate(sel_o, 0.7, -0.4, 1.9)', 'balls count 12'),
    ('scale(sel_o, 0.8, 1.2, 0.7)', 'shards count 8 surface'),
]


def s_simulate():
    print('-- the pieces simulated: glued and loose, from a turned and scaled source, on a plane: rbinfo(16) and every place byte for byte over frames, a script and the console --')
    bad = 0
    moved = 0
    for k, (tr, arg) in enumerate(SIM_CASES):
        base = f'{T}/sim{k}b.bee'
        bee('\n'.join(['n = count()', 'for i in 0..n { delete(name(0)) }', 'add("plane", "Ground", 0, 0, 0)', 'scale("Ground", 10)', 'select("Ground")',
                         'op("rigid.add", "passive plane")', 'sel_o = add("cube", "C", 0.5, 3, -0.3)', tr, f'op("file.save_as", "{base}")']))
        code = [f'op("file.open", "{base}")', 'select("C")', f'op("object.shatter", "{esc(arg)}")']
        a = ['--op', f'file.open {base}', '--select', 'C', '--op', f'object.shatter {arg}']
        files = []
        for f in (1, 2, 10, 30, 60):
            po, pp = f'{T}/sim{k}o{f}.bee', f'{T}/sim{k}p{f}.bee'
            code += [f'frame({f})', 'print("H", rbinfo(16), rbinfo(1))', f'op("file.save_as", "{po}")']
            a += ['--op', f'anim.frame {f}', '--print-anim', 'rbinfo:16', '--print-anim', 'rbinfo:1', '--op', f'file.save_as {pp}']
            files.append((po, pp))
        so = bee('\n'.join(code))
        r = port(*a)
        ho = [[float(x) for x in ln.split()[1:]] for ln in so.splitlines() if ln.startswith('H ')]
        vals = re.findall(r'^rbinfo:\d+=(\S+)', r.stderr if r else '', re.M)
        hp = [[float(vals[i]), float(vals[i + 1])] for i in range(0, len(vals) - 1, 2)]
        why = []
        if ho != hp:
            why.append(f'rbinfo(16), contacts {ho} / {hp}')
        for f, (po, pp) in zip((1, 2, 10, 30, 60), files):
            try:
                oa = {o['name']: o['loc'] + o['rot'] + o['scl'] for o in beefile.objects(po)}
                ob = {o['name']: o['loc'] + o['rot'] + o['scl'] for o in beefile.objects(pp)}
            except Exception as e:
                why.append(f'frame {f}: a file is missing ({e})')
                continue
            d = [n for n in oa if struct.pack('<9f', *oa[n]) != struct.pack('<9f', *ob.get(n, [0] * 9))]
            if d:
                why.append(f'frame {f}: {len(d)} places differ ({d[0]}: {oa[d[0]]} / {ob.get(d[0])})')
                break
        if ho and len(ho) == 5 and ho[1] != ho[-1]:
            moved += 1
        if why:
            bad += 1
            print('      ', arg, '->', '; '.join(why)[:500])
    check(bad == 0, f'{len(SIM_CASES)} shattered objects simulated: rbinfo(16) and every place byte for byte at 5 frames ({len(SIM_CASES) - bad} the same)')
    check(moved == len(SIM_CASES), f'the pieces fell in {moved} of {len(SIM_CASES)}')


def imp_same(po, pp, orig_name='C'):
    """Two files of a shatter on impact: every object's place byte for byte
    but the hidden pieces' while their source is whole (the pieces' bodies are
    compared by rbinfo(16)), and a piece's scale (its turn and place are the
    body's); every object's hidden flag; the bodies, joints, world; the cache
    (SIMC)."""
    try:
        oa = {o['name']: o for o in beefile.objects(po)}
        ob = {o['name']: o for o in beefile.objects(pp)}
    except Exception as e:
        return [f'a file is missing ({e})']
    why = []
    if list(oa) != list(ob):
        why.append(f'objects {list(oa)[:6]} / {list(ob)[:6]}')
    whole = orig_name in oa and not oa[orig_name]['flags'] & 0x200
    for n, x in oa.items():
        y = ob.get(n)
        if y is None:
            continue
        if (x['flags'] & 0x200) != (y['flags'] & 0x200):
            why.append(f'{n}: hidden {bool(x["flags"] & 0x200)} / {bool(y["flags"] & 0x200)}')
        piece = n.startswith(orig_name + '_')
        if piece and whole:
            continue
        ka = x['loc'] + x['rot'] + (() if piece else x['scl'])
        kb = y['loc'] + y['rot'] + (() if piece else y['scl'])
        if struct.pack(f'<{len(ka)}f', *ka) != struct.pack(f'<{len(kb)}f', *kb):
            why.append(f'{n}: place {ka} / {kb}')
    if anim_recs(po) != anim_recs(pp):
        why.append('bodies, joints or world')
    if chunk(po, b'SIMC') != chunk(pp, b'SIMC'):
        why.append(f'SIMC ({len(chunk(po, b"SIMC") or b"")} / {len(chunk(pp, b"SIMC") or b"")} bytes)')
    return why


IMP_INFO = ['16', '1', '20', '21', '2', '25']


def imp_run(base, seq, tag):
    """The steps as a script and as console operators (@name selects, #save
    saves, ? prints rbinfo): ([(script's file, console's file)], the script's
    rbinfo rows, the console's)."""
    code = [f'op("file.open", "{base}")']
    a = ['--op', f'file.open {base}']
    saves = []
    for s in seq:
        if s == '#save':
            po, pp = f'{T}/{tag}o{len(saves)}.bee', f'{T}/{tag}p{len(saves)}.bee'
            code.append(f'op("file.save_as", "{po}")')
            a += ['--op', f'file.save_as {pp}']
            saves.append((po, pp))
        elif s == '?':
            code.append('print("H", ' + ', '.join(f'rbinfo({k})' for k in IMP_INFO) + ')')
            for k in IMP_INFO:
                a += ['--print-anim', f'rbinfo:{k}']
        elif s.startswith('@'):
            code.append(f'select("{s[1:]}")')
            a += ['--select', s[1:]]
        else:
            i, _, r = s.partition(' ')
            code.append(f'op("{i}", "{esc(r)}")')
            a += ['--op', s]
    so = bee('\n'.join(code))
    r = port(*a)
    ho = [[float(x) for x in ln.split()[1:]] for ln in so.splitlines() if ln.startswith('H ')]
    vals = re.findall(r'^rbinfo:\d+=(\S+)', r.stderr if r else '', re.M)
    n = len(IMP_INFO)
    hp = [[float(v) for v in vals[i:i + n]] for i in range(0, len(vals), n)]
    return saves, ho, hp


IMP_CASES = [  # (scene lines, the shatter, frames)
    (['add("cube", "C", 0.5, 3, -0.3)', 'rotate("C", 0.3, 0.2, 0.1)'], 'shards count 12 seed 3 impact 3'),
    (['add("cube", "C", 0, 2.5, 0)', 'rotate("C", -1.1, 2.2, 0.4)', 'scale("C", 1.3, 0.6, 0.9)'], 'bricks size 0.5 0.4 0.4 glue 40 impact 2'),
    (['add("sphere", "C", -0.4, 4, 0.2)', 'scale("C", 0.8)'], 'preset glass count 20 seed 5'),
    (['add("cube", "C", 0, 1.5, 0)'], 'shards count 10 seed 1 impact 1e6'),
    (['add("cube", "C", 0, 1.0, 0)', 'add("sphere", "Ball", -6, 1.2, 0)', 'scale("Ball", 0.4)'], 'shards count 15 seed 8 impact 1'),
]


def s_impact():
    print('-- shatter on impact (rbody: imp_register, imp_check, imp_break, imp_show, imp_restore): breaking when hit, a script and the console over frames --')
    bad = broke = 0
    for k, (scn, arg) in enumerate(IMP_CASES):
        base = f'{T}/im{k}b.bee'
        bee('\n'.join(['n = count()', 'for i in 0..n { delete(name(0)) }', 'add("plane", "Ground", 0, 0, 0)', 'scale("Ground", 10)'] + scn + [f'op("file.save_as", "{base}")']))
        seq = ['@Ground', 'rigid.add passive plane'] + (['@Ball', 'rigid.add active sphere mass 40 velocity 14 0 0'] if 'Ball' in ' '.join(scn) else []) + ['@C', f'object.shatter {arg}']
        for f in (1, 5, 10, 15, 20, 30, 50):
            seq += [f'anim.frame {f}', '?', '#save']
        saves, ho, hp = imp_run(base, seq, f'im{k}')
        why = []
        if ho != hp or len(ho) != 7:
            why.append(f'rbinfo {ho} / {hp}')
        for f, (po, pp) in enumerate(saves):
            w = imp_same(po, pp)
            if w:
                why.append(f'save {f}: ' + '; '.join(w[:2]))
                break
        if ho and ho[-1][3] > 0:
            broke += 1
        if why:
            bad += 1
            print('      ', arg, '->', '; '.join(why)[:600])
    check(bad == 0, f'{len(IMP_CASES)} shatters on impact (dropped, turned and scaled, glued, glass, a ball thrown, too hard to break): rbinfo(16), contacts, '
                    f'groups, broken, awake and the places at 7 frames the same from a script and the console ({len(IMP_CASES) - bad} the same)')
    check(broke == len(IMP_CASES) - 1, f'broken in {broke} of {len(IMP_CASES)} (all but the one too hard to break)')
    # the cache: forward, back (played: whole again, then broken), bake, frames, sim.free; files
    base = f'{T}/im0b.bee'
    seq = ['@Ground', 'rigid.add passive plane', '@C', f'object.shatter {IMP_CASES[0][1]}', 'anim.frame 30', '?', '#save', 'anim.frame 8', '?', '#save',
           'anim.frame 20', '?', '#save', 'anim.frame 40', '?', '#save', 'anim.frame 12', '?', '#save', 'sim.bake rigid', '?', '#save', 'anim.frame 45', '?', '#save',
           'sim.free rigid', 'anim.frame 18', '?', '#save']
    saves, ho, hp = imp_run(base, seq, 'imc')
    why = []
    if ho != hp:
        why.append(f'rbinfo {ho} / {hp}')
    for f, (po, pp) in enumerate(saves):
        w = imp_same(po, pp)
        if w:
            why.append(f'save {f}: ' + '; '.join(w[:2]))
    if why:
        print('      ', '; '.join(why)[:900])
    check(not why and len(saves) == 8, f'the cache with a shatter on impact: forward, back (played whole, then broken), bake, sim.free: {len(saves)} files and rbinfo the same')
    played = [h[5] for h in ho]
    check(len(ho) == 8 and ho[1][3] == 0 and ho[2][3] == 1 and played[1] == 1.0, f'going back played it whole, then broken (broken {[h[3] for h in ho]}, played {played})')
    # back to the start and forward again: the same run
    a = ['--op', f'file.open {base}', '--select', 'Ground', '--op', 'rigid.add passive plane', '--select', 'C', '--op', f'object.shatter {IMP_CASES[0][1]}']
    for f in (30, 1, 30):
        a += ['--op', f'anim.frame {f}', '--print-anim', 'rbinfo:16', '--print-anim', 'rbinfo:21', '--op', f'file.save_as {T}/imr{f}_{len(a)}.bee']
    r = port(*a)
    hv = re.findall(r'^rbinfo:16=(\S+)', r.stderr if r else '', re.M)
    fs = sorted([x for x in os.listdir(T) if x.startswith('imr30_')], key=lambda x: int(x[6:-4]))
    same = len(fs) == 2 and not imp_same(f'{T}/{fs[0]}', f'{T}/{fs[1]}')
    check(len(hv) == 3 and hv[0] == hv[2] and float(hv[0]) == ho[0][0] and same,
          f'back to the start and on again: the same run, the pieces whole and then broken where they were ({hv}, files the same: {same})')
    sc = chunk(saves[5][0], b'SIMC')
    check(sc is not None and len(sc) > 1000 and sc == chunk(saves[5][1], b'SIMC'), f'the bake (with the shattering one\'s records) byte for byte ({len(sc or b"")} bytes)')
    for src, who in ((saves[5][0], 'the script'), (saves[5][1], 'the console')):
        so = bee('\n'.join([f'op("file.open", "{src}")', 'frame(33)', f'op("file.save_as", "{T}/imbo.bee")', 'frame(9)', f'op("file.save_as", "{T}/imbo2.bee")']))
        port('--op', f'file.open {src}', '--op', 'anim.frame 33', '--op', f'file.save_as {T}/imbp.bee', '--op', 'anim.frame 9', '--op', f'file.save_as {T}/imbp2.bee')
        w = imp_same(f'{T}/imbo.bee', f'{T}/imbp.bee') + imp_same(f'{T}/imbo2.bee', f'{T}/imbp2.bee')
        if w:
            print('      ', who, w[:3])
        check(not w, f'{who}\'s baked file played at frames 33 and 9 by a script and the console: the same (broken, whole)')


def s_random():
    print('-- random scenes, patterns and words --')
    rng = random.Random(SEED)
    sc = scenes()
    bad = 0
    for run in range(RUNS):
        pat = rng.choice(['shards', 'shards', 'bricks', 'balls'])
        # (balls: the scenes not scaled unevenly before - see s_cases)
        scn = rng.choice(['cube', 'ball', 'torus', 'vase'] if pat == 'balls' else ['cube', 'sphere', 'torus', 'vase', 'wall'])
        setup, sel = sc[scn]
        tr = f'\nsel_o = active()\nmove(sel_o, {rng.uniform(-2, 2):.3f}, {rng.uniform(-1, 1):.3f}, {rng.uniform(-2, 2):.3f})'
        if rng.random() < 0.6:
            # (y kept off +-90 degrees: there the child-of-parent places
            # come back through another Euler triple, 1e-3 off: not shatter's)
            ry = rng.choice([rng.uniform(-1.45, 1.45), rng.uniform(1.7, 3), rng.uniform(-3, -1.7)])
            tr += f'\nrotate(sel_o, {rng.uniform(-3, 3):.3f}, {ry:.3f}, {rng.uniform(-3, 3):.3f})'
        if rng.random() < 0.6:
            # (balls: evenly - unevenly the shear their places would need, see s_cases)
            k = rng.uniform(0.3, 2)
            sv = [k, k, k] if pat == 'balls' else [rng.uniform(0.3, 2) for _ in range(3)]
            tr += f'\nscale(sel_o, {sv[0]:.3f}, {sv[1]:.3f}, {sv[2]:.3f})'
        if sel:
            tr = f'\nselect("{sel}")' + tr
        setup2 = setup + tr
        sel = sel or active_name(setup2)
        w = [pat, f'count {rng.randint(2, 60)}', f'seed {rng.randint(0, 99)}']
        if pat == 'shards':
            w.append(rng.choice(['', 'surface', f'at {rng.uniform(-1, 1):.2f} {rng.uniform(-1, 1):.2f} {rng.uniform(-1, 1):.2f} spread {rng.uniform(0.1, 1):.2f}']))
        if pat == 'bricks':
            w.append(rng.choice(['', f'counts {rng.randint(1, 8)} {rng.randint(1, 5)} {rng.randint(1, 3)}', f'size {rng.uniform(0.2, 1):.2f} {rng.uniform(0.2, 1):.2f} {rng.uniform(0.2, 2):.2f}']))
            w.append(rng.choice(['', 'offset random', f'offset {rng.uniform(0, 1):.2f}']))
            w.append(rng.choice(['', f'gap {rng.uniform(0, 0.05):.3f}']))
            w.append(rng.choice(['', f'jitter {rng.uniform(0, 1):.2f}']))
        if pat == 'balls':
            w.append(rng.choice(['', f'spread {rng.uniform(0, 0.5):.2f}', f'radius {rng.uniform(0.1, 0.5):.2f}']))
        w.append(rng.choice(['', '', 'nobodies', f'glue {rng.randint(100, 50000)}', f'inner {rng.random():.2f} {rng.random():.2f} {rng.random():.2f}',
                             f'density {rng.randint(100, 5000)}', f'impact {rng.uniform(1, 20):.1f}']))
        arg = ' '.join(x for x in w if x)
        po, pp = run_two(setup2, sel, arg, f'r{run}')
        ok, why, n, _, _ = compare(po, pp)
        if not ok:
            bad += 1
            print('      ', run, scn, arg, '->', why)
    check(bad == 0, f'{RUNS} random shatters (seed {SEED}): {RUNS - bad} the same from a script and the console')


def s_threads():
    print('-- on every thread: the same pieces as on one --')
    n = os.cpu_count() or 1
    base, po, pp = f'{T}/thb.bee', f'{T}/tho.bee', f'{T}/thp.bee'
    bee(f'o = add("sphere", "S", 0, 0, 0)\nscale(o, 3, 3, 3)\nop("file.save_as", "{base}")\nselect("S")\n'
         f'op("object.shatter", "shards count 300 glue 300")\nop("file.save_as", "{po}")')
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'object.shatter shards count 300 glue 300', '--op', f'file.save_as {pp}', cpus=f'0-{n - 1}')
    ok, why, k, _, _ = compare(po, pp)
    check(ok and k > 300, f'300 shards cut on {n} threads: every piece, body and joint as on one CPU ({why or k})')


def s_separate():
    print('-- mesh.separate_loose (shatterop.zig): one object a loose part --')
    two = f'{T}/two.obj'
    cube_obj(two, offsets=(0, 3, 7))
    base, po, pp = f'{T}/sepb.bee', f'{T}/sepo.bee', f'{T}/sepp.bee'
    bee(f'delete("Cube")\nop("file.import_obj", "{two}")\nrotate(active(), 0.2, 0.3, 0.4)\nop("file.save_as", "{base}")\nop("mesh.separate_loose")\nop("file.save_as", "{po}")')
    port('--op', f'file.open {base}', '--select', 'two', '--op', 'mesh.separate_loose', '--op', f'file.save_as {pp}')
    ok, why, n, _, _ = compare(po, pp)
    check(ok and n == 5 and 'separated into loose parts: 3' in plog(), f'three cubes in one mesh: three objects, two_part_1 .. 3, the source gone; a script\'s the same ({why or n})')
    po2, pp2 = f'{T}/sep2o.bee', f'{T}/sep2p.bee'
    bee(f'select("Cube")\nop("mesh.separate_loose")\nop("file.save_as", "{po2}")')
    port('--select', 'Cube', '--op', 'mesh.separate_loose', '--op', f'file.save_as {pp2}')
    check('separate: select mesh objects with loose parts' in plog() and len(objmesh(pp2)) == 3, 'one part: nothing done, "separate: select mesh objects with loose parts"')


def s_words():
    print('-- words it does not understand; what the console says --')
    bad = []
    for arg, word in (('bogus', 'bogus'), ('shards count', ''), ('count 0', '0'), ('inner 1 x 0', '0'), ('preset marble', 'marble'),
                      ('offset', ''), ('seed x', 'x'), ('at 1 2 3 4', '4')):
        po, pp = run_two('', 'Cube', arg, 'w')
        ok, why, n, _, _ = compare(po, pp)
        lg = plog()
        want = f'not understood: {word}'
        if not ok or n != 3 or not re.search(r'^  object\.shatter: ' + re.escape(want) + r'\s*$', lg, re.M):
            bad.append(f'{arg}: {why or n} {lg.strip().splitlines()[-1] if lg.strip() else ""}')
    check(not bad, 'eight bad argument lists: nothing made, "not understood: <the word>"' + (f' ({bad})' if bad else ''))
    # a short list of numbers: what it has, the rest kept from before
    bad = []
    for arg in ('bricks counts 2 2', 'shards count 9 inner 1 0', 'shards count 9 at 0.3'):
        po, pp = run_two('', 'Cube', arg, 'w')
        ok, why, n, _, _ = compare(po, pp)
        if not ok:
            bad.append(f'{arg}: {why}')
    check(not bad, 'counts, inner and at with fewer than three numbers: the pieces the same from a script and the console' + (f' ({bad})' if bad else ''))
    port('--select', 'Light', '--op', 'object.shatter shards')
    check('make a mesh object active' in plog(), 'a light active: "shatter: make a mesh object active"')
    port('--select', 'Cube', '--op', 'object.shatter shards count 12')
    check(re.search(r'shattered into 12 pieces \(\d+ ms\)', plog()) is not None, '"shattered into 12 pieces (N ms)"')


def s_undo():
    print('-- undo and redo, the view after undo, again --')
    pp = [f'{T}/u{k}.bee' for k in range(4)]
    port('--select', 'Cube', '--op', f'file.save_as {pp[0]}', '--op', 'object.shatter shards count 10', '--op', f'file.save_as {pp[1]}',
         '--op', 'edit.undo', '--op', f'file.save_as {pp[2]}', '--op', 'edit.redo', '--op', f'file.save_as {pp[3]}')
    a = [objmesh(p) if os.path.exists(p) else {} for p in pp]
    vis = lambda m, k: k in m and (m[k][0]['flags'] & 0x200) == 0
    check(len(a[1]) == 13 and not vis(a[1], 'Cube') and len(a[2]) == 3 and vis(a[2], 'Cube') and len(a[3]) == 13,
          f'one undo step: Ctrl+Z gives the cube back (shown), Ctrl+Shift+Z the pieces again ({len(a[1])}, {len(a[2])}, {len(a[3])})')
    check(a[1] and a[3] and all(a[1][k][1] == a[3][k][1] for k in a[1]) and anim_recs(pp[1]) == anim_recs(pp[3]), 'redone: the same pieces and bodies')
    # the view after undo: what was drawn before
    from PIL import Image
    port('--select', 'Cube', '--move', '600,300', '--move', '600,310', shot=f'{T}/v0.ppm')
    port('--select', 'Cube', '--move', '600,300', '--op', 'object.shatter shards count 10', '--move', '600,305', '--op', 'edit.undo', '--move', '600,310', shot=f'{T}/v1.ppm')
    port('--select', 'Cube', '--move', '600,300', '--op', 'object.shatter shards count 10', '--move', '600,310', shot=f'{T}/v2.ppm')
    v = [Image.open(f'{T}/v{k}.ppm').crop((215, 90, 1020, 620)).tobytes() for k in range(3)]
    check(v[0] == v[1] and v[0] != v[2], 'the view after undo: the cube as before (the same pixels), the pieces not')
    # again: from a piece, the pieces made before go
    po, pp_ = run_two('op("object.shatter", "shards count 5")\nselect("Cube_shard_2")', 'Cube_shard_2', 'shards count 9 seed 3 again', 'ag')
    ok, why, n, _, _ = compare(po, pp_)
    check(ok and n == 12, f'again on a piece: the five pieces and their bodies go, nine new ones ({why or n})')


def s_files():
    print('-- a file opened and saved again, damaged meshes --')
    sc = scenes()
    setup, _ = sc['vase']
    base, pp, ob = f'{T}/fb.bee', f'{T}/fp.bee', f'{T}/fo.bee'
    bee(f'{setup}\nop("file.save_as", "{base}")')
    sel = active_name(setup)
    port('--op', f'file.open {base}', '--select', sel, '--op', 'object.shatter shards count 30 inner 0 1 0 glue 1000', '--op', f'file.save_as {pp}')
    bee(f'op("file.open", "{pp}")\nop("file.save_as", "{ob}")')
    ok, why, n, _, _ = compare(pp, ob)
    check(ok and n > 30, f'the console\'s pieces opened by a script and saved again: meshes, colours, bodies and joints the same ({why or n})')
    # damaged: NaN, huge and repeated vertices in the mesh shattered
    chs = beefile.chunks(base)
    mesh_ix = beefile.objects(base)[-1]['mesh']
    bad = []
    for what, f in (('a NaN vertex', lambda v: [float('nan')] + v[1:]), ('a vertex at 1e30', lambda v: [1e30] + v[1:]),
                    ('every vertex one point', lambda v: [0.0] * len(v)), ('half the vertices at 0', lambda v: [0.0] * (len(v) // 2) + v[len(v) // 2:])):
        out, mi = [b'BEEM', struct.pack('<I', 1)], 0
        for t, c in chs:
            if t == b'MESH':
                if mi == mesh_ix:
                    nv = struct.unpack_from('<I', c)[0]
                    v = list(struct.unpack_from(f'<{nv * 3}f', c, 12))
                    c = c[:12] + struct.pack(f'<{nv * 3}f', *f(v)) + c[12 + nv * 12:]
                mi += 1
            out += [t, struct.pack('<I', len(c)), c]
        path = f'{T}/dmg.bee'
        open(path, 'wb').write(b''.join(out))
        po = f'{T}/dmgo.bee'
        p2 = f'{T}/dmgp.bee'
        bee(f'op("file.open", "{path}")\nselect("{sel}")\nop("object.shatter", "shards count 12")\nop("file.save_as", "{po}")')
        r = port('--op', f'file.open {path}', '--select', sel, '--op', 'object.shatter shards count 12', '--op', f'file.save_as {p2}', ok=False)
        if r is None or r.returncode != 0:
            bad.append(f'{what}: BeeModel stopped')
            continue
        ok, why, n, _, _ = compare(po, p2)
        if not ok:
            bad.append(f'{what}: {why}')
    check(not bad, 'damaged meshes (NaN, 1e30, one point, half at 0): no crash, the same from a script and the console' + (f' ({bad})' if bad else ''))


# ---- the window -------------------------------------------------------------------------------

def rows(path):
    return [ln.rstrip('\n').split('\t') for ln in open(path)] if os.path.exists(path) else []


def prow(rs, kind, label):
    for r in rs:
        if len(r) >= 3 and r[0] == kind and r[1] == label:
            return [int(x) for x in r[2].split()]
    return None


def s_window():
    print('-- the form (Object > Physics > Shatter...) and Properties > Physics > Shatter --')
    port('--select', 'Cube', '--click-label', 'tab:Physics', '--click-label', 'section:Shatter', '--move', '600,300')
    rs = rows(f'{T}/u.txt')
    want = [('section', 'Shatter'), ('enum', 'Shards'), ('enum', 'No preset'), ('number', 'Count'), ('number', 'Seed'), ('number', 'Glue (N/m2)'),
            ('number', 'Breaks at (N s, 0 now)'), ('checkbox', 'Colour the cut faces'), ('button', 'Shatter'), ('section', 'World')]
    got = [prow(rs, k, lb) for k, lb in want]
    check(all(got), f'the section\'s rows: Pattern, Preset, Count | Seed, Glue, Breaks at, Colour the cut faces, Shatter ({[bool(a) for a in got]})')
    if all(got):
        ys = [a[1] for a in got]
        check(ys == sorted(ys) and ys[3] == ys[4], f'top to bottom under the heading, Count and Seed side by side ({ys})')
    # the panel's Shatter button, the pattern picked, Re-cut
    pf = f'{T}/pan.bee'
    port('--select', 'Cube', '--click-label', 'tab:Physics', '--click-label', 'section:Shatter', '--click-label', 'enum:Shards', '--click-label', 'menuitem:Bricks',
         '--click-label', 'button:Shatter', '--op', f'file.save_as {pf}')
    n1 = len(objmesh(pf)) if os.path.exists(pf) else 0
    port('--select', 'Cube', '--op', 'object.shatter shards count 5 nobodies', '--select', 'Cube_shard_2', '--click-label', 'tab:Physics', '--click-label', 'section:Shatter', '--move', '600,300')
    rec = prow(rows(f'{T}/u.txt'), 'button', 'Re-cut')
    check(n1 > 10 and rec is not None, f'Pattern Bricks, Shatter in the panel: bricks made ({n1 - 3}); a piece active: the button says Re-cut ({rec})')
    # the form: its fields; OK shatters as the operator does
    fl = ['Count', 'Seed', 'Glue (N/m2)', 'Breaks at (N s, 0 = now)', 'Gap (m)']
    port('--select', 'Cube', '--click-label', 'menu:Object', '--move-label', 'menuitem:Physics', '--click-label', 'menuitem:Shatter...', '--move', '600,300')
    rs = rows(f'{T}/u.txt')
    have = [prow(rs, 'number', lb) for lb in fl]
    check(all(have), f'the form: Count, Seed, Glue, Breaks at, Gap ({[bool(a) for a in have]})')
    pf2 = f'{T}/form.bee'
    fb = f'{T}/formb.bee'
    bee(f'op("file.save_as", "{fb}")')
    port('--op', f'file.open {fb}', '--select', 'Cube', '--click-label', 'menu:Object', '--move-label', 'menuitem:Physics', '--click-label', 'menuitem:Shatter...', '--key', 'enter', '--op', f'file.save_as {pf2}')
    po = f'{T}/formo.bee'
    bee(f'op("file.open", "{fb}")\nselect("Cube")\nop("object.shatter", "shards preset none")\nop("file.save_as", "{po}")')
    okc, why, n, _, _ = compare(po, pf2)
    check(okc and n == 53, f'the form\'s OK: object.shatter shards preset none, 50 pieces ({why or n})')


# ---- stability, time ----------------------------------------------------------------------

WORDS = ['shards', 'bricks', 'balls', 'count', '3', '0', '-5', '4097', '99999', 'seed', 'at', '0.1', 'cursor', 'surface', 'spread', 'size', 'counts', 'offset',
         'random', 'gap', '0.5', 'jitter', 'radius', 'inner', 'density', 'nobodies', 'glue', '1e9', 'paint', 'impact', 'preset', 'glass', 'gravel',
         'brickwall', 'stone', 'again', 'nan', 'inf', '1e-30', 'x', '']


def s_fuzz():
    print('-- random words, undo, again on this build: no crash --')
    rng = random.Random(SEED + 5)
    bad = 0
    for run in range(RUNS):
        a = ['--select', rng.choice(['Cube', 'Light', 'Camera'])]
        for _ in range(rng.randint(1, 5)):
            r = rng.random()
            if r < 0.6:
                n = rng.randint(1, 8)
                a += ['--op', 'object.shatter ' + ' '.join(rng.choice(WORDS) for _ in range(n))]
            elif r < 0.75:
                a += ['--op', rng.choice(['edit.undo', 'edit.redo'])]
            elif r < 0.85:
                a += ['--select', f'Cube_shard_{rng.randint(1, 5)}']
            else:
                a += ['--op', rng.choice(['create.sphere', 'create.cube', 'object.duplicate'])]
        a += ['--op', f'file.save_as {T}/fz.bee', '--op', f'file.open {T}/fz.bee']
        r = port(*a, ok=False, timeout=300)
        if r is None or r.returncode != 0:
            bad += 1
            print('      ', run, r and r.stderr[-300:], a)
    check(bad == 0, f'{RUNS} random sessions: no panic, no hang')


def s_time():
    print('-- the time a shatter takes (a release build, one CPU) --')
    rel = os.environ.get('SHATTER_REL')
    if not rel:
        print('       (SHATTER_REL unset: the release build to time; skipped)')
        return
    base = f'{T}/tm.bee'
    bee(f'o = add("sphere", "S", 0, 0, 0)\nscale(o, 3, 3, 3)\nop("file.save_as", "{base}")')
    res = []
    for arg in ('shards count 500 nobodies', 'bricks counts 30 20 4 nobodies', 'balls count 2000 nobodies', 'shards count 200 glue 1000'):
        tp = []
        for _ in range(3):
            port('--op', f'file.open {base}', '--select', 'S', '--op', f'object.shatter {arg}', binary=rel)
            m = re.search(r'shattered into \d+ pieces \((\d+) ms\)', plog())
            if m:
                tp.append(float(m.group(1)))
        if tp:
            res.append((arg, min(tp)))
            print(f'       {arg}: {min(tp):.0f} ms')
    check(len(res) == 4, 'each timed shatter says how long it took')


def main():
    print(f'shatter: {BIN}, runs {RUNS}, seed {SEED}')
    for f in [s_cases, s_simulate, s_impact, s_random, s_threads, s_separate, s_words, s_undo, s_files, s_window, s_fuzz, s_time]:
        if ONLY and f.__name__ not in ONLY:
            continue
        f()
    print(f'shatter: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
