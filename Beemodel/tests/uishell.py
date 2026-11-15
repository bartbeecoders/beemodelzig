#!/usr/bin/env python3
"""What the scenarios cannot say: the threaded rasterizer's image equals the
serial one's, and the UI scale keeps the layout and draws real pixels.
   tests/uishell.py BIN"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import math, os, subprocess, sys, tempfile

BIN = sys.argv[1] if len(sys.argv) > 1 else 'zig-out-debug/bin/beemodel'
d = tempfile.mkdtemp(prefix='bmzui')
fails = 0


def check(ok, what):
    global fails
    print(('ok   ' if ok else 'FAIL ') + what)
    if not ok:
        fails += 1


def shot(name, *args):
    p = os.path.join(d, name + '.ppm')
    u = os.path.join(d, name + '.txt')
    r = subprocess.run([BIN, '--shot', p, '--dump-ui', u, *args], capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        print(r.stderr[-400:])
    return p, u


def widgets(u):
    out = {}
    for line in open(u, errors='replace'):
        f = line.rstrip('\n').split('\t')
        if len(f) >= 3:
            out.setdefault(f[0] + ':' + f[1], f[2])
    return out


# a mesh big enough for the threads: a closed sphere and an open grid
obj = os.path.join(d, 'big.obj')
n = 110
with open(obj, 'w') as f:
    for j in range(n + 1):
        for i in range(n):
            t, p = math.pi * j / n, 2 * math.pi * i / n
            f.write('v %.4f %.4f %.4f\n' % (4 * math.sin(t) * math.cos(p), 4 * math.cos(t), 4 * math.sin(t) * math.sin(p)))
    for j in range(n):
        for i in range(n):
            f.write('f %d %d %d %d\n' % (j * n + i + 1, j * n + (i + 1) % n + 1, (j + 1) * n + (i + 1) % n + 1, (j + 1) * n + i + 1))
imp = ['--key', 'enter', '--type', 'file.import_obj ' + obj, '--key', 'enter', '--key', 'esc', '--move', '400,400']
for name, extra in (('solid', []), ('selected', ['--click', '600,380']), ('material', ['--key', 'shift+z']),
                    ('edit', ['--click', '600,380', '--key', 'tab'])):
    a = open(shot(name + '_mt', *imp, *extra)[0], 'rb').read()
    b = open(shot(name + '_st', '--serial-raster', *imp, *extra)[0], 'rb').read()
    check(a == b and len(a) > 1000, 'threads and one thread draw the same image: ' + name)
# (and it was the threaded path: the mesh is there at all)
w = widgets(shot('solid_mt2', *imp)[1])
check(any(k.startswith('status:') and '24200 faces' in k or '12100' in k for k in w), 'the imported mesh is in the frame')

# the UI scale: the same layout in units, the buffer in pixels
base_p, base_u = shot('s100', '--size', '1000x640')
s_p, s_u = shot('s150', '--size', '1000x640', '--comp-scale', '180')
wa, wb = widgets(base_u), widgets(s_u)
check(wa['menu:File'] == wb['menu:File'] and wa['editor:Tools'] == wb['editor:Tools'], 'the screen\'s scale keeps the layout in units')
hdr = open(s_p, 'rb').read(32).split(b'\n')[1]
check(hdr == b'1500 960', 'the screen\'s scale: 1500 x 960 pixels (%s)' % hdr.decode())


def row(path, y, x0, x1):
    raw = open(path, 'rb').read()
    h = raw.split(b'\n', 3)
    w, _ = map(int, h[1].split())
    px = h[3]
    return px[(y * w + x0) * 3:(y * w + x1) * 3]


def levels(b):
    return len(set(b[i:i + 3] for i in range(0, len(b), 3)))


# text drawn at the real size has its own grey levels, not a scaled bitmap's copies:
# at 2x every second column would repeat the one before it
two_p, _ = shot('s200', '--size', '640x400', '--comp-scale', '240')
r = row(two_p, 32, 68, 300)        # (through the title's letters)
cols = [r[i:i + 3] for i in range(0, len(r), 3)]
same = sum(1 for i in range(0, len(cols) - 1, 2) if cols[i] == cols[i + 1])
check(levels(r) > 6 and same < len(cols) // 2 * 0.9, 'text at 2x is rasterized at 2x (%d of %d pairs alike)' % (same, len(cols) // 2))
# the UI scale preference: fewer units in the same pixels
p, u = shot('u150', '--size', '900x600', '--ui-scale', '150')
hdr = open(p, 'rb').read(32).split(b'\n')[1]
wb = widgets(u)
check(hdr == b'900 600', 'UI scale 150%: the same pixels')
st = [v for k, v in wb.items() if k.startswith('status:')][0].split()
check(int(st[1]) == 400 - 22, 'UI scale 150%%: 400 units high (the status bar at %s)' % st[1])

# maximizing from the console itself stays maximized: the line's refocus does not undo it
_, u0 = shot('maxop0')
_, u = shot('maxop', '--key', 'enter', '--type', 'area.maximize', '--key', 'enter')
n0, n1 = len(widgets(u0)), len(widgets(u))
check(n1 < n0 * 0.6, 'area.maximize typed in the console: it stays maximized (%d widgets of %d)' % (n1, n0))
# Enter with the console hidden by a maximized area: a line is typed, not shortcuts
log = os.path.join(os.path.dirname(p), 'maxlog.txt')
shot('maxenter', '--dump-log', log, '--op', 'area.maximize', '--key', 'enter', '--type', 'render.device cpu', '--key', 'enter')
text = open(log, errors='replace').read()
check('render device: CPU' in text, 'Enter behind a maximized area: the command line takes the line')

print('uishell fails', fails)
sys.exit(1 if fails else 0)
