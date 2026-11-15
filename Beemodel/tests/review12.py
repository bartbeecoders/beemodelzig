#!/usr/bin/env python3
"""Review 12's findings:

  * s_view: geometry crossing the near plane. Bars 3 to 2 000 000 long along
    X and turned, a pole past the eye, the eye inside a big cube, the product
    template with the kernel on, in the maximized viewport: each drawn
    (shaded surfaces where it is solid, wires, the grid), and a 2 000 000
    long bar drawn as the 60 long one (it is cut where that one is).
  * s_refs: SKCH's count of references after undo, redo and a new step: the
    undo and redo steps hold the sketch, and an undo or redo gives back the
    sketch it had.
  * s_panels: the Light and Camera rows of the Object tab (labels, widgets,
    no folding section) and a light drawn in the viewport.
  * s_cad: the CAD tab's rows (headings without fold arrows, the units'
    list cut short, the scroll bar).

    python3 tests/review12.py BIN [runs=1]

BEE_CPU (default 12) pins BeeModel; RV_ONLY=s_view,s_refs,... runs some.
"""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile
from PIL import Image, ImageChops

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
CPU = os.environ.get('BEE_CPU', '12')
ONLY = [x for x in os.environ.get('RV_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beerv12-', dir='/tmp')
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def bee_run(code, timeout=900):
    """A BeeScript script (--run)."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code + '\n')
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return 'timeout'


def port(*a, shot=None, ui=None, timeout=900):
    shot = shot or f'{T}/u.ppm'
    args = ['taskset', '-c', CPU, BIN, '--shot', shot]
    if ui:
        args += ['--dump-ui', ui]
    try:
        r = subprocess.run(args + list(a), capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.returncode
    except subprocess.TimeoutExpired:
        return None


# ---- the maximized viewport's pixels -------------------------------------------------

def masked(x, y):
    """The overlays: the view's name, the gizmo, the axes in the corner, the toast."""
    return (x < 330 and y < 130) or (x > 1170 and y < 290) or (x < 100 and y > 680) or (x > 700 and y > 730)


def surface(p):
    r, g, b = p[:3]
    return max(r, g, b) - min(r, g, b) < 30 and r + g + b > 300


def surface_diff(a, b):
    """Pixels (every second one) shaded grey in one image only, and the grey
    ones in the first."""
    A = Image.open(a).convert('RGB').load()
    B = Image.open(b).convert('RGB').load()
    n = tot = 0
    for y in range(82, 774, 2):
        for x in range(2, 1278, 2):
            if masked(x, y):
                continue
            sa, sb = surface(A[x, y]), surface(B[x, y])
            tot += sa
            n += sa != sb
    return n, tot


def line_diff(a, b, box):
    """Pixels apart by more than 40 in a channel, outside box (the cursor's)."""
    d = ImageChops.difference(Image.open(a).convert('RGB'), Image.open(b).convert('RGB')).load()
    n = 0
    for y in range(82, 774):
        for x in range(2, 1278):
            if masked(x, y) or (box[0] <= x < box[2] and box[1] <= y < box[3]):
                continue
            if max(d[x, y]) > 40:
                n += 1
    return n


CURSOR = (600, 380, 680, 450)   # the 3D cursor at the world's origin
CUBE = (540, 290, 740, 490)     # and the cube over it (its outline: drawn otherwise)

SCENES = {
    'cube': 'o = add("cube", "C", 0, 1, 0)',
    'long30': 'o = add("cube", "Long", 30, 0.5, 0)\nscale(o, 30, 0.5, 0.5)',
    'long3': 'o = add("cube", "Long", 3, 0.5, 0)\nscale(o, 3, 0.5, 0.5)',
    'long100': 'o = add("cube", "Long", 100, 0.2, 0)\nscale(o, 100, 0.2, 0.2)',
    'rot30': 'o = add("cube", "Long", 0, 0.2, 0)\nscale(o, 100, 0.2, 0.2)\nrotate(o, 0, 30, 0)',
    'rot75': 'o = add("cube", "Long", 0, 0.2, 0)\nscale(o, 100, 0.2, 0.2)\nrotate(o, 0, 75, 20)',
    'huge': 'o = add("cube", "Huge", 1000000, 0.5, 0)\nscale(o, 1000000, 0.5, 0.5)',
    'inside': 'o = add("cube", "Big", 5, 0, 5)\nscale(o, 40, 40, 40)',
    'pole': 'o = add("cube", "Pole", 8, 0, 8)\nscale(o, 0.3, 30, 0.3)',
    'ground': 'op("create.ground")',
}
MODES = {'solid': [], 'wire': ['view.shading_wireframe'], 'editwire': ['mode.edit', 'view.shading_wireframe'], 'mat': ['view.shading_material'], 'nogrid': ['view.toggle_grid']}
CASES = [(s, 'solid') for s in SCENES] + [('tpl', 'solid')] + [(s, m) for s in ('long30', 'rot30', 'pole') for m in ('wire', 'editwire', 'mat')] + [('ground', 'nogrid')]


def s_view():
    print('-- the near plane: long bars, a pole, the eye inside, the template (maximized viewport) --')
    D = f'{T}/view'
    os.makedirs(D, exist_ok=True)
    code = 'n = count()\nfor i in 0..n { delete(name(0)) }\n'
    for name, body in SCENES.items():
        code += body + f'\nop("file.save_as", "{D}/{name}.bee")\ndelete(name(0))\n'
    bee_run(code)
    # (the template in a run of its own: into the scene as it starts)
    bee_run(f'op("help.template", "product")\nop("cad.kernel", "on")\nop("file.save_as", "{D}/tpl.bee")')
    check(all(os.path.exists(f'{D}/{n}.bee') for n in list(SCENES) + ['tpl']), 'a script made the scenes')
    empty = f'{D}/empty.bee'
    bee_run(f'n = count()\nfor i in 0..n {{ delete(name(0)) }}\nop("file.save_as", "{empty}")')
    port('--move', '600,300', '--op', f'file.open {empty}', '--op', 'area.maximize', shot=f'{D}/p_empty.ppm')
    for s_, mode in CASES:
        args = ['--move', '600,300', '--op', f'file.open {D}/{s_}.bee', '--op', 'area.maximize']  # (opened first: a file brings its own layout)
        for x in MODES[mode]:
            args += ['--op', x]
        rc = port(*args, shot=f'{D}/p_{s_}_{mode}.ppm')
        b = f'{D}/p_{s_}_{mode}.ppm'
        if rc != 0 or not os.path.exists(b):
            check(False, f'{s_} {mode}: drawn (exit {rc})')
            continue
        # (the ground: its fading grid; the eye inside a cube: its faces culled)
        if mode in ('solid', 'mat') and s_ not in ('ground', 'inside'):
            n, tot = surface_diff(f'{D}/p_empty.ppm', b)
            check(n > 1000, f'{s_} {mode}: shaded surfaces drawn ({n} sampled pixels of them)')
        if mode in ('wire', 'editwire'):
            n = line_diff(f'{D}/p_empty.ppm', b, (0, 0, 0, 0))
            check(n > 200, f'{s_} {mode}: the wires drawn ({n} pixels)')
    # a bar 2 000 000 long is cut where the 60 long one is: the same picture
    a, b = f'{D}/p_long30_solid.ppm', f'{D}/p_huge_solid.ppm'
    if os.path.exists(a) and os.path.exists(b):
        n = line_diff(a, b, (0, 0, 0, 0))
        check(n <= 60, f'the 2 000 000 long bar drawn as the 60 long one ({n} pixels apart)')


# ---- SKCH's references after undo ---------------------------------------------------------

def skch_refs(path):
    c = beefile.chunk(path, b'SKCH') if os.path.exists(path) else None
    return c


def s_refs():
    print('-- SKCH: the references the undo and redo steps hold (undo, redo, a new step) --')
    D = f'{T}/refs'
    os.makedirs(D, exist_ok=True)
    bee_run(f's = sketch("S", "XY")\nr = rect(s, 0, 0, 2, 1)\nop("file.save_as", "{D}/base.bee")')
    steps = [('cad.pad', 'Body 1 normal'), ('mech.joint', 'revolute S world axis 0 0 1 value frame*10deg'), ('#save', ''),
             ('edit.undo', ''), ('#save', ''), ('edit.undo', ''), ('#save', ''), ('edit.redo', ''), ('#save', ''),
             ('edit.redo', ''), ('#save', ''), ('edit.undo', ''), ('#save', ''), ('param.set', 'q 2mm'), ('#save', ''),
             ('edit.undo', ''), ('#save', ''), ('edit.undo', ''), ('#save', '')]
    for run in range(RUNS):
        args = ['--op', f'file.open {D}/base.bee', '--select', 'S']
        k = 0
        for i, a in steps:
            if i == '#save':
                args += ['--op', f'file.save_as {D}/p{k}.bee']
                k += 1
            else:
                args += ['--op', f'{i} {a}'.strip()]
        port(*args)
        c = [skch_refs(f'{D}/p{j}.bee') for j in range(k)]
        refs = [int.from_bytes(x[8:12], 'little') if x else None for x in c]
        body = [x[:8] + x[12:] if x else None for x in c]
        # saves: 0 pad+joint, 1 undo, 2 undo, 3 redo, 4 redo, 5 undo, 6 a new step, 7 undo, 8 undo
        check(all(r is not None and 1 <= r <= 16 for r in refs), f'every save has the sketch, held by its steps (refs {refs})')
        check(body[3] == body[1] and body[4] == body[0] and body[5] == body[1] and body[8] == body[2],
              'an undo or a redo gives back the sketch it had (but for the reference count)')


# ---- the Light and Camera rows, a light in the viewport -----------------------------------

def dump_rows(path):
    rows = []
    for ln in open(path, errors='replace'):
        p = ln.rstrip('\n').split('\t')
        if len(p) >= 3:
            try:
                x, y, w, h = map(int, p[2].split())
            except ValueError:
                continue
            rows.append((p[0], p[1], x, y, w, h))
    return rows


def s_panels():
    print('-- the Light and Camera rows (lcam_props) and a light\'s octahedron --')
    D = f'{T}/lc'
    os.makedirs(D, exist_ok=True)
    bee_run('n = count()\nfor i in 0..n { delete(name(0)) }\nadd("cube", "Cube", 0, 1, 0)\nadd("light", "Lamp", 4, 6, 1)\n'
             f'add("light", "Lamp2", -3, 2, 2)\nadd("camera", "Cam", 7, 5, 7)\nop("file.save_as", "{D}/lc.bee")')
    for nm in ('Lamp', 'Cam'):
        port('--op', f'file.open {D}/lc.bee', '--select', nm, '--move', '600,300', ui=f'{D}/p_{nm}.txt', shot=f'{D}/p_{nm}.ppm')
    port('--op', f'file.open {D}/lc.bee', '--select', 'Lamp', '--move', '600,300', '--op', 'area.maximize', shot=f'{D}/p_view.ppm')

    rows = dump_rows(f'{D}/p_Lamp.txt')
    want = [('heading', 'Light'), ('number', 'Power'), ('enum', 'Point'), ('number', 'Size')]
    got = [next((r for r in rows if r[0] == k and r[1] == lb), None) for k, lb in want]
    check(all(got), f'the Light rows: a heading (no fold arrow), Power, the type list, Size ({[g[:2] if g else None for g in got]})')
    check(not any(r[0] == 'section' and r[1] in ('Light', 'Camera') for r in rows) and not any(r[1] in ('Sun', 'Spot', 'Area', 'Radius') for r in rows),
          'no folding section, no Point / Sun / Spot / Area buttons, no Radius')
    if all(got):
        pw, pt, ps = got[1], got[2], got[3]
        check(pw[3] < pt[3] < ps[3] and pw[4] > 50 and pt[4] > 50 and ps[4] > 50, f'Power, the type, Size: one under another, fields of a width ({pw[3:5]} {pt[3:5]} {ps[3:5]})')
    rows = dump_rows(f'{D}/p_Cam.txt')
    lens = next((r for r in rows if r[0] == 'number' and r[1] == 'Lens (mm)'), None)
    check(lens is not None and lens[4] > 50, f'the camera\'s Lens (mm) field ({lens})')
    check(any(r[1] == 'This camera renders' for r in rows) and not any(r[1] in ('Renders the Scene', 'Render from This Camera') for r in rows),
          'the camera that renders: "This camera renders"')
    # the light in the viewport: its octahedron drawn
    import math
    b = f'{D}/p_view.ppm'
    if os.path.exists(b):
        # (where the lights are: the default view's projection, the maximized viewport)
        def proj(p):
            yaw, pitch, dist = 0.7853982, 0.5, 18.0
            sy, cy, sp, cp = math.sin(yaw), math.cos(yaw), math.sin(pitch), math.cos(pitch)
            right, up, fwd = (cy, 0, -sy), (-sp * sy, cp, -sp * cy), (-cp * sy, -sp, -cp * cy)
            eye = [-fwd[i] * dist for i in range(3)]
            d = [p[i] - eye[i] for i in range(3)]
            dot = lambda u, v: sum(u[i] * v[i] for i in range(3))
            f = 696 * 1.07
            z = dot(d, fwd)
            return int(640 + f * dot(d, right) / z), int(428 - f * dot(d, up) / z)
        for nm, p in (('active', (4, 6, 1)), ('unselected', (-3, 2, 2))):
            x, y = proj(p)
            box = (x - 30, y - 30, x + 30, y + 30)
            B = Image.open(b).convert('RGB').crop(box)
            lit = sum(1 for yy in range(60) for xx in range(60) if max(B.getpixel((xx, yy))) - min(B.getpixel((xx, yy))) > 60)
            check(lit > 10, f'the {nm} light: drawn where it is ({lit} coloured pixels around it)')


# ---- the CAD tab -------------------------------------------------------------------------

def s_cad():
    print('-- the CAD tab: the column, headings, the units\' list, the scroll bar --')
    D = f'{T}/cad'
    os.makedirs(D, exist_ok=True)
    bee_run('n = count()\nfor i in 0..n { delete(name(0)) }\nadd("cube", "Box", 0, 1, 0)\nselect("Box")\n' + f'op("file.save_as", "{D}/e.bee")')
    bee_run('n = count()\nfor i in 0..n { delete(name(0)) }\nop("scene.units", "mm")\n'
            'param("w", "60mm")\nparam("d", "40mm")\nparam("h", "20mm")\nparam("a", "0deg")\n'
            's = sketch("S", "XY")\nr = rect(s, 0, 0, 60, 40)\nselect("S")\n_ = pad("Part", "S", "h", "normal")\n'
            '_ = fillet("Part", "3mm", "vertical")\nop("mech.joint", "revolute Part world axis 0 0 1 value a")\n' + f'op("file.save_as", "{D}/c.bee")')
    if not os.path.exists(f'{D}/c.bee'):
        check(False, 'a script made the CAD scene')
        return
    port('--op', f'file.open {D}/c.bee', '--select', 'Part', '--click-label', 'CAD', '--move', '600,300', ui=f'{D}/p.txt', shot=f'{D}/p.ppm')
    # no parameters, features or joints: the hints and the buttons
    port('--op', f'file.open {D}/e.bee', '--select', 'Box', '--click-label', 'CAD', '--move', '600,300', ui=f'{D}/pe.txt', shot=f'{D}/pe.ppm')
    rows0 = [r for r in dump_rows(f'{D}/pe.txt') if r[2] > 1040 and r[3] > 180]
    for lb in ('Add Parameter...', 'New Sketch...', 'Add Joint...', 'Measure Tool'):
        pe = next((r[2:] for r in rows0 if r[1] == lb), None)
        check(pe is not None, f'no parameters, features or joints: {lb} there ({pe})')
    rows = [r for r in dump_rows(f'{D}/p.txt') if r[2] > 1040 and r[3] > 180]
    ys = []
    for lb in ('Add Parameter...', 'Exact B-rep solids', 'New Sketch...', 'Pad', 'Infill', 'Add Joint...', 'Measure Tool', 'Mass Properties'):
        pe = next((r[2:] for r in rows if r[1] == lb), None)
        check(pe is not None, f'{lb}: there ({pe})')
        if pe:
            ys.append(pe[1])
    check(ys == sorted(ys), f'in the column\'s order, top to bottom ({ys})')
    pe = next((r for r in rows if r[0] == 'enum' and r[1] == 'Millimetres'), None)
    check(pe is not None, f'the units\' list ({pe})')
    heads = [r for r in rows if r[0] == 'heading']
    check([h[1] for h in heads] == ['Parameters', 'Features', 'Mechanism', 'Measure'] and not any(r[0] == 'section' for r in rows),
          f'four plain headings, no fold arrows ({[h[:2] for h in heads]})')
    col = min((r[2] for r in rows), default=None)
    check(heads and all(h[2] == heads[0][2] for h in heads) and col is not None and heads[0][2] - col <= 10,
          f'the headings at the column\'s left ({[h[2] for h in heads]}, the column from {col})')
    pbar = any(r[0] == 'scrollbar' for r in rows)
    check(pbar, 'the scroll bar')
    # the list cut short: no "Millimetres" in full (its last letters are not drawn)
    if pe is not None:
        im = Image.open(f'{D}/p.ppm').convert('RGB')
        x0, y0, w, h = pe[2:]
        # (the text's right end: bright pixels in the field, short of the chevron)
        xs = [x for x in range(x0, x0 + w - 20) for y in range(y0 + 4, y0 + h - 4) if sum(im.getpixel((x, y))) > 450]
        check(xs and max(xs) <= x0 + w - 20, f'"Millimetres" cut short of the chevron (text to x {max(xs) if xs else None})')


SECTIONS = [s_view, s_refs, s_panels, s_cad]

if __name__ == '__main__':
    print(f'review12: runs {RUNS}, binary {BIN}')
    try:
        for fn in SECTIONS:
            if ONLY and fn.__name__ not in ONLY:
                continue
            fn()
    finally:
        shutil.rmtree(T, ignore_errors=True)
    print(f'review12 fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)
