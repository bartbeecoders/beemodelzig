#!/usr/bin/env python3
"""Curves in the window (curve.zig, curveui.zig), BeeModel's headless driver
(operators, keys and clicks as in the window, a shot of the frame):

  * a session of curve operators, each its own undo step as in the window:
    the curves whole, and each edited curve copied with room to spare (an
    edit copies when an undo step holds the curve: room + 16);
  * curve edit mode: Tab, G X 1 Enter, R Z 90 Enter, S 2 Enter on selected
    points and on a lone handle (aligned partners turned), Esc cancelling
    one, Ctrl+Z after: R Z keeps the heights, Esc changes nothing, Ctrl+Z
    gives the curve and mesh before the last step;
  * the look: the edit mode's points and handles over the view, a selection
    shown at once.

    python3 tests/curves_wl.py BIN

BEE_CPU (default 10) pins the runs.
"""
import math, os, shutil, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile
from PIL import Image

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
CPU = os.environ.get('BEE_CPU', '10')
FAILS = []
T = tempfile.mkdtemp(prefix='beecvwl-', dir='/tmp')
import atexit
atexit.register(shutil.rmtree, T, True)
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
VIEW = (210, 85, 1025, 630)
SELECTED, ALIGNED = (0xff, 0xa0, 0x30), (0xd0, 0x70, 0xd0)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def port(*a, shot=None, ui=None):
    args = ['taskset', '-c', CPU, BIN, '--size', '1280x800', '--shot', shot or f'{T}/p.ppm']
    if ui:
        args += ['--dump-ui', ui]
    r = subprocess.run(args + list(a), capture_output=True, text=True, timeout=300, env=ENV)
    if r.returncode != 0:
        print(r.stderr[-1500:])
    return r.returncode


def script(code):
    open(f'{T}/s.bees', 'w').write(code)
    r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', f'{T}/s.bees'], capture_output=True, text=True, timeout=300, env=ENV)
    return r.returncode


def curv(path):
    c = beefile.chunk(path, b'CURV') or b''
    out, o = [], 0
    while len(c) - o >= 8:
        ix, n = struct.unpack_from('<II', c, o)
        rec = n * 48 + 580
        out.append(c[o:o + rec])
        o += rec
    return out


def points(rec):
    """[(co, left, right)] of a record (as returned by curv)."""
    n = struct.unpack_from('<I', rec, 4)[0]
    return [(struct.unpack_from('<3f', rec, 580 + 48 * k), struct.unpack_from('<3f', rec, 592 + 48 * k),
             struct.unpack_from('<3f', rec, 604 + 48 * k)) for k in range(n)]


def tiled(rec):
    """the record's splines tile its points, its numbers finite"""
    nspl, npts = struct.unpack_from('<II', rec, 8)
    at = 0
    for k in range(min(nspl, 32)):
        typ, cyc, first, cnt = struct.unpack_from('<4I', rec, 68 + 16 * k)
        if first != at:
            return False
        at += cnt
    return nspl <= 32 and at == npts and all(math.isfinite(x) for p in points(rec) for v in p for x in v)


def masked(rec):
    """a record without its capacity and mapping size"""
    return rec[:16] + b'\0' * 12 + rec[28:]


def meshes(path):
    """{object: (vertices as bytes, polygons)}"""
    ms = beefile.meshes(path)
    out = {}
    for o in beefile.objects(path):
        if o['mesh'] < len(ms):
            v, p = ms[o['mesh']]
            out[o['name']] = (b''.join(struct.pack('<3f', *x) for x in v), p)
    return out


def count(path, col, box=VIEW):
    return sum(1 for p in Image.open(path).convert('RGB').crop(box).get_flattened_data() if p == col)


SESSION = [('create.bezier', ''), ('curve.point', '2 1 0'), ('curve.set', 'bevel 0.25'), ('curve.select', '0 2'),
           ('curve.extrude', '0 0 1'), ('curve.select', 'all'), ('curve.subdivide', ''), ('curve.handle', 'vector'),
           ('curve.tilt', '30'), ('curve.radius', '0.5'), ('create.curve_circle', ''), ('curve.set', 'resolution 4'),
           ('create.path', ''), ('curve.set', 'profile BezierCircle'), ('curve.select', '1'), ('curve.delete', '')]


def s_session():
    print('-- operators one step each, as in the window: the curves whole, copied with room to spare')
    empty = f'{T}/empty.bee'
    script('n = count()\nfor i in 0..n { delete(name(0)) }\nop("file.save", "' + empty + '")\n')
    b = f'{T}/sess-p.bee'
    args = ['--op', f'file.open {empty}']
    for op, arg in SESSION:
        args += ['--op', f'{op} {arg}'.strip()]
    args += ['--op', f'file.save_as {b}']
    rc = port(*args)
    cb = curv(b) if os.path.exists(b) else []
    check(rc == 0 and len(cb) == 3 and all(tiled(r) for r in cb), f'three curves saved, whole ({rc}, {len(cb)})')
    # (each curve's last edit copied it under an undo step: its room, then 16 more)
    room = [(struct.unpack_from('<I', r, 16)[0], struct.unpack_from('<I', r, 12)[0]) for r in cb]
    check(room and all(cap >= n + 16 for cap, n in room), f'each edited curve copied with 16 points to spare (capacity, points: {room})')
    m = meshes(b) if os.path.exists(b) else {}
    check(len(m) == 3 and all(len(v) > 0 for v, p in m.values()), f'and their meshes ({[(k, len(v) // 12) for k, (v, p) in m.items()]})')
    return empty


def s_edit(empty):
    print('-- curve edit mode: Tab, G / R / S typed, a lone handle, Esc, Ctrl+Z')
    scene = f'{T}/edit.bee'
    script(f'op("file.open", "{empty}")\nop("create.bezier")\nop("curve.point", "2.1 0.3 -1.3")\n'
           f'op("curve.set", "bevel 0.1")\nop("file.save", "{scene}")\n')
    g = [('op', 'curve.select', '1'), ('key', 'g'), ('key', 'x'), ('key', '1'), ('key', 'enter')]
    r = [('op', 'curve.select', 'all'), ('key', 'r'), ('key', 'z'), ('key', '9'), ('key', '0'), ('key', 'enter')]
    s_esc = [('key', 's'), ('key', '2'), ('key', 'esc')]
    s = [('op', 'curve.select', '0'), ('key', 's'), ('key', '2'), ('key', 'enter')]
    start = ['--op', f'file.open {scene}', '--select', 'BezierCurve', '--move', '600,400', '--key', 'tab']

    def run(steps, out, extra=(), shot=None):
        args = list(start)
        for st in steps:
            args += ['--op', f'{st[1]} {st[2]}'] if st[0] == 'op' else ['--move', '600,400', '--key', st[1]]
        args += list(extra) + ['--op', f'file.save_as {out}', '--move', '600,400']
        if os.path.exists(out):
            os.remove(out)
        rc = port(*args, shot=shot)
        return curv(out) if rc == 0 and os.path.exists(out) else None

    c0 = curv(scene)
    cg = run(g, f'{T}/g.bee')
    cr = run(g + r, f'{T}/r.bee')
    ce = run(g + r + s_esc, f'{T}/e.bee')
    cs = run(g + r + s_esc + s, f'{T}/s.bee', shot=f'{T}/edit-p.ppm')
    cz = run(g + r + s_esc + s, f'{T}/z.bee', extra=['--key', 'ctrl+z'])
    ok = all(x is not None and len(x) == 1 and tiled(x[0]) for x in (c0, cg, cr, ce, cs, cz))
    check(ok, 'each run saved one whole curve')
    if not ok:
        return
    p0, pg = points(c0[0]), points(cg[0])
    check(pg[1][0][0] != p0[1][0][0] and pg[1][0][1:] == p0[1][0][1:] and pg[0] == p0[0], 'G X 1: the selected point moved along x alone')
    pr = points(cr[0])
    check(all(a[k][2] == b[k][2] for a, b in zip(pg, pr) for k in range(3)) and pr != pg, 'R Z 90: every point and handle turned, their heights kept')
    check(masked(ce[0]) == masked(cr[0]), 'S 2 Esc: the curve as it was')
    check(cs[0] != ce[0], 'S 2 Enter: the curve changed')
    # (curve.select is no step: the selection may differ)
    check(points(cz[0]) == points(ce[0]) and meshes(f'{T}/z.bee') == meshes(f'{T}/e.bee'), 'Ctrl+Z: the curve\'s points and its mesh as before the last step')
    if os.path.exists(f'{T}/edit-p.ppm'):
        n = {k: count(f'{T}/edit-p.ppm', c) for k, c in (('selected', SELECTED), ('aligned', ALIGNED))}
        check(all(v > 0 for v in n.values()), f'the overlay shows the points and handles ({n})')


def s_handle():
    print('-- a lone handle picked by a click and moved: its aligned partner turns')
    scene = f'{T}/edit.bee'
    start = ['--op', f'file.open {scene}', '--select', 'BezierCurve', '--move', '600,400', '--key', 'tab']
    port(*start, '--op', 'curve.select none', '--move', '600,400', shot=f'{T}/none-p.ppm')
    port(*start, '--op', 'curve.select 1', '--move', '600,400', shot=f'{T}/sel-p.ppm')
    sel0, sel1 = count(f'{T}/none-p.ppm', SELECTED), count(f'{T}/sel-p.ppm', SELECTED)
    check(sel0 == 0 and sel1 > 0, f'a point selected in edit mode shows at once ({sel0} then {sel1} orange pixels)')
    img = Image.open(f'{T}/none-p.ppm').convert('RGB')
    # the left handles of the first point: magenta (aligned) squares; the topmost one
    px = [(x, y) for y in range(VIEW[1], VIEW[3]) for x in range(VIEW[0], VIEW[2]) if img.getpixel((x, y)) == ALIGNED]
    if not px:
        check(False, 'the aligned handles are shown')
        return
    y0 = min(y for x, y in px)
    blob = [(x, y) for x, y in px if y <= y0 + 5]
    cx = sum(x for x, y in blob) // len(blob)
    cy = sum(y for x, y in blob) // len(blob)
    b = f'{T}/hd-p.bee'
    port(*start, '--op', 'curve.select none', '--move', '600,400', '--click', f'{cx},{cy}',
         '--move', '600,400', '--key', 'g', '--key', 'z', '--key', '1', '--key', 'enter', '--op', f'file.save_as {b}')
    ca = curv(b) if os.path.exists(b) else []
    c0 = curv(scene)[0]
    # (point 0: its place kept, its left handle moved, its right one turned)
    moved = len(ca) == 1 and ca[0][580:592] == c0[580:592] and ca[0][592:604] != c0[592:604] and ca[0][604:616] != c0[604:616]
    check(moved, f'the handle at {cx},{cy} moved, its point kept, its partner turned')
    check(len(ca) == 1 and tiled(ca[0]) and meshes(b) != meshes(scene), 'and its mesh follows')


def main():
    empty = s_session()
    s_edit(empty)
    s_handle()


main()
print(f'curves_wl: fails {len(FAILS)}')
