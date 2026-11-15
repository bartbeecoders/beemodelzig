#!/usr/bin/env python3
"""Dynamic topology, BeeModel on its own: a stroke with dyntopo on leaves a mesh of
whole triangles (each vertex used, each edge on two triangles where the mesh is closed),
the topology changed, and the same stroke run again on one CPU (taskset) gives the same
triangles in the same order and the same vertices, byte for byte, from the console and
from the (headless) window. Undo with values, what a mesh loses when its topology
changes, files (save -> open -> save), modes, the strange and the damaged; the window in
the fake compositor (tests/wl_fake.py) idle.

    python3 tests/dyntopo.py BIN [fuzz-runs=40] [seed] [scenario...]

(tests/sculpt.py's helpers: its arguments are the same.)
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import os, random, resource, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile
import sculpt as S
from sculpt import T, BIN, RUNS, SEED, WANT, FAILS, BALL, STROKE, check, make, port, ops, raw, verts, bases, d, rd, ui_rows, logged, info, patched, same, moved
import wl_fake

ONLY = os.environ.get('SCULPT_ONLY', '')  # (the window cases with this in their name)


def finite_mesh(b):
    nv = counts(b)[0]
    v = struct.unpack_from(f'<{nv * 3}f', b, 12)
    return all(x == x and abs(x) != float('inf') for x in v)


def counts(b):
    return struct.unpack_from('<III', b)


def changed(a, base):
    """Other counts or other polygons: the topology changed."""
    return counts(a) != counts(base)


def valid(b, name='', closed=True):
    """Triangles of vertices that exist, each used, no edge on more than two."""
    nv, np, nl = counts(b)
    if nl != np * 3:
        return f'{name}: polygons that are not triangles ({np}, {nl})'
    off = struct.unpack_from(f'<{np + 1}I', b, 12 + nv * 12)
    if list(off) != [i * 3 for i in range(np + 1)]:
        return f'{name}: loop offsets'
    loops = struct.unpack_from(f'<{nl}I', b, 12 + nv * 12 + (np + 1) * 4)
    used = bytearray(nv)
    edges = {}
    for i in range(np):
        t = loops[i * 3:i * 3 + 3]
        if max(t) >= nv:
            return f'{name}: index {max(t)} of {nv}'
        if len(set(t)) != 3:
            return f'{name}: a triangle of two vertices'
        for k in range(3):
            used[t[k]] = 1
            a, c = t[k], t[(k + 1) % 3]
            e = (a, c) if a < c else (c, a)
            edges[e] = edges.get(e, 0) + 1
    if not all(used):
        return f'{name}: vertices no triangle uses'
    if closed and any(v != 2 for v in edges.values()):
        return f'{name}: edges without two triangles ({sum(1 for v in edges.values() if v != 2)})'
    return None


def dyn(base, name, pre, script, cmds, tag='', after='', after_c=()):
    """dyntopo on, then console lines, from one file, twice (one CPU): the two MESH
    chunks, as bytes. (script, after: unused, kept for the callers' shape.)"""
    out = []
    for k in ('o', 'q'):
        p = f'{T}/{k}{tag}.bee'
        if os.path.exists(p):
            os.remove(p)
        port('--op', f'file.open {base}', '--select', name, '--op', 'mode.sculpt', *ops(*pre), '--op', 'sculpt.dyntopo', *ops(*cmds), '--op', 'mode.object', *ops(*after_c), '--op', f'file.save {p}')
        out.append(raw(p, name) if os.path.exists(p) else b'')
    return out[0], out[1]


def equal(msg, a, c, base=None, closed=True):
    """a, c: the same stroke twice"""
    if not a or not c:
        check(False, f'{msg}: no mesh saved')
        return
    if a != c:
        n = sum(1 for x, y in zip(a, c) if x != y)
        check(False, f'{msg}: twice: {counts(a)} and {counts(c)}, {n} bytes differ of {len(a)}')
        return
    if base is not None and not changed(a, base):
        check(False, f'{msg}: the topology did not change {counts(a)}')
        return
    v = valid(c, msg, closed) or (None if finite_mesh(c) else f'{msg}: vertices not finite')
    check(v is None, v or f'{msg}: {counts(c)[0]} vertices, {counts(c)[1]} triangles, whole, {len(a)} bytes the same twice')


def st(b, s=STROKE):
    return '', f'sculpt S "{b}" {s}'


def s_same():
    print('-- each brush: whole triangles, the same twice, to the bit --')
    bases()
    base = f'{T}/ball.bee'
    b0 = raw(base, 'S')
    for b in S.BRUSHES:
        x, y = st(b)
        a, c = dyn(base, 'S', [], x, [y])
        if b in ('mask',):
            check(a == c and counts(c)[0] == counts(b0)[0] and counts(c)[1] == 2 * counts(b0)[1] and valid(c) is None, f'mask: no remeshing, all triangles (each quad two), the same twice ({counts(c)}, {counts(b0)} before)')
        elif b == 'grab':
            equal('grab: no remeshing, all triangles', a, c)
            check(counts(c)[0] == counts(b0)[0] and counts(c)[1] == 2 * counts(b0)[1], f'grab: the same vertices, each quad two triangles ({counts(c)}, {counts(b0)} before)')
        else:
            equal(b, a, c, b0)
    print('-- finer and coarser: the limits too --')
    x, y = st('draw')
    seen = []
    for k, n in (('sculpt.detail_finer', 1), ('sculpt.detail_finer', 3), ('sculpt.detail_finer', 12), ('sculpt.detail_coarser', 1), ('sculpt.detail_coarser', 3), ('sculpt.detail_coarser', 40)):
        a, c = dyn(base, 'S', [k] * n, x, [y])
        equal(f'{k} x {n}', a, c, b0)
        seen.append(counts(c)[1])
    check(seen[0] < seen[1] < seen[2], f'finer: more triangles ({seen[:3]})')
    check(max(seen[3:]) < seen[0], f'coarser: no finer than the first ({seen[3:]})')
    a, c = dyn(base, 'S', ['sculpt.radius_up'] * 3, x, [y])
    a2, c2 = dyn(base, 'S', ['sculpt.radius_down'] * 3, x, [y])
    check(a == c and a2 == c2 and counts(a)[1] > counts(a2)[1], f'the detail is in pixels: the same world radius, more pixels, more triangles ({counts(a)[1]}, {counts(a2)[1]})')
    print('-- symmetry, falloff, several strokes, the mask --')
    for sy in ('x', 'z', 'xyz'):
        z = STROKE.replace('-0.5 2 1 0.5', '0.2 2 1 0.5')
        x2, y2 = st('draw', z)
        a, c = dyn(base, 'S', [f'sculpt.symmetry {sy}'], x2, [y2])
        equal(f'symmetry {sy}', a, c, b0)
    x2, y2 = st('snake hook', '0 2.9 0.3 1.5 4.5 2 0.8 1')
    a, c = dyn(base, 'S', ['sculpt.detail_coarser'] * 8, x2 + x2, [y2, y2])
    equal('a hook pulled far: long edges in a stroke', a, c, b0)
    x2, y2 = st('snake hook', '-0.2 2.8 0.3 0.4 2.8 0.4 0.5 0.6')
    a, c = dyn(base, 'S', ['sculpt.symmetry x'], x2, [y2])
    equal('snake hook, mirrored', a, c, b0)
    a, c = dyn(base, 'S', ['sculpt.falloff constant'], x, [y])
    equal('a constant falloff', a, c, b0)
    x3, y3 = st('clay strips', '-0.3 2.2 0.9 0.6 2.4 0.7 0.5 0.5')
    x4, y4 = st('smooth', '-0.3 2.2 0.9 0.6 2.4 0.7 0.5 1')
    a, c = dyn(base, 'S', [], x + x3 + x4 + x, [y, y3, y4, y])
    equal('four strokes on one another', a, c, b0)
    xm, ym = st('mask', '0 2 1 0.1 2 1 0.5 0.8')
    a, c = dyn(base, 'S', [], xm + x + 'op("sculpt.mask_invert")\n' + x3, [ym, y, 'sculpt.mask_invert', y3])
    equal('a mask across commits, a remesh, an inversion', a, c, b0)
    a2, c2 = dyn(base, 'S', [], x + 'op("sculpt.mask_invert")\n' + x3, [y, 'sculpt.mask_invert', y3])
    check(a != a2, 'the mask changed what the strokes did')
    a, c = dyn(base, 'S', [], x + x3, [y, y3], after_c=['mode.sculpt', y])
    equal('out of the mode and back: it stays on', a, c, b0)
    print('-- other meshes, other matrices --')
    mix = f'{T}/mix.bee'
    for name, s, b in (('C', '2.4 1.9 0.5 1.6 2 0.4 0.6 0.7', 'draw'), ('C', '2 2 0 2.3 2 0 0.8 0.6', 'smooth'), ('B', '-3 2 2 -3 2.1 2 1.5 1', 'draw'), ('B', '-3 1 2 -2.5 1 2 2 0.5', 'pinch')):
        a, c = dyn(mix, name, [], '', [f'sculpt {name} "{b}" {s}'])
        equal(f'{name}: {b}: n-gons, big triangles', a, c, raw(mix, name))
    x0, y0, z0 = next(o for o in beefile.objects(mix) if o['name'] == 'S')['loc']
    p = (x0 + 0.1, y0 + 0.5, z0 + 1.4, x0 + 0.4, y0 + 0.6, z0 + 1.2, 0.6, 0.6)
    a, c = dyn(mix, 'S', [], f'sculpt("S", "draw", {", ".join(map(repr, p))})\n', ['sculpt S "draw" ' + ' '.join(map(repr, p))])
    equal('moved, turned, scaled', a, c, raw(mix, 'S'))
    print('-- a long session --')
    rng = random.Random(SEED)
    br = ['draw', 'clay strips', 'crease', 'inflate', 'snake hook', 'smooth', 'flatten', 'pinch', 'layer', 'grab']
    xs, ys = '', []
    for _ in range(40):
        q = [rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(0.1, 0.9), rng.uniform(-0.9, 0.9)]
        s = ' '.join(f'{v:.4f}' for v in q)
        x5, y5 = st(rng.choice(br), s)
        xs += x5
        ys.append(y5)
    a, c = dyn(base, 'S', [], xs, ys)
    equal('forty random strokes', a, c, b0)


def s_threads():
    print('-- every core: a mesh that holds together --')
    bases()
    base = f'{T}/ball.bee'
    q = f'{T}/qt.bee'
    x, y = st('draw')
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', *ops(y, y.replace('"draw"', '"smooth"')), '--op', 'mode.object', '--op', f'file.save {q}', one=False)
    v = valid(raw(q, 'S'), 'every core')
    check(v is None, v or f'every core: {counts(raw(q, "S"))}')


def s_files():
    print('-- .bee: saved, opened, saved: byte for byte --')
    bases()
    base = f'{T}/ball.bee'
    x, y = st('draw')
    x2, y2 = st('crease', '-0.3 2.2 0.9 0.6 2.4 0.7 0.5 0.5')
    o, q = f'{T}/o.bee', f'{T}/q.bee'
    a, c = dyn(base, 'S', [], x, [y])
    equal('the stroke', a, c, raw(base, 'S'))
    q2 = f'{T}/q2.bee'
    port('--op', f'file.open {q}', '--op', f'file.save {q2}')
    check(raw(q2, 'S') == raw(q, 'S'), 'opened and saved again: the same mesh')
    first = c
    fo, fq = f'{T}/fo.bee', f'{T}/fq.bee'
    shutil.copy(o, fo)
    shutil.copy(q, fq)
    a, c = dyn(fq, 'S', [], x2, [y2], tag='5')
    a3, c3 = dyn(fo, 'S', [], x2, [y2], tag='6')
    check(a == c and a == a3 and a == c3 and a != first, f'dyntopo goes on in the file saved and in its copy, with one result ({counts(a)})')
    tags = lambda p: sorted(t for t, _ in beefile.chunks(p))
    check(b'MUVS' in tags(fq) and b'MRES' in tags(fq), 'the chunks are there')
    print('-- saved in the mode, between strokes --')
    p = f'{T}/m1.bee'
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', y, '--op', f'file.save {p}', '--op', 'mode.object', '--op', f'file.save {T}/m2.bee')
    check(raw(p, 'S') == raw(f'{T}/m2.bee', 'S') and raw(p, 'S') == first, 'what a save in the mode writes is the stroke')
    print('-- autosave in the mode --')
    auto = f'{T}/auto'
    os.makedirs(auto, exist_ok=True)
    port('--autosave-dir', auto, '--autosave-every', '1', '--op', f'file.open {base}', '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', y, '--wait', '300', ok=False)
    fs = [f for f in os.listdir(auto) if f.endswith('.bee')]
    if fs:
        got = raw(os.path.join(auto, sorted(fs)[-1]), 'S')
        v = valid(got, 'the autosave')
        check(v is None and got == first, f'the autosave holds the stroke ({counts(got)})')
    else:
        check(False, 'no autosave was written')


def s_attrs():
    print('-- what the mesh loses with its topology --')
    bases()
    B = 'delete("Cube")\nadd("sphere", "S", 0, 2, 0)\n'
    p = f'{T}/ev.bee'
    make(B + f'seams("S", "sharp")\nprint(unwrap("S"))\nop("file.save", "{p}")\n')
    check(b'MUVS' in [t for t, _ in beefile.chunks(p)] and len(beefile.chunk(p, b'MUVS')) > 100, 'the sphere has UVs')
    s = '-0.3 2.7 0.8 0.2 2.8 0.6 0.5 0.6'
    x, y = '', f'sculpt S "draw" {s}'
    a, c = dyn(p, 'S', [], x, [y])
    equal('UVs and seams: the stroke', a, c, raw(p, 'S'))
    for tag in (b'MUVS',):
        o = beefile.chunk(f'{T}/o.bee', tag)
        q = beefile.chunk(f'{T}/q.bee', tag)
        check(o == q and len(q or b'') < 8, f'{tag.decode()}: gone ({len(q or b"")} bytes, twice)')
    print('-- vertex colours --')
    vc = f'{T}/vc.bee'
    make(f'op("file.open", "{p}")\nvpaint("S", 1, 2, 3, 1, 200, 30, 10)\nop("file.save", "{vc}")\n')
    check(len(beefile.chunk(vc, b'MVCL') or b'') > 100, 'the colours are there')
    a, c = dyn(vc, 'S', [], x, [y])
    equal('coloured: the stroke', a, c, raw(vc, 'S'))
    o = beefile.chunk(f'{T}/o.bee', b'MVCL')
    q = beefile.chunk(f'{T}/q.bee', b'MVCL')
    check(o == q and len(q or b'') < 8, f'the colours go ({len(q or b"")} bytes, twice)')
    port('--op', f'file.open {vc}', '--op', f'file.save {T}/v0.bee', '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', y, '--op', 'mode.object', '--op', 'edit.undo', '--op', f'file.save {T}/vu.bee')
    check(beefile.chunk(f'{T}/vu.bee', b'MVCL') == beefile.chunk(f'{T}/v0.bee', b'MVCL') and len(beefile.chunk(f'{T}/vu.bee', b'MVCL')) > 100, 'undone: they are back')
    print('-- shape keys --')
    K = f'op("file.open", "{p}")\nselect("S")\ni = 0\nwhile i < 200 {{ vmove("S", i, vpos("S", i, 0), vpos("S", i, 1) + 0.5, vpos("S", i, 2))\n i = i + 1 }}\nop("shape.add", "Up S")\nop("shape.set", "Up 0.5 S")\n'
    o0 = f'{T}/sko.bee'
    make(K + f'op("file.save", "{o0}")\n')
    check(len(beefile.chunk(o0, b'MSHK') or b'') > 100, 'the keys are there')
    a, c = dyn(o0, 'S', [], x, [y])
    equal('shape keys: the stroke', a, c, raw(o0, 'S'))
    o = beefile.chunk(f'{T}/o.bee', b'MSHK')
    q = beefile.chunk(f'{T}/q.bee', b'MSHK')
    check(len(o or b'') < 16 and len(q or b'') < 16, f'the keys go with the old mesh ({len(q or b"")} bytes, twice)')
    port('--op', f'file.open {o0}', *d('k0'), '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', y, '--op', 'mode.object', *d('k1'), '--op', 'edit.undo', '--op', f'file.save {T}/k2.bee', *d('k2'))
    check(len(rd('k1')) != len(rd('k0')), 'what shows has the new topology')
    check(rd('k2') == rd('k0') and beefile.chunk(f'{T}/k2.bee', b'MSHK')[4:] == beefile.chunk(o0, b'MSHK')[4:], 'undone: the keys and what showed are back')
    print('-- armature weights --')
    R = f'''op("file.open", "{p}")
a = armature("Rig")
op("arm.bone", "Upper Bone 0 1 0 0.2 3.2 0.1")
op("arm.parent", "S Rig")
select("Rig")
op("arm.pose", "Upper rot 20 10 30")
select("S")
'''
    o1 = f'{T}/skin.bee'
    make(R + f'op("file.save", "{o1}")\n')
    check(len(beefile.chunk(o1, b'MWGT') or b'') > 100, 'the weights are there')
    a, c = dyn(o1, 'S', [], x, [y])
    equal('skinned: the stroke', a, c, raw(o1, 'S'))
    o = beefile.chunk(f'{T}/o.bee', b'MWGT')
    q = beefile.chunk(f'{T}/q.bee', b'MWGT')
    check(len(o or b'') < 16 and len(q or b'') < 16, f'the weights go too ({len(q or b"")} bytes, twice)')
    port('--op', f'file.open {T}/q.bee', *d('w0'))
    w0 = rd('w0')
    check(len(w0) == counts(c)[0] and all(x == x and abs(x) != float('inf') for v in w0 for x in v), f'skinned, weights gone: what shows is the new mesh, finite ({len(w0)} vertices)')
    print('-- a stack above --')
    for mod in ('subsurf', 'mirror', 'solidify'):
        o, q = f'{T}/om.bee', f'{T}/qm.bee'
        port('--op', f'file.open {p}', '--select', 'S', '--op', f'object.modifier_add {mod}', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', y, '--op', 'mode.object', '--op', f'file.save {o}')
        port('--op', f'file.open {p}', '--select', 'S', '--op', f'object.modifier_add {mod}', *d('s0'), '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', y, *d('s1'), '--op', 'mode.object', '--op', f'file.save {q}', *d('s2'), '--op', 'edit.undo', *d('s3'))
        check(raw(o, 'S') == raw(q, 'S') and changed(raw(q, 'S'), raw(p, 'S')) and valid(raw(q, 'S')) is None, f'{mod}: the base remeshed, whole, the same twice')
        check(rd('s1') == rd('s2') and len(rd('s2')) != len(rd('s0')), f'{mod}: follows at the stroke\'s end, in the mode')
        check(rd('s3') == rd('s0'), f'{mod}: undo brings back what showed')


def steps():
    return [x[1] for x in ui_rows() if x[0] == 'step']


def s_undo():
    print('-- undo: a stroke is one step, with values --')
    bases()
    base = f'{T}/ball.bee'
    fr = ['--op', f'file.open {base}', '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo']
    a, b = st('draw')[1], st('smooth', '-0.3 2.2 0.9 0.6 2.4 0.7 0.5 1')[1]
    port(*fr, '--op', a, '--op', b, '--op', 'edit.undo_history')
    check(steps() == ['Original', 'Sculpt', 'Sculpt'], f'two strokes: two steps ({steps()})')
    rng = random.Random(SEED)
    n = 24
    args = list(fr) + ['--op', f'file.save {T}/s0.bee']
    for k in range(n):
        q = [rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(0.1, 0.9), rng.uniform(-0.9, 0.9)]
        args += ['--op', f'sculpt S "{rng.choice(["draw", "smooth", "pinch", "clay strips"])}" ' + ' '.join(f'{v:.4f}' for v in q), '--op', f'file.save {T}/s{k + 1}.bee']
    for k in range(n):
        args += ['--op', 'edit.undo', '--op', f'file.save {T}/u{n - k - 1}.bee']
    for k in range(n):
        args += ['--op', 'edit.redo', '--op', f'file.save {T}/r{k + 1}.bee']
    args += ['--op', f'sculpt S "draw" 0 2 1 0.1 2 1 0.4 0.5', '--op', f'file.save {T}/e.bee', '--op', 'edit.undo', '--op', f'file.save {T}/e2.bee', '--op', 'edit.redo', '--op', f'file.save {T}/e3.bee']
    port(*args)
    sv = [raw(f'{T}/s{k}.bee', 'S') for k in range(n + 1)]
    check(all(sv[k] != sv[k + 1] for k in range(n)), f'{n} strokes each changed it ({counts(sv[0])} -> {counts(sv[-1])})')
    check(all(raw(f'{T}/u{k}.bee', 'S') == sv[k] for k in range(n)), f'{n} undos: each mesh back, byte for byte')
    check(all(raw(f'{T}/r{k + 1}.bee', 'S') == sv[k + 1] for k in range(n)), f'{n} redos: each again')
    check(raw(f'{T}/e2.bee', 'S') == sv[n] and raw(f'{T}/e3.bee', 'S') == raw(f'{T}/e.bee', 'S') and raw(f'{T}/e.bee', 'S') != sv[n], 'and strokes go on from there')
    print('-- the history list: a jump over strokes --')
    port(*fr, '--op', f'file.save {T}/h0.bee', '--op', a, '--op', f'file.save {T}/h1.bee', '--op', b, '--op', 'edit.undo_history', '--click-label', 'step:Original', '--op', f'file.save {T}/h2.bee', '--click-label', 'step:Sculpt', '--op', f'file.save {T}/h3.bee')
    check(raw(f'{T}/h2.bee', 'S') == raw(f'{T}/h0.bee', 'S') and raw(f'{T}/h3.bee', 'S') == raw(f'{T}/h1.bee', 'S'), 'to the start, to the first stroke')
    print('-- deltas and dyntopo strokes in one history --')
    plain = ['--op', f'file.open {base}', '--select', 'S', '--op', 'mode.sculpt']
    c1 = st('draw', '0.5 2.5 0.5 0.7 2.6 0.3 0.4 0.5')[1]
    port(*plain, '--op', a, '--op', f'file.save {T}/d1.bee', '--op', 'sculpt.dyntopo', '--op', b, '--op', f'file.save {T}/d2.bee', '--op', 'sculpt.dyntopo', '--op', c1, '--op', f'file.save {T}/d3.bee',
         '--op', 'edit.undo', '--op', f'file.save {T}/d4.bee', '--op', 'edit.undo', '--op', f'file.save {T}/d5.bee', '--op', 'edit.undo', '--op', f'file.save {T}/d6.bee',
         '--op', 'edit.redo', '--op', 'edit.redo', '--op', 'edit.redo', '--op', f'file.save {T}/d7.bee')
    g = lambda k: raw(f'{T}/d{k}.bee', 'S')
    check(g(1) != g(2) != g(3), 'a plain stroke, a dyntopo one, a plain one')
    check(g(4) == g(2), 'undo: the plain stroke on the dyntopo mesh')
    check(g(5) == g(1), 'undo: the dyntopo stroke')
    check(g(6) == raw(base, 'S'), 'undo: the first, under a working copy or not')
    check(g(7) == g(3), 'and all of it again')
    print('-- undone under the working copy, then a stroke --')
    far = '0 2 -1 0.2 2.1 -0.9 0.3 0.5'
    port(*plain, '--op', a, '--op', 'sculpt.dyntopo', '--op', 'edit.undo', '--op', f'sculpt S "draw" {far}', '--op', 'mode.object', '--op', f'file.save {T}/w1.bee')
    near = lambda p: {v for v in verts(p, 'S') if v[2] > 0}
    check(near(f'{T}/w1.bee') <= near(base) and len(near(f'{T}/w1.bee')) > 10000, 'a plain stroke undone with dyntopo on stays undone')
    print('-- across the modes --')
    port(*fr, '--op', a, '--op', 'mode.object', '--op', f'file.save {T}/m1.bee', '--op', 'edit.undo', '--op', f'file.save {T}/m2.bee', '--select', 'S', '--op', 'mode.edit', '--op', 'edit.redo', '--op', f'file.save {T}/m3.bee', '--op', 'mode.object', '--op', 'mode.sculpt', '--op', 'edit.undo', '--op', f'file.save {T}/m4.bee')
    m1 = raw(f'{T}/m1.bee', 'S')
    check(changed(m1, raw(base, 'S')), 'leaving the mode keeps the stroke')
    check(raw(f'{T}/m2.bee', 'S') == raw(base, 'S'), 'undone in object mode')
    check(raw(f'{T}/m3.bee', 'S') == m1, 'redone in edit mode')
    check(raw(f'{T}/m4.bee', 'S') == raw(base, 'S'), 'undone in sculpt mode again')
    print('-- an edit between strokes --')
    port(*fr, '--op', a, '--op', f'file.save {T}/x1.bee', '--op', 'mode.edit', '--op', 'mesh.subdivide', '--op', 'mode.object', '--op', f'file.save {T}/x2.bee', '--op', 'mode.sculpt', '--op', b, '--op', f'file.save {T}/x3.bee', '--op', 'edit.undo', '--op', f'file.save {T}/x4.bee', '--op', 'edit.undo', '--op', f'file.save {T}/x5.bee', '--op', 'edit.undo', '--op', f'file.save {T}/x6.bee')
    h = lambda k: raw(f'{T}/x{k}.bee', 'S')
    check(counts(h(2))[0] > counts(h(1))[0] and h(3) != h(2), 'subdivided, sculpted')
    check(h(4) == h(2) and h(5) == h(1) and h(6) == raw(base, 'S'), 'each undone, with values')
    print('-- a mesh others show, a primitive --')
    port('--op', 'add cube', '--op', 'mode.object', '--select', 'Cube.001', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', 'sculpt Cube.001 "draw" 0 1 1 0.2 1 1 1.5 1', '--op', 'mode.object', '--op', f'file.save {T}/c1.bee', '--op', 'add cube', '--op', f'file.save {T}/c2.bee', '--op', 'edit.undo', '--op', 'edit.undo', '--op', f'file.save {T}/c3.bee')
    c = beefile.meshes(f'{T}/c2.bee')
    objs = {o['name']: o['mesh'] for o in beefile.objects(f'{T}/c2.bee')}
    check(len(c[objs['Cube']][0]) == 8 and len(c[objs['Cube.002']][0]) == 8 and len(c[objs['Cube.001']][1]) > 12, 'one cube remeshed, the others and a new one cubes')
    check(raw(f'{T}/c3.bee', 'Cube.001') == raw(f'{T}/c3.bee', 'Cube'), 'undone: a cube again')
    bases()
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'object.duplicate', '--op', f'file.save {T}/dup.bee')
    dup = [o['name'] for o in beefile.objects(f'{T}/dup.bee') if o['name'] not in ('S', 'Camera', 'Light')][0]
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'object.duplicate', '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', a, '--op', 'mode.object', '--op', f'file.save {T}/l1.bee', '--op', 'edit.undo', '--op', f'file.save {T}/l2.bee')
    check(changed(raw(f'{T}/l1.bee', 'S'), raw(base, 'S')) and raw(f'{T}/l1.bee', dup) == raw(base, 'S'), 'a duplicate keeps its mesh')
    check(raw(f'{T}/l2.bee', 'S') == raw(base, 'S'), 'undone, they are one shape again')
    print('-- the toggle is no step, the detail neither --')
    port(*fr, '--op', 'sculpt.detail_finer', '--op', 'sculpt.dyntopo', '--op', 'sculpt.dyntopo', '--op', 'edit.undo_history')
    check(steps() == ['Original'], f'nothing to undo ({steps()})')
    print('-- memory: the history holds at most its budget --')
    big = f'{T}/big.bee'
    make(BALL % 5 + f'op("file.save", "{big}")\n')
    n = 24
    args = ['--op', f'file.open {big}', '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo']
    for k in range(n):
        args += ['--op', f'sculpt S "draw" {-0.5 + k * 0.05} 2 1 {-0.4 + k * 0.05} 2.1 0.9 0.2 0.1']
    args += ['--op', f'file.save {T}/g.bee']
    cmd = S.ONE + [BIN, '--shot', f'{T}/u.ppm', *args]
    before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    r = subprocess.run(cmd, capture_output=True, env=S.ENV)
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    mb = max(rss, before) // 1024
    size = os.path.getsize(big) >> 20
    check(r.returncode == 0 and rss > before and mb < 512 + 12 * size + 1500, f'{n} strokes on {counts(raw(big, "S"))[1]} triangles ({size} MB a mesh): at most {mb} MB')


def s_midstroke():
    print('-- things that happen during a stroke --')
    M = ['--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', 'sculpt.detail_finer']
    P = ['--move', '620,330', '--press', '620,330', '--move', '630,335', '--move', '640,340']
    sv = lambda k: ['--op', f'file.save {T}/k{k}.bee']
    g = lambda k: raw(f'{T}/k{k}.bee', 'Cube')
    port('--op', 'file.new', *M, *sv(0), *P, '--key', 'ctrl+z', *sv(1), '--release', '640,340', *sv(2))
    check(g(1) == g(0) and g(2) == g(0), 'Ctrl+Z in a stroke: the stroke so far is a step, and it goes')
    port(*M, *sv(0), *P, '--op', 'mode.object', *sv(3), '--release', '640,340', *sv(4), '--op', 'edit.undo', *sv(5))
    check(changed(g(3), g(0)), f'left in a stroke: what it did stays ({counts(g(0))} -> {counts(g(3))})')
    check(g(4) == g(3), 'the release does nothing more')
    check(g(5) == g(0), 'and it is one step')
    port(*M, *sv(0), *P, '--key', 'esc', '--move', '650,345', '--release', '650,345', *sv(6), '--op', 'edit.undo', *sv(7))
    check(changed(g(6), g(0)) and g(7) == g(0), 'Esc changes nothing: one step')
    r = port(*M, *P, *sv(8), '--release', '640,340', '--op', 'mode.object', *sv(9), ok=False)
    check(r.returncode == 0 and g(8) == g(0) and changed(g(9), g(0)), 'saved in a stroke: the mesh before it (the copy is not done)')
    r = port(*M, *P, '--op', 'sculpt.dyntopo', '--release', '640,340', *sv(10), ok=False)
    check(r.returncode == 0 and not any('dyntopo off' in x for x in logged()) and changed(g(10), g(0)), 'the toggle does nothing in a stroke')
    print('-- the leaves in a stroke: lists, boxes, owners --')
    bases()
    ball = f'{T}/ball.bee'
    wide = ['--key', '26', '--key', '26', '--key', '26', '--key', '26', '--key', '26', '--move', '596,275', '--press', '596,275', *[x for k in range(1, 9) for x in ('--move', f'{596 + k * 5},{275 + k * 2}')], '--op', 'sculpt.check']
    port('--op', f'file.open {ball}', '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', 'sculpt.detail_finer', *wide, '--release', '640,290')
    got = [x for x in logged() if 'sculpt.check' in x and x.startswith('  ')]
    check(len(got) == 1 and 'check ok' in got[0] and '63488 triangles' not in got[0], f'all in order {got}')
    for name, extra in (('a new scene', ['--op', 'file.new', '--release', '640,340']), ('the object deleted', ['--op', 'delete Cube', '--move', '650,345', '--release', '650,345']), ('out and back in', ['--op', 'object.sculpt_mode', '--op', 'object.sculpt_mode', '--move', '650,345', '--release', '650,345']), ('off the window', ['--move', '5000,5000', '--move', '-300,-40', '--move', '640,340', '--release', '640,340'])):
        r = port(*M, *P, *extra, ok=False)
        check(r.returncode == 0, f'{name} in a stroke {r.stderr[-200:]}')


def drag(x0, y0, x1, y1, steps=16):
    """A pointer stroke on the headless window: pressed, moved in steps, released."""
    a = ['--move', f'{x0},{y0}', '--press', f'{x0},{y0}']
    for i in range(1, steps + 1):
        a += ['--move', f'{x0 + (x1 - x0) * i // steps},{y0 + (y1 - y0) * i // steps}']
    return a + ['--release', f'{x1},{y1}']


# the viewport filling the window, looking along -Z, in sculpt mode
FRONT = ['--select', 'S', '--move', '640,300', '--key', 'ctrl+space', '--key', 'kp1', '--keydown', 'ctrl+tab', '--keyup', 'ctrl+tab']


def mouse(base, steps, out):
    """Mouse and keys on the headless window: the MESH chunk it leaves."""
    if os.path.exists(out):
        os.remove(out)
    port('--op', f'file.open {base}', *FRONT, *steps, '--op', 'mode.object', '--op', f'file.save {out}')
    return raw(out, 'S') if os.path.exists(out) else b''


def wball():
    wb = f'{T}/wball.bee'
    if not os.path.exists(wb):
        make(BALL % 3 + f'scale("S", 3.5, 3.5, 3.5)\nselect("S")\nop("file.save", "{wb}")\n')
    return wb


def s_window():
    print('-- the window (headless): the pointer and the keys, twice --')
    wb = wball()
    b0 = raw(wb, 'S')
    P = (560, 250, 720, 290)

    def key(k):
        return ['--key', k]

    def stroke(p=P, steps=16, mods=''):
        return (['--mods', mods] if mods else []) + drag(*p, steps=steps) + (['--mods', 'none'] if mods else [])

    on = key('ctrl+d')
    finer = key('ctrl+26')    # Ctrl+[
    coarser = key('ctrl+27')  # Ctrl+]
    undo, redo = key('ctrl+z'), key('ctrl+shift+z')
    cases = [
        ('a stroke', on + stroke()),
        ('Ctrl+[ five times', on + finer * 5 + stroke()),
        ('Ctrl+] five times', on + coarser * 5 + stroke()),
        ('Ctrl+D off again', on + on + stroke()),
        ('Ctrl inverts', on + stroke(mods='ctrl')),
        ('Shift smooths', on + stroke(mods='shift')),
        ('three strokes', on + stroke() + stroke((600, 300, 500, 200)) + stroke((700, 200, 720, 400))),
        ('symmetry X', key('shift+x') + on + stroke()),
        ('undone, a new one', on + stroke() + undo + stroke((600, 300, 500, 200))),
        ('undone, redone', on + stroke() + undo + redo),
    ]
    if ONLY in 'the copy':
        print('-- a plain stroke undone with dyntopo on --')
        q = mouse(wb, stroke() + on + undo + stroke((600, 420, 700, 430)), f'{T}/pu.bee')
        top = lambda p: {v for v in verts(p, 'S') if v[1] > 0.5}
        check(q and top(f'{T}/pu.bee') <= top(wb) and len(top(wb)) > 3000, f'the upper half is the file\'s ({len(top(wb))} vertices)')
    res = {}
    for name, st_ in cases:
        if ONLY not in name:
            continue
        a = mouse(wb, st_, f'{T}/ow.bee')
        c = mouse(wb, st_, f'{T}/pw.bee')
        res[name] = c
        if name == 'Ctrl+D off again':
            check(a == c and counts(a) == counts(b0) and a != b0, f'{name}: {counts(a)}, the same twice, no remeshing')
            continue
        equal(name, a, c, b0)
    if 'a stroke' in res and 'Ctrl+[ five times' in res and 'Ctrl+] five times' in res:
        n = [counts(res[k])[1] for k in ('Ctrl+] five times', 'a stroke', 'Ctrl+[ five times')]
        check(n[0] < n[1] < n[2], f'coarser, plain, finer: more triangles each ({n})')
    if 'undone, redone' in res and 'a stroke' in res:
        check(res['undone, redone'] == res['a stroke'], 'undone, redone: the stroke again')


def s_ui():
    print('-- the tools, the bar, the operators --')
    port('--op', 'mode.sculpt')
    rows = ui_rows()
    state = {x[1]: x[3] for x in rows}
    check(state.get('Dynamic Topology') == 'on', 'dynamic topology is not greyed in the mode')
    check('Detail' not in [x[1] for x in rows], 'dyntopo off: no Detail field')
    port('--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--move', '640,300', '--expect-field', 'Detail=10', '--key', 'ctrl+26', '--expect-field', 'Detail=8', '--key', 'ctrl+27', '--key', 'ctrl+27', '--expect-field', 'Detail=12.5')
    check('Detail' in [x[1] for x in ui_rows()], 'dyntopo on: the Detail field')
    check('dyntopo 12 px' in [x[1] for x in ui_rows()], 'and the line over it says what it is')
    check(any('dyntopo on, detail 10 px' in x for x in logged()), 'it says so')
    r = port('--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', 'sculpt.dyntopo', ok=False)
    check(any('dyntopo off' in x for x in logged()), 'and off')
    r = port('--op', 'sculpt.dyntopo', '--op', 'sculpt.detail_finer', '--op', 'mode.sculpt', '--move', '640,300', '--expect-field', 'Radius=50', ok=False)
    check('Detail' not in [x[1] for x in ui_rows()], 'outside the mode the operators do nothing')
    port('--op', 'sculpt.dyntopo', '--dump-log', f'{T}/l.txt')
    bad = [x for x in ui_rows() if x[1] == 'Dynamic Topology']
    many = []
    for _ in range(30):
        many += ['--op', 'sculpt.detail_finer']
    port('--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--move', '640,300', *many, '--expect-field', 'Detail=2')
    many = [x.replace('finer', 'coarser') for x in many]
    port('--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--move', '640,300', *many, '--expect-field', 'Detail=64')
    print('-- the detail field reaches past the operators --')
    r = port('--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--move', '640,300', '--dbl-label', 'number:Detail', '--type', '150', '--key', 'enter', '--expect-field', 'Detail=150', ok=False)
    check(r.returncode == 0, f'typed: 150 {r.stderr[-200:]}')
    r = port('--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--move', '640,300', '--dbl-label', 'number:Detail', '--type', '0/0', '--key', 'enter', '--expect-field', 'Detail=10', ok=False)
    check(r.returncode == 0, f'typed: a NaN changes nothing {r.stderr[-200:]}')
    print('-- the look: a stroke shows --')
    wb = f'{T}/lb.bee'
    make(BALL % 2 + f'scale("S", 3.5, 3.5, 3.5)\nselect("S")\nop("file.save", "{wb}")\n')
    shots = os.environ.get('DYN_SHOTS', T)
    r = port('--op', f'file.open {wb}', *FRONT, ok=False)
    p0 = open(f'{T}/u.ppm', 'rb').read() if os.path.exists(f'{T}/u.ppm') else b''
    r2 = port('--op', f'file.open {wb}', *FRONT, '--key', 'ctrl+d', *drag(560, 250, 720, 290), '--op', f'file.save {T}/pl.bee', ok=False)
    p1 = open(f'{T}/u.ppm', 'rb').read() if os.path.exists(f'{T}/u.ppm') else b''
    check(r.returncode == 0 and r2.returncode == 0 and p0 and p1 and p0 != p1, 'the stroke shows in the picture')
    check(os.path.exists(f'{T}/pl.bee') and changed(raw(f'{T}/pl.bee', 'S'), raw(wb, 'S')), 'and in the mesh saved')
    if shots != T:
        open(f'{shots}/dyn_0.ppm', 'wb').write(p0)
        open(f'{shots}/dyn_1.ppm', 'wb').write(p1)
    print('-- idle (the fake compositor) --')
    f = wl_fake.Fake(BIN, size=(1280, 800), env={'HOME': tempfile.mkdtemp(prefix='beedynh-', dir='/tmp')}, args=(wb,))
    f.until(lambda: f.frames > 0 and f.keyboard is not None and f.pointer is not None, 20)
    f.pump(1.0)
    f.enter(640, 330)
    f.key(15, 4)      # Ctrl+Tab: sculpt mode
    f.key(32, 4)      # Ctrl+D: dyntopo
    f.pump(0.2)
    f.motion(620, 330)
    f.button(0x110, True)
    for k in range(1, 5):
        f.motion(620 + k * 10, 330 + k * 5)
        f.pump(0.3)
    f.button(0x110, False)
    f.pump(5.0)           # (the toasts time out by themselves: a frame each)
    n = f.frames
    f.pump(1.5)
    check(f.proc.poll() is None and f.frames == n, f'dyntopo on, nothing moves, nothing is drawn ({f.frames - n} frames)')
    f.close()


def cubeish(base, name, vs, polys):
    p = f'{T}/{name}.bee'
    patched(base, p, 'Cube', vs, polys)
    return p


def s_robust():
    print('-- the small and the strange --')
    base = f'{T}/plain.bee'
    make(f'select("Cube")\nop("file.save", "{base}")\n')
    tri = cubeish(base, 'tri', [(-1, 0, 0), (1, 0, 0), (0, 2, 0)], [[0, 1, 2]])
    S1 = 'sculpt("Cube", "draw", 0, 1.5, 0, 0.2, 1.6, 0, 2, 0.5)\n'
    S2 = 'sculpt Cube "draw" 0 1.5 0 0.2 1.6 0 2 0.5'
    a, c = dyn(tri, 'Cube', ['sculpt.detail_finer'] * 12, S1, [S2])
    check(a == c and counts(c)[:2] == (3, 1), f'a single triangle: a border, nothing splits ({counts(c)})')
    two = cubeish(base, 'two', [(-2, 0, 0), (2, 0, 0), (0, 0.5, 0), (0, -0.5, 0.1)], [[0, 1, 2], [1, 0, 3]])
    a, c = dyn(two, 'Cube', ['sculpt.detail_finer'] * 12, 'sculpt("Cube", "draw", 0, 0.1, 0, 0.1, 0.1, 0, 1, 0.1)\n', ['sculpt Cube "draw" 0 0.1 0 0.1 0.1 0 1 0.1'])
    equal('two triangles: the shared edge splits', a, c, raw(two, 'Cube'), closed=False)
    fan = cubeish(base, 'fan', [(0, 0, 0), (2, 0, 0), (1, 2, 0), (1, -2, 0), (1, 0, 2)], [[0, 1, 2], [1, 0, 3], [0, 1, 4]])
    a, c = dyn(fan, 'Cube', ['sculpt.detail_finer'] * 12, 'sculpt("Cube", "draw", 1, 0.5, 0, 1, 0.6, 0.1, 3, 0.5)\n', ['sculpt Cube "draw" 1 0.5 0 1 0.6 0.1 3 0.5'])
    check(a == c and counts(c)[1] >= 3, f'three triangles on one edge: it stays ({counts(c)})')
    loose = cubeish(base, 'loose', [(-1, 0, 0), (1, 0, 0), (0, 2, 0), (40, 40, 40), (0, -2, 0.1)], [[0, 1, 2], [1, 0, 4]])
    a, c = dyn(loose, 'Cube', [], S1, [S2])
    check(a == c and counts(c)[0] <= 4 + 40, f'a loose vertex goes with the commit ({counts(c)})')
    twice = cubeish(base, 'twice', [(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)], [[0, 1, 2], [0, 1, 2], [0, 0, 1], [0, 2, 3], [0, 3, 1], [1, 3, 2]])
    a, c = dyn(twice, 'Cube', ['sculpt.detail_finer'] * 12, 'sculpt("Cube", "draw", 0.3, 0.3, 0.3, 0.4, 0.3, 0.3, 2, 0.5)\n', ['sculpt Cube "draw" 0.3 0.3 0.3 0.4 0.3 0.3 2 0.5'])
    check(a == c, f'the same triangle twice, a degenerate one ({counts(c)})')
    plane = f'{T}/plane.bee'
    make(f'delete("Cube")\nadd("plane", "Cube")\nmodifier("Cube", "subsurf")\nmodset("Cube", 0, "levels", 3)\nmodapply("Cube", 0)\nop("file.save", "{plane}")\n')
    a, c = dyn(plane, 'Cube', [], 'sculpt("Cube", "draw", -0.3, 0.1, 0.1, 0.3, 0.1, 0.1, 0.4, 0.5)\n', ['sculpt Cube "draw" -0.3 0.1 0.1 0.3 0.1 0.1 0.4 0.5'])
    equal('a sheet with a border', a, c, raw(plane, 'Cube'), closed=False)
    print('-- huge and tiny --')
    bases()
    ball = f'{T}/ball.bee'
    b0 = raw(ball, 'S')
    a, c = dyn(ball, 'S', [], 'sculpt("S", "draw", 0, 2, 1, 0, 2, 1, 1000, 0.5)\n', ['sculpt S "draw" 0 2 1 0 2 1 1000 0.5'])
    check(a == c, f'a huge radius ({counts(c)})')
    a, c = dyn(ball, 'S', ['sculpt.detail_coarser'] * 40, 'sculpt("S", "smooth", 0, 2, 1, 0.1, 2, 1, 50, 1)\n', ['sculpt S "smooth" 0 2 1 0.1 2 1 50 1'])
    equal('a huge smooth, the coarsest: collapses everywhere', a, c, b0)
    a, c = dyn(ball, 'S', [], 'sculpt("S", "draw", 0, 2, 1, 1, 2, 1, 0.0001, 0.5)\n', ['sculpt S "draw" 0 2 1 1 2 1 0.0001 0.5'])
    check(a == c, 'a tiny radius: 4096 dabs at most')
    for what, s in (('no strength', '0 2 1 0.2 2 1 0.5 0'), ('no radius', '0 2 1 0.2 2 1 0 0.5'), ('off the mesh', '50 50 50 51 50 50 0.5 0.5'), ('no way', '0 2 1 0 2 1 0.5 0.5')):
        a, c = dyn(ball, 'S', [], '', [f'sculpt S "draw" {s}'])
        check(a == c, f'{what}: {counts(c)}')
    print('-- growth: the arrays move under a long stroke --')
    # (a stroke's room: twice the mesh and 65536 vertices; a thin stroke on a cube passes it)
    sheet = f'{T}/sheet.bee'
    make(f'delete("Cube")\nadd("plane", "Cube")\nmodifier("Cube", "subsurf")\nmodset("Cube", 0, "levels", 5)\nmodapply("Cube", 0)\nop("file.save", "{sheet}")\n')
    x, y = 'sculpt("Cube", "draw", -1.9, 0.02, -1.9, 1.9, 0.02, 1.9, 0.1, 0.1)\n', 'sculpt Cube "draw" -1.9 0.02 -1.9 1.9 0.02 1.9 0.1 0.1'
    a, c = dyn(sheet, 'Cube', ['sculpt.detail_finer'] * 12, x, [y])
    equal('past the room the copy starts with', a, c, raw(sheet, 'Cube'), closed=False)
    check(counts(c)[0] > 2 * counts(raw(sheet, 'Cube'))[0] + 65536, f'it grew past it ({counts(c)[0]} vertices of {counts(raw(sheet, "Cube"))[0]})')
    print('-- no memory: the stroke goes on without new detail --')
    p = f'{T}/nomem.bee'
    says = 0
    for mb in (500, 450, 400, 350, 300, 280, 260, 240, 220, 200):
        if os.path.exists(p):
            os.remove(p)
        r = subprocess.run(['prlimit', f'--as={mb << 20}', BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--op', f'file.open {sheet}', '--select', 'Cube', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', *(['--op', 'sculpt.detail_finer'] * 12), '--op', y, '--op', 'mode.object', '--op', f'file.save {p}'], capture_output=True, text=True, env=S.ENV)
        if r.returncode != 0 and 'OutOfMemory' not in r.stderr and 'out of memory' not in r.stderr.lower():
            check(False, f'{mb} MB: {r.returncode} {r.stderr[-300:]}')
        if os.path.exists(p) and any('dyntopo: out of memory' in x for x in logged()):
            says += 1
            # (no room for the new mesh: it says so, and the old one stays)
            v = None if raw(p, 'Cube') == raw(sheet, 'Cube') else valid(raw(p, 'Cube'), f'{mb} MB', closed=False)
            check(v is None, v or f'{mb} MB: it says so, and what it saved holds together ({counts(raw(p, "Cube"))})')
    check(says > 0, f'a memory limit was met ({says} of them)')
    print('-- damaged geometry --')
    cases = {
        'NaN corners': [(float('nan'), 0, 0), (1, 0, 0), (0, 2, 0), (0, 0, 1)],
        'infinite corners': [(float('inf'), 0, 0), (1, float('-inf'), 0), (0, 2, 0), (0, 0, 1)],
        'huge corners': [(1e30, 0, 0), (-1e30, 1e30, 0), (0, 2e38, 0), (0, 0, 1)],
        'all in one point': [(0, 1, 0), (0, 1, 0), (0, 1, 0), (0, 1, 0)],
    }
    for name, vs in cases.items():
        q = cubeish(base, 'bad', vs, [[0, 1, 2], [0, 2, 3], [0, 3, 1], [1, 3, 2]])
        r = port('--op', f'file.open {q}', '--select', 'Cube', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', *(['--op', 'sculpt.detail_finer'] * 12), '--op', 'sculpt Cube "draw" 0 1 0 0.2 1 0 2 0.5', '--op', 'sculpt Cube "smooth" 0 1 0 0.2 1 0 2 0.5', '--op', 'sculpt Cube "grab" 0 1 0 0.2 1 0 2 0.5', '--drag', '600,300,700,380', '--op', 'edit.undo', '--op', 'mode.object', ok=False)
        check(r.returncode == 0, f'{name}: {r.stderr[-300:] if r.returncode else "no crash"}')
    data = open(ball, 'rb').read()
    rng = random.Random(SEED)
    for k in range(RUNS):
        b = bytearray(data)
        for _ in range(rng.randrange(1, 40)):
            b[rng.randrange(8, len(b))] = rng.randrange(256)
        open(f'{T}/fz.bee', 'wb').write(bytes(b))
        r = port('--op', f'file.open {T}/fz.bee', '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo', '--op', 'sculpt S "draw" 0 2 1 0.2 2 1 0.5 0.5', '--op', 'sculpt.mask_invert', '--drag', '600,300,700,380', '--op', 'edit.undo', ok=False)
        if r.returncode != 0:
            shutil.copy(f'{T}/fz.bee', '/tmp/beedyn-crash.bee')
            check(False, f'a damaged file: {r.stderr[-400:]}')
            break
    else:
        check(True, f'{RUNS} damaged files sculpted')


def s_fuzz():
    print('-- random strokes with the toggle, undone and redone --')
    bases()
    base = f'{T}/ball.bee'
    rng = random.Random(SEED)
    b0 = raw(base, 'S')
    br = ['draw', 'clay strips', 'crease', 'inflate', 'grab', 'snake hook', 'smooth', 'flatten', 'pinch', 'layer', 'mask']
    for run in range(max(1, RUNS // 4)):
        args = ['--op', f'file.open {base}', '--select', 'S', '--op', 'mode.sculpt', '--op', 'sculpt.dyntopo']
        for _ in range(rng.randrange(3, 14)):
            k = rng.random()
            if k < 0.55:
                a = [rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1), 2 + rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(0.05, 1.5), rng.uniform(-1, 1)]
                args += ['--op', f'sculpt S "{rng.choice(br)}" ' + ' '.join(f'{x:.4f}' for x in a)]
            elif k < 0.7:
                args += ['--op', rng.choice(['sculpt.symmetry x', 'sculpt.symmetry none', 'sculpt.symmetry xyz', 'sculpt.falloff root', 'sculpt.falloff smooth', 'sculpt.mask_invert', 'sculpt.mask_clear', 'sculpt.detail_finer', 'sculpt.detail_finer', 'sculpt.detail_coarser', 'sculpt.dyntopo'])]
            elif k < 0.85:
                args += ['--op', rng.choice(['mode.object', 'mode.sculpt', 'mode.edit', 'object.sculpt_mode'])]
            else:
                x, y = rng.randrange(300, 900), rng.randrange(200, 600)
                args += ['--drag', f'{x},{y},{rng.randrange(300, 900)},{rng.randrange(200, 600)}']
        end = f'{T}/fe.bee'
        args += ['--op', 'mode.object', '--op', f'file.save {end}']
        args2 = list(args)
        args2 += ['--op', 'edit.undo'] * 0
        for _ in range(40):
            args2 += ['--op', 'edit.undo']
        args2 += ['--op', f'file.save {T}/f0.bee']
        for _ in range(40):
            args2 += ['--op', 'edit.redo']
        args2 += ['--op', f'file.save {T}/f1.bee']
        r = port(*args2, ok=False)
        if r.returncode != 0:
            check(False, f'run {run}: {r.stderr[-400:]} {args2[:40]}')
            return
        e = raw(end, 'S')
        a0, a1 = raw(f'{T}/f0.bee', 'S'), raw(f'{T}/f1.bee', 'S')
        # (toggled on and straight off again before a stroke, the ball keeps its quads: not checked whole)
        v = valid(e, f'run {run}') if changed(e, b0) else None
        if a0 != b0 or a1 != e or v:
            check(False, f'run {run}: undone to the start {a0 == b0}, redone to the end {a1 == e}, {v}: {args}')
            return
    check(True, f'{max(1, RUNS // 4)} sessions: undone to the file\'s bytes, redone to the end\'s, each mesh whole')


SCEN = ['s_same', 's_threads', 's_files', 's_attrs', 's_undo', 's_midstroke', 's_window', 's_ui', 's_robust', 's_fuzz']

if __name__ == '__main__':
    print(f'seed {SEED}')
    for n in (WANT or SCEN):
        globals()[n]()
    shutil.rmtree(T, ignore_errors=True)
    print(f'fails {len(FAILS)}')
    for f in FAILS:
        print('  FAILED:', f)
    sys.exit(1 if FAILS else 0)
