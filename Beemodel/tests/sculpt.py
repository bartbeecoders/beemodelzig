#!/usr/bin/env python3
"""Sculpt mode: every brush, falloff, symmetry and the mask move the mesh (all
vertices finite, the counts kept), the same stroke twice on one CPU gives the same
bits and on every core within TOL. Undo with values, across modes, modifiers, shape
keys, skins, shared meshes and files (save, open, save: the same mesh); mouse
strokes with keys and modifiers; a real window in the fake compositor (tests/wl_fake.py);
the UI; damaged input.

    python3 tests/sculpt.py BIN [fuzz-runs=40] [seed] [scenario...]
"""
import hashlib, math, os, random, shutil, struct, subprocess, sys, tempfile, time
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

def wait_saved(f, path, limit=60.0):
    """A save through the window is done when its file is there (atomicfile: whole
    or absent). A fixed pause lost the save under load, and the comparison then
    read the previous case's file."""
    t0 = time.time()
    while not os.path.exists(path) and time.time() - t0 < limit:
        f.pump(0.1)


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 40
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
WANT = sys.argv[4:]
FAILS = []
T = tempfile.mkdtemp(prefix='beesc-', dir=os.environ.get('BEERIG_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)
# One CPU: nothing then depends on which thread sums first, a stroke is the same
# to the bit run to run. Side by side, give each suite its own BEE_CPU.
CPU = os.environ.get('BEE_CPU', '2')
ONE = ['taskset', '-c', CPU]
ONLY = os.environ.get('SCULPT_ONLY', '')  # (the mouse cases with this in their name)
# every core: the area normal's sums come in another order, the last bits differ
TOL = 5e-7


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def make(code, one=True):
    """A script run by BeeModel (--run): its stdout (a script in a file: any length)."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    r = subprocess.run((ONE if one else []) + [BIN, '--run', p], capture_output=True, text=True, timeout=900, env=ENV)
    if 'error:' in r.stdout + r.stderr:
        print((r.stdout + r.stderr)[-600:])
    return r.stdout


def port(*a, ok=True, one=True, size=None):
    r = subprocess.run((ONE if one else []) + [BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *(('--size', size) if size else ()), *a], capture_output=True, text=True, timeout=900, env=ENV)
    if ok and r.returncode != 0:
        print(r.stderr[-1500:])
        check(False, f'BeeModel stopped ({r.returncode}): {list(a)[:6]}')
    return r


def ops(*lines):
    return [x for ln in lines for x in ('--op', ln)]


def mesh_of(path, name):
    objs = beefile.objects(path)
    ms = beefile.meshes(path)
    return ms[next(o for o in objs if o['name'] == name)['mesh']]


def verts(path, name):
    return mesh_of(path, name)[0]


def raw(path, name):
    """The MESH chunk of an object, as bytes."""
    objs = beefile.objects(path)
    k = next(o for o in objs if o['name'] == name)['mesh']
    return [b for t, b in beefile.chunks(path) if t == b'MESH'][k]


def dumped(path):
    return [tuple(float.fromhex(x) for x in ln.split()) for ln in open(path)]


def worst(a, b):
    return max((abs(p - q) for x, y in zip(a, b) for p, q in zip(x, y)), default=0.0)


def moved(a, b):
    return sum(1 for x, y in zip(a, b) if x != y)


def same(name, a, b, before=None, tol=0.0):
    if len(a) != len(b) or not a:
        check(False, f'{name}: {len(a)} and {len(b)} vertices')
        return
    w = worst(a, b)
    n = '' if before is None else f', {moved(a, before)} moved'
    if before is not None and moved(a, before) == 0 and tol >= 0:
        check(False, f'{name}: nothing moved')
        return
    check(w <= tol, f'{name}: {len(a)} vertices{n}, worst {w:.2e}')


def finite(v):
    return all(math.isfinite(c) for x in v for c in x)


def moves(name, c, before=None):
    """A stroke's result: the vertices all finite, as many as before, and
    (given the mesh before) something moved."""
    if before is not None and len(c) != len(before):
        check(False, f'{name}: {len(c)} vertices, {len(before)} before')
        return
    n = '' if before is None else f', {moved(c, before)} moved'
    if before is not None and moved(c, before) == 0:
        check(False, f'{name}: nothing moved')
        return
    check(c and finite(c), f'{name}: {len(c)} vertices{n}, all finite')


BALL = '''delete("Cube")
add("sphere", "S", 0, 2, 0)
modifier("S", "subsurf")
modset("S", 0, "levels", %d)
modapply("S", 0)
'''
STROKE = '-0.5 2 1 0.5 2.2 0.9 0.4 0.5'
BRUSHES = ['draw', 'clay strips', 'crease', 'inflate', 'grab', 'snake hook', 'smooth', 'flatten', 'pinch', 'layer', 'mask']


def bases():
    """The scenes, made by BeeModel's scripts."""
    p = f'{T}/ball.bee'
    if os.path.exists(p):
        return
    make(BALL % 3 + f'op("file.save", "{p}")\n')
    make(BALL % 2 + f'''add("cylinder", "C", 2, 1, 0)
add("cube", "B", -3, 1, 1)
move("S", 0.5, 0.25, -0.3)
rotate("S", 0.3, -0.4, 0.2)
scale("S", 1.5, 1.5, 1.5)
op("file.save", "{T}/mix.bee")
''')
    check(os.path.exists(p), 'the scenes saved')


def stroked(base, name, cmds, tag='', one=True):
    """Console lines on a file: the mesh after them."""
    q = f'{T}/p{tag}.bee'
    port('--op', f'file.open {base}', *ops(*cmds), '--op', f'file.save {q}', one=one)
    return verts(q, name)


def world(args):
    """A stroke's words as BeeScript arguments (tests/dyntopo.py uses it)."""
    return ', '.join(args.split())


def s_brushes():
    print('-- each brush --')
    bases()
    base = f'{T}/ball.bee'
    b0 = verts(base, 'S')
    check(len(b0) == 31746, f'the ball has {len(b0)} vertices in many leaves')
    res = {}
    for b in BRUSHES:
        c = stroked(base, 'S', [f'sculpt S "{b}" {STROKE}'])
        if b == 'mask':
            check(c == b0, 'mask: moves nothing')
        else:
            moves(b, c, b0)
            res[b] = c
    # (layer is draw up to its height: one stroke stays under it)
    same_ = [(x, y) for x in res for y in res if x < y and res[x] == res[y] and (x, y) != ('draw', 'layer')]
    check(not same_, f'{len(res)} brushes, different results (but draw and layer: {same_})')
    c2 = stroked(base, 'S', [f'sculpt S "draw" {STROKE}'])
    check(c2 == res['draw'], 'the same stroke again on one CPU: the same bits')
    print('-- the next stroke reads the normals the last one left --')
    st2 = '-0.2 2.2 1 0.8 2.5 0.7 0.5 0.5'
    for b in ('draw', 'inflate', 'flatten'):
        c = stroked(base, 'S', [f'sculpt S "draw" {STROKE}', f'sculpt S "{b}" {st2}'])
        moves(f'draw, then {b} beside it', c, res['draw'])
    print('-- inverted, twice over, at other strengths --')
    for b, s in (('draw', -0.7), ('clay strips', -0.5), ('crease', -1), ('pinch', -0.5), ('smooth', 1), ('flatten', 0.2), ('inflate', -0.3), ('layer', 2.5)):
        st = STROKE.rsplit(' ', 1)[0] + f' {s}'
        c = stroked(base, 'S', [f'sculpt S "{b}" {st}', f'sculpt S "{b}" {st}'])
        moves(f'{b} {s}', c, b0)
        check(c != res.get(b), f'{b} {s}: not the one stroke at 0.5')


def s_falloff():
    print('-- each falloff, each symmetry --')
    bases()
    base = f'{T}/ball.bee'
    b0 = verts(base, 'S')
    results = []
    for k in ('smooth', 'sphere', 'root', 'sharp', 'linear', 'constant'):
        c = stroked(base, 'S', [f'sculpt.falloff {k}', f'sculpt S "draw" {STROKE}'])
        moves(f'falloff {k}', c, b0)
        results.append(c)
    check(all(results[i] != results[j] for i in range(6) for j in range(i)), 'six different curves')
    for sy in ('x', 'y', 'z', 'xy', 'xz', 'yz', 'xyz', 'none'):
        for b in ('draw', 'grab', 'snake hook', 'smooth'):
            c = stroked(base, 'S', [f'sculpt.symmetry {sy}', f'sculpt S "{b}" 0.3 2.5 0.8 0.4 2.6 0.7 0.45 0.6'])
            moves(f'symmetry {sy}, {b}', c, b0)
    # (a mirror is more than the first dab: the ball sits on y = 2, its mirrors in y miss)
    c = stroked(base, 'S', ['sculpt.symmetry x', 'sculpt S "draw" 0.3 2.5 0.8 0.4 2.6 0.7 0.45 0.6'])
    c2 = stroked(base, 'S', ['sculpt S "draw" 0.3 2.5 0.8 0.4 2.6 0.7 0.45 0.6'])
    check(moved(c, b0) > moved(c2, b0) * 1.5, f'X symmetry moves the other side too ({moved(c2, b0)} -> {moved(c, b0)})')


def s_mask():
    print('-- the mask --')
    bases()
    base = f'{T}/ball.bee'
    b0 = verts(base, 'S')
    d = 'sculpt S "draw" -0.3 2.1 1 0.3 2.1 1 0.5 0.8'
    m = f'sculpt S "mask" {STROKE}'
    c0 = stroked(base, 'S', [d])
    c1 = stroked(base, 'S', [m, d])
    moves('a masked stroke', c1, b0)
    check(moved(c1, c0) > 100, f'the mask holds part of it back ({moved(c1, c0)} vertices elsewhere)')
    c2 = stroked(base, 'S', [m, 'sculpt.mask_invert', d])
    moves('inverted', c2, b0)
    check(moved(c2, c1) > 100, 'the inverse is another result')
    c3 = stroked(base, 'S', [m, 'sculpt.mask_clear', d])
    moves('cleared', c3, b0)
    check(worst(c3, c0) < 1e-6, f'cleared: as if it never was ({worst(c3, c0):.1e}: normals done over)')
    check(moved(c2, c3) > 100, 'inverted is not cleared')
    c4 = stroked(base, 'S', [m, f'sculpt S "mask" {STROKE.rsplit(" ", 1)[0]} -0.5', d])
    moves('a negative mask stroke erases', c4, b0)
    check(moved(c4, c1) > 0, 'erased: not the masked result')
    c5 = stroked(base, 'S', ['sculpt S "mask" 0 0 0 0 0 0 9 1', d])
    check(c5 == b0, 'a full mask holds everything')


def s_objects():
    print('-- other meshes, other matrices --')
    bases()
    base = f'{T}/mix.bee'
    for name, st, b in (('C', '2.4 1.9 0.5 1.6 2 0.4 0.6 0.7', 'draw'), ('C', '2 2 0 2.3 2 0 0.8 0.6', 'smooth'), ('B', '-3 2 2 -3 2.1 2 1.5 1', 'draw'), ('B', '-3 1 2 -2.5 1 2 2 0.5', 'grab')):
        b0 = verts(base, name)
        c = stroked(base, name, [f'sculpt {name} "{b}" {st}'])
        moves(f'{name}: {b}: n-gons, big triangles', c, b0)
    b0 = verts(base, 'S')
    x, y, z = next(o for o in beefile.objects(base) if o['name'] == 'S')['loc']
    p = (x + 0.1, y + 0.5, z + 1.4, x + 0.4, y + 0.6, z + 1.2, 0.6, 0.6)
    for b in ('draw', 'grab', 'inflate', 'smooth', 'snake hook'):
        c = stroked(base, 'S', [f'sculpt S "{b}" ' + ' '.join(map(repr, p))])
        moves(f'moved, turned, scaled: {b}', c, b0)


def s_threads():
    print('-- every core: the sums in any order --')
    bases()
    base = f'{T}/ball.bee'
    b0 = verts(base, 'S')
    runs = []
    for b in ('draw', 'smooth', 'inflate'):
        cmds = [f'sculpt S "{b}" {STROKE}', f'sculpt S "{b}" {STROKE}']
        a1 = stroked(base, 'S', cmds)
        c = stroked(base, 'S', cmds, one=False)
        c2 = stroked(base, 'S', cmds, one=False)
        same(f'{b} on every core, against one CPU', a1, c, b0, TOL)
        runs.append((b, worst(c, c2)))
    print('    every core, run to run:', ', '.join(f'{b} {w:.1e}' for b, w in runs))


def s_files():
    print('-- .bee: save, open, save --')
    bases()
    base = f'{T}/ball.bee'
    q, q2 = f'{T}/pf.bee', f'{T}/pf2.bee'
    port('--op', f'file.open {base}', '--op', f'sculpt S "draw" {STROKE}', '--op', f'file.save {q}')
    moves('the sculpted mesh saved', verts(q, 'S'), verts(base, 'S'))
    tags = lambda p: sorted(t for t, _ in beefile.chunks(p))
    port('--op', f'file.open {q}', '--op', f'file.save {q2}')
    check(raw(q2, 'S') == raw(q, 'S'), f'opened and saved again: the mesh the same ({len(raw(q, "S"))} bytes)')
    # the settings and the mask stay in the session
    r1 = f'{T}/pf3.bee'
    port('--op', f'file.open {base}', '--op', 'sculpt.symmetry xyz', '--op', 'sculpt.falloff root', '--op', f'sculpt S "mask" {STROKE}', '--op', f'file.save {r1}')
    check(tags(r1) == tags(q), f'a mask, symmetry, falloff add nothing to a file ({len(tags(r1))} chunks: they are kept in memory)')
    check(raw(r1, 'S') == raw(base, 'S'), 'and the mesh is the file\'s')
    # sculpted, saved, opened and sculpted on
    q3 = f'{T}/pf4.bee'
    port('--op', f'file.open {q}', '--op', f'sculpt S "smooth" {STROKE}', '--op', f'file.save {q3}')
    moves('on top of the saved file', verts(q3, 'S'), verts(q, 'S'))


def d(tag, name='S'):
    return ['--dump-verts', f'{T}/{tag}.txt;{name}']


def rd(tag):
    return dumped(f'{T}/{tag}.txt')


def s_undo():
    print('-- undo: a stroke is one step, to the bit --')
    bases()
    base = f'{T}/ball.bee'
    a = f'sculpt S "draw" {STROKE}'
    b = f'sculpt S "smooth" {STROKE}'
    port('--op', f'file.open {base}', *d('u0'), '--op', a, *d('u1'), '--op', b, *d('u2'), '--op', 'edit.undo', *d('u3'), '--op', 'edit.undo', *d('u4'),
         '--op', 'edit.redo', *d('u5'), '--op', 'edit.redo', *d('u6'), '--op', 'edit.undo', '--op', 'edit.undo', '--op', 'edit.undo', *d('u7'))
    u = [rd(f'u{k}') for k in range(8)]
    check(u[1] != u[0] and u[2] != u[1], f'two strokes moved it ({moved(u[0], u[1])}, {moved(u[1], u[2])})')
    check(u[3] == u[1], "undo: the first stroke's positions")
    check(u[4] == u[0], "undo again: the file's")
    check(u[5] == u[1] and u[6] == u[2], 'redo, twice: each stroke again')
    check(u[7] == u[0], "past the start: still the file's")
    print('-- the history list: a jump over strokes --')
    port('--op', f'file.open {base}', '--op', a, '--op', b, '--op', 'edit.undo_history', '--click-label', 'step:Original', *d('h0'), '--click-label', 'step:Sculpt', *d('h1'), '--key', 'esc', '--op', 'edit.redo', *d('h2'))
    check(rd('h0') == u[0], 'to the start')
    check(rd('h1') == u[1], 'to the first stroke')
    check(rd('h2') == u[2], 'and on with redo')
    print('-- a new change drops what could be redone --')
    port('--op', f'file.open {base}', '--op', a, '--op', 'edit.undo', '--op', b, *d('v1'), '--op', 'edit.redo', *d('v2'), '--op', 'edit.undo', *d('v3'))
    check(rd('v1') == rd('v2'), 'nothing to redo')
    check(rd('v3') == rd('u0'), "and undo leaves the file's")
    print('-- across the modes --')
    port('--op', f'file.open {base}', '--op', a, '--op', 'mode.object', *d('m1'), '--op', 'edit.undo', *d('m2'), '--select', 'S', '--op', 'mode.edit', '--op', 'edit.redo', *d('m3'), '--op', 'mode.object', '--op', 'mode.sculpt', '--op', 'edit.undo', *d('m4'))
    check(rd('m1') == rd('u1'), 'leaving the mode keeps the stroke')
    check(rd('m2') == rd('u0'), 'undone in object mode')
    check(rd('m3') == rd('u1'), 'redone in edit mode')
    check(rd('m4') == rd('u0'), 'undone in sculpt mode again')
    print('-- an edit between strokes: a new mesh, the old one held by the steps --')
    port('--op', f'file.open {base}', '--select', 'S', '--op', a, '--op', 'mode.edit', '--op', 'mesh.subdivide', '--op', 'mode.object', *d('e1'), '--op', f'sculpt S "draw" {STROKE}', *d('e2'),
         '--op', 'edit.undo', *d('e3'), '--op', 'edit.undo', *d('e4'), '--op', 'edit.undo', *d('e5'), '--op', 'edit.redo', '--op', 'edit.redo', '--op', 'edit.redo', *d('e6'))
    check(len(rd('e1')) > len(rd('u1')) and rd('e2') != rd('e1'), f'more vertices ({len(rd("e1"))}), sculpted')
    check(rd('e3') == rd('e1'), 'undo: the stroke on the new mesh')
    check(rd('e4') == rd('u1'), 'undo: the edit')
    check(rd('e5') == rd('u0'), 'undo: the stroke on the old one')
    check(rd('e6') == rd('e2'), 'and all of it again')
    print('-- more steps than the history keeps --')
    n = 140
    args = ['--op', f'file.open {base}']
    for k in range(n):
        args += ['--op', f'sculpt S "draw" {-0.5 + k * 0.01} 2 1 {-0.4 + k * 0.01} 2.1 0.9 0.3 0.1']
    args += d('n1')
    for k in range(n + 5):
        args += ['--op', 'edit.undo']
    args += d('n2')
    port(*args)
    # (128 steps kept: what is older than that stays)
    check(rd('n1') != rd('u0') and moved(rd('n2'), rd('n1')) > 500 and rd('n2') != rd('u0'), f'the ring keeps 127 strokes back ({moved(rd("n2"), rd("n1"))} moved back, the oldest strokes stay)')


def s_shared():
    print('-- a mesh others show --')
    # the primitives: a stroke on one cube is not on the next
    port('--op', 'add cube', '--op', 'add cube', '--op', 'sculpt Cube.001 "draw" 0 1 1 0.2 1 1 1.5 1', *d('p1', 'Cube.001'), *d('p2', 'Cube'), *d('p3', 'Cube.002'), '--op', 'mode.object', '--op', 'add cube', *d('p4', 'Cube.003'))
    check(rd('p1') != rd('p2'), 'the sculpted cube moved')
    check(rd('p2') == rd('p3') and rd('p3') == rd('p4'), 'the other cubes, and a new one, did not')
    port('--op', 'sculpt Cube "draw" 0 1 1 0.2 1 1 1.5 1', *d('q1', 'Cube'), '--op', 'edit.undo', *d('q2', 'Cube'), '--op', 'sculpt Cube "draw" 0 1 1 0.2 1 1 1.5 1', '--op', 'mode.object', '--op', 'add cube', *d('q3', 'Cube.001'), *d('q4', 'Cube'))
    check(rd('q1') != rd('q2') and rd('q3') == rd('q2'), 'undone and sculpted again: a new cube is still a cube')
    check(rd('q4') == rd('q1'), 'and the stroke is there')
    # undo back past the step the mode was entered in, and on: nothing leaks into the primitive
    port('--op', 'add sphere', '--op', 'move 1 1 1', '--select', 'Cube', '--op', 'sculpt Cube "draw" 0 1 1 0.2 1 1 1.5 1', '--op', 'edit.undo', '--op', 'edit.undo', '--op', 'sculpt Cube "draw" 0 1 1 0.2 1 1 1.5 1', '--op', 'edit.undo', '--op', 'mode.object', '--op', 'add cube', *d('r1', 'Cube.001'), *d('r2', 'Cube'))
    check(rd('r1') == rd('r2') and rd('r1') == rd('q2'), 'undone past where it was entered: the cube as it was')
    # linked duplicates (object.duplicate): the other keeps its shape, in both
    bases()
    base = f'{T}/ball.bee'
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'object.duplicate', '--op', f'file.save {T}/dup.bee')
    objs = beefile.objects(f'{T}/dup.bee')
    names = [x['name'] for x in objs]
    dup = [x for x in names if x not in ('S', 'Camera', 'Light')][0]
    print('    the duplicate is', dup, 'on mesh', next(x for x in objs if x['name'] == dup)['mesh'], 'of', len(beefile.meshes(f'{T}/dup.bee')))
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'object.duplicate', '--op', f'sculpt S "draw" {STROKE}', *d('l1'), *d('l2', dup), '--op', 'edit.undo', *d('l3'), *d('l4', dup), '--op', 'edit.undo', *d('l5', dup))
    check(rd('l1') != rd('l2'), 'the stroke is on S')
    check(rd('l2') == rd('l4') and rd('l3') == rd('l2'), 'not on its duplicate; undone, they are one shape again')
    print('-- the copy the mode makes is no step --')
    port('--op', 'sculpt Cube "draw" 0 1 1 0.2 1 1 1.5 1', '--op', 'edit.undo_history')
    steps = [x[1] for x in ui_rows() if x[0] == 'step']
    check(steps == ['Original', 'Sculpt'], f'one stroke on a primitive: one step ({steps})')
    print('-- a duplicate made in the mode --')
    port('--op', f'file.open {base}', '--select', 'S', '--op', f'sculpt S "draw" {STROKE}', *d('x0'), '--op', 'object.duplicate', '--op', f'sculpt S "smooth" {STROKE}', *d('x1'), *d('x2', dup), '--op', 'edit.undo', *d('x3'), *d('x4', dup))
    check(rd('x1') != rd('x0') and rd('x2') == rd('x0'), 'the next stroke leaves it alone')
    check(rd('x3') == rd('x0') and rd('x4') == rd('x0'), 'undone: as they were')


def s_evaluated():
    print('-- the base under what shows: modifiers, shape keys, skins --')
    B = 'delete("Cube")\nadd("sphere", "S", 0, 2, 0)\n'
    p = f'{T}/ev.bee'
    make(B + f'op("file.save", "{p}")\n')
    st = '-0.3 2.7 0.8 0.2 2.8 0.6 0.5 0.6'
    b0 = verts(p, 'S')
    for mod in ('mirror', 'subsurf', 'solidify'):
        q = f'{T}/ep_{mod}.bee'
        port('--op', f'file.open {p}', '--select', 'S', '--op', f'object.modifier_add {mod}', *d('m0'), '--op', f'sculpt S "draw" {st}', *d('m3'), '--op', 'mode.object', '--op', f'file.save {q}', *d('m1'), '--op', 'edit.undo', *d('m2'))
        check(rd('m3') == rd('m1') and rd('m3') != rd('m0'), f'{mod}: what shows follows at the stroke\'s end, in the mode')
        moves(f'{mod}: the base', verts(q, 'S'), b0)
        moves(f'{mod}: what shows', rd('m1'), None if mod == 'mirror' else rd('m0'))  # (a mirror welds what meets at the seam)
        check(rd('m2') == rd('m0'), f'{mod}: undo brings back what showed')
        q2 = f'{T}/ep2_{mod}.bee'
        port('--op', f'file.open {q}', '--op', f'file.save {q2}', *d('m4'))
        check(raw(q2, 'S') == raw(q, 'S') and rd('m4') == rd('m1'), f'{mod}: opened again: the same base, the same shown')
    print('-- shape keys: the stroke goes under them, their offsets stay --')
    K = f'op("file.open", "{p}")\nselect("S")\ni = 0\nwhile i < 200 {{ vmove("S", i, vpos("S", i, 0), vpos("S", i, 1) + 0.5, vpos("S", i, 2))\n i = i + 1 }}\nop("shape.add", "Up S")\nop("shape.set", "Up 0.5 S")\n'
    o = f'{T}/sko.bee'
    make(K + f'op("file.save", "{o}")\n')
    q = f'{T}/skp.bee'
    port('--op', f'file.open {o}', *d('k0'), '--op', f'sculpt S "draw" {st}', *d('k1'), '--op', 'mode.object', *d('k2'), '--op', f'file.save {q}', '--op', 'shape.set Up 0 S', '--op', 'shape.set Up 0.5 S', *d('k3'), '--op', 'edit.undo', '--op', 'edit.undo', '--op', 'edit.undo', *d('k4'))
    moves('shape keys: the base', verts(q, 'S'), verts(o, 'S'))
    moves('shape keys: what shows', rd('k2'), rd('k0'))
    keys = [t for t, _ in beefile.chunks(q)]
    check(b'MSHK' in keys and beefile.chunk(o, b'MSHK')[4:] == beefile.chunk(q, b'MSHK')[4:], f'the keys themselves are as they were ({[t for t in keys if t[:1] == b"M"]})')
    check(rd('k3') == rd('k2'), 'a value set and back: the same shape')
    check(rd('k4') == rd('k0'), 'undone: the same vertices')
    print('-- skinned --')
    R = f'''op("file.open", "{p}")
a = armature("Rig")
op("arm.bone", "Upper Bone 0 1 0 0.2 3.2 0.1")
op("arm.parent", "S Rig")
select("Rig")
op("arm.pose", "Upper rot 20 10 30")
select("S")
'''
    o = f'{T}/skin.bee'
    make(R + f'op("file.save", "{o}")\n')
    q = f'{T}/skinp.bee'
    port('--op', f'file.open {o}', *d('s0'), '--op', f'sculpt S "draw" {st}', '--op', 'mode.object', '--op', f'file.save {q}', *d('s1'), '--op', 'edit.undo', *d('s2'))
    check(b'ARMT' in [t for t, _ in beefile.chunks(o)] and len([x for x in beefile.objects(o) if x['name'] == 'Rig']) == 1, 'the rig is in the file')
    moves('skinned: the base', verts(q, 'S'), b0)
    moves('skinned: what shows', rd('s1'), rd('s0'))
    check(rd('s2') == rd('s0'), 'undone: the skin as it was')


def s_midstroke():
    print('-- things that happen during a stroke --')
    M = ['--op', 'mode.sculpt']
    P = ['--move', '620,330', '--press', '620,330', '--move', '630,335', '--move', '640,340']
    port(*M, *d('a0', 'Cube'), *P, '--key', 'ctrl+z', *d('a1', 'Cube'), '--release', '640,340', *d('a2', 'Cube'))
    check(rd('a1') == rd('a0'), 'Ctrl+Z in a stroke: the stroke so far is a step, and it goes')
    port(*M, *d('b0', 'Cube'), *P, '--op', 'mode.object', *d('b1', 'Cube'), '--release', '640,340', *d('b2', 'Cube'), '--op', 'edit.undo', *d('b3', 'Cube'))
    check(rd('b1') != rd('b0'), 'left in a stroke: what it did stays')
    check(rd('b2') == rd('b1'), 'the release does nothing more')
    check(rd('b3') == rd('b0'), 'and it is one step')
    port(*M, *d('c0', 'Cube'), *P, '--key', 'esc', '--move', '650,345', '--release', '650,345', *d('c1', 'Cube'), '--op', 'edit.undo', *d('c2', 'Cube'))
    check(rd('c1') != rd('c0') and rd('c2') == rd('c0'), 'Esc changes nothing: one step')
    r = port(*M, *P, '--op', 'file.new', '--release', '640,340', ok=False)
    check(r.returncode == 0, f'a new scene in a stroke {r.stderr[-200:]}')
    r = port(*M, *P, '--op', 'delete Cube', '--move', '650,345', '--release', '650,345', ok=False)
    check(r.returncode == 0, f'the object deleted in a stroke {r.stderr[-200:]}')
    r = port(*M, *P, '--move', '5000,5000', '--move', '-300,-40', '--move', '640,340', '--release', '640,340', ok=False)
    check(r.returncode == 0, f'a stroke that leaves the window comes back {r.stderr[-200:]}')
    r = port(*M, *P, '--op', 'object.sculpt_mode', '--op', 'object.sculpt_mode', '--move', '650,345', '--release', '650,345', ok=False)
    check(r.returncode == 0, f'out of the mode and back in a stroke {r.stderr[-200:]}')
    r = port(*M, *P, '--key', 'g', '--key', 's', '--wheel', '640,340,3', '--release', '640,340', ok=False)
    check(r.returncode == 0, f'keys and the wheel in a stroke {r.stderr[-200:]}')


WBALL = BALL % 3 + 'scale("S", 3.5, 3.5, 3.5)\nselect("S")\nop("file.save", "{wb}")\n'


def wball():
    wb = f'{T}/wball.bee'
    if not os.path.exists(wb):
        make(WBALL.replace('{wb}', wb))
    return wb


def wrap(binary):
    """The binary on one CPU (for the fake compositor)."""
    p = f'{T}/{hashlib.sha1(binary.encode()).hexdigest()[:8]}.sh'
    open(p, 'w').write(f'#!/bin/sh\nexec taskset -c {CPU} {binary} "$@"\n')
    os.chmod(p, 0o755)
    return p


def drag(x0, y0, x1, y1, steps=16):
    """A pointer stroke: pressed, moved in steps, released."""
    a = ['--move', f'{x0},{y0}', '--press', f'{x0},{y0}']
    for i in range(1, steps + 1):
        a += ['--move', f'{x0 + (x1 - x0) * i // steps},{y0 + (y1 - y0) * i // steps}']
    return a + ['--release', f'{x1},{y1}']


# the viewport filling the window, looking along -Z, in sculpt mode
FRONT = ['--select', 'S', '--move', '640,300', '--key', 'ctrl+space', '--key', 'kp1', '--keydown', 'ctrl+tab', '--keyup', 'ctrl+tab']


def mouse(base, steps, out, shot=None):
    """Mouse and keys on the headless window; the mesh it leaves."""
    if os.path.exists(out):
        os.remove(out)
    port('--op', f'file.open {base}', *FRONT, *steps, '--op', 'mode.object', '--op', f'file.save {out}')
    return verts(out, 'S') if os.path.exists(out) else []


def s_window():
    print('-- the pointer: brushes by their keys, modifiers, the stabilizer, odd strokes --')
    wb = wball()
    b0 = verts(wb, 'S')
    P = (560, 250, 720, 290)

    def stroke(*keys, mods='', steps=16, p=P):
        a = []
        for k in keys:
            a += ['--key', k]
        if mods:
            a += ['--mods', mods]
        a += drag(*p, steps=steps)
        if mods:
            a += ['--mods', 'none']
        return a

    cases = [
        ('draw', stroke()),
        ('clay', stroke('c')),
        ('crease', stroke('shift+c')),
        ('inflate', stroke('i')),
        ('grab', stroke('g')),
        ('snake', stroke('k')),
        ('smooth', stroke('s')),
        ('flatten', stroke('shift+t')),
        ('pinch', stroke('p')),
        ('layer', stroke('l')),
        ('Ctrl inverts', stroke(mods='ctrl')),
        ('Shift smooths', stroke(mods='shift')),
        ('pinch, Ctrl', stroke('p', mods='ctrl')),
        ('bigger brush', stroke('27', '27', '27')),
        ('smaller, weaker', stroke('26', '26', 'shift+26', 'shift+26')),
        ('symmetry X', stroke('shift+x')),
        ('stabilizer 10', stroke('shift+s')),
        ('stabilizer 50', stroke('shift+s', 'shift+s', 'shift+s')),
        ('stabilizer, grab', stroke('g', 'shift+s')),
        ('stabilizer, snake', stroke('k', 'shift+s')),
        ('off the mesh on the way', stroke(p=(600, 250, 1000, 250))),
        ('a jump: 64 dabs at most', stroke(*['26'] * 8, steps=1, p=(560, 250, 720, 290))),
        ('a click', stroke(steps=1, p=(640, 250, 640, 250))),
    ]
    res = {}
    for name, do in cases:
        if ONLY not in name:
            continue
        res[name] = mouse(wb, do, f'{T}/pw.bee')
        moves(name, res[name], b0)
    if ONLY:
        return
    br = ['draw', 'clay', 'crease', 'inflate', 'grab', 'snake', 'smooth', 'flatten', 'pinch', 'layer']
    same_ = [(x, y) for x in br for y in br if x < y and res[x] == res[y] and (x, y) != ('draw', 'layer')]
    check(not same_, f'the brushes\' keys: different results (but draw and layer: {same_})')
    for name in ('Ctrl inverts', 'Shift smooths', 'bigger brush', 'smaller, weaker', 'symmetry X', 'stabilizer 10'):
        check(res[name] != res['draw'], f'{name}: not a plain draw')
    check(res['stabilizer 50'] != res['stabilizer 10'], 'stabilizer 50: not 10')
    check(moved(res['symmetry X'], b0) > moved(res['draw'], b0) * 1.5, 'symmetry X: the other side too')
    again = mouse(wb, cases[0][1], f'{T}/pw2.bee')
    check(again == res['draw'], 'the same stroke again: the same bits')


def logged():
    return open(f'{T}/log.txt').read().splitlines()


def info():
    ln = [x for x in logged() if x.startswith('  sculpt.info')]
    w = ln[-1].split() if ln else []
    return {w[i]: w[i + 1] for i in range(1, len(w) - 1, 2)}


def ui_rows():
    return [ln.rstrip('\n').split('\t') for ln in open(f'{T}/u.txt')]


def s_ui():
    print('-- the tools, the bar, the keys --')
    port('--op', 'mode.sculpt')
    r = ui_rows()
    labels = [x[1] for x in r]
    want = ['Draw', 'Clay Strips', 'Crease', 'Inflate', 'Grab', 'Snake Hook', 'Smooth', 'Flatten', 'Pinch', 'Layer', 'Mask', 'Clear Mask', 'Invert Mask', 'Dynamic Topology']
    i = labels.index('Draw')
    check(labels[i:i + len(want)] == want, f'the tools area: the brushes in order ({labels[i:i + 3]}...)')
    off = {x[1]: x[3] for x in r}
    check(off.get('Dynamic Topology') == 'on' and off.get('Draw') == 'on', 'the tools are on, dynamic topology too')
    check('Sculpt Mode' in labels, 'the header says Sculpt Mode')
    for w in ('Radius', 'Strength', 'Smooth', 'X Symmetry', 'Y Symmetry', 'Z Symmetry', 'Stabilizer', 'Pressure: Strength', 'Pressure: Radius'):
        check(w in labels, f'the bar has {w}')
    port('--move', '640,300')
    check('Radius' not in [x[1] for x in ui_rows()], 'object mode: no bar')
    r = port('--op', 'mode.sculpt', '--move', '640,300', '--expect-field', 'Radius=50', '--key', '27', '--expect-field', 'Radius=57.5', '--key', '26', '--key', 'shift+27', '--expect-field', 'Strength=0.6', '--key', 'shift+26', '--key', 'shift+26', '--expect-field', 'Strength=0.4', ok=False)
    check(r.returncode == 0, f'[ ] and Shift+[ ] move the fields {r.stderr[-200:]}')
    many = []
    for _ in range(40):
        many += ['--key', '27', '--key', 'shift+27']
    port('--op', 'mode.sculpt', '--move', '640,300', *many, '--op', 'sculpt.info')
    check(info()['radius'] == '600' and info()['strength'] == '1', f'the keys stop at 600 and 1 ({info()})')
    many = []
    for _ in range(40):
        many += ['--key', '26', '--key', 'shift+26']
    port('--op', 'mode.sculpt', '--move', '640,300', *many, '--op', 'sculpt.info')
    check(info()['radius'] == '4' and abs(float(info()['strength']) - 0.1) < 1e-6, f'and at 4 and 0.1 ({info()})')
    for k, b in (('x', 0), ('c', 1), ('shift+c', 2), ('i', 3), ('g', 4), ('k', 5), ('s', 6), ('shift+t', 7), ('p', 8), ('l', 9), ('m', 10)):
        port('--op', 'mode.sculpt', '--move', '640,300', '--key', 'k' if k != 'k' else 'x', '--key', k, '--op', 'sculpt.info')
        check(info()['brush'] == str(b), f'{k}: brush {b}')
    port('--move', '640,300', '--key', 'k', '--key', 'shift+x', '--op', 'mode.sculpt', '--op', 'sculpt.info')
    check(info()['brush'] == '0' and info()['sym'] == '0', 'their keys are not sculpt mode\'s outside it')
    port('--op', 'mode.sculpt', '--move', '640,300', '--key', 'shift+x', '--op', 'sculpt.symmetry_y', '--op', 'sculpt.info')
    check(info()['sym'] == '3', 'X then Y')
    port('--op', 'sculpt.symmetry zx', '--op', 'mode.sculpt', '--op', 'sculpt.info')
    check(info()['sym'] == '5', 'sculpt.symmetry zx')
    r = port('--op', 'mode.sculpt', '--move', '640,300', '--key', 'shift+s', '--dump-log', f'{T}/log2.txt', ok=False)
    check('sculpt stabilizer: 10 px' in open(f'{T}/log2.txt').read(), 'Shift+S: the stabilizer, not the snap pie')
    print('-- the modes --')
    port('--op', 'object.sculpt_mode', '--op', 'sculpt.info', '--op', 'object.sculpt_mode', '--op', 'sculpt.info')
    check(any('sculpt mode: 12 triangles in 1 leaves' in x for x in logged()), 'entering says what it found')
    check(any('sculpt mode off' in x for x in logged()) and logged()[-1].endswith('off'), 'and leaving')
    port('--select', 'Camera', '--op', 'object.sculpt_mode', '--op', 'sculpt.info')
    check(any('select a mesh' in x for x in logged()) and logged()[-1].endswith('off'), 'a camera cannot be sculpted')
    port('--op', 'mode.edit', '--op', 'mode.sculpt', '--op', 'sculpt.info', '--op', 'mode.edit', '--op', 'sculpt.info')
    check(logged()[-1].endswith('off') and any(' verts 8 ' in x for x in logged()), 'edit -> sculpt -> edit: one mode at a time')
    r = port('--keydown', 'ctrl+tab', '--keyup', 'ctrl+tab', '--op', 'sculpt.info')
    check(any(' verts 8 ' in x for x in logged()), 'Ctrl+Tab tapped: sculpt mode')
    r = port('--move', '640,300', '--keydown', 'ctrl+tab', '--wait', '400', '--move', '640,210', '--keyup', 'ctrl+tab', '--op', 'sculpt.info')
    check(any(' verts 8 ' in x for x in logged()), 'the pie: up is sculpt mode')
    print('-- drawing --')
    bases()
    base = f'{T}/ball.bee'
    fr = ['--op', f'file.open {base}', '--select', 'S', '--move', '640,300', '--op', 'mode.sculpt']
    port(*fr, '--press', '612,270', '--move', '616,272', '--move', '620,274', '--op', 'sculpt.info')
    i = info()
    t = i['tiles'].split('/')
    check(0 < int(t[0]) < int(t[1]) / 3, f'a stroke draws few of the tiles ({i["tiles"]})')
    a = open(f'{T}/u.ppm', 'rb').read()
    port(*fr, '--press', '612,270', '--move', '616,272', '--move', '620,274', '--release', '620,274', '--move', '621,274', '--move', '620,274')
    b = open(f'{T}/u.ppm', 'rb').read()
    hd = len(a) - 1280 * 800 * 3
    n = sum(1 for y in range(90, 540) for x in range(215, 1010) if max(abs(a[hd + (y * 1280 + x) * 3 + c] - b[hd + (y * 1280 + x) * 3 + c]) for c in range(3)) > 40)
    check(n < 200, f'a stroke frame from the tile cache looks as a full redraw ({n} pixels differ)')
    # what moves away leaves nothing behind: the tiles it was on are drawn too
    # (a grab pulled out and back)
    G = ['--key', 'g', '--press', '612,270', '--move', '700,200', '--move', '800,150', '--move', '612,270']
    port(*fr, *G)
    a = open(f'{T}/u.ppm', 'rb').read()
    port(*fr, *G, '--release', '612,270', '--move', '613,270', '--move', '612,270')
    b = open(f'{T}/u.ppm', 'rb').read()
    n = sum(1 for y in range(90, 540) for x in range(215, 1010) if max(abs(a[hd + (y * 1280 + x) * 3 + c] - b[hd + (y * 1280 + x) * 3 + c]) for c in range(3)) > 40)
    check(n < 400, f'a grab pulled across the view: no ghost ({n} pixels differ)')
    dense = f'{T}/dense.bee'
    make(BALL % 5 + f'op("file.save", "{dense}")\n')
    small = ['--key', '26'] * 14  # (a brush of a few pixels)
    port('--op', f'file.open {dense}', '--select', 'S', '--move', '640,300', '--op', 'mode.sculpt', *small, '--press', '612,270', '--move', '616,272', '--move', '620,274', '--op', 'sculpt.info')
    i = info()
    check(0 < int(i['projected']) < int(i['leaves']) / 4, f'and projects few of the {i["leaves"]} leaves ({i["projected"]})')


def s_look():
    print('-- the picture: the sculpted ball in clay --')
    wb = wball()
    port('--op', f'file.open {wb}', *FRONT, *drag(560, 250, 720, 290), '--move', '100,700')
    d_ = open(f'{T}/u.ppm', 'rb').read()
    hd = len(d_) - 1280 * 800 * 3
    px = lambda x, y: tuple(d_[hd + (y * 1280 + x) * 3:hd + (y * 1280 + x) * 3 + 3])
    # (the ball: the 3D cursor over it is the rest of the viewport's)
    inner = [(x, y) for y in range(203, 483) for x in range(500, 780) if (x - 640) ** 2 + (y - 343) ** 2 < 140 ** 2 and (x - 640) ** 2 + (y - 430) ** 2 > 20 ** 2]
    n = sum(1 for x, y in inner if abs(px(x, y)[0] - px(x, y)[1] * 0.8 / 0.76) < 3)
    check(n > 0.99 * len(inner), f'the ball is drawn in clay ({n} of {len(inner)} pixels)')
    cols = len({px(x, y) for x, y in inner})
    check(cols > 20, f'and shaded, the stroke in it ({cols} colours)')


def s_idle():
    print('-- a real window (the fake compositor): a stroke, idle, resized --')
    import wl_fake
    bases()
    f = wl_fake.Fake(wrap(BIN), args=(f'{T}/ball.bee',), size=(1280, 800))
    try:
        f.until(lambda: f.frames > 0 and f.pointer is not None and f.keyboard is not None, 20)
        check(f.frames > 0, f'the window shows ({f.frames} frames)')
        f.enter(640, 330)
        f.pump(0.3)
        f.key(15, mods=4)                    # Ctrl+Tab: sculpt mode
        f.pump(0.5)
        a = f.surfaces[f.main().surface].get('pixels')
        f.motion(620, 330)
        f.pump(0.1)
        f.button(0x110, True)
        for i in range(1, 5):
            f.motion(620 + i * 10, 330 + i * 5)
            f.pump(0.1)
        f.button(0x110, False)
        f.pump(3.0)
        b = f.surfaces[f.main().surface].get('pixels')
        check(a is not None and b is not None and a != b, 'a stroke changes the picture')
        n = f.frames
        f.pump(1.5)
        check(f.frames == n, f'nothing moves, nothing is drawn ({f.frames - n} frames)')
        f.motion(650, 340)
        f.pump(0.3)
        check(f.frames > n, 'the pointer moves: the brush follows')
        f.configure(f.main(), (900, 500))
        f.pump(0.5)
        f.motion(400, 200)
        f.button(0x110, True)
        for i in range(1, 5):
            f.motion(400 + i * 15, 200 + i * 10)
            f.pump(0.1)
        f.button(0x110, False)
        f.pump(0.3)
        check(f.proc.poll() is None and f.commits and f.commits[-1][1:3] == (900, 500), f'resized in the mode, still sculpting ({f.commits[-1][1:3] if f.commits else None})')
    finally:
        err = f.close()
    check('panic' not in err, f'no panic in the window ({err.strip()[-200:]})')


def chunks_of(path):
    return open(path, 'rb').read()[:8], beefile.chunks(path)


def pack(head, cs):
    return head + b''.join(t + struct.pack('<I', len(b)) + b for t, b in cs)


def patched(src, out, name, vs, polys):
    """A copy of a file with an object's mesh replaced."""
    head, cs = chunks_of(src)
    k = next(o for o in beefile.objects(src) if o['name'] == name)['mesh']
    nl = sum(len(p) for p in polys)
    off = [0]
    for p in polys:
        off.append(off[-1] + len(p))
    body = struct.pack('<III', len(vs), len(polys), nl) + struct.pack(f'<{len(vs) * 3}f', *[c for v in vs for c in v]) + struct.pack(f'<{len(off)}I', *off) + struct.pack(f'<{nl}I', *[i for p in polys for i in p])
    out_c, i = [], 0
    for t, b in cs:
        if t == b'MESH':
            if i == k:
                b = body
            i += 1
        elif t in (b'MUVS', b'ZIDX', b'MVCL'):
            continue
        out_c.append((t, b))
    open(out, 'wb').write(pack(head, out_c))


def s_robust():
    print('-- the small and the strange --')
    base = f'{T}/plain.bee'
    make(f'select("Cube")\nop("file.save", "{base}")\n')
    tri = f'{T}/tri.bee'
    patched(base, tri, 'Cube', [(-1, 0, 0), (1, 0, 0), (0, 2, 0)], [[0, 1, 2]])
    c = stroked(tri, 'Cube', ['sculpt Cube "draw" 0 1.5 0 0.2 1.6 0 2 0.5'])
    moves('a single triangle', c, verts(tri, 'Cube'))
    for b in ('smooth', 'pinch', 'grab', 'flatten', 'clay strips', 'crease', 'snake hook'):
        c = stroked(tri, 'Cube', [f'sculpt Cube "{b}" 0 1.5 0 0.2 1.6 0 2 0.5'])
        moves(f'{b} on it', c, None)
    bases()
    ball = f'{T}/ball.bee'
    b0 = verts(ball, 'S')
    c = stroked(ball, 'S', ['sculpt S "draw" 0 2 1 0 2 1 1000 0.5'])
    moves('a huge radius', c, b0)
    check(moved(c, b0) == len(b0), f'a huge radius reaches every vertex ({moved(c, b0)} of {len(b0)})')
    c = stroked(ball, 'S', ['sculpt S "smooth" 0 2 1 0.1 2 1 50 1'])
    moves('a huge smooth', c, b0)
    t0 = time.time()
    c = stroked(ball, 'S', ['sculpt S "draw" 0 2 1 1 2 1 0.0001 0.5'])
    moves('a tiny radius: 4096 dabs at most', c, None)
    check(time.time() - t0 < 120, f'and it ends ({time.time() - t0:.1f} s)')
    for what, stroke_ in (('no strength', '0 2 1 0.2 2 1 0.5 0'), ('no radius', '0 2 1 0.2 2 1 0 0.5'), ('off the mesh', '50 50 50 51 50 50 0.5 0.5'), ('no way', '0 2 1 0 2 1 0.5 0.5')):
        c = stroked(ball, 'S', [f'sculpt S "draw" {stroke_}'])
        moves(what, c, None)
        if what != 'no way':
            check(c == b0, f'{what}: nothing moves')
    for bad in ('nan 2 1 0 2 1 0.5 0.5', '0 2 1 0 2 1 inf 0.5', '0 2 1 0 2 1 0.5 1/0', '0 2 1'):
        r = port('--op', f'file.open {ball}', '--op', f'sculpt S "draw" {bad}', '--op', f'file.save {T}/nan.bee', ok=False)
        check(r.returncode == 0 and verts(f'{T}/nan.bee', 'S') == b0, f'refused: {bad}')
    r = port('--op', 'sculpt Nobody draw 0 0 0 1 1 1 1 1', '--op', 'sculpt Cube nosuch 0 0 0 1 1 1 1 1', '--op', 'sculpt Camera draw 0 0 0 1 1 1 1 1', ok=False)
    check(r.returncode == 0 and any('no object' in x for x in logged()) and any('no brush' in x for x in logged()) and any('select a mesh' in x for x in logged()), 'a stroke on nothing says so')
    print('-- damaged geometry --')
    cases = {
        'NaN corners': [(float('nan'), 0, 0), (1, 0, 0), (0, 2, 0), (0, 0, 1)],
        'infinite corners': [(float('inf'), 0, 0), (1, float('-inf'), 0), (0, 2, 0), (0, 0, 1)],
        'huge corners': [(1e30, 0, 0), (-1e30, 1e30, 0), (0, 2e38, 0), (0, 0, 1)],
        'all in one point': [(0, 1, 0), (0, 1, 0), (0, 1, 0), (0, 1, 0)],
        'a loose vertex': [(-1, 0, 0), (1, 0, 0), (0, 2, 0), (40, 40, 40)],
    }
    for name, vs in cases.items():
        p = f'{T}/bad.bee'
        patched(base, p, 'Cube', vs, [[0, 1, 2], [0, 2, 3]] if 'loose' not in name else [[0, 1, 2]])
        r = port('--op', f'file.open {p}', '--op', 'sculpt Cube "draw" 0 1 0 0.2 1 0 2 0.5', '--op', 'sculpt Cube "smooth" 0 1 0 0.2 1 0 2 0.5', '--op', 'sculpt Cube "grab" 0 1 0 0.2 1 0 2 0.5',
                 '--drag', '600,300,700,380', '--op', 'edit.undo', '--op', 'mode.object', ok=False)
        check(r.returncode == 0, f'{name}: {r.stderr[-300:] if r.returncode else "no crash"}')
    # many faces in one point: leaves by count; a lopsided mesh: more leaves than the first guess
    n = 6000
    vs = [(i * 1e-6, 0.0, 0.0) for i in range(n - 2)] + [(1000.0, 0.0, 1.0), (1000.0, 1.0, 1.0)]
    polys = [[i, i + 1, n - 1 if i % 2 else n - 2] for i in range(n - 3)]
    p = f'{T}/lop.bee'
    patched(base, p, 'Cube', vs, polys)
    c = stroked(p, 'Cube', ['sculpt Cube "draw" 500 0 0.5 501 0 0.5 5 0.5'])
    moves('a lopsided mesh', c, vs)
    # every split cuts off one triangle: far more leaves than the first guess has room for
    vs, polys = [], []
    for i in range(2000):
        x = 2.0 ** (100 - i) if i < 200 else 0.0
        vs += [(x, 0.0, 0.0), (x, 1.0, 0.0), (x, 0.0, 1.0)]
        polys.append([i * 3, i * 3 + 1, i * 3 + 2])
    patched(base, p, 'Cube', vs, polys)
    r = port('--op', f'file.open {p}', '--op', 'sculpt Cube "draw" 0 0 0 0 0.1 0 1 0.5', '--op', 'sculpt.info', ok=False)
    lv = int(info().get('leaves', 0))
    check(r.returncode == 0 and lv > 2000 // 512 + 4, f'leaves past the first guess ({lv})')
    # the geometry of a stroke where a file is damaged: the chunks' fuzz
    data = open(ball, 'rb').read()
    rng = random.Random(SEED)
    for k in range(RUNS):
        b = bytearray(data)
        for _ in range(rng.randrange(1, 40)):
            b[rng.randrange(8, len(b))] = rng.randrange(256)
        open(f'{T}/fz.bee', 'wb').write(bytes(b))
        r = port('--op', f'file.open {T}/fz.bee', '--op', 'sculpt S "draw" 0 2 1 0.2 2 1 0.5 0.5', '--op', 'sculpt.mask_invert', '--drag', '600,300,700,380', '--op', 'edit.undo', ok=False)
        if r.returncode != 0:
            shutil.copy(f'{T}/fz.bee', '/tmp/beesc-crash.bee')
            check(False, f'a damaged file: {r.stderr[-400:]}')
            break
    else:
        check(True, f'{RUNS} damaged files sculpted')


def s_jobs():
    print('-- with something else going on --')
    bases()
    ball = f'{T}/ball.bee'
    fr = ['--op', f'file.open {ball}', '--select', 'S', '--op', 'mode.sculpt']
    r = port(*fr, '--key', 'f12', '--drag', '600,300,700,380', '--op', f'sculpt S "draw" {STROKE}', '--render-wait', '--op', 'edit.undo', '--op', 'mode.object', ok=False)
    check(r.returncode == 0, f'a render running {r.stderr[-200:]}')
    r = port(*fr, '--op', 'view.shading_rendered', '--drag', '600,300,700,380', '--op', f'sculpt S "draw" {STROKE}', '--live-wait', '--op', 'edit.undo', ok=False)
    check(r.returncode == 0, f'the Rendered viewport {r.stderr[-200:]}')
    r = port(*fr, '--op', 'view.shading_material', '--drag', '600,300,700,380', '--op', 'view.shading_wireframe', '--drag', '600,300,700,380', ok=False)
    check(r.returncode == 0, f'material preview, wireframe {r.stderr[-200:]}')
    r = port('--op', f'file.open {ball}', '--op', 'anim.key S:x 1 0', '--op', 'anim.key S:x 30 3', '--select', 'S', '--op', 'mode.sculpt', '--op', 'anim.frame 15', '--drag', '600,300,700,380', '--op', f'sculpt S "draw" {STROKE}', '--op', 'anim.frame 20', '--op', 'edit.undo', ok=False)
    check(r.returncode == 0, f'keyed, a frame changing {r.stderr[-200:]}')
    r = port('--op', f'file.open {ball}', '--select', 'S', '--op', 'vgeo.build', '--op', 'mode.sculpt', '--op', f'sculpt S "draw" {STROKE}', '--op', 'mode.object', '--op', 'vgeo.clear', ok=False)
    check(r.returncode == 0, f'a cluster DAG {r.stderr[-200:]}')
    r = port('--op', f'file.open {ball}', '--select', 'S', '--op', 'workspace.set Sculpt', '--op', 'mode.sculpt', '--drag', '600,300,700,380', '--op', 'workspace.set Modeling', '--op', f'sculpt S "draw" {STROKE}', ok=False)
    check(r.returncode == 0, f'another workspace {r.stderr[-200:]}')
    r = port('--op', f'file.open {ball}', '--op', 'mode.sculpt', '--op', f'file.open {ball}', '--op', f'sculpt S "draw" {STROKE}', '--op', f'file.save {T}/j.bee', '--op', 'file.new', '--op', 'sculpt.info', ok=False)
    check(r.returncode == 0 and logged()[-1].endswith('off'), f'another file: the mode ends {r.stderr[-200:]}')


def s_views():
    print('-- other windows on it --')
    bases()
    ball = f'{T}/ball.bee'
    fr = ['--op', f'file.open {ball}', '--select', 'S', '--op', 'mode.sculpt']
    S = ['--press', '612,270', '--move', '620,274', '--release', '620,274']
    port(*fr, *S, *d('v0'), '--op', 'edit.undo', *d('v1'))
    check(rd('v0') != rd('v1'), 'a stroke in the window')
    port(*fr, '--move', '400,300', '--op', 'area.split_side', '--move', '400,300', '--op', f'sculpt S "draw" {STROKE}', '--move', '380,300', *d('v2'), '--op', 'edit.undo', *d('v3'))
    check(rd('v3') == rd('v1') and rd('v2') != rd('v3'), 'two viewports show it')
    port('--comp-scale', '180', *fr, *S, *d('v4'), '--op', 'edit.undo', *d('v5'))
    check(rd('v5') == rd('v1') and moved(rd('v4'), rd('v5')) > 50, f'a window at 150%: {moved(rd("v4"), rd("v5"))} moved')


def s_gpu():
    print('-- the viewport on the GPU: the sculpted mesh over it --')
    bases()
    ball = f'{T}/ball.bee'
    a = ['--op', f'file.open {ball}', '--select', 'S', '--op', 'mode.sculpt', '--press', '612,270', '--move', '620,274', '--release', '620,274', '--move', '100,700', '--op', 'render.device']
    env = dict(ENV, BEEMODEL_GPU_VIEW='on')
    r = subprocess.run([BIN, '--shot', f'{T}/g1.ppm', '--dump-log', f'{T}/log.txt', *a], capture_output=True, text=True, timeout=300, env=env)
    log = open(f'{T}/log.txt').read()
    u = [x for x in log.splitlines() if 'viewport:' in x]
    if not u or ' 0 frames' in u[-1]:
        print('    no GPU here: skipped')
        return
    env = dict(ENV, BEEMODEL_GPU_VIEW='off')
    subprocess.run([BIN, '--shot', f'{T}/g2.ppm', *a], capture_output=True, text=True, timeout=300, env=env)
    p, c = open(f'{T}/g1.ppm', 'rb').read(), open(f'{T}/g2.ppm', 'rb').read()
    hd = len(p) - 1280 * 800 * 3
    n = sum(1 for y in range(90, 540) for x in range(215, 1010) if max(abs(p[hd + (y * 1280 + x) * 3 + k] - c[hd + (y * 1280 + x) * 3 + k]) for k in range(3)) > 24)
    check(n < 400, f'drawn by the GPU ({u[-1].strip()[:40]}), the mesh as on the CPU: {n} pixels off')


def dumped_base(p):
    port('--op', f'file.open {p}', *d('b0'))
    return rd('b0')


def s_delta():
    print('-- a stroke costs what it moved --')
    p = f'{T}/big.bee'
    make(BALL % 5 + f'op("file.save", "{p}")\n')
    n = len(verts(p, 'S'))
    port('--op', f'file.open {p}', '--op', f'sculpt S "draw" {STROKE}', '--op', 'sculpt.undoinfo', '--op', f'file.save {T}/bigp.bee', '--op', 'edit.undo', '--op', f'file.save {T}/bigu.bee')
    ln = [x for x in logged() if 'sculpt.undoinfo step' in x][-1].split()
    bytes_ = int(ln[2])
    mv = moved(verts(f'{T}/bigp.bee', 'S'), verts(p, 'S'))
    check(mv > 1000 and bytes_ < (mv + 200) * 40, f'{n} vertices, {mv} moved: the step takes {bytes_} bytes, not {n * 12}')
    check(raw(f'{T}/bigu.bee', 'S') == raw(p, 'S'), 'and gives them all back')
    # the budget: steps that hold more than it go, oldest first
    args = ['--op', f'file.open {p}']
    for k in range(50):
        args += ['--op', f'sculpt S "draw" 0 2 1 0 2 1 100 0.0{k + 10}']
    port(*args, *['--op', 'edit.undo'] * 50, *d('b1'))
    b_ = dumped_base(p)
    check(rd('b1') != b_ and moved(rd('b1'), b_) > 1000, f'{n * 28 // 1000000} MB a step, 50 steps: the oldest go, the budget holds')


def s_fuzz():
    print('-- random strokes, undone and redone --')
    bases()
    base = f'{T}/ball.bee'
    rng = random.Random(SEED)
    b0 = raw(base, 'S')
    br = ['draw', 'clay strips', 'crease', 'inflate', 'grab', 'snake hook', 'smooth', 'flatten', 'pinch', 'layer', 'mask']
    for run in range(max(1, RUNS // 4)):
        args = ['--op', f'file.open {base}', '--select', 'S']
        n = 0
        for _ in range(rng.randrange(3, 14)):
            k = rng.random()
            if k < 0.6:
                a = [rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(0.05, 1.5), rng.uniform(-1, 1)]
                args += ['--op', f'sculpt S "{rng.choice(br)}" ' + ' '.join(f'{x:.4f}' for x in a)]
                n += 1
            elif k < 0.75:
                args += ['--op', rng.choice(['sculpt.symmetry x', 'sculpt.symmetry none', 'sculpt.symmetry xyz', 'sculpt.falloff root', 'sculpt.falloff smooth', 'sculpt.mask_invert', 'sculpt.mask_clear', 'sculpt.pressure_curve', 'sculpt.stabilizer'])]
            elif k < 0.85:
                args += ['--op', rng.choice(['mode.object', 'mode.sculpt', 'mode.edit', 'object.sculpt_mode'])]
            else:
                x, y = rng.randrange(300, 900), rng.randrange(200, 600)
                args += ['--drag', f'{x},{y},{rng.randrange(300, 900)},{rng.randrange(200, 600)}']
        end = f'{T}/fe.bee'
        args += ['--op', 'mode.object', '--op', f'file.save {end}']
        r0 = [f'{T}/f0.bee']
        args2 = list(args)
        for _ in range(40):
            args2 += ['--op', 'edit.undo']
        args2 += ['--op', f'file.save {r0[0]}']
        for _ in range(40):
            args2 += ['--op', 'edit.redo']
        args2 += ['--op', f'file.save {T}/f1.bee']
        r = port(*args2, ok=False)
        if r.returncode != 0:
            check(False, f'run {run}: {r.stderr[-400:]} {args2[:40]}')
            return
        a0, a1, e = raw(r0[0], 'S'), raw(f'{T}/f1.bee', 'S'), raw(end, 'S')
        if a0 != b0 or a1 != e:
            check(False, f'run {run}: undone to the start {a0 == b0}, redone to the end {a1 == e}: {args}')
            return
    check(True, f'{max(1, RUNS // 4)} sessions: undone to the file\'s bytes, redone to the end\'s')


def s_undo_window():
    print('-- undo with the pointer and the keys --')
    wb = wball()
    b0 = verts(wb, 'S')
    a = drag(560, 250, 720, 290, steps=10)
    b = drag(600, 330, 680, 280, steps=10)
    cz, csz = ['--key', 'ctrl+z'], ['--key', 'ctrl+shift+z']
    tab = ['--keydown', 'ctrl+tab', '--keyup', 'ctrl+tab']
    key = lambda k: ['--key', k]
    M, X = key('m'), key('x')
    run = lambda *steps: mouse(wb, [x for s in steps for x in s], f'{T}/pu.bee')
    va, vb, vab = run(a), run(b), run(a, b)
    moves('a stroke', va, b0)
    moves('two strokes', vab, va)
    cases = [
        ('two strokes, one undone', (a, b, cz), va),
        ('undone, redone', (a, b, cz, cz, csz), va),
        ('back to the file', (a, cz), b0),
        ('a new stroke drops the redo', (a, b, cz, b, csz), vab),
        ('a masked stroke undone', (M, a, X, b, cz), b0),
        ('the mask stroke is a step of no effect', (M, a, X, b, cz, cz), b0),
        ('the mask leaves with the mode', (M, a, X, tab, tab, b), vb),
        ('undone out of the mode', (a, tab, cz, tab, b), vb),
        ('settings are no steps', (a, key('c'), key('27'), cz, X, b), run(key('27'), b)),
    ]
    for name, steps, want in cases:
        got = run(*steps)
        check(got and got == want, f'{name}: {moved(got, b0) if got else 0} moved, as it should be ({moved(got, want) if got else "-"} apart)')


SCEN = ['s_brushes', 's_falloff', 's_mask', 's_objects', 's_threads', 's_files', 's_undo', 's_undo_window', 's_shared', 's_evaluated', 's_midstroke', 's_window', 's_ui', 's_look', 's_idle', 's_robust', 's_jobs', 's_views', 's_gpu', 's_delta', 's_fuzz']

if __name__ == '__main__':
    print(f'seed {SEED}')
    for n in (WANT or SCEN):
        globals()[n]()
    shutil.rmtree(T, ignore_errors=True)
    print(f'fails {len(FAILS)}')
    for f in FAILS:
        print('  FAILED:', f)
    sys.exit(1 if FAILS else 0)
