#!/usr/bin/env python3
"""Sketches: the solver on random sketches (points, lines, circles, arcs,
every constraint type, expressions, conflicts, damaged references), the SKCH
chunk and the display mesh read back and saved again, DXF and SVG
exports, damaged files, sketch mode driven through the window by the fake
compositor (tools, picks, constraints, dimensions, drags, deletes, undo,
duplicates) with the file checked after every step, the look, and the modes
and undo interplay.

    python3 tests/sketch.py BIN [runs=150] [seed]

BEE_CPU (default 10) pins the window runs; SK_ONLY=s_solver,... runs some.
"""
import math, os, random, struct, subprocess, sys, tempfile, time, zlib
import xml.etree.ElementTree as ET
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 150
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '10')
FAILS = []
T = tempfile.mkdtemp(prefix='beesk-', dir='/tmp')
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)
SK_SZ = 38976
PTS, ENTS, CONS = 64, 64 + 256 * 24, 64 + 256 * 24 + 256 * 32


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def bee_eval(code, timeout=900):
    try:
        r = subprocess.run([BIN, '--eval', code], capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return None, 'timeout'


def port(*a, timeout=900, binary=None):
    try:
        r = subprocess.run([binary or BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *a], capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.returncode
    except subprocess.TimeoutExpired:
        return None


def plog():
    return open(f'{T}/log.txt').read() if os.path.exists(f'{T}/log.txt') else ''


def skch(path):
    try:
        return beefile.chunk(path, b'SKCH')
    except Exception:
        return None


def reads(path):
    """The file reads back as a .bee file."""
    try:
        beefile.chunks(path)
        beefile.objects(path)
        return True
    except Exception:
        return False


def build(chs):
    o = b'BEEM' + struct.pack('<I', 1)
    for t, c in chs:
        o += t + struct.pack('<I', len(c)) + c
    return o


def sketch_obj(path):
    """The first sketch object's OBJS record (without its mesh index) and MESH chunk."""
    objs = beefile.objects(path)
    ms = [c for t, c in beefile.chunks(path) if t == b'MESH']
    for o in objs:
        if o['type'] == 3:
            return (o['name'], o['loc'], o['rot'], o['scl'], o['color'], o['flags']), ms[o['mesh']]
    return None


def finite_block(c):
    """The solved points and radii are finite numbers."""
    npt, ne = struct.unpack_from('<II', c, 8 + 12)
    if npt > 256 or ne > 256:
        return False
    for i in range(npt):
        if not all(math.isfinite(v) for v in struct.unpack_from('<dd', c, 8 + PTS + i * 24)):
            return False
    for i in range(ne):
        if not math.isfinite(struct.unpack_from('<d', c, 8 + ENTS + i * 32 + 16)[0]):
            return False
    return True


def shape(c):
    """What a sketch is made of: the counts, each entity's type, points and
    flags, each constraint's type, references and expression (not the solved
    numbers: a sketch is solved again when it is read)."""
    if not c or len(c) < 8 + CONS:
        return None
    npt, ne, nc = struct.unpack_from('<III', c, 8 + 12)
    if npt > 256 or ne > 256 or nc > 256:
        return None
    ents = [struct.unpack_from('<Iiii', c, 8 + ENTS + i * 32) + struct.unpack_from('<I', c, 8 + ENTS + i * 32 + 24) for i in range(ne)]
    cons = [struct.unpack_from('<Iiii', c, 8 + CONS + i * 96) + (c[8 + CONS + i * 96 + 36:8 + CONS + i * 96 + 96].split(b'\0')[0],) for i in range(nc)]
    return npt, ents, cons


def mesh_finite(path):
    so = sketch_obj(path)
    if so is None:
        return False
    nv = struct.unpack_from('<I', so[1])[0]
    return nv > 0 and all(math.isfinite(v) for v in struct.unpack_from(f'<{nv * 3}f', so[1], 12))


# --- random sketches -----------------------------------------------------------------------

def block(rng, bad=False, constr=False):
    b = bytearray(SK_SZ)
    struct.pack_into('<IIIIIIiId', b, 0, 1, 40960, rng.randrange(3), 0, 0, 0, -1, 0, rng.choice([0, 0, 0.5, -1.25]))
    for i in range(rng.randrange(0, 40)):   # stale bytes the files keep
        b[rng.randrange(64, SK_SZ)] = rng.randrange(256)
    npt = rng.randrange(2, 24)
    pts = []
    for i in range(npt):
        x, y = rng.uniform(-5, 5), rng.uniform(-5, 5)
        pts.append((x, y))
        struct.pack_into('<ddI', b, PTS + i * 24, x, y, 0)
    ents = []
    ne = rng.randrange(1, 10)
    for i in range(ne):
        t = rng.choice([1, 1, 1, 2, 3])
        p = [rng.randrange(npt), rng.randrange(npt) if t != 2 else -1, rng.randrange(npt) if t == 3 else -1]
        r = rng.uniform(0.2, 3)
        if t == 3:
            (cx, cy), (sx, sy) = pts[p[0]], pts[p[1]]
            r = ((sx - cx) ** 2 + (sy - cy) ** 2) ** 0.5 or 1.0
        ents.append((t, p))
        struct.pack_into('<IiiidI', b, ENTS + i * 32, t, p[0], p[1], p[2], r, 4 if constr and rng.random() < .3 else 0)
    lines = [i for i, e in enumerate(ents) if e[0] == 1]
    rounds = [i for i, e in enumerate(ents) if e[0] != 1]
    nc = rng.randrange(0, 14)
    for i in range(nc):
        t = rng.randrange(1, 20)
        a = b_ = c = -1
        v = v2 = 0.0
        P = lambda: rng.randrange(npt)
        L = lambda: rng.choice(lines) if lines else rng.randrange(ne)
        R = lambda: rng.choice(rounds) if rounds else rng.randrange(ne)
        if t in (1, 9, 10, 11): a, b_ = P(), P()
        elif t == 8: a = P(); v, v2 = rng.uniform(-5, 5), rng.uniform(-5, 5)
        elif t in (2, 3, 18): a = L()
        elif t in (4, 5, 13): a, b_ = L(), L()
        elif t == 6: a, b_ = (L(), L()) if rng.random() < .5 else (R(), R())
        elif t == 7: a, b_ = (L(), R()) if rng.random() < .6 else (R(), R()); v2 = rng.choice([1.0, -1.0])
        elif t in (12, 19): a = R()
        elif t in (14, 16): a, b_ = P(), L()
        elif t == 15: a, b_ = P(), R()
        elif t == 17: a, b_, c = P(), P(), L()
        if t in (9, 10, 11, 12, 18, 19): v = rng.uniform(0.1, 6)
        if t == 13: v = rng.uniform(-3, 3)
        if bad and rng.random() < 0.15: a = rng.randrange(-3, 300)
        if bad and rng.random() < 0.05: t = rng.randrange(0, 40)
        expr = b''
        if t in (9, 12, 18, 19) and rng.random() < 0.3:
            expr = rng.choice([b'1+0.25', b'2*1.5', b'3/4', b'0.1+0.2', b'25cm', b'sqrt(2)', b'1/0', b'nosuch+1'])
        struct.pack_into('<IiiiddI', b, CONS + i * 96, t, a, b_, c, v, v2, 0)
        o = CONS + i * 96 + 36
        b[o:o + len(expr) + 1] = expr + b'\0'
    struct.pack_into('<III', b, 12, npt, ne, nc)
    return bytes(b)


def base_file():
    """A scene with one sketch object (index 3), made by a script: the frame the blocks go in."""
    p = f'{T}/base.bee'
    if not os.path.exists(p):
        bee_eval(f's = sketch("S", "XY")\nr = rect(s, 0, 0, 4, 2)\nop("file.save_as", "{p}")')
    return beefile.chunks(p)


def inject(base, blk, path):
    open(path, 'wb').write(build([(t, (struct.pack('<II', 1, 3) + blk) if t == b'SKCH' else c) for t, c in base]))


def resave(names, one_by_one=False, tag='p'):
    """Each file opened and saved again: [(path, saved path, exit code or None)].
    one_by_one: a run for each (a damaged one may stop it)."""
    out = []
    if one_by_one:
        for p in names:
            out.append((p, f'{p}.{tag}.bee', port('--op', f'file.open {p}', '--op', f'file.save_as {p}.{tag}.bee', timeout=120)))
    else:
        args = []
        for p in names:
            args += ['--op', f'file.open {p}', '--op', f'file.save_as {p}.{tag}.bee']
        rc = port(*args)
        out = [(p, f'{p}.{tag}.bee', rc) for p in names]
    return out


def s_solver():
    print('-- the solver: random sketches solved, the SKCH chunk and the display mesh read back, saved again --')
    base = base_file()
    rng = random.Random(SEED)
    for kind in ('ok', 'bad'):
        names = []
        for k in range(RUNS):
            p = f'{T}/r_{kind}{k}.bee'
            inject(base, block(rng, bad=kind == 'bad'), p)
            names.append(p)
        ran = readback = moved = solved = finite = meshok = 0
        bad = []
        saved = resave(names, one_by_one=kind == 'bad')
        for src, b, rc in saved:
            cb = skch(b) if rc == 0 else None
            if cb is None or not reads(b):
                bad.append((os.path.basename(src), rc))
                continue
            ran += 1
            readback += sketch_obj(b) is not None
            meshok += mesh_finite(b)
            finite += finite_block(cb)
            if struct.unpack_from('<i', cb, 8 + 24)[0] >= 0:
                solved += 1
            if skch(src)[8 + 64:8 + 64 + 24 * 24] != cb[8 + 64:8 + 64 + 24 * 24]:
                moved += 1
        n = RUNS
        check(ran == n, f'{kind}: {ran} of {n} sketches opened, solved and saved (no crash, a SKCH chunk back){": " + str(bad[:6]) if bad else ""}')
        check(readback == n and meshok == n, f'{kind}: {readback} of {n} have the sketch object, {meshok} a display mesh of finite vertices')
        check(finite == n, f'{kind}: {finite} of {n} solved points and radii are finite')
        check(solved == n and moved > n // 3, f'{kind}: {solved} of {n} were solved, {moved} of them moved points (the solver ran)')
        # saved once more: the same sketch (solved again when read: its numbers may move on)
        again = resave([b for _, b, rc in saved if rc == 0 and skch(b) is not None], one_by_one=kind == 'bad', tag='q')
        same = sum(rc == 0 and shape(skch(a)) is not None and shape(skch(a)) == shape(skch(b)) and skch(b) is not None and finite_block(skch(b)) and mesh_finite(b)
                   for a, b, rc in again)
        check(same == len(again) and len(again) == ran, f'{kind}: save, open, save: {same} of {len(again)} the same points, entities and constraints, finite, with a display mesh')


def s_dxfsvg():
    print('-- DXF and SVG: written, well formed, construction geometry on its layer / dashed, the units followed, the same bytes each time --')
    base = base_file()
    rng = random.Random(SEED + 1)
    names = []
    for k in range(max(10, RUNS // 3)):
        p = f'{T}/x{k}.bee'
        inject(base, block(rng, constr=True), p)
        names.append(p)
    got = {}
    for units, pre_p in (('m', []), ('mm', ['--op', 'scene.units mm'])):
        args = []
        for p in names:
            args += ['--op', f'file.open {p}', *pre_p, '--op', f'file.export_dxf {p}.{units}.p.dxf', '--op', f'file.export_svg {p}.{units}.p.svg']
        if pre_p:
            rcs = [port('--op', f'file.open {p}', *pre_p, '--op', f'file.export_dxf {p}.{units}.p.dxf', '--op', f'file.export_svg {p}.{units}.p.svg') for p in names]
        else:
            rcs = [port(*args)]
            # once more: the same bytes
            for p in names:
                for ext in ('dxf', 'svg'):
                    if os.path.exists(f'{p}.m.p.{ext}'):
                        os.rename(f'{p}.m.p.{ext}', f'{p}.m.first.{ext}')
            rcs.append(port(*args))
        check(all(rc == 0 for rc in rcs), f'{units}: the exports ran (exit {set(rcs)})')
        for ext in ('dxf', 'svg'):
            written = wellformed = constr = 0
            for p in names:
                try:
                    b = open(f'{p}.{units}.p.{ext}', 'rb').read()
                except OSError:
                    continue
                written += len(b) > 0
                got[(p, units, ext)] = b
                if ext == 'svg':
                    try:
                        wellformed += ET.fromstring(b).tag.endswith('svg')
                    except ET.ParseError:
                        pass
                else:
                    wellformed += b.rstrip().endswith(b'EOF') and b'ENTITIES' in b
                constr += (b'CONSTRUCTION\n10' in b) or (b'dasharray' in b)
            check(written == len(names), f'{ext} in {units}: {written} of {len(names)} files written')
            check(wellformed == len(names), f'{ext} in {units}: {wellformed} of {len(names)} well formed ({"an svg element" if ext == "svg" else "ENTITIES ... EOF"})')
            check(constr > 0, f'{ext} in {units}: {constr} of them have construction geometry')
    for ext in ('dxf', 'svg'):
        same = sum(os.path.exists(f'{p}.m.first.{ext}') and open(f'{p}.m.first.{ext}', 'rb').read() == got.get((p, 'm', ext)) for p in names)
        check(same == len(names), f'{ext}: exported twice, {same} of {len(names)} the same bytes')
        differ = sum(got.get((p, 'm', ext)) is not None and got.get((p, 'm', ext)) != got.get((p, 'mm', ext)) for p in names)
        check(differ == len(names), f'{ext}: {differ} of {len(names)} change with the scene\'s units (metres, millimetres)')
    # nothing to export: the message, no file
    port('--op', f'file.export_dxf {T}/none.dxf')
    check('select a sketch to export' in plog() and not os.path.exists(f'{T}/none.dxf'), 'no sketch: "select a sketch to export", no file')


def s_files():
    print('-- files: saved, opened and saved again; damaged chunks refused or read cleanly --')
    base = base_file()
    rng = random.Random(SEED + 2)
    names = []
    for k in range(20):
        p = f'{T}/f{k}.bee'
        inject(base, block(rng), p)
        names.append(p)
    once = resave(names)
    twice = resave([b for _, b, _ in once])
    thrice = resave([b for _, b, _ in twice])
    ok = sum(rc1 == 0 and rc2 == 0 and shape(skch(b1)) is not None and shape(skch(b1)) == shape(skch(b2)) and reads(b2)
             and struct.unpack_from('<II', skch(b1), 0) == struct.unpack_from('<II', skch(b2), 0) and sketch_obj(b2) is not None
             for (_, b1, rc1), (_, b2, rc2) in zip(twice, thrice))
    check(ok == len(names), f'{ok} of {len(names)}: a saved sketch opened and saved twice more keeps its object, points, entities and constraints')
    # truncated and damaged chunks
    good = skch(names[0])
    cases = {
        'truncated': good[:1000],
        'half a block': good[:4 + 4 + SK_SZ // 2],
        'count too big': struct.pack('<I', 9) + good[4:],
        'no count': b'',
        'object out of range': struct.pack('<II', 1, 99) + good[8:],
        'not a sketch': struct.pack('<II', 1, 2) + good[8:],
        'counts over 256': good[:8 + 12] + struct.pack('<III', 300, 2, 2) + good[8 + 24:],
    }
    rngd = random.Random(SEED + 3)
    for k in range(RUNS // 5):
        g = bytearray(good)
        for _ in range(rngd.randrange(1, 60)):
            g[rngd.randrange(8, len(g))] = rngd.randrange(256)
        cases[f'garbage {k}'] = bytes(g)
    for k in range(RUNS // 10):
        g = bytearray(good)
        o = 8 + ENTS
        for i in range(10):   # entities naming points that are not there, types out of range
            struct.pack_into('<Iiii', g, o + i * 32, rngd.randrange(0, 6), rngd.randrange(-5, 300), rngd.randrange(-5, 300), rngd.randrange(-5, 300))
        struct.pack_into('<I', g, 8 + 16, 10)
        cases[f'wild entities {k}'] = bytes(g)
    crashed = []
    unread = []
    total = 0
    for name, c in cases.items():
        p = f'{T}/d_{total}.bee'
        open(p, 'wb').write(build([(t, c if t == b'SKCH' else d) for t, d in base]))
        total += 1
        rc = port('--op', f'file.open {p}', '--op', f'file.save_as {p}.p.bee', timeout=120)
        if rc != 0:
            crashed.append((name, rc))
            continue
        q = p + '.p.bee'
        cq = skch(q) if os.path.exists(q) else None
        if os.path.exists(q) and not (reads(q) and (cq is None or (len(cq) >= 4 and (struct.unpack_from('<I', cq)[0] == 0 or (len(cq) >= 8 + CONS and finite_block(cq)))))):
            unread.append(name)
    check(not crashed, f'{total} damaged files: each opened and saved (no crash, no hang){": " + str(crashed[:5]) if crashed else ""}')
    check(not unread, f'and what was saved reads back, its sketch finite{": " + str(unread[:5]) if unread else ""}')


# --- the window -----------------------------------------------------------------------------

ROW = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
ROW.update({'.': 52, '/': 53, ' ': 57, '0': 11, '-': 12, ',': 51})
ROW.update({str(i): i + 1 for i in range(1, 10)})


class Fw:
    """tests/wl_fake.py with the calls these steps use: move, button, type, drag, frame."""

    def __init__(self, binary):
        from wl_fake import Fake
        self.f = Fake(binary, size=(1280, 800), env={'BEEMODEL_GPU_VIEW': 'off'})
        self.proc = self.f.proc
        self.f.until(lambda: self.f.frames > 0 and self.f.keyboard is not None and self.f.pointer is not None, 10)

    def pump(self, t=0.05):
        self.f.pump(t)

    def enter(self, x, y):
        self.f.enter(x, y)

    def move(self, x, y):
        self.f.motion(x, y)
        self.f.pump(0.02)

    def mods(self, m):
        self.f.mods(m)
        self.f.pump(0.02)

    def key(self, code):
        self.f.key(code)

    def button(self, down):
        self.f.button(0x110, bool(down))
        self.f.pump(0.02)

    def click(self, x, y):
        self.f.click(x, y)

    def drag(self, x0, y0, x1, y1, steps=6):
        self.move(x0, y0)
        self.button(1)
        for i in range(1, steps + 1):
            self.move(x0 + (x1 - x0) * i // steps, y0 + (y1 - y0) * i // steps)
            self.f.pump(0.03)
        self.button(0)

    def type(self, s):
        for c in s:
            if c == '_':
                self.f.key(12, 1)
            elif c.isupper():
                self.f.key(ROW[c.lower()], 1)
            else:
                self.f.key(ROW[c])

    @property
    def frame(self):
        s = self.f.surfaces[self.f.main().surface]
        bf = self.f.buffers[s['last']]
        return bf['stride'] // 4, bf['h'], s['pixels']


def wrap(binary):
    p = f'{T}/run_{abs(hash(binary)) % 100000}.sh'
    open(p, 'w').write(f'#!/bin/sh\nexec taskset -c {CPU} {binary} "$@"\n')
    os.chmod(p, 0o755)
    return p


class Win:
    def __init__(self, binary):
        self.home = tempfile.mkdtemp(dir=T)
        self.f = Fw(wrap(binary))
        self.f.pump(1.0)
        self.f.enter(600, 350)
        self.f.move(600, 350)
        self.f.pump(0.3)
        self.n = 0

    def line(self, c):
        f = self.f
        f.key(28); f.pump(0.1); f.type(c); f.key(28); f.pump(0.3); f.key(1); f.pump(0.1)

    def maxi(self):
        f = self.f
        f.move(600, 350); f.pump(0.2)
        f.mods(4); f.key(57); f.mods(0); f.pump(0.4)

    def save(self):
        """The sketch now (the viewport back to its place for the console, then maximized again)."""
        self.maxi()
        p = f'{self.home}/s{self.n}.bee'
        self.n += 1
        self.line(f'file.save {p}')
        t0 = time.time()
        while not os.path.exists(p) and time.time() - t0 < 60:
            self.f.pump(0.1)
        self.f.pump(0.2)
        self.maxi()
        return p

    def frame(self):
        wd, h, px = self.f.frame
        return wd, h, bytes(px)

    def close(self):
        self.f.f.close()


def one(fn):
    w = Win(BIN)
    try:
        return fn(w)
    finally:
        w.close()


def pixel(fr, x, y):
    wd, h, px = fr
    o = (y * wd + x) * 4
    return px[o + 2], px[o + 1], px[o]


def blue_mask(fr, box):
    """The sketch's lines in a box: pixels much bluer than the backdrop."""
    out = set()
    for y in range(box[1], box[3]):
        for x in range(box[0], box[2]):
            r, g, b = pixel(fr, x, y)
            if b > r + 60:
                out.add((x, y))
    return out


def accent_mask(fr, box):
    out = set()
    for y in range(box[1], box[3]):
        for x in range(box[0], box[2]):
            r, g, b = pixel(fr, x, y)
            if r > 180 and b < 120:
                out.add((x, y))
    return out


def s_window():
    print('-- sketch mode in the window: tools, picks, constraints, a dimension, a drag, delete, undo; the file after each step --')
    steps = ['rectangle, line chain (snapped, level), circle', 'two lines parallel (Shift+click)', 'H on a slanted line',
             'line and circle tangent', 'D, then 2.5 typed', 'a point dragged', 'a line deleted (X)', 'Ctrl+Z', 'Ctrl+Shift+Z',
             'Esc, Tab out, object.duplicate', 'a point clicked, then F']

    def run(w):
        f = w.f
        snaps, looks = [], {}

        def snap():
            snaps.append(w.save())
        w.line('cad.sketch S XY 0')
        w.maxi()
        f.key(79); f.pump(1.2)                 # Numpad 1: the front
        f.key(19); f.pump(0.2)                 # R
        f.click(400, 250); f.pump(0.3)
        f.move(560, 380); f.pump(0.4)
        looks['rect preview'] = w.frame()
        f.click(560, 380); f.pump(0.4)
        f.key(38); f.pump(0.2)                 # L: a chain from a corner
        f.click(560, 380); f.pump(0.3); f.click(820, 383); f.pump(0.3); f.click(840, 220); f.pump(0.3)
        f.click(700, 200); f.pump(0.3); f.move(900, 300); f.pump(0.4)
        looks['line preview'] = w.frame()
        f.key(1); f.pump(0.2)
        f.key(24); f.pump(0.2)                 # O
        f.click(300, 500); f.pump(0.3); f.click(360, 520); f.pump(0.4)
        f.key(1); f.pump(0.2)
        f.move(1000, 650); f.pump(0.4)
        looks['drawn'] = w.frame()
        snap()
        f.click(480, 250); f.pump(0.3); f.mods(1); f.click(700, 380); f.mods(0); f.pump(0.3)
        f.move(1000, 650); f.pump(0.4)
        looks['two selected'] = w.frame()
        f.key(25); f.pump(0.4)                 # P
        snap()
        f.click(770, 210); f.pump(0.3); f.key(35); f.pump(0.4)   # H
        snap()
        f.click(400, 320); f.pump(0.3); f.mods(1); f.click(300, 437); f.mods(0); f.pump(0.3); f.key(20); f.pump(0.4)  # T
        snap()
        f.click(480, 380); f.pump(0.3)
        w.maxi()
        f.key(32); f.pump(0.4)                 # D: the command line, prefilled
        f.type('2.5'); f.key(28); f.pump(0.4); f.key(1); f.pump(0.2)
        w.maxi()
        f.move(1000, 650); f.pump(0.4)
        looks['labels'] = w.frame()
        snap()
        f.drag(840, 209, 870, 160, steps=6); f.pump(0.5)
        snap()
        f.click(838, 300); f.pump(0.3); f.key(45); f.pump(0.4)   # X
        snap()
        f.mods(4); f.key(44); f.mods(0); f.pump(0.4)
        snap()
        f.mods(5); f.key(44); f.mods(0); f.pump(0.4)
        snap()
        f.key(1); f.pump(0.2); f.key(1); f.pump(0.2)  # Esc: the selection, then sketch mode
        w.maxi()
        w.line('object.duplicate')
        w.maxi()
        snap()
        return snaps, looks
    pa, lb = one(run)
    for k, a in enumerate(pa):
        ca = skch(a)
        check(ca is not None and reads(a) and finite_block(ca) and mesh_finite(a), f'{steps[k]}: the file reads back, its sketch finite, a display mesh')
    if len(pa) < 10 or any(skch(a) is None for a in pa):
        check(False, f'the steps saved {len(pa)} files, {sum(skch(a) is None for a in pa)} without a sketch: nothing more to check')
        return
    # every step changed something (the steps did reach the sketch)
    hdr = [struct.unpack_from('<IIII', skch(a), 8 + 12) for a in pa]
    moved = [skch(pa[k]) != skch(pa[k + 1]) for k in range(len(pa) - 1)]
    check(all(moved[:8]) and hdr[0][:3] == (12, 8, 9), f'each step changed the sketch: {moved}, at first {hdr[0][:3]}')
    check(skch(pa[7]) == skch(pa[5]) and skch(pa[8]) == skch(pa[6]), 'undo gives the step before back, redo the step')
    n = struct.unpack_from('<I', skch(pa[9]))[0]
    check(n == 2, f'a duplicate shares the sketch: {n} in the file')
    # the look
    if os.environ.get('SK_KEEP'):
        from PIL import Image
        for k in lb:
            wd, h, px = lb[k]
            Image.frombytes('RGBA', (wd, h), px, 'raw', 'BGRA').convert('RGB').save(f'{os.environ["SK_KEEP"]}/p_{k.replace(" ", "_")}.png')
    for k in lb:
        box = (395, 195, 565, 392)
        mask = accent_mask if k == 'rect preview' else blue_mask
        mb = mask(lb[k], box)
        check(len(mb) > 200, f'{k}: the rectangle{" (its preview)" if mask is accent_mask else ""}: {len(mb)} line pixels')
    # the accent: the two lines selected, the preview lines
    acc = lambda fr, x, y: pixel(fr, x, y)[0] > 200 and pixel(fr, x, y)[2] < 120
    check(acc(lb['two selected'], 480, 250), 'a selected line is drawn in the accent')
    check(acc(lb['rect preview'], 560, 300), 'the rectangle\'s preview follows the pointer')


def s_point_click():
    print('-- a click on a point selects it --')

    def run(w):
        f = w.f
        w.line('cad.sketch S XY 0')
        w.maxi()
        f.key(79); f.pump(1.2)
        f.key(19); f.pump(0.2)
        f.click(400, 250); f.pump(0.3); f.click(560, 380); f.pump(0.4)
        f.key(1); f.pump(0.2)
        before = skch(w.save())
        f.move(400, 250); f.pump(0.3)
        f.button(1); f.pump(0.3); f.button(0); f.pump(0.4)
        f.key(33); f.pump(0.4)                 # F: fix the selected point
        after = skch(w.save())
        return [struct.unpack_from('<I', c, 8 + 20)[0] if c else None for c in (before, after)]
    a, b = one(run)
    check(a == 8 and b == 9, f'constraints after a click on a corner and F: {b}, the rectangle alone {a} (the point fixed)')


# --- modes, undo interplay, the view -----------------------------------------

def counts(path):
    c = skch(path)
    return struct.unpack_from('<IIIiI', c, 8 + 12) if c and len(c) > 8 else None


def s_modes():
    print('-- Tab, Esc, leaving mid-tool, undo across mode switches, the object going away --')
    p = f'{T}/m.bee'
    R = ['--key', 'r', '--click', '500,300', '--click', '700,450']
    M = ['--move', '600,350']   # (Tab is the viewport's: the pointer over it)
    port('--op', 'cad.sketch S XZ 0', *R, *M, '--key', 'tab', '--op', f'file.save_as {p}')
    check(counts(p)[:3] == (8, 4, 8), f'cad.sketch, R and two clicks: a rectangle {counts(p)}')
    lg = plog()
    check('sketch mode: L line' in lg, 'entering says the keys')
    # Tab leaves: R is then not the rectangle tool
    port('--op', 'cad.sketch S XZ 0', *M, '--key', 'tab', *R, '--op', f'file.save_as {p}')
    check(counts(p)[:3] == (0, 0, 0), f'Tab left sketch mode: clicks draw nothing {counts(p)[:3]}')
    port('--op', 'cad.sketch S XZ 0', *M, '--key', 'tab', *M, '--key', 'tab', *R, '--op', f'file.save_as {p}')
    check(counts(p)[:3] == (8, 4, 8), 'Tab on the sketch enters again')
    # Esc: the tool, then the selection, then sketch mode
    port('--op', 'cad.sketch S XZ 0', '--key', 'r', '--click', '500,300', '--key', 'esc', '--click', '700,450', '--op', f'file.save_as {p}')
    check(counts(p)[:3] == (0, 0, 0), 'Esc ends a tool half way: no rectangle')
    port('--op', 'cad.sketch S XZ 0', '--key', 'esc', '--key', 'r', '--click', '500,300', '--click', '700,450', '--op', f'file.save_as {p}')
    check(counts(p)[:3] == (0, 0, 0), 'Esc with nothing to end leaves sketch mode')
    # undo across the mode switch
    port('--op', 'cad.sketch S XZ 0', *R, *M, '--key', 'tab', '--key', 'ctrl+z', '--op', f'file.save_as {p}')
    c = counts(p)
    check(c is not None and c[:3] == (0, 0, 0), f'Ctrl+Z after leaving sketch mode takes the rectangle back {c and c[:3]}')
    port('--op', 'cad.sketch S XZ 0', *R, *M, '--key', 'tab', '--key', 'ctrl+z', '--key', 'ctrl+shift+z', '--op', f'file.save_as {p}')
    check(counts(p)[:3] == (8, 4, 8), 'and Ctrl+Shift+Z gives it again')
    port('--op', 'cad.sketch S XZ 0', '--key', 'ctrl+z', '--key', 'ctrl+z', *R, '--op', f'file.save_as {p}')
    check(counts(p) is None and 'Sketch' not in [o['name'] for o in beefile.objects(p)], 'undoing the sketch\'s making while in sketch mode: the mode ends with it, clicks draw nothing')
    port('--op', 'cad.sketch S XZ 0', *M, '--key', 'tab', '--op', 'object.delete', *M, '--key', 'tab', *R, '--op', f'file.save_as {p}')
    check(counts(p) is None, 'a deleted sketch: Tab finds none, nothing drawn, no crash')
    # a duplicate shares the block; editing one leaves the other
    port('--op', 'cad.sketch S XZ 0', *R, *M, '--key', 'tab', '--op', 'object.duplicate', '--key', 'esc', *M, '--key', 'tab', '--key', 'l', '--click', '400,200', '--click', '450,250', '--op', f'file.save_as {p}')
    c = skch(p)
    n = struct.unpack_from('<I', c)[0]
    e0 = struct.unpack_from('<I', c, 8 + 16)[0]
    e1 = struct.unpack_from('<I', c, 4 + 4 + SK_SZ + 4 + 16)[0]
    check(n == 2 and sorted((e0, e1)) == [4, 5], f'a duplicate edited in sketch mode: its copy changed alone (entities {e0}, {e1})')
    # the view follows an edit and its undo (the cached image is keyed on the display mesh)
    a = f'{T}/v_a.ppm'
    b = f'{T}/v_b.ppm'
    c2 = f'{T}/v_c.ppm'
    subprocess.run([BIN, '--shot', a, '--op', 'cad.sketch S XZ 0'], env=ENV, capture_output=True, timeout=300)
    subprocess.run([BIN, '--shot', b, '--op', 'cad.sketch S XZ 0', *R], env=ENV, capture_output=True, timeout=300)
    subprocess.run([BIN, '--shot', c2, '--op', 'cad.sketch S XZ 0', *R, '--key', 'ctrl+z'], env=ENV, capture_output=True, timeout=300)
    A, B, C = (ppm_crop(x, (215, 170, 1020, 620)) for x in (a, b, c2))
    check(A != B and A == C, 'the view shows the rectangle, and after Ctrl+Z exactly what it showed before')


def ppm_crop(path, box):
    d = open(path, 'rb').read()
    parts = d.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    px = parts[3]
    return b''.join(px[(y * w + box[0]) * 3:(y * w + box[2]) * 3] for y in range(box[1], box[3]))


def s_ops():
    print('-- the commands\' messages, the form, a dimension with a parameter --')
    p = f'{T}/o.bee'
    port('--op', 'cad.sketch S XZ 0', '--key', 'h')
    check('select what to constrain first' in plog(), 'H with nothing selected: "select what to constrain first"')
    port('--op', 'cad.sketch S XZ 0', '--key', 'd')
    check('takes no dimension' in plog(), 'D with nothing selected: what it takes')
    port('--op', 'cad.sketch S XZ 0', '--op', 'sketch.dim 2')
    check('sketch.dim <value or expression>' in plog() or 'takes no dimension' in plog(), 'sketch.dim without D: its usage')
    # an angle: two lines, D, a plain number is degrees (stored as radians, no text)
    port('--op', 'cad.sketch S XY 0', '--move', '600,350', '--key', 'kp1', '--wait', '1500', '--key', 'r', '--click', '500,300', '--click', '700,450',
         '--key', 'esc', '--click', '600,300', '--mods', 'shift', '--click', '700,375', '--mods', 'none', '--key', 'd', '--op', 'sketch.dim 60', '--op', f'file.save_as {p}')
    c = skch(p)
    nc = struct.unpack_from('<I', c, 8 + 20)[0] if c else 0
    last = struct.unpack_from('<Iiiid', c, 8 + CONS + (nc - 1) * 96) if nc else None
    txt = c[8 + CONS + (nc - 1) * 96 + 36:8 + CONS + (nc - 1) * 96 + 37] if nc else b'?'
    check(last is not None and last[0] == 13 and abs(last[4] - 1.0471975511965976) < 1e-12 and txt == b'\0', f'an angle of "60": 60 degrees in radians, no expression kept {last}')
    # the empty scene's "Start a Sketch...": the form (XZ, offset 0), OK -> a sketch in sketch mode
    port('--op', 'help.template empty', '--click-label', 'Start a Sketch...', '--key', 'enter', '--op', f'file.save_as {p}')
    objs = [(o['name'], o['type']) for o in beefile.objects(p)]
    c = skch(p)
    check(objs == [('Sketch', 3)] and c and struct.unpack_from('<I', c, 8 + 8)[0] == 1 and 'sketch mode: L line' in plog(), f'"Start a Sketch...": the form, then a sketch on XZ in sketch mode {objs}')
    port('--op', 'cad.sketch S QQ 0')
    check('sketch plane: XY, XZ or YZ, not QQ' in plog(), 'a wrong plane: what the planes are')
    # a dimension driven by a parameter: changing it solves the sketch again
    R = ['--move', '600,350', '--key', 'kp1', '--wait', '1500', '--key', 'r', '--click', '500,300', '--click', '700,450', '--key', 'esc']
    port('--op', 'param.set w 3', '--op', 'cad.sketch S XY 0', *R, '--click', '600,300', '--key', 'd', '--op', 'sketch.dim w',
         '--op', f'file.save_as {p}', '--op', 'param.set w 5', '--op', f'file.save_as {p}2')
    def bottom(path):
        c = skch(path)
        if not c:
            return None
        x0 = struct.unpack_from('<d', c, 8 + PTS)[0]
        x1 = struct.unpack_from('<d', c, 8 + PTS + 24)[0]
        return abs(x1 - x0)
    a, b = bottom(p), bottom(p + '2')
    check(a is not None and b is not None and abs(a - 3) < 1e-6 and abs(b - 5) < 1e-6, f'a length of "w": 3, then 5 when w changes ({a}, {b})')
    c = skch(p)
    check(c is not None and b'w\0' in c[8 + CONS:8 + CONS + 96 * 12], 'the dimension keeps its expression in the file')


def s_fuzz():
    print('-- random sessions in sketch mode on this build: keys, clicks, drags, dimensions, undo (no crash, no hang) --')
    rng = random.Random(SEED + 9)
    keys = ['l', 'o', 'r', 'c', 'h', 'v', 'e', 'p', 'n', 't', 'f', 'm', 'd', 'x', 'esc', 'tab', 'ctrl+z', 'ctrl+shift+z', 'shift+d', 'kp1', 'kp7']
    bad = []
    n = max(6, RUNS // 10)
    for k in range(n):
        a = ['--op', f'cad.sketch S {rng.choice(["XY", "XZ", "YZ"])} {rng.choice(["0", "0.5", "-1"])}']
        # (a line first, saved before the random keys: Esc, X and undo may take
        # it all away again, so what is left at the end depends on the seed)
        a += ['--move', '500,350', '--key', 'l', '--click', '450,320', '--click', '620,410', '--key', 'esc', '--op', f'file.save_as {T}/fz{k}a.bee']
        for _ in range(rng.randrange(20, 70)):
            r = rng.random()
            x, y = rng.randrange(220, 1010), rng.randrange(100, 620)
            if r < 0.45:
                a += ['--click', f'{x},{y}']
            elif r < 0.55:
                a += ['--drag', f'{x},{y},{x + rng.randrange(-80, 80)},{y + rng.randrange(-80, 80)}']
            elif r < 0.6:
                a += ['--op', 'sketch.dim ' + rng.choice(['2', '45', '1+1', '30deg', 'w*2', '', 'nosuch', '1e300'])]
            elif r < 0.62:
                a += ['--op', 'file.export_svg ' + f'{T}/fz.svg']
            else:
                a += ['--move', f'{x},{y}', '--key', rng.choice(keys)]
        a += ['--op', f'file.save_as {T}/fz{k}.bee']
        rc = port(*a, timeout=300)
        if rc != 0 or not os.path.exists(f'{T}/fz{k}.bee'):
            bad.append((k, rc))
    check(not bad, f'{n} random sessions ran to their save{": " + str(bad) if bad else ""}')
    drawn = sum(1 for k in range(n) if os.path.exists(f'{T}/fz{k}a.bee') and any(c and c[0] > 0 for c in [counts(f'{T}/fz{k}a.bee')]))
    check(drawn == n, f'{drawn} of {n} drew a line before their random keys (the sessions do draw)')


# --- the review's fixes: a long drag, a W^X system ----------------------------------------

def s_review():
    print('-- a long point drag (each motion shows the sketch anew: the old mesh goes at once), the x87 code with no executable page --')
    # 8300 motions: past the 8192 mesh slots when each one kept its mesh till the next undo step
    def drag(n, tag):
        a = ['--op', 'cad.sketch S XZ 0', '--key', 'r', '--click', '500,300', '--click', '700,450', '--key', 'esc', '--press', '500,300']
        for i in range(n):
            a += ['--move', f'{510 + i % 40},{310 + i % 20}']
        a += ['--move', '560,330', '--release', '560,330', '--dump-verts', f'{T}/dv_{tag};S', '--op', f'file.save_as {T}/dv_{tag}.bee']
        rc = port(*a, timeout=1800)
        v = open(f'{T}/dv_{tag}', 'rb').read() if os.path.exists(f'{T}/dv_{tag}') else None
        so = sketch_obj(f'{T}/dv_{tag}.bee') if os.path.exists(f'{T}/dv_{tag}.bee') else None
        return rc, v, so, skch(f'{T}/dv_{tag}.bee')
    short, long_ = drag(3, 's'), drag(8300, 'l')
    check(short[0] == 0 and long_[0] == 0 and short[1] and short[1] == long_[1], f'8300 motions: the sketch shows where the corner was let go, as after 3 ({len(short[1] or b"")} / {len(long_[1] or b"")} bytes of vertices)')
    # (the points' last bits follow the solver's path: SKCH is not compared, the f32 mesh is)
    check(short[2] is not None and short[2] == long_[2] and long_[3] is not None, 'and the file keeps that mesh (MESH), not one from before the slots ran out')
    # mprotect(PROT_EXEC) refused (a W^X policy): the same sketch, no memory lost
    flt = f'{T}/noexec.py'
    open(flt, 'w').write("""import ctypes, os, struct, sys
libc = ctypes.CDLL(None, use_errno=True)
def ins(code, jt, jf, k): return struct.pack('<HBBI', code, jt, jf, k)
if sys.argv[1] == '1':
    prog = b''.join([ins(0x20, 0, 0, 0), ins(0x15, 0, 3, 10), ins(0x20, 0, 0, 32), ins(0x45, 0, 1, 4), ins(0x06, 0, 0, 0x00050000 | 13), ins(0x06, 0, 0, 0x7fff0000)])
    buf = ctypes.create_string_buffer(prog)
    class FP(ctypes.Structure): _fields_ = [('len', ctypes.c_ushort), ('filter', ctypes.c_void_p)]
    fp = FP(len(prog) // 8, ctypes.addressof(buf))
    assert libc.prctl(38, 1, 0, 0, 0) == 0
    assert libc.prctl(22, 2, ctypes.byref(fp), 0, 0) == 0
os.execv(sys.argv[2], sys.argv[2:])
""")
    a = ['--op', 'cad.sketch S XZ 0', '--key', 'o', '--click', '500,300', '--click', '560,330', '--click', '450,250', '--click', '470,250', '--key', 'l']
    for i in range(300):
        a += ['--click', f'{300 + (i * 13) % 400},{200 + (i * 7) % 300}']
    out = {}
    for tag in ('0', '1'):
        p = subprocess.Popen(['python3', flt, tag, BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *a, '--key', 'esc', '--dump-verts', f'{T}/wx{tag};S'],
                             env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _, st, ru = os.wait4(p.pid, 0)
        out[tag] = (st, ru.ru_maxrss // 1024, open(f'{T}/wx{tag}', 'rb').read() if os.path.exists(f'{T}/wx{tag}') else None)
    check(out['0'][0] == 0 and out['1'][0] == 0 and out['0'][2] and out['0'][2] == out['1'][2],
          f'with mprotect(PROT_EXEC) refused: the same {len((out["0"][2] or b"").splitlines())} vertices (circles: fsincos) bit for bit')
    check(out['1'][1] <= out['0'][1] + 16, f'and no page lost a call: {out["1"][1]} MB at most, {out["0"][1]} MB allowed')

def main():
    print(f'seed {SEED}')
    only = os.environ.get('SK_ONLY', '')
    for s in (s_solver, s_dxfsvg, s_files, s_modes, s_ops, s_fuzz, s_window, s_point_click, s_review):
        if not only or s.__name__ in only.split(','):
            s()
    print('fails', len(FAILS))
    if not os.environ.get('SK_KEEP'):
        import shutil
        shutil.rmtree(T, ignore_errors=True)
    sys.exit(1 if FAILS else 0)


main()
