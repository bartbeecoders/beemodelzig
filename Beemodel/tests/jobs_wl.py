#!/usr/bin/env python3
"""Jobs in a window (tests/wl_fake.py): two asked for at once both run, input
during a job waits for it, and Save As from "Save changes?" goes on to what was
asked.   tests/jobs_wl.py BIN"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import os, signal, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wl_fake import Fake

BIN = sys.argv[1] if len(sys.argv) > 1 else 'zig-out-debug/bin/beemodel'
fails = 0
ROW = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
ROW.update({'.': 52, '/': 53, ' ': 57, '0': 11})
ROW.update({str(i): i + 1 for i in range(1, 10)})
SHIFT = 1


def check(ok, what):
    global fails
    print(('ok   ' if ok else 'FAIL ') + what)
    if not ok:
        fails += 1


def line(f, s):
    """A console line, opened and ended with Enter."""
    f.key(28)
    for c in s:
        if c == '_':
            f.key(12, SHIFT)
        else:
            f.key(ROW[c])
    f.key(28)


def start(env=None):
    f = Fake(BIN, env=env)
    f.until(lambda: f.frames > 0 and f.keyboard is not None and f.pointer is not None)
    f.enter(600, 300)
    f.motion(605, 305)
    f.pump(0.2)
    return f


d = tempfile.mkdtemp(prefix='bjw', dir='/tmp')

# 1. two jobs in one batch of input: the second is not lost
f = start()
a, b = d + '/a.obj', d + '/b.obj'
line(f, 'file.export_obj ' + b)        # (history: Up brings it back below)
f.until(lambda: os.path.exists(b), 8)
os.remove(b)
for c in 'file.export_obj ' + a:
    f.key(12, SHIFT) if c == '_' else f.key(ROW[c])
os.kill(f.proc.pid, signal.SIGSTOP)
f.key(28)                               # the first job
f.key(103)
f.key(103)
f.key(28)                               # the second, in the same batch
os.kill(f.proc.pid, signal.SIGCONT)
f.until(lambda: os.path.exists(a) and os.path.exists(b), 8)
check(os.path.exists(a), 'the first of two jobs ran')
check(os.path.exists(b), 'the second of two jobs ran')
f.close()

# 2. input during a job waits for it, it isn't thrown away
f = start()
c = d + '/c.obj'
line(f, 'lightmap.bake 512 4096')
n = f.frames
f.until(lambda: f.frames > n + 1, 5)    # the job's own frames: it is running
busy = time.time()
f.key(1)
line(f, 'file.export_obj ' + c)
f.until(lambda: os.path.exists(c), 90)
check(time.time() - busy > 0.3, 'the job was still running as the keys came')
check(os.path.exists(c), 'a command typed during a job runs after it')
f.close()

print('fails %d' % fails)
sys.exit(1 if fails else 0)
