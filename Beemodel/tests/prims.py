#!/usr/bin/env python3
"""Cone, torus, grid, ground: the meshes, a file that reads back, the Add menu,
the Ground's grid.

    python3 tests/prims.py BIN
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import math, os, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
FAILS = []
T = tempfile.mkdtemp(prefix='beeprim-', dir='/tmp')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def port(*a):
    ui = f'{T}/u.txt'
    r = subprocess.run([BIN, '--shot', f'{T}/u.ppm', '--dump-ui', ui, *a], capture_output=True, text=True, timeout=120)
    return r, open(ui, errors='replace').read() if os.path.exists(ui) else ''


def status(ui):
    for line in ui.split('\n'):
        if line.startswith('status\t'):
            return line.split('\t')[1]
    return ''


r, ui = port('--op', 'create.cone', '--op', 'create.torus', '--op', 'create.grid', '--op', 'create.ground height 0.5', '--op', f'file.save {T}/p.bee')
check(r.returncode == 0, 'the commands run')
check('7 objects' in status(ui) and ' 1115 faces' in status(ui), status(ui))

pb = {o['name']: o for o in beefile.objects(f'{T}/p.bee')}
pm = beefile.meshes(f'{T}/p.bee')
nf = {'Cone': 33, 'Torus': 576, 'Grid': 100, 'Ground': 400}
for name in ('Cone', 'Torus', 'Grid', 'Ground'):
    if name not in pb:
        check(False, f'{name}: not in the file')
        continue
    v, f = pm[pb[name]['mesh']]
    ok = all(math.isfinite(c) for x in v for c in x) and all(0 <= i < len(v) for p in f for i in p) and all(len(p) >= 3 for p in f)
    check(ok and len(f) == nf[name], f'{name}: {len(v)} vertices, {len(f)} faces, all finite and in range')
check(abs(pb.get('Ground', {'loc': (0, 0, 0)})['loc'][1] - 0.5) < 1e-6, f"the Ground at height 0.5: {pb.get('Ground', {}).get('loc')}")

# save, open, save: the same file
r, ui = port('--op', f'file.open {T}/p.bee', '--op', f'file.save {T}/q.bee')
check(r.returncode == 0 and beefile.chunks(f'{T}/q.bee') == beefile.chunks(f'{T}/p.bee'), 'save, open and save give the same file')
check([o['flags'] & 0x6000 for o in beefile.objects(f'{T}/q.bee')] == [o['flags'] & 0x6000 for o in beefile.objects(f'{T}/p.bee')], 'the Ground stays one through a save')

# one Ground in a scene
r, ui = port('--op', 'create.ground', '--op', 'create.ground', '--op', f'file.save {T}/g.bee')
n = [o['name'] for o in beefile.objects(f'{T}/g.bee') if o['flags'] & 0x2000]
check(n == ['Ground'], f'a second create.ground selects the first: {n}')

# the Add menu has them; the undo step is one each
r, ui = port('--move', '615,360', '--key', 'shift+a', '--click-label', 'menuitem:Torus', '--key', 'ctrl+z')
check('3 objects' in status(ui), 'Add > Torus and Ctrl+Z: ' + status(ui))
r, ui = port('--move', '615,360', '--key', 'shift+a', '--click-label', 'menuitem:Torus')
check('4 objects' in status(ui) and '582 faces' in status(ui), 'Add > Torus: ' + status(ui))


# the Ground is a fading grid, not a plate: nothing where its mesh would cover the
# background, and the floor grid gives way to it
def ppm(*a):
    r, ui = port(*a)
    d = open(f'{T}/u.ppm', 'rb').read()
    return d[d.index(b'255\n') + 4:]


W, H = 1280, 800
px = lambda d, x, y: tuple(d[(y * W + x) * 3:(y * W + x) * 3 + 3])
plain = ppm('--op', 'view.toggle_grid')
grid = ppm('--op', 'create.ground')
diff = sum(1 for i in range(0, len(plain), 3) if plain[i:i + 3] != grid[i:i + 3])
check(diff > 3000, f'the Ground draws its grid: {diff} pixels against no grid')
off = ppm('--op', 'view.toggle_grid', '--op', 'create.ground')
vw = lambda d: [d[(y * W + 214) * 3:(y * W + 1010) * 3] for y in range(90, 640)]
# (the Ground's grid, then with the floor grid on the axes over it, and with it
# off neither floor grid nor axes)
dpx = [(x, y) for y in range(90, 640) for x in range(214, 1010) if px(off, x, y) != px(grid, x, y)]
cols = {px(grid, x, y) for x, y in dpx}
check(dpx and len(cols) == 3 and all(px(off, x, y) not in cols for x, y in dpx), f'with the floor grid off the same but for the axes: the two do not add up ({len(dpx)} axis pixels, {len(cols)} colours)')
# a click on the floor does not pick the Ground
r, ui = port('--op', 'create.ground', '--op', 'select Cube', '--click', '700,600')
check(' 0 selected' in status(ui), 'a click on the Ground does not pick it: ' + status(ui))
print(f'prims: fails {len(FAILS)}')
sys.exit(1 if FAILS else 0)
