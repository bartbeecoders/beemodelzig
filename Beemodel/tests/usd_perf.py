#!/usr/bin/env python3
"""USD import speed, a release build pinned to one CPU: a crate file of about
a million triangles in 2000 meshes (with UVs; pxr makes it, tests/usd_gen.py
--big) and its text twin (usdcat): file.import_usd and file.usd_dump each, the
least of RUNS runs (clock() inside the program: start-up left out), printed.
Fails when an import or a dump takes more than PERF_LIMIT seconds (default
30), or the two files do not give the same objects (2000 or more).

    python3 tests/usd_perf.py BIN_RELEASE [runs=5]

BEE_CPU (default 8) is the CPU; the big files go to .usd-scratch/ on the
project disk (removed at the end).
"""
import os, shutil, subprocess, sys, tempfile
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 5
LIMIT = float(os.environ.get('PERF_LIMIT', '30'))
CPU = os.environ.get('BEE_CPU', '8')
D = os.path.join(ROOT, '.usd-scratch', 'perf')
T = tempfile.mkdtemp(prefix='beeusdperf-', dir='/tmp')
PXENV = dict(os.environ, LD_PRELOAD='/usr/lib/libjemalloc.so.2') if os.path.exists('/usr/lib/libjemalloc.so.2') else dict(os.environ)
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def once(b, f):
    code = ('t0 = clock()\nop("file.import_usd", "%s")\nt1 = clock()\nop("file.usd_dump", "%s %s/d.txt")\nt2 = clock()\n'
            'print("T", t1 - t0, t2 - t1, count())' % (f, f, T))
    if os.path.exists(os.path.join(T, 'd.txt')):
        os.remove(os.path.join(T, 'd.txt'))
    r = subprocess.run(['taskset', '-c', CPU, b, '--eval', code], capture_output=True, text=True, timeout=900)
    ln = next((x for x in r.stdout.splitlines() if x.startswith('T ')), None)
    if ln is None:
        return None
    a = ln.split()
    return float(a[1]), float(a[2]), int(a[3])


def main():
    os.makedirs(D, exist_ok=True)
    big = os.path.join(D, 'big.usdc')
    if not os.path.exists(big):
        r = subprocess.run([sys.executable, os.path.join(HERE, 'usd_gen.py'), '--big', D, '1000000', '2000'], capture_output=True, text=True, env=PXENV)
        check(r.returncode == 0 and os.path.exists(big), 'pxr made the big crate file (%s)' % r.stderr[-200:])
    txt = os.path.join(D, 'big.usda')
    if not os.path.exists(txt):
        subprocess.run(['usdcat', big, '-o', txt], capture_output=True, env=PXENV)
    counts = []
    for f in (big, txt):
        best = None
        for _ in range(RUNS):
            t = once(BIN, f)
            if t is None:
                continue
            best = t if best is None else (min(best[0], t[0]), min(best[1], t[1]), t[2])
        if not best:
            check(False, '%s: it ran' % os.path.basename(f))
            continue
        counts.append(best[2])
        mb = os.path.getsize(f) / 1e6
        print('    %s (%.0f MB, %d objects): import %.0f ms; dump %.0f ms' % (os.path.basename(f), mb, best[2], best[0], best[1]))
        check(best[0] <= LIMIT * 1000 and best[1] <= LIMIT * 1000 and best[2] >= 2000,
              '%s: %d objects, import and dump within %.0f s (%.0f ms, %.0f ms)' % (os.path.basename(f), best[2], LIMIT, best[0], best[1]))
    check(len(counts) == 2 and counts[0] == counts[1], 'the crate file and its text twin: the same objects (%s)' % counts)

try:
    main()
finally:
    shutil.rmtree(T, True)
    shutil.rmtree(D, True)
    try:
        os.rmdir(os.path.dirname(D))
    except OSError:
        pass
print('usd_perf: fails %d' % len(FAILS))
sys.exit(1 if FAILS else 0)
