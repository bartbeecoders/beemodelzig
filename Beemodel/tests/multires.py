#!/usr/bin/env python3
"""Multires in BeeModel: every level of every kind of cage, what a level shows,
displacements (MRES) after strokes at a level, the modifier in the stack, its
buttons, undo with values, files read back, the window, the strange and the damaged.

    python3 tests/multires.py BIN [fuzz-runs=40] [seed] [scenario...]
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import math, os, random, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile
import wl_fake

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 40
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
WANT = sys.argv[4:]
FAILS = []
T = tempfile.mkdtemp(prefix='beemr-', dir=os.environ.get('BEERIG_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)
CPU = os.environ.get('BEE_CPU', '2')
ONE = ['taskset', '-c', CPU]

B = 'delete("Cube")\nadd("sphere", "S", 0, 2, 0)\n'
ST = '-0.5 2 1 0.5 2.2 0.9 0.4 0.5'
ST2 = '-0.3 2.2 0.9 0.6 2.4 0.7 0.5 0.5'
ST2D = '2.2 2.2 0.9 3.1 2.4 0.7 0.5 0.5'  # ST2 on a duplicate: object.duplicate puts it 2.5 along +X (op_duplicate_sel)
BRUSHES = ['draw', 'clay strips', 'crease', 'inflate', 'grab', 'snake hook', 'smooth', 'flatten', 'pinch', 'layer']


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def script(code):
    """A BeeScript run by BeeModel (to make a scene): its stdout."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    r = subprocess.run(ONE + [BIN, '--run', p], capture_output=True, text=True, timeout=900, env=ENV, cwd=T)
    if r.returncode != 0 or 'error:' in r.stdout + r.stderr:
        print((r.stdout + r.stderr)[-600:])
    return r.stdout


def port(*a, ok=True, one=True):
    r = subprocess.run((ONE if one else []) + [BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a], capture_output=True, text=True, timeout=900, env=ENV)
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


def finite(vs):
    return all(math.isfinite(c) for v in vs for c in v)


def d(tag, name='S'):
    return ['--dump-verts', f'{T}/{tag}.txt;{name}']


def rd(tag):
    return dumped(f'{T}/{tag}.txt')


def logged():
    return open(f'{T}/log.txt').read().splitlines()


def ui_rows():
    return [ln.rstrip('\n').split('\t') for ln in open(f'{T}/u.txt')]


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


def scene():
    p = f'{T}/b.bee'
    if not os.path.exists(p):
        script(B + f'op("file.save", "{p}")\n')
        c = f'{T}/mix.bee'
        script(f'add("cylinder", "C", 2, 1, 0)\nadd("plane", "P", 0, 0, 4)\nadd("cube", "K", -3, 1, 1)\nmove("K", 0.5, 0.25, -0.3)\nrotate("K", 0.3, -0.4, 0.2)\nscale("K", 1.5, 1.5, 1.5)\nop("file.save", "{c}")\n')
        check(os.path.exists(p) and os.path.exists(c), 'the scenes made')
    return p


def mres(p):
    return beefile.chunk(p, b'MRES')


def setup(levels, level):
    """Console lines: a multires modifier so."""
    return ['object.modifier_add multires', f'object.modifier_set 0 levels {levels}', f'object.modifier_set 0 level {level}']


def run(base, name, cmds, tag=''):
    """Console lines on a file, the object selected: the file saved after them."""
    q = f'{T}/q{tag}.bee'
    if os.path.exists(q):
        os.remove(q)
    port('--op', f'file.open {base}', '--select', name, *ops(*cmds), '--op', f'file.save {q}')
    return q


def fine_block(msg, q, base, name='S', base_same=True):
    """Displacements there and finite, the base mesh as it was."""
    m = mres(q) or b''
    vals = struct.unpack_from(f'<{(len(m) - 20) // 4}f', m, 20) if len(m) > 20 else ()
    ok = len(m) > 20 and all(math.isfinite(x) for x in vals) and any(x != 0 for x in vals)
    if base_same:
        ok = ok and raw(q, name) == raw(base, name)
    check(ok, f'{msg}: {len(m)} bytes of displacements, finite' + (', the base as it was' if base_same else ''))
    return ok


def applied(p, name, level):
    """The mesh that level is, applied."""
    out = f'{T}/ap.bee'
    port('--op', f'file.open {p}', '--select', name, '--op', f'object.modifier_set 0 level {level}', '--op', 'object.modifier_apply 0', '--op', f'file.save {out}')
    return raw(out, name), verts(out, name)


def levels_grow(msg, q, name, ks):
    """Each level applied: finite, more vertices than the one before."""
    last = None
    for k in ks:
        a, vs = applied(q, name, k)
        if not finite(vs):
            check(False, f'{msg}: level {k} not finite')
            return
        if last is not None and (a == last[0] or len(vs) <= last[1]):
            check(False, f'{msg}: level {k} is no finer than the level before ({len(vs)} vertices)')
            return
        last = (a, len(vs))
    check(True, f'{msg}: levels {list(ks)}, each finer (the last {last[1]} vertices)')


def s_levels():
    print('-- every level of every kind of cage --')
    p = scene()
    mix = f'{T}/mix.bee'
    for name, base, top in (('S', p, 4), ('C', mix, 5), ('P', mix, 6), ('K', mix, 5)):
        q = run(base, name, setup(top, 0))
        check(mres(q) == b'', f'{name}: no displacements yet')
        levels_grow(name, q, name, range(1, top + 1))
    print('-- what a level shows is the level applied --')
    q = run(p, 'S', setup(3, 2))
    port('--op', f'file.open {q}', *d('e0'))
    _, vs = applied(q, 'S', 2)
    ev = rd('e0')
    check(len(ev) == len(vs) and worst(ev, vs) <= 2e-6, f'level 2 shows {len(ev)} vertices, applied {len(vs)}, worst {worst(ev, vs):.2e}')
    print('-- the stored values: 6 is the default level, shown as the levels there are --')
    q2 = f'{T}/defq.bee'
    port('--op', f'file.open {p}', '--select', 'S', '--op', 'object.modifier_add multires', '--op', f'file.save {q2}')
    port('--op', f'file.open {q2}', *d('e1'))
    check(len(rd('e1')) == 7938, f'levels 2, level 6: level 2 shows ({len(rd("e1"))})')
    for v, want in ((2.5, 2), (3.5, 4), (9, 6), (0, 1), (-4, 1)):
        q = run(p, 'S', ['object.modifier_add multires', f'object.modifier_set 0 levels {v}'])
        check(struct.unpack_from('<f', beefile.chunk(q, b'MODS'), 24)[0] == want, f'levels {v} -> {want}, rounded to even, 1 to 6')


def s_sculpt():
    print('-- strokes at a level: displacements, the base left alone --')
    p = scene()
    y0 = setup(3, 2)
    for b in BRUSHES:
        q = run(p, 'S', [*y0, f'sculpt S "{b}" {ST}', 'mode.object'])
        fine_block(b, q, p)
    print('-- each level over the others --')
    cmds = [*y0[:2], 'object.modifier_set 0 level 1', f'sculpt S "draw" {ST}', 'object.modifier_set 0 level 3', f'sculpt S "clay strips" {ST2}', 'object.modifier_set 0 level 2', f'sculpt S "smooth" {ST}', 'object.modifier_set 0 level 0', f'sculpt S "inflate" {ST2}', 'mode.object']
    q = run(p, 'S', cmds)
    fine_block('levels 1, 3, 2, then the base', q, p, base_same=False)
    check(raw(q, 'S') != raw(p, 'S'), 'level 0 sculpted the base')
    levels_grow('all of it', q, 'S', [1, 2, 3])
    print('-- settings: symmetry, falloff, a mask --')
    q = run(p, 'S', [*y0, 'sculpt.symmetry x', 'sculpt.falloff root', f'sculpt S "mask" {ST2}', 'sculpt S "draw" 0.3 2.5 0.8 0.4 2.6 0.7 0.45 0.6', 'sculpt S "draw" 0.3 2.3 0.8 0.4 2.4 0.7 0.45 0.6', 'mode.object'])
    q0 = run(p, 'S', [*y0, 'sculpt S "draw" 0.3 2.5 0.8 0.4 2.6 0.7 0.45 0.6', 'sculpt S "draw" 0.3 2.3 0.8 0.4 2.4 0.7 0.45 0.6', 'mode.object'], tag='0')
    fine_block('mirrored, masked', q, p)
    check(mres(q) != mres(q0), '  not what the strokes give plain')
    print('-- propagate down --')
    cmds = [*y0[:2], 'object.modifier_set 0 level 3', f'sculpt S "draw" {ST}', f'sculpt S "pinch" {ST2}', 'mode.object']
    q0 = run(p, 'S', cmds, tag='0')
    q = run(p, 'S', [*cmds, 'multires.propagate_down'])
    check(any('coarser levels follow the finest' in x for x in logged()), 'it says so')
    fine_block('the coarser levels follow', q, p)
    check(mres(q) != mres(q0), '  the block changed')
    levels_grow('after it', q, 'S', [1, 2, 3])
    q1 = run(p, 'S', [*cmds, 'multires.propagate_down', 'sculpt S "smooth" 0 2 1 0.1 2 1 0.5 0.5', 'mode.object'], tag='1')
    check(mres(q1) != mres(q) and len(mres(q1)) == len(mres(q)), 'and sculpting goes on')
    print('-- a level higher than the block: the rest zero, the block grows --')
    q0 = run(p, 'S', [*y0, f'sculpt S "draw" {ST}', 'mode.object'], tag='0')
    q = run(p, 'S', [*y0, f'sculpt S "draw" {ST}', 'object.modifier_set 0 level 3', f'sculpt S "draw" {ST2}', 'mode.object'])
    check(len(mres(q)) > len(mres(q0)) > 0, f'level 2, then 3: {len(mres(q0))} -> {len(mres(q))} bytes')
    q = run(p, 'S', [*y0[:2], 'object.modifier_set 0 level 3', f'sculpt S "draw" {ST}', 'object.modifier_set 0 level 1', f'sculpt S "draw" {ST2}', 'mode.object'])
    check(len(mres(q)) > len(mres(q0)), f'level 3, then 1: the block stays long ({len(mres(q))} bytes)')


def s_stack():
    print('-- the stack: order, on and off, what comes after --')
    p = scene()
    y0 = setup(2, 2)
    s1 = [f'sculpt S "draw" {ST}', 'mode.object']
    q0 = run(p, 'S', [*y0, *s1], tag='0')
    fine_block('the sculpted one', q0, p)
    port('--op', f'file.open {q0}', *d('s0'))
    plain = rd('s0')
    for what, cmds in (('mirror after', ['object.modifier_add mirror']), ('subsurf after', ['object.modifier_add subsurf']),
                       ('solidify after', ['object.modifier_add solidify']), ('it off', ['object.modifier_toggle 0'])):
        port('--op', f'file.open {q0}', '--select', 'S', *ops(*cmds), *d('s1'))
        ev = rd('s1')
        if what == 'it off':
            check(ev == [tuple(v) for v in verts(q0, 'S')], f'{what}: the base shows ({len(ev)} vertices)')
        else:
            check(finite(ev) and ev != plain and len(ev) >= len(plain), f'{what}: {len(ev)} vertices, finite, not the level alone ({len(plain)})')
    print('-- not first: it reads the stack\'s input; sculpting goes to the base --')
    q = run(p, 'S', ['object.modifier_add mirror', 'object.modifier_add multires', 'object.modifier_set 1 levels 2', *s1])
    check(mres(q) == b'' and raw(q, 'S') != raw(p, 'S'), 'mirror first: the base is sculpted, no displacements')
    q = run(q0, 'S', ['object.modifier_add_subsurf', 'object.modifier_move_up 1'], tag='2')
    port('--op', f'file.open {q}', *d('s2'))
    check(finite(rd('s2')) and len(rd('s2')) > 0, f'moved under another: {len(rd("s2"))} vertices, finite')
    q = run(p, 'S', ['object.modifier_add multires', 'object.modifier_add multires', 'object.modifier_set 0 levels 1', 'object.modifier_set 1 levels 1'])
    port('--op', f'file.open {q}', *d('s3'))
    check(finite(rd('s3')) and len(rd('s3')) > 482, f'two of them: {len(rd("s3"))} vertices, finite')
    q = run(p, 'S', ['object.modifier_add mirror', 'object.modifier_toggle 0', y0[0], 'object.modifier_set 1 levels 2', 'object.modifier_set 1 level 2', *s1], tag='5')
    fine_block('a modifier off before it: it is still the first', q, p)
    print('-- shape keys and bones under it --')
    ko = f'{T}/sk.bee'
    script(f'op("file.open", "{p}")\nselect("S")\ni = 0\nwhile i < 200 {{ vmove("S", i, vpos("S", i, 0), vpos("S", i, 1) + 0.5, vpos("S", i, 2))\n i = i + 1 }}\nop("shape.add", "Up S")\nop("shape.set", "Up 0.5 S")\nop("file.save", "{ko}")\n')
    q = run(ko, 'S', [*y0, *s1], tag='4')
    fine_block('shape keys on: a level sculpts the plain base', q, ko)
    port('--op', f'file.open {q}', *d('s4'))
    check(finite(rd('s4')) and len(rd('s4')) == len(plain) and rd('s4') != plain, f'shape keys: what shows, {len(rd("s4"))} vertices, the key in it')
    print('-- apply --')
    sizes = []
    for k in (2, 1, 0):
        q = f'{T}/qa.bee'
        port('--op', f'file.open {q0}', '--select', 'S', '--op', f'object.modifier_set 0 level {k}', '--op', 'object.modifier_apply 0', '--op', f'file.save {q}')
        sizes.append(len(verts(q, 'S')))
        check(finite(verts(q, 'S')) and beefile.chunk(q, b'MODS') != beefile.chunk(q0, b'MODS'), f'applied at level {k}: {sizes[-1]} vertices, the modifier gone')
        check((len(mres(q)) > 0) == (k == 0), f'  the block: {len(mres(q))} bytes, {"it stays (it fits)" if k == 0 else "it goes"}')
    check(sizes[0] > sizes[1] > sizes[2] == 482, f'finer the higher: {sizes}')


def s_undo():
    print('-- undo: displacements shared with the steps --')
    p = scene()
    y0 = setup(3, 2)
    fr = ['--op', f'file.open {p}', '--select', 'S', *ops(*y0)]
    sv = lambda k: ['--op', f'file.save {T}/k{k}.bee', *d(f'k{k}')]
    g = lambda k: mres(f'{T}/k{k}.bee')
    a, b = f'sculpt S "draw" {ST}', f'sculpt S "smooth" {ST2}'
    port(*fr, *sv(0), '--op', a, *sv(1), '--op', b, *sv(2), '--op', 'edit.undo', *sv(3), '--op', 'edit.undo', *sv(4), '--op', 'edit.redo', *sv(5), '--op', 'edit.redo', *sv(6), '--op', 'edit.undo_history')
    check(g(0) == b'' and g(1) != g(2) and len(g(1)) > 0, 'two strokes, two blocks')
    check(g(3) == g(1) and g(4) == b'' and g(5) == g(1) and g(6) == g(2), 'undone, redone: each block back')
    check(rd('k3') == rd('k1') and rd('k4') == rd('k0') and rd('k6') == rd('k2') and rd('k2') != rd('k1'), 'and what shows with it, in the mode')
    st = [x[1] for x in ui_rows() if x[0] == 'step']
    check(st[-2:] == ['Sculpt', 'Sculpt'], f'a stroke, a step ({st})')
    print('-- many strokes, then back and forth, a sculpt after each --')
    n = 16
    args = list(fr) + sv(0)
    rng = random.Random(SEED)
    for k in range(n):
        q = [rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(0.1, 0.9), rng.uniform(-0.9, 0.9)]
        args += ['--op', f'sculpt S "{rng.choice(["draw", "smooth", "pinch", "clay strips"])}" ' + ' '.join(f'{v:.4f}' for v in q), '--op', f'file.save {T}/s{k + 1}.bee']
    for k in range(n):
        args += ['--op', 'edit.undo', '--op', f'file.save {T}/u{n - k - 1}.bee']
    for k in range(n):
        args += ['--op', 'edit.redo', '--op', f'file.save {T}/r{k + 1}.bee']
    port(*args)
    sv2 = [g(0)] + [mres(f'{T}/s{k}.bee') for k in range(1, n + 1)]
    check(sum(sv2[k] != sv2[k + 1] for k in range(n)) >= n - 4, f'{n} strokes moved something')
    check(all(mres(f'{T}/u{k}.bee') == sv2[k] for k in range(1, n)) and mres(f'{T}/u0.bee') == b'', f'{n} undos: each block, byte for byte')
    check(all(mres(f'{T}/r{k + 1}.bee') == sv2[k + 1] for k in range(n)), f'{n} redos: each again')
    print('-- levels, stack order --')
    port(*fr, '--op', a, '--op', 'mode.object', *sv(0), '--op', 'object.modifier_set 0 level 3', *sv(1), '--op', 'object.modifier_add mirror', *sv(2), '--op', 'object.modifier_move_up 1', *sv(3),
         '--op', 'edit.undo', *sv(4), '--op', 'edit.undo', *sv(5), '--op', 'edit.undo', *sv(6))
    check(len(rd('k1')) > len(rd('k0')) and rd('k2') != rd('k1') and rd('k3') != rd('k2'), 'a level, a mirror, moved first')
    check(rd('k4') == rd('k2') and rd('k5') == rd('k1') and rd('k6') == rd('k0'), 'each undone')
    print('-- remove, then undo: the detail is still on the object --')
    port(*fr, '--op', a, '--op', 'mode.object', *sv(0), '--op', 'object.modifier_remove 0', *sv(1), '--op', 'edit.undo', *sv(2))
    check(len(rd('k1')) == 482 and rd('k2') == rd('k0') and g(1) == g(0) and len(g(0)) > 0, 'removed: the block stays in the file; undone: it shows')
    print('-- apply, then undo --')
    port(*fr, '--op', a, '--op', 'mode.object', *sv(0), '--op', 'object.modifier_apply 0', *sv(1), '--op', 'edit.undo', *sv(2), '--op', 'edit.redo', *sv(3))
    check(g(1) == b'' and g(2) == g(0) and rd('k2') == rd('k0') and rd('k3') == rd('k1'), 'the block goes with the apply and comes back with the undo')
    print('-- a mesh edited under it: the same counts keep the detail, others lose it --')
    port(*fr, '--op', a, '--op', 'mode.object', *sv(0), '--op', 'mode.edit', '--op', 'mesh.subdivide', '--op', 'mode.object', *sv(2), '--op', 'edit.undo', *sv(3), '--op', f'sculpt S "smooth" {ST2}', '--op', 'mode.object', *sv(4), '--op', 'edit.undo', *sv(5), '--op', 'edit.undo', *sv(6))
    check(len(rd('k2')) != len(rd('k0')) and g(2) == g(0), 'subdivided: the block stays on the object, unused')
    check(rd('k3') == rd('k0'), 'undone: it fits again')
    check(g(4) != g(3) and rd('k5') == rd('k3'), 'a stroke on it, undone, with values')
    # the same counts: the base moved under the block (a file: edit mode's moves are modal)
    q1 = f'{T}/k0.bee'
    vs, polys = beefile.meshes(q1)[next(x for x in beefile.objects(q1) if x['name'] == 'S')['mesh']]
    moved_ = f'{T}/mv.bee'
    patched(q1, moved_, 'S', [(x * 1.5, y + 0.25, z) for x, y, z in vs], polys)
    check(len(mres(moved_)) > 0, 'a base moved under its block')
    levels_grow('it fits by its counts', moved_, 'S', [1, 2, 3])
    q = run(p, 'S', [*y0, a, 'mode.object', 'mode.edit', 'mesh.subdivide', 'mode.object', f'sculpt S "draw" {ST}', 'mode.object'], tag='1')
    check(len(mres(q)) > 0, f'a stroke on the new base: a new block, {len(mres(q))} bytes')
    check(struct.unpack_from('<I', mres(q), 8)[0] != 482, 'its counts are the new base\'s')
    print('-- two objects, one mesh --')
    port(*fr, '--op', 'object.duplicate', '--op', f'file.save {T}/dup.bee')
    dup = [x['name'] for x in beefile.objects(f'{T}/dup.bee') if x['name'] not in ('S', 'Camera', 'Light')][0]
    port(*fr, '--op', a, '--op', 'mode.object', '--op', 'object.duplicate', *d('d0', dup), '--op', 'mode.object', '--select', dup, '--op', f'sculpt {dup} "draw" {ST2D}', '--op', 'mode.object', *d('d1', dup), *d('d2', 'S'), '--op', f'file.save {T}/two.bee', '--op', 'edit.undo', *d('d3', dup))
    check(rd('d0') != rd('d1') and rd('d3') == rd('d0'), 'the duplicate has the detail, and its own from then on')
    n = struct.unpack_from('<I', mres(f'{T}/two.bee'), 4)[0]
    check(len(mres(f'{T}/two.bee')) == 2 * (20 + n * 12), 'each has its block in the file')
    print('-- dyntopo and multires --')
    port(*fr, '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', 'sculpt.info')
    check(any('dyntopo: not on a multires level (level 0 sculpts the base)' in x for x in logged()), 'dyntopo is refused at a level, and says why')
    q = run(p, 'S', [*y0, 'mode.sculpt', 'sculpt.dyntopo', 'mode.object', 'object.modifier_set 0 level 0', 'mode.sculpt', 'sculpt.dyntopo', f'sculpt S "draw" {ST}', 'mode.object'])
    check(raw(q, 'S') != raw(p, 'S') and finite(verts(q, 'S')), 'dyntopo at level 0: the base sculpted')
    q = run(p, 'S', [*y0[:2], 'object.modifier_set 0 level 0', 'mode.sculpt', 'sculpt.dyntopo', 'mode.object', 'object.modifier_set 0 level 2', f'sculpt S "draw" {ST}', 'mode.object'], tag='3')
    check(raw(q, 'S') != raw(p, 'S') and finite(verts(q, 'S')), 'dyntopo on, then a level: the base is what sculpts')
    print('-- memory: the blocks only the history holds are in its budget --')
    y3 = setup(6, 6)
    n = 60
    args = ['--op', f'file.open {p}', '--select', 'S', *ops(*y3)]
    for k in range(n):
        args += ['--op', f'sculpt S "draw" {-0.5 + k * 0.01} 2 1 {-0.4 + k * 0.01} 2.1 0.9 0.05 0.1']
    py = f'import resource, subprocess, sys\nr = subprocess.run({ONE + [BIN, "--shot", T + "/u.ppm", *args]!r}, capture_output=True, env={ENV!r})\nprint(r.returncode, resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024)\n'
    rc, mb = map(int, subprocess.run([sys.executable, '-c', py], capture_output=True, text=True).stdout.split())
    # (24 MB a block: 60 of them are 1.4 GB; level 6's mesh, its plan and the sculpt's arrays come to about as much again)
    check(rc == 0 and mb < 512 + 1600, f'{n} strokes at level 6: at most {mb} MB')


def s_files():
    print('-- .bee: saved, opened, saved again --')
    p = scene()
    y0 = setup(3, 2)
    q = run(p, 'S', [*y0, f'sculpt S "draw" {ST}', 'mode.object'])
    fine_block('saved', q, p)
    q2 = f'{T}/q2.bee'
    port('--op', f'file.open {q}', '--op', f'file.save {q2}')
    check(mres(q2) == mres(q) and beefile.chunk(q2, b'MODS') == beefile.chunk(q, b'MODS') and raw(q2, 'S') == raw(q, 'S'), 'opened and saved again: the same block, stack and base')
    port('--op', f'file.open {q}', *d('f0'))
    port('--op', f'file.open {q}', '--select', 'S', '--op', f'sculpt S "draw" {ST}', '--op', 'mode.object', '--op', 'edit.undo', *d('f1'))
    p2 = run(p, 'S', [*y0, f'sculpt S "draw" {ST}'], tag='l')
    port('--op', f'file.open {p2}', *d('f2'))
    check(rd('f0') == rd('f2') and rd('f1') == rd('f0'), 'what shows from the file is what showed when it was saved')
    q3 = f'{T}/q3.bee'
    port('--op', f'file.open {q}', '--select', 'S', '--op', f'sculpt S "smooth" {ST2}', '--op', 'mode.object', '--op', f'file.save {q3}')
    check(mres(q3) != mres(q) and len(mres(q3)) == len(mres(q)), 'on top of the file\'s: the block changes')
    tags = lambda f: [t for t, _ in beefile.chunks(f)]
    check(b'MRES' in tags(q) and mres(p) == b'', 'an empty chunk when there is nothing')
    port('--op', f'file.open {q}', '--select', 'S', '--op', 'object.modifier_remove 0', '--op', 'object.duplicate', '--op', f'file.save {q2}')
    check(len(mres(q2)) == 2 * len(mres(q)), 'without its modifier, and on a duplicate: the block is saved')
    print('-- an object BeeModel does not keep --')
    head, cs = chunks_of(q)
    objs = beefile.objects(q)
    b0 = mres(q)
    extra = struct.pack('<5I', len(objs) + 7, 1, 0, 0, 0) + struct.pack('<3f', 1, 2, 3)
    p3 = f'{T}/x.bee'
    open(p3, 'wb').write(pack(head, [(t, b0 + extra if t == b'MRES' else b) for t, b in cs if t != b'ZIDX']))
    port('--op', f'file.open {p3}', '--op', f'file.save {q2}')
    check(mres(q2) == b0, 'a block for no object is left out')


# ---- the window (the fake compositor) ------------------------------------------------

ROW = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
ROW.update({'.': 52, '/': 53, ' ': 57, '0': 11, '-': 12})
ROW.update({str(i): i + 1 for i in range(1, 10)})


def typed(f, s):
    for c in s:
        if c == '_':
            f.key(12, 1)
        elif c.isupper():
            f.key(ROW[c.lower()], 1)
        else:
            f.key(ROW[c])


def window(scene_file):
    f = wl_fake.Fake(BIN, size=(1280, 800), env={'HOME': T}, args=(scene_file,))
    os.sched_setaffinity(f.proc.pid, {int(CPU)})
    f.until(lambda: f.frames > 0, 15)
    f.pump(1.0)
    f.enter(640, 300)
    f.motion(640, 300)
    f.pump(0.5)
    return f


def drag(f, x0, y0, x1, y1, steps=16):
    f.motion(x0, y0)
    f.pump(0.3)
    f.button(0x110, True)
    for k in range(1, steps + 1):
        f.motion(x0 + (x1 - x0) * k // steps, y0 + (y1 - y0) * k // steps)
        f.pump(0.3)
    f.button(0x110, False)
    f.pump(0.3)


def save_in(f, out):
    f.key(28)
    f.pump(0.2)
    typed(f, f'file.save {out}')
    f.key(28)
    t0 = time.time()
    while not os.path.exists(out) and time.time() - t0 < 60:
        f.pump(0.1)


def s_ui():
    print('-- the Modifiers tab --')
    p = scene()
    fr = ['--op', f'file.open {p}', '--select', 'S', '--click-label', 'tab:Modifiers']
    port(*fr, '--click-label', 'button:Add Modifier', '--wait', '100')
    rows = ui_rows()
    state = {x[1]: x[3] for x in rows if len(x) > 3}
    check(state.get('Multiresolution') == 'on', f'the list has it, not greyed ({state.get("Multiresolution")})')
    port(*fr, '--click-label', 'button:Add Modifier', '--click-label', 'menuitem:Multiresolution', '--wait', '100')
    labels = [x[1] for x in ui_rows() if len(x) > 1]
    for w in ('Multires', 'Levels', 'Level', 'Subdivide', 'Propagate'):
        check(w in labels, f'the tab has {w}')
    check(not any('Not available yet' in x for x in labels), 'nothing says it is not there')
    print('-- Subdivide: one level more, shown --')
    port(*fr, '--op', 'object.modifier_add multires', '--wait', '50', *d('u0'), '--click-label', 'button:Subdivide', '--wait', '50', *d('u1'), '--op', f'file.save {T}/u.bee', '--op', 'edit.undo', *d('u2'), '--op', 'edit.undo_history')
    m_ = beefile.chunk(f'{T}/u.bee', b'MODS')
    k = m_.find(struct.pack('<II', 9, 1))
    lv = struct.unpack_from('<2f', m_, k + 8)
    check(lv == (3.0, 3.0), f'levels 3, level 3 ({lv})')
    check(len(rd('u1')) > len(rd('u0')) and rd('u2') == rd('u0'), f'{len(rd("u0"))} -> {len(rd("u1"))} vertices, undone in one step')
    many = ['--click-label', 'button:Subdivide', '--wait', '30'] * 7
    box = f'{T}/box.bee'
    port('--op', f'file.save {box}')
    port('--op', f'file.open {box}', '--select', 'Cube', '--click-label', 'tab:Modifiers', '--op', 'object.modifier_add multires', '--wait', '50', *many, '--op', f'file.save {T}/u.bee')
    m_ = beefile.chunk(f'{T}/u.bee', b'MODS')
    k = m_.find(struct.pack('<II', 9, 1))
    lv = struct.unpack_from('<2f', m_, k + 8)
    check(lv == (6.0, 6.0), f'it stops at 6 ({lv})')
    print('-- Propagate --')
    port(*fr, '--op', 'object.modifier_add multires', '--op', 'object.modifier_set 0 level 2', '--op', f'sculpt S "draw" {ST}', '--op', 'mode.object', '--op', f'file.save {T}/v0.bee', '--wait', '50', '--click-label', 'button:Propagate', '--wait', '100', '--op', f'file.save {T}/v1.bee', '--op', 'edit.undo', '--op', f'file.save {T}/v2.bee')
    check(mres(f'{T}/v1.bee') != mres(f'{T}/v0.bee') and mres(f'{T}/v2.bee') == mres(f'{T}/v0.bee'), 'the button runs it, one step')
    port('--op', f'file.open {p}', '--select', 'Camera', '--op', 'multires.propagate_down')
    check(any('multires: select a mesh with a multires modifier' in x for x in logged()), 'no multires: it says so')
    port('--op', f'file.open {p}', '--select', 'S', '--op', 'multires.propagate_down', '--op', 'edit.undo_history')
    check(any('multires: select a mesh with a multires modifier' in x for x in logged()) and [x[1] for x in ui_rows() if x[0] == 'step'] == ['Original'], 'and leaves no step')
    print('-- the settings line, a stroke through the window, idle --')
    wb = f'{T}/lb.bee'
    script(B + 'scale("S", 3.5, 3.5, 3.5)\nselect("S")\nmodifier("S", "multires")\nmodset("S", 0, "levels", 2)\nmodset("S", 0, "level", 2)\n' + f'op("file.save", "{wb}")\n')
    port('--op', f'file.open {wb}', '--select', 'S', '--op', 'mode.sculpt', '--move', '640,300')
    check('multires level 2' in [x[1] for x in ui_rows() if len(x) > 1], 'the line over the bar says the level')
    out = f'{T}/pl.bee'
    f = window(wb)
    try:
        f.key(15, 4)   # Ctrl+Tab: sculpt mode
        f.pump(0.5)
        drag(f, 560, 250, 720, 290)
        f.pump(1.5)
        n = f.frames
        f.pump(1.5)
        idle = f.frames - n
        f.key(15, 4)
        f.pump(0.3)
        save_in(f, out)
        alive = f.proc.poll() is None
    finally:
        err = f.close()
    check(os.path.exists(out) and alive, f'the window saves through its console ({err[-200:] if not alive else "alive"})')
    if os.path.exists(out):
        fine_block('a stroke through the window', out, wb)
    check(idle == 0, f'at a level, after a stroke, nothing moves, nothing is drawn ({idle} frames)')


def s_robust():
    print('-- the strange --')
    p = scene()
    y0 = setup(3, 2)
    base = f'{T}/plain.bee'
    port('--op', f'file.save {base}')
    tri = f'{T}/tri.bee'
    patched(base, tri, 'Cube', [(-1, 0, 0), (1, 0, 0), (0, 2, 0)], [[0, 1, 2]])
    y1 = setup(3, 3)
    q = run(tri, 'Cube', [*y1, 'sculpt Cube "draw" 0 1 0 0.2 1 0.1 1 0.5', 'mode.object'])
    fine_block('a single triangle', q, tri, 'Cube')
    levels_grow('a single triangle', q, 'Cube', [1, 2, 3])
    fan = f'{T}/fan.bee'
    patched(base, fan, 'Cube', [(0, 0, 0), (2, 0, 0), (1, 2, 0), (1, -2, 0), (1, 0, 2), (9, 9, 9)], [[0, 1, 2], [1, 0, 3], [0, 1, 4]])
    q = run(fan, 'Cube', y1)
    levels_grow('three faces on an edge, a loose vertex', q, 'Cube', [1, 2, 3])
    print('-- level limit, too much for the memory --')
    y6 = setup(6, 6)
    r = port('--op', f'file.open {p}', '--select', 'S', *ops(*y6), *d('l6'), '--op', 'sculpt.info', ok=False, one=False)
    check(r.returncode == 0 and len(rd('l6')) > 1000000, f'level 6 of a sphere: {len(rd("l6"))} vertices')
    big = f'{T}/nomem.bee'
    r = subprocess.run(['prlimit', f'--as={300 << 20}', BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--op', f'file.open {p}', '--select', 'S', *ops(*y6), '--op', 'mode.sculpt', '--op', 'sculpt.info', '--op', f'sculpt S "draw" {ST}', '--op', 'mode.object', '--op', f'file.save {big}'], capture_output=True, text=True, env=ENV)
    check(r.returncode == 0 and os.path.exists(big), f'under a memory limit: no crash ({r.returncode}, {r.stderr[-200:]})')
    print('-- values stored strangely --')
    q = run(p, 'S', setup(2, 2))
    head, cs = chunks_of(q)
    m0 = beefile.chunk(q, b'MODS')
    k = m0.find(struct.pack('<II', 9, 1))
    for name, a, c in (('NaN, NaN', float('nan'), float('nan')), ('inf, -inf', float('inf'), float('-inf')), ('-5, 40', -5, 40), ('2.9, 1.9', 2.9, 1.9)):
        m1 = m0[:k + 8] + struct.pack('<2f', a, c) + m0[k + 16:]
        f = f'{T}/w.bee'
        open(f, 'wb').write(pack(head, [(t, m1 if t == b'MODS' else b) for t, b in cs if t != b'ZIDX']))
        w3 = f'{T}/w3.bee'
        if os.path.exists(w3):
            os.remove(w3)
        r = port('--op', f'file.open {f}', '--select', 'S', '--op', 'object.modifier_apply 0', '--op', f'file.save {w3}', ok=False)
        vs = verts(w3, 'S') if os.path.exists(w3) else []
        check(r.returncode == 0 and finite(vs) and 482 <= len(vs) <= 2000000, f'levels {name}: applied cleanly, {len(vs)} vertices, finite')
    r = port('--op', f'file.open {p}', '--select', 'S', '--op', 'object.modifier_add multires', '--click-label', 'tab:Modifiers', '--dbl-label', 'number:Levels', '--type', '0/0', '--key', 'enter', '--op', f'file.save {T}/t.bee', ok=False)
    m_ = beefile.chunk(f'{T}/t.bee', b'MODS')
    check(r.returncode == 0 and struct.unpack_from('<f', m_, m_.find(struct.pack('<II', 9, 1)) + 8)[0] == 2, 'a typed NaN leaves it')
    print('-- damaged MRES --')
    q = run(p, 'S', [*y0, f'sculpt S "draw" {ST}', 'mode.object'])
    head, cs = chunks_of(q)
    b0 = mres(q)
    w = lambda body: open(f'{T}/dm.bee', 'wb').write(pack(head, [(t, body if t == b'MRES' else b) for t, b in cs if t != b'ZIDX']))

    def one(name, body):
        w(body)
        r = port('--op', f'file.open {T}/dm.bee', '--select', 'S', '--op', f'sculpt S "draw" {ST2}', '--op', 'mode.object', '--op', 'object.modifier_set 0 level 3', *d('dm'), '--op', 'multires.propagate_down', '--op', 'edit.undo', '--op', f'file.save {T}/dm2.bee', ok=False)
        check(r.returncode == 0, f'{name}: {r.stderr[-300:] if r.returncode else "no crash"}')
    one('cut short', b0[:100])
    one('count past the chunk', b0[:4] + struct.pack('<I', 0x7ffffff) + b0[8:])
    one('count huge', b0[:4] + struct.pack('<I', 0xffffffff) + b0[8:])
    one('index past the objects', struct.pack('<I', 1000) + b0[4:])
    one('another base', b0[:8] + struct.pack('<3I', 3, 3, 3) + b0[20:])
    one('a count of nothing', b0[:4] + struct.pack('<I', 0) + b0[8:20])
    one('short of level 1', b0[:4] + struct.pack('<I', 5) + b0[8:20] + b0[20:80])
    nan = struct.pack('<f', float('nan'))
    one('NaN displacements', b0[:20] + nan * ((len(b0) - 20) // 4))
    inf = struct.pack('<f', float('inf'))
    one('infinite displacements', b0[:20] + inf * ((len(b0) - 20) // 4))
    rng = random.Random(SEED)
    for k in range(RUNS):
        b = bytearray(b0)
        for _ in range(rng.randrange(1, 12)):
            b[rng.randrange(0, 64)] = rng.randrange(256)
        for _ in range(rng.randrange(1, 40)):
            b[rng.randrange(len(b))] = rng.randrange(256)
        w(bytes(b))
        r = port('--op', f'file.open {T}/dm.bee', '--select', 'S', '--op', f'sculpt S "draw" {ST2}', '--op', 'mode.object', '--op', 'object.modifier_set 0 level 3', '--op', 'multires.propagate_down', ok=False)
        if r.returncode != 0:
            shutil.copy(f'{T}/dm.bee', '/tmp/beemr-crash.bee')
            check(False, f'a damaged block: {r.stderr[-400:]}')
            break
    else:
        check(True, f'{RUNS} damaged blocks')
    print('-- random sessions, undone and redone --')
    br = ['draw', 'clay strips', 'smooth', 'grab', 'pinch', 'mask']
    for run_ in range(max(1, RUNS // 4)):
        args = ['--op', f'file.open {p}', '--select', 'S', *ops(*setup(rng.randrange(1, 4), 2))]
        for _ in range(rng.randrange(3, 12)):
            k = rng.random()
            if k < 0.5:
                a = [rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(0.05, 1.5), rng.uniform(-1, 1)]
                args += ['--op', f'sculpt S "{rng.choice(br)}" ' + ' '.join(f'{x:.4f}' for x in a)]
            elif k < 0.75:
                args += ['--op', f'object.modifier_set 0 level {rng.randrange(0, 4)}']
            elif k < 0.85:
                args += ['--op', rng.choice(['mode.object', 'mode.sculpt', 'multires.propagate_down', 'object.modifier_toggle 0'])]
            else:
                x, y = rng.randrange(300, 900), rng.randrange(200, 600)
                args += ['--drag', f'{x},{y},{rng.randrange(300, 900)},{rng.randrange(200, 600)}']
        end = f'{T}/fe.bee'
        args += ['--op', 'mode.object', '--op', f'file.save {end}', *['--op', 'edit.undo'] * 30, '--op', f'file.save {T}/f0.bee', *['--op', 'edit.redo'] * 30, '--op', f'file.save {T}/f1.bee']
        r = port(*args, ok=False)
        if r.returncode != 0:
            check(False, f'run {run_}: {r.stderr[-400:]} {args[:40]}')
            return
        ok = mres(f'{T}/f0.bee') == b'' and mres(f'{T}/f1.bee') == mres(end) and raw(f'{T}/f1.bee', 'S') == raw(end, 'S') and raw(f'{T}/f0.bee', 'S') == raw(p, 'S')
        if not ok:
            check(False, f'run {run_}: {args}')
            return
    check(True, f'{max(1, RUNS // 4)} sessions: undone to the file, redone to the end')


SCEN = ['s_levels', 's_sculpt', 's_stack', 's_undo', 's_files', 's_ui', 's_robust']

if __name__ == '__main__':
    print(f'multires: {BIN}, runs {RUNS}, seed {SEED}')
    for n in (WANT or SCEN):
        globals()[n]()
    shutil.rmtree(T, ignore_errors=True)
    print(f'fails {len(FAILS)}')
    for f in FAILS:
        print('  FAILED:', f)
    sys.exit(1 if FAILS else 0)
