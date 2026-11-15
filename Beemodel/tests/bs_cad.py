#!/usr/bin/env python3
"""BeeScript's CAD builtins (bs_cad.zig: param pad pocket revolve hole shell
fillet chamfer pattern infill feature features fstatus brep nurbscheck area
mass centroid fangle measurement) run by BeeModel through --eval: normal
calls, errors, every argument count, bad names and types, edge values, random
feature trees and the B-rep kernel's queries each give a clean result or a
clean script error (no crash, panic or timeout); the .bee files they save
(the bodies' meshes, CADD: parameters and feature records) read back. In the
window (the fake compositor): a console run is one undo step.

    python3 tests/bs_cad.py BIN [runs=40] [seed]
"""
import os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bsboth as B

A = sys.argv + [os.path.join(B.ROOT, 'zig-out-debug/bin/beemodel')] * (len(sys.argv) < 2)
B.setup(A[:2] + ['-'] + A[2:], 40)   # (bsboth: BIN ORIG RUNS SEED; no ORIG)

NAMES = {k: v for k, v in B.table({'cad', 'modeling'}).items() if k in (
    'param', 'pad', 'pocket', 'revolve', 'hole', 'shell', 'fillet', 'chamfer', 'pattern', 'infill', 'feature', 'features', 'fstatus',
    'brep', 'nurbscheck', 'area', 'mass', 'centroid', 'fangle', 'measurement')}
B.check(len(NAMES) == 20, 'the table: 20 CAD builtins')


# ---- the window: a run is one undo step (features, sketches, parameters, shapes) ----------

def window():
    print('-- the window: console runs, Ctrl+Z / Ctrl+Shift+Z, a failing run --')
    import bscript as W   # (its PortWin: BeeModel under the fake compositor)
    W.CPU = int(B.CPU)
    p = None
    try:
        p = W.PortWin()
        steps = [
            ('line', 's = sketch("S", "XY"); r = rect(s, -1, -1, 2, 2); p = pad("Body", s, 1)'), ('save', 'w1'),
            ('line', 'param("t", "2m"); feature(p, 0, "t"); con(s, "length", r, 3); c = circle(s, 0, 0, 0.3)'), ('save', 'w2'),
            ('key', 1), ('undo',), ('save', 'w3'),
            ('redo',), ('save', 'w4'),
            ('line', 'q = pocket("Body", s, 0.5); x = 1 + nil; q = pocket("Body", s, 0.2)'), ('save', 'w5'),
            ('key', 1), ('undo',), ('save', 'w6'),
            ('line', 'm = modifier("Body", "array"); modset("Body", m, "count", 3); b = smesh("Ball", ssphere(1), 8)'), ('save', 'w7'),
            ('key', 1), ('undo',), ('save', 'w8'),
            ('line', 'm = modifier("Body", "mirror"); modapply("Body", m); boolean("Body", "Cube", "union")'), ('save', 'w9'),
            ('key', 1), ('undo',), ('save', 'w10'),
        ]
        for st in steps:
            if st[0] == 'line':
                p.line(st[1])
            elif st[0] == 'key':
                p.key(st[1])
            elif st[0] == 'undo':
                p.key(44, 4)
                p.f.pump(0.5)
            elif st[0] == 'redo':
                p.key(44, 5)
                p.f.pump(0.5)
            elif st[0] == 'save':
                p.line(f'file.save_as {B.T}/{st[1]}_p.bee')
                p.key(1)
        for tag, what in (('w1', 'a sketch and a pad typed in the console'), ('w2', 'a parameter, a feature value, a dimension, a circle'),
                          ('w3', 'Ctrl+Z: that run undone, one step'), ('w4', 'Ctrl+Shift+Z: redone'),
                          ('w5', 'a run stopped by its error: the pocket before it stays'), ('w6', 'Ctrl+Z: the failing run undone as one step'),
                          ('w7', 'a modifier, a value, a shape mesh'), ('w8', 'Ctrl+Z: gone'), ('w9', 'a modifier applied, a boolean'), ('w10', 'Ctrl+Z: back')):
            try:
                ok = B.scene(f'{B.T}/{tag}_p.bee') is not None
            except Exception as e:  # noqa: BLE001 (a missing or damaged file is the finding)
                ok, what = False, f'{what} ({e!r})'
            B.check(ok, f'{tag}: {what}: saved, reads back')
        def objs(t):
            # (SKCH keeps how many hold a sketch, UIDS the next id: move on)
            r, x = B.scene(f'{B.T}/{t}_p.bee')
            return r, {k: v for k, v in x.items() if k not in (b'SKCH', b'UIDS')}
        for a, b, what in (('w1', 'w3', 'undo'), ('w2', 'w4', 'redo'), ('w4', 'w6', 'the failing run\'s undo'), ('w6', 'w8', 'the shapes\' undo'), ('w8', 'w10', 'the boolean\'s undo')):
            B.check(objs(a) == objs(b), f'{b} is {a} again ({what}: objects, meshes, CADD, MODS)')
        for a, b in (('w1', 'w2'), ('w4', 'w5'), ('w6', 'w7'), ('w8', 'w9')):
            B.check(objs(a) != objs(b), f'{b}: the run changed the scene (a control: undo has something to undo)')
    except Exception as e:
        B.check(False, f'the window: {e!r}')
    finally:
        if p:
            p.close()
        import shutil
        shutil.rmtree(W.T, True)


if os.environ.get('BS_WINONLY'):
    window()
    B.finish('bs_cad')


SK = 's = sketch("S", "XY")\nr = rect(s, -1, -1, 2, 2)\nc = sketch("C", "XY", 1)\ncircle(c, 0, 0, 0.3)\n'
ST = 'fn st() { for i in 0..features() { print(i, fstatus(i)) }\n print(verts("Body"), faces("Body"), volume("Body")) }\n'
print('-- parameters --')
for code in [
    'print(param("w", 3), param("w"), param("h", "w * 2 + 1cm"), param("h"))',
    'print(param("w", 1.23456), param("w", -0.0004), param("w", 1e9), param("w", "1in"))',
    'print(param("w"))', 'print(param("1w", 1))', 'print(param("sin", 1))', 'print(param("w", "1 +"))', 'print(param("w", nil))',
    'param("a", "b")', 'param("a", 1)\nparam("b", "a")\nprint(param("a", "b"))', 'print(param(1))', 'print(param("", 1))',
    'for i in 0..70 { x = param("p" + i, i) }\nprint(x)', 'print(param("abcdefghijklmnopqrstuvwxyz", 1))',
    'op("scene.units", "mm")\nprint(param("w", "2cm"), param("w", 5))',
]:
    B.same(code)

print('-- features: normal calls --')
for code in [
    SK + ST + 'print(pad("Body", s, 1))\nst()\nprint(pocket("Body", c, 0.5))\nst()',
    SK + ST + 'print(pad("Body", s, "50cm", "symmetric"), pocket("Body", c, 1, "through"), pad("Body", c, 0.2, "reverse"), pad("Body", c, 0.1, "normal"))\nst()',
    SK + ST + 'p = pad("Body", s, 1)\nprint(hole("Body", c, 0.1), hole("Body", c, 0.1, 0.3))\nst()',
    SK + ST + 'p = pad("Body", s, 1)\nprint(shell("Body", p, 0.1), shell("Body", p, "2cm", "bottom"))\nst()',
    SK + ST + 'p = pad("Body", s, 1)\nprint(fillet("Body", 0.1), fillet("Body", 0.05, "vertical"), chamfer("Body", "1cm", "top"))\nst()',
    SK + ST + 'p = pad("Body", c, 1)\nprint(pattern("Body", p, 3, 1, "x"), pattern("Body", p, 4, 0, "z", "circular"), pattern("Body", p, 2, "1m", "y", "linear"))\nst()',
    SK + ST + 'p = pad("Body", s, 1)\nq = shell("Body", p, 0.1)\nprint(infill("Body", q, "grid", 0.5, 0.05))\nst()',
    'u = sketch("U", "XZ")\nrect(u, 0.5, 0, 0.5, 1)\n' + ST + 'print(revolve("Body", u, "360deg"), revolve("Body", u, 1, "v"), revolve("Body", u, "90deg", "z"))\nst()',
    SK + ST + 'param("d", "1m")\np = pad("Body", s, "d")\nst()\nparam("d", "2m")\nst()\nprint(feature(p, 0, 3), feature(p, 0, "d / 2"), feature(p, 3, 1))\nst()\nprint(feature(p, 3, 0))\nst()',
    SK + 'print(features(), fstatus(0), fstatus(-1), fstatus(99), fstatus(sqrt(-1)))',
    SK + ST + 'print(pad("Body", c, 1), pad("Body.001", c, 1), pad("Cube", s, 0.5))\nst()\nprint(count(), name(count() - 1))',
    SK + 'print(pad("body", c, 1), pad("BODY", c, 1), pad("", c, 1), pad("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123", c, 1), pad("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123", c, 1))\nfor i in 0..count() { print(name(i)) }',
]:
    B.same(code, timeout=600)

print('-- features: errors --')
for code in [
    SK + 'print(pad("Body", "Nope", 1))', SK + 'print(pad("Body", "Cube", 1))', SK + 'print(pad("Body", s, "1 +"))', SK + 'print(pad("Body", s, nil))',
    SK + 'print(pad("Body", s, 1, "sideways"))', SK + 'print(pad("Light", s, 1))', SK + 'print(pad("S", s, 1))', SK + 'print(pad(nil, s, 1))',
    SK + 'print(pad("Body", s, "1.000000000000000000000000000001"))', SK + 'print(pad("Body", s, "01234567890123456789012345678901"))',
    SK + 'print(revolve("Body", s, 1, "x"), revolve("Body", s, 1, "q"))', SK + 'print(hole("Body", s, 1, "x"))', SK + 'print(hole("Body", s, 1, nil))',
    SK + 'print(shell("Body", "0", 1))', SK + 'print(shell("Body", 0, 1, "top"))', SK + 'print(fillet("Body", 1, "sides"))',
    SK + 'print(pattern("Body", 0, 3, 1, "w"))', SK + 'print(pattern("Body", 0, 3, 1, "x", "spiral"))', SK + 'print(infill("Body", 0, "foam", 1, 1))',
    SK + 'print(feature(0, 0, 1))', SK + 'pad("Body", s, 1)\nprint(feature(0, 4, 1), feature(0, -1, 1))', SK + 'pad("Body", s, 1)\nprint(feature(1, 0, 1))',
    SK + 'pad("Body", s, 1)\nprint(feature(0, 0, "zz"))', SK + 'pad("Body", s, 1)\nprint(feature(0, 3, "1"), fstatus(0))',
    SK + 'pad("Body", s, 1)\nprint(feature(0, 3, sqrt(-1)), fstatus(0), feature(0, 3, -1), fstatus(0))',
    SK + 'for i in 0..70 { k = pad("Body", s, 0.1) }\nprint(k)',
]:
    B.same(code, timeout=600)

print('-- mass properties, faces, measuring, the kernel --')
for code in [
    'print(area("Cube"), mass("Cube"), centroid("Cube", "x"), centroid("Cube", 1), centroid("Cube", "z"))',
    'move("Cube", 1, 2, 3)\nscale("Cube", 2, 1, 0.5)\nrotate("Cube", 0.3, 0.2, 0.1)\nprint(area("Cube"), mass("Cube"), centroid("Cube", "x"), centroid("Cube", "y"), centroid("Cube", 2))',
    'op("scene.units", "mm")\nprint(area("Cube"), mass("Cube"))', 'add("sphere", "B")\nprint(area("B"), mass("B"), centroid("B", 0))',
    'print(centroid("Cube", "w"))', 'print(centroid("Cube", 3))', 'print(centroid("Cube", "{"))', 'print(centroid("Cube", -1))', 'print(centroid("Cube", ""))', 'print(area("Light"))', 'print(mass("Nope"))',
    'print(fangle("Cube", 0, 1), fangle("Cube", 0, 0), fangle("Cube", 0, 2), fangle("Cube", 5, 3))', 'print(fangle("Cube", 0, 6))', 'print(fangle("Cube", -1, 0))',
    'print(fangle("Light", 0, 0))', 'print(fangle("Cube", "0", 0))',
    'print(measurement())',
    'for k in 0..8 { print(k, nurbscheck(k)) }', 'print(nurbscheck(-1), nurbscheck(99), nurbscheck(sqrt(-1)))',
    'print(brep("Cube", "kernel"), brep("Cube", "volume"), brep("Cube", "faces"), brep("Cube", "bogus"))', 'print(brep("Nope", "kernel"))', 'print(brep("Cube", 1))',
    SK + 'op("cad.kernel", "on")\np = pad("Body", s, 1)\nq = pocket("Body", c, 0.5)\n' + ''.join(f'print("{w}", brep("Body", "{w}"))\n' for w in ["volume", "area", "faces", "edges", "vertices", "loops", "valid", "kernel", "triangles", "watertight", "planes", "cylinders", "cones", "spheres", "tori", "nurbs", "error", "tessvolume"]),
]:
    B.same(code, timeout=600)

print('-- edge values --')
for v in ['0', '-0', '1e30', '-1e30', 'sqrt(-1)', '1e-30', '-1', '2147483648', '"0mm"']:
    B.same(SK + ST + f'x = {v}\nprint(pad("Body", s, x))\nprint(pattern("Body", 0, x, x, "x"))\nprint(fillet("Body", x))\nprint(shell("Body", x, x))\nst()', f'feature edge value {v}', timeout=600)
    B.same(f'x = {v}\nprint(fstatus(x), nurbscheck(x))\nprint(feature(x, x, 1))', f'index edge value {v}')

print('-- every argument count, junk values --')
B.argcounts(NAMES, SK)

print('-- the .bee files: bodies, CADD --')
B.files(SK + 'param("t", "1m")\np = pad("Body", s, "t")\nq = pocket("Body", c, "t / 2")\nf = fillet("Body", 0.05, "top")\nop("file.save", "@OUT")', 'cd1',
        'a pad on a parameter, a pocket, a fillet')
B.files(SK + 'p = pad("Body", c, 1)\npattern("Body", p, 5, 0, "z", "circular")\nfeature(0, 0, 2)\nfeature(1, 3, 1)\nop("file.save", "@OUT")', 'cd2',
        'a circular pattern, a value changed, one suppressed')
B.files(SK + 'p = pad("Body", s, 1)\nq = shell("Body", p, 0.1)\ninfill("Body", q, "gyroid", 0.6, 0.05)\nop("file.save", "@OUT")', 'cd3', 'shell and gyroid infill')
B.files(SK + 'p = pad("Body", s, 1)\nop("file.save", "@OUT")\nx = pad("Body", s, nil)\nprint(x)', 'cd4', 'a run that fails part way (saved before its error)')
B.files(SK + 'op("cad.kernel", "on")\np = pad("Body", s, 1)\nq = hole("Body", c, 0.2)\nchamfer("Body", 0.05)\nop("file.save", "@OUT")', 'cd5', 'with the B-rep kernel on')

print('-- random feature trees --')
bad = 0
for k in range(B.RUNS):
    L = [SK, 'u = sketch("U", "XZ")\nrect(u, 0.5, 0, 0.5, 1)']
    if k % 3 == 0:
        L.append('op("cad.kernel", "on")')
    nf = 0
    for j in range(random.randint(1, 5)):
        v = random.choice(['1', '0.5', '"20cm"', '0.25', '2'])
        w = random.random()
        if nf == 0 or w < 0.3:
            L.append(f'print(pad("Body", {random.choice(["s", "c"])}, {v}, "{random.choice(["normal", "symmetric", "reverse"])}"))')
        elif w < 0.45:
            L.append(f'print(pocket("Body", c, {v}, "{random.choice(["normal", "through", "reverse"])}"))')
        elif w < 0.55:
            L.append(f'print(hole("Body", c, 0.1{random.choice(["", ", 0.3"])}))')
        elif w < 0.65:
            L.append(f'print({random.choice(["fillet", "chamfer"])}("Body", {random.choice(["0.05", "0.1"])}, "{random.choice(["all", "vertical", "horizontal", "top", "bottom"])}"))')
        elif w < 0.75:
            L.append(f'print(shell("Body", {random.randint(0, nf - 1)}, 0.1, "{random.choice(["normal", "bottom"])}"))')
        elif w < 0.85:
            L.append(f'print(pattern("Body", {random.randint(0, nf - 1)}, {random.randint(1, 4)}, {random.choice(["1.5", "0"])}, "{random.choice("xyz")}", "{random.choice(["linear", "circular"])}"))')
        elif w < 0.92:
            L.append(f'print(revolve("Body", u, "{random.choice(["90deg", "360deg", "180deg"])}"))')
        else:
            L.append(f'print(feature({random.randint(0, nf - 1)}, {random.randint(0, 3)}, {random.choice(["0", "1", "0.3"])}))')
        nf += 1
    L.append('for i in 0..features() { print(i, fstatus(i)) }\nprint(verts("Body"), faces("Body"), volume("Body"), area("Body"), mass("Body"), brep("Body", "faces"))')
    L.append('op("file.save", "@OUT")')
    ok = B.files('\n'.join(L), f'rf{k}', f'random tree {k}', quiet=True)
    bad += not ok
    if not ok and bad > 3:
        break
B.check(bad == 0, f'{B.RUNS} random feature trees (output, meshes, CADD; a third with the kernel on): clean runs, read back')

if not os.environ.get('BS_NOWIN'):
    window()

B.finish('bs_cad')
