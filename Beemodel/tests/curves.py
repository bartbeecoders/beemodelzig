#!/usr/bin/env python3
"""Curves (curve.zig) on BeeModel alone:

  * random sessions of the curve operators (create.bezier / curve_circle /
    path, curve.add, spline, point, set: resolution, bevel, sides, fill,
    profile, cyclic; select, move (point and handles), subdivide, delete,
    extrude, cyclic, handle types, tilt, radius, to_mesh): each runs cleanly,
    its file reads back, the CURV records are whole (splines tile the points,
    values finite and in range), and save -> open -> save gives the same
    curves and meshes (but the block's capacity and mapping size: checked on
    their own);
  * the CURV chunk: values the operators refuse (resolution 200 or 0, one
    side) read as the clamped ones; damaged chunks (truncated, garbage,
    splines that do not tile the points) read and saved again cleanly, what
    is kept whole;
  * undo and redo (each step's mesh as it was), the view following an edit;
  * the chain functions for geometry nodes and the L-system (curve line,
    circle, to mesh with and without a profile, resample, trim, fillet, curve
    to points) through a driver (tests/curvedrv.zig): the same meshes as the
    node trees give in BeeModel;
  * random sessions on the debug build (no crash, no hang), and the time of a
    big sweep (release build, one CPU: printed).

    python3 tests/curves.py BIN [runs=6] [seed]

BEE_CPU (default 10) pins every run; CV_ONLY=s_ops,s_files ... runs some;
CV_REL=path: a release build for the timing (else BIN).
"""
import math, os, random, re, struct, subprocess, sys, tempfile, shutil, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 6
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '10')
ONLY = [x for x in os.environ.get('CV_ONLY', '').split(',') if x]
REL = os.environ.get('CV_REL', BIN)
FAILS = []
T = tempfile.mkdtemp(prefix='beecurves-', dir='/tmp')
import atexit
atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, XDG_CACHE_HOME='', BEEMODEL_GPU='off')
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
print(f'seed {SEED}')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


# ---- the program ------------------------------------------------------------------------------

def script(code, timeout=600):
    """BeeModel runs a BeeScript (--run): its stdout."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        check(False, 'a script hung')
        return ''
    if r.returncode not in (0, 1) or 'panic' in r.stderr:
        check(False, f'a script stopped ({r.returncode}): {r.stderr[-300:]}')
    return r.stdout


def port(*a, binary=None, timeout=600, ok=True):
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


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


EMPTY = f'{T}/empty.bee'


def make_empty():
    script('n = count()\nfor i in 0..n { delete(name(0)) }\n' + f'op("file.save", "{EMPTY}")\n')
    return os.path.exists(EMPTY)


# ---- files ---------------------------------------------------------------------------------------

def curv_records(path):
    """The CURV chunk's records: (mesh index, points, block bytes)."""
    c = beefile.chunk(path, b'CURV') or b''
    out, o = [], 0
    while len(c) - o >= 8:
        ix, n = struct.unpack_from('<II', c, o)
        rec = n * 48 + 580
        if rec > len(c) - o:
            break
        out.append((ix, n, c[o + 8:o + rec]))
        o += rec
    return out


def masked(block):
    """The block without its capacity and mapping size (bytes 8..24 from the spline count)."""
    return block[:8] + b'\0' * 12 + block[20:]


def scene_of(path):
    """{name: (verts as bytes, polygons, curve block or None)} of a saved file."""
    objs = beefile.objects(path)
    ms = beefile.meshes(path)
    cv = {ix: blk for ix, n, blk in curv_records(path)}
    out = {}
    for o in objs:
        mi = o['mesh']
        if mi >= len(ms):
            continue
        v, p = ms[mi]
        out[o['name']] = (b''.join(struct.pack('<3f', *x) for x in v), p, cv.get(mi), o['loc'])
    return out


# ---- random sessions -----------------------------------------------------------------------------

def q(rnd, lo, hi, den=16):
    return rnd.randint(int(lo * den), int(hi * den)) / den


def fmt(x):
    return ('%r' % x).rstrip('0').rstrip('.') if isinstance(x, float) else str(x)


def session(rnd, n):
    """[op lines] of a random session (the active object is the last curve made)."""
    steps, names, cnt = [], [], {}
    kinds = [('create.bezier', 'BezierCurve'), ('create.curve_circle', 'BezierCircle'), ('create.path', 'Path')]

    def made(base):
        k = cnt.get(base, 0)
        cnt[base] = k + 1
        names.append(base if k == 0 else f'{base}.{k:03d}')

    for _ in range(n):
        r = rnd.random()
        if not names or r < 0.08:
            op, base = rnd.choice(kinds + [('curve.add empty', 'Curve'), ('curve.add circle', 'BezierCircle'), ('curve.add path', 'Path')])
            steps.append(op)
            made(base)
            continue
        r = rnd.random()
        P = lambda: ' '.join(fmt(q(rnd, -3, 3)) for _ in range(3))
        if r < 0.14:
            steps.append(f'curve.point {P()}')
        elif r < 0.2:
            steps.append('curve.spline ' + rnd.choice(['bezier', 'poly', 'bezier cyclic', 'poly cyclic', '']))
        elif r < 0.34:
            k = rnd.choice(['resolution', 'bevel', 'sides', 'fill', 'cyclic', 'resolution', 'bevel'])
            v = {'resolution': rnd.choice([1, 2, 3, 5, 12, 64, 0, 65]), 'bevel': q(rnd, -0.25, 0.75),
                 'sides': rnd.choice([3, 4, 6, 9, 64, 2, 65]), 'fill': rnd.choice([0, 1, 2]), 'cyclic': rnd.choice([0, 1])}[k]
            steps.append(f'curve.set {k} {fmt(v)}')
        elif r < 0.38:
            prof = rnd.choice(names + ['none', 'nothing'])
            steps.append(f'curve.set profile {prof}')
        elif r < 0.52:
            s = rnd.random()
            if s < 0.25:
                steps.append('curve.select all')
            elif s < 0.3:
                steps.append('curve.select none')
            else:
                steps.append('curve.select ' + ' '.join(str(rnd.randrange(12)) for _ in range(rnd.randint(1, 4))))
        elif r < 0.62:
            steps.append(f'curve.move {rnd.randrange(10)} {P()}' + rnd.choice(['', '', ' left', ' right']))
        elif r < 0.68:
            steps.append('curve.subdivide')
        elif r < 0.72:
            steps.append('curve.delete')
        elif r < 0.78:
            steps.append(f'curve.extrude {P()}')
        elif r < 0.82:
            steps.append('curve.cyclic')
        elif r < 0.88:
            steps.append('curve.handle ' + rnd.choice(['auto', 'aligned', 'vector', 'free', '']))
        elif r < 0.93:
            steps.append(f'curve.tilt {fmt(q(rnd, -180, 180, 4))}')
        elif r < 0.97:
            steps.append(f'curve.radius {fmt(q(rnd, -0.5, 2))}')
        else:
            steps.append('curve.to_mesh')
    return steps


def whole(path, ranges=True):
    """What is wrong with a saved file's curves ([] when nothing): every record on a
    mesh of the file, its splines tiling its points, its numbers finite; with
    ranges, the values as the operators keep them (resolution 1..64, 3..256 sides,
    bevel and radius not below 0)."""
    bad = []
    nm = len(beefile.meshes(path))
    for ix, n, blk in curv_records(path):
        nspl, npts = struct.unpack_from('<II', blk, 0)
        res, bevel, sides = struct.unpack_from('<ifi', blk, 20)
        if ix >= nm:
            bad.append(f'record on mesh {ix} of {nm}')
        if npts != n or nspl > 32:
            bad.append(f'mesh {ix}: {npts} points ({n} in the record), {nspl} splines')
            continue
        at = 0
        for k in range(nspl):
            typ, cyc, first, cnt = struct.unpack_from('<4I', blk, 60 + 16 * k)
            if first != at:
                bad.append(f'mesh {ix}: spline {k} starts at {first}, not {at}')
                break
            at += cnt
        else:
            if at != npts:
                bad.append(f'mesh {ix}: the splines hold {at} of {npts} points')
        vals = [bevel]
        for k in range(n):
            vals += struct.unpack_from('<11f', blk, 572 + 48 * k)
        if not all(math.isfinite(x) for x in vals):
            bad.append(f'mesh {ix}: a number not finite')
        if ranges:
            rads = [struct.unpack_from('<f', blk, 572 + 48 * k + 36)[0] for k in range(n)]
            if not (1 <= res <= 64 and 3 <= sides <= 256 and bevel >= 0 and all(r >= 0 for r in rads)):
                bad.append(f'mesh {ix}: resolution {res}, {sides} sides, bevel {bevel}, radii from {min(rads, default=0)}')
    for name, (v, p, c, loc) in scene_of(path).items():
        if not all(math.isfinite(x) for x in struct.unpack(f'<{len(v) // 4}f', v)):
            bad.append(f'{name}: a vertex not finite')
        if any(i >= len(v) // 12 for pl in p for i in pl):
            bad.append(f'{name}: a polygon past the vertices')
    return bad


def run_session(steps, tag):
    """BeeModel runs the steps from the empty scene (--op): its file."""
    b = f'{T}/{tag}-p.bee'
    if os.path.exists(b):
        os.remove(b)
    args = ['--op', f'file.open {EMPTY}']
    for s in steps:
        args += ['--select', s[7:]] if s.startswith('select ') else ['--op', s]
    args += ['--op', f'file.save_as {b}']
    port(*args)
    return b


def loaded(block):
    """What a curve keeps through a load: its points, its settings (a load drops the
    splines left empty, so the spline list and the active one may change)."""
    return block[4:8] + block[20:40] + block[572:]


def same_scene(a, b, what, quiet=False, cmp=None):
    """Two files: the same objects, meshes, places and curves (but the capacity)."""
    cmp = cmp or masked
    if not (os.path.exists(a) and os.path.exists(b)):
        check(False, f'{what}: both saved ({os.path.exists(a)}, {os.path.exists(b)})')
        return False
    sa, sb = scene_of(a), scene_of(b)
    bad = []
    if sorted(sa) != sorted(sb):
        bad.append(f'objects {sorted(sa)} / {sorted(sb)}')
    for k in sa:
        if k not in sb:
            continue
        x, y = sa[k], sb[k]
        if x[0] != y[0]:
            bad.append(f'{k}: vertices ({len(x[0]) // 12} / {len(y[0]) // 12})')
        if x[1] != y[1]:
            bad.append(f'{k}: polygons ({len(x[1])} / {len(y[1])})')
        if (x[2] is None) != (y[2] is None):
            bad.append(f'{k}: curve {x[2] is not None} / {y[2] is not None}')
        elif x[2] is not None and cmp(x[2]) != cmp(y[2]):
            d = [i for i in range(min(len(x[2]), len(y[2]))) if x[2][i] != y[2][i]]
            bad.append(f'{k}: curve block ({len(x[2])} / {len(y[2])} bytes, first differences at {d[:6]})')
        if x[3] != y[3]:
            bad.append(f'{k}: place {x[3]} / {y[3]}')
    if bad or not quiet:
        check(not bad, f'{what}: {len(sa)} objects, meshes and curves the same' + (f' -- {bad[:4]}' if bad else ''))
    return not bad


def resave(src, dst):
    if os.path.exists(dst):
        os.remove(dst)
    port('--op', f'file.open {src}', '--op', f'file.save_as {dst}')


def saved_whole(b, what):
    """A session's file: saved, whole, the same after save -> open -> save (points,
    settings and meshes; empty splines dropped), and the same again after a second."""
    if not os.path.exists(b):
        check(False, f'{what}: saved')
        return False
    bad = whole(b)
    b2, b3 = b[:-4] + '-again.bee', b[:-4] + '-again2.bee'
    resave(b, b2)
    resave(b2, b3)
    same = same_scene(b, b2, '', quiet=True, cmp=loaded) and same_scene(b2, b3, '', quiet=True)
    check(not bad and same, f'{what}: {len(scene_of(b))} objects, {len(curv_records(b))} curves, whole, the same after save -> open -> save'
          + (f' -- {bad[:4]}' if bad else '') + ('' if same else ' -- not the same read back'))
    return not bad and same


def s_ops(rnd):
    print('-- random sessions of the curve operators')
    for r in range(RUNS):
        steps = session(rnd, rnd.randint(8, 40))
        b = run_session(steps, f'ops{r}')
        if not saved_whole(b, f'session {r} ({len(steps)} steps)'):
            for s in steps:
                print('       ', s)


def s_fixed():
    print('-- the three kinds, bevel, profile, fill, tilt and radius')
    steps = ['create.bezier', 'curve.set bevel 0.25', 'curve.set fill 1', 'create.curve_circle', 'curve.set resolution 5',
             'create.path', 'curve.set profile BezierCircle', 'curve.select 1 3', 'curve.tilt 45', 'curve.radius 1.5',
             'create.bezier', 'curve.point 1 2 3', 'curve.point -1 1 2', 'curve.select all', 'curve.subdivide', 'curve.set cyclic 1',
             'curve.set bevel 0.5', 'curve.set sides 5', 'curve.handle vector', 'curve.move 2 0 3 0 left',
             # (an extrude deselects the end: a delete after takes the new point alone; a radius below 0 is 0)
             'create.path', 'curve.select 4', 'curve.extrude 1 0 1', 'curve.delete', 'curve.select 0 1', 'curve.radius -0.5',
             'curve.set bevel 0.25',
             # (a profile's change reaches the curves sweeping it)
             'create.curve_circle', 'create.path', 'curve.set profile BezierCircle.001', 'select BezierCircle.001', 'curve.set resolution 3',
             'curve.select 0', 'curve.move 0 2 0 0']
    b = run_session(steps, 'fixed')
    saved_whole(b, 'a fixed session')


def write_bee(path, chs):
    """A version 1 file of these chunks (ZCHK inflated)."""
    out = [b'BEEM', struct.pack('<I', 1)]
    for t, b in chs:
        out += [t, struct.pack('<I', len(b)), b]
    open(path, 'wb').write(b''.join(out))


def s_files(rnd):
    print('-- the CURV chunk read back, values out of range, and damaged')
    steps = ['create.bezier', 'curve.set bevel 0.25', 'curve.point 2 1 0', 'create.curve_circle', 'curve.set cyclic 0',
             'create.path', 'curve.set profile BezierCircle', 'curve.spline bezier cyclic', 'curve.point 0 0 3', 'curve.point 1 0 3',
             'curve.point 1 1 3', 'curve.select 0 2', 'curve.handle free', 'curve.add empty']
    b = run_session(steps, 'files')
    if not os.path.exists(b):
        check(False, 'the files session saved')
        return
    # its file read back: the CURV records as they were (the capacity aside)
    bb = f'{T}/files-pp.bee'
    resave(b, bb)
    rb, rbb = curv_records(b), curv_records(bb)
    check(len(rb) == 4 and [(x, n, masked(k)) for x, n, k in rb] == [(x, n, masked(k)) for x, n, k in rbb],
          f'four curves read back: CURV records the same but the capacity ({len(rb)}, {len(rbb)})')
    same_scene(b, bb, 'and the meshes')
    # a curve read from a file has room for its points (16 at least), not the room the edits had
    pcaps = [(struct.unpack_from('<I', k, 8)[0], max(16, n)) for x, n, k in rbb]
    check(pcaps and any(struct.unpack_from('<I', k, 8)[0] != max(16, n) for x, n, k in rb) and all(c == w for c, w in pcaps),
          f'a curve read from its file: room for the points, not the room the edits had ({pcaps})')
    # a curve from a file edits as one made in the session (the next point, a bevel)
    c1, c2 = f'{T}/files-e1.bee', f'{T}/files-e2.bee'
    for f in (c1, c2):
        if os.path.exists(f):
            os.remove(f)
    port('--op', f'file.open {EMPTY}', *sum((['--op', s] for s in steps), []), '--select', 'Path', '--op', 'curve.point 5 5 5',
         '--op', 'curve.set bevel 0.1', '--op', f'file.save_as {c1}')
    port('--op', f'file.open {b}', '--select', 'Path', '--op', 'curve.point 5 5 5', '--op', 'curve.set bevel 0.1', '--op', f'file.save_as {c2}')
    same_scene(c1, c2, 'a curve read from a file, then edited: as edited in the session')

    base = list(beefile.chunks(b))
    # values a file may hold that the operators refuse: read as the clamped ones (resolution 1..64, 3 sides at least), then an edit
    crv0 = beefile.chunk(b, b'CURV')

    def with_value(off, val, d):
        c = bytearray(crv0)
        o = 0
        while len(c) - o >= 8:   # (every record)
            n = struct.unpack_from('<I', c, o + 4)[0]
            struct.pack_into('<i', c, o + off, val)
            o += n * 48 + 580
        write_bee(d, [(t, bytes(c) if t == b'CURV' else x) for t, x in base])

    def edited(src, out):
        if os.path.exists(out):
            os.remove(out)
        port('--op', f'file.open {src}', '--select', 'BezierCurve', '--op', 'curve.point 1 2 3', '--select', 'BezierCircle',
             '--op', 'curve.set bevel 0.2', '--op', f'file.save_as {out}')
        return {k: v[:2] for k, v in scene_of(out).items()} if os.path.exists(out) else None

    for what, off, val, like in (('resolution 200', 8 + 24 - 4, 200, 64), ('resolution 0', 8 + 24 - 4, 0, 1), ('one side', 8 + 32 - 4, 1, 3)):
        with_value(off, val, f'{T}/odd.bee')
        with_value(off, like, f'{T}/like.bee')
        x, y = edited(f'{T}/odd.bee', f'{T}/odd-p.bee'), edited(f'{T}/like.bee', f'{T}/like-p.bee')
        check(x is not None and x == y and not whole(f'{T}/odd-p.bee', ranges=False),
              f'{what} in the file, then an edit: the meshes of {like}')

    crv = crv0
    cases = [('cut short', crv[:len(crv) // 2]), ('one byte', crv[:1]), ('empty', b''), ('index past the meshes', b'\xff\xff\x00\x00' + crv[4:]),
             ('a huge point count', crv[:4] + struct.pack('<I', 5000000) + crv[8:]),
             ('splines not tiling the points', crv[:8 + 64 - 4 + 8] + struct.pack('<I', 7) + crv[8 + 64 - 4 + 12:]),
             ('a wrong point count inside', crv[:8 + 4] + struct.pack('<I', 99) + crv[16:]),
             ('too many splines', crv[:8] + struct.pack('<I', 33) + crv[12:])]
    for k in range(max(4, RUNS)):
        c = bytearray(crv)
        for _ in range(rnd.randint(1, 8)):
            c[rnd.randrange(len(c))] = rnd.randrange(256)
        cases.append((f'garbage {k}', bytes(c)))
    good = 0
    for what, c in cases:
        d = f'{T}/dmg.bee'
        write_bee(d, [(t, c if t == b'CURV' else x) for t, x in base])
        p2 = f'{T}/dmg-p.bee'
        if os.path.exists(p2):
            os.remove(p2)
        r = port('--op', f'file.open {d}', '--op', f'file.save_as {p2}', ok=False)
        if r is None or r.returncode != 0 or not os.path.exists(p2):
            check(False, f'damaged CURV ({what}): read and saved ({None if r is None else r.returncode})')
            continue
        bad = whole(p2, ranges=False)
        if bad:
            check(False, f'damaged CURV ({what}): what is kept is whole -- {bad[:3]}')
            continue
        good += 1
    check(good == len(cases), f'damaged CURV chunks: {good} of {len(cases)} read and saved again whole')


def s_undo():
    print('-- undo and redo')
    st = f'{T}/u'
    files = [f'{st}{k}.bee' for k in range(6)]
    for f in files:
        if os.path.exists(f):
            os.remove(f)
    seq = ['create.bezier', 'curve.point 2 1 0', 'curve.set bevel 0.25', 'curve.select all', 'curve.subdivide']
    args = ['--op', f'file.open {EMPTY}']
    for k, s in enumerate(seq):
        args += ['--op', s, '--op', f'file.save_as {files[k]}']
    # back two steps, then forward one
    args += ['--key', 'ctrl+z', '--key', 'ctrl+z', '--op', f'file.save_as {files[5]}']
    port(*args)
    # (curve.select is no step: it marks the points in place)
    ok = os.path.exists(files[5]) and os.path.exists(files[1])
    a = scene_of(files[5]) if ok else {}
    b = scene_of(files[1]) if ok else {}
    check(ok and a == b and a != scene_of(files[2]), 'two undos bring back the curve and its mesh as they were two steps before')
    args2 = args[:-2] + ['--key', 'ctrl+shift+z', '--op', f'file.save_as {files[5]}']
    port(*args2)
    a = scene_of(files[5]) if os.path.exists(files[5]) else {}
    b = scene_of(files[3]) if os.path.exists(files[3]) else {}
    check(a == b and a != {} and a != scene_of(files[4]), 'a redo brings the next step back (its points still selected)')
    # an undo after a session of edits gives the step before
    seq2 = ['create.path', 'curve.select 1', 'curve.move 1 0 2 0', 'curve.set bevel 0.3', 'curve.set profile none', 'curve.extrude 1 0 0']
    args = ['--op', f'file.open {EMPTY}']
    for s in seq2:
        args += ['--op', s]
    args += ['--key', 'ctrl+z', '--op', f'file.save_as {files[4]}']
    port(*args)
    o4 = run_session(seq2[:-1], 'u-before')
    same_scene(o4, files[4], 'undo of an extrude: the curve as it was before')


# ---- the chain functions (geometry nodes' curve nodes) through tests/curvedrv.zig -----------

DRV = None


def build_driver():
    """tests/curvedrv.zig built against src/curve.zig (into the temp dir)."""
    global DRV
    if DRV:
        return DRV
    zig = shutil.which('zig')
    cmd = [zig] if zig else ['mise', 'exec', '--', 'zig']
    out = f'{T}/curvedrv'
    r = subprocess.run(cmd + ['build-exe', '--cache-dir', f'{T}/zcache', '--dep', 'curve', f'-Mroot={HERE}/curvedrv.zig',
                              f'-Mcurve={os.environ.get("CV_SRC", ROOT + "/src")}/curve.zig', f'-femit-bin={out}'], capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0:
        print(r.stderr[-2000:])
        return None
    DRV = out
    return out


class NodeGen:
    """Random curve-node cases: sources (curve circle, line, transformed,
    joined, resampled, filleted) and the node on them."""

    def __init__(self, rnd):
        self.rnd = rnd

    def q(self, lo, hi, den=64):
        return self.rnd.randint(int(lo * den), int(hi * den)) / den

    def src(self):
        k = self.rnd.random()
        if k < 0.07:
            return ('cube', self.q(0.5, 2))   # (no chains: a profile or a curve of faces)
        if k < 0.3:
            return ('circle', self.rnd.choice([2, 3, 4, 5, 8, 12, 33]), self.q(0.25, 3))
        if k < 0.55:
            return ('line', (self.q(-3, 3), self.q(-3, 3), self.q(-3, 3)), (self.q(-3, 3), self.q(-3, 3), self.q(-3, 3)))
        if k < 0.75:
            return ('xform', self.src(), self.rnd.choice([0, 30, 45, 90, 17]), self.rnd.choice([0, 20, 60]), self.rnd.choice([0, 10, 90]))
        if k < 0.85:
            return ('join', self.src(), self.src())
        if k < 0.93:
            return ('resample', self.src(), self.rnd.choice([0, 3, 5, 9]), self.q(0, 1.5))
        return ('fillet', ('resample', self.src(), self.rnd.choice([4, 5, 7]), 0), self.q(0, 1), self.rnd.choice([0, 1, 3, 8]))

    def case(self):
        k = self.rnd.randrange(7)
        if k == 0:
            return ('line', (self.q(-3, 3), self.q(-3, 3), self.q(-3, 3)), (self.q(-3, 3), self.q(-3, 3), self.q(-3, 3)))
        if k == 1:
            return ('circle', self.rnd.choice([-1, 0, 2, 3, 4, 7, 64, 300]), self.q(-1, 3))
        if k == 2:
            prof = self.src() if self.rnd.random() < 0.4 else None
            return ('tomesh', self.src(), prof, self.q(-0.25, 1), self.rnd.choice([0, 3, 4, 6, 9]), self.rnd.choice([0, 1]))
        if k == 3:
            return ('resample', self.src(), self.rnd.choice([0, -2, 1, 2, 5, 17]), self.q(-0.5, 2))
        if k == 4:
            return ('trim', self.src(), self.q(-0.25, 1.25), self.q(-0.25, 1.25))
        if k == 5:
            return ('fillet', self.src(), self.q(0, 2), self.rnd.choice([-1, 0, 1, 2, 5, 70]))
        return ('points', self.src(), self.rnd.choice([0, 1, 2, 3, 8]))

    def emit(self, t, node, lines, ctr):
        ctr[0] += 1
        v = f'n{ctr[0]}'
        op = node[0]
        if op == 'cube':
            lines.append(f'{v} = gnode({t}, "cube", {node[1]})')
        elif op == 'circle':
            lines.append(f'{v} = gnode({t}, "curve_circle", {node[1]}, {node[2]})')
        elif op == 'line':
            lines.append(f'{v} = gnode({t}, "curve_line")')
            lines.append(f'gset({t}, {v}, 1, {node[1][0]}, {node[1][1]}, {node[1][2]})')
            lines.append(f'gset({t}, {v}, 2, {node[2][0]}, {node[2][1]}, {node[2][2]})')
        elif op == 'xform':
            c = self.emit(t, node[1], lines, ctr)
            lines.append(f'{v} = gnode({t}, "transform", {node[2]}, {node[3]}, {node[4]})')
            lines.append(f'glink({t}, {c}, {v}, 1)')
        elif op == 'join':
            a = self.emit(t, node[1], lines, ctr); b = self.emit(t, node[2], lines, ctr)
            lines.append(f'{v} = gnode({t}, "join")')
            lines.append(f'glink({t}, {a}, {v}, 1)')
            lines.append(f'glink({t}, {b}, {v}, 2)')
        elif op == 'tomesh':
            c = self.emit(t, node[1], lines, ctr)
            p = self.emit(t, node[2], lines, ctr) if node[2] else None
            lines.append(f'{v} = gnode({t}, "curve_to_mesh", {node[3]}, {node[4]}, {node[5]})')
            lines.append(f'glink({t}, {c}, {v}, 1)')
            if p:
                lines.append(f'glink({t}, {p}, {v}, 2)')
        else:
            name = {'resample': 'resample', 'trim': 'trim', 'fillet': 'fillet', 'points': 'curve_to_points'}[op]
            c = self.emit(t, node[1], lines, ctr)
            vals = ', '.join(str(x) for x in node[2:])
            lines.append(f'{v} = gnode({t}, "{name}", {vals})')
            lines.append(f'glink({t}, {c}, {v}, 1)')
        return v

    def tree_obj(self, name, node, lines, ctr):
        lines.append(f'add("plane", "{name}")')
        lines.append(f't = gtree("{name}")')
        lines.append('o = gnode(t, "output")')
        v = self.emit('t', node, lines, ctr)
        lines.append(f'glink(t, {v}, o, 1)')
        lines.append(f'm = modifier("{name}", "geometry")')
        lines.append(f'modset("{name}", m, "tree", t)')
        lines.append(f'modapply("{name}", m)')



def enc_mesh(m):
    v, polys = m
    b = struct.pack('<I', len(v)) + b''.join(struct.pack('<3f', *x) for x in v)
    off = [0]
    loops = []
    for pl in polys:
        loops += pl
        off.append(len(loops))
    b += struct.pack('<I', len(polys)) + struct.pack(f'<{len(off)}I', *off)
    b += struct.pack('<I', len(loops)) + struct.pack(f'<{len(loops)}I', *loops)
    return b


OPS = {'line': 0, 'circle': 1, 'tomesh': 2, 'resample': 3, 'trim': 4, 'fillet': 5, 'points': 6}


def s_nodes(rnd):
    print('-- the chain functions against the curve nodes in BeeModel (curve line, circle, to mesh, resample, trim, fillet, to points)')
    drv = build_driver()
    if not drv:
        check(False, 'tests/curvedrv.zig builds')
        return
    g = NodeGen(rnd)
    total = same = 0
    counts = {}
    for run in range(max(2, RUNS)):
        cases = [g.case() for _ in range(18)]   # (64 node trees at most)
        if run == 0:   # (a profile without chains and a radius: the round tube)
            cases[0] = ('tomesh', ('line', (0, 0, 0), (2, 1, 0)), ('cube', 1.0), 0.25, 6, 1)
        lines = ['n = count()', 'for i in 0..n { delete(name(0)) }', 'add("plane", "P0")']   # (P0: a plane as it is)
        ctr = [0]
        for i, c in enumerate(cases):
            counts[c[0]] = counts.get(c[0], 0) + 1
            g.tree_obj(f'R{i}', c, lines, ctr)
            if c[0] not in ('line', 'circle'):
                g.tree_obj(f'A{i}', c[1], lines, ctr)
                if c[0] == 'tomesh' and c[2]:
                    g.tree_obj(f'B{i}', c[2], lines, ctr)
        ob = f'{T}/nodes.bee'
        if os.path.exists(ob):
            os.remove(ob)
        lines.append(f'op("file.save", "{ob}")')
        script('\n'.join(lines) + '\n')
        if not os.path.exists(ob):
            check(False, f'nodes run {run}: BeeModel saved its trees\' meshes')
            continue
        objs = {o['name']: o for o in beefile.objects(ob)}
        meshes = beefile.meshes(ob)

        def mesh_of(name):
            o = objs.get(name)
            if o is None:
                return None
            return meshes[o['mesh']] if o['mesh'] < len(meshes) else ([], [])

        blob = b''
        for i, c in enumerate(cases):
            vals = [0.0] * 4
            ins = [(0.0, 0.0, 0.0)] * 3
            if c[0] == 'line':
                ins = [c[1], c[2], (0, 0, 0)]
            elif c[0] == 'circle':
                vals[:2] = c[1:3]
            elif c[0] == 'tomesh':
                vals[:3] = c[3:6]
            else:
                for k, x in enumerate(c[2:]):
                    vals[k] = x
            blob += struct.pack('<I4f', OPS[c[0]], *vals)
            for x in ins:
                blob += struct.pack('<3f', *x)
            ma = mesh_of(f'A{i}') if c[0] not in ('line', 'circle') else ([], [])
            blob += enc_mesh(ma if ma is not None else ([], []))
            mb = mesh_of(f'B{i}') if c[0] == 'tomesh' and c[2] else None
            blob += struct.pack('<I', 1 if mb is not None else 0) + (enc_mesh(mb) if mb is not None else b'')
        open(f'{T}/cases.bin', 'wb').write(blob)
        r = subprocess.run([drv, f'{T}/cases.bin', f'{T}/out.bin'], capture_output=True, timeout=600)
        if r.returncode != 0:
            check(False, f'nodes run {run}: the driver ran ({r.returncode})')
            continue
        d = open(f'{T}/out.bin', 'rb').read()
        o = 0
        for i, c in enumerate(cases):
            nv = struct.unpack_from('<I', d, o)[0]
            o += 4
            want = mesh_of(f'R{i}')
            if nv == 0xffffffff:
                got = None
            elif c[0] == 'points':
                v = [struct.unpack_from('<3f', d, o + 12 * k) for k in range(nv)]
                o += 12 * nv * 2
                got = (v, [])
            else:
                v = [struct.unpack_from('<3f', d, o + 12 * k) for k in range(nv)]
                o += 12 * nv
                np_ = struct.unpack_from('<I', d, o)[0]
                o += 4
                off = struct.unpack_from(f'<{np_ + 1}I', d, o)
                o += 4 * (np_ + 1)
                nl = struct.unpack_from('<I', d, o)[0]
                o += 4
                loops = struct.unpack_from(f'<{nl}I', d, o)
                o += 4 * nl
                got = (v, [list(loops[off[k]:off[k + 1]]) for k in range(np_)])
            total += 1
            wv = [struct.pack('<3f', *x) for x in want[0]] if want else None
            gv = [struct.pack('<3f', *x) for x in got[0]] if got else None
            # (a tree giving no vertices leaves the object's mesh as it was: modapply refuses it)
            if got is not None and not got[0] and mesh_of('P0') is not None:
                got = mesh_of('P0')
                gv = [struct.pack('<3f', *x) for x in got[0]]
            if want is not None and got is not None and wv == gv and want[1] == got[1]:
                same += 1
            else:
                print(f'       case {c}: want {None if want is None else (len(want[0]), len(want[1]))}, got {None if got is None else (len(got[0]), len(got[1]))}')
    check(total > 0 and same == total, f'curve nodes: {same} of {total} meshes bit for bit as the node trees give ({counts})')
    s_odd_meshes(drv)


def mesh_chunk(v, polys):
    loops = [x for p in polys for x in p]
    off = [0]
    for p in polys:
        off.append(off[-1] + len(p))
    return (struct.pack('<III', len(v), len(polys), len(loops)) + b''.join(struct.pack('<3f', *x) for x in v)
            + struct.pack(f'<{len(off)}I', *off) + struct.pack(f'<{len(loops)}I', *loops))


ODD = [  # meshes the curve nodes may get from an object: (name, vertices, polygons)
    ('a 2-point loop', [(0, 0, 0), (1, 0, 0)], [[0, 1], [1, 0]]),
    ('a triangle of lines', [(0, 0, 0), (1, 0, 0), (1, 0, 1)], [[0, 1], [1, 2], [2, 0]]),
    ('lines among faces', [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 1, 1)], [[0, 1], [0, 1, 2], [1, 2], [3], [2, 3], [3, 0]]),
    ('a loop and a tail', [(0, 0, 0), (2, 0, 0), (2, 0, 2), (0, 0, 2), (5, 1, 0)], [[0, 1], [1, 2], [2, 3], [3, 0], [0, 4]]),
    ('a chain back and forth', [(0, 0, 0), (1, 1, 0), (2, 0, 0)], [[0, 1], [1, 2], [2, 1], [1, 0]]),
    # (9 long: by length 2 a closed chain takes 4.5 points, rounded to even: 4)
    ('a square of 9', [(0, 0, 0), (2.25, 0, 0), (2.25, 0, 2.25), (0, 0, 2.25)], [[0, 1], [1, 2], [2, 3], [3, 0]]),
]
ODD_NODES = [('tomesh', 0.125, 4, 1), ('tomesh', 0, 3, 0), ('trim', 0.25, 0.75), ('resample', 5, 0), ('resample', 0, 0.5), ('resample', 0, 2), ('fillet', 0.25, 2), ('points', 0)]


def s_odd_meshes(drv):
    """Hand-made meshes through an object's geometry (the tree's input)."""
    base = f'{T}/odd-base.bee'
    names = [f'M{k}' for k in range(len(ODD))]
    script('n = count()\nfor i in 0..n { delete(name(0)) }\n' + ''.join(f'add("plane", "{n}")\n' for n in names) + f'op("file.save", "{base}")\n')
    if not os.path.exists(base):
        check(False, 'BeeModel saved planes to fill')
        return
    objs = {o['name']: o for o in beefile.objects(base)}
    chs = list(beefile.chunks(base))
    # (each plane its own mesh, after the file's: the planes share one)
    mi = [i for i, (t, c) in enumerate(chs) if t == b'MESH']
    ob = bytearray(beefile.chunk(base, b'OBJS'))
    for k, (what, v, polys) in enumerate(ODD):
        chs.insert(mi[-1] + 1 + k, (b'MESH', mesh_chunk(v, polys)))
        at = [j for j, o in enumerate(beefile.objects(base)) if o['name'] == names[k]][0]
        struct.pack_into('<I', ob, 4 + at * 84 + 80, len(mi) + k)
    chs = [(t, bytes(ob) if t == b'OBJS' else c) for t, c in chs]
    filled = f'{T}/odd-filled.bee'
    write_bee(filled, chs)
    same = total = 0
    for nd in ODD_NODES:
        lines = [f'op("file.open", "{filled}")']
        for n in names:
            lines += [f't = gtree("{n}{nd[0]}")', 'o = gnode(t, "output")', 'i = gnode(t, "input")',
                      f'c = gnode(t, "{dict(tomesh="curve_to_mesh", trim="trim", resample="resample", fillet="fillet", points="curve_to_points")[nd[0]]}", {", ".join(str(x) for x in nd[1:])})',
                      'glink(t, i, c, 1)', 'glink(t, c, o, 1)', f'm = modifier("{n}", "geometry")', f'modset("{n}", m, "tree", t)', f'modapply("{n}", m)']
        ob = f'{T}/odd-out.bee'
        if os.path.exists(ob):
            os.remove(ob)
        lines.append(f'op("file.save", "{ob}")')
        script('\n'.join(lines) + '\n')
        if not os.path.exists(ob):
            check(False, f'odd meshes, {nd}: BeeModel saved')
            continue
        oo = {o['name']: o for o in beefile.objects(ob)}
        om = beefile.meshes(ob)
        blob = b''
        for k, (what, v, polys) in enumerate(ODD):
            vals = list(nd[1:]) + [0.0] * (4 - len(nd[1:]))
            blob += struct.pack('<I4f', OPS[nd[0]], *vals) + struct.pack('<9f', *([0.0] * 9)) + enc_mesh((v, polys)) + struct.pack('<I', 0)
        open(f'{T}/cases.bin', 'wb').write(blob)
        subprocess.run([drv, f'{T}/cases.bin', f'{T}/out.bin'], capture_output=True, timeout=300)
        d = open(f'{T}/out.bin', 'rb').read()
        o = 0
        for k, (what, v, polys) in enumerate(ODD):
            nv = struct.unpack_from('<I', d, o)[0]
            o += 4
            gv, gp = [], []
            if nv != 0xffffffff:
                gv = [struct.pack('<3f', *struct.unpack_from('<3f', d, o + 12 * j)) for j in range(nv)]
                o += 12 * nv
                if nd[0] == 'points':
                    o += 12 * nv
                else:
                    np_ = struct.unpack_from('<I', d, o)[0]
                    o += 4
                    off = struct.unpack_from(f'<{np_ + 1}I', d, o)
                    o += 4 * (np_ + 1)
                    nl = struct.unpack_from('<I', d, o)[0]
                    o += 4
                    loops = struct.unpack_from(f'<{nl}I', d, o)
                    o += 4 * nl
                    gp = [list(loops[off[j]:off[j + 1]]) for j in range(np_)]
            w = om[oo[names[k]]['mesh']] if names[k] in oo else None
            total += 1
            if nv == 0:   # (no vertices: the object keeps its own mesh)
                gv, gp = [struct.pack('<3f', *x) for x in v], polys
            if w is not None and [struct.pack('<3f', *x) for x in w[0]] == gv and w[1] == gp:
                same += 1
            else:
                print(f'       {what}, {nd}: want {None if w is None else (len(w[0]), len(w[1]))}, got {(len(gv), len(gp))}')
    check(total > 0 and same == total, f'hand-made line meshes through the curve nodes: {same} of {total} as the node trees give')


def s_perf(rnd):
    print('-- the time of a big sweep (release build, one CPU)')
    pts = [f'curve.point {math.cos(k * 0.05) * (3 + k * 0.01):.4f} {k * 0.004:.4f} {math.sin(k * 0.05) * (3 + k * 0.01):.4f}' for k in range(400)]
    base = ['create.bezier'] + pts + ['curve.set resolution 64']
    heavy = ['curve.set sides 64', 'curve.set bevel 0.1']

    # the run with the two steps less the run without (best of 3)
    def wall(extra):
        args = ['--op', f'file.open {EMPTY}']
        for st in base + extra:
            args += ['--op', st]
        best = 1e9
        for _ in range(3):
            t0 = time.time()
            r = port(*args, binary=REL)
            if r is None or r.returncode != 0:
                return None
            best = min(best, time.time() - t0)
        return best
    a, b = wall(heavy), wall([])
    check(a is not None and b is not None, 'the release build runs the sweep')
    if a is not None and b is not None:
        print(f'       {(a - b) * 1000:.0f} ms (a 400-point Bezier, resolution 64, 64 sides, twice: {399 * 64 + 1} rings)')


def s_fuzz(rnd):
    print('-- random operators, words and keys on the debug build: no crash, no hang')
    words = ['', 'nan', 'inf', '-inf', '1e30', '-1e30', '0', '-1', '3.5', '99999999', 'all', 'none', 'left', 'right', 'bezier', 'poly',
             'cyclic', 'profile', 'resolution', 'bevel', 'sides', 'fill', 'x', '"', '\\\\', 'BezierCurve', 'Path', 'BezierCircle']
    ops = ['create.bezier', 'create.curve_circle', 'create.path', 'curve.add', 'curve.set', 'curve.point', 'curve.spline', 'curve.to_mesh',
           'curve.select', 'curve.move', 'curve.select_all', 'curve.extrude', 'curve.subdivide', 'curve.delete', 'curve.cyclic', 'curve.handle',
           'curve.tilt', 'curve.radius', 'object.delete', 'object.duplicate']
    keys = ['tab', 'g', 'r', 's', 'x', 'y', 'z', '1', 'enter', 'esc', 'e', 'w', 'v', 'a', 'alt+c', 'ctrl+z', 'ctrl+shift+z', 'delete']
    crashed = 0
    for run in range(max(2, RUNS)):
        args = ['--op', f'file.open {EMPTY}', '--op', 'create.bezier', '--move', '600,400']
        for _ in range(rnd.randint(20, 60)):
            r = rnd.random()
            if r < 0.6:
                a = ' '.join(rnd.choice(words + [str(rnd.uniform(-5, 5))]) for _ in range(rnd.randint(0, 5)))
                args += ['--op', (rnd.choice(ops) + ' ' + a).strip()]
            elif r < 0.9:
                args += ['--key', rnd.choice(keys)]
            else:
                args += ['--click', f'{rnd.randint(300, 900)},{rnd.randint(150, 600)}']
        args += ['--op', f'file.save_as {T}/fz.bee']
        p = port(*args, ok=False, timeout=300)
        if p is None or p.returncode != 0:
            crashed += 1
            print('       ', (p.stderr[-600:] if p else 'hung'))
            print('       ', ' '.join(args)[:3000])
    check(crashed == 0, f'random curve sessions: {max(2, RUNS) - crashed} of {max(2, RUNS)} ran to the end')


def s_order():
    print('-- CURV in the MESH chunks\' order when slots are reused, and cloth on a curve')
    # (the first curve's mesh made again last: its slot comes after the others', its MESH chunk first)
    steps = ['create.bezier', 'create.path', 'create.curve_circle', 'select BezierCurve', 'curve.set bevel 0.1',
             'select Path', 'curve.set resolution 5', 'select BezierCurve', 'curve.point 1 2 3']
    b = run_session(steps, 'order')
    rb = curv_records(b)
    check(len(rb) == 3 and [r[0] for r in rb] == [0, 1, 2], f'CURV records in the MESH chunks\' order ({[r[0] for r in rb]})')
    saved_whole(b, 'and read back')
    # cloth on a curve object: its shown copies freed with the curve still on the scene's mesh (a
    # copy carrying the curve unrefs it twice: freed under the object, the edits after read garbage
    # or the debug build stops)
    steps = ['create.bezier', 'curve.set bevel 0.2', 'curve.point 2 0 1', 'cloth.add cloth', 'anim.frame 5', 'anim.frame 12', 'anim.frame 1',
             'cloth.remove', 'curve.point 1 1 1', 'curve.set bevel 0.3', 'create.path', 'curve.set resolution 7', 'select BezierCurve',
             'curve.select all', 'curve.subdivide', 'curve.set sides 5']
    b = run_session(steps, 'clc')
    saved_whole(b, 'cloth on a curve: frames, removed, then the curve edited')
    r = port('--op', f'file.open {b}', '--select', 'BezierCurve', '--op', 'cloth.add cloth', '--op', 'anim.frame 6', '--op', 'cloth.remove',
             '--key', 'ctrl+z', '--op', 'anim.frame 9', '--key', 'ctrl+z', '--key', 'ctrl+shift+z', '--op', 'object.delete', '--key', 'ctrl+z',
             '--op', 'curve.set bevel 0.1', '--op', f'file.save_as {T}/clc2.bee', ok=False)
    check(r is not None and r.returncode == 0 and len(curv_records(f'{T}/clc2.bee')) == 2 and not whole(f'{T}/clc2.bee'),
          f'and with undo, redo and delete after: ran through ({None if r is None else r.returncode})' + ('' if r is None or r.returncode == 0 else ' ' + r.stderr[-300:]))


def main():
    rnd = random.Random(SEED)
    if not make_empty():
        check(False, 'BeeModel made an empty scene')
        return
    for name in ('s_fixed', 's_order', 's_ops', 's_files', 's_undo', 's_nodes', 's_fuzz', 's_perf'):
        if ONLY and name not in ONLY:
            continue
        f = globals()[name]
        f(rnd) if name in ('s_ops', 's_files', 's_nodes', 's_fuzz', 's_perf') else f()


main()
print(f'curves: fails {len(FAILS)}')
