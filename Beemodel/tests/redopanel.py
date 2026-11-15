#!/usr/bin/env python3
"""The redo panel: each tool, then new values from the panel give the mesh the
tool gives with those values from the start; drags, F9, a typed expression;
all of it one undo step.

    python3 tests/redopanel.py BIN
"""
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import math, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
FAILS = []
T = tempfile.mkdtemp(prefix='beeredo-', dir='/tmp')


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def port(*a):
    ui = f'{T}/u.txt'
    if os.path.exists(ui):
        os.unlink(ui)
    r = subprocess.run([BIN, '--shot', f'{T}/u.ppm', '--dump-ui', ui, *a], capture_output=True, text=True, timeout=120)
    return r, open(ui, errors='replace').read() if os.path.exists(ui) else ''


def faces(ui):
    m = re.search(r'(\d+) faces', ui)
    return int(m.group(1)) if m else -1


def redo_rows(ui):
    return [l.split('\t')[1] for l in ui.split('\n') if l.startswith('redo\t')]


def rect(ui, label):
    for l in ui.split('\n'):
        p = l.split('\t')
        if p[0] == 'redo' and p[1].startswith(label):
            return [int(x) for x in p[2].split()]


def mesh_of(path, name='Cube'):
    o = {x['name']: x for x in beefile.objects(path)}[name]
    v, f = beefile.meshes(path)[o['mesh']]
    return sorted(tuple(round(c, 4) for c in p) for p in v), sorted(sorted(len(x) for x in f))


def same_mesh(a, b):
    return a[1] == b[1] and len(a[0]) == len(b[0]) and all(abs(x - y) < 2e-3 for u, v in zip(a[0], b[0]) for x, y in zip(u, v))


def sane(m):
    return len(m[0]) > 0 and len(m[1]) > 0 and all(math.isfinite(c) for p in m[0] for c in p)


def saved(r, p):
    if r.returncode != 0:
        print(r.stderr[-300:])
    try:
        return r.returncode == 0 and os.path.exists(p) and mesh_of(p)
    except Exception as e:  # noqa: BLE001 (a file that does not read back is the finding)
        print(f'     {p}: {e}')
        return None


# in edit mode with everything selected, the cube; each tool, then
# edit.redo_last with a new value: the mesh of the tool run with that value
SEL = ['--move', '615,360', '--key', 'tab', '--op', 'mesh.select_mode_face']
tools = [
    ('inset', 'mesh.inset 0.1', 'mesh.inset 0.25', '0.25', 'Inset'),
    ('extrude_individual', 'mesh.extrude_individual 0.5', 'mesh.extrude_individual 1.25', '1.25', 'Extrude'),
    ('bevel', 'mesh.bevel "0.1 2"', 'mesh.bevel "0.2 3"', '0.2 3', 'Bevel'),
    ('merge_distance', 'mesh.merge_distance 0.25', 'mesh.merge_distance 0.3', '0.3', 'Merge'),
    ('spin', 'mesh.spin "4 90 y"', 'mesh.spin "6 120 z"', '6 120 z', 'Spin'),
]
for name, pc, direct, new, lab in tools:
    d = f'{T}/d_{name}.bee'
    p = f'{T}/p_{name}.bee'
    pre = ['--op', 'mesh.inset 0.1', '--op', 'mesh.select_all', '--op', 'mesh.select_all'] if name == 'merge_distance' else []
    r, ui = port(*SEL, *pre, '--op', pc, '--expect-label', 'redo:' + lab, '--op', f'edit.redo_last "{new}"', '--key', 'tab', '--op', f'file.save {p}')
    b = saved(r, p)
    check(bool(b), f'{name}: the panel shows, edit.redo_last runs, the file reads back')
    r, ui = port(*SEL, *pre, '--op', direct, '--key', 'tab', '--op', f'file.save {d}')
    a = saved(r, d)
    print(f'    {direct}: {a and len(a[0])} verts, {a and len(a[1])} faces; redo: {b and len(b[0])}, {b and len(b[1])}')
    check(bool(a) and bool(b) and sane(b) and same_mesh(a, b), f'{name} {new}: the same mesh as {direct} from the start')

# the modal extrude: one face, E 1 Enter, then a new distance: as E 2 Enter
def project(p, canvas=(208, 80, 1024, 633), yaw=0.7853982, pitch=0.5, dist=18.0):
    """A world point on screen in the default view of a --shot run."""
    sy, cy, sp, cp = math.sin(yaw), math.cos(yaw), math.sin(pitch), math.cos(pitch)
    right = (cy, 0, -sy)
    up = (-sp * sy, cp, -sp * cy)
    fwd = (-cp * sy, -sp, -cp * cy)
    eye = [-fwd[i] * dist for i in range(3)]
    dd = [p[i] - eye[i] for i in range(3)]
    dot = lambda a, b: sum(a[i] * b[i] for i in range(3))
    x0, y0, x1, y1 = canvas
    f = (y1 - y0) * 1.07
    z = dot(dd, fwd)
    return (int((x0 + x1) / 2 + f * dot(dd, right) / z), int((y0 + y1) / 2 - f * dot(dd, up) / z))


px, py = project((0.2, 2, -0.3))
p, d = f'{T}/p_x.bee', f'{T}/d_x.bee'
r, ui = port('--move', f'{px},{py}', '--key', 'tab', '--key', '3', '--click', f'{px},{py}', '--key', 'e', '--type', '1', '--key', 'enter', '--expect-label', 'redo:Distance 1', '--op', 'edit.redo_last 2', '--expect-label', 'redo:Distance 2', '--key', 'tab', '--op', f'file.save {p}')
b = saved(r, p)
r, ui = port('--move', f'{px},{py}', '--key', 'tab', '--key', '3', '--click', f'{px},{py}', '--key', 'e', '--type', '2', '--key', 'enter', '--key', 'tab', '--op', f'file.save {d}')
a = saved(r, d)
print(f'    E 2: {a and len(a[0])} verts; redo: {b and len(b[0])}; top y {a and max(v[1] for v in a[0])} {b and max(v[1] for v in b[0])}')
check(bool(a) and bool(b) and sane(b) and len(b[1]) > 6 and same_mesh(a, b), 'E 1 Enter, then 2: the same mesh as E 2 Enter')
# the panel itself
base = ['--move', '615,360', '--key', 'tab', '--op', 'mesh.select_mode_face', '--op', 'mesh.inset 0.1']
r, ui = port(*base)
check(redo_rows(ui)[:2] == ['Inset Faces', 'Thickness 0.1'], f'after a tool: {redo_rows(ui)}')
f0 = faces(ui)
x, y, w, h = rect(ui, 'Thickness')
cx, cy = x + w // 2, y + h // 2
r, ui = port(*base, '--drag', f'{cx},{cy},{cx + 100},{cy}')
check(redo_rows(ui)[1] == 'Thickness 0.6', f'a 100 px drag: 0.005 a pixel: {redo_rows(ui)}')
check(faces(ui) == f0, f'the same faces ({faces(ui)})')
r, ui = port(*base, '--click', f'{cx},{cy}', '--key', 'ctrl+a', '--type', '0.1*2', '--key', 'enter')
check(redo_rows(ui)[1] == 'Thickness 0.2', f'click and type an expression: {redo_rows(ui)}')
r, ui = port(*base, '--key', 'f9', '--key', 'backspace', '--key', 'backspace', '--key', 'backspace', '--type', '0.3', '--key', 'enter')
check(redo_rows(ui)[1:2] == ['Thickness 0.3'], f'F9 and a typed value: {redo_rows(ui)}')
# one undo step, however often
r, ui = port(*base, '--op', 'edit.redo_last 0.2', '--op', 'edit.redo_last 0.3', '--op', 'edit.redo_last 0.05', '--op', 'undo', '--key', 'tab')
check(faces(ui) == 6, f'three re-runs and one undo: the cube again ({faces(ui)} faces)')
r, ui = port(*base, '--key', 'ctrl+z')
check(not redo_rows(ui), 'an undo ends the panel')
r, ui = port(*base, '--key', 'g', '--key', 'x', '--type', '1', '--key', 'enter')
check(not redo_rows(ui), 'a new step ends the panel')
r, ui = port(*base, '--key', 'tab')
check(not redo_rows(ui), 'leaving edit mode hides it')
r, ui = port('--op', 'edit.redo_last 1', '--dump-log', f'{T}/l.txt')
check('nothing to adjust' in open(f'{T}/l.txt').read(), 'nothing to adjust: it says so')
# negative: the minimum holds
r, ui = port(*base, '--op', 'edit.redo_last -3')
check(redo_rows(ui)[1] == 'Thickness 0', f'the minimum holds: {redo_rows(ui)}')
print(f'redo: fails {len(FAILS)}')
sys.exit(1 if FAILS else 0)
