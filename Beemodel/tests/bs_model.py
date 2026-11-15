#!/usr/bin/env python3
"""BeeScript's modelling builtins (bs_model.zig: modifier modset modapply
modremove modcount boolean manifold analyze thinnest) run by BeeModel through
--eval: modifiers, booleans, errors, bad names and types, edge values, every
argument count and random modifier stacks each give a clean result or a clean
script error (no crash, panic or timeout); the .bee files they save (MODS,
the meshes after apply / boolean) read back.

    python3 tests/bs_model.py BIN [runs=40] [seed]
"""
import os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bsboth as B

A = sys.argv + [os.path.join(B.ROOT, 'zig-out-debug/bin/beemodel')] * (len(sys.argv) < 2)
B.setup(A[:2] + ['-'] + A[2:], 40)   # (bsboth: BIN ORIG RUNS SEED; no ORIG)

NAMES = {k: v for k, v in B.table({'modeling'}).items() if k not in ('infill',)}
B.check(len(NAMES) == 9, f'the table: 9 modelling builtins ({sorted(NAMES)})')

print('-- modifiers --')
for code in [
    'print(modifier("Cube", "subsurf"), modcount("Cube"), everts("Cube"), efaces("Cube"))',
    'print(modifier("Cube", "MIRROR"), modifier("Cube", "array x"), modifier("Cube", "Bevel"), modcount("Cube"), everts("Cube"))',
    'm = modifier("Cube", "array")\nprint(modset("Cube", m, "count", 3), everts("Cube"), modset("Cube", m, 1, 2.5), modset("Cube", m, "y", -1), everts("Cube"), efaces("Cube"))',
    'm = modifier("Cube", "subsurf")\nprint(modset("Cube", m, "levels", 9), everts("Cube"), modset("Cube", m, "levels", 1.5), everts("Cube"), modset("Cube", m, "levels", 2.5), everts("Cube"))',
    'm = modifier("Cube", "subsurf")\nprint(modset("Cube", m, "LEVELS", 1), modset("Cube", m, "levels x", 1), modset("Cube", m, "0", 2), modset("Cube", m, "07", 1), everts("Cube"))',
    'm = modifier("Cube", "subsurf")\nmodset("Cube", m, "levels", 1)\nprint(modapply("Cube", m), modcount("Cube"), verts("Cube"), faces("Cube"))',
    'modifier("Cube", "subsurf")\nmodifier("Cube", "mirror")\nmodifier("Cube", "solidify")\nprint(modremove("Cube", 1), modcount("Cube"), modapply("Cube", 1), modcount("Cube"), verts("Cube"))',
    'add("cube", "B", 1, 0, 0)\nm = modifier("Cube", "boolean")\nprint(modset("Cube", m, "object", "B"), modset("Cube", m, "operation", 0), everts("Cube"), efaces("Cube"))',
    'add("sphere", "S")\nm = modifier("S", "decimate")\nmodset("S", m, "ratio", 0.3)\nprint(everts("S"), modapply("S", 0), verts("S"))',
    'm = modifier("Cube", "remesh")\nmodset("Cube", m, "voxel", 0.5)\nprint(everts("Cube"), efaces("Cube"))',
    'for i in 0..9 { print(modifier("Cube", "mirror")) }',
]:
    B.same(code, timeout=600)

print('-- modifier errors --')
for code in [
    'print(modifier("Cube", "warp"))', 'print(modifier("Cube", ""))', 'print(modifier("Cube", "mirrors"))', 'print(modifier("Light", "mirror"))',
    'print(modifier("Nope", "mirror"))', 'print(modifier(1, "mirror"))', 'print(modifier("Cube", 1))',
    'print(modset("Cube", 0, "levels", 1))', 'modifier("Cube", "subsurf")\nprint(modset("Cube", 0, "width", 1))', 'modifier("Cube", "subsurf")\nprint(modset("Cube", 0, 5, 1))',
    'modifier("Cube", "subsurf")\nprint(modset("Cube", 0, -1, 1))', 'modifier("Cube", "subsurf")\nprint(modset("Cube", 1, 0, 1))', 'modifier("Cube", "subsurf")\nprint(modset("Cube", -1, 0, 1))',
    'modifier("Cube", "subsurf")\nprint(modset("Cube", 0, 0, "Nope"))', 'modifier("Cube", "subsurf")\nprint(modset("Cube", 0, 0, nil))', 'modifier("Cube", "subsurf")\nprint(modset("Cube", 0, nil, 1))',
    'modifier("Cube", "subsurf")\nprint(modset("Cube", "0", 0, 1))', 'modifier("Cube", "subsurf")\nprint(modset("Cube", 0, "9", 1))', 'modifier("Cube", "subsurf")\nprint(modset("Cube", 0, "", 1))',
    'print(modapply("Cube", 0))', 'print(modremove("Cube", 0))', 'modifier("Cube", "mirror")\nprint(modapply("Cube", 1), modremove("Cube", -1))', 'print(modcount("Light"))',
    'print(modapply("Cube", "0"))', 'print(modremove(nil, 0))',
]:
    B.same(code)

print('-- boolean, manifold, analyze, thinnest --')
for code in [
    'add("cube", "B", 1, 1, 0)\nboolean("Cube", "B", "union")\nprint(count(), verts("Cube"), faces("Cube"), manifold("Cube"), volume("Cube"))',
    'add("sphere", "B", 1, 0, 0)\nboolean("Cube", "B", "difference")\nprint(count(), verts("Cube"), faces("Cube"), manifold("Cube"), volume("Cube"))',
    'add("cylinder", "B")\nscale("B", 0.5, 0.5, 2)\nboolean("Cube", "B", "intersect")\nprint(count(), verts("Cube"), faces("Cube"), volume("Cube"))',
    'add("cube", "B", 1, 1, 0)\nboolean("Cube", "B", "union keep")\nprint(count(), faces("Cube"))', 'add("cube", "B", 1, 1, 0)\nboolean("Cube", "B", "Subtract")\nprint(count(), faces("Cube"))',
    'add("cube", "B", 1, 1, 0)\nboolean("Cube", "B", "xor")\nprint(count(), faces("Cube"))', 'add("cube", "B", 1, 1, 0)\nboolean("Cube", "B", "Intersect, keep")\nprint(count(), faces("Cube"))',
    'add("cube", "B", 1, 1, 0)\nboolean("Cube", "B", "unionkeep")\nprint(count(), faces("Cube"))', 'add("cube", "B", 1, 1, 0)\nboolean("Cube", "B", " difference")\nprint(count(), faces("Cube"))', 'add("cube", "B", 1, 1, 0)\nboolean("Cube", "B", 1)\nprint(count(), faces("Cube"))',
    'print(boolean("Cube", "Nope", "union"))', 'print(boolean("Nope", "Cube", "union"))', 'print(boolean("Cube", "Light", "union"), count())',
    'print(boolean("Cube", "Cube", "union"), count(), faces("Cube"))',
    'print(manifold("Cube"))', 'add("plane", "P")\nprint(manifold("P"), analyze("P", "boundary"), analyze("P", "loose"))', 'print(manifold("Light"))',
    'for w in 0..1 { print(analyze("Cube", "boundary"), analyze("Cube", "nonmanifold"), analyze("Cube", "degenerate"), analyze("Cube", "loose"), analyze("Cube", "overhang")) }',
    'rotate("Cube", 0.7, 0.2, 0)\nprint(analyze("Cube", "overhang"))', 'add("sphere", "S")\nprint(analyze("S", "overhang"), analyze("S", "degenerate"))',
    'print(analyze("Cube", "holes"))', 'print(analyze("Cube", ""))', 'print(analyze("Light", "loose"))', 'print(analyze("Light", "bogus"))', 'print(analyze("Cube", 1))',
    'print(thinnest("Cube"))', 'scale("Cube", 0.1, 1, 1)\nprint(thinnest("Cube"))', 'add("plane", "P")\nprint(thinnest("P"))', 'add("sphere", "S", 3, 0, 0)\nprint(thinnest("S"))',
    'print(thinnest("Light"))', 'smesh("Ball", ssphere(1), 10)\nprint(thinnest("Ball"), manifold("Ball"))',
    'vmove("Cube", 0, 0, 0, 0)\nprint(manifold("Cube"), analyze("Cube", "degenerate"), thinnest("Cube"))',
    'vmove("Cube", 0, 1, -1, -1)\nvmove("Cube", 3, 1, -1, -1)\nprint(analyze("Cube", "degenerate"), analyze("Cube", "loose"), analyze("Cube", "nonmanifold"), manifold("Cube"))',
]:
    B.same(code, timeout=600)

print('-- edge values --')
for v in ['0', '-0', '1e30', '-1e30', 'sqrt(-1)', '1e-30', '-1', '2147483648', '0.5', '1.5', '2.5', '-2.5', '3.4e38', '1e39']:
    B.same(f'x = {v}\nfor t in 0..1 {{ m = modifier("Cube", "array") }}\nmodset("Cube", 0, 0, x)\nmodset("Cube", 0, 1, x)\nprint(everts("Cube"))\nprint(modset("Cube", x, 0, 1))', f'array values {v}', timeout=600)
    B.same(f'x = {v}\nm = modifier("Cube", "mirror")\nmodset("Cube", 0, "axis", x)\nmodset("Cube", 0, "merge", x)\nprint(everts("Cube"), efaces("Cube"))\nprint(modapply("Cube", x))', f'mirror values {v}', timeout=600)

print('-- every argument count, junk values --')
B.argcounts(NAMES, 'add("cube", "B", 1, 1, 0)\n')

print('-- the .bee files --')
B.files('m = modifier("Cube", "array")\nmodset("Cube", m, "count", 4)\nmodifier("Cube", "bevel")\nmodset("Cube", 1, "segments", 3)\nadd("cube", "B", 1, 0, 0)\n'
        'b = modifier("Cube", "boolean")\nmodset("Cube", b, "object", "B")\nop("file.save", "@OUT")', 'md1', 'a stack: array, bevel, boolean on an object')
B.files('modifier("Cube", "subsurf")\nmodifier("Cube", "mirror")\nmodapply("Cube", 0)\nmodremove("Cube", 0)\nop("file.save", "@OUT")', 'md2', 'apply then remove')
B.files('add("sphere", "B", 0.5, 0.5, 0.5)\nboolean("Cube", "B", "difference")\nop("file.save", "@OUT")', 'md3', 'a boolean difference (B used up)')

print('-- random modifier stacks --')
KINDS = {'mirror': ['axis', 'merge'], 'array': ['count', 'x', 'y', 'z'], 'solidify': ['thickness'], 'subsurf': ['levels'], 'bevel': ['width', 'segments', 'angle'],
         'decimate': ['ratio'], 'remesh': ['voxel']}
bad = 0
for k in range(B.RUNS):
    L = [random.choice(['', 'add("sphere", "Cube.S")\ndelete("Cube")\nrename("Cube.S", "Cube")\n', 'smesh("Cube.M", ssphere(1), 6)\ndelete("Cube")\nrename("Cube.M", "Cube")\n'])]
    n = 0
    for j in range(random.randint(1, 4)):
        t = random.choice(list(KINDS))
        L.append(f'print(modifier("Cube", "{t}"))')
        p = random.choice(KINDS[t])
        val = {'count': random.randint(1, 3), 'levels': random.randint(0, 2), 'segments': random.randint(1, 3), 'axis': random.randint(0, 2),
               'voxel': random.choice([0.3, 0.5]), 'ratio': random.choice([0.3, 0.7])}.get(p, round(random.uniform(-0.5, 1.5), 2))
        L.append(f'print(modset("Cube", {n}, "{p}", {val}))')
        n += 1
    L.append('print(everts("Cube"), efaces("Cube"), modcount("Cube"))')
    if random.random() < 0.5:
        L.append(f'print(modapply("Cube", {random.randint(0, n - 1)}), verts("Cube"), faces("Cube"), modcount("Cube"), manifold("Cube"), analyze("Cube", "boundary"))')
    L.append('op("file.save", "@OUT")')
    code = '\n'.join(L)
    # (the assembly version crashed on some stacks - e.g. bevel, decimate,
    # bevel, remesh on a shape mesh; BeeModel must just answer)
    ok = B.files(code, f'rm{k}', f'random stack {k}', quiet=True)
    if not ok:
        print(f'         {code!r}')
    bad += not ok
    if not ok and bad > 3:
        break
B.check(bad == 0, f'{B.RUNS} random modifier stacks (evaluated, applied, saved): clean runs, read back')

B.finish('bs_model')
