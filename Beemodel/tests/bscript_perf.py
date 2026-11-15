#!/usr/bin/env python3
"""BeeScript's speed: loop-heavy scripts (calls, a million iterations,
texts, the scene) on a release build, pinned to one CPU, best of five. Each
run ends cleanly (exit 0), prints the same every time, and where the answer is
plain arithmetic it prints that answer. The times are printed; there is no
bound on them (no baseline to hold them to).

    python3 tests/bscript_perf.py RELEASE_BIN

BEE_CPU (default 10) is the CPU.
"""
import os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of its own)

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out/bin/beemodel'))
CPU = os.environ.get('BEE_CPU', '10')
FAILS = []
CASES = [  # what, script, its answer (None: not plain arithmetic)
    ('fib(27): 300 000 calls', 'fn fib(n) { if n < 2 { return n }\n return fib(n - 1) + fib(n - 2) }\nprint(fib(27))', '196418'),
    ('a million iterations', 's = 0\nfor i in 0..1000000 { s += i }\nprint(s)', '499999500000'),
    ('a while loop, 3 million', 'i = 0\nwhile i < 3000000 { i += 1 }\nprint(i)', '3000000'),
    ('texts: 100 000 joined', 'for k in 0..100000 { s = "ab" + k }\nt = ""\nfor k in 0..300 { t = t + "x" }\nprint(s, len(t))', 'ab99999 300'),
    ('math: 300 000 rounds', 'n = 0\nfor i in 0..300000 { n += sqrt(i) * sin(i) + floor(i / 3) % 7 + pow(i, 2) }\nprint(n)', None),
    ('the scene: 1500 objects made and moved', 'for i in 0..1500 { add("cube", "C" + i, i, 0, 0) }\nfor i in 0..1500 { move("C" + i, 0, i, 0)\n set("C" + i, "sx", 2) }\nprint(count(), get("C1499", "y"))', None),
]


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def best(b, code):
    h = tempfile.mkdtemp(prefix='beebsperf-', dir='/tmp')
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h)
    t, outs = None, set()
    try:
        for _ in range(5):
            t0 = time.perf_counter()
            r = subprocess.run(['taskset', '-c', CPU, b, '--eval', code], capture_output=True, text=True, env=env, timeout=300)
            dt = time.perf_counter() - t0
            outs.add((r.returncode, r.stdout))
            t = dt if t is None else min(t, dt)
    except subprocess.TimeoutExpired:
        outs.add((None, 'timeout'))
    finally:
        shutil.rmtree(h, True)
    return (t or 0) * 1000, outs


def main():
    print(f'BeeScript speed: {BIN}, CPU {CPU}')
    for what, code, want in CASES:
        tp, outs = best(BIN, code)
        rc, out = next(iter(outs))
        why = ''
        if len(outs) != 1:
            why = f': the runs differ {sorted(outs, key=repr)!r}'
        elif rc != 0 or 'panic' in out:
            why = f': exit {rc} {out[-300:]!r}'
        elif not out.strip():
            why = ': it printed nothing'
        elif want is not None and out.strip() != want:
            why = f': it printed {out.strip()!r}, not {want!r}'
        check(not why, f'{what}: {tp:.1f} ms' + why)
    print(f'bscript_perf: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
