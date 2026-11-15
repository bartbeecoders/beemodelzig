#!/usr/bin/env python3
"""Random calls of the CAD, sketch, shape and modelling builtins (bs_cad.zig,
bs_sketch.zig, bs_sdf.zig, bs_model.zig) with random arguments - numbers
(NaN, huge, negative, fractions), texts (names that exist, that do not,
expressions, empty), nil - in long scripts. On BeeModel (debug build): no
panic, no crash, no hang, nothing but print lines and its one error line.
Console runs that make and drop all of these: the memory does not grow.

    python3 tests/bs_cad_fuzz.py BIN [runs=400] [seed]
"""
import os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bsboth as B

A = sys.argv + [os.path.join(B.ROOT, 'zig-out-debug/bin/beemodel')] * (len(sys.argv) < 2)
B.setup(A[:2] + ['-'] + A[2:], 400)   # (bsboth: BIN ORIG RUNS SEED; no ORIG)

NAMES = B.table({'cad', 'sketch', 'sdf', 'modeling'})
B.check(len(NAMES) == 58, f'58 builtins in these areas ({len(NAMES)})')

WORDS = ['"S"', '"T"', '"Body"', '"Cube"', '"Light"', '"Ball"', '"Nope"', '""', '"XY"', '"XZ"', '"YZ"', '"length"', '"angle"', '"tangent"', '"fixed"',
         '"coincident"', '"radius"', '"horizontal"', '"symmetric"', '"through"', '"reverse"', '"bottom"', '"x"', '"z"', '"v"', '"circular"', '"grid"',
         '"gyroid"', '"all"', '"top"', '"mirror"', '"array"', '"subsurf"', '"bevel"', '"boolean"', '"count"', '"levels"', '"object"', '"0"', '"9"',
         '"union"', '"difference"', '"boundary"', '"loose"', '"overhang"', '"points"', '"entities"', '"10mm"', '"90deg"', '"w * 2"', '"1 +"', '"1e40"',
         '"volume"', '"faces"', '"kernel"', '"w"', '"a b"']
NUMS = ['0', '1', '2', '3', '-1', '0.5', '-0.25', '7', '64', '255', '256', '1e9', '-1e9', '1e30', '1e-30', 'sqrt(-1)' , '2147483648', '-2147483649', '1.5',
        'pow(10, 400)', '-pow(10, 400)', '0.001', '100']


def arg():
    w = random.random()
    if w < 0.45:
        return random.choice(WORDS)
    if w < 0.95:
        return random.choice(NUMS)
    return 'nil'


def script():
    L = ['x = sketch("S", "XY")', 'r = rect("S", -1, -1, 2, 2)', 'y = pad("Body", "S", 1)', 'param("w", 2)']
    names = sorted(NAMES)
    for k in range(random.randint(1, 8)):
        nm = random.choice(names)
        mn, mx = NAMES[nm]
        n = random.randint(mn, mx)
        a = [arg() for _ in range(n)]
        L.append(f'print({nm}({", ".join(a)}))')
    return '\n'.join(L)


for k in range(B.RUNS):
    code = script()
    b = B.run(B.BIN, ['--eval', code], timeout=60)
    lines = b[1].splitlines()
    ok = b[0] in (0, 1) and not any('panic' in ln or 'reached unreachable' in ln for ln in lines)
    if b[0] == 1:
        ok = ok and lines and lines[-1].startswith('error: line ')
    if not ok:
        B.check(False, f'run {k}: {b[0]!r} {b[1][-300:]!r}\n         {code!r}')
B.check(not any(1 for f in B.FAILS if f.startswith('run ')), f'{B.RUNS} random scripts: no panic, crash or hang, only print lines and its error line')

print('-- memory: console runs that make and drop sketches, shapes, meshes, modifiers --')
import subprocess, tempfile
LINE = ('s = sketch("LS", "XY"); r = rect(s, 0, 0, 1, 1); con(s, "length", r, 2); for i in 0..20 { a = ssphere(1 + i / 10); b = smesh("LM", sunion(a, sbox(1, 1, 1)), 10); '
        'm = modifier(b, "subsurf"); modset(b, m, "levels", 1); modapply(b, 0); n = analyze(b, "boundary") + thinnest(b) + area(b); delete(b); point(s, i, 0) }; '
        'feature(0, 0, rand()); delete(s); sclear()')


def rss(k):
    h = tempfile.mkdtemp(dir=B.T)
    a = ['--op', 'x = sketch("S0", "XY"); rect(x, 0, 0, 1, 1); pad("Body", x, 1)']
    for _ in range(k):
        a += ['--op', LINE]
    a = ['--shot', f'{h}/x.ppm', '--dump-log', f'{h}/log.txt', *a]
    p = subprocess.Popen(['taskset', '-c', B.CPU, B.BIN, *a], env=dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, st, ru = os.wait4(p.pid, 0)
    log = open(f'{h}/log.txt', errors='replace').read() if os.path.exists(f'{h}/log.txt') else ''
    return st, ru.ru_maxrss, log.count('error:')


(s4, r4, e4), (s60, r60, e60) = rss(4), rss(60)
B.check(s4 == 0 and s60 == 0 and e4 == 0 and e60 == 0 and r60 - r4 < 16384, f'4 runs {r4} KiB, 60 runs {r60} KiB at most (exit {s4}/{s60}, errors {e4}/{e60}): no growth past 16 MiB')

B.finish('bs_cad_fuzz')
