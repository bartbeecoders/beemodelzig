#!/usr/bin/env python3
"""BeeScript's sketch builtins (bs_sketch.zig: sketch point line circle arc
rect pt con dof conflicts sx sy sr skinfo) run by BeeModel through --eval:
normal calls, errors, bad names and types, edge values, every argument count
and random sketches each give a clean result or a clean script error (no
crash, panic or timeout); huge or NaN angles answer quickly; the .bee files
(SKCH, the display meshes, CADD) read back; parameters drive dimensions;
undo / redo of console runs.

    python3 tests/bs_sketch.py BIN [runs=60] [seed]
"""
import os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bsboth as B

A = sys.argv + [os.path.join(B.ROOT, 'zig-out-debug/bin/beemodel')] * (len(sys.argv) < 2)
B.setup(A[:2] + ['-'] + A[2:], 60)   # (bsboth: BIN ORIG RUNS SEED; no ORIG)

NAMES = B.table({'sketch'})
B.check(len(NAMES) == 14, f'the table: 14 sketch builtins ({sorted(NAMES)})')

print('-- normal calls --')
S0 = 's = sketch("S", "XY")\n'
for code in [
    S0 + 'print(s, skinfo(s, "points"), dof(s), conflicts(s))',
    S0 + 'print(point(s, 1, 2), point(s, "10mm", "2cm"), sx(s, 1), sy(s, 1), dof(s))',
    S0 + 'print(line(s, 0, 0, 1, 0), line(s, 0, 1), skinfo(s, "entities"), dof(s))',
    S0 + 'print(circle(s, 1, 1, 0.5), sr(s, 0), pt(s, 0, 0), dof(s))',
    S0 + 'print(arc(s, 0, 0, 1, 0, "90deg"), pt(s, 0, 1), pt(s, 0, 2), sx(s, 2), sy(s, 2), sx(s, 1), sy(s, 1))',
    S0 + 'r = rect(s, 0, 0, 2, 1)\nprint(r, dof(s), skinfo(s, "constraints"))\nprint(con(s, "fixed", pt(s, r, 0)), dof(s))\n'
         'print(con(s, "length", r, 3), con(s, "length", r + 1, "1.5m"), dof(s), conflicts(s))\nfor i in 0..8 { print(sx(s, i), sy(s, i)) }',
    S0 + 'c = circle(s, 0, 0, 1)\nprint(con(s, "radius", c, 2), sr(s, c), con(s, "diameter", c, 3), sr(s, c), conflicts(s))',
    S0 + 'a = line(s, 0, 0, 1, 0.1)\nb = line(s, 0, 1, 1, 1.3)\nprint(con(s, "parallel", a, b), con(s, "horizontal", a), dof(s))\n'
         'print(sx(s, 3), sy(s, 3), con(s, "angle", a, b, "30deg"), sy(s, 3), conflicts(s))',
    S0 + 'a = line(s, 0, 0, 1, 0)\nc = circle(s, 0.5, 2, 0.5)\nprint(con(s, "tangent", a, c), sy(s, 4), con(s, "distance", 0, 4, 2), sy(s, 4))',
    S0 + 'a = line(s, 0, 0, 2, 0)\np = point(s, 1, 1)\nprint(con(s, "midpoint", p, a), sx(s, p), sy(s, p), con(s, "online", p, a), sy(s, p))',
    S0 + 'p = point(s, 1, 1)\nq = point(s, 3, 2)\nl = line(s, 0, 0, 0, 1)\nprint(con(s, "symmetric", p, q, l), sx(s, q), sy(s, q))',
    S0 + 'p = point(s, 1, 1)\nq = point(s, 3, 2)\nprint(con(s, "hdistance", p, q, 5), con(s, "vdistance", p, q, "-2m"), sx(s, q), sy(s, q))',
    S0 + 'c = circle(s, 0, 0, 1)\np = point(s, 3, 0)\nprint(con(s, "oncircle", p, c), sx(s, p), con(s, "coincident", 0, p), sx(s, 0))',
    S0 + 'a = line(s, 0, 0, 1, 0)\nb = line(s, 0, 0, 0, 2)\nprint(con(s, "equal", a, b), con(s, "perpendicular", a, b), sy(s, 3), dof(s))',
    'print(sketch("A", "XZ", 1), sketch("A", "YZ", "5cm"), sketch("A", "XY", -2))',
    'print(sketch("cube", "XY"), sketch("S", "XY"), sketch("s", "XY"), sketch("", "XY"), sketch("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123", "XY"), sketch("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123", "XY"))',
    'print(sketch("\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9", "XY"))',
    'param("w", "40mm")\ns = sketch("S", "XY")\nr = rect(s, 0, 0, 1, 1)\ncon(s, "length", r, "w * 2")\nprint(sx(s, 1))\nparam("w", "1m")\nprint(sx(s, 1), sx(s, 2))',
    'op("scene.units", "mm")\ns = sketch("S", "XY")\nprint(point(s, "1cm", 2), sx(s, 0), circle(s, 0, 0, "1in"), sr(s, 0))',
]:
    B.same(code)

print('-- errors: bad names, types, references --')
for code in [
    'print(sketch("S", "xy"))', 'print(sketch("S", ""))', 'print(sketch(1, "XY"))', 'print(sketch("S", nil))',
    'print(sketch("S", "XY", "bogus"))', 'print(sketch("S", "XY", nil))',
    'print(point("Nope", 1, 2))', 'print(point("Cube", 1, 2))', 'print(point(nil, 1, 2))',
    S0 + 'print(point(s, "1 +", 2))', S0 + 'print(point(s, nil, 2))', S0 + 'print(point(s, 1))',
    S0 + 'print(line(s, 0, 1))', S0 + 'print(line(s, 0, 0, 1))', S0 + 'point(s, 0, 0)\nprint(line(s, 0, 0), line(s, 0, -1))',
    S0 + 'print(pt(s, 0, 0))', S0 + 'line(s, 0, 0, 1, 1)\nprint(pt(s, 0, 1), pt(s, 0, 2), pt(s, 0, 3))', S0 + 'circle(s, 0, 0, 1)\nprint(pt(s, 0, 1))',
    S0 + 'print(pt(s, -1, 0))', S0 + 'print(pt(s, "0", 0))',
    S0 + 'print(con(s, "bogus", 0))', S0 + 'print(con(s, "length", 0))', S0 + 'print(con(s, "length", 0, 1, 2, 3, 4))',
    S0 + 'print(con(s, "fixed"))', S0 + 'print(con(s, "coincident", 0, 1, 2, 3))', S0 + 'print(con(s, "radius", 0, "x"))',
    S0 + 'print(con(s, "horizontal", 5))', S0 + 'print(con(s, "horizontal", "a"))', S0 + 'print(con(s, 3, 0))',
    S0 + 'print(sx(s, 0))', S0 + 'print(sy(s, -1))', S0 + 'print(sr(s, 0))', S0 + 'point(s, 0, 0)\nprint(sr(s, 0), sx(s, 1))',
    S0 + 'print(skinfo(s, "bogus"), skinfo(s, ""), skinfo(s, 1))', 'print(skinfo("Cube", "points"))', 'print(dof("S"), conflicts("Nope"))',
]:
    B.same(code)

print('-- edge values --')
for v in ['0', '-0', '1e30', '-1e30', '1e300', 'sqrt(-1)', 'pow(10, 400)', '"0mm"', '1e-30', '2147483648', '-2147483649', '0.99999']:
    B.same(S0 + f'x = {v}\nprint(point(s, x, x), sx(s, 0), circle(s, x, 0, x), sr(s, 0), dof(s), conflicts(s))', f'edge value {v}', quiet=False)
    B.same(S0 + f'x = {v}\nline(s, 0, 0, 1, 1)\nprint(pt(s, x, 0), sx(s, x))', f'edge index {v}')
    B.same(S0 + f'x = {v}\nr = rect(s, 0, 0, 1, 1)\nprint(con(s, "length", r, x), dof(s), conflicts(s), sx(s, 1), sy(s, 2))', f'edge length {v}')
    code = S0 + f'x = {v}\nr = rect(s, 0, 0, 1, 1)\nprint(con(s, "angle", r, r + 1, x), dof(s), conflicts(s), sx(s, 1), sy(s, 2))'
    if v in ('1e30', '-1e30', '1e300', 'pow(10, 400)', '2147483648', '-2147483649', 'sqrt(-1)'):
        # (a huge or NaN angle: the solver must not loop for ever (fsincos out of
        # range; sketch.zig): it answers, and quickly)
        b = B.run(B.BIN, ['--eval', code], timeout=20)
        B.check(b[0] == 0 and len(b[1].split()) == 5, f'edge angle {v}: answers within 20 s: {b!r}')
    else:
        B.same(code, f'edge angle {v}')

print('-- a tangent to a missing entity (the assembly version read entity -1 there and crashed) --')
for code in [S0 + 'print(con(s, "tangent", 0))', S0 + 'line(s, 0, 0, 1, 1)\nprint(con(s, "tangent", 0), dof(s))', S0 + 'print(con(s, "tangent", 6), dof(s))']:
    b = B.run(B.BIN, ['--eval', code])
    B.check(B.clean(b) and b[0] == 0 and b[1].strip(), f'{code[23:]!r}: answers {b[1].strip()!r}' + ('' if B.clean(b) else f' {b!r}'))

print('-- full: 256 points, entities, constraints --')
B.same(S0 + 'for i in 0..300 { k = point(s, i, 0) }\nprint(skinfo(s, "points"))')
B.same(S0 + 'for i in 0..130 { k = line(s, i, 0, i, 1) }\nprint(skinfo(s, "points"))')
B.same(S0 + 'p = point(s, 0, 0)\nfor i in 0..300 { k = con(s, "fixed", p) }\nprint(k)')

print('-- every argument count, junk values --')
B.argcounts(NAMES, 's = sketch("S", "XY")\n')

print('-- the .bee files: SKCH and the display meshes --')
B.files(S0 + 'r = rect(s, 0, 0, 2, 1)\ncon(s, "length", r, "2m")\nc = circle(s, 1, 0.5, 0.2)\na = arc(s, 3, 3, 1, 0, 2)\nt = sketch("T", "XZ", 0.5)\npoint(t, 1, 1)\n'
        'op("file.save", "@OUT")', 'sk1', 'a rectangle, a dimension, a circle, an arc, a second sketch')
B.files('param("w", "3cm")\n' + S0 + 'r = rect(s, 0, 0, 1, 1)\ncon(s, "length", r, "w")\ncon(s, "fixed", 0)\nparam("w", "5cm")\nop("file.save", "@OUT")', 'sk2',
        'parameters drive a dimension')
B.files(S0 + 'point(s, 0, 0)\nop("file.save", "@OUT")\nx = point(s, 1, nil)\nprint(x)', 'sk3', 'a run that fails part way (saved before its error)')

print('-- random sketches --')
CT = ['coincident', 'horizontal', 'vertical', 'parallel', 'perpendicular', 'equal', 'tangent', 'fixed', 'distance', 'hdistance', 'vdistance',
      'radius', 'diameter', 'angle', 'length', 'online', 'oncircle', 'midpoint', 'symmetric']
VALS = {'distance', 'hdistance', 'vdistance', 'radius', 'diameter', 'angle', 'length'}
bad = 0
for k in range(B.RUNS):
    L = [S0]
    for j in range(random.randint(2, 14)):
        w = random.random()
        r = lambda: round(random.uniform(-3, 3), random.choice([0, 1, 3]))
        if w < 0.25:
            L.append(f'print(line(s, {r()}, {r()}, {r()}, {r()}))')
        elif w < 0.35:
            L.append(f'print(circle(s, {r()}, {r()}, {abs(r()) + 0.1}))')
        elif w < 0.45:
            L.append(f'print(arc(s, {r()}, {r()}, {abs(r()) + 0.1}, {r()}, {r()}))')
        elif w < 0.52:
            L.append(f'print(rect(s, {r()}, {r()}, {r()}, {r()}))')
        elif w < 0.6:
            L.append(f'print(point(s, {r()}, {r()}))')
        else:
            t = random.choice(CT)
            refs = ', '.join(str(random.randint(0, 6)) for _ in range(random.randint(1, 3)))
            v = f', {random.choice([r(), chr(34) + str(abs(r())) + "cm" + chr(34), chr(34) + "45deg" + chr(34)])}' if t in VALS else ''
            L.append(f'x = con(s, "{t}", {refs}{v})\nprint(x, dof(s), conflicts(s))')
    L.append('for i in 0..skinfo(s, "points") { print(sx(s, i), sy(s, i)) }\nfor i in 0..skinfo(s, "entities") { print(sr(s, i)) }')
    code = '\n'.join(L)
    ok, b = B.same(code, quiet=True)
    if not ok:
        print(f'         {code!r}')
    bad += not ok
    if not ok and bad > 3:
        break
B.check(bad == 0, f'{B.RUNS} random sketches (lines, circles, arcs, rects, constraints; errors too): clean runs')

print('-- undo / redo of console runs (headless; the window: tests/bs_cad.py) --')
import subprocess, tempfile


def port_log(*ops):
    h = tempfile.mkdtemp(dir=B.T)
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h, XDG_CACHE_HOME=h + '/c', XDG_CONFIG_HOME=h + '/cf', XDG_DATA_HOME=h + '/d', XDG_STATE_HOME=h + '/s')
    a = ['--shot', f'{h}/x.ppm', '--dump-log', f'{h}/log.txt']
    for o in ops:
        a += ['--key', o[1:]] if o.startswith('@') else ['--op', o]
    subprocess.run(['taskset', '-c', B.CPU, B.BIN, *a], env=env, capture_output=True, timeout=120)
    lg = open(f'{h}/log.txt', errors='replace').read().splitlines() if os.path.exists(f'{h}/log.txt') else []
    return [ln.strip() for ln in lg if ln.startswith('  ') and not ln.startswith('  error') and ln.strip() and ln.strip()[0].isdigit()]


got = port_log('s = sketch("S", "XY"); r = rect(s, 0, 0, 1, 1)', 'c = circle("S", 0, 0, 1); con("S", "radius", c, 2); print(skinfo("S", "entities"), skinfo("S", "constraints"), sr("S", c))',
               '@ctrl+z', 'print(skinfo("S", "entities"), skinfo("S", "constraints"), dof("S"))', '@ctrl+shift+z', 'print(skinfo("S", "entities"), skinfo("S", "constraints"), sr("S", 4))',
               '@ctrl+z', '@ctrl+z', 'print(exists("S"), count())')
B.check(got == ['5 9 2', '4 8 4', '5 9 2', '0 3'], f'a run that adds to a sketch: Ctrl+Z takes it all back (the step\'s sketch is not changed in place), Ctrl+Shift+Z redoes it: {got}')

B.finish('bs_sketch')
