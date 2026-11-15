#!/usr/bin/env python3
"""Sculpting and painting a landscape in the window (lsculpt.zig press /
drag / release, sculpt mode on a landscape), in the fake compositor
(tests/wl_fake.py): a scene BeeModel makes, the view from the front (the
viewport filling the window), a stroke, the scene saved from the console.
Every tool (raise, lower, smooth, flatten, noise, erode, ramp), a paint, a
bigger and weaker brush, a click, a stroke off the landscape must change the
landscape block (its reference count and milliseconds aside) and leave the
window running; the saved file reads back with as many landscapes; the
file saved again from it is the same; a stroke undone (one step) gives the
block back as it was.

    python3 tests/landscape_wl.py BIN [only]

BEE_CPU (default 20) pins BeeModel.
"""
import hashlib, os, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of its own)
import beefile
import wl_fake

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
ONLY = sys.argv[2] if len(sys.argv) > 2 else ''
CPU = os.environ.get('BEE_CPU', '20')
FAILS = []
T = tempfile.mkdtemp(prefix='beelandwl-', dir=os.environ.get('BEELAND_TMP', '/tmp'))
import atexit
atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T, XDG_CACHE_HOME='', BEEMODEL_GPU='off')
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)

# ---- the user's own settings must not move (read only: the real home, by uid) ----
import pwd as _pwd


def _real_config():
    h = _pwd.getpwuid(os.getuid()).pw_dir
    out = {}
    for d in ('.config/beemodel-zig', '.config/beemodel'):
        p = os.path.join(h, d)
        if os.path.isdir(p):
            for n in sorted(os.listdir(p)):
                st = os.stat(os.path.join(p, n))
                out[f'{d}/{n}'] = (st.st_size, st.st_mtime_ns)
    return out


_REAL0 = _real_config()


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def wait_saved(f, path, limit=60.0):
    t0 = time.time()
    while not os.path.exists(path) and time.time() - t0 < limit:
        f.pump(0.1)


# typed into the console's line: no keymap is sent, BeeModel reads the codes as US keys
ROW = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
ROW.update({'.': 52, '/': 53, ' ': 57, '0': 11, '-': 12})
ROW.update({str(i): i + 1 for i in range(1, 10)})


class Win:
    """BeeModel in the fake compositor, pinned, a scene file opened."""

    def __init__(self, scene_file):
        self.f = wl_fake.Fake(BIN, size=(1280, 800), env={'HOME': T, 'BEEMODEL_GPU': 'off'}, args=(scene_file,))
        os.sched_setaffinity(self.f.proc.pid, {int(c) for c in CPU.split(',')})
        self.f.until(lambda: self.f.frames > 0 and self.f.keyboard is not None and self.f.pointer is not None, 20)
        self.f.pump(1.0)
        self.f.enter(640, 300)
        self.f.pump(0.6)
        self.proc = self.f.proc

    def pump(self, t=0.05):
        return self.f.pump(t)

    def move(self, x, y):
        self.f.motion(x, y)
        self.f.pump(0.02)

    def mods(self, m):
        self.f.mods(m)

    def key(self, code):
        self.f.key(code)

    def type(self, text):
        for c in text:
            if c == '_':
                self.f.key(12, 1)
            else:
                self.f.key(ROW[c])

    def drag(self, x0, y0, x1, y1, steps=12):
        self.move(x0, y0)
        self.f.button(0x110, True)
        self.f.pump(0.05)
        for k in range(1, steps + 1):
            self.move(x0 + (x1 - x0) * k // steps, y0 + (y1 - y0) * k // steps)
        self.f.button(0x110, False)
        self.f.pump(0.1)


def fake(binary, scene_file):
    return Win(scene_file)


def line(f, text):
    f.key(28)
    f.type(text)
    f.key(28)
    f.pump(0.3)


def lands(path):
    if not os.path.exists(path):
        return None
    c = beefile.chunk(path, b'LAND') or b''
    out, o = [], 0
    while len(c) - o >= 8:
        ix, nb = struct.unpack_from('<II', c, o)
        b = bytearray(c[o + 8:o + 8 + nb])
        b[0:4] = b'\0' * 4
        b[72:76] = b'\0' * 4
        out.append(bytes(b))
        o += 8 + nb
    return out


def session(binary, base, pre, do, out):
    """(alive after the stroke, the file saved)"""
    if os.path.exists(out):
        os.remove(out)
    f = fake(binary, base)
    f.move(640, 300)
    f.pump(0.2)
    # the viewport filling the window, from the front and a little above (Numpad 1, 8)
    f.mods(4)
    f.key(57)
    f.mods(0)
    f.pump(0.2)
    f.key(79)
    f.pump(0.4)
    f.key(72)
    f.pump(0.4)
    f.key(72)
    f.pump(0.8)
    f.mods(4)
    f.key(15)  # Ctrl+Tab: sculpt mode (on a landscape: its brushes)
    f.mods(0)
    f.pump(0.5)
    for s in pre:
        f.mods(4)
        f.key(57)
        f.mods(0)
        f.pump(0.2)
        line(f, s)
        f.key(1)
        f.mods(4)
        f.key(57)
        f.mods(0)
        f.pump(0.3)
        f.move(640, 300)
        f.pump(0.2)
    do(f)
    f.pump(0.5)
    alive = f.proc.poll() is None
    f.mods(4)
    f.key(57)
    f.mods(0)
    f.pump(0.2)
    line(f, f'file.save {out}')
    wait_saved(f, out)
    f.pump(0.2)
    f.proc.kill()
    f.proc.wait()
    return alive


def main():
    base = f'{T}/base.bee'
    p = f'{T}/s.bees'
    open(p, 'w').write(f'n = count()\nfor i in 0..n {{ delete(name(0)) }}\nop("landscape.add", "hills res 129 size 30 seed 3")\n'
                       f'op("landscape.layer", "set 0 height 3")\nop("file.save_as", "{base}")\n')
    subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=300, env=ENV)
    check(os.path.exists(base), 'the base scene made by BeeModel (--run)')
    b0 = lands(base)
    check(bool(b0), f'it has a landscape block ({len(b0[0]) if b0 else 0} bytes)')

    def stroke(p=(560, 260, 740, 320), steps=12, keys=()):
        def run(f):
            for k in keys:
                if isinstance(k, tuple):
                    f.mods(k[0])
                    f.key(k[1])
                    f.mods(0)
                else:
                    f.key(k)
                f.pump(0.05)
            f.drag(*p, steps=steps)
        return run

    def undone(f):
        stroke()(f)
        f.pump(0.3)
        f.mods(4)
        f.key(44)  # Ctrl+Z
        f.mods(0)
        f.pump(0.5)

    SHIFT = 1
    cases = [
        ('raise', ['landscape.tool_raise'], stroke()),
        ('lower', ['landscape.tool_lower'], stroke()),
        ('smooth', ['landscape.tool_smooth'], stroke()),
        ('flatten', ['landscape.tool_flatten'], stroke()),
        ('noise', ['landscape.tool_noise'], stroke()),
        ('erode', ['landscape.tool_erode'], stroke()),
        ('ramp', ['landscape.tool_ramp'], stroke(p=(520, 240, 760, 360))),
        ('paint grass', ['landscape.paint_grass'], stroke()),
        ('bigger, weaker', ['landscape.tool_raise'], stroke(keys=(27, 27, (SHIFT, 26), (SHIFT, 26)))),
        ('a click', ['landscape.tool_raise'], stroke(p=(640, 300, 640, 300), steps=1)),
        ('off the landscape on the way', ['landscape.tool_lower'], stroke(p=(600, 280, 1200, 60))),
        ('undone', ['landscape.tool_raise'], undone),
    ]
    for name, pre, do in cases:
        if ONLY and ONLY not in name:
            continue
        q = f'{T}/p.bee'
        alive = session(BIN, base, pre, do, q)
        lp = lands(q)
        check(alive and lp is not None, f'{name}: the window kept running and saved the scene')
        if lp is None:
            continue
        if name == 'undone':
            check(lp == b0, f'{name}: back to the block before')
            continue
        check(lp != b0, f'{name}: the stroke changed the landscape')
        check(len(lp) == len(b0), f'{name}: still {len(b0)} landscape(s)')
        # save -> open -> save: the same block
        q2 = f'{T}/p2.bee'
        if os.path.exists(q2):
            os.remove(q2)
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/u.ppm', '--op', f'file.open {q}', '--op', f'file.save {q2}'],
                           capture_output=True, text=True, timeout=300, env=ENV)
        check(r.returncode == 0 and lands(q2) == lp, f'{name}: opened and saved again, the same block')
    _moved = [k for k in set(_REAL0) | set(_real_config()) if _REAL0.get(k) != _real_config().get(k)]
    check(not _moved, f'the user\'s ~/.config untouched by the run ({", ".join(_moved) or "nothing moved"})')
    print(f'landscape window: fails {len(FAILS)}')
    for x in FAILS:
        print('  -', x)
    print(f'... fails {len(FAILS)}')
    return 1 if FAILS else 0


sys.exit(main())
