#!/usr/bin/env python3
"""BeeScript's signed-distance shapes (bs_sdf.zig: ssphere sbox scyl storus
sgyroid sgrid sunion ssub sisect sshell smove srot sdist smesh sclear) run by
BeeModel through --eval: normal calls, errors, edge values, every argument
count and random shape trees each give a clean result or a clean script error
(no crash, panic or timeout); the .bee files smesh leaves read back.

    python3 tests/bs_sdf.py BIN [runs=60] [seed]
"""
import os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bsboth as B

A = sys.argv + [os.path.join(B.ROOT, 'zig-out-debug/bin/beemodel')] * (len(sys.argv) < 2)
B.setup(A[:2] + ['-'] + A[2:], 60)   # (bsboth: BIN ORIG RUNS SEED; no ORIG)

NAMES = B.table({'sdf'})
B.check(len(NAMES) == 15, 'the table: 15 shape builtins')

P = 'fn d(a) { print(sdist(a, 0, 0, 0), sdist(a, 0.3, -0.2, 0.7), sdist(a, 2, 1, -1), sdist(a, "5cm", 0, "1m")) }\n'
print('-- normal calls --')
for code in [
    P + 'd(ssphere(1))\nd(sbox(1, 2, 3))\nd(sbox(1, 2, 3, 0.2))\nd(scyl(0.5, 2))\nd(storus(1, 0.25))\nd(sgyroid(1, 0.1))\nd(sgrid(1, 0.2))',
    P + 'a = ssphere(1)\nb = sbox(1.5, 1.5, 1.5)\nd(sunion(a, b))\nd(ssub(a, b))\nd(sisect(a, b))\nd(sunion(a, b, 0.2))\nd(ssub(a, b, "1cm"))\nd(sisect(a, b, 0.3))',
    P + 'a = sbox(1, 2, 3)\nd(sshell(a, 0.1))\nd(smove(a, 1, 0.5, -2))\nd(srot(a, 0.3, "45deg", 1))\nd(srot(smove(a, 1, 0, 0), 0, 0, 1.5))',
    'print(ssphere(1), ssphere(2), sclear(), ssphere(3))',
    'print(smesh("Ball", ssphere(1)), verts("Ball"), faces("Ball"), smesh("Ball", 1, 8), verts("Ball.001"))',
    'b = sbox(1, 1, 1, 0.1)\nprint(smesh("Box", b, 16), verts("Box"), faces("Box"), volume("Box"), manifold("Box"))',
    'a = ssub(sbox(2, 2, 2), ssphere(1.2))\nprint(smesh("S", a, 24), verts("S"), faces("S"), volume("S"))',
    'op("scene.units", "mm")\nprint(sdist(ssphere("1cm"), "5mm", 0, 0))',
]:
    B.same(code)

print('-- errors --')
for code in [
    'print(sdist(1, 0, 0, 0))', 'print(sunion(0, 1))', 'a = ssphere(1)\nprint(sunion(0, a))', 'a = ssphere(1)\nprint(sdist(0, 0, 0, 0))', 'a = ssphere(1)\nprint(smesh("Z", 0))', 'a = ssphere(1)\nprint(sunion(a, 2))', 'a = ssphere(1)\nprint(sunion(a, -1))',
    'a = ssphere(1)\nprint(sshell(a + 0.9, 0.1))', 'a = ssphere(1)\nprint(sunion(a, a, "x"))', 'print(ssphere("x"))', 'print(ssphere(nil))',
    'print(sbox(1, 2, "3 *"))', 'print(smesh("A", 0))', 'print(smesh(1, ssphere(1)))', 'print(smesh("A", sgyroid(1, 0.1)))',
    'print(smesh("A", sbox(0, 1, 1)))', 'print(smesh("A", ssphere(-1)))', 'print(smesh("A", ssphere(1), nil))', 'print(smove("a", 0, 0, 0))',
    'a = ssphere(1)\nsclear()\nprint(sdist(a, 0, 0, 0))', 'for i in 0..5000 { a = ssphere(1) }\nprint(a)',
]:
    B.same(code)

print('-- edge values --')
for v in ['0', '-0', '1e30', '-1e30', '1e300', 'sqrt(-1)', '1e-30', '-1', '"0mm"', '3.4e38']:
    B.same(P + f'x = {v}\nd(ssphere(x))\nd(sbox(x, 1, x))\nd(smove(ssphere(1), x, 0, 0))\nd(srot(sbox(1, 2, 3), x, x, 0))\nd(sunion(1, 2, x))', f'edge value {v}')
for c in ['0', '1', '3', '4', '5', '-1', '-100', '513', '2147483648', 'sqrt(-1)', '1e300', '0.5']:
    B.same(f'print(smesh("M", ssphere(1), {c}), verts("M"), faces("M"))', f'smesh cells {c}', timeout=600)

print('-- every argument count, junk values --')
B.argcounts(NAMES, 'a = ssphere(1)\n')

print('-- the .bee files --')
B.files('a = ssub(sbox(2, 2, 2, 0.2), scyl(0.5, 3))\nb = smesh("Part", a, 20)\nmove(b, 1, 2, 3)\nc = smesh("Ring", storus(1, 0.3), 12)\nop("file.save", "@OUT")', 'sd1',
        'two shape meshes, moved')
B.files('c = smesh("G", sisect(sgyroid(0.5, 0.05), sbox(1, 1, 1)), 24)\nop("file.save", "@OUT")', 'sd2', 'a gyroid in a box')

print('-- random shape trees --')
bad = 0
for k in range(B.RUNS):
    L = ['n = 0']
    ids = 0
    for j in range(random.randint(2, 9)):
        r = lambda: round(random.uniform(0.1, 2), random.choice([0, 1, 3]))
        q = lambda: round(random.uniform(-2, 2), random.choice([0, 2]))
        w = random.random()
        if ids == 0 or w < 0.35:
            L.append(random.choice([f'ssphere({r()})', f'sbox({r()}, {r()}, {r()})', f'sbox({r()}, {r()}, {r()}, {r() / 10})', f'scyl({r()}, {r()})',
                                    f'storus({r()}, {r() / 4})', f'sgyroid({r()}, {r() / 10})', f'sgrid({r()}, {r() / 10})']))
        else:
            a, b = random.randint(1, ids), random.randint(1, ids)
            L.append(random.choice([f'sunion({a}, {b})', f'ssub({a}, {b}, {r() / 5})', f'sisect({a}, {b})', f'sshell({a}, {r() / 10})',
                                    f'smove({a}, {q()}, {q()}, {q()})', f'srot({a}, {q()}, {q()}, {q()})']))
        L[-1] = f'print({L[-1]})'
        ids += 1
    for j in range(4):
        L.append(f'print(sdist({ids}, {round(random.uniform(-2, 2), 3)}, {round(random.uniform(-2, 2), 3)}, {round(random.uniform(-2, 2), 3)}))')
    if k % 4 == 0:
        L.append(f'm = smesh("R", {ids}, {random.randint(4, 20)})\nprint(m, verts(m), faces(m))')
    ok, r = B.same('\n'.join(L), quiet=True)
    if ok and r[0] == 0:
        # (each shape prints its id, 1 up; each distance a finite number; a mesh its name, verts, faces)
        w = r[1].split('\n')
        try:
            sane = [int(x) for x in w[:ids]] == list(range(1, ids + 1)) and all(abs(float(x)) < 1e30 for x in w[ids:ids + 4])
            if k % 4 == 0:
                m = w[ids + 4].split()
                sane = sane and len(m) == 3 and int(m[1]) >= 0 and int(m[2]) >= 0
        except (ValueError, IndexError):
            sane = False
        if not sane:
            B.check(False, f'random tree {k}: ids, finite distances, a mesh: {r[1][:300]!r}')
        ok = sane
    bad += not ok
    if not ok and bad > 3:
        break
B.check(bad == 0, f'{B.RUNS} random shape trees: clean runs, ids in order, finite distances')

B.finish('bs_sdf')
