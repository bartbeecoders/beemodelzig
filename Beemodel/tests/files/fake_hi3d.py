#!/usr/bin/env python3
"""A fake bee-hi3d (the Hi3D addon's helper) for tests/aitools.py: never the
real one. It records how it was called (args.json next to it) and behaves as
its mode file (mode, next to it) says:

  ok         progress lines, then the OBJ at --out and "@bee done <out> <faces>"
  refine     the same, the mesh made from --coarse (its vertices moved out)
  slow       progress, then sleeps until stopped (TERM ends it)
  stuck      ignores TERM (only KILL ends it)
  crash      dies of SIGSEGV half way
  error      "@bee error ..." and exit 1
  nomesh     exit 0 without a done line
  missing    "@bee done" with a file that is not there
  badobj     "@bee done" with a file that is no OBJ
  garbage    noise: binary bytes, NUL, a 5000-byte line, odd @bee lines, then
             a done line for a good mesh with no newline after it
  flood      200000 lines of progress, then a good mesh
  spaces     a done line whose path has spaces in it
"""
import json, os, signal, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
mode = open(os.path.join(HERE, 'mode')).read().strip() if os.path.exists(os.path.join(HERE, 'mode')) else 'ok'
args = sys.argv[1:]
with open(os.path.join(HERE, 'args.json'), 'w') as f:
    json.dump(args, f)


def arg(k):
    return args[args.index(k) + 1] if k in args else None


out = arg('--out') or os.path.join(HERE, 'out.obj')
w = sys.stdout


def say(s, nl=True):
    w.write(s + ('\n' if nl else ''))
    w.flush()


CUBE = """# fake hi3d
v -1 -1 -1
v 1 -1 -1
v 1 1 -1
v -1 1 -1
v -1 -1 1
v 1 -1 1
v 1 1 1
v -1 1 1
f 1 4 3 2
f 5 6 7 8
f 1 2 6 5
f 2 3 7 6
f 3 4 8 7
f 4 1 5 8
"""


def write_mesh(path):
    if mode == 'refine' and arg('--coarse'):
        vs, fs = [], []
        for ln in open(arg('--coarse')):
            if ln.startswith('v '):
                x, y, z = (float(t) for t in ln.split()[1:4])
                vs.append(f'v {x * 1.25:.6f} {y * 1.25:.6f} {z * 1.25:.6f}')
            elif ln.startswith('f '):
                fs.append('f ' + ' '.join(t.split('/')[0] for t in ln.split()[1:]))
        open(path, 'w').write('# refined\n' + '\n'.join(vs + fs) + '\n')
        return len(fs)
    open(path, 'w').write(CUBE)
    return 6


if mode == 'stuck':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
say('loading TripoSR (fake)')
say('@bee progress 0.05 Loading the models')
say('@bee progress 0.30 Rough shape')
if mode in ('slow', 'stuck'):
    say('@bee progress 0.42 Carving the detail')
    while True:
        time.sleep(0.2)
if mode == 'crash':
    say('@bee progress 0.5 Carving')
    os.kill(os.getpid(), signal.SIGSEGV)
if mode == 'error':
    say('Traceback (most recent call last): ...', True)
    say('@bee error CUDA out of memory (fake)')
    sys.exit(1)
if mode == 'nomesh':
    say('@bee progress 1 Done')
    sys.exit(0)
if mode == 'missing':
    say('@bee done /nonexistent/hi3d/none.obj 12')
    sys.exit(0)
if mode == 'badobj':
    open(out, 'wb').write(b'\x00\x01garbage\xff\n' * 20)
    say(f'@bee done {out} 3')
    sys.exit(0)
if mode == 'garbage':
    sys.stdout.buffer.write(bytes(range(256)) * 4 + b'\n')
    sys.stdout.buffer.write(b'@bee progress \x00 0.7 nul\n')
    say('x' * 5000)
    say('@bee ' + 'y' * 3000)
    say('@bee progress nan Not a number')
    say('@bee progress 1e999 Huge')
    say('@bee progress -3 Negative ' + 'z' * 200)
    say('@bee progress')
    say('@beeprogress 0.9 no space')
    say('@bee error')
    say('@bee done')
    n = write_mesh(out)
    sys.stdout.buffer.write(f'@bee done {out} {n}'.encode())   # (no newline: the end ends it)
    sys.stdout.flush()
    sys.exit(0)
if mode == 'flood':
    for k in range(200000):
        w.write(f'@bee progress {k / 200000:.5f} Step {k}\n')
    w.flush()
if mode == 'spaces':
    d = os.path.join(os.path.dirname(out), 'a dir with spaces')
    os.makedirs(d, exist_ok=True)
    out = os.path.join(d, 'model one.obj')
say('@bee progress 0.95 Writing the mesh')
n = write_mesh(out)
say(f'@bee done {out} {n}')
sys.exit(0)
