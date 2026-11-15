#!/usr/bin/env python3
"""The CAD, sketch, shape and modelling builtins' speed: scripts that do
real work (feature rebuilds, sketch solves, shape meshes, modifiers, booleans,
mass properties, the thinnest wall) on a release build, pinned to one CPU,
best of three. Each run ends cleanly (exit 0, no script error), prints
something, and prints the same every time. The times are printed; there is no
bound on them (no baseline to hold them to).

    python3 tests/bs_cad_perf.py RELEASE_BIN

BEE_CPU (default 10) is the CPU.
"""
import os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out/bin/beemodel'))
CPU = os.environ.get('BEE_CPU', '10')
FAILS = []
SK = 's = sketch("S", "XY")\nr = rect(s, -1, -1, 2, 2)\nc = sketch("C", "XY", 1)\ncircle(c, 0, 0, 0.3)\n'
CASES = [
    ('pad, pocket, fillet: 30 rebuilds', SK + 'p = pad("Body", s, 1)\nq = pocket("Body", c, 0.5)\nf = fillet("Body", 0.05, "top")\nfor i in 0..30 { feature(p, 0, 1 + i / 30) }\nprint(faces("Body"), volume("Body"))'),
    ('patterns: 12 holes around, rebuilt 10 times', SK + 'p = pad("Body", s, 0.5)\nh = sketch("H", "XY", 0.5)\ncircle(h, 0.7, 0, 0.1)\nq = pocket("Body", h, 0.2)\nt = pattern("Body", q, 12, 0, "z", "circular")\n'
     'for i in 0..10 { feature(q, 0, 0.1 + i / 50) }\nprint(faces("Body"), volume("Body"))'),
    ('the B-rep kernel: pad, pocket, chamfer', SK + 'op("cad.kernel", "on")\np = pad("Body", s, 1)\nq = pocket("Body", c, 0.5)\nf = chamfer("Body", 0.05)\nfor i in 0..5 { feature(p, 0, 1 + i / 10) }\nprint(brep("Body", "faces"), brep("Body", "volume"))'),
    ('a sketch: 60 lines chained and dimensioned, solved each time', 's = sketch("S", "XY")\nfor i in 0..60 { l = line(s, i, 0, i + 1, 0.1 * i)\n if i > 0 { con(s, "coincident", pt(s, l - 1, 1), pt(s, l, 0)) }\n con(s, "length", l, 1) }\nprint(dof(s), sx(s, 119))'),
    ('shapes: a gyroid in a box at 96 cells', 'a = sisect(sgyroid(0.3, 0.03), sbox(2, 2, 2))\nm = smesh("G", a, 96)\nprint(verts(m), faces(m))'),
    ('shapes: 2000 distances in a tree of 40', 'a = ssphere(1)\nfor i in 0..40 { a = sunion(a, smove(sbox(0.3, 0.3, 0.3), i / 10, 0, 0), 0.05) }\nd = 0\nfor i in 0..2000 { d += sdist(a, i / 500, 0.1, 0) }\nprint(d)'),
    ('modifiers: subsurf 3 applied on a sphere', 'add("sphere", "S")\nm = modifier("S", "subsurf")\nmodset("S", m, "levels", 3)\nmodapply("S", 0)\nprint(verts("S"), manifold("S"), analyze("S", "boundary"))'),
    ('boolean: a sphere from a subdivided cube', 'm = modifier("Cube", "subsurf")\nmodset("Cube", m, "levels", 2)\nmodapply("Cube", 0)\nadd("sphere", "B", 0.5, 0.5, 0.5)\nboolean("Cube", "B", "difference")\nprint(faces("Cube"), volume("Cube"))'),
    ('mass properties and the thinnest wall of a sphere', 'add("sphere", "S")\nm = modifier("S", "subsurf")\nmodset("S", m, "levels", 2)\nmodapply("S", 0)\nprint(area("S"), mass("S"), centroid("S", "x"), thinnest("S"))'),
]


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def best(b, code):
    h = tempfile.mkdtemp(prefix='beebscperf-', dir='/tmp')
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h)
    t, outs = None, set()
    try:
        for _ in range(3):
            t0 = time.perf_counter()
            r = subprocess.run(['taskset', '-c', CPU, b, '--eval', code], capture_output=True, text=True, env=env, timeout=600)
            dt = time.perf_counter() - t0
            outs.add((r.returncode, r.stdout))
            t = dt if t is None else min(t, dt)
    except subprocess.TimeoutExpired:
        outs.add((None, 'timeout'))
    finally:
        shutil.rmtree(h, True)
    return (t or 0) * 1000, outs


def main():
    print(f'CAD builtins speed: {BIN}, CPU {CPU}')
    for what, code in CASES:
        tp, outs = best(BIN, code)
        rc, out = next(iter(outs))
        why = ''
        if len(outs) != 1:
            why = f': the runs differ {sorted(outs, key=repr)!r}'
        elif rc != 0 or 'panic' in out or 'error' in out:
            why = f': exit {rc} {out[-300:]!r}'
        elif not out.strip():
            why = ': it printed nothing'
        check(not why, f'{what}: {tp:.1f} ms' + why)
    print(f'bs_cad_perf: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
