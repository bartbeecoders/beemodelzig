#!/usr/bin/env python3
"""The CAD document in BeeModel, headless (--op, --dump-log, --dump-ui):
parameters with expressions and units, the scene's units, CADD read back,
undo and redo, damaged CADD chunks; mass properties and the measure tool;
the print check and its panel, the thin-wall overlay; 3MF, the drawing (PDF),
signed-distance shapes; typed number fields; the CAD tab; a fuzz.

    python3 tests/cad.py BIN [random-sessions=40] [seed]

CAD_ONLY=s_params,s_files ... runs some sections.
"""
import math, os, random, re, shutil, struct, subprocess, sys, tempfile, zipfile
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 40
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '6')
FAILS = []
T = tempfile.mkdtemp(prefix='beecad-', dir=os.environ.get('BEECAD_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


# ---- BeeModel, headless ----------------------------------------------------------

def port(*a, ok=True, timeout=600):
    r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a],
                       capture_output=True, text=True, timeout=timeout, env=ENV)
    if ok and r.returncode != 0:
        print(r.stderr[-1500:])
        check(False, f'BeeModel stopped ({r.returncode}): {a[:6]}')
    return r


def script(code, timeout=600):
    """A BeeScript (to make a scene): (exit code, what it printed)."""
    r = subprocess.run(['taskset', '-c', CPU, BIN, '--eval', code], capture_output=True, text=True, timeout=timeout, env=ENV, cwd=T)
    if r.returncode != 0:
        print(r.stdout[-600:], r.stderr[-600:])
    return r.returncode, r.stdout


def ops(*lines):
    out = []
    for ln in lines:
        out += ['--op', ln]
    return out


def log():
    return open(f'{T}/log.txt', errors='replace').read().splitlines()


def ui():
    return open(f'{T}/u.txt', errors='replace').read()


def answers(lines):
    """The console: what each command said, in order ("> cmd" starts one)."""
    out, cur = [], None
    for ln in lines:
        if ln.startswith('> '):
            cur = []
            out.append(cur)
        elif cur is not None:
            cur.append(ln)
    return out


def cadd(path):
    return beefile.chunk(path, b'CADD') if os.path.exists(path) else None


def params(c):
    """CADD: (unit, [(name, expr, value bits)], features, kernel)."""
    unit, n = struct.unpack_from('<dI', c, 0)
    out = []
    for k in range(n):
        r = c[12 + k * 128:12 + (k + 1) * 128]
        out.append((r[:24].split(b'\0')[0].decode(errors='replace'), r[24:116].split(b'\0')[0].decode(errors='replace'), r[120:128].hex()))
    return unit, out, c[12 + n * 128:]


def pvalue(c, name):
    for nm, _, bits in params(c)[1]:
        if nm == name:
            return struct.unpack('<d', bytes.fromhex(bits))[0]
    return None


def sane(c):
    """A CADD that reads back: a real unit, at most 64 parameters, named, the rest whole."""
    if c is None or len(c) < 12:
        return False
    unit, n = struct.unpack_from('<dI', c, 0)
    if not (math.isfinite(unit) and unit > 0) or n > 64 or len(c) < 12 + n * 128:
        return False
    for k in range(n):
        r = c[12 + k * 128:12 + (k + 1) * 128]
        if b'\0' not in r[:24] or b'\0' not in r[24:116] or r[0] == 0:
            return False
    return True


NUM = re.compile(r'-?\d+(?:\.\d+)?(?:e[-+]?\d+)?')


def finite_words(lines):
    return all('nan' not in ln.lower().split() and 'inf' not in ln.lower().split() for ln in lines)


# ---- parameters -----------------------------------------------------------------------

UNITS = ['mm', 'cm', 'm', 'in', 'ft', 'deg', 'rad', ' mm', 'MM', 'km']
FUNCS = ['sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'sqrt', 'abs', 'floor', 'ceil', 'round', 'min', 'max', 'log', 'exp']


def rnd_num(rng):
    k = rng.random()
    if k < .4:
        return str(rng.randrange(0, 200))
    if k < .7:
        return f'{rng.uniform(0, 50):.{rng.randrange(1, 5)}f}'
    if k < .8:
        return f'{rng.randrange(1, 9)}e{rng.choice(["", "-", "+"])}{rng.randrange(0, 4)}'
    if k < .85:
        return '.5'
    if k < .9:
        return f'{rng.randrange(1, 9)}e999'
    return str(rng.randrange(0, 4))


def rnd_expr(rng, names, d=0):
    k = rng.random()
    if d > 3 or k < .3:
        a = rnd_num(rng)
        if rng.random() < .4:
            a += rng.choice(UNITS)
        return a
    if k < .45 and names:
        return rng.choice(names)
    if k < .5:
        return rng.choice(['pi', 'e', 'nosuch', '_x'])
    if k < .62:
        f = rng.choice(FUNCS)
        if f in ('min', 'max'):
            return f'{f}({rnd_expr(rng, names, d + 1)}, {rnd_expr(rng, names, d + 1)})'
        return f'{f}({rnd_expr(rng, names, d + 1)})'
    if k < .7:
        u = rng.choice(['', '', 'mm', 'deg'])
        return f'({rnd_expr(rng, names, d + 1)}){u}'
    if k < .75:
        return rng.choice(['-', '+', '- ']) + rnd_expr(rng, names, d + 1)
    op = rng.choice(['+', '-', '*', '/', '^', ' + ', ' * '])
    return rnd_expr(rng, names, d + 1) + op + rnd_expr(rng, names, d + 1)


def rnd_name(rng):
    k = rng.random()
    if k < .75:
        return rng.choice(['wall', 'width', 'h', 'r', 'gap', 'a1', '_t', 'Depth', 'n2', 'x'])
    return rng.choice(['1x', 'sin', 'pi', 'e', 'max', 'a-b', 'x' * 23, 'y' * 24, 'cos2', 'é'])


def session(rng, n):
    names, out = [], []
    for _ in range(n):
        k = rng.random()
        if k < .62:
            nm = rnd_name(rng)
            ex = rnd_expr(rng, names)
            sep = rng.choice([' ', ' ', ' = ', '='])
            if rng.random() < .15:
                ex = f'"{ex}"'
            if rng.random() < .03:
                ex = ''
            out.append(('param.set', f'{nm}{sep}{ex}'.strip()))
            if nm not in names:
                names.append(nm)
        elif k < .72:
            out.append(('param.remove', rng.choice(names + ['nosuch']) if names else 'nosuch'))
        elif k < .82:
            out.append(('scene.units', rng.choice(['mm', 'cm', 'm', 'in', 'ft', ''])))
        elif k < .92:
            out.append(('param.list', ''))
        else:
            out.append(('cad.kernel', rng.choice(['on', 'off', 'maybe'])))
    return out


def s_params():
    print('-- parameters: random sessions run, CADD reads back, saved again the same; values as their expressions say --')
    rng = random.Random(SEED)
    bad_rt = 0
    for run in range(RUNS):
        seq = session(rng, rng.randrange(4, 18))
        b, b2 = f'{T}/b{run}.bee', f'{T}/b{run}r.bee'
        port(*ops(*[f'{i} {arg}'.strip() for i, arg in seq], f'file.save_as {b}', f'file.open {b}', f'file.save_as {b2}'))
        said = answers(log())
        cb, cb2 = cadd(b), cadd(b2)
        if not (sane(cb) and cb == cb2):
            bad_rt += 1
            print(f'     session {run}: {params(cb) if cb else None} / {params(cb2) if cb2 else None}')
        check(len(said) >= len(seq) and all(said[k] for k in range(len(seq)) if seq[k][0] in ('param.set', 'scene.units', 'cad.kernel')),
              f'session {run}: {len(seq)} commands, each one answered, {len(params(cb)[1]) if cb else "?"} parameters')
    check(bad_rt == 0, f'{RUNS} sessions: CADD sane, open and save again gives the same bytes ({bad_rt} not)')
    # values: what the expressions say, and the same value written two ways
    fixed = ['p1 2^0.5', 'p9 sqrt(2)', 'p3 sin(0.3)', 'p4 cos(1.1)', 'p8 atan(2)', 'p10 floor(-2.5)', 'p12 ceil(1.2)', 'p13 min(1, 2)',
             'p14 max(3, 1)', 'p17 30deg', 'p18 2rad', 'p19 (1+2)cm', 'q19 3cm', 'p16 3ft + 2in', 'q16 38in', 'p15 1e-3 mm', 'q15 0.001mm',
             'p24 -p1 * -p9 / 7', 'p25 "1+2"']
    b = f'{T}/fix.bee'
    port(*ops(*[f'param.set {x}' for x in fixed], 'scene.units in', f'file.save_as {b}'))
    c = cadd(b)
    v = lambda n: pvalue(c, n) if c else None
    want = {'p1': math.sqrt(2), 'p9': math.sqrt(2), 'p3': math.sin(0.3), 'p4': math.cos(1.1), 'p8': math.atan(2), 'p10': -3, 'p12': 2,
            'p13': 1, 'p14': 3, 'p17': math.pi / 6, 'p18': 2, 'p24': 2 / 7, 'p25': 3}
    off = [(n, v(n), w) for n, w in want.items() if v(n) is None or abs(v(n) - w) > 1e-12 * max(1, abs(w))]
    check(not off, f'{len(want)} values as the expressions say (functions, powers, degrees): {off or "all"}')
    pairs = [('p19', 'q19'), ('p16', 'q16'), ('p15', 'q15')]
    off = [(x, y, v(x), v(y)) for x, y in pairs if v(x) is None or v(y) is None or abs(v(x) - v(y)) > 1e-12 * abs(v(y))]   # (a sum: its last bit may differ)
    check(not off and abs(v('q16') * 1000 - 965.2) < 1e-9 and abs(v('q19') - 0.03) < 1e-12, f'units: (1+2)cm is 3cm, 3ft + 2in is 38in, 1e-3 mm is 0.001mm: {off or "the same"}')
    check(c is not None and params(c)[0] == 25.4, f'scene.units in: the unit is 25.4 mm ({params(c)[0] if c else None})')
    check(c is not None and [x for x in params(c)[1] if x[0] == 'p25'][0][1] == '1+2', 'a quoted value: kept without its quotes')
    # names: 23 characters fit, 24 not
    port(*ops('param.set ' + 'x' * 23 + ' 1', 'param.set ' + 'y' * 24 + ' 1', f'file.save_as {b}'))
    names = [x[0] for x in params(cadd(b))[1]] if cadd(b) else []
    check(names == ['x' * 23], f'a name of 23 is taken, one of 24 refused: {names}')
    # a cycle, a set that fails
    port(*ops('param.set a 1', 'param.set b a', 'param.set a b', 'param.set c 2', 'param.set c 2+', f'file.save_as {b}'))
    said = answers(log())
    c = cadd(b)
    check(said[2] and 'cycle' in said[2][0] and [x[1] for x in params(c)[1]] == ['1', 'a', '2'], f'a cycle refused ({said[2]}), a set that fails keeps the old one: {params(c)[1] if c else None}')


def bee_with(src, tag, body):
    """The file src with chunk tag's data replaced by body (None: left out), as version 1."""
    out = b'BEEM' + struct.pack('<I', 1)
    seen = False
    for t, b in beefile.chunks(src):
        if t == tag:
            seen = True
            if body is None:
                continue
            b = body
        out += t + struct.pack('<I', len(b)) + b
    if not seen and body is not None:
        out += tag + struct.pack('<I', len(body)) + body
    return out


def s_files():
    print('-- files: CADD written and read back, a new scene, damaged chunks taken cleanly --')
    seq = ['param.set wall 2mm', 'param.set width 10*wall + 2mm', 'param.set ang asin(0.5)', 'scene.units in', 'cad.kernel on']
    base, b = f'{T}/base.bee', f'{T}/rt.bee'
    port(*ops(*seq, f'file.save_as {base}'))
    c = cadd(base)
    check(sane(c) and len(params(c)[1]) == 3 and params(c)[0] == 25.4 and params(c)[2][-4:] == struct.pack('<I', 1),
          f'CADD written ({len(c) if c else 0} bytes, unit {params(c)[0] if c else "?"}, the kernel on)')
    port(*ops(f'file.open {base}', f'file.save_as {b}'))
    check(cadd(b) == c, 'opened and saved again: the same bytes')
    port(*ops(f'file.open {base}', 'param.list', 'edit.undo', f'file.save_as {b}'))
    lst = [ln for ln in log() if ln.startswith('  parameter ')]
    check(len(lst) == 3 and lst[2].startswith('  parameter ang = asin(0.5)  (0.52'), f'its parameters listed: {lst}')
    check(cadd(b) == c, 'undo right after opening: the document as opened')
    port(*ops(f'file.save_as {b}'))
    check(cadd(b) is not None and len(cadd(b)) == 20 and sane(cadd(b)), f'a new scene: CADD {cadd(b).hex() if cadd(b) else None}')
    rng = random.Random(SEED + 7)
    body = c
    cases = [('cut at %d' % k, body[:k]) for k in (0, 4, 8, 11, 12, 100, 12 + 128 * 3 - 1, 12 + 128 * 3, 12 + 128 * 3 + 3, len(body) - 1)]
    cases += [('64 parameters claimed', body[:8] + struct.pack('<I', 64) + body[12:]),
              ('65 parameters', body[:8] + struct.pack('<I', 65) + body[12:]),
              ('a negative unit', struct.pack('<d', -3) + body[8:]),
              ('a NaN unit', struct.pack('<d', float('nan')) + body[8:]),
              ('a zero unit', struct.pack('<d', 0) + body[8:]),
              ('names without an end', body[:12] + b'n' * 128 + body[12 + 128:]),
              ('65 features', body[:12 + 128 * 3] + struct.pack('<I', 65) + body[16 + 128 * 3:]),
              ('2 features, none there', body[:12 + 128 * 3] + struct.pack('<I', 2) + body[16 + 128 * 3:]),
              ('kernel 6', body[:-4] + struct.pack('<I', 6)),
              ('one feature', body[:12 + 128 * 3] + struct.pack('<I', 1) + bytes(range(128)) + struct.pack('<I', 1)),
              ('no CADD', None),
              ('wall fails: 2qm', body[:37] + b'q' + body[38:]),
              ('wall fails then uses ang: q+ang', body[:36] + b'q+ang' + body[41:]),
              ('wall uses ang then fails: ang+q', body[:36] + b'ang+q' + body[41:])]
    for k in range(8):
        g = bytearray(body)
        for _ in range(rng.randrange(1, 6)):
            g[rng.randrange(len(g))] = rng.randrange(256)
        cases.append((f'garbage {k}', bytes(g)))
    for name, data in cases:
        src = f'{T}/dam.bee'
        open(src, 'wb').write(bee_with(base, b'CADD', data))
        b3, b4 = f'{T}/dam_p.bee', f'{T}/dam_q.bee'
        for p in (b3, b4):
            if os.path.exists(p):
                os.remove(p)
        r = port(*ops(f'file.open {src}', 'param.list', f'file.save_as {b3}', f'file.open {b3}', f'file.save_as {b4}'), ok=False)
        cb = cadd(b3)
        check(r.returncode == 0 and sane(cb) and cb == cadd(b4), f'{name}: no stop, {len(params(cb)[1]) if cb else "?"} parameters, unit {params(cb)[0] if cb else "?"}, saved back the same')


def s_undo():
    print('-- undo and redo: each step undone gives the document before it, redone the one after; none for what failed --')
    cases = [
        ['param.set a 1mm', 'param.set b 2*a', 'param.set c a+'],
        ['param.set a 1mm', 'scene.units mm', 'cad.kernel on'],
        ['param.set a 1mm', 'param.set a 3mm', 'param.remove a'],
        ['param.set a 1mm', 'param.set b a*2', 'param.set a b'],
        ['param.set a 1mm', 'cad.kernel on', 'cad.kernel maybe', 'param.remove zz'],
        ['param.set x 1', 'param.set y 2', 'param.set z 3'],
    ]
    bad = []

    def doc(lines):
        b = f'{T}/u.bee'
        if os.path.exists(b):
            os.remove(b)
        port(*ops(*lines, f'file.save_as {b}'))
        return cadd(b), [ln[0] if ln else '' for ln in answers(log())[:len(lines)]]
    n = 0
    for seq in cases:
        for k in range(1, len(seq) + 1):
            pre, cur = seq[:k - 1], seq[:k]
            before, _ = doc(pre)
            after, said = doc(cur)
            failed = 'parameter:' in said[-1] or after == before
            undone, _ = doc(cur + ['edit.undo'])
            n += 1
            if failed:
                # nothing changed, no step: undo takes back the one before
                want, _ = doc(pre + ['edit.undo'])
                if not (after == before and undone == want):
                    bad.append(f'{" ; ".join(cur)} (failed: {said[-1]})')
                continue
            redone, _ = doc(cur + ['edit.undo', 'edit.redo'])
            if not (undone == before and redone == after):
                bad.append(' ; '.join(cur))
    for x in bad:
        print('     ' + x)
    check(not bad, f'{n} steps in {len(cases)} sequences: undo gives the document before, redo the one after, a failure makes no step ({len(bad)} not)')


def s_measure():
    print('-- mass properties: boxes moved, turned, scaled, of a density, in every unit (a unit of the scene is one of them) --')
    scene = f'{T}/m.bee'
    code = 'delete("Cube")\n'
    # (a cube is 2 m a side: scaled, its volume and area are known)
    boxes = [('A', (0, 1, 0), (1, 1, 1), 1.0), ('B', (3, 0.5, -1), (1, 2, 0.5), 2.7), ('C', (-2, 0, 2), (0.3, 1, 0.3), 0.05), ('D', (0, -1, 4), (2, 2, 2), 1.0),
             ('E', (5, 0, 0), (0.03, 0.03, 0.03), 1.0)]
    for nm, loc, scl, _ in boxes:
        code += f'add("cube", "{nm}", {loc[0]}, {loc[1]}, {loc[2]})\nscale("{nm}", {scl[0]}, {scl[1]}, {scl[2]})\n'
    code += 'rotate("D", 30deg, 45deg, 10deg)\n'
    code += 'material("Alu")\nmatset("Alu", "density", 2.7)\nassign("B", "Alu")\nmaterial("Light")\nmatset("Light", "density", 0.05)\nassign("C", "Light")\n'
    code += f'op("file.save_as", "{scene}")\n'
    script(code)
    check(os.path.exists(scene), 'the scene made')
    per = {}
    for unit, cm in (('m', 100), ('mm', 0.1), ('cm', 1), ('in', 2.54)):
        port(*ops(f'file.open {scene}', f'scene.units {unit}', 'object.select_all', 'object.select_all', 'object.measure'))
        said = answers(log())[-1]
        rows = {}
        for ln in said:
            m = re.match(r'\s+(\S+): volume (\S+) (\S+)\^3, area (\S+) (\S+)\^2, mass (\S+) (k?g)', ln)
            if m and m.group(3) == m.group(5) == unit:
                rows[m.group(1)] = (float(m.group(2)), float(m.group(4)), float(m.group(6)) * (1000 if m.group(7) == 'kg' else 1), m.group(7))
        per[unit] = rows
        ok = len(rows) == len(boxes)
        for nm, _, s, dens in boxes:
            if nm not in rows:
                continue
            vol = 8 * s[0] * s[1] * s[2]
            area = 8 * (s[0] * s[1] + s[1] * s[2] + s[0] * s[2])
            mass = vol * cm ** 3 * dens   # (g: a density in g/cm^3)
            got = rows[nm]
            close = lambda x, y: abs(x - y) <= 2e-3 * y + 1.5e-3   # (three decimals printed)
            if not (close(got[0], vol) and close(got[1], area) and close(got[2], mass)):
                ok = False
                print(f'     {unit} {nm}: volume {got[0]} area {got[1]} mass {got[2]} g, want {vol} {area} {mass} g')
        check(ok, f'{unit}: {len(rows)} meshes in {unit}, volume, area and mass as their sizes and densities say')
    e = per.get('m', {}).get('E')
    check(e is not None and e[3] == 'g' and per['m']['A'][3] == 'kg', f'under a kilogram in grams (E, 216 g: {e}), over in kilograms')
    # nothing selected: the active one (the file's flags cleared)
    objs = bytearray(beefile.chunk(scene, b'OBJS'))
    for k in range(struct.unpack_from('<I', objs)[0]):
        struct.pack_into('<I', objs, 4 + k * 84 + 76, struct.unpack_from('<I', objs, 4 + k * 84 + 76)[0] & ~1)
    none = f'{T}/none.bee'
    open(none, 'wb').write(bee_with(scene, b'OBJS', bytes(objs)))
    port(*ops(f'file.open {none}', 'object.measure'))
    said = answers(log())[-1]
    check(len(said) == 1 and 'volume' in said[0], f'nothing selected, the active one: {said}')
    port(*ops('object.delete', 'object.measure'))
    said = answers(log())[-1]
    check(len(said) == 1 and 'volume' not in said[0], f'no mesh: {said}')


def chunk_(tag, body):
    return tag + struct.pack('<I', len(body)) + body


def bee_mesh(objs):
    """A .bee of meshes: [(name, verts, polys, loc, rot (radians), scl)], all selected."""
    out = b'BEEM' + struct.pack('<I', 1)
    o = struct.pack('<I', len(objs))
    for k, (nm, verts, polys, loc, rot, scl) in enumerate(objs):
        off, loops = [0], []
        for p in polys:
            loops += p
            off.append(len(loops))
        m = struct.pack('<III', len(verts), len(polys), len(loops))
        m += b''.join(struct.pack('<3f', *v) for v in verts)
        m += struct.pack(f'<{len(off)}I', *off) + struct.pack(f'<{len(loops)}I', *loops)
        out += chunk_(b'MESH', m)
        o += nm.encode().ljust(32, b'\0') + struct.pack('<9f', *loc, *rot, *scl) + struct.pack('<IIII', 0xb4b8c0, 0, 1, k)
    view = struct.pack('<III6f', 0, 1, 0, 0.785398, 0.5, 18, 0, 0, 0)   # (the first one active)
    return out + chunk_(b'OBJS', o) + chunk_(b'VIEW', view)


def box(rng, c, h, jit=0.0, flip=False):
    v = [(c[0] + sx * h[0] + rng.uniform(-jit, jit), c[1] + sy * h[1] + rng.uniform(-jit, jit), c[2] + sz * h[2] + rng.uniform(-jit, jit))
         for sz in (-1, 1) for sy in (-1, 1) for sx in (-1, 1)]
    f = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
    if flip:
        f = [list(reversed(x)) for x in f]
    return v, f


def rnd_part(rng):
    """Shells, plates, rods, open boxes: walls of every thickness."""
    verts, polys = [], []

    def add(vf):
        n = len(verts)
        verts.extend(vf[0])
        polys.extend([[i + n for i in p] for p in vf[1]])
    k = rng.random()
    if k < .3:   # a hollow box: an outer one and an inner one turned inside out
        h = [rng.uniform(.5, 2) for _ in range(3)]
        t = rng.uniform(.001, .3)
        add(box(rng, (0, 0, 0), h))
        add(box(rng, (rng.uniform(-.05, .05), 0, 0), [x - t for x in h], flip=True))
    elif k < .5:  # plates
        for _ in range(rng.randrange(1, 4)):
            add(box(rng, (rng.uniform(-2, 2), rng.uniform(-2, 2), rng.uniform(-2, 2)), (rng.uniform(.2, 2), rng.uniform(.0005, .05), rng.uniform(.2, 2)), jit=rng.choice([0, .001])))
    elif k < .7:  # a box with a hole, jittered
        add(box(rng, (0, 0, 0), [rng.uniform(.3, 1) for _ in range(3)], jit=rng.uniform(0, .2)))
        polys.pop(rng.randrange(len(polys)))
    else:         # boxes overlapping, touching, inside each other
        for _ in range(rng.randrange(2, 6)):
            add(box(rng, (rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)), [rng.uniform(.05, .8) for _ in range(3)], jit=rng.choice([0, .01])))
    return verts, polys


def near(a, b):
    """The same lines but for numbers off by one in their last (third) decimal."""
    if len(a) != len(b):
        return False
    num = re.compile(r'-?\d+(?:\.\d+)?')
    for x, y in zip(a, b):
        if num.sub('#', x) != num.sub('#', y):
            return False
        for p, q in zip(num.findall(x), num.findall(y)):
            if abs(float(p) - float(q)) > 0.0011 + 1e-6 * abs(float(p)):
                return False
    return True


def s_print():
    print('-- print check: walls, closedness, overhangs, size; minimums and units --')
    scene = f'{T}/p.bee'
    code = 'delete("Cube")\n'
    code += 'add("cube", "Plate", 0, 1, 0)\nscale("Plate", 3, 0.002, 2)\n'
    code += 'add("sphere", "Ball", 4, 1, 0)\n'
    code += 'add("cylinder", "Rod", -4, 1, 0)\nscale("Rod", 0.0004, 2, 0.0004)\n'
    code += 'add("torus", "Ring", 0, 3, 4)\nrotate("Ring", 40deg, 10deg, 0)\n'
    code += 'add("plane", "Sheet", 0, 0, -4)\n'
    code += 'add("cone", "Tip", 3, 0, -3)\nscale("Tip", 0.01, 0.5, 0.01)\n'
    code += 'add("grid", "Mesh", -3, 0, -3)\n'
    code += 'add("cube", "Box2", 6, 0, 6)\nadd("cube", "Box3", 6.0005, 0, 6)\n'
    code += f'op("file.save_as", "{scene}")\n'
    script(code)
    check(os.path.exists(scene), 'the scene made')
    res = {}
    for unit, mn in (('m', ''), ('mm', '0.5'), ('m', '3'), ('cm', '25'), ('in', '1'), ('m', '1e3'), ('m', 'abc')):
        port(*ops(f'file.open {scene}', f'scene.units {unit}', 'object.select_all', 'object.select_all', f'mesh.print_check {mn}'.strip()))
        said = answers(log())[-1]
        heads = {ln.split(':')[0].strip(): ln for ln in said if not ln.startswith('  overhangs')}
        opened = [nm for nm, ln in heads.items() if 'NOT closed' in ln]
        thin = {nm: int(re.search(r'\((\d+) faces under', ln).group(1)) for nm, ln in heads.items() if 'faces under' in ln}
        res[(unit, mn)] = (said, thin)
        check(len(said) == 2 * 9 and len(heads) == 9 and len(thin) + len(opened) == 9 and sorted(opened) == ['Mesh', 'Sheet'] and finite_words(said),
              f'{unit}, minimum "{mn}": {len(heads)} meshes, two lines each, {sum(1 for x in thin.values() if x)} with thin faces, open: {opened}')
    said, thin = res[('m', '')]
    plate = [ln for ln in said if ln.startswith('  Plate:')]
    pidx = said.index(plate[0]) if plate else -1
    wall = re.search(r'thinnest wall (\S+) mm', plate[0]) if plate else None
    check(wall is not None and abs(float(wall.group(1)) - 4) < 0.01, f'the plate (4 mm): {plate}')
    sz = re.search(r'size (\S+) x (\S+) x (\S+) mm', said[pidx + 1]) if plate else None
    check(sz is not None and [round(float(x)) for x in sz.groups()] == [6000, 4000, 4], f'its size: the height (y) last: {said[pidx + 1] if plate else None}')
    check(thin.get('Rod', 0) > 0 and thin.get('Plate') == 0, f'1 mm: the rod (0.8 mm) thin, the plate not: {thin}')
    # (a unit of the scene is one mm: the plate is 0.004 mm, the ball 2 mm)
    t = res[('mm', '0.5')][1]
    check(t.get('Plate') == 2 and t.get('Ball') == 0, f'0.5 mm, the scene in mm: the plate\'s two sides thin, the ball not: {t}')
    t = res[('m', '3')][1]
    check(t.get('Plate') == 0 and t.get('Rod', 0) > 0, f'3 mm, the scene in m: the plate (4 mm) not thin, the rod is: {t}')
    t = res[('cm', '25')][1]
    check(t.get('Ball', 0) > 0 and t.get('Box2') == 6, f'25 mm, the scene in cm: the ball (2 cm) and the cubes thin: {t}')
    box2 = [said[k + 1] for k, ln in enumerate(said) if ln.startswith('  Box2:')]
    check(box2 and 'overhangs 0%' in box2[0], f'a cube on the bed: no overhangs ({box2})')
    # random parts: walls of every kind, turned and scaled
    rng = random.Random(SEED + 3)
    bad = 0
    n = max(4, RUNS // 4)
    for k in range(n):
        objs = []
        for j in range(rng.randrange(1, 4)):
            v, p = rnd_part(rng)
            rot = rng.choice([(0, 0, 0), (0, 0, 0), (rng.uniform(-3, 3), rng.uniform(-3, 3), rng.uniform(-3, 3))])
            scl = rng.choice([(1, 1, 1), (2, 2, 2), (1, rng.uniform(.1, 3), 1)])
            objs.append((f'P{j}', v, p, (rng.uniform(-3, 3), rng.uniform(-3, 3), rng.uniform(-3, 3)), rot, scl))
        f = f'{T}/r{k}.bee'
        open(f, 'wb').write(bee_mesh(objs))
        mn = rng.choice(['1', '0.5', '5', '50', '200'])
        port(*ops(f'file.open {f}', f'mesh.print_check {mn}'))
        said = answers(log())[-1]
        if len(said) != 2 * len(objs) or not finite_words(said):
            bad += 1
            print(f'     part {k}: {said}')
    check(bad == 0, f'{n} random parts (shells, plates, holes, overlaps): two lines a mesh, numbers finite ({bad} not)')
    port(*ops('mesh.print_check'))
    said = answers(log())[-1]
    check(len(said) == 2 and 'closed' in said[0], f'a new scene, the cube: {said}')
    port(*ops('object.delete', 'mesh.print_check'))
    said = answers(log())[-1]
    check(len(said) == 1, f'no mesh: {said}')


def mesh_of(path, name):
    """The mesh object `name` shows (None: none, or no such object)."""
    ob = [x for x in beefile.objects(path) if x['name'] == name]
    ms = beefile.meshes(path)
    return ms[ob[0]['mesh']] if ob and ob[0]['mesh'] < len(ms) else None


def s_panel():
    print('-- the Print Check panel: its rows, Show buttons select what was found, stale after a change --')
    rng = random.Random(4)
    v, p = box(rng, (0, 0, 0), (1, 0.0004, 1))
    v3, p3 = box(rng, (4, 0, 0), (1, 1, 1))   # (and a block: a mesh does not go empty)
    plate = ('Plate', v + v3, p + [[i + 8 for i in x] for x in p3], (0, 1, 0), (0, 0, 0), (1, 1, 1))
    v2, p2 = box(rng, (0, 0, 0), (1, 1, 1))
    opn = ('Open', v2, p2[1:] + [[0, 1, 2]], (0, 1, 0), (0, 0, 0), (1, 1, 1))
    a, b = box(rng, (0, 0, 0), (1, 0.5, 1))
    c, d = box(rng, (0.5, 2, 0), (1, 0.3, 0.5))
    over = ('Over', a + c, b + [[i + 8 for i in x] for x in d], (0, 0.5, 0), (0, 0, 0), (1, 1, 1))
    shown = []
    for obj, what, mn in ((plate, 'thin', '1'), (opn, 'edges', '1'), (over, 'overhangs', '1'), (plate, 'thin', '0.5'), (over, 'thin', '700')):
        f = f'{T}/{obj[0]}.bee'
        open(f, 'wb').write(bee_mesh([obj]))
        bp = f'{T}/{obj[0]}_p.bee'
        port(*ops(f'file.open {f}', f'mesh.print_check {mn}', f'mesh.print_show {what}', 'mesh.delete_vertices', 'mode.object', f'file.save_as {bp}'))
        mb = mesh_of(bp, obj[0])
        gone = len(obj[1]) - (len(mb[0]) if mb else 0)
        shown.append(gone)
        print(f'     {obj[0]} {what} under {mn} mm: {gone} of {len(obj[1])} vertices selected')
    check(shown[0] == 8 and shown[3] == 0, f'thin under 1 mm: the 0.8 mm plate\'s 8 vertices, not the block\'s; under 0.5 mm none ({shown[0]}, {shown[3]})')
    check(0 < shown[1] < 8, f'open edges: the hole\'s vertices ({shown[1]})')
    check(0 < shown[2] < 16, f'overhangs: some of the vertices ({shown[2]})')
    check(shown[4] == 8, f'thin under 700 mm: the 600 mm block\'s 8 vertices, not the 1000 mm one\'s ({shown[4]})')
    # the panel through its button, and what it says
    f = f'{T}/Over.bee'
    port(*ops(f'file.open {f}', 'mesh.print_check 1'), '--click-label', 'button:Show', *ops('mesh.delete_vertices', 'mode.object', f'file.save_as {T}/btn.bee'))
    mb = mesh_of(f'{T}/btn.bee', 'Over')
    check(mb is not None and 16 - len(mb[0]) == shown[2], f'its Show button: the overhangs\' vertices selected ({16 - len(mb[0]) if mb else None} gone)')
    port(*ops(f'file.open {f}', 'mesh.print_check 1'))
    said = answers(log())[-1]
    rows = [ln.split('\t')[1] for ln in ui().splitlines() if ln.startswith('info\t')]
    ov = re.search(r'overhangs (\S+)% of the area, size (.*)', said[1]) if len(said) > 1 else None
    want = ['Closed', 'Thinnest wall 600 mm', '0 faces under 1 mm', f'Overhangs {ov.group(1) if ov else "?"}%', 'Size', ov.group(2) if ov else '?']
    check(all(w in rows for w in want) and 'button\tCheck Again' in ui(), f'the rows say what the console said: {rows}')
    port(*ops(f'file.open {f}', 'mesh.print_check 1'), '--move', '615,360', '--key', 'g', '--type', '1', '--key', 'enter')
    check('The mesh changed since: check it again.' in ui(), 'moved: the findings are out of date')
    port(*ops(f'file.open {f}', 'mesh.print_check 1', 'edit.undo'))
    check('section\tPrint Check' in ui() and 'Thinnest wall 600 mm' in ui(), 'undo leaves the findings (nothing changed)')


def project(p, canvas, yaw=0.7853982, pitch=0.5, dist=18.0):
    """A world point on screen in the default view (fakewl.project)."""
    sy, cy, sp, cp = math.sin(yaw), math.cos(yaw), math.sin(pitch), math.cos(pitch)
    right = (cy, 0, -sy)
    up = (-sp * sy, cp, -sp * cy)
    fwd = (-cp * sy, -sp, -cp * cy)
    eye = [-fwd[i] * dist for i in range(3)]
    d = [p[i] - eye[i] for i in range(3)]
    dot = lambda a, b: sum(a[i] * b[i] for i in range(3))
    x0, y0, x1, y1 = canvas
    f = (y1 - y0) * 1.07
    z = dot(d, fwd)
    return (int((x0 + x1) / 2 + f * dot(d, right) / z), int((y0 + y1) / 2 - f * dot(d, up) / z))


CANVAS = (208, 80, 1024, 633)


def s_tool():
    print('-- the measure tool: clicks snap to vertices, the distance and the angle --')
    corners = [(1, 2, -1), (-1, 0, 1), (1, 0, 1)]   # (not equal sides: the angle at the middle one is its own)
    clicks = []
    for c in corners:
        x, y = project(c, CANVAS)
        clicks += ['--press', f'{x},{y}', '--release', f'{x},{y}']
    port('--move', '600,300', '--key', 'shift+m', *clicks)
    lines = [ln for ln in log() if ln.startswith('  distance ') or ln.startswith('  angle ')]
    dist = math.sqrt(12)
    ok_d = len(lines) == 2 and abs(float(lines[0].split()[1]) - dist) < 0.0006 and ' m (' in lines[0]
    check(ok_d, f'two vertices: {lines[0] if lines else None} (between them {dist:.4f})')
    u = [corners[0][i] - corners[1][i] for i in range(3)]
    w = [corners[2][i] - corners[1][i] for i in range(3)]
    deg = math.degrees(math.acos(sum(u[i] * w[i] for i in range(3)) / math.sqrt(sum(x * x for x in u) * sum(x * x for x in w))))
    ok_a = len(lines) == 2 and abs(float(lines[1].split()[1]) - deg) < 0.0006 and lines[1].endswith(' deg')
    check(ok_a, f'a third: the angle at the second: {lines[1] if len(lines) > 1 else None} ({deg:.4f} deg)')
    port('--move', '600,300', '--key', 'shift+m', *clicks[:8], '--key', 'esc', *clicks[8:])
    lines = [ln for ln in log() if ln.startswith('  distance ') or ln.startswith('  angle ')]
    check(len(lines) == 1, f'Esc ends it: the third click selects instead ({lines})')
    port('--move', '600,300', '--key', 'shift+m', *clicks, *clicks[:8])
    lines = [ln for ln in log() if ln.startswith('  distance ') or ln.startswith('  angle ')]
    check(len(lines) == 3 and lines[2] == lines[0], f'a fourth click starts again ({len(lines)} results)')


def colours(path, cols):
    """How many pixels of each colour (a .ppm or .png)."""
    from PIL import Image
    im = Image.open(path).convert('RGB')
    data = im.tobytes()
    out = []
    for c in cols:
        b = bytes(((c >> 16) & 255, (c >> 8) & 255, c & 255))
        out.append(sum(1 for i in range(0, len(data), 3) if data[i:i + 3] == b))
    return out


def s_look():
    print('-- the look: thin walls red and yellow, the legend counts them --')
    rng = random.Random(6)
    a, b = box(rng, (0, 0, 0), (2, 0.0003, 2))
    c, d = box(rng, (0, 0, 2.5), (1.5, 0.0008, 0.4))
    plate = ('Plate', a + c, b + [[i + 8 for i in x] for x in d], (0, 1, 0), (0, 0, 0), (1, 1, 1))
    f = f'{T}/look.bee'
    open(f, 'wb').write(bee_mesh([plate]))
    RED, YEL = 0xff3030, 0xf0d040
    port(*ops(f'file.open {f}', 'view.show_thickness 1'), '--move', '600,700')
    got = colours(f'{T}/u.ppm', [RED, YEL])
    leg = [ln.split('\t')[1] for ln in ui().splitlines() if ln.startswith('analysis\t')]
    check(all(x > 30 for x in got), f'red (under 1 mm) and yellow (under 2 mm) faces: {got} px')
    check(leg and leg[0].split()[-1] == '2', f'the legend counts 2 thin faces: {leg}')
    port(*ops(f'file.open {f}'), '--move', '600,700')
    none = colours(f'{T}/u.ppm', [RED, YEL])
    check(none == [0, 0], f'none without the overlay ({none})')
    port(*ops(f'file.open {f}', 'view.show_thickness 1', 'view.show_thickness'), '--move', '600,700')
    check(colours(f'{T}/u.ppm', [RED, YEL]) == [0, 0], 'view.show_thickness again turns it off')


def s_3mf():
    print('-- 3MF: a zip anyone reads, the CRCs right, Z up, the same bytes each time --')
    scene = f'{T}/f.bee'
    code = 'add("sphere", "Ball <&\\"x\\">", 3, 0.5, -1)\nscale("Ball <&\\"x\\">", 1, 2, 0.5)\n'
    code += 'add("torus", "Ring", 0, 3, 4)\nadd("cone", "Tip", -2, 0, 1)\nscale("Tip", 0.3, 1.5, 0.3)\n'
    code += 'add("grid", "G", 0, 0, 0)\nadd("cylinder", "M", 4, 0, 4)\nmodifier("M", "mirror")\n'
    code += f'op("file.save_as", "{scene}")\n'
    script(code)
    check(os.path.exists(scene), 'the scene made')
    for unit in ('m', 'mm', 'in'):
        b, b2 = f'{T}/b.3mf', f'{T}/b2.3mf'
        for x in (b, b2):
            if os.path.exists(x):
                os.remove(x)
        port(*ops(f'file.open {scene}', f'scene.units {unit}', f'file.export_3mf {b}', f'file.export_3mf {b2}'))
        said = answers(log())[-2]
        db = open(b, 'rb').read() if os.path.exists(b) else None
        check(db is not None and len(db) > 1000 and db == open(b2, 'rb').read(), f'{unit}: {len(db) if db else None} bytes, the same again; it says {said}')
        z = zipfile.ZipFile(b)
        names = z.namelist()
        bad = z.testzip()
        model = z.read('3D/3dmodel.model').decode()
        check(names == ['[Content_Types].xml', '_rels/.rels', '3D/3dmodel.model'] and bad is None and model.count('<object ') == 6 and 'Ball &lt;&amp;&quot;x&quot;&gt;' in model,
              f'  a zip: {names}, CRCs {"right" if bad is None else "wrong: " + bad}, {model.count("<object ")} objects, the name escaped')
        # the ball's place: 3D printers have Z up: x stays, z is the scene's height, y its depth turned
        obj = model.split('<object ')[1:]
        ball = [o for o in obj if 'Ball' in o.split('>')[0]]
        vs = [tuple(float(q) for q in m) for m in re.findall(r'<vertex x="([^"]+)" y="([^"]+)" z="([^"]+)"', ball[0])] if ball else []
        cen = [sum(v[i] for v in vs) / len(vs) for i in range(3)] if vs else None
        f = {'m': 1000, 'mm': 1, 'in': 25.4}[unit]   # (mm in a unit of the scene)
        um = re.search(r'unit="(\w+)"', model)
        scale = {'millimeter': 1, 'meter': 1000, 'inch': 25.4, 'centimeter': 10}.get(um.group(1) if um else 'millimeter', 1)
        if cen:
            cen = [x * scale / f for x in cen]   # (units of the scene)
        check(cen is not None and abs(cen[0] - 3) < 0.05 and abs(cen[1] - 1) < 0.05 and abs(cen[2] - 0.5) < 0.05, f'  the ball at (3, 1, 0.5) {unit} with Z up: {cen} ({len(vs)} vertices)')
    port(*ops('object.delete', f'file.export_3mf {T}/none.3mf'))
    check(not os.path.exists(f'{T}/none.3mf') and answers(log())[-1], f'nothing to export: {answers(log())[-1]}')
    port(*ops('file.export_3mf'))
    check(any(ln.startswith('> ') for ln in log()), 'no path: the console holds the command to finish')


def s_pdf():
    print('-- the drawing (PDF): every option, a whole PDF, the same bytes each time --')
    scene = f'{T}/d.bee'
    code = 'add("cylinder", "Shaft (main)", 3, 0.5, -1)\nscale("Shaft (main)", 0.5, 2, 0.5)\n'
    code += 'add("torus", "Ring", 0, 3, 4)\nrotate("Ring", 30deg, 0, 20deg)\nadd("cone", "Tip", -2, 0, 1)\n'
    code += 'add("sphere", "Ball", 1, 1, 1)\nmodifier("Ball", "mirror")\n'
    code += f'op("file.save_as", "{scene}")\n'
    script(code)
    check(os.path.exists(scene), 'the scene made')
    cases = [('', 'm', ''), ('', 'mm', 'a3 portrait views front top right iso scale auto title "Bracket (rev 2)" author Ann'),
             ('', 'in', 'letter landscape views iso'), ('select', 'm', 'a2 views front right scale 1:50'),
             ('select', 'cm', 'a4 views top iso scale 2:1 title "" author ""'), ('every', 'mm', 'a3 landscape views front top right iso scale auto')]
    hist = []
    for sel, unit, opts in cases:
        b, b2 = f'{T}/b.pdf', f'{T}/b2.pdf'
        for x in (b, b2):
            if os.path.exists(x):
                os.remove(x)
        pre = ['--select', 'Tip'] if sel == 'select' else ops('object.select_all', 'object.select_all') if sel == 'every' else []
        if opts:
            hist.append(opts)
        port(*ops(f'file.open {scene}', f'scene.units {unit}', *[f'drawing.options {x}' for x in hist]), *pre, *ops(f'file.export_pdf {b}', f'file.export_pdf {b2}'))
        db = open(b, 'rb').read() if os.path.exists(b) else None
        nl = db.count(b' l S') if db else 0
        whole = db is not None and db.startswith(b'%PDF-') and db.rstrip().endswith(b'%%EOF') and b'xref' in db
        check(whole and nl > 20 and db == open(b2, 'rb').read(), f'{sel or "all"}, {unit}, {opts or "defaults"}: {len(db) if db else None} bytes, {nl} lines, the same again')
        if 'title "Bracket' in opts:
            check(b'Bracket (rev 2)' in db or b'Bracket \\(rev 2\\)' in db, '  the title in it')
    port(*ops('object.delete', f'file.export_pdf {T}/none.pdf'))
    said = answers(log())[-1]
    check(said == ['  nothing to draw: no meshes'] and not os.path.exists(f'{T}/none.pdf'), f'nothing to draw: {said}')


def rnd_shape(rng, depth=0):
    """A random shape graph: (BeeScript lines, console lines), the last node's variable."""
    bs, cl = [], []
    cnt = [0]

    def node(script, console):
        cnt[0] += 1
        v = f'n{cnt[0]}'
        bs.append(f'{v} = {script}')
        cl.append(console)
        return v, cnt[0]

    def num(lo, hi):
        return f'{rng.uniform(lo, hi):.4f}'

    def leaf():
        k = rng.random()
        if k < .3:
            r = num(.3, 1.5)
            return node(f'ssphere({r})', f'ssphere {r}')
        if k < .55:
            x, y, z = num(.3, 2), num(.3, 2), num(.3, 2)
            rr = rng.choice(['', num(0, .2)])
            return node(f'sbox({x}, {y}, {z}{", " + rr if rr else ""})', f'sbox {x} {y} {z} {rr}'.strip())
        if k < .75:
            r, h = num(.2, 1), num(.3, 2)
            return node(f'scyl({r}, {h})', f'scyl {r} {h}')
        R, r = num(.6, 1.5), num(.1, .4)
        return node(f'storus({R}, {r})', f'storus {R} {r}')

    def shape(d):
        if d >= 3 or rng.random() < .3:
            return leaf()
        k = rng.random()
        if k < .55:
            a, ia = shape(d + 1)
            b, ib = shape(d + 1)
            op = rng.choice(['sunion', 'ssub', 'sisect'])
            kk = rng.choice(['', '0', num(0, .5)])
            return node(f'{op}({a}, {b}{", " + kk if kk else ""})', f'{op} {ia} {ib} {kk}'.strip())
        if k < .7:
            a, ia = shape(d + 1)
            t = num(.05, .3)
            return node(f'sshell({a}, {t})', f'sshell {ia} {t}')
        a, ia = shape(d + 1)
        if rng.random() < .5:
            x, y, z = num(-1, 1), num(-1, 1), num(-1, 1)
            return node(f'smove({a}, {x}, {y}, {z})', f'smove {ia} {x} {y} {z}')
        x, y, z = num(-3, 3), num(-3, 3), num(-3, 3)
        return node(f'srot({a}, {x}, {y}, {z})', f'srot {ia} {x} {y} {z}')
    v, i = shape(depth)
    return bs, cl, v, i


def s_sdf():
    print('-- signed-distance shapes: random graphs meshed, distances as geometry says, errors said --')
    rng = random.Random(SEED + 11)
    n = max(4, RUNS // 4)
    bad = 0
    tot_v = tot_f = 0
    for k in range(n + 3):
        if k < n:
            bs, cl, v, i = rnd_shape(rng)
            cells = rng.choice([8, 16, 24, 40, 64])
        elif k == n:   # a lattice cut by a solid
            cl, i, cells = ['sgyroid 0.8 0.1', 'ssphere 1.2', 'sisect 2 1'], 3, 48
        elif k == n + 1:
            cl, i, cells = ['sgrid 0.5 0.12', 'sbox 2 1 1.5', 'sisect 2 1 0.05'], 3, 40
        else:          # units: lengths typed with them
            cl, i, cells = ['scene.units mm', 'sbox 10mm 2cm 0.5in 1mm'], 1, 24
        b = f'{T}/s{k}.bee'
        r = port(*ops('sclear', *cl, f'smesh S {i} {cells}', f'file.save_as {b}'), ok=False)
        said = answers(log())
        mm = [ln for a in said for ln in a if ln.startswith('  mesh S:')]
        mb = mesh_of(b, 'S') if os.path.exists(b) else None
        fine = r.returncode == 0 and (mb is None and any('empty' in ln or 'unbounded' in ln for a in said for ln in a) or
                                      mb is not None and mm and all(math.isfinite(c) for vv in mb[0] for c in vv) and f'{len(mb[0])} vertices' in mm[0])
        if not fine:
            bad += 1
            print(f'     shape {k}: {mm or said[-2:]} ({r.returncode})\n       ' + ' ; '.join(cl))
        elif mb:
            tot_v += len(mb[0])
            tot_f += len(mb[1])
    check(bad == 0 and tot_f > 1000, f'{n + 3} shapes (random graphs, a gyroid and a grid cut by solids, units): {n + 3 - bad} meshed or said why, {tot_v} vertices, {tot_f} triangles in all')
    # a sphere: its vertices on it
    port(*ops('sclear', 'ssphere 1.5', 'smesh S 1 32', f'file.save_as {T}/sph.bee'))
    mb = mesh_of(f'{T}/sph.bee', 'S')
    rad = [math.sqrt(sum(c * c for c in vv)) for vv in mb[0]] if mb else []
    check(rad and max(abs(x - 1.5) for x in rad) < 0.02, f'a sphere of 1.5: {len(rad)} vertices, radius {min(rad) if rad else 0:.4f} to {max(rad) if rad else 0:.4f}')
    port(*ops('sclear', 'sgyroid 1 0.1', 'smesh S 1 16'))
    check(any('the shape is unbounded' in ln for ln in log()), f'a lattice alone: {answers(log())[-1]}')
    port(*ops('sclear', 'ssphere 1', 'smove 1 5 0 0', 'sisect 1 2', 'smesh S 3 16'))
    check(any('the shape is empty' in ln for ln in log()), f'two apart, intersected: {answers(log())[-1]}')
    port(*ops('sclear', 'sunion 1 2', 'smesh S 9 16'))
    check(all('no such shape' in a[0] for a in answers(log())[1:]), 'no such shape: said so')
    # distances: a sphere, a box, a moved one, a union, a cut
    cases = [(['ssphere 0.8'], 1, (0.9, 0.3, 0.2), math.sqrt(0.81 + 0.09 + 0.04) - 0.8),
             (['ssphere 0.8'], 1, (0, 0, 0), -0.8),
             (['sbox 2 1 1'], 1, (3, 0, 0), 2.0),
             (['sbox 2 1 1'], 1, (0, 0, 0), -0.5),
             (['sbox 2 1 1'], 1, (3, 2, 0), 2.5),
             (['ssphere 1', 'smove 1 2 0 0'], 2, (2, 3, 0), 2.0),
             (['ssphere 1', 'sbox 1 1 1', 'smove 2 5 0 0', 'sunion 1 3'], 4, (2.5, 0, 0), 1.5),
             (['sbox 4 4 4', 'ssphere 1', 'ssub 1 2'], 3, (0, 0, 0), 1.0)]
    off = []
    for cl, i, p, want in cases:
        port(*ops('sclear', *cl, f'sdist {i} {p[0]} {p[1]} {p[2]}'))
        got = [float(ln.split()[-1]) for ln in log() if ln.startswith('  sdist ')]
        if len(got) != 1 or abs(got[0] - want) > 1e-5 * max(1, abs(want)):
            off.append((cl, p, want, got))
    check(not off, f'{len(cases)} distances as geometry says: {off or "all"}')
    port(*ops('sclear', 'sbox 2 1 1 0.1', 'srot 1 0.3 0.2 0.1', 'ssphere 0.8', 'ssub 2 3 0.2', 'sdist 4 0.9 0.3 0.2', 'sdist 4 0 0 0', 'sdist 4 3 1 -1'))
    got = [float(ln.split()[-1]) for ln in log() if ln.startswith('  sdist ')]
    check(len(got) == 3 and all(math.isfinite(x) for x in got) and got[1] > 0 and got[2] > 0, f'a turned box, a smooth cut: {got}')


def s_fuzz():
    print('-- fuzz (the port alone): random lines of every command here, garbage values, odd meshes; no stop --')
    rng = random.Random(SEED + 99)
    junk = ['', '0', '-1', '1e39', '-1e39', 'nan', 'inf', '1/0', '((((((', ')', '"', '""', '=', '==x', 'é€', '\\', '9' * 40, 'x' * 120, '2^99999', 'sqrt(-1)', '-0']
    stops = 0
    for run in range(max(4, RUNS // 2)):
        lines = []
        for _ in range(rng.randrange(10, 40)):
            k = rng.random()
            w = lambda: rng.choice(junk + [rnd_num(rng), rnd_expr(rng, ['a', 'b'])])
            if k < .25:
                lines.append(f'param.set {rng.choice(["a", "b", "c", rnd_name(rng)])} {w()}')
            elif k < .3:
                lines.append(f'param.remove {w()}')
            elif k < .35:
                lines.append(f'scene.units {rng.choice(["mm", "in", "m", w()])}')
            elif k < .55:
                verb = rng.choice(['ssphere', 'sbox', 'scyl', 'storus', 'sgyroid', 'sgrid', 'sunion', 'ssub', 'sisect', 'sshell', 'smove', 'srot', 'sdist'])
                lines.append(f'{verb} ' + ' '.join(rng.choice([str(rng.randrange(0, 6)), w()]) for _ in range(rng.randrange(0, 6))))
            elif k < .6:
                lines.append(f'smesh S {rng.randrange(0, 8)} {rng.choice([4, 8, 16, -5, 0, 100000, "x"])}')
            elif k < .65:
                lines.append(f'mesh.print_check {w()}')
            elif k < .7:
                lines.append(f'view.show_thickness {w()}')
            elif k < .75:
                lines.append(f'mesh.print_show {rng.choice(["edges", "thin", "overhangs", w()])}')
            elif k < .8:
                lines.append(rng.choice(['object.measure', 'edit.undo', 'edit.redo', 'object.select_all', 'create.torus', 'create.cube', 'object.delete', 'mode.edit', 'mode.object']))
            elif k < .85:
                lines.append(f'drawing.options {w()} {rng.choice(["a4", "letter", "portrait", "views", "scale", "title", "author"])} {w()}')
            elif k < .9:
                lines.append(f'file.export_pdf {T}/f.pdf')
            elif k < .95:
                lines.append(f'file.export_3mf {T}/f.3mf')
            else:
                lines.append(f'cad.kernel {w()}')
        r = port(*ops(*lines, f'file.save_as {T}/fz.bee', f'file.open {T}/fz.bee'), ok=False, timeout=600)
        if r.returncode != 0:
            stops += 1
            print(f'     run {run}: stopped ({r.returncode}) {r.stderr[-300:]}')
            print('       ' + ' | '.join(lines)[:600])
    check(stops == 0, f'{max(4, RUNS // 2)} random sessions on {os.path.basename(BIN)}: {stops} stopped')


# ---- the review's fixes (phase 9 layer 1) ------------------------------------------

FIELD_CASES = [('object.location', 0, t) for t in ('sin(30)', 'tau', '5%3', '2*pi', '_a+1', 'w/2', '1/0', '25mm', '1in', '3 4', 'sqrt(2)')] + \
    [('object.rotation', 3, t) for t in ('pi/2', '1rad', '90deg', '45+15', '2e1', 'sin(30)', '30')] + \
    [('object.scale', 6, t) for t in ('25mm', '1.5', '2*_a')] + \
    [('world.strength', 'Strength', t) for t in ('sin(1)', '2cm')] + \
    [('world.rotation', 'Rotation', t) for t in ('pi/4', '30', '1rad')]
FIELD_RESET = {'object.location': '0', 'object.rotation': '0', 'object.scale': '1', 'world.strength': '1', 'world.rotation': '0'}


def field_state(path):
    """What the fields hold, from the file: the Cube's place, the world's strength and rotation."""
    ob = [q for q in beefile.objects(path) if q['name'] == 'Cube'][0]
    w = beefile.chunk(path, b'WRLD')
    return [*ob['loc'], *ob['rot'], *ob['scl'], *struct.unpack_from('<2f', w, len(w) - 8)] if w else None


def ulps(a, b):
    ia, ib = struct.unpack('<i', struct.pack('<f', a))[0], struct.unpack('<i', struct.pack('<f', b))[0]
    return abs(ia - ib)


def field_want(units, wname, text):
    """What a typed text means, as the file keeps it: lengths in units of the scene
    (25mm is 0.025 in metres, 25 in mm), angles in radians: a plain number in a
    degree field is degrees, one with a letter radians (pi/2, 2e1); _a is 2, w is
    80 mm; tau is no value (the field stays 0). None: not one of the plain ones."""
    u = 0.001 if units == 'mm' else 1.0
    loc = {'tau': 0.0, '2*pi': 2 * math.pi, '_a+1': 3, 'w/2': 0.04 / u, '25mm': 0.025 / u, '1in': 0.0254 / u, 'sqrt(2)': math.sqrt(2),
           'sin(30)': math.sin(30)}
    rot = {'pi/2': math.pi / 2, '1rad': 1.0, '90deg': math.pi / 2, '45+15': math.radians(60), '2e1': 20.0, '30': math.radians(30),
           'sin(30)': math.sin(30)}
    if wname == 'object.location':
        return 0, loc.get(text)
    if wname == 'object.rotation':
        return 3, rot.get(text)
    if wname == 'object.scale':
        return 6, {'1.5': 1.5, '2*_a': 4.0}.get(text)
    if wname == 'world.strength':
        return 9, {'sin(1)': math.sin(1)}.get(text)
    return 10, {'pi/4': math.pi / 4, '30': math.radians(30), '1rad': 1.0}.get(text)


def s_fields():
    print('-- number fields: what is typed is an expression (scene units, parameters; a letter in a degree field means radians) --')
    pre = ['param.set _a 2', 'param.set w 80mm']
    port(*ops(*pre))
    nums = [ln.split('\t')[2].split() for ln in ui().splitlines() if ln.startswith('number\t')][:9]
    port(*ops(*pre), '--click-label', 'tab:Scene')
    wl = {ln.split('\t')[1]: ln.split('\t')[2].split() for ln in ui().splitlines() if ln.startswith('number\t')}
    bad = 0
    rows = []
    n = 0
    for units in ('m', 'mm'):
        for wname, where, text in FIELD_CASES:
            idx, want = field_want(units, wname, text)
            r = [int(v) for v in (nums[where] if isinstance(where, int) else wl[where])]
            xy = f'{r[0] + r[2] // 2},{r[1] + r[3] // 2}'
            b = f'{T}/fld.bee'
            if os.path.exists(b):
                os.unlink(b)
            pre2 = pre + (['scene.units mm'] if units == 'mm' else [])
            tab = ['--click-label', 'tab:Scene'] if wname.startswith('world') else []
            port(*ops(*pre2), *tab, '--click', xy, '--key', 'ctrl+a', '--type', text, '--key', 'enter', '--move', '600,300', *ops(f'file.save_as {b}'))
            got = field_state(b) if os.path.exists(b) else None
            v = got[idx] if got else None
            fine = got is not None and all(math.isfinite(x) for x in got)
            if want is not None:
                n += 1
                fine = fine and abs(v - want) <= 2e-6 * max(1, abs(want))
            rows.append(f'{units:>2} {wname:<16} {text!r:<11} {v!s:<22} want {want}')
            if not fine:
                bad += 1
                print('     ' + rows[-1] + '  <-- off')
    check(bad == 0, f'{len(rows)} typed values in five fields, metres and mm: {n} as their expressions say, the rest finite ({bad} not)')
    port(*ops(*pre), '--click', f'{int(nums[0][0]) + 5},{int(nums[0][1]) + 5}', '--key', 'ctrl+a', '--type', 'tau', '--key', 'enter')
    check('not a value: tau' in log(), 'a value that fails: "not a value: tau" in the log')
    # the redo panel's field: the same expressions
    for t, v in (('sin(1)/10', math.sin(1) / 10), ('25mm/1000', 0.025)):
        port(*ops('scene.units mm'), '--move', '615,360', '--key', 'tab', *ops('mesh.select_mode_face', 'mesh.inset 0.1'))
        rr = [ln.split('\t') for ln in ui().splitlines() if ln.startswith('redo\t') and ln.split('\t')[1].startswith('Thickness')]
        if not rr:
            check(False, 'the redo panel shows its Thickness field')
            continue
        x, y, w, h = [int(q) for q in rr[0][2].split()]
        port(*ops('scene.units mm'), '--move', '615,360', '--key', 'tab', *ops('mesh.select_mode_face', 'mesh.inset 0.1'), '--click', f'{x + w // 2},{y + h // 2}', '--key', 'ctrl+a', '--type', t, '--key', 'enter')
        row = [ln.split('\t')[1] for ln in ui().splitlines() if ln.startswith('redo\tThickness')]
        check(row and abs(float(row[0].split()[1]) - v) < 6e-4, f'the redo panel takes {t!r} as {v:.5f} mm: {row}')


def s_review():
    print('-- Print Check from the console, the thin walls after a change of units, New Sketch, the History\'s names --')
    port('--click-label', 'tab:CAD', *ops('mesh.print_check'))
    check('section\tPrint Check' in ui(), 'mesh.print_check typed: Properties shows the Print Check panel')
    port('--click-label', 'tab:CAD', '--move', '600,300')
    u = ui()
    d = open(f'{T}/u.ppm', 'rb').read()
    hdr = d.split(b'\n', 3)
    w = int(hdr[1].split()[0])

    def px(label):
        br = [ln.split('\t')[2].split() for ln in u.splitlines() if ln.startswith(f'button\t{label}\t')]
        if not br:
            return None
        bx, by, bw, bh = [int(q) for q in br[0]]
        k = ((by + bh // 2) * w + bx + 6) * 3
        return tuple(hdr[3][k:k + 3])
    pcol, plain = px('New Sketch...'), px('Add Parameter...')
    check(pcol is not None and plain is not None and pcol[0] > pcol[2] + 60 and max(abs(a - b) for a, b in zip(pcol, plain)) > 40,
          f'New Sketch... is the primary (orange) button: {pcol}, a plain one {plain}')
    # Show Thin Walls: a change of units (and its undo) colours anew what was drawn
    def vp_px(path):
        d = open(path, 'rb').read()
        hdr = d.split(b'\n', 3)
        w = int(hdr[1].split()[0])
        return [hdr[3][(yy * w + 200) * 3:(yy * w + 1000) * 3] for yy in range(40, 600)]

    frames = ['--move', '600,300', '--wait', '100', '--move', '610,300', '--wait', '100', '--move', '600,300']
    res = {}
    for k, seq in (('after', ['view.show_thickness 1500', '#', 'scene.units mm', '#']), ('fresh', ['scene.units mm', 'view.show_thickness 1500', '#']),
                   ('undone', ['view.show_thickness 1500', '#', 'scene.units mm', '#', 'edit.undo', '#']), ('m', ['view.show_thickness 1500', '#'])):
        a = []
        for c in seq:
            a += frames if c == '#' else ['--op', c]
        port(*a)
        res[k] = (vp_px(f'{T}/u.ppm'), [ln.split('\t')[1] for ln in ui().splitlines() if ln.startswith('analysis\t')])
    check(res['after'] == res['fresh'] and res['undone'] == res['m'] and res['after'][0] != res['m'][0],
          f'thin walls: after scene.units mm the view is coloured as a fresh one ({res["after"][1]} / {res["fresh"][1]}), after its undo as before ({res["undone"][1]} / {res["m"][1]})')
    # the History's names: cad.sketch typed is "Script", sketch edits "Sketch ..."
    port(*ops('cad.sketch S XZ 0'), '--move', '500,500', '--key', 'r', '--click', '400,300', '--click', '600,450', '--key', 'esc',
         '--press', '400,300', '--move', '420,310', '--move', '430,320', '--release', '430,320', '--move', '500,500', '--key', 'tab', *ops('edit.undo_history'))
    phist = [ln.split('\t')[1] for ln in ui().splitlines() if ln.startswith('step\t')][1:]
    check(len(phist) == 3 and phist[0] == 'Script' and all(x.startswith('Sketch') for x in phist[1:]), f'the History names the steps: cad.sketch typed a Script, the edits Sketch: {phist!r}')


def main():
    print(f'cad: {BIN}, sessions {RUNS}, seed {SEED}')
    only = os.environ.get('CAD_ONLY', '')
    for s in (s_params, s_files, s_undo, s_measure, s_tool, s_print, s_panel, s_look, s_3mf, s_pdf, s_sdf, s_fields, s_review, s_fuzz):
        if not only or s.__name__ in only.split(','):
            s()
    shutil.rmtree(T, ignore_errors=True)
    print('fails', len(FAILS))
    sys.exit(1 if FAILS else 0)


main()
