#!/usr/bin/env python3
"""Analysis overlays: random meshes (holes, non-manifold fans, folded edges,
repeated corners, loose vertices) through analyze() and through the overlays'
legend: both run cleanly, give the same five counts, sane ones; then the
picture: the overlays' colours on screen.

    python3 tests/analysis.py BIN [meshes]
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import math, os, random, re, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
N = int(sys.argv[2]) if len(sys.argv) > 2 else 60
FAILS = []
T = tempfile.mkdtemp(prefix='beean-', dir='/tmp')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def chunk(tag, body):
    return tag + struct.pack('<I', len(body)) + body


def bee(verts, polys, loc=(0, 0, 0), rot=(0, 0, 0), scl=(1, 1, 1)):
    off, loops = [0], []
    for p in polys:
        loops += p
        off.append(len(loops))
    m = struct.pack('<III', len(verts), len(polys), len(loops))
    m += b''.join(struct.pack('<3f', *v) for v in verts)
    m += struct.pack(f'<{len(off)}I', *off) + struct.pack(f'<{len(loops)}I', *loops)
    o = struct.pack('<I', 1) + b'Mesh'.ljust(32, b'\0') + struct.pack('<9f', *loc, *rot, *scl) + struct.pack('<IIII', 0xb4b8c0, 0, 1, 0)
    return b'BEEM' + struct.pack('<I', 1) + chunk(b'MESH', m) + chunk(b'OBJS', o)


def grid_mesh(rng):
    n = rng.randrange(2, 7)
    v = [(x + rng.random() * .2, rng.random() * rng.choice([0, 1.5]), y) for y in range(n + 1) for x in range(n + 1)]
    p = []
    for y in range(n):
        for x in range(n):
            a, b, c, d = y * (n + 1) + x, y * (n + 1) + x + 1, (y + 1) * (n + 1) + x + 1, (y + 1) * (n + 1) + x
            r = rng.random()
            if r < .1:
                continue                         # a hole
            if r < .2:
                p.append([a, d, c, b])           # the other way round
            elif r < .3:
                p += [[a, b, c, d], [a, b, c, d]]  # twice
            elif r < .4:
                p.append([a, b, a, c])           # a corner repeated
            elif r < .5:
                p += [[a, b, c], [a, c, d]]
            else:
                p.append([a, b, c, d])
    m = len(v)
    v += [(rng.random() * 9, rng.random(), rng.random() * 9) for _ in range(rng.randrange(4))]  # loose
    if rng.random() < .4:
        v += [(0, 0, 0), (0, 0, 0), (0, 0, 0)]    # no area
        p.append([len(v) - 3, len(v) - 2, len(v) - 1])
    if rng.random() < .5:
        p.append([0, 1])                          # too few corners
    return v, p


def port(*a, name='u'):
    ui = f'{T}/{name}.txt'
    r = subprocess.run([BIN, '--shot', f'{T}/{name}.ppm', '--dump-ui', ui, *a], capture_output=True, text=True, timeout=120)
    return r, open(ui, errors='replace').read()


def legend(ui):
    for l in ui.split('\n'):
        if l.startswith('analysis\t'):
            return [int(x) for x in l.split('\t')[1].split()]
    return None


rng = random.Random(11)
bad = 0
ok = 0
total = [0] * 5
for k in range(N):
    v, p = grid_mesh(rng)
    rot = (rng.choice([0, 0, 1.2, math.pi]), rng.choice([0, .7]), rng.choice([0, 3]))
    scl = rng.choice([(1, 1, 1), (2, 2, 2)])
    f = f'{T}/m{k}.bee'
    open(f, 'wb').write(bee(v, p, rot=rot, scl=scl))
    a = rng.choice(['', '30', '60', '80'])
    arg = f'"{a}"' if a else ''
    e = subprocess.run([BIN, '--eval', f'op("file.open", "{f}"); ' + (f'op("view.show_overhangs", {arg}); ' if a else '') + 'print(analyze("Mesh", "boundary"), analyze("Mesh", "nonmanifold"), analyze("Mesh", "degenerate"), analyze("Mesh", "loose"), analyze("Mesh", "overhang"))'], capture_output=True, text=True, timeout=120)
    out = e.stdout.strip().split('\n')[-1] if e.stdout.strip() else ''
    try:
        want = [int(x) for x in out.split()]
    except ValueError:
        want = None
    r, ui = port('--op', f'file.open {f}', '--op', 'view.show_boundary', *(['--op', f'view.show_overhangs {a}'] if a else []))
    full = legend(ui)
    # the legend carries a sixth count, thin walls: 0 without view.show_thickness
    got = full[:5] if full and len(full) == 6 and full[5] == 0 else full
    most = len(v) + sum(len(q) for q in p) + len(p)
    if e.returncode != 0 or r.returncode != 0 or want is None or got != want or len(got) != 5 or not all(0 <= x <= most for x in got):
        bad += 1
        print(f'    mesh {k}: analyze() {e.returncode} {out!r}, the legend {r.returncode} {got}, angle {a} rot {rot}')
        if bad > 5:
            break
    else:
        ok += 1
        total = [x + y for x, y in zip(total, got)]
check(bad == 0 and ok == N, f'{ok} of {N} random meshes: analyze() and the legend give the same five counts, in range; in all {total}')
check(all(total), 'every class came up in them')

# --- the picture ------------------------------------------------------------------


def colour_count(path, rgb):
    d = open(path, 'rb').read()
    p = d.index(b'255\n') + 4
    px = d[p:]
    c = bytes(rgb)
    return sum(1 for i in range(0, len(px), 3) if px[i:i + 3] == c)


cube = [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1), (-1, 1, -1), (1, 1, -1), (1, 1, 1), (-1, 1, 1)]
faces = [[0, 1, 2, 3], [7, 6, 5, 4], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]]
open(f'{T}/hole.bee', 'wb').write(bee(cube, faces[:1] + faces[2:]))        # top gone
CYAN, RED, GREEN, PINK, ORANGE = (0x40, 0xe0, 0xe0), (0xf0, 0x48, 0x48), (0xa8, 0xe0, 0x50), (0xe0, 0x50, 0xe0), (0xf0, 0x80, 0x40)
r, ui = port('--op', f'file.open {T}/hole.bee', '--op', 'view.show_boundary', name='p')
check(colour_count(f'{T}/p.ppm', CYAN) > 100, f"boundary edges in cyan: {colour_count(f'{T}/p.ppm', CYAN)} px")
r, ui = port('--op', f'file.open {T}/hole.bee', name='q')
check(colour_count(f'{T}/q.ppm', CYAN) == 0, 'none without the overlay')
r, ui = port('--op', f'file.open {T}/hole.bee', '--op', 'view.show_normals', name='p')
check(colour_count(f'{T}/p.ppm', GREEN) > 20, f"normals in green: {colour_count(f'{T}/p.ppm', GREEN)} px")
r, ui = port('--op', f'file.open {T}/hole.bee', '--op', 'view.show_overhangs', '--mdrag', '615,360,615,330', '--key', 'kp7', '--key', 'ctrl+kp7', '--wait', '400', '--wait', '400', name='p')
check(colour_count(f'{T}/p.ppm', ORANGE) > 20, f"overhangs in orange from below: {colour_count(f'{T}/p.ppm', ORANGE)} px")
open(f'{T}/nm.bee', 'wb').write(bee(cube + [(0, 3, 0)], faces + [[4, 5, 8]]))
r, ui = port('--op', f'file.open {T}/nm.bee', '--op', 'view.show_nonmanifold', name='p')
check(colour_count(f'{T}/p.ppm', RED) > 40, f"a third face on an edge in red: {colour_count(f'{T}/p.ppm', RED)} px")
open(f'{T}/dg.bee', 'wb').write(bee(cube, faces + [[4, 5, 6, 4]]))
r, ui = port('--op', f'file.open {T}/dg.bee', '--op', 'view.show_degenerate', name='p')
check(colour_count(f'{T}/p.ppm', PINK) > 40, f"a repeated corner in magenta: {colour_count(f'{T}/p.ppm', PINK)} px")
# the Overlays menu lists them, ticked; depth: the far side's edges are hidden
r, ui = port('--op', 'view.show_boundary', '--click-label', 'icon:Overlays', name='m')
items = [l.split('\t')[1:3] for l in ui.split('\n') if l.startswith('menuitem\t')]
names = [x[0] for x in items]
check(names[:4] == ['Ground Grid', 'Text Info', 'Statistics', 'Navigation Gizmo'] or len(names) >= 8, f'the header\'s Overlays: {names}')
check(all(x in names for x in ('Show Normals', 'Show Boundary Edges', 'Show Non-manifold', 'Show Degenerate Faces')), 'the mesh checks are in it')
on = [l for l in ui.split('\n') if l.startswith('menuitem\tShow') and l.endswith('off')]
check(not on, f'none greyed: {on}')
print(f'analysis: fails {len(FAILS)}')
sys.exit(1 if FAILS else 0)
