#!/usr/bin/env python3
"""UV maps and the UV editor: unwraps, smart projections, packing and seams, the
same from a script (BeeScript) as from the operators, finite, in the square and
the same every run; the measures; .bee files saved, read back and saved again;
the editor's transforms, selection, heat maps and look in a window (the fake
compositor, tests/wl_fake.py); undo with values; damaged files; degenerate
meshes; baking. Every comparison also asserts that what it compares exists and
moved.

    python3 tests/uv.py BIN [damage-runs=60] [seed]
"""
import math, os, random, re, struct, subprocess, sys, tempfile, time
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
import wl_fake

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 60
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
FAILS = []
T = tempfile.mkdtemp(prefix='beeuv-', dir=os.environ.get('BEEUV_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def script(code):
    """A BeeScript run by BeeModel (--run): its printed lines. It must end cleanly."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    r = subprocess.run([BIN, '--run', p], capture_output=True, text=True, timeout=900, env=ENV)
    if 'error:' in r.stdout + r.stderr or r.returncode != 0:
        print((r.stdout + r.stderr)[-600:])
        check(False, f'the script stopped ({r.returncode}): {code[:60]!r}')
    return r.stdout


def port(*a, ok=True):
    r = subprocess.run([BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a], capture_output=True, text=True, timeout=900, env=ENV)
    if ok and r.returncode != 0:
        print(r.stderr[-1500:])
        check(False, f'the port stopped ({r.returncode}): {a[:6]}')
    return r


def ops(*lines):
    out = []
    for ln in lines:
        out += ['--op', ln]
    return out


def log():
    return open(f'{T}/log.txt').read().splitlines()


def uitext():
    return open(f'{T}/u.txt').read()


def muvs(path):
    """MUVS by mesh place: (flags, loops, uvs bytes, seams bytes)."""
    c = beefile.chunk(path, b'MUVS') or b''
    o, out = 0, {}
    while o < len(c):
        ix, fl, nl = struct.unpack_from('<III', c, o)
        o += 12
        uv = seam = b''
        if fl & 1:
            uv = c[o:o + nl * 8]
            o += nl * 8
        if fl & 2:
            n = (nl + 3) & ~3
            seam = c[o:o + n]
            o += n
        out[ix] = (fl, nl, uv, seam)
    return out


def rec(path, name):
    o = next(x for x in beefile.objects(path) if x['name'] == name)
    return muvs(path).get(o['mesh'])


def uvs(r):
    return struct.unpack(f'<{r[1] * 2}f', r[2])


def stats(path=None):
    out = {}
    for ln in open(path or f'{T}/uv.txt'):
        w = ln.split()
        if w and w[0] not in ('step', 'uved', 'line'):
            out.update(zip(w[0::2], w[1::2]))
    return out


def dump():
    return ['--dump-uv', f'{T}/uv.txt']


def steps():
    return [ln[5:].strip() for ln in open(f'{T}/uv.txt') if ln.startswith('step ')][1:]


def same(a, b, what):
    """The same record, bit for bit; it must exist and hold more than zeros."""
    ok = a is not None and b is not None and a[:2] == b[:2] and a[2] == b[2] and a[3] == b[3]
    live = a is not None and (any(a[2]) or any(a[3]))
    if a is not None and b is not None and not ok and a[1] == b[1] and a[2] and b[2]:
        d = max(abs(x - y) for x, y in zip(uvs(a), uvs(b)))
        what += f' (differs by {d})'
    check(ok and live, what)


def sane(r, what, square=True):
    """UVs there, finite, and (packed) in the unit square."""
    v = uvs(r) if r is not None and r[0] & 1 else ()
    fin = bool(v) and all(math.isfinite(x) for x in v)
    ins = fin and (not square or all(-1e-3 <= x <= 1.001 for x in v))
    check(fin and ins, what + (f' ({min(v):.3f} .. {max(v):.3f})' if fin else f' (flags {r and r[0]})'))


def obj(path, kind='grid'):
    """Meshes the primitives do not give."""
    with open(path, 'w') as f:
        if kind == 'ngon':
            # an L, a pentagon and a hexagon on a bent strip: fans and ear clipping
            for v in ((0, 0, 0), (2, 0, 0), (2, 1, 0), (1, 1, 0), (1, 2, 0), (0, 2, 0), (3, 0, 1), (4, 1, 1), (3, 2, 2), (2, 2, 1.5)):
                f.write('v %g %g %g\n' % v)
            f.write('f 1 2 3 4 5 6\nf 2 7 8 9 10 3\n')
        elif kind == 'one':
            f.write('v 0 0 0\nv 1 0 0\nv 1 1 0.5\nv 0 1 0.5\nf 1 2 3 4\n')
        elif kind == 'tri':
            f.write('v 0 0 0\nv 1 0 0\nv 0 1 0.5\nf 1 2 3\n')
        elif kind == 'zero':
            # a zero-area polygon between two good ones, all its corners at a point
            f.write('v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nv 2 0 0\nv 2 1 1\nv 1 0.5 0\n')
            f.write('f 1 2 3 4\nf 7 7 7\nf 2 5 6 3\nf 2 1 5\n')   # (2 1 5: on a line, inside the island)
        elif kind == 'nonmanifold':
            # three quads on one edge, and a bow tie at a vertex
            f.write('v 0 0 0\nv 0 1 0\nv 1 0 0\nv 1 1 0\nv -1 0 0\nv -1 1 0\nv 0 0 1\nv 0 1 1\nv 2 1 1\nv 2 0 1\n')
            f.write('f 1 2 4 3\nf 2 1 5 6\nf 1 2 8 7\nf 4 9 10\n')
        elif kind == 'flipped':
            # two polygons along one edge the same way
            f.write('v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nv 1 -1 0.3\nv 0 -1 0.3\n')
            f.write('f 1 2 3 4\nf 1 2 5 6\n')
        elif kind == 'repeat':
            # a polygon through one vertex twice
            f.write('v 0 0 0\nv 2 0 0\nv 2 2 0.5\nv 0 2 0.5\nv 1 1 0\nv 3 1 1\n')
            f.write('f 1 2 5 3 4 5\nf 2 6 3 5\n')
        elif kind == 'sliver':
            # a million to one, bent: conjugate gradients run to their limit
            n = 14
            for j in range(3):
                for i in range(n + 1):
                    f.write(f'v {i * 20000:.3f} {j * 0.02:.6f} {math.sin(i * 1.3 + j) * 3000:.3f}\n')
            for j in range(2):
                for i in range(n):
                    a = j * (n + 1) + i + 1
                    f.write(f'f {a} {a + 1} {a + n + 2} {a + n + 1}\n')
        else:
            n = 8
            for j in range(n + 1):
                for i in range(n + 1):
                    x, y = i / n * 3, j / n * 3
                    f.write(f'v {x:.6f} {y:.6f} {0.4 * math.sin(2 * x) * math.cos(y):.6f}\n')
            for j in range(n):
                for i in range(n):
                    a = j * (n + 1) + i + 1
                    f.write(f'f {a} {a + 1} {a + n + 2} {a + n + 1}\n')
    return path


def unwrapped(a, name, seam, smart):
    return (f'print(seams("{name}", "sharp"))\n' if seam else '') + (f'print(unwrap("{name}", "smart"))\n' if smart else f'print(unwrap("{name}"))\n') + f'op("file.save", "{a}")\n'


def s_same():
    print('-- every primitive, along seams and smart: the script and the operators agree, finite, in the square, the same twice --')
    for kind in ('cube', 'sphere', 'cylinder', 'torus', 'cone', 'plane', 'grid'):
        for seam in (0, 1):
            for smart in (0, 1):
                a, b, c = f'{T}/a.bee', f'{T}/b.bee', f'{T}/c.bee'
                out = script(f'add("{kind}", "X")\nselect("X")\n' + unwrapped(a, 'X', seam, smart)).split()
                line = ops(f'create.{kind}', *(['uv.seams_from_sharp'] if seam else []), 'uv.smart_project' if smart else 'uv.unwrap')
                port(*line, *ops(f'file.save {c}'))
                port(*line, *ops(f'file.save {b}'))
                name = beefile.objects(b)[-1]['name']
                same(rec(a, 'X'), rec(b, name), f'{kind} seams={seam} smart={smart}: {out[-1:]} islands')
                same(rec(c, name), rec(b, name), '  the same UVs on a second run')
                sane(rec(b, name), '  finite, in the square')
                isl = [ln for ln in log() if ln.startswith('  uv: islands')]
                check(len(isl) == 1 and out and isl == [f'  uv: islands {out[-1]}'] and int(out[-1]) >= 1, f'  the console says {isl}')
                if kind == 'cube' and seam:
                    check(isl == ['  uv: islands 6'], '  a cube cut along its sharp edges: its 6 faces')
                if not seam and not smart:
                    check(isl == ['  uv: islands 1'], '  one piece, no seams: one island')
    print('-- meshes of a file: polygons of many sides, one polygon, a triangle, zero area, non-manifold --')
    for kind in ('grid', 'ngon', 'one', 'tri', 'zero', 'nonmanifold', 'flipped', 'repeat', 'sliver'):
        p = obj(f'{T}/{kind}.obj', kind)
        for seam in (0, 1):
            for smart in (0, 1):
                a, b = f'{T}/a.bee', f'{T}/b.bee'
                script(f'op("file.import_obj", "{p}")\nn = name(count() - 1)\nselect(n)\nprint(n)\n' + unwrapped(a, 'n', seam, smart).replace('"n"', 'n'))
                n = beefile.objects(a)[-1]['name']
                port(*ops(f'file.import_obj {p}', *(['uv.seams_from_sharp'] if seam else []), 'uv.smart_project' if smart else 'uv.unwrap', f'file.save {b}'))
                same(rec(a, n), rec(b, n), f'{kind} seams={seam} smart={smart}: the script and the operators agree')
                sane(rec(b, n), '  finite, in the square')
    print('-- every edge a seam, a scaled object, unwrapped twice, packed again --')
    p = obj(f'{T}/grid.obj')
    a, b = f'{T}/a.bee', f'{T}/b.bee'
    script(f'op("file.import_obj", "{p}")\nn = name(count() - 1)\nselect(n)\nop("mode.toggle_edit")\nop("mesh.select_all")\nprint(vsel(n, 0))\nif not vsel(n, 0) {{ op("mesh.select_all") }}\nprint(seams(n, "mark"))\nprint(unwrap(n))\nop("mode.toggle_edit")\nop("file.save", "{a}")\n')
    port(*ops(f'file.import_obj {p}'), '--move', '615,360', '--key', 'tab', *ops('uv.seam_mark', 'uv.unwrap', 'mode.toggle_edit', f'file.save {b}'))
    n = beefile.objects(a)[-1]['name']
    same(rec(a, n), rec(b, n), 'all seams: the script and the window agree')
    check(any(ln == '  uv: islands 64' for ln in log()), 'all seams: 64 islands')
    code = f'add("cube", "X")\nselect("X")\nscale("X", 3, 1, 0.5)\nprint(seams("X", "sharp"))\nprint(unwrap("X"))\nprint(unwrap("X"))\nprint(uvpack("X"))\nop("file.save", "{a}")\n'
    script(code)
    script(code.replace('scale("X", 3, 1, 0.5)\n', '').replace(a, c))
    port(*ops('create.cube', 'object.rename Cube.001 X', 'uv.seams_from_sharp', 'uv.unwrap', 'uv.unwrap', 'uv.pack', f'file.save {b}'))
    name = beefile.objects(b)[-1]['name']
    same(rec(a, 'X'), rec(c, 'X'), 'unwrapped twice and packed: the object\'s scale has no say')
    same(rec(b, name), rec(c, 'X'), 'and the operators give the same')


def s_stats():
    print('-- the measures: uvstat --')
    kinds = ('islands', 'angle', 'area', 'flipped', 'overlap', 'inside')
    for kind, smart in (('sphere', 0), ('torus', 1), ('cylinder', 1)):
        a = f'{T}/a.bee'
        out = script(f'add("{kind}", "X")\nselect("X")\n' + ('print(unwrap("X", "smart"))\n' if smart else 'print(seams("X", "sharp"))\nprint(unwrap("X"))\n') + ''.join(f'print("S", uvstat("X", "{k}"))\n' for k in kinds))
        want = [float(ln.split()[1]) for ln in out.splitlines() if ln.startswith('S ')]
        port(*ops(f'create.{kind}', *(['uv.smart_project'] if smart else ['uv.seams_from_sharp', 'uv.unwrap'])), *dump())
        got = stats()
        check(len(want) == len(kinds), f'{kind}: the script measures all {len(kinds)}: {want}')
        for k, w in zip(kinds, want):
            g = float(got[k])
            check(abs(g - w) <= 2e-4 * max(1, abs(w)), f'{kind} {k}: {g} (the script {w})')
        g = [float(got[k]) for k in kinds]
        check(all(math.isfinite(x) and x >= 0 for x in g) and g[0] >= 1 and g[5] == 1,
              f'{kind}: finite, not negative, an island or more, all inside: {g}')
        check(any(w > 0 for w in g[1:3]), f'{kind}: the measures measure something: {g}')
        if smart:
            check(g[3] == 0 and g[4] == 0, f'{kind}: a smart projection: nothing turned over, nothing on top ({g[3]}, {g[4]})')
    # hand-made UVs in a file: turned over and on top of each other
    src, p = f'{T}/h0.bee', f'{T}/h1.bee'
    script(f'add("cube", "X")\nprint(seams("X", "sharp"))\nprint(unwrap("X"))\nop("file.save", "{src}")\n')
    o = next(x for x in beefile.objects(src) if x['name'] == 'X')
    cs = beefile.chunks(src)
    out = bytearray(b'BEEM' + struct.pack('<I', 1))
    for t, b in cs:
        d = bytearray(b)
        if t == b'MUVS':
            at, q = 0, None
            while at < len(d):
                ix, fl, nl = struct.unpack_from('<III', d, at)
                if ix == o['mesh']:
                    q = at + 12
                at += 12 + (nl * 8 if fl & 1 else 0) + ((nl + 3) & ~3 if fl & 2 else 0)
            quad = [(0.1, 0.1), (0.6, 0.1), (0.6, 0.6), (0.1, 0.6)]
            for k in range(24):
                u, v = quad[k % 4]
                if k >= 12:  # the second half: turned over
                    u, v = quad[3 - k % 4]
                struct.pack_into('<2f', d, q + k * 8, u, v)
            struct.pack_into('<f', d, q, 1.5)  # and one out of the square
        out += t + struct.pack('<I', len(d)) + d
    open(p, 'wb').write(out)
    code = f'op("file.open", "{p}")\n' + ''.join(f'print("S", uvstat("X", "{k}"))\n' for k in kinds)
    want = [float(ln.split()[1]) for ln in script(code).splitlines() if ln.startswith('S ')]
    port(*ops(f'file.open {p}'), '--dump-uv', f'{T}/uv.txt;X')
    got = stats()
    check(len(want) == len(kinds), f'hand-made UVs: the script measures all {len(kinds)}')
    for k, w in zip(kinds, want):
        check(abs(float(got.get(k, 'nan')) - w) <= 2e-4 * max(1, abs(w)), f'hand-made UVs, {k}: {got.get(k)} (the script {w})')
    g = [float(got.get(k, 'nan')) for k in kinds]
    check(g[3] > 0 and g[4] > 0 and g[5] == 0, f'the hand-made case is one: turned over, on top of each other, one outside: {g}')
    # no UVs: -1 everywhere
    port(*ops('create.cube'), *dump())
    check(stats()['hasuv'] == '0' and stats()['islands'] == '-1', 'no UVs: -1')
    check(script('add("cube", "X")\nprint(uvstat("X", "islands"))\n').split()[-1:] == ['-1'], '... from a script too')


def s_seams():
    print('-- seams: between selected vertices, kept with the polygons, counted the same --')
    a, b = f'{T}/a.bee', f'{T}/b.bee'
    code = f'''add("cube", "X")
select("X")
op("mode.toggle_edit")
vselect("X", 0, 1, 2, 3)
print(seams("X", "mark"))
vselect("X", 0, 1)
print(seams("X", "clear"))
vselect("X", 4, 5)
print(seams("X", "mark"))
op("mode.toggle_edit")
op("file.save", "{a}")
'''
    want = script(code).split()
    port(*ops('create.cube'), '--move', '615,360', '--key', 'tab', '--vselect', '0 1 2 3', *ops('uv.seam_mark'), '--vselect', '0 1', *ops('uv.seam_clear'), '--vselect', '4 5', *ops('uv.seam_mark', 'mode.toggle_edit', f'file.save {b}'))
    name = beefile.objects(b)[-1]['name']
    a0, b0 = rec(a, 'X'), rec(b, name)
    check(a0 is not None and b0 is not None and a0[3] == b0[3] and a0[0] == b0[0] == 2 and any(a0[3]), f'the script and the window mark the same seams, no UVs (flags {a0 and a0[0]})')
    got = [ln.split()[-1] for ln in log() if 'uv: seams' in ln]
    check(got == want and len(got) == 3 and len(set(got)) > 1, f'the counts: {got} (the script {want})')
    # nothing selected: the array comes, empty
    out = script(f'add("cube", "X")\nselect("X")\nprint(seams("X", "mark"))\nprint(seams("X", "clear"))\nop("file.save", "{a}")\n').split()
    port(*ops('create.cube', 'uv.seam_mark', 'uv.seam_clear', f'file.save {b}'))
    name = beefile.objects(b)[-1]['name']
    a0, b0 = rec(a, 'X'), rec(b, name)
    check(a0 and b0 and a0[0] == b0[0] and a0[3] == b0[3], f'object mode, a new mesh\'s selection: {out} {[ln for ln in log() if "uv:" in ln]}')
    check(not (b0 and any(b0[3])), 'marked, then cleared: no seam left')
    # a seam marked on one side of its edge is a seam (a file may say so)
    src = f'{T}/one0.bee'
    script(f'add("torus", "X")\nselect("X")\nprint(seams("X", "sharp"))\nop("file.save", "{src}")\n')
    x = next(o for o in beefile.objects(src) if o['name'] == 'X')
    out = bytearray(b'BEEM' + struct.pack('<I', 1))
    for t, d0 in beefile.chunks(src):
        d = bytearray(d0)
        if t == b'MUVS':
            at = 0
            while at < len(d):
                ix, fl, nl = struct.unpack_from('<III', d, at)
                if ix == x['mesh']:
                    # a loop in two keeps its mark: the twins of an edge seldom both do
                    for k in range(nl):
                        if (k >> 2) % 2:
                            d[at + 12 + k] = 0
                at += 12 + ((nl + 3) & ~3)
        out += t + struct.pack('<I', len(d)) + d
    p = f'{T}/one.bee'
    open(p, 'wb').write(out)
    script(f'op("file.open", "{p}")\nselect("X")\nprint(unwrap("X"))\nop("file.save", "{a}")\n')
    port(*ops(f'file.open {p}'), '--select', 'X', *ops('uv.unwrap', f'file.save {b}'))
    same(rec(a, 'X'), rec(b, 'X'), 'a seam on one side of its edge: the script and the operators agree')
    sane(rec(b, 'X'), '  finite, in the square')
    # the edges stay after an edit that moves vertices
    port(*ops('create.cube', 'uv.seams_from_sharp', 'uv.unwrap', 'view.reset_camera'), '--move', '615,360', '--key', 'tab', '--key', 'g', '--key', 'x', '--type', '1', '--key', 'enter', '--key', 'tab', *ops(f'file.save {b}'))
    name = beefile.objects(b)[-1]['name']
    r = rec(b, name)
    check(r is not None and r[0] == 3, 'moved vertices keep their UVs and seams')
    # seams shown: red in edit mode, none without them
    port(*ops('create.cube'), '--move', '615,360', '--key', 'tab', '--op', 'uv.seams_from_sharp')
    red = count_px(f'{T}/u.ppm', 0xe8483c)
    port(*ops('create.cube'), '--move', '615,360', '--key', 'tab')
    none = count_px(f'{T}/u.ppm', 0xe8483c)
    check(red > 100 and none == 0, f'edit mode draws seams red: {red} pixels, {none} without')
    port(*ops('create.cube', 'uv.seams_from_sharp'))
    check(count_px(f'{T}/u.ppm', 0xe8483c) == 0, 'not in object mode')


def s_files():
    print('-- .bee files: UVs, seams, each alone; saved, read back, saved again --')
    a, b, c, d = f'{T}/fa.bee', f'{T}/fb.bee', f'{T}/fc.bee', f'{T}/fd.bee'
    script(f'add("cube", "S")\nprint(seams("S", "sharp"))\nadd("sphere", "U")\nprint(unwrap("U", "smart"))\nadd("torus", "B")\nprint(seams("B", "sharp"))\nprint(unwrap("B"))\nadd("cylinder", "N")\nop("file.save", "{a}")\n')
    recs = muvs(a)
    check(sorted(r[0] for r in recs.values()) == [1, 2, 3], f'the file has seams alone, UVs alone, both: {sorted(r[0] for r in recs.values())}')
    port(*ops(f'file.open {a}', f'file.save {b}'))
    for n in ('S', 'U', 'B'):
        same(rec(a, n), rec(b, n), f'a script\'s file opened and saved: {n}')
    check(rec(b, 'N') is None, 'a mesh with neither has no record')
    script(f'op("file.open", "{b}")\nop("file.save", "{c}")\n')
    for n in ('S', 'U', 'B'):
        same(rec(a, n), rec(c, n), f'and again, opened and saved by a script: {n}')
    check(beefile.chunk(b, b'MUVS') == beefile.chunk(c, b'MUVS'), 'saved twice: the same MUVS chunk')
    # the operators' work, read by a script
    port(*ops(f'file.open {a}', 'object.select_all', 'object.select_all'), '--select', 'N', *ops('uv.seams_from_sharp', 'uv.unwrap', f'file.save {d}'))
    want = script(f'op("file.open", "{d}")\nprint("I", uvstat("N", "islands"))\nprint("O", uvstat("N", "inside"))\n')
    check('I 3' in want and 'O 1' in want, f'a script reads them back: a cylinder in 3 islands, inside: {want.split()}')
    same(rec(d, 'U'), rec(a, 'U'), 'the others are left as they were')
    # an uneven loop count: seam bytes to a multiple of four, zeros after
    p = obj(f'{T}/tri.obj', 'tri')
    script(f'op("file.import_obj", "{p}")\nn = name(count() - 1)\nprint(seams(n, "sharp"))\nop("file.save", "{a}")\n')
    port(*ops(f'file.import_obj {p}', 'uv.seams_from_sharp', f'file.save {b}'))
    n = beefile.objects(a)[-1]['name']
    x, y = rec(a, n), rec(b, n)
    check(x and y and x[3] == y[3] == bytes(4) and x[1] == 3, f'3 loops: 4 seam bytes ({x and len(x[3])})')
    # edit that changes the polygons
    script(f'add("cube", "X")\nprint(seams("X", "sharp"))\nprint(unwrap("X"))\nselect("X")\nop("mode.toggle_edit")\nop("mesh.select_all")\nprint(vsel("X", 0))\nif not vsel("X", 0) {{ op("mesh.select_all") }}\nop("mesh.subdivide")\nop("mode.toggle_edit")\nop("file.save", "{a}")\n')
    port(*ops('create.cube', 'uv.seams_from_sharp', 'uv.unwrap'), '--move', '615,360', '--key', 'tab', *ops('mesh.subdivide', 'mode.toggle_edit', f'file.save {b}'))
    x, y = rec(a, 'X'), rec(b, beefile.objects(b)[-1]['name'])
    check((x is None) == (y is None), f'a new topology: the script and the window agree (script {x and x[:2]}, window {y and y[:2]})')
    nl = sum(len(pl) for pl in beefile.meshes(b)[next(o for o in beefile.objects(b) if o['name'] == beefile.objects(b)[-1]['name'])['mesh']][1])
    check(y is None or (y[1] == nl and (not y[0] & 1 or all(math.isfinite(v) for v in uvs(y)))), f'  what stays fits the new mesh: {y and y[1]} loops of {nl}')


US = {**{c: k for k, c in enumerate('1234567890', 2)}, **{c: k for k, c in enumerate('qwertyuiop', 16)},
      **{c: k for k, c in enumerate('asdfghjkl', 30)}, **{c: k for k, c in enumerate('zxcvbnm', 44)},
      '.': 52, '-': 12, ' ': 57, '/': 53, '=': 13, ',': 51, ';': 39, "'": 40, '[': 26, ']': 27, '\\': 43, '`': 41}
US_SHIFT = {'_': 12, '(': 10, ')': 11, '"': 40, '+': 13, '{': 26, '}': 27, '*': 9, '<': 51, '>': 52,
            '#': 4, '%': 6, '!': 2, ':': 39, '?': 53, '@': 3, '$': 5, '^': 7, '&': 8, '|': 43, '~': 41}


class Fake(wl_fake.Fake):
    """tests/wl_fake.py's compositor (a window of 1280x800) with what these tests
    drive: typing, the wheel, drags, a fractional scale, the last frame."""

    def __init__(self, binary):
        super().__init__(binary, size=(1280, 800))

    def move(self, x, y):
        self.motion(x, y)
        self.pump(0.03)

    def click(self, x, y, btn=0x110):
        super().click(x, y, btn)

    def type(self, text):
        for ch in text:
            sh = ch in US_SHIFT or ch.isupper()
            if sh:
                self.mods(1)
            code = US_SHIFT[ch] if ch in US_SHIFT else US[ch.lower()]
            self.serial += 1
            self.send(self.keyboard, 3, struct.pack('<IIII', self.serial, 1, code, 1))
            self.serial += 1
            self.send(self.keyboard, 3, struct.pack('<IIII', self.serial, 1, code, 0))
            if sh:
                self.mods(0)
        self.pump(0.1)

    def wheel(self, steps):
        """steps: negative up (in), positive down; 15 a step"""
        self.send(self.pointer, 4, struct.pack('<IIi', 0, 0, int(steps * 15 * 256)))
        self.pump(0.05)

    def drag(self, x0, y0, x1, y1, btn=0x110):
        self.motion(x0, y0)
        self.pump(0.03)
        self.button(btn, True)
        self.pump(0.03)
        for k in range(1, 9):
            self.motion(x0 + (x1 - x0) * k // 8, y0 + (y1 - y0) * k // 8)
            self.pump(0.03)
        self.button(btn, False)
        self.pump(0.05)

    def scale(self, pct):
        self.preferred_scale(pct * 120 // 100)

    @property
    def frame(self):
        """(width, height, pixels): 4 bytes a pixel, rows packed."""
        s = self.surfaces[self.main().surface]
        bf = self.buffers[s['last']]
        w, h, st, px = bf['w'], bf['h'], bf['stride'], s['pixels']
        if st != w * 4:
            px = b''.join(px[y * st:y * st + w * 4] for y in range(h))
        return w, h, px


class Win:
    """BeeModel's window, driven by the fake compositor."""

    def __init__(self, binary):
        self.home = tempfile.mkdtemp(dir=T)
        self.f = Fake(binary)
        self.f.until(lambda: self.f.frames > 0, 15)
        self.f.pump(0.5)
        self.f.enter(600, 300)
        self.f.move(600, 300)
        self.f.pump(0.3)
        self.maxed = False

    def line(self, c):
        """A console line."""
        f = self.f
        f.key(28)
        f.pump(0.1)
        f.type(c)
        f.key(28)
        f.pump(0.2)
        f.key(1)
        f.pump(0.1)

    def save(self, tag):
        """The file a console line saves, this window's own: what it wrote, read back."""
        p = f'{self.home}/{tag}.bee'
        was = self.maxed
        if was:
            self.toggle_max()
        if os.path.exists(p):
            os.remove(p)
        self.line(f'file.save {p}')
        wait_saved(self.f, p)
        self.f.pump(0.2)
        if was:
            self.toggle_max()
        check(os.path.exists(p), f'{tag} saved') if not os.path.exists(p) else None
        return p

    def toggle_max(self):
        """The header's Maximize button (the console is not there while maximized)."""
        if self.maxed:
            self.f.click(1199, 68)
        else:
            self.f.move(600, 300)
            self.f.pump(0.1)
            self.line('area.maximize')
        self.f.move(600, 300)
        self.f.pump(0.3)
        self.maxed = not self.maxed

    def undo(self):
        f = self.f
        f.mods(4)
        f.key(44)
        f.mods(0)
        f.pump(0.2)

    def redo(self):
        f = self.f
        f.mods(5)
        f.key(44)
        f.mods(0)
        f.pump(0.2)

    def close(self):
        err = self.f.close()
        check('panic' not in err and 'reached unreachable' not in err, 'the window ended without a panic' + (f': {err[-300:]}' if 'panic' in err else ''))


def one(fn):
    """fn run on a window of its own: its answer."""
    w = Win(BIN)
    try:
        return fn(w)
    finally:
        w.close()


def s_undo():
    print('-- undo with values in a window: unwrap, transforms, cancels, each step back and on again --')
    name = 'Cube'

    def run(w):
        f = w.f
        res = []

        def state(tag):
            r = rec(w.save(tag.replace(' ', '_')), name)
            res.append((tag, (r[0], r[2], r[3]) if r else None))
        w.line('area.type_uv_editor')
        state('start')
        w.line('mode.edit')
        w.line('uv.seams_from_sharp')
        state('seams')
        maxi(w, 'uv.unwrap')   # (one body in both: the same UV under the pointer)
        state('unwrap')
        f.move(460, 300)
        f.pump(0.1)
        f.key(30)   # A: all
        f.pump(0.2)
        f.key(34)   # G, then away: Esc
        f.pump(0.1)
        f.move(520, 330)
        f.pump(0.2)
        f.key(1)
        f.pump(0.2)
        state('cancelled')
        f.key(34)   # G, Enter
        f.pump(0.1)
        f.move(560, 350)
        f.pump(0.2)
        f.key(28)
        f.pump(0.2)
        state('moved')
        f.key(19)   # R, left button
        f.pump(0.1)
        f.move(600, 300)
        f.pump(0.2)
        f.click(600, 300)
        f.pump(0.2)
        state('turned')
        f.key(31)   # S, right button
        f.pump(0.1)
        f.move(640, 300)
        f.pump(0.2)
        f.click(640, 300, btn=0x111)
        f.pump(0.2)
        state('scale cancelled')
        for k in range(7):
            w.undo()
            state(f'undo{k}')
        for k in range(7):
            w.redo()
            state(f'redo{k}')
        return res
    a = one(run)
    check(len(a) == 21, f'{len(a)} states')
    na = [x[0] for x in a]
    vals = {t: x for t, x in a}
    check(vals['moved'] != vals['unwrap'] and vals['turned'] != vals['moved'], 'the transforms moved something')
    check(vals['cancelled'] == vals['unwrap'], 'a cancelled transform leaves the UVs')
    check(vals['scale cancelled'] == vals['turned'], 'the right button cancels a scale')
    check(vals['seams'] is not None and vals['seams'][0] == 2 and vals['unwrap'][0] == 3, 'seams, then UVs too')
    # six steps (a cancel is one): each undo goes one state back, each redo one on
    pre = [x for _, x in a[:7]]
    for k in range(7):
        check(vals[f'undo{k}'] == pre[max(5 - k, 0)], f'undo {k + 1}: the state before ({na[max(5 - k, 0)]})')
    for k in range(7):
        check(vals[f'redo{k}'] == pre[min(k + 1, 6)], f'redo {k + 1}: the state after ({na[min(k + 1, 6)]})')
    check(vals['start'] is None, 'it starts with none')
    check(na.count('start') == 1, 'one start')


def s_undo_steps():
    print('-- the steps: one each, a cancel too, nothing selected: none --')
    port(*ops('create.cube', 'area.type_uv_editor'), '--move', '615,360', *ops('mode.edit', 'uv.seams_from_sharp', 'uv.unwrap'), '--move', '460,300', '--key', 'a', '--key', 'g', '--move', '500,300', '--key', 'esc', *dump())
    want = ['Seams from Sharp Edges', 'Unwrap', 'Move Islands']
    got = steps()
    check(got[-3:] == want, f'a cancelled move is a step: {got[-3:]}')
    port(*ops('create.cube', 'area.type_uv_editor'), '--move', '615,360', *ops('mode.edit', 'uv.seams_from_sharp', 'uv.unwrap'), '--move', '460,300', '--key', 'g', '--move', '500,300', '--key', 'esc', *dump())
    check(steps()[-1] == 'Unwrap', f'nothing selected: no step, no transform: {steps()[-2:]}')
    port(*ops('create.cube', 'area.type_uv_editor'), '--move', '615,360', *ops('mode.edit', 'uv.pack', 'uv.seam_mark', 'uv.seam_clear'), *dump())
    check(steps()[-3:] == ['Pack Islands', 'Mark Seam', 'Clear Seam'], f'operators that change nothing are steps: {steps()[-3:]}')
    check(any('uv: out of memory' in ln for ln in log()), 'pack with no UVs says so')
    # a light: nothing to do, no step
    port(*ops('create.light', 'uv.unwrap', 'uv.seam_mark', 'uv.pack', 'uv.smart_project'), *dump())
    check(steps() == ['Light'] or len(steps()) == 1, f'no mesh: no steps: {steps()}')
    check(sum('uv: select a mesh' in ln for ln in log()) == 4, 'and the message')
    # two objects on one mesh: the other keeps its UVs
    a, b = f'{T}/a.bee', f'{T}/b.bee'
    port(*ops('create.cube', 'create.cube', 'uv.seams_from_sharp', 'uv.unwrap', f'file.save {b}'))
    o = beefile.objects(b)
    m = muvs(b)
    cubes = [x for x in o if x['type'] == 0]
    check(len(cubes) == 3 and sum(x['mesh'] in m for x in cubes) == 1, f'one of three cubes got UVs: {[x["mesh"] in m for x in cubes]}')
    # past a save and a reload
    p = f'{T}/r.bee'
    port(*ops('create.cube', 'uv.seams_from_sharp', 'uv.unwrap', f'file.save {p}', 'uv.pack', 'edit.undo', f'file.save {a}', f'file.open {p}', 'uv.pack', 'edit.undo', f'file.save {b}'))
    n = beefile.objects(a)[-1]['name']
    same(rec(p, n), rec(a, n), 'undone after a save: as it was saved')
    same(rec(p, n), rec(b, n), 'undone after a reload: as it was saved')
    # an undone step and an older one holding the same mesh: the older stays
    port(*ops('create.cube', 'uv.seams_from_sharp', 'uv.unwrap', f'file.save {a}', 'uv.pack', 'uv.smart_project', 'edit.undo', 'edit.undo', f'file.save {b}', 'edit.redo', 'edit.redo', 'edit.undo', 'edit.undo', f'file.save {p}'))
    same(rec(a, n), rec(b, n), 'two undone: the first unwrap, not what came after')
    same(rec(a, n), rec(p, n), 'and again after a redo')
    # edit mode: the selection and the mesh stay together
    port(*ops('create.cube', 'area.type_uv_editor'), '--move', '615,360', *ops('mode.edit', 'uv.unwrap', 'edit.undo', 'uv.unwrap', 'edit.undo', 'edit.redo'), *dump())
    check(stats()['hasuv'] == '1', 'in edit mode, undo and redo')


def maxi(w, *lines):
    """The UV editor over the whole window: one body, the same in both. The lines
    run first."""
    w.line('area.type_uv_editor')
    for ln in lines:
        w.line(ln)
    w.f.move(600, 300)
    w.f.pump(0.2)
    w.line('area.maximize')
    w.f.pump(0.3)
    w.maxed = True


def body(frame, box):
    wd, h, px = frame
    x0, y0, x1, y1 = box
    return [bytes(px[(y * wd + x0) * 4:(y * wd + x1) * 4]) for y in range(y0, y1)]


def s_look():
    print('-- the look: the editor\'s body in each state, each different, Home back --')

    def run(w):
        f = w.f
        out = {}
        maxi(w)
        f.pump(0.3)
        # (the header and the status are the shell's; the toast corner stays out)
        box = (0, 100, 1100, 770)
        out['empty'] = body(f.frame, box)
        w.toggle_max()
        w.line('create.sphere')
        w.line('mode.edit')
        w.line('uv.seams_from_sharp')
        w.line('uv.smart_project')
        f.move(600, 300)
        f.pump(0.2)
        uv = uvs(rec(w.save('ly'), beefile.objects(f'{w.home}/ly.bee')[-1]['name']))
        at = (640 + ((uv[0] + uv[2] + uv[4]) / 3 - 0.5) * 612, 438 - ((uv[1] + uv[3] + uv[5]) / 3 - 0.5) * 612)
        w.toggle_max()
        f.click(40, 700)   # (the keys are the editor's again; there is no island there)
        f.move(640, 300)
        f.pump(3.5)   # (the toast goes)
        out['islands'] = body(f.frame, box)
        f.key(30)
        f.pump(0.2)
        out['all selected'] = body(f.frame, box)
        f.key(30)
        f.pump(0.2)
        f.click(int(at[0]), int(at[1]))
        f.pump(0.3)
        out['one island'] = body(f.frame, box)
        f.key(32)
        f.pump(0.3)
        out['area heat'] = body(f.frame, box)
        f.key(32)
        f.pump(0.3)
        out['angle heat'] = body(f.frame, box)
        f.key(32)
        f.pump(0.2)
        f.wheel(-1)
        f.pump(0.2)
        f.wheel(-1)
        f.pump(0.2)
        out['zoomed in'] = body(f.frame, box)
        f.drag(640, 400, 700, 430, btn=0x112)
        f.pump(0.3)
        out['panned'] = body(f.frame, box)
        f.key(102)
        f.pump(0.3)
        out['Home'] = body(f.frame, box)
        return out
    a = one(run)
    for k in a:
        kinds = len({bytes(r) for r in a[k]})
        check(len(a[k]) == 670 and kinds > (1 if k == 'empty' else 20), f'{k}: {kinds} kinds of row')
    names = list(a)
    dup = [(p, q) for i, p in enumerate(names) for q in names[i + 1:] if a[p] == a[q] and (p, q) != ('one island', 'Home')]
    check(not dup, f'each of them shows something else: {dup}')
    check(a['Home'] == a['one island'], 'Home gives the view back')
    # the line over the layout: its numbers (the text itself is the shell's)
    port(*ops('area.type_uv_editor', 'mode.edit', 'uv.seams_from_sharp', 'uv.unwrap'), *dump())
    check('UV: 6 islands   texel density 166 px/m (1024 px)   D: no heat map' in open(f'{T}/uv.txt').read(), 'the line says 6 islands, 166 px/m')


def s_transforms():
    print('-- transforms: what G, S and R give, in numbers --')

    def run(w):
        f = w.f
        out = []
        maxi(w, 'mode.edit', 'uv.seams_from_sharp', 'uv.smart_project')
        f.move(640, 300)
        f.pump(0.2)
        # an island, the rest stays
        f.click(560, 300)
        f.pump(0.2)
        for k, (x, y) in ((34, (700, 340)), (31, (610, 260)), (19, (500, 200))):
            f.move(600, 320)
            f.pump(0.1)
            f.key(k)
            f.pump(0.1)
            f.move(x, y)
            f.pump(0.2)
            f.key(28)
            f.pump(0.2)
            out.append(rec(w.save(f't{k}'), 'Cube'))
        # the press that keeps a transform selects nothing
        f.move(600, 320)
        f.pump(0.1)
        f.key(34)
        f.pump(0.1)
        f.move(610, 330)
        f.pump(0.2)
        f.click(900, 300)
        f.pump(0.2)
        f.key(34)
        f.pump(0.1)
        f.move(640, 340)
        f.pump(0.2)
        f.key(28)
        f.pump(0.2)
        out.append(rec(w.save('t1'), 'Cube'))
        # shift adds; a click on nothing clears; A again
        f.mods(1)
        f.click(900, 300)
        f.mods(0)
        f.pump(0.2)
        f.key(34)
        f.pump(0.1)
        f.move(650, 330)
        f.pump(0.2)
        f.key(28)
        f.pump(0.2)
        out.append(rec(w.save('t'), 'Cube'))
        f.click(40, 700)
        f.pump(0.2)
        f.key(34)
        f.pump(0.1)
        f.move(800, 330)
        f.pump(0.2)
        f.key(1)  # (nothing to confirm: Enter would open the command line)
        f.pump(0.2)
        out.append(rec(w.save('t2'), 'Cube'))
        # a scale from close to the pivot
        f.click(40, 700)
        f.key(30)
        f.pump(0.2)
        v = uvs(out[-1])
        px = 640 + ((min(v[0::2]) + max(v[0::2])) / 2 - 0.5) * 612
        py = 438 - ((min(v[1::2]) + max(v[1::2])) / 2 - 0.5) * 612
        f.move(int(px) + 30, int(py))
        f.pump(0.1)
        f.key(31)
        f.pump(0.1)
        f.move(int(px) + 45, int(py))
        f.pump(0.2)
        f.key(28)
        f.pump(0.2)
        out.append(rec(w.save('t3'), 'Cube'))
        return out
    a = one(run)

    def image(w):
        f = w.f
        p = os.path.join(ROOT, 'tests/files/tex_uv.bee')
        w.line(f'file.open {p}')
        maxi(w)
        f.pump(3.5)
        return body(f.frame, (0, 100, 1100, 770))
    x = one(image)
    check(len({bytes(r) for r in x}) > 5, f'the texture under the layout: {len({bytes(r) for r in x})} kinds of row')
    for n, x in zip(('moved', 'scaled', 'turned', 'kept by a press', 'shift added, moved', 'nothing there: none moves', 'scaled from close by'), a):
        sane(x, n + ': UVs there, finite', square=False)
    check(len(a) == 7, f'{len(a)} states')
    check(a[0] != a[1] and a[1] != a[2] and a[2] != a[3] and a[3] != a[4] and a[5] != a[6], 'each changed something')
    check(a[4] == a[5], 'with nothing selected G does nothing')


def s_ui():
    print('-- the editor\'s controls --')
    port(*ops('area.type_uv_editor'), '--expect-label', 'button:Unwrap', '--expect-label', 'button:Pack', '--expect-label', 'button:Select All', '--expect-label', 'button:No heat map', '--expect-label', 'button:Fit', '--expect-off', 'Unwrap', '--expect-off', 'Pack')
    t = uitext()
    check('UV editor: a mesh with UVs (U unwraps it' in t, 'without UVs it says what to do')
    # greyed in object mode, as the operators refuse there; on in edit mode
    port(*ops('create.cube', 'area.type_uv_editor', 'mode.edit'), '--expect-label', 'button:Unwrap')
    t = uitext()
    check(re.search(r'button\tUnwrap\t.*\ton', t) and re.search(r'button\tPack\t.*\ton', t), 'in edit mode Unwrap and Pack are on')
    port(*ops('create.cube', 'area.type_uv_editor'))
    t = uitext()
    check(re.search(r'button\tUnwrap\t.*\toff', t) is not None, 'in object mode Unwrap is off')
    # clicks: Unwrap and Fit as buttons, the list of heat maps
    port(*ops('area.type_uv_editor', 'mode.edit'), '--click-label', 'button:Unwrap', *dump())
    check(stats().get('hasuv') == '1', 'Unwrap clicked unwraps')
    port(*ops('area.type_uv_editor', 'mode.edit', 'uv.unwrap'), '--click-label', 'button:No heat map', '--click-label', 'menuitem:Angle distortion', *dump())
    check('heat 2' in open(f'{T}/uv.txt').read(), 'the heat list sets it')
    check('button\tAngle distortion' in uitext(), 'and the button says it')
    port(*ops('area.type_uv_editor', 'mode.edit', 'uv.unwrap'), '--move', '600,300', '--click-label', 'button:Select All', *dump())
    check(re.search(r'selected [1-9]', open(f'{T}/uv.txt').read()) is not None, 'Select All selects')
    # the keys go by where the pointer is: over a viewport G is the object's
    port(*ops('create.cube'), '--move', '600,300', '--key', 'g', '--move', '640,300', '--key', 'enter', *dump())
    check(len(steps()) == 2, f'over the viewport G moves the object: {steps()}')
    port(*ops('create.cube', 'area.type_uv_editor', 'mode.edit', 'uv.unwrap'), '--move', '600,300', '--key', 'd', '--key', 'd', *dump())
    check('heat 2' in open(f'{T}/uv.txt').read(), 'D, D over the editor: angle')
    port(*ops('create.cube', 'mode.edit', 'uv.unwrap'), '--move', '600,300', '--key', 'd', *dump())
    check('heat 0' in open(f'{T}/uv.txt').read(), 'D over a viewport is no heat map')
    # U in edit mode, not in object mode
    port(*ops('create.cube'), '--move', '600,300', '--key', 'u', *dump())
    check(stats().get('hasuv') == '0', 'U in object mode does nothing')
    port(*ops('create.cube'), '--move', '600,300', '--key', 'tab', '--key', 'u', *dump())
    check(stats().get('hasuv') == '1', 'U in edit mode unwraps')
    # the Mesh menu's UV part; a narrow area drops its tools rather than spill
    port(*ops('create.cube', 'area.type_uv_editor'), '--size', '500x400', '--expect-label', 'button:Unwrap')
    # the themes' colours (the square, the grid)
    port(*ops('area.type_uv_editor', 'view.theme_nord'))
    check(count_px(f'{T}/u.ppm', 0x333a47) > 10000, 'a theme gives the square its colour')
    # a workspace saved with a UV editor keeps it
    a, b = f'{T}/ws.bee', f'{T}/ws2.bee'
    port(*ops('area.type_uv_editor', f'file.save {a}'))
    _, w = beefile.workspaces(beefile.chunk(a, b'WSPC'))
    check("('leaf', 7, None)" in str([x['tree'] for x in w]), 'the area goes into the file as number 7')
    port(*ops(f'file.open {a}'), '--expect-label', 'button:Fit')
    check('button\tFit' in uitext(), 'and comes back')


def count_px(path, col):
    d = open(path, 'rb').read()
    head = d.split(b'\n', 3)
    w, h = map(int, head[1].split())
    o = len(d) - w * h * 3
    c = bytes([(col >> 16) & 255, (col >> 8) & 255, col & 255])
    n = 0
    k = d.find(c, o)
    while k >= 0:
        if (k - o) % 3 == 0:
            n += 1
        k = d.find(c, k + 1)
    return n


def s_scale():
    print('-- at a fractional scale: a buffer of 150%, the heat map drawn --')

    def run(w):
        f = w.f
        f.scale(150)
        f.pump(0.5)
        w.line('area.type_uv_editor')
        w.line('create.sphere')
        w.line('mode.edit')
        w.line('uv.seams_from_sharp')
        w.line('uv.smart_project')
        f.move(600, 300)
        f.pump(0.2)
        w.line('area.maximize')
        f.pump(0.3)
        f.click(40, 700)
        f.key(32)
        f.pump(3.5)
        h = f.frame[1]
        return f.frame[0], body(f.frame, (0, 160, f.frame[0] // 2, h - 80))
    x = one(run)
    check(x[0] == 1920 and len({bytes(r) for r in x[1]}) > 50, f'150%, the heat map: width {x[0]}, {len({bytes(r) for r in x[1]})} kinds of row')


def s_preview():
    print('-- what shows the UVs follows them: a moved island in Material Preview --')
    p = os.path.join(ROOT, 'tests/files/tex_uv.bee')
    base = [*ops(f'file.open {p}', 'view.shading_material'), '--move', '600,300', *ops('area.split_side'), '--move', '900,300', *ops('area.type_uv_editor'), '--move', '900,300']
    def view():
        d = open(f'{T}/u.ppm', 'rb').read()
        w, h = 1280, 800
        o = len(d) - w * h * 3
        return [d[o + (y * w + 214) * 3:o + (y * w + 500) * 3] for y in range(100, 620)]
    port(*base)
    a = view()
    port(*base, '--key', 'a', '--key', 'g', '--move', '940,340', '--key', 'esc', *dump())
    b = view()
    port(*base, '--key', 'a', '--key', 'g', '--move', '980,340', '--key', 'enter', *dump())
    c = view()
    check(a == b, 'a cancelled move shows the same')
    check(a != c, 'a kept one shows in the viewport')


def s_keys():
    print('-- the keys and the console in a window --')

    def run(w):
        f = w.f
        out = []

        def state(tag):
            r = rec(w.save(tag), 'Cube')
            out.append((tag, None if r is None else (r[0], r[2], r[3])))
        w.line('area.type_uv_editor')
        f.move(600, 300)
        f.pump(0.2)
        # the console in object mode: an operator's own answer, not the menus'
        w.line('uv.seams_from_sharp')
        state('console')
        f.click(40, 700)
        f.move(600, 300)
        f.pump(0.2)
        f.key(22)            # U over the editor, in object mode: no
        f.pump(0.3)
        state('u_object')
        f.click(40, 700)
        f.move(600, 300)
        f.pump(0.2)
        f.key(15)            # Tab over the editor
        f.pump(0.3)
        f.key(22)            # U
        f.pump(0.5)
        state('tab_u')
        f.click(40, 700)
        f.move(600, 300)
        f.pump(0.2)
        f.mods(1)            # Shift+U: smart
        f.key(22)
        f.mods(0)
        f.pump(0.5)
        state('smart')
        w.line('mode.edit')
        w.line('uv.unwrap')
        w.toggle_max()       # (one body in both: pixels are the same UVs)
        f.click(40, 700)
        f.move(600, 300)
        f.pump(0.2)
        f.key(30)            # A; during G: Ctrl+Z and X are the transform's
        f.pump(0.2)
        f.key(34)
        f.pump(0.1)
        f.move(630, 320)
        f.pump(0.2)
        w.undo()
        f.key(45)
        f.pump(0.2)
        f.move(640, 325)
        f.pump(0.2)
        f.key(28)
        f.pump(0.3)
        state('undo_in_g')
        f.key(34)            # the middle button puts it back
        f.pump(0.1)
        f.move(660, 340)
        f.pump(0.2)
        f.click(660, 340, btn=0x112)
        f.pump(0.3)
        state('middle')
        w.undo()             # (the cancelled one's step)
        w.undo()             # (the kept one)
        state('undone')
        return out
    a = one(run)
    check(len(a) == 7, f'{len(a)} states')
    v = dict(a)
    check(v['console'] is not None and v['console'][0] == 2, 'the console marks seams in object mode')
    check(v['u_object'] == v['console'], 'U over the editor in object mode: nothing')
    check(v['tab_u'] is not None and v['tab_u'][0] == 3 and v['tab_u'][2] == v['console'][2], 'Tab, U: unwrapped along the seams')
    check(v['smart'] is not None and v['smart'][0] == 3, 'Shift+U: UVs and seams kept')
    check(v['middle'] == v['undo_in_g'], 'the middle button puts the transform back')
    check(v['undo_in_g'] != v['undone'], 'the transforms moved something')
    check(v['undone'] == v['tab_u'], 'undone twice (the cancelled one, the kept one): the unwrap again')


def s_idle():
    print('-- in a window: an idle editor draws nothing, and an edit is one frame --')
    w = Win(BIN)
    f = w.f
    try:
        maxi(w, 'mode.edit', 'uv.seams_from_sharp', 'uv.unwrap')
        f.click(40, 700)
        f.move(640, 300)

        def still():
            last = -1
            for _ in range(40):
                f.pump(0.1)
                if f.frames == last:
                    break
                last = f.frames
        still()
        n = f.frames
        f.pump(1.2)
        check(f.frames == n, f'idle, the layout shown: {f.frames - n} frames in 1.2 s')
        f.key(32)
        still()
        n = f.frames
        f.pump(1.2)
        check(f.frames == n, f'idle, a heat map on: {f.frames - n} frames in 1.2 s')
        n = f.frames
        f.key(30)
        f.key(34)
        f.move(660, 310)
        f.pump(0.3)
        check(f.frames > n, 'a transform redraws')
        still()
        n = f.frames
        f.pump(1.2)
        check(f.frames == n, f'idle in the middle of a transform: {f.frames - n} frames')
        f.key(1)
    finally:
        w.close()


def s_degenerate():
    print('-- degenerate input: finite, inside, no crash --')
    for kind in ('zero', 'nonmanifold', 'flipped', 'one', 'tri', 'repeat', 'sliver'):
        p = obj(f'{T}/{kind}.obj', kind)
        b = f'{T}/b.bee'
        port(*ops(f'file.import_obj {p}', 'uv.unwrap', 'uv.pack', 'uv.seams_from_sharp', 'uv.smart_project', 'uv.pack', f'file.save {b}'))
        n = beefile.objects(b)[-1]['name']
        r = rec(b, n)
        v = uvs(r)
        check(all(math.isfinite(x) for x in v) and all(-1e-3 <= x <= 1.001 for x in v), f'{kind}: finite, in the square ({min(v):.3f} .. {max(v):.3f})')
    # no polygons at all in the active mesh is not reachable; no object at all is
    port(*ops('object.select_all', 'object.delete', 'uv.unwrap', 'uv.pack', 'uv.seam_mark', 'area.type_uv_editor'), '--move', '600,300', '--key', 'a', '--key', 'g', '--key', 'esc', '--wheel', '1')
    # a big zoom, far pans: lines stay bounded
    r = port(*ops('create.cube', 'area.type_uv_editor', 'mode.edit', 'uv.seams_from_sharp', 'uv.smart_project'), '--move', '640,300', *(['--wheel', '640,300,-1'] * 300), *dump(), '--key', 'd', '--mdrag', '640,300,900,500', '--key', 'd', '--key', 'd', ok=False)
    check(r.returncode == 0 and float(open(f'{T}/uv.txt').read().split('uved view')[1].split()[2]) > 1e10, 'zoomed in 300 steps, heat maps on: it stays up, the zoom went up')
    # far in, the grid's middle lines still cross the view: cut to it, not dropped
    port(*ops('area.type_uv_editor'), '--move', '640,300', *(['--wheel', '640,300,-1'] * 40), '--size', '1280x800')
    check(count_px(f'{T}/u.ppm', 0x3a3f48) > 300, f'zoomed in 40 steps: the lines through the view are there: {count_px(f"{T}/u.ppm", 0x3a3f48)} pixels')
    r = port(*ops('create.cube', 'area.type_uv_editor', 'mode.edit', 'uv.seams_from_sharp', 'uv.smart_project'), '--move', '640,300', *(['--wheel', '640,300,1'] * 300), '--key', 'd', ok=False)
    check(r.returncode == 0, 'zoomed out 300 steps')
    # a huge scale drag: floats leave the screen and come back
    b = f'{T}/b.bee'
    port(*ops('create.cube', 'area.type_uv_editor', 'mode.edit', 'uv.smart_project'), '--move', '640,300', '--key', 'a', '--key', 's', '--move', '640,300', '--move', '32000,32000', '--key', 'enter', *ops(f'file.save {b}'))
    v = uvs(rec(b, beefile.objects(b)[-1]['name']))
    check(all(math.isfinite(x) for x in v), 'scaled from the pivot itself: finite')
    # NaN through the arguments: a bake's distance
    r = port(*ops('create.cube', 'uv.smart_project', 'image.new i 8 8', 'object.bake Cube.001 Cube.001 ao i nan', 'object.bake Cube.001 Cube.001 normal i inf', 'object.bake Cube.001 Cube.001 curvature i -1'), ok=False)
    check(r.returncode == 0, 'bake distance nan, inf, -1: it stays up')


def s_damage():
    print(f'-- damaged MUVS chunks: {RUNS} runs --')
    rng = random.Random(SEED)
    src = f'{T}/d.bee'
    script(f'add("sphere", "S")\nselect("S")\nprint(seams("S", "sharp"))\nprint(unwrap("S"))\nadd("cube", "C")\nprint(seams("C", "sharp"))\nop("file.save", "{src}")\n')
    cs = beefile.chunks(src)
    bad = 0
    for r in range(RUNS):
        out = bytearray(b'BEEM' + struct.pack('<I', 1))
        for t, b in cs:
            d = bytearray(b)
            if t == b'MUVS' and d:
                k = rng.random()
                if k < 0.4:
                    for _ in range(rng.randrange(1, 40)):
                        d[rng.randrange(len(d))] = rng.randrange(256)
                elif k < 0.7:
                    for _ in range(rng.randrange(1, 12)):
                        o = rng.randrange(max(1, len(d) - 3)) & ~3
                        d[o:o + 4] = struct.pack('<I', rng.choice([0x7fc00000, 0x7f800000, 0xff800000, 0xffffffff, 0x10000000, 0x7f7fffff, 1, 3, 5]))
                elif k < 0.85:
                    del d[rng.randrange(len(d)):]
                else:
                    d += bytes(rng.randrange(256) for _ in range(rng.randrange(1, 64)))
            out += t + struct.pack('<I', len(d)) + d
        p = f'{T}/dmg.bee'
        open(p, 'wb').write(out)
        q = port(*ops(f'file.open {p}', 'area.type_uv_editor'), '--select', 'S', '--move', '600,300', '--key', 'd', '--key', 'a', '--key', 'g', '--move', '640,320', '--key', 'enter', '--key', 'd', *ops('mode.edit', 'uv.pack', 'uv.unwrap', 'uv.smart_project', 'uv.seam_mark', 'uv.seam_clear', f'file.save {T}/dmg2.bee'), ok=False)
        if q.returncode != 0:
            bad += 1
            print(q.stderr[-800:])
            open(f'{T}/dmg_fail_{r}.bee', 'wb').write(out)
    check(bad == 0, f'{RUNS} damaged files: {bad} failed')
    # NaN and infinity in the UVs: gone when read
    out = bytearray(b'BEEM' + struct.pack('<I', 1))
    for t, b in cs:
        d = bytearray(b)
        if t == b'MUVS':
            for k, w in enumerate((0x7fc00000, 0x7f800000, 0xff800000)):
                struct.pack_into('<I', d, 12 + 8 * k, w)
        out += t + struct.pack('<I', len(d)) + d
    open(f'{T}/dmg.bee', 'wb').write(out)
    port(*ops(f'file.open {T}/dmg.bee', f'file.save {T}/dmg2.bee'))
    v = [x for r in muvs(f'{T}/dmg2.bee').values() if r[2] for x in uvs(r)]
    check(len(v) > 8 and all(math.isfinite(x) for x in v), 'NaN and inf in a file\'s UVs are not kept')


def pixels(p):
    from PIL import Image
    return Image.open(p).convert('RGB').tobytes()


def s_bake():
    print('-- baking: the same maps from a script as from the operators, one paint step a bake, the form --')
    a = f'{T}/low.bee'
    script(f'add("sphere", "Low")\nadd("cube", "High")\nscale("High", 0.8)\nadd("sphere", "Hi2")\nscale("Hi2", 1.02)\nmove("Hi2", 0.05, 0, 0.02)\nprint(unwrap("Low", "smart"))\nop("file.save", "{a}")\n')
    for high in ('High', 'Hi2'):
        for kind in ('normal', 'ao', 'curvature'):
            po, pp = f'{T}/o_{kind}.png', f'{T}/p_{kind}.png'
            dist = ' 0.6' if high == 'High' else ''
            d0 = ', 0.6' if dist else ''
            r = script(f'op("file.open", "{a}")\nop("image.new", "B 96 96")\nprint("T", bake("Low", "{high}", "{kind}", "B"{d0}))\nop("image.save", "B {po}")\n')
            n0 = [ln.split()[1] for ln in r.splitlines() if ln.startswith('T ')]
            port(*ops(f'file.open {a}', 'image.new B 96 96', f'object.bake Low {high} {kind} B{dist}', f'image.save B {pp}'))
            n1 = [ln.split()[-1] for ln in log() if 'baked texels' in ln]
            x, y = pixels(po), pixels(pp)
            big = max((abs(p - q) for p, q in zip(x, y)), default=0)
            off = sum(p != q for p, q in zip(x, y))
            # (rows run in parallel in both: a texel on an edge between two triangles
            # goes to whichever comes last)
            check(n0 == n1 and len(n1) == 1 and int(n1[0]) > 0 and len(x) == len(y) and off <= len(x) * 0.002, f'{high} {kind}: {n1} texels (the script {n0}), {off} of {len(x)} channels differ, by at most {big}')
            check(len(set(x)) > 1, f'  the map has something in it: {len(set(x))} levels')
    # a hole: occlusion in earnest; a scale of three sizes: world normals
    q = f'{T}/low2.bee'
    script(f'add("torus", "L3")\nprint(unwrap("L3", "smart"))\nadd("torus", "H3")\nadd("sphere", "L4")\nscale("L4", 1, 2, 0.7)\nprint(unwrap("L4", "smart"))\nadd("sphere", "H4")\nscale("H4", 1.1, 1.9, 0.8)\nop("file.save", "{q}")\n')
    for low, high, kind in (('L3', 'H3', 'ao'), ('L3', 'H3', 'curvature'), ('L4', 'H4', 'normal'), ('L4', 'H4', 'ao')):
        po, pp = f'{T}/o2.png', f'{T}/p2.png'
        script(f'op("file.open", "{q}")\nop("image.new", "B 96 96")\nprint("T", bake("{low}", "{high}", "{kind}", "B"))\nop("image.save", "B {po}")\n')
        port(*ops(f'file.open {q}', 'image.new B 96 96', f'object.bake {low} {high} {kind} B', f'image.save B {pp}'))
        x, y = pixels(po), pixels(pp)
        big = max((abs(p - q2) for p, q2 in zip(x, y)), default=0)
        off = sum(p != q2 for p, q2 in zip(x, y))
        check(len(x) == len(y) and big <= 2 and off <= len(x) * 0.02, f'{low} {high} {kind}: {off} of {len(x)} channels differ, by at most {big}')
        check(len(set(x)) > 8, f'  the map has something in it: {len(set(x))} levels')
    print('-- paint.undo after a bake: the image before it --')
    po, pp = f'{T}/ou.png', f'{T}/pu.png'
    code = f'op("file.open", "{a}")\nop("image.new", "B 32 32")\nprint(bake("Low", "Hi2", "normal", "B"))\nprint(bake("Low", "Hi2", "ao", "B"))\nop("paint.undo")\nop("image.save", "B {po}")\n'
    script(code)
    port(*ops(f'file.open {a}', 'image.new B 32 32', 'object.bake Low Hi2 normal B', 'object.bake Low Hi2 ao B', 'paint.undo', f'image.save B {pp}'))
    x, y = pixels(po), pixels(pp)
    check(max(abs(p - q) for p, q in zip(x, y)) <= 8 and sum(p != q for p, q in zip(x, y)) < len(x) * 0.01, 'one undone: the normal map again, from a script as from the operators')
    port(*ops(f'file.open {a}', 'image.new B 32 32', 'object.bake Low Hi2 normal B', f'image.save B {T}/n.png', 'object.bake Low Hi2 ao B', f'image.save B {T}/ao.png', 'paint.undo', f'image.save B {T}/u1.png', 'paint.undo', f'image.save B {T}/u2.png', 'paint.undo', 'paint.redo', 'paint.redo', f'image.save B {T}/r2.png', 'paint.redo'))
    n, ao, u1, u2, r2 = (pixels(f'{T}/{k}.png') for k in ('n', 'ao', 'u1', 'u2', 'r2'))
    check(n != ao and u1 == n and u2 != n and r2 == ao, 'undo, undo, redo, redo: the images as they were')
    l = log()
    check(sum('nothing to undo' in x for x in l) == 1 and sum('nothing to redo' in x for x in l) == 1, 'past the ends it says so')
    # a new bake drops what was undone
    port(*ops(f'file.open {a}', 'image.new B 32 32', 'object.bake Low Hi2 normal B', 'paint.undo', 'object.bake Low Hi2 ao B', 'paint.redo', 'paint.undo', 'paint.undo'))
    check(sum('nothing to redo' in x for x in log()) == 1 and sum('nothing to undo' in x for x in log()) == 1, 'a new bake drops what was undone')
    # ... not the scene's undo
    port(*ops(f'file.open {a}', 'image.new B 8 8', 'object.bake Low Hi2 normal B'), *dump())
    check(len(steps()) <= 1, f'a bake is no scene step: {steps()}')
    print('-- the form --')
    r = port(*ops(f'file.open {a}', 'image.new Bake 32 32'), '--select', 'Low', '--click-label', 'menu:Render', '--click-label', 'menuitem:Bake Maps', '--expect-label', 'text:Low', '--expect-label', 'text:Bake', '--expect-label', 'button:Normal map', '--click-label', 'text:High mesh', '--type', 'Hi2', '--key', 'enter', '--click-label', 'button:Normal map', '--click-label', 'Ambient occlusion', '--click-label', 'button:OK', *ops(f'image.save Bake {T}/f.png'), ok=False)
    check(r.returncode == 0 and any('baked texels' in x for x in log()), f'Render > Bake Maps: {r.stderr[-300:].strip()}')
    script(f'op("file.open", "{a}")\nop("image.new", "Bake 32 32")\nprint(bake("Low", "Hi2", "ao", "Bake"))\nop("image.save", "Bake {T}/fo.png")\n')
    x, y = pixels(f'{T}/fo.png'), pixels(f'{T}/f.png')
    check(len(x) == len(y) and sum(p != q for p, q in zip(x, y)) < len(x) * 0.01, 'and it baked ambient occlusion: as a script\'s bake')


def main():
    print(f'seed {SEED}')
    only = os.environ.get('UV_ONLY', '')
    for s in (s_same, s_stats, s_seams, s_files, s_undo_steps, s_undo, s_transforms, s_look, s_scale, s_preview, s_ui, s_keys, s_idle, s_degenerate, s_damage, s_bake):
        if not only or s.__name__ in only.split(','):
            s()
    print('fails', len(FAILS))
    sys.exit(1 if FAILS else 0)


main()
