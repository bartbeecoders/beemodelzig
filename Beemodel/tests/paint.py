#!/usr/bin/env python3
"""Painting: the same dabs from a BeeScript script (--run) and from the console give the
same texels, vertex colours and weights, to the bit; hand strokes through the fake
compositor (tests/wl_fake.py, on one CPU), undone and redone in the window as the
strokes they leave; layers, undo with values, files saved and opened again, what the
viewport shows, a UV Editor stroke, bakes into layers, damaged input. Every comparison
also asserts that what it compares moved.

    python3 tests/paint.py BIN [fuzz-runs=40] [seed] [scenario...]
"""
import hashlib, io, os, random, shutil, struct, subprocess, sys, tempfile, time
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

def wait_saved(f, path, limit=60.0):
    """A save through the window is done when its file is there (atomicfile: whole
    or absent). A fixed pause lost the save under load, and the comparison then
    read the previous case's file."""
    t0 = time.time()
    while not os.path.exists(path) and time.time() - t0 < limit:
        f.pump(0.1)


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile
from PIL import Image

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 40
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
WANT = sys.argv[4:]
FAILS = []
T = tempfile.mkdtemp(prefix='beept-', dir=os.environ.get('BEERIG_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)
ONE = ['taskset', '-c', os.environ.get('PAINT_CPU', '2')]
ONLY = os.environ.get('PAINT_ONLY', '')  # (the window's cases with this in their name)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def bee(code, one=True):
    """A BeeScript script (--run): what it printed."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    r = subprocess.run((ONE if one else []) + [BIN, '--run', p], capture_output=True, text=True, timeout=900, env=ENV)
    if 'error:' in r.stdout + r.stderr:
        print((r.stdout + r.stderr)[-600:])
    return r.stdout


def port(*a, ok=True, one=True, size=None, env=None):
    r = subprocess.run((ONE if one else []) + [BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *(('--size', size) if size else ()), *a], capture_output=True, text=True, timeout=900, env=env or ENV)
    if ok and r.returncode != 0:
        print(r.stderr[-1500:])
        check(False, f'BeeModel stopped ({r.returncode}): {list(a)[:6]}')
    return r


def ops(*lines):
    return [x for ln in lines for x in ('--op', ln)]


def logged():
    return open(f'{T}/log.txt').read().splitlines()


def chunk(path, tag):
    return b''.join(b for t, b in beefile.chunks(path) if t == tag)


def rgba(png):
    return Image.open(io.BytesIO(png)).convert('RGBA')


def images(path):
    """The embedded images of a file: {index: (w, h, RGBA bytes)}."""
    d = chunk(path, b'IMGD')
    out, o = {}, 0
    while o + 8 <= len(d):
        ix, n = struct.unpack_from('<II', d, o)
        im = rgba(d[o + 8:o + 8 + n])
        out[ix] = (im.width, im.height, im.tobytes())
        o += 8 + n
    return out


def layers(path):
    """ILAY: {image: (active, [(opacity, blend, visible, RGBA bytes)])}."""
    d = chunk(path, b'ILAY')
    out, o = {}, 0
    while o + 12 <= len(d):
        ix, count, active = struct.unpack_from('<III', d, o)
        o += 12
        ls = []
        for _ in range(count):
            op, bl, vis, n = struct.unpack_from('<fIII', d, o)
            ls.append((op, bl, vis, rgba(d[o + 16:o + 16 + n]).tobytes()))
            o += 16 + n
        out[ix] = (active, ls)
    return out


def mesh_order(path):
    """A mesh's place among the MESH chunks, by object name."""
    return {o['name']: o['mesh'] for o in beefile.objects(path)}


def vcols(path, name):
    """The object's vertex colours, as words; None: it has none."""
    k = mesh_order(path)[name]
    d = chunk(path, b'MVCL')
    o = 0
    while o + 8 <= len(d):
        ix, n = struct.unpack_from('<II', d, o)
        if ix == k:
            return list(struct.unpack_from(f'<{n}I', d, o + 8))
        o += 8 + n * 4
    return None


def weights(path, name):
    """The object's skin weights, as raw records; None: it has none."""
    k = mesh_order(path)[name]
    d = chunk(path, b'MWGT')
    o = 0
    while o + 8 <= len(d):
        ix, n = struct.unpack_from('<II', d, o)
        if ix == k:
            return d[o + 8:o + 8 + n * 20]
        o += 8 + n * 20
    return None


def px_diff(a, b):
    """Texels that differ, and by how much at most."""
    n = w = 0
    for i in range(0, min(len(a), len(b)), 4):
        if a[i:i + 4] != b[i:i + 4]:
            n += 1
            w = max(w, max(abs(a[i + k] - b[i + k]) for k in range(4)))
    return n, w


# A hand stroke's depth test reads the rasterizer's 1 / z: a texel right at the 1.5% limit
# can go the other way from one run to another. A few may.
FEW = 3


def same_px(name, a, b, base=None, tol=0, few=0):
    if len(a) != len(b) or not a:
        check(False, f'{name}: {len(a) // 4} and {len(b) // 4} texels')
        return
    n, w = px_diff(a, b)
    if base is not None:
        c, _ = px_diff(a, base)
        if c == 0:
            check(False, f'{name}: nothing changed')
            return
    moved = '' if base is None else f', {px_diff(a, base)[0]} painted'
    check(w <= tol or n <= few, f'{name}: {len(a) // 4} texels{moved}, {n} differ, worst {w}')


BALL = '''delete("Cube")
add("sphere", "S", 0, 2, 0)
scale("S", {s}, {s}, {s})
select("S")
op("uv.smart_project")
op("image.new", "tex {w} {w}")
material("Mat")
c = node("Mat", "image", "tex", 1)
socket("Mat", "base", c)
assign("S", "Mat")
op("file.save", "{out}")
'''


def bases():
    """The scenes, made by a script."""
    p = f'{T}/ball.bee'
    if os.path.exists(p):
        return
    bee(BALL.format(s=3.5, w=256, out=p))
    check(os.path.exists(p), 'the script saved the scene')


def script(base, code, cmds, tag='x'):
    """A script, then the same as console lines, from one file: both files."""
    o, q = f'{T}/o{tag}.bee', f'{T}/p{tag}.bee'
    bee(f'op("file.open", "{base}")\n{code}op("file.save", "{o}")\n')
    port('--op', f'file.open {base}', *ops(*cmds), '--op', f'file.save {q}')
    return o, q


def wrap(binary):
    p = f'{T}/{hashlib.sha1(binary.encode()).hexdigest()[:8]}.sh'
    open(p, 'w').write(f'#!/bin/sh\nexec taskset -c {ONE[2]} {binary} "$@"\n')
    os.chmod(p, 0o755)
    return p


KEYS = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
KEYS.update({'.': 52, '/': 53, ' ': 57, '0': 11, '-': 12, '=': 13})
KEYS.update({str(i): i + 1 for i in range(1, 10)})


class Win:
    """BeeModel in the fake compositor (tests/wl_fake.py), 1280 x 800, with the few
    helpers the cases use: move, drag, type, image."""

    def __init__(self, binary, args=()):
        from wl_fake import Fake
        self.w = Fake(binary, size=(1280, 800), args=args)
        self.proc = self.w.proc

    def pump(self, t=0.8):
        self.w.pump(t)

    @property
    def frames(self):
        return self.w.frames

    def enter(self, x, y):
        self.w.enter(x, y)

    def move(self, x, y):
        self.w.motion(x, y)
        self.w.pump(0.01)

    def key(self, code):
        self.w.key(code)

    def mods(self, m):
        self.w.mods(m)

    def button(self, pressed):
        self.w.button(0x110, pressed)

    def drag(self, x0, y0, x1, y1, steps=16):
        self.move(x0, y0)
        self.w.pump(0.05)
        self.button(True)
        self.w.pump(0.05)
        for k in range(1, steps + 1):
            self.move(int(x0 + (x1 - x0) * k / steps), int(y0 + (y1 - y0) * k / steps))
            self.w.pump(0.03)
        self.button(False)
        self.w.pump(0.1)

    def type(self, text):
        for c in text:
            if c == '_':
                self.w.key(12, 1)
            elif c == ':':
                self.w.key(39, 1)
            elif c.isupper():
                self.w.key(KEYS[c.lower()], 1)
            else:
                self.w.key(KEYS[c])

    def configure(self, w, h):
        self.w.configure(self.w.main(), (w, h))

    def image(self):
        s = self.w.surfaces[self.w.main().surface]
        bf = self.w.buffers[s.get('last')]
        return Image.frombuffer('RGBX', (bf['w'], bf['h']), s['pixels'], 'raw', 'BGRX', bf['stride'], 1).convert('RGB')


def fake(binary, scene_file, one=True):
    f = Win(wrap(binary) if one else binary, args=(scene_file,) if scene_file else ())
    f.w.until(lambda: f.frames > 0 and f.w.keyboard is not None and f.w.pointer is not None, 10)
    f.pump(1.0)
    f.enter(640, 300)
    f.pump(0.6)
    return None, f


def line(f, text):
    f.key(28)
    f.type(text)
    f.key(28)
    f.pump(0.2)


def combo(f, mods, code):
    f.mods(mods)
    f.key(code)
    f.mods(0)
    f.pump(0.1)


SHIFT, CTRL = 1, 4
TAB, KEYV, KEYW = 15, 47, 17


def front(f):
    """One camera: the viewport filling the window, looking along -Z."""
    combo(f, CTRL, 57)  # Ctrl+Space
    f.key(79)  # Numpad 1
    f.pump(1.0)


def session(binary, base, do, out, enter=(SHIFT, TAB), pre=()):
    """A real window: strokes by hand; the file it leaves, saved through the console."""
    _, f = fake(binary, base)
    for s in pre:
        line(f, s)
        f.key(1)
    f.move(640, 300)
    f.pump(0.2)
    front(f)
    if enter:
        combo(f, *enter)
        f.pump(0.6)
    do(f)
    f.pump(0.3)
    combo(f, CTRL, 57)
    f.pump(0.2)
    if os.path.exists(out):
        os.remove(out)
    line(f, f'file.save {out}')
    wait_saved(f, out)
    f.pump(0.2)
    f.proc.kill()
    f.proc.wait()


def stroke(*keys, steps=16, p=(560, 250, 720, 290)):
    def run(f):
        for k in keys:
            if isinstance(k, tuple):
                combo(f, k[0], k[1])
            else:
                f.key(k)
            f.pump(0.05)
        f.drag(*p, steps=steps)
    return run


def s_dabs():
    print('-- paint(): a dab around a point, to the bit --')
    bases()
    base = f'{T}/ball.bee'
    b0 = images(base)[0][2]
    c1 = [(0, 2, 3.5, 1.5, 200, 30, 10), (0.5, 2.5, 3.2, 0.8, 20, 230, 10), (-3.5, 2, 0, 2, 1, 2, 250), (0, 5.5, 0, 0.5, 255, 255, 0), (40, 40, 40, 1, 9, 9, 9)]
    code = ''.join(f'paint("S", {a}, {b}, {c}, {d}, {e}, {f}, {g})\n' for a, b, c, d, e, f, g in c1) + 'op("paint.strength_down")\n'
    cmds = [f'paint S {a} {b} {c} {d} {e} {f} {g}' for a, b, c, d, e, f, g in c1]
    o, q = script(base, code, cmds)
    same_px('five dabs, seams, one off the mesh', images(o)[0][2], images(q)[0][2], b0)
    # moved, turned, scaled, a parent's child
    m = f'{T}/moved.bee'
    bee(f'op("file.open", "{base}")\nmove("S", 1, -0.5, 2)\nrotate("S", 0.5, 0.3, -0.2)\nscale("S", 2, 3, 1.5)\nop("file.save", "{m}")\n')
    o, q = script(m, 'paint("S", 1, 1, 6, 2, 10, 200, 30)\nop("paint.color", "1 2 3")\npaint("S", 3, 3, 4, 3)\n', ['paint S 1 1 6 2 10 200 30', 'paint.color 1 2 3', 'paint S 3 3 4 3'], 'm')
    same_px('moved, turned, scaled', images(o)[0][2], images(q)[0][2], images(m)[0][2])
    # n-gons, a cylinder's caps
    c = f'{T}/cyl.bee'
    bee(f'delete("Cube")\nadd("cylinder", "S", 0, 1, 0)\nselect("S")\nop("uv.smart_project")\nop("image.new", "tex 128 128")\nmaterial("Mat")\nc = node("Mat", "image", "tex", 1)\nsocket("Mat", "base", c)\nassign("S", "Mat")\nop("file.save", "{c}")\n')
    o, q = script(c, 'paint("S", 0, 2, 0, 0.7, 250, 0, 0)\npaint("S", 1, 1, 0, 0.8, 0, 250, 0)\n', ['paint S 0 2 0 0.7 250 0 0', 'paint S 1 1 0 0.8 0 250 0'], 'c')
    same_px('n-gons', images(o)[0][2], images(q)[0][2], images(c)[0][2])
    print('-- strength --')
    lines = ['paint.strength_down', 'paint.strength_down', 'paint.strength_down']
    code = ''.join(f'op("{x}")\n' for x in lines)
    o, q = script(base, code + 'paint("S", 0, 2, 3.5, 1.5, 200, 30, 10)\n', lines + ['paint S 0 2 3.5 1.5 200 30 10'], 's')
    same_px('a weaker brush', images(o)[0][2], images(q)[0][2], b0)
    lines = ['paint.radius_up'] * 3 + ['paint.strength_up'] * 4
    code = ''.join(f'op("{x}")\n' for x in lines)
    o, q = script(base, code + 'paint("S", 0, 2, 3.5, 1.5, 200, 30, 10)\n', lines + ['paint S 0 2 3.5 1.5 200 30 10'], 's')
    same_px('full strength', images(o)[0][2], images(q)[0][2], b0)
    print('-- a file\'s image, no image, no UVs --')
    r = port('--op', 'paint Cube 0 1 1 1 1 2 3', ok=False)
    check(any('no image to paint' in x for x in logged()), 'a cube with nothing: paint says so')
    out = bee('print("r", paint("Cube", 0, 1, 1, 1, 1, 2, 3))\n')
    check('r 0' in out, f'and a script\'s paint() gives 0 ({out.strip()[:40]})')


def s_vcol():
    print('-- vpaint(), vertex by vertex --')
    bases()
    base = f'{T}/ball.bee'
    D = [(0, 2, 3.5, 2, 200, 30, 10), (1, 3, 3, 1.1, 20, 230, 10), (-1, 1, 3, 3, 1, 2, 250)]
    o, q = script(base, ''.join('vpaint("S", {}, {}, {}, {}, {}, {}, {})\n'.format(*d) for d in D), ['vpaint S {} {} {} {} {} {} {}'.format(*d) for d in D], 'v')
    a, c = vcols(o, 'S'), vcols(q, 'S')
    check(a == c and a and len(set(a)) > 10, f'{len(a or [])} vertices, {len(set(a or []))} colours, the same words')
    check(vcols(base, 'S') is None, 'the file had none')
    print('-- a colour a vertex: white where untouched, opaque --')
    check(a.count(0xffffffff) > 5 and all(x >> 24 == 255 for x in a), 'white, alpha 255')
    print('-- moved, scaled --')
    m = f'{T}/moved.bee'
    bee(f'op("file.open", "{base}")\nmove("S", 1, -0.5, 2)\nrotate("S", 0.5, 0.3, -0.2)\nscale("S", 2, 3, 1.5)\nop("file.save", "{m}")\n')
    o, q = script(m, 'vpaint("S", 1, 1, 6, 3, 10, 200, 30)\n', ['vpaint S 1 1 6 3 10 200 30'], 'w')
    check(vcols(o, 'S') == vcols(q, 'S') and len(set(vcols(q, 'S'))) > 5, 'in world space')
    print('-- what is kept, what goes --')
    o2 = f'{T}/vk.bee'
    bee(f'add("sphere", "K", 3, 0, 0)\nvpaint("K", 3, 1, 0, 1.6, 0, 255, 0)\nop("file.save", "{o2}")\n')
    v0 = vcols(o2, 'K')
    q = f'{T}/vk2.bee'
    port('--op', f'file.open {o2}', '--select', 'K', '--op', 'object.duplicate', '--op', 'move 1 0 0', '--op', f'file.save {q}')
    check(vcols(q, 'K') == v0, 'a duplicate keeps them')
    port('--op', f'file.open {o2}', '--select', 'K', '--op', 'mode.edit', '--move', '640,300', '--key', 'g', '--move', '660,320', '--press', '660,320', '--release', '660,320', '--op', 'mode.object', '--op', f'file.save {q}')
    check(vcols(q, 'K') == v0 and beefile.meshes(q)[mesh_order(q)['K']][0] != beefile.meshes(o2)[mesh_order(o2)['K']][0], 'vertices moved: they stay')
    port('--op', f'file.open {o2}', '--select', 'K', '--op', 'mode.edit', '--op', 'mesh.subdivide', '--op', 'mode.object', '--op', f'file.save {q}')
    check(vcols(q, 'K') is None, 'a new topology has none')
    a = bee(f'op("file.open", "{o2}")\nselect("K")\nop("mode.toggle_edit")\nop("mesh.select_all")\nop("mesh.subdivide")\nop("mode.toggle_edit")\nprint("vc", vcol("K", 0, 0))\n')
    check('vc -1' in a, f'(a script reads none either: {a.strip()[:30]})')


RIG = """delete("Cube")
add("sphere", "S", 0, 2, 0)
scale("S", 3.5, 3.5, 3.5)
a = armature("Rig")
op("arm.bone", "Up Bone 0 2 0 0 5 0")
op("arm.bone", "Side Bone 0 2 0 3 2 0")
op("arm.parent", "S Rig")
select("S")
op("file.save", "{out}")
"""


def rig():
    p = f'{T}/rig.bee'
    if not os.path.exists(p):
        bee(RIG.format(out=p))
    return p


def s_weights():
    print('-- wpaint(): weights, record by record --')
    p = rig()
    w0 = weights(p, 'S')
    check(w0 is not None and len(w0) > 100, f'automatic weights to start with ({len(w0 or b"") // 20} vertices)')
    D = [(0, 5, 0, 2.5, 0, 0.5), (3, 2, 0, 2, 1, 0.8), (0, 2, 3.5, 3, 0, 0.0), (0, 2, 3.5, 1.5, 1, 1.0)]
    o, q = script(p, ''.join('wpaint("S", {}, {}, {}, {}, {}, {})\n'.format(*d) for d in D), ['wpaint S {} {} {} {} {} {}'.format(*d) for d in D], 'g')
    a, c = weights(o, 'S'), weights(q, 'S')
    check(a == c and a != w0, f'{len(a) // 20} records: {sum(1 for i in range(0, len(a), 20) if a[i:i + 20] != w0[i:i + 20])} changed, the same bytes')
    print('-- no weights yet: slots from nothing, the lightest goes --')
    n = f'{T}/nw.bee'
    bee(f'delete("Cube")\nadd("sphere", "S", 0, 2, 0)\nscale("S", 3.5, 3.5, 3.5)\na = armature("Rig")\nb = 0\nwhile b < 6 {{\n op("arm.bone", "B" + str(b) + " Bone 0 2 0 " + str(b) + " 5 0")\n b = b + 1\n}}\nop("file.save", "{n}")\n')
    code = ''
    cmds = []
    # an Armature modifier naming Rig, no weights
    bee(f'op("file.open", "{n}")\nop("arm.parent", "S Rig")\nop("file.save", "{n}")\n')
    for b in range(6):
        code += f'wpaint("S", 0, 2, 3.5, 2.5, {b}, {0.1 * (b + 2)})\n'
        cmds.append(f'wpaint S 0 2 3.5 2.5 {b} {0.1 * (b + 2)}')
    o, q = script(n, code, cmds, 'h')
    check(weights(o, 'S') == weights(q, 'S'), 'six bones on four slots')
    print('-- the skin follows --')
    o2, q2 = f'{T}/skino.bee', f'{T}/skinp.bee'
    out = bee(f'op("file.open", "{p}")\nwpaint("S", 0, 5, 0, 2.5, 0, 0)\nselect("Rig")\nop("arm.pose", "Up rot 30 0 0")\nprint("V", evpos("S", 0, "x"), evpos("S", 0, "y"), evpos("S", 40, "z"))\nop("file.save", "{o2}")\n')
    port('--op', f'file.open {p}', '--op', 'wpaint S 0 5 0 2.5 0 0', '--select', 'Rig', '--op', 'arm.pose Up rot 30 0 0', '--op', f'file.save {q2}')
    check(weights(o2, 'S') == weights(q2, 'S'), 'painted, posed: the same file records')
    print('-- applied, the colours come along --')
    o2, q2 = f'{T}/apo.bee', f'{T}/app.bee'
    bee(f'op("file.open", "{p}")\nvpaint("S", 0, 2, 3.5, 2, 200, 30, 10)\nmodapply("S", 0)\nop("file.save", "{o2}")\n')
    port('--op', f'file.open {p}', '--select', 'S', '--op', 'vpaint S 0 2 3.5 2 200 30 10', '--op', 'object.modifier_apply 0', '--op', f'file.save {q2}')
    check(vcols(o2, 'S') == vcols(q2, 'S') and vcols(q2, 'S') is not None, 'the Armature modifier applied')
    print('-- no armature --')
    r = port('--op', 'wpaint Cube 0 1 1 1 0 1', ok=False)
    check(r.returncode == 0 and any('no armature' in x for x in logged()), 'no armature: says so')


def s_layers():
    print('-- layers: the composite and the stack, to the bit --')
    bases()
    base = f'{T}/ball.bee'
    b0 = images(base)[0][2]
    d1 = 'paint("S", 0, 2, 3.5, 2, 200, 30, 10)\n'
    c1 = 'paint S 0 2 3.5 2 200 30 10'
    d2 = 'paint("S", 1, 3, 3, 1.2, 10, 220, 30)\n'
    c2 = 'paint S 1 3 3 1.2 10 220 30'
    L = 'tex'
    cases = [
        ('a layer over the base', f'layer("{L}", "add")\n' + d1, [f'layer {L} add', c1]),
        ('two, one half', d1 + f'layer("{L}", "add")\n' + d1 + f'layer("{L}", "opacity", 1, 0.5)\nlayer("{L}", "add")\n' + d2, [c1, f'layer {L} add', c1, f'layer {L} opacity 1 0.5', f'layer {L} add', c2]),
        ('multiply', d1 + f'layer("{L}", "add")\n' + d2 + f'layer("{L}", "blend", 1, 1)\n', [c1, f'layer {L} add', c2, f'layer {L} blend 1 1']),
        ('add', d1 + f'layer("{L}", "add")\n' + d2 + f'layer("{L}", "blend", 1, 2)\nlayer("{L}", "opacity", 1, 0.3)\n', [c1, f'layer {L} add', c2, f'layer {L} blend 1 2', f'layer {L} opacity 1 0.3']),
        ('add, past white', d1 + f'layer("{L}", "add")\n' + d1 + f'layer("{L}", "blend", 1, 2)\n', [c1, f'layer {L} add', c1, f'layer {L} blend 1 2']),
        ('hidden', f'layer("{L}", "add")\n' + d1 + f'layer("{L}", "visible", 1, 0)\n', [f'layer {L} add', c1, f'layer {L} visible 1 0']),
        ('the base hidden', d1 + f'layer("{L}", "add")\n' + d2 + f'layer("{L}", "visible", 0, 0)\n', [c1, f'layer {L} add', c2, f'layer {L} visible 0 0']),
        ('paint on a hidden layer', f'layer("{L}", "add")\nlayer("{L}", "visible", 1, 0)\n' + d1, [f'layer {L} add', f'layer {L} visible 1 0', c1]),
        ('a layer below', f'layer("{L}", "add")\nlayer("{L}", "add")\n' + d1 + f'layer("{L}", "active", 1)\n' + d2, [f'layer {L} add', f'layer {L} add', c1, f'layer {L} active 1', c2]),
        ('removed', f'layer("{L}", "add")\n' + d1 + f'layer("{L}", "add")\n' + d2 + f'layer("{L}", "remove", 1)\n', [f'layer {L} add', c1, f'layer {L} add', c2, f'layer {L} remove 1']),
        ('merged', f'layer("{L}", "add")\n' + d1 + f'layer("{L}", "opacity", 1, 0.4)\nlayer("{L}", "merge")\n' + d2, [f'layer {L} add', c1, f'layer {L} opacity 1 0.4', f'layer {L} merge', c2]),
        ('merged with one', f'layer("{L}", "merge")\n' + d1, [f'layer {L} merge', c1]),
        ('painted twice over', f'layer("{L}", "add")\n' + d1 + d1, [f'layer {L} add', c1, c1]),
    ]
    for name, code, cmds in cases:
        o, q = script(base, code, cmds, 'l')
        same_px(name, images(o)[0][2], images(q)[0][2], None if 'hidden' in name else b0)
        a, c = layers(o), layers(q)
        ok = a.keys() == c.keys()
        for k in a:
            ok = ok and a[k][0] == c[k][0] and [x[:3] for x in a[k][1]] == [x[:3] for x in c[k][1]] and [x[3] for x in a[k][1]] == [x[3] for x in c[k][1]]
        check(ok, f'{name}: the stack the same ({[len(a[k][1]) for k in a]} layers)')
    print('-- sixteen at most --')
    code = ''.join(f'print("n", layer("{L}", "add"))\n' for _ in range(17))
    q = f'{T}/l16.bee'
    a = bee(f'op("file.open", "{base}")\n{code}print("c", layer("{L}", "count"))\nop("file.save", "{T}/o16.bee")\n')
    port('--op', f'file.open {base}', *ops(*[f'layer {L} add'] * 17), '--op', f'layer {L} count', '--op', f'file.save {q}')
    res = [ln.split(': ')[-1] for ln in logged() if ln.startswith(f'  layer {L}')]
    want = [ln.split()[1] for ln in a.splitlines() if ln[:2] in ('n ', 'c ')]
    check(res == want and want[-1] == '16' and want[-2] == '-1', f'the console as the script: {want[-4:]}')
    check(len(layers(q)[0][1]) == 16, 'the file has sixteen')
    print('-- out of range --')
    for w in ('active 5', 'opacity 9 1', 'blend 1 7', 'visible 3 1', 'remove 0', 'remove 9'):
        a = bee(f'op("file.open", "{base}")\nlayer("{L}", "add")\nprint("r", layer("{L}", "{w.split()[0]}", {", ".join(w.split()[1:])}))\n')
        port('--op', f'file.open {base}', '--op', f'layer {L} add', '--op', f'layer {L} {w}')
        r = [ln.split(': ')[-1] for ln in logged() if ln.startswith(f'  layer {L}')][-1]
        want = [ln.split()[1] for ln in a.splitlines() if ln.startswith('r ')][0]
        check(r == want, f'{w}: {r}, the console as the script')


def s_files():
    print('-- .bee saved and opened again: colours, weights, pixels, layers --')
    bases()
    p = rig()
    base = f'{T}/ball.bee'
    w = f'{T}/all.bee'
    bee(f'op("file.open", "{base}")\nvpaint("S", 0, 2, 3.5, 2, 200, 30, 10)\npaint("S", 0, 2, 3.5, 2, 200, 30, 10)\nlayer("tex", "add")\npaint("S", 1, 3, 3, 1.2, 10, 220, 30)\nlayer("tex", "add")\nlayer("tex", "opacity", 2, 0.25)\nlayer("tex", "blend", 2, 1)\nlayer("tex", "visible", 1, 0)\nlayer("tex", "active", 1)\nop("file.save", "{w}")\n')
    a = f'{T}/r1.bee'
    port('--op', f'file.open {w}', '--op', f'file.save {a}')
    check(vcols(a, 'S') == vcols(w, 'S') and vcols(a, 'S') and len(set(vcols(a, 'S'))) > 4, 'a script\'s file opened and saved: the colours')
    check(images(a)[0][2] == images(w)[0][2], 'the composite')
    la, lw = layers(a), layers(w)
    check(la == lw and len(la[0][1]) == 3 and la[0][0] == 1, f'the stack: {[x[:3] for x in la[0][1]]}, active {la[0][0]}')
    b = f'{T}/r2.bee'
    bee(f'op("file.open", "{a}")\nop("file.save", "{b}")\n')
    check(vcols(b, 'S') == vcols(w, 'S') and images(b)[0][2] == images(w)[0][2] and layers(b) == lw, 'a script opens the console\'s, and saves the same')
    print('-- and goes on from there --')
    o2, q2 = f'{T}/r3.bee', f'{T}/r4.bee'
    bee(f'op("file.open", "{a}")\npaint("S", 0, 3, 3, 1, 9, 9, 200)\nop("file.save", "{o2}")\n')
    port('--op', f'file.open {w}', '--op', 'paint S 0 3 3 1 9 9 200', '--op', f'file.save {q2}')
    same_px('on the active layer of each other\'s file', images(o2)[0][2], images(q2)[0][2], None)
    check(layers(o2) == layers(q2) != lw, 'the stacks too, and it landed')
    print('-- weights --')
    q = f'{T}/r5.bee'
    port('--op', f'file.open {p}', '--op', 'wpaint S 0 5 0 2.5 0 0.5', '--op', f'file.save {q}')
    b2 = f'{T}/r6.bee'
    bee(f'op("file.open", "{q}")\nop("file.save", "{b2}")\n')
    check(weights(b2, 'S') == weights(q, 'S') != weights(p, 'S'), 'a script keeps the console\'s weights')
    print('-- nothing painted: no chunk grows --')
    q = f'{T}/r7.bee'
    port('--op', f'file.open {base}', '--op', f'file.save {q}')
    check(chunk(q, b'MVCL') == b'' and chunk(q, b'ILAY') == b'', 'empty')
    tags = [t for t, _ in beefile.chunks(q)]
    check(tags.index(b'MUVS') + 1 == tags.index(b'MVCL') and tags.index(b'IMGD') < tags.index(b'ILAY'), 'in their places: MVCL after MUVS, ILAY after IMGD')
    print('-- a painted image goes into the file, the disk stays --')
    png = f'{T}/onfile.png'
    Image.new('RGBA', (32, 32), (10, 20, 30, 128)).save(png)
    png0 = open(png, 'rb').read()
    fb = f'{T}/fileimg.bee'
    bee(BALL.format(s=3.5, w=8, out=fb).replace('op("image.new", "tex 8 8")', f'op("image.load", "{png}")').replace('"image", "tex"', '"image", "onfile"'))
    q = f'{T}/r8.bee'
    port('--op', f'file.open {fb}', '--op', 'paint S 0 2 3.5 2 200 30 10', '--op', f'file.save {q}')
    check(open(png, 'rb').read() == png0, 'the PNG on disk is as it was')
    check(len(images(q)) == 1, 'saved inside the .bee')
    o = f'{T}/r9.bee'
    bee(f'op("file.open", "{fb}")\npaint("S", 0, 2, 3.5, 2, 200, 30, 10)\nop("file.save", "{o}")\n')
    # (the file keeps the alpha of a painted image, so a transparent image stays one)
    rgb = lambda b: bytes(x for i, x in enumerate(b) if i % 4 != 3)
    same_px('the same colours', rgb(images(o)[0][2]) * 2, rgb(images(q)[0][2]) * 2, None)
    al = images(q)[0][2][3::4]
    check(al.count(255) > 10 and al.count(128) > 10, f'painted texels opaque, the others as they were ({al.count(255)}, {al.count(128)})')
    o, q = script(fb, 'layer("onfile", "add")\npaint("S", 0, 2, 3.5, 2, 200, 30, 10)\nlayer("onfile", "opacity", 1, 0.5)\n', ['layer onfile add', 'paint S 0 2 3.5 2 200 30 10', 'layer onfile opacity 1 0.5'], 'a')
    same_px('a layer over a transparent image: the base counts as opaque', rgb(images(o)[0][2]) * 2, rgb(images(q)[0][2]) * 2, None)


def result(path):
    return {'im': images(path), 'la': layers(path), 'vc': vcols(path, 'S'), 'wg': weights(path, 'S')}


def one_session(name, base, do, enter=(SHIFT, TAB), pre=(), want='im', ref=None):
    """A session by hand: it painted (what it changed moved from the file); with ref
    (other steps, or 'base'), its file as that session's (an undo case)."""
    q = f'{T}/pw.bee'
    session(BIN, base, do, q, enter=enter, pre=pre)
    c = result(q)
    b0 = result(base)
    if ref is not None:
        if ref == 'base':
            a = b0
        else:
            r = f'{T}/rw.bee'
            session(BIN, base, ref, r, enter=enter, pre=pre)
            a = result(r)
        if a['im'] or c['im']:
            same_px(name, a['im'][0][2], c['im'][0][2], None, few=FEW)
        check(a['vc'] == c['vc'] and a['wg'] == c['wg'], f'{name}: colours and weights as {"the file" if ref == "base" else "the strokes it leaves"}')
        if a['la'] or c['la']:
            check(a['la'] == c['la'], f'{name}: the layers too ({[len(v[1]) for v in c["la"].values()]})')
        return a, c
    if want == 'vc':
        check(c['vc'] is not None and c['vc'] != b0['vc'] and len(set(c['vc'])) > 1, f'{name}: {len(c["vc"] or [])} vertices, {len(set(c["vc"] or []))} colours')
    elif want == 'wg':
        n = sum(1 for k in range(0, len(c['wg'] or b''), 20) if (c['wg'] or b'')[k:k + 20] != (b0['wg'] or b'')[k:k + 20])
        check(n > 0, f'{name}: {n} records changed ({len(c["wg"] or b"") // 20})')
    else:
        n, _ = px_diff(c['im'][0][2], b0['im'][0][2])
        check(n > 0, f'{name}: {n} texels painted')
    return b0, c


def mid(f, text):
    """A console line in the middle of a session: out of the maximized view and back."""
    combo(f, CTRL, 57)
    f.pump(0.2)
    line(f, text)
    f.key(1)
    f.pump(0.1)
    f.move(640, 300)
    f.pump(0.2)
    combo(f, CTRL, 57)
    f.pump(0.3)


def seq(*steps):
    def run(f):
        for s in steps:
            s(f)
    return run


def key(c):
    return lambda f: (f.key(c), f.pump(0.05))


def chord(m, c):
    return lambda f: combo(f, m, c)


def do(*a, steps=12):
    return lambda f: f.drag(*a, steps=steps)


def cmd(text):
    return lambda f: mid(f, text)


A_ = do(560, 250, 720, 290)
B_ = do(600, 330, 680, 280)
CZ = chord(CTRL, 44)
CSZ = chord(CTRL | SHIFT, 44)
TEX, VP, WP = (SHIFT, TAB), (SHIFT, KEYV), (CTRL, KEYW)


def s_window():
    print('-- the window: strokes by hand --')
    bases()
    base = f'{T}/ball.bee'
    cases = [
        ('a stroke', A_),
        ('a click', do(640, 250, 640, 250, steps=1)),
        ('bigger brush', seq(key(27), key(27), key(27), A_)),
        ('smaller, weaker', seq(key(26), key(26), chord(SHIFT, 26), chord(SHIFT, 26), A_)),
        ('at full strength', seq(chord(SHIFT, 27), chord(SHIFT, 27), chord(SHIFT, 27), A_)),
        ('the colour', seq(cmd('paint.color 20 200 90'), A_)),
        ('a jump: 64 dabs at most', seq(*[key(26)] * 8, do(560, 250, 720, 290, steps=1))),
        ('off the mesh on the way', do(300, 250, 1000, 250)),
        ('all around the silhouette', do(420, 130, 860, 560, steps=30)),
        ('a press off the mesh', do(100, 100, 640, 300)),
    ]
    for name, f in cases:
        if ONLY in name:
            one_session(name, base, f)


def s_depth():
    print('-- what is behind stays clean --')
    bases()
    p = f'{T}/occl.bee'
    bee(f'op("file.open", "{T}/ball.bee")\nadd("cube", "Wall", -1, 2, 4)\nscale("Wall", 0.4, 0.6, 0.1)\nselect("S")\nop("file.save", "{p}")\n')
    a, c = one_session('behind another object', p, seq(key(27), key(27), do(420, 300, 860, 300, steps=24)))
    o = f'{T}/noocc.bee'
    session(BIN, f'{T}/ball.bee', seq(key(27), key(27), do(420, 300, 860, 300, steps=24)), o)
    n, _ = px_diff(images(o)[0][2], c['im'][0][2])
    check(n > 100, f'the wall holds {n} texels back')


def s_layers_window():
    print('-- layers by hand --')
    bases()
    base = f'{T}/ball.bee'
    N = chord(SHIFT, 49)
    PU, PD = key(104), key(109)
    cases = [
        ('a new layer', seq(N, A_)),
        ('two, below the top', seq(N, A_, N, B_, PD, do(600, 200, 700, 240))),
        ('above', seq(N, N, PD, A_, PU, B_)),
        ('below the base', seq(PD, PD, N, A_)),
        ('more than the top', seq(N, PU, PU, A_)),
    ]
    for name, f in cases:
        if ONLY in name:
            one_session(name, base, f)


def s_vpaint_window():
    print('-- vertex paint by hand --')
    bases()
    base = f'{T}/ball.bee'
    cases = [
        ('a stroke', A_),
        ('bigger', seq(key(27), key(27), key(27), A_, B_)),
        ('weaker, the colour', seq(chord(SHIFT, 26), chord(SHIFT, 26), cmd('paint.color 20 200 90'), A_)),
        ('a click', do(640, 250, 640, 250, steps=1)),
    ]
    for name, f in cases:
        if ONLY in name:
            one_session('vertex: ' + name, base, f, enter=VP, want='vc')


def s_wpaint_window():
    print('-- weight paint by hand --')
    p = rig()
    cases = [
        ('a stroke', A_),
        ('bigger', seq(key(27), key(27), key(27), A_)),
        ('a value', seq(cmd('paint.weight 0.25'), A_)),
        ('none', seq(cmd('paint.weight 0'), key(27), key(27), B_)),
    ]
    for name, f in cases:
        if ONLY in name:
            one_session('weight: ' + name, p, f, enter=WP, want='wg')


# (s_pen, a tablet pen's pressure, is gone: tests/wl_fake.py has no tablet protocol)


def s_undo_window():
    print('-- undo in the window: the file as the strokes it leaves --')
    bases()
    base = f'{T}/ball.bee'
    N = chord(SHIFT, 49)
    cases = [
        ('two strokes, one undone', seq(A_, B_, CZ), A_),
        ('undone, redone', seq(A_, B_, CZ, CZ, CSZ), A_),
        ('back to the file', seq(A_, CZ), 'base'),
        ('a new stroke drops the redo', seq(A_, B_, CZ, B_, CSZ), seq(A_, B_)),
        ('nothing to undo', seq(CZ, CZ, CSZ, A_), A_),
        ('out of the mode, back', seq(A_, chord(*TEX), chord(*TEX), CZ), 'base'),
        ('in a layer', seq(N, A_, B_, CZ), seq(N, A_)),
    ]
    for name, f, ref in cases:
        if ONLY in name:
            one_session('texture: ' + name, base, f, ref=ref)
    v = [
        ('two strokes, one undone', seq(A_, B_, CZ), A_),
        ('undone, redone', seq(A_, B_, CZ, CZ, CSZ), A_),
        ('a new stroke drops the redo', seq(A_, B_, CZ, B_, CSZ), seq(A_, B_)),
    ]
    for name, f, ref in v:
        if ONLY in name:
            one_session('vertex: ' + name, base, f, enter=VP, ref=ref)
    p = rig()
    for name, f, ref in v:
        if ONLY in name:
            one_session('weight: ' + name, p, f, enter=WP, ref=ref)


def info():
    ln = [x for x in logged() if x.startswith('  paint.info')]
    w = ln[-1].split() if ln else []
    return {w[i]: w[i + 1] for i in range(1, len(w) - 1, 2)}


def png_of(tag):
    return ['--op', f'image.save tex {T}/{tag}.png']


def rd(tag):
    return Image.open(f'{T}/{tag}.png').convert('RGBA').tobytes()


def s_undo():
    print('-- a stroke is one paint step, to the bit --')
    bases()
    base = f'{T}/ball.bee'
    a, b = 'paint S 0 2 3.5 2 200 30 10', 'paint S 1 3 3 1.2 10 220 30'
    port('--op', f'file.open {base}', *png_of('u0'), '--op', a, *png_of('u1'), '--op', b, *png_of('u2'), '--op', 'paint.info', '--op', 'paint.undo', *png_of('u3'), '--op', 'paint.undo', *png_of('u4'),
         '--op', 'paint.redo', *png_of('u5'), '--op', 'paint.redo', *png_of('u6'), '--op', 'paint.undo', '--op', 'paint.undo', '--op', 'paint.undo', *png_of('u7'))
    u = [rd(f'u{k}') for k in range(8)]
    said = any('nothing to undo' in x for x in logged())
    check(u[1] != u[0] and u[2] != u[1], 'two strokes')
    check(info()['hist'] == '2/2', f'two steps ({info()["hist"]})')
    port('--op', f'file.open {base}', '--op', 'paint S 0 2 3.5 0.2 200 30 10', '--op', 'paint.info')
    check(0 < int(info()['bytes']) < 65536 * 4 / 8, f'a step holds the box it touched ({info()["bytes"]} bytes, the image is {65536 * 4})')
    check(u[3] == u[1] and u[4] == u[0], 'undone, step by step')
    check(u[5] == u[1] and u[6] == u[2], 'redone')
    check(u[7] == u[0], 'past the start: the file\'s')
    check(said, 'and it says so')
    for w_ in ('add', 'merge'):
        port('--op', f'file.open {base}', '--op', a, '--op', 'layer tex add' if w_ == 'merge' else a, '--op', a, '--op', f'layer tex {w_}', '--op', 'paint.info')
        check(info()['hist'] == '0/0', f'layer {w_}: the steps are forgotten, they point at layers ({info()["hist"]})')
    print('-- 32 steps kept --')
    args = ['--op', f'file.open {base}']
    for k in range(40):
        args += ['--op', f'paint S {-1.5 + k * 0.08} 2 3.3 0.5 {k * 6} 200 30']
    args += png_of('n1') + ['--op', 'paint.undo'] * 45 + png_of('n2') + ['--op', 'paint.info']
    port(*args)
    check(info()['hist'] == '0/32', f'{info()["hist"]}')
    check(rd('n2') != rd('u0') and rd('n2') != rd('n1'), 'the oldest strokes stay')
    print('-- a new stroke drops the redo --')
    port('--op', f'file.open {base}', '--op', a, '--op', 'paint.undo', '--op', b, *png_of('r1'), '--op', 'paint.redo', *png_of('r2'), '--op', 'paint.undo', *png_of('r3'))
    check(rd('r1') == rd('r2') and rd('r3') == rd('u0'), 'nothing to redo; undo: the file\'s')
    print('-- the scene\'s undo and the paint undo are two histories --')
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'move 1 0 0', '--op', 'paint S 1 2 3.5 2 200 30 10', '--op', 'move 0 1 0', '--op', f'file.save {T}/h1.bee', *png_of('h1'), '--op', 'edit.undo', '--op', 'edit.undo', *png_of('h2'), '--op', f'file.save {T}/h2.bee', '--op', 'paint.undo', *png_of('h3'), '--op', 'edit.redo', *png_of('h4'))
    check(rd('h1') == rd('h2') and rd('h1') != rd('u0'), 'edit.undo leaves the image')
    check(rd('h3') == rd('u0') and rd('h4') == rd('u0'), 'paint.undo leaves the scene')
    locs = [next(o for o in beefile.objects(f'{T}/{x}.bee') if o['name'] == 'S')['loc'] for x in ('h1', 'h2')]
    check(locs[0] != locs[1], 'the object went back')
    print('-- the scene is replaced --')
    S_ = ['--op', f'file.save {T}/saved.bee']  # (a changed file asks first)
    port('--op', f'file.open {base}', '--op', a, *S_, '--op', f'file.open {base}', '--op', 'paint.info', '--op', 'paint.undo', *png_of('o1'))
    check(info()['hist'] == '0/0' and rd('o1') == rd('u0'), 'another file: no steps from before')
    r = port('--op', f'file.open {base}', '--op', a, *S_, '--op', 'file.new', '--op', 'paint.undo', '--op', 'paint.redo', '--op', 'paint.info', ok=False)
    check(r.returncode == 0 and info()['hist'] == '0/0', 'a new scene too')
    r = port('--op', f'file.open {base}', '--select', 'S', '--op', 'mode.texture_paint', '--op', 'paint.info', '--op', 'file.new', '--op', 'paint.info', ok=False)
    ln = [x for x in logged() if x.startswith('  paint.info')]
    check(' on 1 ' in ln[0] and ' on 0 ' in ln[-1], 'the mode ends with the scene')
    print('-- vertex colours: one scene step --')
    v = 'vpaint S 0 2 3.5 2 200 30 10'
    w = 'vpaint S 1 3 3 1.2 10 220 30'
    port('--op', f'file.open {base}', *ops(f'file.save {T}/v0.bee', v, f'file.save {T}/v1.bee', w, f'file.save {T}/v2.bee', 'edit.undo', f'file.save {T}/v3.bee', 'edit.undo', f'file.save {T}/v4.bee', 'edit.redo', f'file.save {T}/v5.bee', 'edit.redo', f'file.save {T}/v6.bee'))
    c = [vcols(f'{T}/v{k}.bee', 'S') for k in range(7)]
    check(c[0] is None and c[1] is not None and c[2] != c[1], 'the first stroke gives it colours')
    check(c[3] == c[1], 'undo: the colours of the first')
    check(c[4] is None, 'undo: none, as the file')
    check(c[5] == c[1] and c[6] == c[2], 'redo: each again')
    port('--op', f'file.open {base}', '--op', v, '--op', 'edit.undo_history')
    steps = [x.split('\t')[1] for x in open(f'{T}/u.txt') if x.startswith('step\t')]
    check(steps == ['Original', 'Vertex Paint'], f'the steps named ({steps})')
    port('--op', f'file.open {base}', '--op', v, '--op', w, '--op', 'edit.undo_history', '--click-label', 'step:Original', '--op', f'file.save {T}/j0.bee', '--click-label', 'step:Vertex Paint', '--op', f'file.save {T}/j1.bee', '--key', 'esc', ok=False)
    check(vcols(f'{T}/j0.bee', 'S') is None, 'the history list: back to the start')
    print('-- an edit between strokes --')
    port('--op', f'file.open {base}', '--select', 'S', '--op', v, '--op', 'mode.edit', '--key', 'g', '--move', '660,320', '--press', '660,320', '--release', '660,320', '--op', 'mode.object', '--op', w, '--op', f'file.save {T}/e1.bee', '--op', 'edit.undo', '--op', f'file.save {T}/e2.bee', '--op', 'edit.undo', '--op', 'edit.undo', '--op', f'file.save {T}/e3.bee', '--op', 'edit.redo', '--op', 'edit.redo', '--op', 'edit.redo', '--op', f'file.save {T}/e4.bee')
    e = [vcols(f'{T}/e{k}.bee', 'S') for k in (1, 2, 3, 4)]
    check(e[0] != e[1] and e[3] == e[0], 'undone and redone across a new mesh')
    print('-- a mesh others show --')
    port('--op', 'add cube', '--op', 'add cube', '--op', 'vpaint Cube.001 0 1 1 3 255 0 0', '--op', f'file.save {T}/s1.bee', '--op', 'edit.undo', '--op', 'mode.object', '--op', 'add cube', '--op', f'file.save {T}/s2.bee')
    p = f'{T}/s1.bee'
    check(vcols(p, 'Cube.001') is not None and vcols(p, 'Cube') is None and vcols(p, 'Cube.002') is None, 'a cube, not the others')
    check(vcols(f'{T}/s2.bee', 'Cube.003') is None, 'a new cube has none, undone or not')
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'object.duplicate', '--op', f'file.save {T}/d0.bee')
    dup = [o['name'] for o in beefile.objects(f'{T}/d0.bee') if o['name'] not in ('S', 'Camera', 'Light')][0]
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'object.duplicate', '--op', v, '--op', f'file.save {T}/d1.bee', '--op', 'edit.undo', '--op', f'file.save {T}/d2.bee')
    check(vcols(f'{T}/d1.bee', 'S') is not None and vcols(f'{T}/d1.bee', dup) is None, 'a duplicate of a painted mesh keeps out of it')
    check(vcols(f'{T}/d2.bee', 'S') is None, 'undone')
    print('-- two materials, one image --')
    sh = f'{T}/shared.bee'
    bee(f'op("file.open", "{base}")\nadd("cube", "B", 8, 2, 0)\nselect("B")\nop("uv.smart_project")\nmaterial("M2")\nc = node("M2", "image", "tex", 1)\nsocket("M2", "base", c)\nassign("B", "M2")\nop("file.save", "{sh}")\n')
    o, q = script(sh, 'paint("B", 8, 3, 1, 1.5, 0, 0, 255)\n', ['paint B 8 3 1 1.5 0 0 255'], 'sh')
    same_px('painted through the other object', images(o)[0][2], images(q)[0][2], images(sh)[0][2])
    print('-- weights: one scene step, the skin follows --')
    r = rig()
    D = lambda tag: ['--dump-verts', f'{T}/{tag}.txt;S']
    port('--op', f'file.open {r}', '--select', 'Rig', '--op', 'arm.pose Up rot 30 0 0', '--select', 'S', '--op', f'file.save {T}/w0.bee', *D('w0'), '--op', 'wpaint S 0 5 0 2.5 0 0', '--op', f'file.save {T}/w1.bee', *D('w1'), '--op', 'edit.undo', '--op', f'file.save {T}/w2.bee', *D('w2'), '--op', 'edit.redo', '--op', f'file.save {T}/w3.bee', *D('w3'))
    g = [weights(f'{T}/w{k}.bee', 'S') for k in range(4)]
    s = [open(f'{T}/w{k}.txt').read() for k in range(4)]
    check(g[1] != g[0] and g[2] == g[0] and g[3] == g[1], 'the records go and come back')
    check(s[1] != s[0] and s[2] == s[0] and s[3] == s[1], 'what shows follows them')
    print('-- no weights yet: undo takes them away --')
    n = f'{T}/nw2.bee'
    port('--op', f'file.open {r}', '--select', 'S', '--op', f'file.save {n}')
    hd = open(n, 'rb').read()[:8]
    cs_ = beefile.chunks(n)
    open(n, 'wb').write(hd + b''.join(t_ + struct.pack('<I', len(b)) + b for t_, b in cs_ if t_ != b'MWGT'))
    check(weights(n, 'S') is None, 'a skin with no weights')
    port('--op', f'file.open {n}', '--op', 'wpaint S 0 5 0 2.5 0 1', '--op', f'file.save {T}/nw1.bee', '--op', 'edit.undo', '--op', f'file.save {T}/nw3.bee')
    check(weights(f'{T}/nw1.bee', 'S') is not None and weights(f'{T}/nw3.bee', 'S') is None, 'made by the stroke, gone with it')
    print('-- leaving, Esc, Ctrl+Z, in a stroke --')
    fr = ['--op', f'file.open {base}', '--select', 'S', '--move', '640,300']
    P = ['--press', '620,330', '--move', '630,335', '--move', '640,340']
    port(*fr, '--op', 'mode.texture_paint', *P, '--key', 'ctrl+z', *png_of('m1'), '--release', '640,340', '--op', 'paint.info', *png_of('m2'))
    check(rd('m1') == rd('u0') and rd('m2') == rd('u0'), 'Ctrl+Z in a stroke: the stroke so far is a step, and it goes')
    port(*fr, '--op', 'mode.texture_paint', *P, '--op', 'mode.object', *png_of('m3'), '--release', '640,340', *png_of('m4'), '--op', 'paint.undo', *png_of('m5'))
    check(rd('m3') != rd('u0') and rd('m4') == rd('m3') and rd('m5') == rd('u0'), 'left in a stroke: what it did stays, one step')
    port(*fr, '--op', 'mode.texture_paint', *P, '--key', 'esc', '--move', '650,345', '--release', '650,345', *png_of('m6'), '--op', 'paint.undo', *png_of('m7'))
    check(rd('m6') != rd('u0') and rd('m7') == rd('u0'), 'Esc changes nothing: one step')
    port(*fr, '--op', 'mode.vertex_paint', *P, '--key', 'ctrl+z', '--op', f'file.save {T}/m8.bee', '--release', '640,340')
    check(vcols(f'{T}/m8.bee', 'S') is None, 'vertex paint: Ctrl+Z in a stroke, the same')
    for name, extra in (('a new scene', ['--op', 'file.new']), ('the object deleted', ['--op', 'delete S']), ('the file opened', ['--op', f'file.open {base}']), ('out of the window', ['--move', '5000,5000', '--move', '-300,-40', '--move', '640,340']), ('out of the mode and back', ['--op', 'object.texture_paint', '--op', 'object.texture_paint']), ('a new layer', ['--op', 'layer tex add']), ('merged', ['--op', 'layer tex add', '--move', '650,345', '--op', 'layer tex merge']), ('a key, the wheel', ['--key', 'g', '--key', 's', '--wheel', '640,340,3'])):
        for md in ('mode.texture_paint', 'mode.vertex_paint', 'mode.weight_paint'):
            r = port(*fr, '--op', md, *P, *extra, '--move', '650,345', '--release', '650,345', '--op', 'edit.undo', '--op', 'paint.undo', '--op', 'mode.object', ok=False)
            if r.returncode:
                check(False, f'{md}: {name}: {r.stderr[-300:]}')
                break
        else:
            check(True, f'{name} in a stroke, each mode')
    print('-- the title bar: painted is changed --')
    port('--op', f'file.open {base}', '--op', a, '--op', 'paint.info')
    check(info().get('changed') == '1', 'a stroke marks the file')
    port('--op', f'file.open {base}', '--op', a, '--op', f'file.save {T}/c.bee', '--op', 'paint.info')
    check(info().get('changed') == '0', 'saved: clean')
    port('--op', f'file.open {base}', '--op', 'paint.info')
    check(info().get('changed') == '0', 'opened: clean')
    print('-- autosave --')
    auto = f'{T}/auto'
    os.makedirs(auto, exist_ok=True)
    env = dict(ENV)
    args = ['--autosave-dir', auto, '--autosave-every', '3', '--op', f'file.open {base}'] + ops(a, b, a, b)
    r = port(*args, ok=False, env=env)
    found = [f for f in os.listdir(auto) if f.endswith('.bee')]
    good = False
    for f in found:
        try:
            ims = images(f'{auto}/{f}')
            good = good or (0 in ims and ims[0][2] != rd('u0'))
        except Exception as e:
            print('   ', f, e)
    check(good, f'strokes count as changes, the autosave has them ({found})')


def ball_px(a, b, cx=640, cy=343, r=140, tol=0):
    """Pixels of the ball that differ, of how many."""
    pa, pc = a.convert('RGB').load(), b.convert('RGB').load()
    pts = [(x, y) for y in range(cy - r, cy + r) for x in range(cx - r, cx + r) if (x - cx) ** 2 + (y - cy) ** 2 < r ** 2 and (x - cx) ** 2 + (y - 430) ** 2 > 20 ** 2 and (x - cx) ** 2 + (y - 345) ** 2 > 9 ** 2]  # (the 3D cursor, the origin)
    BONE = (180, 184, 192)  # (bones' lines are the rig's: over the mesh)
    bad = sum(1 for p in pts if max(abs(pa[p][k] - pc[p][k]) for k in range(3)) > tol and pa[p] != BONE and pc[p] != BONE)
    return bad, len(pts)


def look(base, pre=(), enter=None, shading=None):
    """The front camera, the pointer away: the picture."""
    _, f = fake(BIN, base)
    for s_ in pre:
        line(f, s_)
        f.key(1)
    f.move(640, 300)
    f.pump(0.2)
    front(f)
    if shading:
        mid(f, shading)
    if enter:
        combo(f, *enter)
        f.pump(0.5)
    f.move(100, 700)
    f.pump(0.8)
    im = f.image()
    f.proc.kill()
    f.proc.wait()
    return im


def s_look():
    print('-- the picture --')
    bases()
    base = f'{T}/ball.bee'
    v = f'{T}/vc.bee'
    bee(f'op("file.open", "{base}")\nvpaint("S", 0, 2, 3.5, 3, 200, 30, 10)\nvpaint("S", 2, 3, 3, 1.5, 10, 220, 30)\nop("file.save", "{v}")\n')
    plain = look(base)
    c = look(v)
    pc = c.convert('RGB').load()
    check(pc[640, 300] != pc[560, 343], 'Solid: tinted, not flat')
    bad, n = ball_px(plain, c)
    check(bad > n // 20, f'Solid: the colours show ({bad} of {n} pixels from the unpainted ball)')
    c = look(v, shading='view.shading_material')
    bad, n = ball_px(look(base, shading='view.shading_material'), c, tol=3)
    check(bad > n // 20, f'Material Preview: the colours show ({bad} of {n} pixels from the unpainted ball)')
    print('-- weights: the heat --')
    p = rig()
    c = look(p, enter=WP)
    pc = c.convert('RGB').load()
    check(pc[640, 300] != pc[560, 343] or pc[640, 300][2] > pc[640, 300][0], 'Weight Paint: the heat shows')
    print('-- Hive: the colours reach the render --')
    def rn(path, tag):
        d = f'{T}/{tag}'
        os.makedirs(d, exist_ok=True)
        port('--op', f'file.open {path}', '--op', 'render.settings 96 64 8', '--op', f'render.animation {d}/f.png 1 1')
        return Image.open(f'{d}/f/0001.png').convert('RGB')
    c, plain = rn(v, 'rp'), rn(base, 'rb')
    moved = sum(1 for x, y in zip(plain.tobytes()[0::3], c.tobytes()[0::3]) if x != y)
    check(moved > 100, f'the colours reach the render ({moved} pixels)')
    print('-- a material with no graph, no material --')
    nm = f'{T}/nomat.bee'
    bee(f'delete("Cube")\nadd("sphere", "S", 0, 2, 0)\nscale("S", 3, 3, 3)\nvpaint("S", 0, 2, 3, 4, 250, 20, 20)\nop("file.save", "{nm}")\n')
    c = rn(nm, 'rm2')
    px = c.load()
    r_, g_, b_ = px[48, 32][:3]
    check(r_ > g_ + 20 and r_ > b_ + 20, f'Hive, its default material tinted red ({px[48, 32]})')
    c = look(nm, shading='view.shading_material')
    pc = c.convert('RGB').load()
    check(pc[640, 310][0] > pc[640, 310][1] * 1.5, f'Material Preview: red ({pc[640, 310]})')
    print('-- a graph that reads them --')
    g = f'{T}/vg.bee'
    bee(f'op("file.open", "{v}")\nmaterial("VG")\nc = node("VG", "vcolor", 1)\nsocket("VG", "base", c)\nassign("S", "VG")\nop("file.save", "{g}")\n')
    c = look(g, shading='view.shading_material')
    bad, n = ball_px(look(base, shading='view.shading_material'), c, tol=3)
    check(bad > n // 20, f'Material Preview with a vertex colour node: the colours show ({bad} of {n})')
    print('-- what shows follows a stroke --')
    Pre = ['--op', f'file.open {base}', '--select', 'S', '--move', '640,300']
    S = ['--press', '612,270', '--move', '640,280', '--move', '660,290', '--release', '660,290', '--move', '100,700']
    for sh, name in (('view.shading_material', 'Material Preview'), ('view.shading_rendered', 'Rendered')):
        w = ['--live-wait'] if 'rendered' in sh else []
        port(*Pre, '--op', sh, '--op', 'mode.texture_paint', '--op', 'paint.color 255 0 0', '--op', 'paint.strength_up', '--op', 'paint.strength_up', '--move', '100,700', *w)
        a = open(f'{T}/u.ppm', 'rb').read()
        port(*Pre, '--op', sh, '--op', 'mode.texture_paint', '--op', 'paint.color 255 0 0', '--op', 'paint.strength_up', '--op', 'paint.strength_up', *S, *w)
        c = open(f'{T}/u.ppm', 'rb').read()
        port(*Pre, '--op', sh, '--op', 'mode.texture_paint', '--op', 'paint.color 255 0 0', '--op', 'paint.strength_up', '--op', 'paint.strength_up', *S, '--op', 'paint.undo', '--move', '101,700', *w)
        e = open(f'{T}/u.ppm', 'rb').read()
        hd = len(a) - 1280 * 800 * 3
        n1 = sum(1 for k in range(hd + 90 * 1280 * 3, hd + 540 * 1280 * 3, 3) if abs(a[k] - c[k]) > 40)
        n2 = sum(1 for k in range(hd + 90 * 1280 * 3, hd + 540 * 1280 * 3, 3) if abs(a[k] - e[k]) > 40)
        check(n1 > 200, f'{name}: the stroke shows ({n1} pixels)')
        check(n2 < n1 / 4, f'{name}: undone, it goes ({n2} pixels)')
    print('-- vertex paint: Rendered follows --')
    Vs = ['--op', 'mode.vertex_paint', '--op', 'paint.color 0 0 255']
    port(*Pre, '--op', 'view.shading_rendered', *Vs, '--move', '100,700', '--live-wait')
    a = open(f'{T}/u.ppm', 'rb').read()
    port(*Pre, '--op', 'view.shading_rendered', *Vs, *S, '--live-wait')
    c = open(f'{T}/u.ppm', 'rb').read()
    hd = len(a) - 1280 * 800 * 3
    n1 = sum(1 for k in range(hd + 90 * 1280 * 3, hd + 540 * 1280 * 3, 3) if abs(a[k] - c[k]) > 30)
    check(n1 > 100, f'a stroke in Rendered shows ({n1} pixels)')
    print('-- the UV Editor shows it --')
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'area.type_uv_editor', '--move', '600,300')
    a = open(f'{T}/u.ppm', 'rb').read()
    port('--op', f'file.open {base}', '--select', 'S', '--op', 'area.type_uv_editor', '--op', 'paint S 0 2 3.5 2 255 0 0', '--move', '600,300')
    c = open(f'{T}/u.ppm', 'rb').read()
    check(sum(1 for k in range(0, len(a)) if a[k] != c[k]) > 100, 'a stroke elsewhere')


def s_gpu():
    print('-- the viewport on the GPU --')
    bases()
    v = f'{T}/vcg.bee'
    bee(f'op("file.open", "{T}/ball.bee")\nvpaint("S", 0, 2, 3.5, 3, 200, 30, 10)\nop("file.save", "{v}")\n')
    a = ['--op', f'file.open {v}', '--op', 'render.device']
    env = dict(ENV, BEEMODEL_GPU_VIEW='on')
    subprocess.run([BIN, '--shot', f'{T}/g1.ppm', '--dump-log', f'{T}/log.txt', *a], capture_output=True, text=True, timeout=300, env=env)
    u = [x for x in logged() if 'viewport:' in x]
    if not u or ' 0 frames' in u[-1]:
        print('    no GPU here: skipped')
        return
    env = dict(ENV, BEEMODEL_GPU_VIEW='off')
    subprocess.run([BIN, '--shot', f'{T}/g2.ppm', *a], capture_output=True, text=True, timeout=300, env=env)
    for sh in ('', 'view.shading_material'):
        pre = ['--op', sh] if sh else []
        for tag, g in (('g3', 'on'), ('g4', 'off')):
            subprocess.run([BIN, '--shot', f'{T}/{tag}.ppm', *a, *pre], capture_output=True, text=True, timeout=300, env=dict(ENV, BEEMODEL_GPU_VIEW=g))
        p, c = open(f'{T}/g3.ppm', 'rb').read(), open(f'{T}/g4.ppm', 'rb').read()
        hd = len(p) - 1280 * 800 * 3
        n = sum(1 for y in range(90, 540) for x in range(215, 1010) if max(abs(p[hd + (y * 1280 + x) * 3 + k] - c[hd + (y * 1280 + x) * 3 + k]) for k in range(3)) > 24)
        check(n < 400, f'{sh or "Solid"}: the colours on the GPU as on the CPU ({u[-1].strip()[:40]}): {n} pixels off')
    print('-- a render on the GPU --')
    for tag, g in (('r1', None), ('r2', 'off')):
        e = dict(ENV, BEEMODEL_GPU_WAIT='15000')
        if g:
            e['BEEMODEL_GPU'] = g
        subprocess.run([BIN, '--shot', f'{T}/x.ppm', '--dump-log', f'{T}/log.txt', '--op', f'file.open {v}', '--op', 'render.settings 240 180 64', '--move', '615,360', '--key', 'f12', '--render-wait', '--op', f'render.save {T}/{tag}.png', '--op', 'render.status', '--op', 'render.device'], capture_output=True, text=True, timeout=300, env=e)
        if g is None:
            where_ = [x for x in logged() if 'rendering ' in x]
    print('   ', where_[-1:] if where_ else 'no log')
    a_, c_ = Image.open(f'{T}/r1.png').convert('RGB'), Image.open(f'{T}/r2.png').convert('RGB')
    ax, cx = a_.tobytes(), c_.tobytes()
    m_ = sum(abs(x - y) for x, y in zip(ax, cx)) / len(ax)
    check(ax != cx and sum(ax) / len(ax) > 5 and m_ < 8, f'the render on the GPU as on the CPU: mean {m_:.2f} levels, not the same file')


def s_uv():
    print('-- a stroke in the UV Editor --')
    bases()
    base = f'{T}/ball.bee'
    S1, S2 = do(500, 300, 760, 420), do(500, 420, 760, 300)
    for name, f, ref in (('a stroke', S1, None), ('bigger', seq(key(27), key(27), key(27), S1), None), ('undone', seq(S1, S2, CZ), S1)):
        one_session(f'UV: {name}', base, f, pre=('area.type_uv_editor',), ref=ref)
    q = f'{T}/pu.bee'
    session(BIN, base, do(100, 150, 300, 200), q, pre=('area.type_uv_editor',))
    check(os.path.exists(q) and images(q)[0][2] == images(base)[0][2], 'UV: off the image: nothing painted')
    print('-- in a layer --')
    f = seq(chord(SHIFT, 49), S1)
    one_session('UV: a layer', base, f, pre=('area.type_uv_editor',))
    print('-- not in vertex paint: the click is the editor\'s --')
    r = port('--op', f'file.open {base}', '--select', 'S', '--op', 'area.type_uv_editor', '--op', 'mode.vertex_paint', '--press', '500,300', '--move', '520,310', '--release', '520,310', '--op', 'paint.info', ok=False)
    check(r.returncode == 0 and info()['stroking'] == '0' and info()['hist'] == '0/0', 'no stroke')


def s_bake():
    print('-- bakes into paint layers --')
    a = f'{T}/bk.bee'
    bee(f'delete("Cube")\nadd("sphere", "Low", 0, 2, 0)\nselect("Low")\nop("uv.smart_project")\nop("image.new", "tex 64 64")\nadd("sphere", "Hi", 0, 2, 0)\nscale("Hi", 1.03, 0.98, 1.05)\nop("file.save", "{a}")\n')
    for kind in ('ao', 'normal', 'curvature'):
        o, q = script(a, f'layer("tex", "add")\nlayer("tex", "add")\nlayer("tex", "active", 1)\nprint("T", bake("Low", "Hi", "{kind}", "tex"))\nlayer("tex", "opacity", 1, 0.5)\n', ['layer tex add', 'layer tex add', 'layer tex active 1', f'object.bake Low Hi {kind} tex', 'layer tex opacity 1 0.5'], 'b')
        la, lc = layers(o), layers(q)
        check(la == lc, f'{kind}: the stack the same ({len(lc[0][1])} layers)')
        check(any(x != 0 for x in lc[0][1][1][3]), f'{kind}: it went into the active layer')
        check(not any(lc[0][1][2][3]), f'{kind}: and only there')
        same_px(f'{kind}: the composite', images(o)[0][2], images(q)[0][2], None)
    print('-- one paint step, in the layer --')
    port('--op', f'file.open {a}', *ops('layer tex add', 'image.save tex ' + f'{T}/b0.png', 'object.bake Low Hi ao tex', 'image.save tex ' + f'{T}/b1.png', 'paint.info', 'paint.undo', 'image.save tex ' + f'{T}/b2.png', 'paint.redo', 'image.save tex ' + f'{T}/b3.png'))
    check(rd('b1') != rd('b0') and rd('b2') == rd('b0') and rd('b3') == rd('b1'), 'undone and redone, the composite follows')
    check(info()['hist'] == '1/1', f'one step ({info()["hist"]})')


def s_ui():
    print('-- the tools, the bar, the keys --')
    bases()
    base = f'{T}/ball.bee'
    fr = ['--op', f'file.open {base}', '--select', 'S']

    def rows():
        return [ln.rstrip('\n').split('\t') for ln in open(f'{T}/u.txt')]
    port(*fr, '--op', 'mode.texture_paint')
    r = rows()
    labels = [x[1] for x in r]
    want = ['Brush Colour', 'Bigger Brush', 'Smaller Brush', 'Stronger', 'Weaker', 'New Paint Layer', 'Layer Above', 'Layer Below', 'Merge Layers']
    i = labels.index('Brush Colour')
    check(labels[i:i + len(want)] == want, f'the tools area ({labels[i:i + 3]}...)')
    check('Texture Paint' in labels, 'the header says Texture Paint')
    for w in ('Radius', 'Strength', 'The paint colour'):
        check(w in labels, f'the bar has {w}')
    check(labels.count('Paint with this colour') == 6, 'six swatches')
    port(*fr, '--op', 'mode.vertex_paint')
    r = rows()
    off = {x[1]: x[3] for x in r}
    check('Vertex Paint' in off and off.get('New Paint Layer') == 'off' and off.get('Bigger Brush') == 'on', 'vertex paint: its name, layers greyed (texture paint\'s)')
    port(*fr, '--op', 'mode.weight_paint')
    labels = [x[1] for x in rows()]
    check('Weight Paint' in labels and 'Weight' in labels and 'No bone' in labels, 'weight paint: the weight, the bone (none: no armature)')
    port('--op', f'file.open {rig()}', '--select', 'S', '--op', 'mode.weight_paint')
    labels = [x[1] for x in rows()]
    check('Side' in labels, f'its armature\'s active bone')
    port('--move', '640,300')
    check('Radius' not in [x[1] for x in rows()], 'object mode: no bar')
    print('-- radius and strength: stops and steps --')
    many = []
    for _ in range(40):
        many += ['--op', 'paint.radius_up', '--op', 'paint.strength_up']
    port(*many, '--op', 'paint.info')
    check(info()['radius'] == '500' and info()['strength'] == '1', f'500 and 1 ({info()["radius"]}, {info()["strength"]})')
    many = []
    for _ in range(40):
        many += ['--op', 'paint.radius_down', '--op', 'paint.strength_down']
    port(*many, '--op', 'paint.info')
    check(info()['radius'] == '2' and abs(float(info()['strength']) - 0.1) < 1e-6, f'2 and 0.1 ({info()["radius"]}, {info()["strength"]})')
    port(*fr, '--op', 'mode.texture_paint', '--move', '640,300', '--key', '27', '--key', 'shift+26', '--op', 'paint.info')
    check(float(info()['radius']) == 34.5 and abs(float(info()['strength']) - 0.7) < 1e-6, f'[ ] Shift+[ ] in the mode ({info()["radius"]})')
    port(*fr, '--move', '640,300', '--key', 'ctrl+z', '--key', '27', '--op', 'paint.info')
    check(info()['radius'] == '30', 'not outside the mode')
    print('-- colour --')
    port('--op', 'paint.color 1 2 3', '--op', 'paint.info')
    check(info()['col'] == 'ff010203', f'paint.color ({info()["col"]})')
    port('--op', 'paint.color 300 2', '--op', 'paint.info')
    check(info()['col'] == 'ffd04020' and any('paint.color' in x and 'r' in x for x in logged()), 'a bad one says how')
    port('--op', 'paint.weight 1.5', '--op', 'paint.info')
    check(info()['weight'] == '1', 'paint.weight stops at 1')
    port(*fr, '--op', 'mode.texture_paint', '--click-label', 'Paint with this colour', '--op', 'paint.info')
    check(info()['col'] == 'ffffffff', f'a swatch paints with its colour ({info()["col"]})')
    print('-- the modes --')
    port(*fr, '--key', 'shift+tab', '--op', 'paint.info', '--key', 'shift+tab', '--op', 'paint.info')
    ln = [x for x in logged() if x.startswith('  paint.info')]
    check(' on 1 ' in ln[0] and ' on 0 ' in ln[1], 'Shift+Tab toggles')
    check(any('texture paint: S' in x for x in logged()) and any('texture paint off' in x for x in logged()), 'and says so')
    port(*fr, '--key', 'shift+v', '--op', 'paint.info')
    check(' kind 1 ' in logged()[-1] and ' on 1 ' in logged()[-1], 'Shift+V: vertex paint')
    port(*fr, '--key', 'ctrl+w', '--op', 'paint.info')
    check(' kind 2 ' in logged()[-1] and ' on 1 ' in logged()[-1], 'Ctrl+W: weight paint')
    port('--select', 'Cube', '--op', 'mode.texture_paint', '--op', 'paint.info')
    check(' on 0 ' in logged()[-1] and any('a mesh with UVs and an image' in x for x in logged()), 'no image: it says what it needs')
    port('--select', 'Camera', '--op', 'mode.vertex_paint', '--op', 'paint.info')
    check(' on 0 ' in logged()[-1], 'a camera cannot be painted')
    for a_, b_ in (('mode.edit', 'mode.texture_paint'), ('mode.sculpt', 'mode.vertex_paint'), ('mode.texture_paint', 'mode.sculpt'), ('mode.vertex_paint', 'mode.edit'), ('mode.vertex_paint', 'mode.texture_paint'), ('mode.texture_paint', 'mode.weight_paint')):
        port(*fr, '--op', a_, '--op', b_, '--op', 'paint.info', '--op', 'sculpt.info')
        ln = logged()
        pi = [x for x in ln if x.startswith('  paint.info')][-1]
        si = [x for x in ln if 'sculpt.info' in x][-1]
        on = ' on 1 ' in pi
        check(on == ('paint' in b_) and (si.endswith('off') or 'sculpt' in b_), f'{a_} -> {b_}: one mode at a time')
    port(*fr, '--move', '640,300', '--op', 'mode.texture_paint', '--key', 'tab', '--op', 'paint.info')
    check(' on 0 ' in logged()[-1], 'Tab leaves for edit mode')
    print('-- the panel: layers --')
    tab = ['--click-label', 'Material']
    port(*fr, *tab, '--op', 'mode.texture_paint', '--move', '1200,300')
    labels = [x[1] for x in rows()]
    check('Paint Layers' in labels and 'Add' in labels and 'Merge' in labels and 'Remove' in labels, 'the Material tab: Paint Layers')
    port(*fr, *tab, '--op', 'mode.texture_paint', '--click-label', 'button:Add', '--click-label', 'button:Add', '--move', '1200,300', '--op', 'layer tex count', '--op', 'layer tex active')
    labels = [x[1] for x in rows()]
    res = [ln.split(': ')[-1] for ln in logged() if ln.startswith('  layer tex')]
    check(res == ['3', '2'] and 'Layer 2' in labels and 'Base' in labels, f'Add, Add ({res})')
    port(*fr, *tab, '--op', 'mode.texture_paint', '--click-label', 'button:Add', '--click-label', 'button:Add', '--click-label', 'row:Layer 1', '--op', 'layer tex active', '--click-label', 'button:Remove', '--op', 'layer tex count', '--click-label', 'button:Merge', '--op', 'layer tex count')
    res = [ln.split(': ')[-1] for ln in logged() if ln.startswith('  layer tex')]
    check(res == ['1', '2', '1'], f'a row paints on it; Remove; Merge ({res})')
    port('--op', f'file.open {base}', '--select', 'S', *tab, '--move', '1200,300')
    check('Paint Layers' not in [x[1] for x in rows()], 'out of the mode: no panel')
    print('-- the Character template --')
    port('--op', 'help.template character', '--select', 'Body', '--op', 'mode.weight_paint', '--move', '640,300', '--op', 'paint.info')
    check(' on 1 ' in logged()[-1] and ' bone -1 ' not in logged()[-1], 'its body paints the Rig\'s bone')


def s_idle():
    print('-- idle --')
    bases()
    _, f = fake(BIN, f'{T}/ball.bee', one=False)
    combo(f, SHIFT, TAB)
    f.move(640, 330)
    f.drag(620, 330, 660, 350, steps=4)
    f.pump(1.5)
    n = f.frames
    f.pump(1.5)
    check(f.frames == n, f'nothing moves, nothing is drawn ({f.frames - n} frames)')
    f.move(650, 340)
    f.pump(0.3)
    check(f.frames > n, 'the pointer moves: the brush follows')
    f.configure(900, 500)
    f.pump(0.5)
    f.drag(400, 200, 460, 240, steps=4)
    f.pump(0.3)
    check(f.proc.poll() is None, 'resized in the mode, still painting')
    f.proc.kill()
    f.proc.wait()


def s_robust():
    print('-- the small and the strange --')
    bases()
    base = f'{T}/ball.bee'
    b0 = images(base)[0][2]
    print('-- huge, tiny --')
    o, q = script(base, 'paint("S", 0, 2, 3.5, 1000, 200, 30, 10)\n', ['paint S 0 2 3.5 1000 200 30 10'], 'r')
    same_px('a huge brush', images(o)[0][2], images(q)[0][2], b0)
    o, q = script(base, 'paint("S", 0, 2, 3.5, 0.001, 200, 30, 10)\n', ['paint S 0 2 3.5 0.001 200 30 10'], 'r')
    same_px('a tiny one', images(o)[0][2], images(q)[0][2], None)
    fr = ['--op', f'file.open {base}', '--select', 'S', '--move', '640,300']
    for bad in ('nan 2 3 1', '0 2 3 inf', '0 2 3 1/0', '0 2', ''):
        r = port('--op', f'file.open {base}', '--op', f'paint S {bad}', '--op', f'vpaint S {bad}', '--op', f'file.save {T}/n.bee', ok=False)
        check(r.returncode == 0 and images(f'{T}/n.bee') in ({}, images(base)) and vcols(f'{T}/n.bee', 'S') is None, f'refused: {bad!r}')
    r = port('--op', 'paint Nobody 0 0 0 1', '--op', 'vpaint Camera 0 0 0 1', '--op', 'wpaint Light 0 0 0 1 0 1', '--op', 'layer nosuch add', '--op', 'layer tex nosuch', ok=False)
    check(r.returncode == 0 and any('no object' in x for x in logged()), 'on nothing: it says so')
    print('-- big radii by hand --')
    keys_ = []
    for _ in range(40):
        keys_ += ['--key', '27']
    for md in ('mode.texture_paint', 'mode.vertex_paint', 'mode.weight_paint'):
        r = port(*fr, '--op', md, *keys_, '--press', '640,300', '--move', '700,320', '--release', '700,320', '--op', 'edit.undo', ok=False)
        check(r.returncode == 0, f'{md}: radius 500')
    print('-- zero-area triangles, all UVs in one point --')
    img = f'{T}/flat.bee'
    bee(f'op("file.open", "{base}")\nop("file.save", "{img}")\n')
    head = open(img, 'rb').read()[:8]
    cs = beefile.chunks(img)
    out = []
    for t_, b in cs:
        if t_ == b'MUVS':
            k = 12 + 0
            b = bytearray(b)
            ix, flags, n = struct.unpack_from('<III', b, 0)
            for i in range(n * 2):
                struct.pack_into('<f', b, 12 + i * 4, 0.5)
            b = bytes(b)
        out.append((t_, b))
    open(img, 'wb').write(head + b''.join(t_ + struct.pack('<I', len(b)) + b for t_, b in out))
    r = port('--op', f'file.open {img}', '--op', 'paint S 0 2 3.5 2 200 30 10', '--op', 'mode.texture_paint', '--press', '640,300', '--move', '660,310', '--release', '660,310', '--op', f'file.save {T}/fl.bee', ok=False)
    check(r.returncode == 0, f'nothing to paint on: no crash {r.stderr[-200:]}')
    check(images(f'{T}/fl.bee')[0][2] == b0, 'and nothing painted')
    print('-- 16-bit and float images --')
    import zlib
    def png16(path):
        def ch(t_, d):
            return struct.pack('>I', len(d)) + t_ + d + struct.pack('>I', zlib.crc32(t_ + d))
        raw = b''.join(b'\0' + bytes([40, 0, 80, 0, 120, 0]) * 8 for _ in range(8))
        open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', 8, 8, 16, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))
    p16 = f'{T}/six.png'
    png16(p16)
    B16 = BALL.format(s=3.5, w=8, out=f'{T}/b16.bee').replace('op("image.new", "tex 8 8")', f'op("image.load", "{p16}")').replace('"image", "tex"', '"image", "six"')
    bee(B16)
    a = bee(f'op("file.open", "{T}/b16.bee")\nselect("S")\nprint("r", paint("S", 0, 2, 3.5, 2, 200, 30, 10))\n')
    port('--op', f'file.open {T}/b16.bee', '--op', 'paint S 0 2 3.5 2 200 30 10')
    painted = not any('no image to paint' in x for x in logged())
    check(('r 1' in a) == painted, f'a 16-bit PNG: the console as a script ({"painted" if painted else "refused"}: {a.strip()[:20]})')
    hdr = os.path.join(ROOT, 'tests/files/gpu_world.hdr')
    if os.path.exists(hdr):
        BH = BALL.format(s=3.5, w=8, out=f'{T}/bh.bee').replace('op("image.new", "tex 8 8")', f'op("image.load", "{hdr}")').replace('"image", "tex"', '"image", "gpu_world"')
        bee(BH)
        a = bee(f'op("file.open", "{T}/bh.bee")\nselect("S")\nprint("r", paint("S", 0, 2, 3.5, 2, 200, 30, 10))\n')
        port('--op', f'file.open {T}/bh.bee', '--op', 'paint S 0 2 3.5 2 200 30 10', '--op', 'mode.texture_paint', '--op', 'paint.info')
        check('r 0' in a and any('no image to paint' in x for x in logged()) and ' on 0 ' in logged()[-1], 'a float image: refused')
    print('-- a job running, other windows --')
    S = ['--press', '620,330', '--move', '630,335', '--move', '660,350', '--release', '660,350']
    for md in ('mode.texture_paint', 'mode.vertex_paint'):
        r = port(*fr, '--op', md, '--key', 'f12', *S, '--render-wait', '--op', 'mode.object', ok=False)
        check(r.returncode == 0, f'{md}: a render running {r.stderr[-200:]}')
        r = port(*fr, '--op', md, '--op', 'view.shading_rendered', *S, '--live-wait', ok=False)
        check(r.returncode == 0, f'{md}: the Rendered viewport {r.stderr[-200:]}')
    r = port(*fr, '--op', 'mode.texture_paint', '--op', 'area.split_side', '--move', '300,300', *S, '--op', 'paint.info', ok=False)
    check(r.returncode == 0, 'two viewports')
    a = port('--comp-scale', '180', '--op', f'file.open {base}', '--select', 'S', '--move', '640,300', '--op', 'mode.texture_paint', '--press', '620,300', '--move', '640,300', '--release', '640,300', '--op', f'file.save {T}/sc.bee', ok=False)
    check(a.returncode == 0 and images(f'{T}/sc.bee')[0][2] != b0, 'a window at 150%')
    print('-- layers: painted to the limit --')
    args = ['--op', f'file.open {base}']
    for k in range(16):
        args += ['--op', 'layer tex add', '--op', f'paint S 0 2 3.5 1.5 {k * 15} 100 30']
    r = port(*args, '--op', 'mode.texture_paint', *S, '--op', 'layer tex merge', *S, '--op', 'paint.undo', '--op', 'mode.object', ok=False)
    check(r.returncode == 0, '16 layers, painted, merged')
    print('-- damaged chunks: colours, layers, weights --')
    src = f'{T}/all2.bee'
    bee(f'op("file.open", "{rig()}")\nvpaint("S", 0, 2, 3.5, 2, 200, 30, 10)\nop("uv.smart_project")\nop("image.new", "tex 16 16")\nmaterial("Mat")\nc = node("Mat", "image", "tex", 1)\nsocket("Mat", "base", c)\nassign("S", "Mat")\npaint("S", 0, 2, 3.5, 2, 200, 30, 10)\nlayer("tex", "add")\npaint("S", 1, 3, 3, 1.2, 10, 220, 30)\nop("file.save", "{src}")\n')
    head = open(src, 'rb').read()[:8]
    cs = beefile.chunks(src)
    rng = random.Random(SEED)
    # ones that matter, each on purpose
    mv = dict(cs_ := [(t_, b) for t_, b in cs])[b'MVCL']
    il = dict(cs)[b'ILAY']
    ix, nv = struct.unpack_from('<II', mv, 0)
    small = io.BytesIO()
    Image.new('RGBA', (3, 5), (9, 9, 9, 9)).save(small, 'PNG')
    sp = small.getvalue()
    made = {
        'MVCL: more colours than vertices': (b'MVCL', struct.pack('<II', ix, nv + 7) + b'\xff' * ((nv + 7) * 4)),
        'MVCL: fewer': (b'MVCL', struct.pack('<II', ix, 3) + b'\xff' * 12),
        'MVCL: a mesh that is not there': (b'MVCL', struct.pack('<II', 9999, 3) + b'\xff' * 12),
        'MVCL: a count past the end': (b'MVCL', struct.pack('<II', ix, nv) + b'\xff' * 8),
        'MVCL: a huge count': (b'MVCL', struct.pack('<II', ix, 0xffffffff)),
        'ILAY: a layer of another size': (b'ILAY', struct.pack('<III', 0, 2, 1) + b''.join(struct.pack('<fIII', 1, 0, 1, len(sp)) + sp for _ in range(2))),
        'ILAY: a thousand layers': (b'ILAY', struct.pack('<III', 0, 1000, 1) + b''.join(struct.pack('<fIII', 1, 0, 1, len(sp)) + sp for _ in range(40))),
        'ILAY: an image that is not there': (b'ILAY', struct.pack('<III', 77, 2, 1)),
        'ILAY: bytes past the end': (b'ILAY', struct.pack('<III', 0, 2, 1) + struct.pack('<fIII', 1, 0, 1, 1 << 30)),
        'ILAY: none': (b'ILAY', struct.pack('<III', 0, 0, 0)),
        'ILAY: NaN opacity, a blend of 99, active 50': (b'ILAY', struct.pack('<III', 0, 2, 50) + b''.join(struct.pack('<IIII', 0x7fc00000, 99, 7, len(sp)) + sp for _ in range(2))),
    }
    for nm_, (tg, body) in made.items():
        open(f'{T}/fz.bee', 'wb').write(head + b''.join(t_ + struct.pack('<I', len(body if t_ == tg else b)) + (body if t_ == tg else b) for t_, b in cs))
        r = port('--op', f'file.open {T}/fz.bee', '--select', 'S', '--op', 'mode.texture_paint', '--press', '620,330', '--move', '630,335', '--release', '630,335', '--op', 'mode.vertex_paint', '--press', '620,330', '--release', '620,330', '--op', 'mode.object', '--op', 'view.shading_material', '--op', f'file.save {T}/fz2.bee', ok=False)
        check(r.returncode == 0, f'{nm_}: {r.stderr[-300:] if r.returncode else "opened, painted, saved"}')
    for k in range(RUNS):
        out = []
        for t_, b in cs:
            if t_ in (b'MVCL', b'ILAY', b'MWGT', b'IMGD') and rng.random() < 0.6:
                b = bytearray(b)
                how = rng.random()
                if how < 0.3:
                    b = b[:rng.randrange(0, len(b) + 1)]
                elif b:
                    for _ in range(rng.randrange(1, 12)):
                        p_ = rng.randrange(0, min(len(b), 64) if how < 0.7 else len(b))
                        b[p_] = rng.choice((0, 255, rng.randrange(256)))
                b = bytes(b)
            out.append((t_, b))
        open(f'{T}/fz.bee', 'wb').write(head + b''.join(t_ + struct.pack('<I', len(b)) + b for t_, b in out))
        r = port('--op', f'file.open {T}/fz.bee', '--select', 'S', '--op', 'mode.texture_paint', '--press', '620,330', '--move', '630,335', '--release', '630,335', '--op', 'mode.vertex_paint', '--press', '620,330', '--release', '620,330', '--op', 'mode.weight_paint', '--press', '620,330', '--release', '620,330', '--op', 'mode.object', '--op', 'view.shading_material', '--op', 'edit.undo', '--op', 'paint.undo', '--op', f'file.save {T}/fz2.bee', ok=False)
        if r.returncode != 0:
            shutil.copy(f'{T}/fz.bee', '/tmp/beept-crash.bee')
            check(False, f'a damaged file: {r.stderr[-400:]}')
            break
    else:
        check(True, f'{RUNS} damaged files painted')


def s_fuzz():
    print('-- random sessions, undone and redone --')
    bases()
    base = f'{T}/ball.bee'
    rng = random.Random(SEED)
    b0 = images(base)[0][2]
    for run in range(max(1, RUNS // 4)):
        args = ['--op', f'file.open {base}', '--select', 'S', '--move', '640,300']
        for _ in range(rng.randrange(3, 14)):
            k = rng.random()
            x, y = rng.randrange(300, 900), rng.randrange(200, 600)
            if k < 0.25:
                args += ['--op', f'vpaint S {rng.uniform(-3, 3):.3f} {rng.uniform(-1, 5):.3f} 3 {rng.uniform(0.1, 3):.3f} {rng.randrange(256)} 40 90']
            elif k < 0.5:
                args += ['--press', f'{x},{y}', '--move', f'{x + 20},{y + 9}', '--move', f'{x + 40},{y - 3}', '--release', f'{x + 40},{y - 3}']
            elif k < 0.7:
                args += ['--op', rng.choice(['mode.object', 'mode.texture_paint', 'mode.vertex_paint', 'mode.weight_paint', 'mode.edit', 'mode.sculpt', 'object.texture_paint', 'object.vertex_paint'])]
            elif k < 0.85:
                args += ['--op', rng.choice(['layer tex add', 'layer tex merge', 'layer tex remove 1', 'layer tex opacity 1 0.5', 'layer tex visible 1 0', 'layer tex blend 1 2', 'paint.layer_add', 'paint.layer_up', 'paint.layer_down', 'paint.layer_merge'])]
            elif k < 0.93:
                args += ['--op', rng.choice(['edit.undo', 'edit.redo', 'paint.undo', 'paint.redo'])]
            else:
                args += ['--op', 'paint S 0 2 3.5 1 200 30 10']
        args += ['--op', 'mode.object']
        for _ in range(40):
            args += ['--op', 'edit.undo', '--op', 'paint.undo']
        args += ['--op', f'file.save {T}/f0.bee']
        r = port(*args, ok=False)
        if r.returncode != 0:
            check(False, f'run {run}: {r.stderr[-400:]} {args[:30]}')
            return
        if vcols(f'{T}/f0.bee', 'S') is not None:
            check(False, f'run {run}: undone to the start, colours remain: {args}')
            return
    check(True, f'{max(1, RUNS // 4)} sessions, no vertex colours left at the start')


def cpu_of(pid):
    w = open(f'/proc/{pid}/stat').read().rsplit(')', 1)[1].split()
    return (int(w[11]) + int(w[12])) * 10.0  # ms


def perf_scene(p, lv, w):
    tex = f'op("uv.smart_project")\nop("image.new", "tex {w} {w}")\nmaterial("Mat")\nc = node("Mat", "image", "tex", 1)\nsocket("Mat", "base", c)\nassign("S", "Mat")\n' if w else ''
    bee(f'delete("Cube")\nadd("sphere", "S", 0, 2, 0)\nmodifier("S", "subsurf")\nmodset("S", 0, "levels", {lv})\nmodapply("S", 0)\nscale("S", 3.5, 3.5, 3.5)\nselect("S")\n{tex}op("file.save", "{p}")\n', one=False)


def s_perf():
    """Numbers, for the record: run with a release build, on every core. A dab from
    its own clock; the CPU the process spent over a stroke, less the same pointer with
    no stroke. Frames over the wall clock."""
    print('-- the costs --')
    path = [(440 + 12 * i, 250 + 2 * i) for i in range(35)]
    a4k, dense, huge = f'{T}/p4k.bee', f'{T}/pdense.bee', f'{T}/phuge.bee'
    perf_scene(a4k, 3, 4096)
    perf_scene(dense, 5, 1024)
    perf_scene(huge, 6, 0)
    # weights on the huge mesh: its vertices in the rig's file, no weights yet
    rg = rig()
    k = mesh_order(rg)['S']
    hm = chunk(huge, b'MESH') if False else [b for t_, b in beefile.chunks(huge) if t_ == b'MESH'][mesh_order(huge)['S']]
    hw = f'{T}/phw.bee'
    out, n = [], 0
    for t_, b in beefile.chunks(rg):
        if t_ == b'MESH':
            if n == k:
                b = hm
            n += 1
        if t_ not in (b'MWGT', b'MUVS'):
            out.append((t_, b))
    open(hw, 'wb').write(open(rg, 'rb').read()[:8] + b''.join(t_ + struct.pack('<I', len(b)) + b for t_, b in out))
    for name, p, en, large in (('32k vertices, 4K image, texture', a4k, TEX, False), ('same, radius 69', a4k, TEX, True), ('507k vertices, 1K image, texture', dense, TEX, False), ('same, vertex', dense, VP, False), ('2M vertices, vertex', huge, VP, False), ('2M vertices, weight', hw, WP, False)):
        vs = len(beefile.meshes(p)[mesh_order(p)['S']][0])
        row = []
        for b in (BIN,):
            _, f = fake(b, p, one=False)
            f.move(640, 300)
            f.pump(0.3)
            front(f)
            combo(f, *en)
            f.pump(1.0)
            if large:
                for _ in range(6):
                    f.key(27)
                    f.pump(0.05)
            for x, y in path:
                f.move(x, y)
            f.pump(0.5)
            c0 = cpu_of(f.proc.pid)
            for x, y in path:
                f.move(x, y)
            f.pump(0.3)
            hover_cpu = cpu_of(f.proc.pid) - c0
            f.move(*path[0])
            f.pump(0.3)
            n0 = f.frames
            c0 = cpu_of(f.proc.pid)
            t0 = time.time()
            f.button(True)
            for x, y in path:
                f.move(x, y)
            f.button(False)
            f.pump(0.5)
            wall = time.time() - t0 - 0.5
            row.append((cpu_of(f.proc.pid) - c0 - hover_cpu, wall, f.frames - n0))
            f.proc.kill()
            f.proc.wait()
        # its clock, headless
        ks = [x for _ in range(6 if large else 0) for x in ('--key', '27')]
        m = {TEX: 'mode.texture_paint', VP: 'mode.vertex_paint', WP: 'mode.weight_paint'}[en]
        mv = [x for q in path for x in ('--move', f'{q[0]},{q[1]}')]
        port('--op', f'file.open {p}', '--select', 'S', '--move', '640,300', '--op', 'view.camera_front' if False else 'paint.info', '--op', m, *ks, '--press', f'{path[0][0]},{path[0][1]}', *mv, '--release', f'{path[-1][0]},{path[-1][1]}', '--op', 'paint.info', one=False)
        i = info()
        d, us = int(i['dabs']), int(i['us'])
        print(f'  {name} ({vs} v): {us / 1000 / max(d, 1):.3f} ms a dab over {d} dabs (wall), {row[0][0]:.0f} ms CPU, {row[0][2]} frames in {row[0][1]:.2f} s; steps {i["bytes"]} bytes')


SCEN = ['s_dabs', 's_vcol', 's_weights', 's_layers', 's_files', 's_window', 's_depth', 's_layers_window', 's_vpaint_window', 's_wpaint_window', 's_undo_window', 's_undo', 's_look', 's_uv', 's_bake', 's_ui', 's_idle', 's_robust', 's_fuzz', 's_gpu']

if __name__ == '__main__':
    print(f'seed {SEED}')
    for n in (WANT or SCEN):
        globals()[n]()
    shutil.rmtree(T, ignore_errors=True)
    print(f'fails {len(FAILS)}')
    for f in FAILS:
        print('  FAILED:', f)
    sys.exit(1 if FAILS else 0)
